//! Swift ランタイムリンクヘルパー

const std = @import("std");
const macos = @import("macos.zig");

/// Swift ランタイムライブラリ群を exe にリンクする。
///
/// - コアランタイム（必ずリンク）
/// - optional ライブラリ（SDK に存在する場合のみリンク）
/// - extra_libs（呼び出し側が指定した追加ライブラリ）
pub fn linkSwiftRuntime(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    sdk_paths: macos.MacOSSDKPaths,
    extra_libs: []const []const u8,
) void {
    const allocator = b.allocator;

    const toolchain_swift_lib_path = std.fmt.allocPrint(
        allocator,
        "{s}/usr/lib/swift/macosx",
        .{sdk_paths.toolchain_path},
    ) catch unreachable;
    const sdk_swift_lib_path = std.fmt.allocPrint(
        allocator,
        "{s}/usr/lib/swift",
        .{sdk_paths.sdk_path},
    ) catch unreachable;

    exe.root_module.addLibraryPath(.{ .cwd_relative = toolchain_swift_lib_path });
    exe.root_module.addLibraryPath(.{ .cwd_relative = sdk_swift_lib_path });

    const runtime_libs = [_][]const u8{
        "swiftCore",
        "swiftCoreFoundation",
        "swiftDispatch",
        "swiftObjectiveC",
        "swiftQuartzCore",
        "swiftCoreImage",
        "swiftIOKit",
        "swiftMetal",
        "swiftOSLog",
        "swiftUniformTypeIdentifiers",
        "swiftXPC",
        "swift_Builtin_float",
        "swiftos",
        "swiftsimd",
    };
    for (runtime_libs) |lib| {
        exe.root_module.linkSystemLibrary(lib, .{});
    }

    // SDK に存在する場合のみリンクする optional な Swift ランタイム
    // (新しい macOS SDK では swiftc が暗黙的にこれらへの FORCE_LOAD を生成する)
    const optional_libs = [_][]const u8{
        "swiftSpatial",
    };
    for (optional_libs) |lib| {
        if (swiftRuntimeLibExists(b, sdk_paths.sdk_path, lib)) {
            exe.root_module.linkSystemLibrary(lib, .{});
        }
    }

    for (extra_libs) |lib| {
        exe.root_module.linkSystemLibrary(lib, .{});
    }
}

/// SDK の usr/lib/swift/ 配下に lib<name>.tbd が存在するかを確認する。
fn swiftRuntimeLibExists(b: *std.Build, sdk_path: []const u8, lib_name: []const u8) bool {
    const tbd_path = b.fmt("{s}/usr/lib/swift/lib{s}.tbd", .{ sdk_path, lib_name });
    var exit_code: u8 = 0;
    const stdout = b.runAllowFail(&.{ "test", "-e", tbd_path }, &exit_code, .ignore) catch return false;
    b.allocator.free(stdout);
    return exit_code == 0;
}
