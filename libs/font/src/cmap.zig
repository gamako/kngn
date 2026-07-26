// cmap parser (codepoint → glyph id). Supports format 4 (BMP) and format 12 (full Unicode).
//
// Design:
//   - Only Unicode platform/encoding subtables are candidates (format12=(3,10)/(0,4),
//     format4=(3,1)/(0,3)). Non-Unicode is excluded to avoid misreading other encoding values.
//   - Keep **both** format 12 and format 4, and fall back in lookup
//     (cp>0xFFFF→f12 only, cp<=0xFFFF→f12→f4).
//   - At parse, verify structural integrity (bounds, order, no overlap, reservedPad). lookup searches
//     the verified structure and only bounds-checks the codepoint-dependent final indirection
//     (format4 idRangeOffset target) each time, falling back to .notdef(0) (no trap).
//   - Matching GID against numGlyphs (gid>=numGlyphs→0) is the caller's OutlineFont responsibility.

const std = @import("std");
const Reader = @import("byte_reader.zig").Reader;

pub const Error = error{InvalidFont};

pub const Cmap = struct {
    /// table-local slice of the selected format 4 subtable (null if none)
    f4: ?[]const u8 = null,
    /// table-local slice of the selected format 12 subtable (null if none)
    f12: ?[]const u8 = null,

    /// Parse a cmap table (slice from SfntFile.tableSlice("cmap")).
    pub fn parse(cmap: []const u8) Error!Cmap {
        const r = Reader{ .data = cmap };
        if ((try r.u16At(0)) != 0) return error.InvalidFont; // version is 0
        const num_tables = try r.u16At(2);

        var f4: ?[]const u8 = null;
        var f4_win = false;
        var f12: ?[]const u8 = null;
        var f12_win = false;

        var i: usize = 0;
        while (i < num_tables) : (i += 1) {
            const rec = 4 + i * 8;
            try r.require(rec, 8);
            const platform = try r.u16At(rec);
            const encoding = try r.u16At(rec + 2);
            const off: usize = try r.u32At(rec + 4);

            const want_f12 = (platform == 3 and encoding == 10) or (platform == 0 and encoding == 4);
            const want_f4 = (platform == 3 and encoding == 1) or (platform == 0 and encoding == 3);
            if (!want_f12 and !want_f4) continue;

            try r.require(off, 2);
            const format = try r.u16At(off);
            const is_win = (platform == 3);
            if (format == 12 and want_f12) {
                const sub = try sliceFormat12(cmap, off);
                if (f12 == null or (is_win and !f12_win)) {
                    f12 = sub;
                    f12_win = is_win;
                }
            } else if (format == 4 and want_f4) {
                const sub = try sliceFormat4(cmap, off);
                if (f4 == null or (is_win and !f4_win)) {
                    f4 = sub;
                    f4_win = is_win;
                }
            }
            // Ignore when platform/encoding and format disagree (prevent misinterpretation).
        }

        if (f4 == null and f12 == null) return error.InvalidFont;
        return .{ .f4 = f4, .f12 = f12 };
    }

    /// codepoint → GID. Returns 0 (.notdef) if missing. No error, no trap.
    pub fn lookup(self: Cmap, codepoint: u32) u16 {
        if (codepoint > 0xFFFF) {
            return if (self.f12) |s| lookup12(s, codepoint) else 0;
        }
        if (self.f12) |s| {
            const g = lookup12(s, codepoint);
            if (g != 0) return g;
        }
        if (self.f4) |s| {
            const g = lookup4(s, codepoint);
            if (g != 0) return g;
        }
        return 0;
    }
};

// ── format 4 ──────────────────────────────────────────────

