// sbix table parser. Safely parses the sfnt 'sbix' table (embedded bitmaps; used by color emoji fonts to
// store PNGs).
//
// Reads glyph records (graphicType + origin offset +
// embedded byte payload) per strike (resolution variants in ppem units), and selects the strike / bitmap from GID and target px.
// Does not decode PNG, cache (GID,px), resolve cmap emoji, or wire into FontFace
// (out of scope here).
//
// Hot-path declaration: **init-time only** (parse on font load) + **event-time only** (glyph
// resolve on cache miss). Does not run on per-frame (all-pixel) / RT (per-sample) paths
// → outside the performance rules (SIMD three-point set, cache_line separation, before/after bench).
//
// Design (same shape as sfnt.zig / glyf.zig / cmap.zig):
//   - Reads go through byte_reader.zig Reader (BE + overflow-safe bounds checks). Out of range is
//     error.InvalidFont. Raw bytes are borrowed (not copied). Reading is on a table-local slice.
//   - At parse time, run "cheap structure validation" (header + each strike header range) eagerly;
//     glyph-record validation is lazy on access (glyphData), same shape as glyf.zig glyphData.
//   - No allocation (Sbix holds only slices + scalars; except the test builder).
//
// Binary layout (OpenType 'sbix' spec):
//   - Header: version(u16, ==1) / flags(u16) / numStrikes(u32) /
//     strikeOffsets[numStrikes](u32, relative to sbix table start).
//   - strike: ppem(u16) / ppi(u16) / glyphDataOffsets[numGlyphs+1](u32, relative to strike start).
//   - glyph record: originOffsetX(i16) / originOffsetY(i16) / graphicType(4byte tag) / data.
//     Record length = offsets[gid+1] − offsets[gid]. 0 means "no bitmap in this strike";
//     1..7 is invalid; 8+ is header(8byte) + data.
//
// graphicType handling:
//   - 'png ': return bytes as-is (do not decode). Empty data (record length 8) is allowed and returns empty bytes.
//   - 'dupe': strictly require data length == 2 (referenced GID as u16). Re-resolve another GID in the same strike.
//     The result **uses the referenced record's originOffset** (not stated explicitly in OpenType;
//     follows FreeType. Fixed as this implementation's contract).
//   - 'jpg ' / 'tiff' / unknown tag: unsupported → same as "no bitmap" (null)
//     (so that strike can be skipped and gracefully fall back to other strikes / outlines).
//
// Error policy: structural corruption (reversed offsets, out of range, record length 1..7, dupe violations, out-of-range GID args) is
// error.InvalidFont. findGlyph must not swallow structural errors from intermediate strikes; it propagates them.

const std = @import("std");
const Reader = @import("byte_reader.zig").Reader;
const sfnt = @import("sfnt.zig");

pub const Error = error{InvalidFont};

/// Hard cap on dupe following (guards against cycles / excessive depth. Spec does not expect dupe→dupe, but follow defensively).
const max_dupe_depth: u32 = 4;

/// Required strike-header length (bytes relative to strike start): ppem(2)+ppi(2)+glyphDataOffsets[n+1](4*(n+1)).
fn strikeHeaderLen(num_glyphs: u16) usize {
    return 4 + (@as(usize, num_glyphs) + 1) * 4;
}

