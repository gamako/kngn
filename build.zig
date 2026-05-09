const std = @import("std");

// ========================================
// ビルド設定定数
// ========================================
const APP_NAME = "video_proto";

// プラットフォーム層の種類
const PlatformType = enum {
    objc,
    swift,
    metal,
};

// ========================================
// 型定義
// ========================================

/// プラットフォーム層のコンパイル結果
const PlatformCompileResult = struct {
    compile_step: *std.Build.Step.Run,
    obj_file: std.Build.LazyPath,
};

// ========================================
// ヘルパー関数
// ========================================

/// プラットフォーム層をコンパイルして.oファイルを生成
fn compilePlatformLayer(
    b: *std.Build,
    platform_type: PlatformType,
    optimize: std.builtin.OptimizeMode,
) PlatformCompileResult {
    const result = switch (platform_type) {
        .objc => blk: {
            const compile_cmd = b.addSystemCommand(&.{
                "clang",
                "-x", "objective-c",
                "-I", "platform",
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
            compile_cmd.addFileArg(b.path("platform/macos/platform_macos.m"));
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
                "-framework", "Cocoa",
                "-framework", "QuartzCore",
                "-c",
                "-o",
            });
            const obj_path = compile_cmd.addOutputFileArg("platform_macos_swift.o");
            compile_cmd.addFileArg(b.path("platform/macos-swift/platform_macos.swift"));
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
                "-framework", "Cocoa",
                "-framework", "Metal",
                "-framework", "MetalKit",
                "-c",
                "-o",
            });
            const obj_path = compile_cmd.addOutputFileArg("platform_macos_metal.o");
            compile_cmd.addFileArg(b.path("platform/macos-metal/platform_macos_metal.swift"));
            break :blk PlatformCompileResult{ .compile_step = compile_cmd, .obj_file = obj_path };
        },
    };

    return result;
}

/// macOS SDK パスを保持する構造体
const MacOSSDKPaths = struct {
    sdk_path: []const u8,
    toolchain_path: []const u8,
};

/// macOS SDK / Toolchain のパスを取得
fn resolveMacOSSDKPaths(
    b: *std.Build,
    toolchain_override: ?[]const u8,
    sdk_override: ?[]const u8,
) MacOSSDKPaths {
    const allocator = b.allocator;

    const toolchain_path = if (toolchain_override) |path|
        path
    else blk: {
        const developer_path = std.mem.trim(u8, b.run(&.{ "xcode-select", "-p" }), " \n\r");
        break :blk std.fmt.allocPrint(allocator, "{s}/Toolchains/XcodeDefault.xctoolchain", .{developer_path}) catch unreachable;
    };

    const sdk_path = if (sdk_override) |path|
        path
    else blk: {
        const output = b.run(&.{ "xcrun", "--show-sdk-path" });
        break :blk std.mem.trim(u8, output, " \n\r");
    };

    return .{ .sdk_path = sdk_path, .toolchain_path = toolchain_path };
}

/// macOS SDK の framework / library 検索パスを exe に追加
/// nix の zig 0.16 は SDK を自動検出しないため、明示的に渡す必要がある
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

/// Swiftランタイムライブラリをリンク
fn linkSwiftRuntime(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    sdk_paths: MacOSSDKPaths,
    extra_libs: []const []const u8,
) void {
    const allocator = b.allocator;

    // Swiftランタイムライブラリのパスを構築
    const toolchain_swift_lib_path = std.fmt.allocPrint(allocator, "{s}/usr/lib/swift/macosx", .{sdk_paths.toolchain_path}) catch unreachable;
    const sdk_swift_lib_path = std.fmt.allocPrint(allocator, "{s}/usr/lib/swift", .{sdk_paths.sdk_path}) catch unreachable;

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

    // 追加ライブラリをリンク
    for (extra_libs) |lib| {
        exe.root_module.linkSystemLibrary(lib, .{});
    }
}

/// SDK の usr/lib/swift/ 配下に lib<name>.tbd が存在するかを確認
fn swiftRuntimeLibExists(b: *std.Build, sdk_path: []const u8, lib_name: []const u8) bool {
    const tbd_path = b.fmt("{s}/usr/lib/swift/lib{s}.tbd", .{ sdk_path, lib_name });
    var exit_code: u8 = 0;
    const stdout = b.runAllowFail(&.{ "test", "-e", tbd_path }, &exit_code, .ignore) catch return false;
    b.allocator.free(stdout);
    return exit_code == 0;
}

