// HVAR テーブル: 水平メトリクス変分（ItemVariationStore + advance mapping）。
//
// ホットパス宣言: advance 評価は **metrics cache ミス or 軸変更時のみ**
// （OutlineFont.advance_cache 経由）。フレーム毎経路には出さない。
//
// ヘッダ（OpenType HVAR）: major@0 / minor@2 / itemVariationStoreOffset@4 (Offset32) /
// advanceWidthMappingOffset@8 / lsbMappingOffset@12 / rsbMappingOffset@16。

const std = @import("std");
const Reader = @import("byte_reader.zig").Reader;
const var_common = @import("var_common.zig");
const ivs = @import("ivs.zig");

pub const Error = error{ InvalidFont, Unsupported, OutOfMemory };

pub const DeltaSetIndex = struct { outer: u16, inner: u16 };

pub const Hvar = struct {
    data: []const u8,
    ivs_off: usize,
    /// advance mapping offset（0 = 無し → gid を inner index として outer=0）。
    adv_map_off: usize,
    axis_count: u16,

    pub fn parse(table: []const u8, axis_count: u16) Error!Hvar {
        const r = Reader{ .data = table };
        try r.require(0, 20);
        const major = try r.u16At(0);
        const minor = try r.u16At(2);
        if (major != 1 or minor != 0) return error.InvalidFont;
        const ivs_off = try r.u32At(4);
        if (ivs_off == 0 or ivs_off >= table.len) return error.InvalidFont;
        const adv_map = try r.u32At(8);
        // lsb/rsb は MVP で未使用だが範囲だけ検証
        _ = try r.u32At(12);
        _ = try r.u32At(16);

        // IVS format 検証
        try ivs.validateIvs(table, ivs_off, axis_count);
        if (adv_map != 0) try validateDeltaSetIndexMap(table, adv_map);

        return .{
            .data = table,
            .ivs_off = ivs_off,
            .adv_map_off = adv_map,
            .axis_count = axis_count,
        };
    }

    /// advance の変分デルタ（font units）。破損は InvalidFont。
    pub fn advanceDelta(self: *const Hvar, gid: u16, norm: []const f32) Error!f32 {
        if (norm.len < self.axis_count) return error.InvalidFont;
        const outer_inner = try self.deltaSetIndex(gid);
        if (outer_inner.outer == 0xFFFF and outer_inner.inner == 0xFFFF) return 0;
        return try ivs.itemDelta(self.data, self.ivs_off, outer_inner.outer, outer_inner.inner, norm, self.axis_count);
    }

    fn deltaSetIndex(self: *const Hvar, gid: u16) Error!DeltaSetIndex {
        if (self.adv_map_off == 0) {
            // implicit: outer=0, inner=gid
            return .{ .outer = 0, .inner = gid };
        }
        return try readDeltaSetIndexMap(self.data, self.adv_map_off, gid);
    }
};

fn validateDeltaSetIndexMap(table: []const u8, map_off: usize) Error!void {
    const r = Reader{ .data = table };
    try r.require(map_off, 4);
    const format = try r.u8At(map_off);
    if (format != 0) return error.InvalidFont; // HVAR は format 0 のみ
    const entry_format = try r.u8At(map_off + 1);
    const map_count = try r.u16At(map_off + 2);
    const entry_size = @as(usize, (entry_format & 0x30) >> 4) + 1;
    const data_bytes = std.math.mul(usize, entry_size, map_count) catch return error.InvalidFont;
    try r.require(map_off + 4, data_bytes);
}

