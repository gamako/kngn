//! recipe — save/load of a CommandRecord sequence (semantic command list).
//!
//! std + libs/serde only (no core dependency). App converts CommandLog→Entry by
//! passing `RecordView` into `collectNormalEntries` (kept thin; avoids type coupling).
//!
//! Format (serde versioned container; magic='RCP1', schema=format_version):
//! - HEAD (exactly one, first): app_name UTF-8 (≤ MAX_APP_NAME)
//! - ENTR (N times, appearance order): name_len u8 | name | args_len u16 LE | args
//!
//! **Size limits (defense for shared files)**:
//! - `MAX_RECIPE_BYTES` (4MiB): cap on whole file / cumulative ENTR payload. Action args are
//!   ≤4096B under the CommandRecord contract (`MAX_CMD_ARGS`), so this fits realistic command
//!   sequences (thousands to tens of thousands) with headroom. Unbounded reads of shared/external
//!   recipes can exhaust memory, so both `load` reads and `decode` reject oversize input.
//! - `MAX_ENTRIES` (65536): caps alloc storms from tiny ENTR chunks. CommandLog ring is 128, but
//!   shared recipes can be longer, so the cap is higher with headroom.
//!
//! Hot-path note: save/load/collect run only at event time (action execution / file I/O).
//! They do not touch the per-frame or RT paths.

const std = @import("std");
const Allocator = std.mem.Allocator;
const serde = @import("serde");

/// .recipe magic (FourCC 'RCP1' as little-endian u32).
pub const magic: u32 = @as(u32, 'R') | (@as(u32, 'C') << 8) | (@as(u32, 'P') << 16) | (@as(u32, '1') << 24);
/// Recipe schema / format_version (carried in serde's schema_version).
pub const format_version: u16 = 1;
/// Max byte length of header.app_name.
pub const MAX_APP_NAME: usize = 64;
/// Max bytes for the whole recipe file (and cumulative ENTR payload during decode). See file-top doc.
pub const MAX_RECIPE_BYTES: usize = 4 * 1024 * 1024;
/// Max number of ENTR chunks. See file-top doc.
pub const MAX_ENTRIES: usize = 65536;

const TAG_HEAD: [4]u8 = "HEAD".*;
const TAG_ENTR: [4]u8 = "ENTR".*;

pub const Error = error{
    AppNameTooLong,
    UnsupportedFormatVersion,
    MissingHeader,
    DuplicateHeader,
    CorruptEntry,
    AppMismatch,
    NestedReplay,
    RecipeTooLarge,
    TooManyEntries,
};

pub const RecipeHeader = struct {
    app_name: []const u8,
    format_version: u16 = format_version,
};

pub const Entry = struct {
    name: []const u8,
    args: []const u8,
};

/// View of one CommandLog-equivalent record (no core dependency; filled by the app).
pub const RecordView = struct {
    is_normal: bool,
    name: []const u8,
    args: []const u8,
};

/// load result (owned; caller `deinit`s).
pub const Loaded = struct {
    header: RecipeHeader,
    entries: []Entry,
    /// Owned block covering header.app_name and each entry's name/args (arena-like).
    /// (Simple: per-field alloc; deinit frees them all.)
    alloc: Allocator,

    pub fn deinit(self: *Loaded) void {
        self.alloc.free(self.header.app_name);
        for (self.entries) |e| {
            self.alloc.free(e.name);
            self.alloc.free(e.args);
        }
        self.alloc.free(self.entries);
        self.* = undefined;
    }
};

/// Keep only kind=normal, in appearance order (= seq order; caller passes records ascending by seq).
/// Returned Entry name/args borrow `records` (records must outlive encode/save).
/// Caller `gpa.free`s the slice itself.
pub fn collectNormalEntries(gpa: Allocator, records: []const RecordView) Allocator.Error![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    errdefer list.deinit(gpa);
    for (records) |r| {
        if (!r.is_normal) continue;
        try list.append(gpa, .{ .name = r.name, .args = r.args });
    }
    return list.toOwnedSlice(gpa);
}

