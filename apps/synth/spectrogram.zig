//! スペクトログラム解析・描画（メインスレッド専用、TASK-27.8）。
//!
//! mono サンプルを溜めて FFT_SIZE 毎に Hann+FFT し、振幅を時間×周波数の列として蓄積。
//! framebuffer の指定領域にヒートマップ（左=古い, 右=新しい / 下=低域, 上=高域）で描画する。

const std = @import("std");
const dsp = @import("dsp");

pub const FFT_SIZE: usize = 512;
pub const N_BINS: usize = FFT_SIZE / 2;

/// `width` 時間列 × `height` 周波数行のスペクトログラム。サイズが大きいので heap 確保推奨。
pub fn Spectrogram(comptime width: usize, comptime height: usize) type {
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

        pub fn init(self: *Self) void {
            self.accum_len = 0;
            self.head = 0;
            self.filled = 0;
            @memset(&self.cols, 0);
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
                // 下(row 0)=低域, 上=高域。表示行を周波数ビンへマップ。
                const bin = row * N_BINS / height;
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
    // dB 換算して [-60,0]dB を 0..255 にマップ
    const db = 20.0 * std.math.log10(mag + 1e-9);
    const norm = std.math.clamp((db + 60.0) / 60.0, 0.0, 1.0);
    return @intFromFloat(norm * 255.0);
}

fn intensityColor(v: u8) u32 {
    // 黒→青→シアン→白 のヒート風ランプ（RGBA8888 = 0xRRGGBBAA）
    const r: u32 = if (v > 128) @as(u32, (v - 128)) * 2 else 0;
    const g: u32 = v;
    const b: u32 = @min(255, 64 + @as(u32, v) * 2);
    return (r << 24) | (g << 16) | (b << 8) | 0xFF;
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "Spectrogram: feed produces columns and a tone lights a band" {
    const Spec = Spectrogram(16, 64);
    var spec: Spec = undefined;
    spec.init();
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

    // 直近列のどこかが点灯している（無音でない）
    const last_col = (spec.head + 16 - 1) % 16;
    var lit = false;
    var row: usize = 0;
    while (row < 64) : (row += 1) {
        if (spec.cols[last_col * 64 + row] > 0) lit = true;
    }
    try testing.expect(lit);
}

test "magToIntensity: silence -> 0, loud -> high" {
    try testing.expectEqual(@as(u8, 0), magToIntensity(0.0));
    try testing.expect(magToIntensity(1.0) > 200);
}
