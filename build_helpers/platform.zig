//! プラットフォーム層（ObjC / Swift / Metal）のコンパイルヘルパー
//!
//! 親 build.zig と examples/*/build.zig から共通利用される。
//! 入力ファイルは LazyPath で受け取り、ビルドグラフに依存を載せる。

const std = @import("std");
const macos = @import("macos.zig");
const swift = @import("swift.zig");

pub const PlatformType = enum {
    // macOS backends（C ABI platform.h 経由。Zig 側 facade/backend は共通で .o リンクだけ異なる）
    objc,
    swift,
    metal,
    // Linux backends（純 Zig。x11 は TASK-28.2〜、wayland は TASK-28.5）
    x11,
    wayland,
    // Windows backend（純 Zig。Win32 + GDI。TASK-31）
    windows,
};

/// 当該 OS のデフォルト backend（`-Dplatform` 省略時に使う）。
pub fn defaultBackend(os: std.Target.Os.Tag) PlatformType {
    return switch (os) {
        .macos => .objc,
        .linux => .x11,
        .windows => .windows,
        else => .objc, // 実際には build.zig 側の OS チェックで到達しない
    };
}

/// 当該 OS で **このタスク時点で実装済み** の backend 一覧。
/// （`install-all` や全 backend ビルドの対象。Linux は x11 / wayland の両方を常時ビルドして
/// 回帰を検出するが、default は x11。wayland は TASK-28.5 で追加）
pub fn implementedBackends(os: std.Target.Os.Tag) []const PlatformType {
    return switch (os) {
        .macos => &.{ .objc, .swift, .metal },
        .linux => &.{ .x11, .wayland },
        .windows => &.{.windows},
        else => &.{},
    };
}

/// L1 オーディオ出力 backend が当該 OS で実装済みか（macOS=AudioToolbox / Linux=ALSA）。
/// Windows(WASAPI) は TASK-31.1（別ブランチ windows-audio）。top-level build.zig と standalone の両方で
/// audio 必須ターゲット（synth / example_15）の gate に使う（判定を 1 箇所に集約する）。
pub fn audioSupported(os: std.Target.Os.Tag) bool {
    return os == .macos or os == .linux;
}

/// `-Dplatform` で指定された backend が対象 OS に対して妥当か検証する。
/// 不整合（macOS backend を Linux で等）は build エラーにする。
/// （panic のスタックトレースを避け、1 行の明確なメッセージで停止する）
pub fn assertBackendForOs(backend: PlatformType, os: std.Target.Os.Tag) void {
    for (implementedBackends(os)) |b| {
        if (b == backend) return;
    }
    const valid = switch (os) {
        .macos => "objc / swift / metal",
        .linux => "x11 / wayland",
        .windows => "windows",
        else => "(なし)",
    };
    std.log.err(
        "-Dplatform={s} は OS={s} では使えません。有効値: {s}",
        .{ @tagName(backend), @tagName(os), valid },
    );
    std.process.exit(1);
}

/// exe / run-step 名のための backend サフィックス。
pub fn backendName(backend: PlatformType) []const u8 {
    return @tagName(backend);
}

