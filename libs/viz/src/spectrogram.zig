//! Spectrogram analysis and drawing (main-thread only; log axis / labels / colormap).
//!
//! Accumulates mono samples; every FFT_SIZE runs Hann+FFT and stores amplitude as time×frequency columns.
//! Draws a heatmap into a framebuffer region (left=older, right=newer / bottom=low, top=high).
//! Frequency axis is **logarithmic** (lows take more vertical space). Colormap is magma-like. Hz/dB labels are drawn by apps.

const std = @import("std");
const dsp = @import("dsp");

pub const FFT_SIZE: usize = 512;
pub const N_BINS: usize = FFT_SIZE / 2;
pub const DB_FLOOR: f32 = -60.0; // Lower bound dBFS for the intensity map / legend

/// Spectrogram of `width` time columns × `height` frequency rows. Prefer heap allocation; the type is large.
pub fn Spectrogram(comptime width: usize, comptime height: usize) type {
    if (height < 2) @compileError("Spectrogram height must be >= 2");
    return struct {
        const Self = @This();

        accum: [FFT_SIZE]f32 = undefined,
        accum_len: usize = 0,
        scratch_re: [FFT_SIZE]f32 = undefined,
        scratch_im: [FFT_SIZE]f32 = undefined,
        mags: [N_BINS]f32 = undefined,

        cols: [width * height]u8 = undefined, // intensity (zeroed in init())
        head: usize = 0, // Next column to write (ring)
        filled: usize = 0,

        // Frequency axis (computed in setSampleRate/setSampleRateLinear)
        sample_rate: f32 = 48000,
        f_min: f32 = 50,
        f_max: f32 = 24000,
        row_bin: [height]usize = undefined, // Display row (0=low) → FFT bin
        log_scale: bool = true, // false → linear frequency axis (default log = fully matches prior behaviour)

        pub fn init(self: *Self, sample_rate: f32) void {
            self.accum_len = 0;
            self.head = 0;
            self.filled = 0;
            @memset(&self.cols, 0);
            self.setSampleRate(sample_rate);
        }

        /// Set the sample rate and recompute the log row→bin map (call after audio.open, before start).
        pub fn setSampleRate(self: *Self, sample_rate: f32) void {
            self.log_scale = true;
            self.recomputeRowBin(sample_rate);
        }

        /// Set the sample rate and recompute the **linear** row→bin map. On a log axis, highs are
        /// compressed into few display rows (e.g. ≥16kHz at 48kHz sampling occupies only the topmost rows),
        /// so linear is better when watching a specific high band (e.g. ultrasonic alert) and you need
        /// display area proportional to bandwidth. Intended use: call after `init()` to overwrite the axis only
        /// (`init()` itself stays logarithmic for backward compatibility with existing callers).
        pub fn setSampleRateLinear(self: *Self, sample_rate: f32) void {
            self.log_scale = false;
            self.recomputeRowBin(sample_rate);
        }

        fn recomputeRowBin(self: *Self, sample_rate: f32) void {
            self.sample_rate = sample_rate;
            const bin_hz = sample_rate / @as(f32, @floatFromInt(FFT_SIZE));
            self.f_min = @max(bin_hz, 50.0); // Below the lowest bin (=bin_hz) is meaningless. Avoid division by zero
            self.f_max = sample_rate * 0.5; // Nyquist (theoretical upper bound for label range)
            const denom: f32 = @floatFromInt(height - 1);
            const ratio = self.f_max / self.f_min; // Used only when log_scale
            for (0..height) |r| {
                const frac = @as(f32, @floatFromInt(r)) / denom; // 0..1 (0=low)
                const freq = if (self.log_scale)
                    self.f_min * std.math.pow(f32, ratio, frac)
                else
                    self.f_min + frac * (self.f_max - self.f_min);
                const bin: usize = @intFromFloat(@round(freq / bin_hz));
                self.row_bin[r] = std.math.clamp(bin, 1, N_BINS - 1);
            }
        }

        /// Display-row offset for frequency freq (from the top; 0=top/high). Out of range → null.
        /// Drawing uses py = y0 + (height-1-row), so offset = height-1-row.
        pub fn rowOffsetForFreq(self: *const Self, freq: f32) ?usize {
            if (freq < self.f_min or freq > self.f_max) return null;
            const frac = if (self.log_scale)
                @log(freq / self.f_min) / @log(self.f_max / self.f_min) // 0..1
            else
                (freq - self.f_min) / (self.f_max - self.f_min);
            const r: usize = @min(@as(usize, @intFromFloat(@round(frac * @as(f32, @floatFromInt(height - 1))))), height - 1);
            return (height - 1) - r;
        }

        pub fn freqMin(self: *const Self) f32 {
            return self.f_min;
        }
        pub fn freqMax(self: *const Self) f32 {
            return self.f_max;
        }

        /// Feed mono samples. Every FFT_SIZE samples, one column is computed.
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
                // Bottom (row 0)=low, top=high. Log mapping places display rows onto frequency bins.
                const bin = self.row_bin[row];
                const mag = self.mags[bin] / @as(f32, FFT_SIZE); // Normalize
                self.cols[base + row] = magToIntensity(mag);
            }
            self.head = (self.head + 1) % width;
            if (self.filled < width) self.filled += 1;
        }

        /// Draw into framebuffer (`pixels`, width `fb_w`) with (x0,y0) as top-left of width×height.
        pub fn draw(self: *const Self, pixels: []u32, fb_w: usize, fb_h: usize, x0: usize, y0: usize) void {
            var cx: usize = 0;
            while (cx < self.filled) : (cx += 1) {
                // Older columns→left, newer→right
                const col = (self.head + width - self.filled + cx) % width;
                const base = col * height;
                const px = x0 + cx;
                if (px >= fb_w) break;
                var row: usize = 0;
                while (row < height) : (row += 1) {
                    const py = y0 + (height - 1 - row); // Lows at the bottom
                    if (py >= fb_h) continue;
                    pixels[py * fb_w + px] = intensityColor(self.cols[base + row]);
                }
            }
        }
    };
}

