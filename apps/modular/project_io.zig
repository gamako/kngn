//! apps/modular プロジェクト直列化（TASK-91）。
//!
//! libs/serde の versioned container に 4 chunk を載せる（.pix の音楽版）:
//!   - SPRM: scalar Params（pattern_io と同じフラットパッカー）
//!   - PTRN: 現在 grid/303 pattern（pattern_io.PatternPayload と同じ 33B layout）
//!   - SEED: base_seed + notation_seed + notation_counter（u64×2 + u32 = 20B）
//!   - SONG: SongData 固定 layout（phrase pool + chain pool + rows + row_count/loop）
//!
//! magic = `MPRJ`（schema_version=1）。既存 MDLP（pattern_io）は不変。
//!
//! **循環 import 回避**: `Params`/`SongData`/`PatternCommand` は import しない。
//! Song は app 非依存の `SongPayload` で受け渡し。main が変換する。
//!
//! ホットパス宣言: encode/decode/save/load は **イベント時のみ**。RT 経路には触れない。

const std = @import("std");
const serde = @import("serde");
const pattern_io = @import("pattern_io.zig");

/// 'MPRJ'（modular project）little-endian u32。
pub const magic: u32 = @as(u32, 'M') | (@as(u32, 'P') << 8) | (@as(u32, 'R') << 16) | (@as(u32, 'J') << 24);
pub const schema_version: u16 = 1;

const TAG_SPRM: [4]u8 = "SPRM".*;
const TAG_PTRN: [4]u8 = "PTRN".*;
const TAG_SEED: [4]u8 = "SEED".*;
const TAG_SONG: [4]u8 = "SONG".*;

pub const DecodeError = error{
    MissingSprm,
    MissingPtrn,
    MissingSeed,
    MissingSong,
    CorruptSprm,
    CorruptPtrn,
    CorruptSeed,
    CorruptSong,
    UnsupportedSchemaVersion,
    NonFiniteField,
};

// ── scalar Params パッカー（pattern_io と同型の f32/bool/usize フラット）────────────────

fn fieldSize(comptime T: type) usize {
    if (T == f32 or T == usize) return 4;
    if (T == bool) return 1;
    @compileError("project_io: unsupported field type " ++ @typeName(T));
}

fn packedSize(comptime T: type) usize {
    comptime var total: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |f| total += comptime fieldSize(f.type);
    return total;
}

fn packInto(comptime T: type, value: T, out: []u8) void {
    comptime var off: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const v = @field(value, f.name);
        if (f.type == f32) {
            std.mem.writeInt(u32, out[off..][0..4], @as(u32, @bitCast(v)), .little);
        } else if (f.type == usize) {
            std.mem.writeInt(u32, out[off..][0..4], @as(u32, @intCast(v)), .little);
        } else if (f.type == bool) {
            out[off] = @intFromBool(v);
        } else {
            @compileError("project_io: unsupported field type " ++ @typeName(f.type));
        }
        off += comptime fieldSize(f.type);
    }
}

fn unpackFrom(comptime T: type, bytes: []const u8) error{NonFiniteField}!T {
    var value: T = .{};
    comptime var off: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (f.type == f32) {
            const v: f32 = @bitCast(std.mem.readInt(u32, bytes[off..][0..4], .little));
            if (!std.math.isFinite(v)) return error.NonFiniteField;
            @field(value, f.name) = v;
        } else if (f.type == usize) {
            @field(value, f.name) = @intCast(std.mem.readInt(u32, bytes[off..][0..4], .little));
        } else if (f.type == bool) {
            @field(value, f.name) = bytes[off] != 0;
        } else {
            @compileError("project_io: unsupported field type " ++ @typeName(f.type));
        }
        off += comptime fieldSize(f.type);
    }
    return value;
}

// ── PTRN（pattern_io.PatternPayload と同じ 33B。自前 pack で pattern_io 非公開 fn に依存しない）──

const PTRN_SIZE: usize = 33;

