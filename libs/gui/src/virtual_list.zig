// Tests for the fixed-row virtual list and ScrollArea wheel-chain contract.
// Implementation lives in widgets.zig / context.zig; this file is imported from
// gui.zig so `zig build test-gui` collects every test below.

const std = @import("std");
const widgets = @import("widgets.zig");
const context_mod = @import("context.zig");
const id_mod = @import("id.zig");
const input_mod = @import("input.zig");
const font_mod = @import("font.zig");
const geom = @import("geom.zig");

const Context = context_mod.Context;
const Id = id_mod.Id;
const Vec2f = input_mod.Vec2f;
const Vec2 = geom.Vec2;
const VirtualListOpts = widgets.VirtualListOpts;
const VirtualRange = widgets.VirtualRange;
const ScrollAreaOpts = widgets.ScrollAreaOpts;
const ScrollAreaRecord = context_mod.ScrollAreaRecord;

fn testCtx() Context {
    return Context.init(std.testing.allocator, font_mod.default_font);
}

fn moveTo(ctx: *Context, x: i32, y: i32) void {
    ctx.pushEvent(.{ .mouse_move = .{ .x = x, .y = y, .modifiers = 0 } });
}

fn pressAt(ctx: *Context, x: i32, y: i32) void {
    moveTo(ctx, x, y);
    ctx.pushEvent(.{ .mouse_down = .{ .x = x, .y = y, .button = 0, .modifiers = 0 } });
}

fn clickAt(ctx: *Context, x: i32, y: i32) void {
    pressAt(ctx, x, y);
    ctx.pushEvent(.{ .mouse_up = .{ .x = x, .y = y, .button = 0, .modifiers = 0 } });
}

fn wheelAt(ctx: *Context, x: i32, y: i32, dy: f32) void {
    moveTo(ctx, x, y);
    ctx.pushEvent(.{ .mouse_scroll = .{ .x = x, .y = y, .dx = 0, .dy = dy, .modifiers = 0 } });
}

fn center(rect: geom.Rect) struct { x: i32, y: i32 } {
    return .{
        .x = rect.x + @as(i32, @intCast(rect.w / 2)),
        .y = rect.y + @as(i32, @intCast(rect.h / 2)),
    };
}

fn rowId(base: Id, i: usize) Id {
    return base + @as(Id, @intCast(i));
}

fn contentId(list_id: Id) Id {
    return id_mod.hashInt(list_id, 1);
}

const default_opts = VirtualListOpts{
    .row_height = 20,
    .row_count = 100,
    .width = .{ .fixed = 120 },
    .height = .{ .fixed = 80 },
    .gap = 0,
    .overscan = 2,
};

fn buildVirtualRows(ctx: *Context, list_id: Id, scroll: *Vec2f, opts: VirtualListOpts, row_base: Id) VirtualRange {
    const range = widgets.beginVirtualList(ctx, list_id, scroll, opts);
    var i = range.first;
    while (i < range.end) : (i += 1) {
        ctx.beginBox(.{
            .id = rowId(row_base, i),
            .width = .{ .grow = 1 },
            .height = .{ .fixed = opts.row_height },
        });
        ctx.endBox();
    }
    widgets.endVirtualList(ctx);
    return range;
}

fn warmupVirtual(ctx: *Context, list_id: Id, scroll: *Vec2f, opts: VirtualListOpts, row_base: Id) void {
    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        ctx.beginFrame(300, 300);
        _ = buildVirtualRows(ctx, list_id, scroll, opts, row_base);
        ctx.endFrame();
    }
}

// ── 1. Range math ──────────────────────────────────────────

test "virtualList: range at scroll 0 / middle / end clamp" {
    const opts = VirtualListOpts{ .row_height = 20, .row_count = 100, .overscan = 0 };
    const pitch = widgets.virtualListPitch(opts);
    const r0 = widgets.virtualListVisibleRange(0, 80, opts.row_count, pitch, 0);
    try std.testing.expectEqual(@as(usize, 0), r0.first);
    try std.testing.expectEqual(@as(usize, 4), r0.end);

    const mid = widgets.virtualListVisibleRange(200, 80, opts.row_count, pitch, 0);
    try std.testing.expectEqual(@as(usize, 10), mid.first);
    try std.testing.expectEqual(@as(usize, 14), mid.end);

    const end = widgets.virtualListVisibleRange(10000, 80, opts.row_count, pitch, 0);
    try std.testing.expectEqual(@as(usize, 100), end.first);
    try std.testing.expectEqual(@as(usize, 100), end.end);
}

test "virtualList: overscan clamps at both ends and overscan 0" {
    const opts = VirtualListOpts{ .row_height = 20, .row_count = 10, .overscan = 2 };
    const pitch = widgets.virtualListPitch(opts);
    const top = widgets.virtualListVisibleRange(0, 40, 10, pitch, 2);
    try std.testing.expectEqual(@as(usize, 0), top.first);
    try std.testing.expectEqual(@as(usize, 4), top.end);

    const bot = widgets.virtualListVisibleRange(160, 40, 10, pitch, 2);
    try std.testing.expectEqual(@as(usize, 6), bot.first);
    try std.testing.expectEqual(@as(usize, 10), bot.end);

    const none = widgets.virtualListVisibleRange(0, 40, 10, pitch, 0);
    try std.testing.expectEqual(@as(usize, 0), none.first);
    try std.testing.expectEqual(@as(usize, 2), none.end);
}

