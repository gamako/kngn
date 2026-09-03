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
// - positioned children (`BoxConfig.position != null`) are out of flow: they take
//   no part in the parent's fit measure, main-axis cursor, gap, grow share, wrap
//   line split, or line cross size. Their containing block is always the direct
//   parent. An axis pinned by both insets takes its size from the distance
//   between them (and rejects a `.fixed` / `.percent` Sizing, which would state
//   the size a second time); otherwise the size comes from the child's own
//   Sizing, resolved against the parent content box (grow fills that box,
//   ignoring weight). min/max clamp still applies, last. They are not in the
//   layout size; a parent with clip_children=false still folds their visible
//   overflow into content extent. Draw order is tree order — later siblings
//   paint on top.
// - main-axis alignment is `BoxConfig.align_main` (CSS justify_content), limited to
//   start / center / end. It places the leftover main-axis space no child took, by shifting
//   the whole line; the gap between children never changes. A weight>0 grow child normally
//   absorbs that leftover, so align_main has no effect in a box that has one — except when
//   every such child is frozen by its own min/max clamp and a remainder is still left. In a
//   wrap box each line is aligned independently. Positioned children ignore it. Distributing
//   the leftover between children (space-between and friends) is not supported; a two-group
//   row still puts a grow box between the groups.
// - a grow / percent child box inside a fit parent measures as 0 before its own clamp, so the
//   fit parent shrinks accordingly; a positive min_* on that child still contributes, since the
//   clamp applies to computeMeasured. A leaf is the other exception: it contributes its
//   intrinsic measure whatever Sizing it declares. This holds on both axes, including
//   measureHeights.
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
const layer_types = @import("layer_types.zig");

pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const Vec2f = geom.Vec2f;
pub const LayerSpec = layer_types.LayerSpec;
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

/// One edge of a positioned box, measured inward from that edge of the parent content box.
///
/// `px` and `percent` add, so one edge expresses CSS `calc(<percentage> + <length>)`;
/// `percent` is a fraction, 1.0 meaning 100% of the parent content box on that axis.
/// Either part may be negative, which moves the box outward, past that edge.
pub const Inset = union(enum) {
    auto,
    length: struct { px: i32 = 0, percent: f32 = 0 },
};

/// Out-of-flow placement inside the parent content box (CSS `position: absolute`).
///
/// The containing block is always the direct parent: there is no search for a positioned
/// ancestor, and no way to escape the parent's box from here. Placing a subtree against
/// something further up is a different mechanism, not a wider version of this one.
///
/// Which insets are set decides the shape of the placement on each axis independently:
/// neither pins the box at the content origin, one pins it to that edge, and both pin both
/// edges and take the size from the distance between them (`Sizing` on that axis must then
/// be `.fit` or `.grow`; a `.fixed` or `.percent` size would contradict the two insets).
pub const Position = struct {
    left: Inset = .auto,
    top: Inset = .auto,
    right: Inset = .auto,
    bottom: Inset = .auto,
    /// Fraction of the box's own size subtracted after the insets resolve, the way CSS
    /// pairs `left: 50%` with `translate: -50%`: 0 puts the box's leading edge on the
    /// resolved point, 0.5 its centre, 1.0 its trailing edge. Any finite value is legal,
    /// including outside [0, 1], which overshoots on purpose. Ignored on an axis where
    /// both insets are set, because the size came from the parent rather than the box.
    pivot: Vec2f = .{},
};

/// Box border. Emit order is bg → children → border (border draws on top of children).
/// The border is drawn inside the rect and does not affect layout math.
///
/// The same type a `DrawList` box takes, so a layout box and a directly painted one
/// describe a border once. `DrawList.box` paints its border straight after the
/// background because it has no children to come between them.
pub const Border = draw_mod.Border;

pub const BoxConfig = struct {
    /// 0 = engine auto-assigns (not externally referenceable; not registered in the rect cache).
    /// Non-zero = explicit ID (caller builds via IdStack etc.). Subject to getNodeRect / hit-test
    /// caching. Must not collide within the same frame, in any build mode.
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
    /// Where the flow children sit along the main axis (CSS `justify-content`). It places
    /// the leftover main-axis space **no child took** — the space that otherwise stays as a
    /// trailing gap — by shifting the whole line: `.start` keeps it at the end, `.center`
    /// splits it, `.end` moves it in front. `gap` between children is never changed.
    ///
    /// A weight>0 `.grow` child normally absorbs that leftover, so **this has no effect in
    /// a box that has one**. It does have an effect when every such child is frozen by its
    /// own `min_*` / `max_*` clamp and a remainder is still left (min-side, max-side, or a
    /// mix), because a frozen child stops taking the remainder. A weight-0 `.grow` child
    /// never takes the remainder either. Children that overflow the parent leave no
    /// leftover, and neither does a `.fit` main axis unless `min_*` widened it.
    ///
    /// In a `wrap` box each line is aligned independently. Positioned children are placed by
    /// their own `Position` and ignore this.
    align_main: Align = .start,
    align_cross: Align = .start,
    bg: ?Color = null,
    /// Border (null = none). Emitted bg → children → border
    border: ?Border = null,
    /// Visual corner radius for this box. Does not affect measure, placement, or hit-testing.
    radius: u32 = 0,
    /// If true, bake a clip from the content box (rect minus padding) into
    /// children's draw cmds (does not affect layout math).
    clip_children: bool = false,
    /// Child placement offset for scrolling (px). Shifts final rects of children (and descendants)
    /// left by scroll_x and up by scroll_y. Does not affect child size, measured, or cursor math (placement only).
    /// Intended with clip_children to cut content outside the viewport. Caller clamps scroll_x/y to
    /// [0, content_natural - viewport] before passing.
    scroll_x: i32 = 0,
    scroll_y: i32 = 0,
    /// When set, this box is out of its parent's flow: it does not take part in the
    /// parent's fit measure, main-axis cursor, gap, grow share, wrap line split, or line
    /// cross size. Its own size is resolved against the parent content box (fixed = value,
    /// fit = measured, percent = fraction of parent content, grow = fill parent content on
    /// that axis ignoring weight), except on an axis pinned by both insets, where the two
    /// insets give the size. min/max clamp still applies. Draw order is tree order — later
    /// siblings paint on top. An explicit `id` is cached and hit-tested like any other box.
    /// Several siblings may be positioned.
    position: ?Position = null,
    /// When set, this box is not a child of the box it is written inside: it is a layer of
    /// its own, laid out as a root and placed against `LayerSpec.placement`.
    ///
    /// `position` takes a box out of its parent's flow but leaves it inside the parent's box,
    /// clip and scroll. This takes it out of the parent altogether — which is what a dropdown,
    /// a context menu or a tooltip needs, and why the two are separate fields rather than one
    /// with a mode. A box may not carry both.
    ///
    /// The pointer is borrowed only during `Context.beginBox`, which copies the specification
    /// into the frame's layer record. No later layout phase may dereference it.
    layer: ?*const LayerSpec = null,
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
    /// In-flow children. `child_count` counts everything written inside the parent, including
    /// a layer marker that never joined the chain, so the difference is the count of children
    /// that are out of flow *and still in the tree* — positioned boxes. Written in
    /// `appendChild` so measure/place never recounts.
    flow_child_count: u32 = 0,
    /// True when this node is a layer's root. Recorded once, when the marker is registered,
    /// rather than read back from `cfg` — a caller holding the node through `openBox` can
    /// change `cfg`, and a scope that opened as a layer has to close as one.
    is_layer_root: bool = false,
    /// True when at least one direct child has `cfg.position != null`.
    /// A false box takes the in-flow walk (no extra sibling scan).
    has_positioned_child: bool = false,
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

/// Give `child` a parent for the purpose of closing scopes, without joining the sibling
/// chain. A layer marker takes this instead of `appendChild`: never being in the chain is
/// what keeps it out of the parent's fit measure, cursor, gap, grow share, wrap split and
/// content extent — not a later pass that removes it again. The caller clears `parent` when
/// the marker's scope closes, so no layout walk can reach upward from a layer root.
pub fn attachDetached(parent: *Node, child: *Node) void {
    std.debug.assert(child.parent == null);
    std.debug.assert(!child.is_layer_root);
    child.parent = parent;
    child.is_layer_root = true;
    // The ordinal advances even though the chain does not. It is what auto-generated ids are
    // built from, so leaving it still would give the box written after a marker the same id
    // as the box written before it.
    parent.child_count += 1;
}

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
    if (child.cfg.position != null) {
        parent.has_positioned_child = true;
    } else {
        parent.flow_child_count += 1;
    }
}

/// Detect invalid Sizing values in debug builds (called from beginBox).
/// Whether a `Sizing` value is legal. A percent must be a finite, non-negative fraction:
/// an infinity would otherwise pass a bare `>= 0` and reach the resolve as a size.
pub fn sizingValid(s: Sizing) bool {
    return switch (s) {
        .fixed => |n| n >= 0,
        .percent => |f| std.math.isFinite(f) and f >= 0,
        else => true,
    };
}

