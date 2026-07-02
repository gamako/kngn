# ADR-006: apps/editor/core の OOM ポリシー（@panic 維持）

**Status:** 承認
**Date:** 2026-07-03
**Category:** エディタ・エラーハンドリング・API 設計

## 概要

`apps/editor/core`（Canvas / UndoStack / StrokeRecorder / Selection / Path）のメモリ確保失敗（OOM）は
**`catch @panic("…: OOM")` で即時停止する現行ポリシーを維持**する（TASK-60 でユーザーと合意）。

**決定内容（要約）:**

- core の公開 API は OOM を **error union で伝播しない**。確保失敗は `@panic` で即時停止する。
- 例外は「呼び出し側が自然に `try` できる初期化・生成系」（`Canvas.init` / `allocBlankLayer` /
  `encodeGpl` 等、既に `!T` を返すもの）で、これは現状どおり error を返してよい。
- 新規に core へ追加するコードもこのポリシーに従う（イベント処理・描画経路の途中で
  error union を導入しない）。panic メッセージは `"<場所>: OOM"` 形式で統一する。

## 背景

- core は「アプリ非依存の再利用コア」と位置づけられる一方、現実の利用者は pixie（編集アプリ）のみで、
  編集操作の途中（stroke 確定・undo push・selection 適用）で OOM からリカバリする現実的な手段がない。
  中途半端に伝播すると「半分適用された stroke」のような不整合状態の巻き戻しが必要になり、
  かえって複雑さと退行リスクが増える。
- `Tool.onEvent` → `StrokeRecorder.finish` の系は「finish は error を返さない」設計
  （イベント駆動の状態機械を error で中断しない）を前提としており、伝播化はこの設計の見直しを強制する。
- error 伝播化は core 公開 API のシグネチャ変更が広範囲（pixie の全呼び出し元 + 入力アダプタ）に波及する。
  外部利用者（tictactoe 型の consumer）が現れて必要になった時点で改めて設計すればよい（YAGNI）。

## 検討した選択肢

1. **@panic 維持（採用）** — 上記のとおり。アプリ組込み前提では OOM は回復不能とみなすのが実態に合う。
2. **error 伝播化** — ライブラリとしては Zig らしいが、シグネチャ変更の波及と
   「部分適用状態の巻き戻し」設計が必要になり、現時点では費用対効果が見合わない。

## 影響

- `undo.zig` / `path.zig` / `bezier.zig` / `selection.zig` / `canvas.zig`（moveLayer）の
  `catch @panic("…: OOM")` は意図された設計であり、レビューで指摘対象にしない。
- 将来 error 伝播が必要になった場合（外部ライブラリ利用等）は、本 ADR を Supersede する
  新しい ADR を起こしてから着手する。

## 参照

- backlog TASK-60（相談と合意の記録）
- `apps/editor/core/undo.zig` 冒頭のポリシーコメント（本 ADR を参照するよう更新済み）
- `apps/editor/core/README.md`（方針の要約を記載）
