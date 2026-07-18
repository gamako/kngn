# TASK-134 pixie: PNG drop を現在ドキュメントへ新レイヤー挿入

## 1. 現状コードの読解結果

- `apps/editor/apps/pixie/main.zig:1472` の `handleFileDrop` は、単一ファイルかつ拡張子が `.png` の場合、netsync でなければ `doOpenPath(path)` を呼ぶ。複数 drop、PNG 以外、netsync 中はそれぞれ既存の reject/no-op 経路を通る。
- `apps/editor/apps/pixie/main.zig:1432` の `doOpenPath` は `png.decodePNGFile` で `PNGImage` をデコードし（`libs/png/src/lib.zig:54-60,203-210`）、`resetCanvasToSingleLayer` を呼んでドキュメントを 1 frame・1 raster layer へ差し替える。その後 `layerPixels(0)` を透明で埋め、PNG の幅・高さと `CANVAS_W/H` の小さい方まで各行を `@memcpy` する（`main.zig:1444-1453`）。PNG は canonical BGRA `0xAARRGGBB` で、canvas と同じ画素レイアウトなので変換はない。
- `apps/editor/apps/pixie/main.zig:2310` の `resetCanvasToSingleLayer` は `Document.resetToSingleBlankLayer` と選択フロート/history invalidation を組み合わせる。 `libs/paint/src/document.zig:1306-1340` の reset 実装は既存 cel、layer、undo/redo を破棄して 1 layer の blank document を再構築するため、File > Open の差し替え挙動を担う。
- `apps/editor/apps/pixie/main.zig:1957` の `doAddLayer` は `editingBlocked` を確認して `Document.addLayer` を呼び、新規 layer を末尾へ追加し、新規 layer を選択する。 `libs/paint/src/document.zig:1000-1018` の `addLayer` は active view の blank layer、現在 frame の blank cel を用意した後、`.layer_add` を undo stack へ 1 回 push する。既定の `LayerDef` により raster・visible・opacity=255 となる。
- `apps/editor/apps/pixie/main.zig:2316-2330` の `syncPreviewCanvas` は active canvas の layer 数・画素・可視性・opacity を preview canvas へ同期する。PNG の直接書き込み後はこれを呼ぶ必要がある。
- `libs/paint/src/canvas.zig:455-461` の `layerPixels` は active view の可変画素 slice を返し、同時に dirty を立てる。 `libs/paint/src/document.zig:685-699` の `commitActiveLayerToCel` は active view の画素を現 frame の cel へ全面書き戻すが、undo Op は追加しない。これは現在の `doOpenPath` が採用している「active view へ書く → cel へ同期する」流儀である。
- `resetCanvasToSingleLayer` を経由するのは `doOpenPath` の File > Open/host open 系だけに残し、drop は reset せず、`doAddLayer` 後に同じ左上クロップ/パディングを新 layer へ適用する。

## 2. undo 1 手で戻す設計

このリポジトリに `UndoCmd` という名前の型はなく、実体は `libs/paint/src/document.zig:146-216` 付近の `Document.Op` union と `UndoStack` である。採用案は新しい PNG 複合 Op を追加せず、既存の `.layer_add` 1 件を「新規 layer と、その layer の完成済み画素」の undo 単位として使う。

1. PNG を先に decode し、decode 失敗では document を変更しない。
2. `doAddLayer()` を呼ぶ。これで `.layer_add` が 1 件だけ push される。
3. 選択された新 layer の `layerPixels` を透明化して PNG を左上へクロップ/パディングする。 `pushPaintOp` は呼ばない。
4. `commitActiveLayerToCel` で active view の完成画素を cel へ書き戻す。

`.layer_add` は push 直後には `row=null` だが、undo の `applyBefore(.layer_add)`（`libs/paint/src/document.zig:1523-1529`）で layer を除去し、`removeLayerRow`/`captureAndReleaseSlots`（`document.zig:841-855`）を通じてその layer の cel と画素を `CelSetSnapshot` として捕捉する。したがって PNG 画素を cel へ同期してから undo すれば、undo は layer 構造とその画素を一体で除去し、redo の `applyAfter(.layer_add)`（`document.zig:1624-1632`）は同じ画素を復元できる。 `Document.undoOne` も apply 後に `resyncActiveView` を行う（`document.zig:1342-1358`）。

