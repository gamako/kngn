//! Animation clip / playback control.
//!
//! AnimationClip: frame list + fps + loop (borrow only; no allocator).
//! AnimationPlayer: advances deterministically with fixed-point phase (no f32 accumulation).
//!
//! Hot-path declaration: `update` is O(1) per fixed timestep. No allocation.

const std = @import("std");

/// Animation clip. The caller keeps the frame list alive for the clip's lifetime (borrow).
pub const AnimationClip = struct {
    /// Sequence of Atlas frame indices
    frames: []const u32,
    fps: u32,
    loop: bool,
};

/// Phase time unit is microseconds.
///
/// Overflow rationale (u64):
/// - `phase` is reduced modulo `TICKS_PER_SECOND` every time, so always `< 1_000_000`.
/// - One update adds `dt_ticks * fps`. Even with `dt_ticks <= 3600 * 1e6` (≈1 hour) and
///   `fps <= 1_000_000`, the product is `3.6e15 < 2^64≈1.8e19`. Normal fixed timestep
///   (dt≈1/60, fps≤120) has ample headroom.
/// - Invalid dt (0 / negative / non-finite) is a no-op. Extremely large dt saturates the u64 conversion
///   and transitions are handled with a modulo in O(1) (does not step one frame at a time).
const TICKS_PER_SECOND: u64 = 1_000_000;

/// Animation player.
///
/// `currentFrame()` returns an Atlas frame index, not a clip sequence index.
pub const AnimationPlayer = struct {
    clip: AnimationClip,
    /// Sequence position inside clip `frames`
    seq_index: u32 = 0,
    /// Phase until the next frame [0, TICKS_PER_SECOND)
    phase: u64 = 0,
    playing: bool = false,

    pub fn init(clip: AnimationClip) AnimationPlayer {
        return .{
            .clip = clip,
            .seq_index = 0,
            .phase = 0,
            .playing = false,
        };
    }

    /// Reset to the first frame and start playing.
    pub fn play(self: *AnimationPlayer) void {
        self.seq_index = 0;
        self.phase = 0;
        self.playing = self.clip.frames.len > 0 and self.clip.fps > 0;
    }

    /// Stop playback. Keeps the current frame.
    pub fn stop(self: *AnimationPlayer) void {
        self.playing = false;
    }

    pub fn isPlaying(self: *const AnimationPlayer) bool {
        return self.playing;
    }

    /// Atlas frame index. Empty clip returns 0.
    pub fn currentFrame(self: *const AnimationPlayer) u32 {
        if (self.clip.frames.len == 0) return 0;
        const idx = @min(self.seq_index, @as(u32, @intCast(self.clip.frames.len - 1)));
        return self.clip.frames[idx];
    }

    /// Advance by `dt` seconds. Quantize once to fixed-point (µs); internals are integers only.
    /// 0 / negative / non-finite / not playing / fps=0 / empty frames → no-op.
    pub fn update(self: *AnimationPlayer, dt: f64) void {
        if (!self.playing) return;
        if (self.clip.frames.len == 0 or self.clip.fps == 0) {
            self.playing = false;
            return;
        }
        if (!std.math.isFinite(dt) or dt <= 0) return;

        const dt_ticks = dtToMicros(dt);
        if (dt_ticks == 0) return;

        // phase += dt_ticks * fps (saturate to u64 max on overflow)
        const add = mulSaturating(dt_ticks, self.clip.fps);
        const sum = addSaturating(self.phase, add);
        const transitions: u64 = sum / TICKS_PER_SECOND;
        self.phase = sum % TICKS_PER_SECOND;

        if (transitions == 0) return;
        self.advance(transitions);
    }

    fn advance(self: *AnimationPlayer, transitions: u64) void {
        const n = self.clip.frames.len;
        if (n == 0) {
            self.playing = false;
            return;
        }
        if (n == 1) {
            self.seq_index = 0;
            if (!self.clip.loop) self.playing = false;
            return;
        }

        if (self.clip.loop) {
            // O(1) modulo. Even with many transitions, do not step one frame at a time.
            const mod = transitions % n;
            self.seq_index = @intCast((@as(u64, self.seq_index) + mod) % n);
        } else {
            const last: u64 = n - 1;
            const next = @as(u64, self.seq_index) + transitions;
            if (next >= last) {
                self.seq_index = @intCast(last);
                self.playing = false;
            } else {
                self.seq_index = @intCast(next);
            }
        }
    }
};

/// Truncate-quantize a positive finite `dt` to µs. Caller is assumed to have excluded <0 / non-finite.
fn dtToMicros(dt: f64) u64 {
    // 1e6 * dt. Values past u64 max saturate.
    const scaled = dt * @as(f64, @floatFromInt(TICKS_PER_SECOND));
    if (!std.math.isFinite(scaled) or scaled <= 0) return 0;
    if (scaled >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) {
        return std.math.maxInt(u64);
    }
    return @intFromFloat(scaled);
}

