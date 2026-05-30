# libs/gui - 全体設計

video-proto-main で開発するグラフィックエディタ群 (pixie / paintly / tilex / animix) の共通 UI 基盤として、汎用の immediate-mode GUI ライブラリ `libs/gui` を構築する。

本ドキュメントは **libs/gui 全体のメンタルモデル** を提供する設計資料。各層の詳細設計は backlog の TASK-21.x シリーズに分割されており、本書はそれらを横断する見取り図として機能する。

---

## 目的・位置づけ

| 観点 | 内容 |
|---|---|
| 何を作るか | Dear ImGui 風の immediate-mode GUI ライブラリ |
| 何のために | エディタ群 (pixie 等) のツールバー / パネル / ボタン / カラースワッチ等の UI を組むため |
| 配置 | `video-proto-main/libs/gui/` (既存 `libs/png-decoder/` と並ぶ standalone library) |
| 依存方針 | **video-proto-main の src 配下に依存しない**。`cd libs/gui && zig build` で単体ビルド可能 |
| 公開モジュール名 | `gui` (`@import("gui")`) |
| 関連親タスク | TASK-21 (editor 立ち上げ + libs/gui 構築) |

---

## 全体構成 (積層図)

```
┌─────────────────── Application 層 (例: pixie) ───────────────────┐
│                                                                  │
│   毎フレーム:                                                      │
│     ctx.beginFrame()                                             │
│     if (ctx.button("Save")) saveFile();    ← 宣言と応答が同時      │
│     ctx.label("FPS: 60");                                        │
│     ctx.endFrame()                                               │
│     renderer.render(target, ctx.draw_list)                       │
│                                                                  │
└─────────────────────────────┬────────────────────────────────────┘
                              │ public API: @import("gui")
┌─────────────────── libs/gui ─┴───────────────────────────────────┐
│                                                                  │
│  ┌─ Widget 層 (TASK-21.5 / 21.9) ──────────────────────────────┐  │
│  │   Button / Label / ColorSwatch / Slider                    │  │
│  │   内部で Layout 層にノードを追加 + buttonBehavior + DrawList   │  │
│  └────────────────────────────────────────────────────────────┘  │
│                              ▲                                   │
│  ┌─ Layout 層 (TASK-21.4) ────┴────────────────────────────────┐  │
│  │   Flex layout (measure + layout 2 パス)                     │  │
│  │   親-子ノードのリンクトリスト + grow/fit/fixed/percent 配分     │  │
│  └────────────────────────────────────────────────────────────┘  │
│                              ▲                                   │
│  ┌─ Context / 入力 / ID 層 (TASK-21.2) ─────────────────────────┐  │
│  │   Input  (mouse / keyboard を edge 化)                       │  │
│  │   IdStack (widget 安定 ID; FNV-1a 64bit)                     │  │
│  │   InteractionState (hot / active / focused 管理)             │  │
│  │   Context (上記 + DrawList + arena を束ね、ライフサイクル契約) │  │
│  └────────────────────────────────────────────────────────────┘  │
│                              ▲                                   │
│  ┌─ 描画プリミティブ層 (TASK-21.3) ─┴───────────────────────────┐  │
│  │   DrawList (rect/line/text/image の cmd を蓄積、clip 焼き込み) │  │
│  │   Renderer (DrawList → RenderTarget pixel に焼く)             │  │
│  │   Color / BitmapFont / Rect / Vec2                          │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ (platform 層には依存しない。caller が変換)
┌─────────────────── video-proto-main / platform 層 ──────────────┐
│   platform.Event (key/mouse) → caller が gui.InputEvent に変換   │
│   platform.Framebuffer → caller が gui.RenderTarget に変換       │
└──────────────────────────────────────────────────────────────────┘
```

下から積み上がる純粋な積層構造。**上位層は下位層のみに依存し、逆は無い。** libs/gui は platform / src 配下に依存しないため、他プロジェクトへ持ち出し可能。

---

## immediate-mode GUI の急所 (なぜこの設計か)

immediate-mode GUI の特徴は「**widget オブジェクトを保持しない**」こと。毎フレーム関数呼び出しだけで GUI を組む:

```zig
if (ctx.button("Save")) { saveFile(); }
```

この一行で「ボタンが存在することの宣言」と「クリックされたかの応答」を同時に行う。これを成立させるために、**フレームをまたいで保持すべき最小限の状態**が要る。それが libs/gui (特に TASK-21.2 = Context 層) の責任。

### フレーム間で保持すべき状態と理由

