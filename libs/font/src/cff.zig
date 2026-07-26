// Parser for CFF / CFF2 containers.
// - 'CFF ' (CFF1): header / INDEX / Top DICT / Private / subr / CID
// - 'CFF2': header(v2) / TopDICT / GlobalSubr / CharStrings / FontDICTINDEX / Private /
//          optional VariationStore + FDSelect. No Encoding/Charset/String INDEX.
//
// Hot-path declaration: parse runs only at FontFace.init. outline only on raster cache miss.

const std = @import("std");
const Reader = @import("byte_reader.zig").Reader;
const ol_mod = @import("outline.zig");
const cs = @import("charstring.zig");
const ivs = @import("ivs.zig");

const Index = cs.Index;

pub const Error = error{ InvalidFont, Unsupported, OutOfMemory };

pub const CffFont = struct {
    data: []const u8,
    charstrings: Index,
    gsubrs: Index,
    // For non-CID (unused for CID: resolved per-glyph instead)
    lsubrs: Index,
    nominal_width: f64,
    default_width: f64,
    // For CID
    is_cid: bool,
    fdarray: Index,
    fdselect: FDSelect,
    num_glyphs: u16,

    pub fn parse(data: []const u8) Error!CffFont {
        const r = Reader{ .data = data };
        // header: major minor hdrSize offSize
        const hdr_size = try r.u8At(2);
        if (hdr_size < 4) return error.InvalidFont;

        const name_index = try Index.parse(data, hdr_size);
        const top_index = try Index.parse(data, name_index.end);
        if (top_index.count != 1) return error.InvalidFont; // OpenType CFF has one Top DICT entry
        const string_index = try Index.parse(data, top_index.end);
        const gsubrs = try Index.parse(data, string_index.end);

        const top = try parseTopDict(top_index.get(0).?);
        if (top.charstring_type != 2) return error.Unsupported; // Type2 only

        const cs_off = top.charstrings_off orelse return error.InvalidFont;
        const charstrings = try Index.parse(data, cs_off);
        const num_glyphs: u16 = std.math.cast(u16, charstrings.count) orelse return error.InvalidFont;

        // charset: if custom(>2), verify bytes covering numGlyphs are within the table (SIDs not retained).
        if (top.charset_off) |co| {
            if (co > 2) try validateCharset(data, co, num_glyphs);
        }

        var font = CffFont{
            .data = data,
            .charstrings = charstrings,
            .gsubrs = gsubrs,
            .lsubrs = cs.Index{ .data = data, .count = 0, .off_size = 0, .offsets_start = 0, .obj_base = 0, .end = 0 },
            .nominal_width = 0,
            .default_width = 0,
            .is_cid = top.is_cid,
            .fdarray = undefined,
            .fdselect = undefined,
            .num_glyphs = num_glyphs,
        };

        if (top.is_cid) {
            const fda_off = top.fdarray_off orelse return error.InvalidFont;
            const fds_off = top.fdselect_off orelse return error.InvalidFont;
            font.fdarray = try Index.parse(data, fda_off);
            font.fdselect = try FDSelect.parse(data, fds_off, num_glyphs, font.fdarray.count);
        } else {
            const ps = top.private_size orelse return error.InvalidFont;
            const po = top.private_off orelse return error.InvalidFont;
            const priv = try parsePrivate(data, po, ps);
            font.lsubrs = priv.lsubrs;
            font.nominal_width = priv.nominal_width;
            font.default_width = priv.default_width;
        }
        return font;
    }

    pub fn numGlyphs(self: CffFont) u16 {
        return self.num_glyphs;
    }

    /// Returns the outline for gid as Outline (font units, cubic).
    pub fn outline(self: *const CffFont, alloc: std.mem.Allocator, gid: u16) Error!ol_mod.Outline {
        if (gid >= self.num_glyphs) return error.InvalidFont;
        const code = self.charstrings.get(gid) orelse return error.InvalidFont;

        var lsubrs = self.lsubrs;
        var nominal = self.nominal_width;
        var default = self.default_width;
        if (self.is_cid) {
            const fd = self.fdselect.lookup(gid) orelse return error.InvalidFont;
            const fd_dict = self.fdarray.get(fd) orelse return error.InvalidFont;
            const fd_top = try parseFdFontDict(fd_dict);
            const priv = try parsePrivate(self.data, fd_top.private_off, fd_top.private_size);
            lsubrs = priv.lsubrs;
            nominal = priv.nominal_width;
            default = priv.default_width;
        }

        var b = ol_mod.Builder.init(alloc);
        errdefer b.deinit();
        try cs.run(&b, code, self.gsubrs, lsubrs, nominal, default);
        return b.finish();
    }
};

// ── CFF2 ──────────────────────────────────────────────────

