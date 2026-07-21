// Flex レイアウトエンジン（TASK-21.4）。
// ツリー構築（context.zig 側）→ measure（帰りがけ DFS）→ place（行きがけ DFS）の 2 パス。
// このファイルは型と measure / place の純粋ロジックのみを持ち、Context に依存しない。
//
// 制限事項:
// - wrap 非対応
// - absolute positioning 非対応
// - 主軸の整列（justify_content）は start のみ。右寄せ等は grow の箱を挟んで表現する
// - shrink 非対応。子の合計が親を超える場合は overflow する（見た目は clip_children で抑制）
// - fit の親の中の grow / percent 子は measure 段階で 0 扱い（fit 親はその分縮む）
// - percent は親の content box（padding 控除後、gap 控除前）基準。floor で切り捨て、
//   percent 子間の合計補正はしない。切り捨てで浮いた px は grow 子が吸収する

const std = @import("std");
const geom = @import("geom.zig");
const color_mod = @import("color.zig");
const draw_mod = @import("draw.zig");
const font_mod = @import("font.zig");
const id_mod = @import("id.zig");

pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const Color = color_mod.Color;
pub const DrawList = draw_mod.DrawList;
pub const BitmapFont = font_mod.BitmapFont;
pub const Font = font_mod.Font;
pub const Id = id_mod.Id;

pub const Direction = enum { row, column };

pub const Sizing = union(enum) {
    fixed: i32,
    fit, // 子の合計（主軸）/ 最大（交差軸）に合わせる
    grow: u16, // 余りを weight 比で配分（交差軸では weight 無視で親 content いっぱい）
    percent: f32, // 親の content box に対する割合（0.0〜）
};

pub const Align = enum { start, center, end };

/// box の枠線（TASK-21.5）。発行順は bg → 子 → border（枠が子の上に乗る）。
/// 枠は rect の内側に描かれ、レイアウト計算には影響しない。
pub const Border = struct { color: Color, thickness: u32 };

pub const BoxConfig = struct {
    /// 0 = エンジンが自動採番（外部参照不可・rect キャッシュ非登録）。
    /// 非 0 = 明示 ID（IdStack 等で caller が生成して渡す）。getNodeRect / hit-test
    /// キャッシュの対象になる。同一フレーム内で重複させないこと（debug で assert）。
    id: Id = 0,
    direction: Direction = .column,
    width: Sizing = .fit,
    height: Sizing = .fit,
    /// top, right, bottom, left
    padding: [4]i32 = .{ 0, 0, 0, 0 },
    gap: i32 = 0,
    align_cross: Align = .start,
    bg: ?Color = null,
    /// 枠線（null なら無し）。bg → 子 → border の順で発行される
    border: ?Border = null,
    /// true なら子の draw cmd に自 rect 由来の clip を焼き込む（レイアウト計算には影響しない）
    clip_children: bool = false,
    /// スクロール用の子配置オフセット（px）。子（とその子孫）の最終 rect を x は左へ scroll_x、
    /// y は上へ scroll_y ずらす。子サイズ・measured・cursor 計算には影響しない（純粋に配置のみ）。
    /// clip_children と併用して viewport 外を切る前提。scroll_x/y は呼び出し側が
    /// [0, content_natural - viewport] に clamp してから渡す。
    scroll_x: i32 = 0,
    scroll_y: i32 = 0,
};

/// custom leaf の描画コールバック。endFrame の layout 確定後に最終 rect 付きで呼ばれる。
/// DrawList メソッドの Allocator.Error は callback 側で処理する（OOM は catch @panic 推奨）。
pub const CustomDrawFn = *const fn (ctx: *anyopaque, dl: *DrawList, rect: Rect) void;

pub const LeafKind = union(enum) {
    /// font は override（null なら Context の font）。measure と draw（draw cmd の font）の
    /// 両方に効く（emitNode が draw cmd へ font を運ぶ）。
    text: struct { str: []const u8, color: Color, font: ?Font },
    custom: struct { measured: Vec2, draw_fn: CustomDrawFn, ctx: *anyopaque },
};

