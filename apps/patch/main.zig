//! apps/patch (run-patch): 動的グラフエンジン（40.6.1 DynGraph）の最小パッチをビジュアルに表示する
//! パッチキャンバス UI（TASK-40.6.2）。
//!
//! モジュール=ノード矩形＋ポート丸（種別色 audio/cv/gate）＋ケーブル線で描画し、pan（背景 drag）/
//! zoom（scroll・カーソル基準）/ノード drag 移動 /node・port・cable の hover・選択ができる。
//! まず読み取り＋配置編集中心で、ケーブルの付け外し（ライブ再配線）と音は 40.6.3。
//!
//! UI レイアウト状態（ノード world 座標・camera・hover・selected）は GUI(メインスレッド)側が持ち、
//! RT のグラフ記述（接続/順序）とは分離する（publish に載せない。AC#3）。40.6.2 は processBlock を
//! 駆動しない（無音）で、currentView() の publish 済みトポロジを読んで描画する。
//! 幾何/ヒットテスト/見切れ判定の純ロジックは canvas.zig（platform 非依存・test-patch で単体テスト）。
//! ESC/閉じるで終了。

const std = @import("std");
const platform = @import("platform");
const gui = @import("gui");
const modular = @import("modular");
const audio = @import("audio");
const canvas = @import("canvas");

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
    node: Handle,
    port: PortRef,
    cable: CableRef, // 安定 ID（dst_handle,dst_in）。フレーム内 edge index は使わない
};

const Drag = union(enum) {
    none,
    pan: struct { start_pan: Vec2f, start_mouse: Vec2f },
    node: struct { handle: Handle, grab_offset: Vec2f }, // node.pos = mouseWorld + grab_offset
    // 接続 pending（origin ポートからカーソルへ仮ケーブル）。detach!=null は「接続済み入力から
    // 拾い上げた drag-off」で、切断は commit（mouse_up）まで遅延する（1 操作=最大 1 publish・
    // 失敗/無効ドロップで既存接続を壊さない）。
    cable: struct { origin: PortRef, detach: ?CableRef = null },
};

// モジュールパレット（画面固定・pan/zoom 非依存）。クリックで add(kind, .{})。
const PALETTE = [_]modular.ModuleKind{ .vco, .vcf, .lfo, .mixer, .clock, .euclid, .kick, .delay };
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
    camera: Camera = .{},
    mouse: Vec2f = .{ .x = 0, .y = 0 },
    hover: ?Item = null,
    selected: ?Item = null,
    drag: Drag = .none,
    fb_w: u32 = WIN_W,
    fb_h: u32 = WIN_H,

    fn buildNodes(self: *const App, out: []NodeGeom) usize {
        var n: usize = 0;
        var h: Handle = 0;
        while (h < MAX_MODULES) : (h += 1) {
            if (!self.dyn.slotActive(h)) continue;
            out[n] = .{ .handle = h, .pos = self.layout[h], .n_in = self.dyn.nIn(h), .n_out = self.dyn.nOut(h) };
            n += 1;
        }
        return n;
    }

    fn buildEdges(self: *const App, out: []Edge) usize {
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
    var edge_buf: [MAX_EDGES]Edge = undefined;
    const nodes = node_buf[0..app.buildNodes(&node_buf)];
    const edges = edge_buf[0..app.buildEdges(&edge_buf)];
    const cam = app.camera;
    const r = cam.portScreenRadius();

    // ケーブル（ノードの下）
    for (edges) |e| {
        const sg = findNode(nodes, e.src_handle) orelse continue;
        const dg = findNode(nodes, e.dst_handle) orelse continue;
        const a = cam.worldToScreen(canvas.outPortPos(sg, e.src_out));
        const b = cam.worldToScreen(canvas.inPortPos(dg, e.dst_in));
        const kind = app.dyn.outKindOf(e.src_handle, e.src_out) orelse .audio;
        const thick: u32 = if (cableItemMatches(app.selected, e) or cableItemMatches(app.hover, e)) 3 else 2;
        dl.line(vec2i(a), vec2i(b), portColor(kind), thick) catch {};
    }

    // ノード + ポート
    for (nodes) |g| {
        const tl = cam.worldToScreen(g.pos);
        const sz = canvas.nodeSize(g).scale(cam.zoom);
        const rect = toRect(tl, sz);
        dl.rectFilled(rect, NODE_BG) catch {};
        const selected = app.selected != null and app.selected.? == .node and app.selected.?.node == g.handle;
        const hovered = app.hover != null and app.hover.? == .node and app.hover.?.node == g.handle;
        const border = if (selected) SEL_COL else if (hovered) HOVER_COL else BORDER_COL;
        dl.rectOutline(rect, border, if (selected) 2 else 1) catch {};
        if (app.dyn.kindOf(g.handle)) |k| {
            dl.text(.{ .x = rect.x + 6, .y = rect.y + 4 }, @tagName(k), TITLE_COL) catch {};
        }
        var i: u8 = 0;
        while (i < g.n_in) : (i += 1) {
            const p = cam.worldToScreen(canvas.inPortPos(g, i));
            const kind = app.dyn.inKindOf(g.handle, i) orelse .audio;
            fillCircle(dl, p, r, portColor(kind));
            if (hoverPort(app, g.handle, true, i)) dl.rectOutline(portBox(p, r), HOVER_COL, 1) catch {};
        }
        i = 0;
        while (i < g.n_out) : (i += 1) {
            const p = cam.worldToScreen(canvas.outPortPos(g, i));
            const kind = app.dyn.outKindOf(g.handle, i) orelse .audio;
            fillCircle(dl, p, r, portColor(kind));
            if (hoverPort(app, g.handle, false, i)) dl.rectOutline(portBox(p, r), HOVER_COL, 1) catch {};
        }
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
        dl.text(.{ .x = rect.x + 6, .y = rect.y + 5 }, @tagName(PALETTE[btn.kind_index]), TITLE_COL) catch {};
    }
}

