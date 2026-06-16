# video-proto プロジェクト

クロスプラットフォーム対応のビデオ/グラフィックスプロトタイピング環境。Zigで記述されたアプリケーション層と、各プラットフォーム固有の実装（Swift/Objective-C）による低レベルAPI層で構成されています。

**目的**: 最小限のプリミティブAPIを提供し、開発者が柔軟にグラフィックスアプリケーションを構築できる環境を提供する。

**現在の対象**: macOS（3つの実装：Objective-C、Swift、Metal）

## ディレクトリ構造

```
video-proto/
├── platform/           # プラットフォーム層（C API）
│   ├── platform.h     # プリミティブAPI定義
│   ├── macos/         # Objective-C実装
│   ├── macos-swift/   # Swift実装
│   └── macos-metal/   # Metal実装
├── src/               # Zigコード
│   ├── main.zig       # メインプログラム（虹色グラデーション）
│   ├── keyboard.zig   # キーボード定義モジュール
│   ├── sprite.zig     # スプライトシステム（Phase 2ヘルパー）
│   ├── fixed_timestep.zig # 固定タイムステップヘルパー（Phase 2ヘルパー）
│   ├── fps_counter.zig    # FPS 計測ヘルパー（Phase 2ヘルパー）
│   └── text.zig       # BDF ビットマップフォント描画（Phase 2ヘルパー）
├── examples/          # サンプルプログラム
│   ├── 01_timed_window/       # タイマー制御ウィンドウ
│   ├── 02_keyboard_input/     # キーボード入力
│   ├── 03_sprite_rendering/   # スプライト表示
│   ├── 04_fixed_timestep/     # 固定タイムステップ + 物理シミュレーション
│   └── 05_text_rendering/     # ビットマップフォントによるテキスト描画
├── libs/              # 再利用ライブラリ
│   ├── png-decoder/   # PNG デコーダー
│   └── gui/           # 即時モード GUI（入力 / ID stack / Flex レイアウト / 描画 / ウィジェット）
├── apps/              # アプリケーション
│   └── editor/        # グラフィックエディタ群（TASK-21 ファミリー）
│       ├── core/      # 再利用コア: Canvas / Tool(Pen/Eraser) / UndoStack / StrokeRecorder / PNG I/O
│       └── apps/pixie/ # ドット絵エディタ MVP（Pen/Eraser/DB16 パレット/Undo/PNG 保存）
└── docs/              # ドキュメント
    └── PLAN.md        # 実装計画（詳細）
```

## クイックスタート

### 前提環境

| 項目 | 用途 |
|------|------|
| macOS（Apple Silicon）+ Xcode | SDK / framework / `swiftc` の提供（必須）。`flake.nix` は `aarch64-darwin` のみ対応 |
| nix（flake 対応） | `flake.nix` 経由で zig 0.16.0 + zls を提供 |
| direnv | プロジェクトディレクトリに入ると自動で nix devShell を有効化（推奨） |

### セットアップ

`flake.nix` で zig 0.16.0 と zls を pin している。`direnv allow` 一回でディレクトリに入れば自動で zig が PATH に通る。

```bash
direnv allow                     # 初回のみ（.envrc を許可）
zig version                      # → 0.16.0 が返ること
```

direnv を使わない場合は `nix develop` でシェルに入るか、各コマンドを `nix develop --command zig build` のように呼ぶ。

### メインプログラムのビルド・実行

