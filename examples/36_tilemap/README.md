# Example 36: TileMap draw + solid collision

Draws fixed terrain with `kit.gfx.TileMap` and demos left/right move, gravity, and landing via
AABB push-out.

## Controls

| Key | Action |
|------|------|
| ← / A | Move left |
| → / D | Move right |
| ↑ / W / Space / Z | Jump (when grounded) |
| Esc / Q | Quit |

## Run

From the repository root:

```bash
zig build run-example_36
```

Standalone:

```bash
cd examples/36_tilemap && zig build run
```

## E2E (headless replay)

```bash
TMPD=$(mktemp -d)
KNGN_HEADLESS=1 \
KNGN_HARNESS_SCRIPT=examples/36_tilemap/e2e.txt \
KNGN_HARNESS_OUT=$TMPD \
zig build run-example_36
```

- Snapshot path omitted → `$KNGN_HARNESS_OUT/frame_<n>.png`
- Each `digest fb` is followed by `expect fb crc=...` (measured values baked in)
- Confirm CRC is green and open `$TMPD/frame_*.png` to inspect terrain and character

See [`docs/harness.md`](../../docs/harness.md).

### Re-capture CRC

```bash
TMPD=$(mktemp -d)
MEASURE=$TMPD/measure.txt
sed '/^expect fb crc=/d' examples/36_tilemap/e2e.txt > "$MEASURE"
KNGN_HEADLESS=1 KNGN_HARNESS_SCRIPT="$MEASURE" KNGN_HARNESS_OUT="$TMPD" \
  zig build run-example_36 2>&1 | tee "$TMPD/replay.log"
rg 'crc=' "$TMPD/replay.log"
```