fn packPattern(p: pattern_io.PatternPayload, out: *[PTRN_SIZE]u8) void {
    out[0] = @intFromBool(p.evolve);
    std.mem.writeInt(u16, out[1..3], p.kick_on, .little);
    out[3] = @intFromBool(p.kick_lock);
    std.mem.writeInt(u16, out[4..6], p.hat_on, .little);
    out[6] = @intFromBool(p.hat_lock);
    std.mem.writeInt(u16, out[7..9], p.clap_on, .little);
    out[9] = @intFromBool(p.clap_lock);
    std.mem.writeInt(u16, out[10..12], p.bass_on, .little);
    std.mem.writeInt(u16, out[12..14], p.bass_accent, .little);
    std.mem.writeInt(u16, out[14..16], p.bass_slide, .little);
    out[16] = @intFromBool(p.bass_lock);
    for (p.bass_deg, 0..) |d, i| out[17 + i] = @bitCast(d);
}

fn unpackPattern(bytes: []const u8) pattern_io.PatternPayload {
    var p: pattern_io.PatternPayload = .{};
    p.evolve = bytes[0] != 0;
    p.kick_on = std.mem.readInt(u16, bytes[1..3], .little);
    p.kick_lock = bytes[3] != 0;
    p.hat_on = std.mem.readInt(u16, bytes[4..6], .little);
    p.hat_lock = bytes[6] != 0;
    p.clap_on = std.mem.readInt(u16, bytes[7..9], .little);
    p.clap_lock = bytes[9] != 0;
    p.bass_on = std.mem.readInt(u16, bytes[10..12], .little);
    p.bass_accent = std.mem.readInt(u16, bytes[12..14], .little);
    p.bass_slide = std.mem.readInt(u16, bytes[14..16], .little);
    p.bass_lock = bytes[16] != 0;
    for (&p.bass_deg, 0..) |*d, i| d.* = @bitCast(bytes[17 + i]);
    return p;
}

// ── SEED（u64 base + u64 notation + u32 counter = 20B）────────────────────────────────

pub const SeedPayload = struct {
    base_seed: u64 = 0,
    notation_seed: u64 = 0,
    notation_counter: u32 = 0,
};

const SEED_SIZE: usize = 20;

fn packSeed(s: SeedPayload, out: *[SEED_SIZE]u8) void {
    std.mem.writeInt(u64, out[0..8], s.base_seed, .little);
    std.mem.writeInt(u64, out[8..16], s.notation_seed, .little);
    std.mem.writeInt(u32, out[16..20], s.notation_counter, .little);
}

fn unpackSeed(bytes: []const u8) SeedPayload {
    return .{
        .base_seed = std.mem.readInt(u64, bytes[0..8], .little),
        .notation_seed = std.mem.readInt(u64, bytes[8..16], .little),
        .notation_counter = std.mem.readInt(u32, bytes[16..20], .little),
    };
}

// ── SONG（SongData 固定 layout。rev は保存しない = load 時に app が increment）──────────

pub const MAX_DRUM_PHRASES: usize = 64;
pub const MAX_BASS_PHRASES: usize = 32;
pub const MAX_CHAINS: usize = 32;
pub const MAX_CHAIN_LEN: usize = 16;
pub const MAX_SONG_ROWS: usize = 64;

pub const BassPhrasePayload = struct {
    on: u16 = 0,
    accent: u16 = 0,
    slide: u16 = 0,
    deg: [16]i8 = [_]i8{0} ** 16,
};

pub const ChainPayload = struct {
    entries: [MAX_CHAIN_LEN]u8 = [_]u8{0} ** MAX_CHAIN_LEN,
    len: u8 = 0,
};

pub const SongRowPayload = struct {
    kick: u8 = 0,
    hat: u8 = 0,
    clap: u8 = 0,
    bass: u8 = 0,
};

/// SongData の中身（rev 除外）。main が patch.SongData と相互変換する。
pub const SongPayload = struct {
    phrases_kick: [MAX_DRUM_PHRASES]u16 = [_]u16{0} ** MAX_DRUM_PHRASES,
    phrases_hat: [MAX_DRUM_PHRASES]u16 = [_]u16{0} ** MAX_DRUM_PHRASES,
    phrases_clap: [MAX_DRUM_PHRASES]u16 = [_]u16{0} ** MAX_DRUM_PHRASES,
    phrases_bass: [MAX_BASS_PHRASES]BassPhrasePayload = [_]BassPhrasePayload{.{}} ** MAX_BASS_PHRASES,
    chains: [MAX_CHAINS]ChainPayload = [_]ChainPayload{.{}} ** MAX_CHAINS,
    rows: [MAX_SONG_ROWS]SongRowPayload = [_]SongRowPayload{.{}} ** MAX_SONG_ROWS,
    row_count: u8 = 0,
    loop: bool = false,
};

