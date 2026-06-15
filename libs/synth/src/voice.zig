//! Voice（1 音 = Osc + Env + Filter）と固定 VoicePool（割当 / スチール / done 回収）。
//! 全て RT スレッドで動くため malloc/lock/IO しない（プールは起動時固定確保）。

const std = @import("std");
const dsp = @import("dsp");

/// ユニゾン声部数の固定上限(奇数=中央1声)。Voice はこの数のオシレータを構造体に内包し RT で確保しない。
pub const MAX_UNISON = 7;

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
    // オシレータ拡張(27.13): ユニゾン / 2nd osc / ノイズ源
    unison: u8 = 1, // ユニゾン声部数(1..MAX_UNISON)
    detune: f32 = 0.0, // ユニゾン detune 広がり(cents、±)
    osc2_waveform: dsp.Waveform = .sine,
    osc2_detune: f32 = 0.0, // 2nd osc 音程差(半音)
    osc2_mix: f32 = 0.0, // osc1↔osc2 クロスフェード(0=osc1のみ, 1=osc2のみ)
    noise_amount: f32 = 0.0, // 加算する白色ノイズ量(0..1)
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

/// ユニゾン声部 i(0..MAX_UNISON-1) の初期位相。MAX_UNISON で等分散し全声部の同位相累積を防ぐ。
fn phaseSpread(i: usize) f32 {
    return @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(MAX_UNISON));
}

/// ユニゾン声部 i の detune 比。count 声部で `±detune_cents` を対称分散(count=1 は 1.0)。
fn unisonRatio(i: usize, count: u8, detune_cents: f32) f32 {
    if (count <= 1) return 1.0;
    // 声部を -1..1 に対称配置(i=0 → -1, i=count-1 → +1)
    const spread = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count - 1)) * 2.0 - 1.0;
    return std.math.pow(f32, 2.0, detune_cents * spread / 1200.0);
}