test "virtualList: gap is part of pitch" {
    const opts = VirtualListOpts{ .row_height = 20, .row_count = 50, .gap = 4 };
    try std.testing.expectEqual(@as(i32, 24), widgets.virtualListPitch(opts));
    try std.testing.expectEqual(@as(i32, 50 * 20 + 49 * 4), widgets.virtualListTotalHeight(opts));
    const r = widgets.virtualListVisibleRange(0, 48, 50, 24, 0);
    try std.testing.expectEqual(@as(usize, 0), r.first);
    try std.testing.expectEqual(@as(usize, 2), r.end);
}

test "virtualList: row_count 0 is an empty range and total height 0" {
    const opts = VirtualListOpts{ .row_height = 20, .row_count = 0, .gap = 4 };
    try std.testing.expectEqual(@as(i32, 0), widgets.virtualListTotalHeight(opts));
    const r = widgets.virtualListVisibleRange(10, 80, 0, 24, 2);
    try std.testing.expectEqual(@as(usize, 0), r.first);
    try std.testing.expectEqual(@as(usize, 0), r.end);
}

test "virtualList: viewport ending inside a gap does not include the next row" {
    // pitch=22, row occupies [0,20), gap [20,22). Viewport [0,21) ends in the gap.
    const r = widgets.virtualListVisibleRange(0, 21, 10, 22, 0);
    try std.testing.expectEqual(@as(usize, 0), r.first);
    try std.testing.expectEqual(@as(usize, 1), r.end);
}

test "virtualList: f32 scroll vs rounded i32 layout can disagree by less than one pitch" {
    // scroll.y = 19.6 → floor(19.6/20) = 0. Layout rounds to 20, the start of row 1.
    const r = widgets.virtualListVisibleRange(19.6, 20, 10, 20, 0);
    try std.testing.expectEqual(@as(usize, 0), r.first);
    try std.testing.expectEqual(@as(usize, 2), r.end);
    const rounded = widgets.virtualListVisibleRange(20, 20, 10, 20, 0);
    try std.testing.expectEqual(@as(usize, 1), rounded.first);
}

test "virtualList: +inf saturates to the end; -inf and NaN to the start" {
    const n: usize = 50;
    const pitch: i32 = 20;
    const pos_inf = std.math.inf(f32);
    const neg_inf = -std.math.inf(f32);
    const nan = std.math.nan(f32);

    const from_inf = widgets.virtualListVisibleRange(pos_inf, 80, n, pitch, 0);
    try std.testing.expectEqual(n, from_inf.first);
    try std.testing.expectEqual(n, from_inf.end);

    // Huge finite scroll: floor(scroll/pitch) is already at the end, and
    // scroll + vp overflows to +inf. end must saturate to n, not collapse to 0.
    const huge = std.math.floatMax(f32);
    const from_huge = widgets.virtualListVisibleRange(huge, 80, n, pitch, 2);
    try std.testing.expectEqual(n, from_huge.first);
    try std.testing.expectEqual(n, from_huge.end);

    const from_neg = widgets.virtualListVisibleRange(neg_inf, 80, n, pitch, 0);
    try std.testing.expectEqual(@as(usize, 0), from_neg.first);
    try std.testing.expectEqual(@as(usize, 0), from_neg.end);

    const from_nan = widgets.virtualListVisibleRange(nan, 80, n, pitch, 0);
    try std.testing.expectEqual(@as(usize, 0), from_nan.first);
    try std.testing.expectEqual(@as(usize, 0), from_nan.end);
}

test "virtualList: first-frame fallback uses screen height when height is not fixed" {
    try std.testing.expectEqual(@as(i32, 768), widgets.virtualListFallbackViewportHeight(768));
    var ctx = testCtx();
    defer ctx.deinit();
    var scroll: Vec2f = .{};
    const opts = VirtualListOpts{
        .row_height = 20,
        .row_count = 200,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .overscan = 0,
    };
    ctx.beginFrame(100, 200);
    const range = widgets.beginVirtualList(&ctx, 0xA100, &scroll, opts);
    // No previous-frame rect, height is grow → fallback 200 px → 10 rows.
    try std.testing.expectEqual(@as(usize, 0), range.first);
    try std.testing.expectEqual(@as(usize, 10), range.end);
    widgets.endVirtualList(&ctx);
    ctx.endFrame();
}

test "virtualList: first-frame fixed height is used when the rect is missing" {
    var ctx = testCtx();
    defer ctx.deinit();
    var scroll: Vec2f = .{};
    const opts = VirtualListOpts{
        .row_height = 20,
        .row_count = 200,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 60 },
        .overscan = 0,
    };
    ctx.beginFrame(400, 400);
    const range = widgets.beginVirtualList(&ctx, 0xA101, &scroll, opts);
    try std.testing.expectEqual(@as(usize, 0), range.first);
    try std.testing.expectEqual(@as(usize, 3), range.end);
    widgets.endVirtualList(&ctx);
    ctx.endFrame();
}

