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
│   ├── macos-shared/  # swift/metal 共有実装（EventQueue/入力/IME/window C ABI/@_cdecl。TASK-140）
│   ├── macos-swift/   # Swift実装（CADisplayLink + CALayer present のみ）
│   └── macos-metal/   # Metal実装（GPU renderer + drawable present のみ）
├── core/              # L1 薄い base（platform に依存 / libs に依存しない）。ADR-007 R1
│   ├── platform.zig   # platform facade（builtin.os.tag で backend を分岐）
│   ├── platform_types.zig      # 共有型（KeyCode / Event 等の単一ソース。type-only module）
│   ├── platform_macos.zig      # macOS backend（C ABI platform.h 経由。objc/swift/metal 共通）
│   ├── platform_linux*.zig     # Linux backend（dispatcher + x11 / wayland + 入力変換。純 Zig）
│   ├── platform_windows*.zig   # Windows backend（dispatcher + gdi / d3d11 + 入力変換。純 Zig）
│   ├── platform_native_stub.zig # native .o archive 公開用 stub（TASK-29.1）
│   ├── audio.zig / audio_*.zig # オーディオ出力 facade + OS 別 backend（macOS/Linux/Windows/null）
│   └── control/       # 制御＋観測プレーン（ADR-007 R3）
│       └── harness.zig # ヘッドレス検証 harness（入力注入 + フレーム捕捉 + 仮想クロック）
├── src/               # 未移設の Zig コード（R8 日和見: 次に触るタスクで libs へ移す）
│   ├── main.zig       # メインプログラム（HSV 虹色グラデーション）
│   ├── dsp/           # DSP ヘルパー（Oscillator / Envelope / Filter / Mixer）→ 将来 libs/audio
│   ├── gamepad.zig    # ゲームパッド入力ヘルパー（kit 収録。TASK-80.1）
│   └── text.zig       # BDF テキスト（→ 将来 libs/gfx 隣接）
├── kit/               # 公開 umbrella モジュール（ADR-007 R4）。apps と外部消費者はこれのみ import
│   └── kit.zig        # platform / control / types / audio / gui / png / font / dsp / synth / gamepad / recipe / gmath / gfx / appshell / sound / midi 等を再エクスポート
├── examples/          # サンプル 01〜31（ルートから run-example_NN で実行）+ image/（共有アセット usako.png）
│   ├── 01_timed_window / 02_keyboard_input / 03_sprite_rendering / 04_fixed_timestep / 05_text_rendering
│   ├── 06_sprite_benchmark / 07_mouse_input / 12_outline_font / 15_audio_tone / 18_cursor / 19_color_emoji
│   ├── 08〜11,13,14,16,17_gui_*  # GUI（primitives/interaction/layout/widgets/slider/color_picker/scroll/toggles）
│   ├── 31_sprite_ex   # drawSpriteEx デモ（kit.gfx。TASK-111.2）
│   └── image/         # 共有アセット（実行 example ではない）
├── libs/              # L2–L3 移植可能な再利用ライブラリ（原則 platform 非依存・headless で単体テスト可）
│   ├── png/           # PNG codec（decode/encode）
│   ├── pixelops/      # ピクセルブレンド共有プリミティブ（premul/straight blend + div255 + clip-hoist）
│   ├── gfx/           # スプライト描画 + Phase2 ヘルパー（sprite/fixed_timestep/fps_counter/keyboard。TASK-111.2。kit 収録）
│   ├── serde/         # versioned container 直列化基盤（RIFF/IFF 系統 + version/CRC。TASK-62.2。std のみ・kit 非収録）
│   ├── recipe/        # CommandRecord 列の save/replay（TASK-62.5.8。std + serde。kit 収録）
│   ├── gui/           # 即時モード GUI（入力 / ID stack / Flex レイアウト / 描画 / ウィジェット）
│   ├── font/          # フォント（TrueType/OpenType アウトライン sfnt/glyf/cff + bmfont。※ BDF は src/text.zig）
│   ├── synth/         # シンセ（Voice / VoicePool / Patch / ロックフリー受け渡し）
│   ├── modular/       # モジュラー・グラフエンジン（TASK-40。kit 非収録=流動中）
│   ├── paint/         # エディタ族の共有コア（旧 apps/editor/core。ADR-007 R6 で格上げ。kit 非収録）
│   │                  #   Canvas(多レイヤ) / Document(frames×layers) / Tool(Pen/Eraser/Brush) / UndoStack / StrokeRecorder / Path / Selection / PNG I/O / document_io(.pix)
│   └── viz/           # 可視化（旧 apps/synth/spectrogram・scope。synth/modular/patch が共有。kit 非収録）
├── apps/              # L4 終端の消費者（kit-only。R5。流動 lib=modular/paint/viz のみ直 import 可）
│   ├── editor/apps/pixie/ # ドット絵エディタ（Pen/Eraser/レイヤー/範囲選択/ベジェ/DB16 パレット/Undo/PNG）
│   ├── synth/         # PC キーボード演奏シンセ MVP（run-synth）
│   └── patch/         # lofi 生成 + パッチキャンバス統合（run-patch）
└── docs/              # ドキュメント
    ├── PLAN.md        # 実装計画（原初の Phase 分け）
    ├── PLAN_*.md      # 個別計画（example_02/03 / libs_gui / png_decoder 等）
    └── adr/           # アーキテクチャ決定記録（層構成は 007）
