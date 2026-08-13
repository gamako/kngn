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
- `platform.framePaceUntil(...)` — pace the loop to a deadline (~60 FPS here)

## Behaviour

- Window size: 800×600
- Duration: 2 seconds
- Colour transition: green → yellow → red

## Build

Default `-Dplatform` depends on the OS (macOS=metal / Linux=x11 / Windows=gdi). macOS has
the single backend `metal`; on Linux/Windows use `zig build run` (default backend) or
`-Dplatform=x11|wayland|gdi|d3d11`.

### Metal (macOS)

```bash
cd examples/01_timed_window
zig build
# or
zig build run-metal
```

From the repository root:

```bash
zig build run-example_01
zig build run-example_01 -Dplatform=wayland   # on Linux
```

## Run (standalone binaries)

```bash
# Default backend (macOS=metal / Linux=x11 / Windows=gdi)
zig build run

# Installed binaries (bare name = default backend; a non-default backend gets a suffix)
./zig-out/bin/example_01_timed_window          # default (Metal on macOS, X11 on Linux)
./zig-out/bin/example_01_timed_window_wayland  # a non-default backend, on Linux
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

- This sample paces with `platform.framePaceUntil(frame_t0 + FRAME_PERIOD_S)` (~60 FPS):
  it takes a frame origin at the top of the loop and waits until that deadline, subtracting
  time spent on work. `present` is not a vsync wait; first-class backend frame pacing (fifo)
  remains available on Tier-1 backends.
- `window.present()` is a non-blocking submit (frame commit point). Tier-1 backends
  (Metal / D3D11-DXGI / Wayland) target tear-free fifo; best-effort backends
  (X11 / GDI) may tear or jitter. See `docs/adr/005`.
