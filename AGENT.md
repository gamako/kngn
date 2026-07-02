# video-proto プロジェクト

クロスプラットフォーム対応のビデオ/グラフィックスプロトタイピング環境。Zigで記述されたアプリケーション層と、各プラットフォーム固有の実装（macOS: Objective-C/Swift/Metal、Linux: X11/Wayland、Windows: GDI/D3D11）による低レベルAPI層で構成されています。

**目的**: 最小限のプリミティブAPIを提供し、開発者が柔軟にグラフィックスアプリケーションを構築できる環境を提供する。

**対応プラットフォーム**: macOS（Objective-C / Swift / Metal）・Linux（X11 / Wayland）・Windows（GDI / D3D11）

## ディレクトリ構造

```
video-proto-main/
├── platform/           # macOS のネイティブ実装（C ABI。platform.h + 各実装）
│   ├── platform.h     # プリミティブAPI定義（C ABI。内部実装用）
│   ├── macos/         # Objective-C実装（CALayer）
│   ├── macos-swift/   # Swift実装（CADisplayLink）
│   └── macos-metal/   # Metal実装（GPU）
├── src/               # Zigコード
│   ├── main.zig       # メインプログラム（HSV 虹色グラデーション）
│   ├── platform.zig   # platform facade（builtin.os.tag で backend を分岐）
│   ├── platform_types.zig      # 共有型（KeyCode / Event 等の単一ソース）
│   ├── platform_macos.zig      # macOS backend（C ABI platform.h 経由。objc/swift/metal 共通）
│   ├── platform_linux*.zig     # Linux backend（dispatcher + x11 / wayland + 入力変換。純 Zig）
│   ├── platform_windows*.zig   # Windows backend（dispatcher + gdi / d3d11 + 入力変換。純 Zig）
│   ├── audio.zig / audio_*.zig # オーディオ出力 facade + OS 別 backend（macOS/Linux/Windows）
│   ├── dsp/           # DSP ヘルパー（Oscillator / Envelope / Filter / Mixer）
│   ├── harness.zig    # ヘッドレス検証 harness（入力注入 + フレーム捕捉 + 仮想クロック）
│   └── sprite.zig / text.zig / fixed_timestep.zig / fps_counter.zig / keyboard.zig  # Phase 2 ヘルパー群
├── examples/          # サンプル 01〜17（ルートから run-example_NN で実行）+ image/（共有アセット usako.png）
│   ├── 01_timed_window / 02_keyboard_input / 03_sprite_rendering / 04_fixed_timestep / 05_text_rendering
│   ├── 06_sprite_benchmark / 07_mouse_input / 12_outline_font / 15_audio_tone
│   ├── 08〜11,13,14,16,17_gui_*  # GUI（primitives/interaction/layout/widgets/slider/color_picker/scroll/toggles）
│   └── image/         # 共有アセット（実行 example ではない）
├── libs/              # 再利用ライブラリ
│   ├── png/           # PNG codec（decode/encode）
│   ├── gui/           # 即時モード GUI（入力 / ID stack / Flex レイアウト / 描画 / ウィジェット）
│   ├── font/          # フォント（TrueType/OpenType アウトライン sfnt/glyf/cff + bmfont。※ BDF は src/text.zig）
│   └── synth/         # シンセ（Voice / VoicePool / Patch / ロックフリー受け渡し）
├── apps/              # アプリケーション
│   ├── editor/        # グラフィックエディタ群（TASK-21 ファミリー）
│   │   ├── core/      # 再利用コア: Canvas(多レイヤ) / Tool(Pen/Eraser/Brush) / UndoStack / StrokeRecorder / Path / Selection / PNG I/O
│   │   └── apps/pixie/ # ドット絵エディタ（Pen/Eraser/レイヤー/範囲選択/ベジェ/DB16 パレット/Undo/PNG）
│   └── synth/         # PC キーボード演奏シンセ MVP（run-synth）
└── docs/              # ドキュメント
    ├── PLAN.md        # 実装計画（原初の Phase 分け）
    ├── PLAN_*.md      # 個別計画（example_02/03 / libs_gui / png_decoder 等）
    └── adr/           # アーキテクチャ決定記録
```
（タスク別の計画メモ `docs/plans/` はトップ階層 `video-proto/docs/plans/` 側。この配下ではない）

## クイックスタート

### 前提環境

| 項目 | 用途 |
|------|------|
| nix（flake 対応） | `flake.nix`（`aarch64-darwin` / `x86_64-linux` の 2 system）が zig 0.16.0 + zls + 各種依存を提供 |
| macOS（Apple Silicon）+ Xcode | macOS backend の SDK / framework / `swiftc` の提供 |
| Linux（x86_64） | X11/Wayland dev lib・Xvfb・ffmpeg 等は Linux 側 devShell が供給（下記「Linux のビルド・検証」） |
| Windows | zig 0.16.0 を現地導入しネイティブビルド（`flake.nix` は非対応。TASK-31/35） |
| direnv | プロジェクトディレクトリに入ると自動で nix devShell を有効化（推奨） |

### セットアップ

`flake.nix` で zig 0.16.0 と zls を pin している。`direnv allow` 一回でディレクトリに入れば自動で zig が PATH に通る。

```bash
direnv allow                     # 初回のみ（.envrc を許可）
zig version                      # → 0.16.0 が返ること
```

direnv を使わない場合は `nix develop` でシェルに入るか、各コマンドを `nix develop --command zig build` のように呼ぶ。

### メインプログラムのビルド・実行

以下は macOS の例。`-Dplatform` の有効値は OS 依存（macOS=objc/swift/metal、Linux=x11/wayland、
Windows=gdi/d3d11。他 OS 向けは下記「backend の選び方」「Linux のビルド・検証」を参照）。

