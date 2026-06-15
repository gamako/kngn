//! スペクトログラム解析・描画（メインスレッド専用、TASK-27.8 / 対数軸・ラベル・カラーマップ改良 27.17）。
//!
//! mono サンプルを溜めて FFT_SIZE 毎に Hann+FFT し、振幅を時間×周波数の列として蓄積。
//! framebuffer の指定領域にヒートマップ（左=古い, 右=新しい / 下=低域, 上=高域）で描画する。
//! 周波数軸は **対数**(低域が縦に広く見える)。配色は magma 風ランプ。Hz/dB ラベルは apps 側が描画する。

const std = @import("std");
const dsp = @import("dsp");

pub const FFT_SIZE: usize = 512;
pub const N_BINS: usize = FFT_SIZE / 2;
pub const DB_FLOOR: f32 = -60.0; // 強度マップ/凡例の下限 dBFS

/// `width` 時間列 × `height` 周波数行のスペクトログラム。サイズが大きいので heap 確保推奨。
pub fn Spectrogram(comptime width: usize, comptime height: usize) type {
    if (height < 2) @compileError("Spectrogram height must be >= 2");
    return struct {
        const Self = @This();

        accum: [FFT_SIZE]f32 = undefined,
        accum_len: usize = 0,
        scratch_re: [FFT_SIZE]f32 = undefined,
        scratch_im: [FFT_SIZE]f32 = undefined,
        mags: [N_BINS]f32 = undefined,

        cols: [width * height]u8 = undefined, // intensity（init() で 0 クリア）
        head: usize = 0, // 次に書く列（リング）
        filled: usize = 0,

        // 対数周波数軸(setSampleRate で算出)
        sample_rate: f32 = 48000,
        f_min: f32 = 50,
        f_max: f32 = 24000,
        row_bin: [height]usize = undefined, // 表示行(0=低域) → FFT bin

        pub fn init(self: *Self, sample_rate: f32) void {
            self.accum_len = 0;
            self.head = 0;
            self.filled = 0;
            @memset(&self.cols, 0);
            self.setSampleRate(sample_rate);
        }

        /// サンプルレートを設定し、行→bin の対数マッピングを再計算する(audio.open 後・start 前に呼ぶ)。
        pub fn setSampleRate(self: *Self, sample_rate: f32) void {
            self.sample_rate = sample_rate;
            const bin_hz = sample_rate / @as(f32, @floatFromInt(FFT_SIZE));
            self.f_min = @max(bin_hz, 50.0); // 最低ビン(=bin_hz)未満は意味がない。ゼロ割回避
            self.f_max = sample_rate * 0.5; // ナイキスト(ラベル範囲用の理論上限)
            const ratio = self.f_max / self.f_min;
            const denom: f32 = @floatFromInt(height - 1);
            for (0..height) |r| {
                const frac = @as(f32, @floatFromInt(r)) / denom; // 0..1(0=低域)
                const freq = self.f_min * std.math.pow(f32, ratio, frac);
                const bin: usize = @intFromFloat(@round(freq / bin_hz));
                self.row_bin[r] = std.math.clamp(bin, 1, N_BINS - 1);
            }
        }

        /// 周波数 freq の描画行(上端からのオフセット, 0=上/高域)。範囲外は null。
        /// 描画は py = y0 + (height-1-row) なので offset = height-1-row。
        pub fn rowOffsetForFreq(self: *const Self, freq: f32) ?usize {
            if (freq < self.f_min or freq > self.f_max) return null;
            const frac = @log(freq / self.f_min) / @log(self.f_max / self.f_min); // 0..1
            const r: usize = @min(@as(usize, @intFromFloat(@round(frac * @as(f32, @floatFromInt(height - 1))))), height - 1);
            return (height - 1) - r;
        }

        pub fn freqMin(self: *const Self) f32 {
            return self.f_min;
        }
        pub fn freqMax(self: *const Self) f32 {
            return self.f_max;
        }

        /// mono サンプルを供給。FFT_SIZE 溜まるごとに 1 列計算する。
        pub fn feed(self: *Self, mono: []const f32) void {
            var i: usize = 0;
            while (i < mono.len) {
                const take = @min(FFT_SIZE - self.accum_len, mono.len - i);
                @memcpy(self.accum[self.accum_len .. self.accum_len + take], mono[i .. i + take]);
                self.accum_len += take;
                i += take;
                if (self.accum_len == FFT_SIZE) {
                    self.computeColumn();
                    self.accum_len = 0;
                }
            }
        }

        fn computeColumn(self: *Self) void {
            dsp.magnitudeSpectrum(&self.accum, &self.scratch_re, &self.scratch_im, &self.mags);
            const base = self.head * height;
            var row: usize = 0;
            while (row < height) : (row += 1) {
                // 下(row 0)=低域, 上=高域。対数マッピングで表示行を周波数ビンへ。
                const bin = self.row_bin[row];
                const mag = self.mags[bin] / @as(f32, FFT_SIZE); // 正規化
                self.cols[base + row] = magToIntensity(mag);
            }
            self.head = (self.head + 1) % width;
            if (self.filled < width) self.filled += 1;
        }

        /// framebuffer(`pixels`, 横幅 `fb_w`) の (x0,y0) を左上に width×height で描画。
        pub fn draw(self: *const Self, pixels: []u32, fb_w: usize, fb_h: usize, x0: usize, y0: usize) void {
            var cx: usize = 0;
            while (cx < self.filled) : (cx += 1) {
                // 古い列→左、新しい列→右
                const col = (self.head + width - self.filled + cx) % width;
                const base = col * height;
                const px = x0 + cx;
                if (px >= fb_w) break;
                var row: usize = 0;
                while (row < height) : (row += 1) {
                    const py = y0 + (height - 1 - row); // 低域を下に
                    if (py >= fb_h) continue;
                    pixels[py * fb_w + px] = intensityColor(self.cols[base + row]);
                }
            }
        }
    };
}

