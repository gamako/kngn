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

/// Opt-in feature flags for the macOS platform layer (gamepad / menu).
/// Bundled into an options struct so more bools can be added without growing the parameter list.
pub const PlatformFeatures = struct {
    enable_gamepad: bool = false,
    enable_menu: bool = false,
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
}
