// Flex layout engine.
// Five-stage pipeline after tree build (in context.zig):
//   measureWidths (post-order) → placeWidths (pre-order) → wrapText →
//   measureHeights (post-order) → placeHeights (pre-order).
// This file holds only types and the pure measure / place / wrap logic; it does not depend on Context.
//
// Hot path declaration: the five stages run every frame on the GUI layout path.
// They are not a per-pixel loop and do not touch the real-time audio path.
//
// Limitations:
// - wrap (main-axis flex wrap) is supported. wrap=true is illegal when the main-axis
//   Sizing is fit (a fit main axis grows to one line). wrap=true with a grow / percent
//   main axis is illegal when the cross axis is fit (line count is unknown at measure).
//   Line splitting uses each child's clamped resolved main size, except grow which
//   enters at its min (default 0) so membership does not depend on the share that
//   membership would determine. Inside a wrap box, cross-axis grow fills the line
//   (not the container) and cross-axis percent resolves against the line cross size.
// - no shrink. If children exceed the parent they overflow (clip_children can hide
//   the overflow). min/max clamp is uniform across fixed/fit/grow/percent: applied
//   to computeMeasured and to every placed main/cross size. weight-0 grow children
//   take none of the remainder but still clamp (grow=0, min=20 is 20 and is frozen
//   into used from the start). If the sum of mins exceeds the remainder, each child
//   still gets its min and the parent overflows. Leftover remainder stays as a
//   trailing gap when no unfrozen weight>0 grow child remains (every such child
//   max-frozen, or none existed). Freeze iteration is bit-identical to the
//   unconstrained peel when no clamp fires.
// - no absolute positioning
// - main-axis alignment (justify_content) is start only; right-align etc. by inserting a grow box
// - grow / percent children inside a fit parent measure as 0 (the fit parent shrinks accordingly).
//   This holds on both axes, including measureHeights.
// - percent is relative to the parent content box (after padding, before gap). Floor truncation;
//   no sum correction among percent children. Leftover px from truncation is absorbed by grow children

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const color_mod = @import("color.zig");
const draw_mod = @import("draw.zig");
const font_mod = @import("font.zig");
const id_mod = @import("id.zig");
const text_wrap = @import("text_wrap.zig");

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
    /// Orthogonal clamp applied to every Sizing on this axis (fixed/fit/grow/percent).
    /// Defaults are a no-op: min 0, max maxInt(i32).
    min_width: i32 = 0,
    min_height: i32 = 0,
    max_width: i32 = std.math.maxInt(i32),
    max_height: i32 = std.math.maxInt(i32),
    /// top, right, bottom, left
    padding: [4]i32 = .{ 0, 0, 0, 0 },
    gap: i32 = 0,
    /// Cross-axis gap between wrap lines. null means the same value as `gap`.
    /// Optional so a negative gap stays distinct from "use gap".
    cross_gap: ?i32 = null,
    /// When true, children wrap onto the next cross-axis line once the main axis
    /// is full. See the Limitations block for the wrap contracts.
    wrap: bool = false,
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

pub const Overflow = text_wrap.Overflow;

