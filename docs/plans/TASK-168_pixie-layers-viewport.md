# TASK-168 Pixie Layers パネル最下段クリップ解消 計画

## 目的 / 背景

狭いウィンドウで Pixie の右スロットに Color / Palette / Tool Options / Layers を同時に
表示し、レイヤー数を増やすと、Layers パネルの最下段行が右スロットの下端で見切れる。
TASK-148.3 は Layers 内に専用 `ScrollArea` を導入したが、右スロット全体の自然高が
viewport を超えた場合は PanelHost 側のスクロールを将来対応とする degradation を残している。

本タスクでは、既存 GUI のスクロール機構を PanelHost の右スロットへ適用し、Layers の
内側スクロールと組み合わせて全レイヤーへ確実に到達できるようにする。他パネルの自然高を
削って救済する方式は採用しない。

## 実コード調査結果

- `apps/editor/apps/pixie/main.zig:2947-3018`
  - `layersNaturalContentHeight` はレイヤー数 × 24px、行間 2px、上下 padding、選択中
    Text Layer UI の概算高から自然高を求める。
  - `updateLayersViewportHeight` は右スロットの前フレーム rect から Color / Palette /
    Tool Options の visible panel 高、panel 間 gap、Layers の chrome 高を差し引く。
  - 現在は「他セクションの自然高を先に確保し、Layers を
    `clamp(natural, 1 行, 残り高)`」で配分し、残り高不足時は下端クリップを許容する。
- `apps/editor/apps/pixie/main.zig:5513-5570`
  - toolbar は Layers 専用 ScrollArea の外にあり、常に操作可能である。
  - 行高は固定 24px のサムネイルが律速で、content は `.fit` のため内側の全行を保持する。
- `apps/editor/apps/pixie/main.zig:6518-6552`
  - 右スロットの宣言順は Color、Palette（既定 closed）、Tool Options、Layers。
  - 右 slot の既定幅は 200px、最小幅は 120px。縦方向は PanelHost の right slot が grow する。
- `libs/gui/src/panel_host.zig:49-63,172-245,564-610`
  - `SlotOptions` に scroll state / scrollable slot はない。
  - `buildSlot` は `clip_children = true` の column box に visible panel を宣言順で縦積みする
    だけで、PanelHost 内に `beginScrollArea/endScrollArea` はない。
  - `clampExtents` は center の最小幅/高さを優先するが、right slot 内の panel 内容高は考慮しない。
- `libs/gui/src/widgets.zig:1635-1848` / `libs/gui/src/layout.zig:61-65`
  - GUI には既存の ScrollArea があり、自然 content 高から scroll 範囲と scrollbar を作る。
  - TASK-126 の LIFO wheel 処理により、ネスト時は内側が先に消費し、端に達した残量を外側へ
    伝播できる。Layers 内側と PanelHost 外側の組み合わせに再利用できる。
- `apps/editor/apps/pixie/main.zig:3583-3606,6585`
  - `digest panels` は右 slot panel の y/h と framebuffer 高を返す。外側 scroll 後は、自然
    content の raw rect の overflow と、visible slot boundary の安全性を区別する必要がある。

## 方針と採用案

### 採用: PanelHost の右スロットに既存 ScrollArea を追加

`SlotOptions` に `scrollable` を追加し、Pixie は右 slot だけ有効にする。scrollable slot は
現行の slot 外枠（背景、padding、clip）を維持し、その内側に既存の vertical ScrollArea を
置く。visible panel 群は `content_height = .fit` の content として、現在どおり宣言順に積む。

ScrollArea の viewport ID は slot ID と分離する。slot ID を持つ外枠 box はそのまま残し、
その内側に別の安定 viewport ID の ScrollArea を置く。slot ID は `slotRect` / splitter / layout
参照に使い続ける。content が収まる場合は scrollbar を
表示せず従来の見た目を保ち、収まらない場合だけ自然高を保持したまま slot 内をスクロールする。

Layers 上の wheel はまず内側 ScrollArea が消費し、Layers が端に達した残量を右 slot 外側が
消費する。このため Layers panel 自体を viewport 内へ移動した後、Layers 内の最下段へ到達できる。

### 不採用: セクション高配分だけを変更

