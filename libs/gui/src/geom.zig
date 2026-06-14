// pixel/geom プリミティブは libs/font が正準定義する（font は gui より下層）。
// gui からは `@import("font")` 経由で再エクスポートする。実体・テストは libs/font 側。
const fnt = @import("font");

pub const Rect = fnt.Rect;
pub const Vec2 = fnt.Vec2;
pub const RenderTarget = fnt.RenderTarget;