// layout:
//   kick[64]u16 = 128
//   hat[64]u16  = 128
//   clap[64]u16 = 128
//   bass[32]*(2+2+2+16) = 32*22 = 704
//   chains[32]*(16+1) = 32*17 = 544
//   rows[64]*4 = 256
//   row_count u8 + loop u8 = 2
// total = 128*3 + 704 + 544 + 256 + 2 = 1890
const SONG_SIZE: usize = 1890;

fn packSong(s: SongPayload, out: *[SONG_SIZE]u8) void {
    var off: usize = 0;
    for (s.phrases_kick) |v| {
        std.mem.writeInt(u16, out[off..][0..2], v, .little);
        off += 2;
    }
    for (s.phrases_hat) |v| {
        std.mem.writeInt(u16, out[off..][0..2], v, .little);
        off += 2;
    }
    for (s.phrases_clap) |v| {
        std.mem.writeInt(u16, out[off..][0..2], v, .little);
        off += 2;
    }
    for (s.phrases_bass) |bp| {
        std.mem.writeInt(u16, out[off..][0..2], bp.on, .little);
        off += 2;
        std.mem.writeInt(u16, out[off..][0..2], bp.accent, .little);
        off += 2;
        std.mem.writeInt(u16, out[off..][0..2], bp.slide, .little);
        off += 2;
        for (bp.deg) |d| {
            out[off] = @bitCast(d);
            off += 1;
        }
    }
    for (s.chains) |ch| {
        @memcpy(out[off..][0..MAX_CHAIN_LEN], &ch.entries);
        off += MAX_CHAIN_LEN;
        out[off] = ch.len;
        off += 1;
    }
    for (s.rows) |row| {
        out[off] = row.kick;
        out[off + 1] = row.hat;
        out[off + 2] = row.clap;
        out[off + 3] = row.bass;
        off += 4;
    }
    out[off] = s.row_count;
    out[off + 1] = @intFromBool(s.loop);
    off += 2;
    std.debug.assert(off == SONG_SIZE);
}

fn unpackSong(bytes: []const u8) SongPayload {
    var s: SongPayload = .{};
    var off: usize = 0;
    for (&s.phrases_kick) |*v| {
        v.* = std.mem.readInt(u16, bytes[off..][0..2], .little);
        off += 2;
    }
    for (&s.phrases_hat) |*v| {
        v.* = std.mem.readInt(u16, bytes[off..][0..2], .little);
        off += 2;
    }
    for (&s.phrases_clap) |*v| {
        v.* = std.mem.readInt(u16, bytes[off..][0..2], .little);
        off += 2;
    }
    for (&s.phrases_bass) |*bp| {
        bp.on = std.mem.readInt(u16, bytes[off..][0..2], .little);
        off += 2;
        bp.accent = std.mem.readInt(u16, bytes[off..][0..2], .little);
        off += 2;
        bp.slide = std.mem.readInt(u16, bytes[off..][0..2], .little);
        off += 2;
        for (&bp.deg) |*d| {
            d.* = @bitCast(bytes[off]);
            off += 1;
        }
    }
    for (&s.chains) |*ch| {
        @memcpy(&ch.entries, bytes[off..][0..MAX_CHAIN_LEN]);
        off += MAX_CHAIN_LEN;
        ch.len = bytes[off];
        off += 1;
    }
    for (&s.rows) |*row| {
        row.kick = bytes[off];
        row.hat = bytes[off + 1];
        row.clap = bytes[off + 2];
        row.bass = bytes[off + 3];
        off += 4;
    }
    s.row_count = bytes[off];
    s.loop = bytes[off + 1] != 0;
    return s;
}

