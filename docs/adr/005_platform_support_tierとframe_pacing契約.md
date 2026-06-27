# ADR-005: platform support tier と frame pacing 契約

**Status:** 承認（決定は承認済み。frame pacing API・D3D11 backend・Metal 1級化の実装は follow-up タスク）
**Date:** 2026-06-27
**Category:** プラットフォーム戦略・レンダリング・フレーム制御

## 概要

ゲーム用途を見据え、platform backend の **support tier**（保証範囲の階層）と、1級 backend 共通の
**frame pacing / vsync / buffer ownership 契約**を定義する。

**決定内容（要約）:**

- backend を 2 tier に分ける。
  - **1級 backend**: macOS **Metal** / Windows **D3D11-DXGI** / Linux **Wayland**。ゲーム向けの frame pacing
    （fifo）・buffer ownership・present semantics を揃え、tearing 回避を保証対象とする。
  - **best-effort backend**（= compatibility backend）: macOS **CALayer**（objc/swift）/ Linux **X11** /
    Windows **GDI**。同じ API 形状に合わせるが、厳密な vsync・低 jitter・tearing 回避・frame latency 制御は
    **保証しない**。
- `present()` は「直近 lock したフレームを表示キューへ submit する **非ブロック操作 / frame 確定点**」とする
  （[ADR-002](002_platform_presentのブロッキング挙動.md) の非ブロック方針を維持）。
- frame pacing は present の待機では表現せず、**frame availability**（`lockFramebuffer()` の成功）と、
  将来の **`beginFrame(wait)` / `waitFrame(timeout)`** で扱う。
- `lockFramebuffer() == null` は retry 可能な **frame slot unavailable** を表す。**fatal**（device lost /
  window 破棄 / backend fatal）は null と **別経路**で扱う方針とする。
- 本 ADR は [ADR-004](004_プラットフォームサポート戦略.md)（X11 除外戦略）を **Supersede** する。

> **本 ADR のスコープ**: 契約・方針・tier の **定義**まで。`beginFrame`/`waitFrame` や fatal 分離 API の Zig 実装、
> D3D11-DXGI backend の実装、Metal の 1級化は **follow-up タスク**で行う（末尾「Follow-up」参照）。現行の
> `lockFramebuffer() ?Framebuffer` / `present()` のシグネチャと挙動はこのタスクでは変更しない。

## 背景

- [ADR-002](002_platform_presentのブロッキング挙動.md) は当初 macOS backend のみを前提に「present は非ブロック、
  rate control は caller の sleep 責任、ティアリングは（WindowServer/GPU が VBLANK でスワップするので）発生しない」
  と決めた。その後 X11 / Wayland（TASK-28）と Windows GDI（TASK-31）が実装され、前提が広がった。
  - **Wayland** は既に `lockFramebuffer()` が `null` を返す（frame callback 未到着 / `wl_buffer.release` 前の
    busy buffer）。これは「busy loop の present flood を frame callback 律速で抑える」ための実装で、ADR-002 の
    「present は単に非ブロック」モデルには現れていない意味論である。
  - **X11 / GDI** は vblank 待ちのないノーガード blit で、高 fps では tearing が出る（X11 は TASK-28.8 で低減予定）。
  - **Metal** は `commandBuffer.present(drawable)+commit` するが `waitUntilCompleted` せず、明示的な
    drawable / inflight buffer の pacing 契約や CAMetalLayerDrawable lifecycle の整理がない。
- [ADR-004](004_プラットフォームサポート戦略.md) は「Linux/X11 を当面除外」と決めたが、現状は X11 / Wayland /
  Windows GDI いずれも実装済みで前提が逆転している。
- 将来 Windows を D3D11-DXGI、macOS を Metal、Linux を Wayland に本命化するにあたり、これらを **1級 backend**
  として frame pacing 契約を揃え、残りを best-effort として保証範囲を明示する必要がある。

## 用語

