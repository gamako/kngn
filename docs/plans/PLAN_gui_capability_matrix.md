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

## AC#5 / AC#6 セルフチェック

- AC#5: §2 に APG URL・living document・版表記なし・30 パターン・取得日、ImGui URL・v1.92.6・取得日を記載。
- AC#6: §7 と §10 に disabled API 不足、PopupItem.enabled / Command.enabled の個別対応、stepgrid editable、focus と semantic role の不足、専用 query API 不足を記載。
