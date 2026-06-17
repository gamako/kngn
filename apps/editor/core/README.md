# editor/core

グラフィックエディタ群（pixie / paintly / tilex / animix …）が共有する再利用可能な抽象。
アプリ非依存（platform / GUI を import しない）。`@import("core")` で `core.zig` の re-export を使う。

## 構成

| ファイル | 役割 |
|---|---|
| `canvas.zig` | `Canvas`（レイヤ配列・合成・座標変換）、`Layer` / `Vec2` / `Rect` |
| `undo.zig` | `StrokeRecorder`（stroke 記録機械）、`UndoStack` / `UndoCmd` / `PixelDiff` |
| `tool.zig` | `Tool`（vtable 抽象）、`ToolEvent` / `ToolPoint`、`Pen` / `Eraser` / `Brush` |
| `io_png.zig` | `encodePNG` / `savePNG`（PNG 出力） |
| `bezier.zig` | 3次ベジェ `Cubic` の評価・適応平坦化、`Vec2f`（TASK-21.13） |
| `path.zig` | `Path`（アンカー + in/out ハンドル）・`hitTest`・`rasterize`（TASK-21.13） |
| `path_editor.zig` | `PathEditor`（ベジェ編集状態機械。pixie が駆動）（TASK-21.13） |

## 不変条件：表示=composite / 保存=raw

`Canvas.composite()` は **表示専用**（白背景に不透明ピクセルを重ねた合成）。
**PNG 保存には raw layer pixels を渡すこと**（`Canvas.layerPixels(idx)`）。
composite を保存すると透明ピクセルが白に潰れ、round-trip 一致が壊れる（TASK-21.6 の学び）。

```zig
// 表示
blit(canvas.composite());
// 保存
try core.savePNG(io, "out.png", canvas.layerPixels(0), w, h, gpa);
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

## 注意・メモリ所有

- `UndoCmd.paint.diffs` は gpa 所有の owned slice。`UndoStack` が pop / `deinit` で free する。
  自分で `onEvent` の戻り値を push せず捨てる場合は `gpa.free(cmd.paint.diffs)` すること。
- `StrokeRecorder` / `Canvas` の幅・高さは一致させる（recorder の dedup ビットマップは w*h）。
- 現状 MVP は単一レイヤ（`layer_idx = 0`）。多レイヤ・Fill・Picker・BlendMode は後続タスク。