/// SONG payload の意味論検証（長さ検査の後に呼ぶ）。
/// 不正値を RT に publish すると `rows[song_row]` / `chains[ci].entries[i]` で OOB panic しうるため fail-fast。
/// 検証: row_count<=64 / Chain.len<=16 / rows の chain idx<32 / phrase idx が pool 上限内 / loop は 0|1。
fn validateSong(s: SongPayload, loop_raw: u8) error{CorruptSong}!void {
    if (loop_raw > 1) return error.CorruptSong;
    if (s.row_count > MAX_SONG_ROWS) return error.CorruptSong;
    for (s.chains) |ch| {
        if (ch.len > MAX_CHAIN_LEN) return error.CorruptSong;
        var i: u8 = 0;
        while (i < ch.len) : (i += 1) {
            // drum pool 上限。bass は RT 側で MAX_BASS_PHRASES ガード（32..63 は drum のみ有効）。
            if (ch.entries[i] >= MAX_DRUM_PHRASES) return error.CorruptSong;
        }
    }
    // song_goto で任意 row に飛べるため全 64 row を検査
    for (s.rows) |row| {
        if (row.kick >= MAX_CHAINS or row.hat >= MAX_CHAINS or
            row.clap >= MAX_CHAINS or row.bass >= MAX_CHAINS)
        {
            return error.CorruptSong;
        }
    }
}

// ── encode / decode / save / load ────────────────────────────────────────────

pub fn Decoded(comptime P: type) type {
    return struct {
        params: P,
        pattern: pattern_io.PatternPayload,
        seed: SeedPayload,
        song: SongPayload,
    };
}

pub fn encode(
    comptime P: type,
    gpa: std.mem.Allocator,
    params: P,
    pattern: pattern_io.PatternPayload,
    seed: SeedPayload,
    song: SongPayload,
) ![]u8 {
    var w = try serde.Writer.init(gpa, magic, schema_version);
    errdefer w.deinit();

    var pbuf: [packedSize(P)]u8 = undefined;
    packInto(P, params, &pbuf);
    try w.addChunk(TAG_SPRM, &pbuf);

    var tbuf: [PTRN_SIZE]u8 = undefined;
    packPattern(pattern, &tbuf);
    try w.addChunk(TAG_PTRN, &tbuf);

    var sbuf: [SEED_SIZE]u8 = undefined;
    packSeed(seed, &sbuf);
    try w.addChunk(TAG_SEED, &sbuf);

    var songbuf: [SONG_SIZE]u8 = undefined;
    packSong(song, &songbuf);
    try w.addChunk(TAG_SONG, &songbuf);

    return w.finish();
}

pub fn decode(comptime P: type, bytes: []const u8) !Decoded(P) {
    const container = try serde.Container.parse(bytes, magic);
    if (container.schemaVersion() > schema_version) return error.UnsupportedSchemaVersion;

    const sprm = container.find(TAG_SPRM) orelse return error.MissingSprm;
    if (sprm.len != packedSize(P)) return error.CorruptSprm;
    const ptrn = container.find(TAG_PTRN) orelse return error.MissingPtrn;
    if (ptrn.len != PTRN_SIZE) return error.CorruptPtrn;
    const seed_c = container.find(TAG_SEED) orelse return error.MissingSeed;
    if (seed_c.len != SEED_SIZE) return error.CorruptSeed;
    const song_c = container.find(TAG_SONG) orelse return error.MissingSong;
    if (song_c.len != SONG_SIZE) return error.CorruptSong;

    const song = unpackSong(song_c);
    // loop raw byte は SONG 末尾（row_count の次）。bool 非正規（2..255）を拒否。
    const loop_raw = song_c[SONG_SIZE - 1];
    try validateSong(song, loop_raw);

    return .{
        .params = try unpackFrom(P, sprm),
        .pattern = unpackPattern(ptrn),
        .seed = unpackSeed(seed_c),
        .song = song,
    };
}

pub fn save(
    io: std.Io,
    path: []const u8,
    comptime P: type,
    params: P,
    pattern: pattern_io.PatternPayload,
    seed: SeedPayload,
    song: SongPayload,
    gpa: std.mem.Allocator,
) !void {
    const bytes = try encode(P, gpa, params, pattern, seed, song);
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

pub fn load(io: std.Io, gpa: std.mem.Allocator, path: []const u8, comptime P: type) !Decoded(P) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    return decode(P, bytes);
}

