// Flex layout engine.
// Two passes: tree build (in context.zig) → measure (post-order DFS) → place (pre-order DFS).
// This file holds only types and the pure measure / place logic; it does not depend on Context.
//
// Limitations:
// - no wrap
// - no absolute positioning
// - main-axis alignment (justify_content) is start only; right-align etc. by inserting a grow box
// - no shrink. If children exceed the parent they overflow (clip_children can hide the overflow)
// - grow / percent children inside a fit parent measure as 0 (the fit parent shrinks accordingly)
// - percent is relative to the parent content box (after padding, before gap). Floor truncation;
//   no sum correction among percent children. Leftover px from truncation is absorbed by grow children

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
    fit, // Match the sum of children (main axis) / the max (cross axis)
    grow: u16, // Distribute remainder by weight ratio (on the cross axis, ignore weight and fill parent content)
    percent: f32, // Fraction of the parent content box (0.0…)
};

pub const Align = enum { start, center, end };

/// Box border. Emit order is bg → children → border (border draws on top of children).
/// The border is drawn inside the rect and does not affect layout math.
pub const Border = struct { color: Color, thickness: u32 };

pub const BoxConfig = struct {
    /// 0 = engine auto-assigns (not externally referenceable; not registered in the rect cache).
    /// Non-zero = explicit ID (caller builds via IdStack etc.). Subject to getNodeRect / hit-test
    /// caching. Must not collide within the same frame (asserted in debug).
    id: Id = 0,
    direction: Direction = .column,
    width: Sizing = .fit,
    height: Sizing = .fit,
    /// top, right, bottom, left
    padding: [4]i32 = .{ 0, 0, 0, 0 },
    gap: i32 = 0,
    align_cross: Align = .start,
    bg: ?Color = null,
    /// Border (null = none). Emitted bg → children → border
    border: ?Border = null,
    /// If true, bake a clip from this rect into children's draw cmds (does not affect layout math)
    clip_children: bool = false,
    /// Child placement offset for scrolling (px). Shifts final rects of children (and descendants)
    /// left by scroll_x and up by scroll_y. Does not affect child size, measured, or cursor math (placement only).
    /// Intended with clip_children to cut content outside the viewport. Caller clamps scroll_x/y to
    /// [0, content_natural - viewport] before passing.
    scroll_x: i32 = 0,
    scroll_y: i32 = 0,
};

/// Draw callback for a custom leaf. Called with the final rect after endFrame finalizes layout.
/// Allocator.Error from DrawList methods is handled inside the callback (catch @panic on OOM is recommended).
pub const CustomDrawFn = *const fn (ctx: *anyopaque, dl: *DrawList, rect: Rect) void;

pub const LeafKind = union(enum) {
    /// font is an override (null = Context font). Affects both measure and draw (the draw cmd's font);
    /// emitNode carries font onto the draw cmd.
    text: struct { str: []const u8, color: Color, font: ?Font },
    custom: struct { measured: Vec2, draw_fn: CustomDrawFn, ctx: *anyopaque },
};

/// Layout node. Allocated on the arena; children form a linked list
/// (avoids lifetime issues from ArrayList reallocation).
pub const Node = struct {
    /// cfg.id if non-zero; otherwise the auto-assigned value (debug only; not externally referenceable)
    id: Id = 0,
    cfg: BoxConfig = .{},
    parent: ?*Node = null,
    first_child: ?*Node = null,
    last_child: ?*Node = null,
    next_sibling: ?*Node = null,
    child_count: u32 = 0,
    measured_w: i32 = 0,
    measured_h: i32 = 0,
    /// Final rect after placement (set by place)
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    leaf: ?LeafKind = null,
};

/// Append at the end (O(1) via last_child).
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

/// Detect invalid Sizing values in debug builds (called from beginBox).
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

/// Total gap. 0 for 0 or 1 children (explicitly guards n−1 underflow).
fn gapTotal(gap: i32, child_count: u32) i32 {
    return if (child_count > 1) gap * (@as(i32, @intCast(child_count)) - 1) else 0;
}

/// Percent resolve: floor(content × f) with no sum correction (leftover px absorbed by grow).
fn percentOf(content: i32, f: f32) i32 {
    std.debug.assert(f >= 0);
    return @intFromFloat(@floor(@as(f64, @floatFromInt(content)) * @as(f64, f)));
}

