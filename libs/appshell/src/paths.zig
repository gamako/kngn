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
///
/// When `override_path` is null, unattended runs redirect to a per-process temporary directory
/// (see `shouldIsolateDefaultPath`). Explicit `KNGN_APPSHELL_DIR` (passed as `override_path`)
/// always wins; automatic isolation does not apply.
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
    } else try defaultPath(io, &path_buf, &base_buf, app_name);
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

/// Create and open the history-journal directory inside the application-data directory.
///
/// Opened with `.iterate = true` for the same reason as `openAutosaveDir`: the directory
/// sweep that enforces the global history budget iterates it.
pub fn openHistoryDir(io: std.Io, app_data_dir: std.Io.Dir) !std.Io.Dir {
    app_data_dir.createDirPath(io, "history") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return app_data_dir.openDir(io, "history", .{ .iterate = true });
}

/// From a document path, build a filename-safe stable history-journal name.
///
/// Only documents that have a path get a journal: an unsaved document has nothing to bind
/// a journal to, so this returns null for it rather than inventing a shared name that two
/// untitled documents would fight over. The journal header stores the full path, so a hash
/// collision is detected on open rather than silently mixing two documents.
pub fn historyFileName(io: std.Io, allocator: std.mem.Allocator, path: ?[]const u8) !?[]u8 {
    const value = path orelse return null;
    const normalized = try normalizePath(io, allocator, value);
    defer allocator.free(normalized);
    const hash = std.hash.Wyhash.hash(0, normalized);
    return try std.fmt.allocPrint(allocator, "{x:0>16}.hjr", .{hash});
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

/// Whether the conventional app-data path should be redirected to a per-process temporary directory.
///
/// Callers that pass an explicit override (`KNGN_APPSHELL_DIR`) never consult this: the override
/// always wins and automatic isolation does not apply.
///
/// | env state | isolate |
/// |---|---:|
/// | `KNGN_HARNESS_SCRIPT` present | yes |
/// | `KNGN_HEADLESS` is `1` | yes |
/// | `KNGN_HARNESS_LISTEN` present, `KNGN_HEADLESS` unset | no |
/// | `KNGN_HARNESS_MANUAL_CLOCK` alone | no |
/// | copilot env only | no |
///
/// `script_present` is true when `KNGN_HARNESS_SCRIPT` exists (any value).
/// `headless_one` is true when `KNGN_HEADLESS` equals `"1"` (same contract as `platform.init`).
pub fn shouldIsolateDefaultPath(script_present: bool, headless_one: bool) bool {
    return script_present or headless_one;
}

fn isolationRequested() bool {
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .freestanding) return false;
    const script_present = env("KNGN_HARNESS_SCRIPT") != null;
    const headless_one = if (env("KNGN_HEADLESS")) |v| std.mem.eql(u8, v, "1") else false;
    return shouldIsolateDefaultPath(script_present, headless_one);
}

/// Process-once isolated root: `<temp>/kngn-appdata-<pid>-<nonce>`.
/// Created at most once; never deleted (cleanup is left to the OS temp directory).
/// Creation failure does not fall back to the real app-data path.
var isolated_root_storage: [std.fs.max_path_bytes]u8 = undefined;
var isolated_root_len: usize = 0;
var isolated_root_ready: bool = false;
var isolated_root_logged: bool = false;

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    if (v.len == 0) return null;
    return v;
}

/// Pick the temporary-directory root for automatic app-data isolation from env values.
///
/// - Windows (`windows == true`): `TEMP`, then `TMP`, then `localappdata_temp`
///   (the caller supplies the joined `LOCALAPPDATA\\Temp` path).
/// - Other platforms: `TMPDIR`, then `posix_fallback` (normally `"/tmp"`).
///
/// Returns null only when every Windows candidate is missing or empty (so the caller can
/// error instead of falling back to the real app-data path).
pub fn resolveIsolationTempRoot(
    windows: bool,
    temp: ?[]const u8,
    tmp: ?[]const u8,
    localappdata_temp: ?[]const u8,
    tmpdir: ?[]const u8,
    posix_fallback: []const u8,
) ?[]const u8 {
    if (windows) {
        if (nonEmpty(temp)) |v| return v;
        if (nonEmpty(tmp)) |v| return v;
        if (nonEmpty(localappdata_temp)) |v| return v;
        return null;
    }
    if (nonEmpty(tmpdir)) |v| return v;
    return posix_fallback;
}

/// This process's id, which keeps unattended processes running at the same time on separate
/// isolated roots.
///
/// `std.c.getpid` declares the libc call, and its `pid_t` is a `HANDLE` on Windows, so that
/// OS reads the id out of the process block instead. Neither value is unique for all time —
/// an id becomes available again once a process exits — but the root only has to separate
/// processes that overlap, and its name carries a nonce as well.
fn processId() u32 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.c.getpid()),
    };
}

