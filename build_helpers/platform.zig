//! Compile helpers for the platform layer (ObjC / Swift / Metal)
//!
//! Shared by the parent build.zig and examples/*/build.zig.
//! Inputs are LazyPaths so they carry build-graph dependencies.
//!
//! External consumers should import `consumer.zig` (the supported vendor surface).
//! This file re-exports the shared types/backend helpers from there and keeps
//! kngn-internal helpers (`createPlatformModule`, `buildStandalone`, …).

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
    // The macOS backends `@cImport("platform.h")`. Wasm has no `@cImport` at all, and on
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
            // plus generated xdg-shell / xdg-decoration headers.
            mod.linkSystemLibrary("wayland-client", .{});
            mod.linkSystemLibrary("wayland-cursor", .{});
            mod.linkSystemLibrary("xkbcommon", .{});
            mod.addIncludePath(consumer.generateXdgShellClientHeaderDir(b));
            mod.addIncludePath(consumer.generateXdgDecorationClientHeaderDir(b));
        },
        // macOS uses platform.h via the include path already on the module; native .o is exe-side.
        // Windows uses extern fn (no @cImport); system libs are exe-side.
        // wasm has no system libs.
        .objc, .swift, .metal, .gdi, .d3d11, .wasm => {},
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
/// `backend` is passed as `build_options.platform_backend` ("x11"/"wayland"/"objc"…) into the
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
        .objc, .swift, .metal => {
            // macOS backends require an SDK
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

/// Spec for a standalone (single-exe) build.
pub const StandaloneSpec = struct {
    /// Base for install / run names (e.g. "example_01_timed_window").
    base_name: []const u8,
    /// Main source (relative to the build root; `b.path("main.zig")`, …).
    main_source: std.Build.LazyPath,
    /// `core/platform.zig` (standalone: `.{ .cwd_relative = PROJECT_ROOT ++ "/core/platform.zig" }`).
    platform_source: std.Build.LazyPath,
    /// platform module include root (`platform.h`; `.{ .cwd_relative = PROJECT_ROOT ++ "/platform" }`).
    platform_include: std.Build.LazyPath,
    /// platform root for setup (macOS backend .o compile/frameworks; `b.path(PROJECT_ROOT ++ "/platform")`).
    platform_root: std.Build.LazyPath,
    /// libs/gfx/src/keyboard.zig (null if unused). Depends only on platform_types (KeyCode), so
    /// create per backend; no platform facade needed.
    keyboard_source: ?std.Build.LazyPath = null,
    /// src/gamepad.zig (null if unused). Symmetric with keyboard_source; depends only on platform_types
    /// (no platform facade needed).
    gamepad_source: ?std.Build.LazyPath = null,
    /// OS/backend-independent extra imports (sprite / png / gui / core, …).
    extra: []const Import = &.{},
    /// Whether to link L1 audio-output system libraries on the exe (pass the audio module via `extra`).
    /// macOS=AudioToolbox / Linux=alsa / Windows=ole32(WASAPI/COM).
    link_audio: bool = false,
    /// Enable the real gamepad backend (GameController framework; meaningful on macOS only)
    /// (opt-in, symmetric with `link_audio`). When true, platform module
    /// `build_options.enable_gamepad` is true, the macOS backend .o compile also gets
    /// `-DKNGN_ENABLE_GAMEPAD`, and GameController is linked. Default false
    /// (existing standalone exes unchanged). Only examples/22_gamepad opts in.
    link_gamepad: bool = false,
    /// Native menu (NSMenu; shared across macOS objc/swift/metal). When true,
    /// `build_options.enable_menu` + shared `platform_macos_menu.m` (`-DKNGN_ENABLE_MENU`).
    /// Default false. Only pixie opts in.
    link_menu: bool = false,
    /// The remaining macOS backend features (dialog, cursor, mascot, fullscreen, text input).
    /// `link_gamepad` and `link_menu` are folded into this before use, so a caller may set
    /// either form; `platformFeatures` below is the single place the two meet.
    platform_features: PlatformFeatures = .{},
    /// png module (libs/png). **If the caller builds png and passes png-dependent modules (sprite/core, …) in `extra`,
    /// pass that same png here too.** If harness (platform→harness→png) and the extra side each get a png module,
    /// you hit "file exists in modules 'png' and 'png0'"; share one instance.
    /// null: buildStandalone derives one from platform_source.
    png_module: ?*std.Build.Module = null,
    /// Stable libs the caller supplies when wiring the kit umbrella (ADR-007 R4).
    /// Required for apps (pixie, …) standalone builds (app sources `@import("kit")`).
    /// examples do not use kit, so leave null.
    /// **png must be the same instance as spec.png_module** (avoid file-in-two-modules).
    /// platform / control(harness) / types / audio / gamepad are wired inside buildStandalone
    /// (gamepad depends only on platform_types, so the caller need not supply it).
    kit_libs: ?KitLibs = null,
};

/// The one feature set a standalone build uses, for the platform module and for the macOS
/// object file alike. Deriving both from this call is what keeps them in step: a module whose
/// `build_options` say a feature is on, linked against an object compiled without it, fails at
/// link time with an undefined symbol.
fn platformFeatures(spec: StandaloneSpec) PlatformFeatures {
    var features = spec.platform_features;
    if (spec.link_gamepad) features.enable_gamepad = true;
    if (spec.link_menu) features.enable_menu = true;
    return features;
}

/// Stable lib modules needed to wire kit for standalone (the caller-supplied slice of the ADR-007 initial kit set).
pub const KitLibs = struct {
    /// Core type-only module shared by the platform facade and command_types.
    platform_types: *std.Build.Module,
    /// Core type-only module shared by kit.command_types and libs/gui.
    command_types: *std.Build.Module,
    gui: *std.Build.Module,
    png: *std.Build.Module,
    font: *std.Build.Module,
    dsp: *std.Build.Module,
    synth: *std.Build.Module,
    gmath: *std.Build.Module,
    /// kit.gfx. sprite / fixed_timestep / fps_counter / keyboard.
    gfx: *std.Build.Module,
    /// kit.sound. WAV decode + SE/BGM mixer. Depends on dsp + synth.
    sound: *std.Build.Module,
    /// kit.recipe depends on serde. If the caller also builds a serde module for paint etc.
    /// (e.g. apps/editor), pass the **same instance** or the same serde.zig ends up in
    /// two modules ("file exists in modules"). If omitted, buildStandalone
    /// creates one alone (backward compat for kit consumers that do not use serde outside recipe).
    serde: ?*std.Build.Module = null,
    /// kit.appshell. Shares the same module instance as serde.
    appshell: ?*std.Build.Module = null,
    /// paint is still in flux and not in kit. Direct-import it into the example/app root.
    paint: ?*std.Build.Module = null,
    /// gamepad module shared by kit.gamepad / kit.gfx(action_map).
    /// If the caller wires gamepad into gfx, pass the **same instance**.
    /// null: buildStandalone creates its own (existing consumers unchanged).
    gamepad: ?*std.Build.Module = null,
    /// kit.pixelops. The shared pixel primitives are part of the public umbrella, so kit.zig
    /// imports it unconditionally and a standalone build must supply it too. gui, font, gfx and
    /// paint already take a pixelops module, so pass the **same instance** — separate instances
    /// put the same lib.zig in two modules and fail to compile.
    /// null is only for a caller that wires no pixelops at all (buildStandalone then creates
    /// one); leaving it null while wiring one elsewhere ends the build with a diagnostic.
    pixelops: ?*std.Build.Module = null,
};

/// Every module wired under the import name `name` anywhere in the graph reachable from
/// `roots`, deduplicated by pointer.
///
/// The walk is breadth-first with a visited set: `addImport` can make the module graph
/// cyclic, and a caller may wire a shared library deep (into the `sprite` module behind
/// `gfx`, say) rather than into a module it hands over directly.
///
/// Reads `std.Build.Module.import_table`, which is Zig 0.16 plumbing. If a later Zig
/// removes or renames it this file stops compiling, which is the loud failure; if the
/// field survives but stops describing imports, callers simply stop finding candidates
/// and fall back to the behaviour they have without this function.
fn collectWiredImports(
    b: *std.Build,
    roots: []const ?*std.Build.Module,
    name: []const u8,
) std.ArrayList(*std.Build.Module) {
    var visited: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
    defer visited.deinit(b.allocator);
    var queue: std.ArrayList(*std.Build.Module) = .empty;
    defer queue.deinit(b.allocator);
    var found: std.ArrayList(*std.Build.Module) = .empty;

    for (roots) |maybe_root| {
        const root = maybe_root orelse continue;
        if (visited.fetchPut(b.allocator, root, {}) catch @panic("OOM") != null) continue;
        queue.append(b.allocator, root) catch @panic("OOM");
    }

    var i: usize = 0;
    while (i < queue.items.len) : (i += 1) {
        var it = queue.items[i].import_table.iterator();
        while (it.next()) |entry| {
            const dep = entry.value_ptr.*;
            if (std.mem.eql(u8, entry.key_ptr.*, name)) appendUnique(b, &found, dep);
            if (visited.fetchPut(b.allocator, dep, {}) catch @panic("OOM") != null) continue;
            queue.append(b.allocator, dep) catch @panic("OOM");
        }
    }
    return found;
}

fn appendUnique(b: *std.Build, list: *std.ArrayList(*std.Build.Module), module: *std.Build.Module) void {
    for (list.items) |existing| if (existing == module) return;
    list.append(b.allocator, module) catch @panic("OOM");
}

/// The pixelops module kit re-exports, checked against what the caller already wired.
///
/// One source file may belong to only one module, so `libs/pixelops/src/lib.zig` has to
/// reach kit as the very instance the caller gave to gui, font, gfx and paint. Creating a
/// second one here compiles into
/// `error: file exists in modules 'pixelops' and 'pixelops0'`, pointed at a file that has
/// nothing to do with the mistake. Detecting it during build configuration keeps the
/// diagnosis next to the fix.
///
/// Detection goes by the import name `pixelops`, which is not a free choice: the sources
/// behind it write `@import("pixelops")`, so every caller has to wire it under that name.
/// A module wired under some other name is therefore not detected, and a *different* file
/// wired under this name is reported as a conflict.
fn resolvePixelops(
    b: *std.Build,
    kl: KitLibs,
    extra: []const Import,
    kit_root: []const u8,
) *std.Build.Module {
    // Roots are what the caller handed over, never a module created in this file: walking
    // one of those would find the very module this function is about to return.
    var roots: std.ArrayList(?*std.Build.Module) = .empty;
    defer roots.deinit(b.allocator);
    roots.appendSlice(b.allocator, &.{
        kl.platform_types, kl.command_types, kl.gui,   kl.png,     kl.font,
        kl.dsp,            kl.synth,         kl.gmath, kl.gfx,     kl.sound,
        kl.serde,          kl.appshell,      kl.paint, kl.gamepad,
    }) catch @panic("OOM");
    for (extra) |imp| roots.append(b.allocator, imp.module) catch @panic("OOM");

    var found = collectWiredImports(b, roots.items, "pixelops");
    defer found.deinit(b.allocator);
    // An `extra` entry names the module it hands over, so it can be the pixelops module
    // itself rather than something importing it.
    for (extra) |imp| {
        if (std.mem.eql(u8, imp.name, "pixelops")) appendUnique(b, &found, imp.module);
    }

    if (kl.pixelops) |explicit| {
        for (found.items) |candidate| {
            if (candidate == explicit) continue;
            std.log.err(
                "kit_libs.pixelops is a different module than the one wired as \"pixelops\" " ++
                    "into the modules passed to buildStandalone. libs/pixelops/src/lib.zig can " ++
                    "belong to only one module, so pass the same instance everywhere.",
                .{},
            );
            std.process.exit(1);
        }
        return explicit;
    }

    if (found.items.len != 0) {
        std.log.err(
            "kit_libs.pixelops is unset while a \"pixelops\" module is already wired into the " ++
                "modules passed to buildStandalone. kit re-exports pixelops, so leaving it unset " ++
                "builds a second module for libs/pixelops/src/lib.zig and the compile fails with " ++
                "\"file exists in modules 'pixelops' and 'pixelops0'\". Pass the module already " ++
                "built here: .kit_libs = .{{ …, .pixelops = pixelops }}",
            .{},
        );
        std.process.exit(1);
    }

    return b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.fmt("{s}/libs/pixelops/src/lib.zig", .{kit_root}) },
    });
}

