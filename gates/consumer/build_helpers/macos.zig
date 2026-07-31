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
};

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

    return .{ .sdk_path = sdk_path, .toolchain_path = toolchain_path };
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
