//! Pixie MVP: libs/gui UI + Pen/Eraser/DB16 パレット/Undo/PNG 保存
//!
//! - レイアウト: menu bar / row(canvas, right pane) / timeline placeholder / status bar
//!   の 4 段 Flex（毎フレーム fb サイズから再フロー。リサイズ対応自体は TASK-23）
//! - canvas 入力: press 起点 capture（canvas_input.zig の状態機械）。stroke 中は GUI 上に
//!   逸れても継続（座標は clamp なし変換 + ピクセル側 clip）
//! - Tool / Undo: core の Tool(Pen/Eraser) / StrokeRecorder / UndoStack（TASK-21.7 で core 化）
//! - ファイル I/O: Cmd+S=保存(記憶パス) / Cmd+Shift+S=名前を付けて保存 / Cmd+O=開く（TASK-24）。
//!   ファイルダイアログは framebuffer lock 中に呼べない（再入の危険）ため、handleKey/ボタンは
//!   pending_file_op をセットするだけにし、フレーム末の安全点 runPendingFileOp() で実行する。
//! - キー: B=Pen / E=Eraser / C=全消去 / Cmd+Z=Undo / Cmd+Shift+Z=Redo
//!         ESC・Cmd+Q=終了（ウィンドウクローズ含め running=false の単一経路）

const std = @import("std");
const builtin = @import("builtin");
const kit = @import("kit"); // 公開 umbrella（ADR-007 R4/R5: apps は kit-only 消費者）
const platform = kit.platform;
const gui = kit.gui;
const recipe = kit.recipe;
const app_runtime = kit.app_runtime;
const appshell = kit.appshell;
const core = @import("paint");
const png = kit.png;
const fontmod = kit.font; // system font ランタイム読込（TASK-82。examples/12・21 と同じ消費方式）
const canvas_input = @import("canvas_input.zig");
const actions = @import("actions.zig");
const diff = @import("diff.zig");
const blit = @import("blit.zig");
const palette_mod = @import("palette.zig");
const bezier_input = @import("bezier_input.zig");
const bezier_overlay = @import("bezier_overlay.zig");
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

// レイヤー名の最大長は libs/paint（保存側）と pixie（編集バッファ側）で独立定義しているため
// （循環 import 回避。詳細は layer_rename_input.zig 冒頭）、乖離しないことを comptime で保証する。
comptime {
    if (core.layer_name_max != layer_rename_input.max_len) {
        @compileError("layer_name_max mismatch between paint.Canvas and layer_rename_input");
    }
}
// テキストレイヤー内容の最大長も同様に独立定義しているため乖離しないことを保証する（TASK-79.5）。
comptime {
    if (core.text_content_max != text_content_input.max_len) {
        @compileError("text_content_max mismatch between paint.Canvas and text_content_input");
    }
}
// brush size 上限も actions.zig（std のみ）と paint 側で独立定義しているため乖離を防ぐ（TASK-62.5.3）。
comptime {
    if (actions.MAX_BRUSH_SIZE != core.Brush.MAX_SIZE) {
        @compileError("MAX_BRUSH_SIZE mismatch between actions.zig and paint.Brush");
    }
}

const WINDOW_W: u32 = 780;
const WINDOW_H: u32 = 600;
/// 起動時既定キャンバスサイズ（実行時サイズは `doc.width` / `doc.height`）。
const DEFAULT_CANVAS_W: u32 = 256;
const DEFAULT_CANVAS_H: u32 = 256;
// ビューポート（TASK-39）: ズームは整数倍のランタイム値。既定 2x で従来の見た目を維持。
const ZOOM_MIN: i32 = 1;
const ZOOM_MAX: i32 = 32;
const ZOOM_DEFAULT: i32 = 2;

/// パンドラッグの開始入力種別（開始時に latch。Cmd が move に載らない backend でも完走させる）
const PanKind = enum { space_left, middle, cmd_left };
// 透明背景チェッカー（screen 固定セル。canonical BGRA 0xAARRGGBB）
// チェッカー定数の単一ソースは blit.zig（TASK-54 で移動）
const CHECKER_LIGHT = blit.CHECKER_LIGHT;
const CHECKER_DARK = blit.CHECKER_DARK;
// ペイン分割（TASK-42）: 右/下ペインのリサイズ + 表示非表示。pane は fixed px・canvas は grow。
const RIGHT_PANE_DEFAULT: i32 = 200;
const RIGHT_PANE_MIN: i32 = 120;
const BOTTOM_PANE_DEFAULT: i32 = 120;
const BOTTOM_PANE_MIN: i32 = 80;
const CANVAS_MIN: i32 = 120; // pane リサイズ時に canvas へ残す最小辺
const SPLITTER_T: i32 = 6; // 境界帯の太さ
const SAVE_MSG_DURATION: f64 = 3.0;
// 範囲選択のマーチングアンツ（TASK-44）。phase 速度（units/sec）と周期（=2*DASH。selection_overlay の DASH=4）。
const MARCH_SPEED: f64 = 12.0;
const MARCH_PERIOD: f64 = 8.0;

/// ファイル操作要求。framebuffer lock 中（フレーム処理中）に発生した要求を保持し、
/// unlock 後の安全点で 1 回だけ実行する（ダイアログのモーダルループ再入を避ける）。
const FileOp = enum { save, save_as, open, save_palette, load_palette, save_project, open_project, export_seq, export_sheet, confirm_save_as };

// ── File/Edit/View Command 定義（TASK-97.2）────────────────────────────────
// ID は stable。separator は INVALID_COMMAND_ID。GUI fallback / keyboard / menu_command が
// 同じ App.dispatchCommand へ到達する。
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
    pub const toggle_panel: platform.CommandId = 12;
    pub const toggle_timeline: platform.CommandId = 13;
};

/// TASK-144.2: New Size / Resize Canvas モーダル。TextBuffer は App 寿命で所有し、
/// `size_dialog != null` のときだけ表示（storage へのポインタ）。
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

const MENU_CMD_CAP = 40;
const RECENT_CMD_BASE: platform.CommandId = 100;

/// native menu dirty-gate 用（TASK-97.3）。
/// label / top_menu は全文 hash+len（prefix 切り捨てだと recent path の suffix 差を取りこぼす）。
/// shortcut は Optional の有無 + key/modifiers を保持する。
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

/// canvas 領域の明示 ID（getNodeRect での外部参照用。自動 ID は不可）
const CANVAS_AREA_ID: gui.Id = 0xC0FFEE01;
/// ペイン分割（TASK-42）の明示 ID。CONTENT_ROW=横分割の利用可能幅、MAIN_AREA=縦分割の利用可能高 の基準。
const CONTENT_ROW_ID: gui.Id = 0xC0FFEE02;
const MAIN_AREA_ID: gui.Id = 0xC0FFEE03;
const SPLIT_RIGHT_ID: gui.Id = 0xC0FFEE04;
const SPLIT_BOTTOM_ID: gui.Id = 0xC0FFEE05;
const RIGHT_SCROLL_ID: gui.Id = 0xC0FFEE06; // 右ペイン縦スクロール領域（TASK-46）
const LAYER_PANEL_ID_BASE: gui.Id = 0xA430_0000;
const LAYER_ROW_ID_BASE: gui.Id = 0xA430_1000;
const LAYER_PANEL_ID_STRIDE: gui.Id = 8;
/// レイヤー行の右クリックコンテキストメニュー（TASK-79.2）。popup primitive（TASK-79.1）の id。
const LAYER_CTX_MENU_ID: gui.Id = 0xA430_2000;
/// テキストレイヤー編集パネル（TASK-79.5）の明示 ID 群。
const TEXT_PANEL_ID_BASE: gui.Id = 0xA430_3000;
const TEXT_EDIT_BOX_ID: gui.Id = TEXT_PANEL_ID_BASE + 6;
/// レイヤー行 box 自身の明示 ID に使う `layerWidgetId` part（0..3 は既存: 0=選択ボタン/1=可視
/// トグル/2=opacity slider/3=サムネ）。右クリックのヒットテストは行全体の矩形を使う。
const LAYER_ROW_PART_ROW: gui.Id = 4;
const LAYER_ROW_PART_IME: gui.Id = 5;
/// 履歴パネル（TASK-83 Phase 1）の明示 ID 群。
const HISTORY_PANEL_ID_BASE: gui.Id = 0xA431_0000;
// レイヤーパネルのサムネイル（raw layer をチェッカー下地へ最近傍縮小・等倍 blit）
const LAYER_THUMB_W: i32 = 24;
const LAYER_THUMB_H: i32 = 24;
const LAYER_THUMB_CELL: usize = 4; // サムネ内チェッカーのセル px
/// タイムライン UI（TASK-45.2）
const TIMELINE_SCROLL_ID: gui.Id = 0xC0FFEE07;
const TIMELINE_PANEL_ID_BASE: gui.Id = 0xA440_0000;
const TIMELINE_HEADER_ID_BASE: gui.Id = 0xA441_0000;
const TIMELINE_CELL_ID_BASE: gui.Id = 0xA442_0000;
const TIMELINE_CELL_FRAME_STRIDE: gui.Id = 4096;
const TIMELINE_CELL_W: i32 = 24;
const TIMELINE_CELL_H: i32 = 24;
const TIMELINE_LABEL_W: i32 = 72;
const TIMELINE_LINK_BORDER = gui.Color.rgba(0x40, 0xA0, 0xE0, 0xFF);
const TIMELINE_PLAYHEAD_BORDER = gui.Color.rgba(0xE0, 0xC0, 0x40, 0xFF);

const COLOR_WINDOW_BG: u32 = 0xFF_24_20_20; // canonical BGRA: r=24,g=20,b=20（従来の見た目を維持）

/// canvas pixel（canonical BGRA 0xAARRGGBB）→ gui.Color（同一ビットレイアウト）。スウォッチ/プレビュー描画用。
fn guiColor(c: u32) gui.Color {
    return @bitCast(c);
}

/// 現在の描画ツール種別（UI 表示・選択ハイライト用。dispatch は core.Tool が担う）
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

    /// ソフトオーバーレイのツールバッジ（cursor_overlay.drawGlyph）用の2文字ラベル + 背景色
    /// （TASK-75.4）。label は全て string literal（DrawList.text の寿命契約を満たす）。
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

/// ブラシ footprint 輪郭リングの配色（selection_overlay の marching ants と同じ「偶奇で交互」流儀。
/// 任意の canvas 背景色に対するコントラストを確保する）。
const RING_COLOR_A = gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF); // 白
const RING_COLOR_B = gui.Color.rgba(0xC9, 0x7A, 0x20, 0xFF); // ブラシバッジと同系オレンジ

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
    dl.textEx(.{ .x = rect.x, .y = rect.y }, d.committed, d.color, d.font) catch @panic("composition text: OOM");
    dl.textEx(.{ .x = rect.x + committed_w, .y = rect.y }, d.preedit, d.preedit_color, d.font) catch @panic("composition preedit: OOM");
    const metrics = d.font.metrics();
    const start_x = rect.x + committed_w;
    // 下線は baseline 直下（ascent+2）。行ボックス最下端だと descent 下に浮く（実機指摘）。
    const underline_y = @min(rect.y + @as(i32, @intCast(metrics.ascent)) + 2, rect.y + @as(i32, @intCast(metrics.line_height)) - 1);
    dl.line(.{
        .x = start_x,
        .y = underline_y,
    }, .{
        .x = start_x + preedit_w,
        .y = underline_y,
    }, d.preedit_color, 1) catch @panic("composition underline: OOM");
    const cursor_prefix = d.preedit[0..@min(d.cursor, d.preedit.len)];
    const cursor_x = start_x + @as(i32, @intCast(d.font.measure(cursor_prefix)));
    dl.line(.{ .x = cursor_x, .y = rect.y + 2 }, .{
        .x = cursor_x,
        .y = rect.y + @as(i32, @intCast(metrics.line_height)) - 2,
    }, d.preedit_color, 1) catch @panic("composition caret: OOM");
}

/// platform.MouseButton → InputEvent の button index（0=left/1=right/2=middle）。
fn buttonToU8(b: platform.MouseButton) u8 {
    return switch (b) {
        .left => 0,
        .right => 1,
        .middle => 2,
        else => 0xFF,
    };
}

/// platform.Event → gui.InputEvent。GUI に関係しない quit は null。
/// key の負値（platform KeyCode.UNKNOWN = -1）は捨てる（libs/gui は u32 code 前提）。
/// `pass_char_input`: size_dialog 表示中のみ true（通常は char_input を GUI へ流さない）。
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
        .gamepad_connected, .gamepad_disconnected => null, // TASK-80.1: pixie 未消費（cross-cutting Event 追加。他機能は無改造）
        .composition_changed => null, // TASK-79.6.1: composition 未消費（inline preedit は 79.6.2）
        .menu_command => null, // TASK-97.2: App.dispatchCommand で消費（gui へは渡さない）
        .file_drop => null, // TASK-113.4: GUI へ転送しない
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

