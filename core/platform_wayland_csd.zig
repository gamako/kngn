//! Wayland CSD（client-side decoration）の純ロジック（TASK-28.5.6）。`@cImport` しない純 Zig。
//!
//! compositor が SSD（server-side decoration）を拒否/非対応のとき、自前でタイトルバー・枠・
//! 閉じる/最大化/最小化ボタンを wl_subsurface へ描画するための「幾何・ヒットテスト・サイズ変換・
//! 装飾ピクセル描画」だけをここに集約し、macOS host でも `zig build test-platform-wayland-csd` で
//! 単体テストできるようにする（`platform_wayland_input.zig` と同じ純ロジック分離方針）。
//!
//! wl_subcompositor / wl_subsurface / xdg_toplevel_resize を叩く本体（`platform_linux_wayland.zig`、
//! Linux 専用 @cImport）は本ファイルの純関数を呼ぶだけにし、protocol 呼び出しと分離する。
//!
//! ホットパス宣言: **イベント時のみ**（装飾の再描画は configure/resize・hover 変化・maximized 変化時
//! のみ。フレーム毎の全画素ループでも RT 経路でもない）→ 性能規約の SIMD 3点セット・bench 前後比較の
//! 適用対象外。装飾の塗りは行単位 @memset（一括書き込みの精神は踏襲）。座標系は content surface 原点
//! （0,0）相対で、装飾は content の上・左・右・下にはみ出す（x/y 負値は xdg-shell 上正当）。

const std = @import("std");

// ============================================================================
// 定数
// ============================================================================

/// タイトルバー高さ（px）。
pub const TITLE_H: i32 = 30;
/// リサイズ枠の幅（px）。
pub const BORDER: i32 = 5;
/// タイトルバー内のボタン 1 個の幅（正方: TITLE_H × TITLE_H）。
pub const BTN_W: i32 = TITLE_H;
/// タイトルバー右端に並ぶボタン数（close / maximize / minimize）。
pub const BTN_COUNT: i32 = 3;
/// コーナー掴み判定のゾーン（枠端からこの距離内はコーナー扱い＝複合 edge）。
pub const CORNER: i32 = 16;
/// タイトルバー上端の north リサイズ掴み帯（px。maximized 時は無効）。
pub const TITLE_TOP_GRAB: i32 = 4;

// 色（canonical BGRA / u32 0xAARRGGBB）。
const COL_BAR: u32 = 0xFF2E2E2E; // 装飾地色（濃い灰）
const COL_BTN_HOVER: u32 = 0xFF505050; // hover 中のボタン背景
const COL_CLOSE_HOVER: u32 = 0xFFC03030; // close は hover 時に赤み
const COL_GLYPH: u32 = 0xFFDDDDDD; // ボタン記号（明るい灰）

// ============================================================================
// 型
// ============================================================================

/// 装飾方式。SSD 要求の可否で分岐する（backend の State に持つ enum と同値）。
pub const DecoKind = enum { none, ssd, csd };

/// 装飾を構成する 4 枚の subsurface の種別。
pub const DecoPart = enum { title, left, right, bottom };

/// xdg_toplevel.resize の edge 値（protocol 定義そのまま）。
pub const ResizeEdge = enum(u32) {
    none = 0,
    top = 1,
    bottom = 2,
    left = 4,
    top_left = 5,
    bottom_left = 6,
    right = 8,
    top_right = 9,
    bottom_right = 10,
};

/// ボタン種別（hover 追跡・ヒットテスト・描画で共有）。
pub const Button = enum { none, close, maximize, minimize };

/// 装飾上のクリック/掴みが何を意味するか。
pub const HitTarget = union(enum) {
    none,
    move, // タイトルバーのドラッグ（xdg_toplevel.move）
    button: Button, // close / maximize / minimize
    resize: ResizeEdge, // 枠/コーナーの掴み（xdg_toplevel.resize）
};

/// content surface 原点相対の矩形（x/y は負値可）。
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn empty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }
};

