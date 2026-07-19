# ADR-008: frame pacing API（beginFrame/waitFrame）と fatal 状態分離

**Status:** 承認（API 形・状態遷移・harness 整合・移行方針を確定。全 backend の実装は follow-up タスク）
**Date:** 2026-07-05
**Category:** プラットフォーム API・レンダリング・フレーム制御

## 概要

[ADR-005](005_platform_support_tierとframe_pacing契約.md) が「方針のみ」と留保した2点を、Zig API として確定する。

1. ゲーム向け pacing 本体: blocking wait を含む `beginFrame(wait)` / `waitFrame(timeout)`
2. `lockFramebuffer() == null`（frame slot unavailable・retry 可）と **fatal**（device lost / window 破棄 /
   backend fatal）の分離

**決定内容（要約）:**

- 新 API は **`Window` method** として追加する: `window.beginFrame(wait: FrameWait) FrameResult` /
  `window.waitFrame(timeout_ns: u64) WaitResult`。
- null と fatal は **`FrameResult` tagged union**（`.framebuffer(Framebuffer) / .unavailable / .fatal(FatalReason)`）
  で分離する。
- **fatal は sticky state**（`Window` 内部 1 個。最初に検出した理由を保持）として扱う。`present()` を含む
  **どの呼び出し経路で検出されても**、以後の `beginFrame`/`waitFrame`/`nextEvent`（`.fatal` event）/
  `pollEvents`（false 固定）で一貫して可視化する。
- **現行 `lockFramebuffer() ?Framebuffer` / `present() void` は互換のため不変更**。fatal 発生後も
  `lockFramebuffer()` は引き続き `null` を返す（シグネチャ上 fatal を表現できないため）。ただし
  **`null` 単独の意味を fatal 通知としては使わず**、`nextEvent()` の `.fatal` event と `pollEvents()==false`
  を**必ず併用**して fatal を可視化する（「null degrade のみ」＝event/pollEvents 側の可視化を伴わない案は
  不採用。理由は後述）。**通常状態の `null` は retry 可能な frame slot unavailable、sticky fatal 確定後の
  `null` は「もう frame は来ない」という terminal no-frame** であり、fatal そのものの正は
  常に `nextEvent`/`pollEvents` 側にある。
- harness の `present = frame 確定点` / `pollEvents = step gate` / 仮想クロックは**変更しない**。
  `beginFrame(wait)` 単独ループは harness step gate の対象外と明記する。
- 全 backend への実装（best-effort backend の no-op 化含む）と、TASK-35.2（D3D11 device lost）/
  TASK-35.3（D3D11 waitable swap chain）の接続は **follow-up タスク**とする。

## 背景

- ADR-005 は support tier と frame pacing 契約（frame availability / buffer ownership / present semantics /
  PresentMode）を定義したが、「blocking wait を含む pacing 本体」と「null と fatal の分離」は API 形を
  確定せず follow-up（本タスク）に委譲した。
- 受け皿として TASK-35.2（D3D11 device lost 復帰。「回復不能時の caller 通知は TASK-38 の fatal API に整合させる」）
  と TASK-35.3（D3D11 waitable swap chain。「TASK-38 の beginFrame/waitFrame API が決まったらそれに接続する」）が
  作成済みで、いずれも本 ADR の決定待ちである。
- 現行 facade（`core/platform.zig`）の `Window.lockFramebuffer()` / `Window.present()` は外部消費者
  （`tictactoe` リポジトリが `.path` 依存で直接使用）がいるため、シグネチャ・意味論を破壊できない。
- harness（`core/control/harness.zig`）は facade の `pollEvents`(=step gate `pollGate`) / `nextEvent` /
  `lockFramebuffer`(`onLock`/`onLockMiss`) / `present`(=frame 確定点。`onPresent` で `frame_index++`) /
  `getTime`(=`frame_index/60`) を interpose 済み。新 API はこの決定論を壊さずに乗せる必要がある。

## 用語

