# Example 33: Camera (2D viewport / follow scroll)

2D camera / viewport demo in `kit.gfx`.

- World larger than the window (1280×720) with a checkerboard + landmark `usako.png`
- Arrow keys / WASD for manual pan (clamped to world bounds)
- **F** toggles target follow (fixed f32 lerp + clamp)
- Target / Camera update on a 60 Hz `FixedTimeStep`

## Run

```bash
# From the repository root
zig build run-example_33

# Standalone
cd examples/33_camera && zig build run
```

## Headless E2E (fixed CRC)

```bash
TMPD=$(mktemp -d)
KNGN_HEADLESS=1 \
  KNGN_HARNESS_SCRIPT=examples/33_camera/e2e.txt \
  KNGN_HARNESS_OUT=$TMPD \
  zig build run-example_33
```

Fixed CRC (640×360, fixed background / world / lerp / virtual clock):

| Scene | crc |
|--------|-----|
| Initial | `11D17951` |
| After manual pan | `47CA82D8` |
| Near boundary | `B81EB721` |
| After enabling follow (lerp in progress) | `EE378351` |
| After follow settles | `A775CEB8` |

Script: `e2e.txt`. CRC values were captured on aarch64-darwin; re-capture if another platform diverges.
See [`docs/harness.md`](../../docs/harness.md).

## Controls

- **Arrows / WASD**: manual pan
- **F**: toggle target follow
- **ESC / Q**: quit

## Dependencies

`@import("kit").gfx` (Camera / FixedTimeStep / drawSpriteEx / Sprite).