```bash
# ビルド（macOS の 3 実装から選択。既定=objc）
zig build                        # Objective-C版（macOS 既定）
zig build -Dplatform=swift       # Swift版
zig build -Dplatform=metal       # Metal版

# 実行
zig build run                    # 既定 backend（macOS=objc / Linux=x11 / Windows=gdi）
zig build run-objc               # Objective-C版（macOS。run-swift / run-metal も同様）
```

### サンプルプログラムの実行

```bash
# 01_timed_window: 時間制限付きウィンドウ（緑→黄→赤）
cd examples/01_timed_window
zig build run

# 02_keyboard_input: インタラクティブなカラーパレット
cd examples/02_keyboard_input
zig build run

# 03_sprite_rendering: スプライト表示と移動
cd examples/03_sprite_rendering
zig build run
```

各 example ディレクトリには `build_helpers` というシンボリックリンク（`../../build_helpers` を指す）が
含まれている。これは Zig 0.16 の build root 外 `@import` 制約に対する workaround で、
build helper（`build_helpers/platform.zig` 等）を独立ビルドからも参照可能にしている。
clone 後にリンクが壊れた場合は `cd examples/<NAME> && ln -sf ../../build_helpers build_helpers` で再作成する。

> **Windows 制約（既知・未対応）**: Windows の git は既定（`core.symlinks=false` / 開発者モード OFF）では
> シンボリックリンクを実体化せず、リンク先パスを書いた**テキストファイル**として展開する。このため
> `examples/*/build_helpers`・`apps/editor/build_helpers` は Windows で壊れ、**sample 単体ビルド
> （`cd examples/<NAME> && zig build`）は Windows では失敗する**。トップ階層からの `zig build`
> （リポジトリ root）は build.zig が実パスを参照し symlink を経由しないため、Windows でも全 sample が動く。
> Windows で sample 単体ビルドが必要なら、開発者モード ON + `core.symlinks=true` で再 checkout して
> 本物の symlink を復元するか、build_helpers の symlink 依存を build.zig 側で外す改修が要る（現状は未対応）。

## 実装状況

プリミティブ API（イベント処理 / 手動描画 / 時刻取得）を土台に、以下が実装済み:

- ✅ **プラットフォーム backend**: macOS（objc/swift/metal）・Linux（x11/wayland）・Windows（gdi/d3d11）。
  frame pacing の support tier は下記「プラットフォーム層の種類」と `docs/adr/005`。
- ✅ **サンプル**: `examples/01`〜`17`（基礎描画 / 入力 / スプライト / 固定ステップ / テキスト /
  ベンチ / マウス / GUI 各種 / アウトラインフォント / オーディオ）。`examples/image/` は共有アセット（run step なし）。
- ✅ **ヘルパー**: sprite / fixed_timestep / fps_counter / text（`src/`。Phase 2 由来）。
- ✅ **ライブラリ**: `libs/png`（PNG codec）・`libs/gui`（即時モード GUI）・`libs/font`・`libs/synth`。
- ✅ **アプリ**: `apps/editor/apps/pixie`（ドット絵エディタ: レイヤー / 範囲選択 / ベジェ / Undo / PNG）・
  `apps/synth`（PC キーボード演奏）。
- ✅ **オーディオ / シンセ層**: `src/audio` + `src/dsp` + `libs/synth`（下記「オーディオ / シンセ層」節）。
- ✅ **ヘッドレス検証 harness**: `src/harness.zig`（下記「ヘッドレス検証 harness」節）。

> 原初の Phase 分け（プリミティブ / ヘルパー関数群 / テンプレート）は `docs/PLAN.md` に記録。
> DoubleBuffer や SimpleApp / GameLoop / SnapshotRenderer 等のテンプレート群は未着手。

## プラットフォーム層の種類

| 実装            | ファイル                                          | レンダリング  | 状態                  |
| --------------- | ------------------------------------------------- | ------------- | --------------------- |
| **Objective-C** | `platform/macos/platform_macos.m`                 | CALayer       | ✅ 完全動作           |
| **Swift**       | `platform/macos-swift/platform_macos.swift`       | CADisplayLink | ✅ 完全動作           |
| **Metal**       | `platform/macos-metal/platform_macos_metal.swift` | Metal GPU     | ✅ 1級 frame pacing 対応（TASK-36） |
| **X11 (Linux)** | `src/platform_linux_x11.zig`（純 Zig / Xlib 直接）  | XShm/XPutImage | ✅ window+blit+入力（TASK-28.2/28.3） |
| **Wayland (Linux)** | `src/platform_linux_wayland.zig`（純 Zig / wl_shm 直接）  | wl_shm (xdg-shell) | ✅ window+blit+入力（TASK-28.5。shiso 実機検証済み） |
| **GDI (Windows)** | `src/platform_windows_gdi.zig`（純 Zig / Win32 直接） | GDI `StretchDIBits`（software blit） | ✅ best-effort backend（TASK-31/35） |
| **D3D11 (Windows)** | `src/platform_windows_d3d11.zig`（純 Zig / COM 手書き vtbl） | D3D11-DXGI swap chain（upload path） | ✅ 1級 frame pacing 対応（TASK-35） |

**Metal版（TASK-36）**: ADR-005 の 1級 frame pacing 契約に適合。triple slot + inflight semaphore で
drawable/buffer の inflight ownership を管理し、`draw(in:)` 内に drawable 取得を集約して CAMetalLayerDrawable
lifecycle 警告を解消。`displaySyncEnabled` 明示で fifo（display refresh 同期）。詳細は `docs/adr/005`。

### backend の選び方（OS 依存）

`src/platform.zig`（facade）が `builtin.os.tag` で backend を切り替え、`build_options.platform_backend`
で具体実装を選ぶ。Linux では `src/platform_linux.zig`（dispatcher）が `platform_backend` で x11/wayland
実装を選ぶ（`platform_linux_x11.zig` / `platform_linux_wayland.zig`、共通の `getTime`/dialog は
`platform_linux_common.zig`）。Windows も同型で `src/platform_windows.zig`（dispatcher）が gdi/d3d11 を
選ぶ（`platform_windows_gdi.zig` / `platform_windows_d3d11.zig`、共通の window/入力/dialog/getTime/CPU backing は
`platform_windows_common.zig`）。`-Dplatform` の有効値は OS で変わる:

