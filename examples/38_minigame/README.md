# Example 38: Integrated minigame capstone

A minimal minigame that external consumers can copy as a starting point, combining `libs/gfx`,
`libs/sound`, and `kit.font`.

Game logic stays inside this example; no new shared ECS / Scene / GameLoop layer is added.

## Responsibilities

| Unit | Role |
|------|------|
| `Game` | Player AABB / velocity / grounded / facing / score / coins |
| `updateGame` | Fixed 60 Hz logic (move / gravity / AABB / coins / anim / camera) |
| `drawGame` | Frame draw (background / tiles / coins / player / HUD) |

## Controls

| Key | Action |
|------|------|
| A / D / ← / → | Horizontal move (`ActionMap` axis `move_x`) |
| Space / Z | Jump (grounded only) |
| Esc / Q | Quit |

## Spec values

- Window 640×360, tiles 16×16, map 80×23 (1280×368 world px)
- Player AABB 12×14, start `(64, 160)`, fixed update 60 Hz
- Horizontal speed 2.5 / gravity 0.35 / max fall 6.0 / jump −8.0 (px per update)
- Camera zoom=1, follow alpha=0.2, clamped to map bounds
- Walk Atlas 64×64×4, clip `[0,1,2,3,2,1]`, 8 fps loop
- Floating platforms ascend left→right like stairs: P1 `top=272` (world 256..416) / P2 `top=208`
  (448..592) / P3 `top=144` (640..784). Horizontal gaps ≈2–3 tiles (no direct vertical stack) so
  arc jumps climb one step at a time
- Three coins (+100 each): floor `(220,328)`, on P1 `(330,264)`, on P3 (summit) `(700,136)`
  (coin bottom = platform top; x inside platform world range)
- BGM 110 Hz loop, jump SE 660 Hz, land SE 220 Hz (code-generated PCM16 WAV)
- HUD: `kit.font.default_font_bytes` + `OutlineFont` for SCORE / FPS / control hints

## Assets

- Player art is a symlink to existing `examples/image/usako.png` (`image/usako.png`). **Do not add
  a new PNG.**
- On Windows checkouts, symlinks may materialise as text files (same class of issue as
  `build_helpers`). The root `zig build` does not rely on the symlink, so it works. For a
  standalone-only build, re-checkout with developer mode + `core.symlinks=true`, or use the root
  build.

## Run

From the repository root:

```bash
zig build run-example_38 -Dplatform=objc
```

Standalone:

```bash
cd examples/38_minigame && zig build run -Dplatform=objc
```

## E2E (headless replay)

```bash
TMPD=$(mktemp -d)
KNGN_HEADLESS=1 \
KNGN_HARNESS_SCRIPT=examples/38_minigame/e2e.txt \
KNGN_HARNESS_OUT=$TMPD \
zig build run-example_38 -Dplatform=objc
```

- `snapshot fb` path omitted → `$KNGN_HARNESS_OUT/frame_<n>.png`
- `expect fb crc=...` baked from macOS objc measurements
- `game` probe asserts grounded / jump / camera / score

See [`docs/harness.md`](../../docs/harness.md).

### CRC freshness (two runs must match)

```bash
RUN1=$(mktemp -d); RUN2=$(mktemp -d)
KNGN_HEADLESS=1 KNGN_HARNESS_SCRIPT=examples/38_minigame/e2e.txt \
  KNGN_HARNESS_OUT=$RUN1 zig build run-example_38 -Dplatform=objc 2>&1 | tee $RUN1/replay.log
KNGN_HEADLESS=1 KNGN_HARNESS_SCRIPT=examples/38_minigame/e2e.txt \
  KNGN_HARNESS_OUT=$RUN2 zig build run-example_38 -Dplatform=objc 2>&1 | tee $RUN2/replay.log
diff <(rg '\[harness\] digest fb' $RUN1/replay.log) <(rg '\[harness\] digest fb' $RUN2/replay.log)
```

### Snapshot visual check

```bash
find "$RUN1" -name 'frame_*.png' -print
# Open each PNG; confirm terrain, player, HUD, flip, no clipping
```

## `game` custom probe

Digest is one `k=v` line (no newlines, under 1024 B):

```text
x=64.000 y=322.000 vy=0.000 grounded=1 state=grounded facing=right frame=0 cam_x=0.000 cam_y=4.000 score=0 fps=60 jump_count=0 landing_count=1 se_count=0 bgm=1
```

| Key | Meaning |
|------|------|
| `x` `y` `vy` | Player AABB / vertical velocity |
| `grounded` | Grounded 0/1 |
| `state` | `grounded` / `jumping` / `falling` |
| `facing` | `left` / `right` |
| `frame` | Current Atlas frame index |
| `cam_x` `cam_y` | Camera position |
| `score` `fps` | Score / displayed FPS |
| `jump_count` `landing_count` `se_count` | Jump / land / SE play counts |
| `bgm` | BGM management flag (always 1) |
