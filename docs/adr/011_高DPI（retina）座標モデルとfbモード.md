# ADR-011: 高 DPI（retina）座標モデルと framebuffer モード

**Status:** 承認済み
**Date:** 2026-07-20
**Category:** platform / gui / gfx・座標系・描画パイプライン
**関連タスク:** TASK-156（高 DPI 対応）/ TASK-157（objc の滲み）/ TASK-167（gui アウトラインフォント）

## 背景・問題

macOS の全 backend（objc/swift/metal）は現状、framebuffer を**論理解像度（points）で確保し、retina
（backingScaleFactor=2）では表示時に 2x 拡大**している。真の物理解像度で描いている backend は無い。
拡大方式の違いが「滲む/くっきり」の差になっているだけ:

| backend | 拡大方式 | 見え方 |
|---|---|---|
| objc | `CALayer.contents` に論理サイズ CGImage、`contentsScale`/filter 未指定 → デフォルト **linear** 拡大 | 滲む |
| swift | objc とほぼ同一（filter/contentsScale 未指定） | 本来 objc と同じく滲むはず（実機で要再確認） |
| metal | シェーダ sampler が `filter::nearest`（`platform_macos_metal.swift:82-84`） | くっきり（ただし nearest 拡大のブロックで、真の 2x 描画ではない） |

このため実機（TASK-138）で「UI パーツが 2x 相当で粗い / フォントが小さすぎ・甘い / objc の OS スクショが
滲む」というフィードバックが出た。**くっきりなテキストは物理 px で直接ラスタライズするしかなく**（論理
ラスタを拡大する限り甘さは消えない）、根治には framebuffer の物理解像度化が要る。一方で、この基盤は
「ゲーム/グラフィックスのプロトタイピング環境」であり、レトロ・ドット絵ゲームのように**論理解像度を
nearest 整数拡大したい**（物理 fb を望まない）用途も一級市民である。

## 決定内容（規則として明文化）

### R1. framebuffer モードは opt-in（既定は現状維持）

`Window` 生成時にアプリが framebuffer モードを選べるようにする。既定は `.logical`（＝今の挙動）:

| モード | 中身 | 向く用途 |
|---|---|---|
| `.logical`（既定） | 論理 fb・OS が拡大。**fb レイアウト・API・crc は bit 不変**（下記 R9 の条件付き。※表示フィルタは R8 で変わり得る＝OS スクショのピクセルまでの不変は約束しない） | レトロ/ドット絵ゲーム・手早いプロトタイプ。文字は甘いが単純 |
| `.physical`（HiDPI） | 物理 fb（`w*scale × h*scale`）を確保し `contentsScale=scale` を設定 | くっきり UI アプリ（pixie/patch）・高解像度ゲーム |

**scale 非対応 backend の受理**: scale を持たない backend でも `.physical` は `contentScale()=1.0` として
**受理する**（`Unsupported` で弾かない）。scale=1 では物理 fb ＝論理 fb と一致し、`.physical` のコードパスが
全 backend で常に成立する（非 retina 環境・未対応 backend でのフォールバック）。

### R2. 論理サイズと framebuffer サイズを API で明確に分離する（最重要の前提契約）

現状は `fb.width/height` をそのまま gui の論理サイズとして使っている（`pixie/main.zig:6668` の
`beginFrame(fb.width, fb.height)`、`patch/main.zig:2830` も同型）。`.physical` でこれを続けると
レイアウト・clip・ヒットテストが 2 倍になって破綻する。A2 を成立させるため、platform に次の契約を置く:

- `window.logicalSize()`（論理 pt）と `window.framebufferSize()`（物理 px）を**別 API として分離**する。
  `Framebuffer` は物理 px を返し、**`.physical` では fb.width/height を gui レイアウトに直接使わない**。
- `window.contentScale() f32` を公開する。
- **runtime での scale 変更**（モニター跨ぎ・解像度変更）を契約に含める: fb サイズ・入力座標・gui 描画が
  **同一フレームで同じ scale を見る**こと。