pub fn assertSizingValid(s: Sizing) void {
    std.debug.assert(sizingValid(s));
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

/// Border-box `rect` minus `padding` (top, right, bottom, left).
/// `clip_children` clips to this box so padding (a scrollbar gutter, etc.)
/// is outside the visible child region. Zero padding leaves `rect` unchanged.
pub fn contentBox(rect: Rect, padding: [4]i32) Rect {
    const top = padding[0];
    const right = padding[1];
    const bottom = padding[2];
    const left = padding[3];
    const w: i32 = @as(i32, @intCast(rect.w)) - left - right;
    const h: i32 = @as(i32, @intCast(rect.h)) - top - bottom;
    return .{
        .x = rect.x + left,
        .y = rect.y + top,
        .w = if (w > 0) @intCast(w) else 0,
        .h = if (h > 0) @intCast(h) else 0,
    };
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
    std.debug.assert(positionConfigValid(cfg));
}

fn insetValid(inset: Inset) bool {
    return switch (inset) {
        .auto => true,
        .length => |l| std.math.isFinite(l.percent),
    };
}

/// Whether `cfg.position` is legal with the Sizing pair.
///
/// Pinning both edges of an axis states the size twice over if that axis also carries a
/// `.fixed` or `.percent` size — the insets say one thing and the size says another. Rather
/// than pick a winner silently (CSS drops one inset and moves on), that pair is rejected:
/// `.fit` and `.grow` are the sizes that mean "whatever is available", which is exactly what
/// two insets supply.
pub fn positionConfigValid(cfg: BoxConfig) bool {
    // A layer is placed against an anchor and a boundary; `position` is measured from a parent
    // content box. A box that carried both would be asking two different frames of reference
    // to decide where it goes.
    if (cfg.layer != null and cfg.position != null) return false;
    const pos = cfg.position orelse return true;
    if (!std.math.isFinite(pos.pivot.x) or !std.math.isFinite(pos.pivot.y)) return false;
    inline for (.{ pos.left, pos.top, pos.right, pos.bottom }) |inset| {
        if (!insetValid(inset)) return false;
    }
    if (pos.left != .auto and pos.right != .auto) {
        switch (cfg.width) {
            .fixed, .percent => return false,
            else => {},
        }
    }
    if (pos.top != .auto and pos.bottom != .auto) {
        switch (cfg.height) {
            .fixed, .percent => return false,
            else => {},
        }
    }
    return true;
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

fn isPositioned(node: *const Node) bool {
    return node.cfg.position != null;
}

fn firstFlowChild(node: *const Node) ?*Node {
    var it = node.first_child;
    while (it) |c| {
        if (!isPositioned(c)) return c;
        it = c.next_sibling;
    }
    return null;
}

fn firstOnLine(node: *const Node) ?*Node {
    return if (node.has_positioned_child) firstFlowChild(node) else node.first_child;
}

fn nextFlowSibling(node: *const Node) ?*Node {
    var it = node.next_sibling;
    while (it) |c| {
        if (!isPositioned(c)) return c;
        it = c.next_sibling;
    }
    return null;
}

fn nextLinePeer(node: *const Node, skip_positioned: bool) ?*Node {
    return if (skip_positioned) nextFlowSibling(node) else node.next_sibling;
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

/// floor(content x f) in f64, as an i64 so the caller decides what range the result must fit.
/// Returns null when the product leaves the i64 range, which a finite f32 can still do.
fn percentFloor(content: i32, f: f32) ?i64 {
    const product = @floor(@as(f64, @floatFromInt(content)) * @as(f64, f));
    if (!(product >= min_i64_f64 and product < max_i64_f64)) return null;
    return @intFromFloat(product);
}

/// i64's range as f64 bounds. The maximum is exclusive: 2^63 is exactly representable as an
/// f64 while `maxInt(i64)` is not, so a `<=` here would admit a product one past the range.
const min_i64_f64: f64 = -9223372036854775808.0;
const max_i64_f64: f64 = 9223372036854775808.0;

/// Percent resolve for `Sizing.percent`: floor(content × f) with no sum correction (leftover
/// px absorbed by grow). The fraction is non-negative and finite (`sizingValid`), and the
/// content it scales is a placed size, so the product is in range by construction.
fn percentOf(content: i32, f: f32) i32 {
    std.debug.assert(sizingValid(.{ .percent = f }));
    const v = percentFloor(content, f).?;
    return @intCast(v);
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
/// grow / percent children inside a fit parent measure as 0 on this axis too, before their
/// own clamp: computeMeasured clamps its raw result, so a positive min_height still contributes.
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
                if (node.has_positioned_child) {
                    while (it) |c| : (it = c.next_sibling) {
                        if (isPositioned(c)) continue;
                        sum += measuredOf(c, axis);
                    }
                } else {
                    while (it) |c| : (it = c.next_sibling) sum += measuredOf(c, axis);
                }
                break :blk sum + gapTotal(node.cfg.gap, node.flow_child_count) + pad;
            } else {
                var max_child: i32 = 0;
                var it = node.first_child;
                if (node.has_positioned_child) {
                    while (it) |c| : (it = c.next_sibling) {
                        if (isPositioned(c)) continue;
                        max_child = @max(max_child, measuredOf(c, axis));
                    }
                } else {
                    while (it) |c| : (it = c.next_sibling) max_child = @max(max_child, measuredOf(c, axis));
                }
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

fn nextLineStart(first: *Node, content_main: i32, gap: i32, main: Axis, skip_positioned: bool) ?*Node {
    var used = wrapEntrySize(first, main, content_main);
    var it = nextLinePeer(first, skip_positioned);
    while (it) |c| {
        const entry = wrapEntrySize(c, main, content_main);
        if (used + gap + entry > content_main) return c;
        used += gap + entry;
        it = nextLinePeer(c, skip_positioned);
    }
    return null;
}

fn countUntil(first: *Node, end: ?*Node, skip_positioned: bool) u32 {
    var n: u32 = 0;
    var it: ?*Node = first;
    while (it) |c| {
        if (c == end) break;
        n += 1;
        it = nextLinePeer(c, skip_positioned);
    }
    return n;
}

fn lineHasClamp(first: *Node, end: ?*Node, axis: Axis, skip_positioned: bool) bool {
    var it: ?*Node = first;
    while (it) |c| {
        if (c == end) break;
        if (hasAxisClamp(c, axis)) return true;
        it = nextLinePeer(c, skip_positioned);
    }
    return false;
}

/// Line cross size: max of (non-grow/percent children's clamped resolved size,
/// grow/percent children's min). A line of only grow/percent children with
/// min 0 has cross 0 (same idea as grow/percent measuring 0 inside a fit parent).
/// This reads the declared Sizing and takes no leaf exception, unlike computeMeasured:
/// a leaf declaring grow / percent contributes its min here, not its intrinsic size.
fn lineCrossSize(first: *Node, end: ?*Node, cross: Axis, skip_positioned: bool) i32 {
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
        it = nextLinePeer(c, skip_positioned);
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
    const skip = node.has_positioned_child;
    var first = firstOnLine(node);
    if (first == null) return pad;
    var total: i32 = 0;
    var nlines: u32 = 0;
    while (first) |f| {
        const end = nextLineStart(f, content_main, gap, main, skip);
        total += lineCrossSize(f, end, cross, skip);
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
    } else {
        placeLinearOnAxis(node, axis);
    }
    if (node.has_positioned_child) placePositionedOnAxis(node, axis);
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
        placeLineMain(
            firstOnLine(node),
            null,
            node.flow_child_count,
            content_origin - scroll,
            content_size,
            cfg.gap,
            axis,
            acc,
            node.has_positioned_child,
            cfg.align_main,
        );
        if (axis == .h) commitExtent(node, max_right, max_bottom);
    } else if (node.has_positioned_child) {
        var it = node.first_child;
        while (it) |c| : (it = c.next_sibling) {
            if (isPositioned(c)) continue;
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

/// Start-of-line offset for `align_main`, given the main-axis space no child took.
/// `.start` is the identity, and the callers pass a zero leftover for it rather
/// than working one out.
fn mainAlignOffset(align_main: Align, leftover: i32) i32 {
    return switch (align_main) {
        .start => 0,
        .center => @divFloor(leftover, 2),
        .end => leftover,
    };
}

/// Distribute leftover main-axis space among grow children on one line, then place.
///
/// Hot path: every frame on the GUI layout path. Line membership and placement
/// are O(children). Freeze reallocation is worst-case O(grow_on_line^2);
/// practical grow counts are small. Not a per-pixel loop; not RT.
///
/// `content_main` is always the parent's real content size on this axis: the
/// indefinite-main sentinel of `contentMainForPlace` reaches `placeWrapCross` only,
/// never here, so a leftover can never be the sentinel.
///
/// Invariants:
/// - weight 0 grow children take 0 of the remainder but still receive min/max
///   clamp (a grow=0, min=20 child is 20 and is frozen into used from the start).
/// - if the sum of mins exceeds the remainder, each child still gets its min
///   and the parent overflows (same as the no-shrink contract).
/// - leftover remainder stays where `align_main` puts it (by default a trailing
///   gap) when no unfrozen weight>0 grow child remains — every such child frozen
///   by its own min/max clamp, or none existed.
/// - with no clamp violations the peel is bit-identical to the unconstrained
///   accumulate-peel (the no-clamp branch is that peel).
/// - `align_main` shifts the whole line by whatever remainder is still unclaimed
///   once every child has its size. `.start` leaves the line at `cursor0`; it adds
///   one comparison and no extra walk, and skips the clamp branch's subtraction.
fn placeLineMain(
    first: ?*Node,
    end: ?*Node,
    count: u32,
    cursor0: i32,
    content_main: i32,
    gap: i32,
    axis: Axis,
    extent: ?ExtentAcc,
    skip_positioned: bool,
    align_main: Align,
) void {
    const start = first orelse return;
    if (!lineHasClamp(start, end, axis, skip_positioned)) {
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
            it = nextLinePeer(c, skip_positioned);
        }
        var remaining: i64 = @max(0, content_main - used);
        var w_rest: i64 = grow_total;
        // A weight>0 grow child takes the remainder down to zero (the last one's share is
        // the whole rest), so only a line without one leaves anything for align_main.
        const leftover: i32 = if (align_main == .start or grow_total > 0) 0 else @intCast(remaining);
        var cursor: i32 = cursor0 + mainAlignOffset(align_main, leftover);
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
            it = nextLinePeer(c, skip_positioned);
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
        it = nextLinePeer(c, skip_positioned);
    }

    // Whatever no child took, once every child has a size. Zero unless the loop below
    // runs out of unfrozen weight>0 grow children: while one is left it takes the rest.
    var leftover: i32 = 0;

    while (true) {
        var w_rest: i64 = 0;
        it = start;
        while (it) |c| {
            if (c == end) break;
            if (isUnfrozenGrow(c, axis)) w_rest += growWeightOf(c, axis);
            it = nextLinePeer(c, skip_positioned);
        }
        if (w_rest == 0) {
            // Every child's size is in `used`: non-grow and weight-0 grow from the seed
            // loop above, weight>0 grow from the freeze pass below (a child freezes once).
            if (align_main != .start) leftover = @max(0, content_main - used);
            break;
        }

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
            it = nextLinePeer(c, skip_positioned);
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
                it = nextLinePeer(c, skip_positioned);
            }
            break;
        }
    }

    var cursor: i32 = cursor0 + mainAlignOffset(align_main, leftover);
    it = start;
    while (it) |c| {
        if (c == end) break;
        const size: i32 = @intCast(rectSizeU(c, axis));
        descendPlace(c, axis, cursor, size);
        if (extent) |acc| accumulateExtent(acc.parent, c, acc.max_right, acc.max_bottom);
        cursor += size + gap;
        it = nextLinePeer(c, skip_positioned);
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
    const skip = node.has_positioned_child;
    var first = firstOnLine(node);
    while (first) |f| {
        const end = nextLineStart(f, content_main, cfg.gap, main, skip);
        const count = countUntil(f, end, skip);
        placeLineMain(f, end, count, origin - scroll, content_main, cfg.gap, main, null, skip, cfg.align_main);
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
    const skip = node.has_positioned_child;
    var first = firstOnLine(node);
    while (first) |f| {
        const end = nextLineStart(f, content_main, cfg.gap, main, skip);
        const line_cross = lineCrossSize(f, end, cross, skip);
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
            it = nextLinePeer(c, skip);
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

/// The two insets of a `Position` on one axis, leading first.
fn axisInsets(pos: Position, axis: Axis) struct { leading: Inset, trailing: Inset } {
    return switch (axis) {
        .w => .{ .leading = pos.left, .trailing = pos.right },
        .h => .{ .leading = pos.top, .trailing = pos.bottom },
    };
}

fn axisPivot(pos: Position, axis: Axis) f32 {
    return switch (axis) {
        .w => pos.pivot.x,
        .h => pos.pivot.y,
    };
}

/// Resolve one inset against the parent content size. A null result means `.auto` — the edge
/// is not pinned — which is a placement, not a failure; a value that leaves the range is the
/// failure. Keeping the two apart matters: folding an overflow into `.auto` would silently
/// place the box at the content origin instead of reporting that it cannot be placed.
fn resolveInset(inset: Inset, content: i32) PositionResolveError!?i64 {
    return switch (inset) {
        .auto => null,
        .length => |l| blk: {
            const pct = percentFloor(content, l.percent) orelse return error.OutOfDomain;
            break :blk addChecked(pct, l.px) orelse return error.OutOfDomain;
        },
    };
}

fn addChecked(a: i64, b: i64) ?i64 {
    const r = @addWithOverflow(a, b);
    return if (r[1] != 0) null else r[0];
}

fn subChecked(a: i64, b: i64) ?i64 {
    const r = @subWithOverflow(a, b);
    return if (r[1] != 0) null else r[0];
}

/// Coordinates layout produces must land inside the domain `render` accepts, so that a tree
/// which lays out cannot fail to draw. `geom` owns those bounds; they are narrower than i32.
fn coordInDomain(v: i64) bool {
    return v >= geom.MIN_COORD and v <= geom.MAX_COORD;
}

fn extentInDomain(v: i64) bool {
    return v >= 0 and v <= geom.MAX_EXTENT;
}

/// floor(size × pivot). `null` when the product leaves the i64 range.
fn pivotOffset(size: i32, pivot: f32) ?i64 {
    return percentFloor(size, pivot);
}

pub const PositionResolveError = error{OutOfDomain};

/// `resolveSize` for the positioned path, where a size that cannot be represented has to be
/// reported rather than trap. `Sizing.percent` is the only mode that can leave the range from
/// a legal config — `sizingValid` admits any finite non-negative fraction, and a large one
/// against a large parent exceeds i32 — so it is the only mode that needs the checked form.
fn resolveSizeChecked(child: *const Node, axis: Axis, content: i32) PositionResolveError!i64 {
    const raw: i64 = switch (sizingOf(child, axis)) {
        .percent => |f| percentFloor(content, f) orelse return error.OutOfDomain,
        else => resolveSize(child, axis, content, null),
    };
    const clamped = clampAxisI64(child, axis, raw);
    if (!extentInDomain(clamped)) return error.OutOfDomain;
    return clamped;
}

/// Where a positioned child sits on one axis, after the parent's scroll is applied.
pub const PositionedAxis = struct { pos: i32, size: i32 };

/// Resolve a positioned child on one axis. Pure and checked: every intermediate is computed
/// in i64 and the result is required to land in the coordinate domain, so an input that
/// cannot be placed is reported rather than wrapped or truncated.
///
/// The four inset combinations are four different placements, not one with special cases:
///
/// | leading | trailing | size                          | position                                       |
/// |---------|----------|-------------------------------|------------------------------------------------|
/// | auto    | auto     | the box's own `Sizing`        | content origin, less the pivot                  |
/// | set     | auto     | the box's own `Sizing`        | origin + leading, less the pivot                |
/// | auto    | set      | the box's own `Sizing`        | the trailing edge, less size and the pivot      |
/// | set     | set      | the gap between the two edges | origin + leading; the pivot does not apply      |
///
/// Both-set is the only case where the parent decides the size, which is why the pivot —
/// a fraction of the box's own size — has nothing to shift there.
///
/// Hot path: every frame on the GUI layout path, once per positioned child per axis.
/// Not a per-pixel loop; not RT.
fn resolvePositionedChecked(
    child: *const Node,
    axis: Axis,
    origin: i64,
    content: i64,
    scroll: i64,
) PositionResolveError!PositionedAxis {
    const pos_cfg = child.cfg.position.?;
    if (!extentInDomain(content)) return error.OutOfDomain;
    if (!coordInDomain(origin)) return error.OutOfDomain;
    const content32: i32 = @intCast(content);
    const insets = axisInsets(pos_cfg, axis);
    const leading = try resolveInset(insets.leading, content32);
    const trailing = try resolveInset(insets.trailing, content32);

    if (leading != null and trailing != null) {
        // Both edges pinned: the distance between them is the size, and the pivot has
        // nothing to shift because the size no longer comes from the box.
        const available = subChecked(subChecked(content, leading.?) orelse
            return error.OutOfDomain, trailing.?) orelse return error.OutOfDomain;
        const clamped = clampAxisI64(child, axis, available);
        if (!extentInDomain(clamped)) return error.OutOfDomain;
        const unscrolled = addChecked(origin, leading.?) orelse return error.OutOfDomain;
        const p = subChecked(unscrolled, scroll) orelse return error.OutOfDomain;
        if (!coordInDomain(p)) return error.OutOfDomain;
        if (!coordInDomain(addChecked(p, clamped) orelse return error.OutOfDomain))
            return error.OutOfDomain;
        return .{ .pos = @intCast(p), .size = @intCast(clamped) };
    }

    const size = try resolveSizeChecked(child, axis, content32);
    const pivot_off = pivotOffset(@intCast(size), axisPivot(pos_cfg, axis)) orelse
        return error.OutOfDomain;

    const base: i64 = if (leading) |l|
        addChecked(origin, l) orelse return error.OutOfDomain
    else if (trailing) |t| blk: {
        // Measured inward from the trailing edge, so the box's own size comes off too.
        const edge = addChecked(origin, content) orelse return error.OutOfDomain;
        const inner = subChecked(edge, t) orelse return error.OutOfDomain;
        break :blk subChecked(inner, size) orelse return error.OutOfDomain;
    } else origin;

    const unscrolled = subChecked(base, pivot_off) orelse return error.OutOfDomain;
    const p = subChecked(unscrolled, scroll) orelse return error.OutOfDomain;
    if (!coordInDomain(p)) return error.OutOfDomain;
    if (!coordInDomain(addChecked(p, size) orelse return error.OutOfDomain))
        return error.OutOfDomain;
    return .{ .pos = @intCast(p), .size = @intCast(size) };
}

/// `resolvePositionedChecked` for a config that `assertBoxConfigValid` has already accepted
/// and a parent whose own rect is in the coordinate domain. A failure here is a bug, not a
/// caller error, so it trips an assertion instead of propagating.
///
/// The checked form covers the child's own rect, on one axis, from the parent's content
/// origin through the insets, the size, the pivot and the scroll. It does **not** cover
/// `accumulateExtent` / `commitExtent`, which fold that rect into the parent's content extent
/// in i32 on the path every in-flow child takes as well: a parent origin at one end of the
/// coordinate domain with a child edge at the other gives a relative extent wider than
/// `geom.MAX_EXTENT`, and `scroll_x` / `scroll_y` are unvalidated i32 the fold adds directly.
/// A rect in the coordinate domain is therefore what this guarantees, and a content extent in
/// range is not.
fn resolvePositioned(
    child: *const Node,
    axis: Axis,
    origin: i64,
    content: i64,
    scroll: i64,
) PositionedAxis {
    return resolvePositionedChecked(child, axis, origin, content, scroll) catch
        @panic("layout: positioned child resolves outside the coordinate domain");
}

/// `clampAxis` in i64, for a size that has not been proven to fit i32 yet.
fn clampAxisI64(node: *const Node, axis: Axis, raw: i64) i64 {
    const lo: i64 = minOf(node, axis);
    const hi: i64 = maxOf(node, axis);
    return @min(@max(raw, lo), hi);
}

/// Place positioned children after the in-flow ones on this axis.
///
/// Hot path: every frame on the GUI layout path. O(children) per box.
/// Not a per-pixel loop; not RT.
fn placePositionedOnAxis(node: *Node, axis: Axis) void {
    const cfg = node.cfg;
    // Widened here rather than inside the resolver: the origin is the parent's own placed
    // edge plus a padding the caller supplies, and the pair can leave the domain before a
    // positioned child is even looked at.
    const content_origin: i64 = if (axis == .w)
        @as(i64, node.rect.x) + cfg.padding[3]
    else
        @as(i64, node.rect.y) + cfg.padding[0];
    // The padding pair is summed in i64 too: `axisPadding` adds two caller-supplied i32s.
    const pad: i64 = switch (axis) {
        .w => @as(i64, cfg.padding[3]) + cfg.padding[1],
        .h => @as(i64, cfg.padding[0]) + cfg.padding[2],
    };
    const content_size: i64 = @max(0, @as(i64, if (axis == .w) node.rect.w else node.rect.h) - pad);
    const scroll: i64 = if (axis == .w) cfg.scroll_x else cfg.scroll_y;
    var it = node.first_child;
    while (it) |c| : (it = c.next_sibling) {
        if (c.cfg.position == null) continue;
        const r = resolvePositioned(c, axis, content_origin, content_size, scroll);
        descendPlace(c, axis, r.pos, r.size);
    }
    if (axis == .h) foldPositionedExtent(node);
}

fn foldPositionedExtent(node: *Node) void {
    if (node.cfg.clip_children) return;
    var max_right: i32 = if (node.content_w >= 0)
        node.content_w - node.cfg.padding[3] - node.cfg.padding[1]
    else
        0;
    var max_bottom: i32 = if (node.content_h >= 0)
        node.content_h - node.cfg.padding[0] - node.cfg.padding[2]
    else
        0;
    var any = false;
    var it = node.first_child;
    while (it) |c| : (it = c.next_sibling) {
        if (!isPositioned(c)) continue;
        accumulateExtent(node, c, &max_right, &max_bottom);
        any = true;
    }
    if (any) commitExtent(node, max_right, max_bottom);
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

test "contentBox: subtracts padding; zero padding is identity" {
    const r = Rect{ .x = 10, .y = 20, .w = 100, .h = 40 };
    try std.testing.expectEqual(r, contentBox(r, .{ 0, 0, 0, 0 }));
    const inner = contentBox(r, .{ 2, 8, 4, 1 });
    try std.testing.expectEqual(@as(i32, 11), inner.x);
    try std.testing.expectEqual(@as(i32, 22), inner.y);
    try std.testing.expectEqual(@as(u32, 91), inner.w);
    try std.testing.expectEqual(@as(u32, 34), inner.h);
}

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

// ── align_main ──────────────────────────────────────────────────────────────
// `align_main` places the main-axis space no child took. The pair of tests that
// matters is "a grow child makes it inert" together with "a clamp-frozen grow
// child does not": the loose rule alone is satisfied by an implementation that
// gives up whenever any grow child is present.

test "place: align_main start/center/end shifts the whole line (fixed children, gap)" {
    inline for (.{
        .{ .alignment = Align.start, .xs = [3]i32{ 0, 40, 90 } },
        .{ .alignment = Align.center, .xs = [3]i32{ 30, 70, 120 } },
        .{ .alignment = Align.end, .xs = [3]i32{ 60, 100, 150 } },
    }) |case| {
        var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 200 }, .height = .{ .fixed = 20 }, .gap = 10, .align_main = case.alignment } };
        var a: Node = .{ .cfg = .{ .width = .{ .fixed = 30 }, .height = .{ .fixed = 20 } } };
        var b: Node = .{ .cfg = .{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } } };
        var c: Node = .{ .cfg = .{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 20 } } };
        appendChild(&root, &a);
        appendChild(&root, &b);
        appendChild(&root, &c);
        measure(&root, test_font);
        place(&root, .{ .x = 0, .y = 0, .w = 200, .h = 20 });
        // used = 30+40+50 + 2 gaps = 140, so 60 px is unclaimed.
        try std.testing.expectEqual(case.xs[0], a.rect.x);
        try std.testing.expectEqual(case.xs[1], b.rect.x);
        try std.testing.expectEqual(case.xs[2], c.rect.x);
        // The gap between children never changes, whatever the alignment.
        try std.testing.expectEqual(@as(i32, 10), b.rect.x - (a.rect.x + @as(i32, @intCast(a.rect.w))));
    }
    // `.end` puts the last child's far edge exactly on the content edge (an
    // off-by-one-gap offset would land on 190 or 210).
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 200 }, .height = .{ .fixed = 20 }, .gap = 10, .align_main = .end } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 30 }, .height = .{ .fixed = 20 } } };
    var b: Node = .{ .cfg = .{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } } };
    var c: Node = .{ .cfg = .{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 20 } } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    appendChild(&root, &c);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 200, .h = 20 });
    try std.testing.expectEqual(@as(i32, 200), c.rect.x + @as(i32, @intCast(c.rect.w)));
}

