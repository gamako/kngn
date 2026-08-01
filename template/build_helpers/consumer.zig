// External projects vendor this helper from kngn/build_helpers/.
// The kngn/build_helpers/ file is authoritative; keep all copies byte-identical.
//! External-consumer build helpers for kngn.
//!
//! Vendor this file (plus `macos.zig` / `swift.zig` when targeting macOS) into an
//! external project. It is the supported surface for `dep.module("kit")` apps:
//! backend resolution and executable-side linking only.
//!
//! Internal-only helpers (`buildStandalone`, `createPlatformModule`,
//! `compilePlatformLayer`, …) live in `platform.zig`, which re-exports this module
//! so there is a single implementation of shared types and Wayland glue.
//!
//! All functions run at build-graph configuration time only (not per-frame / RT).

const std = @import("std");
const macos = @import("macos.zig");
const swift = @import("swift.zig");

pub const PlatformType = enum {
    // macOS backends (via C ABI platform.h. Zig facade/backend is shared; only the .o link differs)
    objc,
    swift,
    metal,
    // Linux backends (pure Zig. x11 and wayland)
    x11,
    wayland,
    // Windows backends (pure Zig. gdi=GDI software blit/best-effort; d3d11=D3D11-DXGI/tier-1)
    gdi,
    d3d11,
    // wasm32-wasi (JS glue + canvas. stdlib is wasi; draw/input via env import)
    wasm,
};

/// Per-executable capabilities, bundled into a struct so more can be added without growing
/// the parameter list. Each one is opt-in, and each one decides what an executable links
/// (ADR-013).
///
/// Every flag but `enable_audio` and `enable_midi` reaches further than linking: it is also
/// baked into the platform module as `build_options` and into the macOS backend compile as
/// `-DKNGN_ENABLE_*`, so the disabled feature's code is absent from the object file and the
/// macOS backend refuses its API at compile time. `enable_audio` and `enable_midi` do
/// neither — they only add the executable-side system libraries that `kit.audio` and
/// `kit.midi` resolve against, and `setupExecutableForPlatform` ignores them (executables
/// inside this repository call `linkAudioBackend` / `linkMidiBackend` directly).
///
/// **These flags only reach an executable that compiles the macOS backend itself.** An
/// external consumer links a prebuilt native archive and receives the published platform
/// module, and both are built here with every one of these features enabled, so passing a
/// `false` from outside this repository turns nothing off. Only `enable_audio` and
/// `enable_midi` are meaningful to an external consumer.
pub const PlatformFeatures = struct {
    enable_gamepad: bool = false,
    enable_menu: bool = false,
    /// Native save/open file panels (`saveFileDialog` / `openFileDialog`). While off, both
    /// report `error.DialogUnavailable`.
    enable_dialog: bool = false,
    /// System cursor shapes (`setCursor`). While off, the call is a no-op and the window
    /// keeps the default arrow.
    enable_cursor: bool = false,
    /// Transparent, borderless, always-on-top, click-through windows and the pop-up quit
    /// menu — what a desktop mascot needs. While off, `beginDrag`, `setAlwaysOnTop`,
    /// `setClickThrough`, `showQuitMenu` and `setDockVisible` are no-ops, and asking for a
    /// transparent or borderless window fails with `error.Unsupported`.
    enable_mascot: bool = false,
    /// Fullscreen: the transition, the live state and the geometry to persist. While off,
    /// creating a fullscreen window fails with `error.Unsupported`, `setFullscreen` is a
    /// no-op, `isFullscreen` is always false, and `restoreGeometry` reports a zero geometry
    /// (the window's pre-fullscreen geometry is not tracked, so there is nothing to restore).
    enable_fullscreen: bool = false,
    /// The macOS native text input machinery: `NSTextInputClient`, IME composition, and
    /// document access for reconversion.
    ///
    /// **Defaults to true, unlike every other flag here.** On macOS `keyDown` is handed to
    /// `interpretKeyEvents:`, which makes `insertText:` the only source of `char_input`, so
    /// turning this off removes character input as well as the IME. Almost every executable
    /// consumes `char_input`, so this is opt-*out*: set it false only for an executable that
    /// handles no characters at all. See `docs/adr/013_per-executable-capability-linking.md`.
    ///
    /// It gates the OS path only. The harness synthesises `char_input` and
    /// `composition_changed` without the OS, and keeps doing so either way.
    enable_text_input: bool = true,
    /// Link what `kit.audio` needs. Set this when the executable uses audio output or
    /// microphone capture.
    enable_audio: bool = false,
    /// Link what `kit.midi` needs. Set this when the executable uses MIDI input.
    enable_midi: bool = false,

    /// The subset that decides the shape of the platform module and of the macOS object
    /// file. Two feature sets differing only in `enable_audio` / `enable_midi` share one
    /// module, because those two are executable-side link decisions and reach neither.
    pub fn moduleKey(self: PlatformFeatures) PlatformFeatures {
        var key = self;
        key.enable_audio = false;
        key.enable_midi = false;
        return key;
    }

    /// Every feature enabled — what the published platform module and the published native
    /// archive are built with, so that an external consumer keeps the whole surface.
    /// `enable_gamepad` stays a parameter because it also decides a framework link the
    /// consumer's executable has to make, and it reaches the consumer as `-Denable_gamepad`.
    pub fn published(enable_gamepad: bool) PlatformFeatures {
        return .{
            .enable_gamepad = enable_gamepad,
            // The menu needs its own translation unit archived alongside, which the published
            // archive does not carry, so it stays off outside this repository.
            .enable_menu = false,
            .enable_dialog = true,
            .enable_cursor = true,
            .enable_mascot = true,
            .enable_fullscreen = true,
            .enable_text_input = true,
        };
    }
};

