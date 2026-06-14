// sfnt コンテナ（TrueType / OpenType 共通）のパース基盤。
//
// table directory + 共通テーブル（head / maxp / hhea / hmtx）を読み、units/em スケールと
// 共通 Metrics（pixel 空間）への変換を提供する。アウトライン（glyf / CFF）・cmap には
// 踏み込まない（後続タスク）。すべての読み取りは範囲チェック付き Reader を経由し、
// 各テーブルは table-local slice 上で読む（テーブル境界をまたがない）。生バイトは借用保持。

const std = @import("std");
const font = @import("font.zig");
// BE 範囲チェック読み取りは共有モジュールに集約（cmap 等と共通）。範囲外は error.InvalidFont。
const Reader = @import("byte_reader.zig").Reader;

pub const Metrics = font.Metrics;

pub const Error = error{
    /// 構造的または意味論的に不正なフォント。
    InvalidFont,
    /// 受理しない sfnt バリアント（コレクション ttcf 等）。
    UnsupportedFormat,
};

/// sfnt 内のテーブルを tag で探し、検証済みの table-local slice を返す（無ければ null）。
fn findTableSlice(data: []const u8, base: usize, num_tables: u16, tag: [4]u8) Error!?[]const u8 {
    const r = Reader{ .data = data };
    var i: usize = 0;
    while (i < num_tables) : (i += 1) {
        const rec = base + 12 + i * 16; // directory は offset table(base)+12 から
        try r.require(rec, 16);
        if (std.mem.eql(u8, data[rec .. rec + 4], &tag)) {
            const off: usize = try r.u32At(rec + 8);
            const len: usize = try r.u32At(rec + 12);
            try r.require(off, len);
            return data[off .. off + len];
        }
    }
    return null;
}