- **macOS**: `objc`（既定）/ `swift` / `metal`
- **Linux**: `x11`（既定）/ `wayland`。wayland は TASK-28.5 で display/入力/pixie まで実装し shiso 実機で
  検証済み（busy loop の present flood は frame callback(vsync)律速で対処）。
- **Windows**: `gdi`（既定、best-effort）/ `d3d11`（1級 frame pacing）。純 Zig で Win32 API を extern fn /
  COM 手書き vtbl で直接呼ぶ（TASK-31/35）。

不整合（例: Linux で `-Dplatform=objc`）は明確な build エラーになる。共有型（`KeyCode`/`Event` 等）は
`src/platform_types.zig` が単一ソース。

### Linux（x86_64）のビルド・検証

`flake.nix` は `aarch64-darwin` と `x86_64-linux` の 2 system を提供する。Linux 側 devShell は
zig 0.16 + zls + X11 dev lib（`libX11`/`libXext`）+ Xvfb（`xorgserver`）+ `xwd` + `ffmpeg` + `zenity` + `xdotool`（入力合成）を含む。

**ソース転送（jackjack / shiso は jj/git remote 無し）**: Mac から `scripts/sync-to.sh <host>` で
`video-proto-main/` を `<host>:~/video-proto-main/` へ rsync ミラーしてから現地でネイティブビルドする。
`.zig-cache`/`zig-out`/`.git`/`.jj`/`.DS_Store` は除外するので現地のビルドキャッシュは保持される。

```bash
bash scripts/sync-to.sh jackjack        # 転送（shiso も同様にホスト名を渡す）
bash scripts/sync-to.sh -n jackjack     # dry-run（--delete の前に差分確認）
```

入力（key/mouse/scroll/modifier）は `src/platform_linux_x11.zig` が XEvent を変換する（TASK-28.3。dispatcher 化で 28.5.1 にファイル移動）。物理キーは evdev
X keycode 表で `KeyCode` へ（layout 非依存・KeySym 不使用）。純粋な変換ロジックは `src/platform_linux_input.zig`
（`@cImport` しない純 Zig）に分離し、`zig build test-platform-input` で **display 無しでも単体テストできる**（集約 `test` に含む）。

```bash
# devShell に入る（direnv 不在の環境では nix develop を使う）
nix develop --command zig build -Dplatform=x11   # x11 backend をビルド

# 入力変換の単体テスト（X server 不要・OS 非依存）
nix develop --command zig build test-platform-input

# ヘッドレス検証（GUI セッション無しの SSH 環境向け）: Xvfb 上で実行 → PNG 撮影
nix develop --command bash scripts/xvfb-screenshot.sh out.png                 # root window を撮影（疎通確認）
nix develop --command bash scripts/xvfb-screenshot.sh out.png -- zig-out/bin/video_proto  # アプリを撮影

# 入力の合成（xdotool）: Xvfb 上のアプリへキー/マウス/ホイールを送って挙動を確認（TASK-28.3）
#   DISPLAY=:99 xdotool key a / mousemove X Y / click 1 / click 4(=wheel up)
```

#### Wayland backend（`-Dplatform=wayland`、TASK-28.5）

Wayland backend（`src/platform_linux_wayland.zig`、wl_shm + xdg-shell + wl_keyboard/pointer + xkbcommon）は
**実コンパイル/表示/入力に Linux + Wayland ライブラリと実セッションが必要**で、macOS では検証できない（shiso 等の Linux で確認）。
純粋な入力変換は `src/platform_wayland_input.zig`（`@cImport` しない純 Zig）に分離し、`zig build test-platform-wayland-input` で
**display 無しでも単体テストできる**（macOS/集約 `test` に含む）。物理キーは X11 と同じ evdev+8 表で `KeyCode` へ（layout 非依存）。

```bash
nix develop --command zig build -Dplatform=wayland          # wayland backend をビルド
nix develop --command zig build run-pixie -Dplatform=wayland # pixie を Wayland で起動
nix develop --command zig build test-platform-wayland-input  # 入力変換の単体テスト（compositor 不要・OS 非依存）
```

**ヘッドレス検証（GUI セッション無しの SSH 環境向け、TASK-28.5.5）**: `scripts/wayland-screenshot.sh` が
headless compositor 上でアプリを動かし PNG 撮影する（X11 の `xvfb-screenshot.sh` の Wayland 版）。既定は
sway（`WLR_BACKENDS=headless`）+ `grim`、`WAYLAND_SHOT_COMPOSITOR=weston` で weston（headless backend）+
`weston-screenshooter` に切替。

```bash
nix develop --command bash scripts/wayland-screenshot.sh out.png                                  # compositor 出力を撮影（疎通確認）
nix develop --command bash scripts/wayland-screenshot.sh out.png -- zig-out/bin/video_proto        # main を撮影（虹色表示の smoke）
WAYLAND_SHOT_COMPOSITOR=weston nix develop --command bash scripts/wayland-screenshot.sh out.png -- zig-out/bin/video_proto
```

> compositor の headless 起動法・出力名・screenshooter 権限は **実機（shiso）依存**で、最終調整は shiso で行う
> （macOS では Wayland を実行できない。スクリプトは `bash -n` の構文確認のみ可能）。

**入力合成の現実解と自動化範囲（TASK-28.5.5）**: X11 の `xdotool` のような統一手段は Wayland に無い。

- **keyboard**: `wtype`（Wayland virtual-keyboard protocol）。compositor の対応に依存（headless sway/weston で
  効くかは shiso 確認）。compositor の socket が専用 `XDG_RUNTIME_DIR` 配下にある場合はそれも渡す:
  `XDG_RUNTIME_DIR=<dir> WAYLAND_DISPLAY=wayland-N wtype a`（実 session なら既存の環境変数のまま `wtype a`）。
