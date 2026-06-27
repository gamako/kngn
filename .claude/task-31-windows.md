---
id: TASK-31
title: Windows プラットフォーム実装（Win32 + GDI backend）
status: In Progress
assignee: []
created_date: '2026-06-27 10:51'
labels: []
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
macOS(objc/swift/metal) / Linux(x11/wayland) に続く **Windows ネイティブ対応**。ソフトウェアフレームバッファ方式(CPU blit, GPU 不要)なので、ウィンドウ生成 / BGRA blit / 入力 / モノトニック時刻 を実装すればよい。設計は **Linux(TASK-28) を踏襲**: 純 Zig backend で Win32 API を直接呼び、`platform.h`(C struct ABI) は経由しない。

**目標**: main(虹色グラデーション) / examples / pixie が **Windows ネイティブで動く**こと。検証ターゲットは walle-win（このリポジトリの開発・検証は walle-win 上の Claude が現地で行う。RDP で対話デスクトップが使える）。

> このファイルは Windows 側 Claude に**目標を伝えるためのもの**。詳細な実装プランは Windows 側で立てること。
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Windows ネイティブ backend で main(虹色) と examples 01-05 が walle-win 上で動作しスクショ確認できる
- [~] #2 pixie エディタが Windows で動作（描画 / GUI）。comdlg32 ファイルダイアログで保存/読込できる
- [x] #3 入力変換の純ロジック単体テスト(test-platform-windows-input)が host で緑
- [~] #4 macOS/Linux 既存 backend のビルド/テスト(zig build -Dinstall-all / zig build test)が回帰しない
<!-- AC:END -->

> AC 状態（2026-06-27 実施）: #1=達成（main 虹色をスクショ確認）/ #3=達成（18 ケース緑、集約 `zig build test` も緑）。
> #2=pixie の描画/GUI/カラーピッカー/DB16 パレット/テキスト描画をスクショ確認済み。ただし**描画ストローク・
> GUI 操作・comdlg ダイアログは合成入力の検証が未了**（理由は下記「検証で判明した環境制約」）。
> #4=Windows host で全テスト緑・全 artifact ビルド可を確認。**macOS/Linux 実機での回帰確認は未実施**
> （共有ファイルを変更したため。変更は両 OS で no-op になる設計だが現物確認が必要）。

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## 方針（詳細プランは Windows 側 Claude が立てる。以下は道標）

### アーキテクチャ（TASK-28 / Linux パターンを踏襲）
- `src/platform.zig`（facade）に `.windows => @import("platform_windows.zig")` を追加。
- 純 Zig backend。`platform.h` は経由しない。Win32 は **extern fn**（audio 層と同様、`@cImport` しない方針が好ましい。`std.os.windows` の既存宣言も活用）。
- 共有型（KeyCode/Event 等）は `src/platform_types.zig` が単一ソース。
- **新規 `src/platform_windows.zig`**: CreateWindowExW / メッセージポンプ(PeekMessageW) / GDI blit(StretchDIBits or SetDIBitsToDevice、`BITMAPINFO`=BI_RGB 32bpp、top-down は biHeight 負) / present / getTime(QueryPerformanceCounter)。
- **新規 `src/platform_windows_input.zig`**: VK→KeyCode / WM_*→Event / modifier / wheel の **純ロジック**（`@cImport` しない）。host でも単体テスト可（手本は `src/platform_linux_input.zig`）。`zig build test-platform-windows-input` を追加し集約 `test` に含める。

### build 配線
- `build_helpers/platform.zig` の `PlatformType` に windows を追加。`defaultBackend` / `implementedBackends` / `assertBackendForOs` / `setupExecutableForPlatform` を .windows 対応。
- リンク: user32 / gdi32 / kernel32（ファイルダイアログ用に comdlg32）。**SDK/xcrun 不要**（zig 同梱 MinGW import lib で解決）。
- audio(synth / example_15) は当面 Windows 対象外に gating（WASAPI は別タスク）。

### pixel format
- canonical **BGRA** が GDI に native（`src/platform.zig` 冒頭コメント / メモリ `project_pixel_format_abgr` 参照）。中間変換層は不要。

### 検証
- compile/link gate: 任意 host で `zig build -Dtarget=x86_64-windows -Dplatform=windows`（クロスコンパイル）。
- 実機: walle-win でネイティブビルド → RDP セッションで実行 → PowerShell(`PrintWindow` / `CopyFromScreen`)でスクショ撮影 → Claude が PNG を読む。実入力は `SendInput`。
- 入力純ロジックは display/実機不要で host テスト。

### 対象外（初期）
- Direct2D / Direct3D(DXGI) backend、WASAPI audio。

### 環境（Windows 側 Claude が準備）
- zig 0.16.0 を導入: https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip （sha256 `68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e`）。
- git 2.45.2 導入済み。リポジトリ配置: `C:/Users/gama/gamako/projects/video-proto-main`（Mac から git bundle で履歴ごとシード済み）。