pub const SfntFile = struct {
    /// 生バイト（呼び出し側所有。コピーしない＝遅延参照基盤）。
    data: []const u8,
    /// offset table の開始位置（plain sfnt=0, .ttc=先頭フォントの offsetTable[0]）。
    /// directory 探索は dir_base+12 から。テーブル本体 offset はファイル絶対。
    dir_base: usize,
    num_tables: u16,
    units_per_em: u16,
    /// loca フォーマット（0=short, 1=long）。TASK-25.4 が使用。本タスクは保持のみ。
    index_to_loc_format: i16,
    num_glyphs: u16,
    ascender: i16, // font units
    descender: i16, // font units（通常負）
    line_gap: i16, // font units
    number_of_h_metrics: u16,
    /// hmtx の table-local slice（advanceWidth の遅延参照用）。
    hmtx: []const u8,

    pub fn parse(data: []const u8) Error!SfntFile {
        const r = Reader{ .data = data };

        // .ttc(TrueType Collection): 先頭が 'ttcf'。先頭フォント offsetTable[0] を採用。
        var base: usize = 0;
        const first = try r.u32At(0);
        if (first == 0x74746366) { // 'ttcf'
            // ttcHeader: tag(4) major(2) minor(2) numFonts(4) offsetTable[numFonts](4)
            const major = try r.u16At(4);
            const minor = try r.u16At(6);
            // TTC は version 1.0 / 2.0 のみ定義（minor は常に 0）。1.1 や 2.99 等は弾く。
            if ((major != 1 and major != 2) or minor != 0) return error.InvalidFont;
            const num_fonts = try r.u32At(8);
            if (num_fonts < 1) return error.InvalidFont;
            // 12 + 4*numFonts <= data.len（overflow-safe）
            const ot_len = std.math.mul(usize, num_fonts, 4) catch return error.InvalidFont;
            try r.require(12, ot_len);
            base = try r.u32At(12); // offsetTable[0]（ファイル絶対）
            // base は header + offset 配列の外を指すこと
            if (base < 12 + ot_len) return error.InvalidFont;
        }

        const version = try r.u32At(base);
        // 0x00010000 = TrueType, 0x4F54544F = 'OTTO'(CFF)。'true' 等は非対応。
        if (version != 0x00010000 and version != 0x4F54544F) return error.UnsupportedFormat;

        const num_tables = try r.u16At(base + 4);
        // table directory 全体（base+12 + 16*numTables）が収まること（overflow-safe）。
        try r.require(base + 12, std.math.mul(usize, num_tables, 16) catch return error.InvalidFont);

        // ── head ──
        const head = (try findTableSlice(data, base, num_tables, "head".*)) orelse return error.InvalidFont;
        if (head.len < 54) return error.InvalidFont;
        const hr = Reader{ .data = head };
        if ((try hr.u32At(12)) != 0x5F0F3CF5) return error.InvalidFont; // magicNumber
        const units_per_em = try hr.u16At(18);
        if (units_per_em < 16 or units_per_em > 16384) return error.InvalidFont;
        const index_to_loc_format = try hr.i16At(50);
        if (index_to_loc_format != 0 and index_to_loc_format != 1) return error.InvalidFont;

        // ── maxp ──
        const maxp = (try findTableSlice(data, base, num_tables, "maxp".*)) orelse return error.InvalidFont;
        if (maxp.len < 6) return error.InvalidFont;
        const num_glyphs = try (Reader{ .data = maxp }).u16At(4);
        if (num_glyphs == 0) return error.InvalidFont;

        // ── hhea ──
        const hhea = (try findTableSlice(data, base, num_tables, "hhea".*)) orelse return error.InvalidFont;
        if (hhea.len < 36) return error.InvalidFont;
        const ar = Reader{ .data = hhea };
        const ascender = try ar.i16At(4);
        const descender = try ar.i16At(6);
        const line_gap = try ar.i16At(8);
        const number_of_h_metrics = try ar.u16At(34);
        if (number_of_h_metrics == 0 or number_of_h_metrics > num_glyphs) return error.InvalidFont;

        // ── hmtx（最低長は nHM <= numGlyphs 確認後に計算）──
        const hmtx = (try findTableSlice(data, base, num_tables, "hmtx".*)) orelse return error.InvalidFont;
        const need: usize = 4 * @as(usize, number_of_h_metrics) +
            2 * (@as(usize, num_glyphs) - @as(usize, number_of_h_metrics));
        if (hmtx.len < need) return error.InvalidFont;

        return .{
            .data = data,
            .dir_base = base,
            .num_tables = num_tables,
            .units_per_em = units_per_em,
            .index_to_loc_format = index_to_loc_format,
            .num_glyphs = num_glyphs,
            .ascender = ascender,
            .descender = descender,
            .line_gap = line_gap,
            .number_of_h_metrics = number_of_h_metrics,
            .hmtx = hmtx,
        };
    }

    /// 後続タスク（cmap / glyf / loca）が table-local slice でパースするための汎用アクセサ。
    /// 戻り値: テーブル不在は `null`、レコードはあるが offset/length が不正なら `error.InvalidFont`
    /// （「壊れたテーブル」と「欠落」を区別する）。
    pub fn tableSlice(self: *const SfntFile, tag: *const [4]u8) Error!?[]const u8 {
        return findTableSlice(self.data, self.dir_base, self.num_tables, tag.*);
    }

    /// glyph id の advance 幅（font units）。gid >= num_glyphs は error。
    /// gid >= number_of_h_metrics は最後の longHorMetric の advance（monospace tail）。
    pub fn advanceWidth(self: *const SfntFile, gid: u16) Error!u16 {
        if (gid >= self.num_glyphs) return error.InvalidFont;
        const idx: u16 = if (gid < self.number_of_h_metrics) gid else self.number_of_h_metrics - 1;
        const r = Reader{ .data = self.hmtx };
        return try r.u16At(@as(usize, idx) * 4);
    }

    /// font units → pixel のスケール係数。
    pub fn scaleForPixelSize(self: *const SfntFile, px: f32) f32 {
        return px / @as(f32, @floatFromInt(self.units_per_em));
    }

    /// 共通 Metrics（pixel 空間）に変換する。
    /// 規約: ascent 上向き正 / descent 下向き正 / line_height = ascent + descent + gap
    /// （`line_height >= ascent + descent` を常に満たす）。
    pub fn pixelMetrics(self: *const SfntFile, px: f32) Metrics {
        const s = self.scaleForPixelSize(px);
        // satI32 で NaN/Inf/範囲外を吸収（@intFromFloat の trap を避ける）。さらに各成分を
        // 下流安全な範囲 [-max_pixel_metric, max_pixel_metric] にクランプする。これにより
        //   - line_height = ascent+descent+gap は |.| <= 3*max < i32 域（加算 overflow なし）で、
        //     u32 化しても利用側（例: layout の @intCast(line_height) → i32）が trap しない
        //   - baseline_y = pos.y + ascent も常識的な pos で overflow しない
        // max_pixel_metric(=1<<20≈100万px) は現実のフォントサイズを遥かに超える安全余裕値。
        const ascent = clampMetric(satI32(@ceil(@as(f32, @floatFromInt(self.ascender)) * s)));
        const descent = clampMetric(satI32(@ceil(@as(f32, @floatFromInt(-@as(i32, self.descender))) * s)));
        const gap = std.math.clamp(satI32(@max(0.0, @round(@as(f32, @floatFromInt(self.line_gap)) * s))), 0, max_pixel_metric);
        const lh: i32 = ascent + descent + gap; // |.| <= 3*max_pixel_metric, i32 内
        return .{
            .line_height = @intCast(@max(0, lh)), // gap>=0 より line_height >= ascent+descent
            .ascent = ascent,
            .descent = descent,
        };
    }
};

