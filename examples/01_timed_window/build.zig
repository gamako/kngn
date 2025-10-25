const std = @import("std");

// プラットフォーム層の種類
const PlatformType = enum {
    objc,
    swift,
    metal,
};

// プラットフォーム層のコンパイル結果
const PlatformCompileResult = struct {
    compile_step: *std.Build.Step.Run,
    obj_file: std.Build.LazyPath,
};

// プラットフォーム層をコンパイルして.oファイルを生成
fn compilePlatformLayer(
    b: *std.Build,
    platform_type: PlatformType,
    optimize: std.builtin.OptimizeMode,
) PlatformCompileResult {
    const platform_dir = "../../platform";

    const result = switch (platform_type) {
        .objc => blk: {
            const compile_cmd = b.addSystemCommand(&.{
                "clang",
                "-x",
                "objective-c",
                "-I",
                platform_dir,
                "-fobjc-arc",
                switch (optimize) {
                    .Debug => "-O0",
                    .ReleaseSafe => "-O2",
                    .ReleaseFast => "-O3",
                    .ReleaseSmall => "-Os",
                },
                "-c",
                "-o",
            });
            const obj_path = compile_cmd.addOutputFileArg("platform_macos_objc.o");
            compile_cmd.addArg(b.pathJoin(&.{ platform_dir, "macos/platform_macos.m" }));
            break :blk PlatformCompileResult{ .compile_step = compile_cmd, .obj_file = obj_path };
        },
        .swift => blk: {
            const compile_cmd = b.addSystemCommand(&.{
                "swiftc",
                "-parse-as-library",
                switch (optimize) {
                    .Debug => "-Onone",
                    .ReleaseSafe, .ReleaseFast => "-O",
                    .ReleaseSmall => "-Osize",
                },
                "-disable-autolinking-runtime-compatibility",
                "-disable-autolinking-runtime-compatibility-concurrency",
                "-disable-autolinking-runtime-compatibility-dynamic-replacements",
                "-framework",
                "Cocoa",
                "-framework",
                "QuartzCore",
                "-c",
                "-o",
            });
            const obj_path = compile_cmd.addOutputFileArg("platform_macos_swift.o");
            compile_cmd.addArg(b.pathJoin(&.{ platform_dir, "macos-swift/platform_macos.swift" }));
            break :blk PlatformCompileResult{ .compile_step = compile_cmd, .obj_file = obj_path };
        },
        .metal => blk: {
            const compile_cmd = b.addSystemCommand(&.{
                "swiftc",
                "-parse-as-library",
                switch (optimize) {
                    .Debug => "-Onone",
                    .ReleaseSafe, .ReleaseFast => "-O",
                    .ReleaseSmall => "-Osize",
                },
                "-disable-autolinking-runtime-compatibility",
                "-disable-autolinking-runtime-compatibility-concurrency",
                "-disable-autolinking-runtime-compatibility-dynamic-replacements",
                "-framework",
                "Cocoa",
                "-framework",
                "Metal",
                "-framework",
                "MetalKit",
                "-c",
                "-o",
            });
            const obj_path = compile_cmd.addOutputFileArg("platform_macos_metal.o");
            compile_cmd.addArg(b.pathJoin(&.{ platform_dir, "macos-metal/platform_macos_metal.swift" }));
            break :blk PlatformCompileResult{ .compile_step = compile_cmd, .obj_file = obj_path };
        },
    };

    return result;
}

// Swiftランタイムライブラリをリンク
fn linkSwiftRuntime(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    extra_libs: []const []const u8,
) void {
    const allocator = b.allocator;

    // ツールチェーンパスを取得
    const developer_path = std.mem.trim(u8, b.run(&.{ "xcode-select", "-p" }), " \n\r");
    const toolchain_path = std.fmt.allocPrint(allocator, "{s}/Toolchains/XcodeDefault.xctoolchain", .{developer_path}) catch unreachable;

    // SDKパスを取得
    const sdk_path_output = b.run(&.{ "xcrun", "--show-sdk-path" });
    const sdk_path = std.mem.trim(u8, sdk_path_output, " \n\r");

    // Swiftランタイムライブラリのパスを構築
    const toolchain_swift_lib_path = std.fmt.allocPrint(allocator, "{s}/usr/lib/swift/macosx", .{toolchain_path}) catch unreachable;
    const sdk_swift_lib_path = std.fmt.allocPrint(allocator, "{s}/usr/lib/swift", .{sdk_path}) catch unreachable;

    // パスを追加
    exe.root_module.addLibraryPath(.{ .cwd_relative = toolchain_swift_lib_path });
    exe.root_module.addLibraryPath(.{ .cwd_relative = sdk_swift_lib_path });

    // 必要なSwiftランタイムライブラリ
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

    // Swiftランタイムライブラリをリンク
    for (runtime_libs) |lib| {
        exe.root_module.linkSystemLibrary(lib, .{});
    }

    // 追加ライブラリをリンク
    for (extra_libs) |lib| {
        exe.root_module.linkSystemLibrary(lib, .{});
    }
}