| 状態 | なぜ必要か | 提供する層 |
|---|---|---|
| **Widget の ID** | 関数呼び出ししか無い世界で「これは前フレームの『Save』ボタンと同じ widget だ」と紐付けるキー | `IdStack` (21.2) |
| **hot_id** (hover 中) | hover 表示を 1 フレーム遅延で安定化させる。重なり widget での同フレーム入れ替わりによるフリッカ防止 | `InteractionState` (21.2) |
| **active_id** (押下中ロック) | 「ボタン上で press → ドラッグして外へ → 戻って release」を click として扱う。押下開始時の widget を記録する必要がある | `InteractionState` (21.2) |
| **mouse_pressed/released** (edge) | 「今フレームに down した」と「ずっと押されている」を区別しないと毎フレーム click が連発になる | `Input` (21.2) |
| **wantsMouse** | 「GUI がマウスを消費中か」の per-frame シグナル (カーソル変更や非ドラッグツール判定に使う)。ドラッグの canvas/GUI 振り分け自体は press 起点ベースの capture で行う (下記「hit-test 契約」/ 手順 6) | `Context` (21.2) |
| **mouse_pressed_pos** | press した瞬間の座標 (Dear ImGui の MouseClickedPos 相当)。canvas-side capture の開始判定や drag 閾値に使う。集約 mouse_pos は最終位置なので起点を取りこぼす | `Input` (21.2) |
| **前フレームの widget rect** | immediate-mode の同期 hit-test に使う (下記「hit-test 契約」)。`id → Rect` を 1 フレーム保持 | `Layout` (21.4) |
| **DrawList** | widget の描画指示を蓄積し、フレーム末にまとめてピクセル化する | 描画プリミティブ (21.3) |

これらが揃って初めて、widget 関数 (21.5) を上に積める。

---

## immediate-mode の hit-test 契約 (重要)

`if (ctx.button("Save")) { ... }` のように **widget 呼び出しが clicked を同期返却**するのが immediate-mode の肝。一方 Flex layout (21.4) は全子確定後でないと rect が決まらず、layout は `endFrame` で行う。この 2 つを **Dear ImGui 流の同期 hit-test** で両立する:

| 処理 | いつ | 使う rect |
|---|---|---|
| **hit-test** (hover/active 判定、`clicked` 返却) | widget 呼び出し時 | **前フレーム**の rect (`id` 別キャッシュ) |
| **layout 計算** | `endFrame` | — (当フレームを算出) |
| **draw コマンド発行** | `endFrame` (layout 後) | **当フレーム**の rect |
| **hover 色** | `endFrame` の draw 時 | `hot_id` (前フレーム確定、安定) |

- `clicked` は当フレームの入力 + 前フレーム rect で判定するので **当フレームに即返る** (click 応答の遅延なし)。
- layout が変化したフレームのみ hit-test に 1 フレーム遅延が生じるが、静的レイアウトでは不可視。
- 初回フレームは rect 未確定なので非ヒット扱い (1 フレームのウォームアップ)。
- layout を持たない 21.2 の sample 09 では rect が hardcode のため、その rect をそのまま hit-test / draw に使う (キャッシュ不要の特殊ケース)。

---

## フレームライフサイクル (1 フレームのデータの流れ)