test "place: align_main center floors an odd leftover" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 105 }, .height = .{ .fixed = 10 }, .align_main = .center } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &a);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 105, .h = 10 });
    try std.testing.expectEqual(@as(i32, 2), a.rect.x); // floor(5/2)
}

test "place: align_main works on a column's main axis too" {
    var root: Node = .{ .cfg = .{ .direction = .column, .width = .{ .fixed = 20 }, .height = .{ .fixed = 200 }, .gap = 10, .align_main = .end } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 30 } } };
    var b: Node = .{ .cfg = .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 40 } } };
    var c: Node = .{ .cfg = .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 50 } } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    appendChild(&root, &c);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 20, .h = 200 });
    try std.testing.expectEqual(@as(i32, 60), a.rect.y);
    try std.testing.expectEqual(@as(i32, 100), b.rect.y);
    try std.testing.expectEqual(@as(i32, 150), c.rect.y);
}

test "place: align_main is inert when a weight>0 grow child takes the remainder" {
    var placed: [2][3]Rect = undefined;
    inline for (.{ Align.start, Align.end }, 0..) |alignment, run| {
        var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 200 }, .height = .{ .fixed = 20 }, .gap = 10, .align_main = alignment } };
        var a: Node = .{ .cfg = .{ .width = .{ .fixed = 30 }, .height = .{ .fixed = 20 } } };
        var b: Node = .{ .cfg = .{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } } };
        var g: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 20 } } };
        appendChild(&root, &a);
        appendChild(&root, &b);
        appendChild(&root, &g);
        measure(&root, test_font);
        place(&root, .{ .x = 0, .y = 0, .w = 200, .h = 20 });
        placed[run] = .{ a.rect, b.rect, g.rect };
    }
    try std.testing.expectEqual(@as(u32, 110), placed[0][2].w); // the grow child took all 110
    try std.testing.expectEqualSlices(Rect, &placed[0], &placed[1]);
}

