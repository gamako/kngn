# 32: Sprite Anim（Atlas + AnimationPlayer）

`kit.gfx` のスプライトシート / アトラスとアニメーション再生制御のデモ（TASK-111.3）。

- 既存 `examples/image/usako.png` から 4 セルの歩行 Atlas をコード生成（bobbing offset + 向きマーカー）
- `AnimationClip` フレーム列 `[0,1,2,3,2,1]` / fps=8 / loop
- 60Hz `FixedTimeStep` で `AnimationPlayer.update`
- 左右往復。左向きは `flip_x = true`

## 実行

```bash
# リポジトリ root から
zig build run-example_32

# standalone
cd examples/32_sprite_anim && zig build run
```

## ヘッドレス E2E（CRC 固定）

```bash
TMPD=$(mktemp -d)
VP_HEADLESS=1 \
  VP_HARNESS_SCRIPT=examples/32_sprite_anim/e2e.txt \
  VP_HARNESS_OUT=$TMPD \
  zig build run-example_32
```

固定 CRC（640×360・固定背景 `0xFF203040`・仮想クロック・決定的 Atlas 生成）:

| step 累計 | crc |
|-----------|-----|
| 1 | `BA8FA900` |
| 60 | `0D5C6C01` |
| 120 | `D357AA75` |
| 180 | `6A31348B` |

script 本体は `e2e.txt`（expect 焼き込み済み）。

## 操作

- **ESC / Q**: 終了

## 依存

`@import("kit").gfx`（Atlas / AnimationClip / AnimationPlayer / FixedTimeStep / drawSpriteEx）。