// ============================ tests ============================

const testing = std.testing;

const TestParams = struct {
    tempo: f32 = 122.0,
    kick_mute: bool = false,
    idx: usize = 0,
};

test "project encode/decode: round-trip params+pattern+seed+song" {
    const gpa = testing.allocator;
    const params = TestParams{ .tempo = 140, .kick_mute = true, .idx = 2 };
    const pattern = pattern_io.PatternPayload{
        .evolve = false,
        .kick_on = 0x1111,
        .kick_lock = true,
        .hat_on = 0x4444,
        .bass_on = 0x4949,
        .bass_deg = [16]i8{ 0, 0, 0, 3, 0, 0, 2, 0, 0, 0, 0, 5, -1, 0, 2, 0 },
    };
    const seed = SeedPayload{ .base_seed = 42, .notation_seed = 99, .notation_counter = 7 };
    var song = SongPayload{};
    song.phrases_kick[0] = 0x1111;
    song.phrases_hat[0] = 0x4444;
    song.phrases_clap[1] = 0x2222;
    song.phrases_bass[0] = .{ .on = 0x4949, .accent = 0x0101, .slide = 0x0808, .deg = [_]i8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0, 0, 0, 0 } };
    song.chains[0] = .{ .entries = .{ 0, 1 } ++ ([_]u8{0} ** 14), .len = 2 };
    song.rows[0] = .{ .kick = 0, .hat = 0, .clap = 0, .bass = 0 };
    song.row_count = 1;
    song.loop = true;

    const bytes = try encode(TestParams, gpa, params, pattern, seed, song);
    defer gpa.free(bytes);

    const got = try decode(TestParams, bytes);
    try testing.expectEqual(params, got.params);
    try testing.expectEqual(pattern, got.pattern);
    try testing.expectEqual(seed, got.seed);
    try testing.expectEqual(song.phrases_kick[0], got.song.phrases_kick[0]);
    try testing.expectEqual(song.phrases_hat[0], got.song.phrases_hat[0]);
    try testing.expectEqual(song.phrases_clap[1], got.song.phrases_clap[1]);
    try testing.expectEqual(song.phrases_bass[0], got.song.phrases_bass[0]);
    try testing.expectEqual(song.chains[0].len, got.song.chains[0].len);
    try testing.expectEqual(song.chains[0].entries[0], got.song.chains[0].entries[0]);
    try testing.expectEqual(song.chains[0].entries[1], got.song.chains[0].entries[1]);
    try testing.expectEqual(song.rows[0], got.song.rows[0]);
    try testing.expectEqual(song.row_count, got.song.row_count);
    try testing.expectEqual(song.loop, got.song.loop);
}