fn mulSaturating(a: u64, b: u32) u64 {
    const bi: u64 = b;
    const prod = @mulWithOverflow(a, bi);
    if (prod[1] != 0) return std.math.maxInt(u64);
    return prod[0];
}

fn addSaturating(a: u64, b: u64) u64 {
    const sum = @addWithOverflow(a, b);
    if (sum[1] != 0) return std.math.maxInt(u64);
    return sum[0];
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

test "AnimationPlayer identical dt sequence is deterministic" {
    const frames = [_]u32{ 10, 20, 30, 40 };
    const clip = AnimationClip{ .frames = &frames, .fps = 4, .loop = true };

    var a = AnimationPlayer.init(clip);
    var b = AnimationPlayer.init(clip);
    a.play();
    b.play();

    // 250_000 µs * fps4 → exactly 1 transition / input
    const dt: f64 = 0.25;
    var seq_a: [8]u32 = undefined;
    var seq_b: [8]u32 = undefined;
    for (0..8) |i| {
        seq_a[i] = a.currentFrame();
        seq_b[i] = b.currentFrame();
        a.update(dt);
        b.update(dt);
    }
    try testing.expectEqualSlices(u32, &seq_a, &seq_b);
    try testing.expectEqualSlices(u32, &[_]u32{ 10, 20, 30, 40, 10, 20, 30, 40 }, &seq_a);
}

test "AnimationPlayer fps=4 advances every 250ms ticks" {
    const frames = [_]u32{ 0, 1, 2 };
    const clip = AnimationClip{ .frames = &frames, .fps = 4, .loop = true };
    var p = AnimationPlayer.init(clip);
    p.play();

    try testing.expectEqual(@as(u32, 0), p.currentFrame());
    // 249_999 µs equivalent: no transition
    p.update(0.249999);
    try testing.expectEqual(@as(u32, 0), p.currentFrame());
    // Add 1 µs more so the total is at least 250_000 µs
    p.update(0.000002);
    try testing.expectEqual(@as(u32, 1), p.currentFrame());

    // Exactly 0.25 twice → advance by 2
    p.update(0.25);
    try testing.expectEqual(@as(u32, 2), p.currentFrame());
    p.update(0.25);
    try testing.expectEqual(@as(u32, 0), p.currentFrame()); // loop
}

test "AnimationPlayer loop wraps to start" {
    const frames = [_]u32{ 5, 6 };
    const clip = AnimationClip{ .frames = &frames, .fps = 10, .loop = true };
    var p = AnimationPlayer.init(clip);
    p.play();

    // Large dt: multiple transitions via O(1) modulo
    p.update(1.0); // 10 transitions
    // start 0 + 10 ≡ 0 (mod 2)
    try testing.expectEqual(@as(u32, 5), p.currentFrame());
    try testing.expect(p.isPlaying());
}

test "AnimationPlayer non-loop stops on last frame" {
    const frames = [_]u32{ 1, 2, 3 };
    const clip = AnimationClip{ .frames = &frames, .fps = 4, .loop = false };
    var p = AnimationPlayer.init(clip);
    p.play();

    p.update(0.25);
    try testing.expectEqual(@as(u32, 2), p.currentFrame());
    p.update(0.25);
    try testing.expectEqual(@as(u32, 3), p.currentFrame());
    try testing.expect(!p.isPlaying());
    // Further updates do not change it
    p.update(0.25);
    p.update(1.0);
    try testing.expectEqual(@as(u32, 3), p.currentFrame());
    try testing.expect(!p.isPlaying());
}

test "AnimationPlayer play reset / stop hold / invalid dt no-op" {
    const frames = [_]u32{ 7, 8, 9 };
    const clip = AnimationClip{ .frames = &frames, .fps = 4, .loop = true };
    var p = AnimationPlayer.init(clip);
    p.play();
    p.update(0.25);
    p.update(0.25);
    try testing.expectEqual(@as(u32, 9), p.currentFrame());

    p.stop();
    try testing.expect(!p.isPlaying());
    try testing.expectEqual(@as(u32, 9), p.currentFrame());
    p.update(0.25); // no-op while stopped
    try testing.expectEqual(@as(u32, 9), p.currentFrame());

    p.play(); // Reset to the start
    try testing.expect(p.isPlaying());
    try testing.expectEqual(@as(u32, 7), p.currentFrame());

    // Invalid dt
    p.update(0);
    p.update(-1.0);
    p.update(std.math.nan(f64));
    p.update(std.math.inf(f64));
    try testing.expectEqual(@as(u32, 7), p.currentFrame());
}
