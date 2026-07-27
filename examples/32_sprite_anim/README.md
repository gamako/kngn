# Example 32: Sprite Anim (Atlas + AnimationPlayer)

Demo of sprite-sheet / atlas playback in `kit.gfx`.

- Builds a 4-cell walk Atlas from `examples/image/usako.png` in code (bobbing offset + facing marker)
- `AnimationClip` frames `[0,1,2,3,2,1]` / fps=8 / loop
- `AnimationPlayer.update` on a 60 Hz `FixedTimeStep`
- Walks left/right; left facing uses `flip_x = true`

## Run

```bash
# From the repository root
zig build run-example_32

# Standalone
cd examples/32_sprite_anim && zig build run
```

## Headless E2E (fixed CRC)

```bash
TMPD=$(mktemp -d)
VP_HEADLESS=1 \
  VP_HARNESS_SCRIPT=examples/32_sprite_anim/e2e.txt \
  VP_HARNESS_OUT=$TMPD \
  zig build run-example_32
```

Fixed CRC (640×360, background `0xFF203040`, virtual clock, deterministic Atlas):

| Cumulative step | crc |
|-----------|-----|
| 1 | `BA8FA900` |
| 60 | `0D5C6C01` |
| 120 | `D357AA75` |
| 180 | `6A31348B` |

Script: `e2e.txt` (expects baked in). See [`docs/harness.md`](../../docs/harness.md).

## Controls

- **ESC / Q**: quit

## Dependencies

`@import("kit").gfx` (Atlas / AnimationClip / AnimationPlayer / FixedTimeStep / drawSpriteEx).