pub const Sbix = struct {
    /// sbix table-local slice (borrowed).
    data: []const u8,
    num_glyphs: u16,
    version: u16,
    /// bit1(draw outlines) and similar are kept only so callers can read them (not validated).
    flags: u16,
    num_strikes: u32,

    pub const Strike = struct { index: u32, ppem: u16, ppi: u16 };

    pub const GlyphData = struct {
        origin_offset_x: i16,
        origin_offset_y: i16,
        /// Always 'png ' after dupe resolution (kept to match that wording).
        graphic_type: [4]u8,
        /// Raw PNG bytes (borrowed). Decode is out of scope here.
        bytes: []const u8,
    };

    pub const FoundGlyph = struct { strike: Strike, glyph: GlyphData };

    /// Parse an sbix table (sfnt-independent; unit-testable).
    /// Validates: version==1 / numStrikes>=1 / strikeOffsets array fits in the table (overflow-safe) /
    /// each strikeOffset does not point inside the header/offsets array (lower bound) / each strike header
    /// (ppem+ppi+glyphDataOffsets[numGlyphs+1]) fits in the table. Glyph-record validation itself is lazy.
    pub fn parse(table: []const u8, num_glyphs: u16) Error!Sbix {
        const r = Reader{ .data = table };
        try r.require(0, 8);
        const version = try r.u16At(0);
        if (version != 1) return error.InvalidFont;
        const flags = try r.u16At(2);
        const num_strikes = try r.u32At(4);
        if (num_strikes == 0) return error.InvalidFont;

        const offsets_len = std.math.mul(usize, @as(usize, num_strikes), 4) catch return error.InvalidFont;
        try r.require(8, offsets_len);
        const header_end = 8 + offsets_len; // Already required, so no overflow

        const strike_header_len = strikeHeaderLen(num_glyphs);

        var i: u32 = 0;
        while (i < num_strikes) : (i += 1) {
            const off: usize = try r.u32At(8 + @as(usize, i) * 4);
            // Lower bound: reject crafted tables whose strikeOffset points inside the header + strikeOffsets array
            // (same shape as sfnt.zig TTC `base < 12 + ot_len` check).
            if (off < header_end) return error.InvalidFont;
            // Upper bound: the whole strike header (ppem/ppi/glyphDataOffsets array) fits in the table.
            try r.require(off, strike_header_len);
        }

        return .{
            .data = table,
            .num_glyphs = num_glyphs,
            .version = version,
            .flags = flags,
            .num_strikes = num_strikes,
        };
    }

    /// Find and parse the 'sbix' table from sfnt. Missing table is null.
    pub fn init(font: *const sfnt.SfntFile) Error!?Sbix {
        const table = (font.tableSlice("sbix") catch return error.InvalidFont) orelse return null;
        return try parse(table, font.num_glyphs);
    }

    fn strikeOffsetAt(self: *const Sbix, index: u32) Error!usize {
        if (index >= self.num_strikes) return error.InvalidFont;
        const r = Reader{ .data = self.data };
        return try r.u32At(8 + @as(usize, index) * 4);
    }

    /// Return the strike at index (ppem/ppi). Callers can walk all strikes for enumeration.
    pub fn strikeAt(self: *const Sbix, index: u32) Error!Strike {
        const off = try self.strikeOffsetAt(index);
        const r = Reader{ .data = self.data };
        const ppem = try r.u16At(off);
        const ppi = try r.u16At(off + 2);
        return .{ .index = index, .ppem = ppem, .ppi = ppi };
    }

    /// Fixed strike-selection rule: pick the smallest ppem ≥ target px. If none, pick the largest ppem.
    /// Ignore ppi. When multiple strikes share the same ppem, first-wins by strike array order.
    pub fn selectStrike(self: *const Sbix, target_px: u32) Error!Strike {
        var best_above: ?Strike = null; // Smallest ppem ≥ target
        var best_max: ?Strike = null; // Largest ppem overall (fallback)
        var i: u32 = 0;
        while (i < self.num_strikes) : (i += 1) {
            const s = try self.strikeAt(i);
            if (best_max == null or s.ppem > best_max.?.ppem) best_max = s;
            if (s.ppem >= target_px) {
                if (best_above == null or s.ppem < best_above.?.ppem) best_above = s;
            }
        }
        // num_strikes >= 1 (guaranteed by parse), so best_max is always set.
        return best_above orelse best_max.?;
    }

    /// Return glyph data for strike_index and gid (dupe-resolved). No bitmap (0-length record,
    /// jpg/tiff/unknown tag) is null. Structural corruption is InvalidFont.
    pub fn glyphData(self: *const Sbix, strike_index: u32, gid: u16) Error!?GlyphData {
        if (gid >= self.num_glyphs) return error.InvalidFont;
        const strike_off = try self.strikeOffsetAt(strike_index);
        return self.resolveGlyphData(strike_off, gid, 0);
    }

    fn resolveGlyphData(self: *const Sbix, strike_off: usize, gid: u16, depth: u32) Error!?GlyphData {
        if (depth > max_dupe_depth) return error.InvalidFont;
        if (gid >= self.num_glyphs) return error.InvalidFont; // Re-validate the dupe target

        const r = Reader{ .data = self.data };
        const rec_off = strike_off + 4 + @as(usize, gid) * 4;
        const off0: usize = try r.u32At(rec_off);
        const off1: usize = try r.u32At(rec_off + 4);
        if (off0 > off1) return error.InvalidFont;
        if (off0 == off1) return null; // No bitmap (even on lower-bound violation, reading 0 bytes is safe → null)

        const strike_slice_len = self.data.len - strike_off; // strike_off was validated <= data.len at parse
        const header_len = strikeHeaderLen(self.num_glyphs);
        // Lower bound: reject non-empty records that point inside the header (ppem/ppi/glyphDataOffsets array).
        // Upper bound: reject ranges past the remaining strike region.
        if (off0 < header_len or off1 > strike_slice_len) return error.InvalidFont;

        const record = self.data[strike_off + off0 .. strike_off + off1];
        if (record.len < 8) return error.InvalidFont; // 1..7 is invalid (header is complete only at 8+)

        const rr = Reader{ .data = record };
        const ox = try rr.i16At(0);
        const oy = try rr.i16At(2);
        var gtype: [4]u8 = undefined;
        @memcpy(&gtype, record[4..8]);

        if (std.mem.eql(u8, &gtype, "png ")) {
            return GlyphData{
                .origin_offset_x = ox,
                .origin_offset_y = oy,
                .graphic_type = gtype,
                .bytes = record[8..],
            };
        } else if (std.mem.eql(u8, &gtype, "dupe")) {
            if (record.len != 10) return error.InvalidFont; // data length must be exactly 2 bytes
            const ref_gid = try rr.u16At(8);
            if (ref_gid >= self.num_glyphs) return error.InvalidFont;
            return self.resolveGlyphData(strike_off, ref_gid, depth + 1);
        } else {
            // jpg / tiff / unknown tag: unsupported → same as "no bitmap".
            return null;
        }
    }

    const Candidate = struct { ppem: u16, index: u32 };

    fn beforeAsc(a: Candidate, b: Candidate) bool {
        return a.ppem < b.ppem or (a.ppem == b.ppem and a.index < b.index);
    }
    fn beforeDesc(a: Candidate, b: Candidate) bool {
        return a.ppem > b.ppem or (a.ppem == b.ppem and a.index < b.index);
    }

    /// Resolve a bitmap across strikes from GID and target px.
    /// Preference order re-applies the same selectStrike rules to the remaining set:
    /// ppem ≥ target ascending → ppem < target descending (same ppem: first-wins by array order).
    /// Must not swallow structural errors (InvalidFont) from intermediate strikes; propagate them. null if no strike has a bitmap.
    pub fn findGlyph(self: *const Sbix, target_px: u32, gid: u16) Error!?FoundGlyph {
        if (gid >= self.num_glyphs) return error.InvalidFont;

        // Phase A: try ppem >= target_px ascending (same ppem: ascending index).
        var last: ?Candidate = null;
        while (true) {
            var best: ?Candidate = null;
            var i: u32 = 0;
            while (i < self.num_strikes) : (i += 1) {
                const s = try self.strikeAt(i);
                if (s.ppem < target_px) continue;
                const c = Candidate{ .ppem = s.ppem, .index = i };
                if (last) |l| {
                    if (!beforeAsc(l, c)) continue;
                }
                if (best == null or beforeAsc(c, best.?)) best = c;
            }
            const cand = best orelse break;
            last = cand;
            if (try self.glyphData(cand.index, gid)) |g| {
                return .{ .strike = try self.strikeAt(cand.index), .glyph = g };
            }
        }

        // Phase B: try ppem < target_px descending (same ppem: ascending index).
        last = null;
        while (true) {
            var best: ?Candidate = null;
            var i: u32 = 0;
            while (i < self.num_strikes) : (i += 1) {
                const s = try self.strikeAt(i);
                if (s.ppem >= target_px) continue;
                const c = Candidate{ .ppem = s.ppem, .index = i };
                if (last) |l| {
                    if (!beforeDesc(l, c)) continue;
                }
                if (best == null or beforeDesc(c, best.?)) best = c;
            }
            const cand = best orelse break;
            last = cand;
            if (try self.glyphData(cand.index, gid)) |g| {
                return .{ .strike = try self.strikeAt(cand.index), .glyph = g };
            }
        }

        return null;
    }
};

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
fn appendU16(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u16) !void {
    try list.append(alloc, @intCast(v >> 8));
    try list.append(alloc, @truncate(v));
}
fn appendI16(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: i16) !void {
    try appendU16(list, alloc, @bitCast(v));
}
fn appendU32(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u32) !void {
    try list.append(alloc, @truncate(v >> 24));
    try list.append(alloc, @truncate(v >> 16));
    try list.append(alloc, @truncate(v >> 8));
    try list.append(alloc, @truncate(v));
}