| 用語 | 定義 |
|---|---|
| **1級 backend** | ゲーム向けの frame pacing（fifo）・buffer ownership・present semantics を保証対象とする backend。Metal / D3D11-DXGI / Wayland。 |
| **best-effort backend**（compatibility backend） | 同じ API 形状に合わせるが、厳密な vsync・低 jitter・tearing 回避・frame latency 制御を保証しない backend。CALayer objc/swift / X11 / GDI。 |
| **frame availability** | 「今このフレームを描画してよいか」。`lockFramebuffer()` が成功（non-null）したときだけ描画可能。 |
| **frame slot unavailable** | 描画可能な backbuffer / frame slot が今は無い retry 可能状態。`lockFramebuffer() == null` で表す。fatal ではない。 |
| **present = submit** | `present()` は「直近 lock したフレームを表示キューへ送る」非ブロック操作。display refresh までは待たない。 |
| **frame 確定点** | `present()` の呼び出し時点。表示するフレームが確定し、TASK-32 harness の frame_index / snapshot / digest の基準になる。 |
| **buffer ownership** | lock で得た pixels の書き込み権。present 後は backend / compositor / GPU 側へ移る。 |
| **fifo / immediate** | PresentMode。fifo = display refresh 同期（tearing しない・ゲーム標準）、immediate = 可能なら即時 submit（低遅延・ベンチ用途。tearing は許容または OS 依存）。 |

## Support Tier（AC#2）

| tier | backend | tearing 回避 | frame pacing（fifo） | 低 jitter / frame latency 制御 | 備考 |
|---|---|---|---|---|---|
| **1級** | macOS Metal | 保証対象 | 保証対象 | 目標 | follow-up で 1級化（drawable/inflight） |
| **1級** | Windows D3D11-DXGI | 保証対象 | 保証対象 | 目標 | 未実装。GDI から移行（follow-up） |
| **1級** | Linux Wayland | compositor が保証 | frame callback 律速で実現済み | compositor 依存 | 既に frame availability を実装済み |
| **best-effort** | macOS CALayer（objc/swift） | WindowServer 任せ（実質出ない） | 非保証 | 非保証 | CADisplayLink は裏で回るが明示契約なし |
| **best-effort** | Linux X11 | **非保証**（出得る） | 非保証 | 非保証 | TASK-28.8 で best-effort 低減予定 |
| **best-effort** | Windows GDI | **非保証**（出得る） | 非保証 | 非保証 | software blit。D3D11 への移行先 |

各 OS の **1級 backend を将来の本命**とし、best-effort backend は移植性・前段の互換経路・ヘッドレス検証用として残す。
tier はビルド時の backend 選択（`-Dplatform`）に対応するが、本 ADR は tier の **意味（保証範囲）** を定義するもので、
ビルド配線の変更は伴わない。

## Frame Pacing Contract（1級 backend 共通・AC#3）

1. **frame availability**: `lockFramebuffer()` が成功（non-null）したフレームだけ描画してよい。
   - `null` は retry 可能な frame slot unavailable（後述）。
   - caller は `null` を受けたらそのフレームの描画を skip し、`pollEvents()` 等を回して次の機会を待てる。
2. **buffer ownership**: `lockFramebuffer()` が返す `Framebuffer.pixels` は、`present()` するまでだけ書き込み可能な
   一時 view とする。
   - caller は `present()` 後、その `pixels` を読み書きしてはならない。
   - backend は `present()` 後、表示キュー / GPU / compositor が完了するまで buffer を所有する。再利用前に
     backend 固有の完了条件を満たす（Wayland: `wl_buffer.release` / D3D11: present・frame latency 完了 /
     Metal: command buffer・drawable/inflight 完了）。最低 double buffering、必要なら triple / inflight。
3. **present semantics**: `present()` は「直近 lock したフレームを表示キューへ submit する」非ブロック操作 /
   frame 確定点。display refresh までは必ずしも待たない（resource pressure / OS API 都合で短時間 block は許容）。
   present せず unlock したフレームは表示確定とみなさない。