/// platform モジュール (`src/platform.zig`) を作成する。
///
/// macOS backend は `@cImport` で `platform.h` を取り込むため、`link_libc = true` と
/// platform/ include path 追加をワンセットで行う（Linux backend は platform.h を
/// 取り込まないので include path は無害な dead path となるだけ）。
///
/// `backend` は `build_options.platform_backend`（"x11"/"wayland"/"objc"…）として
/// platform module に渡され、`src/platform_linux.zig` 等が x11/wayland を選ぶのに使う。
/// backend ごとに別値の module を持たせるため、本関数は backend ごとに呼ぶこと。
///
/// path の解決方法 (`b.path` / `cwd_relative`) は callsite に委ねる。
/// 親 build.zig からは `b.path(...)`、standalone からは
/// `.{ .cwd_relative = PROJECT_ROOT ++ ... }` を渡すこと。
pub fn createPlatformModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    platform_source: std.Build.LazyPath,
    platform_include_root: std.Build.LazyPath,
    backend: PlatformType,
) *std.Build.Module {
    // linkSystemLibrary は target 既知の module を要求するため、明示的に target を設定する
    // （import module は通常 importer から target を継承するが、x11 のリンク呼び出しには事前に必要）。
    const mod = b.createModule(.{
        .root_source_file = platform_source,
        .target = target,
        .link_libc = true,
    });
    mod.addIncludePath(platform_include_root);

    const opts = b.addOptions();
    opts.addOption([]const u8, "platform_backend", backendName(backend));
    mod.addOptions("build_options", opts);

    // Linux x11 backend は platform_linux_x11.zig が @cImport(<X11/Xlib.h>) / <X11/extensions/XShm.h> する。
    // platform module に X11/Xext を linkSystemLibrary することで、(a) @cImport のヘッダ解決
    // （pkg-config の Cflags 経由）と (b) exe への lib リンク伝播 を両方行う。
    if (backend == .x11) {
        mod.linkSystemLibrary("X11", .{});
        mod.linkSystemLibrary("Xext", .{});
    } else if (backend == .wayland) {
        // Wayland backend は platform_linux_wayland.zig が
        // @cImport(<wayland-client.h>, <xkbcommon/xkbcommon.h>, "xdg-shell-client-protocol.h") する。
        // wayland-client/xkbcommon の link で (a) @cImport ヘッダ解決（pkg-config Cflags）と
        // (b) exe への lib リンク伝播 を行う。xdg-shell-client-protocol.h は wayland-scanner 生成物
        // なので、生成 header の dir を include path に追加する。
        mod.linkSystemLibrary("wayland-client", .{});
        mod.linkSystemLibrary("xkbcommon", .{});
        mod.addIncludePath(generateXdgShellClientHeaderDir(b));
    }

    return mod;
}

// ============================================================================
// xdg-shell protocol glue（TASK-28.5.1）
//
// Wayland の window 管理は xdg-shell プロトコルで行う。手書きせず標準経路の `wayland-scanner`
// で client-header(.h) と private-code(.c) を build 時生成する。`xdg-shell.xml` は
// `pkg-config --variable=pkgdatadir wayland-protocols` から引く（shiso/nix devShell 前提）。
//
// 生成は backend×exe ごとに走るが、macOS が setupExecutableForPlatform 内で platform_macos.m を
// exe ごとに clang する既存スタイルと対称で、helper シグネチャを増やさずに済む（scanner は軽量）。
// ============================================================================

/// `xdg-shell-client-protocol.h` を生成し、その親ディレクトリ（include path 用）を返す。
/// Wayland backend の `@cImport("xdg-shell-client-protocol.h")` 解決に使う。
fn generateXdgShellClientHeaderDir(b: *std.Build) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        "sh", "-c",
        // $0=sh, $1=出力パス(addOutputFileArg)。pkg-config で xdg-shell.xml の場所を引く。
        "wayland-scanner client-header \"$(pkg-config --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml\" \"$1\"",
        "sh",
    });
    return cmd.addOutputFileArg("xdg-shell-client-protocol.h").dirname();
}

/// `xdg-shell-protocol.c`（protocol marshalling 実体）を生成して LazyPath を返す。
/// exe に C source として追加する（wl_proxy_* を参照するため wayland-client への link を担保する）。
fn generateXdgShellPrivateCode(b: *std.Build) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        "sh", "-c",
        "wayland-scanner private-code \"$(pkg-config --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml\" \"$1\"",
        "sh",
    });
    return cmd.addOutputFileArg("xdg-shell-protocol.c");
}