```
（タスク別の詳細計画は backlog のタスク plan 欄（歴史的な詳細版は `backlog/docs/plans/`）に、
タスク横断の設計文書はトップ階層 `video-proto/docs/plans/` に置く。いずれもこの配下ではない）

> **層構成（ADR-007）**: `apps → kit → libs → core → platform` の一方向依存を build.zig の
> モジュールグラフ（`Layer` タグ + `link()` 検査）で強制する。逆流・層飛ばし・apps の非許可直 import は
> **build 構成時に panic で停止**する。例外は次の 4 つのみ（`linkCoreException` / `linkAppException` で明示）:
> `harness(core/control) → png(libs/png)`（snapshot fb の PNG encode / crc32）、
> `harness → dsp`（digest audio のスペクトル解析。TASK-92）、
> `platform → pixelops`（wasm present の BGRA→RGBA SIMD swizzle。TASK-73.1）、
> `pixie(apps) → pixelops`（縮小 blit の SIMD ブレンド共有。TASK-153.2）。
> 移行は R8 の遅延方針で、未移設ファイルは `src/` に残す。

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
- ✅ **サンプル**: `examples/01`〜`18`（基礎描画 / 入力 / スプライト / 固定ステップ / テキスト /
  ベンチ / マウス / GUI 各種 / アウトラインフォント / オーディオ / カーソル形状）。`examples/image/` は共有アセット（run step なし）。
- ✅ **ヘルパー**: sprite / fixed_timestep / fps_counter / keyboard（`libs/gfx`。TASK-111.2）/ text（`src/`）。
- ✅ **ライブラリ**: `libs/png`（PNG codec）・`libs/gui`（即時モード GUI）・`libs/font`・`libs/synth`・
  `libs/pixelops`（ブレンド共有プリミティブ）・`libs/gfx`（スプライト拡張）・`libs/modular`（グラフエンジン）・`libs/paint`（エディタ共有コア）・
  `libs/viz`（可視化: spectrogram / scope）。
- ✅ **アプリ**: `apps/editor/apps/pixie`（ドット絵エディタ: レイヤー / 範囲選択 / ベジェ / Undo / PNG）・
  `apps/synth`（PC キーボード演奏）・`apps/patch`（lofi 生成 + パッチキャンバス統合）。
- ✅ **オーディオ / シンセ層**: `core/audio` + `src/dsp` + `libs/synth`（下記「オーディオ / シンセ層」節）。
- ✅ **ヘッドレス検証 harness**: `core/control/harness.zig`（下記「ヘッドレス検証 harness」節）。

> 原初の Phase 分け（プリミティブ / ヘルパー関数群 / テンプレート）は `docs/PLAN.md` に記録。
> DoubleBuffer や SimpleApp / GameLoop / SnapshotRenderer 等のテンプレート群は未着手。

## プラットフォーム層の種類

| 実装            | ファイル                                          | レンダリング  | 状態                  |
| --------------- | ------------------------------------------------- | ------------- | --------------------- |
| **Objective-C** | `platform/macos/platform_macos.m`                 | CALayer       | ✅ 完全動作           |
| **Swift**       | `platform/macos-swift/platform_macos_swift.swift`（共通部は `platform/macos-shared/platform_macos_shared.swift`。TASK-140） | CADisplayLink | ✅ 完全動作           |
| **Metal**       | `platform/macos-metal/platform_macos_metal.swift` | Metal GPU     | ✅ 1級 frame pacing 対応（TASK-36） |
| **X11 (Linux)** | `core/platform_linux_x11.zig`（純 Zig / Xlib 直接）  | XShm/XPutImage | ✅ window+blit+入力（TASK-28.2/28.3） |
| **Wayland (Linux)** | `core/platform_linux_wayland.zig`（純 Zig / wl_shm 直接）  | wl_shm (xdg-shell) | ✅ window+blit+入力（TASK-28.5。Linux 実機検証済み） |
| **GDI (Windows)** | `core/platform_windows_gdi.zig`（純 Zig / Win32 直接） | GDI `StretchDIBits`（software blit） | ✅ best-effort backend（TASK-31/35） |
| **D3D11 (Windows)** | `core/platform_windows_d3d11.zig`（純 Zig / COM 手書き vtbl） | D3D11-DXGI swap chain（upload path） | ✅ 1級 frame pacing 対応（TASK-35） |

**Metal版（TASK-36）**: ADR-005 の 1級 frame pacing 契約に適合。triple slot + inflight semaphore で
drawable/buffer の inflight ownership を管理し、`draw(in:)` 内に drawable 取得を集約して CAMetalLayerDrawable
lifecycle 警告を解消。`displaySyncEnabled` 明示で fifo（display refresh 同期）。詳細は `docs/adr/005`。

### backend の選び方（OS 依存）

`core/platform.zig`（facade）が `builtin.os.tag` で backend を切り替え、`build_options.platform_backend`
で具体実装を選ぶ。Linux では `core/platform_linux.zig`（dispatcher）が `platform_backend` で x11/wayland
実装を選ぶ（`platform_linux_x11.zig` / `platform_linux_wayland.zig`、共通の `getTime`/dialog は
`platform_linux_common.zig`）。Windows も同型で `core/platform_windows.zig`（dispatcher）が gdi/d3d11 を
選ぶ（`platform_windows_gdi.zig` / `platform_windows_d3d11.zig`、共通の window/入力/dialog/getTime/CPU backing は
`platform_windows_common.zig`）。`-Dplatform` の有効値は OS で変わる:

- **macOS**: `objc`（既定）/ `swift` / `metal`
- **Linux**: `x11`（既定）/ `wayland`。wayland は TASK-28.5 で display/入力/pixie まで実装し Linux 実機で
  検証済み（busy loop の present flood は frame callback(vsync)律速で対処）。
- **Windows**: `gdi`（既定、best-effort）/ `d3d11`（1級 frame pacing）。純 Zig で Win32 API を extern fn /
  COM 手書き vtbl で直接呼ぶ（TASK-31/35）。

不整合（例: Linux で `-Dplatform=objc`）は明確な build エラーになる。共有型（`KeyCode`/`Event` 等）は
`core/platform_types.zig` が単一ソース。

### Linux（x86_64）のビルド・検証

`flake.nix` は `aarch64-darwin` と `x86_64-linux` の 2 system を提供する。Linux 側 devShell は
zig 0.16 + zls + X11 dev lib（`libX11`/`libXext`）+ Xvfb（`xorgserver`）+ `xwd` + `ffmpeg` + `zenity` + `xdotool`（入力合成）を含む。

> **ソース転送**: Linux/Windows の実機へソースを送って現地でネイティブビルドする転送スクリプトは、
> 実機ホスト名を含むため上位メタリポ側（`tools/`）に置く。手順はメタリポの `AGENTS.md` を参照。

入力（key/mouse/scroll/modifier）は `core/platform_linux_x11.zig` が XEvent を変換する（TASK-28.3。dispatcher 化で 28.5.1 にファイル移動）。物理キーは evdev
X keycode 表で `KeyCode` へ（layout 非依存・KeySym 不使用）。純粋な変換ロジックは `core/platform_linux_input.zig`
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

Wayland backend（`core/platform_linux_wayland.zig`、wl_shm + xdg-shell + wl_keyboard/pointer + xkbcommon）は
**実コンパイル/表示/入力に Linux + Wayland ライブラリと実セッションが必要**で、macOS では検証できない（Linux 実機で確認）。
純粋な入力変換は `core/platform_wayland_input.zig`（`@cImport` しない純 Zig）に分離し、`zig build test-platform-wayland-input` で
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

> compositor の headless 起動法・出力名・screenshooter 権限は **Linux 実機依存**で、最終調整は Linux 実機で行う
> （macOS では Wayland を実行できない。スクリプトは `bash -n` の構文確認のみ可能）。

**入力合成の現実解と自動化範囲（TASK-28.5.5）**: X11 の `xdotool` のような統一手段は Wayland に無い。

- **keyboard**: `wtype`（Wayland virtual-keyboard protocol）。compositor の対応に依存（headless sway/weston で
  効くかは Linux 実機で確認）。compositor の socket が専用 `XDG_RUNTIME_DIR` 配下にある場合はそれも渡す:
  `XDG_RUNTIME_DIR=<dir> WAYLAND_DISPLAY=wayland-N wtype a`（実 session なら既存の環境変数のまま `wtype a`）。
- **mouse / scroll**: compositor 固有手段か `ydotool`。`ydotool` は `/dev/uinput` の権限（root / `input` グループ /
  systemd サービス）が要り CI 的自動化のリスクが大きいため、**devShell には含めず手動確認レンジ**とする。
- **自動化できる範囲**: headless compositor 起動 + main の screenshot smoke +（compositor が対応すれば）`wtype` の
  keyboard smoke。
- **手動確認レンジ**: mouse move/click/scroll、pixie の canvas 描画・GUI hover/press/drag・undo、zenity dialog の
  実 Wayland session 表示。これらは通常のユーザー Wayland session（GNOME/KDE/Sway 等）で目視確認する。

**zenity ファイルダイアログ（pixie の PNG open/save、TASK-28.5.4）の Wayland 表示条件**:
`saveFileDialog`/`openFileDialog` は X11/Wayland 共通で `core/platform_linux_common.zig` の zenity サブプロセスを使う
（backend 非依存）。zenity は GTK アプリのため、表示は session 環境に依存する:

- 通常の Wayland desktop session（GNOME/KDE/Sway 等）では `WAYLAND_DISPLAY` 下で GTK/zenity が動き、file chooser が出る。
- file chooser は環境により `xdg-desktop-portal`（+ backend service）の有無に影響される。
- SSH / headless compositor / 最小 weston では portal や desktop integration が無く、**window 本体は出ても dialog が出ない**、
  または GTK 初期化失敗（`error.DialogFailed`）になりうる。dialog 確認は通常のユーザー Wayland session 上で行う。
- dialog が出ないときは AC 失敗と即断せず、`zenity` の有無 / `WAYLAND_DISPLAY` / `DISPLAY`(XWayland) /
  `XDG_CURRENT_DESKTOP` / `xdg-desktop-portal` の起動状態を切り分ける。

## 主要なプラットフォームAPI

caller は `@import("platform")` で Zig 高レベル API (`core/platform.zig`) にアクセスする。
C ABI (`platform/platform.h`) は内部実装で、バックエンド (`core/platform_macos.zig`) のみが直接利用する。

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

## エディタ（apps/editor + libs/paint + libs/gui）

`apps/editor/` はグラフィックエディタ群（TASK-21 ファミリー）。共通基盤（`libs/paint` + `libs/gui`）の
上に複数の小アプリ（現状は pixie。将来 paintly / tilex / animix）を載せる構成。

- **libs/gui**（`@import("gui")` / kit 収録）: 即時モード GUI。入力管理（hot/active + ID stack）/
  Flex レイアウト / 描画プリミティブ / ウィジェット（Button / Label / ColorSwatch / Slider）。
- **libs/paint**（`@import("paint")` / ADR-007 R6 で旧 `apps/editor/core` から格上げ）: アプリ非依存の
  再利用コア（platform / GUI を import しない headless lib）。`Canvas`（レイヤ・合成・座標変換）/
  `Tool`(vtable, Pen/Eraser) / `UndoStack` / `StrokeRecorder` / PNG I/O。root は `libs/paint/src/paint.zig`。
  「エディタ族の共有 lib」なので汎用 kit には載せず、pixie 等の該当 app だけが直 import する。
  使い方は **`libs/paint/README.md`** を参照。
  - 不変条件: 表示は `composite()`（白背景合成）。**PNG 保存は `savePNG` に渡す pixels を用途で使い分け**（白背景 `composite()` は保存に使わない）: paint の round-trip は raw layer pixels（`layerPixels(idx)`、透明保持）、pixie の通常保存（TASK-43 以降）は全 visible layer を合成した `compositeStraight()`（フラット透明 PNG。単層 opacity=255 で raw と恒等）。pixie の PNG open はフラット画像を layer0 へ読み込み layer 構造は保持しない。**レイヤー保持は `.pix` プロジェクト形式**（`Document` + `document_io`。TASK-63。serde container 上に width/height/frame/layer を直列化し round-trip で bit 復元。layer payload は raw layerPixels、連番書き出し `exportPngSequence` は compositeStraight。undo は非永続=load でリセット。MVP は 1 frame/raster・256×256 固定で pixie の Prj Save/Prj Open から）。
- **apps/editor/apps/pixie**: ドット絵エディタ MVP。`canvas_input.zig`（入力状態機械）が
  press 起点 capture → Tool 経由で stroke を駆動する。platform / gui / png は `@import("kit")` 経由
  （`kit.platform` / `kit.gui` / `kit.png`）、paint のみ直 import（kit-only 消費者の R5 + 流動 lib 例外）。

> 注: エディタのタスク管理はトップ階層（`video-proto/`）の Backlog.md CLI で行う（上位 AGENTS.md 参照）。
> Zig 0.16 のイディオムは `zig-best-practices` スキルを参照。

## オーディオ / シンセ層（TASK-27 ファミリー）

グラフィックスと対称な 4 層構成でオーディオ（音）シンセサイザー基盤を構成する。設計の正は
トップ階層の `docs/plans/synth-foundation-plan.md`。

| 層 | 場所 | 内容 |
|---|---|---|
| **L1 platform** | `core/audio.zig`（facade）+ `core/audio_{macos,linux,windows}.zig`（OS 別実装） | オーディオ出力プリミティブ（`open/start/stop/close/config`）。各 OS ネイティブ API を **extern fn / COM 手書き** で叩く（`@cImport` しない）: macOS=AudioUnit(AudioToolbox) / Linux=ALSA(`alsa`=libasound) / Windows=WASAPI(ole32)。audio backend は audio を使う exe にのみ link（既存 exe は不変）。 |
| **L2 helpers** | `src/dsp/`（`@import("dsp")`） | Oscillator / Envelope(ADSR) / Filter(TPT SVF) / Mixer + denormal 対策。純 Zig。 |
| **L3 libs** | `libs/synth/`（`@import("synth")`） | Voice / 固定 VoicePool（スチール + done 回収）/ Patch / Synth。GUI⇔Audio のロックフリー受け渡し（SPSC `NoteQueue` / `AtomicF32` / `Mailbox`(triple-buffer) / 出力タップ `SampleTap`）。dsp に依存。 |
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
4. backend 実装（`core/audio_linux.zig` の hw_params 折衝）は**変更不要**。当初 pipewire 1.6.5 で
   `snd_pcm_hw_params` が失敗するのを hw_params の問題と疑ったが、実機調査で真因は sink 不在（ENOENT）と判明。
   sink さえあれば現行 `period`/`buffer` の組合せがそのまま通る。

> 検証機が NixOS の場合、version 表示は 26.11 でも実体は **nixos-unstable** のことがある（`nixos-26.11`
> ブランチは未存在）。Apple T2 機では `apple-t2x4.conf` プロファイルで Speakers/Headphones sink を生成する。

## モジュラーシンセ層（TASK-40 ファミリー）

`libs/modular`（`@import("modular")`）は **モジュラー音響グラフエンジン**。dsp プリミティブを vtable モジュール
として包み、ノードグラフを per-sample で評価する。lofi ミニマルテクノを生成し続ける環境へ発展させる土台
（最終ゴールはビジュアル・パッチング。設計の正はトップ階層 `docs/plans/modular-synth-plan.md`）。

- **graph.zig**: `Graph`（固定確保 / topo sort / 入力単一接続=合算は Mixer / サイクル辺は 1 サンプル遅延 /
  per-sample 処理 / 内部 mono→Output で stereo）。`processBlock(buf,frames,channels)` は **RT 安全**
  （process 経路に alloc/lock/IO/panic なし。未 finalize/channels==0 はゼロ埋め）。係数更新（filter の tan、
  ドラムの @exp）は `updateParams`（ブロック先頭・dirty-gated）に分離し毎サンプル走らせない。
- **signal.zig**: 信号規約（audio≈-1..1 / cv 0..1 / gate threshold 0.5 / trigger=rising edge /
  pitch_cv は VCO・Quantizer 境界で Hz 変換）。
- **modules.zig**: VCO/VCA/EnvGen/VCF/Mixer/Output（Ph1）＋ Clock/ClockDivider/EuclideanSeq/Quantizer/
  Kick/Hat/PercEnv（Ph2a）＋ Random/TuringMachine/Clap/Saturator/Bitcrusher/DelayFx/ReverbFx/VinylNoiseFx/
  WowFlutterFx（Ph2b）＋ ChordPad（Ph4。Ph5 で pitch_cv/cutoff/level の任意 CV 入力を追加。未接続は固定 root で後方互換）＋
  **StepSeq / Lfo**（Ph5。合成ドラム・lofi FX はサンプル不使用）。`Scale`/`scaleDegreeCount`/`degreeIndexToPitchCv` を
  module-level に共有し Quantizer/StepSeq/アンビエント生成が同じ scale 写像を使う。依存は dsp と `libs/synth` の
  lock-free 小物のみ（Voice/SynthEngine/NoteQueue には依存しない）。
  - **StepSeq**（Ph5 DrumMachine/BassMachine）: clock gate で 16 step を進める editable シーケンサ。
    kind=.drum は gate 1 出力、kind=.bass は gate/pitch_cv/accent_cv の 3 出力（slide は内部 pitch glide。未配線出力は作らない）。
- **lofi FX dsp**（`src/dsp`）: Bitcrush（bit/SR 低減）/ VinylNoise（crackle+hiss）/ WowFlutter（可変 delay の
  ピッチ揺れ）。既存 DelayLine/Reverb/softClip も FX wrapper module から利用。
- **apps/patch**（`run-patch`）: `lofi.zig` の `LofiPatch`（自己生成パッチを 1 回構築し RT で
  `graph.processBlock`）＋ `main.zig`（window+audio+harness probe + DrumMachine/BassMachine GUI）。`LofiPatch` は
  graph が各モジュールへの ctx ポインタを保持する自己参照のため**ヒープ確保しムーブしない**（`create`/`destroy`）。
  - **生成は 2 系統**（Ph5 方針 C）: ①前景 = editable StepSeq の grid/303 を **per-bar 離散変異**（evolve(全体トグル)/
    track 単位 lock/density バンド/anchor 復帰の §4.7 境界内。GUI クリックで編集でき、evolve ON 時に lock 外 track だけが
    小節ごと最大 1 パラメータ変異。evolve off で完全な手動シーケンサ）。
    ②背景 = アンビエント連続生成（TuringMachine→Quantizer が ChordPad の和音 root を scale 内で遷移、Lfo が cutoff を
    連続変調、Random が level を S&H）。無操作でも鳴り続け・流れ続ける。全 RNG fixed seed で決定的。
  - **pattern 所有モデル**: RT(StepSeq) が grid/303 pattern の authoritative。GUI は毎フレーム snapshot を読んで
    grid 表示し、編集時のみ `Controls.pattern_db`(Mailbox) へ publish（RT が revision 変化時のみ取り込み、
    その後また per-bar 変異）。RT 経路に alloc/lock/IO/panic を足さない。
  - **Song/Chain/Phrase 3層**（TASK-91 / M8 式）: Phrase=1 bar×1 track の番号参照 pool、Chain=Phrase index 列、
    Song=トラック毎 Chain 列。`SongData` を `Controls.song_db`(Mailbox) で publish。Song position は RT
    authoritative。bar 境界の適用順は **seed → song → pending_bar_cmd → mutate**（93 の bar-latch と共存。
    切替 bar は mutate スキップ = evolve 変異は切替時リセット）。action:
    `phrase_capture` / `chain_set` / `song_row` / `song_len` / `song_loop` / `song_play` / `song_goto`
    （recorded）+ `save_project` / `load_project`（MPRJ serde・local_only 非記録。pattern_io の MDLP は不変）。
  - **mini-notation action**（TASK-93）: `action pattern <track> <notation>`（track ∈ kick|hat|clap|bass）で
    Tidal 風サブセット記法を 16-step mask へ評価し、該当 track を**宣言的全置換**する。文法: 空白区切り /
    `x`=hit / `~`=休符 / `0..9`=bass 度数（hit+deg）/ `[a b]`=スロット内サブ分割（ネスト深さ 2）/
    `<a b>`=**評価ごと**交代（action 再実行で交代。bar ごと連続交代は将来スコープ）/ `a*2`=スロット内反復 /
    `a?`=50% 確率（`splitmix64(notation_seed ^ counter)` 下位 bit。`action seed` と整合）/
    `x(k,n)`=スパン内ユークリッド。位置は bar を有理数分割し `round(pos*16)` で量子化（衝突 OR）。
    適用は **小節境界クオンタイズ**（`PatternCommand.quantize_bar=true` → RT の `pending_bar_cmd` 経由。
    GUI/他 action は即反映のまま）。レシピには記法の生テキストを記録（replay 時 counter 順で再評価→決定的）。
    **recipe replay は `notation_counter` を 0 から再評価**する（`action recipe_replay` 冒頭でリセット）。
    現在パターンの読み出しは既存 `digest modular` の pattern masks hex で充足（読み書き対称。新 probe なし）。
  - harness `modular` probe が生成状態を公開（digest=bpm/density/steps/active/gains/muted/ph4/ambient/pattern masks
    hex/lock/evolve/rev/mut/seed/song={playing,row,bar,rows} を 1024B 以内、snapshot=さらに bass_deg + song_detail）。
  - **`action render <path> <seconds>`**（TASK-86）: offline の別 `LofiPatch` インスタンスで master 出力を
    PCM16 stereo WAV にストリーミング書き出し（1..=600 秒。ヘッダ先書き + chunk=4800）。live の seed +
    公開済み編集状態（params / snapshot pattern）を複製し、同一条件 2 回で bit 一致。RT 再生経路には
    手を入れない（main thread ブロックは MVP 割り切り）。`network_policy=.local_only`・CommandLog 非記録
    （`recipe_save` と同型）。応答: `ok path=... seconds=... sr=...`。
- **apps/patch**（`run-patch`）: 動的グラフエンジン（`DynGraph`, TASK-40.6.1）をビジュアルに編集する
  パッチキャンバス（40.6.2〜）。ノード=矩形＋種別色ポート（audio 橙/cv 青/gate 緑）＋ケーブルで描画し、
  pan/zoom/drag/ライブ再配線・パレット追加・DrumMachine/BassMachine マクロ（畳み/展開・TR/303 grid）ができる。
  UI レイアウト状態は GUI 側が持ち publish には載せない（`group.Ledger`）。純幾何は `canvas.zig`（test-patch）。
  - **信号可視化**（TASK-40.8）: 画面下端に可視化帯（C: master 出力を `SampleTap` で tap→spectrogram/
    oscilloscope/level meter。apps/synth 流用）。各出力ポート丸を活性度で明滅（A: `dyn.sigLevel` の
    best-effort torn read・RT 影響ゼロ）。表示中の出力ポート直下に per-port ミニ oscilloscope（D: RT 側
    per-port リング tap。`graph_core.processBlockTapped` + `DynGraph.tap`。`.unordered` store/load・block 末尾
    wpos release・`applied_seq` gate で旧 port 混入を防ぐ。tap 無し経路は comptime 分岐で機械語不変）。
    ミニは **ポート種別ごとに表示を変える**: audio=細かい間引きの波形＋rising zero-crossing 位相ロック /
    cv=粗い間引きでゆっくりした変調 / gate=粗い間引き＋窓内 max（peak）で 1 サンプル幅パルスを取りこぼさず
    縦インパルスバーで時系列表示（per-slot `decim`/`peak` を `TapConfig` で GUI が種別に応じ設定）。
    キャンバス有効高 = `fb_h - VIS_H`（見切れ判定/ヒットテスト/tap 対象選択に共通適用）。harness `viz` probe が
    master rms/peak + tap 中 port/レベル/wpos を公開（`patch`/`group` probe と併用）。

```bash
zig build run-patch            # 統合 lofi 生成 + パッチキャンバス（ESC で終了）
zig build test-modular         # libs/modular（topo/cycle/単一接続/生成CV/合成ドラム/per-port tap。display/audio 不要）
zig build test-app-modular     # apps/patch/lofi.zig の LofiPatch（offline 非無音/有限/決定的 CRC）
zig build test-patch           # apps/patch 純幾何（camera/hit-test/見切れ/tap 選択/ミニスコープ幾何）+ group 台帳
```

ヘッドレス AC 確認（macOS 実機で発音、live で audio digest）:

```bash
VP_HARNESS_LISTEN= VP_HARNESS_PORT_FILE=/tmp/vp.port zig build run-patch &     # 背景起動
scripts/drive --port-file /tmp/vp.port 'digest audio'                        # → silent=0 / rms>0 を確認
scripts/drive --port-file /tmp/vp.port 'quit'
```

> 決定性は `test-app-modular` の「2 回 render の CRC 一致」で担保（合成パラメータ変更で壊れる golden 定数は
> 置かない）。Linux 発音は環境依存（[ALSA→PipeWire 前提条件](#linux-で音を鳴らす前提条件alsapipewiretask-2871)）で
> `run-patch` は manual、`test-modular`/`test-app-modular` は OS 非依存で必須。

## ヘッドレス検証 harness（TASK-32 ファミリー）

AI がアプリの出力を手軽に確認するための仕組み。`core/platform.zig`(facade) の 4 フック（`pollEvents`/`nextEvent`/`present`/`getTime`）に `core/control/harness.zig` を interpose し、**アプリ無改造**で「入力注入 + フレーム捕捉 + 仮想クロック」を行う。env 未設定なら全フック即パススルー（既存挙動と完全一致）。設計の正はトップ階層の `backlog/decisions/decision-1` と TASK-32 系タスク。

- **P1（TASK-32.1, 実装済み）**: file replay + 組み込み `fb` probe（framebuffer→PNG / 1行 digest）+ 仮想クロック。
- **P2（TASK-32.2, 実装済み）**: live 制御（TCP loopback + driver CLI `scripts/drive`）/ 組み込み `audio`・`stats` probe / record→replay。
- **P3（TASK-32.3, 実装済み）**: custom probe レジストリ。app が `platform.registerProbe(...)` で probe を opt-in 登録（pixie=`canvas`/`undo`/`tool`, synth=`voices`/`patch`）。詳細は下記「custom probe の足し方」。
- **P4（TASK-32.4 → TASK-165, 実装済み）**: 完全 display-less。`VP_HEADLESS=1` で
  `platform.init()` が native `backend.init()` 自体を呼ばず、runtime で `platform_null`（CPU framebuffer
  所有の null window）を選ぶ。SCRIPT/LISTEN は任意（単独の display-less 起動可）。harness は観測 copy
  （`onLock`/`onPresent`）のみ。あわせて `audio_null.zig`（実デバイス無しの null 出力デバイス。実時間 pull スレッド）で
  `audio` probe も実デバイス無しで駆動でき、`platform.frameDelay()`（manual clock 時 no-op）で main loop の
  sleep による replay 速度律速も解消した。詳細は下記「完全 display-less（P4）」節。
  - 注: `fb` probe は**手動描画 API の CPU フレームバッファ**を捕捉する backend 非依存実装なので、**objc / swift / metal いずれでも `snapshot fb` は撮れる**（Metal も同じ CPU バッファを供給し、実測で objc と fb crc が bit 一致）。
- **P4 スコープ外**: Metal の GPU drawable 読み戻し（描画後の合成サーフェスの readback）。理由は上記の CPU
  framebuffer 経由で既に `snapshot fb`/`digest fb` が metal ビルドでも成立しており（objc と crc bit 一致・
  実測済み）、readback は harness の目的（アプリが描いた内容の検証）に寄与しないため見送った。
- **action registry（TASK-62.1, 実装済み）**: probe（read）に対称な write/operate 口。app が
  `platform.registerAction(...)` で opt-in 登録し `action <name> [args...]` で叩ける。詳細は下記
  「custom action の足し方」。
- **capabilities（内省 probe。TASK-62.4, 実装済み）**: 組み込み probe `capabilities` が、登録済み
  probe・action を JSON 1行で列挙する（`digest capabilities`/`snapshot capabilities`）。将来の
  TASK-62.3（network discover）の入口。詳細は下記コマンド言語節の「capabilities（内省 probe）」。

### コマンド言語（file replay と live で共通）

1コマンド/行（区切りは改行 **または `;`**。`#` はコメント）。**file・live で同一文法**:

```text
inject key_down A          # key_down/key_up <KEY> [修飾子...]（KeyCode 名。大小無視。例 A / SPACE / ESCAPE / LEFT / 0）
inject key_down S cmd shift # 末尾に shift/ctrl/alt/cmd を 0 個以上（順不同・大小無視）。例: Cmd+Shift+S
inject mouse_move 100 120  # mouse_move <x> <y> [修飾子...]
inject mouse_down left alt # mouse_down/up <left|right|middle> [修飾子...]
inject scroll 0 -3 ctrl    # scroll <dx> <dy> [修飾子...]
step 5                     # manual/replay: 5 フレーム駆動 / free-run: 5 present の frame barrier
await fb crc=8702DD71 60   # await <probe> <key><op><value> [timeout]（timeout=frame budget。0=1回照合）
await audio silent=0       # free-run は接続保持して自走待ち、manual はフレーム駆動して待つ
snapshot fb  /tmp/out.png  # 直近 present フレームを PNG 保存（省略時 $VP_HARNESS_OUT/frame_<n>.png）
snapshot audio /tmp/a.wav  # 直近の audio tap を PCM16 WAV 保存（省略時 audio_<n>.wav）
snapshot stats /tmp/s.json # stats を JSON 保存（省略時 stats_<n>.json）
digest fb                  # fb <w>x<h> crc=<hex> top=[#RRGGBB:NN%,...]
digest audio               # audio rms=<f> peak=<f> f0=<Hz> silent=<0|1> frames=<n> band_low/mid/high=<0..1> centroid=<Hz> onsets=<n> lufs=<f>（mono downmix・自己相関 f0 + TASK-92: 帯域/セントロイド/オンセット/momentary LUFS。既存 audio への additive。audio2 等の新 probe は作らない）
digest stats               # {"frame":..,"virtual_fps":60.0,"mouse_move_merge_count":..,...}（JSON 1行）
digest capabilities        # {"probes":[{"name":..,"ext":..,"snapshot":bool,"digest":bool,"desc":..(,"args":[...])},...],"actions":[{"name":..,"desc":..(,"args":[...])},...]}（登録済み probe・action の内省列挙。TASK-62.4 + args シグネチャ TASK-88.1）
snapshot capabilities /tmp/c.json # capabilities を JSON 保存（省略時 capabilities_<n>.json）
action <name> [args...]    # app が registerAction した高レベル操作を実行（probe(read)対称のwrite口。TASK-62.1）
expect fb crc=8702DD71     # expect <probe> <key><op><value>（op ∈ = != > <）。digest payload の top-level k=v と照合
expect audio silent=0      # 一致で ok / 不一致で fail。replay は失敗を溜め終了時に非0 exit、live は ok/fail 行を返す
assert fb crc=8702DD71     # expect と同評価。replay では失敗した時点で即 非0 exit（fail-fast abort）
expect fb contains crc=87  # contains <substr>: digest 1行への部分文字列一致（ネスト/JSON はこちらで照合）
quit                       # 終了（EOF でも終了）
```