/// pixel メトリクスの安全上限（現実のフォントサイズを遥かに超える）。利用側の i32 演算を守る。
const max_pixel_metric: i32 = 1 << 20;

fn clampMetric(v: i32) i32 {
    return std.math.clamp(v, -max_pixel_metric, max_pixel_metric);
}

/// f32 → i32 のサチュレート変換（NaN→0, ±Inf/範囲外→i32 端）。`@intFromFloat` の trap を避ける。
fn satI32(v: f32) i32 {
    if (std.math.isNan(v)) return 0;
    if (v >= @as(f32, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    if (v <= @as(f32, @floatFromInt(std.math.minInt(i32)))) return std.math.minInt(i32);
    return @intFromFloat(v);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

/// テスト用に sfnt バイト列を組む小さな builder。
const Builder = struct {
    const Table = struct { tag: [4]u8, body: []const u8 };

    /// version + テーブル群から sfnt バイト列を生成する（呼び出し側が free）。
    fn build(alloc: std.mem.Allocator, version: u32, tables: []const Table) ![]u8 {
        const n: u16 = @intCast(tables.len);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);

        // offset table（12 bytes）
        try appendU32(&out, alloc, version);
        try appendU16(&out, alloc, n);
        try appendU16(&out, alloc, 0); // searchRange
        try appendU16(&out, alloc, 0); // entrySelector
        try appendU16(&out, alloc, 0); // rangeShift

        // table bodies は directory の後ろに連結。offset を先に計算する。
        var body_off: u32 = @intCast(12 + 16 * @as(usize, n));
        for (tables) |t| {
            try out.appendSlice(alloc, &t.tag);
            try appendU32(&out, alloc, 0); // checksum
            try appendU32(&out, alloc, body_off);
            try appendU32(&out, alloc, @intCast(t.body.len));
            body_off += @intCast(t.body.len);
        }
        for (tables) |t| try out.appendSlice(alloc, t.body);
        return out.toOwnedSlice(alloc);
    }

    fn appendU16(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u16) !void {
        try list.append(alloc, @intCast(v >> 8));
        try list.append(alloc, @truncate(v));
    }
    fn appendU32(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u32) !void {
        try list.append(alloc, @truncate(v >> 24));
        try list.append(alloc, @truncate(v >> 16));
        try list.append(alloc, @truncate(v >> 8));
        try list.append(alloc, @truncate(v));
    }
};

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

/// head(54) / maxp(6) / hhea(36) / hmtx を最小構成で組む。
const FontParams = struct {
    units_per_em: u16 = 1000,
    index_to_loc_format: i16 = 0,
    num_glyphs: u16 = 2,
    ascender: i16 = 800,
    descender: i16 = -200,
    line_gap: i16 = 100,
    number_of_h_metrics: u16 = 2,
    /// 各 longHorMetric の advanceWidth（長さは number_of_h_metrics）
    advances: []const u16 = &.{ 600, 500 },
};

fn buildFont(alloc: std.mem.Allocator, version: u32, p: FontParams) ![]u8 {
    var head = [_]u8{0} ** 54;
    putU32(&head, 12, 0x5F0F3CF5); // magic
    putU16(&head, 18, p.units_per_em);
    putU16(&head, 50, @bitCast(p.index_to_loc_format));

    var maxp = [_]u8{0} ** 6;
    putU16(&maxp, 4, p.num_glyphs);

    var hhea = [_]u8{0} ** 36;
    putU16(&hhea, 4, @bitCast(p.ascender));
    putU16(&hhea, 6, @bitCast(p.descender));
    putU16(&hhea, 8, @bitCast(p.line_gap));
    putU16(&hhea, 34, p.number_of_h_metrics);

    const nhm = p.number_of_h_metrics;
    // 異常系（nHM > numGlyphs）でも builder が underflow しないよう安全に計算する。
    const tail: usize = if (p.num_glyphs > nhm) p.num_glyphs - nhm else 0;
    const hmtx = try alloc.alloc(u8, 4 * @as(usize, nhm) + 2 * tail);
    defer alloc.free(hmtx);
    @memset(hmtx, 0);
    for (0..nhm) |i| putU16(hmtx, i * 4, p.advances[i]); // advanceWidth, lsb は 0

    return Builder.build(alloc, version, &.{
        .{ .tag = "head".*, .body = &head },
        .{ .tag = "maxp".*, .body = &maxp },
        .{ .tag = "hhea".*, .body = &hhea },
        .{ .tag = "hmtx".*, .body = hmtx },
    });
}

test "sfnt: 正常な最小フォントをパースできる" {
    const bytes = try buildFont(testing.allocator, 0x00010000, .{});
    defer testing.allocator.free(bytes);

    const f = try SfntFile.parse(bytes);
    try testing.expectEqual(@as(u16, 1000), f.units_per_em);
    try testing.expectEqual(@as(i16, 0), f.index_to_loc_format);
    try testing.expectEqual(@as(u16, 2), f.num_glyphs);
    try testing.expectEqual(@as(i16, 800), f.ascender);
    try testing.expectEqual(@as(i16, -200), f.descender);
    try testing.expectEqual(@as(u16, 600), try f.advanceWidth(0));
    try testing.expectEqual(@as(u16, 500), try f.advanceWidth(1));
}

test "sfnt: OTTO(CFF) も受理する" {
    const bytes = try buildFont(testing.allocator, 0x4F54544F, .{});
    defer testing.allocator.free(bytes);
    const f = try SfntFile.parse(bytes);
    try testing.expectEqual(@as(u16, 1000), f.units_per_em);
}

test "sfnt: advanceWidth の monospace tail（gid >= numberOfHMetrics）" {
    // numGlyphs=4, nHM=2 → gid2,3 は最後の advance(=500)
    const bytes = try buildFont(testing.allocator, 0x00010000, .{
        .num_glyphs = 4,
        .number_of_h_metrics = 2,
        .advances = &.{ 600, 500 },
    });
    defer testing.allocator.free(bytes);
    const f = try SfntFile.parse(bytes);
    try testing.expectEqual(@as(u16, 500), try f.advanceWidth(2));
    try testing.expectEqual(@as(u16, 500), try f.advanceWidth(3));
    try testing.expectError(error.InvalidFont, f.advanceWidth(4)); // gid == numGlyphs
}

test "sfnt: pixelMetrics（規約と不変条件）" {
    const bytes = try buildFont(testing.allocator, 0x00010000, .{
        .units_per_em = 1000,
        .ascender = 800,
        .descender = -200,
        .line_gap = 100,
    });
    defer testing.allocator.free(bytes);
    const f = try SfntFile.parse(bytes);

    const m = f.pixelMetrics(100); // scale = 0.1
    try testing.expectEqual(@as(i32, 80), m.ascent); // ceil(800*0.1)
    try testing.expectEqual(@as(i32, 20), m.descent); // ceil(200*0.1)
    try testing.expectEqual(@as(u32, 110), m.line_height); // 80+20+round(100*0.1)
    // 不変条件
    try testing.expect(m.line_height >= @as(u32, @intCast(m.ascent + m.descent)));
}

test "sfnt: 負 lineGap は line_height をクランプ（不変条件維持）" {
    const bytes = try buildFont(testing.allocator, 0x00010000, .{
        .units_per_em = 1000,
        .ascender = 800,
        .descender = -200,
        .line_gap = -500,
    });
    defer testing.allocator.free(bytes);
    const f = try SfntFile.parse(bytes);
    const m = f.pixelMetrics(100);
    try testing.expectEqual(@as(u32, 100), m.line_height); // gap=max(0,-50)=0 → 80+20
    try testing.expect(m.line_height >= @as(u32, @intCast(m.ascent + m.descent)));
}

test "sfnt: tableSlice は table-local slice を返す / 欠落は null" {
    const bytes = try buildFont(testing.allocator, 0x00010000, .{});
    defer testing.allocator.free(bytes);
    const f = try SfntFile.parse(bytes);
    const head = (try f.tableSlice("head")).?;
    try testing.expectEqual(@as(usize, 54), head.len);
    try testing.expectEqual(@as(?[]const u8, null), try f.tableSlice("glyf"));
}

test "sfnt: tableSlice は壊れた optional テーブル(offset 範囲外)を InvalidFont として区別する" {
    // head/maxp/hhea/hmtx + ダミー cmap の 5 テーブル。cmap の directory offset を範囲外に壊す。
    var head = [_]u8{0} ** 54;
    putU32(&head, 12, 0x5F0F3CF5);
    putU16(&head, 18, 1000);
    var maxp = [_]u8{0} ** 6;
    putU16(&maxp, 4, 1);
    var hhea = [_]u8{0} ** 36;
    putU16(&hhea, 4, 800);
    putU16(&hhea, 6, @bitCast(@as(i16, -200)));
    putU16(&hhea, 34, 1);
    var hmtx = [_]u8{0} ** 4;
    putU16(&hmtx, 0, 500);
    const cmap = [_]u8{0} ** 4;
    const bytes = try Builder.build(testing.allocator, 0x00010000, &.{
        .{ .tag = "head".*, .body = &head },
        .{ .tag = "maxp".*, .body = &maxp },
        .{ .tag = "hhea".*, .body = &hhea },
        .{ .tag = "hmtx".*, .body = &hmtx },
        .{ .tag = "cmap".*, .body = &cmap },
    });
    defer testing.allocator.free(bytes);

    const f = try SfntFile.parse(bytes); // 必須テーブルは健全なので parse は成功
    // cmap は entry index 4。offset field は 12 + 4*16 + 8 = 84。範囲外へ。
    putU32(bytes, 84, 0xFFFF_FF00);
    try testing.expectError(error.InvalidFont, f.tableSlice("cmap"));
}

test "sfnt: maxp / hmtx の個別 length 不足は InvalidFont" {
    // maxp 短縮
    {
        var head = [_]u8{0} ** 54;
        putU32(&head, 12, 0x5F0F3CF5);
        putU16(&head, 18, 1000);
        const maxp = [_]u8{0} ** 5; // 6 未満（parse は length 不足で弾くので numGlyphs は未設定でよい）
        var hhea = [_]u8{0} ** 36;
        putU16(&hhea, 34, 1);
        var hmtx = [_]u8{0} ** 4;
        putU16(&hmtx, 0, 500);
        const bytes = try Builder.build(testing.allocator, 0x00010000, &.{
            .{ .tag = "head".*, .body = &head },
            .{ .tag = "maxp".*, .body = &maxp },
            .{ .tag = "hhea".*, .body = &hhea },
            .{ .tag = "hmtx".*, .body = &hmtx },
        });
        defer testing.allocator.free(bytes);
        try testing.expectError(error.InvalidFont, SfntFile.parse(bytes));
    }
    // hmtx 短縮（numGlyphs=2, nHM=2 → 8 bytes 必要だが 4 しかない）
    {
        var head = [_]u8{0} ** 54;
        putU32(&head, 12, 0x5F0F3CF5);
        putU16(&head, 18, 1000);
        var maxp = [_]u8{0} ** 6;
        putU16(&maxp, 4, 2);
        var hhea = [_]u8{0} ** 36;
        putU16(&hhea, 4, 800);
        putU16(&hhea, 34, 2);
        var hmtx = [_]u8{0} ** 4; // 8 必要
        putU16(&hmtx, 0, 500);
        const bytes = try Builder.build(testing.allocator, 0x00010000, &.{
            .{ .tag = "head".*, .body = &head },
            .{ .tag = "maxp".*, .body = &maxp },
            .{ .tag = "hhea".*, .body = &hhea },
            .{ .tag = "hmtx".*, .body = &hmtx },
        });
        defer testing.allocator.free(bytes);
        try testing.expectError(error.InvalidFont, SfntFile.parse(bytes));
    }
}

test "sfnt: pixelMetrics は極端な px でも panic しない（NaN/Inf/負/巨大）" {
    const bytes = try buildFont(testing.allocator, 0x00010000, .{});
    defer testing.allocator.free(bytes);
    const f = try SfntFile.parse(bytes);
    // いずれも trap せず、下流安全な範囲（line_height は i32 域・成分は ±max_pixel_metric 内）で返ること。
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), -100.0, 1.0e30 }) |px| {
        const m = f.pixelMetrics(px);
        try testing.expect(m.line_height <= @as(u32, @intCast(std.math.maxInt(i32)))); // layout の @intCast(i32) が trap しない
        try testing.expect(m.ascent >= -max_pixel_metric and m.ascent <= max_pixel_metric);
        try testing.expect(m.descent >= -max_pixel_metric and m.descent <= max_pixel_metric);
        // 不変条件 line_height >= ascent + descent
        try testing.expect(@as(i64, m.line_height) >= @as(i64, m.ascent) + @as(i64, m.descent));
    }
}