/// Validate a format 4 subtable and return its table-local slice.
fn sliceFormat4(cmap: []const u8, off: usize) Error![]const u8 {
    const r = Reader{ .data = cmap };
    const length: usize = try r.u16At(off + 2);
    try r.require(off, length);
    const sub = cmap[off .. off + length];

    const sr = Reader{ .data = sub };
    const seg_x2 = try sr.u16At(6);
    if (seg_x2 == 0 or seg_x2 % 2 != 0) return error.InvalidFont;
    const seg_count: usize = seg_x2 / 2;
    // Fixed 14 + endCode[n] + reservedPad(2) + startCode[n] + idDelta[n] + idRangeOffset[n]
    if (sub.len < 16 + 8 * seg_count) return error.InvalidFont;

    const end_off = 14;
    const reserved_off = end_off + 2 * seg_count;
    const start_off = reserved_off + 2;
    if ((try sr.u16At(reserved_off)) != 0) return error.InvalidFont; // reservedPad

    var prev_end: i32 = -1;
    var i: usize = 0;
    while (i < seg_count) : (i += 1) {
        const ec = try sr.u16At(end_off + 2 * i);
        const sc = try sr.u16At(start_off + 2 * i);
        if (sc > ec) return error.InvalidFont;
        // Require startCode > previous endCode (ascending, non-overlapping). lookup4 takes the first
        // seg with endCode>=c, so overlaps would pick the wrong seg. Reject overlaps.
        if (@as(i32, sc) <= prev_end) return error.InvalidFont;
        prev_end = ec;
    }
    return sub;
}

fn lookup4(sub: []const u8, cp: u32) u16 {
    const sr = Reader{ .data = sub };
    const seg_x2 = sr.u16At(6) catch return 0;
    const seg_count: usize = seg_x2 / 2;
    const end_off = 14;
    const start_off = end_off + 2 * seg_count + 2;
    const id_delta_off = start_off + 2 * seg_count;
    const id_range_off = id_delta_off + 2 * seg_count;
    const c: u16 = @intCast(cp); // cp <= 0xFFFF

    var i: usize = 0;
    while (i < seg_count) : (i += 1) {
        const ec = sr.u16At(end_off + 2 * i) catch return 0;
        if (ec < c) continue;
        const sc = sr.u16At(start_off + 2 * i) catch return 0;
        if (sc > c) return 0; // Codepoints below this seg are unsupported
        const id_delta = sr.i16At(id_delta_off + 2 * i) catch return 0;
        const id_range_offset = sr.u16At(id_range_off + 2 * i) catch return 0;
        if (id_range_offset == 0) {
            return c +% @as(u16, @bitCast(id_delta)); // (c + idDelta) mod 65536
        }
        // self-relative byte-address: glyph_addr = entry_addr + idRangeOffset + 2*(c - startCode)
        if (id_range_offset % 2 != 0) return 0;
        const entry_addr = id_range_off + 2 * i;
        const glyph_addr = entry_addr + @as(usize, id_range_offset) + 2 * (@as(usize, c) - sc);
        if (glyph_addr + 2 > sub.len) return 0;
        const g = sr.u16At(glyph_addr) catch return 0;
        if (g == 0) return 0; // .notdef (do not add idDelta)
        return g +% @as(u16, @bitCast(id_delta));
    }
    return 0;
}

// ── format 12 ─────────────────────────────────────────────

fn sliceFormat12(cmap: []const u8, off: usize) Error![]const u8 {
    const r = Reader{ .data = cmap };
    const length: usize = try r.u32At(off + 4);
    if (length < 16) return error.InvalidFont;
    try r.require(off, length);
    const sub = cmap[off .. off + length];

    const sr = Reader{ .data = sub };
    const num_groups: usize = try sr.u32At(12);
    // 16 + numGroups*12 <= length (use division to avoid multiply overflow)
    if ((length - 16) / 12 < num_groups) return error.InvalidFont;

    var prev_end: i64 = -1;
    var i: usize = 0;
    while (i < num_groups) : (i += 1) {
        const g = 16 + i * 12;
        const start = try sr.u32At(g);
        const end = try sr.u32At(g + 4);
        if (start > end) return error.InvalidFont;
        if (@as(i64, start) <= prev_end) return error.InvalidFont; // Ascending, non-overlapping
        prev_end = end;
    }
    return sub;
}

