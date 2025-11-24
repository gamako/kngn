# 03: Sprite Rendering

スプライトシステムのデモンストレーション。PNG画像を読み込んで画面に表示し、キーボードで操作します。

## 機能

- PNG画像の読み込み（`libs/png-decoder/`を使用）
- クリッピング処理（画面外への描画を安全に処理）
- キーボードによるインタラクティブな操作

## 操作方法

- **矢印キー**: スプライトを移動（5px/フレーム）
- **ESC**: 終了

## ビルド・実行

### ルートディレクトリから

```bash
# デフォルト（Objective-C版）
zig build run-example_03

# プラットフォームを指定
zig build run-example_03-swift    # Swift版
zig build run-example_03-metal    # Metal版
```

### 独立ビルド

```bash
cd examples/03_sprite_rendering

# デフォルト（Objective-C版）
zig build run

# プラットフォームを指定
zig build run -Dplatform=swift    # Swift版
zig build run -Dplatform=metal    # Metal版
```

## 使用技術

- **プリミティブAPI**:
  - `platform_lock_framebuffer()` - フレームバッファアクセス
  - `platform_unlock_framebuffer()` - アクセス終了
  - `platform_present()` - 画面更新
  - `platform_poll_events()` - イベントポーリング

- **ヘルパーモジュール**:
  - `keyboard.zig` - キーボード定義
  - `sprite.zig` - スプライト描画システム（Phase 2ヘルパー）

- **サブプロジェクト**:
  - `libs/png-decoder/` - PNG画像デコード

## 技術的な詳細

### スプライトシステム（Phase 1実装）

現在の実装には以下の機能が含まれます：

- ✅ **クリッピング処理**: スプライトが画面外にはみ出しても安全に描画
- ✅ **座標管理**: スプライトの位置を自由に変更可能
- ✅ **PNG読み込み**: RGBA形式の画像を読み込み

### Phase 1の制限事項

以下の機能は将来のPhaseで実装予定です：

- ❌ **アルファブレンディング**: 透明部分は現在上書きされます
- ❌ **複数スプライト管理**: 現在は単一スプライトのみ
- ❌ **回転・スケーリング**: 位置のみ変更可能
- ❌ **アニメーション**: 静止画のみ

### フレームバッファ形式

- **フォーマット**: RGBA8888（32bit）
- **バイトオーダー**: `0xRRGGBBAA`
- PNG decoderの出力形式と完全互換

## スプライト画像

- **ファイル**: `examples/image/usako.png`
- **サイズ**: 64x64
- **フォーマット**: RGBA

## 関連ドキュメント

- [実装計画](../../docs/PLAN_example_03.md) - 詳細な設計書
- [AGENT.md](../../AGENT.md) - プロジェクト全体の構造
- [PLAN.md](../../docs/PLAN.md) - プラットフォーム層の設計