/// Glyph-record description for synthetic sbix test data. The builder auto-computes the offset array.
/// **Test-only** (pub so outline_font.zig integration tests can reuse synthetic sbix byte generation.
/// Do not use from production code).
pub const RecordSpec = union(enum) {
    /// No bitmap (off0==off1).
    empty,
    png: Png,
    dupe: Dupe,
    /// Low-level way to write jpg/tiff/unknown tags or invalid data lengths directly (negative tests for dupe etc.).
    raw: Raw,

    const Png = struct { x: i16 = 0, y: i16 = 0, bytes: []const u8 = &.{} };
    const Dupe = struct { x: i16 = 0, y: i16 = 0, gid: u16 };
    const Raw = struct { x: i16 = 0, y: i16 = 0, kind: [4]u8, data: []const u8 = &.{} };
};

/// **Test-only** (pub for the same reason as RecordSpec).
pub const StrikeSpec = struct {
    ppem: u16,
    ppi: u16 = 72,
    /// Length must match num_glyphs (describe each gid's record in order).
    records: []const RecordSpec,
};

/// Build a correct sbix byte sequence from strikes (caller frees).
/// **Test-only** (pub for the same reason as RecordSpec. Do not use from production code).
/// Tests that use a single-strike fixture (num_strikes==1) can rely on strikeOffsets[0] always at
/// absolute position 8, the strike body always at absolute position 12, and the glyphDataOffsets array always starting at absolute position 16
/// (header length is fixed) to overwrite normal-case bytes for boundary tests.
pub fn buildSbix(alloc: std.mem.Allocator, num_glyphs: u16, strikes: []const StrikeSpec) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try appendU16(&out, alloc, 1); // version
    try appendU16(&out, alloc, 0); // flags
    try appendU32(&out, alloc, @intCast(strikes.len)); // numStrikes

    const offsets_pos = out.items.len;
    for (0..strikes.len) |_| try appendU32(&out, alloc, 0); // strikeOffsets placeholder

    for (strikes, 0..) |sp, i| {
        std.debug.assert(sp.records.len == num_glyphs);
        const strike_abs = out.items.len;
        putU32(out.items, offsets_pos + i * 4, @intCast(strike_abs));

        try appendU16(&out, alloc, sp.ppem);
        try appendU16(&out, alloc, sp.ppi);
        const goff_pos = out.items.len;
        for (0..@as(usize, num_glyphs) + 1) |_| try appendU32(&out, alloc, 0); // glyphDataOffsets placeholder

        var g: usize = 0;
        while (g <= num_glyphs) : (g += 1) {
            const rel: u32 = @intCast(out.items.len - strike_abs);
            putU32(out.items, goff_pos + g * 4, rel);
            if (g == num_glyphs) break;
            switch (sp.records[g]) {
                .empty => {},
                .png => |p| {
                    try appendI16(&out, alloc, p.x);
                    try appendI16(&out, alloc, p.y);
                    try out.appendSlice(alloc, "png ");
                    try out.appendSlice(alloc, p.bytes);
                },
                .dupe => |d| {
                    try appendI16(&out, alloc, d.x);
                    try appendI16(&out, alloc, d.y);
                    try out.appendSlice(alloc, "dupe");
                    try appendU16(&out, alloc, d.gid);
                },
                .raw => |rw| {
                    try appendI16(&out, alloc, rw.x);
                    try appendI16(&out, alloc, rw.y);
                    try out.appendSlice(alloc, &rw.kind);
                    try out.appendSlice(alloc, rw.data);
                },
            }
        }
    }
    return out.toOwnedSlice(alloc);
}