// ── 2. Spacer geometry ─────────────────────────────────────

test "virtualList: spacer places the first built row at first*pitch; no spacer at first 0" {
    var ctx = testCtx();
    defer ctx.deinit();
    const list_id: Id = 0xA200;
    const row_base: Id = 0xA280;
    var scroll: Vec2f = .{};
    const opts = VirtualListOpts{
        .row_height = 20,
        .row_count = 50,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 80 },
        .gap = 4,
        .overscan = 0,
    };
    const pitch = widgets.virtualListPitch(opts);

    warmupVirtual(&ctx, list_id, &scroll, opts, row_base);
    const content = ctx.getNodeRect(contentId(list_id)).?;
    const row0 = ctx.getNodeRect(rowId(row_base, 0)).?;
    try std.testing.expectEqual(content.y, row0.y);

    scroll.y = @floatFromInt(5 * pitch);
    ctx.beginFrame(300, 300);
    const range = buildVirtualRows(&ctx, list_id, &scroll, opts, row_base);
    ctx.endFrame();
    try std.testing.expect(range.first > 0);
    try std.testing.expectEqual(@as(usize, 5), range.first);
    const content2 = ctx.getNodeRect(contentId(list_id)).?;
    const first_row = ctx.getNodeRect(rowId(row_base, range.first)).?;
    try std.testing.expectEqual(content2.y + 5 * pitch, first_row.y);
    try std.testing.expect(ctx.getNodeRect(rowId(row_base, 0)) == null);
}

// ── 3. Out-of-range rows are not built ─────────────────────

test "virtualList: only the window is built (rect_cache and range width)" {
    var ctx = testCtx();
    defer ctx.deinit();
    const list_id: Id = 0xA300;
    const row_base: Id = 0xA380;
    var scroll: Vec2f = .{};
    const opts = VirtualListOpts{
        .row_height = 20,
        .row_count = 80,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 80 },
        .overscan = 1,
    };
    warmupVirtual(&ctx, list_id, &scroll, opts, row_base);
    scroll.y = 400;
    ctx.beginFrame(300, 300);
    const range = buildVirtualRows(&ctx, list_id, &scroll, opts, row_base);
    ctx.endFrame();

    try std.testing.expect(range.end > range.first);
    var i: usize = 0;
    var built: usize = 0;
    while (i < opts.row_count) : (i += 1) {
        if (ctx.getNodeRect(rowId(row_base, i))) |_| {
            try std.testing.expect(i >= range.first and i < range.end);
            built += 1;
        } else {
            try std.testing.expect(i < range.first or i >= range.end);
        }
    }
    try std.testing.expectEqual(range.len(), built);
}

// ── 4. virtualScrollToRow ──────────────────────────────────

test "virtualList: virtualScrollToRow clamps to the top and to the bottom" {
    var ctx = testCtx();
    defer ctx.deinit();
    const list_id: Id = 0xA400;
    const row_base: Id = 0xA480;
    var scroll: Vec2f = .{};
    const opts = VirtualListOpts{
        .row_height = 20,
        .row_count = 40,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 80 },
        .overscan = 0,
    };
    warmupVirtual(&ctx, list_id, &scroll, opts, row_base);

    scroll.y = 200;
    widgets.virtualScrollToRow(&ctx, list_id, &scroll, opts, 0);
    try std.testing.expectEqual(@as(f32, 0), scroll.y);

    widgets.virtualScrollToRow(&ctx, list_id, &scroll, opts, 39);
    const vp_h: i32 = @intCast(ctx.getNodeRect(list_id).?.h);
    const total = widgets.virtualListTotalHeight(opts);
    try std.testing.expectEqual(@as(f32, @floatFromInt(total - vp_h)), scroll.y);

    widgets.virtualScrollToRow(&ctx, list_id, &scroll, opts, 999);
    try std.testing.expectEqual(@as(f32, @floatFromInt(total - vp_h)), scroll.y);

    const empty = VirtualListOpts{ .row_height = 20, .row_count = 0, .height = .{ .fixed = 80 } };
    const before = scroll.y;
    widgets.virtualScrollToRow(&ctx, list_id, &scroll, empty, 0);
    try std.testing.expectEqual(before, scroll.y);
}

test "virtualList: virtualScrollToRow aligns a taller-than-viewport row to the top" {
    var ctx = testCtx();
    defer ctx.deinit();
    const list_id: Id = 0xA410;
    const row_base: Id = 0xA490;
    var scroll: Vec2f = .{};
    const opts = VirtualListOpts{
        .row_height = 120,
        .row_count = 8,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 80 },
        .overscan = 0,
    };
    warmupVirtual(&ctx, list_id, &scroll, opts, row_base);
    widgets.virtualScrollToRow(&ctx, list_id, &scroll, opts, 3);
    try std.testing.expectEqual(@as(f32, 360), scroll.y);
}

// ── 5. Wheel chain ─────────────────────────────────────────

