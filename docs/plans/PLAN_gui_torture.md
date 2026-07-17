# PLAN: GUI layout torture suite (TASK-121.2)

## 目的

`examples/35_gui_gallery` が正常系カタログであるのに対し、本スイートは `libs/gui` の異常系・境界条件（ネスト、zero-size、overflow、状態残留、ID 独立性、量）を harness で自動回帰する。

**libs/gui 本体は変更しない**（公開 API / pub 状態のみ観測）。

## ホットパス宣言

- `examples/37_gui_torture/main.zig`: widget 構築はフレーム毎 O(N)。全画素ループ・RT 経路は追加しない。
- `bench/gui_frame.zig`: bench 実行時のみ（warmup 100 × 測定 1000）。
- `tests/gui_leak.zig`: 300 フレーム計測専用。常設経路に影響しない。

## 構成

| パス | 役割 |
|---|---|
| `examples/37_gui_torture/main.zig` | ケース切替 + custom probe `state`/`layout`/`scroll` |
| `examples/37_gui_torture/e2e_*.txt` | headless replay 通常系 |
| `examples/37_gui_torture/negative_auto_id.{txt,sh}` | Debug assert 負系（期待非ゼロ終了） |
| `bench/gui_frame.zig` | full Context frame bench（`bench-gui-frame`） |
| `tests/gui_leak.zig` | PerIdStateStore leak 計測（`test-gui-leak`） |

## ケース選択

- env: `VP_GUI_TORTURE_CASE=layout|text|input_state|ids_popup|volume|negative_auto_id`
- または PAGE_DOWN / PAGE_UP（volume 中は 500/1000 行トグル）
- 画面サイズ: `VP_GUI_WIDTH` / `VP_GUI_HEIGHT`（未設定 1024x768、0/parse 失敗は warn+既定、4096 clamp）
- volume 行数: `VP_GUI_TORTURE_ROWS=500|1000`（省略時 500）

## Probe 契約（DIGEST_BUF_LEN=1024、top-level k=v）

- **state**: `case` / `active` / `hot` / `active_is_zero` / `dragging` / `focused_id` / `wants_mouse` / `popup_open` / `popup_dismissed` / `layout_generation` + ケース別（text metrics, behind_clicks, button_count, row_count 等）
- **layout**: `case` / `screen_w` / `screen_h` / `overflow` / `draw_ok` / `layout_completed` / `render_completed` + ケース別 rect（pane*/slider/text_input/popup_* 等）
- **scroll**: `outer_scroll_y` / `inner_scroll_y` / viewport rects

キー名は実装後の実 digest に合わせた現行観測値。期待仕様ではなく **初回 headless replay の実測を script に焼き込む**。

## 実行

```bash
# 通常系 E2E（例: layout）
VP_HARNESS_HEADLESS=1 \
VP_GUI_TORTURE_CASE=layout \
VP_HARNESS_SCRIPT=examples/37_gui_torture/e2e_layout.txt \
VP_HARNESS_OUT=$(mktemp -d) \
zig build run-example_37

# 100x100 は別プロセス
VP_GUI_WIDTH=100 VP_GUI_HEIGHT=100 VP_GUI_TORTURE_CASE=layout \
VP_HARNESS_HEADLESS=1 VP_HARNESS_SCRIPT=examples/37_gui_torture/e2e_layout_100x100.txt \
VP_HARNESS_OUT=$(mktemp -d) zig build run-example_37

# 負系
bash examples/37_gui_torture/negative_auto_id.sh

# bench / leak
zig build bench-gui-frame   # ReleaseFast 固定
zig build test-gui-leak

# standalone
cd examples/37_gui_torture && zig build
```

## 期待値固定ルール

1. まず `digest` のみで実測を取る。
2. 数値・矩形・scroll は実測を `expect` に書く（創作禁止）。
3. 仕様との差分は Missing / 起票候補（notes）へ。

## 関連

- 正常系マトリクス: `docs/plans/PLAN_gui_capability_matrix.md`
- 実行記録・起票候補: `docs/notes/TASK-121.2_gui_torture.md`