/// 4 subsurface の配置（content 原点相対）。maximized 時は left/right/bottom が空(w or h=0)。
pub const Layout = struct {
    title: Rect,
    left: Rect,
    right: Rect,
    bottom: Rect,
    maximized: bool,

    pub fn rectOf(self: Layout, part: DecoPart) Rect {
        return switch (part) {
            .title => self.title,
            .left => self.left,
            .right => self.right,
            .bottom => self.bottom,
        };
    }
};

// ============================================================================
// レイアウト
// ============================================================================

/// content 寸法（=fb/公開 Window の width/height）と maximized から各装飾 subsurface の配置を計算する。
/// 通常時: title は content 上、left/right は title 上端〜下枠下端、bottom は content 下（左右枠分も覆う）。
/// maximized 時: 枠を 0 に折り畳み（描画・ヒットテスト無効）、タイトルバーのみ残す。
pub fn layout(content_w: i32, content_h: i32, maximized: bool) Layout {
    const cw = @max(content_w, 1);
    const ch = @max(content_h, 1);
    const title = Rect{ .x = 0, .y = -TITLE_H, .w = cw, .h = TITLE_H };
    if (maximized) {
        return .{
            .title = title,
            .left = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .right = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .bottom = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .maximized = true,
        };
    }
    const side_h = TITLE_H + ch + BORDER; // タイトル上端〜下枠下端
    return .{
        .title = title,
        .left = .{ .x = -BORDER, .y = -TITLE_H, .w = BORDER, .h = side_h },
        .right = .{ .x = cw, .y = -TITLE_H, .w = BORDER, .h = side_h },
        .bottom = .{ .x = -BORDER, .y = ch, .w = cw + 2 * BORDER, .h = BORDER },
        .maximized = false,
    };
}

/// xdg_surface.set_window_geometry に渡す矩形（content 原点相対、装飾込み）。
/// none/ssd: content そのもの。csd 通常: 上下左右に装飾分を含む。csd maximized: 枠なし・タイトル分のみ。
pub fn windowGeometry(content_w: i32, content_h: i32, deco: DecoKind, maximized: bool) Rect {
    const cw = @max(content_w, 1);
    const ch = @max(content_h, 1);
    if (deco != .csd) return .{ .x = 0, .y = 0, .w = cw, .h = ch };
    if (maximized) return .{ .x = 0, .y = -TITLE_H, .w = cw, .h = ch + TITLE_H };
    return .{ .x = -BORDER, .y = -TITLE_H, .w = cw + 2 * BORDER, .h = ch + TITLE_H + BORDER };
}

/// content 寸法。
pub const Size = struct { w: i32, h: i32 };

/// compositor の configure suggested size は **window geometry 基準**。CSD 時は装飾分を引いて
/// content 寸法へ変換する（min 1 clamp）。none/ssd は geometry=content なのでそのまま。
pub fn geometryToContent(geo_w: i32, geo_h: i32, deco: DecoKind, maximized: bool) Size {
    if (deco != .csd) return .{ .w = @max(geo_w, 1), .h = @max(geo_h, 1) };
    if (maximized) return .{ .w = @max(geo_w, 1), .h = @max(geo_h - TITLE_H, 1) };
    return .{ .w = @max(geo_w - 2 * BORDER, 1), .h = @max(geo_h - TITLE_H - BORDER, 1) };
}

// ============================================================================
// ボタン矩形（title-local 座標。title subsurface のバッファは content_w × TITLE_H）
// ============================================================================

/// 右から close(index 0) / maximize(1) / minimize(2) の順に BTN_W 幅で並べる。
/// title 幅がボタン 3 個分に満たない場合は範囲外（x<0）になりうるが hitTest 側で弾く。
pub fn buttonRect(which: Button, content_w: i32) Rect {
    const idx: i32 = switch (which) {
        .close => 0,
        .maximize => 1,
        .minimize => 2,
        .none => return .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    };
    return .{ .x = content_w - BTN_W * (idx + 1), .y = 0, .w = BTN_W, .h = TITLE_H };
}