/// CFF2 font (non-CID preferred + multi FontDICT/FDSelect support).
pub const Cff2Font = struct {
    data: []const u8,
    charstrings: Index,
    gsubrs: Index,
    /// local subrs / initial vsindex when there is a single FontDICT
    lsubrs: Index,
    default_vsindex: u16,
    /// multi-FD
    is_multi_fd: bool,
    fdarray: Index,
    fdselect: FDSelect,
    /// VariationStore: null=none. ivs_off is the start of ItemVariationStore (after length).
    ivs_off: ?usize,
    axis_count: u16,
    num_glyphs: u16,

    /// Parse a CFF2 table. expected_axes: fvar axis_count (0=no fvar; if vstore present, use its axisCount).
    pub fn parse(data: []const u8, expected_axes: u16) Error!Cff2Font {
        const r = Reader{ .data = data };
        try r.require(0, 5);
        const major = try r.u8At(0);
        const minor = try r.u8At(1);
        if (major != 2 or minor != 0) return error.InvalidFont;
        const hdr_size = try r.u8At(2);
        if (hdr_size < 5) return error.InvalidFont;
        const top_dict_size = try r.u16At(3);
        try r.require(hdr_size, top_dict_size);

        const top = try parseCff2TopDict(data[hdr_size .. hdr_size + top_dict_size]);
        const gsubrs = try Index.parseCff2(data, hdr_size + top_dict_size);

        const cs_off = top.charstrings_off orelse return error.InvalidFont;
        const charstrings = try Index.parseCff2(data, cs_off);
        const num_glyphs: u16 = std.math.cast(u16, charstrings.count) orelse return error.InvalidFont;

        const fd_off = top.fdarray_off orelse return error.InvalidFont;
        const fdarray = try Index.parseCff2(data, fd_off);
        if (fdarray.count == 0) return error.InvalidFont;
        if (fdarray.count > 16) return error.Unsupported;

        // FD0 Private (cache for single FD)
        const fd0_dict = fdarray.get(0) orelse return error.InvalidFont;
        const fd0 = try parseFdFontDictAllowEmpty(fd0_dict);
        const p0 = try parsePrivateCff2(data, fd0.private_off, fd0.private_size);

        // Verify all FD Privates exist
        var fi: u32 = 1;
        while (fi < fdarray.count) : (fi += 1) {
            const fd_dict = fdarray.get(fi) orelse return error.InvalidFont;
            const fd = try parseFdFontDictAllowEmpty(fd_dict);
            _ = try parsePrivateCff2(data, fd.private_off, fd.private_size);
        }

        var ivs_off: ?usize = null;
        var axis_count: u16 = expected_axes;
        if (top.vstore_off) |vo| {
            try r.require(vo, 2);
            const vs_len = try r.u16At(vo);
            try r.require(vo + 2, vs_len);
            const io = vo + 2;
            if (expected_axes == 0) {
                axis_count = try ivs.axisCountFromIvs(data, io);
            }
            try ivs.validateIvs(data, io, axis_count);
            ivs_off = io;
        }

        var is_multi = fdarray.count > 1 or top.fdselect_off != null;
        var fdselect: FDSelect = undefined;
        if (top.fdselect_off) |fso| {
            is_multi = true;
            fdselect = try FDSelect.parse(data, fso, num_glyphs, fdarray.count);
        } else if (fdarray.count > 1) {
            return error.InvalidFont;
        } else {
            fdselect = .{ .data = data, .off = 0, .format = 0, .num_glyphs = num_glyphs };
        }

        return .{
            .data = data,
            .charstrings = charstrings,
            .gsubrs = gsubrs,
            .lsubrs = p0.lsubrs,
            .default_vsindex = p0.vsindex,
            .is_multi_fd = is_multi,
            .fdarray = fdarray,
            .fdselect = fdselect,
            .ivs_off = ivs_off,
            .axis_count = axis_count,
            .num_glyphs = num_glyphs,
        };
    }

    pub fn numGlyphs(self: Cff2Font) u16 {
        return self.num_glyphs;
    }

    /// Outline for gid. norm is OutlineFont.axis_norm (missing axes are 0).
    pub fn outline(self: *const Cff2Font, alloc: std.mem.Allocator, gid: u16, norm: []const f32) Error!ol_mod.Outline {
        if (gid >= self.num_glyphs) return error.InvalidFont;
        const code = self.charstrings.get(gid) orelse return error.InvalidFont;

        var lsubrs = self.lsubrs;
        var vsindex = self.default_vsindex;
        if (self.is_multi_fd) {
            const fd = self.fdselect.lookup(gid) orelse return error.InvalidFont;
            const fd_dict = self.fdarray.get(fd) orelse return error.InvalidFont;
            const fd_top = try parseFdFontDictAllowEmpty(fd_dict);
            const priv = try parsePrivateCff2(self.data, fd_top.private_off, fd_top.private_size);
            lsubrs = priv.lsubrs;
            vsindex = priv.vsindex;
        }

        var blend_ptr: ?*cs.BlendState = null;
        var blend_storage: cs.BlendState = undefined;
        if (self.ivs_off) |io| {
            blend_storage = .{
                .table = self.data,
                .ivs_off = io,
                .axis_count = self.axis_count,
                .vsindex = vsindex,
            };
            blend_ptr = &blend_storage;
        }

        var b = ol_mod.Builder.init(alloc);
        errdefer b.deinit();
        try cs.runCff2(&b, code, self.gsubrs, lsubrs, blend_ptr, norm);
        return b.finish();
    }
};

const PrivateCff2 = struct {
    lsubrs: Index,
    vsindex: u16,
};

const Cff2TopDict = struct {
    charstrings_off: ?usize = null,
    vstore_off: ?usize = null,
    fdarray_off: ?usize = null,
    fdselect_off: ?usize = null,
};

fn parseCff2TopDict(dict: []const u8) Error!Cff2TopDict {
    var top = Cff2TopDict{};
    var scn = DictScanner{ .code = dict };
    while (scn.i < dict.len) {
        const b0 = dict[scn.i];
        if (b0 <= 27) {
            scn.i += 1;
            if (b0 == 12) {
                if (scn.i >= dict.len) return error.InvalidFont;
                const b1 = dict[scn.i];
                scn.i += 1;
                switch (b1) {
                    36 => top.fdarray_off = opInt(&scn, 0), // FontDICTINDEXOffset
                    37 => top.fdselect_off = opInt(&scn, 0), // FontDICTSelectOffset
                    else => {}, // FontMatrix etc.
                }
            } else switch (b0) {
                17 => top.charstrings_off = opInt(&scn, 0),
                24 => top.vstore_off = opInt(&scn, 0), // VariationStoreOffset
                else => {},
            }
            scn.nops = 0;
        } else {
            try scn.push(try readDictOperand(dict, &scn.i));
        }
    }
    return top;
}

fn parseFdFontDictAllowEmpty(dict: []const u8) Error!FdDict {
    if (dict.len == 0) return .{ .private_off = 0, .private_size = 0 };
    return parseFdFontDict(dict);
}