`.layer_add` の payload に初期画素を新設する必要はない。既存の複合 Op の前例は `.layer_merge_down`（`document.zig:190-199`）で、下位画素の before/after と削除 layer を 1 Op に保持しているが、今回の add は既存の layer-row snapshot がすでに cel/画素所有権まで表現しているため、より単純な既存経路を採用する。 `layerPixels` 後に `pushPaintOp` を追加すると `.layer_add` + `.paint` の 2 push になり、最初の undo で PNG 画素だけが戻って空 layer が残るため禁止する。

drop は CommandLog の action dispatch ではなく OS/harness event の直接処理なので、追加された `.layer_add` は既存の未記録編集検出（`main.zig:1834-1843`）で local user 所有へ確定され、solo の Cmd+Z は最上位の legacy `doc.undoOne` 経路でこの 1 Op を戻す。

## 3. netsync ガードの位置

`handleFileDrop` の既存順序（`apps/editor/apps/pixie/main.zig:1473-1485`）を維持する。単一 PNG 判定の後、PNG decode・layer add・画素書き込みより前に `platform.netsyncActive()` を確認し、現在の `setSaveMsg("netsync: ... RejectedWhileSynced")` をそのまま使う。netsync 中は remote action へ route せず、I/O も document 変更も行わない。

新しい import helper 自体は drop 専用の private helper とし、同じ event 内で二重に状態が変わらない前提に依存する。File > Open の `doOpenPath` にはこの guard を追加せず、従来の host/document open 経路と差し替え挙動を保つ。

## 4. 変更する関数と差分の骨子

対象は主に `apps/editor/apps/pixie/main.zig`。PNG のコピー処理を重複させないため、既存の `doOpenPath` の行コピー部分を追加の undo push を行わない private helper へ抽出する案を採用する。helper 抽出は画素結果を変えず、File > Open の reset・current_path・history clear は変更しない。

提案する helper:

```zig
fn copyDecodedPngToLayer(self: *App, layer_idx: usize, img: *const png.PNGImage) void {
    const pixels = self.canvas.layerPixels(layer_idx);
    @memset(pixels, 0);
    const iw: usize = img.width;
    const rows = @min(@as(usize, img.height), @as(usize, CANVAS_H));
    const cols = @min(iw, @as(usize, CANVAS_W));
    for (0..rows) |y| {
        @memcpy(pixels[y * CANVAS_W ..][0..cols], img.pixels[y * iw ..][0..cols]);
    }
    self.syncPreviewCanvas();
    self.doc.commitActiveLayerToCel(self.gpa, layer_idx);
}
```

実装時の呼び出し方は次のとおり。

- `doOpenPath`: 現在の decode → `resetCanvasToSingleLayer` → `copyDecodedPngToLayer(0, &img)` → `current_path` 更新の順を維持する。reset により undo/redo が空になる点も変更しない。
- 新規 `doImportPngAsLayer(path)`（名前は同等の明確な private 名でよい）: `editingBlocked` を `doAddLayer` に通し、`decodePNGFile` を先に実行して `defer img.deinit`、`_ = try doAddLayer()`、`const layer_idx = self.canvas.selected_layer`、`copyDecodedPngToLayer(layer_idx, &img)` の順にする。drop asset は current document の path を変更しない。完了メッセージは `Inserted: <basename>` など、既存の Load との区別が分かる文言にする。
- `handleFileDrop`: 既存の count/ext/netsync 判定はそのままにし、最後の `self.doOpenPath(path)` だけを `self.doImportPngAsLayer(path)` へ置き換える。エラー時の `Load failed` 表示経路も維持する。
- `doAddLayer`、`resetCanvasToSingleLayer`、File > Open の `doOpen`/`requestPngImport`/`hostNewDocument` は、drop と同じ helper を抽出する場合を除き挙動を変更しない。リサイズ、複数ファイル、`.pix` は追加しない。

## 5. ホットパス宣言

PNG drop/import はイベント時のみ（drop 1 回につき 1 回）。最大 256×256 の透明化・行コピー・cel 同期を行うが、フレーム毎・render thread・RT 経路には入らないため、性能規約の SIMD/ベンチマーク対象外とする。

