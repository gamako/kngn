# 33: Camera（2D ビューポート / 追従スクロール）

`kit.gfx` の 2D カメラ / ビューポート デモ（TASK-111.4）。

- 画面より広いワールド（1280×720）に市松模様 + 目印 `usako.png`
- 矢印キー / WASD で手動 pan（ワールド境界 clamp）
- **F** でターゲット追従 ON/OFF（固定 f32 lerp + clamp）
- 60Hz `FixedTimeStep` で target / Camera を更新

## 実行

```bash
# リポジトリ root から
zig build run-example_33

# standalone
cd examples/33_camera && zig build run
```

## ヘッドレス E2E（CRC 固定）

```bash
TMPD=$(mktemp -d)
VP_HARNESS_HEADLESS=1 \
  VP_HARNESS_SCRIPT=examples/33_camera/e2e.txt \
  VP_HARNESS_OUT=$TMPD \
  zig build run-example_33
```

固定 CRC（640×360・固定背景 / world / lerp / 仮想クロック）:

| シーン | crc |
|--------|-----|
| 初期 | `11D17951` |
| 手動スクロール後 | `47CA82D8` |
| 境界付近 | `B81EB721` |
| 追従有効化後（lerp 進行） | `EE378351` |
| 追従安定後 | `A775CEB8` |

script 本体は `e2e.txt`（expect 焼き込み済み）。
CRC の正は本開発機（aarch64-darwin）での採取値。他 platform で divergence が出た場合は再採取。

## 操作

- **矢印 / WASD**: 手動 pan
- **F**: ターゲット追従の有効 / 無効
- **ESC / Q**: 終了

## 依存

`@import("kit").gfx`（Camera / FixedTimeStep / drawSpriteEx / Sprite）。
