# 34 — ActionMap（keyboard + gamepad）

`kit.gfx.ActionMap` のデモ。複数入力ソースを同一アクションへ写像し、実行時リバインドを確認する。

## 操作

| アクション | keyboard (WASD モード) | keyboard (矢印モード) | gamepad |
|---|---|---|---|
| `move_x` | A / D | ← / → | 左スティック X |
| `move_y` | W / S | ↑ / ↓ | 左スティック Y |
| `jump` | SPACE | SPACE | A |
| `attack` | Left Ctrl | Left Ctrl | B |
| リバインド | R | R | — |

- **R**: WASD 版と矢印版の key pair を切替（gamepad stick は常に有効）
- スティックとキーの同時入力は **スティック優先**（ActionMap の評価規則）
- スティック deadzone = 0.15（`gamepad.applyDeadzone` の radial semantics）

## ビルド / 実行

トップレベルから:

```bash
zig build run-example_34
```

standalone:

```bash
cd examples/34_action_map
zig build
zig build run
```

## harness E2E

```bash
TMPD=$(mktemp -d)
VP_HARNESS_HEADLESS=1 \
VP_HARNESS_SCRIPT=examples/34_action_map/e2e.txt \
VP_HARNESS_OUT=$TMPD \
zig build run-example_34
```

`digest action_map` で `binding` / `move_source` / `move_x` / `move_y` / `jump_*` / `attack_*` を観測できる。
`snapshot fb` は path 省略（`$VP_HARNESS_OUT/frame_<n>.png`）。
