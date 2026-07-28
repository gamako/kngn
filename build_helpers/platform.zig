//! Compile helpers for the platform layer (ObjC / Swift / Metal)
//!
//! Shared by the parent build.zig and examples/*/build.zig.
//! Inputs are LazyPaths so they carry build-graph dependencies.

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

/// Whether an L1 audio-output backend is implemented for the OS (macOS=AudioToolbox / Linux=ALSA / Windows=WASAPI).
/// Used by both top-level build.zig and standalone as the gate for audio-required targets (synth / example_15)
/// (one place for the decision).
pub fn audioSupported(os: std.Target.Os.Tag) bool {
    return os == .macos or os == .linux or os == .windows;
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

/// Create the platform module (`core/platform.zig`).
///
/// macOS backends `@cImport` `platform.h`, so `link_libc = true` and the
/// platform/ include path are applied together (Linux backends do not pull in platform.h,
/// so the include path is a harmless dead path there).
///
/// `backend` is passed as `build_options.platform_backend` ("x11"/"wayland"/"objc"…) into the
/// platform module; `core/platform_linux.zig` and friends use it to pick x11/wayland.
/// Call once per backend so each gets its own module with a distinct value.
///
/// Path resolution (`b.path` / `cwd_relative`) is left to the callsite.
/// Parent build.zig uses `b.path(...)`; standalone uses
/// `.{ .cwd_relative = PROJECT_ROOT ++ ... }`.
///
/// Opt-in feature flags for the macOS platform layer (gamepad / menu).
/// Bundled into an options struct so more bools can be added without growing the parameter list.
pub const PlatformFeatures = struct {
    enable_gamepad: bool = false,
    enable_menu: bool = false,
};

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
    /// Opt-in features (gamepad / menu). Baked into the platform module as `build_options.enable_gamepad` / `enable_menu`.
    /// gamepad: read by the facade's `Window.getGamepadState`.
    /// menu: read by the comptime gate on C-symbol refs in `platform_macos.zig`.
    /// The harness synthetic gamepad path always runs regardless of this value.
    features: PlatformFeatures,
) *std.Build.Module {
    // linkSystemLibrary needs a module with a known target, so set target explicitly
    // (import modules usually inherit from the importer, but the x11 link call needs it beforehand).
    const is_wasm = backend == .wasm;
    // wasm shared audio: multi-thread when the target has atomics (real atomic ops).
    const wasm_shared = is_wasm and target.result.cpu.has(.wasm, .atomics);
    const mod = b.createModule(.{
        .root_source_file = platform_source,
        .target = target,
        .link_libc = !is_wasm, // wasm (wasi) uses wasi preview1 + a hand-written JS shim. No libc.
        .single_threaded = if (is_wasm) !wasm_shared else null,
    });
    if (!is_wasm) mod.addIncludePath(platform_include_root);
    // platform.zig + backends `@import("platform_types")`; the facade `@import("harness")`.
    mod.addImport("platform_types", types_mod);
    mod.addImport("command_types", command_types_mod);
    mod.addImport("harness", harness_mod);

    const opts = b.addOptions();
    opts.addOption([]const u8, "platform_backend", backendName(backend));
    opts.addOption(bool, "enable_gamepad", features.enable_gamepad);
    opts.addOption(bool, "enable_menu", features.enable_menu);
    mod.addOptions("build_options", opts);

    // Linux x11: platform_linux_x11.zig `@cImport(<X11/Xlib.h>)` / `<X11/extensions/XShm.h>`.
    // linkSystemLibrary("X11"/"Xext") on the platform module both (a) resolves `@cImport` headers
    // (via pkg-config Cflags) and (b) propagates the libs to the exe.
    if (backend == .x11) {
        mod.linkSystemLibrary("X11", .{});
        mod.linkSystemLibrary("Xext", .{});
    } else if (backend == .wayland) {
        // Wayland backend: platform_linux_wayland.zig
        // `@cImport(<wayland-client.h>, <xkbcommon/xkbcommon.h>, "xdg-shell-client-protocol.h")`.
        // Linking wayland-client/xkbcommon both (a) resolves `@cImport` headers (pkg-config Cflags) and
        // (b) propagates the libs to the exe. xdg-shell-client-protocol.h is a wayland-scanner
        // product, so add its generated-header dir to the include path.
        mod.linkSystemLibrary("wayland-client", .{});
        mod.linkSystemLibrary("wayland-cursor", .{}); // system cursor (wl_cursor_theme / @cInclude <wayland-cursor.h>)
        mod.linkSystemLibrary("xkbcommon", .{});
        mod.addIncludePath(generateXdgShellClientHeaderDir(b));
        mod.addIncludePath(generateXdgDecorationClientHeaderDir(b)); // SSD/CSD decoration
    }

    return mod;
}

