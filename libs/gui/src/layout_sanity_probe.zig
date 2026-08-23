const std = @import("std");
const Allocator = std.mem.Allocator;
const draw = @import("draw.zig");
const font_mod = @import("font.zig");
const layout = @import("layout.zig");

/// The opt-in layout contract is intentionally structural: it observes the normal
/// layout root after placement and never changes the draw list or framebuffer.
pub const Font = font_mod.Font;
pub const probe_name = "layout_sanity";
pub const Result = struct {
    enabled: bool = false,
    scanned: bool = false,
    text_overflow: u32 = 0,
    sibling_overlap: u32 = 0,
    content_overflow: u32 = 0,

    pub fn total(self: Result) u32 {
        return self.text_overflow + self.sibling_overlap + self.content_overflow;
    }
};

const SweepItem = struct {
    node: *const layout.Node,
};

const Extent = struct {
    width: i64,
    height: i64,
};

fn sweepLessThan(_: void, lhs: SweepItem, rhs: SweepItem) bool {
    return lhs.node.rect.x < rhs.node.rect.x;
}

fn hasExplicitClamp(node: *const layout.Node) bool {
    return node.cfg.min_width > 0 or node.cfg.min_height > 0 or
        node.cfg.max_width < std.math.maxInt(i32) or node.cfg.max_height < std.math.maxInt(i32);
}

fn childFlowExtent(node: *const layout.Node) Extent {
    const origin_x: i64 = @as(i64, node.rect.x) + @as(i64, node.cfg.padding[3]);
    const origin_y: i64 = @as(i64, node.rect.y) + @as(i64, node.cfg.padding[0]);
    var max_right: i64 = 0;
    var max_bottom: i64 = 0;
    var child = node.first_child;
    while (child) |c| : (child = c.next_sibling) {
        if (c.cfg.anchor != null) continue;
        const child_right = @as(i64, c.rect.x) + @as(i64, c.rect.w) - origin_x + @as(i64, node.cfg.scroll_x);
        const child_bottom = @as(i64, c.rect.y) + @as(i64, c.rect.h) - origin_y + @as(i64, node.cfg.scroll_y);
        max_right = @max(max_right, @max(child_right, 0));
        max_bottom = @max(max_bottom, @max(child_bottom, 0));
        if (!c.cfg.clip_children) {
            if (c.content_w >= 0) {
                const content_right = @as(i64, c.rect.x) + @as(i64, c.content_w) - origin_x + @as(i64, node.cfg.scroll_x);
                max_right = @max(max_right, @max(content_right, 0));
            }
            if (c.content_h >= 0) {
                const content_bottom = @as(i64, c.rect.y) + @as(i64, c.content_h) - origin_y + @as(i64, node.cfg.scroll_y);
                max_bottom = @max(max_bottom, @max(content_bottom, 0));
            }
        }
    }
    return .{
        .width = max_right + @as(i64, node.cfg.padding[3]) + @as(i64, node.cfg.padding[1]),
        .height = max_bottom + @as(i64, node.cfg.padding[0]) + @as(i64, node.cfg.padding[2]),
    };
}

fn contentOverflowExcluded(node: *const layout.Node) bool {
    if (node.cfg.clip_children or node.cfg.scroll_x != 0 or node.cfg.scroll_y != 0) return true;
    if (hasExplicitClamp(node)) return true;
    var child = node.first_child;
    while (child) |c| : (child = c.next_sibling) {
        if (c.cfg.anchor == null and hasExplicitClamp(c)) return true;
    }
    return false;
}

fn textEnvelopeOverflows(node: *const layout.Node, font: Font) bool {
    const text = node.leaf.?.text;
    const f = text.font orelse font;
    const ink_height: i64 = @as(i64, font_mod.fontInkHeight(f));
    const node_left: i64 = node.rect.x;
    const node_top: i64 = node.rect.y;
    const node_right = node_left + @as(i64, node.rect.w);
    const node_bottom = node_top + @as(i64, node.rect.h);

    if (node.lines.len == 0) {
        const right = node_left + @as(i64, f.measure(text.str));
        const bottom = node_top + ink_height;
        return right > node_right or bottom > node_bottom;
    }
    for (node.lines) |line| {
        const top = node_top + @as(i64, line.y_offset);
        const right = node_left + @as(i64, f.measure(line.text));
        const bottom = top + ink_height;
        if (right > node_right or top < node_top or bottom > node_bottom) return true;
    }
    return false;
}