// ── Normal case + truncation ─────────────────────────────────────────

test "sbix: happy path (2 strikes · multi records) reads version/flags/numStrikes/ppem/ppi/offsets" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 2, &.{
        .{ .ppem = 20, .ppi = 72, .records = &.{ .empty, .{ .png = .{ .bytes = &.{ 1, 2, 3 } } } } },
        .{ .ppem = 40, .ppi = 144, .records = &.{ .{ .png = .{ .bytes = &.{4} } }, .empty } },
    });
    defer a.free(bytes);

    const s = try Sbix.parse(bytes, 2);
    try testing.expectEqual(@as(u16, 1), s.version);
    try testing.expectEqual(@as(u16, 0), s.flags);
    try testing.expectEqual(@as(u32, 2), s.num_strikes);

    const st0 = try s.strikeAt(0);
    try testing.expectEqual(@as(u16, 20), st0.ppem);
    try testing.expectEqual(@as(u16, 72), st0.ppi);
    const st1 = try s.strikeAt(1);
    try testing.expectEqual(@as(u16, 40), st1.ppem);
    try testing.expectEqual(@as(u16, 144), st1.ppi);

    // strike0: gid0=empty, gid1=png
    try testing.expect((try s.glyphData(0, 0)) == null);
    const g01 = (try s.glyphData(0, 1)).?;
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, g01.bytes);
    // strike1: gid0=png, gid1=empty
    const g10 = (try s.glyphData(1, 0)).?;
    try testing.expectEqualSlices(u8, &.{4}, g10.bytes);
    try testing.expect((try s.glyphData(1, 1)) == null);
}