/// レイアウトノード。arena 上に確保し、子はリンクトリストで持つ
/// （ArrayList の再確保による寿命問題を回避）。
pub const Node = struct {
    /// cfg.id != 0 ならその値。0 なら自動採番値（デバッグ用。外部参照不可）
    id: Id = 0,
    cfg: BoxConfig = .{},
    parent: ?*Node = null,
    first_child: ?*Node = null,
    last_child: ?*Node = null,
    next_sibling: ?*Node = null,
    child_count: u32 = 0,
    measured_w: i32 = 0,
    measured_h: i32 = 0,
    /// 配置後の最終 rect（place で確定）
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    leaf: ?LeafKind = null,
};

/// 末尾 append（last_child 利用で O(1)）。
pub fn appendChild(parent: *Node, child: *Node) void {
    std.debug.assert(child.parent == null);
    child.parent = parent;
    if (parent.last_child) |last| {
        last.next_sibling = child;
    } else {
        parent.first_child = child;
    }
    parent.last_child = child;
    parent.child_count += 1;
}

/// Sizing の不正値を debug ビルドで検出する（beginBox から呼ぶ）。
pub fn assertSizingValid(s: Sizing) void {
    switch (s) {
        .fixed => |n| std.debug.assert(n >= 0),
        .percent => |f| std.debug.assert(f >= 0),
        else => {},
    }
}

const Axis = enum { w, h };

fn axisPadding(cfg: BoxConfig, axis: Axis) i32 {
    return switch (axis) {
        .w => cfg.padding[3] + cfg.padding[1], // left + right
        .h => cfg.padding[0] + cfg.padding[2], // top + bottom
    };
}

fn mainAxis(cfg: BoxConfig) Axis {
    return switch (cfg.direction) {
        .row => .w,
        .column => .h,
    };
}

fn sizingOf(node: *const Node, axis: Axis) Sizing {
    return switch (axis) {
        .w => node.cfg.width,
        .h => node.cfg.height,
    };
}

fn measuredOf(node: *const Node, axis: Axis) i32 {
    return switch (axis) {
        .w => node.measured_w,
        .h => node.measured_h,
    };
}

/// gap の合計。子 0 個 / 1 個では 0（n−1 の underflow を分岐で明示的に防ぐ）。
fn gapTotal(gap: i32, child_count: u32) i32 {
    return if (child_count > 1) gap * (@as(i32, @intCast(child_count)) - 1) else 0;
}

/// percent 解決: content × f を floor で切り捨て（合計補正なし。余り px は grow が吸収）。
fn percentOf(content: i32, f: f32) i32 {
    std.debug.assert(f >= 0);
    return @intFromFloat(@floor(@as(f64, @floatFromInt(content)) * @as(f64, f)));
}

/// 測定パス（帰りがけ DFS）。leaf は内容サイズ、box は fixed / fit を解決。
/// grow / percent はこの段階では 0（親が fit のときは 0 として畳まれる）。
pub fn measure(node: *Node, default_font: Font) void {
    if (node.leaf) |leaf| {
        switch (leaf) {
            .text => |t| {
                const f = t.font orelse default_font;
                node.measured_w = @intCast(f.measure(t.str));
                // line_height（line gap 含む）ではなく論理 ink 高さ（TASK-167）。
                node.measured_h = font_mod.fontInkHeight(f);
            },
            .custom => |c| {
                node.measured_w = @max(0, c.measured.x);
                node.measured_h = @max(0, c.measured.y);
            },
        }
        return;
    }
    var it = node.first_child;
    while (it) |c| : (it = c.next_sibling) measure(c, default_font);
    node.measured_w = computeMeasured(node, .w);
    node.measured_h = computeMeasured(node, .h);
}

fn computeMeasured(node: *const Node, axis: Axis) i32 {
    switch (sizingOf(node, axis)) {
        .fixed => |n| return n,
        .grow, .percent => return 0, // 測定段階では未確定
        .fit => {},
    }
    const pad = axisPadding(node.cfg, axis);
    if (mainAxis(node.cfg) == axis) {
        var sum: i32 = 0;
        var it = node.first_child;
        while (it) |c| : (it = c.next_sibling) sum += measuredOf(c, axis);
        return sum + gapTotal(node.cfg.gap, node.child_count) + pad;
    } else {
        var max_child: i32 = 0;
        var it = node.first_child;
        while (it) |c| : (it = c.next_sibling) max_child = @max(max_child, measuredOf(c, axis));
        return max_child + pad;
    }
}

