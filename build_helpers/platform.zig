//! Compile helpers for the platform layer (the macOS Swift + Metal sources, and the shared NSMenu .m)
//!
//! Used by this repository's own build.zig. Inputs are LazyPaths so they carry
//! build-graph dependencies.
//!
//! Anything building against the package — a sample in `examples/`, the editor, an
//! application elsewhere — imports `consumer.zig` instead, whether by vendoring it or
//! through `@import("kngn").build_helpers.consumer`. This file re-exports the shared
//! types and backend helpers from there and keeps the ones only this repository uses
//! (`createPlatformModule`, `compilePlatformLayer`, …).

const std = @import("std");
const macos = @import("macos.zig");
const consumer = @import("consumer.zig");

// Re-export the external-consumer surface (single implementation lives in consumer.zig).
pub const PlatformType = consumer.PlatformType;
pub const PlatformFeatures = consumer.PlatformFeatures;
pub const defaultBackend = consumer.defaultBackend;
pub const implementedBackends = consumer.implementedBackends;
pub const assertBackendForOs = consumer.assertBackendForOs;
pub const backendName = consumer.backendName;
pub const resolveBackend = consumer.resolveBackend;
pub const setupConsumerExe = consumer.setupConsumerExe;
pub const linkAudioBackend = consumer.linkAudioBackend;
pub const linkMidiBackend = consumer.linkMidiBackend;

// Wasm app + web package surface (single implementation in consumer.zig).
pub const WasmAudio = consumer.WasmAudio;
pub const WasmImport = consumer.WasmImport;
pub const WasmAppSpec = consumer.WasmAppSpec;
pub const WasmLinkContext = consumer.WasmLinkContext;
pub const WasmLinker = consumer.WasmLinker;
pub const WasmAppBuild = consumer.WasmAppBuild;
pub const PerAppWebInstall = consumer.PerAppWebInstall;
pub const WebStaticInstalls = consumer.WebStaticInstalls;
pub const WasmWebAssets = consumer.WasmWebAssets;
pub const AddWasmAppOptions = consumer.AddWasmAppOptions;
pub const AddWasmWebPackageOptions = consumer.AddWasmWebPackageOptions;
pub const validateWasmAppSpec = consumer.validateWasmAppSpec;
pub const addWasmApp = consumer.addWasmApp;
pub const addWasmWebPackage = consumer.addWasmWebPackage;
pub const makeWasmExportCheckExe = consumer.makeWasmExportCheckExe;

/// Whether an L1 audio-output backend is implemented for the OS (macOS=AudioToolbox / Linux=ALSA / Windows=WASAPI).
/// Used by both top-level build.zig and standalone as the gate for audio-required targets (synth / example_15)
/// (one place for the decision).
pub fn audioSupported(os: std.Target.Os.Tag) bool {
    return os == .macos or os == .linux or os == .windows;
}

/// The `single_threaded` every wasm module in the build graph compiles with — the app root,
/// `platform`, `app_runtime`, `harness`, and the published modules alike, whether or not the
/// target carries the wasm atomics feature for a shared-memory (`worklet_shared`) audio
/// transport (see `docs/adr/018_wasm-audio-transport-build-time-selection.md`).
///
/// `single_threaded` is a Zig-language setting (it governs `std.heap.wasm_allocator` —
/// `@compileError` when false — plus `std.Thread` availability and related codegen), which
/// is a different axis from the target's wasm atomics feature (a codegen concern: whether
/// `@atomicRmw` and friends lower to real wasm atomic instructions). A shared-memory synth
/// target selects atomics so its AudioWorklet second `WebAssembly.Instance` can synchronise
/// with the main thread through plain atomic reads and writes — no code in this backend
/// spawns a `std.Thread`, so nothing here calls for `single_threaded=false`, and
/// `core/platform_wasm.zig` uses `std.heap.wasm_allocator` unconditionally, which requires
/// `single_threaded=true` to compile at all. One value serves every wasm module in the build,
/// wasm-shared or not.
pub const wasm_single_threaded = true;