test "sbix: truncated below header is InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 16, .records = &.{.empty} }});
    defer a.free(bytes);
    try testing.expectError(error.InvalidFont, Sbix.parse(bytes[0..4], 1)); // Fewer than 8 bytes
}

test "sbix: truncated with incomplete strikeOffsets array is InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 16, .records = &.{.empty} }});
    defer a.free(bytes);
    try testing.expectError(error.InvalidFont, Sbix.parse(bytes[0..10], 1)); // strikeOffsets[0] needs 4 bytes (8..12) but only through 10
}

test "sbix: truncated with incomplete strike header is InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 16, .records = &.{.empty} }});
    defer a.free(bytes);
    // Strike body starts at absolute position 12 and needs ppem(2)+ppi(2)+offsets[2](8) = 16 bytes. Through 14 is short.
    try testing.expectError(error.InvalidFont, Sbix.parse(bytes[0..14], 1));
}

test "sbix: version != 1 is InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 16, .records = &.{.empty} }});
    defer a.free(bytes);
    const corrupt = try a.dupe(u8, bytes);
    defer a.free(corrupt);
    putU16(corrupt, 0, 2); // version=2
    try testing.expectError(error.InvalidFont, Sbix.parse(corrupt, 1));
}

test "sbix: numStrikes == 0 is InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 16, .records = &.{.empty} }});
    defer a.free(bytes);
    const corrupt = try a.dupe(u8, bytes);
    defer a.free(corrupt);
    putU32(corrupt, 4, 0); // numStrikes=0
    try testing.expectError(error.InvalidFont, Sbix.parse(corrupt, 1));
}

test "sbix: oversized numStrikes (offsets array past table) is InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 16, .records = &.{.empty} }});
    defer a.free(bytes);
    const corrupt = try a.dupe(u8, bytes);
    defer a.free(corrupt);
    putU32(corrupt, 4, 100); // numStrikes=100 but the table only has room for 1 strike
    try testing.expectError(error.InvalidFont, Sbix.parse(corrupt, 1));
}

// ── strikeOffset bounds ────────────────────────────────────

test "sbix: strikeOffset pointing inside header/offsets array (lower-bound violation) is InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 16, .records = &.{.empty} }});
    defer a.free(bytes);
    const corrupt = try a.dupe(u8, bytes);
    defer a.free(corrupt);
    // strikeOffsets[0] is absolute position 8. Rewrite the valid value 12 to inside the header (4).
    putU32(corrupt, 8, 4);
    try testing.expectError(error.InvalidFont, Sbix.parse(corrupt, 1));
}

test "sbix: strikeOffset that cannot fit the full strike header in table (upper-bound / OOB) is InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 16, .records = &.{.empty} }});
    defer a.free(bytes);
    // Truncate the strike body (absolute position 12) leaving only 2 bytes (ppem readable but not ppi/offsets).
    try testing.expectError(error.InvalidFont, Sbix.parse(bytes[0..14], 1));
}

// ── graphicType (png/dupe/jpg/tiff/unknown) ──────────────────

test "sbix: png record returns origin/type/bytes" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 32, .records = &.{
        .{ .png = .{ .x = 3, .y = -5, .bytes = &.{ 0xAA, 0xBB } } },
    } }});
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    const g = (try s.glyphData(0, 0)).?;
    try testing.expectEqual(@as(i16, 3), g.origin_offset_x);
    try testing.expectEqual(@as(i16, -5), g.origin_offset_y);
    try testing.expectEqualSlices(u8, "png ", &g.graphic_type);
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB }, g.bytes);
}

