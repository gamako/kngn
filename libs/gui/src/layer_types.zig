//! Types for layers: subtrees that leave their parent's box and are placed against something
//! else on the screen.
//!
//! A dropdown under a button, a context menu at the cursor, a tooltip beside what it explains
//! — none of these is a child of the box it belongs to. Their size is not the parent's
//! business, the parent's clip must not cut them, and the parent's scroll must not carry them
//! away. Every toolkit that has faced this arrives at the same shape: a separate root, placed
//! against an anchor. `BoxConfig.position` covers the other case, a box out of its parent's
//! flow but still inside its box; a layer is the one that leaves.
//!
//! These types live in their own file because `BoxConfig` names one of them and `Context`
//! owns the rest. A home in either would make the other import it.
//!
//! Hot path: types only. Nothing here runs.

const std = @import("std");
const geom = @import("geom.zig");

pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const Id = @import("id.zig").Id;

/// The name of a layer slot: what `openLayer` opens and `closeLayer` closes.
///
/// Distinct from `Id`, which names a widget's box for the rect cache, focus and input. The
/// two may hold the same number and mean different things, so this is a struct rather than
/// an alias — `Id` is `u64`, and an alias would be the same type to the compiler and catch
/// nothing.
pub const LayerKey = struct {
    value: u64,

    pub fn eql(a: LayerKey, b: LayerKey) bool {
        return a.value == b.value;
    }
};

/// What a layer is placed against.
pub const AnchorSource = union(enum) {
    /// A point in screen coordinates. A context menu at the cursor is this.
    point: Vec2,
    /// A box elsewhere in this frame, by explicit id. A dropdown under its button is this.
    /// The box may be in the main tree or in another layer; the id is resolved against this
    /// frame's geometry, not the previous frame's, so a layer never draws at a coordinate
    /// its anchor has already left.
    id: Id,
};

/// Which side of the anchor the layer sits on.
pub const Side = enum { below, above, right_of, left_of };

/// Where the layer lines up along the anchor's other axis.
pub const CrossAlign = enum { start, center, end };

/// Whether a layer that does not fit on its preferred side may move to the opposite one.
///
/// This is the half of placement that insets cannot express. `left`/`top` say where to put
/// something; they have nowhere to say what to do when it does not fit. Every toolkit that
/// places menus has a rule for it, which is a large part of why placing a layer is not the
/// same problem as positioning a box.
pub const FlipPolicy = enum { none, main_axis };

/// Whether a layer that runs past the boundary may be pushed back inside it.
pub const ShiftPolicy = enum { none, both_axes };

/// How a layer's root is placed. The `Sizing` on the root says how big it wants to be; this
/// says where that goes.
pub const LayerPlacement = struct {
    source: AnchorSource,
    side: Side = .below,
    cross: CrossAlign = .start,
    /// Added after the side and cross alignment resolve. Integer, like every other coordinate
    /// the layout engine produces, so there is no rounding rule to get wrong.
    offset: Vec2 = .{ .x = 0, .y = 0 },
    flip: FlipPolicy = .main_axis,
    shift: ShiftPolicy = .both_axes,
};

/// The marker a box carries to say it is a layer rather than a child.
pub const LayerSpec = struct {
    key: LayerKey,
    /// Draw order between layers. Higher is nearer the viewer; ties break on registration
    /// order, the same rule siblings already follow.
    z: i32 = 0,
    placement: LayerPlacement,
    /// Whether this layer's boxes join the rect cache, and so the one explicit-id namespace,
    /// and so what an `.id` anchor can point at. A layer that is only ever looked at — a
    /// tooltip — says false and stays out of all three.
    cache: bool = true,
};

test "LayerKey is not interchangeable with Id" {
    // Both are 64-bit names, and the point of the struct is that the compiler knows they are
    // not the same name. If this ever becomes an alias, the two spaces silently merge.
    try std.testing.expect(@TypeOf(LayerKey{ .value = 1 }) != Id);
}

test "placement defaults are the dropdown case" {
    // The common placement should be the one you get by naming only the anchor: under the
    // button, left edges aligned, flipping up when the bottom of the screen is close.
    const p: LayerPlacement = .{ .source = .{ .id = 7 } };
    try std.testing.expectEqual(Side.below, p.side);
    try std.testing.expectEqual(CrossAlign.start, p.cross);
    try std.testing.expectEqual(FlipPolicy.main_axis, p.flip);
    try std.testing.expectEqual(ShiftPolicy.both_axes, p.shift);
}