/// The build settings a `core/platform.zig` module needs, whichever path creates it.
///
/// Two paths do create one — `createPlatformModule` below for executables inside this
/// repository, and `build.zig` for the module external consumers receive as
/// `dep.module("platform")` — because they differ in how the module is registered and in
/// whether their imports go through the layer check of ADR-007. What must *not* differ is
/// the shape of the module itself, so it is decided here and nowhere else.
///
/// Runs at build-graph configuration time only (not per-frame / RT).
pub fn platformModuleOptions(
    target: std.Build.ResolvedTarget,
    platform_source: std.Build.LazyPath,
    backend: PlatformType,
) std.Build.Module.CreateOptions {
    const is_wasm = backend == .wasm;
    return .{
        .root_source_file = platform_source,
        // linkSystemLibrary needs a module with a known target, so it is set explicitly
        // (an imported module usually inherits from its importer, but the x11 link call
        // needs the target beforehand).
        .target = target,
        // Wasm reaches the host through wasi preview1 plus a hand-written JS shim. Linking
        // libc there pulls in crt1, whose `_start` export the browser glue cannot satisfy.
        .link_libc = !is_wasm,
        .single_threaded = if (is_wasm) wasm_single_threaded else null,
    };
}

/// Attach what the backend's `@cImport` needs: the `platform.h` include path on a native
/// target, plus backend-specific system libraries and generated headers.
///
/// Modules carry what `@cImport` needs to compile; executable-only requirements
/// (macOS native archive / frameworks / Swift runtime, Wayland private `.c`,
/// Windows system libs + subsystem) stay on `setupConsumerExe`.
///
/// Like `platformModuleOptions`, this is the single place that decides these, for the
/// module inside this repository and the published one alike.
///
/// Runs at build-graph configuration time only (not per-frame / RT).
pub fn configurePlatformModule(
    b: *std.Build,
    mod: *std.Build.Module,
    platform_include_root: std.Build.LazyPath,
    backend: PlatformType,
) void {
    // The macOS backend `@cImport("platform.h")`s. Wasm has no `@cImport` at all, and on
    // Linux and Windows the path is simply unused.
    if (backend != .wasm) mod.addIncludePath(platform_include_root);
    switch (backend) {
        .x11 => {
            // platform_linux_x11.zig `@cImport`s Xlib/XShm; linkSystemLibrary also
            // supplies pkg-config Cflags for header resolve and propagates libs to the exe.
            mod.linkSystemLibrary("X11", .{});
            mod.linkSystemLibrary("Xext", .{});
        },
        .wayland => {
            // platform_linux_wayland.zig `@cImport`s wayland-client / cursor / xkbcommon
            // plus generated xdg-shell / xdg-decoration / viewporter headers.
            mod.linkSystemLibrary("wayland-client", .{});
            mod.linkSystemLibrary("wayland-cursor", .{});
            mod.linkSystemLibrary("xkbcommon", .{});
            mod.addIncludePath(consumer.generateXdgShellClientHeaderDir(b));
            mod.addIncludePath(consumer.generateXdgDecorationClientHeaderDir(b));
            mod.addIncludePath(consumer.generateViewporterClientHeaderDir(b));
        },
        // macOS uses platform.h via the include path already on the module; native .o is exe-side.
        // Windows uses extern fn (no @cImport); system libs are exe-side.
        // wasm has no system libs.
        .metal, .gdi, .d3d11, .wasm => {},
    }
}

/// Stamp the platform module's `build_options`: the backend name plus the opt-in flags the
/// facade and the macOS backend read at comptime.
///
/// Only the flags that reach the module belong here. `enable_audio` and `enable_midi` are
/// executable-side link decisions and deliberately absent.
///
/// Runs at build-graph configuration time only (not per-frame / RT).
pub fn addPlatformBuildOptions(
    b: *std.Build,
    mod: *std.Build.Module,
    backend: PlatformType,
    features: PlatformFeatures,
) void {
    mod.addOptions("build_options", platformBuildOptions(b, backend, features));
}