/// Link the system libraries `core/audio.zig` resolves against, for one module.
///
/// The audio layer reaches the OS through `extern fn` rather than `@cImport`, so nothing is
/// linked when the module is built; it has to happen where the executable is assembled.
///
/// Takes a module rather than an executable so a bare `addTest` can use it too; callers
/// holding an executable pass `exe.root_module`.
///
/// **Does not set search paths.** On macOS the `-F` / `-L` pair must already be on the
/// module — `setupConsumerExe` and `setupExecutableForPlatform` both arrange that, and a
/// bare test has to do it itself.
///
/// The macOS list also carries the capture frameworks (microphone AUHAL input, camera
/// AVFoundation). `kit` does not re-export the capture camera, so an external consumer
/// does not need them, but linking them is harmless and keeps one list instead of two.
///
/// An OS with no audio backend links nothing: `core/audio.zig` reports it at compile time,
/// and that message names the API, which a panic here would only pre-empt. (Wasm is not
/// such an OS — it has a backend that needs no system library.)
pub fn linkAudioBackend(mod: *std.Build.Module, target_os: std.Target.Os.Tag) void {
    switch (target_os) {
        .macos => {
            mod.linkFramework("AudioToolbox", .{});
            mod.linkFramework("CoreAudio", .{});
            mod.linkFramework("AVFoundation", .{});
            mod.linkFramework("CoreMedia", .{});
            mod.linkFramework("CoreVideo", .{});
            mod.linkFramework("Foundation", .{});
            mod.linkSystemLibrary("objc", .{});
        },
        // "alsa" is the pkg-config name (from alsa-lib-dev), and it resolves both `-lasound`
        // and the library path. Naming the library "asound" directly finds no .pc file, and
        // zig then searches only the `-L` paths that are already present (X11 and such),
        // which do not hold libasound.so.
        .linux => mod.linkSystemLibrary("alsa", .{}),
        // WASAPI goes through COM: CoCreateInstance / CoInitializeEx / CoTaskMemFree live in
        // ole32. IAudioClient and friends arrive through COM, so nothing else is linked
        // directly (the Event API is in kernel32, which is automatic).
        //
        // `core/audio_windows.zig` declares those four as `extern "ole32"`, which carries the
        // library on the declaration, so today an executable links ole32 whether or not this
        // line runs. It stays because the list describes what the audio layer needs, not what
        // the current declaration style happens to make implicit: a symbol declared plain
        // `extern` — as the Linux backend declares its ALSA entry points — would need it. The
        // consequence for the consumer gate is that Windows cannot reproduce the missing
        // library failure that Linux and macOS can.
        .windows => mod.linkSystemLibrary("ole32", .{}),
        else => {},
    }
}

/// Link the system libraries `core/midi.zig` resolves against, for one module.
/// The same contract as `linkAudioBackend`, and for the same reason: `extern fn` rather than
/// `@cImport`, a module rather than an executable, and search paths are the caller's job.
///
/// macOS only. Every other OS uses the null backend, which needs no system library.
pub fn linkMidiBackend(mod: *std.Build.Module, target_os: std.Target.Os.Tag) void {
    switch (target_os) {
        .macos => {
            mod.linkFramework("CoreMIDI", .{});
            mod.linkFramework("CoreFoundation", .{});
        },
        else => {},
    }
}