// ── 異常系（すべて error を返しクラッシュしない）──

test "sfnt: 非対応 version は UnsupportedFormat" {
    const bytes = try buildFont(testing.allocator, 0x00010000, .{});
    defer testing.allocator.free(bytes);
    putU32(bytes, 0, 0x74727565); // 'true'
    try testing.expectError(error.UnsupportedFormat, SfntFile.parse(bytes));
    // 注: 'ttcf' は .ttc コレクションとして別途処理されるためここでは扱わない
    //     （後続の本物の sfnt を 'true' から戻す必要はない＝このテストは破棄値）。
}

test "sfnt: .ttc(ttcf) 先頭フォントをパースできる" {
    const a = testing.allocator;
    const sfnt_bytes = try buildFont(a, 0x00010000, .{ .units_per_em = 1000, .ascender = 800, .descender = -200 });
    defer a.free(sfnt_bytes);

    // ttc header(numFonts=1 → 12 固定 + 4 = 16 byte) + sfnt。base=16。directory record offset を +base 補正。
    const base: u32 = 16;
    const ttc = try a.alloc(u8, base + sfnt_bytes.len);
    defer a.free(ttc);
    putU32(ttc, 0, 0x74746366); // 'ttcf'
    putU16(ttc, 4, 1); // major
    putU16(ttc, 6, 0); // minor
    putU32(ttc, 8, 1); // numFonts
    putU32(ttc, 12, base); // offsetTable[0]（先頭フォントの offset table = base=16）
    @memcpy(ttc[base..], sfnt_bytes);
    // directory は ttc 内では base+12。record offset field(@rec+8) を +base 補正。
    const num_tables = (@as(u16, sfnt_bytes[4]) << 8) | sfnt_bytes[5];
    var i: usize = 0;
    while (i < num_tables) : (i += 1) {
        const rec = base + 12 + i * 16;
        const cur = (@as(u32, ttc[rec + 8]) << 24) | (@as(u32, ttc[rec + 9]) << 16) | (@as(u32, ttc[rec + 10]) << 8) | ttc[rec + 11];
        putU32(ttc, rec + 8, cur + base);
    }

    const f = try SfntFile.parse(ttc);
    try testing.expectEqual(@as(usize, base), f.dir_base);
    try testing.expectEqual(@as(u16, 1000), f.units_per_em);
    try testing.expectEqual(@as(i16, 800), f.ascender);
    try testing.expectEqual(@as(u16, 600), try f.advanceWidth(0)); // buildFont 既定 advance
}

