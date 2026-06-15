//! 波形整形(ディストーション)。代数的ソフトクリップ `x/(1+|x|)`。
//! 超越関数を使わず RT 安全・(-1,1) に有界・単調増加・原点対称。drive を掛けてから適用すると歪みが増す。

const std = @import("std");

/// ソフトクリップ。入力を (-1, 1) へ滑らかに飽和させる。`softClip(x*drive)` で歪み量を制御する。
pub fn softClip(x: f32) f32 {
    return x / (1.0 + @abs(x));
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "softClip: passes origin, bounded in (-1,1), saturates large input" {
    try testing.expectEqual(@as(f32, 0.0), softClip(0.0));
    // 大入力でも (-1,1) に収まる
    try testing.expect(softClip(1e6) < 1.0 and softClip(1e6) > 0.99);
    try testing.expect(softClip(-1e6) > -1.0 and softClip(-1e6) < -0.99);
    // 既知値: softClip(1)=0.5, softClip(-1)=-0.5, softClip(3)=0.75
    try testing.expectApproxEqAbs(@as(f32, 0.5), softClip(1.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.5), softClip(-1.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.75), softClip(3.0), 1e-6);
}

test "softClip: monotonic increasing" {
    var prev = softClip(-10.0);
    var x: f32 = -10.0;
    while (x <= 10.0) : (x += 0.1) {
        const v = softClip(x);
        try testing.expect(v >= prev - 1e-7);
        prev = v;
    }
}

test "softClip: odd symmetry (softClip(-x) = -softClip(x))" {
    for ([_]f32{ 0.3, 1.0, 2.5, 7.0 }) |x| {
        try testing.expectApproxEqAbs(-softClip(x), softClip(-x), 1e-6);
    }
}