- **組み込み probe（framework 所有）**: `fb`(framebuffer→PNG/digest) / `audio`(libs/synth 等の出力を facade `core/audio.zig` が tap→WAV/digest) / `stats`(EventStats + 仮想 fps→JSON) / `capabilities`(登録済み probe・action の内省列挙。下記)。
  `audio` は **直近窓（latest-wins）** を測るので「今鳴っている音」を assert できる（無音は silent=1, f0=0）。
  **TASK-92 拡張（additive・既存キー bit 安定）**: `band_low`/`band_mid`/`band_high`（正規化エネルギー比・合計≈1）/
  `centroid`[Hz] / `onsets`（スペクトラルフラックスピーク数）/ `lufs`（BS.1770 K-weighting momentary 400ms。無音床値 -99.0）。
  AC 判断: 新 probe 名（audio2 等）は作らず既存 `audio` にキーを足す。解析は digest 要求時のみ（RT 経路不変）。
  `virtual_fps` は仮想クロック由来の固定値（≒60。実性能ではない）。
- **capabilities（内省 probe / TASK-62.4 + args シグネチャ TASK-88.1）**: `digest capabilities` / `snapshot capabilities [path]`（ext=json）で、登録済み probe・action を JSON 1行で列挙する。組み込み7件（`fb`/`audio`/`stats`/`capabilities` 自身/`capture`/`gamepad`/`midi`。固定 desc）→ custom probe（登録順）→ action（登録順）の順。各 probe エントリは `name`/`ext`/`snapshot`(bool)/`digest`(bool)/`desc`、action エントリは `name`/`desc`。**フィールド追加のみ**で `args`（省略可）を載せられる（下記）。**中身非解釈の不変条件を維持**（登録簿のメタ情報を転記するだけ。callback は呼ばない。kind の語彙も検証しない）。イベント/接続時のみ走る（フレーム毎・毎サンプルではない）。ホットパスではない。
  - **args シグネチャ（TASK-88.1）**: `registerAction`/`registerProbe` に `args: ?[]const ArgSpec = null` を渡せる（省略可・後方互換）。`ArgSpec = {name, kind, min?, max?, values, pattern, optional, variadic, desc}`。**null=未指定（JSON に `args` フィールド無し・従来と bit 一致）/ 空 slice=`"args":[]`（引数なしを明示。MCP の fallback 判定用に null と区別）**。`args != null` のときだけ `"args":[{"name":..,"kind":..(,"min":..)(,"max":..)(,"values":[..])(,"pattern":..)(,"optional":true)(,"variadic":true)(,"desc":..)},...]` を追記（**非デフォルト値のみ emit**）。kind は文字列（推奨: `int`/`float`/`string`/`bool`/`enum`/`path`。app 独自 kind 可。解釈は消費側=MCP）。
  - **常に valid JSON を返す契約**: registry 上限（custom probe 16 + action 48 + 組み込み7）と desc/args の登録時サニタイズ（下記）により通常は発生しないが、フェイルセーフとして「収まらない・name/ext に JSON を破損させる文字を含む」エントリはそこで列挙を打ち切り、末尾に `"truncated":true` を付与する（値が false の通常時はフィールド自体を省略）。将来 TASK-62.3（network discover）の互換のため、フィールドは追加のみで変更する。
  - 将来クライアント（TASK-62.3 network discover / TASK-88 MCP 等）が「今このアプリで何を観測・操作できるか」を discover する入口になる。
- **custom probe（app 所有・opt-in / TASK-32.3）**: app が `platform.registerProbe(...)` で登録した名前。`snapshot <name>` / `digest <name>` を組み込みと同じ文法・出力で扱える。現状: pixie=`canvas`(composite フラット透明 PNG / `WxH layers=N selected=.. comp=XXXXXXXX lN{v=..,op=..,crc=..,nz=..,name=..}`) / `undo`(`{"depth":N,"redo":M}`) / `tool`(`tool=Pen color=#RRGGBB`) / `cursor` / `history` / `diff`(`changed=N bbox=x0,y0,x1,y1 from=#RRGGBB to=#RRGGBB`。基準は `action diff_mark` または初回 digest で自動初期化。changed=0 時は `bbox=none from=none to=none`) / `palette`(`colors=N used=M top=[#RRGGBB:NN%,...]`。パレット色数 + composite 一意色数 + 上位4色。TASK-89)、synth=`voices`(`{"active":N,"capacity":16,"voices":[{"note":..,"stage":".."}]}`) / `patch`(現在 patch JSON)。**framework は custom probe の中身を解釈しない**（raw bytes と1行 digest をルートするだけ）。
- **digest の出力先**: replay=stderr に `[harness] digest <probe> <payload>`、live=接続レスポンスに prefix なしの `<probe> <payload>`。snapshot は file 保存し、live はそのパスを返す。
- **inject の修飾子トークン（TASK-32.5）**: `inject` の必須引数の後に `shift`/`ctrl`/`alt`/`cmd` を 0 個以上付けると、その KeyEvent/MouseEvent の `modifiers` に反映される（順不同・大小無視）。key_down/up・mouse_move/down/up・scroll の全経路で使える。例: `inject key_down S cmd`（Cmd+S）/ `inject key_down Z cmd`（undo）/ `inject mouse_down left alt`。**未知トークンが 1 つでもあれば警告を出し、そのイベントは注入されない（fail-fast。修飾子名の typo を握りつぶさない）**。修飾子無しは従来通り空 modifiers。
- **expect / assert（アサーション層 / TASK-78）**: probe の **digest 1行 payload** に期待値照合を行い、スクリプトが合否を **exit code / レスポンス**に落とせるようにする（AI が目視なしで自律反復するための乗数施策）。
  - 文法: `expect <probe> <key><op><value>` / `assert <probe> <key><op><value>` / `expect <probe> contains <substr>`。`expect digest <probe> ...` のように第2トークン `digest` はエイリアスとして読み飛ばす。演算子は `=` `!=` `>` `<` + `contains` の最小セット。
  - **値の比較規則**: `>` `<` は両辺 f64 parse 必須（不能は失敗）。`=` `!=` は両辺 f64 parse 可能なら数値比較（`rms=0.5` ≒ `0.5000`）、不能なら文字列完全一致（crc hex はこちら）。crc は digest 出力の 8 桁を**そのままコピペ**する運用（全桁数字の crc に短縮値を渡すと数値一致で誤通過し得るため）。
  - **key 抽出は top-level `k=v`（空白区切り）のみ**。ネスト（canvas の `l0{v=..,crc=..,nz=..}`）や JSON（`stats` の `{"frame":..}`）は 1 トークンに glue され key として拾われない → それらは `contains` を使う（substr は空白を含められない 1 トークン）。
  - **合否と exit code**: replay = stderr `[harness] expect ok/FAILED line N: <expr> [actual=<payload|理由>]`。`expect` の失敗は溜めて**終了時（EOF/quit/window close いずれの経路でも）に 1 件以上で非0 exit**、`assert` の失敗は**その場で即 非0 exit**（fail-fast abort。exit(1) は後始末を飛ばす debug 挙動）。live = レスポンス行 `ok`/`fail <probe> <expr> [actual=..]` を返すだけで**プロセスは終了しない**（∴ live では expect と assert は同挙動）。`scripts/drive` は**レスポンス各行**を走査し `fail ` 行頭があれば自身も非0 exit する（`error:` 等の警告は非0化しない）。
  - **fail-fast（typo を握りつぶさない）**: 未知 probe 名 / 不正構文（op 欠落・key/value 空・`!` 単独）/ 余剰トークン / key 不在 / payload 未確定（fb present 前）はすべて**失敗**として扱う。
  - **record→replay 対称・harness 無効時 no-op** は不変（既存機構にそのまま乗る）。
