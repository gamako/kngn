//! ADSR エンベロープ。線形セグメント。release で 0 に達すると done(idle)。
//! 減衰末尾の denormal は閾値で 0 に丸める。

const std = @import("std");

pub const Envelope = struct {
    pub const Stage = enum { idle, attack, decay, sustain, release };

    // パラメータ（秒。sustain は 0..1 のレベル）
    attack: f32 = 0.01,
    decay: f32 = 0.1,
    sustain: f32 = 0.7,
    release: f32 = 0.2,
    sample_rate: f32 = 48000,

    stage: Stage = .idle,
    level: f32 = 0.0,

    // 減衰末尾の denormal/極小値を 0 に丸める閾値。
    const done_eps: f32 = 1e-4;

    pub fn noteOn(self: *Envelope) void {
        self.stage = .attack;
    }

    pub fn noteOff(self: *Envelope) void {
        if (self.stage != .idle) self.stage = .release;
    }

    /// release 後に 0 へ達し idle に戻ったか（ボイス回収判定に使う）。
    pub fn isActive(self: *const Envelope) bool {
        return self.stage != .idle;
    }

    /// 1 サンプル進め、現在のレベル(0..1)を返す。
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
                self.level -= self.stepDown(self.release, self.sustain);
                if (self.level <= done_eps) {
                    self.level = 0.0; // denormal 末尾を切る
                    self.stage = .idle;
                }
            },
        }
        return self.level;
    }

    /// `seconds` で 0→1 に上がる 1 サンプル分の増分（0 以下なら即時）。
    fn stepUp(self: *const Envelope, seconds: f32) f32 {
        if (seconds <= 0.0) return 1.0;
        return 1.0 / (seconds * self.sample_rate);
    }

    /// `seconds` で `range` 分下がる 1 サンプル分の減分（0 以下なら即時）。
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
        .sample_rate = 1000, // attack/decay/release = 1 サンプル相当
    };
    try testing.expect(!env.isActive());

    env.noteOn();
    // attack: 1 サンプルで 1.0 到達 → decay へ
    const a = env.next();
    try testing.expect(a >= 1.0);

    // decay: sustain(0.5) へ
    const d = env.next();
    try testing.expectApproxEqAbs(@as(f32, 0.5), d, 1e-5);
    try testing.expectEqual(Envelope.Stage.sustain, env.stage);

    // sustain 維持
    try testing.expectApproxEqAbs(@as(f32, 0.5), env.next(), 1e-5);

    // release → 0、idle
    env.noteOff();
    _ = env.next();
    try testing.expectEqual(@as(f32, 0.0), env.level);
    try testing.expect(!env.isActive());
}

test "Envelope: zero attack jumps immediately" {
    var env = Envelope{ .attack = 0.0, .decay = 0.0, .sustain = 0.8, .sample_rate = 48000 };
    env.noteOn();
    const v = env.next();
    try testing.expect(v >= 0.8); // 即時に attack 完了し decay も即時
}