/// Measure pass (post-order DFS). Leaves get content size; boxes resolve fixed / fit.
/// grow / percent are 0 at this stage (folded as 0 when the parent is fit).
pub fn measure(node: *Node, default_font: Font) void {
    if (node.leaf) |leaf| {
        switch (leaf) {
            .text => |t| {
                const f = t.font orelse default_font;
                node.measured_w = @intCast(f.measure(t.str));
                // Logical ink height, not line_height (which includes line gap).
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
        .grow, .percent => return 0, // Unresolved at measure time
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

/// Place pass (pre-order DFS). Walks down while fixing rects from the root.
/// Requires a prior measure.
pub fn place(node: *Node, rect: Rect) void {
    node.rect = rect;
    if (node.leaf != null or node.first_child == null) return;

    const cfg = node.cfg;
    // Content box (after padding). Clamp to 0 if padding exceeds the rect
    const content_x = rect.x + cfg.padding[3];
    const content_y = rect.y + cfg.padding[0];
    const content_w = @max(0, @as(i32, @intCast(rect.w)) - axisPadding(cfg, .w));
    const content_h = @max(0, @as(i32, @intCast(rect.h)) - axisPadding(cfg, .h));

    const main = mainAxis(cfg);
    const content_main: i32 = if (main == .w) content_w else content_h;
    const content_cross: i32 = if (main == .w) content_h else content_w;

    // 1. Sum non-grow main-axis sizes and total grow weight
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

    // 2-3. Accumulate-distribute the remainder to grow children by weight while advancing the main-axis cursor and fixing child rects.
    //      Peel `take = remaining * w / w_rest` in order so no fraction is left and sum(take) == remainder.
    //      If the remainder is negative (overflow), every grow child gets 0.
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
            .grow => content_cross, // Cross-axis grow ignores weight and fills parent content
        };
        // Cross-axis align uses resolved size (not measured: percent/grow children would be 0)
        const cross_off: i32 = switch (cfg.align_cross) {
            .start => 0,
            .center => @divFloor(content_cross - cross_size, 2),
            .end => content_cross - cross_size,
        };
        // Scroll offset: shift only the child's final position left/up (cursor math unchanged).
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

// Override test font with different width/height from defaults (advance=16, line_height=24, ink=24).
const override_dummy: u8 = 0;
const override_vt: Font.VTable = .{
    .measure = struct {
        fn f(_: *const anyopaque, text: []const u8) u32 {
            return 16 * @as(u32, @intCast(text.len)); // ASCII-only test assumption
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

// With line_gap (ink=18 < line_height=24). For text-leaf height checks.
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

test "measure: row fit (including gap + padding)" {
    var root: Node = .{ .cfg = .{ .direction = .row, .padding = .{ 2, 3, 4, 5 }, .gap = 7 } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 20 } } };
    var b: Node = .{ .cfg = .{ .width = .{ .fixed = 30 }, .height = .{ .fixed = 5 } } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    measure(&root, test_font);
    // Main-axis w: 10+30 + gap 7 + padding(left 5 + right 3) = 55
    try std.testing.expectEqual(@as(i32, 55), root.measured_w);
    // Cross-axis h: max(20,5) + padding(top 2 + bottom 4) = 26
    try std.testing.expectEqual(@as(i32, 26), root.measured_h);
}

test "measure: column fit (including gap + padding)" {
    var root: Node = .{ .cfg = .{ .direction = .column, .padding = .{ 1, 2, 3, 4 }, .gap = 5 } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 20 } } };
    var b: Node = .{ .cfg = .{ .width = .{ .fixed = 30 }, .height = .{ .fixed = 40 } } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    measure(&root, test_font);
    // Cross-axis w: max(10,30) + padding(left 4 + right 2) = 36
    try std.testing.expectEqual(@as(i32, 36), root.measured_w);
    // Main-axis h: 20+40 + gap 5 + padding(top 1 + bottom 3) = 69
    try std.testing.expectEqual(@as(i32, 69), root.measured_h);
}

test "measure: fit with 0 children is padding only; 1 child contributes 0 gap" {
    var empty: Node = .{ .cfg = .{ .direction = .row, .padding = .{ 1, 2, 3, 4 }, .gap = 9 } };
    measure(&empty, test_font);
    try std.testing.expectEqual(@as(i32, 6), empty.measured_w); // 4 + 2
    try std.testing.expectEqual(@as(i32, 4), empty.measured_h); // 1 + 3

    var single: Node = .{ .cfg = .{ .direction = .row, .gap = 9 } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } } };
    appendChild(&single, &a);
    measure(&single, test_font);
    try std.testing.expectEqual(@as(i32, 10), single.measured_w); // no gap contribution
}

test "measure: nested fit propagates from children" {
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

test "measure: text leaf comes from font (8×len, ink=ascent+descent)" {
    var t: Node = .{ .leaf = .{ .text = .{ .str = "Hello", .color = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), .font = null } } };
    measure(&t, test_font);
    try std.testing.expectEqual(@as(i32, 40), t.measured_w);
    try std.testing.expectEqual(@as(i32, 16), t.measured_h); // bitmap: 12+4
}

test "measure: leaf override font affects both width and height" {
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
    try std.testing.expectEqual(@as(i32, 32), t.measured_w); // 16 * 2 (override advance)
    try std.testing.expectEqual(@as(i32, 24), t.measured_h); // override ink (20+4)
}

test "text leaf height excludes line_gap (ink=18)" {
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

test "text leaf centers under a fixed-height parent with align_cross=.center" {
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

test "place: mixed fixed + percent + grow(1:2) distribution" {
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
    // percent: 200×0.25 = 50. Remainder = 200−50−50 = 100 split 1:2 → 33/67
    try std.testing.expectEqual(@as(u32, 50), f.rect.w);
    try std.testing.expectEqual(@as(u32, 50), p.rect.w);
    try std.testing.expectEqual(@as(u32, 33), g1.rect.w);
    try std.testing.expectEqual(@as(u32, 67), g2.rect.w);
    // x is contiguous with no gaps; the last edge matches the parent's right edge
    try std.testing.expectEqual(@as(i32, 0), f.rect.x);
    try std.testing.expectEqual(@as(i32, 50), p.rect.x);
    try std.testing.expectEqual(@as(i32, 100), g1.rect.x);
    try std.testing.expectEqual(@as(i32, 133), g2.rect.x);
    try std.testing.expectEqual(@as(i32, 200), g2.rect.x + @as(i32, @intCast(g2.rect.w)));
}

test "place: equal-weight grow fractions still sum exactly (split 100 three ways)" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 } } };
    var g1: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } } };
    var g2: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } } };
    var g3: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &g1);
    appendChild(&root, &g2);
    appendChild(&root, &g3);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    // Cumulative split: 33, 33, 34 (sum 100)
    try std.testing.expectEqual(@as(u32, 33), g1.rect.w);
    try std.testing.expectEqual(@as(u32, 33), g2.rect.w);
    try std.testing.expectEqual(@as(u32, 34), g3.rect.w);
    try std.testing.expectEqual(@as(i32, 100), g3.rect.x + @as(i32, @intCast(g3.rect.w)));
}

