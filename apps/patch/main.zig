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
const canvas = @import("canvas.zig");
const group = @import("group.zig");
const macro = @import("macro.zig");
const actions = @import("actions.zig");
const graph_io = @import("graph_io.zig");

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
};
const PAL_X0: f32 = 8;
const PAL_Y: f32 = 6;
// 10 ボタンが WIN_W(960) 内に収まる幅（8 + 10*(92+3) < 960）。macro 追加でボタンが増えたため縮小（40.7.2）。
const PAL_W: f32 = 92;
const PAL_H: f32 = 22;
const PAL_GAP: f32 = 3;
const PAL_BG = gui.Color.rgba(0x2C, 0x32, 0x3C, 0xFF);
const PAL_BG_HOVER = gui.Color.rgba(0x3A, 0x44, 0x52, 0xFF);
const PENDING_COL = gui.Color.rgba(0xC0, 0xC0, 0xC0, 0xFF);

fn paletteButtons() [PALETTE.len]canvas.PaletteButton {
    var btns: [PALETTE.len]canvas.PaletteButton = undefined;
    for (0..PALETTE.len) |i| {
        const fi: f32 = @floatFromInt(i);
        btns[i] = .{ .kind_index = @intCast(i), .rect = .{ .x = PAL_X0 + fi * (PAL_W + PAL_GAP), .y = PAL_Y, .w = PAL_W, .h = PAL_H } };
    }
    return btns;
}