test "virtualList: large wheel delta leaves no blank on the same frame" {
    var ctx = testCtx();
    defer ctx.deinit();
    const list_id: Id = 0xA500;
    const row_base: Id = 0xA580;
    var scroll: Vec2f = .{};
    const opts = VirtualListOpts{
        .row_height = 20,
        .row_count = 200,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 80 },
        .overscan = 0,
        .wheel_px = 32.0,
    };
    warmupVirtual(&ctx, list_id, &scroll, opts, row_base);
    const vp = ctx.getNodeRect(list_id).?;
    const c = center(vp);

    ctx.beginFrame(300, 300);
    wheelAt(&ctx, c.x, c.y, -20);
    const range = buildVirtualRows(&ctx, list_id, &scroll, opts, row_base);
    ctx.endFrame();

    try std.testing.expect(scroll.y > 80);
    const first_vis = widgets.virtualListVisibleRange(scroll.y, @intCast(vp.h), opts.row_count, 20, 0);
    try std.testing.expect(range.first <= first_vis.first);
    try std.testing.expect(range.end >= first_vis.end);
    try std.testing.expect(ctx.getNodeRect(rowId(row_base, first_vis.first)) != null);
}

test "scrollArea: a newly appeared inner area is not a wheel target on its first frame" {
    var ctx = testCtx();
    defer ctx.deinit();
    const OUTER: Id = 0xA510;
    const INNER: Id = 0xA511;
    var outer: Vec2f = .{};
    var inner: Vec2f = .{};
    const opts_o: ScrollAreaOpts = .{ .width = .{ .fixed = 200 }, .height = .{ .fixed = 160 } };
    const opts_i: ScrollAreaOpts = .{ .width = .{ .fixed = 160 }, .height = .{ .fixed = 80 } };

    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        ctx.beginFrame(400, 400);
        ctx.beginScrollArea(OUTER, &outer, opts_o);
        ctx.beginBox(.{ .id = 0xA51A, .width = .{ .fixed = 40 }, .height = .{ .fixed = 400 } });
        ctx.endBox();
        ctx.endScrollArea();
        ctx.endFrame();
    }
    const oc = center(ctx.getNodeRect(OUTER).?);
    const outer_before = outer.y;

    ctx.beginFrame(400, 400);
    wheelAt(&ctx, oc.x, oc.y, -3);
    ctx.beginScrollArea(OUTER, &outer, opts_o);
    ctx.beginBox(.{ .id = 0xA51A, .width = .{ .fixed = 40 }, .height = .{ .fixed = 400 } });
    ctx.endBox();
    ctx.beginScrollArea(INNER, &inner, opts_i);
    ctx.beginBox(.{ .id = 0xA51B, .width = .{ .fixed = 80 }, .height = .{ .fixed = 400 } });
    ctx.endBox();
    ctx.endScrollArea();
    ctx.endScrollArea();
    ctx.endFrame();

    try std.testing.expect(outer.y > outer_before);
    try std.testing.expectEqual(@as(f32, 0), inner.y);
}

test "scrollArea: mid-frame mouse move does not retarget leftover wheel" {
    var ctx = testCtx();
    defer ctx.deinit();
    const OUTER: Id = 0xA515;
    const INNER: Id = 0xA516;
    var outer: Vec2f = .{};
    var inner: Vec2f = .{};
    const opts_o: ScrollAreaOpts = .{ .width = .{ .fixed = 200 }, .height = .{ .fixed = 160 } };
    const opts_i: ScrollAreaOpts = .{ .width = .{ .fixed = 160 }, .height = .{ .fixed = 80 } };

    const nest = struct {
        fn build(c: *Context, outer_id: Id, inner_id: Id, o: *Vec2f, i: *Vec2f, oo: ScrollAreaOpts, ii: ScrollAreaOpts) void {
            c.beginScrollArea(outer_id, o, oo);
            c.beginBox(.{ .id = id_mod.hashInt(outer_id, 0xA0), .width = .{ .fixed = 40 }, .height = .{ .fixed = 40 } });
            c.endBox();
            c.beginScrollArea(inner_id, i, ii);
            c.beginBox(.{ .id = id_mod.hashInt(inner_id, 0xA0), .width = .{ .fixed = 80 }, .height = .{ .fixed = 400 } });
            c.endBox();
            c.endScrollArea();
            c.beginBox(.{ .id = id_mod.hashInt(outer_id, 0xA1), .width = .{ .fixed = 40 }, .height = .{ .fixed = 400 } });
            c.endBox();
            c.endScrollArea();
        }
    }.build;

    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        ctx.beginFrame(400, 400);
        nest(&ctx, OUTER, INNER, &outer, &inner, opts_o, opts_i);
        ctx.endFrame();
    }

    // Pin outer at its edge so a further wheel is leftover for whoever is inside.
    outer.y = 10000;
    ctx.beginFrame(400, 400);
    nest(&ctx, OUTER, INNER, &outer, &inner, opts_o, opts_i);
    ctx.endFrame();
    const outer_max = outer.y;
    try std.testing.expect(outer_max > 0);
    try std.testing.expectEqual(@as(f32, 0), inner.y);

    const orr = ctx.getNodeRect(OUTER).?;
    const ir = ctx.getNodeRect(INNER).?;
    // Top of the outer viewport sits on the 40-high header, not on the inner area.
    const outer_only_x = orr.x + 10;
    const outer_only_y = orr.y + 10;
    try std.testing.expect(!(outer_only_x >= ir.x and outer_only_x < ir.x + @as(i32, @intCast(ir.w)) and
        outer_only_y >= ir.y and outer_only_y < ir.y + @as(i32, @intCast(ir.h))));

    const ic = center(ir);
    ctx.beginFrame(400, 400);
    wheelAt(&ctx, outer_only_x, outer_only_y, -4);
    ctx.beginScrollArea(OUTER, &outer, opts_o);
    ctx.beginBox(.{ .id = id_mod.hashInt(OUTER, 0xA0), .width = .{ .fixed = 40 }, .height = .{ .fixed = 40 } });
    ctx.endBox();
    // Chain is sealed on outer. A move onto the inner viewport must not let
    // the inner end-path consume the leftover the sealed cursor left for outer.
    moveTo(&ctx, ic.x, ic.y);
    ctx.beginScrollArea(INNER, &inner, opts_i);
    ctx.beginBox(.{ .id = id_mod.hashInt(INNER, 0xA0), .width = .{ .fixed = 80 }, .height = .{ .fixed = 400 } });
    ctx.endBox();
    ctx.endScrollArea();
    ctx.beginBox(.{ .id = id_mod.hashInt(OUTER, 0xA1), .width = .{ .fixed = 40 }, .height = .{ .fixed = 400 } });
    ctx.endBox();
    ctx.endScrollArea();
    ctx.endFrame();

    try std.testing.expectEqual(outer_max, outer.y);
    try std.testing.expectEqual(@as(f32, 0), inner.y);
}

