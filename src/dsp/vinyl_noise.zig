//! ビニルノイズ: 軽いヒス + ランダムな crackle インパルス（lofi の質感）。
//! 固定 seed の xorshift で決定的・RT 安全（確保/ロックなし）。入力に加算する。

const std = @import("std");
const Noise = @import("noise.zig").Noise;

pub const VinylNoise = struct {
    noise: Noise = .{ .state = 0x56494E59 }, // "VINY"
    hiss_gain: f32 = 0.003,
    crackle_gain: f32 = 0.08,
    crackle_prob: f32 = 0.00035, // 毎サンプルの crackle 発生確率
    decay: f32 = 0.92, // crackle インパルスの減衰
    impulse: f32 = 0,

    /// 1 サンプル処理（x に hiss + crackle を加算）。
    pub fn process(self: *VinylNoise, x: f32) f32 {
        const in = if (std.math.isFinite(x)) x else 0.0;
        const hiss = self.noise.next() * std.math.clamp(self.hiss_gain, 0.0, 1.0);
        const r = (self.noise.next() + 1.0) * 0.5; // 0..1
        if (r < std.math.clamp(self.crackle_prob, 0.0, 1.0)) {
            self.impulse = self.noise.next() * std.math.clamp(self.crackle_gain, 0.0, 1.0);
        }
        const out = in + hiss + self.impulse;
        self.impulse *= std.math.clamp(self.decay, 0.0, 0.999);
        return if (std.math.isFinite(out)) out else 0.0;
    }
};

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "VinylNoise: adds non-zero texture even with silent input" {
    var vn = VinylNoise{};
    var energy: f64 = 0;
    var i: u32 = 0;
    while (i < 20000) : (i += 1) {
        const y = vn.process(0.0);
        try testing.expect(std.math.isFinite(y));
        energy += @as(f64, y) * @as(f64, y);
    }
    try testing.expect(energy > 0.0); // 無音入力でも質感が乗る
}

test "VinylNoise: deterministic for fixed seed; bounded over long run" {
    var a = VinylNoise{};
    var b = VinylNoise{};
    var peak: f32 = 0;
    var i: u32 = 0;
    while (i < 50000) : (i += 1) {
        const x = @sin(@as(f32, @floatFromInt(i)) * 0.01) * 0.3;
        const ya = a.process(x);
        const yb = b.process(x);
        try testing.expectEqual(ya, yb); // 決定的
        try testing.expect(std.math.isFinite(ya));
        peak = @max(peak, @abs(ya));
    }
    try testing.expect(peak < 1.5); // 入力 0.3 + hiss/crackle で過大にならない
}
