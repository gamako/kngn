//! マスターエフェクトチェーン(TASK-27.14)。
//!
//! `Synth.render` の後・出力タップの前で interleaved stereo(or mono) バッファを **in-place** 処理する。
//! チェーン順: distortion → chorus → delay(feedback)。各段は mix=0 で実質無効(ただし内部状態は更新継続=
//! 可聴バイパスであって凍結ではない)。完全な無効化は master `bypass`(buf 不変)。
//!
//! パラメータ受け渡しは Synth.patch_db と同じ `DoubleBuffer`(ロックフリー)。
//! 前提: 単一 producer(GUI スレッド)、フレーム単位で publish、`Params` は小さい plain data、
//! publish 後は当該バッファを mutation しない。
//!
//! RT 安全: ディレイ/コーラスのラインは comptime 固定長で構造体内包(起動時固定確保)。
//! process() は確保/ロック/IO をしない。

const std = @import("std");
const dsp = @import("dsp");
const params = @import("params.zig");

/// `delay_cap` / `chorus_cap`(ともに 2 の冪サンプル)のディレイラインを内包するマスターエフェクト。
pub fn MasterEffects(comptime delay_cap: usize, comptime chorus_cap: usize) type {
    return struct {
        const Self = @This();

        pub const Params = struct {
            bypass: bool = false, // true でチェーン全体スキップ(buf 不変)
            // delay(feedback)
            delay_time_s: f32 = 0.25,
            delay_feedback: f32 = 0.3, // 0..0.99
            delay_mix: f32 = 0.0,
            // chorus
            chorus_rate: f32 = 0.8, // Hz
            chorus_depth_ms: f32 = 3.0,
            chorus_mix: f32 = 0.0,
            // distortion
            dist_drive: f32 = 1.0, // >=1 で歪み増
            dist_mix: f32 = 0.0,
        };

        params_db: params.DoubleBuffer(Params),
        sample_rate: f32,
        delay: [2]dsp.DelayLine(delay_cap) = .{ .{}, .{} }, // L/R
        chorus: [2]dsp.DelayLine(chorus_cap) = .{ .{}, .{} }, // L/R
        lfo: [2]dsp.Lfo = .{ .{}, .{ .phase = 0.25 } }, // R を 1/4 位相オフセット(ステレオ幅)

        const chorus_base_ms: f32 = 12.0; // コーラスの基準ディレイ

        pub fn init(sample_rate: f32, initial: Params) Self {
            return .{
                .params_db = params.DoubleBuffer(Params).init(initial),
                .sample_rate = sample_rate,
            };
        }

        /// GUI スレッド: パラメータを公開。
        pub fn publishParams(self: *Self, p: Params) void {
            self.params_db.publish(p);
        }

        /// RT スレッド: buf を in-place 処理。確保/ロックなし。
        pub fn process(self: *Self, buf: []f32, frames: u32, channels: u32) void {
            const p = self.params_db.current();
            if (p.bypass) return; // master bypass: buf 不変

            // process 冒頭で全 Params を clamp(GUI 以外/将来コードからの publish にも頑健に)。
            const fb = std.math.clamp(p.delay_feedback, 0.0, 0.99); // 発散防止
            const dmix = std.math.clamp(p.delay_mix, 0.0, 1.0);
            const cmix = std.math.clamp(p.chorus_mix, 0.0, 1.0);
            const distmix = std.math.clamp(p.dist_mix, 0.0, 1.0);
            const drive = @max(p.dist_drive, 0.0);
            const crate = @max(p.chorus_rate, 0.0);
            const cdepth_ms = @max(p.chorus_depth_ms, 0.0);
            const dtime_s = @max(p.delay_time_s, 0.0);

            const sr = self.sample_rate;
            const delay_samples = std.math.clamp(dtime_s * sr, 1.0, @as(f32, @floatFromInt(delay_cap - 1)));
            const chorus_base = chorus_base_ms * 0.001 * sr;
            const chorus_depth = cdepth_ms * 0.001 * sr;

            const ch_count = @min(channels, 2);
            var i: u32 = 0;
            while (i < frames) : (i += 1) {
                var ch: u32 = 0;
                while (ch < ch_count) : (ch += 1) {
                    const idx = i * channels + ch;
                    var x = buf[idx];

                    // 1) distortion: drive 後ソフトクリップを mix(dry とクロスフェード)
                    if (distmix > 0.0) {
                        x = x * (1.0 - distmix) + dsp.softClip(x * drive) * distmix;
                    }

                    // 2) chorus: 変調した短ディレイ(base + depth*lfo)を補間読み出し。
                    //    mix=0 でも lfo/ライン状態は進める(後で mix を上げた時のクリック回避)。
                    const lfo_v = self.lfo[ch].next(crate, sr); // -1..1
                    if (cmix > 0.0) {
                        // base±depth を有効遅延域 [1, chorus_cap-1] に明示クランプ(高サンプルレート/大 depth で張り付かせない)
                        const mod = std.math.clamp(chorus_base + chorus_depth * lfo_v, 1.0, @as(f32, @floatFromInt(chorus_cap - 1)));
                        const wet = self.chorus[ch].readAt(mod); // read 先(write 前)
                        self.chorus[ch].write(x);
                        x = x * (1.0 - cmix) + wet * cmix;
                    } else {
                        self.chorus[ch].write(x);
                    }

                    // 3) delay(feedback): read 先 → 入力+帰還を write(denormal を 0 に丸める)
                    const dly = self.delay[ch].readAt(delay_samples);
                    self.delay[ch].write(dsp.flushDenormal(x + dly * fb));
                    x = x * (1.0 - dmix) + dly * dmix;

                    buf[idx] = x;
                }
            }
        }
    };
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

// chorus_base(12ms≈576サンプル@48k)+depth が収まるよう実機同等の容量を使う。
const TestFx = MasterEffects(2048, 2048);

test "MasterEffects: bypass leaves buffer unchanged" {
    var fx = TestFx.init(48000, .{
        .bypass = true,
        .delay_mix = 1.0, // bypass なので効かないはず
        .dist_mix = 1.0,
        .chorus_mix = 1.0,
    });
    var buf = [_]f32{ 0.1, -0.2, 0.3, -0.4, 0.5, -0.6, 0.7, -0.8 };
    const orig = buf;
    fx.process(&buf, 4, 2);
    try testing.expectEqualSlices(f32, &orig, &buf);
}

test "MasterEffects: delay produces echoes at delay_samples with decaying feedback" {
    // delay_samples = 4(delay_time_s = 4/sr), feedback 0.5, dmix 1.0(wet のみ)。mono。
    var fx = TestFx.init(48000, .{
        .delay_time_s = 4.0 / 48000.0,
        .delay_feedback = 0.5,
        .delay_mix = 1.0,
    });
    var buf = [_]f32{0} ** 16;
    buf[0] = 1.0; // インパルス
    fx.process(&buf, 16, 1);
    // 4 サンプル後にエコー、以降 4 ごとに 0.5 倍で減衰
    try testing.expectApproxEqAbs(@as(f32, 1.0), buf[4], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), buf[8], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.25), buf[12], 1e-5);
    // エコー前は無音
    try testing.expectApproxEqAbs(@as(f32, 0.0), buf[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), buf[3], 1e-6);
}