fn inRect(r: Rect, x: i32, y: i32) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

/// タイトルバーのボタン域より左（ドラッグ移動できる範囲）の右端 x。
fn titleMoveRightEdge(content_w: i32) i32 {
    return content_w - BTN_W * BTN_COUNT;
}

// ============================================================================
// ヒットテスト（part-local 座標）
// ============================================================================

/// 装飾 subsurface `part` の part-local 座標 (lx,ly) が何を意味するか判定する。
/// maximized 時は枠が無い（layout が空 Rect）ため resize は返らない（呼び出し側で空 part は来ない想定
/// だが、来ても none を返す）。content_w/content_h は現在の content 寸法。
pub fn hitTest(part: DecoPart, lx: i32, ly: i32, content_w: i32, content_h: i32, maximized: bool) HitTarget {
    const lay = layout(content_w, content_h, maximized);
    const r = lay.rectOf(part);
    if (r.empty()) return .none;
    if (lx < 0 or lx >= r.w or ly < 0 or ly >= r.h) return .none;

    switch (part) {
        .title => {
            // ボタン（右端から close/maximize/minimize）
            if (inRect(buttonRect(.close, content_w), lx, ly)) return .{ .button = .close };
            if (inRect(buttonRect(.maximize, content_w), lx, ly)) return .{ .button = .maximize };
            if (inRect(buttonRect(.minimize, content_w), lx, ly)) return .{ .button = .minimize };
            // 上端数 px は north リサイズ（maximized 時は無効）
            if (!maximized and ly < TITLE_TOP_GRAB and lx < titleMoveRightEdge(content_w)) {
                return .{ .resize = .top };
            }
            // それ以外のバー左側はドラッグ移動
            if (lx < titleMoveRightEdge(content_w)) return .move;
            return .none;
        },
        .left => {
            if (maximized) return .none;
            if (ly < CORNER) return .{ .resize = .top_left };
            if (ly >= r.h - CORNER) return .{ .resize = .bottom_left };
            return .{ .resize = .left };
        },
        .right => {
            if (maximized) return .none;
            if (ly < CORNER) return .{ .resize = .top_right };
            if (ly >= r.h - CORNER) return .{ .resize = .bottom_right };
            return .{ .resize = .right };
        },
        .bottom => {
            if (maximized) return .none;
            if (lx < CORNER) return .{ .resize = .bottom_left };
            if (lx >= r.w - CORNER) return .{ .resize = .bottom_right };
            return .{ .resize = .bottom };
        },
    }
}

/// pointer が title バー上にある時の hover ボタン（描画差分判定用）。ボタン外は .none。
pub fn hoverButtonAt(lx: i32, ly: i32, content_w: i32) Button {
    if (inRect(buttonRect(.close, content_w), lx, ly)) return .close;
    if (inRect(buttonRect(.maximize, content_w), lx, ly)) return .maximize;
    if (inRect(buttonRect(.minimize, content_w), lx, ly)) return .minimize;
    return .none;
}

// ============================================================================
// 装飾ピクセル描画（[]u32 BGRA バッファへ。イベント時のみ・行単位 @memset）
// ============================================================================

fn fillRect(buf: []u32, stride: i32, bw: i32, bh: i32, r: Rect, color: u32) void {
    const x0 = @max(r.x, 0);
    const y0 = @max(r.y, 0);
    const x1 = @min(r.x + r.w, bw);
    const y1 = @min(r.y + r.h, bh);
    if (x1 <= x0 or y1 <= y0) return;
    const su: usize = @intCast(stride);
    var y: i32 = y0;
    while (y < y1) : (y += 1) {
        const row: usize = @intCast(y);
        const base = row * su;
        const s: usize = @intCast(x0);
        const e: usize = @intCast(x1);
        @memset(buf[base + s .. base + e], color);
    }
}

