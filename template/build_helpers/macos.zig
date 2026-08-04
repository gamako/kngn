// External projects vendor this helper from kngn/build_helpers/.
// The kngn/build_helpers/ file is authoritative; keep all copies byte-identical.
//! Resolve macOS SDK / toolchain paths and link frameworks
//!
//! nix's zig 0.16 does not auto-detect the macOS SDK, so
//! resolve via `xcode-select -p` (toolchain) and `xcrun --show-sdk-path` (SDK) and pass the paths to the exe explicitly.

const std = @import("std");

pub const MacOSSDKPaths = struct {
    sdk_path: []const u8,
    toolchain_path: []const u8,
    /// The SDK version reported by `xcrun --show-sdk-version` (e.g. "15.2"), or "unknown"
    /// when `sdk_override` bypassed `xcrun`. See `checked_sdk_major_range` for what this
    /// is used for.
    sdk_version: []const u8,
};

/// The macOS SDK major version range this project's Swift runtime autolinking
/// (`build_helpers/swift.zig`'s `optional_libs`) is checked against. `swiftc` changes
/// which overlay libraries it force-loads across SDK versions, so a host outside this
/// range is the first thing to suspect when a build fails with an undefined
/// `__swift_FORCE_LOAD_$_<name>` symbol. This is a coarse, SDK-major-only boundary, not a
/// guarantee: a new `swiftc` on an SDK inside the range can still force-load a name this
/// project has not seen yet.
pub const checked_sdk_major_range = .{ .min = 15, .max = 26 };

/// Resolve macOS SDK / toolchain paths.
/// Use overrides when given; otherwise toolchain=`xcode-select -p`, SDK=`xcrun --show-sdk-path`.
pub fn resolveMacOSSDKPaths(
    b: *std.Build,
    toolchain_override: ?[]const u8,
    sdk_override: ?[]const u8,
) MacOSSDKPaths {
    const allocator = b.allocator;

    const toolchain_path = if (toolchain_override) |path|
        path
    else blk: {
        const developer_path = std.mem.trim(u8, b.run(&.{ "xcode-select", "-p" }), " \n\r");
        break :blk std.fmt.allocPrint(
            allocator,
            "{s}/Toolchains/XcodeDefault.xctoolchain",
            .{developer_path},
        ) catch unreachable;
    };

    const sdk_path = if (sdk_override) |path|
        path
    else blk: {
        const output = b.run(&.{ "xcrun", "--show-sdk-path" });
        break :blk std.mem.trim(u8, output, " \n\r");
    };

    // An overridden SDK path may not match what `xcrun` defaults to, so the version
    // reported here would be misleading; `warnIfSdkVersionUnchecked` reports this case
    // on its own rather than comparing "unknown" against `checked_sdk_major_range`.
    const sdk_version = if (sdk_override != null)
        "unknown"
    else blk: {
        const output = b.run(&.{ "xcrun", "--show-sdk-version" });
        break :blk std.mem.trim(u8, output, " \n\r");
    };
    warnIfSdkVersionUnchecked(sdk_override != null, sdk_version);

    return .{ .sdk_path = sdk_path, .toolchain_path = toolchain_path, .sdk_version = sdk_version };
}

/// The leading integer of a dotted version string ("15.2" -> 15), or `null` if it does
/// not start with one.
fn majorVersion(version: []const u8) ?u32 {
    const dot = std.mem.indexOfScalar(u8, version, '.') orelse version.len;
    return std.fmt.parseInt(u32, version[0..dot], 10) catch null;
}

/// Printed at most once per process: a `-Dinstall-all=true` build resolves SDK paths
/// many times over, and repeating this warning for each one is noise, not signal.
var warned_about_sdk_version = false;