fn isolatedRoot(io: std.Io) ![]const u8 {
    if (isolated_root_ready) return isolated_root_storage[0..isolated_root_len];

    const windows = builtin.os.tag == .windows;
    var local_temp_storage: [std.fs.max_path_bytes]u8 = undefined;
    const localappdata_temp: ?[]const u8 = if (windows) blk: {
        const la = env("LOCALAPPDATA") orelse break :blk null;
        break :blk std.fmt.bufPrint(&local_temp_storage, "{s}\\Temp", .{la}) catch null;
    } else null;
    const tmp = resolveIsolationTempRoot(
        windows,
        env("TEMP"),
        env("TMP"),
        localappdata_temp,
        env("TMPDIR"),
        "/tmp",
    ) orelse return error.TempDirNotFound;

    const pid = processId();
    const ts = std.Io.Clock.now(.awake, io);
    const nonce: u32 = @truncate(@as(u64, @intCast(ts.nanoseconds)));
    const root = try std.fmt.bufPrint(&isolated_root_storage, "{s}/kngn-appdata-{d}-{x}", .{ tmp, pid, nonce });
    try std.Io.Dir.cwd().createDirPath(io, root);
    isolated_root_len = root.len;
    isolated_root_ready = true;
    if (!isolated_root_logged) {
        isolated_root_logged = true;
        std.debug.print("[appshell] isolated app-data root: {s}\n", .{root});
    }
    return isolated_root_storage[0..isolated_root_len];
}

fn defaultPath(io: std.Io, buf: []u8, base_buf: []u8, app_name: []const u8) ![]const u8 {
    if (isolationRequested()) {
        const root = try isolatedRoot(io);
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ root, app_name }) catch |err| switch (err) {
            error.NoSpaceLeft => error.PathTooLong,
        };
    }
    return conventionalDefaultPath(buf, base_buf, app_name);
}

/// The OS-standard app-data path for `app_name`, with no automatic isolation.
///
/// `defaultPath` delegates here once it has decided the run is attended; tests call it to assert
/// that an isolated path is not the conventional one.
fn conventionalDefaultPath(buf: []u8, base_buf: []u8, app_name: []const u8) ![]const u8 {
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

test "history directory and journal names use tmpDir and stable IDs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var history_dir = try openHistoryDir(std.testing.io, tmp.dir);
    defer history_dir.close(std.testing.io);

    const named_a = (try historyFileName(std.testing.io, std.testing.allocator, "a/../document.pix")).?;
    defer std.testing.allocator.free(named_a);
    const named_b = (try historyFileName(std.testing.io, std.testing.allocator, "document.pix")).?;
    defer std.testing.allocator.free(named_b);
    try std.testing.expectEqualStrings(named_a, named_b);
    try std.testing.expect(std.mem.endsWith(u8, named_a, ".hjr"));
    // An unsaved document has no journal name at all.
    try std.testing.expect(try historyFileName(std.testing.io, std.testing.allocator, null) == null);
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

test "shouldIsolateDefaultPath: script or headless isolates; listen-with-display and clock alone do not" {
    try std.testing.expect(shouldIsolateDefaultPath(true, false)); // SCRIPT present
    try std.testing.expect(shouldIsolateDefaultPath(false, true)); // HEADLESS=1 alone
    try std.testing.expect(shouldIsolateDefaultPath(true, true));
    try std.testing.expect(!shouldIsolateDefaultPath(false, false)); // LISTEN+display / MANUAL_CLOCK / copilot
}

test "resolveIsolationTempRoot: Windows prefers TEMP then TMP then LOCALAPPDATA\\Temp" {
    try std.testing.expectEqualStrings(
        "C:\\Temp",
        resolveIsolationTempRoot(true, "C:\\Temp", "C:\\Tmp", "C:\\Users\\x\\AppData\\Local\\Temp", null, "/tmp").?,
    );
    try std.testing.expectEqualStrings(
        "C:\\Tmp",
        resolveIsolationTempRoot(true, null, "C:\\Tmp", "C:\\Users\\x\\AppData\\Local\\Temp", null, "/tmp").?,
    );
    try std.testing.expectEqualStrings(
        "C:\\Users\\x\\AppData\\Local\\Temp",
        resolveIsolationTempRoot(true, null, null, "C:\\Users\\x\\AppData\\Local\\Temp", null, "/tmp").?,
    );
    try std.testing.expect(resolveIsolationTempRoot(true, null, null, null, "/var/tmp", "/tmp") == null);
    try std.testing.expect(resolveIsolationTempRoot(true, "", "", "", null, "/tmp") == null);
}

test "resolveIsolationTempRoot: non-Windows prefers TMPDIR then /tmp" {
    try std.testing.expectEqualStrings(
        "/custom/tmp",
        resolveIsolationTempRoot(false, "C:\\Temp", "C:\\Tmp", null, "/custom/tmp", "/tmp").?,
    );
    try std.testing.expectEqualStrings(
        "/tmp",
        resolveIsolationTempRoot(false, "C:\\Temp", null, null, null, "/tmp").?,
    );
    try std.testing.expectEqualStrings(
        "/tmp",
        resolveIsolationTempRoot(false, null, null, null, "", "/tmp").?,
    );
}

test "isolated root is stable within a process and differs from the conventional path" {
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .freestanding) return;

    // Force the isolated branch without mutating process env: call isolatedRoot + join directly.
    var path_a: [std.fs.max_path_bytes]u8 = undefined;
    var path_b: [std.fs.max_path_bytes]u8 = undefined;
    const root = try isolatedRoot(std.testing.io);
    const a = try std.fmt.bufPrint(&path_a, "{s}/{s}", .{ root, "pixie" });
    const b = try std.fmt.bufPrint(&path_b, "{s}/{s}", .{ root, "pixie" });
    try std.testing.expectEqualStrings(a, b);

    var conv_buf: [std.fs.max_path_bytes]u8 = undefined;
    var conv_base: [std.fs.max_path_bytes]u8 = undefined;
    const conventional = conventionalDefaultPath(&conv_buf, &conv_base, "pixie") catch return;
    try std.testing.expect(!std.mem.eql(u8, a, conventional));
    try std.testing.expect(std.mem.indexOf(u8, a, "kngn-appdata-") != null);
}