pub const LeafKind = union(enum) {
    /// font is an override (null = Context font). Affects both measure and draw (the draw cmd's font);
    /// emitNode carries font onto the draw cmd.
    /// `wrap` folds each paragraph at the placed width. `overflow` applies only to this
    /// leaf's draw commands (not to CachedRect.clip or hit-test).
    text: struct {
        str: []const u8,
        color: Color,
        font: ?Font,
        wrap: bool = false,
        max_lines: u16 = 0,
        overflow: Overflow = .visible,
    },
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
    /// Content extent after place, in border-box units (max child edge + both paddings).
    /// Origin is this node's content origin (inside padding). Child rects have
    /// scroll_x/y added back so the extent does not depend on scroll. Negative
    /// child positions do not extend past the origin (clamped at 0 before max).
    /// An unclipped child's own content extent is included, offset by the child.
    /// -1 = not recorded: a leaf never records extent, and a box stays -1 until
    /// placeHeights runs. A leaf has no children; its own rect is already folded
    /// into the parent's extent, so a leaf-side content_w/h would duplicate that.
    content_w: i32 = -1,
    content_h: i32 = -1,
    /// Final rect after placement (set by placeWidths / placeHeights)
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    leaf: ?LeafKind = null,
    /// Logical lines from wrapText. Empty until wrapText runs. Slices borrow the
    /// leaf string or an allocator-owned normalised / ellipsis buffer.
    lines: []const text_wrap.Line = &.{},
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

/// Whether `cfg.wrap` is legal with the main/cross Sizing pair.
pub fn wrapConfigValid(cfg: BoxConfig) bool {
    if (!cfg.wrap) return true;
    const main = switch (cfg.direction) {
        .row => cfg.width,
        .column => cfg.height,
    };
    const cross = switch (cfg.direction) {
        .row => cfg.height,
        .column => cfg.width,
    };
    if (main == .fit) return false;
    const main_indefinite = switch (main) {
        .grow, .percent => true,
        else => false,
    };
    if (main_indefinite and cross == .fit) return false;
    return true;
}

/// Detect invalid BoxConfig values in debug builds (called from beginBox).
pub fn assertBoxConfigValid(cfg: BoxConfig) void {
    assertSizingValid(cfg.width);
    assertSizingValid(cfg.height);
    std.debug.assert(cfg.min_width >= 0);
    std.debug.assert(cfg.min_height >= 0);
    std.debug.assert(cfg.max_width >= cfg.min_width);
    std.debug.assert(cfg.max_height >= cfg.min_height);
    std.debug.assert(wrapConfigValid(cfg));
}

/// Declared fixed size after min/max clamp, or -1 when the axis is not `.fixed`.
pub fn declaredSizeOf(node: *const Node, axis_is_w: bool) i32 {
    const s = if (axis_is_w) node.cfg.width else node.cfg.height;
    return switch (s) {
        .fixed => |n| clampAxis(node, if (axis_is_w) .w else .h, n),
        else => -1,
    };
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

fn minOf(node: *const Node, axis: Axis) i32 {
    return switch (axis) {
        .w => node.cfg.min_width,
        .h => node.cfg.min_height,
    };
}

fn maxOf(node: *const Node, axis: Axis) i32 {
    return switch (axis) {
        .w => node.cfg.max_width,
        .h => node.cfg.max_height,
    };
}

fn clampAxis(node: *const Node, axis: Axis, value: i32) i32 {
    return std.math.clamp(value, minOf(node, axis), maxOf(node, axis));
}

fn hasAxisClamp(node: *const Node, axis: Axis) bool {
    return minOf(node, axis) > 0 or maxOf(node, axis) < std.math.maxInt(i32);
}

fn growWeightOf(node: *const Node, axis: Axis) u16 {
    return switch (sizingOf(node, axis)) {
        .grow => |w| w,
        else => 0,
    };
}

fn effectiveCrossGap(cfg: BoxConfig) i32 {
    return cfg.cross_gap orelse cfg.gap;
}

fn crossAxis(cfg: BoxConfig) Axis {
    return switch (cfg.direction) {
        .row => .h,
        .column => .w,
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

/// Width measure (post-order). Text leaves use `measureIntrinsicWidth` only —
/// layout never calls `font.measure` on a leaf string directly, so wrap and
/// non-wrap share one paragraph rule.
///
/// Hot path: every frame on the GUI layout path; not a per-pixel loop; not RT.
pub fn measureWidths(node: *Node, default_font: Font) void {
    if (node.leaf) |leaf| {
        switch (leaf) {
            .text => |t| {
                const f = t.font orelse default_font;
                node.measured_w = text_wrap.measureIntrinsicWidth(f, t.str);
            },
            .custom => |c| {
                node.measured_w = @max(0, c.measured.x);
            },
        }
        return;
    }
    var it = node.first_child;
    while (it) |c| : (it = c.next_sibling) measureWidths(c, default_font);
    node.measured_w = computeMeasured(node, .w);
}

/// Height measure (post-order). Text-leaf `measured_h` is already set by wrapText
/// (or by `seedTextHeightsUnwrapped` when tests call `measure` without wrap).
/// grow / percent children inside a fit parent measure as 0 on this axis too.
///
/// Hot path: every frame on the GUI layout path; not a per-pixel loop; not RT.
pub fn measureHeights(node: *Node, default_font: Font) void {
    if (node.leaf) |leaf| {
        switch (leaf) {
            .text => {},
            .custom => |c| {
                node.measured_h = @max(0, c.measured.y);
            },
        }
        return;
    }
    var it = node.first_child;
    while (it) |c| : (it = c.next_sibling) measureHeights(c, default_font);
    node.measured_h = computeMeasured(node, .h);
}

fn seedTextHeightsUnwrapped(node: *Node, default_font: Font) void {
    if (node.leaf) |leaf| {
        switch (leaf) {
            .text => |t| {
                const f = t.font orelse default_font;
                node.measured_h = text_wrap.heightForLineCount(f, text_wrap.paragraphCount(t.str));
            },
            .custom => |c| {
                node.measured_h = @max(0, c.measured.y);
            },
        }
        return;
    }
    var it = node.first_child;
    while (it) |c| : (it = c.next_sibling) seedTextHeightsUnwrapped(c, default_font);
}

/// Convenience for callers that do not wrap: measure both axes, using paragraph
/// count (not wrap-folded line count) for text height.
pub fn measure(node: *Node, default_font: Font) void {
    measureWidths(node, default_font);
    seedTextHeightsUnwrapped(node, default_font);
    measureHeights(node, default_font);
}

fn computeMeasured(node: *const Node, axis: Axis) i32 {
    const raw: i32 = switch (sizingOf(node, axis)) {
        .fixed => |n| n,
        .grow, .percent => 0, // Unresolved at measure time
        .fit => blk: {
            if (node.cfg.wrap and mainAxis(node.cfg) != axis) {
                break :blk measureWrapCross(node, axis);
            }
            const pad = axisPadding(node.cfg, axis);
            if (mainAxis(node.cfg) == axis) {
                var sum: i32 = 0;
                var it = node.first_child;
                while (it) |c| : (it = c.next_sibling) sum += measuredOf(c, axis);
                break :blk sum + gapTotal(node.cfg.gap, node.child_count) + pad;
            } else {
                var max_child: i32 = 0;
                var it = node.first_child;
                while (it) |c| : (it = c.next_sibling) max_child = @max(max_child, measuredOf(c, axis));
                break :blk max_child + pad;
            }
        },
    };
    return clampAxis(node, axis, raw);
}

/// Place widths (pre-order). Sets `rect.x` / `rect.w` from `rect` and resolves
/// children on the width axis only.
///
/// Hot path: every frame on the GUI layout path; not a per-pixel loop; not RT.
pub fn placeWidths(node: *Node, rect: Rect) void {
    node.rect.x = rect.x;
    node.rect.w = rect.w;
    if (node.leaf != null or node.first_child == null) return;
    placeChildrenOnAxis(node, .w);
}

/// Place heights (pre-order). Sets `rect.y` / `rect.h` from `rect` and resolves
/// children on the height axis only. A box records content extent here, folded
/// into the same child walk that places (children already have both axes from
/// placeWidths + this pass). A leaf returns without recording: it has no
/// children, and the parent already includes the leaf rect in its own extent.
///
/// Hot path: every frame on the GUI layout path; not a per-pixel loop; not RT.
pub fn placeHeights(node: *Node, rect: Rect) void {
    node.rect.y = rect.y;
    node.rect.h = rect.h;
    if (node.leaf != null) return;
    if (node.first_child == null) {
        node.content_w = node.cfg.padding[3] + node.cfg.padding[1];
        node.content_h = node.cfg.padding[0] + node.cfg.padding[2];
        return;
    }
    placeChildrenOnAxis(node, .h);
}

/// Convenience: place both axes. Requires a prior measure. Does not wrap text.
pub fn place(node: *Node, rect: Rect) void {
    placeWidths(node, rect);
    placeHeights(node, rect);
}

fn resolveSize(child: *const Node, axis: Axis, content: i32, grow_take: ?i32) i32 {
    const raw: i32 = switch (sizingOf(child, axis)) {
        .fixed => |n| n,
        .fit => measuredOf(child, axis),
        .percent => |f| percentOf(content, f),
        .grow => |w| blk: {
            if (grow_take) |take| break :blk take;
            _ = w;
            // Cross-axis grow ignores weight and fills the given content
            // (parent content, or the wrap line's cross size).
            break :blk content;
        },
    };
    return clampAxis(child, axis, raw);
}

/// Size a child contributes when deciding which flex line it belongs on.
///
/// Hot path: every frame on the GUI layout path (O(children) per wrap box);
/// not a per-pixel loop; not RT.
///
/// fixed / fit / percent enter at their clamped resolved size. grow enters at
/// its min (default 0). grow's final share depends on who shares the line, and
/// line membership would otherwise depend on that share — using min breaks
/// the cycle.
fn wrapEntrySize(child: *const Node, main: Axis, content_main: i32) i32 {
    return switch (sizingOf(child, main)) {
        .grow => minOf(child, main),
        .fixed => |n| clampAxis(child, main, n),
        .fit => clampAxis(child, main, measuredOf(child, main)),
        .percent => |f| clampAxis(child, main, percentOf(content_main, f)),
    };
}

fn nextLineStart(first: *Node, content_main: i32, gap: i32, main: Axis) ?*Node {
    var used = wrapEntrySize(first, main, content_main);
    var it = first.next_sibling;
    while (it) |c| {
        const entry = wrapEntrySize(c, main, content_main);
        if (used + gap + entry > content_main) return c;
        used += gap + entry;
        it = c.next_sibling;
    }
    return null;
}

fn countUntil(first: *Node, end: ?*Node) u32 {
    var n: u32 = 0;
    var it: ?*Node = first;
    while (it) |c| {
        if (c == end) break;
        n += 1;
        it = c.next_sibling;
    }
    return n;
}

fn lineHasClamp(first: *Node, end: ?*Node, axis: Axis) bool {
    var it: ?*Node = first;
    while (it) |c| {
        if (c == end) break;
        if (hasAxisClamp(c, axis)) return true;
        it = c.next_sibling;
    }
    return false;
}

/// Line cross size: max of (non-grow/percent children's clamped resolved size,
/// grow/percent children's min). A line of only grow/percent children with
/// min 0 has cross 0 (same idea as grow/percent measuring 0 inside a fit parent).
fn lineCrossSize(first: *Node, end: ?*Node, cross: Axis) i32 {
    var line_cross: i32 = 0;
    var it: ?*Node = first;
    while (it) |c| {
        if (c == end) break;
        const contrib: i32 = switch (sizingOf(c, cross)) {
            .grow, .percent => minOf(c, cross),
            .fixed => |n| clampAxis(c, cross, n),
            .fit => clampAxis(c, cross, measuredOf(c, cross)),
        };
        line_cross = @max(line_cross, contrib);
        it = c.next_sibling;
    }
    return line_cross;
}

fn wrapContentMainForMeasure(node: *const Node) i32 {
    const main = mainAxis(node.cfg);
    const pad = axisPadding(node.cfg, main);
    return switch (sizingOf(node, main)) {
        .fixed => |n| @max(0, clampAxis(node, main, n) - pad),
        .fit, .grow, .percent => @max(0, clampAxis(node, main, measuredOf(node, main)) - pad),
    };
}

fn measureWrapCross(node: *const Node, cross: Axis) i32 {
    const main = mainAxis(node.cfg);
    const content_main = wrapContentMainForMeasure(node);
    const gap = node.cfg.gap;
    const cgap = effectiveCrossGap(node.cfg);
    const pad = axisPadding(node.cfg, cross);
    var first = node.first_child;
    if (first == null) return pad;
    var total: i32 = 0;
    var nlines: u32 = 0;
    while (first) |f| {
        const end = nextLineStart(f, content_main, gap, main);
        total += lineCrossSize(f, end, cross);
        nlines += 1;
        first = end;
    }
    if (nlines > 1) total += cgap * (@as(i32, @intCast(nlines)) - 1);
    return total + pad;
}

fn resolveContentMain(node: *const Node) i32 {
    const main = mainAxis(node.cfg);
    const pad = axisPadding(node.cfg, main);
    const placed: i32 = if (main == .w)
        @intCast(node.rect.w)
    else
        @intCast(node.rect.h);
    return @max(0, clampAxis(node, main, placed) - pad);
}

fn mainSizeKnown(node: *const Node, placing_axis: Axis) bool {
    const main = mainAxis(node.cfg);
    if (placing_axis == main) return true;
    if (sizingOf(node, main) == .fixed) return true;
    // Widths are placed before heights, so a row-wrap box already has rect.w.
    return main == .w;
}

fn contentMainForPlace(node: *const Node, placing_axis: Axis) i32 {
    if (mainSizeKnown(node, placing_axis)) return resolveContentMain(node);
    return switch (sizingOf(node, mainAxis(node.cfg))) {
        .fixed => |n| @max(0, clampAxis(node, mainAxis(node.cfg), n) - axisPadding(node.cfg, mainAxis(node.cfg))),
        else => std.math.maxInt(i32) / 4,
    };
}

const unfrozen_mark: u32 = std.math.maxInt(u32);

fn rectSizeU(node: *const Node, axis: Axis) u32 {
    return if (axis == .w) node.rect.w else node.rect.h;
}

fn setRectSizeU(node: *Node, axis: Axis, v: u32) void {
    if (axis == .w) node.rect.w = v else node.rect.h = v;
}

fn setRectSizeI(node: *Node, axis: Axis, v: i32) void {
    setRectSizeU(node, axis, @intCast(@max(0, v)));
}

fn isUnfrozenGrow(node: *const Node, axis: Axis) bool {
    return switch (sizingOf(node, axis)) {
        .grow => |w| w > 0 and rectSizeU(node, axis) == unfrozen_mark,
        else => false,
    };
}

const ExtentAcc = struct {
    parent: *const Node,
    max_right: *i32,
    max_bottom: *i32,
};

fn accumulateExtent(parent: *const Node, child: *const Node, max_right: *i32, max_bottom: *i32) void {
    const origin_x = parent.rect.x + parent.cfg.padding[3];
    const origin_y = parent.rect.y + parent.cfg.padding[0];
    const child_right = child.rect.x + @as(i32, @intCast(child.rect.w));
    const child_bottom = child.rect.y + @as(i32, @intCast(child.rect.h));
    const rel_right = child_right - origin_x + parent.cfg.scroll_x;
    const rel_bottom = child_bottom - origin_y + parent.cfg.scroll_y;
    max_right.* = @max(max_right.*, @max(rel_right, 0));
    max_bottom.* = @max(max_bottom.*, @max(rel_bottom, 0));
    if (!child.cfg.clip_children) {
        if (child.content_w >= 0) {
            const ext_right = child.rect.x + child.content_w - origin_x + parent.cfg.scroll_x;
            max_right.* = @max(max_right.*, @max(ext_right, 0));
        }
        if (child.content_h >= 0) {
            const ext_bottom = child.rect.y + child.content_h - origin_y + parent.cfg.scroll_y;
            max_bottom.* = @max(max_bottom.*, @max(ext_bottom, 0));
        }
    }
}

fn commitExtent(node: *Node, max_right: i32, max_bottom: i32) void {
    node.content_w = max_right + node.cfg.padding[3] + node.cfg.padding[1];
    node.content_h = max_bottom + node.cfg.padding[0] + node.cfg.padding[2];
}

fn placeChildrenOnAxis(node: *Node, axis: Axis) void {
    if (node.cfg.wrap) {
        placeWrapOnAxis(node, axis);
        return;
    }
    placeLinearOnAxis(node, axis);
}

fn placeLinearOnAxis(node: *Node, axis: Axis) void {
    const cfg = node.cfg;
    const main = mainAxis(cfg);
    const content_origin: i32 = if (axis == .w)
        node.rect.x + cfg.padding[3]
    else
        node.rect.y + cfg.padding[0];
    const content_size: i32 = @max(0, @as(i32, @intCast(if (axis == .w) node.rect.w else node.rect.h)) - axisPadding(cfg, axis));
    const scroll: i32 = if (axis == .w) cfg.scroll_x else cfg.scroll_y;
    var max_right: i32 = 0;
    var max_bottom: i32 = 0;

    if (main == axis) {
        const acc: ?ExtentAcc = if (axis == .h) .{
            .parent = node,
            .max_right = &max_right,
            .max_bottom = &max_bottom,
        } else null;
        placeLineMain(node.first_child, null, node.child_count, content_origin - scroll, content_size, cfg.gap, axis, acc);
        if (axis == .h) commitExtent(node, max_right, max_bottom);
    } else {
        var it = node.first_child;
        while (it) |c| : (it = c.next_sibling) {
            const size: i32 = resolveSize(c, axis, content_size, null);
            const cross_off: i32 = switch (cfg.align_cross) {
                .start => 0,
                .center => @divFloor(content_size - size, 2),
                .end => content_size - size,
            };
            descendPlace(c, axis, content_origin + cross_off - scroll, size);
            if (axis == .h) accumulateExtent(node, c, &max_right, &max_bottom);
        }
        if (axis == .h) commitExtent(node, max_right, max_bottom);
    }
}

/// Distribute leftover main-axis space among grow children on one line, then place.
///
/// Hot path: every frame on the GUI layout path. Line membership and placement
/// are O(children). Freeze reallocation is worst-case O(grow_on_line^2);
/// practical grow counts are small. Not a per-pixel loop; not RT.
///
/// Invariants:
/// - weight 0 grow children take 0 of the remainder but still receive min/max
///   clamp (a grow=0, min=20 child is 20 and is frozen into used from the start).
/// - if the sum of mins exceeds the remainder, each child still gets its min
///   and the parent overflows (same as the no-shrink contract).
/// - leftover remainder stays as a trailing gap when no unfrozen weight>0 grow
///   child remains (every such child max-frozen, or none existed).
/// - with no clamp violations the peel is bit-identical to the unconstrained
///   accumulate-peel (the no-clamp branch is that peel).
fn placeLineMain(
    first: ?*Node,
    end: ?*Node,
    count: u32,
    cursor0: i32,
    content_main: i32,
    gap: i32,
    axis: Axis,
    extent: ?ExtentAcc,
) void {
    const start = first orelse return;
    if (!lineHasClamp(start, end, axis)) {
        var used: i32 = gapTotal(gap, count);
        var grow_total: i64 = 0;
        var it: ?*Node = start;
        while (it) |c| {
            if (c == end) break;
            switch (sizingOf(c, axis)) {
                .fixed => |n| used += n,
                .fit => used += measuredOf(c, axis),
                .percent => |f| used += percentOf(content_main, f),
                .grow => |w| grow_total += w,
            }
            it = c.next_sibling;
        }
        var remaining: i64 = @max(0, content_main - used);
        var w_rest: i64 = grow_total;
        var cursor: i32 = cursor0;
        it = start;
        while (it) |c| {
            if (c == end) break;
            const size: i32 = switch (sizingOf(c, axis)) {
                .fixed => |n| n,
                .fit => measuredOf(c, axis),
                .percent => |f| percentOf(content_main, f),
                .grow => |w| blk: {
                    const take: i64 = if (w_rest > 0) @divTrunc(remaining * w, w_rest) else 0;
                    remaining -= take;
                    w_rest -= w;
                    break :blk @intCast(take);
                },
            };
            descendPlace(c, axis, cursor, size);
            if (extent) |acc| accumulateExtent(acc.parent, c, acc.max_right, acc.max_bottom);
            cursor += size + gap;
            it = c.next_sibling;
        }
        return;
    }

    var used: i32 = gapTotal(gap, count);
    var it: ?*Node = start;
    while (it) |c| {
        if (c == end) break;
        switch (sizingOf(c, axis)) {
            .grow => |w| {
                if (w == 0) {
                    const sz = clampAxis(c, axis, 0);
                    setRectSizeI(c, axis, sz);
                    used += sz;
                } else {
                    setRectSizeU(c, axis, unfrozen_mark);
                }
            },
            else => {
                const sz = resolveSize(c, axis, content_main, 0);
                setRectSizeI(c, axis, sz);
                used += sz;
            },
        }
        it = c.next_sibling;
    }

    while (true) {
        var w_rest: i64 = 0;
        it = start;
        while (it) |c| {
            if (c == end) break;
            if (isUnfrozenGrow(c, axis)) w_rest += growWeightOf(c, axis);
            it = c.next_sibling;
        }
        if (w_rest == 0) break;

        const remaining: i64 = @max(0, content_main - used);
        var peel_rem = remaining;
        var wr = w_rest;
        var any_freeze = false;
        it = start;
        while (it) |c| {
            if (c == end) break;
            if (isUnfrozenGrow(c, axis)) {
                const w: i64 = growWeightOf(c, axis);
                const take: i64 = if (wr > 0) @divTrunc(peel_rem * w, wr) else 0;
                peel_rem -= take;
                wr -= w;
                const take_i: i32 = @intCast(take);
                const clamped = clampAxis(c, axis, take_i);
                if (clamped != take_i) {
                    setRectSizeI(c, axis, clamped);
                    used += clamped;
                    any_freeze = true;
                }
            }
            it = c.next_sibling;
        }
        if (!any_freeze) {
            peel_rem = remaining;
            wr = w_rest;
            it = start;
            while (it) |c| {
                if (c == end) break;
                if (isUnfrozenGrow(c, axis)) {
                    const w: i64 = growWeightOf(c, axis);
                    const take: i64 = if (wr > 0) @divTrunc(peel_rem * w, wr) else 0;
                    peel_rem -= take;
                    wr -= w;
                    setRectSizeI(c, axis, @intCast(take));
                }
                it = c.next_sibling;
            }
            break;
        }
    }

    var cursor: i32 = cursor0;
    it = start;
    while (it) |c| {
        if (c == end) break;
        const size: i32 = @intCast(rectSizeU(c, axis));
        descendPlace(c, axis, cursor, size);
        if (extent) |acc| accumulateExtent(acc.parent, c, acc.max_right, acc.max_bottom);
        cursor += size + gap;
        it = c.next_sibling;
    }
}

fn placeWrapOnAxis(node: *Node, axis: Axis) void {
    const main = mainAxis(node.cfg);
    if (axis == main) {
        placeWrapMain(node);
        if (main == .h) {
            // Column wrap: main (height) is now known, so re-place cross (width)
            // with the final line membership.
            placeWrapCross(node, true, true);
        }
    } else {
        placeWrapCross(node, axis == .h, mainSizeKnown(node, axis));
    }
}

fn placeWrapMain(node: *Node) void {
    const cfg = node.cfg;
    const main = mainAxis(cfg);
    const content_main = resolveContentMain(node);
    const origin: i32 = if (main == .w)
        node.rect.x + cfg.padding[3]
    else
        node.rect.y + cfg.padding[0];
    const scroll: i32 = if (main == .w) cfg.scroll_x else cfg.scroll_y;
    var first = node.first_child;
    while (first) |f| {
        const end = nextLineStart(f, content_main, cfg.gap, main);
        const count = countUntil(f, end);
        placeLineMain(f, end, count, origin - scroll, content_main, cfg.gap, main, null);
        first = end;
    }
}

fn placeWrapCross(node: *Node, record_extent: bool, main_known: bool) void {
    const cfg = node.cfg;
    const main = mainAxis(cfg);
    const cross = crossAxis(cfg);
    const content_main = if (main_known) resolveContentMain(node) else contentMainForPlace(node, cross);
    const cgap = effectiveCrossGap(cfg);
    const origin_cross: i32 = if (cross == .w)
        node.rect.x + cfg.padding[3]
    else
        node.rect.y + cfg.padding[0];
    const scroll_cross: i32 = if (cross == .w) cfg.scroll_x else cfg.scroll_y;
    var max_right: i32 = 0;
    var max_bottom: i32 = 0;
    var cross_cursor = origin_cross - scroll_cross;
    var first = node.first_child;
    while (first) |f| {
        const end = nextLineStart(f, content_main, cfg.gap, main);
        const line_cross = lineCrossSize(f, end, cross);
        var it: ?*Node = f;
        while (it) |c| {
            if (c == end) break;
            const size = resolveSize(c, cross, line_cross, null);
            const cross_off: i32 = switch (cfg.align_cross) {
                .start => 0,
                .center => @divFloor(line_cross - size, 2),
                .end => line_cross - size,
            };
            descendPlace(c, cross, cross_cursor + cross_off, size);
            if (record_extent) accumulateExtent(node, c, &max_right, &max_bottom);
            it = c.next_sibling;
        }
        cross_cursor += line_cross + cgap;
        first = end;
    }
    if (record_extent) commitExtent(node, max_right, max_bottom);
}

fn descendPlace(child: *Node, axis: Axis, pos: i32, size: i32) void {
    const s: u32 = @intCast(@max(0, size));
    if (axis == .w) {
        placeWidths(child, .{ .x = pos, .y = 0, .w = s, .h = 0 });
    } else {
        placeHeights(child, .{ .x = 0, .y = pos, .w = 0, .h = s });
    }
}

/// Fold every text leaf at its placed width, store logical lines on the node,
/// and set `measured_h` from the line count. Non-wrap leaves still split on
/// paragraphs. A single-paragraph, non-wrap, `.visible` leaf that needs no
/// normalisation leaves `lines` empty (emit uses the original string).
///
/// Hot path: every frame on the GUI layout path; not a per-pixel loop; not RT.
pub fn wrapText(node: *Node, default_font: Font, allocator: Allocator) void {
    if (node.leaf) |leaf| {
        switch (leaf) {
            .text => |t| {
                const f = t.font orelse default_font;
                const opts = text_wrap.WrapOpts{
                    .wrap = t.wrap,
                    .max_lines = t.max_lines,
                    .overflow = t.overflow,
                };
                const avail: i32 = @intCast(node.rect.w);
                const wrapped = text_wrap.wrapParagraphs(allocator, f, t.str, avail, opts) catch
                    @panic("layout.wrapText: OOM");
                node.lines = wrapped.lines;
                const n_lines: u32 = if (wrapped.lines.len == 0) 1 else @intCast(wrapped.lines.len);
                node.measured_h = text_wrap.heightForLineCount(f, n_lines);
            },
            .custom => |c| {
                node.measured_h = @max(0, c.measured.y);
            },
        }
        return;
    }
    var it = node.first_child;
    while (it) |c| : (it = c.next_sibling) wrapText(c, default_font, allocator);
}

/// Full five-stage layout. Prefer this over `measure` + `place` when text may wrap.
///
/// Hot path: every frame on the GUI layout path; not a per-pixel loop; not RT.
pub fn layoutTree(node: *Node, rect: Rect, font: Font, allocator: Allocator) void {
    measureWidths(node, font);
    placeWidths(node, rect);
    wrapText(node, font, allocator);
    measureHeights(node, font);
    placeHeights(node, rect);
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

const white = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);

fn textLeaf(str: []const u8, wrap: bool) Node {
    return .{
        .cfg = .{ .width = if (wrap) .{ .grow = 1 } else .fit },
        .leaf = .{ .text = .{ .str = str, .color = white, .font = null, .wrap = wrap } },
    };
}

test "measureWidths: text leaf uses measureIntrinsicWidth (not font.measure)" {
    var t: Node = textLeaf("ab\nabc", false);
    measureWidths(&t, test_font);
    try std.testing.expectEqual(@as(i32, 24), t.measured_w);
}

test "layoutTree: wrap leaf height under a fixed-width parent" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    var root: Node = .{ .cfg = .{ .direction = .column, .width = .{ .fixed = 40 }, .height = .fit } };
    var t: Node = textLeaf("hello world", true);
    appendChild(&root, &t);
    layoutTree(&root, .{ .x = 0, .y = 0, .w = 40, .h = 200 }, test_font, arena_inst.allocator());
    try std.testing.expectEqual(@as(u32, 40), t.rect.w);
    try std.testing.expectEqual(@as(i32, 32), t.measured_h);
    try std.testing.expectEqual(@as(usize, 2), t.lines.len);
}

test "layoutTree: wrap leaf height under a grow-width parent" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    var screen: Node = .{ .cfg = .{ .direction = .column, .width = .{ .fixed = 40 }, .height = .{ .fixed = 200 } } };
    var parent: Node = .{ .cfg = .{ .direction = .column, .width = .{ .grow = 1 }, .height = .fit } };
    var t: Node = textLeaf("hello world", true);
    appendChild(&parent, &t);
    appendChild(&screen, &parent);
    layoutTree(&screen, .{ .x = 0, .y = 0, .w = 40, .h = 200 }, test_font, arena_inst.allocator());
    try std.testing.expectEqual(@as(u32, 40), t.rect.w);
    try std.testing.expectEqual(@as(i32, 32), t.measured_h);
}

test "layoutTree: wrap leaf height under a percent-width parent" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    var screen: Node = .{ .cfg = .{ .direction = .column, .width = .{ .fixed = 80 }, .height = .{ .fixed = 200 } } };
    var parent: Node = .{ .cfg = .{ .direction = .column, .width = .{ .percent = 0.5 }, .height = .fit } };
    var t: Node = textLeaf("hello world", true);
    appendChild(&parent, &t);
    appendChild(&screen, &parent);
    layoutTree(&screen, .{ .x = 0, .y = 0, .w = 80, .h = 200 }, test_font, arena_inst.allocator());
    try std.testing.expectEqual(@as(u32, 40), t.rect.w);
    try std.testing.expectEqual(@as(i32, 32), t.measured_h);
}

test "layoutTree: n=1 wrap matches the non-wrap measured size" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    var wrapped: Node = textLeaf("Hello", true);
    var plain: Node = textLeaf("Hello", false);
    layoutTree(&wrapped, .{ .x = 0, .y = 0, .w = 200, .h = 50 }, test_font, arena_inst.allocator());
    measure(&plain, test_font);
    place(&plain, .{ .x = 0, .y = 0, .w = 200, .h = 50 });
    try std.testing.expectEqual(plain.measured_w, wrapped.measured_w);
    try std.testing.expectEqual(plain.measured_h, wrapped.measured_h);
    try std.testing.expectEqual(@as(i32, 16), wrapped.measured_h);
}