- **mouse / scroll**: compositor 固有手段か `ydotool`。`ydotool` は `/dev/uinput` の権限（root / `input` グループ /
  systemd サービス）が要り CI 的自動化のリスクが大きいため、**devShell には含めず手動確認レンジ**とする。
- **自動化できる範囲**: headless compositor 起動 + main の screenshot smoke +（compositor が対応すれば）`wtype` の
  keyboard smoke。
- **手動確認レンジ**: mouse move/click/scroll、pixie の canvas 描画・GUI hover/press/drag・undo、zenity dialog の
  実 Wayland session 表示。これらは通常のユーザー Wayland session（GNOME/KDE/Sway 等）で目視確認する。

**zenity ファイルダイアログ（pixie の PNG open/save、TASK-28.5.4）の Wayland 表示条件**:
`saveFileDialog`/`openFileDialog` は X11/Wayland 共通で `src/platform_linux_common.zig` の zenity サブプロセスを使う
（backend 非依存）。zenity は GTK アプリのため、表示は session 環境に依存する:

- 通常の Wayland desktop session（GNOME/KDE/Sway 等）では `WAYLAND_DISPLAY` 下で GTK/zenity が動き、file chooser が出る。
- file chooser は環境により `xdg-desktop-portal`（+ backend service）の有無に影響される。
- SSH / headless compositor / 最小 weston では portal や desktop integration が無く、**window 本体は出ても dialog が出ない**、
  または GTK 初期化失敗（`error.DialogFailed`）になりうる。dialog 確認は通常のユーザー Wayland session 上で行う。
- dialog が出ないときは AC 失敗と即断せず、`zenity` の有無 / `WAYLAND_DISPLAY` / `DISPLAY`(XWayland) /
  `XDG_CURRENT_DESKTOP` / `xdg-desktop-portal` の起動状態を切り分ける。

## 主要なプラットフォームAPI

caller は `@import("platform")` で Zig 高レベル API (`src/platform.zig`) にアクセスする。
C ABI (`platform/platform.h`) は内部実装で、バックエンド (`src/platform_macos.zig`) のみが直接利用する。

### コアプリミティブ
- `platform.init()` / `platform.shutdown()` - 初期化/終了 (`Error!void`)
- `platform.Window.create(w, h, title) Error!Window` / `window.destroy()` - ウィンドウ管理

### イベント処理
- `window.pollEvents()` - イベントポーリング（ノンブロッキング, bool）
- `window.nextEvent()` - イベント取得（`?platform.Event` tagged union）
- `platform.Event` - `quit` / `key_down: KeyEvent` / `key_up: KeyEvent` の union(enum)
- `platform.KeyCode` - non-exhaustive `enum(c_int)` で物理キーを表現
- `platform.ModifierFlags` - `packed struct(u32) { shift, ctrl, alt, cmd, _reserved }`

### 手動描画
- `window.lockFramebuffer()` - 描画可能な frame slot があれば取得、なければ `null`（`?Framebuffer`）。`null` は retry 可能な frame slot unavailable で fatal ではない（Wayland の frame callback / busy buffer 律速が実例。macOS/X11/GDI は現状常に non-null）
- `fb.unlock()` - フレームバッファアクセス終了
- `window.present()` - 描画済みフレームを表示キューへ submit（frame 確定点。vsync 待ち関数ではない）。present 後の pixels は backend 所有で caller は触らない
- frame pacing / vsync / buffer ownership 契約と backend の support tier（**1級** = Metal / D3D11-DXGI / Wayland、**best-effort** = CALayer objc/swift / X11 / GDI）は `docs/adr/002`（改訂）と `docs/adr/005` を参照

### ユーティリティ
- `platform.getTime()` - 高精度モノトニック時刻取得

## エディタ（apps/editor + libs/gui）

`apps/editor/` はグラフィックエディタ群（TASK-21 ファミリー）。共通基盤の上に複数の小アプリ
（現状は pixie。将来 paintly / tilex / animix）を載せる構成。

- **libs/gui**: 即時モード GUI。入力管理（hot/active + ID stack）/ Flex レイアウト / 描画プリミティブ /
  ウィジェット（Button / Label / ColorSwatch / Slider）。`@import("gui")` で使う。
- **apps/editor/core**: アプリ非依存の再利用コア（platform / GUI を import しない）。
  `Canvas`（レイヤ・合成・座標変換）/ `Tool`(vtable, Pen/Eraser) / `UndoStack` / `StrokeRecorder` /
  PNG I/O。使い方は **`apps/editor/core/README.md`** を参照。
  - 不変条件: 表示は `composite()`（白背景合成）。**PNG 保存は `savePNG` に渡す pixels を用途で使い分け**（白背景 `composite()` は保存に使わない）: core の round-trip は raw layer pixels（`layerPixels(idx)`、透明保持）、pixie の通常保存（TASK-43 以降）は全 visible layer を合成した `compositeStraight()`（フラット透明 PNG。単層 opacity=255 で raw と恒等）。pixie の PNG open はフラット画像を layer0 へ読み込み layer 構造は保持しない。
- **apps/editor/apps/pixie**: ドット絵エディタ MVP。`canvas_input.zig`（入力状態機械）が
  press 起点 capture → Tool 経由で stroke を駆動する。

> 注: エディタのタスク管理はトップ階層（`video-proto/`）の Backlog.md CLI で行う（上位 AGENTS.md 参照）。
> Zig 0.16 のイディオムは `zig-best-practices` スキルを参照。

## オーディオ / シンセ層（TASK-27 ファミリー）

グラフィックスと対称な 4 層構成でオーディオ（音）シンセサイザー基盤を構成する。設計の正は
トップ階層の `docs/plans/synth-foundation-plan.md`。