fn siblingOverlapCount(parent: *const layout.Node, allocator: Allocator) u32 {
    if (parent.flow_child_count < 2) return 0;
    const items = allocator.alloc(SweepItem, @intCast(parent.flow_child_count)) catch
        @panic("layout sanity probe: OOM");
    var count: usize = 0;
    var child = parent.first_child;
    while (child) |c| : (child = c.next_sibling) {
        if (c.cfg.anchor == null) {
            items[count] = .{ .node = c };
            count += 1;
        }
    }
    std.sort.pdq(SweepItem, items[0..count], {}, sweepLessThan);

    var overlaps: u32 = 0;
    for (items[0..count], 0..) |item, i| {
        const a = item.node.rect;
        const a_right = @as(i64, a.x) + @as(i64, a.w);
        const a_bottom = @as(i64, a.y) + @as(i64, a.h);
        for (items[i + 1 .. count]) |other| {
            const b = other.node.rect;
            if (@as(i64, b.x) >= a_right) break;
            const b_right = @as(i64, b.x) + @as(i64, b.w);
            const b_bottom = @as(i64, b.y) + @as(i64, b.h);
            if (@as(i64, a.x) < b_right and @as(i64, b.x) < a_right and
                @as(i64, a.y) < b_bottom and @as(i64, b.y) < a_bottom)
            {
                overlaps +|= 1;
            }
        }
    }
    return overlaps;
}

// This is a frame-time tree walk, not a per-pixel path. Scratch storage is allocated
// only for parents with at least two flow children, and the x sweep skips disjoint
// candidate pairs.
fn scanNode(node: *const layout.Node, font: Font, allocator: Allocator, ancestor_clipped: bool, result: *Result) void {
    if (node.leaf) |leaf| {
        if (!ancestor_clipped) switch (leaf) {
            .text => |text| {
                if (text.overflow == .visible and textEnvelopeOverflows(node, font)) result.text_overflow +|= 1;
            },
            .custom => {},
        };
        return;
    }

    if (!contentOverflowExcluded(node)) {
        const extent = childFlowExtent(node);
        if (extent.width > @as(i64, node.rect.w) or extent.height > @as(i64, node.rect.h)) {
            result.content_overflow +|= 1;
        }
    }
    result.sibling_overlap +|= siblingOverlapCount(node, allocator);

    const children_clipped = ancestor_clipped or node.cfg.clip_children;
    var child = node.first_child;
    while (child) |c| : (child = c.next_sibling) scanNode(c, font, allocator, children_clipped, result);
}

pub fn scan(root: *const layout.Node, font: Font, allocator: Allocator) Result {
    var result: Result = .{ .enabled = true, .scanned = true };
    scanNode(root, font, allocator, false, &result);
    return result;
}

pub fn digest(ctx_ptr: *anyopaque, buf: []u8) []const u8 {
    const result: *const Result = @ptrCast(@alignCast(ctx_ptr));
    return std.fmt.bufPrint(buf, "enabled={d} scanned={d} text_overflow={d} sibling_overlap={d} content_overflow={d} total={d}", .{
        @intFromBool(result.enabled),
        @intFromBool(result.scanned),
        result.text_overflow,
        result.sibling_overlap,
        result.content_overflow,
        result.total(),
    }) catch buf[0..0];
}

const testing = std.testing;

fn testTextLeaf(text: []const u8, width: i32, height: i32, opts: layout.Overflow) layout.Node {
    return .{
        .cfg = .{ .width = .{ .fixed = width }, .height = .{ .fixed = height } },
        .leaf = .{ .text = .{
            .str = text,
            .color = draw.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
            .font = null,
            .overflow = opts,
        } },
    };
}

fn scanTestTree(root: *layout.Node) Result {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const width = switch (root.cfg.width) {
        .fixed => |n| @as(u32, @intCast(n)),
        else => 200,
    };
    const height = switch (root.cfg.height) {
        .fixed => |n| @as(u32, @intCast(n)),
        else => 100,
    };
    layout.layoutTree(root, .{ .x = 0, .y = 0, .w = width, .h = height }, font_mod.default_font, arena.allocator());
    return scan(root, font_mod.default_font, arena.allocator());
}

