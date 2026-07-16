//! kit.gmath: platform-independent f32 game mathematics and collision tests.
//!
//! Hot-path declaration: every public operation is inline, allocation-free,
//! and O(1). This library contains no per-pixel loop.

const vec2_module = @import("vec2.zig");
const rect_module = @import("rect.zig");
const scalar_module = @import("scalar.zig");
const collision_module = @import("collision.zig");

pub const vec2 = vec2_module;
pub const rect = rect_module;
pub const scalar = scalar_module;
pub const collision = collision_module;

pub const Vec2 = vec2_module.Vec2;
pub const add = vec2_module.add;
pub const sub = vec2_module.sub;
pub const scale = vec2_module.scale;
pub const dot = vec2_module.dot;
pub const length = vec2_module.length;
pub const normalize = vec2_module.normalize;
pub const lerpVec2 = vec2_module.lerp;

/// Unified lerp entry point: accepts either f32 scalars or Vec2 values.
/// The dedicated scalar/vec2 namespaces remain available for explicit calls.
pub inline fn lerp(a: anytype, b: @TypeOf(a), t: f32) @TypeOf(a) {
    if (comptime @TypeOf(a) == Vec2) return vec2_module.lerp(a, b, t);
    return scalar_module.lerp(a, b, t);
}
pub const smoothstep = scalar_module.smoothstep;
pub const remap = scalar_module.remap;

pub const Rect = rect_module.Rect;
pub const Circle = collision_module.Circle;
pub const Collision = collision_module.Collision;
pub const aabbVsAabb = collision_module.aabbVsAabb;
pub const circleVsCircle = collision_module.circleVsCircle;
pub const circleVsAabb = collision_module.circleVsAabb;

test {
    _ = vec2_module;
    _ = rect_module;
    _ = scalar_module;
    _ = collision_module;
}
