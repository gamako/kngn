//! Timbre-parameter serialisation for apps/synth.
//!
//! Packs main.zig's `Params` (timbre) / `FxParams`
//! (master FX) as chunks into a libs/serde versioned container. Same style as `libs/paint`'s `document_io.zig` (fixed DOCH/FRAM/LAYR
//! layout with an explicit schema_version), but specialised for the restricted shape "flat structs whose fields are only f32/bool/usize"
//! so it is generalised at comptime.
//!
//! **Avoiding a circular import**: the concrete `Params`/`FxParams` types live in main.zig, but this file never imports main.zig
//! (breaks the main.zig ⇄ patch_io.zig cycle so it can be unit-tested with only std + serde;
//! same separation as `actions.zig` passing names through without holding the App type).
//! The caller (main.zig) supplies the concrete `comptime P/F: type`.
//!
//! **Supported field types are f32 / bool / usize only** (fixed little-endian widths 4B/1B/4B, declaration order).
//! Unsupported field types are a comptime error (fail-safe so adding a new field type is noticed
//! immediately). usize is u32-truncated under the assumption it only holds small 32-bit-range index values (wave_idx and the like).
//!
//! Hot-path declaration: encode/decode/save/load are **event-time only** (once per `save_patch`/`load_patch` action).
//! Never touches the RT path (`Synth.render`/`MasterEffects.process`).

const std = @import("std");
const serde = @import("serde");

/// Little-endian u32 of 'SYNP' (synth patch). Passed to serde as expected_magic.
pub const magic: u32 = @as(u32, 'S') | (@as(u32, 'Y') << 8) | (@as(u32, 'N') << 16) | (@as(u32, 'P') << 24);
/// Schema version for this file (separate from serde's container_version; owned by the app).
pub const schema_version: u16 = 1;

const TAG_PARM: [4]u8 = "PARM".*; // Params (timbre)
const TAG_FXPM: [4]u8 = "FXPM".*; // FxParams (master FX)

pub const DecodeError = error{
    MissingParm,
    MissingFxpm,
    CorruptParm,
    CorruptFxpm,
    UnsupportedSchemaVersion,
    NonFiniteField,
};

/// Serialized byte count per field (f32/usize=4B, bool=1B). Unsupported types are a compile error.
fn fieldSize(comptime T: type) usize {
    if (T == f32 or T == usize) return 4;
    if (T == bool) return 1;
    @compileError("patch_io: unsupported field type " ++ @typeName(T));
}

/// Serialized size of a flat struct (sum of fieldSize in declaration order).
fn packedSize(comptime T: type) usize {
    comptime var total: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |f| total += comptime fieldSize(f.type);
    return total;
}

/// Write every field of `value` in declaration order into `out` (exactly `packedSize(T)` bytes).
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

/// Restore `T` in declaration order from `bytes` (exactly `packedSize(T)` bytes; caller-validated).
/// **f32 fields reject non-finite (NaN/Inf) with `error.NonFiniteField`** (fail-fast. Assigning a
/// file-sourced non-finite value straight into `app.params`/`app.fxp` invites safety-checked illegal
/// behaviour later inside `makePatch` via `@intFromFloat(clamp(round(unison)))` and the like.
/// Same check `actions.zig`'s `parseNameF32` already applies on the action path, also on file load).
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

/// Build a versioned container with `P` (Params) / `F` (FxParams) as two chunks (PARM/FXPM)
/// (caller frees).
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

/// Restore `P`/`F` from a byte slice. v1 uses fixed-length chunks (payloads that do not exactly match `packedSize` are corrupt).
pub fn decode(comptime P: type, comptime F: type, bytes: []const u8) !Decoded(P, F) {
    const container = try serde.Container.parse(bytes, magic);
    if (container.schemaVersion() > schema_version) return error.UnsupportedSchemaVersion;

    const parm = container.find(TAG_PARM) orelse return error.MissingParm;
    if (parm.len != packedSize(P)) return error.CorruptParm;
    const fxpm = container.find(TAG_FXPM) orelse return error.MissingFxpm;
    if (fxpm.len != packedSize(F)) return error.CorruptFxpm;

    return .{ .params = try unpackFrom(P, parm), .fxp = try unpackFrom(F, fxpm) };
}

/// Save `P`/`F` to path (encode → writeFile).
pub fn save(io: std.Io, path: []const u8, comptime P: type, comptime F: type, p: P, f: F, gpa: std.mem.Allocator) !void {
    const bytes = try encode(P, F, gpa, p, f);
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// Read `P`/`F` from path.
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

test "decode: corruption detection (BadMagic/UnsupportedSchemaVersion/MissingParm/MissingFxpm/CorruptParm)" {
    const gpa = testing.allocator;

    // BadMagic (detected by serde)
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
    // MissingParm (no PARM)
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
    // MissingFxpm (no FXPM)
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
    // CorruptParm (PARM length mismatch)
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
    // NonFiniteField (f32 field inside PARM is NaN/Inf. CRC-valid but restore is rejected)
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
    // NonFiniteField (f32 field on the FXPM side is +Inf)
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

test "forward compat: still reads PARM/FXPM with an unknown chunk tag in between" {
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