| 用語 | 定義 |
|---|---|
| **frame slot unavailable** | 描画可能な backbuffer が今は無い retry 可能状態（ADR-005 既定義）。`FrameResult.unavailable` / 既存 `lockFramebuffer() == null` で表す。 |
| **fatal** | device lost / window 破棄 / backend fatal error 等、**復帰を試みても継続不能**な状態。retry では解決しない。 |
| **sticky fatal state** | `Window` が内部に保持する「最初に検出した fatal 理由」。一度立つと `false`/`.unavailable` に戻らず、以後の全 API 呼び出しに一貫して現れる。 |
| **frame 確定点** | `present()` 呼び出し時点（ADR-005 既定義。harness の `frame_index` 基準）。本 ADR でも不変。 |
| **手動描画 API** | `lockFramebuffer`/`present`/`beginFrame`/`waitFrame` 等、caller が明示的にフレームを取得・確定する経路。callback 方式（`platform_run`/`FrameCallback`）とは別系統。 |

## 決定

### 1. API 形（AC#1）

```zig
pub const FrameWait = enum { nonblocking, wait };

pub const FatalReason = enum {
    device_lost,       // GPU/描画デバイスの喪失（D3D11 DEVICE_REMOVED/RESET 等）。復帰試行後の不能。
    window_destroyed,  // window が既に破棄されている状態での操作
    backend_fatal,     // 上記に分類できない backend 内部の致命的エラー
};

pub const FrameResult = union(enum) {
    framebuffer: Framebuffer, // 描画可能。ADR-005 の buffer ownership 契約に従う
    unavailable,              // frame slot unavailable（retry 可能。既存 null 相当）
    fatal: FatalReason,       // 復帰不能。retry しても解決しない
};

pub const WaitResult = union(enum) {
    ready,             // 描画可能な frame slot が来た（直後の beginFrame(.nonblocking) 成功を保証はしない。§3 参照）
    timed_out,         // timeout_ns 内に来なかった
    fatal: FatalReason,
};

/// Window method として追加（既存 lockFramebuffer/present と同じ形状に揃える）。
pub fn beginFrame(self: Window, wait: FrameWait) FrameResult;
pub fn waitFrame(self: Window, timeout_ns: u64) WaitResult;
```

**確定した下位項目:**

1. **関数構成**: `beginFrame`（待機+lock 複合）と `waitFrame`（待機のみ、lock は別呼び出し）を **併設**する
   （ADR-005 スケッチのまま）。caller は「待つ/待たない」を `FrameWait` で明示し、`waitFrame` だけで
   pacing し既存 `lockFramebuffer()` で lock する組み合わせも選べる。
2. **API 形は `Window` method**: 現行 `lockFramebuffer`/`present` が `Window` method であることに揃える
   （ADR-005 の free function 風スケッチから変更）。`window.beginFrame(.wait)` のように呼ぶ。
3. **wait 中のイベント処理**: wait は **OS/native の event queue を進めてよい**（Wayland の frame callback
   到達、macOS の runloop tick、Win32 のメッセージポンプ相当）。ただし **非再入性契約**を課す:
   wait 内部で caller のコールバック・`nextEvent()` 相当の user-visible イベント配送は行わない。
   user-visible event は常に `pollEvents()`/`nextEvent()` からのみ観測される。wait はあくまで「次の
   frame slot か timeout か fatal」のいずれかで返るだけの関数。
4. **timeout 意味論**: `timeout_ns: u64`。`0` は「即座に ready/timed_out を判定する nonblocking 相当」、
   `std.math.maxInt(u64)` は実質無限待ち。**spurious wakeup を許容する**: `waitFrame` が `.ready` を返した
   直後の `beginFrame(.nonblocking)` が `.unavailable` になり得ることを契約上明記する（caller はループで
   retry する前提。D3D11 waitable object / Wayland frame callback のいずれも spurious を排除できないため）。
5. **best-effort backend の degrade 挙動**: objc/swift/X11/GDI は frame slot が常に available なので、
   `waitFrame` は **即 `.ready` を返す no-op**、`beginFrame(.wait)` も待機せず即 `framebuffer` を返す。
   これは ADR-005 の「pacing 非保証」tier 定義と整合する。
   - **性能目標**: no-op パスは追加 allocation なし・実時間 sleep なし。harness 無効時のオーバーヘッドは
     既存 `lockFramebuffer` と同等の分岐（`isEnabled()` 1 回）程度に収める（フレーム毎経路に乗るため）。