test "sbix: dupe follows the referent GID bitmap" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 2, &.{.{ .ppem = 32, .records = &.{
        .{ .dupe = .{ .gid = 1 } },
        .{ .png = .{ .bytes = &.{ 9, 9 } } },
    } }});
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 2);
    const g = (try s.glyphData(0, 0)).?;
    try testing.expectEqualSlices(u8, &.{ 9, 9 }, g.bytes);
    try testing.expectEqualSlices(u8, "png ", &g.graphic_type);
}

test "sbix: jpg/tiff/unknown tag treated as no bitmap (null)" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 3, &.{.{ .ppem = 32, .records = &.{
        .{ .raw = .{ .kind = "jpg ".*, .data = &.{1} } },
        .{ .raw = .{ .kind = "tiff".*, .data = &.{1} } },
        .{ .raw = .{ .kind = "zzzz".*, .data = &.{1} } },
    } }});
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 3);
    try testing.expect((try s.glyphData(0, 0)) == null);
    try testing.expect((try s.glyphData(0, 1)) == null);
    try testing.expect((try s.glyphData(0, 2)) == null);
}

// ── dupe safety ──────────────────────────────────────────

test "sbix: dupe data length != 2 is InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{
        .ppem = 32,
        .records = &.{
            .{ .raw = .{ .kind = "dupe".*, .data = &.{ 1, 2, 3 } } }, // 3 bytes (invalid)
        },
    }});
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    try testing.expectError(error.InvalidFont, s.glyphData(0, 0));
}

test "sbix: dupe referent GID out of range is InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{
        .ppem = 32,
        .records = &.{
            .{ .dupe = .{ .gid = 5 } }, // numGlyphs=1 so out of range
        },
    }});
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    try testing.expectError(error.InvalidFont, s.glyphData(0, 0));
}

test "sbix: dupe self-reference exceeds depth cap → InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{
        .ppem = 32,
        .records = &.{
            .{ .dupe = .{ .gid = 0 } }, // Self-reference (stop infinite loop via depth cap)
        },
    }});
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    try testing.expectError(error.InvalidFont, s.glyphData(0, 0));
}

test "sbix: dupe mutual cycle exceeds depth cap → InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 2, &.{.{ .ppem = 32, .records = &.{
        .{ .dupe = .{ .gid = 1 } },
        .{ .dupe = .{ .gid = 0 } },
    } }});
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 2);
    try testing.expectError(error.InvalidFont, s.glyphData(0, 0));
}

test "sbix: dupe→png adopts the referent record's origin (this implementation's spec)" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 2, &.{.{
        .ppem = 32,
        .records = &.{
            .{ .dupe = .{ .x = 999, .y = 888, .gid = 1 } }, // Own origin is ignored
            .{ .png = .{ .x = 5, .y = 7, .bytes = &.{ 1, 2, 3 } } },
        },
    }});
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 2);
    const g = (try s.glyphData(0, 0)).?;
    try testing.expectEqual(@as(i16, 5), g.origin_offset_x);
    try testing.expectEqual(@as(i16, 7), g.origin_offset_y);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, g.bytes);
}

// ── glyphDataOffset bounds (record) ────────────────────

test "sbix: glyphDataOffset reversal (off0 > off1) is InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 2, &.{.{ .ppem = 32, .records = &.{
        .{ .png = .{ .bytes = &.{1} } },
        .{ .png = .{ .bytes = &.{1} } },
    } }});
    defer a.free(bytes);
    const corrupt = try a.dupe(u8, bytes);
    defer a.free(corrupt);
    // With a single strike and numGlyphs=2, glyphDataOffsets[gid] is fixed at absolute position 16+4*gid.
    // Rewrite offsets[1] to a value smaller than offsets[0] to reverse gid0's record.
    putU32(corrupt, 16 + 4 * 1, 0);
    const s = try Sbix.parse(corrupt, 2);
    try testing.expectError(error.InvalidFont, s.glyphData(0, 0));
}

test "sbix: glyphDataOffset record length 1..7 (neither 0 nor ≥8) is InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{
        .ppem = 32,
        .records = &.{
            .{ .png = .{ .bytes = &.{} } }, // Natural length is 8 (header only)
        },
    }});
    defer a.free(bytes);
    const corrupt = try a.dupe(u8, bytes);
    defer a.free(corrupt);
    // Rewrite offsets[0]=12(header_len), offsets[1] (absolute position 16+4=20) to 12+3=15 so record length is 3.
    putU32(corrupt, 16 + 4 * 1, 15);
    const s = try Sbix.parse(corrupt, 1);
    try testing.expectError(error.InvalidFont, s.glyphData(0, 0));
}