test "sfnt: .ttc の不正 version は InvalidFont" {
    const a = testing.allocator;
    const sfnt_bytes = try buildFont(a, 0x00010000, .{});
    defer a.free(sfnt_bytes);
    const base: u32 = 16;

    // minor != 0（TTC は 1.0/2.0 のみ）。base 先の中身まで作らずとも version 検証で弾かれる。
    {
        const ttc = try a.alloc(u8, base + sfnt_bytes.len);
        defer a.free(ttc);
        @memset(ttc, 0);
        putU32(ttc, 0, 0x74746366); // 'ttcf'
        putU16(ttc, 4, 1); // major = 1
        putU16(ttc, 6, 1); // minor = 1 → 不正
        putU32(ttc, 8, 1); // numFonts
        putU32(ttc, 12, base);
        try testing.expectError(error.InvalidFont, SfntFile.parse(ttc));
    }
    // major != 1/2
    {
        const ttc = try a.alloc(u8, base + sfnt_bytes.len);
        defer a.free(ttc);
        @memset(ttc, 0);
        putU32(ttc, 0, 0x74746366);
        putU16(ttc, 4, 3); // major = 3 → 不正
        putU16(ttc, 6, 0);
        putU32(ttc, 8, 1);
        putU32(ttc, 12, base);
        try testing.expectError(error.InvalidFont, SfntFile.parse(ttc));
    }
}