const App = struct {
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

    /// キャンバス有効高（画面下端の可視化帯を除いた領域）。見切れ判定・ヒットテスト・tap 対象選択で共通に使う。
    fn canvasH(self: *const App) f32 {
        const fh: f32 = @floatFromInt(self.fb_h);
        return @max(0.0, fh - VIS_H);
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
    app.dyn.processBlock(buf, frames, channels);
    if (channels == 2) app.tap.write(buf);
}

// ============================================================================
// 最小パッチ構築（全 3 ポート種別・全 3 ケーブル色を見せる）:
//   Clock(gate)→Euclid / VCO(audio)→VCF / LFO(cv)→VCF.cutoff / VCF(audio)→Output
// ============================================================================
fn buildPatch(app: *App) !void {
    const g = app.dyn;
    const clock = try g.add(.clock, .{ .bpm = 120, .ppqn = 4 });
    const euclid = try g.add(.euclid, .{ .steps = 16, .pulses = 4 });
    const vco = try g.add(.vco, .{ .osc = .{ .waveform = .saw }, .base_hz = 110 });
    const lfo = try g.add(.lfo, .{ .rate_hz = 0.5 });
    const vcf = try g.add(.vcf, .{ .cutoff = 800, .resonance = 3.0, .mode = .lowpass });
    const out = try g.add(.output, .{ .soft_clip = true });

    app.layout[clock] = .{ .x = 60, .y = 60 };
    app.layout[euclid] = .{ .x = 280, .y = 60 };
    app.layout[vco] = .{ .x = 60, .y = 210 };
    app.layout[lfo] = .{ .x = 60, .y = 360 };
    app.layout[vcf] = .{ .x = 320, .y = 250 };
    app.layout[out] = .{ .x = 560, .y = 250 };

    try g.connect(clock, 0, euclid, 0); // gate
    try g.connect(vco, 0, vcf, 0); // audio
    try g.connect(lfo, 0, vcf, 1); // cv (cutoff)
    try g.connect(vcf, 0, out, 0); // audio
    g.setOutput(out);
    try g.publish();
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

/// gid の step_seq メンバーを handle 昇順で最大 2 個集める（drum: [seqK, seqH] / bass: [seq]）。
/// active + step_seq + 当該 gid 所属のみ（stale handle を弾く。台帳同期）。
fn collectStepSeqMembers(app: *const App, gid: group.GroupId) struct { items: [2]Handle, n: usize } {
    var items: [2]Handle = .{ 0, 0 };
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

/// クリック可能な mask 行数（drum=2 レーン、bass=on/accent/slide の 3 行。bass の pitch 段は表示のみ）。
fn clickableRows(kind: group.MacroKind) u8 {
    return switch (kind) {
        .drum_machine => 2,
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
            // 2 レーン: row0=seqK.on_mask / row1=seqH.on_mask。
            var rows: [2]stepgrid.DrawRow = undefined;
            var lane: u8 = 0;
            while (lane < 2 and lane < seqs.n) : (lane += 1) {
                const seq: StepSeqPtr = app.dyn.ptrOf(.step_seq, seqs.items[lane]);
                rows[lane] = .{ .mask = seq.loadOnMask(), .on_color = stepgrid.DEFAULT_ON };
            }
            stepgrid.draw(dl, geometry, rows[0..seqs.n], .{ .playhead = @intCast(playhead) });
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
        if (stepgrid.hitTest(geometry, local.x, local.y, clickableRows(g.kind))) |cell| return .{ .gid = gid, .cell = cell };
    }
    return null;
}

/// grid セルクリック → 対象 StepSeq の mask ビットを atomic store でトグル（publish 無し＝トポロジ不変）。
fn toggleMacroGridCell(app: *App, hit: GridHit) void {
    const kind = app.ledger.groups[hit.gid].kind;
    const seqs = collectStepSeqMembers(app, hit.gid);
    if (seqs.n == 0) return;
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
    if (app.mouse.y >= app.canvasH()) {
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

/// パレット index からモジュール or マクロを追加（comptime kind ディスパッチ）→ 画面中央付近へ配置 → publish。
fn addByPaletteIndex(app: *App, ki: u8) !void {
    const casc: f32 = @floatFromInt(app.dyn.activeCount() % 8);
    const cx: f32 = @as(f32, @floatFromInt(app.fb_w)) * 0.45 + casc * 18;
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
    const top_limit: f32 = PAL_Y + PAL_H + margin; // パレット帯の下端より下に置く
    const fbw: f32 = @floatFromInt(app.fb_w);
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
                    if (app.ledger.group_of[h] != null and app.ledger.group_of[h].? == gid) app.dyn.removeModule(h);
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
    const n = canvas.selectTapPorts(app.camera, @floatFromInt(app.fb_w), app.canvasH(), nodes, sel, hov, &handles);

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

    // audio: open で sample rate を確定 → DynGraph 構築 → 初期 publish → その後 start（初手から発音）。
    // RT callback は start 後にのみ発火するので、start 前に app.dyn を確定させれば安全（app は stack 固定・非ムーブ）。
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

    const sr: f32 = @floatFromInt(device.config().sample_rate);
    const dyn = DynGraph.create(allocator, sr) catch |err| {
        std.debug.print("DynGraph.create failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer dyn.destroy();

    app = App{ .dyn = dyn, .io = init.io }; // start 前に app を完全初期化（callback が app.dyn を触る前に確定）
    buildPatch(&app) catch |err| {
        std.debug.print("buildPatch failed: {s}\n", .{@errorName(err)}); // publish 失敗等は panic せず終了
        return;
    };

    var dl = gui.DrawList.init(allocator);
    defer dl.deinit();

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
    // ヘッドレス検証 harness の custom action を登録（harness 無効時は no-op。TASK-65）。
    registerActions(&app);
    registerStateSync(&app);

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
                    onMouseMove(&app);
                },
                .mouse_down => |m| {
                    if (m.button == .left) {
                        app.mouse = .{ .x = @floatFromInt(m.x), .y = @floatFromInt(m.y) };
                        onMouseDown(&app);
                    }
                },
                .mouse_up => |m| {
                    if (m.button == .left) onMouseUp(&app);
                },
                .mouse_scroll => |s| {
                    app.mouse = .{ .x = @floatFromInt(s.x), .y = @floatFromInt(s.y) };
                    const factor: f32 = if (s.dy > 0) 1.1 else if (s.dy < 0) 1.0 / 1.1 else 1.0;
                    app.camera.zoomAt(app.mouse, factor);
                    updateHover(&app);
                },
            }
        }

        // A/D: 活性度更新 + tap 対象の選択・publish（描画の直前・イベント反映後）。
        updateViz(&app);

        @memset(fb.pixels, BG);
        dl.reset(fb.width, fb.height);
        drawFrame(&app, &dl);
        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        gui.render(target, &dl, gui.default_font);
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
    return canvas.viewportContains(app.camera, @floatFromInt(app.fb_w), app.canvasH(), nodes, edges);
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
            const piece = std.fmt.bufPrint(buf[off..], "{s}{{\"id\":{d},\"kind\":\"{s}\",\"collapsed\":{d},\"members\":[", .{
                sep, gid, @tagName(g.kind), @as(u8, if (g.collapsed) 1 else 0),
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

fn toHandle(v: usize) error{InvalidHandle}!Handle {
    if (v >= MAX_MODULES) return error.InvalidHandle;
    return @intCast(v);
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

/// kind 名（`modular.ModuleKind` の tag 名。26種、パレットの10種より広い）→ `addNodeByKind`。
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
fn registerActions(app: *App) void {
    platform.registerAction(.{ .name = "add_node", .ctx = app, .run = actionAddNode });
    platform.registerAction(.{ .name = "remove_node", .ctx = app, .run = actionRemoveNode });
    platform.registerAction(.{ .name = "connect", .ctx = app, .run = actionConnect });
    platform.registerAction(.{ .name = "disconnect", .ctx = app, .run = actionDisconnect });
    platform.registerAction(.{ .name = "save_graph", .ctx = app, .run = actionSaveGraph });
    platform.registerAction(.{ .name = "load_graph", .ctx = app, .run = actionLoadGraph });
}

fn netsyncExport(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
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

fn netsyncImport(ctx: *anyopaque, bytes: []const u8) anyerror!void {
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

fn registerStateSync(app: *App) void {
    platform.registerStateSync(.{
        .ctx = app,
        .export_fn = netsyncExport,
        .import_fn = netsyncImport,
    });
}