6. **PresentMode（fifo/immediate）との関係**: 本 ADR には載せない（ADR-005 と同様、拡張余地の明記のみに留める）。
7. **ライフサイクル / 状態遷移**: 「4. ライフサイクル state machine」節で規約表として定義する。
8. **C ABI / callback 方式との関係**: `beginFrame`/`waitFrame` は **手動描画 API 専用**。callback 方式
   （`platform.h` の `platform_run`/`FrameCallback`、`platform_create_window` の callback 引数）には
   **非公開**（関与しない）。macOS 3 backend（objc/swift/metal）は**初期実装ではすべて no-op wait**とし
   `platform.h` への新規 export は不要（既存の手動描画 export `platform_lock_framebuffer`/`platform_present`
   相当の呼び出しパターンのみで足りる）。Metal の inflight semaphore 待ちを `beginFrame` 側の意味のある wait
   として持たせる案は新規 export を要する**独立 follow-up**とし、本 ADR のスコープには含めない（詳細は
   「5-4」節）。

### 2. null と fatal の分離方式（AC#2）

**`FrameResult` tagged union**（ADR-005 候補2）を採用する。

**不採用理由:**

- `Error!?Framebuffer`（候補1）: `try`+`orelse` の2段 unwrap になり、`.unavailable` と `.fatal` の中間状態
  （wait 系 API の `.timed_out` 等）を素直に表現しづらい。
- **fatal event のみ**（候補3、`lockFramebuffer` は `?Framebuffer` のまま fatal を `nextEvent()` でのみ通知）:
  新 API の戻り値だけでは fatal を検出できず、caller が `nextEvent()` を都度確認する規律に依存する。
  新設 API では戻り値で完結させる方が安全。

**確定した下位項目:**

1. **fatal の分類**: `FatalReason` の3値（`device_lost` / `window_destroyed` / `backend_fatal`）とする。
   `device_lost` は「backend 内部で復帰を試みた後、なお不能」を指す（TASK-35.2 は内部 best-effort 復帰が先で、
   復帰できればそもそも fatal を上げない）。
2. **fatal は sticky state**: `Window` 実装は fatal を検出した時点で内部 1 個の `?FatalReason` を確定し、
   以後リセットしない（`Window.destroy()` まで維持。再接続・再作成による復帰は新しい `Window` を作る運用とし、
   本 ADR では「同一 `Window` インスタンスの fatal からの復帰」は扱わない）。
3. **present() 発 fatal の扱い（sticky state化。D3D11 device lost の主要検出点）**: D3D11 の
   `DXGI_ERROR_DEVICE_REMOVED`/`RESET` は `Present`/`GetBuffer` 等の操作で検出されることが多い。現行
   `present(self: Window) void` は値を返さないため互換上シグネチャを変えない。**`present()` 内部で fatal を
   検出した場合、戻り値では表現せず sticky fatal state に記録**し、以後の
   `beginFrame`/`waitFrame`/`nextEvent`（`.fatal` event）/`pollEvents`（`false` 固定）のいずれで呼んでも
   一貫して fatal が見える形にする。これにより `present()` 起点の fatal も新 API 経由で確実に caller に届く
   （TASK-35.2 の受け皿として必須）。