/// Default backend for the OS (used when `-Dplatform` is omitted).
pub fn defaultBackend(os: std.Target.Os.Tag) PlatformType {
    return switch (os) {
        .macos => .metal, // Metal meets the first-class frame pacing contract of ADR-005 (vsync gating); objc and swift are best-effort
        .linux => .x11,
        .windows => .gdi, // GDI is the default for now (d3d11 is opt-in)
        .wasi => .wasm, // wasm32-wasi
        .freestanding => .wasm, // Legacy freestanding alias; the canonical target is wasi
        else => .objc, // Unreachable in practice: build.zig's OS check rejects it first
    };
}

/// Backends **implemented** for the OS.
/// (targets of `install-all` and full-backend builds. Linux always builds both x11 and wayland for
/// regression coverage; default is x11. wayland is also implemented)
pub fn implementedBackends(os: std.Target.Os.Tag) []const PlatformType {
    return switch (os) {
        .macos => &.{ .objc, .swift, .metal },
        .linux => &.{ .x11, .wayland },
        .windows => &.{ .gdi, .d3d11 },
        .wasi => &.{.wasm}, // wasm32-wasi-only branch is the main path
        .freestanding => &.{.wasm},
        else => &.{},
    };
}

/// Validate that the `-Dplatform` backend is valid for the target OS.
/// Mismatches (e.g. a macOS backend on Linux) become a build error.
/// (exit with a clear one-line message instead of a panic stack trace)
pub fn assertBackendForOs(backend: PlatformType, os: std.Target.Os.Tag) void {
    for (implementedBackends(os)) |b| {
        if (b == backend) return;
    }
    const valid = switch (os) {
        .macos => "objc / swift / metal",
        .linux => "x11 / wayland",
        .windows => "gdi / d3d11",
        .wasi, .freestanding => "wasm",
        else => "(none)",
    };
    std.log.err(
        "-Dplatform={s} is not valid for OS={s}. Valid values: {s}",
        .{ @tagName(backend), @tagName(os), valid },
    );
    std.process.exit(1);
}

/// Backend suffix for exe / run-step names.
pub fn backendName(backend: PlatformType) []const u8 {
    return @tagName(backend);
}

/// Resolve `-Dplatform` for an external consumer.
/// When omitted, uses the OS default; rejects OS/backend mismatches.
pub fn resolveBackend(b: *std.Build, target: std.Build.ResolvedTarget) PlatformType {
    const target_os = target.result.os.tag;
    const backend = b.option(
        PlatformType,
        "platform",
        "Platform backend (macOS: objc/swift/metal, Linux: x11/wayland, Windows: gdi/d3d11)",
    ) orelse defaultBackend(target_os);
    assertBackendForOs(backend, target_os);
    return backend;
}

// ============================================================================
// Wayland protocol glue (shared with kngn internal platform.zig)
//
// Generate client-header (.h) and private-code (.c) at build time via wayland-scanner.
// Pull protocol XML from `pkg-config --variable=pkgdatadir wayland-protocols`.
// ============================================================================

/// Generate `xdg-shell-client-protocol.h` and return its parent directory (include path).
pub fn generateXdgShellClientHeaderDir(b: *std.Build) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        "sh",                                                                                                                            "-c",
        // $0=sh, $1=output path (addOutputFileArg). Locate xdg-shell.xml via pkg-config.
        "wayland-scanner client-header \"$(pkg-config --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml\" \"$1\"", "sh",
    });
    return cmd.addOutputFileArg("xdg-shell-client-protocol.h").dirname();
}

/// Generate `xdg-shell-protocol.c` (protocol marshalling body).
pub fn generateXdgShellPrivateCode(b: *std.Build) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        "sh",                                                                                                                           "-c",
        "wayland-scanner private-code \"$(pkg-config --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml\" \"$1\"", "sh",
    });
    return cmd.addOutputFileArg("xdg-shell-protocol.c");
}

/// Generate `xdg-decoration-unstable-v1-client-protocol.h` and return its parent directory.
pub fn generateXdgDecorationClientHeaderDir(b: *std.Build) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        "sh",                                                                                                                                                    "-c",
        "wayland-scanner client-header \"$(pkg-config --variable=pkgdatadir wayland-protocols)/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml\" \"$1\"", "sh",
    });
    return cmd.addOutputFileArg("xdg-decoration-unstable-v1-client-protocol.h").dirname();
}

