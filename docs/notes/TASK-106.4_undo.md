# TASK-106.4 patch undo/redo

## 方式

逆操作 + 値スナップショットのハイブリッド（replay 不採用）。

- 構造編集（add/remove/connect/disconnect/move/macro）: 固定長 `PatchUndoEntry` に before-state を capture し inverse 適用
- pattern / parameter / song / seed: 変更前値を保存し再 publish
- `pattern_state` / `song_play` / `song_goto` / project load-save / select / observe: undo 対象外

payload は `apps/patch/undo.zig` の `PatchUndoStore`（128 件リング、`UndoRef=gen`）。操作毎の heap alloc は無し。store 本体（~1.16MiB）は起動時 heap（`create`/`destroy`）— App スタック常駐だと `cmd_log` と合わせて Windows 既定 1MB stack を超えるため。

## netsync

pixie 同型: solo は `cmd_exec.undoOne/redoOne(.local_user)`、session 中は `routeAction("undo"/"redo")` → `.undo_own`/`.redo_own` → `PROPOSE_REVERT`/`COMMIT_REVERT`。host 検証は既存 `validateRevertTarget`（変更なし）。

`COMMIT_REVERT` wire は `seq++target_seq` のまま。edge/param は載せない。各 peer が remote commit 適用時にも同じ before-state capture を行い payload を一致させる。

## actor 統一（`.local_user`）

GUI（Cmd+Z）と harness / MCP 操作を **同一 undo 対象**に揃えるため actor は `.local_user` に統一した。

trade-off: GUI 操作と harness/MCP 操作が互いに undo を奪い合う。分離（例: `.local_agent` を harness 専用に戻す）は将来タスク。

## GUI semantic action 統一（スコープ限定）

Fable レビュー確定: 次の **2 経路のみ** semantic action 経由に統一する。

1. inline / macro grid の **生成 StepSeq** クリック → `toggle_step`
2. inspector slider の **release** → `set_param`（drag 中は preview、release で 1 undoable）

`slider_drag_before` は単一 Optional（同時複数 slider drag の UI は無く、1 本分のみ保持する制約）。

### undo 対象外として残す直接経路（将来拡張可）

- transport panel の slider / mute 直接書き込み（`transportParamChanged` / `transportMuteChanged`）
- standalone（非生成）StepSeq の atomic mask トグル（CommandLog 非記録のまま）
- 折りたたみトグル・カメラ・選択など UI-local 操作

## RT 契約

capture / inverse / `dyn.publish` / Mailbox publish はイベント時のみ。`lofi.render` / `applyControls` / `DynGraph.processBlock` に undo 用 alloc/lock/分岐を追加しない。

## redo と NodeId（fresh id 方式）

**採用: pixie 同型の fresh id 再実行。** redo は通常の `add_node` / `add_macro` 再実行として、全 peer が `allocNodeId` / `assignIds` で単調採番する（COMMIT 全順序により決定的一致）。`next_node_id` は減少させない。

### 撤回した復元方式とその発散シナリオ

当初は redo 時に元 NodeId を復元する経路（`reclaimAddNodeSnap` / `lookupRedoAddNodeSnap` + `Executor.currentRedoTarget`）を置いていたが、次の 3 シナリオで peer 発散する構造欠陥があり **撤回**した。

1. **id 盗用**: add → undo → 同 kind/座標の新規 add が undone ノードの id を reclaim で再利用（実機で #31 再利用を確認）
2. **add_macro に fallback 無し**: 受信 peer 側で restore 経路が揃わず必ず発散
3. **late-join**: CommandLog が空の peer は fresh alloc に落ち、復元を期待する peer と発散

### undo 側の NodeId 復元は維持

`remove_node` / `remove_macro` の undo は capture した元 NodeId を `restoreNodeId` で復活させる（各 peer の対称 capture で決定的）。

### redo 後の古い payload

redo で新 id になった後、旧 id を参照する undo payload（例: 旧ノードへの `move_node` / `connect` / node-mode `param`）は `canUndoPayload` の生存チェックで `canUndo=false`（silent no-op 排除）。

### グラフ構造系の検証範囲

`PatchUndoStore` の構造 payload round-trip と `canUndoPayload` 生存分岐は単体テスト。`main.zig` オーケストレータ全体（DynGraph + ledger + netsync）の E2E は既存 headless harness 経路でカバー（本タスクの単体では main 依存を引かない）。
