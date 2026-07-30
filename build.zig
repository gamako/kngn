const std = @import("std");

const platform = @import("build_helpers/platform.zig");
const macos = @import("build_helpers/macos.zig");

const APP_NAME = "kngn_demo";

// ============================================================
// ADR-007 R1: layer tags and dependency wiring checks
//
// Enforce one-way dependency apps → (kit) → libs → core → platform in the build graph.
// Shared modules (SharedModules / PlatformModules) must always go through link() /
// linkCoreException() / linkAppException(). Bare addImport is allowed only for
//   - wiring exe/test/bench to a module-internal root (not a cross-layer shared module)
//   - wiring examples/ and legacy src/ helpers (keyboard/sprite/text, etc.)
//     (R5 kit-only enforcement targets apps/ only; examples keep legacy wiring as teaching material)
// the cases above.
//
// Violations stop via std.debug.panic (= build-configuration error). Module roots live in
// each layer's directory, so a relative @import into an unwired layer becomes
// an "import of file outside module path" compile error (physical isolation).
// ============================================================

const Layer = enum(u8) {
    // L0 platform/ (native .o / C ABI) is not a Zig module, so it does not appear here.
    core = 1, // L1 thin base: core/ (platform facade + audio facade + control)
    lib = 2, // L2-L3 portable libs: libs/ (headless; no dependency on platform implementations)
    kit = 3, // Public umbrella: kit/ (R4)
    app = 4, // L4 terminal consumers: apps/
};

const TaggedModule = struct {
    mod: *std.Build.Module,
    layer: Layer,
    /// Import name (the consumer's `@import("<name>")`).
    name: []const u8,
    /// Allow apps to import a flux lib directly (ADR-007 maturity gate: not in kit, but apps may
    /// direct-import it as "internal / may break": modular / paint / spectrogram / scope / serde).
    /// Kit-listed libs and core stay false.
    app_direct_ok: bool = false,
    /// Type-only module (platform_types). The only core form libs may reference (see ADR-007).
    type_only: bool = false,
};

/// Layer-checked wiring. Violations panic at build configuration time.
fn link(consumer: TaggedModule, dep: TaggedModule) void {
    const ok = switch (consumer.layer) {
        // apps may use kit only (R5). Flux libs (app_direct_ok) alone may be direct-imported as "internal / may break".
        .app => dep.layer == .kit or (dep.layer == .lib and dep.app_direct_ok),
        // kit re-exports core and stable libs (R4).
        .kit => dep.layer == .core or dep.layer == .lib,
        // libs may use other libs plus type-only core modules (platform_types) only (R2).
        .lib => dep.layer == .lib or (dep.layer == .core and dep.type_only),
        // core may use other core only (exceptions harness→png / harness→dsp / platform→pixelops go through linkCoreException).
        .core => dep.layer == .core,
    };
    if (!ok) std.debug.panic(
        "ADR-007 R1 dependency direction violation: {s}({s}) → {s}({s}). Only one-way apps→kit→libs→core is allowed.",
        .{ consumer.name, @tagName(consumer.layer), dep.name, @tagName(dep.layer) },
    );
    consumer.mod.addImport(dep.name, dep.mod);
}

/// Explicit core → libs exceptions. Current set:
///   - harness(core/control) → png(libs/png) (PNG encode / crc32 for snapshot fb)
///   - harness(core/control) → dsp (digest audio spectrum analysis: band/centroid/onset)
///   - platform(core) → pixelops(libs/pixelops) (BGRA→RGBA SIMD swizzle for wasm present)
/// Adding a new exception requires revising ADR-007.
fn linkCoreException(consumer: TaggedModule, dep: TaggedModule, comptime reason: []const u8) void {
    comptime std.debug.assert(reason.len > 0);
    std.debug.assert(consumer.layer == .core and dep.layer == .lib);
    consumer.mod.addImport(dep.name, dep.mod);
}

/// app → lib direct-import exceptions. The full set is the linkAppException call sites:
///   - example_26 → paint; apps/noodle/lofi.zig → synth / dsp (keeps a pure-test root platform-free)
/// A kit-listed dep is the same module instance kit exposes, so type identity holds.
/// (pixie / noodle use kit.pixelops; they do not need a direct pixelops exception.)
fn linkAppException(consumer: TaggedModule, dep: TaggedModule, comptime reason: []const u8) void {
    comptime std.debug.assert(reason.len > 0);
    std.debug.assert(consumer.layer == .app and dep.layer == .lib);
    consumer.mod.addImport(dep.name, dep.mod);
}

/// Wrap an app exe root module with a layer tag (as a link() consumer).
fn appRoot(exe: *std.Build.Step.Compile, name: []const u8) TaggedModule {
    return .{ .mod = exe.root_module, .layer = .app, .name = name };
}

/// Shared web assets for the in-tree `package-web` layout.
fn defaultWasmWebAssets(b: *std.Build) platform.WasmWebAssets {
    return .{
        .js = b.path("web/kngn.js"),
        .worklet = b.path("web/kngn-worklet.js"),
        .headers = b.path("web/deploy/_headers"),
        .netlify = b.path("web/deploy/netlify.toml"),
        .serve_script = b.path("web/deploy/serve-coop-coep.py"),
        .packer = b.path("cli/pack-single-html.zig"),
    };
}

/// Root-only linker: SharedModules + makePlatformModules + layer-checked `link()`.
/// Keeps TaggedModule / flux wiring out of the public consumer surface.
fn makeInternalWasmLinker(b: *std.Build) platform.WasmLinker {
    const Ctx = struct {
        b: *std.Build,

        fn apply(ctx_ptr: *anyopaque, link_ctx: platform.WasmLinkContext) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            const bb = self.b;
            const target = link_ctx.app_module.resolved_target orelse {
                std.debug.panic("internal wasm linker: app module has no resolved target", .{});
            };

            // wasm_shared=false → single_threaded on platform modules (wasm_allocator).
            // Atomics for shared-memory apps come from the target feature set, not multi-threaded Zig.
            const wasm_max_opts = bb.addOptions();
            wasm_max_opts.addOption(usize, "max_modules", @as(usize, 48));
            wasm_max_opts.addOption(bool, "has_frame_cap", false);
            wasm_max_opts.addOption(u32, "frame_cap_hz", @as(u32, 0));
            const shared = SharedModules.init(bb, true, false, false, 48, wasm_max_opts.createModule(), target, .wasm);
            const pm = makePlatformModules(bb, target, .wasm, &shared, false);

            if (std.mem.eql(u8, link_ctx.spec.name, "pixie")) {
                const root = TaggedModule{ .mod = link_ctx.app_module, .layer = .app, .name = "pixie" };
                link(root, pm.kit);
                link(root, shared.paint);
                // pixelops is re-exported via kit (kit.pixelops); no direct apps → pixelops link.
            } else if (std.mem.eql(u8, link_ctx.spec.name, "synth") or
                std.mem.eql(u8, link_ctx.spec.name, "synth_postmessage"))
            {
                // Shared and postMessage synth share the same app module graph; only the
                // wasm memory / audio transport differ (see WasmAppSpec.audio).
                const root = TaggedModule{ .mod = link_ctx.app_module, .layer = .app, .name = "synth" };
                link(root, pm.kit);
                link(root, shared.spectrogram);
                link(root, shared.scope);
                link(root, shared.serde);
            } else {
                std.debug.panic("internal wasm linker: unknown app '{s}'", .{link_ctx.spec.name});
            }
        }
    };

    const ctx = b.allocator.create(Ctx) catch @panic("OOM");
    ctx.* = .{ .b = b };
    return .{ .context = ctx, .apply = Ctx.apply };
}

/// pixie + synth (shared) + synth_postmessage WasmAppSpec values for the in-tree web package.
/// When `with_single_html` is true, pixie and the postMessage synth produce `*.single.html`.
fn makeWasmAppSpecs(b: *std.Build, base_target: std.Build.ResolvedTarget, with_single_html: bool) [3]platform.WasmAppSpec {
    // Keep the caller's CPU / OS / ABI / existing feature set; add simd128 for pixelops @Vector paths.
    var pixie_query = base_target.query;
    pixie_query.cpu_features_add.addFeatureSet(std.Target.wasm.featureSet(&.{.simd128}));

    // atomics + bulk_memory (shared memory / AudioWorklet) plus simd128
    // (pixelops @Vector paths and any other SIMD in the synth graph).
    const synth_shared_query = std.Target.Query{
        .cpu_arch = .wasm32,
        .os_tag = base_target.result.os.tag, // wasi
        .abi = base_target.result.abi,
        .cpu_features_add = std.Target.wasm.featureSet(&.{ .atomics, .bulk_memory, .simd128 }),
    };

    // postMessage synth: non-shared memory (no atomics/import_memory). simd128 only.
    var synth_pm_query = base_target.query;
    synth_pm_query.cpu_features_add.addFeatureSet(std.Target.wasm.featureSet(&.{.simd128}));

    return .{
        .{
            .name = "pixie",
            .target_query = pixie_query,
            .app_source = b.path("apps/editor/apps/pixie/main.zig"),
            .wasm_root_source = b.path("apps/editor/apps/pixie/wasm_root.zig"),
            .wasm_root_import_name = "pixie",
            .single_threaded = true,
            .audio = .none,
            .html_source = b.path("web/index.html"),
            .html_install_path = "web/index.html",
            .single_html = with_single_html,
        },
        .{
            .name = "synth",
            .target_query = synth_shared_query,
            .app_source = b.path("apps/synth/main.zig"),
            .wasm_root_source = b.path("apps/synth/wasm_root.zig"),
            .wasm_root_import_name = "synth_app",
            // single_threaded=true: zig 0.16 wasm_allocator has no multi-thread path;
            // +atomics on the target still emits i32.atomic.* for the JS dual-Instance setup.
            .single_threaded = true,
            .audio = .worklet_shared,
            .shared_memory = true,
            .import_memory = true,
            .export_memory = false,
            // 16 MiB initial / 64 MiB max (FB 1080×520 + audio stack/scratch + synth state)
            .initial_memory = 16 * 1024 * 1024,
            .max_memory = 64 * 1024 * 1024,
            // MasterEffects(65536) is ~0.5MiB+. Leave headroom for init temporaries on the stack.
            .stack_size = 2 * 1024 * 1024,
            // The worklet swaps the __stack_pointer Global per Instance.
            .export_symbol_names = &.{"__stack_pointer"},
            .html_source = b.path("web/synth.html"),
            .html_install_path = "web/synth.html",
            // worklet_shared × single HTML is a build error (COOP/COEP required).
            .single_html = false,
        },
        // Second delivery of the same synth app: main-thread render + postMessage worklet.
        // For file:// / hosts that cannot set COOP/COEP. Higher latency than shared.
        .{
            .name = "synth_postmessage",
            .target_query = synth_pm_query,
            .app_source = b.path("apps/synth/main.zig"),
            .wasm_root_source = b.path("apps/synth/wasm_root.zig"),
            .wasm_root_import_name = "synth_app",
            .single_threaded = true,
            .audio = .worklet_postmessage,
            .shared_memory = false,
            .import_memory = false,
            .export_memory = false,
            .initial_memory = 16 * 1024 * 1024,
            .max_memory = 64 * 1024 * 1024,
            .stack_size = 2 * 1024 * 1024,
            .html_source = b.path("web/synth-postmessage.html"),
            .html_install_path = "web/synth-postmessage.html",
            .single_html = with_single_html,
            .single_html_basename = "synth",
        },
    };
}

/// wasm32-wasi-only build (pixie + synth audio).
/// Root is wasm_root.zig (no main) to avoid the wasi command/_start path (reactor = export-driven).
fn buildWasm(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    var specs = makeWasmAppSpecs(b, target, true);
    const apps = platform.addWasmWebPackage(b, .{
        .apps = &specs,
        .assets = defaultWasmWebAssets(b),
        .optimize = optimize,
        .linker = makeInternalWasmLinker(b),
        .default_install = true,
        .create_package_step = true,
        .package_step_description = "Package wasm web deploy bundle to zig-out/web/ (pixie + synth + static assets)",
        .create_single_package_step = true,
        .single_package_step_description = "Package single-file HTML (pixie + postMessage synth) to zig-out/web/",
    });
    addBuildStep(b, "build-pixie", "Build Pixie wasm (wasm32-wasi)", apps[0].exe);
    addBuildStep(b, "build-synth-wasm", "Build Synth wasm (shared memory + AudioWorklet)", apps[1].exe);
    addBuildStep(b, "build-synth-postmessage-wasm", "Build Synth wasm (postMessage audio, no shared memory)", apps[2].exe);
}

/// Cross-compile wasm web artifacts from the native target into zig-out/web/.
fn packageWebFromNative(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const wasi_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });
    var specs = makeWasmAppSpecs(b, wasi_target, true);
    const apps = platform.addWasmWebPackage(b, .{
        .apps = &specs,
        .assets = defaultWasmWebAssets(b),
        .optimize = optimize,
        .linker = makeInternalWasmLinker(b),
        .default_install = false,
        .create_package_step = true,
        .package_step_description = "Package wasm web deploy bundle to zig-out/web/ (pixie + synth + static assets)",
        .create_single_package_step = true,
        .single_package_step_description = "Package single-file HTML (pixie + postMessage synth) to zig-out/web/",
    });
    addBuildStep(b, "build-pixie-wasm", "Build Pixie wasm for web (wasm32-wasi)", apps[0].exe);
    addBuildStep(b, "build-synth-wasm", "Build Synth wasm for web (shared memory + AudioWorklet)", apps[1].exe);
    addBuildStep(b, "build-synth-postmessage-wasm", "Build Synth wasm for web (postMessage audio, no shared memory)", apps[2].exe);
}