test "project decode: BadMagic / UnsupportedSchemaVersion / Missing* / Corrupt*" {
    const gpa = testing.allocator;
    const pattern = pattern_io.PatternPayload{};
    const seed = SeedPayload{};
    const song = SongPayload{};

    // BadMagic
    {
        var w = try serde.Writer.init(gpa, 0xCAFEBABE, schema_version);
        defer w.deinit();
        var pbuf: [packedSize(TestParams)]u8 = undefined;
        packInto(TestParams, .{}, &pbuf);
        try w.addChunk(TAG_SPRM, &pbuf);
        var tbuf: [PTRN_SIZE]u8 = undefined;
        packPattern(pattern, &tbuf);
        try w.addChunk(TAG_PTRN, &tbuf);
        var sbuf: [SEED_SIZE]u8 = undefined;
        packSeed(seed, &sbuf);
        try w.addChunk(TAG_SEED, &sbuf);
        var songbuf: [SONG_SIZE]u8 = undefined;
        packSong(song, &songbuf);
        try w.addChunk(TAG_SONG, &songbuf);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.BadMagic, decode(TestParams, bytes));
    }
    // UnsupportedSchemaVersion
    {
        var w = try serde.Writer.init(gpa, magic, schema_version + 1);
        defer w.deinit();
        var pbuf: [packedSize(TestParams)]u8 = undefined;
        packInto(TestParams, .{}, &pbuf);
        try w.addChunk(TAG_SPRM, &pbuf);
        var tbuf: [PTRN_SIZE]u8 = undefined;
        packPattern(pattern, &tbuf);
        try w.addChunk(TAG_PTRN, &tbuf);
        var sbuf: [SEED_SIZE]u8 = undefined;
        packSeed(seed, &sbuf);
        try w.addChunk(TAG_SEED, &sbuf);
        var songbuf: [SONG_SIZE]u8 = undefined;
        packSong(song, &songbuf);
        try w.addChunk(TAG_SONG, &songbuf);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.UnsupportedSchemaVersion, decode(TestParams, bytes));
    }
    // MissingSong
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        var pbuf: [packedSize(TestParams)]u8 = undefined;
        packInto(TestParams, .{}, &pbuf);
        try w.addChunk(TAG_SPRM, &pbuf);
        var tbuf: [PTRN_SIZE]u8 = undefined;
        packPattern(pattern, &tbuf);
        try w.addChunk(TAG_PTRN, &tbuf);
        var sbuf: [SEED_SIZE]u8 = undefined;
        packSeed(seed, &sbuf);
        try w.addChunk(TAG_SEED, &sbuf);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.MissingSong, decode(TestParams, bytes));
    }
    // CorruptSong（長さ不一致）
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        var pbuf: [packedSize(TestParams)]u8 = undefined;
        packInto(TestParams, .{}, &pbuf);
        try w.addChunk(TAG_SPRM, &pbuf);
        var tbuf: [PTRN_SIZE]u8 = undefined;
        packPattern(pattern, &tbuf);
        try w.addChunk(TAG_PTRN, &tbuf);
        var sbuf: [SEED_SIZE]u8 = undefined;
        packSeed(seed, &sbuf);
        try w.addChunk(TAG_SEED, &sbuf);
        try w.addChunk(TAG_SONG, "short");
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptSong, decode(TestParams, bytes));
    }
    // CrcMismatch（末尾改変）
    {
        const bytes = try encode(TestParams, gpa, .{}, pattern, seed, song);
        defer gpa.free(bytes);
        var mut = try gpa.dupe(u8, bytes);
        defer gpa.free(mut);
        mut[mut.len - 1] ^= 0xFF;
        try testing.expectError(error.CrcMismatch, decode(TestParams, mut));
    }
}

/// 正当な SPRM/PTRN/SEED + 任意 SONG raw で container を組み立てる（validate 前の不正 fixture 用）。
fn encodeWithRawSong(gpa: std.mem.Allocator, songbuf: *const [SONG_SIZE]u8) ![]u8 {
    var w = try serde.Writer.init(gpa, magic, schema_version);
    errdefer w.deinit();
    var pbuf: [packedSize(TestParams)]u8 = undefined;
    packInto(TestParams, .{}, &pbuf);
    try w.addChunk(TAG_SPRM, &pbuf);
    var tbuf: [PTRN_SIZE]u8 = undefined;
    packPattern(.{}, &tbuf);
    try w.addChunk(TAG_PTRN, &tbuf);
    var sbuf: [SEED_SIZE]u8 = undefined;
    packSeed(.{}, &sbuf);
    try w.addChunk(TAG_SEED, &sbuf);
    try w.addChunk(TAG_SONG, songbuf);
    return w.finish();
}