test "layoutTree: fit-width parent does not wrap (max-content)" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    var root: Node = .{ .cfg = .{ .direction = .column, .width = .fit, .height = .fit } };
    var t: Node = textLeaf("hello world", true);
    appendChild(&root, &t);
    layoutTree(&root, .{ .x = 0, .y = 0, .w = 200, .h = 50 }, test_font, arena_inst.allocator());
    try std.testing.expectEqual(@as(i32, 88), root.measured_w);
    try std.testing.expectEqual(@as(i32, 16), t.measured_h);
    try std.testing.expectEqual(@as(usize, 1), t.lines.len);
}

test "layoutTree: wrap works in a row parent" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 40 }, .height = .fit } };
    var t: Node = textLeaf("hello world", true);
    appendChild(&root, &t);
    layoutTree(&root, .{ .x = 0, .y = 0, .w = 40, .h = 200 }, test_font, arena_inst.allocator());
    try std.testing.expectEqual(@as(u32, 40), t.rect.w);
    try std.testing.expectEqual(@as(i32, 32), t.measured_h);
}

test "layoutTree: wrap respects padding, gap, and align_cross" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    var root: Node = .{ .cfg = .{
        .direction = .row,
        .width = .{ .fixed = 80 },
        .height = .{ .fixed = 80 },
        .padding = .{ 4, 4, 4, 4 },
        .align_cross = .center,
    } };
    var t: Node = textLeaf("hello world", true);
    appendChild(&root, &t);
    layoutTree(&root, .{ .x = 0, .y = 0, .w = 80, .h = 80 }, test_font, arena_inst.allocator());
    try std.testing.expectEqual(@as(u32, 72), t.rect.w);
    try std.testing.expectEqual(@as(i32, 32), t.measured_h);
    try std.testing.expectEqual(@as(i32, 4 + @divFloor(72 - 32, 2)), t.rect.y);
}

