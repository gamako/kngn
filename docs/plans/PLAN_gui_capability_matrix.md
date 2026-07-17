# GUI capability matrix v0

## 1. 目的・スコープ

この文書は、WAI-ARIA APG、Dear ImGui demo、libs/gui の現有 API を同じ表に置く能力マトリクス v0 である。examples/35_gui_gallery は現有 widget の normal / endpoint 表示と、未対応 widget の空セクションを提供する。異常系・境界系は TASK-121.2、実画面 shell は TASK-121.3 / 121.4 のスコープとする。

状態軸は次の 9 列で固定する。

normal / hover / active / focused / disabled / empty / min / max / none

N/A は非適用を意味する明示セルであり、空欄にはしない。demo は代表 widget の実状態を入力注入するセル、partial は API の一部状態だけを表す。

### ホットパス宣言

ギャラリの widget 構築と DrawList 追加はフレーム毎に走る。表示項目数に対する O(N) で、全画素ループ・framebuffer 全面コピー・独自 rasterizer・RT thread は追加しない。svSquare / hueBar / stepgrid の描画は libs/gui に委譲するため、新しい全画素経路はない。状態 metadata・画像・Command/PopupItem は固定配列、widget の一時データは既存 Context frame arena を使う。

## 2. 参照元

本マトリクスの参照元一覧は、オーケストレータが 2026-07-17 に WebFetch で取得した一次資料に基づく。

| 資料 | URL | 対象版・取得日 |
|---|---|---|
| WAI-ARIA APG Patterns | https://www.w3.org/WAI/ARIA/apg/patterns/ | living document、版表記なし、2026-07-17 |
| Dear ImGui | https://github.com/ocornut/imgui | v1.92.6、2026-07-17 |
| video-proto libs/gui | libs/gui/src/widgets.zig / popup.zig / menu.zig / stepgrid.zig | workspace 実物、2026-07-17 |

## 3. APG 30 パターン一覧

Accordion、Alert、Alert and Message Dialogs、Breadcrumb、Button、Carousel、Checkbox、Combobox、Dialog (Modal)、Disclosure、Feed、Grid、Landmarks、Link、Listbox、Menu and Menubar、Menu Button、Meter、Radio Group、Slider、Slider (Multi-Thumb)、Spinbutton、Switch、Table、Tabs、Toolbar、Tooltip、Tree View、Treegrid、Window Splitter。

## 4. ImGui demo セクション一覧

Basic、Trees、Collapsing Headers、Text、Images、Combo、List boxes、Selectables、Text Input、Tabs、Plotting、Color/Picker widgets、Drag/Slider widgets、Range widgets、Multi-component widgets、Vertical sliders、Drag and Drop、Querying item status、Layout & Scrolling、Popups & Modal windows、Tables、Menus。

## 5. APG × ImGui × libs/gui

| APG | ImGui | 現有 API / ギャラリ分類 | 引き継ぎ先 |
|---|---|---|---|
| Accordion / Disclosure | Collapsing Headers | 未対応・空セクション | 121.3 |
| Alert | Querying / message UI | 正常系対象外・参照のみ | 121.2 |
| Alert and Message Dialogs | Popups & Modal windows | 未対応 | 121.2 / 121.3 |
| Breadcrumb / Landmarks | Layout | semantic shell 層で未対応 | 121.3 |
| Button | Basic / Selectables | button / buttonEx / buttonId | 121.3 / 121.4 |
| Carousel / Feed | — | 未対応 | Phase 2 |
| Checkbox | Basic | checkbox / checkboxId | 121.3 / 121.4 |
| Combobox / Menu Button | Combo / Menus | 組み合わせのみ、専用 API なし | 121.3 / 121.4 |
| Dialog (Modal) | Popups & Modal windows | popup のモーダル吸収とは別物 | 121.3 |
| Grid | Tables / Selectables | stepgrid は APG Grid の代替ではない | 121.4 / Phase 2 |
| Link | Basic | 専用 API なし。button 代用は禁止 | 121.3 |
| Listbox | List boxes | 未対応 | 121.4 |
| Menu and Menubar | Menus | menuBar / menuBarPopup / popup | 121.4 |
| Meter | Plotting / Range | 未対応 | 121.3 |
| Radio Group | Selectables | radio、排他状態は caller 管理 | 121.3 / 121.4 |
| Slider / Spinbutton | Drag/Slider widgets | sliderI32 / sliderF32、Spinbutton 未対応 | 121.3 |
| Slider (Multi-Thumb) | Range widgets | 未対応 | Phase 2 |
| Switch | Basic | toggle | 121.3 |
| Table | Tables | 列付き table は未対応 | 121.4 |
| Tabs | Tabs | 未対応 | 121.3 |
| Toolbar | Basic / Layout | row + button、専用 API なし | 121.3 / 121.4 |
| Tooltip | — | 未対応 | 121.3 / Phase 2 |
| Tree View / Treegrid | Trees / Tables | 未対応 | 121.4 / Phase 2 |
| Window Splitter | Layout & Scrolling | splitter | 121.3 |