4. **PresentMode**: 少なくとも `fifo` / `immediate` の 2 概念を持てる設計にする。初期実装は `fifo` のみでよいが、
   API / ADR では拡張余地を残す（`mailbox` 等は本 ADR では定義しない）。

   ```zig
   pub const PresentMode = enum {
       fifo,      // display refresh 同期。tearing しない。ゲーム標準。
       immediate, // 可能なら即時 submit。低遅延 / ベンチ用途。tearing は許容または OS 依存。
   };
   ```

   対応イメージ: Wayland `fifo` = `wl_surface.frame` callback で次 frame availability を許可 /
   D3D11 `fifo` = DXGI `Present(1, 0)` + frame latency 管理 /
   Metal `fifo` = display sync / drawable pacing / inflight semaphore 相当。
5. **resize contract**: resize 対応時は、`lockFramebuffer()` 成功時の `Framebuffer.width/height` を **その frame の正**
   とする。caller は毎フレーム `fb.width/height` を確認する。resize 後、古い framebuffer pointer は無効。backend は
   frame boundary で swap chain / `wl_buffer` / Metal texture 等を再作成し、caller には古い pointer を返さない。
   （現状の全 backend は固定サイズ運用。resize 実装は follow-up。）

## Wait / Skip Policy と beginFrame / waitFrame（AC#9）

- **現行 `lockFramebuffer() ?Framebuffer` は nonblocking な互換経路**として位置づける。availability / ownership /
  submit 意味論の整理であって、これ単体では「ゲーム級の frame pacing 本体」ではない。
  - 描画可能 buffer があれば `Framebuffer` を返し、なければ `null` を返す。caller は skip / poll / sleep /
    harness step gate を選ぶ。
- **ゲーム向け pacing 本体は、blocking wait を含む `beginFrame(wait)` / `waitFrame(timeout)` 相当**として設計する。
  caller が「待つ / 待たない（skip）」を **意図して選べる**ようにし、シングルスレッドでも待機できる経路を与える。

  ```zig
  pub const FrameWait = enum { nonblocking, wait };
  pub fn beginFrame(window: Window, wait: FrameWait) ?Framebuffer;
  pub fn waitFrame(window: Window, timeout_ns: u64) bool;
  ```

  想定実装: Metal = display link / drawable availability / semaphore で main loop を起こす /
  Wayland = event dispatch で frame callback を待つ / D3D11 = `Present(1,0)` または frame latency waitable object。
- **本タスクのスコープ**: 上記は ADR 上の **方針**であり、Zig API の追加・実装は **follow-up**（末尾参照）。現行
  `lockFramebuffer()` 互換経路は残したまま、ゲーム向け pacing API を上に重ねる移行を想定する。

## Fatal State Policy — null と fatal の区別（AC#10）

`lockFramebuffer() == null` は **frame slot unavailable（retry 可能）** のみを表し、**fatal には使わない**。
device lost（D3D）/ window 破棄 / backend fatal error などは別経路で通知する必要がある。現行 API（`?Framebuffer`）
では fatal を表現できないため、本 ADR では **方針のみ決め**、API 形は follow-up で確定する。

候補（follow-up で 1 つに決める）:

- `Error!?Framebuffer`: `error.DeviceLost` 等は error、`null` は frame slot unavailable、non-null は描画可能。
- `FrameResult`（tagged union）: `.framebuffer / .unavailable / .fatal` を 1 値で返す。
- **fatal event**: `lockFramebuffer()` は null / non-null のみとし、fatal は `nextEvent()` の event（例 `.device_lost` /
  既存 `.quit`）で通知する。

いずれの案でも、後続 API 破壊を避けるため「現行 `?Framebuffer` 互換経路を壊さずに fatal 経路を足す」ことを条件とする。

## Backend ごとの差分

### Wayland — frame callback / busy buffer による null（AC#5）