```
  1. platform からイベント受信 → caller が gui.InputEvent に変換
       (Swift/Metal → C → Zig platform.Event → gui.InputEvent)
       ・この時点では canvas に流さず、いったん溜めておく
         (ルーティング判定は hit-test 後の手順 6 で行う)
              │
              ▼
  2. ctx.beginFrame()
       ・arena.reset                    (前フレームの payload をここで解放)
       ・input.beginFrame               (edge クリア、prev pos 保存)
       ・id_stack.clear
       ・state.beginFrame               (hot_id ← next_hot_id, next_hot_id=0,
                                         this_frame_hovered_any=false)
       ・draw_list.reset / layout_tree.reset
              │
              ▼
  3. ctx.pushEvent(ev) を溜まったイベント分くり返す
       ・Input が現在状態を更新 + edge (pressed/released) を計算
              │
              ▼
  4. アプリが widget を呼ぶ (UI 組み立て + 同期 hit-test)
       if (ctx.button("Save")) { ... }
         └→ id = id_stack.make("Save")
         └→ レイアウトツリーにノード追加 (21.4)
         └→ 前フレーム rect で buttonBehavior
            → hot/active 更新、clicked を同期返却
              │
              ▼
  5. ctx.endFrame()
       ・layout(root, screen_rect)       (measure + place)
       ・ツリーを DFS して draw cmd 発行  (当フレーム rect, hover 色は hot_id)
       ・各ノードの rect を id 別キャッシュに保存 (次フレームの hit-test 用)
       ・※ hit-test はしない / arena reset もしない
              │
              ▼
  6. canvas へのルーティング (press 起点ベースの capture で行う)
       ・canvas-side capture: press 起点 mouse_pressed_pos が canvas 領域内なら stroke 開始、
         release まで hover に関わらず canvas が捕捉する (GUI の active_id と対称)。
         - 判定に最終位置 mouse_pos / per-frame wantsMouse は使わない。これらはフレーム
           最終位置依存で、「canvas で down → 同フレームで panel へ move」した press 起点を
           取りこぼすため。down 起点を保持する mouse_pressed_pos で判定する。
         - canvas 領域は GUI widget と重ならない前提 (pixie の canvas_area box は中身空)。
           重なる widget を将来置く場合は press 時の GUI hit-test で別途除外する。
       ・捕捉中は集約フレーム状態 (mouse_pos / pressed / released) をツールに渡す
         (個々の move イベント再生は不要)。stroke の隙間は mouse_prev → mouse_pos の
         線補間で埋める (フレーム内の中間 move を落としても繋がる)。
       ・wantsMouse は「GUI がマウスを消費中か」の per-frame シグナルとして残る
         (カーソル変更や非ドラッグのクリックツール判定などに使う)。
       → 具体的な caller パターンは TASK-21.8 参照
              │
              ▼
  7. canvas.render(target) → Renderer.render(target, ctx.draw_list)
       (canvas を下地に焼き、その上に GUI の DrawCmd を焼く。clip 適用)
              │
              ▼
  8. window.present()                          (画面更新)
```

### ライフサイクル契約 (重要)

- **`arena` reset は次フレームの `beginFrame` 冒頭** に行う。`endFrame` 直後ではない。
  - 理由: `endFrame` 後でも caller が `getNodeRect(id)` 等で layout 結果を参照しうる。同じフレーム内に reset すると dangling になる。
- **hit-test は widget 呼び出し時** (前フレーム rect 使用)。`endFrame` は layout + draw + rect キャッシュ更新のみで、hit-test はしない。
- **ArrayList (cmds / clip_stack / id_stack / layout_tree) は gpa で持つ**。フレームごとに `clearRetainingCapacity()`。
  - arena は cmd の payload (text / image slice 等) のみ。
- `endFrame` 後でも `draw_list` / `id_stack` / `state` / `layout_tree` / rect キャッシュの参照は次フレーム `beginFrame` まで valid。

---

## 用語集

| 用語 | 意味 |
|---|---|
| **immediate-mode** | widget オブジェクトを保持せず、毎フレーム関数呼び出しで UI を組む方式。Dear ImGui が代表。retained-mode (DOM/Qt 等) の対義 |
| **Id** | widget を一意識別する u64。FNV-1a で id_stack + label から生成 |
| **id_stack** | 親 widget の Id を積むスタック。同じラベル ("Save") でも親が違えば異なる Id になる |
| **hot_id** | 前フレーム確定の hover ID。描画用 (色変えなど)。フリッカ防止のため 1 フレーム遅延 |
| **next_hot_id** | 今フレーム計算中の hover 候補。描画順で最後勝ち。次フレーム beginFrame で hot_id に昇格 |
| **active_id** | 押下中ロック対象の widget ID。press 開始から release までの間、入力をこの widget が独占 |
| **focused_id** | キーボード入力フォーカス対象 (text field 用、本フェーズでは設定しない) |
| **edge** | このフレームに状態変化があったことを示すフラグ。`mouse_pressed.left` は down した瞬間のフレームのみ true |
| **wantsMouse** | GUI がマウスイベントを消費中か。`(this_frame_hovered_any) or (active_id != 0)`。caller は hit-test 後 (endFrame 後) に参照するので当フレームの hover を反映する (遅延なし) |
| **同期 hit-test** | widget 呼び出し時に前フレーム rect で当たり判定し、clicked を即返す方式 (Dear ImGui 流)。draw は endFrame に後送り |
| **clip 焼き込み** | 各 DrawCmd に clip rect を含める方式。stateful な push/pop replay 不要 |
| **standalone** | libs/gui が video-proto-main の src 配下や platform に依存しない性質 |

---

## サブタスク分割と進捗

### libs/gui 内の依存順 (本ドキュメントが扱う範囲)