/// 実行ファイルにプラットフォーム層をセットアップする。
///
/// macOS backend: プラットフォーム層 (.o) のコンパイル、framework / Swift ランタイムリンク、
/// include path 設定までを一括で行う（`sdk_paths` 必須）。
/// Linux backend: 純 Zig なので .o コンパイルは無く、X11 等のリンクのみ（`sdk_paths` は null）。
///
/// 各 example の build.zig からはこの関数 1 つを呼ぶだけで platform 関連のセットアップが完了する。
pub fn setupExecutableForPlatform(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    platform_type: PlatformType,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    sdk_paths: ?macos.MacOSSDKPaths,
) void {
    switch (platform_type) {
        .objc, .swift, .metal => {
            // macOS backend は SDK が必須
            const sdk = sdk_paths orelse @panic("macOS backend には SDK パスが必要です（build.zig の OS 分岐を確認）");

            const compiled = compilePlatformLayer(b, platform_type, optimize, platform_root);
            exe.root_module.addObjectFile(compiled.obj_file);
            exe.root_module.link_libc = true;
            exe.root_module.addIncludePath(platform_root);
            exe.step.dependOn(&compiled.compile_step.step);

            macos.linkMacOSFrameworks(b, exe, sdk);

            switch (platform_type) {
                .objc => {},
                .swift => swift.linkSwiftRuntime(b, exe, sdk, &.{}),
                .metal => {
                    exe.root_module.linkFramework("Metal", .{});
                    exe.root_module.linkFramework("MetalKit", .{});
                    swift.linkSwiftRuntime(b, exe, sdk, &.{
                        "swiftMetalKit",
                        "swiftModelIO",
                    });
                },
                else => unreachable,
            }
        },
        .x11 => {
            // X11/Xlib backend（純 Zig）。.o コンパイルや framework は不要。
            // Xlib シンボルは createPlatformModule の linkSystemLibrary("X11"/"Xext") から
            // exe へ伝播するため、ここでは libc のみ有効にする。
            exe.root_module.link_libc = true;
        },
        .wayland => {
            // Wayland backend（純 Zig）。生成 xdg-shell-protocol.c を exe ごとにコンパイルする
            // （macOS が platform_macos.m を addObjectFile するのと対称。helper シグネチャは増やさない）。
            // この .c は wl_proxy_* を参照するため wayland-client への link が成立する。
            // wayland-client は exe 側でも linkSystemLibrary して .c の compile（ヘッダ解決）と
            // symbol 解決を確実にする（module からの伝播に依存しない）。
            exe.root_module.link_libc = true;
            exe.root_module.linkSystemLibrary("wayland-client", .{});
            exe.root_module.addCSourceFile(.{ .file = generateXdgShellPrivateCode(b) });
        },
        .windows => {
            // Windows backend（純 Zig）。platform_windows.zig が Win32 を extern fn で叩く
            // （@cImport しない）。SDK/xcrun は不要で、zig 同梱の MinGW import lib が
            // user32 / gdi32 / comdlg32 を解決する（kernel32 は zig が自動リンク）。
            // libc は不要（std.os.windows と extern fn のみ）だが、他 OS と挙動を揃えるため有効化する。
            exe.root_module.link_libc = true;
            exe.root_module.linkSystemLibrary("user32", .{}); // CreateWindowExW / メッセージポンプ / 入力
            exe.root_module.linkSystemLibrary("gdi32", .{}); // StretchDIBits / BITMAPINFO blit
            exe.root_module.linkSystemLibrary("comdlg32", .{}); // GetSaveFileNameW / GetOpenFileNameW
            // GUI アプリとして Windows subsystem にする（既定の console subsystem だと起動時に
            // コンソール窓が出る）。コンソール出力が本体のツール（例: example_06 ベンチ）は
            // caller 側で .Console に上書きする。std.debug.print はコンソール非接続時 no-op になる。
            exe.subsystem = .Windows;
        },
    }
}

// ============================================================
// standalone build 共通ヘルパー
// （examples/*/build.zig, apps/editor/build.zig が単独ビルドで使う）
// ============================================================

/// exe root module に足す追加 import（OS/backend 非依存。caller が 1 度だけ作って渡す）。
pub const Import = struct {
    name: []const u8,
    module: *std.Build.Module,
};

/// standalone（単一 exe）ビルドの指定。
pub const StandaloneSpec = struct {
    /// install / run 名のベース（例 "example_01_timed_window"）。
    base_name: []const u8,
    /// main ソース（build root 相対。`b.path("main.zig")` 等）。
    main_source: std.Build.LazyPath,
    /// `src/platform.zig`（standalone は `.{ .cwd_relative = PROJECT_ROOT ++ "/src/platform.zig" }`）。
    platform_source: std.Build.LazyPath,
    /// platform module の include root（`platform.h`。`.{ .cwd_relative = PROJECT_ROOT ++ "/platform" }`）。
    platform_include: std.Build.LazyPath,
    /// setup 用の platform root（macOS backend の .o コンパイル/フレームワーク用。`b.path(PROJECT_ROOT ++ "/platform")`）。
    platform_root: std.Build.LazyPath,
    /// keyboard.zig（不要なら null）。platform に依存するため backend ごとに作る。
    keyboard_source: ?std.Build.LazyPath = null,
    /// OS/backend 非依存の追加 import（sprite / png-decoder / gui / core 等）。
    extra: []const Import = &.{},
    /// L1 オーディオ出力の system ライブラリを exe にリンクするか（audio module は `extra` で渡す）。
    /// macOS=AudioToolbox / Linux=alsa。Windows は audio backend 未対応（facade が compileError）なので何もしない。
    link_audio: bool = false,
};