/// Generate `xdg-decoration-unstable-v1-protocol.c` (marshalling body).
pub fn generateXdgDecorationPrivateCode(b: *std.Build) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        "sh",                                                                                                                                                   "-c",
        "wayland-scanner private-code \"$(pkg-config --variable=pkgdatadir wayland-protocols)/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml\" \"$1\"", "sh",
    });
    return cmd.addOutputFileArg("xdg-decoration-unstable-v1-protocol.c");
}

// ============================================================================
// Shared executable-side link helpers
//
// Used by both external consumers (`setupConsumerExe`) and kngn-internal builds
// (`setupExecutableForPlatform` in platform.zig). Keep a single implementation so
// the two entry points cannot drift.
// ============================================================================

/// X11/Xlib: system libs propagate from the platform module; enable libc only.
pub fn linkX11Exe(exe: *std.Build.Step.Compile) void {
    exe.root_module.link_libc = true;
}

/// Wayland: private protocol glue on the exe, plus libs for header/symbol resolve.
pub fn linkWaylandExe(b: *std.Build, exe: *std.Build.Step.Compile) void {
    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("wayland-client", .{});
    exe.root_module.linkSystemLibrary("wayland-cursor", .{});
    exe.root_module.addCSourceFile(.{ .file = generateXdgShellPrivateCode(b) });
    exe.root_module.addCSourceFile(.{ .file = generateXdgDecorationPrivateCode(b) });
}

/// Windows: system libs + GUI subsystem. `backend` must be `.gdi` or `.d3d11`.
pub fn linkWindowsExe(exe: *std.Build.Step.Compile, backend: PlatformType) void {
    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("user32", .{});
    exe.root_module.linkSystemLibrary("comdlg32", .{});
    exe.root_module.linkSystemLibrary("gdi32", .{});
    switch (backend) {
        .gdi => {},
        .d3d11 => exe.root_module.linkSystemLibrary("d3d11", .{}),
        else => unreachable,
    }
    // GUI apps: default console subsystem would open a console on launch.
    // Callers that need console output (e.g. benches) override to .Console.
    exe.subsystem = .Windows;
}