/// アプリ状態（イベント処理と UI 構築の両方から触る）
const App = struct {
    /// app_runtime が参照する初期ウィンドウ仕様（TASK-73.1）
    pub const window = .{ .w = WINDOW_W, .h = WINDOW_H, .title = "Pixie" };

    /// 起動前に window_state を load して WindowOptions を返す（TASK-117）。
    /// platform.init 後・Window.create 前。失敗時はデフォルト 780x600。
    pub fn windowBootstrap(gpa: std.mem.Allocator, io: std.Io) !platform.WindowOptions {
        const fallback_opts: platform.WindowOptions = .{
            .position = null,
            .size = .{ .width = WINDOW_W, .height = WINDOW_H },
        };
        const override_path = if (std.c.getenv("VP_APPSHELL_DIR")) |value| std.mem.span(value) else null;
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
    /// app_runtime が Window.create + App.init 直後に呼ぶ opt-in hook（TASK-23.1 統合）。
    /// ライブリサイズ redraw callback を登録する（harness/headless 時は facade 側で no-op）。
    pub fn onWindowReady(self: *App, win: *platform.Window) void {
        self.redraw_win = win.*;
        self.os_window = win;
        win.setRedrawCallback(self, redrawCb);
        // TASK-142: 起動直後は「テキスト編集フォーカス無し」を宣言（初回 pollEvents 前の keyDown が
        // 従来の route-always で IME に吸われる隙間を塞ぐ）。以後は毎フレーム編集状態に追従する。
        win.setTextInputActive(false);
        self.refreshTitle();
        // TASK-122: native メニュー（macOS native backend + enable_menu）。headless は false → GUI fallback のまま。
        self.rebuildMenuCommands();
        if (win.nativeMenuAvailable()) {
            self.native_menu_active = true;
            win.registerMenu(self.menuCommandsSlice());
            self.saveNativeMenuSnapshot();
            self.native_menu_registered = true;
        }
    }

    /// Window.destroy 前・App.deinit 前に呼ぶ（TASK-117）。geometry を window_state へ保存。
    /// size=0（facade の安全既定 / 取得失敗）は既存 state を温存するため保存スキップ。失敗は log のみ。
    pub fn onWindowShutdown(self: *App, win: *platform.Window) void {
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
    /// GUI コンテキスト（跨フレーム永続。wasm runtime 用に App へ寄せた。TASK-73.1）
    ctx: gui.Context,
    /// ドキュメント（frames × layers。MVP は 1 frame）。Canvas は heap 所有・ポインタ安定（TASK-63）。
    doc: core.Document,
    /// アクティブフレームの Canvas（doc.activeCanvas()）。既存参照の churn 最小化のため *Canvas を保持。
    canvas: *core.Canvas = undefined,
    /// system font（TASK-82）バイト列。所有は App（init で読込・deinit で解放）。
    /// 見つからない/parse 失敗/wasm では `null` のままで、`text_render` 側が embedded ASCII へフォールバック。
    system_font_bytes: ?[]u8 = null,
    recorder: core.StrokeRecorder,
    /// ベジェ編集中のブラシプレビュー用一時 canvas/recorder（本 layer のコピーへ非破壊描画）
    preview_canvas: core.Canvas,
    preview_rec: core.StrokeRecorder,
    // undo は独立フィールドを廃止し `doc.undo` を経由する（TASK-45.1。plan 8.3節）。
    pen: core.Pen,
    eraser: core.Eraser = .{},
    brush: core.Brush,
    /// 塗りつぶし（バケツ）ツール（TASK-76）。Pen/Eraser/Brush と同じく canvas_input 経由の
    /// down/move/up 契約に乗る（bezier/select のような独立経路は不要）。
    fill: core.Fill,
    input: canvas_input.CanvasInput = .{},
    /// ベジェ(ペン)ツール（独立経路。TASK-21.13）。状態機械 + マウス入力アダプタ。
    bezier_editor: core.PathEditor = .{},
    bez_in: bezier_input.BezierInput = .{},
    /// 範囲選択ツール（独立経路。TASK-44）。マーキー作成 / 選択範囲移動の状態機械。
    sel_in: selection_input.SelectionInput = .{},
    /// シェイプツール（独立経路。TASK-90）。Line/Rect/Ellipse の press→drag→release。
    shape_in: shape_input.ShapeInput = .{},
    /// ピクセルパーフェクト線（Pen size=1 のみ有効。StrokeRecorder へ反映。TASK-90）。
    pixel_perfect: bool = false,
    /// 対称描画（StrokeRecorder へ反映。Pen/Eraser/Brush/Shape 全部に効く。TASK-90）。
    symmetry: core.Symmetry = .off,
    /// スポイトツール（独立経路。TASK-68）。press-capture の最小状態機械（塗り操作が無いため
    /// Tool vtable / StrokeRecorder / Undo は不要）。専用ツール選択・Alt+クリック一時スポイトの両方で使う。
    eye_in: eyedropper_input.EyedropperInput = .{},
    /// clipboard（copy/cut で確保し paste で参照。gpa 所有・deinit で free）。
    clipboard: ?core.PixelBlock = null,
    /// 視覚差分の基準スナップショット（TASK-87。遅延 alloc・gpa 所有・deinit で free）。
    /// compositeStraight の借用スライスは保持せず、必ずコピーする。
    diff_base: ?[]u32 = null,
    /// paste/move のブロック配置方法（既定 over=透明を保持＝下の絵を残す）。右ペインのトグルで切替（TASK-44）。
    blend_mode: core.selection.Blend = .over,
    active_kind: ToolKind = .pen,
    /// ── ビューポート（TASK-153.1）。view_zoom は整数倍、cam_cx/cy は表示領域中心が指す連続キャンバス座標 ──
    view_zoom: i32 = ZOOM_DEFAULT,
    /// キャンバス左上端基準の連続キャンバス座標（表示領域中心がこの点を指す）。初期は文書中心。
    cam_cx: f32 = @as(f32, @floatFromInt(DEFAULT_CANVAS_W)) / 2.0,
    cam_cy: f32 = @as(f32, @floatFromInt(DEFAULT_CANVAS_H)) / 2.0,
    /// 直近フレームの canvas area rect（Fit ズーム計算用。canvasBlitRect が毎フレーム更新）
    last_area: ?core.Rect = null,
    /// Space 押下継続（key_down/up で更新）。Space+左ドラッグでパン
    space_down: bool = false,
    /// パンドラッグ進行中。開始時に anchor を latch（描画 capture とは排他）
    pan_active: bool = false,
    /// パン開始時の入力種別（Cmd が move に載らない backend でもドラッグを完走させる）
    pan_kind: PanKind = .space_left,
    pan_anchor_mouse: core.Vec2 = .{ .x = 0, .y = 0 },
    pan_anchor_cam_x: f32 = 0,
    pan_anchor_cam_y: f32 = 0,
    /// KP_ADD/KP_SUBTRACT の保留ズーム段数。updateViewport がカーソル位置で zoomAround 適用する。
    pending_zoom_delta: i32 = 0,
    /// ── ソフトオーバーレイ（ツールグリフ + ブラシ footprint 輪郭リング。TASK-75.4）──
    /// hover 中の生スクリーン座標（ツールバッジの錨点）。in_canvas かつ非 busy の時だけ Some
    /// （updateCursorAndHover が毎フレーム設定）。
    hover_screen: ?core.Vec2 = null,
    /// hover 中の canvas 画素座標（footprint リングの錨点）。`core.screenToCanvas` 経由（実 canvas
    /// 画素範囲外なら null）なので、レターボックス／canvas 外では自然にリングだけ非表示になる。
    hover_cell: ?core.Vec2 = null,
    /// 直近に OS へ要求した cursor shape（変化検出用 + `cursor` probe 公開用）。
    cursor_shape: platform.CursorShape = .default,
    /// Brush footprint 輪郭リングの縁セルキャッシュ（(size,hardness) 変化時のみ再計算）。
    brush_edges: brush_edge_cache.EdgeCache = .{},
    /// ephemeral プレゼンス状態（TASK-103。Document/CommandLog 非保持）。
    presence: actions.PresenceStore = .{},
    /// ── ペイン（TASK-42）。pane は fixed px・canvas は grow。幅/高さは毎フレーム利用可能領域へ clamp ──
    right_pane_w: i32 = RIGHT_PANE_DEFAULT,
    right_visible: bool = true,
    /// 右ペインの縦スクロール量（TASK-46。横は content_width=grow で不要）
    right_scroll: gui.Vec2f = .{},
    bottom_pane_h: i32 = BOTTOM_PANE_DEFAULT,
    bottom_visible: bool = false,
    /// タイムライン UI 状態（TASK-45.2）
    timeline_scroll: gui.Vec2f = .{},
    timeline_playing: bool = false,
    timeline_fps: f32 = 10.0,
    timeline_last_advance: f64 = 0,
    timeline_target_layer: usize = 0,
    timeline_target_frame: u32 = 0,
    /// オニオンスキン（TASK-45.3）。表示専用。
    onion_enabled: bool = false,
    onion_count: u32 = 1,
    onion_buf: []u32 = &.{},
    onion_scratch: []u32 = &.{},
    /// Brush パラメータの UI 状態（Slider の *i32/*f32 と Brush の u32/u8 の型差を吸収）。
    brush_size_i32: i32 = 8,
    brush_opacity_i32: i32 = 255,
    brush_hardness_f32: f32 = 1.0,
    /// Fill の色許容差 tolerance の UI 状態（Slider の *i32 と u8 の型差吸収。brush_size_i32 と同パターン）。
    fill_tolerance_i32: i32 = 0,
    /// 編集可能パレット（colors.len>=1）。描画色 = palette.current()。
    palette: palette_mod.Palette,
    /// 編集中 HSV 状態。選択切替/load 後のみ RGB→HSV で再同期（s==0 でも hue を失わない）。
    edit_h: f32 = 0,
    edit_s: f32 = 0,
    edit_v: f32 = 0,
    /// HSV を同期済みの selected。null/不一致なら再同期。
    edit_synced_for: ?usize = null,
    /// UI Repl 用: スウォッチ選択時点の色（applyEditColor で swatch が変わっても from を保持。TASK-89）。
    repl_source: ?u32 = null,
    running: bool = true,
    /// フレーム本体の再入ガード（TASK-23.1。redraw callback と main loop の二重実行防止）。
    in_frame: bool = false,
    /// redraw callback 用に onWindowReady で保持する Window 値コピー（TASK-23.1。FrameCtx 相当）。
    redraw_win: ?platform.Window = null,
    /// appshell title 更新用の借用 Window。runtime が window を所有する。
    os_window: ?*platform.Window = null,
    /// 現在の PNG 保存先（gpa 所有）。Cmd+S はここへ直接上書き、保存/読込ダイアログ成功時に更新。
    current_path: ?[]u8 = null,
    /// 現在の .pix プロジェクト保存先（gpa 所有。PNG の current_path とは別管理。TASK-63）。
    current_project_path: ?[]u8 = null,
    /// .pix の lifecycle は DocumentHost が正本。legacy field は既存 UI/action との同期用。
    host: appshell.document_host.DocumentHost = undefined,
    data_dir: std.Io.Dir = undefined,
    autosave_dir: std.Io.Dir = undefined,
    recent: appshell.recent_files.RecentFiles = undefined,
    autosave: appshell.autosave.Controller = undefined,
    recovery: ?appshell.autosave.Candidate = null,
    pending_png_path: ?[]u8 = null,
    png_import_pending: bool = false,
    /// `new W H` 確認フロー用（hostNewDocument が消費。TASK-144.1）。
    pending_new_size: ?struct { w: u32, h: u32 } = null,
    /// TASK-144.2: サイズダイアログ本体（TextBuffer は appInit/appDeinit で管理）。
    size_dialog_storage: SizeDialogState = undefined,
    /// null=閉じ。open 中は `&size_dialog_storage`（毎フレーム再生成しない）。
    size_dialog: ?*SizeDialogState = null,
    title_cache: [std.fs.max_path_bytes + 64]u8 = undefined,
    title_cache_len: usize = 0,
    /// パレットの .gpl 保存先（gpa 所有。PNG の current_path とは別管理）。
    palette_path: ?[]u8 = null,
    /// 安全点で実行する保留中のファイル操作（フレーム処理中にセット、unlock 後に消費）。
    pending_file_op: ?FileOp = null,
    /// digest menu の last_op キー用ラッチ（TASK-97.2）: 直近に dispatch された FileOp。
    /// 次の dispatch まで保持（情報提供のみ。真の未消費状態は pending キー = dialog_op/pending_file_op）。
    /// headless では runPendingFileOp が同フレームで消費するため、「メニュー選択が FileOp を
    /// 積んだ」ことは last_op で観測する。
    menu_pending_probe: ?FileOp = null,
    /// GUI fallback メニューバーの開閉（TASK-97.2）。
    menu_bar_state: gui.MenuBarState = .{},
    /// 毎フレーム再構築する Command 表（enabled/checked 反映。native updateMenu と同役割）。
    menu_commands: [MENU_CMD_CAP]platform.Command = undefined,
    menu_command_count: usize = 0,
    /// native メニューが有効か（onWindowReady で確定。headless/swift/metal は false）。
    native_menu_active: bool = false,
    /// native updateMenu dirty-gate 用スナップショット（enabled/checked/id/label）。
    native_menu_snap: [MENU_CMD_CAP]NativeMenuSnap = undefined,
    native_menu_snap_count: usize = 0,
    native_menu_registered: bool = false,
    /// wasm file picker 進行中の FileOp（TASK-73.3 修正1）。
    /// DialogPending のあいだはこの op だけを再試行し、待機中に pending_file_op へ積まれた別要求は破棄する
    /// （例: Cmd+O 待ち中の Cmd+Shift+S が picked path を誤って save_as に食わせない）。
    dialog_op: ?FileOp = null,
    save_msg_buf: [128]u8 = undefined,
    save_msg_len: usize = 0,
    save_msg_until: f64 = 0,
    /// レイヤー名インライン編集の状態機械（TASK-79.3）。`rename_in.active` が true の間、
    /// メインループのイベントポンプは char_input/ENTER/ESCAPE/BACKSPACE のみをここへ回し、
    /// 他のキー・gui への pushEvent は止める（タイプ中に B/E 等のツール切替が誤発火しないため）。
    rename_in: layer_rename_input.LayerRenameInput = .{},
    /// テキストレイヤー内容インライン編集の状態機械（TASK-79.5）。`rename_in` と対称
    /// （どちらか一方のみ active。`beginTextEdit`/`beginRenameLayer` が互いを明示的に cancel する）。
    text_in: text_content_input.TextContentInput = .{},
    /// IME preedit snapshot（latest-wins）。composition_changed を受けたフレームで更新する。
    preedit_buf: [1024]u8 = undefined,
    preedit_len: usize = 0,
    preedit_cursor: usize = 0,
    composition_dirty: bool = false,
    composition_rect: ?CompositionCaretRect = null,

    /// ── command model（TASK-62.5.3）。「誰が（local_user/local_agent）・何を実行したか」の単一 log ──
    /// 常時有効・固定容量（alloc なし）。transport の有無に依存しない（harness replay でも copilot
    /// でも通常起動でも同じ経路）。記録はイベント時のみ（ホットパス外）。
    cmd_log: platform.command.CommandLog = .{},
    /// dispatcher/log は main() で配線する（ctx に &app が要るため field default にできない）。
    cmd_exec: platform.command.Executor = undefined,
    /// recipe_replay 実行中フラグ（入れ子 `recipe_replay` 拒否用。TASK-62.5.8）。
    recipe_replaying: bool = false,
    /// UI stroke（canvas_input 経由）の点列蓄積（§5c。press〜release のイベント時 append・固定上限は
    /// actions.MAX_STROKE_POINTS を共有）。連続同一点は追加しない（同一点 move は描画上 no-op）。
    ui_stroke_pts: [actions.MAX_STROKE_POINTS]actions.Point = undefined,
    ui_stroke_len: usize = 0,
    /// 上限超過 → この stroke は記録しない（257 点以上を記録すると 62.5.4 の redo 再 dispatch が
    /// TooManyPoints で失敗するため。Op は legacy UndoStack に残り既存 undo UI では戻せる）。
    ui_stroke_overflow: bool = false,
    /// 未記録 undoable 編集の検出用（TASK-62.5.4 §2b）: 記録が起きた点（noteUndo/
    /// recordUiStroke/legacy redo）で `doc.undo.next_handle` に追従させ、フレーム末尾に
    /// `next_handle > last_seen_handle` なら「CommandLog に載らない undoable push があった」と
    /// 判定して `bumpEpoch(.local_user)` する（O(1) の整数比較 1 回/フレーム）。
    last_seen_handle: u64 = 1,
    /// 履歴パネル表示用キャッシュ（TASK-83。CommandLog 変異を跨いで保持しない契約のため
    /// dirty 時に全置換再構築。alloc なし・MAX_CMD_LOG 固定配列）。
    history_entries: [platform.command.MAX_CMD_LOG]history_summary.HistoryEntry = undefined,
    history_count: u32 = 0,
    history_dirty: bool = true,
    history_seen_seq: u64 = 1,
    /// 履歴行サムネイル固定リング（TASK-83.2。イベント時のみ生成・フレーム毎は blit のみ）。
    history_thumbs: [platform.command.MAX_CMD_LOG][history_thumbnail.THUMB_PIXELS]u32 = undefined,
    history_thumb_meta: [platform.command.MAX_CMD_LOG]history_thumbnail.HistoryThumbMeta = @splat(.{}),
    /// capture 開始時に latch した実効パラメータ（canonical args の材料。§5c'）。
    ui_stroke_layer_id: u64 = 1,
    ui_stroke_tool: ToolKind = .pen,
    ui_stroke_color: u32 = 0,
    ui_stroke_size: u32 = 4,
    ui_stroke_opacity: u8 = 255,
    ui_stroke_hardness: u8 = 255,

    /// 選択中レイヤーが text kind か（テキストレイヤーへの直接 raster 編集を防ぐガード。
    /// TASK-79.5）。text layer の pixels は「TextParams からの再ラスタライズ結果」という
    /// 不変条件（libs/paint/src/canvas.zig の `TextParams` doc comment 参照）を守るため、
    /// Pen/Eraser/Brush/Fill/Bezier/選択操作（cut/paste/move）の書き込み経路はこれで弾く
    /// （Rasterize 確定後=kind が raster 化した後は通常どおり描画できる）。
    fn selectedLayerIsText(self: *const App) bool {
        return self.canvas.selected_layer < self.canvas.layers.items.len and
            self.canvas.layers.items[self.canvas.selected_layer].kind == .text;
    }

    /// `system_font_bytes`（TASK-82）を `doc.active_view` へ反映する。新しい Document
    /// インスタンス（`core.Document.init`/`document_io.loadDocument` が返す）は
    /// `active_view.system_font` が既定 `null` で始まるため、Document を新規作成/差し替えた直後は
    /// 必ず呼ぶ必要がある（`main()` 起動時 + `doOpenProject`）。`preview_canvas` は
    /// `addTextLayer`/`setLayerTextParams` を一切呼ばないため対象外。イベント時/初期化時のみ
    /// （フレーム毎には呼ばない）。**TASK-45.1**: セルグリッド化により「アクティブフレームの
    /// 編集可能ビュー」は `doc.active_view` の1個のみになった（`resyncActiveView` は
    /// `system_font` を一切触らないため、ここで一度設定すれば保持され続ける。plan 4.2節）。
    fn applySystemFont(self: *App) void {
        self.doc.active_view.system_font = self.system_font_bytes;
    }

    /// 現在 UI 選択中の Tool（fat-pointer。capture 開始時に canvas_input が latch する）
    fn activeTool(self: *App) core.Tool {
        return switch (self.active_kind) {
            .pen => self.pen.tool(),
            .eraser => self.eraser.tool(),
            .brush => self.brush.tool(),
            .bezier => self.pen.tool(), // bezier は独立経路で canvas_input を経由しない（到達しないフォールバック）
            .select => self.pen.tool(), // select も独立経路（到達しないフォールバック）
            .fill => self.fill.tool(),
            .eyedropper => self.pen.tool(), // eyedropper も独立経路（到達しないフォールバック。actionStroke で明示的に弾く）
            .line, .rect, .ellipse => self.pen.tool(), // shape も独立経路（到達しないフォールバック）
        };
    }

    /// StrokeRecorder に UI の pixel_perfect / symmetry を反映する（stroke/shape 開始前に呼ぶ）。
    /// pixel_perfect は Pen のみ（size=1 固定の現状 Pen）。
    fn syncRecorderModes(self: *App) void {
        self.recorder.pixel_perfect = self.pixel_perfect and self.active_kind == .pen;
        self.recorder.symmetry = self.symmetry;
    }

    /// ツール切替を一元化（active_kind への代入は全てここ経由）。
    /// capture / 選択ドラッグ / シェイプドラッグ / スポイト picking 中は切替しない（進行中操作を宙ぶらりんにしない）。
    /// .bezier から出る時は未確定パスを cancel。.select から出る時は進行中ドラッグを破棄（selection は保持）。
    /// シェイプから出る時は進行中ドラッグを cancel。
    fn setActiveKind(self: *App, next: ToolKind) void {
        if (self.input.capturing or self.sel_in.state != .idle or self.shape_in.state != .idle or self.eye_in.picking) return;
        if (self.active_kind == .bezier and next != .bezier) {
            self.bezier_editor.update(self.gpa, .cancel);
        }
        if (self.active_kind.isShape() and !next.isShape()) {
            self.shape_in.cancel();
        }
        if (next != .select) self.sel_in.discardFloat(self.gpa); // 選択ツールを離れる → フロート破棄（canvas は最終形のまま）
        // shape ツール種別を shape_in へ同期
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

    /// ズーム倍率を [ZOOM_MIN, ZOOM_MAX] に clamp し、カメラを文書中心へリセット（0/F 用）。
    fn setZoomCentered(self: *App, z: i32) void {
        self.view_zoom = std.math.clamp(z, ZOOM_MIN, ZOOM_MAX);
        self.cam_cx = @as(f32, @floatFromInt(self.doc.width)) / 2.0;
        self.cam_cy = @as(f32, @floatFromInt(self.doc.height)) / 2.0;
    }

    /// 画面注視点 (fx,fy) を不動点に zoom を変更する（scroll / +/- 用）。
    /// カーソルが表示領域外なら表示中心を注視点とする。clamp は canvasBlitRect が行う。
    fn zoomAround(self: *App, z: i32, fx: i32, fy: i32) void {
        const new_zoom = std.math.clamp(z, ZOOM_MIN, ZOOM_MAX);
        const old_zoom = self.view_zoom;
        if (new_zoom == old_zoom) return;
        const area = self.last_area orelse {
            self.view_zoom = new_zoom;
            return;
        };
        const c = areaCenterF(area);
        const in_area = fx >= area.x and fy >= area.y and fx < area.x + area.w and fy < area.y + area.h;
        const fxf: f32 = if (in_area) @floatFromInt(fx) else c.sx;
        const fyf: f32 = if (in_area) @floatFromInt(fy) else c.sy;
        const oz: f32 = @floatFromInt(old_zoom);
        const nz: f32 = @floatFromInt(new_zoom);
        const focus_cx = self.cam_cx + (fxf - c.sx) / oz;
        const focus_cy = self.cam_cy + (fyf - c.sy) / oz;
        self.cam_cx = focus_cx - (fxf - c.sx) / nz;
        self.cam_cy = focus_cy - (fyf - c.sy) / nz;
        self.view_zoom = new_zoom;
    }

    /// canvas が表示領域に収まる最大整数倍へ（Fit）。カメラは中央リセット。last_area 未確定時は無処理。
    fn fitZoom(self: *App) void {
        const area = self.last_area orelse return;
        const fz_x = @divFloor(area.w, @as(i32, @intCast(self.doc.width)));
        const fz_y = @divFloor(area.h, @as(i32, @intCast(self.doc.height)));
        self.setZoomCentered(@min(fz_x, fz_y));
    }

    fn setSaveMsg(self: *App, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.save_msg_buf, fmt, args) catch &self.save_msg_buf;
        self.save_msg_len = msg.len;
        self.save_msg_until = platform.getTime() + SAVE_MSG_DURATION;
    }

    /// appshell の title を OS 側へ反映する。title は状態遷移時だけ更新し、毎フレームは触らない。
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

    /// DocumentHost の path と autosave ID、既存 pixie field を同期するイベント境界。
    fn syncProjectState(self: *App) void {
        self.setProjectPath(self.host.currentPath()) catch @panic("syncProjectState: OOM");
        self.autosave.setPath(self.host.currentPath()) catch @panic("syncProjectState: OOM");
        if (self.host.isDirty()) self.autosave.markDirty(platform.getTime());
        self.refreshTitle();
    }

    /// document 内容を変更した編集イベントの共通入口。選択/tool/zoom では呼ばない。
    fn markProjectDirty(self: *App) void {
        self.host.markDirty();
        self.autosave.markDirty(platform.getTime());
        self.refreshTitle();
    }

    fn clearProjectAfterSave(self: *App) void {
        self.autosave.clear() catch |err| self.setSaveMsg("Autosave clear failed: {s}", .{@errorName(err)});
        self.syncProjectState();
    }

    fn saveMsg(self: *const App) ?[]const u8 {
        if (self.save_msg_len == 0 or platform.getTime() >= self.save_msg_until) return null;
        return self.save_msg_buf[0..self.save_msg_len];
    }

    fn editingBlocked(self: *const App) bool {
        return self.input.capturing or self.bezier_editor.isEditing() or self.sel_in.state != .idle or self.shape_in.state != .idle;
    }

    /// Document サイズ変更後に recorder / preview / onion / diff_base を新サイズへ再構築する。
    /// loadProjectPath / netsyncImport / doResize / doNew が共有する（dangling pointer 防止）。
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
    }

    /// 内容保持リサイズ（TASK-144.1）。GUI/action の唯一の入口。
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

    /// 指定サイズの blank Document へ置換（TASK-144.1）。GUI/action の唯一の入口。
    /// project path / PNG / autosave のクリアは hostNewDocument 側の規則に任せる。
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

    /// TASK-144.2: New Size / Resize Canvas ダイアログを開く（command は open のみ）。
    fn openSizeDialog(self: *App, mode: SizeDialogMode) void {
        // reentrant open 二重防御（dispatchCommand 先頭ガードと対称）。
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

    /// OK: parse → validate → doResize/doNew（確認経路）。失敗時は dialog を維持。
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
                // confirmation / applied のいずれも dialog を閉じる（overlay と同時に開かない）
                self.closeSizeDialog();
            },
        }
    }

    /// netsync 中に editingBlocked なら、ローカル編集（capture / bezier / select ドラッグ）を
    /// 中断して適用を許可する（host 権威の remote COMMIT を fail-soft 切断させない。TASK-94 Phase C P1）。
    /// solo は従来どおり EditingBlocked。
    fn checkEditingAllowed(self: *App) error{EditingBlocked}!void {
        if (!self.editingBlocked()) return;
        if (!platform.netsyncActive()) return error.EditingBlocked;
        self.interruptLocalEditForNetsync();
    }

    /// ローカルの進行中編集を破棄する（canvas 画素を汚す capture/fill のみ巻き戻し。
    /// bezier / select ドラッグは確定前に canvas を汚さないので cancel のみ）。
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
            // ESC と同じ内部処理（未確定 path 破棄）。ドラッグ中フラグも落とす。
            self.bezier_editor.update(self.gpa, .cancel);
            self.bez_in.in_drag = false;
        }
        if (self.sel_in.state != .idle) {
            // ESC ドラッグ中断と同じ（実レイヤーは drag 中不変 → 画素巻き戻し不要）。
            self.sel_in.cancel(self.gpa);
        }
        if (self.shape_in.state != .idle) {
            self.shape_in.cancel(); // プレビューのみ・canvas 非汚染
        }
        self.setSaveMsg("netsync: 進行中の編集は相手の操作適用のため中断されました", .{});
    }

    /// ソフトオーバーレイ（ツールグリフ + footprint リング）を隠すべきか（TASK-75.4）。
    /// 実際に描画/入力操作が進行中（stroke capture・選択ドラッグ・ベジェのハンドルドラッグ・パン）の間は
    /// 隠す（bezier hover プレビューの「ドラッグ中は隠す」流儀と同じ）。これにより
    /// `brush_edges.refresh()`（Brush.footprint() 経由で buildDab を再実行する）が Brush ストローク中に
    /// 呼ばれることも無くなり、「footprint は down 時に latch・stroke 中不変」という既存契約を壊さない。
    fn isPointerBusy(self: *const App) bool {
        return self.input.capturing or self.sel_in.state != .idle or self.shape_in.state != .idle or self.bez_in.in_drag or self.pan_active or self.eye_in.picking;
    }

    /// 安全点（framebuffer unlock 後・入力更新後）で保留中のファイル操作を 1 回だけ実行する。
    /// `error.DialogPending`（wasm file picker 待ち）のときは `dialog_op` に当該 op を保持して次 frame 再試行。
    /// dialog 待ち中に `pending_file_op` へ積まれた別要求は破棄する（picker 結果の誤配送防止。TASK-73.3 修正1）。
    /// それ以外（成功・キャンセル null・他 error 表示済み）では `dialog_op` をクリアして消費する。
    fn runPendingFileOp(self: *App) void {
        // システム clipboard paste（色 #RRGGBB）の非同期届けを安全点で取り込む。
        if (platform.clipboardTakePaste()) |text| {
            self.applySystemClipboardColor(text);
        }

        // dialog 進行中は dialog_op を優先。無ければ pending を 1 回だけ起動。
        const op = self.dialog_op orelse (self.pending_file_op orelse return);
        // dialog 待ち中に積まれた別要求は破棄（通知なし。意図: picker 結果を別 op に食わせない）。
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

    /// ファイル op の結果。`.dialog_pending` は wasm open の picker 待ち。
    const FileOpResult = enum { done, dialog_pending };

    /// システム clipboard の text を色として解釈（`#RRGGBB` / `RRGGBB`。他は無視）。
    fn applySystemClipboardColor(self: *App, text: []const u8) void {
        var s = std.mem.trim(u8, text, " \t\r\n");
        if (s.len > 0 and s[0] == '#') s = s[1..];
        if (s.len != 6) return;
        const rgb = std.fmt.parseInt(u32, s, 16) catch return;
        self.doSetColorHex(0xFF000000 | rgb);
    }

    /// 現在の描画色を `#RRGGBB` でシステム clipboard へ（wasm Clipboard API。native は no-op）。
    fn copySystemColor(self: *App) void {
        const c = self.pen.color;
        const r: u8 = @truncate(c >> 16);
        const g: u8 = @truncate(c >> 8);
        const b: u8 = @truncate(c);
        var buf: [7]u8 = undefined;
        const hex = std.fmt.bufPrint(&buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b }) catch return;
        platform.clipboardWrite(hex);
    }

    /// 選択スウォッチの色を編集中 HSV から決定し、palette と描画色（pen）へ反映する。
    /// edit_synced_for と palette.selected が一致するフレームでだけ呼ぶ（選択切替フレームの上書き事故回避）。
    fn applyEditColor(self: *App) void {
        const c: u32 = @bitCast(gui.Color.fromHsv(self.edit_h, self.edit_s, self.edit_v));
        self.palette.setSelectedColor(c);
        self.pen.color = c;
        self.brush.color = c; // Brush の描画色もパレット編集色に追従
        self.fill.color = c; // Fill の塗り色もパレット編集色に追従
    }

    /// 指定色を直接パレット選択色へ設定する（action `set_color` 用）。HSV ウィジェットを経由しない
    /// 直接代入のため `edit_synced_for = null` で次フレームの `syncEditHsv` に再同期を強制する
    /// （無いと HSV スライダーに触れた瞬間に古い HSV から色が巻き戻る）。`applyEditColor` 同様
    /// guard 無し（色選択は既存 UI でも editingBlocked に関わらず常に効く）。
    fn doSetColorHex(self: *App, color: u32) void {
        self.palette.setSelectedColor(color);
        self.pen.color = color;
        self.brush.color = color;
        self.fill.color = color;
        self.edit_synced_for = null;
    }

    /// App.palette.colors → doc.palette へ同期（.pix encode / netsync export 前。TASK-89）。
    fn syncPaletteToDoc(self: *App) void {
        self.doc.palette.clearRetainingCapacity();
        self.doc.palette.ensureTotalCapacity(self.gpa, self.palette.colors.items.len) catch @panic("syncPaletteToDoc: OOM");
        for (self.palette.colors.items) |c| self.doc.palette.appendAssumeCapacity(c);
    }

    /// doc.palette → App.palette 再構築（空なら DB16。load / netsync import 後。TASK-89）。
    fn loadPaletteFromDoc(self: *App) void {
        self.palette.colors.clearRetainingCapacity();
        if (self.doc.palette.items.len == 0) {
            // DB16 初期化（initDb16 と同内容・既存 gpa の colors を再利用）
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

    /// パレット色列を全置換する（palette_set / palette_ramp / palette_from_png 共通。undo 対象外）。
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

    /// 指定 layer の from→to 色置換（UI Repl / action replace_color。undo 可 = .paint Op）。
    /// layer_idx は呼び出し側が resolve（action は layer ref、UI は selected）。
    fn doReplaceColor(self: *App, layer_idx: usize, from: u32, to: u32) !u32 {
        if (self.editingBlocked()) return error.EditingBlocked;
        if (layer_idx >= self.doc.layers.items.len) return error.OutOfRange;
        if (self.doc.layers.items[layer_idx].kind == .text) return error.TextLayerSelected;
        return self.doc.pushReplaceColor(self.gpa, layer_idx, from, to) catch |err| switch (err) {
            error.TextLayerSelected => return error.TextLayerSelected,
        };
    }

    /// undo op の所有者タグ（`UndoStack.owners` の pixie 規約。TASK-62.5.4 review 反映:
    /// CommandLog リング退避で record が消えても op の所有者を誤認しないための op 側タグ）。
    /// unknown は「まだ確定していない未記録 push」で、フレーム末尾の `checkUnrecordedEdits` が
    /// user に確定する（agent 操作は常に action 経由で同イベント内にタグ付けされるため、
    /// フレーム末尾まで unknown で残る push は user の UI 操作しかない）。
    const OP_OWNER_UNKNOWN: u8 = 0;
    const OP_OWNER_USER: u8 = 1;
    const OP_OWNER_AGENT: u8 = 2;

    /// `first_seq`（呼び出し前の `cmd_log.next_seq`）**以降**に記録された normal record の
    /// undo_ref op へ所有者タグを付ける（executeAction / redoOne の後始末。record の actor が
    /// 確定している時点で op 側へ転記する）。
    fn tagOwnersFromRecords(self: *App, first_seq: u64, tag: u8) void {
        var i: u32 = self.cmd_log.filled;
        while (i > 0) {
            i -= 1;
            const rec = self.cmd_log.recordAt(i);
            if (rec.seq < first_seq) break; // seq は単調（これより古い record にタグ対象はない）
            if (rec.kind != .normal) continue;
            const ref = rec.undo_ref orelse continue;
            self.doc.undo.setOwner(ref, tag);
        }
    }

    /// ドキュメント読込/リセットで CommandLog 上の stale な undo/redo 候補を失効させる
    /// （TASK-62.5.4 review 反映）。undo 側は handle 単調化 + `hasHandle=false`（canUndo）で
    /// 自然失効するが、**redo 側（revert record）は epoch を進めないと旧 document の command を
    /// 新 document に再実行してしまう**ため、両 actor の epoch を明示的に bump する。
    fn invalidateHistoryAfterDocReset(self: *App) void {
        self.cmd_exec.bumpEpoch(.local_user);
        self.cmd_exec.bumpEpoch(.local_agent);
        self.last_seen_handle = self.doc.undo.next_handle;
        // 旧 document のサムネイルが新 document に残らないよう固定メタを無効化（TASK-83.2）。
        for (&self.history_thumb_meta) |*m| m.clear();
        self.markHistoryDirty();
    }

    /// 履歴確定フック: seq の CommandRecord から visual メタ／paint サムネイルを固定リングへ保存。
    /// **イベント時のみ**。allocator 不使用。
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

        // normal だが非 paint / undo_ref なし → [meta]
        meta.kind = @intFromEnum(history_summary.VisualKind.meta);
        self.history_thumb_meta[slot] = meta;
    }

    /// seq_before 以降に append された record をまとめて capture（redo / undo の複数 append 用）。
    fn captureHistoryVisualsSince(self: *App, seq_before: u64) void {
        var i: u32 = 0;
        while (i < self.cmd_log.filled) : (i += 1) {
            const rec = self.cmd_log.recordAt(i);
            if (rec.seq >= seq_before) self.captureHistoryVisual(rec.seq);
        }
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

    /// stroke の実効パラメータを解決する（§5c': 明示 k=v > 現在の App 状態）。tool 未指定かつ
    /// 現在ツールが pen/eraser/brush 以外は `error.UnsupportedTool`（fill は呼び出し側が
    /// legacy 経路で扱う。bezier/select/eyedropper は従来どおり拒否）。
    fn resolveEffectiveStroke(self: *App, p: actions.StrokeParams) error{UnsupportedTool}!actions.EffectiveStroke {
        const tool: actions.StrokeTool = p.tool orelse switch (self.active_kind) {
            .pen => .pen,
            .eraser => .eraser,
            .brush => .brush,
            else => return error.UnsupportedTool,
        };
        return .{
            .layer_id = 0,
            .tool = tool,
            .color = p.color orelse self.palette.current(),
            .size = p.size orelse self.brush.size,
            .opacity = p.opacity orelse self.brush.opacity,
            .hardness = p.hardness orelse self.brush.hardness_q,
        };
    }

    /// stroke の発信元 layer を安定 id へ解決する。省略時は capture/dispatch 元の selected layer。
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

    /// `.relay` route の入口で、発信元の tool/color/brush 設定と layer id を焼き込む。
    /// fill の旧 legacy 経路だけは従来の raw args を維持する。
    fn canonicalizeStroke(ctx: *anyopaque, args: []const u8, scratch: []u8) anyerror![]const u8 {
        const app: *App = @ptrCast(@alignCast(ctx));
        var pts_buf: [actions.MAX_STROKE_POINTS]actions.Point = undefined;
        const parsed = try actions.parseStroke(args, &pts_buf);
        const eff = app.resolveEffectiveStroke(parsed.params) catch |err| {
            if (app.active_kind == .fill and parsed.params.tool == null) return args;
            return err;
        };
        var canonical = eff;
        canonical.layer_id = try app.resolveStrokeLayerId(parsed.params.layer);
        return actions.formatCanonicalStroke(scratch, canonical, parsed.points) catch return error.ArgsTooLong;
    }

    /// UI stroke の点列蓄積を開始する（capture 開始時。実効パラメータもここで latch する。§5c）。
    fn uiStrokeBegin(self: *App, p: core.Vec2) void {
        self.ui_stroke_len = 0;
        self.ui_stroke_overflow = false;
        self.ui_stroke_layer_id = @intFromEnum(self.doc.layerIdAt(self.canvas.selected_layer) orelse .invalid);
        self.ui_stroke_tool = self.active_kind;
        self.ui_stroke_color = self.palette.current();
        self.ui_stroke_size = self.brush.size;
        self.ui_stroke_opacity = self.brush.opacity;
        self.ui_stroke_hardness = self.brush.hardness_q;
        self.uiStrokeAppend(p);
    }

    fn uiStrokeAppend(self: *App, p: core.Vec2) void {
        if (self.ui_stroke_overflow) return;
        if (self.ui_stroke_len > 0) {
            const last = self.ui_stroke_pts[self.ui_stroke_len - 1];
            if (last.x == p.x and last.y == p.y) return; // 連続同一点は蓄積しない
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
    }

    /// UI stroke の確定点で CommandRecord を記録する（§5c。actor=local_user・canonical args。
    /// one-shot: 蓄積は必ずクリアする）。`pushed` = pushPaintOp で Op が実際に push されたか
    /// （true なら undo_ref = 直近 push の handle = AC #2 の対応付け）。
    fn recordUiStroke(self: *App, pushed: bool) void {
        if (pushed) self.markProjectDirty();
        const len = self.ui_stroke_len;
        const overflow = self.ui_stroke_overflow;
        self.uiStrokeDiscard();
        if (len == 0) return;
        if (overflow) {
            std.debug.print("pixie: UI stroke の記録を skip（{d} 点超過。Op は legacy UndoStack に残る）\n", .{actions.MAX_STROKE_POINTS});
            return;
        }
        const tool: actions.StrokeTool = switch (self.ui_stroke_tool) {
            .pen => .pen,
            .eraser => .eraser,
            .brush => .brush,
            else => return, // fill 等は §5c の記録対象外（pen/eraser/brush のみ）
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
            std.debug.print("pixie: UI stroke の記録を skip（canonical args が {d}B 超過。Op は legacy UndoStack に残る）\n", .{platform.command.MAX_CMD_ARGS});
            return;
        };
        const undo_ref: ?u64 = if (pushed) self.doc.undo.topHandle() else null;
        var msg_buf: [64]u8 = undefined;
        const seq = self.cmd_exec.recordExecuted("stroke", canon, .{ .actor = .local_user }, undo_ref, &msg_buf) catch |err| {
            std.debug.print("pixie: UI stroke の記録に失敗: {s}\n", .{@errorName(err)});
            return; // 記録失敗 = 未記録 push としてフレーム末尾の bumpEpoch に委ねる（§2b）
        };
        if (seq) |s| self.captureHistoryVisual(s);
        if (undo_ref) |ref| self.doc.undo.setOwner(ref, OP_OWNER_USER); // op は user 所有（review 反映）
        self.last_seen_handle = self.doc.undo.next_handle; // 記録された push（§2b の追従点）
    }

    /// netsync 中の UI stroke を routeAction("stroke") へ流す対象か（pen/eraser/brush のみ。
    /// fill 等は action 語彙なし → netsync 中は rewind_discard。TASK-94 Phase C）。
    fn uiStrokeRelaysViaAction(self: *const App) bool {
        return switch (self.ui_stroke_tool) {
            .pen, .eraser, .brush => true,
            else => false,
        };
    }

    /// ローカル preview 塗りを pd.diffs の before（= ストローク開始前値。StrokeRecorder dedup /
    /// brush orig）で巻き戻し、diffs を解放する（pushPaintOp しない。TASK-94 Phase C-1b）。
    fn rewindPaintDiff(self: *App, pd: core.PaintDiff) void {
        const pixels = self.canvas.layerPixels(pd.layer_idx);
        for (pd.diffs) |d| pixels[d.idx] = d.before;
        self.gpa.free(pd.diffs);
    }

    /// UI shape 確定の CommandRecord 記録（TASK-90。actor=local_user）。
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
            std.debug.print("pixie: UI shape の記録を skip（canonical args 超過）\n", .{});
            return;
        };
        const undo_ref: ?u64 = if (pushed) self.doc.undo.topHandle() else null;
        var msg_buf: [64]u8 = undefined;
        const seq = self.cmd_exec.recordExecuted("shape", canon, .{ .actor = .local_user }, undo_ref, &msg_buf) catch |err| {
            std.debug.print("pixie: UI shape の記録に失敗: {s}\n", .{@errorName(err)});
            return;
        };
        if (seq) |s| self.captureHistoryVisual(s);
        if (undo_ref) |ref| self.doc.undo.setOwner(ref, OP_OWNER_USER);
        self.last_seen_handle = self.doc.undo.next_handle;
    }

    /// netsync 中 UI shape 確定: 巻き戻し済み → routeAction("shape")。
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
            std.debug.print("pixie: netsync UI shape を skip（canonical args 超過）\n", .{});
            return;
        };
        var out_buf: [256]u8 = undefined;
        _ = platform.routeAction("shape", canon, &out_buf) catch |err| {
            std.debug.print("pixie: netsync UI shape routeAction 失敗: {s}\n", .{@errorName(err)});
        };
    }

    /// netsync 中 UI stroke 確定: 巻き戻し → canonical args で routeAction("stroke")。
    /// solo の recordUiStroke と対になる経路（actor は wire の origin peer。TASK-94 Phase C-1）。
    fn relayUiStroke(self: *App) void {
        const len = self.ui_stroke_len;
        const overflow = self.ui_stroke_overflow;
        const tool_kind = self.ui_stroke_tool;
        const color = self.ui_stroke_color;
        const size = self.ui_stroke_size;
        const opacity = self.ui_stroke_opacity;
        const hardness = self.ui_stroke_hardness;
        // 点列は discard 前に canon 化するため、slice を先に取る（discard は len を 0 にするだけ）。
        const pts = self.ui_stroke_pts[0..len];
        self.uiStrokeDiscard();
        if (len == 0) return;
        if (overflow) {
            std.debug.print("pixie: netsync UI stroke を skip（{d} 点超過。preview は巻き戻し済み）\n", .{actions.MAX_STROKE_POINTS});
            return;
        }
        const tool: actions.StrokeTool = switch (tool_kind) {
            .pen => .pen,
            .eraser => .eraser,
            .brush => .brush,
            else => return,
        };
        var canon_buf: [platform.command.MAX_CMD_ARGS]u8 = undefined;
        const canon = actions.formatCanonicalStroke(&canon_buf, .{
            .layer_id = self.ui_stroke_layer_id,
            .tool = tool,
            .color = color,
            .size = size,
            .opacity = opacity,
            .hardness = hardness,
        }, pts) catch {
            std.debug.print("pixie: netsync UI stroke を skip（canonical args 超過）\n", .{});
            return;
        };
        var out_buf: [256]u8 = undefined;
        _ = platform.routeAction("stroke", canon, &out_buf) catch |err| {
            std.debug.print("pixie: netsync UI stroke routeAction 失敗: {s}\n", .{@errorName(err)});
            self.setSaveMsg("netsync: stroke を送信できませんでした（{s}）", .{@errorName(err)});
        };
    }

    /// netsync 中のみ routeAction、solo は呼び出し側が do* を使う（TASK-94 Phase C-2）。
    fn routeUi(self: *App, name: []const u8, args: []const u8) void {
        var buf: [256]u8 = undefined;
        _ = platform.routeAction(name, args, &buf) catch |err| {
            std.debug.print("pixie: routeAction {s} 失敗: {s}\n", .{ name, @errorName(err) });
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

    /// スポイト（TASK-68）: 指定 canvas 座標の色を描画色へ反映する。座標は呼び出し側
    /// （`eyedropper_input.EyedropperInput.update`）が既に canvas 範囲内であることを保証している。
    /// 取得色は「合成色」（`compositeStraight()`。表示されている見た目の色。設計判断は plan 参照）。
    /// alpha==0（未描画/透明）は無視する（黒などの偽色を拾わせない）。alpha は不透明へ強制してから
    /// `doSetColorHex` へ渡す（`palette.zig` の不変条件「色は常に不透明」を守るため）。
    /// Eraser 選択中に拾った場合は Pen へ自動切替する（Eraser 自体には描画色の概念が無いため。
    /// パレットスウォッチクリックと同じ既存慣習）。`setActiveKind` は経由しない直接代入で切り替える
    /// （`setActiveKind` は `eye_in.picking` 中は競合ガードで no-op になるため、drag 中に不透明色を
    /// 拾った時点で切り替えたい本メソッドの意図と噛み合わない。この切替は「進行中の eyedrop 操作
    /// 自身の帰結」であり他ツールとの競合ではないので安全にバイパスできる。かつ .eraser から離れる
    /// 遷移は bezier cancel も sel_in フロート破棄も不要＝`setActiveKind` のガード外処理を再現する
    /// 必要が無い。codex レビュー指摘 2026-07-05）。
    fn pickColor(self: *App, x: i32, y: i32) void {
        const idx = @as(usize, @intCast(y)) * self.canvas.width + @as(usize, @intCast(x));
        const sampled = self.canvas.compositeStraight()[idx];
        if (sampled & 0xFF000000 == 0) return; // 透明部は無視
        self.doSetColorHex(0xFF000000 | (sampled & 0x00FFFFFF));
        if (self.active_kind == .eraser) self.active_kind = .pen;
    }

    /// 選択（or load）が変わったフレームに編集中 HSV を現在色から再同期する。
    fn syncEditHsv(self: *App) void {
        if (self.edit_synced_for == self.palette.selected) return;
        const hsv = guiColor(self.palette.current()).toHsv();
        self.edit_h = hsv.h;
        self.edit_s = hsv.s;
        self.edit_v = hsv.v;
        self.edit_synced_for = self.palette.selected;
    }

    /// パレットを .gpl で保存（名前を付けて保存。成功でダイアログ戻り値を palette_path へ移譲）。
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

    /// .gpl を読み込んでパレットを差し替える（成功時のみ。失敗時は既存パレットを保持）。
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
        // 成功: 旧 colors を解放して差し替え、selected/HSV を初期化
        self.palette.colors.deinit(self.gpa);
        self.palette.colors = colors;
        self.palette.selected = 0;
        self.edit_synced_for = null; // 次フレームで HSV 再同期
        self.repl_source = null;
        const cur = self.palette.current();
        self.pen.color = cur;
        self.brush.color = cur;
        self.fill.color = cur;
        self.setSaveMsg("Palette loaded: {s}", .{std.fs.path.basename(path)});
        return .done;
    }

    /// 指定パスへ直接保存する（ダイアログ不使用。`doSave` の共通実装 + action `save <path>` 用）。
    /// current_path は更新しない（headless 呼び出しが UI の「名前を付けて保存」の永続状態へ
    /// 暗黙に介入しないため）。editingBlocked チェックは無い（既存 doSave/doSaveAs に無いのでそのまま）。
    fn doSaveTo(self: *App, path: []const u8) !void {
        const flat = self.canvas.compositeStraight();
        try core.savePNG(self.io, path, flat, self.canvas.width, self.canvas.height, self.gpa);
        self.setSaveMsg("Saved: {s}", .{std.fs.path.basename(path)});
    }

    /// 記憶している保存先へ直接上書き。未設定なら「名前を付けて保存」へフォールバック。
    fn doSave(self: *App) FileOpResult {
        const path = self.current_path orelse return self.doSaveAs();
        // current_path は永続パスなので失敗しても保持（free しない）
        self.doSaveTo(path) catch |err| {
            self.setSaveMsg("Save failed: {s}", .{@errorName(err)});
        };
        return .done;
    }

    /// ダイアログで保存先を選んで保存。成功時にダイアログ戻り値を current_path へ移譲する。
    fn doSaveAs(self: *App) FileOpResult {
        const maybe = platform.saveFileDialog(self.gpa, self.io, .{
            .default_name = "untitled.png",
            .allowed_ext = "png",
        }) catch |err| {
            if (err == error.DialogPending) return .dialog_pending;
            self.setSaveMsg("Save failed: {s}", .{@errorName(err)});
            return .done;
        };
        const path = maybe orelse return .done; // キャンセル: サイレント no-op
        const flat = self.canvas.compositeStraight();
        core.savePNG(self.io, path, flat, self.canvas.width, self.canvas.height, self.gpa) catch |err| {
            self.setSaveMsg("Save failed: {s}", .{@errorName(err)});
            self.gpa.free(path); // 失敗時はダイアログ戻り値を解放・旧 current_path は触らない
            return .done;
        };
        if (self.current_path) |old| self.gpa.free(old);
        self.current_path = path; // 移譲（再 dupe しない）
        self.setSaveMsg("Saved: {s}", .{std.fs.path.basename(path)});
        return .done;
    }

    /// デコード済み PNG を指定 layer へ左上クロップ/パディングで書き込み、preview と cel へ同期する。
    /// undo push は一切しない（呼び出し側が `.layer_add` 等の Op 単位を決める）。
    /// canvas / PNG は canonical BGRA 0xAARRGGBB 同一レイアウトなので変換不要。
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
        // active_view は cel のコピー。saveDocument は cel_pool を直列化するため、
        // layer 直書き後に cel へ書き戻す（TASK-95。undo Op は呼び出し側の責務）。
        self.doc.commitActiveLayerToCel(self.gpa, layer_idx);
    }

    /// ダイアログで PNG を選んでキャンバスへ読み込む（左上クロップ/パディング）。
    /// 進行中 stroke 中は破棄。undo/redo はクリアし、current_path を開いたファイルに更新。
    /// 指定パスから直接読み込む（ダイアログ不使用。`doOpen` の共通実装 + action `open <path>` 用）。
    /// `doOpen` と同じ narrow guard（`input.capturing or bezier_editor.isEditing()`。`sel_in.state`
    /// は見ない＝既存 doOpen の挙動をそのまま踏襲）。path は `gpa.dupe` して current_path へ独立
    /// 所有コピーとして格納する（呼び出し側の path 所有権には関与しない）。
    fn doOpenPath(self: *App, path: []const u8) !void {
        if (self.input.capturing or self.bezier_editor.isEditing()) return error.EditingBlocked;
        var img = try png.decodePNGFile(self.io, self.gpa, path);
        defer img.deinit(self.gpa);
        // current_path 用の独立コピーを、ドキュメントを差し替える**前**に確保する（後段はエラーを
        // return しない: Document 系の OOM は panic 契約（commitActiveLayerToCel 含む）。エラー return
        // で「読み込み済みだが失敗扱い」という中途半端な状態を作らない、の意）。
        const owned = try self.gpa.dupe(u8, path);

        // PNG はフラット形式として読み込み、layer0 だけの新規ドキュメントへ置き換える。
        self.resetCanvasToSingleLayer();
        // selected_frame は resetToSingleBlankLayer で 0 に確定済み。
        // load はドキュメント差し替えなので undo 不要（reset が doc.undo を破棄済み。TASK-45.1）。
        self.copyDecodedPngToLayer(0, &img);

        if (self.current_path) |old| self.gpa.free(old);
        self.current_path = owned;
        self.setSaveMsg("Loaded: {s}", .{std.fs.path.basename(path)});
    }

    /// 現ドキュメントへ PNG を新レイヤーとして挿入する（TASK-134）。
    /// decode 先行（失敗時は document 不変）。`doAddLayer` が push する `.layer_add` 1 件を undo 単位にし、
    /// 画素は cel へ同期してから返す（undo で layer 構造 + 画素を一体除去）。`pushPaintOp` は呼ばない。
    /// `current_path` は変更しない。ホットパス: イベント時のみ。
    fn doImportPngAsLayer(self: *App, path: []const u8) !void {
        // 不変条件: decode 失敗時は document を一切変更しない。
        var img = try png.decodePNGFile(self.io, self.gpa, path);
        defer img.deinit(self.gpa);

        _ = try self.doAddLayer();
        // doAddLayer → Document.addLayer が新 layer を選択する（Canvas.insertLayer 経由で
        // canvas.selected_layer も同期済み）。
        const layer_idx = self.canvas.selected_layer;
        self.copyDecodedPngToLayer(layer_idx, &img);
        self.setSaveMsg("Inserted: {s}", .{std.fs.path.basename(path)});
    }

    /// OS / harness の file drop を消費する（TASK-113.4 / TASK-134）。
    /// PNG のみ `doImportPngAsLayer` へ直結（現ドキュメントへ新レイヤー挿入。.pix / その他は拒否）。
    /// netsync 中は I/O せず reject。ホットパス: イベント時のみ。
    fn handleFileDrop(self: *App, drop: platform.FileDropEvent) void {
        if (drop.count != 1) return;
        const path = drop.paths[0].slice();
        const ext = std.fs.path.extension(path);
        if (!std.ascii.eqlIgnoreCase(ext, ".png")) {
            self.setSaveMsg("Drop rejected: not a PNG ({s})", .{std.fs.path.basename(path)});
            return;
        }
        if (platform.netsyncActive()) {
            // 既存 PNG open の reject_when_synced と同じメッセージ経路（setSaveMsg）。
            // remote action へ route しない・I/O しない・canvas 不変。
            self.setSaveMsg("netsync: open を送信できませんでした（RejectedWhileSynced）", .{});
            return;
        }
        self.doImportPngAsLayer(path) catch |err| {
            self.setSaveMsg("Import failed: {s}", .{@errorName(err)});
        };
    }

    /// ダイアログで PNG を選んでキャンバスへ読み込む（左上クロップ/パディング）。
    fn doOpen(self: *App) FileOpResult {
        if (self.input.capturing or self.bezier_editor.isEditing()) return .done;
        const maybe = platform.openFileDialog(self.gpa, self.io, .{ .allowed_ext = "png" }) catch |err| {
            if (err == error.DialogPending) return .dialog_pending;
            self.setSaveMsg("Load failed: {s}", .{@errorName(err)});
            return .done;
        };
        const path = maybe orelse return .done; // キャンセル: サイレント no-op
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

    // ── .pix プロジェクト保存/読込（レイヤー構造保持。TASK-63）─────────────────

    /// 記憶している .pix 保存先へ直接上書き。未設定なら「名前を付けて保存」へフォールバック。
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

    /// ダイアログで .pix 保存先を選んで保存。成功時にダイアログ戻り値を current_project_path へ移譲。
    fn doSaveAsProject(self: *App) FileOpResult {
        const maybe = platform.saveFileDialog(self.gpa, self.io, .{
            .default_name = "untitled.pix",
            .allowed_ext = "pix",
        }) catch |err| {
            if (err == error.DialogPending) return .dialog_pending;
            self.setSaveMsg("Project save failed: {s}", .{@errorName(err)});
            return .done;
        };
        const path = maybe orelse return .done; // キャンセル: サイレント no-op
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

    /// .pix プロジェクトを読み込んでドキュメントを差し替える（レイヤー構造保持）。
    /// 進行中 stroke/編集中は破棄。undo/redo はクリア、selection/float 破棄、current_project_path 更新。
    /// サイズは peekCanvasSize + 共通上限 validator（各辺≤4096・総画素≤16M）で検証する（TASK-144.1）。
    fn doOpenProject(self: *App) FileOpResult {
        if (self.editingBlocked()) return .done;
        const maybe = platform.openFileDialog(self.gpa, self.io, .{ .allowed_ext = "pix" }) catch |err| {
            if (err == error.DialogPending) return .dialog_pending;
            self.setSaveMsg("Project load failed: {s}", .{@errorName(err)});
            return .done;
        };
        const path = maybe orelse return .done; // キャンセル: サイレント no-op
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

    // ── 連番 PNG / スプライトシート書き出し（TASK-45.5）──────────────────────

    /// saveFileDialog で選んだ path から `.png` 拡張子を除いた stem を返す（連番書き出し用）。
    fn pathToPngStem(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        if (path.len >= 4 and std.ascii.eqlIgnoreCase(path[path.len - 4 ..], ".png")) {
            return allocator.dupe(u8, path[0 .. path.len - 4]);
        }
        return allocator.dupe(u8, path);
    }

    /// ダイアログで stem を選び連番 PNG（`<stem>_NNNN.png`）を書き出す。
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

    /// ダイアログで path を選びスプライトシート PNG を書き出す（columns/margin は既定）。
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

    /// 指定 stem へ連番 PNG を直接書き出す（action `export_seq <stem>` 用）。
    fn doExportSeqTo(self: *App, stem: []const u8) !void {
        if (self.doc.frames.items.len == 0) return error.NoFrames;
        try core.document_io.exportPngSequence(self.io, stem, &self.doc, self.gpa);
        self.setSaveMsg("Exported sequence: {s}", .{std.fs.path.basename(stem)});
    }

    /// 指定 path へスプライトシートを直接書き出す（action `export_sheet` 用）。
    fn doExportSheetTo(self: *App, path: []const u8, opts: core.document_io.SpriteSheetOpts) !void {
        try core.document_io.exportSpriteSheet(self.io, path, &self.doc, self.gpa, opts);
        self.setSaveMsg("Exported sheet: {s}", .{std.fs.path.basename(path)});
    }

    /// 編集系コマンドは stroke 中は無視する（仕様の簡略化指示）。`!void` 化（TASK-64）は UI
    /// （`catch {}` で無視）と action（`try` で伝播）が同じ判定コードを共有するための変更で、
    /// 挙動そのものは変わらない（action ⇄ UndoCmd 対応表は下部「custom action」セクションの
    /// doc comment 参照）。undo/redo スタックが空の場合は失敗にせず冪等 no-op として成功する
    /// （`UndoStack.undoOne`/`redoOne` も空なら何もしない既存実装のため、新規挙動ではない）。
    fn doUndo(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        const undo_before = self.doc.undo.undo.items.len;
        const redo_before = self.doc.undo.redo.items.len;
        const seq_before = self.cmd_log.next_seq;
        // defer: routeAction が途中失敗しても revert フラグ等の変異は起きうる（next_seq 非依存）
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
            // HistoryEntry.name は CommandRecord 内バッファへの借用（history_summary.zig の
            // 「CommandLog 変異を跨いで保持禁止」契約）。パネルは summary（inline copy）のみ
            // 使うので、キャッシュには借用を残さない。
            self.history_entries[i].name = "";
        }
        self.history_seen_seq = self.cmd_log.next_seq;
        self.history_dirty = false;
    }

    fn ensureHistoryFresh(self: *App) void {
        if (!self.history_dirty and self.history_seen_seq == self.cmd_log.next_seq) return;
        self.rebuildHistoryEntries();
    }

    /// local_user の undo（ハイブリッド。TASK-62.5.4 §2）: undo stack を上から走査し、最初の
    /// 「local_user 所有の op」を undo する。
    /// - CommandLog に record が対応する op:
    ///   - actor が local_user 以外（agent 等）→ skip（agent の op は `action undo` でのみ戻す）
    ///   - actor=local_user → framework 経路 `cmd_exec.undoOne(.local_user)`（revert record の
    ///     append・reverted マーク・tx bundle・epoch は framework が処理）
    /// - record が対応しない（未記録）op = local_user 所有（agent 操作は常に action 経由で記録
    ///   される。62.5.3 の構造）→ legacy 経路:
    ///   - 最上位なら従来の `doc.undoOne()`（redo stack へ移動）
    ///   - 最上位でない `.paint` op は `revertByHandle(move_to_redo)`（agent op が上にある場合）
    ///   - 最上位でない未記録**構造 op は undo 不能として skip**（任意位置 revert は paint 限定 =
    ///     `Document.canRevertByHandle` の構造 Op 制約参照）。走査は次の user 所有 op へ進む
    /// 2 系統（framework revert / legacy stack）の時系列交錯は**近似**（MVP 割り切り。62.5.3 の
    /// 段階移行が完了すれば legacy 系統は消える）。pixel 巻き添え artifact の割り切りは
    /// `Document.revertByHandle` の doc comment 参照。
    fn userUndo(self: *App) void {
        var i: usize = self.doc.undo.handles.items.len;
        while (i > 0) {
            i -= 1;
            const h = self.doc.undo.handles.items[i];
            // 所有者判定は record 逆引きでなく op 側の owner タグが正（CommandLog リング退避で
            // record が消えた agent op を「未記録 = user 所有」と誤認して legacy undo しないため。
            // review 反映）。unknown は user 扱い（§2 の根拠: agent 操作は常にタグ付けされる）。
            if (self.doc.undo.owners.items[i] == OP_OWNER_AGENT) continue;
            if (self.findRecordByUndoRef(h)) |rec| {
                if (!rec.actor.eql(.local_user)) continue; // 防御（owner タグと二重の保険）
                var buf: [256]u8 = undefined;
                _ = self.cmd_exec.undoOne(.local_user, &buf) catch |err| {
                    std.debug.print("pixie: undoOne 失敗: {s}\n", .{@errorName(err)});
                };
                return;
            }
            // 未記録 = local_user 所有 → legacy 経路
            if (i == self.doc.undo.undo.items.len - 1) {
                self.doc.undoOne(self.gpa);
                return;
            }
            if (self.doc.canRevertByHandle(h)) {
                _ = self.doc.revertByHandle(self.gpa, h, .move_to_redo);
                return;
            }
            // 最上位でない未記録構造 op → skip して次の user 所有 op へ
        }
    }

    /// local_user の redo（ハイブリッド。§2）: framework `redoOne(.local_user)` を先に試み、
    /// **候補なしなら legacy `doc.redoOne()`**（legacy undo で redo stack に載った未記録 op 用）。
    /// legacy の再 push は「新規編集」ではないため `last_seen_handle` を追従させ epoch bump を
    /// 防ぐ（§2b）。framework redo の再 dispatch 側は `dispatchPixieAction` の noteUndo 経路で
    /// 追従済み。エラー（PartialRedo 等）時は legacy へ流さない（部分適用の上に重ねない）。
    fn userRedo(self: *App) void {
        var buf: [256]u8 = undefined;
        const seq_before = self.cmd_log.next_seq;
        const outcome = self.cmd_exec.redoOne(.local_user, &buf) catch |err| {
            std.debug.print("pixie: redoOne 失敗: {s}\n", .{@errorName(err)});
            self.tagOwnersFromRecords(seq_before, OP_OWNER_USER); // PartialRedo でも適用済み分はタグ
            self.captureHistoryVisualsSince(seq_before); // PartialRedo でも append 済み分を捕捉
            return;
        };
        if (!outcome.happened) {
            const handle_before = self.doc.undo.next_handle;
            self.doc.redoOne(self.gpa);
            self.last_seen_handle = self.doc.undo.next_handle;
            // legacy redo が実際に再 push した場合のみ owner を user に確定する（no-op 時に
            // 既存 top（agent 所有かもしれない）を誤って上書きしない。last_seen 更新で
            // checkUnrecordedEdits の unknown→USER 確定は走らないため、ここで直接付ける）
            if (self.doc.undo.next_handle > handle_before) {
                if (self.doc.undo.topHandle()) |h| self.doc.undo.setOwner(h, OP_OWNER_USER);
            }
            // legacy redo は CommandRecord を生成しない → 新規履歴サムネイルなし
            return;
        }
        self.tagOwnersFromRecords(seq_before, OP_OWNER_USER); // 再 dispatch された新 op は user 所有
        self.captureHistoryVisualsSince(seq_before);
    }

    /// CommandLog を後方走査して undo_ref==handle の normal record を返す（userUndo の
    /// op→record 対応判定。イベント時のみ・最大 128 slot の線形走査）。
    fn findRecordByUndoRef(self: *App, handle: u64) ?*const platform.command.CommandRecord {
        var i: u32 = self.cmd_log.filled;
        while (i > 0) {
            i -= 1;
            const rec = self.cmd_log.recordAt(i);
            if (rec.kind == .normal and rec.undo_ref != null and rec.undo_ref.? == handle) return rec;
        }
        return null;
    }

    /// フレーム末尾の未記録 undoable 編集検出（§2b）。検出したら local_user の redo 候補を
    /// epoch で失効させる（layer add 等の未記録 UI 操作で framework redo が古い候補を再実行
    /// しないため）。
    fn checkUnrecordedEdits(self: *App) void {
        if (self.doc.undo.next_handle > self.last_seen_handle) {
            self.markProjectDirty();
            self.cmd_exec.bumpEpoch(.local_user);
            self.last_seen_handle = self.doc.undo.next_handle;
            // 未記録 push の owner を user に確定（agent 操作は同イベント内にタグ済み = unknown で
            // フレーム末尾まで残るのは user の UI 操作のみ。bump 発生時のみの O(depth) 走査）
            for (self.doc.undo.owners.items) |*o| {
                if (o.* == OP_OWNER_UNKNOWN) o.* = OP_OWNER_USER;
            }
        }
    }

    fn doClear(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        if (self.selectedLayerIsText()) return error.EditingBlocked; // TASK-79.5: text layer 直接編集禁止
        self.doc.pushClear(self.gpa, self.canvas.selected_layer) catch |err| switch (err) {
            error.TextLayerSelected => return error.EditingBlocked, // 上のガードで既に弾いているはずの防御的分岐
        };
    }

    /// シェイプを 1 回描画して UndoStack へ push（TASK-90）。UI 確定 / action shape が共有。
    /// pixel_perfect は一時無効。symmetry は recorder 設定に従う。
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

    /// 対称描画モードを設定する（TASK-90。UI / action set_symmetry 共通）。
    fn doSetSymmetry(self: *App, mode: core.Symmetry) void {
        self.symmetry = mode;
        self.recorder.symmetry = mode;
    }

    /// ピクセルパーフェクトを設定する（TASK-90。UI / action set_pixel_perfect 共通）。
    fn doSetPixelPerfect(self: *App, on: bool) void {
        self.pixel_perfect = on;
    }

    /// UI から対称を切替（TASK-94 Phase C: netsync 中は routeAction、solo は do* 直呼び）。
    fn uiSetSymmetry(self: *App, mode: core.Symmetry) void {
        const args: []const u8 = switch (mode) {
            .off => "off",
            .vertical => "v",
            .horizontal => "h",
            .quad => "quad",
        };
        if (platform.netsyncActive()) self.routeUi("set_symmetry", args) else self.doSetSymmetry(mode);
    }

    /// UI から pixel_perfect を切替（netsync 中は routeAction）。
    fn uiSetPixelPerfect(self: *App, on: bool) void {
        if (platform.netsyncActive()) {
            self.routeUi("set_pixel_perfect", if (on) "1" else "0");
        } else {
            self.doSetPixelPerfect(on);
        }
    }

    /// 選択範囲を clipboard へコピー（読み取りのみ・undo 不要）。selection 無しは no-op。
    /// 読み取りのみ（pixels を変更しない）なので text layer 選択中でも許可する（TASK-79.5）。
    fn doCopy(self: *App) void {
        if (self.editingBlocked()) return;
        const sel = self.canvas.selection orelse return;
        const block = core.selection.extract(self.gpa, self.canvas, self.canvas.selected_layer, sel);
        if (self.clipboard) |*old| old.deinit(self.gpa);
        self.clipboard = block;
    }

    /// 選択範囲を clipboard へコピーし、選択内を透明化する（undo 可）。selection 無しは no-op。
    fn doCut(self: *App) void {
        if (self.editingBlocked()) return;
        if (self.selectedLayerIsText()) return; // TASK-79.5: text layer 直接編集禁止
        const sel = self.canvas.selection orelse return;
        const block = core.selection.extract(self.gpa, self.canvas, self.canvas.selected_layer, sel);
        if (self.clipboard) |*old| old.deinit(self.gpa);
        self.clipboard = block;
        if (core.selection.clearRectCmd(self.gpa, self.canvas, self.canvas.selected_layer, sel)) |pd| {
            self.doc.pushPaintOp(self.gpa, pd.layer_idx, pd.diffs) catch {}; // 上で text layer は既に弾いている
        }
    }

    /// clipboard を貼り付ける（undo 可）。貼付先は selection の左上（無ければ 0,0）。
    /// selection を貼付矩形（canvas 内 clip）へ更新する。clipboard 無しは no-op。
    fn doPaste(self: *App) void {
        if (self.editingBlocked()) return;
        if (self.selectedLayerIsText()) return; // TASK-79.5: text layer 直接編集禁止
        const block = self.clipboard orelse return;
        const dx: i32 = if (self.canvas.selection) |s| s.x else 0;
        const dy: i32 = if (self.canvas.selection) |s| s.y else 0;
        if (core.selection.pasteCmd(self.gpa, self.canvas, self.canvas.selected_layer, block, dx, dy, self.blend_mode)) |pd| {
            self.doc.pushPaintOp(self.gpa, pd.layer_idx, pd.diffs) catch {}; // 上で text layer は既に弾いている
        }
        const dest = core.Rect{ .x = dx, .y = dy, .w = @intCast(block.w), .h = @intCast(block.h) };
        self.canvas.setSelection(core.selection.clipRect(dest, self.canvas.width, self.canvas.height));
    }

    /// `Document.addLayer` が mutation + Op構築 + push を内部で完結する（plan 5.4節「一般化」）。
    /// 戻り値は新規レイヤーの LayerId raw（action 応答 `ok id=#N` 用。TASK-94 Phase B review）。
    fn doAddLayer(self: *App) !u64 {
        if (self.editingBlocked()) return error.EditingBlocked;
        const idx = self.doc.addLayer(self.gpa) catch |err| {
            self.setSaveMsg("Layer add failed: {s}", .{@errorName(err)});
            return err;
        };
        self.clampTimelineTarget();
        return @intFromEnum(self.doc.layerIdAt(idx).?);
    }

    /// 明示 index のレイヤーを削除する（TASK-94 Phase B: selected 暗黙参照を排除）。
    fn doDeleteLayer(self: *App, idx: usize) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        try self.doc.deleteLayer(self.gpa, idx);
        self.clampTimelineTarget();
    }

    /// 明示 index のレイヤーを delta（±1）だけ移動する（TASK-94 Phase B）。
    fn doMoveLayer(self: *App, idx: usize, delta: i32) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        const to_i: i32 = @as(i32, @intCast(idx)) + delta;
        if (to_i < 0) return error.OutOfRange;
        try self.doc.reorderLayer(self.gpa, idx, @intCast(to_i));
    }

    /// レイヤー可視性を明示値へ設定する（`doToggleLayerVisible` の共通実装。TASK-64 で action
    /// `set_layer_visible` からも直接呼べるよう抽出）。`Document.setLayerVisible` が冪等 no-op
    /// 判定込みで mutation + Op構築 + push を完結する。
    fn doSetLayerVisible(self: *App, idx: usize, on: bool) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        try self.doc.setLayerVisible(self.gpa, idx, on);
    }

    /// UI のトグルボタン用（現在値の反転）。範囲外は既存どおり黙って無視（idx 境界は `doSetLayerVisible`
    /// 呼び出し前に確認する必要がある＝ `!before` 読み出しの OOB を避けるため）。
    fn doToggleLayerVisible(self: *App, idx: usize) void {
        if (idx >= self.canvas.layers.items.len) return;
        const before = self.canvas.layers.items[idx].visible;
        self.doSetLayerVisible(idx, !before) catch {};
    }

    fn doSetLayerOpacity(self: *App, idx: usize, value: u8) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        try self.doc.setLayerOpacity(self.gpa, idx, value);
    }

    /// レイヤー名を変更する（Rename。TASK-79.3）。`Document.renameLayer` が冪等 no-op 判定込みで
    /// mutation + Op構築 + push を完結する。呼び出し元はインライン編集の確定
    /// （`commitRenameLayer`）と harness action（将来採用時）を想定。
    fn doRenameLayer(self: *App, idx: usize, new_name: []const u8) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        try self.doc.renameLayer(self.gpa, idx, new_name);
    }

    /// レイヤー行の右クリックメニュー「Rename...」から呼ぶ。現在名を編集バッファへコピーして
    /// インライン編集を開始する（確定は `commitRenameLayer`、取消は `cancelRenameLayer`）。
    fn beginRenameLayer(self: *App, idx: usize) void {
        if (idx >= self.canvas.layers.items.len) return;
        self.text_in.cancel(); // rename/text 編集は同時に active にしない（TASK-79.5）
        self.rename_in.begin(idx, self.canvas.layers.items[idx].name());
        // rename 開始時点で Space パン modifier が張り付いていると、rename 中は key_up を
        // 素通りさせない設計（下記イベントポンプ参照）のため解除しておく（codex レビュー指摘
        // 2026-07-05: rename 前に Space が押されたまま rename に入ると space_down が残留しうる）。
        self.space_down = false;
    }

    /// 編集を確定する（ENTER）。`doRenameLayer` へ委譲し Undo へ積む。失敗（境界外等）は無視
    /// （他の pending file op 等と同型の「UI からの呼び出しはベストエフォート」扱い）。
    fn commitRenameLayer(self: *App) void {
        if (!self.rename_in.active) return;
        const idx = self.rename_in.layer_idx;
        const committed = self.rename_in.commit();
        self.doRenameLayer(idx, committed) catch {};
    }

    /// 編集を取り消す（ESCAPE）。バッファは破棄するだけで Undo には積まない。
    fn cancelRenameLayer(self: *App) void {
        self.rename_in.cancel();
    }

    /// renaming 中の key_down を処理する（メインループのイベントポンプから、通常の
    /// `handleKey` の代わりに呼ばれる）。ENTER/KP_ENTER=確定・ESCAPE=取消・
    /// BACKSPACE/DELETE=1文字削除。Cmd+C/X/V はテキスト clipboard（pixel clipboard へ流さない）。
    /// composition 中の C/X/V は抑止。それ以外はすべて無視。
    fn handleRenameKey(self: *App, k: platform.KeyEvent) void {
        if (self.handleTextFieldClipboard(k, .rename)) return;
        if (k.key == .ENTER or k.key == .KP_ENTER) {
            self.commitRenameLayer();
        } else if (k.key == .ESCAPE) {
            self.cancelRenameLayer();
        } else if (k.key == .BACKSPACE or k.key == .DELETE) {
            self.rename_in.backspace();
        }
        // その他のキーは無視（ツール切替ショートカット等を遮断）
    }

    // ── テキストレイヤー（TASK-79.5）─────────────────────────────

    /// テキストレイヤーを新規追加する（右クリックメニュー「Add Text Layer」）。既定
    /// テキスト "Text" / font_px=16 / 現在のパレット色 / 位置(8,8) で作成し選択する。
    /// Undo は既存 `.layer_add`（Layer 値コピーに kind/text_params が自動的に乗るため
    /// Op 変更は不要。`doAddLayer` と同じ仕組み）。
    fn doAddTextLayer(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        var params: core.TextParams = .{ .x = 8, .y = 8, .color = self.palette.current() };
        params.setText("Text");
        _ = self.doc.addTextLayer(self.gpa, params) catch |err| {
            self.setSaveMsg("Text layer add failed: {s}", .{@errorName(err)});
            return err;
        };
    }

    /// テキストレイヤーの text_params を更新し再ラスタライズする（内容確定・サイズ/位置
    /// スライダー・色ボタンの共通適用口。TASK-79.5）。`Document.setLayerTextParams` が
    /// 冪等 no-op 判定・共有cel再ラスタライズ・Op構築+push を完結する。
    fn doSetTextParams(self: *App, idx: usize, params: core.TextParams) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        try self.doc.setLayerTextParams(self.gpa, idx, params);
    }

    /// テキストレイヤーを通常 raster レイヤーへ確定する（Rasterize。右クリックメニュー。
    /// TASK-79.5）。pixels 不変・kind/text_params のみ変化。Undo 1 回で戻せる。
    fn doRasterizeLayer(self: *App, idx: usize) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        _ = try self.doc.rasterizeLayer(self.gpa, idx);
    }

    /// レイヤー右クリックメニュー「Edit Text...」（kind==text の時のみ有効）から呼ぶ。
    /// 現在テキストを編集バッファへコピーしてインライン編集を開始する（確定は
    /// `commitTextEdit`、取消は `cancelTextEdit`）。`rename_in`/`text_in` は対称実装。
    fn beginTextEdit(self: *App, idx: usize) void {
        if (idx >= self.canvas.layers.items.len) return;
        if (self.canvas.layers.items[idx].kind != .text) return;
        self.rename_in.cancel(); // rename/text 編集は同時に active にしない（beginRenameLayer と対称）
        self.text_in.begin(idx, self.canvas.layers.items[idx].text_params.text());
        self.space_down = false; // beginRenameLayer と同じ理由（Space 残留防止）
    }

    /// 編集を確定する（ENTER）。`doSetTextParams` へ委譲する（色/サイズ/位置は現状値を維持し
    /// 文字列だけ更新）。失敗（境界外等）は無視（他の pending file op 等と同型）。
    fn commitTextEdit(self: *App) void {
        if (!self.text_in.active) return;
        const idx = self.text_in.layer_idx;
        const committed = self.text_in.commit();
        if (idx >= self.canvas.layers.items.len) return;
        var params = self.canvas.layers.items[idx].text_params;
        params.setText(committed);
        self.doSetTextParams(idx, params) catch {};
    }

    /// 編集を取り消す（ESCAPE）。バッファは破棄するだけで Undo には積まない。
    fn cancelTextEdit(self: *App) void {
        self.text_in.cancel();
    }

    /// テキスト編集中の key_down を処理する（`handleRenameKey` と対称）。
    fn handleTextEditKey(self: *App, k: platform.KeyEvent) void {
        if (self.handleTextFieldClipboard(k, .text)) return;
        if (k.key == .ENTER or k.key == .KP_ENTER) {
            self.commitTextEdit();
        } else if (k.key == .ESCAPE) {
            self.cancelTextEdit();
        } else if (k.key == .BACKSPACE or k.key == .DELETE) {
            self.text_in.backspace();
        }
        // その他のキーは無視（ツール切替ショートカット等を遮断）
    }

    const TextFieldClipboardTarget = enum { rename, text };

    /// rename / text 編集中の Cmd+C/X/V。消費したら true（pixel clipboard・tool shortcut へ流さない）。
    /// composition（preedit あり）中は C/X/V を抑止して消費扱い。
    fn handleTextFieldClipboard(self: *App, k: platform.KeyEvent, target: TextFieldClipboardTarget) bool {
        const accel = k.modifiers.cmd or k.modifiers.ctrl;
        if (!accel or k.is_repeat) return false;
        if (k.key != .C and k.key != .X and k.key != .V) return false;
        if (self.preedit().len > 0) return true; // composition 中は抑止（消費）
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
                var buf: [96]u8 = undefined; // text_content max; rename は短いので共用で足りる
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

    /// 明示 index のレイヤーを複製し、直上へ挿入する（Duplicate。TASK-79.2。TASK-94 Phase B で
    /// selected 暗黙参照を排除）。戻り値は新規レイヤーの LayerId raw（action 応答用）。
    /// `Document.duplicateLayer` が raster(各frame深いコピー)/text(新規cel全frameリンク)の
    /// 分岐込みで mutation + Op構築 + push を完結する（4.4/4.5節）。
    fn doDuplicateLayer(self: *App, idx: usize) !u64 {
        if (self.editingBlocked()) return error.EditingBlocked;
        const new_idx = self.doc.duplicateLayer(self.gpa, idx) catch |err| {
            self.setSaveMsg("Layer duplicate failed: {s}", .{@errorName(err)});
            return err;
        };
        return @intFromEnum(self.doc.layerIdAt(new_idx).?);
    }

    /// 明示 index のレイヤーを直下のレイヤーへ結合する（Merge Down。TASK-79.2。TASK-94 Phase B で
    /// selected 暗黙参照を排除）。選択中レイヤー(top)の内容を opacity 込みで下位レイヤー
    /// (bottom=top-1)へ src-over 焼き込みし、top 自体を削除する。最下層（index 0）は結合先が
    /// 無いため error.OutOfRange。
    ///
    /// 「下位への合成」と「上位の削除」という 2 つの構造変化は、libs/paint の atomic な
    /// `.layer_merge_down` Op（undo.zig, TASK-79.2）へ **1 push** で表現する（2 つの UndoCmd に
    /// 分けると、片方だけ undo された状態で別操作が push された際に古い座標参照が残り不整合を
    /// 起こし得るため。codex レビュー指摘 2026-07-05）。
    ///
    /// ホットパス宣言: イベント時のみ（結合ボタン/メニュー項目クリック時に1回）。下位レイヤーの
    /// 全画素(256x256)を走るが event-time の1回ループであり、フレーム毎ではない
    /// （`Canvas.composite`/`UndoStack.pushClear` と同じ既存前例に倣うスカラーループで足りる。
    /// 性能規約の SIMD 3点セット等は対象外）。
    ///
    /// **TASK-79.5**: top・bottom いずれかが `kind==.text` なら `error.TextLayerSelected` で
    /// 拒否する（「選択中レイヤーが text か」だけでは top=raster(選択中)・bottom=text の組を
    /// 見逃す＝bottom の pixels が直接書き換えられ「text layer の pixels は text_params からの
    /// 再ラスタライズ結果」という不変条件を破る。codex レビュー指摘 2026-07-05）。
    /// `Document.mergeDown` が frame数1制限（9.1節MVP制限）込みで mutation + Op構築 + push を
    /// 完結する（below の焼き込み・top の削除を1 push でatomicに。plan 4.5/5.3節）。
    fn doMergeDown(self: *App, idx: usize) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        try self.doc.mergeDown(self.gpa, idx);
    }

    // ── タイムライン（TASK-45.2）──────────────────────────────────

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

    /// フレーム境界の再生 tick（毎フレーム 1 回・f64 比較のみ。全画素・RT 非該当）。
    /// 実効間隔 = playbackIntervalSec(fps, 現在 frame の duration_ms)。追いつき無し（1 tick で 1 frame）。
    ///
    /// `timeline_last_advance` は play 開始時（UI / action play）に `getTime()` で seed する。
    /// 旧実装の `last==0` 再 seed は、仮想クロックが 0 起点のとき毎 tick で上書きされ
    /// （advance 前は last が 0 のまま残る）step 数をずらすため行わない（TASK-45.4）。
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

    /// PNG open 用: doc/active_view を「1layer・1frame・1cel(空)」状態へ縮める
    /// （`Document.resetToSingleBlankLayer`。undo/redo も内部で破棄される。plan 8.5節）。
    fn resetCanvasToSingleLayer(self: *App) void {
        self.doc.resetToSingleBlankLayer(self.gpa);
        self.sel_in.discardFloat(self.gpa); // フロートも破棄
        self.invalidateHistoryAfterDocReset(); // 旧 document への framework redo を失効（review 反映）
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
        // selection も同期（bezier プレビューが描画制約を commit と一致させる。TASK-44）
        self.preview_canvas.selection = self.canvas.selection;
        // 上の @memcpy / visible / opacity は Canvas API を通らない直接書きのため、
        // composite_cache を明示的に無効化する（TASK-53 の dirty フラグ導入に伴う）
        self.preview_canvas.markDirty();
    }

    /// 描画用の straight-alpha composite を返す（ベジェ/選択プレビュー時は preview_canvas）。
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

    /// File/Edit/View の共通実行入口（TASK-97.2）。
    /// keyboard / GUI メニュー / menu_command イベントがここに集約する。
    /// File 系は pending_file_op へ積むだけ（ダイアログは runPendingFileOp 安全点）。
    /// Undo/Redo は既存 doUndo/doRedo（ハイブリッド userUndo + netsync route）を維持し、
    /// 結果と undo 記録を変えない。
    fn dispatchCommand(self: *App, id: platform.CommandId) void {
        // TASK-144.2: size_dialog 中は他メニューコマンドを通さない（recovery/confirmation の
        // 早期 continue と同じ「開いている間は横取り」方針。native keyEquivalent / menuBarPopup
        // 経由の reentrant open・confirmation 二重表示・layer 操作を防ぐ）。
        // Esc/Enter は key_down 経路で処理され、ここは通らない。
        if (self.size_dialog != null) return;
        // stale event / disabled 項目の最終防御: 共通入口で Command 表の存在 + enabled を
        // 再検証する。GUI click / shortcut は各自チェック済みだが、native/harness の
        // menu_command イベントは ID をそのまま運ぶため、状態更新後の stale event でも
        // disabled 項目を実行しない（エラーでなく無視）。
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
            CmdId.toggle_panel => self.right_visible = !self.right_visible,
            CmdId.toggle_timeline => self.bottom_visible = !self.bottom_visible,
            else => {},
        }
    }

    /// Command 表から id を検索（separator は対象外）。dispatchCommand の最終防御用。
    fn findMenuCommand(self: *const App, id: platform.CommandId) ?platform.Command {
        if (id == 0) return null;
        for (self.menu_commands[0..self.menu_command_count]) |cmd| {
            if (cmd.kind == .separator) continue;
            if (cmd.id == id) return cmd;
        }
        return null;
    }

    /// 現在の app 状態から Command 表を再構築（checked = Panel/Timeline 表示状態）。
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

        put(self, &n, .{ .id = CmdId.toggle_panel, .label = "Panel", .menu = .{ .title = "View", .order = 300 }, .checked = self.right_visible });
        put(self, &n, .{ .id = CmdId.toggle_timeline, .label = "Timeline", .menu = .{ .title = "View", .order = 301 }, .checked = self.bottom_visible });

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

    /// enabled/checked 変化時のみ updateMenu。構造変化時は registerMenu。
    /// 毎フレームの ObjC ブリッジ呼び出しを dirty-gate で禁止（TASK-97.3 付記）。
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

    /// GUI fallback 環境のショートカット照合（single-owner = アプリ側。TASK-97.2 plan 4）。
    /// primary accel は cmd または ctrl（既存 handleKey と同じ）。
    /// native メニュー有効時は keyEquivalent が所有するため呼ばない（AC#2）。
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
        // Space はパン用 modifier（押下継続を追跡。解放は handleKeyUp）。他処理には回さない。
        if (k.key == .SPACE) {
            self.space_down = true;
            return;
        }
        // ベジェ編集中はツール固有キーを横取り（Enter=確定 / Esc=キャンセル / Delete・Backspace=点削除）
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
        // 保存系などのアクセラレータ修飾: macOS=Cmd / Linux=Ctrl。
        // Linux(GNOME 等)は Super(=cmd) を WM が予約してアプリに届かないため Ctrl も受ける
        // （Ctrl+S 等は Linux の保存の慣習にも合致。macOS は従来どおり Cmd で、Ctrl も追加で効く）。
        const accel = k.modifiers.cmd or k.modifiers.ctrl;
        if (k.key == .ESCAPE) {
            // メニュー表示中の Esc はメニューを閉じるだけ（アプリ終了に落とさない）。
            // popup 本体は次の menuBarPopup が open_title==null を見て閉じる。
            if (self.menu_bar_state.open_title != null) {
                self.menu_bar_state.open_title = null;
                return;
            }
            // シェイプ/選択ドラッグ中なら破棄 → 選択(またはフロート)があれば解除 → それ以外は終了
            if (self.shape_in.state != .idle) {
                self.shape_in.cancel();
            } else if (self.sel_in.state != .idle) {
                self.sel_in.cancel(self.gpa); // drag 中断（フロート破棄・実レイヤーは drag 中不変）
            } else if (self.canvas.selection != null or self.sel_in.float != null) {
                self.canvas.clearSelection();
                self.sel_in.discardFloat(self.gpa);
            } else {
                if (self.os_window) |win| self.requestClose(win);
            }
        } else if (k.key == .Q and accel) {
            if (self.os_window) |win| self.requestClose(win);
        } else if (blk: {
            // native 有効時は keyEquivalent がショートカットを所有（AC#2）。GUI/headless のみ照合。
            break :blk if (self.native_menu_active) null else self.matchMenuShortcut(k);
        }) |cmd_id| {
            // File/Edit ショートカットは Command 表経由（single-owner。GUI メニューと同じ入口）。
            self.dispatchCommand(cmd_id);
        } else if (k.key == .C and accel) {
            self.doCopy(); // accel+C は copy（bare C の clear より前に判定）
            // システム clipboard へ現在色 #RRGGBB（wasm Clipboard API。TASK-73.3）
            self.copySystemColor();
        } else if (k.key == .X and accel) {
            self.doCut();
        } else if (k.key == .V and accel) {
            self.doPaste();
            // システム clipboard から色 paste を非同期要求（結果は runPendingFileOp で適用）
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
            self.setActiveKind(.eyedropper); // Photoshop/GIMP 慣習のキー割当（一時スポイトは Alt+クリック）
        } else if (k.key == .C) {
            self.doClear() catch {};
        } else if (k.key == .@"0") {
            self.setZoomCentered(1); // 100% (1x) 中央リセット
        } else if (k.key == .F) {
            self.fitZoom();
        } else if (k.key == .KP_ADD) {
            // カーソル位置は updateViewport 時に確定するため保留（zoom-to-cursor）
            self.pending_zoom_delta += 1;
        } else if (k.key == .KP_SUBTRACT) {
            self.pending_zoom_delta -= 1;
        }
    }

    /// key_up 処理。現状は Space パン modifier の解放のみ。
    fn handleKeyUp(self: *App, k: platform.KeyEvent) void {
        if (k.key == .SPACE) self.space_down = false;
    }

    /// ベジェ確定（現在ブラシ footprint + color/opacity で rasterize → `Document.pushPaintOp`）。
    fn commitBezier(self: *App) void {
        const dab = self.brush.footprint();
        if (self.bezier_editor.rasterizeCommit(self.canvas, &self.recorder, self.gpa, dab, self.brush.color, self.brush.opacity)) |pd| {
            self.doc.pushPaintOp(self.gpa, pd.layer_idx, pd.diffs) catch {}; // text layer 選択中はこの経路に到達しない
        }
    }
};