test "layoutTree: wrap height under fixed / fit / percent / grow parents" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    {
        var root: Node = .{ .cfg = .{ .direction = .column, .width = .{ .fixed = 40 }, .height = .{ .fixed = 10 } } };
        var t: Node = textLeaf("hello world", true);
        appendChild(&root, &t);
        layoutTree(&root, .{ .x = 0, .y = 0, .w = 40, .h = 10 }, test_font, a);
        try std.testing.expectEqual(@as(i32, 32), t.measured_h);
        try std.testing.expectEqual(@as(u32, 32), t.rect.h);
    }
    {
        var screen: Node = .{ .cfg = .{ .direction = .column, .width = .{ .fixed = 40 }, .height = .{ .fixed = 100 } } };
        var parent: Node = .{ .cfg = .{ .direction = .column, .width = .{ .grow = 1 }, .height = .{ .percent = 0.5 } } };
        var t: Node = textLeaf("hello world", true);
        appendChild(&parent, &t);
        appendChild(&screen, &parent);
        layoutTree(&screen, .{ .x = 0, .y = 0, .w = 40, .h = 100 }, test_font, a);
        try std.testing.expectEqual(@as(u32, 50), parent.rect.h);
        try std.testing.expectEqual(@as(i32, 32), t.measured_h);
    }
}

