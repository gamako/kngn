//! プラットフォーム層（ObjC / Swift / Metal）のコンパイルヘルパー
//!
//! 親 build.zig と examples/*/build.zig から共通利用される。
//! 入力ファイルは LazyPath で受け取り、ビルドグラフに依存を載せる。

const std = @import("std");
const macos = @import("macos.zig");
const swift = @import("swift.zig");

pub const PlatformType = enum {
    objc,
    swift,
    metal,
};

/// platform モジュール (`src/platform.zig`) を作成する。
///
/// `@cImport` で `platform.h` を取り込むため、`link_libc = true` と
/// platform/ include path 追加をワンセットで行う。
///
/// path の解決方法 (`b.path` / `cwd_relative`) は callsite に委ねる。
/// 親 build.zig からは `b.path(...)`、standalone からは
/// `.{ .cwd_relative = PROJECT_ROOT ++ ... }` を渡すこと。
pub fn createPlatformModule(
    b: *std.Build,
    platform_source: std.Build.LazyPath,
    platform_include_root: std.Build.LazyPath,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = platform_source,
        .link_libc = true,
    });
    mod.addIncludePath(platform_include_root);
    return mod;
}

/// 実行ファイルにプラットフォーム層をセットアップする。
///
/// プラットフォーム層 (.o) のコンパイル、framework / Swift ランタイムリンク、
/// include path 設定までを一括で行う。各 example の build.zig からは
/// この関数 1 つを呼ぶだけで platform 関連のセットアップが完了する。
pub fn setupExecutableForPlatform(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    platform_type: PlatformType,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    sdk_paths: macos.MacOSSDKPaths,
) void {
    const compiled = compilePlatformLayer(b, platform_type, optimize, platform_root);
    exe.root_module.addObjectFile(compiled.obj_file);
    exe.root_module.link_libc = true;
    exe.root_module.addIncludePath(platform_root);
    exe.step.dependOn(&compiled.compile_step.step);

    macos.linkMacOSFrameworks(b, exe, sdk_paths);

    switch (platform_type) {
        .objc => {},
        .swift => swift.linkSwiftRuntime(b, exe, sdk_paths, &.{}),
        .metal => {
            exe.root_module.linkFramework("Metal", .{});
            exe.root_module.linkFramework("MetalKit", .{});
            swift.linkSwiftRuntime(b, exe, sdk_paths, &.{
                "swiftMetalKit",
                "swiftModelIO",
            });
        },
    }
}

pub const PlatformCompileResult = struct {
    compile_step: *std.Build.Step.Run,
    obj_file: std.Build.LazyPath,
};

/// プラットフォーム層を `.o` にコンパイルする。
///
/// `platform_root` は `platform/` ディレクトリへの LazyPath。
/// 親プロジェクトからは `b.path("platform")`、examples からは
/// `b.path("../../platform")` を渡す。
pub fn compilePlatformLayer(
    b: *std.Build,
    platform_type: PlatformType,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
) PlatformCompileResult {
    return switch (platform_type) {
        .objc => buildObjC(b, optimize, platform_root),
        .swift => buildSwift(b, optimize, platform_root),
        .metal => buildMetal(b, optimize, platform_root),
    };
}

fn buildObjC(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
) PlatformCompileResult {
    const compile_cmd = b.addSystemCommand(&.{
        "clang",
        "-x",
        "objective-c",
    });
    compile_cmd.addPrefixedDirectoryArg("-I", platform_root);
    compile_cmd.addArgs(&.{
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
    compile_cmd.addFileArg(platform_root.path(b, "macos/platform_macos.m"));
    return .{ .compile_step = compile_cmd, .obj_file = obj_path };
}

fn buildSwift(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
) PlatformCompileResult {
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
        "-import-objc-header",
    });
    compile_cmd.addFileArg(platform_root.path(b, "platform.h"));
    compile_cmd.addArgs(&.{ "-c", "-o" });
    const obj_path = compile_cmd.addOutputFileArg("platform_macos_swift.o");
    compile_cmd.addFileArg(platform_root.path(b, "macos-swift/platform_macos.swift"));
    return .{ .compile_step = compile_cmd, .obj_file = obj_path };
}

fn buildMetal(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
) PlatformCompileResult {
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
        "-import-objc-header",
    });
    compile_cmd.addFileArg(platform_root.path(b, "platform.h"));
    compile_cmd.addArgs(&.{ "-c", "-o" });
    const obj_path = compile_cmd.addOutputFileArg("platform_macos_metal.o");
    compile_cmd.addFileArg(platform_root.path(b, "macos-metal/platform_macos_metal.swift"));
    return .{ .compile_step = compile_cmd, .obj_file = obj_path };
}
