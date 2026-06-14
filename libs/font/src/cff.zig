// CFF（Compact Font Format）コンテナのパーサ。OpenType .otf の 'CFF ' テーブルを読み、
// Type2 charstring（charstring.zig）を実行して共通 Outline（outline.zig, cubic）を得る。
//
// 対応: header / INDEX(Name,TopDICT,String,GlobalSubr,CharStrings) / Top DICT / Private DICT /
//       local+global subr / CID-keyed(FDArray,FDSelect format 0/3)。
// charset は offset/範囲のみ検証(SID 非保持)。Type1(CharstringType!=2)・arithmetic op は非対応。

const std = @import("std");
const Reader = @import("byte_reader.zig").Reader;
const ol_mod = @import("outline.zig");
const cs = @import("charstring.zig");

const Index = cs.Index;

pub const Error = error{ InvalidFont, Unsupported, OutOfMemory };

pub const CffFont = struct {
    data: []const u8,
    charstrings: Index,
    gsubrs: Index,
    // 非 CID 用（CID のときは per-glyph に解決するため未使用）
    lsubrs: Index,
    nominal_width: f64,
    default_width: f64,
    // CID 用
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
        if (top_index.count != 1) return error.InvalidFont; // OpenType CFF は Top DICT 1 entry
        const string_index = try Index.parse(data, top_index.end);
        const gsubrs = try Index.parse(data, string_index.end);

        const top = try parseTopDict(top_index.get(0).?);
        if (top.charstring_type != 2) return error.Unsupported; // Type2 のみ

        const cs_off = top.charstrings_off orelse return error.InvalidFont;
        const charstrings = try Index.parse(data, cs_off);
        const num_glyphs: u16 = std.math.cast(u16, charstrings.count) orelse return error.InvalidFont;

        // charset: custom(>2) なら numGlyphs を覆うバイトが table 内にあることを検証（SID 非保持）。
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

    /// gid の輪郭を Outline（font units, cubic）として返す。
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

// ── DICT パーサ ──────────────────────────────────────────

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

/// DICT operand を順に積み、operator が来たら handler に (op2byte, operands) を渡す。
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
    // CFF の offset/size は u32 範囲。範囲外/非有限は無効（@intFromFloat の trap も防ぐ）。
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
                    else => {}, // FontMatrix 等は無視
                }
            } else switch (b0) {
                15 => top.charset_off = opInt(&scn, 0),
                17 => top.charstrings_off = opInt(&scn, 0),
                18 => { // Private: size offset
                    top.private_size = opInt(&scn, 0);
                    top.private_off = opInt(&scn, 1);
                },
                else => {}, // version/Notice/FontBBox 等は無視
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
    try r.require(off, size); // Private DICT が table 内
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
                19 => subrs_off = opInt(&scn, 0), // Private 先頭からの相対
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

/// custom charset(offset>2) の領域が numGlyphs を覆って table 内に収まるか検証（SID は保持しない）。
fn validateCharset(data: []const u8, off: usize, num_glyphs: u16) Error!void {
    const r = Reader{ .data = data };
    const format = try r.u8At(off);
    if (num_glyphs <= 1) return; // glyph 0(.notdef) のみ
    const n: u32 = @as(u32, num_glyphs) - 1; // glyph 0 は charset に含まれない
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

/// DICT operand を読む（28=int16, 29=int32, 30=real, 32..254=int）。i は operand 先頭。
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

/// real operand（nibble エンコード）。0-9=数字, a=., b=E, c=E-, e=-, f=終端。
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

// ── FDSelect（CID-keyed）──────────────────────────────────

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
            // 各 fd < fd_count を検証
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
                if (@as(i32, first) <= prev_first) return error.InvalidFont; // 狭義単調増加
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
        // format 3: ranges を線形探索
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

test "cff parseTopDict: CharStrings/Private 抽出" {
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
    var i: usize = 1; // 30 は呼び出し前提なので operand 本体から
    const v = try readRealOperand(&d, &i);
    try testing.expectApproxEqAbs(@as(f64, -2.25), v, 1e-9);
}
