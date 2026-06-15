//! Voice（1 音 = Osc + Env + Filter）と固定 VoicePool（割当 / スチール / done 回収）。
//! 全て RT スレッドで動くため malloc/lock/IO しない（プールは起動時固定確保）。

const std = @import("std");
const dsp = @import("dsp");

/// 音色パラメータの集合。waveform / ADSR は noteOn で latch、cutoff/res/gain/filter_mode/keytrack は毎ブロック反映。
pub const Patch = struct {
    waveform: dsp.Waveform = .sine,
    attack: f32 = 0.01,
    decay: f32 = 0.1,
    sustain: f32 = 0.7,
    release: f32 = 0.2,
    cutoff: f32 = 8000.0,
    resonance: f32 = 0.707,
    gain: f32 = 0.2,
    filter_mode: dsp.FilterMode = .lowpass,
    /// キートラッキング量(0=追従なし, 1=1オクターブ/オクターブ=完全追従)。基準ノートは C4(60)。
    keytrack: f32 = 0.0,
    // フィルタエンベロープ（2本目 ADSR で cutoff をモジュレート）
    filter_attack: f32 = 0.01,
    filter_decay: f32 = 0.2,
    filter_sustain: f32 = 0.0,
    filter_release: f32 = 0.2,
    /// フィルタ env のモジュレーション量（オクターブ単位の±）。0 で無効（従来通り）。
    filter_env_amount: f32 = 0.0,
    // LFO（vibrato/tremolo）
    lfo_rate: f32 = 5.0, // Hz
    lfo_waveform: dsp.LfoWaveform = .sine,
    vibrato_depth: f32 = 0.0, // 半音単位（pitch モジュレーション）
    tremolo_depth: f32 = 0.0, // 0..1（amp モジュレーション）
    /// ベロシティ → cutoff（オクターブ単位）。0 で無効。
    velocity_to_cutoff: f32 = 0.0,
};

/// キートラッキング適用後の実効 cutoff(Hz)。基準 C4(60) から半音ごとに keytrack 比率で追従。
fn trackedCutoff(base_cutoff: f32, keytrack: f32, note: u8) f32 {
    const semitones = (@as(f32, @floatFromInt(note)) - 60.0);
    return base_cutoff * std.math.pow(f32, 2.0, keytrack * semitones / 12.0);
}