/// Whether the file's app_name matches the expected value (mismatch → `error.AppMismatch`).
pub fn checkAppName(file_app: []const u8, expected: []const u8) Error!void {
    if (!std.mem.eql(u8, file_app, expected)) return error.AppMismatch;
}

/// Prevent nested recipe_replay (already replaying → `error.NestedReplay`).
pub fn checkNotReplaying(replaying: bool) Error!void {
    if (replaying) return error.NestedReplay;
}

/// Serialize a Recipe to bytes (caller frees).
pub fn encode(gpa: Allocator, header: RecipeHeader, entries: []const Entry) (Error || Allocator.Error || error{PayloadTooLarge})![]u8 {
    if (header.app_name.len > MAX_APP_NAME) return error.AppNameTooLong;
    if (header.format_version != format_version) return error.UnsupportedFormatVersion;

    var w = try serde.Writer.init(gpa, magic, header.format_version);
    errdefer w.deinit();

    try w.addChunk(TAG_HEAD, header.app_name);

    for (entries) |e| {
        if (e.name.len > std.math.maxInt(u8)) return error.CorruptEntry;
        if (e.args.len > std.math.maxInt(u16)) return error.CorruptEntry;
        const payload_len = 1 + e.name.len + 2 + e.args.len;
        const buf = try gpa.alloc(u8, payload_len);
        defer gpa.free(buf);
        buf[0] = @intCast(e.name.len);
        @memcpy(buf[1..][0..e.name.len], e.name);
        std.mem.writeInt(u16, buf[1 + e.name.len ..][0..2], @intCast(e.args.len), .little);
        @memcpy(buf[1 + e.name.len + 2 ..][0..e.args.len], e.args);
        try w.addChunk(TAG_ENTR, buf);
    }

    return w.finish();
}

/// Restore a Recipe from bytes (owned; caller `Loaded.deinit`s).
/// `bytes.len > MAX_RECIPE_BYTES` / ENTR count > `MAX_ENTRIES` / cumulative ENTR payload >
/// `MAX_RECIPE_BYTES` map to `RecipeTooLarge` / `TooManyEntries` / `RecipeTooLarge` respectively.
pub fn decode(gpa: Allocator, bytes: []const u8) (Error || serde.Error || Allocator.Error)!Loaded {
    if (bytes.len > MAX_RECIPE_BYTES) return error.RecipeTooLarge;

    const container = try serde.Container.parse(bytes, magic);
    if (container.schemaVersion() != format_version) return error.UnsupportedFormatVersion;

    var app_name: ?[]u8 = null;
    errdefer if (app_name) |n| gpa.free(n);

    var list: std.ArrayList(Entry) = .empty;
    errdefer {
        for (list.items) |e| {
            gpa.free(e.name);
            gpa.free(e.args);
        }
        list.deinit(gpa);
    }

    var it = container.iterator();
    var seen_head = false;
    var entr_count: usize = 0;
    var entr_payload_total: usize = 0;
    while (it.next()) |chunk| {
        if (std.mem.eql(u8, &chunk.tag, &TAG_HEAD)) {
            if (seen_head) return error.DuplicateHeader;
            if (list.items.len != 0) return error.MissingHeader; // HEAD must be first (before any ENTR)
            if (chunk.payload.len > MAX_APP_NAME) return error.AppNameTooLong;
            app_name = try gpa.dupe(u8, chunk.payload);
            seen_head = true;
        } else if (std.mem.eql(u8, &chunk.tag, &TAG_ENTR)) {
            if (!seen_head) return error.MissingHeader;
            entr_count += 1;
            if (entr_count > MAX_ENTRIES) return error.TooManyEntries;
            entr_payload_total += chunk.payload.len;
            if (entr_payload_total > MAX_RECIPE_BYTES) return error.RecipeTooLarge;
            const e = try decodeEntry(gpa, chunk.payload);
            try list.append(gpa, e);
        }
        // Unknown tags are skipped serde-style (forward compat). But an unknown tag before HEAD also
        // violates the "HEAD is first" rule, so it is rejected.
        else if (!seen_head) return error.MissingHeader;
    }

    const name = app_name orelse return error.MissingHeader;
    app_name = null;
    const entries = try list.toOwnedSlice(gpa);
    return .{
        .header = .{ .app_name = name, .format_version = container.schemaVersion() },
        .entries = entries,
        .alloc = gpa,
    };
}