- **action（probe 対称の高レベル操作 / TASK-62.1）**: app が `platform.registerAction(...)` で登録した名前を `action <name> [args...]` で叩ける write/operate 口。UI 座標に依存せずアプリの意味的コマンドを直接実行できる（undo/network の共通コマンド単位の土台）。
  - 文法: `action <name>` の後の残り行が **raw テキストのまま**（trim のみ・再トークン化しない）`args` として callback に渡る。**`;`/改行はコマンド区切りなので args に含められない**（同一コマンド片内のテキストに限られる）。
  - callback は `run(ctx, args, buf) anyerror![]const u8`（`buf` は `digest` と同じ 1024B 契約。戻り値は改行を含めない1行）。**framework は args も戻り値の意味も一切解釈しない**（probe と同じ不変条件。改行以降を emit しないのは中身の解釈ではなく wire framing 保護）。callback は **main thread（`pollGate` 内・step/フレーム境界）で実行**され、RT callback から呼ばれることは無い（RT スレッドと共有する app 状態への同期責務は app 側）。
  - **合否と exit code**: 未知 action・名前欠落・`run()` のエラーは**すべて失敗**として扱い、`expect`/`assert`（TASK-78）と同じ `expect_failures` カウンタに相乗りする（記帳して続行。`assert` のような即時 abort 変種は無い）。replay は終了時（EOF/quit/window close いずれの経路でも）に記帳が 1 件以上あれば非0 exit、live はプロセスを終了せずレスポンス行のみで合否を返す。
  - **wire format**: replay stderr = 成功 `[harness] action <name> ok <msg>` / 失敗 `[harness] action <name> FAILED <msg>`。live resp = 成功 `<name> <msg>`（**bare。`digest` の `<probe> <payload>` と同じ流儀**）/ 失敗 `fail <name> <msg>`（**`fail ` 接頭辞。`scripts/drive` の行頭スキャンに乗せて非0 exit させるため**）。callback が誤って複数行を返しても `msg` は最初の `\r`/`\n` の手前で切って emit する（wire framing 保護。中身の解釈ではない）。
  - **structured error（code + suggested_next_action / TASK-62.5.9）**: action 失敗の自己回復ヒントを app が opt-in で載せる wire 拡張。
    - **API**: `platform.setActionErrorDetail(code, suggested_next_action)`（main thread 専有。`action_registry` の module 変数）。handler が **エラー return の直前**に呼ぶ。`dispatch` 開始時（および copilot の direct-run 前）に毎回クリアされるので、呼ばなければ**従来失敗行と bit 一致**（` code=`/` next=` を一切付けない）。
    - **sanitize**: wire framing 保護のみ（意味は非解釈）。制御文字/`DEL` を `_` に置換、上限 code=64B / next=200B。code は 1 トークン想定のため ASCII whitespace も `_`。next は空白可（`next=` は行末最終フィールドで残り全体）。
    - **wire（失敗行の末尾追記のみ）**: live/copilot = `fail <name> <msg> code=<c> next=<n>` / replay = `[harness] action <name> FAILED <msg> code=<c> next=<n>`。**行頭 `fail ` は不変**（`scripts/drive` の fail 行頭スキャン・非0 exit 運用は無改修で維持）。netsync の REJECT reason・capabilities JSON は本拡張の対象外。
    - **非解釈の不変条件**: code/suggestion の語彙は app 側が返す。framework は透過（desc と同様に framing 保護だけ）。MCP ブリッジ（TASK-88）はこの wire をそのまま tool エラーとして読む前提。
    - **pixie 実例**: `open` の読込失敗（`ReadFailed`/`FileNotFound`）→ `code=file_not_found` / `next=check path or use save first`。`select_layer` の `OutOfRange` → `code=index_out_of_range` / `next=use add_layer or 0..N-1`。
  - **登録**: `registerAction` は harness 無効時 no-op、同名上書き、空白/`;`/改行を含む名前と空名は拒否、registry 満杯（48件。TASK-90 で 32→48。以前 TASK-62.5.3 で 16→32）は skip。組み込み action は無い（framework は action の中身を一切解釈しないので予約名の概念も無い）。app 側の登録は各採用タスクで行う（本タスクは framework 側のみ）。
  - **pixie の登録 action（TASK-64。probe の pixie=`canvas`/`undo`/`tool`/`cursor`/`history`/`diff`/`palette` と対称の write 口）**: `undo` / `redo` / `clear` / `add_layer` / `delete_layer` / `select_layer <idx>` / `set_layer_visible <idx> <0|1>` / `set_layer_opacity <idx> <0-255>` / `move_layer <+1|-1>` / `set_color <RRGGBB>`（per-peer local） / `set_tool <pen|eraser|brush|bezier|select|fill>`（per-peer local） / `stroke [layer=#<id>] [tool=...] [color=...] [size=...] [opacity=...] [hardness=...] <x0> <y0> [x y ...]`（canvas 座標。奇数個は失敗。relay wire は origin context + stable layer id を焼き込む） / `save <path>` / `open <path>` / `recipe_save <path>` / `recipe_replay <path>`（TASK-62.5.8。下記「レシピ」節） / `diff_mark`（TASK-87。現 composite を `digest diff` の基準にコピー。引数なし・メタ操作で CommandLog 非記録） / `replace_color [#<id>|<index>] <from> <to>`（TASK-89。layer ref は optional・省略時 selected。netsync 中は #id 必須・`.relay`。hex 2 個のみは従来互換・undo 可） / `palette_ramp <seed_hex> <n>`（TASK-89。OKLCH 明暗ランプ n=2..32・パレット全置換・`.reject_when_synced`） / `palette_from_png <path>`（TASK-89。PNG 頻度抽出→パレット全置換・上限64・`.reject_when_synced`） / `palette_set <hex...>`（TASK-89。1..64 色でパレット全置換・`.reject_when_synced`）。palette 系は document 状態（.pix v4 PLTE / netsync SYNC 対象）のため session 中のローカル変更は拒否。**.pix 互換**: v4 reader が v2/v3 を読む後方互換のみ（v3 reader は schema>3 を拒否。旧 reader が v4 を読めるわけではない）。全 action は UI/キーボードと同じ `App.do*` メソッドを通るため undo 経路が一致する（`action stroke` で描いた内容を `inject key_down Z cmd` で undo できる、等）。実装は `apps/editor/apps/pixie/main.zig`（dispatch + `registerActions`）+ `actions.zig`（純パーサ。App/kit 非依存で単体テスト可能）。詳細な action⇄UndoCmd対応表は main.zig の該当セクションの doc comment 参照。

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
VP_HARNESS_LISTEN= VP_HARNESS_PORT_FILE=/tmp/vp.port VP_HARNESS_OUT=/tmp \
  VP_HARNESS_RECORD=/tmp/live.txt zig build run-synth &        # 背景起動（ephemeral port を /tmp/vp.port に出力）