```bash
# ビルド（3つのプラットフォーム実装から選択）
zig build                        # Objective-C版（デフォルト）
zig build -Dplatform=swift       # Swift版
zig build -Dplatform=metal       # Metal版

# 実行
zig build run                    # デフォルトプラットフォーム
zig build run-objc               # Objective-C版
zig build run-swift              # Swift版
zig build run-metal              # Metal版
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

## 開発フェーズの状態

- ✅ **フェーズ1（プリミティブAPI）**: 完成
  - イベント処理API
  - 手動描画API
  - 時刻取得API
- ✅ **サンプル**: 01_timed_window, 02_keyboard_input, 03_sprite_rendering, 04_fixed_timestep, 05_text_rendering
- 🚧 **フェーズ2（ヘルパー関数群）**: 進行中
  - ✅ sprite.zig - スプライト描画（Phase 1: クリッピングのみ）
  - ✅ fixed_timestep.zig - 固定タイムステップ
  - ✅ fps_counter.zig - FPS 計測（コンソール出力版）
  - ✅ text.zig - BDF ビットマップフォント描画
  - ⚠️ DoubleBuffer 等 - 未着手
- ⚠️ **フェーズ3（テンプレート）**: 未着手
  - SimpleApp, GameLoop, SnapshotRenderer等

## プラットフォーム層の種類

| 実装            | ファイル                                          | レンダリング  | 状態                  |
| --------------- | ------------------------------------------------- | ------------- | --------------------- |
| **Objective-C** | `platform/macos/platform_macos.m`                 | CALayer       | ✅ 完全動作           |
| **Swift**       | `platform/macos-swift/platform_macos.swift`       | CADisplayLink | ✅ 完全動作           |
| **Metal**       | `platform/macos-metal/platform_macos_metal.swift` | Metal GPU     | ⚠️ 警告あり（動作）   |
| **X11 (Linux)** | `src/platform_linux.zig`（純 Zig / Xlib 直接）  | XShm/XPutImage | ✅ window+blit+入力（TASK-28.2/28.3） |

**Metal版の警告**: `CAMetalLayerDrawable`のライフサイクル問題。機能的には動作中。

### backend の選び方（OS 依存）

`src/platform.zig`（facade）が `builtin.os.tag` で backend を切り替え、`build_options.platform_backend`
で具体実装を選ぶ。`-Dplatform` の有効値は OS で変わる:

- **macOS**: `objc`（既定）/ `swift` / `metal`
- **Linux**: `x11`（既定）。`wayland` は TASK-28.5 で追加予定（現状は build エラー）。

不整合（例: Linux で `-Dplatform=objc`）は明確な build エラーになる。共有型（`KeyCode`/`Event` 等）は
`src/platform_types.zig` が単一ソース。

### Linux（x86_64）のビルド・検証

`flake.nix` は `aarch64-darwin` と `x86_64-linux` の 2 system を提供する。Linux 側 devShell は
zig 0.16 + zls + X11 dev lib（`libX11`/`libXext`）+ Xvfb（`xorgserver`）+ `xwd` + `ffmpeg` + `zenity` + `xdotool`（入力合成）を含む。

入力（key/mouse/scroll/modifier）は `src/platform_linux.zig` が XEvent を変換する（TASK-28.3）。物理キーは evdev
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
- `window.lockFramebuffer()` - フレームバッファアクセス開始 (`?Framebuffer`)
- `fb.unlock()` - フレームバッファアクセス終了
- `window.present()` - 画面更新（vsync待ちなし）

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
  - 不変条件: 表示は `composite()`（白背景合成）、**PNG 保存は raw layer pixels**（透明保持）。
- **apps/editor/apps/pixie**: ドット絵エディタ MVP。`canvas_input.zig`（入力状態機械）が
  press 起点 capture → Tool 経由で stroke を駆動する。

> 注: エディタのタスク管理はトップ階層（`video-proto/`）の Backlog.md CLI で行う（上位 AGENTS.md 参照）。
> Zig 0.16 のイディオムは `zig-best-practices` スキルを参照。

## オーディオ / シンセ層（TASK-27 ファミリー）

グラフィックスと対称な 4 層構成でオーディオ（音）シンセサイザー基盤を構成する。設計の正は
トップ階層の `docs/plans/synth-foundation-plan.md`。

| 層 | 場所 | 内容 |
|---|---|---|
| **L1 platform** | `src/audio.zig`（facade）+ `src/audio_macos.zig`（実装） | オーディオ出力プリミティブ。AudioUnit (Default Output Unit) を **extern fn** で叩く（`@cImport` しない）。`open/start/stop/close/config`。`AudioToolbox` は audio を使う exe にのみ `linkFramework`（既存 exe は不変）。 |
| **L2 helpers** | `src/dsp/`（`@import("dsp")`） | Oscillator / Envelope(ADSR) / Filter(TPT SVF) / Mixer + denormal 対策。純 Zig。 |
| **L3 libs** | `libs/synth/`（`@import("synth")`） | Voice / 固定 VoicePool（スチール + done 回収）/ Patch / Synth。GUI⇔Audio のロックフリー受け渡し（SPSC `NoteQueue` / `AtomicF32` / `DoubleBuffer` / 出力タップ `SampleTap`）。dsp に依存。 |
| **L4 apps** | `apps/synth/`（`run-synth`）+ `examples/15_audio_tone`（`run-example_15`） | PC キーボード演奏 MVP / サイン波最小サンプル。 |

**最重要のスレッドモデル**: グラフィックスは CADisplayLink（メインスレッド）、オーディオは CoreAudio
の **RT スレッド**でレンダーコールバックを呼ぶ。**RT スレッドでは malloc/lock/IO/panic 禁止**。
メイン⇔RT のデータ交換は `libs/synth` のロックフリー機構（note は SPSC、連続パラメータは atomic、
出力タップは drop 可）で行う。

## よく使うコマンド

```bash
# すべてのプラットフォーム版をビルド（example / platform のビルド回帰確認にも使う）
zig build -Dinstall-all=true

# すべてのテストを実行（集約。全 test-* を束ねる）
zig build test

# 個別テスト
zig build test-core             # editor/core（undo + tool）+ pixie 入力状態機械
zig build test-gui              # libs/gui
zig build test-png-roundtrip    # PNG encode/decode round-trip（+ canvas 単体）
zig build test-png-format       # PNG format 変換
zig build test-text             # BDF パーサ + テキスト描画
zig build test-sprite           # sprite ブレンド / 描画
zig build test-dsp              # src/dsp（Oscillator / ADSR / Filter / Mixer）
zig build test-synth            # libs/synth（SPSC リング / atomic / Voice / VoicePool / Synth）

# Pixie エディタの実行（-Dplatform で objc/swift/metal 切替）
zig build run-pixie

# Synth アプリの実行（PC キーボード演奏。A..K = C4..C5、ESC で終了）
zig build run-synth

# 特定のサンプルを実行（ルートから。run-example_01 〜 _NN）
zig build run-example_01        # 01_timed_window
zig build run-example_02        # 02_keyboard_input
zig build run-example_03        # 03_sprite_rendering
zig build run-example_04        # 04_fixed_timestep
zig build run-example_05        # 05_text_rendering
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