test "fixture: fixed-width text reports a logical text overflow" {
    var root: layout.Node = .{ .cfg = .{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 100 } } };
    var text = testTextLeaf("too-wide", 16, 16, .visible);
    layout.appendChild(&root, &text);
    const result = scanTestTree(&root);
    try testing.expectEqual(@as(u32, 1), result.text_overflow);
}

test "fixture: fixed flow siblings report one overlap pair" {
    var root: layout.Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 40 }, .gap = -20 } };
    var first: layout.Node = .{ .cfg = .{ .width = .{ .fixed = 70 }, .height = .{ .fixed = 20 } } };
    var second: layout.Node = .{ .cfg = .{ .width = .{ .fixed = 60 }, .height = .{ .fixed = 20 } } };
    layout.appendChild(&root, &first);
    layout.appendChild(&root, &second);
    const result = scanTestTree(&root);
    try testing.expectEqual(@as(u32, 1), result.sibling_overlap);
}

test "fixture: content plus padding reports a fixed box overflow" {
    var root: layout.Node = .{ .cfg = .{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 40 }, .padding = .{ 0, 8, 0, 8 } } };
    var child: layout.Node = .{ .cfg = .{ .width = .{ .fixed = 32 }, .height = .{ .fixed = 20 } } };
    layout.appendChild(&root, &child);
    const result = scanTestTree(&root);
    try testing.expectEqual(@as(u32, 1), result.content_overflow);
}

test "fixture exclusions: clip, scroll, ellipsis, wrap, anchor, detached popup, and min-max" {
    {
        var root: layout.Node = .{ .cfg = .{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 100 } } };
        var clip: layout.Node = .{ .cfg = .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 }, .clip_children = true } };
        var text = testTextLeaf("too-wide", 20, 16, .visible);
        layout.appendChild(&clip, &text);
        layout.appendChild(&root, &clip);
        try testing.expectEqual(@as(u32, 0), scanTestTree(&root).total());
    }
    {
        var root: layout.Node = .{ .cfg = .{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 100 } } };
        var scroll: layout.Node = .{ .cfg = .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 }, .clip_children = true, .scroll_y = 4 } };
        var text = testTextLeaf("too-wide", 20, 16, .visible);
        layout.appendChild(&scroll, &text);
        layout.appendChild(&root, &scroll);
        try testing.expectEqual(@as(u32, 0), scanTestTree(&root).total());
    }
    {
        var root: layout.Node = .{ .cfg = .{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 100 } } };
        var text = testTextLeaf("too-wide", 16, 16, .ellipsis);
        layout.appendChild(&root, &text);
        try testing.expectEqual(@as(u32, 0), scanTestTree(&root).total());
    }
    {
        var root: layout.Node = .{ .cfg = .{ .width = .{ .fixed = 32 }, .height = .{ .fixed = 40 } } };
        var text = testTextLeaf("abcd", 32, 16, .visible);
        text.leaf = .{ .text = .{
            .str = "abcd",
            .color = draw.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
            .font = null,
            .wrap = true,
            .overflow = .visible,
        } };
        layout.appendChild(&root, &text);
        try testing.expectEqual(@as(u32, 0), scanTestTree(&root).total());
    }
    {
        var root: layout.Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } } };
        var flow: layout.Node = .{ .cfg = .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } } };
        var anchor: layout.Node = .{ .cfg = .{
            .width = .{ .fixed = 40 },
            .height = .{ .fixed = 20 },
            .anchor = .{ .at = .center },
        } };
        layout.appendChild(&root, &flow);
        layout.appendChild(&root, &anchor);
        try testing.expectEqual(@as(u32, 0), scanTestTree(&root).total());
    }
    {
        var root: layout.Node = .{ .cfg = .{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } } };
        var visible: layout.Node = .{ .cfg = .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } } };
        const detached_popup = testTextLeaf("detached", 16, 16, .visible);
        layout.appendChild(&root, &visible);
        _ = scanTestTree(&root);
        _ = detached_popup;
        try testing.expectEqual(@as(u32, 0), scanTestTree(&root).total());
    }
    {
        var root: layout.Node = .{ .cfg = .{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } } };
        var constrained: layout.Node = .{ .cfg = .{
            .width = .{ .grow = 1 },
            .height = .{ .fixed = 20 },
            .min_width = 80,
        } };
        layout.appendChild(&root, &constrained);
        try testing.expectEqual(@as(u32, 0), scanTestTree(&root).total());
    }
}
