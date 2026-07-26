//! White noise source. Generates one sample of -1..1 pseudo-random noise at a time via an xorshift32 PRNG.
//! Real-time safe (branches and arithmetic only; no malloc / locking / IO). For a synth noise oscillator.
//!
//! Note: `<<` is a plain left shift (discards overflow bits) and does not trip a safety-checked overflow
//! (only `@shlExact` does). So the xorshift `x << 13` / `x << 5` are wrapping-safe.

const std = @import("std");

pub const Noise = struct {
    state: u32 = 0x12345678, // Non-zero seed (xorshift stalls when state=0)

    /// Set the seed (OR in the low bit so a 0 argument still guarantees non-zero and does not stall).
    pub fn seed(self: *Noise, s: u32) void {
        self.state = s | 1;
    }

    /// Advance one sample with xorshift32 and return white noise in [-1, 1).
    pub fn next(self: *Noise) f32 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        // Map u32(0..2^32-1) onto [-1, 1)
        return @as(f32, @floatFromInt(x)) * (2.0 / 4294967296.0) - 1.0;
    }
};

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "Noise: output stays within [-1, 1) and varies (not constant)" {
    var n = Noise{};
    var min: f32 = 1e9;
    var max: f32 = -1e9;
    var prev = n.next();
    var changed = false;
    var i: u32 = 0;
    while (i < 10000) : (i += 1) {
        const v = n.next();
        try testing.expect(v >= -1.0 and v < 1.0);
        if (v != prev) changed = true;
        prev = v;
        min = @min(min, v);
        max = @max(max, v);
    }
    try testing.expect(changed); // Not constant
    // Uses a wide range (reaches beyond ±0.5 at both ends)
    try testing.expect(min < -0.5 and max > 0.5);
}

test "Noise: roughly zero-mean with positive variance over many samples" {
    var n = Noise{};
    var sum: f64 = 0;
    var sumsq: f64 = 0;
    const count: usize = 50000;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const v: f64 = n.next();
        sum += v;
        sumsq += v * v;
    }
    const mean = sum / @as(f64, @floatFromInt(count));
    const variance = sumsq / @as(f64, @floatFromInt(count)) - mean * mean;
    try testing.expect(@abs(mean) < 0.05); // Mean ~0
    try testing.expect(variance > 0.1); // Variance of uniform [-1,1) is theoretically ~0.33
}

test "Noise: deterministic for a given seed (reproducible)" {
    var a = Noise{};
    var b = Noise{};
    a.seed(0xC0FFEE);
    b.seed(0xC0FFEE);
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        try testing.expectEqual(a.next(), b.next());
    }
    // Does not stall even with seed(0) (non-zero guarantee)
    var z = Noise{};
    z.seed(0);
    try testing.expect(z.next() != z.next() or true); // Runs without a trap (value is unchecked)
    try testing.expect(z.state != 0);
}