既存 Wayland backend（`src/platform_linux_wayland.zig`）は `lockFramebuffer()` が次の場合に `null` を返す:
未 configure / closing / 既に lock 中、`frame_pending` かつ deadline 前（`wl_surface.frame` callback 未到着）、
両 buffer が busy（`wl_buffer.release` 未到着）。これは busy loop の present flood を frame callback（≒ compositor
vsync）律速で抑える実装で、**本 ADR の frame availability / frame slot unavailable 意味論の既存実装例**として正式に
位置づける（`frame_timeout_secs` の fallback により callback 取りこぼし時も最低限復帰する）。Wayland は 1級 backend の
fifo pacing を実質すでに満たしている。

### Metal — 現状差分と 1級化の前提（AC#6 / AC#13）

現状（`platform/macos-metal/platform_macos_metal.swift`）: `present()` で CPU framebuffer を texture へ転送し
`commandBuffer.present(drawable)+commit` するが `waitUntilCompleted` せず、明示的な drawable / inflight buffer の
pacing 契約がない。CAMetalLayerDrawable lifecycle 警告も残る（機能的には動作）。1級 backend にするには以下が前提
（follow-up タスクで具体化）:

- CAMetalLayerDrawable lifecycle 警告の解消。
- drawable / command buffer / CPU framebuffer の **inflight ownership** の明確化（present 済み buffer を安全に
  再利用する条件）。
- fifo pacing（display sync / inflight semaphore 相当）の保証。
- `lockFramebuffer() == null`（または将来の `beginFrame/waitFrame`）との対応付け。

### D3D11-DXGI — GDI からの移行先（AC#4 概要）

Windows は現状 GDI（software blit）のみ（TASK-31 / Done）。D3D11-DXGI を Windows の **1級 backend** として追加し、
fifo（DXGI `Present(1,0)` + frame latency 管理）・buffer ownership（swap chain / upload）・present semantics を本
契約に合わせる。詳細方針は次節。

### GDI / X11 / CALayer — 非保証項目（AC#7）

best-effort backend では次を **保証しない**ことを明記する:

- 厳密な vsync 同期
- 低 jitter（フレーム間隔の安定性）
- tearing 回避（X11 / GDI はノーガード blit で tearing が出得る。CALayer は WindowServer 任せで実質出ないが契約上は非保証）
- frame latency 制御 / inflight buffer 管理
- `lockFramebuffer() == null` による frame availability gating（X11 / GDI / CALayer は現状常に non-null を返す。
  caller 側で sleep / fixed timestep による self-pacing が必要）

これらの非保証項目は利用者にも届くよう、別途 follow-up で README / docs にも記載する（末尾参照）。

## Windows GDI から D3D11-DXGI への移行 / 併存方針（AC#4）

- **GDI は best-effort backend として残す**（撤去しない）。software framebuffer / 移植性 / ヘッドレス検証の前段として有用。
- **D3D11-DXGI を Windows の 1級 backend として追加**する。`-Dplatform` の Windows 値に `d3d11`（仮）を足し、
  既定をどちらにするかは follow-up で決める（当面は GDI 既定、d3d11 opt-in が無難）。
- canonical pixel format は全 OS BGRA 統一済み（TASK-28.6）なので、CPU framebuffer → D3D11 テクスチャ upload は
  変換不要。
- 公開 API（`lockFramebuffer` / `present` / event / `getTime`）の形は不変に保ち、D3D11 backend を facade dispatcher
  の 1 実装として足す（Linux の x11/wayland dispatcher と同じパターン）。
- 段階分解（follow-up タスクの粒度の目安）: ①device / swap chain / render target or upload path ②BGRA framebuffer の
  表示（present = submit）③fifo present / frame latency 管理 ④resize / device lost（best-effort 範囲の明記含む）。

## TASK-32 harness（統合済み）との整合（AC#8）

> **前提**: TASK-32 harness（`src/harness.zig` と facade のラッパ化）は **main にマージ済み**（TASK-32.1〜32.3）。
> `src/platform.zig` はもはや素通し re-export ではなく、`pollEvents` / `nextEvent` / `lockFramebuffer` / `present`
> / `getTime` を interpose する薄いラッパで、env 未設定時のみ即パススルーする。本節はその**統合済み harness の実装**と
> 本契約の整合確認である（完全 display-less / Metal fb 捕捉は P4=TASK-32.4 として未実装）。

