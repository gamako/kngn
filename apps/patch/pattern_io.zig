//! apps/patch の scalar パラメータ + grid/303 pattern 直列化（TASK-65 serialize / TASK-105.4 旧 MDLP）。
//!
//! libs/serde の versioned container（TASK-62.2）に 2 chunk を載せる:
//!   - SPRM: scalar `Params`（tempo/gain/mute 等）。main.zig の具体型を comptime で汎用直列化
//!     （patch_io.zig(apps/synth) と同じ「f32/bool/usize のみのフラット struct」汎用パッカー。
//!     コードは小さいため per-app 複製方針で重複させている＝pixie/synth/modular/patch の
//!     actions.zig 群と同じ「std のみの小さい純ロジックを app ごとに持つ」既存パターンに揃える）。
//!   - PTRN: grid/303 pattern（`PatternPayload`。固定 layout・明示 offset。document_io.zig の
//!     DOCH と同じ流儀）。
//!
//! **TASK-105.4**: 正規のプロジェクト保存は `project_io.zig`（VPRJ）。本 file は旧 MDLP の
//! reader/encoder と PTRN/SPRM layout の単一ソースを維持する。VPRJ の PTRN/SPRM は同一 33B /
//! フラット Params layout。統合 reader が MDLP magic を検出して本 decode へ委譲する。
//!
//! **循環 import 回避**: `Params`/`PatternCommand`（apps/patch/main.zig・lofi.zig 具体型）は
//! import しない。main.zig 側が `PatternPayload` との変換（`patternToPayload`/`payloadToPatternCommand`）
//! を行う。
//!
//! スコープ: 保存対象は「pattern の中身」（on/lock/accent/slide/deg + evolve）のみ。`rev`（revision
//! counter）は保存しない（load 時に app 側の `pattern_rev` を 1 回 increment して払い出す。他の
//! pattern 編集 action と同じ revision 採番経路を共有し二重採番を防ぐ）。
//!
//! ホットパス宣言: encode/decode/save/load は **イベント時のみ**（`save_pattern`/`load_pattern`
//! action 1回につき1回）。RT 経路（`LofiPatch.render`→graph `processBlock`）には一切触れない。

const std = @import("std");
const serde = @import("serde");

/// 'MDLP'（modular pattern）の little-endian u32。serde の expected_magic に渡す。
pub const magic: u32 = @as(u32, 'M') | (@as(u32, 'D') << 8) | (@as(u32, 'L') << 16) | (@as(u32, 'P') << 24);
pub const schema_version: u16 = 1;

const TAG_SPRM: [4]u8 = "SPRM".*; // scalar Params
const TAG_PTRN: [4]u8 = "PTRN".*; // grid/303 pattern

pub const DecodeError = error{
    MissingSprm,
    MissingPtrn,
    CorruptSprm,
    CorruptPtrn,
    UnsupportedSchemaVersion,
    NonFiniteField,
};

// ── scalar Params の汎用フラットパッカー（f32/bool/usize のみ。patch_io.zig(apps/synth) と同型）───

fn fieldSize(comptime T: type) usize {
    if (T == f32 or T == usize) return 4;
    if (T == bool) return 1;
    @compileError("pattern_io: unsupported field type " ++ @typeName(T));
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
            @compileError("pattern_io: unsupported field type " ++ @typeName(f.type));
        }
        off += comptime fieldSize(f.type);
    }
}

/// **f32 field は non-finite（NaN/Inf）を `error.NonFiniteField` で拒否する**（fail-fast。
/// `actions.zig` の `parseNameF32` が action 経路で行っている検査を file load 経路にも課す。
/// synth の `patch_io.zig` と同じ理由）。
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
            @compileError("pattern_io: unsupported field type " ++ @typeName(f.type));
        }
        off += comptime fieldSize(f.type);
    }
    return value;
}

// ── grid/303 pattern（固定 layout。PatternCommand の中身相当。rev は含まない）───────────────────

/// `PatternCommand`（apps/patch/lofi.zig）の中身を app 非依存の形で保持する plain struct。
/// main.zig が `PatternCommand` との変換を行う。
pub const PatternPayload = struct {
    evolve: bool = true,
    kick_on: u16 = 0,
    kick_lock: bool = false,
    hat_on: u16 = 0,
    hat_lock: bool = false,
    clap_on: u16 = 0,
    clap_lock: bool = false,
    bass_on: u16 = 0,
    bass_accent: u16 = 0,
    bass_slide: u16 = 0,
    bass_lock: bool = false,
    bass_deg: [16]i8 = [_]i8{0} ** 16,
};

// layout（little-endian・明示 offset。バイト数 = 1+2+1+2+1+2+1+2+2+2+1+16 = 33）:
const PTRN_SIZE: usize = 33;