# 固定 port は VP_HARNESS_LISTEN=<n>。ポートは stderr にも出る。
# 旧 step-driven 相当は VP_HARNESS_MANUAL_CLOCK=1 を併用。
scripts/drive --port-file /tmp/vp.port 'inject key_down A; step 5; digest fb'   # → fb ... を stdout に返す
scripts/drive --port-file /tmp/vp.port 'digest audio'                          # → audio rms=.. f0=.. ..
scripts/drive --port-file /tmp/vp.port 'snapshot fb /tmp/out.png'              # → /tmp/out.png
scripts/drive --port-file /tmp/vp.port 'quit'                                  # アプリ終了
# record→replay 対称: 上の VP_HARNESS_RECORD のログを replay すれば同じコマンド列を再現できる
VP_HARNESS_SCRIPT=/tmp/live.txt VP_HARNESS_OUT=/tmp zig build run-synth
```

| env | 役割 |
|---|---|
| `VP_HARNESS_SCRIPT=<file>` | **replay** 有効化（file トランスポート。常に manual clock） |
| `VP_HARNESS_LISTEN[=port]` | **listen** 有効化（TCP loopback。値なし／空／`0`=ephemeral、正の値=固定 port。既定は free-run） |
| `VP_HARNESS_MANUAL_CLOCK=1` | LISTEN に従属。socket を旧 step-driven（blocking）相当の manual clock にする |
| `VP_HARNESS_PORT_FILE=<file>` | 選ばれた port の出力先（省略時 `$VP_HARNESS_OUT/harness.port`） |
| `VP_HARNESS_RECORD=<file>` | listen 受信コマンドを追記（→ `VP_HARNESS_SCRIPT` で replay 可能） |
| `VP_HARNESS_OUT=<dir>` | snapshot 省略 path / port file の既定ディレクトリ |
| `VP_HEADLESS=1` | **完全 display-less**（TASK-165）。`platform.init` が null backend を選ぶ。SCRIPT/LISTEN は任意（単独起動可）。詳細は下記「完全 display-less（P4）」節 |

> SCRIPT と LISTEN の同時指定はエラーで無効化（1プロセス1トランスポート）。LISTEN なしの MANUAL_CLOCK 単独も無効。env 未設定なら全フック即パススルー。

> **Windows の free-run LISTEN は未対応（既知の制約）**: free-run の非ブロッキング accept は現状 POSIX の
> `poll(0)` 実装のみで、Windows 分岐は常に `not_ready`（接続を accept しない silent no-op。port file と
> listen ログは出るが drive が繋がらない）。**Windows では `VP_HARNESS_MANUAL_CLOCK=1` を併用**して旧
> step-driven（blocking accept）経路を使うこと。mac/Linux は free-run 既定でよい（Windows の非ブロッキング
> accept 実装は将来対応）。

### 完全 display-less（P4 → TASK-165）

`VP_HEADLESS=1` で、`platform.init()` が native `backend.init()` 自体を呼ばない（X11/Wayland の display
接続や macOS の WindowServer 接続を一切行わない）。runtime で `core/platform_null.zig` を選び、
`Window` が一次 CPU framebuffer（`w*h` の `u32` バッファ）を所有する。harness は `onLock`/`onPresent`
で観測 copy するだけ（一次 buffer は持たない）。SCRIPT/LISTEN は任意で、transport 無しの display-less
起動も可能。**backend 別の offscreen 実装（X11 Pixmap 等）は採用していない**。

- **純 SSH（`DISPLAY`/`WAYLAND_DISPLAY` 無し）で replay/listen がそのまま回る**（display 接続が無いため）。
- **audio も実デバイス無しで駆動できる**: `core/audio_null.zig`（純 Zig・OS 非依存の null 出力デバイス）が
  `audio_linux`/`audio_windows` と同じ push-thread パターン（実時間 pull スレッド）で render callback を
  駆動し、`harness.onAudioSamples()` へ流す。`audio` probe（`digest audio`/`snapshot audio`）が実 sink 不在
  でも成立する。
- **replay 速度律速の解消**: `platform.frameDelay(nanoseconds)`（manual clock 時は no-op、free-run / harness
  無効時は `platform.sleep()` と同じ）を main loop の frame-wait に使う。manual では仮想クロック + `pollGate` が
  フレーム進行を決めるため real-time sleep は待ち損。`src/main.zig` / `apps/synth/main.zig` /
  examples `01,02,03,04,05,12` は置換済み（`examples/15_audio_tone` の 3 秒 sleep はアプリの寿命そのもの
  なので対象外）。
- **fb crc は headless でも非 headless と bit 一致**（実測確認済み。headless は描画内容を一切変えない）。
- 既知の限界: `audio-only` で `platform.init()` を呼ばないアプリ（`examples/15_audio_tone` 等）は
  `VP_HEADLESS` を解釈できない（判定は `platform.init()` 起点）。もっとも harness 自体は frame loop
  （`window.pollEvents()`）駆動が前提であり、window を持たないアプリは元々 replay スクリプトで駆動できない
  （`step` 相当の同期点が無い）ため実害は無い。
- 実機検証済み（2026-07-04）: **Linux（Ubuntu・VPN 経由の純 SSH）**で x11/wayland build 緑、
  `DISPLAY`/`WAYLAND_DISPLAY` を unset した純 SSH で headless replay 動作（fb crc が mac と bit 一致）、
  sink 不在でも `audio_null` が発音（`digest audio` f0≈262Hz・silent=0）。**Windows 実機**で
  gdi/d3d11 の full build 緑、純 Zig の `test-harness`/`test-audio-null` も compile+pass（facade 型変更が
  Windows backend で compile 確認。runtime headless は OS 非依存で mac/Linux 実証済み）。

### custom probe の足し方（TASK-32.3）

app が内部状態を opt-in で probe として公開する。**framework（`core/control/harness.zig`）には probe 固有のコードを一切足さない**（中身非パースの不変条件）。手順:

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
- `fb` / `audio` / `stats` / `capabilities` は予約名（登録拒否）。同名 custom は上書き。registry 上限は 16。
- `registerProbe` は **harness 無効時（env 未設定）は no-op**なので、通常実行に影響しない（常に呼んでよい）。
- audio RT スレッドが触る状態（synth `voices`/`patch` 等）の読み出しは torn し得る best-effort スナップショット。**RT 経路に同期/alloc/lock を足さない**。
- **`desc`（capabilities 列挙用の説明文。TASK-62.4。省略可）は登録時にサニタイズされる**: `"` / `\` / ASCII 制御文字（tab・NUL 等）を含む、または 200 bytes 超の desc は warn を出し空文字へ落とされる（登録自体は成功する。desc だけ無効化）。**capabilities JSON は desc を JSON エスケープせずそのまま埋め込む前提**なので、この禁止文字は「意味解釈」ではなく wire framing 保護。
- **`args`（TASK-88.1。省略可）も登録時にサニタイズされる**: 各 `ArgSpec` の文字列フィールド（name/kind/values[*]/pattern/desc）に同じ禁止文字規則 + 長さ上限（name/kind 32B・values 各 64B・pattern 100B・desc 200B）を適用。**違反時は warn + args 全体を null に落とす**（登録自体は成功。desc の空文字化と同型のフェイルセーフ）。framework は kind の意味を解釈しない。
- 実装の手本: pixie の `canvas`/`undo`/`tool`（`apps/editor/apps/pixie/main.zig`）、synth の `voices`/`patch`（`apps/synth/main.zig`）。

### custom action の足し方（TASK-62.1）

app が内部の高レベル操作を opt-in で action として公開する。probe（read）の登録手順と対称だが、
**write callback で成功/失敗を返す点が異なる**。**framework（`core/control/harness.zig`）には
action 固有のコードを一切足さない**（中身非パースの不変条件は probe と同じ）。手順:

1. app（`@import("platform")` 済み）で action の callback を書く:
   - `run: fn(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8` — `args`（`action <name>`
     の後の残り行 raw テキスト。trim 済み・再トークン化されない）を受けて状態を変更し、結果1行を
     `buf`（最大 1024B）に書いて返す（改行を含めない。`Probe.digest` と同じ契約）。エラーを返すと
     `run() エラー` として記帳される。
   - `ctx` は app 状態へのポインタ（例 `*App`）。callback 内で `@ptrCast(@alignCast(ctx))` で戻す。
2. `platform.init()` 後・main loop 前に登録する:
   ```zig
   platform.registerAction(.{ .name = "undo", .ctx = &app, .run = appUndo });
   ```
3. これだけで `action undo [args...]` が replay・live 両方で使える。

規約・制約:
- **args は raw テキスト透過（framework は解釈しない）が、`;`/改行を含められない**（`nextLine()` の
  コマンド区切りのため。同一コマンド片内のテキストに限られる）。
- **名前規則**: 空名・空白・`;`・改行を含む名前は登録拒否（コマンド言語上そもそも呼び出せないため）。
  同名 custom は上書き。registry 上限は 48（TASK-90 で 32→48。以前 TASK-62.5.3 で 16→32）。予約名は無い（組み込み action を作らないため）。
- `registerAction` は **harness 無効時（env 未設定）は no-op**なので、通常実行に影響しない（常に呼んでよい）。
- **callback は main thread（`pollGate` 内・step/フレーム境界）で実行される**。RT callback から呼ばれる
  ことは無い。callback が RT スレッドと共有する app 状態に触れる場合、その同期責務は app 側にある
  （probe の digest/snapshot callback と同じ規約）。
- **失敗の扱い**: 未知 action・名前欠落・`run()` のエラーは `expect`/`assert`（TASK-78）と同じ
  `expect_failures` カウンタに記帳される（記帳して続行。即時 abort 変種は無い）。詳細な wire format は
  上記コマンド言語節の「action（probe 対称の高レベル操作 / TASK-62.1）」を参照。
- **structured error（TASK-62.5.9・opt-in）**: エラー return の直前に
  `platform.setActionErrorDetail(code, suggested_next_action)` を呼ぶと、失敗行末尾に
  ` code=<c> next=<n>` が追記される（未呼び出し時は従来と bit 一致）。語彙は app 所有・framework 非解釈。
  詳細は上記 action 節の structured error 項。