// ============================================================================
// ヘッドレス検証 harness の custom probe（TASK-32.3）
//
// `platform.registerProbe` で opt-in 登録する。framework は中身を解釈せず、snapshot の raw bytes を
// file へ書き / digest の1行を sink へ流すだけ。各 probe の意味づけは下の callback に閉じる。
// ctx は *App。harness 無効時は登録自体が no-op なので通常実行に影響しない。
// ============================================================================

/// canvas digest: サイズ / layer 数 / selected / composite crc / layer metadata。
/// 1024B に入り切らない場合は打ち切り、top-level `trunc=1` を末尾に付与（TASK-94 Phase B P2）。
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
    // viewport 観測値（TASK-153.1）。top-level key=value。layers より前に置き trunc でも harness が拾えるようにする。
    {
        const doc_w = app.doc.width;
        const doc_h = app.doc.height;
        const zoom = app.view_zoom;
        if (app.last_area) |a| {
            const origin = displayOrigin(app, a);
            const vp = std.fmt.bufPrint(buf[len..], " doc_w={d} doc_h={d} area_x={d} area_y={d} area_w={d} area_h={d} zoom={d} origin_x={d} origin_y={d} cam_cx={d:.3} cam_cy={d:.3}", .{
                doc_w, doc_h, a.x, a.y, a.w, a.h, zoom, origin.x, origin.y, app.cam_cx, app.cam_cy,
            }) catch {
                truncated = true;
                return actions.finishDigestWithTrunc(buf, len, truncated);
            };
            len += vp.len;
        } else {
            const vp = std.fmt.bufPrint(buf[len..], " doc_w={d} doc_h={d} zoom={d} cam_cx={d:.3} cam_cy={d:.3}", .{
                doc_w, doc_h, zoom, app.cam_cx, app.cam_cy,
            }) catch {
                truncated = true;
                return actions.finishDigestWithTrunc(buf, len, truncated);
            };
            len += vp.len;
        }
    }
    for (app.canvas.layers.items, 0..) |layer, idx| {
        var nonzero: usize = 0;
        for (layer.pixels) |p| {
            if (p != 0) nonzero += 1;
        }
        const crc = png.crc32(std.mem.sliceAsBytes(layer.pixels));
        // id= を nested 先頭へ（TASK-94 Phase B review: agent が #id を発見する手段）。
        // nested は expect contains 規約。1024B 予算のため id は短い u64 十進のみ追加。
        const layer_id: u64 = if (app.doc.layerIdAt(idx)) |lid| @intFromEnum(lid) else 0;
        // kind=text の時だけ text= を nested 内へ追加する（TASK-79.5。既存 name= と同じ
        // 「nested は contains で見る」規約。text_content_input が ASCII 制御文字を弾くため
        // 改行等の混入は無い＝1行契約は保たれる）。
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

/// canvas snapshot: visible layer を合成したフラット透明 PNG。
fn canvasSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    return core.encodePNG(app.canvas.compositeStraight(), app.doc.width, app.doc.height, allocator);
}

