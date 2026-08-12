// Path representation used by the outline parsers (glyf / CFF).
// The type is owned by `vector` because it is a generic f32 path, not a font
// table: font is a producer (coordinates are font units) and the coverage
// fill is a consumer. Re-exported so parsers keep a local import.

const vector = @import("vector");

pub const Vec2f = vector.Vec2f;
pub const Segment = vector.Segment;
pub const Contour = vector.Contour;
pub const Outline = vector.Outline;
pub const Builder = vector.Builder;
