# 36_tilemap — TileMap 描画 + solid 衝突

`kit.gfx.TileMap` で固定地形を描画し、AABB 押し戻しで左右移動・重力・着地をデモする（TASK-111.5）。

## 操作

| キー | 動作 |
|------|------|
| ← / A | 左移動 |
| → / D | 右移動 |
| ↑ / W / Space / Z | ジャンプ（接地時） |
| Esc / Q | 終了 |

## 実行

ルートから:

```bash
zig build run-example_36
```

standalone:

```bash
cd examples/36_tilemap && zig build run
```

## E2E（headless replay）

```bash
TMPD=$(mktemp -d)
VP_HEADLESS=1 \
VP_HARNESS_SCRIPT=examples/36_tilemap/e2e.txt \
VP_HARNESS_OUT=$TMPD \
zig build run-example_36
```

- snapshot path は省略 → `$VP_HARNESS_OUT/frame_<n>.png`
- 各 `digest fb` の直後に `expect fb crc=...`（実測値を焼き込み）
- CRC が green であること、`open $TMPD/frame_*.png` で地形とキャラクターを目視確認

### CRC 再採取

```bash
TMPD=$(mktemp -d)
MEASURE=$TMPD/measure.txt
sed '/^expect fb crc=/d' examples/36_tilemap/e2e.txt > "$MEASURE"
VP_HEADLESS=1 VP_HARNESS_SCRIPT="$MEASURE" VP_HARNESS_OUT="$TMPD" \
  zig build run-example_36 2>&1 | tee "$TMPD/replay.log"
rg 'crc=' "$TMPD/replay.log"
```
