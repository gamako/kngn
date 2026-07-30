//! apps/noodle: serialization of scalar parameters plus the grid/303 pattern (legacy MDLP).
//!
//! Places 2 chunks in libs/serde's versioned container:
//!   - SPRM: scalar `Params` (tempo/gain/mute, etc). Generically serializes main.zig's concrete type via comptime
//!     (the same generic packer for a "flat struct of only f32/bool/usize" as patch_io.zig (apps/synth).
//!     Since the code is small, it's duplicated per app on purpose — matching the existing pattern of
//!     pixie/synth/modular/patch's actions.zig group, each app keeping its own small std-only pure logic).
//!   - PTRN: grid/303 pattern (`PatternPayload`. Fixed layout, explicit offsets. Same convention as
//!     document_io.zig's DOCH).
//!
//! The canonical project save path is `project_io.zig` (KNGN). This file maintains the legacy MDLP
//! reader/encoder and remains the single source for PTRN/SPRM layout. KNGN's PTRN/SPRM use the same 33B /
//! flat Params layout. The unified reader detects the MDLP magic and delegates to this decode.
//!
//! **Avoiding circular imports**: does not import `Params`/`PatternCommand` (concrete types from
//! apps/noodle/main.zig, lofi.zig). main.zig performs the conversion with `PatternPayload`
//! (`patternToPayload`/`payloadToPatternCommand`).
//!
//! Scope: only the "contents of the pattern" (on/lock/accent/slide/deg + evolve) are saved. `rev` (the revision
//! counter) is not saved (on load, the app side increments `pattern_rev` once and hands it out. This shares the
//! same revision numbering path as other pattern-editing actions, preventing double numbering).
//!
//! Hot-path declaration: encode/decode/save/load run **only on events** (once per `save_pattern`/`load_pattern`
//! action invocation). Never touches the RT path (`LofiPatch.render` → graph `processBlock`).

const std = @import("std");
const serde = @import("serde");

/// Little-endian u32 for 'MDLP' (modular pattern). Passed to serde's expected_magic.
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

// ── Generic flat packer for scalar Params (f32/bool/usize only; same shape as patch_io.zig(apps/synth)) ───

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

/// **f32 fields reject non-finite values (NaN/Inf) with `error.NonFiniteField`** (fail-fast.
/// Applies the same check `actions.zig`'s `parseNameF32` performs on the action path to the file-load path too.
/// Same reason as synth's `patch_io.zig`).
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

// ── grid/303 pattern (fixed layout, equivalent to PatternCommand's contents; rev not included) ───────────────────

/// Plain struct holding `PatternCommand`'s (apps/noodle/lofi.zig) contents in an app-independent form.
/// main.zig performs the conversion with `PatternCommand`.
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

// layout (little-endian, explicit offsets. Byte count = 1+2+1+2+1+2+1+2+2+2+1+16 = 33):
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

/// Assembles `P` (scalar Params) + `PatternPayload` into a container as SPRM/PTRN's 2 chunks
/// (caller frees).
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

/// Restores `P`/`PatternPayload` from a byte slice. v1 uses fixed-length chunks.
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

test "decode: corruption detection (BadMagic/UnsupportedSchemaVersion/MissingSprm/MissingPtrn/CorruptPtrn)" {
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
    // CorruptPtrn (length mismatch)
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
    // NonFiniteField (an f32 field inside SPRM is NaN; valid per CRC but rejected on restore)
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
    // This test is included in both the pattern_io standalone root and the project_io root (via @import), so it runs
    // as 2 binaries under `zig build test` in parallel. A fixed cwd name would make them contend for the same file
    // and race, so it's isolated with tmpDir's random sub_path.
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