| 層 | 場所 | 内容 |
|---|---|---|
| **L1 platform** | `src/audio.zig`（facade）+ `src/audio_{macos,linux,windows}.zig`（OS 別実装） | オーディオ出力プリミティブ（`open/start/stop/close/config`）。各 OS ネイティブ API を **extern fn / COM 手書き** で叩く（`@cImport` しない）: macOS=AudioUnit(AudioToolbox) / Linux=ALSA(`alsa`=libasound) / Windows=WASAPI(ole32)。audio backend は audio を使う exe にのみ link（既存 exe は不変）。 |
| **L2 helpers** | `src/dsp/`（`@import("dsp")`） | Oscillator / Envelope(ADSR) / Filter(TPT SVF) / Mixer + denormal 対策。純 Zig。 |
| **L3 libs** | `libs/synth/`（`@import("synth")`） | Voice / 固定 VoicePool（スチール + done 回収）/ Patch / Synth。GUI⇔Audio のロックフリー受け渡し（SPSC `NoteQueue` / `AtomicF32` / `DoubleBuffer` / 出力タップ `SampleTap`）。dsp に依存。 |
| **L4 apps** | `apps/synth/`（`run-synth`）+ `examples/15_audio_tone`（`run-example_15`） | PC キーボード演奏 MVP / サイン波最小サンプル。 |

**最重要のスレッドモデル**: グラフィックスはメインスレッド（macOS=CADisplayLink 等）、オーディオは
render callback で駆動される（macOS=CoreAudio が OS の RT スレッドで pull / Linux=ALSA・Windows=WASAPI は
backend が自前の再生スレッド `std.Thread` を spawn して push）。**callback の実行区間では malloc/lock/IO/panic 禁止**
（backend 非依存の RT 契約。callback 外の backend I/O はブロッキング可）。
メイン⇔RT のデータ交換は `libs/synth` のロックフリー機構（note は SPSC、連続パラメータは atomic、
出力タップは drop 可）で行う。

### Linux で音を鳴らす前提条件（ALSA→PipeWire、TASK-28.7.1）

Linux の音声は ALSA `default`→PipeWire ブリッジ（外部プラグイン `libasound_module_pcm_pipewire.so` を
libasound が dlopen）を通る。`run-example_15` / `run-synth` が Linux で発音するには次の条件が要る。

1. **アプリの libasound 版 ≥ host の pipewire ALSA プラグインのビルド版**。古いと plugin が dlopen できず
   `NoDevice` になる（プラグイン版が新しい NixOS unstable 等で顕在化）。flake は `alsa-lib` だけ host と同
   version/src を使うが、**ビルドは 25.11 の stdenv で行う**（`flake.nix` の `alsaLibFor`）。unstable の
   alsa-lib を丸ごと使うと unstable の glibc を引き込み、古い system glibc の distro（Ubuntu 24.04 等）で
   `GLIBC_ABI_* not found` で実行不能になるため、glibc は 25.11 のまま alsa symbol だけ上げる。
2. **PipeWire に sink がある状態**。sink は wireplumber が `/dev/snd/*` を開けて初めて生成される。
   `/dev/snd/*` は `root:audio` なので、アクセスには次のいずれかが要る:
   - **active な seat セッション**（VT/物理ログイン）。logind が動的 device ACL を付与する（**揮発的**:
     セッションが idle/非アクティブになると剥がれ sink が消える）。
   - **`audio` グループ**に user を追加（永続）。**graphical セッション無しの純 SSH / headless 検証**は
     こちらが要る（`users.users.<user>.extraGroups = [ "audio" ];` → rebuild → relogin/reboot）。
3. **確認コマンド**: `wpctl status`（Audio Sink が出ているか）、`ldd zig-out/bin/example_15 | grep asound`
   と `LD_DEBUG=libs`（実行時にロードされる libasound が host plugin 要求版以上か）。
4. backend 実装（`src/audio_linux.zig` の hw_params 折衝）は**変更不要**。当初 pipewire 1.6.5 で
   `snd_pcm_hw_params` が失敗するのを hw_params の問題と疑ったが、実機調査で真因は sink 不在（ENOENT）と判明。
   sink さえあれば現行 `period`/`buffer` の組合せがそのまま通る。

> 検証機 jackjack は NixOS（version 表示は 26.11 だが実体は **nixos-unstable**。`nixos-26.11` ブランチは未存在）。
> jackjack で Apple T2 は `apple-t2x4.conf` プロファイルで Speakers/Headphones sink を生成する。

## ヘッドレス検証 harness（TASK-32 ファミリー）

AI がアプリの出力を手軽に確認するための仕組み。`src/platform.zig`(facade) の 4 フック（`pollEvents`/`nextEvent`/`present`/`getTime`）に `src/harness.zig` を interpose し、**アプリ無改造**で「入力注入 + フレーム捕捉 + 仮想クロック」を行う。env 未設定なら全フック即パススルー（既存挙動と完全一致）。設計の正はトップ階層の `backlog/decisions/decision-1` と TASK-32 系タスク。

- **P1（TASK-32.1, 実装済み）**: file replay + 組み込み `fb` probe（framebuffer→PNG / 1行 digest）+ 仮想クロック。
- **P2（TASK-32.2, 実装済み）**: live 制御（TCP loopback + driver CLI `scripts/drive`）/ 組み込み `audio`・`stats` probe / record→replay。
- **P3（TASK-32.3, 実装済み）**: custom probe レジストリ。app が `platform.registerProbe(...)` で probe を opt-in 登録（pixie=`canvas`/`undo`/`tool`, synth=`voices`/`patch`）。詳細は下記「custom probe の足し方」。
- **P4 以降（未実装）**: offscreen / 完全 display-less / Metal の GPU drawable 読み戻し（描画後の合成サーフェスの readback）。
  - 注: `fb` probe は**手動描画 API の CPU フレームバッファ**を捕捉する backend 非依存実装なので、**objc / swift / metal いずれでも `snapshot fb` は撮れる**（Metal も同じ CPU バッファを供給し、実測で objc と fb crc が bit 一致）。P4 の「Metal」は CPU バッファ経路ではなく GPU drawable の読み戻しを指す。