test "place: align_main places the remainder left by max-frozen grow children" {
    inline for (.{
        .{ .alignment = Align.start, .xs = [2]i32{ 0, 50 } },
        .{ .alignment = Align.end, .xs = [2]i32{ 100, 150 } },
    }) |case| {
        var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 200 }, .height = .{ .fixed = 10 }, .align_main = case.alignment } };
        var a: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 }, .max_width = 50 } };
        var b: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 }, .max_width = 50 } };
        appendChild(&root, &a);
        appendChild(&root, &b);
        measure(&root, test_font);
        place(&root, .{ .x = 0, .y = 0, .w = 200, .h = 10 });
        try std.testing.expectEqual(@as(u32, 50), a.rect.w);
        try std.testing.expectEqual(@as(u32, 50), b.rect.w);
        try std.testing.expectEqual(case.xs[0], a.rect.x);
        try std.testing.expectEqual(case.xs[1], b.rect.x);
    }
}

test "place: align_main places the remainder when min and max freezes are mixed" {
    // a freezes at its min, b at its max: 60 + 10 = 70 of 100, so 30 is unclaimed.
    // An implementation that treats only a max freeze as an exception reports 0 here.
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 }, .align_main = .end } };
    var a: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 }, .min_width = 60 } };
    var b: Node = .{ .cfg = .{ .width = .{ .grow = 9 }, .height = .{ .fixed = 10 }, .max_width = 10 } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    try std.testing.expectEqual(@as(u32, 60), a.rect.w);
    try std.testing.expectEqual(@as(u32, 10), b.rect.w);
    try std.testing.expectEqual(@as(i32, 30), a.rect.x);
    try std.testing.expectEqual(@as(i32, 90), b.rect.x);
    try std.testing.expectEqual(@as(i32, 100), b.rect.x + @as(i32, @intCast(b.rect.w)));
}

test "place: align_main places the remainder weight-0 grow children never take (clamped)" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 }, .align_main = .end } };
    var a: Node = .{ .cfg = .{ .width = .{ .grow = 0 }, .height = .{ .fixed = 10 }, .min_width = 20 } };
    var b: Node = .{ .cfg = .{ .width = .{ .grow = 0 }, .height = .{ .fixed = 10 }, .min_width = 20 } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    try std.testing.expectEqual(@as(u32, 20), a.rect.w);
    try std.testing.expectEqual(@as(i32, 60), a.rect.x);
    try std.testing.expectEqual(@as(i32, 80), b.rect.x);
    try std.testing.expectEqual(@as(i32, 100), b.rect.x + @as(i32, @intCast(b.rect.w)));
}

test "place: align_main places the remainder weight-0 grow children never take (unclamped)" {
    // No min or max anywhere, so this goes through the no-clamp peel where
    // grow_total is 0 — the branch the clamped case above never reaches.
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 }, .align_main = .end } };
    var f: Node = .{ .cfg = .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 10 } } };
    var g: Node = .{ .cfg = .{ .width = .{ .grow = 0 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &f);
    appendChild(&root, &g);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    try std.testing.expectEqual(@as(u32, 20), f.rect.w);
    try std.testing.expectEqual(@as(i32, 80), f.rect.x);
    try std.testing.expectEqual(@as(u32, 0), g.rect.w);
    try std.testing.expectEqual(@as(i32, 100), g.rect.x);
}

test "place: align_main leaves overflowing children where they are" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 50 }, .height = .{ .fixed = 10 }, .align_main = .center } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 10 } } };
    var b: Node = .{ .cfg = .{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 50, .h = 10 });
    try std.testing.expectEqual(@as(i32, 0), a.rect.x); // never a negative offset
    try std.testing.expectEqual(@as(i32, 40), b.rect.x);
}

test "wrap: align_main aligns each line on its own leftover" {
    var root: Node = .{ .cfg = .{ .direction = .row, .wrap = true, .width = .{ .fixed = 100 }, .height = .{ .fixed = 100 }, .cross_gap = 0, .align_main = .end } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 60 }, .height = .{ .fixed = 10 } } };
    var b: Node = .{ .cfg = .{ .width = .{ .fixed = 30 }, .height = .{ .fixed = 10 } } };
    var c: Node = .{ .cfg = .{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    appendChild(&root, &c);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    // Line 1 is 60+30 = 90 (leftover 10), line 2 is 40 (leftover 60). One offset
    // for the whole container would give both lines the same shift.
    try std.testing.expectEqual(@as(i32, 10), a.rect.x);
    try std.testing.expectEqual(@as(i32, 70), b.rect.x);
    try std.testing.expectEqual(@as(i32, 60), c.rect.x);
    try std.testing.expectEqual(@as(i32, 0), a.rect.y);
    try std.testing.expectEqual(@as(i32, 10), c.rect.y);
}

test "wrap: align_main uses the real main size on a column whose main axis is indefinite" {
    // A column-wrap box splits lines against a huge sentinel while widths are being
    // placed; heights then re-split against the real 80 px. A sentinel leaking into
    // the leftover would put these children thousands of pixels down.
    var root: Node = .{ .cfg = .{ .direction = .column, .wrap = true, .width = .{ .fixed = 100 }, .height = .{ .grow = 1 }, .cross_gap = 0, .align_main = .end } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 30 } } };
    var b: Node = .{ .cfg = .{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 30 } } };
    var c: Node = .{ .cfg = .{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 30 } } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    appendChild(&root, &c);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 80 });
    // Line 1 holds two children (60 of 80, leftover 20), line 2 one (leftover 50).
    try std.testing.expectEqual(@as(i32, 20), a.rect.y);
    try std.testing.expectEqual(@as(i32, 50), b.rect.y);
    try std.testing.expectEqual(@as(i32, 50), c.rect.y);
    try std.testing.expectEqual(@as(i32, 0), a.rect.x);
    try std.testing.expectEqual(@as(i32, 40), c.rect.x);
}