## 6. libs/gui 現有 API 一覧

| 分類 | 実物 API |
|---|---|
| Basic | Context.buttonId、Context.label |
| Text | gui.selectableLabelId、Context.textInputId |
| Values | Context.sliderI32Id、Context.sliderF32Id、Context.checkboxId、Context.toggleId、Context.radioId |
| Color / Image | Context.colorSwatchId、Context.svSquareId、Context.hueBarId、Context.imageBox |
| Layout | gui.splitter、Context.beginScrollArea/endScrollArea |
| Popup / Menu | Context.popupMenu、gui.menuBar、gui.menuBarPopup |
| Step grid | gui.stepgrid.widgetRow |

ID 付き variant は libs/gui に実在するものだけを使用し、同一セクション内の衝突を避ける。libs/gui 本体は本タスクで変更しない。

## 7. 状態規則

normal は caller 所有値の初期表示、hover と active は前フレーム rect cache と Context.state.hot_id / active_id による実状態、focused は TextInput の focus、disabled は PopupItem.enabled / Command.enabled の個別対応を示す。

empty は空 label / empty text、min / max は slider・picker・layout の endpoint、none は radio など「値なし」の表示を示す。共通 disabled property、semantic role、ARIA 属性、専用 focus-visible API は現有 API にない。

## 8. 現有 widget 状態マトリクス

| widget | normal | hover | active | focused | disabled | empty | min | max | none |
|---|---|---|---|---|---|---|---|---|---|
| button | ✓ | demo | demo | N/A | N/A | ✓ | N/A | N/A | N/A |
| label | ✓ | N/A | N/A | N/A | N/A | ✓ | N/A | N/A | N/A |
| selectableLabel | ✓ | N/A | drag | ✓ | N/A | ✓ | N/A | N/A | ✓ |
| textInputId | ✓ | demo | demo | ✓ | N/A | ✓ | N/A | N/A | ✓ |
| slider i32/f32 | ✓ | demo | demo | N/A | N/A | N/A | ✓ | ✓ | N/A |
| checkbox | ✓ | demo | demo | N/A | N/A | ✓ | N/A | N/A | N/A |
| toggle | ✓ | demo | demo | N/A | N/A | ✓ | N/A | N/A | N/A |
| radio | ✓ | demo | demo | N/A | N/A | ✓ | N/A | N/A | ✓ |
| colorSwatch | ✓ | demo | demo | N/A | N/A | N/A | N/A | N/A | ✓ |
| SV square / hue bar | ✓ | demo | demo | N/A | N/A | N/A | ✓ | ✓ | N/A |
| imageBox | ✓ | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A |
| splitter | ✓ | demo | demo | N/A | N/A | N/A | ✓ | ✓ | N/A |
| scrollArea | ✓ | demo | demo | N/A | N/A | N/A | ✓ | ✓ | N/A |
| popup / contextMenu | ✓ | ✓ | ✓ | N/A | ✓ item | N/A | N/A | N/A | ✓ |
| menuBar | ✓ | demo | demo | N/A | ✓ command | N/A | N/A | N/A | ✓ |
| stepgrid | ✓ | demo | demo | N/A | partial (editable=false) | ✓ | N/A | N/A | ✓ |

## 9. 未対応 widget 空セクション