fn parsePrivateCff2(data: []const u8, off: usize, size: usize) Error!PrivateCff2 {
    const empty_subrs = Index{ .data = data, .count = 0, .off_size = 0, .offsets_start = 0, .obj_base = 0, .end = 0 };
    if (size == 0) return .{ .lsubrs = empty_subrs, .vsindex = 0 };
    const r = Reader{ .data = data };
    try r.require(off, size);
    const dict = data[off .. off + size];
    var scn = DictScanner{ .code = dict };
    var subrs_off: ?usize = null;
    var vsindex: u16 = 0;
    while (scn.i < dict.len) {
        const b0 = dict[scn.i];
        if (b0 <= 27) {
            scn.i += 1;
            if (b0 == 12) {
                if (scn.i >= dict.len) return error.InvalidFont;
                scn.i += 1;
            } else switch (b0) {
                19 => subrs_off = opInt(&scn, 0), // LocalSubr relative
                22 => { // vsindex
                    if (opInt(&scn, 0)) |v| {
                        vsindex = std.math.cast(u16, v) orelse return error.InvalidFont;
                    }
                },
                else => {},
            }
            scn.nops = 0;
        } else {
            try scn.push(try readDictOperand(dict, &scn.i));
        }
    }
    var lsubrs = empty_subrs;
    if (subrs_off) |so| {
        const so_abs = std.math.add(usize, off, so) catch return error.InvalidFont;
        lsubrs = try Index.parseCff2(data, so_abs);
    }
    return .{ .lsubrs = lsubrs, .vsindex = vsindex };
}

// ── DICT parser ──────────────────────────────────────────

const TopDict = struct {
    charstrings_off: ?usize = null,
    private_size: ?usize = null,
    private_off: ?usize = null,
    charset_off: ?usize = null,
    fdarray_off: ?usize = null,
    fdselect_off: ?usize = null,
    is_cid: bool = false,
    charstring_type: i32 = 2,
};

const PrivateResult = struct { lsubrs: Index, nominal_width: f64, default_width: f64 };
const FdDict = struct { private_off: usize, private_size: usize };

/// Stack DICT operands in order; when an operator arrives, pass (op2byte, operands) to handler.
const DictScanner = struct {
    code: []const u8,
    i: usize = 0,
    ops: [48]f64 = undefined,
    nops: usize = 0,

    fn push(self: *DictScanner, v: f64) Error!void {
        if (self.nops >= self.ops.len) return error.InvalidFont;
        self.ops[self.nops] = v;
        self.nops += 1;
    }
};

fn opInt(scn: *const DictScanner, k: usize) ?usize {
    if (k >= scn.nops) return null;
    const v = scn.ops[k];
    // CFF offset/size are in u32 range. Out-of-range/non-finite are invalid (also avoids @intFromFloat traps).
    if (!std.math.isFinite(v) or v < 0 or v > @as(f64, std.math.maxInt(u32))) return null;
    return @intFromFloat(v);
}

fn parseTopDict(dict: []const u8) Error!TopDict {
    var top = TopDict{};
    var scn = DictScanner{ .code = dict };
    while (scn.i < dict.len) {
        const b0 = dict[scn.i];
        if (b0 <= 21) {
            // operator
            scn.i += 1;
            if (b0 == 12) {
                if (scn.i >= dict.len) return error.InvalidFont;
                const b1 = dict[scn.i];
                scn.i += 1;
                switch (b1) {
                    6 => top.charstring_type = if (opInt(&scn, 0)) |v| @intCast(v) else 2,
                    30 => top.is_cid = true, // ROS
                    36 => top.fdarray_off = opInt(&scn, 0),
                    37 => top.fdselect_off = opInt(&scn, 0),
                    else => {}, // FontMatrix etc. are ignored
                }
            } else switch (b0) {
                15 => top.charset_off = opInt(&scn, 0),
                17 => top.charstrings_off = opInt(&scn, 0),
                18 => { // Private: size offset
                    top.private_size = opInt(&scn, 0);
                    top.private_off = opInt(&scn, 1);
                },
                else => {}, // version/Notice/FontBBox etc. are ignored
            }
            scn.nops = 0;
        } else {
            try scn.push(try readDictOperand(dict, &scn.i));
        }
    }
    return top;
}

fn parseFdFontDict(dict: []const u8) Error!FdDict {
    var scn = DictScanner{ .code = dict };
    var poff: ?usize = null;
    var psize: ?usize = null;
    while (scn.i < dict.len) {
        const b0 = dict[scn.i];
        if (b0 <= 21) {
            scn.i += 1;
            if (b0 == 12) {
                if (scn.i >= dict.len) return error.InvalidFont;
                scn.i += 1; // skip 2-byte op operand index
            } else if (b0 == 18) {
                psize = opInt(&scn, 0);
                poff = opInt(&scn, 1);
            }
            scn.nops = 0;
        } else {
            try scn.push(try readDictOperand(dict, &scn.i));
        }
    }
    return .{
        .private_off = poff orelse return error.InvalidFont,
        .private_size = psize orelse return error.InvalidFont,
    };
}

fn parsePrivate(data: []const u8, off: usize, size: usize) Error!PrivateResult {
    const r = Reader{ .data = data };
    try r.require(off, size); // Private DICT is within the table
    const dict = data[off .. off + size];
    var scn = DictScanner{ .code = dict };
    var subrs_off: ?usize = null;
    var nominal: f64 = 0;
    var default: f64 = 0;
    while (scn.i < dict.len) {
        const b0 = dict[scn.i];
        if (b0 <= 21) {
            scn.i += 1;
            if (b0 == 12) {
                if (scn.i >= dict.len) return error.InvalidFont;
                scn.i += 1;
            } else switch (b0) {
                19 => subrs_off = opInt(&scn, 0), // Relative to the start of Private
                20 => default = if (scn.nops > 0) scn.ops[0] else 0,
                21 => nominal = if (scn.nops > 0) scn.ops[0] else 0,
                else => {},
            }
            scn.nops = 0;
        } else {
            try scn.push(try readDictOperand(dict, &scn.i));
        }
    }
    var lsubrs = Index{ .data = data, .count = 0, .off_size = 0, .offsets_start = 0, .obj_base = 0, .end = 0 };
    if (subrs_off) |so| {
        const so_abs = std.math.add(usize, off, so) catch return error.InvalidFont;
        lsubrs = try Index.parse(data, so_abs);
    }
    return .{ .lsubrs = lsubrs, .nominal_width = nominal, .default_width = default };
}