/// 1 音分のボイス。状態機械は Envelope の stage に従う
/// (idle → attack/decay/sustain → release → done=idle)。
pub const Voice = struct {
    oscs: [MAX_UNISON]dsp.Oscillator = [_]dsp.Oscillator{.{}} ** MAX_UNISON, // osc1 ユニゾン複製
    osc2: dsp.Oscillator = .{}, // 2nd オシレータ
    noise: dsp.Noise = .{}, // ノイズ源
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
    // オシレータ段(27.13)のブロック確定パラメータ
    block_unison: u8 = 1,
    block_unison_norm: f32 = 1.0, // 1/sqrt(unison)
    unison_ratio: [MAX_UNISON]f32 = [_]f32{1.0} ** MAX_UNISON,
    block_osc2_ratio: f32 = 1.0,
    block_osc2_mix: f32 = 0.0,
    block_noise: f32 = 0.0,

    pub fn noteOn(self: *Voice, note: u8, velocity: f32, patch: Patch, sample_rate: f32, age: u64) void {
        self.note = note;
        self.freq = noteToFreq(note);
        self.velocity = velocity;
        self.active = true;
        self.age = age;
        // ユニゾン: MAX_UNISON 全要素を初期化(古い再利用 Voice の残り位相/波形を拾わない)。
        // 位相は phaseSpread で分散し同位相による単なる増幅を防ぐ(決定論的・RT 安全)。
        for (&self.oscs, 0..) |*o, i| {
            o.* = .{ .waveform = patch.waveform, .phase = phaseSpread(i) };
        }
        self.osc2 = .{ .waveform = patch.osc2_waveform, .phase = 0 };
        // ノイズ seed: age(単調増加) からノート/ボイス毎に異なる非ゼロ u32 を作る(脱相関)。
        self.noise.seed(@truncate((age +% 1) *% 0x9E3779B97F4A7C15));
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
        // オシレータ段(27.13): ユニゾン数 / detune 比 / osc2 / ノイズ量を確定(pow は毎ブロックのみ)。
        const uni = std.math.clamp(patch.unison, 1, MAX_UNISON);
        self.block_unison = uni;
        self.block_unison_norm = 1.0 / @sqrt(@as(f32, @floatFromInt(uni))); // 脱相関時の体感ラウドネス一定化
        for (0..uni) |i| self.unison_ratio[i] = unisonRatio(i, uni, patch.detune);
        self.block_osc2_ratio = std.math.pow(f32, 2.0, patch.osc2_detune / 12.0);
        self.block_osc2_mix = std.math.clamp(patch.osc2_mix, 0.0, 1.0);
        self.block_noise = std.math.clamp(patch.noise_amount, 0.0, 1.0);
        self.osc2.waveform = patch.osc2_waveform; // ライブ変更可
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
        // オシレータ段: ユニゾン(osc1 複製を detune して合算・正規化) + 2nd osc(クロスフェード) + ノイズ(加算)。
        var osc1: f32 = 0;
        for (self.oscs[0..self.block_unison], 0..) |*o1, i| {
            osc1 += o1.next(freq * self.unison_ratio[i], sample_rate);
        }
        osc1 *= self.block_unison_norm;
        // osc2 は mix=0 でも常に位相を進める(ライブで mix を上げた時のクリック回避)。
        const o2 = self.osc2.next(freq * self.block_osc2_ratio, sample_rate);
        var o = osc1 * (1.0 - self.block_osc2_mix) + o2 * self.block_osc2_mix;
        if (self.block_noise > 0.0) o += self.noise.next() * self.block_noise;
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

// ---- ユニゾン / 2nd osc / ノイズ源 (TASK-27.13) ----

test "unisonRatio: count=1 unchanged, symmetric spread, edges at ±detune" {
    try testing.expectApproxEqAbs(@as(f32, 1.0), unisonRatio(0, 1, 50.0), 1e-6); // 1声=変化なし
    // 3声: i=0 → -detune, i=1 → 0(中央), i=2 → +detune
    try testing.expectApproxEqAbs(std.math.pow(f32, 2.0, -50.0 / 1200.0), unisonRatio(0, 3, 50.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), unisonRatio(1, 3, 50.0), 1e-6);
    try testing.expectApproxEqAbs(std.math.pow(f32, 2.0, 50.0 / 1200.0), unisonRatio(2, 3, 50.0), 1e-6);
}

test "Voice unison: detuned voices beat (window-peak varies) vs steady single voice" {
    // 振幅 env を一定に保ち、窓(256サンプル)ごとのピークの変動幅で「うねり」を測る。
    // 単一正弦は各窓ピークが ~1.0 で一定、detune ユニゾンはビートで窓ピークが大きく変動する。
    const measure = struct {
        fn windowPeakSpread(unison: u8, detune: f32) f32 {
            var v = Voice{};
            const patch = Patch{
                .attack = 0.0,
                .sustain = 1.0,
                .waveform = .sine,
                .cutoff = 18000, // フィルタ影響を最小化
                .filter_env_amount = 0,
                .unison = unison,
                .detune = detune,
            };
            v.noteOn(60, 1.0, patch, 48000, 1);
            v.prepareBlock(patch);
            var min_pk: f32 = 1e9;
            var max_pk: f32 = 0;
            var w: u32 = 0;
            while (w < 64) : (w += 1) { // 64 窓 ≈ 340ms ⇒ 数 beat 周期をカバー
                var pk: f32 = 0;
                var i: u32 = 0;
                while (i < 256) : (i += 1) pk = @max(pk, @abs(v.renderSample(48000)));
                min_pk = @min(min_pk, pk);
                max_pk = @max(max_pk, pk);
            }
            return max_pk - min_pk;
        }
    };
    const single = measure.windowPeakSpread(1, 0.0); // 単一正弦 → 窓ピーク一定
    const unison = measure.windowPeakSpread(7, 25.0); // 7声 detune → ビートで窓ピークが変動
    try testing.expect(single < 0.05); // 単声は定常
    try testing.expect(unison > 0.2); // detune ユニゾンは明確にうねる
}

test "Voice noise: noise_amount>0 mixes audible noise; =0 is deterministic" {
    // noise=0: 2 回の render が完全一致(決定論)
    const peakAndDet = struct {
        fn run(noise_amount: f32) struct { peak: f32, det: bool } {
            var a = Voice{};
            var b = Voice{};
            const patch = Patch{
                .attack = 0.0,
                .sustain = 1.0,
                .gain = 1,
                .cutoff = 18000,
                .filter_env_amount = 0,
                .waveform = .sine,
                .noise_amount = noise_amount,
            };
            a.noteOn(60, 1.0, patch, 48000, 5);
            b.noteOn(60, 1.0, patch, 48000, 5); // 同 age → 同 seed
            a.prepareBlock(patch);
            b.prepareBlock(patch);
            var peak: f32 = 0;
            var det = true;
            var i: u32 = 0;
            while (i < 256) : (i += 1) {
                const sa = a.renderSample(48000);
                const sb = b.renderSample(48000);
                if (sa != sb) det = false;
                peak = @max(peak, @abs(sa));
            }
            return .{ .peak = peak, .det = det };
        }
    };
    const r0 = peakAndDet.run(0.0);
    try testing.expect(r0.det); // noise=0 → 決定論(同 seed で完全一致)
    const r1 = peakAndDet.run(0.8);
    try testing.expect(r1.det); // 同 age=同 seed なので noise>0 でも 2 ボイスは一致(再現性)
    try testing.expect(r1.peak > r0.peak); // ノイズ混入で振幅が増える(混ざっている)
}

test "Voice osc2: mix=0 makes osc2_detune irrelevant; mix>0 changes output" {
    const firstSamples = struct {
        fn render(osc2_mix: f32, osc2_detune: f32, out: []f32) void {
            var v = Voice{};
            const patch = Patch{
                .attack = 0.0,
                .sustain = 1.0,
                .cutoff = 18000,
                .filter_env_amount = 0,
                .waveform = .sine,
                .osc2_waveform = .saw,
                .osc2_mix = osc2_mix,
                .osc2_detune = osc2_detune,
            };
            v.noteOn(60, 1.0, patch, 48000, 1);
            v.prepareBlock(patch);
            for (out) |*s| s.* = v.renderSample(48000);
        }
    };
    var a: [128]f32 = undefined;
    var b: [128]f32 = undefined;
    // mix=0: osc2_detune を変えても出力は完全一致(osc2 が寄与しない)
    firstSamples.render(0.0, 0.0, &a);
    firstSamples.render(0.0, 7.0, &b);
    try testing.expectEqualSlices(f32, &a, &b);
    // mix>0: osc2(saw, 1オクターブ上)を混ぜると出力が変わる
    var c: [128]f32 = undefined;
    firstSamples.render(0.6, 12.0, &c);
    var differs = false;
    for (a, c) |x, y| {
        if (x != y) differs = true;
    }
    try testing.expect(differs);
}

test "Voice unison=MAX: renders finite output over many samples (fixed allocation, no alloc)" {
    var v = Voice{};
    const patch = Patch{
        .attack = 0.01,
        .sustain = 0.8,
        .waveform = .saw,
        .unison = MAX_UNISON,
        .detune = 30.0,
        .osc2_mix = 0.5,
        .osc2_detune = -12,
        .noise_amount = 0.3,
        .cutoff = 8000,
    };
    v.noteOn(64, 1.0, patch, 48000, 1);
    v.prepareBlock(patch);
    var i: u32 = 0;
    while (i < 4096) : (i += 1) {
        const s = v.renderSample(48000);
        try testing.expect(std.math.isFinite(s));
    }
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