test "layoutTree: wrap + cross-axis grow and a nested tree" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    var outer: Node = .{ .cfg = .{
        .direction = .column,
        .width = .{ .fixed = 48 },
        .height = .{ .fixed = 80 },
        .padding = .{ 2, 2, 2, 2 },
    } };
    var inner: Node = .{ .cfg = .{ .direction = .column, .width = .{ .grow = 1 }, .height = .fit } };
    var t: Node = textLeaf("hello world", true);
    appendChild(&inner, &t);
    appendChild(&outer, &inner);
    layoutTree(&outer, .{ .x = 0, .y = 0, .w = 48, .h = 80 }, test_font, arena_inst.allocator());
    try std.testing.expectEqual(@as(u32, 44), t.rect.w);
    try std.testing.expectEqual(@as(i32, 32), t.measured_h);
    try std.testing.expectEqual(@as(i32, 32), inner.measured_h);
}

test "axis split: measure+place matches layoutTree for non-wrap text" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    var a: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 200 }, .height = .{ .fixed = 50 } } };
    var ta: Node = textLeaf("Hello", false);
    appendChild(&a, &ta);
    measure(&a, test_font);
    place(&a, .{ .x = 0, .y = 0, .w = 200, .h = 50 });

    var b: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 200 }, .height = .{ .fixed = 50 } } };
    var tb: Node = textLeaf("Hello", false);
    appendChild(&b, &tb);
    layoutTree(&b, .{ .x = 0, .y = 0, .w = 200, .h = 50 }, test_font, arena_inst.allocator());

    try std.testing.expectEqual(a.rect, b.rect);
    try std.testing.expectEqual(ta.rect, tb.rect);
    try std.testing.expectEqual(ta.measured_w, tb.measured_w);
    try std.testing.expectEqual(ta.measured_h, tb.measured_h);
}

fn boxWH(w: i32, h: i32) Node {
    return .{ .cfg = .{ .width = .{ .fixed = w }, .height = .{ .fixed = h } } };
}

fn layoutOnce(root: *Node, w: u32, h: u32) void {
    measure(root, test_font);
    place(root, .{ .x = 0, .y = 0, .w = w, .h = h });
}

test "minmax: fixed is clamped" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 200 }, .height = .{ .fixed = 20 } } };
    var lo: Node = .{ .cfg = .{ .width = .{ .fixed = 80 }, .height = .{ .fixed = 10 }, .min_width = 90 } };
    var hi: Node = .{ .cfg = .{ .width = .{ .fixed = 80 }, .height = .{ .fixed = 10 }, .max_width = 50 } };
    appendChild(&root, &lo);
    appendChild(&root, &hi);
    layoutOnce(&root, 200, 20);
    try std.testing.expectEqual(@as(u32, 90), lo.rect.w);
    try std.testing.expectEqual(@as(u32, 50), hi.rect.w);
}

test "minmax: grow weight 0 with min_width receives min" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 } } };
    var g: Node = .{ .cfg = .{ .width = .{ .grow = 0 }, .height = .{ .fixed = 10 }, .min_width = 20 } };
    appendChild(&root, &g);
    layoutOnce(&root, 100, 10);
    try std.testing.expectEqual(@as(u32, 20), g.rect.w);
}

test "minmax: fit min floors and max clips (child overflows)" {
    {
        var root: Node = .{ .cfg = .{ .direction = .row, .min_width = 50 } };
        var a: Node = boxWH(10, 10);
        appendChild(&root, &a);
        measure(&root, test_font);
        try std.testing.expectEqual(@as(i32, 50), root.measured_w);
    }
    {
        var root: Node = .{ .cfg = .{ .direction = .row, .max_width = 20 } };
        var a: Node = boxWH(80, 10);
        appendChild(&root, &a);
        measure(&root, test_font);
        place(&root, .{ .x = 0, .y = 0, .w = @intCast(root.measured_w), .h = 10 });
        try std.testing.expectEqual(@as(i32, 20), root.measured_w);
        try std.testing.expectEqual(@as(u32, 80), a.rect.w);
    }
}

test "minmax: percent is clamped" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 } } };
    var hi: Node = .{ .cfg = .{ .width = .{ .percent = 0.8 }, .height = .{ .fixed = 10 }, .max_width = 50 } };
    var lo: Node = .{ .cfg = .{ .width = .{ .percent = 0.1 }, .height = .{ .fixed = 10 }, .min_width = 30 } };
    appendChild(&root, &hi);
    appendChild(&root, &lo);
    layoutOnce(&root, 100, 10);
    try std.testing.expectEqual(@as(u32, 50), hi.rect.w);
    try std.testing.expectEqual(@as(u32, 30), lo.rect.w);
}

test "minmax: used sums the clamped non-grow size (fixed 80 max 40 leaves 60 for grow)" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 } } };
    var f: Node = .{ .cfg = .{ .width = .{ .fixed = 80 }, .height = .{ .fixed = 10 }, .max_width = 40 } };
    var g: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &f);
    appendChild(&root, &g);
    layoutOnce(&root, 100, 10);
    try std.testing.expectEqual(@as(u32, 40), f.rect.w);
    try std.testing.expectEqual(@as(u32, 60), g.rect.w);
}

test "minmax: grow min wins over the peel" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 } } };
    var a: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 }, .min_width = 60 } };
    var b: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 }, .min_width = 60 } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    layoutOnce(&root, 100, 10);
    try std.testing.expectEqual(@as(u32, 60), a.rect.w);
    try std.testing.expectEqual(@as(u32, 60), b.rect.w);
}

