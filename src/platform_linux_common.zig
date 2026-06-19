//! Linux backend 共通実装（TASK-28.5.1）
//!
//! X11 / Wayland 両 backend が再利用する、display 技術に依存しない処理:
//!   - `getTime`: clock_gettime(CLOCK_MONOTONIC_RAW) ベースの高精度モノトニック時刻。
//!   - ファイル選択ダイアログ: zenity サブプロセス（Linux にネイティブ API が無いため）。
//!
//! 本ファイルは `@cImport`（X11 / Wayland）しない。libc の `clock_gettime` を extern 宣言し、
//! dialog は `std.process.run` で完結する。`platform_linux_x11.zig` / `platform_linux_wayland.zig`
//! から `pub const getTime = common.getTime;` 等で re-export する。

const std = @import("std");
const types = @import("platform_types.zig");

const SaveDialogOptions = types.SaveDialogOptions;
const OpenDialogOptions = types.OpenDialogOptions;
const DialogError = types.DialogError;

// ============================================================================
// getTime: clock_gettime(CLOCK_MONOTONIC_RAW) → 失敗時 CLOCK_MONOTONIC
// （link_libc 済み。型を確実に制御するため extern を自前宣言）
// ============================================================================
extern fn clock_gettime(clk_id: c_int, tp: *std.c.timespec) c_int;
const CLOCK_MONOTONIC: c_int = 1;
const CLOCK_MONOTONIC_RAW: c_int = 4;

pub fn getTime() f64 {
    var ts: std.c.timespec = undefined;
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &ts) != 0) {
        if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    }
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) * 1e-9;
}

// ============================================================================
// ファイル選択ダイアログ（TASK-28.4）
//
// Linux にネイティブのファイル選択 API は無いため zenity サブプロセスで実現する。
// `std.process.run` が spawn→stdout/stderr collect→wait を一括で行う（内部の
// MultiReader が pipe 詰まりを回避）。結果は term と stderr で分類する:
//   - spawn FileNotFound（zenity 不在）          → error.DialogUnavailable
//   - exit 0                                      → stdout の絶対パス（改行 trim）を dupe
//   - exit 1 かつ stderr 空                       → null（ユーザーキャンセル / クローズ）
//   - exit 1 かつ stderr 非空（GTK 初期化失敗等） → error.DialogFailed（silent cancel にしない）
//   - その他 exit / signal / stdout 空 / 上限超過 → error.DialogFailed
// メインスレッドから呼ばれる（RT スレッドではない）ので malloc/spawn の制約はない。
// ============================================================================

/// zenity の stdout/stderr 上限（パス用途には十分。暴走出力に対する安全弁）。
const dialog_output_limit: std.Io.Limit = .limited(64 * 1024);

pub fn saveFileDialog(gpa: std.mem.Allocator, io: std.Io, opts: SaveDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    // 実行時に組み立てる引数（--filename= / --file-filter=）は使用後に free する。
    var filename_arg: ?[]u8 = null;
    defer if (filename_arg) |a| gpa.free(a);
    var filter_arg: ?[]u8 = null;
    defer if (filter_arg) |a| gpa.free(a);

    try argv.append(gpa, "zenity");
    try argv.append(gpa, "--file-selection");
    try argv.append(gpa, "--save");
    if (opts.default_name) |name| {
        filename_arg = try std.fmt.allocPrint(gpa, "--filename={s}", .{name});
        try argv.append(gpa, filename_arg.?);
    }
    if (opts.allowed_ext) |ext| {
        filter_arg = try fileFilterArg(gpa, ext);
        try argv.append(gpa, filter_arg.?);
    }

    return runZenity(gpa, io, argv.items);
}

pub fn openFileDialog(gpa: std.mem.Allocator, io: std.Io, opts: OpenDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    var filter_arg: ?[]u8 = null;
    defer if (filter_arg) |a| gpa.free(a);

    try argv.append(gpa, "zenity");
    try argv.append(gpa, "--file-selection");
    if (opts.allowed_ext) |ext| {
        filter_arg = try fileFilterArg(gpa, ext);
        try argv.append(gpa, filter_arg.?);
    }

    return runZenity(gpa, io, argv.items);
}

/// `--file-filter=NAME | *.ext` を組み立てる（zenity manpage 形式）。
/// allowed_ext は拡張子のみ（"png"。ドット/アスタリスク無し）前提。
fn fileFilterArg(gpa: std.mem.Allocator, ext: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "--file-filter={s} files | *.{s}", .{ ext, ext });
}

/// zenity を起動し、結果を (パス | null=キャンセル | DialogError) に分類する。
fn runZenity(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = dialog_output_limit,
        .stderr_limit = dialog_output_limit,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return error.DialogUnavailable, // zenity 不在
        else => return error.DialogFailed,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| switch (code) {
            0 => {
                const path = std.mem.trimEnd(u8, result.stdout, "\r\n");
                if (path.len == 0) return error.DialogFailed; // 成功なのにパス無し＝異常
                return try gpa.dupe(u8, path);
            },
            // zenity はキャンセル/クローズも exit 1。GTK 初期化失敗等も exit 1 になりうるため
            // stderr の有無で「キャンセル」と「機構が使えない」を切り分ける。
            1 => if (result.stderr.len == 0) return null else return error.DialogFailed,
            else => return error.DialogFailed,
        },
        else => return error.DialogFailed, // signal / stopped / unknown
    }
}