fn readDeltaSetIndexMap(table: []const u8, map_off: usize, gid: u16) Error!DeltaSetIndex {
    const r = Reader{ .data = table };
    try r.require(map_off, 4);
    const format = try r.u8At(map_off);
    if (format != 0) return error.InvalidFont;
    const entry_format = try r.u8At(map_off + 1);
    const map_count = try r.u16At(map_off + 2);
    if (map_count == 0) return error.InvalidFont;
    const entry_size = @as(usize, (entry_format & 0x30) >> 4) + 1;
    const inner_bits = @as(u5, @intCast((entry_format & 0x0F) + 1));
    const idx: usize = if (gid < map_count) gid else map_count - 1;
    const entry_off = map_off + 4 + idx * entry_size;
    try r.require(entry_off, entry_size);

    // big-endian entry
    var entry: u32 = 0;
    var bi: usize = 0;
    while (bi < entry_size) : (bi += 1) {
        entry = (entry << 8) | try r.u8At(entry_off + bi);
    }
    const inner_mask: u32 = (@as(u32, 1) << inner_bits) - 1;
    const inner: u16 = @truncate(entry & inner_mask);
    const outer: u16 = @truncate(entry >> inner_bits);
    return .{ .outer = outer, .inner = inner };
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn putU16(buf: []u8, off: usize, v: u16) void {
    buf[off] = @intCast(v >> 8);
    buf[off + 1] = @truncate(v);
}
fn putU32(buf: []u8, off: usize, v: u32) void {
    buf[off] = @truncate(v >> 24);
    buf[off + 1] = @truncate(v >> 16);
    buf[off + 2] = @truncate(v >> 8);
    buf[off + 3] = @truncate(v);
}
fn putI16(buf: []u8, off: usize, v: i16) void {
    putU16(buf, off, @bitCast(v));
}
fn f2d(v: f32) i16 {
    return var_common.f32ToF2dot14(v);
}

/// 最小 HVAR: 1 軸・1 region peak=1 start=0 end=1・1 item（gid0 直接）delta=20。
/// advance mapping 無し（direct: outer=0, inner=gid）。
fn buildMinimalHvarDirect() [64]u8 {
    var buf: [64]u8 = .{0} ** 64;
    // HVAR header
    putU16(&buf, 0, 1);
    putU16(&buf, 2, 0);
    putU32(&buf, 4, 20); // IVS at 20
    putU32(&buf, 8, 0); // no advance mapping
    putU32(&buf, 12, 0);
    putU32(&buf, 16, 0);

    // IVS at 20
    // format=1, regionListOffset=8 (relative → 28), itemVariationDataCount=1
    // itemVariationDataOffsets[0] = 8+4+6 = wait
    // IVS: format@0, regionListOff@2, count@6, offsets@8
    // region list immediately after offsets: off = 8+4 = 12 from IVS → abs 32
    // Actually: regionListOffset = 12, data offset = 12 + 4 + 6 = 22 from IVS?
    // Region list: axisCount(2)+regionCount(2)+region(6) = 10 bytes
    // IVS layout:
    //  0: format u16 = 1
    //  2: regionListOffset u32 = 12  (points to after header+1 offset)
    //  6: itemVariationDataCount = 1
    //  8: offset[0] = 22  (after region list: 12+10=22)
    // 12: VariationRegionList
    // 22: ItemVariationData
    const ivs_base: usize = 20;
    putU16(&buf, ivs_base, 1);
    putU32(&buf, ivs_base + 2, 12);
    putU16(&buf, ivs_base + 6, 1);
    putU32(&buf, ivs_base + 8, 22);

    // Region list at ivs+12 = 32
    const rl = ivs_base + 12;
    putU16(&buf, rl, 1); // axisCount
    putU16(&buf, rl + 2, 1); // regionCount
    putI16(&buf, rl + 4, f2d(0)); // start
    putI16(&buf, rl + 6, f2d(1)); // peak
    putI16(&buf, rl + 8, f2d(1)); // end

    // ItemVariationData at ivs+22 = 42
    const ivd = ivs_base + 22;
    putU16(&buf, ivd, 1); // itemCount = 1 (gid 0 only for direct; higher gids error or need more)
    putU16(&buf, ivd + 2, 0); // wordDeltaCount = 0 (all short/byte)
    putU16(&buf, ivd + 4, 1); // regionIndexCount
    putU16(&buf, ivd + 6, 0); // regionIndexes[0]=0
    // deltaSets: 1 region × int8 = 1 byte. delta = 20
    buf[ivd + 8] = 20;

    return buf;
}

/// HVAR with mapping: gid0 → outer0/inner0, and 2 items so we can have more glyphs via map.
fn buildHvarWithMapping() [80]u8 {
    var buf: [80]u8 = .{0} ** 80;
    putU16(&buf, 0, 1);
    putU16(&buf, 2, 0);
    putU32(&buf, 4, 20); // IVS
    putU32(&buf, 8, 52); // advance mapping at 52
    putU32(&buf, 12, 0);
    putU32(&buf, 16, 0);

    const ivs_base: usize = 20;
    putU16(&buf, ivs_base, 1);
    putU32(&buf, ivs_base + 2, 12);
    putU16(&buf, ivs_base + 6, 1);
    putU32(&buf, ivs_base + 8, 22);

    const rl = ivs_base + 12;
    putU16(&buf, rl, 1);
    putU16(&buf, rl + 2, 1);
    putI16(&buf, rl + 4, f2d(0));
    putI16(&buf, rl + 6, f2d(1));
    putI16(&buf, rl + 8, f2d(1));

    const ivd = ivs_base + 22;
    putU16(&buf, ivd, 2); // 2 items
    putU16(&buf, ivd + 2, 0);
    putU16(&buf, ivd + 4, 1);
    putU16(&buf, ivd + 6, 0);
    buf[ivd + 8] = 10; // item0 delta
    buf[ivd + 9] = 30; // item1 delta

    // DeltaSetIndexMap format 0 at 52
    // entryFormat: inner bits=1 (bit count-1=0 → 1 bit? wait: INNER_INDEX_BIT_COUNT = low 4 bits = bits-1
    // For outer=0, inner=0 or 1: need 1 bit inner, entry size 1 byte
    // entryFormat = (entrySize-1)<<4 | (innerBits-1) = 0 | 0 = 0 for 1-byte, 1 inner bit
    // Actually innerBits=1 → mask bits = 0 → INNER = 0. entry >> 1 for outer.
    // mapCount=3, mapData: gid0→inner0, gid1→inner1, gid2→inner0
    const map: usize = 52;
    buf[map] = 0; // format
    buf[map + 1] = 0; // entryFormat: 1 byte, 1 inner bit
    putU16(&buf, map + 2, 3);
    buf[map + 4] = 0; // outer=0, inner=0
    buf[map + 5] = 1; // outer=0, inner=1
    buf[map + 6] = 0; // outer=0, inner=0

    return buf;
}

test "hvar: direct mapping（mapping 無し）既知 advance delta" {
    const buf = buildMinimalHvarDirect();
    const hv = try Hvar.parse(&buf, 1);
    // norm=1 → scalar=1 → delta=20
    try testing.expectApproxEqAbs(@as(f32, 20), try hv.advanceDelta(0, &.{1.0}), 0.01);
    // norm=0.5 → scalar=0.5 → delta=10
    try testing.expectApproxEqAbs(@as(f32, 10), try hv.advanceDelta(0, &.{0.5}), 0.01);
    // norm=0 → scalar=0
    try testing.expectApproxEqAbs(@as(f32, 0), try hv.advanceDelta(0, &.{0.0}), 0.01);
}

test "hvar: delta-set mapping で gid 別 delta" {
    const buf = buildHvarWithMapping();
    const hv = try Hvar.parse(&buf, 1);
    try testing.expectApproxEqAbs(@as(f32, 10), try hv.advanceDelta(0, &.{1.0}), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 30), try hv.advanceDelta(1, &.{1.0}), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 10), try hv.advanceDelta(2, &.{1.0}), 0.01);
}

test "hvar: 壊れた version は InvalidFont" {
    var buf = buildMinimalHvarDirect();
    putU16(&buf, 0, 2);
    try testing.expectError(error.InvalidFont, Hvar.parse(&buf, 1));
}

test "hvar: IVS region axisCount 不一致は InvalidFont" {
    const buf = buildMinimalHvarDirect();
    try testing.expectError(error.InvalidFont, Hvar.parse(&buf, 2));
}