missing section は Accordion、Alert / Message Dialog、Breadcrumb、Carousel、Combobox、Dialog (Modal)、Disclosure、Listbox、Meter、Spinbutton、Table、Tabs、Tooltip、Tree View、Treegrid の 15 項目を表示する。各項目は矩形、NOT IMPLEMENTED、対象タスク（121.2 / 121.3 / 121.4 / Phase 2）だけを持ち、widget 実装を含まない。

## 10. 横断的な穴

### AC#1: 参照元・欠落セクション・横断穴

- 参照元は §2、APG 30 パターンは §3、ImGui セクションは §4、突き合わせは §5 に固定する。
- 欠落 15 項目と対象タスクは §9 と gallery の missing section に一致させる。
- disabled / focused / semantic role / common query API の穴は本 §10 と §7 に記録する。

### Disabled

共通 disabled property はない。gallery は PopupItem.enabled と Command.enabled を個別に表示し、一般 widget の disabled は N/A とする。stepgrid の editable=false だけは部分対応である。

### Focused / semantic

Context.state.focused_id と textInputId の focus は観測できるが、ARIA role、name、description、keyboard interaction policy を widget 共通に宣言する API はない。landmark、toolbar、link、tabs の semantic 層も未対応で、121.3 の shell で再評価する。

### Querying item status

専用 query API はない。gallery は ButtonResult と custom gallery probe により、代表 widget の hot / active / focused category を観測する。probe digest は次の形式で固定する。

section=<name> index=<i> widgets=<n> missing=<n> schema=v0 hot=<name|none> active=<name|none> focused=<name|none>

## 11. Gallery section と E2E snapshot

| index | section | widgets | missing | 主な実演 |
|---:|---|---:|---:|---|
| 0 | overview | 0 | 15 | 3 軸・参照元・全体件数 |
| 1 | basic | 2 | 0 | button / label |
| 2 | text | 2 | 0 | textInputId / selectableLabelId |
| 3 | values | 4 | 0 | i32/f32 slider / checkbox / toggle / radio |
| 4 | color | 3 | 0 | swatch / SV+hue / image |
| 5 | layout | 2 | 0 | splitter / scrollArea |
| 6 | menus | 2 | 0 | popup/context / menuBar |
| 7 | stepgrid | 1 | 0 | 16 step row |
| 8 | missing | 15 | 15 | 15 placeholders |

examples/35_gui_gallery/e2e.txt は各 section で digest gallery と path 省略の snapshot fb を行う。PNG は repository に追加せず、VP_HARNESS_OUT の実行時生成物を目視する。固定窓は 1024×640、初期 section は overview、font は gui.default_font。

## 12. 更新ルールと引き継ぎ

1. APG / ImGui の参照版と取得日を更新し、§3〜§5 の対応を先に修正する。
2. libs/gui に API が追加されたら §6、§8、gallery section、E2E probe を同じ変更で更新する。
3. N/A を実装済みへ変更するときは、入力注入か単体テストで状態根拠を残す。
4. disabled / semantic / query の共通 API 追加は、横断穴を閉じる変更として記録する。
5. TASK-121.2 は異常系、TASK-121.3 / 121.4 は shell・設定・リスト画面を引き継ぐ。

## 13. TASK-121.2 異常系カタログへの参照

正常系（本マトリクス + `examples/35_gui_gallery`）の対となる異常系・境界系スイートは次を参照する。

- 計画: `docs/plans/PLAN_gui_torture.md`
- 実行記録・起票候補: `docs/notes/TASK-121.2_gui_torture.md`
- example: `examples/37_gui_torture`（probe: `state` / `layout` / `scroll`）
- bench: `zig build bench-gui-frame`（full Context frame 500/1000 行）
- leak: `zig build test-gui-leak`（PerIdStateStore 30000 entries）

### 121.2 で発見された Missing（起票候補・概要）

詳細・file:line・再現 script は notes を正とする。

1. Nested ScrollArea の wheel が内側優先にならず outer/inner 同時変化
2. PerIdStateStore に trim/TTL/上限がなく ID 長期変化で単調増加
3. TextBuffer / textInputId に最大長 API がない
4. 改行・CJK・emoji の measure / coverage は §17 で default font の観測契約を明文化済み
5. popup 長文 item の小画面 outer はみ出し仕様が未明文化
6. zero-size / overflow container の hit-test・clip・child rect 仕様未定義
7. drag 中 layout 変更時の rect cache 同期遅延は §16 で現行契約を明文化済み
8. 自動 ID 同一ラベル衝突は §17 で現行契約と `Id` 版利用規約を明文化済み