fn magToIntensity(mag: f32) u8 {
    // Convert to dB and map [DB_FLOOR, 0]dB onto 0..255
    const db = 20.0 * std.math.log10(mag + 1e-9);
    const norm = std.math.clamp((db - DB_FLOOR) / (-DB_FLOOR), 0.0, 1.0);
    return @intFromFloat(norm * 255.0);
}

// Magma-like color-ramp stops (black→purple→red→orange→yellow-white).
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

/// Intensity v(0..255) → framebuffer form 0xAARRGGBB (u32 = b|g<<8|r<<16|a<<24).
/// Magma-like (black→purple→red→orange→yellow-white). pub so legend drawing can share the ramp.
pub fn intensityColor(v: u8) u32 {
    const n_seg = color_stops.len - 1; // 4 segments
    const seg_f = @as(f32, @floatFromInt(v)) / 255.0 * @as(f32, @floatFromInt(n_seg)); // 0..4
    var seg: usize = @intFromFloat(seg_f);
    if (seg >= n_seg) seg = n_seg - 1;
    const t = seg_f - @as(f32, @floatFromInt(seg));
    const a = color_stops[seg];
    const b = color_stops[seg + 1];
    const r: u32 = lerpU8(a[0], b[0], t);
    const g: u32 = lerpU8(a[1], b[1], t);
    const bl: u32 = lerpU8(a[2], b[2], t);
    return bl | (g << 8) | (r << 16) | (@as(u32, 0xFF) << 24);
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

    // Feed several columns of a sine at frequency bin k0 (period matched to FFT_SIZE)
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

    // Brightest row in the newest column must map near bin k0(=64)
    // (= regression: computeColumn places energy on the log axis via row_bin).
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
    try testing.expect(max_v > 0); // Lit
    const mapped_bin = spec.row_bin[max_row];
    try testing.expect(mapped_bin >= 60 and mapped_bin <= 68); // Near k0=64 (leakage allowed)
}