test "project decode: SONG 意味論 CorruptSong（row_count/chain.len/chain idx/phrase idx/loop）" {
    const gpa = testing.allocator;

    // 1) row_count > 64
    {
        var song = SongPayload{};
        song.row_count = 65;
        var songbuf: [SONG_SIZE]u8 = undefined;
        packSong(song, &songbuf);
        // packSong は row_count を u8 として書くので 65 が入る
        const bytes = try encodeWithRawSong(gpa, &songbuf);
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptSong, decode(TestParams, bytes));
    }
    // 2) Chain.len > 16
    {
        var song = SongPayload{};
        song.chains[0].len = 17;
        var songbuf: [SONG_SIZE]u8 = undefined;
        packSong(song, &songbuf);
        const bytes = try encodeWithRawSong(gpa, &songbuf);
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptSong, decode(TestParams, bytes));
    }
    // 3) rows の chain idx >= 32
    {
        var song = SongPayload{};
        song.rows[0].kick = 32;
        var songbuf: [SONG_SIZE]u8 = undefined;
        packSong(song, &songbuf);
        const bytes = try encodeWithRawSong(gpa, &songbuf);
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptSong, decode(TestParams, bytes));
    }
    // 4) Chain.entries の phrase idx >= 64（drum pool 上限）
    {
        var song = SongPayload{};
        song.chains[0].len = 1;
        song.chains[0].entries[0] = 64;
        var songbuf: [SONG_SIZE]u8 = undefined;
        packSong(song, &songbuf);
        const bytes = try encodeWithRawSong(gpa, &songbuf);
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptSong, decode(TestParams, bytes));
    }
    // 5) loop raw が 0/1 以外
    {
        const song = SongPayload{};
        var songbuf: [SONG_SIZE]u8 = undefined;
        packSong(song, &songbuf);
        songbuf[SONG_SIZE - 1] = 2; // loop を非正規化
        const bytes = try encodeWithRawSong(gpa, &songbuf);
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptSong, decode(TestParams, bytes));
    }
}

test "project decode: 未知 chunk skip（前方互換）" {
    const gpa = testing.allocator;
    const params = TestParams{ .tempo = 100 };
    const pattern = pattern_io.PatternPayload{ .kick_on = 0x00FF };
    const seed = SeedPayload{ .base_seed = 1 };
    const song = SongPayload{ .row_count = 3, .loop = true };

    var w = try serde.Writer.init(gpa, magic, schema_version);
    defer w.deinit();
    var pbuf: [packedSize(TestParams)]u8 = undefined;
    packInto(TestParams, params, &pbuf);
    try w.addChunk(TAG_SPRM, &pbuf);
    // 未知 chunk を途中に挿入
    try w.addChunk("FUTR".*, "future-data-here");
    var tbuf: [PTRN_SIZE]u8 = undefined;
    packPattern(pattern, &tbuf);
    try w.addChunk(TAG_PTRN, &tbuf);
    var sbuf: [SEED_SIZE]u8 = undefined;
    packSeed(seed, &sbuf);
    try w.addChunk(TAG_SEED, &sbuf);
    var songbuf: [SONG_SIZE]u8 = undefined;
    packSong(song, &songbuf);
    try w.addChunk(TAG_SONG, &songbuf);
    const bytes = try w.finish();
    defer gpa.free(bytes);

    const got = try decode(TestParams, bytes);
    try testing.expectEqual(params, got.params);
    try testing.expectEqual(pattern.kick_on, got.pattern.kick_on);
    try testing.expectEqual(seed.base_seed, got.seed.base_seed);
    try testing.expectEqual(song.row_count, got.song.row_count);
    try testing.expectEqual(song.loop, got.song.loop);
}

test "project file I/O: save→load round-trip" {
    const gpa = testing.allocator;
    const io = testing.io;
    // cwd 固定名は複数テストバイナリの並列実行で race しうる（pattern_io と同型。TASK-96）。
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/project_io_test.mprj", .{&tmp.sub_path});

    const params = TestParams{ .tempo = 96, .idx = 1 };
    const pattern = pattern_io.PatternPayload{ .kick_on = 0x8421 };
    const seed = SeedPayload{ .base_seed = 7, .notation_seed = 8, .notation_counter = 9 };
    var song = SongPayload{};
    song.phrases_kick[3] = 0xF00F;
    song.row_count = 2;
    song.loop = false;

    try save(io, path, TestParams, params, pattern, seed, song, gpa);
    const got = try load(io, gpa, path, TestParams);
    try testing.expectEqual(params, got.params);
    try testing.expectEqual(pattern, got.pattern);
    try testing.expectEqual(seed, got.seed);
    try testing.expectEqual(song.phrases_kick[3], got.song.phrases_kick[3]);
    try testing.expectEqual(song.row_count, got.song.row_count);
}
