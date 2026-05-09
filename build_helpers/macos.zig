//! macOS SDK / Toolchain パスの解決とフレームワークリンクヘルパー
//!
//! nix の zig 0.16 は macOS SDK を自動検出しないため、
//! xcode-select / xcrun で解決したパスを exe に明示的に渡す。

const std = @import("std");

pub const MacOSSDKPaths = struct {
    sdk_path: []const u8,
    toolchain_path: []const u8,
};

/// macOS SDK / Toolchain のパスを解決する。
/// オーバーライドが渡された場合はそれを使い、なければ xcode-select / xcrun で取得する。
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

/// macOS フレームワークを exe にリンクする。
/// 内部で SDK の framework / library 検索パスも追加する。
pub fn linkMacOSFrameworks(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    sdk_paths: MacOSSDKPaths,
) void {
    addMacOSSDKSearchPaths(b, exe, sdk_paths);

    const frameworks = [_][]const u8{
        "Cocoa",
        "QuartzCore",
    };
    for (frameworks) |framework| {
        exe.root_module.linkFramework(framework, .{});
    }
}

/// SDK の framework / library 検索パスを exe に追加する。
/// linkMacOSFrameworks() の内部実装で、外部公開はしない。
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