- **フレーム scale スナップショット（確定規則）**: `lockFramebuffer()` が返す `Framebuffer` に
  `logical_size` / `framebuffer_size` / `content_scale` / `scale_epoch`（scale 変更ごとに +1 する版番号）を
  **束ねて 1 スナップショットとして持たせる**。scale は **`lockFramebuffer()`（フレーム先頭）で latch** し、
  そのフレームの描画・入力処理・present はすべてこの latch 値を読む。フレーム途中に OS が scale を変えても
  当該フレームには影響せず、**次フレーム境界で新 scale を latch**する（プロジェクトの「生成境界で latch」
  イディオムと同型）。
- **入力座標の変換責任と時点（確定）**: ループ順は `pollEvents()`（キュー投入）→ `lockFramebuffer()`
  （scale latch）→ `nextEvent()`（取り出し）である。投入時点では当フレームの latch がまだ無いので、
  **backend は raw（native/物理）座標 + event epoch をキューに積むだけ**にし、**facade（`core/platform.zig`）が
  `nextEvent()` の取り出し時に、現フレームの latch scale を使って論理座標へ正規化する**（変換の唯一の主体は
  facade。backend は変換しない）。`nextEvent()` は必ず `lockFramebuffer()` 後に呼ばれる前提だが、稀に前に
  呼ばれる経路では**直近に latch 済みの scale**（初回は content_scale）を使う。`mouse_pressed_pos` 等の派生
  座標もこの facade 正規化後の値から作る。
- `platform_types.zig` / `platform.zig` の window / `Framebuffer` 型に fb モード・上記スナップショット
  4 項目を追加する（現状これらの契約が無い）。

### R3. 座標モデルは A2（アプリ/gui は論理座標のまま。scale は出力の端で 1 回）

`.physical` でも、アプリと gui のロジックは**論理座標（points）のまま**書く。レイアウト・ヒットテスト・
マウス入力（論理 pt）はすべて論理座標で行い、物理ピクセルへの変換は描画の出口でだけ適用する。
`Context.beginFrame()` には論理サイズを渡し、`DrawList.reset()` の root clip も論理サイズにする。

**入力の backend 別契約**（macOS だけでは成立しない）:
- 各 backend の OS イベント座標の単位を明記する（macOS はビュー座標→論理 pt に変換済み
  `platform_macos.m:336-343`。Linux/Windows はクライアント px を返している可能性があり要確認）。
- **論理座標への変換場所を 1 箇所に定める**（R2 の確定どおり: backend は raw 座標 + event epoch を渡すだけ、
  **facade が nextEvent() 取り出し時に論理 pt へ正規化する唯一の主体**。backend は変換しない）。
- `mouse_pressed_pos` / `mouse_released_pos` 等の派生座標も**同じ変換を通す**（変換漏れ防止）。

不採用: A1（アプリ/gui が物理 px で考え、全レイアウト定数に `×scale` を撒く）。理由は下記「代替案」。

### R4. UI 系の scale 注入は `gui.render` に集約し、変換規則を明文化する

DrawList は論理座標を持ち、`gui.render`（`libs/gui/src/render.zig`）が物理 target + scale を受けて焼く。
render は現状 1:1 描画（`render.zig:17-28`）なので、次の**変換規則を確定**する（P2 開始条件。すべて
`libs/gui` の単体テストで固定する）:

- **矩形は「両エッジ floor」で完全タイリングする**（`floor/ceil` 混在は隣接矩形が 1px 重複するので採らない）:
  `x0 = floor(x*s)`, `x1 = floor((x+w)*s)`, 幅 `= x1 - x0`（y も同様）。隣接矩形 `[0,10),[10,20)` は s=1.5 で
  `[0,15),[15,30)` となり**隙間も重複も出ない**。**clip も同一規則**で物理化する。負座標も `floor`（-∞ 方向）で
  一貫（`floor(-1.5*2) = -3`）。
- **線**: 端点は `floor(p*s)`、線幅は `thickness_phys = max(1, round(t*s))`。∴ **1 論理 px 罫線は s=2 で 2px**
  （`round(1*2)=2`）、s=1 で 1px。
  - ⚠️ **既存バグ（高 DPI 以前）**: `render.zig:23` は `line` の thickness を `drawLine`（`render.zig:123`）へ
    渡していない（`draw.zig:15` に thickness はある）。これは**この対応の前提として先に修正**する。