test "place: align_main and align_cross are independent" {
    inline for (.{ Align.start, Align.end }) |main_alignment| {
        var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 200 }, .height = .{ .fixed = 100 }, .align_main = main_alignment, .align_cross = .center } };
        var a: Node = .{ .cfg = .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } } };
        appendChild(&root, &a);
        measure(&root, test_font);
        place(&root, .{ .x = 0, .y = 0, .w = 200, .h = 100 });
        try std.testing.expectEqual(@as(i32, 40), a.rect.y); // (100−20)/2, whatever align_main is
        try std.testing.expectEqual(@as(i32, if (main_alignment == .end) 180 else 0), a.rect.x);
    }
}

test "place: align_main counts a percent child's resolved share" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 200 }, .height = .{ .fixed = 10 }, .align_main = .end } };
    var f: Node = .{ .cfg = .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 10 } } };
    var pc: Node = .{ .cfg = .{ .width = .{ .percent = 0.25 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &f);
    appendChild(&root, &pc);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 200, .h = 10 });
    // 20 + floor(200 × 0.25) = 70 used, so 130 is left.
    try std.testing.expectEqual(@as(u32, 50), pc.rect.w);
    try std.testing.expectEqual(@as(i32, 130), f.rect.x);
    try std.testing.expectEqual(@as(i32, 150), pc.rect.x);
}

test "place: align_main accounts for a negative gap" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 }, .gap = -10, .align_main = .end } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 30 }, .height = .{ .fixed = 10 } } };
    var b: Node = .{ .cfg = .{ .width = .{ .fixed = 30 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    // 30 + 30 − 10 = 50 used, so 50 is left; b overlaps a by the negative gap.
    try std.testing.expectEqual(@as(i32, 50), a.rect.x);
    try std.testing.expectEqual(@as(i32, 70), b.rect.x);
}

test "place: align_main applies on top of scroll, not instead of it" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 }, .scroll_x = 15, .align_main = .end } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &a);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    // Aligned to 80, then shifted left by the scroll. Applying either twice moves it.
    try std.testing.expectEqual(@as(i32, 65), a.rect.x);
    // The extent is measured with the scroll added back, so it is the unscrolled value.
    try std.testing.expectEqual(@as(i32, 100), root.content_w);
}

test "place: align_main center splits the remainder in the clamp branch too" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 }, .align_main = .center } };
    var a: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 }, .max_width = 20 } };
    appendChild(&root, &a);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    try std.testing.expectEqual(@as(u32, 20), a.rect.w);
    try std.testing.expectEqual(@as(i32, 40), a.rect.x);
}

test "place: align_main handles a weight-0 grow child beside a max-frozen one" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 10 }, .align_main = .end } };
    var z: Node = .{ .cfg = .{ .width = .{ .grow = 0 }, .height = .{ .fixed = 10 }, .min_width = 10 } };
    var g: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 }, .max_width = 30 } };
    appendChild(&root, &z);
    appendChild(&root, &g);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 10 });
    // 10 (weight-0 at its min) + 30 (max-frozen) = 40 used, so 60 is left.
    try std.testing.expectEqual(@as(u32, 10), z.rect.w);
    try std.testing.expectEqual(@as(u32, 30), g.rect.w);
    try std.testing.expectEqual(@as(i32, 60), z.rect.x);
    try std.testing.expectEqual(@as(i32, 70), g.rect.x);
}

test "wrap: align_main aligns each line when the grow children freeze" {
    var root: Node = .{ .cfg = .{ .direction = .row, .wrap = true, .width = .{ .fixed = 100 }, .height = .{ .fixed = 100 }, .cross_gap = 0, .align_main = .end } };
    // Each child enters the line split at its min (40), so two fit per line; each is
    // then max-frozen at 40, leaving 20 on the full line and 60 on the last.
    var a: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 }, .min_width = 40, .max_width = 40 } };
    var b: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 }, .min_width = 40, .max_width = 40 } };
    var c: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 }, .min_width = 40, .max_width = 40 } };
    appendChild(&root, &a);
    appendChild(&root, &b);
    appendChild(&root, &c);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try std.testing.expectEqual(@as(i32, 20), a.rect.x);
    try std.testing.expectEqual(@as(i32, 60), b.rect.x);
    try std.testing.expectEqual(@as(i32, 60), c.rect.x);
    try std.testing.expectEqual(@as(i32, 0), a.rect.y);
    try std.testing.expectEqual(@as(i32, 10), c.rect.y);
}

test "place: content extent follows the children align_main moved" {
    inline for (.{
        .{ .alignment = Align.start, .x = 0, .content_w = 20 },
        .{ .alignment = Align.center, .x = 40, .content_w = 60 },
        .{ .alignment = Align.end, .x = 80, .content_w = 100 },
    }) |case| {
        var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 20 }, .align_main = case.alignment } };
        var a: Node = .{ .cfg = .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } } };
        appendChild(&root, &a);
        measure(&root, test_font);
        place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
        try std.testing.expectEqual(@as(i32, case.x), a.rect.x);
        try std.testing.expectEqual(@as(i32, case.content_w), root.content_w);
    }
}

test "place: content extent stays a border-box value with padding under align_main" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 20 }, .padding = .{ 0, 5, 0, 7 }, .align_main = .end } };
    var a: Node = .{ .cfg = .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } } };
    appendChild(&root, &a);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    // content = 100 − 12 = 88, leftover 68, so x = 7 + 68 and the extent is 88 + 12.
    try std.testing.expectEqual(@as(i32, 75), a.rect.x);
    try std.testing.expectEqual(@as(i32, 100), root.content_w);
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

fn positioned(pos: Position, w: i32, h: i32) Node {
    return .{ .cfg = .{
        .position = pos,
        .width = .{ .fixed = w },
        .height = .{ .fixed = h },
    } };
}

/// A box out of flow whose placement the test does not care about: both insets auto on
/// both axes, which pins it at the parent's content origin.
fn atOrigin(w: i32, h: i32) Node {
    return positioned(.{}, w, h);
}

const LegacyAt = enum { start, center, end };

/// The nine attachment points a box can want against its parent — each corner, each edge
/// midpoint, and the centre — written as insets. Nine placements built one way and asserted
/// against hand-computed coordinates, which is what makes the table a check on the resolver
/// rather than nine restatements of it.
///
/// Two of the three cases per axis are easy to get subtly wrong:
///
/// - `.end` is the only one whose offset changes sign. An inset is measured *inward* from its
///   edge, so "8px further right" is `right = -8`, not `right = 8`.
/// - `.center` is `50%` paired with a half-size pivot, the CSS idiom. The two terms floor
///   independently — `floor(content x 0.5) - floor(size x 0.5)` — which is not the same as
///   flooring once at the end. With content 100 and size 11 it is 45, where a single
///   `floor((content - size) / 2)` would give 44.
fn legacyPosition(h: LegacyAt, v: LegacyAt, dx: i32, dy: i32) Position {
    var p: Position = .{};
    switch (h) {
        .start => p.left = .{ .length = .{ .px = dx } },
        .center => {
            p.left = .{ .length = .{ .px = dx, .percent = 0.5 } };
            p.pivot.x = 0.5;
        },
        .end => p.right = .{ .length = .{ .px = -dx } },
    }
    switch (v) {
        .start => p.top = .{ .length = .{ .px = dy } },
        .center => {
            p.top = .{ .length = .{ .px = dy, .percent = 0.5 } };
            p.pivot.y = 0.5;
        },
        .end => p.bottom = .{ .length = .{ .px = -dy } },
    }
    return p;
}

test "appendChild: out-of-flow membership is recorded at insert" {
    var parent: Node = .{};
    var a: Node = boxWH(10, 10);
    var badge: Node = atOrigin(8, 8);
    var c: Node = boxWH(10, 10);
    appendChild(&parent, &a);
    try std.testing.expect(!parent.has_positioned_child);
    try std.testing.expectEqual(@as(u32, 1), parent.flow_child_count);
    try std.testing.expectEqual(@as(u32, 1), parent.child_count);
    appendChild(&parent, &badge);
    try std.testing.expect(parent.has_positioned_child);
    try std.testing.expectEqual(@as(u32, 1), parent.flow_child_count);
    try std.testing.expectEqual(@as(u32, 2), parent.child_count);
    appendChild(&parent, &c);
    try std.testing.expect(parent.has_positioned_child);
    try std.testing.expectEqual(@as(u32, 2), parent.flow_child_count);
    try std.testing.expectEqual(@as(u32, 3), parent.child_count);
}

