//! Voice（1 音 = Osc + Env + Filter）と固定 VoicePool（割当 / スチール / done 回収）。
//! 全て RT スレッドで動くため malloc/lock/IO しない（プールは起動時固定確保）。

const std = @import("std");
const dsp = @import("dsp");

/// 音色パラメータの集合。waveform / ADSR は noteOn で latch、cutoff/res/gain は毎ブロック反映。
pub const Patch = struct {
    waveform: dsp.Waveform = .sine,
    attack: f32 = 0.01,
    decay: f32 = 0.1,
    sustain: f32 = 0.7,
    release: f32 = 0.2,
    cutoff: f32 = 8000.0,
    resonance: f32 = 0.707,
    gain: f32 = 0.2,
};

/// MIDI ノート番号 → 周波数(Hz)。A4(note 69)=440Hz。
pub fn noteToFreq(note: u8) f32 {
    const n: f32 = @floatFromInt(note);
    return 440.0 * std.math.pow(f32, 2.0, (n - 69.0) / 12.0);
}

/// 1 音分のボイス。状態機械は Envelope の stage に従う
/// (idle → attack/decay/sustain → release → done=idle)。
pub const Voice = struct {
    osc: dsp.Oscillator = .{},
    env: dsp.Envelope = .{},
    filter: dsp.Filter = .{},
    note: u8 = 0,
    freq: f32 = 0,
    velocity: f32 = 0,
    active: bool = false,
    age: u64 = 0, // スチール判定用（小さいほど古い）

    pub fn noteOn(self: *Voice, note: u8, velocity: f32, patch: Patch, sample_rate: f32, age: u64) void {
        self.note = note;
        self.freq = noteToFreq(note);
        self.velocity = velocity;
        self.active = true;
        self.age = age;
        self.osc = .{ .waveform = patch.waveform, .phase = 0 };
        self.env = .{
            .attack = patch.attack,
            .decay = patch.decay,
            .sustain = patch.sustain,
            .release = patch.release,
            .sample_rate = sample_rate,
        };
        self.env.noteOn();
        self.filter = dsp.Filter.init(sample_rate, patch.cutoff, patch.resonance);
    }

    pub fn noteOff(self: *Voice) void {
        self.env.noteOff();
    }

    /// ブロック先頭で cutoff/resonance を反映（毎サンプル tan を避ける）。
    pub fn prepareBlock(self: *Voice, patch: Patch) void {
        if (self.active) self.filter.setParams(patch.cutoff, patch.resonance);
    }

    /// 1 サンプル合成。env が done になったら active=false（プールへ返る）。
    pub fn renderSample(self: *Voice, sample_rate: f32) f32 {
        if (!self.active) return 0.0;
        const o = self.osc.next(self.freq, sample_rate);
        const e = self.env.next();
        const out = self.filter.process(o * e * self.velocity);
        if (!self.env.isActive()) self.active = false; // done 回収
        return out;
    }

    pub fn stage(self: *const Voice) dsp.Envelope.Stage {
        return self.env.stage;
    }
};

