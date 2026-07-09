//! オニオンスキン表示合成（TASK-45.3）。Document の cel グリッドから前後 frame を
//! 減色＋半透明で重ねる表示専用ロジック（core モデル非改変）。
//!
//! 毎フレーム全画素×(2N+1) を走るホットパス。pixelops の srcOverStraight4 / div255 を流用。

const std = @import("std");
const pixelops = @import("pixelops");
const Document = @import("document.zig").Document;

pub const max_count: u32 = 3;

/// 距離 dist（1..max_count）に対する onion 層の src-over opacity。N≤3 固定（128/64/42）。
pub fn onionOpacity(dist: u32) u8 {
    std.debug.assert(dist >= 1 and dist <= max_count);
    return @intCast(128 / dist);
}

const tint_half: u8 = 128;

const bg_lane_mask: @Vector(16, bool) = .{
    true,  true,  false, false,
    true,  true,  false, false,
    true,  true,  false, false,
    true,  true,  false, false,
};

const rg_lane_mask: @Vector(16, bool) = .{
    false, true,  true,  false,
    false, true,  true,  false,
    false, true,  true,  false,
    false, true,  true,  false,
};

/// 前フレーム用減色（赤味）: G/B を 1/2 に抑える。alpha は不変。
pub fn tintPrevPixel(c: u32) u32 {
    const b: u32 = c & 0xFF;
    const g: u32 = (c >> 8) & 0xFF;
    const r: u32 = (c >> 16) & 0xFF;
    const a: u32 = (c >> 24) & 0xFF;
    const b2 = pixelops.div255Round(b * tint_half);
    const g2 = pixelops.div255Round(g * tint_half);
    return @as(u32, a << 24) | (r << 16) | (g2 << 8) | b2;
}

/// 後フレーム用減色（青味）: R/G を 1/2 に抑える。alpha は不変。
pub fn tintNextPixel(c: u32) u32 {
    const b: u32 = c & 0xFF;
    const g: u32 = (c >> 8) & 0xFF;
    const r: u32 = (c >> 16) & 0xFF;
    const a: u32 = (c >> 24) & 0xFF;
    const r2 = pixelops.div255Round(r * tint_half);
    const g2 = pixelops.div255Round(g * tint_half);
    return @as(u32, a << 24) | (r2 << 16) | (g2 << 8) | b;
}

fn tintPrev4(c: pixelops.Vec16u8) pixelops.Vec16u8 {
    const c16: pixelops.Vec16u16 = @intCast(c);
    const half16: pixelops.Vec16u16 = @splat(tint_half);
    const scaled: pixelops.Vec16u8 = @intCast(pixelops.div255RoundVec16(c16 * half16));
    return @select(u8, bg_lane_mask, scaled, c);
}

fn tintNext4(c: pixelops.Vec16u8) pixelops.Vec16u8 {
    const c16: pixelops.Vec16u16 = @intCast(c);
    const half16: pixelops.Vec16u16 = @splat(tint_half);
    const scaled: pixelops.Vec16u8 = @intCast(pixelops.div255RoundVec16(c16 * half16));
    return @select(u8, rg_lane_mask, scaled, c);
}

fn tintPrevInPlace(buf: []u32) void {
    var i: usize = 0;
    while (i + 4 <= buf.len) : (i += 4) {
        const chunk: *[4]u32 = buf[i..][0..4];
        chunk.* = @bitCast(tintPrev4(@bitCast(chunk.*)));
    }
    while (i < buf.len) : (i += 1) {
        buf[i] = tintPrevPixel(buf[i]);
    }
}

fn tintNextInPlace(buf: []u32) void {
    var i: usize = 0;
    while (i + 4 <= buf.len) : (i += 4) {
        const chunk: *[4]u32 = buf[i..][0..4];
        chunk.* = @bitCast(tintNext4(@bitCast(chunk.*)));
    }
    while (i < buf.len) : (i += 1) {
        buf[i] = tintNextPixel(buf[i]);
    }
}

fn srcOverStraightOnto(dst: []u32, src: []const u32, opacity: u8) void {
    std.debug.assert(dst.len == src.len);
    const n = dst.len;
    var i: usize = 0;
    while (i + 4 <= n) : (i += 4) {
        const s4: [4]u32 = src[i..][0..4].*;
        if ((s4[0] | s4[1] | s4[2] | s4[3]) & 0xFF000000 == 0) continue;
        const dst_chunk: *[4]u32 = dst[i..][0..4];
        dst_chunk.* = @bitCast(pixelops.srcOverStraight4(@bitCast(dst_chunk.*), @bitCast(s4), opacity));
    }
    while (i < n) : (i += 1) {
        const s = src[i];
        if (s & 0xFF000000 == 0) continue;
        dst[i] = pixelops.srcOverStraightScalar(dst[i], s, opacity);
    }
}

