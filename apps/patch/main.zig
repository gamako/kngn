//! apps/patch (run-patch): visually displays a minimal patch on the dynamic graph engine (DynGraph)
//! as a patch-canvas UI.
//!
//! Modules are drawn as node rectangles plus port dots (kind colours audio/cv/gate) plus cable lines; pan (background drag) /
//! zoom (scroll, cursor-anchored) / node drag / hover and selection of node, port, and cable are supported.
//! Live cable rewiring and audio are also supported.
//!
//! UI layout state (node world positions, camera, hover, selected, group ledger) lives on the GUI (main thread)
//! and is kept separate from the RT graph description (connections/order) — not published. Drawing reads currentView()'s
//! published topology for display.
//! Pure geometry / hit-test / clip logic lives in canvas.zig (platform-free; unit-tested via test-patch).
//!
//! Groups/macros (DrumMachine) display as a single collapsed node box; expanding reveals the internal
//! primitive subgraph (one level of nesting). Macro members exist as ordinary primitive modules on
//! dyn; which handle belongs to which macro / whether it is collapsed / which ports face outward is
//! pure UI state in `group.Ledger` (App.ledger in this file; not published). Synthetic handles
//! (`>= group.GROUP_HANDLE_BASE`) are used only as arguments/return values of canvas geometry helpers — never as
//! dyn accessors, `app.layout[h]` indices, or `dyn.disconnect` targets (resolve to a real PortRef via
//! `group.resolvePort` before existing commitConnect paths). See comments in group.zig.
//! ESC / close quits.

const std = @import("std");
const builtin = @import("builtin");
const kit = @import("kit"); // Public umbrella (ADR-007 R4/R5: apps are kit-only consumers)
const platform = kit.platform;
const gui = kit.gui;
const appshell = kit.appshell;
const stepgrid = gui.stepgrid;
const modular = @import("modular");
const pixelops = @import("pixelops"); // app → lib exception (see build.zig linkAppException)
const audio = kit.audio;
const synth = kit.synth; // SampleTap (Audio→GUI output tap; C master visualisation)
const midi = kit.midi;
const dsp = kit.dsp; // mono downmix
const spectrogram = @import("spectrogram");
const scope = @import("scope");
const recipe = kit.recipe;
const patchmod = @import("lofi.zig");
const LofiPatch = patchmod.LofiPatch;
const PatternCommand = patchmod.PatternCommand;
const PatchState = patchmod.PatchState;
const SongData = patchmod.SongData;
const Chain = patchmod.Chain;
const BASS_DEG_TOTAL: usize = patchmod.BASS_DEG_TOTAL;
const canvas = @import("canvas.zig");
const inspector = @import("inspector.zig");
const param_view = @import("param_view.zig");
const group = @import("group.zig");
const layout_mod = @import("layout.zig");
const macro = @import("macro.zig");
const actions = @import("actions.zig");
const gen_actions = @import("gen_actions.zig");
const graph_io = @import("graph_io.zig");
const pattern_io = @import("pattern_io.zig");
const project_io = @import("project_io.zig");
const wav = @import("wav.zig");
const seedmod = @import("seed.zig");
const patch_undo = @import("undo.zig");
const selection = @import("selection.zig");

const DynGraph = modular.DynGraph;
const PortKind = modular.PortKind;
const Handle = canvas.Handle;
const Vec2f = canvas.Vec2f;
const Camera = canvas.Camera;
const NodeGeom = canvas.NodeGeom;
const Edge = canvas.Edge;
const PortRef = canvas.PortRef;

const MAX_MODULES = modular.dyn.MAX_MODULES;
const MAX_OUT = modular.signal.MAX_OUT;
const MAX_IN = modular.signal.MAX_IN;
const MAX_EDGES = MAX_MODULES * MAX_IN;
// Per-port tap constants (modular is the single source).
const TAP_SLOTS = modular.graph_core.TAP_SLOTS;
const TAP_RING = modular.graph_core.TAP_RING;

// group.zig does not import modular, so GROUP_HANDLE_BASE comes from build_options.max_modules (same source as MAX_MODULES).
// A comptime check catches mismatches if dyn.zig MAX_MODULES and group.zig GROUP_HANDLE_BASE diverge.
comptime {
    if (group.GROUP_HANDLE_BASE != MAX_MODULES) {
        @compileError("group.GROUP_HANDLE_BASE must equal modular.dyn.MAX_MODULES");
    }
    if (group.MAX_OUT_PORTS != MAX_OUT) {
        @compileError("group.MAX_OUT_PORTS must equal modular.signal.MAX_OUT");
    }
}

// ----------------------------------------------------------------------------
// Fixed MIDI CC → GenRole/descriptor map (MVP; no learn UI)
// ----------------------------------------------------------------------------
const MidiParamTarget = struct {
    role: project_io.GenRole,
    param: []const u8,
};

const MidiCcBinding = struct {
    controller: u8,
    label: []const u8,
    targets: []const MidiParamTarget,
    curve: patchmod.MidiCcCurve,
    min: f32,
    max: f32,
};

const MIDI_CC_MAP = [_]MidiCcBinding{
    .{
        .controller = 1,
        .label = "tempo",
        .targets = &[_]MidiParamTarget{.{ .role = .clock, .param = "bpm" }},
        .curve = .linear,
        .min = 60.0,
        .max = 180.0,
    },
    .{
        .controller = 7,
        .label = "master_gain",
        .targets = &[_]MidiParamTarget{.{ .role = .master_mixer, .param = "gain" }},
        .curve = .linear,
        .min = 0.0,
        .max = 1.5,
    },
    .{
        .controller = 16,
        .label = "pad_warmth",
        .targets = &[_]MidiParamTarget{.{ .role = .pad, .param = "warmth" }},
        .curve = .linear,
        .min = 0.0,
        .max = 1.0,
    },
    .{
        .controller = 71,
        .label = "sidechain",
        .targets = &[_]MidiParamTarget{.{ .role = .sidechain, .param = "amount" }},
        .curve = .linear,
        .min = 0.0,
        .max = 1.0,
    },
    .{
        .controller = 74,
        .label = "cutoff",
        .targets = &[_]MidiParamTarget{.{ .role = .master_vcf, .param = "cutoff" }},
        .curve = .exponential,
        .min = 80.0,
        .max = 18000.0,
    },
};

comptime {
    // Controllers must not duplicate. Descriptor coverage is checked at runtime by midiBindingDescriptorsExist().
    for (MIDI_CC_MAP, 0..) |a, i| {
        for (MIDI_CC_MAP[i + 1 ..]) |b| {
            if (a.controller == b.controller) @compileError("MIDI_CC_MAP: duplicate controller");
        }
    }
}

fn midiRoleKind(role: project_io.GenRole) modular.ModuleKind {
    return switch (role) {
        .clock => .clock,
        .pad => .chord_pad,
        .sidechain => .sidechain,
        .master_mixer => .mixer,
        .master_vcf => .vcf,
        else => .clock, // Roles absent from the table are unreachable (only MIDI_CC_MAP targets).
    };
}

fn midiBindingDescriptorsExist() bool {
    // Every target points at a known descriptor.
    for (MIDI_CC_MAP) |binding| {
        for (binding.targets) |t| {
            const kind = midiRoleKind(t.role);
            const descs: []const modular.ParamDesc = switch (kind) {
                inline else => |k| modular.descriptors(k),
            };
            var found = false;
            for (descs) |d| {
                if (std.mem.eql(u8, d.name, t.param)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
    }
    return true;
}

/// Canonical app name for recipe / diagnostics (compatible with existing modular recipes).
const APP_NAME = "modular";

const WIN_W = 960;
// Add a visualisation strip (VIS_H) at the bottom (canvas usable height = fb_h - VIS_H).
const WIN_H = 760;
const BG: u32 = 0xFF12161B;

// ---- Visualisation strip (C: master scope/spectrogram/level meter). Fixed band at the screen bottom. ----
/// Target frame period (60fps). Pacing is deadline-based.
const FRAME_PERIOD_S: f64 = 1.0 / 60.0;
const VIS_H = 150; // Strip height (canvas usable area = fb_h - VIS_H)
const VIS_LABEL_H = 16; // Label row at the top of the strip
const VIS_MARGIN = 6; // Bottom padding inside the strip
const VIS_DRAW_H = VIS_H - VIS_LABEL_H - VIS_MARGIN; // Spec/scope draw height (comptime)
const SPEC_X0 = 16;
const SPEC_W = 500;
const SCOPE_X0 = SPEC_X0 + SPEC_W + 12; // 528
const SCOPE_W = 300;
const METER_X0 = SCOPE_X0 + SCOPE_W + 12; // 840
const METER_W = 48;
const VIS_BG: u32 = 0xFF0A0E12; // Strip background
const Spec = spectrogram.Spectrogram(SPEC_W, VIS_DRAW_H);
const Scope = scope.Oscilloscope(SCOPE_W, VIS_DRAW_H);
const Tap = synth.SampleTap(8192);

const NODE_BG = gui.Color.rgba(0x24, 0x2A, 0x33, 0xFF);
const BORDER_COL = gui.Color.rgba(0x50, 0x58, 0x64, 0xFF);
const HOVER_COL = gui.Color.rgba(0x90, 0xA0, 0xB0, 0xFF);
const SEL_COL = gui.Color.rgba(0xE0, 0xC0, 0x50, 0xFF);
/// Rubber-band rectangle: translucent blue fill + blue border.
const RECT_SEL_FILL = gui.Color.rgba(0x40, 0x80, 0xE0, 0x40);
const RECT_SEL_OUTLINE = gui.Color.rgba(0x50, 0xA0, 0xF0, 0xFF);
const TITLE_COL = gui.Color.rgba(0xE0, 0xE6, 0xEE, 0xFF);
const GRID_COL = gui.Color.rgba(0x1A, 0x20, 0x28, 0xFF);

fn portColor(k: PortKind) gui.Color {
    return switch (k) {
        .audio => gui.Color.rgba(0xE0, 0x90, 0x40, 0xFF), // orange
        .cv => gui.Color.rgba(0x50, 0x90, 0xE0, 0xFF), // blue
        .gate => gui.Color.rgba(0x60, 0xC0, 0x70, 0xFF), // green
    };
}

/// A: blink port colour by activity level (0..1+). Scale base lightness in 0.30..1.0 (still visible when idle).
fn litColor(base: gui.Color, level: f32) gui.Color {
    const t = 0.30 + 0.70 * std.math.clamp(level, 0.0, 1.0);
    const sc = struct {
        fn f(v: u8, k: f32) u8 {
            return @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(v)) * k, 0.0, 255.0));
        }
    }.f;
    return gui.Color.rgba(sc(base.r, t), sc(base.g, t), sc(base.b, t), base.a);
}

const CableRef = canvas.CableRef;

const Item = union(enum) {
    node: Handle, // Always a real handle (synthetic handles use .group)
    port: PortRef, // Display/highlight may be synthetic (collapsed-box ports). Resolve to a real PortRef via resolvePort before dyn/commit
    cable: CableRef, // Stable id (dst_handle,dst_in). Always a real CableRef (via DisplayEdge.actual)
    group: group.GroupId, // Selection of a collapsed-box or expanded-frame header
};

const Drag = union(enum) {
    none,
    pan: struct { start_pan: Vec2f, start_mouse: Vec2f },
    node: struct { handle: Handle, grab_offset: Vec2f }, // node.pos = mouseWorld + grab_offset (always a real handle)
    // Collapsed-box drag: update ledger.groups[gid].pos and translate member layout slots by the same
    // delta (never index a synthetic handle into app.layout[h]). Expanded-frame headers are not draggable = selection only.
    group: struct { gid: group.GroupId, grab_offset: Vec2f },
    // Connection pending (ghost cable from origin port to cursor). detach!=null means a drag-off from a connected
    // input; disconnect is deferred until commit (mouse_up) so one gesture = at most one publish and a failed/
    // invalid drop does not break the existing connection. origin may be synthetic for display/highlight (when
    // grabbing a collapsed-box port). On commit (mouse_up), resolvePort to a real PortRef before dyn/commitConnect.
    // detach is set only when grabbing a connected input, and is already resolvePort'd = always a real CableRef.
    cable: struct { origin: PortRef, detach: ?CableRef = null },
    /// Rubber-band rect select on empty-canvas left-drag. additive=Shift/Cmd adds to the set.
    /// With Option(Alt) held this variant is not used — becomes `.pan` (trackpad pan alternative).
    rect_select: struct { start_world: Vec2f, additive: bool },
};

// Module palette (screen-fixed; independent of pan/zoom). Click runs add(kind,.{}) for primitives, or the
// macro builder (preflight+add+connect+1publish → ledger register) for macros.
const PaletteEntry = union(enum) {
    primitive: modular.ModuleKind,
    macro_kind: group.MacroKind,
    /// Standalone step_seq of bass kind (existing `.primitive = .step_seq` remains drum).
    step_seq_bass: void,
};
const PALETTE = [_]PaletteEntry{
    .{ .primitive = .vco },
    .{ .primitive = .vcf },
    .{ .primitive = .lfo },
    .{ .primitive = .mixer },
    .{ .primitive = .clock },
    .{ .primitive = .euclid },
    .{ .primitive = .kick },
    .{ .primitive = .delay },
    .{ .macro_kind = .drum_machine },
    .{ .macro_kind = .bass_machine },
    .{ .primitive = .step_seq },
    .{ .primitive = .slew },
    .{ .primitive = .sample_hold },
    .{ .primitive = .comparator },
    .{ .primitive = .ring_mod },
    .{ .primitive = .logic },
    .{ .step_seq_bass = {} },
};
const PAL_X0: f32 = 8;
const PAL_Y: f32 = 2;
const PAL_W: f32 = 92;
const PAL_H: f32 = 18;
const PAL_GAP: f32 = 2;
const PAL_COLS_MAX: usize = 10;
const PAL_BG = gui.Color.rgba(0x2C, 0x32, 0x3C, 0xFF);
const PAL_BG_HOVER = gui.Color.rgba(0x3A, 0x44, 0x52, 0xFF);
const PENDING_COL = gui.Color.rgba(0xC0, 0xC0, 0xC0, 0xFF);
const MAX_PARAM_EDITS: usize = patchmod.MAX_PARAM_OVERRIDES;

// ── File menu ──────────────────────────────────────────────────────────────
// GUI-fallback row height (box padding 4+4 + button ≈24). Native: 0 (OS menu bar).
const MENU_GUI_H: f32 = 32;
const MENU_CMD_CAP: usize = 24;
const MenuFileOp = enum { save_project, open_project };
const CmdId = struct {
    pub const save_project: platform.CommandId = 1;
    pub const open_project: platform.CommandId = 2;
    pub const quit: platform.CommandId = 3;
    pub const undo: platform.CommandId = 4;
    pub const redo: platform.CommandId = 5;
    pub const toggle_history: platform.CommandId = 6;
};

// Local-only meta ring for History display (ops that do not enter CommandLog).
const MAX_META_EVENTS: usize = 64;
const META_SUMMARY_CAP: usize = 96;
const HISTORY_LINE_CAP: usize = 160;
const HISTORY_SCROLL_ID: gui.Id = 0x1493_0001;
const MetaEvent = struct {
    /// Latest cmd_log seq at append time (0 = no command recorded). Merge-display order key.
    after_seq: u64 = 0,
    summary_buf: [META_SUMMARY_CAP]u8 = undefined,
    summary_len: u8 = 0,

    fn summary(self: *const MetaEvent) []const u8 {
        return self.summary_buf[0..self.summary_len];
    }
};

/// Column count that fits the canvas width (button.x + button.w <= canvas_w; max PAL_COLS_MAX).
fn paletteCols(canvas_w: f32) usize {
    const cell = PAL_W + PAL_GAP;
    if (canvas_w <= PAL_X0 + PAL_W) return 1;
    const avail = canvas_w - PAL_X0 - PAL_W;
    const extra: usize = @intFromFloat(@floor(@max(0.0, avail) / cell));
    return @min(PAL_COLS_MAX, extra + 1);
}

fn paletteRowCount(canvas_w: f32) usize {
    const cols = paletteCols(canvas_w);
    return (PALETTE.len + cols - 1) / cols;
}

/// Bottom of the palette band (absolute screen coords. Row count depends on center width. Upper bound for clampMacroPos).
fn paletteBottom(app: *const App) f32 {
    const rows: f32 = @floatFromInt(paletteRowCount(app.canvasW()));
    return app.canvas_rect.y + PAL_Y + rows * (PAL_H + PAL_GAP);
}

/// Module palette in center-rect space (absolute screen coords).
fn paletteButtons(app: *const App) [PALETTE.len]canvas.PaletteButton {
    const canvas_w = app.canvasW();
    const cols = paletteCols(canvas_w);
    const ox = app.canvas_rect.x;
    const oy = app.canvas_rect.y + PAL_Y;
    var btns: [PALETTE.len]canvas.PaletteButton = undefined;
    for (0..PALETTE.len) |i| {
        const col = i % cols;
        const row = i / cols;
        const x: f32 = @floatFromInt(col);
        const y: f32 = @floatFromInt(row);
        btns[i] = .{ .kind_index = @intCast(i), .rect = .{
            .x = ox + PAL_X0 + x * (PAL_W + PAL_GAP),
            .y = oy + y * (PAL_H + PAL_GAP),
            .w = PAL_W,
            .h = PAL_H,
        } };
    }
    return btns;
}

const CUTOFF_MIN: f32 = patchmod.MASTER_CUTOFF_MIN;
const CUTOFF_MAX: f32 = patchmod.MASTER_CUTOFF_MAX;

const Params = struct {
    // The following tempo..mute fields are deprecated SPRM v1-compatible storage.
    // The live graph authority is NPRM descriptors / param_db. Transport UI does not read or write them.
    tempo: f32 = 122.0,
    cutoff_norm: f32 = 1.0,
    density: f32 = 0.25,
    swing: f32 = 0.0,
    sidechain: f32 = 0.35,
    kick_gain: f32 = 1.0,
    hat_gain: f32 = 1.0,
    clap_gain: f32 = 1.0,
    bass_gain: f32 = 1.0,
    pad_gain: f32 = 1.0,
    kick_mute: bool = false,
    hat_mute: bool = false,
    clap_mute: bool = false,
    bass_mute: bool = false,
    pad_mute: bool = false,
    kick_punch: f32 = 1.0,
    hat_bright: f32 = 1.0,
    hat_decay: f32 = 0.045,
    pad_cutoff: f32 = 1400.0,
    pad_warmth: f32 = 0.6,
    master_warmth: f32 = 0.5,
    ambient_move: f32 = 0.4,
};

const FrameParamSnapshot = struct {
    key: param_view.FieldKey = .{},
    snapshot: modular.ParamSnapshot = .{ .field = .{ .scalar = 0.0 } },
    valid: bool = false,
};

const ParamRowSnapshot = struct {
    key: param_view.FieldKey = .{},
    rect: gui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    valid: bool = false,
};

fn cutoffRange() param_view.CutoffRange {
    return .{ .min = CUTOFF_MIN, .max = CUTOFF_MAX };
}

fn cutoffHz(norm: f32) f32 {
    return param_view.cutoffHz(norm, cutoffRange());
}

/// Publish tone macros only into Controls.
/// tempo/cutoff/swing/sidechain/density/gain/mute are owned by graph descriptors (NPRM / param_db).
fn publishControls(patch: *LofiPatch, p: Params) void {
    const c = &patch.controls;
    c.kick_punch.store(p.kick_punch);
    c.hat_bright.store(p.hat_bright);
    c.hat_decay.store(p.hat_decay);
    c.pad_cutoff.store(p.pad_cutoff);
    c.pad_warmth.store(p.pad_warmth);
    c.master_warmth.store(p.master_warmth);
    c.ambient_move.store(p.ambient_move);
}

/// One-shot apply of legacy SPRM / Params transport fields into graph param_db.
/// For load_pattern (no NPRM) and offline render. Not called on a full KNGN load where NPRM is authoritative.
/// Params is deprecated storage (not the live authoritative source).
fn publishDeprecatedGraphFromParams(patch: *LofiPatch, p: Params) void {
    var batch: patchmod.ParamBatch = .{};
    batch.revision = 1;
    batch.entries[0] = .{ .handle = patch.clock_h, .name = "bpm", .value = .{ .scalar = p.tempo }, .touched = true };
    batch.entries[1] = .{ .handle = patch.clock_h, .name = "swing", .value = .{ .scalar = p.swing }, .touched = true };
    batch.entries[2] = .{ .handle = patch.master_vcf_h, .name = "cutoff", .value = .{ .scalar = cutoffHz(p.cutoff_norm) }, .touched = true };
    batch.entries[3] = .{ .handle = patch.sidechain_h, .name = "amount", .value = .{ .scalar = p.sidechain }, .touched = true };
    batch.entries[4] = .{ .handle = patch.kick_seq_h, .name = "density", .value = .{ .scalar = p.density }, .touched = true };
    batch.entries[5] = .{ .handle = patch.hat_seq_h, .name = "density", .value = .{ .scalar = p.density }, .touched = true };
    batch.entries[6] = .{ .handle = patch.clap_seq_h, .name = "density", .value = .{ .scalar = p.density }, .touched = true };
    batch.entries[7] = .{ .handle = patch.bass_seq_h, .name = "density", .value = .{ .scalar = p.density }, .touched = true };
    batch.entries[8] = .{ .handle = patch.master_mixer_h, .name = "in0_gain", .value = .{ .scalar = p.kick_gain }, .touched = true };
    batch.entries[9] = .{ .handle = patch.nonkick_mixer_h, .name = "in0_gain", .value = .{ .scalar = p.hat_gain }, .touched = true };
    batch.entries[10] = .{ .handle = patch.nonkick_mixer_h, .name = "in1_gain", .value = .{ .scalar = p.clap_gain }, .touched = true };
    batch.entries[11] = .{ .handle = patch.nonkick_mixer_h, .name = "in2_gain", .value = .{ .scalar = p.bass_gain }, .touched = true };
    batch.entries[12] = .{ .handle = patch.nonkick_mixer_h, .name = "in3_gain", .value = .{ .scalar = p.pad_gain }, .touched = true };
    batch.entries[13] = .{ .handle = patch.master_mixer_h, .name = "in0_mute", .value = .{ .choice = @intFromBool(p.kick_mute) }, .touched = true };
    batch.entries[14] = .{ .handle = patch.nonkick_mixer_h, .name = "in0_mute", .value = .{ .choice = @intFromBool(p.hat_mute) }, .touched = true };
    batch.entries[15] = .{ .handle = patch.nonkick_mixer_h, .name = "in1_mute", .value = .{ .choice = @intFromBool(p.clap_mute) }, .touched = true };
    batch.entries[16] = .{ .handle = patch.nonkick_mixer_h, .name = "in2_mute", .value = .{ .choice = @intFromBool(p.bass_mute) }, .touched = true };
    batch.entries[17] = .{ .handle = patch.nonkick_mixer_h, .name = "in3_mute", .value = .{ .choice = @intFromBool(p.pad_mute) }, .touched = true };
    patch.publishParamBatch(batch);
}

fn stateToCommand(st: PatchState) PatternCommand {
    return .{
        .rev = st.pattern_rev,
        .evolve = st.evolve,
        .kick = .{ .on = st.kick_on, .lock = st.lock[0] },
        .hat = .{ .on = st.hat_on, .lock = st.lock[1] },
        .clap = .{ .on = st.clap_on, .lock = st.lock[2] },
        .bass = .{ .on = st.bass_on, .accent = st.bass_accent, .slide = st.bass_slide, .deg = st.bass_deg, .lock = st.lock[3] },
    };
}

inline fn bitOf(s: u8) u16 {
    return @as(u16, 1) << @as(u4, @intCast(s & 15));
}

fn b01(v: bool) u8 {
    return if (v) 1 else 0;
}

/// Hold the inspector-slider before-value at drag start; on release record one
/// undoable set_param (do not record the continuous overrides during the drag).
const App = struct {
    /// Sole owner of the generation layer and DynGraph. The patch is heap-fixed and not moved from RT userdata.
    patch: *LofiPatch,
    /// Non-owning alias that existing canvas code references. The real object is always patch.graph.
    dyn: *DynGraph,
    layout: [MAX_MODULES]Vec2f = [_]Vec2f{.{ .x = 0, .y = 0 }} ** MAX_MODULES,
    ledger: group.Ledger = .{},
    camera: Camera = .{},
    mouse: Vec2f = .{ .x = 0, .y = 0 },
    hover: ?Item = null,
    selected: ?Item = null,
    /// Multi-node selection set (real handles + group synthetic handles). Independent of App.selected.
    multi_selected: [group.GROUP_HANDLE_BASE + group.MAX_GROUPS]bool =
        [_]bool{false} ** (group.GROUP_HANDLE_BASE + group.MAX_GROUPS),
    /// Inspector drill-down target (independent of canvas selected).
    /// When a group is selected, filled by member selection; when a node is selected, matches the selected node.
    inspector_target: ?Handle = null,
    drag: Drag = .none,
    fb_w: u32 = WIN_W,
    fb_h: u32 = WIN_H,
    // PanelHost owns the outer shape / open / visible of History(left) / Inspector(right).
    // Pointers into host/panels/gui_ctx on main's stack (outlive App).
    panel_host: *gui.PanelHost = undefined,
    panels: []gui.Panel = &.{},
    gui_ctx: *gui.Context = undefined,
    /// Small font for node titles (borrowed OutlineFont view owned by kit.GuiFont.
    /// Falls back to gui.default_font when not loaded).
    title_font: gui.Font = gui.default_font,
    /// PanelHost center rect (absolute screen coords). Shared origin for draw / hit / palette / camera.
    canvas_rect: canvas.ScreenRect = .{ .x = 0, .y = 0, .w = WIN_W, .h = WIN_H - VIS_H },
    /// One-shot auto-layout-done flag at startup.
    /// centerRect becomes non-null after the previous frame's endFrame, so the first apply runs inside the main loop.
    initial_layout_done: bool = false,
    // H key hides all. Temporary override of slot visible; on release restore pre_hide_* and keep open.
    panels_hidden: bool = false,
    pre_hide_left_visible: bool = true,
    pre_hide_right_visible: bool = true,
    // History panel ScrollArea and local-only meta ring.
    history_scroll: gui.Vec2f = .{},
    meta_events: [MAX_META_EVENTS]MetaEvent = [_]MetaEvent{.{}} ** MAX_META_EVENTS,
    meta_head: u32 = 0,
    meta_filled: u32 = 0,
    // appshell Preferences (panel/slot persistence; KNGN_APPSHELL_DIR).
    prefs: appshell.preferences.Preferences = undefined,
    prefs_dir: ?std.Io.Dir = null,
    prefs_dirty: bool = false,

    // C: master output tap + latest-block rms/peak (for viz probe; updated on GUI thread).
    tap: Tap = .{},
    master_rms: f32 = 0,
    master_peak: f32 = 0,

    // A: output-port activity peak-hold (GUI-local; zero RT impact). [handle][out].
    port_level: [MAX_MODULES][MAX_OUT]f32 = [_][MAX_OUT]f32{[_]f32{0} ** MAX_OUT} ** MAX_MODULES,

    // D: per-port tap state (GUI-owned). Slot i maps tap_display[i] (display handle for drawing) to
    // tap_ports[i] (real global port id; -1=empty). tap_slot_seq[i] = seq that published that assignment.
    tap_display: [TAP_SLOTS]Handle = [_]Handle{0} ** TAP_SLOTS,
    tap_ports: [TAP_SLOTS]i32 = [_]i32{-1} ** TAP_SLOTS,
    tap_slot_seq: [TAP_SLOTS]u32 = [_]u32{0} ** TAP_SLOTS,
    tap_count: usize = 0,
    tap_seq: u32 = 0,

    /// File I/O handle used by the `save_graph`/`load_graph` actions
    /// (`std.process.Init.io`. Event only. Never passed onto the RT path).
    io: std.Io,

    // Generation-app command/action state (actions are event-only).
    params: Params = .{},
    pattern_rev: u32 = 0,
    /// Last pattern main published. Even across consecutive edits before RT acquires the Mailbox,
    /// the next pattern action must not discard prior edits by basing itself on the RT snapshot.
    pending_pattern: ?PatternCommand = null,
    sample_rate: u32 = 48000,
    cmd_log: platform.command.CommandLog = .{},
    cmd_exec: platform.command.Executor = undefined,
    recipe_replaying: bool = false,
    notation_seed: u64 = seedmod.DEFAULT_BASE_SEED,
    notation_counter: u32 = 0,
    last_quantized_cmd: ?PatternCommand = null,
    song: SongData = .{},
    // Cumulative override table owned by main (Mailbox payload source).
    param_batch: patchmod.ParamBatch = .{},
    // Latest raw values from the fixed CC table (null if never received; for digest midi_map).
    midi_cc_raw: [MIDI_CC_MAP.len]?u8 = [_]?u8{null} ** MIDI_CC_MAP.len,
    // Pending op values shared by the Inspector, keyed per field.
    param_edits: [MAX_PARAM_EDITS]param_view.ParamEditState = [_]param_view.ParamEditState{.{}} ** MAX_PARAM_EDITS,
    // params probe observed defaults to master VCF cutoff. Switchable via action observe_param.
    observed_field: param_view.FieldKey = .{},
    frame_snapshots: [MAX_PARAM_EDITS]FrameParamSnapshot = [_]FrameParamSnapshot{.{}} ** MAX_PARAM_EDITS,
    frame_snapshot_count: usize = 0,
    param_rows: [MAX_PARAM_EDITS]ParamRowSnapshot = [_]ParamRowSnapshot{.{}} ** MAX_PARAM_EDITS,
    param_row_count: usize = 0,

    // Stable NodeId (relay/save/digest). Separate from runtime Handle; monotonic; never reused.
    next_node_id: u64 = 1,
    handle_to_id: [MAX_MODULES]?graph_io.NodeId = [_]?graph_io.NodeId{null} ** MAX_MODULES,
    // Last mutation_count the host distributed via pattern_state (change detection).
    last_pattern_state_mut: u32 = 0,
    // Peer count last frame. On increase, force a join pattern_state broadcast.
    last_broadcast_peer_count: usize = 0,

    // Fixed-length undo payload (CommandLog.undo_ref = gen). ~1.16MiB so heap-allocated (avoids Windows 1MB stack).
    undo_store: *patch_undo.PatchUndoStore,
    /// Before-state that a local GUI release passes into set_param. Keyed by param name;
    /// actionSetParam consumes it only when the incoming args param name matches (so a remote COMMIT for a
    /// different param cannot steal the pending). Single Optional: no concurrent multi-drag; one slider only.
    /// Known limit: if another peer changes the same param name while ours is pending, before may be slightly
    /// stale but not destructive (consume only on name match; otherwise fall back to the current value as before).
    pending_param_undo_before: ?patch_undo.ParamValueSnap = null,
    /// Capture before at Inspector (mode=1) drag start.
    /// On release move into pending_param_undo_before and routeUiAction("set_param").
    /// Single Optional: the UI never drags multiple sliders at once; hold one only.
    slider_drag_before: ?patch_undo.ParamValueSnap = null,

    // File menu (native NSMenu / GUI fallback) + dialog-mediated save/load.
    menu_commands: [MENU_CMD_CAP]platform.Command = undefined,
    menu_command_count: usize = 0,
    menu_bar_state: gui.MenuBarState = .{},
    native_menu_active: bool = false,
    pending_menu_op: ?MenuFileOp = null,
    menu_last_op: ?MenuFileOp = null,
    running: bool = true,

    /// GUI-fallback menu row height. When native is on, defer to the OS menu bar (0).
    fn menuTopH(self: *const App) f32 {
        return if (self.native_menu_active) 0 else MENU_GUI_H;
    }

    fn pointInMenuBar(self: *const App) bool {
        return !self.native_menu_active and self.mouse.y < self.menuTopH();
    }

    /// PanelHost center width (canvas viewport). Shared by clip / hit / tap / palette.
    fn canvasW(self: *const App) f32 {
        return @max(0.0, self.canvas_rect.w);
    }

    /// PanelHost center height (canvas viewport).
    fn canvasH(self: *const App) f32 {
        return @max(0.0, self.canvas_rect.h);
    }

    /// Y start of the bottom visualisation strip (absolute; VIS_H is outside PanelHost).
    fn vizBandY0(self: *const App) f32 {
        const fh: f32 = @floatFromInt(self.fb_h);
        return @max(0.0, fh - VIS_H);
    }

    /// Absolute screen → center-local (camera space).
    fn toCanvasLocal(self: *const App, screen: Vec2f) Vec2f {
        return .{ .x = screen.x - self.canvas_rect.x, .y = screen.y - self.canvas_rect.y };
    }

    /// Center-local → absolute screen.
    fn fromCanvasLocal(self: *const App, local: Vec2f) Vec2f {
        return .{ .x = local.x + self.canvas_rect.x, .y = local.y + self.canvas_rect.y };
    }

    fn mouseWorld(self: *const App) Vec2f {
        return self.camera.screenToWorld(self.toCanvasLocal(self.mouse));
    }

    fn worldToAbs(self: *const App, w: Vec2f) Vec2f {
        return self.fromCanvasLocal(self.camera.worldToScreen(w));
    }

    fn findPanel(self: *const App, name: []const u8) ?*gui.Panel {
        for (self.panels) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    fn panelOpen(self: *const App, name: []const u8) bool {
        return if (self.findPanel(name)) |p| p.open else false;
    }

    fn panelVisible(self: *const App, name: []const u8) bool {
        return if (self.findPanel(name)) |p| p.visible else false;
    }

    /// Allow canvas ops only when PanelHost hit is center (block panel/splitter/outside).
    fn allowsCanvasInput(self: *const App) bool {
        if (self.pointInMenuBar()) return false;
        if (self.gui_ctx.state.active_id != 0) return false;
        const pt = gui.Vec2{ .x = @intFromFloat(self.mouse.x), .y = @intFromFloat(self.mouse.y) };
        return self.panel_host.hitTest(self.gui_ctx, pt) == .center;
    }

    fn togglePanelsHidden(self: *App) void {
        if (!self.panels_hidden) {
            self.pre_hide_left_visible = self.panel_host.slotVisible(.left);
            self.pre_hide_right_visible = self.panel_host.slotVisible(.right);
            self.panel_host.setSlotVisible(.left, false);
            self.panel_host.setSlotVisible(.right, false);
            self.panels_hidden = true;
        } else {
            self.panel_host.setSlotVisible(.left, self.pre_hide_left_visible);
            self.panel_host.setSlotVisible(.right, self.pre_hide_right_visible);
            self.panels_hidden = false;
        }
        self.prefs_dirty = true;
    }

    fn togglePanelByName(self: *App, name: []const u8) bool {
        const p = self.findPanel(name) orelse return false;
        _ = self.panel_host.setPanelVisible(name, !p.visible);
        self.prefs_dirty = true;
        return true;
    }

    fn pushMetaEvent(self: *App, summary: []const u8) void {
        const after: u64 = if (self.cmd_log.filled > 0) self.cmd_log.recordAt(self.cmd_log.filled - 1).seq else 0;
        var e: MetaEvent = .{ .after_seq = after };
        const n = @min(summary.len, e.summary_buf.len);
        @memcpy(e.summary_buf[0..n], summary[0..n]);
        e.summary_len = @intCast(n);
        self.meta_events[self.meta_head] = e;
        self.meta_head = (self.meta_head + 1) % @as(u32, MAX_META_EVENTS);
        if (self.meta_filled < MAX_META_EVENTS) self.meta_filled += 1;
    }

    fn metaAt(self: *const App, i: u32) *const MetaEvent {
        // i: 0 = oldest … filled-1 = newest
        const idx = (self.meta_head + MAX_META_EVENTS - self.meta_filled + i) % MAX_META_EVENTS;
        return &self.meta_events[idx];
    }

    fn historyBodyAvail(self: *const App) i32 {
        if (self.panel_host.panelRect(self.gui_ctx, "History")) |r| {
            return @max(1, @as(i32, @intCast(r.w)) - 16);
        }
        return @max(1, self.panel_host.slotExtent(.left) - 24);
    }

    /// Outer height of the History ScrollArea.
    ///
    /// The left slot has real height via `height=.grow`, but the History wrap is fit, so
    /// `panelRect` shrinks to content height (the injected fixed height). Re-injecting that value sticks
    /// at the minimum (~2 rows) — a chicken-and-egg. The authority is the previous frame's **left slotRect** height − chrome.
    fn historyBodyHeight(self: *const App) i32 {
        // slot pad(4×2) + Collapsible header + gap/padding. Same class of estimate as pixie Layers chrome.
        const chrome: i32 = 44;
        if (self.panel_host.slotRect(self.gui_ctx, .left)) |sr| {
            return @max(40, @as(i32, @intCast(sr.h)) - chrome);
        }
        // First frame etc.: provisional while the slot rect is unset (converges to real slot height next frame).
        return 200;
    }

    fn historyCount(self: *const App) u32 {
        return self.cmd_log.filled + self.meta_filled;
    }

    fn historyLatestSeq(self: *const App) i64 {
        if (self.cmd_log.filled == 0) return -1;
        return @intCast(self.cmd_log.recordAt(self.cmd_log.filled - 1).seq);
    }

    fn syncCanvasRect(self: *App) void {
        if (self.panel_host.centerRect(self.gui_ctx)) |r| {
            self.canvas_rect = .{
                .x = @floatFromInt(r.x),
                .y = @floatFromInt(r.y),
                .w = @floatFromInt(r.w),
                .h = @floatFromInt(r.h),
            };
        }
    }

    /// Outer width of the Inspector body (panel rect − padding). First frame based on right slot extent.
    /// Collapsible body is fit, so inject .fixed into drawBody (avoid grow-in-fit collapse).
    fn inspectorBodyAvail(self: *const App) i32 {
        if (self.panel_host.panelRect(self.gui_ctx, "Inspector")) |r| {
            return @max(1, @as(i32, @intCast(r.w)) - 16);
        }
        return @max(1, self.panel_host.slotExtent(.right) - 24);
    }

    /// Legacy digest-key compat: !visible→hidden / visible&&!open→closed / else open.
    fn panelStateName(self: *const App, name: []const u8) []const u8 {
        const p = self.findPanel(name) orelse return "hidden";
        if (!p.visible) return "hidden";
        if (!p.open) return "closed";
        return "open";
    }

    /// Sync inspector_target to selected every frame (stale → null).
    fn syncInspectorTarget(self: *App) void {
        if (self.inspector_target) |t| {
            if (t >= MAX_MODULES or !self.dyn.slotActive(t)) {
                self.inspector_target = null;
            }
        }
        if (self.selected) |item| {
            switch (item) {
                .node => |h| {
                    // Primitive selection pins target to that handle.
                    self.inspector_target = h;
                },
                .group => |gid| {
                    // Group selection: keep target only while it is an active member of that group.
                    if (self.inspector_target) |t| {
                        if (t >= group.GROUP_HANDLE_BASE or self.ledger.group_of[t] != gid or !self.dyn.slotActive(t)) {
                            self.inspector_target = null;
                        }
                    }
                },
                .port, .cable => self.inspector_target = null,
            }
        } else {
            self.inspector_target = null;
        }
    }

    /// Real handle whose descriptors are shown (params mode). Null while in the member list.
    fn inspectorParamHandle(self: *const App) ?Handle {
        if (self.selected) |item| {
            switch (item) {
                .node => |h| return if (self.dyn.slotActive(h)) h else null,
                .group => return self.inspector_target,
                else => return null,
            }
        }
        return null;
    }

    /// Write the group's active members into out in handle order (no alloc).
    fn collectGroupMembers(self: *const App, gid: group.GroupId, out: []inspector.MemberInfo) usize {
        var n: usize = 0;
        var h: Handle = 0;
        while (h < MAX_MODULES and n < out.len) : (h += 1) {
            if (self.ledger.group_of[h] != gid) continue;
            if (!self.dyn.slotActive(h)) continue;
            const kind = self.dyn.kindOf(h) orelse continue;
            out[n] = .{ .handle = h, .kind_name = @tagName(kind) };
            n += 1;
        }
        return n;
    }

    fn inspectorView(self: *const App, member_buf: []inspector.MemberInfo) inspector.View {
        if (self.selected) |item| {
            switch (item) {
                .node => |h| {
                    if (self.dyn.slotActive(h)) return .{ .params = h };
                    return .empty;
                },
                .group => |gid| {
                    if (gid >= group.MAX_GROUPS or !self.ledger.groups[gid].active) return .empty;
                    if (self.inspector_target) |t| {
                        if (t < group.GROUP_HANDLE_BASE and self.ledger.group_of[t] == gid and self.dyn.slotActive(t)) {
                            return .{ .params = t };
                        }
                    }
                    const n = self.collectGroupMembers(gid, member_buf);
                    return .{ .group_members = .{
                        .group_name = self.ledger.groups[gid].kind.displayName(),
                        .members = member_buf[0..n],
                    } };
                },
                else => return .empty,
            }
        }
        return .empty;
    }

    fn editState(self: *App, key: param_view.FieldKey) *param_view.ParamEditState {
        var free: ?usize = null;
        for (&self.param_edits, 0..) |*state, index| {
            if (state.pending != null and param_view.sameField(state.key, key)) return state;
            if (free == null and state.pending == null) free = index;
        }
        return &self.param_edits[free orelse 0];
    }

    fn findEditState(self: *const App, key: param_view.FieldKey) ?*const param_view.ParamEditState {
        for (&self.param_edits) |*state| {
            if (state.pending != null and param_view.sameField(state.key, key)) return state;
        }
        return null;
    }

    fn beginParamFrame(self: *App) void {
        self.frame_snapshot_count = 0;
        for (&self.frame_snapshots) |*entry| entry.valid = false;
    }

    fn captureParamRows(self: *App, ctx: *const gui.Context) void {
        self.param_row_count = 0;
        // Ghost marker on scalar rows only (choice radios excluded).
        const h = self.inspectorParamHandle() orelse return;
        const kind = self.dyn.kindOf(h) orelse return;
        const descs = switch (kind) {
            inline else => |comptime_kind| modular.descriptors(comptime_kind),
        };
        for (descs, 0..) |desc, index| {
            if (self.param_row_count >= self.param_rows.len) break;
            switch (desc.kind) {
                .scalar => {},
                .choice => continue,
            }
            const rect = ctx.getNodeRect(inspector.paramId(ctx, h, index)) orelse continue;
            self.param_rows[self.param_row_count] = .{ .key = param_view.fieldKey(h, desc.name), .rect = rect, .valid = true };
            self.param_row_count += 1;
        }
    }

    fn snapshotParam(self: *App, handle: Handle, name: []const u8) ?param_view.ParamSnapshot {
        const key = param_view.fieldKey(handle, name);
        for (self.frame_snapshots[0..self.frame_snapshot_count]) |entry| {
            if (entry.valid and param_view.sameField(entry.key, key)) return .{
                .field = entry.snapshot.field,
                .instant = entry.snapshot.instant,
                .has_instant = entry.snapshot.has_instant,
            };
        }
        if (self.frame_snapshot_count >= self.frame_snapshots.len) return null;
        const snapshot = modular.getParamSnapshot(self.dyn, handle, name) catch return null;
        self.frame_snapshots[self.frame_snapshot_count] = .{ .key = key, .snapshot = snapshot, .valid = true };
        self.frame_snapshot_count += 1;
        return .{ .field = snapshot.field, .instant = snapshot.instant, .has_instant = snapshot.has_instant };
    }

    fn releaseParamEdits(self: *App) void {
        const before = self.slider_drag_before;
        self.slider_drag_before = null;
        // Record per entry. One gesture = one record is already coalesced by dragging→release
        // (mid-drag values only update pending; they do not enter CommandLog).
        // The old shared committed guard silently dropped records for other slots in the same call — a bug.
        for (&self.param_edits) |*state| {
            const was_dragging = state.dragging;
            state.release();
            if (!was_dragging) continue;
            if (before) |b| {
                if (b.mode == 1) {
                    // Inspector slider: set_param in NodeId form (queueParamOverride path).
                    if (state.key.invalid()) continue;
                    const final_raw: f32 = blk: {
                        if (state.pending) |pv| break :blk switch (pv) {
                            .scalar => |v| v,
                            .choice => |idx| @floatFromInt(idx),
                        };
                        const snap = modular.getParam(self.dyn, @intCast(state.key.handle), state.key.name) catch break :blk @as(f32, @bitCast(b.value_bits));
                        break :blk switch (snap) {
                            .scalar => |v| v,
                            .choice => |idx| @floatFromInt(idx),
                        };
                    };
                    self.pending_param_undo_before = b;
                    var args_buf: [128]u8 = undefined;
                    const args = std.fmt.bufPrint(&args_buf, "#{d} {s} {d}", .{ b.node_id, b.name(), final_raw }) catch {
                        self.pending_param_undo_before = null;
                        continue;
                    };
                    // Via recordedAction: one CommandLog record + notePatchUndo.
                    routeUiAction(self, "set_param", args);
                }
            }
        }
    }

    fn advanceParamEdits(self: *App) void {
        for (&self.param_edits) |*state| {
            if (state.pending == null or state.dragging) continue;
            const key = state.key;
            for (self.frame_snapshots[0..self.frame_snapshot_count]) |entry| {
                if (entry.valid and param_view.sameField(entry.key, key)) {
                    state.advance(.{ .field = entry.snapshot.field, .instant = entry.snapshot.instant, .has_instant = entry.snapshot.has_instant });
                    break;
                }
            }
        }
    }

    fn drawGhostMarkers(self: *App, dl: *gui.DrawList) void {
        for (self.param_rows[0..self.param_row_count]) |row| {
            if (!row.valid) continue;
            const kind = self.dyn.kindOf(@intCast(row.key.handle)) orelse continue;
            const desc = paramDescFor(kind, row.key.name) orelse continue;
            const scalar_desc = switch (desc.kind) {
                .scalar => |s| s,
                .choice => continue,
            };
            const snapshot = self.snapshotParam(@intCast(row.key.handle), row.key.name) orelse continue;
            const fraction = param_view.ghostFraction(snapshot, scalar_desc.min, scalar_desc.max) orelse continue;
            const x = row.rect.x + @as(i32, @intFromFloat(fraction * @as(f32, @floatFromInt(row.rect.w))));
            const y = row.rect.y + @divTrunc(@as(i32, @intCast(row.rect.h)), 2);
            dl.line(.{ .x = x, .y = y - 6 }, .{ .x = x, .y = y + 6 }, gui.Color.rgba(0xF0, 0xA0, 0x50, 0xFF), 2) catch {};
        }
    }

    /// Raw node list of real handles (from dyn; no synthetic handles). Per frame.
    /// Attach grid_rows for the inline grid on a selected step_seq (standalone / expanded group member).
    /// Collapsed-group members stay hidden in the box via mapNodesForCollapsed, so only the macro grid as before.
    fn buildRawNodes(self: *const App, out: []NodeGeom) usize {
        var n: usize = 0;
        var h: Handle = 0;
        while (h < MAX_MODULES) : (h += 1) {
            if (!self.dyn.slotActive(h)) continue;
            var g: NodeGeom = .{ .handle = h, .pos = self.layout[h], .n_in = self.dyn.nIn(h), .n_out = self.dyn.nOut(h) };
            if (self.selected) |sel| switch (sel) {
                .node => |sh| if (sh == h and self.dyn.kindOf(h) == .step_seq) {
                    const seq = self.dyn.ptrOfConst(.step_seq, h);
                    g.grid_rows = switch (seq.kind) {
                        .drum => 1,
                        .bass => 4,
                    };
                },
                else => {},
            };
            out[n] = g;
            n += 1;
        }
        return n;
    }

    /// Display node list (per frame. Collapsed-group members fold into one box. Mapping is
    /// delegated to group.Ledger.mapNodesForCollapsed).
    fn buildNodes(self: *const App, out: []NodeGeom) usize {
        var raw_buf: [MAX_MODULES]NodeGeom = undefined;
        const raw = raw_buf[0..self.buildRawNodes(&raw_buf)];
        return self.ledger.mapNodesForCollapsed(raw, out);
    }

    /// Flat edges (real handles only; view.in_src laid out as-is). deriveExposed, boundary checks,
    /// edgeForInput/commitConnect read this flat list (no synthetic handles mixed in).
    fn buildFlatEdges(self: *const App, out: []Edge) usize {
        const view = self.dyn.currentView();
        var n: usize = 0;
        var k: usize = 0;
        while (k < view.node_count) : (k += 1) {
            const h = view.order[k];
            const nin = self.dyn.nIn(h);
            var i: usize = 0;
            while (i < nin) : (i += 1) {
                const src = view.in_src[h][i];
                if (src < 0) continue;
                const sid: usize = @intCast(src);
                out[n] = .{
                    .src_handle = @intCast(sid / MAX_OUT),
                    .src_out = @intCast(sid % MAX_OUT),
                    .dst_handle = h,
                    .dst_in = @intCast(i),
                };
                n += 1;
            }
        }
        return n;
    }

    /// Display edge list (per frame. Map collapsed-group boundaries onto box ports. Used for draw/hit-test/selection).
    fn buildDisplayEdges(self: *const App, out: []group.DisplayEdge) usize {
        var flat_buf: [MAX_EDGES]Edge = undefined;
        const flat = flat_buf[0..self.buildFlatEdges(&flat_buf)];
        return self.ledger.buildDisplayEdges(flat, out);
    }

    /// Headers of expanded groups (title+toggle only; no ports n_in=n_out=0). Collapsed groups are
    /// already in the buildNodes box, so they do not appear here. Per frame (a handful of groups).
    fn buildGroupHeaders(self: *const App, out: []NodeGeom) usize {
        var n: usize = 0;
        for (self.ledger.groups, 0..) |g, i| {
            if (g.active and !g.collapsed and n < out.len) {
                out[n] = .{ .handle = group.handleOfGroup(@intCast(i)), .pos = g.pos, .n_in = 0, .n_out = 0 };
                n += 1;
            }
        }
        return n;
    }

    /// Event only. Re-derive every active group's expose table whenever connections change (group count<=8 so
    /// a full scan is cheap. deriveExposed requires real-handle edges only = pass the flat edge list).
    fn refreshAllExposed(self: *App) void {
        var flat_buf: [MAX_EDGES]Edge = undefined;
        const flat = flat_buf[0..self.buildFlatEdges(&flat_buf)];
        for (self.ledger.groups, 0..) |g, i| {
            if (g.active) self.ledger.deriveExposed(@intCast(i), flat);
        }
    }

    // ── File menu ──────────────────────────────────────────────────────────
    fn rebuildMenuCommands(self: *App) void {
        const accel_mod: platform.ModifierFlags = if (builtin.os.tag == .macos)
            .{ .cmd = true }
        else
            .{ .ctrl = true };
        var n: usize = 0;
        const put = struct {
            fn go(app: *App, idx: *usize, cmd: platform.Command) void {
                if (idx.* >= MENU_CMD_CAP) return;
                app.menu_commands[idx.*] = cmd;
                idx.* += 1;
            }
        }.go;
        put(self, &n, .{
            .id = CmdId.undo,
            .label = "Undo",
            .menu = .{ .title = "Edit", .order = 100 },
            .shortcut = .{ .key = .Z, .modifiers = accel_mod },
            .execution_policy = .undo,
        });
        var redo_mod = accel_mod;
        redo_mod.shift = true;
        put(self, &n, .{
            .id = CmdId.redo,
            .label = "Redo",
            .menu = .{ .title = "Edit", .order = 101 },
            .shortcut = .{ .key = .Z, .modifiers = redo_mod },
            .execution_policy = .redo,
        });
        put(self, &n, .{
            .id = CmdId.save_project,
            .label = "Save Project",
            .menu = .{ .title = "File", .order = 100 },
            .shortcut = .{ .key = .S, .modifiers = accel_mod },
        });
        put(self, &n, .{
            .id = CmdId.open_project,
            .label = "Open Project",
            .menu = .{ .title = "File", .order = 101 },
            .shortcut = .{ .key = .O, .modifiers = accel_mod },
        });
        put(self, &n, .{ .id = 0, .kind = .separator, .menu = .{ .title = "File", .order = 102 } });
        put(self, &n, .{
            .id = CmdId.quit,
            .label = "Quit",
            .menu = .{ .title = "File", .order = 103 },
        });
        // View → History (Cmd/Ctrl+Shift+H. Separate from modifier-less H hide-all).
        var hist_mod = accel_mod;
        hist_mod.shift = true;
        const hist_checked = if (self.findPanel("History")) |p| p.visible else false;
        put(self, &n, .{
            .id = CmdId.toggle_history,
            .label = "History",
            .menu = .{ .title = "View", .order = 100 },
            .shortcut = .{ .key = .H, .modifiers = hist_mod },
            .checked = hist_checked,
        });
        self.menu_command_count = n;
    }

    fn menuCommandsSlice(self: *App) []const platform.Command {
        return self.menu_commands[0..self.menu_command_count];
    }

    fn findMenuCommand(self: *const App, id: platform.CommandId) ?platform.Command {
        if (id == 0) return null;
        for (self.menu_commands[0..self.menu_command_count]) |cmd| {
            if (cmd.kind == .separator) continue;
            if (cmd.id == id) return cmd;
        }
        return null;
    }

    fn dispatchCommand(self: *App, id: platform.CommandId) void {
        const cmd = self.findMenuCommand(id) orelse return;
        if (!cmd.enabled) return;
        switch (id) {
            CmdId.undo => doUndo(self),
            CmdId.redo => doRedo(self),
            CmdId.save_project => {
                self.pending_menu_op = .save_project;
                self.menu_last_op = .save_project;
            },
            CmdId.open_project => {
                self.pending_menu_op = .open_project;
                self.menu_last_op = .open_project;
            },
            CmdId.quit => self.running = false,
            CmdId.toggle_history => {
                _ = self.togglePanelByName("History");
                if (self.prefs_dirty) persistPanelPrefs(self);
            },
            else => {},
        }
    }

    /// Shortcut matching for the GUI-fallback environment (when native menu is on, keyEquivalent owns it).
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

    /// Append `.kngn` when the extension is missing (dialog return path; caller frees).
    fn ensureKngnExt(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
        if (path.len >= 5 and std.ascii.eqlIgnoreCase(path[path.len - 5 ..], ".kngn")) {
            return gpa.dupe(u8, path);
        }
        return std.fmt.allocPrint(gpa, "{s}.kngn", .{path});
    }

    /// Run pending File ops at a safe point after framebuffer unlock (dialogs forbidden while locked).
    fn runPendingMenuFileOp(self: *App) void {
        const op = self.pending_menu_op orelse return;
        self.pending_menu_op = null;
        const gpa = std.heap.c_allocator;
        switch (op) {
            .save_project => {
                const maybe = platform.saveFileDialog(gpa, self.io, .{
                    .default_name = "untitled.kngn",
                    .allowed_ext = "kngn",
                }) catch return; // Ignore DialogFailed (headless) etc. and keep RT running
                const path = maybe orelse return;
                defer gpa.free(path);
                const final_path = ensureKngnExt(gpa, path) catch return;
                defer gpa.free(final_path);
                actionSaveProjectFile(self, final_path) catch {};
            },
            .open_project => {
                const maybe = platform.openFileDialog(gpa, self.io, .{ .allowed_ext = "kngn" }) catch return;
                const path = maybe orelse return;
                defer gpa.free(path);
                // Same path as actionLoadProject (args = path).
                var buf: [256]u8 = undefined;
                _ = actionLoadProject(self, path, &buf) catch {};
            },
        }
    }
};

// RT audio callback: dyn.processBlock only (no sync/alloc/lock/IO/panic). The facade auto-taps the audio probe.
// Master visualisation tap for C (SampleTap.write. Drop whole writes when full; non-blocking. Established RT pattern).
fn audioCallback(buf: []f32, frames: u32, channels: u32, sample_rate: u32, userdata: ?*anyopaque) void {
    _ = sample_rate;
    const app: *App = @ptrCast(@alignCast(userdata orelse {
        @memset(buf, 0);
        return;
    }));
    app.patch.render(buf, frames, channels);
    if (channels == 2) app.tap.write(buf);
}

// ----------------------------------------------------------------------------
// main-thread MIDI drain (event only; not via Executor/CommandLog)
// ----------------------------------------------------------------------------

fn handleForGenRole(app: *const App, role: project_io.GenRole) ?Handle {
    const h = app.patch.snapshotGenRoles().get(role);
    if (h == project_io.INVALID_ROLE_HANDLE) return null;
    if (!app.dyn.isActive(h)) return null;
    return h;
}

fn midiTargetActive(app: *const App, role: project_io.GenRole, param: []const u8) bool {
    const h = handleForGenRole(app, role) orelse return false;
    const kind = app.dyn.kindOf(h) orelse return false;
    return paramDescFor(kind, param) != null;
}

/// CC → ParamBatch update. Does not touch CommandLog / History / undo / recipe at all.
fn applyMidiCc(app: *App, controller: u8, value: u8) void {
    const v: u8 = @min(value, 127);
    for (MIDI_CC_MAP, 0..) |binding, bi| {
        if (binding.controller != controller) continue;
        app.midi_cc_raw[bi] = v;
        const mapped = patchmod.mapMidiCcValue(v, binding.curve, binding.min, binding.max);
        var published = false;
        for (binding.targets) |target| {
            const h = handleForGenRole(app, target.role) orelse continue;
            const kind = app.dyn.kindOf(h) orelse continue;
            const desc = paramDescFor(kind, target.param) orelse continue;
            if (desc.kind != .scalar) continue;
            modular.validateParam(kind, desc.name, .{ .scalar = mapped }) catch continue;

            var free: ?usize = null;
            var found: ?usize = null;
            for (app.param_batch.entries, 0..) |entry, i| {
                if (!entry.touched) {
                    if (free == null) free = i;
                } else if (entry.handle == h and std.mem.eql(u8, entry.name, desc.name)) {
                    found = i;
                    break;
                }
            }
            const index = found orelse free orelse continue;
            app.param_batch.entries[index] = .{
                .handle = h,
                .name = desc.name,
                .value = .{ .scalar = mapped },
                .touched = true,
            };
            published = true;
        }
        if (published) {
            app.param_batch.revision += 1;
            app.patch.publishParamBatch(app.param_batch);
        }
        return;
    }
}

/// main thread: drain the MIDI FIFO and route note→NoteQueue / CC→ParamBatch.
/// Does not go through Executor.executeAction (not recorded in CommandLog/recipe).
fn drainMidiEvents(app: *App, device: *midi.Device) void {
    while (device.pollMidi()) |ev| {
        switch (ev) {
            .note_on => |n| {
                const vel = @as(f32, @floatFromInt(n.velocity)) / 127.0;
                app.patch.sendMidiNoteOn(n.note, vel);
            },
            .note_off => |n| app.patch.sendMidiNoteOff(n.note),
            .cc => |c| applyMidiCc(app, c.controller, c.value),
        }
    }
}

fn midiMapDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var off: usize = 0;
    const head = std.fmt.bufPrint(buf[off..], "map_version=1", .{}) catch return buf[0..0];
    off += head.len;
    for (MIDI_CC_MAP, 0..) |binding, bi| {
        const raw: u8 = app.midi_cc_raw[bi] orelse 0; // ccN_value = raw CC 0..127 (not mapped Hz/BPM)
        // 1 CC → 1 target (MVP). Even with future multi-target, digest uses the first target as representative.
        const t0 = binding.targets[0];
        const active: u8 = if (midiTargetActive(app, t0.role, t0.param)) 1 else 0;
        const curve_s: []const u8 = switch (binding.curve) {
            .linear => "linear",
            .exponential => "exponential",
        };
        const piece = std.fmt.bufPrint(buf[off..], " cc{d}_label={s} cc{d}_role={s} cc{d}_param={s} cc{d}_curve={s} cc{d}_min={d} cc{d}_max={d} cc{d}_value={d} cc{d}_active={d}", .{
            binding.controller,
            binding.label,
            binding.controller,
            @tagName(t0.role),
            binding.controller,
            t0.param,
            binding.controller,
            curve_s,
            binding.controller,
            binding.min,
            binding.controller,
            binding.max,
            binding.controller,
            raw,
            binding.controller,
            active,
        }) catch return buf[0..off];
        off += piece.len;
    }
    return buf[0..off];
}

// ============================================================================
// Draw helpers
// ============================================================================
/// f32 screen coords → i32 (NaN/Inf/OOB safe. Do not panic on extreme zoom/pan).
fn safeI32(v: f32) i32 {
    if (!std.math.isFinite(v)) return 0;
    return @intFromFloat(std.math.clamp(@round(v), -1_000_000.0, 1_000_000.0));
}
fn safeU32(v: f32) u32 {
    if (!std.math.isFinite(v)) return 0;
    return @intFromFloat(std.math.clamp(@round(v), 0.0, 1_000_000.0));
}

fn toRect(tl: Vec2f, sz: Vec2f) gui.Rect {
    return .{
        .x = safeI32(tl.x),
        .y = safeI32(tl.y),
        .w = safeU32(sz.x),
        .h = safeU32(sz.y),
    };
}

fn vec2i(p: Vec2f) gui.Vec2 {
    return .{ .x = safeI32(p.x), .y = safeI32(p.y) };
}

/// Simple filled circle painted as horizontal spans (DrawList has no circle). Caller already clamps radius to 3..10.
fn fillCircle(dl: *gui.DrawList, center: Vec2f, r: f32, col: gui.Color) void {
    if (!std.math.isFinite(center.x) or !std.math.isFinite(center.y)) return;
    const rr = std.math.clamp(r, 0.0, 64.0);
    const ri: i32 = @intFromFloat(@round(rr));
    const cxi = safeI32(center.x);
    const cyi = safeI32(center.y);
    if (ri < 1) {
        dl.rectFilled(.{ .x = cxi, .y = cyi, .w = 1, .h = 1 }, col) catch {};
        return;
    }
    var dy: i32 = -ri;
    while (dy <= ri) : (dy += 1) {
        const dyf: f32 = @floatFromInt(dy);
        const dxf = @sqrt(@max(0.0, rr * rr - dyf * dyf));
        const dx: i32 = @intFromFloat(@round(dxf));
        const w: u32 = @intCast(@max(1, dx * 2 + 1));
        dl.rectFilled(.{ .x = cxi - dx, .y = cyi + dy, .w = w, .h = 1 }, col) catch {};
    }
}

fn drawFrame(app: *App, dl: *gui.DrawList) void {
    var node_buf: [MAX_MODULES]NodeGeom = undefined;
    var edge_buf: [MAX_EDGES]group.DisplayEdge = undefined;
    const nodes = node_buf[0..app.buildNodes(&node_buf)];
    const dedges = edge_buf[0..app.buildDisplayEdges(&edge_buf)];
    const cam = app.camera;
    const r = cam.portScreenRadius();

    // Cables (under nodes). Draw at visual (mapped) endpoints; select/hover against actual (real CableRef)
    // (synthetic handles stay inside draw coordinates only). Coords are absolute screen = center origin added.
    for (dedges) |de| {
        const e = de.visual;
        const sg = findNode(nodes, e.src_handle) orelse continue;
        const dg = findNode(nodes, e.dst_handle) orelse continue;
        const a = app.worldToAbs(canvas.outPortPos(sg, e.src_out));
        const b = app.worldToAbs(canvas.inPortPos(dg, e.dst_in));
        const kind = portKindOut(app, e.src_handle, e.src_out);
        const thick: u32 = if (cableItemMatches(app.selected, de.actual) or cableItemMatches(app.hover, de.actual)) 3 else 2;
        dl.line(vec2i(a), vec2i(b), portColor(kind), thick) catch {};
    }

    // Nodes + ports (collapsed box = synthetic handle resolves title/port kinds via the ledger. Never pass the box
    // handle straight into dyn — keep synthetic handles confined).
    for (nodes) |g| {
        const tl = app.worldToAbs(g.pos);
        const sz = canvas.nodeSize(g).scale(cam.zoom);
        const rect = toRect(tl, sz);
        dl.rectFilled(rect, NODE_BG) catch {};
        const selected = itemIsHandle(app.selected, g.handle) or selection.contains(&app.multi_selected, g.handle);
        const hovered = itemIsHandle(app.hover, g.handle);
        const border = if (selected) SEL_COL else if (hovered) HOVER_COL else BORDER_COL;
        dl.rectOutline(rect, border, if (selected) 2 else 1) catch {};
        // Vertically centre by ink height inside the title band (TITLE_H * zoom).
        // Macro-box evolve/lock toggles are drawn at the left of the title band, so shift
        // the text start x right by that amount to avoid overlap.
        {
            var title_x_pad: i32 = 6;
            if (group.groupIdFromHandle(g.handle)) |title_gid| {
                const seqs = collectStepSeqMembers(app, title_gid);
                if (macroHasGeneratedSeqs(app, seqs.items[0..seqs.n])) {
                    const reserved = canvas.macroToggleReservedWidth(@intCast(seqs.n));
                    title_x_pad += @intFromFloat(@round(reserved * cam.zoom));
                }
            }
            const title_band_h: i32 = @intFromFloat(@round(canvas.TITLE_H * cam.zoom));
            // Node titles use the small font (title_font). Ink centering uses the same
            // small-font metrics (the font passed to textEx must match the font used for centering).
            const text_h = gui.fontInkHeight(app.title_font);
            const text_y = gui.centeredTextY(rect.y, title_band_h, text_h);
            // Even when title_x_pad for toggles squeezes the node width, clip to the node's own
            // rect so glyphs do not spill into neighbouring nodes
            // (a temporary mitigation; a fuller node-display rethink is future work).
            dl.pushClip(rect) catch {};
            dl.textEx(.{ .x = rect.x + title_x_pad, .y = text_y }, nodeTitle(app, g.handle), TITLE_COL, app.title_font) catch {};
            dl.popClip();
        }
        if (group.groupIdFromHandle(g.handle)) |gid| {
            drawToggle(app, dl, g, true); // Collapsed boxes always use the collapsed side
            drawMacroGrid(app, dl, g, gid); // TR/303 grid + playhead in the body
        } else if (g.grid_rows > 0) {
            // Inline grid for a selected standalone step_seq (separate from the macro-box path)
            drawInlineStepSeqGrid(app, dl, g);
        }
        var i: u8 = 0;
        while (i < g.n_in) : (i += 1) {
            const p = app.worldToAbs(canvas.inPortPos(g, i));
            const kind = portKindIn(app, g.handle, i);
            fillCircle(dl, p, r, portColor(kind));
            if (hoverPort(app, g.handle, true, i)) dl.rectOutline(portBox(p, r), HOVER_COL, 1) catch {};
        }
        i = 0;
        while (i < g.n_out) : (i += 1) {
            const p = app.worldToAbs(canvas.outPortPos(g, i));
            const kind = portKindOut(app, g.handle, i);
            // A: blink output-port dots by activity (peak-hold + decay; zero RT impact). When active, halo first then a bright dot on top.
            const lvl = outPortLevel(app, g.handle, i);
            const base = portColor(kind);
            if (lvl > 0.12) fillCircle(dl, p, r + 2, litColor(base, lvl * 0.5));
            fillCircle(dl, p, r, litColor(base, lvl));
            if (hoverPort(app, g.handle, false, i)) dl.rectOutline(portBox(p, r), HOVER_COL, 1) catch {};
        }
    }

    // Thin frame for an expanded group (rect+title+toggle). Inner grid drawing is separate.
    for (app.ledger.groups, 0..) |gr, gi| {
        if (!gr.active or gr.collapsed) continue;
        drawExpandedGroupFrame(app, dl, nodes, @intCast(gi), gr);
    }

    // D: mini oscilloscope for tapped ports (band along the inner bottom of the node).
    drawMiniScopes(app, dl, nodes);
    // Compact display of key parameter values (right of the same scope band). Every frame regardless of tap.
    drawNodeParamValues(app, dl, nodes);

    // pending cable (during connection drag: origin port → cursor)
    if (app.drag == .cable) {
        const origin = app.drag.cable.origin;
        if (portScreenPos(app, nodes, origin)) |op| {
            dl.line(vec2i(op), vec2i(app.mouse), PENDING_COL, 2) catch {};
        }
    }

    // Rubber-band rectangle: translucent blue fill + blue border (while dragging only).
    if (app.drag == .rect_select) {
        const rs = app.drag.rect_select;
        const wr = canvas.normalizeWorldRect(rs.start_world, app.mouseWorld());
        const tl = app.worldToAbs(.{ .x = wr.x, .y = wr.y });
        const br = app.worldToAbs(.{ .x = wr.x + wr.w, .y = wr.y + wr.h });
        const rect = gui.Rect{
            .x = safeI32(tl.x),
            .y = safeI32(tl.y),
            .w = safeU32(br.x - tl.x),
            .h = safeU32(br.y - tl.y),
        };
        dl.rectFilled(rect, RECT_SEL_FILL) catch {};
        dl.rectOutline(rect, RECT_SEL_OUTLINE, 1) catch {};
    }

    // Module palette (center-rect overlay; not a PanelHost panel).
    const buttons = paletteButtons(app);
    for (buttons) |btn| {
        const rect = gui.Rect{ .x = safeI32(btn.rect.x), .y = safeI32(btn.rect.y), .w = safeU32(btn.rect.w), .h = safeU32(btn.rect.h) };
        const hov = canvas.hitTestPalette(app.mouse, &buttons) == btn.kind_index;
        dl.rectFilled(rect, if (hov) PAL_BG_HOVER else PAL_BG) catch {};
        dl.rectOutline(rect, BORDER_COL, 1) catch {};
        // Ink-centre within palette row height PAL_H.
        {
            const text_h = gui.fontInkHeight(app.gui_ctx.font);
            const text_y = gui.centeredTextY(rect.y, @as(i32, @intFromFloat(PAL_H)), text_h);
            dl.text(.{ .x = rect.x + 6, .y = text_y }, paletteLabel(PALETTE[btn.kind_index]), TITLE_COL) catch {};
        }
    }
}

/// Absolute screen position of the origin port (null if the node is gone). For pending-cable drawing.
fn portScreenPos(app: *const App, nodes: []const NodeGeom, p: PortRef) ?Vec2f {
    const g = findNode(nodes, p.handle) orelse return null;
    const wp = if (p.is_input) canvas.inPortPos(g, p.index) else canvas.outPortPos(g, p.index);
    return app.worldToAbs(wp);
}

fn cableItemMatches(item: ?Item, actual: CableRef) bool {
    if (item) |it| {
        if (it == .cable) return it.cable.dst_handle == actual.dst_handle and it.cable.dst_in == actual.dst_in;
    }
    return false;
}

/// Whether the selected/hover Item points at handle h (real node or synthetic handle of a collapsed box/frame header).
fn itemIsHandle(item: ?Item, h: Handle) bool {
    if (item) |it| {
        return switch (it) {
            .node => |nh| nh == h,
            .group => |gid| group.handleOfGroup(gid) == h,
            else => false,
        };
    }
    return false;
}

fn portBox(center: Vec2f, r: f32) gui.Rect {
    const ri: i32 = @intFromFloat(std.math.clamp(@round(r + 2), 1.0, 66.0));
    return .{
        .x = safeI32(center.x) - ri,
        .y = safeI32(center.y) - ri,
        .w = @intCast(ri * 2),
        .h = @intCast(ri * 2),
    };
}

fn hoverPort(app: *const App, h: Handle, is_input: bool, index: u8) bool {
    if (app.hover) |it| {
        if (it == .port) return it.port.handle == h and it.port.is_input == is_input and it.port.index == index;
    }
    return false;
}

fn findNode(nodes: []const NodeGeom, h: Handle) ?NodeGeom {
    for (nodes) |n| {
        if (n.handle == h) return n;
    }
    return null;
}

/// Node title string. Collapsed box/frame header (synthetic handle) → ledger MacroKind name; real node → dyn.kindOf.
fn nodeTitle(app: *const App, h: Handle) []const u8 {
    if (group.groupIdFromHandle(h)) |gid| return app.ledger.groups[gid].kind.displayName();
    if (app.dyn.kindOf(h)) |k| return @tagName(k);
    return "?";
}

/// Input port kind. Synthetic handle (collapsed box) resolves exposed_in[i]'s real member port via dyn.inKindOf
/// (do not pass the box handle straight into dyn).
fn portKindIn(app: *const App, h: Handle, i: u8) PortKind {
    if (group.groupIdFromHandle(h)) |gid| {
        const g = app.ledger.groups[gid];
        if (i < g.n_in) return app.dyn.inKindOf(g.exposed_in[i].member, g.exposed_in[i].port) orelse .audio;
        return .audio;
    }
    return app.dyn.inKindOf(h, i) orelse .audio;
}

/// Output port kind. Synthetic handle (collapsed box) resolves exposed_out[i]'s real member port via dyn.outKindOf.
fn portKindOut(app: *const App, h: Handle, i: u8) PortKind {
    if (group.groupIdFromHandle(h)) |gid| {
        const g = app.ledger.groups[gid];
        if (i < g.n_out) return app.dyn.outKindOf(g.exposed_out[i].member, g.exposed_out[i].port) orelse .audio;
        return .audio;
    }
    return app.dyn.outKindOf(h, i) orelse .audio;
}

fn paletteLabel(entry: PaletteEntry) []const u8 {
    return switch (entry) {
        .primitive => |k| @tagName(k),
        .macro_kind => |mk| mk.displayName(),
        .step_seq_bass => "step_seq(bass)",
    };
}

/// Draw the collapse toggle [±] (g is the box or frame-header NodeGeom; collapsed switches the label).
fn drawToggle(app: *const App, dl: *gui.DrawList, g: NodeGeom, collapsed: bool) void {
    const tl = app.worldToAbs(canvas.togglePos(g));
    const size = canvas.TOGGLE_SIZE * app.camera.zoom;
    const rect = gui.Rect{ .x = safeI32(tl.x), .y = safeI32(tl.y), .w = safeU32(size), .h = safeU32(size) };
    dl.rectFilled(rect, PAL_BG) catch {};
    dl.rectOutline(rect, BORDER_COL, 1) catch {};
    // Ink-centre inside the toggle square.
    {
        const text_h = gui.fontInkHeight(app.gui_ctx.font);
        const text_y = gui.centeredTextY(rect.y, @as(i32, @intCast(rect.h)), text_h);
        dl.text(.{ .x = rect.x + 3, .y = text_y }, if (collapsed) "+" else "-", TITLE_COL) catch {};
    }
}

/// Thin frame of an expanded group (bbox around current member layout) + header (title+toggle, anchored at group.pos).
/// Inner content (TR grid etc.) is drawn separately.
fn drawExpandedGroupFrame(app: *const App, dl: *gui.DrawList, nodes: []const NodeGeom, gid: group.GroupId, gr: group.Group) void {
    var bbox_min = Vec2f{ .x = std.math.floatMax(f32), .y = std.math.floatMax(f32) };
    var bbox_max = Vec2f{ .x = -std.math.floatMax(f32), .y = -std.math.floatMax(f32) };
    var any = false;
    for (nodes) |ng| {
        if (ng.handle >= group.GROUP_HANDLE_BASE) continue;
        const mgid = app.ledger.group_of[ng.handle] orelse continue;
        if (mgid != gid) continue;
        any = true;
        const sz = canvas.nodeSize(ng);
        bbox_min.x = @min(bbox_min.x, ng.pos.x);
        bbox_min.y = @min(bbox_min.y, ng.pos.y);
        bbox_max.x = @max(bbox_max.x, ng.pos.x + sz.x);
        bbox_max.y = @max(bbox_max.y, ng.pos.y + sz.y);
    }
    if (any) {
        const margin: f32 = 10;
        const tl = app.worldToAbs(.{ .x = bbox_min.x - margin, .y = bbox_min.y - margin });
        const br = app.worldToAbs(.{ .x = bbox_max.x + margin, .y = bbox_max.y + margin });
        const rect = gui.Rect{ .x = safeI32(tl.x), .y = safeI32(tl.y), .w = safeU32(br.x - tl.x), .h = safeU32(br.y - tl.y) };
        dl.rectOutline(rect, HOVER_COL, 1) catch {};
    }

    const header = NodeGeom{ .handle = group.handleOfGroup(gid), .pos = gr.pos, .n_in = 0, .n_out = 0 };
    const htl = app.worldToAbs(header.pos);
    const hsz = canvas.nodeSize(header).scale(app.camera.zoom);
    const hrect = toRect(htl, hsz);
    const hsel = itemIsHandle(app.selected, header.handle) or selection.contains(&app.multi_selected, header.handle);
    dl.rectFilled(hrect, NODE_BG) catch {};
    dl.rectOutline(hrect, if (hsel) SEL_COL else BORDER_COL, if (hsel) 2 else 1) catch {};
    // Expanded-group headers also ink-centre in the TITLE_H band. Same small font as ordinary nodes.
    {
        const title_band_h: i32 = @intFromFloat(@round(canvas.TITLE_H * app.camera.zoom));
        const text_h = gui.fontInkHeight(app.title_font);
        const text_y = gui.centeredTextY(hrect.y, title_band_h, text_h);
        dl.textEx(.{ .x = hrect.x + 6, .y = text_y }, gr.kind.displayName(), TITLE_COL, app.title_font) catch {};
    }
    drawToggle(app, dl, header, false);
}

// ============================================================================
// Collapsed-macro TR/303 grid. Members: only real handles resolved via the ledger go to dyn.ptrOf;
// mask/step are atomic-loaded (keep the no-synthetic-handle-into-dyn rule). Per frame (at most 4 rows×16 cells per box).
// ============================================================================
const StepSeqPtr = *modular.StepSeq;

/// Collect up to 3 step_seq members of gid in handle order (drum: [seqK, seqH, seqClap] / bass: [seq]).
/// Only active + step_seq + belonging to that gid (drop stale handles; stay in sync with the ledger).
fn collectStepSeqMembers(app: *const App, gid: group.GroupId) struct { items: [3]Handle, n: usize } {
    var items: [3]Handle = .{ 0, 0, 0 };
    var n: usize = 0;
    var h: Handle = 0;
    while (h < MAX_MODULES and n < items.len) : (h += 1) {
        if (app.ledger.group_of[h] == null or app.ledger.group_of[h].? != gid) continue;
        if (!app.dyn.slotActive(h)) continue;
        if (app.dyn.kindOf(h) != .step_seq) continue;
        items[n] = h;
        n += 1;
    }
    return .{ .items = items, .n = n };
}

/// Clickable mask row count (drum = lane count from group metadata; bass = on/accent/slide = 3 rows).
fn clickableRows(g: group.Group) u8 {
    return switch (g.kind) {
        .drum_machine => @min(if (g.grid_rows == 0) 2 else g.grid_rows, 3),
        .bass_machine => 3,
    };
}

fn toStepgridGeometry(g: canvas.GridGeometry) stepgrid.Geometry {
    return .{
        .origin_x = g.origin_x,
        .origin_y = g.origin_y,
        .cell_w = g.cell_w,
        .cell_h = g.cell_h,
        .step_pitch = g.step_pitch,
        .row_pitch = g.row_pitch,
    };
}

/// Shared camera-transformed grid geometry (adapter shared by macro box / standalone node).
fn gridGeometry(cam: Camera, box_pos: Vec2f) stepgrid.Geometry {
    return toStepgridGeometry(canvas.gridGeometry(cam, box_pos));
}

/// For drawing: grid geometry in absolute screen coords (center origin added).
fn absGridGeometry(app: *const App, box_pos: Vec2f) stepgrid.Geometry {
    var g = gridGeometry(app.camera, box_pos);
    g.origin_x += app.canvas_rect.x;
    g.origin_y += app.canvas_rect.y;
    return g;
}

/// Draw the TR grid (drum 2 lanes) / 303 rows (on/accent/slide + pitch) + playhead into the collapsed-box body.
/// Draw evolve (global) / lock (per-lane) toggles in the title band (generation macros only).
fn drawMacroGrid(app: *App, dl: *gui.DrawList, box: NodeGeom, gid: group.GroupId) void {
    const kind = app.ledger.groups[gid].kind;
    const seqs = collectStepSeqMembers(app, gid);
    if (seqs.n == 0) return;

    // Playhead column: process does step++ after evaluating the current step, so the last-sounded column is (step + STEPS-1) % STEPS.
    const head_seq: StepSeqPtr = app.dyn.ptrOf(.step_seq, seqs.items[0]);
    const playhead: u8 = (head_seq.loadStep() + stepgrid.STEP_COUNT - 1) % stepgrid.STEP_COUNT;
    const geometry = absGridGeometry(app, box.pos);

    drawMacroMutationToggles(app, dl, box, seqs.items[0..seqs.n]);

    switch (kind) {
        .drum_machine => {
            // Legacy palette macros are 2 lanes; generated DrumMachine is 3 lanes.
            var rows: [3]stepgrid.DrawRow = undefined;
            var lane: u8 = 0;
            const row_count = @min(@as(usize, if (box.grid_rows == 0) 2 else box.grid_rows), seqs.n);
            while (lane < row_count) : (lane += 1) {
                const seq: StepSeqPtr = app.dyn.ptrOf(.step_seq, seqs.items[lane]);
                rows[lane] = .{ .mask = seq.loadOnMask(), .on_color = stepgrid.DEFAULT_ON };
            }
            stepgrid.draw(dl, geometry, rows[0..row_count], .{ .playhead = @intCast(playhead) });
        },
        .bass_machine => {
            const seq: StepSeqPtr = app.dyn.ptrOf(.step_seq, seqs.items[0]);
            const rows = [_]stepgrid.DrawRow{
                .{ .mask = seq.loadOnMask(), .on_color = stepgrid.DEFAULT_ON },
                .{ .mask = seq.loadAccentMask(), .on_color = stepgrid.DEFAULT_ACCENT },
                .{ .mask = seq.loadSlideMask(), .on_color = stepgrid.DEFAULT_SLIDE },
                .{ .pitch = .{ .degrees = seq.pitch_deg[0..], .degree_count = modular.scaleDegreeCount(seq.scale, seq.octaves), .color = stepgrid.DEFAULT_PITCH, .style = .bars } },
            };
            stepgrid.draw(dl, geometry, rows[0..], .{ .playhead = @intCast(playhead) });
        },
    }
}

const EVOLVE_ON_COL = gui.Color.rgba(0x60, 0xC0, 0x90, 0xFF);
const EVOLVE_OFF_COL = gui.Color.rgba(0x40, 0x48, 0x52, 0xFF);
const LOCK_ON_COL = gui.Color.rgba(0xE0, 0x90, 0x50, 0xFF);
const LOCK_OFF_COL = gui.Color.rgba(0x40, 0x48, 0x52, 0xFF);

fn drawMacroMutationToggles(app: *App, dl: *gui.DrawList, box: NodeGeom, seq_handles: []const Handle) void {
    if (!macroHasGeneratedSeqs(app, seq_handles)) return;
    const zoom = app.camera.zoom;
    const origin = app.worldToAbs(box.pos);
    const e = canvas.macroEvolveToggleRect();
    const head: StepSeqPtr = app.dyn.ptrOf(.step_seq, seq_handles[0]);
    const er = gui.Rect{
        .x = @intFromFloat(origin.x + e.x * zoom),
        .y = @intFromFloat(origin.y + e.y * zoom),
        .w = @intFromFloat(e.w * zoom),
        .h = @intFromFloat(e.h * zoom),
    };
    dl.rectFilled(er, if (head.evolve) EVOLVE_ON_COL else EVOLVE_OFF_COL) catch {};

    var lane: u8 = 0;
    while (lane < seq_handles.len) : (lane += 1) {
        const lr = canvas.macroLockToggleRect(lane);
        const seq: StepSeqPtr = app.dyn.ptrOf(.step_seq, seq_handles[lane]);
        const rect = gui.Rect{
            .x = @intFromFloat(origin.x + lr.x * zoom),
            .y = @intFromFloat(origin.y + lr.y * zoom),
            .w = @intFromFloat(lr.w * zoom),
            .h = @intFromFloat(lr.h * zoom),
        };
        dl.rectFilled(rect, if (seq.lock) LOCK_ON_COL else LOCK_OFF_COL) catch {};
    }
}

fn macroHasGeneratedSeqs(app: *const App, seq_handles: []const Handle) bool {
    for (seq_handles) |h| {
        if (!isGeneratedStepSeq(app, h)) return false;
    }
    return seq_handles.len > 0;
}

const MacroToggleHit = union(enum) {
    evolve: void,
    lock: u8, // lane index into collectStepSeqMembers order
};

const MacroMutationHit = struct {
    gid: group.GroupId,
    hit: MacroToggleHit,
};

fn hitMacroMutationToggle(app: *const App, world_pt: Vec2f) ?MacroMutationHit {
    for (app.ledger.groups, 0..) |g, i| {
        if (!g.active or !g.collapsed) continue;
        const gid: group.GroupId = @intCast(i);
        const seqs = collectStepSeqMembers(app, gid);
        if (!macroHasGeneratedSeqs(app, seqs.items[0..seqs.n])) continue;
        const local = world_pt.sub(g.pos);
        const er = canvas.macroEvolveToggleRect();
        if (local.x >= er.x and local.x < er.x + er.w and local.y >= er.y and local.y < er.y + er.h) {
            return .{ .gid = gid, .hit = .evolve };
        }
        var lane: u8 = 0;
        while (lane < seqs.n) : (lane += 1) {
            const lr = canvas.macroLockToggleRect(lane);
            if (local.x >= lr.x and local.x < lr.x + lr.w and local.y >= lr.y and local.y < lr.y + lr.h) {
                return .{ .gid = gid, .hit = .{ .lock = lane } };
            }
        }
    }
    return null;
}

fn trackNameForGeneratedSeq(app: *const App, h: Handle) ?[]const u8 {
    if (h == app.patch.kick_seq_h) return "kick";
    if (h == app.patch.hat_seq_h) return "hat";
    if (h == app.patch.clap_seq_h) return "clap";
    if (h == app.patch.bass_seq_h) return "bass";
    return null;
}

fn applyMacroMutationToggle(app: *App, hit: MacroMutationHit) void {
    const seqs = collectStepSeqMembers(app, hit.gid);
    switch (hit.hit) {
        .evolve => {
            const head: StepSeqPtr = app.dyn.ptrOf(.step_seq, seqs.items[0]);
            var buf: [8]u8 = undefined;
            const args = std.fmt.bufPrint(&buf, "{d}", .{@as(u8, @intFromBool(!head.evolve))}) catch return;
            routeUiAction(app, "set_evolve", args);
        },
        .lock => |lane| {
            if (lane >= seqs.n) return;
            const h = seqs.items[lane];
            const name = trackNameForGeneratedSeq(app, h) orelse return;
            const seq: StepSeqPtr = app.dyn.ptrOf(.step_seq, h);
            var buf: [32]u8 = undefined;
            const args = std.fmt.bufPrint(&buf, "{s} {d}", .{ name, @as(u8, @intFromBool(!seq.lock)) }) catch return;
            routeUiAction(app, "set_lock", args);
        },
    }
}

/// Inline grid for a selected standalone step_seq (not via pattern_db; atomic load only).
fn drawInlineStepSeqGrid(app: *App, dl: *gui.DrawList, box: NodeGeom) void {
    const seq: StepSeqPtr = app.dyn.ptrOf(.step_seq, box.handle);
    const playhead: u8 = (seq.loadStep() + stepgrid.STEP_COUNT - 1) % stepgrid.STEP_COUNT;
    const geometry = absGridGeometry(app, box.pos);
    switch (seq.kind) {
        .drum => {
            const rows = [_]stepgrid.DrawRow{
                .{ .mask = seq.loadOnMask(), .on_color = stepgrid.DEFAULT_ON },
            };
            stepgrid.draw(dl, geometry, rows[0..], .{ .playhead = @intCast(playhead) });
        },
        .bass => {
            const rows = [_]stepgrid.DrawRow{
                .{ .mask = seq.loadOnMask(), .on_color = stepgrid.DEFAULT_ON },
                .{ .mask = seq.loadAccentMask(), .on_color = stepgrid.DEFAULT_ACCENT },
                .{ .mask = seq.loadSlideMask(), .on_color = stepgrid.DEFAULT_SLIDE },
                .{ .pitch = .{ .degrees = seq.pitch_deg[0..], .degree_count = modular.scaleDegreeCount(seq.scale, seq.octaves), .color = stepgrid.DEFAULT_PITCH, .style = .bars } },
            };
            stepgrid.draw(dl, geometry, rows[0..], .{ .playhead = @intCast(playhead) });
        },
    }
}

/// Which collapsed-macro grid cell a world point hits (clickable rows only).
const GridHit = struct { gid: group.GroupId, cell: stepgrid.GridCell };
fn hitMacroGrid(app: *const App, world_pt: Vec2f) ?GridHit {
    for (app.ledger.groups, 0..) |g, i| {
        if (!g.active or !g.collapsed) continue;
        const gid: group.GroupId = @intCast(i);
        const local = world_pt.sub(g.pos);
        const geometry = gridGeometry(.{ .zoom = 1.0 }, .{ .x = 0, .y = 0 });
        if (stepgrid.hitTest(geometry, local.x, local.y, clickableRows(g))) |cell| return .{ .gid = gid, .cell = cell };
    }
    return null;
}

/// Hit-test the selected step_seq inline grid (mask rows only; pitch out of scope.
/// Both standalone and expanded group members. Collapsed members are not shown, so they never reach here).
const InlineGridHit = struct { handle: Handle, cell: stepgrid.GridCell };
fn hitInlineStepSeqGrid(app: *const App, world_pt: Vec2f) ?InlineGridHit {
    const sel = app.selected orelse return null;
    const h: Handle = switch (sel) {
        .node => |nh| nh,
        else => return null,
    };
    if (app.dyn.kindOf(h) != .step_seq) return null;
    if (!app.dyn.slotActive(h)) return null;
    const seq = app.dyn.ptrOfConst(.step_seq, h);
    const clickable: u8 = switch (seq.kind) {
        .drum => 1,
        .bass => 3, // on/accent/slide. pitch (row 3) is display-only
    };
    const local = world_pt.sub(app.layout[h]);
    const geometry = gridGeometry(.{ .zoom = 1.0 }, .{ .x = 0, .y = 0 });
    if (stepgrid.hitTest(geometry, local.x, local.y, clickable)) |cell| {
        return .{ .handle = h, .cell = cell };
    }
    return null;
}

fn isGeneratedStepSeq(app: *const App, h: Handle) bool {
    return h == app.patch.kick_seq_h or
        h == app.patch.hat_seq_h or
        h == app.patch.clap_seq_h or
        h == app.patch.bass_seq_h;
}

/// Toggle an inline step_seq mask. Generation handles go patternEditBase → publishPatternCommand;
/// standalone uses atomic accessors only.
fn toggleInlineStepSeqCell(app: *App, hit: InlineGridHit) void {
    if (isGeneratedStepSeq(app, hit.handle)) {
        const target: ?[]const u8 = blk: {
            if (hit.handle == app.patch.kick_seq_h) {
                if (hit.cell.row != 0) break :blk null;
                break :blk "kick";
            } else if (hit.handle == app.patch.hat_seq_h) {
                if (hit.cell.row != 0) break :blk null;
                break :blk "hat";
            } else if (hit.handle == app.patch.clap_seq_h) {
                if (hit.cell.row != 0) break :blk null;
                break :blk "clap";
            } else if (hit.handle == app.patch.bass_seq_h) {
                break :blk switch (hit.cell.row) {
                    0 => "bass_on",
                    1 => "bass_accent",
                    2 => "bass_slide",
                    else => null,
                };
            } else break :blk null;
        };
        if (target) |name| {
            var args_buf: [32]u8 = undefined;
            const args = std.fmt.bufPrint(&args_buf, "{s} {d}", .{ name, hit.cell.step }) catch return;
            routeUiAction(app, "toggle_step", args);
        }
        return;
    }
    const seq: StepSeqPtr = app.dyn.ptrOf(.step_seq, hit.handle);
    switch (seq.kind) {
        .drum => {
            if (hit.cell.row == 0) seq.toggleOnBit(hit.cell.step);
        },
        .bass => switch (hit.cell.row) {
            0 => seq.toggleOnBit(hit.cell.step),
            1 => seq.toggleAccentBit(hit.cell.step),
            2 => seq.toggleSlideBit(hit.cell.step),
            else => {},
        },
    }
}

fn generatedMacroGroup(app: *const App, gid: group.GroupId) bool {
    return app.ledger.memberOf(gid, app.patch.kick_seq_h) or
        app.ledger.memberOf(gid, app.patch.hat_seq_h) or
        app.ledger.memberOf(gid, app.patch.clap_seq_h) or
        app.ledger.memberOf(gid, app.patch.bass_seq_h);
}

/// Use the latest publish not yet applied by RT as the edit base. If RT has already acquired the rev, drop pending and
/// fall back to the RT-authoritative current values (evolve etc.). The caller re-sets quantize explicitly.
fn patternEditBase(app: *App) PatternCommand {
    const st = app.patch.snapshotState();
    var base = stateToCommand(st);
    if (app.pending_pattern) |pending| {
        if (pending.rev == app.pattern_rev and st.pattern_rev != pending.rev) {
            base = pending;
        } else {
            app.pending_pattern = null;
        }
    }
    base.quantize_bar = false;
    return base;
}

/// Publish a pattern and keep the latest not-yet-RT-applied command on the GUI side.
/// Does not change graph topology / RT view; existing applyControls() takes it in at the next block start.
fn publishPatternCommand(app: *App, cmd: PatternCommand) PatternCommand {
    var next = cmd;
    app.pattern_rev +%= 1;
    next.rev = app.pattern_rev;
    app.pending_pattern = next;
    if (!next.quantize_bar) app.last_quantized_cmd = null;
    app.patch.controls.pattern_db.publish(next);
    return next;
}

/// Grid-cell click → PatternCommand for generation macros; atomic accessors for legacy palette macros.
fn toggleMacroGridCell(app: *App, hit: GridHit) void {
    const group_state = app.ledger.groups[hit.gid];
    const kind = group_state.kind;
    const seqs = collectStepSeqMembers(app, hit.gid);
    if (seqs.n == 0) return;
    if (generatedMacroGroup(app, hit.gid)) {
        const target: ?[]const u8 = switch (kind) {
            .drum_machine => switch (hit.cell.row) {
                0 => "kick",
                1 => "hat",
                2 => "clap",
                else => null,
            },
            .bass_machine => switch (hit.cell.row) {
                0 => "bass_on",
                1 => "bass_accent",
                2 => "bass_slide",
                else => null,
            },
        };
        if (target) |name| {
            var args_buf: [32]u8 = undefined;
            const args = std.fmt.bufPrint(&args_buf, "{s} {d}", .{ name, hit.cell.step }) catch return;
            routeUiAction(app, "toggle_step", args);
        }
        return;
    }
    switch (kind) {
        .drum_machine => {
            if (hit.cell.row >= seqs.n) return;
            const seq: StepSeqPtr = app.dyn.ptrOf(.step_seq, seqs.items[hit.cell.row]);
            seq.toggleOnBit(hit.cell.step);
        },
        .bass_machine => {
            const seq: StepSeqPtr = app.dyn.ptrOf(.step_seq, seqs.items[0]);
            switch (hit.cell.row) {
                0 => seq.toggleOnBit(hit.cell.step),
                1 => seq.toggleAccentBit(hit.cell.step),
                2 => seq.toggleSlideBit(hit.cell.step),
                else => {},
            }
        },
    }
}

// ============================================================================
// Input
// ============================================================================
fn edgeForInput(app: *const App, dst: Handle, dst_in: u8) ?Edge {
    var edge_buf: [MAX_EDGES]Edge = undefined;
    const edges = edge_buf[0..app.buildFlatEdges(&edge_buf)];
    for (edges) |e| {
        if (e.dst_handle == dst and e.dst_in == dst_in) return e;
    }
    return null;
}

/// Group whose toggle is near a world point (looks at both collapsed boxes and expanded-frame headers).
fn hitToggle(app: *const App, world_pt: Vec2f) ?group.GroupId {
    var node_buf: [MAX_MODULES]NodeGeom = undefined;
    const nodes = node_buf[0..app.buildNodes(&node_buf)];
    if (canvas.hitTestToggle(world_pt, nodes)) |h| {
        if (group.groupIdFromHandle(h)) |gid| return gid;
    }
    var hdr_buf: [group.MAX_GROUPS]NodeGeom = undefined;
    const headers = hdr_buf[0..app.buildGroupHeaders(&hdr_buf)];
    if (canvas.hitTestToggle(world_pt, headers)) |h| return group.groupIdFromHandle(h);
    return null;
}

/// Expanded-frame header near a world point (title area; no ports).
fn hitGroupHeader(app: *const App, world_pt: Vec2f) ?group.GroupId {
    var hdr_buf: [group.MAX_GROUPS]NodeGeom = undefined;
    const headers = hdr_buf[0..app.buildGroupHeaders(&hdr_buf)];
    if (canvas.hitTestNode(world_pt, headers)) |h| return group.groupIdFromHandle(h);
    return null;
}

/// Display cable (hit-test at visual endpoints; return the real CableRef=actual).
fn hitTestDisplayCable(world_pt: Vec2f, nodes: []const NodeGeom, dedges: []const group.DisplayEdge) ?CableRef {
    var visual_buf: [MAX_EDGES]Edge = undefined;
    for (dedges, 0..) |de, i| visual_buf[i] = de.visual;
    if (canvas.hitTestCable(world_pt, nodes, visual_buf[0..dedges.len])) |idx| return dedges[idx].actual;
    return null;
}

fn updateHover(app: *App) void {
    // Do not raise canvas hover over panel / splitter / outside / the visualisation strip.
    if (!app.allowsCanvasInput()) {
        app.hover = null;
        return;
    }
    var node_buf: [MAX_MODULES]NodeGeom = undefined;
    var edge_buf: [MAX_EDGES]group.DisplayEdge = undefined;
    const nodes = node_buf[0..app.buildNodes(&node_buf)];
    const dedges = edge_buf[0..app.buildDisplayEdges(&edge_buf)];
    const mw = app.mouseWorld();
    if (canvas.hitTestPort(mw, nodes)) |pr| {
        app.hover = .{ .port = pr };
    } else if (canvas.hitTestNode(mw, nodes)) |h| {
        app.hover = if (group.groupIdFromHandle(h)) |gid| .{ .group = gid } else .{ .node = h };
    } else if (hitTestDisplayCable(mw, nodes, dedges)) |actual| {
        app.hover = .{ .cable = actual };
    } else {
        app.hover = null;
    }
}

fn routeUiAction(app: *App, name: []const u8, args: []const u8) void {
    var buf: [512]u8 = undefined;
    _ = routeUiActionInto(app, name, args, &buf);
}

/// GUI → action entry. Write the response into `out_buf` and return that slice (null on failure).
///
/// - During netsync: `platform.routeAction` (PROPOSE/COMMIT; canonicalize via the registry path).
/// - Otherwise: call `cmd_exec.executeAction` directly.
///   When harness is off, `registerAction` is a no-op and the registry is empty, so `routeAction`→dispatch
///   would return UnknownAction (critical on real hardware). Executor is owned by app and harness-independent.
fn routeUiActionInto(app: *App, name: []const u8, args: []const u8, out_buf: []u8) ?[]const u8 {
    if (platform.netsyncActive()) {
        return platform.routeAction(name, args, out_buf) catch |err| {
            std.debug.print("patch: routeAction {s} failed: {s}\n", .{ name, @errorName(err) });
            return null;
        };
    }
    const res = app.cmd_exec.executeAction(name, args, .{
        .actor = .local_user,
        .record_policy = .record,
    }, out_buf) catch |err| {
        std.debug.print("patch: executeAction {s} failed: {s}\n", .{ name, @errorName(err) });
        return null;
    };
    return res.output;
}

/// If the response is `ok id=#N`, resolve NodeId → handle and set selected (ignore client `proposed`).
fn selectNodeFromOkIdResponse(app: *App, resp: []const u8) void {
    const prefix = "ok id=#";
    if (!std.mem.startsWith(u8, resp, prefix)) return;
    var end: usize = 0;
    const digits = resp[prefix.len..];
    while (end < digits.len and digits[end] >= '0' and digits[end] <= '9') : (end += 1) {}
    if (end == 0) return;
    const id_raw = std.fmt.parseUnsigned(u64, digits[0..end], 10) catch return;
    if (handleOfNodeId(app, NodeId.fromRaw(id_raw))) |h| {
        app.selected = .{ .node = h };
    }
}

/// Palette index → add_node / add_macro action (with world coords).
fn routePaletteAdd(app: *App, ki: u8) void {
    const casc: f32 = @floatFromInt(app.dyn.activeCount() % 8);
    // Place in center-local coords (camera space).
    const cx: f32 = app.canvasW() * 0.45 + casc * 18;
    const cy: f32 = app.canvasH() * 0.4 + casc * 18;
    if (ki >= PALETTE.len) return;
    var resp_buf: [512]u8 = undefined;
    switch (PALETTE[ki]) {
        .primitive => |kind| {
            const pos = app.camera.screenToWorld(.{ .x = cx, .y = cy });
            var args_buf: [128]u8 = undefined;
            const args = std.fmt.bufPrint(&args_buf, "{s} {d} {d}", .{ @tagName(kind), pos.x, pos.y }) catch return;
            const resp = routeUiActionInto(app, "add_node", args, &resp_buf) orelse return;
            selectNodeFromOkIdResponse(app, resp);
        },
        .macro_kind => |mk| {
            // Put the clamped world coords on the wire (same coords across peers)
            const anchor: Vec2f = .{ .x = cx, .y = cy };
            // Footprint estimated from kind-fixed OFFSETS (members not yet known; header-only approx)
            const fp = switch (mk) {
                .drum_machine => Vec2f{ .x = 450 + 80, .y = MACRO_HEADER_BAND + 120 },
                .bass_machine => Vec2f{ .x = 450 + 80, .y = MACRO_HEADER_BAND + 120 },
            };
            const pos = clampMacroPos(app, anchor, fp);
            var args_buf: [128]u8 = undefined;
            const args = std.fmt.bufPrint(&args_buf, "{s} {d} {d}", .{ @tagName(mk), pos.x, pos.y }) catch return;
            // solo/host: actionAddMacro sets selected=.group. client proposed stays unselected.
            _ = routeUiActionInto(app, "add_macro", args, &resp_buf);
        },
        .step_seq_bass => {
            const pos = app.camera.screenToWorld(.{ .x = cx, .y = cy });
            var args_buf: [128]u8 = undefined;
            // Wire token `step_seq_bass` (separate from drum `step_seq`. Same COMMIT args on every peer).
            const args = std.fmt.bufPrint(&args_buf, "step_seq_bass {d} {d}", .{ pos.x, pos.y }) catch return;
            const resp = routeUiActionInto(app, "add_node", args, &resp_buf) orelse return;
            selectNodeFromOkIdResponse(app, resp);
        },
    }
}

fn onMouseUp(app: *App) void {
    if (app.drag == .cable) {
        const pend = app.drag.cable;
        var node_buf: [MAX_MODULES]NodeGeom = undefined;
        const nodes = node_buf[0..app.buildNodes(&node_buf)];
        const mw = app.camera.screenToWorld(app.mouse);
        if (canvas.hitTestPort(mw, nodes)) |target_raw| {
            if (app.ledger.resolvePort(pend.origin)) |origin_real| {
                if (app.ledger.resolvePort(target_raw)) |target_real| {
                    routeCommitConnect(app, origin_real, target_real, pend.detach);
                }
            }
        } else if (pend.detach) |d| {
            routeDisconnect(app, d.dst_handle, d.dst_in);
        }
    } else if (app.drag == .node) {
        const nd = app.drag.node;
        const pos = app.layout[nd.handle];
        if (nodeIdOf(app, nd.handle)) |id| {
            var args_buf: [128]u8 = undefined;
            const args = std.fmt.bufPrint(&args_buf, "#{d} {d} {d}", .{ id.raw(), pos.x, pos.y }) catch {
                app.drag = .none;
                return;
            };
            routeUiAction(app, "move_node", args);
        }
    } else if (app.drag == .rect_select) {
        // Confirm rect select: put handles whose display-node bbox (from buildNodes) positively intersects into the set.
        const rs = app.drag.rect_select;
        const sel_rect = canvas.normalizeWorldRect(rs.start_world, app.mouseWorld());
        if (!rs.additive) selection.clear(&app.multi_selected);
        var node_buf: [MAX_MODULES]NodeGeom = undefined;
        const nodes = node_buf[0..app.buildNodes(&node_buf)];
        for (nodes) |g| {
            if (canvas.rectsIntersectPositive(sel_rect, canvas.nodeWorldBBox(g))) {
                selection.set(&app.multi_selected, g.handle, true);
            }
        }
    }
    app.drag = .none;
}

/// Fully pre-validate a connection, then commit in one publish. A drag-off's old connection (detach) is handled in the same commit,
/// keeping "one gesture = at most one publish" and "invalid/failed drop does not break existing connections" (do not disconnect first).
/// a/b/detach are always real PortRef/CableRef (caller already resolvePort'd. Synthetic handles never reach here).
/// UI goes routeCommitConnect → `connect` action. Equivalent logic is centralised in `actionConnect`.
fn routeCommitConnect(app: *App, a: PortRef, b: PortRef, detach: ?CableRef) void {
    const rc = canvas.resolveConnection(a, b) orelse return;
    const src = rc.src;
    const dst = rc.dst;
    const src_id = nodeIdOf(app, src.handle) orelse return;
    const dst_id = nodeIdOf(app, dst.handle) orelse return;
    var args_buf: [192]u8 = undefined;
    const args = blk: {
        if (detach) |d| {
            const did = nodeIdOf(app, d.dst_handle) orelse break :blk actions.formatConnect(&args_buf, src_id.raw(), src.index, dst_id.raw(), dst.index) catch return;
            break :blk actions.formatConnectWithDetach(&args_buf, src_id.raw(), src.index, dst_id.raw(), dst.index, did.raw(), d.dst_in) catch return;
        }
        break :blk actions.formatConnect(&args_buf, src_id.raw(), src.index, dst_id.raw(), dst.index) catch return;
    };
    routeUiAction(app, "connect", args);
}

fn routeDisconnect(app: *App, dst_h: Handle, dst_in: u8) void {
    const id = nodeIdOf(app, dst_h) orelse return;
    var args_buf: [64]u8 = undefined;
    const args = actions.formatDisconnect(&args_buf, id.raw(), dst_in) catch return;
    routeUiAction(app, "disconnect", args);
}

/// Shift or Cmd (macOS multi-select modifier).
fn multiSelectModifier(m: platform.ModifierFlags) bool {
    return m.shift or m.cmd;
}

/// When multi_selected is empty, seed the set from the current app.selected node/group (Shift/Cmd toggle preprocess).
fn seedMultiFromSelectedIfEmpty(app: *App) void {
    if (!selection.empty(&app.multi_selected)) return;
    if (app.selected) |it| switch (it) {
        .node => |h| selection.set(&app.multi_selected, h, true),
        .group => |gid| selection.set(&app.multi_selected, group.handleOfGroup(gid), true),
        else => {},
    };
}

fn onMouseDown(app: *App, modifiers: platform.ModifierFlags) void {
    // panel / splitter / outside mouse goes to the GUI Context. Do not compete with the canvas.
    if (!app.allowsCanvasInput()) return;
    // Palette is hit-tested in absolute screen coords before world hits (via the action route).
    const buttons = paletteButtons(app);
    if (canvas.hitTestPalette(app.mouse, &buttons)) |ki| {
        routePaletteAdd(app, ki);
        return;
    }
    const mw = app.mouseWorld();
    const multi_mod = multiSelectModifier(modifiers);

    // Collapse toggle [±] takes priority over clicking the node body (both collapsed box and expanded-frame header).
    if (hitToggle(app, mw)) |gid| {
        app.ledger.groups[gid].collapsed = !app.ledger.groups[gid].collapsed;
        app.selected = .{ .group = gid };
        selection.clear(&app.multi_selected);
        app.hover = null;
        app.drag = .none;
        return;
    }

    // Generation-macro evolve/lock toggles (priority over step cells; non-overlapping rects).
    if (hitMacroMutationToggle(app, mw)) |hit| {
        applyMacroMutationToggle(app, hit);
        app.selected = .{ .group = hit.gid };
        selection.clear(&app.multi_selected);
        app.drag = .none;
        return;
    }

    // Collapsed-box TR/303 grid cell click → toggle mask bit (atomic store; no publish). Takes priority over
    // node hit on the box body (group drag start). Ports sit on the left/right edges and do not overlap the grid (order free, but handle first).
    if (hitMacroGrid(app, mw)) |hit| {
        toggleMacroGridCell(app, hit);
        app.selected = .{ .group = hit.gid };
        selection.clear(&app.multi_selected);
        app.drag = .none;
        return;
    }

    // Selected step_seq inline grid (standalone / expanded member). Before port/node drag.
    // On hit: mask toggle only; keep selected; do not start node drag.
    if (hitInlineStepSeqGrid(app, mw)) |hit| {
        toggleInlineStepSeqCell(app, hit);
        app.selected = .{ .node = hit.handle };
        selection.clear(&app.multi_selected);
        app.drag = .none;
        return;
    }

    var node_buf: [MAX_MODULES]NodeGeom = undefined;
    var edge_buf: [MAX_EDGES]group.DisplayEdge = undefined;
    const nodes = node_buf[0..app.buildNodes(&node_buf)];
    const dedges = edge_buf[0..app.buildDisplayEdges(&edge_buf)];
    if (canvas.hitTestPort(mw, nodes)) |pr| {
        // pr is the as-hit PortRef (synthetic handle if a collapsed-box port). Use it as-is for selection/pending drawing
        // (to highlight the box's port dots); run resolvePort only for real connection checks/changes.
        selection.clear(&app.multi_selected);
        app.selected = .{ .port = pr };
        if (app.ledger.resolvePort(pr)) |real| {
            if (real.is_input) {
                if (edgeForInput(app, real.handle, real.index)) |e| {
                    // Drag-off from a connected input: pend from that source output; defer disconnect until commit(mouse_up).
                    app.drag = .{ .cable = .{
                        .origin = .{ .handle = e.src_handle, .is_input = false, .index = e.src_out },
                        .detach = .{ .dst_handle = real.handle, .dst_in = real.index },
                    } };
                    return;
                }
            }
        }
        app.drag = .{ .cable = .{ .origin = pr } }; // Start pending from an output or an unconnected input
    } else if (canvas.hitTestNode(mw, nodes)) |h| {
        if (multi_mod) {
            // Shift/Cmd: toggle in the set. Do not start a drag.
            seedMultiFromSelectedIfEmpty(app);
            selection.toggle(&app.multi_selected, h);
            if (group.groupIdFromHandle(h)) |gid| {
                app.selected = .{ .group = gid };
            } else {
                app.selected = .{ .node = h };
            }
            app.drag = .none;
        } else if (group.groupIdFromHandle(h)) |gid| {
            // Collapsed-box body drag: update ledger.groups[gid].pos and translate member layout slots
            // by the same delta (never index a synthetic handle into app.layout[h]).
            selection.clear(&app.multi_selected);
            app.selected = .{ .group = gid };
            app.drag = .{ .group = .{ .gid = gid, .grab_offset = app.ledger.groups[gid].pos.sub(mw) } };
        } else {
            selection.clear(&app.multi_selected);
            app.selected = .{ .node = h };
            const npos = app.layout[h];
            app.drag = .{ .node = .{ .handle = h, .grab_offset = npos.sub(mw) } };
        }
    } else if (hitGroupHeader(app, mw)) |gid| {
        // Click on an expanded-frame header body: selection only (not draggable). Shift/Cmd toggles.
        const gh = group.handleOfGroup(gid);
        if (multi_mod) {
            seedMultiFromSelectedIfEmpty(app);
            selection.toggle(&app.multi_selected, gh);
            app.selected = .{ .group = gid };
        } else {
            selection.clear(&app.multi_selected);
            app.selected = .{ .group = gid };
        }
        app.drag = .none;
    } else if (hitTestDisplayCable(mw, nodes, dedges)) |actual| {
        selection.clear(&app.multi_selected);
        app.selected = .{ .cable = actual };
    } else if (modifiers.alt) {
        // Option(Alt)+empty left-drag = pan (same path as middle button. Alternative for trackpads with no
        // physical middle button on Mac). Does not touch selection (same rule as middle-button pan).
        app.drag = .{ .pan = .{ .start_pan = app.camera.pan, .start_mouse = app.toCanvasLocal(app.mouse) } };
    } else {
        // Empty left-drag = rect select. Pan moved to middle button or Option+left-drag.
        if (!multi_mod) {
            selection.clear(&app.multi_selected);
            app.selected = null;
        }
        app.drag = .{ .rect_select = .{ .start_world = mw, .additive = multi_mod } };
    }
}

/// Relative member layout when a macro is expanded (world offsets from group.pos). y starts below
/// MACRO_HEADER_BAND so the expand header (title+[−] at group.pos) does not overlap members. OFFSETS order
/// matches the field order of the Handles struct in macro.zig.
const MACRO_HEADER_BAND: f32 = 58;
const DRUM_OFFSETS = [_]Vec2f{
    .{ .x = 0, .y = MACRO_HEADER_BAND + 40 }, // cdiv (left, mid)
    .{ .x = 150, .y = MACRO_HEADER_BAND }, // seqK (top)
    .{ .x = 150, .y = MACRO_HEADER_BAND + 80 }, // seqH (bottom)
    .{ .x = 300, .y = MACRO_HEADER_BAND }, // kick (top)
    .{ .x = 300, .y = MACRO_HEADER_BAND + 80 }, // hat (bottom)
    .{ .x = 450, .y = MACRO_HEADER_BAND + 40 }, // mix (right, mid)
};
const BASS_OFFSETS = [_]Vec2f{
    .{ .x = 0, .y = MACRO_HEADER_BAND + 40 }, // seq (left, mid)
    .{ .x = 150, .y = MACRO_HEADER_BAND }, // vco (top)
    .{ .x = 300, .y = MACRO_HEADER_BAND + 40 }, // vcf (mid)
    .{ .x = 150, .y = MACRO_HEADER_BAND + 80 }, // env (bottom)
    .{ .x = 450, .y = MACRO_HEADER_BAND + 40 }, // vca (right, mid)
};

// Expanded layout for the generation graph LofiPatch already owns at startup.
// No add/connect/publish here — only set UI coordinates on group.Ledger.
const GENERATED_DRUM_OFFSETS = [_]Vec2f{
    .{ .x = 150, .y = MACRO_HEADER_BAND }, // kick_seq
    .{ .x = 150, .y = MACRO_HEADER_BAND + 80 }, // hat_seq
    .{ .x = 150, .y = MACRO_HEADER_BAND + 160 }, // clap_seq
    .{ .x = 330, .y = MACRO_HEADER_BAND }, // kick
    .{ .x = 330, .y = MACRO_HEADER_BAND + 80 }, // hat
    .{ .x = 330, .y = MACRO_HEADER_BAND + 160 }, // clap
};
const GENERATED_BASS_OFFSETS = [_]Vec2f{
    .{ .x = 0, .y = MACRO_HEADER_BAND + 40 }, // bass_seq
    .{ .x = 150, .y = MACRO_HEADER_BAND + 40 }, // bass_perc
    .{ .x = 150, .y = MACRO_HEADER_BAND }, // vco
    .{ .x = 330, .y = MACRO_HEADER_BAND + 40 }, // vcf
    .{ .x = 510, .y = MACRO_HEADER_BAND + 40 }, // vca
};

/// Register a generation macro onto the ledger with existing handles (init only).
/// Does not change DynGraph topology, the published view, or the RT view at all.
fn registerGeneratedMacro(
    app: *App,
    gid: group.GroupId,
    kind: group.MacroKind,
    pos: Vec2f,
    grid_rows: u8,
    members: []const Handle,
    offsets: []const Vec2f,
) void {
    std.debug.assert(members.len == offsets.len);
    const g = &app.ledger.groups[gid];
    g.kind = kind;
    g.collapsed = true;
    g.grid_rows = grid_rows;
    g.pos = pos;
    for (members, offsets) |h, offset| {
        std.debug.assert(h < MAX_MODULES and app.dyn.slotActive(h));
        app.ledger.assign(h, gid);
        app.layout[h] = pos.add(offset);
    }
}

/// Register LofiPatch generation handles as DrumMachine/BassMachine on the ledger (init only).
/// Does not re-run the generation builder, so DynGraph node count / handles / topology stay unchanged; only the display becomes a macro.
fn registerGeneratedMacros(app: *App) void {
    const drum_gid = app.ledger.alloc() orelse return;
    const bass_gid = app.ledger.alloc() orelse {
        selection.set(&app.multi_selected, group.handleOfGroup(drum_gid), false);
        app.ledger.free(drum_gid);
        return;
    };
    const drum_members = [_]Handle{
        app.patch.kick_seq_h,
        app.patch.hat_seq_h,
        app.patch.clap_seq_h,
        app.patch.kick_h,
        app.patch.hat_h,
        app.patch.clap_h,
    };
    const bass_members = [_]Handle{
        app.patch.bass_seq_h,
        app.patch.bass_perc_h,
        app.patch.vco_h,
        app.patch.vcf_h,
        app.patch.vca_h,
    };
    registerGeneratedMacro(
        app,
        drum_gid,
        .drum_machine,
        .{ .x = 40, .y = 330 },
        3,
        &drum_members,
        &GENERATED_DRUM_OFFSETS,
    );
    registerGeneratedMacro(
        app,
        bass_gid,
        .bass_machine,
        .{ .x = 40, .y = 440 },
        4,
        &bass_members,
        &GENERATED_BASS_OFFSETS,
    );
    // Re-derive the shared clock and external mixer/voice boundary from real graph edges.
    app.refreshAllExposed();
}

/// Add a module or macro from a palette index (comptime kind dispatch) → place near screen centre → publish.
fn addByPaletteIndex(app: *App, ki: u8) !void {
    const casc: f32 = @floatFromInt(app.dyn.activeCount() % 8);
    const cx: f32 = app.canvasW() * 0.45 + casc * 18;
    const cy: f32 = app.canvasH() * 0.4 + casc * 18;
    inline for (PALETTE, 0..) |entry, i| {
        if (i == ki) {
            switch (entry) {
                .primitive => |kind| {
                    // Primitives stay as before (no clip clamp = behaviour unchanged).
                    const pos = app.camera.screenToWorld(.{ .x = cx, .y = cy });
                    const h = try app.dyn.add(kind, .{});
                    app.layout[h] = pos;
                    try app.dyn.publish();
                    _ = allocNodeId(app, h);
                    app.selected = .{ .node = h };
                },
                // Macros clamp the screen anchor so the expanded footprint fits the default fb, then place.
                .macro_kind => |mk| try addMacro(app, mk, .{ .x = cx, .y = cy }),
                .step_seq_bass => {
                    const pos = app.camera.screenToWorld(.{ .x = cx, .y = cy });
                    const h = try app.dyn.add(.step_seq, stepSeqBassInit);
                    app.layout[h] = pos;
                    try app.dyn.publish();
                    _ = allocNodeId(app, h);
                    app.selected = .{ .node = h };
                },
            }
            return;
        }
    }
}

/// Macro-expand subgraph footprint (world width/height from group.pos). Bottom-right of the bbox that contains
/// the header box + every member's real node size (top-left is always (0,0)). members/offsets are same order and length.
fn macroFootprint(app: *const App, members: []const Handle, offsets: []const Vec2f) Vec2f {
    const header = NodeGeom{ .handle = group.GROUP_HANDLE_BASE, .pos = .{ .x = 0, .y = 0 }, .n_in = 0, .n_out = 0 };
    var w: f32 = canvas.nodeSize(header).x; // = NODE_W
    var h: f32 = canvas.nodeSize(header).y;
    for (members, offsets) |m, off| {
        const geom = NodeGeom{ .handle = m, .pos = off, .n_in = app.dyn.nIn(m), .n_out = app.dyn.nOut(m) };
        const sz = canvas.nodeSize(geom);
        w = @max(w, off.x + sz.x);
        h = @max(h, off.y + sz.y);
    }
    return .{ .x = w, .y = h };
}

/// Convert footprint to screen size (world × zoom) and clamp anchor(screen) so the bottom-right stays inside the fb,
/// then convert to world. Protect with @max so the lower bound is not breached even when the footprint is wider than the fb.
fn clampMacroPos(app: *const App, anchor: Vec2f, fp: Vec2f) Vec2f {
    // anchor is center-local screen coords.
    const zoom = app.camera.zoom;
    const margin: f32 = 16;
    const top_limit: f32 = (paletteBottom(app) - app.canvas_rect.y) + margin; // Bottom of the palette band (local)
    const fbw: f32 = app.canvasW();
    const fbh: f32 = app.canvasH();
    const max_x = @max(margin, fbw - fp.x * zoom - margin);
    const max_y = @max(top_limit, fbh - fp.y * zoom - margin);
    const sx = std.math.clamp(anchor.x, margin, max_x);
    const sy = std.math.clamp(anchor.y, top_limit, max_y);
    return app.camera.screenToWorld(.{ .x = sx, .y = sy });
}

/// Add a macro (DrumMachine / BassMachine) from the palette. macro.zig owns preflight+add+connect+1publish;
/// register on the ledger (group_of/exposed_in/out/collapsed=true) only after publish succeeds.
/// `anchor` is the add position in screen coords. Clamp so the expanded footprint fits the default fb, then place.
fn addMacro(app: *App, kind: group.MacroKind, anchor: Vec2f) !void {
    switch (kind) {
        .drum_machine => {
            const h = try macro.buildDrumMachine(app.dyn); // On failure nothing remains (rollback inside macro.zig)
            const members = [_]Handle{ h.cdiv, h.seq_k, h.seq_h, h.kick, h.hat, h.mix };
            for (members) |m| _ = allocNodeId(app, m);
            const gid = app.ledger.alloc() orelse {
                // Ledger exhaustion (MAX_GROUPS cap; very rare): fold published members back (1 publish).
                for (members) |m| {
                    clearNodeIdMapping(app, m);
                    selection.set(&app.multi_selected, m, false);
                    app.dyn.removeModule(m);
                }
                app.dyn.publish() catch {};
                return;
            };
            const pos = clampMacroPos(app, anchor, macroFootprint(app, &members, &DRUM_OFFSETS));
            finishDrumMacroLedger(app, gid, h, pos, &members);
        },
        .bass_machine => {
            const h = try macro.buildBassMachine(app.dyn);
            const members = [_]Handle{ h.seq, h.vco, h.vcf, h.env, h.vca };
            for (members) |m| _ = allocNodeId(app, m);
            const gid = app.ledger.alloc() orelse {
                for (members) |m| {
                    clearNodeIdMapping(app, m);
                    selection.set(&app.multi_selected, m, false);
                    app.dyn.removeModule(m);
                }
                app.dyn.publish() catch {};
                return;
            };
            const pos = clampMacroPos(app, anchor, macroFootprint(app, &members, &BASS_OFFSETS));
            finishBassMacroLedger(app, gid, h, pos, &members);
        },
    }
}

/// For wire `add_macro`: use world coords as group.pos directly (no clamp; for peer determinism).
/// NodeId is always monotonic from `allocNodeId` (redo also gets a fresh id; same shape as pixie).
fn addMacroAtWorld(app: *App, kind: group.MacroKind, pos: Vec2f, out_ids: *[patch_undo.MAX_MACRO_MEMBERS]u64, out_n: *u8) !void {
    const assignIds = struct {
        fn go(a: *App, members: []const Handle, out: *[patch_undo.MAX_MACRO_MEMBERS]u64, on: *u8) void {
            on.* = 0;
            for (members) |m| {
                _ = allocNodeId(a, m);
                if (on.* < patch_undo.MAX_MACRO_MEMBERS) {
                    out[on.*] = nodeIdOf(a, m).?.raw();
                    on.* += 1;
                }
            }
        }
    }.go;
    switch (kind) {
        .drum_machine => {
            const h = try macro.buildDrumMachine(app.dyn);
            const members = [_]Handle{ h.cdiv, h.seq_k, h.seq_h, h.kick, h.hat, h.mix };
            assignIds(app, &members, out_ids, out_n);
            const gid = app.ledger.alloc() orelse {
                for (members) |m| {
                    clearNodeIdMapping(app, m);
                    selection.set(&app.multi_selected, m, false);
                    app.dyn.removeModule(m);
                }
                app.dyn.publish() catch {};
                platform.setActionErrorDetail("too_many_nodes", "macro ledger full");
                return error.TooManyNodes;
            };
            finishDrumMacroLedger(app, gid, h, pos, &members);
        },
        .bass_machine => {
            const h = try macro.buildBassMachine(app.dyn);
            const members = [_]Handle{ h.seq, h.vco, h.vcf, h.env, h.vca };
            assignIds(app, &members, out_ids, out_n);
            const gid = app.ledger.alloc() orelse {
                for (members) |m| {
                    clearNodeIdMapping(app, m);
                    selection.set(&app.multi_selected, m, false);
                    app.dyn.removeModule(m);
                }
                app.dyn.publish() catch {};
                platform.setActionErrorDetail("too_many_nodes", "macro ledger full");
                return error.TooManyNodes;
            };
            finishBassMacroLedger(app, gid, h, pos, &members);
        },
    }
}

fn finishDrumMacroLedger(app: *App, gid: group.GroupId, h: macro.DrumMachineHandles, pos: Vec2f, members: *const [6]Handle) void {
    const g = &app.ledger.groups[gid];
    g.kind = .drum_machine;
    g.collapsed = true;
    g.pos = pos;
    for (members.*, DRUM_OFFSETS) |m, off| {
        app.ledger.assign(m, gid);
        app.layout[m] = pos.add(off);
    }
    g.exposed_in[0] = .{ .member = h.cdiv, .port = 0, .is_input = true };
    group.setLabel(&g.exposed_in[0], "clock");
    g.n_in = 1;
    g.template_n_in = 1;
    g.exposed_out[0] = .{ .member = h.mix, .port = 0, .is_input = false };
    group.setLabel(&g.exposed_out[0], "audio");
    g.n_out = 1;
    g.template_n_out = 1;
    app.selected = .{ .group = gid };
}

fn finishBassMacroLedger(app: *App, gid: group.GroupId, h: macro.BassMachineHandles, pos: Vec2f, members: *const [5]Handle) void {
    const g = &app.ledger.groups[gid];
    g.kind = .bass_machine;
    g.collapsed = true;
    g.pos = pos;
    for (members.*, BASS_OFFSETS) |m, off| {
        app.ledger.assign(m, gid);
        app.layout[m] = pos.add(off);
    }
    g.exposed_in[0] = .{ .member = h.seq, .port = 0, .is_input = true };
    group.setLabel(&g.exposed_in[0], "clock");
    g.n_in = 1;
    g.template_n_in = 1;
    g.exposed_out[0] = .{ .member = h.vca, .port = 0, .is_input = false };
    group.setLabel(&g.exposed_out[0], "audio");
    g.n_out = 1;
    g.template_n_out = 1;
    app.selected = .{ .group = gid };
}

/// Delete the selected node/cable/group (Delete/Backspace). Via the action route.
fn deleteSelected(app: *App) void {
    if (app.selected) |it| {
        switch (it) {
            .node => |h| {
                const id = nodeIdOf(app, h) orelse return;
                var args_buf: [32]u8 = undefined;
                const args = actions.formatNodeId(&args_buf, id.raw()) catch return;
                routeUiAction(app, "remove_node", args);
            },
            .cable => |cr| {
                routeDisconnect(app, cr.dst_handle, cr.dst_in);
            },
            .group => |gid| {
                // remove_macro: list of member #id
                var args_buf: [512]u8 = undefined;
                var off: usize = 0;
                var first = true;
                var h: Handle = 0;
                while (h < MAX_MODULES) : (h += 1) {
                    if (app.ledger.group_of[h]) |g| {
                        if (g == gid) {
                            const id = nodeIdOf(app, h) orelse continue;
                            const piece = if (first)
                                std.fmt.bufPrint(args_buf[off..], "#{d}", .{id.raw()}) catch break
                            else
                                std.fmt.bufPrint(args_buf[off..], " #{d}", .{id.raw()}) catch break;
                            off += piece.len;
                            first = false;
                        }
                    }
                }
                if (off == 0) return;
                routeUiAction(app, "remove_macro", args_buf[0..off]);
            },
            .port => {},
        }
    }
}

fn onMouseMove(app: *App) void {
    switch (app.drag) {
        .none => updateHover(app),
        .pan => |p| {
            // pan/start_mouse are center-local screen coords.
            const local = app.toCanvasLocal(app.mouse);
            app.camera.pan = p.start_pan.add(local.sub(p.start_mouse));
        },
        .node => |nd| {
            const mw = app.mouseWorld();
            app.layout[nd.handle] = mw.add(nd.grab_offset);
        },
        .group => |gd| {
            const mw = app.mouseWorld();
            const new_pos = mw.add(gd.grab_offset);
            app.ledger.setPosAndTranslateMembers(gd.gid, new_pos, app.layout[0..]);
        },
        .cable => {}, // pending is drawn every frame from app.mouse (no state update)
        .rect_select => {}, // Rect is drawn by drawFrame from mouseWorld (no state update)
    }
}

// ============================================================================
// A/D: update port activity + select/publish tap targets.
// ============================================================================
const MINI_BG = gui.Color.rgba(0x0A, 0x0E, 0x12, 0xFF);
const VALUE_COL = gui.Color.rgba(0x90, 0x98, 0xA0, 0xFF); // Compact parameter-value display colour
// Mini-scope display sample count (after decimation). Kept smaller than TAP_RING so trigger search has remaining window.
// 128 post-decimation points ≈ 10.6ms; at 110Hz (period 9ms) the search window covers ≥1 cycle and can lock.
const MINI_DISP: usize = 128;

/// Extract the display handle used for tap priority from a selected/hover Item (node/group only).
fn itemHandle(item: ?Item) ?Handle {
    if (item) |it| {
        return switch (it) {
            .node => |h| h,
            .group => |gid| group.handleOfGroup(gid),
            else => null,
        };
    }
    return null;
}

/// Resolve a display handle (real or synthetic box) to a real global output port id (handle*MAX_OUT+out). out0 is representative.
/// Unresolvable (no output / inactive / no expose on synthetic box) → -1. Keep the no-synthetic-handle-into-dyn rule.
///
/// Tap-slot stability contract: this function's return (real port id) and the display handle (stability key) are
/// intentionally separate axes. (1) Same synthetic-box handle but a changed `exposed_out[0]` member/port → return changes
/// (updateViz republishes). (2) Different display handles exposing the same real member/port → return may match
/// (updateViz does not republish). updateViz detects change by
/// `new_ports[] (this return) != app.tap_ports[]`, separately from slot retention (handle match).
/// Body is `group.resolveExposedPort` (extracted App-free and pinned by test-patch).
fn resolveTapPort(app: *const App, dh: Handle) i32 {
    // app.dyn is already *DynGraph. &app.dyn would be ** and duck-typed method resolve would fail.
    return group.resolveExposedPort(&app.ledger, app.dyn, dh);
}

/// Activity of output port i on a display handle (synthetic box resolves to the real member's activity via exposed_out[i]).
fn outPortLevel(app: *const App, dh: Handle, i: u8) f32 {
    if (group.groupIdFromHandle(dh)) |gid| {
        const g = app.ledger.groups[gid];
        if (i >= g.n_out) return 0;
        const ref = g.exposed_out[i];
        if (ref.member >= MAX_MODULES or ref.port >= MAX_OUT) return 0;
        return app.port_level[ref.member][ref.port];
    }
    if (dh >= MAX_MODULES or i >= MAX_OUT) return 0;
    return app.port_level[dh][i];
}

/// Per frame: A (peak-hold decay of every output port's activity) + D (tap-target select; config publish only on change).
fn updateViz(app: *App) void {
    // A: peak-hold + decay activity of every active node's output ports (read-only sigLevel; zero RT impact).
    const decay: f32 = 0.90;
    var h: Handle = 0;
    while (h < MAX_MODULES) : (h += 1) {
        if (!app.dyn.slotActive(h)) {
            app.port_level[h] = [_]f32{0} ** MAX_OUT;
            continue;
        }
        const no = app.dyn.nOut(h);
        var o: u8 = 0;
        while (o < MAX_OUT) : (o += 1) {
            app.port_level[h][o] = if (o < no) @max(app.dyn.sigLevel(h, o), app.port_level[h][o] * decay) else 0;
        }
    }

    // D: tap-target select (stable). Existing slots (tap_ports>=0) that are still candidates this frame
    // keep the same slot number — unrelated hover/selected changes must not reset them as collateral.
    var node_buf: [MAX_MODULES]NodeGeom = undefined;
    const nodes = node_buf[0..app.buildNodes(&node_buf)];
    const sel = itemHandle(app.selected);
    const hov = itemHandle(app.hover);

    var prev: [TAP_SLOTS]?Handle = undefined;
    for (0..TAP_SLOTS) |s| prev[s] = if (app.tap_ports[s] >= 0) app.tap_display[s] else null;
    var handles: [TAP_SLOTS]?Handle = undefined;
    canvas.selectTapPortsStable(app.camera, app.canvasW(), app.canvasH(), nodes, sel, hov, &prev, &handles);

    var new_ports: [TAP_SLOTS]i32 = [_]i32{-1} ** TAP_SLOTS;
    // Per port kind: choose decimation and reduce (audio=fine waveform / cv=coarse modulation / gate=coarse peak bar).
    var new_decim: [TAP_SLOTS]u32 = [_]u32{modular.graph_core.TAP_DECIM} ** TAP_SLOTS;
    var new_peak: [TAP_SLOTS]bool = [_]bool{false} ** TAP_SLOTS;
    for (0..TAP_SLOTS) |s| {
        const dh = handles[s] orelse continue;
        new_ports[s] = resolveTapPort(app, dh);
        if (new_ports[s] < 0) continue;
        switch (portKindOut(app, dh, 0)) {
            .audio => {
                new_decim[s] = modular.graph_core.TAP_DECIM;
                new_peak[s] = false;
            },
            .cv => {
                new_decim[s] = modular.graph_core.TAP_DECIM_SLOW;
                new_peak[s] = false;
            },
            .gate => {
                new_decim[s] = modular.graph_core.TAP_DECIM_SLOW;
                new_peak[s] = true;
            },
        }
    }

    // Change detection is per-slot: whether the real global port ID (new_ports) changed.
    // Slot-retention stability key is the display handle, but republish/tap_slot_seq update triggers on the real port ID
    // (no republish if the handle changes but the real port ID stays the same; republish if the handle stays the same but
    // the real port ID changes, e.g. a synthetic node's exposed port change).
    var changed = false;
    var s: usize = 0;
    while (s < TAP_SLOTS) : (s += 1) {
        if (new_ports[s] != app.tap_ports[s]) {
            changed = true;
            break;
        }
    }
    if (changed) {
        app.tap_seq += 1;
        s = 0;
        while (s < TAP_SLOTS) : (s += 1) {
            if (new_ports[s] != app.tap_ports[s]) app.tap_slot_seq[s] = app.tap_seq;
        }
        app.tap_ports = new_ports;
        app.dyn.publishTapConfig(.{ .seq = app.tap_seq, .ports = new_ports, .decim = new_decim, .peak = new_peak });
    }
    // Update display handles for drawing every frame (follow node drag; independent of publish).
    // Allow holes in slots (drop the contiguous 0..tap_count assumption).
    var count: usize = 0;
    s = 0;
    while (s < TAP_SLOTS) : (s += 1) {
        if (handles[s]) |dh| {
            app.tap_display[s] = dh;
            count += 1;
        }
    }
    app.tap_count = count;
}

/// Draw a mini oscilloscope for each tapped port along the inner bottom band of the node (per frame; ≤16 × 64×28px).
/// applied_seq gate: do not draw the trace until RT has applied that slot's port assignment (prevents stale-port bleed).
/// Slot stability can leave holes, so scan the full `slot < TAP_SLOTS` range (`tap_count` is
/// not a contiguous-bound; same rule as the existing digest/snapshot loops).
fn drawMiniScopes(app: *App, dl: *gui.DrawList, nodes: []const NodeGeom) void {
    const applied = app.dyn.tapAppliedSeq();
    var win: [TAP_RING]f32 = undefined;
    var slot: usize = 0;
    while (slot < TAP_SLOTS) : (slot += 1) {
        if (app.tap_ports[slot] < 0) continue;
        const dh = app.tap_display[slot];
        const g = findNode(nodes, dh) orelse continue;
        const tl = app.worldToAbs(g.pos);
        const sz = canvas.nodeSize(g).scale(app.camera.zoom);
        const lr = canvas.miniScopeRect(tl, sz, app.camera.zoom);
        const rect = gui.Rect{ .x = safeI32(lr.x), .y = safeI32(lr.y), .w = safeU32(lr.w), .h = safeU32(lr.h) };
        const kind = portKindOut(app, dh, 0);
        const col = portColor(kind);
        dl.rectFilled(rect, MINI_BG) catch {};
        dl.rectOutline(rect, col, 1) catch {};
        if (applied < app.tap_slot_seq[slot]) continue; // Unapplied slots get an empty window (frame only)
        const nsamp = app.dyn.tapWindow(slot, &win);
        if (nsamp >= 2) {
            // audio: rising zero-crossing trigger freezes the waveform (readable shape; search room is the MINI_DISP window).
            // cv/gate: free-running full window (gate=peak-bar timing; cv=show slow modulation as long as possible).
            const disp = if (kind == .audio) @min(nsamp, MINI_DISP) else nsamp;
            const start = if (kind == .audio) canvas.findTriggerStart(win[0..nsamp], disp) else 0;
            drawMiniTrace(dl, rect, kind, win[start .. start + disp], col);
        }
    }
}

/// Compact display of key parameter values (value only; no parameter names).
/// Drawn inside the always-reserved mini-scope band of nodes with n_out>0 (see nodeSize), to the right of the scope rect.
/// Synthetic/collapsed-group handles (not real DynGraph handles) are out of scope. Every frame regardless of tap,
/// over all nodes (GUI per-frame work; O(node count); does not touch the RT path).
/// Strings come from the per-frame arena (`app.gui_ctx.allocator()`); long values are clipped to the node's own rect
/// so they do not spill into neighbouring nodes.
fn drawNodeParamValues(app: *App, dl: *gui.DrawList, nodes: []const NodeGeom) void {
    for (nodes) |g| {
        if (g.n_out == 0) continue;
        if (group.groupIdFromHandle(g.handle) != null) continue; // Synthetic handles get no value display
        const kind = app.dyn.kindOf(g.handle) orelse continue;
        const descs = switch (kind) {
            inline else => |comptime_kind| modular.descriptors(comptime_kind),
        };
        const desc = param_view.primaryDescriptor(descs) orelse continue;
        const value = modular.getParam(app.dyn, g.handle, desc.name) catch continue;
        const text = formatParamValueCompact(app.gui_ctx.allocator(), desc, value) orelse continue;
        if (text.len == 0) continue;

        const tl = app.worldToAbs(g.pos);
        const sz = canvas.nodeSize(g).scale(app.camera.zoom);
        const scope_rect = canvas.miniScopeRect(tl, sz, app.camera.zoom);
        const node_rect = gui.Rect{ .x = safeI32(tl.x), .y = safeI32(tl.y), .w = safeU32(sz.x), .h = safeU32(sz.y) };
        const text_h = gui.fontInkHeight(app.title_font);
        const text_y = gui.centeredTextY(safeI32(scope_rect.y), safeI32(scope_rect.h), text_h);
        const value_x = safeI32(scope_rect.x + scope_rect.w) + 4;

        dl.pushClip(node_rect) catch {};
        dl.textEx(.{ .x = value_x, .y = text_y }, text, VALUE_COL, app.title_font) catch {};
        dl.popClip();
    }
}

/// Format a ParamValue into a compact value-only string (no parameter name).
/// scalar: digit count from ScalarDesc.step (do not hard-code one decimal place).
/// choice: use ChoiceDesc.options[idx] as-is (OOB / non-finite → null = hide).
fn formatParamValueCompact(alloc: std.mem.Allocator, desc: modular.ParamDesc, value: modular.ParamValue) ?[]const u8 {
    return switch (value) {
        .scalar => |v| blk: {
            if (!std.math.isFinite(v)) break :blk null;
            const unit = switch (desc.kind) {
                .scalar => |sd| sd.unit,
                .choice => "",
            };
            const decimals: u8 = switch (desc.kind) {
                .scalar => |sd| decimalsForStep(sd.step),
                .choice => 0,
            };
            break :blk (switch (decimals) {
                0 => std.fmt.allocPrint(alloc, "{d:.0}{s}", .{ v, unit }),
                1 => std.fmt.allocPrint(alloc, "{d:.1}{s}", .{ v, unit }),
                else => std.fmt.allocPrint(alloc, "{d:.2}{s}", .{ v, unit }),
            }) catch null;
        },
        .choice => |idx| switch (desc.kind) {
            .choice => |cd| if (idx < cd.options.len) cd.options[idx] else null,
            .scalar => null,
        },
    };
}

fn decimalsForStep(step: f32) u8 {
    if (!std.math.isFinite(step) or step >= 1.0) return 0;
    if (step >= 0.1) return 1;
    return 2;
}

/// Mini-scope trace. audio = centre-line (-1..1) polyline; cv = bottom-based (0..1) polyline;
/// gate = bottom-based impulse bars (paint high columns as verticals from the baseline = sparse pulses stay readable).
fn drawMiniTrace(dl: *gui.DrawList, rect: gui.Rect, kind: PortKind, samples: []const f32, col: gui.Color) void {
    const n = samples.len;
    if (n < 2 or rect.w < 2) return;
    const w: usize = rect.w;
    const top: f32 = @floatFromInt(rect.y);
    const hh: f32 = @floatFromInt(rect.h);
    const bottom = top + hh - 1;
    const mid = top + (hh - 1) * 0.5;
    const by = safeI32(bottom);

    if (kind == .gate) {
        // Sparse pulse trains look like 1px spikes as a polyline → paint high columns as vertical bars from the baseline.
        // Thinning from the column side can miss sparse highs, so scan every sample into columns (every high becomes ≥1 bar).
        var si: usize = 0;
        while (si < n) : (si += 1) {
            const s = std.math.clamp(samples[si], 0.0, 1.0);
            if (s > 0.05) {
                const px = rect.x + @as(i32, @intCast(si * (w - 1) / (n - 1)));
                dl.line(.{ .x = px, .y = by }, .{ .x = px, .y = safeI32(bottom - s * (hh - 1)) }, col, 1) catch {};
            }
        }
        return;
    }

    var prev: ?gui.Vec2 = null;
    var xc: usize = 0;
    while (xc < w) : (xc += 1) {
        const s = samples[xc * (n - 1) / (w - 1)];
        const py: f32 = switch (kind) {
            .audio => mid - std.math.clamp(s, -1.0, 1.0) * ((hh - 1) * 0.5),
            .cv, .gate => bottom - std.math.clamp(s, 0.0, 1.0) * (hh - 1),
        };
        const pt = gui.Vec2{ .x = rect.x + @as(i32, @intCast(xc)), .y = safeI32(py) };
        if (prev) |pp| dl.line(pp, pt, col, 1) catch {};
        prev = pt;
    }
}

// ============================================================================
// C: master-output visualisation strip (screen bottom). Two-layer draw.
// Layer A: draw Spec/Scope/Meter into a fixed logical-resolution bitmap; DrawList.image nearest-scales it.
// Layer B: add labels/ticks to gui_ctx.draw_list in logical coords; gui.render(scale) draws them in physical px afterwards.
// Intermediate bitmap is allocated once at startup (no per-frame allocation). comptime Spec/Scope sizes are fixed.
// ============================================================================
const FreqLabel = struct { hz: f32, text: []const u8 };
const FREQ_LABELS = [_]FreqLabel{
    .{ .hz = 100, .text = "100Hz" },
    .{ .hz = 1000, .text = "1kHz" },
    .{ .hz = 10000, .text = "10kHz" },
};
/// Logical bitmap width of the visualisation strip (fixed at startup; not rebuilt on resize).
const VIZ_BITMAP_W: u32 = WIN_W;

/// Layer A: background + Spec/Scope/Meter on the logical bitmap (no labels).
fn drawVizBitmap(
    viz_pixels: []u32,
    spec: *const Spec,
    osc: *const Scope,
    meter: *const scope.LevelMeter,
) void {
    std.debug.assert(viz_pixels.len >= VIZ_BITMAP_W * VIS_H);
    // Strip background: one contiguous bulk write (do not write a per-pixel loop).
    // `fill32` rather than `@memset` because the four bytes of VIS_BG differ.
    pixelops.fill32(viz_pixels[0 .. VIZ_BITMAP_W * VIS_H], VIS_BG);
    const draw_y: usize = VIS_LABEL_H;
    // y=0..VIS_LABEL_H is background only. Draw area is y=VIS_LABEL_H..VIS_H.
    spec.draw(viz_pixels, VIZ_BITMAP_W, VIS_H, SPEC_X0, draw_y);
    osc.draw(viz_pixels, VIZ_BITMAP_W, VIS_H, SCOPE_X0, draw_y);
    meter.draw(viz_pixels, VIZ_BITMAP_W, VIS_H, METER_X0, draw_y, METER_W, VIS_DRAW_H);
}

/// Layer B: labels and frequency ticks onto DrawList in logical coords (gui.render applies scale; P3 font).
fn drawVizLabels(app: *const App, dl: *gui.DrawList, spec: *const Spec) void {
    const band_y0: i32 = @intFromFloat(app.vizBandY0());
    if (band_y0 < 0) return;
    const label_col = gui.Color.rgba(0xC8, 0xD0, 0xD8, 0xFF);
    const tick_col = gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);
    const ly: i32 = band_y0 + 3;
    // Static strings must outlive the DrawList.
    dl.text(.{ .x = SPEC_X0, .y = ly }, "SPECTROGRAM", label_col) catch {};
    dl.text(.{ .x = SCOPE_X0, .y = ly }, "SCOPE (master)", label_col) catch {};
    dl.text(.{ .x = @intCast(METER_X0), .y = ly }, "LVL", label_col) catch {};

    const draw_y: i32 = band_y0 + VIS_LABEL_H;
    for (FREQ_LABELS) |fl| {
        const off = spec.rowOffsetForFreq(fl.hz) orelse continue;
        const tick_y: i32 = draw_y + @as(i32, @intCast(off));
        // Tick marks (logical 6px. render scales thickness)
        dl.line(
            .{ .x = SPEC_X0, .y = tick_y },
            .{ .x = SPEC_X0 + 6, .y = tick_y },
            tick_col,
            1,
        ) catch {};
        dl.text(.{ .x = SPEC_X0 + 8, .y = tick_y }, fl.text, label_col) catch {};
    }
}

pub fn main(init: std.process.Init) !void {
    std.debug.print("apps/patch: patch canvas (drag=move/pan, scroll=zoom, ESC quits)\n", .{});
    const allocator = std.heap.c_allocator;

    try platform.init();
    defer platform.shutdown();

    // .physical fb (HiDPI). Layout uses logical_size; content_scale at the draw exit.
    var window = try platform.Window.createWithOptions(WIN_W, WIN_H, "patch canvas (modular)", .{
        .fb_mode = .physical,
    });
    defer window.destroy();

    // Native menu facade: call once manually right after Window.create (do not migrate into app_runtime).
    // app is stack-settled immediately after, so register the menu after app init.

    // audio: open fixes the sample rate → build LofiPatch → initial publish → then start (sound from the first beat).
    // The RT callback fires only after start, so settling app before start is safe (app is stack-fixed and never moved).
    var app: App = undefined;
    const device = audio.open(allocator, .{
        .sample_rate = 48000,
        .buffer_frames = 512,
        .channels = 2,
        .render_callback = audioCallback,
        .userdata = &app,
    }) catch |err| {
        std.debug.print("audio.open failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer device.close();

    const sr_u32 = device.config().sample_rate;
    const sr: f32 = @floatFromInt(sr_u32);
    const patch = LofiPatch.create(allocator, sr) catch |err| {
        std.debug.print("LofiPatch.create failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer patch.destroy();

    const undo_store = patch_undo.PatchUndoStore.create(allocator) catch |err| {
        std.debug.print("PatchUndoStore.create failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer undo_store.destroy();

    app = App{ .patch = patch, .dyn = patch.graph, .io = init.io, .sample_rate = sr_u32, .undo_store = undo_store };
    app.observed_field = defaultObservedField(&app);
    std.debug.assert(midiBindingDescriptorsExist());
    // Initial placement is baked via runAutoLayout in the main loop after centerRect becomes valid.
    registerGeneratedMacros(&app);
    // Assign NodeIds deterministically in ascending runtime-handle order of the initial graph.
    assignInitialNodeIds(&app);

    // Native menu (headless → false → GUI fallback).
    app.rebuildMenuCommands();
    if (window.nativeMenuAvailable()) {
        app.native_menu_active = true;
        window.registerMenu(app.menuCommandsSlice());
    }
    defer if (app.native_menu_active) window.destroyMenu();

    var dl = gui.DrawList.init(allocator);
    defer dl.deinit();
    // GuiFont is placed last on the stack. Register its defer before gui_ctx so LIFO frees ctx→font.
    var gui_font: kit.GuiFont = .{};
    defer gui_font.deinit();
    var gui_ctx = gui.Context.init(allocator, gui.default_font);
    defer gui_ctx.deinit();
    gui_font.load(init.io, allocator);
    gui_ctx.font = gui_font.asFont();
    app.title_font = gui_font.asTitleFont();

    // PanelHost registry — History=left, Inspector=right (Transport removed).
    var panels = [_]gui.Panel{
        .{ .name = "History", .slot = .left, .build = buildHistoryPanel, .user_data = &app },
        .{ .name = "Inspector", .slot = .right, .build = buildInspectorPanel, .user_data = &app },
    };
    var panel_host = try gui.PanelHost.init(panels[0..], .{
        .left = .{ .extent = 220, .min_extent = 140, .max_extent = 400 },
        .right = .{ .extent = 280, .min_extent = 160, .max_extent = 480 },
        .bottom = .{ .visible = false, .extent = 0, .min_extent = 0, .max_extent = 1 },
        .min_center_width = 200,
        .min_center_height = 160,
    });
    app.panel_host = &panel_host;
    app.panels = panels[0..];
    app.gui_ctx = &gui_ctx;

    // appshell Preferences (panel/slot persistence).
    app.prefs = appshell.preferences.Preferences.init(allocator);
    const override_path = if (std.c.getenv("KNGN_APPSHELL_DIR")) |v| std.mem.span(v) else null;
    if (appshell.paths.openAppDataDir(app.io, allocator, "patch", override_path)) |dir| {
        app.prefs_dir = dir;
        _ = app.prefs.load(app.io, dir, "preferences.ash") catch {};
        panel_host.restore(panelPersistence(&app));
        // Migrate: if old prefs left left.visible=false, History would never appear.
        // If the History panel is visible, enable the left slot (per-panel OFF is panel_toggle history).
        if (app.panelVisible("History")) {
            panel_host.setSlotVisible(.left, true);
        }
    } else |err| {
        std.debug.print("apps/patch: preferences dir open failed: {s}\n", .{@errorName(err)});
    }
    // Startup auto-layout is a 1-shot apply inside the main loop (first time centerRect is non-null).

    // C: master visualisation (spectrogram/oscilloscope/level meter). comptime size is large → heap-allocate.
    const spec = try allocator.create(Spec);
    defer allocator.destroy(spec);
    spec.init(48000);
    spec.setSampleRate(sr);
    const osc = try allocator.create(Scope);
    defer allocator.destroy(osc);
    osc.* = .{};
    var meter = scope.LevelMeter{};
    // Logical-resolution viz intermediate bitmap (once at startup; no per-frame alloc; not embedded in App).
    const viz_pixels = try allocator.alloc(u32, VIZ_BITMAP_W * VIS_H);
    defer allocator.free(viz_pixels);

    platform.registerProbe(.{ .name = "patch", .ctx = &app, .ext = "json", .snapshot = patchSnapshot, .digest = patchDigest });
    platform.registerProbe(.{ .name = "group", .ctx = &app, .ext = "json", .snapshot = null, .digest = groupDigest });
    platform.registerProbe(.{ .name = "viz", .ctx = &app, .ext = "json", .snapshot = vizSnapshot, .digest = vizDigest });
    platform.registerProbe(.{ .name = "modular", .ctx = &app, .ext = "json", .snapshot = modularSnapshot, .digest = modularDigest });
    platform.registerProbe(.{ .name = "panel", .ctx = &app, .ext = "json", .snapshot = null, .digest = panelDigest });
    platform.registerProbe(.{ .name = "params", .ctx = &app, .ext = "json", .snapshot = paramsSnapshot, .digest = paramsDigest });
    platform.registerProbe(.{ .name = "menu", .ctx = &app, .ext = "txt", .digest = menuDigest, .desc = "menu open/items/enabled/checked/pending/last_op/native" });
    platform.registerProbe(.{ .name = "midi_map", .ctx = &app, .ext = "txt", .snapshot = null, .digest = midiMapDigest, .desc = "fixed MIDI CC map v1" });
    // Register harness custom actions (no-op when harness is off).
    app.cmd_exec = platform.command.Executor.init(.{ .ctx = &app, .run = dispatchModularAction });
    app.cmd_exec.log = &app.cmd_log;
    // Undo inverse-apply adapter.
    app.cmd_exec.adapter = .{ .ctx = &app, .canUndo = patchCanUndo, .applyUndo = patchApplyUndo, .summarize = patchSummarize };
    platform.setCommandExecutor(&app.cmd_exec);
    registerPatchActions(&app);
    registerActions(&app);
    registerIntegratedStateSync(&app);

    // MIDI device (harness → synthetic FIFO; native → CoreMIDI).
    var midi_device = midi.open(allocator) catch |err| {
        std.debug.print("midi.open failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer midi_device.close();

    device.start() catch |err| {
        std.debug.print("audio.start failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer device.stop();
    std.debug.print("apps/patch: drag between ports to patch / add from the palette / Delete removes / scroll=zoom. Audio is running.\n", .{});

    var stereo: [2048]f32 = undefined;
    var mono: [1024]f32 = undefined;
    main_loop: while (app.running and window.pollEvents()) {
        // Deadline-based pacing. Register defer at the top of the loop body so the path that
        // continues when lockFramebuffer is null still waits once (a trailing fixed frameDelay
        // would be skipped on lock miss and busy-loop). defer is LIFO, so it runs after the
        // inner block's fb.unlock() — never sleep while the framebuffer is locked.
        const frame_t0 = platform.getTime();
        defer platform.framePaceUntil(frame_t0 + FRAME_PERIOD_S);
        // Event only: drain the MIDI FIFO (return immediately if empty. Not a per-frame always-on scan).
        drainMidiEvents(&app, &midi_device);
        {
            const fb = window.lockFramebuffer() orelse continue :main_loop;
            defer fb.unlock();
            // Layout/input are logical; RenderTarget is physical. Use only the scale from the same snapshot.
            const logical_w = fb.logical_size.width;
            const logical_h = fb.logical_size.height;
            const content_scale = fb.content_scale;
            const phys_w = fb.width;
            const phys_h = fb.height;
            app.fb_w = logical_w;
            app.fb_h = logical_h;
            gui_ctx.beginFrame(logical_w, logical_h);

            // C: read the master tap → mono downmix → feed spec/osc/meter. Latch latest-block rms/peak.
            var frame_sumsq: f64 = 0;
            var frame_n: usize = 0;
            var frame_peak: f32 = 0;
            while (true) {
                const n = app.tap.read(&stereo);
                if (n < 2) break;
                const frames = n / 2;
                dsp.downmixStereoToMono(stereo[0 .. frames * 2], mono[0..frames]);
                spec.feed(mono[0..frames]);
                osc.feed(mono[0..frames]);
                meter.feed(mono[0..frames]);
                for (mono[0..frames]) |s| {
                    frame_sumsq += @as(f64, s) * @as(f64, s);
                    frame_peak = @max(frame_peak, @abs(s));
                }
                frame_n += frames;
            }
            if (frame_n > 0) {
                app.master_rms = @floatCast(@sqrt(frame_sumsq / @as(f64, @floatFromInt(frame_n))));
                app.master_peak = frame_peak;
            }

            app.rebuildMenuCommands();

            while (window.nextEvent()) |ev| {
                switch (ev) {
                    .quit => app.running = false,
                    .key_down => |k| {
                        // GUI fallback: menu shortcuts (Cmd/Ctrl+S/O). Native: the OS owns them.
                        if (!app.native_menu_active) {
                            if (app.matchMenuShortcut(k)) |cmd_id| {
                                app.dispatchCommand(cmd_id);
                                continue;
                            }
                        }
                        switch (k.key) {
                            .ESCAPE => {
                                if (!app.native_menu_active and app.menu_bar_state.open_title != null) {
                                    app.menu_bar_state.open_title = null;
                                } else {
                                    app.running = false;
                                }
                            },
                            .Z => {
                                const primary = if (builtin.os.tag == .macos) k.modifiers.cmd else k.modifiers.ctrl;
                                if (primary) {
                                    if (k.modifiers.shift) doRedo(&app) else doUndo(&app);
                                    continue;
                                }
                            },
                            .DELETE, .BACKSPACE => deleteSelected(&app),
                            .H => {
                                // Modifier-less H only. Ignore Cmd/Ctrl/Alt/Shift+H.
                                if (!(k.modifiers.shift or k.modifiers.ctrl or k.modifiers.alt or k.modifiers.cmd)) {
                                    app.togglePanelsHidden();
                                }
                            },
                            else => {},
                        }
                    },
                    .key_up => {},
                    .char_input => {},
                    .gamepad_connected, .gamepad_disconnected => {}, // This app does not consume this cross-cutting Event
                    .composition_changed => {}, // composition not consumed (inline preedit is separate)
                    .menu_command => |id| app.dispatchCommand(id),
                    .file_drop => {}, // patch does not consume this
                    .mouse_move => |m| {
                        app.mouse = .{ .x = @floatFromInt(m.x), .y = @floatFromInt(m.y) };
                        gui_ctx.pushEvent(.{ .mouse_move = .{ .x = m.x, .y = m.y, .modifiers = m.modifiers.toC() } });
                        // While dragging, keep following even over a panel (do not cut node/pan at the panel edge). Start requires allowsCanvasInput.
                        if (app.drag != .none or app.allowsCanvasInput()) onMouseMove(&app);
                    },
                    .mouse_down => |m| {
                        const button: u8 = if (m.button == .left) 0 else if (m.button == .right) 1 else 2;
                        gui_ctx.pushEvent(.{ .mouse_down = .{ .x = m.x, .y = m.y, .button = button, .modifiers = m.modifiers.toC() } });
                        app.mouse = .{ .x = @floatFromInt(m.x), .y = @floatFromInt(m.y) };
                        if (m.button == .left) {
                            if (app.allowsCanvasInput()) onMouseDown(&app, m.modifiers);
                        } else if (m.button == .middle) {
                            // Middle button: start pan without the hit-test cascade (allowsCanvasInput gate).
                            if (app.allowsCanvasInput()) {
                                app.drag = .{ .pan = .{
                                    .start_pan = app.camera.pan,
                                    .start_mouse = app.toCanvasLocal(app.mouse),
                                } };
                            }
                        }
                        // Right button does nothing on the canvas (reserved for a future context menu).
                    },
                    .mouse_up => |m| {
                        const button: u8 = if (m.button == .left) 0 else if (m.button == .right) 1 else 2;
                        gui_ctx.pushEvent(.{ .mouse_up = .{ .x = m.x, .y = m.y, .button = button, .modifiers = m.modifiers.toC() } });
                        app.mouse = .{ .x = @floatFromInt(m.x), .y = @floatFromInt(m.y) };
                        if (m.button == .left) {
                            // Accept cable/node/rect_select commit even over a panel (start is center-only).
                            if (app.drag != .none or app.allowsCanvasInput()) onMouseUp(&app);
                        } else if (m.button == .middle) {
                            if (app.drag == .pan) app.drag = .none;
                        }
                    },
                    .mouse_scroll => |s| {
                        app.mouse = .{ .x = @floatFromInt(s.x), .y = @floatFromInt(s.y) };
                        gui_ctx.pushEvent(.{ .mouse_scroll = .{ .x = s.x, .y = s.y, .dx = s.dx, .dy = s.dy, .modifiers = s.modifiers.toC() } });
                        if (app.allowsCanvasInput()) {
                            const factor: f32 = if (s.dy > 0) 1.1 else if (s.dy < 0) 1.0 / 1.1 else 1.0;
                            app.camera.zoomAt(app.toCanvasLocal(app.mouse), factor);
                            updateHover(&app);
                        }
                    },
                }
            }

            // A/D: update activity + select/publish tap targets (just before draw, after event handling).
            // Generation-layer scalars: atomic-publish the latest GUI/action values at control rate.
            publishControls(app.patch, app.params);
            updateViz(&app);
            app.syncInspectorTarget();
            app.beginParamFrame();

            // Whole-framebuffer clear: `fill32` rather than `@memset` (the four bytes of BG differ).
            pixelops.fill32(fb.pixels, BG);
            dl.reset(logical_w, logical_h);
            drawFrame(&app, &dl);

            // Layer A: logical viz bitmap → DrawList.image (first render nearest-scales it).
            // PanelHost assumes content_h = logical_h - menu - VIS_H and does not draw into the VIS_H band
            // (a spacer reserves the strip; snapshots confirm popups do not invade the strip).
            drawVizBitmap(viz_pixels, spec, osc, &meter);
            const band_y0_i: i32 = @intFromFloat(app.vizBandY0());
            const band_bg_col = gui.Color.rgba(0x0A, 0x0E, 0x12, 0xFF);
            // Even when window width > VIZ_BITMAP_W, fill the whole strip width with VIS_BG.
            if (band_y0_i >= 0) {
                dl.rectFilled(.{
                    .x = 0,
                    .y = band_y0_i,
                    .w = @intCast(logical_w),
                    .h = VIS_H,
                }, band_bg_col) catch {};
                dl.image(.{
                    .x = 0,
                    .y = band_y0_i,
                    .w = @intCast(VIZ_BITMAP_W),
                    .h = VIS_H,
                }, viz_pixels[0 .. VIZ_BITMAP_W * VIS_H], VIZ_BITMAP_W, VIS_H) catch {};
            }

            const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = phys_w, .height = phys_h };
            gui.render(target, &dl, gui_ctx.font, content_scale);

            // menu → PanelHost content (above VIS_H) → VIS_H spacer. Logical-size basis.
            const mtop_i: i32 = @intFromFloat(app.menuTopH());
            const vis_h_i: i32 = VIS_H;
            const content_h_i: i32 = @max(0, @as(i32, @intCast(logical_h)) - mtop_i - vis_h_i);
            gui_ctx.beginBox(.{
                .direction = .column,
                .width = .{ .fixed = @intCast(logical_w) },
                .height = .{ .fixed = @intCast(logical_h) },
            });
            if (!app.native_menu_active) {
                gui_ctx.beginBox(.{
                    .direction = .row,
                    .width = .{ .grow = 1 },
                    .height = .{ .fixed = mtop_i },
                    .padding = .{ 4, 4, 4, 4 },
                    .gap = 5,
                    .bg = gui.Color.rgba(0x28, 0x28, 0x30, 0xFF),
                });
                gui.menuBar(&gui_ctx, app.menuCommandsSlice(), &app.menu_bar_state);
                gui_ctx.endBox();
            }
            gui_ctx.beginBox(.{
                .direction = .column,
                .width = .{ .grow = 1 },
                .height = .{ .fixed = content_h_i },
            });
            panel_host.build(&gui_ctx) catch |err| {
                std.debug.print("apps/patch: PanelHost.build failed: {s}\n", .{@errorName(err)});
            };
            gui_ctx.endBox();
            // VIS_H spacer (keeps PanelHost content above the strip so they do not overlap).
            if (vis_h_i > 0) {
                gui_ctx.beginBox(.{ .width = .{ .grow = 1 }, .height = .{ .fixed = vis_h_i } });
                gui_ctx.endBox();
            }
            gui_ctx.endBox();
            if (!gui_ctx.input.mouse_buttons.left) app.releaseParamEdits();
            gui_ctx.endFrame();
            app.syncCanvasRect();
            // Bake auto-layout on the first frame the GUI rect cache is valid.
            // (centerRect is always null at init → canvas would stay full-width and the palette would overlap again)
            if (!app.initial_layout_done) {
                if (app.panel_host.centerRect(app.gui_ctx)) |_| {
                    runAutoLayout(&app);
                    app.initial_layout_done = true;
                }
            }
            if (!app.native_menu_active) {
                const menu_res = gui.menuBarPopup(&gui_ctx, app.menuCommandsSlice(), &app.menu_bar_state);
                if (menu_res.selected) |id| app.dispatchCommand(id);
            }
            app.captureParamRows(&gui_ctx);
            app.advanceParamEdits();
            app.drawGhostMarkers(&gui_ctx.draw_list);
            // Layer B: labels at the end of the second render (after layer A's nearest scale; physical font).
            drawVizLabels(&app, &gui_ctx.draw_list, spec);
            gui.render(target, &gui_ctx.draw_list, gui_ctx.font, content_scale);

            window.present();
        }
        // Dialogs at the safe point after framebuffer unlock (platform.h contract).
        if (app.running) app.runPendingMenuFileOp();
        // evolve authority and host pattern_state broadcast (main-thread event boundary only).
        updateEvolveAuthority(&app);
        maybeBroadcastPatternState(&app);
        // Pacing is owned by the defer (framePaceUntil) at the top of the loop body.
    }
    // Persist panel/slot state to Preferences (on exit).
    persistPanelPrefs(&app);
    if (app.prefs_dir) |*dir| {
        dir.close(app.io);
        app.prefs_dir = null;
    }
    app.prefs.deinit();
    std.debug.print("apps/patch: done.\n", .{});
}

// ============================================================================
// harness custom probe: publish topology (node list + connections) + offscreen counts.
// digest stays within the framework's fixed 1024B.
// The `patch` probe is invariant = always shows the flat topology (real handles; unaffected by collapsed).
// Nesting is machine-checked by pairing with the `group` probe (groupDigest) — digest patch × digest group.
// ============================================================================
fn offscreenOf(app: *const App) canvas.OffscreenCounts {
    var node_buf: [MAX_MODULES]NodeGeom = undefined;
    var edge_buf: [MAX_EDGES]Edge = undefined;
    const nodes = node_buf[0..app.buildRawNodes(&node_buf)];
    const edges = edge_buf[0..app.buildFlatEdges(&edge_buf)];
    // Offscreen checks use the canvas height (excluding the bottom viz strip). Nodes hidden by the strip still count as offscreen.
    return canvas.viewportContains(app.camera, app.canvasW(), app.canvasH(), nodes, edges);
}

fn patchDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var sn_buf: [MAX_MODULES]graph_io.StableNode = undefined;
    var se_buf: [MAX_EDGES]graph_io.StableEdge = undefined;
    const topo = collectStableTopology(app, &sn_buf, &se_buf);
    const fmt = graph_io.formatStableTopologyInto(buf, topo.nodes, topo.edges, topo.output_id);
    return actions.finishDigestWithTrunc(buf, fmt.len, fmt.truncated);
}

fn collectStableTopology(
    app: *const App,
    sn_buf: *[MAX_MODULES]graph_io.StableNode,
    se_buf: *[MAX_EDGES]graph_io.StableEdge,
) struct { nodes: []graph_io.StableNode, edges: []graph_io.StableEdge, output_id: u64 } {
    var nn: usize = 0;
    var h: Handle = 0;
    while (h < MAX_MODULES) : (h += 1) {
        if (!app.dyn.slotActive(h)) continue;
        const id = nodeIdOf(app, h) orelse continue;
        const pos = app.layout[h];
        sn_buf[nn] = .{
            .id = id,
            .kind = app.dyn.kindOf(h).?,
            .x = pos.x,
            .y = pos.y,
        };
        nn += 1;
    }
    var flat_buf: [MAX_EDGES]Edge = undefined;
    const flat = flat_buf[0..app.buildFlatEdges(&flat_buf)];
    var en: usize = 0;
    for (flat) |e| {
        const sid = nodeIdOf(app, e.src_handle) orelse continue;
        const did = nodeIdOf(app, e.dst_handle) orelse continue;
        se_buf[en] = .{ .src_id = sid, .src_out = e.src_out, .dst_id = did, .dst_in = e.dst_in };
        en += 1;
    }
    std.mem.sort(graph_io.StableNode, sn_buf[0..nn], {}, struct {
        fn less(_: void, a: graph_io.StableNode, b: graph_io.StableNode) bool {
            return a.id.raw() < b.id.raw();
        }
    }.less);
    std.mem.sort(graph_io.StableEdge, se_buf[0..en], {}, struct {
        fn less(_: void, a: graph_io.StableEdge, b: graph_io.StableEdge) bool {
            if (a.src_id.raw() != b.src_id.raw()) return a.src_id.raw() < b.src_id.raw();
            if (a.src_out != b.src_out) return a.src_out < b.src_out;
            if (a.dst_id.raw() != b.dst_id.raw()) return a.dst_id.raw() < b.dst_id.raw();
            return a.dst_in < b.dst_in;
        }
    }.less);

    const view = app.dyn.currentView();
    const output_id: u64 = if (view.output >= 0 and view.output < MAX_MODULES)
        if (nodeIdOf(app, @intCast(view.output))) |oid| oid.raw() else 0
    else
        0;
    return .{ .nodes = sn_buf[0..nn], .edges = se_buf[0..en], .output_id = output_id };
}

fn errDigest(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"error\":\"digest overflow\"}}", .{}) catch buf[0..0];
}

/// menu digest: open/close, item count, enabled/checked masks, pending/last_op/native.
/// `open=<title|none> items=<n> enabled=<hex> checked=<hex> pending=<op|none> last_op=<op|none> native=<0|1>`
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
    const pending = if (app.pending_menu_op) |op| @tagName(op) else "none";
    const last_op = if (app.menu_last_op) |op| @tagName(op) else "none";
    return std.fmt.bufPrint(buf, "open={s} items={d} enabled={X:0>8} checked={X:0>8} pending={s} last_op={s} native={d}", .{
        open, items, enabled_mask, checked_mask, pending, last_op, @intFromBool(app.native_menu_active),
    }) catch buf[0..0];
}

/// snapshot patch: independent of digest's 1024B limit; return all nodes/edges + layout as raw JSON.
fn patchSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var sn_buf: [MAX_MODULES]graph_io.StableNode = undefined;
    var se_buf: [MAX_EDGES]graph_io.StableEdge = undefined;
    const topo = collectStableTopology(app, &sn_buf, &se_buf);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    // Build the topology body without the closing `}`, splice in layout, then close.
    try graph_io.appendStableTopologyJson(&list, allocator, topo.nodes, topo.edges, topo.output_id);
    // Drop the trailing `}` and append layout
    if (list.items.len == 0 or list.items[list.items.len - 1] != '}') return error.OutOfMemory;
    list.items.len -= 1;
    try list.appendSlice(allocator, ",\"layout\":[");
    var node_buf: [MAX_MODULES]NodeGeom = undefined;
    const nodes = node_buf[0..app.buildRawNodes(&node_buf)];
    for (nodes, 0..) |n, i| {
        if (i != 0) try list.append(allocator, ',');
        var tmp: [96]u8 = undefined;
        const piece = try std.fmt.bufPrint(&tmp, "{{\"h\":{d},\"x\":{d:.1},\"y\":{d:.1}}}", .{ n.handle, n.pos.x, n.pos.y });
        try list.appendSlice(allocator, piece);
    }
    try list.appendSlice(allocator, "]}");
    return try list.toOwnedSlice(allocator);
}

// ============================================================================
// harness custom probe: `group` — publish the group ledger (nested topology).
// Pair `digest patch` (flat topology) × `digest group` (membership/expose) to machine-check nesting.
// digest stays within the framework's fixed 1024B; no snapshot (null).
// ============================================================================
fn groupDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var off: usize = 0;
    const head = std.fmt.bufPrint(buf[off..], "{{\"groups\":[", .{}) catch return errDigest(buf);
    off += head.len;
    var first_group = true;
    for (app.ledger.groups, 0..) |g, gid_idx| {
        if (!g.active) continue;
        const gid: group.GroupId = @intCast(gid_idx);
        {
            const sep: []const u8 = if (first_group) "" else ",";
            first_group = false;
            const piece = std.fmt.bufPrint(buf[off..], "{s}{{\"id\":{d},\"kind\":\"{s}\",\"collapsed\":{d},\"grid_rows\":{d},\"members\":[", .{
                sep, gid, @tagName(g.kind), @as(u8, if (g.collapsed) 1 else 0), g.grid_rows,
            }) catch return errDigest(buf);
            off += piece.len;
        }
        var first_member = true;
        var h: Handle = 0;
        while (h < MAX_MODULES) : (h += 1) {
            if (app.ledger.group_of[h] != null and app.ledger.group_of[h].? == gid) {
                const msep: []const u8 = if (first_member) "" else ",";
                first_member = false;
                const piece = std.fmt.bufPrint(buf[off..], "{s}{d}", .{ msep, h }) catch return errDigest(buf);
                off += piece.len;
            }
        }
        {
            const piece = std.fmt.bufPrint(buf[off..], "],\"exposed_in\":[", .{}) catch return errDigest(buf);
            off += piece.len;
        }
        var i: u8 = 0;
        while (i < g.n_in) : (i += 1) {
            const sep: []const u8 = if (i == 0) "" else ",";
            const piece = std.fmt.bufPrint(buf[off..], "{s}[{d},{d}]", .{ sep, g.exposed_in[i].member, g.exposed_in[i].port }) catch return errDigest(buf);
            off += piece.len;
        }
        {
            const piece = std.fmt.bufPrint(buf[off..], "],\"exposed_out\":[", .{}) catch return errDigest(buf);
            off += piece.len;
        }
        i = 0;
        while (i < g.n_out) : (i += 1) {
            const sep: []const u8 = if (i == 0) "" else ",";
            const piece = std.fmt.bufPrint(buf[off..], "{s}[{d},{d}]", .{ sep, g.exposed_out[i].member, g.exposed_out[i].port }) catch return errDigest(buf);
            off += piece.len;
        }
        {
            const piece = std.fmt.bufPrint(buf[off..], "]}}", .{}) catch return errDigest(buf);
            off += piece.len;
        }
    }
    const tail = std.fmt.bufPrint(buf[off..], "]}}", .{}) catch return errDigest(buf);
    off += tail.len;
    return buf[0..off];
}

// ============================================================================
// harness custom probe: `viz` — signal visualisation data.
//   C: master rms/peak (real signal level for the bottom-band scope/spectrogram)
//   A: per-port levels (ports[]. from sigLevel; zero-RT-impact torn read)
//   D: tapped ports and latest-window state (taps[]. wpos / whether applied)
// digest stays within the framework's fixed 1024B. snapshot adds min/max/nz per tap window.
// ============================================================================
fn vizDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    // Reserve 2B for the trailing close ("]}") so the JSON is always closed (never return a broken fragment on overflow).
    // Short keys (h/o/k/w/ap/lv). Sized so 16 taps × worst-case 10-digit wpos still fit in 1024B.
    if (buf.len < 8) return errDigest(buf);
    const cap = buf.len - 2;
    var off: usize = 0;
    {
        const head = std.fmt.bufPrint(buf[0..cap], "{{\"master\":{{\"rms\":{d:.4},\"peak\":{d:.4}}},\"taps\":[", .{ app.master_rms, app.master_peak }) catch return errDigest(buf);
        off += head.len;
    }
    const applied = app.dyn.tapAppliedSeq();
    var first = true;
    for (0..modular.graph_core.TAP_SLOTS) |s| {
        const gp = app.tap_ports[s];
        if (gp < 0) continue;
        const gpu: u32 = @intCast(gp);
        const h: Handle = @intCast(gpu / MAX_OUT);
        const out: u8 = @intCast(gpu % MAX_OUT);
        const applied_ok = applied >= app.tap_slot_seq[s];
        const wpos = app.dyn.tapWpos(s);
        const lvl = app.dyn.sigLevel(h, out);
        const kn = @tagName(portKindOfReal(app, h, out));
        const sep: []const u8 = if (first) "" else ",";
        const piece = std.fmt.bufPrint(buf[off..cap], "{s}{{\"h\":{d},\"o\":{d},\"k\":\"{s}\",\"w\":{d},\"ap\":{d},\"lv\":{d:.4}}}", .{
            sep, h, out, kn, wpos, @as(u8, if (applied_ok) 1 else 0), lvl,
        }) catch break; // If it does not fit, stop there (tail always closes)
        off += piece.len;
        first = false;
    }
    const tail = std.fmt.bufPrint(buf[off..], "]}}", .{}) catch return errDigest(buf); // Reserved, so this must succeed
    off += tail.len;
    return buf[0..off];
}

/// Signal kind of a real handle/out (synthetic handles never arrive — tap_ports hold real global port ids only).
fn portKindOfReal(app: *const App, h: Handle, out: u8) PortKind {
    return app.dyn.outKindOf(h, out) orelse .audio;
}

fn vizSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var dbuf: [1024]u8 = undefined;
    const d = vizDigest(ctx, &dbuf);
    const body = if (d.len > 0 and d[d.len - 1] == '}') d[0 .. d.len - 1] else d;
    var out: [4096]u8 = undefined;
    var off: usize = 0;
    {
        const piece = std.fmt.bufPrint(out[off..], "{s},\"windows\":[", .{body}) catch return allocator.dupe(u8, d);
        off += piece.len;
    }
    var win: [modular.graph_core.TAP_RING]f32 = undefined;
    var first = true;
    for (0..modular.graph_core.TAP_SLOTS) |s| {
        if (app.tap_ports[s] < 0) continue;
        const n = app.dyn.tapWindow(s, &win);
        var mn: f32 = 0;
        var mx: f32 = 0;
        var nz: usize = 0;
        if (n > 0) {
            mn = win[0];
            mx = win[0];
            for (win[0..n]) |v| {
                mn = @min(mn, v);
                mx = @max(mx, v);
                if (v != 0) nz += 1;
            }
        }
        const sep: []const u8 = if (first) "" else ",";
        first = false;
        const piece = std.fmt.bufPrint(out[off..], "{s}{{\"slot\":{d},\"n\":{d},\"min\":{d:.4},\"max\":{d:.4},\"nz\":{d}}}", .{ sep, s, n, mn, mx, nz }) catch break;
        off += piece.len;
    }
    const tail = std.fmt.bufPrint(out[off..], "]}}", .{}) catch "";
    off += tail.len;
    return allocator.dupe(u8, out[0..off]);
}

// ============================================================================
// harness custom actions (patch adopts registerAction.
// Same shape as pixie/synth/modular: a write mouth symmetric to probe(read). Walks the same
// `DynGraph` method sequence as existing UI ops (palette add, drag-wire, Delete)).
//
// Hot-path declaration: every action `run()` is event-only (once per harness `action` command,
// inside main-thread pollGate). Neither per-frame nor per-sample, so the performance rules do not apply.
// `DynGraph.add/removeModule/connect/disconnect/publish` are all non-RT staging→triple-buffer
// publish (the exact same path as existing `commitConnect`/`deleteSelected`/`addByPaletteIndex`). No new
// sync/alloc/lock/panic is added to the RT path (`DynGraph.processBlock`).
//
// Parsers live in `actions.zig` (std only; no App/kit/modular) and are unit-tested. Resolving
// `ModuleKind` names stays in this file, which knows App's concrete types (same split as pixie's `ToolKind`).
//
// Scope: node add/remove/connect/disconnect only.
// Macro (DrumMachine/BassMachine) actions are out of scope here.
// ============================================================================

// ============================================================================
// undo payload capture / CommandAdapter / inverse apply
// Hot path: event only (action dispatch / Cmd+Z). Does not touch the RT path.
// ============================================================================

fn patternToSnap(cmd: PatternCommand) patch_undo.PatternSnap {
    return .{
        .rev = cmd.rev,
        .evolve = cmd.evolve,
        .kick_on = cmd.kick.on,
        .kick_lock = cmd.kick.lock,
        .hat_on = cmd.hat.on,
        .hat_lock = cmd.hat.lock,
        .clap_on = cmd.clap.on,
        .clap_lock = cmd.clap.lock,
        .bass_on = cmd.bass.on,
        .bass_accent = cmd.bass.accent,
        .bass_slide = cmd.bass.slide,
        .bass_deg = cmd.bass.deg,
        .bass_lock = cmd.bass.lock,
        .quantize_bar = cmd.quantize_bar,
    };
}

fn snapToPattern(s: patch_undo.PatternSnap) PatternCommand {
    return .{
        .rev = 0,
        .evolve = s.evolve,
        .kick = .{ .on = s.kick_on, .lock = s.kick_lock },
        .hat = .{ .on = s.hat_on, .lock = s.hat_lock },
        .clap = .{ .on = s.clap_on, .lock = s.clap_lock },
        .bass = .{
            .on = s.bass_on,
            .accent = s.bass_accent,
            .slide = s.bass_slide,
            .deg = s.bass_deg,
            .lock = s.bass_lock,
        },
        .quantize_bar = false,
    };
}

fn songToSnap(song: SongData) patch_undo.SongSnap {
    var out: patch_undo.SongSnap = .{
        .rev = song.rev,
        .phrases_kick = song.phrases_kick,
        .phrases_hat = song.phrases_hat,
        .phrases_clap = song.phrases_clap,
        .row_count = song.row_count,
        .loop = song.loop,
    };
    for (song.phrases_bass, 0..) |ph, i| {
        out.phrases_bass[i] = .{ .on = ph.on, .accent = ph.accent, .slide = ph.slide, .deg = ph.deg };
    }
    for (song.chains, 0..) |ch, i| {
        out.chains[i] = .{ .entries = ch.entries, .len = ch.len };
    }
    for (song.rows, 0..) |row, i| {
        out.rows[i] = .{ .kick = row.kick, .hat = row.hat, .clap = row.clap, .bass = row.bass };
    }
    return out;
}

fn snapToSong(s: patch_undo.SongSnap) SongData {
    var out: SongData = .{
        .rev = 0,
        .phrases_kick = s.phrases_kick,
        .phrases_hat = s.phrases_hat,
        .phrases_clap = s.phrases_clap,
        .row_count = s.row_count,
        .loop = s.loop,
    };
    for (s.phrases_bass, 0..) |ph, i| {
        out.phrases_bass[i] = .{ .on = ph.on, .accent = ph.accent, .slide = ph.slide, .deg = ph.deg };
    }
    for (s.chains, 0..) |ch, i| {
        out.chains[i] = .{ .entries = ch.entries, .len = ch.len };
    }
    for (s.rows, 0..) |row, i| {
        out.rows[i] = .{ .kick = row.kick, .hat = row.hat, .clap = row.clap, .bass = row.bass };
    }
    return out;
}

fn notePatchUndo(app: *App, payload: patch_undo.PatchUndoPayload) void {
    const ref = app.undo_store.push(payload);
    app.cmd_exec.noteUndo(ref);
}

fn notePatternUndoIfChanged(app: *App, before: patch_undo.PatternSnap, after_cmd: PatternCommand) void {
    const after = patternToSnap(after_cmd);
    if (patch_undo.patternContentEql(before, after)) return;
    notePatchUndo(app, .{ .pattern = patch_undo.patternForStore(before) });
}

fn noteSongUndoIfChanged(app: *App, before: patch_undo.SongSnap, after: SongData) void {
    const after_snap = songToSnap(after);
    if (patch_undo.songContentEql(before, after_snap)) return;
    notePatchUndo(app, .{ .song = patch_undo.songForStore(before) });
}

fn restoreNodeId(app: *App, h: Handle, id: NodeId) void {
    std.debug.assert(h < MAX_MODULES);
    std.debug.assert(app.handle_to_id[h] == null);
    app.handle_to_id[h] = id;
    if (id.raw() >= app.next_node_id) app.next_node_id = id.raw() + 1;
    if (app.next_node_id == 0) app.next_node_id = 1;
}

fn kindFromTag(tag: u8) ?modular.ModuleKind {
    inline for (@typeInfo(modular.ModuleKind).@"enum".fields) |f| {
        if (f.value == tag) return @enumFromInt(f.value);
    }
    return null;
}

fn captureNodeParamsInto(app: *App, h: Handle, snap: *patch_undo.NodeSnap) void {
    const kind = app.dyn.kindOf(h) orelse return;
    snap.kind_tag = @intFromEnum(kind);
    const descs = switch (kind) {
        inline else => |ck| modular.descriptors(ck),
    };
    var pn: u8 = 0;
    for (descs) |desc| {
        if (pn >= patch_undo.MAX_UNDO_PARAMS) break;
        const value = modular.getParam(app.dyn, h, desc.name) catch continue;
        snap.params[pn].setName(desc.name);
        switch (value) {
            .scalar => |v| {
                snap.params[pn].value_kind = 0;
                snap.params[pn].value = @bitCast(v);
            },
            .choice => |idx| {
                snap.params[pn].value_kind = 1;
                snap.params[pn].value = @intCast(idx);
            },
        }
        pn += 1;
    }
    snap.param_count = pn;
}

fn applyNodeParamsFrom(app: *App, h: Handle, snap: *const patch_undo.NodeSnap) void {
    var i: u8 = 0;
    while (i < snap.param_count) : (i += 1) {
        const p = snap.params[i];
        const value: modular.ParamValue = switch (p.value_kind) {
            0 => .{ .scalar = @bitCast(p.value) },
            1 => .{ .choice = @intCast(p.value) },
            else => continue,
        };
        modular.setParam(app.dyn, h, p.name(), value) catch {};
    }
}

fn genRoleOfHandle(app: *const App, h: Handle) u8 {
    const roles = app.patch.snapshotGenRoles();
    inline for (@typeInfo(project_io.GenRole).@"enum".fields) |f| {
        const role: project_io.GenRole = @enumFromInt(f.value);
        if (roles.get(role) == h) return @intCast(f.value);
    }
    return 0xFF;
}

fn captureIncidentEdges(app: *const App, h: Handle, out: *[patch_undo.MAX_UNDO_EDGES]patch_undo.EdgeSnap) u8 {
    var flat_buf: [MAX_EDGES]Edge = undefined;
    const flat = flat_buf[0..app.buildFlatEdges(&flat_buf)];
    var n: u8 = 0;
    for (flat) |e| {
        if (e.src_handle != h and e.dst_handle != h) continue;
        if (n >= patch_undo.MAX_UNDO_EDGES) break;
        const sid = nodeIdOf(app, e.src_handle) orelse continue;
        const did = nodeIdOf(app, e.dst_handle) orelse continue;
        out[n] = .{ .src_id = sid.raw(), .src_out = e.src_out, .dst_id = did.raw(), .dst_in = e.dst_in };
        n += 1;
    }
    return n;
}

fn edgeSnapForInput(app: *const App, dst_h: Handle, dst_in: usize) ?patch_undo.EdgeSnap {
    if (dst_in > 255) return null;
    const e = edgeForInput(app, dst_h, @intCast(dst_in)) orelse return null;
    const sid = nodeIdOf(app, e.src_handle) orelse return null;
    const did = nodeIdOf(app, e.dst_handle) orelse return null;
    return .{ .src_id = sid.raw(), .src_out = e.src_out, .dst_id = did.raw(), .dst_in = e.dst_in };
}

fn reconnectEdgeSnap(app: *App, edge: patch_undo.EdgeSnap) void {
    const src = handleOfNodeId(app, NodeId.fromRaw(edge.src_id)) orelse return;
    const dst = handleOfNodeId(app, NodeId.fromRaw(edge.dst_id)) orelse return;
    app.dyn.disconnect(dst, edge.dst_in);
    app.dyn.connect(src, edge.src_out, dst, edge.dst_in) catch {};
}

fn removeNodeByHandleForUndo(app: *App, h: Handle) void {
    if (app.ledger.group_of[h] != null) app.ledger.unassign(h);
    purgeParamOverrides(app, h);
    // Drop multi-selection before remove so a reused handle cannot inherit a stale multi select.
    selection.set(&app.multi_selected, h, false);
    app.dyn.removeModule(h);
    clearNodeIdMapping(app, h);
}

fn patchNodeExists(ctx: *anyopaque, id: u64) bool {
    const app: *App = @ptrCast(@alignCast(ctx));
    return handleOfNodeId(app, NodeId.fromRaw(id)) != null;
}

fn patchCanUndo(ctx: *anyopaque, rec: *const platform.command.CommandRecord) bool {
    const app: *App = @ptrCast(@alignCast(ctx));
    const ref = rec.undo_ref orelse return false;
    const entry = app.undo_store.get(ref) orelse return false;
    return patch_undo.canUndoPayload(entry.payload, .{
        .ctx = app,
        .exists = patchNodeExists,
        .free_handles = app.dyn.freeHandleCount(),
    });
}

fn patchSummarize(ctx: *anyopaque, rec: *const platform.command.CommandRecord, buf: []u8) []const u8 {
    _ = ctx;
    const n = @min(buf.len, rec.name().len);
    @memcpy(buf[0..n], rec.name()[0..n]);
    // sanitize non-printable
    for (buf[0..n]) |*c| {
        if (c.* < 0x20 or c.* > 0x7E) c.* = '?';
    }
    return buf[0..n];
}

fn patchApplyUndo(ctx: *anyopaque, rec: *const platform.command.CommandRecord) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    const ref = rec.undo_ref orelse return;
    const entry = app.undo_store.get(ref) orelse return;
    switch (entry.payload) {
        .pattern => |s| {
            _ = publishPatternCommand(app, snapToPattern(s));
        },
        .song => |s| {
            app.song = snapToSong(s);
            publishSong(app, app.patch);
        },
        .seed => |s| {
            app.notation_seed = s.notation_seed;
            app.notation_counter = s.notation_counter;
            app.patch.requestSeed(s.base_seed);
        },
        .mute => |s| {
            if (s.track < std.meta.fields(MuteTrack).len) {
                const name = @tagName(@as(MuteTrack, @enumFromInt(s.track)));
                setMuteAndPublish(app, name, s.was_muted) catch {};
            }
        },
        .param => |s| {
            // mode=0 is the old Transport alias (removed). Ignore it; restore NodeId form only.
            if (s.mode != 1) return;
            const h = handleOfNodeId(app, NodeId.fromRaw(s.node_id)) orelse return;
            const raw: f32 = if (s.value_kind == 0) @bitCast(s.value_bits) else @floatFromInt(s.value_bits);
            queueParamOverride(app, h, s.name(), raw) catch {};
        },
        .add_node => |s| {
            const h = handleOfNodeId(app, NodeId.fromRaw(s.id)) orelse return;
            const clear_selected = if (app.selected) |it| refsHandleForRemoval(app, it, h) else false;
            const clear_hover = if (app.hover) |it| refsHandleForRemoval(app, it, h) else false;
            removeNodeByHandleForUndo(app, h);
            app.dyn.publish() catch {};
            app.refreshAllExposed();
            if (clear_selected) app.selected = null;
            if (clear_hover) app.hover = null;
        },
        .remove_node => |s| {
            applyUndoRemoveNode(app, s);
        },
        .connect => |s| {
            const dst = handleOfNodeId(app, NodeId.fromRaw(s.new_edge.dst_id)) orelse return;
            app.dyn.disconnect(dst, s.new_edge.dst_in);
            var ri: u8 = 0;
            while (ri < s.replaced_count) : (ri += 1) reconnectEdgeSnap(app, s.replaced[ri]);
            app.dyn.publish() catch {};
            app.refreshAllExposed();
        },
        .disconnect => |s| {
            reconnectEdgeSnap(app, s.edge);
            app.dyn.publish() catch {};
            app.refreshAllExposed();
        },
        .move_node => |s| {
            const h = handleOfNodeId(app, NodeId.fromRaw(s.id)) orelse return;
            app.layout[h] = .{ .x = s.x, .y = s.y };
        },
        .add_macro => |s| {
            applyUndoAddMacro(app, s);
        },
        .remove_macro => |s| {
            applyUndoRemoveMacro(app, s);
        },
    }
}

fn applyUndoRemoveNode(app: *App, s: patch_undo.RemoveNodeSnap) void {
    waitGraphReclaim(app, 1) catch return;
    const kind = kindFromTag(s.node.kind_tag) orelse return;
    const h = blk: {
        if (kind == .step_seq and s.node.gen_role != 0xFF) {
            // bass_seq role uses bass init
            const role: project_io.GenRole = @enumFromInt(s.node.gen_role);
            if (role == .bass_seq) break :blk app.dyn.add(.step_seq, stepSeqBassInit) catch return;
        }
        break :blk addNodeByKind(app, kind) catch return;
    };
    app.layout[h] = .{ .x = s.node.x, .y = s.node.y };
    restoreNodeId(app, h, NodeId.fromRaw(s.node.id));
    applyNodeParamsFrom(app, h, &s.node);
    if (s.group_id != 0xFF and s.group_id < group.MAX_GROUPS and app.ledger.groups[s.group_id].active) {
        app.ledger.assign(h, s.group_id);
    }
    if (s.node.gen_role != 0xFF) {
        var roles = app.patch.snapshotGenRoles();
        roles.set(@enumFromInt(s.node.gen_role), h);
        app.patch.applyGenRoles(roles);
    }
    var ei: u8 = 0;
    while (ei < s.edge_count) : (ei += 1) reconnectEdgeSnap(app, s.edges[ei]);
    app.dyn.publish() catch {};
    app.refreshAllExposed();
}

fn applyUndoAddMacro(app: *App, s: patch_undo.AddMacroSnap) void {
    var mi: u8 = 0;
    while (mi < s.member_count) : (mi += 1) {
        const h = handleOfNodeId(app, NodeId.fromRaw(s.members[mi])) orelse continue;
        removeNodeByHandleForUndo(app, h);
    }
    if (s.group_id != 0xFF and s.group_id < group.MAX_GROUPS) {
        selection.set(&app.multi_selected, group.handleOfGroup(s.group_id), false);
        app.ledger.free(s.group_id);
    }
    app.dyn.publish() catch {};
    app.refreshAllExposed();
    app.selected = null;
    app.hover = null;
}

fn applyUndoRemoveMacro(app: *App, s: patch_undo.RemoveMacroSnap) void {
    waitGraphReclaim(app, s.member_count) catch return;
    const mk: group.MacroKind = @enumFromInt(s.kind);
    const gid = app.ledger.alloc() orelse return;
    app.ledger.groups[gid].kind = mk;
    app.ledger.groups[gid].pos = .{ .x = s.x, .y = s.y };
    app.ledger.groups[gid].collapsed = s.collapsed;
    app.ledger.groups[gid].grid_rows = s.grid_rows;
    var mi: u8 = 0;
    while (mi < s.member_count) : (mi += 1) {
        const ns = s.members[mi];
        const kind = kindFromTag(ns.kind_tag) orelse continue;
        const h = blk: {
            if (kind == .step_seq and ns.gen_role != 0xFF) {
                const role: project_io.GenRole = @enumFromInt(ns.gen_role);
                if (role == .bass_seq) break :blk app.dyn.add(.step_seq, stepSeqBassInit) catch continue;
            }
            break :blk addNodeByKind(app, kind) catch continue;
        };
        app.layout[h] = .{ .x = ns.x, .y = ns.y };
        restoreNodeId(app, h, NodeId.fromRaw(ns.id));
        applyNodeParamsFrom(app, h, &ns);
        app.ledger.assign(h, gid);
        if (ns.gen_role != 0xFF) {
            var roles = app.patch.snapshotGenRoles();
            roles.set(@enumFromInt(ns.gen_role), h);
            app.patch.applyGenRoles(roles);
        }
    }
    var ei: u8 = 0;
    while (ei < s.edge_count) : (ei += 1) reconnectEdgeSnap(app, s.edges[ei]);
    app.dyn.publish() catch {};
    app.refreshAllExposed();
}

fn doUndo(app: *App) void {
    var buf: [128]u8 = undefined;
    if (platform.netsyncActive()) {
        _ = platform.routeAction("undo", "", &buf) catch |err| {
            std.debug.print("patch: undo failed: {s}\n", .{@errorName(err)});
        };
    } else {
        _ = app.cmd_exec.undoOne(.local_user, &buf) catch |err| {
            std.debug.print("patch: undoOne failed: {s}\n", .{@errorName(err)});
        };
    }
    resyncUiAfterHistoryChange(app);
}

fn doRedo(app: *App) void {
    var buf: [128]u8 = undefined;
    if (platform.netsyncActive()) {
        _ = platform.routeAction("redo", "", &buf) catch |err| {
            std.debug.print("patch: redo failed: {s}\n", .{@errorName(err)});
        };
    } else {
        _ = app.cmd_exec.redoOne(.local_user, &buf) catch |err| {
            std.debug.print("patch: redoOne failed: {s}\n", .{@errorName(err)});
        };
    }
    resyncUiAfterHistoryChange(app);
}

fn actionUndo(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    if (args.len != 0) return error.UnexpectedArgs;
    const app = actionApp(ctx);
    const outcome = try app.cmd_exec.undoOne(.local_user, buf);
    resyncUiAfterHistoryChange(app);
    return outcome.message;
}

fn actionRedo(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    if (args.len != 0) return error.UnexpectedArgs;
    const app = actionApp(ctx);
    const outcome = try app.cmd_exec.redoOne(.local_user, buf);
    resyncUiAfterHistoryChange(app);
    return outcome.message;
}

/// After undo/redo, re-align UI-only refs (selection/hover/inspector/param edit) with the document.
/// State not included in the graph snapshot. Event only.
fn resyncUiAfterHistoryChange(app: *App) void {
    if (app.selected) |it| {
        if (!itemStillValid(app, it)) app.selected = null;
    }
    if (app.hover) |it| {
        if (!itemStillValid(app, it)) app.hover = null;
    }
    // syncInspectorTarget / refreshAllExposed also run on the per-frame path, but
    // probe/digest may read in the same frame right after undo, so re-sync immediately here.
    app.syncInspectorTarget();
    for (&app.param_edits) |*state| {
        if (state.key.invalid()) continue;
        if (state.key.handle >= MAX_MODULES) continue;
        if (!app.dyn.slotActive(@intCast(state.key.handle))) state.* = .{};
    }
    app.refreshAllExposed();
}

fn itemStillValid(app: *const App, it: Item) bool {
    return switch (it) {
        .node => |h| h < MAX_MODULES and app.dyn.slotActive(h),
        .group => |gid| gid < group.MAX_GROUPS and app.ledger.groups[gid].active,
        .port => |pr| blk: {
            const real = app.ledger.resolvePort(pr) orelse break :blk false;
            break :blk real.handle < MAX_MODULES and app.dyn.slotActive(real.handle);
        },
        .cable => |cr| blk: {
            if (cr.dst_handle >= MAX_MODULES or !app.dyn.slotActive(cr.dst_handle)) break :blk false;
            break :blk edgeForInput(app, cr.dst_handle, cr.dst_in) != null;
        },
    };
}

fn actionApp(ctx: *anyopaque) *App {
    return @ptrCast(@alignCast(ctx));
}

fn paramDescFor(kind: modular.ModuleKind, name: []const u8) ?modular.ParamDesc {
    switch (kind) {
        inline else => |comptime_kind| {
            for (modular.descriptors(comptime_kind)) |desc| {
                if (std.mem.eql(u8, desc.name, name)) return desc;
            }
        },
    }
    return null;
}

fn canonicalParamName(app: *const App, h: Handle, name: []const u8) ?[]const u8 {
    const kind = app.dyn.kindOf(h) orelse return null;
    const descs = switch (kind) {
        inline else => |comptime_kind| modular.descriptors(comptime_kind),
    };
    return param_view.canonicalDescriptorName(descs, name);
}

fn snapshotParamCallback(ctx: *anyopaque, handle: modular.dyn.Handle, name: []const u8) ?param_view.ParamSnapshot {
    const app: *App = @ptrCast(@alignCast(ctx));
    return app.snapshotParam(handle, name);
}

fn displayInspectorValue(ctx: *anyopaque, key: param_view.FieldKey, snapshot: param_view.ParamSnapshot) modular.ParamValue {
    const app: *App = @ptrCast(@alignCast(ctx));
    return param_view.displayValue(snapshot, app.findEditState(key), key);
}

/// Convert a scalar/choice UI value to a descriptor ParamValue and publish the cumulative table.
fn queueParamOverride(app: *App, handle: usize, name: []const u8, raw: f32) !void {
    if (handle >= MAX_MODULES) return error.InvalidHandle;
    const h: Handle = @intCast(handle);
    if (!app.dyn.slotActive(h)) return error.InvalidHandle;
    const kind = app.dyn.kindOf(h) orelse return error.InvalidHandle;
    const desc = paramDescFor(kind, name) orelse return error.UnknownParam;
    const value: modular.ParamValue = switch (desc.kind) {
        .scalar => .{ .scalar = raw },
        .choice => |choice| blk: {
            if (!std.math.isFinite(raw) or raw < 0 or @trunc(raw) != raw) return error.WrongValueKind;
            const index: usize = @intFromFloat(raw);
            if (index >= choice.options.len) return error.OutOfRange;
            break :blk .{ .choice = index };
        },
    };

    var free: ?usize = null;
    var found: ?usize = null;
    for (app.param_batch.entries, 0..) |entry, i| {
        if (!entry.touched) {
            if (free == null) free = i;
        } else if (entry.handle == h and std.mem.eql(u8, entry.name, desc.name)) {
            found = i;
            break;
        }
    }
    const index = found orelse free orelse return error.ParamTableFull;
    app.param_batch.entries[index] = .{ .handle = h, .name = desc.name, .value = value, .touched = true };
    app.param_batch.revision += 1;
    app.patch.publishParamBatch(app.param_batch);
    app.editState(param_view.fieldKey(h, desc.name)).begin(param_view.fieldKey(h, desc.name), value);
}

fn inspectorChanged(ctx: *anyopaque, handle: modular.dyn.Handle, name: []const u8, value: modular.ParamValue) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    // Capture before only at drag start (pass to set_param on release)
    if (app.slider_drag_before == null) {
        var s = patch_undo.ParamValueSnap{
            .mode = 1,
            .node_id = (nodeIdOf(app, handle) orelse NodeId.fromRaw(0)).raw(),
        };
        s.setName(name);
        const cur = modular.getParam(app.dyn, handle, name) catch null;
        if (cur) |c| {
            switch (c) {
                .scalar => |v| {
                    s.value_kind = 0;
                    s.value_bits = @bitCast(v);
                },
                .choice => |idx| {
                    s.value_kind = 1;
                    s.value_bits = @intCast(idx);
                },
            }
            app.slider_drag_before = s;
        }
    }
    const raw: f32 = switch (value) {
        .scalar => |v| v,
        .choice => |idx| @floatFromInt(idx),
    };
    queueParamOverride(app, handle, name, raw) catch {};
    app.editState(param_view.fieldKey(handle, name)).dragging = true;
}

fn purgeParamOverrides(app: *App, handle: ?Handle) void {
    var changed = false;
    for (&app.param_batch.entries) |*entry| {
        if (!entry.touched) continue;
        if (handle == null or entry.handle == handle.?) {
            entry.* = .{};
            changed = true;
        }
    }
    if (changed) {
        app.param_batch.revision += 1;
        app.patch.publishParamBatch(app.param_batch);
    }
}

fn toHandle(v: usize) error{InvalidHandle}!Handle {
    if (v >= MAX_MODULES) return error.InvalidHandle;
    return @intCast(v);
}

const NodeId = graph_io.NodeId;

fn allocNodeId(app: *App, h: Handle) NodeId {
    std.debug.assert(h < MAX_MODULES);
    std.debug.assert(app.handle_to_id[h] == null);
    const raw = app.next_node_id;
    app.next_node_id += 1;
    const id = NodeId.fromRaw(raw);
    app.handle_to_id[h] = id;
    return id;
}

fn clearNodeIdMapping(app: *App, h: Handle) void {
    if (h < MAX_MODULES) app.handle_to_id[h] = null;
}

fn clearAllNodeIdMappings(app: *App) void {
    @memset(&app.handle_to_id, null);
}

fn nodeIdOf(app: *const App, h: Handle) ?NodeId {
    if (h >= MAX_MODULES) return null;
    return app.handle_to_id[h];
}

fn handleOfNodeId(app: *const App, id: NodeId) ?Handle {
    if (id == .invalid) return null;
    var h: Handle = 0;
    while (h < MAX_MODULES) : (h += 1) {
        if (app.handle_to_id[h]) |hid| {
            if (hid == id) return h;
        }
    }
    return null;
}

/// Initial graph: deterministic ids in ascending active-handle order.
fn assignInitialNodeIds(app: *App) void {
    clearAllNodeIdMappings(app);
    app.next_node_id = 1;
    var h: Handle = 0;
    while (h < MAX_MODULES) : (h += 1) {
        if (!app.dyn.slotActive(h)) continue;
        _ = allocNodeId(app, h);
    }
}

fn restoreNodeIdsFromRefs(app: *App, mapping: []const ?Handle, refs: []const project_io.NodeIdRef, next: u64) void {
    clearAllNodeIdMappings(app);
    var max_id: u64 = 0;
    for (refs) |r| {
        if (r.saved_handle >= MAX_MODULES) continue;
        const nh = mapping[r.saved_handle] orelse continue;
        app.handle_to_id[nh] = r.id;
        if (r.id.raw() > max_id) max_id = r.id.raw();
    }
    app.next_node_id = @max(next, max_id + 1);
    if (app.next_node_id == 0) app.next_node_id = 1;
}

/// NodeRef → runtime Handle. Reject bare handle / group synthetic / stale id during netsync.
fn resolveNodeRef(app: *const App, ref: actions.NodeRef, require_id_during_netsync: bool) !Handle {
    if (require_id_during_netsync and actions.nodeRefRejectDuringNetsync(ref, platform.netsyncActive())) {
        platform.setActionErrorDetail("id_required", "use #<id> from digest patch during netsync");
        return error.IdRequired;
    }
    switch (ref) {
        .id => |raw| {
            const id = NodeId.fromRaw(raw);
            const h = handleOfNodeId(app, id) orelse {
                platform.setActionErrorDetail("unknown_node_id", "stale or unknown #<id>");
                return error.UnknownNodeId;
            };
            if (!app.dyn.slotActive(h)) {
                platform.setActionErrorDetail("unknown_node_id", "stale or unknown #<id>");
                return error.UnknownNodeId;
            }
            return h;
        },
        .handle => |hv| {
            if (hv >= group.GROUP_HANDLE_BASE) {
                platform.setActionErrorDetail("group_handle_not_wireable", "use member #<id> not group synthetic handle");
                return error.GroupHandleNotWireable;
            }
            const h = try toHandle(hv);
            if (!app.dyn.slotActive(h)) return error.InvalidHandle;
            return h;
        },
    }
}

fn nodeRefToId(app: *const App, ref: actions.NodeRef, forbid_handle: bool) !u64 {
    if (forbid_handle and ref == .handle) {
        platform.setActionErrorDetail("id_required", "use #<id> from digest patch during netsync");
        return error.IdRequired;
    }
    const h = try resolveNodeRef(app, ref, false);
    const id = nodeIdOf(app, h) orelse {
        platform.setActionErrorDetail("unknown_node_id", "node has no stable id");
        return error.UnknownNodeId;
    };
    return id.raw();
}

fn actionSelectNode(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const h = try toHandle(try actions.parseSelectNode(args));
    if (!app.dyn.slotActive(h)) return error.InvalidHandle;
    app.selected = .{ .node = h };
    app.observed_field = observedFieldForNode(app, h) orelse .{};
    app.hover = null;
    app.drag = .none;
    return "ok";
}

fn observedFieldForNode(app: *const App, h: Handle) ?param_view.FieldKey {
    const kind = app.dyn.kindOf(h) orelse return null;
    const descs = switch (kind) {
        inline else => |comptime_kind| modular.descriptors(comptime_kind),
    };
    // select_node follow-up also uses the descriptor's static name, not a slice from action args.
    const d = param_view.primaryDescriptor(descs) orelse return null;
    return param_view.fieldKey(h, d.name);
}

/// Shared bass step_seq defaults for palette / wire (same as solo `addByPaletteIndex`).
/// Drum `step_seq` uses `ModuleKind` defaults (`.{}` including `.kind=.drum`) matching the palette.
const stepSeqBassInit = modular.StepSeq{
    .kind = .bass,
    .on_mask = 0,
    .accent_mask = 0,
    .slide_mask = 0,
    .scale = .minor_pentatonic,
    .octaves = 2,
};

/// `modular.ModuleKind` → comptime dispatch into `dyn.add(k, .{})`. Same "runtime enum → comptime call"
/// pattern as `addByPaletteIndex`'s `inline for` (`switch (kind) { inline else
/// => |k| ... }` generates a comptime-specialised branch per tag; `k` inside the branch is comptime).
/// Used by both `actionAddNode` (kind name) and `load_graph` (typed kind from `graph_io.decodeGraph`).
fn addNodeByKind(app: *App, kind: modular.ModuleKind) !Handle {
    return switch (kind) {
        inline else => |k| app.dyn.add(k, .{}),
    };
}

/// Kind name (`ModuleKind` tag, or wire alias `step_seq_bass`) → add.
fn addNodeByKindName(app: *App, name: []const u8) !Handle {
    if (std.mem.eql(u8, name, "step_seq_bass")) {
        return app.dyn.add(.step_seq, stepSeqBassInit);
    }
    const kind = std.meta.stringToEnum(modular.ModuleKind, name) orelse return error.UnknownKind;
    return addNodeByKind(app, kind);
}

fn actionAddNode(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    const p = try actions.parseAddNode(args);
    const h = try addNodeByKindName(app, p.kind);
    errdefer {
        selection.set(&app.multi_selected, h, false);
        app.dyn.removeModule(h);
    }
    app.layout[h] = .{ .x = p.x, .y = p.y };
    try app.dyn.publish();
    // Redo is a normal re-exec: every peer agrees via monotonic allocNodeId (total COMMIT order).
    const id = allocNodeId(app, h);
    const kind = app.dyn.kindOf(h).?;
    notePatchUndo(app, .{ .add_node = .{
        .id = id.raw(),
        .kind_tag = @intFromEnum(kind),
        .x = p.x,
        .y = p.y,
    } });
    return std.fmt.bufPrint(buf, "ok id=#{d}", .{id.raw()}) catch "ok";
}

/// Whether item refers to the about-to-be-removed handle `h` (detect selected/hover that would go stale).
/// Call **before** `removeModule(h)` (src-side cable checks need the pre-remove flat edges).
///   - node: direct match.
///   - port: `PortRef.handle` may be synthetic on a collapsed group, so `resolvePort` to the
///     real member before comparing. Unresolvable (already stale) ports are dropped conservatively (true).
///   - cable: `CableRef` only holds dst, so besides dst match, pull the pre-remove real edge via `edgeForInput`
///     and also detect cables whose src is h (removeModule clears that connection → would go stale).
///   - group: a single-node remove does not delete the group, so keep (false).
/// `deleteSelected`'s node branch unconditionally nulls when selected==target, but actions can remove an
/// arbitrary handle, so narrow by reference check.
fn refsHandleForRemoval(app: *const App, it: Item, h: Handle) bool {
    return switch (it) {
        .node => |sh| sh == h,
        .port => |pr| blk: {
            const real = app.ledger.resolvePort(pr) orelse break :blk true;
            break :blk real.handle == h;
        },
        .cable => |cr| blk: {
            if (cr.dst_handle == h) break :blk true;
            if (edgeForInput(app, cr.dst_handle, cr.dst_in)) |e| break :blk e.src_handle == h;
            break :blk false;
        },
        .group => false,
    };
}

fn actionRemoveNode(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const ref = try actions.parseNodeRef(args);
    const h = try resolveNodeRef(app, ref, true);
    const id = nodeIdOf(app, h) orelse return error.UnknownNodeId;
    const kind = app.dyn.kindOf(h) orelse return error.InvalidHandle;
    var snap: patch_undo.RemoveNodeSnap = .{};
    snap.node.id = id.raw();
    snap.node.kind_tag = @intFromEnum(kind);
    snap.node.x = app.layout[h].x;
    snap.node.y = app.layout[h].y;
    snap.node.gen_role = genRoleOfHandle(app, h);
    captureNodeParamsInto(app, h, &snap.node);
    snap.edge_count = captureIncidentEdges(app, h, &snap.edges);
    if (app.ledger.group_of[h]) |gid| {
        snap.group_id = gid;
        snap.group_kind = @intFromEnum(app.ledger.groups[gid].kind);
    }
    const clear_selected = if (app.selected) |it| refsHandleForRemoval(app, it, h) else false;
    const clear_hover = if (app.hover) |it| refsHandleForRemoval(app, it, h) else false;
    if (app.ledger.group_of[h] != null) app.ledger.unassign(h);
    purgeParamOverrides(app, h);
    // Drop multi-selection before remove so a reused handle cannot inherit a stale multi select.
    selection.set(&app.multi_selected, h, false);
    app.dyn.removeModule(h);
    clearNodeIdMapping(app, h);
    try app.dyn.publish();
    app.refreshAllExposed();
    if (clear_selected) app.selected = null;
    if (clear_hover) app.hover = null;
    notePatchUndo(app, .{ .remove_node = snap });
    return "ok";
}

/// Same "validate then break" order as `commitConnect` (check active/kind match first → only if OK,
/// replace any existing connection on the destination) so an invalid request does not break an existing one.
fn actionConnect(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const p = try actions.parseConnect(args);
    const src_h = try resolveNodeRef(app, p.src, true);
    const dst_h = try resolveNodeRef(app, p.dst, true);
    if (!app.dyn.slotActive(src_h) or !app.dyn.slotActive(dst_h)) return error.InvalidHandle;
    const sk = app.dyn.outKindOf(src_h, p.src_out) orelse return error.InvalidPort;
    const dk = app.dyn.inKindOf(dst_h, p.dst_in) orelse return error.InvalidPort;
    if (sk != dk) return error.PortKindMismatch;
    var conn: patch_undo.ConnectSnap = .{};
    if (edgeSnapForInput(app, dst_h, p.dst_in)) |old| {
        conn.replaced[0] = old;
        conn.replaced_count = 1;
    }
    if (p.detach_dst) |dref| {
        const din = p.detach_in orelse return error.InvalidArguments;
        const dh = try resolveNodeRef(app, dref, true);
        if (!(dh == dst_h and din == p.dst_in)) {
            if (edgeSnapForInput(app, dh, din)) |det| {
                if (conn.replaced_count < conn.replaced.len) {
                    conn.replaced[conn.replaced_count] = det;
                    conn.replaced_count += 1;
                }
            }
            app.dyn.disconnect(dh, din);
        }
    }
    const src_id = nodeIdOf(app, src_h) orelse return error.UnknownNodeId;
    const dst_id = nodeIdOf(app, dst_h) orelse return error.UnknownNodeId;
    conn.new_edge = .{
        .src_id = src_id.raw(),
        .src_out = @intCast(p.src_out),
        .dst_id = dst_id.raw(),
        .dst_in = @intCast(p.dst_in),
    };
    app.dyn.disconnect(dst_h, @intCast(p.dst_in));
    try app.dyn.connect(src_h, @intCast(p.src_out), dst_h, @intCast(p.dst_in));
    try app.dyn.publish();
    app.refreshAllExposed();
    notePatchUndo(app, .{ .connect = conn });
    return "ok";
}

fn actionDisconnect(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const p = try actions.parseDisconnect(args);
    const dst_h = try resolveNodeRef(app, p.dst, true);
    if (!app.dyn.slotActive(dst_h)) return error.InvalidHandle;
    if (app.dyn.inKindOf(dst_h, p.dst_in) == null) return error.InvalidPort;
    const old = edgeSnapForInput(app, dst_h, p.dst_in);
    app.dyn.disconnect(dst_h, p.dst_in);
    try app.dyn.publish();
    app.refreshAllExposed();
    if (old) |e| notePatchUndo(app, .{ .disconnect = .{ .edge = e } });
    return "ok";
}

fn actionMoveNode(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const p = try actions.parseMoveNode(args);
    const h = try resolveNodeRef(app, p.ref, true);
    const id = nodeIdOf(app, h) orelse return error.UnknownNodeId;
    const ox = app.layout[h].x;
    const oy = app.layout[h].y;
    app.layout[h] = .{ .x = p.x, .y = p.y };
    if (ox != p.x or oy != p.y) {
        notePatchUndo(app, .{ .move_node = .{ .id = id.raw(), .x = ox, .y = oy } });
    }
    return "ok";
}

fn actionAddMacro(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    const p = try actions.parseAddMacro(args);
    const mk = std.meta.stringToEnum(group.MacroKind, p.kind) orelse return error.UnknownKind;
    var out_ids: [patch_undo.MAX_MACRO_MEMBERS]u64 = undefined;
    var out_n: u8 = 0;
    try addMacroAtWorld(app, mk, .{ .x = p.x, .y = p.y }, &out_ids, &out_n);
    const gid = blk: {
        if (app.selected) |it| switch (it) {
            .group => |g| break :blk g,
            else => {},
        };
        return error.MacroAddFailed;
    };
    var snap: patch_undo.AddMacroSnap = .{
        .kind = patch_undo.macroKindTag(mk),
        .x = p.x,
        .y = p.y,
        .group_id = gid,
        .member_count = out_n,
    };
    @memcpy(snap.members[0..out_n], out_ids[0..out_n]);
    notePatchUndo(app, .{ .add_macro = snap });

    var off: usize = 0;
    const head = std.fmt.bufPrint(buf[off..], "ok kind={s} members=", .{@tagName(mk)}) catch return "ok";
    off += head.len;
    var first = true;
    var mi: u8 = 0;
    while (mi < snap.member_count) : (mi += 1) {
        const piece = std.fmt.bufPrint(buf[off..], "{s}#{d}", .{ if (first) "" else ",", snap.members[mi] }) catch break;
        off += piece.len;
        first = false;
    }
    return buf[0..off];
}

fn actionRemoveMacro(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const p = try actions.parseRemoveMacro(args);
    var handles: [actions.MAX_REMOVE_MACRO_MEMBERS]Handle = undefined;
    var n: usize = 0;
    var gid: ?group.GroupId = null;
    var i: usize = 0;
    while (i < p.count) : (i += 1) {
        const h = try resolveNodeRef(app, p.members[i], true);
        const g = app.ledger.group_of[h] orelse return error.NotInMacro;
        if (gid) |want| {
            if (g != want) return error.MixedMacroMembers;
        } else gid = g;
        handles[n] = h;
        n += 1;
    }
    const group_id = gid orelse return error.NotInMacro;
    const gstate = app.ledger.groups[group_id];
    var snap: patch_undo.RemoveMacroSnap = .{
        .kind = @intFromEnum(gstate.kind),
        .x = gstate.pos.x,
        .y = gstate.pos.y,
        .collapsed = gstate.collapsed,
        .grid_rows = gstate.grid_rows,
        .group_id = group_id,
    };
    // Collect edges involving any member
    var flat_buf: [MAX_EDGES]Edge = undefined;
    const flat = flat_buf[0..app.buildFlatEdges(&flat_buf)];
    var member_set = [_]bool{false} ** MAX_MODULES;
    for (handles[0..n]) |h| member_set[h] = true;
    for (flat) |e| {
        if (!member_set[e.src_handle] and !member_set[e.dst_handle]) continue;
        if (snap.edge_count >= patch_undo.MAX_UNDO_EDGES) break;
        const sid = nodeIdOf(app, e.src_handle) orelse continue;
        const did = nodeIdOf(app, e.dst_handle) orelse continue;
        snap.edges[snap.edge_count] = .{ .src_id = sid.raw(), .src_out = e.src_out, .dst_id = did.raw(), .dst_in = e.dst_in };
        snap.edge_count += 1;
    }
    for (handles[0..n]) |h| {
        if (snap.member_count >= patch_undo.MAX_MACRO_MEMBERS) break;
        const id = nodeIdOf(app, h) orelse continue;
        const kind = app.dyn.kindOf(h) orelse continue;
        var ns: patch_undo.NodeSnap = .{
            .id = id.raw(),
            .kind_tag = @intFromEnum(kind),
            .x = app.layout[h].x,
            .y = app.layout[h].y,
            .gen_role = genRoleOfHandle(app, h),
        };
        captureNodeParamsInto(app, h, &ns);
        snap.members[snap.member_count] = ns;
        snap.member_count += 1;
    }
    for (handles[0..n]) |h| {
        purgeParamOverrides(app, h);
        app.ledger.unassign(h);
        selection.set(&app.multi_selected, h, false);
        app.dyn.removeModule(h);
        clearNodeIdMapping(app, h);
    }
    selection.set(&app.multi_selected, group.handleOfGroup(group_id), false);
    app.ledger.free(group_id);
    try app.dyn.publish();
    app.refreshAllExposed();
    app.selected = null;
    app.hover = null;
    notePatchUndo(app, .{ .remove_macro = snap });
    return "ok";
}

// ============================================================================
// save_graph / load_graph (KNGN-compatible aliases; legacy PTCG still loads).
//
// Hot-path declaration: save/load are event only. Do not touch the RT path.
// save_graph = full KNGN save (same content as save_project).
// load_graph = apply graph/Ledger/GENR from KNGN. PTCG also loads (empty Ledger reset; GENR disabled).
// ============================================================================

fn collectNodesEdges(app: *App, node_buf: *[MAX_MODULES]project_io.NodeEntry, edge_buf: *[MAX_EDGES]project_io.EdgeEntry) struct { nodes: []project_io.NodeEntry, edges: []project_io.EdgeEntry } {
    var nn: usize = 0;
    var h: Handle = 0;
    while (h < MAX_MODULES) : (h += 1) {
        if (!app.dyn.slotActive(h)) continue;
        const pos = app.layout[h];
        node_buf[nn] = .{ .handle = h, .kind = app.dyn.kindOf(h).?, .x = pos.x, .y = pos.y };
        nn += 1;
    }
    var flat_buf: [MAX_EDGES]Edge = undefined;
    const flat = flat_buf[0..app.buildFlatEdges(&flat_buf)];
    for (flat, 0..) |e, i| {
        edge_buf[i] = .{ .src_handle = e.src_handle, .src_out = e.src_out, .dst_handle = e.dst_handle, .dst_in = e.dst_in };
    }
    return .{ .nodes = node_buf[0..nn], .edges = edge_buf[0..flat.len] };
}

/// Collect active-node descriptor source fields for NPRM (do not persist instant).
/// `param_bufs` is per-node parameter-value scratch (names point at descriptor static strings).
fn collectNodeParams(
    app: *App,
    record_buf: *[MAX_MODULES]project_io.NodeParamRecord,
    param_bufs: *[MAX_MODULES][project_io.MAX_PARAMS_PER_NODE]project_io.NodeParam,
) []project_io.NodeParamRecord {
    var rn: usize = 0;
    var h: Handle = 0;
    while (h < MAX_MODULES) : (h += 1) {
        if (!app.dyn.slotActive(h)) continue;
        const kind = app.dyn.kindOf(h).?;
        const descs = switch (kind) {
            inline else => |comptime_kind| modular.descriptors(comptime_kind),
        };
        var pn: usize = 0;
        for (descs) |desc| {
            std.debug.assert(pn < project_io.MAX_PARAMS_PER_NODE);
            const value = modular.getParam(app.dyn, h, desc.name) catch continue;
            param_bufs[rn][pn] = switch (value) {
                .scalar => |v| .{
                    .name = desc.name,
                    .value_kind = project_io.VALUE_KIND_SCALAR,
                    .value = @bitCast(v),
                },
                .choice => |idx| .{
                    .name = desc.name,
                    .value_kind = project_io.VALUE_KIND_CHOICE,
                    .value = @intCast(idx),
                },
            };
            pn += 1;
        }
        record_buf[rn] = .{
            .saved_handle = h,
            .params = param_bufs[rn][0..pn],
        };
        rn += 1;
    }
    return record_buf[0..rn];
}

fn buildEncodeInput(
    app: *App,
    node_buf: *[MAX_MODULES]project_io.NodeEntry,
    edge_buf: *[MAX_EDGES]project_io.EdgeEntry,
    nprm_buf: *[MAX_MODULES]project_io.NodeParamRecord,
    param_bufs: *[MAX_MODULES][project_io.MAX_PARAMS_PER_NODE]project_io.NodeParam,
    nref_buf: *[MAX_MODULES]project_io.NodeIdRef,
) project_io.EncodeInput {
    const patch = app.patch;
    const cmd = stateToCommand(patch.snapshotState());
    const st = patch.snapshotState();
    const ne = collectNodesEdges(app, node_buf, edge_buf);
    const nprm = collectNodeParams(app, nprm_buf, param_bufs);
    var rn: usize = 0;
    for (ne.nodes) |n| {
        const id = nodeIdOf(app, n.handle) orelse NodeId.fromRaw(0);
        nref_buf[rn] = .{ .saved_handle = n.handle, .id = id };
        rn += 1;
    }
    return .{
        .pattern = patternToPayload(cmd),
        .seed = .{
            .base_seed = st.base_seed,
            .notation_seed = app.notation_seed,
            .notation_counter = app.notation_counter,
        },
        .song = songToPayload(app.song),
        .nodes = ne.nodes,
        .edges = ne.edges,
        .node_params = nprm,
        .node_id_refs = nref_buf[0..rn],
        .next_node_id = app.next_node_id,
        .ledger = &app.ledger,
        .genr = patch.snapshotGenRoles(),
    };
}

fn actionSaveProjectFile(app: *App, path: []const u8) !void {
    var node_buf: [MAX_MODULES]project_io.NodeEntry = undefined;
    var edge_buf: [MAX_EDGES]project_io.EdgeEntry = undefined;
    var nprm_buf: [MAX_MODULES]project_io.NodeParamRecord = undefined;
    var param_bufs: [MAX_MODULES][project_io.MAX_PARAMS_PER_NODE]project_io.NodeParam = undefined;
    var nref_buf: [MAX_MODULES]project_io.NodeIdRef = undefined;
    const input = buildEncodeInput(app, &node_buf, &edge_buf, &nprm_buf, &param_bufs, &nref_buf);
    try project_io.save(app.io, path, Params, app.params, input, std.heap.c_allocator);
}

/// Capacity under replace semantics: count slots about to be cleared as free too.
fn ensureReplaceCapacity(app: *App, nodes: []const project_io.NodeEntry) !void {
    const free = app.dyn.freeHandleCount();
    const active = app.dyn.activeCount();
    if (nodes.len > free + active) return error.TooManyNodesForCapacity;
    inline for (@typeInfo(modular.ModuleKind).@"enum".fields) |kf| {
        const k: modular.ModuleKind = @enumFromInt(kf.value);
        var need: usize = 0;
        for (nodes) |n| {
            if (n.kind == k) need += 1;
        }
        var active_k: usize = 0;
        var h: Handle = 0;
        while (h < MAX_MODULES) : (h += 1) {
            if (app.dyn.slotActive(h) and app.dyn.kindOf(h) == k) active_k += 1;
        }
        if (need > app.dyn.poolFreeCount(k) + active_k) return error.TooManyNodesForCapacity;
    }
}

/// After clearGraph + publish, wait (bounded) for RT's processBlock to advance grace.
fn waitGraphReclaim(app: *App, need_nodes: usize) !void {
    var spins: usize = 0;
    while (app.dyn.freeHandleCount() < need_nodes and spins < 200_000) : (spins += 1) {
        std.atomic.spinLoopHint();
    }
    if (app.dyn.freeHandleCount() < need_nodes) return error.TooManyNodesForCapacity;
}

const GraphApplyResult = struct { nodes_restored: usize, edges_restored: usize };

fn applyGraphReplace(
    app: *App,
    nodes: []const project_io.NodeEntry,
    edges: []const project_io.EdgeEntry,
    ledger_src: ?*const group.Ledger,
    genr_src: ?project_io.GenRoleHandles,
    node_params: ?[]const project_io.NodeParamRecord,
    node_id_refs: ?[]const project_io.NodeIdRef,
    next_node_id: ?u64,
) !GraphApplyResult {
    // Reject bad NPRM before clearGraph (do not destroy the graph)
    if (node_params) |records| {
        try project_io.validateNodeParams(nodes, records);
    }
    if (node_id_refs) |refs| {
        const next = next_node_id orelse return error.CorruptNidm;
        try project_io.validateNodeIdRefs(nodes, refs, next);
    }

    try ensureReplaceCapacity(app, nodes);
    clearGraph(app);
    try app.dyn.publish();
    try waitGraphReclaim(app, nodes.len);

    var mapping = [_]?Handle{null} ** MAX_MODULES;
    var nodes_restored: usize = 0;
    const genr_old: ?project_io.GenRoleHandles = genr_src;
    for (nodes) |n| {
        if (n.handle >= MAX_MODULES) continue;
        const nh = blk: {
            if (n.kind == .step_seq) {
                if (genr_old) |g| {
                    if (n.handle == g.get(.bass_seq)) {
                        break :blk app.dyn.add(.step_seq, .{ .kind = .bass }) catch continue;
                    }
                    if (n.handle == g.get(.kick_seq) or n.handle == g.get(.hat_seq) or n.handle == g.get(.clap_seq)) {
                        break :blk app.dyn.add(.step_seq, .{ .kind = .drum }) catch continue;
                    }
                }
            }
            break :blk addNodeByKind(app, n.kind) catch continue;
        };
        app.layout[nh] = .{ .x = n.x, .y = n.y };
        mapping[n.handle] = nh;
        nodes_restored += 1;
    }

    // NPRM: apply source fields after node rebuild, before the final publish (avoid a 1-block type-default transient)
    if (node_params) |records| {
        for (records) |rec| {
            if (rec.saved_handle >= MAX_MODULES) continue;
            const nh = mapping[rec.saved_handle] orelse continue;
            for (rec.params) |p| {
                const value: modular.ParamValue = switch (p.value_kind) {
                    project_io.VALUE_KIND_SCALAR => .{ .scalar = @bitCast(p.value) },
                    project_io.VALUE_KIND_CHOICE => .{ .choice = @intCast(p.value) },
                    else => continue,
                };
                modular.setParam(app.dyn, nh, p.name, value) catch |err| {
                    // Unreachable after validate. Do not leave the graph empty.
                    std.log.warn("applyGraphReplace: setParam skipped h={d} name={s} err={s}", .{ nh, p.name, @errorName(err) });
                    continue;
                };
            }
        }
    }

    var edges_restored: usize = 0;
    for (edges) |e| {
        if (e.src_handle >= MAX_MODULES or e.dst_handle >= MAX_MODULES) continue;
        const src = mapping[e.src_handle] orelse continue;
        const dst = mapping[e.dst_handle] orelse continue;
        app.dyn.connect(src, e.src_out, dst, e.dst_in) catch continue;
        edges_restored += 1;
    }
    try app.dyn.publish();

    if (ledger_src) |src| {
        app.ledger = try project_io.remapLedger(src, &mapping);
        // Right after restore: deriveExposed for consistency (values are unchanged if graph+membership match)
        app.refreshAllExposed();
    } else {
        app.ledger = .{};
    }

    if (genr_src) |g| {
        app.patch.applyGenRoles(project_io.remapGenr(g, &mapping));
    } else {
        app.patch.invalidateGenRoles();
    }

    // stable NodeId: restore from NREF if present, else deterministic fallback
    if (node_id_refs) |refs| {
        restoreNodeIdsFromRefs(app, &mapping, refs, next_node_id orelse 1);
    } else {
        var ids_buf: [MAX_MODULES]NodeId = undefined;
        const next = graph_io.assignFallbackNodeIds(nodes, ids_buf[0..nodes.len]);
        var refs_buf: [MAX_MODULES]project_io.NodeIdRef = undefined;
        for (nodes, 0..) |n, i| {
            refs_buf[i] = .{ .saved_handle = n.handle, .id = ids_buf[i] };
        }
        restoreNodeIdsFromRefs(app, &mapping, refs_buf[0..nodes.len], next);
    }

    // master output is outside KNGN chunks; restore staging output from the GENR output role
    // (without it, load is silent. Legacy PTCG has no GENR so does not setOutput).
    if (app.patch.output_h != project_io.INVALID_ROLE_HANDLE and app.dyn.isActive(app.patch.output_h)) {
        app.dyn.setOutput(app.patch.output_h);
        try app.dyn.publish();
    }

    return .{ .nodes_restored = nodes_restored, .edges_restored = edges_restored };
}

/// Publish params + pattern.
/// `quantize_bar=true`: required when the same load also applies seed (so seed's anchor reset does not wipe the pattern;
/// at the bar boundary, seed→pending_bar_cmd last-wins). KNGN/MPRJ load / SYNC.
/// `quantize_bar=false`: pattern-only (load_pattern). Apply immediately (as before).
/// Callers pass `loaded.apply_seed_song` to mean "quantize only when pattern and seed share a format".
/// The combo `apply_params_pattern=true` and `apply_seed_song=false` does not exist in current formats.
fn applyParamsPattern(app: *App, params: Params, pattern: pattern_io.PatternPayload, quantize_bar: bool) void {
    app.params = params;
    publishControls(app.patch, app.params);
    var cmd = payloadToPatternCommand(0, pattern);
    cmd.quantize_bar = quantize_bar;
    const published = publishPatternCommand(app, cmd);
    // Put the load's quantized pattern into last_quantized_cmd so a stale mini-notation is not reused.
    if (quantize_bar) app.last_quantized_cmd = published;
}

fn applySeedSong(app: *App, seed: project_io.SeedPayload, song: project_io.SongPayload) void {
    app.song = payloadToSong(app.song.rev +% 1, song);
    app.patch.controls.song_db.publish(app.song);
    app.notation_seed = seed.notation_seed;
    app.notation_counter = seed.notation_counter;
    app.patch.requestSeed(seed.base_seed);
}

fn actionSaveGraph(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const path = try actions.parsePath(args);
    try actionSaveProjectFile(app, path);
    return "ok";
}

/// Erase the whole existing graph (load's "replace" semantics. Also reset ledger/selection/hover).
fn clearGraph(app: *App) void {
    purgeParamOverrides(app, null);
    var h: Handle = 0;
    while (h < MAX_MODULES) : (h += 1) {
        if (!app.dyn.slotActive(h)) continue;
        if (app.ledger.group_of[h] != null) app.ledger.unassign(h);
        selection.set(&app.multi_selected, h, false);
        app.dyn.removeModule(h);
    }
    app.ledger = .{};
    clearAllNodeIdMappings(app);
    // next_node_id is restored by load/SYNC (clear alone must not break monotonicity)
    selection.clear(&app.multi_selected);
    app.selected = null;
    app.hover = null;
    app.drag = .none;
}

fn actionLoadGraph(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    const path = try actions.parsePath(args);
    const gpa = std.heap.c_allocator;
    var decoded = try project_io.load(app.io, gpa, path, Params);
    defer decoded.deinit(gpa);

    if (!decoded.apply_graph) return error.UnsupportedFormat;

    const ledger_ptr: ?*const group.Ledger = if (decoded.apply_ledger and decoded.format == .kngn) &decoded.ledger else null;
    const genr_opt: ?project_io.GenRoleHandles = if (decoded.apply_genr and decoded.format == .kngn) decoded.genr else null;
    const nprm_opt: ?[]const project_io.NodeParamRecord = if (decoded.apply_node_params) decoded.node_params else null;
    // PTCG: apply_ledger/genr are true but empty/INVALID (decodeFromPtcg)
    const result = if (decoded.format == .ptcg)
        try applyGraphReplace(app, decoded.nodes, decoded.edges, null, null, null, decoded.node_id_refs, decoded.next_node_id)
    else
        try applyGraphReplace(app, decoded.nodes, decoded.edges, ledger_ptr, genr_opt, nprm_opt, decoded.node_id_refs, decoded.next_node_id);

    return std.fmt.bufPrint(buf, "nodes={d}/{d} edges={d}/{d}", .{
        result.nodes_restored, decoded.nodes.len, result.edges_restored, decoded.edges.len,
    }) catch "ok";
}

/// Register graph relay actions in bulk. `.relay` + canonicalize. Not undoable.
/// network_policy's single source is `gen_actions.PATCH_NETWORK_POLICIES`.
fn registerPatchActions(app: *App) void {
    platform.registerAction(.{ .name = "select_node", .ctx = app, .run = actionSelectNode, .network_policy = patchPolicy("select_node") });
    platform.registerAction(.{ .name = "observe_param", .ctx = app, .run = actionObserveParam, .network_policy = patchPolicy("observe_param") });
    // Panel visible toggle (local_only. Not recorded in recipe/CommandLog → meta ring).
    platform.registerAction(.{
        .name = "panel_toggle",
        .ctx = app,
        .run = actionPanelToggle,
        .network_policy = .local_only,
        .args = &.{.{ .name = "name", .kind = "string" }},
        .desc = "toggle panel visible (inspector|history)",
    });
    platform.registerAction(.{
        .name = "add_node",
        .ctx = app,
        .run = recordedGraphAction("add_node"),
        .network_policy = patchPolicy("add_node"),
        .canonicalize = canonicalizeAddNode,
    });
    platform.registerAction(.{
        .name = "remove_node",
        .ctx = app,
        .run = recordedGraphAction("remove_node"),
        .network_policy = patchPolicy("remove_node"),
        .canonicalize = canonicalizeRemoveNode,
    });
    platform.registerAction(.{
        .name = "connect",
        .ctx = app,
        .run = recordedGraphAction("connect"),
        .network_policy = patchPolicy("connect"),
        .canonicalize = canonicalizeConnect,
    });
    platform.registerAction(.{
        .name = "disconnect",
        .ctx = app,
        .run = recordedGraphAction("disconnect"),
        .network_policy = patchPolicy("disconnect"),
        .canonicalize = canonicalizeDisconnect,
    });
    platform.registerAction(.{
        .name = "move_node",
        .ctx = app,
        .run = recordedGraphAction("move_node"),
        .network_policy = patchPolicy("move_node"),
        .canonicalize = canonicalizeMoveNode,
    });
    platform.registerAction(.{
        .name = "add_macro",
        .ctx = app,
        .run = recordedGraphAction("add_macro"),
        .network_policy = patchPolicy("add_macro"),
        .canonicalize = canonicalizeAddMacro,
    });
    platform.registerAction(.{
        .name = "remove_macro",
        .ctx = app,
        .run = recordedGraphAction("remove_macro"),
        .network_policy = patchPolicy("remove_macro"),
        .canonicalize = canonicalizeRemoveMacro,
    });
    platform.registerAction(.{
        .name = "save_graph",
        .ctx = app,
        .run = actionSaveGraph,
        .network_policy = patchPolicy("save_graph"),
        .desc = "save integrated KNGN project (alias of save_project)",
    });
    platform.registerAction(.{
        .name = "load_graph",
        .ctx = app,
        .run = actionLoadGraph,
        .network_policy = patchPolicy("load_graph"),
        .desc = "load graph/Ledger/GENR from KNGN (or legacy PTCG); reject while synced",
    });
    // Full re-layout of the display graph (local_only; no args; no undo/history)
    platform.registerAction(.{
        .name = "auto_layout",
        .ctx = app,
        .run = actionAutoLayout,
        .network_policy = .local_only,
        .args = &.{},
        .desc = "Sugiyama layered layout of display graph (real nodes + collapsed boxes)",
    });
    // Topology-ignoring grid of selected display nodes only (local_only; no args)
    platform.registerAction(.{
        .name = "auto_layout_selected",
        .ctx = app,
        .run = actionAutoLayoutSelected,
        .network_policy = .local_only,
        .args = &.{},
        .desc = "simple grid pack of selected display nodes (topology ignored)",
    });
}

/// Apply a Sugiyama-style layered layout to the display graph (shared body for the action and startup placement).
/// Synthetic handles write only groups[gid].pos; App.layout[] gets real handles only.
/// Hot path: event only / init only. No camera fit / undo.
fn runAutoLayout(app: *App) void {
    var node_buf: [MAX_MODULES + group.MAX_GROUPS]NodeGeom = undefined;
    const n_nodes = app.buildNodes(&node_buf);

    var dedge_buf: [MAX_EDGES]group.DisplayEdge = undefined;
    const n_dedges = app.buildDisplayEdges(&dedge_buf);
    var edge_buf: [MAX_EDGES]Edge = undefined;
    var ei: usize = 0;
    while (ei < n_dedges) : (ei += 1) {
        edge_buf[ei] = dedge_buf[ei].visual;
    }

    // order key: real nodes use view.order index. collapsed groups use the min order key of their members.
    const view = app.dyn.currentView();
    var handle_order: [MAX_MODULES]?u32 = [_]?u32{null} ** MAX_MODULES;
    var k: usize = 0;
    while (k < view.node_count) : (k += 1) {
        handle_order[view.order[k]] = @intCast(k);
    }

    var order_keys: [MAX_MODULES + group.MAX_GROUPS]u32 = undefined;
    var i: usize = 0;
    while (i < n_nodes) : (i += 1) {
        const ng = node_buf[i];
        if (group.groupIdFromHandle(ng.handle)) |gid| {
            var min_key: u32 = std.math.maxInt(u32);
            var found = false;
            for (app.ledger.group_of, 0..) |go, h| {
                if (go == null or go.? != gid) continue;
                if (handle_order[h]) |ok| {
                    if (!found or ok < min_key) {
                        min_key = ok;
                        found = true;
                    }
                }
            }
            order_keys[i] = if (found) min_key else std.math.maxInt(u32);
        } else {
            order_keys[i] = handle_order[ng.handle] orelse std.math.maxInt(u32);
        }
    }

    // origin_y that clears the palette band (same shape as clampMacroPos: paletteBottom + margin → world Y)
    const margin: f32 = 16;
    const top_limit_local = (paletteBottom(app) - app.canvas_rect.y) + margin;
    const origin_y = app.camera.screenToWorld(.{ .x = 0, .y = top_limit_local }).y;

    layout_mod.apply(
        node_buf[0..n_nodes],
        edge_buf[0..n_dedges],
        order_keys[0..n_nodes],
        app.layout[0..],
        &app.ledger,
        origin_y,
    );
}

/// `auto_layout`: thin wrapper around runAutoLayout. No camera fit / undo.
fn actionAutoLayout(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = args;
    _ = buf;
    runAutoLayout(actionApp(ctx));
    return "ok";
}

/// Prefer multi_selected; if empty, take App.selected .node/.group as a single target.
/// Write only handles that exist in the display nodes into out; return the count (.port/.cable/null → 0).
fn collectSelectedLayoutTargets(app: *const App, nodes: []const NodeGeom, out: []Handle) usize {
    var n: usize = 0;
    if (!selection.empty(&app.multi_selected)) {
        for (nodes) |ng| {
            if (!selection.contains(&app.multi_selected, ng.handle)) continue;
            if (n >= out.len) break;
            out[n] = ng.handle;
            n += 1;
        }
        return n;
    }
    if (app.selected) |it| switch (it) {
        .node => |h| {
            if (findNode(nodes, h) == null) return 0;
            if (out.len == 0) return 0;
            out[0] = h;
            return 1;
        },
        .group => |gid| {
            const h = group.handleOfGroup(gid);
            if (findNode(nodes, h) == null) return 0;
            if (out.len == 0) return 0;
            out[0] = h;
            return 1;
        },
        .port, .cable => return 0,
    };
    return 0;
}

/// Simple grid of selected display nodes only. 0 → empty_selection; 1 → successful no-op.
/// Hot path: action call only. No camera fit / undo / header follow.
fn runAutoLayoutSelected(app: *App) anyerror!void {
    var node_buf: [MAX_MODULES + group.MAX_GROUPS]NodeGeom = undefined;
    const n_nodes = app.buildNodes(&node_buf);
    var targets: [MAX_MODULES + group.MAX_GROUPS]Handle = undefined;
    const n_targets = collectSelectedLayoutTargets(app, node_buf[0..n_nodes], targets[0..]);
    if (n_targets == 0) {
        platform.setActionErrorDetail("empty_selection", "select one or more display nodes");
        return error.EmptySelection;
    }
    if (n_targets == 1) return;
    layout_mod.applySelectedGrid(
        node_buf[0..n_nodes],
        targets[0..n_targets],
        app.layout[0..],
        &app.ledger,
    );
}

/// `auto_layout_selected`: thin wrapper around runAutoLayoutSelected.
fn actionAutoLayoutSelected(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = args;
    _ = buf;
    try runAutoLayoutSelected(actionApp(ctx));
    return "ok";
}

fn toPlatformPolicy(tag: gen_actions.NetworkPolicyTag) platform.NetworkPolicy {
    return switch (tag) {
        .relay => .relay,
        .local_only => .local_only,
        .reject_when_synced => .reject_when_synced,
    };
}

fn patchPolicy(comptime name: []const u8) platform.NetworkPolicy {
    // Resolve gen_actions.policyOf at comptime (a missing table entry is a build error).
    const tag = comptime gen_actions.policyOf(name) orelse @compileError("missing PATCH_NETWORK_POLICIES entry: " ++ name);
    return toPlatformPolicy(tag);
}

/// CommandLog recording wrapper for graph relay actions.
///
/// Persistence contract: args after `platform.routeAction` canonicalize (NodeId as `#<id>`) go
/// straight into `CommandRecord.args`. `recordedGraphAction` does not re-canonicalize
/// (remote COMMIT already receives host-canonicalised wire args).
///
/// Fresh-replay assumption: NodeId allocation is the startup ascending-active-handle initial assign plus
/// monotonic increments after successful publish (never reused after delete), so the same op sequence reproduces the same `#id`.
fn recordedGraphAction(comptime name: []const u8) *const fn (*anyopaque, []const u8, []u8) anyerror![]const u8 {
    return &struct {
        fn run(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
            const app: *App = @ptrCast(@alignCast(ctx));
            const res = try app.cmd_exec.executeAction(name, args, .{
                .actor = .local_user,
                .record_policy = .record,
            }, buf);
            return res.output;
        }
    }.run;
}

fn canonicalizeAddNode(ctx: *anyopaque, args: []const u8, scratch: []u8) anyerror![]const u8 {
    _ = ctx;
    const p = try actions.parseAddNode(args);
    return actions.formatAddNode(scratch, p.kind, p.x, p.y) catch return error.ArgsTooLong;
}

fn canonicalizeRemoveNode(ctx: *anyopaque, args: []const u8, scratch: []u8) anyerror![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const forbid = !actions.allowNodeCanonFill(platform.netsyncActive());
    const ref = try actions.parseNodeRef(args);
    const id = try nodeRefToId(app, ref, forbid);
    return actions.formatNodeId(scratch, id) catch return error.ArgsTooLong;
}

fn canonicalizeMoveNode(ctx: *anyopaque, args: []const u8, scratch: []u8) anyerror![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const forbid = !actions.allowNodeCanonFill(platform.netsyncActive());
    const p = try actions.parseMoveNode(args);
    const id = try nodeRefToId(app, p.ref, forbid);
    return actions.formatMoveNode(scratch, id, p.x, p.y) catch return error.ArgsTooLong;
}

fn canonicalizeDisconnect(ctx: *anyopaque, args: []const u8, scratch: []u8) anyerror![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const forbid = !actions.allowNodeCanonFill(platform.netsyncActive());
    const p = try actions.parseDisconnect(args);
    const id = try nodeRefToId(app, p.dst, forbid);
    return actions.formatDisconnect(scratch, id, p.dst_in) catch return error.ArgsTooLong;
}

fn canonicalizeConnect(ctx: *anyopaque, args: []const u8, scratch: []u8) anyerror![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const forbid = !actions.allowNodeCanonFill(platform.netsyncActive());
    const p = try actions.parseConnect(args);
    const src_id = try nodeRefToId(app, p.src, forbid);
    const dst_id = try nodeRefToId(app, p.dst, forbid);
    if (p.detach_dst) |dref| {
        const din = p.detach_in orelse return error.InvalidArguments;
        const did = try nodeRefToId(app, dref, forbid);
        return actions.formatConnectWithDetach(scratch, src_id, p.src_out, dst_id, p.dst_in, did, din) catch return error.ArgsTooLong;
    }
    return actions.formatConnect(scratch, src_id, p.src_out, dst_id, p.dst_in) catch return error.ArgsTooLong;
}

fn canonicalizeAddMacro(ctx: *anyopaque, args: []const u8, scratch: []u8) anyerror![]const u8 {
    _ = ctx;
    const p = try actions.parseAddMacro(args);
    return actions.formatAddMacro(scratch, p.kind, p.x, p.y) catch return error.ArgsTooLong;
}

fn canonicalizeRemoveMacro(ctx: *anyopaque, args: []const u8, scratch: []u8) anyerror![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const forbid = !actions.allowNodeCanonFill(platform.netsyncActive());
    const p = try actions.parseRemoveMacro(args);
    var off: usize = 0;
    var i: usize = 0;
    while (i < p.count) : (i += 1) {
        const id = try nodeRefToId(app, p.members[i], forbid);
        const piece = if (i == 0)
            std.fmt.bufPrint(scratch[off..], "#{d}", .{id}) catch return error.ArgsTooLong
        else
            std.fmt.bufPrint(scratch[off..], " #{d}", .{id}) catch return error.ArgsTooLong;
        off += piece.len;
    }
    return scratch[0..off];
}

fn actionObserveParam(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    var it = std.mem.tokenizeAny(u8, args, " \t");
    const raw_handle = it.next() orelse return error.InvalidArguments;
    const name = it.next() orelse return error.InvalidArguments;
    if (it.next() != null) return error.InvalidArguments;
    const h = try toHandle(try std.fmt.parseInt(usize, raw_handle, 10));
    if (!app.dyn.slotActive(h)) return error.InvalidHandle;
    const canonical_name = canonicalParamName(app, h, name) orelse {
        platform.setActionErrorDetail("unknown_param", "use a descriptor name for the selected handle");
        return error.UnknownParam;
    };
    app.observed_field = param_view.fieldKey(h, canonical_name);
    return std.fmt.bufPrint(buf, "observed_h={d} observed_name={s}", .{ h, canonical_name }) catch "ok";
}

fn integratedStateSyncExport(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app = actionApp(ctx);
    var node_buf: [MAX_MODULES]project_io.NodeEntry = undefined;
    var edge_buf: [MAX_EDGES]project_io.EdgeEntry = undefined;
    var nprm_buf: [MAX_MODULES]project_io.NodeParamRecord = undefined;
    var param_bufs: [MAX_MODULES][project_io.MAX_PARAMS_PER_NODE]project_io.NodeParam = undefined;
    var nref_buf: [MAX_MODULES]project_io.NodeIdRef = undefined;
    const input = buildEncodeInput(app, &node_buf, &edge_buf, &nprm_buf, &param_bufs, &nref_buf);
    return project_io.encode(Params, allocator, app.params, input);
}

fn integratedStateSyncImport(ctx: *anyopaque, bytes: []const u8) anyerror!void {
    const app = actionApp(ctx);
    const gpa = std.heap.c_allocator;
    var decoded = try project_io.decode(Params, gpa, bytes);
    defer decoded.deinit(gpa);
    if (decoded.format != .kngn) return error.UnsupportedFormat;

    // Destructive apply only after validation completes (capacity is inside applyGraphReplace)
    const nprm_opt: ?[]const project_io.NodeParamRecord = if (decoded.apply_node_params) decoded.node_params else null;
    _ = try applyGraphReplace(app, decoded.nodes, decoded.edges, &decoded.ledger, decoded.genr, nprm_opt, decoded.node_id_refs, decoded.next_node_id);
    // SYNC, like KNGN load, stages pattern as pending (quantize_bar) → seed last-wins.
    applyParamsPattern(app, decoded.params, decoded.pattern, true);
    applySeedSong(app, decoded.seed, decoded.song);
}

fn registerIntegratedStateSync(app: *App) void {
    platform.registerStateSync(.{
        .ctx = app,
        .export_fn = integratedStateSyncExport,
        .import_fn = integratedStateSyncImport,
    });
}
fn selectedParamDigest(app: *const App, buf: []u8) []const u8 {
    const h = if (app.selected) |item| switch (item) {
        .node => |node_h| node_h,
        else => return std.fmt.bufPrint(buf, "\"selected\":null,", .{}) catch buf[0..0],
    } else return std.fmt.bufPrint(buf, "\"selected\":null,", .{}) catch buf[0..0];
    const kind = app.dyn.kindOf(h) orelse return std.fmt.bufPrint(buf, "\"selected\":null,", .{}) catch buf[0..0];
    var off: usize = 0;
    const head = std.fmt.bufPrint(buf[off..], "\"selected\":{{\"h\":{d},\"kind\":\"{s}\",\"params\":{{", .{ h, @tagName(kind) }) catch return buf[0..0];
    off += head.len;
    var first = true;
    const descs = switch (kind) {
        inline else => |comptime_kind| modular.descriptors(comptime_kind),
    };
    for (descs) |desc| {
        const value = modular.getParam(app.dyn, h, desc.name) catch continue;
        const sep: []const u8 = if (first) "" else ",";
        const piece = switch (value) {
            .scalar => |v| std.fmt.bufPrint(buf[off..], "{s}\"{s}\":{d:.3}", .{ sep, desc.name, v }) catch return buf[0..0],
            .choice => |v| std.fmt.bufPrint(buf[off..], "{s}\"{s}\":{d}", .{ sep, desc.name, v }) catch return buf[0..0],
        };
        off += piece.len;
        first = false;
    }
    const tail = std.fmt.bufPrint(buf[off..], "}},", .{}) catch return buf[0..0];
    return buf[0 .. off + tail.len];
}

fn defaultObservedField(app: *const App) param_view.FieldKey {
    // Master VCF cutoff (default observe for the Inspector path).
    const name = param_view.canonicalDescriptorName(modular.descriptors(.vcf), "cutoff") orelse "cutoff";
    return param_view.fieldKey(app.patch.master_vcf_h, name);
}

fn observedField(app: *const App) param_view.FieldKey {
    return if (app.observed_field.invalid()) defaultObservedField(app) else app.observed_field;
}

fn scalarParamValue(value: modular.ParamValue) ?f32 {
    return switch (value) {
        .scalar => |v| v,
        .choice => null,
    };
}

fn editScalarValue(app: *const App, key: param_view.FieldKey) ?f32 {
    if (app.findEditState(key)) |state| {
        if (state.pending) |pending| return scalarParamValue(pending);
    }
    return null;
}

fn observedInspectorValue(app: *const App, key: param_view.FieldKey) ?f32 {
    const target_h = app.inspectorParamHandle() orelse return null;
    if (!param_view.sameField(key, param_view.fieldKey(target_h, key.name))) return null;
    const snapshot = modular.getParamSnapshot(app.dyn, target_h, key.name) catch return null;
    const field = scalarParamValue(snapshot.field) orelse return null;
    return editScalarValue(app, key) orelse field;
}

fn hasOverride(app: *const App, key: param_view.FieldKey) bool {
    for (app.param_batch.entries) |entry| {
        if (entry.touched and param_view.sameFieldParts(key, entry.handle, entry.name)) return true;
    }
    return false;
}

fn optionalF32Text(buf: []u8, value: ?f32) []const u8 {
    if (value) |v| return std.fmt.bufPrint(buf, "{d:.2}", .{v}) catch "none";
    return "none";
}

fn panelDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *const App = @ptrCast(@alignCast(ctx));
    const host = app.panel_host;
    // Removed Transport / bottom-slot keys. History + Inspector only.
    return std.fmt.bufPrint(buf, "inspector_visible={d} inspector_open={d} inspector_state={s} panels_hidden={d} history_visible={d} history_open={d} history_count={d} history_latest_seq={d} history_scroll_y={d} left_extent={d} right_extent={d} bottom_extent={d} center_x={d} center_y={d} center_w={d} center_h={d} canvas_w={d} canvas_h={d}", .{
        @intFromBool(app.panelVisible("Inspector")),
        @intFromBool(app.panelOpen("Inspector")),
        app.panelStateName("Inspector"),
        @intFromBool(app.panels_hidden),
        @intFromBool(app.panelVisible("History")),
        @intFromBool(app.panelOpen("History")),
        app.historyCount(),
        app.historyLatestSeq(),
        @as(i32, @intFromFloat(app.history_scroll.y)),
        host.slotExtent(.left),
        host.slotExtent(.right),
        host.slotExtent(.bottom),
        @as(i32, @intFromFloat(app.canvas_rect.x)),
        @as(i32, @intFromFloat(app.canvas_rect.y)),
        @as(i32, @intFromFloat(app.canvas_rect.w)),
        @as(i32, @intFromFloat(app.canvas_rect.h)),
        @as(i32, @intFromFloat(app.canvasW())),
        @as(i32, @intFromFloat(app.canvasH())),
    }) catch return buf[0..0];
}

// ── PanelHost body callbacks + Preferences adapter ────────

fn actorLabel(actor: platform.command.ActorId, buf: []u8) []const u8 {
    return switch (actor) {
        .local_user => "user",
        .local_agent => "agent",
        .system => "system",
        .peer => |n| std.fmt.bufPrint(buf, "peer#{d}", .{n}) catch "peer",
    };
}

/// Single source for recipeEntriesFromLog and history badges. Touch only here when adding excluded names.
fn isRecipeEligibleCommandName(name: []const u8) bool {
    // Internal snapshot. Not included in semantic recipes.
    if (std.mem.eql(u8, name, "pattern_state")) return false;
    return true;
}

fn normalHistoryBadge(name: []const u8) []const u8 {
    return if (isRecipeEligibleCommandName(name)) "[recipe]" else "[internal]";
}

fn formatHistoryCmdLine(rec: *const platform.command.CommandRecord, buf: []u8) []const u8 {
    var actor_buf: [24]u8 = undefined;
    const actor = actorLabel(rec.actor, &actor_buf);
    return switch (rec.kind) {
        .normal => blk: {
            const badge = if (rec.reverted)
                "[undone]"
            else
                normalHistoryBadge(rec.name());
            const args = rec.args();
            if (rec.redo_of) |src| {
                if (args.len == 0) {
                    break :blk std.fmt.bufPrint(buf, "#{d} {s} {s} redo_of=#{d} {s}", .{ rec.seq, actor, rec.name(), src, badge }) catch "#?";
                }
                const max_args = @min(args.len, 40);
                break :blk std.fmt.bufPrint(buf, "#{d} {s} {s} {s} redo_of=#{d} {s}", .{ rec.seq, actor, rec.name(), args[0..max_args], src, badge }) catch "#?";
            }
            if (args.len == 0) {
                break :blk std.fmt.bufPrint(buf, "#{d} {s} {s} {s}", .{ rec.seq, actor, rec.name(), badge }) catch "#?";
            }
            const max_args = @min(args.len, 48);
            break :blk std.fmt.bufPrint(buf, "#{d} {s} {s} {s} {s}", .{ rec.seq, actor, rec.name(), args[0..max_args], badge }) catch "#?";
        },
        .revert => blk: {
            if (rec.target_seq) |t| {
                break :blk std.fmt.bufPrint(buf, "#{d} {s} undo #{d} [meta/revert]", .{ rec.seq, actor, t }) catch "#?";
            }
            break :blk std.fmt.bufPrint(buf, "#{d} {s} undo [meta/revert]", .{ rec.seq, actor }) catch "#?";
        },
    };
}

/// History row colour (as in pixie: reverted=subtle / revert=meta colour / normal=body).
fn historyCmdRowColor(ctx: *const gui.Context, rec: *const platform.command.CommandRecord) gui.Color {
    return switch (rec.kind) {
        .revert => gui.Color.rgba(0x88, 0x9A, 0xB0, 0xFF),
        .normal => if (rec.reverted) ctx.style.text_subtle else gui.Color.rgba(0xD0, 0xD6, 0xDE, 0xFF),
    };
}

fn formatHistoryMetaLine(meta: *const MetaEvent, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "— user {s} [local_only]", .{meta.summary()}) catch "—";
}

/// For History row merge display (cmd + meta). Fixed stack; no per-frame alloc.
const HistoryDisplayLine = struct {
    primary_seq: u64,
    is_meta: bool,
    /// meta → meta ring index (0=oldest); cmd → recordAt index.
    src_index: u32,
};

fn buildHistoryDisplayLines(app: *const App, out: []HistoryDisplayLine) usize {
    var n: usize = 0;
    var i: u32 = 0;
    while (i < app.cmd_log.filled and n < out.len) : (i += 1) {
        const rec = app.cmd_log.recordAt(i);
        out[n] = .{ .primary_seq = rec.seq, .is_meta = false, .src_index = i };
        n += 1;
    }
    i = 0;
    while (i < app.meta_filled and n < out.len) : (i += 1) {
        const m = app.metaAt(i);
        // Splice in right after after_seq (same primary → tie-break with is_meta so meta sits above visually).
        out[n] = .{ .primary_seq = m.after_seq, .is_meta = true, .src_index = i };
        n += 1;
    }
    // Newest first: primary_seq desc; same seq → meta newer (above) than cmd.
    std.mem.sort(HistoryDisplayLine, out[0..n], {}, struct {
        fn less(_: void, a: HistoryDisplayLine, b: HistoryDisplayLine) bool {
            if (a.primary_seq != b.primary_seq) return a.primary_seq > b.primary_seq;
            if (a.is_meta != b.is_meta) return a.is_meta and !b.is_meta;
            return a.src_index > b.src_index;
        }
    }.less);
    return n;
}

fn buildHistoryPanel(ctx: *gui.Context, user_data: *anyopaque) anyerror!void {
    const app: *App = @ptrCast(@alignCast(user_data));
    const body_w = app.historyBodyAvail();
    const body_h = app.historyBodyHeight();
    const pad: i32 = 4;
    const outer_w = @max(1, body_w);
    const content_w = @max(1, outer_w - pad * 2);

    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .fixed = outer_w },
        .height = .{ .fixed = body_h },
        .padding = .{ pad, pad, pad, pad },
        .gap = 2,
    });

    // ScrollArea: fixed-width/height viewport; content is fit (avoid grow-in-fit).
    ctx.beginScrollArea(HISTORY_SCROLL_ID, &app.history_scroll, .{
        .width = .{ .fixed = content_w },
        .height = .{ .fixed = @max(20, body_h - pad * 2) },
        .padding = .{ 2, 2, 2, 2 },
        .gap = 1,
        .bg = gui.Color.rgba(0x14, 0x18, 0x1E, 0xFF),
        .bar_thickness = 8,
    });

    var lines_buf: [platform.command.MAX_CMD_LOG + MAX_META_EVENTS]HistoryDisplayLine = undefined;
    const n_lines = buildHistoryDisplayLines(app, &lines_buf);
    if (n_lines == 0) {
        ctx.labelEx("(no history)", gui.Color.rgba(0x9A, 0xA4, 0xB0, 0xFF));
    } else {
        var line_buf: [HISTORY_LINE_CAP]u8 = undefined;
        for (lines_buf[0..n_lines]) |entry| {
            if (entry.is_meta) {
                const text = formatHistoryMetaLine(app.metaAt(entry.src_index), &line_buf);
                ctx.beginBox(.{ .width = .{ .fixed = @max(1, content_w - 12) }, .height = .fit });
                ctx.labelEx(text, gui.Color.rgba(0x9A, 0xA4, 0xB0, 0xFF));
                ctx.endBox();
            } else {
                const rec = app.cmd_log.recordAt(entry.src_index);
                const text = formatHistoryCmdLine(rec, &line_buf);
                ctx.beginBox(.{ .width = .{ .fixed = @max(1, content_w - 12) }, .height = .fit });
                ctx.labelEx(text, historyCmdRowColor(ctx, rec));
                ctx.endBox();
            }
        }
    }
    ctx.endScrollArea();
    ctx.endBox();
}

fn inspectorMemberSelected(ctx: *anyopaque, handle: modular.dyn.Handle) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    // Do not touch canvas selection / group collapsed / RT. target only.
    if (handle >= MAX_MODULES or !app.dyn.slotActive(handle)) return;
    app.inspector_target = handle;
    // Point observe at the drill-down target too (for params-digest choice checks).
    app.observed_field = observedFieldForNode(app, handle) orelse app.observed_field;
}

fn buildInspectorPanel(ctx: *gui.Context, user_data: *anyopaque) anyerror!void {
    const app: *App = @ptrCast(@alignCast(user_data));
    var member_buf: [MAX_MODULES]inspector.MemberInfo = undefined;
    const view_state = app.inspectorView(&member_buf);
    inspector.drawBody(
        ctx,
        app.dyn,
        view_state,
        app.inspectorBodyAvail(),
        app,
        snapshotParamCallback,
        app,
        displayInspectorValue,
        app,
        inspectorChanged,
        app,
        inspectorMemberSelected,
    );
}

fn formatPersistKey(buf: []u8, key: gui.PersistKey) []const u8 {
    return switch (key) {
        .slot => |s| std.fmt.bufPrint(buf, "slot.{s}.{s}", .{ @tagName(s.slot), @tagName(s.field) }) catch "",
        .panel => |p| std.fmt.bufPrint(buf, "panel.{s}.{s}", .{ p.name, @tagName(p.field) }) catch "",
    };
}

fn panelPrefsRead(ud: *anyopaque, key: gui.PersistKey) ?gui.PersistValue {
    const app: *App = @ptrCast(@alignCast(ud));
    var key_buf: [96]u8 = undefined;
    const k = formatPersistKey(&key_buf, key);
    if (k.len == 0) return null;
    return switch (key) {
        .slot => |s| switch (s.field) {
            .visible => if (app.prefs.getBool(k)) |v| .{ .boolean = v } else null,
            .extent => if (app.prefs.getI64(k)) |v| .{ .integer = v } else null,
        },
        .panel => |p| switch (p.field) {
            .visible, .open => if (app.prefs.getBool(k)) |v| .{ .boolean = v } else null,
        },
    };
}

fn panelPrefsWrite(ud: *anyopaque, key: gui.PersistKey, value: gui.PersistValue) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ud));
    var key_buf: [96]u8 = undefined;
    const k = formatPersistKey(&key_buf, key);
    if (k.len == 0) return;
    switch (value) {
        .boolean => |v| try app.prefs.setBool(k, v),
        .integer => |v| try app.prefs.setI64(k, v),
    }
}

fn panelPersistence(app: *App) gui.Persistence {
    return .{
        .user_data = app,
        .read = panelPrefsRead,
        .write = panelPrefsWrite,
    };
}

fn persistPanelPrefs(app: *App) void {
    const dir = app.prefs_dir orelse return;
    // H hide-all is a temporary slot override. Restore pre-hide values before persist; re-apply after.
    const was_hidden = app.panels_hidden;
    if (was_hidden) {
        app.panel_host.setSlotVisible(.left, app.pre_hide_left_visible);
        app.panel_host.setSlotVisible(.right, app.pre_hide_right_visible);
    }
    app.panel_host.persist(panelPersistence(app)) catch |err| {
        std.debug.print("apps/patch: panel persist failed: {s}\n", .{@errorName(err)});
        if (was_hidden) {
            app.panel_host.setSlotVisible(.left, false);
            app.panel_host.setSlotVisible(.right, false);
        }
        return;
    };
    if (was_hidden) {
        app.panel_host.setSlotVisible(.left, false);
        app.panel_host.setSlotVisible(.right, false);
    }
    app.prefs.save(app.io, dir, "preferences.ash") catch |err| {
        std.debug.print("apps/patch: preferences save failed: {s}\n", .{@errorName(err)});
        return;
    };
    app.prefs_dirty = false;
}

fn actionPanelToggle(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const name_raw = std.mem.trim(u8, args, " \t");
    // harness uses lowercase names. PanelHost names are PascalCase. local_only (not in CommandLog → meta ring).
    const panel_name: []const u8 = blk: {
        if (std.mem.eql(u8, name_raw, "inspector") or std.mem.eql(u8, name_raw, "Inspector")) break :blk "Inspector";
        if (std.mem.eql(u8, name_raw, "history") or std.mem.eql(u8, name_raw, "History")) break :blk "History";
        return error.InvalidArgument;
    };
    if (!app.togglePanelByName(panel_name)) return error.InvalidArgument;
    if (app.prefs_dirty) persistPanelPrefs(app);
    const visible = app.panelVisible(panel_name);
    var sum_buf: [64]u8 = undefined;
    const sum = std.fmt.bufPrint(&sum_buf, "panel_toggle {s}={d}", .{ name_raw, @intFromBool(visible) }) catch "panel_toggle";
    app.pushMetaEvent(sum);
    return std.fmt.bufPrint(buf, "ok panel_toggle {s}={d}", .{ name_raw, @intFromBool(visible) }) catch error.BufferTooSmall;
}

/// Undoable recording of GUI ops goes through `routeUiAction` → `recordedAction` / `notePatchUndo`.
/// Display-only `recordExecuted(..., undo_ref=null)` has been removed.
const ChoiceDigestInfo = struct {
    name: []const u8,
    index: i32,
    option: []const u8,

    const none: ChoiceDigestInfo = .{ .name = "none", .index = -1, .option = "none" };
};

/// Choice-parameter info for the target handle (for digest). Prefer observed if it is a choice; else the first choice.
fn targetChoiceInfo(app: *const App, target: Handle) ChoiceDigestInfo {
    const kind = app.dyn.kindOf(target) orelse return ChoiceDigestInfo.none;
    const descs = switch (kind) {
        inline else => |comptime_kind| modular.descriptors(comptime_kind),
    };
    const observed = observedField(app);
    // 1) If observed is a choice on this target, prefer it
    if (param_view.sameFieldParts(observed, target, observed.name)) {
        if (paramDescFor(kind, observed.name)) |desc| switch (desc.kind) {
            .choice => |c| {
                const snap = modular.getParamSnapshot(app.dyn, target, desc.name) catch return ChoiceDigestInfo.none;
                const idx: usize = switch (snap.field) {
                    .choice => |v| @min(v, c.options.len -| 1),
                    .scalar => return ChoiceDigestInfo.none,
                };
                // If pending exists, use it as the display value
                const shown_idx: usize = blk: {
                    if (app.findEditState(param_view.fieldKey(target, desc.name))) |st| {
                        if (st.pending) |p| switch (p) {
                            .choice => |v| break :blk @min(v, c.options.len -| 1),
                            .scalar => {},
                        };
                    }
                    break :blk idx;
                };
                return .{ .name = desc.name, .index = @intCast(shown_idx), .option = c.options[shown_idx] };
            },
            .scalar => {},
        };
    }
    // 2) first choice descriptor
    for (descs) |desc| {
        switch (desc.kind) {
            .choice => |c| {
                const snap = modular.getParamSnapshot(app.dyn, target, desc.name) catch continue;
                const idx: usize = switch (snap.field) {
                    .choice => |v| @min(v, c.options.len -| 1),
                    .scalar => continue,
                };
                const shown_idx: usize = blk: {
                    if (app.findEditState(param_view.fieldKey(target, desc.name))) |st| {
                        if (st.pending) |p| switch (p) {
                            .choice => |v| break :blk @min(v, c.options.len -| 1),
                            .scalar => {},
                        };
                    }
                    break :blk idx;
                };
                return .{ .name = desc.name, .index = @intCast(shown_idx), .option = c.options[shown_idx] };
            },
            .scalar => {},
        }
    }
    return ChoiceDigestInfo.none;
}

fn paramsDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *const App = @ptrCast(@alignCast(ctx));
    const key = observedField(app);
    const snapshot = modular.getParamSnapshot(app.dyn, @intCast(key.handle), key.name) catch return buf[0..0];
    const field = scalarParamValue(snapshot.field);
    const instant = if (snapshot.instant) |value| scalarParamValue(value) else null;
    const inspector_value = observedInspectorValue(app, key);
    const shown = editScalarValue(app, key) orelse inspector_value orelse field;
    const kind = app.dyn.kindOf(@intCast(key.handle)) orelse .vca;
    const ghost = if (paramDescFor(kind, key.name)) |desc| switch (desc.kind) {
        .scalar => |s| param_view.ghostFraction(.{ .field = snapshot.field, .instant = snapshot.instant, .has_instant = snapshot.has_instant }, s.min, s.max) != null,
        .choice => false,
    } else false;
    const selected_h: i32 = if (app.selected) |item| switch (item) {
        .node => |h| @intCast(h),
        .group => |gid| @intCast(group.handleOfGroup(gid)),
        else => -1,
    } else -1;
    const selected_kind = if (app.selected) |item| switch (item) {
        .node => |h| if (app.dyn.kindOf(h)) |k| @tagName(k) else "none",
        .group => |gid| if (gid < group.MAX_GROUPS and app.ledger.groups[gid].active) @tagName(app.ledger.groups[gid].kind) else "none",
        else => "none",
    } else "none";
    const target_h: i32 = if (app.inspector_target) |t| @intCast(t) else -1;
    const target_kind: []const u8 = if (app.inspector_target) |t|
        if (app.dyn.kindOf(t)) |k| @tagName(k) else "none"
    else
        "none";
    const choice = if (app.inspectorParamHandle()) |th| targetChoiceInfo(app, th) else ChoiceDigestInfo.none;
    const edit = app.findEditState(key);
    var instant_buf: [32]u8 = undefined;
    var field_buf: [32]u8 = undefined;
    var inspector_buf: [32]u8 = undefined;
    var shown_buf: [32]u8 = undefined;
    const instant_text = optionalF32Text(&instant_buf, instant);
    const field_text = optionalF32Text(&field_buf, field);
    const inspector_text = optionalF32Text(&inspector_buf, inspector_value);
    const shown_text = optionalF32Text(&shown_buf, shown);
    // transport= key removed. Inspector path only.
    const result = std.fmt.bufPrint(buf, "selected_h={d} selected_kind={s} inspector_target={d} target_kind={s} choice_name={s} choice_index={d} choice_option={s} observed_h={d} observed_name={s} field={s} instant={s} inspector={s} shown={s} dragging={d} override={d} ghost={d}", .{
        selected_h,
        selected_kind,
        target_h,
        target_kind,
        choice.name,
        choice.index,
        choice.option,
        key.handle,
        key.name,
        field_text,
        instant_text,
        inspector_text,
        shown_text,
        if (edit) |state| @intFromBool(state.dragging) else 0,
        @intFromBool(hasOverride(app, key)),
        @intFromBool(ghost),
    }) catch return buf[0..0];
    return result;
}

fn paramsSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app: *const App = @ptrCast(@alignCast(ctx));
    const key = observedField(app);
    const target_h: i32 = if (app.inspector_target) |t| @intCast(t) else -1;
    const target_kind: []const u8 = if (app.inspector_target) |t|
        if (app.dyn.kindOf(t)) |k| @tagName(k) else "none"
    else
        "none";
    const choice = if (app.inspectorParamHandle()) |th| targetChoiceInfo(app, th) else ChoiceDigestInfo.none;
    var out: [4096]u8 = undefined;
    var off: usize = 0;
    const head = std.fmt.bufPrint(out[off..], "{{\"observed_h\":{d},\"observed_name\":\"{s}\",\"inspector_target\":{d},\"target_kind\":\"{s}\",\"choice_name\":\"{s}\",\"choice_index\":{d},\"choice_option\":\"{s}\",\"rows\":[", .{
        key.handle,
        key.name,
        target_h,
        target_kind,
        choice.name,
        choice.index,
        choice.option,
    }) catch return allocator.dupe(u8, "{}");
    off += head.len;
    for (app.param_rows[0..app.param_row_count]) |row| {
        if (!row.valid) continue;
        const snapshot = modular.getParamSnapshot(app.dyn, @intCast(row.key.handle), row.key.name) catch continue;
        const field = scalarParamValue(snapshot.field) orelse continue;
        const shown = editScalarValue(app, row.key) orelse field;
        const sep: []const u8 = if (off == head.len) "" else ",";
        const piece = std.fmt.bufPrint(out[off..], "{s}{{\"h\":{d},\"name\":\"{s}\",\"x\":{d},\"y\":{d},\"w\":{d},\"h_px\":{d},\"field\":{d:.2},\"shown\":{d:.2}}}", .{
            sep, row.key.handle, row.key.name, row.rect.x, row.rect.y, row.rect.w, row.rect.h, field, shown,
        }) catch break;
        off += piece.len;
    }
    const tail = std.fmt.bufPrint(out[off..], "]}}", .{}) catch "";
    off += tail.len;
    return allocator.dupe(u8, out[0..off]);
}

fn modularDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const p = app.patch;
    const st = p.snapshotState();
    // Concatenate into the same buf in 3 pieces (bufPrint caps one call at 32 args).
    const a = std.fmt.bufPrint(buf, "{{\"playing\":true,\"bpm\":{d:.0},\"clock_phase\":{d:.3},\"density\":{d:.3},\"density_target\":{d:.3}," ++
        "\"swing\":{d:.3},\"sidechain\":{d:.3},\"master_cutoff\":{d:.0},\"bass_pitch_cv\":{d:.4}," ++
        "\"steps\":{{\"kick\":{d},\"hat\":{d},\"clap\":{d},\"bass\":{d}}}," ++
        "\"active\":{{\"kick\":{},\"hat\":{},\"clap\":{},\"pad\":{}}}," ++
        "\"gains\":{{\"kick\":{d:.3},\"hat\":{d:.3},\"clap\":{d:.3},\"bass\":{d:.3},\"pad\":{d:.3}}}," ++
        "\"muted\":{{\"kick\":{},\"hat\":{},\"clap\":{},\"bass\":{},\"pad\":{}}},", .{
        st.bpm,         st.clock_phase,      st.density,       st.density_target,
        st.swing,       st.sidechain_amount, st.master_cutoff, st.bass_pitch_cv,
        st.kick_step,   st.hat_step,         st.clap_step,     st.bass_step,
        st.kick_active, st.hat_active,       st.clap_active,   st.pad_active,
        st.kick_gain,   st.hat_gain,         st.clap_gain,     st.bass_gain,
        st.pad_gain,    st.kick_muted,       st.hat_muted,     st.clap_muted,
        st.bass_muted,  st.pad_muted,
    }) catch return buf[0..0];
    const b = std.fmt.bufPrint(buf[a.len..], "\"ph4\":{{\"kick_click\":{d:.3},\"hat_bright\":{d:.3}," ++
        "\"pad_cutoff\":{d:.0},\"pad_warmth\":{d:.3},\"master_drive\":{d:.3}," ++
        "\"pre_clip_peak\":{d:.3},\"clip_rate\":{d:.4}}}," ++
        "\"ambient\":{{\"move\":{d:.3},\"register\":{d},\"root_cv\":{d:.4}}},", .{
        st.kick_click_gain,  st.hat_brightness,  st.pad_cutoff, st.pad_warmth,
        st.master_drive,     st.pre_clip_peak,   st.clip_rate,  st.ambient_move,
        st.ambient_register, st.ambient_root_cv,
    }) catch return buf[0..a.len];
    // Ph5 pattern (masks as hex. bass_deg array is on the snapshot side) + song summary.
    // Close JSON with a single trailing `}` (watch the 1024B budget).
    const selected = selectedParamDigest(app, buf[a.len + b.len ..]);
    const c = std.fmt.bufPrint(buf[a.len + b.len + selected.len ..], "\"patterns\":{{\"kick\":\"{x:0>4}\",\"hat\":\"{x:0>4}\"," ++
        "\"clap\":\"{x:0>4}\",\"bass_on\":\"{x:0>4}\",\"bass_accent\":\"{x:0>4}\",\"bass_slide\":\"{x:0>4}\"}}," ++
        "\"lock\":[{d},{d},{d},{d}],\"evolve\":{d},\"rev\":{d},\"mut\":{d},\"seed\":{d}," ++
        "\"song\":{{\"playing\":{d},\"row\":{d},\"bar\":{d},\"rows\":{d}}}}}", .{
        st.kick_on,        st.hat_on,          st.clap_on,
        st.bass_on,        st.bass_accent,     st.bass_slide,
        b01(st.lock[0]),   b01(st.lock[1]),    b01(st.lock[2]),
        b01(st.lock[3]),   b01(st.evolve),     st.pattern_rev,
        st.mutation_count, st.base_seed,       b01(st.song_playing),
        st.song_row,       st.song_bar_in_row, st.song_rows,
    }) catch return buf[0 .. a.len + b.len];
    return buf[0 .. a.len + b.len + selected.len + c.len];
}

fn modularSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const p = app.patch;
    const st = p.snapshotState();
    // Detailed snapshot = digest (within 1024B) plus bass_deg array + song detail (build in a fixed buf → dupe).
    var dbuf: [1024]u8 = undefined;
    const d = modularDigest(ctx, &dbuf);
    const body = if (d.len > 0 and d[d.len - 1] == '}') d[0 .. d.len - 1] else d; // Drop the trailing '}'
    var out: [2048]u8 = undefined;
    var off: usize = 0;
    {
        const piece = std.fmt.bufPrint(out[off..], "{s},\"bass_deg\":[", .{body}) catch return allocator.dupe(u8, d);
        off += piece.len;
    }
    for (st.bass_deg, 0..) |dg, i| {
        const sep: []const u8 = if (i == 0) "" else ",";
        const piece = std.fmt.bufPrint(out[off..], "{s}{d}", .{ sep, dg }) catch break;
        off += piece.len;
    }
    // song detail (row summary + chain lens + loop)
    {
        const piece = std.fmt.bufPrint(out[off..], "],\"song_detail\":{{\"loop\":{d},\"rev\":{d},\"rows\":[", .{
            b01(st.song_loop),
            st.song_rev,
        }) catch {
            const tail = std.fmt.bufPrint(out[off..], "]}}", .{}) catch "";
            off += tail.len;
            return allocator.dupe(u8, out[0..off]);
        };
        off += piece.len;
    }
    const song = p.song;
    const n_rows: usize = @min(@as(usize, st.song_rows), 8); // Summary: first 8 rows
    var ri: usize = 0;
    while (ri < n_rows) : (ri += 1) {
        const row = song.rows[ri];
        const sep: []const u8 = if (ri == 0) "" else ",";
        const piece = std.fmt.bufPrint(out[off..], "{s}[{d},{d},{d},{d}]", .{
            sep, row.kick, row.hat, row.clap, row.bass,
        }) catch break;
        off += piece.len;
    }
    {
        const piece = std.fmt.bufPrint(out[off..], "],\"chain_lens\":[", .{}) catch "";
        off += piece.len;
    }
    var ci: usize = 0;
    while (ci < 8) : (ci += 1) {
        const sep: []const u8 = if (ci == 0) "" else ",";
        const piece = std.fmt.bufPrint(out[off..], "{s}{d}", .{ sep, song.chains[ci].len }) catch break;
        off += piece.len;
    }
    const tail = std.fmt.bufPrint(out[off..], "]}}}}", .{}) catch "";
    off += tail.len;
    return allocator.dupe(u8, out[0..off]);
}

// ============================================================================
// harness custom actions (modular adopts registerAction.
// Same shape as pixie/synth: a write mouth symmetric to probe(read). Walks the same
// publish calls as the existing GUI edit path).
//
// Hot-path declaration: every action `run()` is event-only (once per harness `action` command,
// inside main-thread pollGate). Neither per-frame nor per-sample, so the performance rules do not apply.
// State propagation only reuses the existing RT-safe cross-thread hand-off; no new
// sync/alloc/lock/panic is added to the RT path (`LofiPatch.render`→graph `processBlock`):
//   - graph param: `queueParamOverride` → param_db Mailbox.
//   - tone macros: `publishControls` (atomic store).
//   - pattern edits (lock/evolve/step/pitch): read the latest pattern via `patch.snapshotState()`,
//     convert to an edit base with `stateToCommand` → rewrite the field → increment `app.pattern_rev` once
//     → `patch.controls.pattern_db.publish(cmd)` (triple-buffer Mailbox. Same path and revision
//     counter as the GUI's "publish only when edited=true in a frame", so there is no double numbering).
//
// Parsers live in `gen_actions.zig` (std only; no App/kit/modular) and are unit-tested. Resolving track names
// stays in this file, which knows App's concrete types (same split as pixie's `ToolKind`).
// ============================================================================

fn setMuteAndPublish(app: *App, name: []const u8, muted: bool) error{UnknownTrack}!void {
    const track = std.meta.stringToEnum(MuteTrack, name) orelse return error.UnknownTrack;
    switch (track) {
        .kick => app.params.kick_mute = muted,
        .hat => app.params.hat_mute = muted,
        .clap => app.params.clap_mute = muted,
        .bass => app.params.bass_mute = muted,
        .pad => app.params.pad_mute = muted,
    }
    const target = trackMixerMuteTarget(app, track);
    queueParamOverride(app, target.handle, target.name, if (muted) 1.0 else 0.0) catch {};
}

fn trackMixerMuteTarget(app: *const App, track: MuteTrack) struct { handle: usize, name: []const u8 } {
    return switch (track) {
        .kick => .{ .handle = app.patch.master_mixer_h, .name = "in0_mute" },
        .hat => .{ .handle = app.patch.nonkick_mixer_h, .name = "in0_mute" },
        .clap => .{ .handle = app.patch.nonkick_mixer_h, .name = "in1_mute" },
        .bass => .{ .handle = app.patch.nonkick_mixer_h, .name = "in2_mute" },
        .pad => .{ .handle = app.patch.nonkick_mixer_h, .name = "in3_mute" },
    };
}

/// Consume pending_param_undo_before only when the param name matches, and return it.
/// On mismatch return null (leave pending) → caller falls back to the current value as before.
fn takePendingParamUndoBefore(app: *App, param_name: []const u8) ?patch_undo.ParamValueSnap {
    const pending = app.pending_param_undo_before orelse return null;
    if (!std.mem.eql(u8, pending.name(), param_name)) return null;
    app.pending_param_undo_before = null;
    return pending;
}

fn actionSetParam(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    // `#NodeId|handle + descriptor + value` only (reject the old 2-token Transport alias).
    const p = try actions.parseParamOverride(args);
    const h = try resolveNodeRef(app, p.ref, true);
    const cname = canonicalParamName(app, h, p.name) orelse return error.UnknownParam;
    const before_snap = takePendingParamUndoBefore(app, cname) orelse blk: {
        var s = patch_undo.ParamValueSnap{ .mode = 1, .node_id = (nodeIdOf(app, h) orelse NodeId.fromRaw(0)).raw() };
        s.setName(cname);
        const cur = modular.getParam(app.dyn, h, cname) catch break :blk null;
        switch (cur) {
            .scalar => |v| {
                s.value_kind = 0;
                s.value_bits = @bitCast(v);
            },
            .choice => |idx| {
                s.value_kind = 1;
                s.value_bits = @intCast(idx);
            },
        }
        break :blk s;
    };
    try queueParamOverride(app, h, cname, p.value);
    if (before_snap) |bs| {
        const same = switch (bs.value_kind) {
            0 => @as(f32, @bitCast(bs.value_bits)) == p.value,
            1 => @as(f32, @floatFromInt(bs.value_bits)) == p.value,
            else => false,
        };
        if (!same) notePatchUndo(app, .{ .param = bs });
    }
    return "ok";
}

fn canonicalizeSetParam(ctx: *anyopaque, args: []const u8, scratch: []u8) anyerror![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    // NodeId form only (reject the 2-token Transport alias).
    const forbid = !actions.allowNodeCanonFill(platform.netsyncActive());
    const p = try actions.parseParamOverride(args);
    const id = try nodeRefToId(app, p.ref, forbid);
    const h = try resolveNodeRef(app, .{ .id = id }, false);
    const cname = canonicalParamName(app, h, p.name) orelse return error.UnknownParam;
    return actions.formatParamOverride(scratch, id, cname, p.value) catch return error.ArgsTooLong;
}

const MuteTrack = enum { kick, hat, clap, bass, pad };

fn actionSetMute(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const p = try gen_actions.parseNameBool(args);
    const track = std.meta.stringToEnum(MuteTrack, p.name) orelse return error.UnknownTrack;
    const was = switch (track) {
        .kick => app.params.kick_mute,
        .hat => app.params.hat_mute,
        .clap => app.params.clap_mute,
        .bass => app.params.bass_mute,
        .pad => app.params.pad_mute,
    };
    try setMuteAndPublish(app, p.name, p.on);
    if (was != p.on) {
        notePatchUndo(app, .{ .mute = .{ .track = @intFromEnum(track), .was_muted = was } });
    }
    return "ok";
}

const LockTrack = enum { kick, hat, clap, bass };

fn actionSetLock(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const before = patternToSnap(patternEditBase(app));
    const p = try gen_actions.parseNameBool(args);
    const track = std.meta.stringToEnum(LockTrack, p.name) orelse return error.UnknownTrack;
    var cmd = patternEditBase(app);
    switch (track) {
        .kick => cmd.kick.lock = p.on,
        .hat => cmd.hat.lock = p.on,
        .clap => cmd.clap.lock = p.on,
        .bass => cmd.bass.lock = p.on,
    }
    const published = publishPatternCommand(app, cmd);
    notePatternUndoIfChanged(app, before, published);
    return "ok";
}

fn actionSetEvolve(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const before = patternToSnap(patternEditBase(app));
    const on = try gen_actions.parseBool01(args);
    var cmd = patternEditBase(app);
    cmd.evolve = on;
    const published = publishPatternCommand(app, cmd);
    notePatternUndoIfChanged(app, before, published);
    return "ok";
}

/// Internal snapshot of the host evolve result. Publish immediately with quantize_bar=false.
fn actionPatternState(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const p = try gen_actions.parsePatternState(args);
    var cmd = patternEditBase(app);
    cmd.kick = .{ .on = p.kick_on, .lock = p.kick_lock };
    cmd.hat = .{ .on = p.hat_on, .lock = p.hat_lock };
    cmd.clap = .{ .on = p.clap_on, .lock = p.clap_lock };
    cmd.bass = .{
        .on = p.bass_on,
        .accent = p.bass_accent,
        .slide = p.bass_slide,
        .deg = p.bass_deg,
        .lock = p.bass_lock,
    };
    cmd.evolve = p.evolve;
    cmd.quantize_bar = false;
    _ = publishPatternCommand(app, cmd);
    app.patch.controls.remote_mutation_count.store(p.mutation_count, .release);
    // Also align the already-broadcast mutation when the host applies its own COMMIT.
    if (platform.netsyncIsHost()) app.last_pattern_state_mut = p.mutation_count;
    return "ok";
}

/// netsync off or host → may mutate. client → pattern_state receive only.
fn updateEvolveAuthority(app: *App) void {
    const host = !platform.netsyncActive() or platform.netsyncIsHost();
    app.patch.controls.evolve_host_authority.store(@intFromBool(host), .release);
}

/// host main thread: on mutation_count change, or peer increase (join), COMMIT-broadcast pattern_state.
fn maybeBroadcastPatternState(app: *App) void {
    if (!platform.netsyncActive() or !platform.netsyncIsHost()) {
        app.last_broadcast_peer_count = 0;
        return;
    }
    const peers = platform.netsyncPeerCount();
    const peer_joined = peers > app.last_broadcast_peer_count;
    app.last_broadcast_peer_count = peers;

    const st = app.patch.snapshotState();
    const mut_changed = st.mutation_count != app.last_pattern_state_mut;
    if (!mut_changed and !peer_joined) return;

    const args_payload = gen_actions.PatternStateArgs{
        .kick_on = st.kick_on,
        .hat_on = st.hat_on,
        .clap_on = st.clap_on,
        .bass_on = st.bass_on,
        .bass_accent = st.bass_accent,
        .bass_slide = st.bass_slide,
        .kick_lock = st.lock[0],
        .hat_lock = st.lock[1],
        .clap_lock = st.lock[2],
        .bass_lock = st.lock[3],
        .evolve = st.evolve,
        .mutation_count = st.mutation_count,
        .bass_deg = st.bass_deg,
    };
    var args_buf: [512]u8 = undefined;
    const args = gen_actions.formatPatternState(&args_buf, args_payload) catch {
        std.debug.print("[patch] pattern_state format failed\n", .{});
        return;
    };
    var out_buf: [64]u8 = undefined;
    _ = platform.commitHostAction("pattern_state", args, &out_buf) catch |err| {
        std.debug.print("[patch] pattern_state broadcast failed: {s}\n", .{@errorName(err)});
        return;
    };
    app.last_pattern_state_mut = st.mutation_count;
}

const StepTarget = enum { kick, hat, clap, bass_on, bass_accent, bass_slide };

fn actionToggleStep(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const before = patternToSnap(patternEditBase(app));
    const p = try gen_actions.parseNameU8(args);
    const target = std.meta.stringToEnum(StepTarget, p.name) orelse return error.UnknownTrack;
    if (p.value >= 16) return error.StepOutOfRange;
    var cmd = patternEditBase(app);
    const mask = bitOf(p.value);
    switch (target) {
        .kick => cmd.kick.on ^= mask,
        .hat => cmd.hat.on ^= mask,
        .clap => cmd.clap.on ^= mask,
        .bass_on => cmd.bass.on ^= mask,
        .bass_accent => cmd.bass.accent ^= mask,
        .bass_slide => cmd.bass.slide ^= mask,
    }
    const published = publishPatternCommand(app, cmd);
    notePatternUndoIfChanged(app, before, published);
    return "ok";
}

fn actionSetPitch(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const before = patternToSnap(patternEditBase(app));
    const p = try gen_actions.parseTwoU8(args);
    if (p.a >= 16) return error.StepOutOfRange;
    if (p.b >= BASS_DEG_TOTAL) return error.DegreeOutOfRange;
    var cmd = patternEditBase(app);
    cmd.bass.deg[p.a] = @intCast(p.b);
    const published = publishPatternCommand(app, cmd);
    notePatternUndoIfChanged(app, before, published);
    return "ok";
}

// ============================================================================
// save_pattern / load_pattern (KNGN-compatible aliases; legacy MDLP still loads).
//
// Hot-path declaration: save/load are event only. Do not touch the RT path.
// save_pattern = full KNGN save (same content as save_project).
// load_pattern = apply SPRM/PTRN only from KNGN/MDLP.
// ============================================================================

/// Map the current `PatternCommand` into `pattern_io.PatternPayload` (app-free plain struct).
fn patternToPayload(cmd: PatternCommand) pattern_io.PatternPayload {
    return .{
        .evolve = cmd.evolve,
        .kick_on = cmd.kick.on,
        .kick_lock = cmd.kick.lock,
        .hat_on = cmd.hat.on,
        .hat_lock = cmd.hat.lock,
        .clap_on = cmd.clap.on,
        .clap_lock = cmd.clap.lock,
        .bass_on = cmd.bass.on,
        .bass_accent = cmd.bass.accent,
        .bass_slide = cmd.bass.slide,
        .bass_lock = cmd.bass.lock,
        .bass_deg = cmd.bass.deg,
    };
}

/// Restore `pattern_io.PatternPayload` into a `PatternCommand` with `rev` (rev is not in the payload;
/// allocate it the same way as other pattern-edit actions: increment `app.pattern_rev` once).
fn payloadToPatternCommand(rev: u32, p: pattern_io.PatternPayload) PatternCommand {
    return .{
        .rev = rev,
        .evolve = p.evolve,
        .kick = .{ .on = p.kick_on, .lock = p.kick_lock },
        .hat = .{ .on = p.hat_on, .lock = p.hat_lock },
        .clap = .{ .on = p.clap_on, .lock = p.clap_lock },
        .bass = .{ .on = p.bass_on, .accent = p.bass_accent, .slide = p.bass_slide, .deg = p.bass_deg, .lock = p.bass_lock },
    };
}

fn actionSavePattern(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const path = try gen_actions.parsePath(args);
    try actionSaveProjectFile(app, path);
    return "ok";
}

fn actionLoadPattern(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const path = try gen_actions.parsePath(args);
    const gpa = std.heap.c_allocator;
    var loaded = try project_io.load(app.io, gpa, path, Params);
    defer loaded.deinit(gpa);
    if (!loaded.apply_params_pattern) return error.UnsupportedFormat;
    // pattern-only: no seed → apply immediately (quantize_bar=false).
    applyParamsPattern(app, loaded.params, loaded.pattern, false);
    // No NPRM, so one-shot apply legacy SPRM transport fields into the graph.
    publishDeprecatedGraphFromParams(app.patch, app.params);
    return "ok";
}

/// `action seed <n>`: parse on main → lock-free publish → RT applies at the next bar boundary.
/// Also sync app.notation_seed (so mini-notation `?` / alternation stay consistent with the seed contract).
fn actionSeed(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch;
    const n = try gen_actions.parseU64(args);
    const st = patch.snapshotState();
    const before = patch_undo.SeedSnap{
        .base_seed = st.base_seed,
        .notation_seed = app.notation_seed,
        .notation_counter = app.notation_counter,
    };
    if (before.base_seed == n and before.notation_seed == n) {
        // still update notation_seed for consistency; no undo if identical intent
        app.notation_seed = n;
        patch.requestSeed(n);
        return "ok";
    }
    app.notation_seed = n;
    patch.requestSeed(n);
    notePatchUndo(app, .{ .seed = before });
    return "ok";
}

// ============================================================================
// Song/Chain/Phrase actions (recorded = consistent with seed+recipe determinism)
// Edits rewrite app.song → rev++ → song_db.publish (declarative whole-SongData replace).
// ============================================================================

fn publishSong(app: *App, patch: *LofiPatch) void {
    app.song.rev +%= 1;
    patch.controls.song_db.publish(app.song);
}

/// `phrase_capture <idx>`: capture the current pattern into drum pool[idx]×3 + bass pool[idx].
fn actionPhraseCapture(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch;
    const before = songToSnap(app.song);
    const idx = gen_actions.parseU8(args) catch {
        platform.setActionErrorDetail("bad_args", "usage: phrase_capture <idx 0..31>");
        return error.BadArgs;
    };
    if (idx >= patchmod.MAX_BASS_PHRASES) {
        platform.setActionErrorDetail("index_out_of_range", "phrase idx must be 0..31");
        return error.IndexOutOfRange;
    }
    const st = patch.snapshotState();
    app.song.phrases_kick[idx] = st.kick_on;
    app.song.phrases_hat[idx] = st.hat_on;
    app.song.phrases_clap[idx] = st.clap_on;
    app.song.phrases_bass[idx] = .{
        .on = st.bass_on,
        .accent = st.bass_accent,
        .slide = st.bass_slide,
        .deg = st.bass_deg,
    };
    publishSong(app, patch);
    noteSongUndoIfChanged(app, before, app.song);
    return "ok";
}

/// `chain_set <chain_idx> <phrase_idx...>` (1..16).
fn actionChainSet(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch;
    const before = songToSnap(app.song);
    const parsed = gen_actions.parseChainSet(args) catch {
        platform.setActionErrorDetail("bad_args", "usage: chain_set <chain_idx> <phrase_idx...>");
        return error.BadArgs;
    };
    if (parsed.chain_idx >= patchmod.MAX_CHAINS) {
        platform.setActionErrorDetail("index_out_of_range", "chain_idx must be 0..31");
        return error.IndexOutOfRange;
    }
    var i: u8 = 0;
    while (i < parsed.len) : (i += 1) {
        if (parsed.phrases[i] >= patchmod.MAX_DRUM_PHRASES) {
            platform.setActionErrorDetail("index_out_of_range", "phrase_idx must be 0..63");
            return error.IndexOutOfRange;
        }
    }
    var ch: Chain = .{};
    ch.len = parsed.len;
    @memcpy(ch.entries[0..parsed.len], parsed.phrases[0..parsed.len]);
    app.song.chains[parsed.chain_idx] = ch;
    publishSong(app, patch);
    noteSongUndoIfChanged(app, before, app.song);
    return "ok";
}

/// `song_row <row_idx> <kick_chain> <hat_chain> <clap_chain> <bass_chain>`.
fn actionSongRow(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const before = songToSnap(app.song);
    const patch = app.patch;
    const parsed = gen_actions.parseSongRow(args) catch {
        platform.setActionErrorDetail("bad_args", "usage: song_row <row> <kick> <hat> <clap> <bass>");
        return error.BadArgs;
    };
    if (parsed.row_idx >= patchmod.MAX_SONG_ROWS) {
        platform.setActionErrorDetail("index_out_of_range", "row_idx must be 0..63");
        return error.IndexOutOfRange;
    }
    if (parsed.kick >= patchmod.MAX_CHAINS or parsed.hat >= patchmod.MAX_CHAINS or
        parsed.clap >= patchmod.MAX_CHAINS or parsed.bass >= patchmod.MAX_CHAINS)
    {
        platform.setActionErrorDetail("index_out_of_range", "chain index must be 0..31");
        return error.IndexOutOfRange;
    }
    app.song.rows[parsed.row_idx] = .{
        .kick = parsed.kick,
        .hat = parsed.hat,
        .clap = parsed.clap,
        .bass = parsed.bass,
    };
    publishSong(app, patch);
    noteSongUndoIfChanged(app, before, app.song);
    return "ok";
}

/// `song_len <n>` (0..64).
fn actionSongLen(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const before = songToSnap(app.song);
    const patch = app.patch;
    const n = gen_actions.parseU8(args) catch {
        platform.setActionErrorDetail("bad_args", "usage: song_len <0..64>");
        return error.BadArgs;
    };
    if (n > patchmod.MAX_SONG_ROWS) {
        platform.setActionErrorDetail("index_out_of_range", "song_len must be 0..64");
        return error.IndexOutOfRange;
    }
    app.song.row_count = n;
    publishSong(app, patch);
    noteSongUndoIfChanged(app, before, app.song);
    return "ok";
}

/// `song_loop <0|1>`.
fn actionSongLoop(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const before = songToSnap(app.song);
    const patch = app.patch;
    const on = gen_actions.parseBool01(args) catch {
        platform.setActionErrorDetail("bad_args", "usage: song_loop <0|1>");
        return error.BadArgs;
    };
    app.song.loop = on;
    publishSong(app, patch);
    noteSongUndoIfChanged(app, before, app.song);
    return "ok";
}

/// `song_play <0|1>`. On start, RT resets position (applyControls rising edge).
fn actionSongPlay(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch;
    const on = gen_actions.parseBool01(args) catch {
        platform.setActionErrorDetail("bad_args", "usage: song_play <0|1>");
        return error.BadArgs;
    };
    // Publish the latest SongData before play (avoid leaking unpublished edits)
    publishSong(app, patch);
    patch.controls.song_playing.store(@intFromBool(on), .release);
    return "ok";
}

/// `song_goto <row>`.
fn actionSongGoto(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch;
    const row = gen_actions.parseU8(args) catch {
        platform.setActionErrorDetail("bad_args", "usage: song_goto <row 0..63>");
        return error.BadArgs;
    };
    if (row >= patchmod.MAX_SONG_ROWS) {
        platform.setActionErrorDetail("index_out_of_range", "row must be 0..63");
        return error.IndexOutOfRange;
    }
    patch.controls.song_goto_row.store(row, .release);
    _ = patch.controls.song_goto_gen.fetchAdd(1, .release);
    return "ok";
}

fn songToPayload(s: SongData) project_io.SongPayload {
    var out: project_io.SongPayload = .{};
    out.phrases_kick = s.phrases_kick;
    out.phrases_hat = s.phrases_hat;
    out.phrases_clap = s.phrases_clap;
    for (s.phrases_bass, 0..) |bp, i| {
        out.phrases_bass[i] = .{ .on = bp.on, .accent = bp.accent, .slide = bp.slide, .deg = bp.deg };
    }
    for (s.chains, 0..) |ch, i| {
        out.chains[i] = .{ .entries = ch.entries, .len = ch.len };
    }
    for (s.rows, 0..) |row, i| {
        out.rows[i] = .{ .kick = row.kick, .hat = row.hat, .clap = row.clap, .bass = row.bass };
    }
    out.row_count = s.row_count;
    out.loop = s.loop;
    return out;
}

fn payloadToSong(rev: u32, p: project_io.SongPayload) SongData {
    var out: SongData = .{};
    out.rev = rev;
    out.phrases_kick = p.phrases_kick;
    out.phrases_hat = p.phrases_hat;
    out.phrases_clap = p.phrases_clap;
    for (p.phrases_bass, 0..) |bp, i| {
        out.phrases_bass[i] = .{ .on = bp.on, .accent = bp.accent, .slide = bp.slide, .deg = bp.deg };
    }
    for (p.chains, 0..) |ch, i| {
        out.chains[i] = .{ .entries = ch.entries, .len = ch.len };
    }
    for (p.rows, 0..) |row, i| {
        out.rows[i] = .{ .kick = row.kick, .hat = row.hat, .clap = row.clap, .bass = row.bass };
    }
    out.row_count = p.row_count;
    out.loop = p.loop;
    return out;
}

/// `save_project <path>`: full KNGN (graph+Ledger+pattern+Song+Params+seed+GENR). local_only; not recorded.
fn actionSaveProject(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const path = try gen_actions.parsePath(args);
    try actionSaveProjectFile(app, path);
    app.pushMetaEvent("save_project");
    return "ok";
}

/// `load_project <path>`: auto-detect KNGN or legacy MDLP/MPRJ/PTCG. local_only; not recorded.
fn actionLoadProject(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    const path = try gen_actions.parsePath(args);
    const gpa = std.heap.c_allocator;
    var loaded = project_io.load(app.io, gpa, path, Params) catch |err| {
        if (err == error.FileNotFound) {
            platform.setActionErrorDetail("file_not_found", "check path or use save_project first");
        }
        return err;
    };
    defer loaded.deinit(gpa);

    if (loaded.apply_graph) {
        const ledger_ptr: ?*const group.Ledger = if (loaded.apply_ledger and loaded.format == .kngn) &loaded.ledger else null;
        const genr_opt: ?project_io.GenRoleHandles = if (loaded.apply_genr and loaded.format == .kngn) loaded.genr else null;
        const nprm_opt: ?[]const project_io.NodeParamRecord = if (loaded.apply_node_params) loaded.node_params else null;
        const result = if (loaded.format == .ptcg)
            try applyGraphReplace(app, loaded.nodes, loaded.edges, null, null, null, loaded.node_id_refs, loaded.next_node_id)
        else
            try applyGraphReplace(app, loaded.nodes, loaded.edges, ledger_ptr, genr_opt, nprm_opt, loaded.node_id_refs, loaded.next_node_id);
        // Use apply_seed_song as the quantize_bar proxy (last-wins quantize only for co-resident formats. See applyParamsPattern).
        if (loaded.apply_params_pattern) applyParamsPattern(app, loaded.params, loaded.pattern, loaded.apply_seed_song);
        if (loaded.apply_seed_song) applySeedSong(app, loaded.seed, loaded.song);
        app.pushMetaEvent("load_project");
        return std.fmt.bufPrint(buf, "format={s} nodes={d}/{d} edges={d}/{d}", .{
            @tagName(loaded.format), result.nodes_restored, loaded.nodes.len, result.edges_restored, loaded.edges.len,
        }) catch "ok";
    }

    // Same: apply_seed_song → quantize_bar (current formats have no pattern-only+seed combo).
    if (loaded.apply_params_pattern) applyParamsPattern(app, loaded.params, loaded.pattern, loaded.apply_seed_song);
    if (loaded.apply_seed_song) applySeedSong(app, loaded.seed, loaded.song);
    app.pushMetaEvent("load_project");
    return std.fmt.bufPrint(buf, "format={s}", .{@tagName(loaded.format)}) catch "ok";
}

/// `action render <path> <seconds>`: write master to a PCM16 WAV via an offline LofiPatch.
///
/// Hot-path declaration: event / main thread only. Does not touch the live patch's RT path.
/// offline is a completely separate instance. Copy seed + published edit state (params + snapshot pattern).
/// Does not copy live mid-bar mutation position (clock phase / step). Full reproduce needs seed+recipe.
/// Blocking the main thread (and thus the UI) during render is an accepted MVP trade-off.
fn actionRender(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    const live = app.patch;

    const parsed = gen_actions.parseRender(args) catch {
        platform.setActionErrorDetail("bad_args", "usage: render <path> <seconds 1..600>");
        return error.BadArgs;
    };

    const sr_u32 = app.sample_rate;
    const sr_f32: f32 = @floatFromInt(sr_u32);
    // Compute seconds×sr in u64 and check the RIFF u32 limit first (defensive; normally unreachable for seconds<=600).
    const total_frames_u64: u64 = @as(u64, parsed.seconds) * @as(u64, sr_u32);
    const data_size_u64: u64 = total_frames_u64 * 2 * 2; // stereo PCM16
    if (total_frames_u64 > std.math.maxInt(u32) or 36 + data_size_u64 > std.math.maxInt(u32)) {
        platform.setActionErrorDetail("bad_args", "output too long for RIFF");
        return error.TooLong;
    }
    const total_frames: u32 = @intCast(total_frames_u64);
    const chunk: u32 = 4800;
    const channels: u32 = 2;

    const gpa = std.heap.c_allocator;
    const offline = LofiPatch.create(gpa, sr_f32) catch |err| {
        platform.setActionErrorDetail("create_failed", "offline patch create failed");
        return err;
    };
    defer offline.destroy();

    // live.base_seed is the same best-effort torn read as digest (do not add new synchronisation).
    offline.resetWithSeed(live.base_seed);
    publishControls(offline, app.params);
    publishDeprecatedGraphFromParams(offline, app.params);
    // Put the snapshot pattern onto offline and bump rev so it always applies.
    var cmd = stateToCommand(live.snapshotState());
    cmd.rev = offline.applied_rev +% 1;
    offline.controls.pattern_db.publish(cmd);

    var file = std.Io.Dir.cwd().createFile(app.io, parsed.path, .{}) catch |err| {
        platform.setActionErrorDetail("write_failed", "cannot create output path");
        return err;
    };
    defer file.close(app.io); // File.close is void (not an error union)

    var wbuf: [8192]u8 = undefined;
    var fwriter = file.writerStreaming(app.io, &wbuf);
    var wav_w = wav.WavWriter.init(&fwriter.interface, channels, sr_u32, total_frames) catch |err| {
        if (err == error.TooLong) {
            platform.setActionErrorDetail("bad_args", "output too long for RIFF");
        } else {
            platform.setActionErrorDetail("write_failed", "wav header write failed");
        }
        return err;
    };

    const audio_buf = gpa.alloc(f32, chunk * channels) catch |err| {
        platform.setActionErrorDetail("write_failed", "render buffer alloc failed");
        return err;
    };
    defer gpa.free(audio_buf);

    var rendered: u32 = 0;
    while (rendered < total_frames) {
        const n = @min(chunk, total_frames - rendered);
        offline.render(audio_buf, n, channels);
        wav_w.writeChunk(audio_buf[0 .. n * channels]) catch |err| {
            platform.setActionErrorDetail("write_failed", "wav chunk write failed");
            return err;
        };
        rendered += n;
    }
    wav_w.finish() catch |err| {
        platform.setActionErrorDetail("write_failed", "wav finish failed");
        return err;
    };

    return std.fmt.bufPrint(buf, "ok path={s} seconds={d} sr={d}", .{ parsed.path, parsed.seconds, sr_u32 }) catch "ok";
}

// ============================================================================
// `action pattern <track> <notation>` (mini-notation → pattern_db, applied at the bar boundary)
//
// Hot-path declaration: parse/eval runs only at action time (main thread, event). RT only receives the
// evaluated PatternCommand (quantize_bar=true) via publish. RT-side work is the fixed-length copy at the
// bar boundary in lofi.zig (no alloc/lock).
// ============================================================================

const PatternTrack = enum { kick, hat, clap, bass };

fn actionPattern(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const before = patternToSnap(patternEditBase(app));
    const patch = app.patch;
    const pa = gen_actions.parsePatternArgs(args) catch {
        platform.setActionErrorDetail("invalid_notation", "usage: pattern <kick|hat|clap|bass> <notation>");
        return error.InvalidNotation;
    };
    const track = std.meta.stringToEnum(PatternTrack, pa.track) orelse {
        platform.setActionErrorDetail("unknown_track", "track must be kick|hat|clap|bass");
        return error.UnknownTrack;
    };
    const ast = gen_actions.parseNotation(pa.notation) catch {
        platform.setActionErrorDetail("invalid_notation", "check mini-notation syntax");
        return error.InvalidNotation;
    };
    // rng_seed = splitmix64(notation_seed ^ counter), alt_index = counter. ++ after eval.
    const alt_index = app.notation_counter;
    const rng_seed = seedmod.splitmix64(app.notation_seed ^ @as(u64, alt_index));
    app.notation_counter +%= 1;
    const result = gen_actions.evalNotation(ast, rng_seed, alt_index);

    // While waiting on a bar (or published but RT has not acquired): base on last_quantized_cmd so
    // consecutive pattern actions do not wipe an earlier track.
    const st = patch.snapshotState();
    var cmd = patternEditBase(app);
    if (app.last_quantized_cmd) |lq| {
        // Our latest quantize is not yet bar-applied: bar_pending, or applied_rev not reached
        if (lq.rev == app.pattern_rev and (st.bar_pending or st.pattern_rev != lq.rev)) {
            cmd = lq;
        }
    }
    switch (track) {
        .kick => cmd.kick.on = result.on,
        .hat => cmd.hat.on = result.on,
        .clap => cmd.clap.on = result.on,
        .bass => {
            // Declarative full replace: on is fully replaced; deg overwrites only deg_set steps (accent/slide kept)
            cmd.bass.on = result.on;
            var s: u8 = 0;
            while (s < 16) : (s += 1) {
                const m = bitOf(s);
                if (result.deg_set & m != 0) {
                    cmd.bass.deg[s] = result.deg[s];
                }
            }
        },
    }
    // Explicit edits go through even when locked (same behaviour as GUI toggle_step)
    cmd.quantize_bar = true;
    const published = publishPatternCommand(app, cmd);
    app.last_quantized_cmd = published;
    notePatternUndoIfChanged(app, before, published);
    return "ok";
}

/// Turn CommandLog kind=normal into Entry in seq order. name/args are borrowed from the log.
/// Exclusion uses `isRecipeEligibleCommandName` (shared with history badges).
fn recipeEntriesFromLog(log: *const platform.command.CommandLog, gpa: std.mem.Allocator) ![]recipe.Entry {
    var views_buf: [platform.command.MAX_CMD_LOG]recipe.RecordView = undefined;
    var n: usize = 0;
    var i: u32 = 0;
    while (i < log.filled) : (i += 1) {
        const rec = log.recordAt(i);
        const name = rec.name();
        if (!isRecipeEligibleCommandName(name)) continue;
        views_buf[n] = .{
            .is_normal = rec.kind == .normal,
            .name = name,
            .args = rec.args(),
        };
        n += 1;
    }
    return recipe.collectNormalEntries(gpa, views_buf[0..n]);
}

/// `recipe_save <path>`: CommandLog → recipe (app_name=APP_NAME). Not recorded.
fn actionRecipeSave(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const gpa = std.heap.c_allocator;
    const path = try gen_actions.parsePath(args);
    const entries = try recipeEntriesFromLog(&app.cmd_log, gpa);
    defer gpa.free(entries);
    try recipe.save(app.io, path, .{ .app_name = APP_NAME }, entries, gpa);
    app.pushMetaEvent("recipe_save");
    return "ok";
}

/// `recipe_replay <path>`: load → verify app_name → apply routeLocalAction in order. Reject nesting.
/// Re-evaluate from notation_counter = 0 (determinism of the seed+pattern sequence).
fn actionRecipeReplay(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    const gpa = std.heap.c_allocator;
    recipe.checkNotReplaying(app.recipe_replaying) catch {
        platform.setActionErrorDetail("nested_replay", "wait for current recipe_replay to finish");
        return error.NestedReplay;
    };
    // Re-evaluate mini-notation `?` / `<a b>` deterministically from the start of the recipe.
    app.notation_counter = 0;
    const path = try gen_actions.parsePath(args);
    var loaded = recipe.load(app.io, gpa, path) catch |err| {
        if (err == error.FileNotFound) {
            platform.setActionErrorDetail("file_not_found", "check path or use recipe_save first");
        }
        return err;
    };
    defer loaded.deinit();

    recipe.checkAppName(loaded.header.app_name, APP_NAME) catch {
        platform.setActionErrorDetail("app_mismatch", "open with the correct app");
        return error.AppMismatch;
    };

    app.recipe_replaying = true;
    defer app.recipe_replaying = false;

    for (loaded.entries, 0..) |entry, idx| {
        _ = platform.routeAction(entry.name, entry.args, buf) catch |err| {
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

// ============================================================================
// command-model integration (record only; minimal form)
//
// App owns CommandLog + Executor and dispatches harness/copilot actions from registerAction via
// executeAction(actor=.local_user) with recording (GUI and harness/MCP share one undo target).
// ============================================================================

const ActionEntry = struct {
    name: []const u8,
    run: *const fn (ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8,
};

const MODULAR_ACTIONS = [_]ActionEntry{
    .{ .name = "set_param", .run = actionSetParam },
    .{ .name = "set_mute", .run = actionSetMute },
    .{ .name = "set_lock", .run = actionSetLock },
    .{ .name = "set_evolve", .run = actionSetEvolve },
    .{ .name = "toggle_step", .run = actionToggleStep },
    .{ .name = "set_pitch", .run = actionSetPitch },
    .{ .name = "seed", .run = actionSeed },
    .{ .name = "pattern", .run = actionPattern },
    .{ .name = "pattern_state", .run = actionPatternState },
    // Song/Chain/Phrase (recorded)
    .{ .name = "phrase_capture", .run = actionPhraseCapture },
    .{ .name = "chain_set", .run = actionChainSet },
    .{ .name = "song_row", .run = actionSongRow },
    .{ .name = "song_len", .run = actionSongLen },
    .{ .name = "song_loop", .run = actionSongLoop },
    .{ .name = "song_play", .run = actionSongPlay },
    .{ .name = "song_goto", .run = actionSongGoto },
    // graph relay (executor / COMMIT path)
    .{ .name = "add_node", .run = actionAddNode },
    .{ .name = "remove_node", .run = actionRemoveNode },
    .{ .name = "connect", .run = actionConnect },
    .{ .name = "disconnect", .run = actionDisconnect },
    .{ .name = "move_node", .run = actionMoveNode },
    .{ .name = "add_macro", .run = actionAddMacro },
    .{ .name = "remove_macro", .run = actionRemoveMacro },
};

fn dispatchModularAction(ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    for (&MODULAR_ACTIONS) |*e| {
        if (std.mem.eql(u8, e.name, name)) return e.run(ctx, args, buf);
    }
    return error.UnknownAction;
}

fn recordedAction(comptime name: []const u8) *const fn (*anyopaque, []const u8, []u8) anyerror![]const u8 {
    return &struct {
        fn run(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
            const app: *App = @ptrCast(@alignCast(ctx));
            const res = try app.cmd_exec.executeAction(name, args, .{
                .actor = .local_user,
                .record_policy = .record,
            }, buf);
            return res.output;
        }
    }.run;
}

/// Register every action in bulk (call after `platform.init()`, before the main loop. When harness is off,
/// `registerAction` itself is a no-op so normal runs are unaffected). Via the recording wrapper.
/// network_policy's single source is `gen_actions.PATCH_NETWORK_POLICIES`.
fn registerActions(app: *App) void {
    platform.registerAction(.{ .name = "undo", .ctx = app, .run = actionUndo, .network_policy = .undo_own, .desc = "undo last local undoable action" });
    platform.registerAction(.{ .name = "redo", .ctx = app, .run = actionRedo, .network_policy = .redo_own, .desc = "redo last local revert" });
    platform.registerAction(.{
        .name = "set_param",
        .ctx = app,
        .run = recordedAction("set_param"),
        .network_policy = patchPolicy("set_param"),
        .canonicalize = canonicalizeSetParam,
    });
    platform.registerAction(.{ .name = "set_mute", .ctx = app, .run = recordedAction("set_mute"), .network_policy = patchPolicy("set_mute") });
    platform.registerAction(.{ .name = "set_lock", .ctx = app, .run = recordedAction("set_lock"), .network_policy = patchPolicy("set_lock") });
    platform.registerAction(.{ .name = "set_evolve", .ctx = app, .run = recordedAction("set_evolve"), .network_policy = patchPolicy("set_evolve") });
    platform.registerAction(.{ .name = "toggle_step", .ctx = app, .run = recordedAction("toggle_step"), .network_policy = patchPolicy("toggle_step") });
    platform.registerAction(.{ .name = "set_pitch", .ctx = app, .run = recordedAction("set_pitch"), .network_policy = patchPolicy("set_pitch") });
    platform.registerAction(.{
        .name = "save_pattern",
        .ctx = app,
        .run = actionSavePattern,
        .network_policy = patchPolicy("save_pattern"),
        .desc = "save integrated KNGN project (alias of save_project)",
    });
    platform.registerAction(.{
        .name = "load_pattern",
        .ctx = app,
        .run = actionLoadPattern,
        .network_policy = patchPolicy("load_pattern"),
        .desc = "load SPRM/PTRN from KNGN (or legacy MDLP); reject while synced",
    });
    platform.registerAction(.{ .name = "seed", .ctx = app, .run = recordedAction("seed"), .network_policy = patchPolicy("seed") });
    // mini-notation. Recipes record the raw notation text (replay re-evaluates in counter order → deterministic).
    platform.registerAction(.{ .name = "pattern", .ctx = app, .run = recordedAction("pattern"), .network_policy = patchPolicy("pattern") });
    // Host-internal snapshot. Not relay → client PROPOSE gets the generic not-relayable.
    platform.registerAction(.{
        .name = "pattern_state",
        .ctx = app,
        .run = recordedAction("pattern_state"),
        .network_policy = patchPolicy("pattern_state"),
        .desc = "host-internal pattern snapshot (not for client propose)",
    });
    // Song/Chain/Phrase (recorded; consistent with seed+recipe determinism)
    platform.registerAction(.{ .name = "phrase_capture", .ctx = app, .run = recordedAction("phrase_capture"), .network_policy = patchPolicy("phrase_capture") });
    platform.registerAction(.{ .name = "chain_set", .ctx = app, .run = recordedAction("chain_set"), .network_policy = patchPolicy("chain_set") });
    platform.registerAction(.{ .name = "song_row", .ctx = app, .run = recordedAction("song_row"), .network_policy = patchPolicy("song_row") });
    platform.registerAction(.{ .name = "song_len", .ctx = app, .run = recordedAction("song_len"), .network_policy = patchPolicy("song_len") });
    platform.registerAction(.{ .name = "song_loop", .ctx = app, .run = recordedAction("song_loop"), .network_policy = patchPolicy("song_loop") });
    platform.registerAction(.{ .name = "song_play", .ctx = app, .run = recordedAction("song_play"), .network_policy = patchPolicy("song_play") });
    platform.registerAction(.{ .name = "song_goto", .ctx = app, .run = recordedAction("song_goto"), .network_policy = patchPolicy("song_goto") });
    // recipe: meta-op, so not via executor; not recorded in CommandLog.
    platform.registerAction(.{ .name = "recipe_save", .ctx = app, .run = actionRecipeSave, .network_policy = patchPolicy("recipe_save") });
    platform.registerAction(.{ .name = "recipe_replay", .ctx = app, .run = actionRecipeReplay, .network_policy = patchPolicy("recipe_replay") });
    // render: reject during a session (offline copy cannot reproduce the host mutation stream). solo is OK.
    platform.registerAction(.{ .name = "render", .ctx = app, .run = actionRender, .network_policy = patchPolicy("render") });
    // Integrated project serialisation (KNGN). Not recorded.
    platform.registerAction(.{
        .name = "save_project",
        .ctx = app,
        .run = actionSaveProject,
        .network_policy = patchPolicy("save_project"),
        .desc = "save integrated KNGN project (graph+Ledger+pattern+Song+Params+seed)",
    });
    platform.registerAction(.{
        .name = "load_project",
        .ctx = app,
        .run = actionLoadProject,
        .network_policy = patchPolicy("load_project"),
        .desc = "load KNGN or legacy MDLP/MPRJ/PTCG; reject while synced",
    });
}

// (Dual registerStateSync for pattern/graph is retired. integrated only)