/// macOSフレームワークをリンク
/// SDK 検索パスを明示的に追加してから framework をリンクする
fn linkMacOSFrameworks(
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

// この関数は命令形に見えますが、ビルドを直接実行せず、代わりに
// 外部ランナーによって実行されるビルドグラフ(`b`)を変更します。
// `std.Build`の関数はビルドステップを定義するDSLを実装し、
// ステップ間の依存関係を表現することで、ビルドランナーが
// ビルドを自動的に並列化でき、キャッシュシステムが
// ステップを再実行する必要があるかどうかを知ることができます。
pub fn build(b: *std.Build) void {
    // ========================================
    // ビルドオプション
    // ========================================
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // プラットフォーム層の選択オプション
    const platform_option = b.option(PlatformType, "platform", "Platform layer to use") orelse .objc;

    // Swiftツールチェーンパスオプション（指定されない場合は自動検出）
    const swift_toolchain_path = b.option(
        []const u8,
        "swift-toolchain-path",
        "Path to Swift toolchain (e.g., /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain)",
    );

    // Swift SDKパスオプション（指定されない場合は自動検出）
    const swift_sdk_path = b.option(
        []const u8,
        "swift-sdk-path",
        "Path to macOS SDK (e.g., /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk)",
    );

    // macOS SDK パスを一度だけ解決
    const sdk_paths = resolveMacOSSDKPaths(b, swift_toolchain_path, swift_sdk_path);

    // ========================================
    // Objective-C版実行ファイルのビルド
    // ========================================
    const exe_objc = b.addExecutable(.{
        .name = APP_NAME,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Objective-C版プラットフォーム層をコンパイル
    const objc_platform = compilePlatformLayer(b, .objc, optimize);
    exe_objc.root_module.addObjectFile(objc_platform.obj_file);
    exe_objc.root_module.link_libc = true;
    exe_objc.root_module.addIncludePath(b.path("platform"));
    exe_objc.step.dependOn(&objc_platform.compile_step.step);

    // macOSフレームワークをリンク
    linkMacOSFrameworks(b, exe_objc, sdk_paths);

    // ========================================
    // Swift版実行ファイルのビルド
    // ========================================
    const exe_swift = b.addExecutable(.{
        .name = APP_NAME ++ "_swift",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Swift版プラットフォーム層をコンパイル
    const swift_platform = compilePlatformLayer(b, .swift, optimize);
    exe_swift.root_module.addObjectFile(swift_platform.obj_file);
    exe_swift.root_module.link_libc = true;
    exe_swift.root_module.addIncludePath(b.path("platform"));
    exe_swift.step.dependOn(&swift_platform.compile_step.step);

    // macOSフレームワークとSwiftランタイムをリンク
    linkMacOSFrameworks(b, exe_swift, sdk_paths);
    linkSwiftRuntime(b, exe_swift, sdk_paths, &.{});

    // ========================================
    // Metal版実行ファイルのビルド
    // ========================================
    const exe_metal = b.addExecutable(.{
        .name = APP_NAME ++ "_metal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Metal版プラットフォーム層をコンパイル
    const metal_platform = compilePlatformLayer(b, .metal, optimize);
    exe_metal.root_module.addObjectFile(metal_platform.obj_file);
    exe_metal.root_module.link_libc = true;
    exe_metal.root_module.addIncludePath(b.path("platform"));
    exe_metal.step.dependOn(&metal_platform.compile_step.step);

    // macOSフレームワークとSwiftランタイムをリンク
    linkMacOSFrameworks(b, exe_metal, sdk_paths);
    exe_metal.root_module.linkFramework("Metal", .{});
    exe_metal.root_module.linkFramework("MetalKit", .{});
    linkSwiftRuntime(b, exe_metal, sdk_paths, &.{
        "swiftMetalKit",
        "swiftModelIO",
    });

    // ========================================
    // インストールステップの設定
    // ========================================
    // プラットフォームオプションに応じてデフォルトでインストールする実行ファイルを選択
    switch (platform_option) {
        .objc => b.installArtifact(exe_objc),
        .swift => b.installArtifact(exe_swift),
        .metal => b.installArtifact(exe_metal),
    }

    // 複数バージョンをインストールするオプション
    if (b.option(bool, "install-all", "Install all platform versions") orelse false) {
        b.installArtifact(exe_objc);
        b.installArtifact(exe_swift);
        b.installArtifact(exe_metal);
    }

    // ========================================
    // 実行ステップの設定
    // ========================================
    // デフォルトの`run`コマンド（プラットフォームオプションに従う）
    const run_step = b.step("run", "Run the app (uses -Dplatform option)");
    const exe_to_run = switch (platform_option) {
        .objc => exe_objc,
        .swift => exe_swift,
        .metal => exe_metal,
    };
    const run_cmd = b.addRunArtifact(exe_to_run);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    // Objective-C版を明示的に実行
    const run_objc_step = b.step("run-objc", "Run the ObjC version");
    const run_objc_cmd = b.addRunArtifact(exe_objc);
    run_objc_step.dependOn(&run_objc_cmd.step);
    run_objc_cmd.step.dependOn(b.getInstallStep());

    // Swift版を明示的に実行
    const run_swift_step = b.step("run-swift", "Run the Swift version");
    const run_swift_cmd = b.addRunArtifact(exe_swift);
    run_swift_step.dependOn(&run_swift_cmd.step);
    run_swift_cmd.step.dependOn(b.getInstallStep());

    // Metal版を明示的に実行
    const run_metal_step = b.step("run-metal", "Run the Metal version");
    const run_metal_cmd = b.addRunArtifact(exe_metal);
    run_metal_step.dependOn(&run_metal_cmd.step);
    run_metal_cmd.step.dependOn(b.getInstallStep());

    // コマンドライン引数をサポート
    if (b.args) |args| {
        run_cmd.addArgs(args);
        run_objc_cmd.addArgs(args);
        run_swift_cmd.addArgs(args);
        run_metal_cmd.addArgs(args);
    }

    // ========================================
    // PNGデコーダー format.zig テストの設定
    // ========================================
    const png_format_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("libs/png-decoder/src/format.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_png_format_test = b.addRunArtifact(png_format_test);
    const test_png_format_step = b.step("test-png-format", "Run PNG format conversion tests");
    test_png_format_step.dependOn(&run_png_format_test.step);

    // ========================================
    // サンプルプログラム用のビルド設定
    // ========================================

    // キーボード入力モジュール
    const keyboard_module = b.createModule(.{
        .root_source_file = b.path("src/keyboard.zig"),
    });

    // PNG decoderモジュール
    const png_decoder_module = b.createModule(.{
        .root_source_file = b.path("libs/png-decoder/src/lib.zig"),
    });

    // スプライトモジュール
    const sprite_module = b.createModule(.{
        .root_source_file = b.path("src/sprite.zig"),
    });
    sprite_module.addImport("png-decoder", png_decoder_module);

    // 固定タイムステップモジュール
    const fixed_timestep_module = b.createModule(.{
        .root_source_file = b.path("src/fixed_timestep.zig"),
    });

    // FPSカウンターモジュール
    const fps_counter_module = b.createModule(.{
        .root_source_file = b.path("src/fps_counter.zig"),
    });

    // サンプルプログラムをビルド・実行するヘルパー関数
    inline for (.{
        .{ .name = "example_01", .path = "examples/01_timed_window/main.zig" },
        .{ .name = "example_02", .path = "examples/02_keyboard_input/main.zig" },
        .{ .name = "example_03", .path = "examples/03_sprite_rendering/main.zig" },
        .{ .name = "example_04", .path = "examples/04_fixed_timestep/main.zig" },
    }) |example| {
        // サンプル用Objective-C版
        const example_exe_objc = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.path),
                .target = target,
                .optimize = optimize,
            }),
        });

        // キーボードモジュールを追加
        example_exe_objc.root_module.addImport("keyboard", keyboard_module);

        // example_03の場合はspriteモジュールも追加
        if (std.mem.eql(u8, example.name, "example_03")) {
            example_exe_objc.root_module.addImport("sprite", sprite_module);
        }

        // example_04の場合はfixed_timestepとfps_counterモジュールも追加
        if (std.mem.eql(u8, example.name, "example_04")) {
            example_exe_objc.root_module.addImport("fixed_timestep", fixed_timestep_module);
            example_exe_objc.root_module.addImport("fps_counter", fps_counter_module);
        }

        const example_objc_platform = compilePlatformLayer(b, .objc, optimize);
        example_exe_objc.root_module.addObjectFile(example_objc_platform.obj_file);
        example_exe_objc.root_module.link_libc = true;
        example_exe_objc.root_module.addIncludePath(b.path("platform"));
        example_exe_objc.step.dependOn(&example_objc_platform.compile_step.step);
        linkMacOSFrameworks(b, example_exe_objc, sdk_paths);

        // サンプル用Swift版
        const example_exe_swift = b.addExecutable(.{
            .name = example.name ++ "_swift",
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.path),
                .target = target,
                .optimize = optimize,
            }),
        });

        // キーボードモジュールを追加
        example_exe_swift.root_module.addImport("keyboard", keyboard_module);

        // example_03の場合はspriteモジュールも追加
        if (std.mem.eql(u8, example.name, "example_03")) {
            example_exe_swift.root_module.addImport("sprite", sprite_module);
        }

        // example_04の場合はfixed_timestepとfps_counterモジュールも追加
        if (std.mem.eql(u8, example.name, "example_04")) {
            example_exe_swift.root_module.addImport("fixed_timestep", fixed_timestep_module);
            example_exe_swift.root_module.addImport("fps_counter", fps_counter_module);
        }

        const example_swift_platform = compilePlatformLayer(b, .swift, optimize);
        example_exe_swift.root_module.addObjectFile(example_swift_platform.obj_file);
        example_exe_swift.root_module.link_libc = true;
        example_exe_swift.root_module.addIncludePath(b.path("platform"));
        example_exe_swift.step.dependOn(&example_swift_platform.compile_step.step);
        linkMacOSFrameworks(b, example_exe_swift, sdk_paths);
        linkSwiftRuntime(b, example_exe_swift, sdk_paths, &.{});

        // サンプル用Metal版
        const example_exe_metal = b.addExecutable(.{
            .name = example.name ++ "_metal",
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.path),
                .target = target,
                .optimize = optimize,
            }),
        });

        // キーボードモジュールを追加
        example_exe_metal.root_module.addImport("keyboard", keyboard_module);

        // example_03の場合はspriteモジュールも追加
        if (std.mem.eql(u8, example.name, "example_03")) {
            example_exe_metal.root_module.addImport("sprite", sprite_module);
        }

        // example_04の場合はfixed_timestepとfps_counterモジュールも追加
        if (std.mem.eql(u8, example.name, "example_04")) {
            example_exe_metal.root_module.addImport("fixed_timestep", fixed_timestep_module);
            example_exe_metal.root_module.addImport("fps_counter", fps_counter_module);
        }

        const example_metal_platform = compilePlatformLayer(b, .metal, optimize);
        example_exe_metal.root_module.addObjectFile(example_metal_platform.obj_file);
        example_exe_metal.root_module.link_libc = true;
        example_exe_metal.root_module.addIncludePath(b.path("platform"));
        example_exe_metal.step.dependOn(&example_metal_platform.compile_step.step);
        linkMacOSFrameworks(b, example_exe_metal, sdk_paths);
        example_exe_metal.root_module.linkFramework("Metal", .{});
        example_exe_metal.root_module.linkFramework("MetalKit", .{});
        linkSwiftRuntime(b, example_exe_metal, sdk_paths, &.{
            "swiftMetalKit",
            "swiftModelIO",
        });

        // インストール
        b.installArtifact(example_exe_objc);
        b.installArtifact(example_exe_swift);
        b.installArtifact(example_exe_metal);

        // 実行ステップ
        const example_run_step = b.step(
            b.fmt("run-{s}", .{example.name}),
            b.fmt("Run {s} example (uses -Dplatform option)", .{example.name}),
        );

        const example_exe_to_run = switch (platform_option) {
            .objc => example_exe_objc,
            .swift => example_exe_swift,
            .metal => example_exe_metal,
        };

        const example_run_cmd = b.addRunArtifact(example_exe_to_run);
        example_run_step.dependOn(&example_run_cmd.step);
        example_run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            example_run_cmd.addArgs(args);
        }
    }

    // フラグと同じように、トップレベルステップも`--help`メニューに表示されます。
    //
    // Zigビルドシステムはユーザーランドに完全に実装されています。
    // つまり、プライベートコンパイラAPIにフックできません。
    // ビルドシステムによってオーケストレーションされたすべてのコンパイルワークは、
    // 定義された正しいフラグを使用して、他のZigコンパイラサブコマンドを
    // 呼び出します。失敗したとき(またはフラグを渡して冗長性を増すとき)に
    // これらの呼び出しを観察して、仮定を検証し、問題を診断できます。
    //
    // 最後に、Zigビルドシステムは比較的シンプルで自己完結しており、
    // そのソースコードを読むことで、それをマスターできます。
}