fn decodeEntry(gpa: Allocator, payload: []const u8) (Error || Allocator.Error)!Entry {
    if (payload.len < 1 + 2) return error.CorruptEntry;
    const name_len: usize = payload[0];
    if (payload.len < 1 + name_len + 2) return error.CorruptEntry;
    const name_bytes = payload[1..][0..name_len];
    const args_len: usize = std.mem.readInt(u16, payload[1 + name_len ..][0..2], .little);
    if (payload.len != 1 + name_len + 2 + args_len) return error.CorruptEntry;
    const args_bytes = payload[1 + name_len + 2 ..][0..args_len];
    const name = try gpa.dupe(u8, name_bytes);
    errdefer gpa.free(name);
    const args = try gpa.dupe(u8, args_bytes);
    return .{ .name = name, .args = args };
}

/// Save to path (encode → writeFile).
pub fn save(io: std.Io, path: []const u8, header: RecipeHeader, entries: []const Entry, gpa: Allocator) !void {
    const bytes = try encode(gpa, header, entries);
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// Read from path (owned; caller `Loaded.deinit`s).
/// File larger than `MAX_RECIPE_BYTES` → `error.RecipeTooLarge` (read limit is
/// `MAX_RECIPE_BYTES+1` so "exactly at the cap is allowed; over is rejected").
pub fn load(io: std.Io, gpa: Allocator, path: []const u8) !Loaded {
    // +1: allow exactly MAX_RECIPE_BYTES; reject only when larger
    // (`.limited(N)` can raise StreamTooLong once N bytes have been read).
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(MAX_RECIPE_BYTES + 1)) catch |err| {
        if (err == error.StreamTooLong) return error.RecipeTooLarge;
        return err;
    };
    defer gpa.free(bytes);
    if (bytes.len > MAX_RECIPE_BYTES) return error.RecipeTooLarge;
    return decode(gpa, bytes);
}

// ============================ tests ============================

const testing = std.testing;

fn expectRoundTrip(header: RecipeHeader, entries: []const Entry) !void {
    const gpa = testing.allocator;
    const bytes = try encode(gpa, header, entries);
    defer gpa.free(bytes);
    var loaded = try decode(gpa, bytes);
    defer loaded.deinit();
    try testing.expectEqualStrings(header.app_name, loaded.header.app_name);
    try testing.expectEqual(format_version, loaded.header.format_version);
    try testing.expectEqual(entries.len, loaded.entries.len);
    for (entries, loaded.entries) |a, b| {
        try testing.expectEqualStrings(a.name, b.name);
        try testing.expectEqualStrings(a.args, b.args);
    }
}

test "round-trip: empty entries" {
    try expectRoundTrip(.{ .app_name = "pixie" }, &.{});
}

test "round-trip: one entry / blank args / long args" {
    var long_args: [4000]u8 = undefined;
    @memset(&long_args, 'x');
    try expectRoundTrip(.{ .app_name = "pixie" }, &.{
        .{ .name = "set_color", .args = "ff0000" },
    });
    try expectRoundTrip(.{ .app_name = "modular" }, &.{
        .{ .name = "set_param", .args = "tempo 122.5" },
        .{ .name = "stroke", .args = &long_args },
    });
}