/// undo digest/snapshot: undo/redo スタックの深さ（JSON 1行）。undo で depth が減る。
fn undoDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    return std.fmt.bufPrint(buf, "{{\"depth\":{d},\"redo\":{d}}}", .{
        app.doc.undo.undo.items.len, app.doc.undo.redo.items.len,
    }) catch buf[0..0];
}

/// presence digest（TASK-103）: ephemeral overlay 状態。TTL 期限切れは除去してから出力。
fn presenceDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    return app.presence.formatDigest(buf, platform.getTime());
}

/// menu digest（TASK-97.2）: 開閉・項目数・enabled/checked mask・pending_file_op。
/// `open=<title|none> items=<n> enabled=<hex> checked=<hex> pending=<tag|none>`
/// enabled/checked は非 separator 項目の出現順ビット（bit0=先頭の item）。
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
    // pending = 実際に未消費の FileOp（dialog 進行中を優先。真の状態）。
    // last_op = 直近に dispatch された FileOp のラッチ（次の dispatch まで保持。headless では
    // 同フレームで消費されるため「メニュー選択が FileOp を積んだ」ことはこちらで観測する）。
    const live_pending = app.dialog_op orelse app.pending_file_op;
    const pending = if (live_pending) |op| @tagName(op) else "none";
    const last_op = if (app.menu_pending_probe) |op| @tagName(op) else "none";
    // native=0|1: OS native メニュー（NSMenu）が有効か（TASK-97.3 hotfix で追加。
    // headless は常に 0 / macOS 実 window + enable_menu ビルドで 1。実機検証の機械 assert 用）。
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
    // TASK-117: geometry を additive で載せる（headless=サイズのみ/pos=none。配線 silent false 検出用）。
    const geo = if (app.os_window) |win| win.getGeometry() else platform.WindowGeometry{
        .position = null,
        .size = .{ .width = 0, .height = 0 },
    };
    var pos_buf: [48]u8 = undefined;
    const pos = if (geo.position) |p|
        (std.fmt.bufPrint(&pos_buf, "{d},{d}", .{ p.x, p.y }) catch "err")
    else
        "none";
    return std.fmt.bufPrint(buf, "dirty={d} path={s} confirm={s} recent={d} recent0={s} recovery={s} autosave={d} netsync={d} title={s} geom={d}x{d} pos={s}", .{
        @intFromBool(app.host.isDirty()),
        path,
        @tagName(app.host.confirmation()),
        app.recent.items().len,
        recent0,
        recovery,
        @intFromBool(activeAutosavePresent(app)),
        @intFromBool(platform.netsyncActive()),
        title,
        geo.size.width,
        geo.size.height,
        pos,
    }) catch buf[0..0];
}