/// Create one exe per implemented backend for the target OS, plus install / `run-<backend>` /
/// `run` (default). Resolve the SDK only for macOS backends (Linux needs no xcrun).
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
        "Platform backend (macOS: objc/swift/metal, Linux: x11/wayland, Windows: gdi/d3d11)",
    ) orelse defaultBackend(target_os);
    assertBackendForOs(platform_option, target_os);

    // Audio-required standalones (example_15, …) skip exe creation on OSes without audio
    // (same as top-level build.zig's audio_supported gate. Without it, unsupported OSes hit the audio facade
    // compileError). -Dtarget/-Dplatform were already accepted above, so early-return with no steps.
    // macOS/Linux/Windows all support audio today; this skip is for future unsupported OSes.
    if (spec.link_audio and !audioSupported(target_os)) {
        std.log.info("standalone '{s}': skipping; OS ({s}) has no audio backend", .{ spec.base_name, @tagName(target_os) });
        return;
    }

    const sdk_paths: ?macos.MacOSSDKPaths = if (target_os == .macos)
        macos.resolveMacOSSDKPaths(b, null, null)
    else
        null;

    const default_be = defaultBackend(target_os);
    var default_exe: ?*std.Build.Step.Compile = null;

    // The platform module depends on the png codec (libs/png) via harness (core/platform.zig → core/control/harness.zig).
    // From the standalone platform_source (.cwd_relative <ROOT>/core/platform.zig),
    // derive the png lib (<ROOT>/libs/png/src/lib.zig) and share one png module across backends.
    const png_source: std.Build.LazyPath = switch (spec.platform_source) {
        .cwd_relative => |s| blk: {
            const root = std.fs.path.dirname(std.fs.path.dirname(s) orelse s) orelse ".";
            break :blk .{ .cwd_relative = b.fmt("{s}/libs/png/src/lib.zig", .{root}) };
        },
        // standalone builds always pass a .cwd_relative platform_source.
        // Anything else cannot derive the png lib path and would break `@import("png")`, so fail explicitly.
        else => @panic("buildStandalone: platform_source must be .cwd_relative (needed to derive the png lib path)"),
    };
    // Reuse a caller-built png for extra when present (avoid a second png module).
    const png_mod = spec.png_module orelse b.createModule(.{ .root_source_file = png_source });

    // Also derive shared platform_types and harness modules from platform_source's dirname (<ROOT>/core)
    // and share one of each across backends. platform.zig (facade) `@import("platform_types")` /
    // `@import("harness")`; harness `@import("png")` / `@import("platform_types")`.
    // harness lives under core/control/ (ADR-007 R3: promotion into the control+obs plane).
    const core_dir: []const u8 = switch (spec.platform_source) {
        .cwd_relative => |s| std.fs.path.dirname(s) orelse ".",
        else => @panic("buildStandalone: platform_source must be .cwd_relative (needed to derive types/harness paths)"),
    };
    const types_mod: *std.Build.Module = if (spec.kit_libs) |kl|
        kl.platform_types
    else
        b.createModule(.{ .root_source_file = .{ .cwd_relative = b.fmt("{s}/platform_types.zig", .{core_dir}) } });
    const command_types_mod: *std.Build.Module = if (spec.kit_libs) |kl|
        kl.command_types
    else blk: {
        const m = b.createModule(.{ .root_source_file = .{ .cwd_relative = b.fmt("{s}/command_types.zig", .{core_dir}) } });
        m.addImport("platform_types", types_mod);
        break :blk m;
    };
    const harness_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.fmt("{s}/control/harness.zig", .{core_dir}) },
        .link_libc = true,
    });
    harness_mod.addImport("png", png_mod);
    harness_mod.addImport("platform_types", types_mod);
    harness_mod.addImport("command_types", command_types_mod);
    // harness `@import("capture_synthetic")` for the synthetic capture source.
    // capture_synthetic depends only on capture_types (not wired to camera/audio facades).
    // Without this wire, every standalone build that uses harness breaks.
    const capture_types_mod = b.createModule(.{ .root_source_file = .{ .cwd_relative = b.fmt("{s}/capture_types.zig", .{core_dir}) } });
    const capture_synthetic_mod = b.createModule(.{ .root_source_file = .{ .cwd_relative = b.fmt("{s}/capture_synthetic.zig", .{core_dir}) } });
    capture_synthetic_mod.addImport("capture_types", capture_types_mod);
    harness_mod.addImport("capture_synthetic", capture_synthetic_mod);

    // harness `@import("dsp")` for digest-audio spectrum analysis (band/centroid/onset)
    // (same wiring as top-level build.zig `linkCoreException(harness, dsp, ...)`). Without it,
    // every harness-using standalone (e.g. soundalert) breaks (same reason as capture_synthetic).
    // Reuse kit_libs.dsp when the caller supplies it (avoid two modules for the same file);
    // otherwise create a standalone dsp module here.
    const harness_dsp_mod: *std.Build.Module = if (spec.kit_libs) |kl|
        kl.dsp
    else
        b.createModule(.{ .root_source_file = .{ .cwd_relative = b.fmt("{s}/../src/dsp/dsp.zig", .{core_dir}) } });
    harness_mod.addImport("dsp", harness_dsp_mod);

    // When link_audio is set, **buildStandalone creates** the audio facade module and wires harness.
    // audio.zig `@import("harness")`, so sharing a **single harness_mod** with the platform module is required;
    // otherwise file-in-two-modules and a silent audio probe. If the caller also builds an audio module for extra,
    // harness duplicates, so audio is concentrated under link_audio (example_15, …).
    const audio_mod: ?*std.Build.Module = if (spec.link_audio or spec.kit_libs != null) blk: {
        const am = b.createModule(.{ .root_source_file = .{ .cwd_relative = b.fmt("{s}/audio.zig", .{core_dir}) } });
        am.addImport("harness", harness_mod);
        // audio.zig's capture extension (mic input) `@import("capture_types")`
        // (named module; same wiring as top-level build.zig `link(audio, capture_types)`).
        // Without it, standalones that actually call `audio.openCapture`/`requestCapturePermission`
        // (e.g. soundalert) fail to compile.
        am.addImport("capture_types", capture_types_mod);
        // macOS audio_macos.zig (capture permission check) `@import("objc_runtime")`
        // (same wiring as top-level build.zig `link(audio, objc_runtime)`; also link_libc=true because
        // it uses std.c.nanosleep). Without it, macOS standalones that touch capture APIs hit
        // `no module named 'objc_runtime'`. Harmless on non-macOS native (unreflected), but
        // on wasm (audio_web path) skip the wire just like top-level `if (!is_wasm) link(audio, objc_runtime)`
        // (intent made explicit; wasi/freestanding is buildStandalone's wasm path).
        if (target_os != .wasi and target_os != .freestanding) {
            const objc_runtime_mod = b.createModule(.{
                .root_source_file = .{ .cwd_relative = b.fmt("{s}/objc_runtime.zig", .{core_dir}) },
                .link_libc = true,
            });
            am.addImport("objc_runtime", objc_runtime_mod);
        }
        break :blk am;
    } else null;

    const features = platformFeatures(spec);

    for (implementedBackends(target_os)) |be| {
        const platform_mod = createPlatformModule(
            b,
            target,
            spec.platform_source,
            spec.platform_include,
            be,
            types_mod,
            command_types_mod,
            harness_mod,
            features,
        );

        const root = b.createModule(.{
            .root_source_file = spec.main_source,
            .target = target,
            .optimize = optimize,
        });
        root.addImport("platform", platform_mod);
        if (spec.link_audio) root.addImport("audio", audio_mod.?);

        // kit umbrella (ADR-007 R4/R5). apps standalones have the root `@import("kit")`.
        // Keep 1:1 with kit/kit.zig's pub imports (platform is per-backend, so kit is too).
        if (spec.kit_libs) |kl| {
            const kit_root: []const u8 = std.fs.path.dirname(core_dir) orelse ".";
            const kit_mod = b.createModule(.{
                .root_source_file = .{ .cwd_relative = b.fmt("{s}/kit/kit.zig", .{kit_root}) },
            });
            kit_mod.addImport("platform", platform_mod);
            kit_mod.addImport("harness", harness_mod);
            kit_mod.addImport("platform_types", types_mod);
            kit_mod.addImport("command_types", command_types_mod);
            kit_mod.addImport("audio", audio_mod.?);
            kit_mod.addImport("gui", kl.gui);
            kit_mod.addImport("png", kl.png);
            kit_mod.addImport("font", kl.font);
            kit_mod.addImport("dsp", kl.dsp);
            kit_mod.addImport("synth", kl.synth);
            kit_mod.addImport("gmath", kl.gmath);
            kit_mod.addImport("gfx", kl.gfx);
            kit_mod.addImport("sound", kl.sound);
            // gamepad: kit.zig imports unconditionally.
            // Reuse kl.gamepad when supplied (same instance as gfx/action_map).
            // null: create locally as before (existing consumers such as apps/editor unchanged).
            const kit_gamepad_mod: *std.Build.Module = if (kl.gamepad) |gp|
                gp
            else blk: {
                const m = b.createModule(.{
                    .root_source_file = .{ .cwd_relative = b.fmt("{s}/src/gamepad.zig", .{kit_root}) },
                });
                m.addImport("platform_types", types_mod);
                break :blk m;
            };
            kit_mod.addImport("gamepad", kit_gamepad_mod);
            // pixelops: kit.zig re-exports it, so the module has to be present even when the
            // application never names it. The caller's gui/font/gfx/paint already import the same
            // lib.zig, so a second module for it would put one file in two modules;
            // resolvePixelops reports that during build configuration rather than letting the
            // compiler emit "file exists in modules 'pixelops' and 'pixelops0'".
            const kit_pixelops_mod: *std.Build.Module =
                resolvePixelops(b, kl, spec.extra, kit_root);
            kit_mod.addImport("pixelops", kit_pixelops_mod);
            // recipe: kit.zig imports unconditionally (same as top-level build.zig
            // `link(kit, common.recipe)`). libs/recipe is a headless lib that depends only on serde.
            // The serde module **must share one instance** with the caller (when paint etc. also use serde);
            // separate modules put the same serde.zig in two modules and fail to compile. Use
            // kl.serde when supplied; otherwise create locally like gamepad.
            const kit_serde_mod: *std.Build.Module = if (kl.serde) |s|
                s
            else
                b.createModule(.{ .root_source_file = .{ .cwd_relative = b.fmt("{s}/libs/serde/src/serde.zig", .{kit_root}) } });
            const kit_recipe_mod = b.createModule(.{
                .root_source_file = .{ .cwd_relative = b.fmt("{s}/libs/recipe/src/recipe.zig", .{kit_root}) },
            });
            kit_recipe_mod.addImport("serde", kit_serde_mod);
            kit_mod.addImport("recipe", kit_recipe_mod);
            const kit_appshell_mod: *std.Build.Module = if (kl.appshell) |a| a else blk: {
                const m = b.createModule(.{ .root_source_file = .{ .cwd_relative = b.fmt("{s}/libs/appshell/src/appshell.zig", .{kit_root}) } });
                m.addImport("serde", kit_serde_mod);
                break :blk m;
            };
            kit_mod.addImport("appshell", kit_appshell_mod);
            // app_runtime: kit.zig imports unconditionally (same as top-level build.zig
            // `link(kit, app_runtime)`). Frame-driven runtime depends on platform, so
            // create per backend and wire platform_mod (not part of KitLibs).
            const kit_app_runtime_mod = b.createModule(.{
                .root_source_file = .{ .cwd_relative = b.fmt("{s}/app_runtime.zig", .{core_dir}) },
            });
            kit_app_runtime_mod.addImport("platform", platform_mod);
            // app_runtime reads `build_options.has_frame_cap` / `frame_cap_hz` (the root build's
            // `-Dframe-cap`). An external consumer has no such option, so supply the "unset" values:
            // the target period then comes from `App.frame_period_s` as before. Without this import,
            // instantiating `Runtime(App)` outside this repository fails to compile.
            const kit_app_runtime_opts = b.addOptions();
            kit_app_runtime_opts.addOption(bool, "has_frame_cap", false);
            kit_app_runtime_opts.addOption(u32, "frame_cap_hz", @as(u32, 0));
            kit_app_runtime_mod.addImport("build_options", kit_app_runtime_opts.createModule());
            kit_mod.addImport("app_runtime", kit_app_runtime_mod);
            // midi: kit.zig imports unconditionally. core/midi.zig depends on platform_types and
            // harness (synthetic FIFO); harness is per-backend, so midi is also created per backend
            // here (same reason as gamepad/app_runtime: not in KitLibs).
            const kit_midi_mod = b.createModule(.{
                .root_source_file = .{ .cwd_relative = b.fmt("{s}/midi.zig", .{core_dir}) },
            });
            kit_midi_mod.addImport("platform_types", types_mod);
            kit_midi_mod.addImport("harness", harness_mod);
            kit_mod.addImport("midi", kit_midi_mod);
            root.addImport("kit", kit_mod);
        }
        if (spec.kit_libs) |kl| if (kl.paint) |paint| root.addImport("paint", paint);
        if (spec.keyboard_source) |ks| {
            const kb = b.createModule(.{ .root_source_file = ks });
            kb.addImport("platform_types", types_mod);
            root.addImport("keyboard", kb);
        }
        if (spec.gamepad_source) |gs| {
            const gp = b.createModule(.{ .root_source_file = gs });
            gp.addImport("platform_types", types_mod);
            root.addImport("gamepad", gp);
        }
        for (spec.extra) |imp| root.addImport(imp.name, imp.module);

        const name = if (be == default_be)
            spec.base_name
        else
            b.fmt("{s}_{s}", .{ spec.base_name, backendName(be) });

        const exe = b.addExecutable(.{ .name = name, .root_module = root });

        // build_options: platform name for the startup banner (attached to every backend, as in top build.zig)
        const opts = b.addOptions();
        opts.addOption([]const u8, "platform_name", backendName(be));
        exe.root_module.addOptions("build_options", opts);

        setupExecutableForPlatform(b, exe, be, optimize, spec.platform_root, sdk_paths, features);
        // setupExecutableForPlatform runs in the same loop and sets the -F/-L search
        // paths the shared helper expects to find already in place.
        if (spec.link_audio) consumer.linkAudioBackend(exe.root_module, target_os);

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
        .objc => buildObjC(b, optimize, platform_root, features),
        .swift => buildSwift(b, optimize, platform_root, features),
        .metal => buildMetal(b, optimize, platform_root, features),
        // Linux / Windows backends are pure Zig and need no .o compile. Only reached from
        // setupExecutableForPlatform's macOS branch, so this arm is unreachable.
        .x11, .wayland, .gdi, .d3d11, .wasm => unreachable,
    };
}