/// Verify custom charset(offset>2) region covers numGlyphs and fits in the table (SIDs not retained).
fn validateCharset(data: []const u8, off: usize, num_glyphs: u16) Error!void {
    const r = Reader{ .data = data };
    const format = try r.u8At(off);
    if (num_glyphs <= 1) return; // glyph 0 (.notdef) only
    const n: u32 = @as(u32, num_glyphs) - 1; // glyph 0 is not included in charset
    switch (format) {
        0 => try r.require(off + 1, @as(usize, n) * 2), // SID[n]
        1 => { // ranges {SID(2), nLeft(1)}
            var covered: u32 = 0;
            var p = off + 1;
            while (covered < n) {
                try r.require(p, 3);
                covered += @as(u32, data[p + 2]) + 1;
                p += 3;
            }
        },
        2 => { // ranges {SID(2), nLeft(2)}
            var covered: u32 = 0;
            var p = off + 1;
            while (covered < n) {
                try r.require(p, 4);
                covered += @as(u32, try r.u16At(p + 2)) + 1;
                p += 4;
            }
        },
        else => return error.InvalidFont,
    }
}

/// Read a DICT operand (28=int16, 29=int32, 30=real, 32..254=int). i is the start of the operand.
fn readDictOperand(dict: []const u8, i: *usize) Error!f64 {
    const b0 = dict[i.*];
    i.* += 1;
    if (b0 == 28) {
        if (i.* + 2 > dict.len) return error.InvalidFont;
        const v: i16 = @bitCast((@as(u16, dict[i.*]) << 8) | dict[i.* + 1]);
        i.* += 2;
        return @floatFromInt(v);
    }
    if (b0 == 29) {
        if (i.* + 4 > dict.len) return error.InvalidFont;
        const v: i32 = @bitCast((@as(u32, dict[i.*]) << 24) | (@as(u32, dict[i.* + 1]) << 16) | (@as(u32, dict[i.* + 2]) << 8) | dict[i.* + 3]);
        i.* += 4;
        return @floatFromInt(v);
    }
    if (b0 == 30) return readRealOperand(dict, i);
    if (b0 >= 32 and b0 <= 246) return @as(f64, @floatFromInt(@as(i32, b0) - 139));
    if (b0 >= 247 and b0 <= 250) {
        if (i.* >= dict.len) return error.InvalidFont;
        const b1 = dict[i.*];
        i.* += 1;
        return @floatFromInt((@as(i32, b0) - 247) * 256 + @as(i32, b1) + 108);
    }
    if (b0 >= 251 and b0 <= 254) {
        if (i.* >= dict.len) return error.InvalidFont;
        const b1 = dict[i.*];
        i.* += 1;
        return @floatFromInt(-(@as(i32, b0) - 251) * 256 - @as(i32, b1) - 108);
    }
    return error.InvalidFont; // 255/reserved
}

/// real operand (nibble encoding). 0-9=digit, a=., b=E, c=E-, e=-, f=end.
fn readRealOperand(dict: []const u8, i: *usize) Error!f64 {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    while (true) {
        if (i.* >= dict.len) return error.InvalidFont;
        const byte = dict[i.*];
        i.* += 1;
        const nibs = [_]u4{ @intCast(byte >> 4), @intCast(byte & 0x0F) };
        for (nibs) |nib| {
            const ch: []const u8 = switch (nib) {
                0x0...0x9 => &[_]u8{'0' + @as(u8, nib)},
                0xa => ".",
                0xb => "E",
                0xc => "E-",
                0xd => "", // reserved
                0xe => "-",
                0xf => return std.fmt.parseFloat(f64, buf[0..n]) catch error.InvalidFont,
            };
            for (ch) |c| {
                if (n >= buf.len) return error.InvalidFont;
                buf[n] = c;
                n += 1;
            }
        }
    }
}

// ── FDSelect (CID-keyed) ──────────────────────────────────