test "scrollArea: wheel chain uses previous-frame viewport, not this frame's move" {
    var ctx = testCtx();
    defer ctx.deinit();
    const SID: Id = 0xA520;
    const OTHER: Id = 0xA521;
    var scroll: Vec2f = .{};
    var other: Vec2f = .{};
    const opts: ScrollAreaOpts = .{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 60 } };

    ctx.beginFrame(400, 400);
    ctx.beginBox(.{ .direction = .column, .gap = 200 });
    ctx.beginScrollArea(SID, &scroll, opts);
    ctx.beginBox(.{ .id = 0xA52A, .width = .{ .fixed = 40 }, .height = .{ .fixed = 300 } });
    ctx.endBox();
    ctx.endScrollArea();
    ctx.beginScrollArea(OTHER, &other, opts);
    ctx.beginBox(.{ .id = 0xA52B, .width = .{ .fixed = 40 }, .height = .{ .fixed = 40 } });
    ctx.endBox();
    ctx.endScrollArea();
    ctx.endBox();
    ctx.endFrame();

    ctx.beginFrame(400, 400);
    ctx.beginBox(.{ .direction = .column, .gap = 200 });
    ctx.beginScrollArea(SID, &scroll, opts);
    ctx.beginBox(.{ .id = 0xA52A, .width = .{ .fixed = 40 }, .height = .{ .fixed = 300 } });
    ctx.endBox();
    ctx.endScrollArea();
    ctx.beginScrollArea(OTHER, &other, opts);
    ctx.beginBox(.{ .id = 0xA52B, .width = .{ .fixed = 40 }, .height = .{ .fixed = 40 } });
    ctx.endBox();
    ctx.endScrollArea();
    ctx.endBox();
    ctx.endFrame();

    const vp = ctx.getNodeRect(SID).?;
    const c = center(vp);
    const before = scroll.y;

    // This frame the areas swap order (OTHER first), so SID's new rect is below.
    // The chain still uses last frame's SID rect, which contains the cursor.
    ctx.beginFrame(400, 400);
    wheelAt(&ctx, c.x, c.y, -2);
    ctx.beginBox(.{ .direction = .column, .gap = 200 });
    ctx.beginScrollArea(OTHER, &other, opts);
    ctx.beginBox(.{ .id = 0xA52B, .width = .{ .fixed = 40 }, .height = .{ .fixed = 40 } });
    ctx.endBox();
    ctx.endScrollArea();
    ctx.beginScrollArea(SID, &scroll, opts);
    ctx.beginBox(.{ .id = 0xA52A, .width = .{ .fixed = 40 }, .height = .{ .fixed = 300 } });
    ctx.endBox();
    ctx.endScrollArea();
    ctx.endBox();
    ctx.endFrame();

    try std.testing.expect(scroll.y > before);
    try std.testing.expectEqual(@as(f32, 0), other.y);
}