test "sfnt: 切り詰めデータは InvalidFont" {
    const bytes = try buildFont(testing.allocator, 0x00010000, .{});
    defer testing.allocator.free(bytes);
    try testing.expectError(error.InvalidFont, SfntFile.parse(bytes[0..3])); // offset table 未満
    try testing.expectError(error.InvalidFont, SfntFile.parse(bytes[0..20])); // directory 不足
}

test "sfnt: directory 長 (12+16*numTables) 不足は InvalidFont" {
    const bytes = try buildFont(testing.allocator, 0x00010000, .{});
    defer testing.allocator.free(bytes);
    // numTables を過大にして directory がはみ出す
    putU16(bytes, 4, 100);
    try testing.expectError(error.InvalidFont, SfntFile.parse(bytes));
}

test "sfnt: 必須テーブル欠落は InvalidFont" {
    // hmtx を含めない
    var head = [_]u8{0} ** 54;
    putU32(&head, 12, 0x5F0F3CF5);
    putU16(&head, 18, 1000);
    var maxp = [_]u8{0} ** 6;
    putU16(&maxp, 4, 1);
    var hhea = [_]u8{0} ** 36;
    putU16(&hhea, 4, 800);
    putU16(&hhea, 6, @bitCast(@as(i16, -200)));
    putU16(&hhea, 34, 1);
    const bytes = try Builder.build(testing.allocator, 0x00010000, &.{
        .{ .tag = "head".*, .body = &head },
        .{ .tag = "maxp".*, .body = &maxp },
        .{ .tag = "hhea".*, .body = &hhea },
    });
    defer testing.allocator.free(bytes);
    try testing.expectError(error.InvalidFont, SfntFile.parse(bytes));
}