/// The `build_options` the platform module reads, as a standalone `Options` step.
///
/// Split out so that a bare `addTest` rooted at a backend file can stamp exactly the same
/// set. Hand-writing the option list there means a flag added here is missing there, and the
/// test stops compiling for a reason that has nothing to do with the test.
///
/// Runs at build-graph configuration time only (not per-frame / RT).
pub fn platformBuildOptions(
    b: *std.Build,
    backend: PlatformType,
    features: PlatformFeatures,
) *std.Build.Step.Options {
    const opts = b.addOptions();
    opts.addOption([]const u8, "platform_backend", backendName(backend));
    opts.addOption(bool, "enable_gamepad", features.enable_gamepad);
    opts.addOption(bool, "enable_menu", features.enable_menu);
    opts.addOption(bool, "enable_dialog", features.enable_dialog);
    opts.addOption(bool, "enable_cursor", features.enable_cursor);
    opts.addOption(bool, "enable_mascot", features.enable_mascot);
    opts.addOption(bool, "enable_fullscreen", features.enable_fullscreen);
    opts.addOption(bool, "enable_text_input", features.enable_text_input);
    return opts;
}

/// Create the platform module (`core/platform.zig`) for an executable inside this repository.
///
/// The module's shape comes from `platformModuleOptions`, `configurePlatformModule` and
/// `addPlatformBuildOptions`; only the creation and the imports are decided here, because
/// the published module registers itself differently and routes its imports through the
/// layer check in `build.zig`.
///
/// `backend` is passed as `build_options.platform_backend` ("x11"/"wayland"/"metal"…) into the
/// platform module; `core/platform_linux.zig` and friends use it to pick x11/wayland.
/// Call once per backend so each gets its own module with a distinct value.
///
/// Path resolution (`b.path` / `cwd_relative`) is left to the callsite.
/// Parent build.zig uses `b.path(...)`; standalone uses
/// `.{ .cwd_relative = PROJECT_ROOT ++ ... }`.
///
pub fn createPlatformModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    platform_source: std.Build.LazyPath,
    platform_include_root: std.Build.LazyPath,
    backend: PlatformType,
    /// Shared types module (core/platform_types.zig). platform.zig + each backend `@import("platform_types")`.
    /// Pass the **same instance** as the harness module (for Event/EventStats type identity).
    types_mod: *std.Build.Module,
    /// Command/menu type-only module (core/command_types.zig). Shared contract between facade and backend.
    command_types_mod: *std.Build.Module,
    /// harness module (core/control/harness.zig). platform.zig (facade) `@import("harness")`.
    /// Pass the **same instance** as the audio module so module-level state (audio tap, …) is shared.
    harness_mod: *std.Build.Module,
    /// The opt-in features, baked into the platform module as `build_options.enable_*`.
    /// gamepad is read by the facade's `Window.getGamepadState`; the rest are read by the
    /// comptime gates on C-symbol references in `platform_macos.zig`.
    /// The harness paths (synthetic gamepad, injected characters) run regardless of these.
    features: PlatformFeatures,
) *std.Build.Module {
    const mod = b.createModule(platformModuleOptions(target, platform_source, backend));
    configurePlatformModule(b, mod, platform_include_root, backend);
    // platform.zig + backends `@import("platform_types")`; the facade `@import("harness")`.
    mod.addImport("platform_types", types_mod);
    mod.addImport("command_types", command_types_mod);
    mod.addImport("harness", harness_mod);
    addPlatformBuildOptions(b, mod, backend, features);

    return mod;
}

