// pixel/geom primitives are canonically defined in libs/font (font sits below gui).
// gui re-exports them via `@import("font")`. Impl + tests live under libs/font.
const fnt = @import("font");

pub const Rect = fnt.Rect;
pub const Vec2 = fnt.Vec2;
pub const RenderTarget = fnt.RenderTarget;
