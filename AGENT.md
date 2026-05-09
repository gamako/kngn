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
│   └── sprite.zig     # スプライトシステム（Phase 2ヘルパー）
├── examples/          # サンプルプログラム
│   ├── 01_timed_window/       # タイマー制御ウィンドウ
│   ├── 02_keyboard_input/     # キーボード入力
│   ├── 03_sprite_rendering/   # スプライト表示
│   └── image/
│       └── usako.png          # スプライト画像
├── libs/              # サブプロジェクト
│   └── png-decoder/   # PNG デコーダー
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

## 開発フェーズの状態

- ✅ **フェーズ1（プリミティブAPI）**: 完成
  - イベント処理API
  - 手動描画API
  - 時刻取得API
- ✅ **サンプル**: 01_timed_window, 02_keyboard_input, 03_sprite_rendering
- 🚧 **フェーズ2（ヘルパー関数群）**: 進行中
  - ✅ sprite.zig - スプライト描画（Phase 1: クリッピングのみ）
  - ⚠️ FPSCounter, FixedTimeStep, DoubleBuffer等 - 未着手
- ⚠️ **フェーズ3（テンプレート）**: 未着手
  - SimpleApp, GameLoop, SnapshotRenderer等

## プラットフォーム層の種類

| 実装            | ファイル                                          | レンダリング  | 状態                  |
| --------------- | ------------------------------------------------- | ------------- | --------------------- |
| **Objective-C** | `platform/macos/platform_macos.m`                 | CALayer       | ✅ 完全動作           |
| **Swift**       | `platform/macos-swift/platform_macos.swift`       | CADisplayLink | ✅ 完全動作           |
| **Metal**       | `platform/macos-metal/platform_macos_metal.swift` | Metal GPU     | ⚠️ 警告あり（動作）   |

**Metal版の警告**: `CAMetalLayerDrawable`のライフサイクル問題。機能的には動作中。

## 主要なプラットフォームAPI

### コアプリミティブ
- `platform_init()` / `platform_shutdown()` - 初期化/終了
- `platform_create_window()` / `platform_destroy_window()` - ウィンドウ管理

### イベント処理
- `platform_poll_events()` - イベントポーリング（ノンブロッキング）
- `platform_get_event()` - イベント取得（1つずつ）
- `PlatformEvent` - イベント構造体（QUIT, KEY_DOWN, KEY_UP）

### 手動描画
- `platform_lock_framebuffer()` - フレームバッファアクセス開始
- `platform_unlock_framebuffer()` - フレームバッファアクセス終了
- `platform_present()` - 画面更新（vsync待ちなし）

### ユーティリティ
- `platform_get_time()` - 高精度モノトニック時刻取得

## よく使うコマンド

```bash
# すべてのプラットフォーム版をビルド
zig build -Dinstall-all=true

# PNG デコーダーのテスト
zig build test-png-format

# 特定のサンプルを実行（ルートから）
zig build run-example_01        # 01_timed_window
zig build run-example_02        # 02_keyboard_input
zig build run-example_03        # 03_sprite_rendering
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