### コマンド言語（file replay と live で共通）

1コマンド/行（区切りは改行 **または `;`**。`#` はコメント）。**file・live で同一文法**:

```text
inject key_down A          # key_down/key_up <KEY> [修飾子...]（KeyCode 名。大小無視。例 A / SPACE / ESCAPE / LEFT / 0）
inject key_down S cmd shift # 末尾に shift/ctrl/alt/cmd を 0 個以上（順不同・大小無視）。例: Cmd+Shift+S
inject mouse_move 100 120  # mouse_move <x> <y> [修飾子...]
inject mouse_down left alt # mouse_down/up <left|right|middle> [修飾子...]
inject scroll 0 -3 ctrl    # scroll <dx> <dy> [修飾子...]
step 5                     # 5 フレーム進める（省略時 1）
snapshot fb  /tmp/out.png  # 直近 present フレームを PNG 保存（省略時 $VP_HARNESS_OUT/frame_<n>.png）
snapshot audio /tmp/a.wav  # 直近の audio tap を PCM16 WAV 保存（省略時 audio_<n>.wav）
snapshot stats /tmp/s.json # stats を JSON 保存（省略時 stats_<n>.json）
digest fb                  # fb <w>x<h> crc=<hex> top=[#RRGGBB:NN%,...]
digest audio               # audio rms=<f> peak=<f> f0=<Hz> silent=<0|1> frames=<n>（mono downmix・自己相関 f0）
digest stats               # {"frame":..,"virtual_fps":60.0,"mouse_move_merge_count":..,...}（JSON 1行）
quit                       # 終了（EOF でも終了）
```

- **組み込み probe（framework 所有）**: `fb`(framebuffer→PNG/digest) / `audio`(libs/synth 等の出力を facade `src/audio.zig` が tap→WAV/digest) / `stats`(EventStats + 仮想 fps→JSON)。
  `audio` は **直近窓（latest-wins）** を測るので「今鳴っている音」を assert できる（無音は silent=1, f0=0）。`virtual_fps` は仮想クロック由来の固定値（≒60。実性能ではない）。
- **custom probe（app 所有・opt-in / TASK-32.3）**: app が `platform.registerProbe(...)` で登録した名前。`snapshot <name>` / `digest <name>` を組み込みと同じ文法・出力で扱える。現状: pixie=`canvas`(composite フラット透明 PNG / `WxH layers=N selected=.. comp=XXXXXXXX lN{v=..,op=..,crc=..,nz=..}`) / `undo`(`{"depth":N,"redo":M}`) / `tool`(`tool=Pen color=#RRGGBB`)、synth=`voices`(`{"active":N,"capacity":16,"voices":[{"note":..,"stage":".."}]}`) / `patch`(現在 patch JSON)。**framework は custom probe の中身を解釈しない**（raw bytes と1行 digest をルートするだけ）。
- **digest の出力先**: replay=stderr に `[harness] digest <probe> <payload>`、live=接続レスポンスに prefix なしの `<probe> <payload>`。snapshot は file 保存し、live はそのパスを返す。
- **inject の修飾子トークン（TASK-32.5）**: `inject` の必須引数の後に `shift`/`ctrl`/`alt`/`cmd` を 0 個以上付けると、その KeyEvent/MouseEvent の `modifiers` に反映される（順不同・大小無視）。key_down/up・mouse_move/down/up・scroll の全経路で使える。例: `inject key_down S cmd`（Cmd+S）/ `inject key_down Z cmd`（undo）/ `inject mouse_down left alt`。**未知トークンが 1 つでもあれば警告を出し、そのイベントは注入されない（fail-fast。修飾子名の typo を握りつぶさない）**。修飾子無しは従来通り空 modifiers。

### 使い方（replay = file トランスポート）

```bash
cat > /tmp/script.txt <<'EOF'
inject key_down A; step 2; digest fb; snapshot fb /tmp/out.png
quit
EOF
VP_HARNESS_SCRIPT=/tmp/script.txt VP_HARNESS_OUT=/tmp zig build run            # main（example/synth 等も無改造で可）
# → /tmp/*.png を Read で目視、digest を assert（同一スクリプト再実行で PNG は bit 一致＝決定論）

zig build test-harness   # 単体テスト（parser/実行モデル/仮想クロック/audio 解析/WAV/stats。display 不要・backend 非依存）
```

### 使い方（live = TCP loopback + driver CLI）

アプリを背景起動しておき、`scripts/drive` で1接続=1リクエスト=1レスポンスを叩く。状態はプロセスに残る。

```bash
zig build drive                                   # 一度だけ zig-out/bin/drive を生成（zig build でも入る）
VP_HARNESS_LIVE=1 VP_HARNESS_PORT_FILE=/tmp/vp.port VP_HARNESS_OUT=/tmp \
  VP_HARNESS_RECORD=/tmp/live.txt zig build run-synth &        # 背景起動（ephemeral port を /tmp/vp.port に出力）
# 固定 port は VP_HARNESS_PORT=<n>。ポートは stderr にも出る。
scripts/drive --port-file /tmp/vp.port 'inject key_down A; step 5; digest fb'   # → fb ... を stdout に返す
scripts/drive --port-file /tmp/vp.port 'digest audio'                          # → audio rms=.. f0=.. ..
scripts/drive --port-file /tmp/vp.port 'snapshot fb /tmp/out.png'              # → /tmp/out.png
scripts/drive --port-file /tmp/vp.port 'quit'                                  # アプリ終了
# record→replay 対称: 上の VP_HARNESS_RECORD のログを replay すれば同じコマンド列を再現できる
VP_HARNESS_SCRIPT=/tmp/live.txt VP_HARNESS_OUT=/tmp zig build run-synth
```