fn activeAutosavePresent(app: *const App) bool {
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

/// tool digest/snapshot: 現在ツール名 + 描画色 #RRGGBB。
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

/// timeline digest（TASK-45.4）: 再生状態を top-level k=v 1 行で公開（snapshot なし・expect 適合）。
/// 形式: `playing=<0|1> frame=<n> frames=<n> fps=<f:.1> dur=<ms> layers=<n> onion=<0|1>`
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
fn toolSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    var buf: [128]u8 = undefined;
    return allocator.dupe(u8, toolDigest(ctx, &buf));
}

/// diff digest（TASK-87）: 基準スナップショットとの変更画素数 / bbox / 最頻 before・after 色。
/// 初回（未 mark）は現 composite を基準として自動初期化し changed=0 を返す。snapshot なし。
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

/// palette digest（TASK-89）: パレット色数 / canvas 一意色数 / 上位 4 色（fb top 書式整合）。
/// イベント時のみ（compositeStraight + AutoHashMap ヒストグラム）。
fn paletteDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const flat = app.canvas.compositeStraight();
    const n = flat.len;
    var counts = std.AutoHashMap(u32, u32).init(app.gpa);
    defer counts.deinit();
    for (flat) |p| {
        // 完全透明は used に含めない（表示色統計）
        if (p & 0xFF000000 == 0) continue;
        const c = 0xFF000000 | (p & 0x00FFFFFF);
        const gop = counts.getOrPut(c) catch return buf[0..0];
        if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
    }
    const used = counts.count();
    // 上位 4 色（count 降順・同数は color 昇順）
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
    // 分母は全画素（透明含む）で fb digest と同じ % 規約
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

/// compositeStraight を diff_base へコピー（未確保なら alloc）。借用スライスは保持しない。
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

/// cursor digest/snapshot（TASK-75.4）: 要求中の OS cursor shape + 現在ツール + footprint リング半径。
/// OS カーソル自体は framebuffer に写らないため、「pixie が要求した値」を assert する用途
/// （実際に OS カーソルが変わったかは各 backend 手動目視。docs/plans/cursor-support-plan.md 参照）。
fn cursorDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const shape_name: []const u8 = switch (app.cursor_shape) {
        .default => "default",
        .crosshair => "crosshair",
        .hidden => "hidden",
    };
    // ring_r は Brush 選択時のみ意味を持つ（それ以外は 0）。EdgeCache と同じ clampedSize 経由で
    // size 解釈をズレさせない（brush_edge_cache.clampedSize 参照）。
    const ring_r: u32 = if (app.active_kind == .brush) brush_edge_cache.clampedSize(&app.brush) / 2 else 0;
    return std.fmt.bufPrint(buf, "shape={s} tool={s} ring_r={d}", .{
        shape_name, app.active_kind.name(), ring_r,
    }) catch buf[0..0];
}
fn cursorSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    var buf: [128]u8 = undefined;
    return allocator.dupe(u8, cursorDigest(ctx, &buf));
}

/// CommandAdapter（TASK-62.5.4 §4a）: framework undo の逆適用口。
/// canUndo = handle 現存 + .paint + cel 生存 + 位置前提（`Document.canRevertByHandle`）。
/// applyUndo は**不可失敗契約**（canUndo==true 前提で呼ばれる。万一の handle 消失時も
/// `revertByHandle` が no-op で戻るだけ = 部分 undo なし）。mode=.discard（記録済み op の redo は
/// CommandLog の name/args 再 dispatch で行うため Op は破棄）。resyncActiveView は revertByHandle
/// 内部・clampTimelineTarget 等の App 同期は undo/redo 呼び出し側の責務（既存 doUndo と同じ分担）。
/// 構造 Op 制約・pixel 巻き添え artifact の割り切りは `Document.canRevertByHandle`/`revertByHandle` 参照。
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

fn historyCtx(app: *App) history_summary.HistoryContext {
    return .{
        .ctx = app,
        .hasHandle = historyHasHandle,
        .log = &app.cmd_log,
        .getVisualMeta = historyGetVisualMeta,
    };
}

/// history probe（TASK-62.5.5 正式 schema）: digest=最新+集計（expect 用）、snapshot=全件 JSON。
fn historyDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    return history_summary.formatDigest(historyCtx(app), buf);
}

fn historySnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    return history_summary.formatSnapshotJson(historyCtx(app), allocator);
}

// ============================================================================
// ヘッドレス検証 harness の custom action（TASK-64。TASK-62.1 の registerAction を pixie が採用）
//
// `platform.registerAction` で opt-in 登録する。probe（read）と対称の write/operate 口。
// 全 action は既存の UI/キーボードと同じ `App.do*` メソッドを呼ぶだけ（入口の一本化＝
// undo単位=action単位。UI/キーボード/action の3経路が同じ判定コード＝ do* 内のガードを通る）。
// パーサは `actions.zig`（std のみ・App/kit/platform 非依存）に切り出し単体テストする。
//
// action ⇄ UndoCmd 対応表（push は「この action 呼び出しで undo.push が起きるか」。
// 高々1回＝0 or 1。複数回 push する action は無い）:
//
//   action              → App メソッド          push  失敗時の error
//   ------------------  ---------------------  ----  --------------------------------
//   undo                cmd_exec.undoOne(.local_agent)  no*   EditingBlocked（候補なしは冪等成功。TASK-62.5.4
//   redo                cmd_exec.redoOne(.local_agent)  no*   で per-actor revert 化。UI の Cmd+Z は userUndo/userRedo）
//   clear               doClear                 yes   EditingBlocked
//   add_layer           doAddLayer              yes   EditingBlocked / allocator error
//   delete_layer        doDeleteLayer(idx)      yes   EditingBlocked / LastLayer / UnknownLayerId（TASK-94: args=`#<id>`|idx）
//   select_layer        doSelectLayer           no    EditingBlocked / OutOfRange / UnknownLayerId（.local_only）
//   set_layer_visible   doSetLayerVisible       yes*  EditingBlocked / OutOfRange / UnknownLayerId
//   set_layer_opacity   doSetLayerOpacity       yes*  EditingBlocked / OutOfRange / UnknownLayerId
//   move_layer          doMoveLayer(idx,δ)      yes   EditingBlocked / OutOfRange / UnknownLayerId（args=`#<id> ±1`）
//   duplicate_layer     doDuplicateLayer(idx)   yes   EditingBlocked / allocator error / UnknownLayerId（TASK-79.2）
//   merge_down          doMergeDown(idx)        yes   EditingBlocked / OutOfRange / LastLayer / UnknownLayerId（TASK-79.2。
//                                                      atomic `.layer_merge_down` 1 entry。2 push ではない）
//   ※ layer 構造 op は canRevertByHandle=false → noteUndo せず wire 上 undoable=false（62.3.5 MVP）
//   ※ add/delete/visible/opacity/move/duplicate/merge_down は .relay、select_layer は .local_only（TASK-94 B）
//   set_color           doSetColorHex           no    （guard 無し。常に成功）
//   set_tool            setActiveKind           no    （guard 無し。既存 UI と同じ「無反応」を許容）
//   stroke              activeTool().onEvent 直接 yes  EditingBlocked / UnsupportedTool / parse系
//   save                doSaveTo                no    savePNG の元 error
//   open                doOpenPath              no    EditingBlocked / decode 系
//   replace_color       doReplaceColor(layer)   yes*  EditingBlocked / TextLayer / OutOfRange / IdRequired / parse系
//                                                      args=`[#id|idx] from to`（省略時 selected。netsync 中は #id 必須）
//   palette_ramp        doReplacePalette        no    parse系（パレット変更は undo 対象外。.reject_when_synced）
//   palette_from_png    doReplacePalette        no    EmptyPalette / decode 系（.reject_when_synced）
//   palette_set         doReplacePalette        no    parse系（.reject_when_synced）
//
//   * before==after の冪等呼び出しは push 無し（既存 UI のスライダー/チェックボックス挙動と同じ）。
//
//   TASK-79.5（テキストレイヤー: doAddTextLayer/doSetTextParams/doRasterizeLayer）には action を
//   追加していない。harness の action registry は `MAX_ACTIONS=16`（core/control/harness.zig）
//   固定で pixie は既に 16 件を使い切っており、harness.zig 改変はスコープ外（AGENT.md 上位
//   ルール）のため空き slot が無い。これらは UI 操作（右クリックメニュー + `inject char`
//   による文字入力）で harness 検証する。
//
// 非 push action（select_layer/set_color/set_tool/save/open/undo/redo 自体）が undo 対象外なのは
// 新たな非一貫ではない: 既存 UI でも同じ操作（ツール切替キー・HSV スライダー・ファイル I/O）は
// undo.push を呼ばない設計だった（`applyEditColor`/`setActiveKind`/`doSave` 参照）。本タスクの主眼は
// 「UI が辿る undo 判定と全く同じコードを agent（action）からも辿れるようにする」ことで、UndoCmd
// 自体の構造拡張（tool/color の履歴化等）はスコープ外（TASK-64 plan 参照）。
//
// 将来 TASK-65（他アプリへの action 横展開）/ network（TASK-62.3）への申し送り: action 呼び出し列
// （name+args）がそのまま「ネットワークで流す操作ストリーム」の単位になる、という設計意図をここに
// 残す。UndoCmd の pixel diff は各ノードでの決定的 re-apply の実装詳細であり、ネットワーク越しに
// 流す粒度ではない。
// ============================================================================

fn actionApp(ctx: *anyopaque) *App {
    return @ptrCast(@alignCast(ctx));
}

/// action `undo`/`redo`（agent。TASK-62.5.4 §4b）: **executeAction を経由せず** framework の
/// `undoOne`/`redoOne(.local_agent)` を直接呼ぶ登録 callback（undo/redo は begin_tx と同種の
/// **制御コマンド**。executeAction 経由だと redoOne の内部再 dispatch が `ReentrantDispatch` に
/// なるため構造的に不可）。既存ガード（editingBlocked）と実行後の App 同期（clampTimelineTarget）
/// は従来 doUndo/doRedo と同じ。agent 操作は全て記録済みなのでハイブリッド（userUndo）は不要。
fn actionUndo(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    try actions.parseNoArgs(args);
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    const seq_before = app.cmd_log.next_seq;
    // defer: undoOne が失敗しても record フラグの変異は起きうる（next_seq 非依存のため
    // dirty で拾う。codex 指摘）
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
    // defer: redoOne は途中失敗でも redo_consumed を更新しうる（next_seq 不変のケースが
    // あるため dirty で拾う。codex 指摘）
    defer app.markHistoryDirty();
    const outcome = app.cmd_exec.redoOne(.local_agent, buf) catch |err| {
        app.tagOwnersFromRecords(seq_before, App.OP_OWNER_AGENT); // PartialRedo でも適用済み分はタグ
        app.captureHistoryVisualsSince(seq_before);
        return err;
    };
    app.tagOwnersFromRecords(seq_before, App.OP_OWNER_AGENT); // 再 dispatch された新 op は agent 所有
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

/// LayerRef → 現在の index。stale id は `unknown_layer_id`、範囲外 index は `index_out_of_range`。
/// `require_id_during_netsync=true`（.relay layer op）かつ netsync 中の bare index は `id_required`。
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
    // select_layer は .local_only（per-peer view）なので netsync 中も bare index を許容。
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

/// `add` で空フレーム追加、`select <idx>` でフレーム選択（harness 向け。registry 節約のため1名）。
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

/// `action shape <line|rect|ellipse> <p0> <p1> [fill]`（TASK-90）。
/// `App.doShape` 経由（UI 確定と同じ描画/undo 経路）。agent 操作の undo は `action undo`
/// （Cmd+Z は local_user 専用のハイブリッド。既存 stroke action と同型）。
fn actionShape(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    const parsed = try actions.parseShape(args, @intCast(app.doc.width), @intCast(app.doc.height));
    try app.doShape(parsed.kind, parsed.p0, parsed.p1, parsed.fill);
    return "ok";
}

/// `action set_symmetry <off|v|h|quad>`（TASK-90）。document 描画に影響 → .relay。
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

/// `action set_pixel_perfect <0|1>`（TASK-90）。Pen 描画に影響 → .relay。
fn actionSetPixelPerfect(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    app.doSetPixelPerfect(try actions.parsePixelPerfect(args));
    return "ok";
}

/// canvas 座標の点列を down→move×N→up で直接駆動する（既存 canvas_input と同じ Tool 経路）。
/// TASK-62.5.3 §5c': `[tool=|color=|size=|opacity=|hardness=]` の k=v 前置を受け、明示された
/// パラメータを**一時的に latch して実行後に元の App 状態へ復元**する（redo が現在のユーザー
/// 設定を壊さない）。パラメータ無しは従来どおり現在状態を使う（TASK-64 文法と後方互換。
/// fill は tool= で表現できない legacy 経路として従来どおり現在ツールで実行する）。
/// bezier/select/eyedropper は従来どおり明示的に弾く（`activeTool()` の到達しないフォールバック
/// による意図しない Pen 描画の回避）。
fn actionStroke(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    var pts_buf: [actions.MAX_STROKE_POINTS]actions.Point = undefined;
    const parsed = try actions.parseStroke(args, &pts_buf);
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

    // 実効パラメータの解決と latch。fill（tool= 無し + active_kind==.fill）のみ legacy 経路。
    var tool: core.Tool = undefined;
    const saved_pen_color = app.pen.color;
    const saved_brush_color = app.brush.color;
    const saved_brush_size = app.brush.size;
    const saved_brush_opacity = app.brush.opacity;
    const saved_brush_hardness = app.brush.hardness_q;
    defer {
        app.pen.color = saved_pen_color;
        app.brush.color = saved_brush_color;
        app.brush.size = saved_brush_size;
        app.brush.opacity = saved_brush_opacity;
        app.brush.hardness_q = saved_brush_hardness;
    }
    if (app.resolveEffectiveStroke(parsed.params)) |eff| {
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
        }
    } else |err| {
        // tool= 無しで現在ツールが fill → 従来どおり現在状態で実行（TASK-64 後方互換）。
        // bezier/select/eyedropper は従来どおり UnsupportedTool。
        if (app.active_kind != .fill or parsed.params.tool != null) return err;
        tool = app.activeTool();
    }

    _ = tool.onEvent(app.canvas, &app.recorder, app.gpa, .{ .down = .{ .x = pts[0].x, .y = pts[0].y } });
    var cmd: ?core.PaintDiff = null;
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
        // structured error（TASK-62.5.9）: 読込失敗（png は FileNotFound 等を ReadFailed に正規化）は
        // 自己回復ヒントを wire に載せる。
        if (err == error.ReadFailed or err == error.FileNotFound) {
            platform.setActionErrorDetail("file_not_found", "check path or use save first");
        }
        return err;
    };
    return "ok";
}

/// CommandLog の kind=normal を seq 順（recordAt の古い→新しい）で Entry 化する（TASK-62.5.8）。
/// 返る Entry の name/args は log 内バッファへの借用。スライスは caller が free。
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

/// `replace_color [#<id>|<index>] <from> <to>`（layer 省略時 selected。netsync 中は #id 必須。TASK-89）。
fn actionReplaceColor(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    try app.checkEditingAllowed();
    const p = try actions.parseReplaceColor(args);
    const layer_idx: usize = if (p.layer) |ref|
        try resolveLayerRef(app, ref, true)
    else blk: {
        // 省略 = selected。netsync 中は peer ごとに selected が違うため #id 必須。
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

/// TASK-103: presence_* は recordedAction 非経由・Document/CommandLog/undo 非変更。
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

/// `play`: timeline 再生開始（UI Play ボタンと同一処理）。CommandLog 非記録・冪等。
fn actionPlay(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    try actions.parseNoArgs(args);
    const app = actionApp(ctx);
    app.timeline_playing = true;
    app.timeline_last_advance = platform.getTime();
    return "ok";
}

/// `pause`: timeline 再生停止。CommandLog 非記録・冪等。
fn actionPause(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    try actions.parseNoArgs(args);
    const app = actionApp(ctx);
    app.timeline_playing = false;
    return "ok";
}

/// `goto_frame <idx>`: 表示 frame を選択（doSelectFrame・undo-free）。編集中は拒否。
/// CommandLog 非記録（recordedAction 非経由）。範囲外は structured error。
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

/// `export_seq <stem>`: 連番 PNG 書き出し（CommandLog 非記録・undo 対象外）。
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

/// `export_sheet <path> [columns] [margin]`: スプライトシート書き出し（CommandLog 非記録）。
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

/// `recipe_save <path>`: CommandLog → recipe ファイル（header.app_name="pixie"）。記録しない（メタ操作）。
fn actionRecipeSave(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const path = try actions.parsePath(args);
    const entries = try recipeEntriesFromLog(&app.cmd_log, app.gpa);
    defer app.gpa.free(entries);
    try recipe.save(app.io, path, .{ .app_name = "pixie" }, entries, app.gpa);
    return "ok";
}

/// `recipe_replay <path>`: load → app_name 検証 → 各 entry を routeLocalAction で逐次適用。
/// 失敗で中断（structured error に何番目かを含む）。入れ子 recipe_replay は拒否。
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
            // 入れ子 recipe_replay は内側が nested_replay detail をセット済み → 上書きしない
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

// テキストレイヤー（TASK-79.5）向け action（doAddTextLayer/doSetTextParams/doRasterizeLayer）は
// 未追加のまま（TASK-62.5.3 で MAX_ACTIONS は 32 へ拡張済みで slot は空いたが、追加自体は
// 本タスクのスコープ外）。harness 検証は既存の `inject mouse_down/up` + `inject char` で行う。

// ============================================================================
// command model 統合（TASK-62.5.3）
//
// App が CommandLog + Executor を所有し（常時有効・固定容量）、記録は次の 2 箇所に一元化する:
//   1. registerAction 経由（harness `action` / copilot `action`）→ 下の記録 wrapper が
//      `executeAction(actor=.local_agent)` で実ハンドラ（PIXIE_ACTIONS 表）を dispatch + 記録
//   2. UI の canvas stroke 確定点 → `App.recordUiStroke`（`recordExecuted(actor=.local_user)`）
// undo/redo action は `.no_record`（正規化された undo 表現は 62.5.4 の revert record。normal
// record としてログを汚さない）。undo_ref は `UndoStack.handles` の handle（AC #2 の対応付け）。
// ============================================================================

const ActionEntry = struct {
    name: []const u8,
    run: *const fn (ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8,
};

/// name→実ハンドラ表（`dispatchPixieAction` が引く。登録 wrapper とは分離）。
/// undo/redo は載せない（executeAction/redo 再 dispatch の対象外 = 制御コマンド。§4b。
/// registry へは actionUndo/actionRedo を直接登録する）。
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
    // TASK-89: 末尾追加のみ（並列制約）
    .{ .name = "replace_color", .run = actionReplaceColor },
    .{ .name = "palette_ramp", .run = actionPaletteRamp },
    .{ .name = "palette_from_png", .run = actionPaletteFromPng },
    .{ .name = "palette_set", .run = actionPaletteSet },
    // TASK-90: 末尾追加のみ
    .{ .name = "shape", .run = actionShape },
    .{ .name = "set_symmetry", .run = actionSetSymmetry },
    .{ .name = "set_pixel_perfect", .run = actionSetPixelPerfect },
};

/// `App.cmd_exec` の Dispatcher: name→実ハンドラ dispatch + noteUndo 配線（§5b）。
/// dispatch 前後の undo push 回数を handle 採番カウンタ（`next_handle` の差分 = 「深さ +
/// topHandle」比較の正確化。max_history 満杯時に深さが増えない push も正しく数える）で判定し、
/// **丁度 1 push のときのみ** `noteUndo(topHandle)` する（0 push = non-undoable、2 push 以上 =
/// 1 command = 1 Op の対応が崩れるため noteUndo しない + warn。現行 action set では発生しない想定）。
fn dispatchPixieAction(ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    for (&PIXIE_ACTIONS) |*e| {
        if (std.mem.eql(u8, e.name, name)) {
            const handle_before = app.doc.undo.next_handle;
            const out = try e.run(ctx, args, buf);
            const handle_after = app.doc.undo.next_handle;
            // 防御: 採番は生存期間単調が不変条件（clearHistoryPreservingHandles / doOpenProject の
            // 引き継ぎで維持）だが、万一巻き戻っても unsigned underflow で落とさない（0 push 扱い + warn）。
            const pushes = if (handle_after >= handle_before) handle_after - handle_before else blk: {
                std.debug.print("pixie: action '{s}' で undo handle 採番が巻き戻り（{d}→{d}）。noteUndo を skip\n", .{ name, handle_before, handle_after });
                break :blk 0;
            };
            if (pushes == 1) {
                app.markProjectDirty();
                // 62.3.5 revert は `.paint` のみ（canRevertByHandle）。構造 layer op は push しても
                // adapter 逆適用不能 → noteUndo せず undoable=false（TASK-94 Phase B MVP）。
                if (app.doc.undo.topHandle()) |h| {
                    if (app.doc.canRevertByHandle(h)) app.cmd_exec.noteUndo(h);
                }
                app.last_seen_handle = app.doc.undo.next_handle; // 記録される push（§2b の追従点）
            } else if (pushes >= 2) {
                std.debug.print("pixie: action '{s}' が {d} 回 undo.push（1 command = 1 Op が崩れるため noteUndo しない。62.5.4 申し送り）\n", .{ name, pushes });
            }
            return out;
        }
    }
    return error.UnknownAction;
}

/// registerAction 用の記録 wrapper を comptime 生成する（§5a）。executor 経由で実ハンドラを
/// dispatch し `actor=.local_agent` で記録する。copilot の `begin_tx` で開いた transaction には
/// `openTransactionFor` で自動参加する。`policy=.no_record` は undo/redo 用（dispatch のみ）。
/// layer 系は executeAction 前に index→`#<id>` へ正規化する（TASK-94 Phase B。記録・solo
/// dispatch 経路の args を id 形式に統一。netsync `.relay` は act.run を迂回するため、relay
/// 呼び出し側は canonical args を渡すこと＝stroke の recordedStroke と同型）。
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
            app.tagOwnersFromRecords(seq_before, App.OP_OWNER_AGENT); // 生んだ op は agent 所有（review 反映）
            if (res.seq) |s| app.captureHistoryVisual(s);
            return res.output;
        }
    }.run;
}