/// 配置パス（行きがけ DFS）。rect を root から確定させながら降りる。
/// 事前に measure 済みであること。
pub fn place(node: *Node, rect: Rect) void {
    node.rect = rect;
    if (node.leaf != null or node.first_child == null) return;

    const cfg = node.cfg;
    // content box（padding 控除後）。padding が rect を超えたら 0 に clamp
    const content_x = rect.x + cfg.padding[3];
    const content_y = rect.y + cfg.padding[0];
    const content_w = @max(0, @as(i32, @intCast(rect.w)) - axisPadding(cfg, .w));
    const content_h = @max(0, @as(i32, @intCast(rect.h)) - axisPadding(cfg, .h));

    const main = mainAxis(cfg);
    const content_main: i32 = if (main == .w) content_w else content_h;
    const content_cross: i32 = if (main == .w) content_h else content_w;

    // 1. grow 以外の主軸サイズ合計と grow weight 合計
    var used: i32 = gapTotal(cfg.gap, node.child_count);
    var grow_total: i64 = 0;
    var it = node.first_child;
    while (it) |c| : (it = c.next_sibling) {
        switch (sizingOf(c, main)) {
            .fixed => |n| used += n,
            .fit => used += measuredOf(c, main),
            .percent => |f| used += percentOf(content_main, f),
            .grow => |w| grow_total += w,
        }
    }

    // 2-3. 余りを grow 子へ weight 比で累積配分しつつ、主軸カーソルを進めて子 rect を確定。
    //      `take = remaining * w / w_rest` を順に切り出すことで端数を残さず Σtake == 余り。
    //      余りが負（overflow）なら grow 子は全て 0。
    var remaining: i64 = @max(0, content_main - used);
    var w_rest: i64 = grow_total;
    var cursor: i32 = if (main == .w) content_x else content_y;
    const cross_origin: i32 = if (main == .w) content_y else content_x;

    it = node.first_child;
    while (it) |c| : (it = c.next_sibling) {
        const main_size: i32 = switch (sizingOf(c, main)) {
            .fixed => |n| n,
            .fit => measuredOf(c, main),
            .percent => |f| percentOf(content_main, f),
            .grow => |w| blk: {
                const take: i64 = if (w_rest > 0) @divTrunc(remaining * w, w_rest) else 0;
                remaining -= take;
                w_rest -= w;
                break :blk @intCast(take);
            },
        };
        const cross: Axis = if (main == .w) .h else .w;
        const cross_size: i32 = switch (sizingOf(c, cross)) {
            .fixed => |n| n,
            .fit => measuredOf(c, cross),
            .percent => |f| percentOf(content_cross, f),
            .grow => content_cross, // 交差軸の grow は weight 無視で親 content いっぱい
        };
        // 交差軸整列は解決済みサイズ基準（measured ではない: percent/grow 子で 0 になるため）
        const cross_off: i32 = switch (cfg.align_cross) {
            .start => 0,
            .center => @divFloor(content_cross - cross_size, 2),
            .end => content_cross - cross_size,
        };
        // スクロールオフセット: 子の最終位置だけを左/上へずらす（cursor 計算は不変）。
        const child_rect: Rect = if (main == .w) .{
            .x = cursor - cfg.scroll_x,
            .y = cross_origin + cross_off - cfg.scroll_y,
            .w = @intCast(@max(0, main_size)),
            .h = @intCast(@max(0, cross_size)),
        } else .{
            .x = cross_origin + cross_off - cfg.scroll_x,
            .y = cursor - cfg.scroll_y,
            .w = @intCast(@max(0, cross_size)),
            .h = @intCast(@max(0, main_size)),
        };
        place(c, child_rect);
        cursor += main_size + cfg.gap;
    }
}

// ============================================================
// Tests
// ============================================================

const test_font = font_mod.default_font;