/// macOS frameworks + Swift/Metal runtime (native body is attached by the caller).
///
/// Callers differ only in how they supply the native layer:
/// - external: `linkLibrary(dep.artifact("platform_native_*"))`
/// - internal: `compilePlatformLayer` + `addObjectFile`
pub fn linkMacosFrameworksAndRuntime(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    sdk: macos.MacOSSDKPaths,
    backend: PlatformType,
    features: PlatformFeatures,
) void {
    macos.linkMacOSFrameworks(b, exe, sdk, features.enable_gamepad);
    switch (backend) {
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
}

/// Apply executable-side platform setup for an external consumer of `dep.module("kit")`.
///
/// The public platform module already carries `@cImport`-required system libs (X11/Wayland).
/// This helper applies what only the executable can carry:
/// - macOS: `platform_native_*` archive + frameworks + Swift/Metal runtime
/// - Wayland: generated private C sources (and lib links for reliable resolve)
/// - Windows: system libraries + `subsystem = .Windows`
/// - X11: libc only (system libs propagate from the module)
///
/// Pass the same `backend` used for `b.dependency("kngn", .{ .platform = backend })`.
/// `sdk_paths` is required on macOS backends and ignored elsewhere.
pub fn setupConsumerExe(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    dep: *std.Build.Dependency,
    backend: PlatformType,
    sdk_paths: ?macos.MacOSSDKPaths,
    features: PlatformFeatures,
) void {
    switch (backend) {
        .objc, .swift, .metal => {
            const sdk = sdk_paths orelse @panic("macOS backend requires SDK paths (pass resolveMacOSSDKPaths result)");
            const native_lib_name = switch (backend) {
                .objc => "platform_native_objc",
                .swift => "platform_native_swift",
                .metal => "platform_native_metal",
                else => unreachable,
            };
            // External path: prebuilt native archive from the kngn package.
            exe.root_module.linkLibrary(dep.artifact(native_lib_name));
            linkMacosFrameworksAndRuntime(b, exe, sdk, backend, features);
        },
        .x11 => linkX11Exe(exe),
        .wayland => linkWaylandExe(b, exe),
        .gdi, .d3d11 => linkWindowsExe(exe, backend),
        .wasm => {},
    }
    // L1 capabilities beyond the platform layer. `kit` re-exports audio and midi, and both
    // resolve against system libraries on the executable side, so an external consumer that
    // uses them has no other way to get them linked.
    const target_os = exe.rootModuleTarget().os.tag;
    if (features.enable_audio) linkAudioBackend(exe.root_module, target_os);
    if (features.enable_midi) linkMidiBackend(exe.root_module, target_os);
}

// ============================================================================
// Wasm app + web package helpers
//
// Spec-driven builders for wasm32-wasi apps and the multi-file web package under
// zig-out/web/. All functions run at build-graph configuration time only.
// ============================================================================

/// Audio transport selected for a wasm app at build time.
/// JS glue and worklet code read the same choice from HTML data attributes or
/// embedded package options; they do not infer transport from the app name.
pub const WasmAudio = enum {
    /// No audio path. AudioContext / AudioWorklet are not started.
    none,
    /// Shared wasm memory + dual Instance (main + AudioWorklet). Requires COOP/COEP.
    worklet_shared,
    /// Non-shared memory; main thread renders and postMessages blocks to the worklet.
    worklet_postmessage,
};

/// Named module import wired onto the app module (`app_module.addImport`).
pub const WasmImport = struct {
    name: []const u8,
    module: *std.Build.Module,
};

/// Build-time description of one wasm web app.
///
/// Memory / entry / rdynamic / install layout are applied by `addWasmApp` from
/// these fields so root and external consumers cannot drift on the wasm ABI.
pub const WasmAppSpec = struct {
    name: []const u8,

    target_query: std.Target.Query,
    app_source: std.Build.LazyPath,
    wasm_root_source: std.Build.LazyPath,
    /// Import name the wasm root uses for the app module (e.g. `"pixie"`, `"synth_app"`).
    wasm_root_import_name: []const u8,

    imports: []const WasmImport = &.{},
    extra_link_libraries: []const *std.Build.Step.Compile = &.{},

    single_threaded: bool = true,

    audio: WasmAudio = .none,

    shared_memory: bool = false,
    import_memory: bool = false,
    export_memory: bool = false,
    /// When 0, leave the Compile step default (unset).
    initial_memory: u64 = 0,
    max_memory: ?u64 = null,
    /// When 0, leave the Compile step default (unset).
    stack_size: u64 = 0,
    export_symbol_names: []const []const u8 = &.{},

    html_source: std.Build.LazyPath,
    /// Install destination relative to the prefix (e.g. `"web/index.html"`).
    html_install_path: []const u8,

    /// When true, a single-HTML pack step is required (configured by the package helper).
    single_html: bool = false,
    /// Basename for `web/<basename>.single.html` (default = `name`).
    /// Use when the wasm artifact name differs from the desired single-HTML name
    /// (e.g. name=`synth_postmessage`, single_html_basename=`synth` → `synth.single.html`).
    single_html_basename: ?[]const u8 = null,
};

/// Context passed to an optional root-only dependency linker.
pub const WasmLinkContext = struct {
    app_module: *std.Build.Module,
    root_module: *std.Build.Module,
    exe: *std.Build.Step.Compile,
    spec: *const WasmAppSpec,
};

/// Callback that wires internal modules onto an already-created app module.
/// External consumers leave this null and use `WasmAppSpec.imports` instead.
pub const WasmLinker = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque, WasmLinkContext) void,
};

/// Result of building one wasm app (artifact + install steps).
pub const WasmAppBuild = struct {
    exe: *std.Build.Step.Compile,
    install: *std.Build.Step.InstallArtifact,
    html_install: *std.Build.Step.InstallFile,
    /// Set when single-HTML packing is configured for this app.
    single_html_install: ?*std.Build.Step.InstallFile = null,
    /// Reads the compiled wasm and fails the build if it exports `_start` or `_initialize`.
    /// Every step that ships this artefact — the multi-file install and the single-HTML pack
    /// alike — depends on this run, because each is reachable without the other.
    export_check: *std.Build.Step.Run,
};

/// Per-app install edges for the web package step.
pub const PerAppWebInstall = struct {
    name: []const u8,
    wasm_install: *std.Build.Step.InstallArtifact,
    html_install: *std.Build.Step.InstallFile,
    single_html_install: ?*std.Build.Step.InstallFile = null,
};

