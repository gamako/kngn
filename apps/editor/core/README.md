# editor/core

グラフィックエディタ群（pixie / paintly / tilex / animix …）が共有する再利用可能な抽象。
アプリ非依存（platform / GUI を import しない）。`@import("core")` で `core.zig` の re-export を使う。

## 構成

| ファイル | 役割 |
|---|---|
| `canvas.zig` | `Canvas`（多レイヤ配列・合成・座標変換・レイヤ操作）、`Layer` / `Vec2` / `Rect` |
| `undo.zig` | `StrokeRecorder`（stroke 記録機械）、`UndoStack` / `UndoCmd` / `PixelDiff` |
| `tool.zig` | `Tool`（vtable 抽象）、`ToolEvent` / `ToolPoint`、`Pen` / `Eraser` / `Brush` |
| `blend.zig` | ピクセル合成（`srcOver` 等）。canvas / selection / brush が利用。実装は `libs/pixelops` への facade（TASK-51） |
| `io_png.zig` | `encodePNG` / `savePNG`（PNG 出力） |
| `bezier.zig` | 3次ベジェ `Cubic` の評価・適応平坦化、`Vec2f`（TASK-21.13） |
| `path.zig` | `Path`（アンカー + in/out ハンドル）・`hitTest`・`rasterize`（TASK-21.13） |
| `path_editor.zig` | `PathEditor`（ベジェ編集状態機械。pixie が駆動）（TASK-21.13） |
| `selection.zig` | 矩形選択の操作（clipboard `PixelBlock` / cut・paste・move のピクセル編集）（TASK-44） |

## 不変条件：表示=composite / 保存は用途で使い分け

`Canvas.composite()` は **表示専用**（白背景に不透明ピクセルを重ねた合成）。
**白背景の `composite()` を保存に使ってはいけない**（透明ピクセルが白に潰れ、round-trip 一致が壊れる。TASK-21.6 の学び）。

core の `savePNG` は **渡された pixels をそのまま PNG 化するだけ**。何を渡すかは呼び出し側の用途で決める:

- **単一 raw layer の round-trip**（透明保持）: `Canvas.layerPixels(idx)` を渡す。
- **全 visible layer の合成フラット透明 PNG**（TASK-43 以降の pixie 通常保存）: `Canvas.compositeStraight()`
  を渡す。透明背景に visible layer を opacity 込みで src-over するので透明が保持され、単層・opacity=255 では
  raw と恒等になる（既存 round-trip も保たれる）。
- **注意**: pixie の PNG open はフラット画像を layer0 へ読み込み他 layer を破棄する。**save/open で layer 構造は
  保持されない**（レイヤー保持形式は非スコープ）。

```zig
// 表示（白背景）
blit(canvas.composite());
// 単一 raw layer の保存（透明保持）
try core.savePNG(io, "out.png", canvas.layerPixels(0), w, h, gpa);
// 全 visible layer の合成フラット透明 PNG 保存（pixie 通常保存）
try core.savePNG(io, "out.png", canvas.compositeStraight(), w, h, gpa);
```

## Tool / StrokeRecorder / UndoStack の協調

責務分担:

- **StrokeRecorder**: stroke 記録機械。dedup（同一 stroke 内の再塗りは最初の before のみ）・
  before 観測・Bresenham 線補間を担う。tool 非依存。
- **Tool**: 入力イベント → recorder 駆動のポリシー（どの色で塗るか）。`Pen` / `Eraser` は塗り色が
  違うだけ。vtable は将来 Fill / Picker が挿さる拡張点。
- **UndoStack**: `UndoCmd`（before/after 両持ち）を保持。undo/redo はスタック間移動 + 値適用で可逆。

データフロー（1 stroke）:

```
入力(down) ─▶ tool.onEvent(.down) ─▶ recorder.begin + point
入力(move) ─▶ tool.onEvent(.move) ─▶ recorder.lineTo
入力(up)   ─▶ tool.onEvent(.up)   ─▶ recorder.lineTo + finish ─▶ ?UndoCmd
                                                                  │ 非 null なら
                                                                  ▼
                                                          undoStack.push(cmd)

Undo/Redo ─▶ undoStack.undoOne(canvas) / redoOne(canvas)   // canvas に before/after 適用
全消去    ─▶ undoStack.pushClear(canvas, layer_idx)        // 1 コマンドとして原子的に積む
```

最小の使い方:

```zig
var canvas = try core.Canvas.init(gpa, w, h);
defer canvas.deinit();
var recorder = try core.StrokeRecorder.init(gpa, w, h);
defer recorder.deinit(gpa);
var undo: core.UndoStack = .{};
defer undo.deinit(gpa);

var pen: core.Pen = .{ .color = 0xFFFF0000 }; // canonical BGRA 0xAARRGGBB（赤）
const tool = pen.tool();

_ = tool.onEvent(&canvas, &recorder, gpa, .{ .down = .{ .x = 0, .y = 0 } });
_ = tool.onEvent(&canvas, &recorder, gpa, .{ .move = .{ .x = 9, .y = 4 } });
if (tool.onEvent(&canvas, &recorder, gpa, .{ .up = .{ .x = 9, .y = 4 } })) |cmd| {
    undo.push(gpa, cmd);
}
undo.undoOne(gpa, &canvas); // 取り消し
```

## 新しいツールの足し方

