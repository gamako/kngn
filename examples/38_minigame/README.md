# 38_minigame — 統合ミニゲーム capstone

TASK-111 ファミリー（`libs/gfx` / `libs/sound` / `kit.font`）の利用例を、外部消費者がコピーして開始できる最小限のミニゲームとして統合する。

ゲームロジックは本 example 内に閉じ込め、ECS・Scene・GameLoop などの新しい共通層は追加しない。

## 責務

| 単位 | 役割 |
|------|------|
| `Game` | プレイヤー AABB / 速度 / 接地 / facing / スコア / コイン状態 |
| `updateGame` | 固定 60Hz 論理更新（移動・重力・AABB・コイン・アニメ・カメラ） |
| `drawGame` | フレーム描画（背景・タイル・コイン・プレイヤー・HUD） |

## 操作

| キー | 動作 |
|------|------|
| A / D / ← / → | 水平移動（`ActionMap` 軸 `move_x`） |
| Space / Z | ジャンプ（接地時のみ） |
| Esc / Q | 終了 |

## 仕様値

- ウィンドウ 640×360、タイル 16×16、マップ 80×23（1280×368 world px）
- プレイヤー AABB 12×14、初期位置 `(64, 160)`、固定更新 60 Hz
- 水平速度 2.5 / 重力 0.35 / 最大落下 6.0 / ジャンプ -5.5（いずれも px / update）
- カメラ zoom=1、追従 alpha=0.2、マップ境界 clamp
- 歩行 Atlas 64×64×4、clip `[0,1,2,3,2,1]`、8 fps loop
- コイン 3 個（取得 +100）。床 `(320,328)`、第1足場 `(336,264)`、第2足場 `(600,200)`
  （コイン bottom = 足場 top、x は足場 world 範囲内）
- BGM 110 Hz ループ、ジャンプ SE 660 Hz、着地 SE 220 Hz（いずれもコード生成 PCM16 WAV）
- HUD: `kit.font.default_font_bytes` + `OutlineFont` で SCORE / FPS / 操作ヒント

## アセット

- プレイヤー画像は既存 `examples/image/usako.png` への symlink（`image/usako.png`）。**新規 PNG は追加しない**。
- Windows checkout では symlink がテキスト化される既知制約あり（`build_helpers` と同種）。ルート `zig build` は symlink を経由しないため動作する。standalone 単体ビルドが必要な場合は開発者モード + `core.symlinks=true` で再 checkout するか、ルートビルドを使う。

## 実行

ルートから:

```bash
zig build run-example_38 -Dplatform=objc
```

standalone:

```bash
cd examples/38_minigame && zig build run -Dplatform=objc
```

## E2E（headless replay）

```bash
TMPD=$(mktemp -d)
VP_HARNESS_HEADLESS=1 \
VP_HARNESS_SCRIPT=examples/38_minigame/e2e.txt \
VP_HARNESS_OUT=$TMPD \
zig build run-example_38 -Dplatform=objc
```

- `snapshot fb` は path 省略 → `$VP_HARNESS_OUT/frame_<n>.png`
- `expect fb crc=...` は macOS objc 実測値を焼き込み
- `game` probe で接地・ジャンプ・カメラ・スコアを assert

### CRC fresh 2 回一致

```bash
RUN1=$(mktemp -d); RUN2=$(mktemp -d)
VP_HARNESS_HEADLESS=1 VP_HARNESS_SCRIPT=examples/38_minigame/e2e.txt \
  VP_HARNESS_OUT=$RUN1 zig build run-example_38 -Dplatform=objc 2>&1 | tee $RUN1/replay.log
VP_HARNESS_HEADLESS=1 VP_HARNESS_SCRIPT=examples/38_minigame/e2e.txt \
  VP_HARNESS_OUT=$RUN2 zig build run-example_38 -Dplatform=objc 2>&1 | tee $RUN2/replay.log
diff <(rg '\[harness\] digest fb' $RUN1/replay.log) <(rg '\[harness\] digest fb' $RUN2/replay.log)
```

### snapshot 目視

```bash
find "$RUN1" -name 'frame_*.png' -print
# 各 PNG を開き、地形・プレイヤー・HUD・flip・見切れを確認
```

## `game` custom probe

digest は 1 行 `k=v`（改行なし、1024B 未満）:

```text
x=64.000 y=322.000 vy=0.000 grounded=1 state=grounded facing=right frame=0 cam_x=0.000 cam_y=4.000 score=0 fps=60 jump_count=0 landing_count=1 se_count=0 bgm=1
```

| キー | 意味 |
|------|------|
| `x` `y` `vy` | プレイヤー AABB / 垂直速度 |
| `grounded` | 接地 0/1 |
| `state` | `grounded` / `jumping` / `falling` |
| `facing` | `left` / `right` |
| `frame` | 現在の Atlas フレーム番号 |
| `cam_x` `cam_y` | カメラ位置 |
| `score` `fps` | スコア / 表示 FPS |
| `jump_count` `landing_count` `se_count` | ジャンプ・着地・SE 投入回数 |
| `bgm` | BGM 管理状態（常時 1） |
