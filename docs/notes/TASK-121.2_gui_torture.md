# TASK-121.2 実行記録（GUI torture suite）

## 実行環境

| 項目 | 値 |
|---|---|
| 日時 | 2026-07-17 |
| OS | macOS (Darwin) |
| CPU | Apple M1 Max / arm64 |
| Zig | 0.16.0 |
| ビルドモード（bench） | ReleaseFast |
| ビルドモード（test/E2E） | Debug（既定）/ 負系は Debug 明示 |

## コマンドと結果

### 1. zig fmt

変更ファイルに適用済み。

### 2. test-gui / test-gui-leak

| step | exit | 本数 / 計測 |
|---|---:|---|
| `zig build test-gui --summary all` | 0 | **158/158 pass** |
| `zig build test-gui-leak --summary all` | 0 | **1/1 pass** |

state leak 実測:

```
state_entries_frame_1=100
state_entries_frame_300=30000
state_entries_final=30000
per_id_state.map.capacity=65536
live_bytes_before_deinit=4912166
peak_bytes=7304254
total_alloc_bytes=9827100
alloc_count=36
free_count=31
live_bytes_after_deinit=0
```

### 3. zig build test

- exit **0**
- **2351/2355 tests passed (4 skipped)**、221/221 steps

### 4. zig build -Dinstall-all=true

- exit **0**

### 5. headless E2E（全カテゴリ）

いずれも `VP_HARNESS_HEADLESS=1`、`VP_HARNESS_OUT=$(mktemp -d)`、exit **0**。

| script | env | exit |
|---|---|---:|
| `e2e_layout.txt` | `VP_GUI_TORTURE_CASE=layout` | 0 |
| `e2e_layout_100x100.txt` | `CASE=layout WIDTH=100 HEIGHT=100` | 0 |
| `e2e_text.txt` | `CASE=text` | 0 |
| `e2e_input_state.txt` | `CASE=input_state` | 0 |
| `e2e_ids_popup.txt` | `CASE=ids_popup` | 0 |
| `e2e_volume.txt` | `CASE=volume` | 0 |

### 6. 負系 shell runner

```bash
bash examples/37_gui_torture/negative_auto_id.sh
```

- exit **0**（runner 自体）
- 被試験プロセス exit **1**（Debug assert / panic 署名あり）→ PASS

### 7. bench-gui-frame

```
=== GUI full Context frame benchmark (ReleaseFast, 1024x768) ===
measure: beginFrame + widget build + endFrame + gui.render
gui.frame rows=500  viewport=1024x768 warmup=100 iters=1000  avg=482368 ns  min=471459 ns  p95=495833 ns
gui.frame rows=1000 viewport=1024x768 warmup=100 iters=1000  avg=619133 ns  min=601500 ns  p95=637833 ns
```

- exit **0**
- p95 = 昇順 950 番目（1-based）

### 8. standalone

```bash
cd examples/37_gui_torture && direnv exec <video-proto-main> zig build
```

- exit **0**
- note: `command_types` 共有のため `kit_libs` 経由で同一 module instance を供給（gallery 同様の二重 module 回避）

## 観測値メモ（代表）

- nested scroll wheel @ inner: `outer_scroll_y=96` かつ `inner_scroll_y=96`（同時変化）
- splitter0 min drag: `splitter0_size=36` / `pane0_w=36`
- 100x100: `overflow=1`、`draw_ok=1`、zero box `zero_w=0 zero_h=0`
- zero-size 親でも子 button rect は非ゼロになりうる（`zero_btn_w=24`）
- popup 右下 open: `popup_clamped=1`、`popup_fits_x/y=1`
- volume: 500 → PAGE_DOWN → 1000、`layout_completed=1` `render_completed=1`

## AC 対応

| AC | 充足箇所 |
|---|---|
| 1 クラッシュ・状態リーク・入力漏れ | e2e_layout / 100x100 / input_state / ids / volume / negative / leak test |
| 2 発見バグの個別起票 | 下記「起票候補リスト」（本タスクでは起票せず候補のみ） |
| 3 full Context frame bench | `bench/gui_frame.zig` + `bench-gui-frame` 上記数値 |
| 4 harness 自動判定 | `e2e_*.txt` expect + `negative_auto_id.sh` |
| 5 state leak | `tests/gui_leak.zig` + 上記 entry/allocator 実測 |

## 起票候補リスト（Missing / バグ）

1. **Nested ScrollArea wheel routing**  
   - 根拠: `libs/gui/src/widgets.zig` `beginScrollArea` が viewport 内なら `scroll_delta` を独立加算（~L1419–1427）。`e2e_layout.txt` で outer/inner が同時に 96 へ変化。  
   - 期待仕様候補: 内側優先で外側は動かない。

2. **PerIdStateStore に trim / TTL / 上限がない**  
   - 根拠: `libs/gui/src/state.zig` `PerIdStateStore` は `getOrPut` のみで削除 API なし。`tests/gui_leak.zig` で `state_entries_final=30000` 単調増加。

3. **TextBuffer / textInputId に最大 codepoint/byte 長 API がない**  
   - 根拠: `libs/gui/src/text_edit.zig` `TextBuffer`、`widgets.zig` `textInputId`。e2e_text で 500 codepoints を受け入れ現状観測。

4. **改行・CJK・emoji の measure / line break / glyph coverage が default font 依存**  
   - 根拠: default bitmap font の measure と coverage。text torture は描画完了のみ確認、仕様未定義。

5. **popup 長文 item が小画面で outer を超える表示・選択仕様の明文化**  
   - 根拠: `libs/gui/src/popup.zig` `layoutPopup` は screen 内に縮小するが item 行は outer 下端をはみ出しうる（doc comment L123–125）。

6. **zero-size / overflow container の hit-test・clip・child rect 仕様未定義**  
   - 根拠: layout で `zero_w=0 zero_h=0` でも子 button が 24x24 の rect を持つ（layout digest 実測）。`context.zig` 同期 rect cache 契約。

7. **drag 中 layout 変更時の active widget rect cache 同期遅延**  
   - 根拠: `context.zig` 冒頭「前フレーム rect = 同期 hit-test」契約。e2e_input_state で F1 レイアウト切替中も `active=slider` 維持を現行観測として固定。仕様化が必要。

8. **自動 ID 同一ラベル衝突は現行契約（修正候補ではない）**  
   - 根拠: `context.zig` `updateRectCache` の `std.debug.assert(!gop.found_existing)`（~L391）。`negative_auto_id.sh` で Debug 非ゼロを確認。ドキュメント化候補。

## 逸脱

- **逸脱なし**（プラン準拠。standalone は `kit_libs` で command_types を共有する実装詳細を採用。gallery の build.zig と同型の二重 module 問題を回避するための additive 配線であり、libs/gui 非改変・example 番号 37 を維持）。