// width/height ともに既定と異なる override 用テストフォント（advance=16, line_height=24, ink=24）。
const override_dummy: u8 = 0;
const override_vt: Font.VTable = .{
    .measure = struct {
        fn f(_: *const anyopaque, text: []const u8) u32 {
            return 16 * @as(u32, @intCast(text.len)); // ASCII テスト前提
        }
    }.f,
    .drawTo = struct {
        fn f(_: *const anyopaque, _: geom.RenderTarget, _: Vec2, _: []const u8, _: Color, _: Rect, _: f32) void {}
    }.f,
    .metrics = struct {
        fn f(_: *const anyopaque) font_mod.Metrics {
            return .{ .line_height = 24, .ascent = 20, .descent = 4 };
        }
    }.f,
};
const override_font: Font = .{ .ptr = &override_dummy, .vtable = &override_vt };

// line_gap 付き（ink=18 < line_height=24）。TASK-167 の text leaf 高さ検証用。
const gap_dummy: u8 = 0;
const gap_vt: Font.VTable = .{
    .measure = struct {
        fn f(_: *const anyopaque, text: []const u8) u32 {
            return 8 * @as(u32, @intCast(text.len));
        }
    }.f,
    .drawTo = struct {
        fn f(_: *const anyopaque, _: geom.RenderTarget, _: Vec2, _: []const u8, _: Color, _: Rect, _: f32) void {}
    }.f,
    .metrics = struct {
        fn f(_: *const anyopaque) font_mod.Metrics {
            return .{ .line_height = 24, .ascent = 14, .descent = 4 };
        }
    }.f,
};
const gap_font: Font = .{ .ptr = &gap_dummy, .vtable = &gap_vt };

test "measure: row の fit（gap + padding 込み）" {
    var root: Node = .{ .cfg = .{ .direction = .row, .padding = .{ 2, 3, 4, 5 }, .gap = 7 } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 20 } } };
    var b: Node = .{ .cfg = .{ .width = .{ .fixed = 30 }, .height = .{ .fixed = 5 } } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    measure(&root, test_font);
    // 主軸 w: 10+30 + gap 7 + padding(left 5 + right 3) = 55
    try std.testing.expectEqual(@as(i32, 55), root.measured_w);
    // 交差軸 h: max(20,5) + padding(top 2 + bottom 4) = 26
    try std.testing.expectEqual(@as(i32, 26), root.measured_h);
}

test "measure: column の fit（gap + padding 込み）" {
    var root: Node = .{ .cfg = .{ .direction = .column, .padding = .{ 1, 2, 3, 4 }, .gap = 5 } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 20 } } };
    var b: Node = .{ .cfg = .{ .width = .{ .fixed = 30 }, .height = .{ .fixed = 40 } } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    measure(&root, test_font);
    // 交差軸 w: max(10,30) + padding(left 4 + right 2) = 36
    try std.testing.expectEqual(@as(i32, 36), root.measured_w);
    // 主軸 h: 20+40 + gap 5 + padding(top 1 + bottom 3) = 69
    try std.testing.expectEqual(@as(i32, 69), root.measured_h);
}

test "measure: 子 0 個の fit は padding のみ・子 1 個は gap 寄与 0" {
    var empty: Node = .{ .cfg = .{ .direction = .row, .padding = .{ 1, 2, 3, 4 }, .gap = 9 } };
    measure(&empty, test_font);
    try std.testing.expectEqual(@as(i32, 6), empty.measured_w); // 4 + 2
    try std.testing.expectEqual(@as(i32, 4), empty.measured_h); // 1 + 3

    var single: Node = .{ .cfg = .{ .direction = .row, .gap = 9 } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } } };
    appendChild(&single, &a);
    measure(&single, test_font);
    try std.testing.expectEqual(@as(i32, 10), single.measured_w); // gap 寄与なし
}