/// audio を使う standalone exe に L1 出力の system ライブラリを OS 別にリンクする
/// （top build.zig の linkAudioBackend と同方針。Windows は audio 未対応のため no-op = facade の compileError に委ねる）。
fn linkAudioForStandalone(exe: *std.Build.Step.Compile, target_os: std.Target.Os.Tag) void {
    switch (target_os) {
        .macos => exe.root_module.linkFramework("AudioToolbox", .{}),
        .linux => exe.root_module.linkSystemLibrary("alsa", .{}),
        else => {}, // Windows 等: audio backend 未対応。リンクせず compile 時の facade compileError に任せる
    }
}

/// 対象 OS の実装済み backend ごとに exe を 1 つ作り、install / `run-<backend>` /
/// `run`(default) を生成する。SDK 解決は macOS backend のときだけ行う（Linux は xcrun 不要）。
pub fn buildStandalone(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    spec: StandaloneSpec,
) void {
    const target_os = target.result.os.tag;
    const platform_option = b.option(
        PlatformType,
        "platform",
        "Platform backend (macOS: objc/swift/metal, Linux: x11/wayland, Windows: windows)",
    ) orelse defaultBackend(target_os);
    assertBackendForOs(platform_option, target_os);

    // audio 必須の standalone（example_15 等）は audio 非対応 OS では exe を生成しない
    // （top-level build.zig の audio_supported gate と同じ。無いと Windows target で audio facade の
    // compileError に落ちる）。-Dtarget/-Dplatform は上で受理済みなので、ここで何も step を作らず早期 return。
    if (spec.link_audio and !audioSupported(target_os)) {
        std.log.info("standalone '{s}': audio 非対応 OS ({s}) のためスキップ（WASAPI は TASK-31.1 / windows-audio）", .{ spec.base_name, @tagName(target_os) });
        return;
    }

    const sdk_paths: ?macos.MacOSSDKPaths = if (target_os == .macos)
        macos.resolveMacOSSDKPaths(b, null, null)
    else
        null;

    const default_be = defaultBackend(target_os);
    var default_exe: ?*std.Build.Step.Compile = null;

    for (implementedBackends(target_os)) |be| {
        const platform_mod = createPlatformModule(b, target, spec.platform_source, spec.platform_include, be);

        const root = b.createModule(.{
            .root_source_file = spec.main_source,
            .target = target,
            .optimize = optimize,
        });
        root.addImport("platform", platform_mod);
        if (spec.keyboard_source) |ks| {
            const kb = b.createModule(.{ .root_source_file = ks });
            kb.addImport("platform", platform_mod);
            root.addImport("keyboard", kb);
        }
        for (spec.extra) |imp| root.addImport(imp.name, imp.module);

        const name = if (be == default_be)
            spec.base_name
        else
            b.fmt("{s}_{s}", .{ spec.base_name, backendName(be) });

        const exe = b.addExecutable(.{ .name = name, .root_module = root });

        // build_options: 起動時バナー用の platform 名（top build.zig と同じく全 backend に付与）
        const opts = b.addOptions();
        opts.addOption([]const u8, "platform_name", backendName(be));
        exe.root_module.addOptions("build_options", opts);

        setupExecutableForPlatform(b, exe, be, optimize, spec.platform_root, sdk_paths);
        if (spec.link_audio) linkAudioForStandalone(exe, target_os);

        if (be == platform_option) default_exe = exe;
        addStandaloneRunStep(b, b.fmt("run-{s}", .{backendName(be)}), b.fmt("Run the {s} version", .{backendName(be)}), exe);
    }

    const def = default_exe.?;
    b.installArtifact(def);
    addStandaloneRunStep(b, "run", "Run (uses -Dplatform option)", def);
}

fn addStandaloneRunStep(b: *std.Build, name: []const u8, description: []const u8, exe: *std.Build.Step.Compile) void {
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |a| run_cmd.addArgs(a);
    const run_step = b.step(name, description);
    run_step.dependOn(&run_cmd.step);
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
        // Linux / Windows backend は純 Zig で .o コンパイル不要。setupExecutableForPlatform の
        // macOS 分岐からのみ呼ばれるため、ここには到達しない。
        .x11, .wayland, .windows => unreachable,
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
