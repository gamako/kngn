const std = @import("std");

/// FPS measurement helper
///
/// Design intent:
/// - Auto-measure FPS over a configured time interval
/// - Just call update() every frame to count
/// - When the interval elapses, update the FPS value automatically (console print is optional)
///
/// Example:
/// ```zig
/// var fps_counter = FpsCounter.init(1.0);  // 1-second interval
///
/// while (c.platform_poll_events(window)) {
///     const frame_time = /* elapsed time since the previous frame */;
///
///     if (fps_counter.update(frame_time)) {
///         std.debug.print("FPS: {d}\n", .{fps_counter.getFps()});
///     }
///
///     // ... draw ...
/// }
/// ```
pub const FpsCounter = struct {
    /// Measurement interval (seconds)
    interval: f64,

    /// Elapsed time in the current interval (seconds)
    timer: f64 = 0.0,

    /// Frame count within the current interval
    frame_count: u32 = 0,

    /// Last computed FPS value
    last_fps: u32 = 0,

    /// Initialize
    /// - interval: FPS measurement update interval (seconds); usually 1.0
    pub fn init(interval: f64) FpsCounter {
        std.debug.assert(interval > 0.0); // Prevent division by zero
        return .{ .interval = interval };
    }

    /// Add frame time and update the FPS value
    ///
    /// Returns: true when the FPS value was updated (interval elapsed)
    pub fn update(self: *FpsCounter, frame_time: f64) bool {
        self.timer += frame_time;
        self.frame_count += 1;

        if (self.timer >= self.interval) {
            // FPS = frame count / elapsed time
            self.last_fps = @intFromFloat(@as(f64, @floatFromInt(self.frame_count)) / self.timer);

            // Reset
            // Note: discard surplus time so a lag spike does not falsely report the next interval early
            self.frame_count = 0;
            self.timer = 0.0;

            return true;
        }

        return false;
    }

    /// Get the latest FPS value
    pub fn getFps(self: *const FpsCounter) u32 {
        return self.last_fps;
    }

    /// Reset the counter (e.g. scene change, unpause)
    pub fn reset(self: *FpsCounter) void {
        self.timer = 0.0;
        self.frame_count = 0;
        self.last_fps = 0;
    }
};

test "FpsCounter basic" {
    var counter = FpsCounter.init(1.0);

    // Simulate 60FPS (≈16.67ms per frame)
    const dt = 1.0 / 60.0;

    // No update through frame 59
    for (0..59) |_| {
        const updated = counter.update(dt);
        try std.testing.expect(!updated);
    }

    // Frame 60 ≈ 1 second elapsed → FPS updates
    const updated = counter.update(dt);
    try std.testing.expect(updated);

    // FPS is about 60
    const fps = counter.getFps();
    try std.testing.expect(fps >= 59 and fps <= 61);
}

test "FpsCounter reset" {
    var counter = FpsCounter.init(1.0);

    // Add a few frames
    _ = counter.update(0.5);
    try std.testing.expect(counter.frame_count > 0);

    // Reset
    counter.reset();
    try std.testing.expectEqual(@as(f64, 0.0), counter.timer);
    try std.testing.expectEqual(@as(u32, 0), counter.frame_count);
    try std.testing.expectEqual(@as(u32, 0), counter.last_fps);
}

test "FpsCounter timer reset on interval" {
    var counter = FpsCounter.init(1.0);

    // Add 1.1 seconds of time
    const updated = counter.update(1.1);
    try std.testing.expect(updated);

    // Timer resets to 0 (prevents false reports after a lag spike)
    try std.testing.expectEqual(@as(f64, 0.0), counter.timer);
}

test "FpsCounter zero interval assertion" {
    // Confirm interval=0.0 fails the assertion
    // Note: this test only works in debug builds
    // In release builds assert is disabled
}
