//! ビットクラッシャ: bit 深度量子化 + サンプルレート低減(S&H ダウンサンプル)。lofi の主役。
//! RT 安全(算術 + 分岐のみ・確保/ロックなし)。

const std = @import("std");

pub const Bitcrush = struct {
    bit_depth: u8 = 8, // 1..16 に clamp
    hold_samples: u32 = 4, // S&H 保持サンプル数(>=1)。大きいほど SR 低下
    wet: f32 = 1.0,
    counter: u32 = 0,
    held: f32 = 0,

    /// 1 サンプル処理。
    pub fn process(self: *Bitcrush, x: f32) f32 {
        const in = if (std.math.isFinite(x)) x else 0.0;
        const bits: u8 = std.math.clamp(self.bit_depth, 1, 16);
        const hold: u32 = @max(self.hold_samples, 1);
        if (self.counter == 0) {
            const shift: u5 = @intCast(bits);
            const levels: f32 = @floatFromInt((@as(u32, 1) << shift) - 1);
            const clamped = std.math.clamp(in, -1.0, 1.0);
            // [-1,1] -> [0,1] -> levels で量子化 -> [-1,1]
            const q = @round((clamped * 0.5 + 0.5) * levels) / levels;
            self.held = q * 2.0 - 1.0;
        }
        self.counter += 1;
        if (self.counter >= hold) self.counter = 0;
        const w = std.math.clamp(self.wet, 0.0, 1.0);
        const out = in * (1.0 - w) + self.held * w;
        return if (std.math.isFinite(out)) out else 0.0;
    }
};

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "Bitcrush: low bit depth stairsteps the signal (few distinct levels)" {
    var bc = Bitcrush{ .bit_depth = 2, .hold_samples = 1, .wet = 1.0 };
    var seen = [_]bool{false} ** 8;
    var distinct: u32 = 0;
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        const x = @as(f32, @floatFromInt(i)) / 200.0 * 2.0 - 1.0; // -1..1 ramp
        const y = bc.process(x);
        // bit_depth=2 -> levels=3 -> 4 段(0,1/3,2/3,1)->[-1,1]
        const idx: usize = @intFromFloat(@round((std.math.clamp(y, -1.0, 1.0) * 0.5 + 0.5) * 3.0));
        if (idx < seen.len and !seen[idx]) {
            seen[idx] = true;
            distinct += 1;
        }
    }
    try testing.expect(distinct <= 4); // 連続でなく段階化されている
    try testing.expect(distinct >= 2);
}

test "Bitcrush: hold_samples holds value across samples (sample-rate reduction)" {
    var bc = Bitcrush{ .bit_depth = 16, .hold_samples = 4, .wet = 1.0 };
    var prev = bc.process(0.5);
    var held_runs: u32 = 0;
    var i: u32 = 0;
    while (i < 12) : (i += 1) {
        const y = bc.process(@as(f32, @floatFromInt(i)) / 12.0);
        if (y == prev) held_runs += 1;
        prev = y;
    }
    try testing.expect(held_runs > 0); // 保持区間がある
}

test "Bitcrush: NaN/Inf input stays finite; deterministic" {
    var a = Bitcrush{};
    var b = Bitcrush{};
    const nan = std.math.nan(f32);
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const x: f32 = if (i % 7 == 0) nan else @sin(@as(f32, @floatFromInt(i)) * 0.1);
        const ya = a.process(x);
        const yb = b.process(x);
        try testing.expect(std.math.isFinite(ya));
        try testing.expectEqual(ya, yb); // 決定的
    }
}