fn warnIfSdkVersionUnchecked(sdk_overridden: bool, sdk_version: []const u8) void {
    if (warned_about_sdk_version) return;
    if (sdk_overridden) {
        warned_about_sdk_version = true;
        std.debug.print(
            "warning: macOS SDK version could not be checked because the SDK path was " ++
                "overridden. If this build fails with an undefined " ++
                "`__swift_FORCE_LOAD_$_<name>` symbol, add <name> to `optional_libs` in " ++
                "build_helpers/swift.zig.\n",
            .{},
        );
        return;
    }
    const major = majorVersion(sdk_version) orelse {
        warned_about_sdk_version = true;
        std.debug.print(
            "warning: macOS SDK version '{s}' could not be parsed, so it could not be " ++
                "checked against the range this project's Swift runtime autolinking is " ++
                "checked against ({d}-{d}). If this build fails with an undefined " ++
                "`__swift_FORCE_LOAD_$_<name>` symbol, add <name> to `optional_libs` in " ++
                "build_helpers/swift.zig.\n",
            .{ sdk_version, checked_sdk_major_range.min, checked_sdk_major_range.max },
        );
        return;
    };
    if (major >= checked_sdk_major_range.min and major <= checked_sdk_major_range.max) return;
    warned_about_sdk_version = true;
    std.debug.print(
        "warning: macOS SDK {s} is outside the range this project's Swift runtime " ++
            "autolinking is checked against ({d}-{d}). If this build fails with " ++
            "an undefined `__swift_FORCE_LOAD_$_<name>` symbol, add <name> to " ++
            "`optional_libs` in build_helpers/swift.zig.\n",
        .{ sdk_version, checked_sdk_major_range.min, checked_sdk_major_range.max },
    );
}

test "majorVersion parses the leading dotted component" {
    try std.testing.expectEqual(@as(?u32, 15), majorVersion("15.2"));
    try std.testing.expectEqual(@as(?u32, 16), majorVersion("16.99"));
    try std.testing.expectEqual(@as(?u32, 26), majorVersion("26.5"));
    try std.testing.expectEqual(@as(?u32, 14), majorVersion("14.9"));
    try std.testing.expectEqual(@as(?u32, 17), majorVersion("17.0"));
}

test "majorVersion rejects input with no parseable leading integer" {
    try std.testing.expectEqual(@as(?u32, null), majorVersion("unknown"));
    try std.testing.expectEqual(@as(?u32, null), majorVersion(""));
    try std.testing.expectEqual(@as(?u32, null), majorVersion(".5"));
}

test "checked_sdk_major_range boundaries" {
    const min = checked_sdk_major_range.min;
    const max = checked_sdk_major_range.max;
    try std.testing.expect(majorVersion("15.0").? >= min);
    try std.testing.expect(majorVersion("26.5").? <= max);
    try std.testing.expect(majorVersion("14.9").? < min);
    try std.testing.expect(majorVersion("27.0").? > max);
}

/// Link macOS frameworks into the exe.
/// Also adds the SDK framework / library search paths.
///
/// `enable_gamepad`: true only for exes that use gamepad input (GCController/GCExtendedGamepad; ADR-009).
/// Opt-in, symmetric with audio's `link_audio`.
/// When false, GameController is not linked (absent from `otool -L`).
pub fn linkMacOSFrameworks(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    sdk_paths: MacOSSDKPaths,
    enable_gamepad: bool,
) void {
    addMacOSSDKSearchPaths(b, exe, sdk_paths);

    const frameworks = [_][]const u8{
        "Cocoa",
        "QuartzCore",
        // For file-dialog UTType (allowedContentTypes). The objc backend requires an explicit link.
        // swift/metal can resolve via the swiftUniformTypeIdentifiers overlay; link uniformly for consistency.
        "UniformTypeIdentifiers",
    };
    for (frameworks) |framework| {
        exe.root_module.linkFramework(framework, .{});
    }
    if (enable_gamepad) {
        // Gamepad input (GCController/GCExtendedGamepad; ADR-009). Linked only for opt-in exes.
        exe.root_module.linkFramework("GameController", .{});
    }
}

/// Add the SDK framework / library search paths to the exe.
/// Internal to linkMacOSFrameworks(); not part of the public surface.
fn addMacOSSDKSearchPaths(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    sdk_paths: MacOSSDKPaths,
) void {
    const frameworks_path = b.fmt("{s}/System/Library/Frameworks", .{sdk_paths.sdk_path});
    const usr_lib_path = b.fmt("{s}/usr/lib", .{sdk_paths.sdk_path});

    exe.root_module.addSystemFrameworkPath(.{ .cwd_relative = frameworks_path });
    exe.root_module.addLibraryPath(.{ .cwd_relative = usr_lib_path });
}
