//! アニメーションクリップ / 再生制御（TASK-111.3）。
//!
//! AnimationClip: フレーム列 + fps + loop（借用のみ。allocator 無し）。
//! AnimationPlayer: 固定小数位相で決定的に進行（f32 蓄積禁止）。
//!
//! ホットパス宣言: `update` は固定 timestep ごとの O(1)。アロケーション無し。

const std = @import("std");

/// アニメーションクリップ。フレーム列は呼び出し側が長寿命で保持する（借用）。
pub const AnimationClip = struct {
    /// Atlas のフレーム番号列
    frames: []const u32,
    fps: u32,
    loop: bool,
};

/// 位相の時間単位はマイクロ秒。
///
/// overflow 根拠（u64）:
/// - `phase` は毎回 `TICKS_PER_SECOND` で剰余されるため常に `< 1_000_000`。
/// - 1 update の加算量は `dt_ticks * fps`。`dt_ticks <= 3600 * 1e6`（1 時間相当）かつ
///   `fps <= 1_000_000` でも積は `3.6e15 < 2^64≈1.8e19`。通常の fixed timestep
///   （dt≈1/60、fps≤120）では余裕がある。
/// - 不正 dt（0 / 負 / 非有限）は no-op。極端に大きい dt は u64 変換で飽和し、
///   遷移は剰余で O(1) 処理する（1 フレームずつ回さない）。
const TICKS_PER_SECOND: u64 = 1_000_000;

/// アニメーション再生器。
///
/// `currentFrame()` はクリップのシーケンス index ではなく、Atlas のフレーム番号を返す。
pub const AnimationPlayer = struct {
    clip: AnimationClip,
    /// クリップ `frames` 内のシーケンス位置
    seq_index: u32 = 0,
    /// 次フレームまでの位相 [0, TICKS_PER_SECOND)
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

    /// 先頭フレームへ戻して再生開始。
    pub fn play(self: *AnimationPlayer) void {
        self.seq_index = 0;
        self.phase = 0;
        self.playing = self.clip.frames.len > 0 and self.clip.fps > 0;
    }

    /// 再生停止。現在フレームを保持。
    pub fn stop(self: *AnimationPlayer) void {
        self.playing = false;
    }

    pub fn isPlaying(self: *const AnimationPlayer) bool {
        return self.playing;
    }

    /// Atlas のフレーム番号。空クリップは 0。
    pub fn currentFrame(self: *const AnimationPlayer) u32 {
        if (self.clip.frames.len == 0) return 0;
        const idx = @min(self.seq_index, @as(u32, @intCast(self.clip.frames.len - 1)));
        return self.clip.frames[idx];
    }

    /// `dt` 秒だけ進行させる。固定小数（µs）へ一度量子化し、内部は整数のみ。
    /// 0 / 負 / 非有限 / 非再生 / fps=0 / 空フレーム は no-op。
    pub fn update(self: *AnimationPlayer, dt: f64) void {
        if (!self.playing) return;
        if (self.clip.frames.len == 0 or self.clip.fps == 0) {
            self.playing = false;
            return;
        }
        if (!std.math.isFinite(dt) or dt <= 0) return;

        const dt_ticks = dtToMicros(dt);
        if (dt_ticks == 0) return;

        // phase += dt_ticks * fps（overflow 時は u64 最大へ飽和）
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
            // O(1) 剰余。transitions が大きくても 1 フレームずつ回さない。
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

/// 正の有限 `dt` を µs へ切り捨て量子化。0 未満や非有限は呼び出し側で除外済み想定。
fn dtToMicros(dt: f64) u64 {
    // 1e6 * dt。u64 最大を超える値は飽和。
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

    // 250_000 µs * fps4 → ちょうど 1 遷移 / 入力
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
    // 249_999 µs 相当: 遷移しない
    p.update(0.249999);
    try testing.expectEqual(@as(u32, 0), p.currentFrame());
    // 追加で 1 µs 分超えて合計 250_000 µs 以上へ
    p.update(0.000002);
    try testing.expectEqual(@as(u32, 1), p.currentFrame());

    // 正確に 0.25 を 2 回 → 2 進む
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

    // 大きな dt で複数遷移を O(1) 剰余
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
    // 追加 update で変化しない
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

    p.play(); // 先頭へリセット
    try testing.expect(p.isPlaying());
    try testing.expectEqual(@as(u32, 7), p.currentFrame());

    // 不正 dt
    p.update(0);
    p.update(-1.0);
    p.update(std.math.nan(f64));
    p.update(std.math.inf(f64));
    try testing.expectEqual(@as(u32, 7), p.currentFrame());
}