test "sfnt: テーブル length 不足は InvalidFont（head 短縮）" {
    var head = [_]u8{0} ** 53; // 54 未満
    putU32(&head, 12, 0x5F0F3CF5);
    var maxp = [_]u8{0} ** 6;
    putU16(&maxp, 4, 1);
    var hhea = [_]u8{0} ** 36;
    putU16(&hhea, 34, 1);
    var hmtx = [_]u8{0} ** 4;
    putU16(&hmtx, 0, 500);
    const bytes = try Builder.build(testing.allocator, 0x00010000, &.{
        .{ .tag = "head".*, .body = &head },
        .{ .tag = "maxp".*, .body = &maxp },
        .{ .tag = "hhea".*, .body = &hhea },
        .{ .tag = "hmtx".*, .body = &hmtx },
    });
    defer testing.allocator.free(bytes);
    try testing.expectError(error.InvalidFont, SfntFile.parse(bytes));
}

test "sfnt: 意味論違反は InvalidFont" {
    // unitsPerEm = 0
    {
        const bytes = try buildFont(testing.allocator, 0x00010000, .{ .units_per_em = 0 });
        defer testing.allocator.free(bytes);
        try testing.expectError(error.InvalidFont, SfntFile.parse(bytes));
    }
    // unitsPerEm > 16384
    {
        const bytes = try buildFont(testing.allocator, 0x00010000, .{ .units_per_em = 20000 });
        defer testing.allocator.free(bytes);
        try testing.expectError(error.InvalidFont, SfntFile.parse(bytes));
    }
    // indexToLocFormat = 2
    {
        const bytes = try buildFont(testing.allocator, 0x00010000, .{ .index_to_loc_format = 2 });
        defer testing.allocator.free(bytes);
        try testing.expectError(error.InvalidFont, SfntFile.parse(bytes));
    }
    // numGlyphs = 0
    {
        const bytes = try buildFont(testing.allocator, 0x00010000, .{
            .num_glyphs = 0,
            .number_of_h_metrics = 0,
            .advances = &.{},
        });
        defer testing.allocator.free(bytes);
        try testing.expectError(error.InvalidFont, SfntFile.parse(bytes));
    }
}

test "sfnt: numberOfHMetrics の異常（0 / numGlyphs 超過）は InvalidFont" {
    // nHM = 0
    {
        const bytes = try buildFont(testing.allocator, 0x00010000, .{
            .num_glyphs = 2,
            .number_of_h_metrics = 0,
            .advances = &.{},
        });
        defer testing.allocator.free(bytes);
        try testing.expectError(error.InvalidFont, SfntFile.parse(bytes));
    }
    // nHM > numGlyphs
    {
        const bytes = try buildFont(testing.allocator, 0x00010000, .{
            .num_glyphs = 1,
            .number_of_h_metrics = 2,
            .advances = &.{ 600, 500 },
        });
        defer testing.allocator.free(bytes);
        try testing.expectError(error.InvalidFont, SfntFile.parse(bytes));
    }
}
