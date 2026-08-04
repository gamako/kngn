// External projects vendor this helper from kngn/build_helpers/.
// The kngn/build_helpers/ file is authoritative; keep all copies byte-identical.
//! Swift runtime link helper

const std = @import("std");
const macos = @import("macos.zig");

/// Link the Swift runtime libraries into the exe.
///
/// - core runtime (always linked)
/// - optional libraries (linked only when a `.tbd` for them exists under the SDK or
///   toolchain Swift library path; kept within the SDK major version range declared by
///   `macos.checked_sdk_major_range`)
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

    // A Command Line Tools-only toolchain has no nested
    // `Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx`; passing a `-L` for a
    // directory that does not exist earns a linker warning zig reports as a build
    // failure even though linking still succeeds, so only add a path that is there.
    if (pathExists(b, toolchain_swift_lib_path)) {
        exe.root_module.addLibraryPath(.{ .cwd_relative = toolchain_swift_lib_path });
    }
    if (pathExists(b, sdk_swift_lib_path)) {
        exe.root_module.addLibraryPath(.{ .cwd_relative = sdk_swift_lib_path });
    }

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

    // Optional Swift runtime libraries. These are overlay modules some SDK within
    // `macos.checked_sdk_major_range` force-loads and others do not, so each is linked
    // only when present.
    const optional_libs = [_][]const u8{
        "swiftSpatial",
        "swiftDarwin",
        "swift_errno",
        "swift_math",
        "swift_signal",
        "swift_stdio",
        "swift_time",
        "swiftsys_time",
        "swiftunistd",
    };
    for (optional_libs) |lib| {
        if (swiftRuntimeLibExists(b, sdk_paths, lib)) {
            exe.root_module.linkSystemLibrary(lib, .{});
        }
    }

    for (extra_libs) |lib| {
        exe.root_module.linkSystemLibrary(lib, .{});
    }
}

/// Check whether lib<name>.tbd exists under the toolchain's or the SDK's usr/lib/swift/
/// (the same two directories `linkSwiftRuntime` adds as library search paths).
fn swiftRuntimeLibExists(b: *std.Build, sdk_paths: macos.MacOSSDKPaths, lib_name: []const u8) bool {
    return pathExists(b, b.fmt("{s}/usr/lib/swift/macosx/lib{s}.tbd", .{ sdk_paths.toolchain_path, lib_name })) or
        pathExists(b, b.fmt("{s}/usr/lib/swift/lib{s}.tbd", .{ sdk_paths.sdk_path, lib_name }));
}

fn pathExists(b: *std.Build, path: []const u8) bool {
    var exit_code: u8 = 0;
    const stdout = b.runAllowFail(&.{ "test", "-e", path }, &exit_code, .ignore) catch return false;
    b.allocator.free(stdout);
    return exit_code == 0;
}
