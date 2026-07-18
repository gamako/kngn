//! apps/patch (run-patch): 動的グラフエンジン（40.6.1 DynGraph）の最小パッチをビジュアルに表示する
//! パッチキャンバス UI（TASK-40.6.2）。
//!
//! モジュール=ノード矩形＋ポート丸（種別色 audio/cv/gate）＋ケーブル線で描画し、pan（背景 drag）/
//! zoom（scroll・カーソル基準）/ノード drag 移動 /node・port・cable の hover・選択ができる。
//! ケーブルの付け外し（ライブ再配線）と音は 40.6.3。
//!
//! UI レイアウト状態（ノード world 座標・camera・hover・selected・グループ台帳）は GUI(メインスレッド)側が
//! 持ち、RT のグラフ記述（接続/順序）とは分離する（publish に載せない。AC#3）。currentView() の
//! publish 済みトポロジを読んで描画する。
//! 幾何/ヒットテスト/見切れ判定の純ロジックは canvas.zig（platform 非依存・test-patch で単体テスト）。
//!
//! TASK-40.7.1: グループ/マクロ（DrumMachine）を『畳んだ 1 ノード箱』として表示し、展開すると内部
//! プリミティブのサブグラフが見える（1 レベル入れ子）。マクロのメンバーは通常のプリミティブモジュールとして
//! dyn 上に存在し、「どの handle がどのマクロに属すか / 畳んでいるか / 外向きポートはどれか」は
//! `group.Ledger`（このファイルの App.ledger）が持つ純 UI 状態（publish 非対象）。合成 handle
//! （`>= group.GROUP_HANDLE_BASE`）は canvas 幾何関数の引数/返り値の中だけで使い、dyn accessor・
//! `app.layout[h]` の index・`dyn.disconnect` へは決して渡さない（`group.resolvePort` で実 PortRef へ
//! 解決してから既存の commitConnect 等へ渡す）。詳細は group.zig のコメントを参照。
//! ESC/閉じるで終了。

const std = @import("std");
const builtin = @import("builtin");
const kit = @import("kit"); // 公開 umbrella（ADR-007 R4/R5: apps は kit-only 消費者）
const platform = kit.platform;
const gui = kit.gui;
const appshell = kit.appshell;
const stepgrid = gui.stepgrid;
const modular = @import("modular");
const audio = kit.audio;
const synth = kit.synth; // SampleTap（Audio→GUI 出力タップ。C の master 可視化）
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
const transport = @import("transport.zig");
const param_view = @import("param_view.zig");
const group = @import("group.zig");
const macro = @import("macro.zig");
const actions = @import("actions.zig");
const gen_actions = @import("gen_actions.zig");
const graph_io = @import("graph_io.zig");
const pattern_io = @import("pattern_io.zig");
const project_io = @import("project_io.zig");
const wav = @import("wav.zig");
const seedmod = @import("seed.zig");
const patch_undo = @import("undo.zig");

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
// TASK-40.8 D: per-port tap 定数（modular が単一ソース）。
const TAP_SLOTS = modular.graph_core.TAP_SLOTS;
const TAP_RING = modular.graph_core.TAP_RING;

// group.zig は modular 非依存のため GROUP_HANDLE_BASE(=48) を定数複製している。数値の食い違い
// （dyn.zig の MAX_MODULES 変更を group.zig 側へ反映し忘れる等）を compile time に検出する。
comptime {
    if (group.GROUP_HANDLE_BASE != MAX_MODULES) {
        @compileError("group.GROUP_HANDLE_BASE must equal modular.dyn.MAX_MODULES");
    }
}

/// recipe / diagnostics の canonical app name（既存 modular recipe 互換。TASK-105.4）。
const APP_NAME = "modular";

const WIN_W = 960;
// TASK-40.8: 下部に可視化帯（VIS_H）を足したぶん高くする（キャンバス有効高 = fb_h - VIS_H）。
const WIN_H = 760;
const BG: u32 = 0xFF12161B;

// ---- 可視化帯（C: master scope/spectrogram/level meter）。画面下端の固定帯。----
const VIS_H = 150; // 帯の高さ（キャンバス有効領域 = fb_h - VIS_H）
const VIS_LABEL_H = 16; // 帯上端のラベル行
const VIS_MARGIN = 6; // 帯内の下端余白
const VIS_DRAW_H = VIS_H - VIS_LABEL_H - VIS_MARGIN; // spec/scope の描画高（comptime）
const SPEC_X0 = 16;
const SPEC_W = 500;
const SCOPE_X0 = SPEC_X0 + SPEC_W + 12; // 528
const SCOPE_W = 300;
const METER_X0 = SCOPE_X0 + SCOPE_W + 12; // 840
const METER_W = 48;
const VIS_BG: u32 = 0xFF0A0E12; // 帯の下地
const Spec = spectrogram.Spectrogram(SPEC_W, VIS_DRAW_H);
const Scope = scope.Oscilloscope(SCOPE_W, VIS_DRAW_H);
const Tap = synth.SampleTap(8192);

const NODE_BG = gui.Color.rgba(0x24, 0x2A, 0x33, 0xFF);
const BORDER_COL = gui.Color.rgba(0x50, 0x58, 0x64, 0xFF);
const HOVER_COL = gui.Color.rgba(0x90, 0xA0, 0xB0, 0xFF);
const SEL_COL = gui.Color.rgba(0xE0, 0xC0, 0x50, 0xFF);
const TITLE_COL = gui.Color.rgba(0xE0, 0xE6, 0xEE, 0xFF);
const GRID_COL = gui.Color.rgba(0x1A, 0x20, 0x28, 0xFF);

fn portColor(k: PortKind) gui.Color {
    return switch (k) {
        .audio => gui.Color.rgba(0xE0, 0x90, 0x40, 0xFF), // 橙
        .cv => gui.Color.rgba(0x50, 0x90, 0xE0, 0xFF), // 青
        .gate => gui.Color.rgba(0x60, 0xC0, 0x70, 0xFF), // 緑
    };
}

/// A: ポート色を活性度 level(0..1+) で明滅させる。base を 0.30..1.0 の範囲で明度スケール（消灯でも視認可）。
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
    node: Handle, // 常に実 handle（合成 handle は .group）
    port: PortRef, // 表示/ハイライト用は synthetic 可（畳み箱ポート）。dyn/commit へ渡す前に resolvePort で実 PortRef へ解決する
    cable: CableRef, // 安定 ID（dst_handle,dst_in）。常に実 CableRef（DisplayEdge.actual 経由）
    group: group.GroupId, // 畳み箱 or 展開枠のヘッダーの選択
};

const Drag = union(enum) {
    none,
    pan: struct { start_pan: Vec2f, start_mouse: Vec2f },
    node: struct { handle: Handle, grab_offset: Vec2f }, // node.pos = mouseWorld + grab_offset（常に実 handle）
    // 畳み箱ドラッグ: ledger.groups[gid].pos を更新し layout には触らない（合成 handle を app.layout[h] へ
    // 絶対に index しない。展開時の枠ヘッダーはドラッグ不可＝選択のみ、40.7.1 のスコープ）。
    group: struct { gid: group.GroupId, grab_offset: Vec2f },
    // 接続 pending（origin ポートからカーソルへ仮ケーブル）。detach!=null は「接続済み入力から
    // 拾い上げた drag-off」で、切断は commit（mouse_up）まで遅延する（1 操作=最大 1 publish・
    // 失敗/無効ドロップで既存接続を壊さない）。origin は表示/ハイライト用に synthetic 可（畳み箱ポートを
    // 掴んだ場合）。commit（mouse_up）で dyn/commitConnect へ渡す前に resolvePort で実 PortRef へ解決する。
    // detach は接続済み入力を掴んだときのみ設定され、その時点で resolvePort 済み＝常に実 CableRef。
    cable: struct { origin: PortRef, detach: ?CableRef = null },
};