## AC#5 / AC#6 セルフチェック

- AC#5: §2 に APG URL・living document・版表記なし・30 パターン・取得日、ImGui URL・v1.92.6・取得日を記載。
- AC#6: §7 と §10 に disabled API 不足、PopupItem.enabled / Command.enabled の個別対応、stepgrid editable、focus と semantic role の不足、専用 query API 不足を記載。

## 14. TASK-121.3 観測（設定画面シェル / examples/39_settings_shell）

`examples/39_settings_shell` で左ナビ + 3 フォーム（General / Editor / Audio、合計 36 コントロール）を現有 API のみで構築した結果。`libs/gui` 本体は変更していない。

### 14.1 既存 Missing への証拠追記（重複行は作らない）

| 項目 | 121.3 での観測 |
|---|---|
| Tabs | 専用 API なし。左ナビ section 切替を `selectableLabelId` + app 側 section enum で代用。 |
| Accordion / Disclosure | 専用 widget なし。フォームは常時展開の `ScrollArea` 内フラットリストで代替。 |
| Combobox / dropdown / select | 専用 widget なし。theme / indent / font / output / buffer は `radioId` 群で代替。 |
| Meter | 未使用・未実装のまま（Audio の show_meter は checkbox フラグのみ）。 |
| Spinbutton | 数値は `sliderI32Id` / `sliderF32Id` で代替。 |
| Tooltip | form description は `labelEx` の固定文で代替。専用 hover tooltip API なし。 |
| Dialog (Modal) | 本シェルでは不要。モーダル確認 UI は未検証。 |

### 14.2 121.3 で新規に観測したギャップ

1. **`selectableLabelId` に clicked 結果がなく、nav activation に focus 依存の app 側 glue が必要**  
   `claimFocus` は click 時に走るが「section 選択」セマンティクスではない。app が `focused_id` を section enum に写す。focus が効かない場合は `hot_id` + `mouse_pressed` の click glue が必要（hack）。
2. **Tabs 相当の selected section semantics が専用 API として存在しない**  
   選択中背景は外側 `beginBox` の bg で app が描画。`selectableLabel` の selection background はテキスト選択用に残した。
3. **共通 form row / label-for / field description の composable API が存在しない**  
   各コントロールは label 付き widget と補助 `labelEx` を手で縦に積む。field と説明の紐付け API はない。
4. **一般 widget 共通の disabled state API が存在しない**  
   設定項目の無効化（例: audio off 時に volume を disable）を表現できない。PopupItem/Command の個別 enabled のみ。
5. **非 text widget の keyboard focus traversal / tab order API が存在しない**  
   checkbox / toggle / radio / slider は focus を claim しない。E2E の `focused=` 期待のため app が `claimFocus` glue を足す必要がある（hack）。
6. **focus-visible の共通描画状態 API が存在しない**  
   keyboard 操作中のフォーカスリング描画を widget 横断で宣言できない。
7. **3 フォーム 36 コントロールの明示 ID 管理が必要**  
   自動 ID は使わず section ごとに ID レンジを分離。probe / harness 座標導出が同一 ID 表に依存。
8. **ScrollArea 長フォームの hit-test は可能だが、scroll 後 rect の再取得が caller 責務**  
   layout probe を scroll 後に取り直し、座標を再計算する運用が必須（harness に座標変数機能はない）。

### 14.3 121.2 既記録との関係

- Nested ScrollArea wheel・PerIdStateStore 上限・TextBuffer 最大長などは本シェルでは再起票しない。
- 設定画面は section ごとに独立 ScrollArea 1 本で、nested wheel 問題は再現経路に含めなかった。

## 15. TASK-121.4 観測（リスト + メニュー shell）

証拠 example: `examples/40_list_menu`（probe: `state` / `layout`、E2E: `e2e.sh` 7 シナリオ、port 9230–9239）。
bench: `zig build bench-gui-list-menu`（500 行 full Context frame、ReleaseFast、1024×768）。
libs/gui 本体は変更していない。不足は example 側 custom/hack または Missing として記録する。