- **image**: nearest 拡大。dst の各画素 `(dx,dy)`（物理・rect ローカル）に対し
  `sx = floor(dx * src_w / dst_w)`, `sy = floor(dy * src_h / dst_h)` で src を引く（整数 nearest）。
  現状 `rect.w == src_w` 前提の 1:1 blit（`draw.zig:96-113`）をこの一般 nearest へ拡張する。
- **テストケース（最低限）**: s∈{1.0, 1.5, 2.0} で ①隣接矩形の完全タイリング（隙間/重複ゼロ）②clip 境界の
  一致 ③1px 罫線の物理幅 ④image の src↔dst 対応、を bit で固定。

### R5. gui フォントは論理 measure / 物理 raster を分離する（TASK-167 を拡張）

`Font` は現状 `measure()` と `drawTo()` が同一インスタンスに属す（`libs/font/src/font.zig:30-66`）。A2 では
`measure()`=論理幅・`drawTo()`=物理 px ラスタライズを両立させる。**採用する API（確定）**:

- **`Font` は論理定義のまま**にする（scale を持たせない）。`measure()` / `metrics()` は**論理 px 単位**を返し、
  scale に非依存。縦センタリングは論理 `ascent`/`descent`（TASK-167）を使う。
- **ラスタライズは `drawTo` が scale 引数を受ける（確定）**: `drawTo(target, pos, text, color, clip, scale)`
  で、内部的に**論理 px × scale の物理 px サイズ**でグリフを生成する（既存の `Font` vtable 契約を保ちやすい
  この形に確定。「render が別途 scale を渡す」案は不採用）。**glyph cache は物理 px サイズをキーにする**
  （`(codepoint, px_size)`）。
- **bitmap font を `.physical` で拒否しない**: `default_font`（spleen ビットマップ `gui/font.zig:208-215`）は
  `.physical` でも動くが、**nearest 拡大でくっきりにはならない**。crisp が要る UI は**アウトライン
  デフォルトフォント**に切り替える（推奨・R4 のテキスト crisp 化の本命）。

∴ **TASK-167 は「縦センタリング」だけでなく「上記 Font API（論理 measure / 物理 raster・glyph cache）と
アウトラインデフォルトフォント」まで含む依存タスクとして再定義**する（B1=2x ビットマップは任意 scale に
弱く却下）。

### R6. ゲーム系は camera に scale を混ぜず「論理 viewport → 物理 target 変換」を別契約にする

ゲームは gui を通さず fb へ直接描く（`33_camera`: `@memset(fb.pixels)` + `drawSpriteEx(pixels, fb_w, fb_h, …)`、
位置は `gfx.camera` 経由）。ただし `camera.worldToScreen()` だけでなく `screenToWorld()` /
`visibleRect()` / `clampToWorld()` / タイル・sprite の物理描画サイズ / viewport の論理・物理サイズ
すべてに scale 契約が要る（`camera.zig:59-88` は viewport を画面座標として扱う）。

**camera に scale を混ぜると「見えるワールド範囲」が retina 化で変わってしまう**。これを避けるため、
scale は camera 内部ではなく**描画 transform** として分離し、camera の視野計算は論理のまま不変に保つ。

**所有者（確定）**: `libs/gfx` に **`gfx.ScreenTransform`** を新設し、**描画用**の論理→物理変換を**一元化**する
（各アプリが独自変換を再発明するのを防ぐ。P4 の受け入れ条件）:
- `logicalPointToPhysical` / `logicalRectToPhysical`（R4 と同一の floor タイリング規則を共有）
- `logicalViewportToTarget`（camera の論理 viewport → 物理 target）
- `spriteDestRect`（sprite の物理描画 rect）

