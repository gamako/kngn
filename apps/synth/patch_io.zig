//! apps/synth の音色パラメータ直列化（TASK-65 serialize）。
//!
//! libs/serde の versioned container（TASK-62.2）に main.zig の `Params`（音色）/ `FxParams`
//! （マスター FX）を chunk として載せる。`libs/paint` の `document_io.zig`（DOCH/FRAM/LAYR の固定
//! layout・schema_version 明示）と同じ流儀だが、対象が「f32/bool/usize のみを持つフラット構造体」
//! という限定形なので comptime で汎用化している。
//!
//! **循環 import 回避**: `Params`/`FxParams` の具体型は main.zig にあるが、この file は main.zig を
//! 一切 import しない（main.zig ⇄ patch_io.zig の循環を避け、std + serde のみで単体テストできる
//! ようにするため。`actions.zig` が App 型を持たず name を素通しするのと同じ分離方針）。
//! 呼び出し側（main.zig）が具体型 `comptime P/F: type` を渡す。
//!
//! **対応 field 型は f32 / bool / usize のみ**（各 4B/1B/4B の little-endian 固定幅、宣言順）。
//! 未対応の field 型は comptime error になる（構造体に新しい型の field を足したとき即座に気づける
//! フェイルセーフ）。usize は 32bit 範囲の小さい index 値（wave_idx 等）にのみ使う前提で u32 truncate。
//!
//! ホットパス宣言: encode/decode/save/load は **イベント時のみ**（`save_patch`/`load_patch` action
//! 1回につき1回）。RT 経路（`Synth.render`/`MasterEffects.process`）には一切触れない。

const std = @import("std");
const serde = @import("serde");

/// 'SYNP'（synth patch）の little-endian u32。serde の expected_magic に渡す。
pub const magic: u32 = @as(u32, 'S') | (@as(u32, 'Y') << 8) | (@as(u32, 'N') << 16) | (@as(u32, 'P') << 24);
/// このファイルの schema バージョン（serde の container_version とは別。app 管理）。
pub const schema_version: u16 = 1;

const TAG_PARM: [4]u8 = "PARM".*; // Params（音色）
const TAG_FXPM: [4]u8 = "FXPM".*; // FxParams（マスター FX）

pub const DecodeError = error{
    MissingParm,
    MissingFxpm,
    CorruptParm,
    CorruptFxpm,
    UnsupportedSchemaVersion,
    NonFiniteField,
};

/// field 1 個あたりの直列化バイト数（f32/usize=4B, bool=1B）。未対応型は compile error。
fn fieldSize(comptime T: type) usize {
    if (T == f32 or T == usize) return 4;
    if (T == bool) return 1;
    @compileError("patch_io: unsupported field type " ++ @typeName(T));
}

/// フラット struct の直列化サイズ（宣言順に fieldSize を積算）。
fn packedSize(comptime T: type) usize {
    comptime var total: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |f| total += comptime fieldSize(f.type);
    return total;
}

/// `value` の全 field を宣言順に `out`（ちょうど `packedSize(T)` バイト）へ書く。
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
            @compileError("patch_io: unsupported field type " ++ @typeName(f.type));
        }
        off += comptime fieldSize(f.type);
    }
}

/// `bytes`（ちょうど `packedSize(T)` バイト。呼び出し側が検証済み）から `T` を宣言順に復元する。
/// **f32 field は non-finite（NaN/Inf）を `error.NonFiniteField` で拒否する**（fail-fast。ファイル
/// 由来の非有限値をそのまま `app.params`/`app.fxp` へ代入すると、後段の `makePatch` 内
/// `@intFromFloat(clamp(round(unison)))` 等で safety-checked illegal behavior を招くため。
/// `actions.zig` の `parseNameF32` が action 経路で行っている検査と同じものを file load 経路にも課す）。
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
            @compileError("patch_io: unsupported field type " ++ @typeName(f.type));
        }
        off += comptime fieldSize(f.type);
    }
    return value;
}

