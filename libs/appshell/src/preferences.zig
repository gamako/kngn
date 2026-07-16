//! 型付き key-value 設定。

const std = @import("std");
const serde = @import("serde");

pub const format_version: u16 = 1;
pub const magic: u32 = @as(u32, 'A') | (@as(u32, 'S') << 8) | (@as(u32, 'H') << 16) | (@as(u32, '1') << 24);
const max_file_size = 16 * 1024 * 1024;

pub const Value = union(enum) {
    boolean: bool,
    integer: i64,
    real: f64,
    string: []u8,
};

pub const LoadResult = enum { loaded, defaulted };

const Entry = struct { key: []const u8, value: Value };

pub const Preferences = struct {
    allocator: std.mem.Allocator,
    values: std.StringHashMapUnmanaged(Value) = .empty,

    pub fn init(allocator: std.mem.Allocator) Preferences {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Preferences) void {
        var it = self.values.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeValue(self.allocator, entry.value_ptr.*);
        }
        self.values.deinit(self.allocator);
        self.values = .empty;
    }

    pub fn getBool(self: *const Preferences, key: []const u8) ?bool {
        return switch (self.values.get(key) orelse return null) {
            .boolean => |v| v,
            else => null,
        };
    }

    pub fn getI64(self: *const Preferences, key: []const u8) ?i64 {
        return switch (self.values.get(key) orelse return null) {
            .integer => |v| v,
            else => null,
        };
    }

    pub fn getF64(self: *const Preferences, key: []const u8) ?f64 {
        return switch (self.values.get(key) orelse return null) {
            .real => |v| v,
            else => null,
        };
    }

    pub fn getString(self: *const Preferences, key: []const u8) ?[]const u8 {
        return switch (self.values.get(key) orelse return null) {
            .string => |v| v,
            else => null,
        };
    }

    pub fn setBool(self: *Preferences, key: []const u8, value: bool) !void {
        try self.set(key, .{ .boolean = value });
    }
    pub fn setI64(self: *Preferences, key: []const u8, value: i64) !void {
        try self.set(key, .{ .integer = value });
    }
    pub fn setF64(self: *Preferences, key: []const u8, value: f64) !void {
        try self.set(key, .{ .real = value });
    }
    pub fn setString(self: *Preferences, key: []const u8, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned);
        try self.set(key, .{ .string = owned });
    }

    fn set(self: *Preferences, key: []const u8, value: Value) !void {
        if (self.values.getPtr(key)) |old| {
            freeValue(self.allocator, old.*);
            old.* = value;
            return;
        }
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        try self.values.put(self.allocator, owned_key, value);
    }

    pub fn load(self: *Preferences, io: std.Io, dir: std.Io.Dir, file_name: []const u8) !LoadResult {
        self.clear();
        const bytes = dir.readFileAlloc(io, file_name, self.allocator, .limited(max_file_size)) catch |err| switch (err) {
            error.FileNotFound => return .defaulted,
            else => return err,
        };
        defer self.allocator.free(bytes);

        const container = serde.Container.parse(bytes, magic) catch return .defaulted;
        if (container.schemaVersion() != format_version) return .defaulted;
        var it = container.iterator();
        while (it.next()) |chunk| {
            if (!std.mem.eql(u8, &chunk.tag, "KV00")) continue;
            const record = parseRecord(self.allocator, chunk.payload) catch {
                self.clear();
                return .defaulted;
            };
            self.set(record.key, record.value) catch |err| {
                freeValue(self.allocator, record.value);
                return err;
            };
            self.allocator.free(record.key);
        }
        return .loaded;
    }

    pub fn save(self: *const Preferences, io: std.Io, dir: std.Io.Dir, file_name: []const u8) !void {
        var writer = try serde.Writer.init(self.allocator, magic, format_version);
        defer writer.deinit();
        var it = self.values.iterator();
        while (it.next()) |entry| {
            var payload: std.ArrayList(u8) = .empty;
            defer payload.deinit(self.allocator);
            try encodeRecord(self.allocator, &payload, entry.key_ptr.*, entry.value_ptr.*);
            try writer.addChunk("KV00".*, payload.items);
        }
        const bytes = try writer.finish();
        defer self.allocator.free(bytes);
        try writeAtomic(io, dir, file_name, bytes);
    }

    fn clear(self: *Preferences) void {
        var it = self.values.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeValue(self.allocator, entry.value_ptr.*);
        }
        self.values.clearRetainingCapacity();
    }
};

