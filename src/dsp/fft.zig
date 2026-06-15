//! FFT（基数2 反復 Cooley-Tukey）+ Hann 窓 + 振幅スペクトル。
//! スペクトログラム可視化用。**メインスレッドで実行**（RT スレッドからは呼ばない）。

const std = @import("std");

/// in-place 順方向 FFT。`re`/`im` は同長で 2 の冪。
pub fn fft(re: []f32, im: []f32) void {
    const n = re.len;
    std.debug.assert(n == im.len);
    std.debug.assert(std.math.isPowerOfTwo(n));
    if (n <= 1) return;

    // ビットリバース置換
    var j: usize = 0;
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var bit = n >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            std.mem.swap(f32, &re[i], &re[j]);
            std.mem.swap(f32, &im[i], &im[j]);
        }
    }

    // バタフライ
    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const ang = -2.0 * std.math.pi / @as(f32, @floatFromInt(len));
        const wlen_re = @cos(ang);
        const wlen_im = @sin(ang);
        var start: usize = 0;
        while (start < n) : (start += len) {
            var w_re: f32 = 1;
            var w_im: f32 = 0;
            var k: usize = 0;
            const half = len / 2;
            while (k < half) : (k += 1) {
                const a = start + k;
                const b = a + half;
                const v_re = re[b] * w_re - im[b] * w_im;
                const v_im = re[b] * w_im + im[b] * w_re;
                const u_re = re[a];
                const u_im = im[a];
                re[a] = u_re + v_re;
                im[a] = u_im + v_im;
                re[b] = u_re - v_re;
                im[b] = u_im - v_im;
                const nw_re = w_re * wlen_re - w_im * wlen_im;
                w_im = w_re * wlen_im + w_im * wlen_re;
                w_re = nw_re;
            }
        }
    }
}

/// Hann 窓を in-place で掛ける。
pub fn applyHann(buf: []f32) void {
    const n = buf.len;
    if (n <= 1) return;
    const denom: f32 = @floatFromInt(n - 1);
    for (buf, 0..) |*s, idx| {
        const t: f32 = @floatFromInt(idx);
        const w = 0.5 - 0.5 * @cos(2.0 * std.math.pi * t / denom);
        s.* *= w;
    }
}

/// 実数信号 `samples`(長さ N=2^k) に Hann 窓を掛けて FFT し、
/// 振幅スペクトル `mags[0..N/2]` を埋める。`mags.len >= samples.len/2` が必要。
/// `scratch_re`/`scratch_im` は長さ N の作業領域（呼び出し側が確保 = ここでは alloc しない）。
pub fn magnitudeSpectrum(
    samples: []const f32,
    scratch_re: []f32,
    scratch_im: []f32,
    mags: []f32,
) void {
    const n = samples.len;
    std.debug.assert(scratch_re.len == n and scratch_im.len == n);
    std.debug.assert(mags.len >= n / 2);
    for (samples, 0..) |s, idx| {
        scratch_re[idx] = s;
        scratch_im[idx] = 0;
    }
    applyHann(scratch_re);
    fft(scratch_re, scratch_im);
    var k: usize = 0;
    while (k < n / 2) : (k += 1) {
        mags[k] = @sqrt(scratch_re[k] * scratch_re[k] + scratch_im[k] * scratch_im[k]);
    }
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "fft: impulse -> flat spectrum (all ones)" {
    var re = [_]f32{ 1, 0, 0, 0, 0, 0, 0, 0 };
    var im = [_]f32{0} ** 8;
    fft(&re, &im);
    for (re) |v| try testing.expectApproxEqAbs(@as(f32, 1.0), v, 1e-5);
    for (im) |v| try testing.expectApproxEqAbs(@as(f32, 0.0), v, 1e-5);
}

test "fft: bin-aligned cosine peaks at its bin" {
    const n = 64;
    const k0 = 8; // 周波数ビン
    var re: [n]f32 = undefined;
    var im = [_]f32{0} ** n;
    var idx: usize = 0;
    while (idx < n) : (idx += 1) {
        const t: f32 = @floatFromInt(idx);
        re[idx] = @cos(2.0 * std.math.pi * @as(f32, k0) * t / @as(f32, n));
    }
    fft(&re, &im);
    // 振幅は k0 と n-k0 にピーク（各 n/2）、他はほぼ 0
    var mags: [n]f32 = undefined;
    for (0..n) |m| mags[m] = @sqrt(re[m] * re[m] + im[m] * im[m]);
    try testing.expect(mags[k0] > @as(f32, n) * 0.4);
    try testing.expect(mags[1] < 1e-2);
    try testing.expect(mags[k0 + 1] < 1e-2);
}

test "applyHann: endpoints zero, center ~1" {
    var buf = [_]f32{1} ** 8;
    applyHann(&buf);
    try testing.expectApproxEqAbs(@as(f32, 0.0), buf[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), buf[7], 1e-6);
    try testing.expect(buf[4] > 0.8);
}

test "magnitudeSpectrum: sine energy concentrates near its bin" {
    const n = 128;
    var samples: [n]f32 = undefined;
    const k0 = 16;
    var idx: usize = 0;
    while (idx < n) : (idx += 1) {
        const t: f32 = @floatFromInt(idx);
        samples[idx] = @sin(2.0 * std.math.pi * @as(f32, k0) * t / @as(f32, n));
    }
    var sre: [n]f32 = undefined;
    var sim: [n]f32 = undefined;
    var mags: [n / 2]f32 = undefined;
    magnitudeSpectrum(&samples, &sre, &sim, &mags);
    // 最大ビンが k0 近傍（窓で多少漏れる）
    var max_bin: usize = 0;
    var max_val: f32 = 0;
    for (mags, 0..) |m, bi| {
        if (m > max_val) {
            max_val = m;
            max_bin = bi;
        }
    }
    try testing.expect(max_bin >= k0 - 1 and max_bin <= k0 + 1);
}