/// layer 系 action の args を `#<id>` 形式へ正規化する（非 layer / add_layer はそのまま返す）。
/// solo: 空 args の delete/duplicate/merge_down と bare delta の move_layer は selected の id を付与。
/// netsync 中の .relay 対象（select_layer 以外）: 暗黙 selected / bare index の補完・変換を禁止し
/// `id_required`（peer ごとの selected 補完で diverge するため。TASK-94 Phase B P1）。
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

    // select_layer は .local_only なので netsync 中も index→id 補完を許容。relay 系は禁止。
    const can_fill = (comptime std.mem.eql(u8, name, "select_layer")) or actions.allowLayerCanonFill(platform.netsyncActive());
    const forbid_fill = !can_fill;

    if (comptime std.mem.eql(u8, name, "replace_color")) {
        // `#id RRGGBB RRGGBB` に正規化（.relay で peer が同一 layer に適用するため）。
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
        // 旧形式 `<±1>` → selected id を前置。新形式 `ref ±1` はそのまま id 化。
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
            // 既に id 形式ならそのまま（存在確認は handler 側。stale は適用時 REJECT）。
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

/// `stroke` 専用の記録 wrapper（§5c'）: 入力 args を parse → 実効パラメータ解決（明示 k=v >
/// 現在状態）→ **各 key をちょうど一度だけ含む canonical args** を生成 → canonical args で
/// executeAction（dispatch も canonical を実行するため挙動は入力の意味と同一。CommandLog 上の
/// 全 stroke record が状態非依存に再実行可能になる）。fill の legacy 経路（tool= で表現不能）
/// のみ raw args のまま記録する（従来挙動の互換維持。canonical 化は pen/eraser/brush が対象）。
fn recordedStroke(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var canon_buf: [platform.command.MAX_CMD_ARGS]u8 = undefined;
    const exec_args = App.canonicalizeStroke(app, args, &canon_buf) catch |err| blk: {
        var pts_buf: [actions.MAX_STROKE_POINTS]actions.Point = undefined;
        const parsed = actions.parseStroke(args, &pts_buf) catch return err;
        if (app.active_kind != .fill or parsed.params.tool != null) return err;
        break :blk args; // fill legacy（actionStroke 側も同じ判定で legacy 経路に入る）
    };

    const seq_before = app.cmd_log.next_seq;
    const res = try app.cmd_exec.executeAction("stroke", exec_args, .{
        .actor = .local_agent,
        .transaction = app.cmd_exec.openTransactionFor(.local_agent),
        .record_policy = .record,
    }, buf);
    app.tagOwnersFromRecords(seq_before, App.OP_OWNER_AGENT); // 生んだ op は agent 所有（review 反映）
    if (res.seq) |s| app.captureHistoryVisual(s);
    return res.output;
}

// TASK-88.1: capabilities 用 args シグネチャ（file-scope const。registerActions 直前）。
// `@FieldType(platform.Action, "args")` = `?[]const ArgSpec`。null=未指定 / 空 slice=引数なし明示。
const pixie_args_none: @FieldType(platform.Action, "args") = &.{};
/// 省略可 layer ref（TASK-94: delete/duplicate/merge。省略時 selected。netsync 中は #id 必須）。
const pixie_args_layer_ref_opt: @FieldType(platform.Action, "args") = &.{
    .{ .name = "layer", .kind = "string", .pattern = "#<id>|<index>", .optional = true, .desc = "省略時 selected。netsync 中は #id 必須" },
};
const pixie_args_select_layer: @FieldType(platform.Action, "args") = &.{
    .{ .name = "layer", .kind = "string", .pattern = "#<id>|<index>", .desc = "netsync 中は #id 必須" },
};
const pixie_args_set_layer_visible: @FieldType(platform.Action, "args") = &.{
    .{ .name = "layer", .kind = "string", .pattern = "#<id>|<index>", .desc = "netsync 中は #id 必須" },
    .{ .name = "visible", .kind = "bool", .desc = "0|1" },
};
const pixie_args_set_layer_opacity: @FieldType(platform.Action, "args") = &.{
    .{ .name = "layer", .kind = "string", .pattern = "#<id>|<index>", .desc = "netsync 中は #id 必須" },
    .{ .name = "value", .kind = "int", .min = 0, .max = 255 },
};
const pixie_args_move_layer: @FieldType(platform.Action, "args") = &.{
    .{ .name = "delta", .kind = "enum", .values = &.{ "1", "-1" }, .desc = "+1|-1" },
};
const pixie_args_frame: @FieldType(platform.Action, "args") = &.{
    .{ .name = "sub", .kind = "enum", .values = &.{ "add", "select" } },
    .{ .name = "idx", .kind = "int", .optional = true, .desc = "select 時の frame index" },
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
const pixie_args_stroke: @FieldType(platform.Action, "args") = &.{
    .{ .name = "layer", .kind = "string", .pattern = "#<id>|<index>", .optional = true, .desc = "省略時 selected。canonical wire は #id" },
    .{ .name = "params", .kind = "string", .optional = true, .desc = "tool/color/size/opacity/hardness の k=v" },
    .{ .name = "xy", .kind = "int", .variadic = true, .desc = "canvas 座標 x y の組（偶数個・最低1組）" },
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
// TASK-89 args
const pixie_args_replace_color: @FieldType(platform.Action, "args") = &.{
    .{ .name = "layer", .kind = "string", .pattern = "#<id>|<index>", .optional = true, .desc = "省略時 selected。netsync 中は #id 必須" },
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
    .{ .name = "hex", .kind = "string", .pattern = "#?RRGGBB", .variadic = true, .desc = "1..=64 色" },
};
// TASK-45.4: timeline view actions
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
// TASK-103: presence
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

/// 全 action を一括登録する（`platform.init()` 後・main loop 前に呼ぶ。harness/copilot とも
/// 無効時は `registerAction` 自体が no-op なので通常実行に影響しない）。登録するのは記録
/// wrapper（実ハンドラは `PIXIE_ACTIONS` 表経由で `dispatchPixieAction` が呼ぶ）。
fn registerActions(app: *App) void {
    platform.registerAction(.{ .name = "undo", .ctx = app, .run = actionUndo, .network_policy = .undo_own, .args = pixie_args_none }); // 制御コマンド（§4b。executor 非経由）
    platform.registerAction(.{ .name = "redo", .ctx = app, .run = actionRedo, .network_policy = .redo_own, .args = pixie_args_none });
    platform.registerAction(.{ .name = "clear", .ctx = app, .run = recordedAction("clear", .record), .args = pixie_args_none });
    // TASK-94 Phase B: layer 構造 op は handle 参照化済みのため .relay 昇格。
    // select_layer のみ .local_only（selection は per-peer view。relay すると選択を奪い合う）。
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
    // recipe（TASK-62.5.8）: メタ操作のため executor 非経由・CommandLog 非記録。local_only。
    platform.registerAction(.{ .name = "recipe_save", .ctx = app, .run = actionRecipeSave, .network_policy = .local_only, .args = pixie_args_path });
    platform.registerAction(.{ .name = "recipe_replay", .ctx = app, .run = actionRecipeReplay, .network_policy = .local_only, .args = pixie_args_path });
    // diff_mark（TASK-87）: メタ操作のため executor 非経由・CommandLog 非記録。local_only。
    platform.registerAction(.{ .name = "diff_mark", .ctx = app, .run = actionDiffMark, .network_policy = .local_only, .desc = "mark current composite as diff baseline", .args = pixie_args_none });
    // TASK-45.4: timeline view actions（executor 非経由・CommandLog 非記録・local_only）
    platform.registerAction(.{ .name = "play", .ctx = app, .run = actionPlay, .network_policy = .local_only, .desc = "start timeline playback", .args = pixie_args_none });
    platform.registerAction(.{ .name = "pause", .ctx = app, .run = actionPause, .network_policy = .local_only, .desc = "pause timeline playback", .args = pixie_args_none });
    platform.registerAction(.{ .name = "goto_frame", .ctx = app, .run = actionGotoFrame, .network_policy = .local_only, .desc = "select frame by index (view only, no undo)", .args = pixie_args_goto_frame });
    // TASK-45.5: 書き出し（executor 非経由・CommandLog 非記録・local_only）
    platform.registerAction(.{ .name = "export_seq", .ctx = app, .run = actionExportSeq, .network_policy = .local_only, .desc = "export numbered PNG sequence", .args = pixie_args_export_seq });
    platform.registerAction(.{ .name = "export_sheet", .ctx = app, .run = actionExportSheet, .network_policy = .local_only, .desc = "export sprite sheet PNG", .args = pixie_args_export_sheet });
    // TASK-89: 末尾追加のみ（並列制約。既存行の変更・並べ替え禁止）
    platform.registerAction(.{ .name = "replace_color", .ctx = app, .run = recordedAction("replace_color", .record), .network_policy = .relay, .desc = "replace color A→B on layer ([#id|idx] from to; undoable)", .args = pixie_args_replace_color });
    // palette は document 状態（SYNC 対象）なので session 中のローカル変更は diverge → reject_when_synced
    platform.registerAction(.{ .name = "palette_ramp", .ctx = app, .run = recordedAction("palette_ramp", .record), .network_policy = .reject_when_synced, .desc = "OKLCH light-dark ramp from seed (n=2..32)", .args = pixie_args_palette_ramp });
    platform.registerAction(.{ .name = "palette_from_png", .ctx = app, .run = recordedAction("palette_from_png", .record), .network_policy = .reject_when_synced, .desc = "extract palette from PNG by frequency (max 64)", .args = pixie_args_palette_from_png });
    platform.registerAction(.{ .name = "palette_set", .ctx = app, .run = recordedAction("palette_set", .record), .network_policy = .reject_when_synced, .desc = "replace palette with hex list (1..64)", .args = pixie_args_palette_set });
    // TASK-90: shape は stroke と同じ .relay（document 画素変更・undoable）。
    // set_symmetry / set_pixel_perfect も描画結果に影響する document 系トグル → .relay
    // set_tool / set_color は per-peer のため .local_only。stroke は tool/color を payload に焼き込む。
    platform.registerAction(.{ .name = "shape", .ctx = app, .run = recordedAction("shape", .record), .network_policy = .relay, .desc = "draw shape line|rect|ellipse p0 p1 [fill]", .args = pixie_args_shape });
    platform.registerAction(.{ .name = "set_symmetry", .ctx = app, .run = recordedAction("set_symmetry", .record), .network_policy = .relay, .desc = "symmetry off|v|h|quad", .args = pixie_args_set_symmetry });
    platform.registerAction(.{ .name = "set_pixel_perfect", .ctx = app, .run = recordedAction("set_pixel_perfect", .record), .network_policy = .relay, .desc = "pixel-perfect pen 0|1", .args = pixie_args_set_pixel_perfect });
    // TASK-103: ephemeral presence（recordedAction / CommandLog / undo 非経由）
    platform.registerAction(.{ .name = "presence_point", .ctx = app, .run = actionPresencePoint, .network_policy = .ephemeral, .desc = "agent cursor / work position", .args = pixie_args_presence_point });
    platform.registerAction(.{ .name = "presence_highlight", .ctx = app, .run = actionPresenceHighlight, .network_policy = .ephemeral, .desc = "temporary canvas highlight rect", .args = pixie_args_presence_highlight });
    platform.registerAction(.{ .name = "presence_suggest", .ctx = app, .run = actionPresenceSuggest, .network_policy = .ephemeral, .desc = "assist suggestion marker", .args = pixie_args_presence_suggest });
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

/// peer 固定色（point/highlight 用）。suggest は amber 固定。
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

fn canvasToScreen(canvas_rect: core.Rect, zoom: i32, cx: i32, cy: i32) gui.Vec2 {
    return .{
        .x = canvas_rect.x + cx * zoom + @divTrunc(zoom, 2),
        .y = canvas_rect.y + cy * zoom + @divTrunc(zoom, 2),
    };
}

/// TASK-103 presence overlay。フレーム毎・最大 8 peer × 固定小面積。
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
        .w = @intCast(canvas_rect.w * zoom),
        .h = @intCast(canvas_rect.h * zoom),
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
            const rect: gui.Rect = .{
                .x = canvas_rect.x + x0 * zoom,
                .y = canvas_rect.y + y0 * zoom,
                .w = @intCast((x1 - x0 + 1) * zoom),
                .h = @intCast((y1 - y0 + 1) * zoom),
            };
            dl.rectFilled(rect, fill) catch {};
            dl.rectOutline(rect, col, 2) catch {};
        }

        if (p.point_active) {
            const c = canvasToScreen(canvas_rect, zoom, p.point_x, p.point_y);
            const arm: i32 = @max(4, zoom);
            dl.line(.{ .x = c.x - arm, .y = c.y }, .{ .x = c.x + arm, .y = c.y }, col, 2) catch {};
            dl.line(.{ .x = c.x, .y = c.y - arm }, .{ .x = c.x, .y = c.y + arm }, col, 2) catch {};
            dl.rectFilled(.{ .x = c.x - 2, .y = c.y - 2, .w = 4, .h = 4 }, col) catch {};
            const label = std.fmt.bufPrint(&label_bufs[i], "agent #{d}", .{p.peer_id}) catch "agent";
            dl.text(.{ .x = c.x + 6, .y = c.y - 12 }, label, col) catch {};
        }

        if (p.suggest_active) {
            const c = canvasToScreen(canvas_rect, zoom, p.suggest_x, p.suggest_y);
            const r: i32 = @max(3, zoom);
            dl.rectOutline(.{ .x = c.x - r, .y = c.y - r, .w = @intCast(r * 2), .h = @intCast(r * 2) }, PRESENCE_SUGGEST_COLOR, 2) catch {};
            dl.rectFilled(.{ .x = c.x - 2, .y = c.y - 2, .w = 4, .h = 4 }, PRESENCE_SUGGEST_COLOR) catch {};
            dl.text(.{ .x = c.x + 6, .y = c.y + 4 }, "suggest", PRESENCE_SUGGEST_COLOR) catch {};
        }
    }
}

/// 表示領域中心（連続座標）。カメラモデルの S=(Sx,Sy)。
fn areaCenterF(area: core.Rect) struct { sx: f32, sy: f32 } {
    return .{
        .sx = @as(f32, @floatFromInt(area.x)) + @as(f32, @floatFromInt(area.w)) / 2.0,
        .sy = @as(f32, @floatFromInt(area.y)) + @as(f32, @floatFromInt(area.h)) / 2.0,
    };
}

/// カメラ由来の整数表示原点を計算し、area と最低 1px 交差する範囲へ clamp する（非破壊）。
/// origin ∈ [a - canvas*z + 1, a + area_size - 1]
fn displayOrigin(app: *const App, area: core.Rect) struct { x: i32, y: i32 } {
    const z = app.view_zoom;
    const zf: f32 = @floatFromInt(z);
    const c = areaCenterF(area);
    var ox: i32 = @intFromFloat(@round(c.sx - app.cam_cx * zf));
    var oy: i32 = @intFromFloat(@round(c.sy - app.cam_cy * zf));
    const vw = @as(i32, @intCast(app.doc.width)) * z;
    const vh = @as(i32, @intCast(app.doc.height)) * z;
    ox = std.math.clamp(ox, area.x - vw + 1, area.x + area.w - 1);
    oy = std.math.clamp(oy, area.y - vh + 1, area.y + area.h - 1);
    return .{ .x = ox, .y = oy };
}

/// 整数表示原点から cam_cx/cy を再導出する（clamp 後の状態整合）。
fn syncCameraFromOrigin(app: *App, area: core.Rect, ox: i32, oy: i32) void {
    const zf: f32 = @floatFromInt(app.view_zoom);
    const c = areaCenterF(area);
    app.cam_cx = (c.sx - @as(f32, @floatFromInt(ox))) / zf;
    app.cam_cy = (c.sy - @as(f32, @floatFromInt(oy))) / zf;
}

/// canvas_area 内にカメラ由来の表示原点で canvas rect を配置する。
/// 連続原点を整数へ丸めた後に clamp し、cam_cx/cy を表示原点から再導出する。
/// 毎フレーム app.last_area も更新する（Fit ズーム計算用）。
/// 返す core.Rect の w/h は canvas ピクセル数（screenToCanvas* の契約）。初回フレームは null。
fn canvasBlitRect(ctx: *const gui.Context, app: *App) ?core.Rect {
    const area_node = ctx.getNodeRect(CANVAS_AREA_ID) orelse return null;
    const area: core.Rect = .{ .x = area_node.x, .y = area_node.y, .w = @intCast(area_node.w), .h = @intCast(area_node.h) };
    app.last_area = area;

    const origin = displayOrigin(app, area);
    syncCameraFromOrigin(app, area, origin.x, origin.y);
    return .{ .x = origin.x, .y = origin.y, .w = @intCast(app.doc.width), .h = @intCast(app.doc.height) };
}

/// ビューポートのズーム/パン入力を処理する（endFrame 後・canvas 入力前に呼ぶ）。
/// 戻り値: パン中なら true（呼び出し側は描画入力を抑止する）。zoom/pan の変更は app へ書き戻し、
/// 実際の clamp は次フレームの canvasBlitRect が現 area に対して行う。
fn updateViewport(app: *App, ctx: *const gui.Context) bool {
    const in = &ctx.input;
    const area = app.last_area;
    // popup（レイヤー右クリックメニュー等。TASK-79.2）表示中は新規のズーム/パン**開始**を
    // 抑止する（canvas への入力貫通防止。既存の stroke 開始ゲートと同じ狙い）。既に進行中の
    // パンはそのまま release まで完走させる（下の `if (app.pan_active)` は popup_open を見ない）。
    const popup_open = ctx.hasOpenPopup();

    // マウスが canvas area 内か（ズーム/パン開始の判定に使う）
    const in_area = blk: {
        if (area) |a| {
            const p = in.mouse_pos;
            break :blk (p.x >= a.x and p.y >= a.y and p.x < a.x + a.w and p.y < a.y + a.h);
        }
        break :blk false;
    };

    // ── ホイールズーム（zoom-to-cursor。area 内のみ）──
    // scroll_delta.y > 0 = 上スクロール = ズームイン（backend により符号が逆なら調整）。
    if (in_area and in.scroll_delta.y != 0 and !popup_open) {
        const step: i32 = if (in.scroll_delta.y > 0) 1 else -1;
        app.zoomAround(app.view_zoom + step, in.mouse_pos.x, in.mouse_pos.y);
    }

    // ── KP_ADD/KP_SUBTRACT の保留ズーム（カーソル軸。area 外なら中央）──
    if (app.pending_zoom_delta != 0 and !popup_open) {
        const delta = app.pending_zoom_delta;
        app.pending_zoom_delta = 0;
        app.zoomAround(app.view_zoom + delta, in.mouse_pos.x, in.mouse_pos.y);
    } else if (popup_open) {
        app.pending_zoom_delta = 0;
    }

    // ── パン（Space+左 / middle / Cmd+左）。capturing / bezier 編集中は開始しない ──
    if (!app.pan_active) {
        const bezier_editing = app.active_kind == .bezier and app.bezier_editor.isEditing();
        const kind_opt: ?PanKind = blk: {
            if (app.space_down and in.mouse_pressed.left) break :blk .space_left;
            if (in.mouse_pressed.middle) break :blk .middle;
            // mouse_pressed_modifiers: down 時の modifier を latch 済み（move に cmd が載らなくても開始判定は正確）
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
                        // press 座標を anchor にする（同一フレームの move 後 mouse_pos を使うと delta=0 になる）
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
            // Cmd は開始時に latch 済み。move に modifier が載らなくても左ボタン継続で完走する。
            .cmd_left => in.mouse_buttons.left,
        };
        if (pan_held) {
            const zf: f32 = @floatFromInt(app.view_zoom);
            const dx = @as(f32, @floatFromInt(in.mouse_pos.x - app.pan_anchor_mouse.x));
            const dy = @as(f32, @floatFromInt(in.mouse_pos.y - app.pan_anchor_mouse.y));
            // 画面移動量を zoom で割り、カメラを逆方向へ更新
            app.cam_cx = app.pan_anchor_cam_x - dx / zf;
            app.cam_cy = app.pan_anchor_cam_y - dy / zf;
        } else {
            app.pan_active = false;
        }
    }
    return app.pan_active;
}

/// M1 配線（TASK-75.4）: hover 領域（canvas / パネル・外）から OS cursor shape を決め、前フレームと
/// 異なる時だけ `window.setCursor` を呼ぶ（canvas → crosshair、パネル/外 → default）。
/// あわせて free-hover 位置（`hover_screen`/`hover_cell`）を更新する。
///
/// 呼び出しタイミングは「canvas 入力ディスパッチの後・描画の前」（main loop 内）にすること。
/// ディスパッチ前だと、当フレームで新規 stroke が開始しても `isPointerBusy()` がまだ false のままの
/// 状態で hover が確定してしまい、直後の描画パスで busy 開始直後の footprint リング（Brush の場合）が
/// 一瞬出てしまう（codex レビュー指摘。2026-07-05）。
///
/// ホットパス宣言: 毎フレーム呼ばれるが O(1)（矩形内外判定 + 座標変換のみ）。全画素ループ非該当。
fn updateCursorAndHover(app: *App, window: platform.Window, ctx: *const gui.Context, canvas_rect: ?core.Rect) void {
    const mouse = core.Vec2{ .x = ctx.input.mouse_pos.x, .y = ctx.input.mouse_pos.y };
    // 表示領域全体ではなく、カメラ由来 canvas_rect 上の画素に乗っているか（screenToCanvas 成功）で判定。
    const hover_cell = if (canvas_rect) |rect|
        core.screenToCanvas(mouse, rect, app.view_zoom)
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

/// レイヤー名の表示上限（**切り詰め後を含めた総コードポイント数**。TASK-79.3）。右ペイン幅
/// 200px の行に収める表示専用の制約で、保存される名前自体（`layer_name_max`=32B）は切り詰めない。
///
/// 実測値: サムネ(24px)+可視トグル(min_w 22)+opacity slider(track_w 40 他)を差し引いた
/// 右ペイン(200px)の残り予算では、名前欄が**総描画 7 文字**（フォントは固定 8px/コードポイント。
/// `libs/gui/src/font.zig`）を超えると opacity slider がスクロール viewport 外へ押し出され
/// 操作不能になることを harness snapshot で確認済み（7 文字="Layer 1" は収まる／8 文字="Layer 10"
/// 相当は収まらない）。既定名 "Layer N" は 1 桁のうちは 7 文字ちょうどで収まるが、2 桁以降
/// （"Layer 10".."Layer 99"）は下記の切り詰めで "Layer.." のように短縮表示される
/// （番号は失われるが選択ハイライト/サムネで見分けは付く。3 桁以降も同様）。
const LAYER_NAME_DISPLAY_MAX: usize = 7;

/// 表示用にレイヤー名を「切り詰め後を含めた総コードポイント数」が `max_total_chars` に収まるよう
/// 切り詰める（収まらない場合のみ末尾 2 文字を ".." に差し替え）。buttonId/box の width は
/// min_w を「下限」としてしか扱えないため、切り詰めずに渡すと長い名前でレイヤー行が際限なく
/// 広がり opacity slider 等がスクロール viewport 外へ押し出され操作不能になりうる
/// （本関数はその防止専用。保存データは一切変更しない）。
/// **既にちょうど収まる名前（例: "Layer 1"）を無駄に切り詰めない**よう、「切り詰め要否」の判定は
/// 元の総コードポイント数で行う（「先頭 N 文字を機械的に切って ".." を足す」だけだと、
/// 元がわずかに budget を超えるだけの名前で `N+2 > 元の長さ` になり、切り詰めが逆に長くなる
/// 事故を避けるため）。
/// alloc は `ctx.allocator()`（フレーム arena）想定で、収まる場合は allocation なしで name を
/// そのまま返す。
///
/// 毎フレーム呼ばれるが（immediate-mode GUI 構築の一部）、対象は高々「レイヤー数×十数文字」で
/// 全画素ループではない（同じ buildLayerPanel が毎フレーム呼ぶ既存の `fillLayerThumb` と同じ
/// 「小さい per-frame UI 構築コスト」のクラス。性能規約の SIMD 3点セット等は対象外）。
fn truncateForDisplay(alloc: std.mem.Allocator, name: []const u8, max_total_chars: usize) []const u8 {
    const view = std.unicode.Utf8View.init(name) catch return name; // 不正 UTF-8 はそのまま返す（防御）
    var total: usize = 0;
    {
        var counter = view.iterator();
        while (counter.nextCodepointSlice()) |_| total += 1;
    }
    if (total <= max_total_chars) return name; // 収まる → 切り詰め不要

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

/// raw layer pixels（`cw`×`ch` = doc.width×doc.height, straight BGRA 0xAARRGGBB）を THUMB へ縮小し、
/// チェッカー下地へ src-over して不透明サムネを作る（透明部はチェッカーが見える）。
/// 各サムネ画素は元領域の **alpha 重み付き平均（premultiplied 平均）** にして、1px の細線も
/// 薄く残し内容が分かるようにする（最近傍だと細線が抜け落ちる）。opacity は反映しない（生の内容を表示）。
/// buf.len == LAYER_THUMB_W * LAYER_THUMB_H 前提。
fn fillLayerThumb(buf: []u32, layer_pixels: []const u32, cw: usize, ch: usize) void {
    const tw: usize = @intCast(LAYER_THUMB_W);
    const th: usize = @intCast(LAYER_THUMB_H);
    var ty: usize = 0;
    while (ty < th) : (ty += 1) {
        const sy0 = ty * ch / th;
        const sy1 = @max(sy0 + 1, (ty + 1) * ch / th); // 必ず 1 行以上
        var tx: usize = 0;
        while (tx < tw) : (tx += 1) {
            const sx0 = tx * cw / tw;
            const sx1 = @max(sx0 + 1, (tx + 1) * cw / tw);
            // 元領域 [sx0,sx1)×[sy0,sy1) の premultiplied 平均で straight BGRA を作る
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
    ctx.label("Layers");
    ctx.beginBox(.{ .direction = .row, .gap = 4 });
    // TASK-94 Phase C: netsync 中は routeAction（#id）、solo は do* 直呼び。
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

    var rev = app.canvas.layers.items.len;
    while (rev > 0) {
        rev -= 1;
        const idx = rev;
        const layer = app.canvas.layers.items[idx];
        // 1 行 = [サムネイル][選択 L{d}][visible][opacity slider]。行高はサムネイル(24px)律速。
        // 横一列で 200px 幅に収め、行を低く保って縦方向に多くの layer を見せる。
        // 明示 ID（row_id）を付けて rect_cache に登録する（右クリックのヒットテスト用。TASK-79.2）。
        const row_id = layerWidgetId(idx, LAYER_ROW_PART_ROW);
        ctx.beginBox(.{ .id = row_id, .direction = .row, .gap = 3, .align_cross = .center });

        // サムネイル: raw layer をチェッカー下地へ縮小合成。選択中は枠を明色に。
        const thumb = ctx.allocator().alloc(u32, @as(usize, @intCast(LAYER_THUMB_W)) * @as(usize, @intCast(LAYER_THUMB_H))) catch @panic("layer thumb: OOM");
        fillLayerThumb(thumb, layer.pixels, app.doc.width, app.doc.height);
        const thumb_border = if (idx == app.canvas.selected_layer) ctx.style.border_hover else ctx.style.border;
        ctx.imageBox(layerWidgetId(idx, 3), thumb, LAYER_THUMB_W, LAYER_THUMB_H, .{ .border = thumb_border });

        // レイヤー名表示（TASK-79.3）。renaming 中の対象行だけ確定前バッファ+カーソルを表示する。
        // どちらも `truncateForDisplay` で表示専用に切り詰める（保存名自体は変えない）: buttonId/
        // beginBox の width は min_w を「下限」としてしか扱えず、テキストが長いと際限なく箱が
        // 広がる。右ペイン幅 200px からサムネ/可視トグル/opacity slider を差し引くと名前欄の
        // 実質予算は 70〜90px 程度しかなく、無制限だと opacity slider 等がスクロール viewport
        // 外へ押し出され操作不能になりうるため。
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
                ctx.custom(.{ .x = @intCast(ctx.font.measure(shown) + ctx.font.measure(app.preedit())), .y = @intCast(ctx.font.metrics().line_height) }, drawInlineComposition, draw_ctx);
            } else {
                var cursor_buf: [96]u8 = undefined;
                const with_cursor = std.fmt.bufPrint(&cursor_buf, "{s}_", .{shown}) catch shown;
                ctx.labelEx(with_cursor, ctx.style.text);
            }
            ctx.endBox();
        } else {
            const shown = truncateForDisplay(ctx.allocator(), layer.name(), LAYER_NAME_DISPLAY_MAX);
            if (ctx.buttonId(layerWidgetId(idx, 0), shown, .{ .selected = idx == app.canvas.selected_layer, .min_w = 28 }).clicked) {
                // select_layer は .local_only（per-peer view）→ netsync 中もローカル do*
                app.doSelectLayer(idx) catch {};
            }
        }
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

        // 右クリックでこの行のレイヤーを選択しコンテキストメニューを開く（TASK-79.2）。
        // 行矩形は「前フレームの rect_cache」（既存 widget と同じ同期 hit-test 契約。
        // context.zig 冒頭の契約コメント参照）。openPopup は endFrame 前でも呼べる
        // （endFrame 後を要求するのは描画+hit-test を行う popupMenu 側のみ。popup.zig 参照）。
        // レイヤーパネルは右ペインの縦スクロール領域（RIGHT_SCROLL_ID, clip_children=true）配下
        // にあるため、行 rect 単体だけでは「スクロールでクリップされ実際には見えていない部分」を
        // 誤ヒットし得る（codex レビュー指摘 2026-07-05）。RIGHT_SCROLL_ID のビューポート矩形
        // （beginScrollArea が clip_children 付きで登録する viewport box の rect）にも収まっている
        // ことを追加で確認する（既存 widget の buttonBehavior(rect, clip) と同じ「祖先 clip を
        // hit-test に使う」契約を、手動 hit-test でも踏襲する）。
        if (ctx.input.mouse_pressed.right) {
            if (ctx.getNodeRect(row_id)) |r| {
                const p = ctx.input.mouse_pressed_pos;
                const in_viewport = if (ctx.getNodeRect(RIGHT_SCROLL_ID)) |vp| vp.contains(p) else true;
                if (in_viewport and r.contains(p)) {
                    app.doSelectLayer(idx) catch {};
                    ctx.openPopup(LAYER_CTX_MENU_ID, p);
                }
            }
        }
    }
}

fn historyActorAbbrev(entry: *const history_summary.HistoryEntry, buf: []u8) []const u8 {
    if (std.mem.eql(u8, entry.actor, "local_user")) return "u";
    if (std.mem.eql(u8, entry.actor, "local_agent")) return "ai";
    if (std.mem.eql(u8, entry.actor, "system")) return "sys";
    if (entry.actor_peer) |id| {
        return std.fmt.bufPrint(buf, "#{d}", .{id}) catch "peer";
    }
    return "peer";
}

fn historyRowColor(ctx: *gui.Context, entry: *const history_summary.HistoryEntry) gui.Color {
    if (entry.reverted) return ctx.style.text_subtle;
    if (entry.redo_consumed) return gui.Color.rgba(0x68, 0x70, 0x78, 0xFF);
    return ctx.style.text;
}

fn formatHistoryLine(entry: *const history_summary.HistoryEntry, buf: []u8) []const u8 {
    var actor_buf: [16]u8 = undefined;
    const actor = historyActorAbbrev(entry, &actor_buf);
    if (entry.tx != null) {
        return std.fmt.bufPrint(buf, "#{d} {s} T {s}", .{ entry.seq, actor, entry.summary() }) catch "";
    }
    return std.fmt.bufPrint(buf, "#{d} {s} {s}", .{ entry.seq, actor, entry.summary() }) catch "";
}

fn historyRowId(idx: u32) gui.Id {
    return HISTORY_PANEL_ID_BASE + @as(gui.Id, idx);
}

/// 操作履歴パネル（TASK-83 Phase 1 + 83.2 サムネイル）。CommandLog を最新が上の縦リストで表示する。
/// ホットパス宣言: 毎フレーム構築されるが履歴データの再構築は dirty 時のみ（イベント時相当）。
/// サムネイルは固定バッファの blit のみ（PixelDiff / bbox 再計算 / composite / allocator 禁止）。
fn buildHistoryPanel(ctx: *gui.Context, app: *App) void {
    app.ensureHistoryFresh();
    ctx.label("History");
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
        var line_buf: [platform.command.MAX_SUMMARY + 48]u8 = undefined;
        const line = formatHistoryLine(entry, &line_buf);
        ctx.beginBox(.{ .id = historyRowId(rev), .direction = .row, .gap = 2, .align_cross = .center });
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
        ctx.labelEx(line, historyRowColor(ctx, entry));
        ctx.endBox();
    }
}

/// テキストレイヤー（kind==.text）専用の編集パネル。選択中レイヤーが text の時のみ表示する
/// （TASK-79.5）。内容編集（`text_in` 経由のインライン編集）/ font size / 位置(x,y) /
/// 現在色の適用を扱う。値変化時に `App.doSetTextParams` へ委譲する（既存 opacity スライダーと
/// 同じ「値が変わった時だけ呼ぶ」パターン。ドラッグ中の複数回 push は既存 opacity スライダーと
/// 同クラスの既知トレードオフで新規の懸念ではない）。
///
/// ホットパス宣言: 毎フレーム構築されるが（immediate-mode GUI の一部）、実際の再ラスタライズ
/// （`doSetTextParams` 経由）はスライダー値変化・文字列確定等の**イベント時のみ**走る。
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
            ctx.custom(.{ .x = @intCast(ctx.font.measure(shown) + ctx.font.measure(app.preedit())), .y = @intCast(ctx.font.metrics().line_height) }, drawInlineComposition, draw_ctx);
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

/// 空セル用チェッカーサムネ（cel 無し）。
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

/// 下ペインのタイムライン UI（TASK-45.2）。行=layer × 列=frame のセルグリッド。
/// ホットパス宣言: 毎フレーム構築（immediate-mode GUI）。サムネは 24×24 縮小のみ。
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

/// UI ツリー構築（widget の同期 hit-test もここで走る）
fn buildUi(ctx: *gui.Context, app: *App, canvas_rect: ?core.Rect) !void {
    // 選択/load 変更フレームに編集 HSV を現在色から再同期（以後は編集中 HSV を保持）
    app.syncEditHsv();
    // 右ペイン非表示時は HSV widget が無く applyEditColor がブロック内で呼ばれない（TASK-42）。
    // Pal Load 等で current が変わっても pen/brush.color が旧色のままになるのを防ぐためここで同期する
    // （visible 時は従来どおり HSV slider 更新後・palette grid より前のブロック内で呼ぶ）。
    if (!app.right_visible) app.applyEditColor();

    // ペイン幅/高さを前フレーム rect の「利用可能領域」へ clamp（TASK-42）。
    // 基準は CONTENT_ROW（横分割の全幅）/ MAIN_AREA（縦分割の全高）。CANVAS_AREA は pane 差引後の
    // 残りなので max 基準に使えない。max は splitter にも渡し、ウィンドウ縮小時も canvas を CANVAS_MIN 残す。
    var right_max: i32 = RIGHT_PANE_DEFAULT;
    if (ctx.getNodeRect(CONTENT_ROW_ID)) |row| {
        right_max = @max(RIGHT_PANE_MIN, @as(i32, @intCast(row.w)) - SPLITTER_T - CANVAS_MIN);
    }
    app.right_pane_w = std.math.clamp(app.right_pane_w, RIGHT_PANE_MIN, right_max);
    var bottom_max: i32 = BOTTOM_PANE_DEFAULT;
    if (ctx.getNodeRect(MAIN_AREA_ID)) |m| {
        bottom_max = @max(BOTTOM_PANE_MIN, @as(i32, @intCast(m.h)) - SPLITTER_T - CANVAS_MIN);
    }
    app.bottom_pane_h = std.math.clamp(app.bottom_pane_h, BOTTOM_PANE_MIN, bottom_max);

    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 4, 4, 4, 4 },
        .gap = 4,
    });

    // ── 1 段目: menu bar（Command 定義から File/Edit/View。TASK-97.2）──
    // native 有効時は OS メニューバーに任せて GUI fallback 行をスキップ（TASK-97.3）。
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

    // ── main area: content row(canvas + 右ペイン) + 任意の下ペイン（TASK-42。縦分割の基準 ID） ──
    ctx.beginBox(.{ .id = MAIN_AREA_ID, .direction = .column, .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .gap = 0 });

    // content row: canvas(grow) + [splitter + right pane]。gap=0 で splitter を境界帯にする（横分割の基準 ID）。
    ctx.beginBox(.{ .id = CONTENT_ROW_ID, .direction = .row, .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .gap = 0 });

    // canvas area: 明示 ID・中身空（blit は endFrame 後に別パスで行う）。bg なし（canvas を上塗りしない）。
    ctx.beginBox(.{ .id = CANVAS_AREA_ID, .width = .{ .grow = 1 }, .height = .{ .grow = 1 } });
    ctx.endBox();

    if (app.right_visible) {
        _ = ctx.splitter(SPLIT_RIGHT_ID, .vertical, &app.right_pane_w, .{ .thickness = SPLITTER_T, .min = RIGHT_PANE_MIN, .max = right_max, .invert = true });
        // right pane: Color / Palette / Tool / Layers を縦スクロール領域に入れる（TASK-46）。
        // content_width=grow で content を viewport 幅いっぱい（横スクロール不要）、高さは fit で縦スクロール。
        ctx.beginScrollArea(RIGHT_SCROLL_ID, &app.right_scroll, .{
            .width = .{ .fixed = app.right_pane_w },
            .height = .{ .grow = 1 },
            .padding = .{ 8, 8, 8, 8 },
            .gap = 6,
            .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
            .content_width = .{ .grow = 1 },
        });
        // ── カラーエディタ（HSV）。grid より前に write-back する（選択変更の上書き事故回避） ──
        ctx.label("Color");
        ctx.beginBox(.{ .direction = .row, .gap = 8, .align_cross = .start });
        _ = ctx.svSquareId(0xCED10001, app.edit_h, &app.edit_s, &app.edit_v, .{ .size = 120 });
        _ = ctx.hueBarId(0xCED10002, &app.edit_h, .{ .h = 120 });
        ctx.endBox();
        _ = ctx.sliderF32Id(0xCED10003, "H", &app.edit_h, .{ .min = 0, .max = 360, .step = 1, .track_w = 96 });
        _ = ctx.sliderF32Id(0xCED10004, "S", &app.edit_s, .{ .min = 0, .max = 1, .step = 0.01, .track_w = 96 });
        _ = ctx.sliderF32Id(0xCED10005, "V", &app.edit_v, .{ .min = 0, .max = 1, .step = 0.01, .track_w = 96 });
        app.edit_h = @min(app.edit_h, 360 - 1e-3); // hueBar と同じ [0,360) 契約
        app.applyEditColor(); // 編集中 HSV → 選択スウォッチ色 + pen.color（grid クリックより前）

        // ── 編集可能パレット（可変長スウォッチ + 追加/削除） ──
        ctx.label("Palette");
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
                        app.palette.select(idx); // HSV は次フレームで再同期
                        app.repl_source = app.palette.current(); // Repl の from を選択時点色に固定（TASK-89）
                        if (app.active_kind == .eraser) app.setActiveKind(.pen); // 色は pen 用（brush/bezier は維持）
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
            // 非末尾削除で index が詰まると selected が同値のまま別色を指す。
            // edit_synced_for を無効化し、次フレームで現 current 色から HSV 再同期する
            // （さもないと applyEditColor が旧 HSV で新色を上書きする）。
            app.edit_synced_for = null;
            app.repl_source = null;
        }
        // TASK-89: 選択スウォッチ選択時色 → 現在 HSV 編集色に canvas 置換 + swatch 更新
        // netsync 中は peer の selected が違うと diverge するため拒否（fill と同型ガード。TASK-94 Phase C）
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

        ctx.label("Tool");
        // 7 ツールは右ペイン幅に収めるため 2 個ずつ折り返す（TASK-68 で Eyedrop 追加・奇数個なので最終行は単独）
        ctx.beginBox(.{ .direction = .row, .gap = 4 });
        if (ctx.buttonEx("Pen", .{ .selected = app.active_kind == .pen, .min_w = 56 }).clicked) app.setActiveKind(.pen);
        if (ctx.buttonEx("Eraser", .{ .selected = app.active_kind == .eraser, .min_w = 56 }).clicked) app.setActiveKind(.eraser);
        ctx.endBox();
        ctx.beginBox(.{ .direction = .row, .gap = 4 });
        if (ctx.buttonEx("Brush", .{ .selected = app.active_kind == .brush, .min_w = 56 }).clicked) app.setActiveKind(.brush);
        if (ctx.buttonEx("Bezier", .{ .selected = app.active_kind == .bezier, .min_w = 56 }).clicked) app.setActiveKind(.bezier);
        ctx.endBox();
        ctx.beginBox(.{ .direction = .row, .gap = 4 });
        if (ctx.buttonEx("Select", .{ .selected = app.active_kind == .select, .min_w = 56 }).clicked) app.setActiveKind(.select);
        if (ctx.buttonEx("Fill", .{ .selected = app.active_kind == .fill, .min_w = 56 }).clicked) app.setActiveKind(.fill);
        ctx.endBox();
        ctx.beginBox(.{ .direction = .row, .gap = 4 });
        if (ctx.buttonEx("Eyedrop", .{ .selected = app.active_kind == .eyedropper, .min_w = 56 }).clicked) app.setActiveKind(.eyedropper);
        ctx.endBox();
        // TASK-90: Line / Rect / Ellipse
        ctx.beginBox(.{ .direction = .row, .gap = 4 });
        if (ctx.buttonEx("Line", .{ .selected = app.active_kind == .line, .min_w = 56 }).clicked) app.setActiveKind(.line);
        if (ctx.buttonEx("Rect", .{ .selected = app.active_kind == .rect, .min_w = 56 }).clicked) app.setActiveKind(.rect);
        ctx.endBox();
        ctx.beginBox(.{ .direction = .row, .gap = 4 });
        if (ctx.buttonEx("Ellipse", .{ .selected = app.active_kind == .ellipse, .min_w = 56 }).clicked) app.setActiveKind(.ellipse);
        ctx.endBox();
        ctx.labelEx("(Alt+click = temp eyedrop)", ctx.style.text_subtle);
        // paste/move のブロック配置トグル（gui.toggle スイッチ。TASK-48）。
        // ON=透明を保持(src-over・下の絵を残す) / OFF=上書き(replace)。
        var keep_transp = app.blend_mode == .over;
        if (ctx.toggle("Keep Transp", &keep_transp)) {
            app.blend_mode = if (keep_transp) .over else .replace;
        }
        // TASK-90: shape fill / pixel_perfect / symmetry
        if (app.active_kind == .rect or app.active_kind == .ellipse) {
            var fill_on = app.shape_in.fill;
            if (ctx.toggle("Shape Fill", &fill_on)) {
                app.shape_in.fill = fill_on;
            }
        }
        // TASK-90 + TASK-94 Phase C: netsync 中は routeAction、solo は do* 直呼び
        var pp_on = app.pixel_perfect;
        if (ctx.toggle("Pixel Perfect", &pp_on)) {
            app.uiSetPixelPerfect(pp_on);
        }
        // symmetry: Off / V / H / Quad を 1 行ボタン
        ctx.label("Symmetry");
        ctx.beginBox(.{ .direction = .row, .gap = 4 });
        if (ctx.buttonEx("Off", .{ .selected = app.symmetry == .off, .min_w = 36 }).clicked) {
            app.uiSetSymmetry(.off);
        }
        if (ctx.buttonEx("V", .{ .selected = app.symmetry == .vertical, .min_w = 28 }).clicked) {
            app.uiSetSymmetry(.vertical);
        }
        if (ctx.buttonEx("H", .{ .selected = app.symmetry == .horizontal, .min_w = 28 }).clicked) {
            app.uiSetSymmetry(.horizontal);
        }
        if (ctx.buttonEx("Q", .{ .selected = app.symmetry == .quad, .min_w = 28 }).clicked) {
            app.uiSetSymmetry(.quad);
        }
        ctx.endBox();
        // Brush/Bezier 選択時に Size/Opacity/Hardness の Slider を表示（bezier も同じブラシ設定で描く）
        if (app.active_kind == .brush or app.active_kind == .bezier) {
            _ = ctx.sliderI32Id(0xB0_0001, "Size", &app.brush_size_i32, .{ .min = 1, .max = 64, .track_w = 90 });
            _ = ctx.sliderI32Id(0xB0_0002, "Opac", &app.brush_opacity_i32, .{ .min = 0, .max = 255, .track_w = 90 });
            _ = ctx.sliderF32Id(0xB0_0003, "Hard", &app.brush_hardness_f32, .{ .min = 0, .max = 1, .step = 0.05, .track_w = 90 });
        }
        // UI 状態 → Brush（毎フレーム clamp/変換。型差吸収）
        app.brush.size = @intCast(std.math.clamp(app.brush_size_i32, 1, 64));
        app.brush.opacity = @intCast(std.math.clamp(app.brush_opacity_i32, 0, 255));
        app.brush.hardness_q = @intFromFloat(std.math.clamp(app.brush_hardness_f32, 0, 1) * 255 + 0.5);

        // Fill 選択時に色許容差(Tol)の Slider を表示（TASK-76）
        if (app.active_kind == .fill) {
            _ = ctx.sliderI32Id(0xFEED_0001, "Tol", &app.fill_tolerance_i32, .{ .min = 0, .max = 255, .track_w = 90 });
        }
        // UI 状態 → Fill（毎フレーム clamp/変換。型差吸収）
        app.fill.tolerance = @intCast(std.math.clamp(app.fill_tolerance_i32, 0, 255));

        try buildLayerPanel(ctx, app);
        try buildTextLayerPanel(ctx, app); // TASK-79.5: 選択中レイヤーが text kind の時のみ表示
        buildHistoryPanel(ctx, app);
        ctx.endScrollArea(); // right pane (縦スクロール)
    } // right_visible

    ctx.endBox(); // content row

    // ── 下ペイン（タイムライン枠。中身は Phase5。TASK-42 はリサイズ/トグル枠のみ） ──
    if (app.bottom_visible) {
        _ = ctx.splitter(SPLIT_BOTTOM_ID, .horizontal, &app.bottom_pane_h, .{ .thickness = SPLITTER_T, .min = BOTTOM_PANE_MIN, .max = bottom_max, .invert = true });
        ctx.beginBox(.{
            .direction = .column,
            .width = .{ .grow = 1 },
            .height = .{ .fixed = app.bottom_pane_h },
            .padding = .{ 4, 6, 4, 6 },
            .gap = 4,
            .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
            .clip_children = true,
        });
        try buildTimelinePanel(ctx, app);
        ctx.endBox(); // bottom pane
    }

    ctx.endBox(); // main area

    // ── 4 段目: status bar ──
    ctx.beginBox(.{
        .direction = .row,
        .width = .{ .grow = 1 },
        .padding = .{ 2, 6, 2, 6 },
        .gap = 16,
        .bg = gui.Color.rgba(0x28, 0x28, 0x30, 0xFF),
    });
    const arena = ctx.allocator();
    // cursor の canvas 座標（表示領域外は "-"）。rect は前フレーム値（同期 hit-test 契約と同じ）
    const cursor_txt = blk: {
        if (canvas_rect) |rect| {
            if (core.screenToCanvas(
                .{ .x = ctx.input.mouse_pos.x, .y = ctx.input.mouse_pos.y },
                rect,
                app.view_zoom,
            )) |cp| {
                break :blk try std.fmt.allocPrint(arena, "cursor: ({d}, {d})", .{ cp.x, cp.y });
            }
        }
        break :blk "cursor: -";
    };
    ctx.labelEx(cursor_txt, ctx.style.text_subtle);
    {
        const c = app.palette.current();
        // canonical BGRA(0xAARRGGBB) から #RRGGBB 用に明示抽出。
        const r: u8 = @truncate(c >> 16);
        const g: u8 = @truncate(c >> 8);
        const b: u8 = @truncate(c);
        ctx.labelEx(
            try std.fmt.allocPrint(arena, "color: #{X:0>2}{X:0>2}{X:0>2} ({d})", .{ r, g, b, app.palette.colors.items.len }),
            ctx.style.text_subtle,
        );
    }
    ctx.labelEx(
        try std.fmt.allocPrint(arena, "tool: {s}", .{app.active_kind.name()}),
        ctx.style.text_subtle,
    );
    ctx.labelEx(
        try std.fmt.allocPrint(arena, "layer: {d}/{d}", .{ app.canvas.selected_layer + 1, app.canvas.layers.items.len }),
        ctx.style.text_subtle,
    );
    ctx.labelEx(
        try std.fmt.allocPrint(arena, "frame: {d}/{d}", .{ app.doc.selected_frame + 1, app.doc.frames.items.len }),
        ctx.style.text_subtle,
    );
    ctx.labelEx(
        try std.fmt.allocPrint(arena, "zoom: {d}%", .{app.view_zoom * 100}),
        ctx.style.text_subtle,
    );
    if (app.active_kind == .brush or app.active_kind == .bezier) {
        ctx.labelEx(
            try std.fmt.allocPrint(arena, "brush: sz={d} op={d} hard={d:.2}", .{
                app.brush.size, app.brush.opacity, app.brush_hardness_f32,
            }),
            ctx.style.text_subtle,
        );
    }
    if (app.active_kind == .fill) {
        ctx.labelEx(
            try std.fmt.allocPrint(arena, "fill: tol={d}", .{app.fill.tolerance}),
            ctx.style.text_subtle,
        );
    }
    if (app.active_kind == .bezier and app.bezier_editor.isEditing()) {
        ctx.labelEx(
            try std.fmt.allocPrint(arena, "anchors: {d}", .{app.bezier_editor.path.anchors.items.len}),
            ctx.style.text_subtle,
        );
    }
    if (app.saveMsg()) |msg| ctx.label(msg);
    ctx.endBox();

    // ── TASK-144.2: サイズダイアログ（root 末尾 = 通常 UI より後に layout 発行 = 前面）──
    // absolute 非対応のため canvas 領域相当の grow box で dim+panel を重ねるのではなく、
    // root 末尾にフル幅の modal 帯を置き、panel を中央寄せする（確認 overlay と同時非表示は
    // openSizeDialog 側でガード）。
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
        extern "env" fn vp_log(ptr: [*]const u8, len: u32) void;
    };
    env.vp_log(msg.ptr, @intCast(msg.len));
}