test "minmax: grow max freezes and the leftover is redistributed (two freeze passes)" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 } } };
    var a: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 }, .max_width = 20 } };
    var b: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } } };
    var c: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    appendChild(&root, &c);
    layoutOnce(&root, 100, 10);
    try std.testing.expectEqual(@as(u32, 20), a.rect.w);
    try std.testing.expectEqual(@as(u32, 40), b.rect.w);
    try std.testing.expectEqual(@as(u32, 40), c.rect.w);
}

test "minmax: grow weight 0 stays 0 when min is 0" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 } } };
    var z: Node = .{ .cfg = .{ .width = .{ .grow = 0 }, .height = .{ .fixed = 10 } } };
    var g: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &z);
    appendChild(&root, &g);
    layoutOnce(&root, 100, 10);
    try std.testing.expectEqual(@as(u32, 0), z.rect.w);
    try std.testing.expectEqual(@as(u32, 100), g.rect.w);
}

test "minmax: min sum greater than remainder prefers min (parent overflows)" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 50 }, .height = .{ .fixed = 10 } } };
    var a: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 }, .min_width = 40 } };
    var b: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 }, .min_width = 40 } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    layoutOnce(&root, 50, 10);
    try std.testing.expectEqual(@as(u32, 40), a.rect.w);
    try std.testing.expectEqual(@as(u32, 40), b.rect.w);
    try std.testing.expectEqual(@as(i32, 80), b.rect.x + @as(i32, @intCast(b.rect.w)));
}

test "minmax: leftover remains when every grow child max-freezes" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 } } };
    var a: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 }, .max_width = 20 } };
    var b: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 }, .max_width = 20 } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    layoutOnce(&root, 100, 10);
    try std.testing.expectEqual(@as(u32, 20), a.rect.w);
    try std.testing.expectEqual(@as(u32, 20), b.rect.w);
    try std.testing.expectEqual(@as(i32, 40), b.rect.x + @as(i32, @intCast(b.rect.w)));
}

test "minmax: leftover remains when no positive-weight grow child exists" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 } } };
    var f: Node = boxWH(30, 10);
    var z: Node = .{ .cfg = .{ .width = .{ .grow = 0 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &f);
    appendChild(&root, &z);
    layoutOnce(&root, 100, 10);
    try std.testing.expectEqual(@as(u32, 30), f.rect.w);
    try std.testing.expectEqual(@as(u32, 0), z.rect.w);
    try std.testing.expectEqual(@as(i32, 30), z.rect.x + @as(i32, @intCast(z.rect.w)));
}

test "minmax: mix of grow=0+min, grow=0, and positive-weight grow keeps the invariants" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 } } };
    var a: Node = .{ .cfg = .{ .width = .{ .grow = 0 }, .height = .{ .fixed = 10 }, .min_width = 20 } };
    var b: Node = .{ .cfg = .{ .width = .{ .grow = 0 }, .height = .{ .fixed = 10 } } };
    var c: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    appendChild(&root, &c);
    layoutOnce(&root, 100, 10);
    try std.testing.expectEqual(@as(u32, 20), a.rect.w);
    try std.testing.expectEqual(@as(u32, 0), b.rect.w);
    try std.testing.expectEqual(@as(u32, 80), c.rect.w);
}

test "minmax: min sum greater than the parent overflows" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 30 }, .height = .{ .fixed = 10 } } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 10 }, .min_width = 25 } };
    var b: Node = .{ .cfg = .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 10 }, .min_width = 25 } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    layoutOnce(&root, 30, 10);
    try std.testing.expectEqual(@as(u32, 25), a.rect.w);
    try std.testing.expectEqual(@as(u32, 25), b.rect.w);
}

test "minmax: max equals min is a fixed size" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 } } };
    var g: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 }, .min_width = 40, .max_width = 40 } };
    appendChild(&root, &g);
    layoutOnce(&root, 100, 10);
    try std.testing.expectEqual(@as(u32, 40), g.rect.w);
}