| env | 役割 |
|---|---|
| `VP_HARNESS_SCRIPT=<file>` | **replay** 有効化（file トランスポート） |
| `VP_HARNESS_LIVE=1` | **live** 有効化（ephemeral port で listen） |
| `VP_HARNESS_PORT=<n>` | live を固定 port で有効化 |
| `VP_HARNESS_PORT_FILE=<file>` | 選ばれた port の出力先（省略時 `$VP_HARNESS_OUT/harness.port`） |
| `VP_HARNESS_RECORD=<file>` | live 受信コマンドを追記（→ `VP_HARNESS_SCRIPT` で replay 可能） |
| `VP_HARNESS_OUT=<dir>` | snapshot 省略 path / port file の既定ディレクトリ |

> SCRIPT と LIVE/PORT の同時指定はエラーで無効化（1プロセス1トランスポート）。env 未設定なら全フック即パススルー。

### custom probe の足し方（TASK-32.3）

app が内部状態を opt-in で probe として公開する。**framework（`src/harness.zig`）には probe 固有のコードを一切足さない**（中身非パースの不変条件）。手順:

1. app（`@import("platform")` 済み）で probe の callback を書く:
   - `digest: fn(ctx: *anyopaque, buf: []u8) []const u8` — 1行テキストを `buf`（最大 1024B）へ書いて返す（改行を含めない）。
   - `snapshot: fn(ctx: *anyopaque, allocator) anyerror![]u8` — raw バイト列を `allocator` で確保して返す（harness が file へ書き、**同じ allocator で free**）。null 可。
   - `ctx` は app 状態へのポインタ（例 `*App`）。callback 内で `@ptrCast(@alignCast(ctx))` で戻す。
2. `platform.init()` 後・main loop 前に登録する:
   ```zig
   platform.registerProbe(.{ .name = "canvas", .ctx = &app, .ext = "png",
       .snapshot = canvasSnapshot, .digest = canvasDigest });
   ```
3. これだけで `snapshot canvas [path]` / `digest canvas` が replay・live 両方で使える。

規約・制約:
- **snapshot=raw bytes / digest=1行 / 画像=PNG・構造化=JSON|text**（組み込みと同一規約）。
- `fb` / `audio` / `stats` は予約名（登録拒否）。同名 custom は上書き。registry 上限は 16。
- `registerProbe` は **harness 無効時（env 未設定）は no-op**なので、通常実行に影響しない（常に呼んでよい）。
- audio RT スレッドが触る状態（synth `voices`/`patch` 等）の読み出しは torn し得る best-effort スナップショット。**RT 経路に同期/alloc/lock を足さない**。
- 実装の手本: pixie の `canvas`/`undo`/`tool`（`apps/editor/apps/pixie/main.zig`）、synth の `voices`/`patch`（`apps/synth/main.zig`）。

- **実行モデル**: 非 step（inject/snapshot/digest）は即実行（inject は当該フレームに注入、snapshot/digest は直近 present 済みフレーム / audio tap を読む）。`step N` が pollEvents を N 回だけ true にしてフレームを進める。live では未消費コマンドが尽きると `pollEvents` が **次の接続を accept でブロック**（= step 待ちで block）。
- **仮想クロック**: harness 有効時 `getTime()` = `frame_index/60`（getTime 利用アプリの replay を決定論化）。
- **制約**: 実ウィンドウは生成する（display 必須。macOS は通常 OK、Linux は Xvfb/実セッション）。完全 display-less は P4。`audio` は RT スレッド実時間依存なので record→replay で digest の bit 一致は非保証（`fb` は仮想クロックで bit 決定論）。live の accept ブロック中は window pump が止まる。`fb` の捕捉は CPU フレームバッファ経路で **objc / swift / metal いずれでも可**（実測で objc と Metal の fb crc は bit 一致）。P4 なのは Metal の GPU drawable 読み戻しの方。
- **driver は std.Io.net 1本実装**で mac/Linux/Windows 共通コード（`drive` は OS gate 無しで常時 install される。Windows 上での動作は未検証）。`scripts/drive` は `zig-out/bin/drive` を直接 exec する薄い wrapper（応答 stdout を汚さない）。

## 性能規約（メモリI/O・キャッシュ最適化）

2026-07 の全ホットパス監査に基づく規約。RT 契約（「オーディオ / シンセ層」節）が全 backend で
守られているのと同じ強度で、以下も**新規実装・変更時の必須規約**として扱う。手本が既にコード内に
あるものは車輪を再発明せず踏襲する。

### ホットパス宣言（すべての新規ループに）

コードを書く前に「このループはどの頻度で走るか」を判定し、**フレーム毎（全画素）/ RT（毎サンプル）
の場合はファイル or 関数の doc comment に明記**する（例: `/// 毎フレーム全画素を走る`）。
実装計画（backlog の plan 欄）にも同じ宣言を含める。頻度の判定を誤ると以下の規約の要否を誤る。

### 全画素ループの3点セット（`src/sprite.zig` が手本）

フレーム毎に全画素（またはそれに準ずる面積）を走るループは:

1. **SIMD**: `@Vector(16, u8)` の 4px 同時ブレンド（`sprite.zig` の `blend4Pixels` 型）+ scalar tail。
   **SIMD 版とスカラー参照版の bit 一致テストを必ず併設**する（`sprite.zig` 既存テストが手本）。
2. **per-pixel 除算の禁止**: `/255` は `div255` 整数近似 `(x + 1 + (x >> 8)) >> 8` を使う。
   浮動小数点も per-pixel では使わない（AA カバレッジ計算等、本質的に f32 な処理は除く）。
3. **clip/bounds のループ外ホイスト**: clip 交差はループ**外**で1回計算し、内側は無検査の
   行連続アクセスにする。per-pixel の clip 比較・bounds 再チェックは禁止。

加えて: 不透明（`a==255`）で全面を塗る経路には `@memset` / 一括書き込みの高速パスを用意する。
行優先（row-major）の連続アクセスを守り、行頭オフセットはループ外で計算する。

### RT / スレッド間共有の追加規約