test "MasterEffects: chorus alters signal and creates L/R difference" {
    var fx = TestFx.init(48000, .{ .chorus_rate = 15.0, .chorus_depth_ms = 1.0, .chorus_mix = 0.7 });
    const frames = 4096;
    var buf: [frames * 2]f32 = undefined;
    // 同一の正弦を L/R に入れる
    var i: usize = 0;
    while (i < frames) : (i += 1) {
        const s = @sin(2.0 * std.math.pi * 600.0 * @as(f32, @floatFromInt(i)) / 48000.0);
        buf[i * 2] = s;
        buf[i * 2 + 1] = s;
    }
    var input: [frames * 2]f32 = undefined;
    @memcpy(&input, &buf);
    fx.process(&buf, frames, 2);
    // (a) chorus でドライ入力から変化している
    var differs_from_input = false;
    // (b) L/R が相違する箇所がある(lfo 位相オフセット + 変調)
    var lr_differs = false;
    i = 0;
    while (i < frames) : (i += 1) {
        if (@abs(buf[i * 2] - input[i * 2]) > 1e-3) differs_from_input = true;
        if (@abs(buf[i * 2] - buf[i * 2 + 1]) > 1e-3) lr_differs = true;
    }
    try testing.expect(differs_from_input);
    try testing.expect(lr_differs);
}

test "MasterEffects: distortion (mix=1) saturates large input into (-1,1)" {
    var fx = TestFx.init(48000, .{ .dist_drive = 10.0, .dist_mix = 1.0 });
    const frames = 512;
    var buf: [frames]f32 = undefined;
    var peak: f32 = 0;
    var i: usize = 0;
    while (i < frames) : (i += 1) {
        buf[i] = @sin(2.0 * std.math.pi * 200.0 * @as(f32, @floatFromInt(i)) / 48000.0); // amp 1
    }
    fx.process(&buf, frames, 1);
    for (buf) |s| peak = @max(peak, @abs(s));
    try testing.expect(peak < 1.0); // 有界
    try testing.expect(peak > 0.8); // 飽和(殺してはいない)
}

test "MasterEffects: all stages on stays finite over many frames" {
    var fx = TestFx.init(48000, .{
        .delay_time_s = 30.0 / 48000.0,
        .delay_feedback = 0.8,
        .delay_mix = 0.5,
        .chorus_rate = 5.0,
        .chorus_depth_ms = 2.0,
        .chorus_mix = 0.5,
        .dist_drive = 5.0,
        .dist_mix = 0.5,
    });
    var buf: [256]f32 = undefined;
    var block: u32 = 0;
    while (block < 200) : (block += 1) {
        var i: usize = 0;
        while (i < 128) : (i += 1) {
            const s = @sin(2.0 * std.math.pi * 440.0 * @as(f32, @floatFromInt(block * 128 + @as(u32, @intCast(i)))) / 48000.0) * 0.5;
            buf[i * 2] = s;
            buf[i * 2 + 1] = s;
        }
        fx.process(&buf, 128, 2);
        for (buf[0 .. 128 * 2]) |v| try testing.expect(std.math.isFinite(v));
    }
}
