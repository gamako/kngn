// Deterministic scalar tweens and color interpolation for GUI state transitions.

const std = @import("std");
const color_mod = @import("color.zig");

pub const Color = color_mod.Color;

/// Fixed rational approximation of exp(-dt/tau) for UI transitions.
/// The function uses only strict f32 arithmetic and has no clock or libm dependency.
pub fn decay(dt_s: f32, tau_s: f32) f32 {
    @setFloatMode(.strict);
    if (dt_s <= 0) return 1.0;
    if (tau_s <= 0) return 0.0;

    const x: f32 = dt_s / tau_s;
    if (x >= 4.0) return 0.0;

    const x2: f32 = x * x;
    const x3: f32 = x2 * x;
    const x4: f32 = x3 * x;
    const x5: f32 = x4 * x;
    const x6: f32 = x5 * x;
    const x7: f32 = x6 * x;
    const x8: f32 = x7 * x;

    var denominator: f32 = 1.0 + x;
    denominator = denominator + x2 / 2.0;
    denominator = denominator + x3 / 6.0;
    denominator = denominator + x4 / 24.0;
    denominator = denominator + x5 / 120.0;
    denominator = denominator + x6 / 720.0;
    denominator = denominator + x7 / 5040.0;
    denominator = denominator + x8 / 40320.0;
    return 1.0 / denominator;
}

pub const TweenState = struct {
    value: f32 = 0,
    target: f32 = 0,
    last_s: f32 = 0,
    initialized: bool = false,

    pub const settle_epsilon: f32 = 0.0005;

    /// Advance toward `target` using Context's deterministic frame time.
    pub fn update(self: *TweenState, target: f32, now_s: f64, tau_s: f32) f32 {
        @setFloatMode(.strict);
        self.target = target;
        const now: f32 = @floatCast(now_s);
        if (!self.initialized) {
            self.initialized = true;
            self.last_s = now;
            if (tau_s <= 0) self.value = target;
            return self.value;
        }

        const dt: f32 = now - self.last_s;
        self.last_s = now;
        if (tau_s <= 0) {
            self.value = target;
            return self.value;
        }
        if (dt <= 0) return self.value;

        const factor = decay(dt, tau_s);
        if (factor == 0) {
            self.value = target;
            return self.value;
        }

        const difference: f32 = self.value - target;
        const next: f32 = target + difference * factor;
        const error_value: f32 = next - target;
        self.value = if (error_value <= settle_epsilon and error_value >= -settle_epsilon) target else next;
        return self.value;
    }

    pub fn isSettled(self: *const TweenState) bool {
        const error_value: f32 = self.value - self.target;
        return error_value <= settle_epsilon and error_value >= -settle_epsilon;
    }
};

pub const AnimationState = struct {
    hover: TweenState = .{},
    press: TweenState = .{},
};

/// Interpolate straight-alpha colors with truncation as the fixed channel rounding rule.
pub fn mixColor(from: Color, to: Color, amount: f32) Color {
    @setFloatMode(.strict);
    if (amount <= 0) return from;
    if (amount >= 1) return to;
    return Color.rgba(
        mixChannel(from.r, to.r, amount),
        mixChannel(from.g, to.g, amount),
        mixChannel(from.b, to.b, amount),
        mixChannel(from.a, to.a, amount),
    );
}

fn mixChannel(from: u8, to: u8, amount: f32) u8 {
    @setFloatMode(.strict);
    const from_f: f32 = @floatFromInt(from);
    const to_f: f32 = @floatFromInt(to);
    const delta: f32 = to_f - from_f;
    const value: f32 = from_f + delta * amount;
    return @intFromFloat(value);
}

test "decay is bounded and monotone over its finite range" {
    var previous: f32 = decay(0, 0.1);
    try std.testing.expectEqual(@as(f32, 1), previous);
    var i: usize = 1;
    while (i <= 16) : (i += 1) {
        const current = decay(@as(f32, @floatFromInt(i)) / 4.0, 0.1);
        try std.testing.expect(current <= previous);
        try std.testing.expect(current >= 0 and current <= 1);
        previous = current;
    }
    try std.testing.expectEqual(@as(f32, 0), decay(4, 1));
}

test "decay handles non-positive and oversized inputs deterministically" {
    try std.testing.expectEqual(@as(f32, 1), decay(-1, 0.1));
    try std.testing.expectEqual(@as(f32, 1), decay(0, 0.1));
    try std.testing.expectEqual(@as(f32, 0), decay(0.1, 0));
    try std.testing.expectEqual(@as(f32, 0), decay(0.1, -1));
    try std.testing.expectEqual(@as(f32, 0), decay(100, 0.1));
}

test "TweenState uses the same f32 bit sequence for the same time sequence" {
    const times = [_]f64{ 0, 0.016, 0.032, 0.064, 0.128, 0.256, 0.5 };
    var left: TweenState = .{};
    var right: TweenState = .{};
    for (times) |time| {
        _ = left.update(1, time, 0.1);
        _ = right.update(1, time, 0.1);
        try std.testing.expectEqual(@as(u32, @bitCast(left.value)), @as(u32, @bitCast(right.value)));
    }
}

test "TweenState keeps endpoints and handles a backwards clock" {
    var tween: TweenState = .{};
    try std.testing.expectEqual(@as(f32, 0), tween.update(1, 10, 0.1));
    try std.testing.expectEqual(@as(f32, 0), tween.update(1, 9, 0.1));
    try std.testing.expect(tween.update(1, 9.1, 0.1) > 0);
    try std.testing.expectEqual(@as(f32, 1), tween.update(1, 13.2, 0.1));

    var immediate: TweenState = .{};
    try std.testing.expectEqual(@as(f32, 1), immediate.update(1, 0, 0));
    try std.testing.expectEqual(@as(f32, 1), immediate.update(1, 1, 0));
}

test "mixColor has fixed channel rounding and exact endpoints" {
    const from = Color.rgba(0, 10, 200, 255);
    const to = Color.rgba(255, 110, 0, 0);
    try std.testing.expectEqual(from, mixColor(from, to, 0));
    try std.testing.expectEqual(to, mixColor(from, to, 1));
    const middle = mixColor(from, to, 0.5);
    try std.testing.expectEqual(@as(u8, 127), middle.r);
    try std.testing.expectEqual(@as(u8, 60), middle.g);
    try std.testing.expectEqual(@as(u8, 100), middle.b);
    try std.testing.expectEqual(@as(u8, 127), middle.a);
}