Layers に固定優先で高さを与えると Color / Palette / Tool Options の natural 高を削る。
Tool Options はアイコン、toggle、slider、Bezier anchor 表示を持つが、PanelHost 側に
縮小・内部スクロールの契約がない。高さを強制的に縮めるだけでは操作部品を clip して AC #2
を損なうため、TASK-148.3 の「他セクション優先」意図を維持し、不足分を PanelHost 外側の
scrollbar で救済する。

## 高さ配分の設計

右 slot の優先順位は次のとおりとする。

1. visible かつ open な Color / Palette / Tool Options は、前フレーム実測 natural 高を確保する。
   closed は見出しだけ、非表示は 0 とする。
2. slot padding、visible panel 間 gap、Layers の Collapsible 見出し + toolbar（chrome）を引く。
3. 残り高が Layers 自然高以上なら自然高を使う。
4. 残り高が自然高未満でも Layers viewport は最低 1 行（24px）まで縮める。残りが 24px 未満
   でも 24px を要求し、PanelHost 外側の content overflow を scrollbar で扱う。
5. Color / Palette / Tool Options を Layers のために縮めない。right extent や center 最小
   幅/高さも変更しない。自然 content が slot viewport を超えた場合は各 panel の高さを保って
   panel 群を外側 scroll する。

`updateLayersViewportHeight` と `layersNaturalContentHeight` の数式・固定行高は再利用し、
TASK-148.3 の degradation コメントだけを「PanelHost 外側 scroll で下端へ到達可能」という
現行設計へ更新する。初回 rect 未確定時は既存 fallback、次フレームで前フレーム rect を使う。
外側 scroll offset は UI 一時状態とし、既存 Preferences の visible/open/extent 形式は変えない。

`digest panels` の既存 raw `Color_y/Color_h` 等は互換維持する。`bottom`/`ok` が自然 content の
画面外部分を崩壊と誤判定しないよう、必要なら slot y/h または clip 内 bottom を追加キーで公開し、
`ok` は visible slot boundary の有効性として扱う。raw rect の overflow と到達不能を probe 上で区別する。

## 作業手順

1. `libs/gui/src/panel_host.zig` の `SlotOptions` / `SlotState` に scrollable flag と
   PanelHost-owned の永続 `Vec2f` state を追加し、slot ごとの stable viewport ID を用意する。offset は
   init 時ゼロ、毎フレーム ScrollArea が content natural 高に合わせて clamp する。
2. `buildSlot` を scrollable / non-scrollable の二経路に分ける。non-scrollable は現行のまま、
   scrollable は既存 padding/bg/clip の外枠 + `beginScrollArea/endScrollArea` + panel content
   fit とする。callback error 時も endScrollArea と box end を必ず呼び、begin/end 対称契約を守る。
3. `hitTest` の panel 判定を `getNodeCachedRect` の effective clip と
   `context_mod.pointHitsVisible` で行い、外側 ScrollArea で画面外へ移動した panel を可視と誤認
   しない。splitter / center の優先順位は変更しない。
4. `apps/editor/apps/pixie/main.zig` の PanelHost 初期化で右 slot のみ `scrollable = true` にする。
   Layers 内側 ScrollArea、toolbar の scroll 外配置、既存の高さ配分式は維持し、コメントと
   `digest panels` の visible-boundary 観測だけを新設計に合わせる。
5. `panel_host.zig` の unit test に、(a) content overflow 時の scrollbar/offset、(b) wheel または
   thumb 操作で下側 panel が viewport 内へ移ること、(c) non-scrollable の回帰、(d) clip 外
   panel が hitTest されないこと、(e) callback error 後も次 frame が構築できることを追加する。
6. `zig build test-gui` と `zig build bench-gui-frame` を実行する。新設経路が panel/widget 数
   オーダーであり、全画素処理・音声 RT 経路・lock を追加していないことを確認する。

## 検証方法

`VP_APPSHELL_DIR` を一時ディレクトリにし、既存 `window_state.ash` の仕組みで Pixie を
420x360 程度に設定する。Palette を visible + open、Color / Tool Options / Layers も open にし、
`action add_layer` を 15〜20 回実行する。生成した ash / PNG はリポジトリへ追加しない。