test "round-trip: many entries" {
    var bufs: [64][8]u8 = undefined;
    var entries: [64]Entry = undefined;
    for (&entries, 0..) |*e, i| {
        const name = try std.fmt.bufPrint(&bufs[i], "a{d}", .{i});
        e.* = .{ .name = name, .args = "x" };
    }
    try expectRoundTrip(.{ .app_name = "pixie" }, &entries);
}

test "Corrupt CRC → CrcMismatch" {
    const gpa = testing.allocator;
    const bytes = try encode(gpa, .{ .app_name = "pixie" }, &.{.{ .name = "clear", .args = "" }});
    defer gpa.free(bytes);
    // Corrupt the footer CRC
    bytes[bytes.len - 1] ^= 0xff;
    try testing.expectError(error.CrcMismatch, decode(gpa, bytes));
}

test "Version mismatch → UnsupportedFormatVersion" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, 99);
    defer w.deinit();
    try w.addChunk(TAG_HEAD, "pixie");
    const bytes = try w.finish();
    defer gpa.free(bytes);
    try testing.expectError(error.UnsupportedFormatVersion, decode(gpa, bytes));
}

test "app_name too long → AppNameTooLong" {
    const gpa = testing.allocator;
    var long: [MAX_APP_NAME + 1]u8 = undefined;
    @memset(&long, 'a');
    try testing.expectError(error.AppNameTooLong, encode(gpa, .{ .app_name = &long }, &.{}));

    // decode path: HEAD payload too long
    var w = try serde.Writer.init(gpa, magic, format_version);
    defer w.deinit();
    try w.addChunk(TAG_HEAD, &long);
    const bytes = try w.finish();
    defer gpa.free(bytes);
    try testing.expectError(error.AppNameTooLong, decode(gpa, bytes));
}

test "collectNormalEntries: normal only, appearance order (seq order)" {
    const gpa = testing.allocator;
    const views = [_]RecordView{
        .{ .is_normal = true, .name = "set_color", .args = "ff0000" },
        .{ .is_normal = false, .name = "undo", .args = "" }, // revert-equivalent → excluded
        .{ .is_normal = true, .name = "stroke", .args = "1 2 3 4" },
        .{ .is_normal = false, .name = "redo", .args = "" },
        .{ .is_normal = true, .name = "clear", .args = "" },
    };
    const entries = try collectNormalEntries(gpa, &views);
    defer gpa.free(entries);
    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqualStrings("set_color", entries[0].name);
    try testing.expectEqualStrings("stroke", entries[1].name);
    try testing.expectEqualStrings("clear", entries[2].name);
}

test "checkAppName / checkNotReplaying" {
    try checkAppName("pixie", "pixie");
    try testing.expectError(error.AppMismatch, checkAppName("modular", "pixie"));
    try checkNotReplaying(false);
    try testing.expectError(error.NestedReplay, checkNotReplaying(true));
}

test "file I/O: save→load round-trip" {
    const gpa = testing.allocator;
    const io = std.testing.io;
    // Fixed cwd names race across parallel test binaries, so isolate with tmpDir.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/recipe_io_test.recipe", .{&tmp.sub_path});

    const entries = [_]Entry{
        .{ .name = "seed", .args = "42" },
        .{ .name = "set_param", .args = "tempo 100" },
    };
    try save(io, path, .{ .app_name = "modular" }, &entries, gpa);
    var loaded = try load(io, gpa, path);
    defer loaded.deinit();
    try testing.expectEqualStrings("modular", loaded.header.app_name);
    try testing.expectEqual(@as(usize, 2), loaded.entries.len);
    try testing.expectEqualStrings("seed", loaded.entries[0].name);
    try testing.expectEqualStrings("42", loaded.entries[0].args);
}

test "duplicate HEAD → DuplicateHeader" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, format_version);
    defer w.deinit();
    try w.addChunk(TAG_HEAD, "pixie");
    try w.addChunk(TAG_HEAD, "modular");
    const bytes = try w.finish();
    defer gpa.free(bytes);
    try testing.expectError(error.DuplicateHeader, decode(gpa, bytes));
}

