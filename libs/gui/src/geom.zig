// Integer pixel/geom primitives are canonically defined in libs/font (font sits below gui).
// gui re-exports them via `@import("font")`. Impl + tests live under libs/font.
// The float pair below is gui's own: font has no equivalent (`libs/font`'s outline module
// re-exports `vector.Vec2f`, which is an outline control point, a different concept).
const fnt = @import("font");

pub const Rect = fnt.Rect;
pub const Vec2 = fnt.Vec2;
pub const RenderTarget = fnt.RenderTarget;

/// Float pair. One type for every sub-pixel quantity gui carries: scroll deltas, path
/// points, and the fraction of its own size a positioned box is shifted by. Having a
/// single definition is what lets a value cross between those uses without a conversion.
pub const Vec2f = struct { x: f32 = 0, y: f32 = 0 };

/// Inclusive logical coordinate range a DrawCmd may carry when `render`
/// physicalizes it (`scale != 1.0`). 2^20 is larger than any window we present
/// (8K is 7680).
pub const MAX_COORD: i32 = 1 << 20;
pub const MIN_COORD: i32 = -(1 << 20);

/// Maximum `w` / `h` / `clip_w` / `clip_h`. Same 2^20 bound as `MAX_COORD` so
/// `x + w` stays inside i32 when `x` is also in range.
pub const MAX_EXTENT: u32 = 1 << 20;

/// Maximum stroke / outline thickness. 4096 px is already a filled slab, not a
/// stroke. Together with `MAX_COORD`, `coord + thickness + thickness / 2` stays
/// inside i32 before scale is applied.
pub const MAX_THICKNESS: u32 = 4096;

/// Rounds a caller-owned scroll amount into an `i32` the conversion can represent.
///
/// Unconditional, and lossless for every amount a scroll can legitimately hold: the
/// upper bound is the largest `f32` that converts into `i32`, so no reachable value is
/// clipped. It exists because `@intFromFloat` is undefined for a value outside the
/// destination range or for a non-finite one, and a scroll amount belongs to the
/// caller, so `+inf` or a huge magnitude can arrive here. Clamping against zero also
/// maps NaN to zero, because `@max` returns the operand that is not NaN.
///
/// What upper bound a scroll amount is *allowed* to hold is a separate question about
/// the scroll input domain; this only makes the conversion defined.
pub fn scrollOffsetToLayout(v: f32) i32 {
    // 2^31 - 128 is the largest f32 below 2^31, hence the largest one an i32 can hold:
    // f32 steps by 128 in this range, so the next value up is exactly 2^31.
    const max_representable: f32 = 2147483520.0;
    return @intFromFloat(@round(@min(@max(v, 0), max_representable)));
}

/// Same conversion, for an amount no clamp has settled: a scroll area's first frame, or
/// the frame it becomes visible again, where the range it would be clamped against does
/// not exist yet.
///
/// Such an amount is additionally held inside `MAX_COORD`, because a placement offset
/// reaches draw commands and `render` rejects one outside the coordinate domain before
/// any clip would cut it. Nothing real is lost: on that frame the amount is a one-frame
/// guess. This bounds one area's own offset; what nested areas accumulate between them is
/// a question about the scroll input domain, which this does not answer.
///
/// Where the amount *has* been settled, use `scrollOffsetToLayout`: `MAX_COORD` bounds a
/// draw command's coordinates, not how far a caller may scroll, and a fixed size or a
/// virtual list's total height may legitimately exceed it.
pub fn unsettledScrollOffsetToLayout(v: f32) i32 {
    return scrollOffsetToLayout(@min(v, @as(f32, @floatFromInt(MAX_COORD))));
}

test "scrollOffsetToLayout: every f32 a caller can hold converts" {
    const std = @import("std");
    // The integrated cases that reach this with an out-of-range value are hard to build:
    // a range near the i32 maximum needs a box that tall, whose own placement arithmetic
    // overflows first. The contract belongs to this function, so it is stated here.
    try std.testing.expectEqual(@as(i32, 2147483520), scrollOffsetToLayout(std.math.inf(f32)));
    try std.testing.expectEqual(@as(i32, 2147483520), scrollOffsetToLayout(1e30));
    // A range read out of an i32 maximum rounds *up* through f32, past what i32 holds.
    try std.testing.expectEqual(@as(i32, 2147483520), scrollOffsetToLayout(@floatFromInt(std.math.maxInt(i32))));
    try std.testing.expectEqual(@as(i32, 0), scrollOffsetToLayout(-std.math.inf(f32)));
    try std.testing.expectEqual(@as(i32, 0), scrollOffsetToLayout(std.math.nan(f32)));
    try std.testing.expectEqual(@as(i32, 0), scrollOffsetToLayout(-50));
    // Everything a scroll legitimately holds passes through, rounded.
    try std.testing.expectEqual(@as(i32, 100), scrollOffsetToLayout(100.4));
    try std.testing.expectEqual(@as(i32, 101), scrollOffsetToLayout(100.6));
    try std.testing.expectEqual(@as(i32, 400_000), scrollOffsetToLayout(400_000));
    try std.testing.expectEqual(@as(i32, 2_000_000), scrollOffsetToLayout(2_000_000));
}