test "measure: ネストした fit が子から伝播する" {
    var outer: Node = .{ .cfg = .{ .direction = .column, .padding = .{ 2, 2, 2, 2 } } };
    var inner: Node = .{ .cfg = .{ .direction = .row, .gap = 5 } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 30 }, .height = .{ .fixed = 10 } } };
    var b: Node = .{ .cfg = .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 40 } } };
    appendChild(&inner, &a);
    appendChild(&inner, &b);
    appendChild(&outer, &inner);
    measure(&outer, test_font);
    // inner: w = 30+20+5 = 55, h = max(10,40) = 40
    try std.testing.expectEqual(@as(i32, 55), inner.measured_w);
    try std.testing.expectEqual(@as(i32, 40), inner.measured_h);
    // outer: w = 55 + 4, h = 40 + 4
    try std.testing.expectEqual(@as(i32, 59), outer.measured_w);
    try std.testing.expectEqual(@as(i32, 44), outer.measured_h);
}

test "measure: text leaf は font 由来（8×len, ink=ascent+descent）" {
    var t: Node = .{ .leaf = .{ .text = .{ .str = "Hello", .color = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), .font = null } } };
    measure(&t, test_font);
    try std.testing.expectEqual(@as(i32, 40), t.measured_w);
    try std.testing.expectEqual(@as(i32, 16), t.measured_h); // bitmap: 12+4
}

test "measure: leaf override font が width/height 両方に効く" {
    var t: Node = .{
        .leaf = .{
            .text = .{
                .str = "ab",
                .color = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
                .font = override_font, // advance=16, ink=24
            },
        },
    };
    measure(&t, test_font);
    try std.testing.expectEqual(@as(i32, 32), t.measured_w); // 16 * 2（override の advance）
    try std.testing.expectEqual(@as(i32, 24), t.measured_h); // override の ink（20+4）
}

test "TASK-167: text leaf は line_gap を高さに含めない（ink=18）" {
    var t: Node = .{
        .leaf = .{
            .text = .{
                .str = "Hi",
                .color = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
                .font = gap_font, // line_height=24, ascent=14, descent=4 → ink=18
            },
        },
    };
    measure(&t, test_font);
    try std.testing.expectEqual(@as(i32, 16), t.measured_w);
    try std.testing.expectEqual(@as(i32, 18), t.measured_h);
}

test "TASK-167: text leaf は固定高 parent の align_cross=.center で中央配置" {
    // parent h=40, text ink=18 → center y = (40-18)/2 = 11
    var root: Node = .{
        .cfg = .{
            .direction = .row,
            .width = .{ .fixed = 100 },
            .height = .{ .fixed = 40 },
            .align_cross = .center,
        },
    };
    var t: Node = .{
        .leaf = .{
            .text = .{
                .str = "Hi",
                .color = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
                .font = gap_font,
            },
        },
    };
    appendChild(&root, &t);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 40 });
    try std.testing.expectEqual(@as(i32, 18), t.measured_h);
    try std.testing.expectEqual(@as(u32, 18), t.rect.h);
    try std.testing.expectEqual(@as(i32, 11), t.rect.y);
}

test "place: fixed + percent + grow(1:2) の混合配分" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 200 }, .height = .{ .fixed = 50 } } };
    var f: Node = .{ .cfg = .{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 10 } } };
    var p: Node = .{ .cfg = .{ .width = .{ .percent = 0.25 }, .height = .{ .fixed = 10 } } };
    var g1: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } } };
    var g2: Node = .{ .cfg = .{ .width = .{ .grow = 2 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &f);
    appendChild(&root, &p);
    appendChild(&root, &g1);
    appendChild(&root, &g2);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 200, .h = 50 });
    // percent: 200×0.25 = 50。余り = 200−50−50 = 100 を 1:2 で 33/67
    try std.testing.expectEqual(@as(u32, 50), f.rect.w);
    try std.testing.expectEqual(@as(u32, 50), p.rect.w);
    try std.testing.expectEqual(@as(u32, 33), g1.rect.w);
    try std.testing.expectEqual(@as(u32, 67), g2.rect.w);
    // x が隙間なく連続し、末尾が親右端に一致
    try std.testing.expectEqual(@as(i32, 0), f.rect.x);
    try std.testing.expectEqual(@as(i32, 50), p.rect.x);
    try std.testing.expectEqual(@as(i32, 100), g1.rect.x);
    try std.testing.expectEqual(@as(i32, 133), g2.rect.x);
    try std.testing.expectEqual(@as(i32, 200), g2.rect.x + @as(i32, @intCast(g2.rect.w)));
}