4. **fatal 後の API 呼び出し規約**（sticky state の具体的な現れ方）:
   - `beginFrame`/`waitFrame`: 呼ぶたびに `.fatal(reason)` を返す（何度呼んでも同じ理由。二重通知を許容し、
     caller 側の「1回だけ処理したい」ニーズは `nextEvent()` の `.fatal` event 1回発火で満たす）。
   - `nextEvent()`: fatal 検出直後の1回だけ `Event.fatal: FatalReason` を新設イベントとして発火する
     （`platform_types.zig` の `Event` union に追加。実装は follow-up）。以後は発火しない（`.quit` と同様
     「1回消費されるべき通知」として扱う）。
   - `pollEvents()`: fatal 後は常に `false` を返す（= 通常の「ウィンドウが閉じた」ケースと同じ終了シグナル。
     caller のメインループが自然に終了する）。
   - `lockFramebuffer()`（旧 API）: **fatal 後は `null` を返し続ける**（既存の「retry 可能」契約とは矛盾するが、
     `nextEvent()` の `.fatal` event / `pollEvents() == false` と**併用**することで、旧 API のみを使う caller も
     「pollEvents が false になったら終了する」という既存の一般的なループ規約で fatal を扱える。
     「null degrade のみ」（`nextEvent`/`pollEvents` 側の可視化を伴わない）は **不採用**: それだと旧 caller が
     `null` を単純 retry 可能と誤解し無限ループしうるため、必ず `pollEvents()==false` とセットで提供する。
   - `present()`: fatal 後も呼び出し自体はクラッシュしない no-op 相当とする（backend は内部で何もしない）。
5. **backend 別 fatal 源**（実装時の対応表・本 ADR は列挙のみ）:

   | backend | fatal 源 |
   |---|---|
   | D3D11 | `DXGI_ERROR_DEVICE_REMOVED`/`RESET`（`Present`/`GetBuffer` 等で検出。`GetDeviceRemovedReason` で理由取得） |
   | Wayland | `wl_display` エラー（`wl_display_get_error`）・compositor 切断（socket close） |
   | X11 | `XSetIOErrorHandler` 相当の fatal I/O error（display 切断） |
   | macOS（objc/swift） | window close・CALayer 関連の内部エラー（現状 fatal 源は実質無し。将来のための分類のみ） |
   | macOS（Metal） | command buffer の非同期エラー（`MTLCommandBuffer.error`）、drawable 取得の恒常的失敗 |
   | GDI | `hwnd` 破棄後の操作 |

### 3. ライフサイクル state machine（caller 契約。AC#1 の必須項目）

`Window` の手動描画状態を以下の規約で定義する（実装は各 backend が満たす契約。厳密な型状態機械ではなく
呼び出し順序の規約表として定義する）:

| 現在の状態 / 呼び出し | 結果 |
|---|---|
| unlocked 状態で `beginFrame`/`lockFramebuffer` | 通常通り `.framebuffer`/`non-null` or `.unavailable`/`null` を返す |
| **lock 中**（前回の `Framebuffer` を `unlock()`/`present()` していない）に再度 `beginFrame`/`lockFramebuffer` | **未定義動作としない**: 実装は前回の lock を暗黙に無効化し新しい lock を返す（既存 backend の実装済み挙動を踏襲。二重 lock は禁止されるものではなく「最後の lock が有効」とする）。ADR-005 の buffer ownership 契約（`present()` するまでの書き込み権）は変わらない。 |
| `Framebuffer` を取得後、**`present()` せず** `unlock()` のみ呼ぶ | そのフレームは表示確定しない（ADR-005 既定義どおり）。次の `beginFrame` は新しい frame slot を要求してよい。 |
| `Framebuffer` を取得後、**`unlock()` せず** `present()` を呼ぶ | 許容する（`present()` が内部で必要な後始末を行う。`lockFramebuffer`/`present` の既存コードパターン。`unlock()` は呼んでも呼ばなくても安全な冪等操作として扱う）。 |
| 同一 `Framebuffer` に対する **二重 `present()`** | 2回目は no-op（既に確定したフレームの再 submit はしない）。fatal 化はしない。 |
| `waitFrame` が `.ready` を返した直後の `beginFrame(.nonblocking)` | **成功を保証しない**（spurious wakeup 許容。`.unavailable` を返しうる。caller は retry ループを組む）。 |
| wait 中（`beginFrame(.wait)`/`waitFrame`）に window close が発生 | `.fatal(.window_destroyed)` 相当ではなく、通常の `.quit` 相当として扱う（window close は fatal ではなく正常終了経路。既存 `Event.quit` と同じ扱いを維持）。 |
| wait 中に fatal（device lost 等）が発生 | wait 関数自身が `.fatal(reason)` を返す（sticky state も同時に立つ）。 |
| fatal 確定後の任意の呼び出し | 「2-4. fatal 後の API 呼び出し規約」に従う（sticky。何度呼んでも同じ結果） |