test "Spectrogram: log frequency axis (row_bin non-decreasing, low-freq emphasis)" {
    const Spec = Spectrogram(8, 64);
    var spec: Spec = undefined;
    spec.init(48000);
    // Monotonic non-decreasing (several low rows can round to the same bin)
    var prev: usize = spec.row_bin[0];
    for (spec.row_bin[1..]) |b| {
        try testing.expect(b >= prev);
        prev = b;
    }
    // Low-end emphasis: more rows map to bin <= N_BINS/8 than under a linear map
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
    try testing.expect(lo > hi); // Low=bottom (large offset), high=top (small offset)
    try testing.expect(lo <= 63 and hi <= 63);
    try testing.expect(spec.rowOffsetForFreq(10.0) == null); // Below f_min
    try testing.expect(spec.rowOffsetForFreq(30000.0) == null); // Above f_max
}

test "Spectrogram: linear frequency axis (row_bin non-decreasing, fewer low-freq rows than log)" {
    const Spec = Spectrogram(8, 64);
    var log_spec: Spec = undefined;
    log_spec.init(48000); // Default = log
    var lin_spec: Spec = undefined;
    lin_spec.init(48000);
    lin_spec.setSampleRateLinear(48000); // Overwrite axis to linear only
    // Linear is also monotonic non-decreasing
    var prev: usize = lin_spec.row_bin[0];
    for (lin_spec.row_bin[1..]) |b| {
        try testing.expect(b >= prev);
        prev = b;
    }
    // Linear has no low-end emphasis: fewer rows map to bin <= N_BINS/8 than on the log axis
    var log_low: usize = 0;
    var lin_low: usize = 0;
    for (0..64) |r| {
        if (log_spec.row_bin[r] <= N_BINS / 8) log_low += 1;
        if (lin_spec.row_bin[r] <= N_BINS / 8) lin_low += 1;
    }
    try testing.expect(lin_low < log_low);
    // Linearity is pinned by the "arithmetic midpoint near vertical center" test below (rowOffsetForFreq linear).
    // Endpoints distort under clamp([1, N_BINS-1]) (at FFT_SIZE=512, f_max=24kHz clamps bin 256→255 and
    // flattens the top few rows), so equal spacing of adjacent rows does not hold across the full display.
}

test "Spectrogram: rowOffsetForFreq linear maps arithmetic mid to vertical middle" {
    const Spec = Spectrogram(8, 64);
    var spec: Spec = undefined;
    spec.init(48000);
    spec.setSampleRateLinear(48000);
    const lo = spec.rowOffsetForFreq(spec.freqMin()).?;
    const hi = spec.rowOffsetForFreq(spec.freqMax() * 0.999).?;
    try testing.expect(lo > hi); // Low=bottom (large offset), high=top (small offset)
    // Linear: arithmetic midpoint near vertical center (log: geometric midpoint at center)
    const mid_freq = (spec.freqMin() + spec.freqMax()) / 2.0;
    const mid_off = spec.rowOffsetForFreq(mid_freq).?;
    try testing.expect(mid_off >= 28 and mid_off <= 35); // height=64 → center ≈ 31
    try testing.expect(spec.rowOffsetForFreq(spec.freqMin() - 1.0) == null); // Out of range
    try testing.expect(spec.rowOffsetForFreq(30000.0) == null); // Above f_max
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
    try testing.expectEqual(@as(u32, 0), lum.f(intensityColor(0))); // Black
    var prev: u32 = 0;
    for ([_]u8{ 64, 128, 192, 255 }) |v| {
        const l = lum.f(intensityColor(v));
        try testing.expect(l > prev); // Luminance is roughly monotonic increasing
        prev = l;
    }
}
