# Example 03: Sprite Rendering

Sprite demo: load a PNG, draw it with clipping, move it with the keyboard.

## Features

- PNG load via `libs/png` (`@embedFile` + `sprite.Sprite.initFromData`)
- Clipping (safe draw when the sprite leaves the window)
- Keyboard movement

## Controls

- **Arrow keys**: move the sprite (5 px per key event)
- **ESC**: quit

## Build / run

From the repository root:

```bash
zig build run-example_03
zig build run-example_03 -Dplatform=swift
zig build run-example_03 -Dplatform=metal
```

Standalone:

```bash
cd examples/03_sprite_rendering
zig build run
zig build run -Dplatform=swift
zig build run -Dplatform=metal
```

## Stack

- **Platform API** (`@import("platform")`):
  - `lockFramebuffer` / `unlock` / `present`
  - `pollEvents` / `nextEvent`
- **Sprite helper** (`@import("sprite")` — `libs/gfx` sprite path wired by the build):
  - `Sprite` / `drawSprite` (premultiplied alpha blend via `libs/pixelops`)
- **PNG**: `libs/png`

## Technical notes

### Current behaviour

- Clipping when the sprite is partially off-screen
- Free position updates
- PNG → canonical BGRA `0xAARRGGBB` (memory `[B,G,R,A]`), matching the framebuffer
- `drawSprite` uses premultiplied alpha blending (transparent pixels leave the background)

### Limits of this sample

- Single sprite only
- No rotate / scale (position only; see `examples/31_sprite_ex` for `drawSpriteEx`)
- Still image (see `examples/32_sprite_anim` for atlas animation)

## Sprite asset

- File: `examples/image/usako.png`
- Size: 64×64
- Format: RGBA PNG

## Related

- [`AGENT.md`](../../AGENT.md) — project layout and contracts
- [`docs/adr/005`](../../docs/adr/005_platform-support-tiers-and-frame-pacing.md) — backends / present