// ============================================================================
// xdg-shell protocol glue
//
// Wayland window management uses the xdg-shell protocol. Generate client-header (.h) and
// private-code (.c) at build time via the standard `wayland-scanner` path (no hand-writing). Pull `xdg-shell.xml` from
// `pkg-config --variable=pkgdatadir wayland-protocols` (assumes the nix devShell).
//
// Generation runs per backend×exe, symmetric with macOS clang'ing platform_macos.m per exe
// inside setupExecutableForPlatform, without widening the helper signature (scanner is cheap).
// ============================================================================

/// Generate `xdg-shell-client-protocol.h` and return its parent directory (for the include path).
/// Used to resolve Wayland backend `@cImport("xdg-shell-client-protocol.h")`.
fn generateXdgShellClientHeaderDir(b: *std.Build) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        "sh",                                                                                                                            "-c",
        // $0=sh, $1=output path (addOutputFileArg). Locate xdg-shell.xml via pkg-config.
        "wayland-scanner client-header \"$(pkg-config --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml\" \"$1\"", "sh",
    });
    return cmd.addOutputFileArg("xdg-shell-client-protocol.h").dirname();
}

/// Generate `xdg-shell-protocol.c` (protocol marshalling body) and return a LazyPath.
/// Add it as a C source on the exe (references wl_proxy_*, so wayland-client must be linked).
fn generateXdgShellPrivateCode(b: *std.Build) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        "sh",                                                                                                                           "-c",
        "wayland-scanner private-code \"$(pkg-config --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml\" \"$1\"", "sh",
    });
    return cmd.addOutputFileArg("xdg-shell-protocol.c");
}

// xdg-decoration protocol glue (SSD request / CSD fallback)
// Same shape as xdg-shell. XML lives under wayland-protocols unstable/xdg-decoration. As of 2026-07 upstream has not
// moved it to staging (still under unstable/). If the path drifts, confirm on a Linux machine with
// `find "$(pkg-config --variable=pkgdatadir wayland-protocols)" -iname '*decoration*'`.
// wl_subcompositor is a core wayland-client interface (declared in wayland-client.h); no scanner generation needed.

/// Generate `xdg-decoration-unstable-v1-client-protocol.h` and return its parent directory (for the include path).
fn generateXdgDecorationClientHeaderDir(b: *std.Build) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        "sh",                                                                                                                                                    "-c",
        "wayland-scanner client-header \"$(pkg-config --variable=pkgdatadir wayland-protocols)/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml\" \"$1\"", "sh",
    });
    return cmd.addOutputFileArg("xdg-decoration-unstable-v1-client-protocol.h").dirname();
}

/// Generate `xdg-decoration-unstable-v1-protocol.c` (marshalling body) and return a LazyPath.
fn generateXdgDecorationPrivateCode(b: *std.Build) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        "sh",                                                                                                                                                   "-c",
        "wayland-scanner private-code \"$(pkg-config --variable=pkgdatadir wayland-protocols)/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml\" \"$1\"", "sh",
    });
    return cmd.addOutputFileArg("xdg-decoration-unstable-v1-protocol.c");
}

