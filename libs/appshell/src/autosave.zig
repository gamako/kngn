//! dirty document の autosave と起動時 recovery candidate。
//!
//! ホットパス宣言: 編集イベントでは時刻更新だけ、tick では閾値判定だけを行う。
//! envelope encode と file I/O は 1 秒の idle 閾値に到達した main thread 上でのみ行う。

const std = @import("std");
const file_safety = @import("file_safety.zig");
const paths = @import("paths.zig");

pub const magic: u32 = @as(u32, 'A') | (@as(u32, 'S') << 8) | (@as(u32, 'V') << 16) | (@as(u32, '1') << 24);
pub const version: u16 = 1;
pub const idle_interval: f64 = 1.0;
const header_size: usize = 16;
const max_envelope_size: usize = 64 * 1024 * 1024;

pub const Envelope = struct {
    allocator: std.mem.Allocator,
    original_path: ?[]u8,
    snapshot: []u8,

    pub fn deinit(self: *Envelope) void {
        if (self.original_path) |path| self.allocator.free(path);
        self.allocator.free(self.snapshot);
        self.* = undefined;
    }
};

pub const Candidate = struct {
    allocator: std.mem.Allocator,
    file_name: []u8,
    envelope: Envelope,

    pub fn deinit(self: *Candidate) void {
        self.allocator.free(self.file_name);
        self.envelope.deinit();
        self.* = undefined;
    }
};

pub const SnapshotFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8;

pub const Controller = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    current_path: ?[]u8 = null,
    dirty_since: ?f64 = null,
    saved_revision: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: ?[]const u8) !Controller {
        return .{
            .allocator = allocator,
            .io = io,
            .dir = dir,
            .current_path = if (path) |value| try allocator.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *Controller) void {
        if (self.current_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    /// 文書切替後の autosave ID を変更する。既存ファイルの削除は caller が
    /// 文書切替成功を確認してから `clear` と組み合わせて行う。
    pub fn setPath(self: *Controller, path: ?[]const u8) !void {
        const owned = if (path) |value| try self.allocator.dupe(u8, value) else null;
        if (self.current_path) |old| self.allocator.free(old);
        self.current_path = owned;
        self.dirty_since = null;
        self.saved_revision = false;
    }

    pub fn markDirty(self: *Controller, now: f64) void {
        self.dirty_since = now;
        self.saved_revision = false;
    }

    /// idle 閾値に達した dirty revision を一度だけ保存する。保存した場合 true。
    pub fn tick(self: *Controller, now: f64, ctx: *anyopaque, snapshot: SnapshotFn) !bool {
        const since = self.dirty_since orelse return false;
        if (self.saved_revision or now - since < idle_interval) return false;

        const snapshot_bytes = try snapshot(ctx, self.allocator);
        defer self.allocator.free(snapshot_bytes);
        const envelope = try encodeEnvelope(self.allocator, self.current_path, snapshot_bytes);
        defer self.allocator.free(envelope);
        const file_name = try paths.autosaveFileName(self.io, self.allocator, self.current_path);
        defer self.allocator.free(file_name);
        try file_safety.writeAtomicToDir(self.io, self.dir, file_name, envelope, .{});
        self.saved_revision = true;
        return true;
    }

    /// active document の autosave を削除する。未作成または既に削除済みは成功扱い。
    pub fn clear(self: *Controller) !void {
        try clearPath(self.io, self.dir, self.allocator, self.current_path);
        self.dirty_since = null;
        self.saved_revision = false;
    }
};

pub fn encodeEnvelope(allocator: std.mem.Allocator, original_path: ?[]const u8, snapshot: []const u8) ![]u8 {
    const path_len = if (original_path) |path| path.len else 0;
    if (path_len > std.math.maxInt(u32) or snapshot.len > std.math.maxInt(u32)) return error.EnvelopeTooLarge;
    const total = std.math.add(usize, header_size, path_len) catch return error.EnvelopeTooLarge;
    const total_with_snapshot = std.math.add(usize, total, snapshot.len) catch return error.EnvelopeTooLarge;
    const bytes = try allocator.alloc(u8, total_with_snapshot);
    errdefer allocator.free(bytes);
    std.mem.writeInt(u32, bytes[0..4], magic, .little);
    std.mem.writeInt(u16, bytes[4..6], version, .little);
    std.mem.writeInt(u16, bytes[6..8], 0, .little);
    std.mem.writeInt(u32, bytes[8..12], @intCast(path_len), .little);
    std.mem.writeInt(u32, bytes[12..16], @intCast(snapshot.len), .little);
    if (original_path) |path| @memcpy(bytes[header_size .. header_size + path.len], path);
    @memcpy(bytes[header_size + path_len ..], snapshot);
    return bytes;
}

pub fn decodeEnvelope(allocator: std.mem.Allocator, bytes: []const u8) !Envelope {
    if (bytes.len < header_size or bytes.len > max_envelope_size) return error.MalformedEnvelope;
    if (std.mem.readInt(u32, bytes[0..4], .little) != magic) return error.InvalidMagic;
    if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.UnsupportedVersion;
    if (std.mem.readInt(u16, bytes[6..8], .little) != 0) return error.MalformedEnvelope;
    const path_len = std.mem.readInt(u32, bytes[8..12], .little);
    const snapshot_len = std.mem.readInt(u32, bytes[12..16], .little);
    const expected = std.math.add(usize, header_size, path_len) catch return error.MalformedEnvelope;
    const expected_with_snapshot = std.math.add(usize, expected, snapshot_len) catch return error.MalformedEnvelope;
    if (expected_with_snapshot != bytes.len or (path_len == 0 and snapshot_len == 0)) return error.MalformedEnvelope;

    const original_path = if (path_len == 0) null else try allocator.dupe(u8, bytes[header_size .. header_size + path_len]);
    errdefer if (original_path) |path| allocator.free(path);
    const snapshot = try allocator.dupe(u8, bytes[header_size + path_len ..]);
    return .{ .allocator = allocator, .original_path = original_path, .snapshot = snapshot };
}

/// autosave directoryから最初の有効な candidate を返す。壊れた/未知 version の
/// ファイルは recovery 候補にせず、次回起動時も診断用に残す。
pub fn scan(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !?Candidate {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".autosave")) continue;
        const bytes = dir.readFileAlloc(io, entry.name, allocator, .limited(max_envelope_size)) catch continue;
        defer allocator.free(bytes);
        var envelope = decodeEnvelope(allocator, bytes) catch continue;
        errdefer envelope.deinit();
        const file_name = try allocator.dupe(u8, entry.name);
        return Candidate{ .allocator = allocator, .file_name = file_name, .envelope = envelope };
    }
    return null;
}

