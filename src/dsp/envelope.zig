//! ADSR envelope. Linear segments. Becomes done(idle) when release reaches 0.
//! Round denormal values at the end of decay to 0 by a threshold.

const std = @import("std");

pub const Envelope = struct {
    pub const Stage = enum { idle, attack, decay, sustain, release };

    // Parameters (seconds; sustain is a 0..1 level)
    attack: f32 = 0.01,
    decay: f32 = 0.1,
    sustain: f32 = 0.7,
    release: f32 = 0.2,
    sample_rate: f32 = 48000,

    stage: Stage = .idle,
    level: f32 = 0.0,
    release_level: f32 = 0.0, // Level at release start (decays from here to 0 over release seconds)

    // Threshold that rounds end-of-decay denormal / tiny values to 0.
    const done_eps: f32 = 1e-4;

    pub fn noteOn(self: *Envelope) void {
        self.stage = .attack;
    }

    pub fn noteOff(self: *Envelope) void {
        if (self.stage != .idle) {
            self.release_level = self.level; // Start release from the current level
            self.stage = .release;
        }
    }

    /// True when release has reached 0 and the envelope is idle again (used for voice reclaim).
    pub fn isActive(self: *const Envelope) bool {
        return self.stage != .idle;
    }

    /// Advance one sample and return the current level (0..1).
    pub fn next(self: *Envelope) f32 {
        switch (self.stage) {
            .idle => self.level = 0.0,
            .attack => {
                self.level += self.stepUp(self.attack);
                if (self.level >= 1.0) {
                    self.level = 1.0;
                    self.stage = .decay;
                }
            },
            .decay => {
                self.level -= self.stepDown(self.decay, 1.0 - self.sustain);
                if (self.level <= self.sustain) {
                    self.level = self.sustain;
                    self.stage = .sustain;
                }
            },
            .sustain => self.level = self.sustain,
            .release => {
                // From the release-start level down to 0 over release seconds (independent of sustain)
                self.level -= self.stepDown(self.release, self.release_level);
                if (self.level <= done_eps) {
                    self.level = 0.0; // Cut the denormal tail
                    self.stage = .idle;
                }
            },
        }
        return self.level;
    }

    /// Per-sample increment that rises 0->1 in `seconds` (immediate if seconds <= 0).
    fn stepUp(self: *const Envelope, seconds: f32) f32 {
        if (seconds <= 0.0) return 1.0;
        return 1.0 / (seconds * self.sample_rate);
    }

    /// Per-sample decrement that falls by `range` in `seconds` (immediate if seconds <= 0).
    fn stepDown(self: *const Envelope, seconds: f32, range: f32) f32 {
        if (seconds <= 0.0) return 1.0;
        return range / (seconds * self.sample_rate);
    }
};

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "Envelope: attack rises to 1, decays to sustain, releases to 0 (done)" {
    var env = Envelope{
        .attack = 0.001,
        .decay = 0.001,
        .sustain = 0.5,
        .release = 0.001,
        .sample_rate = 1000, // attack/decay/release = 1 sample each
    };
    try testing.expect(!env.isActive());

    env.noteOn();
    // attack: reaches 1.0 in 1 sample -> decay
    const a = env.next();
    try testing.expect(a >= 1.0);

    // decay: toward sustain(0.5)
    const d = env.next();
    try testing.expectApproxEqAbs(@as(f32, 0.5), d, 1e-5);
    try testing.expectEqual(Envelope.Stage.sustain, env.stage);

    // Hold sustain
    try testing.expectApproxEqAbs(@as(f32, 0.5), env.next(), 1e-5);

    // release -> 0, idle
    env.noteOff();
    _ = env.next();
    try testing.expectEqual(@as(f32, 0.0), env.level);
    try testing.expect(!env.isActive());
}

test "Envelope: release decays to 0 even when sustain=0 (codex review fix)" {
    var env = Envelope{
        .attack = 0.0,
        .decay = 0.0,
        .sustain = 0.0, // release must still work when sustain is 0
        .release = 0.01,
        .sample_rate = 1000, // release = 10 samples
    };
    env.noteOn();
    // With sustain=0, decay leaves the level near 0; try noteOff from the high level just after attack
    const top = env.next(); // attack 0 -> near 1.0 immediately
    try testing.expect(top > 0.5);
    env.noteOff();
    const start = env.level;
    try testing.expect(start > 0.0);
    // Monotonic decrease on release, eventually 0(idle)
    var prev = start;
    var i: u32 = 0;
    var reached_zero = false;
    while (i < 50) : (i += 1) {
        const v = env.next();
        try testing.expect(v <= prev + 1e-6); // Monotonic decrease
        prev = v;
        if (!env.isActive()) {
            reached_zero = true;
            break;
        }
    }
    try testing.expect(reached_zero);
    try testing.expectEqual(@as(f32, 0.0), env.level);
}

test "Envelope: zero attack jumps immediately" {
    var env = Envelope{ .attack = 0.0, .decay = 0.0, .sustain = 0.8, .sample_rate = 48000 };
    env.noteOn();
    const v = env.next();
    try testing.expect(v >= 0.8); // attack completes immediately and decay is immediate too
}