/// Static web assets plus per-app wasm/HTML installs under `zig-out/web/`.
pub const WebStaticInstalls = struct {
    apps: []const PerAppWebInstall,
    js: *std.Build.Step.InstallFile,
    worklet: *std.Build.Step.InstallFile,
    headers: *std.Build.Step.InstallFile,
    netlify: *std.Build.Step.InstallFile,
    serve_script: *std.Build.Step.InstallFile,

    pub fn dependOnAll(self: WebStaticInstalls, step: *std.Build.Step) void {
        for (self.apps) |app| {
            step.dependOn(&app.wasm_install.step);
            step.dependOn(&app.html_install.step);
            if (app.single_html_install) |single| step.dependOn(&single.step);
        }
        step.dependOn(&self.js.step);
        step.dependOn(&self.worklet.step);
        step.dependOn(&self.headers.step);
        step.dependOn(&self.netlify.step);
        step.dependOn(&self.serve_script.step);
    }

    pub fn dependOnShared(self: WebStaticInstalls, step: *std.Build.Step) void {
        step.dependOn(&self.js.step);
        step.dependOn(&self.worklet.step);
        step.dependOn(&self.headers.step);
        step.dependOn(&self.netlify.step);
        step.dependOn(&self.serve_script.step);
    }
};

/// Shared (non-app) web package assets.
pub const WasmWebAssets = struct {
    js: std.Build.LazyPath,
    worklet: std.Build.LazyPath,
    headers: std.Build.LazyPath,
    netlify: std.Build.LazyPath,
    serve_script: std.Build.LazyPath,
    /// Host packer source (`cli/pack-single-html.zig`). Required when any app has `single_html`.
    packer: ?std.Build.LazyPath = null,
    /// Host export-checker source (`cli/check-wasm-exports.zig`). Not optional: a wasm
    /// artefact that reaches a browser is always subject to the check, and a default of
    /// "no checker" would let a build opt out of it by saying nothing.
    export_check: std.Build.LazyPath,
};

pub const AddWasmAppOptions = struct {
    /// When true, fold the wasm and HTML install steps into `zig build` (the install step).
    default_install: bool = true,
    /// Host executable built from `cli/check-wasm-exports.zig` (see `makeWasmExportCheckExe`).
    /// One instance can serve every app in a package. Not optional, for the reason given on
    /// `WasmWebAssets.export_check`.
    export_check_exe: *std.Build.Step.Compile,
};

pub const AddWasmWebPackageOptions = struct {
    apps: []const WasmAppSpec,
    assets: WasmWebAssets,
    optimize: std.builtin.OptimizeMode,
    linker: ?WasmLinker = null,
    /// When true, fold wasm/HTML/shared static installs into the default install step.
    default_install: bool = false,
    /// When true, create the multi-file `package-web` step (wasm + HTML + shared assets).
    create_package_step: bool = true,
    package_step_name: []const u8 = "package-web",
    package_step_description: []const u8 = "Package wasm web deploy bundle to zig-out/web/",
    /// When true, create a step that depends only on single-HTML installs for apps that request them.
    create_single_package_step: bool = false,
    single_package_step_name: []const u8 = "package-web-single",
    single_package_step_description: []const u8 = "Package single-file HTML (embedded wasm + glue) to zig-out/web/",
};

/// Validate audio/memory/target consistency for a resolved wasm target.
pub fn validateWasmAppSpec(spec: *const WasmAppSpec, target: std.Build.ResolvedTarget) void {
    switch (spec.audio) {
        .none => {
            if (spec.shared_memory or spec.import_memory) {
                std.log.err(
                    "wasm app '{s}': audio=none requires shared_memory=false and import_memory=false",
                    .{spec.name},
                );
                std.process.exit(1);
            }
        },
        .worklet_postmessage => {
            if (spec.shared_memory or spec.import_memory) {
                std.log.err(
                    "wasm app '{s}': audio=worklet_postmessage requires shared_memory=false and import_memory=false",
                    .{spec.name},
                );
                std.process.exit(1);
            }
        },
        .worklet_shared => {
            if (!spec.shared_memory or !spec.import_memory) {
                std.log.err(
                    "wasm app '{s}': audio=worklet_shared requires shared_memory=true and import_memory=true",
                    .{spec.name},
                );
                std.process.exit(1);
            }
            if (!target.result.cpu.has(.wasm, .atomics) or !target.result.cpu.has(.wasm, .bulk_memory)) {
                std.log.err(
                    "wasm app '{s}': audio=worklet_shared requires target features atomics and bulk_memory",
                    .{spec.name},
                );
                std.process.exit(1);
            }
        },
    }

    // Single-HTML: shared audio needs response headers (impossible for file:// / single file).
    // none and worklet_postmessage are allowed (postmessage embeds the worklet source).
    if (spec.single_html and spec.audio == .worklet_shared) {
        std.log.err(
            "wasm app '{s}': single_html cannot use audio=worklet_shared (needs COOP/COEP headers)",
            .{spec.name},
        );
        std.process.exit(1);
    }
}

