const std = @import("std");

const platform = @import("build_helpers/platform.zig");
const macos = @import("build_helpers/macos.zig");

const APP_NAME = "video_proto";

// ============================================================
// ADR-007 R1: 層タグと依存配線検査
//
// apps → (kit) → libs → core → platform の一方向依存を build graph で強制する。
// 共有 module（SharedModules / PlatformModules）の配線は必ず link() /
// linkCoreException() / linkAppException() を経由すること。素の addImport は
//   - exe/test/bench の module-internal な root への配線（層をまたぐ共有 module ではない）
//   - examples/ と src/ レガシーヘルパー（keyboard/sprite/text 等）の配線
//     （R5 の kit-only 強制は apps/ のみが対象。examples は教材として従来配線を維持）
// に限って許す。
//
// 違反は std.debug.panic（= build 構成時エラー）で止まる。さらに module root が各層の
// ディレクトリ内にあるため、配線されていない層のファイルへの相対 @import は
// 「import of file outside module path」で compile error になる（物理隔離）。
// ============================================================

const Layer = enum(u8) {
    // L0 platform/（native .o / C ABI）は Zig module ではないためここには現れない。
    core = 1, // L1 薄い base: core/（platform facade + audio facade + control）
    lib = 2, // L2-L3 移植可能 libs: libs/（headless。platform 実装に依存しない）
    kit = 3, // 公開 umbrella: kit/（R4）
    app = 4, // L4 終端消費者: apps/
};

const TaggedModule = struct {
    mod: *std.Build.Module,
    layer: Layer,
    /// import 名（consumer 側の `@import("<name>")`）。
    name: []const u8,
    /// 流動 lib の apps 直 import 許可（ADR-007 成熟ゲート: kit 非収録だが、apps が
    /// 「内部・壊れうる」前提で直 import してよい: modular / paint / spectrogram / scope）。
    /// kit 収録 lib と core は false のまま。
    app_direct_ok: bool = false,
    /// type-only module（platform_types）。libs が core から参照してよい唯一の形（ADR-007 未決#1 の確定）。
    type_only: bool = false,
};

/// 層検査つき配線。違反は build 構成時に panic で止める。
fn link(consumer: TaggedModule, dep: TaggedModule) void {
    const ok = switch (consumer.layer) {
        // apps は kit のみ（R5）。流動 lib（app_direct_ok）だけ「内部・壊れうる」直 import 可。
        .app => dep.layer == .kit or (dep.layer == .lib and dep.app_direct_ok),
        // kit は core と安定 libs を再エクスポートする（R4）。
        .kit => dep.layer == .core or dep.layer == .lib,
        // libs は libs 同士 + type-only な core module（platform_types）のみ（R2）。
        .lib => dep.layer == .lib or (dep.layer == .core and dep.type_only),
        // core は core 同士のみ（例外 harness→png / harness→dsp / platform→pixelops は linkCoreException 経由）。
        .core => dep.layer == .core,
    };
    if (!ok) std.debug.panic(
        "ADR-007 R1 依存方向違反: {s}({s}) → {s}({s})。apps→kit→libs→core の一方向のみ許可。",
        .{ consumer.name, @tagName(consumer.layer), dep.name, @tagName(dep.layer) },
    );
    consumer.mod.addImport(dep.name, dep.mod);
}

/// core → libs の明示例外。現状:
///   - harness(core/control) → png(libs/png)（snapshot fb の PNG encode / crc32）
///   - harness(core/control) → dsp（digest audio のスペクトル解析 band/centroid/onset。TASK-92）
///   - platform(core) → pixelops(libs/pixelops)（wasm present の BGRA→RGBA SIMD swizzle。TASK-73.1）
/// 新たな例外を足す場合は ADR-007 の改訂を伴うこと。
fn linkCoreException(consumer: TaggedModule, dep: TaggedModule, comptime reason: []const u8) void {
    comptime std.debug.assert(reason.len > 0);
    std.debug.assert(consumer.layer == .core and dep.layer == .lib);
    consumer.mod.addImport(dep.name, dep.mod);
}

/// app → kit 収録 lib の直 import 例外。app 内ファイルが pure-test root を兼ねる場合
/// （apps/patch/lofi.zig の synth/dsp）に限り、テスト module を platform 非依存に保つため
/// named 直 import を許す。kit と同一 module インスタンスなので型同一性は保たれる。
fn linkAppException(consumer: TaggedModule, dep: TaggedModule, comptime reason: []const u8) void {
    comptime std.debug.assert(reason.len > 0);
    std.debug.assert(consumer.layer == .app and dep.layer == .lib);
    consumer.mod.addImport(dep.name, dep.mod);
}

/// app exe の root module を層タグ付きで包む（link() の consumer にする）。
fn appRoot(exe: *std.Build.Step.Compile, name: []const u8) TaggedModule {
    return .{ .mod = exe.root_module, .layer = .app, .name = name };
}

const WasmExeBuild = struct {
    exe: *std.Build.Step.Compile,
    install: *std.Build.Step.InstallArtifact,
};

const WebStaticInstalls = struct {
    html: *std.Build.Step.InstallFile,
    synth_html: *std.Build.Step.InstallFile,
    js: *std.Build.Step.InstallFile,
    worklet: *std.Build.Step.InstallFile,
    headers: *std.Build.Step.InstallFile,
    netlify: *std.Build.Step.InstallFile,
    serve_script: *std.Build.Step.InstallFile,

    fn dependOnAll(self: WebStaticInstalls, step: *std.Build.Step) void {
        step.dependOn(&self.html.step);
        step.dependOn(&self.synth_html.step);
        step.dependOn(&self.js.step);
        step.dependOn(&self.worklet.step);
        step.dependOn(&self.headers.step);
        step.dependOn(&self.netlify.step);
        step.dependOn(&self.serve_script.step);
    }
};

/// HTML/JS + ホスティング設定雛形を zig-out/web/ へ install。
fn installWebStaticAssets(b: *std.Build) WebStaticInstalls {
    return .{
        .html = b.addInstallFile(b.path("web/index.html"), "web/index.html"),
        .synth_html = b.addInstallFile(b.path("web/synth.html"), "web/synth.html"),
        .js = b.addInstallFile(b.path("web/vp.js"), "web/vp.js"),
        .worklet = b.addInstallFile(b.path("web/vp-worklet.js"), "web/vp-worklet.js"),
        .headers = b.addInstallFile(b.path("web/deploy/_headers"), "web/_headers"),
        .netlify = b.addInstallFile(b.path("web/deploy/netlify.toml"), "web/netlify.toml"),
        .serve_script = b.addInstallFile(b.path("web/deploy/serve-coop-coep.py"), "web/serve-coop-coep.py"),
    };
}

fn addPackageWebStep(
    b: *std.Build,
    pixie: WasmExeBuild,
    synth: WasmExeBuild,
    static_assets: WebStaticInstalls,
) void {
    const package_step = b.step(
        "package-web",
        "Package wasm web deploy bundle to zig-out/web/ (pixie + synth + static assets)",
    );
    package_step.dependOn(&pixie.install.step);
    package_step.dependOn(&synth.install.step);
    static_assets.dependOnAll(package_step);
}

/// wasm32-wasi 専用ビルド（TASK-73.1 pixie + TASK-73.2 synth audio）。
/// pixie は従来どおり non-shared / single_threaded（ブラウザ回帰を出さない）。
/// synth のみ shared memory + atomics（AudioWorklet 2nd Instance）。
/// root は wasm_root.zig（main 無し）にし、wasi command/_start 経路を避ける（reactor=export 駆動）。
fn buildWasm(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const pixie = buildWasmPixie(b, target, optimize, .{ .build_step_name = "build-pixie" });
    const synth = buildWasmSynth(b, target, optimize, .{ .build_step_name = "build-synth-wasm" });
    const static_assets = installWebStaticAssets(b);
    static_assets.dependOnAll(b.getInstallStep());
    addPackageWebStep(b, pixie, synth, static_assets);
}

const WasmBuildOpts = struct {
    /// true のとき `zig build`（install step）に wasm install を束ねる。
    default_install: bool = true,
    /// null のとき専用 build step を張らない（package-web 経由の cross-compile 用）。
    build_step_name: ?[]const u8,
};

fn buildWasmPixie(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    opts: WasmBuildOpts,
) WasmExeBuild {
    const shared = SharedModules.init(b, true, false);
    const pm = makePlatformModules(b, target, .wasm, &shared, false);

    const pixie_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    {
        const root = TaggedModule{ .mod = pixie_mod, .layer = .app, .name = "pixie" };
        link(root, pm.kit);
        link(root, shared.paint);
    }

    const exe = b.addExecutable(.{
        .name = "pixie",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/editor/apps/pixie/wasm_root.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
        }),
    });
    exe.entry = .disabled;
    exe.rdynamic = true;
    exe.root_module.addImport("pixie", pixie_mod);

    const wasm_install = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
    });
    if (opts.default_install) b.getInstallStep().dependOn(&wasm_install.step);
    if (opts.build_step_name) |name| {
        addBuildStep(b, name, "Build Pixie wasm (wasm32-wasi)", exe);
    }
    return .{ .exe = exe, .install = wasm_install };
}