fn freeValue(allocator: std.mem.Allocator, value: Value) void {
    if (value == .string) allocator.free(value.string);
}

fn parseRecord(allocator: std.mem.Allocator, payload: []const u8) !Entry {
    if (payload.len < 7) return error.InvalidPayload;
    const key_len = std.mem.readInt(u16, payload[1..3], .little);
    const value_len = std.mem.readInt(u32, payload[3..7], .little);
    if (key_len == 0 or value_len > payload.len - 7 or key_len > payload.len - 7 - value_len) return error.InvalidPayload;
    if (7 + key_len + value_len != payload.len) return error.InvalidPayload;
    const key = try allocator.dupe(u8, payload[7 .. 7 + key_len]);
    errdefer allocator.free(key);
    const raw = payload[7 + key_len ..];
    if (payload[0] == 3 and !std.unicode.utf8ValidateSlice(raw)) return error.InvalidPayload;
    const value: Value = switch (payload[0]) {
        0 => if (value_len == 1 and (raw[0] == 0 or raw[0] == 1)) .{ .boolean = raw[0] != 0 } else return error.InvalidPayload,
        1 => if (value_len == 8) .{ .integer = std.mem.readInt(i64, raw[0..8], .little) } else return error.InvalidPayload,
        2 => if (value_len == 8) .{ .real = @bitCast(std.mem.readInt(u64, raw[0..8], .little)) } else return error.InvalidPayload,
        3 => .{ .string = try allocator.dupe(u8, raw) },
        else => return error.InvalidPayload,
    };
    return .{ .key = key, .value = value };
}

fn encodeRecord(allocator: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, value: Value) !void {
    if (key.len > std.math.maxInt(u16)) return error.KeyTooLong;
    const value_len: usize = switch (value) {
        .boolean => 1,
        .integer, .real => 8,
        .string => |v| v.len,
    };
    if (value_len > std.math.maxInt(u32)) return error.ValueTooLong;
    try out.ensureTotalCapacity(allocator, 7 + key.len + value_len);
    out.appendAssumeCapacity(@intFromEnum(value));
    var sizes: [6]u8 = undefined;
    std.mem.writeInt(u16, sizes[0..2], @intCast(key.len), .little);
    std.mem.writeInt(u32, sizes[2..6], @intCast(value_len), .little);
    out.appendSliceAssumeCapacity(&sizes);
    out.appendSliceAssumeCapacity(key);
    switch (value) {
        .boolean => |v| out.appendAssumeCapacity(@intFromBool(v)),
        .integer => |v| {
            var b: [8]u8 = undefined;
            std.mem.writeInt(i64, &b, v, .little);
            out.appendSliceAssumeCapacity(&b);
        },
        .real => |v| {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, @bitCast(v), .little);
            out.appendSliceAssumeCapacity(&b);
        },
        .string => |v| out.appendSliceAssumeCapacity(v),
    }
}

