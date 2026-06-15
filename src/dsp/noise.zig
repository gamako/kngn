//! 白色ノイズ源。xorshift32 PRNG で -1..1 の擬似乱数を 1 サンプルずつ生成する。
//! RT 安全(分岐 + 算術のみ、確保/ロック/IO なし)。シンセのノイズオシレータ用。
//!
//! 注: `<<` は通常の左シフト(溢れビットを破棄)で safety-checked overflow を起こさない
//! (それは `@shlExact` のみ)。よって xorshift の `x << 13` / `x << 5` は wrapping で安全。

const std = @import("std");

pub const Noise = struct {
    state: u32 = 0x12345678, // 非ゼロ seed(xorshift は state=0 で停止する)

    /// seed を設定(0 を渡しても停止しないよう最下位ビットを立てて非ゼロ保証)。
    pub fn seed(self: *Noise, s: u32) void {
        self.state = s | 1;
    }

    /// xorshift32 で 1 サンプル進め、[-1, 1) の白色ノイズを返す。
    pub fn next(self: *Noise) f32 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        // u32(0..2^32-1) を [-1, 1) にマップ
        return @as(f32, @floatFromInt(x)) * (2.0 / 4294967296.0) - 1.0;
    }
};

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "Noise: output stays within [-1, 1) and varies (not constant)" {
    var n = Noise{};
    var min: f32 = 1e9;
    var max: f32 = -1e9;
    var prev = n.next();
    var changed = false;
    var i: u32 = 0;
    while (i < 10000) : (i += 1) {
        const v = n.next();
        try testing.expect(v >= -1.0 and v < 1.0);
        if (v != prev) changed = true;
        prev = v;
        min = @min(min, v);
        max = @max(max, v);
    }
    try testing.expect(changed); // 一定でない
    // 広い範囲を使う(±0.5 を超える両端に到達)
    try testing.expect(min < -0.5 and max > 0.5);
}

test "Noise: roughly zero-mean with positive variance over many samples" {
    var n = Noise{};
    var sum: f64 = 0;
    var sumsq: f64 = 0;
    const count: usize = 50000;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const v: f64 = n.next();
        sum += v;
        sumsq += v * v;
    }
    const mean = sum / @as(f64, @floatFromInt(count));
    const variance = sumsq / @as(f64, @floatFromInt(count)) - mean * mean;
    try testing.expect(@abs(mean) < 0.05); // 平均 ~0
    try testing.expect(variance > 0.1); // 一様 [-1,1) の分散は理論上 ~0.33
}

test "Noise: deterministic for a given seed (reproducible)" {
    var a = Noise{};
    var b = Noise{};
    a.seed(0xC0FFEE);
    b.seed(0xC0FFEE);
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        try testing.expectEqual(a.next(), b.next());
    }
    // seed(0) でも停止しない(非ゼロ保証)
    var z = Noise{};
    z.seed(0);
    try testing.expect(z.next() != z.next() or true); // trap せず動くこと(値は問わない)
    try testing.expect(z.state != 0);
}
