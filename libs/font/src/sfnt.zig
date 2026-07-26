// Parse foundation for the sfnt container (shared by TrueType / OpenType).
//
// Reads the table directory plus common tables (head / maxp / hhea / hmtx), and provides units/em scaling and
// conversion into shared Metrics (pixel space). Does not cover outlines (glyf / CFF) or cmap.
// All reads go through a bounds-checked Reader; each table is read on a table-local slice
// (never across table boundaries). Raw bytes are held by borrow.

const std = @import("std");
const font = @import("font.zig");
// BE bounds-checked reads are centralized in a shared module (also used by cmap etc.). Out of range → error.InvalidFont.
const Reader = @import("byte_reader.zig").Reader;

pub const Metrics = font.Metrics;

pub const Error = error{
    /// Structurally or semantically invalid font.
    InvalidFont,
    /// Unsupported sfnt variant (a .ttc collection is supported: its first font).
    UnsupportedFormat,
};

/// Look up a table by tag in the sfnt and return a validated table-local slice (null if absent).
fn findTableSlice(data: []const u8, base: usize, num_tables: u16, tag: [4]u8) Error!?[]const u8 {
    const r = Reader{ .data = data };
    var i: usize = 0;
    while (i < num_tables) : (i += 1) {
        const rec = base + 12 + i * 16; // directory starts at offset table(base)+12
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
    /// Raw bytes (owned by caller; not copied — deferred-reference foundation).
    data: []const u8,
    /// Start of the offset table (plain sfnt=0; .ttc = offsetTable[0] of the first font).
    /// Directory search starts at dir_base+12. Table body offsets are file-absolute.
    dir_base: usize,
    num_tables: u16,
    units_per_em: u16,
    /// loca format (0=short, 1=long). Retained for consumers that need it.
    index_to_loc_format: i16,
    num_glyphs: u16,
    ascender: i16, // font units
    descender: i16, // font units (usually negative)
    line_gap: i16, // font units
    number_of_h_metrics: u16,
    /// table-local slice of hmtx (for deferred advanceWidth lookup).
    hmtx: []const u8,

    pub fn parse(data: []const u8) Error!SfntFile {
        const r = Reader{ .data = data };

        // .ttc (TrueType Collection): leads with 'ttcf'. Use offsetTable[0] of the first font.
        var base: usize = 0;
        const first = try r.u32At(0);
        if (first == 0x74746366) { // 'ttcf'
            // ttcHeader: tag(4) major(2) minor(2) numFonts(4) offsetTable[numFonts](4)
            const major = try r.u16At(4);
            const minor = try r.u16At(6);
            // TTC defines only versions 1.0 / 2.0 (minor always 0). Reject 1.1, 2.99, etc.
            if ((major != 1 and major != 2) or minor != 0) return error.InvalidFont;
            const num_fonts = try r.u32At(8);
            if (num_fonts < 1) return error.InvalidFont;
            // 12 + 4*numFonts <= data.len (overflow-safe)
            const ot_len = std.math.mul(usize, num_fonts, 4) catch return error.InvalidFont;
            try r.require(12, ot_len);
            base = try r.u32At(12); // offsetTable[0] (file-absolute)
            // base must point past the header + offset array
            if (base < 12 + ot_len) return error.InvalidFont;
        }

        const version = try r.u32At(base);
        // 0x00010000 = TrueType, 0x4F54544F = 'OTTO'(CFF). 'true' etc. unsupported.
        if (version != 0x00010000 and version != 0x4F54544F) return error.UnsupportedFormat;

        const num_tables = try r.u16At(base + 4);
        // Entire table directory (base+12 + 16*numTables) must fit (overflow-safe).
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

        // ── hmtx (min length computed after confirming nHM <= numGlyphs) ──
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

    /// Generic accessor so consumers (cmap / glyf / loca) can parse via table-local slices.
    /// Returns: `null` if the table is absent; `error.InvalidFont` if a record exists but offset/length is invalid
    /// (distinguishes a broken table from a missing one).
    pub fn tableSlice(self: *const SfntFile, tag: *const [4]u8) Error!?[]const u8 {
        return findTableSlice(self.data, self.dir_base, self.num_tables, tag.*);
    }

    /// Advance width for glyph id (font units). gid >= num_glyphs is an error.
    /// For gid >= number_of_h_metrics, use advance from the last longHorMetric (monospace tail).
    pub fn advanceWidth(self: *const SfntFile, gid: u16) Error!u16 {
        if (gid >= self.num_glyphs) return error.InvalidFont;
        const idx: u16 = if (gid < self.number_of_h_metrics) gid else self.number_of_h_metrics - 1;
        const r = Reader{ .data = self.hmtx };
        return try r.u16At(@as(usize, idx) * 4);
    }

    /// Scale factor from font units → pixels.
    pub fn scaleForPixelSize(self: *const SfntFile, px: f32) f32 {
        return px / @as(f32, @floatFromInt(self.units_per_em));
    }

    /// Convert into shared Metrics (pixel space).
    /// Convention: ascent positive upward / descent positive downward / line_height = ascent + descent + gap
    /// (always satisfies `line_height >= ascent + descent`).
    pub fn pixelMetrics(self: *const SfntFile, px: f32) Metrics {
        const s = self.scaleForPixelSize(px);
        // Absorb NaN/Inf/out-of-range via satI32 (avoid @intFromFloat traps). Then clamp each component to the
        // downstream-safe range [-max_pixel_metric, max_pixel_metric]. This ensures
        //   - line_height = ascent+descent+gap has |.| <= 3*max < i32 range (no add overflow), so
        //     even as u32, callers (e.g. layout @intCast(line_height) → i32) do not trap
        //   - baseline_y = pos.y + ascent does not overflow for ordinary pos
        // max_pixel_metric(=1<<20≈1M px) is a safety margin far beyond realistic font sizes.
        const ascent = clampMetric(satI32(@ceil(@as(f32, @floatFromInt(self.ascender)) * s)));
        const descent = clampMetric(satI32(@ceil(@as(f32, @floatFromInt(-@as(i32, self.descender))) * s)));
        const gap = std.math.clamp(satI32(@max(0.0, @round(@as(f32, @floatFromInt(self.line_gap)) * s))), 0, max_pixel_metric);
        const lh: i32 = ascent + descent + gap; // |.| <= 3*max_pixel_metric, within i32
        return .{
            .line_height = @intCast(@max(0, lh)), // gap>=0 implies line_height >= ascent+descent
            .ascent = ascent,
            .descent = descent,
        };
    }
};

/// Safe upper bound for pixel metrics (far beyond realistic font sizes). Protects callers' i32 arithmetic.
const max_pixel_metric: i32 = 1 << 20;

fn clampMetric(v: i32) i32 {
    return std.math.clamp(v, -max_pixel_metric, max_pixel_metric);
}

/// Saturating f32 → i32 (NaN→0, ±Inf/out-of-range→i32 extremes). Avoids `@intFromFloat` traps.
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

/// Small builder that assembles sfnt byte streams for tests.
const Builder = struct {
    const Table = struct { tag: [4]u8, body: []const u8 };

    /// Build an sfnt byte stream from version + tables (caller frees).
    fn build(alloc: std.mem.Allocator, version: u32, tables: []const Table) ![]u8 {
        const n: u16 = @intCast(tables.len);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);

        // offset table (12 bytes)
        try appendU32(&out, alloc, version);
        try appendU16(&out, alloc, n);
        try appendU16(&out, alloc, 0); // searchRange
        try appendU16(&out, alloc, 0); // entrySelector
        try appendU16(&out, alloc, 0); // rangeShift

        // Table bodies are concatenated after the directory; compute offsets first.
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

/// Minimal head(54) / maxp(6) / hhea(36) / hmtx assembly.
const FontParams = struct {
    units_per_em: u16 = 1000,
    index_to_loc_format: i16 = 0,
    num_glyphs: u16 = 2,
    ascender: i16 = 800,
    descender: i16 = -200,
    line_gap: i16 = 100,
    number_of_h_metrics: u16 = 2,
    /// advanceWidth for each longHorMetric (length = number_of_h_metrics)
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
    // Compute safely so the builder never underflows even in the abnormal case (nHM > numGlyphs).
    const tail: usize = if (p.num_glyphs > nhm) p.num_glyphs - nhm else 0;
    const hmtx = try alloc.alloc(u8, 4 * @as(usize, nhm) + 2 * tail);
    defer alloc.free(hmtx);
    @memset(hmtx, 0);
    for (0..nhm) |i| putU16(hmtx, i * 4, p.advances[i]); // advanceWidth, lsb are 0

    return Builder.build(alloc, version, &.{
        .{ .tag = "head".*, .body = &head },
        .{ .tag = "maxp".*, .body = &maxp },
        .{ .tag = "hhea".*, .body = &hhea },
        .{ .tag = "hmtx".*, .body = hmtx },
    });
}

test "sfnt: parses a valid minimal font" {
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

test "sfnt: also accepts OTTO(CFF)" {
    const bytes = try buildFont(testing.allocator, 0x4F54544F, .{});
    defer testing.allocator.free(bytes);
    const f = try SfntFile.parse(bytes);
    try testing.expectEqual(@as(u16, 1000), f.units_per_em);
}

test "sfnt: advanceWidth monospace tail (gid >= numberOfHMetrics)" {
    // numGlyphs=4, nHM=2 → gid2,3 use the last advance(=500)
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

test "sfnt: pixelMetrics (convention and invariants)" {
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
    // Invariant
    try testing.expect(m.line_height >= @as(u32, @intCast(m.ascent + m.descent)));
}

test "sfnt: negative lineGap clamps line_height (keeps invariant)" {
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

test "sfnt: tableSlice returns a table-local slice / missing is null" {
    const bytes = try buildFont(testing.allocator, 0x00010000, .{});
    defer testing.allocator.free(bytes);
    const f = try SfntFile.parse(bytes);
    const head = (try f.tableSlice("head")).?;
    try testing.expectEqual(@as(usize, 54), head.len);
    try testing.expectEqual(@as(?[]const u8, null), try f.tableSlice("glyf"));
}

test "sfnt: tableSlice distinguishes broken optional table (offset OOB) as InvalidFont" {
    // 5 tables: head/maxp/hhea/hmtx + dummy cmap. Corrupt the cmap directory offset out of range.
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

    const f = try SfntFile.parse(bytes); // Required tables are sound so parse succeeds
    // cmap is entry index 4. offset field is 12 + 4*16 + 8 = 84. Force out of range.
    putU32(bytes, 84, 0xFFFF_FF00);
    try testing.expectError(error.InvalidFont, f.tableSlice("cmap"));
}

test "sfnt: insufficient maxp / hmtx length is InvalidFont" {
    // Truncated maxp
    {
        var head = [_]u8{0} ** 54;
        putU32(&head, 12, 0x5F0F3CF5);
        putU16(&head, 18, 1000);
        const maxp = [_]u8{0} ** 5; // Under 6 (parse rejects on short length; numGlyphs need not be set)
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
    // Truncated hmtx (numGlyphs=2, nHM=2 → needs 8 bytes but only 4)
    {
        var head = [_]u8{0} ** 54;
        putU32(&head, 12, 0x5F0F3CF5);
        putU16(&head, 18, 1000);
        var maxp = [_]u8{0} ** 6;
        putU16(&maxp, 4, 2);
        var hhea = [_]u8{0} ** 36;
        putU16(&hhea, 4, 800);
        putU16(&hhea, 34, 2);
        var hmtx = [_]u8{0} ** 4; // Needs 8
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

test "sfnt: pixelMetrics does not panic on extreme px (NaN/Inf/negative/huge)" {
    const bytes = try buildFont(testing.allocator, 0x00010000, .{});
    defer testing.allocator.free(bytes);
    const f = try SfntFile.parse(bytes);
    // Must not trap; return values stay in the downstream-safe range (line_height in i32; components within ±max_pixel_metric).
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), -100.0, 1.0e30 }) |px| {
        const m = f.pixelMetrics(px);
        try testing.expect(m.line_height <= @as(u32, @intCast(std.math.maxInt(i32)))); // layout's @intCast(i32) must not trap
        try testing.expect(m.ascent >= -max_pixel_metric and m.ascent <= max_pixel_metric);
        try testing.expect(m.descent >= -max_pixel_metric and m.descent <= max_pixel_metric);
        // Invariant: line_height >= ascent + descent
        try testing.expect(@as(i64, m.line_height) >= @as(i64, m.ascent) + @as(i64, m.descent));
    }
}

// ── Abnormal cases (all return errors; must not crash) ──

test "sfnt: unsupported version is UnsupportedFormat" {
    const bytes = try buildFont(testing.allocator, 0x00010000, .{});
    defer testing.allocator.free(bytes);
    putU32(bytes, 0, 0x74727565); // 'true'
    try testing.expectError(error.UnsupportedFormat, SfntFile.parse(bytes));
    // Note: 'ttcf' is handled separately as a .ttc collection, so it is not covered here
    //     (this test uses a discard value; no need to restore a real sfnt from 'true').
}

test "sfnt: parses the first font of a .ttc(ttcf)" {
    const a = testing.allocator;
    const sfnt_bytes = try buildFont(a, 0x00010000, .{ .units_per_em = 1000, .ascender = 800, .descender = -200 });
    defer a.free(sfnt_bytes);

    // ttc header (numFonts=1 → fixed 12 + 4 = 16 bytes) + sfnt. base=16. Adjust directory record offsets by +base.
    const base: u32 = 16;
    const ttc = try a.alloc(u8, base + sfnt_bytes.len);
    defer a.free(ttc);
    putU32(ttc, 0, 0x74746366); // 'ttcf'
    putU16(ttc, 4, 1); // major
    putU16(ttc, 6, 0); // minor
    putU32(ttc, 8, 1); // numFonts
    putU32(ttc, 12, base); // offsetTable[0] (first font's offset table = base=16)
    @memcpy(ttc[base..], sfnt_bytes);
    // Inside a ttc, directory is at base+12. Adjust record offset field (@rec+8) by +base.
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
    try testing.expectEqual(@as(u16, 600), try f.advanceWidth(0)); // buildFont default advance
}

test "sfnt: bad .ttc version is InvalidFont" {
    const a = testing.allocator;
    const sfnt_bytes = try buildFont(a, 0x00010000, .{});
    defer a.free(sfnt_bytes);
    const base: u32 = 16;

    // minor != 0 (TTC only allows 1.0/2.0). Rejected at version check without building past base.
    {
        const ttc = try a.alloc(u8, base + sfnt_bytes.len);
        defer a.free(ttc);
        @memset(ttc, 0);
        putU32(ttc, 0, 0x74746366); // 'ttcf'
        putU16(ttc, 4, 1); // major = 1
        putU16(ttc, 6, 1); // minor = 1 → invalid
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
        putU16(ttc, 4, 3); // major = 3 → invalid
        putU16(ttc, 6, 0);
        putU32(ttc, 8, 1);
        putU32(ttc, 12, base);
        try testing.expectError(error.InvalidFont, SfntFile.parse(ttc));
    }
}

test "sfnt: truncated data is InvalidFont" {
    const bytes = try buildFont(testing.allocator, 0x00010000, .{});
    defer testing.allocator.free(bytes);
    try testing.expectError(error.InvalidFont, SfntFile.parse(bytes[0..3])); // Shorter than offset table
    try testing.expectError(error.InvalidFont, SfntFile.parse(bytes[0..20])); // Directory too short
}

test "sfnt: short directory (12+16*numTables) is InvalidFont" {
    const bytes = try buildFont(testing.allocator, 0x00010000, .{});
    defer testing.allocator.free(bytes);
    // Inflate numTables so the directory overflows
    putU16(bytes, 4, 100);
    try testing.expectError(error.InvalidFont, SfntFile.parse(bytes));
}

test "sfnt: missing required table is InvalidFont" {
    // Omit hmtx
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

test "sfnt: insufficient table length is InvalidFont (shortened head)" {
    var head = [_]u8{0} ** 53; // Under 54
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

test "sfnt: semantic violation is InvalidFont" {
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

test "sfnt: bad numberOfHMetrics (0 / >numGlyphs) is InvalidFont" {
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
