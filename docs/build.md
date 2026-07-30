# Building

Everything needed to get a build running: the toolchain, the per-OS prerequisites
(with and without nix), the build and test commands, and what can be
cross-compiled.

Verifying a build on Linux and Windows — Xvfb, a headless Wayland compositor,
synthesising input — is a separate topic and lives in
[platform-verification.md](platform-verification.md).

## The toolchain

Zig 0.16.0, and nothing else that is not listed below. There are no third-party
Zig package dependencies: `.dependencies` in `build.zig.zon` is empty.

### With nix (recommended)

`flake.nix` covers two systems, `aarch64-darwin` and `x86_64-linux`, and supplies
zig 0.16.0, zls and every system dependency.

```bash
direnv allow      # once, for .envrc. Entering the directory then puts zig on PATH
zig version       # → 0.16.0
```

Without direnv, prefix each command with `nix develop --command`, as in
`nix develop --command zig build`.

Windows is not covered by the flake — install zig locally and build natively.

### Without nix

nix is not required. Install [zig 0.16.0](https://ziglang.org/download/) and add
the per-OS prerequisites below.

**macOS** — Xcode, or the Command Line Tools. That is all: `xcrun` resolves the
SDK and the `swiftc` path. All three macOS backends, the default `metal` included,
build the editor (`zig build build-pixie`) with the Command Line Tools alone, as
measured: the Metal backend compiles its shaders at
run time from source, so the offline `metal` shader compiler that only Xcode ships
is not needed. Under the Command Line Tools the Swift runtime resolves from the SDK
and the build prints a warning about a Swift library directory it cannot open —
that directory only exists in an Xcode toolchain, and linking succeeds without it.

**Windows** — zig alone. Nothing else.

**Linux (Debian / Ubuntu)**

```bash
sudo apt install pkg-config libx11-dev libxext-dev \
                 libwayland-dev wayland-protocols libxkbcommon-dev \
                 libasound2-dev
```

The X11 backend needs `libx11-dev` and `libxext-dev`; drop the wayland packages
if the X11 backend is enough. `libasound2-dev` is for audio output. Optional:
`zenity` for the file dialog, `fontconfig` for dynamic font resolution. For
headless verification, add `xvfb x11-utils ffmpeg xdotool` (X11) or
`sway grim wtype` (Wayland).

The authoritative package set is the Linux devShell in
[`../flake.nix`](../flake.nix), under nixpkgs attribute names; the apt list above
is that set translated.

## Backends

The valid values of `-Dplatform` depend on the OS. Asking for `x11` on macOS is a
build error.

| OS | `-Dplatform` | Implementation |
|----|--------------|----------------|
| macOS | `metal` (default) / `swift` / `objc` | Metal (GPU) / Swift (CADisplayLink) / Objective-C (CALayer) |
| Linux | `x11` (default) / `wayland` | Pure Zig (Xlib directly / wl_shm plus xdg-shell directly) |
| Windows | `gdi` (default) / `d3d11` | Pure Zig (Win32/GDI directly / hand-written D3D11-DXGI COM) |

The frame-pacing support tiers — first-class (Metal, D3D11-DXGI, Wayland) versus
best-effort (CALayer, X11, GDI) — are in [adr/005](adr/).

## Building and running

```bash
zig build                        # the default backend for the host OS
zig build -Dplatform=metal       # pick a backend

zig build run                    # the main program (an HSV rainbow gradient)
zig build run-pixie              # the pixel editor
zig build run-synth              # the synth (A..K = C4..C5, ESC quits)
zig build run-noodle              # the modular patch canvas
zig build run-example_01         # one example (01..41)

zig build --release=fast         # a release build
zig build -Dinstall-all=true     # every backend and example — the build regression check
```

`run-pixie` and friends default to Debug. On a retina display at `.physical` 2x
that feels slow (27.9 fps measured), so use
`zig build run-pixie -Doptimize=ReleaseFast` to judge smoothness or to measure.

An example also builds on its own:

```bash
cd examples/01_timed_window && zig build run
```

Each example directory holds a `build_helpers` symlink pointing at
`../../build_helpers`, which works around Zig 0.16's restriction on `@import`
outside the build root. Recreate it with
`ln -sf ../../build_helpers build_helpers` if a clone breaks it. On Windows the
symlink does not survive a checkout — see
[platform-verification.md](platform-verification.md).

## Tests

```bash
zig build test          # the aggregate; it bundles every test-*
zig build test-gui      # one suite
```

The individual suites are listed in [`../AGENT.md`](../AGENT.md) under "Common
commands". None of them needs a display.

## The macOS SDK and Swift toolchain

Both paths are detected through `xcrun` and `xcode-select`, so updating Xcode
needs no edit to `build.zig`. To pin them — in CI, for instance — pass
`-Dswift-toolchain-path=` and `-Dswift-sdk-path=`. Setting `DEVELOPER_DIR` to
`/Library/Developer/CommandLineTools` reproduces a machine that has the Command
Line Tools but no Xcode.

## Cross-compilation

A Windows target builds from any host. A Linux target and a macOS target each
need that machine.

| Target | Cross-compiles | What is missing otherwise |
|---|---|---|
| **Windows** | ✅ from any host | — |
| **Linux** | ❌ needs a Linux machine | `pkg-config` and `wayland-scanner` (they generate the xdg-shell C sources at build time), plus the X11 and Wayland headers reached through `@cImport` — that is, a Linux sysroot |
| **macOS** | ❌ needs a Mac | The Apple SDK (Foundation, AppKit, QuartzCore, Metal). `swiftc` exists on Linux, but the missing piece is the frameworks, not the compiler. `build.zig` also resolves the SDK through `xcrun` |

```bash
zig build -Dtarget=x86_64-windows      # produces .exe for both gdi and d3d11
```

The Windows backend calls Win32 through Zig `extern` declarations and links
against the mingw-w64 import libraries that ship with Zig, so neither a sysroot
nor the Windows SDK is involved. Verified by building on macOS: both
`example_01.exe` (GDI) and `example_01_d3d11.exe` come out as
`PE32+ executable (GUI) x86-64`.

The Linux restriction is not fundamental — it is only that no sysroot is wired
up. The macOS one is.

## Consuming this from another project

[app-authoring.md](app-authoring.md) is the guide for that: the published surface, the
four wiring routes, and how to take `template/` out of the tree as a starting point.
[tictactoe](https://github.com/gamako/tictactoe) is a second worked example of a `.path`
dependency.