/// 記号を線分で描く（× / □ / −）。中央に padding を取った矩形内へ。
fn drawGlyph(buf: []u32, stride: i32, bw: i32, bh: i32, btn: Rect, which: Button) void {
    const pad: i32 = 10;
    const gx0 = btn.x + pad;
    const gy0 = btn.y + pad;
    const gx1 = btn.x + btn.w - pad;
    const gy1 = btn.y + btn.h - pad;
    if (gx1 <= gx0 or gy1 <= gy0) return;
    switch (which) {
        .close => {
            // × : 2 本の対角線（太さ 2px）
            drawLine(buf, stride, bw, bh, gx0, gy0, gx1, gy1);
            drawLine(buf, stride, bw, bh, gx1, gy0, gx0, gy1);
        },
        .maximize => {
            // □ : 枠
            fillRect(buf, stride, bw, bh, .{ .x = gx0, .y = gy0, .w = gx1 - gx0, .h = 2 }, COL_GLYPH);
            fillRect(buf, stride, bw, bh, .{ .x = gx0, .y = gy1 - 2, .w = gx1 - gx0, .h = 2 }, COL_GLYPH);
            fillRect(buf, stride, bw, bh, .{ .x = gx0, .y = gy0, .w = 2, .h = gy1 - gy0 }, COL_GLYPH);
            fillRect(buf, stride, bw, bh, .{ .x = gx1 - 2, .y = gy0, .w = 2, .h = gy1 - gy0 }, COL_GLYPH);
        },
        .minimize => {
            // − : 下側の横線
            const my = @divTrunc(gy0 + gy1, 2);
            fillRect(buf, stride, bw, bh, .{ .x = gx0, .y = my, .w = gx1 - gx0, .h = 2 }, COL_GLYPH);
        },
        .none => {},
    }
}

/// Bresenham（太さ 2px。装飾なので簡易）。
fn drawLine(buf: []u32, stride: i32, bw: i32, bh: i32, x0: i32, y0: i32, x1: i32, y1: i32) void {
    var x = x0;
    var y = y0;
    const dx = @as(i32, @intCast(@abs(x1 - x0)));
    const dy = -@as(i32, @intCast(@abs(y1 - y0)));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    while (true) {
        putPx(buf, stride, bw, bh, x, y);
        putPx(buf, stride, bw, bh, x + 1, y);
        if (x == x1 and y == y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y += sy;
        }
    }
}

fn putPx(buf: []u32, stride: i32, bw: i32, bh: i32, x: i32, y: i32) void {
    if (x < 0 or x >= bw or y < 0 or y >= bh) return;
    const idx: usize = @intCast(y * stride + x);
    buf[idx] = COL_GLYPH;
}

/// 装飾 subsurface `part` のバッファ（w×h、stride=w）を描画する。hover 中のボタンは背景を変える。
/// title 以外は地色一色。全経路イベント時のみ実行される想定。
pub fn draw(part: DecoPart, buf: []u32, w: i32, h: i32, content_w: i32, hover: Button) void {
    std.debug.assert(buf.len >= @as(usize, @intCast(w * h)));
    // 地色一色。
    @memset(buf[0..@intCast(w * h)], COL_BAR);
    if (part != .title) return;

    // ボタン背景（hover）+ 記号。
    inline for (.{ Button.minimize, Button.maximize, Button.close }) |b| {
        const r = buttonRect(b, content_w);
        if (r.x >= 0 and r.x + r.w <= w) {
            if (hover == b) {
                const bg: u32 = if (b == .close) COL_CLOSE_HOVER else COL_BTN_HOVER;
                fillRect(buf, w, w, h, r, bg);
            }
            drawGlyph(buf, w, w, h, r, b);
        }
    }
}

// ============================================================================
// テスト（display/compositor 不要・OS 非依存 = macOS で回る）
// ============================================================================