const FDSelect = struct {
    data: []const u8,
    off: usize,
    format: u8,
    num_glyphs: u16,
    n_ranges: u16 = 0, // format 3

    fn parse(data: []const u8, off: usize, num_glyphs: u16, fd_count: u32) Error!FDSelect {
        const r = Reader{ .data = data };
        const format = try r.u8At(off);
        if (format == 0) {
            try r.require(off + 1, num_glyphs); // 1 + numGlyphs byte
            // Verify each fd < fd_count
            var g: usize = 0;
            while (g < num_glyphs) : (g += 1) {
                if (data[off + 1 + g] >= fd_count) return error.InvalidFont;
            }
            return .{ .data = data, .off = off, .format = 0, .num_glyphs = num_glyphs };
        }
        if (format == 3) {
            const n_ranges = try r.u16At(off + 1);
            if (n_ranges == 0) return error.InvalidFont;
            // ranges[n]: {first(u16), fd(u8)} + sentinel(u16)
            const ranges_off = off + 3;
            try r.require(ranges_off, @as(usize, n_ranges) * 3 + 2);
            var prev_first: i32 = -1;
            var k: usize = 0;
            while (k < n_ranges) : (k += 1) {
                const first = try r.u16At(ranges_off + k * 3);
                const fd = data[ranges_off + k * 3 + 2];
                if (k == 0 and first != 0) return error.InvalidFont;
                if (@as(i32, first) <= prev_first) return error.InvalidFont; // Strictly monotonically increasing
                if (fd >= fd_count) return error.InvalidFont;
                prev_first = first;
            }
            const sentinel = try r.u16At(ranges_off + @as(usize, n_ranges) * 3);
            if (sentinel != num_glyphs) return error.InvalidFont;
            return .{ .data = data, .off = off, .format = 3, .num_glyphs = num_glyphs, .n_ranges = n_ranges };
        }
        return error.Unsupported;
    }

    fn lookup(self: FDSelect, gid: u16) ?u32 {
        if (gid >= self.num_glyphs) return null;
        if (self.format == 0) {
            return self.data[self.off + 1 + gid];
        }
        // format 3: linear search over ranges
        const ranges_off = self.off + 3;
        const r = Reader{ .data = self.data };
        var k: usize = 0;
        while (k < self.n_ranges) : (k += 1) {
            const first = r.u16At(ranges_off + k * 3) catch return null;
            const next_first = if (k + 1 < self.n_ranges)
                (r.u16At(ranges_off + (k + 1) * 3) catch return null)
            else
                (r.u16At(ranges_off + @as(usize, self.n_ranges) * 3) catch return null); // sentinel
            if (gid >= first and gid < next_first) {
                return self.data[ranges_off + k * 3 + 2];
            }
        }
        return null;
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "cff readDictOperand: int / 2-byte / int32" {
    var i: usize = 0;
    const d1 = [_]u8{op8d(100)};
    try testing.expectEqual(@as(f64, 100), try readDictOperand(&d1, &i));
    i = 0;
    const d2 = [_]u8{ 28, 0x01, 0x00 }; // int16 256
    try testing.expectEqual(@as(f64, 256), try readDictOperand(&d2, &i));
    i = 0;
    const d3 = [_]u8{ 29, 0x00, 0x01, 0x00, 0x00 }; // int32 65536
    try testing.expectEqual(@as(f64, 65536), try readDictOperand(&d3, &i));
}

fn op8d(v: i32) u8 {
    return @intCast(v + 139);
}

test "cff parseTopDict: extract CharStrings/Private" {
    // operands... 100 17(CharStrings off=100) ; 50 200 18(Private size=50 off=200)
    const dict = [_]u8{ op8d(100), 17, op8d(50), 28, 0x00, 0xC8, 18 };
    const top = try parseTopDict(&dict);
    try testing.expectEqual(@as(?usize, 100), top.charstrings_off);
    try testing.expectEqual(@as(?usize, 50), top.private_size);
    try testing.expectEqual(@as(?usize, 200), top.private_off);
    try testing.expectEqual(@as(i32, 2), top.charstring_type);
    try testing.expect(!top.is_cid);
}

test "cff readRealOperand: -2.25" {
    // -2.25 → nibbles: e(-) 2 a(.) 2 5 f(end) → 0xe2 0xa2 0x5f
    const d = [_]u8{ 30, 0xe2, 0xa2, 0x5f };
    var i: usize = 1; // 30 is assumed by the caller, so start from the operand body
    const v = try readRealOperand(&d, &i);
    try testing.expectApproxEqAbs(@as(f64, -2.25), v, 1e-9);
}

// ── CFF2 synthetic fixtures (public: reusable for snapshot / E2E) ──

fn putU16be(buf: []u8, off: usize, v: u16) void {
    buf[off] = @intCast(v >> 8);
    buf[off + 1] = @truncate(v);
}
fn putU32be(buf: []u8, off: usize, v: u32) void {
    buf[off] = @truncate(v >> 24);
    buf[off + 1] = @truncate(v >> 16);
    buf[off + 2] = @truncate(v >> 8);
    buf[off + 3] = @truncate(v);
}
fn putI16be(buf: []u8, off: usize, v: i16) void {
    putU16be(buf, off, @bitCast(v));
}
fn f2d14(v: f32) i16 {
    return @import("var_common.zig").f32ToF2dot14(v);
}
fn appendDictI16(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: i16) !void {
    try list.append(alloc, 28);
    try list.append(alloc, @intCast(@as(u16, @bitCast(v)) >> 8));
    try list.append(alloc, @truncate(@as(u16, @bitCast(v))));
}

/// Options for synthesizing a CFF2 table.
pub const Cff2TableOpts = struct {
    /// Initial vsindex of Private DICT (0=default).
    private_vsindex: u16 = 0,
    /// vstore with 2 ItemVariationData + 2 regions.
    /// region0: peak=1 (scalar=norm), region1: peak=0.5 (scalar=0 at norm=1).
    /// IVD0→region0, IVD1→region1. blend result changes with vsindex.
    dual_ivd: bool = false,
    /// Value for emitting a vsindex operator (op 15) at the start of the charstring. null=none.
    charstring_vsindex: ?u16 = null,
};

/// Minimal CFF2 table with 1-axis VariationStore + blend (1 glyph).
/// Base edge x = blend(100, +50). Caller frees.
pub fn buildCff2Table(alloc: std.mem.Allocator, opts: Cff2TableOpts) ![]u8 {
    var cs_bytes: std.ArrayList(u8) = .empty;
    defer cs_bytes.deinit(alloc);
    if (opts.charstring_vsindex) |vi| {
        try cs_bytes.append(alloc, op8d(@intCast(vi)));
        try cs_bytes.append(alloc, 15); // vsindex
    }
    // 0 0 rmoveto
    try cs_bytes.append(alloc, op8d(0));
    try cs_bytes.append(alloc, op8d(0));
    try cs_bytes.append(alloc, 21);
    // 100 50 1 blend → x, 0 rlineto
    try cs_bytes.append(alloc, op8d(100));
    try cs_bytes.append(alloc, op8d(50));
    try cs_bytes.append(alloc, op8d(1));
    try cs_bytes.append(alloc, 16); // blend
    try cs_bytes.append(alloc, op8d(0));
    try cs_bytes.append(alloc, 5); // rlineto
    try cs_bytes.append(alloc, op8d(-50));
    try cs_bytes.append(alloc, op8d(80));
    try cs_bytes.append(alloc, 5);
    try cs_bytes.append(alloc, op8d(-50));
    try cs_bytes.append(alloc, op8d(-80));
    try cs_bytes.append(alloc, 5);

    // Private DICT
    var priv: std.ArrayList(u8) = .empty;
    defer priv.deinit(alloc);
    if (opts.private_vsindex != 0) {
        try priv.append(alloc, op8d(@intCast(opts.private_vsindex)));
        try priv.append(alloc, 22); // vsindex
    }
    const priv_size = priv.items.len;

    // FontDICT: Private size offset 18
    var fd_body: std.ArrayList(u8) = .empty;
    defer fd_body.deinit(alloc);
    if (priv_size == 0) {
        try fd_body.append(alloc, op8d(0));
        try fd_body.append(alloc, op8d(0));
        try fd_body.append(alloc, 18);
    } else {
        // size as 1-byte or 28, offset as 28 (filled later) — use 28 for both for simplicity
        try appendDictI16(&fd_body, alloc, @intCast(priv_size));
        // placeholder offset — rebuild after layout; use 3-byte 28 encoding
        try appendDictI16(&fd_body, alloc, 0); // temp
        try fd_body.append(alloc, 18);
    }

    const empty_index_size: usize = 4;
    const cs_index_size = 4 + 1 + 2 + cs_bytes.items.len;
    const fd_index_size = 4 + 1 + 2 + fd_body.items.len;

    // IVS size
    const n_regions: usize = if (opts.dual_ivd) 2 else 1;
    const n_ivd: usize = if (opts.dual_ivd) 2 else 1;
    // header 16 for dual (2 offsets), 12 for single (1 offset): format2+regOff4+count2+offsets
    const ivs_hdr: usize = 8 + n_ivd * 4; // 2+4+2 + n*4
    const region_list_size: usize = 4 + n_regions * 6;
    const ivd_size: usize = 8; // item0, word0, regCount1, index
    const ivs_size: usize = ivs_hdr + region_list_size + n_ivd * ivd_size;
    const vstore_size: usize = 2 + ivs_size;

    // topdict: 3 offsets with 28 + ops = 13 (fixed)
    const topdict_size: usize = 13;
    const off_gsubr: u32 = 5 + @as(u32, @intCast(topdict_size));
    const off_cs: u32 = off_gsubr + @as(u32, @intCast(empty_index_size));
    const off_fd: u32 = off_cs + @as(u32, @intCast(cs_index_size));
    // private immediately after fd index if non-empty
    const off_priv: u32 = off_fd + @as(u32, @intCast(fd_index_size));
    const off_vs: u32 = off_priv + @as(u32, @intCast(priv_size));

    // Fix FontDICT private offset if needed
    if (priv_size != 0) {
        // fd_body: size(28,2b) offset(28,2b) 18 — rewrite offset at bytes 3..5 of body
        // appendDictI16 for size = 3 bytes, then offset 3 bytes
        fd_body.clearRetainingCapacity();
        try appendDictI16(&fd_body, alloc, @intCast(priv_size));
        try appendDictI16(&fd_body, alloc, @intCast(off_priv));
        try fd_body.append(alloc, 18);
    }

    var top: std.ArrayList(u8) = .empty;
    defer top.deinit(alloc);
    try appendDictI16(&top, alloc, @intCast(off_cs));
    try top.append(alloc, 17);
    try appendDictI16(&top, alloc, @intCast(off_fd));
    try top.append(alloc, 12);
    try top.append(alloc, 36);
    try appendDictI16(&top, alloc, @intCast(off_vs));
    try top.append(alloc, 24);
    std.debug.assert(top.items.len == topdict_size);

    const total = off_vs + @as(u32, @intCast(vstore_size));
    var out = try alloc.alloc(u8, total);
    errdefer alloc.free(out);
    @memset(out, 0);

    out[0] = 2;
    out[1] = 0;
    out[2] = 5;
    putU16be(out, 3, @intCast(topdict_size));
    @memcpy(out[5..][0..topdict_size], top.items);
    putU32be(out, off_gsubr, 0);

    putU32be(out, off_cs, 1);
    out[off_cs + 4] = 1;
    out[off_cs + 5] = 1;
    out[off_cs + 6] = @intCast(1 + cs_bytes.items.len);
    @memcpy(out[off_cs + 7 ..][0..cs_bytes.items.len], cs_bytes.items);

    putU32be(out, off_fd, 1);
    out[off_fd + 4] = 1;
    out[off_fd + 5] = 1;
    out[off_fd + 6] = @intCast(1 + fd_body.items.len);
    @memcpy(out[off_fd + 7 ..][0..fd_body.items.len], fd_body.items);

    if (priv_size > 0) {
        @memcpy(out[off_priv..][0..priv_size], priv.items);
    }

    // VariationStore
    putU16be(out, off_vs, @intCast(ivs_size));
    const ivs_base = off_vs + 2;
    putU16be(out, ivs_base, 1); // format
    putU32be(out, ivs_base + 2, @intCast(ivs_hdr)); // regionListOffset
    putU16be(out, ivs_base + 6, @intCast(n_ivd));
    const reg_start = ivs_hdr;
    var ii: usize = 0;
    while (ii < n_ivd) : (ii += 1) {
        putU32be(out, ivs_base + 8 + ii * 4, @intCast(reg_start + region_list_size + ii * ivd_size));
    }
    // region list
    const rl = ivs_base + reg_start;
    putU16be(out, rl, 1); // axisCount
    putU16be(out, rl + 2, @intCast(n_regions));
    // region0: start=0 peak=1 end=1
    putI16be(out, rl + 4, f2d14(0));
    putI16be(out, rl + 6, f2d14(1));
    putI16be(out, rl + 8, f2d14(1));
    if (n_regions > 1) {
        // region1: start=0 peak=0.5 end=1 → scalar=0 at norm=1
        putI16be(out, rl + 10, f2d14(0));
        putI16be(out, rl + 12, f2d14(0.5));
        putI16be(out, rl + 14, f2d14(1));
    }
    // IVDs: each maps to region index == ivd index
    ii = 0;
    while (ii < n_ivd) : (ii += 1) {
        const ivd = ivs_base + reg_start + region_list_size + ii * ivd_size;
        putU16be(out, ivd, 0); // itemCount
        putU16be(out, ivd + 2, 0);
        putU16be(out, ivd + 4, 1);
        putU16be(out, ivd + 6, @intCast(ii)); // regionIndexes[0] = ii
    }
    return out;
}

/// Backward compatible: minimal CFF2 table with default options.
pub fn buildMinimalCff2Vf(alloc: std.mem.Allocator) ![]u8 {
    return buildCff2Table(alloc, .{});
}

/// Complete SFNT for a CFF2 VF (head/maxp/hhea/hmtx/cmap/fvar/CFF2).
/// 1 glyph (treated as .notdef / cmap 'A'→0), unitsPerEm=64, advance=64, wght axis 100/400/900.
/// Caller frees. Can be written to a file for snapshots.
pub fn buildCff2VfSfnt(alloc: std.mem.Allocator, opts: Cff2TableOpts) ![]u8 {
    const cff2 = try buildCff2Table(alloc, opts);
    defer alloc.free(cff2);

    var head = [_]u8{0} ** 54;
    head[12] = 0x5F;
    head[13] = 0x0F;
    head[14] = 0x3C;
    head[15] = 0xF5;
    putU16be(&head, 18, 64); // unitsPerEm
    putU16be(&head, 50, 0);

    var maxp = [_]u8{0} ** 6;
    putU16be(&maxp, 4, 1); // numGlyphs

    var hhea = [_]u8{0} ** 36;
    putU16be(&hhea, 4, @bitCast(@as(i16, 48)));
    putU16be(&hhea, 6, @bitCast(@as(i16, -16)));
    putU16be(&hhea, 34, 1); // numberOfHMetrics

    var hmtx = [_]u8{0} ** 4;
    putU16be(&hmtx, 0, 64); // advance

    // fvar 1 axis wght
    var fvar_tbl = [_]u8{0} ** 36;
    putU16be(&fvar_tbl, 0, 1);
    putU16be(&fvar_tbl, 2, 0);
    putU16be(&fvar_tbl, 4, 16);
    putU16be(&fvar_tbl, 6, 2);
    putU16be(&fvar_tbl, 8, 1);
    putU16be(&fvar_tbl, 10, 20);
    putU16be(&fvar_tbl, 12, 0);
    putU16be(&fvar_tbl, 14, 8);
    fvar_tbl[16] = 'w';
    fvar_tbl[17] = 'g';
    fvar_tbl[18] = 'h';
    fvar_tbl[19] = 't';
    // Fixed min/def/max = 100/400/900
    const putFixed = struct {
        fn go(buf: []u8, off: usize, design: i32) void {
            const v: i32 = design * 65536;
            putU32be(buf, off, @bitCast(v));
        }
    }.go;
    putFixed(&fvar_tbl, 20, 100);
    putFixed(&fvar_tbl, 24, 400);
    putFixed(&fvar_tbl, 28, 900);

    // cmap format4: 'A'(0x41) → gid 0
    var cmap_sub = [_]u8{0} ** (16 + 8 * 2);
    putU16be(&cmap_sub, 0, 4);
    putU16be(&cmap_sub, 2, @intCast(cmap_sub.len));
    putU16be(&cmap_sub, 6, 4); // segCountX2
    putU16be(&cmap_sub, 14, 0x41);
    putU16be(&cmap_sub, 16, 0xFFFF);
    putU16be(&cmap_sub, 20, 0x41);
    putU16be(&cmap_sub, 22, 0xFFFF);
    putU16be(&cmap_sub, 24, @bitCast(@as(i16, 0 - 0x41))); // idDelta → gid 0
    putU16be(&cmap_sub, 26, 1);
    var cmap_tbl = [_]u8{0} ** (12 + cmap_sub.len);
    putU16be(&cmap_tbl, 2, 1);
    putU16be(&cmap_tbl, 4, 3);
    putU16be(&cmap_tbl, 6, 1);
    cmap_tbl[11] = 12;
    @memcpy(cmap_tbl[12..], &cmap_sub);

    // sfnt assemble
    const tables = [_]struct { tag: [4]u8, body: []const u8 }{
        .{ .tag = "head".*, .body = &head },
        .{ .tag = "maxp".*, .body = &maxp },
        .{ .tag = "hhea".*, .body = &hhea },
        .{ .tag = "hmtx".*, .body = &hmtx },
        .{ .tag = "cmap".*, .body = &cmap_tbl },
        .{ .tag = "fvar".*, .body = &fvar_tbl },
        .{ .tag = "CFF2".*, .body = cff2 },
    };
    const n: u16 = @intCast(tables.len);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try appendU32List(&out, alloc, 0x4F54544F); // OTTO for CFF/CFF2
    try appendU16List(&out, alloc, n);
    try appendU16List(&out, alloc, 0);
    try appendU16List(&out, alloc, 0);
    try appendU16List(&out, alloc, 0);
    var off: u32 = @intCast(12 + 16 * @as(usize, n));
    for (tables) |t| {
        try out.appendSlice(alloc, &t.tag);
        try appendU32List(&out, alloc, 0);
        try appendU32List(&out, alloc, off);
        try appendU32List(&out, alloc, @intCast(t.body.len));
        off += @intCast(t.body.len);
    }
    for (tables) |t| try out.appendSlice(alloc, t.body);
    return out.toOwnedSlice(alloc);
}

fn appendU16List(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) !void {
    try l.append(a, @intCast(v >> 8));
    try l.append(a, @truncate(v));
}
fn appendU32List(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
    try l.append(a, @truncate(v >> 24));
    try l.append(a, @truncate(v >> 16));
    try l.append(a, @truncate(v >> 8));
    try l.append(a, @truncate(v));
}

test "CFF2 VF: parse + blend outline tracks axes; matches at norm0" {
    const a = testing.allocator;
    const cff2 = try buildMinimalCff2Vf(a);
    defer a.free(cff2);

    const font = try Cff2Font.parse(cff2, 1);
    try testing.expectEqual(@as(u16, 1), font.numGlyphs());
    try testing.expect(font.ivs_off != null);

    var o0 = try font.outline(a, 0, &.{0});
    defer o0.deinit(a);
    try testing.expect(o0.contours.len >= 1);
    const c0 = o0.contours[0];
    try testing.expectApproxEqAbs(@as(f32, 0), c0.start.x, 0.5);
    try testing.expect(c0.segments.len >= 1);
    try testing.expect(c0.segments[0] == .line);
    try testing.expectApproxEqAbs(@as(f32, 100), c0.segments[0].line.x, 0.5);

    var o1 = try font.outline(a, 0, &.{1.0});
    defer o1.deinit(a);
    try testing.expect(o1.contours[0].segments[0] == .line);
    try testing.expectApproxEqAbs(@as(f32, 150), o1.contours[0].segments[0].line.x, 0.5);

    var o0b = try font.outline(a, 0, &.{0});
    defer o0b.deinit(a);
    try testing.expectApproxEqAbs(c0.segments[0].line.x, o0b.contours[0].segments[0].line.x, 0.01);
}

test "CFF2: broken major is InvalidFont" {
    var bad = [_]u8{ 1, 0, 5, 0, 0 }; // major=1
    try testing.expectError(error.InvalidFont, Cff2Font.parse(&bad, 0));
}

test "CFF2: out-of-range vsindex blend is InvalidFont" {
    const a = testing.allocator;
    const cff2 = try buildMinimalCff2Vf(a);
    defer a.free(cff2);
    const font = try Cff2Font.parse(cff2, 1);
    var blend = cs.BlendState{
        .table = font.data,
        .ivs_off = font.ivs_off.?,
        .axis_count = 1,
        .vsindex = 5,
    };
    var b = ol_mod.Builder.init(a);
    defer b.deinit();
    const code = [_]u8{ op8d(0), op8d(0), 21, op8d(100), op8d(50), op8d(1), 16, op8d(0), 5 };
    try testing.expectError(error.InvalidFont, cs.runCff2(&b, &code, font.gsubrs, font.lsubrs, &blend, &.{1.0}));
}

test "CFF2: Private DICT vsindex=1 uses IVD1 region scalar" {
    const a = testing.allocator;
    // dual_ivd: vsindex0→region0(peak1) scalar@1=1 → x=150
    //           vsindex1→region1(peak0.5) scalar@1=0 → x=100
    const cff2 = try buildCff2Table(a, .{ .private_vsindex = 1, .dual_ivd = true });
    defer a.free(cff2);
    const font = try Cff2Font.parse(cff2, 1);
    try testing.expectEqual(@as(u16, 1), font.default_vsindex);

    var o_max = try font.outline(a, 0, &.{1.0});
    defer o_max.deinit(a);
    // Private vsindex=1 → IVD1 → region1 peak0.5 → at norm1 scalar=0 → x=100
    try testing.expectApproxEqAbs(@as(f32, 100), o_max.contours[0].segments[0].line.x, 0.5);

    // Compare: 150 when private_vsindex=0
    const cff2_0 = try buildCff2Table(a, .{ .private_vsindex = 0, .dual_ivd = true });
    defer a.free(cff2_0);
    const font0 = try Cff2Font.parse(cff2_0, 1);
    var o0 = try font0.outline(a, 0, &.{1.0});
    defer o0.deinit(a);
    try testing.expectApproxEqAbs(@as(f32, 150), o0.contours[0].segments[0].line.x, 0.5);
}

test "CFF2: charstring vsindex op15 switches blend result" {
    const a = testing.allocator;
    // dual IVD + emit vsindex=1 in charstring (Private is 0)
    const cff2 = try buildCff2Table(a, .{
        .private_vsindex = 0,
        .dual_ivd = true,
        .charstring_vsindex = 1,
    });
    defer a.free(cff2);
    const font = try Cff2Font.parse(cff2, 1);
    try testing.expectEqual(@as(u16, 0), font.default_vsindex); // Private is 0

    var o = try font.outline(a, 0, &.{1.0});
    defer o.deinit(a);
    // op15 sets vsindex=1 → IVD1 → x=100
    try testing.expectApproxEqAbs(@as(f32, 100), o.contours[0].segments[0].line.x, 0.5);

    // op15 explicitly sets vsindex=0
    const cff2_v0 = try buildCff2Table(a, .{
        .dual_ivd = true,
        .charstring_vsindex = 0,
    });
    defer a.free(cff2_v0);
    const font_v0 = try Cff2Font.parse(cff2_v0, 1);
    var o0 = try font_v0.outline(a, 0, &.{1.0});
    defer o0.deinit(a);
    try testing.expectApproxEqAbs(@as(f32, 150), o0.contours[0].segments[0].line.x, 0.5);
}

test "CFF2: buildCff2VfSfnt returns a complete SFNT byte stream" {
    const a = testing.allocator;
    const sfnt_bytes = try buildCff2VfSfnt(a, .{});
    defer a.free(sfnt_bytes);
    try testing.expect(sfnt_bytes.len > 100);
    // OTTO tag
    try testing.expectEqual(@as(u8, 'O'), sfnt_bytes[0]);
    try testing.expectEqual(@as(u8, 'T'), sfnt_bytes[1]);
    try testing.expectEqual(@as(u8, 'T'), sfnt_bytes[2]);
    try testing.expectEqual(@as(u8, 'O'), sfnt_bytes[3]);
}
