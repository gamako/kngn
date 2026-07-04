//! 3次ベジェの評価と適応的平坦化（TASK-21.13）。
//!
//! GUI/platform 非依存の純粋数学。論理座標は f32（滑らかなハンドル編集のため）。
//! 平坦化は de Casteljau による適応再帰細分（flatness <= tol で停止、深さ上限 16）。

const std = @import("std");

pub const Vec2f = struct {
    x: f32,
    y: f32,

    pub fn lerp(a: Vec2f, b: Vec2f, t: f32) Vec2f {
        return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
    }
};

/// 3次ベジェ 1 セグメント（p0→p1、制御点 c0/c1）。
pub const Cubic = struct {
    p0: Vec2f,
    c0: Vec2f,
    c1: Vec2f,
    p1: Vec2f,

    /// de Casteljau で t∈[0,1] を評価（t=0→p0, t=1→p1）。
    pub fn eval(seg: Cubic, t: f32) Vec2f {
        const a = Vec2f.lerp(seg.p0, seg.c0, t);
        const b = Vec2f.lerp(seg.c0, seg.c1, t);
        const c = Vec2f.lerp(seg.c1, seg.p1, t);
        const d = Vec2f.lerp(a, b, t);
        const e = Vec2f.lerp(b, c, t);
        return Vec2f.lerp(d, e, t);
    }
};

/// 制御点が弦 p0-p1 に十分近いか（AGG 由来の flatness 判定）。
fn flatEnough(seg: Cubic, tol: f32) bool {
    const ux = 3.0 * seg.c0.x - 2.0 * seg.p0.x - seg.p1.x;
    const uy = 3.0 * seg.c0.y - 2.0 * seg.p0.y - seg.p1.y;
    const vx = 3.0 * seg.c1.x - seg.p0.x - 2.0 * seg.p1.x;
    const vy = 3.0 * seg.c1.y - seg.p0.y - 2.0 * seg.p1.y;
    const d2 = @max(ux * ux, vx * vx) + @max(uy * uy, vy * vy);
    return d2 <= 16.0 * tol * tol;
}

const MAX_DEPTH: u8 = 16;

fn flattenRec(seg: Cubic, tol: f32, out: *std.ArrayList(Vec2f), gpa: std.mem.Allocator, depth: u8) void {
    if (depth >= MAX_DEPTH or flatEnough(seg, tol)) {
        out.append(gpa, seg.p1) catch @panic("bezier.flatten: OOM");
        return;
    }
    // de Casteljau で t=0.5 分割
    const p01 = Vec2f.lerp(seg.p0, seg.c0, 0.5);
    const p12 = Vec2f.lerp(seg.c0, seg.c1, 0.5);
    const p23 = Vec2f.lerp(seg.c1, seg.p1, 0.5);
    const p012 = Vec2f.lerp(p01, p12, 0.5);
    const p123 = Vec2f.lerp(p12, p23, 0.5);
    const mid = Vec2f.lerp(p012, p123, 0.5);
    flattenRec(.{ .p0 = seg.p0, .c0 = p01, .c1 = p012, .p1 = mid }, tol, out, gpa, depth + 1);
    flattenRec(.{ .p0 = mid, .c0 = p123, .c1 = p23, .p1 = seg.p1 }, tol, out, gpa, depth + 1);
}

/// 適応再帰細分で平坦化し、各サブ区間の終点を `out` へ push する。
/// **始点 p0 は呼び出し側が事前に push する契約**（セグメント連結で重複させない）。
pub fn flatten(seg: Cubic, tol: f32, out: *std.ArrayList(Vec2f), gpa: std.mem.Allocator) void {
    flattenRec(seg, tol, out, gpa, 0);
}

// ============================================================
// Tests
// ============================================================

fn expectApprox(expected: Vec2f, actual: Vec2f) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, 1e-4);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, 1e-4);
}

test "eval: 端点と中点" {
    const seg: Cubic = .{
        .p0 = .{ .x = 0, .y = 0 },
        .c0 = .{ .x = 0, .y = 10 },
        .c1 = .{ .x = 10, .y = 10 },
        .p1 = .{ .x = 10, .y = 0 },
    };
    try expectApprox(.{ .x = 0, .y = 0 }, seg.eval(0));
    try expectApprox(.{ .x = 10, .y = 0 }, seg.eval(1));
    // 対称な山なり → t=0.5 は x=5, y=7.5
    try expectApprox(.{ .x = 5, .y = 7.5 }, seg.eval(0.5));
}

test "flatten: 直線状セグメントは端点のみ（始点は呼び出し側 push）" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(Vec2f) = .empty;
    defer out.deinit(gpa);
    // 制御点が弦上に乗る完全な直線
    const seg: Cubic = .{
        .p0 = .{ .x = 0, .y = 0 },
        .c0 = .{ .x = 3, .y = 0 },
        .c1 = .{ .x = 6, .y = 0 },
        .p1 = .{ .x = 9, .y = 0 },
    };
    out.append(gpa, seg.p0) catch unreachable; // 始点
    flatten(seg, 0.25, &out, gpa);
    try std.testing.expectEqual(@as(usize, 2), out.items.len); // 始点 + 終点
    try expectApprox(.{ .x = 0, .y = 0 }, out.items[0]);
    try expectApprox(.{ .x = 9, .y = 0 }, out.items[1]);
}

test "flatten: 湾曲セグメントは中間点が増え、終点を含む" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(Vec2f) = .empty;
    defer out.deinit(gpa);
    const seg: Cubic = .{
        .p0 = .{ .x = 0, .y = 0 },
        .c0 = .{ .x = 0, .y = 40 },
        .c1 = .{ .x = 40, .y = 40 },
        .p1 = .{ .x = 40, .y = 0 },
    };
    out.append(gpa, seg.p0) catch unreachable;
    flatten(seg, 0.25, &out, gpa);
    try std.testing.expect(out.items.len > 2); // 細分される
    const last = out.items[out.items.len - 1];
    try expectApprox(.{ .x = 40, .y = 0 }, last); // 終点を含む
    // 単調性は要求しないが、全点が bbox 内（[0,40]×[0,40] に概ね収まる）
    for (out.items) |p| {
        try std.testing.expect(p.x >= -0.01 and p.x <= 40.01);
        try std.testing.expect(p.y >= -0.01 and p.y <= 40.01);
    }
}
