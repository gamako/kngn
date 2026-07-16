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

/// アプリデータディレクトリ内の autosave 用ディレクトリを作成して開く。
pub fn openAutosaveDir(io: std.Io, app_data_dir: std.Io.Dir) !std.Io.Dir {
    app_data_dir.createDirPath(io, "autosave") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return app_data_dir.openDir(io, "autosave", .{});
}

/// 文書 path から、ファイル名に安全な安定 autosave ID を生成する。
///
/// 相対 path は cwd に対して正規化してから hash する。元 path 自体は autosave
/// envelope に保存するため、この関数の戻り値に path の情報を持たせない。
pub fn autosaveFileName(io: std.Io, allocator: std.mem.Allocator, path: ?[]const u8) ![]u8 {
    if (path == null) return allocator.dupe(u8, "untitled.autosave");
    const normalized = try normalizePath(io, allocator, path.?);
    defer allocator.free(normalized);
    const hash = std.hash.Wyhash.hash(0, normalized);
    return std.fmt.allocPrint(allocator, "{x:0>16}.autosave", .{hash});
}

/// autosave ID の元になる path を OS の区切りと `.`/`..` に対して正規化する。
pub fn normalizePath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(allocator, &.{path});

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    return std.fs.path.resolve(allocator, &.{ cwd_buf[0..cwd_len], path });
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
