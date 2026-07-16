//! 本体を壊さない atomic save と一世代 backup。
//!
//! ホットパス宣言: 保存・backup・削除は明示 save または autosave の閾値到達時のみ。
//! フレーム毎、RT、非同期保存 thread では実行しない。

const std = @import("std");

pub const WriteOptions = struct {
    backup: bool = false,
};

/// path へ bytes を atomic に保存する。
///
/// 既存 path がある場合、`backup` が true なら置換前の bytes を path + ".bak"
/// へ保存してから本体を置換する。backup 保存に失敗した場合、本体には触れない。
pub fn writeAtomic(io: std.Io, path: []const u8, bytes: []const u8, options: WriteOptions) !void {
    var parent = try openParent(io, path);
    defer if (parent.owns) parent.dir.close(io);
    return writeAtomicToDir(io, parent.dir, std.fs.path.basename(path), bytes, options);
}

/// 開いている directory 内のファイルを atomic に保存する。autosave が使用する。
pub fn writeAtomicToDir(io: std.Io, dir: std.Io.Dir, file_name: []const u8, bytes: []const u8, options: WriteOptions) !void {
    return writeAtomicToDirImpl(io, dir, file_name, bytes, options, false);
}

fn writeAtomicToDirImpl(
    io: std.Io,
    dir: std.Io.Dir,
    file_name: []const u8,
    bytes: []const u8,
    options: WriteOptions,
    fail_before_replace: bool,
) !void {
    if (options.backup) {
        const previous = dir.readFileAlloc(io, file_name, std.heap.page_allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (previous) |old_bytes| {
            defer std.heap.page_allocator.free(old_bytes);
            const backup_name = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.bak", .{file_name});
            defer std.heap.page_allocator.free(backup_name);
            try writeAtomicToDirImpl(io, dir, backup_name, old_bytes, .{}, false);
        }
    }

    var atomic = try dir.createFileAtomic(io, file_name, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    // 親 directory の fsync は MVP では行わない。Zig 0.16 の portable Dir に
    // directory sync API がなく、POSIX 固有 API を導入すると Windows 共通契約を崩す。
    if (fail_before_replace) return error.TestInjectedFailure;
    try atomic.replace(io);
}

const OpenParent = struct { dir: std.Io.Dir, owns: bool };

fn openParent(io: std.Io, path: []const u8) !OpenParent {
    const parent_path = std.fs.path.dirname(path) orelse return .{ .dir = std.Io.Dir.cwd(), .owns = false };
    if (std.fs.path.isAbsolute(parent_path)) return .{ .dir = try std.Io.Dir.openDirAbsolute(io, parent_path, .{}), .owns = true };
    if (parent_path.len == 0 or std.mem.eql(u8, parent_path, ".")) return .{ .dir = std.Io.Dir.cwd(), .owns = false };
    return .{ .dir = try std.Io.Dir.cwd().openDir(io, parent_path, .{}), .owns = true };
}

test "atomic save creates file without backup on first save" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeAtomicToDir(std.testing.io, tmp.dir, "doc.pix", "one", .{ .backup = true });
    const body = try tmp.dir.readFileAlloc(std.testing.io, "doc.pix", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("one", body);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "doc.pix.bak", .{}));
}

test "atomic save keeps one backup generation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeAtomicToDir(std.testing.io, tmp.dir, "doc.pix", "one", .{});
    try writeAtomicToDir(std.testing.io, tmp.dir, "doc.pix", "two", .{ .backup = true });
    try writeAtomicToDir(std.testing.io, tmp.dir, "doc.pix", "three", .{ .backup = true });
    const body = try tmp.dir.readFileAlloc(std.testing.io, "doc.pix", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(body);
    const backup = try tmp.dir.readFileAlloc(std.testing.io, "doc.pix.bak", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(backup);
    try std.testing.expectEqualStrings("three", body);
    try std.testing.expectEqualStrings("two", backup);
}

test "fail-before-replace leaves original and no temp file" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeAtomicToDir(std.testing.io, tmp.dir, "doc.pix", "original", .{});
    try std.testing.expectError(error.TestInjectedFailure, writeAtomicToDirImpl(std.testing.io, tmp.dir, "doc.pix", "replacement", .{}, true));
    const body = try tmp.dir.readFileAlloc(std.testing.io, "doc.pix", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("original", body);

    var it = tmp.dir.iterate();
    var names: usize = 0;
    while (try it.next(std.testing.io)) |entry| {
        if (entry.kind == .file) names += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), names);
}
