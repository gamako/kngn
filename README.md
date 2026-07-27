# video-proto

A cross-platform environment for prototyping video and graphics. An application layer
written in Zig sits on a low-level API layer implemented per platform. A minimal set of
primitive APIs (events / manual drawing / time) underpins GUI, editors, audio/synth, and a
headless verification harness.

> **Technical detail lives in [`AGENT.md`](AGENT.md)** (directory layout, platform API, backends,
> build/test, headless harness, audio layers, and more). This README stays an overview and
> quick start.

## Supported platforms

| OS | backend (`-Dplatform`) | Implementation |
|----|------------------------|----------------|
| **macOS** | `objc` (default) / `swift` / `metal` | Objective-C (CALayer) / Swift (CADisplayLink) / Metal (GPU) |
| **Linux** | `x11` (default) / `wayland` | Pure Zig (Xlib direct / wl_shm + xdg-shell direct) |
| **Windows** | `gdi` (default) / `d3d11` | Pure Zig (Win32/GDI direct / hand-written D3D11-DXGI COM) |

Valid `-Dplatform` values are OS-specific (asking for `x11` on macOS is a build error). Frame-pacing
support tiers (first-class = Metal / D3D11-DXGI / Wayland; best-effort = CALayer / X11 / GDI) are in
`docs/adr/005`.

## Layout

```
.
├── core/         # Platform facade + per-OS backends, audio, MIDI, the control plane (harness)
├── kit/          # The public umbrella module that applications and external consumers import
├── src/          # Zig not yet moved into libs (main, dsp, BDF text, gamepad helpers)
├── platform/     # macOS native (C ABI: macos / macos-shared / macos-swift / macos-metal)
├── examples/     # Samples 01–41 (`run-example_NN`) + image/ (shared assets)
├── libs/         # Reusable libraries (png / gui / font / synth / paint / …)
├── apps/         # Applications (editor/pixie: pixel editor; synth: PC-keyboard play)
└── docs/         # Design docs (per-subsystem docs / adr/)
```

## Prerequisites

| Item | Role |
|------|------|
| nix (flakes) + direnv | `flake.nix` (`aarch64-darwin` / `x86_64-linux`) supplies zig 0.16.0 + zls + deps. Recommended |
| macOS (Apple Silicon) + Xcode | SDK / frameworks / `swiftc` for macOS backends |
| Linux (x86_64) | X11/Wayland dev libs come from the flake's devShell |
| Windows | Install zig 0.16.0 locally and build natively (no flake) |

```bash
direnv allow      # once (.envrc). After that, entering the directory puts zig on PATH
zig version       # → 0.16.0
```

Without direnv, call `nix develop --command zig build ...`.

## Build and run

```bash
# Main program (HSV rainbow gradient)
zig build run                 # default backend (macOS=objc / Linux=x11 / Windows=gdi)
zig build run-objc            # explicit backend (macOS: run-objc / run-swift / run-metal)
zig build run -Dplatform=metal  # switch the default run backend (e.g. Metal)

# Applications
zig build run-pixie           # pixel editor (-Dplatform switches backend)
zig build run-synth           # synth (PC keyboard; A..K = C4..C5, ESC quits)

# Samples (from the repo root; 01–41)
zig build run-example_01      # 01_timed_window
zig build run-example_15      # 15_audio_tone … (run-example_NN)

# Build regression across all backends / samples
zig build -Dinstall-all=true

# Release
zig build --release=fast
```

## Tests

```bash
zig build test                # aggregate of every test-* step
zig build test-gui            # individual (e.g. libs/gui). Also test-core / test-png-roundtrip /
                              # test-synth / test-dsp / test-font / test-harness and others
```

SDK / Swift toolchain paths used by macOS Swift/Metal builds are detected via `xcrun` /
`xcode-select` (no `build.zig` edit needed when Xcode updates). To pin them in CI, pass
`-Dswift-toolchain-path=` / `-Dswift-sdk-path=`.

## License

Project code is released under the [MIT License](LICENSE). Bundled third-party assets and
libraries keep their own licenses (see each directory's LICENSE):

| Component | License | Location |
|---|---|---|
| Press Start 2P (font) | SIL OFL 1.1 | [`libs/font/LICENSE`](libs/font/LICENSE) |
| Spleen (bitmap font) | BSD-2-Clause | [`libs/gui/LICENSE`](libs/gui/LICENSE) / [`examples/05_text_rendering/assets/LICENSE-spleen`](examples/05_text_rendering/assets/LICENSE-spleen) |
| LodePNG (dev tools only; not shipped in the build) | zlib License | [`libs/png/tools/lodepng/LICENSE`](libs/png/tools/lodepng/LICENSE) |

Some samples such as `examples/19_color_emoji` load OS system fonts (Apple Color Emoji and so on)
at runtime and do not ship those fonts in the repository.