/// Pass `-DKNGN_ENABLE_*` for each enabled feature to a macOS backend compile.
///
/// Only the enabled ones are passed, so `.m` and `.swift` gate on
/// `#if defined(KNGN_ENABLE_X)` (clang) / `#if KNGN_ENABLE_X` (swiftc) alike.
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
    // Fullscreen transition, live state and restore geometry.
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

fn buildObjC(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    platform_root: std.Build.LazyPath,
    features: PlatformFeatures,
) PlatformCompileResult {
    const compile_cmd = b.addSystemCommand(&.{
        "clang",
        "-x",
        "objective-c",
    });
    compile_cmd.addPrefixedDirectoryArg("-I", platform_root);
    addFeatureDefines(compile_cmd, features);
    compile_cmd.addArgs(&.{
        "-fobjc-arc",
        objcOptFlag(optimize),
        "-c",
        "-o",
    });
    const obj_path = compile_cmd.addOutputFileArg("platform_macos_objc.o");
    compile_cmd.addFileArg(platform_root.path(b, "macos/platform_macos.m"));
    return makeCompileResult(b, compile_cmd, obj_path, features, optimize, platform_root);
}

fn buildSwift(
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
        // Pack shared+backend's two .swift files into one .o (WMO required: -c -o with multiple inputs would emit multiple outputs).
        "-whole-module-optimization",
        "-framework",
        "Cocoa",
        "-framework",
        "QuartzCore",
    });
    addFeatureDefines(compile_cmd, features);
    compile_cmd.addArg("-import-objc-header");
    compile_cmd.addFileArg(platform_root.path(b, "platform.h"));
    compile_cmd.addArgs(&.{ "-c", "-o" });
    const obj_path = compile_cmd.addOutputFileArg("platform_macos_swift.o");
    // Compile shared .swift and backend-specific .swift in one swiftc invocation (one .o).
    compile_cmd.addFileArg(platform_root.path(b, "macos-shared/platform_macos_shared.swift"));
    compile_cmd.addFileArg(platform_root.path(b, "macos-swift/platform_macos_swift.swift"));
    return makeCompileResult(b, compile_cmd, obj_path, features, optimize, platform_root);
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
        // Pack shared+backend's two .swift files into one .o (WMO required: -c -o with multiple inputs would emit multiple outputs).
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
    compile_cmd.addFileArg(platform_root.path(b, "macos-shared/platform_macos_shared.swift"));
    compile_cmd.addFileArg(platform_root.path(b, "macos-metal/platform_macos_metal.swift"));
    return makeCompileResult(b, compile_cmd, obj_path, features, optimize, platform_root);
}