fn lookup12(sub: []const u8, cp: u32) u16 {
    const sr = Reader{ .data = sub };
    const num_groups = sr.u32At(12) catch return 0;
    var i: usize = 0;
    while (i < num_groups) : (i += 1) {
        const g = 16 + i * 12;
        const start = sr.u32At(g) catch return 0;
        const end = sr.u32At(g + 4) catch return 0;
        if (cp < start) return 0; // Ascending, so none after this
        if (cp <= end) {
            const start_gid = sr.u32At(g + 8) catch return 0;
            // Add in u64 (no overflow trap even for huge startGlyphID in bad fonts)
            const gid: u64 = @as(u64, start_gid) + (@as(u64, cp) - start);
            if (gid > 0xFFFF) return 0; // GID is u16
            return @intCast(gid);
        }
    }
    return 0;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

/// cmap test builder. Assembles a cmap table from encoding records + subtables.
const Builder = struct {
    const Sub = struct { platform: u16, encoding: u16, body: []const u8 };

    fn build(alloc: std.mem.Allocator, subs: []const Sub) ![]u8 {
        const n: u16 = @intCast(subs.len);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try appendU16(&out, alloc, 0); // version
        try appendU16(&out, alloc, n);
        var off: u32 = @intCast(4 + 8 * @as(usize, n));
        for (subs) |s| {
            try appendU16(&out, alloc, s.platform);
            try appendU16(&out, alloc, s.encoding);
            try appendU32(&out, alloc, off);
            off += @intCast(s.body.len);
        }
        for (subs) |s| try out.appendSlice(alloc, s.body);
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

const Seg = struct { start: u16, end: u16, id_delta: i16, id_range_offset: u16 };

/// Build a format 4 subtable. glyph_id_array is the extra array for idRangeOffset!=0.
fn buildFormat4(alloc: std.mem.Allocator, segs: []const Seg, glyph_id_array: []const u16) ![]u8 {
    const seg_count = segs.len;
    // Caller must pass segs including the trailing sentinel (0xFFFF).
    const len = 16 + 8 * seg_count + 2 * glyph_id_array.len;
    const buf = try alloc.alloc(u8, len);
    @memset(buf, 0);
    putU16(buf, 0, 4); // format
    putU16(buf, 2, @intCast(len)); // length
    putU16(buf, 6, @intCast(seg_count * 2)); // segCountX2
    const end_off = 14;
    const reserved_off = end_off + 2 * seg_count;
    const start_off = reserved_off + 2;
    const id_delta_off = start_off + 2 * seg_count;
    const id_range_off = id_delta_off + 2 * seg_count;
    for (segs, 0..) |s, i| {
        putU16(buf, end_off + 2 * i, s.end);
        putU16(buf, start_off + 2 * i, s.start);
        putU16(buf, id_delta_off + 2 * i, @bitCast(s.id_delta));
        putU16(buf, id_range_off + 2 * i, s.id_range_offset);
    }
    for (glyph_id_array, 0..) |g, i| putU16(buf, id_range_off + 2 * seg_count + 2 * i, g);
    return buf;
}

fn buildFormat12(alloc: std.mem.Allocator, groups: []const [3]u32) ![]u8 {
    const len = 16 + 12 * groups.len;
    const buf = try alloc.alloc(u8, len);
    @memset(buf, 0);
    putU16(buf, 0, 12); // format
    putU32(buf, 4, @intCast(len)); // length
    putU32(buf, 12, @intCast(groups.len)); // numGroups
    for (groups, 0..) |g, i| {
        putU32(buf, 16 + 12 * i, g[0]); // start
        putU32(buf, 16 + 12 * i + 4, g[1]); // end
        putU32(buf, 16 + 12 * i + 8, g[2]); // startGID
    }
    return buf;
}

test "cmap format 4: idRangeOffset==0 path (idDelta add)" {
    const a = testing.allocator;
    // 'A'(0x41)..'C'(0x43) → gid 10..12 (idDelta = 10-0x41), sentinel 0xFFFF
    const segs = [_]Seg{
        .{ .start = 0x41, .end = 0x43, .id_delta = @intCast(@as(i32, 10) - 0x41), .id_range_offset = 0 },
        .{ .start = 0xFFFF, .end = 0xFFFF, .id_delta = 1, .id_range_offset = 0 },
    };
    const f4 = try buildFormat4(a, &segs, &.{});
    defer a.free(f4);
    const bytes = try Builder.build(a, &.{.{ .platform = 3, .encoding = 1, .body = f4 }});
    defer a.free(bytes);

    const cm = try Cmap.parse(bytes);
    try testing.expectEqual(@as(u16, 10), cm.lookup('A'));
    try testing.expectEqual(@as(u16, 12), cm.lookup('C'));
    try testing.expectEqual(@as(u16, 0), cm.lookup('D')); // Missing
    try testing.expectEqual(@as(u16, 0), cm.lookup(0x4E00)); // Within BMP but unsupported seg
}

test "cmap format 4: idRangeOffset!=0 path (glyphIdArray indirect)" {
    const a = testing.allocator;
    // seg0: map 0x41..0x42 to [100,101] via glyphIdArray. idRangeOffset is self-relative.
    // segs are [seg0, sentinel]. glyphIdArray follows immediately after the idRangeOffset array.
    // entry_addr(seg0 idRangeOffset) = id_range_off + 0. glyphIdArray start for seg0 is
    // id_range_off + 2*seg_count (= after sentinel). idRangeOffset = (that delta) = 2*(seg_count - 0).
    const seg_count = 2;
    const id_range_offset_0: u16 = 2 * (seg_count - 0); // = 4
    const segs = [_]Seg{
        .{ .start = 0x41, .end = 0x42, .id_delta = 0, .id_range_offset = id_range_offset_0 },
        .{ .start = 0xFFFF, .end = 0xFFFF, .id_delta = 1, .id_range_offset = 0 },
    };
    const glyphs = [_]u16{ 100, 101 };
    const f4 = try buildFormat4(a, &segs, &glyphs);
    defer a.free(f4);
    const bytes = try Builder.build(a, &.{.{ .platform = 0, .encoding = 3, .body = f4 }});
    defer a.free(bytes);

    const cm = try Cmap.parse(bytes);
    try testing.expectEqual(@as(u16, 100), cm.lookup(0x41));
    try testing.expectEqual(@as(u16, 101), cm.lookup(0x42));
}

test "cmap format 12: group resolve and non-BMP" {
    const a = testing.allocator;
    const groups = [_][3]u32{
        .{ 0x41, 0x43, 10 }, // 'A'..'C' → 10..12
        .{ 0x1F600, 0x1F601, 200 }, // Emoji → 200..201
    };
    const f12 = try buildFormat12(a, &groups);
    defer a.free(f12);
    const bytes = try Builder.build(a, &.{.{ .platform = 3, .encoding = 10, .body = f12 }});
    defer a.free(bytes);

    const cm = try Cmap.parse(bytes);
    try testing.expectEqual(@as(u16, 10), cm.lookup('A'));
    try testing.expectEqual(@as(u16, 12), cm.lookup('C'));
    try testing.expectEqual(@as(u16, 200), cm.lookup(0x1F600));
    try testing.expectEqual(@as(u16, 201), cm.lookup(0x1F601));
    try testing.expectEqual(@as(u16, 0), cm.lookup(0x1F602)); // Outside groups
}

test "cmap: fall back to f4 when f12 lacks BMP but f4 has it" {
    const a = testing.allocator;
    // f12 has emoji only, f4 has 'A'. cp='A'(BMP) is 0 in f12 → resolved via f4.
    const f12 = try buildFormat12(a, &.{.{ 0x1F600, 0x1F600, 200 }});
    defer a.free(f12);
    const segs = [_]Seg{
        .{ .start = 0x41, .end = 0x41, .id_delta = @intCast(@as(i32, 10) - 0x41), .id_range_offset = 0 },
        .{ .start = 0xFFFF, .end = 0xFFFF, .id_delta = 1, .id_range_offset = 0 },
    };
    const f4 = try buildFormat4(a, &segs, &.{});
    defer a.free(f4);
    const bytes = try Builder.build(a, &.{
        .{ .platform = 3, .encoding = 10, .body = f12 },
        .{ .platform = 3, .encoding = 1, .body = f4 },
    });
    defer a.free(bytes);

    const cm = try Cmap.parse(bytes);
    try testing.expect(cm.f12 != null and cm.f4 != null);
    try testing.expectEqual(@as(u16, 200), cm.lookup(0x1F600)); // f12
    try testing.expectEqual(@as(u16, 10), cm.lookup('A')); // 0 in f12 → f4 fallback
}

test "cmap: Unicode-less subtables only is InvalidFont" {
    const a = testing.allocator;
    const f4 = try buildFormat4(a, &.{
        .{ .start = 0x41, .end = 0x41, .id_delta = 0, .id_range_offset = 0 },
        .{ .start = 0xFFFF, .end = 0xFFFF, .id_delta = 1, .id_range_offset = 0 },
    }, &.{});
    defer a.free(f4);
    // platform=1 (Macintosh) is non-Unicode
    const bytes = try Builder.build(a, &.{.{ .platform = 1, .encoding = 0, .body = f4 }});
    defer a.free(bytes);
    try testing.expectError(error.InvalidFont, Cmap.parse(bytes));
}

test "cmap format 12: non-ascending/overlapping groups is InvalidFont" {
    const a = testing.allocator;
    // Overlap (group0.end >= group1.start)
    const f12 = try buildFormat12(a, &.{ .{ 0x41, 0x50, 10 }, .{ 0x45, 0x60, 20 } });
    defer a.free(f12);
    const bytes = try Builder.build(a, &.{.{ .platform = 3, .encoding = 10, .body = f12 }});
    defer a.free(bytes);
    try testing.expectError(error.InvalidFont, Cmap.parse(bytes));
}

test "cmap format 4: startCode>endCode (bad segment) is InvalidFont" {
    const a = testing.allocator;
    const f4 = try buildFormat4(a, &.{
        .{ .start = 0x50, .end = 0x40, .id_delta = 0, .id_range_offset = 0 }, // start>end
        .{ .start = 0xFFFF, .end = 0xFFFF, .id_delta = 1, .id_range_offset = 0 },
    }, &.{});
    defer a.free(f4);
    const bytes = try Builder.build(a, &.{.{ .platform = 3, .encoding = 1, .body = f4 }});
    defer a.free(bytes);
    try testing.expectError(error.InvalidFont, Cmap.parse(bytes));
}

test "cmap: encoding record offset out of range is InvalidFont" {
    const a = testing.allocator;
    const f12 = try buildFormat12(a, &.{.{ 0x41, 0x41, 10 }});
    defer a.free(f12);
    const bytes = try Builder.build(a, &.{.{ .platform = 3, .encoding = 10, .body = f12 }});
    defer a.free(bytes);
    // Push encoding-record offset (rec=4, offset@rec+4=8) out of range
    putU32(bytes, 8, 0xFFFF_0000);
    try testing.expectError(error.InvalidFont, Cmap.parse(bytes));
}

test "cmap format 4: out-of-range idRangeOffset target → lookup 0 (no trap)" {
    const a = testing.allocator;
    // Make idRangeOffset huge so it points past glyphIdArray. lookup returns 0.
    const segs = [_]Seg{
        .{ .start = 0x41, .end = 0x41, .id_delta = 0, .id_range_offset = 0xFFFE },
        .{ .start = 0xFFFF, .end = 0xFFFF, .id_delta = 1, .id_range_offset = 0 },
    };
    const f4 = try buildFormat4(a, &segs, &.{});
    defer a.free(f4);
    const bytes = try Builder.build(a, &.{.{ .platform = 3, .encoding = 1, .body = f4 }});
    defer a.free(bytes);
    const cm = try Cmap.parse(bytes);
    try testing.expectEqual(@as(u16, 0), cm.lookup(0x41));
}

test "cmap format 4: overlapping segments is InvalidFont" {
    const a = testing.allocator;
    const f4 = try buildFormat4(a, &.{
        .{ .start = 0x40, .end = 0x50, .id_delta = 0, .id_range_offset = 0 },
        .{ .start = 0x45, .end = 0x60, .id_delta = 0, .id_range_offset = 0 }, // 0x45 <= previous endCode 0x50
    }, &.{});
    defer a.free(f4);
    const bytes = try Builder.build(a, &.{.{ .platform = 3, .encoding = 1, .body = f4 }});
    defer a.free(bytes);
    try testing.expectError(error.InvalidFont, Cmap.parse(bytes));
}

test "cmap format 12: huge startGlyphID lookup returns 0 without trap" {
    const a = testing.allocator;
    const f12 = try buildFormat12(a, &.{.{ 0x41, 0x42, 0xFFFF_FFFF }});
    defer a.free(f12);
    const bytes = try Builder.build(a, &.{.{ .platform = 3, .encoding = 10, .body = f12 }});
    defer a.free(bytes);
    const cm = try Cmap.parse(bytes);
    try testing.expectEqual(@as(u16, 0), cm.lookup(0x42)); // gid exceeds u16 range → 0
}

test "cmap: non-zero header version is InvalidFont" {
    const a = testing.allocator;
    const f12 = try buildFormat12(a, &.{.{ 0x41, 0x41, 10 }});
    defer a.free(f12);
    const bytes = try Builder.build(a, &.{.{ .platform = 3, .encoding = 10, .body = f12 }});
    defer a.free(bytes);
    putU16(bytes, 0, 1); // version = 1
    try testing.expectError(error.InvalidFont, Cmap.parse(bytes));
}
