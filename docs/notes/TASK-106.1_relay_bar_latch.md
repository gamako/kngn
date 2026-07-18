# TASK-106.1 relay / bar-latch / evolve authority

## 要約

modular 系の共有状態 action を netsync `.relay` へ昇格し、evolve は host-only mutate + 内部 action `pattern_state` の COMMIT で client へ生成結果を配布する。`pattern` の bar 量子化は「次の自プロセスの bar」割り切り（同一 bar 適用は保証しない・最終状態一致）。

## policy 表（TASK-106.1 後）

単一ソース: `apps/patch/gen_actions.zig` の `PATCH_NETWORK_POLICIES`（register + 単体テストが参照）。

| action | policy | 判断 |
|---|---|---|
| `select_node` / `observe_param` | `.local_only` | peer-local UI |
| `add_node` / `remove_node` / `connect` / `disconnect` / `move_node` / `add_macro` / `remove_macro` | `.relay` | graph 共有（106.2） |
| `set_param` / `set_mute` / `set_lock` / `set_evolve` / `toggle_step` / `set_pitch` | `.relay` | 音楽・param 共有 |
| `seed` / `pattern` / `phrase_capture` / `chain_set` / `song_*` | `.relay` | 生成・Song 共有 |
| `save_*` / `recipe_save` | `.local_only` | ファイル出力のみ |
| `load_graph` / `load_pattern` / `load_project` / `recipe_replay` | `.reject_when_synced` | ローカル内容での無通知発散を遮断 |
| `render` | `.reject_when_synced` | session 中の offline 複製は host 変異ストリームを再現できない（solo は従来どおり可） |
| `pattern_state` | `.reject_when_synced` | host 内部のみ `commitHostAction` で発行。client PROPOSE は汎用 `not relayable`（framework は action 名を解釈しない） |

## bar-latch

| 操作 | 適用経路 | タイミング |
|---|---|---|
| `seed` | `pending_seed` atomic | 次の自 bar |
| `pattern` | `pattern_db` → `pending_bar_cmd`（`quantize_bar=true`） | 次の自 bar |
| `toggle_step` / `set_lock` / `set_evolve` / `set_pitch` | `pattern_db` | 次の RT block |
| `set_param` / `set_mute` | atomic / `param_db` | 次の RT block |
| Song 系 | `song_db` / atomics | 既存どおり |
| `pattern_state` | `pattern_db`（`quantize_bar=false`） | host 結果を即時反映 |

host/client の bar 位相は同期しない。発音開始の完全一致は要求せず、最終 mask / mutation count 一致を判定する。

## evolve

- host（または netsync 無効）: 既存 `mutatePattern` + `applyDensityTarget` を bar 境界で実行
- client（netsync 中）: mutate/density を実行しない（`Controls.evolve_host_authority=0`）
- host main thread が次のいずれかで `platform.commitHostAction("pattern_state", ...)` を発行:
  - `mutation_count` が前回 broadcast から変化した
  - peer 数が増えた（join 検出。新規 client が次変異を待たず最新 pattern を受け取れる）
- client は `pattern_state` → `pattern_db.publish` + `remote_mutation_count`（digest `mut` に反映）
- `pattern_state` は recipe 抽出から除外（意味的 action 列の汚染防止）
- TASK-106.4: `pattern_state` は undo 対象外（host 生成の収束用状態。ユーザー intent ではない）

bar 境界順序は不変: **seed → song → pending_bar_cmd → mutate → density**

## set_param NodeId

wire: `#<NodeId> <canonical-param-name> <value>`。bare handle は netsync 中 `id_required`。transport 2 引数形式（`tempo 128`）は従来どおり。NPRM / integrated StateSync とは別経路を追加しない。

## RT 契約

`applyControls` / `processBlock` / `LofiPatch.render` / `maybeEvolve` に network IO・alloc・lock・CommandLog 操作を追加しない。host snapshot 生成は main thread のイベント境界のみ。
