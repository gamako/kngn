/// Fixed timestep helper
///
/// Time manager that runs logical updates (physics, game logic) at a fixed rate.
/// Guarantees stable logical behavior even when the frame rate varies.
///
/// Design intent:
/// - Separate render rate from logical update rate for a stable simulation
/// - Fast rendering uses interpolation for smooth display; under load, step capping prevents collapse
/// - max_steps (default 5) prevents the spiral of death (updates fall behind and delay grows without bound)
///
/// Relation to frame strategies:
///
/// 1. Variable timestep (use delta time directly)
///    - Compute with each frame's delta time
///    - Simple, but behavior depends on frame rate
///    - This helper is not needed
///
/// 2. Fixed timestep (synced with rendering)
///    - Render and logical update share a rate (e.g. both 60Hz + VSync)
///    - Stable behavior; alpha interpolation is unnecessary
///    - Use this helper (alpha() is not needed)
///
/// 3. Fixed timestep (async from rendering) ← primary use of this helper
///    - Render and logical update differ in rate, or frame rate is unstable
///    - Alpha interpolation for smooth drawing (up to 1 dt of latency)
///    - Use this helper + alpha()
///
/// Reference: https://gafferongames.com/post/fix_your_timestep/
pub const FixedTimeStep = struct {
    accumulator: f64 = 0.0, // Public: callers may mutate
    dt: f64, // Logical update interval (seconds)
    max_steps: usize = 5, // Spiral-of-death guard

    pub fn init(update_rate: f64) FixedTimeStep {
        return .{ .dt = 1.0 / update_rate };
    }

    /// Add frame time and return how many logical updates should run
    pub fn update(self: *FixedTimeStep, frame_time: f64) usize {
        self.accumulator += frame_time;
        var steps: usize = @intFromFloat(self.accumulator / self.dt);

        if (steps > self.max_steps) {
            steps = self.max_steps;
        }

        self.accumulator -= @as(f64, @floatFromInt(steps)) * self.dt;
        return steps;
    }

    /// Get the interpolation factor (0.0..1.0)
    ///
    /// Purpose: smooth rendering
    /// Logical-update timing and draw timing diverge, so
    /// interpolate the previous two logical states (prev, current) for the draw position.
    ///
    /// Trade-off:
    /// Interpolation delays the draw position by at most one logical update (dt) behind real time.
    /// At 60Hz that is about 16.7ms max. Usually fine, but
    /// consider it when low latency is required (e.g. fighting games).
    ///
    /// Interpolation is optional:
    /// To avoid that latency, skip interpolation and draw the latest logical position as-is.
    /// If logical updates are 60Hz or higher, no interpolation is usually smooth enough.
    ///
    /// Example:
    ///   // prev_x: state saved before update()
    ///   // current_x: latest state after update()
    ///   const alpha = timestep.alpha();
    ///   const draw_x = prev_x + (current_x - prev_x) * alpha;
    pub fn alpha(self: *const FixedTimeStep) f64 {
        return self.accumulator / self.dt;
    }

    /// Reset the accumulator (e.g. scene change, unpause)
    pub fn reset(self: *FixedTimeStep) void {
        self.accumulator = 0.0;
    }
};

test "FixedTimeStep basic" {
    var ts = FixedTimeStep.init(60.0);

    // Add one frame at 60FPS → 1 step
    const steps1 = ts.update(1.0 / 60.0);
    try @import("std").testing.expectEqual(@as(usize, 1), steps1);

    // Add half a frame → 0 steps (accumulates)
    const steps2 = ts.update(1.0 / 120.0);
    try @import("std").testing.expectEqual(@as(usize, 0), steps2);

    // Add the other half → 1 step
    const steps3 = ts.update(1.0 / 120.0);
    try @import("std").testing.expectEqual(@as(usize, 1), steps3);
}

test "FixedTimeStep max_steps" {
    var ts = FixedTimeStep.init(60.0);

    // Add a large time (spike simulation)
    const steps = ts.update(1.0); // 1 second = 60 steps worth
    try @import("std").testing.expectEqual(@as(usize, 5), steps); // Capped by max_steps
}

test "FixedTimeStep alpha" {
    var ts = FixedTimeStep.init(60.0);
    const dt = ts.dt;

    // Add half a frame
    _ = ts.update(dt * 0.5);
    const a = ts.alpha();

    // alpha should be near 0.5
    try @import("std").testing.expect(a > 0.4 and a < 0.6);
}

test "FixedTimeStep reset" {
    var ts = FixedTimeStep.init(60.0);

    // Accumulate time
    _ = ts.update(1.0 / 120.0);
    try @import("std").testing.expect(ts.accumulator > 0);

    // Reset
    ts.reset();
    try @import("std").testing.expectEqual(@as(f64, 0.0), ts.accumulator);
}
