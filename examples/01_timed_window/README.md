# Example 01: Timed Window

Shows a window whose colour changes over two seconds, then exits.

## What it demonstrates

Basic manual-drawing API usage:

- `platform.Window.create()` — create a window
- `window.pollEvents()` — non-blocking event poll
- `platform.getTime()` — high-resolution time
- `window.lockFramebuffer()` — begin framebuffer access
- `fb.unlock()` — end framebuffer access
- `window.present()` — submit the frame
- `platform.frameDelay(...)` — pace the loop (~60 FPS here)

## Behaviour

- Window size: 800×600
- Duration: 2 seconds
- Colour transition: green → yellow → red

## Build

Default `-Dplatform` depends on the OS (macOS=objc / Linux=x11 / Windows=gdi). The
`run-objc` / `run-swift` / `run-metal` steps below are for macOS. On Linux/Windows use
`zig build run` (default backend) or `-Dplatform=x11|wayland|gdi|d3d11`.

### Objective-C (macOS default)

```bash
cd examples/01_timed_window
zig build
# or
zig build run-objc
```

### Swift

```bash
zig build -Dplatform=swift
# or
zig build run-swift
```

### Metal

```bash
zig build -Dplatform=metal
# or
zig build run-metal
```

From the repository root:

```bash
zig build run-example_01
zig build run-example_01 -Dplatform=metal
```

## Run (standalone binaries)

```bash
# Default backend (macOS=objc / Linux=x11 / Windows=gdi)
zig build run

# Installed binaries (macOS; bare name = default backend)
./zig-out/bin/example_01_timed_window        # default (Objective-C on macOS)
./zig-out/bin/example_01_timed_window_swift  # Swift
./zig-out/bin/example_01_timed_window_metal  # Metal
```

## Learning points

### 1. Manual draw flow

```zig
const platform = @import("platform");

try platform.init();
defer platform.shutdown();

var window = try platform.Window.create(800, 600, "title");
defer window.destroy();

while (window.pollEvents()) {
    if (window.lockFramebuffer()) |fb| {
        defer fb.unlock();
        @memset(fb.pixels, color);
        window.present();
    }
}
```

### 2. Timing

```zig
const start_time = platform.getTime();
const elapsed = platform.getTime() - start_time;

if (elapsed >= duration) {
    break;
}
```

### 3. Colour interpolation

Linear interpolation between two colours for a smooth transition.

## Next steps

- `02_keyboard_input` — keyboard handling
- `03_sprite_rendering` — sprite display
- `04_fixed_timestep` — fixed timestep + physics
- `07_mouse_input` — mouse handling

## Notes

- This sample paces with `platform.frameDelay(16_666_666)` (~60 FPS). Serious applications
  should prefer first-class backend frame pacing (fifo) or the frame-pacing APIs; `present` is not a
  vsync wait.
- `window.present()` is a non-blocking submit (frame commit point). Tier-1 backends
  (Metal / D3D11-DXGI / Wayland) target tear-free fifo; best-effort backends
  (CALayer objc/swift / X11 / GDI) may tear or jitter. See `docs/adr/005`.