test "minmax: unconstrained grow peel stays bit-identical (1:2 of 100)" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 200 }, .height = .{ .fixed = 50 } } };
    var f: Node = boxWH(50, 10);
    var p: Node = .{ .cfg = .{ .width = .{ .percent = 0.25 }, .height = .{ .fixed = 10 } } };
    var g1: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } } };
    var g2: Node = .{ .cfg = .{ .width = .{ .grow = 2 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &f);
    appendChild(&root, &p);
    appendChild(&root, &g1);
    appendChild(&root, &g2);
    layoutOnce(&root, 200, 50);
    try std.testing.expectEqual(@as(u32, 50), f.rect.w);
    try std.testing.expectEqual(@as(u32, 50), p.rect.w);
    try std.testing.expectEqual(@as(u32, 33), g1.rect.w);
    try std.testing.expectEqual(@as(u32, 67), g2.rect.w);
}

test "wrap: grow main uses the placed width for line breaks" {
    var screen: Node = .{ .cfg = .{ .direction = .column, .width = .{ .fixed = 80 }, .height = .{ .fixed = 200 } } };
    var root: Node = .{ .cfg = .{
        .direction = .row,
        .wrap = true,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
    } };
    var a: Node = boxWH(50, 10);
    var b: Node = boxWH(50, 10);
    appendChild(&root, &a);
    appendChild(&root, &b);
    appendChild(&screen, &root);
    layoutOnce(&screen, 80, 200);
    try std.testing.expectEqual(@as(u32, 80), root.rect.w);
    try std.testing.expectEqual(@as(i32, 0), a.rect.y);
    try std.testing.expectEqual(@as(i32, 10), b.rect.y);
}

test "wrap: exact fit stays on one line" {
    var root: Node = .{ .cfg = .{
        .direction = .row,
        .wrap = true,
        .width = .{ .fixed = 100 },
        .height = .fit,
        .gap = 20,
    } };
    var a: Node = boxWH(40, 10);
    var b: Node = boxWH(40, 10);
    appendChild(&root, &a);
    appendChild(&root, &b);
    layoutOnce(&root, 100, 50);
    try std.testing.expectEqual(@as(i32, 0), a.rect.x);
    try std.testing.expectEqual(@as(i32, 60), b.rect.x);
    try std.testing.expectEqual(@as(i32, 0), a.rect.y);
    try std.testing.expectEqual(@as(i32, 0), b.rect.y);
    try std.testing.expectEqual(@as(i32, 10), root.measured_h);
}

test "wrap: the container max_width changes the line break (fixed 100, max 50)" {
    var root: Node = .{ .cfg = .{
        .direction = .row,
        .wrap = true,
        .width = .{ .fixed = 100 },
        .max_width = 50,
        .height = .fit,
    } };
    var a: Node = boxWH(40, 10);
    var b: Node = boxWH(40, 10);
    appendChild(&root, &a);
    appendChild(&root, &b);
    layoutOnce(&root, 100, 50);
    try std.testing.expectEqual(@as(i32, 0), a.rect.x);
    try std.testing.expectEqual(@as(i32, 0), b.rect.x);
    try std.testing.expectEqual(@as(i32, 0), a.rect.y);
    try std.testing.expectEqual(@as(i32, 10), b.rect.y);
    try std.testing.expectEqual(@as(i32, 20), root.measured_h);
}

test "wrap: 1px overflow starts a new line" {
    var root: Node = .{ .cfg = .{
        .direction = .row,
        .wrap = true,
        .width = .{ .fixed = 100 },
        .height = .fit,
        .gap = 1,
    } };
    var a: Node = boxWH(50, 10);
    var b: Node = boxWH(50, 10);
    appendChild(&root, &a);
    appendChild(&root, &b);
    layoutOnce(&root, 100, 50);
    try std.testing.expectEqual(@as(i32, 0), b.rect.x);
    // cross_gap defaults to gap (1), so the second line starts at 10 + 1.
    try std.testing.expectEqual(@as(i32, 11), b.rect.y);
}

test "wrap: a single child that overflows the line stays on that line" {
    var root: Node = .{ .cfg = .{
        .direction = .row,
        .wrap = true,
        .width = .{ .fixed = 50 },
        .height = .fit,
    } };
    var a: Node = boxWH(80, 10);
    appendChild(&root, &a);
    layoutOnce(&root, 50, 50);
    try std.testing.expectEqual(@as(i32, 0), a.rect.x);
    try std.testing.expectEqual(@as(i32, 0), a.rect.y);
    try std.testing.expectEqual(@as(u32, 80), a.rect.w);
    try std.testing.expectEqual(@as(i32, 10), root.measured_h);
}

test "wrap: line cross is the max of the line" {
    var root: Node = .{ .cfg = .{
        .direction = .row,
        .wrap = true,
        .width = .{ .fixed = 100 },
        .height = .fit,
    } };
    var a: Node = boxWH(40, 10);
    var b: Node = boxWH(40, 30);
    var c: Node = boxWH(40, 20);
    appendChild(&root, &a);
    appendChild(&root, &b);
    appendChild(&root, &c);
    layoutOnce(&root, 100, 80);
    try std.testing.expectEqual(@as(i32, 0), a.rect.y);
    try std.testing.expectEqual(@as(i32, 0), b.rect.y);
    try std.testing.expectEqual(@as(i32, 30), c.rect.y);
    try std.testing.expectEqual(@as(i32, 50), root.measured_h);
}

test "wrap: align_cross center applies inside the line" {
    var root: Node = .{ .cfg = .{
        .direction = .row,
        .wrap = true,
        .width = .{ .fixed = 100 },
        .height = .fit,
        .align_cross = .center,
    } };
    var a: Node = boxWH(40, 10);
    var b: Node = boxWH(40, 30);
    appendChild(&root, &a);
    appendChild(&root, &b);
    layoutOnce(&root, 100, 80);
    try std.testing.expectEqual(@as(i32, 10), a.rect.y);
    try std.testing.expectEqual(@as(i32, 0), b.rect.y);
}

test "wrap: cross_gap defaults to gap and can be set separately" {
    {
        var root: Node = .{ .cfg = .{
            .direction = .row,
            .wrap = true,
            .width = .{ .fixed = 50 },
            .height = .fit,
            .gap = 4,
        } };
        var a: Node = boxWH(40, 10);
        var b: Node = boxWH(40, 10);
        appendChild(&root, &a);
        appendChild(&root, &b);
        measure(&root, test_font);
        try std.testing.expectEqual(@as(i32, 24), root.measured_h);
        place(&root, .{ .x = 0, .y = 0, .w = 50, .h = @intCast(root.measured_h) });
        try std.testing.expectEqual(@as(i32, 14), b.rect.y);
    }
    {
        var root: Node = .{ .cfg = .{
            .direction = .row,
            .wrap = true,
            .width = .{ .fixed = 50 },
            .height = .fit,
            .gap = 4,
            .cross_gap = 8,
        } };
        var a: Node = boxWH(40, 10);
        var b: Node = boxWH(40, 10);
        appendChild(&root, &a);
        appendChild(&root, &b);
        measure(&root, test_font);
        try std.testing.expectEqual(@as(i32, 28), root.measured_h);
        place(&root, .{ .x = 0, .y = 0, .w = 50, .h = @intCast(root.measured_h) });
        try std.testing.expectEqual(@as(i32, 18), b.rect.y);
    }
}

test "wrap: main fixed plus cross fit measures as the line sum" {
    var root: Node = .{ .cfg = .{
        .direction = .row,
        .wrap = true,
        .width = .{ .fixed = 50 },
        .height = .fit,
        .padding = .{ 2, 3, 4, 5 },
        .cross_gap = 6,
    } };
    var a: Node = boxWH(40, 10);
    var b: Node = boxWH(40, 20);
    appendChild(&root, &a);
    appendChild(&root, &b);
    measure(&root, test_font);
    // 10 + 20 + cross_gap 6 + pad 2+4 = 42
    try std.testing.expectEqual(@as(i32, 42), root.measured_h);
}

test "wrap: percent children enter at the resolved size (two 0.6 do not share a line)" {
    var root: Node = .{ .cfg = .{
        .direction = .row,
        .wrap = true,
        .width = .{ .fixed = 100 },
        .height = .fit,
    } };
    var a: Node = .{ .cfg = .{ .width = .{ .percent = 0.6 }, .height = .{ .fixed = 10 } } };
    var b: Node = .{ .cfg = .{ .width = .{ .percent = 0.6 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    layoutOnce(&root, 100, 50);
    try std.testing.expectEqual(@as(u32, 60), a.rect.w);
    try std.testing.expectEqual(@as(u32, 60), b.rect.w);
    try std.testing.expectEqual(@as(i32, 0), a.rect.y);
    try std.testing.expectEqual(@as(i32, 10), b.rect.y);
}

test "wrap: grow enters at min and is then distributed on the line" {
    var root: Node = .{ .cfg = .{
        .direction = .row,
        .wrap = true,
        .width = .{ .fixed = 100 },
        .height = .fit,
    } };
    var g1: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } } };
    var g2: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } } };
    var f: Node = boxWH(40, 10);
    appendChild(&root, &g1);
    appendChild(&root, &g2);
    appendChild(&root, &f);
    layoutOnce(&root, 100, 50);
    try std.testing.expectEqual(@as(i32, 0), g1.rect.y);
    try std.testing.expectEqual(@as(i32, 0), g2.rect.y);
    try std.testing.expectEqual(@as(i32, 0), f.rect.y);
    try std.testing.expectEqual(@as(u32, 30), g1.rect.w);
    try std.testing.expectEqual(@as(u32, 30), g2.rect.w);
    try std.testing.expectEqual(@as(u32, 40), f.rect.w);
}

test "wrap: a line of only cross-grow + min_height children has line cross equal to min" {
    var root: Node = .{ .cfg = .{
        .direction = .row,
        .wrap = true,
        .width = .{ .fixed = 50 },
        .height = .fit,
    } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 40 }, .height = .{ .grow = 1 }, .min_height = 20 } };
    var b: Node = .{ .cfg = .{ .width = .{ .fixed = 40 }, .height = .{ .grow = 1 }, .min_height = 20 } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    layoutOnce(&root, 50, 80);
    try std.testing.expectEqual(@as(u32, 20), a.rect.h);
    try std.testing.expectEqual(@as(u32, 20), b.rect.h);
    try std.testing.expectEqual(@as(i32, 20), b.rect.y);
    try std.testing.expectEqual(@as(i32, 40), root.measured_h);
}

test "wrap: cross grow fills the line, not the container; cross percent resolves against the line; a grow-only line is 0" {
    {
        var root: Node = .{ .cfg = .{
            .direction = .row,
            .wrap = true,
            .width = .{ .fixed = 100 },
            .height = .{ .fixed = 100 },
        } };
        var a: Node = boxWH(40, 20);
        var g: Node = .{ .cfg = .{ .width = .{ .fixed = 40 }, .height = .{ .grow = 1 } } };
        var c: Node = boxWH(80, 30);
        appendChild(&root, &a);
        appendChild(&root, &g);
        appendChild(&root, &c);
        layoutOnce(&root, 100, 100);
        // line 1: a + g (40+40 <= 100). line cross = 20. g fills 20, not the 100-tall container.
        try std.testing.expectEqual(@as(i32, 0), a.rect.y);
        try std.testing.expectEqual(@as(u32, 20), g.rect.h);
        try std.testing.expectEqual(@as(i32, 0), g.rect.y);
        try std.testing.expectEqual(@as(i32, 20), c.rect.y);
        try std.testing.expectEqual(@as(u32, 30), c.rect.h);
    }
    {
        var root: Node = .{ .cfg = .{
            .direction = .row,
            .wrap = true,
            .width = .{ .fixed = 100 },
            .height = .{ .fixed = 100 },
        } };
        var a: Node = boxWH(40, 40);
        var p: Node = .{ .cfg = .{ .width = .{ .fixed = 40 }, .height = .{ .percent = 0.5 } } };
        appendChild(&root, &a);
        appendChild(&root, &p);
        layoutOnce(&root, 100, 100);
        try std.testing.expectEqual(@as(u32, 20), p.rect.h);
        try std.testing.expectEqual(@as(i32, 0), p.rect.y);
    }
    {
        var root: Node = .{ .cfg = .{
            .direction = .row,
            .wrap = true,
            .width = .{ .fixed = 50 },
            .height = .fit,
        } };
        var g: Node = .{ .cfg = .{ .width = .{ .fixed = 40 }, .height = .{ .grow = 1 } } };
        appendChild(&root, &g);
        measure(&root, test_font);
        try std.testing.expectEqual(@as(i32, 0), root.measured_h);
    }
}

test "wrap: a zero-width child still occupies a line slot (no empty line)" {
    var root: Node = .{ .cfg = .{
        .direction = .row,
        .wrap = true,
        .width = .{ .fixed = 0 },
        .height = .fit,
    } };
    var a: Node = boxWH(0, 10);
    var b: Node = boxWH(40, 10);
    appendChild(&root, &a);
    appendChild(&root, &b);
    layoutOnce(&root, 0, 50);
    try std.testing.expectEqual(@as(i32, 0), a.rect.y);
    try std.testing.expectEqual(@as(i32, 10), b.rect.y);
}