/// Build one wasm app from `spec` and install `web/<name>.wasm` plus its HTML.
///
/// Common wasm ABI (entry, rdynamic, memory, exports) is applied here.
/// Optional `linker` only wires modules onto the already-created app module.
pub fn addWasmApp(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    spec: *const WasmAppSpec,
    linker: ?WasmLinker,
    opts: AddWasmAppOptions,
) WasmAppBuild {
    const target = b.resolveTargetQuery(spec.target_query);
    validateWasmAppSpec(spec, target);

    const app_module = b.createModule(.{
        .root_source_file = spec.app_source,
        .target = target,
        .optimize = optimize,
        .single_threaded = spec.single_threaded,
    });
    for (spec.imports) |imp| {
        app_module.addImport(imp.name, imp.module);
    }

    const root_module = b.createModule(.{
        .root_source_file = spec.wasm_root_source,
        .target = target,
        .optimize = optimize,
        .single_threaded = spec.single_threaded,
    });
    if (spec.export_symbol_names.len != 0) {
        root_module.export_symbol_names = spec.export_symbol_names;
    }

    const exe = b.addExecutable(.{
        .name = spec.name,
        .root_module = root_module,
    });
    exe.entry = .disabled;
    exe.rdynamic = true;
    exe.shared_memory = spec.shared_memory;
    exe.import_memory = spec.import_memory;
    exe.export_memory = spec.export_memory;
    if (spec.initial_memory != 0) exe.initial_memory = spec.initial_memory;
    if (spec.max_memory) |max_memory| exe.max_memory = max_memory;
    if (spec.stack_size != 0) exe.stack_size = spec.stack_size;
    exe.root_module.addImport(spec.wasm_root_import_name, app_module);
    for (spec.extra_link_libraries) |lib| {
        exe.root_module.linkLibrary(lib);
    }

    if (linker) |l| {
        l.apply(l.context, .{
            .app_module = app_module,
            .root_module = root_module,
            .exe = exe,
            .spec = spec,
        });
    }

    // Gate the artefact before anything ships it. A compile and link that succeed say
    // nothing about whether libc reached the module graph; only the export table does.
    const export_check = b.addRunArtifact(opts.export_check_exe);
    export_check.setName(b.fmt("check-wasm-exports {s}", .{spec.name}));
    export_check.addArg("--wasm");
    export_check.addFileArg(exe.getEmittedBin());
    export_check.addArg("--out");
    _ = export_check.addOutputFileArg(b.fmt("{s}.wasm-exports-ok", .{spec.name}));

    const wasm_install = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
    });
    wasm_install.step.dependOn(&export_check.step);
    if (opts.default_install) b.getInstallStep().dependOn(&wasm_install.step);

    const html_install = b.addInstallFile(spec.html_source, spec.html_install_path);
    if (opts.default_install) b.getInstallStep().dependOn(&html_install.step);

    return .{
        .exe = exe,
        .install = wasm_install,
        .html_install = html_install,
        .single_html_install = null,
        .export_check = export_check,
    };
}