### 15.1 観測結果（Missing 完全リスト）

1. **500 行 full Context frame 時間** — 毎フレーム全行を `selectableLabelId` 付きで構築する。`bench-gui-list-menu` で avg/min/p95 を計測（既存 `bench-gui-frame` の 500 行値と対比）。virtualization なし。
2. **Listbox 専用 semantics なし** — `selectableLabelId` はテキスト選択用であり、単一行 listbox の選択モデルではない。行選択・ハイライトは app 側 state（`selected_row` / `active_row`）で管理。
3. **List keyboard navigation API なし** — 上下キーによる active row 移動は app が `key_down UP/DOWN` を処理する custom 実装。popup 表示中は list ナビを抑制。
4. **Checkbox 付き persistent multi-select popup なし** — `PopupItem` に checked 状態がない。filter は `[on]/[off]` ラベル生成 + 項目選択で閉じる API 挙動を app が再オープンして複数選択を再現（`filter_reopen_count`）。
5. **popup 同時表示数 1 件** — `PopupState` は同時 1 つのみ。menuBar と context/filter は同時保持できない。E2E シナリオ 7 で File menu 表示中に row 右クリックしても `popup_count=1` のまま（観測値: 右クリック後も menu が popup を保持／context は置換しきれない、または次フレームで menu が再確保）。menu と context の重ね合わせは不可。
6. **Ellipsis 標準 API なし** — 長い filename の省略は app が `font.measure` で幅を見て `...` を付与。独自 rasterizer / `DrawList` 直接操作は行わない。
7. **Virtualization API なし** — 500 行を毎フレーム全構築・全 layout。スクロールは `beginScrollArea` のみ。
8. **複数行選択・ドラッグ選択なし** — 本画面は単一選択のみ。probe で `multi_select=0` / `drag_select=0` を明示。
9. **Toolbar 専用 API なし** — Back / New / Refresh は `buttonId` 列として構築。
10. **Table / column / tree view なし** — リストは row box + kind label + selectableLabel + detail の手組み。列レイアウト・ツリーは提供されない。

### 15.2 custom / hack 計数（example 側）

| 種別 | 件数 | 内容 |
|---|---:|---|
| row hit-test + 単一選択 glue | 1 | 右/左クリックで `getNodeCachedRect` により行選択 |
| filter popup 再オープン | 1 | 選択後 `filter_open_request` で次フレーム再 open |
| keyboard 上下ナビ | 1 | `UP`/`DOWN` → `navigateRows` |
| ellipsis 文字列生成 | 1 | `ellipsize` + frame arena |
| menu/context 切替制御 | 1 | context 開要求を menuBarPopup 後に適用、right-press を gui へ渡さない |
| custom draw | 0 | `ctx.custom` / DrawList 直操作 / 独自 rasterizer なし |

### 15.3 サイズ別確認

640×360 / 1024×768 / 1440×900 を別プロセスで起動し `snapshot fb`（path 省略）で目視。padding/gap は幅に応じて調整、固定絶対配置は使わない。

## 16. TASK-131 レイアウトと入力の時間契約

> **本タスク時点の観測（2026-07-18）**: 以下は libs/gui の現行実装に基づく契約である。
> TASK-130 等の並行変更で clip / hit-test 境界が変わる場合は、当該タスクの節と本節を併読すること。

### 16.1 フレーム順序

| 段階 | 処理 | 根拠 |
|---|---|---|
| `beginFrame` | arena reset、input/id_stack/state 初期化、draw_list reset、layout root 生成（未 measure/place） | `libs/gui/src/context.zig:220-243` |
| widget 呼び出し | 前フレーム `rect_cache` で同期 hit-test、当フレーム layout tree を構築 | `libs/gui/src/widgets.zig:203-206` |
| `endFrame` | `layout.measure` → `layout.place` → `rect_cache.clearRetainingCapacity` → `updateRectCache` → `emitNode` → `frame_active=false` | `libs/gui/src/context.zig:245-260` |

`endFrame` は hit-test を行わない。focus 解除・active 張り付き防止は `endFrame` 末尾の state 更新のみ（`context.zig:261-270`）。

### 16.2 rect cache の可視時点

