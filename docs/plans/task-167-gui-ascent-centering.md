# TASK-167: GUI テキストの ascent/descent 基準縦中央揃え

## 目的

TASK-138 で `pixie` / `synth` / `patch` の `gui.Context.font` に system `OutlineFont` を注入した結果、レイヤー名 rename 欄や通常ラベルの日本語が行内で上寄りに見える問題を解消する。bitmap default font と outline font のどちらでも、GUI のテキスト行をフォントの論理的な `ascent + descent` の高さで縦中央に配置する。

コード変更はこの計画には含めない。実装時に触る対象・検証方法だけを確定する。

## 調査結果

### 縦メトリクスと描画契約

- `libs/font/src/font.zig:20-28` の `Metrics` は `line_height`、`ascent`、`descent` を持ち、`ascent` は baseline より上、`descent` は baseline より下の正値という契約である。`Font.VTable.metrics` と `Font.metrics()`（同:46-66）が共通取得口になっている。
- `libs/font/src/outline_font.zig:502-507` の `OutlineFont.metrics()` は、サイズ束縛済み `OutlineFont` の pixel metrics を返す。`drawGlyphs`（同:556-560）は `baseline_y = pos.y + m.ascent` として描画するため、`pos.y` は line box 上端である。
- `libs/gui/src/font.zig:20-55` の `BitmapFont` も `metrics()` を vtable に実装し、既定値は ascent=12、descent=4、line_height=16 である。bitmap の `drawTo`（同:64-75）は `pos.y` をセル上端として描くため、`ascent+descent == glyph_h` の既存 bitmap 出力は変更しない。
- `libs/font/src/bmfont.zig:42-50,150-171` の `BMFont` は descriptor の `base` を ascent、`line_height-base` を descent として `Metrics` を返す。
- `FontFace` はサイズ非依存の供給源で、GUI が保持する描画可能な `Font` ではない。`FontFace` に ascent/descent を追加する必要はない。pixel size に束縛された `OutlineFont.metrics()` を使うのが正しい。
- `sfnt.SfntFile.pixelMetrics()`（`libs/font/src/sfnt.zig:156-174`）は outline の ascent/descent と line gap を pixel 化し、`line_height >= ascent+descent` を保証する。

したがって共通 interface の追加は不要である。取得不能な既存フォント実装は確認できない。将来 FontFace 単体のメトリクスが必要になった場合だけ、px 引数付きの `FontFace.metricsAt(px)` 等を検討するが、本タスクの GUI 経路には追加しない。

### TASK-118 の先例

`libs/gui/src/widgets.zig:643-649` の `textInputId` が既に `max(0, metrics.ascent + metrics.descent)` を `ink_height` とし、box 高さを padding + ink height にしている。`TextInputDraw.draw`（同:774-830）は本文、placeholder、preedit、selection、caret、underline の y 基準を共有している。`TASK-118` の単体テスト（同:3836-3934）は line gap を持つ outline 相当フォントで高さ・描画 y・caret・underline を固定している。

通常 GUI はまだ `line_height` を使っている。

- `libs/gui/src/layout.zig:163-170` の text leaf 測定
- `libs/gui/src/widgets.zig:407-423` の `selectableLabel`
- `libs/gui/src/popup.zig:269-286,299-318` の popup/tooltip の手動配置
- `libs/gui/src/font.zig:23-25` の「GUI は line_height のみ使用」という記述

これが outline の line gap を含む line box と実際の ascent/descent のずれを引き起こす。

## 採用方針

### 1. GUI 内の共通高さ・中央位置を一元化する

`libs/gui/src/font.zig` に、`Font.metrics()` から安全に `max(0, ascent + descent)` を得る内部共通 helper を追加する。必要なら低レベル `DrawList` 利用者向けに「指定 row の text y を中央化する」helperも同じ場所から公開する。計算は整数だけで行い、既存の `Font.metrics()` 呼び出し以外の取得・allocation・cache は増やさない。

この helper の意味は「ink の実測 bbox」ではなく、Font 契約の論理 ascent/descent box とする。`line_height` の line gap は row の余白として親の `align_cross` に任せる。bitmap default font では高さが従来の 16px と一致するため、bitmap の座標と決定論は維持される。

### 2. 通常レイアウトを ascent+descent に切り替える

`libs/gui/src/layout.zig` の text leaf の `measured_h` を `line_height` から共通 helper の高さへ変更する。これにより、`align_cross = .center` の flex 配置は論理 glyph box 自体を row の中央へ置く。