test "sbix: non-empty record glyphDataOffset pointing inside header (lower-bound violation) is InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 32, .records = &.{
        .{ .png = .{ .bytes = &.{ 1, 2 } } },
    } }});
    defer a.free(bytes);
    const corrupt = try a.dupe(u8, bytes);
    defer a.free(corrupt);
    // Rewrite offsets[0] (absolute position 16) to 0 (leave off1 as-is. off0!=off1 so non-empty).
    putU32(corrupt, 16 + 4 * 0, 0);
    const s = try Sbix.parse(corrupt, 1);
    try testing.expectError(error.InvalidFont, s.glyphData(0, 0));
}

test "sbix: empty record (off0==off1) returns null even with lower-bound violation (safe exception)" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 32, .records = &.{.empty} }});
    defer a.free(bytes);
    const corrupt = try a.dupe(u8, bytes);
    defer a.free(corrupt);
    // Rewrite both offsets[0] and offsets[1] to 0 (off0==off1==0 is a lower-bound-violation value inside the header, but
    // the contract returns null safely because 0 bytes are read).
    putU32(corrupt, 16 + 4 * 0, 0);
    putU32(corrupt, 16 + 4 * 1, 0);
    const s = try Sbix.parse(corrupt, 1);
    try testing.expect((try s.glyphData(0, 0)) == null);
}

test "sbix: glyphDataOffset past remaining strike region (OOB) is InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 32, .records = &.{
        .{ .png = .{ .bytes = &.{1} } },
    } }});
    defer a.free(bytes);
    const corrupt = try a.dupe(u8, bytes);
    defer a.free(corrupt);
    putU32(corrupt, 16 + 4 * 1, 0xFFFFFF); // offsets[1](sentinel) to a huge value
    const s = try Sbix.parse(corrupt, 1);
    try testing.expectError(error.InvalidFont, s.glyphData(0, 0));
}

// ── Out-of-range GID argument ──────────────────────────────────────────

test "sbix: out-of-range GID arg is InvalidFont (glyphData / findGlyph)" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 32, .records = &.{.empty} }});
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    try testing.expectError(error.InvalidFont, s.glyphData(0, 1)); // gid==numGlyphs
    try testing.expectError(error.InvalidFont, s.findGlyph(32, 1));
}

test "sbix: out-of-range strike index is InvalidFont (strikeAt / glyphData)" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 32, .records = &.{.empty} }});
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    try testing.expectError(error.InvalidFont, s.strikeAt(1));
    try testing.expectError(error.InvalidFont, s.glyphData(1, 0));
}

// ── Cross-strike coverage resolution ────────────────────────

test "sbix: findGlyph resolves a GID missing in strike A but present in B from B" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 16, .records = &.{.empty} }, // strike A: no bitmap
        .{ .ppem = 32, .records = &.{.{ .png = .{ .bytes = &.{7} } }} }, // strike B: has bitmap
    });
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    const found = (try s.findGlyph(16, 0)).?; // target=16 prefers strike A(16) but it has none, so fall through to B
    try testing.expectEqual(@as(u32, 1), found.strike.index);
    try testing.expectEqualSlices(u8, &.{7}, found.glyph.bytes);
}

test "sbix: findGlyph falls back in descending ppem when all strikes are below target" {
    const a = testing.allocator;
    // target=100. No strike with ppem>=100. Confirm 40(largest) has no bitmap → next 20 has one.
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 40, .records = &.{.empty} },
        .{ .ppem = 20, .records = &.{.{ .png = .{ .bytes = &.{5} } }} },
    });
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    const found = (try s.findGlyph(100, 0)).?;
    try testing.expectEqual(@as(u32, 1), found.strike.index);
    try testing.expectEqualSlices(u8, &.{5}, found.glyph.bytes);
}

test "sbix: findGlyph at equal ppem tries first-wins (ascending index) then next equal if no bitmap" {
    const a = testing.allocator;
    // target=32. Two strikes with ppem=32 at index0,1. 0 has no bitmap → try first-wins but empty, so advance to index1.
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 32, .records = &.{.empty} },
        .{ .ppem = 32, .records = &.{.{ .png = .{ .bytes = &.{9} } }} },
    });
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    const found = (try s.findGlyph(32, 0)).?;
    try testing.expectEqual(@as(u32, 1), found.strike.index);
    try testing.expectEqualSlices(u8, &.{9}, found.glyph.bytes);
}

