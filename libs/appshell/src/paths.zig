//! 慣習的なアプリデータディレクトリの解決。

const std = @import("std");
const builtin = @import("builtin");

/// アプリデータ用ディレクトリを作成して開く。
///
/// `override_path` は絶対パスを想定する。通常の環境変数は Zig 0.16 の std.c getenv
/// を介して読むが、ディレクトリ操作は std.Io.Dir に限定している。
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

fn env(name: [*:0]const u8) ?[]const u8 {
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
    const path = try tmp.dir.realPathAlloc(std.testing.io, std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    var dir = try openAppDataDir(std.testing.io, std.testing.allocator, "ignored", path);
    dir.close(std.testing.io);
}