pub fn Decoded(comptime P: type, comptime F: type) type {
    return struct { params: P, fxp: F };
}

/// `P`（Params）/ `F`（FxParams）を 2 chunk（PARM/FXPM）にして versioned container を組み立てる
/// （caller が free する）。
pub fn encode(comptime P: type, comptime F: type, gpa: std.mem.Allocator, p: P, f: F) ![]u8 {
    var w = try serde.Writer.init(gpa, magic, schema_version);
    errdefer w.deinit();

    var pbuf: [packedSize(P)]u8 = undefined;
    packInto(P, p, &pbuf);
    try w.addChunk(TAG_PARM, &pbuf);

    var fbuf: [packedSize(F)]u8 = undefined;
    packInto(F, f, &fbuf);
    try w.addChunk(TAG_FXPM, &fbuf);

    return w.finish();
}

/// バイト列から `P`/`F` を復元する。v1 は固定長 chunk（`packedSize` と厳密一致しない payload は破損扱い）。
pub fn decode(comptime P: type, comptime F: type, bytes: []const u8) !Decoded(P, F) {
    const container = try serde.Container.parse(bytes, magic);
    if (container.schemaVersion() > schema_version) return error.UnsupportedSchemaVersion;

    const parm = container.find(TAG_PARM) orelse return error.MissingParm;
    if (parm.len != packedSize(P)) return error.CorruptParm;
    const fxpm = container.find(TAG_FXPM) orelse return error.MissingFxpm;
    if (fxpm.len != packedSize(F)) return error.CorruptFxpm;

    return .{ .params = try unpackFrom(P, parm), .fxp = try unpackFrom(F, fxpm) };
}

/// `P`/`F` を path へ保存する（encode → writeFile）。
pub fn save(io: std.Io, path: []const u8, comptime P: type, comptime F: type, p: P, f: F, gpa: std.mem.Allocator) !void {
    const bytes = try encode(P, F, gpa, p, f);
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// path から `P`/`F` を読む。
pub fn load(io: std.Io, gpa: std.mem.Allocator, path: []const u8, comptime P: type, comptime F: type) !Decoded(P, F) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    return decode(P, F, bytes);
}

// ============================ tests ============================

const testing = std.testing;

const TestParams = struct {
    a: f32 = 1.0,
    b: f32 = 2.0,
    idx: usize = 0,
    flag: bool = false,
    c: f32 = -3.5,
};
const TestFx = struct {
    bypass: bool = false,
    x: f32 = 0.5,
    y: f32 = -1.25,
};

test "encode/decode: round-trip flat f32/bool/usize struct pair" {
    const gpa = testing.allocator;
    const p = TestParams{ .a = 3.5, .b = -2.25, .idx = 2, .flag = true, .c = 0.0 };
    const f = TestFx{ .bypass = true, .x = 0.125, .y = 99.5 };

    const bytes = try encode(TestParams, TestFx, gpa, p, f);
    defer gpa.free(bytes);

    const got = try decode(TestParams, TestFx, bytes);
    try testing.expectEqual(p, got.params);
    try testing.expectEqual(f, got.fxp);
}