test "scrollArea: same-depth overlapping siblings use reverse end-order (later end is head)" {
    const a: Id = 0xA530;
    const b: Id = 0xA531;
    const records = [_]ScrollAreaRecord{
        .{ .id = a, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 }, .depth = 0, .serial = 0 },
        .{ .id = b, .rect = .{ .x = 20, .y = 20, .w = 100, .h = 100 }, .depth = 0, .serial = 1 },
    };
    const head = context_mod.pickWheelChainHead(&records, .{ .x = 50, .y = 50 });
    try std.testing.expectEqual(b, head);

    const deeper = [_]ScrollAreaRecord{
        .{ .id = a, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 }, .depth = 0, .serial = 1 },
        .{ .id = b, .rect = .{ .x = 20, .y = 20, .w = 80, .h = 80 }, .depth = 1, .serial = 0 },
    };
    try std.testing.expectEqual(b, context_mod.pickWheelChainHead(&deeper, .{ .x = 50, .y = 50 }));
    try std.testing.expectEqual(@as(Id, 0), context_mod.pickWheelChainHead(&records, .{ .x = 300, .y = 300 }));
}

test "scrollArea: caller write then thumb then wheel then clamp" {
    var ctx = testCtx();
    defer ctx.deinit();
    const list_id: Id = 0xA540;
    const row_base: Id = 0xA580;
    var scroll: Vec2f = .{};
    const opts = VirtualListOpts{
        .row_height = 20,
        .row_count = 80,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 80 },
        .overscan = 0,
        .wheel_px = 32.0,
    };
    warmupVirtual(&ctx, list_id, &scroll, opts, row_base);

    // (1) caller write
    widgets.virtualScrollToRow(&ctx, list_id, &scroll, opts, 10);
    const after_caller = scroll.y;
    try std.testing.expect(after_caller > 0);

    // (3) wheel on top of the caller write (no thumb this frame)
    const vp = ctx.getNodeRect(list_id).?;
    const c = center(vp);
    ctx.beginFrame(300, 300);
    wheelAt(&ctx, c.x, c.y, -2);
    _ = buildVirtualRows(&ctx, list_id, &scroll, opts, row_base);
    ctx.endFrame();
    try std.testing.expect(scroll.y > after_caller);

    // (4) clamp: an oversize caller write is pinned
    scroll.y = 1_000_000;
    ctx.beginFrame(300, 300);
    _ = buildVirtualRows(&ctx, list_id, &scroll, opts, row_base);
    ctx.endFrame();
    const total = widgets.virtualListTotalHeight(opts);
    const vp_h: i32 = @intCast(ctx.getNodeRect(list_id).?.h);
    try std.testing.expectEqual(@as(f32, @floatFromInt(total - vp_h)), scroll.y);

    // (2) thumb drag still moves scroll (after a reset to 0)
    scroll.y = 0;
    ctx.beginFrame(300, 300);
    _ = buildVirtualRows(&ctx, list_id, &scroll, opts, row_base);
    ctx.endFrame();
    const vthumb = id_mod.hashInt(list_id, 2);
    const tc = center(ctx.getNodeRect(vthumb).?);
    ctx.beginFrame(300, 300);
    pressAt(&ctx, tc.x, tc.y);
    _ = buildVirtualRows(&ctx, list_id, &scroll, opts, row_base);
    ctx.endFrame();
    const before_drag = scroll.y;
    ctx.beginFrame(300, 300);
    moveTo(&ctx, tc.x, tc.y + 24);
    _ = buildVirtualRows(&ctx, list_id, &scroll, opts, row_base);
    ctx.endFrame();
    try std.testing.expect(scroll.y > before_drag);
}

// ── 6. Hit-test delay ──────────────────────────────────────

test "virtualList: a newly built row is not hittable this frame and is hittable the next" {
    var ctx = testCtx();
    defer ctx.deinit();
    const list_id: Id = 0xA600;
    const row_base: Id = 0xA680;
    var scroll: Vec2f = .{};
    const opts = VirtualListOpts{
        .row_height = 20,
        .row_count = 80,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 80 },
        .overscan = 0,
    };
    warmupVirtual(&ctx, list_id, &scroll, opts, row_base);
    try std.testing.expect(ctx.getNodeRect(rowId(row_base, 20)) == null);

    scroll.y = 400;
    ctx.beginFrame(300, 300);
    const range = buildVirtualRows(&ctx, list_id, &scroll, opts, row_base);
    // Same frame: rect_cache still has the previous window. New rows are not hittable.
    try std.testing.expect(range.first >= 18);
    try std.testing.expect(ctx.getNodeRect(rowId(row_base, range.first)) == null);
    ctx.endFrame();
    try std.testing.expect(ctx.getNodeRect(rowId(row_base, range.first)) != null);

    ctx.beginFrame(300, 300);
    _ = buildVirtualRows(&ctx, list_id, &scroll, opts, row_base);
    try std.testing.expect(ctx.getNodeRect(rowId(row_base, range.first)) != null);
    ctx.endFrame();
}

test "virtualList: an overscanned row is hittable the frame it enters the core window" {
    var ctx = testCtx();
    defer ctx.deinit();
    const list_id: Id = 0xA610;
    const row_base: Id = 0xA690;
    var scroll: Vec2f = .{};
    const opts = VirtualListOpts{
        .row_height = 20,
        .row_count = 80,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 80 },
        .overscan = 2,
    };
    warmupVirtual(&ctx, list_id, &scroll, opts, row_base);
    // At scroll 0 with overscan 2, rows 0..6-ish are built.
    try std.testing.expect(ctx.getNodeRect(rowId(row_base, 5)) != null);

    scroll.y = 40; // row 2 at the top; row 5 is inside the core window
    ctx.beginFrame(300, 300);
    _ = buildVirtualRows(&ctx, list_id, &scroll, opts, row_base);
    try std.testing.expect(ctx.getNodeRect(rowId(row_base, 5)) != null);
    ctx.endFrame();
}