test "place: grow 等 weight の端数も合計一致（100 を 3 分割）" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 } } };
    var g1: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } } };
    var g2: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } } };
    var g3: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &g1);
    appendChild(&root, &g2);
    appendChild(&root, &g3);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    // 累積配分: 33, 33, 34（合計 100）
    try std.testing.expectEqual(@as(u32, 33), g1.rect.w);
    try std.testing.expectEqual(@as(u32, 33), g2.rect.w);
    try std.testing.expectEqual(@as(u32, 34), g3.rect.w);
    try std.testing.expectEqual(@as(i32, 100), g3.rect.x + @as(i32, @intCast(g3.rect.w)));
}

test "place: percent は floor 切り捨て・合計補正なし" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 } } };
    var p1: Node = .{ .cfg = .{ .width = .{ .percent = 1.0 / 3.0 }, .height = .{ .fixed = 10 } } };
    var p2: Node = .{ .cfg = .{ .width = .{ .percent = 1.0 / 3.0 }, .height = .{ .fixed = 10 } } };
    var p3: Node = .{ .cfg = .{ .width = .{ .percent = 1.0 / 3.0 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &p1);
    appendChild(&root, &p2);
    appendChild(&root, &p3);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    // floor(33.33…) = 33 ×3 = 99 < 100（補正しない）
    try std.testing.expectEqual(@as(u32, 33), p1.rect.w);
    try std.testing.expectEqual(@as(u32, 33), p2.rect.w);
    try std.testing.expectEqual(@as(u32, 33), p3.rect.w);
    try std.testing.expectEqual(@as(i32, 99), p3.rect.x + @as(i32, @intCast(p3.rect.w)));
}

test "place: percent の切り捨て余りは grow が吸収" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 } } };
    var p1: Node = .{ .cfg = .{ .width = .{ .percent = 1.0 / 3.0 }, .height = .{ .fixed = 10 } } };
    var p2: Node = .{ .cfg = .{ .width = .{ .percent = 1.0 / 3.0 }, .height = .{ .fixed = 10 } } };
    var g: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &p1);
    appendChild(&root, &p2);
    appendChild(&root, &g);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    // 33 + 33 + grow 34 = 100
    try std.testing.expectEqual(@as(u32, 34), g.rect.w);
    try std.testing.expectEqual(@as(i32, 100), g.rect.x + @as(i32, @intCast(g.rect.w)));
}

test "place: percent は親 content box（padding 控除後）基準" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 120 }, .height = .{ .fixed = 20 }, .padding = .{ 0, 10, 0, 10 } } };
    var p: Node = .{ .cfg = .{ .width = .{ .percent = 0.5 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &p);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 120, .h = 20 });
    // content = 120 − 20 = 100 → 50。x は padding 直下
    try std.testing.expectEqual(@as(u32, 50), p.rect.w);
    try std.testing.expectEqual(@as(i32, 10), p.rect.x);
}

test "place: 余りが負なら grow 子は 0 幅（u32 underflow なし）" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 50 }, .height = .{ .fixed = 10 } } };
    var f: Node = .{ .cfg = .{ .width = .{ .fixed = 80 }, .height = .{ .fixed = 10 } } };
    var g: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &f);
    appendChild(&root, &g);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 50, .h = 10 });
    try std.testing.expectEqual(@as(u32, 80), f.rect.w); // overflow はそのまま
    try std.testing.expectEqual(@as(u32, 0), g.rect.w);
    try std.testing.expectEqual(@as(i32, 80), g.rect.x);
}

test "place: align_cross start/center/end（fixed 子）" {
    inline for (.{
        .{ .alignment = Align.start, .y = 0 },
        .{ .alignment = Align.center, .y = 40 },
        .{ .alignment = Align.end, .y = 80 },
    }) |case| {
        var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 100 }, .align_cross = case.alignment } };
        var a: Node = .{ .cfg = .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 20 } } };
        appendChild(&root, &a);
        measure(&root, test_font);
        place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
        try std.testing.expectEqual(@as(i32, case.y), a.rect.y);
    }
}