test "sbix: findGlyph scans correctly even when strike array is not ascending by ppem" {
    const a = testing.allocator;
    // Array order: 64(no bitmap), 16(no bitmap), 32(has bitmap). target=20 → ppem>=20 is {64,32} but
    // try in ppem ascending order (32 first), not array order (64 first), so 32 with bitmap is found immediately.
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 64, .records = &.{.empty} },
        .{ .ppem = 16, .records = &.{.empty} },
        .{ .ppem = 32, .records = &.{.{ .png = .{ .bytes = &.{3} } }} },
    });
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    const found = (try s.findGlyph(20, 0)).?;
    try testing.expectEqual(@as(u32, 2), found.strike.index);
    try testing.expectEqualSlices(u8, &.{3}, found.glyph.bytes);
}

test "sbix: findGlyph multi-step falls back in descending ppem when all are below target" {
    const a = testing.allocator;
    // target=100. Descending candidates: 40(none)→20(none)→10(has).
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 40, .records = &.{.empty} },
        .{ .ppem = 20, .records = &.{.empty} },
        .{ .ppem = 10, .records = &.{.{ .png = .{ .bytes = &.{1} } }} },
    });
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    const found = (try s.findGlyph(100, 0)).?;
    try testing.expectEqual(@as(u32, 2), found.strike.index);
    try testing.expectEqualSlices(u8, &.{1}, found.glyph.bytes);
}

test "sbix: findGlyph returns null when absent from all strikes (enumerable via strikeAt)" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 16, .records = &.{.empty} },
        .{ .ppem = 32, .records = &.{.empty} },
    });
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    try testing.expect((try s.findGlyph(16, 0)) == null);
    try testing.expectEqual(@as(u32, 2), s.num_strikes);
    try testing.expectEqual(@as(u16, 16), (try s.strikeAt(0)).ppem);
    try testing.expectEqual(@as(u16, 32), (try s.strikeAt(1)).ppem);
}

test "sbix: findGlyph propagates mid-strike structural errors (must not swallow)" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 16, .records = &.{.{ .png = .{ .bytes = &.{1} } }} },
    });
    defer a.free(bytes);
    const corrupt = try a.dupe(u8, bytes);
    defer a.free(corrupt);
    putU32(corrupt, 16 + 4 * 1, 0xFFFFFF); // Corrupt strike0 gid0 record out of range
    const s = try Sbix.parse(corrupt, 1);
    try testing.expectError(error.InvalidFont, s.findGlyph(16, 0));
}

// ── selectStrike fixed rules ─────────────────────────────────

test "sbix: selectStrike picks the smallest ppem ≥ target px" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 16, .records = &.{.empty} },
        .{ .ppem = 32, .records = &.{.empty} },
        .{ .ppem = 64, .records = &.{.empty} },
    });
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    try testing.expectEqual(@as(u16, 32), (try s.selectStrike(20)).ppem);
    try testing.expectEqual(@as(u16, 16), (try s.selectStrike(16)).ppem); // Exact match
}

test "sbix: selectStrike picks the largest ppem when all are below target" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 16, .records = &.{.empty} },
        .{ .ppem = 32, .records = &.{.empty} },
    });
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    try testing.expectEqual(@as(u16, 32), (try s.selectStrike(100)).ppem);
}

test "sbix: selectStrike first-wins by strike array order at equal ppem (ppi ignored)" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 32, .ppi = 72, .records = &.{.empty} },
        .{ .ppem = 32, .ppi = 144, .records = &.{.empty} },
    });
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    const sel = try s.selectStrike(20);
    try testing.expectEqual(@as(u32, 0), sel.index); // First-wins
    try testing.expectEqual(@as(u16, 72), sel.ppi);
}

test "sbix: selectStrike picks correctly even when strike array is not ascending by ppem" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 64, .records = &.{.empty} },
        .{ .ppem = 16, .records = &.{.empty} },
        .{ .ppem = 32, .records = &.{.empty} },
    });
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    try testing.expectEqual(@as(u16, 32), (try s.selectStrike(20)).ppem);
    try testing.expectEqual(@as(u16, 16), (try s.selectStrike(0)).ppem);
}
