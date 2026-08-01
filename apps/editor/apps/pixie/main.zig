//! Pixie MVP: libs/gui UI + Pen/Eraser/DB16 palette / Undo / PNG save
//!
//! - Layout: menu bar / PanelHost(left=History, center=canvas, right=Color/Palette/
//!   Tool Options/Layers, bottom=Timeline) / status bar
//! - Canvas input: press-origin capture (canvas_input.zig state machine). During a stroke,
//!   continue even if the pointer leaves over the GUI (unclamped transform + pixel-side clip)
//! - Tool / Undo: core Tool(Pen/Eraser) / StrokeRecorder / UndoStack
//! - File I/O: Cmd+S=save (remembered path) / Cmd+Shift+S=save as / Cmd+O=open.
//!   File dialogs must not run under the framebuffer lock (re-entrancy risk), so handleKey/buttons
//!   only set pending_file_op; runPendingFileOp() executes them at the end-of-frame safe point.
//! - Keys: B=Pen / E=Eraser / C=clear all / Cmd+Z=Undo / Cmd+Shift+Z=Redo
//!         ESC / Cmd+Q=quit (including window close: single path sets running=false)

const std = @import("std");
const builtin = @import("builtin");
const kit = @import("kit"); // Public umbrella (ADR-007 R4/R5: apps are kit-only consumers)
const platform = kit.platform;
const gui = kit.gui;
const recipe = kit.recipe;
const app_runtime = kit.app_runtime;
const appshell = kit.appshell;
const core = @import("paint");
const pixelops = kit.pixelops;
const png = kit.png;
const canvas_input = @import("canvas_input.zig");
const actions = @import("actions.zig");
const icons = @import("icons.zig");
const diff = @import("diff.zig");
const blit = @import("blit.zig");
const zoom_mod = @import("zoom.zig");
const Zoom = zoom_mod.Zoom;
const minimap_mod = @import("minimap.zig");
const ScreenTransform = kit.gfx.ScreenTransform;
const palette_mod = @import("palette.zig");
const bezier_input = @import("bezier_input.zig");
const bezier_overlay = @import("bezier_overlay.zig");
const grid_overlay = @import("grid_overlay.zig");
const loupe_overlay = @import("loupe_overlay.zig");
const selection_input = @import("selection_input.zig");
const selection_overlay = @import("selection_overlay.zig");
const shape_input = @import("shape_input.zig");
const shape_overlay = @import("shape_overlay.zig");
const eyedropper_input = @import("eyedropper_input.zig");
const brush_edge_cache = @import("brush_edge_cache.zig");
const cursor_overlay = @import("cursor_overlay.zig");
const layer_rename_input = @import("layer_rename_input.zig");
const text_content_input = @import("text_content_input.zig");
const history_summary = @import("history_summary.zig");
const history_thumbnail = @import("history_thumbnail.zig");
const history_persist = @import("history_persist.zig");

// Layer-name max length is defined independently in libs/paint (save side) and pixie (edit buffer)
// (avoids a cyclic import; see the top of layer_rename_input.zig). Comptime-assert they match.
comptime {
    if (core.layer_name_max != layer_rename_input.max_len) {
        @compileError("layer_name_max mismatch between paint.Canvas and layer_rename_input");
    }
}
// Text-layer content max length is likewise independently defined; comptime-assert they match.
comptime {
    if (core.text_content_max != text_content_input.max_len) {
        @compileError("text_content_max mismatch between paint.Canvas and text_content_input");
    }
}
// Brush-size max is likewise independently defined in actions.zig (std-only) and paint; guard drift.
comptime {
    if (actions.MAX_BRUSH_SIZE != core.Brush.MAX_SIZE) {
        @compileError("MAX_BRUSH_SIZE mismatch between actions.zig and paint.Brush");
    }
}
// Drift guard: RELAY_STROKE_CHUNK_POINTS worst-case args must fit the real MAX_CMD_ARGS
// (actions.zig is std-only so it self-checks against a 4096 literal; this is the platform-side guard).
comptime {
    const commit_framing = 12 + "stroke ".len;
    const worst_head =
        "layer=#18446744073709551615 tool=brush color=FFFFFF size=64 opacity=255 hardness=255 segment=continuation".len;
    const worst_point = " -2147483648 -2147483648".len;
    const worst_args = worst_head + actions.RELAY_STROKE_CHUNK_POINTS * worst_point;
    if (worst_args > platform.command.MAX_CMD_ARGS) {
        @compileError("RELAY_STROKE_CHUNK_POINTS too large for platform.command.MAX_CMD_ARGS");
    }
    if (commit_framing + worst_args > platform.command.MAX_CMD_ARGS) {
        @compileError("RELAY_STROKE_CHUNK_POINTS too large for action frame (MAX_CMD_ARGS)");
    }
}

const WINDOW_W: u32 = 780;
const WINDOW_H: u32 = 600;

/// Whether the appshell persistence layer (window_state / recent files / autosave /
/// preferences) has a directory-capable filesystem to save into. Wasm's WASI shim
/// (`web/kngn.js`) is a flat file store with no directory concept at all (`path_open`
/// rejects `O_DIRECTORY` and `path_create_directory` is unconditionally unsupported),
/// so on wasm every appshell save/load/scan call below is skipped and the session
/// keeps its state in memory only, never touching an app-data or autosave directory.
const appshell_dir_supported = builtin.os.tag != .wasi and builtin.os.tag != .freestanding;
/// Default canvas size at startup (runtime size is `doc.width` / `doc.height`).
const DEFAULT_CANVAS_W: u32 = 256;
const DEFAULT_CANVAS_H: u32 = 256;
// Viewport: rational Zoom (1/4..1/2 plus integer 1..32). Default 2x.

/// Input kind that started a pan drag (latched at start so backends that omit Cmd on move still finish)
const PanKind = enum { space_left, middle, cmd_left };
// Transparent-background checker (screen-fixed cells; canonical BGRA 0xAARRGGBB)
// Single source for checker constants is blit.zig
const CHECKER_LIGHT = blit.CHECKER_LIGHT;
const CHECKER_DARK = blit.CHECKER_DARK;
// Default PanelHost slot extents (inherits the former right/bottom pane constants).
const RIGHT_PANE_DEFAULT: i32 = 200;
const RIGHT_PANE_MIN: i32 = 120;
const LEFT_PANE_DEFAULT: i32 = 200;
const LEFT_PANE_MIN: i32 = 120;
const BOTTOM_PANE_DEFAULT: i32 = 120;
const BOTTOM_PANE_MIN: i32 = 80;
const CANVAS_MIN: i32 = 120; // Minimum canvas edge kept when resizing panes
const SPLITTER_T: i32 = 6; // Splitter band thickness

/// Stable PanelHost panel names (shared by Preferences / Collapsible / View menu).
const PanelNames = struct {
    pub const history = "History";
    pub const color = "Color";
    pub const palette = "Palette";
    pub const tool_options = "Tool Options";
    pub const layers = "Layers";
    pub const timeline = "Timeline";
};

/// One panel's rect (y/h) for `digest panels`.
const PanelProbeRect = struct { y: i32, h: i32 };
const SAVE_MSG_DURATION: f64 = 3.0;
// Selection marching ants. Phase speed (units/sec) and period (=2*DASH; selection_overlay DASH=4).
const MARCH_SPEED: f64 = 12.0;
const MARCH_PERIOD: f64 = 8.0;

/// File-op request. Holds a request that arrived under the framebuffer lock (during frame work)
/// and runs it once at the post-unlock safe point (avoids re-entering a dialog modal loop).
const FileOp = enum { save, save_as, open, save_palette, load_palette, save_project, open_project, export_seq, export_sheet, confirm_save_as };

// ── File/Edit/View Command definitions ────────────────────────────────
// IDs are stable. Separators use INVALID_COMMAND_ID. GUI fallback / keyboard / menu_command
// all reach the same App.dispatchCommand.
const CmdId = struct {
    pub const open: platform.CommandId = 1;
    pub const save: platform.CommandId = 2;
    pub const save_as: platform.CommandId = 3;
    pub const open_project: platform.CommandId = 4;
    pub const save_project: platform.CommandId = 5;
    pub const new_document: platform.CommandId = 14;
    pub const new_size: platform.CommandId = 15;
    pub const resize_canvas: platform.CommandId = 16;
    pub const export_seq: platform.CommandId = 6;
    pub const export_sheet: platform.CommandId = 7;
    pub const save_palette: platform.CommandId = 8;
    pub const load_palette: platform.CommandId = 9;
    pub const undo: platform.CommandId = 10;
    pub const redo: platform.CommandId = 11;
    pub const toggle_history: platform.CommandId = 12;
    pub const toggle_timeline: platform.CommandId = 13;
    pub const toggle_color: platform.CommandId = 17;
    pub const toggle_palette: platform.CommandId = 18;
    pub const toggle_tool_options: platform.CommandId = 19;
    pub const toggle_layers: platform.CommandId = 20;
};

/// New Size / Resize Canvas modal. TextBuffers are owned for the App lifetime and
/// shown only while `size_dialog != null` (pointer into storage).
const SizeDialogMode = enum { new_size, resize };
const SizeDialogState = struct {
    mode: SizeDialogMode,
    width_buf: gui.TextBuffer,
    height_buf: gui.TextBuffer,
    err_len: usize = 0,
    err_buf: [128]u8 = undefined,

    fn setError(self: *SizeDialogState, msg: []const u8) void {
        const n = @min(msg.len, self.err_buf.len);
        @memcpy(self.err_buf[0..n], msg[0..n]);
        self.err_len = n;
    }

    fn clearError(self: *SizeDialogState) void {
        self.err_len = 0;
    }

    fn errorMsg(self: *const SizeDialogState) ?[]const u8 {
        if (self.err_len == 0) return null;
        return self.err_buf[0..self.err_len];
    }
};
const SIZE_DIALOG_ID_BASE: gui.Id = 0xA450_0000;
const SIZE_DIALOG_W_ID: gui.Id = SIZE_DIALOG_ID_BASE + 1;
const SIZE_DIALOG_H_ID: gui.Id = SIZE_DIALOG_ID_BASE + 2;
const SIZE_DIALOG_OK_ID: gui.Id = SIZE_DIALOG_ID_BASE + 3;
const SIZE_DIALOG_CANCEL_ID: gui.Id = SIZE_DIALOG_ID_BASE + 4;
/// Status-bar zoom%/cursor variable slots. Explicit IDs reserved for layout.
/// Live text is drawn by drawStatusBarLive after updateViewport.
const STATUS_BAR_ID_BASE: gui.Id = 0xA451_0000;
const STATUS_CURSOR_ID: gui.Id = STATUS_BAR_ID_BASE + 1;
const STATUS_ZOOM_ID: gui.Id = STATUS_BAR_ID_BASE + 2;
/// The zoom slider's track (sliderI32Id's explicit ID names its track node, not the whole
/// [label][track][value] row it draws). A separate box from STATUS_ZOOM_ID: this one is a real
/// interactive widget built every frame in buildUi, while STATUS_ZOOM_ID stays a layout
/// placeholder repainted post-hoc by drawStatusBarLive (repainting this box too would erase the
/// slider's own drawing).
const STATUS_ZOOM_SLIDER_ID: gui.Id = STATUS_BAR_ID_BASE + 3;
const STATUS_BAR_BG = gui.Color.rgba(0x28, 0x28, 0x30, 0xFF);

const MENU_CMD_CAP = 40;
const RECENT_CMD_BASE: platform.CommandId = 100;

/// Snapshot for the native-menu dirty gate.
/// label / top_menu use full-string hash+len (prefix truncation would miss recent-path suffix diffs).
/// shortcut keeps Optional presence plus key/modifiers.
const NativeMenuSnap = struct {
    id: platform.CommandId,
    enabled: bool,
    checked: bool,
    kind: platform.CommandKind,
    label_hash: u32 = 0,
    label_len: usize = 0,
    title_hash: u32 = 0,
    title_len: usize = 0,
    has_shortcut: bool = false,
    shortcut_key: platform.KeyCode = .A,
    shortcut_mods: platform.ModifierFlags = .{},
};

fn hashMenuStr(s: []const u8) u32 {
    return std.hash.Fnv1a_32.hash(s);
}

const LAYER_PANEL_ID_BASE: gui.Id = 0xA430_0000;
const LAYER_ROW_ID_BASE: gui.Id = 0xA430_1000;
const LAYER_PANEL_ID_STRIDE: gui.Id = 8;
/// Layer-row right-click context menu id (popup primitive).
const LAYER_CTX_MENU_ID: gui.Id = 0xA430_2000;
/// Explicit IDs for the text-layer edit panel.
const TEXT_PANEL_ID_BASE: gui.Id = 0xA430_3000;
const TEXT_EDIT_BOX_ID: gui.Id = TEXT_PANEL_ID_BASE + 6;
/// `layerWidgetId` part for the layer-row box itself (0..3 already used: 0=select button / 1=visibility
/// toggle / 2=opacity slider / 3=thumb). Right-click hit-testing uses the full row rect.
const LAYER_ROW_PART_ROW: gui.Id = 4;
const LAYER_ROW_PART_IME: gui.Id = 5;
/// Explicit IDs for the history panel.
const HISTORY_PANEL_ID_BASE: gui.Id = 0xA431_0000;
/// Explicit IDs for tool / symmetry icons. Offsets 0..13 are a fixed assignment.
const TOOL_ICON_ID_BASE: gui.Id = 0xA148_2000;
// Layer-panel thumbnail (alpha-weighted downscale of the raw layer onto a checker, then 1:1 blit)
const LAYER_THUMB_W: i32 = 24;
const LAYER_THUMB_H: i32 = 24;
const LAYER_THUMB_CELL: usize = 4; // Checker cell size in px inside the thumbnail
/// Timeline UI
const TIMELINE_SCROLL_ID: gui.Id = 0xC0FFEE07;
/// Layers-only scroll (successor to the former RIGHT_SCROLL_ID).
const LAYERS_SCROLL_ID: gui.Id = 0xC0FFEE08;
/// Layers ScrollArea min height = one layer row (thumb-paced; no fixed 80/180).
const LAYERS_VIEWPORT_ROW_MIN: i32 = LAYER_THUMB_H;
/// First-frame fallback for chrome (Collapsible heading + toolbar). Later measured as panelRect − scroll rect.
const LAYERS_CHROME_FALLBACK: i32 = 50;
/// Approximate height when Text Layer UI is inside the Layers scroll (first frame before measurement).
const LAYERS_TEXT_UI_FALLBACK: i32 = 130;
/// Total vertical padding of the PanelHost right slot (slot build padding top+bottom = 4+4).
const PANEL_SLOT_PAD_V: i32 = 8;
/// Gap between panels inside a PanelHost slot.
const PANEL_SLOT_GAP: i32 = 4;
const TIMELINE_PANEL_ID_BASE: gui.Id = 0xA440_0000;
const TIMELINE_HEADER_ID_BASE: gui.Id = 0xA441_0000;
const TIMELINE_CELL_ID_BASE: gui.Id = 0xA442_0000;
const TIMELINE_CELL_FRAME_STRIDE: gui.Id = 4096;
const TIMELINE_CELL_W: i32 = 24;
const TIMELINE_CELL_H: i32 = 24;
const TIMELINE_LABEL_W: i32 = 72;
const TIMELINE_LINK_BORDER = gui.Color.rgba(0x40, 0xA0, 0xE0, 0xFF);
const TIMELINE_PLAYHEAD_BORDER = gui.Color.rgba(0xE0, 0xC0, 0x40, 0xFF);

const COLOR_WINDOW_BG: u32 = 0xFF_24_20_20; // canonical BGRA: r=24,g=20,b=20 (keeps the existing look)

/// canvas pixel (canonical BGRA 0xAARRGGBB) → gui.Color (same bit layout). For swatch/preview drawing.
fn guiColor(c: u32) gui.Color {
    return @bitCast(c);
}

/// Current drawing-tool kind (UI display / selection highlight; dispatch is owned by core.Tool)
const ToolKind = enum {
    pen,
    eraser,
    brush,
    bezier,
    select,
    fill,
    eyedropper,
    line,
    rect,
    ellipse,

    fn name(self: ToolKind) []const u8 {
        return switch (self) {
            .pen => "Pen",
            .eraser => "Eraser",
            .brush => "Brush",
            .bezier => "Bezier",
            .select => "Select",
            .fill => "Fill",
            .eyedropper => "Eyedropper",
            .line => "Line",
            .rect => "Rect",
            .ellipse => "Ellipse",
        };
    }

    /// Soft-overlay tool badge (cursor_overlay.drawGlyph): 2-char label + background color.
    /// Labels are all string literals (satisfies DrawList.text lifetime).
    fn glyph(self: ToolKind) struct { label: []const u8, color: gui.Color } {
        return switch (self) {
            .pen => .{ .label = "Pn", .color = gui.Color.rgba(0x2A, 0x5F, 0xB0, 0xFF) },
            .eraser => .{ .label = "Er", .color = gui.Color.rgba(0xB0, 0x33, 0x5A, 0xFF) },
            .brush => .{ .label = "Br", .color = gui.Color.rgba(0xC9, 0x7A, 0x20, 0xFF) },
            .bezier => .{ .label = "Bz", .color = gui.Color.rgba(0x1E, 0x9E, 0xC9, 0xFF) },
            .select => .{ .label = "Sl", .color = gui.Color.rgba(0xB8, 0x9A, 0x16, 0xFF) },
            .fill => .{ .label = "Fl", .color = gui.Color.rgba(0x2E, 0x9E, 0x52, 0xFF) },
            .eyedropper => .{ .label = "Ey", .color = gui.Color.rgba(0x7A, 0x4A, 0xC9, 0xFF) },
            .line => .{ .label = "Ln", .color = gui.Color.rgba(0x4A, 0x7A, 0xC9, 0xFF) },
            .rect => .{ .label = "Rc", .color = gui.Color.rgba(0x5A, 0x9E, 0x7A, 0xFF) },
            .ellipse => .{ .label = "El", .color = gui.Color.rgba(0x9E, 0x6A, 0xC9, 0xFF) },
        };
    }

    fn isShape(self: ToolKind) bool {
        return self == .line or self == .rect or self == .ellipse;
    }
};

/// Brush footprint outline-ring colors (same even/odd alternating style as selection_overlay marching ants,
/// to keep contrast against any canvas background).
const RING_COLOR_A = gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF); // White
const RING_COLOR_B = gui.Color.rgba(0xC9, 0x7A, 0x20, 0xFF); // Same orange family as the brush badge

const InlineCompositionDraw = struct {
    committed: []const u8,
    preedit: []const u8,
    cursor: usize,
    font: gui.Font,
    color: gui.Color,
    preedit_color: gui.Color,
};

const CompositionCaretRect = struct { x: i32, y: i32, w: i32, h: i32 };

fn drawInlineComposition(ctx_ptr: *anyopaque, dl: *gui.DrawList, rect: gui.Rect) void {
    const d: *const InlineCompositionDraw = @ptrCast(@alignCast(ctx_ptr));
    const committed_w: i32 = @intCast(d.font.measure(d.committed));
    const preedit_w: i32 = @intCast(d.font.measure(d.preedit));
    // Custom leaf height is ink-based. Align text/underline/caret to the same y (ink, not line_height).
    const metrics = d.font.metrics();
    const ink_h = gui.inkHeight(metrics);
    const text_y = gui.centeredTextY(rect.y, @as(i32, @intCast(rect.h)), ink_h);
    dl.textEx(.{ .x = rect.x, .y = text_y }, d.committed, d.color, d.font) catch @panic("composition text: OOM");
    dl.textEx(.{ .x = rect.x + committed_w, .y = text_y }, d.preedit, d.preedit_color, d.font) catch @panic("composition preedit: OOM");
    const start_x = rect.x + committed_w;
    // Underline sits just under the baseline (ascent+2). Clamped to the ink-box bottom (ink, not line_height).
    const underline_y = @min(text_y + metrics.ascent + 2, text_y + ink_h - 1);
    dl.line(.{
        .x = start_x,
        .y = underline_y,
    }, .{
        .x = start_x + preedit_w,
        .y = underline_y,
    }, d.preedit_color, 1) catch @panic("composition underline: OOM");
    const cursor_prefix = d.preedit[0..@min(d.cursor, d.preedit.len)];
    const cursor_x = start_x + @as(i32, @intCast(d.font.measure(cursor_prefix)));
    dl.line(.{ .x = cursor_x, .y = text_y + 2 }, .{
        .x = cursor_x,
        .y = text_y + ink_h - 2,
    }, d.preedit_color, 1) catch @panic("composition caret: OOM");
}

/// platform.MouseButton → InputEvent button index (0=left/1=right/2=middle).
fn buttonToU8(b: platform.MouseButton) u8 {
    return switch (b) {
        .left => 0,
        .right => 1,
        .middle => 2,
        else => 0xFF,
    };
}

/// platform.Event → gui.InputEvent. quit (GUI-irrelevant) becomes null.
/// Drop negative key codes (platform KeyCode.UNKNOWN = -1); libs/gui assumes u32 codes.
/// `pass_char_input`: true only while size_dialog is open (normally char_input is not forwarded to GUI).
fn toGuiEvent(ev: platform.Event) ?gui.InputEvent {
    return toGuiEventEx(ev, false);
}

fn toGuiEventEx(ev: platform.Event, pass_char_input: bool) ?gui.InputEvent {
    return switch (ev) {
        .quit => null,
        .char_input => |ch| if (pass_char_input)
            .{ .char_input = .{ .codepoint = ch.codepoint, .modifiers = ch.modifiers.toC() } }
        else
            null,
        .gamepad_connected, .gamepad_disconnected => null, // pixie does not consume this (cross-cutting Event; other features untouched)
        .composition_changed => null, // composition not consumed here (inline preedit is separate)
        .menu_command => null, // Consumed by App.dispatchCommand (not forwarded to gui)
        .file_drop => null, // Do not forward to GUI
        .mouse_move => |m| .{ .mouse_move = .{ .x = m.x, .y = m.y, .modifiers = m.modifiers.toC() } },
        .mouse_down => |m| .{ .mouse_down = .{ .x = m.x, .y = m.y, .button = buttonToU8(m.button), .modifiers = m.modifiers.toC() } },
        .mouse_up => |m| .{ .mouse_up = .{ .x = m.x, .y = m.y, .button = buttonToU8(m.button), .modifiers = m.modifiers.toC() } },
        .mouse_scroll => |s| .{ .mouse_scroll = .{ .x = s.x, .y = s.y, .dx = s.dx, .dy = s.dy, .modifiers = s.modifiers.toC() } },
        .key_down => |k| blk: {
            const code = @intFromEnum(k.key);
            if (code < 0) break :blk null;
            break :blk .{ .key_down = .{ .code = @intCast(code), .modifiers = k.modifiers.toC(), .repeat = k.is_repeat } };
        },
        .key_up => |k| blk: {
            const code = @intFromEnum(k.key);
            if (code < 0) break :blk null;
            break :blk .{ .key_up = .{ .code = @intCast(code), .modifiers = k.modifiers.toC() } };
        },
    };
}

/// App state (touched from both event handling and UI build)
/// One relay-wire chunk (owns a copied point list; canonicalized on release).
const RelayStrokeChunk = struct {
    pts: [actions.RELAY_STROKE_CHUNK_POINTS]actions.Point = undefined,
    len: usize = 0,
    continuation: bool = false,
};

const App = struct {
    /// Initial window spec consulted by app_runtime
    pub const window = .{ .w = WINDOW_W, .h = WINDOW_H, .title = "Pixie" };

    /// Load window_state before startup and return WindowOptions.
    /// After platform.init, before Window.create. On failure: default 780x600.
    /// fb_mode=.physical (HiDPI crisp UI + nearest-neighbor canvas).
    /// On wasm (no directory-capable filesystem, see `appshell_dir_supported`), always
    /// returns `fallback_opts` without attempting to open a data directory.
    pub fn windowBootstrap(gpa: std.mem.Allocator, io: std.Io) !platform.WindowOptions {
        const fallback_opts: platform.WindowOptions = .{
            .position = null,
            .size = .{ .width = WINDOW_W, .height = WINDOW_H },
            .fb_mode = .physical,
        };
        if (comptime !appshell_dir_supported) return fallback_opts;
        // KNGN_APPSHELL_DIR is a native-only development override; wasm has no process env to read.
        const override_path = if (std.c.getenv("KNGN_APPSHELL_DIR")) |value|
            std.mem.span(value)
        else
            null;
        var data_dir = appshell.paths.openAppDataDir(io, gpa, "pixie", override_path) catch |err| {
            std.log.err("pixie: window_state data dir open failed: {s}", .{@errorName(err)});
            return fallback_opts;
        };
        defer data_dir.close(io);
        const fallback_state: appshell.window_state.State = .{
            .position = null,
            .size = .{ .width = WINDOW_W, .height = WINDOW_H },
        };
        const loaded = appshell.window_state.load(io, data_dir, "window_state.ash", fallback_state) catch |err| {
            std.log.err("pixie: window_state load failed: {s}", .{@errorName(err)});
            return fallback_opts;
        };
        const resolved = appshell.window_state.resolve(loaded.state, fallback_state, null);
        return .{
            .position = if (resolved.position) |p| .{ .x = p.x, .y = p.y } else null,
            .size = .{ .width = resolved.size.width, .height = resolved.size.height },
            .fb_mode = .physical,
        };
    }

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !*App {
        return appInit(gpa, io);
    }
    pub fn deinit(self: *App) void {
        appDeinit(self);
    }
    pub fn frame(self: *App, win: *platform.Window, now: f64) !bool {
        return appFrame(self, win, now);
    }
    /// Opt-in hook app_runtime calls right after Window.create + App.init.
    /// Registers the live-resize redraw callback (facade no-op under harness/headless).
    pub fn onWindowReady(self: *App, win: *platform.Window) void {
        self.redraw_win = win.*;
        self.os_window = win;
        win.setRedrawCallback(self, redrawCb);
        // At startup declare "no text-edit focus" (closes the gap where keyDown before the first pollEvents
        // was swallowed by IME via the old route-always). Afterwards track edit state every frame.
        win.setTextInputActive(false);
        self.refreshTitle();
        // Native menu (macOS native backend + enable_menu). headless stays false → GUI fallback.
        self.rebuildMenuCommands();
        if (win.nativeMenuAvailable()) {
            self.native_menu_active = true;
            win.registerMenu(self.menuCommandsSlice());
            self.saveNativeMenuSnapshot();
            self.native_menu_registered = true;
        }
    }

    /// Called before Window.destroy and App.deinit. Persists geometry into window_state.
    /// Also persists PanelHost visibility/extents into Preferences.
    /// size=0 (facade safe default / fetch failure) skips window_state save so existing state is kept.
    /// Preferences always attempts persist+save regardless of geometry success; failures are log-only.
    /// On wasm (no directory-capable filesystem), both persistPanels (via preferences.save) and
    /// window_state.save are no-ops; see `appshell_dir_supported`.
    pub fn onWindowShutdown(self: *App, win: *platform.Window) void {
        self.persistPanels() catch |err| {
            std.log.err("pixie: preferences save failed: {s}", .{@errorName(err)});
        };
        if (comptime !appshell_dir_supported) return;
        const geo = win.getGeometry();
        if (geo.size.width == 0 or geo.size.height == 0) {
            std.log.warn("pixie: window_state save skipped (invalid geometry size={d}x{d})", .{ geo.size.width, geo.size.height });
            return;
        }
        const state: appshell.window_state.State = .{
            .position = if (geo.position) |p| .{ .x = p.x, .y = p.y } else null,
            .size = .{ .width = geo.size.width, .height = geo.size.height },
        };
        appshell.window_state.save(self.io, self.data_dir, "window_state.ash", state) catch |err| {
            std.log.err("pixie: window_state save failed: {s}", .{@errorName(err)});
        };
    }

    fn syncComposition(self: *App, win: *platform.Window) void {
        if (!self.composition_dirty) return;
        const snapshot = win.getCompositionSnapshot(self.preedit_buf[0..]);
        self.preedit_len = snapshot.text.len;
        self.preedit_cursor = @min(@as(usize, snapshot.cursor), self.preedit_len);
        self.composition_dirty = false;
    }

    fn preedit(self: *const App) []const u8 {
        return self.preedit_buf[0..self.preedit_len];
    }

    io: std.Io,
    gpa: std.mem.Allocator,
    /// GUI context (cross-frame persistent; owned by App for the wasm runtime).
    ctx: gui.Context,
    /// Document (frames × layers; MVP is 1 frame). Canvas is heap-owned with a stable pointer.
    doc: core.Document,
    /// Active-frame Canvas (doc.activeCanvas()). Keep *Canvas to minimize churn of existing references.
    canvas: *core.Canvas = undefined,
    /// System OutlineFont shared by GUI / canvas (owned by App; falls back to default_font if missing).
    gui_font: kit.GuiFont = .{},
    recorder: core.StrokeRecorder,
    /// Temporary canvas/recorder for brush preview while editing a bezier (non-destructive draw on a copy of this layer)
    preview_canvas: core.Canvas,
    preview_rec: core.StrokeRecorder,
    // Undo no longer has a standalone field; go through `doc.undo`.
    pen: core.Pen,
    eraser: core.Eraser = .{},
    brush: core.Brush,
    /// Fill (bucket) tool. Shares the canvas_input down/move/up contract with Pen/Eraser/Brush
    /// (no independent path like bezier/select).
    fill: core.Fill,
    input: canvas_input.CanvasInput = .{},
    /// Bezier (pen) tool (independent path). State machine + mouse-input adapter.
    bezier_editor: core.PathEditor = .{},
    bez_in: bezier_input.BezierInput = .{},
    /// Selection tool (independent path). State machine for marquee create / selection move.
    sel_in: selection_input.SelectionInput = .{},
    /// Shape tool (independent path). Line/Rect/Ellipse press→drag→release.
    shape_in: shape_input.ShapeInput = .{},
    /// Pixel-perfect lines (Pen size=1 only; reflected into StrokeRecorder).
    pixel_perfect: bool = false,
    /// Symmetry drawing (reflected into StrokeRecorder; applies to Pen/Eraser/Brush/Shape).
    symmetry: core.Symmetry = .off,
    /// Eyedropper tool (independent path). Minimal press-capture state machine (no paint ops, so
    /// Tool vtable / StrokeRecorder / Undo are unused). Used for both dedicated tool mode and Alt+click temporary pick.
    eye_in: eyedropper_input.EyedropperInput = .{},
    /// Clipboard (allocated on copy/cut, referenced on paste; gpa-owned, freed in deinit).
    clipboard: ?core.PixelBlock = null,
    /// Baseline snapshot for visual diff (lazy alloc; gpa-owned; freed in deinit).
    /// Never retain a borrowed compositeStraight slice; always copy.
    diff_base: ?[]u32 = null,
    /// Block placement for paste/move (default over=keep transparency=leave art below). Toggled in the right pane.
    blend_mode: core.selection.Blend = .over,
    active_kind: ToolKind = .pen,
    /// ── Viewport. view_zoom is rational Zoom; cam_cx/cy are continuous canvas coords under the view center ──
    view_zoom: Zoom = Zoom.default(),
    /// Continuous canvas coords from the canvas top-left (view center points here). Starts at document center.
    cam_cx: f32 = @as(f32, @floatFromInt(DEFAULT_CANVAS_W)) / 2.0,
    cam_cy: f32 = @as(f32, @floatFromInt(DEFAULT_CANVAS_H)) / 2.0,
    /// Previous frame's canvas area rect (for Fit zoom; canvasBlitRect updates every frame)
    last_area: ?core.Rect = null,
    /// Space held (updated on key_down/up). Space+left-drag pans
    space_down: bool = false,
    /// Pan drag in progress. Anchor latched at start (exclusive with paint capture)
    pan_active: bool = false,
    /// Input kind that started the pan (so backends that omit Cmd on move still finish the drag)
    pan_kind: PanKind = .space_left,
    pan_anchor_mouse: core.Vec2 = .{ .x = 0, .y = 0 },
    pan_anchor_cam_x: f32 = 0,
    pan_anchor_cam_y: f32 = 0,
    /// Pending KP_ADD/KP_SUBTRACT zoom steps. updateViewport applies zoomAround at the cursor.
    pending_zoom_delta: i32 = 0,
    /// ── Minimap. Thumbnail regenerates on edit events only; drag moves the camera ──
    minimap: minimap_mod.MiniMapCache = .{},
    minimap_drag_active: bool = false,
    /// Soft overlay (tool glyph + brush footprint outline ring) ──
    /// Raw screen coords while hovering (tool-badge anchor). Some only when in_canvas and not busy
    /// (set every frame by updateCursorAndHover).
    hover_screen: ?core.Vec2 = null,
    /// Canvas pixel coords while hovering (footprint-ring anchor). Via `core.screenToCanvas` (null outside
    /// real canvas pixels), so the ring alone stays hidden over letterbox / outside the canvas.
    hover_cell: ?core.Vec2 = null,
    /// Last cursor shape requested from the OS (change detection + `cursor` probe).
    cursor_shape: platform.CursorShape = .default,
    /// Edge-cell cache for the brush footprint outline ring (recomputed only when (size,hardness) change).
    brush_edges: brush_edge_cache.EdgeCache = .{},
    /// Ephemeral presence state (not held in Document/CommandLog).
    presence: actions.PresenceStore = .{},
    /// ── PanelHost. left/right/bottom + center. Persisted via Preferences ──
    panels: [6]gui.Panel = undefined,
    panel_host: gui.PanelHost = undefined,
    preferences: appshell.preferences.Preferences = undefined,
    /// Layers-only scroll
    layers_scroll: gui.Vec2f = .{},
    /// Fixed Layers ScrollArea viewport height (content-based; starts at one row).
    layers_viewport_h: i32 = LAYERS_VIEWPORT_ROW_MIN,
    /// For `digest panels`: written by cachePanelsProbe after the previous frame settles.
    panels_probe_fb_h: i32 = 0,
    panels_probe_bottom: i32 = 0,
    panels_probe_ok: bool = false,
    panels_probe_slot: ?PanelProbeRect = null,
    panels_probe_color: ?PanelProbeRect = null,
    panels_probe_palette: ?PanelProbeRect = null,
    panels_probe_tool: ?PanelProbeRect = null,
    panels_probe_layers: ?PanelProbeRect = null,
    /// Buffer for the dynamic Tool Options title (pointed to by Panel.title; stable name is separate)
    tool_options_title_buf: [64]u8 = undefined,
    tool_options_title_len: usize = 0,
    /// Timeline UI state
    timeline_scroll: gui.Vec2f = .{},
    timeline_playing: bool = false,
    timeline_fps: f32 = 10.0,
    timeline_last_advance: f64 = 0,
    timeline_target_layer: usize = 0,
    timeline_target_frame: u32 = 0,
    /// Onion skin. Display-only.
    onion_enabled: bool = false,
    onion_count: u32 = 1,
    onion_buf: []u32 = &.{},
    onion_scratch: []u32 = &.{},
    /// Pixel grid overlay. Display-only (view state; not routed through netsync).
    grid_enabled: bool = false,
    /// Loupe (magnifier) overlay. Display-only (view state; not routed through netsync).
    loupe_enabled: bool = false,
    /// Per-frame transient: the composite buffer this frame actually blitted to the canvas
    /// (post onion-skin blend when onion is active). Set once in the draw section below; the
    /// loupe overlay reads it later the same frame so the magnifier matches exactly what was
    /// drawn, without re-rasterizing a bezier/move preview a second time. Empty before the first
    /// frame that reaches the draw section.
    loupe_source_composite: []const u32 = &.{},
    /// Brush-parameter UI state (bridges Slider *i32/*f32 vs Brush u32/u8).
    brush_size_i32: i32 = 8,
    brush_opacity_i32: i32 = 255,
    brush_hardness_f32: f32 = 1.0,
    /// Fill color-tolerance UI state (bridges Slider *i32 vs u8; same pattern as brush_size_i32).
    fill_tolerance_i32: i32 = 0,
    /// Editable palette (colors.len>=1). Drawing color = palette.current().
    palette: palette_mod.Palette,
    /// In-edit HSV state. Re-sync RGB→HSV only after selection change/load (keeps hue when s==0).
    edit_h: f32 = 0,
    edit_s: f32 = 0,
    edit_v: f32 = 0,
    /// selected already synced to HSV. Resync when null/mismatch.
    edit_synced_for: ?usize = null,
    /// For UI Repl: color at swatch-select time (keeps `from` even if applyEditColor changes the swatch).
    repl_source: ?u32 = null,
    running: bool = true,
    /// Re-entrancy guard for the frame body (stops double-run of redraw callback vs main loop).
    in_frame: bool = false,
    /// Window value copy kept in onWindowReady for the redraw callback (FrameCtx role).
    redraw_win: ?platform.Window = null,
    /// Borrowed Window for appshell title updates. The runtime owns the window.
    os_window: ?*platform.Window = null,
    /// Current PNG save path (gpa-owned). Cmd+S overwrites here; updated on successful save/open dialogs.
    current_path: ?[]u8 = null,
    /// Current .pix project save path (gpa-owned; managed separately from PNG current_path).
    current_project_path: ?[]u8 = null,
    /// DocumentHost is authoritative for .pix lifecycle. Legacy fields sync existing UI/action.
    host: appshell.document_host.DocumentHost = undefined,
    data_dir: std.Io.Dir = undefined,
    autosave_dir: std.Io.Dir = undefined,
    recent: appshell.recent_files.RecentFiles = undefined,
    autosave: appshell.autosave.Controller = undefined,
    recovery: ?appshell.autosave.Candidate = null,
    /// History-journal directory inside the application data directory (native only).
    history_dir: std.Io.Dir = undefined,
    /// Journal for the document currently open; null while the document is unsaved.
    history_store: ?appshell.history_journal.NativeStore = null,
    /// Composition of the command log and undo stack onto the journal.
    history_journal: history_persist.Persist = undefined,
    /// Outcome of the last restore attempt, reported by `digest appshell`.
    history_restore: history_persist.LoadOutcome = .{ .status = .no_store },
    pending_png_path: ?[]u8 = null,
    png_import_pending: bool = false,
    /// For the `new W H` confirmation flow (consumed by hostNewDocument).
    pending_new_size: ?struct { w: u32, h: u32 } = null,
    /// Size-dialog body (TextBuffers managed in appInit/appDeinit).
    size_dialog_storage: SizeDialogState = undefined,
    /// null=closed. While open, `&size_dialog_storage` (not rebuilt every frame).
    size_dialog: ?*SizeDialogState = null,
    title_cache: [std.fs.max_path_bytes + 64]u8 = undefined,
    title_cache_len: usize = 0,
    /// Palette .gpl save path (gpa-owned; managed separately from PNG current_path).
    palette_path: ?[]u8 = null,
    /// Pending file op to run at the safe point (set during frame work; consumed after unlock).
    pending_file_op: ?FileOp = null,
    /// Latch for digest menu `last_op`: most recently dispatched FileOp.
    /// Kept until the next dispatch (informational only. True pending state is dialog_op/pending_file_op).
    /// Under headless, runPendingFileOp consumes in the same frame, so "menu selection queued a FileOp"
    /// is observed via last_op.
    menu_pending_probe: ?FileOp = null,
    /// Open/closed state of the GUI-fallback menu bar.
    menu_bar_state: gui.MenuBarState = .{},
    /// Command table rebuilt every frame (enabled/checked; same role as native updateMenu).
    menu_commands: [MENU_CMD_CAP]platform.Command = undefined,
    menu_command_count: usize = 0,
    /// Whether native menu is enabled (set in onWindowReady; false for headless/swift/metal).
    native_menu_active: bool = false,
    /// Snapshot for the native updateMenu dirty gate (enabled/checked/id/label).
    native_menu_snap: [MENU_CMD_CAP]NativeMenuSnap = undefined,
    native_menu_snap_count: usize = 0,
    native_menu_registered: bool = false,
    /// FileOp while a wasm file picker is in flight.
    /// While DialogPending, only this op is retried; other requests queued on pending_file_op are discarded
    /// (e.g. Cmd+Shift+S while waiting on Cmd+O must not feed the picked path into save_as).
    dialog_op: ?FileOp = null,
    save_msg_buf: [128]u8 = undefined,
    save_msg_len: usize = 0,
    save_msg_until: f64 = 0,
    /// Inline layer-name edit state machine. While `rename_in.active` is true,
    /// the main-loop event pump routes only char_input/ENTER/ESCAPE/BACKSPACE here and
    /// blocks other keys and gui pushEvent (so B/E tool shortcuts do not fire while typing).
    rename_in: layer_rename_input.LayerRenameInput = .{},
    /// Inline text-layer content edit state machine. Symmetric with `rename_in`
    /// (only one may be active; `beginTextEdit`/`beginRenameLayer` explicitly cancel each other).
    text_in: text_content_input.TextContentInput = .{},
    /// IME preedit snapshot (latest-wins). Updated on the frame that receives composition_changed.
    preedit_buf: [1024]u8 = undefined,
    preedit_len: usize = 0,
    preedit_cursor: usize = 0,
    composition_dirty: bool = false,
    composition_rect: ?CompositionCaretRect = null,

    /// ── command model. Single log of who (local_user/local_agent) did what ──
    /// Always on, fixed capacity (no alloc). Independent of transport (same path for harness replay, copilot,
    /// and normal launch). Recording is event-time only (off the hot path).
    cmd_log: platform.command.CommandLog = .{},
    /// dispatcher/log are wired in main() (need &app in ctx, so not field-defaultable).
    cmd_exec: platform.command.Executor = undefined,
    /// recipe_replay in-progress flag (rejects nested `recipe_replay`).
    recipe_replaying: bool = false,
    /// UI-stroke point buffer via canvas_input (event-time append from press through release; fixed cap
    /// shared with actions.MAX_STROKE_POINTS). Consecutive identical points are not appended (same-point move is a draw no-op).
    ui_stroke_pts: [actions.MAX_STROKE_POINTS]actions.Point = undefined,
    ui_stroke_len: usize = 0,
    /// On overflow this stroke is not recorded (recording past MAX_STROKE_POINTS would make redo re-dispatch
    /// fail with TooManyPoints; the Op remains on the legacy UndoStack so existing undo UI can still reverse it).
    ui_stroke_overflow: bool = false,
    /// Detects unrecorded undoable edits: at record sites (noteUndo/
    /// recordUiStroke/legacy redo) follow `doc.undo.next_handle`, and at frame end if
    /// `next_handle > last_seen_handle` treat it as "an undoable push missed CommandLog"
    /// and `bumpEpoch(.local_user)` (one O(1) integer compare per frame).
    last_seen_handle: u64 = 1,
    /// Cache for the history-panel display (must not outlive CommandLog mutation, so
    /// fully rebuilt on dirty. No alloc; fixed MAX_CMD_LOG array).
    history_entries: [platform.command.MAX_CMD_LOG]history_summary.HistoryEntry = undefined,
    history_count: u32 = 0,
    history_dirty: bool = true,
    history_seen_seq: u64 = 1,
    /// netsync peer catalog/slot metadata revision (full history-cache rebuild on change).
    history_seen_peer_revision: u64 = 0,
    /// Fixed ring of history-row thumbnails (generated on events only; per-frame work is blit only).
    history_thumbs: [platform.command.MAX_CMD_LOG][history_thumbnail.THUMB_PIXELS]u32 = undefined,
    history_thumb_meta: [platform.command.MAX_CMD_LOG]history_thumbnail.HistoryThumbMeta = @splat(.{}),
    /// Effective parameters latched at capture start (material for canonical args).
    ui_stroke_layer_id: u64 = 1,
    ui_stroke_tool: ToolKind = .pen,
    ui_stroke_color: u32 = 0,
    ui_stroke_size: u32 = 4,
    ui_stroke_opacity: u8 = 255,
    ui_stroke_hardness: u8 = 255,

    /// netsync-relay-only wire point chunks (solo uses ui_stroke_* only; preview is a separate path).
    /// All chunks are sync-PROPOSEd on release, so there is no cross-frame send queue.
    relay_stroke: bool = false,
    relay_active_pts: [actions.RELAY_STROKE_CHUNK_POINTS]actions.Point = undefined,
    relay_active_len: usize = 0,
    relay_active_continuation: bool = false,
    /// Finalized chunks (mid-drag flush + final release piece). Elements are copy-owned.
    relay_chunks: std.ArrayListUnmanaged(RelayStrokeChunk) = .empty,

    /// Whether the selected layer is text kind (guards against direct raster edits on text layers.
    /// Text-layer pixels are the rasterization of TextParams — that invariant
    /// (see the `TextParams` doc comment in libs/paint/src/canvas.zig) is enforced by rejecting
    /// Pen/Eraser/Brush/Fill/Bezier/selection (cut/paste/move) write paths here
    /// (after Rasterize commits and kind becomes raster, normal drawing is allowed again).
    fn selectedLayerIsText(self: *const App) bool {
        return self.canvas.selected_layer < self.canvas.layers.items.len and
            self.canvas.layers.items[self.canvas.selected_layer].kind == .text;
    }

    /// Apply `gui_font.systemBytes()` onto `doc.active_view`. A fresh Document
    /// (`core.Document.init` / `document_io.loadDocument`) starts with
    /// `active_view.system_font` as the default `null`, so this must be called right after creating/replacing
    /// a Document (`main()` startup + `doOpenProject`). `preview_canvas` is out of scope because it never
    /// calls `addTextLayer`/`setLayerTextParams`. Event-time / init-time only
    /// (not every frame). After cel-grid migration the editable view of the active frame
    /// is the single `doc.active_view` (`resyncActiveView` never
    /// touches `system_font`, so one assignment here keeps it for the Document lifetime).
    fn applySystemFont(self: *App) void {
        self.doc.active_view.system_font = self.gui_font.systemBytes();
    }

    /// Currently UI-selected Tool (fat pointer; latched by canvas_input when capture starts)
    fn activeTool(self: *App) core.Tool {
        return switch (self.active_kind) {
            .pen => self.pen.tool(),
            .eraser => self.eraser.tool(),
            .brush => self.brush.tool(),
            .bezier => self.pen.tool(), // bezier is an independent path and does not go through canvas_input (unreachable fallback)
            .select => self.pen.tool(), // select is also an independent path (unreachable fallback)
            .fill => self.fill.tool(),
            .eyedropper => self.pen.tool(), // eyedropper is also an independent path (unreachable fallback; actionStroke rejects it explicitly)
            .line, .rect, .ellipse => self.pen.tool(), // shape is also an independent path (unreachable fallback)
        };
    }

    /// Reflect UI pixel_perfect / symmetry into StrokeRecorder (call before stroke/shape start).
    /// pixel_perfect is Pen-only (current Pen is fixed at size=1).
    fn syncRecorderModes(self: *App) void {
        self.recorder.pixel_perfect = self.pixel_perfect and self.active_kind == .pen;
        self.recorder.symmetry = self.symmetry;
    }

    /// Single chokepoint for tool switches (all writes to active_kind go through here).
    /// No switch during capture / selection-drag / shape-drag / eyedropper picking (do not strand an in-flight op).
    /// Leaving .bezier cancels the unfinished path. Leaving .select discards an in-flight drag (selection kept).
    /// Leaving a shape cancels an in-flight drag.
    fn setActiveKind(self: *App, next: ToolKind) void {
        if (self.input.capturing or self.sel_in.state != .idle or self.shape_in.state != .idle or self.eye_in.picking) return;
        if (self.active_kind == .bezier and next != .bezier) {
            self.bezier_editor.update(self.gpa, .cancel);
        }
        if (self.active_kind.isShape() and !next.isShape()) {
            self.shape_in.cancel();
        }
        if (next != .select) self.sel_in.discardFloat(self.gpa); // Leaving the select tool → discard the float (canvas stays at its final form)
        // Sync the shape-tool kind into shape_in
        if (next.isShape()) {
            self.shape_in.kind = switch (next) {
                .line => .line,
                .rect => .rect,
                .ellipse => .ellipse,
                else => unreachable,
            };
        }
        self.active_kind = next;
    }

    /// Set zoom and reset the camera to document center (for 0/F).
    fn setZoomCentered(self: *App, z: Zoom) void {
        self.view_zoom = z;
        self.cam_cx = @as(f32, @floatFromInt(self.doc.width)) / 2.0;
        self.cam_cy = @as(f32, @floatFromInt(self.doc.height)) / 2.0;
    }

    /// Change zoom keeping the current view center fixed (no camera jump): cam_cx/cam_cy are
    /// exactly what `zoomAround` computes when its focus point is the view center itself (the
    /// `(fxf - c.sx)` and `(fyf - c.sy)` terms both vanish), so this is that same math with no
    /// screen-position input required. For a control not anchored to a screen position (the zoom
    /// slider) — unlike `setZoomCentered`, which recenters on the *document* center instead.
    fn zoomInPlace(self: *App, z: Zoom) void {
        if (z.eql(self.view_zoom)) return;
        self.view_zoom = z;
    }

    /// Change zoom with screen focus (fx,fy) as the fixed point (scroll / +/-).
    /// If the cursor is outside the view, use the view center as the focus. canvasBlitRect performs clamp.
    fn zoomAround(self: *App, z: Zoom, fx: i32, fy: i32) void {
        const new_zoom = z;
        const old_zoom = self.view_zoom;
        if (new_zoom.eql(old_zoom)) return;
        const area = self.last_area orelse {
            self.view_zoom = new_zoom;
            return;
        };
        const c = areaCenterF(area);
        const in_area = fx >= area.x and fy >= area.y and fx < area.x + area.w and fy < area.y + area.h;
        const fxf: f32 = if (in_area) @floatFromInt(fx) else c.sx;
        const fyf: f32 = if (in_area) @floatFromInt(fy) else c.sy;
        const oz = old_zoom.scaleF32();
        const nz = new_zoom.scaleF32();
        const focus_cx = self.cam_cx + (fxf - c.sx) / oz;
        const focus_cy = self.cam_cy + (fyf - c.sy) / oz;
        self.cam_cx = focus_cx - (fxf - c.sx) / nz;
        self.cam_cy = focus_cy - (fyf - c.sy) / nz;
        self.view_zoom = new_zoom;
    }

    /// Largest zoom that fits the canvas in the view (Fit; sub-1 uses 1/2..1/4). Camera resets to center.
    fn fitZoom(self: *App) void {
        const area = self.last_area orelse return;
        self.setZoomCentered(Zoom.fit(area.w, area.h, self.doc.width, self.doc.height));
    }

    fn setSaveMsg(self: *App, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.save_msg_buf, fmt, args) catch &self.save_msg_buf;
        self.save_msg_len = msg.len;
        self.save_msg_until = platform.getTime() + SAVE_MSG_DURATION;
    }

    /// Push the appshell title to the OS. Title updates only on state transitions, never every frame.
    fn refreshTitle(self: *App) void {
        var doc_title_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
        const doc_title = self.host.title(&doc_title_buf);
        var title_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
        const title = std.fmt.bufPrintZ(&title_buf, "Pixie — {s}", .{doc_title}) catch return;
        if (self.title_cache_len == title.len and std.mem.eql(u8, self.title_cache[0..self.title_cache_len], title[0..title.len])) return;
        @memcpy(self.title_cache[0..title.len], title[0..title.len]);
        self.title_cache_len = title.len;
        if (self.os_window) |win| win.setTitle(title);
    }

    fn setProjectPath(self: *App, path: ?[]const u8) !void {
        const owned = if (path) |value| try self.gpa.dupe(u8, value) else null;
        if (self.current_project_path) |old| self.gpa.free(old);
        self.current_project_path = owned;
    }

    /// Event boundary that syncs DocumentHost path and autosave ID with the legacy pixie fields.
    fn syncProjectState(self: *App) void {
        self.setProjectPath(self.host.currentPath()) catch @panic("syncProjectState: OOM");
        self.autosave.setPath(self.host.currentPath()) catch @panic("syncProjectState: OOM");
        if (self.host.isDirty()) self.autosave.markDirty(platform.getTime());
        self.refreshTitle();
    }

    /// Common entry for edit events that change document contents. Not called for selection/tool/zoom.
    fn markProjectDirty(self: *App) void {
        self.host.markDirty();
        self.autosave.markDirty(platform.getTime());
        self.refreshTitle();
        self.minimap.invalidate();
    }

    fn clearProjectAfterSave(self: *App) void {
        if (comptime appshell_dir_supported) {
            self.autosave.clear() catch |err| self.setSaveMsg("Autosave clear failed: {s}", .{@errorName(err)});
        }
        self.syncProjectState();
    }

    fn saveMsg(self: *const App) ?[]const u8 {
        if (self.save_msg_len == 0 or platform.getTime() >= self.save_msg_until) return null;
        return self.save_msg_buf[0..self.save_msg_len];
    }

    fn editingBlocked(self: *const App) bool {
        return self.input.capturing or self.bezier_editor.isEditing() or self.sel_in.state != .idle or self.shape_in.state != .idle;
    }

    /// After a Document size change, rebuild recorder / preview / onion / diff_base for the new size.
    /// Shared by loadProjectPath / netsyncImport / doResize / doNew (prevents dangling pointers).
    fn rebuildRuntimeForDocSize(self: *App) !void {
        const w = self.doc.width;
        const h = self.doc.height;
        const n = @as(usize, w) * @as(usize, h);

        var new_recorder = try core.StrokeRecorder.init(self.gpa, w, h);
        errdefer new_recorder.deinit(self.gpa);
        new_recorder.pixel_perfect = self.recorder.pixel_perfect;
        new_recorder.symmetry = self.recorder.symmetry;

        var new_preview = try core.Canvas.init(self.gpa, w, h);
        errdefer new_preview.deinit();

        var new_preview_rec = try core.StrokeRecorder.init(self.gpa, w, h);
        errdefer new_preview_rec.deinit(self.gpa);

        const new_onion = try self.gpa.alloc(u32, n);
        errdefer self.gpa.free(new_onion);
        const new_scratch = try self.gpa.alloc(u32, n);
        errdefer self.gpa.free(new_scratch);

        self.recorder.deinit(self.gpa);
        self.recorder = new_recorder;
        self.preview_canvas.deinit();
        self.preview_canvas = new_preview;
        self.preview_rec.deinit(self.gpa);
        self.preview_rec = new_preview_rec;

        self.gpa.free(self.onion_buf);
        self.onion_buf = new_onion;
        self.gpa.free(self.onion_scratch);
        self.onion_scratch = new_scratch;

        if (self.diff_base) |b| {
            self.gpa.free(b);
            self.diff_base = null;
        }
        self.minimap.invalidate();
    }

    /// Content-preserving resize. Sole entry for GUI/action.
    fn doResize(self: *App, new_w: u32, new_h: u32) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        if (platform.netsyncActive()) return error.RejectedWhileSynced;
        try actions.validateCanvasSize(new_w, new_h);
        if (self.doc.layers.items[self.doc.selected_layer].kind != .text) {
            self.doc.commitActiveLayerToCel(self.gpa, self.doc.selected_layer);
        }
        try self.doc.resize(self.gpa, new_w, new_h);
        self.invalidateHistoryAfterDocReset();
        self.canvas = self.doc.activeCanvas();
        try self.rebuildRuntimeForDocSize();
        self.doc.resyncActiveView(self.gpa);
        self.clampTimelineTarget();
        self.canvas.clearSelection();
        self.sel_in.discardFloat(self.gpa);
        self.syncPreviewCanvas();
        self.markProjectDirty();
    }

    /// Replace with a blank Document of the given size. Sole entry for GUI/action.
    /// Clearing project path / PNG / autosave follows hostNewDocument rules.
    fn doNew(self: *App, new_w: u32, new_h: u32) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        if (platform.netsyncActive()) return error.RejectedWhileSynced;
        try actions.validateCanvasSize(new_w, new_h);
        var new_doc = try core.Document.init(self.gpa, new_w, new_h);
        errdefer new_doc.deinit();
        const preserved_next_handle = self.doc.undo.next_handle;
        self.doc.deinit();
        self.doc = new_doc;
        self.doc.undo.next_handle = preserved_next_handle;
        self.invalidateHistoryAfterDocReset();
        self.canvas = self.doc.activeCanvas();
        try self.rebuildRuntimeForDocSize();
        self.doc.resyncActiveView(self.gpa);
        self.clampTimelineTarget();
        self.applySystemFont();
        self.canvas.clearSelection();
        self.sel_in.discardFloat(self.gpa);
        self.loadPaletteFromDoc();
        self.syncPreviewCanvas();
    }

    fn replaceSizeDialogBuf(buf: *gui.TextBuffer, text: []const u8) !void {
        buf.bytes.clearRetainingCapacity();
        try buf.bytes.appendSlice(buf.alloc, text);
    }

    /// Open the New Size / Resize Canvas dialog (command only opens; it does not apply).
    fn openSizeDialog(self: *App, mode: SizeDialogMode) void {
        // Double-guard against reentrant open (symmetric with the guard at the top of dispatchCommand).
        if (self.size_dialog != null) return;
        if (self.recovery != null or self.host.confirmation() != .none) return;
        if (platform.netsyncActive()) return;
        var wbuf: [16]u8 = undefined;
        var hbuf: [16]u8 = undefined;
        const ws = std.fmt.bufPrint(&wbuf, "{d}", .{self.doc.width}) catch return;
        const hs = std.fmt.bufPrint(&hbuf, "{d}", .{self.doc.height}) catch return;
        replaceSizeDialogBuf(&self.size_dialog_storage.width_buf, ws) catch return;
        replaceSizeDialogBuf(&self.size_dialog_storage.height_buf, hs) catch return;
        self.size_dialog_storage.mode = mode;
        self.size_dialog_storage.clearError();
        self.size_dialog = &self.size_dialog_storage;
    }

    fn closeSizeDialog(self: *App) void {
        self.size_dialog = null;
    }

    /// OK: parse → validate → doResize/doNew (confirmation path). On failure keep the dialog open.
    fn confirmSizeDialog(self: *App) void {
        const dlg = self.size_dialog orelse return;
        dlg.clearError();
        var args_buf: [48]u8 = undefined;
        const args = std.fmt.bufPrint(&args_buf, "{s} {s}", .{ dlg.width_buf.slice(), dlg.height_buf.slice() }) catch {
            dlg.setError("InvalidSize");
            return;
        };
        const sz = actions.parseCanvasSize(args) catch |err| {
            dlg.setError(@errorName(err));
            return;
        };
        actions.validateCanvasSize(sz.w, sz.h) catch |err| {
            dlg.setError(@errorName(err));
            return;
        };
        if (self.editingBlocked()) {
            dlg.setError("EditingBlocked");
            return;
        }
        if (platform.netsyncActive()) {
            dlg.setError("RejectedWhileSynced");
            return;
        }
        switch (dlg.mode) {
            .resize => {
                self.doResize(sz.w, sz.h) catch |err| {
                    dlg.setError(@errorName(err));
                    return;
                };
                self.closeSizeDialog();
            },
            .new_size => {
                self.pending_new_size = .{ .w = sz.w, .h = sz.h };
                const result = self.requestNewDocument() catch |err| {
                    self.pending_new_size = null;
                    dlg.setError(@errorName(err));
                    return;
                };
                if (result == .canceled) {
                    self.pending_new_size = null;
                    return;
                }
                // Both confirmation and applied close the dialog (do not open alongside the overlay)
                self.closeSizeDialog();
            },
        }
    }

    /// During netsync, if editingBlocked, interrupt local edits (capture / bezier / select drag)
    /// and allow the apply (so a host-authoritative remote COMMIT does not fail-soft disconnect).
    /// Solo still returns EditingBlocked as before.
    fn checkEditingAllowed(self: *App) error{EditingBlocked}!void {
        if (!self.editingBlocked()) return;
        if (!platform.netsyncActive()) return error.EditingBlocked;
        self.interruptLocalEditForNetsync();
    }

    /// Discard in-flight local edits (only capture/fill that dirty canvas pixels are rolled back;
    /// bezier / select drag do not dirty the canvas before commit, so cancel only).
    fn interruptLocalEditForNetsync(self: *App) void {
        if (self.input.capturing) {
            self.recorder.abandon(self.canvas, self.gpa);
            if (self.fill.pending) |pd| {
                const pixels = self.canvas.layerPixels(pd.layer_idx);
                for (pd.diffs) |d| pixels[d.idx] = d.before;
                self.gpa.free(pd.diffs);
                self.fill.pending = null;
            }
            self.uiStrokeDiscard();
            self.input.cancel();
        }
        if (self.bezier_editor.isEditing()) {
            // Same internal path as ESC (discard unfinished path). Also clear the in-drag flag.
            self.bezier_editor.update(self.gpa, .cancel);
            self.bez_in.in_drag = false;
        }
        if (self.sel_in.state != .idle) {
            // Same as ESC drag interrupt (real layer is unchanged during drag → no pixel rollback).
            self.sel_in.cancel(self.gpa);
        }
        if (self.shape_in.state != .idle) {
            self.shape_in.cancel(); // Preview only; does not dirty the canvas
        }
        self.setSaveMsg("netsync: 進行中の編集は相手の操作適用のため中断されました", .{});
    }

    /// Whether the soft overlay (tool glyph + footprint ring) should be hidden.
    /// Hide while a real draw/input op is in progress (stroke capture, selection drag, bezier handle drag, pan)
    /// (same "hide while dragging" style as the bezier hover preview). This also prevents
    /// `brush_edges.refresh()` (which re-runs buildDab via Brush.footprint()) from being called mid-Brush stroke,
    /// preserving the existing contract that the footprint is latched on down and immutable during the stroke.
    fn isPointerBusy(self: *const App) bool {
        return self.input.capturing or self.sel_in.state != .idle or self.shape_in.state != .idle or self.bez_in.in_drag or self.pan_active or self.minimap_drag_active or self.eye_in.picking;
    }

    /// Run the pending file op once at the safe point (after framebuffer unlock and input update).
    /// On `error.DialogPending` (wasm file picker wait), keep that op in `dialog_op` and retry next frame.
    /// While a dialog is pending, discard other requests queued on `pending_file_op` (prevents mis-delivering the picker result).
    /// Otherwise (success, cancel null, or other error already shown) clear `dialog_op` and consume it.
    fn runPendingFileOp(self: *App) void {
        // Take up an async system-clipboard paste (color #RRGGBB) at the safe point.
        if (platform.clipboardTakePaste()) |text| {
            self.applySystemClipboardColor(text);
        }

        // While a dialog is in flight, prefer dialog_op. Otherwise start pending at most once.
        const op = self.dialog_op orelse (self.pending_file_op orelse return);
        // Discard other requests queued during dialog wait (no notice; intent: do not feed the picker result to another op).
        self.pending_file_op = null;
        const pending = switch (op) {
            .save => self.doSave(),
            .save_as => self.doSaveAs(),
            .open => self.doOpen(),
            .save_palette => self.doSavePalette(),
            .load_palette => self.doLoadPalette(),
            .save_project => self.doSaveProject(),
            .open_project => self.doOpenProject(),
            .export_seq => self.doExportSeq(),
            .export_sheet => self.doExportSheet(),
            .confirm_save_as => self.doConfirmSaveAs(),
        };
        if (pending == .dialog_pending) {
            self.dialog_op = op;
            return;
        }
        self.dialog_op = null;
    }

    /// Result of a file op. `.dialog_pending` means waiting on the wasm open picker.
    const FileOpResult = enum { done, dialog_pending };

    /// Interpret system-clipboard text as a color (`#RRGGBB` / `RRGGBB`; anything else is ignored).
    fn applySystemClipboardColor(self: *App, text: []const u8) void {
        var s = std.mem.trim(u8, text, " \t\r\n");
        if (s.len > 0 and s[0] == '#') s = s[1..];
        if (s.len != 6) return;
        const rgb = std.fmt.parseInt(u32, s, 16) catch return;
        self.doSetColorHex(0xFF000000 | rgb);
    }

    /// Put the current drawing color on the system clipboard as `#RRGGBB` (wasm Clipboard API; native is a no-op).
    fn copySystemColor(self: *App) void {
        const c = self.pen.color;
        const r: u8 = @truncate(c >> 16);
        const g: u8 = @truncate(c >> 8);
        const b: u8 = @truncate(c);
        var buf: [7]u8 = undefined;
        const hex = std.fmt.bufPrint(&buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b }) catch return;
        platform.clipboardWrite(hex);
    }

    /// Resolve the selected swatch color from the in-edit HSV and apply it to the palette and drawing color (pen).
    /// Call only on frames where edit_synced_for matches palette.selected (avoids overwrite on the selection-change frame).
    fn applyEditColor(self: *App) void {
        const c: u32 = @bitCast(gui.Color.fromHsv(self.edit_h, self.edit_s, self.edit_v));
        self.palette.setSelectedColor(c);
        self.pen.color = c;
        self.brush.color = c; // Brush drawing color also follows the palette edit color
        self.fill.color = c; // Fill paint color also follows the palette edit color
    }

    /// Set the palette selection color directly (for action `set_color`). Bypasses the HSV widgets;
    /// the direct assign forces `edit_synced_for = null` so the next frame's `syncEditHsv` re-syncs
    /// (otherwise touching an HSV slider would roll the color back from stale HSV). Like `applyEditColor`,
    /// no editingBlocked guard (color picks always apply in the existing UI regardless of editingBlocked).
    fn doSetColorHex(self: *App, color: u32) void {
        self.palette.setSelectedColor(color);
        self.pen.color = color;
        self.brush.color = color;
        self.fill.color = color;
        self.edit_synced_for = null;
    }

    /// Sync App.palette.colors → doc.palette (before .pix encode / netsync export).
    fn syncPaletteToDoc(self: *App) void {
        self.doc.palette.clearRetainingCapacity();
        self.doc.palette.ensureTotalCapacity(self.gpa, self.palette.colors.items.len) catch @panic("syncPaletteToDoc: OOM");
        for (self.palette.colors.items) |c| self.doc.palette.appendAssumeCapacity(c);
    }

    /// Rebuild App.palette from doc.palette (DB16 if empty; after load / netsync import).
    fn loadPaletteFromDoc(self: *App) void {
        self.palette.colors.clearRetainingCapacity();
        if (self.doc.palette.items.len == 0) {
            // DB16 init (same contents as initDb16; reuse the existing gpa-backed colors)
            self.palette.colors.ensureTotalCapacity(self.gpa, palette_mod.db16.len) catch @panic("loadPaletteFromDoc: OOM");
            for (palette_mod.db16) |rgb| self.palette.colors.appendAssumeCapacity(palette_mod.rgbToCanvas(rgb));
        } else {
            self.palette.colors.ensureTotalCapacity(self.gpa, self.doc.palette.items.len) catch @panic("loadPaletteFromDoc: OOM");
            for (self.doc.palette.items) |c| self.palette.colors.appendAssumeCapacity(c);
        }
        self.palette.selected = 0;
        const c = self.palette.current();
        self.pen.color = c;
        self.brush.color = c;
        self.fill.color = c;
        self.edit_synced_for = null;
        self.repl_source = null;
    }

    /// Replace the whole palette color list (shared by palette_set / palette_ramp / palette_from_png; not undoable).
    fn doReplacePalette(self: *App, colors: []const u32) void {
        std.debug.assert(colors.len >= 1);
        self.palette.colors.clearRetainingCapacity();
        self.palette.colors.ensureTotalCapacity(self.gpa, colors.len) catch @panic("doReplacePalette: OOM");
        for (colors) |c| self.palette.colors.appendAssumeCapacity(c);
        self.palette.select(0); // clamp selected
        const cur = self.palette.current();
        self.pen.color = cur;
        self.brush.color = cur;
        self.fill.color = cur;
        self.edit_synced_for = null;
        self.repl_source = null;
        self.markProjectDirty();
    }

    /// Replace from→to colors on the given layer (UI Repl / action replace_color; undoable = .paint Op).
    /// Caller resolves layer_idx (action uses a layer ref; UI uses selected).
    fn doReplaceColor(self: *App, layer_idx: usize, from: u32, to: u32) !u32 {
        if (self.editingBlocked()) return error.EditingBlocked;
        if (layer_idx >= self.doc.layers.items.len) return error.OutOfRange;
        if (self.doc.layers.items[layer_idx].kind == .text) return error.TextLayerSelected;
        return self.doc.pushReplaceColor(self.gpa, layer_idx, from, to) catch |err| switch (err) {
            error.TextLayerSelected => return error.TextLayerSelected,
        };
    }

    /// Owner tag for an undo op (pixie convention for `UndoStack.owners`:
    /// an op-side tag so ownership is not misread after CommandLog ring eviction drops the record).
    /// unknown means "an as-yet unrecorded push"; end-of-frame `checkUnrecordedEdits` settles it
    /// as user (agent ops are always tagged in the same event via an action, so the only pushes that
    /// stay unknown until frame end are user UI ops).
    const OP_OWNER_UNKNOWN: u8 = 0;
    const OP_OWNER_USER: u8 = 1;
    const OP_OWNER_AGENT: u8 = 2;

    /// Tag owner on the undo_ref ops of normal records recorded at/after `first_seq`
    /// (the pre-call `cmd_log.next_seq`) — cleanup after executeAction / redoOne; once the record's actor is
    /// known, copy it onto the op side).
    fn tagOwnersFromRecords(self: *App, first_seq: u64, tag: u8) void {
        var i: u32 = self.cmd_log.filled;
        while (i > 0) {
            i -= 1;
            const rec = self.cmd_log.recordAt(i);
            if (rec.seq < first_seq) break; // seq is monotonic (no older record is a tag target)
            if (rec.kind != .normal) continue;
            const ref = rec.undo_ref orelse continue;
            self.doc.undo.setOwner(ref, tag);
        }
    }

    /// Invalidate stale undo/redo candidates on CommandLog after a document load/reset.
    /// The undo side expires naturally via handle monotonicity + `hasHandle=false` (canUndo), but
    /// **the redo side (revert records) must bump epoch** or old-document commands would re-run
    /// against the new document — bump both actors' epochs explicitly.
    fn invalidateHistoryAfterDocReset(self: *App) void {
        self.cmd_exec.bumpEpoch(.local_user);
        self.cmd_exec.bumpEpoch(.local_agent);
        self.last_seen_handle = self.doc.undo.next_handle;
        // Invalidate fixed visual meta so old-document thumbnails do not linger on the new document.
        for (&self.history_thumb_meta) |*m| m.clear();
        self.markHistoryDirty();
    }

    /// History commit hook: store visual meta / paint thumbnail for seq's CommandRecord into the fixed ring.
    /// **Event-time only**. No allocator.
    fn captureHistoryVisual(self: *App, seq: u64) void {
        const rec = self.cmd_log.findBySeq(seq) orelse return;
        const slot: usize = @intCast(seq % platform.command.MAX_CMD_LOG);
        var meta: history_thumbnail.HistoryThumbMeta = .{ .seq = seq };

        if (rec.kind == .revert) {
            meta.kind = @intFromEnum(history_summary.VisualKind.revert);
            self.history_thumb_meta[slot] = meta;
            return;
        }

        if (rec.undo_ref) |ref| {
            if (self.doc.paintDiffsForHandle(ref)) |view| {
                const result = history_thumbnail.renderThumb(
                    self.history_thumbs[slot][0..],
                    self.doc.width,
                    view.diffs,
                );
                meta.kind = @intFromEnum(history_summary.VisualKind.paint);
                if (result.changed) {
                    meta.flags = history_thumbnail.HistoryThumbMeta.FLAG_THUMB;
                    if (result.bbox) |b| meta.setBBox(b);
                }
                self.history_thumb_meta[slot] = meta;
                return;
            }
        }

        // normal but non-paint / no undo_ref → [meta]
        meta.kind = @intFromEnum(history_summary.VisualKind.meta);
        self.history_thumb_meta[slot] = meta;
    }

    /// Capture every record appended at/after seq_before (for multi-append redo / undo).
    fn captureHistoryVisualsSince(self: *App, seq_before: u64) void {
        var i: u32 = 0;
        while (i < self.cmd_log.filled) : (i += 1) {
            const rec = self.cmd_log.recordAt(i);
            if (rec.seq >= seq_before) self.captureHistoryVisual(rec.seq);
        }
    }

    /// netsync `applyWireCommit` post-apply → existing `captureHistoryVisual`.
    /// Fire point differs from solo recordedStroke/recordedAction, so do not double-capture.
    fn netsyncPostApplyHook(ctx: *anyopaque, applied: platform.NetsyncPostApplyContext) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        _ = applied.name;
        _ = applied.args;
        _ = applied.origin_peer;
        self.captureHistoryVisual(applied.seq);
    }

    fn historyVisualMeta(self: *const App, seq: u64) history_summary.VisualMeta {
        const slot: usize = @intCast(seq % platform.command.MAX_CMD_LOG);
        const m = self.history_thumb_meta[slot];
        if (m.seq != seq) return .{};
        const kind: history_summary.VisualKind = if (m.kind <= @intFromEnum(history_summary.VisualKind.revert))
            @enumFromInt(m.kind)
        else
            .none;
        const bbox: ?history_summary.BBox = if (m.bbox()) |b|
            .{ .x0 = b.x0, .y0 = b.y0, .x1 = b.x1, .y1 = b.y1 }
        else
            null;
        return .{
            .kind = kind,
            .thumb_present = m.thumbPresent(),
            .bbox = bbox,
        };
    }

    /// Resolve effective stroke parameters (explicit k=v overrides current App state). If tool is omitted and
    /// the current tool is not pen/eraser/brush/fill, return `error.UnsupportedTool`
    /// (bezier/select/eyedropper stay rejected as before).
    fn resolveEffectiveStroke(self: *App, p: actions.StrokeParams) error{UnsupportedTool}!actions.EffectiveStroke {
        const tool: actions.StrokeTool = p.tool orelse switch (self.active_kind) {
            .pen => .pen,
            .eraser => .eraser,
            .brush => .brush,
            .fill => .fill,
            else => return error.UnsupportedTool,
        };
        return .{
            .layer_id = 0,
            .tool = tool,
            .color = p.color orelse if (tool == .fill) self.fill.color else self.palette.current(),
            .size = p.size orelse self.brush.size,
            .opacity = p.opacity orelse self.brush.opacity,
            .hardness = p.hardness orelse self.brush.hardness_q,
            .tolerance = p.tolerance orelse if (tool == .fill) self.fill.tolerance else 0,
        };
    }

    /// Resolve the stroke's source layer to a stable id. When omitted, use the selected layer at capture/dispatch.
    fn resolveStrokeLayerId(self: *App, ref: ?actions.LayerRef) !u64 {
        const idx = if (ref) |r|
            self.resolveStrokeLayerIndex(r) catch |err| {
                platform.setActionErrorDetail("layer_not_found", "use #<id> from digest canvas");
                return err;
            }
        else
            self.canvas.selected_layer;
        return @intFromEnum(self.doc.layerIdAt(idx) orelse {
            platform.setActionErrorDetail("layer_not_found", "use #<id> from digest canvas");
            return error.LayerNotFound;
        });
    }

    fn resolveStrokeLayerIndex(self: *App, ref: actions.LayerRef) !usize {
        return resolveLayerRef(self, ref, true) catch |err| switch (err) {
            error.IdRequired, error.UnknownLayerId, error.OutOfRange => return error.LayerNotFound,
        };
    }

    /// At the `.relay` route entry, bake the source tool/color/brush/fill settings and layer id.
    /// Legacy input without `tool=` is resolved against this peer's active tool and emitted as a
    /// total wire form (every accepted stroke carries `tool=`).
    fn canonicalizeStroke(ctx: *anyopaque, args: []const u8, scratch: []u8) anyerror![]const u8 {
        const app: *App = @ptrCast(@alignCast(ctx));
        var pts_buf: [actions.MAX_STROKE_POINTS]actions.Point = undefined;
        const parsed = try actions.parseStroke(args, &pts_buf);
        const eff = try app.resolveEffectiveStroke(parsed.params);

        if (platform.netsyncActive() and
            eff.tool == .fill and
            app.canvas.selection != null)
        {
            platform.setActionErrorDetail(
                "selection_not_supported",
                "clear the selection before relaying a fill stroke",
            );
            return error.SelectionNotSupported;
        }

        var canonical = eff;
        canonical.layer_id = try app.resolveStrokeLayerId(parsed.params.layer);
        canonical.segment = parsed.params.segment orelse .first;
        return actions.formatCanonicalStroke(scratch, canonical, parsed.points) catch return error.ArgsTooLong;
    }

    /// Begin accumulating UI-stroke points (at capture start; also latch effective parameters here).
    fn uiStrokeBegin(self: *App, p: core.Vec2) void {
        self.ui_stroke_len = 0;
        self.ui_stroke_overflow = false;
        self.ui_stroke_layer_id = @intFromEnum(self.doc.layerIdAt(self.canvas.selected_layer) orelse .invalid);
        self.ui_stroke_tool = self.active_kind;
        self.ui_stroke_color = self.palette.current();
        self.ui_stroke_size = self.brush.size;
        self.ui_stroke_opacity = self.brush.opacity;
        self.ui_stroke_hardness = self.brush.hardness_q;
        // During netsync use relay chunking (no overflow). Solo keeps the fixed array.
        self.relay_stroke = platform.netsyncActive();
        if (self.relay_stroke) {
            self.relayResetCapture();
            self.relayChunkAppend(p);
        } else {
            self.uiStrokeAppend(p);
        }
    }

    fn uiStrokeAppend(self: *App, p: core.Vec2) void {
        if (self.relay_stroke) {
            self.relayChunkAppend(p);
            return;
        }
        if (self.ui_stroke_overflow) return;
        if (self.ui_stroke_len > 0) {
            const last = self.ui_stroke_pts[self.ui_stroke_len - 1];
            if (last.x == p.x and last.y == p.y) return; // Do not accumulate consecutive identical points
        }
        if (self.ui_stroke_len >= actions.MAX_STROKE_POINTS) {
            self.ui_stroke_overflow = true;
            return;
        }
        self.ui_stroke_pts[self.ui_stroke_len] = .{ .x = p.x, .y = p.y };
        self.ui_stroke_len += 1;
    }

    fn uiStrokeDiscard(self: *App) void {
        self.ui_stroke_len = 0;
        self.ui_stroke_overflow = false;
        if (self.relay_stroke) {
            self.relayResetCapture();
            self.relay_stroke = false;
        }
    }

    fn relayResetCapture(self: *App) void {
        self.relay_active_len = 0;
        self.relay_active_continuation = false;
        self.relay_chunks.clearRetainingCapacity();
    }

    fn relayChunkAppend(self: *App, p: core.Vec2) void {
        const pt: actions.Point = .{ .x = p.x, .y = p.y };
        if (self.relay_active_len > 0) {
            const last = self.relay_active_pts[self.relay_active_len - 1];
            if (last.x == pt.x and last.y == pt.y) return;
        }
        if (self.relay_active_len >= actions.RELAY_STROKE_CHUNK_POINTS) {
            self.relayFlushActiveChunk() catch {
                std.debug.print("pixie: relay chunk flush OOM — subsequent points may be dropped\n", .{});
                return;
            };
            // After flush, active carries 1 point. Do not append if it is the same point.
            if (self.relay_active_len > 0) {
                const last = self.relay_active_pts[self.relay_active_len - 1];
                if (last.x == pt.x and last.y == pt.y) return;
            }
        }
        self.relay_active_pts[self.relay_active_len] = pt;
        self.relay_active_len += 1;
    }

    fn relayFlushActiveChunk(self: *App) !void {
        if (self.relay_active_len == 0) return;
        // Do not send a continuation that is carry-only (no new points).
        if (self.relay_active_continuation and self.relay_active_len == 1) {
            return;
        }
        var chunk: RelayStrokeChunk = .{
            .len = self.relay_active_len,
            .continuation = self.relay_active_continuation,
        };
        @memcpy(chunk.pts[0..self.relay_active_len], self.relay_active_pts[0..self.relay_active_len]);
        const carry = self.relay_active_pts[self.relay_active_len - 1];
        try self.relay_chunks.append(self.gpa, chunk);
        self.relay_active_pts[0] = carry;
        self.relay_active_len = 1;
        self.relay_active_continuation = true;
    }

    /// On release: finalize the last active into a chunk and build canonical args for every chunk into `out`.
    /// On success empty `relay_chunks`; caller rewinds then calls `relaySendCanonicalChunks`.
    /// On failure return false (do not rewind the preview). Clear a partially built `out`; leave chunks alone
    /// (caller abandons them).
    fn relayBuildCanonicalChunks(self: *App, out: *std.ArrayListUnmanaged([]u8)) bool {
        // Flush the final active (skip carry-only continuation)
        if (self.relay_active_len > 0) {
            if (!(self.relay_active_continuation and self.relay_active_len == 1)) {
                var chunk: RelayStrokeChunk = .{
                    .len = self.relay_active_len,
                    .continuation = self.relay_active_continuation,
                };
                @memcpy(chunk.pts[0..self.relay_active_len], self.relay_active_pts[0..self.relay_active_len]);
                self.relay_chunks.append(self.gpa, chunk) catch {
                    self.setSaveMsg("netsync: stroke chunk OOM", .{});
                    return false;
                };
            }
            self.relay_active_len = 0;
        }
        if (self.relay_chunks.items.len == 0) return true;

        // client: can the pending FIFO take every chunk at once? (pre-check; no cross-frame drain)
        if (!platform.netsyncIsHost()) {
            const pending = platform.netsyncPendingProposalCount();
            const avail = if (pending < platform.netsyncPendingCap)
                platform.netsyncPendingCap - pending
            else
                0;
            if (self.relay_chunks.items.len > avail) {
                self.setSaveMsg("netsync: stroke too long ({d} chunks > pending avail {d})", .{
                    self.relay_chunks.items.len,
                    avail,
                });
                return false;
            }
        }

        const tool: actions.StrokeTool = switch (self.ui_stroke_tool) {
            .pen => .pen,
            .eraser => .eraser,
            .brush => .brush,
            else => return false,
        };
        const eff: actions.EffectiveStroke = .{
            .layer_id = self.ui_stroke_layer_id,
            .tool = tool,
            .color = self.ui_stroke_color,
            .size = self.ui_stroke_size,
            .opacity = self.ui_stroke_opacity,
            .hardness = self.ui_stroke_hardness,
        };

        const freeOut = struct {
            fn call(app: *App, list: *std.ArrayListUnmanaged([]u8)) void {
                for (list.items) |a| app.gpa.free(a);
                list.clearRetainingCapacity();
            }
        }.call;

        for (self.relay_chunks.items) |chunk| {
            var canon_buf: [platform.command.MAX_CMD_ARGS]u8 = undefined;
            var eff_seg = eff;
            eff_seg.segment = if (chunk.continuation) .continuation else .first;
            const canon = actions.formatCanonicalStroke(&canon_buf, eff_seg, chunk.pts[0..chunk.len]) catch {
                freeOut(self, out);
                self.setSaveMsg("netsync: stroke args too long", .{});
                return false;
            };
            const owned = self.gpa.dupe(u8, canon) catch {
                freeOut(self, out);
                self.setSaveMsg("netsync: stroke args OOM", .{});
                return false;
            };
            out.append(self.gpa, owned) catch {
                self.gpa.free(owned);
                freeOut(self, out);
                self.setSaveMsg("netsync: stroke queue OOM", .{});
                return false;
            };
        }
        self.relay_chunks.clearRetainingCapacity();
        return true;
    }

    /// Right after release: routeAction every built canonical args in order (do not wait for COMMIT).
    /// Client enqueues PROPOSEs back-to-back (pending cap was checked before build).
    fn relaySendCanonicalChunks(self: *App, args_list: []const []u8) void {
        for (args_list, 0..) |args, i| {
            var out_buf: [256]u8 = undefined;
            _ = platform.routeAction("stroke", args, &out_buf) catch |err| {
                std.debug.print("pixie: netsync UI stroke chunk {d}/{d} routeAction failed: {s}\n", .{
                    i + 1,
                    args_list.len,
                    @errorName(err),
                });
                self.setSaveMsg("netsync: stroke chunk {d}/{d} 送信失敗（{s}）— 以降は未送", .{
                    i + 1,
                    args_list.len,
                    @errorName(err),
                });
                return;
            };
        }
    }

    /// Record a CommandRecord at UI-stroke commit (actor=local_user, canonical args;
    /// one-shot: always clear the accumulator). `pushed` = whether pushPaintOp actually pushed an Op
    /// (when true, undo_ref = handle of the latest push — the action⇄UndoCmd pairing).
    fn recordUiStroke(self: *App, pushed: bool) void {
        if (pushed) self.markProjectDirty();
        const len = self.ui_stroke_len;
        const overflow = self.ui_stroke_overflow;
        self.uiStrokeDiscard();
        if (len == 0) return;
        if (overflow) {
            std.debug.print("pixie: skipping UI stroke record ({d} points over limit; Op remains on legacy UndoStack)\n", .{actions.MAX_STROKE_POINTS});
            return;
        }
        const tool: actions.StrokeTool = switch (self.ui_stroke_tool) {
            .pen => .pen,
            .eraser => .eraser,
            .brush => .brush,
            else => return, // fill etc. are outside this recording path (pen/eraser/brush only)
        };
        var canon_buf: [platform.command.MAX_CMD_ARGS]u8 = undefined;
        const canon = actions.formatCanonicalStroke(&canon_buf, .{
            .layer_id = self.ui_stroke_layer_id,
            .tool = tool,
            .color = self.ui_stroke_color,
            .size = self.ui_stroke_size,
            .opacity = self.ui_stroke_opacity,
            .hardness = self.ui_stroke_hardness,
        }, self.ui_stroke_pts[0..len]) catch {
            std.debug.print("pixie: skipping UI stroke record (canonical args exceed {d}B; Op remains on legacy UndoStack)\n", .{platform.command.MAX_CMD_ARGS});
            return;
        };
        const undo_ref: ?u64 = if (pushed) self.doc.undo.topHandle() else null;
        var msg_buf: [64]u8 = undefined;
        const seq = self.cmd_exec.recordExecuted("stroke", canon, .{ .actor = .local_user }, undo_ref, &msg_buf) catch |err| {
            std.debug.print("pixie: failed to record UI stroke: {s}\n", .{@errorName(err)});
            return; // Record failure = unrecorded push; leave epoch bump to end-of-frame
        };
        if (seq) |s| self.captureHistoryVisual(s);
        if (undo_ref) |ref| self.doc.undo.setOwner(ref, OP_OWNER_USER); // op is user-owned
        self.last_seen_handle = self.doc.undo.next_handle; // Recorded push (follow point for unrecorded-edit detection)
    }

    /// Whether a netsync UI stroke should go through routeAction("stroke") (pen/eraser/brush only;
    /// fill etc. have no action vocabulary → rewind_discard during netsync).
    fn uiStrokeRelaysViaAction(self: *const App) bool {
        return switch (self.ui_stroke_tool) {
            .pen, .eraser, .brush => true,
            else => false,
        };
    }

    /// Rewind the local preview paint from pd.diffs' before values (= pre-stroke; StrokeRecorder dedup /
    /// brush orig) and free the diffs (do not pushPaintOp).
    fn rewindPaintDiff(self: *App, pd: core.PaintDiff) void {
        const pixels = self.canvas.layerPixels(pd.layer_idx);
        for (pd.diffs) |d| pixels[d.idx] = d.before;
        self.gpa.free(pd.diffs);
    }

    /// Record a CommandRecord for a committed UI shape (actor=local_user).
    fn recordUiShape(self: *App, pushed: bool) void {
        if (pushed) self.markProjectDirty();
        var canon_buf: [platform.command.MAX_CMD_ARGS]u8 = undefined;
        const canon = actions.formatCanonicalShape(&canon_buf, .{
            .kind = switch (self.shape_in.kind) {
                .line => .line,
                .rect => .rect,
                .ellipse => .ellipse,
            },
            .p0 = .{ .x = self.shape_in.anchor.x, .y = self.shape_in.anchor.y },
            .p1 = .{ .x = self.shape_in.cur.x, .y = self.shape_in.cur.y },
            .fill = self.shape_in.fill,
        }) catch {
            std.debug.print("pixie: skipping UI shape record (canonical args too long)\n", .{});
            return;
        };
        const undo_ref: ?u64 = if (pushed) self.doc.undo.topHandle() else null;
        var msg_buf: [64]u8 = undefined;
        const seq = self.cmd_exec.recordExecuted("shape", canon, .{ .actor = .local_user }, undo_ref, &msg_buf) catch |err| {
            std.debug.print("pixie: failed to record UI shape: {s}\n", .{@errorName(err)});
            return;
        };
        if (seq) |s| self.captureHistoryVisual(s);
        if (undo_ref) |ref| self.doc.undo.setOwner(ref, OP_OWNER_USER);
        self.last_seen_handle = self.doc.undo.next_handle;
    }

    /// netsync UI shape commit: already rewound → routeAction("shape").
    fn relayUiShape(self: *App) void {
        var canon_buf: [platform.command.MAX_CMD_ARGS]u8 = undefined;
        const canon = actions.formatCanonicalShape(&canon_buf, .{
            .kind = switch (self.shape_in.kind) {
                .line => .line,
                .rect => .rect,
                .ellipse => .ellipse,
            },
            .p0 = .{ .x = self.shape_in.anchor.x, .y = self.shape_in.anchor.y },
            .p1 = .{ .x = self.shape_in.cur.x, .y = self.shape_in.cur.y },
            .fill = self.shape_in.fill,
        }) catch {
            std.debug.print("pixie: skipping netsync UI shape (canonical args too long)\n", .{});
            return;
        };
        var out_buf: [256]u8 = undefined;
        _ = platform.routeAction("shape", canon, &out_buf) catch |err| {
            std.debug.print("pixie: netsync UI shape routeAction failed: {s}\n", .{@errorName(err)});
        };
    }

    /// routeAction only during netsync; solo callers use do* directly.
    fn routeUi(self: *App, name: []const u8, args: []const u8) void {
        var buf: [256]u8 = undefined;
        _ = platform.routeAction(name, args, &buf) catch |err| {
            std.debug.print("pixie: routeAction {s} failed: {s}\n", .{ name, @errorName(err) });
            self.setSaveMsg("netsync: {s} を送信できませんでした（{s}）", .{ name, @errorName(err) });
        };
    }

    fn routeUiLayerOp(self: *App, name: []const u8, idx: usize) void {
        const id = self.doc.layerIdAt(idx) orelse return;
        var args_buf: [64]u8 = undefined;
        const args = actions.formatLayerId(&args_buf, @intFromEnum(id)) catch return;
        self.routeUi(name, args);
    }

    fn routeUiLayerVisible(self: *App, idx: usize, on: bool) void {
        const id = self.doc.layerIdAt(idx) orelse return;
        var args_buf: [64]u8 = undefined;
        const args = actions.formatLayerIdBool(&args_buf, @intFromEnum(id), on) catch return;
        self.routeUi("set_layer_visible", args);
    }

    fn routeUiLayerOpacity(self: *App, idx: usize, value: u8) void {
        const id = self.doc.layerIdAt(idx) orelse return;
        var args_buf: [64]u8 = undefined;
        const args = actions.formatLayerIdU8(&args_buf, @intFromEnum(id), value) catch return;
        self.routeUi("set_layer_opacity", args);
    }

    fn routeUiLayerMove(self: *App, idx: usize, delta: i32) void {
        const id = self.doc.layerIdAt(idx) orelse return;
        var args_buf: [64]u8 = undefined;
        const args = actions.formatLayerIdDelta(&args_buf, @intFromEnum(id), delta) catch return;
        self.routeUi("move_layer", args);
    }

    /// Eyedropper: apply the color at the given canvas coords as the drawing color. The caller
    /// (`eyedropper_input.EyedropperInput.update`) already guarantees the coords are inside the canvas.
    /// The sampled color is the composite (`compositeStraight()` — the on-screen look).
    /// Ignore alpha==0 (undrawn/transparent) so bogus blacks are not picked. Force opaque alpha before
    /// passing to `doSetColorHex` (keeps the `palette.zig` invariant that colors are always opaque).
    /// Picking while Eraser is selected auto-switches to Pen (Eraser has no drawing-color concept;
    /// same convention as clicking a palette swatch). Assign active_kind directly, not via `setActiveKind`
    /// (`setActiveKind` is a no-op while `eye_in.picking` due to the conflict guard, which fights this
    /// method's intent to switch as soon as an opaque color is picked mid-drag. The switch is a
    /// consequence of the in-flight eyedrop itself, not a conflict with another tool, so the bypass is safe.
    /// Leaving .eraser also needs no bezier cancel / sel_in float discard, so there is nothing of
    /// `setActiveKind`'s out-of-guard work to reproduce.)
    fn pickColor(self: *App, x: i32, y: i32) void {
        const idx = @as(usize, @intCast(y)) * self.canvas.width + @as(usize, @intCast(x));
        const sampled = self.canvas.compositeStraight()[idx];
        if (sampled & 0xFF000000 == 0) return; // Ignore transparent samples
        self.doSetColorHex(0xFF000000 | (sampled & 0x00FFFFFF));
        if (self.active_kind == .eraser) self.active_kind = .pen;
    }

    /// On the frame selection (or load) changes, re-sync in-edit HSV from the current color.
    fn syncEditHsv(self: *App) void {
        if (self.edit_synced_for == self.palette.selected) return;
        const hsv = guiColor(self.palette.current()).toHsv();
        self.edit_h = hsv.h;
        self.edit_s = hsv.s;
        self.edit_v = hsv.v;
        self.edit_synced_for = self.palette.selected;
    }

    /// Save the palette as .gpl (save-as; on success hand the dialog path to palette_path).
    fn doSavePalette(self: *App) FileOpResult {
        const maybe = platform.saveFileDialog(self.gpa, self.io, .{
            .default_name = "palette.gpl",
            .allowed_ext = "gpl",
        }) catch |err| {
            if (err == error.DialogPending) return .dialog_pending;
            self.setSaveMsg("Palette save failed: {s}", .{@errorName(err)});
            return .done;
        };
        const path = maybe orelse return .done;
        const bytes = palette_mod.encodeGpl(self.palette.colors.items, "pixie", self.gpa) catch |err| {
            self.setSaveMsg("Palette save failed: {s}", .{@errorName(err)});
            self.gpa.free(path);
            return .done;
        };
        defer self.gpa.free(bytes);
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = bytes }) catch |err| {
            self.setSaveMsg("Palette save failed: {s}", .{@errorName(err)});
            self.gpa.free(path);
            return .done;
        };
        if (self.palette_path) |old| self.gpa.free(old);
        self.palette_path = path;
        self.setSaveMsg("Palette saved: {s}", .{std.fs.path.basename(path)});
        return .done;
    }

    /// Load a .gpl and replace the palette (only on success; keep the existing palette on failure).
    fn doLoadPalette(self: *App) FileOpResult {
        const maybe = platform.openFileDialog(self.gpa, self.io, .{ .allowed_ext = "gpl" }) catch |err| {
            if (err == error.DialogPending) return .dialog_pending;
            self.setSaveMsg("Palette load failed: {s}", .{@errorName(err)});
            return .done;
        };
        const path = maybe orelse return .done;
        defer self.gpa.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .unlimited) catch |err| {
            self.setSaveMsg("Palette load failed: {s}", .{@errorName(err)});
            return .done;
        };
        defer self.gpa.free(bytes);
        const colors = palette_mod.decodeGpl(self.gpa, bytes) catch |err| {
            self.setSaveMsg("Palette load failed: {s}", .{@errorName(err)});
            return .done;
        };
        // Success: free old colors, swap in the new list, reset selected/HSV
        self.palette.colors.deinit(self.gpa);
        self.palette.colors = colors;
        self.palette.selected = 0;
        self.edit_synced_for = null; // Re-sync HSV next frame
        self.repl_source = null;
        const cur = self.palette.current();
        self.pen.color = cur;
        self.brush.color = cur;
        self.fill.color = cur;
        self.setSaveMsg("Palette loaded: {s}", .{std.fs.path.basename(path)});
        return .done;
    }

    /// Save directly to the given path (no dialog; shared by `doSave` + action `save <path>`).
    /// Does not update current_path (a headless call must not silently mutate the UI "save as" persistent state).
    /// No editingBlocked check (neither doSave nor doSaveAs has one).
    fn doSaveTo(self: *App, path: []const u8) !void {
        const flat = self.canvas.compositeStraight();
        try core.savePNG(self.io, path, flat, self.canvas.width, self.canvas.height, self.gpa);
        self.setSaveMsg("Saved: {s}", .{std.fs.path.basename(path)});
    }

    /// Overwrite the remembered save path directly. If unset, fall back to save-as.
    fn doSave(self: *App) FileOpResult {
        const path = self.current_path orelse return self.doSaveAs();
        // current_path is the persistent path; keep it even on failure (do not free)
        self.doSaveTo(path) catch |err| {
            self.setSaveMsg("Save failed: {s}", .{@errorName(err)});
        };
        return .done;
    }

    /// Pick a save path via dialog and save. On success hand the dialog path to current_path.
    fn doSaveAs(self: *App) FileOpResult {
        const maybe = platform.saveFileDialog(self.gpa, self.io, .{
            .default_name = "untitled.png",
            .allowed_ext = "png",
        }) catch |err| {
            if (err == error.DialogPending) return .dialog_pending;
            self.setSaveMsg("Save failed: {s}", .{@errorName(err)});
            return .done;
        };
        const path = maybe orelse return .done; // Cancel: silent no-op
        const flat = self.canvas.compositeStraight();
        core.savePNG(self.io, path, flat, self.canvas.width, self.canvas.height, self.gpa) catch |err| {
            self.setSaveMsg("Save failed: {s}", .{@errorName(err)});
            self.gpa.free(path); // On failure free the dialog path; leave the old current_path untouched
            return .done;
        };
        if (self.current_path) |old| self.gpa.free(old);
        self.current_path = path; // Transfer ownership (do not re-dupe)
        self.setSaveMsg("Saved: {s}", .{std.fs.path.basename(path)});
        return .done;
    }

    /// Write a decoded PNG into the given layer with top-left crop/pad, then sync preview and cel.
    /// Never pushes undo (caller decides the Op unit, e.g. `.layer_add`).
    /// canvas and PNG share canonical BGRA 0xAARRGGBB, so no conversion.
    fn copyDecodedPngToLayer(self: *App, layer_idx: usize, img: *const png.PNGImage) void {
        const layer = self.canvas.layerPixels(layer_idx);
        @memset(layer, 0);
        const iw: usize = img.width;
        const rows = @min(@as(usize, img.height), @as(usize, self.canvas.height));
        const cols = @min(iw, @as(usize, self.canvas.width));
        for (0..rows) |y| {
            @memcpy(layer[y * self.canvas.width ..][0..cols], img.pixels[y * iw ..][0..cols]);
        }
        self.syncPreviewCanvas();
        // active_view is a copy of the cel. saveDocument serializes cel_pool, so
        // write the layer back into the cel after a direct layer write (undo Op is the caller's job).
        self.doc.commitActiveLayerToCel(self.gpa, layer_idx);
    }

    /// Pick a PNG via dialog and load it onto the canvas (top-left crop/pad).
    /// Discard an in-flight stroke. Clear undo/redo and set current_path to the opened file.
    /// Load directly from the given path (no dialog; shared by `doOpen` + action `open <path>`).
    /// Same narrow guard as `doOpen` (`input.capturing or bezier_editor.isEditing()`; does not look at
    /// `sel_in.state` — preserves existing doOpen behaviour). Path is `gpa.dupe`'d into current_path as an
    /// independently owned copy (does not take ownership of the caller's path).
    fn doOpenPath(self: *App, path: []const u8) !void {
        if (self.input.capturing or self.bezier_editor.isEditing()) return error.EditingBlocked;
        var img = try png.decodePNGFile(self.io, self.gpa, path);
        defer img.deinit(self.gpa);
        // Secure the independent current_path copy **before** swapping the document (later stages do not
        // return errors: Document OOM is a panic contract, including commitActiveLayerToCel. Avoid an error
        // return that would leave "loaded but reported as failed".).
        const owned = try self.gpa.dupe(u8, path);

        // Load PNG as a flat image and replace with a new single-layer0 document.
        self.resetCanvasToSingleLayer();
        // selected_frame is already 0 after resetToSingleBlankLayer.
        // Load replaces the document, so no undo (reset already discarded doc.undo).
        self.copyDecodedPngToLayer(0, &img);

        if (self.current_path) |old| self.gpa.free(old);
        self.current_path = owned;
        self.setSaveMsg("Loaded: {s}", .{std.fs.path.basename(path)});
    }

    /// Insert a PNG into the current document as a new layer.
    /// Decode first (document unchanged on failure). One `.layer_add` from `doAddLayer` is the undo unit;
    /// pixels are synced to the cel before return (undo removes layer structure + pixels together). No `pushPaintOp`.
    /// Does not change `current_path`. Hot path: event-time only.
    fn doImportPngAsLayer(self: *App, path: []const u8) !void {
        // Invariant: on decode failure, do not mutate the document at all.
        var img = try png.decodePNGFile(self.io, self.gpa, path);
        defer img.deinit(self.gpa);

        _ = try self.doAddLayer();
        // doAddLayer → Document.addLayer selects the new layer (Canvas.insertLayer also
        // syncs canvas.selected_layer).
        const layer_idx = self.canvas.selected_layer;
        self.copyDecodedPngToLayer(layer_idx, &img);
        self.setSaveMsg("Inserted: {s}", .{std.fs.path.basename(path)});
    }

    /// Consume an OS / harness file drop.
    /// PNG only goes straight to `doImportPngAsLayer` (new layer in the current document; .pix / others rejected).
    /// During netsync, reject without I/O. Hot path: event-time only.
    fn handleFileDrop(self: *App, drop: platform.FileDropEvent) void {
        if (drop.count != 1) return;
        const path = drop.paths[0].slice();
        const ext = std.fs.path.extension(path);
        if (!std.ascii.eqlIgnoreCase(ext, ".png")) {
            self.setSaveMsg("Drop rejected: not a PNG ({s})", .{std.fs.path.basename(path)});
            return;
        }
        if (platform.netsyncActive()) {
            // Same message path as PNG open's reject_when_synced (setSaveMsg).
            // Do not route to a remote action; no I/O; canvas unchanged.
            self.setSaveMsg("netsync: open を送信できませんでした（RejectedWhileSynced）", .{});
            return;
        }
        self.doImportPngAsLayer(path) catch |err| {
            self.setSaveMsg("Import failed: {s}", .{@errorName(err)});
        };
    }

    /// Pick a PNG via dialog and load it onto the canvas (top-left crop/pad).
    fn doOpen(self: *App) FileOpResult {
        if (self.input.capturing or self.bezier_editor.isEditing()) return .done;
        const maybe = platform.openFileDialog(self.gpa, self.io, .{ .allowed_ext = "png" }) catch |err| {
            if (err == error.DialogPending) return .dialog_pending;
            self.setSaveMsg("Load failed: {s}", .{@errorName(err)});
            return .done;
        };
        const path = maybe orelse return .done; // Cancel: silent no-op
        _ = self.requestPngImport(path) catch |err| {
            self.setSaveMsg("Load failed: {s}", .{@errorName(err)});
        };
        self.gpa.free(path);
        return .done;
    }

    fn requestPngImport(self: *App, path: []const u8) !appshell.document_host.Result {
        if (self.host.confirmation() != .none) return error.PendingConfirmation;
        const owned = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(owned);
        self.pending_png_path = owned;
        self.png_import_pending = true;
        const result = self.host.newDocument() catch |err| {
            self.pending_png_path = null;
            self.png_import_pending = false;
            return err;
        };
        if (result != .confirmation_required) finishHostResult(self, result);
        return result;
    }

    fn requestNewDocument(self: *App) !appshell.document_host.Result {
        const result = try self.host.newDocument();
        if (result != .confirmation_required) finishHostResult(self, result);
        return result;
    }

    // ── .pix project save/load (preserves layer structure) ─────────────────

    /// Overwrite the remembered .pix save path directly. If unset, fall back to save-as.
    fn doSaveProject(self: *App) FileOpResult {
        const result = self.host.save() catch |err| {
            self.setSaveMsg("Project save failed: {s}", .{@errorName(err)});
            return .done;
        };
        if (result == .needs_save_as) return self.doSaveAsProject();
        finishHostResult(self, result);
        self.setSaveMsg("Project saved: {s}", .{std.fs.path.basename(self.current_project_path orelse "untitled.pix")});
        return .done;
    }

    /// Pick a .pix save path via dialog and save. On success hand the dialog path to current_project_path.
    fn doSaveAsProject(self: *App) FileOpResult {
        const maybe = platform.saveFileDialog(self.gpa, self.io, .{
            .default_name = "untitled.pix",
            .allowed_ext = "pix",
        }) catch |err| {
            if (err == error.DialogPending) return .dialog_pending;
            self.setSaveMsg("Project save failed: {s}", .{@errorName(err)});
            return .done;
        };
        const path = maybe orelse return .done; // Cancel: silent no-op
        const result = self.host.saveAs(path) catch |err| {
            self.setSaveMsg("Project save failed: {s}", .{@errorName(err)});
            self.gpa.free(path);
            return .done;
        };
        self.setSaveMsg("Project saved: {s}", .{std.fs.path.basename(path)});
        finishHostResult(self, result);
        self.gpa.free(path);
        return .done;
    }

    fn doConfirmSaveAs(self: *App) FileOpResult {
        const maybe = platform.saveFileDialog(self.gpa, self.io, .{
            .default_name = "untitled.pix",
            .allowed_ext = "pix",
        }) catch |err| {
            if (err == error.DialogPending) return .dialog_pending;
            self.setSaveMsg("Project save failed: {s}", .{@errorName(err)});
            return .done;
        };
        const path = maybe orelse return .done;
        const result = self.host.confirmSave(path) catch |err| {
            self.setSaveMsg("Project save failed: {s}", .{@errorName(err)});
            self.gpa.free(path);
            return .done;
        };
        self.setSaveMsg("Project saved: {s}", .{std.fs.path.basename(path)});
        finishHostResult(self, result);
        self.gpa.free(path);
        return .done;
    }

    /// Load a .pix project and replace the document (preserves layer structure).
    /// Discard in-flight stroke/edit. Clear undo/redo, discard selection/float, update current_project_path.
    /// Size is checked with peekCanvasSize + the shared limit validator (edge ≤ MAX_CANVAS_EDGE, pixels ≤ MAX_CANVAS_PIXELS).
    fn doOpenProject(self: *App) FileOpResult {
        if (self.editingBlocked()) return .done;
        const maybe = platform.openFileDialog(self.gpa, self.io, .{ .allowed_ext = "pix" }) catch |err| {
            if (err == error.DialogPending) return .dialog_pending;
            self.setSaveMsg("Project load failed: {s}", .{@errorName(err)});
            return .done;
        };
        const path = maybe orelse return .done; // Cancel: silent no-op
        _ = self.requestProjectOpen(path) catch |err| {
            self.setSaveMsg("Project load failed: {s}", .{@errorName(err)});
        };
        self.gpa.free(path);
        return .done;
    }

    fn requestProjectOpen(self: *App, path: []const u8) !appshell.document_host.Result {
        const result = try self.host.open(path);
        if (result != .confirmation_required) finishHostResult(self, result);
        return result;
    }

    // ── Sequence PNG / sprite-sheet export ──────────────────────

    /// From a saveFileDialog path, return the stem with `.png` stripped (for sequence export).
    fn pathToPngStem(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        if (path.len >= 4 and std.ascii.eqlIgnoreCase(path[path.len - 4 ..], ".png")) {
            return allocator.dupe(u8, path[0 .. path.len - 4]);
        }
        return allocator.dupe(u8, path);
    }

    /// Pick a stem via dialog and write sequence PNGs (`<stem>_NNNN.png`).
    fn doExportSeq(self: *App) FileOpResult {
        const maybe = platform.saveFileDialog(self.gpa, self.io, .{
            .default_name = "sequence.png",
            .allowed_ext = "png",
        }) catch |err| {
            if (err == error.DialogPending) return .dialog_pending;
            self.setSaveMsg("Export failed: {s}", .{@errorName(err)});
            return .done;
        };
        const path = maybe orelse return .done;
        const stem = App.pathToPngStem(self.gpa, path) catch |err| {
            self.setSaveMsg("Export failed: {s}", .{@errorName(err)});
            self.gpa.free(path);
            return .done;
        };
        defer self.gpa.free(path);
        defer self.gpa.free(stem);
        core.document_io.exportPngSequence(self.io, stem, &self.doc, self.gpa) catch |err| {
            self.setSaveMsg("Export failed: {s}", .{@errorName(err)});
            return .done;
        };
        self.setSaveMsg("Exported sequence: {s}", .{std.fs.path.basename(stem)});
        return .done;
    }

    /// Pick a path via dialog and write a sprite-sheet PNG (default columns/margin).
    fn doExportSheet(self: *App) FileOpResult {
        const maybe = platform.saveFileDialog(self.gpa, self.io, .{
            .default_name = "spritesheet.png",
            .allowed_ext = "png",
        }) catch |err| {
            if (err == error.DialogPending) return .dialog_pending;
            self.setSaveMsg("Export failed: {s}", .{@errorName(err)});
            return .done;
        };
        const path = maybe orelse return .done;
        defer self.gpa.free(path);
        core.document_io.exportSpriteSheet(self.io, path, &self.doc, self.gpa, .{}) catch |err| {
            self.setSaveMsg("Export failed: {s}", .{@errorName(err)});
            return .done;
        };
        self.setSaveMsg("Exported sheet: {s}", .{std.fs.path.basename(path)});
        return .done;
    }

    /// Write sequence PNGs directly to the given stem (for action `export_seq <stem>`).
    fn doExportSeqTo(self: *App, stem: []const u8) !void {
        if (self.doc.frames.items.len == 0) return error.NoFrames;
        try core.document_io.exportPngSequence(self.io, stem, &self.doc, self.gpa);
        self.setSaveMsg("Exported sequence: {s}", .{std.fs.path.basename(stem)});
    }

    /// Write a sprite sheet directly to the given path (for action `export_sheet`).
    fn doExportSheetTo(self: *App, path: []const u8, opts: core.document_io.SpriteSheetOpts) !void {
        try core.document_io.exportSpriteSheet(self.io, path, &self.doc, self.gpa, opts);
        self.setSaveMsg("Exported sheet: {s}", .{std.fs.path.basename(path)});
    }

    /// Edit commands are ignored during a stroke. Returning `!void` lets UI
    /// (`catch {}`) and action (`try`) share the same decision code;
    /// behaviour is unchanged (see the action⇄UndoCmd pairing table in the
    /// "custom action" section doc comment below). Empty undo/redo stacks succeed as an idempotent no-op
    /// (`UndoStack.undoOne`/`redoOne` already do nothing when empty — not a new behaviour).
    fn doUndo(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        const undo_before = self.doc.undo.undo.items.len;
        const redo_before = self.doc.undo.redo.items.len;
        const seq_before = self.cmd_log.next_seq;
        // defer: routeAction may mutate revert flags etc. even on mid-failure (independent of next_seq)
        defer self.markHistoryDirty();
        if (platform.netsyncActive()) {
            var buf: [128]u8 = undefined;
            _ = try platform.routeAction("undo", "", &buf);
        } else {
            self.userUndo();
        }
        self.captureHistoryVisualsSince(seq_before);
        self.clampTimelineTarget();
        if (undo_before != self.doc.undo.undo.items.len or redo_before != self.doc.undo.redo.items.len) self.markProjectDirty();
    }

    fn doRedo(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        const undo_before = self.doc.undo.undo.items.len;
        const redo_before = self.doc.undo.redo.items.len;
        defer self.markHistoryDirty();
        if (platform.netsyncActive()) {
            var buf: [128]u8 = undefined;
            const seq_before = self.cmd_log.next_seq;
            _ = try platform.routeAction("redo", "", &buf);
            self.captureHistoryVisualsSince(seq_before);
        } else {
            self.userRedo();
        }
        self.clampTimelineTarget();
        if (undo_before != self.doc.undo.undo.items.len or redo_before != self.doc.undo.redo.items.len) self.markProjectDirty();
    }

    fn markHistoryDirty(self: *App) void {
        self.history_dirty = true;
    }

    fn rebuildHistoryEntries(self: *App) void {
        const hctx = historyCtx(self);
        self.history_count = self.cmd_log.filled;
        var i: u32 = 0;
        while (i < self.cmd_log.filled) : (i += 1) {
            const rec = self.cmd_log.recordAt(i);
            self.history_entries[i] = history_summary.makeHistoryEntry(hctx, rec);
            // HistoryEntry.name borrows the buffer inside CommandRecord (history_summary.zig contract:
            // must not outlive CommandLog mutation). The panel only uses summary (inline copy), so
            // the cache must not retain the borrow.
            self.history_entries[i].name = "";
        }
        self.history_seen_seq = self.cmd_log.next_seq;
        self.history_seen_peer_revision = platform.netsyncPeerMetadataRevision();
        self.history_dirty = false;
    }

    fn ensureHistoryFresh(self: *App) void {
        const peer_rev = platform.netsyncPeerMetadataRevision();
        if (!self.history_dirty and self.history_seen_seq == self.cmd_log.next_seq and
            self.history_seen_peer_revision == peer_rev) return;
        self.rebuildHistoryEntries();
    }

    /// local_user undo (hybrid): walk the undo stack from the top and undo the first
    /// "local_user-owned op".
    /// - Op with a matching CommandLog record:
    ///   - actor other than local_user (agent etc.) → skip (agent ops undo only via `action undo`)
    ///   - actor=local_user → framework path `cmd_exec.undoOne(.local_user)` (revert-record
    ///     append, reverted mark, tx bundle, epoch are handled by the framework)
    /// - Op with no matching record (unrecorded) = local_user-owned (agent ops are always recorded
    ///   via an action) → legacy path:
    ///   - If topmost: classic `doc.undoOne()` (moves onto the redo stack)
    ///   - Non-topmost `.paint` op: `revertByHandle(move_to_redo)` (when an agent op sits above)
    ///   - Non-topmost unrecorded **structure op: skip as non-undoable** (arbitrary-position revert is paint-only —
    ///     see `Document.canRevertByHandle` structure-Op constraints). Walk continues to the next user-owned op
    /// Interleaving of the two systems (framework revert / legacy stack) is an **approximation** (MVP;
    /// the legacy system goes away once the staged migration finishes). Pixel side-effect trade-offs:
    /// see the `Document.revertByHandle` doc comment.
    fn userUndo(self: *App) void {
        var i: usize = self.doc.undo.handles.items.len;
        while (i > 0) {
            i -= 1;
            const h = self.doc.undo.handles.items[i];
            // Ownership is decided by the op-side owner tag, not by reverse-looking up the record (so an agent op
            // whose record was ring-evicted is not misread as "unrecorded = user-owned" and legacy-undone.
            // unknown is treated as user (agent ops are always tagged).
            if (self.doc.undo.owners.items[i] == OP_OWNER_AGENT) continue;
            if (self.findRecordByUndoRef(h)) |rec| {
                if (!rec.actor.eql(.local_user)) continue; // Defence in depth alongside the owner tag
                var buf: [256]u8 = undefined;
                _ = self.cmd_exec.undoOne(.local_user, &buf) catch |err| {
                    std.debug.print("pixie: undoOne failed: {s}\n", .{@errorName(err)});
                };
                return;
            }
            // Unrecorded = local_user-owned → legacy path
            if (i == self.doc.undo.undo.items.len - 1) {
                self.doc.undoOne(self.gpa);
                return;
            }
            if (self.doc.canRevertByHandle(h)) {
                _ = self.doc.revertByHandle(self.gpa, h, .move_to_redo);
                return;
            }
            // Non-topmost unrecorded structure op → skip and continue to the next user-owned op
        }
    }

    /// local_user redo (hybrid): try framework `redoOne(.local_user)` first;
    /// **if no candidate, legacy `doc.redoOne()`** (for unrecorded ops that landed on the redo stack via legacy undo).
    /// A legacy re-push is not a "new edit", so advance `last_seen_handle` to avoid an epoch bump.
    /// Framework redo's re-dispatch already advances via `dispatchPixieAction`'s noteUndo path.
    /// On error (PartialRedo etc.) do not fall through to legacy (do not stack on a partial apply).
    fn userRedo(self: *App) void {
        var buf: [256]u8 = undefined;
        const seq_before = self.cmd_log.next_seq;
        const outcome = self.cmd_exec.redoOne(.local_user, &buf) catch |err| {
            std.debug.print("pixie: redoOne failed: {s}\n", .{@errorName(err)});
            self.tagOwnersFromRecords(seq_before, OP_OWNER_USER); // Tag the already-applied portion even on PartialRedo
            self.captureHistoryVisualsSince(seq_before); // Capture already-appended records even on PartialRedo
            return;
        };
        if (!outcome.happened) {
            const handle_before = self.doc.undo.next_handle;
            self.doc.redoOne(self.gpa);
            self.last_seen_handle = self.doc.undo.next_handle;
            // Only when legacy redo actually re-pushed, settle owner as user (on no-op do not
            // overwrite the existing top, which may be agent-owned. Updating last_seen skips
            // checkUnrecordedEdits' unknown→USER settle, so tag directly here)
            if (self.doc.undo.next_handle > handle_before) {
                if (self.doc.undo.topHandle()) |h| self.doc.undo.setOwner(h, OP_OWNER_USER);
            }
            // legacy redo creates no CommandRecord → no new history thumbnail
            return;
        }
        self.tagOwnersFromRecords(seq_before, OP_OWNER_USER); // Newly re-dispatched ops are user-owned
        self.captureHistoryVisualsSince(seq_before);
    }

    /// Walk CommandLog backwards for a normal record with undo_ref==handle (userUndo's
    /// op→record pairing. Event-time only; linear scan of at most 128 slots).
    fn findRecordByUndoRef(self: *App, handle: u64) ?*const platform.command.CommandRecord {
        var i: u32 = self.cmd_log.filled;
        while (i > 0) {
            i -= 1;
            const rec = self.cmd_log.recordAt(i);
            if (rec.kind == .normal and rec.undo_ref != null and rec.undo_ref.? == handle) return rec;
        }
        return null;
    }

    /// End-of-frame detection of unrecorded undoable edits. On hit, expire local_user redo candidates
    /// via epoch (so an unrecorded UI op like layer add cannot make framework redo
    /// re-run a stale candidate).
    fn checkUnrecordedEdits(self: *App) void {
        if (self.doc.undo.next_handle > self.last_seen_handle) {
            self.markProjectDirty();
            self.cmd_exec.bumpEpoch(.local_user);
            self.last_seen_handle = self.doc.undo.next_handle;
            // Settle unrecorded-push owner as user (agent ops are tagged in-event; only user UI ops
            // stay unknown until frame end. O(depth) walk only when a bump fires)
            for (self.doc.undo.owners.items) |*o| {
                if (o.* == OP_OWNER_UNKNOWN) o.* = OP_OWNER_USER;
            }
        }
    }

    fn doClear(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        if (self.selectedLayerIsText()) return error.EditingBlocked; // Forbid direct edits on a text layer
        self.doc.pushClear(self.gpa, self.canvas.selected_layer) catch |err| switch (err) {
            error.TextLayerSelected => return error.EditingBlocked, // Defensive branch: the guard above should already have rejected this
        };
    }

    /// Draw one shape and push onto the UndoStack. Shared by UI commit / action shape.
    /// pixel_perfect is temporarily off. symmetry follows the recorder setting.
    fn doShape(self: *App, kind: actions.ShapeKind, p0: actions.Point, p1: actions.Point, fill: bool) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        if (self.selectedLayerIsText()) return error.TextLayerSelected;
        self.syncRecorderModes();
        const saved_pp = self.recorder.pixel_perfect;
        self.recorder.pixel_perfect = false;
        defer self.recorder.pixel_perfect = saved_pp;

        self.recorder.begin(self.canvas.selected_layer, self.palette.current());
        const PlotCtx = struct {
            rec: *core.StrokeRecorder,
            canvas: *core.Canvas,
            gpa: std.mem.Allocator,
            fn plot(c: *anyopaque, x: i32, y: i32) void {
                const s: *@This() = @ptrCast(@alignCast(c));
                s.rec.point(s.canvas, s.gpa, x, y);
            }
        };
        var pctx: PlotCtx = .{ .rec = &self.recorder, .canvas = self.canvas, .gpa = self.gpa };
        switch (kind) {
            .line => core.plotLine(p0.x, p0.y, p1.x, p1.y, &pctx, PlotCtx.plot),
            .rect => core.plotRect(p0.x, p0.y, p1.x, p1.y, fill, &pctx, PlotCtx.plot),
            .ellipse => core.plotEllipse(p0.x, p0.y, p1.x, p1.y, fill, &pctx, PlotCtx.plot),
        }
        if (self.recorder.finish(self.gpa)) |pd| {
            try self.doc.pushPaintOp(self.gpa, pd.layer_idx, pd.diffs);
        }
    }

    /// Set the symmetry drawing mode (shared by UI / action set_symmetry).
    fn doSetSymmetry(self: *App, mode: core.Symmetry) void {
        self.symmetry = mode;
        self.recorder.symmetry = mode;
    }

    /// Set pixel-perfect (shared by UI / action set_pixel_perfect).
    fn doSetPixelPerfect(self: *App, on: bool) void {
        self.pixel_perfect = on;
    }

    /// UI toggle for symmetry (during netsync: routeAction; solo: do* directly).
    fn uiSetSymmetry(self: *App, mode: core.Symmetry) void {
        const args: []const u8 = switch (mode) {
            .off => "off",
            .vertical => "v",
            .horizontal => "h",
            .quad => "quad",
        };
        if (platform.netsyncActive()) self.routeUi("set_symmetry", args) else self.doSetSymmetry(mode);
    }

    /// UI toggle for pixel_perfect (during netsync: routeAction).
    fn uiSetPixelPerfect(self: *App, on: bool) void {
        if (platform.netsyncActive()) {
            self.routeUi("set_pixel_perfect", if (on) "1" else "0");
        } else {
            self.doSetPixelPerfect(on);
        }
    }

    /// Copy the selection to the clipboard (read-only; no undo). No-op without a selection.
    /// Read-only (does not change pixels), so allowed even when a text layer is selected.
    fn doCopy(self: *App) void {
        if (self.editingBlocked()) return;
        const sel = self.canvas.selection orelse return;
        const block = core.selection.extract(self.gpa, self.canvas, self.canvas.selected_layer, sel);
        if (self.clipboard) |*old| old.deinit(self.gpa);
        self.clipboard = block;
    }

    /// Copy the selection to the clipboard and clear the selection to transparent (undoable). No-op without a selection.
    fn doCut(self: *App) void {
        if (self.editingBlocked()) return;
        if (self.selectedLayerIsText()) return; // Forbid direct edits on a text layer
        const sel = self.canvas.selection orelse return;
        const block = core.selection.extract(self.gpa, self.canvas, self.canvas.selected_layer, sel);
        if (self.clipboard) |*old| old.deinit(self.gpa);
        self.clipboard = block;
        if (core.selection.clearRectCmd(self.gpa, self.canvas, self.canvas.selected_layer, sel)) |pd| {
            self.doc.pushPaintOp(self.gpa, pd.layer_idx, pd.diffs) catch {}; // Text layer already rejected above
        }
    }

    /// Paste the clipboard (undoable). Destination is the selection top-left (or 0,0 if none).
    /// Update selection to the pasted rect (clipped to the canvas). No-op without a clipboard.
    fn doPaste(self: *App) void {
        if (self.editingBlocked()) return;
        if (self.selectedLayerIsText()) return; // Forbid direct edits on a text layer
        const block = self.clipboard orelse return;
        const dx: i32 = if (self.canvas.selection) |s| s.x else 0;
        const dy: i32 = if (self.canvas.selection) |s| s.y else 0;
        if (core.selection.pasteCmd(self.gpa, self.canvas, self.canvas.selected_layer, block, dx, dy, self.blend_mode)) |pd| {
            self.doc.pushPaintOp(self.gpa, pd.layer_idx, pd.diffs) catch {}; // Text layer already rejected above
        }
        const dest = core.Rect{ .x = dx, .y = dy, .w = @intCast(block.w), .h = @intCast(block.h) };
        self.canvas.setSelection(core.selection.clipRect(dest, self.canvas.width, self.canvas.height));
    }

    /// `Document.addLayer` completes mutation + Op build + push internally.
    /// Return value is the new layer's LayerId raw (for action response `ok id=#N`).
    fn doAddLayer(self: *App) !u64 {
        if (self.editingBlocked()) return error.EditingBlocked;
        const idx = self.doc.addLayer(self.gpa) catch |err| {
            self.setSaveMsg("Layer add failed: {s}", .{@errorName(err)});
            return err;
        };
        self.clampTimelineTarget();
        return @intFromEnum(self.doc.layerIdAt(idx).?);
    }

    /// Delete the layer at an explicit index (no implicit selected reference).
    fn doDeleteLayer(self: *App, idx: usize) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        try self.doc.deleteLayer(self.gpa, idx);
        self.clampTimelineTarget();
    }

    /// Move the layer at an explicit index by delta (±1).
    fn doMoveLayer(self: *App, idx: usize, delta: i32) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        const to_i: i32 = @as(i32, @intCast(idx)) + delta;
        if (to_i < 0) return error.OutOfRange;
        try self.doc.reorderLayer(self.gpa, idx, @intCast(to_i));
    }

    /// Set layer visibility to an explicit value (shared implementation behind `doToggleLayerVisible`;
    /// also called directly from action `set_layer_visible`). `Document.setLayerVisible` completes
    /// mutation + Op build + push, including the idempotent no-op check.
    fn doSetLayerVisible(self: *App, idx: usize, on: bool) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        try self.doc.setLayerVisible(self.gpa, idx, on);
    }

    /// For the UI toggle button (invert current value). Out of range is silently ignored as before
    /// (caller must check idx bounds before `doSetLayerVisible` — avoids OOB when reading `!before`).
    fn doToggleLayerVisible(self: *App, idx: usize) void {
        if (idx >= self.canvas.layers.items.len) return;
        const before = self.canvas.layers.items[idx].visible;
        self.doSetLayerVisible(idx, !before) catch {};
    }

    fn doSetLayerOpacity(self: *App, idx: usize, value: u8) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        try self.doc.setLayerOpacity(self.gpa, idx, value);
    }

    /// Rename a layer. `Document.renameLayer` completes mutation + Op build + push, including the
    /// idempotent no-op check. Callers are the inline-edit commit
    /// (`commitRenameLayer`) and a future harness action.
    fn doRenameLayer(self: *App, idx: usize, new_name: []const u8) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        try self.doc.renameLayer(self.gpa, idx, new_name);
    }

    /// Called from the layer-row context menu "Rename...". Copy the current name into the edit buffer and
    /// start inline editing (commit via `commitRenameLayer`, cancel via `cancelRenameLayer`).
    fn beginRenameLayer(self: *App, idx: usize) void {
        if (idx >= self.canvas.layers.items.len) return;
        self.text_in.cancel(); // rename and text edit must not both be active
        self.rename_in.begin(idx, self.canvas.layers.items[idx].name());
        // If Space pan modifier is still held when rename starts, clear it — during rename the event pump
        // does not pass key_up through (see below), so a pre-rename Space could otherwise leave
        // space_down stuck.
        self.space_down = false;
    }

    /// Commit the edit (ENTER). Delegates to `doRenameLayer` and pushes Undo. Failures (OOB etc.) are ignored
    /// (same "best-effort from UI" pattern as other pending file ops).
    fn commitRenameLayer(self: *App) void {
        if (!self.rename_in.active) return;
        const idx = self.rename_in.layer_idx;
        const committed = self.rename_in.commit();
        self.doRenameLayer(idx, committed) catch {};
    }

    /// Cancel the edit (ESCAPE). Discard the buffer only; do not push Undo.
    fn cancelRenameLayer(self: *App) void {
        self.rename_in.cancel();
    }

    /// Handle key_down while renaming (called from the main-loop event pump in place of the usual
    /// `handleKey`). ENTER/KP_ENTER=commit, ESCAPE=cancel,
    /// BACKSPACE/DELETE=delete one char. Cmd+C/X/V go to the text clipboard (not the pixel clipboard).
    /// Suppress C/X/V during composition. Ignore everything else.
    fn handleRenameKey(self: *App, k: platform.KeyEvent) void {
        if (self.handleTextFieldClipboard(k, .rename)) return;
        if (k.key == .ENTER or k.key == .KP_ENTER) {
            self.commitRenameLayer();
        } else if (k.key == .ESCAPE) {
            self.cancelRenameLayer();
        } else if (k.key == .BACKSPACE or k.key == .DELETE) {
            self.rename_in.backspace();
        }
        // Ignore other keys (block tool-switch shortcuts etc.)
    }

    // ── Text layers ─────────────────────────────

    /// Add a new text layer (context menu "Add Text Layer"). Defaults:
    /// text "Text" / font_px=16 / current palette color / position (8,8); then select it.
    /// Undo uses the existing `.layer_add` (the Layer value copy already carries kind/text_params, so
    /// no Op change is needed — same mechanism as `doAddLayer`).
    fn doAddTextLayer(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        var params: core.TextParams = .{ .x = 8, .y = 8, .color = self.palette.current() };
        params.setText("Text");
        _ = self.doc.addTextLayer(self.gpa, params) catch |err| {
            self.setSaveMsg("Text layer add failed: {s}", .{@errorName(err)});
            return err;
        };
    }

    /// Update a text layer's text_params and re-rasterize (shared apply path for content commit, size/position
    /// sliders, and the color button). `Document.setLayerTextParams` completes the
    /// idempotent no-op check, shared-cel re-rasterize, and Op build+push.
    fn doSetTextParams(self: *App, idx: usize, params: core.TextParams) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        try self.doc.setLayerTextParams(self.gpa, idx, params);
    }

    /// Commit a text layer to a normal raster layer (Rasterize; context menu).
    /// pixels unchanged; only kind/text_params change. One Undo step reverses it.
    fn doRasterizeLayer(self: *App, idx: usize) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        _ = try self.doc.rasterizeLayer(self.gpa, idx);
    }

    /// Called from the layer-row context menu "Edit Text..." (enabled only when kind==text).
    /// Copy the current text into the edit buffer and start inline editing (commit via
    /// `commitTextEdit`, cancel via `cancelTextEdit`). `rename_in`/`text_in` are symmetric.
    fn beginTextEdit(self: *App, idx: usize) void {
        if (idx >= self.canvas.layers.items.len) return;
        if (self.canvas.layers.items[idx].kind != .text) return;
        self.rename_in.cancel(); // rename and text edit must not both be active (symmetric with beginRenameLayer)
        self.text_in.begin(idx, self.canvas.layers.items[idx].text_params.text());
        self.space_down = false; // Same reason as beginRenameLayer (prevent stuck Space)
    }

    /// Commit the edit (ENTER). Delegates to `doSetTextParams` (keep current color/size/position;
    /// update the string only). Failures (OOB etc.) are ignored (same pattern as other pending file ops).
    fn commitTextEdit(self: *App) void {
        if (!self.text_in.active) return;
        const idx = self.text_in.layer_idx;
        const committed = self.text_in.commit();
        if (idx >= self.canvas.layers.items.len) return;
        var params = self.canvas.layers.items[idx].text_params;
        params.setText(committed);
        self.doSetTextParams(idx, params) catch {};
    }

    /// Cancel the edit (ESCAPE). Discard the buffer only; do not push Undo.
    fn cancelTextEdit(self: *App) void {
        self.text_in.cancel();
    }

    /// Handle key_down while text-editing (symmetric with `handleRenameKey`).
    fn handleTextEditKey(self: *App, k: platform.KeyEvent) void {
        if (self.handleTextFieldClipboard(k, .text)) return;
        if (k.key == .ENTER or k.key == .KP_ENTER) {
            self.commitTextEdit();
        } else if (k.key == .ESCAPE) {
            self.cancelTextEdit();
        } else if (k.key == .BACKSPACE or k.key == .DELETE) {
            self.text_in.backspace();
        }
        // Ignore other keys (block tool-switch shortcuts etc.)
    }

    const TextFieldClipboardTarget = enum { rename, text };

    /// Cmd+C/X/V during rename / text edit. Return true if consumed (do not reach pixel clipboard / tool shortcuts).
    /// During composition (preedit present), suppress C/X/V but still treat as consumed.
    fn handleTextFieldClipboard(self: *App, k: platform.KeyEvent, target: TextFieldClipboardTarget) bool {
        const accel = k.modifiers.cmd or k.modifiers.ctrl;
        if (!accel or k.is_repeat) return false;
        if (k.key != .C and k.key != .X and k.key != .V) return false;
        if (self.preedit().len > 0) return true; // Suppress during composition (consumed)
        switch (k.key) {
            .C => {
                const text = switch (target) {
                    .rename => self.rename_in.clipboardCopy(),
                    .text => self.text_in.clipboardCopy(),
                };
                if (text) |t| platform.setClipboardText(t);
            },
            .X => {
                const text = switch (target) {
                    .rename => self.rename_in.clipboardCut(),
                    .text => self.text_in.clipboardCut(),
                };
                if (text) |t| platform.setClipboardText(t);
            },
            .V => {
                var buf: [96]u8 = undefined; // text_content max; rename is short enough to share
                if (platform.getClipboardText(buf[0..])) |t| {
                    switch (target) {
                        .rename => self.rename_in.clipboardPaste(t),
                        .text => self.text_in.clipboardPaste(t),
                    }
                }
            },
            else => unreachable,
        }
        return true;
    }

    fn doSelectLayer(self: *App, idx: usize) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        try self.doc.selectLayer(idx);
    }

    /// Duplicate the layer at an explicit index and insert it above (Duplicate;
    /// no implicit selected reference). Return value is the new layer's LayerId raw (for action responses).
    /// `Document.duplicateLayer` completes mutation + Op build + push, including the
    /// raster (deep-copy each frame) / text (link a new cel across all frames) branch.
    fn doDuplicateLayer(self: *App, idx: usize) !u64 {
        if (self.editingBlocked()) return error.EditingBlocked;
        const new_idx = self.doc.duplicateLayer(self.gpa, idx) catch |err| {
            self.setSaveMsg("Layer duplicate failed: {s}", .{@errorName(err)});
            return err;
        };
        return @intFromEnum(self.doc.layerIdAt(new_idx).?);
    }

    /// Merge the layer at an explicit index into the layer below (Merge Down;
    /// no implicit selected reference). Src-over the selected layer (top) with opacity onto the lower layer
    /// (bottom=top-1) and delete top. The bottom-most layer (index 0) has no merge target, so
    /// error.OutOfRange.
    ///
    /// The two structural changes "composite onto below" and "delete above" are expressed as one atomic
    /// `.layer_merge_down` Op in libs/paint (undo.zig) with **1 push** (splitting into two UndoCmds
    /// could leave a stale coordinate reference if only one side is undone and another op is pushed
    /// in between).
    ///
    /// Hot path: event-time only (once per merge button/menu click). Walks every pixel of the lower layer
    /// (doc.width × doc.height) once at event time — not every frame
    /// (a scalar loop matching `Canvas.composite`/`UndoStack.pushClear` is enough;
    /// the performance-rules SIMD checklist does not apply).
    ///
    /// If either top or bottom has `kind==.text`, reject with `error.TextLayerSelected`
    /// ("is the selected layer text?" alone would miss top=raster(selected) + bottom=text, which would
    /// rewrite bottom's pixels directly and break the invariant that text-layer pixels are the
    /// re-rasterization of text_params).
    /// `Document.mergeDown` completes mutation + Op build + push, including the frame-count==1 limit,
    /// baking below and deleting top in one atomic push.
    fn doMergeDown(self: *App, idx: usize) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        try self.doc.mergeDown(self.gpa, idx);
    }

    // ── Timeline ──────────────────────────────────

    fn clampTimelineTarget(self: *App) void {
        if (self.doc.layers.items.len == 0) {
            self.timeline_target_layer = 0;
        } else if (self.timeline_target_layer >= self.doc.layers.items.len) {
            self.timeline_target_layer = self.doc.layers.items.len - 1;
        }
        if (self.doc.frames.items.len == 0) {
            self.timeline_target_frame = 0;
        } else if (self.timeline_target_frame >= self.doc.frames.items.len) {
            self.timeline_target_frame = @intCast(self.doc.frames.items.len - 1);
        }
    }

    fn doSelectFrame(self: *App, frame_idx: u32) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        if (frame_idx >= self.doc.frames.items.len) return error.OutOfRange;
        if (self.doc.selected_frame == frame_idx) return;
        self.doc.selected_frame = frame_idx;
        self.doc.resyncActiveView(self.gpa);
        self.syncPreviewCanvas();
        self.clampTimelineTarget();
    }

    fn doAddFrame(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        const at = self.doc.selected_frame + 1;
        try self.doc.addFrame(self.gpa, at);
        self.clampTimelineTarget();
    }

    fn doDuplicateFrame(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        try self.doc.duplicateFrame(self.gpa, self.doc.selected_frame);
        self.clampTimelineTarget();
    }

    fn doDeleteFrame(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        try self.doc.deleteFrame(self.gpa, self.doc.selected_frame);
        self.clampTimelineTarget();
    }

    fn doAdvanceFrame(self: *App, delta: i32) !void {
        const nf: i32 = @intCast(self.doc.frames.items.len);
        if (nf <= 0) return;
        const cur: i32 = @intCast(self.doc.selected_frame);
        const next = std.math.clamp(cur + delta, 0, nf - 1);
        try self.doSelectFrame(@intCast(next));
    }

    fn doCreateCelAt(self: *App, layer: usize, frame_idx: u32) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        if (layer >= self.doc.layers.items.len or frame_idx >= self.doc.frames.items.len) return error.OutOfRange;
        if (self.doc.layers.items[layer].kind == .text) return error.EditingBlocked;
        _ = self.doc.createCel(self.gpa, layer, frame_idx);
    }

    fn doClearCelAt(self: *App, layer: usize, frame_idx: u32) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        if (layer >= self.doc.layers.items.len or frame_idx >= self.doc.frames.items.len) return error.OutOfRange;
        if (self.doc.layers.items[layer].kind == .text) return error.EditingBlocked;
        const was_selected = self.doc.selected_frame == frame_idx;
        self.doc.clearCel(self.gpa, layer, frame_idx);
        if (was_selected) self.doc.resyncActiveView(self.gpa);
        self.clampTimelineTarget();
    }

    fn doLinkCelLeft(self: *App, layer: usize, frame_idx: u32) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        if (layer >= self.doc.layers.items.len or frame_idx == 0 or frame_idx >= self.doc.frames.items.len) return error.OutOfRange;
        if (self.doc.layers.items[layer].kind == .text) return error.EditingBlocked;
        try self.doc.linkCel(self.gpa, layer, frame_idx, frame_idx - 1);
    }

    fn doUnlinkCelAt(self: *App, layer: usize, frame_idx: u32) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        if (layer >= self.doc.layers.items.len or frame_idx >= self.doc.frames.items.len) return error.OutOfRange;
        if (self.doc.layers.items[layer].kind == .text) return error.EditingBlocked;
        try self.doc.unlinkCel(self.gpa, layer, frame_idx);
    }

    /// Playback tick at frame boundaries (once per frame; f64 compares only. Not full-pixel / not RT).
    /// Effective interval = playbackIntervalSec(fps, current frame's duration_ms). No catch-up (1 tick → 1 frame).
    ///
    /// `timeline_last_advance` is seeded with `getTime()` when play starts (UI / action play).
    /// Do not re-seed on `last==0` — with a virtual clock that starts at 0 that would overwrite every tick
    /// (last stays 0 until advance) and skew the step count.
    fn tickTimelinePlayback(self: *App, now: f64) void {
        if (!self.timeline_playing or self.editingBlocked()) return;
        const nframes = self.doc.frames.items.len;
        if (nframes == 0) return;
        const duration_ms = self.doc.frames.items[self.doc.selected_frame].duration_ms;
        const interval = core.document.playbackIntervalSec(self.timeline_fps, duration_ms);
        if (!core.document.shouldAdvance(now, self.timeline_last_advance, interval)) return;
        self.timeline_last_advance = now;
        const next: u32 = if (self.doc.selected_frame + 1 >= nframes) 0 else self.doc.selected_frame + 1;
        self.doSelectFrame(next) catch {};
    }

    /// For PNG open: shrink doc/active_view to "1 layer · 1 frame · 1 empty cel"
    /// (`Document.resetToSingleBlankLayer`; undo/redo are discarded inside as well).
    fn resetCanvasToSingleLayer(self: *App) void {
        self.doc.resetToSingleBlankLayer(self.gpa);
        self.sel_in.discardFloat(self.gpa); // Discard the float too
        self.invalidateHistoryAfterDocReset(); // Expire framework redo against the old document
    }

    fn syncPreviewCanvas(self: *App) void {
        while (self.preview_canvas.layers.items.len > self.canvas.layers.items.len) {
            const removed = self.preview_canvas.deleteLayer(self.preview_canvas.layers.items.len - 1).?;
            self.gpa.free(removed.pixels);
        }
        while (self.preview_canvas.layers.items.len < self.canvas.layers.items.len) {
            _ = self.preview_canvas.addLayer(self.gpa) catch @panic("syncPreviewCanvas: OOM");
        }
        for (self.canvas.layers.items, self.preview_canvas.layers.items) |src, *dst| {
            @memcpy(dst.pixels, src.pixels);
            dst.visible = src.visible;
            dst.opacity = src.opacity;
        }
        self.preview_canvas.selected_layer = self.canvas.selected_layer;
        // Sync selection too (so bezier preview drawing constraints match the commit)
        self.preview_canvas.selection = self.canvas.selection;
        // The @memcpy / visible / opacity writes above bypass the Canvas API, so
        // invalidate composite_cache explicitly.
        self.preview_canvas.markDirty();
    }

    /// Return the straight-alpha composite for drawing (preview_canvas while bezier/selection preview is active).
    fn resolveDisplayComposite(self: *App, gpa: std.mem.Allocator) []const u32 {
        if (self.active_kind == .bezier and self.bezier_editor.isEditing()) {
            self.syncPreviewCanvas();
            const dab = self.brush.footprint();
            self.bezier_editor.rasterizePreview(&self.preview_canvas, &self.preview_rec, gpa, dab, self.brush.color, self.brush.opacity);
            return self.preview_canvas.compositeStraight();
        }
        if (self.active_kind == .select and self.sel_in.state == .moving) {
            self.syncPreviewCanvas();
            _ = self.sel_in.renderMovePreview(self.preview_canvas.layerPixels(self.canvas.selected_layer), self.canvas.width, self.canvas.height, self.blend_mode);
            return self.preview_canvas.compositeStraight();
        }
        return self.canvas.compositeStraight();
    }

    /// Shared File/Edit/View execution entry.
    /// keyboard / GUI menu / menu_command events all converge here.
    /// File ops only queue pending_file_op (dialogs run at the runPendingFileOp safe point).
    /// Undo/Redo keep the existing doUndo/doRedo (hybrid userUndo + netsync route) and
    /// do not change results or undo recording.
    fn dispatchCommand(self: *App, id: platform.CommandId) void {
        // While size_dialog is open, do not run other menu commands (same "intercept while open" policy as
        // the early continue for recovery/confirmation. Prevents reentrant open via native keyEquivalent /
        // menuBarPopup, double confirmation, and layer ops).
        // Esc/Enter are handled on the key_down path and do not reach here.
        if (self.size_dialog != null) return;
        // Final defence against stale events / disabled items: at this shared entry re-check Command-table
        // presence + enabled. GUI click / shortcut already check locally, but native/harness
        // menu_command events carry a raw ID, so even a stale post-update event must not
        // run a disabled item (ignore, do not error).
        const cmd = self.findMenuCommand(id) orelse return;
        if (!cmd.enabled) return;
        if (id >= RECENT_CMD_BASE and id < RECENT_CMD_BASE + 10) {
            const index: usize = @intCast(id - RECENT_CMD_BASE);
            const items = self.recent.items();
            if (index < items.len) _ = self.requestProjectOpen(items[index]) catch |err| self.setSaveMsg("Recent open failed: {s}", .{@errorName(err)});
            return;
        }
        switch (id) {
            CmdId.new_document => _ = self.requestNewDocument() catch |err| self.setSaveMsg("New failed: {s}", .{@errorName(err)}),
            CmdId.new_size => self.openSizeDialog(.new_size),
            CmdId.resize_canvas => self.openSizeDialog(.resize),
            CmdId.open => {
                self.pending_file_op = .open;
                self.menu_pending_probe = .open;
            },
            CmdId.save => {
                self.pending_file_op = .save;
                self.menu_pending_probe = .save;
            },
            CmdId.save_as => {
                self.pending_file_op = .save_as;
                self.menu_pending_probe = .save_as;
            },
            CmdId.open_project => {
                self.pending_file_op = .open_project;
                self.menu_pending_probe = .open_project;
            },
            CmdId.save_project => {
                self.pending_file_op = .save_project;
                self.menu_pending_probe = .save_project;
            },
            CmdId.export_seq => {
                self.pending_file_op = .export_seq;
                self.menu_pending_probe = .export_seq;
            },
            CmdId.export_sheet => {
                self.pending_file_op = .export_sheet;
                self.menu_pending_probe = .export_sheet;
            },
            CmdId.save_palette => {
                self.pending_file_op = .save_palette;
                self.menu_pending_probe = .save_palette;
            },
            CmdId.load_palette => {
                self.pending_file_op = .load_palette;
                self.menu_pending_probe = .load_palette;
            },
            CmdId.undo => self.doUndo() catch {},
            CmdId.redo => self.doRedo() catch {},
            CmdId.toggle_history => _ = self.togglePanelVisible(PanelNames.history),
            CmdId.toggle_color => _ = self.togglePanelVisible(PanelNames.color),
            CmdId.toggle_palette => _ = self.togglePanelVisible(PanelNames.palette),
            CmdId.toggle_tool_options => _ = self.togglePanelVisible(PanelNames.tool_options),
            CmdId.toggle_layers => _ = self.togglePanelVisible(PanelNames.layers),
            CmdId.toggle_timeline => _ = self.togglePanelVisible(PanelNames.timeline),
            else => {},
        }
    }

    fn findPanel(self: *App, name: []const u8) ?*gui.Panel {
        for (&self.panels) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    fn isPanelVisible(self: *const App, name: []const u8) bool {
        for (&self.panels) |p| {
            if (std.mem.eql(u8, p.name, name)) return p.visible;
        }
        return false;
    }

    /// Shared by View menu / panel_toggle. Flip visibility and immediately persist Preferences.
    /// Unknown name → null. On success return the new visible.
    fn togglePanelVisible(self: *App, name: []const u8) ?bool {
        const p = self.findPanel(name) orelse return null;
        const new_vis = !p.visible;
        _ = self.panel_host.setPanelVisible(name, new_vis);
        self.persistPanels() catch |err| {
            std.log.err("pixie: preferences save failed: {s}", .{@errorName(err)});
        };
        return new_vis;
    }

    fn panelPersistence(self: *App) gui.Persistence {
        return .{ .user_data = self, .read = panelPersistRead, .write = panelPersistWrite };
    }

    /// Persists PanelHost layout into the in-memory Preferences, then saves it to disk.
    /// The disk save is skipped on wasm (no directory-capable filesystem); the in-memory
    /// state still updates so the current session's panel layout stays consistent.
    fn persistPanels(self: *App) !void {
        try self.panel_host.persist(self.panelPersistence());
        if (comptime appshell_dir_supported) try self.preferences.save(self.io, self.data_dir, "preferences.ash");
    }

    /// Update the display-only Tool Options title every frame (stable name unchanged; only Panel.title).
    fn syncToolOptionsTitle(self: *App) void {
        const written = std.fmt.bufPrint(&self.tool_options_title_buf, "Tool Options - {s}", .{self.active_kind.name()}) catch {
            self.tool_options_title_len = 0;
            if (self.findPanel(PanelNames.tool_options)) |p| p.title = null;
            return;
        };
        self.tool_options_title_len = written.len;
        if (self.findPanel(PanelNames.tool_options)) |p| {
            p.title = self.tool_options_title_buf[0..self.tool_options_title_len];
        }
    }

    /// Natural content height inside the Layers scroll (rows×row-height + Text Layer UI).
    fn layersNaturalContentHeight(self: *const App) i32 {
        const n: i32 = @intCast(self.canvas.layers.items.len);
        if (n <= 0) return LAYERS_VIEWPORT_ROW_MIN;
        const gap: i32 = 2; // beginScrollArea gap
        const pad_v: i32 = 4; // scroll padding top+bottom
        var h = n * LAYER_THUMB_H + (n - 1) * gap + pad_v;
        const idx = self.canvas.selected_layer;
        if (idx < self.canvas.layers.items.len and self.canvas.layers.items[idx].kind == .text) {
            h += LAYERS_TEXT_UI_FALLBACK;
        }
        return h;
    }

    /// Layers Collapsible heading + toolbar height. Measured previous-frame as panelRect − scroll rect.
    fn measureLayersChrome(self: *const App, ctx: *const gui.Context) i32 {
        if (self.panel_host.panelRect(ctx, PanelNames.layers)) |pr| {
            if (ctx.getNodeRect(LAYERS_SCROLL_ID)) |vp| {
                const chrome = @as(i32, @intCast(pr.h)) - @as(i32, @intCast(vp.h));
                if (chrome >= 20) return chrome;
            }
        }
        return LAYERS_CHROME_FALLBACK;
    }

    /// Outer width of the Layers body (previous-frame panel-wrap rect.w − margin).
    /// Collapsible body is width=.fit, so inject .fixed (avoids grow-in-fit collapse).
    /// Do not re-inject height from panelRect (chicken-and-egg shrink to content; width only).
    /// Margin is 24px (after the PanelHost right slot became scrollable, the outer ScrollArea viewport is
    /// one level deeper; the extra clip headroom is included. At 16px the Layers inner scrollbar
    /// (8px wide) sat outside the real clip and was not drawn).
    fn layersBodyAvail(self: *const App, ctx: *const gui.Context) i32 {
        if (self.panel_host.panelRect(ctx, PanelNames.layers)) |r| {
            return @max(1, @as(i32, @intCast(r.w)) - 24);
        }
        // First frame etc.: rect unset → base on right-slot extent
        return @max(1, self.panel_host.slotExtent(.right) - 24);
    }

    /// Fixed height of the Layers ScrollArea.
    ///
    /// Policy: prefer the natural height of other sections (Tool Options etc.) and
    /// clamp the Layers viewport to `clamp(content natural height, one row, remaining height)`.
    /// With one layer, reserve only one row and give the rest to Tool Options.
    ///
    /// Degradation: with every section open and a short window, remaining height can fall below one row.
    /// Then shrink Layers to one row; the shortfall is reached via the PanelHost right-slot outer ScrollArea.
    fn updateLayersViewportHeight(self: *App, ctx: *const gui.Context) void {
        const right = self.panel_host.slotRect(ctx, .right) orelse return;
        var others: i32 = 0;
        var other_count: i32 = 0;
        for ([_][]const u8{ PanelNames.color, PanelNames.palette, PanelNames.tool_options }) |name| {
            if (!self.isPanelVisible(name)) continue;
            if (self.panel_host.panelRect(ctx, name)) |r| {
                others += @intCast(r.h);
                other_count += 1;
            } else {
                // First frame etc.: other panel rects missing → provisional min from content (one row..natural)
                const natural = self.layersNaturalContentHeight();
                self.layers_viewport_h = std.math.clamp(natural, LAYERS_VIEWPORT_ROW_MIN, natural);
                return;
            }
        }
        const layers_on = self.isPanelVisible(PanelNames.layers);
        const visible_n = other_count + @as(i32, @intFromBool(layers_on));
        const gaps: i32 = if (visible_n > 1) (visible_n - 1) * PANEL_SLOT_GAP else 0;
        const layers_chrome = self.measureLayersChrome(ctx);
        const slot_h: i32 = @intCast(right.h);
        const remain = slot_h - PANEL_SLOT_PAD_V - gaps - others - layers_chrome;
        const natural = self.layersNaturalContentHeight();
        // Even if remain is tiny, keep one row (bottom clip is acceptable; see Degradation above)
        const max_h = @max(LAYERS_VIEWPORT_ROW_MIN, remain);
        self.layers_viewport_h = std.math.clamp(natural, LAYERS_VIEWPORT_ROW_MIN, max_h);
    }

    /// Call after endFrame. Record y/h of each right-slot panel and fb_h for `digest panels`.
    fn cachePanelsProbe(self: *App) void {
        self.panels_probe_fb_h = @intCast(self.ctx.screen_h);
        self.panels_probe_color = if (self.panel_host.panelRect(&self.ctx, PanelNames.color)) |r|
            .{ .y = r.y, .h = @intCast(r.h) }
        else
            null;
        self.panels_probe_palette = if (self.panel_host.panelRect(&self.ctx, PanelNames.palette)) |r|
            .{ .y = r.y, .h = @intCast(r.h) }
        else
            null;
        self.panels_probe_tool = if (self.panel_host.panelRect(&self.ctx, PanelNames.tool_options)) |r|
            .{ .y = r.y, .h = @intCast(r.h) }
        else
            null;
        self.panels_probe_layers = if (self.panel_host.panelRect(&self.ctx, PanelNames.layers)) |r|
            .{ .y = r.y, .h = @intCast(r.h) }
        else
            null;
        var bottom: i32 = 0;
        for ([_]?PanelProbeRect{
            self.panels_probe_color,
            self.panels_probe_palette,
            self.panels_probe_tool,
            self.panels_probe_layers,
        }) |maybe| {
            if (maybe) |r| bottom = @max(bottom, r.y + r.h);
        }
        self.panels_probe_bottom = bottom;
        self.panels_probe_slot = if (self.panel_host.slotRect(&self.ctx, .right)) |r|
            .{ .y = r.y, .h = @intCast(r.h) }
        else
            null;
        // ok = the right slot itself fits inside the framebuffer (raw overflow of panel natural height is allowed).
        self.panels_probe_ok = if (self.panels_probe_slot) |sr|
            sr.y >= 0 and sr.y + sr.h <= self.panels_probe_fb_h
        else
            false;
    }

    /// Look up an id in the Command table (separators excluded). Final defence for dispatchCommand.
    fn findMenuCommand(self: *const App, id: platform.CommandId) ?platform.Command {
        if (id == 0) return null;
        for (self.menu_commands[0..self.menu_command_count]) |cmd| {
            if (cmd.kind == .separator) continue;
            if (cmd.id == id) return cmd;
        }
        return null;
    }

    /// Rebuild the Command table from current app state (checked = each panel's visibility).
    fn rebuildMenuCommands(self: *App) void {
        const accel_mod: platform.ModifierFlags = if (builtin.os.tag == .macos)
            .{ .cmd = true }
        else
            .{ .ctrl = true };
        const accel_shift: platform.ModifierFlags = if (builtin.os.tag == .macos)
            .{ .cmd = true, .shift = true }
        else
            .{ .ctrl = true, .shift = true };

        var n: usize = 0;
        const put = struct {
            fn go(app: *App, idx: *usize, cmd: platform.Command) void {
                if (idx.* >= MENU_CMD_CAP) return;
                app.menu_commands[idx.*] = cmd;
                idx.* += 1;
            }
        }.go;

        put(self, &n, .{ .id = CmdId.new_document, .label = "New", .menu = .{ .title = "File", .order = 98 } });
        put(self, &n, .{
            .id = CmdId.new_size,
            .label = "New Size...",
            .menu = .{ .title = "File", .order = 99 },
            .enabled = !platform.netsyncActive(),
        });
        put(self, &n, .{ .id = CmdId.open, .label = "Open", .menu = .{ .title = "File", .order = 100 }, .shortcut = .{ .key = .O, .modifiers = accel_mod } });
        put(self, &n, .{ .id = CmdId.save, .label = "Save", .menu = .{ .title = "File", .order = 101 }, .shortcut = .{ .key = .S, .modifiers = accel_mod } });
        put(self, &n, .{ .id = CmdId.save_as, .label = "Save As", .menu = .{ .title = "File", .order = 102 }, .shortcut = .{ .key = .S, .modifiers = accel_shift } });
        put(self, &n, .{ .id = 0, .kind = .separator, .menu = .{ .title = "File", .order = 103 } });
        put(self, &n, .{ .id = CmdId.open_project, .label = "Prj Open", .menu = .{ .title = "File", .order = 104 } });
        put(self, &n, .{ .id = CmdId.save_project, .label = "Prj Save", .menu = .{ .title = "File", .order = 105 } });
        put(self, &n, .{ .id = 0, .kind = .separator, .menu = .{ .title = "File", .order = 106 } });
        put(self, &n, .{ .id = CmdId.export_seq, .label = "Exp Seq", .menu = .{ .title = "File", .order = 107 } });
        put(self, &n, .{ .id = CmdId.export_sheet, .label = "Exp Sheet", .menu = .{ .title = "File", .order = 108 } });
        put(self, &n, .{ .id = 0, .kind = .separator, .menu = .{ .title = "File", .order = 109 } });
        put(self, &n, .{ .id = CmdId.save_palette, .label = "Pal Save", .menu = .{ .title = "File", .order = 110 } });
        put(self, &n, .{ .id = CmdId.load_palette, .label = "Pal Load", .menu = .{ .title = "File", .order = 111 } });
        if (self.recent.items().len > 0) {
            put(self, &n, .{ .id = 0, .kind = .separator, .menu = .{ .title = "File", .order = 112 } });
            for (self.recent.items(), 0..) |path, index| {
                if (index >= 10) break;
                const base = std.fs.path.basename(path);
                var duplicate = false;
                for (self.recent.items(), 0..) |other, other_index| {
                    if (other_index != index and std.mem.eql(u8, base, std.fs.path.basename(other))) {
                        duplicate = true;
                        break;
                    }
                }
                put(self, &n, .{ .id = RECENT_CMD_BASE + @as(platform.CommandId, @intCast(index)), .label = if (duplicate) path else base, .menu = .{ .title = "File", .order = @intCast(113 + index) } });
            }
        }

        put(self, &n, .{ .id = CmdId.undo, .label = "Undo", .menu = .{ .title = "Edit", .order = 200 }, .shortcut = .{ .key = .Z, .modifiers = accel_mod }, .execution_policy = .undo });
        put(self, &n, .{ .id = CmdId.redo, .label = "Redo", .menu = .{ .title = "Edit", .order = 201 }, .shortcut = .{ .key = .Z, .modifiers = accel_shift }, .execution_policy = .redo });
        put(self, &n, .{
            .id = CmdId.resize_canvas,
            .label = "Resize Canvas...",
            .menu = .{ .title = "Edit", .order = 202 },
            .enabled = !platform.netsyncActive(),
        });

        put(self, &n, .{ .id = CmdId.toggle_history, .label = "History", .menu = .{ .title = "View", .order = 300 }, .checked = self.isPanelVisible(PanelNames.history), .shortcut = .{ .key = .H, .modifiers = accel_shift } });
        put(self, &n, .{ .id = CmdId.toggle_color, .label = "Color", .menu = .{ .title = "View", .order = 301 }, .checked = self.isPanelVisible(PanelNames.color), .shortcut = .{ .key = .C, .modifiers = accel_shift } });
        put(self, &n, .{ .id = CmdId.toggle_palette, .label = "Palette", .menu = .{ .title = "View", .order = 302 }, .checked = self.isPanelVisible(PanelNames.palette), .shortcut = .{ .key = .P, .modifiers = accel_shift } });
        put(self, &n, .{ .id = CmdId.toggle_tool_options, .label = "Tool Options", .menu = .{ .title = "View", .order = 303 }, .checked = self.isPanelVisible(PanelNames.tool_options), .shortcut = .{ .key = .O, .modifiers = accel_shift } });
        put(self, &n, .{ .id = CmdId.toggle_layers, .label = "Layers", .menu = .{ .title = "View", .order = 304 }, .checked = self.isPanelVisible(PanelNames.layers), .shortcut = .{ .key = .L, .modifiers = accel_shift } });
        put(self, &n, .{ .id = CmdId.toggle_timeline, .label = "Timeline", .menu = .{ .title = "View", .order = 305 }, .checked = self.isPanelVisible(PanelNames.timeline), .shortcut = .{ .key = .T, .modifiers = accel_shift } });

        self.menu_command_count = n;
    }

    fn menuCommandsSlice(self: *App) []const platform.Command {
        return self.menu_commands[0..self.menu_command_count];
    }

    fn saveNativeMenuSnapshot(self: *App) void {
        const cmds = self.menuCommandsSlice();
        self.native_menu_snap_count = cmds.len;
        for (cmds, 0..) |cmd, i| {
            var snap: NativeMenuSnap = .{
                .id = cmd.id,
                .enabled = cmd.enabled,
                .checked = cmd.checked,
                .kind = cmd.kind,
                .label_hash = hashMenuStr(cmd.label),
                .label_len = cmd.label.len,
                .title_hash = hashMenuStr(cmd.menu.title),
                .title_len = cmd.menu.title.len,
            };
            if (cmd.shortcut) |sc| {
                snap.has_shortcut = true;
                snap.shortcut_key = sc.key;
                snap.shortcut_mods = sc.modifiers;
            }
            self.native_menu_snap[i] = snap;
        }
    }

    fn nativeMenuStructureChanged(self: *const App) bool {
        const cmds = self.menu_commands[0..self.menu_command_count];
        if (cmds.len != self.native_menu_snap_count) return true;
        for (cmds, self.native_menu_snap[0..cmds.len]) |cmd, snap| {
            if (cmd.id != snap.id or cmd.kind != snap.kind) return true;
            if (cmd.label.len != snap.label_len or hashMenuStr(cmd.label) != snap.label_hash) return true;
            if (cmd.menu.title.len != snap.title_len or hashMenuStr(cmd.menu.title) != snap.title_hash) return true;
            if (cmd.shortcut) |sc| {
                if (!snap.has_shortcut) return true;
                if (sc.key != snap.shortcut_key) return true;
                if (sc.modifiers.toC() != snap.shortcut_mods.toC()) return true;
            } else if (snap.has_shortcut) {
                return true;
            }
        }
        return false;
    }

    fn nativeMenuStateChanged(self: *const App) bool {
        const cmds = self.menu_commands[0..self.menu_command_count];
        if (cmds.len != self.native_menu_snap_count) return true;
        for (cmds, self.native_menu_snap[0..cmds.len]) |cmd, snap| {
            if (cmd.enabled != snap.enabled or cmd.checked != snap.checked) return true;
        }
        return false;
    }

    /// updateMenu only when enabled/checked change. registerMenu on structural change.
    /// Forbid per-frame ObjC bridge calls via the dirty gate.
    fn syncNativeMenu(self: *App, win: *platform.Window) void {
        if (!self.native_menu_active) return;
        const cmds = self.menuCommandsSlice();
        if (!self.native_menu_registered or self.nativeMenuStructureChanged()) {
            win.registerMenu(cmds);
            self.saveNativeMenuSnapshot();
            self.native_menu_registered = true;
        } else if (self.nativeMenuStateChanged()) {
            win.updateMenu(cmds);
            self.saveNativeMenuSnapshot();
        }
    }

    /// Shortcut matching in the GUI-fallback environment (single-owner = app side).
    /// Primary accel is cmd or ctrl (same as existing handleKey).
    /// Not called when the native menu is active — keyEquivalent owns shortcuts then.
    fn matchMenuShortcut(self: *const App, k: platform.KeyEvent) ?platform.CommandId {
        const accel = k.modifiers.cmd or k.modifiers.ctrl;
        for (self.menu_commands[0..self.menu_command_count]) |cmd| {
            if (cmd.kind == .separator) continue;
            if (!cmd.enabled) continue;
            const sc = cmd.shortcut orelse continue;
            if (sc.key != k.key) continue;
            const want_accel = sc.modifiers.cmd or sc.modifiers.ctrl;
            if (want_accel != accel) continue;
            if (sc.modifiers.shift != k.modifiers.shift) continue;
            if (sc.modifiers.alt != k.modifiers.alt) continue;
            return cmd.id;
        }
        return null;
    }

    fn requestClose(self: *App, win: *platform.Window) void {
        if (self.recovery != null) {
            win.cancelQuit();
            return;
        }
        const result = self.host.requestClose() catch |err| {
            self.setSaveMsg("Close failed: {s}", .{@errorName(err)});
            win.cancelQuit();
            return;
        };
        if (result == .allowed) {
            self.running = false;
        } else {
            win.cancelQuit();
            self.refreshTitle();
        }
    }

    fn handleConfirmationClick(self: *App, x: i32, y: i32) void {
        if (self.recovery != null) {
            if (x >= 100 and x < 210 and y >= 480 and y < 520) recoverAutosave(self) catch |err| self.setSaveMsg("Recover failed: {s}", .{@errorName(err)}) else if (x >= 245 and x < 355 and y >= 480 and y < 520) discardRecovery(self) catch |err| self.setSaveMsg("Discard recovery failed: {s}", .{@errorName(err)});
            return;
        }
        if (x < 100 or x >= 500 or y < 480 or y >= 520) return;
        if (x < 210) {
            if (self.host.nameState() == .untitled) {
                self.pending_file_op = .confirm_save_as;
                self.dialog_op = null;
            } else {
                const result = self.host.confirmSave(null) catch |err| {
                    self.setSaveMsg("Project save failed: {s}", .{@errorName(err)});
                    return;
                };
                finishHostResult(self, result);
            }
        } else if (x < 355) {
            const result = self.host.confirmDiscard() catch |err| {
                self.setSaveMsg("Discard failed: {s}", .{@errorName(err)});
                return;
            };
            finishHostResult(self, result);
        } else {
            finishHostResult(self, self.host.confirmCancel());
        }
    }

    fn handleKey(self: *App, k: platform.KeyEvent) void {
        // Space is the pan modifier (track held state; release in handleKeyUp). Do not route elsewhere.
        if (k.key == .SPACE) {
            self.space_down = true;
            return;
        }
        // While editing a bezier, intercept tool keys (Enter=commit / Esc=cancel / Delete·Backspace=delete point)
        if (self.active_kind == .bezier and self.bezier_editor.isEditing()) {
            if (k.key == .ENTER or k.key == .KP_ENTER) {
                self.commitBezier();
                return;
            } else if (k.key == .ESCAPE) {
                self.bezier_editor.update(self.gpa, .cancel);
                return;
            } else if (k.key == .DELETE or k.key == .BACKSPACE) {
                self.bezier_editor.update(self.gpa, .delete);
                return;
            }
        }
        // Accelerator modifier for save etc.: macOS=Cmd / Linux=Ctrl.
        // On Linux (GNOME etc.) Super(=cmd) is reserved by the WM and never reaches the app, so also accept Ctrl
        // (Ctrl+S also matches Linux save convention. macOS stays Cmd; Ctrl works as an extra).
        const accel = k.modifiers.cmd or k.modifiers.ctrl;
        if (k.key == .ESCAPE) {
            // Esc while a menu is open only closes the menu (does not quit the app).
            // The popup itself closes when the next menuBarPopup sees open_title==null.
            if (self.menu_bar_state.open_title != null) {
                self.menu_bar_state.open_title = null;
                return;
            }
            // If shape/selection drag is active → cancel; else if selection (or float) exists → clear; else quit
            if (self.shape_in.state != .idle) {
                self.shape_in.cancel();
            } else if (self.sel_in.state != .idle) {
                self.sel_in.cancel(self.gpa); // Interrupt drag (discard float; real layer unchanged during drag)
            } else if (self.canvas.selection != null or self.sel_in.float != null) {
                self.canvas.clearSelection();
                self.sel_in.discardFloat(self.gpa);
            } else {
                if (self.os_window) |win| self.requestClose(win);
            }
        } else if (k.key == .Q and accel) {
            if (self.os_window) |win| self.requestClose(win);
        } else if (blk: {
            // When native is active, keyEquivalent owns shortcuts. Match only for GUI/headless.
            break :blk if (self.native_menu_active) null else self.matchMenuShortcut(k);
        }) |cmd_id| {
            // File/Edit shortcuts go through the Command table (single-owner; same entry as the GUI menu).
            self.dispatchCommand(cmd_id);
        } else if (k.key == .C and accel) {
            self.doCopy(); // accel+C is copy (decide before bare-C clear)
            // Also put the current color #RRGGBB on the system clipboard (wasm Clipboard API)
            self.copySystemColor();
        } else if (k.key == .X and accel) {
            self.doCut();
        } else if (k.key == .V and accel) {
            self.doPaste();
            // Async request to paste a color from the system clipboard (applied in runPendingFileOp)
            platform.clipboardRequestPaste();
        } else if (k.key == .B) {
            self.setActiveKind(.pen);
        } else if (k.key == .E) {
            self.setActiveKind(.eraser);
        } else if (k.key == .P) {
            self.setActiveKind(.bezier);
        } else if (k.key == .M) {
            self.setActiveKind(.select);
        } else if (k.key == .G) {
            self.setActiveKind(.fill);
        } else if (k.key == .I) {
            self.setActiveKind(.eyedropper); // Photoshop/GIMP-style key binding (temporary eyedropper is Alt+click)
        } else if (k.key == .C) {
            self.doClear() catch {};
        } else if (k.key == .@"0") {
            self.setZoomCentered(Zoom.one()); // 100% (1x) center reset
        } else if (k.key == .F) {
            self.fitZoom();
        } else if (k.key == .KP_ADD) {
            // Cursor position is finalized in updateViewport, so defer (zoom-to-cursor)
            self.pending_zoom_delta += 1;
        } else if (k.key == .KP_SUBTRACT) {
            self.pending_zoom_delta -= 1;
        }
    }

    /// key_up handling. Currently only releases the Space pan modifier.
    fn handleKeyUp(self: *App, k: platform.KeyEvent) void {
        if (k.key == .SPACE) self.space_down = false;
    }

    /// Commit bezier (rasterize with current brush footprint + color/opacity → `Document.pushPaintOp`).
    fn commitBezier(self: *App) void {
        const dab = self.brush.footprint();
        if (self.bezier_editor.rasterizeCommit(self.canvas, &self.recorder, self.gpa, dab, self.brush.color, self.brush.opacity)) |pd| {
            self.doc.pushPaintOp(self.gpa, pd.layer_idx, pd.diffs) catch {}; // This path is not reached while a text layer is selected
        }
    }
};

// ============================================================================
// Headless-harness custom probes
//
// Opt-in via `platform.registerProbe`. The framework does not interpret the body; it only writes snapshot raw bytes
// to a file / streams the one-line digest to the sink. Probe meaning stays inside the callbacks below.
// ctx is *App. When the harness is disabled, registration itself is a no-op so normal runs are unaffected.
// ============================================================================

/// canvas digest: size / layer count / selected / composite crc / layer metadata.
/// If it does not fit in 1024B, truncate and append top-level `trunc=1` at the end.
fn canvasDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var len: usize = 0;
    var truncated = false;
    const head = std.fmt.bufPrint(buf[len..], "{d}x{d} layers={d} selected={d} comp={X:0>8}", .{
        app.doc.width,
        app.doc.height,
        app.canvas.layers.items.len,
        app.canvas.selected_layer,
        png.crc32(std.mem.sliceAsBytes(app.canvas.compositeStraight())),
    }) catch return buf[0..0];
    len += head.len;
    const sel_part = if (app.canvas.selection) |s|
        std.fmt.bufPrint(buf[len..], " sel={d},{d},{d},{d}", .{ s.x, s.y, s.w, s.h }) catch return buf[0..len]
    else
        std.fmt.bufPrint(buf[len..], " sel=none", .{}) catch return buf[0..len];
    len += sel_part.len;
    // Viewport observations. Top-level key=value, placed before layers so harness can still see them when truncated.
    // `zoom=` compatibility key: integer scale when den==1; sentinel `0` when den>1 (shrink).
    // Rational detail is also written as zoom_num / zoom_den / zoom_pct (additive only).
    {
        const doc_w = app.doc.width;
        const doc_h = app.doc.height;
        const zoom = app.view_zoom;
        const zoom_compat: u32 = if (zoom.den == 1) zoom.num else 0;
        if (app.last_area) |a| {
            const origin = displayOrigin(app, a);
            const mm = minimapDigestFields(app, a);
            const vp = std.fmt.bufPrint(buf[len..], " doc_w={d} doc_h={d} area_x={d} area_y={d} area_w={d} area_h={d} zoom={d} zoom_num={d} zoom_den={d} zoom_pct={d} origin_x={d} origin_y={d} cam_cx={d:.3} cam_cy={d:.3}{s}", .{
                doc_w, doc_h, a.x, a.y, a.w, a.h, zoom_compat, zoom.num, zoom.den, zoom.pct(), origin.x, origin.y, app.cam_cx, app.cam_cy, mm,
            }) catch {
                truncated = true;
                return actions.finishDigestWithTrunc(buf, len, truncated);
            };
            len += vp.len;
        } else {
            const vp = std.fmt.bufPrint(buf[len..], " doc_w={d} doc_h={d} zoom={d} zoom_num={d} zoom_den={d} zoom_pct={d} cam_cx={d:.3} cam_cy={d:.3} minimap=off minimap_rect=none visible_rect=none viewport_rect=none", .{
                doc_w, doc_h, zoom_compat, zoom.num, zoom.den, zoom.pct(), app.cam_cx, app.cam_cy,
            }) catch {
                truncated = true;
                return actions.finishDigestWithTrunc(buf, len, truncated);
            };
            len += vp.len;
        }
    }
    // Zoom slider track rect (additive; independent of last_area — it exists once buildUi has run
    // at least once). `zoom_slider_track_*` names the TRACK node specifically (sliderI32Id's
    // explicit ID names its track, not the [label][track][value] row it draws), so a replay script
    // can compute the on-screen knob position (see zoomSliderDigestFields) to drag it.
    {
        const zs = zoomSliderDigestFields(app);
        const zs_part = std.fmt.bufPrint(buf[len..], "{s}", .{zs}) catch {
            truncated = true;
            return actions.finishDigestWithTrunc(buf, len, truncated);
        };
        len += zs_part.len;
    }
    for (app.canvas.layers.items, 0..) |layer, idx| {
        var nonzero: usize = 0;
        for (layer.pixels) |p| {
            if (p != 0) nonzero += 1;
        }
        const crc = png.crc32(std.mem.sliceAsBytes(layer.pixels));
        // Put id= first in the nested block (so agents can discover #<id>).
        // Nested follows the expect-contains convention. Only a short decimal u64 id is added (1024B budget).
        const layer_id: u64 = if (app.doc.layerIdAt(idx)) |lid| @intFromEnum(lid) else 0;
        // Add text= inside nested only when kind=text (same convention as existing name=:
        // nested is matched with contains. text_content_input rejects ASCII controls so
        // newlines and similar cannot appear — the one-line contract holds).
        const part = if (layer.kind == .text)
            std.fmt.bufPrint(buf[len..], " l{d}{{id={d},v={},op={d},crc={X:0>8},nz={d},name={s},kind=text,text={s}}}", .{
                idx, layer_id, layer.visible, layer.opacity, crc, nonzero, layer.name(), layer.text_params.text(),
            }) catch {
                truncated = true;
                break;
            }
        else
            std.fmt.bufPrint(buf[len..], " l{d}{{id={d},v={},op={d},crc={X:0>8},nz={d},name={s},kind=raster}}", .{
                idx, layer_id, layer.visible, layer.opacity, crc, nonzero, layer.name(),
            }) catch {
                truncated = true;
                break;
            };
        len += part.len;
    }
    return actions.finishDigestWithTrunc(buf, len, truncated);
}

/// canvas snapshot: flat transparent PNG of the visible layers composited.
fn canvasSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    return core.encodePNG(app.canvas.compositeStraight(), app.doc.width, app.doc.height, allocator);
}

/// drawlist digest/snapshot: the current frame's DrawList (see libs/gui/src/drawlist_probe.zig).
fn drawlistDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    return gui.drawlistDigest(&app.ctx.draw_list, buf);
}
fn drawlistSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    return gui.drawlistDumpAlloc(allocator, &app.ctx.draw_list);
}

/// undo digest/snapshot: undo/redo stack depths (one JSON line). undo reduces depth.
fn undoDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    return std.fmt.bufPrint(buf, "{{\"depth\":{d},\"redo\":{d}}}", .{
        app.doc.undo.undo.items.len, app.doc.undo.redo.items.len,
    }) catch buf[0..0];
}

/// presence digest: ephemeral overlay state. Expired TTL entries are removed before output.
fn presenceDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    return app.presence.formatDigest(buf, platform.getTime());
}

/// menu digest: open/closed, item count, enabled/checked masks, pending_file_op.
/// `open=<title|none> items=<n> enabled=<hex> checked=<hex> pending=<tag|none>`
/// enabled/checked are bits in non-separator appearance order (bit0 = first item).
fn menuDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const open = if (app.menu_bar_state.open_title) |t| t else "none";
    var enabled_mask: u32 = 0;
    var checked_mask: u32 = 0;
    var items: u32 = 0;
    for (app.menu_commands[0..app.menu_command_count]) |cmd| {
        if (cmd.kind == .separator) continue;
        if (items >= 32) break;
        const bit: u32 = @as(u32, 1) << @intCast(items);
        if (cmd.enabled) enabled_mask |= bit;
        if (cmd.checked) checked_mask |= bit;
        items += 1;
    }
    // pending = FileOp actually still unconsumed (prefer in-flight dialog; the true state).
    // last_op = latch of the most recently dispatched FileOp (kept until the next dispatch. Under headless
    // it is consumed in the same frame, so "menu selection queued a FileOp" is observed here).
    const live_pending = app.dialog_op orelse app.pending_file_op;
    const pending = if (live_pending) |op| @tagName(op) else "none";
    const last_op = if (app.menu_pending_probe) |op| @tagName(op) else "none";
    // native=0|1: whether the OS native menu (NSMenu) is enabled
    // (headless always 0; macOS real window + enable_menu build = 1. For mechanical asserts on device).
    return std.fmt.bufPrint(buf, "open={s} items={d} enabled={X:0>8} checked={X:0>8} pending={s} last_op={s} native={d}", .{
        open, items, enabled_mask, checked_mask, pending, last_op, @intFromBool(app.native_menu_active),
    }) catch buf[0..0];
}

fn appshellDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var title_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const title = app.host.title(&title_buf);
    const path = app.host.currentPath() orelse "none";
    const recent0 = if (app.recent.items().len > 0) app.recent.items()[0] else "none";
    const recovery = if (app.recovery != null) "pending" else "none";
    const modal = if (app.recovery != null)
        "recovery"
    else if (app.host.confirmation() != .none)
        "confirmation"
    else if (app.size_dialog != null)
        "size"
    else
        "none";
    // Geometry is additive (headless = size only / pos=none. Detects silent false wiring).
    const geo = if (app.os_window) |win| win.getGeometry() else platform.WindowGeometry{
        .position = null,
        .size = .{ .width = 0, .height = 0 },
    };
    var pos_buf: [48]u8 = undefined;
    const pos = if (geo.position) |p|
        (std.fmt.bufPrint(&pos_buf, "{d},{d}", .{ p.x, p.y }) catch "err")
    else
        "none";
    // History-journal observability: whether a journal is bound, how the last restore went,
    // and how many records it holds (so a replay can assert persistence without a file path).
    const journal_stats = if (app.history_store) |*store| store.store().stats() else null;
    return std.fmt.bufPrint(buf, "dirty={d} path={s} confirm={s} recent={d} recent0={s} recovery={s} modal={s} autosave={d} netsync={d} history_journal={d} history_restore={s} history_undo={d} history_records={d} title={s} geom={d}x{d} pos={s}", .{
        @intFromBool(app.host.isDirty()),
        path,
        @tagName(app.host.confirmation()),
        app.recent.items().len,
        recent0,
        recovery,
        modal,
        @intFromBool(activeAutosavePresent(app)),
        @intFromBool(platform.netsyncActive()),
        @intFromBool(app.history_store != null),
        @tagName(app.history_restore.status),
        app.history_restore.undo_records,
        if (journal_stats) |st| st.live_count else 0,
        title,
        geo.size.width,
        geo.size.height,
        pos,
    }) catch buf[0..0];
}

/// Self-report for harness: returns a static label when the given injected event will be
/// consumed by an application state instead of reaching the main canvas / shortcut path.
///
/// Priority (first match wins):
/// 1. `recovery` — every event (full absorb)
/// 2. `confirmation` — every event (full absorb)
/// 3. `size` — `key_down` ESCAPE / ENTER / KP_ENTER while the size dialog is open
/// 4. `text_edit` — `key_down` and `char_input` while layer-rename or text-layer edit is active
///
/// Other events under size_dialog / text edit return null (they still reach GUI or pass through).
fn pixieInputBlocker(ctx: *anyopaque, event: platform.Event) ?[]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (app.recovery != null) return "recovery";
    if (app.host.confirmation() != .none) return "confirmation";
    if (app.size_dialog != null) {
        switch (event) {
            .key_down => |k| if (k.key == .ESCAPE or k.key == .ENTER or k.key == .KP_ENTER) return "size",
            else => {},
        }
        return null;
    }
    if (app.rename_in.active or app.text_in.active) {
        return switch (event) {
            .key_down, .char_input => "text_edit",
            else => null,
        };
    }
    return null;
}

fn activeAutosavePresent(app: *const App) bool {
    // No autosave file is ever written on wasm (no directory-capable filesystem), so it is
    // never present; skip touching the uninitialized autosave dir handle.
    if (comptime !appshell_dir_supported) return false;
    const name = appshell.paths.autosaveFileName(app.io, app.gpa, app.autosave.current_path) catch return false;
    defer app.gpa.free(name);
    app.autosave.dir.access(app.io, name, .{}) catch return false;
    return true;
}
fn undoSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    return std.fmt.allocPrint(allocator, "{{\"depth\":{d},\"redo\":{d}}}", .{
        app.doc.undo.undo.items.len, app.doc.undo.redo.items.len,
    });
}

/// tool digest/snapshot: current tool name + drawing color #RRGGBB.
fn toolDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const c = app.palette.current();
    const r: u8 = @truncate(c >> 16);
    const g: u8 = @truncate(c >> 8);
    const b: u8 = @truncate(c);
    return std.fmt.bufPrint(buf, "tool={s} color=#{X:0>2}{X:0>2}{X:0>2}", .{
        app.active_kind.name(), r, g, b,
    }) catch buf[0..0];
}

/// timeline digest: playback state as one top-level k=v line (no snapshot; expect-compatible).
/// Format: `playing=<0|1> frame=<n> frames=<n> fps=<f:.1> dur=<ms> layers=<n> onion=<0|1>`
fn timelineDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const sf = app.doc.selected_frame;
    const dur: u32 = if (sf < app.doc.frames.items.len)
        app.doc.frames.items[sf].duration_ms
    else
        100;
    return std.fmt.bufPrint(buf, "playing={d} frame={d} frames={d} fps={d:.1} dur={d} layers={d} onion={d}", .{
        @intFromBool(app.timeline_playing),
        sf,
        app.doc.frames.items.len,
        app.timeline_fps,
        dur,
        app.doc.layers.items.len,
        @intFromBool(app.onion_enabled),
    }) catch buf[0..0];
}

/// panels digest: previous-frame rects of each right-slot section and fb_h.
/// Format: `fb_h=<n> bottom=<n> ok=<0|1> RightSlot_y=<n> RightSlot_h=<n> Color_y=<n> ...`
/// `expect panels ok=1` means the right-slot bounds are inside the framebuffer (raw overflow of natural content is allowed).
fn panelsDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var len: usize = 0;
    len += (std.fmt.bufPrint(buf[len..], "fb_h={d} bottom={d} ok={d}", .{
        app.panels_probe_fb_h,
        app.panels_probe_bottom,
        @intFromBool(app.panels_probe_ok),
    }) catch return buf[0..0]).len;
    if (app.panels_probe_slot) |r| {
        len += (std.fmt.bufPrint(buf[len..], " RightSlot_y={d} RightSlot_h={d}", .{ r.y, r.h }) catch return buf[0..len]).len;
    }
    if (app.panels_probe_color) |r| {
        len += (std.fmt.bufPrint(buf[len..], " Color_y={d} Color_h={d}", .{ r.y, r.h }) catch return buf[0..len]).len;
    }
    if (app.panels_probe_palette) |r| {
        len += (std.fmt.bufPrint(buf[len..], " Palette_y={d} Palette_h={d}", .{ r.y, r.h }) catch return buf[0..len]).len;
    }
    if (app.panels_probe_tool) |r| {
        len += (std.fmt.bufPrint(buf[len..], " Tool_y={d} Tool_h={d}", .{ r.y, r.h }) catch return buf[0..len]).len;
    }
    if (app.panels_probe_layers) |r| {
        len += (std.fmt.bufPrint(buf[len..], " Layers_y={d} Layers_h={d}", .{ r.y, r.h }) catch return buf[0..len]).len;
    }
    return buf[0..len];
}
fn toolSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    var buf: [128]u8 = undefined;
    return allocator.dupe(u8, toolDigest(ctx, &buf));
}

/// diff digest: changed pixel count / bbox / most-frequent before and after colors vs the baseline snapshot.
/// On first use (unmarked) auto-init the baseline from the current composite and return changed=0. No snapshot.
fn diffDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (app.diff_base == null) {
        copyCompositeToDiffBase(app) catch return buf[0..0];
        return std.fmt.bufPrint(buf, "changed=0 bbox=none from=none to=none", .{}) catch buf[0..0];
    }
    const base = app.diff_base.?;
    const cur = app.canvas.compositeStraight();
    const r = diff.computeDiff(app.gpa, base, cur, app.doc.width, app.doc.height) catch return buf[0..0];
    if (r.changed == 0) {
        return std.fmt.bufPrint(buf, "changed=0 bbox=none from=none to=none", .{}) catch buf[0..0];
    }
    const from = diff.rgbChannels(r.from);
    const to = diff.rgbChannels(r.to);
    return std.fmt.bufPrint(buf, "changed={d} bbox={d},{d},{d},{d} from=#{X:0>2}{X:0>2}{X:0>2} to=#{X:0>2}{X:0>2}{X:0>2}", .{
        r.changed, r.x0, r.y0, r.x1, r.y1, from.r, from.g, from.b, to.r, to.g, to.b,
    }) catch buf[0..0];
}

/// palette digest: palette size / unique canvas colors / top 4 (aligned with fb top format).
/// Event-time only (compositeStraight + AutoHashMap histogram).
fn paletteDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const flat = app.canvas.compositeStraight();
    const n = flat.len;
    var counts = std.AutoHashMap(u32, u32).init(app.gpa);
    defer counts.deinit();
    for (flat) |p| {
        // Fully transparent pixels are excluded from used (visible-color stats)
        if (p & 0xFF000000 == 0) continue;
        const c = 0xFF000000 | (p & 0x00FFFFFF);
        const gop = counts.getOrPut(c) catch return buf[0..0];
        if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
    }
    const used = counts.count();
    // Top 4 colors (count desc; color asc on ties)
    const Top = struct { color: u32 = 0, count: u32 = 0 };
    var top = [_]Top{.{}} ** 4;
    const better = struct {
        fn f(a: Top, b: Top) bool {
            return a.count > b.count or (a.count == b.count and a.color < b.color);
        }
    }.f;
    var it = counts.iterator();
    while (it.next()) |e| {
        const cand = Top{ .color = e.key_ptr.*, .count = e.value_ptr.* };
        if (better(cand, top[0])) {
            top[3] = top[2];
            top[2] = top[1];
            top[1] = top[0];
            top[0] = cand;
        } else if (better(cand, top[1])) {
            top[3] = top[2];
            top[2] = top[1];
            top[1] = cand;
        } else if (better(cand, top[2])) {
            top[3] = top[2];
            top[2] = cand;
        } else if (better(cand, top[3])) {
            top[3] = cand;
        }
    }
    var len: usize = 0;
    len += (std.fmt.bufPrint(buf[len..], "colors={d} used={d} top=[", .{
        app.palette.colors.items.len, used,
    }) catch return buf[0..0]).len;
    // Denominator is all pixels including transparent — same % convention as fb digest
    var first = true;
    for (top) |t| {
        if (t.count == 0) continue;
        const pct = if (n == 0) 0 else @as(u64, t.count) * 100 / n;
        const sep = if (first) "" else ",";
        first = false;
        len += (std.fmt.bufPrint(buf[len..], "{s}#{X:0>6}:{d}%", .{
            sep, t.color & 0xFFFFFF, pct,
        }) catch break).len;
    }
    len += (std.fmt.bufPrint(buf[len..], "]", .{}) catch return buf[0..len]).len;
    return buf[0..len];
}

/// Copy compositeStraight into diff_base (alloc if needed). Never retain a borrowed slice.
fn copyCompositeToDiffBase(app: *App) !void {
    const n = @as(usize, app.doc.width) * @as(usize, app.doc.height);
    const dst = if (app.diff_base) |b| blk: {
        if (b.len != n) {
            app.gpa.free(b);
            app.diff_base = null;
            const nb = try app.gpa.alloc(u32, n);
            app.diff_base = nb;
            break :blk nb;
        }
        break :blk b;
    } else blk: {
        const b = try app.gpa.alloc(u32, n);
        app.diff_base = b;
        break :blk b;
    };
    const src = app.canvas.compositeStraight();
    @memcpy(dst, src);
}

/// cursor digest/snapshot: requested OS cursor shape + current tool + footprint ring radius.
/// The OS cursor itself does not appear in the framebuffer, so this asserts "the value pixie requested"
/// (whether the OS cursor actually changed is per-backend manual inspection).
fn cursorDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const shape_name: []const u8 = switch (app.cursor_shape) {
        .default => "default",
        .crosshair => "crosshair",
        .hidden => "hidden",
    };
    // ring_r only means something when Brush is selected (otherwise 0). Use the same clampedSize path as EdgeCache
    // so size interpretation cannot drift (see brush_edge_cache.clampedSize).
    const ring_r: u32 = if (app.active_kind == .brush) brush_edge_cache.clampedSize(&app.brush) / 2 else 0;
    return std.fmt.bufPrint(buf, "shape={s} tool={s} ring_r={d}", .{
        shape_name, app.active_kind.name(), ring_r,
    }) catch buf[0..0];
}
fn cursorSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    var buf: [128]u8 = undefined;
    return allocator.dupe(u8, cursorDigest(ctx, &buf));
}

/// CommandAdapter: framework-undo reverse-apply entry.
/// canUndo = handle still present + .paint + cel alive + position preconditions (`Document.canRevertByHandle`).
/// applyUndo is **infallible** (called only when canUndo==true. Even if the handle vanishes,
/// `revertByHandle` returns as a no-op — no partial undo). mode=.discard (redo of a recorded op is
/// CommandLog name/args re-dispatch, so the Op is discarded). resyncActiveView is inside revertByHandle;
/// App sync such as clampTimelineTarget is the undo/redo caller's job (same split as existing doUndo).
/// Structure-Op limits and pixel side-effect trade-offs: see `Document.canRevertByHandle`/`revertByHandle`.
fn adapterCanUndo(ctx: *anyopaque, rec: *const platform.command.CommandRecord) bool {
    const app: *App = @ptrCast(@alignCast(ctx));
    const ref = rec.undo_ref orelse return false;
    return app.doc.canRevertByHandle(ref);
}

fn adapterApplyUndo(ctx: *anyopaque, rec: *const platform.command.CommandRecord) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    _ = app.doc.revertByHandle(app.gpa, rec.undo_ref.?, .discard);
}

fn adapterSummarize(_: *anyopaque, rec: *const platform.command.CommandRecord, buf: []u8) []const u8 {
    return history_summary.summarizeRecord(rec, buf);
}

fn historyHasHandle(ctx: *anyopaque, ref: u64) bool {
    const app: *App = @ptrCast(@alignCast(ctx));
    return app.doc.undo.hasHandle(ref);
}

fn historyGetVisualMeta(ctx: *anyopaque, seq: u64) history_summary.VisualMeta {
    const app: *App = @ptrCast(@alignCast(ctx));
    return app.historyVisualMeta(seq);
}

fn historyResolvePeerOrigin(ctx: *anyopaque, peer_id: u32, label_buf: []u8) history_summary.ActorOriginResult {
    _ = ctx;
    const view = platform.netsyncResolvePeerOrigin(peer_id, label_buf) orelse return .{};
    return .{
        .kind = switch (view.kind) {
            .human => .human,
            .agent => .agent,
        },
        .label_len = view.label.len,
    };
}

fn historyCtx(app: *App) history_summary.HistoryContext {
    return .{
        .ctx = app,
        .hasHandle = historyHasHandle,
        .log = &app.cmd_log,
        .getVisualMeta = historyGetVisualMeta,
        .resolvePeerOrigin = if (platform.netsyncActive()) historyResolvePeerOrigin else null,
    };
}

/// history probe (formal schema): digest = latest + aggregates (for expect); snapshot = full JSON.
fn historyDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    return history_summary.formatDigest(historyCtx(app), buf);
}

fn historySnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    return history_summary.formatSnapshotJson(historyCtx(app), allocator);
}

// ============================================================================
// Headless-harness custom actions (pixie adopts registerAction)
//
// Opt-in via `platform.registerAction`. The write/operate counterpart of probes (read).
// Every action only calls the same `App.do*` methods as UI/keyboard (one entry point =
// undo unit = action unit. UI / keyboard / action all share the same decision code = guards inside do*).
// Parsers live in `actions.zig` (std only; no App/kit/platform) and are unit-tested there.
//
// action ⇄ UndoCmd pairing table (push = "does this action call cause undo.push?".
// At most once = 0 or 1. No action pushes more than once):
//
//   action              → App method            push  error on failure
//   ------------------  ---------------------  ----  --------------------------------
//   undo                cmd_exec.undoOne(.local_agent)  no*   EditingBlocked (no candidate = idempotent success;
//   redo                cmd_exec.redoOne(.local_agent)  no*   per-actor revert. UI Cmd+Z uses userUndo/userRedo)
//   clear               doClear                 yes   EditingBlocked
//   add_layer           doAddLayer              yes   EditingBlocked / allocator error
//   delete_layer        doDeleteLayer(idx)      yes   EditingBlocked / LastLayer / UnknownLayerId (args=`#<id>`|idx)
//   select_layer        doSelectLayer           no    EditingBlocked / OutOfRange / UnknownLayerId (.local_only)
//   set_layer_visible   doSetLayerVisible       yes*  EditingBlocked / OutOfRange / UnknownLayerId
//   set_layer_opacity   doSetLayerOpacity       yes*  EditingBlocked / OutOfRange / UnknownLayerId
//   move_layer          doMoveLayer(idx,δ)      yes   EditingBlocked / OutOfRange / UnknownLayerId (args=`#<id> ±1`)
//   duplicate_layer     doDuplicateLayer(idx)   yes   EditingBlocked / allocator error / UnknownLayerId
//   merge_down          doMergeDown(idx)        yes   EditingBlocked / OutOfRange / LastLayer / UnknownLayerId
//                                                      (atomic `.layer_merge_down` 1 entry; not 2 pushes)
//   * layer structure ops have canRevertByHandle=false → no noteUndo; wire undoable=false (MVP)
//   * add/delete/visible/opacity/move/duplicate/merge_down = .relay; select_layer = .local_only
//   set_color           doSetColorHex           no    (no guard; always succeeds)
//   set_tool            setActiveKind           no    (no guard; same "no reaction" tolerance as existing UI)
//   stroke              activeTool().onEvent direct yes  EditingBlocked / UnsupportedTool / parse errors
//   save                doSaveTo                no    underlying savePNG error
//   open                doOpenPath              no    EditingBlocked / decode errors
//   replace_color       doReplaceColor(layer)   yes*  EditingBlocked / TextLayer / OutOfRange / IdRequired / parse errors
//                                                      args=`[#id|idx] from to` (defaults to selected; #<id> required during netsync)
//   palette_ramp        doReplacePalette        no    parse errors (palette changes are not undoable; .reject_when_synced)
//   palette_from_png    doReplacePalette        no    EmptyPalette / decode errors (.reject_when_synced)
//   palette_set         doReplacePalette        no    parse errors (.reject_when_synced)
//
//   * an idempotent call with before==after pushes nothing (same as existing UI slider/checkbox behaviour).
//
//   Text-layer ops (doAddTextLayer/doSetTextParams/doRasterizeLayer) are not
//   registered as harness actions. Harness verifies them via UI (context menu
//   + `inject char` text input). Slot capacity is not the limiter
//   (MAX_ACTIONS = action_registry.MAX_ACTIONS has headroom);
//   these stay UI-only by design.
//
// Non-push actions (select_layer/set_color/set_tool/save/open/undo/redo themselves) being non-undoable is
// not a new inconsistency: the existing UI for the same ops (tool keys, HSV sliders, file I/O)
// also never called undo.push (see `applyEditColor`/`setActiveKind`/`doSave`). The invariant is
// that agents (actions) walk the exact same undo decision code as UI;
// extending UndoCmd structure (e.g. historizing tool/color) is out of scope here.
//
// Design note for networked ops: the action call stream (name+args) is the unit
// that would travel on the wire. UndoCmd pixel diffs are a per-node
// deterministic re-apply detail, not the granularity to send across
// the network.
// ============================================================================

fn actionApp(ctx: *anyopaque) *App {
    return @ptrCast(@alignCast(ctx));
}

/// action `undo`/`redo` (agent): registered callbacks that call framework
/// `undoOne`/`redoOne(.local_agent)` **directly**, not via executeAction (undo/redo are
/// **control commands** like begin_tx. Going through executeAction makes redoOne's internal re-dispatch hit `ReentrantDispatch`,
/// which is structurally impossible). Existing guards (editingBlocked) and post-run App sync (clampTimelineTarget)
/// match classic doUndo/doRedo. Agent ops are all recorded, so the hybrid (userUndo) path is unnecessary.
fn actionUndo(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    try actions.parseNoArgs(args);
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    const seq_before = app.cmd_log.next_seq;
    // defer: undoOne may mutate record flags even on failure (independent of next_seq, so
    // pick them up via dirty).
    defer app.markHistoryDirty();
    const outcome = try app.cmd_exec.undoOne(.local_agent, buf);
    app.captureHistoryVisualsSince(seq_before);
    app.clampTimelineTarget();
    return outcome.message;
}

fn actionRedo(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    try actions.parseNoArgs(args);
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    const seq_before = app.cmd_log.next_seq;
    // defer: redoOne may update redo_consumed even on mid-failure (next_seq can stay
    // unchanged, so pick them up via dirty).
    defer app.markHistoryDirty();
    const outcome = app.cmd_exec.redoOne(.local_agent, buf) catch |err| {
        app.tagOwnersFromRecords(seq_before, App.OP_OWNER_AGENT); // Tag the already-applied portion even on PartialRedo
        app.captureHistoryVisualsSince(seq_before);
        return err;
    };
    app.tagOwnersFromRecords(seq_before, App.OP_OWNER_AGENT); // Newly re-dispatched ops are agent-owned
    app.captureHistoryVisualsSince(seq_before);
    app.clampTimelineTarget();
    return outcome.message;
}

fn actionClear(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    try actions.parseNoArgs(args);
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    try app.doClear();
    return "ok";
}

fn actionAddLayer(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    try actions.parseNoArgs(args);
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    const id = try app.doAddLayer();
    return std.fmt.bufPrint(buf, "ok id=#{d}", .{id}) catch return error.ArgsTooLong;
}

/// LayerRef → current index. Stale id → `unknown_layer_id`; out-of-range index → `index_out_of_range`.
/// With `require_id_during_netsync=true` (.relay layer op), a bare index during netsync → `id_required`.
fn resolveLayerRef(app: *App, ref: actions.LayerRef, require_id_during_netsync: bool) !usize {
    if (require_id_during_netsync and actions.layerRefRejectDuringNetsync(ref, platform.netsyncActive())) {
        platform.setActionErrorDetail("id_required", "use #<id> from digest canvas during netsync");
        return error.IdRequired;
    }
    switch (ref) {
        .id => |raw| {
            const id: core.LayerId = @enumFromInt(raw);
            return app.doc.layerIndexOf(id) orelse {
                platform.setActionErrorDetail("unknown_layer_id", "layer was deleted or never existed");
                return error.UnknownLayerId;
            };
        },
        .index => |idx| {
            if (idx >= app.doc.layers.items.len) {
                platform.setActionErrorDetail("index_out_of_range", "use add_layer or 0..N-1");
                return error.OutOfRange;
            }
            return idx;
        },
    }
}

fn actionDeleteLayer(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    const ref = try actions.parseLayerRef(args);
    const idx = try resolveLayerRef(app, ref, true);
    try app.doDeleteLayer(idx);
    return "ok";
}

fn actionSelectLayer(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    const ref = try actions.parseLayerRef(args);
    // select_layer is .local_only (per-peer view), so bare index is allowed during netsync too.
    const idx = try resolveLayerRef(app, ref, false);
    try app.doSelectLayer(idx);
    return "ok";
}

fn actionSetLayerVisible(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    const p = try actions.parseLayerRefBool(args);
    const idx = try resolveLayerRef(app, p.ref, true);
    try app.doSetLayerVisible(idx, p.on);
    return "ok";
}

fn actionSetLayerOpacity(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    const p = try actions.parseLayerRefU8(args);
    const idx = try resolveLayerRef(app, p.ref, true);
    try app.doSetLayerOpacity(idx, p.value);
    return "ok";
}

fn actionMoveLayer(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    const p = try actions.parseLayerRefDelta(args);
    const idx = try resolveLayerRef(app, p.ref, true);
    try app.doMoveLayer(idx, p.delta);
    return "ok";
}

fn actionDuplicateLayer(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    const ref = try actions.parseLayerRef(args);
    const idx = try resolveLayerRef(app, ref, true);
    const id = try app.doDuplicateLayer(idx);
    return std.fmt.bufPrint(buf, "ok id=#{d}", .{id}) catch return error.ArgsTooLong;
}

fn actionMergeDown(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    const ref = try actions.parseLayerRef(args);
    const idx = try resolveLayerRef(app, ref, true);
    try app.doMergeDown(idx);
    return "ok";
}

/// `add` appends an empty frame; `select <idx>` selects a frame (for harness; one name to save registry slots).
fn actionFrame(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    var it = std.mem.tokenizeAny(u8, args, " \t");
    const sub = it.next() orelse return error.Empty;
    if (std.mem.eql(u8, sub, "add")) {
        if (it.next() != null) return error.TooManyTokens;
        try app.doAddFrame();
        return "ok";
    }
    if (std.mem.eql(u8, sub, "select")) {
        const idx_tok = it.next() orelse return error.Empty;
        if (it.next() != null) return error.TooManyTokens;
        const idx = std.fmt.parseUnsigned(u32, idx_tok, 10) catch return error.InvalidNumber;
        try app.doSelectFrame(idx);
        return "ok";
    }
    return error.InvalidNumber;
}

fn actionSetOnion(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const p = try actions.parseOnion(args);
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    app.onion_enabled = p.enabled;
    if (p.count) |c| {
        app.onion_count = @intCast(std.math.clamp(c, 1, core.onion_skin.max_count));
    }
    return "ok";
}

fn actionSetColor(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    const color = try actions.parseHexColor(args);
    app.doSetColorHex(color);
    return "ok";
}

fn actionSetTool(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    const trimmed = std.mem.trim(u8, args, " \t");
    const kind = std.meta.stringToEnum(ToolKind, trimmed) orelse return error.UnknownTool;
    app.setActiveKind(kind);
    return "ok";
}

/// `action shape <line|rect|ellipse> <p0> <p1> [fill]`.
/// Goes through `App.doShape` (same draw/undo path as UI commit). Agent undo uses `action undo`
/// (Cmd+Z is the local_user-only hybrid — same shape as existing stroke action).
fn actionShape(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    const parsed = try actions.parseShape(args, @intCast(app.doc.width), @intCast(app.doc.height));
    try app.doShape(parsed.kind, parsed.p0, parsed.p1, parsed.fill);
    return "ok";
}

/// `action set_symmetry <off|v|h|quad>`. Affects document drawing → .relay.
fn actionSetSymmetry(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    const mode = try actions.parseSymmetry(args);
    app.doSetSymmetry(switch (mode) {
        .off => .off,
        .v => .vertical,
        .h => .horizontal,
        .quad => .quad,
    });
    return "ok";
}

/// `action set_pixel_perfect <0|1>`. Affects Pen drawing → .relay.
fn actionSetPixelPerfect(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    app.doSetPixelPerfect(try actions.parsePixelPerfect(args));
    return "ok";
}

/// `action set_grid <0|1>`. View-only (a per-peer canvas overlay; no undo entry, no netsync relay).
fn actionSetGrid(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    app.grid_enabled = try actions.parseGrid(args);
    return "ok";
}

/// `action set_loupe <0|1>`. View-only (a per-peer canvas overlay; no undo entry, no netsync relay).
fn actionSetLoupe(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    app.loupe_enabled = try actions.parseLoupe(args);
    return "ok";
}

/// Drive a canvas-coordinate point list as down→move×N→up (same Tool path as existing canvas_input).
/// Accepts a leading `[tool=|color=|size=|opacity=|hardness=|tolerance=]` k=v prefix; latches the
/// explicit parameters **temporarily and restores App state after** (so redo cannot clobber the
/// current user settings). Local callers may omit `tool=` (resolved against the active tool at
/// canonicalize). A synced wire stroke without `tool=` is rejected (`error.ToolRequired`).
/// bezier/select/eyedropper stay explicitly rejected (avoids unintended Pen draws via
/// `activeTool()`'s unreachable fallbacks).
fn actionStroke(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    var pts_buf: [actions.MAX_STROKE_POINTS]actions.Point = undefined;
    const parsed = try actions.parseStroke(args, &pts_buf);

    if (platform.netsyncActive() and parsed.params.tool == null) {
        platform.setActionErrorDetail(
            "tool_required",
            "include tool=pen|eraser|brush|fill",
        );
        return error.ToolRequired;
    }

    const pts = parsed.points;
    const target_layer = if (parsed.params.layer) |ref|
        try app.resolveStrokeLayerIndex(ref)
    else
        app.canvas.selected_layer;
    if (target_layer >= app.canvas.layers.items.len) return error.LayerNotFound;
    if (app.canvas.layers.items[target_layer].kind == .text) return error.TextLayerSelected;
    const saved_doc_layer = app.doc.selected_layer;
    const saved_canvas_layer = app.canvas.selected_layer;
    defer {
        app.doc.selected_layer = saved_doc_layer;
        app.canvas.selected_layer = saved_canvas_layer;
    }
    app.doc.selected_layer = target_layer;
    app.canvas.selected_layer = target_layer;

    // Resolve and latch effective parameters (including fill color/tolerance).
    var tool: core.Tool = undefined;
    var stroke_tool: ?actions.StrokeTool = null;
    const saved_pen_color = app.pen.color;
    const saved_brush_color = app.brush.color;
    const saved_brush_size = app.brush.size;
    const saved_brush_opacity = app.brush.opacity;
    const saved_brush_hardness = app.brush.hardness_q;
    const saved_fill_color = app.fill.color;
    const saved_fill_tolerance = app.fill.tolerance;
    const saved_selection = app.canvas.selection;
    defer {
        app.pen.color = saved_pen_color;
        app.brush.color = saved_brush_color;
        app.brush.size = saved_brush_size;
        app.brush.opacity = saved_brush_opacity;
        app.brush.hardness_q = saved_brush_hardness;
        app.fill.color = saved_fill_color;
        app.fill.tolerance = saved_fill_tolerance;
        app.canvas.setSelection(saved_selection);
    }
    const eff = try app.resolveEffectiveStroke(parsed.params);
    stroke_tool = eff.tool;
    switch (eff.tool) {
        .pen => {
            app.pen.color = eff.color;
            tool = app.pen.tool();
        },
        .eraser => tool = app.eraser.tool(),
        .brush => {
            app.brush.color = eff.color;
            app.brush.size = eff.size;
            app.brush.opacity = eff.opacity;
            app.brush.hardness_q = eff.hardness;
            tool = app.brush.tool();
        },
        .fill => {
            app.fill.color = eff.color;
            app.fill.tolerance = eff.tolerance;
            // A relayed fill is defined without receiver-local selection.
            if (platform.netsyncActive()) app.canvas.clearSelection();
            tool = app.fill.tool();
        },
    }

    const is_continuation = (parsed.params.segment orelse .first) == .continuation;
    var cmd: ?core.PaintDiff = null;
    if (is_continuation) {
        // Start-point no-stamp. Fill has no multi-chunk continuation form.
        const st = stroke_tool orelse return error.UnsupportedTool;
        switch (st) {
            .pen => app.recorder.beginAt(target_layer, app.pen.color, pts[0].x, pts[0].y),
            .eraser => app.recorder.beginAt(target_layer, core.tool.ERASER_COLOR, pts[0].x, pts[0].y),
            .brush => {
                const dab = app.brush.footprint();
                app.recorder.brushBeginAt(target_layer, app.brush.color, app.brush.opacity, pts[0].x, pts[0].y);
                if (pts.len >= 2) {
                    for (pts[1..], 0..) |p, i| {
                        if (i == 0) {
                            app.recorder.stampLineToContinue(app.canvas, app.gpa, p.x, p.y, dab);
                        } else {
                            app.recorder.stampLineTo(app.canvas, app.gpa, p.x, p.y, dab);
                        }
                    }
                }
                cmd = app.recorder.brushFinish(app.canvas, app.gpa);
                if (cmd) |pd| try app.doc.pushPaintOp(app.gpa, pd.layer_idx, pd.diffs);
                return "ok";
            },
            .fill => return error.UnsupportedTool,
        }
        if (pts.len >= 2) {
            for (pts[1..], 0..) |p, i| {
                if (i == 0) {
                    app.recorder.lineToContinue(app.canvas, app.gpa, p.x, p.y);
                } else {
                    app.recorder.lineTo(app.canvas, app.gpa, p.x, p.y);
                }
            }
        }
        cmd = app.recorder.finish(app.gpa);
    } else {
        _ = tool.onEvent(app.canvas, &app.recorder, app.gpa, .{ .down = .{ .x = pts[0].x, .y = pts[0].y } });
        if (pts.len == 1) {
            cmd = tool.onEvent(app.canvas, &app.recorder, app.gpa, .{ .up = .{ .x = pts[0].x, .y = pts[0].y } });
        } else {
            for (pts[1..], 0..) |p, i| {
                if (i == pts.len - 2) {
                    cmd = tool.onEvent(app.canvas, &app.recorder, app.gpa, .{ .up = .{ .x = p.x, .y = p.y } });
                } else {
                    _ = tool.onEvent(app.canvas, &app.recorder, app.gpa, .{ .move = .{ .x = p.x, .y = p.y } });
                }
            }
        }
    }
    if (cmd) |pd| try app.doc.pushPaintOp(app.gpa, pd.layer_idx, pd.diffs);
    return "ok";
}

fn actionSave(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    const path = try actions.parsePath(args);
    try app.doSaveTo(path);
    return "ok";
}

fn actionOpen(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    const path = try actions.parsePath(args);
    _ = app.requestPngImport(path) catch |err| {
        // structured error: load failures (png normalizes FileNotFound etc. to ReadFailed) put a
        // self-recovery hint on the wire.
        if (err == error.ReadFailed or err == error.FileNotFound) {
            platform.setActionErrorDetail("file_not_found", "check path or use save first");
        }
        return err;
    };
    return "ok";
}

/// Materialize CommandLog kind=normal as Entry in seq order (recordAt oldest→newest).
/// Returned Entry name/args borrow buffers inside the log. Caller frees the slice.
fn recipeEntriesFromLog(log: *const platform.command.CommandLog, gpa: std.mem.Allocator) ![]recipe.Entry {
    var views_buf: [platform.command.MAX_CMD_LOG]recipe.RecordView = undefined;
    var n: usize = 0;
    var i: u32 = 0;
    while (i < log.filled) : (i += 1) {
        const rec = log.recordAt(i);
        views_buf[n] = .{
            .is_normal = rec.kind == .normal,
            .name = rec.name(),
            .args = rec.args(),
        };
        n += 1;
    }
    return recipe.collectNormalEntries(gpa, views_buf[0..n]);
}

/// `replace_color [#<id>|<index>] <from> <to>` (defaults to selected; #<id> required during netsync).
fn actionReplaceColor(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    const p = try actions.parseReplaceColor(args);
    const layer_idx: usize = if (p.layer) |ref|
        try resolveLayerRef(app, ref, true)
    else blk: {
        // Omit = selected. During netsync each peer has a different selected, so #<id> is required.
        if (platform.netsyncActive()) {
            platform.setActionErrorDetail("id_required", "use #<id> from digest canvas during netsync");
            return error.IdRequired;
        }
        break :blk app.canvas.selected_layer;
    };
    const n = try app.doReplaceColor(layer_idx, p.from, p.to);
    return std.fmt.bufPrint(buf, "ok replaced={d}", .{n}) catch return error.ArgsTooLong;
}

fn actionPaletteRamp(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    const p = try actions.parsePaletteRamp(args);
    var ramp: [palette_mod.MAX_RAMP_N]u32 = undefined;
    palette_mod.generateRamp(p.seed, p.n, ramp[0..p.n]);
    app.doReplacePalette(ramp[0..p.n]);
    return std.fmt.bufPrint(buf, "ok colors={d}", .{p.n}) catch return error.ArgsTooLong;
}

fn actionPaletteFromPng(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    const path = try actions.parsePath(args);
    var img = try png.decodePNGFile(app.io, app.gpa, path);
    defer img.deinit(app.gpa);
    const colors = try palette_mod.extractColorsByFrequency(app.gpa, img.pixels, palette_mod.MAX_PALETTE_COLORS);
    defer app.gpa.free(colors);
    if (colors.len == 0) return error.EmptyPalette;
    app.doReplacePalette(colors);
    return std.fmt.bufPrint(buf, "ok colors={d}", .{colors.len}) catch return error.ArgsTooLong;
}

fn actionPaletteSet(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    var color_buf: [actions.MAX_PALETTE_SET]u32 = undefined;
    const colors = try actions.parsePaletteSet(args, &color_buf);
    app.doReplacePalette(colors);
    return std.fmt.bufPrint(buf, "ok colors={d}", .{colors.len}) catch return error.ArgsTooLong;
}

fn actionDiffMark(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    try actions.parseNoArgs(args);
    try copyCompositeToDiffBase(actionApp(ctx));
    return "ok";
}

/// presence_* bypass recordedAction and do not touch Document/CommandLog/undo.
fn actionPresencePoint(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    const parsed = try actions.parsePresencePoint(args);
    app.presence.applyPoint(parsed, platform.getTime());
    return std.fmt.bufPrint(buf, "ok peer={d} x={d} y={d}", .{ parsed.peer_id, parsed.x, parsed.y }) catch "ok";
}

fn actionPresenceHighlight(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    const parsed = try actions.parsePresenceHighlight(args);
    app.presence.applyHighlight(parsed, platform.getTime());
    return std.fmt.bufPrint(buf, "ok peer={d}", .{parsed.peer_id}) catch "ok";
}

fn actionPresenceSuggest(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    const parsed = try actions.parsePresenceSuggest(args);
    app.presence.applySuggest(parsed, platform.getTime());
    return std.fmt.bufPrint(buf, "ok peer={d} x={d} y={d}", .{ parsed.peer_id, parsed.x, parsed.y }) catch "ok";
}

/// `play`: start timeline playback (same as the UI Play button). Not recorded in CommandLog; idempotent.
fn actionPlay(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    try actions.parseNoArgs(args);
    const app = actionApp(ctx);
    app.timeline_playing = true;
    app.timeline_last_advance = platform.getTime();
    return "ok";
}

/// `pause`: stop timeline playback. Not recorded in CommandLog; idempotent.
fn actionPause(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    try actions.parseNoArgs(args);
    const app = actionApp(ctx);
    app.timeline_playing = false;
    return "ok";
}

/// `goto_frame <idx>`: select the display frame (doSelectFrame; undo-free). Rejected while editing.
/// Not recorded in CommandLog (bypasses recordedAction). Out of range → structured error.
fn actionGotoFrame(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    app.checkEditingAllowed() catch {
        platform.setActionErrorDetail("editing_in_progress", "finish current stroke/selection first");
        return error.EditingBlocked;
    };
    const idx = try actions.parseGotoFrame(args);
    if (idx >= app.doc.frames.items.len) {
        platform.setActionErrorDetail("index_out_of_range", "use 0..frames-1");
        return error.OutOfRange;
    }
    try app.doSelectFrame(idx);
    return "ok";
}

/// `export_seq <stem>`: write numbered PNGs (not recorded in CommandLog; not undoable).
fn actionExportSeq(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    const stem = try actions.parseExportSeq(args);
    app.doExportSeqTo(stem) catch |err| {
        if (err == error.NoFrames) {
            platform.setActionErrorDetail("no_frames", "add frames before export");
        } else if (err == error.OutOfMemory) {
            platform.setActionErrorDetail("out_of_memory", "reduce canvas size or frame count");
        }
        return err;
    };
    return std.fmt.bufPrint(buf, "ok stem={s}", .{stem}) catch "ok";
}

/// `export_sheet <path> [columns] [margin]`: write a sprite sheet (not recorded in CommandLog).
fn actionExportSheet(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    const parsed = try actions.parseExportSheet(args);
    const opts: core.document_io.SpriteSheetOpts = .{
        .columns = parsed.columns,
        .margin = parsed.margin,
    };
    app.doExportSheetTo(parsed.path, opts) catch |err| {
        switch (err) {
            error.NoFrames => platform.setActionErrorDetail("no_frames", "add frames before export"),
            error.SheetTooLarge => platform.setActionErrorDetail("sheet_too_large", "reduce columns/margin or canvas size"),
            error.OutOfMemory => platform.setActionErrorDetail("out_of_memory", "reduce canvas size or frame count"),
            else => {},
        }
        return err;
    };
    return std.fmt.bufPrint(buf, "ok path={s}", .{parsed.path}) catch "ok";
}

/// `recipe_save <path>`: CommandLog → recipe file (header.app_name="pixie"). Not recorded (meta-op).
fn actionRecipeSave(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const path = try actions.parsePath(args);
    const entries = try recipeEntriesFromLog(&app.cmd_log, app.gpa);
    defer app.gpa.free(entries);
    try recipe.save(app.io, path, .{ .app_name = "pixie" }, entries, app.gpa);
    return "ok";
}

/// `recipe_replay <path>`: load → verify app_name → apply each entry via routeLocalAction in order.
/// Abort on failure (structured error includes which entry). Nested recipe_replay is rejected.
fn actionRecipeReplay(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    recipe.checkNotReplaying(app.recipe_replaying) catch {
        platform.setActionErrorDetail("nested_replay", "wait for current recipe_replay to finish");
        return error.NestedReplay;
    };
    const path = try actions.parsePath(args);
    var loaded = recipe.load(app.io, app.gpa, path) catch |err| {
        if (err == error.FileNotFound) {
            platform.setActionErrorDetail("file_not_found", "check path or use recipe_save first");
        }
        return err;
    };
    defer loaded.deinit();

    recipe.checkAppName(loaded.header.app_name, "pixie") catch {
        platform.setActionErrorDetail("app_mismatch", "open with the correct app");
        return error.AppMismatch;
    };

    app.recipe_replaying = true;
    defer app.recipe_replaying = false;

    for (loaded.entries, 0..) |entry, idx| {
        _ = platform.routeAction(entry.name, entry.args, buf) catch |err| {
            // Nested recipe_replay: the inner already set nested_replay detail → do not overwrite
            if (err == error.NestedReplay) return err;
            var code_buf: [32]u8 = undefined;
            const code = std.fmt.bufPrint(&code_buf, "replay_failed_at_{d}", .{idx + 1}) catch "replay_failed";
            var next_buf: [200]u8 = undefined;
            const next = std.fmt.bufPrint(&next_buf, "fix entry {d} ({s}) or preceding state", .{ idx + 1, entry.name }) catch "fix recipe entry";
            platform.setActionErrorDetail(code, next);
            return error.ReplayFailed;
        };
    }
    return "ok";
}

// Text-layer actions (doAddTextLayer/doSetTextParams/doRasterizeLayer) remain
// unregistered. Harness verifies them via existing `inject mouse_down/up` + `inject char`.
// (MAX_ACTIONS has headroom; leaving them UI-only is by design, not a capacity limit.)

// ============================================================================
// command-model integration
//
// App owns CommandLog + Executor (always on, fixed capacity). Recording is centralized in two places:
//   1. Via registerAction (harness `action` / copilot `action`) → the recording wrapper below
//      dispatches + records via `executeAction(actor=.local_agent)` against the PIXIE_ACTIONS table
//   2. At UI canvas-stroke commit → `App.recordUiStroke` (`recordExecuted(actor=.local_user)`)
// undo/redo actions use `.no_record` (the normalized undo form is the revert record; do not pollute
// the log as a normal record). undo_ref is the handle from `UndoStack.handles` (action⇄UndoCmd pairing).
// ============================================================================

const ActionEntry = struct {
    name: []const u8,
    run: *const fn (ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8,
};

/// name→handler table (looked up by `dispatchPixieAction`; separate from registration wrappers).
/// undo/redo are not listed (outside executeAction/redo re-dispatch = control commands.
/// Register actionUndo/actionRedo directly on the registry).
const PIXIE_ACTIONS = [_]ActionEntry{
    .{ .name = "clear", .run = actionClear },
    .{ .name = "add_layer", .run = actionAddLayer },
    .{ .name = "delete_layer", .run = actionDeleteLayer },
    .{ .name = "select_layer", .run = actionSelectLayer },
    .{ .name = "set_layer_visible", .run = actionSetLayerVisible },
    .{ .name = "set_layer_opacity", .run = actionSetLayerOpacity },
    .{ .name = "move_layer", .run = actionMoveLayer },
    .{ .name = "duplicate_layer", .run = actionDuplicateLayer },
    .{ .name = "merge_down", .run = actionMergeDown },
    .{ .name = "frame", .run = actionFrame },
    .{ .name = "set_onion", .run = actionSetOnion },
    .{ .name = "set_color", .run = actionSetColor },
    .{ .name = "set_tool", .run = actionSetTool },
    .{ .name = "stroke", .run = actionStroke },
    .{ .name = "save", .run = actionSave },
    .{ .name = "open", .run = actionOpen },
    // Append-only at the end (parallelism constraint)
    .{ .name = "replace_color", .run = actionReplaceColor },
    .{ .name = "palette_ramp", .run = actionPaletteRamp },
    .{ .name = "palette_from_png", .run = actionPaletteFromPng },
    .{ .name = "palette_set", .run = actionPaletteSet },
    // Append-only at the end
    .{ .name = "shape", .run = actionShape },
    .{ .name = "set_symmetry", .run = actionSetSymmetry },
    .{ .name = "set_pixel_perfect", .run = actionSetPixelPerfect },
    // Append-only at the end (parallelism constraint)
    .{ .name = "set_grid", .run = actionSetGrid },
    .{ .name = "set_loupe", .run = actionSetLoupe },
};

/// `App.cmd_exec` Dispatcher: name→handler dispatch + noteUndo wiring.
/// Count undo pushes around dispatch via the handle allocation counter (`next_handle` delta = accurate
/// "depth + topHandle" even when max_history is full and depth does not grow), and
/// `noteUndo(topHandle)` **only on exactly 1 push** (0 = non-undoable; 2+ =
/// breaks 1 command = 1 Op, so skip noteUndo + warn. Not expected with the current action set).
fn dispatchPixieAction(ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    for (&PIXIE_ACTIONS) |*e| {
        if (std.mem.eql(u8, e.name, name)) {
            const handle_before = app.doc.undo.next_handle;
            const out = try e.run(ctx, args, buf);
            const handle_after = app.doc.undo.next_handle;
            // Defence: allocation is monotonic for a lifetime (kept across clearHistoryPreservingHandles / doOpenProject
            // hand-off), but if it ever rolled back, do not underflow unsigned (treat as 0 push + warn).
            const pushes = if (handle_after >= handle_before) handle_after - handle_before else blk: {
                std.debug.print("pixie: action '{s}' undo handle allocation went backwards ({d}→{d}); skipping noteUndo\n", .{ name, handle_before, handle_after });
                break :blk 0;
            };
            if (pushes == 1) {
                app.markProjectDirty();
                // revert applies to `.paint` only (canRevertByHandle). Structure layer ops may push but
                // cannot reverse via the adapter → skip noteUndo; undoable=false (MVP).
                if (app.doc.undo.topHandle()) |h| {
                    if (app.doc.canRevertByHandle(h)) app.cmd_exec.noteUndo(h);
                }
                app.last_seen_handle = app.doc.undo.next_handle; // Recorded push (follow point for unrecorded-edit detection)
            } else if (pushes >= 2) {
                std.debug.print("pixie: action '{s}' pushed undo {d} times (breaks 1 command = 1 Op; skip noteUndo)\n", .{ name, pushes });
            }
            return out;
        }
    }
    return error.UnknownAction;
}

/// Comptime-build a recording wrapper for registerAction. Dispatches the real handler via the executor
/// and records with `actor=.local_agent`. Auto-joins a transaction opened by copilot `begin_tx` via
/// `openTransactionFor`. `policy=.no_record` is for undo/redo (dispatch only).
/// Layer actions normalize index→`#<id>` before executeAction (unify recorded / solo
/// dispatch args to id form. netsync `.relay` bypasses act.run, so relay
/// callers must pass canonical args — same shape as stroke's recordedStroke).
fn recordedAction(comptime name: []const u8, comptime policy: platform.command.RecordPolicy) *const fn (*anyopaque, []const u8, []u8) anyerror![]const u8 {
    return &struct {
        fn run(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
            const app: *App = @ptrCast(@alignCast(ctx));
            var canon_buf: [platform.command.MAX_CMD_ARGS]u8 = undefined;
            const exec_args = try canonicalizeLayerArgs(app, name, args, &canon_buf);
            const seq_before = app.cmd_log.next_seq;
            const res = try app.cmd_exec.executeAction(name, exec_args, .{
                .actor = .local_agent,
                .transaction = app.cmd_exec.openTransactionFor(.local_agent),
                .record_policy = policy,
            }, buf);
            app.tagOwnersFromRecords(seq_before, App.OP_OWNER_AGENT); // Ops produced are agent-owned
            if (res.seq) |s| app.captureHistoryVisual(s);
            return res.output;
        }
    }.run;
}

/// Normalize layer-action args to `#<id>` form (non-layer / add_layer returned unchanged).
/// solo: empty args on delete/duplicate/merge_down and bare-delta move_layer get the selected id.
/// During netsync, .relay targets (everything except select_layer) forbid implicit-selected / bare-index fill-in
/// and return `id_required` (per-peer selected fill-in would diverge).
fn canonicalizeLayerArgs(app: *App, comptime name: []const u8, args: []const u8, buf: []u8) ![]const u8 {
    const is_layer = comptime (std.mem.eql(u8, name, "select_layer") or
        std.mem.eql(u8, name, "set_layer_visible") or
        std.mem.eql(u8, name, "set_layer_opacity") or
        std.mem.eql(u8, name, "delete_layer") or
        std.mem.eql(u8, name, "duplicate_layer") or
        std.mem.eql(u8, name, "merge_down") or
        std.mem.eql(u8, name, "move_layer") or
        std.mem.eql(u8, name, "replace_color"));
    if (!is_layer) return args;

    // select_layer is .local_only so index→id fill-in is allowed during netsync too. Relay ops forbid it.
    const can_fill = (comptime std.mem.eql(u8, name, "select_layer")) or actions.allowLayerCanonFill(platform.netsyncActive());
    const forbid_fill = !can_fill;

    if (comptime std.mem.eql(u8, name, "replace_color")) {
        // Normalize to `#id RRGGBB RRGGBB` (so .relay applies to the same layer on every peer).
        const p = try actions.parseReplaceColor(args);
        const id: u64 = if (p.layer) |ref|
            try layerRefToId(app, ref, forbid_fill)
        else
            try selectedLayerIdRaw(app, forbid_fill);
        return std.fmt.bufPrint(buf, "#{d} {X:0>6} {X:0>6}", .{ id, p.from & 0xFFFFFF, p.to & 0xFFFFFF }) catch return error.ArgsTooLong;
    }
    if (comptime std.mem.eql(u8, name, "select_layer")) {
        const ref = try actions.parseLayerRef(args);
        const id = try layerRefToId(app, ref, false);
        return actions.formatLayerId(buf, id) catch return error.ArgsTooLong;
    }
    if (comptime std.mem.eql(u8, name, "set_layer_visible")) {
        const p = try actions.parseLayerRefBool(args);
        const id = try layerRefToId(app, p.ref, forbid_fill);
        return actions.formatLayerIdBool(buf, id, p.on) catch return error.ArgsTooLong;
    }
    if (comptime std.mem.eql(u8, name, "set_layer_opacity")) {
        const p = try actions.parseLayerRefU8(args);
        const id = try layerRefToId(app, p.ref, forbid_fill);
        return actions.formatLayerIdU8(buf, id, p.value) catch return error.ArgsTooLong;
    }
    if (comptime (std.mem.eql(u8, name, "delete_layer") or
        std.mem.eql(u8, name, "duplicate_layer") or
        std.mem.eql(u8, name, "merge_down")))
    {
        const trimmed = std.mem.trim(u8, args, " \t");
        const id: u64 = if (trimmed.len == 0)
            try selectedLayerIdRaw(app, forbid_fill)
        else blk: {
            const ref = try actions.parseLayerRef(args);
            break :blk try layerRefToId(app, ref, forbid_fill);
        };
        return actions.formatLayerId(buf, id) catch return error.ArgsTooLong;
    }
    if (comptime std.mem.eql(u8, name, "move_layer")) {
        // Old form `<±1>` → prepend selected id. New form `ref ±1` is id-ified as-is.
        const trimmed = std.mem.trim(u8, args, " \t");
        var it = std.mem.tokenizeAny(u8, trimmed, " \t");
        const first = it.next() orelse return error.Empty;
        if (it.next()) |second| {
            if (it.next() != null) return error.TooManyTokens;
            const ref = try actions.parseLayerRefToken(first);
            const delta = std.fmt.parseInt(i32, second, 10) catch return error.InvalidNumber;
            if (delta != 1 and delta != -1) return error.InvalidDelta;
            const id = try layerRefToId(app, ref, forbid_fill);
            return actions.formatLayerIdDelta(buf, id, delta) catch return error.ArgsTooLong;
        } else {
            const delta = std.fmt.parseInt(i32, first, 10) catch return error.InvalidNumber;
            if (delta != 1 and delta != -1) return error.InvalidDelta;
            const id = try selectedLayerIdRaw(app, forbid_fill);
            return actions.formatLayerIdDelta(buf, id, delta) catch return error.ArgsTooLong;
        }
    }
    return args;
}

fn rejectIdRequired() error{IdRequired} {
    platform.setActionErrorDetail("id_required", "use #<id> from digest canvas during netsync");
    return error.IdRequired;
}

fn selectedLayerIdRaw(app: *App, forbid_implicit: bool) !u64 {
    if (forbid_implicit) return rejectIdRequired();
    const idx = app.canvas.selected_layer;
    const id = app.doc.layerIdAt(idx) orelse {
        platform.setActionErrorDetail("index_out_of_range", "use add_layer or 0..N-1");
        return error.OutOfRange;
    };
    return @intFromEnum(id);
}

fn layerRefToId(app: *App, ref: actions.LayerRef, forbid_index: bool) !u64 {
    switch (ref) {
        .id => |raw| {
            // Already-id form is left as-is (existence is checked in the handler; stale → REJECT on apply).
            return raw;
        },
        .index => |idx| {
            if (forbid_index) return rejectIdRequired();
            const id = app.doc.layerIdAt(idx) orelse {
                platform.setActionErrorDetail("index_out_of_range", "use add_layer or 0..N-1");
                return error.OutOfRange;
            };
            return @intFromEnum(id);
        },
    }
}

/// `stroke`-only recording wrapper: parse input args → resolve effective parameters (explicit k=v
/// overrides current state) → build **canonical args with each key exactly once** → executeAction with
/// those canonical args (dispatch runs the same meaning as the input; every stroke record on CommandLog
/// becomes state-independent and re-runnable). Legacy fill input is canonicalised to
/// `tool=fill color=… tolerance=…` before execute (no raw fallback).
fn recordedStroke(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var canon_buf: [platform.command.MAX_CMD_ARGS]u8 = undefined;
    const exec_args = try App.canonicalizeStroke(app, args, &canon_buf);

    const seq_before = app.cmd_log.next_seq;
    const res = try app.cmd_exec.executeAction("stroke", exec_args, .{
        .actor = .local_agent,
        .transaction = app.cmd_exec.openTransactionFor(.local_agent),
        .record_policy = .record,
    }, buf);
    app.tagOwnersFromRecords(seq_before, App.OP_OWNER_AGENT); // Ops produced are agent-owned
    if (res.seq) |s| app.captureHistoryVisual(s);
    return res.output;
}

// Args signatures for capabilities (file-scope const; just before registerActions).
// `@FieldType(platform.Action, "args")` = `?[]const ArgSpec`. null=unspecified / empty slice=explicitly no args.
const pixie_args_none: @FieldType(platform.Action, "args") = &.{};
/// Optional layer ref (delete/duplicate/merge. Defaults to selected; #<id> required during netsync).
const pixie_args_layer_ref_opt: @FieldType(platform.Action, "args") = &.{
    .{ .name = "layer", .kind = "string", .pattern = "#<id>|<index>", .optional = true, .desc = "defaults to selected; #<id> required during netsync" },
};
const pixie_args_select_layer: @FieldType(platform.Action, "args") = &.{
    .{ .name = "layer", .kind = "string", .pattern = "#<id>|<index>", .desc = "layer #<id> or index (bare index ok during netsync)" },
};
const pixie_args_set_layer_visible: @FieldType(platform.Action, "args") = &.{
    .{ .name = "layer", .kind = "string", .pattern = "#<id>|<index>", .desc = "requires #<id> during netsync" },
    .{ .name = "visible", .kind = "bool", .desc = "0|1" },
};
const pixie_args_set_layer_opacity: @FieldType(platform.Action, "args") = &.{
    .{ .name = "layer", .kind = "string", .pattern = "#<id>|<index>", .desc = "requires #<id> during netsync" },
    .{ .name = "value", .kind = "int", .min = 0, .max = 255 },
};
const pixie_args_move_layer: @FieldType(platform.Action, "args") = &.{
    .{ .name = "delta", .kind = "enum", .values = &.{ "1", "-1" }, .desc = "+1|-1" },
};
const pixie_args_frame: @FieldType(platform.Action, "args") = &.{
    .{ .name = "sub", .kind = "enum", .values = &.{ "add", "select" } },
    .{ .name = "idx", .kind = "int", .optional = true, .desc = "frame index when selecting" },
};
const pixie_args_set_onion: @FieldType(platform.Action, "args") = &.{
    .{ .name = "enabled", .kind = "enum", .values = &.{ "on", "off", "1", "0" } },
    .{ .name = "count", .kind = "int", .min = 1, .max = 3, .optional = true },
};
const pixie_args_set_color: @FieldType(platform.Action, "args") = &.{
    .{ .name = "color", .kind = "string", .pattern = "#?RRGGBB" },
};
const pixie_args_set_tool: @FieldType(platform.Action, "args") = &.{
    .{ .name = "tool", .kind = "enum", .values = &.{ "pen", "eraser", "brush", "bezier", "select", "fill", "eyedropper", "line", "rect", "ellipse" } },
};
const pixie_args_shape: @FieldType(platform.Action, "args") = &.{
    .{ .name = "kind", .kind = "enum", .values = &.{ "line", "rect", "ellipse" } },
    .{ .name = "p0", .kind = "string", .pattern = "x,y|anchor", .desc = "x,y or center/top-left/..." },
    .{ .name = "p1", .kind = "string", .pattern = "x,y|anchor" },
    .{ .name = "fill", .kind = "enum", .values = &.{"fill"}, .optional = true },
};
const pixie_args_set_symmetry: @FieldType(platform.Action, "args") = &.{
    .{ .name = "mode", .kind = "enum", .values = &.{ "off", "v", "h", "quad" } },
};
const pixie_args_set_pixel_perfect: @FieldType(platform.Action, "args") = &.{
    .{ .name = "on", .kind = "bool", .desc = "0|1" },
};
const pixie_args_set_grid: @FieldType(platform.Action, "args") = &.{
    .{ .name = "on", .kind = "bool", .desc = "0|1" },
};
const pixie_args_set_loupe: @FieldType(platform.Action, "args") = &.{
    .{ .name = "on", .kind = "bool", .desc = "0|1" },
};
const pixie_args_stroke: @FieldType(platform.Action, "args") = &.{
    .{ .name = "layer", .kind = "string", .pattern = "#<id>|<index>", .optional = true, .desc = "defaults to selected; canonical wire uses #<id>" },
    .{ .name = "params", .kind = "string", .optional = true, .desc = "k=v for tool/color/size/opacity/hardness/tolerance (tool=pen|eraser|brush|fill)" },
    .{ .name = "xy", .kind = "int", .variadic = true, .desc = "canvas x y pairs (even count; at least one pair)" },
};
const pixie_args_path: @FieldType(platform.Action, "args") = &.{
    .{ .name = "path", .kind = "path" },
};
const pixie_args_canvas_size: @FieldType(platform.Action, "args") = &.{
    .{ .name = "width", .kind = "int", .min = 1, .max = @floatFromInt(actions.MAX_CANVAS_EDGE) },
    .{ .name = "height", .kind = "int", .min = 1, .max = @floatFromInt(actions.MAX_CANVAS_EDGE) },
};
const pixie_args_new: @FieldType(platform.Action, "args") = &.{
    .{ .name = "width", .kind = "int", .min = 1, .max = @floatFromInt(actions.MAX_CANVAS_EDGE), .optional = true },
    .{ .name = "height", .kind = "int", .min = 1, .max = @floatFromInt(actions.MAX_CANVAS_EDGE), .optional = true },
};
const appshell_args_optional_path: @FieldType(platform.Action, "args") = &.{
    .{ .name = "path", .kind = "path", .optional = true },
};
// palette args
const pixie_args_replace_color: @FieldType(platform.Action, "args") = &.{
    .{ .name = "layer", .kind = "string", .pattern = "#<id>|<index>", .optional = true, .desc = "defaults to selected; #<id> required during netsync" },
    .{ .name = "from", .kind = "string", .pattern = "#?RRGGBB" },
    .{ .name = "to", .kind = "string", .pattern = "#?RRGGBB" },
};
const pixie_args_palette_ramp: @FieldType(platform.Action, "args") = &.{
    .{ .name = "seed", .kind = "string", .pattern = "#?RRGGBB" },
    .{ .name = "n", .kind = "int", .min = 2, .max = 32 },
};
const pixie_args_palette_from_png: @FieldType(platform.Action, "args") = &.{
    .{ .name = "path", .kind = "path" },
};
const pixie_args_palette_set: @FieldType(platform.Action, "args") = &.{
    .{ .name = "hex", .kind = "string", .pattern = "#?RRGGBB", .variadic = true, .desc = "1..=64 colors" },
};
// timeline view actions
const pixie_args_goto_frame: @FieldType(platform.Action, "args") = &.{
    .{ .name = "idx", .kind = "int", .desc = "frame index" },
};
const pixie_args_export_seq: @FieldType(platform.Action, "args") = &.{
    .{ .name = "stem", .kind = "path", .desc = "output stem for <stem>_NNNN.png" },
};
const pixie_args_export_sheet: @FieldType(platform.Action, "args") = &.{
    .{ .name = "path", .kind = "path" },
    .{ .name = "columns", .kind = "int", .optional = true, .desc = "0=auto ceil(sqrt(n))" },
    .{ .name = "margin", .kind = "int", .optional = true, .desc = "gap between frames in px" },
};
// presence
const pixie_args_presence_point: @FieldType(platform.Action, "args") = &.{
    .{ .name = "x", .kind = "int", .min = 0, .max = 255 },
    .{ .name = "y", .kind = "int", .min = 0, .max = 255 },
    .{ .name = "ttl_ms", .kind = "int", .min = 0, .max = 10000, .optional = true },
};
const pixie_args_presence_highlight: @FieldType(platform.Action, "args") = &.{
    .{ .name = "x0", .kind = "int", .min = 0, .max = 255 },
    .{ .name = "y0", .kind = "int", .min = 0, .max = 255 },
    .{ .name = "x1", .kind = "int", .min = 0, .max = 255 },
    .{ .name = "y1", .kind = "int", .min = 0, .max = 255 },
    .{ .name = "ttl_ms", .kind = "int", .min = 0, .max = 10000, .optional = true },
};
const pixie_args_presence_suggest: @FieldType(platform.Action, "args") = &.{
    .{ .name = "x", .kind = "int", .min = 0, .max = 255 },
    .{ .name = "y", .kind = "int", .min = 0, .max = 255 },
    .{ .name = "ttl_ms", .kind = "int", .min = 0, .max = 10000, .optional = true },
};
const pixie_args_panel_toggle: @FieldType(platform.Action, "args") = &.{
    .{ .name = "name", .kind = "enum", .values = &.{ "history", "color", "palette", "tool_options", "layers", "timeline" } },
};

fn actionRequestClose(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    try actions.parseNoArgs(args);
    const app = actionApp(ctx);
    const win = app.os_window orelse return error.NoWindow;
    if (app.recovery != null) {
        win.cancelQuit();
        return "ok close=rejected";
    }
    const result = try app.host.requestClose();
    if (result == .allowed) app.running = false else win.cancelQuit();
    return std.fmt.bufPrint(buf, "ok close={s}", .{@tagName(result)}) catch error.BufferTooSmall;
}

fn actionNewDocument(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    const parsed = try actions.parseNew(args);
    switch (parsed) {
        .reset_current => {
            const result = try app.requestNewDocument();
            return std.fmt.bufPrint(buf, "ok new={s}", .{@tagName(result)}) catch error.BufferTooSmall;
        },
        .sized => |sz| {
            try actions.validateCanvasSize(sz.w, sz.h);
            app.pending_new_size = .{ .w = sz.w, .h = sz.h };
            const result = app.requestNewDocument() catch |err| {
                app.pending_new_size = null;
                return err;
            };
            if (result == .canceled) app.pending_new_size = null;
            return std.fmt.bufPrint(buf, "ok new={s} size={d}x{d}", .{ @tagName(result), sz.w, sz.h }) catch error.BufferTooSmall;
        },
    }
}

fn actionResize(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const sz = try actions.parseCanvasSize(args);
    try actions.validateCanvasSize(sz.w, sz.h);
    const app = actionApp(ctx);
    try app.doResize(sz.w, sz.h);
    return std.fmt.bufPrint(buf, "ok resize={d}x{d}", .{ sz.w, sz.h }) catch error.BufferTooSmall;
}

fn actionOpenProject(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    if (args.len == 0) return error.InvalidArgument;
    const result = try app.requestProjectOpen(args);
    return std.fmt.bufPrint(buf, "ok open_project={s}", .{@tagName(result)}) catch error.BufferTooSmall;
}

fn actionConfirmSave(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    const result = try app.host.confirmSave(if (args.len == 0) null else args);
    finishHostResult(app, result);
    return std.fmt.bufPrint(buf, "ok confirm_save={s}", .{@tagName(result)}) catch error.BufferTooSmall;
}

fn actionConfirmDiscard(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    try actions.parseNoArgs(args);
    const app = actionApp(ctx);
    const result = try app.host.confirmDiscard();
    finishHostResult(app, result);
    return std.fmt.bufPrint(buf, "ok confirm_discard={s}", .{@tagName(result)}) catch error.BufferTooSmall;
}

fn actionConfirmCancel(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    try actions.parseNoArgs(args);
    const app = actionApp(ctx);
    const result = app.host.confirmCancel();
    finishHostResult(app, result);
    return std.fmt.bufPrint(buf, "ok confirm_cancel={s}", .{@tagName(result)}) catch error.BufferTooSmall;
}

fn actionRecover(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    try actions.parseNoArgs(args);
    try recoverAutosave(actionApp(ctx));
    return "ok recover";
}

fn actionDiscardRecovery(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    try actions.parseNoArgs(args);
    try discardRecovery(actionApp(ctx));
    return "ok discard_recovery";
}

fn panelNameFromToggle(name: actions.PanelToggleName) []const u8 {
    return switch (name) {
        .history => PanelNames.history,
        .color => PanelNames.color,
        .palette => PanelNames.palette,
        .tool_options => PanelNames.tool_options,
        .layers => PanelNames.layers,
        .timeline => PanelNames.timeline,
    };
}

/// `panel_toggle <name>`: UI state only (local_only; not undoable).
fn actionPanelToggle(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const name = try actions.parsePanelToggle(args);
    const app = actionApp(ctx);
    const panel_name = panelNameFromToggle(name);
    const new_vis = app.togglePanelVisible(panel_name) orelse return error.InvalidArgument;
    return std.fmt.bufPrint(buf, "ok panel_toggle {s}={d}", .{ @tagName(name), @intFromBool(new_vis) }) catch error.BufferTooSmall;
}

fn panelPersistKeyBuf(key: gui.PersistKey, buf: *[128]u8) []const u8 {
    return switch (key) {
        .slot => |s| std.fmt.bufPrint(buf, "pixie.panel.slot.{s}.{s}", .{ @tagName(s.slot), @tagName(s.field) }) catch buf[0..0],
        .panel => |p| std.fmt.bufPrint(buf, "pixie.panel.{s}.{s}", .{ p.name, @tagName(p.field) }) catch buf[0..0],
    };
}

fn panelPersistRead(ud: *anyopaque, key: gui.PersistKey) ?gui.PersistValue {
    const app: *App = @ptrCast(@alignCast(ud));
    var key_buf: [128]u8 = undefined;
    const pref_key = panelPersistKeyBuf(key, &key_buf);
    if (pref_key.len == 0) return null;
    return switch (key) {
        .slot => |s| switch (s.field) {
            .visible => if (app.preferences.getBool(pref_key)) |v| .{ .boolean = v } else null,
            .extent => if (app.preferences.getI64(pref_key)) |v| .{ .integer = v } else null,
        },
        .panel => |p| switch (p.field) {
            .visible => if (app.preferences.getBool(pref_key)) |v| .{ .boolean = v } else null,
            .open => if (app.preferences.getBool(pref_key)) |v| .{ .boolean = v } else null,
        },
    };
}

fn panelPersistWrite(ud: *anyopaque, key: gui.PersistKey, value: gui.PersistValue) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ud));
    var key_buf: [128]u8 = undefined;
    const pref_key = panelPersistKeyBuf(key, &key_buf);
    if (pref_key.len == 0) return error.NoSpaceLeft;
    switch (value) {
        .boolean => |v| try app.preferences.setBool(pref_key, v),
        .integer => |v| try app.preferences.setI64(pref_key, v),
    }
}

/// Register every action in one shot (call after `platform.init()`, before the main loop. When harness/copilot are
/// disabled, `registerAction` itself is a no-op so normal runs are unaffected). What gets registered is the recording
/// wrapper (`dispatchPixieAction` calls the real handler via the `PIXIE_ACTIONS` table).
fn registerActions(app: *App) void {
    platform.registerAction(.{ .name = "undo", .ctx = app, .run = actionUndo, .network_policy = .undo_own, .args = pixie_args_none }); // Control commands (bypass the executor)
    platform.registerAction(.{ .name = "redo", .ctx = app, .run = actionRedo, .network_policy = .redo_own, .args = pixie_args_none });
    platform.registerAction(.{ .name = "clear", .ctx = app, .run = recordedAction("clear", .record), .args = pixie_args_none });
    // Layer structure ops are handle-referenced → promoted to .relay.
    // select_layer alone is .local_only (selection is a per-peer view; relaying would fight over selection).
    platform.registerAction(.{ .name = "add_layer", .ctx = app, .run = recordedAction("add_layer", .record), .network_policy = .relay, .args = pixie_args_none });
    platform.registerAction(.{ .name = "delete_layer", .ctx = app, .run = recordedAction("delete_layer", .record), .network_policy = .relay, .args = pixie_args_layer_ref_opt });
    platform.registerAction(.{ .name = "select_layer", .ctx = app, .run = recordedAction("select_layer", .record), .network_policy = .local_only, .args = pixie_args_select_layer });
    platform.registerAction(.{ .name = "set_layer_visible", .ctx = app, .run = recordedAction("set_layer_visible", .record), .network_policy = .relay, .args = pixie_args_set_layer_visible });
    platform.registerAction(.{ .name = "set_layer_opacity", .ctx = app, .run = recordedAction("set_layer_opacity", .record), .network_policy = .relay, .args = pixie_args_set_layer_opacity });
    platform.registerAction(.{ .name = "move_layer", .ctx = app, .run = recordedAction("move_layer", .record), .network_policy = .relay, .args = pixie_args_move_layer });
    platform.registerAction(.{ .name = "duplicate_layer", .ctx = app, .run = recordedAction("duplicate_layer", .record), .network_policy = .relay, .args = pixie_args_layer_ref_opt });
    platform.registerAction(.{ .name = "merge_down", .ctx = app, .run = recordedAction("merge_down", .record), .network_policy = .relay, .args = pixie_args_layer_ref_opt });
    platform.registerAction(.{ .name = "frame", .ctx = app, .run = recordedAction("frame", .record), .args = pixie_args_frame });
    platform.registerAction(.{ .name = "set_onion", .ctx = app, .run = recordedAction("set_onion", .record), .args = pixie_args_set_onion });
    platform.registerAction(.{ .name = "set_color", .ctx = app, .run = recordedAction("set_color", .record), .network_policy = .local_only, .args = pixie_args_set_color });
    platform.registerAction(.{ .name = "set_tool", .ctx = app, .run = recordedAction("set_tool", .record), .network_policy = .local_only, .args = pixie_args_set_tool });
    platform.registerAction(.{ .name = "stroke", .ctx = app, .run = recordedStroke, .network_policy = .relay, .canonicalize = App.canonicalizeStroke, .args = pixie_args_stroke });
    platform.registerAction(.{ .name = "save", .ctx = app, .run = recordedAction("save", .record), .network_policy = .local_only, .args = pixie_args_path });
    platform.registerAction(.{ .name = "open", .ctx = app, .run = recordedAction("open", .record), .args = pixie_args_path });
    platform.registerAction(.{ .name = "request_close", .ctx = app, .run = actionRequestClose, .network_policy = .local_only, .args = pixie_args_none });
    platform.registerAction(.{ .name = "new", .ctx = app, .run = actionNewDocument, .network_policy = .reject_when_synced, .args = pixie_args_new });
    platform.registerAction(.{ .name = "resize", .ctx = app, .run = actionResize, .network_policy = .reject_when_synced, .desc = "resize canvas keeping top-left content", .args = pixie_args_canvas_size });
    platform.registerAction(.{ .name = "open_project", .ctx = app, .run = actionOpenProject, .network_policy = .local_only, .args = pixie_args_path });
    platform.registerAction(.{ .name = "confirm_save", .ctx = app, .run = actionConfirmSave, .network_policy = .local_only, .args = appshell_args_optional_path });
    platform.registerAction(.{ .name = "confirm_discard", .ctx = app, .run = actionConfirmDiscard, .network_policy = .local_only, .args = pixie_args_none });
    platform.registerAction(.{ .name = "confirm_cancel", .ctx = app, .run = actionConfirmCancel, .network_policy = .local_only, .args = pixie_args_none });
    platform.registerAction(.{ .name = "recover", .ctx = app, .run = actionRecover, .network_policy = .local_only, .args = pixie_args_none });
    platform.registerAction(.{ .name = "discard_recovery", .ctx = app, .run = actionDiscardRecovery, .network_policy = .local_only, .args = pixie_args_none });
    // recipe: meta-ops → bypass executor, not recorded in CommandLog, local_only.
    platform.registerAction(.{ .name = "recipe_save", .ctx = app, .run = actionRecipeSave, .network_policy = .local_only, .args = pixie_args_path });
    platform.registerAction(.{ .name = "recipe_replay", .ctx = app, .run = actionRecipeReplay, .network_policy = .local_only, .args = pixie_args_path });
    // diff_mark: meta-op → bypass executor, not recorded in CommandLog, local_only.
    platform.registerAction(.{ .name = "diff_mark", .ctx = app, .run = actionDiffMark, .network_policy = .local_only, .desc = "mark current composite as diff baseline", .args = pixie_args_none });
    // timeline view actions (bypass executor, not recorded in CommandLog, local_only)
    platform.registerAction(.{ .name = "play", .ctx = app, .run = actionPlay, .network_policy = .local_only, .desc = "start timeline playback", .args = pixie_args_none });
    platform.registerAction(.{ .name = "pause", .ctx = app, .run = actionPause, .network_policy = .local_only, .desc = "pause timeline playback", .args = pixie_args_none });
    platform.registerAction(.{ .name = "goto_frame", .ctx = app, .run = actionGotoFrame, .network_policy = .local_only, .desc = "select frame by index (view only, no undo)", .args = pixie_args_goto_frame });
    // export (bypass executor, not recorded in CommandLog, local_only)
    platform.registerAction(.{ .name = "export_seq", .ctx = app, .run = actionExportSeq, .network_policy = .local_only, .desc = "export numbered PNG sequence", .args = pixie_args_export_seq });
    platform.registerAction(.{ .name = "export_sheet", .ctx = app, .run = actionExportSheet, .network_policy = .local_only, .desc = "export sprite sheet PNG", .args = pixie_args_export_sheet });
    // Append-only at the end (parallelism constraint; do not edit or reorder existing rows)
    platform.registerAction(.{ .name = "replace_color", .ctx = app, .run = recordedAction("replace_color", .record), .network_policy = .relay, .desc = "replace color A→B on layer ([#id|idx] from to; undoable)", .args = pixie_args_replace_color });
    // palette is document state (SYNC'd), so local changes during a session would diverge → reject_when_synced
    platform.registerAction(.{ .name = "palette_ramp", .ctx = app, .run = recordedAction("palette_ramp", .record), .network_policy = .reject_when_synced, .desc = "OKLCH light-dark ramp from seed (n=2..32)", .args = pixie_args_palette_ramp });
    platform.registerAction(.{ .name = "palette_from_png", .ctx = app, .run = recordedAction("palette_from_png", .record), .network_policy = .reject_when_synced, .desc = "extract palette from PNG by frequency (max 64)", .args = pixie_args_palette_from_png });
    platform.registerAction(.{ .name = "palette_set", .ctx = app, .run = recordedAction("palette_set", .record), .network_policy = .reject_when_synced, .desc = "replace palette with hex list (1..64)", .args = pixie_args_palette_set });
    // shape is .relay like stroke (document pixel change; undoable).
    // set_symmetry / set_pixel_perfect also affect draw results → document toggles → .relay
    // set_tool / set_color are per-peer → .local_only. stroke bakes tool/color into the payload.
    platform.registerAction(.{ .name = "shape", .ctx = app, .run = recordedAction("shape", .record), .network_policy = .relay, .desc = "draw shape line|rect|ellipse p0 p1 [fill]", .args = pixie_args_shape });
    platform.registerAction(.{ .name = "set_symmetry", .ctx = app, .run = recordedAction("set_symmetry", .record), .network_policy = .relay, .desc = "symmetry off|v|h|quad", .args = pixie_args_set_symmetry });
    platform.registerAction(.{ .name = "set_pixel_perfect", .ctx = app, .run = recordedAction("set_pixel_perfect", .record), .network_policy = .relay, .desc = "pixel-perfect pen 0|1", .args = pixie_args_set_pixel_perfect });
    // ephemeral presence (bypasses recordedAction / CommandLog / undo)
    platform.registerAction(.{ .name = "presence_point", .ctx = app, .run = actionPresencePoint, .network_policy = .ephemeral, .desc = "agent cursor / work position", .args = pixie_args_presence_point });
    platform.registerAction(.{ .name = "presence_highlight", .ctx = app, .run = actionPresenceHighlight, .network_policy = .ephemeral, .desc = "temporary canvas highlight rect", .args = pixie_args_presence_highlight });
    platform.registerAction(.{ .name = "presence_suggest", .ctx = app, .run = actionPresenceSuggest, .network_policy = .ephemeral, .desc = "assist suggestion marker", .args = pixie_args_presence_suggest });
    // panel visibility toggle (UI state only; not undoable)
    platform.registerAction(.{ .name = "panel_toggle", .ctx = app, .run = actionPanelToggle, .network_policy = .local_only, .desc = "toggle panel visibility", .args = pixie_args_panel_toggle });
    // pixel grid overlay toggle (view only, no undo; a per-peer canvas overlay, not document state)
    platform.registerAction(.{ .name = "set_grid", .ctx = app, .run = recordedAction("set_grid", .record), .network_policy = .local_only, .desc = "toggle the pixel grid overlay 0|1 (view only, no undo)", .args = pixie_args_set_grid });
    // loupe (magnifier) overlay toggle (view only, no undo; a per-peer canvas overlay, not document state)
    platform.registerAction(.{ .name = "set_loupe", .ctx = app, .run = recordedAction("set_loupe", .record), .network_policy = .local_only, .desc = "toggle the loupe magnifier overlay 0|1 (view only, no undo)", .args = pixie_args_set_loupe });
}

fn netsyncExport(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.syncPaletteToDoc();
    return core.document_io.encodeDocument(&app.doc, allocator);
}

fn netsyncImport(ctx: *anyopaque, bytes: []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ctx));
    try app.checkEditingAllowed();
    const sz = try core.document_io.peekCanvasSize(bytes);
    try actions.validateCanvasSize(sz.w, sz.h);
    var new_doc = try core.document_io.decodeDocument(bytes, app.gpa);
    errdefer new_doc.deinit();
    try actions.validateCanvasSize(new_doc.width, new_doc.height);
    const preserved_next_handle = app.doc.undo.next_handle;
    app.doc.deinit();
    app.doc = new_doc;
    new_doc = undefined;
    app.doc.undo.next_handle = preserved_next_handle;
    app.invalidateHistoryAfterDocReset();
    app.doc.resyncActiveView(app.gpa);
    app.canvas = app.doc.activeCanvas();
    try app.rebuildRuntimeForDocSize();
    app.clampTimelineTarget();
    app.applySystemFont();
    app.loadPaletteFromDoc();
    app.canvas.clearSelection();
    app.sel_in.discardFloat(app.gpa);
    app.syncPreviewCanvas();
    app.markProjectDirty();
}

fn registerStateSync(app: *App) void {
    platform.registerStateSync(.{
        .ctx = app,
        .export_fn = netsyncExport,
        .import_fn = netsyncImport,
    });
}

/// Fixed peer colors (for point/highlight). suggest uses a fixed amber.
fn presencePeerColor(peer_id: u32) gui.Color {
    const palette = [_]gui.Color{
        gui.Color.rgba(0x3B, 0x82, 0xF6, 0xFF), // blue
        gui.Color.rgba(0x22, 0xC5, 0x5E, 0xFF), // green
        gui.Color.rgba(0xA8, 0x55, 0xF7, 0xFF), // purple
        gui.Color.rgba(0xEF, 0x44, 0x44, 0xFF), // red
        gui.Color.rgba(0x06, 0xB6, 0xD4, 0xFF), // cyan
        gui.Color.rgba(0xF9, 0x73, 0x16, 0xFF), // orange
        gui.Color.rgba(0xEC, 0x48, 0x99, 0xFF), // pink
        gui.Color.rgba(0x84, 0xCC, 0x16, 0xFF), // lime
    };
    return palette[peer_id % palette.len];
}

const PRESENCE_SUGGEST_COLOR = gui.Color.rgba(0xF5, 0x9E, 0x0B, 0xFF); // amber

fn canvasToScreen(canvas_rect: core.Rect, zoom: Zoom, cx: i32, cy: i32) gui.Vec2 {
    const c = zoom_mod.canvasCellCenterToScreen(canvas_rect.x, canvas_rect.y, cx, cy, zoom);
    return .{ .x = c.x, .y = c.y };
}

/// presence overlay. Every frame; at most 8 peers × a fixed small area.
fn drawPresenceOverlay(app: *App, canvas_rect_opt: ?core.Rect) void {
    const canvas_rect = canvas_rect_opt orelse return;
    const area = app.last_area orelse return;
    const zoom = app.view_zoom;
    const now = platform.getTime();
    app.presence.expire(now);

    const clip_area: gui.Rect = .{ .x = area.x, .y = area.y, .w = @intCast(area.w), .h = @intCast(area.h) };
    const disp: gui.Rect = .{
        .x = canvas_rect.x,
        .y = canvas_rect.y,
        .w = @intCast(zoom.displayExtent(@intCast(canvas_rect.w))),
        .h = @intCast(zoom.displayExtent(@intCast(canvas_rect.h))),
    };
    const dl = &app.ctx.draw_list;
    dl.pushClip(disp.intersect(clip_area)) catch return;
    defer dl.popClip();

    var label_bufs: [actions.PRESENCE_MAX_PEERS][32]u8 = undefined;
    for (&app.presence.peers, 0..) |*p, i| {
        if (!p.occupied) continue;
        const col = presencePeerColor(p.peer_id);

        if (p.highlight_active) {
            const x0 = @min(p.hl_x0, p.hl_x1);
            const y0 = @min(p.hl_y0, p.hl_y1);
            const x1 = @max(p.hl_x0, p.hl_x1);
            const y1 = @max(p.hl_y0, p.hl_y1);
            const fill = gui.Color.rgba(col.r, col.g, col.b, 0x55);
            const cell = core.Rect{ .x = x0, .y = y0, .w = x1 - x0 + 1, .h = y1 - y0 + 1 };
            const sr = zoom_mod.canvasRectToScreen(canvas_rect, cell, zoom);
            const rect: gui.Rect = .{
                .x = sr.x,
                .y = sr.y,
                .w = @intCast(sr.w),
                .h = @intCast(sr.h),
            };
            dl.rectFilled(rect, fill) catch {};
            dl.rectOutline(rect, col, 2) catch {};
        }

        if (p.point_active) {
            const c = canvasToScreen(canvas_rect, zoom, p.point_x, p.point_y);
            const arm: i32 = @max(4, @as(i32, @intFromFloat(@ceil(zoom.scaleF32()))));
            dl.line(.{ .x = c.x - arm, .y = c.y }, .{ .x = c.x + arm, .y = c.y }, col, 2) catch {};
            dl.line(.{ .x = c.x, .y = c.y - arm }, .{ .x = c.x, .y = c.y + arm }, col, 2) catch {};
            dl.rectFilled(.{ .x = c.x - 2, .y = c.y - 2, .w = 4, .h = 4 }, col) catch {};
            const label = std.fmt.bufPrint(&label_bufs[i], "agent #{d}", .{p.peer_id}) catch "agent";
            dl.text(.{ .x = c.x + 6, .y = c.y - 12 }, label, col) catch {};
        }

        if (p.suggest_active) {
            const c = canvasToScreen(canvas_rect, zoom, p.suggest_x, p.suggest_y);
            const r: i32 = @max(3, @as(i32, @intFromFloat(@ceil(zoom.scaleF32()))));
            dl.rectOutline(.{ .x = c.x - r, .y = c.y - r, .w = @intCast(r * 2), .h = @intCast(r * 2) }, PRESENCE_SUGGEST_COLOR, 2) catch {};
            dl.rectFilled(.{ .x = c.x - 2, .y = c.y - 2, .w = 4, .h = 4 }, PRESENCE_SUGGEST_COLOR) catch {};
            dl.text(.{ .x = c.x + 6, .y = c.y + 4 }, "suggest", PRESENCE_SUGGEST_COLOR) catch {};
        }
    }
}

/// View-area center (continuous coords). Camera model S=(Sx,Sy).
fn areaCenterF(area: core.Rect) struct { sx: f32, sy: f32 } {
    return .{
        .sx = @as(f32, @floatFromInt(area.x)) + @as(f32, @floatFromInt(area.w)) / 2.0,
        .sy = @as(f32, @floatFromInt(area.y)) + @as(f32, @floatFromInt(area.h)) / 2.0,
    };
}

/// Compute the camera-derived integer display origin and clamp it to intersect area by at least 1px (non-destructive).
/// origin ∈ [a - canvas*z + 1, a + area_size - 1]
fn displayOrigin(app: *const App, area: core.Rect) struct { x: i32, y: i32 } {
    const z = app.view_zoom;
    const zf = z.scaleF32();
    const c = areaCenterF(area);
    var ox: i32 = @intFromFloat(@round(c.sx - app.cam_cx * zf));
    var oy: i32 = @intFromFloat(@round(c.sy - app.cam_cy * zf));
    const vw = z.displayExtent(app.doc.width);
    const vh = z.displayExtent(app.doc.height);
    ox = std.math.clamp(ox, area.x - vw + 1, area.x + area.w - 1);
    oy = std.math.clamp(oy, area.y - vh + 1, area.y + area.h - 1);
    return .{ .x = ox, .y = oy };
}

/// Re-derive cam_cx/cy from the integer display origin (state consistency after clamp).
fn syncCameraFromOrigin(app: *App, area: core.Rect, ox: i32, oy: i32) void {
    const zf = app.view_zoom.scaleF32();
    const c = areaCenterF(area);
    app.cam_cx = (c.sx - @as(f32, @floatFromInt(ox))) / zf;
    app.cam_cy = (c.sy - @as(f32, @floatFromInt(oy))) / zf;
}

/// Place the canvas rect inside canvas_area at the camera-derived display origin.
/// Round the continuous origin to integers, clamp, then re-derive cam_cx/cy from the display origin.
/// Also update app.last_area every frame (for Fit zoom).
/// Returned core.Rect w/h are canvas pixel counts (screenToCanvas* contract). First frame is null
/// (PanelHost.centerRect reads the previous-frame cache).
fn canvasBlitRect(ctx: *const gui.Context, app: *App) ?core.Rect {
    const area_node = app.panel_host.centerRect(ctx) orelse return null;
    const area: core.Rect = .{ .x = area_node.x, .y = area_node.y, .w = @intCast(area_node.w), .h = @intCast(area_node.h) };
    app.last_area = area;

    const origin = displayOrigin(app, area);
    syncCameraFromOrigin(app, area, origin.x, origin.y);
    return .{ .x = origin.x, .y = origin.y, .w = @intCast(app.doc.width), .h = @intCast(app.doc.height) };
}

/// Minimap observation fields for canvas digest (additive only).
fn minimapDigestFields(app: *App, area: core.Rect) []const u8 {
    // Static buffer (digest is sync, single-call). Part of the 1024 budget.
    const Buf = struct {
        var bytes: [192]u8 = undefined;
    };
    const cw = app.doc.width;
    const ch = app.doc.height;
    const z = app.view_zoom;
    const vis = minimap_mod.visibleRect(app.cam_cx, app.cam_cy, area.w, area.h, z, cw, ch);
    const vx0: i32 = @intFromFloat(@floor(vis.x0));
    const vy0: i32 = @intFromFloat(@floor(vis.y0));
    const vw: i32 = @max(0, @as(i32, @intFromFloat(@ceil(vis.x1))) - vx0);
    const vh: i32 = @max(0, @as(i32, @intFromFloat(@ceil(vis.y1))) - vy0);
    if (!minimap_mod.shouldShow(z, cw, ch, area.w, area.h)) {
        return std.fmt.bufPrint(&Buf.bytes, " minimap=off minimap_rect=none visible_rect={d},{d},{d},{d} viewport_rect=none", .{
            vx0, vy0, vw, vh,
        }) catch " minimap=off minimap_rect=none visible_rect=none viewport_rect=none";
    }
    const tw: u32 = if (app.minimap.width > 0) app.minimap.width else minimap_mod.thumbSize(cw, ch).w;
    const th: u32 = if (app.minimap.height > 0) app.minimap.height else minimap_mod.thumbSize(cw, ch).h;
    const mm = minimap_mod.layoutRect(area, tw, th);
    const vp = minimap_mod.mapVisibleToViewport(vis, cw, ch, mm);
    return std.fmt.bufPrint(&Buf.bytes, " minimap=on minimap_rect={d},{d},{d},{d} visible_rect={d},{d},{d},{d} viewport_rect={d},{d},{d},{d}", .{
        mm.x, mm.y, mm.w, mm.h, vx0, vy0, vw, vh, vp.x, vp.y, vp.w, vp.h,
    }) catch " minimap=on minimap_rect=none visible_rect=none viewport_rect=none";
}

/// Zoom-slider track rect for `digest canvas` (a replay script's way to compute where to click the
/// knob — see STATUS_ZOOM_SLIDER_ID's doc comment for why this is the track, not the whole
/// [label][track][value] row). `zoom_slider_track=none` before buildUi has run once (the very
/// first frame; `getNodeRect` reads the previous frame's cached layout, same contract as
/// drawStatusBarLive's STATUS_ZOOM_ID lookup).
fn zoomSliderDigestFields(app: *App) []const u8 {
    // Static buffer (digest is sync, single-call). Part of the 1024 budget.
    const Buf = struct {
        var bytes: [96]u8 = undefined;
    };
    const r = app.ctx.getNodeRect(STATUS_ZOOM_SLIDER_ID) orelse
        return " zoom_slider_track=none";
    return std.fmt.bufPrint(&Buf.bytes, " zoom_slider_track={d},{d},{d},{d}", .{ r.x, r.y, r.w, r.h }) catch " zoom_slider_track=none";
}

/// Current-frame minimap placement (only when display conditions hold).
fn currentMinimapRect(app: *const App, area: core.Rect) ?core.Rect {
    const cw = app.doc.width;
    const ch = app.doc.height;
    if (!minimap_mod.shouldShow(app.view_zoom, cw, ch, area.w, area.h)) return null;
    const tw: u32 = if (app.minimap.width > 0) app.minimap.width else minimap_mod.thumbSize(cw, ch).w;
    const th: u32 = if (app.minimap.height > 0) app.minimap.height else minimap_mod.thumbSize(cw, ch).h;
    return minimap_mod.layoutRect(area, tw, th);
}

/// Minimap click/drag → camera move. Call before updateViewport.
/// Returns true = input consumed (exclusive with normal pan/stroke).
fn updateMinimapInput(app: *App, ctx: *const gui.Context) bool {
    const in = &ctx.input;
    const area = app.last_area orelse {
        app.minimap_drag_active = false;
        return false;
    };
    const mm = currentMinimapRect(app, area) orelse {
        app.minimap_drag_active = false;
        return false;
    };
    const popup_open = ctx.hasOpenPopup();
    const cw = app.doc.width;
    const ch = app.doc.height;

    if (!app.minimap_drag_active) {
        if (!popup_open and in.mouse_pressed.left and !app.pan_active and !app.isPointerBusy()) {
            const p = in.mouse_pressed_pos;
            if (minimap_mod.contains(mm, p.x, p.y)) {
                app.minimap_drag_active = true;
                const cam = minimap_mod.screenToCameraCenter(p.x, p.y, mm, cw, ch);
                app.cam_cx = cam.cx;
                app.cam_cy = cam.cy;
                return true;
            }
        }
        return false;
    }

    // During drag
    if (in.mouse_buttons.left) {
        const cam = minimap_mod.screenToCameraCenter(in.mouse_pos.x, in.mouse_pos.y, mm, cw, ch);
        app.cam_cx = cam.cx;
        app.cam_cy = cam.cy;
        return true;
    }
    app.minimap_drag_active = false;
    return false;
}

/// paint.Rect (i32) → ScreenTransform → physical paint.Rect.
/// Scale rules live in gfx.ScreenTransform. Here only f32→i32 conversion of integer-valued floats.
fn logicalPaintRectToPhysical(r: core.Rect, scale: f32) core.Rect {
    const cam = ScreenTransform.logicalRectToPhysical(.{
        .x = @floatFromInt(r.x),
        .y = @floatFromInt(r.y),
        .w = @floatFromInt(r.w),
        .h = @floatFromInt(r.h),
    }, scale);
    return .{
        .x = @intFromFloat(cam.x),
        .y = @intFromFloat(cam.y),
        .w = @intFromFloat(cam.w),
        .h = @intFromFloat(cam.h),
    };
}

/// Refresh the cache and draw the minimap into the fb.
/// `area` is the logical canvas area. Pass a ScreenTransform floor-converted rect to the physical fb.
fn drawMinimapOverlay(app: *App, fb: []u32, fb_w: u32, fb_h: u32, area: core.Rect, content_scale: f32) void {
    const mm_logical = currentMinimapRect(app, area) orelse return;
    const cw = app.doc.width;
    const ch = app.doc.height;
    const composite = app.canvas.compositeStraight();
    app.minimap.ensure(composite, cw, ch) catch return;
    const vis = minimap_mod.visibleRect(app.cam_cx, app.cam_cy, area.w, area.h, app.view_zoom, cw, ch);
    const vp_logical = minimap_mod.mapVisibleToViewport(vis, cw, ch, mm_logical);
    const mm = logicalPaintRectToPhysical(mm_logical, content_scale);
    const vp = logicalPaintRectToPhysical(vp_logical, content_scale);
    const area_phys = logicalPaintRectToPhysical(area, content_scale);
    minimap_mod.draw(fb, fb_w, fb_h, &app.minimap, mm, vp, area_phys);
}

/// Handle viewport zoom/pan input (call after endFrame, before canvas input).
/// Return: true while panning (caller suppresses draw input). zoom/pan writes go back into app;
/// actual clamp is done next frame by canvasBlitRect against the current area.
fn updateViewport(app: *App, ctx: *const gui.Context) bool {
    const in = &ctx.input;
    const area = app.last_area;
    // While a popup is open (layer context menu etc.), suppress **starting** a new zoom/pan
    // (block input punch-through to the canvas; same intent as the stroke-start gate). An already in-progress
    // pan runs through to release (the `if (app.pan_active)` below does not look at popup_open).
    const popup_open = ctx.hasOpenPopup();

    // Is the mouse inside the canvas area? (used to decide zoom/pan start)
    const in_area = blk: {
        if (area) |a| {
            const p = in.mouse_pos;
            break :blk (p.x >= a.x and p.y >= a.y and p.x < a.x + a.w and p.y < a.y + a.h);
        }
        break :blk false;
    };

    // ── Wheel zoom (zoom-to-cursor; only inside area) ──
    // scroll_delta.y > 0 = scroll up = zoom in (adjust if a backend flips the sign).
    if (in_area and in.scroll_delta.y != 0 and !popup_open) {
        const step: i32 = if (in.scroll_delta.y > 0) 1 else -1;
        app.zoomAround(app.view_zoom.stepped(step), in.mouse_pos.x, in.mouse_pos.y);
    }

    // ── Pending KP_ADD/KP_SUBTRACT zoom (cursor axis; view center if outside area) ──
    if (app.pending_zoom_delta != 0 and !popup_open) {
        const delta = app.pending_zoom_delta;
        app.pending_zoom_delta = 0;
        app.zoomAround(app.view_zoom.stepped(delta), in.mouse_pos.x, in.mouse_pos.y);
    } else if (popup_open) {
        app.pending_zoom_delta = 0;
    }

    // ── Pan (Space+left / middle / Cmd+left). Do not start while capturing / editing a bezier ──
    if (!app.pan_active) {
        const bezier_editing = app.active_kind == .bezier and app.bezier_editor.isEditing();
        const kind_opt: ?PanKind = blk: {
            if (app.space_down and in.mouse_pressed.left) break :blk .space_left;
            if (in.mouse_pressed.middle) break :blk .middle;
            // mouse_pressed_modifiers: modifiers latched at down (start detection stays accurate even if move omits cmd)
            if (in.mouse_pressed.left and in.mouse_pressed_modifiers.cmd) break :blk .cmd_left;
            break :blk null;
        };
        if (kind_opt) |kind| {
            if (!app.input.capturing and !bezier_editing and !popup_open) {
                if (area) |a| {
                    const p = in.mouse_pressed_pos;
                    if (p.x >= a.x and p.y >= a.y and p.x < a.x + a.w and p.y < a.y + a.h) {
                        app.pan_active = true;
                        app.pan_kind = kind;
                        // Use the press coords as the anchor (using mouse_pos after a same-frame move would make delta=0)
                        app.pan_anchor_mouse = .{ .x = in.mouse_pressed_pos.x, .y = in.mouse_pressed_pos.y };
                        app.pan_anchor_cam_x = app.cam_cx;
                        app.pan_anchor_cam_y = app.cam_cy;
                    }
                }
            }
        }
    }
    if (app.pan_active) {
        const pan_held = switch (app.pan_kind) {
            .space_left => app.space_down and in.mouse_buttons.left,
            .middle => in.mouse_buttons.middle,
            // Cmd is latched at start. Finish with the left button held even if move omits modifiers.
            .cmd_left => in.mouse_buttons.left,
        };
        if (pan_held) {
            const zf = app.view_zoom.scaleF32();
            const dx = @as(f32, @floatFromInt(in.mouse_pos.x - app.pan_anchor_mouse.x));
            const dy = @as(f32, @floatFromInt(in.mouse_pos.y - app.pan_anchor_mouse.y));
            // Divide screen delta by zoom and update the camera in the opposite direction
            app.cam_cx = app.pan_anchor_cam_x - dx / zf;
            app.cam_cy = app.pan_anchor_cam_y - dy / zf;
        } else {
            app.pan_active = false;
        }
    }
    return app.pan_active;
}

/// M1 wiring: pick an OS cursor shape from the hover region (canvas / panel / outside) and call
/// `window.setCursor` only when it differs from the previous frame (canvas → crosshair; panel/outside → default).
/// Also update the free-hover position (`hover_screen`/`hover_cell`).
///
/// Call after canvas-input dispatch and before drawing (inside the main loop).
/// If called before dispatch, a newly started stroke this frame still has `isPointerBusy()` false when
/// hover is finalized, so the draw path can flash a footprint ring (Brush) for one frame
/// at busy start.
///
/// Hot path: called every frame but O(1) (rect hit-test + coordinate transform only). Not a full-pixel loop.
fn updateCursorAndHover(app: *App, window: platform.Window, ctx: *const gui.Context, canvas_rect: ?core.Rect) void {
    const mouse = core.Vec2{ .x = ctx.input.mouse_pos.x, .y = ctx.input.mouse_pos.y };
    // Judge by whether the point lands on a camera-derived canvas_rect pixel (screenToCanvas succeeds), not the whole view area.
    const hover_cell = if (canvas_rect) |rect|
        zoom_mod.screenToCanvas(mouse, rect, app.view_zoom)
    else
        null;
    const in_canvas = hover_cell != null;

    const shape: platform.CursorShape = if (in_canvas) .crosshair else .default;
    if (shape != app.cursor_shape) {
        app.cursor_shape = shape;
        window.setCursor(shape);
    }

    app.hover_screen = if (in_canvas and !app.isPointerBusy()) mouse else null;
    app.hover_cell = if (app.hover_screen != null) hover_cell else null;
}

fn layerWidgetId(idx: usize, part: gui.Id) gui.Id {
    return LAYER_ROW_ID_BASE + @as(gui.Id, idx) * LAYER_PANEL_ID_STRIDE + part;
}

/// Display cap for layer names (**total codepoints including truncation**). A display-only limit that fits the
/// 200px right-pane row; the stored name itself (`layer_name_max`=32B) is never truncated.
///
/// Measured: after subtracting thumb(24px)+visibility toggle(min_w 22)+opacity slider(track_w 40 etc.) from the
/// 200px right pane, the name field overflows the scroll viewport's opacity slider (and becomes unusable) once
/// total drawn characters exceed **7** (fixed font 8px/codepoint;
/// `libs/gui/src/font.zig`) — confirmed via harness snapshot (7 chars="Layer 1" fits; 8 chars≈"Layer 10"
/// does not). Default "Layer N" fits exactly at 7 chars for one digit; two digits and beyond
/// ("Layer 10".."Layer 99") are shortened by the truncation below to forms like "Layer.."
/// (the number is lost, but selection highlight/thumb still distinguish rows; three+ digits likewise).
const LAYER_NAME_DISPLAY_MAX: usize = 7;

/// Truncate a layer name for display so the **total codepoints including truncation** fit `max_total_chars`
/// (only when needed, replace the last 2 chars with ".."). buttonId/box width treats min_w as a
/// lower bound only, so passing an untruncated long name can grow the layer row without limit and
/// push the opacity slider etc. outside the scroll viewport
/// (this function exists only to prevent that; it never mutates saved data).
/// **Do not needlessly truncate a name that already fits** (e.g. "Layer 1"): decide "needs truncation?" from
/// the original total codepoint count (a blind "take first N chars and append .." can make
/// `N+2 > original length` for names that only barely exceed the budget, so truncation would make them longer —
/// avoid that accident).
/// Allocations use `ctx.allocator()` (frame arena); when it fits, return name with no
/// allocation.
///
/// Called every frame (part of immediate-mode GUI build), but the work here is at most
/// "layer count × a few dozen chars" — not a full-pixel loop, so the performance-rules SIMD
/// checklist does not apply to this function (`fillLayerThumb` scans the source canvas and is separate).
fn truncateForDisplay(alloc: std.mem.Allocator, name: []const u8, max_total_chars: usize) []const u8 {
    const view = std.unicode.Utf8View.init(name) catch return name; // Return invalid UTF-8 as-is (defensive)
    var total: usize = 0;
    {
        var counter = view.iterator();
        while (counter.nextCodepointSlice()) |_| total += 1;
    }
    if (total <= max_total_chars) return name; // Fits → no truncation

    const keep = if (max_total_chars > 2) max_total_chars - 2 else 0;
    var it = view.iterator();
    var end: usize = 0;
    var count: usize = 0;
    while (it.nextCodepointSlice()) |slice| {
        if (count >= keep) break;
        end += slice.len;
        count += 1;
    }
    return std.fmt.allocPrint(alloc, "{s}..", .{name[0..end]}) catch name[0..end];
}

/// Downscale raw layer pixels (`cw`×`ch` = doc.width×doc.height, straight BGRA 0xAARRGGBB) into THUMB,
/// src-over onto a checker so the thumb is opaque (transparent areas show the checker).
/// Each thumb pixel is an **alpha-weighted average (premultiplied mean)** of its source region so 1px fine lines
/// stay faintly visible (nearest-neighbor would drop them). opacity is not applied (show raw content).
/// Assumes buf.len == LAYER_THUMB_W * LAYER_THUMB_H.
fn fillLayerThumb(buf: []u32, layer_pixels: []const u32, cw: usize, ch: usize) void {
    const tw: usize = @intCast(LAYER_THUMB_W);
    const th: usize = @intCast(LAYER_THUMB_H);
    var ty: usize = 0;
    while (ty < th) : (ty += 1) {
        const sy0 = ty * ch / th;
        const sy1 = @max(sy0 + 1, (ty + 1) * ch / th); // Always at least one row
        var tx: usize = 0;
        while (tx < tw) : (tx += 1) {
            const sx0 = tx * cw / tw;
            const sx1 = @max(sx0 + 1, (tx + 1) * cw / tw);
            // Build straight BGRA as the premultiplied mean of source region [sx0,sx1)×[sy0,sy1)
            var sum_a: u64 = 0;
            var sum_r: u64 = 0;
            var sum_g: u64 = 0;
            var sum_b: u64 = 0;
            var n: u64 = 0;
            var sy = sy0;
            while (sy < sy1) : (sy += 1) {
                var sx = sx0;
                while (sx < sx1) : (sx += 1) {
                    const px = layer_pixels[sy * cw + sx];
                    const a: u64 = (px >> 24) & 0xFF;
                    const r: u64 = (px >> 16) & 0xFF;
                    const g: u64 = (px >> 8) & 0xFF;
                    const b: u64 = px & 0xFF;
                    sum_a += a;
                    sum_r += r * a;
                    sum_g += g * a;
                    sum_b += b * a;
                    n += 1;
                }
            }
            const avg_a: u32 = @intCast(sum_a / n);
            const avg_r: u32 = if (sum_a > 0) @intCast(sum_r / sum_a) else 0;
            const avg_g: u32 = if (sum_a > 0) @intCast(sum_g / sum_a) else 0;
            const avg_b: u32 = if (sum_a > 0) @intCast(sum_b / sum_a) else 0;
            const src = (avg_a << 24) | (avg_r << 16) | (avg_g << 8) | avg_b;
            const checker = (tx / LAYER_THUMB_CELL + ty / LAYER_THUMB_CELL) & 1;
            const bg: u32 = if (checker == 0) CHECKER_LIGHT else CHECKER_DARK;
            buf[ty * tw + tx] = core.blend.srcOver(bg, src);
        }
    }
}

fn buildLayerPanel(ctx: *gui.Context, app: *App) !void {
    // Collapsible body is fit, so inject the previous-frame panel-wrap width as .fixed.
    const outer_w = app.layersBodyAvail(ctx);
    const body_pad: i32 = 2;
    const content_w = @max(1, outer_w - body_pad * 2);

    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .fixed = outer_w },
        .gap = 4,
        .padding = .{ body_pad, body_pad, body_pad, body_pad },
    });
    defer ctx.endBox();

    // toolbar stays outside the scroll (always operable).
    ctx.beginBox(.{ .direction = .row, .width = .{ .fixed = content_w }, .gap = 4 });
    // During netsync use routeAction (#id); solo calls do* directly.
    if (ctx.buttonId(LAYER_PANEL_ID_BASE + 1, "+", .{ .min_w = 28 }).clicked) {
        if (platform.netsyncActive()) app.routeUi("add_layer", "") else _ = app.doAddLayer() catch {};
    }
    if (ctx.buttonId(LAYER_PANEL_ID_BASE + 2, "-", .{ .min_w = 28 }).clicked) {
        const idx = app.canvas.selected_layer;
        if (platform.netsyncActive()) app.routeUiLayerOp("delete_layer", idx) else app.doDeleteLayer(idx) catch {};
    }
    if (ctx.buttonId(LAYER_PANEL_ID_BASE + 3, "Up", .{ .min_w = 34 }).clicked) {
        const idx = app.canvas.selected_layer;
        if (platform.netsyncActive()) app.routeUiLayerMove(idx, 1) else app.doMoveLayer(idx, 1) catch {};
    }
    if (ctx.buttonId(LAYER_PANEL_ID_BASE + 4, "Dn", .{ .min_w = 34 }).clicked) {
        const idx = app.canvas.selected_layer;
        if (platform.netsyncActive()) app.routeUiLayerMove(idx, -1) else app.doMoveLayer(idx, -1) catch {};
    }
    ctx.endBox();

    app.updateLayersViewportHeight(ctx);
    // Fix the ScrollArea viewport to the content width and keep content_width=.grow so rows stretch to the body width.
    ctx.beginScrollArea(LAYERS_SCROLL_ID, &app.layers_scroll, .{
        .width = .{ .fixed = content_w },
        .height = .{ .fixed = app.layers_viewport_h },
        .padding = .{ 0, 2, 0, 2 },
        .gap = 2,
        .content_width = .{ .grow = 1 },
        .content_height = .fit,
    });

    var rev = app.canvas.layers.items.len;
    while (rev > 0) {
        rev -= 1;
        const idx = rev;
        const layer = app.canvas.layers.items[idx];
        // One row = [thumb][name][V/H][opacity slider]. Row height is paced by the thumb (24px).
        // width=.grow stretches to the ScrollArea content width so the selection background covers the whole row.
        // Attach an explicit ID (row_id) so it lands in rect_cache (for right-click hit-testing).
        const row_id = layerWidgetId(idx, LAYER_ROW_PART_ROW);
        const selected = idx == app.canvas.selected_layer;
        const row_bg: ?gui.Color = if (selected) ctx.style.button_bg_selected else null;
        const row_border: ?gui.Border = if (selected)
            .{ .color = ctx.style.border_hover, .thickness = 1 }
        else
            null;
        ctx.beginBox(.{
            .id = row_id,
            .direction = .row,
            .width = .{ .grow = 1 },
            .gap = 3,
            .align_cross = .center,
            .bg = row_bg,
            .border = row_border,
        });

        // Thumb: downscale-composite the raw layer onto a checker. Selected rows get a bright border.
        const thumb = ctx.allocator().alloc(u32, @as(usize, @intCast(LAYER_THUMB_W)) * @as(usize, @intCast(LAYER_THUMB_H))) catch @panic("layer thumb: OOM");
        fillLayerThumb(thumb, layer.pixels, app.doc.width, app.doc.height);
        const thumb_border = if (selected) ctx.style.border_hover else ctx.style.border;
        ctx.imageBox(layerWidgetId(idx, 3), thumb, LAYER_THUMB_W, LAYER_THUMB_H, .{ .border = thumb_border });

        // Layer-name display. While renaming, only the target row shows the pre-commit buffer + caret.
        if (app.rename_in.active and app.rename_in.layer_idx == idx) {
            const shown = truncateForDisplay(ctx.allocator(), app.rename_in.text(), LAYER_NAME_DISPLAY_MAX);
            ctx.beginBox(.{
                .id = layerWidgetId(idx, LAYER_ROW_PART_IME),
                .padding = .{ 2, 4, 2, 4 },
                .bg = ctx.style.bg_active,
                .border = .{ .color = ctx.style.border_hover, .thickness = 1 },
            });
            if (app.preedit().len > 0) {
                const draw_ctx = ctx.allocator().create(InlineCompositionDraw) catch @panic("composition draw ctx: OOM");
                draw_ctx.* = .{
                    .committed = shown,
                    .preedit = app.preedit(),
                    .cursor = app.preedit_cursor,
                    .font = ctx.font,
                    .color = ctx.style.text,
                    .preedit_color = gui.Color.rgba(0x66, 0xCC, 0xFF, 0xFF),
                };
                ctx.custom(.{ .x = @intCast(ctx.font.measure(shown) + ctx.font.measure(app.preedit())), .y = gui.fontInkHeight(ctx.font) }, drawInlineComposition, draw_ctx);
            } else {
                var cursor_buf: [96]u8 = undefined;
                const with_cursor = std.fmt.bufPrint(&cursor_buf, "{s}_", .{shown}) catch shown;
                ctx.labelEx(with_cursor, ctx.style.text);
            }
            ctx.endBox();
        } else {
            const shown = truncateForDisplay(ctx.allocator(), layer.name(), LAYER_NAME_DISPLAY_MAX);
            if (ctx.buttonId(layerWidgetId(idx, 0), shown, .{ .selected = selected, .min_w = 28 }).clicked) {
                app.doSelectLayer(idx) catch {};
            }
        }
        // V=visible ON (selected accent) / H=hidden OFF (normal bg). State is readable from both color and letter.
        const vis_label: []const u8 = if (layer.visible) "V" else "H";
        if (ctx.buttonId(layerWidgetId(idx, 1), vis_label, .{ .selected = layer.visible, .min_w = 22 }).clicked) {
            if (platform.netsyncActive()) app.routeUiLayerVisible(idx, !layer.visible) else app.doToggleLayerVisible(idx);
        }
        var op_i32: i32 = layer.opacity;
        if (ctx.sliderI32Id(layerWidgetId(idx, 2), "O", &op_i32, .{ .min = 0, .max = 255, .track_w = 40 })) {
            const v: u8 = @intCast(std.math.clamp(op_i32, 0, 255));
            if (platform.netsyncActive()) app.routeUiLayerOpacity(idx, v) else app.doSetLayerOpacity(idx, v) catch {};
        }
        ctx.endBox(); // row

        // Right-click: test against both the row rect and the ancestor clip (ScrollArea viewport).
        if (ctx.input.mouse_pressed.right) {
            if (ctx.getNodeCachedRect(row_id)) |cached| {
                const p = ctx.input.mouse_pressed_pos;
                if (cached.clip.contains(p) and cached.rect.contains(p)) {
                    app.doSelectLayer(idx) catch {};
                    ctx.openPopup(LAYER_CTX_MENU_ID, p);
                }
            }
        }
    }

    try buildTextLayerPanel(ctx, app);
    ctx.endScrollArea();
}

fn historyActorAbbrev(entry: *const history_summary.HistoryEntry, buf: []u8) []const u8 {
    if (std.mem.eql(u8, entry.actor, "local_user")) return "u";
    if (std.mem.eql(u8, entry.actor, "local_agent")) return "ai";
    if (std.mem.eql(u8, entry.actor, "system")) return "sys";
    if (entry.actor_peer) |id| {
        // Resolved + non-empty label → H:<label> / AI:<label>. Unresolved / empty label → #<id>.
        if (entry.origin_kind != .unknown and entry.origin_label_len > 0) {
            const prefix: []const u8 = switch (entry.origin_kind) {
                .human => "H",
                .agent => "AI",
                .unknown => unreachable,
            };
            return std.fmt.bufPrint(buf, "{s}:{s}", .{ prefix, entry.originLabel() }) catch "#?";
        }
        return std.fmt.bufPrint(buf, "#{d}", .{id}) catch "peer";
    }
    return "peer";
}

/// Whether this is our own wire op (only while netsync is active. host=peer_id 0 / client=HELLO-assigned id).
fn isOwnHistoryEntry(app: *const App, entry: *const history_summary.HistoryEntry) bool {
    _ = app;
    if (!platform.netsyncActive()) return false;
    const peer = entry.actor_peer orelse return false;
    return peer == platform.netsyncLocalPeerId();
}

/// Display priority: reverted (grey) > redo_consumed (dim) > own-op (normal color + bg) > normal.
fn historyRowColor(ctx: *gui.Context, entry: *const history_summary.HistoryEntry, is_own: bool) gui.Color {
    _ = is_own;
    if (entry.reverted) return ctx.style.text_subtle;
    if (entry.redo_consumed) return gui.Color.rgba(0x68, 0x70, 0x78, 0xFF);
    return ctx.style.text;
}

fn formatHistoryLine(entry: *const history_summary.HistoryEntry, buf: []u8, is_own: bool) []const u8 {
    var actor_buf: [history_summary.MAX_ACTOR_LABEL + 8]u8 = undefined;
    const actor = historyActorAbbrev(entry, &actor_buf);
    // Leading ★ (own wire op only. Still shown when reverted/redo_consumed; color/bg carry priority).
    const star: []const u8 = if (is_own) "★ " else "";
    if (entry.tx != null) {
        return std.fmt.bufPrint(buf, "{s}#{d} {s} T {s}", .{ star, entry.seq, actor, entry.summary() }) catch "";
    }
    return std.fmt.bufPrint(buf, "{s}#{d} {s} {s}", .{ star, entry.seq, actor, entry.summary() }) catch "";
}

fn historyRowId(idx: u32) gui.Id {
    return HISTORY_PANEL_ID_BASE + @as(gui.Id, idx);
}

/// History panel. CommandLog as a newest-on-top vertical list.
/// Hot path: rebuilt every frame, but history data rebuilds only when dirty (event-time equivalent).
/// Thumbnails are blit-only from a fixed buffer (no PixelDiff / bbox recompute / composite / allocator).
fn buildHistoryPanel(ctx: *gui.Context, app: *App) void {
    app.ensureHistoryFresh();
    if (app.history_count == 0) {
        ctx.labelEx("(empty)", ctx.style.text_subtle);
        return;
    }
    const thumb_w: i32 = @intCast(history_thumbnail.THUMB_W);
    const thumb_h: i32 = @intCast(history_thumbnail.THUMB_H);
    var rev: u32 = app.history_count;
    while (rev > 0) {
        rev -= 1;
        const entry = &app.history_entries[rev];
        const is_own = isOwnHistoryEntry(app, entry);
        // own background ranks below reverted/redo_consumed (suppress bg to match color priority)
        const own_bg: ?gui.Color = if (is_own and !entry.reverted and !entry.redo_consumed)
            ctx.style.button_bg_selected
        else
            null;
        var line_buf: [platform.command.MAX_SUMMARY + history_summary.MAX_ACTOR_LABEL + 64]u8 = undefined;
        const line = formatHistoryLine(entry, &line_buf, is_own);
        ctx.beginBox(.{
            .id = historyRowId(rev),
            .direction = .row,
            .width = .{ .grow = 1 },
            .gap = 2,
            .align_cross = .center,
            .bg = own_bg,
        });
        // [24x24 thumbnail or label][history text]
        if (entry.visual.thumb_present) {
            const slot: usize = @intCast(entry.seq % platform.command.MAX_CMD_LOG);
            const meta = app.history_thumb_meta[slot];
            if (meta.seq == entry.seq and meta.thumbPresent()) {
                ctx.imageBox(
                    historyRowId(rev) + 0x1000,
                    app.history_thumbs[slot][0..],
                    thumb_w,
                    thumb_h,
                    .{ .border = ctx.style.border },
                );
            } else {
                ctx.labelEx("[meta]", ctx.style.text_subtle);
            }
        } else if (std.mem.eql(u8, entry.kind, "revert") or entry.visual.kind == .revert) {
            ctx.labelEx("[undo]", ctx.style.text_subtle);
        } else {
            ctx.labelEx("[meta]", ctx.style.text_subtle);
        }
        ctx.labelEx(line, historyRowColor(ctx, entry, is_own));
        ctx.endBox();
    }
}

/// Edit panel for text layers (kind==.text). Shown only when the selected layer is text.
/// Handles content edit (inline via `text_in`) / font size / position (x,y) /
/// applying the current color. On value change, delegates to `App.doSetTextParams` (same
/// "call only when the value changed" pattern as the existing opacity slider. Multiple pushes while dragging
/// are the same known trade-off class as that slider — not a new concern).
///
/// Hot path: built every frame (part of immediate-mode GUI), but actual re-rasterize
/// (via `doSetTextParams`) runs **event-time only** (slider change, string commit, etc.).
fn buildTextLayerPanel(ctx: *gui.Context, app: *App) !void {
    const idx = app.canvas.selected_layer;
    if (idx >= app.canvas.layers.items.len) return;
    if (app.canvas.layers.items[idx].kind != .text) return;
    const layer = app.canvas.layers.items[idx];

    ctx.label("Text Layer");
    ctx.beginBox(.{ .direction = .column, .gap = 3 });

    if (app.text_in.active and app.text_in.layer_idx == idx) {
        const shown = truncateForDisplay(ctx.allocator(), app.text_in.text(), LAYER_NAME_DISPLAY_MAX);
        ctx.beginBox(.{
            .id = TEXT_EDIT_BOX_ID,
            .padding = .{ 2, 4, 2, 4 },
            .bg = ctx.style.bg_active,
            .border = .{ .color = ctx.style.border_hover, .thickness = 1 },
        });
        if (app.preedit().len > 0) {
            const draw_ctx = ctx.allocator().create(InlineCompositionDraw) catch @panic("composition draw ctx: OOM");
            draw_ctx.* = .{
                .committed = shown,
                .preedit = app.preedit(),
                .cursor = app.preedit_cursor,
                .font = ctx.font,
                .color = ctx.style.text,
                .preedit_color = gui.Color.rgba(0x66, 0xCC, 0xFF, 0xFF),
            };
            ctx.custom(.{ .x = @intCast(ctx.font.measure(shown) + ctx.font.measure(app.preedit())), .y = gui.fontInkHeight(ctx.font) }, drawInlineComposition, draw_ctx);
        } else {
            var cursor_buf: [160]u8 = undefined;
            const with_cursor = std.fmt.bufPrint(&cursor_buf, "{s}_", .{shown}) catch shown;
            ctx.labelEx(with_cursor, ctx.style.text);
        }
        ctx.endBox();
    } else {
        const shown = truncateForDisplay(ctx.allocator(), layer.text_params.text(), LAYER_NAME_DISPLAY_MAX);
        if (ctx.buttonId(TEXT_PANEL_ID_BASE + 1, shown, .{ .min_w = 100 }).clicked) {
            app.beginTextEdit(idx);
        }
    }

    var px_f32: f32 = layer.text_params.font_px;
    if (ctx.sliderF32Id(TEXT_PANEL_ID_BASE + 2, "Size", &px_f32, .{ .min = 6, .max = 96, .step = 1, .track_w = 80 })) {
        var params = layer.text_params;
        params.font_px = px_f32;
        app.doSetTextParams(idx, params) catch {};
    }

    var x_i32: i32 = layer.text_params.x;
    const max_x: i32 = @max(@as(i32, @intCast(app.canvas.width)), 1) - 1;
    if (ctx.sliderI32Id(TEXT_PANEL_ID_BASE + 3, "X", &x_i32, .{ .min = 0, .max = max_x, .track_w = 80 })) {
        var params = layer.text_params;
        params.x = x_i32;
        app.doSetTextParams(idx, params) catch {};
    }

    var y_i32: i32 = layer.text_params.y;
    const max_y: i32 = @max(@as(i32, @intCast(app.canvas.height)), 1) - 1;
    if (ctx.sliderI32Id(TEXT_PANEL_ID_BASE + 4, "Y", &y_i32, .{ .min = 0, .max = max_y, .track_w = 80 })) {
        var params = layer.text_params;
        params.y = y_i32;
        app.doSetTextParams(idx, params) catch {};
    }

    if (ctx.buttonId(TEXT_PANEL_ID_BASE + 5, "Apply Color", .{ .min_w = 80 }).clicked) {
        var params = layer.text_params;
        params.color = app.palette.current();
        app.doSetTextParams(idx, params) catch {};
    }

    ctx.endBox();
}

fn timelineCellId(layer_idx: usize, frame_idx: u32) gui.Id {
    return TIMELINE_CELL_ID_BASE + @as(gui.Id, @intCast(layer_idx)) * TIMELINE_CELL_FRAME_STRIDE + frame_idx;
}

fn timelineHeaderId(frame_idx: u32) gui.Id {
    return TIMELINE_HEADER_ID_BASE + frame_idx;
}

/// Checker thumb for empty cells (no cel).
fn fillEmptyThumb(buf: []u32) void {
    const tw: usize = @intCast(LAYER_THUMB_W);
    const th: usize = @intCast(LAYER_THUMB_H);
    var ty: usize = 0;
    while (ty < th) : (ty += 1) {
        var tx: usize = 0;
        while (tx < tw) : (tx += 1) {
            const checker = (tx / LAYER_THUMB_CELL + ty / LAYER_THUMB_CELL) & 1;
            buf[ty * tw + tx] = if (checker == 0) CHECKER_LIGHT else CHECKER_DARK;
        }
    }
}

const TimelineCellDraw = struct {
    buf: []const u32,
    border_left: bool,
    border_right: bool,
    border_top: bool,
    border_bottom: bool,
    border_color: gui.Color,

    fn draw(ctx_ptr: *anyopaque, dl: *gui.DrawList, rect: gui.Rect) void {
        const self: *const TimelineCellDraw = @ptrCast(@alignCast(ctx_ptr));
        dl.image(rect, self.buf, @intCast(LAYER_THUMB_W), @intCast(LAYER_THUMB_H)) catch @panic("timeline cell: OOM");
        const t: u32 = 1;
        const col = self.border_color;
        const rh: i32 = @intCast(rect.h);
        const rw: i32 = @intCast(rect.w);
        const ti: i32 = @intCast(t);
        if (self.border_top) dl.rectFilled(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = t }, col) catch @panic("timeline cell: OOM");
        if (self.border_bottom) dl.rectFilled(.{ .x = rect.x, .y = rect.y + rh - ti, .w = rect.w, .h = t }, col) catch @panic("timeline cell: OOM");
        if (self.border_left) dl.rectFilled(.{ .x = rect.x, .y = rect.y, .w = t, .h = rect.h }, col) catch @panic("timeline cell: OOM");
        if (self.border_right) dl.rectFilled(.{ .x = rect.x + rw - ti, .y = rect.y, .w = t, .h = rect.h }, col) catch @panic("timeline cell: OOM");
    }
};

fn timelineCellBorderSides(doc: *const core.Document, layer_idx: usize, frame_idx: u32) struct { left: bool, right: bool, is_linked: bool } {
    const cid = doc.gridGet(layer_idx, frame_idx);
    if (cid == null) return .{ .left = true, .right = true, .is_linked = false };
    const left_same = if (frame_idx > 0) doc.gridGet(layer_idx, frame_idx - 1) == cid else false;
    const right_same = if (frame_idx + 1 < doc.frames.items.len) doc.gridGet(layer_idx, frame_idx + 1) == cid else false;
    return .{ .left = !left_same, .right = !right_same, .is_linked = left_same or right_same };
}

/// Bottom-pane timeline UI. Cell grid of rows=layer × columns=frame.
/// Hot path: built every frame (immediate-mode GUI). Thumbs are 24×24 downscales only.
fn buildTimelinePanel(ctx: *gui.Context, app: *App) !void {
    app.clampTimelineTarget();
    const tl = TIMELINE_PANEL_ID_BASE;
    const target_layer = app.timeline_target_layer;
    const target_frame = app.timeline_target_frame;

    ctx.beginBox(.{ .direction = .row, .gap = 4, .align_cross = .center });
    const play_label: []const u8 = if (app.timeline_playing) "Pause" else "Play";
    if (ctx.buttonId(tl + 1, play_label, .{ .min_w = 44, .selected = app.timeline_playing }).clicked) {
        app.timeline_playing = !app.timeline_playing;
        app.timeline_last_advance = platform.getTime();
    }
    var fps_f32 = app.timeline_fps;
    if (ctx.sliderF32Id(tl + 2, "FPS", &fps_f32, .{ .min = 1, .max = 30, .step = 1, .track_w = 60 })) {
        app.timeline_fps = fps_f32;
    }
    if (ctx.buttonId(tl + 3, "Fr+", .{ .min_w = 32 }).clicked) app.doAddFrame() catch {};
    if (ctx.buttonId(tl + 4, "Dup", .{ .min_w = 32 }).clicked) app.doDuplicateFrame() catch {};
    if (ctx.buttonId(tl + 5, "Del", .{ .min_w = 32 }).clicked) app.doDeleteFrame() catch {};
    if (ctx.buttonId(tl + 6, "<", .{ .min_w = 24 }).clicked) app.doAdvanceFrame(-1) catch {};
    if (ctx.buttonId(tl + 7, ">", .{ .min_w = 24 }).clicked) app.doAdvanceFrame(1) catch {};
    if (ctx.buttonId(tl + 8, "Cel+", .{ .min_w = 36 }).clicked) app.doCreateCelAt(target_layer, target_frame) catch {};
    if (ctx.buttonId(tl + 9, "Clr", .{ .min_w = 32 }).clicked) app.doClearCelAt(target_layer, target_frame) catch {};
    if (ctx.buttonId(tl + 10, "Link", .{ .min_w = 36 }).clicked) app.doLinkCelLeft(target_layer, target_frame) catch {};
    if (ctx.buttonId(tl + 11, "Unlk", .{ .min_w = 36 }).clicked) app.doUnlinkCelAt(target_layer, target_frame) catch {};
    _ = ctx.toggleId(tl + 12, "Onion", &app.onion_enabled);
    if (app.onion_enabled) {
        var onion_n_i32: i32 = @intCast(app.onion_count);
        if (ctx.sliderI32Id(tl + 13, "On.N", &onion_n_i32, .{ .min = 1, .max = @as(i32, @intCast(core.onion_skin.max_count)), .step = 1, .track_w = 40 })) {
            app.onion_count = @intCast(std.math.clamp(onion_n_i32, 1, @as(i32, @intCast(core.onion_skin.max_count))));
        }
    }
    ctx.endBox();

    ctx.beginScrollArea(TIMELINE_SCROLL_ID, &app.timeline_scroll, .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .direction = .column,
        .gap = 1,
        .content_width = .fit,
        .content_height = .fit,
    });

    ctx.beginBox(.{ .direction = .row, .gap = 1, .align_cross = .center });
    ctx.beginBox(.{ .width = .{ .fixed = TIMELINE_LABEL_W }, .height = .{ .fixed = TIMELINE_CELL_H } });
    ctx.endBox();
    var fi: u32 = 0;
    while (fi < app.doc.frames.items.len) : (fi += 1) {
        var num_buf: [8]u8 = undefined;
        const num_txt = try std.fmt.bufPrint(&num_buf, "{d}", .{fi + 1});
        if (ctx.buttonId(timelineHeaderId(fi), num_txt, .{
            .min_w = TIMELINE_CELL_W,
            .selected = fi == app.doc.selected_frame,
        }).clicked) {
            app.doSelectFrame(fi) catch {};
        }
    }
    ctx.endBox();

    var rev = app.doc.layers.items.len;
    while (rev > 0) {
        rev -= 1;
        const li = rev;
        const layer_def = app.doc.layers.items[li];
        ctx.beginBox(.{ .direction = .row, .gap = 1, .align_cross = .center });
        const shown = truncateForDisplay(ctx.allocator(), layer_def.name(), LAYER_NAME_DISPLAY_MAX);
        if (ctx.buttonId(tl + 100 + @as(gui.Id, @intCast(li)), shown, .{
            .min_w = TIMELINE_LABEL_W,
            .selected = li == app.canvas.selected_layer,
        }).clicked) {
            app.doSelectLayer(li) catch {};
            app.timeline_target_layer = li;
        }

        fi = 0;
        while (fi < app.doc.frames.items.len) : (fi += 1) {
            const thumb = ctx.allocator().alloc(u32, @as(usize, @intCast(LAYER_THUMB_W)) * @as(usize, @intCast(LAYER_THUMB_H))) catch @panic("timeline thumb: OOM");
            if (app.doc.gridGet(li, fi)) |cel_id| {
                if (app.doc.celPixels(cel_id)) |pixels| fillLayerThumb(thumb, pixels, app.doc.width, app.doc.height);
            } else {
                fillEmptyThumb(thumb);
            }
            const sides = timelineCellBorderSides(&app.doc, li, fi);
            const is_playhead = fi == app.doc.selected_frame;
            const is_target = li == target_layer and fi == target_frame;
            const border_color = if (is_playhead)
                TIMELINE_PLAYHEAD_BORDER
            else if (sides.is_linked)
                TIMELINE_LINK_BORDER
            else if (is_target)
                ctx.style.border_hover
            else
                ctx.style.border;
            const data = ctx.allocator().create(TimelineCellDraw) catch @panic("timeline cell: OOM");
            data.* = .{
                .buf = thumb,
                .border_left = sides.left or is_playhead,
                .border_right = sides.right or is_playhead,
                .border_top = true,
                .border_bottom = true,
                .border_color = border_color,
            };
            ctx.beginBox(.{ .id = timelineCellId(li, fi), .width = .{ .fixed = TIMELINE_CELL_W }, .height = .{ .fixed = TIMELINE_CELL_H } });
            ctx.custom(.{ .x = TIMELINE_CELL_W, .y = TIMELINE_CELL_H }, TimelineCellDraw.draw, data);
            ctx.endBox();
        }
        ctx.endBox();
    }

    ctx.endScrollArea();

    if (ctx.input.mouse_pressed.left) {
        const p = ctx.input.mouse_pressed_pos;
        const in_viewport = if (ctx.getNodeRect(TIMELINE_SCROLL_ID)) |vp| vp.contains(p) else false;
        if (in_viewport) {
            var li2 = app.doc.layers.items.len;
            while (li2 > 0) {
                li2 -= 1;
                fi = 0;
                while (fi < app.doc.frames.items.len) : (fi += 1) {
                    if (ctx.getNodeRect(timelineCellId(li2, fi))) |r| {
                        if (r.contains(p)) {
                            app.timeline_target_layer = li2;
                            app.timeline_target_frame = fi;
                            app.doSelectFrame(fi) catch {};
                            app.doSelectLayer(li2) catch {};
                            return;
                        }
                    }
                }
            }
        }
    }
}

fn panelBuildHistory(ctx: *gui.Context, user_data: *anyopaque) anyerror!void {
    const app: *App = @ptrCast(@alignCast(user_data));
    buildHistoryPanel(ctx, app);
}

fn panelBuildColor(ctx: *gui.Context, user_data: *anyopaque) anyerror!void {
    const app: *App = @ptrCast(@alignCast(user_data));
    // HSV. Write-back before the palette grid (avoid overwrite on selection-change).
    ctx.beginBox(.{ .direction = .row, .gap = 8, .align_cross = .start });
    // Compress SV so Color + Tool Options (including Brush sliders / Bezier anchors) fit above the
    // status bar at the default 780x600.
    _ = ctx.svSquareId(0xCED10001, app.edit_h, &app.edit_s, &app.edit_v, .{ .size = 80 });
    _ = ctx.hueBarId(0xCED10002, &app.edit_h, .{ .h = 80 });
    ctx.endBox();
    _ = ctx.sliderF32Id(0xCED10003, "H", &app.edit_h, .{ .min = 0, .max = 360, .step = 1, .track_w = 96 });
    _ = ctx.sliderF32Id(0xCED10004, "S", &app.edit_s, .{ .min = 0, .max = 1, .step = 0.01, .track_w = 96 });
    _ = ctx.sliderF32Id(0xCED10005, "V", &app.edit_v, .{ .min = 0, .max = 1, .step = 0.01, .track_w = 96 });
    app.edit_h = @min(app.edit_h, 360 - 1e-3); // Same [0,360) contract as hueBar
    app.applyEditColor();
}

fn panelBuildPalette(ctx: *gui.Context, user_data: *anyopaque) anyerror!void {
    const app: *App = @ptrCast(@alignCast(user_data));
    {
        var idx: usize = 0;
        while (idx < app.palette.colors.items.len) {
            ctx.beginBox(.{ .direction = .row, .gap = 3 });
            var col: u32 = 0;
            while (col < 4 and idx < app.palette.colors.items.len) : (col += 1) {
                const swatch_id: gui.Id = 0x1000 + @as(gui.Id, idx);
                if (ctx.colorSwatchId(swatch_id, .{
                    .color = guiColor(app.palette.colors.items[idx]),
                    .selected = idx == app.palette.selected,
                    .size = 22,
                }).clicked) {
                    app.palette.select(idx);
                    app.repl_source = app.palette.current();
                    if (app.active_kind == .eraser) app.setActiveKind(.pen);
                }
                idx += 1;
            }
            ctx.endBox();
        }
    }
    ctx.beginBox(.{ .direction = .row, .gap = 4 });
    if (ctx.buttonEx("+", .{ .min_w = 28 }).clicked) {
        app.palette.addColor(app.gpa, app.palette.current()) catch {};
    }
    if (ctx.buttonEx("-", .{ .min_w = 28 }).clicked) {
        app.palette.removeSelected();
        app.edit_synced_for = null;
        app.repl_source = null;
    }
    if (ctx.buttonEx("Repl", .{ .min_w = 36 }).clicked) {
        if (platform.netsyncActive()) {
            app.setSaveMsg("netsync: Repl unavailable (use replace_color with #id)", .{});
        } else {
            const to: u32 = @bitCast(gui.Color.fromHsv(app.edit_h, app.edit_s, app.edit_v));
            const from = app.repl_source orelse app.palette.current();
            _ = app.doReplaceColor(app.canvas.selected_layer, from, to) catch {};
            app.palette.setSelectedColor(to);
            app.pen.color = to;
            app.brush.color = to;
            app.fill.color = to;
            app.edit_synced_for = null;
            app.repl_source = to;
        }
    }
    ctx.endBox();
}

fn toolIconButton(ctx: *gui.Context, id_off: gui.Id, icon: gui.IconBitmap, selected: bool, tip: []const u8) bool {
    const res = ctx.iconButtonId(TOOL_ICON_ID_BASE + id_off, icon, selected);
    ctx.tooltip(tip);
    return res.clicked;
}

fn panelBuildToolOptions(ctx: *gui.Context, user_data: *anyopaque) anyerror!void {
    const app: *App = @ptrCast(@alignCast(user_data));
    // 4-column icon grid
    ctx.beginBox(.{ .direction = .row, .gap = 4 });
    if (toolIconButton(ctx, 0, icons.pen, app.active_kind == .pen, "Pen (B)")) app.setActiveKind(.pen);
    if (toolIconButton(ctx, 1, icons.eraser, app.active_kind == .eraser, "Eraser (E)")) app.setActiveKind(.eraser);
    if (toolIconButton(ctx, 2, icons.brush, app.active_kind == .brush, "Brush (no shortcut)")) app.setActiveKind(.brush);
    if (toolIconButton(ctx, 3, icons.bezier, app.active_kind == .bezier, "Bezier (P)")) app.setActiveKind(.bezier);
    ctx.endBox();
    ctx.beginBox(.{ .direction = .row, .gap = 4 });
    if (toolIconButton(ctx, 4, icons.select, app.active_kind == .select, "Select (M)")) app.setActiveKind(.select);
    if (toolIconButton(ctx, 5, icons.fill, app.active_kind == .fill, "Fill (G)")) app.setActiveKind(.fill);
    if (toolIconButton(ctx, 6, icons.eyedrop, app.active_kind == .eyedropper, "Eyedrop (I)")) app.setActiveKind(.eyedropper);
    if (toolIconButton(ctx, 7, icons.line, app.active_kind == .line, "Line (no shortcut)")) app.setActiveKind(.line);
    ctx.endBox();
    ctx.beginBox(.{ .direction = .row, .gap = 4 });
    if (toolIconButton(ctx, 8, icons.rect, app.active_kind == .rect, "Rect (no shortcut)")) app.setActiveKind(.rect);
    if (toolIconButton(ctx, 9, icons.ellipse, app.active_kind == .ellipse, "Ellipse (no shortcut)")) app.setActiveKind(.ellipse);
    ctx.endBox();
    ctx.beginBox(.{ .direction = .row, .gap = 4 });
    if (toolIconButton(ctx, 10, icons.sym_off, app.symmetry == .off, "Symmetry Off (no shortcut)")) app.uiSetSymmetry(.off);
    if (toolIconButton(ctx, 11, icons.sym_v, app.symmetry == .vertical, "Symmetry V (no shortcut)")) app.uiSetSymmetry(.vertical);
    if (toolIconButton(ctx, 12, icons.sym_h, app.symmetry == .horizontal, "Symmetry H (no shortcut)")) app.uiSetSymmetry(.horizontal);
    if (toolIconButton(ctx, 13, icons.sym_q, app.symmetry == .quad, "Symmetry Q (no shortcut)")) app.uiSetSymmetry(.quad);
    ctx.endBox();

    ctx.labelEx("Alt+click: eyedrop", ctx.style.text_subtle);
    var keep_transp = app.blend_mode == .over;
    if (ctx.toggle("Keep Transp", &keep_transp)) {
        app.blend_mode = if (keep_transp) .over else .replace;
    }
    if (app.active_kind == .rect or app.active_kind == .ellipse) {
        var fill_on = app.shape_in.fill;
        if (ctx.toggle("Shape Fill", &fill_on)) {
            app.shape_in.fill = fill_on;
        }
    }
    var pp_on = app.pixel_perfect;
    if (ctx.toggle("Pixel Perfect", &pp_on)) {
        app.uiSetPixelPerfect(pp_on);
    }
    var grid_on = app.grid_enabled;
    if (ctx.toggle("Grid", &grid_on)) {
        app.grid_enabled = grid_on;
    }
    var loupe_on = app.loupe_enabled;
    if (ctx.toggle("Loupe", &loupe_on)) {
        app.loupe_enabled = loupe_on;
    }
    if (app.active_kind == .brush or app.active_kind == .bezier) {
        _ = ctx.sliderI32Id(0xB0_0001, "Size", &app.brush_size_i32, .{ .min = 1, .max = 64, .track_w = 90 });
        _ = ctx.sliderI32Id(0xB0_0002, "Opac", &app.brush_opacity_i32, .{ .min = 0, .max = 255, .track_w = 90 });
        _ = ctx.sliderF32Id(0xB0_0003, "Hard", &app.brush_hardness_f32, .{ .min = 0, .max = 1, .step = 0.05, .track_w = 90 });
    }
    if (app.active_kind == .bezier) {
        const n = app.bezier_editor.path.anchors.items.len;
        ctx.labelEx(
            std.fmt.allocPrint(ctx.allocator(), "anchors: {d}", .{n}) catch "anchors: ?",
            ctx.style.text_subtle,
        );
    }
    if (app.active_kind == .fill) {
        _ = ctx.sliderI32Id(0xFEED_0001, "Tol", &app.fill_tolerance_i32, .{ .min = 0, .max = 255, .track_w = 90 });
    }
}

fn panelBuildLayers(ctx: *gui.Context, user_data: *anyopaque) anyerror!void {
    const app: *App = @ptrCast(@alignCast(user_data));
    try buildLayerPanel(ctx, app);
}

fn panelBuildTimeline(ctx: *gui.Context, user_data: *anyopaque) anyerror!void {
    const app: *App = @ptrCast(@alignCast(user_data));
    try buildTimelinePanel(ctx, app);
}

/// Build the UI tree (widget sync hit-tests also run here)
fn buildUi(ctx: *gui.Context, app: *App, canvas_rect: ?core.Rect) !void {
    // canvas_rect used to feed the status-bar cursor; that moved to drawStatusBarLive.
    // Keep the parameter for call-site compatibility and mark it unused.
    _ = canvas_rect;
    // On selection/load-change frames, re-sync edit HSV from the current color (then keep in-edit HSV)
    app.syncEditHsv();
    // When the Color panel is hidden there is no HSV widget, so applyEditColor is never called from a callback.
    // Prevent pen/brush.color from staying stale after Pal Load etc. change current.
    if (!app.isPanelVisible(PanelNames.color)) app.applyEditColor();

    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 4, 4, 4, 4 },
        .gap = 4,
    });

    // ── Row 1: menu bar (File/Edit/View from Command defs) ──
    // When native is active, skip the GUI-fallback row and leave it to the OS menu bar.
    if (!app.native_menu_active) {
        ctx.beginBox(.{
            .direction = .row,
            .width = .{ .grow = 1 },
            .padding = .{ 4, 4, 4, 4 },
            .gap = 5,
            .bg = gui.Color.rgba(0x28, 0x28, 0x30, 0xFF),
        });
        app.rebuildMenuCommands();
        gui.menuBar(ctx, app.menuCommandsSlice(), &app.menu_bar_state);
        ctx.endBox();
    } else {
        app.rebuildMenuCommands();
    }

    // Update the Tool Options heading for the current tool (Panel.title; stable name unchanged)
    app.syncToolOptionsTitle();

    // ── PanelHost: left/center/right/bottom (center is an empty box; canvas blit uses centerRect) ──
    try app.panel_host.build(ctx);

    // Brush/Fill UI state → tools (clamp every frame. Keep values synced even when Tool Options is hidden)
    app.brush.size = @intCast(std.math.clamp(app.brush_size_i32, 1, 64));
    app.brush.opacity = @intCast(std.math.clamp(app.brush_opacity_i32, 0, 255));
    app.brush.hardness_q = @intFromFloat(std.math.clamp(app.brush_hardness_f32, 0, 1) * 255 + 0.5);
    app.fill.tolerance = @intCast(std.math.clamp(app.fill_tolerance_i32, 0, 255));

    // ── status bar (cursor → zoom → layer → frame → saveMsg) ──
    // cursor/zoom would be stale before updateViewport, so buildUi only places layout placeholders
    // (fixed-width box + explicit ID); live text is drawn after endFrame and updateViewport by
    // drawStatusBarLive (same low-level direct draw style as drawAppshellOverlay).
    ctx.beginBox(.{
        .direction = .row,
        .width = .{ .grow = 1 },
        .padding = .{ 2, 6, 2, 6 },
        .gap = 16,
        .bg = STATUS_BAR_BG,
    });
    const arena = ctx.allocator();
    const ink_h = gui.fontInkHeight(ctx.font);
    // Reserve max display width (4-digit coords; zoom up to 3200%. Live text overwrites later).
    const cursor_slot_w: i32 = @intCast(ctx.font.measure("cursor: (9999, 9999)"));
    const zoom_slot_w: i32 = @intCast(ctx.font.measure("zoom: 3200%"));
    ctx.beginBox(.{
        .id = STATUS_CURSOR_ID,
        .width = .{ .fixed = cursor_slot_w },
        .height = .{ .fixed = ink_h },
    });
    ctx.endBox();
    ctx.beginBox(.{
        .id = STATUS_ZOOM_ID,
        .width = .{ .fixed = zoom_slot_w },
        .height = .{ .fixed = ink_h },
    });
    ctx.endBox();
    // Zoom slider: read view_zoom fresh every frame (one-frame-stale only relative to a wheel/key
    // zoom this same frame, same as every other model-bound slider here e.g. brush size — the
    // model write for those happens in updateViewport, after this buildUi call). Only ever
    // produces an integer zoom (1..32); shrink stages (1/2..1/4) show as 1 and stay reachable only
    // via wheel/keys, matching the "snap to integer stages" contract.
    var zoom_i32: i32 = app.view_zoom.toInteger() orelse 1;
    if (ctx.sliderI32Id(STATUS_ZOOM_SLIDER_ID, "Zoom", &zoom_i32, .{ .min = 1, .max = @intCast(Zoom.max_integer), .track_w = 80 })) {
        app.zoomInPlace(Zoom.fromInteger(zoom_i32));
    }
    ctx.labelEx(
        try std.fmt.allocPrint(arena, "layer: {d}/{d}", .{ app.canvas.selected_layer + 1, app.canvas.layers.items.len }),
        ctx.style.text_subtle,
    );
    ctx.labelEx(
        try std.fmt.allocPrint(arena, "frame: {d}/{d}", .{ app.doc.selected_frame + 1, app.doc.frames.items.len }),
        ctx.style.text_subtle,
    );
    if (app.saveMsg()) |msg| ctx.label(msg);
    ctx.endBox();

    // ── Size dialog (end of root = laid out after normal UI = on top) ──
    // absolute is unsupported, so instead of stacking dim+panel in a canvas-sized grow box,
    // place a full-width modal band at the end of root and center the panel (simultaneous display with the
    // confirmation overlay is guarded in openSizeDialog).
    if (app.size_dialog) |dlg| {
        ctx.beginBox(.{
            .direction = .column,
            .width = .{ .grow = 1 },
            .padding = .{ 24, 24, 24, 24 },
            .gap = 12,
            .align_cross = .center,
            .bg = gui.Color.rgba(0x10, 0x12, 0x18, 0xE0),
            .border = .{ .color = gui.Color.rgba(0xFF, 0xD0, 0x80, 0xFF), .thickness = 2 },
        });
        const title: []const u8 = switch (dlg.mode) {
            .new_size => "New Canvas Size",
            .resize => "Resize Canvas",
        };
        ctx.label(title);
        ctx.beginBox(.{ .direction = .row, .gap = 8, .align_cross = .center });
        ctx.label("W");
        _ = ctx.textInputId(SIZE_DIALOG_W_ID, &dlg.width_buf, .{
            .width = .{ .fixed = 100 },
            .max_len = 10,
            .placeholder = "width",
        });
        ctx.label("H");
        _ = ctx.textInputId(SIZE_DIALOG_H_ID, &dlg.height_buf, .{
            .width = .{ .fixed = 100 },
            .max_len = 10,
            .placeholder = "height",
        });
        ctx.endBox();
        if (dlg.errorMsg()) |err| {
            ctx.labelEx(err, gui.Color.rgba(0xFF, 0x80, 0x80, 0xFF));
        }
        ctx.beginBox(.{ .direction = .row, .gap = 12 });
        if (ctx.buttonId(SIZE_DIALOG_OK_ID, "OK", .{ .min_w = 72 }).clicked) {
            app.confirmSizeDialog();
        }
        if (ctx.buttonId(SIZE_DIALOG_CANCEL_ID, "Cancel", .{ .min_w = 72 }).clicked) {
            app.closeSizeDialog();
        }
        ctx.endBox();
        ctx.endBox();
    }

    ctx.endBox(); // root
}

fn wasmLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = message_level;
    _ = scope;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, format, args) catch return;
    const env = struct {
        extern "env" fn kngn_log(ptr: [*]const u8, len: u32) void;
    };
    env.kngn_log(msg.ptr, @intCast(msg.len));
}

fn wasmPanic(msg: []const u8, _: ?usize) noreturn {
    const env = struct {
        extern "env" fn kngn_log(ptr: [*]const u8, len: u32) void;
    };
    env.kngn_log(msg.ptr, @intCast(@min(msg.len, std.math.maxInt(u32))));
    @trap();
}

pub const std_options: std.Options = if (builtin.cpu.arch.isWasm())
    .{ .logFn = wasmLogFn }
else
    .{};

pub const panic = if (builtin.cpu.arch.isWasm())
    std.debug.FullPanic(wasmPanic)
else
    std.debug.FullPanic(std.debug.defaultPanic);

/// Clears the active document's autosave file, skipped on wasm (no directory-capable
/// filesystem; there is never a file to clear there).
fn clearAutosave(app: *App) !void {
    if (comptime appshell_dir_supported) try app.autosave.clear();
}

/// Close the journal bound to the previous document, if any.
///
/// Detaching the composition layer first keeps it from holding a `Store` whose backing
/// `NativeStore` is about to be destroyed.
fn closeHistoryStore(app: *App) void {
    app.history_journal.setStore(null);
    app.history_restore = .{ .status = .no_store };
    if (app.history_store) |*store| {
        store.deinit();
        app.history_store = null;
    }
}

/// Bind the journal that belongs to `path`, replacing any journal already open.
///
/// Failing to open one is not an error the user needs to see: history simply is not
/// persisted for this document, and the editor behaves exactly as it did before.
fn bindHistoryStore(app: *App, path: []const u8) void {
    if (comptime !appshell_dir_supported) {
        closeHistoryStore(app);
        return;
    }
    const canonical = appshell.paths.normalizePath(app.io, app.gpa, path) catch {
        closeHistoryStore(app);
        return;
    };
    defer app.gpa.free(canonical);
    // Already bound to this document: keep it. Rebinding would discard the map of which Ops
    // are already in the journal, and every save would write them all again.
    if (app.history_store) |*open_store| {
        if (std.mem.eql(u8, open_store.documentPath(), canonical)) return;
    }
    closeHistoryStore(app);
    const file_name = (appshell.paths.historyFileName(app.io, app.gpa, path) catch return) orelse return;
    defer app.gpa.free(file_name);
    app.history_store = appshell.history_journal.NativeStore.openOrReset(
        app.gpa,
        app.io,
        app.history_dir,
        file_name,
        canonical,
    ) catch return;
    app.history_journal.setStore(app.history_store.?.store());
}

/// Persist the current history against the document bytes that were just written.
fn persistHistory(app: *App, doc_bytes: []const u8) void {
    const outcome = app.history_journal.save(
        &app.doc.undo,
        &app.cmd_log,
        &app.cmd_exec,
        history_persist.documentDigest(doc_bytes),
    ) catch |err| {
        std.log.warn("pixie: history journal save failed: {s}", .{@errorName(err)});
        return;
    };
    if (outcome.dropped_by_budget > 0) {
        app.setSaveMsg("History: {d} older steps exceeded the size budget", .{outcome.dropped_by_budget});
    }
}

/// Restore the history recorded for the document bytes that were just loaded.
///
/// Any mismatch — a document saved by another editor, an edited file, a journal from a
/// different document — leaves the freshly loaded document with no history, which is the
/// same state a file that never had a journal starts in.
fn restoreHistory(app: *App, doc_bytes: []const u8) void {
    app.history_restore = app.history_journal.load(
        &app.doc.undo,
        &app.cmd_log,
        &app.cmd_exec,
        history_persist.documentDigest(doc_bytes),
    );
    if (app.history_restore.status == .restored) {
        app.last_seen_handle = app.doc.undo.next_handle;
        app.markHistoryDirty();
    }
}

fn hostNewDocument(ctx: *anyopaque) !void {
    const app: *App = @ptrCast(@alignCast(ctx));
    closeHistoryStore(app);
    if (app.pending_png_path) |path| {
        app.doOpenPath(path) catch |err| return err;
        app.gpa.free(path);
        app.pending_png_path = null;
        try app.setProjectPath(null);
        try clearAutosave(app);
        try app.autosave.setPath(null);
        return;
    }
    if (app.pending_new_size) |sz| {
        app.pending_new_size = null;
        try app.doNew(sz.w, sz.h);
    } else {
        app.resetCanvasToSingleLayer();
    }
    if (app.current_path) |old| app.gpa.free(old);
    app.current_path = null;
    try app.setProjectPath(null);
    try clearAutosave(app);
    try app.autosave.setPath(null);
}

fn hostOpenDocument(ctx: *anyopaque, path: []const u8) !void {
    const app: *App = @ptrCast(@alignCast(ctx));
    try loadProjectPath(app, path);
    try app.recent.push(path);
    try clearAutosave(app);
    try app.autosave.setPath(path);
}

fn hostSaveDocument(ctx: *anyopaque, path: []const u8) !void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.syncPaletteToDoc();
    const bytes = try core.document_io.encodeDocument(&app.doc, app.gpa);
    defer app.gpa.free(bytes);
    try appshell.file_safety.writeAtomic(app.io, path, bytes, .{ .backup = true });
    // Only after the document is on disk: an index must never claim to describe a save
    // that did not happen.
    bindHistoryStore(app, path);
    persistHistory(app, bytes);
    try app.recent.push(path);
    try clearAutosave(app);
    try app.autosave.setPath(path);
    try app.setProjectPath(path);
}

fn loadProjectPath(app: *App, path: []const u8) !void {
    if (app.editingBlocked()) return error.EditingBlocked;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .unlimited);
    defer app.gpa.free(bytes);
    const sz = try core.document_io.peekCanvasSize(bytes);
    try actions.validateCanvasSize(sz.w, sz.h);
    var new_doc = try core.document_io.decodeDocument(bytes, app.gpa);
    errdefer new_doc.deinit();
    try actions.validateCanvasSize(new_doc.width, new_doc.height);
    const preserved_next_handle = app.doc.undo.next_handle;
    app.doc.deinit();
    app.doc = new_doc;
    new_doc = undefined;
    app.doc.undo.next_handle = preserved_next_handle;
    app.invalidateHistoryAfterDocReset();
    app.doc.resyncActiveView(app.gpa);
    app.canvas = app.doc.activeCanvas();
    try app.rebuildRuntimeForDocSize();
    app.clampTimelineTarget();
    app.applySystemFont();
    app.canvas.clearSelection();
    app.sel_in.discardFloat(app.gpa);
    app.loadPaletteFromDoc();
    app.syncPreviewCanvas();
    try app.setProjectPath(path);
    bindHistoryStore(app, path);
    restoreHistory(app, bytes);
}

/// Draw status-bar zoom%/cursor directly with post-updateViewport values.
/// Call after endFrame and after canvas_rect recompute. getNodeRect sees the latest layout (endFrame done).
/// draw_list.text does not own the string, so dupe the payload into the frame arena
/// (valid until the next beginFrame arena.reset; same contract as labelEx).
fn drawStatusBarLive(ctx: *gui.Context, app: *const App, canvas_rect: ?core.Rect) !void {
    const col = ctx.style.text_subtle;
    const arena = ctx.allocator();
    if (ctx.getNodeRect(STATUS_CURSOR_ID)) |r| {
        var buf: [64]u8 = undefined;
        const raw: []const u8 = blk: {
            if (canvas_rect) |rect| {
                if (zoom_mod.screenToCanvas(
                    .{ .x = ctx.input.mouse_pos.x, .y = ctx.input.mouse_pos.y },
                    rect,
                    app.view_zoom,
                )) |cp| {
                    break :blk std.fmt.bufPrint(&buf, "cursor: ({d}, {d})", .{ cp.x, cp.y }) catch "cursor: -";
                }
            }
            break :blk "cursor: -";
        };
        const txt = try arena.dupe(u8, raw);
        try ctx.draw_list.rectFilled(r, STATUS_BAR_BG);
        try ctx.draw_list.text(.{ .x = r.x, .y = r.y }, txt, col);
    }
    if (ctx.getNodeRect(STATUS_ZOOM_ID)) |r| {
        var buf: [32]u8 = undefined;
        const raw = std.fmt.bufPrint(&buf, "zoom: {d}%", .{app.view_zoom.pct()}) catch "zoom: ?%";
        const txt = try arena.dupe(u8, raw);
        try ctx.draw_list.rectFilled(r, STATUS_BAR_BG);
        try ctx.draw_list.text(.{ .x = r.x, .y = r.y }, txt, col);
    }
}

fn drawAppshellOverlay(ctx: *gui.Context, app: *const App) !void {
    if (app.recovery != null) {
        try ctx.draw_list.rectFilled(.{ .x = 75, .y = 420, .w = 460, .h = 120 }, gui.Color.rgba(0x20, 0x24, 0x30, 0xF8));
        try ctx.draw_list.rectOutline(.{ .x = 75, .y = 420, .w = 460, .h = 120 }, gui.Color.rgba(0xFF, 0xD0, 0x80, 0xFF), 2);
        try ctx.draw_list.text(.{ .x = 100, .y = 438 }, "Recover autosaved changes?", gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
        try ctx.draw_list.rectFilled(.{ .x = 100, .y = 480, .w = 110, .h = 30 }, gui.Color.rgba(0x40, 0x80, 0xC0, 0xFF));
        try ctx.draw_list.rectFilled(.{ .x = 245, .y = 480, .w = 110, .h = 30 }, gui.Color.rgba(0x80, 0x60, 0x40, 0xFF));
        try ctx.draw_list.text(.{ .x = 120, .y = 489 }, "Recover", gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
        try ctx.draw_list.text(.{ .x = 262, .y = 489 }, "Discard", gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
        return;
    }
    if (app.host.confirmation() != .none) {
        try ctx.draw_list.rectFilled(.{ .x = 75, .y = 420, .w = 460, .h = 120 }, gui.Color.rgba(0x20, 0x24, 0x30, 0xF8));
        try ctx.draw_list.rectOutline(.{ .x = 75, .y = 420, .w = 460, .h = 120 }, gui.Color.rgba(0xFF, 0xD0, 0x80, 0xFF), 2);
        try ctx.draw_list.text(.{ .x = 100, .y = 438 }, "Unsaved changes", gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
        try ctx.draw_list.text(.{ .x = 100, .y = 458 }, "Save before continuing?", gui.Color.rgba(0xC0, 0xC8, 0xD8, 0xFF));
        try ctx.draw_list.rectFilled(.{ .x = 100, .y = 480, .w = 110, .h = 30 }, gui.Color.rgba(0x40, 0x80, 0xC0, 0xFF));
        try ctx.draw_list.rectFilled(.{ .x = 245, .y = 480, .w = 110, .h = 30 }, gui.Color.rgba(0x80, 0x60, 0x40, 0xFF));
        try ctx.draw_list.rectFilled(.{ .x = 390, .y = 480, .w = 110, .h = 30 }, gui.Color.rgba(0x50, 0x58, 0x68, 0xFF));
        try ctx.draw_list.text(.{ .x = 120, .y = 489 }, "Save", gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
        try ctx.draw_list.text(.{ .x = 262, .y = 489 }, "Discard", gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
        try ctx.draw_list.text(.{ .x = 410, .y = 489 }, "Cancel", gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
    }
}

fn finishHostResult(app: *App, result: appshell.document_host.Result) void {
    switch (result) {
        .applied, .allowed, .canceled => {},
        else => return,
    }
    if (result == .canceled and app.pending_png_path != null) {
        app.gpa.free(app.pending_png_path.?);
        app.pending_png_path = null;
        app.png_import_pending = false;
    }
    if (result == .canceled) app.pending_new_size = null;
    app.syncProjectState();
    if (app.png_import_pending and result == .applied) {
        app.png_import_pending = false;
        app.markProjectDirty();
    }
    if (result == .allowed) app.running = false;
}

fn recoverAutosave(app: *App) !void {
    const candidate = &(app.recovery orelse return error.NoRecoveryPending);
    var decoded = try core.document_io.decodeDocument(candidate.envelope.snapshot, app.gpa);
    errdefer decoded.deinit();
    try actions.validateCanvasSize(decoded.width, decoded.height);
    try app.host.adoptRecovered(candidate.envelope.original_path);
    // Unreachable on wasm (recovery scanning is skipped there, so app.recovery is always null
    // and the early return above already fires); guarded anyway since app.autosave.dir is
    // uninitialized on wasm.
    if (comptime appshell_dir_supported) {
        try appshell.autosave.discardCandidate(app.io, app.autosave.dir, candidate.file_name);
    }
    closeHistoryStore(app);
    app.doc.deinit();
    app.doc = decoded;
    decoded = undefined;
    app.invalidateHistoryAfterDocReset();
    app.doc.resyncActiveView(app.gpa);
    app.canvas = app.doc.activeCanvas();
    try app.rebuildRuntimeForDocSize();
    app.clampTimelineTarget();
    app.applySystemFont();
    app.canvas.clearSelection();
    app.sel_in.discardFloat(app.gpa);
    app.loadPaletteFromDoc();
    app.syncPreviewCanvas();
    candidate.deinit();
    app.recovery = null;
    app.syncProjectState();
    app.markProjectDirty();
}

fn discardRecovery(app: *App) !void {
    const candidate = &(app.recovery orelse return error.NoRecoveryPending);
    // Unreachable on wasm; see the matching comment in recoverAutosave.
    if (comptime appshell_dir_supported) {
        try appshell.autosave.discardCandidate(app.io, app.autosave.dir, candidate.file_name);
    }
    candidate.deinit();
    app.recovery = null;
    app.refreshTitle();
}

fn snapshotProject(ctx: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.syncPaletteToDoc();
    app.doc.commitActiveLayerToCel(app.gpa, app.doc.selected_layer);
    return core.document_io.encodeDocument(&app.doc, allocator);
}

fn appInit(gpa: std.mem.Allocator, io: std.Io) !*App {
    const self = try gpa.create(App);
    errdefer gpa.destroy(self);

    // Stage fallible resources before the literal + errdefer (restore the pre-change main pattern of ctx-first defer,
    // and give doc/recorder/preview/palette/onion at least the same guarantee. The literal only moves).
    // GuiFont has a self-referential pointer, so load in-place after the literal.
    var ctx = gui.Context.init(gpa, gui.default_font);
    errdefer ctx.deinit();

    var doc = try core.Document.init(gpa, DEFAULT_CANVAS_W, DEFAULT_CANVAS_H);
    errdefer doc.deinit();

    var recorder = try core.StrokeRecorder.init(gpa, DEFAULT_CANVAS_W, DEFAULT_CANVAS_H);
    errdefer recorder.deinit(gpa);

    var preview_canvas = try core.Canvas.init(gpa, DEFAULT_CANVAS_W, DEFAULT_CANVAS_H);
    errdefer preview_canvas.deinit();

    var preview_rec = try core.StrokeRecorder.init(gpa, DEFAULT_CANVAS_W, DEFAULT_CANVAS_H);
    errdefer preview_rec.deinit(gpa);

    var palette = try palette_mod.Palette.initDb16(gpa);
    errdefer palette.deinit(gpa);

    const canvas_pixel_count = @as(usize, DEFAULT_CANVAS_W) * @as(usize, DEFAULT_CANVAS_H);
    const onion_buf = try gpa.alloc(u32, canvas_pixel_count);
    errdefer gpa.free(onion_buf);
    const onion_scratch = try gpa.alloc(u32, canvas_pixel_count);
    errdefer gpa.free(onion_scratch);

    // KNGN_APPSHELL_DIR is a native-only development override; wasm has no process env to read.
    const override_path = if (comptime !appshell_dir_supported)
        null
    else if (std.c.getenv("KNGN_APPSHELL_DIR")) |value|
        std.mem.span(value)
    else
        null;
    // On wasm data_dir/autosave_dir stay undefined and are never touched (no directory-capable
    // filesystem there; see `appshell_dir_supported`). recent/autosave/recovery still exist so the
    // in-memory parts of their API (setPath, markDirty, items(), push) keep working for the session.
    //
    // Every errdefer below stays a single statement directly in this function's top-level scope
    // (an if/else *expression* picks the value, never an if *statement* wrapping the errdefer), so
    // it guards every later fallible step in appInit. An errdefer's reach ends at the closing
    // brace of the block it is written in, so nesting it inside a conditional block here would
    // silently stop covering failures below that block.
    var data_dir: std.Io.Dir = if (comptime appshell_dir_supported)
        try appshell.paths.openAppDataDir(io, gpa, "pixie", override_path)
    else
        undefined;
    errdefer if (comptime appshell_dir_supported) data_dir.close(io);
    var autosave_dir: std.Io.Dir = if (comptime appshell_dir_supported)
        try appshell.paths.openAutosaveDir(io, data_dir)
    else
        undefined;
    errdefer if (comptime appshell_dir_supported) autosave_dir.close(io);
    var history_dir: std.Io.Dir = if (comptime appshell_dir_supported)
        try appshell.paths.openHistoryDir(io, data_dir)
    else
        undefined;
    errdefer if (comptime appshell_dir_supported) history_dir.close(io);
    // Amortised housekeeping: bounded per launch, and a failure never blocks startup.
    if (comptime appshell_dir_supported) {
        const now = std.Io.Clock.now(.real, io);
        _ = appshell.history_journal.maintain(
            gpa,
            io,
            history_dir,
            @divFloor(now.nanoseconds, std.time.ns_per_s),
            .{},
        ) catch |err| std.log.warn("pixie: history journal sweep failed: {s}", .{@errorName(err)});
    }
    var recent = appshell.recent_files.RecentFiles.init(gpa, 10);
    errdefer recent.deinit();
    if (comptime appshell_dir_supported) {
        _ = try recent.load(io, data_dir, "recent_files.ash");
        _ = try recent.pruneMissing(io, std.Io.Dir.cwd());
    }
    var autosave_controller: appshell.autosave.Controller = if (comptime appshell_dir_supported)
        try appshell.autosave.Controller.init(gpa, io, autosave_dir, null)
    else
        try appshell.autosave.Controller.init(gpa, io, undefined, null);
    errdefer autosave_controller.deinit();
    var recovery: ?appshell.autosave.Candidate = if (comptime appshell_dir_supported)
        try appshell.autosave.scan(gpa, io, autosave_dir)
    else
        null;
    errdefer if (recovery) |*candidate| candidate.deinit();

    var size_w_buf = try gui.TextBuffer.init(gpa, "");
    errdefer size_w_buf.deinit();
    var size_h_buf = try gui.TextBuffer.init(gpa, "");
    errdefer size_h_buf.deinit();

    // From here on, infallible (ownership moves into App. On success return the errdefers above do not fire)
    self.* = .{
        .io = io,
        .gpa = gpa,
        .ctx = ctx,
        .doc = doc,
        .recorder = recorder,
        .preview_canvas = preview_canvas,
        .preview_rec = preview_rec,
        .palette = palette,
        .pen = .{ .color = 0 },
        .brush = .{ .color = 0 },
        .fill = .{ .color = 0 },
        .onion_buf = onion_buf,
        .onion_scratch = onion_scratch,
        .data_dir = data_dir,
        .autosave_dir = autosave_dir,
        .history_dir = history_dir,
        .history_journal = .{ .gpa = gpa },
        .recent = recent,
        .autosave = autosave_controller,
        .recovery = recovery,
        .preferences = appshell.preferences.Preferences.init(gpa),
        .panels = .{
            .{ .name = PanelNames.history, .slot = .left, .build = panelBuildHistory, .user_data = undefined },
            .{ .name = PanelNames.color, .slot = .right, .build = panelBuildColor, .user_data = undefined },
            // Default closed: room for Color + Tool Options controls and one Layers row to coexist at 780x600
            .{ .name = PanelNames.palette, .slot = .right, .open = false, .build = panelBuildPalette, .user_data = undefined },
            .{ .name = PanelNames.tool_options, .slot = .right, .build = panelBuildToolOptions, .user_data = undefined },
            .{ .name = PanelNames.layers, .slot = .right, .build = panelBuildLayers, .user_data = undefined },
            .{ .name = PanelNames.timeline, .slot = .bottom, .visible = false, .build = panelBuildTimeline, .user_data = undefined },
        },
        .panel_host = undefined,
        .size_dialog_storage = .{
            .mode = .resize,
            .width_buf = size_w_buf,
            .height_buf = size_h_buf,
        },
        .size_dialog = null,
    };
    errdefer self.preferences.deinit();

    // After App is finally placed, load GuiFont in-place → re-point ctx.font (self-ref lifetime).
    self.gui_font.load(io, gpa);
    errdefer self.gui_font.deinit();
    self.ctx.font = self.gui_font.asFont();

    if (comptime appshell_dir_supported) {
        _ = self.preferences.load(io, data_dir, "preferences.ash") catch |err| {
            std.log.err("pixie: preferences load failed: {s}", .{@errorName(err)});
        };
    }

    self.panel_host = try gui.PanelHost.init(self.panels[0..], .{
        .left = .{ .extent = LEFT_PANE_DEFAULT, .min_extent = LEFT_PANE_MIN, .max_extent = 800 },
        .right = .{ .extent = RIGHT_PANE_DEFAULT, .min_extent = RIGHT_PANE_MIN, .max_extent = 800, .scrollable = true },
        .bottom = .{ .extent = BOTTOM_PANE_DEFAULT, .min_extent = BOTTOM_PANE_MIN, .max_extent = 600 },
        .splitter_thickness = SPLITTER_T,
        .min_center_width = CANVAS_MIN,
        .min_center_height = CANVAS_MIN,
    });
    for (&self.panels) |*p| p.user_data = self;
    self.panel_host.restore(self.panelPersistence());

    self.host = appshell.document_host.DocumentHost.init(gpa, .{
        .ctx = self,
        .newDocument = hostNewDocument,
        .openDocument = hostOpenDocument,
        .saveDocument = hostSaveDocument,
    });

    self.canvas = self.doc.activeCanvas();
    self.applySystemFont();
    self.pen.color = self.palette.current();
    self.brush.color = self.palette.current();
    self.fill.color = self.palette.current();
    self.minimap = minimap_mod.MiniMapCache.init(gpa);

    self.cmd_exec = platform.command.Executor.init(.{ .ctx = self, .run = dispatchPixieAction });
    self.cmd_exec.log = &self.cmd_log;
    self.cmd_exec.adapter = .{ .ctx = self, .canUndo = adapterCanUndo, .applyUndo = adapterApplyUndo, .summarize = adapterSummarize };
    platform.setCommandExecutor(&self.cmd_exec);
    // history thumbnail capture after remote COMMIT apply (opaque hook).
    platform.setNetsyncPostApplyHook(self, App.netsyncPostApplyHook);

    platform.registerProbe(.{ .name = "canvas", .ctx = self, .ext = "png", .snapshot = canvasSnapshot, .digest = canvasDigest });
    platform.registerProbe(.{ .name = "drawlist", .ctx = self, .ext = "txt", .snapshot = drawlistSnapshot, .digest = drawlistDigest, .desc = "DrawList structure: per-kind counts + stable hash + offclip count (raw dump via snapshot)" });
    platform.registerProbe(.{ .name = "undo", .ctx = self, .ext = "json", .snapshot = undoSnapshot, .digest = undoDigest });
    platform.registerProbe(.{ .name = "tool", .ctx = self, .ext = "txt", .snapshot = toolSnapshot, .digest = toolDigest });
    platform.registerProbe(.{ .name = "cursor", .ctx = self, .ext = "txt", .snapshot = cursorSnapshot, .digest = cursorDigest });
    platform.registerProbe(.{ .name = "history", .ctx = self, .ext = "json", .snapshot = historySnapshot, .digest = historyDigest });
    platform.registerProbe(.{ .name = "diff", .ctx = self, .ext = "txt", .digest = diffDigest, .desc = "visual diff vs marked baseline: changed/bbox/from/to" });
    // timeline playback state (digest only; snapshot=null)
    platform.registerProbe(.{ .name = "timeline", .ctx = self, .ext = "txt", .digest = timelineDigest, .desc = "timeline playback: playing/frame/frames/fps/dur/layers/onion" });
    platform.registerProbe(.{ .name = "panels", .ctx = self, .ext = "txt", .digest = panelsDigest, .desc = "right-slot panel rects: fb_h/bottom/ok/RightSlot + Color/Palette/Tool/Layers y,h" });
    platform.registerProbe(.{ .name = "palette", .ctx = self, .ext = "txt", .digest = paletteDigest, .desc = "palette size + canvas color histogram top4" });
    platform.registerProbe(.{ .name = "menu", .ctx = self, .ext = "txt", .digest = menuDigest, .desc = "menu open/items/enabled/checked/pending_file_op" });
    platform.registerProbe(.{ .name = "appshell", .ctx = self, .ext = "txt", .digest = appshellDigest, .desc = "pixie appshell dirty/recent/recovery/modal/autosave/title/geometry state", .input_blocker = pixieInputBlocker });
    platform.registerProbe(.{ .name = "presence", .ctx = self, .ext = "txt", .digest = presenceDigest, .desc = "ephemeral presence overlay: count/point/highlight/suggest + per-peer coords" });
    registerActions(self);
    registerStateSync(self);
    return self;
}

fn appDeinit(self: *App) void {
    const gpa = self.gpa;
    // Clear the hook before App teardown (same shape as the Executor teardown contract).
    platform.setNetsyncPostApplyHook(null, null);
    self.relay_chunks.deinit(gpa);
    if (self.native_menu_active) {
        if (self.os_window) |win| win.destroyMenu();
        self.native_menu_active = false;
        self.native_menu_registered = false;
    }
    // Wasm has no directory-capable filesystem (see `appshell_dir_supported`), so none of
    // recent/autosave/data_dir/autosave_dir is opened; skip every save/close on it.
    if (comptime appshell_dir_supported) {
        if (self.recovery == null and !self.host.isDirty()) {
            self.autosave.clear() catch |err| std.log.err("pixie: autosave clear failed: {s}", .{@errorName(err)});
        }
        self.recent.save(self.io, self.data_dir, "recent_files.ash") catch |err| std.log.err("pixie: recent save failed: {s}", .{@errorName(err)});
    }
    if (self.pending_png_path) |p| gpa.free(p);
    self.host.deinit();
    if (self.recovery) |*candidate| candidate.deinit();
    self.autosave.deinit();
    self.recent.deinit();
    self.preferences.deinit();
    closeHistoryStore(self);
    self.history_journal.deinit();
    if (comptime appshell_dir_supported) {
        self.history_dir.close(self.io);
        self.autosave_dir.close(self.io);
        self.data_dir.close(self.io);
    }
    if (self.current_path) |p| gpa.free(p);
    if (self.current_project_path) |p| gpa.free(p);
    if (self.palette_path) |p| gpa.free(p);
    if (self.clipboard) |*cb| cb.deinit(gpa);
    if (self.diff_base) |b| gpa.free(b);
    self.minimap.deinit();
    self.size_dialog = null;
    self.size_dialog_storage.width_buf.deinit();
    self.size_dialog_storage.height_buf.deinit();
    self.sel_in.deinit(gpa);
    self.bezier_editor.deinit(gpa);
    self.preview_rec.deinit(gpa);
    self.preview_canvas.deinit();
    self.palette.deinit(gpa);
    gpa.free(self.onion_buf);
    gpa.free(self.onion_scratch);
    self.recorder.deinit(gpa);
    self.doc.deinit();
    self.ctx.deinit();
    self.gui_font.deinit();
    gpa.destroy(self);
}

/// Frame body shared by the live-resize redraw callback and the normal frame path.
/// Does not include modal dialogs (runPendingFileOp) — contract: do not open dialogs from the callback.
fn appFrameInner(self: *App, win: *platform.Window) !void {
    // in_frame guard: defer clears it even on early / error return.
    if (self.in_frame) return;
    self.in_frame = true;
    defer self.in_frame = false;
    // Close frame work in an inner block and unlock the framebuffer when leaving that block.
    // File dialogs (modal) are unsafe to call while locked (re-entrancy), so only set pending here
    // and run at the post-unlock safe point (runPendingFileOp below).
    {
        const fb = win.lockFramebuffer() orelse return;
        defer fb.unlock();

        // Layout/input use logical size; raw fb is physical. Use only the scale from the same Framebuffer snapshot.
        const logical_w = fb.logical_size.width;
        const logical_h = fb.logical_size.height;
        const content_scale = fb.content_scale;
        // Physical target size (fb.width/height alias framebuffer_size)
        const phys_w = fb.width;
        const phys_h = fb.height;

        self.ctx.beginFrame(logical_w, logical_h);

        // Refresh the Command table before event handling (shortcut matching / probes; checked state).
        self.rebuildMenuCommands();
        self.syncNativeMenu(win);

        while (win.nextEvent()) |ev| {
            if (self.recovery != null or self.host.confirmation() != .none) {
                switch (ev) {
                    .mouse_down => |m| self.handleConfirmationClick(m.x, m.y),
                    .key_down => |k| if (k.key == .ESCAPE) finishHostResult(self, self.host.confirmCancel()),
                    .quit => win.cancelQuit(),
                    else => {},
                }
                continue;
            }
            switch (ev) {
                .quit => self.requestClose(win), // Window close uses the same path
                // While inline layer-name edit or text-layer content edit
                // (`text_in`; symmetric with rename_in; never both active) is in progress,
                // route key_down to the dedicated handlers and append committed chars from char_input
                // (first consumer of char_input). Always pass key_up through (so Space-pan modifiers etc. are not
                // dropped from held state during edit).
                // During size_dialog: do not run shortcuts; Esc=cancel / Enter=OK.
                .key_down => |k| if (self.rename_in.active)
                    self.handleRenameKey(k)
                else if (self.text_in.active)
                    self.handleTextEditKey(k)
                else if (self.size_dialog != null) {
                    if (k.key == .ESCAPE) self.closeSizeDialog() else if (k.key == .ENTER or k.key == .KP_ENTER) self.confirmSizeDialog();
                } else self.handleKey(k),
                .key_up => |k| self.handleKeyUp(k),
                .char_input => |c| if (self.rename_in.active)
                    self.rename_in.appendCodepoint(c.codepoint)
                else if (self.text_in.active)
                    self.text_in.appendCodepoint(c.codepoint),
                .composition_changed => self.composition_dirty = true,
                .menu_command => |id| self.dispatchCommand(id),
                .file_drop => |drop| self.handleFileDrop(drop),
                else => {},
            }
            // While renaming/text-editing, also stop forwarding mouse/key events to gui (avoid interference from
            // clicking other rows etc. rename_in/text_in are not discarded here, so a right-click on another row that
            // starts a new edit simply overwrites — no crash).
            // During size_dialog, pass char_input to GUI; Enter/Esc were already consumed above so do not re-send.
            if (!self.rename_in.active and !self.text_in.active) {
                const pass_char = self.size_dialog != null;
                const skip_dialog_confirm_keys = if (self.size_dialog != null) switch (ev) {
                    .key_down => |k| k.key == .ESCAPE or k.key == .ENTER or k.key == .KP_ENTER,
                    else => false,
                } else false;
                if (!skip_dialog_confirm_keys) {
                    if (toGuiEventEx(ev, pass_char)) |ge| self.ctx.pushEvent(ge);
                }
            }
        }

        self.syncComposition(win);

        // canvas rect is the previous frame's layout result (null on the first frame).
        // canvasBlitRect clamps the camera origin to the current area, writes it back into app, and updates last_area.
        var canvas_rect = canvasBlitRect(&self.ctx, self);

        self.tickTimelinePlayback(platform.getTime());

        try buildUi(&self.ctx, self, canvas_rect);
        self.ctx.endFrame();
        self.cachePanelsProbe();
        // After endFrame has finalized GUI draw commands, append so the confirmation UI sits on top.
        try drawAppshellOverlay(&self.ctx, self);

        // GUI-fallback dropdown (post-endFrame contract; same shape as popup.zig).
        // Skip when native is active (OS menu bar owns it).
        if (!self.native_menu_active) {
            const menu_res = gui.menuBarPopup(&self.ctx, self.menuCommandsSlice(), &self.menu_bar_state);
            if (menu_res.selected) |id| self.dispatchCommand(id);
            // Reflect checked immediately after a View toggle (for same-frame probes)
            if (menu_res.selected != null) self.rebuildMenuCommands();
        } else {
            // When View toggles etc. change checked, updateMenu via the dirty-gate
            self.rebuildMenuCommands();
            self.syncNativeMenu(win);
        }

        // Pass keyDown to IME only while text edit (body input or layer-name rename) is active.
        // When inactive, unmodified keys still reach tools/shortcuts even if IME is enabled.
        win.setTextInputActive(self.text_in.active or self.rename_in.active);

        // IME candidate-window caret anchor. Supply here because the rect cache is finalized after endFrame.
        // Do not gate on preedit presence: IME may decide the window position during the composition-start
        // key's handleEvent (before the app supplies a new rect), so keep pointing at a caret for the whole
        // time the input UI is active (avoids first-show offset from a stale rect).
        if (self.text_in.active or self.rename_in.active) {
            const caret_text = if (self.text_in.active)
                self.text_in.text()
            else if (self.rename_in.active)
                self.rename_in.text()
            else
                "";
            const caret_x_offset: i32 = @intCast(self.ctx.font.measure(caret_text));
            const caret_id = if (self.text_in.active)
                TEXT_EDIT_BOX_ID
            else if (self.rename_in.active)
                layerWidgetId(self.rename_in.layer_idx, LAYER_ROW_PART_IME)
            else
                0;
            if (caret_id != 0) if (self.ctx.getNodeRect(caret_id)) |r| {
                const rect = CompositionCaretRect{
                    .x = r.x + 4 + caret_x_offset,
                    .y = r.y + 2,
                    .w = 1,
                    .h = @intCast(gui.fontInkHeight(self.ctx.font)),
                };
                if (self.composition_rect == null or
                    self.composition_rect.?.x != rect.x or
                    self.composition_rect.?.y != rect.y or
                    self.composition_rect.?.w != rect.w or
                    self.composition_rect.?.h != rect.h)
                {
                    win.setCompositionRect(rect.x, rect.y, rect.w, rect.h);
                    self.composition_rect = rect;
                }
            };
        }

        // ── Minimap input (before updateViewport; exclusive with normal pan/stroke) ──
        const minimap_busy = if (self.size_dialog != null) false else updateMinimapInput(self, &self.ctx);
        // ── Viewport: wheel zoom (zoom-to-cursor) / pan (Space+left / middle / Cmd+left) ──
        // While panning, suppress draw input (pan does not start while capturing, so existing strokes can finish).
        // Also stop viewport ops during size_dialog.
        const panning = if (self.size_dialog != null or minimap_busy) false else updateViewport(self, &self.ctx);
        // zoom/pan may have changed, so recompute rect so this frame's input/draw do not mix
        // "old rect + new zoom" (post-endFrame, so area is this frame's layout. O(1)).
        canvas_rect = canvasBlitRect(&self.ctx, self);
        // Overwrite status-bar zoom%/cursor with the new zoom/pan (do not use the stale buildUi values).
        try drawStatusBarLive(&self.ctx, self, canvas_rect);

        // ── canvas input. capturing first (finish existing strokes). bezier is a separate path ──
        // While the selected layer is text kind, stop this whole branch (bezier/select/
        // eyedropper/normal canvas_input alike). Preserves the invariant that
        // "text-layer pixels are the re-rasterize result of text_params" (eyedropper is
        // read-only and harmless in principle, but blocking the whole branch is the simpler design
        // choice over adding a special case; color picking is temporarily unavailable while a text layer is selected).
        // Same block when size_dialog != null.
        if (!panning and !minimap_busy and !self.selectedLayerIsText() and self.size_dialog == null) {
            const in = &self.ctx.input;
            // New-stroke start gate: allow a new start only when press is inside the canvas area(last_area) and gui
            // (widget/splitter) did not take the press (!wantsMouse). In-progress strokes drop pressed_left only,
            // still run update, and deliver release so they finish (prevents stuck capturing).
            // Presses on the minimap rect were already consumed by updateMinimapInput; exclude them here as a safety net too.
            const pressed_left_gated = in.mouse_pressed.left and gate: {
                const p = in.mouse_pressed_pos;
                const in_area = if (self.last_area) |a|
                    (p.x >= a.x and p.y >= a.y and p.x < a.x + a.w and p.y < a.y + a.h)
                else
                    false;
                const on_minimap = if (self.last_area) |a|
                    if (currentMinimapRect(self, a)) |mm| minimap_mod.contains(mm, p.x, p.y) else false
                else
                    false;
                // active_id==0 = no widget/splitter took the press (hover-only wantsMouse does not
                // suppress = a canvas press that moves onto UI in the same frame can still start a stroke).
                // !hasOpenPopup() = do not start a new stroke while the layer context menu is open
                // (popup keeps active_id at 0, so the condition above alone cannot stop it.
                // Same reason popup.zig's wantsMouse() ORs popup_state).
                break :gate in_area and !on_minimap and self.ctx.state.active_id == 0 and !self.ctx.hasOpenPopup();
            };
            if (self.active_kind == .bezier and !self.input.capturing) {
                const frame: bezier_input.BezierInput.Frame = .{
                    .canvas_rect = canvas_rect,
                    .zoom = self.view_zoom,
                    .mouse_pos = .{ .x = in.mouse_pos.x, .y = in.mouse_pos.y },
                    .mouse_pressed_pos = .{ .x = in.mouse_pressed_pos.x, .y = in.mouse_pressed_pos.y },
                    .mouse_released_pos = .{ .x = in.mouse_released_pos.x, .y = in.mouse_released_pos.y },
                    .pressed_left = pressed_left_gated,
                    .released_left = in.mouse_released.left,
                    .time = platform.getTime(),
                };
                self.syncRecorderModes();
                const dab = self.brush.footprint();
                if (self.bez_in.update(frame, &self.bezier_editor, self.canvas, &self.recorder, self.gpa, dab, self.brush.color, self.brush.opacity)) |pd| {
                    self.doc.pushPaintOp(self.gpa, pd.layer_idx, pd.diffs) catch {}; // This branch is unreachable while a text layer is selected
                }
            } else if (self.active_kind.isShape() and !self.input.capturing) {
                // Shape (separate path). press→drag→release commits the shape.
                const frame: shape_input.ShapeInput.Frame = .{
                    .canvas_rect = canvas_rect,
                    .zoom = self.view_zoom,
                    .mouse_pos = .{ .x = in.mouse_pos.x, .y = in.mouse_pos.y },
                    .mouse_pressed_pos = .{ .x = in.mouse_pressed_pos.x, .y = in.mouse_pressed_pos.y },
                    .mouse_released_pos = .{ .x = in.mouse_released_pos.x, .y = in.mouse_released_pos.y },
                    .pressed_left = pressed_left_gated,
                    .released_left = in.mouse_released.left,
                };
                self.syncRecorderModes();
                // shape_in.kind / fill are already synced by UI / setActiveKind
                if (self.shape_in.update(frame, self.canvas, &self.recorder, self.gpa, self.palette.current())) |pd| {
                    switch (actions.uiPaintCommitPath(platform.netsyncActive(), true)) {
                        .relay => {
                            // netsync: rewind preview → re-apply via action shape
                            self.rewindPaintDiff(pd);
                            self.relayUiShape();
                        },
                        .rewind_discard => {
                            self.rewindPaintDiff(pd);
                        },
                        .solo => {
                            const handle_before = self.doc.undo.next_handle;
                            self.doc.pushPaintOp(self.gpa, pd.layer_idx, pd.diffs) catch {};
                            self.recordUiShape(self.doc.undo.next_handle != handle_before);
                        },
                    }
                }
            } else if (self.active_kind == .select and !self.input.capturing) {
                const frame: selection_input.SelectionInput.Frame = .{
                    .canvas_rect = canvas_rect,
                    .zoom = self.view_zoom,
                    .mouse_pos = .{ .x = in.mouse_pos.x, .y = in.mouse_pos.y },
                    .mouse_pressed_pos = .{ .x = in.mouse_pressed_pos.x, .y = in.mouse_pressed_pos.y },
                    .mouse_released_pos = .{ .x = in.mouse_released_pos.x, .y = in.mouse_released_pos.y },
                    .pressed_left = pressed_left_gated,
                    .released_left = in.mouse_released.left,
                };
                if (self.sel_in.update(frame, self.canvas, self.canvas.selected_layer, self.gpa, self.blend_mode)) |pd| {
                    self.doc.pushPaintOp(self.gpa, pd.layer_idx, pd.diffs) catch {}; // This branch is unreachable while a text layer is selected
                }
            } else if (self.eye_in.picking or self.active_kind == .eyedropper or
                (pressed_left_gated and in.modifiers.alt))
            {
                // Eyedropper (separate path). While the dedicated tool is selected, or finish an in-progress pick,
                // or temporary Alt+click eyedrop (bezier/select already branched above, so
                // active_kind here is one of pen/eraser/brush/fill/eyedropper. Minimal case split that enables
                // Alt+click uniformly for all four tools).
                const frame: eyedropper_input.EyedropperInput.Frame = .{
                    .canvas_rect = canvas_rect,
                    .zoom = self.view_zoom,
                    .mouse_pos = .{ .x = in.mouse_pos.x, .y = in.mouse_pos.y },
                    .mouse_pressed_pos = .{ .x = in.mouse_pressed_pos.x, .y = in.mouse_pressed_pos.y },
                    .pressed_left = pressed_left_gated,
                    .released_left = in.mouse_released.left,
                };
                if (self.eye_in.update(frame)) |cp| {
                    self.pickColor(cp.x, cp.y);
                }
            } else {
                const frame: canvas_input.CanvasInput.Frame = .{
                    .canvas_rect = canvas_rect,
                    .zoom = self.view_zoom,
                    .mouse_pos = .{ .x = in.mouse_pos.x, .y = in.mouse_pos.y },
                    .mouse_pressed_pos = .{ .x = in.mouse_pressed_pos.x, .y = in.mouse_pressed_pos.y },
                    .mouse_released_pos = .{ .x = in.mouse_released_pos.x, .y = in.mouse_released_pos.y },
                    .pressed_left = pressed_left_gated,
                    .released_left = in.mouse_released.left,
                };
                const was_capturing = self.input.capturing;
                self.syncRecorderModes();
                const pd_opt = self.input.update(frame, self.activeTool(), self.canvas, &self.recorder, self.gpa);
                // ── UI stroke point tracking (same coord transform as canvas_input down/move/up) ──
                if (canvas_rect) |rect| {
                    if (pd_opt != null) {
                        // Commit on release (same-frame press+release starts from begin; up uses released_pos)
                        if (!was_capturing) self.uiStrokeBegin(zoom_mod.screenToCanvasRaw(frame.mouse_pressed_pos, rect, frame.zoom));
                        self.uiStrokeAppend(zoom_mod.screenToCanvasRaw(frame.mouse_released_pos, rect, frame.zoom));
                    } else if (!was_capturing and self.input.capturing) {
                        // Start capture (down=pressed_pos + same-frame move=mouse_pos)
                        self.uiStrokeBegin(zoom_mod.screenToCanvasRaw(frame.mouse_pressed_pos, rect, frame.zoom));
                        self.uiStrokeAppend(zoom_mod.screenToCanvasRaw(frame.mouse_pos, rect, frame.zoom));
                    } else if (self.input.capturing) {
                        self.uiStrokeAppend(zoom_mod.screenToCanvasRaw(frame.mouse_pos, rect, frame.zoom));
                    }
                }
                if (pd_opt) |pd| {
                    // During netsync: rewind preview → routeAction("stroke").
                    // fill etc. (no action vocabulary) discard the rewind (prevent silent diverge).
                    // solo keeps pushPaintOp + recordUiStroke as before.
                    switch (actions.uiPaintCommitPath(platform.netsyncActive(), self.uiStrokeRelaysViaAction())) {
                        .relay => {
                            // After every chunk is canonically accepted, rewind once then send all PROPOSEs synchronously.
                            // No cross-frame drain (structurally avoids dropping unsent chunks across consecutive strokes).
                            var canons: std.ArrayListUnmanaged([]u8) = .empty;
                            defer {
                                for (canons.items) |a| self.gpa.free(a);
                                canons.deinit(self.gpa);
                            }
                            if (self.relayBuildCanonicalChunks(&canons)) {
                                self.rewindPaintDiff(pd);
                                self.relay_stroke = false;
                                self.relay_active_len = 0;
                                self.ui_stroke_len = 0;
                                self.ui_stroke_overflow = false;
                                self.relaySendCanonicalChunks(canons.items);
                            } else {
                                // preflight failure (chunk count > pending cap=netsyncPendingCap, or
                                // pending saturated): **rewind** the preview so we do not diverge from the host.
                                // The stroke itself is lost, but that is safer than a silent canvas diverge (unsent
                                // ghost pixels remaining only on this peer, not undoable, permanent mismatch).
                                self.rewindPaintDiff(pd);
                                self.relayResetCapture();
                                self.relay_stroke = false;
                                self.setSaveMsg("netsync: stroke too long to relay (dropped)", .{});
                            }
                        },
                        .rewind_discard => {
                            self.rewindPaintDiff(pd);
                            self.uiStrokeDiscard();
                            std.debug.print("pixie: netsync: fill etc. unavailable (no action vocabulary — discarding preview)\n", .{});
                            self.setSaveMsg("netsync: fill unavailable (no action)", .{});
                        },
                        .solo => {
                            const handle_before = self.doc.undo.next_handle;
                            self.doc.pushPaintOp(self.gpa, pd.layer_idx, pd.diffs) catch {}; // This branch is unreachable while a text layer is selected
                            // On commit points, record a CommandRecord (actor=local_user. undo_ref = handle of the pushed Op)
                            self.recordUiStroke(self.doc.undo.next_handle != handle_before);
                        },
                    }
                } else if (!self.input.capturing) {
                    self.uiStrokeDiscard(); // Released but no committed diff → discard the accumulated points
                }
            }
        }

        // ── Soft-overlay hover tracking + OS cursor-shape M1 wiring.
        // Placed after input dispatch so a newly started stroke this frame correctly updates the busy check
        // (isPointerBusy) and the draw path does not flash a footprint ring.
        updateCursorAndHover(self, win.*, &self.ctx, canvas_rect);

        // ── Draw: bg → checker → canvas blit (α src-over) → GUI (on top) ──
        // Clear the physical fb. canvas is logical Zoom rect → physical nearest.
        // `fill32`, not `@memset`: the four bytes of COLOR_WINDOW_BG differ, and this is the
        // largest single write of the frame at a HiDPI physical size.
        pixelops.fill32(fb.pixels, COLOR_WINDOW_BG);
        if (canvas_rect) |rect| {
            if (self.last_area) |area| {
                const zoom = self.view_zoom;
                const cw = self.doc.width;
                const ch = self.doc.height;
                // Logical display rect (displayExtent = ceil(canvas * num / den))
                const screen_rect: core.Rect = .{
                    .x = rect.x,
                    .y = rect.y,
                    .w = zoom.displayExtent(cw),
                    .h = zoom.displayExtent(ch),
                };
                blit.drawCheckerboardPhysical(fb.pixels, phys_w, phys_h, screen_rect, area, content_scale);
                const base_composite = self.resolveDisplayComposite(self.gpa);
                const display_composite: []const u32 = if (self.onion_enabled and self.doc.frames.items.len > 1) blk: {
                    const cnt = @min(self.onion_count, core.onion_skin.max_count);
                    core.onion_skin.build(&self.doc, base_composite, self.doc.selected_frame, cnt, self.onion_buf, self.onion_scratch);
                    break :blk self.onion_buf;
                } else base_composite;
                self.loupe_source_composite = display_composite;
                blit.blitCanvasZoomPhysical(fb.pixels, phys_w, phys_h, display_composite, cw, ch, rect, zoom, area, content_scale);
                // Minimap (right after canvas blit; below other overlays)
                drawMinimapOverlay(self, fb.pixels, phys_w, phys_h, area, content_scale);
            }
        }
        // Pixel grid overlay (view-only; draw_list-based, so it paints on top of the raw-pixel
        // canvas/minimap regardless of call order relative to those, same as every other overlay below).
        if (self.grid_enabled) {
            if (canvas_rect) |rect| if (self.last_area) |area| {
                const clip_area: gui.Rect = .{ .x = area.x, .y = area.y, .w = @intCast(area.w), .h = @intCast(area.h) };
                grid_overlay.draw(&self.ctx, rect, self.view_zoom, clip_area);
            };
        }
        // presence overlay (right after canvas blit; below bezier/selection)
        drawPresenceOverlay(self, canvas_rect);
        // Bezier edit handles/anchors into draw_list (above preview; burned by gui.render; clip to area)
        if (self.active_kind == .bezier) {
            if (canvas_rect) |rect| if (self.last_area) |area| {
                const clip_area: gui.Rect = .{ .x = area.x, .y = area.y, .w = @intCast(area.w), .h = @intCast(area.h) };
                bezier_overlay.draw(&self.ctx, &self.bezier_editor, rect, self.view_zoom, clip_area);
            };
        }
        // Selection marching ants (always when a selection exists; select-tool drag prefers the live preview)
        {
            const display_sel: ?core.Rect = if (self.active_kind == .select)
                (self.sel_in.previewRect(self.canvas) orelse self.canvas.selection)
            else
                self.canvas.selection;
            if (display_sel != null) {
                if (canvas_rect) |rect| if (self.last_area) |area| {
                    const clip_area: gui.Rect = .{ .x = area.x, .y = area.y, .w = @intCast(area.w), .h = @intCast(area.h) };
                    // phase is time-derived. mod by MARCH_PERIOD(=2*DASH) to avoid i32 overflow (pattern preserved).
                    const phase: i32 = @intFromFloat(@mod(platform.getTime() * MARCH_SPEED, MARCH_PERIOD));
                    selection_overlay.draw(&self.ctx, display_sel, rect, self.view_zoom, clip_area, phase);
                };
            }
        }
        // Outline preview while dragging a shape
        if (self.active_kind.isShape() and self.shape_in.state == .dragging) {
            if (canvas_rect) |rect| if (self.last_area) |area| {
                const clip_area: gui.Rect = .{ .x = area.x, .y = area.y, .w = @intCast(area.w), .h = @intCast(area.h) };
                shape_overlay.draw(&self.ctx, &self.shape_in, rect, self.view_zoom, clip_area);
            };
        }
        // Tool glyph + brush footprint outline ring (soft overlay, topmost).
        // hover_screen is Some only when "in_canvas and not busy" (see updateCursorAndHover), so
        // stroke / selection-drag / bezier-drag / pan never reach here.
        if (self.hover_screen) |hs| {
            if (self.last_area) |area| {
                const clip_area: gui.Rect = .{ .x = area.x, .y = area.y, .w = @intCast(area.w), .h = @intCast(area.h) };
                const glyph = self.active_kind.glyph();
                cursor_overlay.drawGlyph(&self.ctx, .{ .x = hs.x, .y = hs.y }, glyph.label, glyph.color, clip_area);
                if (self.active_kind == .brush) {
                    if (self.hover_cell) |hc| if (canvas_rect) |rect| {
                        self.brush_edges.refresh(&self.brush);
                        cursor_overlay.drawRing(&self.ctx, &self.brush_edges, hc, rect, self.view_zoom, clip_area, RING_COLOR_A, RING_COLOR_B);
                    };
                }
            }
        }
        // Loupe (magnifier), topmost tool overlay (drawn after cursor/brush-ring so it sits above
        // them; only the layer context-menu popup below draws on top of it). Both hover_screen and
        // hover_cell are null outside the canvas and during any busy state (pan/stroke/drag), so
        // this is automatically hidden then, with no extra gating needed.
        if (self.loupe_enabled) {
            if (self.hover_screen) |hs| if (self.hover_cell) |hc| if (self.last_area) |area| {
                const clip_area: gui.Rect = .{ .x = area.x, .y = area.y, .w = @intCast(area.w), .h = @intCast(area.h) };
                loupe_overlay.draw(&self.ctx, hs, hc, self.loupe_source_composite, self.doc.width, self.doc.height, clip_area);
            };
        }
        // Layer right-click context menu. popup.zig's post-endFrame contract
        // + calling after other overlays (bezier/selection/cursor) puts it on top.
        // Unconditional every-frame calls are fine (returns immediately as a no-op when the target popup is closed;
        // see popup.zig's doc comment). items are derived each time from the current selected_layer
        // (doSelectLayer already ran on right-click, so every later item acts on selected_layer).
        {
            const sel_is_text = self.selectedLayerIsText();
            const items = [_]gui.PopupItem{
                .{ .label = "Add Layer" },
                .{ .label = "Add Text Layer" }, // text-layer path
                .{ .label = "Delete Layer", .enabled = self.canvas.layers.items.len > 1 },
                .{ .label = "Move Up", .enabled = self.canvas.selected_layer + 1 < self.canvas.layers.items.len },
                .{ .label = "Move Down", .enabled = self.canvas.selected_layer > 0 },
                .{ .label = if (self.canvas.layers.items[self.canvas.selected_layer].visible) "Hide" else "Show" },
                .{ .label = "Duplicate" },
                .{ .label = "Merge Down", .enabled = self.canvas.selected_layer > 0 and !sel_is_text and
                    self.canvas.layers.items[self.canvas.selected_layer - 1].kind != .text },
                .{ .label = "Rename..." }, // layer-name rename path
                .{ .label = "Edit Text...", .enabled = sel_is_text }, // text-layer path
                .{ .label = "Rasterize", .enabled = sel_is_text }, // text-layer path
            };
            const ctx_menu_result = self.ctx.popupMenu(LAYER_CTX_MENU_ID, &items);
            if (ctx_menu_result.selected) |sel| {
                const sel_idx = self.canvas.selected_layer;
                const synced = platform.netsyncActive();
                switch (sel) {
                    0 => {
                        if (synced) self.routeUi("add_layer", "") else _ = self.doAddLayer() catch {};
                    },
                    1 => self.doAddTextLayer() catch {}, // action not registered / not a relay target
                    2 => {
                        if (synced) self.routeUiLayerOp("delete_layer", sel_idx) else self.doDeleteLayer(sel_idx) catch {};
                    },
                    3 => {
                        if (synced) self.routeUiLayerMove(sel_idx, 1) else self.doMoveLayer(sel_idx, 1) catch {};
                    },
                    4 => {
                        if (synced) self.routeUiLayerMove(sel_idx, -1) else self.doMoveLayer(sel_idx, -1) catch {};
                    },
                    5 => {
                        if (synced)
                            self.routeUiLayerVisible(sel_idx, !self.canvas.layers.items[sel_idx].visible)
                        else
                            self.doToggleLayerVisible(sel_idx);
                    },
                    6 => {
                        if (synced) self.routeUiLayerOp("duplicate_layer", sel_idx) else _ = self.doDuplicateLayer(sel_idx) catch {};
                    },
                    7 => {
                        if (synced) self.routeUiLayerOp("merge_down", sel_idx) else self.doMergeDown(sel_idx) catch {};
                    },
                    8 => self.beginRenameLayer(sel_idx),
                    9 => self.beginTextEdit(sel_idx),
                    10 => self.doRasterizeLayer(sel_idx) catch {},
                    else => {},
                }
            }
        }
        // GUI DrawList stays in logical coords. Inject scale at the render exit.
        gui.render(
            .{ .pixels = fb.pixels, .width = phys_w, .height = phys_h },
            &self.ctx.draw_list,
            self.ctx.font,
            content_scale,
        );
        win.present();
    } // ← framebuffer unlock here
}

fn appFrame(self: *App, win: *platform.Window, now: f64) !bool {
    try appFrameInner(self, win);

    // Safe point: framebuffer unlocked and this frame's input update done. Open modals here.
    // Even if save/load is pending in the same frame as a quit request, do not open dialogs while quitting.
    if (self.running) self.runPendingFileOp();

    if (comptime appshell_dir_supported) {
        if (self.running and self.recovery == null and !platform.netsyncActive()) {
            _ = self.autosave.tick(now, self, snapshotProject) catch |err| self.setSaveMsg("Autosave failed: {s}", .{@errorName(err)});
        }
    }

    // End of frame: detect unrecorded undoable edits → expire redo-candidate epochs
    self.checkUnrecordedEdits();

    return self.running;
}

/// Live-resize redraw callback. Called from the backend during an OS modal loop to draw one frame.
/// Errors are logged and that frame is skipped (callback is void).
fn redrawCb(ctx_ptr: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx_ptr));
    var win = self.redraw_win orelse return;
    appFrameInner(self, &win) catch |e| std.log.err("redraw frame failed: {s}", .{@errorName(e)});
}

const Rt = app_runtime.Runtime(App);

pub fn enableWasmRuntime() void {
    Rt.enableWasmExports();
}

pub fn main(process_init: std.process.Init) !void {
    try Rt.runNative(process_init);
}