/// origin ポートの screen 位置（node が消えていれば null）。pending cable 描画用。
fn portScreenPos(app: *const App, nodes: []const NodeGeom, p: PortRef) ?Vec2f {
    const g = findNode(nodes, p.handle) orelse return null;
    const wp = if (p.is_input) canvas.inPortPos(g, p.index) else canvas.outPortPos(g, p.index);
    return app.camera.worldToScreen(wp);
}

fn cableItemMatches(item: ?Item, e: Edge) bool {
    if (item) |it| {
        if (it == .cable) return it.cable.dst_handle == e.dst_handle and it.cable.dst_in == e.dst_in;
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

// ============================================================================
// 入力
// ============================================================================
fn edgeForInput(app: *const App, dst: Handle, dst_in: u8) ?Edge {
    var edge_buf: [MAX_EDGES]Edge = undefined;
    const edges = edge_buf[0..app.buildEdges(&edge_buf)];
    for (edges) |e| {
        if (e.dst_handle == dst and e.dst_in == dst_in) return e;
    }
    return null;
}

fn updateHover(app: *App) void {
    var node_buf: [MAX_MODULES]NodeGeom = undefined;
    var edge_buf: [MAX_EDGES]Edge = undefined;
    const nodes = node_buf[0..app.buildNodes(&node_buf)];
    const edges = edge_buf[0..app.buildEdges(&edge_buf)];
    const mw = app.camera.screenToWorld(app.mouse);
    if (canvas.hitTestPort(mw, nodes)) |pr| {
        app.hover = .{ .port = pr };
    } else if (canvas.hitTestNode(mw, nodes)) |h| {
        app.hover = .{ .node = h };
    } else if (canvas.hitTestCable(mw, nodes, edges)) |ci| {
        app.hover = .{ .cable = .{ .dst_handle = edges[ci].dst_handle, .dst_in = edges[ci].dst_in } };
    } else {
        app.hover = null;
    }
}

fn onMouseDown(app: *App) void {
    // パレットは screen 座標で world hit より先に判定（追加。1 操作 1 publish は addByPaletteIndex 内）。
    const buttons = paletteButtons();
    if (canvas.hitTestPalette(app.mouse, &buttons)) |ki| {
        addByPaletteIndex(app, ki) catch {}; // PoolFull/TooManyModules は無視（追加せず）
        return;
    }
    var node_buf: [MAX_MODULES]NodeGeom = undefined;
    var edge_buf: [MAX_EDGES]Edge = undefined;
    const nodes = node_buf[0..app.buildNodes(&node_buf)];
    const edges = edge_buf[0..app.buildEdges(&edge_buf)];
    const mw = app.camera.screenToWorld(app.mouse);
    if (canvas.hitTestPort(mw, nodes)) |pr| {
        app.selected = .{ .port = pr };
        if (pr.is_input) {
            if (edgeForInput(app, pr.handle, pr.index)) |e| {
                // 接続済み入力からの drag-off: その元出力から pending を張り、切断は commit(mouse_up)まで遅延。
                app.drag = .{ .cable = .{
                    .origin = .{ .handle = e.src_handle, .is_input = false, .index = e.src_out },
                    .detach = .{ .dst_handle = pr.handle, .dst_in = pr.index },
                } };
                return;
            }
        }
        app.drag = .{ .cable = .{ .origin = pr } }; // 出力 or 未接続入力から pending 開始
    } else if (canvas.hitTestNode(mw, nodes)) |h| {
        app.selected = .{ .node = h };
        const npos = app.layout[h];
        app.drag = .{ .node = .{ .handle = h, .grab_offset = npos.sub(mw) } };
    } else if (canvas.hitTestCable(mw, nodes, edges)) |ci| {
        app.selected = .{ .cable = .{ .dst_handle = edges[ci].dst_handle, .dst_in = edges[ci].dst_in } };
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
        if (canvas.hitTestPort(mw, nodes)) |target| {
            commitConnect(app, pend.origin, target, pend.detach);
        } else if (pend.detach) |d| {
            // 空きへドロップ = drag-off 切断（1 publish）。origin だけの pending は何もしない。
            app.dyn.disconnect(d.dst_handle, d.dst_in);
            app.dyn.publish() catch {};
        }
    }
    app.drag = .none;
}

/// 接続を全事前検証してから 1 publish で確定する。drag-off の旧接続(detach)も同じ commit で処理し、
/// 「1 操作=最大 1 publish」「無効/失敗時は既存接続を壊さない」を守る（切断を先行させない）。
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
}

/// パレット index からモジュールを追加（comptime kind ディスパッチ）→ 画面中央付近にカスケード配置 → publish。
fn addByPaletteIndex(app: *App, ki: u8) !void {
    const casc: f32 = @floatFromInt(app.dyn.activeCount() % 8);
    const cx: f32 = @as(f32, @floatFromInt(app.fb_w)) * 0.45 + casc * 18;
    const cy: f32 = @as(f32, @floatFromInt(app.fb_h)) * 0.4 + casc * 18;
    const pos = app.camera.screenToWorld(.{ .x = cx, .y = cy });
    inline for (PALETTE, 0..) |kind, i| {
        if (i == ki) {
            const h = try app.dyn.add(kind, .{});
            app.layout[h] = pos;
            app.selected = .{ .node = h };
            try app.dyn.publish();
            return;
        }
    }
}

/// 選択中のノード/ケーブルを削除（Delete/Backspace）。
fn deleteSelected(app: *App) void {
    if (app.selected) |it| {
        switch (it) {
            .node => |h| {
                app.dyn.removeModule(h);
                app.dyn.publish() catch {};
                app.selected = null;
                app.hover = null;
            },
            .cable => |cr| {
                app.dyn.disconnect(cr.dst_handle, cr.dst_in);
                app.dyn.publish() catch {};
                app.selected = null;
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
// ============================================================================
fn offscreenOf(app: *const App) canvas.OffscreenCounts {
    var node_buf: [MAX_MODULES]NodeGeom = undefined;
    var edge_buf: [MAX_EDGES]Edge = undefined;
    const nodes = node_buf[0..app.buildNodes(&node_buf)];
    const edges = edge_buf[0..app.buildEdges(&edge_buf)];
    return canvas.viewportContains(app.camera, @floatFromInt(app.fb_w), @floatFromInt(app.fb_h), nodes, edges);
}

fn patchDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var node_buf: [MAX_MODULES]NodeGeom = undefined;
    var edge_buf: [MAX_EDGES]Edge = undefined;
    const nodes = node_buf[0..app.buildNodes(&node_buf)];
    const edges = edge_buf[0..app.buildEdges(&edge_buf)];
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
    const nodes = node_buf[0..app.buildNodes(&node_buf)];
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
