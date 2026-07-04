//! オシロスコープ + ピーク/RMS レベルメータ(メインスレッド専用の可視化、TASK-27.16)。
//!
//! 出力タップ(27.8)→ mono downmix したサンプルを `feed` で供給し、framebuffer の指定領域へ描画する。
//! spectrogram.zig と同じ流儀(解析+描画を 1 ファイル、ロジックを単体テスト)。RT スレッドには関与しない。

const std = @import("std");

// framebuffer のピクセル packing(gui.Color と同じ: メモリ B,G,R,A = u32 0xAARRGGBB)。
inline fn rgba(r: u8, g: u8, b: u8, a: u8) u32 {
    return @as(u32, b) | (@as(u32, g) << 8) | (@as(u32, r) << 16) | (@as(u32, a) << 24);
}

const bg_color = rgba(0x08, 0x10, 0x10, 0xFF);
const grid_color = rgba(0x24, 0x40, 0x40, 0xFF);
const frame_color = rgba(0x40, 0x60, 0x60, 0xFF);
const trace_color = rgba(0x40, 0xFF, 0x80, 0xFF);
const rms_color = rgba(0x30, 0xC0, 0x60, 0xFF);
const peak_color = rgba(0xFF, 0xD0, 0x40, 0xFF);
const hold_color = rgba(0xFF, 0x40, 0x40, 0xFF);

fn putPixel(pixels: []u32, fb_w: usize, fb_h: usize, x: usize, y: usize, c: u32) void {
    if (x >= fb_w or y >= fb_h) return;
    pixels[y * fb_w + x] = c;
}

/// 列 x の ya..yb(両端含む)を縦線で塗る。
fn vline(pixels: []u32, fb_w: usize, fb_h: usize, x: usize, ya: usize, yb: usize, c: u32) void {
    const lo = @min(ya, yb);
    const hi = @max(ya, yb);
    var y = lo;
    while (y <= hi) : (y += 1) putPixel(pixels, fb_w, fb_h, x, y, c);
}

/// (x0,y0) 左上 w×h を bg で塗り、枠を frame で描く。
fn fillFramedRect(pixels: []u32, fb_w: usize, fb_h: usize, x0: usize, y0: usize, w: usize, h: usize) void {
    var yy: usize = 0;
    while (yy < h) : (yy += 1) {
        var xx: usize = 0;
        while (xx < w) : (xx += 1) {
            const on_border = (xx == 0 or xx == w - 1 or yy == 0 or yy == h - 1);
            putPixel(pixels, fb_w, fb_h, x0 + xx, y0 + yy, if (on_border) frame_color else bg_color);
        }
    }
}

/// 線形振幅(0..)を -60..0 dBFS の 0..1 へマップ(無音=log10(0) 回避の epsilon 付き)。
pub fn linearToMeter(v: f32) f32 {
    return std.math.clamp((20.0 * std.math.log10(@max(v, 1e-6)) + 60.0) / 60.0, 0.0, 1.0);
}

const RING_CAP: usize = 2048; // 直近サンプルのリング容量(2 の冪)

/// `width`×`height` のオシロスコープ。直近サンプルをリングに保持し、立ち上がりゼロ交差トリガで描画。
pub fn Oscilloscope(comptime width: usize, comptime height: usize) type {
    if (width > RING_CAP) @compileError("Oscilloscope width must be <= RING_CAP");
    if (width < 2 or height < 2) @compileError("Oscilloscope needs width>=2, height>=2");
    return struct {
        const Self = @This();

        ring: [RING_CAP]f32 = [_]f32{0} ** RING_CAP,
        wpos: usize = 0, // 書き込んだ総サンプル数(単調増加)

        pub fn reset(self: *Self) void {
            @memset(&self.ring, 0);
            self.wpos = 0;
        }

        pub fn feed(self: *Self, mono: []const f32) void {
            for (mono) |s| {
                self.ring[self.wpos % RING_CAP] = s;
                self.wpos += 1;
            }
        }

        fn sampleAt(self: *const Self, a: usize) f32 {
            return self.ring[a % RING_CAP];
        }

        /// 描画開始の絶対インデックス。[oldest, wpos-width] の範囲で最も新しい立ち上がりゼロ交差。
        /// 無ければ wpos-width(直近 width サンプル)。width サンプル後続を保証。
        pub fn findTrigger(self: *const Self) usize {
            if (self.wpos < width) return 0; // まだ width 揃わない
            const filled = @min(self.wpos, RING_CAP);
            const oldest = self.wpos - filled;
            const newest_start = self.wpos - width;
            var t = newest_start;
            while (t > oldest) : (t -= 1) {
                if (self.sampleAt(t - 1) < 0.0 and self.sampleAt(t) >= 0.0) return t;
            }
            return newest_start;
        }

        pub fn draw(self: *const Self, pixels: []u32, fb_w: usize, fb_h: usize, x0: usize, y0: usize) void {
            fillFramedRect(pixels, fb_w, fb_h, x0, y0, width, height);
            const half: usize = (height - 1) / 2;
            const center_y = y0 + half;
            // 中央線(grid)
            var gx: usize = 1;
            while (gx < width - 1) : (gx += 1) putPixel(pixels, fb_w, fb_h, x0 + gx, center_y, grid_color);
            // 波形トレース
            const start = self.findTrigger();
            const halff: f32 = @floatFromInt(half);
            var prev_y: ?usize = null;
            var x: usize = 0;
            while (x < width) : (x += 1) {
                const s = std.math.clamp(self.sampleAt(start + x), -1.0, 1.0);
                const off: i32 = @intFromFloat(@round(s * halff));
                var yi: i32 = @as(i32, @intCast(center_y)) - off;
                yi = std.math.clamp(yi, @as(i32, @intCast(y0)), @as(i32, @intCast(y0 + height - 1)));
                const y: usize = @intCast(yi);
                const px = x0 + x;
                if (prev_y) |py| vline(pixels, fb_w, fb_h, px, py, y, trace_color) else putPixel(pixels, fb_w, fb_h, px, y, trace_color);
                prev_y = y;
            }
        }
    };
}

