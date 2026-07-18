# TASK-106.2 graph relay（NodeId）

## 要約

patch のグラフ編集 action を netsync relay 化し、runtime `DynGraph.Handle` と wire/保存用の安定 `NodeId` を分離した。pixie TASK-94 の `LayerId` と同型（`enum(u64)`、`0=invalid`、単調増加・再利用なし）。

## なぜ Handle を wire に載せないか

- `DynGraph` の handle は空き slot の低位から再利用される（削除→grace→reclaim）
- VPRJ load / SYNC の `applyGraphReplace` は保存時 handle を無視して新規割当する
- よって peer 間・save/load 跨ぎの参照には不適

## wire 契約

| action | policy | args |
|---|---|---|
| `add_node` | `.relay` | `<kind> <x> <y>`（成功応答 `ok id=#N`） |
| `remove_node` | `.relay` | `#<id>` |
| `connect` | `.relay` | `#src <out> #dst <in> [#detach <in>]` |
| `disconnect` | `.relay` | `#<id> <in>` |
| `move_node` | `.relay` | `#<id> <x> <y>`（drag 中は local preview、mouse-up のみ relay） |
| `add_macro` / `remove_macro` | `.relay` | atomic 1 COMMIT（primitive 列へ展開しない） |
| `select_node` 等 | `.local_only` | wire に載せない |

netsync 中の bare runtime handle は `code=id_required`（detail: `use #<id> from digest patch during netsync`）。
stale `#id` は `unknown_node_id`。group synthetic handle は `group_handle_not_wireable`。
client の `awaiting_sync=1` 中 PROPOSE は `session_not_ready`。

canonicalize hook（`action_registry` 既存契約）が router 前に `#id` へ正規化する。

## VPRJ

- schema 2: `NIDM`（`next_node_id` u64）+ `NREF`（saved_handle↔NodeId）
- `NPRM`（TASK-143）とは別 chunk。未知 chunk skip 維持
- schema 1 / PTCG: node 出現順の決定的 fallback 採番

## macro / Ledger

- `add_macro` / `remove_macro` は 1 publish の atomic action（preflight で `MAX_MODULES` 超過を拒否）
- `group.Ledger` は publish 対象外の UI 台帳。折りたたみ・表示位置は local-only

## undo

構造 action は relay するが `undoable=false`（106.4 まで逆操作形式を別設計）。pixie TASK-94 構造 op MVP と同方針。

## digest

`digest patch` は NodeId 昇順・edge キー順の topology JSON。camera/fb は equality 対象外。1024B 超過時は `trunc=1`。

`snapshot patch` は digest と独立に全 nodes/edges + layout を raw JSON で返す（1024B 制限なし。lofi 既定グラフでも valid JSON）。

## palette / wire kind alias

- `step_seq`（drum）: `ModuleKind` 既定 `.{}`（palette primitive と同一）
- `step_seq_bass`: wire 専用トークン。solo palette と同じ bass 初期値（`kind=.bass`, `octaves=2` 等）で `dyn.add`

## selected の既知挙動

palette からの primitive / step_seq_bass 追加は、solo/host の `ok id=#N` 応答で `app.selected` を設定する。
client の `proposed` 応答時は COMMIT 適用前のため未選択のまま（macro も同様に client では action 未適用）。

## awaiting_sync 中のエラーコード精度（既知制約）

canonicalize は router 前にローカルで `#id` 解決を試みる。`awaiting_sync=1` のとき SYNC 未適用で id 表が空/不一致だと、`session_not_ready` より先に `unknown_node_id` になりうる。
`proposeToHost` の `session_not_ready` は、canonicalize を通過した PROPOSE 経路で効く。運用上は `digest netsync` で `awaiting_sync=0` を待ってから graph action を送る。

## E2E 待機（オーケストレータ向け）

固定 sleep は port file 待ち以外禁止。`digest netsync` で `awaiting_sync=0` / `last_seq` を待ち、両 peer の stable graph digest を比較する。