test "position: a tree with none keeps the in-flow rect contract" {
    var root: Node = .{ .cfg = .{ .direction = .row, .width = .{ .fixed = 200 }, .height = .{ .fixed = 50 } } };
    var f: Node = .{ .cfg = .{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 10 } } };
    var p: Node = .{ .cfg = .{ .width = .{ .percent = 0.25 }, .height = .{ .fixed = 10 } } };
    var g1: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } } };
    var g2: Node = .{ .cfg = .{ .width = .{ .grow = 2 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &f);
    appendChild(&root, &p);
    appendChild(&root, &g1);
    appendChild(&root, &g2);
    try std.testing.expect(!root.has_positioned_child);
    try std.testing.expectEqual(root.child_count, root.flow_child_count);
    measure(&root, test_font);
    place(&root, .{ .x = 0, .y = 0, .w = 200, .h = 50 });
    try std.testing.expectEqual(@as(u32, 50), f.rect.w);
    try std.testing.expectEqual(@as(u32, 50), p.rect.w);
    try std.testing.expectEqual(@as(u32, 33), g1.rect.w);
    try std.testing.expectEqual(@as(u32, 67), g2.rect.w);
    try std.testing.expectEqual(@as(i32, 0), f.rect.x);
    try std.testing.expectEqual(@as(i32, 50), p.rect.x);
    try std.testing.expectEqual(@as(i32, 100), g1.rect.x);
    try std.testing.expectEqual(@as(i32, 133), g2.rect.x);

    var wrap_root: Node = .{ .cfg = .{
        .direction = .row,
        .wrap = true,
        .width = .{ .fixed = 50 },
        .height = .fit,
    } };
    var a: Node = boxWH(40, 10);
    var b: Node = boxWH(40, 10);
    appendChild(&wrap_root, &a);
    appendChild(&wrap_root, &b);
    try std.testing.expect(!wrap_root.has_positioned_child);
    try std.testing.expectEqual(wrap_root.child_count, wrap_root.flow_child_count);
    layoutOnce(&wrap_root, 50, 50);
    try std.testing.expectEqual(@as(i32, 0), a.rect.x);
    try std.testing.expectEqual(@as(i32, 0), a.rect.y);
    try std.testing.expectEqual(@as(i32, 0), b.rect.x);
    try std.testing.expectEqual(@as(i32, 10), b.rect.y);
    try std.testing.expectEqual(@as(u32, 40), a.rect.w);
    try std.testing.expectEqual(@as(u32, 10), a.rect.h);
}

test "position: a fit parent does not grow for a positioned child" {
    var root: Node = .{ .cfg = .{ .direction = .row } };
    var flow: Node = boxWH(10, 10);
    var badge: Node = positioned(legacyPosition(.end, .start, 0, 0), 80, 80);
    appendChild(&root, &flow);
    appendChild(&root, &badge);
    measure(&root, test_font);
    try std.testing.expectEqual(@as(i32, 10), root.measured_w);
    try std.testing.expectEqual(@as(i32, 10), root.measured_h);
}

test "position: wrap line split and line cross ignore the positioned child" {
    var with: Node = .{ .cfg = .{
        .direction = .row,
        .wrap = true,
        .width = .{ .fixed = 50 },
        .height = .fit,
    } };
    var a: Node = boxWH(40, 10);
    var badge: Node = atOrigin(40, 40);
    var b: Node = boxWH(40, 10);
    appendChild(&with, &a);
    appendChild(&with, &badge);
    appendChild(&with, &b);
    layoutOnce(&with, 50, 80);

    var plain: Node = .{ .cfg = .{
        .direction = .row,
        .wrap = true,
        .width = .{ .fixed = 50 },
        .height = .fit,
    } };
    var c: Node = boxWH(40, 10);
    var d: Node = boxWH(40, 10);
    appendChild(&plain, &c);
    appendChild(&plain, &d);
    layoutOnce(&plain, 50, 80);

    try std.testing.expectEqual(c.rect.x, a.rect.x);
    try std.testing.expectEqual(c.rect.y, a.rect.y);
    try std.testing.expectEqual(d.rect.x, b.rect.x);
    try std.testing.expectEqual(d.rect.y, b.rect.y);
    try std.testing.expectEqual(plain.measured_h, with.measured_h);
    try std.testing.expectEqual(@as(i32, 20), with.measured_h);
}

test "position: gap and grow share ignore the positioned child" {
    var root: Node = .{ .cfg = .{
        .direction = .row,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 20 },
        .gap = 10,
    } };
    var g1: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } } };
    var badge: Node = atOrigin(8, 8);
    var g2: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } } };
    appendChild(&root, &g1);
    appendChild(&root, &badge);
    appendChild(&root, &g2);
    layoutOnce(&root, 100, 20);
    try std.testing.expectEqual(@as(u32, 45), g1.rect.w);
    try std.testing.expectEqual(@as(u32, 45), g2.rect.w);
    try std.testing.expectEqual(@as(i32, 0), g1.rect.x);
    try std.testing.expectEqual(@as(i32, 55), g2.rect.x);
}

test "position: the nine legacy attachment points as insets" {
    var root: Node = .{ .cfg = .{
        .direction = .column,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 80 },
        .padding = .{ 4, 4, 4, 4 },
    } };
    var tl: Node = positioned(legacyPosition(.start, .start, 2, 3), 10, 8);
    var tc: Node = positioned(legacyPosition(.center, .start, 0, 0), 10, 8);
    // The `.end` rows carry a non-zero offset on purpose: with zero there, an inset whose
    // sign was inverted would land on the same coordinate and this table would pass.
    var tr: Node = positioned(legacyPosition(.end, .start, 5, 0), 10, 8);
    var cl: Node = positioned(legacyPosition(.start, .center, 0, 0), 10, 8);
    var c: Node = positioned(legacyPosition(.center, .center, 0, 0), 10, 8);
    var cr: Node = positioned(legacyPosition(.end, .center, 5, 0), 10, 8);
    var bl: Node = positioned(legacyPosition(.start, .end, 0, 7), 10, 8);
    var bc: Node = positioned(legacyPosition(.center, .end, 0, 7), 10, 8);
    var br: Node = positioned(legacyPosition(.end, .end, 5, 7), 10, 8);
    appendChild(&root, &tl);
    appendChild(&root, &tc);
    appendChild(&root, &tr);
    appendChild(&root, &cl);
    appendChild(&root, &c);
    appendChild(&root, &cr);
    appendChild(&root, &bl);
    appendChild(&root, &bc);
    appendChild(&root, &br);
    layoutOnce(&root, 100, 80);
    // Content box is 92 x 72 at (4, 4), so the centres are 4 + floor(92 x 0.5) - floor(10 x 0.5)
    // = 45 and 4 + floor(72 x 0.5) - floor(8 x 0.5) = 36, computed by hand. Both sizes share
    // parity with the content box here, which is the case where flooring twice and flooring
    // once agree; the test below pins one where they do not.
    const mid_x: i32 = 45;
    const mid_y: i32 = 36;
    try std.testing.expectEqual(@as(i32, 4 + 2), tl.rect.x);
    try std.testing.expectEqual(@as(i32, 4 + 3), tl.rect.y);
    try std.testing.expectEqual(mid_x, tc.rect.x);
    try std.testing.expectEqual(@as(i32, 4), tc.rect.y);
    try std.testing.expectEqual(@as(i32, 100 - 4 - 10 + 5), tr.rect.x);
    try std.testing.expectEqual(@as(i32, 4), tr.rect.y);
    try std.testing.expectEqual(@as(i32, 4), cl.rect.x);
    try std.testing.expectEqual(mid_y, cl.rect.y);
    try std.testing.expectEqual(mid_x, c.rect.x);
    try std.testing.expectEqual(mid_y, c.rect.y);
    try std.testing.expectEqual(@as(i32, 100 - 4 - 10 + 5), cr.rect.x);
    try std.testing.expectEqual(mid_y, cr.rect.y);
    try std.testing.expectEqual(@as(i32, 4), bl.rect.x);
    try std.testing.expectEqual(@as(i32, 80 - 4 - 8 + 7), bl.rect.y);
    try std.testing.expectEqual(mid_x, bc.rect.x);
    try std.testing.expectEqual(@as(i32, 80 - 4 - 8 + 7), bc.rect.y);
    try std.testing.expectEqual(@as(i32, 100 - 4 - 10 + 5), br.rect.x);
    try std.testing.expectEqual(@as(i32, 80 - 4 - 8 + 7), br.rect.y);
}

test "position: centring is 50% plus a half pivot, floored on each term" {
    // Content 100, size 11: floor(100 x 0.5) - floor(11 x 0.5) = 50 - 5 = 45. Flooring once
    // at the end instead would give 44, so pinning 45 is what makes the two-term form the
    // contract rather than an accident nobody would notice.
    var root: Node = .{ .cfg = .{
        .direction = .column,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 100 },
    } };
    var c: Node = positioned(.{
        .left = .{ .length = .{ .percent = 0.5 } },
        .top = .{ .length = .{ .percent = 0.5 } },
        .pivot = .{ .x = 0.5, .y = 0.5 },
    }, 11, 11);
    appendChild(&root, &c);
    layoutOnce(&root, 100, 100);
    try std.testing.expectEqual(@as(i32, 45), c.rect.x);
    try std.testing.expectEqual(@as(i32, 45), c.rect.y);
}

test "position: px and percent on one edge add, as CSS calc does" {
    var root: Node = .{ .cfg = .{
        .direction = .column,
        .width = .{ .fixed = 200 },
        .height = .{ .fixed = 200 },
    } };
    var a: Node = positioned(.{
        .left = .{ .length = .{ .px = 10, .percent = 0.5 } },
        .top = .{ .length = .{ .px = -10, .percent = 0.5 } },
    }, 20, 20);
    appendChild(&root, &a);
    layoutOnce(&root, 200, 200);
    try std.testing.expectEqual(@as(i32, 110), a.rect.x); // 100 + 10
    try std.testing.expectEqual(@as(i32, 90), a.rect.y); // 100 - 10
}

test "position: percent floors, and floors toward negative infinity when the fraction is negative" {
    var root: Node = .{ .cfg = .{
        .direction = .column,
        .width = .{ .fixed = 101 },
        .height = .{ .fixed = 101 },
    } };
    var a: Node = positioned(.{
        .left = .{ .length = .{ .percent = 0.5 } },
        .top = .{ .length = .{ .percent = -0.5 } },
    }, 10, 10);
    appendChild(&root, &a);
    layoutOnce(&root, 101, 101);
    try std.testing.expectEqual(@as(i32, 50), a.rect.x); // floor(101 * 0.5)
    try std.testing.expectEqual(@as(i32, -51), a.rect.y); // floor(101 * -0.5)
}

test "position: one inset per axis pins that edge, from either side" {
    var root: Node = .{ .cfg = .{
        .direction = .column,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 100 },
        .padding = .{ 5, 5, 5, 5 },
    } };
    var from_start: Node = positioned(.{
        .left = .{ .length = .{ .px = 7 } },
        .top = .{ .length = .{ .px = 3 } },
    }, 10, 10);
    var from_end: Node = positioned(.{
        .right = .{ .length = .{ .px = 7 } },
        .bottom = .{ .length = .{ .px = 3 } },
    }, 10, 10);
    appendChild(&root, &from_start);
    appendChild(&root, &from_end);
    layoutOnce(&root, 100, 100);
    try std.testing.expectEqual(@as(i32, 12), from_start.rect.x); // 5 + 7
    try std.testing.expectEqual(@as(i32, 8), from_start.rect.y); // 5 + 3
    try std.testing.expectEqual(@as(i32, 78), from_end.rect.x); // 5 + 90 - 7 - 10
    try std.testing.expectEqual(@as(i32, 82), from_end.rect.y); // 5 + 90 - 3 - 10
}