test "place: align_cross center は percent 子の解決済みサイズで整列する" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 100 }, .align_cross = .center } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 10 }, .height = .{ .percent = 0.5 } } };
    appendChild(&root, &a);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    // 解決後 h = 50 → y = (100−50)/2 = 25（measured=0 基準なら 50 になってしまう）
    try std.testing.expectEqual(@as(u32, 50), a.rect.h);
    try std.testing.expectEqual(@as(i32, 25), a.rect.y);
}

test "place: 交差軸の grow は親 content いっぱい" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 100 }, .padding = .{ 2, 0, 3, 0 } } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 10 }, .height = .{ .grow = 1 } } };
    appendChild(&root, &a);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try std.testing.expectEqual(@as(u32, 95), a.rect.h); // 100 − (2+3)
    try std.testing.expectEqual(@as(i32, 2), a.rect.y);
}

test "place: 入れ子 box の padding / gap が正しく効く" {
    var outer: Node = .{ .cfg = .{ .direction = .column, .width = .{ .fixed = 100 }, .height = .{ .fixed = 100 }, .padding = .{ 10, 10, 10, 10 }, .gap = 5 } };
    var a: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 20 } } };
    var inner: Node = .{ .cfg = .{ .direction = .row, .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .padding = .{ 4, 4, 4, 4 } } };
    var b: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } } };
    appendChild(&outer, &a);
    appendChild(&outer, &inner);
    appendChild(&inner, &b);
    measure(&outer, test_font);
    place(&outer, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    // a: content 起点 (10,10)、幅 = 100−20 = 80
    try std.testing.expectEqual(@as(i32, 10), a.rect.x);
    try std.testing.expectEqual(@as(i32, 10), a.rect.y);
    try std.testing.expectEqual(@as(u32, 80), a.rect.w);
    // inner: y = 10+20+gap5 = 35、h = 余り = 100−10−10−20−5 = 55
    try std.testing.expectEqual(@as(i32, 35), inner.rect.y);
    try std.testing.expectEqual(@as(u32, 55), inner.rect.h);
    // b: inner の padding 内側いっぱい
    try std.testing.expectEqual(@as(i32, 14), b.rect.x);
    try std.testing.expectEqual(@as(i32, 39), b.rect.y);
    try std.testing.expectEqual(@as(u32, 72), b.rect.w); // 80 − 8
    try std.testing.expectEqual(@as(u32, 47), b.rect.h); // 55 − 8
}

test "place: scroll_y は子配置だけを上へずらす（自 rect / measured / サイズ不変）" {
    var root: Node = .{ .cfg = .{ .direction = .column, .scroll_y = 20 } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 30 } } };
    var b: Node = .{ .cfg = .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 40 } } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 50 });
    // 自 rect は与えた viewport のまま不変
    try std.testing.expectEqual(@as(i32, 0), root.rect.y);
    try std.testing.expectEqual(@as(u32, 50), root.rect.h);
    // 子の y は scroll_y=20 分だけ上（絶対値: a=0−20=−20, b=30−20=10）。x は scroll_x=0 で不変。
    try std.testing.expectEqual(@as(i32, -20), a.rect.y);
    try std.testing.expectEqual(@as(i32, 10), b.rect.y);
    try std.testing.expectEqual(@as(i32, 0), a.rect.x);
    // 子サイズと measured は scroll に依存しない
    try std.testing.expectEqual(@as(u32, 30), a.rect.h);
    try std.testing.expectEqual(@as(i32, 70), root.measured_h); // 30+40
}

test "place: scroll_x は子配置だけを左へずらす（row）" {
    var root: Node = .{ .cfg = .{ .direction = .row, .scroll_x = 15 } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 30 }, .height = .{ .fixed = 10 } } };
    var b: Node = .{ .cfg = .{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 50, .h = 20 });
    // 子の x は scroll_x=15 分だけ左（a=0−15=−15, b=30−15=15）。y は不変。
    try std.testing.expectEqual(@as(i32, -15), a.rect.x);
    try std.testing.expectEqual(@as(i32, 15), b.rect.x);
    try std.testing.expectEqual(@as(i32, 0), a.rect.y);
    try std.testing.expectEqual(@as(i32, 0), root.rect.x); // 自 rect 不変
}