test "wrap: column wrap with grow height uses the placed height for line breaks" {
    var screen: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 80 }, .height = .{ .fixed = 50 } } };
    var root: Node = .{ .cfg = .{
        .direction = .column,
        .wrap = true,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
    } };
    var a: Node = boxWH(10, 40);
    var b: Node = boxWH(20, 40);
    appendChild(&root, &a);
    appendChild(&root, &b);
    appendChild(&screen, &root);
    layoutOnce(&screen, 80, 50);
    try std.testing.expectEqual(@as(u32, 50), root.rect.h);
    try std.testing.expectEqual(@as(i32, 0), a.rect.x);
    try std.testing.expectEqual(@as(i32, 10), b.rect.x);
    try std.testing.expectEqual(@as(i32, 0), a.rect.y);
    try std.testing.expectEqual(@as(i32, 0), b.rect.y);
}

test "wrap: column direction wraps on height" {
    var root: Node = .{ .cfg = .{
        .direction = .column,
        .wrap = true,
        .width = .fit,
        .height = .{ .fixed = 50 },
    } };
    var a: Node = boxWH(10, 40);
    var b: Node = boxWH(20, 40);
    appendChild(&root, &a);
    appendChild(&root, &b);
    layoutOnce(&root, 80, 50);
    try std.testing.expectEqual(@as(i32, 0), a.rect.x);
    try std.testing.expectEqual(@as(i32, 10), b.rect.x);
    try std.testing.expectEqual(@as(i32, 0), a.rect.y);
    try std.testing.expectEqual(@as(i32, 0), b.rect.y);
    try std.testing.expectEqual(@as(i32, 30), root.measured_w);
}

test "wrap: scroll offset shifts children without changing sizes or line breaks" {
    var root: Node = .{ .cfg = .{
        .direction = .row,
        .wrap = true,
        .width = .{ .fixed = 50 },
        .height = .fit,
        .scroll_x = 5,
        .scroll_y = 7,
    } };
    var a: Node = boxWH(40, 10);
    var b: Node = boxWH(40, 10);
    appendChild(&root, &a);
    appendChild(&root, &b);
    layoutOnce(&root, 50, 50);
    try std.testing.expectEqual(@as(i32, -5), a.rect.x);
    try std.testing.expectEqual(@as(i32, -7), a.rect.y);
    try std.testing.expectEqual(@as(i32, -5), b.rect.x);
    try std.testing.expectEqual(@as(i32, 3), b.rect.y);
    try std.testing.expectEqual(@as(u32, 40), a.rect.w);
    try std.testing.expectEqual(@as(u32, 10), a.rect.h);
}

test "wrap: forbidden contracts are rejected by wrapConfigValid" {
    try std.testing.expect(wrapConfigValid(.{ .wrap = false, .width = .fit, .height = .fit }));
    try std.testing.expect(!wrapConfigValid(.{ .wrap = true, .direction = .row, .width = .fit, .height = .{ .fixed = 10 } }));
    try std.testing.expect(!wrapConfigValid(.{ .wrap = true, .direction = .row, .width = .{ .grow = 1 }, .height = .fit }));
    try std.testing.expect(!wrapConfigValid(.{ .wrap = true, .direction = .row, .width = .{ .percent = 0.5 }, .height = .fit }));
    try std.testing.expect(!wrapConfigValid(.{ .wrap = true, .direction = .column, .width = .fit, .height = .{ .grow = 1 } }));
    try std.testing.expect(wrapConfigValid(.{ .wrap = true, .direction = .row, .width = .{ .fixed = 100 }, .height = .fit }));
    try std.testing.expect(wrapConfigValid(.{ .wrap = true, .direction = .row, .width = .{ .grow = 1 }, .height = .{ .grow = 1 } }));
    try std.testing.expect(wrapConfigValid(.{ .wrap = true, .direction = .column, .width = .fit, .height = .{ .fixed = 50 } }));
}

test "extent: a wrap box reports padding plus the child envelope" {
    var root: Node = .{ .cfg = .{
        .direction = .row,
        .wrap = true,
        .width = .{ .fixed = 50 },
        .height = .fit,
        .padding = .{ 1, 2, 3, 4 },
    } };
    var a: Node = boxWH(40, 10);
    var b: Node = boxWH(40, 10);
    appendChild(&root, &a);
    appendChild(&root, &b);
    layoutOnce(&root, 50, 50);
    try std.testing.expectEqual(@as(i32, 40 + 4 + 2), root.content_w);
    try std.testing.expectEqual(@as(i32, 20 + 1 + 3), root.content_h);
}

test "extent: no children is padding only" {
    var root: Node = .{ .cfg = .{ .padding = .{ 1, 2, 3, 4 } } };
    layoutOnce(&root, 50, 50);
    try std.testing.expectEqual(@as(i32, 6), root.content_w);
    try std.testing.expectEqual(@as(i32, 4), root.content_h);
}

test "extent: a non-zero node origin still uses the content origin" {
    var root: Node = .{ .cfg = .{ .padding = .{ 5, 5, 5, 5 } } };
    var a: Node = boxWH(20, 10);
    appendChild(&root, &a);
    measure(&root, test_font);
    place(&root, .{ .x = 50, .y = 80, .w = 40, .h = 30 });
    try std.testing.expectEqual(@as(i32, 20 + 10), root.content_w);
    try std.testing.expectEqual(@as(i32, 10 + 10), root.content_h);
}

test "extent: scroll does not change the recorded extent" {
    var scrolled: Node = .{ .cfg = .{ .direction = .column, .scroll_y = 20 } };
    var a: Node = boxWH(10, 30);
    var b: Node = boxWH(10, 40);
    appendChild(&scrolled, &a);
    appendChild(&scrolled, &b);
    layoutOnce(&scrolled, 100, 50);

    var still: Node = .{ .cfg = .{ .direction = .column } };
    var c: Node = boxWH(10, 30);
    var d: Node = boxWH(10, 40);
    appendChild(&still, &c);
    appendChild(&still, &d);
    layoutOnce(&still, 100, 50);

    try std.testing.expectEqual(still.content_w, scrolled.content_w);
    try std.testing.expectEqual(still.content_h, scrolled.content_h);
    try std.testing.expectEqual(@as(i32, 70), scrolled.content_h);
}

test "extent: a negative-position child does not shrink the origin" {
    var root: Node = .{ .cfg = .{ .direction = .column, .width = .{ .fixed = 20 }, .height = .{ .fixed = 50 }, .gap = -25 } };
    var a: Node = boxWH(10, 10);
    var b: Node = boxWH(10, 10);
    appendChild(&root, &a);
    appendChild(&root, &b);
    layoutOnce(&root, 20, 50);
    try std.testing.expect(b.rect.y < 0);
    try std.testing.expect(b.rect.y + @as(i32, @intCast(b.rect.h)) < 0);
    try std.testing.expectEqual(@as(i32, 10), root.content_h);
    try std.testing.expectEqual(@as(i32, 10), root.content_w);
}

test "extent: an unclipped child's overflowing descendant is included; a clipped child is not" {
    {
        var root: Node = .{ .cfg = .{ .direction = .column, .width = .{ .fixed = 40 }, .height = .{ .fixed = 40 } } };
        var mid: Node = .{ .cfg = .{
            .direction = .column,
            .width = .{ .fixed = 20 },
            .height = .{ .fixed = 20 },
            .clip_children = false,
        } };
        var leaf: Node = boxWH(50, 10);
        appendChild(&mid, &leaf);
        appendChild(&root, &mid);
        layoutOnce(&root, 40, 40);
        try std.testing.expectEqual(@as(i32, 50), mid.content_w);
        try std.testing.expectEqual(@as(i32, 50), root.content_w);
    }
    {
        var root: Node = .{ .cfg = .{ .direction = .column, .width = .{ .fixed = 40 }, .height = .{ .fixed = 40 } } };
        var mid: Node = .{ .cfg = .{
            .direction = .column,
            .width = .{ .fixed = 20 },
            .height = .{ .fixed = 20 },
            .clip_children = true,
        } };
        var leaf: Node = boxWH(50, 10);
        appendChild(&mid, &leaf);
        appendChild(&root, &mid);
        layoutOnce(&root, 40, 40);
        try std.testing.expectEqual(@as(i32, 50), mid.content_w);
        try std.testing.expectEqual(@as(i32, 20), root.content_w);
    }
}

test "extent: a leaf does not record content extent (stays -1)" {
    var t: Node = textLeaf("Hi", false);
    layoutOnce(&t, 200, 50);
    try std.testing.expectEqual(@as(i32, -1), t.content_w);
    try std.testing.expectEqual(@as(i32, -1), t.content_h);
}