pub fn build(b: *std.Build) void {
    // ========================================
    // Project-specific setup
    // ========================================
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Wasm packaging defaults to ReleaseSmall when neither -Doptimize nor --release is given.
    // Explicit -Doptimize=… / --release=… always wins (same value as `optimize` above).
    // Native apps keep the Debug default from standardOptimizeOption.
    const wasm_optimize: std.builtin.OptimizeMode = if (b.user_input_options.contains("optimize") or b.release_mode != .off)
        optimize
    else
        .ReleaseSmall;
    const target_os = target.result.os.tag;
    const is_wasm = target.result.cpu.arch.isWasm();

    // ========================================
    // wasm-only branch (wasm32-wasi)
    // Even under wasi, skip the native backend loop and use the dedicated path.
    // Also publish dep.module("kit") / platform so an external package that depends on
    // kngn with a wasm target can import kit for its own wasm app.
    // ========================================
    if (is_wasm) {
        // Public modules for external wasm consumers (dep.module("kit")).
        // is_wasm=true uses createModule for internal package graphs elsewhere; here we
        // deliberately publish via addModule so the dependency surface exists.
        const wasm_pub_opts = b.addOptions();
        wasm_pub_opts.addOption(usize, "max_modules", @as(usize, 48));
        wasm_pub_opts.addOption(bool, "has_frame_cap", false);
        wasm_pub_opts.addOption(u32, "frame_cap_hz", @as(u32, 0));
        const wasm_pub_shared = SharedModules.init(
            b,
            true,
            false,
            false,
            48,
            wasm_pub_opts.createModule(),
            target,
            .wasm,
        );
        // SharedModules with is_wasm=true uses createModule for platform/png/… so register
        // the public names explicitly for external consumers.
        _ = b.modules.put(b.graph.arena, b.dupe("platform"), wasm_pub_shared.platform.mod) catch @panic("OOM");
        _ = b.modules.put(b.graph.arena, b.dupe("png"), wasm_pub_shared.png.mod) catch @panic("OOM");
        _ = b.modules.put(b.graph.arena, b.dupe("gmath"), wasm_pub_shared.gmath.mod) catch @panic("OOM");
        _ = b.modules.put(b.graph.arena, b.dupe("font"), wasm_pub_shared.font.mod) catch @panic("OOM");
        _ = b.modules.put(b.graph.arena, b.dupe("gui"), wasm_pub_shared.gui.mod) catch @panic("OOM");
        const app_runtime_wasm: TaggedModule = .{ .layer = .core, .name = "app_runtime", .mod = b.createModule(.{
            .root_source_file = b.path("core/app_runtime.zig"),
            .target = target,
            .single_threaded = true,
        }) };
        link(app_runtime_wasm, wasm_pub_shared.platform);
        app_runtime_wasm.mod.addImport("build_options", wasm_pub_shared.max_modules_mod);
        const kit_wasm: TaggedModule = .{ .layer = .kit, .name = "kit", .mod = b.addModule("kit", .{
            .root_source_file = b.path("kit/kit.zig"),
            .target = target,
            .single_threaded = true,
        }) };
        wireKitImports(kit_wasm, wasm_pub_shared.platform, &wasm_pub_shared, app_runtime_wasm);
        // BGRA→RGBA SIMD swizzle (same exception as makePlatformModules for wasm).
        linkCoreException(wasm_pub_shared.platform, wasm_pub_shared.pixelops, "BGRA→RGBA SIMD swizzle for wasm present");

        buildWasm(b, target, wasm_optimize);
        return;
    }

    // Backend selection. Valid values depend on the OS (macOS: objc/swift/metal, Linux: x11/wayland, Windows: gdi/d3d11).
    // When omitted, use the OS default. OS/backend mismatch is a build error via assertBackendForOs.
    const platform_option = b.option(
        platform.PlatformType,
        "platform",
        "Platform backend (macOS: objc/swift/metal, Linux: x11/wayland, Windows: gdi/d3d11)",
    ) orelse platform.defaultBackend(target_os);
    platform.assertBackendForOs(platform_option, target_os);

    // SDK / toolchain paths are needed only for macOS backends (Linux has no xcrun, so they are not resolved).
    // When unspecified, auto-detect via xcode-select (toolchain) and xcrun (SDK).
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

    // Gamepad opt-in for external consumers. Default false.
    // The same boolean drives dep.module("platform") / platform_native_* archive / GameController link conditions.
    // Internal exes (main/pixie/examples) use per-backend opt-in in makePlatformModules (independent of this option).
    const enable_gamepad_ext = b.option(
        bool,
        "enable_gamepad",
        "Enable gamepad for external platform module and native archive (default false)",
    ) orelse false;

    // modular/noodle concurrent module limit. Default 48 = bit-identical with the current default.
    // Lower bound: enough for the default lofi patch + macros. Upper bound: u16 handle / a sensible memory range.
    // Create the Options Module once via createModule; all consumers share it through addImport
    // (addOptions creates a Module each call, so the same options.zig would become 2 roots and compile-error).
    const max_modules_option = b.option(
        usize,
        "max-modules",
        "Max concurrent modular modules (default 48)",
    ) orelse 48;
    if (max_modules_option < 48) {
        @panic("-Dmax-modules must be >= 48 (default lofi patch + macros require at least 48)");
    }
    if (max_modules_option > 4096) {
        @panic("-Dmax-modules must be <= 4096");
    }
    const max_modules_opts = b.addOptions();
    max_modules_opts.addOption(usize, "max_modules", max_modules_option);
    // Frame-rate cap for app_runtime (`-Dframe-cap`). Piggybacks on this shared options
    // module (createModule once) so every consumer gets one root — see comment above.
    const frame_cap_option = b.option(
        u32,
        "frame-cap",
        "Native loop frame rate cap in Hz (omit to use App.frame_period_s)",
    );
    max_modules_opts.addOption(bool, "has_frame_cap", frame_cap_option != null);
    max_modules_opts.addOption(u32, "frame_cap_hz", frame_cap_option orelse 0);
    const max_modules_mod = max_modules_opts.createModule();

    // ========================================
    // Shared modules (OS/backend-independent; shared by main + examples + pixie + synth)
    // Also includes the external public modules (platform/png/font/gui).
    // ========================================
    const shared_modules = SharedModules.init(b, false, false, enable_gamepad_ext, max_modules_option, max_modules_mod, target, platform_option);

    // External public kit umbrella. Reuses SharedModules instances so type identity holds.
    // Obtained via dep.module("kit"). platform / gui / gamepad etc. are the same module instances through kit.
    {
        const app_runtime_ext: TaggedModule = .{ .layer = .core, .name = "app_runtime", .mod = b.createModule(.{
            .root_source_file = b.path("core/app_runtime.zig"),
        }) };
        link(app_runtime_ext, shared_modules.platform);
        app_runtime_ext.mod.addImport("build_options", max_modules_mod);
        const kit_ext: TaggedModule = .{ .layer = .kit, .name = "kit", .mod = b.addModule("kit", .{
            .root_source_file = b.path("kit/kit.zig"),
        }) };
        wireKitImports(kit_ext, shared_modules.platform, &shared_modules, app_runtime_ext);
    }

    // Backend set implemented for the target OS (macOS: objc/swift/metal, Linux: x11/wayland, Windows: gdi/d3d11)
    const backends = platform.implementedBackends(target_os);
    const default_be = platform.defaultBackend(target_os);

    // audio (L1 output) backend: macOS(AudioToolbox) / Linux(ALSA) / Windows(WASAPI).
    // Whether synth / example_15(audio) are generated (decision shared with the standalone helper).
    const audio_supported = platform.audioSupported(target_os);

    // ========================================
    // Generate main / pixie / synth / examples per backend
    // (platform / keyboard get a per-backend module graph = build_options.platform_backend).
    // synth / example_15 that need audio: macOS/Linux/Windows (audio backend is OS-branched). platform native lib is macOS only.
    // ========================================
    var default_main: ?*std.Build.Step.Compile = null;
    var default_pixie: ?*std.Build.Step.Compile = null;
    var default_synth: ?*std.Build.Step.Compile = null;
    var default_noodle: ?*std.Build.Step.Compile = null;

    for (backends) |be| {
        const is_default = (be == platform_option);
        const pm = makePlatformModules(b, target, be, &shared_modules, false);

        // ----- Main application -----
        const main_exe = addMainExe(b, target, optimize, platform_root, sdk_paths, be, artifactName(b, APP_NAME, be, default_be), &pm);
        if (is_default) default_main = main_exe;
        if (install_all) b.installArtifact(main_exe);
        addRunStep(b, b.fmt("run-{s}", .{platform.backendName(be)}), b.fmt("Run the {s} version", .{platform.backendName(be)}), main_exe, b.args);

        // ----- Pixie editor (apps/editor/apps/pixie) -----
        const pixie_exe = addPixieExe(b, target, optimize, platform_root, sdk_paths, be, artifactName(b, "pixie", be, default_be), &shared_modules, &pm);
        if (is_default) default_pixie = pixie_exe;
        // Under install-all, also build pixie as a compile-regression target (non-interactive)
        if (install_all) b.installArtifact(pixie_exe);
        addRunStep(b, b.fmt("run-pixie-{s}", .{platform.backendName(be)}), b.fmt("Run Pixie editor ({s})", .{platform.backendName(be)}), pixie_exe, b.args);

        // ----- Synth app (apps/synth) — PC-keyboard performance MVP. audio backend: macOS/Linux/Windows -----
        if (audio_supported) {
            // ----- Noodle app (apps/noodle) — patch-canvas UI + live rewiring. audio-capable OSes -----
            const noodle_exe = addNoodleExe(b, target, optimize, platform_root, sdk_paths, be, artifactName(b, "noodle", be, default_be), &shared_modules, &pm);
            if (is_default) default_noodle = noodle_exe;
            if (install_all) b.installArtifact(noodle_exe);
            addRunStep(b, b.fmt("run-noodle-{s}", .{platform.backendName(be)}), b.fmt("Run noodle, the modular patch canvas ({s})", .{platform.backendName(be)}), noodle_exe, b.args);

            const synth_exe = addSynthExe(b, target, optimize, platform_root, sdk_paths, be, artifactName(b, "synth", be, default_be), &shared_modules, &pm);
            if (is_default) default_synth = synth_exe;
            if (install_all) b.installArtifact(synth_exe);
            addRunStep(b, b.fmt("run-synth-{s}", .{platform.backendName(be)}), b.fmt("Run synth app ({s})", .{platform.backendName(be)}), synth_exe, b.args);

            // ----- 20_capture_demo (examples/20_capture_demo) — mic waveform/FFT viz + camera→canvas demo.
            // camera/audio capture extensions are practical only on audio-capable OSes, so
            // keep it inside the audio_supported gate (unlike other examples it is not in the ExampleNeeds table;
            // wired via a dedicated helper because it direct-imports camera/harness/capture_synthetic. examples are
            // outside R5=kit-only; see the build.zig header comment).
            const capture_demo_exe = addCaptureDemoExe(b, target, optimize, platform_root, sdk_paths, be, artifactName(b, "example_20", be, default_be), &shared_modules, &pm);
            // examples always install for every backend, independent of install-all (same policy as existing examples).
            b.installArtifact(capture_demo_exe);
            if (is_default) {
                addRunStep(
                    b,
                    "run-example_20",
                    "Run 20_capture_demo example (uses -Dplatform option; set KNGN_HARNESS_CAPTURE_SYNTHETIC=1 + KNGN_HEADLESS=1 for headless synthetic mic/camera verification)",
                    capture_demo_exe,
                    b.args,
                );
            }
        }

        // ----- Sample programs -----
        // Declare the modules each example needs.
        // Every entry must share the same field set (name / path / needs_*) so anonymous struct types
        // match (avoids type mismatch in inline for).
        inline for (.{
            .{ .name = "example_01", .path = "examples/01_timed_window/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_02", .path = "examples/02_keyboard_input/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_03", .path = "examples/03_sprite_rendering/main.zig", .needs_sprite = true, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_04", .path = "examples/04_fixed_timestep/main.zig", .needs_sprite = false, .needs_fps_counter = true, .needs_fixed_timestep = true, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_05", .path = "examples/05_text_rendering/main.zig", .needs_sprite = false, .needs_fps_counter = true, .needs_fixed_timestep = false, .needs_text = true, .needs_gui = false, .needs_png = false, .needs_font = true, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_06", .path = "examples/06_sprite_benchmark/main.zig", .needs_sprite = true, .needs_fps_counter = true, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_07", .path = "examples/07_mouse_input/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_08", .path = "examples/08_gui_primitives/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = true, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_09", .path = "examples/09_gui_interaction/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_10", .path = "examples/10_gui_layout/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_11", .path = "examples/11_gui_widgets/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_12", .path = "examples/12_outline_font/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = true, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_13", .path = "examples/13_gui_slider/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_14", .path = "examples/14_gui_color_picker/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_15", .path = "examples/15_audio_tone/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = true, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_16", .path = "examples/16_gui_scroll/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_17", .path = "examples/17_gui_toggles/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_18", .path = "examples/18_cursor/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_19", .path = "examples/19_color_emoji/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = true, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_21", .path = "examples/21_char_input/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = true, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_22", .path = "examples/22_gamepad/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = true, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_23", .path = "examples/23_fullscreen/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_24", .path = "examples/24_desktop_mascot/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = true, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_25", .path = "examples/25_collision_demo/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = true, .needs_sound = false },
            .{ .name = "example_26", .path = "examples/26_appshell_demo/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = true, .needs_paint = true, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_27", .path = "examples/27_selectable_label/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = true, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_28", .path = "examples/28_text_input/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = true, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_29", .path = "examples/29_midi_monitor/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_30", .path = "examples/30_sound_demo/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = true, .needs_gamepad = false, .needs_gmath = false, .needs_sound = true },
            .{ .name = "example_31", .path = "examples/31_sprite_ex/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_32", .path = "examples/32_sprite_anim/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_33", .path = "examples/33_camera/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_34", .path = "examples/34_action_map/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = true, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_35", .path = "examples/35_gui_gallery/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_36", .path = "examples/36_tilemap/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_37", .path = "examples/37_gui_torture/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_38", .path = "examples/38_minigame/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = false, .needs_png = false, .needs_font = false, .needs_audio = true, .needs_gamepad = false, .needs_gmath = false, .needs_sound = true },
            .{ .name = "example_39", .path = "examples/39_settings_shell/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_40", .path = "examples/40_list_menu/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
            .{ .name = "example_41", .path = "examples/41_panel_host/main.zig", .needs_sprite = false, .needs_fps_counter = false, .needs_fixed_timestep = false, .needs_text = false, .needs_gui = true, .needs_png = false, .needs_font = false, .needs_audio = false, .needs_gamepad = false, .needs_gmath = false, .needs_sound = false },
        }) |example| {
            const needs: ExampleNeeds = .{
                .needs_sprite = example.needs_sprite,
                .needs_fps_counter = example.needs_fps_counter,
                .needs_fixed_timestep = example.needs_fixed_timestep,
                .needs_text = example.needs_text,
                .needs_gui = example.needs_gui,
                .needs_png = example.needs_png,
                .needs_font = example.needs_font,
                .needs_paint = if (@hasField(@TypeOf(example), "needs_paint")) example.needs_paint else false,
                .needs_audio = example.needs_audio,
                .needs_gamepad = example.needs_gamepad,
                .needs_midi = std.mem.eql(u8, example.name, "example_29"),
                .needs_gmath = example.needs_gmath,
                .needs_sound = example.needs_sound,
                .needs_kit = std.mem.eql(u8, example.name, "example_31") or std.mem.eql(u8, example.name, "example_32") or std.mem.eql(u8, example.name, "example_33") or std.mem.eql(u8, example.name, "example_34") or std.mem.eql(u8, example.name, "example_36") or std.mem.eql(u8, example.name, "example_38") or std.mem.startsWith(u8, example.name, "example_26"),
            };
            // audio examples: audio-capable OSes only (macOS/Linux/Windows). All other examples: every OS.
            if (!needs.needs_audio or audio_supported) {
                const ex_exe = addExampleExe(b, target, optimize, platform_root, sdk_paths, be, artifactName(b, example.name, be, default_be), example.path, &shared_modules, &pm, needs);
                // Tools with no window that write to stdout (example_06 bench / example_15 audio tone)
                // keep the console subsystem on Windows too (override setupExecutableForPlatform GUI subsystem).
                if (target_os == .windows and comptime (std.mem.eql(u8, example.name, "example_06") or
                    std.mem.eql(u8, example.name, "example_15"))) ex_exe.subsystem = .Console;
                // examples always install for every backend, independent of install-all
                // (keeps the existing behaviour of catching platform-layer / example compile regressions on every `zig build`).
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

    // Bind the default backend to `run` / the default install.
    // Under install-all the loop above already installed every backend, so skip a second install.
    if (!install_all) b.installArtifact(default_main.?);
    addRunStep(b, "run", "Run the app (uses -Dplatform option)", default_main.?, b.args);
    addRunStep(b, "run-pixie", "Run Pixie editor (uses -Dplatform option)", default_pixie.?, b.args);

    // Build-only (do not run). A step that installs just that exe.
    // Bare `zig build` builds every installArtifact, so split out single-target build steps.
    addBuildStep(b, "build-main", "Build the app only (uses -Dplatform option)", default_main.?);
    addBuildStep(b, "build-pixie", "Build Pixie editor only (uses -Dplatform option)", default_pixie.?);

    // synth is generated only on audio-capable OSes (macOS/Linux/Windows). On others default_synth=null and no step is created.
    if (default_synth) |ds| {
        addRunStep(b, "run-synth", "Run synth app (uses -Dplatform option)", ds, b.args);
        addBuildStep(b, "build-synth", "Build synth app only (uses -Dplatform option)", ds);
    }

    // noodle is also audio-capable OSes only (it makes sound; default_noodle is null otherwise).
    if (default_noodle) |dp| {
        addRunStep(b, "run-noodle", "Run noodle, the modular patch canvas (uses -Dplatform option)", dp, b.args);
        addBuildStep(b, "build-noodle", "Build noodle only (uses -Dplatform option)", dp);
    }

    // ----- The command line tool -----
    // One binary with a subcommand per line of work: `kngn ctl` drives a running app's harness,
    // `kngn mcp` serves that harness to an MCP client. Standalone exe of pure std + std.Io.net
    // (no platform/audio). Always install so it doubles as compile regression.
    // The `scripts/kngn` wrapper execs `zig-out/bin/kngn` directly.
    const kngn_exe = b.addExecutable(.{
        .name = "kngn",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/kngn.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(kngn_exe);
    addBuildStep(b, "kngn", "Build the command line tool (zig-out/bin/kngn; ctl and mcp subcommands)", kngn_exe);

    // ----- wasm web distribution package -----
    // Cross-compile from the native target into zig-out/web/. The web/ layout used in development is unchanged.
    packageWebFromNative(b, wasm_optimize);

    // ========================================
    // platform native object archive lib (for external packages) — macOS only
    // Separated from the facade module (addModule "platform"). Externals linkLibrary
    // dep.artifact("platform_native_<plat>"). Archive of .o only; framework / Swift runtime / search paths
    // are applied on the consumer exe side (C-style: build_helpers.setupConsumerExe, or vendor macos/swift helpers).
    //
    // Public module vs executable (current): the public platform module is backend-aware for
    // `@cImport` resolution — X11 (`X11`/`Xext`) and Wayland (`wayland-client`/`wayland-cursor`/
    // `xkbcommon` + generated protocol headers) live on the module. Executable-only requirements
    // stay on the consumer: macOS native `.o` archive / frameworks / Swift runtime, Wayland
    // private `.c` sources, Windows system libs + `subsystem = .Windows`. Linux and Windows need
    // no native archive; only macOS publishes `platform_native_*` below. Prefer
    // `build_helpers.setupConsumerExe` rather than hand-rolling these links.
    // ========================================
    if (target_os == .macos) {
        // enable_gamepad_ext aligns KNGN_ENABLE_GAMEPAD on the native archive with the platform module.
        // GameController framework linking stays on the consumer side (explicit on the exe when enabled).
        _ = addPlatformNativeLib(b, target, optimize, platform_root, .objc, "platform_native_objc", enable_gamepad_ext);
        _ = addPlatformNativeLib(b, target, optimize, platform_root, .swift, "platform_native_swift", enable_gamepad_ext);
        _ = addPlatformNativeLib(b, target, optimize, platform_root, .metal, "platform_native_metal", enable_gamepad_ext);
    }

    // ========================================
    // Test suite (pure tests that do not import platform. OS/backend-independent)
    // ========================================

    // PNG round-trip tests (io_png.zig tests + verify with png)
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

    // PNG encoder unit tests (golden byte match + scanline order; decoder-independent)
    const png_encode_mod = b.createModule(.{
        .root_source_file = b.path("libs/png/src/encode.zig"),
        .target = target,
        .optimize = optimize,
    });
    const png_encode_test = b.addTest(.{ .root_module = png_encode_mod });
    test_png_roundtrip_step.dependOn(&b.addRunArtifact(png_encode_test).step);

    // harness unit tests (parser / execution model / virtual clock. no display; backend-independent)
    const harness_test_mod = b.createModule(.{
        .root_source_file = b.path("core/control/harness.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // harness.init() uses libc getenv (so tests that call init also pass)
    });
    harness_test_mod.addImport("png", shared_modules.png.mod); // harness uses encodePNG/crc32
    harness_test_mod.addImport("platform_types", shared_modules.types.mod); // harness uses Event/EventStats etc.
    harness_test_mod.addImport("command_types", shared_modules.command_types.mod);
    harness_test_mod.addImport("capture_synthetic", shared_modules.capture_synthetic.mod); // used by harness `capture` command/probe
    harness_test_mod.addImport("dsp", shared_modules.dsp.mod); // digest audio spectrum analysis (band/centroid/onset)
    const harness_test = b.addTest(.{ .root_module = harness_test_mod });
    const run_harness_test = b.addRunArtifact(harness_test);
    const test_harness_step = b.step("test-harness", "Run harness unit tests (parser / execution model / virtual clock)");
    test_harness_step.dependOn(&run_harness_test.step);

    // `kngn mcp` unit tests (schema convert / serialize / fail extract / collision resolve / contract; std only)
    const mcp_test_mod = b.createModule(.{
        .root_source_file = b.path("cli/mcp.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mcp_test = b.addTest(.{ .root_module = mcp_test_mod });
    const run_mcp_test = b.addRunArtifact(mcp_test);
    const test_mcp_step = b.step("test-mcp", "Run the kngn mcp unit tests (schema / serialize / fail / contract)");
    test_mcp_step.dependOn(&run_mcp_test.step);

    // command model unit tests (types + executor + no-op recorder; std only; no platform/harness)
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

    // menu Command type-only model and App.dispatchCommand adapter.
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

    // The platform facade's own unit tests (event-scale normalisation / framebuffer snapshot
    // contract). `zig test` only collects `test` blocks declared in the root file itself, not ones
    // reached through a relative `@import` (the OS backend dispatch inside core/platform.zig), so a
    // wrapper module that merely imports "platform" (as platform_menu_test_mod below does) would never
    // run these — same policy as the frame-pacing/MIDI/capture dedicated roots. Rooting the test module
    // directly at core/platform.zig and building it with the same `createPlatformModule` helper the
    // production module uses works with no extra native archive: the facade's tests exercise only pure
    // logic (comptime-unreachable native calls are never analysed, let alone linked).
    const platform_facade_test_mod = platform.createPlatformModule(
        b,
        target,
        b.path("core/platform.zig"),
        platform_root,
        platform.defaultBackend(target_os),
        shared_modules.types.mod,
        shared_modules.command_types.mod,
        shared_modules.harness.mod,
        .{},
    );
    const platform_facade_test = b.addTest(.{ .root_module = platform_facade_test_mod });
    const run_platform_facade_test = b.addRunArtifact(platform_facade_test);
    const test_platform_facade_step = b.step("test-platform-facade", "Run platform facade unit tests (event-scale normalisation / framebuffer snapshot contract)");
    test_platform_facade_step.dependOn(&run_platform_facade_test.step);

    // The macOS backend's own unit tests (same "root file only" collection rule as above). Its
    // `test` blocks reference no link-time C function (guarded by `builtin.is_test`; `@cInclude`
    // still resolves the C type/constant references at comptime), so `@cInclude("platform.h")`
    // only needs the include path, not the native .o archive.
    if (target_os == .macos) {
        const platform_macos_test_mod = b.createModule(.{
            .root_source_file = b.path("core/platform_macos.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        platform_macos_test_mod.addIncludePath(platform_root);
        platform_macos_test_mod.addImport("platform_types", shared_modules.types.mod);
        platform_macos_test_mod.addImport("command_types", shared_modules.command_types.mod);
        const macos_opts = b.addOptions();
        macos_opts.addOption([]const u8, "platform_backend", platform.backendName(platform.defaultBackend(target_os)));
        macos_opts.addOption(bool, "enable_menu", false);
        platform_macos_test_mod.addOptions("build_options", macos_opts);
        const platform_macos_test = b.addTest(.{ .root_module = platform_macos_test_mod });
        test_platform_facade_step.dependOn(&b.addRunArtifact(platform_macos_test).step);
    }

    // The Linux backends' own unit tests (same "root file only" collection rule as above).
    // Rooting each test module directly at its backend file and building it with the same
    // `createPlatformModule` helper the production module uses applies the `linkSystemLibrary`
    // calls (X11/Xext for x11; wayland-client/wayland-cursor/xkbcommon plus the generated
    // xdg-shell/xdg-decoration client headers for wayland) that resolving each backend's
    // `@cImport` needs, with no extra native archive.
    if (target_os == .linux) {
        const platform_linux_x11_test_mod = platform.createPlatformModule(
            b,
            target,
            b.path("core/platform_linux_x11.zig"),
            platform_root,
            .x11,
            shared_modules.types.mod,
            shared_modules.command_types.mod,
            shared_modules.harness.mod,
            .{},
        );
        const platform_linux_x11_test = b.addTest(.{ .root_module = platform_linux_x11_test_mod });
        test_platform_facade_step.dependOn(&b.addRunArtifact(platform_linux_x11_test).step);

        const platform_linux_wayland_test_mod = platform.createPlatformModule(
            b,
            target,
            b.path("core/platform_linux_wayland.zig"),
            platform_root,
            .wayland,
            shared_modules.types.mod,
            shared_modules.command_types.mod,
            shared_modules.harness.mod,
            .{},
        );
        const platform_linux_wayland_test = b.addTest(.{ .root_module = platform_linux_wayland_test_mod });
        test_platform_facade_step.dependOn(&b.addRunArtifact(platform_linux_wayland_test).step);
    }

    // The Windows backend's shared Win32 layer (`platform_windows_common.zig`) own unit tests
    // (same "root file only" collection rule as above). It has no `@cImport`: its user32/gdi32/
    // comdlg32 externs resolve against zig's bundled MinGW import libs, so only the system
    // libraries need linking (no include path, unlike the macOS/Linux backends above).
    if (target_os == .windows) {
        const platform_windows_common_test_mod = b.createModule(.{
            .root_source_file = b.path("core/platform_windows_common.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        platform_windows_common_test_mod.addImport("platform_types", shared_modules.types.mod);
        platform_windows_common_test_mod.linkSystemLibrary("user32", .{});
        platform_windows_common_test_mod.linkSystemLibrary("gdi32", .{});
        platform_windows_common_test_mod.linkSystemLibrary("comdlg32", .{});
        const platform_windows_common_test = b.addTest(.{ .root_module = platform_windows_common_test_mod });
        test_platform_facade_step.dependOn(&b.addRunArtifact(platform_windows_common_test).step);
    }

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

    // null backend unit tests. no display / native .o. platform_types + command_types only.
    const platform_null_test_mod = b.createModule(.{
        .root_source_file = b.path("core/platform_null.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    platform_null_test_mod.addImport("platform_types", shared_modules.types.mod);
    platform_null_test_mod.addImport("command_types", shared_modules.command_types.mod);
    const platform_null_test = b.addTest(.{ .root_module = platform_null_test_mod });
    const run_platform_null_test = b.addRunArtifact(platform_null_test);
    const test_platform_null_step = b.step("test-platform-null", "Run platform_null (KNGN_HEADLESS) unit tests");
    test_platform_null_step.dependOn(&run_platform_null_test.step);

    const platform_clipboard_test_mod = b.createModule(.{
        .root_source_file = b.path("core/platform_clipboard_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    platform_clipboard_test_mod.addImport("platform", shared_modules.platform.mod);
    const platform_clipboard_test = b.addTest(.{ .root_module = platform_clipboard_test_mod });
    const run_platform_clipboard_test = b.addRunArtifact(platform_clipboard_test);
    const test_platform_clipboard_step = b.step("test-platform-clipboard", "Run OS text clipboard facade round-trip tests");
    test_platform_clipboard_step.dependOn(&run_platform_clipboard_test.step);

    // copilot transport unit tests (ConnState state machine / command execution / registry OR gate / exclusion.
    // no socket/display). root=copilot.zig imports harness.zig, so
    // it needs the same import/link_libc shape as harness_test_mod. The "copilot:" filter runs only copilot tests
    // (imported harness/command tests stay with test-harness / test-command; avoid double-running).
    const copilot_test_mod = b.createModule(.{
        .root_source_file = b.path("core/control/copilot.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // both copilot/harness use libc getenv
    });
    copilot_test_mod.addImport("png", shared_modules.png.mod);
    copilot_test_mod.addImport("platform_types", shared_modules.types.mod);
    copilot_test_mod.addImport("command_types", shared_modules.command_types.mod);
    copilot_test_mod.addImport("capture_synthetic", shared_modules.capture_synthetic.mod);
    const copilot_test = b.addTest(.{ .root_module = copilot_test_mod, .filters = &.{"copilot:"} });
    const run_copilot_test = b.addRunArtifact(copilot_test);
    const test_copilot_step = b.step("test-copilot", "Run copilot transport unit tests (ConnState / command layer / registry OR gate)");
    test_copilot_step.dependOn(&run_copilot_test.step);

    // netsync transport unit tests (action_registry + frame codec + loopback HELLO/queue.
    // no display). root=netsync.zig relative-imports action_registry.zig.
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

    // Also fold action_registry unit tests into test-netsync (separate artifact, no filter).
    const action_registry_test_mod = b.createModule(.{
        .root_source_file = b.path("core/control/action_registry.zig"),
        .target = target,
        .optimize = optimize,
    });
    const action_registry_test = b.addTest(.{ .root_module = action_registry_test_mod });
    test_netsync_step.dependOn(&b.addRunArtifact(action_registry_test).step);

    // audio_null unit tests (headless output with no real device. RT zero-alloc / pull loop.
    // no display / real audio device; OS-independent)
    const audio_null_test_mod = b.createModule(.{
        .root_source_file = b.path("core/audio_null.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // sleep pacing uses std.c.nanosleep (same implementation as platform.sleep)
    });
    const audio_null_test = b.addTest(.{ .root_module = audio_null_test_mod });
    const run_audio_null_test = b.addRunArtifact(audio_null_test);
    const test_audio_null_step = b.step("test-audio-null", "Run audio_null (headless null device) unit tests");
    test_audio_null_step.dependOn(&run_audio_null_test.step);

    // Shared types module (platform_types) unit tests (ModifierFlags round-trip etc.).
    // platform_types is a named module, so it is no longer picked up via source-include;
    // cover it explicitly as a dedicated step.
    const platform_types_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/platform_types.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_platform_types_step = b.step("test-platform-types", "Run platform_types unit tests (shared type definitions)");
    test_platform_types_step.dependOn(&b.addRunArtifact(platform_types_test).step);

    // Pure frame-pacing logic. OS / display / platform independent (no imports).
    // Tests behind a cross-root indirect import are not collected, so run them via a dedicated addTest
    // (rooting at core/platform.zig would require linking native-backend externs, so
    //   the pure logic lives in core/frame_pacing.zig and this step runs it).
    const frame_pacing_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/frame_pacing.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_frame_pacing_step = b.step("test-frame-pacing", "Run frame pacing (deadline + overshoot EWMA) unit tests");
    test_frame_pacing_step.dependOn(&b.addRunArtifact(frame_pacing_test).step);

    // MIDI facade/null/CoreMIDI backend unit tests (ADR-010).
    // On macOS the facade relative-imports midi_macos, so CoreMIDI is linked.
    // A dedicated addTest rooted at midi_macos.zig also runs the native-side tests
    // (cross-root indirect-import tests are not collected; same policy as capture).
    const midi_test_mod = b.createModule(.{
        .root_source_file = b.path("core/midi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    midi_test_mod.addImport("platform_types", shared_modules.types.mod);
    midi_test_mod.addImport("harness", shared_modules.harness.mod);
    if (target_os == .macos) linkMidiMacFrameworks(b, midi_test_mod, sdk_paths.?);
    const midi_test = b.addTest(.{ .root_module = midi_test_mod });
    const midi_null_test_mod = b.createModule(.{
        .root_source_file = b.path("core/midi_null.zig"),
        .target = target,
        .optimize = optimize,
    });
    midi_null_test_mod.addImport("platform_types", shared_modules.types.mod);
    const midi_null_test = b.addTest(.{ .root_module = midi_null_test_mod });
    const test_midi_step = b.step("test-midi", "Run MIDI facade/null/CoreMIDI backend unit tests");
    test_midi_step.dependOn(&b.addRunArtifact(midi_test).step);
    test_midi_step.dependOn(&b.addRunArtifact(midi_null_test).step);
    if (target_os == .macos) {
        const midi_macos_test_mod = b.createModule(.{
            .root_source_file = b.path("core/midi_macos.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        midi_macos_test_mod.addImport("platform_types", shared_modules.types.mod);
        linkMidiMacFrameworks(b, midi_macos_test_mod, sdk_paths.?);
        const midi_macos_test = b.addTest(.{ .root_module = midi_macos_test_mod });
        test_midi_step.dependOn(&b.addRunArtifact(midi_macos_test).step);
    }

    // wasm platform DOM→MouseButton / KeyCode mapping (runs on native too; extern env unused on the test path).
    const platform_wasm_test_mod = b.createModule(.{
        .root_source_file = b.path("core/platform_wasm.zig"),
        .target = target,
        .optimize = optimize,
    });
    platform_wasm_test_mod.addImport("platform_types", shared_modules.types.mod);
    platform_wasm_test_mod.addImport("pixelops", shared_modules.pixelops.mod);
    const platform_wasm_test = b.addTest(.{ .root_module = platform_wasm_test_mod });
    const test_platform_wasm_step = b.step("test-platform-wasm", "Run platform_wasm DOM→MouseButton / KeyCode unit tests");
    test_platform_wasm_step.dependOn(&b.addRunArtifact(platform_wasm_test).step);

    // Capture input foundation unit tests. no display/real device; OS-independent.
    // Bundles capture_types (TripleBuffer round-trip / invariants / DeviceInfo/CaptureError) + camera facade
    // (relative-imports camera_stub.zig; harness branch + stub delegate) + audio.zig
    // capture extension (relative-imports audio_capture_stub.zig; existing output-backend switch is
    // not analyzed unless referenced — Zig lazy analysis means no AudioToolbox etc. link is needed)
    // + capture_synthetic (harness-built-in synthetic capture source)
    // — four roots in one step.
    const capture_types_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/capture_types.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_capture_types_step = b.step("test-capture-types", "Run capture_types / camera facade / audio capture extension unit tests");
    test_capture_types_step.dependOn(&b.addRunArtifact(capture_types_test).step);

    // camera.zig facade (relative-imports camera_macos.zig on macOS / camera_stub.zig elsewhere).
    // Uses harness, so link_libc=true for the same reason as harness_test_mod
    // (also needed for std.c.nanosleep/getenv via objc_runtime in camera_macos.zig).
    const camera_test_mod = b.createModule(.{
        .root_source_file = b.path("core/camera.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // harness.init() path uses libc getenv + macOS: objc_runtime nanosleep
    });
    camera_test_mod.addImport("capture_types", shared_modules.capture_types.mod);
    camera_test_mod.addImport("harness", shared_modules.harness.mod);
    camera_test_mod.addImport("objc_runtime", shared_modules.objc_runtime.mod); // macOS: camera_macos.zig references via named import
    const camera_test = b.addTest(.{ .root_module = camera_test_mod });
    // On macOS camera_macos.zig drives AVFoundation (ObjC-only APIs) via objc_runtime, so
    // tests are not executed here (config check only is automatic) but compile+link still needs the full
    // framework set linked explicitly (other OSes stay on camera_stub.zig with no extras).
    if (target.result.os.tag == .macos) linkCaptureMacFrameworks(b, camera_test_mod, sdk_paths.?);
    test_capture_types_step.dependOn(&b.addRunArtifact(camera_test).step);

    // core/audio.zig (whole file including capture extension). The `switch` on existing output backends
    // (audio_macos etc.) remains, but no test here calls output-side functions, so Zig lazy analysis
    // leaves them unreferenced. Capture on macOS goes through the real backend
    // (`capture` namespace in `audio_macos.zig`), so link_libc=true
    // (std.c.nanosleep/getenv via objc_runtime) is required.
    const audio_capture_test_mod = b.createModule(.{
        .root_source_file = b.path("core/audio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    audio_capture_test_mod.addImport("harness", shared_modules.harness.mod);
    audio_capture_test_mod.addImport("capture_types", shared_modules.capture_types.mod);
    audio_capture_test_mod.addImport("objc_runtime", shared_modules.objc_runtime.mod); // macOS: audio_macos.zig references via named import
    if (target.result.os.tag == .linux) audio_capture_test_mod.linkSystemLibrary("alsa", .{});
    const audio_capture_test = b.addTest(.{ .root_module = audio_capture_test_mod });
    // On macOS mic capture (AUHAL input) uses AudioToolbox/CoreAudio + permission-check
    // AVFoundation (ObjC), so frameworks are linked explicitly (other OSes stay on audio_capture_stub.zig
    // with no extras).
    if (target.result.os.tag == .macos) linkCaptureMacFrameworks(b, audio_capture_test_mod, sdk_paths.?);
    test_capture_types_step.dependOn(&b.addRunArtifact(audio_capture_test).step);

    // `zig test` collects/runs only tests on the root file itself; tests in files the root
    // relative-`@import`s (`camera_macos.zig`/`audio_macos.zig` etc.) are
    // not collected (root=camera.zig/audio.zig `camera_test`/`audio_capture_test` compile
    // and link, but tests inside those files do not appear in the run count).
    // So, same policy as `capture_synthetic_test`: add dedicated addTest rooted directly at those files
    // on macOS only, so `copyBgraRows`/`mapAuthStatus`/config checks etc. actually run.
    // `objc_runtime.zig` (msgSend/stack block; the most fragile part) is relative-imported from both
    // camera_macos.zig and audio_macos.zig, so it runs indirectly via those root tests
    // (a root file's direct relative imports are collected; the
    // "not collected" rule applies only to two-hop cross-root indirect imports). Still, to verify
    // without relying on that dependency, also add a dedicated addTest
    // rooted directly at core/objc_runtime.zig.
    if (target_os == .macos) {
        const objc_runtime_test_mod = b.createModule(.{
            .root_source_file = b.path("core/objc_runtime.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // for std.c.nanosleep/getenv
        });
        linkCaptureMacFrameworks(b, objc_runtime_test_mod, sdk_paths.?);
        const objc_runtime_test = b.addTest(.{ .root_module = objc_runtime_test_mod });
        test_capture_types_step.dependOn(&b.addRunArtifact(objc_runtime_test).step);

        const camera_macos_test_mod = b.createModule(.{
            .root_source_file = b.path("core/camera_macos.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // for std.c.nanosleep/getenv via objc_runtime
        });
        camera_macos_test_mod.addImport("capture_types", shared_modules.capture_types.mod);
        camera_macos_test_mod.addImport("objc_runtime", shared_modules.objc_runtime.mod); // relative → named import
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
        audio_macos_capture_test_mod.addImport("objc_runtime", shared_modules.objc_runtime.mod); // relative → named import
        linkCaptureMacFrameworks(b, audio_macos_capture_test_mod, sdk_paths.?);
        const audio_macos_capture_test = b.addTest(.{ .root_module = audio_macos_capture_test_mod });
        test_capture_types_step.dependOn(&b.addRunArtifact(audio_macos_capture_test).step);
    }

    // core/camera_stub.zig's own unit tests (same "root file only" collection rule noted above).
    // The stub is OS-independent (it only `@import`s `capture_types`, with no `@cImport` or
    // extern fn), so this root builds and runs on every OS regardless of which backend
    // camera.zig's `builtin.os.tag` dispatch actually selects for the host running this build.
    const camera_stub_test_mod = b.createModule(.{
        .root_source_file = b.path("core/camera_stub.zig"),
        .target = target,
        .optimize = optimize,
    });
    camera_stub_test_mod.addImport("capture_types", shared_modules.capture_types.mod);
    const camera_stub_test = b.addTest(.{ .root_module = camera_stub_test_mod });
    test_capture_types_step.dependOn(&b.addRunArtifact(camera_stub_test).step);

    // core/audio_capture_stub.zig's own unit tests, same reasoning as camera_stub above.
    const audio_capture_stub_test_mod = b.createModule(.{
        .root_source_file = b.path("core/audio_capture_stub.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_capture_stub_test_mod.addImport("capture_types", shared_modules.capture_types.mod);
    const audio_capture_stub_test = b.addTest(.{ .root_module = audio_capture_stub_test_mod });
    test_capture_types_step.dependOn(&b.addRunArtifact(audio_capture_stub_test).step);

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

    // core/capture_synthetic.zig (harness-built-in synthetic capture source).
    // Depends only on capture_types (no wiring into camera/audio facades). link_libc=true for
    // std.c.nanosleep on the audio generation thread (same reason as the core/audio_null.zig test).
    const capture_synthetic_test_mod = b.createModule(.{
        .root_source_file = b.path("core/capture_synthetic.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    capture_synthetic_test_mod.addImport("capture_types", shared_modules.capture_types.mod);
    const capture_synthetic_test = b.addTest(.{ .root_module = capture_synthetic_test_mod });
    test_capture_types_step.dependOn(&b.addRunArtifact(capture_synthetic_test).step);

    // canvas.zig unit tests
    const canvas_test_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/canvas.zig"),
        .target = target,
        .optimize = optimize,
    });
    canvas_test_mod.addImport("pixelops", shared_modules.pixelops.mod); // via blend.zig facade
    canvas_test_mod.addImport("font", shared_modules.font.mod); // via text_render.zig
    const canvas_test = b.addTest(.{ .root_module = canvas_test_mod });
    const run_canvas_test = b.addRunArtifact(canvas_test);
    test_png_roundtrip_step.dependOn(&run_canvas_test.step);

    // blend.zig unit tests (facade plumbing to pixelops; blend body tests live in test-pixelops)
    const blend_test_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/blend.zig"),
        .target = target,
        .optimize = optimize,
    });
    blend_test_mod.addImport("pixelops", shared_modules.pixelops.mod);
    const blend_test = b.addTest(.{ .root_module = blend_test_mod });
    const run_blend_test = b.addRunArtifact(blend_test);
    test_png_roundtrip_step.dependOn(&run_blend_test.step);

    // libs/pixelops unit tests (SIMD vs scalar premul/straight blend; div255 identity; clipBlit edges)
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

    // libs/gmath unit tests (Vec2 / Rect / scalar / collision; platform-independent)
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

    // libs/serde unit tests (versioned-container round-trip / corruption / forward compat / fixed fixtures)
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

    // libs/appshell unit tests (settings / window state / recent files)
    const appshell_test_mod = b.createModule(.{
        .root_source_file = b.path("libs/appshell/src/appshell.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // for std.c.getenv in paths.zig
    });
    appshell_test_mod.addImport("serde", shared_modules.serde.mod);
    const appshell_test = b.addTest(.{ .root_module = appshell_test_mod });
    const run_appshell_test = b.addRunArtifact(appshell_test);
    const test_appshell_step = b.step("test-appshell", "Run libs/appshell persistence tests");
    test_appshell_step.dependOn(&run_appshell_test.step);

    // libs/recipe unit tests (CommandRecord-sequence save/load; depends on serde)
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

    // editor/core tests (undo: stroke record + undo/redo + PNG round-trip; tool: Tool golden)
    // + pixie canvas_input (input state machine: capture / outside release / outside continue / ignore during stroke)
    const core_undo_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/undo.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_undo_mod.addImport("png", shared_modules.png.mod);
    core_undo_mod.addImport("pixelops", shared_modules.pixelops.mod);
    core_undo_mod.addImport("font", shared_modules.font.mod); // via canvas.zig → text_render.zig
    const core_undo_test = b.addTest(.{ .root_module = core_undo_mod });
    const run_core_undo_test = b.addRunArtifact(core_undo_test);

    const core_tool_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/tool.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_tool_mod.addImport("png", shared_modules.png.mod);
    core_tool_mod.addImport("pixelops", shared_modules.pixelops.mod);
    core_tool_mod.addImport("font", shared_modules.font.mod); // via canvas.zig → text_render.zig
    const core_tool_test = b.addTest(.{ .root_module = core_tool_mod });
    const run_core_tool_test = b.addRunArtifact(core_tool_test);

    // Flood fill + Fill Tool. Needs png/pixelops like tool.zig
    // (PNG round-trip tests + pixelops via canvas.zig).
    const core_fill_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/fill.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_fill_mod.addImport("png", shared_modules.png.mod);
    core_fill_mod.addImport("pixelops", shared_modules.pixelops.mod);
    core_fill_mod.addImport("font", shared_modules.font.mod); // via canvas.zig → text_render.zig
    const core_fill_test = b.addTest(.{ .root_module = core_fill_mod });
    const run_core_fill_test = b.addRunArtifact(core_fill_test);

    // Shape rasterize. Pure std-only function (no canvas).
    const core_shape_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/shape.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_shape_test = b.addTest(.{ .root_module = core_shape_mod });
    const run_core_shape_test = b.addRunArtifact(core_shape_test);

    // Bezier/vector path. bezier=pure. path/path_editor need the import because relative-import targets
    // (undo/path tests) use png (Zig also compiles tests in same-module @import targets).
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
    core_path_mod.addImport("font", shared_modules.font.mod); // via canvas.zig → text_render.zig
    const core_path_test = b.addTest(.{ .root_module = core_path_mod });
    const run_core_path_test = b.addRunArtifact(core_path_test);

    const core_path_editor_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/path_editor.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_path_editor_mod.addImport("png", shared_modules.png.mod);
    core_path_editor_mod.addImport("pixelops", shared_modules.pixelops.mod);
    core_path_editor_mod.addImport("font", shared_modules.font.mod); // via canvas.zig → text_render.zig
    const core_path_editor_test = b.addTest(.{ .root_module = core_path_editor_mod });
    const run_core_path_editor_test = b.addRunArtifact(core_path_editor_test);

    // Document / document_io. document_io.zig root also includes document.zig tests.
    // Needs serde(container) / png(exportPngSequence decode check) / pixelops(via canvas).
    const core_document_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/document_io.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_document_mod.addImport("serde", shared_modules.serde.mod);
    core_document_mod.addImport("png", shared_modules.png.mod);
    core_document_mod.addImport("pixelops", shared_modules.pixelops.mod);
    core_document_mod.addImport("font", shared_modules.font.mod); // via canvas.zig → text_render.zig
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
    canvas_input_core.addImport("png", shared_modules.png.mod); // paint.zig → document_io/io_png
    canvas_input_core.addImport("serde", shared_modules.serde.mod);
    canvas_input_core.addImport("font", shared_modules.font.mod); // paint.zig → canvas.zig → text_render.zig
    canvas_input_mod.addImport("paint", canvas_input_core);
    const canvas_input_test = b.addTest(.{ .root_module = canvas_input_mod });
    const run_canvas_input_test = b.addRunArtifact(canvas_input_test);

    // Selection core. Needs png because @import("undo.zig") also compiles undo's png-using tests.
    const core_selection_mod = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/selection.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_selection_mod.addImport("png", shared_modules.png.mod);
    core_selection_mod.addImport("pixelops", shared_modules.pixelops.mod);
    core_selection_mod.addImport("font", shared_modules.font.mod); // via canvas.zig → text_render.zig
    const core_selection_test = b.addTest(.{ .root_module = core_selection_mod });
    const run_core_selection_test = b.addRunArtifact(core_selection_test);

    // Selection input adapter. Named-import core (same shape as canvas_input; no png)
    const selection_input_core = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/paint.zig"),
    });
    const selection_input_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/selection_input.zig"),
        .target = target,
        .optimize = optimize,
    });
    selection_input_core.addImport("pixelops", shared_modules.pixelops.mod);
    selection_input_core.addImport("png", shared_modules.png.mod); // paint.zig → document_io/io_png
    selection_input_core.addImport("serde", shared_modules.serde.mod);
    selection_input_core.addImport("font", shared_modules.font.mod); // paint.zig → canvas.zig → text_render.zig
    selection_input_mod.addImport("paint", selection_input_core);
    const selection_input_test = b.addTest(.{ .root_module = selection_input_mod });
    const run_selection_input_test = b.addRunArtifact(selection_input_test);

    // Shape input adapter. Named-import core (same shape as selection_input)
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

    // Bezier input adapter. Named-import core (same shape as canvas_input)
    const bezier_input_core = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/paint.zig"),
    });
    const bezier_input_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/bezier_input.zig"),
        .target = target,
        .optimize = optimize,
    });
    bezier_input_core.addImport("pixelops", shared_modules.pixelops.mod);
    bezier_input_core.addImport("png", shared_modules.png.mod); // paint.zig → document_io/io_png
    bezier_input_core.addImport("serde", shared_modules.serde.mod);
    bezier_input_core.addImport("font", shared_modules.font.mod); // paint.zig → canvas.zig → text_render.zig
    bezier_input_mod.addImport("paint", bezier_input_core);
    const bezier_input_test = b.addTest(.{ .root_module = bezier_input_mod });
    const run_bezier_input_test = b.addRunArtifact(bezier_input_test);

    // Eyedropper input adapter. Named-import core (same shape as selection_input/bezier_input)
    const eyedropper_input_core = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/paint.zig"),
    });
    const eyedropper_input_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/eyedropper_input.zig"),
        .target = target,
        .optimize = optimize,
    });
    eyedropper_input_core.addImport("pixelops", shared_modules.pixelops.mod);
    eyedropper_input_core.addImport("png", shared_modules.png.mod); // paint.zig → document_io/io_png
    eyedropper_input_core.addImport("serde", shared_modules.serde.mod);
    eyedropper_input_core.addImport("font", shared_modules.font.mod); // paint.zig → canvas.zig → text_render.zig
    eyedropper_input_mod.addImport("paint", eyedropper_input_core);
    const eyedropper_input_test = b.addTest(.{ .root_module = eyedropper_input_mod });
    const run_eyedropper_input_test = b.addRunArtifact(eyedropper_input_test);

    // Brush footprint edge-cell cache. Pure logic; no gui/kit. Named-import core (same shape as canvas_input)
    const brush_edge_cache_core = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/paint.zig"),
    });
    const brush_edge_cache_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/brush_edge_cache.zig"),
        .target = target,
        .optimize = optimize,
    });
    brush_edge_cache_core.addImport("pixelops", shared_modules.pixelops.mod);
    brush_edge_cache_core.addImport("png", shared_modules.png.mod); // paint.zig → document_io/io_png
    brush_edge_cache_core.addImport("serde", shared_modules.serde.mod);
    brush_edge_cache_core.addImport("font", shared_modules.font.mod); // paint.zig → canvas.zig → text_render.zig
    brush_edge_cache_mod.addImport("paint", brush_edge_cache_core);
    const brush_edge_cache_test = b.addTest(.{ .root_module = brush_edge_cache_mod });
    const run_brush_edge_cache_test = b.addRunArtifact(brush_edge_cache_test);

    // pixie blit (canvas zoom transfer + checker). Named-import core (same shape as canvas_input)
    const blit_core = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/paint.zig"),
    });
    blit_core.addImport("png", shared_modules.png.mod);
    blit_core.addImport("pixelops", shared_modules.pixelops.mod);
    blit_core.addImport("serde", shared_modules.serde.mod); // paint.zig → document_io
    blit_core.addImport("font", shared_modules.font.mod); // paint.zig → canvas.zig → text_render.zig
    const blit_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/blit.zig"),
        .target = target,
        .optimize = optimize,
    });
    blit_test_mod.addImport("paint", blit_core);
    // blit.zig uses kit.pixelops (same instance as shared_modules.pixelops).
    const blit_pm = makePlatformModules(b, target, default_be, &shared_modules, false);
    blit_test_mod.addImport("kit", blit_pm.kit.mod);
    const blit_test = b.addTest(.{ .root_module = blit_test_mod });
    const run_blit_test = b.addRunArtifact(blit_test);

    // pixie zoom. rational Zoom + coordinate transforms. Named-import paint.
    const zoom_core = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/paint.zig"),
    });
    zoom_core.addImport("png", shared_modules.png.mod);
    zoom_core.addImport("pixelops", shared_modules.pixelops.mod);
    zoom_core.addImport("serde", shared_modules.serde.mod);
    zoom_core.addImport("font", shared_modules.font.mod);
    const zoom_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/zoom.zig"),
        .target = target,
        .optimize = optimize,
    });
    zoom_test_mod.addImport("paint", zoom_core);
    const zoom_test = b.addTest(.{ .root_module = zoom_test_mod });
    const run_zoom_test = b.addRunArtifact(zoom_test);

    // pixie minimap. Cache / mapping pure logic.
    const minimap_core = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/paint.zig"),
    });
    minimap_core.addImport("png", shared_modules.png.mod);
    minimap_core.addImport("pixelops", shared_modules.pixelops.mod);
    minimap_core.addImport("serde", shared_modules.serde.mod);
    minimap_core.addImport("font", shared_modules.font.mod);
    const minimap_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/minimap.zig"),
        .target = target,
        .optimize = optimize,
    });
    minimap_test_mod.addImport("paint", minimap_core);
    const minimap_test = b.addTest(.{ .root_module = minimap_test_mod });
    const run_minimap_test = b.addRunArtifact(minimap_test);

    // history_thumbnail. PixelDiff → 24×24 bbox thumbnail. Named-import paint.
    const history_thumbnail_core = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/paint.zig"),
    });
    history_thumbnail_core.addImport("png", shared_modules.png.mod);
    history_thumbnail_core.addImport("pixelops", shared_modules.pixelops.mod);
    history_thumbnail_core.addImport("serde", shared_modules.serde.mod);
    history_thumbnail_core.addImport("font", shared_modules.font.mod);
    const history_thumbnail_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/history_thumbnail.zig"),
        .target = target,
        .optimize = optimize,
    });
    history_thumbnail_mod.addImport("paint", history_thumbnail_core);
    const history_thumbnail_test = b.addTest(.{ .root_module = history_thumbnail_mod });
    const run_history_thumbnail_test = b.addRunArtifact(history_thumbnail_test);
    const test_history_thumbnail_step = b.step("test-history-thumbnail", "Run history_thumbnail unit tests");
    test_history_thumbnail_step.dependOn(&run_history_thumbnail_test.step);

    // onion_skin. Display-only onion composite inside paint.
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

    // pixie palette (model + GIMP .gpl). pure (std only; no imports).
    const palette_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/editor/apps/pixie/palette.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_palette_test = b.addRunArtifact(palette_test);

    // pixie action pure parser. std only; no App/kit; no imports.
    const actions_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/editor/apps/pixie/actions.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_actions_test = b.addRunArtifact(actions_test);

    // pixie visual diff. std only; no App/kit; no imports.
    const diff_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/editor/apps/pixie/diff.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_diff_test = b.addRunArtifact(diff_test);

    // history summary schema. Wires default-backend kit because it uses kit.platform.command types.
    const history_summary_pm = makePlatformModules(b, target, default_be, &shared_modules, false);
    const history_summary_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/history_summary.zig"),
        .target = target,
        .optimize = optimize,
    });
    history_summary_mod.addImport("kit", history_summary_pm.kit.mod);
    const history_summary_test = b.addTest(.{ .root_module = history_summary_mod });
    const run_history_summary_test = b.addRunArtifact(history_summary_test);
    const test_history_summary_step = b.step("test-history-summary", "Run history_summary schema unit tests");
    test_history_summary_step.dependOn(&run_history_summary_test.step);

    // Layer-name inline-edit input state machine. std only; no paint/App/kit; no imports.
    const layer_rename_input_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/editor/apps/pixie/layer_rename_input.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_layer_rename_input_test = b.addRunArtifact(layer_rename_input_test);

    // Text-layer content-edit input state machine. Independent implementation of the same design
    // pattern as layer_rename_input.zig. std only; no paint/App/kit; no imports.
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
    test_core_step.dependOn(&run_zoom_test.step);
    test_core_step.dependOn(&run_minimap_test.step);
    test_core_step.dependOn(&run_onion_skin_test.step);
    test_core_step.dependOn(&run_brush_edge_cache_test.step);
    test_core_step.dependOn(&run_actions_test.step);
    test_core_step.dependOn(&run_diff_test.step);
    test_core_step.dependOn(&run_history_summary_test.step);
    test_core_step.dependOn(&run_history_thumbnail_test.step);
    test_core_step.dependOn(&run_layer_rename_input_test.step);
    test_core_step.dependOn(&run_text_content_input_test.step);

    // ========================================
    // PNG decoder format.zig tests
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
    // platform_linux_input.zig tests (pure X11 input convert: keycode/modifier/EventQueue/KeyDownSet)
    // Pure Zig (no @cImport), so it runs OS-independently on the host too
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
    // platform_linux_convert.zig tests (pure X11 pixel convert: packPixel/maskShift/classifyVisual)
    // Pure Zig (no @cImport), so it runs OS-independently on the host too
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
    // platform_wayland_input.zig tests (pure Wayland input convert: evdev+8/BTN_*/wl_fixed/xkb modifier/
    // axis scroll/scroll coalesce/repeat timing). Pure Zig (no @cImport), so it runs OS-independently on the host too
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
    // platform_wayland_csd.zig tests (pure Wayland CSD decoration logic: layout/hit-test/
    // window geometry ⇄ content size convert/decoration draw). Pure Zig (no @cImport), so it runs on the host too
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
    // platform_windows_input.zig tests (pure Windows input convert: VK→KeyCode/modifier(post-state)/wheel sign)
    // Pure Zig (no @cImport), so it runs OS-independently on the host too
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
    // text.zig tests (BDF parser + draw)
    // ========================================
    const text_test_mod = b.createModule(.{
        .root_source_file = b.path("src/text.zig"),
        .target = target,
        .optimize = optimize,
    });
    text_test_mod.addImport("font", shared_modules.font.mod); // text.zig uses the shared Font IF
    const text_test = b.addTest(.{ .root_module = text_test_mod });
    const run_text_test = b.addRunArtifact(text_test);
    const test_text_step = b.step("test-text", "Run BDF parser and text rendering tests");
    test_text_step.dependOn(&run_text_test.step);

    // ========================================
    // libs/gfx/src/sprite.zig tests (blend / drawSprite / drawSpriteEx)
    // ========================================
    const sprite_test_png = b.createModule(.{
        .root_source_file = b.path("libs/png/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sprite_test_module = b.createModule(.{
        .root_source_file = b.path("libs/gfx/src/sprite.zig"),
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
    // libs/gfx tests (umbrella + moved helpers)
    // atlas/animation/camera/action_map are collected via gfx.zig relative import + test { _ = ... }.
    // ========================================
    const gfx_test_keyboard = b.createModule(.{
        .root_source_file = b.path("libs/gfx/src/keyboard.zig"),
        .target = target,
        .optimize = optimize,
    });
    gfx_test_keyboard.addImport("platform_types", shared_modules.types.mod);
    const gfx_test_ft = b.createModule(.{
        .root_source_file = b.path("libs/gfx/src/fixed_timestep.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gfx_test_fps = b.createModule(.{
        .root_source_file = b.path("libs/gfx/src/fps_counter.zig"),
        .target = target,
        .optimize = optimize,
    });
    // action_map @import("gamepad"), so the test root also shares gamepad (same types).
    const gfx_test_gamepad = b.createModule(.{
        .root_source_file = b.path("src/gamepad.zig"),
        .target = target,
        .optimize = optimize,
    });
    gfx_test_gamepad.addImport("platform_types", shared_modules.types.mod);
    const gfx_test_root = b.createModule(.{
        .root_source_file = b.path("libs/gfx/src/gfx.zig"),
        .target = target,
        .optimize = optimize,
    });
    gfx_test_root.addImport("sprite", sprite_test_module);
    gfx_test_root.addImport("fixed_timestep", gfx_test_ft);
    gfx_test_root.addImport("fps_counter", gfx_test_fps);
    gfx_test_root.addImport("keyboard", gfx_test_keyboard);
    gfx_test_root.addImport("gamepad", gfx_test_gamepad);
    gfx_test_root.addImport("platform_types", shared_modules.types.mod);
    gfx_test_root.addImport("gmath", shared_modules.gmath.mod); // TileMap
    const gfx_test = b.addTest(.{ .root_module = gfx_test_root });
    const run_gfx_test = b.addRunArtifact(gfx_test);
    const run_gfx_ft_test = b.addRunArtifact(b.addTest(.{ .root_module = gfx_test_ft }));
    const run_gfx_fps_test = b.addRunArtifact(b.addTest(.{ .root_module = gfx_test_fps }));
    const run_gfx_kb_test = b.addRunArtifact(b.addTest(.{ .root_module = gfx_test_keyboard }));
    const test_gfx_step = b.step("test-gfx", "Run libs/gfx umbrella and helper unit tests");
    test_gfx_step.dependOn(&run_gfx_test.step);
    test_gfx_step.dependOn(&run_gfx_ft_test.step);
    test_gfx_step.dependOn(&run_gfx_fps_test.step);
    test_gfx_step.dependOn(&run_gfx_kb_test.step);

    // ========================================
    // kit tests (toGuiEvent adapter etc.)
    // Root at kit/kit.zig and wire the same SharedModules instances
    // (avoids vacuous green when tests are not collected through a named module).
    // ========================================
    const kit_test_app_runtime = b.createModule(.{
        .root_source_file = b.path("core/app_runtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    kit_test_app_runtime.addImport("platform", shared_modules.platform.mod);
    kit_test_app_runtime.addImport("build_options", max_modules_mod);
    const kit_test_root = b.createModule(.{
        .root_source_file = b.path("kit/kit.zig"),
        .target = target,
        .optimize = optimize,
    });
    {
        const kit_tm: TaggedModule = .{ .layer = .kit, .name = "kit", .mod = kit_test_root };
        const ar_tm: TaggedModule = .{ .layer = .core, .name = "app_runtime", .mod = kit_test_app_runtime };
        wireKitImports(kit_tm, shared_modules.platform, &shared_modules, ar_tm);
    }
    const kit_test = b.addTest(.{ .root_module = kit_test_root });
    const run_kit_test = b.addRunArtifact(kit_test);
    const test_kit_step = b.step("test-kit", "Run kit umbrella unit tests (toGuiEvent adapter)");
    test_kit_step.dependOn(&run_kit_test.step);

    // ========================================
    // libs/gui tests (geom / color / draw / font + input / id / state / context)
    // Rooting at gui.zig runs tests from every referenced file together.
    // SharedModules.gui is for imports; build a dedicated module for tests.
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

    // test-gui-leak: measure PerIdStateStore unique-ID monotonic growth
    // (do not change libs/gui. Assert entry count for regression; print allocator bytes for notes)
    const gui_leak_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/gui_leak.zig"),
        .target = target,
        .optimize = optimize,
    });
    gui_leak_test_mod.addImport("gui", gui_test_root);
    const gui_leak_test = b.addTest(.{ .root_module = gui_leak_test_mod });
    const run_gui_leak_test = b.addRunArtifact(gui_leak_test);
    // Always show measurement lines (easier with --summary all)
    run_gui_leak_test.has_side_effects = true;
    const test_gui_leak_step = b.step("test-gui-leak", "Run GUI PerIdStateStore leak measurement");
    test_gui_leak_step.dependOn(&run_gui_leak_test.step);

    // libs/font tests (geom / color / Font IF + coverage draw path + BMFont)
    const font_test_mod = b.createModule(.{
        .root_source_file = b.path("libs/font/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    font_test_mod.addImport("png", shared_modules.png.mod); // used by bmfont.zig
    font_test_mod.addImport("pixelops", shared_modules.pixelops.mod); // used by color.zig
    const font_test = b.addTest(.{ .root_module = font_test_mod });
    const run_font_test = b.addRunArtifact(font_test);
    const test_font_step = b.step("test-font", "Run libs/font unit tests");
    test_font_step.dependOn(&run_font_test.step);

    // libs/synth tests (SPSC ring / NoteQueue / atomic params / output tap)
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

    // libs/sound tests (WAV decode / SoundPlayer SE+BGM / RT zero-alloc)
    const sound_test_mod = b.createModule(.{
        .root_source_file = b.path("libs/sound/src/sound.zig"),
        .target = target,
        .optimize = optimize,
    });
    sound_test_mod.addImport("dsp", shared_modules.dsp.mod);
    sound_test_mod.addImport("synth", shared_modules.synth.mod);
    const sound_test = b.addTest(.{ .root_module = sound_test_mod });
    const run_sound_test = b.addRunArtifact(sound_test);
    const test_sound_step = b.step("test-sound", "Run libs/sound unit tests");
    test_sound_step.dependOn(&run_sound_test.step);

    // apps/synth action pure parser. std only; no App/kit/dsp; no imports.
    const synth_actions_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/synth/actions.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_synth_actions_test = b.addRunArtifact(synth_actions_test);
    test_synth_step.dependOn(&run_synth_actions_test.step);

    // apps/synth voice/FX param serialize. std + serde only; no App/kit.
    const synth_patch_io_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/synth/patch_io.zig"),
        .target = target,
        .optimize = optimize,
    });
    synth_patch_io_test_mod.addImport("serde", shared_modules.serde.mod);
    const synth_patch_io_test = b.addTest(.{ .root_module = synth_patch_io_test_mod });
    const run_synth_patch_io_test = b.addRunArtifact(synth_patch_io_test);
    test_synth_step.dependOn(&run_synth_patch_io_test.step);

    // libs/modular tests (graph engine: topo / cycle delay edges / single connection / per-sample / variable frames / long render)
    const modular_test_mod = b.createModule(.{
        .root_source_file = b.path("libs/modular/src/modular.zig"),
        .target = target,
        .optimize = optimize,
    });
    modular_test_mod.addImport("dsp", shared_modules.dsp.mod);
    modular_test_mod.addImport("build_options", max_modules_mod);
    const modular_test = b.addTest(.{ .root_module = modular_test_mod });
    const run_modular_test = b.addRunArtifact(modular_test);
    const test_modular_step = b.step("test-modular", "Run libs/modular unit tests");
    test_modular_step.dependOn(&run_modular_test.step);

    // apps/noodle generative-layer tests (LofiPatch offline render: non-silent/finite/deterministic CRC).
    const modular_app_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/noodle/lofi.zig"),
        .target = target,
        .optimize = optimize,
    });
    modular_app_test_mod.addImport("modular", shared_modules.modular.mod);
    modular_app_test_mod.addImport("synth", shared_modules.synth.mod); // noodle uses AtomicF32
    modular_app_test_mod.addImport("dsp", shared_modules.dsp.mod); // noodle verifies band energy via FFT
    modular_app_test_mod.addImport("serde", shared_modules.serde.mod); // via project_io (GENR)
    const modular_app_test = b.addTest(.{ .root_module = modular_app_test_mod });
    const run_modular_app_test = b.addRunArtifact(modular_app_test);
    const test_app_modular_step = b.step("test-app-modular", "Run apps/noodle LofiPatch tests");
    test_app_modular_step.dependOn(&run_modular_app_test.step);

    // apps/noodle generation action pure parser. std only.
    const modular_actions_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/noodle/gen_actions.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_modular_actions_test = b.addRunArtifact(modular_actions_test);
    test_app_modular_step.dependOn(&run_modular_actions_test.step);

    // apps/noodle WAV writer. std only; streaming PCM16 RIFF/WAVE.
    const modular_wav_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/noodle/wav.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_modular_wav_test = b.addRunArtifact(modular_wav_test);
    test_app_modular_step.dependOn(&run_modular_wav_test.step);

    // apps/noodle scalar params + grid/303 pattern serialize. std + serde only;
    // no App/kit/modular (PatternPayload is a plain struct; main.zig converts to/from PatternCommand).
    const modular_pattern_io_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/noodle/pattern_io.zig"),
        .target = target,
        .optimize = optimize,
    });
    modular_pattern_io_test_mod.addImport("serde", shared_modules.serde.mod);
    const modular_pattern_io_test = b.addTest(.{ .root_module = modular_pattern_io_test_mod });
    const run_modular_pattern_io_test = b.addRunArtifact(modular_pattern_io_test);
    test_app_modular_step.dependOn(&run_modular_pattern_io_test.step);

    // apps/noodle integrated project serialize (KNGN). serde + modular (graph_io) + group/pattern_io.
    const modular_project_io_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/noodle/project_io.zig"),
        .target = target,
        .optimize = optimize,
    });
    modular_project_io_test_mod.addImport("serde", shared_modules.serde.mod);
    modular_project_io_test_mod.addImport("modular", shared_modules.modular.mod);
    // group.zig reads build_options.max_modules (relative import; same module)
    modular_project_io_test_mod.addImport("build_options", max_modules_mod);
    const modular_project_io_test = b.addTest(.{ .root_module = modular_project_io_test_mod });
    const run_modular_project_io_test = b.addRunArtifact(modular_project_io_test);
    test_app_modular_step.dependOn(&run_modular_project_io_test.step);

    // apps/noodle seed derive. std only.
    const modular_seed_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/noodle/seed.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_modular_seed_test = b.addRunArtifact(modular_seed_test);
    test_app_modular_step.dependOn(&run_modular_seed_test.step);

    // apps/noodle CommandRecord wiring contract. command is std only; uses existing APIs.
    const modular_cmd_seed_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/noodle/cmd_seed_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    modular_cmd_seed_test_mod.addImport("command", command_test_mod);
    const modular_cmd_seed_test = b.addTest(.{ .root_module = modular_cmd_seed_test_mod });
    const run_modular_cmd_seed_test = b.addRunArtifact(modular_cmd_seed_test);
    test_app_modular_step.dependOn(&run_modular_cmd_seed_test.step);

    // patch undo CommandAdapter contract (pattern/ring/epoch; no main)
    const noodle_undo_cmd_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/noodle/undo_cmd_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    noodle_undo_cmd_test_mod.addImport("command", command_test_mod);
    const noodle_undo_cmd_test = b.addTest(.{ .root_module = noodle_undo_cmd_test_mod });
    const run_noodle_undo_cmd_test = b.addRunArtifact(noodle_undo_cmd_test);
    test_app_modular_step.dependOn(&run_noodle_undo_cmd_test.step);

    // apps/noodle pure-logic test aggregate root (canvas: camera transform / hit-test / clip detect + group: group ledger /
    // expose derivation / display mapping. no display/audio)
    const patch_tests_mod = b.createModule(.{
        .root_source_file = b.path("apps/noodle/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    patch_tests_mod.addImport("gui", shared_modules.gui.mod);
    patch_tests_mod.addImport("modular", shared_modules.modular.mod);
    // group.zig reads build_options.max_modules (relative import; same module)
    patch_tests_mod.addImport("build_options", max_modules_mod);
    const patch_tests = b.addTest(.{ .root_module = patch_tests_mod });
    const run_patch_tests = b.addRunArtifact(patch_tests);
    const test_patch_step = b.step("test-noodle", "Run apps/noodle canvas + group logic tests");
    test_patch_step.dependOn(&run_patch_tests.step);

    // apps/noodle layout target-list wire format (std only; encode/decode + args budget).
    const patch_layout_wire_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/noodle/layout_wire.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_patch_layout_wire_test = b.addRunArtifact(patch_layout_wire_test);
    test_patch_step.dependOn(&run_patch_layout_wire_test.step);

    // apps/noodle action pure parser. std only; no App/kit/modular; no imports.
    const patch_actions_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/noodle/actions.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_patch_actions_test = b.addRunArtifact(patch_actions_test);
    test_patch_step.dependOn(&run_patch_actions_test.step);

    // apps/noodle node/edge topology serialize. std + serde + modular (ModuleKind
    // single source) only; no App/kit/canvas.
    const patch_graph_io_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/noodle/graph_io.zig"),
        .target = target,
        .optimize = optimize,
    });
    patch_graph_io_test_mod.addImport("serde", shared_modules.serde.mod);
    patch_graph_io_test_mod.addImport("modular", shared_modules.modular.mod);
    const patch_graph_io_test = b.addTest(.{ .root_module = patch_graph_io_test_mod });
    const run_patch_graph_io_test = b.addRunArtifact(patch_graph_io_test);
    test_patch_step.dependOn(&run_patch_graph_io_test.step);

    // apps/noodle macro builder tests (DrumMachine template: preflight/rollback/determinism/sound regression)
    const patch_macro_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/noodle/macro.zig"),
        .target = target,
        .optimize = optimize,
    });
    patch_macro_test_mod.addImport("modular", shared_modules.modular.mod);
    const patch_macro_test = b.addTest(.{ .root_module = patch_macro_test_mod });
    const run_patch_macro_test = b.addRunArtifact(patch_macro_test);
    const test_macro_step = b.step("test-macro", "Run apps/noodle macro (DrumMachine template) tests");
    test_macro_step.dependOn(&run_patch_macro_test.step);

    // src/dsp tests (Oscillator / Envelope / Filter / Mixer)
    const dsp_test_mod = b.createModule(.{
        .root_source_file = b.path("src/dsp/dsp.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dsp_test = b.addTest(.{ .root_module = dsp_test_mod });
    const run_dsp_test = b.addRunArtifact(dsp_test);
    const test_dsp_step = b.step("test-dsp", "Run src/dsp unit tests");
    test_dsp_step.dependOn(&run_dsp_test.step);

    // src/gamepad.zig tests (getButtonName/justPressed/justReleased/applyDeadzone).
    // Headless lib depending only on platform_types (no display/backend).
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

    // apps/synth spectrogram analysis tests (FFT column logic)
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

    // apps/synth oscilloscope / level-meter analysis tests (dsp-independent)
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
    // Aggregate test step (bundles every test-*)
    // Note: this runs tests only. Example build regression is covered by ordinary `zig build` (examples always install every backend).
    //     `-Dinstall-all=true` also installs main/pixie for every backend.
    // ========================================
    // Host-only packer + postMessage ring invariant tests (no wasm compile).
    const pack_single_html_test_mod = b.createModule(.{
        .root_source_file = b.path("cli/pack-single-html.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pack_single_html_test = b.addTest(.{ .root_module = pack_single_html_test_mod });
    const run_pack_single_html_test = b.addRunArtifact(pack_single_html_test);
    const audio_pm_ring_test_mod = b.createModule(.{
        .root_source_file = b.path("cli/audio_pm_ring.zig"),
        .target = target,
        .optimize = optimize,
    });
    const audio_pm_ring_test = b.addTest(.{ .root_module = audio_pm_ring_test_mod });
    const run_audio_pm_ring_test = b.addRunArtifact(audio_pm_ring_test);
    const test_pack_single_html_step = b.step(
        "test-pack-single-html",
        "Run single-HTML packer unit tests and postMessage ring invariants (host-only)",
    );
    test_pack_single_html_step.dependOn(&run_pack_single_html_test.step);
    test_pack_single_html_step.dependOn(&run_audio_pm_ring_test.step);

    const test_step = b.step("test", "Run all unit/integration tests");
    test_step.dependOn(test_pack_single_html_step);
    test_step.dependOn(test_frame_pacing_step);
    test_step.dependOn(test_png_roundtrip_step);
    test_step.dependOn(test_core_step);
    test_step.dependOn(test_png_format_step);
    test_step.dependOn(test_text_step);
    test_step.dependOn(test_sprite_step);
    test_step.dependOn(test_gfx_step);
    test_step.dependOn(test_kit_step);
    test_step.dependOn(test_font_step);
    test_step.dependOn(test_gui_step);
    test_step.dependOn(test_gui_leak_step);
    test_step.dependOn(test_synth_step);
    test_step.dependOn(test_modular_step);
    test_step.dependOn(test_app_modular_step);
    test_step.dependOn(test_patch_step);
    test_step.dependOn(test_macro_step);
    test_step.dependOn(test_dsp_step);
    test_step.dependOn(test_gamepad_step);
    test_step.dependOn(test_midi_step);
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
    test_step.dependOn(test_platform_facade_step);
    test_step.dependOn(test_platform_menu_step);
    test_step.dependOn(test_platform_null_step);
    test_step.dependOn(test_platform_clipboard_step);
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
    test_step.dependOn(test_sound_step);

    // ========================================
    // Micro-benchmarks. Pure-logic measurement (no display / audio device; OS-independent).
    // optimize is fixed to ReleaseFast: ignores -Doptimize (prevents Debug measurement accidents.
    // Keeps before/after comparisons on the same optimization level).
    // ========================================
    const bench_canvas_root = b.createModule(.{
        .root_source_file = b.path("bench/canvas.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    // Also build bench pixelops independently at ReleaseFast (do not inherit a shared instance)
    const bench_pixelops_mod = b.createModule(.{
        .root_source_file = b.path("libs/pixelops/src/lib.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    // Also build bench png/font independently at ReleaseFast (bench_canvas_core needs font via
    // canvas.zig → text_render.zig, so hoist them before the bench_gui definitions).
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
    bench_canvas_core.addImport("font", bench_font_mod); // via text_render.zig
    bench_canvas_root.addImport("editor_canvas", bench_canvas_core);
    const bench_canvas_exe = b.addExecutable(.{ .name = "bench_canvas", .root_module = bench_canvas_root });
    const bench_canvas_step = b.step("bench-canvas", "Run Canvas composite/compositeStraight micro-benchmark (ReleaseFast)");
    bench_canvas_step.dependOn(&b.addRunArtifact(bench_canvas_exe).step);

    // bench-fill: compare the u32 fill strategies behind pixelops.fill32 / fillRect32
    // (@memset vs a @Vector store loop vs seeding a block and replicating it with @memcpy).
    const bench_fill_root = b.createModule(.{
        .root_source_file = b.path("bench/fill.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_fill_root.addImport("pixelops", bench_pixelops_mod);
    const bench_fill_exe = b.addExecutable(.{ .name = "bench_fill", .root_module = bench_fill_root });
    const bench_fill_step = b.step("bench-fill", "Run u32 fill (framebuffer clear / rect fill) micro-benchmark (ReleaseFast)");
    bench_fill_step.dependOn(&b.addRunArtifact(bench_fill_exe).step);

    // bench-sprite: measure drawSprite / drawSpriteEx plain/flip/2x/tint.
    // No display/audio. Before/after comparisons stay on ReleaseFast.
    const bench_sprite_mod = b.createModule(.{
        .root_source_file = b.path("libs/gfx/src/sprite.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_sprite_mod.addImport("png", bench_png_mod);
    bench_sprite_mod.addImport("pixelops", bench_pixelops_mod);
    const bench_sprite_root = b.createModule(.{
        .root_source_file = b.path("bench/sprite.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_sprite_root.addImport("sprite", bench_sprite_mod);
    const bench_sprite_exe = b.addExecutable(.{ .name = "bench_sprite", .root_module = bench_sprite_root });
    const bench_sprite_step = b.step("bench-sprite", "Run sprite drawSprite/drawSpriteEx micro-benchmark (ReleaseFast)");
    bench_sprite_step.dependOn(&b.addRunArtifact(bench_sprite_exe).step);

    // bench-yuyv: measure pure V4L2 YUYV→BGRA color conversion.
    // The camera backend uses libc ioctl/mmap, but the bench only calls the pure function so no device is needed.
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

    // Peak-memory measuring allocator shared by bench-gui/-gui-frame/-blit/-viz
    const bench_peak_allocator_mod = b.createModule(.{
        .root_source_file = b.path("bench/peak_allocator.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    // Build dsp/synth for benches independently at ReleaseFast (do not use shared_modules instances,
    // which inherit the ordinary build's optimize)
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

    // bench-gui: measure rect_filled / image / text draw via the public API
    // (bench_png_mod/bench_font_mod were hoisted above for bench_canvas_core)
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
    bench_gui_root.addImport("peak_allocator", bench_peak_allocator_mod);
    const bench_gui_exe = b.addExecutable(.{ .name = "bench_gui", .root_module = bench_gui_root });
    const bench_gui_step = b.step("bench-gui", "Run GUI render (rect/image/text) micro-benchmark (ReleaseFast)");
    bench_gui_step.dependOn(&b.addRunArtifact(bench_gui_exe).step);

    // bench-gui-frame: full Context frame beginFrame → widget build → endFrame → gui.render
    const bench_gui_frame_root = b.createModule(.{
        .root_source_file = b.path("bench/gui_frame.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_gui_frame_root.addImport("gui", bench_gui_mod);
    bench_gui_frame_root.addImport("peak_allocator", bench_peak_allocator_mod);
    const bench_gui_frame_exe = b.addExecutable(.{ .name = "bench_gui_frame", .root_module = bench_gui_frame_root });
    const bench_gui_frame_step = b.step("bench-gui-frame", "Run GUI full Context frame benchmark 500/1000 rows (ReleaseFast)");
    bench_gui_frame_step.dependOn(&b.addRunArtifact(bench_gui_frame_exe).step);

    // bench-gui-list-menu: list/menu shell 500-row full Context frame (ReleaseFast fixed)
    // menuBar needs command_types, so build a separate gui module from bench_gui_mod.
    const bench_list_menu_cmd = b.createModule(.{
        .root_source_file = b.path("core/command_types.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_list_menu_cmd.addImport("platform_types", b.createModule(.{
        .root_source_file = b.path("core/platform_types.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    }));
    const bench_list_menu_gui = b.createModule(.{
        .root_source_file = b.path("libs/gui/src/gui.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_list_menu_gui.addImport("font", bench_font_mod);
    bench_list_menu_gui.addImport("pixelops", bench_pixelops_mod);
    bench_list_menu_gui.addImport("command_types", bench_list_menu_cmd);
    const bench_list_menu_ui = b.createModule(.{
        .root_source_file = b.path("examples/40_list_menu/ui.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_list_menu_ui.addImport("gui", bench_list_menu_gui);
    const bench_gui_list_menu_root = b.createModule(.{
        .root_source_file = b.path("bench/gui_list_menu.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_gui_list_menu_root.addImport("gui", bench_list_menu_gui);
    bench_gui_list_menu_root.addImport("list_menu_ui", bench_list_menu_ui);
    const bench_gui_list_menu_exe = b.addExecutable(.{ .name = "bench_gui_list_menu", .root_module = bench_gui_list_menu_root });
    const bench_gui_list_menu_step = b.step("bench-gui-list-menu", "Run GUI list/menu shell full Context frame benchmark 500 rows (ReleaseFast)");
    bench_gui_list_menu_step.dependOn(&b.addRunArtifact(bench_gui_list_menu_exe).step);

    // bench-blit: pixie canvas zoom transfer + checker background (measure old/new together)
    const bench_blit_core = b.createModule(.{
        .root_source_file = b.path("libs/paint/src/paint.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_blit_core.addImport("png", bench_png_mod);
    bench_blit_core.addImport("pixelops", bench_pixelops_mod);
    bench_blit_core.addImport("font", bench_font_mod); // paint.zig → canvas.zig → text_render.zig
    const bench_blit_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/apps/pixie/blit.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_blit_mod.addImport("paint", bench_blit_core);
    // blit.zig uses kit.pixelops (same path as the app). Kit is wired via makePlatformModules.
    const bench_blit_pm = makePlatformModules(b, target, default_be, &shared_modules, false);
    bench_blit_mod.addImport("kit", bench_blit_pm.kit.mod);
    const bench_blit_root = b.createModule(.{
        .root_source_file = b.path("bench/blit.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_blit_root.addImport("blit", bench_blit_mod);
    bench_blit_root.addImport("paint", bench_blit_core);
    bench_blit_root.addImport("peak_allocator", bench_peak_allocator_mod);
    const bench_blit_exe = b.addExecutable(.{ .name = "bench_blit", .root_module = bench_blit_root });
    const bench_blit_step = b.step("bench-blit", "Run pixie canvas blit/checker micro-benchmark (ReleaseFast)");
    bench_blit_step.dependOn(&b.addRunArtifact(bench_blit_exe).step);

    // bench-viz: Spec/Scope/Meter logical bitmap + image scale transfer
    const bench_viz_spec = b.createModule(.{
        .root_source_file = b.path("libs/viz/src/spectrogram.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_viz_spec.addImport("dsp", bench_dsp_mod);
    const bench_viz_scope = b.createModule(.{
        .root_source_file = b.path("libs/viz/src/scope.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench_viz_root = b.createModule(.{
        .root_source_file = b.path("bench/viz.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_viz_root.addImport("gui", bench_gui_mod);
    bench_viz_root.addImport("spectrogram", bench_viz_spec);
    bench_viz_root.addImport("scope", bench_viz_scope);
    bench_viz_root.addImport("peak_allocator", bench_peak_allocator_mod);
    const bench_viz_exe = b.addExecutable(.{ .name = "bench_viz", .root_module = bench_viz_root });
    const bench_viz_step = b.step("bench-viz", "Run patch viz bitmap/image scale micro-benchmark (ReleaseFast)");
    bench_viz_step.dependOn(&b.addRunArtifact(bench_viz_exe).step);

    // bench-modular: measure DynGraph.processBlock gen-skip effect.
    // modular depends only on dsp (same as test-modular). Built independently at ReleaseFast.
    const bench_modular_mod = b.createModule(.{
        .root_source_file = b.path("libs/modular/src/modular.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_modular_mod.addImport("dsp", bench_dsp_mod);
    bench_modular_mod.addImport("build_options", max_modules_mod);
    const bench_modular_root = b.createModule(.{
        .root_source_file = b.path("bench/modular.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_modular_root.addImport("modular", bench_modular_mod);
    const bench_modular_exe = b.addExecutable(.{ .name = "bench_modular", .root_module = bench_modular_root });
    const bench_modular_step = b.step("bench-modular", "Run DynGraph.processBlock micro-benchmark (ReleaseFast)");
    bench_modular_step.dependOn(&b.addRunArtifact(bench_modular_exe).step);

    // bench-lofi: compare LofiPatch.render before/after DynGraph swap under the same conditions.
    // patch needs only modular/synth/dsp, same as the pure-test root.
    const bench_lofi_patch_mod = b.createModule(.{
        .root_source_file = b.path("apps/noodle/lofi.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_lofi_patch_mod.addImport("modular", bench_modular_mod);
    bench_lofi_patch_mod.addImport("synth", bench_synth_mod);
    bench_lofi_patch_mod.addImport("dsp", bench_dsp_mod);
    bench_lofi_patch_mod.addImport("serde", shared_modules.serde.mod);
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
// exe / run-step names: default backend has no suffix; others get "_<backend>"
// (macOS: metal=bare / swift / objc, Linux: x11=bare, Windows: gdi=bare / d3d11)
// ============================================================
fn artifactName(b: *std.Build, base: []const u8, be: platform.PlatformType, default_be: platform.PlatformType) []const u8 {
    return if (be == default_be) base else b.fmt("{s}_{s}", .{ base, platform.backendName(be) });
}

// ============================================================
// Build per-backend platform / keyboard modules
// (platform module gets build_options.platform_backend)
// ============================================================
const PlatformModules = struct {
    platform: TaggedModule, // opt-in off (default; main/synth/modular/patch/most examples)
    platform_gamepad: TaggedModule, // gamepad opt-in (examples/22_gamepad / 34_action_map)
    platform_menu: TaggedModule, // for menu opt-in (shared by pixie/patch)
    keyboard: *std.Build.Module, // legacy src/ (examples only; outside layer management)
    kit: TaggedModule, // wire the platform (opt-in off) side
    kit_gamepad: TaggedModule, // wire the platform_gamepad side (example_34)
    kit_menu: TaggedModule, // for menu opt-in (shared by pixie/patch)
};

fn wireKitImports(kit: TaggedModule, platform_mod: TaggedModule, common: *const SharedModules, app_runtime: TaggedModule) void {
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
    link(kit, common.gamepad); // kit.gamepad
    link(kit, common.midi); // kit.midi
    link(kit, common.recipe); // kit.recipe
    link(kit, common.gmath); // kit.gmath
    link(kit, common.gfx); // kit.gfx
    link(kit, common.appshell); // kit.appshell
    link(kit, common.sound); // kit.sound
    link(kit, common.pixelops); // kit.pixelops (shared SIMD blend / u32 fill)
    link(kit, app_runtime);
}

fn makePlatformModules(b: *std.Build, target: std.Build.ResolvedTarget, backend: platform.PlatformType, common: *const SharedModules, wasm_shared: bool) PlatformModules {
    // opt-in-off edition (default). main/synth/modular/patch/most examples use this.
    const platform_mod: TaggedModule = .{ .layer = .core, .name = "platform", .mod = platform.createPlatformModule(
        b,
        target,
        b.path("core/platform.zig"),
        b.path("platform"),
        backend,
        common.types.mod,
        common.command_types.mod,
        common.harness.mod,
        .{},
    ) };
    // Gamepad opt-in-on edition. examples/22_gamepad only.
    const platform_gamepad_mod: TaggedModule = .{ .layer = .core, .name = "platform", .mod = platform.createPlatformModule(
        b,
        target,
        b.path("core/platform.zig"),
        b.path("platform"),
        backend,
        common.types.mod,
        common.command_types.mod,
        common.harness.mod,
        .{ .enable_gamepad = true },
    ) };
    // Native menu opt-in-on edition (shared across macOS objc/swift/metal; shared by pixie/patch).
    // Separate Module because build_options differ.
    const platform_menu_mod: TaggedModule = .{ .layer = .core, .name = "platform", .mod = platform.createPlatformModule(
        b,
        target,
        b.path("core/platform.zig"),
        b.path("platform"),
        backend,
        common.types.mod,
        common.command_types.mod,
        common.harness.mod,
        .{ .enable_menu = true },
    ) };
    // keyboard borrows KeyCode type defs from platform_types (opt-in-off types are enough;
    // depends on type-only core only, not the platform facade).
    const keyboard_mod = b.createModule(.{
        .root_source_file = b.path("libs/gfx/src/keyboard.zig"),
    });
    keyboard_mod.addImport("platform_types", common.types.mod);

    // app_runtime: frame-driven runtime. Depends on platform, so one per backend and per opt-in.
    const app_runtime: TaggedModule = .{ .layer = .core, .name = "app_runtime", .mod = b.createModule(.{
        .root_source_file = b.path("core/app_runtime.zig"),
        .target = target,
        .single_threaded = if (backend == .wasm) !wasm_shared else null,
    }) };
    link(app_runtime, platform_mod);
    app_runtime.mod.addImport("build_options", common.max_modules_mod);

    const app_runtime_gamepad: TaggedModule = .{ .layer = .core, .name = "app_runtime", .mod = b.createModule(.{
        .root_source_file = b.path("core/app_runtime.zig"),
        .target = target,
        .single_threaded = if (backend == .wasm) !wasm_shared else null,
    }) };
    link(app_runtime_gamepad, platform_gamepad_mod);
    app_runtime_gamepad.mod.addImport("build_options", common.max_modules_mod);

    const app_runtime_menu: TaggedModule = .{ .layer = .core, .name = "app_runtime", .mod = b.createModule(.{
        .root_source_file = b.path("core/app_runtime.zig"),
        .target = target,
        .single_threaded = if (backend == .wasm) !wasm_shared else null,
    }) };
    link(app_runtime_menu, platform_menu_mod);
    app_runtime_menu.mod.addImport("build_options", common.max_modules_mod);

    // kit umbrella (per backend; ADR-007 R4). Keep 1:1 with pub imports in kit/kit.zig.
    const kit: TaggedModule = .{ .layer = .kit, .name = "kit", .mod = b.createModule(.{
        .root_source_file = b.path("kit/kit.zig"),
    }) };
    wireKitImports(kit, platform_mod, common, app_runtime);

    // gamepad opt-in kit (example_34; platform_gamepad and ActionMap share the same opt-in)
    const kit_gamepad: TaggedModule = .{ .layer = .kit, .name = "kit", .mod = b.createModule(.{
        .root_source_file = b.path("kit/kit.zig"),
    }) };
    wireKitImports(kit_gamepad, platform_gamepad_mod, common, app_runtime_gamepad);

    // menu opt-in kit (wires enable_menu=true platform; shared by pixie/patch)
    const kit_menu: TaggedModule = .{ .layer = .kit, .name = "kit", .mod = b.createModule(.{
        .root_source_file = b.path("kit/kit.zig"),
    }) };
    wireKitImports(kit_menu, platform_menu_mod, common, app_runtime_menu);

    // BGRA→RGBA SIMD swizzle for wasm present (platform_wasm → pixelops).
    // ADR-007 core→lib exception via linkCoreException (bare addImport is not allowed).
    if (backend == .wasm) {
        linkCoreException(platform_mod, common.pixelops, "BGRA→RGBA SIMD swizzle for wasm present");
        linkCoreException(platform_gamepad_mod, common.pixelops, "BGRA→RGBA SIMD swizzle for wasm present");
        linkCoreException(platform_menu_mod, common.pixelops, "BGRA→RGBA SIMD swizzle for wasm present");
    }

    return .{
        .platform = platform_mod,
        .platform_gamepad = platform_gamepad_mod,
        .platform_menu = platform_menu_mod,
        .keyboard = keyboard_mod,
        .kit = kit,
        .kit_gamepad = kit_gamepad,
        .kit_menu = kit_menu,
    };
}

// ============================================================
// Helper: set up the main-app exe for one backend
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
    // src/main.zig is not under apps/, so it is outside R5 (kit-only); same legacy wiring as examples.
    exe.root_module.addImport("platform", pm.platform.mod);
    // Gamepad opt-in off (main does not use gamepad; keeps existing exes unchanged).
    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths, .{});
    return exe;
}

// ============================================================
// Shared modules (OS/backend-independent). Also includes external public modules (addModule).
// Our exes / examples use per-backend PlatformModules.platform, so platform/keyboard here are
// mainly for external consumers (dep.module("platform")) and tests.
// ADR-007: each shared module is created with a layer tag (TaggedModule) and wired through link().
// ============================================================
const SharedModules = struct {
    platform: TaggedModule, // External public facade (platform_backend gets the OS default; for dep.module("platform") and tests)
    keyboard: *std.Build.Module, // Legacy src/ helpers (examples only; outside layer management)
    sprite: *std.Build.Module, // Same as above
    fixed_timestep: *std.Build.Module, // Same as above
    fps_counter: *std.Build.Module, // Same as above
    text: *std.Build.Module, // Same as above
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
    gfx: TaggedModule, // libs/gfx (sprite/ft/fps/keyboard/atlas/animation/camera; kit-listed)
    serde: TaggedModule, // libs/serde (versioned-container serialization; std only)
    appshell: TaggedModule, // libs/appshell (settings / window / recent files)
    recipe: TaggedModule, // libs/recipe (CommandRecord-sequence save/replay; std + serde; kit-listed)
    paint: TaggedModule, // Former apps/editor/core (promoted to libs/paint under ADR-007 R6)
    spectrogram: TaggedModule, // libs/viz (former apps/synth/spectrogram.zig)
    scope: TaggedModule, // libs/viz (former apps/synth/scope.zig)
    capture_types: TaggedModule, // Shared capture-input types (type-only, same pattern as platform_types)
    camera: TaggedModule, // Camera L1 facade (core layer primitive at the same rank as audio)
    capture_synthetic: TaggedModule, // Harness-built-in synthetic capture source (no facade wiring)
    objc_runtime: TaggedModule, // Objective-C runtime FFI (shared module linked by both camera and audio; named module)
    gamepad: TaggedModule, // src/gamepad.zig (gamepad input helper; headless lib depending only on platform_types; kit-listed)
    sound: TaggedModule, // libs/sound (WAV decode + SE/BGM mixer; dsp + synth; kit-listed)
    midi: TaggedModule, // core/midi.zig (MIDI facade)
    /// modular/patch -Dmax-modules. Referenced by group.zig / addNoodleExe.
    max_modules: usize,
    /// Shared build_options Module (max_modules). createModule once; all consumers addImport.
    max_modules_mod: *std.Build.Module,

    /// `wasm_shared`: for AudioWorklet. single_threaded=false so atomics are enabled.
    /// `enable_gamepad`: build_options for the external public platform module (default false).
    /// `max_modules` / `max_modules_mod`: concurrent modular module limit (default 48).
    /// The wasm path passes enable_gamepad=false and max_modules=48.
    /// `target`: resolved target for the public platform module (needed by `linkSystemLibrary`).
    /// `platform_backend`: value of `-Dplatform` (or the OS default). Stamped into
    /// `build_options.platform_backend` and used to attach `@cImport`-required system libs
    /// (X11/Wayland). Must match the backend the consumer executable links against.
    fn init(b: *std.Build, is_wasm: bool, wasm_shared: bool, enable_gamepad: bool, max_modules: usize, max_modules_mod: *std.Build.Module, target: std.Build.ResolvedTarget, platform_backend: platform.PlatformType) SharedModules {
        // External public module (addModule). Available via dep.module("platform") and via kit.
        // Facade. Carries link_libc + include path for @cImport("platform.h"), plus backend-specific
        // system libs/headers needed for @cImport (see platform.configurePublicPlatformModule).
        // target is set so linkSystemLibrary can resolve pkg-config for the selected OS.
        //
        // When is_wasm, use createModule so the internal wasm package graph does not overwrite
        // the native public modules registered for external consumers (dep.module("platform")).
        const platform_mod: TaggedModule = .{ .layer = .core, .name = "platform", .mod = if (is_wasm)
            b.createModule(.{
                .root_source_file = b.path("core/platform.zig"),
                .target = target,
                .link_libc = true,
            })
        else
            b.addModule("platform", .{
                .root_source_file = b.path("core/platform.zig"),
                .target = target,
                .link_libc = true,
            }) };
        platform_mod.mod.addIncludePath(b.path("platform"));
        platform.configurePublicPlatformModule(b, platform_mod.mod, platform_backend);
        // build_options (gamepad/menu opt-in + platform_backend): the facade for external consumers
        // (tictactoe etc.; dep.module("platform") / dep.module("kit")) roots at core/platform.zig,
        // so the same named import is required. enable_gamepad opts in with `-Denable_gamepad=true`
        // (default false = safe side). platform_backend must match the consumer's chosen backend
        // so OS dispatchers do not @compileError.
        {
            const opts = b.addOptions();
            opts.addOption(bool, "enable_gamepad", enable_gamepad);
            opts.addOption(bool, "enable_menu", false);
            opts.addOption([]const u8, "platform_backend", platform.backendName(platform_backend));
            platform_mod.mod.addOptions("build_options", opts);
        }

        // External public module. dep.module("png").
        const png: TaggedModule = .{ .layer = .lib, .name = "png", .mod = if (is_wasm)
            b.createModule(.{ .root_source_file = b.path("libs/png/src/lib.zig") })
        else
            b.addModule("png", .{ .root_source_file = b.path("libs/png/src/lib.zig") }) };

        // libs/pixelops: shared pixel-blend primitives (premul/straight blend + div255 +
        // clip-hoist). sprite / paint blend / font Color.blend delegate here.
        const pixelops: TaggedModule = .{ .layer = .lib, .name = "pixelops", .mod = b.createModule(.{
            .root_source_file = b.path("libs/pixelops/src/lib.zig"),
        }) };

        // libs/gmath: platform-independent f32 game math and collision primitives.
        // It is a stable L2-L3 library and is publicly exposed through kit.gmath.
        const gmath: TaggedModule = .{ .layer = .lib, .name = "gmath", .mod = if (is_wasm)
            b.createModule(.{ .root_source_file = b.path("libs/gmath/src/lib.zig") })
        else
            b.addModule("gmath", .{ .root_source_file = b.path("libs/gmath/src/lib.zig") }) };

        // libs/serde: versioned-container serialization (std only; no link needed).
        // Flux lib: not in kit; apps may direct-import (app_direct_ok=true). First adopter is
        // pixie Document. Not published externally, so createModule (not addModule).
        const serde: TaggedModule = .{ .layer = .lib, .name = "serde", .app_direct_ok = true, .mod = b.createModule(.{
            .root_source_file = b.path("libs/serde/src/serde.zig"),
        }) };

        const appshell: TaggedModule = .{ .layer = .lib, .name = "appshell", .mod = b.createModule(.{
            .root_source_file = b.path("libs/appshell/src/appshell.zig"),
        }) };
        link(appshell, serde);

        // libs/recipe: CommandRecord-sequence save/replay (std + serde only).
        // Kit-listed (apps go through kit.recipe; R5). No core dependency.
        const recipe: TaggedModule = .{ .layer = .lib, .name = "recipe", .mod = b.createModule(.{
            .root_source_file = b.path("libs/recipe/src/recipe.zig"),
        }) };
        link(recipe, serde);

        // Shared types module (platform_types): single source for KeyCode/Event/EventStats etc.
        // Type-only (the only core module libs may reference; see ADR-007).
        // platform (facade+backends) and harness import the **same instance** so
        // type identity holds (Event/EventStats cross harness↔platform).
        const types: TaggedModule = .{ .layer = .core, .name = "platform_types", .type_only = true, .mod = b.createModule(.{
            .root_source_file = b.path("core/platform_types.zig"),
        }) };
        link(platform_mod, types);

        // keyboard borrows KeyCode from platform_types (libs/gfx; type-only core only).
        // Keep the examples-only named module name `keyboard` (consumer import statements unchanged).
        const keyboard_mod = b.createModule(.{
            .root_source_file = b.path("libs/gfx/src/keyboard.zig"),
        });
        keyboard_mod.addImport("platform_types", types.mod);

        // Shared menu/command types. Type-only like platform_types; libs/gui and
        // the platform facade share one instance. The adapter is a core execution contract, so
        // it is wired only into the facade as a separate ordinary core module.
        const command_types: TaggedModule = .{ .layer = .core, .name = "command_types", .type_only = true, .mod = b.createModule(.{
            .root_source_file = b.path("core/command_types.zig"),
        }) };
        link(command_types, types);
        link(platform_mod, command_types);

        // src/gamepad.zig: gamepad input helper (ADR-009). Headless lib depending only on
        // platform_types (layer=.lib). First use of ADR-007 R2 ("libs may direct-reference a type-only
        // core module") — the `link()` branch `.lib => dep.layer==.core and dep.type_only`.
        // keyboard also moved into libs/gfx and is published via kit.gfx.
        const gamepad: TaggedModule = .{ .layer = .lib, .name = "gamepad", .mod = b.createModule(.{
            .root_source_file = b.path("src/gamepad.zig"),
        }) };
        link(gamepad, types);

        const sprite = b.createModule(.{
            .root_source_file = b.path("libs/gfx/src/sprite.zig"),
        });
        sprite.addImport("png", png.mod);
        sprite.addImport("pixelops", pixelops.mod);

        const fixed_timestep_mod = b.createModule(.{
            .root_source_file = b.path("libs/gfx/src/fixed_timestep.zig"),
        });
        const fps_counter_mod = b.createModule(.{
            .root_source_file = b.path("libs/gfx/src/fps_counter.zig"),
        });

        // libs/gfx umbrella. Re-exports named sprite/helpers modules. Kit-listed.
        // action_map depends on gamepad + platform_types (MAX_GAMEPADS) via relative import of action_map.zig.
        const gfx: TaggedModule = .{ .layer = .lib, .name = "gfx", .mod = b.createModule(.{
            .root_source_file = b.path("libs/gfx/src/gfx.zig"),
        }) };
        gfx.mod.addImport("sprite", sprite);
        gfx.mod.addImport("fixed_timestep", fixed_timestep_mod);
        gfx.mod.addImport("fps_counter", fps_counter_mod);
        gfx.mod.addImport("keyboard", keyboard_mod);
        link(gfx, gamepad); // ActionMap gamepad button/stick evaluation
        link(gfx, types); // action_map MAX_GAMEPADS (type-only core)
        link(gfx, gmath); // TileMap collision queries

        // libs/font: shared font abstraction + canonical pixel/geom primitives (below gui)
        // BMFont loader (bmfont.zig) depends on png to decode the PNG atlas.
        // External public module. dep.module("font"). Depends on png.
        const font: TaggedModule = .{ .layer = .lib, .name = "font", .mod = if (is_wasm)
            b.createModule(.{ .root_source_file = b.path("libs/font/src/lib.zig") })
        else
            b.addModule("font", .{ .root_source_file = b.path("libs/font/src/lib.zig") }) };
        link(font, png);
        link(font, pixelops); // Color.blend in color.zig delegates here

        // src/text.zig depends on font because it implements the shared Font IF (libs/font).
        const text_mod = b.createModule(.{
            .root_source_file = b.path("src/text.zig"),
        });
        text_mod.addImport("font", font.mod);

        // External public module. dep.module("gui"). Depends on font.
        const gui: TaggedModule = .{ .layer = .lib, .name = "gui", .mod = if (is_wasm)
            b.createModule(.{ .root_source_file = b.path("libs/gui/src/gui.zig") })
        else
            b.addModule("gui", .{ .root_source_file = b.path("libs/gui/src/gui.zig") }) };
        link(gui, font);
        link(gui, pixelops); // drawImage SIMD in render.zig
        link(gui, command_types);

        // objc_runtime (L1): minimal Objective-C runtime FFI helper. Used by both camera_macos.zig
        // (camera module) and audio_macos.zig (audio module; mic permission checks), so
        // create one named module and link it into both. Unlike `capture_types`, the reason is not type
        // identity but Zig's rule that "the same file cannot belong to two different modules"
        // (both camera and audio used to relative-`@import("objc_runtime.zig")`, which collided when
        // both modules were linked into one exe; see the doc comment on core/objc_runtime.zig).
        // link_libc=true because it uses std.c.nanosleep (blocking wait for permission
        // checks).
        const objc_runtime: TaggedModule = .{ .layer = .core, .name = "objc_runtime", .mod = b.createModule(.{
            .root_source_file = b.path("core/objc_runtime.zig"),
            .link_libc = true,
        }) };

        // audio (L1 audio output): independent of the platform backend. No @cImport, so
        // an ordinary createModule is enough (audio system libs are linked per-OS on the exe side:
        // macOS=AudioToolbox / Linux=asound / Windows=ole32(WASAPI); see linkAudioBackend).
        const audio: TaggedModule = .{ .layer = .core, .name = "audio", .mod = b.createModule(.{
            .root_source_file = b.path("core/audio.zig"),
        }) };

        // harness (core/control; headless verification = control + observation plane): the **single
        // instance** shared by the platform facade and the audio facade. To share module-level state (audio tap etc.)
        // within one exe, inject the same harness into both the platform module (per-backend,
        // makePlatformModules→createPlatformModule) and the audio module.
        // harness depends on png (encodePNG/crc32) and link_libc for getenv.
        // Under wasm, swap in harness_wasm.zig (no-op stub) and do not wire png/capture_synthetic/dsp.
        const harness: TaggedModule = .{
            .layer = .core,
            .name = "harness",
            .mod = b.createModule(.{
                .root_source_file = b.path(if (is_wasm) "core/control/harness_wasm.zig" else "core/control/harness.zig"),
                .link_libc = !is_wasm,
                // wasm non-shared (pixie): single_threaded. shared audio (synth): multi (atomics).
                .single_threaded = if (is_wasm) !wasm_shared else null,
            }),
        };
        // The command adapter re-exports the command module held by harness from the facade.
        link(harness, command_types);
        if (!is_wasm) {
            linkCoreException(harness, png, "PNG encode / crc32 for snapshot fb (ADR-007 R1 exception)");
        }
        link(harness, types);
        // The public platform module (addModule "platform") also goes through harness, so it propagates.
        link(platform_mod, harness);
        // The audio facade (core/audio.zig) calls onAudioSamples via `@import("harness")`.
        link(audio, harness);

        // MIDI facade (L1). macOS selects CoreMIDI; other OSes select midi_null; under harness, read the synthetic FIFO.
        // platform_types and harness share the same named-module instance.
        const midi: TaggedModule = .{ .layer = .core, .name = "midi", .mod = b.createModule(.{
            .root_source_file = b.path("core/midi.zig"),
        }) };
        link(midi, types);
        link(midi, harness);
        // macOS: audio_macos.zig capture (mic) extension hits permission checks via objc_runtime.
        // Under wasm, audio_web never touches objc; the import wiring is harmless (unreferenced = not analyzed).
        if (!is_wasm) link(audio, objc_runtime);

        // Shared capture-input types: control-plane common types + data-plane types
        // (DeviceInfo/PermissionState/CaptureError/AudioInFrame/PixelFormat/VideoFrame/TripleBuffer).
        // Type-only module like platform_types. Both camera and audio must link the same instance
        // (Zig relative imports yield per-module type instances, so shared types that need identity
        // must be a named module; see docs/capture.md).
        const capture_types: TaggedModule = .{ .layer = .core, .name = "capture_types", .type_only = true, .mod = b.createModule(.{
            .root_source_file = b.path("core/capture_types.zig"),
        }) };
        // Used by the audio facade (core/audio.zig) capture extension via `@import("capture_types")`.
        link(audio, capture_types);

        // camera (L1 camera input): core layer primitive at the same rank as audio.
        // Dispatches by builtin.os.tag to camera_macos / camera_v4l2 / camera_stub, and shares
        // the harness isCaptureSyntheticActive() seam.
        const camera: TaggedModule = .{ .layer = .core, .name = "camera", .mod = b.createModule(.{
            .root_source_file = b.path("core/camera.zig"),
        }) };
        link(camera, capture_types);
        link(camera, harness); // isCaptureSyntheticActive() seam
        if (!is_wasm) link(camera, objc_runtime); // macOS: camera_macos.zig drives AVFoundation via objc_runtime

        // capture_synthetic (L1): harness-built-in synthetic capture source (fake mic/camera).
        // No wiring into camera/audio facades; only the harness built-in `capture`
        // command/probe consumes it (see the `isCaptureSyntheticActive()` doc comment).
        // Depends only on capture_types. link_libc=true for std.c.nanosleep (real-time pacing of the
        // audio generation thread — a POSIX sleep requirement, not a std.Thread.spawn one;
        // same situation as core/audio_null.zig).
        const capture_synthetic: TaggedModule = .{ .layer = .core, .name = "capture_synthetic", .mod = b.createModule(.{
            .root_source_file = b.path("core/capture_synthetic.zig"),
            .link_libc = true,
        }) };
        link(capture_synthetic, capture_types);
        // harness.zig uses it via `@import("capture_synthetic")` (`capture` command/probe).
        // The wasm stub does not depend on capture_synthetic, so do not wire it.
        if (!is_wasm) link(harness, capture_synthetic);

        // dsp (L2): Oscillator / Envelope / Filter / Mixer. Pure Zig.
        // (Still physically under src/dsp; move into libs/audio is opportunistic under R8.)
        const dsp: TaggedModule = .{ .layer = .lib, .name = "dsp", .mod = b.createModule(.{
            .root_source_file = b.path("src/dsp/dsp.zig"),
        }) };
        // digest audio band/centroid/onset uses magnitudeSpectrum.
        // Link harness after dsp is defined (linkCoreException, same as png; recorded in ADR-007).
        // The wasm stub does not depend on dsp, so do not wire it.
        if (!is_wasm) linkCoreException(harness, dsp, "digest audio spectrum analysis (band/centroid/onset)");

        // synth (L3): Voice/VoicePool/Patch/Synth + GUI↔Audio handoff. Depends on dsp.
        const synth: TaggedModule = .{ .layer = .lib, .name = "synth", .mod = b.createModule(.{
            .root_source_file = b.path("libs/synth/src/synth.zig"),
        }) };
        link(synth, dsp);

        // sound (L3): WAV decode + SE one-shot / BGM loop mixer.
        // Depends on dsp (equalPowerPan) and synth (SpscRing / AtomicF32). Kit-listed.
        const sound: TaggedModule = .{ .layer = .lib, .name = "sound", .mod = b.createModule(.{
            .root_source_file = b.path("libs/sound/src/sound.zig"),
        }) };
        link(sound, dsp);
        link(sound, synth);

        // modular (L3): modular graph engine. Depends only on dsp.
        // In flux, so not in kit (apps direct-import via app_direct_ok).
        // Concurrent module limit injected at comptime via build_options.max_modules.
        const modular: TaggedModule = .{ .layer = .lib, .name = "modular", .app_direct_ok = true, .mod = b.createModule(.{
            .root_source_file = b.path("libs/modular/src/modular.zig"),
        }) };
        modular.mod.addImport("build_options", max_modules_mod);
        link(modular, dsp);

        // paint (former apps/editor/core; promoted to libs under R6): Canvas/Tool/Undo/Selection/PNG I/O.
        // Editor-family shared lib; not on the general kit (only matching apps such as pixie direct-import).
        const paint: TaggedModule = .{ .layer = .lib, .name = "paint", .app_direct_ok = true, .mod = b.createModule(.{
            .root_source_file = b.path("libs/paint/src/paint.zig"),
        }) };
        link(paint, png); // io_png.zig delegates to the PNG codec (libs/png)
        link(paint, pixelops); // blend.zig delegates here
        link(paint, serde); // document_io.zig delegates to the versioned container (libs/serde)
        link(paint, font); // canvas.zig → text_render.zig delegates text rasterization

        // libs/viz (former apps/synth visualization. Shared by the synth/modular/patch apps, so
        // moved to libs under R6 "reuse vs terminal". In flux, so not in kit).
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
            .fixed_timestep = fixed_timestep_mod,
            .fps_counter = fps_counter_mod,
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
            .gfx = gfx,
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
            .sound = sound,
            .midi = midi,
            .max_modules = max_modules,
            .max_modules_mod = max_modules_mod,
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
    needs_paint: bool = false,
    needs_audio: bool,
    needs_gamepad: bool, // examples/22_gamepad / 34_action_map
    needs_midi: bool, // true only for examples/29_midi_monitor
    needs_gmath: bool, // true only for examples/25_collision_demo
    needs_sound: bool, // true only for examples/30_sound_demo
    needs_kit: bool = false, // example_31/32/33/34/36/38 / example_26
};

// ============================================================
// Helper: set up an example exe for one backend
// platform / keyboard come from the per-backend pm; other shared modules from common.
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
    // Every example uses platform / keyboard
    // (examples are teaching material outside R5=kit-only; keep legacy per-module wiring)
    // Gamepad opt-in: only needs_gamepad examples (22 / 34) use the
    // opt-in-enabled platform module (GameController framework link + enable gamepad code in .m/.swift).
    // Other examples use the default opt-in-disabled side (existing exes unchanged).
    exe.root_module.addImport("platform", if (needs.needs_gamepad) pm.platform_gamepad.mod else pm.platform.mod);
    exe.root_module.addImport("keyboard", pm.keyboard);
    if (needs.needs_sprite) exe.root_module.addImport("sprite", common.sprite);
    if (needs.needs_fps_counter) exe.root_module.addImport("fps_counter", common.fps_counter);
    if (needs.needs_fixed_timestep) exe.root_module.addImport("fixed_timestep", common.fixed_timestep);
    if (needs.needs_text) exe.root_module.addImport("text", common.text);
    if (needs.needs_gui) exe.root_module.addImport("gui", common.gui.mod);
    if (needs.needs_png) exe.root_module.addImport("png", common.png.mod);
    if (needs.needs_font) exe.root_module.addImport("font", common.font.mod);
    if (needs.needs_paint) {
        // paint is a flux lib not in kit. Layer.app_direct_ok=true, so example roots may direct-import it.
        linkAppException(appRoot(exe, name), common.paint, "example_26 doodle direct paint import");
    }
    if (needs.needs_audio) {
        exe.root_module.addImport("audio", common.audio.mod);
        // L1 audio-output system libraries (only on needs_audio exes; per OS).
        linkAudioBackend(exe, target.result.os.tag);
    }
    // gamepad is a backend-independent lib depending only on platform_types. Direct-addImport from
    // common (SharedModules) (matches the existing examples convention of not using kit).
    if (needs.needs_gamepad) exe.root_module.addImport("gamepad", common.gamepad.mod);
    if (needs.needs_midi) {
        exe.root_module.addImport("midi", common.midi.mod);
        // CoreMIDI and other system frameworks are opt-in linked only on needs_midi exes (same shape as audio).
        linkMidiBackend(exe, target.result.os.tag);
    }
    if (needs.needs_gmath) exe.root_module.addImport("gmath", common.gmath.mod);
    if (needs.needs_sound) exe.root_module.addImport("sound", common.sound.mod);
    if (needs.needs_kit) {
        // needs_gamepad kit examples use kit_gamepad wired to platform_gamepad.
        exe.root_module.addImport("kit", if (needs.needs_gamepad) pm.kit_gamepad.mod else pm.kit.mod);
    }
    if (std.mem.startsWith(u8, name, "example_26")) {
        exe.root_module.addImport("appshell", common.appshell.mod);
    }

    // build_options: for showing platform name / build mode in the startup banner.
    // Any example may read `@import("build_options").platform_name`.
    // (Separate module scope from build_options.platform_backend on the platform module)
    const opts = b.addOptions();
    opts.addOption([]const u8, "platform_name", platform.backendName(platform_type));
    exe.root_module.addOptions("build_options", opts);

    // Gamepad opt-in: only needs.needs_gamepad exes get GameController framework
    // link + .m/.swift gamepad code enabled (aligned with the addImport choice above).
    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths, .{ .enable_gamepad = needs.needs_gamepad });
    return exe;
}

// ============================================================
// Helper: set up a pixie exe for one backend
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
    // apps are kit-only consumers (R5). paint is an editor-family shared lib (not in kit; in flux) and is direct-imported.
    // Native menu opt-in: kit_menu (enable_menu=true) + shared menu.m (-DKNGN_ENABLE_MENU).
    // Shared across macOS objc/swift/metal. Do not change the enable_menu default of false.
    const root = appRoot(exe, "pixie");
    link(root, pm.kit_menu);
    link(root, common.paint);
    // pixelops is re-exported via kit (kit.pixelops); no direct apps → pixelops link.

    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths, .{ .enable_menu = true });
    return exe;
}

// ============================================================
// Helper: set up a patch app exe for one backend (apps/noodle)
// platform + gui + modular (dynamic graph engine) + audio (live rewiring makes sound).
// canvas.zig/group.zig/macro.zig are pulled in via relative @import from main.zig (same module)
// (apps/noodle/main.zig relative-imports lofi.zig. macro.zig's
// @import("modular") resolves the "modular" named import already registered on this exe.root_module).
// ============================================================
fn addNoodleExe(
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
            .root_source_file = b.path("apps/noodle/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // apps are kit-only consumers (R5). platform/gui/audio/synth/dsp via kit.*.
    // modular / viz (libs/viz) are in flux and not in kit, so direct-import.
    // Native menu opt-in: kit_menu (enable_menu=true) + shared menu.m (shared with pixie).
    // group.zig reads build_options.max_modules (relative import; same module).
    // Share the same Module instance as modular (avoid a second options.zig root).
    exe.root_module.addImport("build_options", common.max_modules_mod);
    const root = appRoot(exe, "patch");
    link(root, pm.kit_menu);
    link(root, common.modular); // Dynamic graph engine (dsp-only dependency; also referenced by macro.zig)
    link(root, common.spectrogram); // Signal visualization (master scope/spectrogram/level meter)
    link(root, common.scope);
    link(root, common.serde); // graph_io.zig (serialize: versioned-container serialization of node/edge topology)
    // pixelops is re-exported via kit (kit.pixelops); no direct apps → pixelops link.
    linkAppException(root, common.synth, "apps/noodle/lofi.zig uses the generative layer directly (SampleTap / AtomicF32)");
    linkAppException(root, common.dsp, "apps/noodle/lofi.zig uses the generative layer directly (FFT band energy checks)");
    linkAudioBackend(exe, target.result.os.tag); // macOS=AudioToolbox / Linux=asound / Windows=ole32
    // Opt-in link so run-noodle can use kit.midi (CoreMIDI).
    linkMidiBackend(exe, target.result.os.tag);

    // Gamepad opt-in off. Native menu opt-in on.
    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths, .{ .enable_menu = true });
    return exe;
}

// ============================================================
// Helper: set up a synth app exe for one backend (macOS/Linux/Windows; links the audio system lib)
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
    // apps are kit-only consumers (R5). platform/audio/synth/dsp/gui via kit.*.
    // Direct-import only viz (libs/viz; in flux, not in kit) + serde (serialize: patch_io.zig direct-imports it).
    const root = appRoot(exe, "synth");
    link(root, pm.kit);
    link(root, common.spectrogram);
    link(root, common.scope);
    link(root, common.serde); // patch_io.zig (versioned-container serialization of voice/FX params)
    linkAudioBackend(exe, target.result.os.tag); // L1 audio output (macOS=AudioToolbox / Linux=asound / Windows=ole32)

    // Gamepad opt-in off (this app does not use gamepad; keeps existing exes unchanged).
    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths, .{});
    return exe;
}

// ============================================================================
// Helper: set up the 20_capture_demo exe for one backend (examples/20_capture_demo).
//
// R5 (kit-only) covers apps/ only; examples are outside it (see build.zig header), so use the same
// direct-addImport wiring as other examples (no appRoot/link()). Directly consuming camera/audio/capture_synthetic
// (all core layer) is required because headless verification must direct-import the harness-built-in synthetic
// capture source (core/capture_synthetic.zig; an independent module not wired into the camera.zig/audio.zig
// facades) — unreachable from the apps layer under R5.
// The camera.zig/audio.zig facade APIs themselves are consumed as-is (not modified here).
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
    exe.root_module.addImport("harness", common.harness.mod); // for isCaptureSyntheticActive()
    exe.root_module.addImport("camera", common.camera.mod); // Real camera capture (macOS implementation / stub elsewhere)
    exe.root_module.addImport("audio", common.audio.mod); // Real mic capture extension (via audio.zig)
    exe.root_module.addImport("capture_synthetic", common.capture_synthetic.mod); // Harness-built-in synthetic source (only when KNGN_HARNESS_CAPTURE_SYNTHETIC=1)
    exe.root_module.addImport("spectrogram", common.spectrogram.mod);
    exe.root_module.addImport("scope", common.scope.mod);
    exe.root_module.addImport("synth", common.synth.mod); // SampleTap (lock-free mic-capture-callback → main-thread visualization handoff)
    linkAudioBackend(exe, target.result.os.tag); // macOS: AudioToolbox/CoreAudio + capture AVFoundation/CoreMedia/CoreVideo/Foundation/objc

    // Gamepad opt-in off (this app does not use gamepad; keeps existing exes unchanged).
    platform.setupExecutableForPlatform(b, exe, platform_type, optimize, platform_root, sdk_paths, .{});
    return exe;
}

// ============================================================
// Helper: link L1-output system libraries per OS onto exes that use audio.
// The audio module uses extern fn without @cImport, so linking is done on the exe side
// (macOS=AudioToolbox framework / Linux=ALSA libasound). libc is already enabled by backend setup.
//
// On Linux pass the pkg-config name "alsa" (provided by alsa-lib-dev). That resolves both
// `-lasound` and the lib path. Passing the library name "asound" directly finds no .pc, and
// zig only searches existing -L paths (X11 etc.), so it cannot find libasound.so (confirmed on a real Linux build).
// ============================================================
fn linkAudioBackend(exe: *std.Build.Step.Compile, target_os: std.Target.Os.Tag) void {
    switch (target_os) {
        // Also link capture frameworks (mic AUHAL input / camera AVFoundation).
        // Every caller also calls `platform.setupExecutableForPlatform` in the same function,
        // which sets the `-F <sdk>/System/Library/Frameworks` / `-L <sdk>/usr/lib` search paths
        // (`addMacOSSDKSearchPaths` in `build_helpers/macos.zig`), so here
        // `linkFramework`/`linkSystemLibrary` calls alone are enough (build-graph construction order does not
        // affect link-time resolution). Also linked so future apps that consume capture
        // and pass through this helper do not fail from missing frameworks.
        // Preventive addition (no exe currently uses these frameworks — harmless).
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
        // WASAPI goes through COM. CoCreateInstance/CoInitializeEx/CoTaskMemFree live in ole32
        // (IAudioClient etc. are obtained via COM so no direct link; Event API is kernel32=auto-linked).
        .windows => exe.root_module.linkSystemLibrary("ole32", .{}),
        else => @panic("audio backend is only available on macOS / Linux / Windows"),
    }
}

// ============================================================
// Helper: link CoreMIDI etc. per OS onto exes that use MIDI.
// The midi module uses extern fn without @cImport, so linking is done on the exe side.
// Same opt-in placement as audio's linkAudioBackend. Called only for needs_midi examples.
// Assumes setupExecutableForPlatform has attached the SDK framework search paths.
// ============================================================
fn linkMidiBackend(exe: *std.Build.Step.Compile, target_os: std.Target.Os.Tag) void {
    switch (target_os) {
        .macos => {
            exe.root_module.linkFramework("CoreMIDI", .{});
            exe.root_module.linkFramework("CoreFoundation", .{});
        },
        // macOS only. Other OSes use the null backend and need no framework.
        else => {},
    }
}

// For test-midi (bare addTest): explicitly set SDK framework/library search paths and link CoreMIDI.
// Same shape as linkCaptureMacFrameworks (does not go through platform.setupExecutableForPlatform).
fn linkMidiMacFrameworks(b: *std.Build, mod: *std.Build.Module, sdk_paths: macos.MacOSSDKPaths) void {
    mod.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk_paths.sdk_path}) });
    mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk_paths.sdk_path}) });
    mod.linkFramework("CoreMIDI", .{});
    mod.linkFramework("CoreFoundation", .{});
}

// ============================================================
// Framework link for capture-only tests (mic AUHAL input / camera AVFoundation).
// nix's zig does not auto-detect the SDK, so framework/library search paths are stated explicitly
// (same reason and paths as `addMacOSSDKSearchPaths` in `build_helpers/macos.zig`).
// Unlike `linkAudioBackend`, this targets bare `b.addTest` that does not go through
// `platform.setupExecutableForPlatform`, so the search paths themselves must be stated here.
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
// Generic helper to add a run step
// ============================================================
fn addRunStep(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    exe: *std.Build.Step.Compile,
    args: ?[]const []const u8,
) void {
    const run_cmd = b.addRunArtifact(exe);
    // Note: deliberately do not depend on b.getInstallStep(). getInstallStep bundles every installArtifact
    // (including every example backend), so depending on it would make run-* build every example
    // as a side effect. A run only needs that exe compiled, so stay with the exe-build dependency
    // that addRunArtifact attaches automatically (run straight from cache).
    if (args) |a| run_cmd.addArgs(a);
    const run_step = b.step(name, description);
    run_step.dependOn(&run_cmd.step);
}

// ============================================================
// Helper to add a build-only (do not run) step
// Installs (= builds) only that exe. Does not depend on getInstallStep, so
// it does not pull in other exes / examples (same reason as run-*).
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
// Helper: publish the platform native layer as a static lib (object archive)
//
// External packages linkLibrary `dep.artifact("platform_native_<plat>")`.
// Facade is `dep.module("platform")`. Only addObjectFile the compilePlatformLayer .o onto a minimal stub
// module and archive it. framework / Swift runtime / search paths
// cannot be resolved at static-lib build time (search paths also do not propagate to the consumer), so the
// consumer exe applies them (C-style: vendor macos/swift build helpers onto the exe).
// ============================================================
fn addPlatformNativeLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    platform_type: platform.PlatformType,
    name: []const u8,
    enable_gamepad: bool,
) *std.Build.Step.Compile {
    // Gamepad opt-in for the external-consumer native archive.
    // Same boolean as build_options.enable_gamepad on the SharedModules public "platform".
    // The archive is .o only and does not include the GameController framework (consumer exe links it).
    // When enable_gamepad=true, -DKNGN_ENABLE_GAMEPAD is passed to .m/.swift and the real backend is enabled.
    const compiled = platform.compilePlatformLayer(b, platform_type, optimize, platform_root, .{
        .enable_gamepad = enable_gamepad,
    });

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("core/platform_native_stub.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (compiled.obj_files) |obj| {
        lib_mod.addObjectFile(obj);
    }
    // framework / Swift runtime / framework·library search paths cannot be resolved at static-lib build time
    // (`unable to find framework`), and search paths do not propagate to the consumer.
    // So this only archives the .o; link settings are applied on the consumer exe
    // (C-style: vendor macos.linkMacOSFrameworks / swift.linkSwiftRuntime).

    const lib = b.addLibrary(.{
        .name = name,
        .linkage = .static,
        .root_module = lib_mod,
    });
    for (compiled.compile_steps) |step| {
        lib.step.dependOn(&step.step);
    }
    // Install the header for the consumer's @cImport("platform.h") (also keeps the
    // linkLibrary installed-headers-include-tree path healthy).
    lib.installHeader(b.path("platform/platform.h"), "platform.h");
    b.installArtifact(lib);
    return lib;
}