/// ピーク / RMS レベルメータ。`feed` でブロック毎に更新(アタック即時・リリース減衰)。
pub const LevelMeter = struct {
    disp_peak: f32 = 0,
    disp_rms: f32 = 0,
    hold: f32 = 0, // ピークホールド(より遅い減衰)

    const release: f32 = 0.85; // 1 feed あたりの減衰率(RT 非関与の可視化なので feed 回数依存で割り切り)
    const hold_release: f32 = 0.99;

    pub fn reset(self: *LevelMeter) void {
        self.* = .{};
    }

    pub fn feed(self: *LevelMeter, mono: []const f32) void {
        var pk: f32 = 0;
        var sumsq: f32 = 0;
        for (mono) |s| {
            pk = @max(pk, @abs(s));
            sumsq += s * s;
        }
        const rms = if (mono.len > 0) @sqrt(sumsq / @as(f32, @floatFromInt(mono.len))) else 0;
        // アタック即時(max)、リリースは前値を release 倍して減衰
        self.disp_peak = @max(pk, self.disp_peak * release);
        self.disp_rms = @max(rms, self.disp_rms * release);
        self.hold = @max(pk, self.hold * hold_release);
    }

    pub fn draw(self: *const LevelMeter, pixels: []u32, fb_w: usize, fb_h: usize, x0: usize, y0: usize, w: usize, h: usize) void {
        fillFramedRect(pixels, fb_w, fb_h, x0, y0, w, h);
        const inner_h = h - 2; // 枠の内側の高さ
        const bottom_y = y0 + h - 2; // バーの底(枠の内側)
        // ピーク(明)を底から上端まで、その上に RMS(濃)を重ねる。下=無音/-60dB、上=0dBFS。
        drawBar(pixels, fb_w, fb_h, x0, w, bottom_y, inner_h, linearToMeter(self.disp_peak), peak_color);
        drawBar(pixels, fb_w, fb_h, x0, w, bottom_y, inner_h, linearToMeter(self.disp_rms), rms_color);
        // ピークホールドの水平マーカ(レベル 0 のときは描かない)
        const hold_f = filledPixels(linearToMeter(self.hold), inner_h);
        if (hold_f > 0) {
            const hy = bottom_y - (hold_f - 1);
            var hx: usize = 1;
            while (hx < w - 1) : (hx += 1) putPixel(pixels, fb_w, fb_h, x0 + hx, hy, hold_color);
        }
    }

    // 正規化レベル(0..1)を inner_h ピクセル中の塗り高さに(0=無音→0px)。
    fn filledPixels(n: f32, inner_h: usize) usize {
        const f: usize = @intFromFloat(@round(n * @as(f32, @floatFromInt(inner_h))));
        return @min(f, inner_h);
    }

    // 底 bottom_y から filled ピクセルぶん上に縦バーを描く(filled=0 なら何も描かない)。
    fn drawBar(pixels: []u32, fb_w: usize, fb_h: usize, x0: usize, w: usize, bottom_y: usize, inner_h: usize, n: f32, color: u32) void {
        const f = filledPixels(n, inner_h);
        if (f == 0) return;
        const top = bottom_y - (f - 1);
        var xx: usize = 1;
        while (xx < w - 1) : (xx += 1) vline(pixels, fb_w, fb_h, x0 + xx, top, bottom_y, color);
    }
};

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "linearToMeter: -inf->0, 0dB->1, -60dB->0, monotonic" {
    try testing.expectApproxEqAbs(@as(f32, 0.0), linearToMeter(0.0), 1e-6); // 無音 → 0(clamp)
    try testing.expectApproxEqAbs(@as(f32, 1.0), linearToMeter(1.0), 1e-6); // 0dBFS → 1
    try testing.expectApproxEqAbs(@as(f32, 0.0), linearToMeter(0.001), 1e-3); // -60dB → ~0
    try testing.expect(linearToMeter(0.5) < linearToMeter(1.0));
    try testing.expect(linearToMeter(0.1) < linearToMeter(0.5));
}