/// フィルタ env による cutoff モジュレーション。amount(オクターブ) × env_level(0..1) を底2で適用。
fn modulatedCutoff(base_cutoff: f32, amount: f32, env_level: f32) f32 {
    return base_cutoff * std.math.pow(f32, 2.0, amount * env_level);
}

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
    filter_env: dsp.Envelope = .{}, // フィルタ用 2 本目 ADSR
    lfo: dsp.Lfo = .{},
    filter: dsp.Filter = .{},
    note: u8 = 0,
    freq: f32 = 0,
    velocity: f32 = 0,
    active: bool = false,
    age: u64 = 0, // スチール判定用（小さいほど古い）
    // ブロック先頭で確定するパラメータ（renderSample のモジュレーションに使う）
    block_cutoff: f32 = 8000,
    block_res: f32 = 0.707,
    block_fenv_amount: f32 = 0.0,
    block_lfo_rate: f32 = 5.0,
    block_vibrato: f32 = 0.0,
    block_tremolo: f32 = 0.0,

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
        self.filter_env = .{
            .attack = patch.filter_attack,
            .decay = patch.filter_decay,
            .sustain = patch.filter_sustain,
            .release = patch.filter_release,
            .sample_rate = sample_rate,
        };
        self.filter_env.noteOn();
        self.lfo = .{ .waveform = patch.lfo_waveform, .phase = 0 };
        self.filter = dsp.Filter.init(sample_rate, trackedCutoff(patch.cutoff, patch.keytrack, note), patch.resonance);
        self.filter.setMode(patch.filter_mode);
    }

    pub fn noteOff(self: *Voice) void {
        self.env.noteOff();
        self.filter_env.noteOff();
    }

    /// ブロック先頭で cutoff(キートラッキング + ベロシティ→cutoff)/resonance/種別/モジュレーション量を確定。
    /// filter_env_amount=0 のときは毎サンプルの再計算を避けてここで一度だけ setParams。
    pub fn prepareBlock(self: *Voice, patch: Patch) void {
        if (!self.active) return;
        // base cutoff = キートラッキング × ベロシティ→cutoff
        const vel_oct = patch.velocity_to_cutoff * self.velocity;
        self.block_cutoff = trackedCutoff(patch.cutoff, patch.keytrack, self.note) * std.math.pow(f32, 2.0, vel_oct);
        self.block_res = patch.resonance;
        self.block_fenv_amount = patch.filter_env_amount;
        self.block_lfo_rate = patch.lfo_rate;
        self.block_vibrato = patch.vibrato_depth;
        self.block_tremolo = std.math.clamp(patch.tremolo_depth, 0.0, 1.0); // 範囲外で負ゲイン/増幅を防ぐ
        self.filter.setMode(patch.filter_mode);
        if (patch.filter_env_amount == 0.0) self.filter.setParams(self.block_cutoff, self.block_res);
    }

    /// 1 サンプル合成。env が done になったら active=false（プールへ返る）。
    pub fn renderSample(self: *Voice, sample_rate: f32) f32 {
        if (!self.active) return 0.0;
        // LFO は vibrato/tremolo のどちらかが有効なときだけ進める（不要な計算を避ける）。
        const mod_on = self.block_vibrato != 0.0 or self.block_tremolo != 0.0;
        const lfo_v = if (mod_on) self.lfo.next(self.block_lfo_rate, sample_rate) else 0.0; // -1..1
        // vibrato: pitch を半音単位でモジュレート（depth=0 なら pow を省く）
        const freq = if (self.block_vibrato != 0.0)
            self.freq * std.math.pow(f32, 2.0, self.block_vibrato * lfo_v / 12.0)
        else
            self.freq;
        const o = self.osc.next(freq, sample_rate);
        const e = self.env.next();
        const fe = self.filter_env.next();
        // フィルタ env が有効なら cutoff を毎サンプルモジュレート（amount=0 なら prepareBlock の設定のまま）
        if (self.block_fenv_amount != 0.0) {
            self.filter.setParams(modulatedCutoff(self.block_cutoff, self.block_fenv_amount, fe), self.block_res);
        }
        // tremolo: amp を 0..1 でモジュレート（lfo=+1→1.0、-1→1-depth）
        const trem = if (self.block_tremolo != 0.0) 1.0 - self.block_tremolo * (0.5 - 0.5 * lfo_v) else 1.0;
        const out = self.filter.process(o * e * self.velocity * trem);
        if (!self.env.isActive()) self.active = false; // done 回収（振幅 env 基準）
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

test "modulatedCutoff: env_level=0 unchanged, amount/level applied in octaves" {
    try testing.expectApproxEqAbs(@as(f32, 1000.0), modulatedCutoff(1000, 3.0, 0.0), 0.01); // level 0 → base
    try testing.expectApproxEqAbs(@as(f32, 2000.0), modulatedCutoff(1000, 1.0, 1.0), 0.01); // +1oct
    try testing.expectApproxEqAbs(@as(f32, 4000.0), modulatedCutoff(1000, 2.0, 1.0), 0.01); // +2oct
}

test "Voice filter env: amount>0 で env が上昇→減衰し cutoff も追従、amount=0 で無効" {
    // amount>0: filter_env が attack で上昇 → release で減衰
    var v = Voice{};
    const patch = Patch{
        .attack = 1.0, // 振幅 env は長く保つ（ボイスを生かす）
        .sustain = 1.0,
        .filter_attack = 0.002,
        .filter_decay = 0.001,
        .filter_sustain = 0.2,
        .filter_release = 0.002,
        .filter_env_amount = 2.0,
        .cutoff = 1000,
    };
    v.noteOn(60, 1.0, patch, 1000, 1); // sr=1000
    v.prepareBlock(patch);
    // attack 中: filter_env.level が上がる
    _ = v.renderSample(1000);
    const lvl1 = v.filter_env.level;
    _ = v.renderSample(1000);
    const lvl2 = v.filter_env.level;
    try testing.expect(lvl2 >= lvl1); // 上昇（attack/decay 中）
    const peak_cutoff = modulatedCutoff(v.block_cutoff, v.block_fenv_amount, lvl2);
    try testing.expect(peak_cutoff > 1000.0); // env により base より高い cutoff

    // release で減衰
    v.noteOff();
    var i: u32 = 0;
    while (i < 5) : (i += 1) _ = v.renderSample(1000);
    try testing.expect(v.filter_env.level < lvl2); // 減衰した

    // amount=0: filter モジュレーション無効（block_fenv_amount=0）
    var v2 = Voice{};
    const p0 = Patch{ .attack = 1.0, .sustain = 1.0, .filter_env_amount = 0.0, .cutoff = 1000 };
    v2.noteOn(60, 1.0, p0, 1000, 1);
    v2.prepareBlock(p0);
    try testing.expectEqual(@as(f32, 0.0), v2.block_fenv_amount);
}

test "Voice LFO tremolo: amp varies over time when depth>0" {
    var v = Voice{};
    const patch = Patch{
        .attack = 0.0,
        .sustain = 1.0, // 一定振幅に保つ
        .waveform = .sine,
        .lfo_rate = 100, // 速い tremolo（短時間で変動）
        .tremolo_depth = 1.0,
        .filter_env_amount = 0.0,
        .cutoff = 18000, // フィルタの影響を最小化
    };
    v.noteOn(60, 1.0, patch, 1000, 1);
    v.prepareBlock(patch);
    var min_abs: f32 = 1e9;
    var max_abs: f32 = 0;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const s = @abs(v.renderSample(1000));
        min_abs = @min(min_abs, s);
        max_abs = @max(max_abs, s);
    }
    // tremolo により振幅に明確な変動がある
    try testing.expect(max_abs - min_abs > 0.05);
}