**入力逆変換は facade（core）専用実装にする（層構成と R2 の統一）**: 依存方向は
`apps → kit → libs → core → platform`（AGENT.md 層構成）なので、**`core/platform.zig` は `libs/gfx` を
import できない**。よって入力の物理→論理逆変換を `gfx.ScreenTransform` に置かず、**facade 自身の実装
（scale で割るだけの自明な変換）で行う**。`gfx.ScreenTransform` は**描画専用ヘルパー**に限定し、入力キュー・
latch・入力逆変換は持たない（入力正規化の唯一の主体は facade＝ R2）。camera は論理 viewport のみを扱い、
`gfx.ScreenTransform` が描画の出口で物理化する。これがゲーム系のチョークポイント。

### R7. 生の直接 fb 描画の継ぎ目は各アプリが吸収する（pixie canvas / patch viz）

`gui.render` / 描画 transform を通らず fb.pixels に直接書く箇所は個別に scale を織り込む:

- **pixie の canvas**（ドット絵。nearest blit が正）: 「論理レイアウト rect → 物理 blit rect」の `×scale` を
  既存の `Zoom`/`screenToCanvas`/`canvasToScreen` 変換に畳み込む。**fb が大きくなった分だけ自動でくっきり**に
  なり、再ラスタライズ問題は無い。
- **patch の可視化帯**（`spec.draw`/`osc.draw`/`meter.draw` が fb.pixels 直書き。`patch/main.zig:2643-2665`）:
  `VIS_H` を単純に `×scale` するだけでは**内部の可視化バッファが高解像度化しない**（`libs/viz` の
  `Spectrogram(width,height)`/`Scope(width,height)` は comptime サイズ）。**描画順を 2 層に分ける
  （確定・P4 受け入れ条件）**:
  1. **層 A（下）**: 可視化データ（spectrogram/scope/meter）を**論理解像度の viz bitmap に描き、帯領域を
     nearest 拡大**して物理 fb へ置く（comptime サイズの viz バッファを scale ごとに作り直さない。
     メモリ・性能据え置き。nearest 拡大で実用上十分という割り切り）。
  2. **層 B（上）**: **ラベルは層 A の nearest 拡大の後に、物理 fb 上へアウトライン（P3 経路）で後描画**する
     （論理帯に含めてから拡大するとラベルまで nearest 拡大されて甘くなるため、必ず拡大後に物理 px で描く）。
  3. **`VIS_H` とキャンバスの論理・物理境界は論理側で管理**し、物理化は R6 `gfx.ScreenTransform` /
     層 A の nearest 拡大の出口でのみ行う（境界計算を二重に scale しない）。

### R8. TASK-157 は暫定・独立の応急処置として先に入れる

objc の `contentLayer` に `magnificationFilter = kCAFilterNearest`（+ minification）を付け、metal と体感を
揃える（**CPU fb crc は不変**＝表示層だけの変更）。ドット絵はくっきり・フォント AA はブロック化する妥協だが、
**R1 の `.physical` が入れば拡大自体が消えて不要になる**。156 の完成前に実機の滲みを止める橋渡し。
併せて swift 単体の滲みを実機で再確認する（コード上は objc と同一設定）。

**R1 との整合（意図的な表示変更）**: このフィルタ変更は `.logical`（既定・現状の唯一モード）の**表示結果を
意図的に変える**（linear 滲み → nearest くっきり。滲みバグの是正）。したがって R1 の「`.logical`＝現状維持」は
**fb レイアウト・API・CPU fb crc の不変**を指し、**OS スクショのピクセル一致までは約束しない**（前述の表注記の
通り）。`.physical` 導入後は 1:1 描画で拡大が消えるためフィルタ選択は無効化される（moot）。

### R9. fb crc bit 不変は条件付きで保証し、回帰テストで固定する

「既定 `.logical` なら fb crc 不変」は次の条件下でのみ成立する。ADR 上の約束でなく**テストで固定**する:
- `.logical` の fb 幅・高さを従来と完全に同一にする。
- **logical 経路を physical 経路から分岐**させる（physical の分岐が logical のバッファ確保・clear・
  resize 順序を変えない）。
- init / resize / clear の順序を変えない。
- nearest filter（R8）は CPU fb ではなく**表示層だけ**に適用する。
- 回帰は macOS objc だけでなく **harness / null backend / 各 backend** を含めて固定する。