### 開発・往復（VCS）
- Windows 側は **素の git** で作業ブランチ（例 `windows-port`）に Conventional Commits で積む。
- Mac への取り込みは Mac 側 `jj git fetch`（Mac は jj、colocated）。jj の change-id 等はローカル専用で、機械間で渡るのは git コミット + ref のみ。

---

## 実装記録（2026-06-27 / windows-port ブランチ）

### 開発環境整備（walle-win）
- **zig 0.16.0**: `C:\Users\gama\tools\zig-x86_64-windows-0.16.0\`（sha256 検証済み）。ユーザー PATH 追加。
- **git**: リポジトリが `BUILTIN/Administrators` 所有のため `git config --global --add safe.directory <repo>` を設定。
- Claude の PowerShell ツールはセッション間で env 非保持。zig 利用時は毎回 `$env:Path += ";<zigdir>"` を前置。

### 追加 / 変更ファイル
- **新規 `src/platform_windows.zig`** — Win32 + GDI backend 本体。
  - init: `RegisterClassExW`（プロセス単一・冪等）。getTime: `QueryPerformanceCounter`/`Frequency`。
  - Window.create: `CreateWindowExW`（固定サイズ = `WS_CAPTION|WS_SYSMENU|WS_MINIMIZEBOX`、`AdjustWindowRectEx` で
    client=指定寸法）。State* を `GWLP_USERDATA` に格納（早期メッセージは DefWindowProcW に落ちる）。
  - present: `GetDC`→`StretchDIBits`（`BITMAPINFO` BI_RGB 32bpp、**biHeight 負 = top-down**）→`ReleaseDC`。
    canonical BGRA を**変換なしで直接 blit**（背景ブラシ null でちらつき防止）。
  - pollEvents: `PeekMessageW(PM_REMOVE)`→`TranslateMessage`/`DispatchMessageW`。wndProc が WM_* を Event 化し enqueue。
  - 入力: WM_KEY*/SYSKEY*（generic 修飾 VK は scancode/拡張ビットで左右解決、テンキー Enter→KP_ENTER 正規化、
    lParam bit30=repeat）/ WM_*BUTTON*（押下中に SetCapture、全離しで ReleaseCapture）/ WM_MOUSEMOVE /
    WM_MOUSEWHEEL・HWHEEL（screen→client 変換）。SYSKEY は DefWindowProc にも通し Alt+F4 等を保つ。
  - ダイアログ: comdlg32 `GetSaveFileNameW`/`GetOpenFileNameW`（OPENFILENAMEW）。キャンセル=null /
    `CommDlgExtendedError`!=0=DialogFailed。UTF-16⇔UTF-8 変換。`io: std.Io` は未使用（native dialog）。
  - Win32 は **extern fn**（`@cImport` しない）。型は `std.os.windows` を流用しつつ、当版に無い
    `WPARAM/LRESULT/POINT/RECT` と、enum 化されている `BOOL`（→ i32）は自前定義。
- **新規 `src/platform_windows_input.zig`** — 入力純ロジック（VK→KeyCode / 修飾 post-state / wheel 符号）。
  `@cImport` しない純 Zig。`KeyDownSet`/`EventQueue`/`SCROLL_LINE_TO_POINTS` は `platform_linux_input.zig` を
  再利用（Wayland backend と同方針）。test 18 ケース内蔵（host で緑）。
- **`src/platform.zig`** facade — `.windows => @import("platform_windows.zig")` を追加。
  併せて `pub fn sleep(nanoseconds)` を追加（zig 0.16 で std.time.sleep 廃止・sleep が std.Io 経由化したため。
  comptime OS 分岐: POSIX=nanosleep / Windows=`kernel32.Sleep`。unselected 分岐は解析されず両 OS を壊さない）。
- **`build_helpers/platform.zig`** — `PlatformType` に `windows` 追加。`defaultBackend`/`implementedBackends`/
  `assertBackendForOs`/`setupExecutableForPlatform`（user32/gdi32/comdlg32 を linkSystemLibrary。SDK 不要）対応。
- **`build.zig`** — `test-platform-windows-input` step 追加（集約 `test` に含む）。`audio_supported`（macOS/Linux のみ）で
  synth アプリ / example_15(audio) を Windows ビルドから除外（`default_synth` を optional 化、run-synth/build-synth も gate）。
- **`src/main.zig` + examples 01〜05,12** — `std.c.timespec`/`nanosleep`（POSIX 専用で Windows 非対応）を
  `platform.sleep(ns)` に置換。example_02 の `std.c.clock_gettime`（PRNG seed）は `platform.getTime()` に置換。
  example_15(audio) は Windows 対象外のため未変更。

### 検証結果
- `zig build -Dinstall-all=true` → main + pixie + examples 01-14 の **16 exe を Windows ネイティブビルド成功**。
- `zig build test`（集約・host）→ **全緑**（新規 windows-input 18 ケース含む）。
- 実行: `video_proto.exe`（虹色グラデーション）と `pixie.exe`（ツールバー/キャンバス/カラーピッカー/DB16
  パレット/ツール/ステータスバー）を起動し **PowerShell `PrintWindow` でスクショ取得 → 正しく描画**を確認。
  色は BGRA→GDI で正常（R/B 反転なし）。

### 検証で判明した環境制約（重要）
- この自動化セッション（PowerShell ツール）は **session 2 / UserInteractive=True だが入力デスクトップが
  アタッチされておらず、`SetCursorPos`/`mouse_event`/`SendInput` が一切効かない**（`SetCursorPos(600,400)` 後も
  `GetCursorPos` が 0,0 のまま。RDP 切断中の典型）。このため **描画ストローク・GUI hover/press・comdlg ダイアログ
  表示の自動検証は不可**。`PrintWindow` はウィンドウ自身の DC を撮るためクロスデスクトップに動作する（描画確認は可能）。
- → **AC#2 の残り（実描画・ダイアログ）は RDP 対話セッションに接続した状態で手動確認が必要**。
  入力マッピングの正しさは `test-platform-windows-input`（18 ケース）と pixie の `canvas_input` 単体テスト（test-core）で担保済み。

### 残タスク
1. **AC#2 仕上げ**: RDP 対話デスクトップで pixie 描画 / GUI 操作 / PNG open・save ダイアログ（comdlg32）を手動確認。
2. **AC#4 仕上げ**: macOS / Linux 実機で `zig build -Dinstall-all` / `zig build test` の回帰確認（共有ファイル変更の影響確認）。
   変更は両 OS で no-op になる設計（sleep の else 分岐＝従来 nanosleep、audio gating は mac/linux で従来どおり全 build）。
3. （任意）`platform.sleep` 追加に伴い、他 example/app に残る `std.c.nanosleep` 直書きがあれば統一。
4. 対象外のまま: Direct2D/Direct3D backend、WASAPI audio（別タスク）。

### Mac への取り込み手順（リマインダ）
- Windows: `windows-port` に Conventional Commits でコミット（ユーザー確認の上で）。
- Mac: `jj git fetch` で取り込み。

---

## 追加修正（実機で発覚した Windows 固有の不具合・2026-06-27）

実機で sample を起動して判明した 3 点を修正:

### 1. 全 sample で起動時に DOS（コンソール）窓が出る
- 原因: exe が既定の **console subsystem** でビルドされ、GUI アプリでも起動時にコンソール窓が出る。
- 修正: `build_helpers/platform.zig` の `setupExecutableForPlatform` `.windows` 分岐で `exe.subsystem = .Windows`
  （GUI subsystem）。`std.debug.print` はコンソール非接続時 no-op になり問題なし。
- 例外: `example_06`（スプライトベンチ）は **stdout のベンチ数値が本体**なので、`build.zig` で
  `ex_exe.subsystem = .Console` に上書きしコンソールを保つ。
- 確認: PE subsystem が main/pixie/example_01/12=2(GUI)、example_06=3(Console)。

### 2. example_06 が `InvalidPNGSignature` で起動失敗
- 原因: `examples/06_sprite_benchmark/image/usako.png` は **git シンボリックリンク**（→ 03 の PNG）。
  **Windows の git（core.symlinks=false）はリンクを実体化せずリンク先パス文字列のテキストファイルで展開**するため、
  `@embedFile` が PNG ではなく `"../../03_..."` という文字列を読み、署名検証に失敗していた。
- 修正: 実体 PNG（`examples/03_sprite_rendering/image/usako.png`）を 06 にコピーして実ファイル化。
  → git 上は symlink(120000) から通常ファイル(100644) への変更になる（Mac 取り込み時に実体ファイルになる）。
- 確認: PNG 署名 `89 50 4E 47 ...` 正常化、`example_06.exe 500 moving` がベンチ計測まで動作（fps 計測 OK）。

### 3. example_12 が「ファイルを読めない」（空白表示）
- 原因: system フォント候補パスが **macOS / Linux のみ**で Windows のフォントが無く、全候補 FileNotFound で
  フォント未ロード → 空白。
- 修正: `examples/12_outline_font/main.zig` の `font_paths` に Windows 候補を追加
  （`C:/Windows/Fonts/YuGothM.ttc`〔游ゴシック〕/ `meiryo.ttc` / `msgothic.ttc` / `arial.ttf` / `segoeui.ttf` / `consola.ttf`。
  forward slash で Win32 file API が解決）。
- 確認: `YuGothM.ttc` をロードし英字 + 日本語（「こんにちは 世界 ABC 123」）をスクショで描画確認。

### 既知の未対応（symlink 起因。top-level ビルドには影響しないが standalone ビルドに影響）
- `examples/*/build_helpers`・`apps/editor/build_helpers` は git **シンボリックリンク**（→ `../../build_helpers`）。
  Windows ではテキストファイル化しているため、**各 example/app ディレクトリでの standalone ビルド
  （`cd examples/XX && zig build`）は失敗する**。top-level の `zig build`（リポジトリ root）は実パスを使うため影響なし。
  恒久対策の候補: (a) `core.symlinks=true` + Developer Mode で再 checkout、(b) `.gitattributes` で symlink を
  Windows でも扱う運用、(c) 必要資産を実ファイル化。windows-port では未対応（top-level ビルドで全 sample が動くため）。
<!-- SECTION:NOTES:END -->