/// Set up the platform layer on an executable.
///
/// macOS backend: compile the platform layer (.o), link frameworks / Swift runtime, and
/// set include paths in one shot (`sdk_paths` required).
/// Linux backend: pure Zig, so no .o compile; only link X11 etc. (`sdk_paths` is null).
///
/// Each example's build.zig only needs this one call for all platform setup.
///
/// `features`: the macOS backend opt-ins. Only the enabled ones pass `-DKNGN_ENABLE_*` into
/// the .o compile, and the same value has to reach `createPlatformModule`, or the module's
/// `build_options` and the object file disagree. Ignored on Linux/Windows backends.
pub fn setupExecutableForPlatform(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    platform_type: PlatformType,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    sdk_paths: ?macos.MacOSSDKPaths,
    features: PlatformFeatures,
) void {
    switch (platform_type) {
        .metal => {
            // The macOS backend requires an SDK
            const sdk = sdk_paths orelse @panic("macOS backend requires SDK paths (check the OS branch in build.zig)");

            // Internal path: compile the platform layer .o into this exe (not the published archive).
            const compiled = compilePlatformLayer(b, platform_type, optimize, platform_root, features);
            for (compiled.obj_files) |obj| {
                exe.root_module.addObjectFile(obj);
            }
            exe.root_module.link_libc = true;
            exe.root_module.addIncludePath(platform_root);
            for (compiled.compile_steps) |step| {
                exe.step.dependOn(&step.step);
            }

            consumer.linkMacosFrameworksAndRuntime(b, exe, sdk, platform_type, features);
        },
        .x11 => consumer.linkX11Exe(exe),
        .wayland => consumer.linkWaylandExe(b, exe),
        .gdi, .d3d11 => consumer.linkWindowsExe(exe, platform_type),
        .wasm => {
            // wasm32-wasi. No native .o / system lib.
            // entry/rdynamic/single_threaded are set on build.zig's wasm branch.
        },
    }
}

// ============================================================
// standalone build shared helpers
// (used by examples/*/build.zig and apps/editor/build.zig for standalone builds)
// ============================================================

/// Extra imports for the exe root module (OS/backend-independent. Caller creates once and passes in).
pub const Import = struct {
    name: []const u8,
    module: *std.Build.Module,
};

pub const PlatformCompileResult = struct {
    /// Backend body + (when enable_menu) the shared menu TU. One or more.
    compile_steps: []const *std.Build.Step.Run,
    /// .o files in the same order as compile_steps.
    obj_files: []const std.Build.LazyPath,
};

/// Compile the platform layer to `.o`.
///
/// `platform_root` is a LazyPath to the `platform/` directory.
/// Parent project: `b.path("platform")`; examples:
/// `b.path("../../platform")`.
/// `features`: only the enabled ones pass `-DKNGN_ENABLE_*` into the .o compile (see
/// `addFeatureDefines`). When enable_menu=true, also compile the shared
/// `platform_macos_menu.m` and return it.
pub fn compilePlatformLayer(
    b: *std.Build,
    platform_type: PlatformType,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    features: PlatformFeatures,
) PlatformCompileResult {
    return switch (platform_type) {
        .metal => buildMetal(b, optimize, platform_root, features),
        // Linux / Windows backends are pure Zig and need no .o compile. Only reached from
        // setupExecutableForPlatform's macOS branch, so this arm is unreachable.
        .x11, .wayland, .gdi, .d3d11, .wasm => unreachable,
    };
}

/// Pass `-DKNGN_ENABLE_*` for each enabled feature to a macOS backend compile.
///
/// Only the enabled ones are passed, so the `.swift` sources and the shared menu `.m` gate on
/// `#if KNGN_ENABLE_X` (swiftc) / `#if defined(KNGN_ENABLE_X)` (clang) alike.
///
/// Call it **before** `-import-objc-header` on a swiftc command: that flag takes the next
/// token as the bridging-header path and would otherwise swallow a define as a path.
///
/// Runs at build-graph configuration time only (not per-frame / RT).
fn addFeatureDefines(compile_cmd: *std.Build.Step.Run, features: PlatformFeatures) void {
    // Gamepad: the GameController backend (the framework link is on the executable).
    if (features.enable_gamepad) compile_cmd.addArg("-DKNGN_ENABLE_GAMEPAD");
    // Native menu: the bridge plus the poll-loop consumption. The NSMenu body itself lives in
    // the shared translation unit added by makeCompileResult.
    if (features.enable_menu) compile_cmd.addArg("-DKNGN_ENABLE_MENU");
    // Native save/open panels.
    if (features.enable_dialog) compile_cmd.addArg("-DKNGN_ENABLE_DIALOG");
    // System cursor shapes.
    if (features.enable_cursor) compile_cmd.addArg("-DKNGN_ENABLE_CURSOR");
    // Transparent / borderless / always-on-top / click-through windows and the quit menu.
    if (features.enable_mascot) compile_cmd.addArg("-DKNGN_ENABLE_MASCOT");
    // Fullscreen transition, live state and windowed geometry.
    if (features.enable_fullscreen) compile_cmd.addArg("-DKNGN_ENABLE_FULLSCREEN");
    // NSTextInputClient: character input, IME composition and document access.
    if (features.enable_text_input) compile_cmd.addArg("-DKNGN_ENABLE_TEXT_INPUT");
}