test "decode: 破損検出 (BadMagic/UnsupportedSchemaVersion/MissingParm/MissingFxpm/CorruptParm)" {
    const gpa = testing.allocator;

    // BadMagic（serde が検出）
    {
        var w = try serde.Writer.init(gpa, 0xDEADBEEF, schema_version);
        defer w.deinit();
        var pbuf: [packedSize(TestParams)]u8 = undefined;
        packInto(TestParams, .{}, &pbuf);
        try w.addChunk(TAG_PARM, &pbuf);
        var fbuf: [packedSize(TestFx)]u8 = undefined;
        packInto(TestFx, .{}, &fbuf);
        try w.addChunk(TAG_FXPM, &fbuf);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.BadMagic, decode(TestParams, TestFx, bytes));
    }
    // UnsupportedSchemaVersion
    {
        var w = try serde.Writer.init(gpa, magic, schema_version + 1);
        defer w.deinit();
        var pbuf: [packedSize(TestParams)]u8 = undefined;
        packInto(TestParams, .{}, &pbuf);
        try w.addChunk(TAG_PARM, &pbuf);
        var fbuf: [packedSize(TestFx)]u8 = undefined;
        packInto(TestFx, .{}, &fbuf);
        try w.addChunk(TAG_FXPM, &fbuf);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.UnsupportedSchemaVersion, decode(TestParams, TestFx, bytes));
    }
    // MissingParm（PARM 無し）
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        var fbuf: [packedSize(TestFx)]u8 = undefined;
        packInto(TestFx, .{}, &fbuf);
        try w.addChunk(TAG_FXPM, &fbuf);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.MissingParm, decode(TestParams, TestFx, bytes));
    }
    // MissingFxpm（FXPM 無し）
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        var pbuf: [packedSize(TestParams)]u8 = undefined;
        packInto(TestParams, .{}, &pbuf);
        try w.addChunk(TAG_PARM, &pbuf);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.MissingFxpm, decode(TestParams, TestFx, bytes));
    }
    // CorruptParm（PARM の長さ不一致）
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        try w.addChunk(TAG_PARM, "short");
        var fbuf: [packedSize(TestFx)]u8 = undefined;
        packInto(TestFx, .{}, &fbuf);
        try w.addChunk(TAG_FXPM, &fbuf);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptParm, decode(TestParams, TestFx, bytes));
    }
    // NonFiniteField（PARM 内の f32 field が NaN/Inf。CRC 的には正当だが復元を拒否する）
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        var pbuf: [packedSize(TestParams)]u8 = undefined;
        packInto(TestParams, .{ .a = std.math.nan(f32) }, &pbuf);
        try w.addChunk(TAG_PARM, &pbuf);
        var fbuf: [packedSize(TestFx)]u8 = undefined;
        packInto(TestFx, .{}, &fbuf);
        try w.addChunk(TAG_FXPM, &fbuf);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.NonFiniteField, decode(TestParams, TestFx, bytes));
    }
    // NonFiniteField（FXPM 側の f32 field が +Inf）
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        var pbuf: [packedSize(TestParams)]u8 = undefined;
        packInto(TestParams, .{}, &pbuf);
        try w.addChunk(TAG_PARM, &pbuf);
        var fbuf: [packedSize(TestFx)]u8 = undefined;
        packInto(TestFx, .{ .y = std.math.inf(f32) }, &fbuf);
        try w.addChunk(TAG_FXPM, &fbuf);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.NonFiniteField, decode(TestParams, TestFx, bytes));
    }
}

test "前方互換: 未知 chunk tag を挟んでも PARM/FXPM を読める" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, schema_version);
    defer w.deinit();
    var pbuf: [packedSize(TestParams)]u8 = undefined;
    packInto(TestParams, .{ .a = 7 }, &pbuf);
    try w.addChunk(TAG_PARM, &pbuf);
    try w.addChunk("XxYy".*, "future-unknown-chunk");
    var fbuf: [packedSize(TestFx)]u8 = undefined;
    packInto(TestFx, .{ .x = 9 }, &fbuf);
    try w.addChunk(TAG_FXPM, &fbuf);
    const bytes = try w.finish();
    defer gpa.free(bytes);

    const got = try decode(TestParams, TestFx, bytes);
    try testing.expectEqual(@as(f32, 7), got.params.a);
    try testing.expectEqual(@as(f32, 9), got.fxp.x);
}

test "file I/O: save→load round-trip" {
    const gpa = testing.allocator;
    const io = testing.io;
    const path = ".task65_synth_patch_io_test.synp";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const p = TestParams{ .a = 42, .b = -1, .idx = 3, .flag = true, .c = 0.5 };
    const f = TestFx{ .bypass = false, .x = 1.5, .y = -2.5 };
    try save(io, path, TestParams, TestFx, p, f, gpa);

    const got = try load(io, gpa, path, TestParams, TestFx);
    try testing.expectEqual(p, got.params);
    try testing.expectEqual(f, got.fxp);
}
