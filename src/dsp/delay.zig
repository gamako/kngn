//! ディレイライン: 2 の冪固定長リングバッファ。線形補間付き遅延読み出し。
//! delay / chorus / reverb(27.15) のエフェクト基盤として再利用する。
//! 起動時に固定確保(構造体内包)し、RT スレッドでは確保/ロックなしで使う。

const std = @import("std");

/// `cap` サンプルのリングディレイ。`cap` は 2 の冪。
/// 使い方(feedback ループ): `const d = line.readAt(n); line.write(x + d*fb);`(read を write より先に)。
pub fn DelayLine(comptime cap: usize) type {
    if (!std.math.isPowerOfTwo(cap)) @compileError("DelayLine cap must be a power of two");
    if (cap < 2) @compileError("DelayLine cap must be >= 2 (readAt needs delay range [1, cap-1])");
    return struct {
        const Self = @This();
        const mask = cap - 1;

        buffer: [cap]f32 = [_]f32{0} ** cap,
        head: usize = 0, // 次に書く位置

        /// バッファと位相をクリア。
        pub fn reset(self: *Self) void {
            @memset(&self.buffer, 0);
            self.head = 0;
        }

        /// 1 サンプル書き込み、head を進める。
        pub fn write(self: *Self, x: f32) void {
            self.buffer[self.head & mask] = x;
            self.head +%= 1;
        }

        /// `delay` サンプル前(>=1)の値を線形補間で読む。
        /// head は「次に書く位置」なので 1 サンプル前 = head-1。整数遅延 N は head-N。
        /// 小数遅延は新側 i0(=floor) と古側 i0+1 を a*(1-frac)+b*frac で補間。delay は 1..cap-1 にクランプ。
        pub fn readAt(self: *const Self, delay: f32) f32 {
            const d = std.math.clamp(delay, 1.0, @as(f32, @floatFromInt(cap - 1)));
            const di: usize = @intFromFloat(d);
            const frac = d - @as(f32, @floatFromInt(di));
            const a = self.buffer[(self.head -% di) & mask]; // di サンプル前(新しい側)
            const b = self.buffer[(self.head -% di -% 1) & mask]; // di+1 サンプル前(古い側)
            return a * (1.0 - frac) + b * frac;
        }
    };
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "DelayLine: integer delay reads exactly N samples ago" {
    var line = DelayLine(8){};
    // 0,1,2,3,4,5,6,7 を順に書く
    var i: usize = 0;
    while (i < 8) : (i += 1) line.write(@floatFromInt(i));
    // 直近に書いたのは 7。delay=1 → 7, delay=2 → 6, ...
    try testing.expectApproxEqAbs(@as(f32, 7), line.readAt(1), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 6), line.readAt(2), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 4), line.readAt(4), 1e-6);
}

test "DelayLine: fractional delay interpolates between neighbors" {
    var line = DelayLine(8){};
    var i: usize = 0;
    while (i < 8) : (i += 1) line.write(@floatFromInt(i * 10)); // 0,10,20,...,70
    // delay=1.5 → 1ago(70) と 2ago(60) の中間 = 65
    try testing.expectApproxEqAbs(@as(f32, 65), line.readAt(1.5), 1e-5);
    // delay=2.25 → 2ago(60) を 0.75、3ago(50) を 0.25 → 57.5
    try testing.expectApproxEqAbs(@as(f32, 57.5), line.readAt(2.25), 1e-5);
}

test "DelayLine: clamps delay to [1, cap-1] and reset clears" {
    var line = DelayLine(4){};
    line.write(1);
    line.write(2);
    line.write(3);
    line.write(4);
    // delay<1 は 1 に、delay>cap-1 は cap-1 にクランプ(trap しない)
    _ = line.readAt(0.0);
    _ = line.readAt(100.0);
    line.reset();
    // reset 後は全て 0
    try testing.expectApproxEqAbs(@as(f32, 0), line.readAt(1), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), line.readAt(3), 1e-6);
}

test "DelayLine: ring wraps around (older samples overwritten)" {
    var line = DelayLine(4){};
    // 8 サンプル書くと最後の 4 つだけ残る: buffer=[4,5,6,7], head=8。読める遅延は 1..cap-1(=3)。
    var i: usize = 0;
    while (i < 8) : (i += 1) line.write(@floatFromInt(i));
    try testing.expectApproxEqAbs(@as(f32, 7), line.readAt(1), 1e-6); // 1 ago
    try testing.expectApproxEqAbs(@as(f32, 6), line.readAt(2), 1e-6); // 2 ago
    try testing.expectApproxEqAbs(@as(f32, 5), line.readAt(3), 1e-6); // 3 ago(読める最古)
}
