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
const platform = @import("platform");
const gui = @import("gui");
const modular = @import("modular");
const audio = @import("audio");
const canvas = @import("canvas.zig");
const group = @import("group.zig");
const macro = @import("macro.zig");

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

// group.zig は modular 非依存のため GROUP_HANDLE_BASE(=48) を定数複製している。数値の食い違い
// （dyn.zig の MAX_MODULES 変更を group.zig 側へ反映し忘れる等）を compile time に検出する。
comptime {
    if (group.GROUP_HANDLE_BASE != MAX_MODULES) {
        @compileError("group.GROUP_HANDLE_BASE must equal modular.dyn.MAX_MODULES");
    }
}

const WIN_W = 960;
const WIN_H = 600;
const BG: u32 = 0xFF12161B;

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
};
const PAL_X0: f32 = 8;
const PAL_Y: f32 = 6;
const PAL_W: f32 = 100;
const PAL_H: f32 = 22;
const PAL_GAP: f32 = 4;
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

// RT audio callback: dyn.processBlock のみ（同期/alloc/lock/IO/panic なし）。facade が自動 tap。
fn audioCallback(buf: []f32, frames: u32, channels: u32, sample_rate: u32, userdata: ?*anyopaque) void {
    _ = sample_rate;
    const app: *App = @ptrCast(@alignCast(userdata orelse {
        @memset(buf, 0);
        return;
    }));
    app.dyn.processBlock(buf, frames, channels);
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
        if (group.groupIdFromHandle(g.handle) != null) drawToggle(dl, cam, g, true); // 畳み箱は常に collapsed 側
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
            fillCircle(dl, p, r, portColor(kind));
            if (hoverPort(app, g.handle, false, i)) dl.rectOutline(portBox(p, r), HOVER_COL, 1) catch {};
        }
    }

    // 展開中グループの薄い枠（矩形+タイトル+トグル）。中身の grid 描画は 40.7.2。
    for (app.ledger.groups, 0..) |gr, gi| {
        if (!gr.active or gr.collapsed) continue;
        drawExpandedGroupFrame(app, dl, cam, nodes, @intCast(gi), gr);
    }

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
    const mw = app.camera.screenToWorld(app.mouse);

    // 折り畳みトグル [±] はノード本体のクリックより優先する（畳み箱 / 展開枠ヘッダーの両方）。
    if (hitToggle(app, mw)) |gid| {
        app.ledger.groups[gid].collapsed = !app.ledger.groups[gid].collapsed;
        app.selected = .{ .group = gid };
        app.hover = null;
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

/// DrumMachine 展開時のメンバー相対配置（group.pos 基準の world offset）。y は展開ヘッダー（group.pos に
/// タイトル+[−]、高さ ≒ canvas.TITLE_H+PORT_SPACING+BODY_PAD）とメンバーが重ならないよう DRUM_HEADER_BAND
/// の下から始める（codex #5）。members 配列と同順（cdiv/seqK/seqH/kick/hat/mix）。
const DRUM_HEADER_BAND: f32 = 58;
const DRUM_OFFSETS = [_]Vec2f{
    .{ .x = 0, .y = DRUM_HEADER_BAND + 40 }, // cdiv（左・中段）
    .{ .x = 150, .y = DRUM_HEADER_BAND }, // seqK（上段）
    .{ .x = 150, .y = DRUM_HEADER_BAND + 80 }, // seqH（下段）
    .{ .x = 300, .y = DRUM_HEADER_BAND }, // kick（上段）
    .{ .x = 300, .y = DRUM_HEADER_BAND + 80 }, // hat（下段）
    .{ .x = 450, .y = DRUM_HEADER_BAND + 40 }, // mix（右・中段）
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

/// DrumMachine 展開サブグラフの footprint（group.pos 基準の world 幅・高さ）。header 箱 + 全メンバー node
/// 実サイズを内包する bbox の右下端（左上端は必ず (0,0)）。
fn drumFootprint(app: *const App, members: [6]Handle) Vec2f {
    const header = NodeGeom{ .handle = group.GROUP_HANDLE_BASE, .pos = .{ .x = 0, .y = 0 }, .n_in = 0, .n_out = 0 };
    var w: f32 = canvas.nodeSize(header).x; // = NODE_W
    var h: f32 = canvas.nodeSize(header).y;
    for (members, DRUM_OFFSETS) |m, off| {
        const geom = NodeGeom{ .handle = m, .pos = off, .n_in = app.dyn.nIn(m), .n_out = app.dyn.nOut(m) };
        const sz = canvas.nodeSize(geom);
        w = @max(w, off.x + sz.x);
        h = @max(h, off.y + sz.y);
    }
    return .{ .x = w, .y = h };
}

/// マクロ（DrumMachine 等）をパレットから追加する。preflight+add+connect+1publish は macro.zig が担い、
/// publish 成功を確認してから台帳登録（group_of/exposed_in/out/collapsed=true）する（§3.2）。
/// `anchor` は追加位置の screen 座標。展開時の footprint が既定 fb に収まるよう screen で clamp してから
/// screenToWorld し（codex #4）、畳み箱・各メンバー layout をそこ基準に置く。
fn addMacro(app: *App, kind: group.MacroKind, anchor: Vec2f) !void {
    switch (kind) {
        .drum_machine => {
            const h = try macro.buildDrumMachine(app.dyn); // 失敗時は何も残らない（macro.zig 側の rollback）
            const gid = app.ledger.alloc() orelse {
                // 台帳枯渇（MAX_GROUPS 上限。極めて稀）: 公開済みメンバーを畳んで戻す（1 publish）。
                app.dyn.removeModule(h.cdiv);
                app.dyn.removeModule(h.seq_k);
                app.dyn.removeModule(h.seq_h);
                app.dyn.removeModule(h.kick);
                app.dyn.removeModule(h.hat);
                app.dyn.removeModule(h.mix);
                app.dyn.publish() catch {};
                return;
            };

            const members = [_]Handle{ h.cdiv, h.seq_k, h.seq_h, h.kick, h.hat, h.mix };

            // footprint を screen サイズ（world × zoom）に換算し、右下が fb 内に収まるよう anchor を clamp。
            // footprint が fb より広い場合でも max が下限（margin / palette 帯下）を割らないよう @max で保護。
            const fp = drumFootprint(app, members);
            const zoom = app.camera.zoom;
            const margin: f32 = 16;
            const top_limit: f32 = PAL_Y + PAL_H + margin; // パレット帯の下端より下に置く
            const fbw: f32 = @floatFromInt(app.fb_w);
            const fbh: f32 = @floatFromInt(app.fb_h);
            const max_x = @max(margin, fbw - fp.x * zoom - margin);
            const max_y = @max(top_limit, fbh - fp.y * zoom - margin);
            const sx = std.math.clamp(anchor.x, margin, max_x);
            const sy = std.math.clamp(anchor.y, top_limit, max_y);
            const pos = app.camera.screenToWorld(.{ .x = sx, .y = sy });

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

pub fn main() !void {
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

    app = App{ .dyn = dyn }; // start 前に app を完全初期化（callback が app.dyn を触る前に確定）
    buildPatch(&app) catch |err| {
        std.debug.print("buildPatch failed: {s}\n", .{@errorName(err)}); // publish 失敗等は panic せず終了
        return;
    };

    var dl = gui.DrawList.init(allocator);
    defer dl.deinit();

    platform.registerProbe(.{ .name = "patch", .ctx = &app, .ext = "json", .snapshot = patchSnapshot, .digest = patchDigest });
    platform.registerProbe(.{ .name = "group", .ctx = &app, .ext = "json", .snapshot = null, .digest = groupDigest });

    device.start() catch |err| {
        std.debug.print("audio.start failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer device.stop();
    std.debug.print("apps/patch: ドラッグでポート間を配線 / パレットで追加 / Delete で削除 / scroll=zoom。音が鳴ります。\n", .{});

    var running = true;
    main_loop: while (running and window.pollEvents()) {
        const fb = window.lockFramebuffer() orelse continue :main_loop;
        defer fb.unlock();
        app.fb_w = fb.width;
        app.fb_h = fb.height;

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

        @memset(fb.pixels, BG);
        dl.reset(fb.width, fb.height);
        drawFrame(&app, &dl);
        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        gui.render(target, &dl, gui.default_font);

        window.present();
        platform.sleep(16_000_000);
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
    return canvas.viewportContains(app.camera, @floatFromInt(app.fb_w), @floatFromInt(app.fb_h), nodes, edges);
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
        app.fb_w,    app.fb_h,        oc.node,          oc.port,           oc.cable,
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