- 組み込み action は今回作らない。app 側の action 登録は各採用タスク（pixie/synth/modular 等）で行う。
- **`desc`（capabilities 列挙用の説明文。TASK-62.4。省略可）は probe と同じ規則でサニタイズされる**: `"` / `\` / ASCII 制御文字を含む、または 200 bytes 超は warn + 空文字化（登録自体は成功）。
- **`args`（TASK-88.1。省略可）も probe と同じ規則でサニタイズされる**: name/kind/values/pattern/desc の禁止文字 + 長さ上限違反時は warn + args 全体を null（登録自体は成功。null=JSON から args 省略 / 空 slice=`"args":[]` は区別される）。pixie は全登録 action にシグネチャを付与（`stroke`=variadic 座標列 / `set_tool`=enum / `set_color`=hex pattern / path 系 等）。

- **実行モデル**: 非 step（inject/snapshot/digest/action/await 即時成立時）は即実行。`step N` は
  **manual/replay** では pollEvents を N 回 true にしてフレームを駆動し、**free-run** では
  `frame_index >= X+N` の barrier でアプリの present を待つ。`await` は expect と同じ predicate を
  frame budget で再評価する（timeout 0=1回）。listen free-run では未消費コマンドが無くてもアプリは
  自走し、空 drain は listener `poll(0)` 1 回のみ。**manual LISTEN**（`VP_HARNESS_MANUAL_CLOCK=1`）では
  従来どおり次接続の accept/read で block。**実表示 + manual** では待機中も facade 経由で native
  `pollEvents()` を短周期 pump（TASK-32.6）。**free-run では NativePump を使わない**（二重 poll 回避）。
  **headless** は compositor 未接続のため pump callback は渡さない。
- **仮想クロック**: manual clock 時のみ `getTime()` = `frame_index/60`。free-run は backend 実時刻。
- **制約**: 実ウィンドウ生成は `VP_HEADLESS` 未指定時のみ必須（display 必須。macOS は通常 OK、
  Linux は Xvfb/実セッション）。**`VP_HEADLESS=1` で完全 display-less**（P4, TASK-165 実装済み。
  詳細は上記「完全 display-less（P4）」節）。`audio` は RT スレッド実時間依存なので record→replay で
  digest の bit 一致は非保証（`fb` は manual 仮想クロックで bit 決定論。headless でも同様に bit 決定論で、実測で
  headless と非 headless の fb crc も bit 一致）。**ただし audio を伴うアプリ（run-modular / run-patch）は
  fb crc も非決定**（ポート活性 glow・ミニスコープ・可視化帯など RT 実時間依存の描画があり、main 同士の
  連続実行でも crc 不一致を実測。2026-07-15）→ fb crc を回帰オラクルにせず、(a) grid/UI 領域に限定した
  画素 diff（PNG デコードして領域比較） (b) warm cache でのマクロ box snapshot bit 比較 (c) `snapshot fb` の
  Read 目視で照合し、音は `digest audio`（silent/rms/band）で判定する（pixie 等 audio 無しアプリの fb crc は
  従来どおり bit 決定的）。`fb` の捕捉は CPU フレームバッファ経路で
  **objc / swift / metal いずれでも可**（実測で objc と Metal の fb crc は bit 一致）。Metal の GPU
  drawable 読み戻しは P4 スコープ外（上記参照）。
- **driver は std.Io.net 1本実装**で mac/Linux/Windows 共通コード（`drive` は OS gate 無しで常時 install される。Windows 上での動作は未検証）。`scripts/drive` は `zig-out/bin/drive` を直接 exec する薄い wrapper（応答 stdout を汚さない）。

### vp-mcp（MCP server。TASK-88.2）

harness live TCP の 1 client として attach し、capabilities から MCP tools を動的生成する stdio JSON-RPC アダプタ（アプリ無改造）。

```bash
zig build mcp                    # → zig-out/bin/vp-mcp
# アプリを headless live で起動したうえで:
VP_HEADLESS=1 VP_HARNESS_LISTEN= VP_HARNESS_PORT_FILE=/tmp/vp.port zig build run-pixie &
zig-out/bin/vp-mcp --port-file /tmp/vp.port
# または scripts/mcp --port-file /tmp/vp.port
```

- **引数**: `--port` / `--port-file`（drive と同じ優先順位 + env `VP_HARNESS_LISTEN`（正の値）/`VP_HARNESS_PORT_FILE`）+ `--out <dir>`（snapshot 出力先。省略時 `$TMPDIR/vp-mcp-<port>`。起動時に絶対化 + mkdir）
- **起動時**: `digest capabilities` を 1 回取り、`"truncated":true` なら起動失敗。tool 表は以後固定（アプリ再起動追従なし）
- **MCP**: protocolVersion `2025-06-18` 固定 / initialize → notifications/initialized ゲート / tools/list・tools/call・ping / stdout は JSON-RPC のみ（ログは stderr）
- **tools**: probe → `digest_<name>` / `snapshot_<name>`（path 引数なし。vp-mcp が `--out` 配下の絶対 path を注入）/ action → `<name>`（衝突時 `a_<name>`）
- **検証**: `zig build test-mcp`（純関数単体テスト）

## network 同時編集（netsync, TASK-62.3）

持続 TCP で複数 pixie プロセスが同一ドキュメントを同時編集する（host 権威の PROPOSE/COMMIT）。
実装は `core/control/netsync.zig` + `action_registry.NetworkPolicy`。env 未設定時は完全パススルー。

### 環境変数

| 変数 | 意味 |
|---|---|
| `VP_NETSYNC_HOST=1` | host 役で listen（`VP_NETSYNC_PORT` 必須） |
| `VP_NETSYNC_PORT` | host の listen port |
| `VP_NETSYNC_CONNECT=ip:port` | client 役で接続 |
| `VP_NETSYNC_ACTOR=human\|agent` | client HELLO の actor 種別（既定 `human`。不正値は warn+human） |
| `VP_NETSYNC_LABEL=<表示名>` | client HELLO の表示ラベル（既定 `client`。最大 200B） |

`HOST` と `CONNECT` の同時指定は無効化。listen/connect 失敗は fail-soft（アプリは netsync 無しで継続）。

**copilot との関係（TASK-62.5.6）**: netsync session 中は copilot transport の operate（`action` / `begin_tx` / `end_tx` / `cancel_tx`）を拒否する（observe=digest/snapshot は可）。agent の操作は `VP_NETSYNC_ACTOR=agent` の専用 peer 接続へ一本化。

**teardown 契約（TASK-109）**: Executor は caller 所有の借用で、`platform.shutdown` が App 解放後の teardown に先立って netsync/copilot の借用を drop する。

### フレーム仕様（要点）

```
Frame = { kind: u8, len: u32 LE, payload: [len]u8 }
```

| kind | 値 | payload |
|---|---|---|
| HELLO | `0x01` | テキスト（client→host / host→client） |
| PROPOSE | `0x02` | `u32 LE proposal_id` ++ `"<name> <args>"`（client→host） |
| COMMIT | `0x03` | `u64 LE seq` ++ `u32 LE origin_peer` ++ `"<name> <args>"`（host→clients。host 自身へは送らない） |
| SYNC | `0x04` | `u64 LE seq` ++ state bytes（host→client。join 時 1 回。空 state=snapshot なし） |
| REJECT | `0x05` | `u32 LE proposal_id` ++ `"<reason>"`（host→提案元のみ） |

action 系の上限は `MAX_ACTION_FRAME_BYTES`（4096）。SYNC は big-entry（heap）で `MAX_SYNC_BYTES`（16MiB）まで。超過は当該接続切断。

### join 時 SYNC（TASK-62.3.3）

1. host: HELLO 成功 → inbound に ClientJoined（内部 kind。peer_id+generation）→ pump が export → SYNC(seq=`wire_seq`) を outbound FIFO に big-entry enqueue → `synced=true`。broadcast は synced slot のみ
2. export 未登録 → state 0 の空 SYNC + `snapshot_valid=false`。登録済み exporter が 0 byte を返すのは失敗扱い（切断）
3. client: 接続時 `awaiting_sync=true`。解除まで pump は inbound dequeue ループに入らない（COMMIT は queue に滞留）。SYNC は heap `pending_sync`（後着は置換）。空 SYNC は import なしで解除。import 失敗は保留 COMMIT 不適用のまま fail-soft
4. 4 app は既存 serde（pixie=`document_io` / synth=`patch_io` / modular=`pattern_io` / patch=`graph_io`）を薄い `registerStateSync` で呼ぶだけ

### NetworkPolicy

| 値 | host | client |
|---|---|---|
| `.relay` | ローカル適用 → COMMIT fan-out | PROPOSE のみ（応答 `"proposed <id>"`。適用は後続 COMMIT） |
| `.local_only` | ローカルのみ（broadcast なし） | ローカルのみ（PROPOSE なし） |
| `.reject_when_synced` | 即 `RejectedWhileSynced` | 同左 |
| `.undo_own` / `.redo_own` | 自分の最新 undoable を revert / 直近 revert を再 commit（62.3.5） | PROPOSE_REVERT / 原コマンド PROPOSE |

既定は `.reject_when_synced`。pixie MVP: `stroke`=`.relay`（発信元の tool/color/size/opacity/hardness と
`layer=#<id>` を canonical 化）、`set_color`/`set_tool`=`.local_only`（per-peer UI 状態）、
`save`=`.local_only`。layer 構造 op（add/delete/visible/opacity/move 等）は TASK-94 で `.relay` 昇格済み。

### PROPOSE/COMMIT/REJECT の流れ

1. client が `.relay` action → `proposed <id>` を即返し、PROPOSE を host へ送る（ローカル未適用）
2. host が `network_policy==.relay` を再検証 → 適用 → 全 client へ COMMIT（失敗時は提案元へ REJECT）
3. client が COMMIT を受けて適用（自分起源も含む。router 非経由）
4. REJECT は warn + `last_rejected_proposal`/`last_reject_reason` に保存（62.3.4 probe のデータ源）

**remote 適用（62.3.5）**: 全 wire commit を `source=.remote_commit{seq}` で CommandLog に記録。session 中の local 記録は `wire_session` で抑止（62.3.2 の no_record 暫定例外は解消済み）。

### MVP 2 プロセス手順（probe ベースの決定的待ち）

```bash
# 起動（port file 出現待ちだけ sleep 可。netsync=9110、port file は workspace の .e2e）
mkdir -p .e2e
VP_HEADLESS=1 VP_HARNESS_LISTEN= VP_HARNESS_PORT_FILE=./.e2e/host.port \
  VP_NETSYNC_HOST=1 VP_NETSYNC_PORT=9110 zig build run-pixie &
VP_HEADLESS=1 VP_HARNESS_LISTEN= VP_HARNESS_PORT_FILE=./.e2e/client.port \
  VP_NETSYNC_CONNECT=127.0.0.1:9110 zig build run-pixie &

# client join 完了: free-run では host への step 注入不要。await で一接続保持して待つ。
scripts/drive --port-file ./.e2e/client.port 'await netsync awaiting_sync=0 600'

# 共有 layer を1枚増やし、host/client が別 layer を選ぶ（select_layer は local_only）。
scripts/drive --port-file ./.e2e/host.port 'action add_layer'
until scripts/drive --port-file ./.e2e/host.port 'step 1; digest netsync' | grep -E 'last_seq=[1-9][0-9]*' | grep -q 'pending=0'; do sleep 0.05; done
until scripts/drive --port-file ./.e2e/client.port 'step 1; digest netsync' | grep -q 'awaiting_sync=0'; do sleep 0.05; done
scripts/drive --port-file ./.e2e/host.port 'action select_layer 0; action set_tool brush; action set_color FF0000'
scripts/drive --port-file ./.e2e/client.port 'action select_layer 1; action set_tool pen; action set_color 0000FF'

# 相互 stroke。canonical wire には origin の layer=#id/color/tool が入る。
scripts/drive --port-file ./.e2e/host.port 'action stroke 10 10 60 10'
scripts/drive --port-file ./.e2e/client.port 'action stroke 20 20 70 20'  # → "proposed <id>"

# relay 完了: COMMIT を進める host の step を混ぜ、両側 last_seq>=3 && pending=0 を再照合。
until scripts/drive --port-file ./.e2e/host.port 'step 1; digest netsync' | grep -E 'last_seq=[3-9][0-9]*' | grep -q 'pending=0'; do sleep 0.05; done
until scripts/drive --port-file ./.e2e/client.port 'step 1; digest netsync' | grep -E 'last_seq=[3-9][0-9]*' | grep -q 'pending=0'; do sleep 0.05; done

scripts/drive --port-file ./.e2e/host.port 'digest canvas'    # l0/l1 の crc
scripts/drive --port-file ./.e2e/client.port 'digest canvas'  # 同じ l0/l1 crc、selected は各 peer のまま

# 実測値を採取して l0/l1 の crc 一致、tool/color/selected の peer-local 性を assert する。
# 終了は必ず scripts/drive の quit（pkill 禁止）。
scripts/drive --port-file ./.e2e/host.port 'quit'
scripts/drive --port-file ./.e2e/client.port 'quit'
```

### netsync 観測 probe（TASK-62.3.4）

`platform.init` で netsync 有効時のみ custom probe `netsync` を登録（予約名ではない）。

| 項目 | 内容 |
|---|---|
| digest | 1 行 k=v（live 応答は `netsync ` 接頭）: `role=<host\|client> peers=<n> agents=<n> peer_id=<n> last_seq=<n> pending=<n> awaiting_sync=<0\|1> last_reject=<id\|none> reject_reason=<str\|none> [log=<seq:origin:name,...>]` |
| snapshot | JSON 1 オブジェクト: `peers` 配列 `[{peer_id,kind,label}]` + `agents` + `log` 全件（`ext=json`）。client の peers は自分のみ（PEER_INFO 未配布の既知制約） |
| last_seq | host = wire commit カウンタ / client = 最後に適用した COMMIT の seq |
| reject_reason | ASCII whitespace・制御文字を `_` 置換、64B 切り詰め |
| log 要約 | 末尾数件。revert は `seq:origin:revert->target` |
| agents | 接続中の `kind=agent` peer 数（host=peer テーブル / client=自分） |

### session 中の undo/redo（TASK-62.3.5）

- 自分の wire commit のみ undo 可（`.undo_own`）。host 検証: unknown / not yours / not undoable / already reverted / transaction unsupported / too old / before peer join
- undo は revert 前進適用（`PROPOSE_REVERT` / `COMMIT_REVERT`）。重なり領域の pixel 巻き添えは MVP 割り切り
- redo は原コマンドの通常 PROPOSE/COMMIT（wire に redo_of 非搭載。発行者ローカルの pending meta で epoch を守る）
- transaction undo は session 中非対応
- キーボード Cmd+Z は `netsyncActive()` 中 `routeAction("undo"/"redo")` 経由

決定的待ちは `drive 'digest netsync'` を until で再照合する（固定 sleep リトライは使わない。プロセス起動の port file 待ちだけ sleep 可）。

### セッション中の制約・retry