/// Host executable for the export check (not installed). Shared across apps in one package call.
pub fn makeWasmExportCheckExe(b: *std.Build, source: std.Build.LazyPath) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "check-wasm-exports",
        .root_module = b.createModule(.{
            .root_source_file = source,
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
}

/// Host packer executable (not installed). Shared across apps in one package call.
fn makePackerExe(b: *std.Build, packer_source: std.Build.LazyPath) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "pack-single-html",
        .root_module = b.createModule(.{
            .root_source_file = packer_source,
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
}

/// Run the packer and install `web/<name>.single.html`. Does not install the packer itself.
fn addSingleHtmlPack(
    b: *std.Build,
    packer_exe: *std.Build.Step.Compile,
    app: *const WasmAppBuild,
    spec: *const WasmAppSpec,
    assets: WasmWebAssets,
    default_install: bool,
) *std.Build.Step.InstallFile {
    const run = b.addRunArtifact(packer_exe);
    run.setName(b.fmt("pack-single-html {s}", .{spec.name}));
    run.addArg("--html");
    run.addFileArg(spec.html_source);
    run.addArg("--js");
    run.addFileArg(assets.js);
    run.addArg("--wasm");
    run.addFileArg(app.exe.getEmittedBin());
    run.addArg("--wasm-name");
    run.addArg(b.fmt("{s}.wasm", .{spec.name}));
    run.addArg("--audio");
    run.addArg(@tagName(spec.audio));
    if (spec.shared_memory) run.addArg("--shared-memory");
    if (spec.audio == .worklet_postmessage) {
        run.addArg("--worklet");
        run.addFileArg(assets.worklet);
    }
    run.addArg("--out");
    const single_base = spec.single_html_basename orelse spec.name;
    const out = run.addOutputFileArg(b.fmt("{s}.single.html", .{single_base}));

    const install_path = b.fmt("web/{s}.single.html", .{single_base});
    const install = b.addInstallFile(out, install_path);
    // The single-HTML bundle embeds the wasm without going through the multi-file install,
    // so it needs its own edge to the export check rather than inheriting one.
    install.step.dependOn(&app.export_check.step);
    if (default_install) b.getInstallStep().dependOn(&install.step);
    return install;
}

/// Build every app in `options.apps`, install shared web assets, and optionally
/// create the `package-web` / `package-web-single` steps. Returns one `WasmAppBuild`
/// per app (caller may attach dedicated compile-only build steps to each `exe`).
pub fn addWasmWebPackage(b: *std.Build, options: AddWasmWebPackageOptions) []WasmAppBuild {
    const apps = b.allocator.alloc(WasmAppBuild, options.apps.len) catch @panic("OOM");
    const per_app = b.allocator.alloc(PerAppWebInstall, options.apps.len) catch @panic("OOM");

    var any_single = false;
    for (options.apps) |spec| {
        if (spec.single_html) any_single = true;
    }
    if (any_single and options.assets.packer == null) {
        std.log.err("addWasmWebPackage: single_html apps require assets.packer (cli/pack-single-html.zig)", .{});
        std.process.exit(1);
    }
    const packer_exe: ?*std.Build.Step.Compile = if (any_single)
        makePackerExe(b, options.assets.packer.?)
    else
        null;
    const export_check_exe = makeWasmExportCheckExe(b, options.assets.export_check);

    for (options.apps, 0..) |*spec, i| {
        apps[i] = addWasmApp(b, options.optimize, spec, options.linker, .{
            .default_install = options.default_install,
            .export_check_exe = export_check_exe,
        });
        if (spec.single_html) {
            apps[i].single_html_install = addSingleHtmlPack(
                b,
                packer_exe.?,
                &apps[i],
                spec,
                options.assets,
                options.default_install,
            );
        }
        per_app[i] = .{
            .name = spec.name,
            .wasm_install = apps[i].install,
            .html_install = apps[i].html_install,
            .single_html_install = apps[i].single_html_install,
        };
    }

    const static_assets = WebStaticInstalls{
        .apps = per_app,
        .js = b.addInstallFile(options.assets.js, "web/kngn.js"),
        .worklet = b.addInstallFile(options.assets.worklet, "web/kngn-worklet.js"),
        .headers = b.addInstallFile(options.assets.headers, "web/_headers"),
        .netlify = b.addInstallFile(options.assets.netlify, "web/netlify.toml"),
        .serve_script = b.addInstallFile(options.assets.serve_script, "web/serve-coop-coep.py"),
    };

    if (options.default_install) {
        // Per-app wasm/HTML already joined the install step in addWasmApp.
        static_assets.dependOnShared(b.getInstallStep());
    }

    if (options.create_package_step) {
        const package_step = b.step(options.package_step_name, options.package_step_description);
        // Multi-file package: wasm + multi-file HTML + shared assets (not single HTML).
        for (per_app) |app| {
            package_step.dependOn(&app.wasm_install.step);
            package_step.dependOn(&app.html_install.step);
        }
        static_assets.dependOnShared(package_step);
    }

    if (options.create_single_package_step) {
        const single_step = b.step(options.single_package_step_name, options.single_package_step_description);
        var any: bool = false;
        for (per_app) |app| {
            if (app.single_html_install) |s| {
                single_step.dependOn(&s.step);
                any = true;
            }
        }
        if (!any) {
            std.log.err(
                "addWasmWebPackage: create_single_package_step is set but no app has single_html",
                .{},
            );
            std.process.exit(1);
        }
    }

    return apps;
}