- `updateRectCache` は `endFrame` の measure/place 完了後にのみ走る（`context.zig:256-257`）。
- 登録対象は `beginBox` で `cfg.id != 0` の明示 ID ノードのみ。`{rect, clip, measured_w, measured_h}` を保存（`context.zig:420-429`）。
- `getNodeRect` / `getNodeCachedRect` / `getNodeMeasured` は前フレーム確定値を返す。`beginFrame` 直後も更新されない（`context.zig:377-404`）。
- 初回フレーム・未知 ID・自動採番ノード（`beginBox` の `cfg.id==0`）は null。
- 同一フレーム内の明示 ID 重複は Debug assert で契約違反（`context.zig:424-425`）。

### 16.3 drag 中の layout 変更

layout 変更を伴う drag では次の 1 フレーム遅延が観測される（現行契約。修正は採用しない）。

```text
フレーム N:
  前フレーム rect を読む
  → buttonBehavior が前フレーム rect で active / held を判定
  → widget 構築中に layout 変更
  → endFrame で新 rect を cache に保存・新 layout を描画

フレーム N+1:
  新 rect cache を読んで hit-test
```

フレーム N の描画は新 layout、hit-test は旧 layout。通常の static layout・slider drag・scroll では観測しにくい。

### 16.4 採用理由と非採用案

**採用**: 前フレーム rect cache による同期 hit-test を現行契約として維持。

**非採用案**（同一フレーム rect 反映）:

| 案 | 理由 |
|---|---|
| A: widget 構築前に layout 確定 | 兄弟 measure・親 sizing に依存し、全 widget 構築前に最終 rect を得られない |
| B: endFrame 後に hit-test 再実行 | 同期返却 API（`ButtonResult` / `changed`）と衝突。イベント保存・再評価・順序定義が必要 |
| C: widget ごとに予測 rect | flex/scroll/popup/動的ラベル幅を含む一般 widget に適用不可。layout と hit-test の二重経路 |

実害は限定ケース（drag 中の親 layout 変更、表示切替、release 位置が新旧 rect で不一致）に留まる。

### 16.5 TASK-121.2 E2E 根拠

`examples/37_gui_torture/e2e_input_state.txt` が現行契約の観測値を固定している。

- F1 による layout shift 中も `active=slider`、`dragging=1`、`layout_generation=1` を維持（`e2e_input_state.txt:17-25`）
- mouse up 後 `active_is_zero=1`（`e2e_input_state.txt:27-30`）

### 16.6 TASK-126 wheel 契約との境界

TASK-126 の scroll wheel は `endScrollArea` 同フレーム反映（内側優先消費・viewport node への scroll offset 適用）という scroll 固有の入力配送契約である（`context.zig:64-66` の `ScrollState` コメント参照）。

任意の layout 変更を同一フレーム hit-test に反映する一般契約とは分離して扱う。wheel と rect cache 遅延は矛盾しない。

## 17. TASK-132 テキスト計測・描画契約

> **本タスク時点の観測（2026-07-18）**: 以下は `gui.default_font`（spleen 8×16 bitmap）を前提とした観測契約である。
> 別の `Font` 実装を渡した場合の glyph coverage と advance はその実装の契約に依存する。

### 17.1 適用範囲と Font 依存

- 対象: `Font.measure` / `Font.drawTo` / `TextLayout` / label 系 widget / `textInputId`
- default font: ASCII `32..127` の 8×16 bitmap（`libs/gui/src/font.zig:13-19`, `font.zig:208-215`）
- font chain / emoji font / glyph fallback は `libs/gui` に存在しない

### 17.2 改行

| 経路 | 挙動 | 根拠 |
|---|---|---|
| label / selectableLabel 等（表示） | `\n` は strip されない。1 codepoint として measure 8px。描画は glyph 範囲外のためスキップ、advance は 8px 進む（行送りなし） | `font.zig:18-19`, `font.zig:81-85` |
| TextInput（編集） | typed char / paste / selection replacement は改行・ASCII 制御文字を挿入しない | `widgets.zig:500`, `widgets.zig:619-621`, `text_edit.zig:377`, `text_edit.zig:418` |

default font は 1 行描画契約（改行による高さ増加なし）。

### 17.3 CJK

valid UTF-8 の CJK は 1 codepoint として処理。