// ── 7. Focus ───────────────────────────────────────────────

test "virtualList: an off-screen selected row stays focused, is not a Tab stop, and nav still works" {
    var ctx = testCtx();
    defer ctx.deinit();
    const list_id: Id = 0xA700;
    const row_base: Id = 0xA780;
    const other: Id = 0xA7FF;
    var scroll: Vec2f = .{};
    const opts = VirtualListOpts{
        .row_height = 20,
        .row_count = 80,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 80 },
        .overscan = 0,
    };

    const build = struct {
        fn f(c: *Context, sid: Id, sc: *Vec2f, o: VirtualListOpts, base: Id, other_id: Id, selected: usize) VirtualRange {
            _ = c.buttonId(other_id, "other", .{});
            const range = widgets.beginVirtualList(c, sid, sc, o);
            var i = range.first;
            while (i < range.end) : (i += 1) {
                _ = widgets.beginListboxRow(c, rowId(base, i), i == selected, .{
                    .height = .{ .fixed = o.row_height },
                });
                widgets.endListboxRow(c);
            }
            widgets.endVirtualList(c);
            return range;
        }
    }.f;

    ctx.beginFrame(300, 300);
    _ = build(&ctx, list_id, &scroll, opts, row_base, other, 0);
    ctx.endFrame();
    ctx.beginFrame(300, 300);
    _ = build(&ctx, list_id, &scroll, opts, row_base, other, 0);
    _ = ctx.claimFocus(rowId(row_base, 0));
    ctx.endFrame();
    try std.testing.expectEqual(rowId(row_base, 0), ctx.state.focused_id);

    scroll.y = 400;
    ctx.beginFrame(300, 300);
    const range = build(&ctx, list_id, &scroll, opts, row_base, other, 0);
    ctx.endFrame();
    try std.testing.expect(range.first > 0);
    try std.testing.expectEqual(rowId(row_base, 0), ctx.state.focused_id);
    var list_stop = false;
    for (ctx.focus_order.items) |id| {
        if (id == rowId(row_base, 0)) list_stop = true;
    }
    try std.testing.expect(!list_stop);

    ctx.beginFrame(300, 300);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.down, .modifiers = 0, .repeat = false } });
    try std.testing.expectEqual(widgets.ListNav.next, widgets.pollListNav(&ctx, rowId(row_base, 0)));
    _ = build(&ctx, list_id, &scroll, opts, row_base, other, 1);
    ctx.endFrame();

    // Tab return: scroll the selected row back in, it is a stop again.
    widgets.virtualScrollToRow(&ctx, list_id, &scroll, opts, 1);
    ctx.beginFrame(300, 300);
    _ = build(&ctx, list_id, &scroll, opts, row_base, other, 1);
    ctx.endFrame();
    var returned = false;
    for (ctx.focus_order.items) |id| {
        if (id == rowId(row_base, 1)) returned = true;
    }
    try std.testing.expect(returned);
}

// ── 8. PerIdStateStore ─────────────────────────────────────

test "virtualList: hidden row per-id state trims to default; focused stays" {
    var ctx = testCtx();
    defer ctx.deinit();
    const list_id: Id = 0xA800;
    const row_base: Id = 0xA880;
    var scroll: Vec2f = .{};
    const opts = VirtualListOpts{
        .row_height = 20,
        .row_count = 16,
        .width = .{ .fixed = 200 },
        .height = .{ .fixed = 40 },
        .overscan = 0,
    };

    const build = struct {
        fn f(c: *Context, sid: Id, sc: *Vec2f, o: VirtualListOpts, base: Id) VirtualRange {
            const range = widgets.beginVirtualList(c, sid, sc, o);
            var i = range.first;
            while (i < range.end) : (i += 1) {
                const id = rowId(base, i);
                c.beginBox(.{ .id = id, .width = .{ .grow = 1 }, .height = .{ .fixed = o.row_height } });
                _ = widgets.selectableLabelId(c, id + 0x1000, "row", .{});
                c.endBox();
            }
            widgets.endVirtualList(c);
            return range;
        }
    }.f;

    // First frames: tall fallback builds every row so each gets per-id state.
    ctx.beginFrame(300, 400);
    _ = build(&ctx, list_id, &scroll, opts, row_base);
    ctx.endFrame();
    ctx.beginFrame(300, 400);
    _ = build(&ctx, list_id, &scroll, opts, row_base);
    ctx.endFrame();

    const hidden_sel = rowId(row_base, 10) + 0x1000;
    const focused_sel = rowId(row_base, 12) + 0x1000;
    ctx.perIdState(hidden_sel).selection = .{ .anchor = 1, .extent = 2 };
    ctx.perIdState(focused_sel).selection = .{ .anchor = 1, .extent = 3 };

    ctx.per_id_state.max_entries = 3;
    ctx.per_id_state.trim_to = 2;

    scroll.y = 0;
    ctx.beginFrame(300, 400);
    _ = ctx.claimFocus(focused_sel);
    _ = build(&ctx, list_id, &scroll, opts, row_base);
    ctx.endFrame();

    try std.testing.expect(ctx.per_id_state.get(hidden_sel) == null);
    const kept = ctx.per_id_state.get(focused_sel).?;
    try std.testing.expectEqual(@as(usize, 1), kept.selection.anchor);
    try std.testing.expectEqual(@as(usize, 3), kept.selection.extent);

    scroll.y = 200;
    widgets.virtualScrollToRow(&ctx, list_id, &scroll, opts, 10);
    ctx.beginFrame(300, 400);
    _ = build(&ctx, list_id, &scroll, opts, row_base);
    ctx.endFrame();
    const restored = ctx.perIdState(hidden_sel);
    try std.testing.expectEqual(@as(usize, 0), restored.selection.anchor);
    try std.testing.expectEqual(@as(usize, 0), restored.selection.extent);
}

