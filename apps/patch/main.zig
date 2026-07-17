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
const kit = @import("kit"); // 公開 umbrella（ADR-007 R4/R5: apps は kit-only 消費者）
const platform = kit.platform;
const gui = kit.gui;
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
    .{ .primitive = .slew },
    .{ .primitive = .sample_hold },
    .{ .primitive = .comparator },
    .{ .primitive = .ring_mod },
    .{ .primitive = .logic },
};
const PAL_X0: f32 = 8;
const PAL_Y: f32 = 6;
const COLS: usize = 10;
const PAL_W: f32 = 92;
const PAL_H: f32 = 22;
const PAL_GAP: f32 = 3;
const paletteBottom: f32 = PAL_Y + 2.0 * (PAL_H + PAL_GAP);
const PAL_BG = gui.Color.rgba(0x2C, 0x32, 0x3C, 0xFF);
const PAL_BG_HOVER = gui.Color.rgba(0x3A, 0x44, 0x52, 0xFF);
const PENDING_COL = gui.Color.rgba(0xC0, 0xC0, 0xC0, 0xFF);
const MAX_PARAM_EDITS: usize = patchmod.MAX_PARAM_OVERRIDES;

fn paletteButtons() [PALETTE.len]canvas.PaletteButton {
    var btns: [PALETTE.len]canvas.PaletteButton = undefined;
    for (0..PALETTE.len) |i| {
        const col = i % COLS;
        const row = i / COLS;
        const x: f32 = @floatFromInt(col);
        const y: f32 = @floatFromInt(row);
        btns[i] = .{ .kind_index = @intCast(i), .rect = .{
            .x = PAL_X0 + x * (PAL_W + PAL_GAP),
            .y = PAL_Y + y * (PAL_H + PAL_GAP),
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
    drag: Drag = .none,
    fb_w: u32 = WIN_W,
    fb_h: u32 = WIN_H,
    // TASK-123: GUI-local panel visibility。保存・publish・netsync には含めない。
    transport_open: bool = true,
    inspector_open: bool = true,

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

    /// キャンバス有効高（画面下端の可視化帯を除いた領域）。見切れ判定・ヒットテスト・tap 対象選択で共通に使う。
    fn canvasH(self: *const App) f32 {
        const fh: f32 = @floatFromInt(self.fb_h);
        return @max(0.0, fh - VIS_H);
    }

    fn canvasW(self: *const App) f32 {
        return canvas.canvasViewportWidth(@floatFromInt(self.fb_w), self.canvasH());
    }

    fn pointInInspectorPanel(self: *const App) bool {
        return canvas.pointInInspectorState(self.mouse, @floatFromInt(self.fb_w), self.canvasH(), self.inspector_open);
    }

    fn pointInTransportPanel(self: *const App) bool {
        return canvas.pointInTransportState(self.mouse, @floatFromInt(self.fb_w), self.canvasH(), self.transport_open);
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
        const h = if (self.selected) |item| switch (item) {
            .node => |node_h| node_h,
            else => return,
        } else return;
        const kind = self.dyn.kindOf(h) orelse return;
        const descs = switch (kind) {
            inline else => |comptime_kind| modular.descriptors(comptime_kind),
        };
        for (descs, 0..) |desc, index| {
            if (self.param_row_count >= self.param_rows.len) break;
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
        for (&self.param_edits) |*state| state.release();
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
    fn buildRawNodes(self: *const App, out: []NodeGeom) usize {
        var n: usize = 0;
        var h: Handle = 0;
        while (h < MAX_MODULES) : (h += 1) {
            if (!self.dyn.slotActive(h)) continue;
            out[n] = .{ .handle = h, .pos = self.layout[h], .n_in = self.dyn.nIn(h), .n_out = self.dyn.nOut(h) };
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
    // （合成 handle は描画座標の中だけで使う）。
    for (dedges) |de| {
        const e = de.visual;
        const sg = findNode(nodes, e.src_handle) orelse continue;
        const dg = findNode(nodes, e.dst_handle) orelse continue;
        const a = cam.worldToScreen(canvas.outPortPos(sg, e.src_out));
        const b = cam.worldToScreen(canvas.inPortPos(dg, e.dst_in));
        const kind = portKindOut(app, e.src_handle, e.src_out);
        const thick: u32 = if (cableItemMatches(app.selected, de.actual) or cableItemMatches(app.hover, de.actual)) 3 else 2;
        dl.line(vec2i(a), vec2i(b), portColor(kind), thick) catch {};
    }

    // ノード + ポート（畳み箱＝合成 handle はタイトル/ポート種別を台帳経由で解決。box handle は dyn へ
    // 直接渡さない＝§3.1 の閉じ込め）。
    for (nodes) |g| {
        const tl = cam.worldToScreen(g.pos);
        const sz = canvas.nodeSize(g).scale(cam.zoom);
        const rect = toRect(tl, sz);
        dl.rectFilled(rect, NODE_BG) catch {};
        const selected = itemIsHandle(app.selected, g.handle);
        const hovered = itemIsHandle(app.hover, g.handle);
        const border = if (selected) SEL_COL else if (hovered) HOVER_COL else BORDER_COL;
        dl.rectOutline(rect, border, if (selected) 2 else 1) catch {};
        dl.text(.{ .x = rect.x + 6, .y = rect.y + 4 }, nodeTitle(app, g.handle), TITLE_COL) catch {};
        if (group.groupIdFromHandle(g.handle)) |gid| {
            drawToggle(dl, cam, g, true); // 畳み箱は常に collapsed 側
            drawMacroGrid(app, dl, cam, g, gid); // 本体に TR/303 grid + playhead（TASK-40.7.2）
        }
        var i: u8 = 0;
        while (i < g.n_in) : (i += 1) {
            const p = cam.worldToScreen(canvas.inPortPos(g, i));
            const kind = portKindIn(app, g.handle, i);
            fillCircle(dl, p, r, portColor(kind));
            if (hoverPort(app, g.handle, true, i)) dl.rectOutline(portBox(p, r), HOVER_COL, 1) catch {};
        }
        i = 0;
        while (i < g.n_out) : (i += 1) {
            const p = cam.worldToScreen(canvas.outPortPos(g, i));
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
        drawExpandedGroupFrame(app, dl, cam, nodes, @intCast(gi), gr);
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

    // モジュールパレット（最前面・画面固定）
    const buttons = paletteButtons();
    for (buttons) |btn| {
        const rect = gui.Rect{ .x = safeI32(btn.rect.x), .y = safeI32(btn.rect.y), .w = safeU32(btn.rect.w), .h = safeU32(btn.rect.h) };
        const hov = canvas.hitTestPalette(app.mouse, &buttons) == btn.kind_index;
        dl.rectFilled(rect, if (hov) PAL_BG_HOVER else PAL_BG) catch {};
        dl.rectOutline(rect, BORDER_COL, 1) catch {};
        dl.text(.{ .x = rect.x + 6, .y = rect.y + 5 }, paletteLabel(PALETTE[btn.kind_index]), TITLE_COL) catch {};
    }
}

/// origin ポートの screen 位置（node が消えていれば null）。pending cable 描画用。
fn portScreenPos(app: *const App, nodes: []const NodeGeom, p: PortRef) ?Vec2f {
    const g = findNode(nodes, p.handle) orelse return null;
    const wp = if (p.is_input) canvas.inPortPos(g, p.index) else canvas.outPortPos(g, p.index);
    return app.camera.worldToScreen(wp);
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
    };
}

/// 折り畳みトグル [±] を描画する（g は箱 or 枠ヘッダーの NodeGeom。collapsed で表示ラベルを切替）。
fn drawToggle(dl: *gui.DrawList, cam: Camera, g: NodeGeom, collapsed: bool) void {
    const tl = cam.worldToScreen(canvas.togglePos(g));
    const size = canvas.TOGGLE_SIZE * cam.zoom;
    const rect = gui.Rect{ .x = safeI32(tl.x), .y = safeI32(tl.y), .w = safeU32(size), .h = safeU32(size) };
    dl.rectFilled(rect, PAL_BG) catch {};
    dl.rectOutline(rect, BORDER_COL, 1) catch {};
    dl.text(.{ .x = rect.x + 3, .y = rect.y + 2 }, if (collapsed) "+" else "-", TITLE_COL) catch {};
}

/// 展開中グループの薄い枠（現在のメンバー配置の bbox 外周）+ ヘッダー（タイトル+トグル、group.pos アンカー）。
/// 中身（TR grid 等）の描画は 40.7.2。
fn drawExpandedGroupFrame(app: *const App, dl: *gui.DrawList, cam: Camera, nodes: []const NodeGeom, gid: group.GroupId, gr: group.Group) void {
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
        const tl = cam.worldToScreen(.{ .x = bbox_min.x - margin, .y = bbox_min.y - margin });
        const br = cam.worldToScreen(.{ .x = bbox_max.x + margin, .y = bbox_max.y + margin });
        const rect = gui.Rect{ .x = safeI32(tl.x), .y = safeI32(tl.y), .w = safeU32(br.x - tl.x), .h = safeU32(br.y - tl.y) };
        dl.rectOutline(rect, HOVER_COL, 1) catch {};
    }

    const header = NodeGeom{ .handle = group.handleOfGroup(gid), .pos = gr.pos, .n_in = 0, .n_out = 0 };
    const htl = cam.worldToScreen(header.pos);
    const hsz = canvas.nodeSize(header).scale(cam.zoom);
    const hrect = toRect(htl, hsz);
    const hsel = itemIsHandle(app.selected, header.handle);
    dl.rectFilled(hrect, NODE_BG) catch {};
    dl.rectOutline(hrect, if (hsel) SEL_COL else BORDER_COL, if (hsel) 2 else 1) catch {};
    dl.text(.{ .x = hrect.x + 6, .y = hrect.y + 4 }, gr.kind.displayName(), TITLE_COL) catch {};
    drawToggle(dl, cam, header, false);
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

fn macroGridGeometry(cam: Camera, box_pos: Vec2f) stepgrid.Geometry {
    const g = canvas.macroGridGeometry(cam, box_pos);
    return .{
        .origin_x = g.origin_x,
        .origin_y = g.origin_y,
        .cell_w = g.cell_w,
        .cell_h = g.cell_h,
        .step_pitch = g.step_pitch,
        .row_pitch = g.row_pitch,
    };
}

/// 畳み箱本体に TR grid（drum 2 レーン）/ 303 行（on/accent/slide + pitch 段）+ playhead を描く。
fn drawMacroGrid(app: *App, dl: *gui.DrawList, cam: Camera, box: NodeGeom, gid: group.GroupId) void {
    const kind = app.ledger.groups[gid].kind;
    const seqs = collectStepSeqMembers(app, gid);
    if (seqs.n == 0) return;

    // playhead 列: process は現 step 評価後に step++ するので、直近発音した列は (step + STEPS-1) % STEPS。
    const head_seq: StepSeqPtr = app.dyn.ptrOf(.step_seq, seqs.items[0]);
    const playhead: u8 = (head_seq.loadStep() + stepgrid.STEP_COUNT - 1) % stepgrid.STEP_COUNT;
    const geometry = macroGridGeometry(cam, box.pos);

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

/// world 点がどの collapsed マクロ箱の grid セルに当たるか（クリック可能行のみ）。
const GridHit = struct { gid: group.GroupId, cell: stepgrid.GridCell };
fn hitMacroGrid(app: *const App, world_pt: Vec2f) ?GridHit {
    for (app.ledger.groups, 0..) |g, i| {
        if (!g.active or !g.collapsed) continue;
        const gid: group.GroupId = @intCast(i);
        const local = world_pt.sub(g.pos);
        const geometry = macroGridGeometry(.{ .zoom = 1.0 }, .{ .x = 0, .y = 0 });
        if (stepgrid.hitTest(geometry, local.x, local.y, clickableRows(g))) |cell| return .{ .gid = gid, .cell = cell };
    }
    return null;
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
        var cmd = patternEditBase(app);
        const mask = bitOf(hit.cell.step);
        switch (kind) {
            .drum_machine => switch (hit.cell.row) {
                0 => cmd.kick.on ^= mask,
                1 => cmd.hat.on ^= mask,
                2 => cmd.clap.on ^= mask,
                else => return,
            },
            .bass_machine => switch (hit.cell.row) {
                0 => cmd.bass.on ^= mask,
                1 => cmd.bass.accent ^= mask,
                2 => cmd.bass.slide ^= mask,
                else => return,
            },
        }
        _ = publishPatternCommand(app, cmd);
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
    // 可視化帯の上ではキャンバスの hover を出さない。
    if (app.pointInInspectorPanel() or app.mouse.y >= app.canvasH()) {
        app.hover = null;
        return;
    }
    var node_buf: [MAX_MODULES]NodeGeom = undefined;
    var edge_buf: [MAX_EDGES]group.DisplayEdge = undefined;
    const nodes = node_buf[0..app.buildNodes(&node_buf)];
    const dedges = edge_buf[0..app.buildDisplayEdges(&edge_buf)];
    const mw = app.camera.screenToWorld(app.mouse);
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

fn onMouseDown(app: *App) void {
    // Transport/Inspector の mouse は GUI Context 側へ渡す。canvas の選択/drag/zoom と競合させない。
    if (app.pointInInspectorPanel() or app.pointInTransportPanel()) return;
    // パレットは screen 座標で world hit より先に判定（追加/マクロ追加。1 操作 1 publish は
    // addByPaletteIndex/macro.buildDrumMachine 内）。
    const buttons = paletteButtons();
    if (canvas.hitTestPalette(app.mouse, &buttons)) |ki| {
        addByPaletteIndex(app, ki) catch {}; // PoolFull/TooManyModules は無視（追加せず）
        return;
    }
    // 下端の可視化帯上のクリックはキャンバス操作にしない（選択/pan/配線を開始しない）。
    if (app.mouse.y >= app.canvasH()) {
        app.selected = null;
        app.drag = .none;
        return;
    }
    const mw = app.camera.screenToWorld(app.mouse);

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
        app.drag = .{ .pan = .{ .start_pan = app.camera.pan, .start_mouse = app.mouse } };
    }
}

fn onMouseUp(app: *App) void {
    if (app.drag == .cable) {
        const pend = app.drag.cable;
        var node_buf: [MAX_MODULES]NodeGeom = undefined;
        const nodes = node_buf[0..app.buildNodes(&node_buf)];
        const mw = app.camera.screenToWorld(app.mouse);
        if (canvas.hitTestPort(mw, nodes)) |target_raw| {
            // origin/target は as-hit のまま保持していた可能性がある（合成 handle）ので、commitConnect の
            // 前段で resolvePort して実 PortRef へ解決する（合成 handle を dyn/commitConnect へ渡さない）。
            if (app.ledger.resolvePort(pend.origin)) |origin_real| {
                if (app.ledger.resolvePort(target_raw)) |target_real| {
                    commitConnect(app, origin_real, target_real, pend.detach);
                }
            }
        } else if (pend.detach) |d| {
            // 空きへドロップ = drag-off 切断（1 publish）。origin だけの pending は何もしない。
            app.dyn.disconnect(d.dst_handle, d.dst_in);
            app.dyn.publish() catch {};
            app.refreshAllExposed();
        }
    }
    app.drag = .none;
}

/// 接続を全事前検証してから 1 publish で確定する。drag-off の旧接続(detach)も同じ commit で処理し、
/// 「1 操作=最大 1 publish」「無効/失敗時は既存接続を壊さない」を守る（切断を先行させない）。
/// a/b/detach は常に実 PortRef/CableRef（呼び出し側が resolvePort 済み。合成 handle はここに来ない）。
fn commitConnect(app: *App, a: PortRef, b: PortRef, detach: ?CableRef) void {
    const rc = canvas.resolveConnection(a, b) orelse return; // 方向不正（out-out/in-in）→ 何もしない（旧接続維持）
    const src = rc.src;
    const dst = rc.dst;
    // 事前検証: active / index 範囲 / 種別一致（dyn accessor は範囲外で null を返す）。落ちれば旧接続維持。
    if (!app.dyn.slotActive(src.handle) or !app.dyn.slotActive(dst.handle)) return;
    const sk = app.dyn.outKindOf(src.handle, src.index) orelse return;
    const dk = app.dyn.inKindOf(dst.handle, dst.index) orelse return;
    if (sk != dk) return; // 種別不一致は拒否（旧接続維持）
    // 全 OK。ここから destructive: drag-off 元入力を外し（宛先と異なるとき）、宛先が既接続なら置換、connect、1 publish。
    if (detach) |d| {
        if (!(d.dst_handle == dst.handle and d.dst_in == dst.index)) app.dyn.disconnect(d.dst_handle, d.dst_in);
    }
    if (edgeForInput(app, dst.handle, dst.index) != null) app.dyn.disconnect(dst.handle, dst.index);
    app.dyn.connect(src.handle, src.index, dst.handle, dst.index) catch {};
    app.dyn.publish() catch {};
    app.refreshAllExposed(); // 境界が変わりうるので expose を再導出（イベント時のみ）
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
    const cy: f32 = @as(f32, @floatFromInt(app.fb_h)) * 0.4 + casc * 18;
    inline for (PALETTE, 0..) |entry, i| {
        if (i == ki) {
            switch (entry) {
                .primitive => |kind| {
                    // primitive は従来どおり（見切れ clamp なし＝挙動不変）。
                    const pos = app.camera.screenToWorld(.{ .x = cx, .y = cy });
                    const h = try app.dyn.add(kind, .{});
                    app.layout[h] = pos;
                    app.selected = .{ .node = h };
                    try app.dyn.publish();
                },
                // macro は展開時 footprint が既定 fb に収まるよう screen anchor を clamp してから配置する。
                .macro_kind => |mk| try addMacro(app, mk, .{ .x = cx, .y = cy }),
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
    const zoom = app.camera.zoom;
    const margin: f32 = 16;
    const top_limit: f32 = paletteBottom + margin; // 2段パレット帯の下端より下に置く
    const fbw: f32 = app.canvasW();
    const fbh: f32 = @floatFromInt(app.fb_h);
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
            const gid = app.ledger.alloc() orelse {
                // 台帳枯渇（MAX_GROUPS 上限。極めて稀）: 公開済みメンバーを畳んで戻す（1 publish）。
                for (members) |m| app.dyn.removeModule(m);
                app.dyn.publish() catch {};
                return;
            };
            const pos = clampMacroPos(app, anchor, macroFootprint(app, &members, &DRUM_OFFSETS));
            const g = &app.ledger.groups[gid];
            g.kind = .drum_machine;
            g.collapsed = true;
            g.pos = pos;
            for (members, DRUM_OFFSETS) |m, off| {
                app.ledger.assign(m, gid);
                app.layout[m] = pos.add(off);
            }
            // テンプレ明示 expose（§3.2: clock in = cdiv.in0(gate) / audio out = mix.out0(audio)）。
            g.exposed_in[0] = .{ .member = h.cdiv, .port = 0, .is_input = true };
            group.setLabel(&g.exposed_in[0], "clock");
            g.n_in = 1;
            g.template_n_in = 1;
            g.exposed_out[0] = .{ .member = h.mix, .port = 0, .is_input = false };
            group.setLabel(&g.exposed_out[0], "audio");
            g.n_out = 1;
            g.template_n_out = 1;
            app.selected = .{ .group = gid };
        },
        .bass_machine => {
            const h = try macro.buildBassMachine(app.dyn);
            const members = [_]Handle{ h.seq, h.vco, h.vcf, h.env, h.vca };
            const gid = app.ledger.alloc() orelse {
                for (members) |m| app.dyn.removeModule(m);
                app.dyn.publish() catch {};
                return;
            };
            const pos = clampMacroPos(app, anchor, macroFootprint(app, &members, &BASS_OFFSETS));
            const g = &app.ledger.groups[gid];
            g.kind = .bass_machine;
            g.collapsed = true;
            g.pos = pos;
            for (members, BASS_OFFSETS) |m, off| {
                app.ledger.assign(m, gid);
                app.layout[m] = pos.add(off);
            }
            // テンプレ明示 expose（§3.3: clock in = seq.in0(gate) / audio out = vca.out0(audio)）。
            g.exposed_in[0] = .{ .member = h.seq, .port = 0, .is_input = true };
            group.setLabel(&g.exposed_in[0], "clock");
            g.n_in = 1;
            g.template_n_in = 1;
            g.exposed_out[0] = .{ .member = h.vca, .port = 0, .is_input = false };
            group.setLabel(&g.exposed_out[0], "audio");
            g.n_out = 1;
            g.template_n_out = 1;
            app.selected = .{ .group = gid };
        },
    }
}

/// 選択中のノード/ケーブル/グループを削除（Delete/Backspace）。
fn deleteSelected(app: *App) void {
    if (app.selected) |it| {
        switch (it) {
            .node => |h| {
                // 展開中グループのメンバー個別削除は先に台帳を同期する（メンバー 0 で自動消滅）。
                purgeParamOverrides(app, h);
                if (app.ledger.group_of[h] != null) app.ledger.unassign(h);
                app.dyn.removeModule(h);
                app.dyn.publish() catch {};
                app.refreshAllExposed();
                app.selected = null;
                app.hover = null;
            },
            .cable => |cr| {
                app.dyn.disconnect(cr.dst_handle, cr.dst_in);
                app.dyn.publish() catch {};
                app.refreshAllExposed();
                app.selected = null;
            },
            .group => |gid| {
                // グループ削除: メンバー全 removeModule + ledger.free + 1 publish（RT へは 1 回だけ反映）。
                var h: Handle = 0;
                while (h < MAX_MODULES) : (h += 1) {
                    if (app.ledger.group_of[h] != null and app.ledger.group_of[h].? == gid) {
                        purgeParamOverrides(app, h);
                        app.dyn.removeModule(h);
                    }
                }
                app.ledger.free(gid);
                app.dyn.publish() catch {};
                // 削除グループのメンバーと境界接続していた別グループの auto expose が stale に残らないよう再導出。
                app.refreshAllExposed();
                app.selected = null;
                app.hover = null;
            },
            .port => {},
        }
    }
}

fn onMouseMove(app: *App) void {
    switch (app.drag) {
        .none => updateHover(app),
        .pan => |p| {
            app.camera.pan = p.start_pan.add(app.mouse.sub(p.start_mouse));
        },
        .node => |nd| {
            const mw = app.camera.screenToWorld(app.mouse);
            app.layout[nd.handle] = mw.add(nd.grab_offset);
        },
        .group => |gd| {
            const mw = app.camera.screenToWorld(app.mouse);
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
        const tl = app.camera.worldToScreen(g.pos);
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
    const band_y0: usize = @intFromFloat(app.canvasH());
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

    app = App{ .patch = patch, .dyn = patch.graph, .io = init.io, .sample_rate = sr_u32 };
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

    var dl = gui.DrawList.init(allocator);
    defer dl.deinit();
    var gui_ctx = gui.Context.init(allocator, gui.default_font);
    defer gui_ctx.deinit();

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
    // ヘッドレス検証 harness の custom action を登録（harness 無効時は no-op。TASK-65）。
    app.cmd_exec = platform.command.Executor.init(.{ .ctx = &app, .run = dispatchModularAction });
    app.cmd_exec.log = &app.cmd_log;
    platform.setCommandExecutor(&app.cmd_exec);
    registerPatchActions(&app);
    registerActions(&app);
    registerGenStateSync(&app);

    device.start() catch |err| {
        std.debug.print("audio.start failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer device.stop();
    std.debug.print("apps/patch: ドラッグでポート間を配線 / パレットで追加 / Delete で削除 / scroll=zoom。音が鳴ります。\n", .{});

    var stereo: [2048]f32 = undefined;
    var mono: [1024]f32 = undefined;
    var running = true;
    main_loop: while (running and window.pollEvents()) {
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

        while (window.nextEvent()) |ev| {
            switch (ev) {
                .quit => running = false,
                .key_down => |k| {
                    switch (k.key) {
                        .ESCAPE => running = false,
                        .DELETE, .BACKSPACE => deleteSelected(&app),
                        else => {},
                    }
                },
                .key_up => {},
                .char_input => {},
                .gamepad_connected, .gamepad_disconnected => {}, // TASK-80.1: 本 app 未消費（cross-cutting Event 追加）
                .composition_changed => {}, // TASK-79.6.1: composition 未消費（inline preedit は 79.6.2）
                .menu_command => {}, // TASK-97.1: 97.2 の App.dispatchCommand 統合前は未消費
                .mouse_move => |m| {
                    app.mouse = .{ .x = @floatFromInt(m.x), .y = @floatFromInt(m.y) };
                    gui_ctx.pushEvent(.{ .mouse_move = .{ .x = m.x, .y = m.y, .modifiers = 0 } });
                    if (!app.pointInInspectorPanel() and
                        !app.pointInTransportPanel() and
                        gui_ctx.state.active_id == 0) onMouseMove(&app);
                },
                .mouse_down => |m| {
                    const button: u8 = if (m.button == .left) 0 else if (m.button == .right) 1 else 2;
                    gui_ctx.pushEvent(.{ .mouse_down = .{ .x = m.x, .y = m.y, .button = button, .modifiers = 0 } });
                    if (m.button == .left) {
                        app.mouse = .{ .x = @floatFromInt(m.x), .y = @floatFromInt(m.y) };
                        if (!app.pointInInspectorPanel() and
                            !app.pointInTransportPanel() and
                            gui_ctx.state.active_id == 0) onMouseDown(&app);
                    }
                },
                .mouse_up => |m| {
                    const button: u8 = if (m.button == .left) 0 else if (m.button == .right) 1 else 2;
                    gui_ctx.pushEvent(.{ .mouse_up = .{ .x = m.x, .y = m.y, .button = button, .modifiers = 0 } });
                    if (m.button == .left) {
                        app.mouse = .{ .x = @floatFromInt(m.x), .y = @floatFromInt(m.y) };
                        if (gui_ctx.state.active_id == 0 and
                            !app.pointInInspectorPanel() and
                            !app.pointInTransportPanel()) onMouseUp(&app);
                    }
                },
                .mouse_scroll => |s| {
                    app.mouse = .{ .x = @floatFromInt(s.x), .y = @floatFromInt(s.y) };
                    gui_ctx.pushEvent(.{ .mouse_scroll = .{ .x = s.x, .y = s.y, .dx = s.dx, .dy = s.dy, .modifiers = 0 } });
                    if (!app.pointInInspectorPanel() and !app.pointInTransportPanel()) {
                        const factor: f32 = if (s.dy > 0) 1.1 else if (s.dy < 0) 1.0 / 1.1 else 1.0;
                        app.camera.zoomAt(app.mouse, factor);
                        updateHover(&app);
                    }
                },
            }
        }

        // A/D: 活性度更新 + tap 対象の選択・publish（描画の直前・イベント反映後）。
        // 生成レイヤ scalar は GUI/action の最新値を制御レートで atomic publish する。
        publishControls(app.patch, app.params);
        updateViz(&app);
        app.beginParamFrame();
        const transport_model = transportModel(&app);

        @memset(fb.pixels, BG);
        dl.reset(fb.width, fb.height);
        drawFrame(&app, &dl);
        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        gui.render(target, &dl, gui.default_font);
        const ir = canvas.inspectorVisibleRect(@floatFromInt(fb.width), app.canvasH(), app.inspector_open);
        const tr = canvas.transportVisibleRect(@floatFromInt(fb.width), app.canvasH(), app.transport_open);
        gui_ctx.beginBox(.{ .direction = .row, .width = .{ .fixed = @intCast(fb.width) }, .height = .{ .fixed = @intCast(fb.height) } });
        transport.draw(&gui_ctx, .{ .x = safeI32(tr.x), .y = safeI32(tr.y), .w = safeU32(tr.w), .h = safeU32(tr.h) }, safeI32(ir.x), @intCast(fb.height), &transport_model, &app.transport_open, &app, displayTransportValue, &app, transportParamChanged, transportMuteChanged);
        inspector.drawPanel(&gui_ctx, app.dyn, if (app.selected) |item| switch (item) {
            .node => |h| h,
            else => null,
        } else null, .{ .x = safeI32(ir.x), .y = safeI32(ir.y), .w = safeU32(ir.w), .h = safeU32(ir.h) }, &app.inspector_open, &app, snapshotParamCallback, &app, displayInspectorValue, &app, inspectorChanged);
        gui_ctx.endBox();
        if (!gui_ctx.input.mouse_buttons.left) app.releaseParamEdits();
        gui_ctx.endFrame();
        app.captureParamRows(&gui_ctx);
        app.advanceParamEdits();
        app.drawGhostMarkers(&gui_ctx.draw_list);
        gui.render(target, &gui_ctx.draw_list, gui.default_font);
        // 可視化帯は最後に直描き（下地 @memset で canvas 内容を上書き＝帯が常に最前面）。
        drawVizBand(&app, fb, spec, osc, &meter);

        window.present();
        platform.frameDelay(16_000_000);
    }
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
    var node_buf: [MAX_MODULES]NodeGeom = undefined;
    var edge_buf: [MAX_EDGES]Edge = undefined;
    const nodes = node_buf[0..app.buildRawNodes(&node_buf)];
    const edges = edge_buf[0..app.buildFlatEdges(&edge_buf)];
    const oc = offscreenOf(app);
    const view = app.dyn.currentView();

    var off: usize = 0;
    const head = std.fmt.bufPrint(buf[off..], "{{\"nodes\":[", .{}) catch return errDigest(buf);
    off += head.len;
    for (nodes, 0..) |n, i| {
        const sep: []const u8 = if (i == 0) "" else ",";
        const kn = if (app.dyn.kindOf(n.handle)) |k| @tagName(k) else "?";
        const piece = std.fmt.bufPrint(buf[off..], "{s}{{\"h\":{d},\"kind\":\"{s}\",\"nin\":{d},\"nout\":{d}}}", .{ sep, n.handle, kn, n.n_in, n.n_out }) catch return errDigest(buf);
        off += piece.len;
    }
    const mid = std.fmt.bufPrint(buf[off..], "],\"edges\":[", .{}) catch return errDigest(buf);
    off += mid.len;
    for (edges, 0..) |e, i| {
        const sep: []const u8 = if (i == 0) "" else ",";
        const piece = std.fmt.bufPrint(buf[off..], "{s}[{d},{d},{d},{d}]", .{ sep, e.src_handle, e.src_out, e.dst_handle, e.dst_in }) catch return errDigest(buf);
        off += piece.len;
    }
    const tail = std.fmt.bufPrint(buf[off..], "],\"output\":{d},\"cam\":{{\"zoom\":{d:.3},\"pan\":[{d:.1},{d:.1}]}}," ++
        "\"fb_size\":[{d},{d}],\"offscreen\":{{\"node\":{d},\"port\":{d},\"cable\":{d}}}}}", .{
        view.output, app.camera.zoom, app.camera.pan.x, app.camera.pan.y,
        app.fb_w,    app.fb_h,        oc.node,          oc.port,
        oc.cable,
    }) catch return errDigest(buf);
    off += tail.len;
    return buf[0..off];
}

fn errDigest(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"error\":\"digest overflow\"}}", .{}) catch buf[0..0];
}

fn patchSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var node_buf: [MAX_MODULES]NodeGeom = undefined;
    const nodes = node_buf[0..app.buildRawNodes(&node_buf)];
    // digest（1024B 以内）に layout 座標を足した詳細スナップショット。
    var dbuf: [1024]u8 = undefined;
    const d = patchDigest(ctx, &dbuf);
    const body = if (d.len > 0 and d[d.len - 1] == '}') d[0 .. d.len - 1] else d;
    var out: [2048]u8 = undefined;
    var off: usize = 0;
    {
        const piece = std.fmt.bufPrint(out[off..], "{s},\"layout\":[", .{body}) catch return allocator.dupe(u8, d);
        off += piece.len;
    }
    for (nodes, 0..) |n, i| {
        const sep: []const u8 = if (i == 0) "" else ",";
        const piece = std.fmt.bufPrint(out[off..], "{s}{{\"h\":{d},\"x\":{d:.1},\"y\":{d:.1}}}", .{ sep, n.handle, n.pos.x, n.pos.y }) catch return allocator.dupe(u8, d);
        off += piece.len;
    }
    const tail = std.fmt.bufPrint(out[off..], "]}}", .{}) catch return allocator.dupe(u8, d);
    off += tail.len;
    return allocator.dupe(u8, out[0..off]);
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
    const raw: f32 = switch (value) {
        .scalar => |v| v,
        .choice => |v| @floatFromInt(v),
    };
    queueParamOverride(app, handle, name, raw) catch {};
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

/// `modular.ModuleKind` → comptime dispatch で `dyn.add(k, .{})`。`addByPaletteIndex` の
/// `inline for` と同型の「runtime enum → comptime 呼び出し」パターン（`switch (kind) { inline else
/// => |k| ... }` は各 tag ごとに comptime 特殊化された分岐を生成し、分岐内の `k` は comptime 値になる）。
/// `actionAddNode`（kind 名）と `load_graph`（`graph_io.decodeGraph` が返す typed kind）の両方が使う。
fn addNodeByKind(app: *App, kind: modular.ModuleKind) !Handle {
    return switch (kind) {
        inline else => |k| app.dyn.add(k, .{}),
    };
}

/// kind 名（`modular.ModuleKind` の tag 名。31種、パレットの15種より広い）→ `addNodeByKind`。
fn addNodeByKindName(app: *App, name: []const u8) !Handle {
    const kind = std.meta.stringToEnum(modular.ModuleKind, name) orelse return error.UnknownKind;
    return addNodeByKind(app, kind);
}

fn actionAddNode(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    const p = try actions.parseAddNode(args);
    const h = try addNodeByKindName(app, p.kind);
    if (p.x) |x| {
        if (p.y) |y| app.layout[h] = .{ .x = x, .y = y };
    }
    try app.dyn.publish();
    return std.fmt.bufPrint(buf, "handle={d}", .{h}) catch "ok";
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
    const h = try toHandle(try actions.parseUsize(args));
    if (!app.dyn.slotActive(h)) return error.InvalidHandle;
    // 削除で stale になる selected/hover を、まだ edge が残っている削除前に判定しておく。
    const clear_selected = if (app.selected) |it| refsHandleForRemoval(app, it, h) else false;
    const clear_hover = if (app.hover) |it| refsHandleForRemoval(app, it, h) else false;
    // 展開中グループのメンバー個別削除は先に台帳を同期する（`deleteSelected` の `.node` 分岐と同型）。
    if (app.ledger.group_of[h] != null) app.ledger.unassign(h);
    purgeParamOverrides(app, h);
    app.dyn.removeModule(h);
    try app.dyn.publish();
    app.refreshAllExposed();
    if (clear_selected) app.selected = null;
    if (clear_hover) app.hover = null;
    return "ok";
}

/// `commitConnect` と同じ「検証してから壊す」順序（active/種別一致を先に検証 → 検証 OK なら
/// 宛先の既存接続を置換）で、無効な接続要求で既存接続を壊さない。
fn actionConnect(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const p = try actions.parseFourUsize(args);
    const src_h = try toHandle(p.a);
    const dst_h = try toHandle(p.c);
    if (!app.dyn.slotActive(src_h) or !app.dyn.slotActive(dst_h)) return error.InvalidHandle;
    const sk = app.dyn.outKindOf(src_h, p.b) orelse return error.InvalidPort;
    const dk = app.dyn.inKindOf(dst_h, p.d) orelse return error.InvalidPort;
    if (sk != dk) return error.PortKindMismatch;
    app.dyn.disconnect(dst_h, p.d); // 検証後の置換（宛先が既接続でも安全に上書き）
    try app.dyn.connect(src_h, p.b, dst_h, p.d);
    try app.dyn.publish();
    app.refreshAllExposed();
    return "ok";
}

fn actionDisconnect(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const p = try actions.parseTwoUsize(args);
    const dst_h = try toHandle(p.a);
    if (!app.dyn.slotActive(dst_h)) return error.InvalidHandle;
    // 入力 port の範囲を検証（connect と同じ fail-fast。存在しない dst_in への typo を握りつぶさない。
    // `inKindOf` は範囲外/非 active で null を返す）。
    if (app.dyn.inKindOf(dst_h, p.b) == null) return error.InvalidPort;
    app.dyn.disconnect(dst_h, p.b);
    try app.dyn.publish();
    app.refreshAllExposed();
    return "ok";
}

// ============================================================================
// save_graph / load_graph（TASK-65 serialize。probe `patch` と対称の永続化口）。
//
// ホットパス宣言: save/load はイベント時のみ（action 1回につき1回。std.Io のブロッキング file I/O は
// main thread の pollGate 内で完結する）。RT 経路（DynGraph.processBlock）には一切触れない。
//
// スコープ: `graph_io.zig` と同じく生ノード（add/remove/connect/disconnect）のみ。マクロの折り畳み
// 情報は保存されない。load_graph は「既存グラフの置換」意味論: 現在の全ノードを削除してから復元する
// （pixie の `open` が canvas 全体を差し替えるのと同じ考え方）。ハンドル番号は保存値をそのまま
// 再現できるとは限らない（`DynGraph.add` が空き slot から動的採番するため）ので、load 側で
// 旧 handle→新 handle の対応表を作って EDGE を訳し直す。
// ============================================================================

fn actionSaveGraph(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const path = try actions.parsePath(args);

    var node_buf: [MAX_MODULES]graph_io.NodeEntry = undefined;
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
    var edge_buf: [MAX_EDGES]graph_io.EdgeEntry = undefined;
    for (flat, 0..) |e, i| {
        edge_buf[i] = .{ .src_handle = e.src_handle, .src_out = e.src_out, .dst_handle = e.dst_handle, .dst_in = e.dst_in };
    }

    try graph_io.saveGraph(app.io, path, std.heap.c_allocator, node_buf[0..nn], edge_buf[0..flat.len]);
    return "ok";
}

/// 既存グラフを全消去する（load_graph の「置換」意味論。台帳/選択/hover も併せてリセット）。
fn clearGraph(app: *App) void {
    purgeParamOverrides(app, null);
    var h: Handle = 0;
    while (h < MAX_MODULES) : (h += 1) {
        if (!app.dyn.slotActive(h)) continue;
        if (app.ledger.group_of[h] != null) app.ledger.unassign(h);
        app.dyn.removeModule(h);
    }
    app.ledger = .{}; // グループ台帳も完全リセット（load_graph はマクロ折り畳み情報を持たない）
    app.selected = null;
    app.hover = null;
    app.drag = .none;
}

fn actionLoadGraph(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    const path = try actions.parsePath(args);
    const gpa = std.heap.c_allocator;
    var decoded = try graph_io.loadGraph(app.io, gpa, path);
    defer decoded.deinit(gpa);

    // 容量事前検証（「検証してから壊す」。commitConnect と同方針）: clearGraph() で retired にした
    // slot は RT が次 publish を consume するまで（RCU grace）この action 呼び出し内では再利用でき
    // ない。`DynGraph.freeHandleCount()`/`poolFreeCount(k)` は「今 add したら確保できる数」を
    // 既存の active/retired(未 reclaim) を織り込んで返す（`add()` の reclaim 条件と同一式）ため、
    // clearGraph 前に読んでも clearGraph 直後の実際の空きと一致する（retire は「active→retired」
    // であって pool/handle 占有を解放しないため）。
    // 事前に2種の容量（全体 handle 数 / kind 別 pool 数）を検証し、どちらか超過なら既存グラフを
    // 破壊せずに拒否する（黙って一部だけ復元して「成功」を返すのを防ぐ。codex 指摘。当初
    // `MAX_MODULES - activeCount()` という手書き計算だったが、(a) 既存 retired 分を見落とす、
    // (b) kind 別 pool cap を見ない、の2点で不十分だったため公開 API に置き換えた）。
    if (decoded.nodes.len > app.dyn.freeHandleCount()) return error.TooManyNodesForCapacity;
    inline for (@typeInfo(modular.ModuleKind).@"enum".fields) |kf| {
        const k: modular.ModuleKind = @enumFromInt(kf.value);
        var need: usize = 0;
        for (decoded.nodes) |n| {
            if (n.kind == k) need += 1;
        }
        if (need > app.dyn.poolFreeCount(k)) return error.TooManyNodesForCapacity;
    }

    clearGraph(app);

    // 旧 handle → 新 handle 対応表（DynGraph.add は空き slot から動的採番するため保存値は再現されない）。
    // add が失敗（TooManyModules/PoolFull）したノードは skip（fail-soft。addByPaletteIndex と同方針）。
    // 実際に復元できた数を数え、返り値に「要求数/復元数」を出す（部分成功を隠さない。codex 指摘）。
    var mapping = [_]?Handle{null} ** MAX_MODULES;
    var nodes_restored: usize = 0;
    for (decoded.nodes) |n| {
        if (n.handle >= MAX_MODULES) continue; // 破損/範囲外 handle は skip
        const nh = addNodeByKind(app, n.kind) catch continue;
        app.layout[nh] = .{ .x = n.x, .y = n.y };
        mapping[n.handle] = nh;
        nodes_restored += 1;
    }
    var edges_restored: usize = 0;
    for (decoded.edges) |e| {
        if (e.src_handle >= MAX_MODULES or e.dst_handle >= MAX_MODULES) continue;
        const src = mapping[e.src_handle] orelse continue; // 対応ノードが skip されていたら edge も skip
        const dst = mapping[e.dst_handle] orelse continue;
        app.dyn.connect(src, e.src_out, dst, e.dst_in) catch continue; // 型不一致/範囲外は skip（fail-soft）
        edges_restored += 1;
    }

    try app.dyn.publish();
    app.refreshAllExposed();
    return std.fmt.bufPrint(buf, "nodes={d}/{d} edges={d}/{d}", .{
        nodes_restored, decoded.nodes.len, edges_restored, decoded.edges.len,
    }) catch "ok";
}

/// 6 action を一括登録する（`platform.init()` 後・main loop 前に呼ぶ。harness 無効時は
/// `registerAction` 自体が no-op なので通常実行に影響しない）。
fn registerPatchActions(app: *App) void {
    platform.registerAction(.{ .name = "select_node", .ctx = app, .run = actionSelectNode });
    platform.registerAction(.{ .name = "observe_param", .ctx = app, .run = actionObserveParam });
    platform.registerAction(.{ .name = "add_node", .ctx = app, .run = actionAddNode });
    platform.registerAction(.{ .name = "remove_node", .ctx = app, .run = actionRemoveNode });
    platform.registerAction(.{ .name = "connect", .ctx = app, .run = actionConnect });
    platform.registerAction(.{ .name = "disconnect", .ctx = app, .run = actionDisconnect });
    platform.registerAction(.{ .name = "save_graph", .ctx = app, .run = actionSaveGraph });
    platform.registerAction(.{ .name = "load_graph", .ctx = app, .run = actionLoadGraph });
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

fn graphNetsyncExport(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app = actionApp(ctx);
    var node_buf: [MAX_MODULES]graph_io.NodeEntry = undefined;
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
    var edge_buf: [MAX_EDGES]graph_io.EdgeEntry = undefined;
    for (flat, 0..) |e, i| {
        edge_buf[i] = .{ .src_handle = e.src_handle, .src_out = e.src_out, .dst_handle = e.dst_handle, .dst_in = e.dst_in };
    }
    return graph_io.encodeGraph(allocator, node_buf[0..nn], edge_buf[0..flat.len]);
}

fn graphNetsyncImport(ctx: *anyopaque, bytes: []const u8) anyerror!void {
    const app = actionApp(ctx);
    const gpa = std.heap.c_allocator;
    var decoded = try graph_io.decodeGraph(gpa, bytes);
    defer decoded.deinit(gpa);

    if (decoded.nodes.len > app.dyn.freeHandleCount()) return error.TooManyNodesForCapacity;
    inline for (@typeInfo(modular.ModuleKind).@"enum".fields) |kf| {
        const k: modular.ModuleKind = @enumFromInt(kf.value);
        var need: usize = 0;
        for (decoded.nodes) |n| {
            if (n.kind == k) need += 1;
        }
        if (need > app.dyn.poolFreeCount(k)) return error.TooManyNodesForCapacity;
    }

    clearGraph(app);

    var mapping = [_]?Handle{null} ** MAX_MODULES;
    for (decoded.nodes) |n| {
        if (n.handle >= MAX_MODULES) continue;
        const nh = addNodeByKind(app, n.kind) catch continue;
        app.layout[nh] = .{ .x = n.x, .y = n.y };
        mapping[n.handle] = nh;
    }
    for (decoded.edges) |e| {
        if (e.src_handle >= MAX_MODULES or e.dst_handle >= MAX_MODULES) continue;
        const src = mapping[e.src_handle] orelse continue;
        const dst = mapping[e.dst_handle] orelse continue;
        app.dyn.connect(src, e.src_out, dst, e.dst_in) catch continue;
    }

    try app.dyn.publish();
    app.refreshAllExposed();
}

fn registerGraphStateSync(app: *App) void {
    platform.registerStateSync(.{
        .ctx = app,
        .export_fn = graphNetsyncExport,
        .import_fn = graphNetsyncImport,
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
    const selected_h = if (app.selected) |item| switch (item) {
        .node => |h| h,
        else => return null,
    } else return null;
    if (!param_view.sameField(key, param_view.fieldKey(selected_h, key.name))) return null;
    const snapshot = modular.getParamSnapshot(app.dyn, selected_h, key.name) catch return null;
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
    return std.fmt.bufPrint(buf, "transport_open={d} inspector_open={d}", .{
        @intFromBool(app.transport_open),
        @intFromBool(app.inspector_open),
    }) catch return buf[0..0];
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
        else => -1,
    } else -1;
    const selected_kind = if (app.selected) |item| switch (item) {
        .node => |h| if (app.dyn.kindOf(h)) |k| @tagName(k) else "none",
        else => "none",
    } else "none";
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
    const result = std.fmt.bufPrint(buf, "selected_h={d} selected_kind={s} observed_h={d} observed_name={s} field={s} instant={s} transport={s} inspector={s} shown={s} dragging={d} override={d} ghost={d}", .{ selected_h, selected_kind, key.handle, key.name, field_text, instant_text, transport_text, inspector_text, shown_text, if (edit) |state| @intFromBool(state.dragging) else 0, @intFromBool(hasOverride(app, key)), @intFromBool(ghost) }) catch return buf[0..0];
    return result;
}

fn paramsSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app: *const App = @ptrCast(@alignCast(ctx));
    const key = observedField(app);
    var out: [4096]u8 = undefined;
    var off: usize = 0;
    const head = std.fmt.bufPrint(out[off..], "{{\"observed_h\":{d},\"observed_name\":\"{s}\",\"rows\":[", .{ key.handle, key.name }) catch return allocator.dupe(u8, "{}");
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
    app.editState(key).dragging = true;
}

fn transportMuteChanged(ctx: *anyopaque, name: []const u8, muted: bool) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    setMuteAndPublish(app, name, muted) catch {};
}

fn actionSetParam(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    var it = std.mem.tokenizeAny(u8, args, " \t");
    _ = it.next() orelse return error.Empty;
    _ = it.next() orelse return error.Empty;
    if (it.next() != null) {
        // Additive な 3 引数形式。従来の recipe 用 2 引数形式は下記のまま不変。
        const p = try actions.parseParamOverride(args);
        try queueParamOverride(app, p.handle, p.name, p.value);
    } else {
        const nf = try gen_actions.parseNameF32(args);
        try setParamAndPublish(app, nf.name, nf.value);
    }
    return "ok";
}

const MuteTrack = enum { kick, hat, clap, bass, pad };

fn actionSetMute(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const p = try gen_actions.parseNameBool(args);
    try setMuteAndPublish(app, p.name, p.on);
    return "ok";
}

const LockTrack = enum { kick, hat, clap, bass };

fn actionSetLock(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const p = try gen_actions.parseNameBool(args);
    const track = std.meta.stringToEnum(LockTrack, p.name) orelse return error.UnknownTrack;
    var cmd = patternEditBase(app);
    switch (track) {
        .kick => cmd.kick.lock = p.on,
        .hat => cmd.hat.lock = p.on,
        .clap => cmd.clap.lock = p.on,
        .bass => cmd.bass.lock = p.on,
    }
    _ = publishPatternCommand(app, cmd);
    return "ok";
}

fn actionSetEvolve(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const on = try gen_actions.parseBool01(args);
    var cmd = patternEditBase(app);
    cmd.evolve = on;
    _ = publishPatternCommand(app, cmd);
    return "ok";
}

const StepTarget = enum { kick, hat, clap, bass_on, bass_accent, bass_slide };

fn actionToggleStep(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
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
    _ = publishPatternCommand(app, cmd);
    return "ok";
}

fn actionSetPitch(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const p = try gen_actions.parseTwoU8(args); // a=step(0..15) b=deg(0..BASS_DEG_TOTAL-1)
    if (p.a >= 16) return error.StepOutOfRange;
    if (p.b >= BASS_DEG_TOTAL) return error.DegreeOutOfRange;
    var cmd = patternEditBase(app);
    cmd.bass.deg[p.a] = @intCast(p.b);
    _ = publishPatternCommand(app, cmd);
    return "ok";
}

// ============================================================================
// save_pattern / load_pattern（TASK-65 serialize。probe `modular` と対称の永続化口）。
//
// ホットパス宣言: save/load はイベント時のみ（action 1回につき1回。std.Io のブロッキング file I/O は
// main thread の pollGate 内で完結する）。RT 経路（LofiPatch.render→graph processBlock）には
// 一切触れない。保存対象は App.params（scalar）+ 現在の grid/303 pattern（PatternCommand の中身）。
// load は既存の pattern 編集 action と同じ経路（publishControls / pattern_rev++ → pattern_db.publish）
// をそのまま辿るため revision の二重採番は起きない。
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
    const patch = app.patch;
    const path = try gen_actions.parsePath(args);
    const cmd = stateToCommand(patch.snapshotState());
    try pattern_io.save(app.io, path, Params, app.params, patternToPayload(cmd), std.heap.c_allocator);
    return "ok";
}

fn actionLoadPattern(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch;
    const path = try gen_actions.parsePath(args);
    const loaded = try pattern_io.load(app.io, std.heap.c_allocator, path, Params);
    app.params = loaded.params;
    publishControls(patch, app.params);
    const cmd = payloadToPatternCommand(0, loaded.pattern);
    _ = publishPatternCommand(app, cmd);
    return "ok";
}

/// `action seed <n>`: main thread で parse → lock-free publish → 次 bar 境界で RT が適用（TASK-62.5.7）。
/// TASK-93: app.notation_seed も同期（mini-notation の `?` / 交代が seed 規約と整合する）。
fn actionSeed(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch;
    const n = try gen_actions.parseU64(args);
    app.notation_seed = n;
    patch.requestSeed(n);
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
    const idx = gen_actions.parseU8(args) catch {
        platform.setActionErrorDetail("bad_args", "usage: phrase_capture <idx 0..31>");
        return error.BadArgs;
    };
    // bass pool 上限 32 に合わせる（4 track 同 idx のため）
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
    return "ok";
}

/// `chain_set <chain_idx> <phrase_idx...>`（1..16）。
fn actionChainSet(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch;
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
        // drum pool 64 / bass 32。chain は共有なので 0..63 を許容（bass 解決時 OOB は RT で現行維持）
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
    return "ok";
}

/// `song_row <row_idx> <kick_chain> <hat_chain> <clap_chain> <bass_chain>`。
fn actionSongRow(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
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
    return "ok";
}

/// `song_len <n>`（0..64）。
fn actionSongLen(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
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
    return "ok";
}

/// `song_loop <0|1>`。
fn actionSongLoop(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch;
    const on = gen_actions.parseBool01(args) catch {
        platform.setActionErrorDetail("bad_args", "usage: song_loop <0|1>");
        return error.BadArgs;
    };
    app.song.loop = on;
    publishSong(app, patch);
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

/// `save_project <path>`: MPRJ（params+pattern+seed+song）。local_only・非記録。
fn actionSaveProject(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch;
    const path = try gen_actions.parsePath(args);
    const cmd = stateToCommand(patch.snapshotState());
    const st = patch.snapshotState();
    const seed = project_io.SeedPayload{
        .base_seed = st.base_seed,
        .notation_seed = app.notation_seed,
        .notation_counter = app.notation_counter,
    };
    try project_io.save(
        app.io,
        path,
        Params,
        app.params,
        patternToPayload(cmd),
        seed,
        songToPayload(app.song),
        std.heap.c_allocator,
    );
    return "ok";
}

/// `load_project <path>`: SongData publish + params publish + seed 復元。local_only・非記録。
fn actionLoadProject(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch;
    const path = try gen_actions.parsePath(args);
    const loaded = project_io.load(app.io, std.heap.c_allocator, path, Params) catch |err| {
        if (err == error.FileNotFound) {
            platform.setActionErrorDetail("file_not_found", "check path or use save_project first");
        }
        return err;
    };
    app.params = loaded.params;
    publishControls(patch, app.params);
    const cmd = payloadToPatternCommand(0, loaded.pattern);
    _ = publishPatternCommand(app, cmd);
    app.song = payloadToSong(app.song.rev +% 1, loaded.song);
    patch.controls.song_db.publish(app.song);
    app.notation_seed = loaded.seed.notation_seed;
    app.notation_counter = loaded.seed.notation_counter;
    patch.requestSeed(loaded.seed.base_seed);
    return "ok";
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
    app.last_quantized_cmd = publishPatternCommand(app, cmd);
    return "ok";
}

/// CommandLog の kind=normal を seq 順で Entry 化（TASK-62.5.8）。name/args は log 借用。
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

/// `recipe_save <path>`: CommandLog → recipe（app_name="modular"）。記録しない。
fn actionRecipeSave(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const gpa = std.heap.c_allocator;
    const path = try gen_actions.parsePath(args);
    const entries = try recipeEntriesFromLog(&app.cmd_log, gpa);
    defer gpa.free(entries);
    try recipe.save(app.io, path, .{ .app_name = "modular" }, entries, gpa);
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

    recipe.checkAppName(loaded.header.app_name, "modular") catch {
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
// executeAction(actor=.local_agent) で dispatch + 記録する。undo/transaction/probe 統合はしない。
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
    .{ .name = "save_pattern", .run = actionSavePattern },
    .{ .name = "load_pattern", .run = actionLoadPattern },
    .{ .name = "seed", .run = actionSeed },
    .{ .name = "pattern", .run = actionPattern },
    // TASK-91: Song/Chain/Phrase（recorded）
    .{ .name = "phrase_capture", .run = actionPhraseCapture },
    .{ .name = "chain_set", .run = actionChainSet },
    .{ .name = "song_row", .run = actionSongRow },
    .{ .name = "song_len", .run = actionSongLen },
    .{ .name = "song_loop", .run = actionSongLoop },
    .{ .name = "song_play", .run = actionSongPlay },
    .{ .name = "song_goto", .run = actionSongGoto },
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
                .actor = .local_agent,
                .record_policy = .record,
            }, buf);
            return res.output;
        }
    }.run;
}

/// 全 action を一括登録する（`platform.init()` 後・main loop 前に呼ぶ。harness 無効時は
/// `registerAction` 自体が no-op なので通常実行に影響しない）。記録 wrapper 経由。
fn registerActions(app: *App) void {
    platform.registerAction(.{ .name = "set_param", .ctx = app, .run = recordedAction("set_param") });
    platform.registerAction(.{ .name = "set_mute", .ctx = app, .run = recordedAction("set_mute") });
    platform.registerAction(.{ .name = "set_lock", .ctx = app, .run = recordedAction("set_lock") });
    platform.registerAction(.{ .name = "set_evolve", .ctx = app, .run = recordedAction("set_evolve") });
    platform.registerAction(.{ .name = "toggle_step", .ctx = app, .run = recordedAction("toggle_step") });
    platform.registerAction(.{ .name = "set_pitch", .ctx = app, .run = recordedAction("set_pitch") });
    platform.registerAction(.{ .name = "save_pattern", .ctx = app, .run = recordedAction("save_pattern") });
    platform.registerAction(.{ .name = "load_pattern", .ctx = app, .run = recordedAction("load_pattern") });
    platform.registerAction(.{ .name = "seed", .ctx = app, .run = recordedAction("seed") });
    // TASK-93: mini-notation。レシピには記法の生テキストを記録（replay 時 counter 順で再評価→決定的）。
    platform.registerAction(.{ .name = "pattern", .ctx = app, .run = recordedAction("pattern") });
    // TASK-91: Song/Chain/Phrase（recorded。seed+recipe 決定性に整合）
    platform.registerAction(.{ .name = "phrase_capture", .ctx = app, .run = recordedAction("phrase_capture") });
    platform.registerAction(.{ .name = "chain_set", .ctx = app, .run = recordedAction("chain_set") });
    platform.registerAction(.{ .name = "song_row", .ctx = app, .run = recordedAction("song_row") });
    platform.registerAction(.{ .name = "song_len", .ctx = app, .run = recordedAction("song_len") });
    platform.registerAction(.{ .name = "song_loop", .ctx = app, .run = recordedAction("song_loop") });
    platform.registerAction(.{ .name = "song_play", .ctx = app, .run = recordedAction("song_play") });
    platform.registerAction(.{ .name = "song_goto", .ctx = app, .run = recordedAction("song_goto") });
    // recipe（TASK-62.5.8）: メタ操作のため executor 非経由・CommandLog 非記録。local_only。
    platform.registerAction(.{ .name = "recipe_save", .ctx = app, .run = actionRecipeSave, .network_policy = .local_only });
    platform.registerAction(.{ .name = "recipe_replay", .ctx = app, .run = actionRecipeReplay, .network_policy = .local_only });
    // render（TASK-86）: offline WAV 書き出し。recipe_save と同じ local_only・CommandLog 非記録。
    platform.registerAction(.{ .name = "render", .ctx = app, .run = actionRender, .network_policy = .local_only });
    // TASK-91: プロジェクト直列化（save_pattern 同型・local_only・非記録）
    platform.registerAction(.{ .name = "save_project", .ctx = app, .run = actionSaveProject, .network_policy = .local_only });
    platform.registerAction(.{ .name = "load_project", .ctx = app, .run = actionLoadProject, .network_policy = .local_only });
}

fn netsyncExport(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app = actionApp(ctx);
    const patch = app.patch;
    const cmd = stateToCommand(patch.snapshotState());
    return pattern_io.encode(Params, allocator, app.params, patternToPayload(cmd));
}

fn netsyncImport(ctx: *anyopaque, bytes: []const u8) anyerror!void {
    const app = actionApp(ctx);
    const patch = app.patch;
    const loaded = try pattern_io.decode(Params, bytes);
    app.params = loaded.params;
    publishControls(patch, app.params);
    const cmd = payloadToPatternCommand(0, loaded.pattern);
    _ = publishPatternCommand(app, cmd);
}

fn registerGenStateSync(app: *App) void {
    platform.registerStateSync(.{
        .ctx = app,
        .export_fn = netsyncExport,
        .import_fn = netsyncImport,
    });
}