test "position: pinning both edges takes the size from the gap between them" {
    var root: Node = .{ .cfg = .{
        .direction = .column,
        .width = .{ .fixed = 200 },
        .height = .{ .fixed = 100 },
    } };
    var bar: Node = .{ .cfg = .{
        .position = .{
            .left = .{ .length = .{ .px = 12 } },
            .right = .{ .length = .{ .px = 12 } },
            .top = .{ .length = .{ .px = 0 } },
            // A pivot that would shift the box if the axis were not pinned on both sides.
            .pivot = .{ .x = 0.5, .y = 0 },
        },
        .width = .fit,
        .height = .{ .fixed = 20 },
    } };
    appendChild(&root, &bar);
    layoutOnce(&root, 200, 100);
    try std.testing.expectEqual(@as(i32, 12), bar.rect.x);
    try std.testing.expectEqual(@as(u32, 176), bar.rect.w); // 200 - 12 - 12
    try std.testing.expectEqual(@as(i32, 0), bar.rect.y);
}

test "position: both edges pinned, then clamped, keeps the leading edge and gives up the trailing one" {
    var root: Node = .{ .cfg = .{
        .direction = .column,
        .width = .{ .fixed = 200 },
        .height = .{ .fixed = 100 },
    } };
    var narrow: Node = .{ .cfg = .{
        .position = .{
            .left = .{ .length = .{ .px = 10 } },
            .right = .{ .length = .{ .px = 10 } },
        },
        .width = .{ .grow = 1 },
        .height = .{ .fixed = 10 },
        .max_width = 50,
    } };
    var wide: Node = .{ .cfg = .{
        .position = .{
            .left = .{ .length = .{ .px = 10 } },
            .right = .{ .length = .{ .px = 170 } },
        },
        .width = .{ .grow = 1 },
        .height = .{ .fixed = 10 },
        .min_width = 60,
    } };
    appendChild(&root, &narrow);
    appendChild(&root, &wide);
    layoutOnce(&root, 200, 100);
    try std.testing.expectEqual(@as(i32, 10), narrow.rect.x);
    try std.testing.expectEqual(@as(u32, 50), narrow.rect.w);
    // min wins over the available 20, and the overflow goes past the trailing edge.
    try std.testing.expectEqual(@as(i32, 10), wide.rect.x);
    try std.testing.expectEqual(@as(u32, 60), wide.rect.w);
}

test "position: a negative inset puts the box outside the parent" {
    var root: Node = .{ .cfg = .{
        .direction = .column,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 100 },
    } };
    var out: Node = positioned(.{
        .left = .{ .length = .{ .px = -5 } },
        .top = .{ .length = .{ .px = -6 } },
    }, 10, 10);
    appendChild(&root, &out);
    layoutOnce(&root, 100, 100);
    try std.testing.expectEqual(@as(i32, -5), out.rect.x);
    try std.testing.expectEqual(@as(i32, -6), out.rect.y);
}

test "position: a pivot outside [0, 1] overshoots, and is not clamped" {
    var root: Node = .{ .cfg = .{
        .direction = .column,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 100 },
    } };
    var past: Node = positioned(.{
        .left = .{ .length = .{ .px = 50 } },
        .top = .{ .length = .{ .px = 50 } },
        .pivot = .{ .x = 2.0, .y = -1.0 },
    }, 10, 10);
    appendChild(&root, &past);
    layoutOnce(&root, 100, 100);
    try std.testing.expectEqual(@as(i32, 30), past.rect.x); // 50 - floor(10 * 2)
    try std.testing.expectEqual(@as(i32, 60), past.rect.y); // 50 - floor(10 * -1)
}

test "position: grow fills the parent content box on both axes" {
    var root: Node = .{ .cfg = .{
        .direction = .column,
        .width = .{ .fixed = 80 },
        .height = .{ .fixed = 50 },
        .padding = .{ 2, 6, 4, 8 },
    } };
    var cover: Node = .{ .cfg = .{
        .position = .{},
        .width = .{ .grow = 3 },
        .height = .{ .grow = 9 },
    } };
    appendChild(&root, &cover);
    layoutOnce(&root, 80, 50);
    try std.testing.expectEqual(@as(u32, 66), cover.rect.w); // 80 - 8 - 6
    try std.testing.expectEqual(@as(u32, 44), cover.rect.h); // 50 - 2 - 4
    try std.testing.expectEqual(@as(i32, 8), cover.rect.x);
    try std.testing.expectEqual(@as(i32, 2), cover.rect.y);
}

test "position: percent size resolves against the parent content box" {
    var root: Node = .{ .cfg = .{
        .direction = .column,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 80 },
        .padding = .{ 0, 10, 0, 10 },
    } };
    var p: Node = .{ .cfg = .{
        .position = .{},
        .width = .{ .percent = 0.5 },
        .height = .{ .percent = 0.25 },
    } };
    appendChild(&root, &p);
    layoutOnce(&root, 100, 80);
    try std.testing.expectEqual(@as(u32, 40), p.rect.w); // floor(80 * 0.5)
    try std.testing.expectEqual(@as(u32, 20), p.rect.h); // floor(80 * 0.25)
}

test "position: min/max clamp applies to the resolved size" {
    var root: Node = .{ .cfg = .{
        .direction = .column,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 80 },
    } };
    var lo: Node = .{ .cfg = .{
        .position = .{},
        .width = .{ .fixed = 10 },
        .height = .{ .fixed = 10 },
        .min_width = 30,
        .min_height = 20,
    } };
    var hi: Node = .{ .cfg = .{
        .position = legacyPosition(.end, .start, 0, 0),
        .width = .{ .grow = 1 },
        .height = .{ .percent = 1.0 },
        .max_width = 40,
        .max_height = 25,
    } };
    appendChild(&root, &lo);
    appendChild(&root, &hi);
    layoutOnce(&root, 100, 80);
    try std.testing.expectEqual(@as(u32, 30), lo.rect.w);
    try std.testing.expectEqual(@as(u32, 20), lo.rect.h);
    try std.testing.expectEqual(@as(u32, 40), hi.rect.w);
    try std.testing.expectEqual(@as(u32, 25), hi.rect.h);
}

test "position: a positioned child is still measured, and its subtree still wraps" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    var root: Node = .{ .cfg = .{ .direction = .column, .width = .{ .fixed = 40 }, .height = .fit } };
    var badge: Node = .{ .cfg = .{
        .position = .{},
        .width = .{ .grow = 1 },
        .height = .fit,
        .direction = .column,
    } };
    var t: Node = textLeaf("hello world", true);
    appendChild(&badge, &t);
    appendChild(&root, &badge);
    layoutTree(&root, .{ .x = 0, .y = 0, .w = 40, .h = 80 }, test_font, arena_inst.allocator());
    try std.testing.expectEqual(@as(u32, 40), badge.rect.w);
    try std.testing.expectEqual(@as(i32, 32), t.measured_h);
    try std.testing.expectEqual(@as(usize, 2), t.lines.len);
    try std.testing.expectEqual(@as(i32, 0), root.measured_h);
}

test "position: the parent's scroll shifts a positioned child too" {
    var root: Node = .{ .cfg = .{
        .direction = .column,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 100 },
        .scroll_x = 7,
        .scroll_y = 9,
    } };
    var a: Node = positioned(.{
        .left = .{ .length = .{ .px = 20 } },
        .top = .{ .length = .{ .px = 30 } },
    }, 10, 10);
    appendChild(&root, &a);
    layoutOnce(&root, 100, 100);
    try std.testing.expectEqual(@as(i32, 13), a.rect.x); // 20 - 7
    try std.testing.expectEqual(@as(i32, 21), a.rect.y); // 30 - 9
}

test "position: clip_children=false folds overflow into extent; clip excludes it" {
    {
        var root: Node = .{ .cfg = .{
            .direction = .column,
            .width = .{ .fixed = 40 },
            .height = .{ .fixed = 40 },
            .clip_children = false,
        } };
        var flow: Node = boxWH(10, 10);
        var badge: Node = positioned(legacyPosition(.end, .start, 20, 0), 20, 10);
        appendChild(&root, &flow);
        appendChild(&root, &badge);
        layoutOnce(&root, 40, 40);
        try std.testing.expect(root.content_w > 40);
        try std.testing.expectEqual(@as(i32, 60), root.content_w); // badge right = 40-20+20+20
    }
    {
        var root: Node = .{ .cfg = .{
            .direction = .column,
            .width = .{ .fixed = 40 },
            .height = .{ .fixed = 40 },
            .clip_children = true,
        } };
        var flow: Node = boxWH(10, 10);
        var badge: Node = positioned(legacyPosition(.end, .start, 20, 0), 20, 10);
        appendChild(&root, &flow);
        appendChild(&root, &badge);
        layoutOnce(&root, 40, 40);
        try std.testing.expectEqual(@as(i32, 10), root.content_w);
        try std.testing.expectEqual(@as(i32, 10), root.content_h);
    }
}

test "positionConfigValid: pinning both edges of an axis rejects a size that states it again" {
    const both_x: Position = .{
        .left = .{ .length = .{ .px = 1 } },
        .right = .{ .length = .{ .px = 1 } },
    };
    const both_y: Position = .{
        .top = .{ .length = .{ .px = 1 } },
        .bottom = .{ .length = .{ .px = 1 } },
    };
    // The two sizes that mean "whatever is available" are the ones two insets can supply.
    try std.testing.expect(positionConfigValid(.{ .position = both_x, .width = .fit }));
    try std.testing.expect(positionConfigValid(.{ .position = both_x, .width = .{ .grow = 1 } }));
    try std.testing.expect(positionConfigValid(.{ .position = both_y, .height = .fit }));
    try std.testing.expect(positionConfigValid(.{ .position = both_y, .height = .{ .grow = 1 } }));
    // The two that state a size of their own contradict the insets.
    try std.testing.expect(!positionConfigValid(.{ .position = both_x, .width = .{ .fixed = 10 } }));
    try std.testing.expect(!positionConfigValid(.{ .position = both_x, .width = .{ .percent = 0.5 } }));
    try std.testing.expect(!positionConfigValid(.{ .position = both_y, .height = .{ .fixed = 10 } }));
    try std.testing.expect(!positionConfigValid(.{ .position = both_y, .height = .{ .percent = 0.5 } }));
    // Pinning one axis says nothing about the other.
    try std.testing.expect(positionConfigValid(.{ .position = both_x, .height = .{ .fixed = 10 } }));
    try std.testing.expect(positionConfigValid(.{ .position = both_y, .width = .{ .fixed = 10 } }));
    // A box with no position is unaffected.
    try std.testing.expect(positionConfigValid(.{ .width = .{ .fixed = 10 } }));
}

