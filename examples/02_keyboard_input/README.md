# Example 02: Keyboard Input (Interactive Colour Palette)

Interactive colour palette driven by keyboard events.

## What it demonstrates

Keyboard event handling:

- `platform.init()` / `platform.shutdown()`
- `platform.Window.create()` / `window.destroy()`
- `window.pollEvents()` — non-blocking poll
- `window.nextEvent()` — tagged-union events
- `platform.Event` — `quit` / `key_down` / `key_up`
- `platform.KeyEvent` — key code, modifiers, repeat
- `platform.KeyCode` — typed key enum
- `platform.ModifierFlags` — SHIFT/CTRL/ALT/CMD as a packed struct
- `keyboard` module — key names and classification helpers
- `window.lockFramebuffer()` / `fb.unlock()` / `window.present()`

## Behaviour

- Window size: 800×600
- Initial colour: orange (HSV: 0°, 0.8, 0.8)
- Colour changes with keyboard input

## Controls

| Key | Action |
|------|------|
| **A–Z** | 26-colour palette (A ≈ red, …; letters set hue at S/V = 0.8) |
| **0–9** | Grayscale (0 = dark, 9 = bright) |
| **↑** | Brightness +5% |
| **↓** | Brightness −5% |
| **←** | Hue −10° |
| **→** | Hue +10° |
| **Space** | Random colour |
| **ESC / Q** | Quit |

Holding Shift / Ctrl / Alt / Cmd prefixes the console `[KEY_DOWN]` line (modifiers are printed;
they do not change the colour action).

> Note: a `.R => reset` branch exists in source but is unreachable — `R` is handled earlier as a
> letter key and sets a palette hue like the other A–Z keys.

## Build

### Objective-C (default on macOS)

```bash
cd examples/02_keyboard_input
zig build
# or
zig build run-objc
```

### Swift / Metal

```bash
zig build -Dplatform=swift
# or
zig build run-swift

zig build -Dplatform=metal
# or
zig build run-metal
```

From the repository root:

```bash
zig build run-example_02
zig build run-example_02 -Dplatform=metal
```

## Run (standalone binaries)

```bash
zig build run

./zig-out/bin/example_02_keyboard_input
./zig-out/bin/example_02_keyboard_input_swift
./zig-out/bin/example_02_keyboard_input_metal
```

## Learning points

### 1. Event-loop pattern

```zig
main_loop: while (window.pollEvents()) {
    while (window.nextEvent()) |ev| switch (ev) {
        .quit => break :main_loop,
        .key_down => |k| {
            // k.key, k.modifiers, k.is_repeat
        },
        .key_up => {},
        else => {},
    };
    // draw…
}
```

### 2. KeyCode

```zig
if (k.key == .ESCAPE) return;

switch (k.key) {
    .UP => move_up(),
    .DOWN => move_down(),
    .LEFT => move_left(),
    .RIGHT => move_right(),
    .SPACE => fire(),
    else => {},
}

const keyboard = @import("keyboard");
if (keyboard.isLetterKey(k.key)) {
    const offset = @intFromEnum(k.key) - @intFromEnum(KeyCode.A);
    _ = offset; // 0..25
}
```

### 3. Modifiers

```zig
const mods = k.modifiers;
if (mods.shift) std.debug.print("Shift+", .{});
if (mods.ctrl) std.debug.print("Ctrl+", .{});
if (mods.alt) std.debug.print("Alt+", .{});
if (mods.cmd) std.debug.print("Cmd+", .{});
```

### 4. Repeat

```zig
if (k.is_repeat) {
    std.debug.print(" [REPEAT]", .{});
}
```

### 5. `keyboard` helpers

```zig
const key_name = keyboard.getKeyName(k.key);
const info = keyboard.getKeyInfo(k.key);
if (keyboard.getCharFromKey(k.key)) |ch| {
    std.debug.print("char='{c}'\n", .{ch});
}
```

## Console sample

```
Starting 02_keyboard_input (Interactive Color Palette)...
Window created. Interactive color palette ready.
Controls:
  A-Z: 26 colors (hue variation)
  0-9: Grayscale (10 steps)
  Arrow Keys: Adjust hue/brightness
  Space: Random color
  R: Reset to default
  ESC/Q: Quit
[KEY_DOWN] A (code=65)
[KEY_DOWN] SHIFT+B (code=66)
[KEY_DOWN] SPACE (code=32)
[KEY_DOWN] UP (code=265)
[KEY_DOWN] Q (code=81)
Quit key pressed
Application terminated.
```

(The in-app banner still prints `R: Reset to default`; pressing R actually picks the R palette
hue — see the controls note above.)

## Implementation notes

### HSV

- **H**: hue 0–360°
- **S**: saturation 0.0–1.0
- **V**: brightness 0.0–1.0

### Frame pacing

Uses `platform.frameDelay(16_666_666)` (~60 FPS). Prefer vsync / frame-pacing APIs for
production apps.

## Caveats

- Keyboard events are handled on the main thread
- Held keys produce repeat events
- Modifier combinations can differ by platform
- `KeyCode` is non-exhaustive (`_` trailing); `switch` needs an `else`
