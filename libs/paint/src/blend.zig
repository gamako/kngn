//! Straight-alpha src-over blend (thin facade over libs/pixelops).
//! canonical BGRA(0xAARRGGBB), non-premultiplied.
//!
//! Keeps core's blend surface (srcOver/overWhite/scaleAlpha) while the body is a thin facade
//! that delegates to shared `pixelops`. Bit behavior is identical (detailed tests live
//! in libs/pixelops/src/lib.zig).

const std = @import("std");
const pixelops = @import("pixelops");

/// src OVER dst (**argument order: dst first, src second**). Straight-alpha src-over, canonical BGRA(0xAARRGGBB).
pub const srcOver = pixelops.srcOver;

/// Opaque color from src-over of src onto an opaque white background (for composite display).
pub const overWhite = pixelops.overWhite;

/// Multiply color alpha by coverage(0..255) (RGB unchanged; a' = (a*cov+127)/255).
pub const scaleAlpha = pixelops.scaleAlpha;

/// Straight src-over treating dst as opaque (no division; out_a fixed at 255).
/// Bit-identical to srcOver when dst is opaque (pinned by exhaustive tests on the pixelops side).
pub const srcOverOpaque = pixelops.srcOverOpaque;

// ============================================================
// Tests (facade re-export smoke only; blend itself is tested in pixelops)
// ============================================================

test "facade: srcOver/overWhite/scaleAlpha delegate to pixelops" {
    const dst: u32 = 0xFF112233;
    try std.testing.expectEqual(dst, srcOver(dst, 0x00AABBCC)); // a=0 → dst
    try std.testing.expectEqual(@as(u32, 0xFFAABBCC), srcOver(dst, 0xFFAABBCC)); // a=255 → src
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), overWhite(0xFF0000FF));
    try std.testing.expectEqual(@as(u32, 0x000000FF), scaleAlpha(0xFF0000FF, 0));
}