| 項目 | default font | 根拠 |
|---|---|---|
| measure | 1 文字 8px | `font.zig:57-61` |
| TextLayout | 1 codepoint 分の byte offset / prefix_width | `text_edit.zig:54-79` |
| 描画 | glyph なし（スキップ） | `font.zig:81-85` |
| advance | glyph なくても 8px | `font.zig:64-71` |
| fallback | なし | — |

`wordRange` は非 ASCII 連続列を 1 word とする。grapheme cluster / 言語別分割は未実装（`text_edit.zig:112-128`）。

### 17.4 emoji

emoji も valid UTF-8 なら codepoint 単位。default font では CJK と同様に glyph 未描画・advance 8px。

ZWJ sequence / variation selector / skin tone 等は grapheme 単位では処理せず、構成 codepoint ごとに処理する。表示上の 1 emoji と logical width の一致は保証されない。

### 17.5 default font の coverage と fallback

- coverage: ASCII `32..127` の bitmap 立ちビット（`font.zig:101-120`）
- 非 ASCII: `.notdef` や代替 glyph に置換されず描画スキップ（`font.zig:81-85`）
- fallback font / font chain: なし

### 17.6 measure / draw advance / ink 幅

default font の `measure`:

- valid UTF-8: codepoint 数 × 8
- invalid UTF-8: byte 数 × 8
- missing glyph / newline / CJK / emoji: いずれも advance 8px

`drawTo` も codepoint ごとに 8px 進むため logical measure と描画カーソル幅は一致する。glyph 未描画時があるため **logical width は ink pixel 幅を意味しない**。

layout text leaf: 幅 = `Font.measure`、高さ = `Font.metrics().line_height`（`libs/gui/src/layout.zig:166-169`）。

### 17.7 TextLayout / caret / selection / hit-test

`buildTextLayout` は codepoint ごとに UTF-8 byte offset・logical advance・累積 `prefix_widths` を生成（`text_edit.zig:54-79`）。

- `selectableLabel`: 幅 = `prefix_widths[count]`、高さ = line_height（`widgets.zig:294-298`）
- `textInputId`: selection / caret / scroll / hit-test は `prefix_widths` 基準（`widgets.zig:351-378`）
- `.fit` 幅 = `Font.measure` + padding（`widgets.zig:596-600`）
- ink height = `ascent + descent`（line_height ではない。`widgets.zig:531-533`）

`hitTest` は advance 中点を境界として **codepoint index** を返す（byte offset ではない）（`text_edit.zig:91-100`）。

### 17.8 自動 ID と同一ラベル衝突

label 系自動 ID は `IdStack.make(label)` = 現在 seed + label の hash（`libs/gui/src/id.zig:83-85`）。

該当 API: `button` / `buttonEx` / `selectableLabel` / `sliderI32` / `sliderF32` / `svSquare` / `hueBar` / `checkbox` / `toggle` / `radio`（各 `id_stack.make` 呼び出しは `widgets.zig` 参照）。`colorSwatch` は `makeInt(色値)`。`textInputId` は自動 ID 版なし。

同一 `IdStack` scope 内で同一 label → 同一 ID → `endFrame` の `updateRectCache` で Debug assert（`context.zig:424-425`）。

負系 E2E: `examples/37_gui_torture/negative_auto_id.sh`（非ゼロ終了 + assert/panic 痕跡を期待）。

**利用規約**: 同一ラベル並置は `buttonId` / `selectableLabelId` 等の明示 ID 版、または `id_stack.push(i)` で scope を分ける。

Release build での最後勝ち上書きは契約上の許容動作ではなく、重複 ID を使わないことを前提とする。

### 17.9 利用規約と非対応範囲

| 項目 | 状態 |
|---|---|
| 複数行 layout / 折返し | 未対応（1 行契約） |
| grapheme cluster 処理 | 未対応（codepoint 単位） |
| glyph fallback / emoji font | 未追加 |
| 改行の行送り（label 表示） | 未対応（advance のみ） |
| 自動 ID 同一ラベル | Debug assert で検出（`endFrame` cache 更新時） |

観測 E2E: `examples/37_gui_torture/e2e_text.txt`（ASCII/CJK/emoji/改行入り label、500 codepoints measure、TextInput caret/selection の codepoint 境界）。