fn writeAtomic(io: std.Io, dir: std.Io.Dir, file_name: []const u8, bytes: []const u8) !void {
    var atomic = try dir.createFileAtomic(io, file_name, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}

test "preferences round-trip, type mismatch, duplicate key, and empty set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var prefs = Preferences.init(std.testing.allocator);
    defer prefs.deinit();
    try prefs.setBool("flag", true);
    try prefs.setI64("count", -42);
    try prefs.setF64("ratio", 1.25);
    try prefs.setString("name", "日本語");
    try prefs.save(std.testing.io, tmp.dir, "preferences.ash");

    var loaded = Preferences.init(std.testing.allocator);
    defer loaded.deinit();
    try std.testing.expectEqual(LoadResult.loaded, try loaded.load(std.testing.io, tmp.dir, "preferences.ash"));
    try std.testing.expectEqual(true, loaded.getBool("flag"));
    try std.testing.expectEqual(@as(i64, -42), loaded.getI64("count"));
    try std.testing.expectEqual(@as(f64, 1.25), loaded.getF64("ratio"));
    try std.testing.expectEqualStrings("日本語", loaded.getString("name").?);
    try std.testing.expectEqual(@as(?bool, null), loaded.getBool("count"));

    var duplicate_writer = try serde.Writer.init(std.testing.allocator, magic, format_version);
    defer duplicate_writer.deinit();
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(std.testing.allocator);
    try encodeRecord(std.testing.allocator, &payload, "dup", .{ .integer = 1 });
    try duplicate_writer.addChunk("KV00".*, payload.items);
    payload.clearRetainingCapacity();
    try encodeRecord(std.testing.allocator, &payload, "dup", .{ .integer = 2 });
    try duplicate_writer.addChunk("KV00".*, payload.items);
    const duplicate_bytes = try duplicate_writer.finish();
    defer std.testing.allocator.free(duplicate_bytes);
    try writeBytes(tmp.dir, "preferences.ash", duplicate_bytes);
    try std.testing.expectEqual(LoadResult.loaded, try loaded.load(std.testing.io, tmp.dir, "preferences.ash"));
    try std.testing.expectEqual(@as(i64, 2), loaded.getI64("dup"));

    loaded.clear();
    try loaded.save(std.testing.io, tmp.dir, "preferences.ash");
    try std.testing.expectEqual(LoadResult.loaded, try loaded.load(std.testing.io, tmp.dir, "preferences.ash"));
    try std.testing.expectEqual(@as(?i64, null), loaded.getI64("dup"));
}

test "preferences corruption defaults and next save overwrites all five forms" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var source = Preferences.init(std.testing.allocator);
    defer source.deinit();
    try source.setI64("ok", 7);
    try source.save(std.testing.io, tmp.dir, "seed.ash");
    const valid = try tmp.dir.readFileAlloc(std.testing.io, "seed.ash", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(valid);

    var crc_broken = try std.testing.allocator.dupe(u8, valid);
    defer std.testing.allocator.free(crc_broken);
    crc_broken[crc_broken.len - 1] ^= 1;
    try checkCorrupt(&tmp.dir, "crc.ash", crc_broken);

    try checkCorrupt(&tmp.dir, "footer.ash", valid[0 .. valid.len - 1]);

    var length_broken = try std.testing.allocator.dupe(u8, valid);
    defer std.testing.allocator.free(length_broken);
    length_broken[12] = 0xff;
    try checkCorrupt(&tmp.dir, "length.ash", length_broken);

    var old_schema = try std.testing.allocator.dupe(u8, valid);
    defer std.testing.allocator.free(old_schema);
    std.mem.writeInt(u16, old_schema[6..8], 0, .little);
    std.mem.writeInt(u32, old_schema[old_schema.len - 4 ..][0..4], std.hash.Crc32.hash(old_schema[0 .. old_schema.len - 4]), .little);
    try checkCorrupt(&tmp.dir, "schema0.ash", old_schema);

    var new_schema = try std.testing.allocator.dupe(u8, valid);
    defer std.testing.allocator.free(new_schema);
    std.mem.writeInt(u16, new_schema[6..8], 2, .little);
    std.mem.writeInt(u32, new_schema[new_schema.len - 4 ..][0..4], std.hash.Crc32.hash(new_schema[0 .. new_schema.len - 4]), .little);
    try checkCorrupt(&tmp.dir, "schema2.ash", new_schema);

    try checkCorrupt(&tmp.dir, "empty.ash", &.{});
}

fn writeBytes(dir: std.Io.Dir, file_name: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(std.testing.io, file_name, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
}

fn checkCorrupt(dir: *std.Io.Dir, file_name: []const u8, bytes: []const u8) !void {
    try writeBytes(dir.*, file_name, bytes);
    var prefs = Preferences.init(std.testing.allocator);
    defer prefs.deinit();
    try std.testing.expectEqual(LoadResult.defaulted, try prefs.load(std.testing.io, dir.*, file_name));
    try std.testing.expectEqual(@as(?i64, null), prefs.getI64("ok"));
    try prefs.setI64("repaired", 1);
    try prefs.save(std.testing.io, dir.*, file_name);
    try std.testing.expectEqual(LoadResult.loaded, try prefs.load(std.testing.io, dir.*, file_name));
    try std.testing.expectEqual(@as(i64, 1), prefs.getI64("repaired"));
}