### 4. harness への影響（AC#3）

1. **新 API の interpose 方針**: `beginFrame`/`waitFrame` にも `lockFramebuffer` と対称なフックを足す
   （`onLock`/`onLockMiss` 相当を `FrameResult`/`WaitResult` の分岐に対応させる）。**harness 有効時、
   `wait`/`timeout` は実時間待ちせず即座に判定する**（仮想クロックと整合し、replay 決定論を守る）。
   ここで「即座に判定する」の中身は headless（P4）と非 headless（native window 併用）で異なる:
   - **headless**（`VP_HEADLESS=1`）: backend 自体を呼ばない null window のため、frame slot は
     常に即 available（`.framebuffer`/`.ready` 固定）。
   - **非 headless**（native window + replay/live 併用）: `beginFrame`/`waitFrame` は native backend の
     lock 結果をそのまま尊重しつつ、**実時間の sleep/dispatch 待ちだけを行わない**（= 判定は即座だが、
     結果は native 次第で `.unavailable`/`timed_out` になり得る）。Wayland 等 native が `null`/busy を返す
     ケースは既存 `onLockMiss` 相当のフックにそのまま乗せ、`.framebuffer` を偽装しない。
2. **frame_index 進行条件は変更しない**: `present() = frame 確定点` を維持する。`beginFrame`/`waitFrame`
   自体は `frame_index` を進めない（既存 `lockFramebuffer` と同じ位置づけ）。
3. **fatal の harness 表現**: harness は fatal を**生成しない**（パススルーのみ）。replay 決定論の観点では、
   backend 発の fatal は非決定的事象であり、replay スクリプトの `inject`/`expect` 語彙には含めない
   （`.fatal` event は native backend からのみ発生し、harness の注入イベント経路には乗せない）。
4. **env 未設定時の完全パススルー維持**: 新フックも既存4フックと同様、`VP_HARNESS_SCRIPT`/`LIVE` 未設定時は
   即パススルー。既存 `fb` digest の bit 一致に回帰を出さない。
5. **`beginFrame(wait)` 単独ループは harness step gate の対象外**と明記する: harness の step gate
   （`pollGate`）は `pollEvents()` 起点のまま変更しない。`pollEvents()` を呼ばず `beginFrame(.wait)` だけで
   回る caller は harness の replay 決定論の対象にならない（そのような caller は「harness 非対象」として
   ADR に明記する）。**標準ループは `pollEvents() → beginFrame/waitFrame → 描画 → present()` の順序**を
   推奨し、既存 examples/apps はこの順序を踏襲する前提とする。将来 step gate を `beginFrame` 側へ移す案は
   本 ADR では採らず、必要になれば別 ADR / follow-up タスクで replay 決定性への影響を再評価する。

### 5. 既存 `lockFramebuffer()` 互換経路との移行方針（AC#4）

1. **`lockFramebuffer()` は nonblocking 互換経路として恒久維持**する（deprecate しない）。外部消費者
   （`tictactoe`）が `.path` 依存で直接使用しているため。
2. **`beginFrame(.nonblocking)` と `lockFramebuffer()` の意味論**: fatal 発生前は完全に同義
   （`.framebuffer`/non-null ↔ `.unavailable`/null が1:1対応）。fatal 発生後のみ差がある
   （`beginFrame` は `.fatal` を返せるが `lockFramebuffer` は `null` を返し続け、`nextEvent`/`pollEvents`
   側で fatal を可視化する。「2-4」節参照）。
3. **段階分解**（follow-up タスク粒度）:
   1. facade（`core/platform.zig`）+ 全 backend（macOS objc/swift/metal, Linux x11/wayland,
      Windows gdi/d3d11）への `beginFrame`/`waitFrame`/`FrameResult`/`WaitResult`/`FatalReason`
      追加。best-effort backend は no-op wait、fatal は各 backend が検出可能な範囲のみ実装
      （多くの backend は当面 fatal を上げない = 常に `.framebuffer`/`.unavailable` のみ）。
      `platform_types.zig` の `Event` union に `.fatal: FatalReason` を追加。
   2. TASK-35.2（D3D11 device lost）が本 ADR の sticky fatal state・fatal 分類に接続。
      TASK-35.3（D3D11 waitable swap chain）が本 ADR の `waitFrame` 実体に接続。
   3.（任意）examples/apps の新 API への移行（既存コードは無改修のままでよいため優先度低）。