test "layout: 通常時の各 subsurface 配置" {
    const l = layout(200, 100, false);
    try std.testing.expect(!l.maximized);
    try std.testing.expectEqual(Rect{ .x = 0, .y = -TITLE_H, .w = 200, .h = TITLE_H }, l.title);
    try std.testing.expectEqual(Rect{ .x = -BORDER, .y = -TITLE_H, .w = BORDER, .h = TITLE_H + 100 + BORDER }, l.left);
    try std.testing.expectEqual(Rect{ .x = 200, .y = -TITLE_H, .w = BORDER, .h = TITLE_H + 100 + BORDER }, l.right);
    try std.testing.expectEqual(Rect{ .x = -BORDER, .y = 100, .w = 200 + 2 * BORDER, .h = BORDER }, l.bottom);
}

test "layout: maximized で枠が折り畳まれる（タイトルのみ）" {
    const l = layout(200, 100, true);
    try std.testing.expect(l.maximized);
    try std.testing.expectEqual(Rect{ .x = 0, .y = -TITLE_H, .w = 200, .h = TITLE_H }, l.title);
    try std.testing.expect(l.left.empty());
    try std.testing.expect(l.right.empty());
    try std.testing.expect(l.bottom.empty());
}

test "layout: 最小サイズ clamp" {
    const l = layout(0, 0, false);
    try std.testing.expectEqual(@as(i32, 1), l.title.w);
}

test "windowGeometry: none/ssd は content そのもの" {
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 200, .h = 100 }, windowGeometry(200, 100, .none, false));
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 200, .h = 100 }, windowGeometry(200, 100, .ssd, false));
}

test "windowGeometry: csd 通常/maximized" {
    try std.testing.expectEqual(Rect{ .x = -BORDER, .y = -TITLE_H, .w = 200 + 2 * BORDER, .h = 100 + TITLE_H + BORDER }, windowGeometry(200, 100, .csd, false));
    try std.testing.expectEqual(Rect{ .x = 0, .y = -TITLE_H, .w = 200, .h = 100 + TITLE_H }, windowGeometry(200, 100, .csd, true));
}

test "geometryToContent: windowGeometry と往復整合（通常/maximized）" {
    // 通常 csd: content -> geo -> content が一致
    inline for (.{ .{ 200, 100 }, .{ 1, 1 }, .{ 640, 480 } }) |sz| {
        const cw: i32 = sz[0];
        const ch: i32 = sz[1];
        const geo = windowGeometry(cw, ch, .csd, false);
        const back = geometryToContent(geo.w, geo.h, .csd, false);
        try std.testing.expectEqual(@max(cw, 1), back.w);
        try std.testing.expectEqual(@max(ch, 1), back.h);
        // maximized も
        const geo2 = windowGeometry(cw, ch, .csd, true);
        const back2 = geometryToContent(geo2.w, geo2.h, .csd, true);
        try std.testing.expectEqual(@max(cw, 1), back2.w);
        try std.testing.expectEqual(@max(ch, 1), back2.h);
    }
}

test "geometryToContent: 装飾分より小さい geo は min 1 clamp" {
    const c = geometryToContent(1, 1, .csd, false);
    try std.testing.expectEqual(@as(i32, 1), c.w);
    try std.testing.expectEqual(@as(i32, 1), c.h);
}

test "hitTest: タイトルバーのボタン（右から close/maximize/minimize）" {
    const cw: i32 = 300;
    // close = 右端 BTN_W
    const close = hitTest(.title, cw - BTN_W / 2, TITLE_H / 2, cw, 200, false);
    try std.testing.expectEqual(HitTarget{ .button = .close }, close);
    const maxb = hitTest(.title, cw - BTN_W - BTN_W / 2, TITLE_H / 2, cw, 200, false);
    try std.testing.expectEqual(HitTarget{ .button = .maximize }, maxb);
    const minb = hitTest(.title, cw - 2 * BTN_W - BTN_W / 2, TITLE_H / 2, cw, 200, false);
    try std.testing.expectEqual(HitTarget{ .button = .minimize }, minb);
}