// モジュールパレット（画面固定・pan/zoom 非依存）。クリックで primitive は add(kind,.{})、macro は
// マクロ builder（preflight+add+connect+1publish→台帳登録）を呼ぶ（TASK-40.7.1）。
const PaletteEntry = union(enum) {
    primitive: modular.ModuleKind,
    macro_kind: group.MacroKind,
    /// TASK-133: bass kind の standalone step_seq（既存 `.primitive = .step_seq` は drum のまま）。
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

// ── File メニュー（TASK-136）──────────────────────────────────────────────
// GUI fallback 行の高さ（box padding 4+4 + button ≈24）。native 時は OS メニューバーのため 0。
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

// TASK-149.3: History 表示用 local-only meta ring（CommandLog に入らない操作）。
const MAX_META_EVENTS: usize = 64;
const META_SUMMARY_CAP: usize = 96;
const HISTORY_LINE_CAP: usize = 160;
const HISTORY_SCROLL_ID: gui.Id = 0x1493_0001;
const MetaEvent = struct {
    /// 追加時点の cmd_log 最新 seq（0=コマンド未記録）。merge 表示の順序キー。
    after_seq: u64 = 0,
    summary_buf: [META_SUMMARY_CAP]u8 = undefined,
    summary_len: u8 = 0,

    fn summary(self: *const MetaEvent) []const u8 {
        return self.summary_buf[0..self.summary_len];
    }
};

/// canvas 幅に収まる列数（button.x + button.w <= canvas_w。最大 PAL_COLS_MAX）。
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

/// パレット帯の下端（screen 絶対座標。行数は center 幅依存。clampMacroPos の上限に使う）。
fn paletteBottom(app: *const App) f32 {
    const rows: f32 = @floatFromInt(paletteRowCount(app.canvasW()));
    return app.canvas_rect.y + PAL_Y + rows * (PAL_H + PAL_GAP);
}

/// center rect 基準のモジュールパレット（screen 絶対座標）。
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

fn cutoffHz(norm: f32) f32 {
    return param_view.cutoffHz(norm, conversion());
}

fn conversion() param_view.Conversion {
    return .{
        .cutoff_min = CUTOFF_MIN,
        .cutoff_max = CUTOFF_MAX,
        .kick_base_gain = patchmod.KICK_BASE_GAIN,
        .hat_base_gain = patchmod.HAT_BASE_GAIN,
        .clap_base_gain = patchmod.CLAP_BASE_GAIN,
        .pad_base_gain = patchmod.PAD_BASE_GAIN,
    };
}

fn publishControls(patch: *LofiPatch, p: Params) void {
    const c = &patch.controls;
    c.tempo_bpm.store(p.tempo);
    c.master_cutoff.store(cutoffHz(p.cutoff_norm));
    c.density_target.store(p.density);
    c.swing.store(p.swing);
    c.sidechain_amount.store(p.sidechain);
    c.kick_gain.store(p.kick_gain);
    c.hat_gain.store(p.hat_gain);
    c.clap_gain.store(p.clap_gain);
    c.bass_gain.store(p.bass_gain);
    c.pad_gain.store(p.pad_gain);
    c.kick_mute.store(@intFromBool(p.kick_mute), .release);
    c.hat_mute.store(@intFromBool(p.hat_mute), .release);
    c.clap_mute.store(@intFromBool(p.clap_mute), .release);
    c.bass_mute.store(@intFromBool(p.bass_mute), .release);
    c.pad_mute.store(@intFromBool(p.pad_mute), .release);
    c.kick_punch.store(p.kick_punch);
    c.hat_bright.store(p.hat_bright);
    c.hat_decay.store(p.hat_decay);
    c.pad_cutoff.store(p.pad_cutoff);
    c.pad_warmth.store(p.pad_warmth);
    c.master_warmth.store(p.master_warmth);
    c.ambient_move.store(p.ambient_move);
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

/// TASK-106.4: inspector slider の drag 開始時 before 値を保持し、release 時に 1 つの
/// undoable な set_param として記録する（drag 中の連続 override は記録しない）。
const App = struct {
    /// 生成レイヤと DynGraph の唯一の所有者。patch 自体は heap 上で固定し、RT userdata から動かさない。
    patch: *LofiPatch,
    /// canvas の既存コードが参照する非所有 alias。実体は常に patch.graph。
    dyn: *DynGraph,
    layout: [MAX_MODULES]Vec2f = [_]Vec2f{.{ .x = 0, .y = 0 }} ** MAX_MODULES,
    ledger: group.Ledger = .{},
    camera: Camera = .{},
    mouse: Vec2f = .{ .x = 0, .y = 0 },
    hover: ?Item = null,
    selected: ?Item = null,
    /// TASK-149.2: Inspector 用 drill-down target（canvas selected とは独立）。
    /// group 選択時は member 選択で埋まり、node 選択時は selected node と一致。
    inspector_target: ?Handle = null,
    drag: Drag = .none,
    fb_w: u32 = WIN_W,
    fb_h: u32 = WIN_H,
    // TASK-149.1: PanelHost が Transport(bottom)/Inspector(right) の外形・open/visible の正。
    // ポインタは main の stack 上 host/panels/gui_ctx を指す（App より長く生きる）。
    panel_host: *gui.PanelHost = undefined,
    panels: []gui.Panel = &.{},
    gui_ctx: *gui.Context = undefined,
    /// PanelHost center rect（screen 絶対座標）。描画・hit・palette・camera の共通原点。
    canvas_rect: canvas.ScreenRect = .{ .x = 0, .y = 0, .w = WIN_W, .h = WIN_H - VIS_H },
    // TASK-125: H キー全 hide。slot visible の一時 override。解除時に pre_hide_* を復元し open は保持。
    panels_hidden: bool = false,
    pre_hide_left_visible: bool = true,
    pre_hide_right_visible: bool = true,
    pre_hide_bottom_visible: bool = true,
    // TASK-149.3: History panel ScrollArea と local-only meta ring。
    history_scroll: gui.Vec2f = .{},
    meta_events: [MAX_META_EVENTS]MetaEvent = [_]MetaEvent{.{}} ** MAX_META_EVENTS,
    meta_head: u32 = 0,
    meta_filled: u32 = 0,
    // appshell Preferences（panel/slot 永続化。VP_APPSHELL_DIR 対応）。
    prefs: appshell.preferences.Preferences = undefined,
    prefs_dir: ?std.Io.Dir = null,
    prefs_dirty: bool = false,

    // TASK-40.8 C: master 出力タップ + 直近ブロックの rms/peak（viz probe 用。GUI スレッド更新）。
    tap: Tap = .{},
    master_rms: f32 = 0,
    master_peak: f32 = 0,

    // TASK-40.8 A: 出力ポート活性度の peak-hold（GUI ローカル・RT 影響ゼロ）。[handle][out]。
    port_level: [MAX_MODULES][MAX_OUT]f32 = [_][MAX_OUT]f32{[_]f32{0} ** MAX_OUT} ** MAX_MODULES,

    // TASK-40.8 D: per-port tap 状態（GUI 所有）。slot i は tap_display[i]（描画用 display handle）を
    // tap_ports[i]（実 global port id・-1=空き）へ写す。tap_slot_seq[i] = その割当を publish した seq。
    tap_display: [TAP_SLOTS]Handle = [_]Handle{0} ** TAP_SLOTS,
    tap_ports: [TAP_SLOTS]i32 = [_]i32{-1} ** TAP_SLOTS,
    tap_slot_seq: [TAP_SLOTS]u32 = [_]u32{0} ** TAP_SLOTS,
    tap_count: usize = 0,
    tap_seq: u32 = 0,

    /// `save_graph`/`load_graph` action（TASK-65 serialize）が使うファイル I/O ハンドル
    /// （`std.process.Init.io`。イベント時のみ使用。RT 経路には一切渡さない）。
    io: std.Io,

    // 生成アプリの command/action 状態（action はイベント時のみ）。
    params: Params = .{},
    pattern_rev: u32 = 0,
    /// main thread が最後に publish した pattern。RT が Mailbox を acquire する前の連続編集でも、
    /// 次の pattern action が RT snapshot を基底にして先行編集を捨てないために使う。
    pending_pattern: ?PatternCommand = null,
    sample_rate: u32 = 48000,
    cmd_log: platform.command.CommandLog = .{},
    cmd_exec: platform.command.Executor = undefined,
    recipe_replaying: bool = false,
    notation_seed: u64 = seedmod.DEFAULT_BASE_SEED,
    notation_counter: u32 = 0,
    last_quantized_cmd: ?PatternCommand = null,
    song: SongData = .{},
    // TASK-110.4: main thread が所有する累積 override 表（Mailbox payload の source）。
    param_batch: patchmod.ParamBatch = .{},
    // TASK-124: field 単位で transport/inspector が共有する pending 操作値。
    param_edits: [MAX_PARAM_EDITS]param_view.ParamEditState = [_]param_view.ParamEditState{.{}} ** MAX_PARAM_EDITS,
    // params probe の observed は既定で transport cutoff canonical field。action observe_param で切替可能。
    observed_field: param_view.FieldKey = .{},
    frame_snapshots: [MAX_PARAM_EDITS]FrameParamSnapshot = [_]FrameParamSnapshot{.{}} ** MAX_PARAM_EDITS,
    frame_snapshot_count: usize = 0,
    param_rows: [MAX_PARAM_EDITS]ParamRowSnapshot = [_]ParamRowSnapshot{.{}} ** MAX_PARAM_EDITS,
    param_row_count: usize = 0,

    // TASK-106.2: 安定 NodeId（relay/保存/digest）。runtime Handle とは分離・単調・再利用なし。
    next_node_id: u64 = 1,
    handle_to_id: [MAX_MODULES]?graph_io.NodeId = [_]?graph_io.NodeId{null} ** MAX_MODULES,
    // TASK-106.1: host が最後に pattern_state で配った mutation_count（変化検出用）。
    last_pattern_state_mut: u32 = 0,
    // TASK-106.1: 直前 frame の peer 数。増加時は join 強制 pattern_state 配信。
    last_broadcast_peer_count: usize = 0,

    // TASK-106.4: 固定長 undo payload（CommandLog.undo_ref = gen）。~1.16MiB のため heap（Windows 1MB stack 回避）。
    undo_store: *patch_undo.PatchUndoStore,
    /// inspector slider release 時に set_param へ渡す before-state（drag 中に埋める）。
    pending_param_undo_before: ?patch_undo.ParamValueSnap = null,
    /// inspector drag 開始時の before 捕捉（release で pending_param_undo_before へ移す）。
    /// 単一 Optional: 同時に複数 slider を drag する UI は無く、1 本分のみ保持する制約。
    slider_drag_before: ?patch_undo.ParamValueSnap = null,

    // TASK-136: File メニュー（native NSMenu / GUI fallback）+ dialog 経由 save/load。
    menu_commands: [MENU_CMD_CAP]platform.Command = undefined,
    menu_command_count: usize = 0,
    menu_bar_state: gui.MenuBarState = .{},
    native_menu_active: bool = false,
    pending_menu_op: ?MenuFileOp = null,
    menu_last_op: ?MenuFileOp = null,
    running: bool = true,

    /// GUI fallback メニュー行の高さ。native 有効時は OS メニューバーに任せて 0。
    fn menuTopH(self: *const App) f32 {
        return if (self.native_menu_active) 0 else MENU_GUI_H;
    }

    fn pointInMenuBar(self: *const App) bool {
        return !self.native_menu_active and self.mouse.y < self.menuTopH();
    }

    /// PanelHost center の幅（canvas viewport）。見切れ判定・hit・tap・palette で共通。
    fn canvasW(self: *const App) f32 {
        return @max(0.0, self.canvas_rect.w);
    }

    /// PanelHost center の高さ（canvas viewport）。
    fn canvasH(self: *const App) f32 {
        return @max(0.0, self.canvas_rect.h);
    }

    /// 画面下端可視化帯の y 開始（絶対座標。VIS_H は PanelHost の外）。
    fn vizBandY0(self: *const App) f32 {
        const fh: f32 = @floatFromInt(self.fb_h);
        return @max(0.0, fh - VIS_H);
    }

    /// screen 絶対 → center ローカル（camera 空間）。
    fn toCanvasLocal(self: *const App, screen: Vec2f) Vec2f {
        return .{ .x = screen.x - self.canvas_rect.x, .y = screen.y - self.canvas_rect.y };
    }

    /// center ローカル → screen 絶対。
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

    /// PanelHost hit が center のときのみ canvas 操作を許可（panel/splitter/outside は遮断）。
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
            self.pre_hide_bottom_visible = self.panel_host.slotVisible(.bottom);
            self.panel_host.setSlotVisible(.left, false);
            self.panel_host.setSlotVisible(.right, false);
            self.panel_host.setSlotVisible(.bottom, false);
            self.panels_hidden = true;
        } else {
            self.panel_host.setSlotVisible(.left, self.pre_hide_left_visible);
            self.panel_host.setSlotVisible(.right, self.pre_hide_right_visible);
            self.panel_host.setSlotVisible(.bottom, self.pre_hide_bottom_visible);
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
        // i: 0 = 最古 … filled-1 = 最新
        const idx = (self.meta_head + MAX_META_EVENTS - self.meta_filled + i) % MAX_META_EVENTS;
        return &self.meta_events[idx];
    }

    fn historyBodyAvail(self: *const App) i32 {
        if (self.panel_host.panelRect(self.gui_ctx, "History")) |r| {
            return @max(1, @as(i32, @intCast(r.w)) - 16);
        }
        return @max(1, self.panel_host.slotExtent(.left) - 24);
    }

    fn historyBodyHeight(self: *const App) i32 {
        if (self.panel_host.panelRect(self.gui_ctx, "History")) |r| {
            return @max(40, @as(i32, @intCast(r.h)) - 28);
        }
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

    /// Inspector body 外側幅（panel rect − 余白）。初回は right slot extent ベース。
    /// Collapsible body は fit のため、drawBody へ .fixed 注入する（grow-in-fit collapse 回避）。
    fn inspectorBodyAvail(self: *const App) i32 {
        if (self.panel_host.panelRect(self.gui_ctx, "Inspector")) |r| {
            return @max(1, @as(i32, @intCast(r.w)) - 16);
        }
        return @max(1, self.panel_host.slotExtent(.right) - 24);
    }

    /// Transport body 外側幅（panel rect − 余白）。bottom の extent は高さなので
    /// 初回 fallback は slotRect または fb 幅概算。
    fn transportBodyAvail(self: *const App) i32 {
        if (self.panel_host.panelRect(self.gui_ctx, "Transport")) |r| {
            return @max(1, @as(i32, @intCast(r.w)) - 16);
        }
        if (self.panel_host.slotRect(self.gui_ctx, .bottom)) |r| {
            return @max(1, @as(i32, @intCast(r.w)) - 24);
        }
        return @max(1, @as(i32, @intCast(self.fb_w)) - 40);
    }

    /// 旧 TASK-123/125 digest キー互換: !visible→hidden / visible&&!open→closed / else open。
    fn panelStateName(self: *const App, name: []const u8) []const u8 {
        const p = self.findPanel(name) orelse return "hidden";
        if (!p.visible) return "hidden";
        if (!p.open) return "closed";
        return "open";
    }

    /// selected と整合するよう inspector_target を毎フレーム同期（stale は null）。
    fn syncInspectorTarget(self: *App) void {
        if (self.inspector_target) |t| {
            if (t >= MAX_MODULES or !self.dyn.slotActive(t)) {
                self.inspector_target = null;
            }
        }
        if (self.selected) |item| {
            switch (item) {
                .node => |h| {
                    // primitive 選択は target をその handle に固定。
                    self.inspector_target = h;
                },
                .group => |gid| {
                    // group 選択: target は当該 group の active member のときだけ維持。
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

    /// descriptor を表示する実 handle（params モード）。member list 中は null。
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

    /// group の active member を handle 昇順で out へ（alloc なし）。
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
        // ghost marker は scalar row のみ（choice radio は除外）。
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
        // entry ごとに記録する。1 操作 = 1 record の coalesce は dragging→release で既に担保
        // （drag 中の中間値は pending 更新のみで CommandLog に載せない）。
        // 旧 committed 共有ガードは「同一呼び出し内の別 slot の記録を黙って落とす」誤動作だった。
        for (&self.param_edits) |*state| {
            const was_dragging = state.dragging;
            state.release();
            if (!was_dragging) continue;
            if (before) |b| {
                // Inspector slider: NodeId 形式で set_param（queueParamOverride 経路）。
                if (b.mode != 1 or state.key.invalid()) continue;
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
                // recordedAction 経由で CommandLog へ 1 record。
                routeUiAction(self, "set_param", args);
            } else if (state.pending) |pv| {
                // Transport slider: alias 名 2 トークン形式（setParamAndPublish 経路と一致）。
                // density は FieldKey.handle==INVALID でも alias 経由で記録する（invalid() で落とさない）。
                const alias = transportAliasForKey(self, state.key) orelse continue;
                const raw_canonical: f32 = switch (pv) {
                    .scalar => |v| v,
                    .choice => |idx| @floatFromInt(idx),
                };
                // pending は canonical。setParamAndPublish は UI 値を期待するので toUi で戻す。
                const ui = param_view.toUi(alias, raw_canonical, conversion());
                var args_buf: [128]u8 = undefined;
                const args = std.fmt.bufPrint(&args_buf, "{s} {d}", .{ @tagName(alias), ui }) catch continue;
                recordGuiAction(self, "set_param", args);
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

    /// 実 handle の生ノード列（dyn 由来。合成 handle は含まない）。フレーム毎。
    /// selected な step_seq（standalone / 展開中 group member）に inline grid 用 grid_rows を付与する。
    /// collapsed group の member は mapNodesForCollapsed で箱へ隠れるため従来どおり macro grid のみ（TASK-133）。
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

    /// 表示用ノード列（フレーム毎。collapsed グループのメンバーは箱 1 個に畳まれる。写像は
    /// group.Ledger.mapNodesForCollapsed に委譲。§3.1/§3.3）。
    fn buildNodes(self: *const App, out: []NodeGeom) usize {
        var raw_buf: [MAX_MODULES]NodeGeom = undefined;
        const raw = raw_buf[0..self.buildRawNodes(&raw_buf)];
        return self.ledger.mapNodesForCollapsed(raw, out);
    }

    /// flat edge（実 handle のみ。view.in_src をそのまま並べたもの）。deriveExposed・境界判定・
    /// edgeForInput/commitConnect はこの flat を読む（合成 handle を混ぜない。§3.3）。
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

    /// 表示用 edge 列（フレーム毎。collapsed グループの境界を箱ポートへ写像。描画/ヒットテスト/選択に使う）。
    fn buildDisplayEdges(self: *const App, out: []group.DisplayEdge) usize {
        var flat_buf: [MAX_EDGES]Edge = undefined;
        const flat = flat_buf[0..self.buildFlatEdges(&flat_buf)];
        return self.ledger.buildDisplayEdges(flat, out);
    }

    /// 展開中の group のヘッダー（タイトル+トグルのみ。ポート無し n_in=n_out=0）。collapsed な group は
    /// buildNodes 側の箱に既に含まれるのでここには出さない。フレーム毎（group 数個規模）。
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

    /// イベント時のみ。接続が変わるたびに全 active group の expose 表を再導出する（group 数<=8 なので
    /// 毎回全走査しても安い。deriveExposed は実 handle edge のみを事前条件とする＝flat edge を渡す）。
    fn refreshAllExposed(self: *App) void {
        var flat_buf: [MAX_EDGES]Edge = undefined;
        const flat = flat_buf[0..self.buildFlatEdges(&flat_buf)];
        for (self.ledger.groups, 0..) |g, i| {
            if (g.active) self.ledger.deriveExposed(@intCast(i), flat);
        }
    }

    // ── File メニュー（TASK-136）──────────────────────────────────────────
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
        // TASK-149.3: View → History（Cmd/Ctrl+Shift+H。modifier 無し H の全 hide と分離）。
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

    /// GUI fallback 環境のショートカット照合（native メニュー有効時は keyEquivalent が所有）。
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

    /// 拡張子欠落時に `.vprj` を付加（dialog 戻り path。caller が free）。
    fn ensureVprjExt(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
        if (path.len >= 5 and std.ascii.eqlIgnoreCase(path[path.len - 5 ..], ".vprj")) {
            return gpa.dupe(u8, path);
        }
        return std.fmt.allocPrint(gpa, "{s}.vprj", .{path});
    }

    /// framebuffer unlock 後の安全点で pending File 操作を実行（dialog は lock 中禁止）。
    fn runPendingMenuFileOp(self: *App) void {
        const op = self.pending_menu_op orelse return;
        self.pending_menu_op = null;
        const gpa = std.heap.c_allocator;
        switch (op) {
            .save_project => {
                const maybe = platform.saveFileDialog(gpa, self.io, .{
                    .default_name = "untitled.vprj",
                    .allowed_ext = "vprj",
                }) catch return; // DialogFailed（headless）等は無視して RT 継続
                const path = maybe orelse return;
                defer gpa.free(path);
                const final_path = ensureVprjExt(gpa, path) catch return;
                defer gpa.free(final_path);
                actionSaveProjectFile(self, final_path) catch {};
            },
            .open_project => {
                const maybe = platform.openFileDialog(gpa, self.io, .{ .allowed_ext = "vprj" }) catch return;
                const path = maybe orelse return;
                defer gpa.free(path);
                // actionLoadProject と同じ経路（args = path）を呼ぶ。
                var buf: [256]u8 = undefined;
                _ = actionLoadProject(self, path, &buf) catch {};
            },
        }
    }
};

// RT audio callback: dyn.processBlock のみ（同期/alloc/lock/IO/panic なし）。facade が audio probe を自動 tap。
// C 用の master 可視化タップ（SampleTap.write。空き不足は丸ごと drop・非ブロッキング。RT 実績パターン）。
fn audioCallback(buf: []f32, frames: u32, channels: u32, sample_rate: u32, userdata: ?*anyopaque) void {
    _ = sample_rate;
    const app: *App = @ptrCast(@alignCast(userdata orelse {
        @memset(buf, 0);
        return;
    }));
    app.patch.render(buf, frames, channels);
    if (channels == 2) app.tap.write(buf);
}

// ============================================================================
// 描画ヘルパー
// ============================================================================
/// f32 screen 座標 → i32（NaN/Inf/範囲外を安全化。極端 zoom/pan で panic させない）。
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

/// 水平スパンで塗る簡易な塗り円（DrawList に circle が無いため）。半径は呼び出し側で 3..10 に clamp 済み。
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

    // ケーブル（ノードの下）。visual（写像済み）端点で描画し、選択/hover 判定は actual（実 CableRef）で行う
    // （合成 handle は描画座標の中だけで使う）。座標は center origin を加えた screen 絶対。
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

    // ノード + ポート（畳み箱＝合成 handle はタイトル/ポート種別を台帳経由で解決。box handle は dyn へ
    // 直接渡さない＝§3.1 の閉じ込め）。
    for (nodes) |g| {
        const tl = app.worldToAbs(g.pos);
        const sz = canvas.nodeSize(g).scale(cam.zoom);
        const rect = toRect(tl, sz);
        dl.rectFilled(rect, NODE_BG) catch {};
        const selected = itemIsHandle(app.selected, g.handle);
        const hovered = itemIsHandle(app.hover, g.handle);
        const border = if (selected) SEL_COL else if (hovered) HOVER_COL else BORDER_COL;
        dl.rectOutline(rect, border, if (selected) 2 else 1) catch {};
        dl.text(.{ .x = rect.x + 6, .y = rect.y + 4 }, nodeTitle(app, g.handle), TITLE_COL) catch {};
        if (group.groupIdFromHandle(g.handle)) |gid| {
            drawToggle(app, dl, g, true); // 畳み箱は常に collapsed 側
            drawMacroGrid(app, dl, g, gid); // 本体に TR/303 grid + playhead（TASK-40.7.2）
        } else if (g.grid_rows > 0) {
            // selected standalone step_seq の inline grid（TASK-110.2。マクロ箱経路とは分離）
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
            // A: 出力ポート丸を活性度で明滅（peak-hold + decay。RT 影響ゼロ）。活性時は halo を先に、その上に明るい dot。
            const lvl = outPortLevel(app, g.handle, i);
            const base = portColor(kind);
            if (lvl > 0.12) fillCircle(dl, p, r + 2, litColor(base, lvl * 0.5));
            fillCircle(dl, p, r, litColor(base, lvl));
            if (hoverPort(app, g.handle, false, i)) dl.rectOutline(portBox(p, r), HOVER_COL, 1) catch {};
        }
    }

    // 展開中グループの薄い枠（矩形+タイトル+トグル）。中身の grid 描画は 40.7.2。
    for (app.ledger.groups, 0..) |gr, gi| {
        if (!gr.active or gr.collapsed) continue;
        drawExpandedGroupFrame(app, dl, nodes, @intCast(gi), gr);
    }

    // D: tap 中ポートのミニ oscilloscope（ノード直下）。
    drawMiniScopes(app, dl, nodes);

    // pending cable（接続 drag 中: origin ポート → カーソル）
    if (app.drag == .cable) {
        const origin = app.drag.cable.origin;
        if (portScreenPos(app, nodes, origin)) |op| {
            dl.line(vec2i(op), vec2i(app.mouse), PENDING_COL, 2) catch {};
        }
    }

    // モジュールパレット（center rect 基準オーバーレイ。PanelHost panel にはしない）。
    const buttons = paletteButtons(app);
    for (buttons) |btn| {
        const rect = gui.Rect{ .x = safeI32(btn.rect.x), .y = safeI32(btn.rect.y), .w = safeU32(btn.rect.w), .h = safeU32(btn.rect.h) };
        const hov = canvas.hitTestPalette(app.mouse, &buttons) == btn.kind_index;
        dl.rectFilled(rect, if (hov) PAL_BG_HOVER else PAL_BG) catch {};
        dl.rectOutline(rect, BORDER_COL, 1) catch {};
        dl.text(.{ .x = rect.x + 6, .y = rect.y + 5 }, paletteLabel(PALETTE[btn.kind_index]), TITLE_COL) catch {};
    }
}

/// origin ポートの screen 絶対位置（node が消えていれば null）。pending cable 描画用。
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

/// selected/hover の Item が handle h（実ノード or 畳み箱/枠ヘッダーの合成 handle）を指しているか。
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

/// ノードタイトル文字列。畳み箱/枠ヘッダー（合成 handle）は台帳の MacroKind 名、実ノードは dyn.kindOf。
fn nodeTitle(app: *const App, h: Handle) []const u8 {
    if (group.groupIdFromHandle(h)) |gid| return app.ledger.groups[gid].kind.displayName();
    if (app.dyn.kindOf(h)) |k| return @tagName(k);
    return "?";
}

/// 入力ポート種別。合成 handle（畳み箱）は exposed_in[i] の実メンバーポートを dyn.inKindOf で解決する
/// （box handle を dyn へ直接渡さない）。
fn portKindIn(app: *const App, h: Handle, i: u8) PortKind {
    if (group.groupIdFromHandle(h)) |gid| {
        const g = app.ledger.groups[gid];
        if (i < g.n_in) return app.dyn.inKindOf(g.exposed_in[i].member, g.exposed_in[i].port) orelse .audio;
        return .audio;
    }
    return app.dyn.inKindOf(h, i) orelse .audio;
}

/// 出力ポート種別。合成 handle（畳み箱）は exposed_out[i] の実メンバーポートを dyn.outKindOf で解決する。
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

/// 折り畳みトグル [±] を描画する（g は箱 or 枠ヘッダーの NodeGeom。collapsed で表示ラベルを切替）。
fn drawToggle(app: *const App, dl: *gui.DrawList, g: NodeGeom, collapsed: bool) void {
    const tl = app.worldToAbs(canvas.togglePos(g));
    const size = canvas.TOGGLE_SIZE * app.camera.zoom;
    const rect = gui.Rect{ .x = safeI32(tl.x), .y = safeI32(tl.y), .w = safeU32(size), .h = safeU32(size) };
    dl.rectFilled(rect, PAL_BG) catch {};
    dl.rectOutline(rect, BORDER_COL, 1) catch {};
    dl.text(.{ .x = rect.x + 3, .y = rect.y + 2 }, if (collapsed) "+" else "-", TITLE_COL) catch {};
}

/// 展開中グループの薄い枠（現在のメンバー配置の bbox 外周）+ ヘッダー（タイトル+トグル、group.pos アンカー）。
/// 中身（TR grid 等）の描画は 40.7.2。
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
    const hsel = itemIsHandle(app.selected, header.handle);
    dl.rectFilled(hrect, NODE_BG) catch {};
    dl.rectOutline(hrect, if (hsel) SEL_COL else BORDER_COL, if (hsel) 2 else 1) catch {};
    dl.text(.{ .x = hrect.x + 6, .y = hrect.y + 4 }, gr.kind.displayName(), TITLE_COL) catch {};
    drawToggle(app, dl, header, false);
}

// ============================================================================
// 畳みマクロ箱の TR/303 grid（TASK-40.7.2）。member は台帳経由で解決した実 handle のみを dyn.ptrOf へ渡し、
// mask/step は atomic load で読む（合成 handle を dyn へ渡さない規約踏襲）。フレーム毎（1 箱で最大 4 行×16 セル）。
// ============================================================================
const StepSeqPtr = *modular.StepSeq;

/// gid の step_seq メンバーを handle 昇順で最大 3 個集める（drum: [seqK, seqH, seqClap] / bass: [seq]）。
/// active + step_seq + 当該 gid 所属のみ（stale handle を弾く。台帳同期）。
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

/// クリック可能な mask 行数（drum は group metadata の lane 数、bass は on/accent/slide の 3 行）。
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

/// camera 変換済みの共通 grid geometry（macro box / standalone node 共用 adapter）。
fn gridGeometry(cam: Camera, box_pos: Vec2f) stepgrid.Geometry {
    return toStepgridGeometry(canvas.gridGeometry(cam, box_pos));
}

/// 描画用: center origin を加えた screen 絶対 grid geometry。
fn absGridGeometry(app: *const App, box_pos: Vec2f) stepgrid.Geometry {
    var g = gridGeometry(app.camera, box_pos);
    g.origin_x += app.canvas_rect.x;
    g.origin_y += app.canvas_rect.y;
    return g;
}

/// 畳み箱本体に TR grid（drum 2 レーン）/ 303 行（on/accent/slide + pitch 段）+ playhead を描く。
fn drawMacroGrid(app: *App, dl: *gui.DrawList, box: NodeGeom, gid: group.GroupId) void {
    const kind = app.ledger.groups[gid].kind;
    const seqs = collectStepSeqMembers(app, gid);
    if (seqs.n == 0) return;

    // playhead 列: process は現 step 評価後に step++ するので、直近発音した列は (step + STEPS-1) % STEPS。
    const head_seq: StepSeqPtr = app.dyn.ptrOf(.step_seq, seqs.items[0]);
    const playhead: u8 = (head_seq.loadStep() + stepgrid.STEP_COUNT - 1) % stepgrid.STEP_COUNT;
    const geometry = absGridGeometry(app, box.pos);

    switch (kind) {
        .drum_machine => {
            // 既存パレット macro は 2 レーン、生成 DrumMachine は 3 レーン。
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

/// 選択中 standalone step_seq の inline grid 描画（pattern_db 非経由・atomic load のみ。TASK-110.2）。
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

/// world 点がどの collapsed マクロ箱の grid セルに当たるか（クリック可能行のみ）。
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

/// selected step_seq の inline grid ヒット（mask 行のみ。pitch は対象外。
/// standalone / 展開中 group member 両方。collapsed member は表示されないのでここに来ない。TASK-133）。
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
        .bass => 3, // on/accent/slide。pitch(row 3) は表示専用
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

/// inline step_seq の mask トグル。生成 handle は patternEditBase → publishPatternCommand、
/// standalone は atomic accessor のみ（TASK-133）。
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

/// RT 未適用の直近 publish を編集基底にする。RT が rev を acquire 済みなら pending を破棄し、
/// evolve 等の RT authoritative な現在値へ戻す。quantize は呼び出し側が明示的に再設定する。
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

/// pattern を publish し、RT 未適用の最新 command を GUI 側へ保持する。
/// graph topology / RT view は変更せず、次の block 先頭で既存 applyControls() が取り込む。
fn publishPatternCommand(app: *App, cmd: PatternCommand) PatternCommand {
    var next = cmd;
    app.pattern_rev +%= 1;
    next.rev = app.pattern_rev;
    app.pending_pattern = next;
    if (!next.quantize_bar) app.last_quantized_cmd = null;
    app.patch.controls.pattern_db.publish(next);
    return next;
}

/// grid セルクリック → 生成 macro は PatternCommand、既存パレット macro は atomic accessor でトグル。
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
// 入力
// ============================================================================
fn edgeForInput(app: *const App, dst: Handle, dst_in: u8) ?Edge {
    var edge_buf: [MAX_EDGES]Edge = undefined;
    const edges = edge_buf[0..app.buildFlatEdges(&edge_buf)];
    for (edges) |e| {
        if (e.dst_handle == dst and e.dst_in == dst_in) return e;
    }
    return null;
}

/// world 点近傍のトグルを持つ group（畳み箱 or 展開枠ヘッダーの両方を見る）。
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

/// world 点近傍の展開枠ヘッダー（タイトル部分。ポートは無い）。
fn hitGroupHeader(app: *const App, world_pt: Vec2f) ?group.GroupId {
    var hdr_buf: [group.MAX_GROUPS]NodeGeom = undefined;
    const headers = hdr_buf[0..app.buildGroupHeaders(&hdr_buf)];
    if (canvas.hitTestNode(world_pt, headers)) |h| return group.groupIdFromHandle(h);
    return null;
}

/// 表示用ケーブル（visual 端点でヒットテストし、実 CableRef=actual を返す）。
fn hitTestDisplayCable(world_pt: Vec2f, nodes: []const NodeGeom, dedges: []const group.DisplayEdge) ?CableRef {
    var visual_buf: [MAX_EDGES]Edge = undefined;
    for (dedges, 0..) |de, i| visual_buf[i] = de.visual;
    if (canvas.hitTestCable(world_pt, nodes, visual_buf[0..dedges.len])) |idx| return dedges[idx].actual;
    return null;
}

fn updateHover(app: *App) void {
    // panel / splitter / outside / 可視化帯上ではキャンバスの hover を出さない。
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

/// `out_buf` に応答を書き、その slice を返す（失敗時 null。`proposed` / `ok id=#N` 等）。
fn routeUiActionInto(app: *App, name: []const u8, args: []const u8, out_buf: []u8) ?[]const u8 {
    _ = app;
    return platform.routeAction(name, args, out_buf) catch |err| {
        std.debug.print("patch: routeAction {s} 失敗: {s}\n", .{ name, @errorName(err) });
        return null;
    };
}

/// `ok id=#N` 応答なら NodeId → handle を解決して selected を設定（client の `proposed` は無視）。
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

/// パレット index → add_node / add_macro action（world 座標付き）。
fn routePaletteAdd(app: *App, ki: u8) void {
    const casc: f32 = @floatFromInt(app.dyn.activeCount() % 8);
    // center ローカル座標（camera 空間）で配置点を決める。
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
            // clamp 後の world を wire に載せる（peer 間で同一座標）
            const anchor: Vec2f = .{ .x = cx, .y = cy };
            // footprint は kind 固定 OFFSETS で概算（members 未確定のため header のみ近似）
            const fp = switch (mk) {
                .drum_machine => Vec2f{ .x = 450 + 80, .y = MACRO_HEADER_BAND + 120 },
                .bass_machine => Vec2f{ .x = 450 + 80, .y = MACRO_HEADER_BAND + 120 },
            };
            const pos = clampMacroPos(app, anchor, fp);
            var args_buf: [128]u8 = undefined;
            const args = std.fmt.bufPrint(&args_buf, "{s} {d} {d}", .{ @tagName(mk), pos.x, pos.y }) catch return;
            // solo/host: actionAddMacro 内で selected=.group を設定。client proposed は未選択のまま。
            _ = routeUiActionInto(app, "add_macro", args, &resp_buf);
        },
        .step_seq_bass => {
            const pos = app.camera.screenToWorld(.{ .x = cx, .y = cy });
            var args_buf: [128]u8 = undefined;
            // wire トークン `step_seq_bass`（drum の `step_seq` と分離。全 peer 同一 COMMIT args）。
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
    }
    app.drag = .none;
}

/// 接続を全事前検証してから 1 publish で確定する。drag-off の旧接続(detach)も同じ commit で処理し、
/// 「1 操作=最大 1 publish」「無効/失敗時は既存接続を壊さない」を守る（切断を先行させない）。
/// a/b/detach は常に実 PortRef/CableRef（呼び出し側が resolvePort 済み。合成 handle はここに来ない）。
/// TASK-106.2: UI は routeCommitConnect → `connect` action。同等ロジックは `actionConnect` に集約。
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

fn onMouseDown(app: *App) void {
    // panel / splitter / outside の mouse は GUI Context 側へ渡す。canvas と競合させない。
    if (!app.allowsCanvasInput()) return;
    // パレットは screen 絶対座標で world hit より先に判定（TASK-106.2: action route 経由）。
    const buttons = paletteButtons(app);
    if (canvas.hitTestPalette(app.mouse, &buttons)) |ki| {
        routePaletteAdd(app, ki);
        return;
    }
    const mw = app.mouseWorld();

    // 折り畳みトグル [±] はノード本体のクリックより優先する（畳み箱 / 展開枠ヘッダーの両方）。
    if (hitToggle(app, mw)) |gid| {
        app.ledger.groups[gid].collapsed = !app.ledger.groups[gid].collapsed;
        app.selected = .{ .group = gid };
        app.hover = null;
        app.drag = .none;
        return;
    }

    // 畳み箱本体の TR/303 grid セルクリック → mask ビットトグル（atomic store・publish 無し）。box 本体の
    // node hit（グループ drag 開始）より優先する。ポートは箱の左右端でグリッドと重ならない（順序不問だが先に処理）。
    if (hitMacroGrid(app, mw)) |hit| {
        toggleMacroGridCell(app, hit);
        app.selected = .{ .group = hit.gid };
        app.drag = .none;
        return;
    }

    // selected step_seq の inline grid（standalone / 展開中 member。TASK-133）。port/node drag より前。
    // ヒット時は mask toggle のみ・selected 維持・node drag を開始しない。
    if (hitInlineStepSeqGrid(app, mw)) |hit| {
        toggleInlineStepSeqCell(app, hit);
        app.selected = .{ .node = hit.handle };
        app.drag = .none;
        return;
    }

    var node_buf: [MAX_MODULES]NodeGeom = undefined;
    var edge_buf: [MAX_EDGES]group.DisplayEdge = undefined;
    const nodes = node_buf[0..app.buildNodes(&node_buf)];
    const dedges = edge_buf[0..app.buildDisplayEdges(&edge_buf)];
    if (canvas.hitTestPort(mw, nodes)) |pr| {
        // pr は as-hit の PortRef（畳み箱ポートなら合成 handle）。選択/pending 描画にはそのまま使い
        // （box のポート dot をハイライトするため）、実接続の判定・変更にだけ resolvePort を通す。
        app.selected = .{ .port = pr };
        if (app.ledger.resolvePort(pr)) |real| {
            if (real.is_input) {
                if (edgeForInput(app, real.handle, real.index)) |e| {
                    // 接続済み入力からの drag-off: その元出力から pending を張り、切断は commit(mouse_up)まで遅延。
                    app.drag = .{ .cable = .{
                        .origin = .{ .handle = e.src_handle, .is_input = false, .index = e.src_out },
                        .detach = .{ .dst_handle = real.handle, .dst_in = real.index },
                    } };
                    return;
                }
            }
        }
        app.drag = .{ .cable = .{ .origin = pr } }; // 出力 or 未接続入力から pending 開始
    } else if (canvas.hitTestNode(mw, nodes)) |h| {
        if (group.groupIdFromHandle(h)) |gid| {
            // 畳み箱本体のドラッグ: ledger.groups[gid].pos を更新し、app.layout には触らない
            // （合成 handle を app.layout[h] へ絶対に index しない）。
            app.selected = .{ .group = gid };
            app.drag = .{ .group = .{ .gid = gid, .grab_offset = app.ledger.groups[gid].pos.sub(mw) } };
        } else {
            app.selected = .{ .node = h };
            const npos = app.layout[h];
            app.drag = .{ .node = .{ .handle = h, .grab_offset = npos.sub(mw) } };
        }
    } else if (hitGroupHeader(app, mw)) |gid| {
        // 展開枠ヘッダー本体のクリック: 選択のみ（40.7.1 はドラッグ非対応）。
        app.selected = .{ .group = gid };
        app.drag = .none;
    } else if (hitTestDisplayCable(mw, nodes, dedges)) |actual| {
        app.selected = .{ .cable = actual };
    } else {
        app.selected = null;
        app.drag = .{ .pan = .{ .start_pan = app.camera.pan, .start_mouse = app.toCanvasLocal(app.mouse) } };
    }
}

/// マクロ展開時のメンバー相対配置（group.pos 基準の world offset）。y は展開ヘッダー（group.pos に
/// タイトル+[−]）とメンバーが重ならないよう MACRO_HEADER_BAND の下から始める。各 OFFSETS は
/// macro.zig の Handles 構造体のフィールド順と同順。
const MACRO_HEADER_BAND: f32 = 58;
const DRUM_OFFSETS = [_]Vec2f{
    .{ .x = 0, .y = MACRO_HEADER_BAND + 40 }, // cdiv（左・中段）
    .{ .x = 150, .y = MACRO_HEADER_BAND }, // seqK（上段）
    .{ .x = 150, .y = MACRO_HEADER_BAND + 80 }, // seqH（下段）
    .{ .x = 300, .y = MACRO_HEADER_BAND }, // kick（上段）
    .{ .x = 300, .y = MACRO_HEADER_BAND + 80 }, // hat（下段）
    .{ .x = 450, .y = MACRO_HEADER_BAND + 40 }, // mix（右・中段）
};
const BASS_OFFSETS = [_]Vec2f{
    .{ .x = 0, .y = MACRO_HEADER_BAND + 40 }, // seq（左・中段）
    .{ .x = 150, .y = MACRO_HEADER_BAND }, // vco（上段）
    .{ .x = 300, .y = MACRO_HEADER_BAND + 40 }, // vcf（中段）
    .{ .x = 150, .y = MACRO_HEADER_BAND + 80 }, // env（下段）
    .{ .x = 450, .y = MACRO_HEADER_BAND + 40 }, // vca（右・中段）
};

// LofiPatch が起動時に既に所有している生成 graph の展開時レイアウト。
// ここでは add/connect/publish を行わず、group.Ledger の UI 座標だけを設定する。
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

/// 生成 macro を既存 handle のまま台帳へ登録する（初期化時のみ）。
/// DynGraph の topology、publish 済み view、RT view には一切変更を加えない。
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

/// LofiPatch の生成 handle を DrumMachine/BassMachine として台帳へ登録する（初期化時のみ）。
/// 生成 builder を再実行しないため、DynGraph の node 数・handle・topology は不変のまま表示だけが macro 化される。
fn registerGeneratedMacros(app: *App) void {
    const drum_gid = app.ledger.alloc() orelse return;
    const bass_gid = app.ledger.alloc() orelse {
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
    // 共有 clock と外部 mixer/voice 境界を実 graph edge から再導出する。
    app.refreshAllExposed();
}

/// パレット index からモジュール or マクロを追加（comptime kind ディスパッチ）→ 画面中央付近へ配置 → publish。
fn addByPaletteIndex(app: *App, ki: u8) !void {
    const casc: f32 = @floatFromInt(app.dyn.activeCount() % 8);
    const cx: f32 = app.canvasW() * 0.45 + casc * 18;
    const cy: f32 = app.canvasH() * 0.4 + casc * 18;
    inline for (PALETTE, 0..) |entry, i| {
        if (i == ki) {
            switch (entry) {
                .primitive => |kind| {
                    // primitive は従来どおり（見切れ clamp なし＝挙動不変）。
                    const pos = app.camera.screenToWorld(.{ .x = cx, .y = cy });
                    const h = try app.dyn.add(kind, .{});
                    app.layout[h] = pos;
                    try app.dyn.publish();
                    _ = allocNodeId(app, h);
                    app.selected = .{ .node = h };
                },
                // macro は展開時 footprint が既定 fb に収まるよう screen anchor を clamp してから配置する。
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

/// マクロ展開サブグラフの footprint（group.pos 基準の world 幅・高さ）。header 箱 + 全メンバー node 実サイズを
/// 内包する bbox の右下端（左上端は必ず (0,0)）。members/offsets は同順・同長。
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

/// footprint を screen サイズ（world × zoom）に換算し、右下が fb 内に収まるよう anchor(screen) を clamp
/// してから world 座標へ（codex #4 と同型）。footprint が fb より広くても max が下限を割らないよう @max で保護。
fn clampMacroPos(app: *const App, anchor: Vec2f, fp: Vec2f) Vec2f {
    // anchor は center ローカル screen 座標。
    const zoom = app.camera.zoom;
    const margin: f32 = 16;
    const top_limit: f32 = (paletteBottom(app) - app.canvas_rect.y) + margin; // パレット帯下端（ローカル）
    const fbw: f32 = app.canvasW();
    const fbh: f32 = app.canvasH();
    const max_x = @max(margin, fbw - fp.x * zoom - margin);
    const max_y = @max(top_limit, fbh - fp.y * zoom - margin);
    const sx = std.math.clamp(anchor.x, margin, max_x);
    const sy = std.math.clamp(anchor.y, top_limit, max_y);
    return app.camera.screenToWorld(.{ .x = sx, .y = sy });
}

/// マクロ（DrumMachine / BassMachine）をパレットから追加する。preflight+add+connect+1publish は macro.zig が
/// 担い、publish 成功を確認してから台帳登録（group_of/exposed_in/out/collapsed=true）する（§3.2/§3.3）。
/// `anchor` は追加位置の screen 座標。展開時 footprint が既定 fb に収まるよう clamp してから配置する。
fn addMacro(app: *App, kind: group.MacroKind, anchor: Vec2f) !void {
    switch (kind) {
        .drum_machine => {
            const h = try macro.buildDrumMachine(app.dyn); // 失敗時は何も残らない（macro.zig 側の rollback）
            const members = [_]Handle{ h.cdiv, h.seq_k, h.seq_h, h.kick, h.hat, h.mix };
            for (members) |m| _ = allocNodeId(app, m);
            const gid = app.ledger.alloc() orelse {
                // 台帳枯渇（MAX_GROUPS 上限。極めて稀）: 公開済みメンバーを畳んで戻す（1 publish）。
                for (members) |m| {
                    clearNodeIdMapping(app, m);
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

/// wire `add_macro` 用: world 座標をそのまま group.pos に使う（clamp なし。peer 決定性のため）。
/// NodeId は常に `allocNodeId` の単調採番（redo も fresh id。pixie 同型）。
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

/// 選択中のノード/ケーブル/グループを削除（Delete/Backspace）。TASK-106.2: action route 経由。
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
                // remove_macro: member #id 一覧
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
            // pan/start_mouse は center ローカル screen 座標。
            const local = app.toCanvasLocal(app.mouse);
            app.camera.pan = p.start_pan.add(local.sub(p.start_mouse));
        },
        .node => |nd| {
            const mw = app.mouseWorld();
            app.layout[nd.handle] = mw.add(nd.grab_offset);
        },
        .group => |gd| {
            const mw = app.mouseWorld();
            app.ledger.groups[gd.gid].pos = mw.add(gd.grab_offset);
        },
        .cable => {}, // pending は app.mouse を使って毎フレーム描画（状態更新なし）
    }
}

// ============================================================================
// TASK-40.8 A/D: ポート活性度の更新 + tap 対象の選択・publish。
// ============================================================================
const MINI_BG = gui.Color.rgba(0x0A, 0x0E, 0x12, 0xFF);
// ミニスコープの表示サンプル数（間引き後）。トリガ探索の余地（残り窓）を残すため TAP_RING より小さくする。
// 128 点(間引き後)≒10.6ms は 110Hz(周期 9ms)なら 1 周期以上を探索範囲に含みロックできる。
const MINI_DISP: usize = 128;

/// selected/hover の Item から tap 優先度に使う display handle を取り出す（node/group のみ）。
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

/// display handle（実 or 合成箱）を実 global 出力 port id（handle*MAX_OUT+out）へ解決。out0 を代表とする。
/// 解決不能（出力なし/非 active/合成箱の expose なし）は -1。合成 handle を dyn へ渡さない規約を守る。
fn resolveTapPort(app: *const App, dh: Handle) i32 {
    if (group.groupIdFromHandle(dh)) |gid| {
        const g = app.ledger.groups[gid];
        if (g.n_out == 0) return -1;
        const ref = g.exposed_out[0];
        if (!app.dyn.slotActive(ref.member) or app.dyn.nOut(ref.member) <= ref.port) return -1;
        return @intCast(@as(u32, ref.member) * MAX_OUT + ref.port);
    }
    if (!app.dyn.slotActive(dh) or app.dyn.nOut(dh) == 0) return -1;
    return @intCast(@as(u32, dh) * MAX_OUT); // out0
}

/// display handle の出力ポート i の活性度（合成箱は exposed_out[i] の実メンバー活性度へ解決）。
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

/// フレーム毎: A（全出力ポート活性度の peak-hold 減衰）+ D（tap 対象選択・変化時のみ config publish）。
fn updateViz(app: *App) void {
    // A: 全 active ノードの出力ポート活性度を peak-hold + 減衰（RT 影響ゼロの sigLevel を読むだけ）。
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

    // D: tap 対象選択（viewport 内・上限 TAP_SLOTS・優先度）→ port 割当が変わった時だけ publish。
    var node_buf: [MAX_MODULES]NodeGeom = undefined;
    const nodes = node_buf[0..app.buildNodes(&node_buf)];
    var handles: [TAP_SLOTS]Handle = undefined;
    const sel = itemHandle(app.selected);
    const hov = itemHandle(app.hover);
    const n = canvas.selectTapPorts(app.camera, app.canvasW(), app.canvasH(), nodes, sel, hov, &handles);

    var new_ports: [TAP_SLOTS]i32 = [_]i32{-1} ** TAP_SLOTS;
    // ポート種別ごとに間引き率・reduce を決める（audio=細かい波形 / cv=粗い変調 / gate=粗い peak バー）。
    var new_decim: [TAP_SLOTS]u32 = [_]u32{modular.graph_core.TAP_DECIM} ** TAP_SLOTS;
    var new_peak: [TAP_SLOTS]bool = [_]bool{false} ** TAP_SLOTS;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        new_ports[i] = resolveTapPort(app, handles[i]);
        if (new_ports[i] < 0) continue;
        switch (portKindOut(app, handles[i], 0)) {
            .audio => {
                new_decim[i] = modular.graph_core.TAP_DECIM;
                new_peak[i] = false;
            },
            .cv => {
                new_decim[i] = modular.graph_core.TAP_DECIM_SLOW;
                new_peak[i] = false;
            },
            .gate => {
                new_decim[i] = modular.graph_core.TAP_DECIM_SLOW;
                new_peak[i] = true;
            },
        }
    }

    // 変化検出は port 割当のみで足りる（decim/peak は port の種別に従属＝port 不変なら不変）。
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
    // 描画用 display handle と本数は毎フレーム更新（ノード drag に座標追従。publish とは独立）。
    s = 0;
    while (s < n) : (s += 1) app.tap_display[s] = handles[s];
    app.tap_count = n;
}

/// tap 中の各ポートのミニ oscilloscope をノード直下に描く（フレーム毎・≤16 個 × 64×28px）。
/// applied_seq gate: RT が当該 slot の port 割当を反映済みでなければトレースを描かない（旧 port 混入防止）。
fn drawMiniScopes(app: *App, dl: *gui.DrawList, nodes: []const NodeGeom) void {
    const applied = app.dyn.tapAppliedSeq();
    var win: [TAP_RING]f32 = undefined;
    var slot: usize = 0;
    while (slot < app.tap_count) : (slot += 1) {
        if (app.tap_ports[slot] < 0) continue;
        const dh = app.tap_display[slot];
        const g = findNode(nodes, dh) orelse continue;
        const tl = app.worldToAbs(g.pos);
        const sz = canvas.nodeSize(g).scale(app.camera.zoom);
        const lr = canvas.miniScopeRect(tl, sz);
        const rect = gui.Rect{ .x = safeI32(lr.x), .y = safeI32(lr.y), .w = safeU32(lr.w), .h = safeU32(lr.h) };
        const kind = portKindOut(app, dh, 0);
        const col = portColor(kind);
        dl.rectFilled(rect, MINI_BG) catch {};
        dl.rectOutline(rect, col, 1) catch {};
        if (applied < app.tap_slot_seq[slot]) continue; // 未適用 slot は空窓（枠のみ）
        const nsamp = app.dyn.tapWindow(slot, &win);
        if (nsamp >= 2) {
            // audio は rising zero-crossing トリガで波形を静止（形が読みやすい・探索の余地に MINI_DISP 窓）。
            // cv/gate は非ロックで全窓を流す（gate=peak バーのタイミング、cv=ゆっくりした変調をなるべく長く見せる）。
            const disp = if (kind == .audio) @min(nsamp, MINI_DISP) else nsamp;
            const start = if (kind == .audio) canvas.findTriggerStart(win[0..nsamp], disp) else 0;
            drawMiniTrace(dl, rect, kind, win[start .. start + disp], col);
        }
    }
}

/// ミニスコープのトレース。audio は中央線基準(-1..1)の polyline、cv は下基準(0..1)の polyline、
/// gate は下基準のインパルス・バー（high の列を baseline から縦線で塗る＝疎なパルス列を見やすく）。
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
        // 疎なパルス列は polyline だと 1px スパイクで見えにくい → high の列を baseline から縦バーで塗る。
        // 列側から間引くと疎な high を取りこぼすので、全サンプルを走査して列へ写す（どの high も必ず 1 本になる）。
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
// C: master 出力の可視化帯（画面下端）。spectrogram / oscilloscope / level meter を直描き。
// 帯下地は @memset の一括塗り（不透明・行連続＝新設の全画素ループを書かない。性能規約）。
// spec/osc/meter.draw は apps/synth の既存実装の流用（新規全画素ループ無し）。フレーム毎。
// ============================================================================
const FreqLabel = struct { hz: f32, text: []const u8 };
const FREQ_LABELS = [_]FreqLabel{
    .{ .hz = 100, .text = "100Hz" },
    .{ .hz = 1000, .text = "1kHz" },
    .{ .hz = 10000, .text = "10kHz" },
};

fn drawVizBand(app: *const App, fb: platform.Framebuffer, spec: *const Spec, osc: *const Scope, meter: *const scope.LevelMeter) void {
    const fb_w = fb.width;
    // VIS_H は画面最下端固定。PanelHost center とは独立。
    const band_y0: usize = @intFromFloat(app.vizBandY0());
    if (band_y0 >= fb.height) return;
    // 帯下地: 行連続なので単一 @memset（全画素ループを書かない）。
    const start = band_y0 * fb_w;
    const end = fb.height * fb_w;
    if (start < end and end <= fb.pixels.len) @memset(fb.pixels[start..end], VIS_BG);

    const draw_y = band_y0 + VIS_LABEL_H;
    spec.draw(fb.pixels, fb_w, fb.height, SPEC_X0, draw_y);
    osc.draw(fb.pixels, fb_w, fb.height, SCOPE_X0, draw_y);
    meter.draw(fb.pixels, fb_w, fb.height, METER_X0, draw_y, METER_W, VIS_DRAW_H);

    // ラベル（帯上端の 16px 行）。
    const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb_w, .height = fb.height };
    const clip: gui.Rect = .{ .x = 0, .y = 0, .w = @intCast(fb_w), .h = @intCast(fb.height) };
    const label_col = gui.Color.rgba(0xC8, 0xD0, 0xD8, 0xFF);
    const ly: i32 = @intCast(band_y0 + 3);
    gui.default_bitmap_font.drawTo(target, .{ .x = SPEC_X0, .y = ly }, "SPECTROGRAM", label_col, clip);
    gui.default_bitmap_font.drawTo(target, .{ .x = SCOPE_X0, .y = ly }, "SCOPE (master)", label_col, clip);
    gui.default_bitmap_font.drawTo(target, .{ .x = @intCast(METER_X0), .y = ly }, "LVL", label_col, clip);

    // spectrogram の周波数目盛り。
    const tick_col: u32 = 0xFFFFFFFF;
    for (FREQ_LABELS) |fl| {
        const off = spec.rowOffsetForFreq(fl.hz) orelse continue;
        const tick_y = draw_y + off;
        if (tick_y >= fb.height) continue;
        var tx: usize = SPEC_X0;
        while (tx < SPEC_X0 + 6) : (tx += 1) {
            if (tx < fb_w) fb.pixels[tick_y * fb_w + tx] = tick_col;
        }
        gui.default_bitmap_font.drawTo(target, .{ .x = SPEC_X0 + 8, .y = @intCast(tick_y) }, fl.text, label_col, clip);
    }
}

pub fn main(init: std.process.Init) !void {
    std.debug.print("apps/patch: パッチキャンバス（drag=move/pan, scroll=zoom, ESC で終了）\n", .{});
    const allocator = std.heap.c_allocator;

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WIN_W, WIN_H, "patch canvas (modular)");
    defer window.destroy();

    // TASK-136: native menu facade は Window.create 直後に手動で 1 回（app_runtime へは移行しない）。
    // app は直後に stack 確定するので、menu 登録は app 初期化後に行う。

    // audio: open で sample rate を確定 → LofiPatch 構築 → 初期 publish → その後 start（初手から発音）。
    // RT callback は start 後にのみ発火するので、start 前に app を確定させれば安全（app は stack 固定・非ムーブ）。
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
    app.observed_field = param_view.keyFor(.cutoff, transportHandles(&app));
    // 生成グラフ全体を canvas に配置する（初期状態は 8 列の折り返し。Drum/Bass の
    // マクロ台帳は既存 canvas 操作に任せ、全モジュールを MAX_MODULES 内で可視化する）。
    var layout_h: Handle = 0;
    while (layout_h < MAX_MODULES) : (layout_h += 1) {
        if (!app.dyn.slotActive(layout_h)) continue;
        const col = layout_h % 8;
        const row = layout_h / 8;
        app.layout[layout_h] = .{ .x = 24 + @as(f32, @floatFromInt(col)) * 140, .y = 52 + @as(f32, @floatFromInt(row)) * 96 };
    }
    registerGeneratedMacros(&app);
    // 初期 graph の runtime handle 昇順で決定的に NodeId を割当（TASK-106.2）。
    assignInitialNodeIds(&app);

    // TASK-136: native menu（headless は false → GUI fallback）。
    app.rebuildMenuCommands();
    if (window.nativeMenuAvailable()) {
        app.native_menu_active = true;
        window.registerMenu(app.menuCommandsSlice());
    }
    defer if (app.native_menu_active) window.destroyMenu();

    var dl = gui.DrawList.init(allocator);
    defer dl.deinit();
    var gui_ctx = gui.Context.init(allocator, gui.default_font);
    defer gui_ctx.deinit();

    // TASK-149.1/149.3: PanelHost registry — History=left, Transport=bottom, Inspector=right。
    var panels = [_]gui.Panel{
        .{ .name = "History", .slot = .left, .build = buildHistoryPanel, .user_data = &app },
        .{ .name = "Transport", .slot = .bottom, .build = buildTransportPanel, .user_data = &app },
        .{ .name = "Inspector", .slot = .right, .build = buildInspectorPanel, .user_data = &app },
    };
    var panel_host = try gui.PanelHost.init(panels[0..], .{
        .left = .{ .extent = 220, .min_extent = 140, .max_extent = 400 },
        .right = .{ .extent = 280, .min_extent = 160, .max_extent = 480 },
        .bottom = .{ .extent = 250, .min_extent = 120, .max_extent = 400 },
        .min_center_width = 200,
        .min_center_height = 160,
    });
    app.panel_host = &panel_host;
    app.panels = panels[0..];
    app.gui_ctx = &gui_ctx;

    // appshell Preferences（panel/slot 永続化）。
    app.prefs = appshell.preferences.Preferences.init(allocator);
    const override_path = if (std.c.getenv("VP_APPSHELL_DIR")) |v| std.mem.span(v) else null;
    if (appshell.paths.openAppDataDir(app.io, allocator, "patch", override_path)) |dir| {
        app.prefs_dir = dir;
        _ = app.prefs.load(app.io, dir, "preferences.ash") catch {};
        panel_host.restore(panelPersistence(&app));
        // TASK-149.3 移行: 旧 prefs が left.visible=false（149.1 時代）だと History が永久に出ない。
        // History panel が visible なら left slot を有効化（個別 OFF は panel_toggle history）。
        if (app.panelVisible("History")) {
            panel_host.setSlotVisible(.left, true);
        }
    } else |err| {
        std.debug.print("apps/patch: preferences dir open failed: {s}\n", .{@errorName(err)});
    }

    // C: master 可視化（spectrogram/oscilloscope/level meter）。comptime サイズが大きいので heap 確保。
    const spec = try allocator.create(Spec);
    defer allocator.destroy(spec);
    spec.init(48000);
    spec.setSampleRate(sr);
    const osc = try allocator.create(Scope);
    defer allocator.destroy(osc);
    osc.* = .{};
    var meter = scope.LevelMeter{};

    platform.registerProbe(.{ .name = "patch", .ctx = &app, .ext = "json", .snapshot = patchSnapshot, .digest = patchDigest });
    platform.registerProbe(.{ .name = "group", .ctx = &app, .ext = "json", .snapshot = null, .digest = groupDigest });
    platform.registerProbe(.{ .name = "viz", .ctx = &app, .ext = "json", .snapshot = vizSnapshot, .digest = vizDigest });
    platform.registerProbe(.{ .name = "modular", .ctx = &app, .ext = "json", .snapshot = modularSnapshot, .digest = modularDigest });
    platform.registerProbe(.{ .name = "panel", .ctx = &app, .ext = "json", .snapshot = null, .digest = panelDigest });
    platform.registerProbe(.{ .name = "params", .ctx = &app, .ext = "json", .snapshot = paramsSnapshot, .digest = paramsDigest });
    platform.registerProbe(.{ .name = "menu", .ctx = &app, .ext = "txt", .digest = menuDigest, .desc = "menu open/items/enabled/checked/pending/last_op/native" });
    // ヘッドレス検証 harness の custom action を登録（harness 無効時は no-op。TASK-65）。
    app.cmd_exec = platform.command.Executor.init(.{ .ctx = &app, .run = dispatchModularAction });
    app.cmd_exec.log = &app.cmd_log;
    // TASK-106.4: undo 逆適用アダプタ。
    app.cmd_exec.adapter = .{ .ctx = &app, .canUndo = patchCanUndo, .applyUndo = patchApplyUndo, .summarize = patchSummarize };
    platform.setCommandExecutor(&app.cmd_exec);
    registerPatchActions(&app);
    registerActions(&app);
    registerIntegratedStateSync(&app);

    device.start() catch |err| {
        std.debug.print("audio.start failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer device.stop();
    std.debug.print("apps/patch: ドラッグでポート間を配線 / パレットで追加 / Delete で削除 / scroll=zoom。音が鳴ります。\n", .{});

    var stereo: [2048]f32 = undefined;
    var mono: [1024]f32 = undefined;
    main_loop: while (app.running and window.pollEvents()) {
        {
            const fb = window.lockFramebuffer() orelse continue :main_loop;
            defer fb.unlock();
            app.fb_w = fb.width;
            app.fb_h = fb.height;
            gui_ctx.beginFrame(fb.width, fb.height);

            // C: master タップを読み → mono downmix → spec/osc/meter へ供給。直近ブロックの rms/peak を latch。
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
                        // GUI fallback: メニューショートカット（Cmd/Ctrl+S/O）。native 時は OS が所有。
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
                                // TASK-125: modifier なし H のみ。Cmd/Ctrl/Alt/Shift+H は無視。
                                if (!(k.modifiers.shift or k.modifiers.ctrl or k.modifiers.alt or k.modifiers.cmd)) {
                                    app.togglePanelsHidden();
                                }
                            },
                            else => {},
                        }
                    },
                    .key_up => {},
                    .char_input => {},
                    .gamepad_connected, .gamepad_disconnected => {}, // TASK-80.1: 本 app 未消費（cross-cutting Event 追加）
                    .composition_changed => {}, // TASK-79.6.1: composition 未消費（inline preedit は 79.6.2）
                    .menu_command => |id| app.dispatchCommand(id),
                    .file_drop => {}, // TASK-113.4: patch 未消費
                    .mouse_move => |m| {
                        app.mouse = .{ .x = @floatFromInt(m.x), .y = @floatFromInt(m.y) };
                        gui_ctx.pushEvent(.{ .mouse_move = .{ .x = m.x, .y = m.y, .modifiers = 0 } });
                        // drag 中は panel 上でも追従（node/pan を panel 境界で切らない）。開始は allowsCanvasInput。
                        if (app.drag != .none or app.allowsCanvasInput()) onMouseMove(&app);
                    },
                    .mouse_down => |m| {
                        const button: u8 = if (m.button == .left) 0 else if (m.button == .right) 1 else 2;
                        gui_ctx.pushEvent(.{ .mouse_down = .{ .x = m.x, .y = m.y, .button = button, .modifiers = 0 } });
                        if (m.button == .left) {
                            app.mouse = .{ .x = @floatFromInt(m.x), .y = @floatFromInt(m.y) };
                            if (app.allowsCanvasInput()) onMouseDown(&app);
                        }
                    },
                    .mouse_up => |m| {
                        const button: u8 = if (m.button == .left) 0 else if (m.button == .right) 1 else 2;
                        gui_ctx.pushEvent(.{ .mouse_up = .{ .x = m.x, .y = m.y, .button = button, .modifiers = 0 } });
                        if (m.button == .left) {
                            app.mouse = .{ .x = @floatFromInt(m.x), .y = @floatFromInt(m.y) };
                            // cable/node drag の commit は panel 上でも受け付ける（開始は center のみ）。
                            if (app.drag != .none or app.allowsCanvasInput()) onMouseUp(&app);
                        }
                    },
                    .mouse_scroll => |s| {
                        app.mouse = .{ .x = @floatFromInt(s.x), .y = @floatFromInt(s.y) };
                        gui_ctx.pushEvent(.{ .mouse_scroll = .{ .x = s.x, .y = s.y, .dx = s.dx, .dy = s.dy, .modifiers = 0 } });
                        if (app.allowsCanvasInput()) {
                            const factor: f32 = if (s.dy > 0) 1.1 else if (s.dy < 0) 1.0 / 1.1 else 1.0;
                            app.camera.zoomAt(app.toCanvasLocal(app.mouse), factor);
                            updateHover(&app);
                        }
                    },
                }
            }

            // A/D: 活性度更新 + tap 対象の選択・publish（描画の直前・イベント反映後）。
            // 生成レイヤ scalar は GUI/action の最新値を制御レートで atomic publish する。
            publishControls(app.patch, app.params);
            updateViz(&app);
            app.syncInspectorTarget();
            app.beginParamFrame();

            @memset(fb.pixels, BG);
            dl.reset(fb.width, fb.height);
            drawFrame(&app, &dl);
            const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
            gui.render(target, &dl, gui.default_font);

            // menu → PanelHost content（VIS_H より上）→ VIS_H の描画順。
            const mtop_i: i32 = @intFromFloat(app.menuTopH());
            const vis_h_i: i32 = VIS_H;
            const content_h_i: i32 = @max(0, @as(i32, @intCast(fb.height)) - mtop_i - vis_h_i);
            gui_ctx.beginBox(.{
                .direction = .column,
                .width = .{ .fixed = @intCast(fb.width) },
                .height = .{ .fixed = @intCast(fb.height) },
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
            // VIS_H 分のスペーサ（PanelHost が帯と重ならないよう content を上に限定）。
            if (vis_h_i > 0) {
                gui_ctx.beginBox(.{ .width = .{ .grow = 1 }, .height = .{ .fixed = vis_h_i } });
                gui_ctx.endBox();
            }
            gui_ctx.endBox();
            if (!gui_ctx.input.mouse_buttons.left) app.releaseParamEdits();
            gui_ctx.endFrame();
            app.syncCanvasRect();
            if (!app.native_menu_active) {
                const menu_res = gui.menuBarPopup(&gui_ctx, app.menuCommandsSlice(), &app.menu_bar_state);
                if (menu_res.selected) |id| app.dispatchCommand(id);
            }
            app.captureParamRows(&gui_ctx);
            app.advanceParamEdits();
            app.drawGhostMarkers(&gui_ctx.draw_list);
            gui.render(target, &gui_ctx.draw_list, gui.default_font);
            // 可視化帯は最後に直描き（下地 @memset で canvas 内容を上書き＝帯が常に最前面）。
            drawVizBand(&app, fb, spec, osc, &meter);

            window.present();
        }
        // dialog は framebuffer unlock 後の安全点（platform.h 契約。TASK-136）。
        if (app.running) app.runPendingMenuFileOp();
        // TASK-106.1: evolve authority と host pattern_state 配信（main thread イベント境界のみ）。
        updateEvolveAuthority(&app);
        maybeBroadcastPatternState(&app);
        platform.frameDelay(16_000_000);
    }
    // panel/slot 状態を Preferences へ保存（終了時）。
    persistPanelPrefs(&app);
    if (app.prefs_dir) |*dir| {
        dir.close(app.io);
        app.prefs_dir = null;
    }
    app.prefs.deinit();
    std.debug.print("apps/patch: done.\n", .{});
}

// ============================================================================
// harness custom probe（TASK-32.3）: topology（node 一覧・接続）+ 見切れカウントを公開。
// digest は framework 固定 1024B 以内。
// TASK-40.7.1: `patch` probe は不変＝常に flat（実 handle・collapsed の影響を受けない）トポロジを見せる。
// 入れ子構造は `group` probe（groupDigest）と組み合わせて機械検証する（digest patch × digest group）。
// ============================================================================
fn offscreenOf(app: *const App) canvas.OffscreenCounts {
    var node_buf: [MAX_MODULES]NodeGeom = undefined;
    var edge_buf: [MAX_EDGES]Edge = undefined;
    const nodes = node_buf[0..app.buildRawNodes(&node_buf)];
    const edges = edge_buf[0..app.buildFlatEdges(&edge_buf)];
    // 見切れ判定の有効領域はキャンバス高（下端の可視化帯を除く）。帯に隠れるノードも「見切れ」に数える。
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

/// menu digest（TASK-136）: 開閉・項目数・enabled/checked mask・pending/last_op/native。
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

/// snapshot patch: digest の 1024B 制限と独立に、全 nodes/edges + layout を raw JSON で返す。
fn patchSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var sn_buf: [MAX_MODULES]graph_io.StableNode = undefined;
    var se_buf: [MAX_EDGES]graph_io.StableEdge = undefined;
    const topo = collectStableTopology(app, &sn_buf, &se_buf);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    // topology 本体は `}` なしで組み立て、layout を差し込んで閉じる。
    try graph_io.appendStableTopologyJson(&list, allocator, topo.nodes, topo.edges, topo.output_id);
    // 末尾の `}` を落として layout を追記
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
// harness custom probe（TASK-32.3/40.7.1）: `group` — グループ台帳（入れ子 topology）を公開。
// `digest patch`（flat topology）× `digest group`（グループ所属/expose）の組で入れ子構造を機械検証できる。
// digest は framework 固定 1024B 以内・snapshot 無し（null）。
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
// harness custom probe（TASK-40.8）: `viz` — 信号可視化データ。
//   C: master rms/peak（下帯 scope/spectrogram の実信号レベル）
//   A: per-port レベル（ports[]。sigLevel 由来・RT 影響ゼロの torn read）
//   D: tap 中の port と直近窓の状態（taps[]。wpos / applied 済みか）
// digest は framework 固定 1024B 以内。snapshot は各 tap 窓の min/max/nz を追加。
// ============================================================================
fn vizDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    // 末尾 "]}" 用に 2B 予約して常に閉じた JSON を返す（overflow でも壊れた断片を返さない）。
    // キーは短縮（h/o/k/w/ap/lv）。16 tap × 最悪 wpos 10 桁でも 1024B 内に収まる見積り。
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
        }) catch break; // 入り切らなければそこで打ち切り（tail で必ず閉じる）
        off += piece.len;
        first = false;
    }
    const tail = std.fmt.bufPrint(buf[off..], "]}}", .{}) catch return errDigest(buf); // 予約済みなので必ず成功
    off += tail.len;
    return buf[0..off];
}

/// 実 handle/out の信号種別（合成 handle は来ない＝tap_ports は実 global port id のみ）。
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
// ヘッドレス検証 harness の custom action（TASK-65。TASK-62.1 の registerAction を patch が採用。
// pixie(TASK-64)/synth・modular(TASK-65) と同じ「probe(read) に対称な write 口。既存の UI 操作
// （パレット追加・drag 配線・Delete）と同じ `DynGraph` メソッド列をそのまま辿る」構図）。
//
// ホットパス宣言: 全 action の `run()` は「イベント時のみ」（harness `action` コマンド1回につき1回、
// main thread の pollGate 内で実行）。フレーム毎・毎サンプルのいずれでもないため性能規約の適用対象外。
// `DynGraph.add/removeModule/connect/disconnect/publish` はいずれも非RT・staging→triple-buffer
// publish（既存の `commitConnect`/`deleteSelected`/`addByPaletteIndex` と全く同じ経路）で、RT 経路
// （`DynGraph.processBlock`）へ新たな同期/alloc/lock/panic は一切追加しない。
//
// パーサは `actions.zig`（std のみ・App/kit/modular 非依存）に切り出し単体テストする。`ModuleKind`
// 名の enum 解決は App の具象型を知るこのファイル側で行う（pixie の `ToolKind` 解決と同じ分離方針）。
//
// スコープ: ノード add/remove/connect/disconnect のみ（task description が明示する範囲）。
// マクロ（DrumMachine/BassMachine）の action 化は別議論として見送る。
// ============================================================================

// ============================================================================
// TASK-106.4: undo payload capture / CommandAdapter / inverse apply
// ホットパス: イベント時のみ（action dispatch / Cmd+Z）。RT 経路には触れない。
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
            if (s.mode == 0) {
                const v: f32 = @bitCast(s.value_bits);
                setParamAndPublish(app, s.name(), v) catch {};
            } else {
                const h = handleOfNodeId(app, NodeId.fromRaw(s.node_id)) orelse return;
                const raw: f32 = if (s.value_kind == 0) @bitCast(s.value_bits) else @floatFromInt(s.value_bits);
                queueParamOverride(app, h, s.name(), raw) catch {};
            }
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
    if (s.group_id != 0xFF and s.group_id < group.MAX_GROUPS) app.ledger.free(s.group_id);
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
}

fn actionUndo(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    if (args.len != 0) return error.UnexpectedArgs;
    const app = actionApp(ctx);
    const outcome = try app.cmd_exec.undoOne(.local_user, buf);
    return outcome.message;
}

fn actionRedo(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    if (args.len != 0) return error.UnexpectedArgs;
    const app = actionApp(ctx);
    const outcome = try app.cmd_exec.redoOne(.local_user, buf);
    return outcome.message;
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

fn displayTransportValue(ctx: *anyopaque, key: param_view.FieldKey, field: f32) f32 {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (app.findEditState(key)) |state| {
        if (state.pending) |pending| switch (pending) {
            .scalar => |value| return value,
            .choice => {},
        };
    }
    return field;
}

fn transportHandles(app: *const App) param_view.TransportHandles {
    return .{
        .clock = app.patch.clock_h,
        .master_vcf = app.patch.master_vcf_h,
        .sidechain = app.patch.sidechain_h,
        .kick = app.patch.kick_h,
        .hat = app.patch.hat_h,
        .clap = app.patch.clap_h,
        .bass_perc = app.patch.bass_perc_h,
        .pad = app.patch.pad_h,
    };
}

fn scalarFor(app: *App, key: param_view.FieldKey, fallback: f32) transport.Scalar {
    const snapshot = app.snapshotParam(@intCast(key.handle), key.name) orelse return .{ .key = key, .field = fallback };
    const field = switch (snapshot.field) {
        .scalar => |value| value,
        .choice => fallback,
    };
    const instant = if (snapshot.instant) |value| switch (value) {
        .scalar => |v| v,
        .choice => null,
    } else null;
    return .{ .key = key, .field = field, .instant = instant };
}

fn transportModel(app: *App) transport.Model {
    const handles = transportHandles(app);
    const density_key = param_view.keyFor(.density, handles);
    const state = app.patch.snapshotState();
    return .{
        .tempo = scalarFor(app, param_view.keyFor(.tempo, handles), state.bpm),
        .cutoff = scalarFor(app, param_view.keyFor(.cutoff, handles), state.master_cutoff),
        .density = .{ .key = density_key, .field = state.density_target },
        .swing = scalarFor(app, param_view.keyFor(.swing, handles), state.swing),
        .sidechain = scalarFor(app, param_view.keyFor(.sidechain, handles), state.sidechain_amount),
        .kick = .{ .gain = scalarFor(app, param_view.keyFor(.kick_gain, handles), state.kick_gain), .muted = state.kick_muted },
        .hat = .{ .gain = scalarFor(app, param_view.keyFor(.hat_gain, handles), state.hat_gain), .muted = state.hat_muted },
        .clap = .{ .gain = scalarFor(app, param_view.keyFor(.clap_gain, handles), state.clap_gain), .muted = state.clap_muted },
        .bass = .{ .gain = scalarFor(app, param_view.keyFor(.bass_gain, handles), state.bass_gain), .muted = state.bass_muted },
        .pad = .{ .gain = scalarFor(app, param_view.keyFor(.pad_gain, handles), state.pad_gain), .muted = state.pad_muted },
        .conversion = conversion(),
    };
}

/// scalar/choice の UI 値を descriptor の ParamValue へ変換し、累積表を publish する。
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
    // drag 開始時のみ before を捕捉（release で set_param へ渡す）
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

fn purgeParamOverrideField(app: *App, key: param_view.FieldKey) void {
    var changed = false;
    for (&app.param_batch.entries) |*entry| {
        if (!entry.touched) continue;
        if (param_view.sameFieldParts(key, entry.handle, entry.name)) {
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

/// 初期 graph: active handle 昇順で決定的採番。
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

/// NodeRef → runtime Handle。netsync 中の bare handle / group synthetic / stale id を拒否。
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
    // select_node の追従も action args 由来の slice を保持せず、descriptor static name を使う。
    if (param_view.canonicalDescriptorName(descs, "cutoff")) |name| return param_view.fieldKey(h, name);
    if (descs.len > 0) return param_view.fieldKey(h, descs[0].name);
    return null;
}

/// palette / wire 共通の bass step_seq 初期値（solo `addByPaletteIndex` と同一。TASK-106.2 P1-1）。
/// drum 版 `step_seq` は `ModuleKind` 既定（`.kind=.drum` 等の `.{}`）で palette と一致。
const stepSeqBassInit = modular.StepSeq{
    .kind = .bass,
    .on_mask = 0,
    .accent_mask = 0,
    .slide_mask = 0,
    .scale = .minor_pentatonic,
    .octaves = 2,
};

/// `modular.ModuleKind` → comptime dispatch で `dyn.add(k, .{})`。`addByPaletteIndex` の
/// `inline for` と同型の「runtime enum → comptime 呼び出し」パターン（`switch (kind) { inline else
/// => |k| ... }` は各 tag ごとに comptime 特殊化された分岐を生成し、分岐内の `k` は comptime 値になる）。
/// `actionAddNode`（kind 名）と `load_graph`（`graph_io.decodeGraph` が返す typed kind）の両方が使う。
fn addNodeByKind(app: *App, kind: modular.ModuleKind) !Handle {
    return switch (kind) {
        inline else => |k| app.dyn.add(k, .{}),
    };
}

/// kind 名（`ModuleKind` tag 名、または wire alias `step_seq_bass`）→ add。
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
    errdefer app.dyn.removeModule(h);
    app.layout[h] = .{ .x = p.x, .y = p.y };
    try app.dyn.publish();
    // redo も通常再実行: 全 peer が allocNodeId の単調採番で一致（COMMIT 全順序）。
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

/// item が削除対象 handle `h` を参照しているか（remove 後 stale になる selected/hover の判定）。
/// **`removeModule(h)` の前に**呼ぶこと（cable の src 側判定に削除前の flat edge を引くため）。
///   - node: 直接一致。
///   - port: `PortRef.handle` は collapsed group では合成 handle になりうるので `resolvePort` で
///     実 member へ解決してから比較する。解決不能（既に stale）な port は保守的に落とす（true）。
///   - cable: `CableRef` は dst しか持たないため、dst 一致に加えて削除前の実 edge を `edgeForInput` で
///     引き src 側が h の cable も検出する（src 削除で `removeModule` がその接続を消すため stale になる）。
///   - group: 単一ノード削除では group は消えないので保持（false）。
/// `deleteSelected` の node 分岐は selected==削除対象前提で無条件 null にするが、action は任意 handle を
/// 消せるため参照判定で限定する。
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
    app.dyn.removeModule(h);
    clearNodeIdMapping(app, h);
    try app.dyn.publish();
    app.refreshAllExposed();
    if (clear_selected) app.selected = null;
    if (clear_hover) app.hover = null;
    notePatchUndo(app, .{ .remove_node = snap });
    return "ok";
}

/// `commitConnect` と同じ「検証してから壊す」順序（active/種別一致を先に検証 → 検証 OK なら
/// 宛先の既存接続を置換）で、無効な接続要求で既存接続を壊さない。
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
        app.dyn.removeModule(h);
        clearNodeIdMapping(app, h);
    }
    app.ledger.free(group_id);
    try app.dyn.publish();
    app.refreshAllExposed();
    app.selected = null;
    app.hover = null;
    notePatchUndo(app, .{ .remove_macro = snap });
    return "ok";
}

// ============================================================================
// save_graph / load_graph（TASK-105.4: VPRJ 互換 alias。旧 PTCG も読込可）。
//
// ホットパス宣言: save/load はイベント時のみ。RT 経路には触れない。
// save_graph = VPRJ 全体保存（save_project と同内容）。
// load_graph = VPRJ から graph/Ledger/GENR を適用。PTCG も読込（Ledger 空リセット・GENR 無効化）。
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

/// active node の descriptor source field を NPRM 用に収集（instant は保存しない）。
/// `param_bufs` は各 node の parameter 値 scratch（name は descriptor 静的文字列を指す）。
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

/// 置換意味論の容量: クリア予定の active 分も空きとして数える。
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

/// clearGraph + publish 後、RT の processBlock が grace を進めるまで待つ（上限付き）。
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
    // 不正 NPRM は clearGraph 前に reject（graph を破壊しない）
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

    // NPRM: node 再生成後・最終 publish 前に source field を適用（型デフォルトの 1-block transient 回避）
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
                    // validate 済みなので本来到達不能。グラフを空のまま放置しない。
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
        // 復元直後: deriveExposed で整合確認（値はグラフ+membership が一致すれば不変）
        app.refreshAllExposed();
    } else {
        app.ledger = .{};
    }

    if (genr_src) |g| {
        app.patch.applyGenRoles(project_io.remapGenr(g, &mapping));
    } else {
        app.patch.invalidateGenRoles();
    }

    // stable NodeId: NREF があれば復元、無ければ決定的 fallback
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

    // master output は VPRJ chunk 対象外だが、GENR の output role から staging output を復元する
    // （無いと load 後 silent。旧 PTCG 経路は GENR 無効のため setOutput しない）。
    if (app.patch.output_h != project_io.INVALID_ROLE_HANDLE and app.dyn.isActive(app.patch.output_h)) {
        app.dyn.setOutput(app.patch.output_h);
        try app.dyn.publish();
    }

    return .{ .nodes_restored = nodes_restored, .edges_restored = edges_restored };
}

/// params + pattern を publish する。
/// `quantize_bar=true`: 同一 load で seed も適用される場合に必須（seed の anchor リセットに pattern が潰されないよう、
/// bar 境界で seed→pending_bar_cmd の後勝ち適用）。VPRJ/MPRJ load / SYNC が該当。
/// `quantize_bar=false`: pattern-only（load_pattern）。即時適用（従来どおり）。
/// 呼び出し側が `loaded.apply_seed_song` を渡すのは「pattern と seed が同居するフォーマットだけ量子化」の意図借用。
/// `apply_params_pattern=true` かつ `apply_seed_song=false` の組合せは現行フォーマットに存在しない。
fn applyParamsPattern(app: *App, params: Params, pattern: pattern_io.PatternPayload, quantize_bar: bool) void {
    app.params = params;
    publishControls(app.patch, app.params);
    var cmd = payloadToPatternCommand(0, pattern);
    cmd.quantize_bar = quantize_bar;
    const published = publishPatternCommand(app, cmd);
    // load の quantized pattern を last_quantized_cmd に載せ、stale mini-notation の再利用を防ぐ。
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

/// 既存グラフを全消去する（load の「置換」意味論。台帳/選択/hover も併せてリセット）。
fn clearGraph(app: *App) void {
    purgeParamOverrides(app, null);
    var h: Handle = 0;
    while (h < MAX_MODULES) : (h += 1) {
        if (!app.dyn.slotActive(h)) continue;
        if (app.ledger.group_of[h] != null) app.ledger.unassign(h);
        app.dyn.removeModule(h);
    }
    app.ledger = .{};
    clearAllNodeIdMappings(app);
    // next_node_id は load/SYNC 側が restore する（clear 単体では単調性を壊さない）
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

    const ledger_ptr: ?*const group.Ledger = if (decoded.apply_ledger and decoded.format == .vprj) &decoded.ledger else null;
    const genr_opt: ?project_io.GenRoleHandles = if (decoded.apply_genr and decoded.format == .vprj) decoded.genr else null;
    const nprm_opt: ?[]const project_io.NodeParamRecord = if (decoded.apply_node_params) decoded.node_params else null;
    // PTCG: apply_ledger/genr は true だが空/INVALID（decodeFromPtcg）
    const result = if (decoded.format == .ptcg)
        try applyGraphReplace(app, decoded.nodes, decoded.edges, null, null, null, decoded.node_id_refs, decoded.next_node_id)
    else
        try applyGraphReplace(app, decoded.nodes, decoded.edges, ledger_ptr, genr_opt, nprm_opt, decoded.node_id_refs, decoded.next_node_id);

    return std.fmt.bufPrint(buf, "nodes={d}/{d} edges={d}/{d}", .{
        result.nodes_restored, decoded.nodes.len, result.edges_restored, decoded.edges.len,
    }) catch "ok";
}

/// graph relay action を一括登録する（TASK-106.2）。`.relay` + canonicalize。undoable なし。
/// network_policy は `gen_actions.PATCH_NETWORK_POLICIES` が単一ソース。
fn registerPatchActions(app: *App) void {
    platform.registerAction(.{ .name = "select_node", .ctx = app, .run = actionSelectNode, .network_policy = patchPolicy("select_node") });
    platform.registerAction(.{ .name = "observe_param", .ctx = app, .run = actionObserveParam, .network_policy = patchPolicy("observe_param") });
    // TASK-149.1/149.3: panel visible トグル（local_only。recipe/CommandLog 非記録→meta ring）。
    platform.registerAction(.{
        .name = "panel_toggle",
        .ctx = app,
        .run = actionPanelToggle,
        .network_policy = .local_only,
        .args = &.{.{ .name = "name", .kind = "string" }},
        .desc = "toggle panel visible (transport|inspector|history)",
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
        .desc = "save integrated VPRJ project (alias of save_project)",
    });
    platform.registerAction(.{
        .name = "load_graph",
        .ctx = app,
        .run = actionLoadGraph,
        .network_policy = patchPolicy("load_graph"),
        .desc = "load graph/Ledger/GENR from VPRJ (or legacy PTCG); reject while synced",
    });
}

fn toPlatformPolicy(tag: gen_actions.NetworkPolicyTag) platform.NetworkPolicy {
    return switch (tag) {
        .relay => .relay,
        .local_only => .local_only,
        .reject_when_synced => .reject_when_synced,
    };
}

fn patchPolicy(comptime name: []const u8) platform.NetworkPolicy {
    // gen_actions.policyOf を comptime で確実に解決する（表欠落はビルド時エラー）。
    const tag = comptime gen_actions.policyOf(name) orelse @compileError("missing PATCH_NETWORK_POLICIES entry: " ++ name);
    return toPlatformPolicy(tag);
}

/// graph relay action の CommandLog 記録ラッパー（TASK-106.2/106.3）。
///
/// 保存契約: `platform.routeAction` の canonicalize 後 args（NodeId は `#<id>` 形式）が
/// `CommandRecord.args` にそのまま入る。`recordedGraphAction` 内で再 canonicalize はしない
/// （remote COMMIT は host 側 canonicalize 済み wire args を受け取るため）。
///
/// fresh replay 前提: NodeId 採番は起動時 active handle 昇順の初期割当と、publish 成功後の
/// 単調増分（削除後も再利用なし）により、同じ操作列なら同じ `#id` が再現される。
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
    if (decoded.format != .vprj) return error.UnsupportedFormat;

    // 検証完了後にのみ破壊的適用（capacity は applyGraphReplace 内）
    const nprm_opt: ?[]const project_io.NodeParamRecord = if (decoded.apply_node_params) decoded.node_params else null;
    _ = try applyGraphReplace(app, decoded.nodes, decoded.edges, &decoded.ledger, decoded.genr, nprm_opt, decoded.node_id_refs, decoded.next_node_id);
    // TASK-151: SYNC も VPRJ load と同じく pattern を pending（quantize_bar）で staging → seed 後勝ち。
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
    return param_view.keyFor(.cutoff, transportHandles(app));
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

fn observedTransportValue(app: *const App, key: param_view.FieldKey) ?f32 {
    const handles = transportHandles(app);
    if (param_view.sameField(key, param_view.keyFor(.density, handles))) return app.patch.snapshotState().density_target;
    const alias = transportAliasForKey(app, key) orelse return null;
    _ = alias;
    const snapshot = modular.getParamSnapshot(app.dyn, @intCast(key.handle), key.name) catch return null;
    const field = scalarParamValue(snapshot.field) orelse return null;
    return editScalarValue(app, key) orelse field;
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
    // 既存キー維持 + TASK-149.3 history_* を追加のみ。
    return std.fmt.bufPrint(buf, "transport_visible={d} inspector_visible={d} transport_open={d} inspector_open={d} transport_state={s} inspector_state={s} panels_hidden={d} history_visible={d} history_open={d} history_count={d} history_latest_seq={d} history_scroll_y={d} left_extent={d} right_extent={d} bottom_extent={d} center_x={d} center_y={d} center_w={d} center_h={d} canvas_w={d} canvas_h={d}", .{
        @intFromBool(app.panelVisible("Transport")),
        @intFromBool(app.panelVisible("Inspector")),
        @intFromBool(app.panelOpen("Transport")),
        @intFromBool(app.panelOpen("Inspector")),
        app.panelStateName("Transport"),
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

// ── PanelHost body callbacks + Preferences adapter（TASK-149.1/149.3）────────

fn actorLabel(actor: platform.command.ActorId, buf: []u8) []const u8 {
    return switch (actor) {
        .local_user => "user",
        .local_agent => "agent",
        .system => "system",
        .peer => |n| std.fmt.bufPrint(buf, "peer#{d}", .{n}) catch "peer",
    };
}

/// recipeEntriesFromLog と履歴 badge の単一ソース。除外名を増やすときはここだけ触る。
fn isRecipeEligibleCommandName(name: []const u8) bool {
    // TASK-106.1: 内部 snapshot。意味的 recipe に含めない。
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
            const badge = normalHistoryBadge(rec.name());
            const args = rec.args();
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

fn formatHistoryMetaLine(meta: *const MetaEvent, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "— user {s} [local_only]", .{meta.summary()}) catch "—";
}

/// History 行の merge 表示用（cmd + meta）。fixed stack、per-frame alloc なし。
const HistoryDisplayLine = struct {
    primary_seq: u64,
    is_meta: bool,
    /// meta なら meta ring index（0=oldest）、cmd なら recordAt index。
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
        // after_seq の直後に差し込む（同じ primary なら meta を後＝表示上は上側に寄りやすいよう is_meta で tie-break）。
        out[n] = .{ .primary_seq = m.after_seq, .is_meta = true, .src_index = i };
        n += 1;
    }
    // 新しい順: primary_seq desc、同 seq なら meta を cmd より新（上）に。
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

    // ScrollArea: viewport 固定幅・固定高、content は fit（grow-in-fit 回避）。
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
            const text: []const u8 = if (entry.is_meta)
                formatHistoryMetaLine(app.metaAt(entry.src_index), &line_buf)
            else
                formatHistoryCmdLine(app.cmd_log.recordAt(entry.src_index), &line_buf);
            // 各行 fixed 幅 label（wrap なし・見切れは scroll）。
            ctx.beginBox(.{ .width = .{ .fixed = @max(1, content_w - 12) }, .height = .fit });
            ctx.labelEx(text, gui.Color.rgba(0xD0, 0xD6, 0xDE, 0xFF));
            ctx.endBox();
        }
    }
    ctx.endScrollArea();
    ctx.endBox();
}

fn buildTransportPanel(ctx: *gui.Context, user_data: *anyopaque) anyerror!void {
    const app: *App = @ptrCast(@alignCast(user_data));
    const model = transportModel(app);
    transport.drawBody(ctx, &model, app.transportBodyAvail(), app, displayTransportValue, app, transportParamChanged, transportMuteChanged);
}

fn inspectorMemberSelected(ctx: *anyopaque, handle: modular.dyn.Handle) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    // canvas selection / group collapsed / RT は触らない。target のみ。
    if (handle >= MAX_MODULES or !app.dyn.slotActive(handle)) return;
    app.inspector_target = handle;
    // observe も drill-down 対象へ（params digest の choice 確認用）。
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
    // H 全 hide は slot の一時 override。persist 前に pre-hide 値へ戻し、終了後に再適用する。
    const was_hidden = app.panels_hidden;
    if (was_hidden) {
        app.panel_host.setSlotVisible(.left, app.pre_hide_left_visible);
        app.panel_host.setSlotVisible(.right, app.pre_hide_right_visible);
        app.panel_host.setSlotVisible(.bottom, app.pre_hide_bottom_visible);
    }
    app.panel_host.persist(panelPersistence(app)) catch |err| {
        std.debug.print("apps/patch: panel persist failed: {s}\n", .{@errorName(err)});
        if (was_hidden) {
            app.panel_host.setSlotVisible(.left, false);
            app.panel_host.setSlotVisible(.right, false);
            app.panel_host.setSlotVisible(.bottom, false);
        }
        return;
    };
    if (was_hidden) {
        app.panel_host.setSlotVisible(.left, false);
        app.panel_host.setSlotVisible(.right, false);
        app.panel_host.setSlotVisible(.bottom, false);
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
    // harness は小文字名。PanelHost name は PascalCase。local_only（CommandLog 非記録→meta ring）。
    const panel_name: []const u8 = blk: {
        if (std.mem.eql(u8, name_raw, "transport") or std.mem.eql(u8, name_raw, "Transport")) break :blk "Transport";
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

/// GUI 操作を CommandLog へ記録する（dispatch なし。既存変更経路の後に呼ぶ）。
fn recordGuiAction(app: *App, name: []const u8, args: []const u8) void {
    var buf: [8]u8 = undefined;
    _ = app.cmd_exec.recordExecuted(name, args, .{ .actor = .local_user }, null, &buf) catch {};
}

const ChoiceDigestInfo = struct {
    name: []const u8,
    index: i32,
    option: []const u8,

    const none: ChoiceDigestInfo = .{ .name = "none", .index = -1, .option = "none" };
};

/// target handle の choice パラメータ情報（digest 用）。observed が choice なら優先し、なければ先頭 choice。
fn targetChoiceInfo(app: *const App, target: Handle) ChoiceDigestInfo {
    const kind = app.dyn.kindOf(target) orelse return ChoiceDigestInfo.none;
    const descs = switch (kind) {
        inline else => |comptime_kind| modular.descriptors(comptime_kind),
    };
    const observed = observedField(app);
    // 1) observed がこの target の choice ならそれを優先
    if (param_view.sameFieldParts(observed, target, observed.name)) {
        if (paramDescFor(kind, observed.name)) |desc| switch (desc.kind) {
            .choice => |c| {
                const snap = modular.getParamSnapshot(app.dyn, target, desc.name) catch return ChoiceDigestInfo.none;
                const idx: usize = switch (snap.field) {
                    .choice => |v| @min(v, c.options.len -| 1),
                    .scalar => return ChoiceDigestInfo.none,
                };
                // pending があれば表示値
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
    const transport_value = observedTransportValue(app, key);
    const inspector_value = observedInspectorValue(app, key);
    const shown = editScalarValue(app, key) orelse transport_value orelse inspector_value orelse field;
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
    var transport_buf: [32]u8 = undefined;
    var inspector_buf: [32]u8 = undefined;
    var shown_buf: [32]u8 = undefined;
    const instant_text = optionalF32Text(&instant_buf, instant);
    const field_text = optionalF32Text(&field_buf, field);
    const transport_text = optionalF32Text(&transport_buf, transport_value);
    const inspector_text = optionalF32Text(&inspector_buf, inspector_value);
    const shown_text = optionalF32Text(&shown_buf, shown);
    // 既存キーは維持し、inspector_target / choice 情報を追加のみ。
    const result = std.fmt.bufPrint(buf, "selected_h={d} selected_kind={s} inspector_target={d} target_kind={s} choice_name={s} choice_index={d} choice_option={s} observed_h={d} observed_name={s} field={s} instant={s} transport={s} inspector={s} shown={s} dragging={d} override={d} ghost={d}", .{
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
        transport_text,
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
    // 3 ピースに分けて同じ buf へ連結（bufPrint は 1 呼び出し 32 引数上限）。
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
    // Ph5 pattern（masks は hex。bass_deg 配列は snapshot 側）+ TASK-91 song 要約。
    // 末尾は 1 つの `}` で JSON を閉じる（1024B 注意）。
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
    // digest（1024B 以内）に bass_deg 配列 + song 詳細を足した詳細スナップショット（固定 buf に組み立て→dupe）。
    var dbuf: [1024]u8 = undefined;
    const d = modularDigest(ctx, &dbuf);
    const body = if (d.len > 0 and d[d.len - 1] == '}') d[0 .. d.len - 1] else d; // 末尾 '}' を外す
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
    // TASK-91: song 詳細（rows 要約 + chain lens + loop）
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
    const n_rows: usize = @min(@as(usize, st.song_rows), 8); // 要約: 先頭 8 row
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
// ヘッドレス検証 harness の custom action（TASK-65。TASK-62.1 の registerAction を modular が採用。
// pixie(TASK-64)/synth(TASK-65) と同じ「probe(read) に対称な write 口。既存の GUI 編集経路と同じ
// publish 呼び出しをそのまま辿る」構図）。
//
// ホットパス宣言: 全 action の `run()` は「イベント時のみ」（harness `action` コマンド1回につき1回、
// main thread の pollGate 内で実行）。フレーム毎・毎サンプルのいずれでもないため性能規約の適用対象外。
// action が触れる状態伝播は既存の RT-safe cross-thread hand-off をそのまま使うだけで、RT 経路
// （`LofiPatch.render`→graph `processBlock`）へ新たな同期/alloc/lock/panic は一切追加しない:
//   - scalar param / mute: `publishControls`（atomic store。GUI が毎フレーム呼ぶ既存コードと同一）。
//   - pattern 編集(lock/evolve/step/pitch): `patch.snapshotState()` で最新 pattern を読み
//     `stateToCommand` で編集用 base に変換 → 該当 field を書換 → `app.pattern_rev` を1回だけ increment
//     → `patch.controls.pattern_db.publish(cmd)`（triple-buffer Mailbox。GUI の「1 フレームで edited=true
//     のときだけ publish」と全く同じ経路・同じ revision カウンタを共有するため二重採番が起きない）。
//
// パーサは `gen_actions.zig`（std のみ・App/kit/modular 非依存）に切り出し単体テストする。track 名の enum
// 解決は App の具象型を知るこのファイル側で行う（pixie の `ToolKind` 解決と同じ分離方針）。
// ============================================================================

/// `Params` の f32 field へ comptime dispatch で書き込む（`set_param` 汎用 setter）。
fn setParamsF32(p: *Params, name: []const u8, value: f32) error{UnknownParam}!void {
    inline for (@typeInfo(Params).@"struct".fields) |f| {
        if (f.type == f32 and std.mem.eql(u8, f.name, name)) {
            @field(p, f.name) = value;
            return;
        }
    }
    return error.UnknownParam;
}

fn transportAliasForKey(app: *const App, key: param_view.FieldKey) ?param_view.TransportAlias {
    const handles = transportHandles(app);
    inline for (std.meta.fields(param_view.TransportAlias)) |field| {
        const alias: param_view.TransportAlias = @enumFromInt(field.value);
        if (param_view.sameField(key, param_view.keyFor(alias, handles))) return alias;
    }
    return null;
}

fn setTransportCanonical(app: *App, key: param_view.FieldKey, value: f32) error{UnknownParam}!void {
    const alias = transportAliasForKey(app, key) orelse return error.UnknownParam;
    const c = conversion();
    switch (alias) {
        .tempo => app.params.tempo = value,
        .cutoff => app.params.cutoff_norm = param_view.cutoffNorm(value, c),
        .density => app.params.density = value,
        .swing => app.params.swing = value,
        .sidechain => app.params.sidechain = value,
        .kick_gain => app.params.kick_gain = param_view.gainToUi(alias, value, c),
        .hat_gain => app.params.hat_gain = param_view.gainToUi(alias, value, c),
        .clap_gain => app.params.clap_gain = param_view.gainToUi(alias, value, c),
        .bass_gain => app.params.bass_gain = value,
        .pad_gain => app.params.pad_gain = param_view.gainToUi(alias, value, c),
    }
    if (alias == .density) app.patch.controls.density_target_enabled.store(1, .release);
    publishControls(app.patch, app.params);
    purgeParamOverrideField(app, key);
    app.editState(key).begin(key, .{ .scalar = value });
}

fn setTransportAlias(app: *App, alias: param_view.TransportAlias, value: f32) error{UnknownParam}!void {
    const handles = transportHandles(app);
    const key = param_view.keyFor(alias, handles);
    try setTransportCanonical(app, key, param_view.toCanonical(alias, value, conversion()));
    app.editState(key).release();
}

fn setParamAndPublish(app: *App, name: []const u8, value: f32) error{UnknownParam}!void {
    const alias = std.meta.stringToEnum(param_view.TransportAlias, name) orelse blk: {
        if (std.mem.eql(u8, name, "cutoff_norm")) break :blk param_view.TransportAlias.cutoff;
        break :blk null;
    };
    if (alias) |transport_alias| return setTransportAlias(app, transport_alias, value);
    try setParamsF32(&app.params, name, value);
    if (std.mem.eql(u8, name, "density")) {
        app.patch.controls.density_target_enabled.store(1, .release);
    }
    publishControls(app.patch, app.params);
}

fn setMuteAndPublish(app: *App, name: []const u8, muted: bool) error{UnknownTrack}!void {
    switch (std.meta.stringToEnum(MuteTrack, name) orelse return error.UnknownTrack) {
        .kick => app.params.kick_mute = muted,
        .hat => app.params.hat_mute = muted,
        .clap => app.params.clap_mute = muted,
        .bass => app.params.bass_mute = muted,
        .pad => app.params.pad_mute = muted,
    }
    publishControls(app.patch, app.params);
}

fn transportParamChanged(ctx: *anyopaque, key: param_view.FieldKey, value: f32) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    setTransportCanonical(app, key, value) catch {};
    // drag 中は pending 更新のみ。CommandLog は release 時に 1 record（coalesce）。
    const es = app.editState(key);
    if (es.pending == null) es.begin(key, .{ .scalar = value }) else {
        es.pending = .{ .scalar = value };
        es.dragging = true;
    }
}

fn transportMuteChanged(ctx: *anyopaque, name: []const u8, muted: bool) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    setMuteAndPublish(app, name, muted) catch {};
    var args_buf: [32]u8 = undefined;
    const args = std.fmt.bufPrint(&args_buf, "{s} {d}", .{ name, @intFromBool(muted) }) catch return;
    recordGuiAction(app, "set_mute", args);
}

fn actionSetParam(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    var it = std.mem.tokenizeAny(u8, args, " \t");
    _ = it.next() orelse return error.Empty;
    _ = it.next() orelse return error.Empty;
    const pending = app.pending_param_undo_before;
    app.pending_param_undo_before = null;
    if (it.next() != null) {
        const p = try actions.parseParamOverride(args);
        const h = try resolveNodeRef(app, p.ref, true);
        const cname = canonicalParamName(app, h, p.name) orelse return error.UnknownParam;
        const before_snap = pending orelse blk: {
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
    } else {
        const nf = try gen_actions.parseNameF32(args);
        const before_snap = pending orelse blk: {
            var s = patch_undo.ParamValueSnap{ .mode = 0 };
            s.setName(nf.name);
            // best-effort: read transport via params struct fields is complex; use 0 sentinel
            // Prefer pending from slider; for harness capture live transport aliases.
            const alias = std.meta.stringToEnum(param_view.TransportAlias, nf.name) orelse
                (if (std.mem.eql(u8, nf.name, "cutoff_norm")) param_view.TransportAlias.cutoff else null);
            if (alias) |a| {
                const st = app.patch.snapshotState();
                const v: f32 = switch (a) {
                    .tempo => st.bpm,
                    .cutoff => st.master_cutoff,
                    .density => st.density_target,
                    .swing => st.swing,
                    .sidechain => st.sidechain_amount,
                    .kick_gain => st.kick_gain,
                    .hat_gain => st.hat_gain,
                    .clap_gain => st.clap_gain,
                    .bass_gain => st.bass_gain,
                    .pad_gain => st.pad_gain,
                };
                s.value_kind = 0;
                s.value_bits = @bitCast(v);
                break :blk s;
            }
            break :blk null;
        };
        try setParamAndPublish(app, nf.name, nf.value);
        if (before_snap) |bs| {
            if (@as(f32, @bitCast(bs.value_bits)) != nf.value) notePatchUndo(app, .{ .param = bs });
        }
    }
    return "ok";
}

fn canonicalizeSetParam(ctx: *anyopaque, args: []const u8, scratch: []u8) anyerror![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var it = std.mem.tokenizeAny(u8, args, " \t");
    _ = it.next() orelse return error.Empty;
    _ = it.next() orelse return error.Empty;
    if (it.next() == null) {
        // transport: `<name> <value>`（NodeId なし）
        const nf = try gen_actions.parseNameF32(args);
        return std.fmt.bufPrint(scratch, "{s} {d}", .{ nf.name, nf.value }) catch return error.ArgsTooLong;
    }
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

/// TASK-106.1: host evolve 結果の内部 snapshot。quantize_bar=false で即 publish。
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
    // host が自 COMMIT を適用した場合も broadcast 済 mutation を揃える。
    if (platform.netsyncIsHost()) app.last_pattern_state_mut = p.mutation_count;
    return "ok";
}

/// netsync 無効 or host → mutate 可。client → pattern_state 受信のみ。
fn updateEvolveAuthority(app: *App) void {
    const host = !platform.netsyncActive() or platform.netsyncIsHost();
    app.patch.controls.evolve_host_authority.store(@intFromBool(host), .release);
}

/// host main thread: mutation_count 変化、または peer 増加（join）時に pattern_state を COMMIT 配信。
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
// save_pattern / load_pattern（TASK-105.4: VPRJ 互換 alias。旧 MDLP も読込可）。
//
// ホットパス宣言: save/load はイベント時のみ。RT 経路には触れない。
// save_pattern = VPRJ 全体保存（save_project と同内容）。
// load_pattern = VPRJ/MDLP から SPRM/PTRN のみ適用。
// ============================================================================

/// 現在の `PatternCommand` を `pattern_io.PatternPayload`（app 非依存の plain struct）へ写す。
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

/// `pattern_io.PatternPayload` を `rev` 付きで `PatternCommand` へ復元する（rev は payload に
/// 含めず、他の pattern 編集 action と同じ「app.pattern_rev を1回 increment」で払い出す）。
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
    // pattern-only: seed 無しのため即時適用（quantize_bar=false）。
    applyParamsPattern(app, loaded.params, loaded.pattern, false);
    return "ok";
}

/// `action seed <n>`: main thread で parse → lock-free publish → 次 bar 境界で RT が適用（TASK-62.5.7）。
/// TASK-93: app.notation_seed も同期（mini-notation の `?` / 交代が seed 規約と整合する）。
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
// TASK-91: Song/Chain/Phrase actions（recorded = seed+recipe 決定性に整合）
// 編集は app.song を書き換え → rev++ → song_db.publish（宣言的全置換粒度 = SongData 全体）。
// ============================================================================

fn publishSong(app: *App, patch: *LofiPatch) void {
    app.song.rev +%= 1;
    patch.controls.song_db.publish(app.song);
}

/// `phrase_capture <idx>`: 現在パターンを drum pool[idx]×3 + bass pool[idx] へ取り込み。
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

/// `chain_set <chain_idx> <phrase_idx...>`（1..16）。
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

/// `song_row <row_idx> <kick_chain> <hat_chain> <clap_chain> <bass_chain>`。
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

/// `song_len <n>`（0..64）。
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

/// `song_loop <0|1>`。
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

/// `song_play <0|1>`。開始時は RT が position リセット（applyControls の rising edge）。
fn actionSongPlay(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch;
    const on = gen_actions.parseBool01(args) catch {
        platform.setActionErrorDetail("bad_args", "usage: song_play <0|1>");
        return error.BadArgs;
    };
    // SongData 最新を載せてから play（編集後の unpublish 漏れ防止）
    publishSong(app, patch);
    patch.controls.song_playing.store(@intFromBool(on), .release);
    return "ok";
}

/// `song_goto <row>`。
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

/// `save_project <path>`: VPRJ 全体（graph+Ledger+pattern+Song+Params+seed+GENR）。local_only・非記録。
fn actionSaveProject(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const path = try gen_actions.parsePath(args);
    try actionSaveProjectFile(app, path);
    app.pushMetaEvent("save_project");
    return "ok";
}

/// `load_project <path>`: VPRJ または旧 MDLP/MPRJ/PTCG を自動判定。local_only・非記録。
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
        const ledger_ptr: ?*const group.Ledger = if (loaded.apply_ledger and loaded.format == .vprj) &loaded.ledger else null;
        const genr_opt: ?project_io.GenRoleHandles = if (loaded.apply_genr and loaded.format == .vprj) loaded.genr else null;
        const nprm_opt: ?[]const project_io.NodeParamRecord = if (loaded.apply_node_params) loaded.node_params else null;
        const result = if (loaded.format == .ptcg)
            try applyGraphReplace(app, loaded.nodes, loaded.edges, null, null, null, loaded.node_id_refs, loaded.next_node_id)
        else
            try applyGraphReplace(app, loaded.nodes, loaded.edges, ledger_ptr, genr_opt, nprm_opt, loaded.node_id_refs, loaded.next_node_id);
        // TASK-151: apply_seed_song を quantize_bar 代理にする（同居フォーマットのみ後勝ち量子化。doc は applyParamsPattern）。
        if (loaded.apply_params_pattern) applyParamsPattern(app, loaded.params, loaded.pattern, loaded.apply_seed_song);
        if (loaded.apply_seed_song) applySeedSong(app, loaded.seed, loaded.song);
        app.pushMetaEvent("load_project");
        return std.fmt.bufPrint(buf, "format={s} nodes={d}/{d} edges={d}/{d}", .{
            @tagName(loaded.format), result.nodes_restored, loaded.nodes.len, result.edges_restored, loaded.edges.len,
        }) catch "ok";
    }

    // 同上: apply_seed_song → quantize_bar（現行フォーマットに pattern-only+seed なしの組合せは無い）。
    if (loaded.apply_params_pattern) applyParamsPattern(app, loaded.params, loaded.pattern, loaded.apply_seed_song);
    if (loaded.apply_seed_song) applySeedSong(app, loaded.seed, loaded.song);
    app.pushMetaEvent("load_project");
    return std.fmt.bufPrint(buf, "format={s}", .{@tagName(loaded.format)}) catch "ok";
}

/// `action render <path> <seconds>`: offline LofiPatch で master を PCM16 WAV に書き出す（TASK-86）。
///
/// ホットパス宣言: イベント時・main thread のみ。live patch の RT 経路には触らない。
/// offline は完全別インスタンス。複製は seed + 公開済み編集状態（params + snapshot pattern）。
/// live の bar 途中の変異位置（クロック位相・step）は複製しない（完全再現は seed+recipe）。
/// レンダー中 main thread がブロックし UI が止まるのは MVP 割り切り。
fn actionRender(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    const live = app.patch;

    const parsed = gen_actions.parseRender(args) catch {
        platform.setActionErrorDetail("bad_args", "usage: render <path> <seconds 1..600>");
        return error.BadArgs;
    };

    const sr_u32 = app.sample_rate;
    const sr_f32: f32 = @floatFromInt(sr_u32);
    // u64 で秒×sr を計算し RIFF u32 制約を先に検査（seconds<=600 では通常到達しない防御）。
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

    // live.base_seed は digest と同じ best-effort torn read（新規同期を足さない）。
    offline.resetWithSeed(live.base_seed);
    publishControls(offline, app.params);
    // snapshot pattern を offline に載せ、rev をずらして必ず apply させる。
    var cmd = stateToCommand(live.snapshotState());
    cmd.rev = offline.applied_rev +% 1;
    offline.controls.pattern_db.publish(cmd);

    var file = std.Io.Dir.cwd().createFile(app.io, parsed.path, .{}) catch |err| {
        platform.setActionErrorDetail("write_failed", "cannot create output path");
        return err;
    };
    defer file.close(app.io); // File.close は void（error union ではない）

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
// TASK-93: `action pattern <track> <notation>`（mini-notation → pattern_db、小節境界適用）
//
// ホットパス宣言: parse/eval は action 実行時（main thread・イベント時）のみ。RT へは評価済み
// PatternCommand（quantize_bar=true）を publish するだけ。RT 追加分は patch.zig の bar 境界
// 固定長コピー（alloc/lock なし）。
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
    // rng_seed = splitmix64(notation_seed ^ counter)、alt_index = counter。評価後に ++。
    const alt_index = app.notation_counter;
    const rng_seed = seedmod.splitmix64(app.notation_seed ^ @as(u64, alt_index));
    app.notation_counter +%= 1;
    const result = gen_actions.evalNotation(ast, rng_seed, alt_index);

    // P1-3: bar 待ち中（または publish 済みで RT 未 acquire）は last_quantized_cmd を base にし、
    // 連続 pattern で先行 track を潰さない。
    const st = patch.snapshotState();
    var cmd = patternEditBase(app);
    if (app.last_quantized_cmd) |lq| {
        // 我々の最新 quantize がまだ bar 反映前: bar_pending、または applied_rev 未到達
        if (lq.rev == app.pattern_rev and (st.bar_pending or st.pattern_rev != lq.rev)) {
            cmd = lq;
        }
    }
    switch (track) {
        .kick => cmd.kick.on = result.on,
        .hat => cmd.hat.on = result.on,
        .clap => cmd.clap.on = result.on,
        .bass => {
            // 宣言的全置換: on は全置換、deg は deg_set の step のみ上書き（accent/slide は維持）
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
    // lock されていても明示編集は通す（GUI toggle_step と同挙動）
    cmd.quantize_bar = true;
    const published = publishPatternCommand(app, cmd);
    app.last_quantized_cmd = published;
    notePatternUndoIfChanged(app, before, published);
    return "ok";
}

/// CommandLog の kind=normal を seq 順で Entry 化（TASK-62.5.8）。name/args は log 借用。
/// 除外判定は `isRecipeEligibleCommandName`（履歴 badge と共有）。
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

/// `recipe_save <path>`: CommandLog → recipe（app_name=APP_NAME）。記録しない。
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

/// `recipe_replay <path>`: load → app_name 検証 → routeLocalAction 逐次適用。入れ子拒否。
/// TASK-93: notation_counter を 0 から再評価（seed+pattern 列の決定性）。
fn actionRecipeReplay(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    const gpa = std.heap.c_allocator;
    recipe.checkNotReplaying(app.recipe_replaying) catch {
        platform.setActionErrorDetail("nested_replay", "wait for current recipe_replay to finish");
        return error.NestedReplay;
    };
    // mini-notation の `?` / `<a b>` を recipe 先頭から決定的に再評価する。
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
// command model 統合（TASK-62.5.7: 記録のみ。pixie 62.5.3 の最小版）
//
// App が CommandLog + Executor を所有し、registerAction 経由の harness/copilot action を
// executeAction(actor=.local_user) で dispatch + 記録する（TASK-106.4: GUI と harness/MCP を同一 undo 対象に統一）。
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
    // TASK-91: Song/Chain/Phrase（recorded）
    .{ .name = "phrase_capture", .run = actionPhraseCapture },
    .{ .name = "chain_set", .run = actionChainSet },
    .{ .name = "song_row", .run = actionSongRow },
    .{ .name = "song_len", .run = actionSongLen },
    .{ .name = "song_loop", .run = actionSongLoop },
    .{ .name = "song_play", .run = actionSongPlay },
    .{ .name = "song_goto", .run = actionSongGoto },
    // TASK-106.2: graph relay（executor / COMMIT 経路）
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

/// 全 action を一括登録する（`platform.init()` 後・main loop 前に呼ぶ。harness 無効時は
/// `registerAction` 自体が no-op なので通常実行に影響しない）。記録 wrapper 経由。
/// network_policy は `gen_actions.PATCH_NETWORK_POLICIES` が単一ソース（TASK-106.1）。
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
        .desc = "save integrated VPRJ project (alias of save_project)",
    });
    platform.registerAction(.{
        .name = "load_pattern",
        .ctx = app,
        .run = actionLoadPattern,
        .network_policy = patchPolicy("load_pattern"),
        .desc = "load SPRM/PTRN from VPRJ (or legacy MDLP); reject while synced",
    });
    platform.registerAction(.{ .name = "seed", .ctx = app, .run = recordedAction("seed"), .network_policy = patchPolicy("seed") });
    // TASK-93: mini-notation。レシピには記法の生テキストを記録（replay 時 counter 順で再評価→決定的）。
    platform.registerAction(.{ .name = "pattern", .ctx = app, .run = recordedAction("pattern"), .network_policy = patchPolicy("pattern") });
    // TASK-106.1: host 内部 snapshot。非 relay → client PROPOSE は汎用 not relayable。
    platform.registerAction(.{
        .name = "pattern_state",
        .ctx = app,
        .run = recordedAction("pattern_state"),
        .network_policy = patchPolicy("pattern_state"),
        .desc = "host-internal pattern snapshot (not for client propose)",
    });
    // TASK-91: Song/Chain/Phrase（recorded。seed+recipe 決定性に整合）
    platform.registerAction(.{ .name = "phrase_capture", .ctx = app, .run = recordedAction("phrase_capture"), .network_policy = patchPolicy("phrase_capture") });
    platform.registerAction(.{ .name = "chain_set", .ctx = app, .run = recordedAction("chain_set"), .network_policy = patchPolicy("chain_set") });
    platform.registerAction(.{ .name = "song_row", .ctx = app, .run = recordedAction("song_row"), .network_policy = patchPolicy("song_row") });
    platform.registerAction(.{ .name = "song_len", .ctx = app, .run = recordedAction("song_len"), .network_policy = patchPolicy("song_len") });
    platform.registerAction(.{ .name = "song_loop", .ctx = app, .run = recordedAction("song_loop"), .network_policy = patchPolicy("song_loop") });
    platform.registerAction(.{ .name = "song_play", .ctx = app, .run = recordedAction("song_play"), .network_policy = patchPolicy("song_play") });
    platform.registerAction(.{ .name = "song_goto", .ctx = app, .run = recordedAction("song_goto"), .network_policy = patchPolicy("song_goto") });
    // recipe（TASK-62.5.8）: メタ操作のため executor 非経由・CommandLog 非記録。
    platform.registerAction(.{ .name = "recipe_save", .ctx = app, .run = actionRecipeSave, .network_policy = patchPolicy("recipe_save") });
    platform.registerAction(.{ .name = "recipe_replay", .ctx = app, .run = actionRecipeReplay, .network_policy = patchPolicy("recipe_replay") });
    // render: session 中は reject（offline 複製が host 変異ストリームを再現できない）。solo は可。
    platform.registerAction(.{ .name = "render", .ctx = app, .run = actionRender, .network_policy = patchPolicy("render") });
    // TASK-105.4: 統合プロジェクト直列化（VPRJ）。非記録。
    platform.registerAction(.{
        .name = "save_project",
        .ctx = app,
        .run = actionSaveProject,
        .network_policy = patchPolicy("save_project"),
        .desc = "save integrated VPRJ project (graph+Ledger+pattern+Song+Params+seed)",
    });
    platform.registerAction(.{
        .name = "load_project",
        .ctx = app,
        .run = actionLoadProject,
        .network_policy = patchPolicy("load_project"),
        .desc = "load VPRJ or legacy MDLP/MPRJ/PTCG; reject while synced",
    });
}

// (TASK-105.4: pattern/graph の二重 registerStateSync は廃止。integrated のみ)