- PNG open は session 中不可（既定 reject）。layer 構造 op は `.relay` で、同じ stable `#id` を全 peer に適用する。
- save のみローカル可（session 中は CommandLog に記録しない = wire seq 非消費）
- **retry するのは clientSend 失敗（エラー応答）のときだけ**。`"proposed"` / `"revert proposed"` を一度受けたら再送しない。以後は `digest netsync` の決定的待ち
- 接続確立前の action は失敗しうる → join 完了（`awaiting_sync=0`）後に再試行（上記 retry 条件）

## seed/決定論規約（TASK-62.5.7）

seed + コマンド列（レシピ）で作品を完全再現するための共通規約。framework は action 名を予約・解釈しない
（app が `registerAction` する通常 custom action）。62.5.8 のレシピは command 列 replay で seed を再現する。

1. **action 名**: 共通で `seed`。args は u64 の 10 進文字列 1 個。
2. **適用タイミング**: 即時ではなく**次の生成境界**（modular = 次 bar 境界）。再現性の切れ目を境界に
   量子化し、`seed` + 後続コマンド列の replay 決定性を成立させる。
3. **決定論の定義**: `action seed N` 適用後の生成出力は、同一の後続コマンド列・同一 render チャンク分割に
   対して bit 決定的。
4. **seed 適用のセマンティクス**: **生成状態の初期化 + 再スタート**（modular では変異 RNG・背景生成 RNG・
   pattern anchor・シーケンサ実行位置・クロック位相を seed 由来の初期状態へ戻す）。「途中から乱数だけ変わる」
   ではなく「その seed の作品として最初から」が再現性の単位。
5. **CommandRecord への記録**: 通常の recorded command として記録する（専用フィールドは設けない）。

**リセット範囲**: seed 適用がリセットするのは**生成状態**（パターン・変異・生成 RNG・シーケンサ実行位置・
クロック位相）であり、**音響残響 transient は対象外**（reverb/delay の尾・envelope 追従・アンチクリック等）。
出力の bit 決定性は fresh 起動 + コマンド列 replay（レシピ 62.5.8 の実行モデル）で成立し、動作中の seed
変更は「生成レイヤが最初から」を保証する（transient は減衰する非生成状態で、RT callback での大バッファ
memset も避ける）。

**RNG 注入**: app は base seed（u64）+ 用途別 derive（splitmix64 系）に集約する。音色用 fixed seed
（合成ドラムの `"KICK"` / `"HAT1"` / `"CLAP"` 等）は**音色の同一性**が目的なので base seed から独立のまま
（本規約の対象外）。

**ホットパス**: seed の受理・記録はイベント時のみ。RT への反映は既存の lock-free 受け渡し（atomic/Mailbox）+
生成境界での latch/再初期化のみ。RT 経路に alloc/lock/毎サンプル分岐を追加しない。

## レシピ（recipe, TASK-62.5.8）

CommandRecord 列（意味的コマンド列）をファイルへ save/replay し、作品の再現・共有を可能にする。
実装は `libs/recipe`（kit.recipe）+ pixie/modular の `recipe_save` / `recipe_replay` action。

### harness replay script との役割分担

| | harness replay script | recipe |
|---|---|---|
| 中身 | 低レベル入力列（`inject` / `step` / `snapshot` / `digest` / `action`） | 意味的コマンド列（action name+args のみ） |
| 用途 | 検証・再現テスト（ヘッドレス harness） | 作品の保存・共有・再現 |
| 実行 | harness が script を解釈 | app が `routeLocalAction` で逐次適用 |
| 形式 | テキスト行（`;` 区切り可） | serde versioned container（magic=`RCP1`、format_version=1） |

両者は置換関係ではない。harness script で `action recipe_replay <path>` を呼ぶことはできるが、
script 自体がレシピの代替ではない。

### 形式

- **header**: `app_name`（≤64B）+ `format_version=1`
- **entries**: `{name, args}` の列（CommandLog の **kind=normal** を **seq 順**に書き出したもの）
- 破損（CRC）・版不一致・app_name 長超過はエラー
- `recipe_replay` は header.app_name を検証し、不一致なら `code=app_mismatch`（正しい app で開く）

### seed 規約（62.5.7）との組

`seed` も通常の normal command として保存・再生される。**seed + 後続コマンド列 = 作品の完全な再現**
（上記 seed 規約参照）。modular では `action seed N` が recipe に含まれ、replay で同じ生成状態から始まる。

### MVP 制約

- **revert 非対応**: CommandLog の kind=revert は save 対象外（「undo も再生する」再現は 62.3.5 wire 経路依存のためスコープ外）
- **入れ子拒否**: `recipe_replay` 実行中の `recipe_replay` は `code=nested_replay` で拒否
- **失敗中断**: 途中 entry が失敗したらそこで止まり、`code=replay_failed_at_N`（1-based）を載せる
- remix（部分適用・パラメータ差し替え）は将来スコープ

## 性能規約（メモリI/O・キャッシュ最適化）

2026-07 の全ホットパス監査に基づく規約。RT 契約（「オーディオ / シンセ層」節）が全 backend で
守られているのと同じ強度で、以下も**新規実装・変更時の必須規約**として扱う。手本が既にコード内に
あるものは車輪を再発明せず踏襲する。

### ホットパス宣言（すべての新規ループに）

コードを書く前に「このループはどの頻度で走るか」を判定し、**フレーム毎（全画素）/ RT（毎サンプル）
の場合はファイル or 関数の doc comment に明記**する（例: `/// 毎フレーム全画素を走る`）。
実装計画（backlog の plan 欄）にも同じ宣言を含める。頻度の判定を誤ると以下の規約の要否を誤る。

### 全画素ループの3点セット（`libs/pixelops` が正準実装・`libs/gfx/src/sprite.zig` が消費例）

フレーム毎に全画素（またはそれに準ずる面積）を走るループは:

1. **SIMD**: `@Vector(16, u8)` の 4px 同時ブレンド（`pixelops` の `blendPremul4` / `srcOverOpaque4` 型）+ scalar tail。
   **SIMD 版とスカラー参照版の bit 一致テストを必ず併設**する（`libs/pixelops` 既存テストが手本）。
   ブレンド/div255/clip-hoist は自作せず **`@import("pixelops")` の共有実装を使う**（TASK-51）。
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
- SIMD vs スカラー参照の bit 一致（`libs/pixelops`）

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
zig build test-core             # libs/paint（undo + tool + Document/document_io .pix round-trip）+ pixie 入力状態機械
zig build test-gui              # libs/gui
zig build test-png-roundtrip    # PNG encode/decode round-trip（+ canvas 単体）
zig build test-png-format       # PNG format 変換
zig build test-text             # BDF パーサ + テキスト描画
zig build test-font             # libs/font（bmfont 等）
zig build test-sprite           # sprite ブレンド / 描画
zig build test-pixelops         # libs/pixelops（SIMD vs scalar 一致 / div255 恒等 / clipBlit 境界）
zig build test-serde            # libs/serde（versioned container round-trip / 破損検出 / 前方互換 / 固定 fixture）
zig build test-recipe           # libs/recipe（CommandRecord 列 save/load / collect / app_name。TASK-62.5.8）
zig build test-dsp              # src/dsp（Oscillator / ADSR / Filter / Mixer）
zig build test-synth            # libs/synth（SPSC リング / atomic / Voice / VoicePool / Synth）
zig build test-spectrogram      # apps/synth スペクトログラム（FFT 列ロジック）
zig build test-scope            # apps/synth オシロスコープ / レベルメータ
zig build test-harness          # harness（parser / 実行モデル / 仮想クロック / inject midi）
zig build test-appshell         # libs/appshell（Preferences/WindowState/RecentFiles/DocumentHost）
zig build test-midi             # core/midi facade + null backend（TASK-115.1）
zig build test-sound            # libs/sound（WAV decode / SoundPlayer RT ゼロアロケーション。TASK-111.6）
zig build test-platform-clipboard # clipboard facade round-trip（headless in-memory fallback。TASK-120）
zig build test-gui-leak         # PerIdStateStore の state leak 計測（ユニーク100 ID×300 frame。TASK-121.2）
# 入力変換の単体テスト（display/compositor 不要）: test-platform-input / -wayland-input / -windows-input / -convert / test-platform-types
# テスト実装の規約: ファイル I/O を伴うテストは cwd 固定ファイル名を使わず std.testing.tmpDir(.{}) を使う
# （@import 連鎖で同じテストが複数テストバイナリに同居し、集約 test の並列実行で固定名を取り合って
#   高負荷時のみ flaky になる。単体実行では再現しない。TASK-96 実測・tmpDir 化で根治）

# マイクロベンチ（性能変更の前後比較。ReleaseFast 固定・display/audio デバイス不要・OS 非依存。TASK-50）
zig build bench-canvas          # Canvas.composite / compositeStraight の ns/frame・Mpx/s
zig build bench-synth           # Synth(16voice).render / MasterEffects.process の ns/block・×realtime
zig build bench-gui-frame       # gui full Context frame（beginFrame→構築→endFrame→render。500/1000行 avg/min/p95。TASK-121.2）

# Pixie エディタの実行（-Dplatform で objc/swift/metal 切替）
zig build run-pixie

# Synth アプリの実行（PC キーボード演奏。A..K = C4..C5、ESC で終了）
zig build run-synth

# 特定のサンプルを実行（ルートから。run-example_01 〜 _19）
zig build run-example_01        # 01_timed_window
zig build run-example_04        # 04_fixed_timestep
zig build run-example_05        # 05_text_rendering
zig build run-example_07        # 07_mouse_input
zig build run-example_15        # 15_audio_tone
zig build run-example_17        # 17_gui_toggles（checkbox/toggle/radio。TASK-48）
zig build run-example_18        # 18_cursor（system cursor 形状切替。TASK-75.1）
zig build run-example_19        # 19_color_emoji（Apple Color Emoji.ttc の sbix カラー絵文字デモ。TASK-26.4）
zig build run-example_23        # 23_fullscreen（Window.createFullscreen デモ。全域 animated グラデーション。ESC/Q で終了。TASK-100）
# 一覧: 01_timed_window / 02_keyboard_input / 03_sprite_rendering / 04_fixed_timestep / 05_text_rendering /
#       06_sprite_benchmark / 07_mouse_input / 08_gui_primitives / 09_gui_interaction / 10_gui_layout /
#       11_gui_widgets / 12_outline_font / 13_gui_slider / 14_gui_color_picker / 15_audio_tone /
#       16_gui_scroll / 17_gui_toggles / 18_cursor / 19_color_emoji / 20_capture_demo / 21_char_input /
#       22_gamepad / 23_fullscreen / 24_desktop_mascot / 25_collision_demo / 26_appshell_demo /
#       27_selectable_label / 28_text_input / 29_midi_monitor / 30_sound_demo / 31_sprite_ex /
#       32_sprite_anim / 33_camera / 34_action_map / 35_gui_gallery / 36_tilemap / 37_gui_torture  （image/ は共有アセットで run step なし）
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
