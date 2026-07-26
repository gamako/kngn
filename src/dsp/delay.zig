//! Delay line: power-of-two fixed-length ring buffer with linearly interpolated delayed reads.
//! Reused as the building block for delay / chorus / reverb effects.
//! Fixed allocation at startup (embedded in the struct); no malloc / locking on the real-time thread.

const std = @import("std");

/// A ring delay of `cap` samples. `cap` must be a power of two.
/// Feedback-loop usage: `const d = line.readAt(n); line.write(x + d*fb);` (read before write).
pub fn DelayLine(comptime cap: usize) type {
    if (!std.math.isPowerOfTwo(cap)) @compileError("DelayLine cap must be a power of two");
    if (cap < 2) @compileError("DelayLine cap must be >= 2 (readAt needs delay range [1, cap-1])");
    return struct {
        const Self = @This();
        const mask = cap - 1;

        buffer: [cap]f32 = [_]f32{0} ** cap,
        head: usize = 0, // Next write position

        /// Clear the buffer and phase.
        pub fn reset(self: *Self) void {
            @memset(&self.buffer, 0);
            self.head = 0;
        }

        /// Write one sample and advance head.
        pub fn write(self: *Self, x: f32) void {
            self.buffer[self.head & mask] = x;
            self.head +%= 1;
        }

        /// Read the value `delay` samples ago (>=1) with linear interpolation.
        /// head is the next write position, so 1 sample ago = head-1. Integer delay N is head-N.
        /// Fractional delay interpolates newer i0(=floor) and older i0+1 as a*(1-frac)+b*frac. delay is clamped to 1..cap-1.
        pub fn readAt(self: *const Self, delay: f32) f32 {
            const d = std.math.clamp(delay, 1.0, @as(f32, @floatFromInt(cap - 1)));
            const di: usize = @intFromFloat(d);
            const frac = d - @as(f32, @floatFromInt(di));
            const a = self.buffer[(self.head -% di) & mask]; // di samples ago (newer side)
            const b = self.buffer[(self.head -% di -% 1) & mask]; // di+1 samples ago (older side)
            return a * (1.0 - frac) + b * frac;
        }
    };
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "DelayLine: integer delay reads exactly N samples ago" {
    var line = DelayLine(8){};
    // Write 0,1,2,3,4,5,6,7 in order
    var i: usize = 0;
    while (i < 8) : (i += 1) line.write(@floatFromInt(i));
    // Most recently written is 7. delay=1 -> 7, delay=2 -> 6, ...
    try testing.expectApproxEqAbs(@as(f32, 7), line.readAt(1), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 6), line.readAt(2), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 4), line.readAt(4), 1e-6);
}

test "DelayLine: fractional delay interpolates between neighbors" {
    var line = DelayLine(8){};
    var i: usize = 0;
    while (i < 8) : (i += 1) line.write(@floatFromInt(i * 10)); // 0,10,20,...,70
    // delay=1.5 -> midpoint of 1ago(70) and 2ago(60) = 65
    try testing.expectApproxEqAbs(@as(f32, 65), line.readAt(1.5), 1e-5);
    // delay=2.25 -> 0.75 of 2ago(60) and 0.25 of 3ago(50) -> 57.5
    try testing.expectApproxEqAbs(@as(f32, 57.5), line.readAt(2.25), 1e-5);
}

test "DelayLine: clamps delay to [1, cap-1] and reset clears" {
    var line = DelayLine(4){};
    line.write(1);
    line.write(2);
    line.write(3);
    line.write(4);
    // delay<1 clamps to 1, delay>cap-1 clamps to cap-1 (no trap)
    _ = line.readAt(0.0);
    _ = line.readAt(100.0);
    line.reset();
    // All zeros after reset
    try testing.expectApproxEqAbs(@as(f32, 0), line.readAt(1), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), line.readAt(3), 1e-6);
}

test "DelayLine: ring wraps around (older samples overwritten)" {
    var line = DelayLine(4){};
    // After writing 8 samples only the last 4 remain: buffer=[4,5,6,7], head=8. Readable delays are 1..cap-1(=3).
    var i: usize = 0;
    while (i < 8) : (i += 1) line.write(@floatFromInt(i));
    try testing.expectApproxEqAbs(@as(f32, 7), line.readAt(1), 1e-6); // 1 ago
    try testing.expectApproxEqAbs(@as(f32, 6), line.readAt(2), 1e-6); // 2 ago
    try testing.expectApproxEqAbs(@as(f32, 5), line.readAt(3), 1e-6); // 3 ago (oldest readable)
}