harness は facade の `pollEvents` / `nextEvent` / `lockFramebuffer` / `present` / `getTime` を interpose する。
本契約でも以下を維持すれば、harness の replay 決定性（`frame_index` / 仮想時計 / digest）は壊れない:

- `present()` を **frame 確定点**とする（harness はここで framebuffer を owned copy し `frame_index` を +1、
  仮想時計 `getTime = frame_index/60`）。
- `lockFramebuffer() == null` のとき harness は `onLockMiss()` で stale frame を再コピーしない（frame_index は進む）。
  本契約の frame slot unavailable 意味論と一致する。
- present 後の buffer ownership 厳密化は、harness が present **直前**に owned copy する設計と矛盾しない。

**将来の移行判断点**: `beginFrame()` / `waitFrame()` を導入する場合、フレーム進行の同期点（step gate）を現行どおり
`pollEvents()` に置くか、frame boundary（beginFrame/present）側へ移すかを再検討する。その際も「present = frame 確定点・
frame_index 進行条件」を変えないか、変えるなら harness の replay 決定性を壊さない移行方針を別途定義する（follow-up）。

> **実コードへの制約（harness 統合後）**: harness は設計ではなく `src/platform.zig` の実フックになったので、
> 1級 backend 実装タスク（**TASK-35** D3D11-DXGI / **TASK-36** Metal）が `present` / `lockFramebuffer` の挙動・
> シグネチャ・frame_index 進行条件を変える場合は、**`src/harness.zig` のフック（`onLock`/`onLockMiss`/`onPresent`/
> `pollGate`/仮想クロック）も同時に追従**させる。env 未設定パススルーと replay 決定性（fb の bit 一致）を回帰させないこと。

## TASK-28.8 X11 vsync との整合（AC#11）

**TASK-28.8**（X11 backend の vsync 同期 / tearing 解消）は、**1級 backend と同等の frame pacing
保証ではなく、best-effort backend における tearing 低減 / backend 改善**として位置づける。X Present 拡張または
フレームレート上限のいずれで実装しても、X11 が 1級 backend に**昇格するわけではない**。TASK-28.8 の AC「公開描画 API
（lockFramebuffer/present）の caller 駆動契約は不変」は本 ADR と整合する。

## Follow-up

本 ADR は契約・方針・tier の定義まで。以下を follow-up タスクとして切った（TASK-34 で起票済み）:

1. **TASK-35**: D3D11-DXGI 1級 backend の実装（GDI と併存。Windows の 1級化。AC#4）。
2. **TASK-36**: Metal backend の 1級 frame pacing 契約への適合（CAMetalLayerDrawable 警告解消 / drawable・inflight
   ownership / fifo pacing。AC#6 / AC#13）。
3. **TASK-37**: best-effort backend の非保証項目の利用者向け文書化（README / AGENT / docs。AC#7）。
4. **TASK-38**: `beginFrame` / `waitFrame` と fatal 状態分離 API の設計（AC#9 / AC#10 の実装受け皿）。

## 影響

- [ADR-002](002_platform_presentのブロッキング挙動.md): present = 非ブロック submit / frame 確定点として整理。
  詳細契約を本 ADR に委譲（改訂済み）。
- [ADR-004](004_プラットフォームサポート戦略.md): Superseded（X11 除外戦略は現状実装と逆転）。
- コメント整合: `platform/platform.h`（present / lockFramebuffer コメント）、`AGENT.md`（手動描画節）、
  `docs/PLAN.md`、`examples/01_timed_window/README.md` を本契約の用語に整合。
- 実装コード（present / lockFramebuffer の挙動・シグネチャ・`build.zig`・facade）は本タスクでは不変。frame pacing API /
  D3D11 backend / Metal 1級化は上記 follow-up。

## 変更履歴

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-06-27 | 初版（TASK-34）。support tier と frame pacing 契約を定義。ADR-004 を Supersede、ADR-002 を改訂。 |