/// synth wasm: SharedArrayBuffer + atomics + dual Instance（main + AudioWorklet）。
/// notes: pixie は non-shared のまま。audio を使う app だけ shared 化する（回帰最小化）。
///
/// single_threaded=true を維持する理由（TASK-73.2 notes）:
/// - zig 0.16 の `std.heap.wasm_allocator` は multi-thread 未実装
/// - ただし target に `+atomics` があれば single_threaded でも i32.atomic.* が生成される
///   （/tmp/task-73.2 atom PoC で single/multi の atomic 命令が一致することを確認）
/// - Zig Thread は spawn しない（JS 側 main + AudioWorklet の 2 Instance が共有 memory を触る）
fn buildWasmSynth(
    b: *std.Build,
    base_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    opts: WasmBuildOpts,
) WasmExeBuild {
    // atomics + bulk_memory を足した target（shared memory 必須）
    const query = std.Target.Query{
        .cpu_arch = .wasm32,
        .os_tag = base_target.result.os.tag, // wasi
        .abi = base_target.result.abi,
        .cpu_features_add = std.Target.wasm.featureSet(&.{ .atomics, .bulk_memory }),
    };
    const target = b.resolveTargetQuery(query);

    // wasm_shared=false → single_threaded=true（wasm_allocator 可）。atomics は target feature で担保。
    const shared = SharedModules.init(b, true, false);
    const pm = makePlatformModules(b, target, .wasm, &shared, false);

    const synth_mod = b.createModule(.{
        .root_source_file = b.path("apps/synth/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    {
        const root = TaggedModule{ .mod = synth_mod, .layer = .app, .name = "synth" };
        link(root, pm.kit);
        link(root, shared.spectrogram);
        link(root, shared.scope);
        link(root, shared.serde);
    }

    const root_mod = b.createModule(.{
        .root_source_file = b.path("apps/synth/wasm_root.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    // worklet が Instance 毎に __stack_pointer Global を差し替える（PoC a）
    root_mod.export_symbol_names = &.{"__stack_pointer"};

    const exe = b.addExecutable(.{
        .name = "synth",
        .root_module = root_mod,
    });
    exe.entry = .disabled;
    exe.rdynamic = true;
    exe.shared_memory = true;
    exe.import_memory = true;
    exe.export_memory = false;
    // 16 MiB initial / 64 MiB max（FB 1080×520 + audio stack/scratch + synth 状態）
    exe.initial_memory = 16 * 1024 * 1024;
    exe.max_memory = 64 * 1024 * 1024;
    // MasterEffects(65536) は ~0.5MiB+。init で値返し一時がスタックに乗るため余裕を取る。
    exe.stack_size = 2 * 1024 * 1024;
    exe.root_module.addImport("synth_app", synth_mod);

    const wasm_install = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
    });
    if (opts.default_install) b.getInstallStep().dependOn(&wasm_install.step);
    if (opts.build_step_name) |name| {
        addBuildStep(b, name, "Build Synth wasm (shared memory + AudioWorklet)", exe);
    }
    return .{ .exe = exe, .install = wasm_install };
}

/// native ターゲットから wasm web 配布物を cross-compile して zig-out/web/ へ集約（TASK-73.4）。
fn packageWebFromNative(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const wasi_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });
    const cross_opts = WasmBuildOpts{
        .default_install = false,
        .build_step_name = null,
    };
    const pixie = buildWasmPixie(b, wasi_target, optimize, cross_opts);
    const synth = buildWasmSynth(b, wasi_target, optimize, cross_opts);
    const static_assets = installWebStaticAssets(b);
    addPackageWebStep(b, pixie, synth, static_assets);
    addBuildStep(b, "build-pixie-wasm", "Build Pixie wasm for web (wasm32-wasi)", pixie.exe);
    addBuildStep(b, "build-synth-wasm", "Build Synth wasm for web (shared memory + AudioWorklet)", synth.exe);
}

pub fn build(b: *std.Build) void {
    // ========================================
    // プロジェクト特有のセットアップ
    // ========================================
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const target_os = target.result.os.tag;
    const is_wasm = target.result.cpu.arch.isWasm();

    // ========================================
    // wasm 専用ブランチ（TASK-73.1: wasm32-wasi）
    // wasi でも既存 native backend ループは使わず専用経路。pixie のみ。
    // ========================================
    if (is_wasm) {
        buildWasm(b, target, optimize);
        return;
    }

    // backend 選択。有効値は OS で変わる（macOS: objc/swift/metal, Linux: x11/wayland, Windows: gdi/d3d11）。
    // 省略時は OS のデフォルト。OS/backend 不整合は assertBackendForOs で build エラー。
    const platform_option = b.option(
        platform.PlatformType,
        "platform",
        "Platform backend (macOS: objc/swift/metal, Linux: x11/wayland, Windows: gdi/d3d11)",
    ) orelse platform.defaultBackend(target_os);
    platform.assertBackendForOs(platform_option, target_os);

    // SDK / Toolchain パスは macOS backend のみ必要（Linux には xcrun が無いので解決しない）。
    // 指定なしなら xcrun で自動検出。
    const swift_toolchain_path = b.option(
        []const u8,
        "swift-toolchain-path",
        "Path to Swift toolchain (e.g., /Applications/Xcode.app/.../XcodeDefault.xctoolchain)",
    );
    const swift_sdk_path = b.option(
        []const u8,
        "swift-sdk-path",
        "Path to macOS SDK (e.g., /Applications/Xcode.app/.../MacOSX.sdk)",
    );
    const sdk_paths: ?macos.MacOSSDKPaths = if (target_os == .macos)
        macos.resolveMacOSSDKPaths(b, swift_toolchain_path, swift_sdk_path)
    else
        null;

    const platform_root = b.path("platform");

    const install_all = b.option(bool, "install-all", "Install all backends for the target OS") orelse false;

    // ========================================
    // 共有モジュール (OS/backend 非依存。main + examples + pixie + synth で共有)
    // 29.1 の外部公開 module（platform/png/font/gui）も内包する。
    // ========================================
    const shared_modules = SharedModules.init(b, false, false);

    // 対象 OS で実装済みの backend 群（macOS: objc/swift/metal, Linux: x11/wayland, Windows: gdi/d3d11）
    const backends = platform.implementedBackends(target_os);
    const default_be = platform.defaultBackend(target_os);

    // audio (L1 出力) backend: macOS(AudioToolbox) / Linux(ALSA) / Windows(WASAPI)。
    // synth アプリ / example_15(audio) の生成可否（判定は standalone と共有 helper に集約）。
    const audio_supported = platform.audioSupported(target_os);

    // ========================================
    // main / pixie / synth / examples を backend ごとに生成
    // （platform / keyboard は backend ごとに module graph を分ける = build_options.platform_backend を付与）
    // audio を使う synth / example_15 は macOS/Linux/Windows（audio backend が OS 分岐）。platform native lib は macOS のみ。
    // ========================================
    var default_main: ?*std.Build.Step.Compile = null;
    var default_pixie: ?*std.Build.Step.Compile = null;
    var default_synth: ?*std.Build.Step.Compile = null;
    var default_patch: ?*std.Build.Step.Compile = null;

    for (backends) |be| {
        const is_default = (be == platform_option);
        const pm = makePlatformModules(b, target, be, &shared_modules, false);

        // ----- メインアプリケーション -----
        const main_exe = addMainExe(b, target, optimize, platform_root, sdk_paths, be, artifactName(b, APP_NAME, be, default_be), &pm);
        if (is_default) default_main = main_exe;
        if (install_all) b.installArtifact(main_exe);
        addRunStep(b, b.fmt("run-{s}", .{platform.backendName(be)}), b.fmt("Run the {s} version", .{platform.backendName(be)}), main_exe, b.args);

        // ----- Pixie エディタ (apps/editor/apps/pixie) -----
        const pixie_exe = addPixieExe(b, target, optimize, platform_root, sdk_paths, be, artifactName(b, "pixie", be, default_be), &shared_modules, &pm);
        if (is_default) default_pixie = pixie_exe;
        // install-all で pixie もビルド回帰対象にする（非対話のコンパイル検証手段）
        if (install_all) b.installArtifact(pixie_exe);
        addRunStep(b, b.fmt("run-pixie-{s}", .{platform.backendName(be)}), b.fmt("Run Pixie editor ({s})", .{platform.backendName(be)}), pixie_exe, b.args);

        // ----- Synth アプリ (apps/synth) — PC キーボード演奏 MVP (TASK-27.5)。audio backend は macOS/Linux/Windows -----
        if (audio_supported) {
            // ----- Patch アプリ (apps/patch) — パッチキャンバス UI + ライブ再配線 (TASK-40.6.2/40.6.3)。audio 対応 OS -----
            const patch_exe = addPatchExe(b, target, optimize, platform_root, sdk_paths, be, artifactName(b, "patch", be, default_be), &shared_modules, &pm);
            if (is_default) default_patch = patch_exe;
            if (install_all) b.installArtifact(patch_exe);
            addRunStep(b, b.fmt("run-patch-{s}", .{platform.backendName(be)}), b.fmt("Run patch canvas ({s})", .{platform.backendName(be)}), patch_exe, b.args);

            const synth_exe = addSynthExe(b, target, optimize, platform_root, sdk_paths, be, artifactName(b, "synth", be, default_be), &shared_modules, &pm);
            if (is_default) default_synth = synth_exe;
            if (install_all) b.installArtifact(synth_exe);
            addRunStep(b, b.fmt("run-synth-{s}", .{platform.backendName(be)}), b.fmt("Run synth app ({s})", .{platform.backendName(be)}), synth_exe, b.args);

            // ----- 20_capture_demo (examples/20_capture_demo) — mic 波形/FFT可視化 + camera→canvas デモ
            // (TASK-49.6)。camera/audio の capture 拡張は audio backend 対応 OS でのみ実用的なため
            // audio_supported ゲート内に置く（他 example と異なり ExampleNeeds テーブルではなく
            // 専用 helper で配線: camera/harness/capture_synthetic を直 import するため。examples は
            // R5=kit-only 対象外。build.zig 冒頭コメント参照）。
            const capture_demo_exe = addCaptureDemoExe(b, target, optimize, platform_root, sdk_paths, be, artifactName(b, "example_20", be, default_be), &shared_modules, &pm);
            // examples は install-all とは独立に常に全 backend を install（既存 example と同じ方針）。
            b.installArtifact(capture_demo_exe);
            if (is_default) {
                addRunStep(
                    b,
                    "run-example_20",
                    "Run 20_capture_demo example (uses -Dplatform option; set VP_HARNESS_CAPTURE_SYNTHETIC=1 + VP_HARNESS_HEADLESS=1 for headless synthetic mic/camera verification)",
                    capture_demo_exe,
                    b.args,
                );
            }
        }

        // ----- サンプルプログラム -----
        // 各 example が必要とするモジュールを宣言的に指定する。
        // 全要素は同じフィールド集合（name / path / needs_*）を持たせて anonymous struct 型を
        // 揃えること（inline for で型不一致を避けるため）。
        inline for (.{
            .{ .name = "example_01", .path = "examples/01_timed_window/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_02", .path = "examples/02_keyboard_input/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_03", .path = "examples/03_sprite_rendering/main.zig", .needs_sprite = true, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_04", .path = "examples/04_fixed_timestep/main.zig", .needs_sprite = false, .needs_fps_counter = true, .needs_fixed_timestep = true, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_05", .path = "examples/05_text_rendering/main.zig", .needs_sprite = false, .needs_fps_counter = true, .needs_fixed_timestep = false, .needs_text = true, .needs_gui = false, .needs_png = false, .needs_font = true, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_06", .path = "examples/06_sprite_benchmark/main.zig", .needs_sprite = true, .needs_fps_counter = true, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_07", .path = "examples/07_mouse_input/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_08", .path = "examples/08_gui_primitives/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = true, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_09", .path = "examples/09_gui_interaction/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_10", .path = "examples/10_gui_layout/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_11", .path = "examples/11_gui_widgets/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_12", .path = "examples/12_outline_font/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = true, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_13", .path = "examples/13_gui_slider/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_14", .path = "examples/14_gui_color_picker/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_15", .path = "examples/15_audio_tone/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = true, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_16", .path = "examples/16_gui_scroll/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_17", .path = "examples/17_gui_toggles/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_18", .path = "examples/18_cursor/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_19", .path = "examples/19_color_emoji/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = true, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_21", .path = "examples/21_char_input/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = true, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_22", .path = "examples/22_gamepad/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = true, .needs_gmath = false },
            .{ .name = "example_23", .path = "examples/23_fullscreen/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_24", .path = "examples/24_desktop_mascot/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = true, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_25", .path = "examples/25_collision_demo/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = true },
            .{ .name = "example_26", .path = "examples/26_appshell_demo/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
            .{ .name = "example_27", .path = "examples/27_selectable_label/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = true, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false },
        }) |example| {
            const needs: ExampleNeeds = .{
                .needs_sprite = example.needs_sprite,
                .needs_fps_counter = example.needs_fps_counter,
                .needs_fixed_timestep = example.needs_fixed_timestep,
                .needs_text = example.needs_text,
                .needs_gui = example.needs_gui,
                .needs_png = example.needs_png,
                .needs_font = example.needs_font,
                .needs_audio = example.needs_audio,
                .needs_gamepad = example.needs_gamepad,
                .needs_gmath = example.needs_gmath,
            };
            // audio example は audio 対応 OS（macOS/Linux/Windows）のみ。それ以外の example は全 OS。
            if (!needs.needs_audio or audio_supported) {
                const ex_exe = addExampleExe(b, target, optimize, platform_root, sdk_paths, be, artifactName(b, example.name, be, default_be), example.path, &shared_modules, &pm, needs);
                // window を持たず stdout に出力するツール（example_06 ベンチ / example_15 音声トーン）は
                // Windows でも console subsystem を保つ（setupExecutableForPlatform の GUI subsystem を上書き）。
                if (target_os == .windows and comptime (std.mem.eql(u8, example.name, "example_06") or
                    std.mem.eql(u8, example.name, "example_15"))) ex_exe.subsystem = .Console;
                // examples は install-all とは独立に常に全 backend を install する
                // （platform 層 / example のビルド回帰を毎 `zig build` で検出する従来挙動を踏襲）。
                b.installArtifact(ex_exe);
                if (is_default) {
                    addRunStep(
                        b,
                        b.fmt("run-{s}", .{example.name}),
                        b.fmt("Run {s} example (uses -Dplatform option)", .{example.name}),
                        ex_exe,
                        b.args,
                    );
                }
            }
        }
    }

    // デフォルト backend を `run` / 既定 install に紐づける。
    // install-all のときは上のループで全 backend を install 済みなので二重 install しない。
    if (!install_all) b.installArtifact(default_main.?);
    addRunStep(b, "run", "Run the app (uses -Dplatform option)", default_main.?, b.args);
    addRunStep(b, "run-pixie", "Run Pixie editor (uses -Dplatform option)", default_pixie.?, b.args);

    // ビルドのみ（実行しない）。当該 exe だけを install する step。
    // `zig build`（引数なし）は全 installArtifact をビルドしてしまうので、単体ビルド用に分ける。
    addBuildStep(b, "build-main", "Build the app only (uses -Dplatform option)", default_main.?);
    addBuildStep(b, "build-pixie", "Build Pixie editor only (uses -Dplatform option)", default_pixie.?);

    // synth は audio 対応 OS（macOS/Linux/Windows）のみ生成。非対応 OS では default_synth=null で step を張らない。
    if (default_synth) |ds| {
        addRunStep(b, "run-synth", "Run synth app (uses -Dplatform option)", ds, b.args);
        addBuildStep(b, "build-synth", "Build synth app only (uses -Dplatform option)", ds);
    }

    // patch canvas も audio 対応 OS のみ生成（40.6.3 で発音するため。default_patch は非対応 OS で null）。
    if (default_patch) |dp| {
        addRunStep(b, "run-patch", "Run patch canvas (uses -Dplatform option)", dp, b.args);
        addBuildStep(b, "build-patch", "Build patch canvas only (uses -Dplatform option)", dp);
    }

    // ----- 検証 harness の live driver CLI（TASK-32.2）-----
    // 純 std + std.Io.net の単独 exe（platform/audio 非依存）。常に install して compile 回帰も兼ねる。
    // `scripts/drive` wrapper が `zig-out/bin/drive` を直接 exec する。
    const drive_exe = b.addExecutable(.{
        .name = "drive",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/drive.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(drive_exe);
    addBuildStep(b, "drive", "Build the live harness driver CLI (zig-out/bin/drive)", drive_exe);

    // ----- MCP server CLI（TASK-88.2）-----
    // 純 std + std.Io.net の単独 exe（platform/audio 非依存）。drive と同型。
    // `scripts/mcp` wrapper が `zig-out/bin/vp-mcp` を直接 exec する。
    const mcp_exe = b.addExecutable(.{
        .name = "vp-mcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/mcp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(mcp_exe);
    addBuildStep(b, "mcp", "Build the MCP server CLI (zig-out/bin/vp-mcp)", mcp_exe);

    // ----- wasm web 配布パッケージ（TASK-73.4）-----
    // native ターゲットから cross-compile して zig-out/web/ へ集約。開発時の web/ 配置は不変。
    packageWebFromNative(b, optimize);

    // ========================================
    // platform native object archive lib（外部パッケージ向け。TASK-29.1）— macOS のみ
    // facade module(addModule "platform") と責務分離。外部は dep.artifact("platform_native_<plat>")
    // を linkLibrary する。.o の archive のみで、framework/Swift ランタイム/検索パスは
    // consumer の exe 側で適用する（29.2 の C 方式）。
    //
    // 既知の制限（Linux 外部消費は未対応）: 29.1 の公開モデル（facade module + native .o archive）は
    // macOS backend(Obj-C/Swift を別コンパイル)前提の形。Linux で外部パッケージとして
    // `dep.module("platform")` を使うと、(1) facade が platform_linux.zig を選び
    // `@import("build_options")`(platform_backend) を要求するが公開 module には付いていない、
    // (2) X11 の include / `linkSystemLibrary("X11"/"Xext")` が無い、(3) Linux backend は純 Zig で
    // 別 .o archive 不要、のため成立しない。対応するなら公開 module を backend-aware にする
    // （Linux 既定 x11 の build_options + X11 link を付与）必要がある。自プロジェクトの内部ビルドは
    // per-backend module(makePlatformModules)を使うので無影響。需要が出たら 29.x で対応。
    // ========================================
    if (target_os == .macos) {
        _ = addPlatformNativeLib(b, target, optimize, platform_root, .objc, "platform_native_objc");
        _ = addPlatformNativeLib(b, target, optimize, platform_root, .swift, "platform_native_swift");
        _ = addPlatformNativeLib(b, target, optimize, platform_root, .metal, "platform_native_metal");
    }

    // ========================================
    // テスト群（platform を import しない純テスト。OS/backend 非依存）
    // ========================================

    // PNG round-trip テスト (io_png.zig のテスト + png で検証)
    const io_png_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/io_png.zig"),
        .target = target,
        .optimize = optimize,
    });
    io_png_mod.addImport("png", shared_modules.png.mod);
    const png_roundtrip_test = b.addTest(.{ .root_module = io_png_mod });
    const run_png_roundtrip_test = b.addRunArtifact(png_roundtrip_test);
    const test_png_roundtrip_step = b.step("test-png-roundtrip", "Run PNG encode/decode round-trip tests");
    test_png_roundtrip_step.dependOn(&run_png_roundtrip_test.step);

    // PNG エンコーダ単体テスト（golden byte 一致 + scanline 順。decoder 非依存。TASK-33）
    const png_encode_mod = b.createModule(.{
        .root_source_file = b.path("libs/png/src/encode.zig"),
        .target = target,
        .optimize = optimize,
    });
    const png_encode_test = b.addTest(.{ .root_module = png_encode_mod });
    test_png_roundtrip_step.dependOn(&b.addRunArtifact(png_encode_test).step);

    // harness 単体テスト（parser / 実行モデル / 仮想クロック。display 不要・backend 非依存。TASK-32.1）
    const harness_test_mod = b.createModule(.{
        .root_source_file = b.path("core/control/harness.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // harness.init() は libc getenv を使う（init を呼ぶテストでも通るように）
    });
    harness_test_mod.addImport("png", shared_modules.png.mod); // harness が encodePNG/crc32 を使う
    harness_test_mod.addImport("platform_types", shared_modules.types.mod); // harness が Event/EventStats 等を使う
    harness_test_mod.addImport("command_types", shared_modules.command_types.mod);
    harness_test_mod.addImport("capture_synthetic", shared_modules.capture_synthetic.mod); // harness の `capture` コマンド/probe が使う（TASK-49.5）
    harness_test_mod.addImport("dsp", shared_modules.dsp.mod); // TASK-92: digest audio スペクトル解析（band/centroid/onset）
    const harness_test = b.addTest(.{ .root_module = harness_test_mod });
    const run_harness_test = b.addRunArtifact(harness_test);
    const test_harness_step = b.step("test-harness", "Run harness unit tests (parser / 実行モデル / 仮想クロック)");
    test_harness_step.dependOn(&run_harness_test.step);

    // vp-mcp 単体テスト（schema 変換・直列化・fail 抽出・衝突解決・contract。std のみ。TASK-88.2）
    const mcp_test_mod = b.createModule(.{
        .root_source_file = b.path("scripts/mcp.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mcp_test = b.addTest(.{ .root_module = mcp_test_mod });
    const run_mcp_test = b.addRunArtifact(mcp_test);
    const test_mcp_step = b.step("test-mcp", "Run vp-mcp unit tests (schema / serialize / fail / contract)");
    test_mcp_step.dependOn(&run_mcp_test.step);

    // command model 単体テスト（型 + executor + no-op recorder。std のみ・platform/harness 非依存。TASK-62.5.1）
    const command_test_mod = b.createModule(.{
        .root_source_file = b.path("core/control/command.zig"),
        .target = target,
        .optimize = optimize,
    });
    command_test_mod.addImport("command_types", shared_modules.command_types.mod);
    const command_test = b.addTest(.{ .root_module = command_test_mod });
    const run_command_test = b.addRunArtifact(command_test);
    const test_command_step = b.step("test-command", "Run command model unit tests (types / executor / undo-redo / no-op recorder)");
    test_command_step.dependOn(&run_command_test.step);

    // TASK-97.1: menu Command の type-only model と App.dispatchCommand adapter。
    const command_types_test_mod = b.createModule(.{
        .root_source_file = b.path("core/command_types.zig"),
        .target = target,
        .optimize = optimize,
    });
    command_types_test_mod.addImport("platform_types", shared_modules.types.mod);
    const command_types_test = b.addTest(.{ .root_module = command_types_test_mod });
    const run_command_types_test = b.addRunArtifact(command_types_test);
    const test_command_types_step = b.step("test-command-types", "Run menu Command type-only model tests");
    test_command_types_step.dependOn(&run_command_types_test.step);

    const platform_menu_test_mod = b.createModule(.{
        .root_source_file = b.path("core/platform_menu_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    platform_menu_test_mod.addImport("platform", shared_modules.platform.mod);
    platform_menu_test_mod.addImport("command_types", shared_modules.command_types.mod);
    const platform_menu_test = b.addTest(.{ .root_module = platform_menu_test_mod });
    const run_platform_menu_test = b.addRunArtifact(platform_menu_test);
    const test_platform_menu_step = b.step("test-platform-menu", "Run display-less platform menu facade tests");
    test_platform_menu_step.dependOn(&run_platform_menu_test.step);

    // copilot transport 単体テスト（ConnState state machine / コマンド実行層 / registry OR ゲート / 排他。
    // socket・display 不要。TASK-62.5.2）。root=copilot.zig は harness.zig を import するため
    // harness_test_mod と同じ import/link_libc 構成が要る。"copilot:" filter で copilot のテストのみ
    // 実行する（import された harness/command のテストは test-harness / test-command が担う。二重実行を避ける）。
    const copilot_test_mod = b.createModule(.{
        .root_source_file = b.path("core/control/copilot.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // copilot/harness とも libc getenv を使う
    });
    copilot_test_mod.addImport("png", shared_modules.png.mod);
    copilot_test_mod.addImport("platform_types", shared_modules.types.mod);
    copilot_test_mod.addImport("command_types", shared_modules.command_types.mod);
    copilot_test_mod.addImport("capture_synthetic", shared_modules.capture_synthetic.mod);
    const copilot_test = b.addTest(.{ .root_module = copilot_test_mod, .filters = &.{"copilot:"} });
    const run_copilot_test = b.addRunArtifact(copilot_test);
    const test_copilot_step = b.step("test-copilot", "Run copilot transport unit tests (ConnState / command layer / registry OR gate)");
    test_copilot_step.dependOn(&run_copilot_test.step);

    // netsync transport 単体テスト（action_registry + frame codec + loopback HELLO/queue。
    // display 不要。TASK-62.3.1）。root=netsync.zig は action_registry.zig を相対 import する。
    const netsync_test_mod = b.createModule(.{
        .root_source_file = b.path("core/control/netsync.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // getenv
    });
    netsync_test_mod.addImport("command_types", shared_modules.command_types.mod);
    const netsync_test = b.addTest(.{ .root_module = netsync_test_mod, .filters = &.{"netsync:"} });
    const run_netsync_test = b.addRunArtifact(netsync_test);
    const test_netsync_step = b.step("test-netsync", "Run netsync transport unit tests (codec / HELLO / loopback queues)");
    test_netsync_step.dependOn(&run_netsync_test.step);

    // action_registry 単体も test-netsync に含める（filter 無しの別 artifact）。
    const action_registry_test_mod = b.createModule(.{
        .root_source_file = b.path("core/control/action_registry.zig"),
        .target = target,
        .optimize = optimize,
    });
    const action_registry_test = b.addTest(.{ .root_module = action_registry_test_mod });
    test_netsync_step.dependOn(&b.addRunArtifact(action_registry_test).step);

    // audio_null 単体テスト（headless の実デバイス無し出力。RT ゼロアロケーション / pull ループ。
    // display・実オーディオデバイス不要・OS 非依存。TASK-32.4 P4）
    const audio_null_test_mod = b.createModule(.{
        .root_source_file = b.path("core/audio_null.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // sleep ペーシングに std.c.nanosleep を使う（platform.sleep と同じ実装）
    });
    const audio_null_test = b.addTest(.{ .root_module = audio_null_test_mod });
    const run_audio_null_test = b.addRunArtifact(audio_null_test);
    const test_audio_null_step = b.step("test-audio-null", "Run audio_null (headless null device) unit tests");
    test_audio_null_step.dependOn(&run_audio_null_test.step);

    // 共有型 module（platform_types）の単体テスト（ModifierFlags round-trip 等）。
    // TASK-32.2 で platform_types を named module 化したため、source-include で拾われなくなった分を
    // 独立 step として明示的にカバーする。
    const platform_types_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/platform_types.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_platform_types_step = b.step("test-platform-types", "Run platform_types unit tests (shared type definitions)");
    test_platform_types_step.dependOn(&b.addRunArtifact(platform_types_test).step);

    // wasm platform の DOM→MouseButton / KeyCode 写像（native でも実行。extern env はテスト経路から未参照）。
    const platform_wasm_test_mod = b.createModule(.{
        .root_source_file = b.path("core/platform_wasm.zig"),
        .target = target,
        .optimize = optimize,
    });
    platform_wasm_test_mod.addImport("platform_types", shared_modules.types.mod);
    platform_wasm_test_mod.addImport("pixelops", shared_modules.pixelops.mod);
    const platform_wasm_test = b.addTest(.{ .root_module = platform_wasm_test_mod });
    const test_platform_wasm_step = b.step("test-platform-wasm", "Run platform_wasm DOM→MouseButton / KeyCode unit tests (TASK-73.1)");
    test_platform_wasm_step.dependOn(&b.addRunArtifact(platform_wasm_test).step);

    // capture 入力基盤（TASK-49.1/49.5）単体テスト。display/実デバイス不要・OS 非依存。
    // capture_types（TripleBuffer 往復・不変条件・DeviceInfo/CaptureError 構造）+ camera facade
    // （camera_stub.zig を relative import で内包。harness 分岐 + stub 委譲）+ audio.zig の
    // capture 拡張（audio_capture_stub.zig を relative import で内包。既存出力 backend の switch は
    // 参照されない限り分析されない Zig の lazy analysis により、AudioToolbox 等のリンクは不要
    // ＝実測確認済み）+ capture_synthetic（harness 内蔵 synthetic capture source。TASK-49.5）の
    // 4本を1 step に束ねる。
    const capture_types_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/capture_types.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_capture_types_step = b.step("test-capture-types", "Run capture_types / camera facade / audio capture extension unit tests (TASK-49.1)");
    test_capture_types_step.dependOn(&b.addRunArtifact(capture_types_test).step);

    // camera.zig facade（macOS: camera_macos.zig / 他OS: camera_stub.zig を relative import で
    // 内包。TASK-49.2）。harness を使うため harness_test_mod と同じ理由で link_libc=true にする
    // （camera_macos.zig の objc_runtime 経由 std.c.nanosleep/getenv にも同じ理由で必要）。
    const camera_test_mod = b.createModule(.{
        .root_source_file = b.path("core/camera.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // harness.init() 系が libc getenv を使う + macOS: objc_runtime の nanosleep
    });
    camera_test_mod.addImport("capture_types", shared_modules.capture_types.mod);
    camera_test_mod.addImport("harness", shared_modules.harness.mod);
    camera_test_mod.addImport("objc_runtime", shared_modules.objc_runtime.mod); // macOS: camera_macos.zig が named import で参照（TASK-49.6）
    const camera_test = b.addTest(.{ .root_module = camera_test_mod });
    // TASK-49.2: macOS は camera_macos.zig が AVFoundation(ObjC専用API)を objc_runtime 経由で
    // 叩くため、テスト実行はしない（設定検証のみ自動）が compile+link には必要な framework 一式を
    // 明示リンクする（他OS は camera_stub.zig のまま追加不要）。
    if (target.result.os.tag == .macos) linkCaptureMacFrameworks(b, camera_test_mod, sdk_paths.?);
    test_capture_types_step.dependOn(&b.addRunArtifact(camera_test).step);

    // core/audio.zig（capture 拡張含む全体）。既存出力 backend（audio_macos 等）への `switch` は
    // 残るが、出力側の関数は本テストのどの test からも呼ばれないため Zig の lazy analysis で
    // 未参照のまま留まる（実測確認済み）。capture 側は macOS で実 backend
    // （`audio_macos.zig` の `capture` 名前空間。TASK-49.2）を経由するため link_libc=true
    // （objc_runtime 経由 std.c.nanosleep/getenv）が必要。
    const audio_capture_test_mod = b.createModule(.{
        .root_source_file = b.path("core/audio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    audio_capture_test_mod.addImport("harness", shared_modules.harness.mod);
    audio_capture_test_mod.addImport("capture_types", shared_modules.capture_types.mod);
    audio_capture_test_mod.addImport("objc_runtime", shared_modules.objc_runtime.mod); // macOS: audio_macos.zig が named import で参照（TASK-49.6）
    if (target.result.os.tag == .linux) audio_capture_test_mod.linkSystemLibrary("alsa", .{});
    const audio_capture_test = b.addTest(.{ .root_module = audio_capture_test_mod });
    // TASK-49.2: macOS の mic capture（AUHAL input）は AudioToolbox/CoreAudio + 権限確認の
    // AVFoundation(ObjC)を使うため framework を明示リンクする（他OS は audio_capture_stub.zig の
    // まま追加不要）。
    if (target.result.os.tag == .macos) linkCaptureMacFrameworks(b, audio_capture_test_mod, sdk_paths.?);
    test_capture_types_step.dependOn(&b.addRunArtifact(audio_capture_test).step);

    // TASK-49.2 実測知見: `zig test` は「root file 自身の test」のみを収集・実行し、root file が
    // 相対 `@import` する別ファイル（`camera_macos.zig`/`audio_macos.zig` 等）側の test は
    // 収集されない（root=camera.zig/audio.zig の `camera_test`/`audio_capture_test` はコンパイル
    // ＝リンクは通るが、それらのファイル内の test は実行数に現れないことを実測確認済み）。
    // よって `capture_synthetic_test` と同じ方針で、root を直接そのファイルにした専用 addTest を
    // macOS のみ追加し、`copyBgraRows`/`mapAuthStatus`/config 検証等の自動テストを実際に実行させる。
    // `objc_runtime.zig`（msgSend/stack block。最も壊れやすい部分）は camera_macos.zig/
    // audio_macos.zig の双方から相対 import されるため、それらの root test に載って間接的に
    // 実行される（実測確認済み: root file 自身の「直接の」相対 import は収集対象になる。上記の
    // 「収集されない」制約は root を跨いだ2段階の間接 import にのみ働く）。ただし依存関係を
    // 前提にせず明示的に検証できるよう、root を直接 core/objc_runtime.zig にした専用 addTest も
    // 追加する（codex レビュー指摘）。
    if (target_os == .macos) {
        const objc_runtime_test_mod = b.createModule(.{
            .root_source_file = b.path("core/objc_runtime.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // std.c.nanosleep/getenv 用
        });
        linkCaptureMacFrameworks(b, objc_runtime_test_mod, sdk_paths.?);
        const objc_runtime_test = b.addTest(.{ .root_module = objc_runtime_test_mod });
        test_capture_types_step.dependOn(&b.addRunArtifact(objc_runtime_test).step);

        const camera_macos_test_mod = b.createModule(.{
            .root_source_file = b.path("core/camera_macos.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // objc_runtime 経由の std.c.nanosleep/getenv 用
        });
        camera_macos_test_mod.addImport("capture_types", shared_modules.capture_types.mod);
        camera_macos_test_mod.addImport("objc_runtime", shared_modules.objc_runtime.mod); // TASK-49.6: 相対→named import 化
        linkCaptureMacFrameworks(b, camera_macos_test_mod, sdk_paths.?);
        const camera_macos_test = b.addTest(.{ .root_module = camera_macos_test_mod });
        test_capture_types_step.dependOn(&b.addRunArtifact(camera_macos_test).step);

        const audio_macos_capture_test_mod = b.createModule(.{
            .root_source_file = b.path("core/audio_macos.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        audio_macos_capture_test_mod.addImport("capture_types", shared_modules.capture_types.mod);
        audio_macos_capture_test_mod.addImport("objc_runtime", shared_modules.objc_runtime.mod); // TASK-49.6: 相対→named import 化
        linkCaptureMacFrameworks(b, audio_macos_capture_test_mod, sdk_paths.?);
        const audio_macos_capture_test = b.addTest(.{ .root_module = audio_macos_capture_test_mod });
        test_capture_types_step.dependOn(&b.addRunArtifact(audio_macos_capture_test).step);
    }

    if (target_os == .linux) {
        const camera_v4l2_test_mod = b.createModule(.{
            .root_source_file = b.path("core/camera_v4l2.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        camera_v4l2_test_mod.addImport("capture_types", shared_modules.capture_types.mod);
        const camera_v4l2_test = b.addTest(.{ .root_module = camera_v4l2_test_mod });
        test_capture_types_step.dependOn(&b.addRunArtifact(camera_v4l2_test).step);

        const audio_linux_capture_test_mod = b.createModule(.{
            .root_source_file = b.path("core/audio_linux.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        audio_linux_capture_test_mod.addImport("capture_types", shared_modules.capture_types.mod);
        audio_linux_capture_test_mod.linkSystemLibrary("alsa", .{});
        const audio_linux_capture_test = b.addTest(.{ .root_module = audio_linux_capture_test_mod });
        test_capture_types_step.dependOn(&b.addRunArtifact(audio_linux_capture_test).step);
    }

    // core/capture_synthetic.zig（harness 内蔵 synthetic capture source。TASK-49.5）。
    // capture_types にのみ依存（camera/audio facade への配線は無い）。audio 生成スレッドの
    // std.c.nanosleep 用に link_libc=true（core/audio_null.zig の test と同じ理由）。
    const capture_synthetic_test_mod = b.createModule(.{
        .root_source_file = b.path("core/capture_synthetic.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    capture_synthetic_test_mod.addImport("capture_types", shared_modules.capture_types.mod);
    const capture_synthetic_test = b.addTest(.{ .root_module = capture_synthetic_test_mod });
    test_capture_types_step.dependOn(&b.addRunArtifact(capture_synthetic_test).step);

    // canvas.zig 単体テスト
    const canvas_test_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/canvas.zig"),
        .target = target,
        .optimize = optimize,
    });
    canvas_test_mod.addImport("pixelops", shared_modules.pixelops.mod); // blend.zig facade 経由（TASK-51）
    canvas_test_mod.addImport("font", shared_modules.font.mod); // text_render.zig 経由（TASK-79.5）
    const canvas_test = b.addTest(.{ .root_module = canvas_test_mod });
    const run_canvas_test = b.addRunArtifact(canvas_test);
    test_png_roundtrip_step.dependOn(&run_canvas_test.step);

    // blend.zig 単体テスト（pixelops への facade 疎通。ブレンド本体のテストは test-pixelops）
    const blend_test_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/blend.zig"),
        .target = target,
        .optimize = optimize,
    });
    blend_test_mod.addImport("pixelops", shared_modules.pixelops.mod);
    const blend_test = b.addTest(.{ .root_module = blend_test_mod });
    const run_blend_test = b.addRunArtifact(blend_test);
    test_png_roundtrip_step.dependOn(&run_blend_test.step);

    // libs/pixelops 単体テスト（premul/straight blend の SIMD vs scalar 一致・div255 恒等・clipBlit 境界）
    const pixelops_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("libs/pixelops/src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_pixelops_test = b.addRunArtifact(pixelops_test);
    const test_pixelops_step = b.step("test-pixelops", "Run libs/pixelops blend/div255/clip-hoist tests");
    test_pixelops_step.dependOn(&run_pixelops_test.step);

    // libs/gmath 単体テスト（Vec2 / Rect / scalar / 衝突。platform 非依存。TASK-111.1）
    const gmath_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("libs/gmath/src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_gmath_test = b.addRunArtifact(gmath_test);
    const test_gmath_step = b.step("test-gmath", "Run libs/gmath unit tests");
    test_gmath_step.dependOn(&run_gmath_test.step);

    // libs/serde 単体テスト（versioned container の round-trip / 破損検出 / 前方互換 / 固定 fixture。TASK-62.2）
    const serde_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("libs/serde/src/serde.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_serde_test = b.addRunArtifact(serde_test);
    const test_serde_step = b.step("test-serde", "Run libs/serde versioned container tests");
    test_serde_step.dependOn(&run_serde_test.step);

    // libs/appshell 単体テスト（設定 / window state / recent files。TASK-114.1）
    const appshell_test_mod = b.createModule(.{
        .root_source_file = b.path("libs/appshell/src/appshell.zig"),
        .target = target,
        .optimize = optimize,
    });
    appshell_test_mod.addImport("serde", shared_modules.serde.mod);
    const appshell_test = b.addTest(.{ .root_module = appshell_test_mod });
    const run_appshell_test = b.addRunArtifact(appshell_test);
    const test_appshell_step = b.step("test-appshell", "Run libs/appshell persistence tests");
    test_appshell_step.dependOn(&run_appshell_test.step);

    // libs/recipe 単体テスト（CommandRecord 列 save/load。TASK-62.5.8。serde に依存）
    const recipe_test_mod = b.createModule(.{
        .root_source_file = b.path("libs/recipe/src/recipe.zig"),
        .target = target,
        .optimize = optimize,
    });
    recipe_test_mod.addImport("serde", shared_modules.serde.mod);
    const recipe_test = b.addTest(.{ .root_module = recipe_test_mod });
    const run_recipe_test = b.addRunArtifact(recipe_test);
    const test_recipe_step = b.step("test-recipe", "Run libs/recipe save/load / collect / app_name tests");
    test_recipe_step.dependOn(&run_recipe_test.step);

    // editor/core テスト (undo: stroke 記録 + undo/redo + PNG round-trip, tool: Tool ゴールデン)
    // + pixie canvas_input (入力状態機械: capture / 外 release / 外継続 / stroke 中無視)
    const core_undo_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/undo.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_undo_mod.addImport("png", shared_modules.png.mod);
    core_undo_mod.addImport("pixelops", shared_modules.pixelops.mod);
    core_undo_mod.addImport("font", shared_modules.font.mod); // canvas.zig → text_render.zig 経由（TASK-79.5）
    const core_undo_test = b.addTest(.{ .root_module = core_undo_mod });
    const run_core_undo_test = b.addRunArtifact(core_undo_test);

    const core_tool_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/tool.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_tool_mod.addImport("png", shared_modules.png.mod);
    core_tool_mod.addImport("pixelops", shared_modules.pixelops.mod);
    core_tool_mod.addImport("font", shared_modules.font.mod); // canvas.zig → text_render.zig 経由（TASK-79.5）
    const core_tool_test = b.addTest(.{ .root_module = core_tool_mod });
    const run_core_tool_test = b.addRunArtifact(core_tool_test);

    // 塗りつぶし（バケツ）flood fill + Fill Tool（TASK-76）。tool.zig と同様 png/pixelops が要る
    // （PNG round-trip テスト + canvas.zig 経由の pixelops）。
    const core_fill_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/fill.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_fill_mod.addImport("png", shared_modules.png.mod);
    core_fill_mod.addImport("pixelops", shared_modules.pixelops.mod);
    core_fill_mod.addImport("font", shared_modules.font.mod); // canvas.zig → text_render.zig 経由（TASK-79.5）
    const core_fill_test = b.addTest(.{ .root_module = core_fill_mod });
    const run_core_fill_test = b.addRunArtifact(core_fill_test);

    // シェイプラスタライズ（TASK-90）。std のみの純関数（canvas 非依存）。
    const core_shape_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/shape.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_shape_test = b.addTest(.{ .root_module = core_shape_mod });
    const run_core_shape_test = b.addRunArtifact(core_shape_test);

    // ベジェ/ベクターパス（TASK-21.13）。bezier=pure。path/path_editor は相対 import 先（undo/path の test）が
    // png を使うため import 要（Zig は同一モジュール内 @import 先の test もコンパイルする）。
    const core_bezier_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/bezier.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_bezier_test = b.addTest(.{ .root_module = core_bezier_mod });
    const run_core_bezier_test = b.addRunArtifact(core_bezier_test);

    const core_path_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/path.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_path_mod.addImport("png", shared_modules.png.mod);
    core_path_mod.addImport("pixelops", shared_modules.pixelops.mod);
    core_path_mod.addImport("font", shared_modules.font.mod); // canvas.zig → text_render.zig 経由（TASK-79.5）
    const core_path_test = b.addTest(.{ .root_module = core_path_mod });
    const run_core_path_test = b.addRunArtifact(core_path_test);

    const core_path_editor_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/path_editor.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_path_editor_mod.addImport("png", shared_modules.png.mod);
    core_path_editor_mod.addImport("pixelops", shared_modules.pixelops.mod);
    core_path_editor_mod.addImport("font", shared_modules.font.mod); // canvas.zig → text_render.zig 経由（TASK-79.5）
    const core_path_editor_test = b.addTest(.{ .root_module = core_path_editor_mod });
    const run_core_path_editor_test = b.addRunArtifact(core_path_editor_test);

    // Document / document_io（TASK-63）。document_io.zig root で document.zig の test も含む。
    // serde(container) / png(exportPngSequence の decode 検証) / pixelops(canvas 経由) が要る。
    const core_document_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/document_io.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_document_mod.addImport("serde", shared_modules.serde.mod);
    core_document_mod.addImport("png", shared_modules.png.mod);
    core_document_mod.addImport("pixelops", shared_modules.pixelops.mod);
    core_document_mod.addImport("font", shared_modules.font.mod); // canvas.zig → text_render.zig 経由（TASK-79.5）
    const core_document_test = b.addTest(.{ .root_module = core_document_mod });
    const run_core_document_test = b.addRunArtifact(core_document_test);

    const canvas_input_core = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/paint.zig"),
    });
    const canvas_input_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/canvas_input.zig"),
        .target = target,
        .optimize = optimize,
    });
    canvas_input_core.addImport("pixelops", shared_modules.pixelops.mod);
    canvas_input_core.addImport("png", shared_modules.png.mod); // paint.zig → document_io/io_png（TASK-63）
    canvas_input_core.addImport("serde", shared_modules.serde.mod);
    canvas_input_core.addImport("font", shared_modules.font.mod); // paint.zig → canvas.zig → text_render.zig（TASK-79.5）
    canvas_input_mod.addImport("paint", canvas_input_core);
    const canvas_input_test = b.addTest(.{ .root_module = canvas_input_mod });
    const run_canvas_input_test = b.addRunArtifact(canvas_input_test);

    // 範囲選択 core（TASK-44）。@import("undo.zig") 経由で undo の png 使用テストもコンパイルされるため png 要。
    const core_selection_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/selection.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_selection_mod.addImport("png", shared_modules.png.mod);
    core_selection_mod.addImport("pixelops", shared_modules.pixelops.mod);
    core_selection_mod.addImport("font", shared_modules.font.mod); // canvas.zig → text_render.zig 経由（TASK-79.5）
    const core_selection_test = b.addTest(.{ .root_module = core_selection_mod });
    const run_core_selection_test = b.addRunArtifact(core_selection_test);

    // 範囲選択の入力アダプタ（TASK-44）。core を名前付き import（canvas_input と同型・png 不要）
    const selection_input_core = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/paint.zig"),
    });
    const selection_input_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/selection_input.zig"),
        .target = target,
        .optimize = optimize,
    });
    selection_input_core.addImport("pixelops", shared_modules.pixelops.mod);
    selection_input_core.addImport("png", shared_modules.png.mod); // paint.zig → document_io/io_png（TASK-63）
    selection_input_core.addImport("serde", shared_modules.serde.mod);
    selection_input_core.addImport("font", shared_modules.font.mod); // paint.zig → canvas.zig → text_render.zig（TASK-79.5）
    selection_input_mod.addImport("paint", selection_input_core);
    const selection_input_test = b.addTest(.{ .root_module = selection_input_mod });
    const run_selection_input_test = b.addRunArtifact(selection_input_test);

    // シェイプ入力アダプタ（TASK-90）。core を名前付き import（selection_input と同型）
    const shape_input_core = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/paint.zig"),
    });
    const shape_input_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/shape_input.zig"),
        .target = target,
        .optimize = optimize,
    });
    shape_input_core.addImport("pixelops", shared_modules.pixelops.mod);
    shape_input_core.addImport("png", shared_modules.png.mod);
    shape_input_core.addImport("serde", shared_modules.serde.mod);
    shape_input_core.addImport("font", shared_modules.font.mod);
    shape_input_mod.addImport("paint", shape_input_core);
    const shape_input_test = b.addTest(.{ .root_module = shape_input_mod });
    const run_shape_input_test = b.addRunArtifact(shape_input_test);

    // ベジェ入力アダプタ（TASK-21.13）。core を名前付き import（canvas_input と同型）
    const bezier_input_core = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/paint.zig"),
    });
    const bezier_input_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/bezier_input.zig"),
        .target = target,
        .optimize = optimize,
    });
    bezier_input_core.addImport("pixelops", shared_modules.pixelops.mod);
    bezier_input_core.addImport("png", shared_modules.png.mod); // paint.zig → document_io/io_png（TASK-63）
    bezier_input_core.addImport("serde", shared_modules.serde.mod);
    bezier_input_core.addImport("font", shared_modules.font.mod); // paint.zig → canvas.zig → text_render.zig（TASK-79.5）
    bezier_input_mod.addImport("paint", bezier_input_core);
    const bezier_input_test = b.addTest(.{ .root_module = bezier_input_mod });
    const run_bezier_input_test = b.addRunArtifact(bezier_input_test);

    // スポイトの入力アダプタ（TASK-68）。core を名前付き import（selection_input/bezier_input と同型）
    const eyedropper_input_core = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/paint.zig"),
    });
    const eyedropper_input_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/eyedropper_input.zig"),
        .target = target,
        .optimize = optimize,
    });
    eyedropper_input_core.addImport("pixelops", shared_modules.pixelops.mod);
    eyedropper_input_core.addImport("png", shared_modules.png.mod); // paint.zig → document_io/io_png（TASK-63）
    eyedropper_input_core.addImport("serde", shared_modules.serde.mod);
    eyedropper_input_core.addImport("font", shared_modules.font.mod); // paint.zig → canvas.zig → text_render.zig（TASK-79.5）
    eyedropper_input_mod.addImport("paint", eyedropper_input_core);
    const eyedropper_input_test = b.addTest(.{ .root_module = eyedropper_input_mod });
    const run_eyedropper_input_test = b.addRunArtifact(eyedropper_input_test);

    // ブラシ footprint 縁セルキャッシュ（TASK-75.4）。gui/kit 非依存の純ロジック。core を名前付き import（canvas_input と同型）
    const brush_edge_cache_core = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/paint.zig"),
    });
    const brush_edge_cache_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/brush_edge_cache.zig"),
        .target = target,
        .optimize = optimize,
    });
    brush_edge_cache_core.addImport("pixelops", shared_modules.pixelops.mod);
    brush_edge_cache_core.addImport("png", shared_modules.png.mod); // paint.zig → document_io/io_png（TASK-63）
    brush_edge_cache_core.addImport("serde", shared_modules.serde.mod);
    brush_edge_cache_core.addImport("font", shared_modules.font.mod); // paint.zig → canvas.zig → text_render.zig（TASK-79.5）
    brush_edge_cache_mod.addImport("paint", brush_edge_cache_core);
    const brush_edge_cache_test = b.addTest(.{ .root_module = brush_edge_cache_mod });
    const run_brush_edge_cache_test = b.addRunArtifact(brush_edge_cache_test);

    // pixie blit（canvas zoom 転送 + チェッカー。TASK-54）。core を名前付き import（canvas_input と同型）
    const blit_core = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/paint.zig"),
    });
    blit_core.addImport("png", shared_modules.png.mod);
    blit_core.addImport("pixelops", shared_modules.pixelops.mod);
    blit_core.addImport("serde", shared_modules.serde.mod); // paint.zig → document_io（TASK-63）
    blit_core.addImport("font", shared_modules.font.mod); // paint.zig → canvas.zig → text_render.zig（TASK-79.5）
    const blit_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/blit.zig"),
        .target = target,
        .optimize = optimize,
    });
    blit_test_mod.addImport("paint", blit_core);
    const blit_test = b.addTest(.{ .root_module = blit_test_mod });
    const run_blit_test = b.addRunArtifact(blit_test);

    // onion_skin（TASK-45.3）。paint 内の表示専用オニオン合成。
    const onion_skin_test_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/onion_skin.zig"),
        .target = target,
        .optimize = optimize,
    });
    onion_skin_test_mod.addImport("pixelops", shared_modules.pixelops.mod);
    onion_skin_test_mod.addImport("png", shared_modules.png.mod);
    onion_skin_test_mod.addImport("serde", shared_modules.serde.mod);
    onion_skin_test_mod.addImport("font", shared_modules.font.mod);
    const onion_skin_test = b.addTest(.{ .root_module = onion_skin_test_mod });
    const run_onion_skin_test = b.addRunArtifact(onion_skin_test);

    // pixie palette（モデル + GIMP .gpl）。pure（std のみ・import 不要）。
    const palette_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/editor/apps/pixie/palette.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_palette_test = b.addRunArtifact(palette_test);

    // pixie action の純パーサ（TASK-64）。std のみ・App/kit 非依存で import 不要。
    const actions_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/editor/apps/pixie/actions.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_actions_test = b.addRunArtifact(actions_test);

    // pixie 視覚差分（TASK-87）。std のみ・App/kit 非依存で import 不要。
    const diff_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/editor/apps/pixie/diff.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_diff_test = b.addRunArtifact(diff_test);

    // history summary schema（TASK-62.5.5）。kit.platform.command 型を使うため default backend の kit を配線。
    const history_summary_pm = makePlatformModules(b, target, default_be, &shared_modules, false);
    const history_summary_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/history_summary.zig"),
        .target = target,
        .optimize = optimize,
    });
    history_summary_mod.addImport("kit", history_summary_pm.kit.mod);
    const history_summary_test = b.addTest(.{ .root_module = history_summary_mod });
    const run_history_summary_test = b.addRunArtifact(history_summary_test);
    const test_history_summary_step = b.step("test-history-summary", "Run history_summary schema unit tests (TASK-62.5.5)");
    test_history_summary_step.dependOn(&run_history_summary_test.step);

    // レイヤー名インライン編集の入力状態機械（TASK-79.3）。std のみ・paint/App/kit 非依存で import 不要。
    const layer_rename_input_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/editor/apps/pixie/layer_rename_input.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_layer_rename_input_test = b.addRunArtifact(layer_rename_input_test);

    // テキストレイヤー内容編集の入力状態機械（TASK-79.5）。layer_rename_input.zig と同じ設計
    // パターンの独立実装。std のみ・paint/App/kit 非依存で import 不要。
    const text_content_input_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/editor/apps/pixie/text_content_input.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_text_content_input_test = b.addRunArtifact(text_content_input_test);

    const test_core_step = b.step("test-core", "Run editor/core (undo + tool) and pixie input tests");
    test_core_step.dependOn(&run_core_undo_test.step);
    test_core_step.dependOn(&run_core_tool_test.step);
    test_core_step.dependOn(&run_core_fill_test.step);
    test_core_step.dependOn(&run_core_shape_test.step);
    test_core_step.dependOn(&run_core_bezier_test.step);
    test_core_step.dependOn(&run_core_path_test.step);
    test_core_step.dependOn(&run_core_path_editor_test.step);
    test_core_step.dependOn(&run_core_document_test.step);
    test_core_step.dependOn(&run_canvas_input_test.step);
    test_core_step.dependOn(&run_bezier_input_test.step);
    test_core_step.dependOn(&run_core_selection_test.step);
    test_core_step.dependOn(&run_selection_input_test.step);
    test_core_step.dependOn(&run_shape_input_test.step);
    test_core_step.dependOn(&run_eyedropper_input_test.step);
    test_core_step.dependOn(&run_palette_test.step);
    test_core_step.dependOn(&run_blit_test.step);
    test_core_step.dependOn(&run_onion_skin_test.step);
    test_core_step.dependOn(&run_brush_edge_cache_test.step);
    test_core_step.dependOn(&run_actions_test.step);
    test_core_step.dependOn(&run_diff_test.step);
    test_core_step.dependOn(&run_history_summary_test.step);
    test_core_step.dependOn(&run_layer_rename_input_test.step);
    test_core_step.dependOn(&run_text_content_input_test.step);

    // ========================================
    // PNG デコーダー format.zig テスト
    // ========================================
    const png_format_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("libs/png/src/format.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_png_format_test = b.addRunArtifact(png_format_test);
    const test_png_format_step = b.step("test-png-format", "Run PNG format conversion tests");
    test_png_format_step.dependOn(&run_png_format_test.step);

    // ========================================
    // platform_linux_input.zig テスト（X11 入力の純粋変換: keycode/modifier/EventQueue/KeyDownSet）
    // 純 Zig（@cImport なし）なので OS 非依存で host でも回る（TASK-28.3）
    // ========================================
    const platform_input_test_mod = b.createModule(.{
        .root_source_file = b.path("core/platform_linux_input.zig"),
        .target = target,
        .optimize = optimize,
    });
    platform_input_test_mod.addImport("platform_types", shared_modules.types.mod);
    const platform_input_test = b.addTest(.{ .root_module = platform_input_test_mod });
    const run_platform_input_test = b.addRunArtifact(platform_input_test);
    const test_platform_input_step = b.step("test-platform-input", "Run X11 input mapping/queue unit tests");
    test_platform_input_step.dependOn(&run_platform_input_test.step);

    // ========================================
    // platform_linux_convert.zig テスト（X11 pixel 変換の純粋ロジック: packPixel/maskShift/classifyVisual）
    // 純 Zig（@cImport なし）なので OS 非依存で host でも回る（TASK-28.6 / AC#4）
    // ========================================
    const platform_convert_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/platform_linux_convert.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_platform_convert_test = b.addRunArtifact(platform_convert_test);
    const test_platform_convert_step = b.step("test-platform-convert", "Run X11 pixel format conversion/visual classification unit tests");
    test_platform_convert_step.dependOn(&run_platform_convert_test.step);

    // ========================================
    // platform_wayland_input.zig テスト（Wayland 入力の純粋変換: evdev+8/BTN_*/wl_fixed/xkb modifier/
    // axis scroll/scroll coalesce/repeat timing）。純 Zig（@cImport なし）なので OS 非依存で host でも回る（TASK-28.5.3）
    // ========================================
    const platform_wayland_input_test_mod = b.createModule(.{
        .root_source_file = b.path("core/platform_wayland_input.zig"),
        .target = target,
        .optimize = optimize,
    });
    platform_wayland_input_test_mod.addImport("platform_types", shared_modules.types.mod);
    const platform_wayland_input_test = b.addTest(.{ .root_module = platform_wayland_input_test_mod });
    const run_platform_wayland_input_test = b.addRunArtifact(platform_wayland_input_test);
    const test_platform_wayland_input_step = b.step("test-platform-wayland-input", "Run Wayland input mapping/scroll/repeat unit tests");
    test_platform_wayland_input_step.dependOn(&run_platform_wayland_input_test.step);

    // ========================================
    // platform_wayland_csd.zig テスト（Wayland CSD 装飾の純ロジック: レイアウト/ヒットテスト/
    // window geometry ⇄ content サイズ変換/装飾描画）。純 Zig（@cImport なし）なので host でも回る（TASK-28.5.6）
    // ========================================
    const platform_wayland_csd_test_mod = b.createModule(.{
        .root_source_file = b.path("core/platform_wayland_csd.zig"),
        .target = target,
        .optimize = optimize,
    });
    const platform_wayland_csd_test = b.addTest(.{ .root_module = platform_wayland_csd_test_mod });
    const run_platform_wayland_csd_test = b.addRunArtifact(platform_wayland_csd_test);
    const test_platform_wayland_csd_step = b.step("test-platform-wayland-csd", "Run Wayland CSD decoration layout/hit-test/geometry/draw unit tests");
    test_platform_wayland_csd_step.dependOn(&run_platform_wayland_csd_test.step);

    // ========================================
    // platform_windows_input.zig テスト（Windows 入力の純粋変換: VK→KeyCode/modifier(post-state)/wheel 符号）
    // 純 Zig（@cImport なし）なので OS 非依存で host でも回る（TASK-31 / AC#3）
    // ========================================
    const platform_windows_input_test_mod = b.createModule(.{
        .root_source_file = b.path("core/platform_windows_input.zig"),
        .target = target,
        .optimize = optimize,
    });
    platform_windows_input_test_mod.addImport("platform_types", shared_modules.types.mod);
    const platform_windows_input_test = b.addTest(.{ .root_module = platform_windows_input_test_mod });
    const run_platform_windows_input_test = b.addRunArtifact(platform_windows_input_test);
    const test_platform_windows_input_step = b.step("test-platform-windows-input", "Run Windows input mapping/modifier/wheel unit tests");
    test_platform_windows_input_step.dependOn(&run_platform_windows_input_test.step);

    // ========================================
    // text.zig テスト (BDF パーサ + 描画)
    // ========================================
    const text_test_mod = b.createModule(.{
        .root_source_file = b.path("src/text.zig"),
        .target = target,
        .optimize = optimize,
    });
    text_test_mod.addImport("font", shared_modules.font.mod); // text.zig が共通 Font IF を利用
    const text_test = b.addTest(.{ .root_module = text_test_mod });
    const run_text_test = b.addRunArtifact(text_test);
    const test_text_step = b.step("test-text", "Run BDF parser and text rendering tests");
    test_text_step.dependOn(&run_text_test.step);

    // ========================================
    // sprite.zig テスト (blend4Pixels / drawSprite)
    // ========================================
    const sprite_test_png = b.createModule(.{
        .root_source_file = b.path("libs/png/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sprite_test_module = b.createModule(.{
        .root_source_file = b.path("src/sprite.zig"),
        .target = target,
        .optimize = optimize,
    });
    sprite_test_module.addImport("png", sprite_test_png);
    sprite_test_module.addImport("pixelops", shared_modules.pixelops.mod);
    const sprite_test = b.addTest(.{
        .root_module = sprite_test_module,
    });
    const run_sprite_test = b.addRunArtifact(sprite_test);
    const test_sprite_step = b.step("test-sprite", "Run sprite blending and drawing tests");
    test_sprite_step.dependOn(&run_sprite_test.step);

    // ========================================
    // libs/gui テスト (geom / color / draw / font + input / id / state / context)
    // gui.zig を root にすると参照する全ファイルの test がまとめて回る。
    // SharedModules.gui は import 用なので、test 用に専用 module を作る。
    // ========================================
    const gui_test_root = b.createModule(.{
        .root_source_file = b.path("libs/gui/src/gui.zig"),
        .target = target,
        .optimize = optimize,
    });
    gui_test_root.addImport("font", shared_modules.font.mod);
    gui_test_root.addImport("pixelops", shared_modules.pixelops.mod);
    gui_test_root.addImport("command_types", shared_modules.command_types.mod);
    const gui_test = b.addTest(.{ .root_module = gui_test_root });
    const run_gui_test = b.addRunArtifact(gui_test);
    const test_gui_step = b.step("test-gui", "Run libs/gui unit tests");
    test_gui_step.dependOn(&run_gui_test.step);

    // libs/font テスト (geom / color / Font インターフェース + カバレッジ描画路 + BMFont)
    const font_test_mod = b.createModule(.{
        .root_source_file = b.path("libs/font/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    font_test_mod.addImport("png", shared_modules.png.mod); // bmfont.zig が利用
    font_test_mod.addImport("pixelops", shared_modules.pixelops.mod); // color.zig が利用（TASK-51）
    const font_test = b.addTest(.{ .root_module = font_test_mod });
    const run_font_test = b.addRunArtifact(font_test);
    const test_font_step = b.step("test-font", "Run libs/font unit tests");
    test_font_step.dependOn(&run_font_test.step);

    // libs/synth テスト (SPSC リング / NoteQueue / atomic パラメータ / 出力タップ)
    const synth_test_mod = b.createModule(.{
        .root_source_file = b.path("libs/synth/src/synth.zig"),
        .target = target,
        .optimize = optimize,
    });
    synth_test_mod.addImport("dsp", shared_modules.dsp.mod);
    const synth_test = b.addTest(.{ .root_module = synth_test_mod });
    const run_synth_test = b.addRunArtifact(synth_test);
    const test_synth_step = b.step("test-synth", "Run libs/synth unit tests");
    test_synth_step.dependOn(&run_synth_test.step);

    // apps/synth action の純パーサ（TASK-65）。std のみ・App/kit/dsp 非依存で import 不要。
    const synth_actions_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/synth/actions.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_synth_actions_test = b.addRunArtifact(synth_actions_test);
    test_synth_step.dependOn(&run_synth_actions_test.step);

    // apps/synth 音色/FX パラメータ直列化（TASK-65 serialize）。std + serde のみ・App/kit 非依存。
    const synth_patch_io_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/synth/patch_io.zig"),
        .target = target,
        .optimize = optimize,
    });
    synth_patch_io_test_mod.addImport("serde", shared_modules.serde.mod);
    const synth_patch_io_test = b.addTest(.{ .root_module = synth_patch_io_test_mod });
    const run_synth_patch_io_test = b.addRunArtifact(synth_patch_io_test);
    test_synth_step.dependOn(&run_synth_patch_io_test.step);

    // libs/modular テスト（グラフエンジン: topo / cycle 遅延辺 / 単一接続 / per-sample / 可変 frames / 長時間レンダー）
    const modular_test_mod = b.createModule(.{
        .root_source_file = b.path("libs/modular/src/modular.zig"),
        .target = target,
        .optimize = optimize,
    });
    modular_test_mod.addImport("dsp", shared_modules.dsp.mod);
    const modular_test = b.addTest(.{ .root_module = modular_test_mod });
    const run_modular_test = b.addRunArtifact(modular_test);
    const test_modular_step = b.step("test-modular", "Run libs/modular unit tests");
    test_modular_step.dependOn(&run_modular_test.step);

    // apps/patch 生成レイヤテスト（LofiPatch の offline render: 非無音/有限/決定的 CRC）。
    const modular_app_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/patch/lofi.zig"),
        .target = target,
        .optimize = optimize,
    });
    modular_app_test_mod.addImport("modular", shared_modules.modular.mod);
    modular_app_test_mod.addImport("synth", shared_modules.synth.mod); // patch が AtomicF32 を使う（chunk B）
    modular_app_test_mod.addImport("dsp", shared_modules.dsp.mod); // patch が FFT で band energy を検証（Ph4）
    const modular_app_test = b.addTest(.{ .root_module = modular_app_test_mod });
    const run_modular_app_test = b.addRunArtifact(modular_app_test);
    const test_app_modular_step = b.step("test-app-modular", "Run apps/patch LofiPatch tests");
    test_app_modular_step.dependOn(&run_modular_app_test.step);

    // apps/patch generation action の純パーサ（TASK-65）。std のみ。
    const modular_actions_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/patch/gen_actions.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_modular_actions_test = b.addRunArtifact(modular_actions_test);
    test_app_modular_step.dependOn(&run_modular_actions_test.step);

    // apps/patch WAV writer（TASK-86）。std のみ・ストリーミング PCM16 RIFF/WAVE。
    const modular_wav_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/patch/wav.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_modular_wav_test = b.addRunArtifact(modular_wav_test);
    test_app_modular_step.dependOn(&run_modular_wav_test.step);

    // apps/patch scalar params + grid/303 pattern 直列化（TASK-65 serialize）。std + serde のみ・
    // App/kit/modular 非依存（PatternPayload は plain struct。main.zig 側で PatternCommand と変換）。
    const modular_pattern_io_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/patch/pattern_io.zig"),
        .target = target,
        .optimize = optimize,
    });
    modular_pattern_io_test_mod.addImport("serde", shared_modules.serde.mod);
    const modular_pattern_io_test = b.addTest(.{ .root_module = modular_pattern_io_test_mod });
    const run_modular_pattern_io_test = b.addRunArtifact(modular_pattern_io_test);
    test_app_modular_step.dependOn(&run_modular_pattern_io_test.step);

    // apps/patch プロジェクト直列化（TASK-91 MPRJ）。std + serde + pattern_io.PatternPayload。
    const modular_project_io_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/patch/project_io.zig"),
        .target = target,
        .optimize = optimize,
    });
    modular_project_io_test_mod.addImport("serde", shared_modules.serde.mod);
    const modular_project_io_test = b.addTest(.{ .root_module = modular_project_io_test_mod });
    const run_modular_project_io_test = b.addRunArtifact(modular_project_io_test);
    test_app_modular_step.dependOn(&run_modular_project_io_test.step);

    // apps/patch seed derive（TASK-62.5.7）。std のみ。
    const modular_seed_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/patch/seed.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_modular_seed_test = b.addRunArtifact(modular_seed_test);
    test_app_modular_step.dependOn(&run_modular_seed_test.step);

    // apps/patch CommandRecord 配線契約（TASK-62.5.7）。command は std のみ・既存 API 利用。
    const modular_cmd_seed_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/patch/cmd_seed_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    modular_cmd_seed_test_mod.addImport("command", command_test_mod);
    const modular_cmd_seed_test = b.addTest(.{ .root_module = modular_cmd_seed_test_mod });
    const run_modular_cmd_seed_test = b.addRunArtifact(modular_cmd_seed_test);
    test_app_modular_step.dependOn(&run_modular_cmd_seed_test.step);

    // apps/patch 純ロジックテスト集約 root（canvas: camera 変換 / hit-test / 見切れ検出 + group: グループ台帳 /
    // expose 導出 / 表示写像。display/audio 不要。TASK-40.6.2 / 40.7.1）
    const patch_tests_mod = b.createModule(.{
        .root_source_file = b.path("apps/patch/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    patch_tests_mod.addImport("gui", shared_modules.gui.mod);
    const patch_tests = b.addTest(.{ .root_module = patch_tests_mod });
    const run_patch_tests = b.addRunArtifact(patch_tests);
    const test_patch_step = b.step("test-patch", "Run apps/patch canvas + group logic tests");
    test_patch_step.dependOn(&run_patch_tests.step);

    // apps/patch action の純パーサ（TASK-65）。std のみ・App/kit/modular 非依存で import 不要。
    const patch_actions_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/patch/actions.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_patch_actions_test = b.addRunArtifact(patch_actions_test);
    test_patch_step.dependOn(&run_patch_actions_test.step);

    // apps/patch ノード/エッジ構成の直列化（TASK-65 serialize）。std + serde + modular（ModuleKind の
    // 単一ソース）のみ・App/kit/canvas 非依存。
    const patch_graph_io_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/patch/graph_io.zig"),
        .target = target,
        .optimize = optimize,
    });
    patch_graph_io_test_mod.addImport("serde", shared_modules.serde.mod);
    patch_graph_io_test_mod.addImport("modular", shared_modules.modular.mod);
    const patch_graph_io_test = b.addTest(.{ .root_module = patch_graph_io_test_mod });
    const run_patch_graph_io_test = b.addRunArtifact(patch_graph_io_test);
    test_patch_step.dependOn(&run_patch_graph_io_test.step);

    // apps/patch マクロ builder テスト（DrumMachine テンプレ: preflight/rollback/決定性/発音回帰。TASK-40.7.1）
    const patch_macro_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/patch/macro.zig"),
        .target = target,
        .optimize = optimize,
    });
    patch_macro_test_mod.addImport("modular", shared_modules.modular.mod);
    const patch_macro_test = b.addTest(.{ .root_module = patch_macro_test_mod });
    const run_patch_macro_test = b.addRunArtifact(patch_macro_test);
    const test_macro_step = b.step("test-macro", "Run apps/patch macro (DrumMachine template) tests");
    test_macro_step.dependOn(&run_patch_macro_test.step);

    // src/dsp テスト (Oscillator / Envelope / Filter / Mixer)
    const dsp_test_mod = b.createModule(.{
        .root_source_file = b.path("src/dsp/dsp.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dsp_test = b.addTest(.{ .root_module = dsp_test_mod });
    const run_dsp_test = b.addRunArtifact(dsp_test);
    const test_dsp_step = b.step("test-dsp", "Run src/dsp unit tests");
    test_dsp_step.dependOn(&run_dsp_test.step);

    // src/gamepad.zig テスト（getButtonName/justPressed/justReleased/applyDeadzone。TASK-80.1）。
    // platform_types のみに依存する headless lib（display/backend 不要）。
    const gamepad_test_mod = b.createModule(.{
        .root_source_file = b.path("src/gamepad.zig"),
        .target = target,
        .optimize = optimize,
    });
    gamepad_test_mod.addImport("platform_types", shared_modules.types.mod);
    const gamepad_test = b.addTest(.{ .root_module = gamepad_test_mod });
    const run_gamepad_test = b.addRunArtifact(gamepad_test);
    const test_gamepad_step = b.step("test-gamepad", "Run src/gamepad unit tests (ADR-009)");
    test_gamepad_step.dependOn(&run_gamepad_test.step);

    // apps/synth スペクトログラム解析テスト (FFT 列ロジック)
    const spec_test_mod = b.createModule(.{
        .root_source_file = b.path("libs/viz/src/spectrogram.zig"),
        .target = target,
        .optimize = optimize,
    });
    spec_test_mod.addImport("dsp", shared_modules.dsp.mod);
    const spec_test = b.addTest(.{ .root_module = spec_test_mod });
    const run_spec_test = b.addRunArtifact(spec_test);
    const test_spec_step = b.step("test-spectrogram", "Run apps/synth spectrogram tests");
    test_spec_step.dependOn(&run_spec_test.step);

    // apps/synth オシロスコープ / レベルメータ解析テスト (TASK-27.16, dsp 非依存)
    const scope_test_mod = b.createModule(.{
        .root_source_file = b.path("libs/viz/src/scope.zig"),
        .target = target,
        .optimize = optimize,
    });
    const scope_test = b.addTest(.{ .root_module = scope_test_mod });
    const run_scope_test = b.addRunArtifact(scope_test);
    const test_scope_step = b.step("test-scope", "Run apps/synth oscilloscope/level-meter tests");
    test_scope_step.dependOn(&run_scope_test.step);

    // ========================================
    // 集約 test ステップ (全 test-* を束ねる)
    // 注: ここはテスト実行のみ。example の build 回帰は通常の `zig build`（examples は常に全 backend install）で
    //     カバーされる。`-Dinstall-all=true` は main/pixie も全 backend install する用途。
    // ========================================
    const test_step = b.step("test", "Run all unit/integration tests");
    test_step.dependOn(test_png_roundtrip_step);
    test_step.dependOn(test_core_step);
    test_step.dependOn(test_png_format_step);
    test_step.dependOn(test_text_step);
    test_step.dependOn(test_sprite_step);
    test_step.dependOn(test_font_step);
    test_step.dependOn(test_gui_step);
    test_step.dependOn(test_synth_step);
    test_step.dependOn(test_modular_step);
    test_step.dependOn(test_app_modular_step);
    test_step.dependOn(test_patch_step);
    test_step.dependOn(test_macro_step);
    test_step.dependOn(test_dsp_step);
    test_step.dependOn(test_gamepad_step);
    test_step.dependOn(test_spec_step);
    test_step.dependOn(test_scope_step);
    test_step.dependOn(test_platform_input_step);
    test_step.dependOn(test_platform_convert_step);
    test_step.dependOn(test_platform_wayland_input_step);
    test_step.dependOn(test_platform_wayland_csd_step);
    test_step.dependOn(test_platform_windows_input_step);
    test_step.dependOn(test_harness_step);
    test_step.dependOn(test_mcp_step);
    test_step.dependOn(test_command_step);
    test_step.dependOn(test_command_types_step);
    test_step.dependOn(test_platform_menu_step);
    test_step.dependOn(test_copilot_step);
    test_step.dependOn(test_netsync_step);
    test_step.dependOn(test_audio_null_step);
    test_step.dependOn(test_platform_types_step);
    test_step.dependOn(test_platform_wasm_step);
    test_step.dependOn(test_capture_types_step);
    test_step.dependOn(test_pixelops_step);
    test_step.dependOn(test_serde_step);
    test_step.dependOn(test_appshell_step);
    test_step.dependOn(test_recipe_step);
    test_step.dependOn(test_gmath_step);

    // ========================================
    // マイクロベンチ（TASK-50）。純ロジック計測（display / audio デバイス不要・OS 非依存）。
    // optimize は ReleaseFast 固定: -Doptimize には従わない（Debug 計測事故の防止。
    // 前後比較の基準を常に同一最適化レベルに保つ）。
    // ========================================
    const bench_canvas_root = b.createModule(.{
        .root_source_file = b.path("bench/canvas.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    // bench 用 pixelops も ReleaseFast 固定で独立生成（共有インスタンスに引きずられない）
    const bench_pixelops_mod = b.createModule(.{
        .root_source_file = b.path("libs/pixelops/src/lib.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    // bench 用 png/font も ReleaseFast 固定で独立生成（bench_canvas_core が canvas.zig →
    // text_render.zig 経由で font を要するため、bench_gui 用の定義より前に前詰めする。TASK-79.5）。
    const bench_png_mod = b.createModule(.{
        .root_source_file = b.path("libs/png/src/lib.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench_font_mod = b.createModule(.{
        .root_source_file = b.path("libs/font/src/lib.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_font_mod.addImport("png", bench_png_mod);
    bench_font_mod.addImport("pixelops", bench_pixelops_mod);
    const bench_canvas_core = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/canvas.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_canvas_core.addImport("pixelops", bench_pixelops_mod);
    bench_canvas_core.addImport("font", bench_font_mod); // text_render.zig 経由（TASK-79.5）
    bench_canvas_root.addImport("editor_canvas", bench_canvas_core);
    const bench_canvas_exe = b.addExecutable(.{ .name = "bench_canvas", .root_module = bench_canvas_root });
    const bench_canvas_step = b.step("bench-canvas", "Run Canvas composite/compositeStraight micro-benchmark (ReleaseFast)");
    bench_canvas_step.dependOn(&b.addRunArtifact(bench_canvas_exe).step);

    // bench-yuyv（TASK-49.3）: V4L2 YUYV→BGRA の純粋な色変換を計測する。
    // camera backend は libc の ioctl/mmap を使うが、ベンチは純関数だけを呼ぶためデバイス不要。
    const bench_yuyv_root = b.createModule(.{
        .root_source_file = b.path("bench/yuyv.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    const bench_camera_v4l2_mod = b.createModule(.{
        .root_source_file = b.path("core/camera_v4l2.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    bench_camera_v4l2_mod.addImport("capture_types", shared_modules.capture_types.mod);
    bench_yuyv_root.addImport("camera_v4l2", bench_camera_v4l2_mod);
    const bench_yuyv_exe = b.addExecutable(.{ .name = "bench_yuyv", .root_module = bench_yuyv_root });
    const bench_yuyv_step = b.step("bench-yuyv", "Run YUYV to BGRA micro-benchmark (ReleaseFast)");
    bench_yuyv_step.dependOn(&b.addRunArtifact(bench_yuyv_exe).step);

    // bench 用に dsp/synth を ReleaseFast で独立生成（shared_modules の共有インスタンスは
    // 通常ビルドの optimize を引き継ぐため使わない）
    const bench_dsp_mod = b.createModule(.{
        .root_source_file = b.path("src/dsp/dsp.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench_synth_mod = b.createModule(.{
        .root_source_file = b.path("libs/synth/src/synth.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_synth_mod.addImport("dsp", bench_dsp_mod);
    const bench_synth_root = b.createModule(.{
        .root_source_file = b.path("bench/synth.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_synth_root.addImport("synth", bench_synth_mod);
    const bench_synth_exe = b.addExecutable(.{ .name = "bench_synth", .root_module = bench_synth_root });
    const bench_synth_step = b.step("bench-synth", "Run Synth.render / MasterEffects.process micro-benchmark (ReleaseFast)");
    bench_synth_step.dependOn(&b.addRunArtifact(bench_synth_exe).step);

    // bench-gui（TASK-58）: rect_filled / image / text の描画を public API 経由で計測
    // （bench_png_mod/bench_font_mod は上の bench_canvas_core 用に前詰め済み。TASK-79.5）
    const bench_gui_mod = b.createModule(.{
        .root_source_file = b.path("libs/gui/src/gui.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_gui_mod.addImport("font", bench_font_mod);
    bench_gui_mod.addImport("pixelops", bench_pixelops_mod);
    const bench_gui_root = b.createModule(.{
        .root_source_file = b.path("bench/gui.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_gui_root.addImport("gui", bench_gui_mod);
    const bench_gui_exe = b.addExecutable(.{ .name = "bench_gui", .root_module = bench_gui_root });
    const bench_gui_step = b.step("bench-gui", "Run GUI render (rect/image/text) micro-benchmark (ReleaseFast)");
    bench_gui_step.dependOn(&b.addRunArtifact(bench_gui_exe).step);

    // bench-blit（TASK-54）: pixie の canvas zoom 転送 + チェッカー背景（新旧比較を同時計測）
    const bench_blit_core = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/paint.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_blit_core.addImport("png", bench_png_mod);
    bench_blit_core.addImport("pixelops", bench_pixelops_mod);
    bench_blit_core.addImport("font", bench_font_mod); // paint.zig → canvas.zig → text_render.zig（TASK-79.5）
    const bench_blit_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/blit.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_blit_mod.addImport("paint", bench_blit_core);
    const bench_blit_root = b.createModule(.{
        .root_source_file = b.path("bench/blit.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_blit_root.addImport("blit", bench_blit_mod);
    bench_blit_root.addImport("paint", bench_blit_core);
    const bench_blit_exe = b.addExecutable(.{ .name = "bench_blit", .root_module = bench_blit_root });
    const bench_blit_step = b.step("bench-blit", "Run pixie canvas blit/checker micro-benchmark (ReleaseFast)");
    bench_blit_step.dependOn(&b.addRunArtifact(bench_blit_exe).step);

    // bench-modular（TASK-61）: DynGraph.processBlock の gen スキップ効果を計測。
    // modular は dsp のみ依存（test-modular と同じ）。ReleaseFast 固定で独立生成。
    const bench_modular_mod = b.createModule(.{
        .root_source_file = b.path("libs/modular/src/modular.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_modular_mod.addImport("dsp", bench_dsp_mod);
    const bench_modular_root = b.createModule(.{
        .root_source_file = b.path("bench/modular.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_modular_root.addImport("modular", bench_modular_mod);
    const bench_modular_exe = b.addExecutable(.{ .name = "bench_modular", .root_module = bench_modular_root });
    const bench_modular_step = b.step("bench-modular", "Run DynGraph.processBlock micro-benchmark (ReleaseFast)");
    bench_modular_step.dependOn(&b.addRunArtifact(bench_modular_exe).step);

    // bench-lofi（TASK-105.2）: LofiPatch.render の DynGraph 載せ替え前後を同一条件で比較。
    // patch は pure-test root と同じく modular/synth/dsp のみを必要とする。
    const bench_lofi_patch_mod = b.createModule(.{
        .root_source_file = b.path("apps/patch/lofi.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_lofi_patch_mod.addImport("modular", bench_modular_mod);
    bench_lofi_patch_mod.addImport("synth", bench_synth_mod);
    bench_lofi_patch_mod.addImport("dsp", bench_dsp_mod);
    const bench_lofi_root = b.createModule(.{
        .root_source_file = b.path("bench/lofi.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_lofi_root.addImport("patch", bench_lofi_patch_mod);
    const bench_lofi_exe = b.addExecutable(.{ .name = "bench_lofi", .root_module = bench_lofi_root });
    const bench_lofi_step = b.step("bench-lofi", "Run LofiPatch.render micro-benchmark (ReleaseFast)");
    bench_lofi_step.dependOn(&b.addRunArtifact(bench_lofi_exe).step);
}

// ============================================================
// exe / run-step 名: デフォルト backend は無印、他は "_<backend>" サフィックス
// （macOS: objc=無印 / swift / metal, Linux: x11=無印, Windows: gdi=無印 / d3d11）
// ============================================================
fn artifactName(b: *std.Build, base: []const u8, be: platform.PlatformType, default_be: platform.PlatformType) []const u8 {
    return if (be == default_be) base else b.fmt("{s}_{s}", .{ base, platform.backendName(be) });
}

// ============================================================
// backend ごとの platform / keyboard module を作る
// （platform module には build_options.platform_backend が付与される）
// ============================================================
const PlatformModules = struct {
    platform: TaggedModule, // ゲームパッド opt-in 無効（既定。main/pixie/synth/modular/patch/大半の example が使う。TASK-80.2 opt-in 化）
    platform_gamepad: TaggedModule, // ゲームパッド opt-in 有効（GameController framework をリンク。examples/22_gamepad 専用）
    keyboard: *std.Build.Module, // src/ レガシー（examples 専用。層管理外）
    kit: TaggedModule, // 公開 umbrella（ADR-007 R4）。apps はこれだけを import する（R5）。platform(opt-in無効) 側を配線
};

fn makePlatformModules(b: *std.Build, target: std.Build.ResolvedTarget, backend: platform.PlatformType, common: *const SharedModules, wasm_shared: bool) PlatformModules {
    // ゲームパッド opt-in 無効版（既定）。main/pixie/synth/modular/patch/example_01..21 はこちらを使う
    // （GameController framework 非リンク・.m/.swift の gamepad コードも条件コンパイルで除外。TASK-80.2 opt-in 化）。
    const platform_mod: TaggedModule = .{ .layer = .core, .name = "platform", .mod = platform.createPlatformModule(
        b,
        target,
        b.path("core/platform.zig"),
        b.path("platform"),
        backend,
        common.types.mod,
        common.command_types.mod,
        common.harness.mod,
        false,
    ) };
    // ゲームパッド opt-in 有効版。examples/22_gamepad だけがこちらを使う（GameController framework をリンクし、
    // .m/.swift の gamepad コードも有効化される）。同じ backend/types/harness から作るが build_options が異なるため
    // 別 Module インスタンスが必要（addOptions は Module 生成時に焼き込まれ、共有 Module では上書きできない）。
    const platform_gamepad_mod: TaggedModule = .{ .layer = .core, .name = "platform", .mod = platform.createPlatformModule(
        b,
        target,
        b.path("core/platform.zig"),
        b.path("platform"),
        backend,
        common.types.mod,
        common.command_types.mod,
        common.harness.mod,
        true,
    ) };
    // keyboard は KeyCode 型定義を platform から借りる（opt-in 無効側で十分。examples の keyboard 入力は
    // gamepad の有無に依存しない）。
    const keyboard_mod = b.createModule(.{
        .root_source_file = b.path("src/keyboard.zig"),
    });
    keyboard_mod.addImport("platform", platform_mod.mod);

    // kit umbrella（backend 毎。ADR-007 R4）。kit/kit.zig の pub import と 1:1 で揃えること。
    // pixie/synth/modular/patch はゲームパッド opt-in しないため opt-in 無効側の platform を配線する。
    const kit: TaggedModule = .{ .layer = .kit, .name = "kit", .mod = b.createModule(.{
        .root_source_file = b.path("kit/kit.zig"),
    }) };
    link(kit, platform_mod);
    link(kit, common.harness); // kit.control
    link(kit, common.types); // kit.types
    link(kit, common.command_types); // kit.command_types
    link(kit, common.audio);
    link(kit, common.gui);
    link(kit, common.png);
    link(kit, common.font);
    link(kit, common.dsp);
    link(kit, common.synth);
    link(kit, common.gamepad); // kit.gamepad（TASK-80.1）
    link(kit, common.recipe); // kit.recipe（TASK-62.5.8）
    link(kit, common.gmath); // kit.gmath（TASK-111.1）
    link(kit, common.appshell); // kit.appshell（TASK-114.1）

    // app_runtime（TASK-73）: frame-driven runtime。platform に依存するため backend 毎。
    // wasm shared audio（TASK-73.2）は single_threaded=false（atomics を本物にする）。
    const app_runtime: TaggedModule = .{ .layer = .core, .name = "app_runtime", .mod = b.createModule(.{
        .root_source_file = b.path("core/app_runtime.zig"),
        .target = target,
        .single_threaded = if (backend == .wasm) !wasm_shared else null,
    }) };
    link(app_runtime, platform_mod);
    link(kit, app_runtime);

    // wasm present の BGRA→RGBA SIMD swizzle（platform_wasm → pixelops）。
    // ADR-007 の core→lib 例外として linkCoreException 経由（素の addImport は不可）。
    if (backend == .wasm) {
        linkCoreException(platform_mod, common.pixelops, "wasm present の BGRA→RGBA SIMD swizzle（TASK-73.1）");
    }

    return .{ .platform = platform_mod, .platform_gamepad = platform_gamepad_mod, .keyboard = keyboard_mod, .kit = kit };
}

// ============================================================
// ヘルパー: メインアプリの exe を 1 backend 分セットアップ
// ============================================================
fn addMainExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    sdk_paths: ?macos.MacOSSDKPaths,
    platform_type: platform.PlatformType,
    name: []const u8,
    pm: *const PlatformModules,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // src/main.zig は apps/ 配下でないため R5（kit-only）対象外（examples と同じ従来配線）。
    exe.root_module.addImport("platform", pm.platform.mod);
    // ゲームパッド opt-in 無効（TASK-80.2 opt-in 化。main は gamepad を使わないため既存exe不変）。
    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths, false);
    return exe;
}

// ============================================================
// 共有モジュール (OS/backend 非依存)。29.1 の外部公開 module（addModule）も内包。
// 我々の exe / example は backend ごとの PlatformModules.platform を使うため、ここの platform/keyboard は
// 主に外部公開（dep.module("platform")）と test 用。
// ADR-007: 各共有 module は層タグ（TaggedModule）付きで生成し、配線は link() を通す。
// ============================================================
const SharedModules = struct {
    platform: TaggedModule, // 外部公開用 facade（backend build_options 無し。dep.module("platform")・test 用）
    keyboard: *std.Build.Module, // src/ レガシーヘルパー（examples 専用。層管理外）
    sprite: *std.Build.Module, // 同上
    fixed_timestep: *std.Build.Module, // 同上
    fps_counter: *std.Build.Module, // 同上
    text: *std.Build.Module, // 同上
    png: TaggedModule,
    font: TaggedModule,
    gui: TaggedModule,
    command_types: TaggedModule,
    audio: TaggedModule,
    synth: TaggedModule,
    modular: TaggedModule,
    dsp: TaggedModule,
    harness: TaggedModule,
    types: TaggedModule,
    pixelops: TaggedModule,
    gmath: TaggedModule,
    serde: TaggedModule, // libs/serde（versioned container 直列化基盤。TASK-62.2。std のみ）
    appshell: TaggedModule, // libs/appshell（設定 / window / recent files。TASK-114.1）
    recipe: TaggedModule, // libs/recipe（CommandRecord 列 save/replay。TASK-62.5.8。std + serde。kit 収録）
    paint: TaggedModule, // 旧 apps/editor/core（ADR-007 R6 で libs/paint へ格上げ）
    spectrogram: TaggedModule, // libs/viz（旧 apps/synth/spectrogram.zig）
    scope: TaggedModule, // libs/viz（旧 apps/synth/scope.zig）
    capture_types: TaggedModule, // capture 入力基盤の共有型（TASK-49.1。platform_types と同じ type-only）
    camera: TaggedModule, // カメラ L1 facade（TASK-49.1。audio と同格の core layer primitive）
    capture_synthetic: TaggedModule, // harness 内蔵 synthetic capture source（TASK-49.5。facade 配線は無い）
    objc_runtime: TaggedModule, // Objective-C ランタイム FFI（TASK-49.2。camera/audio 両方が link する共有 module。TASK-49.6 で named module 化）
    gamepad: TaggedModule, // src/gamepad.zig（ゲームパッド入力ヘルパー。TASK-80.1。platform_types のみに依存する headless lib。kit 収録）

    /// `wasm_shared`: TASK-73.2 AudioWorklet 用。atomics を有効にするため single_threaded=false。
    fn init(b: *std.Build, is_wasm: bool, wasm_shared: bool) SharedModules {
        // TASK-29.1: 外部公開 module（addModule）。dep.module("platform") で取得可能。
        // facade。@cImport("platform.h") のため link_libc + include path を内包。
        const platform_mod: TaggedModule = .{ .layer = .core, .name = "platform", .mod = b.addModule("platform", .{
            .root_source_file = b.path("core/platform.zig"),
            .link_libc = true,
        }) };
        platform_mod.mod.addIncludePath(b.path("platform"));
        // build_options.enable_gamepad（TASK-80.2 opt-in 化）: 外部消費者（tictactoe 等。dep.module("platform")）
        // 向けの facade も core/platform.zig を root にするため同じ named import が要る。外部消費者は
        // ゲームパッド opt-in を選べないため既定 false（GameController 非リンクの安全側）。
        {
            const opts = b.addOptions();
            opts.addOption(bool, "enable_gamepad", false);
            platform_mod.mod.addOptions("build_options", opts);
        }

        // keyboard は KeyCode 型定義を platform から借りる（src/ レガシー。examples 専用のため
        // 層管理外の素配線。apps へは配線しない）。
        const keyboard_mod = b.createModule(.{
            .root_source_file = b.path("src/keyboard.zig"),
        });
        keyboard_mod.addImport("platform", platform_mod.mod);

        // TASK-29.1: 外部公開 module。dep.module("png")。
        const png: TaggedModule = .{ .layer = .lib, .name = "png", .mod = b.addModule("png", .{
            .root_source_file = b.path("libs/png/src/lib.zig"),
        }) };

        // libs/pixelops: ピクセルブレンド共有プリミティブ（premul/straight blend + div255 +
        // clip-hoist。TASK-51）。sprite / paint blend / font Color.blend が委譲する。
        const pixelops: TaggedModule = .{ .layer = .lib, .name = "pixelops", .mod = b.createModule(.{
            .root_source_file = b.path("libs/pixelops/src/lib.zig"),
        }) };

        // libs/gmath: platform-independent f32 game math and collision primitives (TASK-111.1).
        // It is a stable L2-L3 library and is publicly exposed through kit.gmath.
        const gmath: TaggedModule = .{ .layer = .lib, .name = "gmath", .mod = b.addModule("gmath", .{
            .root_source_file = b.path("libs/gmath/src/lib.zig"),
        }) };

        // libs/serde: versioned container 直列化基盤（TASK-62.2）。std のみ依存（link 不要）。
        // 流動 lib のため kit 非収録・apps 直 import 許可（app_direct_ok=true）。第一 adopter は
        // pixie Document(TASK-63)。外部公開しないので createModule（addModule ではない）。
        const serde: TaggedModule = .{ .layer = .lib, .name = "serde", .app_direct_ok = true, .mod = b.createModule(.{
            .root_source_file = b.path("libs/serde/src/serde.zig"),
        }) };

        const appshell: TaggedModule = .{ .layer = .lib, .name = "appshell", .mod = b.createModule(.{
            .root_source_file = b.path("libs/appshell/src/appshell.zig"),
        }) };
        link(appshell, serde);

        // libs/recipe: CommandRecord 列の save/replay（TASK-62.5.8）。std + serde のみ。
        // kit 収録（apps は kit.recipe 経由。R5）。core 非依存。
        const recipe: TaggedModule = .{ .layer = .lib, .name = "recipe", .mod = b.createModule(.{
            .root_source_file = b.path("libs/recipe/src/recipe.zig"),
        }) };
        link(recipe, serde);

        // 共有型 module（platform_types）: KeyCode/Event/EventStats 等の単一ソース。
        // type-only（ADR-007 未決#1 の確定: libs が core から参照してよい唯一の module）。
        // platform module(facade+backends) と harness module が **同一インスタンス** を import して
        // 型同一性を保つ（Event/EventStats を harness↔platform 間で受け渡すため。TASK-32.2）。
        const types: TaggedModule = .{ .layer = .core, .name = "platform_types", .type_only = true, .mod = b.createModule(.{
            .root_source_file = b.path("core/platform_types.zig"),
        }) };
        link(platform_mod, types);

        // メニュー/command の共有型。platform_types と同じく type-only で、libs/gui と
        // platform facade が同一インスタンスを参照する。adapter は core 実行契約なので
        // 別の通常 core module として facade にだけ配線する。
        const command_types: TaggedModule = .{ .layer = .core, .name = "command_types", .type_only = true, .mod = b.createModule(.{
            .root_source_file = b.path("core/command_types.zig"),
        }) };
        link(command_types, types);
        link(platform_mod, command_types);

        // src/gamepad.zig: ゲームパッド入力ヘルパー（TASK-80.1。ADR-009）。platform_types のみに
        // 依存する headless lib（layer=.lib）。ADR-007 R2「libs が type-only core module を直接
        // 参照してよい唯一の形」の初適用（`link()` の `.lib => dep.layer==.core and dep.type_only` 分岐）。
        // keyboard 等の他 src/ ヘルパーと異なり kit にも収録するため TaggedModule 化する。
        const gamepad: TaggedModule = .{ .layer = .lib, .name = "gamepad", .mod = b.createModule(.{
            .root_source_file = b.path("src/gamepad.zig"),
        }) };
        link(gamepad, types);

        const sprite = b.createModule(.{
            .root_source_file = b.path("src/sprite.zig"),
        });
        sprite.addImport("png", png.mod);
        sprite.addImport("pixelops", pixelops.mod);

        // libs/font: 共通フォント抽象 + pixel/geom プリミティブの正準定義（gui より下層）
        // BMFont ローダ(bmfont.zig)が PNG アトラスを decode するため png に依存。
        // TASK-29.1: 外部公開 module。dep.module("font")。png に依存。
        const font: TaggedModule = .{ .layer = .lib, .name = "font", .mod = b.addModule("font", .{
            .root_source_file = b.path("libs/font/src/lib.zig"),
        }) };
        link(font, png);
        link(font, pixelops); // color.zig の Color.blend が委譲（TASK-51）

        // src/text.zig は共通 Font IF（libs/font）の実装を提供するため font に依存（TASK-25.14）。
        const text_mod = b.createModule(.{
            .root_source_file = b.path("src/text.zig"),
        });
        text_mod.addImport("font", font.mod);

        // TASK-29.1: 外部公開 module。dep.module("gui")。font に依存。
        const gui: TaggedModule = .{ .layer = .lib, .name = "gui", .mod = b.addModule("gui", .{
            .root_source_file = b.path("libs/gui/src/gui.zig"),
        }) };
        link(gui, font);
        link(gui, pixelops); // render.zig の drawImage SIMD（TASK-58）
        link(gui, command_types);

        // objc_runtime (L1): Objective-C ランタイム最小 FFI ヘルパー（TASK-49.2）。camera_macos.zig
        // （camera module）と audio_macos.zig（audio module。マイク権限確認）の両方が使うため、
        // named module として1個だけ作り両方に link する。`capture_types` と異なり型同一性が
        // 理由ではなく、「同一ファイルは2つの異なる module に属せない」という Zig の制約が本質
        // （camera/audio 双方が相対 `@import("objc_runtime.zig")` していたため、両 module を同一
        // exe に同時 link すると衝突していた。TASK-49.6: mic+camera を同時に使う初のデモで発覚。
        // 詳細は core/objc_runtime.zig の doc comment 参照）。std.c.nanosleep（権限確認の
        // ブロッキング待機）を使うため link_libc=true。
        const objc_runtime: TaggedModule = .{ .layer = .core, .name = "objc_runtime", .mod = b.createModule(.{
            .root_source_file = b.path("core/objc_runtime.zig"),
            .link_libc = true,
        }) };

        // audio (L1 オーディオ出力): platform バックエンド非依存。@cImport しないので
        // 通常の createModule でよい（audio system lib は exe 側で OS 別にリンク:
        // macOS=AudioToolbox / Linux=asound / Windows=ole32(WASAPI)。linkAudioBackend 参照）。
        const audio: TaggedModule = .{ .layer = .core, .name = "audio", .mod = b.createModule(.{
            .root_source_file = b.path("core/audio.zig"),
        }) };

        // harness（core/control。ヘッドレス検証 = 制御＋観測プレーン）: platform facade と
        // audio facade が共有する **単一インスタンス**。module-level state（audio tap 等）を
        // 1 exe 内で共有させるため、同じ harness を platform module(per-backend,
        // makePlatformModules→createPlatformModule) と audio module の両方に注入する (TASK-32.2)。
        // harness は png(encodePNG/crc32) に依存し getenv で link_libc。
        // wasm では harness_wasm.zig（no-op stub）に差し替え、png/capture_synthetic/dsp を張らない（TASK-73.1）。
        const harness: TaggedModule = .{
            .layer = .core,
            .name = "harness",
            .mod = b.createModule(.{
                .root_source_file = b.path(if (is_wasm) "core/control/harness_wasm.zig" else "core/control/harness.zig"),
                .link_libc = !is_wasm,
                // wasm non-shared (pixie): single_threaded。shared audio (synth): multi（atomics）。
                .single_threaded = if (is_wasm) !wasm_shared else null,
            }),
        };
        // command adapter は harness が保持する command module を facade が再 export する。
        link(harness, command_types);
        if (!is_wasm) {
            linkCoreException(harness, png, "snapshot fb の PNG encode / crc32。ADR-007 R1 の例外");
        }
        link(harness, types);
        // 公開 platform module（addModule "platform"）も harness 経由になるため伝播。
        link(platform_mod, harness);
        // audio facade（core/audio.zig）が `@import("harness")` で onAudioSamples を呼ぶ。
        link(audio, harness);
        // macOS: audio_macos.zig の capture(マイク) 拡張が objc_runtime 経由で権限確認を叩く。
        // wasm では audio_web が objc を触らないが、import 配線は無害（未参照なら解析されない）。
        if (!is_wasm) link(audio, objc_runtime);

        // capture 入力基盤の共有型（TASK-49.1）: control plane 共通型 + data plane 型
        // （DeviceInfo/PermissionState/CaptureError/AudioInFrame/PixelFormat/VideoFrame/TripleBuffer）。
        // platform_types と同じ type-only module。camera/audio の両方が同一インスタンスを link する
        // 必要がある（Zig の相対 import は module ごとに別インスタンスの型になるため、型同一性が
        // 要る共有型は named module 化が必須。詳細は docs/plans/capture-foundation-plan.md 8章）。
        const capture_types: TaggedModule = .{ .layer = .core, .name = "capture_types", .type_only = true, .mod = b.createModule(.{
            .root_source_file = b.path("core/capture_types.zig"),
        }) };
        // audio facade（core/audio.zig）の capture 拡張が `@import("capture_types")` で使う。
        link(audio, capture_types);

        // camera (L1 カメラ入力): audio と同格の core layer primitive（TASK-49.1）。49.1 時点は
        // 全 OS 共通の明示 stub（camera_stub.zig）を経由し、harness の isCaptureSyntheticActive()
        // 継ぎ目を持つ。TASK-49.2〜.4 が builtin.os.tag 分岐の実 backend へ置き換える。
        const camera: TaggedModule = .{ .layer = .core, .name = "camera", .mod = b.createModule(.{
            .root_source_file = b.path("core/camera.zig"),
        }) };
        link(camera, capture_types);
        link(camera, harness); // isCaptureSyntheticActive() 継ぎ目
        if (!is_wasm) link(camera, objc_runtime); // macOS: camera_macos.zig が objc_runtime 経由で AVFoundation を叩く

        // capture_synthetic (L1): harness 内蔵の synthetic capture source（偽 mic/camera。
        // TASK-49.5）。camera/audio facade への配線は無く、harness の組み込み `capture`
        // コマンド/probe だけが消費する（`isCaptureSyntheticActive()` の doc comment 参照）。
        // capture_types にのみ依存。std.c.nanosleep（audio 生成スレッドの実時間ペーシング）用に
        // link_libc=true（std.Thread.spawn 自体の要件ではなく POSIX sleep 側の理由。
        // core/audio_null.zig と同じ事情）。
        const capture_synthetic: TaggedModule = .{ .layer = .core, .name = "capture_synthetic", .mod = b.createModule(.{
            .root_source_file = b.path("core/capture_synthetic.zig"),
            .link_libc = true,
        }) };
        link(capture_synthetic, capture_types);
        // harness.zig が `@import("capture_synthetic")` で使う（`capture` コマンド/probe）。
        // wasm stub は capture_synthetic 非依存なので張らない（TASK-73.1）。
        if (!is_wasm) link(harness, capture_synthetic);

        // dsp (L2): Oscillator / Envelope / Filter / Mixer。純 Zig。
        // （物理位置は src/dsp のまま。libs/audio への移動は R8 日和見で後続タスクにて）
        const dsp: TaggedModule = .{ .layer = .lib, .name = "dsp", .mod = b.createModule(.{
            .root_source_file = b.path("src/dsp/dsp.zig"),
        }) };
        // TASK-92: digest audio の band/centroid/onset が magnitudeSpectrum を使う。
        // harness は dsp 定義後に link（png と同様 linkCoreException。ADR-007 追記済み）。
        // wasm stub は dsp 非依存なので張らない。
        if (!is_wasm) linkCoreException(harness, dsp, "digest audio のスペクトル解析（band/centroid/onset）");

        // synth (L3): Voice/VoicePool/Patch/Synth + GUI⇔Audio 受け渡し機構。dsp に依存。
        const synth: TaggedModule = .{ .layer = .lib, .name = "synth", .mod = b.createModule(.{
            .root_source_file = b.path("libs/synth/src/synth.zig"),
        }) };
        link(synth, dsp);

        // modular (L3): モジュラー・グラフエンジン（TASK-40）。dsp のみに依存。
        // 流動中のため kit 非収録（apps が直 import: app_direct_ok）。
        const modular: TaggedModule = .{ .layer = .lib, .name = "modular", .app_direct_ok = true, .mod = b.createModule(.{
            .root_source_file = b.path("libs/modular/src/modular.zig"),
        }) };
        link(modular, dsp);

        // paint（旧 apps/editor/core。R6 で libs へ格上げ）: Canvas/Tool/Undo/Selection/PNG I/O。
        // 「エディタ族の共有 lib」で汎用 kit には載せない（pixie 等の該当 app だけが直 import）。
        const paint: TaggedModule = .{ .layer = .lib, .name = "paint", .app_direct_ok = true, .mod = b.createModule(.{
            .root_source_file = b.path("libs/paint/src/paint.zig"),
        }) };
        link(paint, png); // io_png.zig が PNG codec(libs/png) に委譲 (TASK-33)
        link(paint, pixelops); // blend.zig が委譲 (TASK-51)
        link(paint, serde); // document_io.zig が versioned container(libs/serde) に委譲 (TASK-63)
        link(paint, font); // canvas.zig → text_render.zig がテキストラスタライズに委譲 (TASK-79.5)

        // libs/viz（旧 apps/synth の可視化。synth/modular/patch の 3 app が共有するため
        // R6 の「再利用 vs 終端」で libs へ。流動中のため kit 非収録）。
        const spectrogram: TaggedModule = .{ .layer = .lib, .name = "spectrogram", .app_direct_ok = true, .mod = b.createModule(.{
            .root_source_file = b.path("libs/viz/src/spectrogram.zig"),
        }) };
        link(spectrogram, dsp); // FFT
        const scope: TaggedModule = .{ .layer = .lib, .name = "scope", .app_direct_ok = true, .mod = b.createModule(.{
            .root_source_file = b.path("libs/viz/src/scope.zig"),
        }) };

        return .{
            .platform = platform_mod,
            .keyboard = keyboard_mod,
            .sprite = sprite,
            .fixed_timestep = b.createModule(.{
                .root_source_file = b.path("src/fixed_timestep.zig"),
            }),
            .fps_counter = b.createModule(.{
                .root_source_file = b.path("src/fps_counter.zig"),
            }),
            .text = text_mod,
            .png = png,
            .font = font,
            .gui = gui,
            .command_types = command_types,
            .audio = audio,
            .synth = synth,
            .modular = modular,
            .dsp = dsp,
            .harness = harness,
            .types = types,
            .pixelops = pixelops,
            .gmath = gmath,
            .serde = serde,
            .appshell = appshell,
            .recipe = recipe,
            .paint = paint,
            .spectrogram = spectrogram,
            .scope = scope,
            .capture_types = capture_types,
            .camera = camera,
            .capture_synthetic = capture_synthetic,
            .objc_runtime = objc_runtime,
            .gamepad = gamepad,
        };
    }
};

const ExampleNeeds = struct {
    needs_sprite: bool,
    needs_fps_counter: bool,
    needs_fixed_timestep: bool,
    needs_text: bool,
    needs_gui: bool,
    needs_png: bool,
    needs_font: bool,
    needs_audio: bool,
    needs_gamepad: bool, // TASK-80.1（examples/22_gamepad のみ true）
    needs_gmath: bool, // TASK-111.1（examples/25_collision_demo のみ true）
};

// ============================================================
// ヘルパー: example の exe を 1 backend 分セットアップ
// platform / keyboard は backend ごとの pm から、その他の共有 module は common から取る。
// ============================================================
fn addExampleExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    sdk_paths: ?macos.MacOSSDKPaths,
    platform_type: platform.PlatformType,
    name: []const u8,
    source_path: []const u8,
    common: *const SharedModules,
    pm: *const PlatformModules,
    needs: ExampleNeeds,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source_path),
            .target = target,
            .optimize = optimize,
        }),
    });
    // 全 example が platform / keyboard を使う
    // （examples は教材として R5=kit-only の対象外。従来の個別 module 配線を維持する）
    // ゲームパッド opt-in（TASK-80.2 opt-in 化）: needs_gamepad の example（22_gamepad のみ）だけ
    // opt-in 有効側の platform module を使う（GameController framework リンク + .m/.swift の
    // gamepad コード有効化）。他の example は既定の opt-in 無効側（既存exe不変）。
    exe.root_module.addImport("platform", if (needs.needs_gamepad) pm.platform_gamepad.mod else pm.platform.mod);
    exe.root_module.addImport("keyboard", pm.keyboard);
    if (needs.needs_sprite) exe.root_module.addImport("sprite", common.sprite);
    if (needs.needs_fps_counter) exe.root_module.addImport("fps_counter", common.fps_counter);
    if (needs.needs_fixed_timestep) exe.root_module.addImport("fixed_timestep", common.fixed_timestep);
    if (needs.needs_text) exe.root_module.addImport("text", common.text);
    if (needs.needs_gui) exe.root_module.addImport("gui", common.gui.mod);
    if (needs.needs_png) exe.root_module.addImport("png", common.png.mod);
    if (needs.needs_font) exe.root_module.addImport("font", common.font.mod);
    if (needs.needs_audio) {
        exe.root_module.addImport("audio", common.audio.mod);
        // L1 オーディオ出力の system ライブラリ（needs_audio の exe にのみ付与。OS 別）。
        linkAudioBackend(exe, target.result.os.tag);
    }
    // gamepad は platform_types のみに依存する backend 非依存 lib（TASK-80.1）。common（SharedModules）から
    // 直接 addImport する（kit を使わない examples の既存慣習に揃える）。
    if (needs.needs_gamepad) exe.root_module.addImport("gamepad", common.gamepad.mod);
    if (needs.needs_gmath) exe.root_module.addImport("gmath", common.gmath.mod);
    if (std.mem.startsWith(u8, name, "example_26")) {
        exe.root_module.addImport("kit", pm.kit.mod);
        exe.root_module.addImport("appshell", common.appshell.mod);
    }

    // build_options: 起動時バナーで platform 名 / build mode を表示する用途。
    // 任意の example が `@import("build_options").platform_name` で参照可能。
    // （platform module 側の build_options.platform_backend とは別 module スコープ）
    const opts = b.addOptions();
    opts.addOption([]const u8, "platform_name", platform.backendName(platform_type));
    exe.root_module.addOptions("build_options", opts);

    // ゲームパッド opt-in（TASK-80.2 opt-in 化）: needs.needs_gamepad の exe だけ GameController framework
    // リンク + .m/.swift gamepad コード有効化（上の addImport 選択と揃える）。
    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths, needs.needs_gamepad);
    return exe;
}

// ============================================================
// ヘルパー: pixie exe を 1 backend 分セットアップ
// ============================================================
fn addPixieExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    sdk_paths: ?macos.MacOSSDKPaths,
    platform_type: platform.PlatformType,
    name: []const u8,
    common: *const SharedModules,
    pm: *const PlatformModules,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/editor/apps/pixie/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // apps は kit-only 消費者（R5）。paint は「エディタ族の共有 lib」（kit 非収録・流動）で直 import。
    const root = appRoot(exe, "pixie");
    link(root, pm.kit);
    link(root, common.paint);

    // ゲームパッド opt-in 無効（TASK-80.2 opt-in 化。このアプリは gamepad を使わないため既存exe不変）。
    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths, false);
    return exe;
}

// ============================================================
// ヘルパー: patch app exe を 1 backend 分セットアップ（apps/patch。TASK-40.6.2/40.6.3/40.7.1）
// platform + gui + modular（動的グラフエンジン）+ audio（40.6.3 ライブ再配線で発音）。
// canvas.zig/group.zig/macro.zig は main.zig からの相対 @import（同一 module）で取り込む
// （apps/patch/main.zig が lofi.zig を相対 import する構成。macro.zig の
// @import("modular") はこの exe.root_module に登録済みの "modular" named import をそのまま解決できる）。
// ============================================================
fn addPatchExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    sdk_paths: ?macos.MacOSSDKPaths,
    platform_type: platform.PlatformType,
    name: []const u8,
    common: *const SharedModules,
    pm: *const PlatformModules,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/patch/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // apps は kit-only 消費者（R5）。platform/gui/audio/synth/dsp は kit.* で参照。
    // modular / 可視化（libs/viz）は流動中で kit 非収録のため直 import。
    const root = appRoot(exe, "patch");
    link(root, pm.kit);
    link(root, common.modular); // 動的グラフエンジン（dsp 依存のみ。macro.zig も参照）
    link(root, common.spectrogram); // TASK-40.8: 信号可視化（master scope/spectrogram/level meter）
    link(root, common.scope);
    link(root, common.serde); // graph_io.zig（TASK-65 serialize: ノード/エッジ構成の versioned container 直列化）
    linkAppException(root, common.synth, "apps/patch/lofi.zig が生成レイヤを直接利用（SampleTap / AtomicF32）");
    linkAppException(root, common.dsp, "apps/patch/lofi.zig が生成レイヤを直接利用（FFT band energy 検証）");
    linkAudioBackend(exe, target.result.os.tag); // macOS=AudioToolbox / Linux=asound / Windows=ole32

    // ゲームパッド opt-in 無効（TASK-80.2 opt-in 化。このアプリは gamepad を使わないため既存exe不変）。
    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths, false);
    return exe;
}

// ============================================================
// ヘルパー: synth app exe を 1 backend 分セットアップ（macOS/Linux/Windows。audio system lib を link）
// ============================================================
fn addSynthExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    sdk_paths: ?macos.MacOSSDKPaths,
    platform_type: platform.PlatformType,
    name: []const u8,
    common: *const SharedModules,
    pm: *const PlatformModules,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/synth/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // apps は kit-only 消費者（R5）。platform/audio/synth/dsp/gui は kit.* で参照。
    // 可視化（libs/viz。流動中で kit 非収録）+ serde（TASK-65 serialize: patch_io.zig が直 import）だけ直 import。
    const root = appRoot(exe, "synth");
    link(root, pm.kit);
    link(root, common.spectrogram);
    link(root, common.scope);
    link(root, common.serde); // patch_io.zig（音色/FX パラメータの versioned container 直列化）
    linkAudioBackend(exe, target.result.os.tag); // L1 オーディオ出力（macOS=AudioToolbox / Linux=asound / Windows=ole32）

    // ゲームパッド opt-in 無効（TASK-80.2 opt-in 化。このアプリは gamepad を使わないため既存exe不変）。
    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths, false);
    return exe;
}

// ============================================================================
// ヘルパー: 20_capture_demo exe を 1 backend 分セットアップ（examples/20_capture_demo。TASK-49.6）。
//
// R5(kit-only) は apps/ のみが対象で examples は対象外（build.zig 冒頭コメント）なので、他 example
// と同じ「直 addImport」配線を使う（appRoot/link() は使わない）。camera/audio/capture_synthetic
// （いずれも core layer）を直接消費するのは、headless 検証に harness 内蔵の synthetic capture
// source（core/capture_synthetic.zig。TASK-49.5。camera.zig/audio.zig facade へは配線されていない
// 独立モジュール）への直 import が必須なため（apps 層からは R5 で到達できない）。
// camera.zig/audio.zig の facade API 自体は本タスクで変更しない（consume に徹する）。
// ============================================================================
fn addCaptureDemoExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    sdk_paths: ?macos.MacOSSDKPaths,
    platform_type: platform.PlatformType,
    name: []const u8,
    common: *const SharedModules,
    pm: *const PlatformModules,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/20_capture_demo/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("platform", pm.platform.mod);
    exe.root_module.addImport("harness", common.harness.mod); // isCaptureSyntheticActive() 判定用
    exe.root_module.addImport("camera", common.camera.mod); // カメラ実 capture（macOS 実装 / 他OS stub。TASK-49.2）
    exe.root_module.addImport("audio", common.audio.mod); // マイク実 capture 拡張（audio.zig 経由。TASK-49.2）
    exe.root_module.addImport("capture_synthetic", common.capture_synthetic.mod); // harness 内蔵 synthetic source（TASK-49.5。VP_HARNESS_CAPTURE_SYNTHETIC=1 時のみ使用）
    exe.root_module.addImport("spectrogram", common.spectrogram.mod);
    exe.root_module.addImport("scope", common.scope.mod);
    exe.root_module.addImport("synth", common.synth.mod); // SampleTap（mic capture callback → メインスレッド可視化のロックフリー受け渡し）
    linkAudioBackend(exe, target.result.os.tag); // macOS: AudioToolbox/CoreAudio + capture 用 AVFoundation/CoreMedia/CoreVideo/Foundation/objc も含む

    // ゲームパッド opt-in 無効（TASK-80.2 opt-in 化。このアプリは gamepad を使わないため既存exe不変）。
    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths, false);
    return exe;
}

// ============================================================
// ヘルパー: audio を使う exe に L1 出力の system ライブラリを OS 別にリンクする。
// audio module は @cImport せず extern fn なので、リンクは exe 側で行う
// （macOS=AudioToolbox framework / Linux=ALSA libasound）。libc は backend setup 側で有効化済み。
//
// Linux は pkg-config 名 "alsa"（.pc は alsa-lib-dev が提供）を渡す。これで pkg-config が
// `-lasound` と lib パスの両方を解決する。ライブラリ名 "asound" を直接渡すと .pc が無く、
// zig は既存の -L（X11 等）しか探さず libasound.so を見つけられない（Linux 実ビルドで確認）。
// ============================================================
fn linkAudioBackend(exe: *std.Build.Step.Compile, target_os: std.Target.Os.Tag) void {
    switch (target_os) {
        // capture（mic AUHAL input / camera AVFoundation。TASK-49.2）の framework も併せてリンク
        // する。呼び出し側の全 exe は `platform.setupExecutableForPlatform` を同じ関数内で呼んで
        // おり、そちらが `-F <sdk>/System/Library/Frameworks` / `-L <sdk>/usr/lib` の検索パスを
        // 設定する（`build_helpers/macos.zig` の `addMacOSSDKSearchPaths`）ため、ここでは
        // `linkFramework`/`linkSystemLibrary` の呼び出しだけで足りる（build graph 構築順序は
        // 実際のリンク時の解決に影響しない）。codex レビュー指摘: capture を実使用する将来の
        // アプリ（TASK-49.6 想定）がこの関数を素通しした時にリンク不足で壊れないようにする
        // 予防的追加（現時点でこれらの framework を実際に使う exe はまだ無い＝害が無い）。
        .macos => {
            exe.root_module.linkFramework("AudioToolbox", .{});
            exe.root_module.linkFramework("CoreAudio", .{});
            exe.root_module.linkFramework("AVFoundation", .{});
            exe.root_module.linkFramework("CoreMedia", .{});
            exe.root_module.linkFramework("CoreVideo", .{});
            exe.root_module.linkFramework("Foundation", .{});
            exe.root_module.linkSystemLibrary("objc", .{});
        },
        .linux => exe.root_module.linkSystemLibrary("alsa", .{}),
        // WASAPI は COM 経由。CoCreateInstance/CoInitializeEx/CoTaskMemFree が ole32 にある
        // （IAudioClient 等は COM で取得するので直接リンク不要。Event API は kernel32=自動リンク）。
        .windows => exe.root_module.linkSystemLibrary("ole32", .{}),
        else => @panic("audio backend is only available on macOS / Linux / Windows"),
    }
}

// ============================================================
// capture（mic AUHAL input / camera AVFoundation。TASK-49.2）専用 test 用の framework リンク。
// nix の zig は SDK を自動検出しないため framework/library 検索パスを明示する
// （`build_helpers/macos.zig` の `addMacOSSDKSearchPaths` と同じ理由・同じパス）。
// `linkAudioBackend` と異なり、こちらは `platform.setupExecutableForPlatform` を経由しない
// 素の `b.addTest` 向けなので検索パス自体もここで明示する必要がある。
// ============================================================
fn linkCaptureMacFrameworks(b: *std.Build, mod: *std.Build.Module, sdk_paths: macos.MacOSSDKPaths) void {
    mod.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk_paths.sdk_path}) });
    mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk_paths.sdk_path}) });
    mod.linkFramework("AudioToolbox", .{});
    mod.linkFramework("CoreAudio", .{});
    mod.linkFramework("AVFoundation", .{});
    mod.linkFramework("CoreMedia", .{});
    mod.linkFramework("CoreVideo", .{});
    mod.linkFramework("Foundation", .{});
    mod.linkSystemLibrary("objc", .{});
}

// ============================================================
// 一般的な run ステップ追加ヘルパー
// ============================================================
fn addRunStep(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    exe: *std.Build.Step.Compile,
    args: ?[]const []const u8,
) void {
    const run_cmd = b.addRunArtifact(exe);
    // 注: あえて b.getInstallStep() に依存させない。getInstallStep は全 installArtifact
    // （example 全 backend を含む）を束ねるため、依存させると run-* が全 example を
    // 芋づる式にビルドしてしまう。run には当該 exe のコンパイルだけで十分なので、
    // addRunArtifact が自動で張る exe ビルド依存に留める（cache から直接実行）。
    if (args) |a| run_cmd.addArgs(a);
    const run_step = b.step(name, description);
    run_step.dependOn(&run_cmd.step);
}

// ============================================================
// ビルドのみ（実行しない）の step 追加ヘルパー
// 当該 exe だけを install（= ビルド）する。getInstallStep には依存させないので
// 他の exe / example を巻き込まない（run-* と同じ理由）。
// ============================================================
fn addBuildStep(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    exe: *std.Build.Step.Compile,
) void {
    const build_step = b.step(name, description);
    build_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
}

// ============================================================
// ヘルパー: platform native 層を static lib (object archive) として公開 (TASK-29.1)
//
// 外部パッケージは `dep.artifact("platform_native_<plat>")` を linkLibrary する。
// facade は `dep.module("platform")`。compilePlatformLayer の .o を最小 stub module に
// addObjectFile して archive するだけに徹する。framework / Swift ランタイム / 検索パスは
// static lib ビルド時に解決できず（検索パスは consumer へ伝播もしない）、consumer の exe 側で
// 適用する（29.2 の C 方式: macos/swift build_helper を vendoring して exe に適用）。
// ============================================================
fn addPlatformNativeLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    platform_type: platform.PlatformType,
    name: []const u8,
) *std.Build.Step.Compile {
    // ゲームパッド opt-in 無効（TASK-80.2 opt-in 化）。外部消費者向け native archive は
    // SharedModules の外部公開 "platform" module（build_options.enable_gamepad=false）と対で
    // GameController framework を一切参照しない .o にする（consumer 側で framework 検索パスを
    // 解決できないのと同じ理由で、opt-in も consumer 側に委ねない）。
    const compiled = platform.compilePlatformLayer(b, platform_type, optimize, platform_root, false);

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("core/platform_native_stub.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addObjectFile(compiled.obj_file);
    // framework / Swift ランタイム / framework・library 検索パスは static lib ビルド時に
    // 解決できず（`unable to find framework` になる）、検索パスは consumer へ伝播もしない。
    // よってここは .o を archive することに徹し、リンク設定は consumer の exe 側で適用する
    // （29.2 の C 方式: macos.linkMacOSFrameworks / swift.linkSwiftRuntime を vendoring）。

    const lib = b.addLibrary(.{
        .name = name,
        .linkage = .static,
        .root_module = lib_mod,
    });
    lib.step.dependOn(&compiled.compile_step.step);
    // consumer の @cImport("platform.h") 用に header を install（linkLibrary の
    // installed-headers-include-tree 経路の健全性も確保）。
    lib.installHeader(b.path("platform/platform.h"), "platform.h");
    b.installArtifact(lib);
    return lib;
}