/// 固定数のボイスプール。割当は空きボイス優先、満杯なら最古をスチール。
pub fn VoicePool(comptime max_voices: usize) type {
    return struct {
        const Self = @This();

        voices: [max_voices]Voice = [_]Voice{.{}} ** max_voices,
        age_counter: u64 = 0,

        pub fn capacity() usize {
            return max_voices;
        }

        pub fn activeCount(self: *const Self) usize {
            var n: usize = 0;
            for (self.voices) |v| {
                if (v.active) n += 1;
            }
            return n;
        }

        /// 空きボイスへ割当。満杯なら最古(age 最小)をスチール。
        pub fn noteOn(self: *Self, note: u8, velocity: f32, patch: Patch, sample_rate: f32) void {
            self.age_counter += 1;
            const idx = self.findFreeOrOldest();
            self.voices[idx].noteOn(note, velocity, patch, sample_rate, self.age_counter);
        }

        /// 該当ノートを鳴らしている全ボイスを release へ。
        pub fn noteOff(self: *Self, note: u8) void {
            for (&self.voices) |*v| {
                if (v.active and v.note == note) v.noteOff();
            }
        }

        /// 全ノートオフ（パニック）。
        pub fn allNotesOff(self: *Self) void {
            for (&self.voices) |*v| {
                if (v.active) v.noteOff();
            }
        }

        fn findFreeOrOldest(self: *Self) usize {
            var oldest: usize = 0;
            var oldest_age: u64 = std.math.maxInt(u64);
            for (self.voices, 0..) |v, i| {
                if (!v.active) return i; // 空き優先
                if (v.age < oldest_age) {
                    oldest_age = v.age;
                    oldest = i;
                }
            }
            return oldest; // 満杯 → 最古をスチール
        }

        /// ブロック先頭処理: 全アクティブボイスに patch の filter を反映。
        pub fn prepareBlock(self: *Self, patch: Patch) void {
            for (&self.voices) |*v| v.prepareBlock(patch);
        }

        /// 1 サンプル分、全アクティブボイスを合成して合算。
        pub fn renderSample(self: *Self, sample_rate: f32) f32 {
            var sum: f32 = 0;
            for (&self.voices) |*v| sum += v.renderSample(sample_rate);
            return sum;
        }
    };
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "noteToFreq: A4=440, A5=880" {
    try testing.expectApproxEqAbs(@as(f32, 440.0), noteToFreq(69), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 880.0), noteToFreq(81), 0.01);
}

test "Voice: state machine idle -> attack -> ... -> release -> idle(done)" {
    var v = Voice{};
    try testing.expectEqual(dsp.Envelope.Stage.idle, v.stage());
    try testing.expect(!v.active);

    const patch = Patch{ .attack = 0.001, .decay = 0.001, .sustain = 0.5, .release = 0.001, .gain = 1 };
    v.noteOn(69, 1.0, patch, 1000, 1); // sr=1000 → 各セグメント約1サンプル
    try testing.expect(v.active);
    try testing.expectEqual(dsp.Envelope.Stage.attack, v.stage());

    // 数サンプル進めると attack→decay→sustain
    var i: u32 = 0;
    while (i < 5) : (i += 1) _ = v.renderSample(1000);
    try testing.expectEqual(dsp.Envelope.Stage.sustain, v.stage());
    try testing.expect(v.active);

    // noteOff → release → done で active=false
    v.noteOff();
    i = 0;
    while (i < 10 and v.active) : (i += 1) _ = v.renderSample(1000);
    try testing.expect(!v.active);
    try testing.expectEqual(dsp.Envelope.Stage.idle, v.stage());
}

test "VoicePool: allocate free voices then steal oldest when full" {
    var pool = VoicePool(2){};
    const patch = Patch{};
    try testing.expectEqual(@as(usize, 0), pool.activeCount());

    pool.noteOn(60, 1.0, patch, 48000); // voice0 (age1)
    pool.noteOn(62, 1.0, patch, 48000); // voice1 (age2)
    try testing.expectEqual(@as(usize, 2), pool.activeCount());

    // 満杯。3つ目は最古(age1, note60)をスチール
    pool.noteOn(64, 1.0, patch, 48000);
    try testing.expectEqual(@as(usize, 2), pool.activeCount());
    // note60 はもう鳴っていない（スチールされた）
    var has60 = false;
    var has64 = false;
    for (pool.voices) |v| {
        if (v.active and v.note == 60) has60 = true;
        if (v.active and v.note == 64) has64 = true;
    }
    try testing.expect(!has60);
    try testing.expect(has64);
}

test "VoicePool: done voices are recycled (active count drops after release)" {
    var pool = VoicePool(4){};
    const patch = Patch{ .attack = 0.0001, .decay = 0.0001, .sustain = 0.5, .release = 0.0001, .gain = 1 };
    pool.noteOn(60, 1.0, patch, 1000);
    pool.noteOff(60);
    try testing.expectEqual(@as(usize, 1), pool.activeCount());
    // release が 0 に達するまで回す → 回収される
    var i: u32 = 0;
    while (i < 50) : (i += 1) _ = pool.renderSample(1000);
    try testing.expectEqual(@as(usize, 0), pool.activeCount());
}