test "Voice velocity->amp: lower velocity gives quieter output" {
    const measure = struct {
        fn peak(vel: f32) f32 {
            var v = Voice{};
            const patch = Patch{ .attack = 0.0, .sustain = 1.0, .cutoff = 18000, .filter_env_amount = 0 };
            v.noteOn(60, vel, patch, 1000, 1);
            v.prepareBlock(patch);
            var mx: f32 = 0;
            var i: u32 = 0;
            while (i < 50) : (i += 1) mx = @max(mx, @abs(v.renderSample(1000)));
            return mx;
        }
    };
    try testing.expect(measure.peak(0.3) < measure.peak(1.0));
}

test "Voice velocity->cutoff: higher velocity raises block_cutoff when amount>0" {
    var lo = Voice{};
    var hi = Voice{};
    const patch = Patch{ .cutoff = 1000, .velocity_to_cutoff = 2.0, .filter_env_amount = 0 };
    lo.noteOn(60, 0.2, patch, 48000, 1);
    hi.noteOn(60, 1.0, patch, 48000, 2);
    lo.prepareBlock(patch);
    hi.prepareBlock(patch);
    try testing.expect(hi.block_cutoff > lo.block_cutoff);
}

test "trackedCutoff: keytrack=0 unchanged, keytrack=1 follows 1oct/oct, higher note->higher cutoff" {
    // keytrack=0: 音程に関係なく base のまま
    try testing.expectApproxEqAbs(@as(f32, 1000.0), trackedCutoff(1000, 0.0, 72), 0.01);
    // keytrack=1: C4(60)基準。C5(72, +12半音)で 2 倍
    try testing.expectApproxEqAbs(@as(f32, 2000.0), trackedCutoff(1000, 1.0, 72), 0.5);
    // C3(48, -12半音)で半分
    try testing.expectApproxEqAbs(@as(f32, 500.0), trackedCutoff(1000, 1.0, 48), 0.5);
    // 高い音ほど cutoff が高い
    try testing.expect(trackedCutoff(1000, 0.5, 80) > trackedCutoff(1000, 0.5, 60));
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