### R10. ホットパス影響を測って固定する（bench マトリクスを拡張）

`.physical` の fb は画素数 4x（2x×2x）＋ double buffer メモリ・背景 clear・矩形/画像合成・フォント物理
ラスタライズ・patch viz・キャッシュミス/メモリ帯域も増える。**性能規約（SIMD 3 点セット・clip-hoist・
行連続アクセス）の適用対象**とし、`bench-canvas` だけでなく次を前後比較して notes に記録する:
`gui.render` の logical/physical 比較・フォント描画比較・pixie canvas blit 比較・patch viz 比較を、
**1x / 1.5x / 2x** の各 scale で、**frame time と peak memory** の両方。フォント coverage と viz は別途監査。

**性能上限（受け入れ基準）**: `.physical` 2x で pixie / patch が **60fps を維持**すること（frame budget
16.6ms 内）。peak memory は `.logical` 比で fb double buffer の**増分**（≒ `w*h*(scale²-1)*4*2` bytes）＋ glyph
cache 増分の範囲に収める（青天井の一時確保を作らない）。上限超過は最適化 or 機能削減の判断材料にする。

## 段階プラン

- **P0**: TASK-157（objc nearest、応急）を独立実装（R8）。
- **P1**: platform 契約 — `logicalSize()` / `framebufferSize()` / `contentScale()` / **runtime scale 変更** /
  fb モード（既定 `.logical`）/ **入力の論理座標正規化**（R2・R3。objc 先行）。
- **P2**: gui の変換規則 — `gui.render` に scale 注入 + **半開区間の丸め・clip・image・line thickness**
  （R4。既存 drawLine thickness バグの修正を含む）。
- **P3**: フォント — 論理 measure / 物理 raster の分離 + アウトラインフォント物理 px ラスタライズ
  （R5・TASK-167 拡張）。
- **P4**: アプリ切替 — pixie（canvas 継ぎ目）/ patch（viz 帯・R7）/ `gfx.camera`（論理 viewport→物理
  target 変換・R6）を `.physical` へ。
- **P5**: swift / metal → Linux（x11/wayland）/ Windows（gdi/d3d11）横展開 + 性能回帰（R10）。

## 代替案と却下理由

- **A1（アプリ/gui が物理 px で考える）**: gui の widget・全レイアウト定数・ヒットテスト・マウスという
  面積の大きい層すべてに `×scale` を撒く必要があり、1 箇所の付け忘れが「実機の retina でだけズレる」
  目視でしか気づけないバグになる。A2 は摩擦を gui.render / 描画 transform ＋ pixie canvas/patch viz の
  小さな継ぎ目に閉じ込められる。
- **論理 fb を丸ごと物理へ拡大**: それは現状＝滲み（157）そのもの。くっきりなテキストは得られない。
- **全アプリを物理 fb に強制**: レトロ/ドット絵ゲームは論理解像度の nearest 整数拡大を望むため破綻する。
  → R1 の opt-in で解決。
- **B1（2x ビットマップフォント追加）**: 2x/3x 以外の scale や可変サイズに弱い。アウトライン（R5）が汎用。
- **camera に scale を直接混ぜる**: retina 化で「見えるワールド範囲」が変わる。R6 の描画 transform 分離で回避。

## 影響

- 既存アプリ・examples・harness: 既定 `.logical` で**無改修・fb crc bit 不変**（R9 の条件・回帰テストで固定）。
- pixie / patch: `.physical` へ opt-in で crisp UI 化（P4）。patch viz は R7 で解像度方針確定済み
  （論理描画→nearest 拡大 + ラベルは拡大後にアウトライン後描画）。
- ゲーム作者: `.logical` で従来どおり（レトロは自前バックバッファ nearest 拡大が引き続き自然）、
  `.physical` + `contentScale()` + 描画 transform で高解像度 crisp も選べる。
- TASK-167 は R5 の前提として拡張定義（物理 px ラスタライズ API を含む）し、156 に取り込む。
- 既存バグ（`gui.render` が line thickness を渡していない）を P2 の前提として先に修正する。