// ── Content-extent connection (declared fixed wins) ────────

test "virtualList: content height is the declared fixed total, not the visible extent" {
    var ctx = testCtx();
    defer ctx.deinit();
    const list_id: Id = 0xA900;
    const row_base: Id = 0xA980;
    var scroll: Vec2f = .{};
    const opts = VirtualListOpts{
        .row_height = 20,
        .row_count = 40,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 80 },
        .overscan = 0,
    };
    const total = widgets.virtualListTotalHeight(opts);
    warmupVirtual(&ctx, list_id, &scroll, opts, row_base);
    const cached = ctx.getNodeCachedRect(contentId(list_id)).?;
    try std.testing.expectEqual(total, cached.declared_h);
    try std.testing.expect(cached.content_h < total);
    try std.testing.expectEqual(total, cached.scrollContentSize().y);

    scroll.y = 9999;
    ctx.beginFrame(300, 300);
    _ = buildVirtualRows(&ctx, list_id, &scroll, opts, row_base);
    ctx.endFrame();
    const vp_h: i32 = @intCast(ctx.getNodeRect(list_id).?.h);
    try std.testing.expectEqual(@as(f32, @floatFromInt(total - vp_h)), scroll.y);
}

test "virtualList: empty begin/end pair is well-formed" {
    var ctx = testCtx();
    defer ctx.deinit();
    var scroll: Vec2f = .{};
    const opts = VirtualListOpts{
        .row_height = 20,
        .row_count = 0,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 80 },
    };
    ctx.beginFrame(200, 200);
    const range = widgets.beginVirtualList(&ctx, 0xAA00, &scroll, opts);
    try std.testing.expectEqual(@as(usize, 0), range.first);
    try std.testing.expectEqual(@as(usize, 0), range.end);
    widgets.endVirtualList(&ctx);
    ctx.endFrame();
}

test "virtualList: a total height past the coordinate domain still places the visible rows" {
    var ctx = testCtx();
    defer ctx.deinit();
    const LIST: Id = 0xA344;
    const ROW: Id = 0xA345;
    var scroll: Vec2f = .{};
    // 100k rows of 20 px is ~2M tall, past `geom.MAX_COORD`, and a scroll amount inside
    // that range is legitimate: holding the offset to the coordinate domain would place
    // the rows somewhere else entirely.
    const opts = VirtualListOpts{
        .row_height = 20,
        .row_count = 100_000,
        .width = .{ .fixed = 200 },
        .height = .{ .fixed = 200 },
        .overscan = 0,
    };
    const target_row: usize = 60_000;

    // Settle the viewport rect first, so the range comes from real geometry.
    ctx.beginFrame(400, 400);
    _ = widgets.beginVirtualList(&ctx, LIST, &scroll, opts);
    widgets.endVirtualList(&ctx);
    ctx.endFrame();

    scroll.y = @floatFromInt(target_row * opts.row_height);
    try std.testing.expect(scroll.y > @as(f32, @floatFromInt(geom.MAX_COORD)));

    ctx.beginFrame(400, 400);
    const range = widgets.beginVirtualList(&ctx, LIST, &scroll, opts);
    try std.testing.expect(range.first <= target_row and target_row < range.end);
    var i = range.first;
    while (i < range.end) : (i += 1) {
        const id = if (i == target_row) ROW else 0;
        ctx.beginBox(.{ .id = id, .width = .{ .grow = 1 }, .height = .{ .fixed = opts.row_height } });
        ctx.endBox();
    }
    widgets.endVirtualList(&ctx);
    ctx.endFrame();

    // The row is not merely in the range: it lands inside the viewport.
    const vp = ctx.getNodeRect(LIST).?;
    const row = ctx.getNodeRect(ROW).?;
    try std.testing.expect(row.y >= vp.y);
    try std.testing.expect(row.y + @as(i32, @intCast(row.h)) <= vp.y + @as(i32, @intCast(vp.h)));
}