test "place: percent uses floor truncation with no sum correction" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 } } };
    var p1: Node = .{ .cfg = .{ .width = .{ .percent = 1.0 / 3.0 }, .height = .{ .fixed = 10 } } };
    var p2: Node = .{ .cfg = .{ .width = .{ .percent = 1.0 / 3.0 }, .height = .{ .fixed = 10 } } };
    var p3: Node = .{ .cfg = .{ .width = .{ .percent = 1.0 / 3.0 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &p1);
    appendChild(&root, &p2);
    appendChild(&root, &p3);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    // floor(33.33…) = 33 ×3 = 99 < 100 (no correction)
    try std.testing.expectEqual(@as(u32, 33), p1.rect.w);
    try std.testing.expectEqual(@as(u32, 33), p2.rect.w);
    try std.testing.expectEqual(@as(u32, 33), p3.rect.w);
    try std.testing.expectEqual(@as(i32, 99), p3.rect.x + @as(i32, @intCast(p3.rect.w)));
}

test "place: truncation leftover from percent is absorbed by grow" {
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

test "place: percent is relative to the parent content box (after padding)" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 120 }, .height = .{ .fixed = 20 }, .padding = .{ 0, 10, 0, 10 } } };
    var p: Node = .{ .cfg = .{ .width = .{ .percent = 0.5 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &p);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 120, .h = 20 });
    // content = 120 − 20 = 100 → 50. x starts just inside padding
    try std.testing.expectEqual(@as(u32, 50), p.rect.w);
    try std.testing.expectEqual(@as(i32, 10), p.rect.x);
}