`Tool.VTable`（`onEvent` / `reset`）を実装した struct を作り、`tool()` で `Tool` を返す。
`onEvent` 内で `StrokeRecorder` を駆動し、`.up` で `finish` の戻り値（`?UndoCmd`）を返す。
`Pen` / `Eraser` が最小の実装例（`tool.zig`）。OOM は `@panic`（error union を返さない契約）。

## ベジェ/ベクターパス（TASK-21.13）

`Path` は **ブラシ非依存の独立値**（アンカー + in/out ハンドルの列）。`PathEditor` が編集状態機械
（配置 / ハンドルドラッグ / 後編集 / 点削除 / cancel）を担い、確定（`rasterizeCommit`）で flatten 点列を
`StrokeRecorder` の **brush 経路**（21.11/21.12 の Dab スタンプ）へ流して AA ラスタライズする。
描画色・ブラシ形状（footprint）・不透明度は呼び出し側が渡す（`Path`/`PathEditor` は Brush ツールに依存しない）。

- 出力は破壊的ラスタライズで、確定後 `Path` は破棄する（MVP）。
- **将来の拡張点**: `Path` がブラシ非依存の独立値なので、レイヤ機能導入時に
  `VectorLayer { paths: []Path }` として保持でき、**再描画・ブラシ後切替・確定後の再編集**へ拡張できる。
- pixie 側のプレビュー描画（`bezier_overlay.zig`）と入力アダプタ（`bezier_input.zig`）は GUI/platform 依存
  のため core には置かない（core は数学・データ・状態機械・rasterize のみ）。

## 範囲選択（TASK-44）

矩形選択の MVP。selection は `Canvas.selection: ?Rect`（矩形のみ。投げ縄/ワンドは非スコープ）。
`selection.zig` が矩形ユーティリティ（`rectFromPoints` / `clipRect`）・clipboard（`PixelBlock`）・
cut/paste のピクセル編集・フロート移動用の純描画ヘルパ（`renderBlockOverBase` / `layerMatchesRender` /
`diffCmd` / `clearRectInBuf`）を担う。

- **描画制約**: `Canvas.selection` が非 null のとき、`StrokeRecorder.point` / `applyCoverage`（＝実描画
  ホットパス）と `Canvas.drawPixel` は選択範囲外のピクセルを描かない。`selection == null` は 1 分岐で
  素通り（オーバーヘッドゼロ・追加バッファ無し）。
- **cut/paste は `canvas.layerPixels` へ直接書き込み**、selection ゲート付きの `StrokeRecorder` は
  通さない（さもないと貼付先が選択範囲外だとゲートに握り潰される）。適用と同時に既存
  `UndoCmd.paint`（before/after の PixelDiff 列）を生成して返すので可逆（`pushClear` と同じ形）。
- **paste のブロック配置は `Blend{replace, over}` で切替**（`pasteCmd` 引数）: `replace`=そのまま上書き
  （透明部も配置先を消す）、`over`=`blend.srcOver` 合成（透明部は配置先を残す）。pixie の既定は `over`
  （透明を保持）で右ペインのトグルで切替。cut の元領域は透明（0）へ。
- **move はフローティング（遅延確定）**: pixie 側 `selection_input` が **Float キャッシュ**（`base`=移動元を
  0 クリアしたレイヤー / `block`=持ち上げた内容 / `rect` / `layer_idx` / `render_mode`）を持つ。canvas の
  レイヤーは常に最終形（`base + block@rect`）に保たれるので、表示/保存/copy/probe/undo は普通にレイヤーを
  読むだけでよく **確定トリガーは不要**。ドラッグ中は実レイヤーを変えず `preview_canvas` へ
  `renderBlockOverBase` で表示し、release 時だけ実レイヤーへ焼いて `diffCmd` で 1 ドラッグ分の `UndoCmd.paint`
  を作る。**release で確定せず Float を保持**するので、選択を作り直すまで何度でも再配置できる（再ドラッグは
  Float を再利用＝再キャプチャしない）。移動開始時に「同一レイヤー / フロート矩形=現選択 / レイヤー内容=
  `base+block@rect`」が崩れていれば（外部編集・選択変更等）`layerMatchesRender` 判定で re-lift する（単一地点
  での無効化。copy/cut/paste/undo 等に破棄を散在させない）。
- **selection 矩形そのものは undo 対象外**（編集アプリの慣習）。undo されるのはピクセル変更（cut/paste/move）
  のみ。マーキー作成/解除/移動後の選択枠更新は undo に積まない（move を undo するとピクセルは戻るが選択枠は
  移動先に残り得る＝既知の軽微な癖）。
- pixie 側の入力（`selection_input.zig`）と overlay（`selection_overlay.zig`。マーチングアンツ）は
  GUI/platform 依存のため core には置かない（bezier と同じ独立経路）。

## 注意・メモリ所有

- `UndoCmd.paint.diffs` は gpa 所有の owned slice。`UndoStack` が pop / `deinit` で free する。
  自分で `onEvent` の戻り値を push せず捨てる場合は `gpa.free(cmd.paint.diffs)` すること。
- `StrokeRecorder` / `Canvas` の幅・高さは一致させる（recorder の dedup ビットマップは w*h）。
- 多レイヤは実装済み（TASK-43。`Canvas` の `layers` / `selected_layer` + `addLayer` / `insertLayer` /
  `deleteLayer` / `moveLayer` / `selectLayer`、レイヤ opacity / visibility。描画は選択レイヤ対象）。
  Fill / Picker / レイヤーブレンドモードは後続タスク。