fn objcOptFlag(optimize: std.builtin.OptimizeMode) []const u8 {
    return switch (optimize) {
        .Debug => "-O0",
        .ReleaseSafe => "-O2",
        .ReleaseFast => "-O3",
        .ReleaseSmall => "-Os",
    };
}

/// Compile the shared menu TU only when enable_menu (NSMenu).
fn buildMenuObject(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
) struct { *std.Build.Step.Run, std.Build.LazyPath } {
    const compile_cmd = b.addSystemCommand(&.{
        "clang",
        "-x",
        "objective-c",
    });
    compile_cmd.addPrefixedDirectoryArg("-I", platform_root);
    compile_cmd.addArg("-DKNGN_ENABLE_MENU");
    compile_cmd.addArgs(&.{
        "-fobjc-arc",
        objcOptFlag(optimize),
        "-c",
        "-o",
    });
    const obj_path = compile_cmd.addOutputFileArg("platform_macos_menu.o");
    compile_cmd.addFileArg(platform_root.path(b, "macos/platform_macos_menu.m"));
    return .{ compile_cmd, obj_path };
}

fn makeCompileResult(
    b: *std.Build,
    main_step: *std.Build.Step.Run,
    main_obj: std.Build.LazyPath,
    features: PlatformFeatures,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
) PlatformCompileResult {
    if (!features.enable_menu) {
        const steps = b.allocator.alloc(*std.Build.Step.Run, 1) catch @panic("OOM");
        steps[0] = main_step;
        const objs = b.allocator.alloc(std.Build.LazyPath, 1) catch @panic("OOM");
        objs[0] = main_obj;
        return .{ .compile_steps = steps, .obj_files = objs };
    }
    const menu = buildMenuObject(b, optimize, platform_root);
    const steps = b.allocator.alloc(*std.Build.Step.Run, 2) catch @panic("OOM");
    steps[0] = main_step;
    steps[1] = menu[0];
    const objs = b.allocator.alloc(std.Build.LazyPath, 2) catch @panic("OOM");
    objs[0] = main_obj;
    objs[1] = menu[1];
    return .{ .compile_steps = steps, .obj_files = objs };
}

fn buildMetal(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    features: PlatformFeatures,
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
        // Pack the AppKit and Metal .swift files into one .o (WMO required: -c -o with multiple inputs would emit multiple outputs).
        "-whole-module-optimization",
        "-framework",
        "Cocoa",
        "-framework",
        "Metal",
        "-framework",
        "MetalKit",
    });
    addFeatureDefines(compile_cmd, features);
    compile_cmd.addArg("-import-objc-header");
    compile_cmd.addFileArg(platform_root.path(b, "platform.h"));
    compile_cmd.addArgs(&.{ "-c", "-o" });
    const obj_path = compile_cmd.addOutputFileArg("platform_macos_metal.o");
    // Compile shared .swift and backend-specific .swift in one swiftc invocation (one .o).
    compile_cmd.addFileArg(platform_root.path(b, "macos/platform_macos_appkit.swift"));
    compile_cmd.addFileArg(platform_root.path(b, "macos/platform_macos_metal.swift"));
    return makeCompileResult(b, compile_cmd, obj_path, features, optimize, platform_root);
}