test "LevelMeter: constant 0.5 -> peak~0.5 rms~0.5; silence decays" {
    var m = LevelMeter{};
    const block = [_]f32{0.5} ** 64;
    m.feed(&block);
    try testing.expectApproxEqAbs(@as(f32, 0.5), m.disp_peak, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), m.disp_rms, 1e-4);
    // 無音を流し続けると減衰して 0 に近づく
    const silence = [_]f32{0} ** 64;
    var i: u32 = 0;
    while (i < 50) : (i += 1) m.feed(&silence);
    try testing.expect(m.disp_peak < 0.05);
    try testing.expect(m.disp_rms < 0.05);
}

test "LevelMeter: full-scale sine -> peak~1, rms~0.707" {
    var m = LevelMeter{};
    var block: [1024]f32 = undefined;
    for (&block, 0..) |*s, i| s.* = @sin(2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / 64.0);
    m.feed(&block);
    try testing.expectApproxEqAbs(@as(f32, 1.0), m.disp_peak, 0.02);
    try testing.expectApproxEqAbs(@as(f32, 0.707), m.disp_rms, 0.02);
}

test "Oscilloscope: feed stores samples and trigger finds rising zero crossing" {
    const Scope = Oscilloscope(64, 32);
    var sc = Scope{};
    // 1 周期 = 64 サンプルの正弦を十分供給(>= width)
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const s = @sin(2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / 64.0);
        sc.feed(&[_]f32{s});
    }
    const t = sc.findTrigger();
    // トリガ位置は立ち上がりゼロ交差(prev<0, cur>=0)で、width サンプル後続できる
    try testing.expect(sc.sampleAt(t -% 1) < 0.0 and sc.sampleAt(t) >= 0.0);
    try testing.expect(t <= sc.wpos - 64);
}

test "Oscilloscope: draw renders a non-empty trace into the region" {
    const Scope = Oscilloscope(40, 24);
    var sc = Scope{};
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const s = @sin(2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / 40.0) * 0.8;
        sc.feed(&[_]f32{s});
    }
    const fb_w = 48;
    const fb_h = 32;
    var pixels = [_]u32{0} ** (fb_w * fb_h);
    sc.draw(&pixels, fb_w, fb_h, 2, 2);
    // トレース色のピクセルが描かれている
    var found_trace = false;
    for (pixels) |p| {
        if (p == trace_color) found_trace = true;
    }
    try testing.expect(found_trace);
}

test "LevelMeter: draw renders bars into the region" {
    var m = LevelMeter{};
    // 正弦(peak~1 > rms~0.707)で peak バーが rms バーの上に見える(定数だと peak==rms で隠れる)
    var block: [1024]f32 = undefined;
    for (&block, 0..) |*s, i| s.* = @sin(2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / 64.0);
    m.feed(&block);
    const fb_w = 16;
    const fb_h = 40;
    var pixels = [_]u32{0} ** (fb_w * fb_h);
    m.draw(&pixels, fb_w, fb_h, 1, 1, 12, 38);
    var found_rms = false;
    var found_peak = false;
    for (pixels) |p| {
        if (p == rms_color) found_rms = true;
        if (p == peak_color) found_peak = true; // peak > rms なので上端に残る
    }
    try testing.expect(found_rms);
    try testing.expect(found_peak);
}

test "LevelMeter: silence draws no bars/marker (level 0 -> nothing)" {
    const m = LevelMeter{}; // 無音(disp_peak/rms/hold = 0)
    const fb_w = 16;
    const fb_h = 40;
    var pixels = [_]u32{0} ** (fb_w * fb_h);
    m.draw(&pixels, fb_w, fb_h, 1, 1, 12, 38);
    for (pixels) |p| {
        try testing.expect(p != rms_color);
        try testing.expect(p != peak_color);
        try testing.expect(p != hold_color);
    }
}

test "Oscilloscope: findTrigger picks the most recent rising zero crossing in range" {
    const Scope = Oscilloscope(8, 16);
    var sc = Scope{};
    // 立ち上がりゼロ交差(prev<0, cur>=0)を index 4 と 7 に作り、末尾に width=8 ぶん後続を確保。
    const pattern = [_]f32{ -1, 1, 1, -1, 1, 1, -1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };
    sc.feed(&pattern);
    // wpos=20, width=8 → newest_start=12。[0,12] 内で最新の交差は index 7。
    const t = sc.findTrigger();
    try testing.expectEqual(@as(usize, 7), t);
    try testing.expect(sc.sampleAt(t - 1) < 0.0 and sc.sampleAt(t) >= 0.0);
}