/// Set up the platform layer on an executable.
///
/// macOS backend: compile the platform layer (.o), link frameworks / Swift runtime, and
/// set include paths in one shot (`sdk_paths` required).
/// Linux backend: pure Zig, so no .o compile; only link X11 etc. (`sdk_paths` is null).
///
/// Each example's build.zig only needs this one call for all platform setup.
///
/// `features`: macOS-backend opt-in (gamepad=GameController / menu=NSMenu).
/// Only true flags pass `-DVP_ENABLE_*` into the .o compile. Ignored on Linux/Windows backends.
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

            const compiled = compilePlatformLayer(b, platform_type, optimize, platform_root, features);
            for (compiled.obj_files) |obj| {
                exe.root_module.addObjectFile(obj);
            }
            exe.root_module.link_libc = true;
            exe.root_module.addIncludePath(platform_root);
            for (compiled.compile_steps) |step| {
                exe.step.dependOn(&step.step);
            }

            macos.linkMacOSFrameworks(b, exe, sdk, features.enable_gamepad);

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
            // X11/Xlib backend (pure Zig). No .o compile or frameworks.
            // Xlib symbols propagate from createPlatformModule's linkSystemLibrary("X11"/"Xext")
            // to the exe, so only enable libc here.
            exe.root_module.link_libc = true;
        },
        .wayland => {
            // Wayland backend (pure Zig). Compile the generated xdg-shell-protocol.c per exe
            // (symmetric with macOS addObjectFile of platform_macos.m; do not widen the helper signature).
            // The .c references wl_proxy_*, so linking wayland-client is required.
            // Also linkSystemLibrary wayland-client on the exe so .c compile (header resolve) and
            // symbol resolve are reliable (do not rely on module propagation alone).
            exe.root_module.link_libc = true;
            exe.root_module.linkSystemLibrary("wayland-client", .{});
            exe.root_module.linkSystemLibrary("wayland-cursor", .{}); // system cursor
            exe.root_module.addCSourceFile(.{ .file = generateXdgShellPrivateCode(b) });
            exe.root_module.addCSourceFile(.{ .file = generateXdgDecorationPrivateCode(b) }); // xdg-decoration private code
        },
        .gdi, .d3d11 => {
            // Windows backend (pure Zig). platform_windows.zig (dispatcher) calls Win32 via extern fn
            // (no @cImport). No SDK/xcrun; zig's bundled MinGW import libs resolve the link
            // (kernel32 is auto-linked by zig). libc is not required (std.os.windows + extern fn only), but
            // enable it to match other OS behaviour. Shared window/input/dialog uses user32 / comdlg32.
            exe.root_module.link_libc = true;
            exe.root_module.linkSystemLibrary("user32", .{}); // CreateWindowExW / message pump / input
            exe.root_module.linkSystemLibrary("comdlg32", .{}); // GetSaveFileNameW / GetOpenFileNameW
            switch (platform_type) {
                // GDI: software blit (StretchDIBits / BITMAPINFO).
                .gdi => exe.root_module.linkSystemLibrary("gdi32", .{}),
                // D3D11-DXGI: GPU upload path. The only named export is d3d11.dll's D3D11CreateDeviceAndSwapChain
                // (swap chain / DXGI are only touched via COM vtbls from the d3d11-created objects, so no dxgi.dll
                // import). gdi32 is also unnecessary.
                .d3d11 => exe.root_module.linkSystemLibrary("d3d11", .{}),
                else => unreachable,
            }
            // Use the Windows subsystem for GUI apps (the default console subsystem would open a
            // console window on launch). Tools whose console output is the point (e.g. example_06 bench)
            // override to .Console at the caller. std.debug.print is a no-op when no console is attached.
            exe.subsystem = .Windows;
        },
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
    /// `-DVP_ENABLE_GAMEPAD`, and GameController is linked. Default false
    /// (existing standalone exes unchanged). Only examples/22_gamepad opts in.
    link_gamepad: bool = false,
    /// Native menu (NSMenu; shared across macOS objc/swift/metal). When true,
    /// `build_options.enable_menu` + shared `platform_macos_menu.m` (`-DVP_ENABLE_MENU`).
    /// Default false. Only pixie opts in.
    link_menu: bool = false,
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
};

