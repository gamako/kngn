// avar テーブルパーサ（正規化座標の非線形セグメントマップ）。
//
// ホットパス宣言: **FontFace.init 時のみ**。軸変更時の mapAxis はイベント時のみ。
//
// ヘッダ: majorVersion@0 / minorVersion@2 / reserved@4 / axisCount@6、
// offset 8 から各軸の SegmentMaps が連続配置。

const std = @import("std");
const Reader = @import("byte_reader.zig").Reader;
const var_common = @import("var_common.zig");

pub const Error = var_common.Error;
pub const MAX_AXES = var_common.MAX_AXES;
pub const f2dot14ToF32 = var_common.f2dot14ToF32;

/// 1 軸あたりのセグメントマップ上限（実装上限。仕様上限ではない。超過は Unsupported）。
const max_segments_per_axis: usize = 32;

const Segment = struct {
    from: f32,
    to: f32,
};

pub const Avar = struct {
    data: []const u8,
    axis_count: u16,
    /// 各軸のセグメント（owned 固定配列。segment_counts[i] が有効長）。
    segments: [MAX_AXES][max_segments_per_axis]Segment,
    segment_counts: [MAX_AXES]u16,

    /// normalized_pre ∈ [-1,1] → avar 後の normalized。
    pub fn mapAxis(self: *const Avar, axis_index: u16, n: f32) f32 {
        if (axis_index >= self.axis_count) return n;
        const count = self.segment_counts[axis_index];
        if (count == 0) return n;
        const segs = self.segments[axis_index][0..count];

        if (n <= segs[0].from) return segs[0].to;
        const last = segs[count - 1];
        if (n >= last.from) return last.to;

        var i: usize = 0;
        while (i + 1 < count) : (i += 1) {
            const a = segs[i];
            const b = segs[i + 1];
            if (n >= a.from and n <= b.from) {
                const span = b.from - a.from;
                if (span == 0) return a.to;
                const t = (n - a.from) / span;
                return a.to + t * (b.to - a.to);
            }
        }
        return n;
    }

    fn validateSegmentMap(segs: []const Segment) Error!void {
        // OpenType avar: 'Axis value maps can be provided for any axis but are required only if
        // the normalization mapping for an axis is being modified. If the segment map for a given
        // axis has any value maps, then it must include at least three value maps...'
        // positionMapCount==0 は identity（実フォントに普通に存在する正当ケース）。
        if (segs.len == 0) return;

        var has_neg1 = false;
        var has_zero = false;
        var has_pos1 = false;
        var prev_from: f32 = -2;
        var prev_to: f32 = -2;

        for (segs, 0..) |s, si| {
            // F2DOT14 は量子化済み。from/to は厳密に [-1,1]。
            if (s.from < -1.0 or s.from > 1.0) return error.InvalidFont;
            if (s.to < -1.0 or s.to > 1.0) return error.InvalidFont;
            if (si > 0 and s.from <= prev_from) return error.InvalidFont;
            if (si > 0 and s.to < prev_to) return error.InvalidFont;
            prev_from = s.from;
            prev_to = s.to;

            if (s.from == -1.0 and s.to == -1.0) has_neg1 = true;
            if (s.from == 0.0 and s.to == 0.0) has_zero = true;
            if (s.from == 1.0 and s.to == 1.0) has_pos1 = true;
        }
        if (!has_neg1 or !has_zero or !has_pos1) return error.InvalidFont;
    }

    pub fn parse(table: []const u8, expected_axes: u16) Error!Avar {
        const r = Reader{ .data = table };
        try r.require(0, 8);
        const major = try r.u16At(0);
        const minor = try r.u16At(2);
        if (major != 1 or minor != 0) return error.InvalidFont;
        // reserved@4: fvar の reserved@6 と同方針。読み飛ばしのみ（!=0 でも InvalidFont にしない）。
        _ = try r.u16At(4);
        const axis_count = try r.u16At(6);
        if (axis_count != expected_axes) return error.InvalidFont;
        if (axis_count > MAX_AXES) return error.Unsupported;

        var result: Avar = .{
            .data = table,
            .axis_count = axis_count,
            .segments = undefined,
            .segment_counts = .{0} ** MAX_AXES,
        };

        var map_off: usize = 8;
        var ai: u16 = 0;
        while (ai < axis_count) : (ai += 1) {
            try r.require(map_off, 2);
            const pos_count = try r.u16At(map_off);
            const seg_bytes = std.math.mul(usize, @as(usize, pos_count), 4) catch return error.InvalidFont;
            try r.require(map_off + 2, seg_bytes);

            // 実装上限超過は「フォント不正」でなく「未対応」（MAX_AXES と同方針）
            if (pos_count > max_segments_per_axis) return error.Unsupported;

            var si: u16 = 0;
            while (si < pos_count) : (si += 1) {
                const entry_off = map_off + 2 + @as(usize, si) * 4;
                const from_v = f2dot14ToF32(try r.i16At(entry_off));
                const to_v = f2dot14ToF32(try r.i16At(entry_off + 2));
                result.segments[ai][si] = .{ .from = from_v, .to = to_v };
            }
            result.segment_counts[ai] = pos_count;
            try validateSegmentMap(result.segments[ai][0..pos_count]);
            map_off += 2 + seg_bytes;
        }

        return result;
    }
};