test "place: negative remainder gives grow children 0 width (no u32 underflow)" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 50 }, .height = .{ .fixed = 10 } } };
    var f: Node = .{ .cfg = .{ .width = .{ .fixed = 80 }, .height = .{ .fixed = 10 } } };
    var g: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &f);
    appendChild(&root, &g);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 50, .h = 10 });
    try std.testing.expectEqual(@as(u32, 80), f.rect.w); // overflow left as-is
    try std.testing.expectEqual(@as(u32, 0), g.rect.w);
    try std.testing.expectEqual(@as(i32, 80), g.rect.x);
}

test "place: align_cross start/center/end (fixed children)" {
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

test "place: align_cross center aligns using the percent child's resolved size" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 100 }, .align_cross = .center } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 10 }, .height = .{ .percent = 0.5 } } };
    appendChild(&root, &a);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    // Resolved h = 50 → y = (100−50)/2 = 25 (would be 50 if based on measured=0)
    try std.testing.expectEqual(@as(u32, 50), a.rect.h);
    try std.testing.expectEqual(@as(i32, 25), a.rect.y);
}

test "place: cross-axis grow fills parent content" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 100 }, .padding = .{ 2, 0, 3, 0 } } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 10 }, .height = .{ .grow = 1 } } };
    appendChild(&root, &a);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try std.testing.expectEqual(@as(u32, 95), a.rect.h); // 100 − (2+3)
    try std.testing.expectEqual(@as(i32, 2), a.rect.y);
}

test "place: nested box padding / gap apply correctly" {
    var outer: Node = .{ .cfg = .{ .direction = .column, .width = .{ .fixed = 100 }, .height = .{ .fixed = 100 }, .padding = .{ 10, 10, 10, 10 }, .gap = 5 } };
    var a: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 20 } } };
    var inner: Node = .{ .cfg = .{ .direction = .row, .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .padding = .{ 4, 4, 4, 4 } } };
    var b: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } } };
    appendChild(&outer, &a);
    appendChild(&outer, &inner);
    appendChild(&inner, &b);
    measure(&outer, test_font);
    place(&outer, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    // a: content origin (10,10), width = 100−20 = 80
    try std.testing.expectEqual(@as(i32, 10), a.rect.x);
    try std.testing.expectEqual(@as(i32, 10), a.rect.y);
    try std.testing.expectEqual(@as(u32, 80), a.rect.w);
    // inner: y = 10+20+gap5 = 35, h = remainder = 100−10−10−20−5 = 55
    try std.testing.expectEqual(@as(i32, 35), inner.rect.y);
    try std.testing.expectEqual(@as(u32, 55), inner.rect.h);
    // b: fills inner padding
    try std.testing.expectEqual(@as(i32, 14), b.rect.x);
    try std.testing.expectEqual(@as(i32, 39), b.rect.y);
    try std.testing.expectEqual(@as(u32, 72), b.rect.w); // 80 − 8
    try std.testing.expectEqual(@as(u32, 47), b.rect.h); // 55 − 8
}

test "place: scroll_y shifts only child placement up (own rect / measured / size unchanged)" {
    var root: Node = .{ .cfg = .{ .direction = .column, .scroll_y = 20 } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 30 } } };
    var b: Node = .{ .cfg = .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 40 } } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 50 });
    // Own rect stays the given viewport unchanged
    try std.testing.expectEqual(@as(i32, 0), root.rect.y);
    try std.testing.expectEqual(@as(u32, 50), root.rect.h);
    // Child y shifts up by scroll_y=20 (absolute: a=0−20=−20, b=30−20=10). x unchanged at scroll_x=0.
    try std.testing.expectEqual(@as(i32, -20), a.rect.y);
    try std.testing.expectEqual(@as(i32, 10), b.rect.y);
    try std.testing.expectEqual(@as(i32, 0), a.rect.x);
    // Child size and measured do not depend on scroll
    try std.testing.expectEqual(@as(u32, 30), a.rect.h);
    try std.testing.expectEqual(@as(i32, 70), root.measured_h); // 30+40
}

test "place: scroll_x shifts only child placement left (row)" {
    var root: Node = .{ .cfg = .{ .direction = .row, .scroll_x = 15 } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 30 }, .height = .{ .fixed = 10 } } };
    var b: Node = .{ .cfg = .{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 50, .h = 20 });
    // Child x shifts left by scroll_x=15 (a=0−15=−15, b=30−15=15). y unchanged.
    try std.testing.expectEqual(@as(i32, -15), a.rect.x);
    try std.testing.expectEqual(@as(i32, 15), b.rect.x);
    try std.testing.expectEqual(@as(i32, 0), a.rect.y);
    try std.testing.expectEqual(@as(i32, 0), root.rect.x); // Own rect unchanged
}