/// Link L1 output system libraries per OS onto a standalone exe that uses audio
/// (same policy as top build.zig's linkAudioBackend).
///
/// The macOS branch also links capture frameworks (mic AUHAL input / camera AVFoundation),
/// matching top-level build.zig `linkAudioBackend` as a preventive add.
/// `setupExecutableForPlatform` in the same loop (see call order in
/// `buildStandalone` below) sets the -F/-L search paths, so only framework/library names
/// are needed here (build-graph construction order does not affect link-time resolve).
fn linkAudioForStandalone(exe: *std.Build.Step.Compile, target_os: std.Target.Os.Tag) void {
    switch (target_os) {
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
        .windows => exe.root_module.linkSystemLibrary("ole32", .{}), // WASAPI goes through COM (CoCreateInstance etc. in ole32)
        else => {}, // else: no audio backend. Do not link; leave it to the facade compileError at compile time
    }
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
            .{ .enable_gamepad = spec.link_gamepad, .enable_menu = spec.link_menu },
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

        setupExecutableForPlatform(b, exe, be, optimize, spec.platform_root, sdk_paths, .{
            .enable_gamepad = spec.link_gamepad,
            .enable_menu = spec.link_menu,
        });
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
/// `features`: only true flags pass `-DVP_ENABLE_*` into the .o compile (gamepad/menu opt-in).
/// When enable_menu=true, also compile shared `platform_macos_menu.m` and return it.
/// .m/.swift sources gate on `#if defined(VP_ENABLE_GAMEPAD)` / `#if defined(VP_ENABLE_MENU)`.
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
    compile_cmd.addArg("-DVP_ENABLE_MENU");
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
    // Gamepad opt-in. Enables `#if defined(VP_ENABLE_GAMEPAD)` in platform_macos.m.
    if (features.enable_gamepad) compile_cmd.addArg("-DVP_ENABLE_GAMEPAD");
    // Native menu opt-in. `-DVP_ENABLE_MENU` for bridge + poll consumption.
    // NSMenu body lives in shared platform_macos_menu.m (added by makeCompileResult).
    if (features.enable_menu) compile_cmd.addArg("-DVP_ENABLE_MENU");
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
    // Gamepad opt-in. Enables `#if VP_ENABLE_GAMEPAD` in shared platform_macos_shared.swift.
    // `-import-objc-header` takes the next token as the bridging-header path, so place the define before it
    // (otherwise `-import-objc-header` would consume `-DVP_ENABLE_GAMEPAD` as a path).
    if (features.enable_gamepad) compile_cmd.addArg("-DVP_ENABLE_GAMEPAD");
    // Native menu opt-in. Bridge + poll consumption; body is shared menu.m.
    if (features.enable_menu) compile_cmd.addArg("-DVP_ENABLE_MENU");
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
    // Gamepad opt-in. Enables `#if VP_ENABLE_GAMEPAD` in shared platform_macos_shared.swift.
    // `-import-objc-header` takes the next token as the bridging-header path, so place the define before it.
    if (features.enable_gamepad) compile_cmd.addArg("-DVP_ENABLE_GAMEPAD");
    // Native menu opt-in. Bridge + poll consumption; body is shared menu.m.
    if (features.enable_menu) compile_cmd.addArg("-DVP_ENABLE_MENU");
    compile_cmd.addArg("-import-objc-header");
    compile_cmd.addFileArg(platform_root.path(b, "platform.h"));
    compile_cmd.addArgs(&.{ "-c", "-o" });
    const obj_path = compile_cmd.addOutputFileArg("platform_macos_metal.o");
    // Compile shared .swift and backend-specific .swift in one swiftc invocation (one .o).
    compile_cmd.addFileArg(platform_root.path(b, "macos-shared/platform_macos_shared.swift"));
    compile_cmd.addFileArg(platform_root.path(b, "macos-metal/platform_macos_metal.swift"));
    return makeCompileResult(b, compile_cmd, obj_path, features, optimize, platform_root);
}