fn packPattern(p: PatternPayload, out: *[PTRN_SIZE]u8) void {
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

fn unpackPattern(bytes: []const u8) PatternPayload {
    var p: PatternPayload = .{};
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

pub fn Decoded(comptime P: type) type {
    return struct { params: P, pattern: PatternPayload };
}

/// `P`（scalar Params）+ `PatternPayload` を SPRM/PTRN の 2 chunk にして container を組み立てる
/// （caller が free する）。
pub fn encode(comptime P: type, gpa: std.mem.Allocator, params: P, pattern: PatternPayload) ![]u8 {
    var w = try serde.Writer.init(gpa, magic, schema_version);
    errdefer w.deinit();

    var pbuf: [packedSize(P)]u8 = undefined;
    packInto(P, params, &pbuf);
    try w.addChunk(TAG_SPRM, &pbuf);

    var tbuf: [PTRN_SIZE]u8 = undefined;
    packPattern(pattern, &tbuf);
    try w.addChunk(TAG_PTRN, &tbuf);

    return w.finish();
}

/// バイト列から `P`/`PatternPayload` を復元する。v1 は固定長 chunk。
pub fn decode(comptime P: type, bytes: []const u8) !Decoded(P) {
    const container = try serde.Container.parse(bytes, magic);
    if (container.schemaVersion() > schema_version) return error.UnsupportedSchemaVersion;

    const sprm = container.find(TAG_SPRM) orelse return error.MissingSprm;
    if (sprm.len != packedSize(P)) return error.CorruptSprm;
    const ptrn = container.find(TAG_PTRN) orelse return error.MissingPtrn;
    if (ptrn.len != PTRN_SIZE) return error.CorruptPtrn;

    return .{ .params = try unpackFrom(P, sprm), .pattern = unpackPattern(ptrn) };
}

pub fn save(io: std.Io, path: []const u8, comptime P: type, params: P, pattern: PatternPayload, gpa: std.mem.Allocator) !void {
    const bytes = try encode(P, gpa, params, pattern);
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

test "encode/decode: round-trip scalar Params + pattern payload" {
    const gpa = testing.allocator;
    const params = TestParams{ .tempo = 140, .kick_mute = true, .idx = 2 };
    const pattern = PatternPayload{
        .evolve = false,
        .kick_on = 0x1111,
        .kick_lock = true,
        .hat_on = 0x4444,
        .hat_lock = false,
        .clap_on = 0x1010,
        .clap_lock = false,
        .bass_on = 0x4949,
        .bass_accent = 0x0101,
        .bass_slide = 0x0808,
        .bass_lock = true,
        .bass_deg = [16]i8{ 0, 0, 0, 3, 0, 0, 2, 0, 0, 0, 0, 5, -1, 0, 2, 0 },
    };

    const bytes = try encode(TestParams, gpa, params, pattern);
    defer gpa.free(bytes);

    const got = try decode(TestParams, bytes);
    try testing.expectEqual(params, got.params);
    try testing.expectEqual(pattern, got.pattern);
}

test "decode: 破損検出 (BadMagic/UnsupportedSchemaVersion/MissingSprm/MissingPtrn/CorruptPtrn)" {
    const gpa = testing.allocator;

    // BadMagic
    {
        var w = try serde.Writer.init(gpa, 0xCAFEBABE, schema_version);
        defer w.deinit();
        var pbuf: [packedSize(TestParams)]u8 = undefined;
        packInto(TestParams, .{}, &pbuf);
        try w.addChunk(TAG_SPRM, &pbuf);
        var tbuf: [PTRN_SIZE]u8 = undefined;
        packPattern(.{}, &tbuf);
        try w.addChunk(TAG_PTRN, &tbuf);
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
        packPattern(.{}, &tbuf);
        try w.addChunk(TAG_PTRN, &tbuf);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.UnsupportedSchemaVersion, decode(TestParams, bytes));
    }
    // MissingSprm
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        var tbuf: [PTRN_SIZE]u8 = undefined;
        packPattern(.{}, &tbuf);
        try w.addChunk(TAG_PTRN, &tbuf);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.MissingSprm, decode(TestParams, bytes));
    }
    // MissingPtrn
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        var pbuf: [packedSize(TestParams)]u8 = undefined;
        packInto(TestParams, .{}, &pbuf);
        try w.addChunk(TAG_SPRM, &pbuf);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.MissingPtrn, decode(TestParams, bytes));
    }
    // CorruptPtrn（長さ不一致）
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        var pbuf: [packedSize(TestParams)]u8 = undefined;
        packInto(TestParams, .{}, &pbuf);
        try w.addChunk(TAG_SPRM, &pbuf);
        try w.addChunk(TAG_PTRN, "short");
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptPtrn, decode(TestParams, bytes));
    }
    // NonFiniteField（SPRM 内の f32 field が NaN。CRC 的には正当だが復元を拒否する）
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        var pbuf: [packedSize(TestParams)]u8 = undefined;
        packInto(TestParams, .{ .tempo = std.math.nan(f32) }, &pbuf);
        try w.addChunk(TAG_SPRM, &pbuf);
        var tbuf: [PTRN_SIZE]u8 = undefined;
        packPattern(.{}, &tbuf);
        try w.addChunk(TAG_PTRN, &tbuf);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.NonFiniteField, decode(TestParams, bytes));
    }
}

test "file I/O: save→load round-trip" {
    const gpa = testing.allocator;
    const io = testing.io;
    // このテストは pattern_io 単体 root と project_io root（@import 経由）の 2 バイナリに
    // 含まれ `zig build test` で並列実行される。cwd 固定名だと同一ファイルを取り合って
    // race する（TASK-96 で実測）ため tmpDir のランダム sub_path で分離する。
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/pattern_io_test.mdlp", .{&tmp.sub_path});

    const params = TestParams{ .tempo = 96, .kick_mute = false, .idx = 1 };
    const pattern = PatternPayload{ .kick_on = 0x8421, .bass_deg = [16]i8{ 5, 4, 3, 2, 1, 0, -1, -2, 0, 0, 0, 0, 0, 0, 0, 0 } };
    try save(io, path, TestParams, params, pattern, gpa);

    const got = try load(io, gpa, path, TestParams);
    try testing.expectEqual(params, got.params);
    try testing.expectEqual(pattern, got.pattern);
}