4. **C ABI（`platform.h`）への波及範囲**: **初期実装（段階①）は macOS 3 backend（objc/swift/metal）すべて
   no-op wait**とし、新規 export は行わない（既存 `platform_lock_framebuffer`/`platform_present` の
   呼び出しパターンのみで `beginFrame`/`waitFrame` を Zig 側 facade + `core/platform_macos.zig` に実装できる）。
   Metal の inflight semaphore 待ち（現状 `present()` 内で実施。TASK-36）を `beginFrame` 側の意味のある wait
   として移す案は、`platform.h` への**新規 export 追加を伴う独立 follow-up**として扱い、本 ADR および段階①
   のスコープには含めない（対応が必要になった時点で別タスクを起票する）。

## 検証（既存契約に対する整合確認）

- **既存 caller 無改修**: `lockFramebuffer`/`present` のシグネチャ・戻り値は不変のため、examples 01〜18 /
  pixie / synth / modular / patch / main / 外部 `tictactoe` はソース変更なしでビルド・動作する
  （新 API は追加のみ、既存 API の型変更を伴わない）。
- **backend 実装可能性**: 5 backend 系統すべてで「no-op / 部分実装 / 将来 followup 接続」のいずれかとして
  自然に書ける（「2-5」節の対応表、「1-8」節の C ABI 非公開方針を参照）。
- **フレーム毎経路のオーバーヘッド**: harness 無効時は `isEnabled()` 分岐程度（既存 `lockFramebuffer` と同等）。
  best-effort backend の `waitFrame` no-op は sleep/allocation なし。
- **harness 決定論との整合**: `present = frame 確定点` / `pollEvents = step gate` / 仮想クロックいずれも不変。
  fatal は harness が生成しない（パススルーのみ）ため replay 決定論に影響しない。
- **TASK-35.2 / TASK-35.3 の受け皿としての充足**: TASK-35.2 が求める「回復不能時の caller 通知」は
  sticky fatal state + `FatalReason.device_lost` + `.fatal` event で受けられる。TASK-35.3 が求める
  「beginFrame/waitFrame への接続」は `WaitResult`/`FrameResult` の型と `waitFrame` の呼び出し形で受けられる。

## 影響

- [ADR-005](005_platform_support_tierとframe_pacing契約.md): 「Wait / Skip Policy と beginFrame / waitFrame」
  「Fatal State Policy」の両節へ「API 形は本 ADR-008 参照」の参照と変更履歴（v1.2）を追記済み（本タスクの
  同一 commit に含む）。
- `core/platform_types.zig`: `Event` union への `.fatal: FatalReason` 追加は本 ADR の型定義案の文書化に留め、
  実コード変更は follow-up タスクで行う（本タスクはコード変更ゼロ）。
- `core/platform.zig` / 各 backend / `core/control/harness.zig` へのフック追加は follow-up タスク
  （「5-3」節の段階①）で実施する。本 ADR 自体はコード変更を伴わない。
- 実装コード（`lockFramebuffer`/`present` の挙動・シグネチャ・`build.zig`・facade）は本タスクでは不変。

## ホットパス宣言

本 ADR は設計文書のみでコード変更を伴わない（フレーム毎/RT ループの新設なし）。ただし決定した API 自体は
main loop で毎フレーム呼ばれる経路に乗るため、「1-5」「検証」節で per-frame オーバーヘッド（no-op backend の
allocation/sleep ゼロ、harness 無効時のパススルー同等コスト）を評価軸として明記した。

## 変更履歴

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-07-05 | 初版（TASK-38）。beginFrame/waitFrame API 形・FrameResult による null/fatal 分離・sticky fatal state・ライフサイクル規約・harness 整合・lockFramebuffer 互換移行方針を確定。 |