test "corrupt ENTR payload → CorruptEntry" {
    const gpa = testing.allocator;

    // Whole payload too short
    {
        var w = try serde.Writer.init(gpa, magic, format_version);
        defer w.deinit();
        try w.addChunk(TAG_HEAD, "pixie");
        const entr = [_]u8{ 5, 'c' };
        try w.addChunk(TAG_ENTR, &entr);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptEntry, decode(gpa, bytes));
    }

    // name_len disagrees with actual payload length
    {
        var w = try serde.Writer.init(gpa, magic, format_version);
        defer w.deinit();
        try w.addChunk(TAG_HEAD, "pixie");
        const entr = [_]u8{ 10, 'c', 'l', 'e', 'a', 'r', 0, 0 };
        try w.addChunk(TAG_ENTR, &entr);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptEntry, decode(gpa, bytes));
    }

    // args_len disagrees with actual payload length
    {
        var w = try serde.Writer.init(gpa, magic, format_version);
        defer w.deinit();
        try w.addChunk(TAG_HEAD, "pixie");
        const entr = [_]u8{ 5, 'c', 'l', 'e', 'a', 'r', 10, 0 };
        try w.addChunk(TAG_ENTR, &entr);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptEntry, decode(gpa, bytes));
    }
}

test "HEAD not first / missing → MissingHeader" {
    const gpa = testing.allocator;

    // ENTR only (no HEAD)
    {
        var w = try serde.Writer.init(gpa, magic, format_version);
        defer w.deinit();
        var entr: [1 + 5 + 2]u8 = undefined;
        entr[0] = 5;
        @memcpy(entr[1..6], "clear");
        std.mem.writeInt(u16, entr[6..8], 0, .little);
        try w.addChunk(TAG_ENTR, &entr);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.MissingHeader, decode(gpa, bytes));
    }

    // ENTR → HEAD (order violation)
    {
        var w = try serde.Writer.init(gpa, magic, format_version);
        defer w.deinit();
        var entr: [1 + 5 + 2]u8 = undefined;
        entr[0] = 5;
        @memcpy(entr[1..6], "clear");
        std.mem.writeInt(u16, entr[6..8], 0, .little);
        try w.addChunk(TAG_ENTR, &entr);
        try w.addChunk(TAG_HEAD, "pixie");
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.MissingHeader, decode(gpa, bytes));
    }
}

test "Byte-count oversize → RecipeTooLarge (decode / load)" {
    const gpa = testing.allocator;

    // decode: total byte count over the cap (rejected before serde)
    {
        const big = try gpa.alloc(u8, MAX_RECIPE_BYTES + 1);
        defer gpa.free(big);
        @memset(big, 0);
        try testing.expectError(error.RecipeTooLarge, decode(gpa, big));
    }

    // load: file over the cap
    {
        const io = std.testing.io;
        // Fixed cwd names race across parallel test binaries, so isolate with tmpDir.
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/recipe_too_large.recipe", .{&tmp.sub_path});
        const big = try gpa.alloc(u8, MAX_RECIPE_BYTES + 1);
        defer gpa.free(big);
        @memset(big, 0xab);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = big });
        try testing.expectError(error.RecipeTooLarge, load(io, gpa, path));
    }
}

test "Entry-count oversize → TooManyEntries" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, format_version);
    defer w.deinit();
    try w.addChunk(TAG_HEAD, "pixie");
    // Minimal ENTR: name_len=1, name='a', args_len=0
    const entr = [_]u8{ 1, 'a', 0, 0 };
    var i: usize = 0;
    while (i < MAX_ENTRIES + 1) : (i += 1) {
        try w.addChunk(TAG_ENTR, &entr);
    }
    const bytes = try w.finish();
    defer gpa.free(bytes);
    try testing.expect(bytes.len <= MAX_RECIPE_BYTES); // Even when fragmented, the file itself stays within the size cap
    try testing.expectError(error.TooManyEntries, decode(gpa, bytes));
}