```
TASK-21.3 (描画プリミティブ: DrawList / Renderer / Color / BitmapFont)
   ▼
TASK-21.2 (Input + ID + InteractionState + Context、フレームライフサイクル契約)
   ▼
TASK-21.4 (Flex layout: measure + layout 2 パス、rect キャッシュ / getNodeRect)
   ▼
TASK-21.5 (Button / Label / ColorSwatch)
   ▼
TASK-21.9 (Slider; 21.5 完了後、必要になった時点で)
```

各サブタスクは独立した backlog タスクとして `backlog/tasks/task-21.x - *.md` に詳細設計が記述されている (GPT レビュー反映済み)。本ドキュメントを起点に各タスクへドリルダウンする。

### TASK-21 全体ロードマップ (親タスク基準)

libs/gui の構築と editor 側 (pixie) の立ち上げは **並行する 2 本のクリティカルパス**。tracer-bullet (21.6) は libs/gui の完成を待たず、21.1 完了後に着手できる:

```
TASK-21.1 (mouse input, platform 層) ── Done
   ├──→ TASK-21.6 (editor skeleton + tracer-bullet 最小 pixie。UI ハードコード)
   │       └──→ TASK-21.8 (pixie UI 置換 + Pen/Eraser/Undo)
   │               └──→ TASK-21.7 (core 抽象化整理)
   └ (並行)
TASK-21.3 → 21.2 → 21.4 → 21.5 ──→ TASK-21.8 (libs/gui で UI 置換)
```

→ 21.8 が libs/gui (21.5 まで) と tracer-bullet pixie (21.6) の合流点。

---

## standalone 性の維持

libs/gui の独立性を保つため、以下を遵守する:

1. **`@import("...")` で video-proto-main の src/ を参照しない**
   - text / sprite / platform は使わず、libs/gui 内で `BitmapFont` / `RenderTarget` を独自定義
   - デフォルト 8x16 ASCII フォントは libs/gui に同梱 (@embedFile)
2. **イベント型を独立定義**: `gui.InputEvent` を持つ。`platform.Event` には依存しない
   - caller (pixie 等) が `platform.Event → gui.InputEvent` の薄いアダプタを書く
3. **`cd libs/gui && zig build` / `zig build test` が単体で通る**
4. **video-proto-main の build.zig からはモジュール `gui` として公開** (`@import("gui")`)

これにより、将来 editor を sibling repo として切り出す際に libs/gui ごと持ち出せる。

---

## 外部参照 (getNodeRect) の制約

caller が「キャンバス領域」「ステータスバー」等の widget rect を GUI 外から参照したい場合は `getNodeRect(id)` を使う。ただし:

- **明示 ID を与えたノードのみ参照可能**。自動 ID (label hash + id_stack / @src() ベース) のノードは `getNodeRect` が `null` を返す (21.4 仕様)。
- 外部参照対象 (canvas_area 等) は `buttonId(0xCANVAS_AREA, ..)` のように **明示 ID を要求する API** を使う (21.2 指摘 3-7)。
- 取得した rect は `endFrame` 後〜次フレーム `beginFrame` まで valid (ライフサイクル契約)。

---

## 制限事項 (libs/gui MVP では非対応)

- Flex layout: wrap、absolute positioning、justify_content (start のみ)
- 線描画: 太さ > 1 のアンチエイリアス
- フォント: ASCII のみ (CJK は将来課題)
- スタイル: push/pop によるスコープ管理 (Context.style 直接書き換えで MVP は十分)
- text field、scroll view、dropdown 等の複合 widget (pixie MVP では不要)

これらは別タスクとして必要になった時点で着手する。

---

## 関連資料

- TASK-21 (親、ディレクトリ配置と全体実装順序): `backlog/tasks/task-21 - editor-プロジェクト立ち上げ-libs-gui-構築...md`
- TASK-21.2 (Context / 入力 / ID 層): `backlog/tasks/task-21.2 - libs-gui-入力管理-ID-stack-hot-active.md`
- TASK-21.3 (描画プリミティブ): `backlog/tasks/task-21.3 - libs-gui-骨組み-描画プリミティブ.md`
- TASK-21.4 (Flex レイアウト): `backlog/tasks/task-21.4 - libs-gui-Flex-レイアウトエンジン.md`
- TASK-21.5 (基本ウィジェット): `backlog/tasks/task-21.5 - libs-gui-基本ウィジェット（Button-Label-ColorSwatch-Slider）.md`
- TASK-21.9 (Slider): `backlog/tasks/task-21.9 - libs-gui-Slider-ウィジェット（i32-f32）.md`
- ADR 003 (イベント処理層の配置): `video-proto-main/docs/adr/003_イベント処理層の配置.md`
