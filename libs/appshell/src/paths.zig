//! Resolve conventional application-data directories.

const std = @import("std");
const builtin = @import("builtin");

/// Create and open the application-data directory.
///
/// `override_path` is expected to be absolute. Ordinary env vars are read via Zig 0.16 std.c getenv,
/// while directory ops stay limited to std.Io.Dir.
///
/// This repository's browser build (`web/kngn.js`'s WASI shim) is a flat, file-only in-memory
/// store with no directory concept at all, so without `override_path` this fails with
/// `error.PersistenceUnsupported` there rather than opening a real directory; see `defaultPath`.
/// Callers that run on wasm should treat that as "no persistence available" and skip calling
/// this rather than surface it as a fatal error.
pub fn openAppDataDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    app_name: []const u8,
    override_path: ?[]const u8,
) !std.Io.Dir {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = if (override_path) |path| blk: {
        if (std.fs.path.isAbsolute(path)) break :blk path;
        const cwd_len = try std.process.currentPath(io, &base_buf);
        break :blk try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_buf[0..cwd_len], path });
    } else try defaultPath(&path_buf, &base_buf, app_name);
    try std.Io.Dir.cwd().createDirPath(io, path);
    _ = allocator;
    return std.Io.Dir.openDirAbsolute(io, path, .{});
}

/// Create and open the autosave directory inside the application-data directory.
///
/// `autosave.scan` calls `iterate()` on this function's return value (the autosave directory), so
/// open with `.iterate = true`. Per `std.Io.Dir.OpenOptions.iterate` docs,
/// iterating a Dir opened with iterate=false is Illegal Behavior; skipping it means:
///   - Linux: non-iterate open yields an O_PATH fd; `dirReadLinux`'s `posixSeekTo` then
///     BADF-**panics** (programmer bug; not catchable).
///   - Windows: opened without `FILE_LIST_DIRECTORY`; `NtQueryDirectoryFile` returns
///     `error.AccessDenied` (catchable, but scan fails).
///   - macOS/BSD: no O_PATH equivalent; always opens fully capable, so the bug is undetectable (silently works).
/// macOS-only testing will not surface this, so when opening a Dir decide whether you will iterate later
/// and always set `.iterate = true` explicitly, as this function does.
pub fn openAutosaveDir(io: std.Io, app_data_dir: std.Io.Dir) !std.Io.Dir {
    app_data_dir.createDirPath(io, "autosave") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return app_data_dir.openDir(io, "autosave", .{ .iterate = true });
}

/// From a document path, build a filename-safe stable autosave ID.
///
/// Relative paths are normalized against cwd before hashing. The original path itself is stored in the
/// autosave envelope, so this function's return value carries no path information.
pub fn autosaveFileName(io: std.Io, allocator: std.mem.Allocator, path: ?[]const u8) ![]u8 {
    if (path == null) return allocator.dupe(u8, "untitled.autosave");
    const normalized = try normalizePath(io, allocator, path.?);
    defer allocator.free(normalized);
    const hash = std.hash.Wyhash.hash(0, normalized);
    return std.fmt.allocPrint(allocator, "{x:0>16}.autosave", .{hash});
}

/// Normalize the path that seeds an autosave ID against OS separators and `.`/`..`.
pub fn normalizePath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(allocator, &.{path});

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    return std.fs.path.resolve(allocator, &.{ cwd_buf[0..cwd_len], path });
}

fn env(name: [*:0]const u8) ?[]const u8 {
    // Wasm has no process env; env-based path overrides are a native-only development aid.
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .freestanding) return null;
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

fn defaultPath(buf: []u8, base_buf: []u8, app_name: []const u8) ![]const u8 {
    const base = switch (builtin.os.tag) {
        .macos => blk: {
            const home = env("HOME") orelse return error.HomeNotFound;
            break :blk try std.fmt.bufPrint(base_buf, "{s}/Library/Application Support", .{home});
        },
        .windows => blk: {
            const root = env("APPDATA") orelse env("LOCALAPPDATA") orelse return error.AppDataNotFound;
            break :blk try std.fmt.bufPrint(base_buf, "{s}", .{root});
        },
        // Not an env-var lookup failure: wasm has no HOME to be missing in the first place, and
        // even a resolved path could not be opened (this repository's browser WASI shim, see
        // openAppDataDir's doc comment, has no directory concept at all). Name the error for
        // what it is rather than reusing HomeNotFound, which would misleadingly imply setting
        // HOME would fix it.
        .wasi, .freestanding => return error.PersistenceUnsupported,
        else => blk: {
            if (env("XDG_CONFIG_HOME")) |xdg| break :blk try std.fmt.bufPrint(base_buf, "{s}", .{xdg});
            const home = env("HOME") orelse return error.HomeNotFound;
            break :blk try std.fmt.bufPrint(base_buf, "{s}/.config", .{home});
        },
    };
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ base, app_name }) catch |err| switch (err) {
        error.NoSpaceLeft => error.PathTooLong,
    };
}

test "override path is created and opened" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(std.testing.io, &cwd_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/.zig-cache/tmp/{s}", .{
        cwd_buf[0..cwd_len],
        tmp.sub_path[0..],
    });
    var dir = try openAppDataDir(std.testing.io, std.testing.allocator, "ignored", path);
    dir.close(std.testing.io);
}

test "autosave directory and names use tmpDir and stable IDs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var autosave_dir = try openAutosaveDir(std.testing.io, tmp.dir);
    defer autosave_dir.close(std.testing.io);

    const named_a = try autosaveFileName(std.testing.io, std.testing.allocator, "a/../document.pix");
    defer std.testing.allocator.free(named_a);
    const named_b = try autosaveFileName(std.testing.io, std.testing.allocator, "document.pix");
    defer std.testing.allocator.free(named_b);
    try std.testing.expectEqualStrings(named_a, named_b);
    const untitled = try autosaveFileName(std.testing.io, std.testing.allocator, null);
    defer std.testing.allocator.free(untitled);
    try std.testing.expectEqualStrings("untitled.autosave", untitled);
}