pub fn discardCandidate(io: std.Io, dir: std.Io.Dir, file_name: []const u8) !void {
    dir.deleteFile(io, file_name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn clearPath(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, path: ?[]const u8) !void {
    const file_name = try paths.autosaveFileName(io, allocator, path);
    defer allocator.free(file_name);
    try discardCandidate(io, dir, file_name);
}

test "envelope round-trip and fixed fixture" {
    const fixture = [_]u8{
        'A', 'S', 'V', '1', 1,   0,   0,   0, 4, 0, 0, 0, 3, 0, 0, 0,
        'd', 'o', 'c', '1', 'a', 'b', 'c',
    };
    var decoded = try decodeEnvelope(std.testing.allocator, &fixture);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("doc1", decoded.original_path.?);
    try std.testing.expectEqualStrings("abc", decoded.snapshot);

    const encoded = try encodeEnvelope(std.testing.allocator, "doc1", "abc");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &fixture, encoded);
}

test "idle timer threshold, reset, duplicate suppression, and clear" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var controller = try Controller.init(std.testing.allocator, std.testing.io, tmp.dir, null);
    defer controller.deinit();
    var state: usize = 0;
    const snapshot = struct {
        fn run(ctx: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
            const count: *usize = @ptrCast(@alignCast(ctx));
            count.* += 1;
            return allocator.dupe(u8, "snapshot");
        }
    }.run;
    try std.testing.expect(!try controller.tick(1.0, &state, snapshot));
    controller.markDirty(1.0);
    try std.testing.expect(!try controller.tick(1.9, &state, snapshot));
    try std.testing.expect(try controller.tick(2.0, &state, snapshot));
    try std.testing.expect(!try controller.tick(3.0, &state, snapshot));
    try std.testing.expectEqual(@as(usize, 1), state);
    try controller.clear();
    try std.testing.expectEqual(@as(?Candidate, null), try scan(std.testing.allocator, std.testing.io, tmp.dir));
}

test "malformed and version-mismatched envelopes are rejected by scan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try file_safety.writeAtomicToDir(std.testing.io, tmp.dir, "bad.autosave", "bad", .{});
    try file_safety.writeAtomicToDir(std.testing.io, tmp.dir, "future.autosave", &.{ 'A', 'S', 'V', '1', 2, 0 }, .{});
    try std.testing.expectEqual(@as(?Candidate, null), try scan(std.testing.allocator, std.testing.io, tmp.dir));
}