fn wasmPanic(msg: []const u8, _: ?usize) noreturn {
    const env = struct {
        extern "env" fn vp_log(ptr: [*]const u8, len: u32) void;
    };
    env.vp_log(msg.ptr, @intCast(@min(msg.len, std.math.maxInt(u32))));
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

fn hostNewDocument(ctx: *anyopaque) !void {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (app.pending_png_path) |path| {
        app.doOpenPath(path) catch |err| return err;
        app.gpa.free(path);
        app.pending_png_path = null;
        try app.setProjectPath(null);
        try app.autosave.clear();
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
    try app.autosave.clear();
    try app.autosave.setPath(null);
}

fn hostOpenDocument(ctx: *anyopaque, path: []const u8) !void {
    const app: *App = @ptrCast(@alignCast(ctx));
    try loadProjectPath(app, path);
    try app.recent.push(path);
    try app.autosave.clear();
    try app.autosave.setPath(path);
}

fn hostSaveDocument(ctx: *anyopaque, path: []const u8) !void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.syncPaletteToDoc();
    const bytes = try core.document_io.encodeDocument(&app.doc, app.gpa);
    defer app.gpa.free(bytes);
    try appshell.file_safety.writeAtomic(app.io, path, bytes, .{ .backup = true });
    try app.recent.push(path);
    try app.autosave.clear();
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
    try appshell.autosave.discardCandidate(app.io, app.autosave.dir, candidate.file_name);
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
    try appshell.autosave.discardCandidate(app.io, app.autosave.dir, candidate.file_name);
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

    // fallible 資源は literal 前に段階化 + errdefer（変更前 main の ctx 先行 defer を復元し、
    // さらに doc/recorder/preview/palette/onion も同等以上の保証にする。literal は移動のみ）。
    const system_font_bytes = fontmod.loadSystemTextFontBytes(io, gpa);
    errdefer if (system_font_bytes) |b| gpa.free(b);

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

    const override_path = if (std.c.getenv("VP_APPSHELL_DIR")) |value| std.mem.span(value) else null;
    var data_dir = try appshell.paths.openAppDataDir(io, gpa, "pixie", override_path);
    errdefer data_dir.close(io);
    var autosave_dir = try appshell.paths.openAutosaveDir(io, data_dir);
    errdefer autosave_dir.close(io);
    var recent = appshell.recent_files.RecentFiles.init(gpa, 10);
    errdefer recent.deinit();
    _ = try recent.load(io, data_dir, "recent_files.ash");
    _ = try recent.pruneMissing(io, std.Io.Dir.cwd());
    var autosave_controller = try appshell.autosave.Controller.init(gpa, io, autosave_dir, null);
    errdefer autosave_controller.deinit();
    var recovery = try appshell.autosave.scan(gpa, io, autosave_dir);
    errdefer if (recovery) |*candidate| candidate.deinit();

    var size_w_buf = try gui.TextBuffer.init(gpa, "");
    errdefer size_w_buf.deinit();
    var size_h_buf = try gui.TextBuffer.init(gpa, "");
    errdefer size_h_buf.deinit();

    // ここから infallible（所有は App へ移動。成功 return 時は上記 errdefer は発火しない）
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
        .system_font_bytes = system_font_bytes,
        .onion_buf = onion_buf,
        .onion_scratch = onion_scratch,
        .data_dir = data_dir,
        .autosave_dir = autosave_dir,
        .recent = recent,
        .autosave = autosave_controller,
        .recovery = recovery,
        .size_dialog_storage = .{
            .mode = .resize,
            .width_buf = size_w_buf,
            .height_buf = size_h_buf,
        },
        .size_dialog = null,
    };

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

    self.cmd_exec = platform.command.Executor.init(.{ .ctx = self, .run = dispatchPixieAction });
    self.cmd_exec.log = &self.cmd_log;
    self.cmd_exec.adapter = .{ .ctx = self, .canUndo = adapterCanUndo, .applyUndo = adapterApplyUndo, .summarize = adapterSummarize };
    platform.setCommandExecutor(&self.cmd_exec);

    platform.registerProbe(.{ .name = "canvas", .ctx = self, .ext = "png", .snapshot = canvasSnapshot, .digest = canvasDigest });
    platform.registerProbe(.{ .name = "undo", .ctx = self, .ext = "json", .snapshot = undoSnapshot, .digest = undoDigest });
    platform.registerProbe(.{ .name = "tool", .ctx = self, .ext = "txt", .snapshot = toolSnapshot, .digest = toolDigest });
    platform.registerProbe(.{ .name = "cursor", .ctx = self, .ext = "txt", .snapshot = cursorSnapshot, .digest = cursorDigest });
    platform.registerProbe(.{ .name = "history", .ctx = self, .ext = "json", .snapshot = historySnapshot, .digest = historyDigest });
    platform.registerProbe(.{ .name = "diff", .ctx = self, .ext = "txt", .digest = diffDigest, .desc = "visual diff vs marked baseline: changed/bbox/from/to" });
    // TASK-45.4: timeline 再生状態（digest のみ・snapshot=null）
    platform.registerProbe(.{ .name = "timeline", .ctx = self, .ext = "txt", .digest = timelineDigest, .desc = "timeline playback: playing/frame/frames/fps/dur/layers/onion" });
    platform.registerProbe(.{ .name = "palette", .ctx = self, .ext = "txt", .digest = paletteDigest, .desc = "palette size + canvas color histogram top4" });
    platform.registerProbe(.{ .name = "menu", .ctx = self, .ext = "txt", .digest = menuDigest, .desc = "menu open/items/enabled/checked/pending_file_op" });
    platform.registerProbe(.{ .name = "appshell", .ctx = self, .ext = "txt", .digest = appshellDigest, .desc = "pixie appshell dirty/recent/recovery/autosave/title/geometry state" });
    platform.registerProbe(.{ .name = "presence", .ctx = self, .ext = "txt", .digest = presenceDigest, .desc = "ephemeral presence overlay: count/point/highlight/suggest + per-peer coords" });
    registerActions(self);
    registerStateSync(self);
    return self;
}