test "positionConfigValid: a non-finite percent or pivot is rejected on every edge" {
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    for ([_]f32{ nan, inf, -inf }) |bad| {
        try std.testing.expect(!positionConfigValid(.{ .position = .{ .left = .{ .length = .{ .percent = bad } } } }));
        try std.testing.expect(!positionConfigValid(.{ .position = .{ .top = .{ .length = .{ .percent = bad } } } }));
        try std.testing.expect(!positionConfigValid(.{ .position = .{ .right = .{ .length = .{ .percent = bad } } } }));
        try std.testing.expect(!positionConfigValid(.{ .position = .{ .bottom = .{ .length = .{ .percent = bad } } } }));
        try std.testing.expect(!positionConfigValid(.{ .position = .{ .pivot = .{ .x = bad } } }));
        try std.testing.expect(!positionConfigValid(.{ .position = .{ .pivot = .{ .y = bad } } }));
    }
    // A finite percent outside [0, 1] and a finite pivot outside [0, 1] are both legal.
    try std.testing.expect(positionConfigValid(.{ .position = .{
        .left = .{ .length = .{ .percent = -2.5 } },
        .pivot = .{ .x = 3.0, .y = -1.0 },
    } }));
}

test "sizingValid: a percent size must be finite and non-negative" {
    try std.testing.expect(sizingValid(.{ .percent = 0 }));
    try std.testing.expect(sizingValid(.{ .percent = 2.5 }));
    try std.testing.expect(!sizingValid(.{ .percent = -0.5 }));
    try std.testing.expect(!sizingValid(.{ .percent = std.math.nan(f32) }));
    // The bare `>= 0` this replaced let an infinity through and on into the resolve.
    try std.testing.expect(!sizingValid(.{ .percent = std.math.inf(f32) }));
    try std.testing.expect(sizingValid(.{ .fixed = 0 }));
    try std.testing.expect(!sizingValid(.{ .fixed = -1 }));
    try std.testing.expect(sizingValid(.fit));
    try std.testing.expect(sizingValid(.{ .grow = 0 }));
}

/// Independent of `resolvePositionedChecked`: the four placements written out again, in the
/// plainest form, so that a test comparing against them is comparing against the contract
/// rather than against a second copy of the implementation's own arithmetic.
fn oraclePos(
    leading: ?i64,
    trailing: ?i64,
    origin: i64,
    content: i64,
    size: i64,
    pivot: f32,
) i64 {
    const shift: i64 = @intFromFloat(@floor(@as(f64, @floatFromInt(size)) * @as(f64, pivot)));
    if (leading != null and trailing != null) return origin + leading.?;
    if (leading) |l| return origin + l - shift;
    if (trailing) |t| return origin + content - t - size - shift;
    return origin - shift;
}

test "position: the four placements match an independent oracle over a swept input space" {
    // A deterministic sweep rather than one example per branch: a case built from the one
    // input the author had in mind passes while the general claim is false.
    const contents = [_]i32{ 0, 1, 101, 200 };
    const origins = [_]i32{ 0, 37, -19 };
    const px_values = [_]i32{ 0, 7, -7 };
    const pcts = [_]f32{ 0, 0.5, -0.25 };
    const pivots = [_]f32{ 0, 0.5, 1.0, -0.5 };
    // Chosen so the pairs land on each side of the raw size (11) and on it exactly.
    const clamps = [_][2]i32{ .{ 0, std.math.maxInt(i32) }, .{ 20, 200 }, .{ 0, 5 }, .{ 11, 11 } };
    const size: i32 = 11;

    for (contents) |content| {
        for (origins) |origin| {
            for (px_values) |px| {
                for (pcts) |pct| {
                    for (pivots) |pivot| for (clamps) |clamp| {
                        const min_w = clamp[0];
                        const max_w = clamp[1];
                        const len: Inset = .{ .length = .{ .px = px, .percent = pct } };
                        // The trailing edge gets a different value from the leading one, so
                        // that a resolver reading the wrong one still lands somewhere else.
                        const len_t: Inset = .{ .length = .{ .px = px + 3, .percent = pct } };
                        const combos = [_]Position{
                            .{ .pivot = .{ .x = pivot } },
                            .{ .left = len, .pivot = .{ .x = pivot } },
                            .{ .right = len, .pivot = .{ .x = pivot } },
                            .{ .left = len, .right = len_t, .pivot = .{ .x = pivot } },
                        };
                        for (combos, 0..) |pos, i| {
                            const both = i == 3;
                            var child: Node = .{ .cfg = .{
                                .position = pos,
                                .width = if (both) .fit else .{ .fixed = size },
                                .height = .{ .fixed = size },
                                .min_width = min_w,
                                .max_width = max_w,
                            } };
                            child.measured_w = size;
                            const r = try resolvePositionedChecked(&child, .w, origin, content, 0);

                            const pct_part: i64 =
                                @intFromFloat(@floor(@as(f64, @floatFromInt(content)) * @as(f64, pct)));
                            const inset: i64 = @as(i64, px) + pct_part;
                            const inset_t: i64 = @as(i64, px) + 3 + pct_part;
                            const leading: ?i64 = if (i == 1 or both) inset else null;
                            const trailing: ?i64 = if (i == 2) inset else if (both) inset_t else null;
                            const raw_size: i64 = if (both)
                                @as(i64, content) - inset - inset_t
                            else
                                size;
                            const expect_size = @min(@max(raw_size, min_w), max_w);
                            const expect_pos = oraclePos(leading, trailing, origin, content, expect_size, pivot);

                            try std.testing.expectEqual(@as(i32, @intCast(expect_size)), r.size);
                            try std.testing.expectEqual(@as(i32, @intCast(expect_pos)), r.pos);

                            // Where both edges are pinned inward, the gap is real, and the
                            // clamp does not widen it, the box stays inside that gap. Outside
                            // that region the claim is simply false — a negative inset is a
                            // request to overflow, and a min wider than the gap is a request
                            // to exceed it — so it is not asserted there.
                            const gap = @as(i64, content) - inset - inset_t;
                            if (both and inset >= 0 and inset_t >= 0 and gap >= 0 and min_w <= gap) {
                                try std.testing.expectEqual(@as(i32, @intCast(origin + inset)), r.pos);
                                try std.testing.expect(r.pos + r.size <= origin + content);
                            }
                        }
                    };
                }
            }
        }
    }
}

test "position: a placement that leaves the coordinate domain is reported, not wrapped" {
    const huge_px: i32 = std.math.maxInt(i32);
    const cases = [_]Position{
        // A percentage large enough to throw the box out of the drawable domain.
        .{ .left = .{ .length = .{ .percent = 1e30 } } },
        // The same through the pixel term.
        .{ .left = .{ .length = .{ .px = huge_px } } },
        // And through the pivot, which scales the box's own size.
        .{ .left = .{ .length = .{} }, .pivot = .{ .x = -1e30 } },
        // Pinned on both sides, far enough apart that the size leaves the extent domain.
        .{ .left = .{ .length = .{ .px = -huge_px } }, .right = .{ .length = .{ .px = -huge_px } } },
    };
    for (cases, 0..) |pos, i| {
        const both = i == 3;
        var child: Node = .{ .cfg = .{
            .position = pos,
            .width = if (both) .fit else .{ .fixed = 10 },
            .height = .{ .fixed = 10 },
        } };
        child.measured_w = 10;
        try std.testing.expectError(
            error.OutOfDomain,
            resolvePositionedChecked(&child, .w, 0, 100, 0),
        );
    }

    // The size itself, not the insets. `sizingValid` admits any finite non-negative fraction,
    // so a large one against a large parent leaves i32 while still being a legal config.
    for ([_]f32{ 1e7, 1e30 }) |pct| {
        var big: Node = .{ .cfg = .{
            .position = .{ .left = .{ .length = .{} } },
            .width = .{ .percent = pct },
            .height = .{ .fixed = 10 },
        } };
        try std.testing.expectError(
            error.OutOfDomain,
            resolvePositionedChecked(&big, .w, 0, 1000, 0),
        );
    }

    // A pivot at the far edge of what f64 can multiply out. 2^63 is exactly representable
    // as an f64 while maxInt(i64) is not, so an inclusive bound here would let it through.
    var pivot_edge: Node = .{ .cfg = .{
        .position = .{ .left = .{ .length = .{} }, .pivot = .{ .x = 9223372036854775808.0 } },
        .width = .{ .fixed = 1 },
        .height = .{ .fixed = 1 },
    } };
    try std.testing.expectError(
        error.OutOfDomain,
        resolvePositionedChecked(&pivot_edge, .w, 0, 100, 0),
    );

    // Scroll is applied inside the checked path, so a scroll that throws the box out of the
    // domain is reported rather than wrapping around.
    var scrolled: Node = .{ .cfg = .{
        .position = .{ .left = .{ .length = .{} } },
        .width = .{ .fixed = 10 },
        .height = .{ .fixed = 10 },
    } };
    try std.testing.expectError(
        error.OutOfDomain,
        resolvePositionedChecked(&scrolled, .w, 0, 100, std.math.maxInt(i32)),
    );
}

test "position: a placement at the edge of the coordinate domain still resolves" {
    var child: Node = .{ .cfg = .{
        .position = .{ .left = .{ .length = .{ .px = geom.MAX_COORD - 10 } } },
        .width = .{ .fixed = 10 },
        .height = .{ .fixed = 10 },
    } };
    const r = try resolvePositionedChecked(&child, .w, 0, 100, 0);
    try std.testing.expectEqual(@as(i32, geom.MAX_COORD - 10), r.pos);
    try std.testing.expectEqual(@as(i32, 10), r.size);
}

test "BoxConfig: radius defaults to zero" {
    const cfg: BoxConfig = .{};
    try std.testing.expectEqual(@as(u32, 0), cfg.radius);
}
