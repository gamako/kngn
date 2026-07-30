// External projects vendor this helper from kngn/build_helpers/.
// The kngn/build_helpers/ file is authoritative; keep all copies byte-identical.
//! Swift runtime link helper

const std = @import("std");
const macos = @import("macos.zig");

/// Link the Swift runtime libraries into the exe.
///
/// - core runtime (always linked)
/// - optional libraries (linked only when present in the SDK)
/// - extra_libs (additional libraries requested by the caller)
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

    // Optional Swift runtime libraries, linked only when present in the SDK
    // (on newer macOS SDKs swiftc implicitly emits FORCE_LOAD for these)
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

/// Check whether lib<name>.tbd exists under the SDK's usr/lib/swift/.
fn swiftRuntimeLibExists(b: *std.Build, sdk_path: []const u8, lib_name: []const u8) bool {
    const tbd_path = b.fmt("{s}/usr/lib/swift/lib{s}.tbd", .{ sdk_path, lib_name });
    var exit_code: u8 = 0;
    const stdout = b.runAllowFail(&.{ "test", "-e", tbd_path }, &exit_code, .ignore) catch return false;
    b.allocator.free(stdout);
    return exit_code == 0;
}