## 6. テスト/E2E 手順

既存 asset の `examples/image/usako.png` を使う。実ファイルは 64×64 RGBA PNG で、256×256 固定 canvas に収まり、クロップ確認にも使える。まず既存 layer に決定的な stroke を入れてから drop し、drop 前後の layer 0 の crc/nz を比較する。

headless replay の雛形（例: 実装時に `apps/editor/apps/pixie/task_134_file_drop_e2e.txt` として追加）:

```text
step 3
action set_tool pen
action set_color FF0000
action stroke 10 10 60 10 60 60
step 2
digest canvas
inject file_drop examples/image/usako.png
step 2
digest canvas
assert canvas contains layers=2
snapshot fb /tmp/task-134-after-drop.png
inject key_down Z cmd
step 2
digest canvas
assert canvas contains layers=1
snapshot fb /tmp/task-134-after-undo.png
quit
```

実装時の E2E wrapper は `VP_HARNESS_HEADLESS=1`、`VP_HARNESS_SCRIPT=<script>`、`VP_HARNESS_OUT=<out>` で pixie を起動する。 `digest canvas` の drop 前後について、次を機械的に assert する。

- drop 前の `l0{...crc=...,nz=...}` と drop 後の `l0{...}` の crc/nz が一致する（元 layer 保持）。
- drop 後の `l1{...}` が存在し、`nz` が `1` 以上である。nested field は harness の `contains` 規約に従い、初回実測した crc/nz を exact fragment に焼き込むか、wrapper の正規表現 `l1\{[^}]*nz=[1-9][0-9]*` で検査する。
- undo 後の `digest canvas` が `layers=1` で、残った `l0` の crc/nz が drop 前と一致する。必要に応じて `digest undo` も drop 前後・undo 後に採取し、drop が 1 push、undo で depth が 1 減ることを確認する。
- `snapshot fb` は drop 後に元の stroke と usako が同時に見えること、undo 後に usako が消え元の stroke が残ることを目視確認する。

併せて `zig build test-core` と `zig build -Dplatform=objc build-pixie`（使用 backend に合わせる）を実行し、File > Open の既存 `apps/editor/apps/pixie/appshell_e2e.sh` PNG open ケースが従来どおり document 差し替えであることを回帰確認する。invalid PNG/存在しない path では layer 数が増えないこと、netsync 中は reject message だけで canvas が不変であることも確認する。

## 7. リスク・plan の曖昧点

- `Document.Op` の `.layer_add` は任意位置 revert の対象外だが、drop は netsync reject で solo の最上位 legacy undo を使うため今回の 1 手 undo には適合する。将来 drop を relay 対象にする場合は別設計が必要で、今回は扱わない。
- PNG の decode を layer add より前に行わないと、壊れた/読めない PNG で blank layer だけが残る。decode 先行を実装上の不変条件とする。
- `layerPixels` の active view への直接書き込みだけでは cel_pool・保存データ・undo/redo 復元に反映されない。必ず `commitActiveLayerToCel` を同じ helper の末尾で呼ぶ。
- `doAddLayer` は新 layer を末尾へ追加して選択するため、挿入位置は既存の Add Layer semantics（現在 layer の直上ではなく末尾）を踏襲する。位置変更やレイヤー名変更はスコープ外。
- 新 layer の opacity、visible、kind は `Document.addLayer` の既定値（255、true、raster）をそのまま使う。PNG の透明画素は 0 のまま保持し、premultiplied 化・スケール・リサイズは行わない。
- drop は current document の path を PNG asset へ変更しない。編集 dirty は通常の未記録 `.layer_add` 検出（`main.zig:1834-1843`）に任せるが、実装で早期 return を追加する場合もこの検出を妨げない。
- helper 抽出時に `doOpenPath` の reset、history invalidation、current_path ownership を誤って共通化しない。共通化するのは decoded PNG の layerPixels 書き込み・preview 同期・cel 書き戻しだけとする。
- 1 回の drop で `doAddLayer` 以外の undo push を発生させない。特に `pushPaintOp` を追加しないことをレビュー時の必須確認項目とする。