`Context.label/labelEx` は `layout` の text leaf 経由なので、通常の label、button 内ラベル、menu bar の button、PanelHost のタイトル/ラベル、pixie のレイヤー行・履歴行・timeline 行へ自動的に波及する。button の `.fit` 高さも text leaf の高さ + padding になるため、outline の line gap を二重に含めない。

`libs/gui/src/widgets.zig` の `selectableLabel` も box/custom leaf の高さを同じ helper にそろえ、selection background の高さと text の line box を一致させる。`TextInput` は TASK-118 と同じ値を使うよう helper 呼び出しへ寄せるだけで、既存の `text_y`、caret、selection、preedit underline の仕様は変えない。

### 3. layout 外の popup/tooltip も同じ基準にする

`libs/gui/src/popup.zig` は `style.popup_item_h` を menu item の行高（hit-test と外枠計算）として維持し、text の高さだけを ascent+descent にする。`text_y = item top + (item_h - text_height) / 2` とし、現在の `line_height` 直接使用をなくす。tooltip も同じ行高・中央化規則に統一する。これにより popup のサイズ・クリック領域を不要に変えず、outline の line gap だけが中央化に反映される。

### 4. 低レベル DrawList 経路は自動補正しない

`DrawList.textEx` は row の矩形を持たず、渡された `pos` をそのまま Font に渡す API なので、`gui.render` で一律に y を変更してはならない。低レベル経路は次のように扱う。

- `apps/editor/apps/pixie/main.zig:324-340` の inline composition は custom leaf の `rect` を持つため、本文/preedit の y と underline/caret の高さを同じ metric helper へ寄せる対象候補とする。
- `apps/patch/main.zig:1195-1420` の node title、palette label、toggle、expanded group header は OutlineFont を使う `gui.DrawList.text` の手動 row であり、通常 layout の変更だけでは位置が変わらない。snapshot で上寄りが残る場合に備え、各既存 row 矩形から metric-aware な text y を計算する変更を TASK-167 の実装範囲に含める。
- `apps/synth/main.zig:175-207` と `apps/patch/main.zig:2545-2585` の `gui.default_bitmap_font.drawTo` は明示的に bitmap font を選ぶ可視化帯ラベルで、system OutlineFont 注入経路ではない。ここは bitmap の既存座標を保ち、GUI Context 経路と混同しない。
- pixie の appshell confirmation など固定座標の overlay text も `DrawList` 直書きであるため、TASK-167 の対象 row かどうかを目視確認する。通常 widget の修正で自動的に直るとは仮定しない。

## 影響範囲

| 経路 | 実コード | 影響 |
|---|---|---|
| 通常 label | `libs/gui/src/context.zig:459-467` → `layout.zig:163-170` | 高さと親 row 内の y が ascent+descent 基準になる |
| button / menu bar | `libs/gui/src/widgets.zig:buttonId`、`libs/gui/src/menu.zig:menuBar` | button 内 label、menu title の中央位置。bitmap の高さは不変 |
| selectable label | `libs/gui/src/widgets.zig:320-448` | box、選択背景、文字の高さを統一 |
| TextInput / rename | `widgets.zig:451-830`、pixie `main.zig:5577-5603` | TASK-118 の先例を共通化。レイヤー名 rename と text layer inline input を含む |
| pixie レイヤー/履歴/timeline | `apps/editor/apps/pixie/main.zig:5499-5910` | `labelEx`/`buttonId` の標準経路は自動波及。手動 overlay は別監査 |
| synth GUI | `apps/synth/main.zig:429-490` | Context の label/button/slider の表示へ波及。spectrogram の bitmap 直描きは対象外 |
| patch GUI | `apps/patch/main.zig:5045-5125`、`gui_ctx` の PanelHost 構築 | panel の label/button は自動波及。canvas/node の直描き text は別途 metric-aware 化を判断 |
| popup/tooltip | `libs/gui/src/popup.zig:213-318` | 表示 y のみ変更。item hit-test/outer geometry の契約を維持 |
| その他 widget | `collapsible`、slider、checkbox、radio、color picker 等 | text を `Context.label`/button 経由で持つものは波及。icon/custom pixel 描画は対象外 |

状態機械だけの `apps/editor/apps/pixie/layer_rename_input.zig` / `text_content_input.zig` は縦配置を持たないため、コード変更対象ではない。

## テスト計画

