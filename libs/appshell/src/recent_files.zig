//! Most-recently-used file list.

const std = @import("std");
const serde = @import("serde");

pub const format_version: u16 = 1;
pub const magic: u32 = @as(u32, 'A') | (@as(u32, 'S') << 8) | (@as(u32, 'H') << 16) | (@as(u32, '1') << 24);
const max_file_size = 16 * 1024 * 1024;
pub const LoadResult = enum { loaded, defaulted };

pub const RecentFiles = struct {
    allocator: std.mem.Allocator,
    max_items: usize,
    list: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, max_items: usize) RecentFiles {
        return .{ .allocator = allocator, .max_items = max_items };
    }

    pub fn deinit(self: *RecentFiles) void {
        self.clear();
        self.list.deinit(self.allocator);
    }

    pub fn push(self: *RecentFiles, path: []const u8) !void {
        var index: ?usize = null;
        for (self.list.items, 0..) |item, i| if (std.mem.eql(u8, item, path)) {
            index = i;
            break;
        };
        if (index) |i| {
            self.allocator.free(self.list.items[i]);
            _ = self.list.orderedRemove(i);
        }
        if (self.max_items == 0) return;
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        try self.list.insert(self.allocator, 0, owned);
        while (self.list.items.len > self.max_items) self.allocator.free(self.list.pop().?);
    }

    pub fn items(self: *const RecentFiles) []const []const u8 {
        return @as([]const []const u8, @ptrCast(self.list.items));
    }

    pub fn load(self: *RecentFiles, io: std.Io, dir: std.Io.Dir, file_name: []const u8) !LoadResult {
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
            if (!std.mem.eql(u8, &chunk.tag, "PATH")) continue;
            if (chunk.payload.len == 0) {
                self.clear();
                return .defaulted;
            }
            self.push(chunk.payload) catch |err| {
                self.clear();
                return err;
            };
        }
        return .loaded;
    }

    pub fn save(self: *const RecentFiles, io: std.Io, dir: std.Io.Dir, file_name: []const u8) !void {
        var writer = try serde.Writer.init(self.allocator, magic, format_version);
        defer writer.deinit();
        for (self.list.items) |path| try writer.addChunk("PATH".*, path);
        const bytes = try writer.finish();
        defer self.allocator.free(bytes);
        var atomic = try dir.createFileAtomic(io, file_name, .{ .replace = true });
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, bytes);
        try atomic.replace(io);
    }

    pub fn pruneMissing(self: *RecentFiles, io: std.Io, file_dir: std.Io.Dir) !usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.list.items.len) {
            file_dir.access(io, self.list.items[i], .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    self.allocator.free(self.list.items[i]);
                    _ = self.list.orderedRemove(i);
                    removed += 1;
                    continue;
                },
                else => return err,
            };
            i += 1;
        }
        return removed;
    }

    fn clear(self: *RecentFiles) void {
        for (self.list.items) |path| self.allocator.free(path);
        self.list.clearRetainingCapacity();
    }
};

test "recent files MRU, limit, and delayed prune" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var present = try tmp.dir.createFile(std.testing.io, "present.txt", .{});
    defer present.close(std.testing.io);
    var recent = RecentFiles.init(std.testing.allocator, 2);
    defer recent.deinit();
    try recent.push("missing.txt");
    try recent.push("present.txt");
    try recent.push("missing.txt");
    try recent.save(std.testing.io, tmp.dir, "recent_files.ash");
    var loaded = RecentFiles.init(std.testing.allocator, 2);
    defer loaded.deinit();
    try std.testing.expectEqual(LoadResult.loaded, try loaded.load(std.testing.io, tmp.dir, "recent_files.ash"));
    try std.testing.expectEqual(@as(usize, 2), loaded.items().len);
    try std.testing.expectEqual(@as(usize, 1), try loaded.pruneMissing(std.testing.io, tmp.dir));
    try std.testing.expectEqualStrings("present.txt", loaded.items()[0]);
    try loaded.push("third.txt");
    try std.testing.expectEqualStrings("third.txt", loaded.items()[0]);
    try std.testing.expectEqualStrings("present.txt", loaded.items()[1]);
}