- スレッド間で producer/consumer が別々に触る atomic ペア（SPSC の head/tail 等）は
  `std.atomic.cache_line` で**別キャッシュラインに分離**する（false sharing 回避）。
- 1 producer / 1 consumer の値受け渡しで consumer 読み取り中の上書きを許せないものは
  **2枚バッファでなく3枚**（triple buffer。`libs/modular` の `Mailbox` が手本）。
- ブロック内で複数回参照するパラメータはブロック先頭で**1回 latch** する。
- 毎サンプルの超越関数（`pow`/`tan`/`exp`）は禁止。ブロックレート（`updateParams`/`prepareBlock`）
  へ集約するか、dirty-gate + control-rate 間引き（`libs/modular` の VCF が手本）にする。

### アロケーション

- 出力サイズが概算できるループ内 append は `ensureTotalCapacity` で事前確保する。
- 履歴・キューなど単調に増える構造には容量上限（trim / リング）を設計時に決める。
- （既存規約の再掲）フレーム毎の一時メモリは GUI の per-frame arena、RT は comptime 固定長。

### 性能の主張はテストで固定する

「ゼロアロケーション」「係数再計算はブロックレート」「SIMD=スカラー一致」等の性能上の性質は、
文章でなく**実行可能なテストで固定**する。手本（いずれも実装済み）:

- RT ゼロアロケーション: `FailingAllocator` で実測（`libs/modular/src/dyn.zig` のテスト）
- 係数再計算回数の上限 assert（`libs/modular/src/modules.zig` の VCF テスト）
- SIMD vs スカラー参照の bit 一致（`src/sprite.zig`）

### 測定（bench）

性能目的の変更タスクは `zig build bench-*`（TASK-50 で整備）の**前後比較を notes に記録**する。
測定なしの「速くなったはず」は不可。マイクロベンチが無い領域を最適化する場合は先にベンチを足す。

> 監査の詳細（既知ギャップ一覧と根拠 file:line）は backlog TASK-50〜61 の description を参照。

## よく使うコマンド

```bash
# すべてのプラットフォーム版をビルド（example / platform のビルド回帰確認にも使う）
zig build -Dinstall-all=true

# すべてのテストを実行（集約。全 test-* を束ねる）
zig build test

# 個別テスト（集約 test に全て含まれる）
zig build test-core             # editor/core（undo + tool）+ pixie 入力状態機械
zig build test-gui              # libs/gui
zig build test-png-roundtrip    # PNG encode/decode round-trip（+ canvas 単体）
zig build test-png-format       # PNG format 変換
zig build test-text             # BDF パーサ + テキスト描画
zig build test-font             # libs/font（bmfont 等）
zig build test-sprite           # sprite ブレンド / 描画
zig build test-dsp              # src/dsp（Oscillator / ADSR / Filter / Mixer）
zig build test-synth            # libs/synth（SPSC リング / atomic / Voice / VoicePool / Synth）
zig build test-spectrogram      # apps/synth スペクトログラム（FFT 列ロジック）
zig build test-scope            # apps/synth オシロスコープ / レベルメータ
zig build test-harness          # harness（parser / 実行モデル / 仮想クロック）
# 入力変換の単体テスト（display/compositor 不要）: test-platform-input / -wayland-input / -windows-input / -convert / test-platform-types

# マイクロベンチ（性能変更の前後比較。ReleaseFast 固定・display/audio デバイス不要・OS 非依存。TASK-50）
zig build bench-canvas          # Canvas.composite / compositeStraight の ns/frame・Mpx/s
zig build bench-synth           # Synth(16voice).render / MasterEffects.process の ns/block・×realtime

# Pixie エディタの実行（-Dplatform で objc/swift/metal 切替）
zig build run-pixie

# Synth アプリの実行（PC キーボード演奏。A..K = C4..C5、ESC で終了）
zig build run-synth

# 特定のサンプルを実行（ルートから。run-example_01 〜 _17）
zig build run-example_01        # 01_timed_window
zig build run-example_04        # 04_fixed_timestep
zig build run-example_05        # 05_text_rendering
zig build run-example_07        # 07_mouse_input
zig build run-example_15        # 15_audio_tone
zig build run-example_17        # 17_gui_toggles（checkbox/toggle/radio。TASK-48）
# 一覧: 01_timed_window / 02_keyboard_input / 03_sprite_rendering / 04_fixed_timestep / 05_text_rendering /
#       06_sprite_benchmark / 07_mouse_input / 08_gui_primitives / 09_gui_interaction / 10_gui_layout /
#       11_gui_widgets / 12_outline_font / 13_gui_slider / 14_gui_color_picker / 15_audio_tone /
#       16_gui_scroll / 17_gui_toggles  （image/ は共有アセットで run step なし）
```

---

## プロジェクト管理

実装プランは docs/PLAN.md に記述

# version management
バージョン管理はjjを使用します。gitとは異なる管理概念です。その他の作業はユーザーに相談すること。
```
jj new -m "v0.2.0リリース準備" # 新しい作業ブランチを作成
jj commit -m "変更内容"        # 変更をコミット
jj log                         # 履歴を表示
```
## コミット規約

### Conventional Commits

コミットメッセージは以下の形式に従います：

```
<type>: <subject>

[optional body]
```

#### Type 一覧

| Type       | 説明             | 例                                     |
| ---------- | ---------------- | -------------------------------------- |
| `feat`     | 新機能           | `feat: CSVインポート機能を追加`        |
| `fix`      | バグ修正         | `fix: 金額の負値処理を修正`            |
| `test`     | テスト追加・修正 | `test: Transaction型のテストを追加`    |
| `docs`     | ドキュメント     | `docs: READMEにインストール手順を追加` |
| `refactor` | リファクタリング | `refactor: CSV解析ロジックを分離`      |
| `style`    | フォーマット     | `style: rustfmt適用`                   |
| `chore`    | ビルド・設定     | `chore: 依存関係を更新`                |
