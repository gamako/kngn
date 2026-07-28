# Example 34: ActionMap (keyboard + gamepad)

Demo of `kit.gfx.ActionMap`: several input sources map onto the same actions, with a runtime
rebind.

## Controls

| Action | Keyboard (WASD mode) | Keyboard (arrows mode) | Gamepad |
|---|---|---|---|
| `move_x` | A / D | ← / → | Left stick X |
| `move_y` | W / S | ↑ / ↓ | Left stick Y |
| `jump` | SPACE | SPACE | A |
| `attack` | Left Ctrl | Left Ctrl | B |
| Rebind | R | R | — |

- **R**: switch WASD vs arrow key pairs (gamepad stick stays bound)
- Stick + keys together: **stick wins** (ActionMap evaluation rule)
- Stick deadzone = 0.15 (`gamepad.applyDeadzone` radial semantics)

## Build / run

From the repository root:

```bash
zig build run-example_34
```

Standalone:

```bash
cd examples/34_action_map
zig build
zig build run
```

## Harness E2E

```bash
TMPD=$(mktemp -d)
KNGN_HEADLESS=1 \
KNGN_HARNESS_SCRIPT=examples/34_action_map/e2e.txt \
KNGN_HARNESS_OUT=$TMPD \
zig build run-example_34
```

`digest action_map` observes `binding` / `move_source` / `move_x` / `move_y` / `jump_*` /
`attack_*`. `snapshot fb` may omit the path (`$KNGN_HARNESS_OUT/frame_<n>.png`).
See [`docs/harness.md`](../../docs/harness.md).