// macOSフレームワークをリンク
fn linkMacOSFrameworks(exe: *std.Build.Step.Compile) void {
    const frameworks = [_][]const u8{
        "Cocoa",
        "QuartzCore",
    };

    for (frameworks) |framework| {
        exe.root_module.linkFramework(framework, .{});
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // プラットフォーム層の選択オプション
    const platform_option = b.option(PlatformType, "platform", "Platform layer to use") orelse .objc;

    // ========================================
    // Objective-C版実行ファイルのビルド
    // ========================================
    const exe_objc = b.addExecutable(.{
        .name = "example_01_timed_window",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const objc_platform = compilePlatformLayer(b, .objc, optimize);
    exe_objc.root_module.addObjectFile(objc_platform.obj_file);
    exe_objc.root_module.link_libc = true;
    exe_objc.root_module.addIncludePath(.{ .cwd_relative = "../../platform" });
    exe_objc.step.dependOn(&objc_platform.compile_step.step);
    linkMacOSFrameworks(exe_objc);

    // ========================================
    // Swift版実行ファイルのビルド
    // ========================================
    const exe_swift = b.addExecutable(.{
        .name = "example_01_timed_window_swift",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const swift_platform = compilePlatformLayer(b, .swift, optimize);
    exe_swift.root_module.addObjectFile(swift_platform.obj_file);
    exe_swift.root_module.link_libc = true;
    exe_swift.root_module.addIncludePath(.{ .cwd_relative = "../../platform" });
    exe_swift.step.dependOn(&swift_platform.compile_step.step);
    linkMacOSFrameworks(exe_swift);
    linkSwiftRuntime(b, exe_swift, &.{});

    // ========================================
    // Metal版実行ファイルのビルド
    // ========================================
    const exe_metal = b.addExecutable(.{
        .name = "example_01_timed_window_metal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const metal_platform = compilePlatformLayer(b, .metal, optimize);
    exe_metal.root_module.addObjectFile(metal_platform.obj_file);
    exe_metal.root_module.link_libc = true;
    exe_metal.root_module.addIncludePath(.{ .cwd_relative = "../../platform" });
    exe_metal.step.dependOn(&metal_platform.compile_step.step);
    linkMacOSFrameworks(exe_metal);
    exe_metal.root_module.linkFramework("Metal", .{});
    exe_metal.root_module.linkFramework("MetalKit", .{});
    linkSwiftRuntime(b, exe_metal, &.{
        "swiftMetalKit",
        "swiftModelIO",
    });

    // ========================================
    // インストールステップの設定
    // ========================================
    switch (platform_option) {
        .objc => b.installArtifact(exe_objc),
        .swift => b.installArtifact(exe_swift),
        .metal => b.installArtifact(exe_metal),
    }

    // ========================================
    // 実行ステップの設定
    // ========================================
    const run_step = b.step("run", "Run the example (uses -Dplatform option)");
    const exe_to_run = switch (platform_option) {
        .objc => exe_objc,
        .swift => exe_swift,
        .metal => exe_metal,
    };
    const run_cmd = b.addRunArtifact(exe_to_run);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    // 個別実行ステップ
    const run_objc_step = b.step("run-objc", "Run the ObjC version");
    const run_objc_cmd = b.addRunArtifact(exe_objc);
    run_objc_step.dependOn(&run_objc_cmd.step);
    run_objc_cmd.step.dependOn(b.getInstallStep());

    const run_swift_step = b.step("run-swift", "Run the Swift version");
    const run_swift_cmd = b.addRunArtifact(exe_swift);
    run_swift_step.dependOn(&run_swift_cmd.step);
    run_swift_cmd.step.dependOn(b.getInstallStep());

    const run_metal_step = b.step("run-metal", "Run the Metal version");
    const run_metal_cmd = b.addRunArtifact(exe_metal);
    run_metal_step.dependOn(&run_metal_cmd.step);
    run_metal_cmd.step.dependOn(b.getInstallStep());
}