1. `libs/gui/src/font.zig` の helper に、既定 bitmap (`12+4=16`) と line gap を持つ custom metrics の決定論テストを追加する。
2. `libs/gui/src/layout.zig` に `line_height=24, ascent=14, descent=4` の vtable font を使う測定・配置テストを追加する。text leaf の高さが 18 になり、固定高さ parent の `align_cross=.center` で text rect が期待 y になることを DrawCmd/rect で確認する。
3. `libs/gui/src/widgets.zig` の `selectableLabel` / button 相当テストで、同じ custom font の measured height、selection rect、text command y を確認する。既存 `TASK-118` テストは helper 利用後も高さ 26、本文/selection/caret/underline の共有 y が変わらないことを確認する。
4. `libs/gui/src/popup.zig` に custom font の text command y テストを追加する。既定 `popup_item_h=20` と ink height 18 なら item top + 1 になること、itemRect/hitTest の結果と popup 外枠高さは変わらないことを確認する。
5. 既存の bitmap pixel 検査（`widgets.zig` の collapsible glyph テスト等）と command 数・clip・ID/hit-test テストをそのまま実行し、default font の `line_height=16` と `ascent+descent=16` による bit/座標不変を確認する。
6. `libs/gui` には snapshot/golden PNG 比較テストは存在しないことを確認済み。決定論の担保は上記の固定値・DrawCmd・ピクセル検査で行い、CI に脆い golden CRC は追加しない。

## 実機相当の snapshot 検証

ヘッドレス harness を使い、各アプリについて修正前後で `snapshot fb` を撮って Read で目視する。example_28 は既存の `VP_EXAMPLE_28_FONT=bitmap|outline` を使い、同じ入力状態で両方を比較する。pixie はレイヤー rename を開始して日本語を入力した状態、synth は GUI control/label 表示、patch は panel と node/palette label が見える状態を代表シナリオにする。fb は CPU framebuffer probe なので backend に依存しない。

確認項目は、(a) label/button/レイヤー名/rename の論理 text box が row の中央、(b) bitmap と outline で同じ row 中心、(c) selection/caret/underline が TextInput 本文と同じ y、(d) popup/tooltip の hit-test と clipping が不変、(e) patch/pixie の低レベル直描きに上寄りが残っていない、である。

## ホットパス宣言と性能確認

**ホットパス宣言:** 通常の text leaf の高さ計算・flex 配置・DrawCmd 発行はフレーム毎の UI 描画（テキスト node 数に比例）で、Font の glyph raster/blit は既存どおりフレーム毎のテキスト描画ホットパス。popup/tooltip の追加計算は popup 表示時（イベント/UI 更新時）のみ。RT（毎サンプル）経路には入らない。

変更は metrics の読み出しと定数個の整数加算/除算だけで、per-pixel 除算・新規関数呼び出しを glyph 内側へ追加しない。新規の全画素ループ、allocation、lock、atomic、SIMD 対象処理はないため SIMD 3点セットや cache-line 分離は不要。ただしフレーム毎のレイアウト経路を触るため、実装時に `zig build bench-gui-frame` を変更前後で実行し、500/1000 行の結果と顕著な退行の有無を TASK-167 notes に記録する。

## 実装順序

1. `libs/gui/src/font.zig` の共通 metric helper とコメントを追加し、`libs/gui/src/gui.zig` から必要な公開 helper を再 export する。
2. `libs/gui/src/layout.zig` の text leaf、`libs/gui/src/widgets.zig` の selectableLabel/TextInput を helper 基準へ変更する。
3. `libs/gui/src/popup.zig` の popup/tooltip text y を helper 基準へ変更し、単体テストを追加する。
4. patch/pixie の low-level DrawList text を snapshot と照合し、必要な row だけ metric-aware y へ変更する。synth/patch の明示 bitmap 可視化ラベルは既存座標を維持する。
5. `zig build test-gui`、必要に応じて `zig build test-font`、`zig build bench-gui-frame` を実行する。
6. `example_28` の bitmap/outline、pixie、synth、patch の harness snapshot を Read で目視し、AC #1〜#3 と変更ファイル/検証結果を TASK-167 notes に記録する。

## 未確定事項・判断基準

- `FontFace` 単体への metrics API 追加は不要。GUI に渡るのは常に sized `Font` であり、`Font.metrics()` で取得できる。
- `line_height` を widget の自然高さから完全に外すことで、line gap を含めた余白は親 row/padding 側へ移る。既存 UI の外枠高さを意図的に維持すべき popup だけは `style.popup_item_h` を維持する。
- `DrawList.textEx` に row 情報がないため、低レベル直描きは render 層で一律補正しない。snapshot で実際に AC の対象表示に該当するものだけ、呼び出し側で row 矩形と metrics を明示して補正する。