comptime {
    const parse_fn = @TypeOf(Avar.parse);
    const params = @typeInfo(parse_fn).@"fn".params;
    for (params) |p| {
        const ty = p.type orelse continue;
        if (@typeInfo(ty) == .pointer) {
            const ptr = @typeInfo(ty).pointer;
            if (ptr.size == .one and ptr.child == std.mem.Allocator) @compileError("Avar.parse must not take Allocator");
        }
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn putU16(buf: []u8, off: usize, v: u16) void {
    buf[off] = @intCast(v >> 8);
    buf[off + 1] = @truncate(v);
}
fn putI16(buf: []u8, off: usize, v: i16) void {
    putU16(buf, off, @bitCast(v));
}

/// 1 軸・必須マップ (-1,-1),(0,0),(1,1) + 中間 (0.5,0.75) の正しい avar。
fn buildAvar2Segment() [26]u8 {
    var buf: [26]u8 = undefined;
    @memset(&buf, 0);
    putU16(&buf, 0, 1); // majorVersion
    putU16(&buf, 2, 0); // minorVersion
    // reserved @4 = 0
    putU16(&buf, 6, 1); // axisCount
    // SegmentMaps @8（連続配置）
    putU16(&buf, 8, 4); // positionMapCount
    putI16(&buf, 10, -16384); // from -1 → to -1
    putI16(&buf, 12, -16384);
    putI16(&buf, 14, 0); // from 0 → to 0
    putI16(&buf, 16, 0);
    putI16(&buf, 18, 8192); // from 0.5 → to 0.75
    putI16(&buf, 20, 12288);
    putI16(&buf, 22, 16384); // from 1 → to 1
    putI16(&buf, 24, 16384);
    return buf;
}

test "avar: 2 セグメント中間値" {
    const buf = buildAvar2Segment();
    const av = try Avar.parse(&buf, 1);
    try testing.expectApproxEqAbs(@as(f32, 0), av.mapAxis(0, 0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, -0.5), av.mapAxis(0, -0.5), 0.01);
    // n=0.5: (0,0)〜(0.5,0.75) の区分線形中間
    try testing.expectApproxEqAbs(@as(f32, 0.375), av.mapAxis(0, 0.25), 0.02);
    try testing.expectApproxEqAbs(@as(f32, 0.75), av.mapAxis(0, 0.5), 0.02);
}

test "avar: axisCount 不一致は InvalidFont" {
    const buf = buildAvar2Segment();
    try testing.expectError(error.InvalidFont, Avar.parse(&buf, 2));
}

test "avar: 必須マップ欠落は InvalidFont" {
    var buf: [18]u8 = undefined;
    @memset(&buf, 0);
    putU16(&buf, 0, 1);
    putU16(&buf, 6, 1);
    putU16(&buf, 8, 2); // (-1,-1),(0,0) のみ。+1 欠落
    putI16(&buf, 10, -16384);
    putI16(&buf, 12, -16384);
    putI16(&buf, 14, 0);
    putI16(&buf, 16, 0);
    try testing.expectError(error.InvalidFont, Avar.parse(&buf, 1));
}

test "avar: toCoordinate 逆行は InvalidFont" {
    var buf = buildAvar2Segment();
    putI16(&buf, 24, 8192); // to at from=1 を 0.5 に（前点 to=0.75 より小さい）→ InvalidFont
    try testing.expectError(error.InvalidFont, Avar.parse(&buf, 1));
}

test "avar: 範囲外 from/to は InvalidFont" {
    var buf = buildAvar2Segment();
    putI16(&buf, 10, 20000); // from > 1
    try testing.expectError(error.InvalidFont, Avar.parse(&buf, 1));
}

test "avar: 空 SegmentMap は identity（受理）" {
    var buf: [10]u8 = undefined;
    @memset(&buf, 0);
    putU16(&buf, 0, 1);
    putU16(&buf, 6, 1); // axisCount
    putU16(&buf, 8, 0); // positionMapCount=0 → identity
    const av = try Avar.parse(&buf, 1);
    try testing.expectEqual(@as(u16, 0), av.segment_counts[0]);
    try testing.expectApproxEqAbs(@as(f32, 0.5), av.mapAxis(0, 0.5), 0.001);
}

test "avar: 端点確認" {
    const buf = buildAvar2Segment();
    const av = try Avar.parse(&buf, 1);
    try testing.expectApproxEqAbs(@as(f32, -1), av.mapAxis(0, -1), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1), av.mapAxis(0, 1), 0.001);
}