代表 replay は次のコマンド列とする（Palette の open は通常の header クリックまたは persisted
PanelHost 設定で準備し、座標は初回 snapshot で確認する）。

    step 3
    action add_layer       # これを 15〜20 回
    step 3
    digest panels
    snapshot fb /tmp/task-168-before.png
    inject scroll 0 -3     # Layers 内側の下端まで複数回
    inject scroll 0 -3     # 端到達後は外側へ伝播
    inject scroll 0 -3
    step 8
    digest panels
    snapshot fb /tmp/task-168-after.png
    quit

通常は `VP_HEADLESS=1 VP_HARNESS_SCRIPT=/tmp/task-168.txt VP_HARNESS_OUT=/tmp zig build run-pixie`
で replay し、`snapshot fb` の PNG を Read で目視する。before で Layers viewport または
PanelHost scrollbar が見え、after で最下段の thumbnail / name / visibility / opacity controls
が完全に見えることを確認する。Tool Options の slider/toggle、Color/Palette の下端も確認する。
必要なら外側 scrollbar の thumb drag も実施する。macOS 実機では同じ replay を実 backend でも
一度実行し、スクロールバー入力と描画差がないことを確認する。

`expect panels ok=1` は visible slot boundary の意味に合わせて使う。自然 content の raw rect が
画面外へ出ることは許容し、scroll offset が clamp され最後の Layers 行が visible になった
snapshot を AC #1 の証拠とする。

## ホットパス宣言

`PanelHost.build`、`updateLayersViewportHeight`、各 panel callback、Layers 行構築はフレーム毎の
UI 描画コードで、計算量は visible panel / widget / layer row 数オーダーである。外側 ScrollArea
の layout もフレーム毎、wheel の offset 更新は入力イベントのあるフレームのみ。音声 RT、毎サンプル、
全画素 framebuffer ループには触れない。

per-pixel 除算、内側 loop の bounds/clip 検査、フレーム毎の registry 複製、RT alloc/lock/panic
は新設しない。Scroll stack の容量拡張は warm-up 時だけにし、通常フレームは既存 GUI state を
再利用する。フレーム毎 UI の変更なので `bench-gui-frame` は前後比較するが、SIMD 3点セットや
audio RT benchmark は対象外とする。根拠は変更が画素処理・毎サンプル処理ではなく、panel/widget
数オーダーの layout だけだからである。

## 影響範囲 / 関係ファイル

- `libs/gui/src/panel_host.zig`: scrollable slot、外側 ScrollArea、clip-aware hit-test、unit test。
- `apps/editor/apps/pixie/main.zig`: 右 slot の scroll 有効化、TASK-148.3 コメント、必要なら
  `digest panels` の visible-boundary 観測。
- `libs/gui/src/widgets.zig`: 既存 ScrollArea を再利用し、仕様変更は原則不要。ネスト wheel
  テストで不足が見つかった場合のみ TASK-126 契約を壊さない範囲で対象とする。
- `build.zig` / harness: 新規 build target や golden image は追加せず、既存 test/bench/replay/
  snapshot/digest を使う。

## AC との対応

- AC #1: Layers 内側 ScrollArea で全行へ到達し、必要時は PanelHost 右 slot 外側 ScrollArea
  で Layers panel 自体を viewport 内へ移動できる。最下段を snapshot で目視する。
- AC #2: Color / Palette / Tool Options は natural 高を優先して保持し、Layers の不足分を
  それらから奪わない。Tool Options の slider/toggle が不当に clip されないことを snapshot と
  panel rect probe で確認する。

## 未確定事項 / 決定事項

- 決定: 新しい scroll 実装を作らず、既存 `beginScrollArea/endScrollArea` を slot content の
  外側へ再利用する。
- 決定: Pixie では右 slot のみ scrollable にし、left/bottom の既存表示契約は変えない。
- 決定: Layers の「他セクション natural 高優先」配分を維持する。Tool Options を縮める案は
  AC #2 と TASK-148.3 の意図に反するため見送る。
- 保留: `digest panels` の `ok/bottom` を raw rect と visible slot boundary のどちらで表すかは
  実装後の probe 互換性を確認する。ただし既存 raw キーを無断で別意味に変更せず、必要なら
  visible-boundary 用キーを追加する。