fn appDeinit(self: *App) void {
    const gpa = self.gpa;
    if (self.native_menu_active) {
        if (self.os_window) |win| win.destroyMenu();
        self.native_menu_active = false;
        self.native_menu_registered = false;
    }
    if (self.recovery == null and !self.host.isDirty()) {
        self.autosave.clear() catch |err| std.log.err("pixie: autosave clear failed: {s}", .{@errorName(err)});
    }
    self.recent.save(self.io, self.data_dir, "recent_files.ash") catch |err| std.log.err("pixie: recent save failed: {s}", .{@errorName(err)});
    if (self.pending_png_path) |p| gpa.free(p);
    self.host.deinit();
    if (self.recovery) |*candidate| candidate.deinit();
    self.autosave.deinit();
    self.recent.deinit();
    self.autosave_dir.close(self.io);
    self.data_dir.close(self.io);
    if (self.current_path) |p| gpa.free(p);
    if (self.current_project_path) |p| gpa.free(p);
    if (self.palette_path) |p| gpa.free(p);
    if (self.clipboard) |*cb| cb.deinit(gpa);
    if (self.diff_base) |b| gpa.free(b);
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
    if (self.system_font_bytes) |b| gpa.free(b);
    gpa.destroy(self);
}

/// ライブリサイズ中の redraw callback と通常 frame の双方から呼ぶフレーム本体（TASK-23.1）。
/// モーダルダイアログ（runPendingFileOp）は含めない（callback からダイアログを開かない契約）。
fn appFrameInner(self: *App, win: *platform.Window) !void {
    // in_frame ガード: early return / error return でも必ず戻るよう defer で落とす。
    if (self.in_frame) return;
    self.in_frame = true;
    defer self.in_frame = false;
    // フレーム処理は内側ブロックに閉じ、ブロックを抜けたところで framebuffer を unlock する。
    // ファイルダイアログ（モーダル）は lock 中に呼ぶと再入で危険なので、ここでは pending を
    // セットするだけにし、unlock 後の安全点（下の runPendingFileOp）で実行する。
    {
        const fb = win.lockFramebuffer() orelse return;
        defer fb.unlock();

        self.ctx.beginFrame(fb.width, fb.height);

        // Command 表をイベント処理前に更新（ショートカット照合・probe 用。checked 反映）。
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
                .quit => self.requestClose(win), // ウィンドウクローズも同一経路
                // レイヤー名インライン編集中（TASK-79.3）・テキストレイヤー内容編集中
                // （TASK-79.5、`text_in`。rename_in と対称・互いに同時 active にならない）は
                // key_down を専用ハンドラへ回し、char_input で確定文字を追記する（TASK-22
                // char_input の初消費）。key_up は常に通す（Space パン modifier 等の held
                // 状態を編集中に取りこぼさないため。codex レビュー指摘 2026-07-05）。
                // TASK-144.2: size_dialog 中は shortcut を流さず Esc=cancel / Enter=OK。
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
            // renaming/テキスト編集中は gui へのマウス/キーイベント転送も止める（他行クリック等
            // での干渉を避ける。rename_in/text_in はここで破棄されないため、他行の右クリックで
            // 新たな編集が始まれば単に上書きされるだけでクラッシュはしない）。
            // size_dialog 中は char_input を GUI へ渡し、Enter/Esc は上で消費済みなので再送しない。
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

        // canvas rect は前フレームの layout 結果（初回フレームは null）。
        // canvasBlitRect はカメラ原点を現 area に clamp して app へ書き戻し、last_area も更新する。
        var canvas_rect = canvasBlitRect(&self.ctx, self);

        self.tickTimelinePlayback(platform.getTime());

        try buildUi(&self.ctx, self, canvas_rect);
        self.ctx.endFrame();
        // endFrame が GUI の draw command を確定した後に追加し、確認 UI を最前面へ置く。
        try drawAppshellOverlay(&self.ctx, self);

        // GUI fallback ドロップダウン（endFrame 後契約。popup.zig と同型）。
        // native 有効時はスキップ（OS メニューバーが所有。TASK-97.3）。
        if (!self.native_menu_active) {
            const menu_res = gui.menuBarPopup(&self.ctx, self.menuCommandsSlice(), &self.menu_bar_state);
            if (menu_res.selected) |id| self.dispatchCommand(id);
            // View トグル後に checked を即反映（同一フレームの probe 用）
            if (menu_res.selected != null) self.rebuildMenuCommands();
        } else {
            // View トグル等で checked が変わった場合に dirty-gate 経由で updateMenu
            self.rebuildMenuCommands();
            self.syncNativeMenu(win);
        }

        // TASK-142: テキスト編集（本文入力 or レイヤー名 rename）がアクティブな間だけ keyDown を
        // IME へ渡す。非アクティブ時は IME 有効中でも修飾なしキーがツール/ショートカットとして届く。
        win.setTextInputActive(self.text_in.active or self.rename_in.active);

        // IME 候補窓の基準 caret。rect cache は endFrame 後に確定するため、この時点で供給する。
        // preedit の有無でゲートしない: IME は composition 開始打鍵の handleEvent 中（= app が
        // 新 rect を供給する前）に窓位置を決めるため、入力 UI がアクティブな間は常に caret を
        // 指しておく（stale rect による初回表示ずれの実機指摘 2026-07-17）。
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
                    .h = @intCast(self.ctx.font.metrics().line_height),
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

        // ── ビューポート: ホイールズーム（zoom-to-cursor）/ パン（Space+左 / middle / Cmd+左）──
        // パン中は描画入力を抑止（既存 stroke 完走を妨げないよう pan は capturing 中に開始しない）。
        // TASK-144.2: size_dialog 中は viewport 操作も止める。
        const panning = if (self.size_dialog != null) false else updateViewport(self, &self.ctx);
        // zoom/pan が変わり得たので、当フレームの入力・描画が「旧 rect + 新 zoom」で不整合に
        // ならないよう rect を再計算する（endFrame 後なので area は当フレームの layout 結果。O(1)）。
        canvas_rect = canvasBlitRect(&self.ctx, self);

        // ── canvas 入力。capturing 最優先（既存 stroke を完走）。bezier は独立経路 ──
        // TASK-79.5: 選択中レイヤーが text kind の間は、この分岐全体（bezier/select/
        // eyedropper/通常 canvas_input のいずれも）を丸ごと止める。「text layer の pixels は
        // text_params からの再ラスタライズ結果」という不変条件を守るため（eyedropper は
        // 本来読み取りのみで実害は無いが、分岐追加のミスリスクよりシンプルさを優先し
        // 丸ごと止める設計判断。text layer 選択中は色スポイトも一時的に使えない）。
        // TASK-144.2: size_dialog != null でも同様にブロック。
        if (!panning and !self.selectedLayerIsText() and self.size_dialog == null) {
            const in = &self.ctx.input;
            // 新規 stroke 開始の gate（TASK-42）: press が canvas area(last_area) 内 かつ gui（widget/
            // splitter）が press を取っていない（!wantsMouse）時だけ新規開始を許可。進行中 stroke は
            // pressed_left のみ落として update は通し、release を届けて完走させる（capturing 張り付き防止）。
            const pressed_left_gated = in.mouse_pressed.left and gate: {
                const p = in.mouse_pressed_pos;
                const in_area = if (self.last_area) |a|
                    (p.x >= a.x and p.y >= a.y and p.x < a.x + a.w and p.y < a.y + a.h)
                else
                    false;
                // active_id==0 = どの widget/splitter も press を取っていない（hover だけの wantsMouse は
                // 抑止しない＝canvas 内 press → 同一フレーム UI 上へ move でも stroke は開始できる）。
                // !hasOpenPopup() = レイヤー右クリックメニュー（TASK-79.2）表示中は新規 stroke を
                // 開始しない（popup は active_id を 0 のまま保つため、上の条件だけでは防げない。
                // popup.zig の wantsMouse() が popup_state を OR しているのと同じ理由）。
                break :gate in_area and self.ctx.state.active_id == 0 and !self.ctx.hasOpenPopup();
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
                    self.doc.pushPaintOp(self.gpa, pd.layer_idx, pd.diffs) catch {}; // text layer 選択中はこの分岐に到達しない
                }
            } else if (self.active_kind.isShape() and !self.input.capturing) {
                // シェイプ（独立経路。TASK-90）。press→drag→release で shape 確定。
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
                // shape_in.kind / fill は UI・setActiveKind で同期済み
                if (self.shape_in.update(frame, self.canvas, &self.recorder, self.gpa, self.palette.current())) |pd| {
                    switch (actions.uiPaintCommitPath(platform.netsyncActive(), true)) {
                        .relay => {
                            // netsync: preview を巻き戻し → action shape で再適用
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
                    self.doc.pushPaintOp(self.gpa, pd.layer_idx, pd.diffs) catch {}; // text layer 選択中はこの分岐に到達しない
                }
            } else if (self.eye_in.picking or self.active_kind == .eyedropper or
                (pressed_left_gated and in.modifiers.alt))
            {
                // スポイト（独立経路。TASK-68）。専用ツール選択中、または進行中の picking を完走、
                // または Alt+クリックの一時スポイト（bezier/select は上の分岐で既に弾かれているので
                // ここに来る active_kind は pen/eraser/brush/fill/eyedropper のいずれか。4ツール
                // 全てで Alt+クリックを一律有効にする最小の場合分け）。
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
                // ── UI stroke の点列追跡（TASK-62.5.3 §5c。canvas_input の down/move/up と同じ座標変換）──
                if (canvas_rect) |rect| {
                    if (pd_opt != null) {
                        // release で確定（同一フレーム press+release は begin から。up は released_pos）
                        if (!was_capturing) self.uiStrokeBegin(core.screenToCanvasRaw(frame.mouse_pressed_pos, rect, frame.zoom));
                        self.uiStrokeAppend(core.screenToCanvasRaw(frame.mouse_released_pos, rect, frame.zoom));
                    } else if (!was_capturing and self.input.capturing) {
                        // capture 開始（down=pressed_pos + 同フレーム move=mouse_pos）
                        self.uiStrokeBegin(core.screenToCanvasRaw(frame.mouse_pressed_pos, rect, frame.zoom));
                        self.uiStrokeAppend(core.screenToCanvasRaw(frame.mouse_pos, rect, frame.zoom));
                    } else if (self.input.capturing) {
                        self.uiStrokeAppend(core.screenToCanvasRaw(frame.mouse_pos, rect, frame.zoom));
                    }
                }
                if (pd_opt) |pd| {
                    // TASK-94 Phase C: netsync 中は preview を巻き戻し → routeAction("stroke")。
                    // fill 等（action 語彙なし）は rewind 破棄（silent diverge 防止）。
                    // solo は従来どおり pushPaintOp + recordUiStroke。
                    switch (actions.uiPaintCommitPath(platform.netsyncActive(), self.uiStrokeRelaysViaAction())) {
                        .relay => {
                            self.rewindPaintDiff(pd);
                            self.relayUiStroke();
                        },
                        .rewind_discard => {
                            self.rewindPaintDiff(pd);
                            self.uiStrokeDiscard();
                            std.debug.print("pixie: netsync 中は fill 等は使えません（action 語彙なし・preview を破棄）\n", .{});
                            self.setSaveMsg("netsync: fill unavailable (no action)", .{});
                        },
                        .solo => {
                            const handle_before = self.doc.undo.next_handle;
                            self.doc.pushPaintOp(self.gpa, pd.layer_idx, pd.diffs) catch {}; // text layer 選択中はこの分岐に到達しない
                            // 確定点で CommandRecord を記録（actor=local_user。undo_ref = push された Op の handle）
                            self.recordUiStroke(self.doc.undo.next_handle != handle_before);
                        },
                    }
                } else if (!self.input.capturing) {
                    self.uiStrokeDiscard(); // release したが確定 diff なし → 蓄積破棄
                }
            }
        }

        // ── ソフトオーバーレイ用 hover 追跡 + OS カーソル形状の M1 配線（TASK-75.4）。
        // 入力ディスパッチの後に置くことで、当フレームで新規 stroke が始まった場合の busy 判定
        // （isPointerBusy）を正しく反映する（描画パスで footprint リングが一瞬出ることを防ぐ）。
        updateCursorAndHover(self, win.*, &self.ctx, canvas_rect);

        // ── 描画: bg → チェッカー背景 → canvas blit(α src-over) → GUI（上に重ねる） ──
        @memset(fb.pixels, COLOR_WINDOW_BG);
        if (canvas_rect) |rect| {
            if (self.last_area) |area| {
                const zoom = self.view_zoom;
                const cw = self.doc.width;
                const ch = self.doc.height;
                // 表示矩形（screen px 実寸。canvasBlitRect の rect.w/h は canvas px なので zoom 倍）
                const screen_rect: core.Rect = .{
                    .x = rect.x,
                    .y = rect.y,
                    .w = @as(i32, @intCast(cw)) * zoom,
                    .h = @as(i32, @intCast(ch)) * zoom,
                };
                blit.drawCheckerboard(fb.pixels, fb.width, fb.height, screen_rect, area);
                const base_composite = self.resolveDisplayComposite(self.gpa);
                const display_composite: []const u32 = if (self.onion_enabled and self.doc.frames.items.len > 1) blk: {
                    const cnt = @min(self.onion_count, core.onion_skin.max_count);
                    core.onion_skin.build(&self.doc, base_composite, self.doc.selected_frame, cnt, self.onion_buf, self.onion_scratch);
                    break :blk self.onion_buf;
                } else base_composite;
                blit.blitCanvasZoom(fb.pixels, fb.width, fb.height, display_composite, cw, ch, rect, zoom, area);
            }
        }
        // TASK-103: presence overlay（canvas blit の直後・bezier/selection より下）
        drawPresenceOverlay(self, canvas_rect);
        // ベジェ編集中のハンドル/アンカー UI を draw_list へ（プレビューの上、gui.render で焼かれる。area で clip）
        if (self.active_kind == .bezier) {
            if (canvas_rect) |rect| if (self.last_area) |area| {
                const clip_area: gui.Rect = .{ .x = area.x, .y = area.y, .w = @intCast(area.w), .h = @intCast(area.h) };
                bezier_overlay.draw(&self.ctx, &self.bezier_editor, rect, self.view_zoom, clip_area);
            };
        }
        // 範囲選択のマーチングアンツ（選択があれば常時表示。select ツール時はドラッグ中の preview を優先）
        {
            const display_sel: ?core.Rect = if (self.active_kind == .select)
                (self.sel_in.previewRect(self.canvas) orelse self.canvas.selection)
            else
                self.canvas.selection;
            if (display_sel != null) {
                if (canvas_rect) |rect| if (self.last_area) |area| {
                    const clip_area: gui.Rect = .{ .x = area.x, .y = area.y, .w = @intCast(area.w), .h = @intCast(area.h) };
                    // phase は時間由来。MARCH_PERIOD(=2*DASH) で mod し i32 overflow を防ぐ（パターンは保存）。
                    const phase: i32 = @intFromFloat(@mod(platform.getTime() * MARCH_SPEED, MARCH_PERIOD));
                    selection_overlay.draw(&self.ctx, display_sel, rect, self.view_zoom, clip_area, phase);
                };
            }
        }
        // シェイプドラッグ中の輪郭プレビュー（TASK-90）
        if (self.active_kind.isShape() and self.shape_in.state == .dragging) {
            if (canvas_rect) |rect| if (self.last_area) |area| {
                const clip_area: gui.Rect = .{ .x = area.x, .y = area.y, .w = @intCast(area.w), .h = @intCast(area.h) };
                shape_overlay.draw(&self.ctx, &self.shape_in, rect, self.view_zoom, clip_area);
            };
        }
        // ツールグリフ + ブラシ footprint 輪郭リング（ソフトオーバーレイ最前面。TASK-75.4）。
        // hover_screen は「in_canvas かつ非 busy」の時だけ Some（updateCursorAndHover 参照）なので、
        // stroke/選択ドラッグ/ベジェドラッグ/パン中はここに来ない。
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
        // レイヤー右クリックコンテキストメニュー（TASK-79.2）。popup.zig の「endFrame 後」契約
        // + 他のオーバーレイ（bezier/selection/cursor）より後に呼ぶことで最前面に描画される。
        // 呼び出しは毎フレーム無条件でよい（対象 popup が閉じていれば no-op で即返る。
        // popup.zig の doc comment 参照）。items は selected_layer の現在値から都度算出する
        // （右クリック時に doSelectLayer 済みなので、以降の全項目は selected_layer に対して動く）。
        {
            const sel_is_text = self.selectedLayerIsText();
            const items = [_]gui.PopupItem{
                .{ .label = "Add Layer" },
                .{ .label = "Add Text Layer" }, // TASK-79.5
                .{ .label = "Delete Layer", .enabled = self.canvas.layers.items.len > 1 },
                .{ .label = "Move Up", .enabled = self.canvas.selected_layer + 1 < self.canvas.layers.items.len },
                .{ .label = "Move Down", .enabled = self.canvas.selected_layer > 0 },
                .{ .label = if (self.canvas.layers.items[self.canvas.selected_layer].visible) "Hide" else "Show" },
                .{ .label = "Duplicate" },
                .{ .label = "Merge Down", .enabled = self.canvas.selected_layer > 0 and !sel_is_text and
                    self.canvas.layers.items[self.canvas.selected_layer - 1].kind != .text },
                .{ .label = "Rename..." }, // TASK-79.3
                .{ .label = "Edit Text...", .enabled = sel_is_text }, // TASK-79.5
                .{ .label = "Rasterize", .enabled = sel_is_text }, // TASK-79.5
            };
            const ctx_menu_result = self.ctx.popupMenu(LAYER_CTX_MENU_ID, &items);
            if (ctx_menu_result.selected) |sel| {
                const sel_idx = self.canvas.selected_layer;
                const synced = platform.netsyncActive();
                switch (sel) {
                    0 => {
                        if (synced) self.routeUi("add_layer", "") else _ = self.doAddLayer() catch {};
                    },
                    1 => self.doAddTextLayer() catch {}, // action 未登録・relay 対象外
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
        gui.render(
            .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height },
            &self.ctx.draw_list,
            self.ctx.font,
        );
        win.present();
    } // ← ここで framebuffer unlock
}

fn appFrame(self: *App, win: *platform.Window, now: f64) !bool {
    try appFrameInner(self, win);

    // 安全点: framebuffer unlock 済み・当フレームの入力更新も完了。ここでモーダルを開く。
    // 終了要求と同フレームで保存/読込が pending でも、終了中はダイアログを開かない。
    if (self.running) self.runPendingFileOp();

    if (self.running and self.recovery == null and !platform.netsyncActive()) {
        _ = self.autosave.tick(now, self, snapshotProject) catch |err| self.setSaveMsg("Autosave failed: {s}", .{@errorName(err)});
    }

    // フレーム末尾: 未記録 undoable 編集の検出 → redo 候補の epoch 失効（TASK-62.5.4 §2b）
    self.checkUnrecordedEdits();

    return self.running;
}

/// ライブリサイズ redraw callback（TASK-23.1）。OS モーダルループ中に backend から呼ばれ 1 フレーム描く。
/// エラーは log して当該フレームを skip（callback は void）。
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