/// 表示用オニオン合成を `out` へ構築する。
/// `current` は現フレームの straight-alpha composite（通常 `canvas`、プレビュー時 `preview_canvas`）。
/// `scratch` は 1 枚分の作業バッファ（`out` と同サイズ）。
pub fn build(
    doc: *const Document,
    current: []const u32,
    selected_frame: u32,
    count: u32,
    out: []u32,
    scratch: []u32,
) void {
    std.debug.assert(count >= 1 and count <= max_count);
    std.debug.assert(out.len == current.len and scratch.len == current.len);
    @memset(out, 0);

    var d: u32 = count;
    while (d > 0) : (d -= 1) {
        if (selected_frame < d) continue;
        const frame_idx = selected_frame - d;
        doc.compositeFrameStraight(frame_idx, scratch);
        tintPrevInPlace(scratch);
        srcOverStraightOnto(out, scratch, onionOpacity(d));
    }

    srcOverStraightOnto(out, current, 255);

    d = 1;
    while (d <= count) : (d += 1) {
        const frame_idx = selected_frame + d;
        if (frame_idx >= doc.frames.items.len) continue;
        doc.compositeFrameStraight(frame_idx, scratch);
        tintNextInPlace(scratch);
        srcOverStraightOnto(out, scratch, onionOpacity(d));
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "tintPrev4/tintNext4 match scalar" {
    const samples = [_]u32{ 0x80_FF_00_00, 0x40_00_FF_00, 0xFF_80_40_20, 0x00000000 };
    for (samples) |px| {
        const p4: [4]u32 = .{ px, px, px, px };
        const prev_actual: [4]u32 = @bitCast(tintPrev4(@bitCast(p4)));
        const next_actual: [4]u32 = @bitCast(tintNext4(@bitCast(p4)));
        for (0..4) |i| {
            try testing.expectEqual(tintPrevPixel(px), prev_actual[i]);
            try testing.expectEqual(tintNextPixel(px), next_actual[i]);
        }
    }
}

test "compositeFrameStraight: frame ごとに異なる cel を合成" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 2, 2);
    defer doc.deinit();
    try doc.addFrame(gpa, 1);
    const id0 = doc.createCel(gpa, 0, 0);
    @memset(doc.cel_pool.items[id0].?.pixels, 0);
    doc.cel_pool.items[id0].?.pixels[0] = 0xFF_FF_00_00;
    const id1 = doc.createCel(gpa, 0, 1);
    @memset(doc.cel_pool.items[id1].?.pixels, 0);
    doc.cel_pool.items[id1].?.pixels[0] = 0xFF_00_00_FF;
    const saved = doc.selected_frame;
    defer {
        doc.selected_frame = saved;
        doc.resyncActiveView(gpa);
    }
    var buf: [4]u32 = undefined;
    doc.compositeFrameStraight(0, &buf);
    try testing.expectEqual(@as(u32, 0xFF_FF_00_00), buf[0]);
    doc.compositeFrameStraight(1, &buf);
    try testing.expectEqual(@as(u32, 0xFF_00_00_FF), buf[0]);
    try testing.expectEqual(@as(u32, 0), buf[1]);
}

test "build: prev under / next over current" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 1, 1);
    defer doc.deinit();
    try doc.addFrame(gpa, 1);
    try doc.addFrame(gpa, 2);
    inline for (.{
        .{ 0, 0xFF_FF_00_00 },
        .{ 1, 0xFF_00_FF_00 },
        .{ 2, 0xFF_00_00_FF },
    }) |item| {
        const id = doc.createCel(gpa, 0, item[0]);
        @memset(doc.cel_pool.items[id].?.pixels, 0);
        doc.cel_pool.items[id].?.pixels[0] = item[1];
    }
    const current = [_]u32{0xFF_00_FF_00};
    var out: [1]u32 = undefined;
    var scratch: [1]u32 = undefined;
    build(&doc, &current, 1, 1, &out, &scratch);
    try testing.expect(out[0] != current[0]);
    try testing.expect(out[0] & 0xFF000000 != 0);
}