test "hitTest: タイトルバー左側はドラッグ移動、上端は north" {
    const cw: i32 = 300;
    try std.testing.expectEqual(HitTarget.move, hitTest(.title, 50, TITLE_H / 2, cw, 200, false));
    try std.testing.expectEqual(HitTarget{ .resize = .top }, hitTest(.title, 50, 1, cw, 200, false));
    // maximized 時は上端でも move（north 無効）
    try std.testing.expectEqual(HitTarget.move, hitTest(.title, 50, 1, cw, 200, true));
}

test "hitTest: 枠のエッジとコーナー" {
    const cw: i32 = 300;
    const ch: i32 = 200;
    const lay = layout(cw, ch, false);
    // left 中央 = left
    try std.testing.expectEqual(HitTarget{ .resize = .left }, hitTest(.left, 2, @divTrunc(lay.left.h, 2), cw, ch, false));
    // left 上端 = top_left
    try std.testing.expectEqual(HitTarget{ .resize = .top_left }, hitTest(.left, 2, 1, cw, ch, false));
    // left 下端 = bottom_left
    try std.testing.expectEqual(HitTarget{ .resize = .bottom_left }, hitTest(.left, 2, lay.left.h - 1, cw, ch, false));
    // right 中央 = right
    try std.testing.expectEqual(HitTarget{ .resize = .right }, hitTest(.right, 2, @divTrunc(lay.right.h, 2), cw, ch, false));
    // bottom 中央 = bottom
    try std.testing.expectEqual(HitTarget{ .resize = .bottom }, hitTest(.bottom, @divTrunc(lay.bottom.w, 2), 2, cw, ch, false));
    // bottom 左端 = bottom_left
    try std.testing.expectEqual(HitTarget{ .resize = .bottom_left }, hitTest(.bottom, 1, 2, cw, ch, false));
    // bottom 右端 = bottom_right
    try std.testing.expectEqual(HitTarget{ .resize = .bottom_right }, hitTest(.bottom, lay.bottom.w - 1, 2, cw, ch, false));
}

test "hitTest: maximized 中は枠 resize を返さない" {
    // maximized では left/right/bottom は空 Rect（layout）なので none
    try std.testing.expectEqual(HitTarget.none, hitTest(.left, 2, 20, 300, 200, true));
    try std.testing.expectEqual(HitTarget.none, hitTest(.bottom, 20, 2, 300, 200, true));
}

test "hoverButtonAt: ボタン域内/外" {
    const cw: i32 = 300;
    try std.testing.expectEqual(Button.close, hoverButtonAt(cw - 1, TITLE_H / 2, cw));
    try std.testing.expectEqual(Button.none, hoverButtonAt(10, TITLE_H / 2, cw));
}

test "draw: title 地色 + hover でボタン背景が変わる（bit assert）" {
    const cw: i32 = 300;
    const w = cw;
    const h = TITLE_H;
    var buf: [300 * TITLE_H]u32 = undefined;

    // hover 無し
    draw(.title, buf[0..@as(usize, @intCast(w * h))], w, h, cw, .none);
    // 左端（ドラッグ域）は地色
    try std.testing.expectEqual(COL_BAR, buf[@intCast(2 * w + 2)]);
    // close ボタン中央のピクセル（hover 無しでは地色 or 記号。少なくとも hover 背景色ではない）
    const close_r = buttonRect(.close, cw);
    const cpx: usize = @intCast((TITLE_H / 2) * w + (close_r.x + 1));
    try std.testing.expect(buf[cpx] != COL_CLOSE_HOVER);

    // close hover
    draw(.title, buf[0..@as(usize, @intCast(w * h))], w, h, cw, .close);
    // close ボタン背景の隅（記号でない位置）が赤み hover 色
    const corner: usize = @intCast(1 * w + (close_r.x + 1));
    try std.testing.expectEqual(COL_CLOSE_HOVER, buf[corner]);
}

test "draw: 枠 part は地色一色" {
    var buf: [5 * 200]u32 = undefined;
    draw(.left, buf[0 .. 5 * 200], 5, 200, 300, .none);
    try std.testing.expectEqual(COL_BAR, buf[0]);
    try std.testing.expectEqual(COL_BAR, buf[5 * 200 - 1]);
}
