//! The shared Linux backend implementation
//!
//! What both the X11 and the Wayland backend reuse, independent of the display technology:
//!   - `getTime`: a high-resolution monotonic time based on clock_gettime(CLOCK_MONOTONIC_RAW).
//!   - The file selection dialogs: a zenity subprocess (Linux has no native API for them).
//!
//! This file does not `@cImport` (X11 or Wayland). It declares libc's `clock_gettime` as an extern,
//! and the dialogs are entirely `std.process.run`. `platform_linux_x11.zig` and
//! `platform_linux_wayland.zig` re-export it with `pub const getTime = common.getTime;` and the like.

const std = @import("std");
const types = @import("platform_types");

const SaveDialogOptions = types.SaveDialogOptions;
const OpenDialogOptions = types.OpenDialogOptions;
const DialogError = types.DialogError;

// ============================================================================
// getTime: clock_gettime(CLOCK_MONOTONIC_RAW), falling back to CLOCK_MONOTONIC
// (link_libc is on. The extern is declared here to keep the types firmly under control)
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
// The file selection dialogs
//
// Linux has no native file selection API, so a zenity subprocess provides one.
// `std.process.run` does the spawn, the stdout/stderr collection and the wait in one go (its internal
// MultiReader avoids a blocked pipe). The result is classified by term and stderr:
//   - a spawn FileNotFound (zenity is absent)          → error.DialogUnavailable
//   - exit 0                                           → dupe the absolute path from stdout (newline trimmed)
//   - exit 1 with empty stderr                         → null (the user cancelled or closed it)
//   - exit 1 with non-empty stderr (GTK failed to start, say) → error.DialogFailed (never a silent cancel)
//   - any other exit, a signal, empty stdout, or over the limit → error.DialogFailed
// It is called from the main thread (not the real-time thread), so malloc and spawn are unconstrained.
// ============================================================================

/// The limit on zenity's stdout and stderr (ample for a path; a safety valve against runaway output).
const dialog_output_limit: std.Io.Limit = .limited(64 * 1024);

pub fn saveFileDialog(gpa: std.mem.Allocator, io: std.Io, opts: SaveDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    // The arguments built at runtime (--filename= and --file-filter=) are freed after use.
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

/// Build `--file-filter=NAME | *.ext` (the form in zenity's manpage).
/// allowed_ext is assumed to be the extension alone ("png": no dot, no asterisk).
fn fileFilterArg(gpa: std.mem.Allocator, ext: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "--file-filter={s} files | *.{s}", .{ ext, ext });
}

/// Start zenity and classify the result as a path, null (cancelled), or a DialogError.
fn runZenity(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = dialog_output_limit,
        .stderr_limit = dialog_output_limit,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return error.DialogUnavailable, // zenity is absent
        else => return error.DialogFailed,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| switch (code) {
            0 => {
                const path = std.mem.trimEnd(u8, result.stdout, "\r\n");
                if (path.len == 0) return error.DialogFailed; // success yet no path: something is wrong
                return try gpa.dupe(u8, path);
            },
            // zenity exits 1 for a cancel or a close, but GTK failing to start also exits 1, so
            // the presence of stderr is what separates "cancelled" from "the mechanism is unusable".
            1 => if (result.stderr.len == 0) return null else return error.DialogFailed,
            else => return error.DialogFailed,
        },
        else => return error.DialogFailed, // signal / stopped / unknown
    }
}
