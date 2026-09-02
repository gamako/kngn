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