fn magToIntensity(mag: f32) u8 {
    // dB 換算して [DB_FLOOR, 0]dB を 0..255 にマップ
    const db = 20.0 * std.math.log10(mag + 1e-9);
    const norm = std.math.clamp((db - DB_FLOOR) / (-DB_FLOOR), 0.0, 1.0);
    return @intFromFloat(norm * 255.0);
}

// magma 風カラーランプの stop(黒→紫→赤→橙→黄白)。
const color_stops = [_][3]u8{
    .{ 0, 0, 0 },
    .{ 60, 12, 80 },
    .{ 170, 30, 70 },
    .{ 245, 120, 30 },
    .{ 255, 255, 180 },
};

fn lerpU8(a: u8, b: u8, t: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return @intFromFloat(@round(af + (bf - af) * t));
}

/// 強度 v(0..255) → framebuffer 形式 0xAABBGGRR(u32 = r|g<<8|b<<16|a<<24)。
/// magma 風(黒→紫→赤→橙→黄白)。凡例描画でも同じ配色を使えるよう pub。
pub fn intensityColor(v: u8) u32 {
    const n_seg = color_stops.len - 1; // 4 区間
    const seg_f = @as(f32, @floatFromInt(v)) / 255.0 * @as(f32, @floatFromInt(n_seg)); // 0..4
    var seg: usize = @intFromFloat(seg_f);
    if (seg >= n_seg) seg = n_seg - 1;
    const t = seg_f - @as(f32, @floatFromInt(seg));
    const a = color_stops[seg];
    const b = color_stops[seg + 1];
    const r: u32 = lerpU8(a[0], b[0], t);
    const g: u32 = lerpU8(a[1], b[1], t);
    const bl: u32 = lerpU8(a[2], b[2], t);
    return r | (g << 8) | (bl << 16) | (@as(u32, 0xFF) << 24);
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "Spectrogram: feed produces columns and a tone lights a band" {
    const Spec = Spectrogram(16, 64);
    var spec: Spec = undefined;
    spec.init(48000);
    try testing.expectEqual(@as(usize, 0), spec.filled);

    // 周波数ビン k0 の正弦（FFT_SIZE 周期に合わせる）を数列ぶん供給
    var buf: [FFT_SIZE]f32 = undefined;
    const k0 = 64;
    var i: usize = 0;
    while (i < FFT_SIZE) : (i += 1) {
        const t: f32 = @floatFromInt(i);
        buf[i] = @sin(2.0 * std.math.pi * @as(f32, k0) * t / @as(f32, FFT_SIZE)) * 0.5;
    }
    var c: usize = 0;
    while (c < 3) : (c += 1) spec.feed(&buf);
    try testing.expectEqual(@as(usize, 3), spec.filled);

    // 直近列で最も明るい行が、k0(=64) 近傍の bin にマップされた行であること
    // (= computeColumn が row_bin を使って対数軸に正しく配置している回帰検証)。
    const last_col = (spec.head + 16 - 1) % 16;
    var max_row: usize = 0;
    var max_v: u8 = 0;
    var row: usize = 0;
    while (row < 64) : (row += 1) {
        const v = spec.cols[last_col * 64 + row];
        if (v > max_v) {
            max_v = v;
            max_row = row;
        }
    }
    try testing.expect(max_v > 0); // 点灯している
    const mapped_bin = spec.row_bin[max_row];
    try testing.expect(mapped_bin >= 60 and mapped_bin <= 68); // k0=64 近傍(リーク許容)
}

test "Spectrogram: log frequency axis (row_bin non-decreasing, low-freq emphasis)" {
    const Spec = Spectrogram(8, 64);
    var spec: Spec = undefined;
    spec.init(48000);
    // 単調非減少(低域では複数行が同 bin に丸まる)
    var prev: usize = spec.row_bin[0];
    for (spec.row_bin[1..]) |b| {
        try testing.expect(b >= prev);
        prev = b;
    }
    // 低域強調: bin <= N_BINS/8 にマップされる行数が、線形マップ時より多い
    var log_low: usize = 0;
    var lin_low: usize = 0;
    for (0..64) |r| {
        if (spec.row_bin[r] <= N_BINS / 8) log_low += 1;
        if (r * N_BINS / 64 <= N_BINS / 8) lin_low += 1;
    }
    try testing.expect(log_low > lin_low);
}

test "Spectrogram: rowOffsetForFreq maps low->bottom, high->top, out-of-range null" {
    const Spec = Spectrogram(8, 64);
    var spec: Spec = undefined;
    spec.init(48000);
    const lo = spec.rowOffsetForFreq(spec.freqMin()).?;
    const hi = spec.rowOffsetForFreq(8000).?;
    try testing.expect(lo > hi); // 低域=下(offset 大), 高域=上(offset 小)
    try testing.expect(lo <= 63 and hi <= 63);
    try testing.expect(spec.rowOffsetForFreq(10.0) == null); // f_min 未満
    try testing.expect(spec.rowOffsetForFreq(30000.0) == null); // f_max 超
}

test "magToIntensity: silence -> 0, loud -> high" {
    try testing.expectEqual(@as(u8, 0), magToIntensity(0.0));
    try testing.expect(magToIntensity(1.0) > 200);
}

test "intensityColor: black at 0, luminance increases across stops" {
    const lum = struct {
        fn f(c: u32) u32 {
            return (c & 0xFF) + ((c >> 8) & 0xFF) + ((c >> 16) & 0xFF);
        }
    };
    try testing.expectEqual(@as(u32, 0), lum.f(intensityColor(0))); // 黒
    var prev: u32 = 0;
    for ([_]u8{ 64, 128, 192, 255 }) |v| {
        const l = lum.f(intensityColor(v));
        try testing.expect(l > prev); // 輝度が概ね単調増加
        prev = l;
    }
}
