# zigで画像表示を行うプロトタイプ

Zig + C/Swiftを組み合わせた、macOSでのクロスプラットフォーム映像表示システムのプロトタイプです。

## プロジェクト構成

```
.
├── src/
│   └── main.zig              # メインプログラム（Zig）
├── platform/
│   ├── macos/
│   │   └── platform_macos.m  # macOS実装（Objective-C版）
│   ├── macos-swift/
│   │   └── platform_macos.swift  # macOS実装（Swift版）
│   └── macos-metal/
│       └── platform_macos_metal.swift  # macOS実装（Metal版）
├── build.zig                 # ビルド設定
└── README.md                 # このファイル
```

## 要件

- **Zig**: 0.16.0-dev以上
- **macOS**: 10.15以上
- **Xcode**: Command Line Tools

## ビルド方法

### 1. デフォルトビルド（Objective-C版）

```bash
zig build
```

自動的に環境から必要なパスを検出します。生成物は `zig-out/bin/video_proto` に配置されます。

### 2. Swift版のビルド

```bash
zig build -Dplatform=swift
```

Swift版を明示的に選択してビルドします。生成物は `zig-out/bin/video_proto_swift` に配置されます。

#### 特徴

- Swiftランタイムライブラリパスは**自動検出**されます
- `xcode-select`と`xcrun`コマンドを使用して環境から動的にパスを取得
- CI環境など特殊な環境では、パスを明示的に指定可能です

### 3. Metal版のビルド

```bash
zig build -Dplatform=metal
```

Metal版を明示的に選択してビルドします。生成物は `zig-out/bin/video_proto_metal` に配置されます。

#### 特徴

- GPU直結のレンダリング（MTKView + Metal API）
- Metalシェーダーを使った高速描画
- Metal Compute Shaderではなくテクスチャ転送方式（CPU→GPU）
- 既存のobj-c版・swift版と同じAPI

### 4. カスタムパス指定（CI環境用）

SwiftツールチェーンパスとSDKパスを明示的に指定できます：

```bash
zig build -Dplatform=swift \
  -Dswift-toolchain-path=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain \
  -Dswift-sdk-path=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
```

同様にMetal版も指定可能です：

```bash
zig build -Dplatform=metal \
  -Dswift-toolchain-path=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain \
  -Dswift-sdk-path=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
```

**オプション説明:**

| オプション | 型 | 説明 | デフォルト |
|-----------|-----|------|----------|
| `-Dplatform=[enum]` | `objc`\|`swift` | プラットフォーム層の実装を選択 | `objc` |
| `-Dswift-toolchain-path=[string]` | パス | Xcodeツールチェーンパス | 自動検出 |
| `-Dswift-sdk-path=[string]` | パス | macOS SDKパス | 自動検出 |
| `-Dinstall-all=[bool]` | - | ObjC版とSwift版の両方をビルド | `false` |
| `--release[=mode]` | - | リリースモード（`fast`, `safe`, `small` 指定可） | デバッグ |

### 5. その他のビルドコマンド

```bash
# すべてのバージョンをビルド・インストール
zig build -Dinstall-all=true

# リリースビルド（最適化）
zig build --release=fast

# キャッシュをクリア
rm -rf .zig-cache zig-out
```

## 実行方法

### Objective-C版を実行

```bash
zig build run-objc
```

またはビルド後：

```bash
./zig-out/bin/video_proto
```

### Swift版を実行

```bash
zig build run-swift
```

またはビルド後：

```bash
./zig-out/bin/video_proto_swift
```

### Metal版を実行

```bash
zig build run-metal
```

またはビルド後：

```bash
./zig-out/bin/video_proto_metal
```

### 汎用実行（プラットフォームオプション従う）

```bash
zig build run
```

デフォルトではObjective-C版が実行されます。Metal版を実行したい場合：

```bash
zig build run -Dplatform=metal
```

## プラットフォーム実装比較

| 特性 | Objective-C版 | Swift版 | Metal版 |
|------|----------------|---------|---------|
| **フレームワーク** | Cocoa, QuartzCore | Cocoa, QuartzCore | Metal, MetalKit |
| **描画方式** | CALayer | CALayer | MTKView + Metal API |
| **ピクセル更新** | CGImage再生成 | CGImage再生成 | テクスチャ転送 |
| **GPU利用** | ✗ (CPU描画) | ✗ (CPU描画) | ✓ (GPU描画) |
| **パフォーマンス** | ⭐⭐ | ⭐⭐ | ⭐⭐⭐ |
| **実装言語** | Objective-C | Swift | Swift |
| **Swiftランタイム** | ✗ | ✓ | ✓ |

**推奨される用途:**
- **Objective-C版**: 軽量で依存性が少ない実装が必要な場合
- **Swift版**: Swiftの型安全性が必要な場合、CALayerの標準機能で十分な場合
- **Metal版**: 高パフォーマンスが必要、大解像度での描画が必要な場合

## パス自動検出の仕組み

Swift版・Metal版をビルドする際、以下のコマンドで環境から動的にパスを取得しています：

```bash
# ツールチェーンパス取得
xcode-select -p
# → /Applications/Xcode.app/Contents/Developer

# SDK パス取得
xcrun --show-sdk-path
# → /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
```

これにより、Xcode更新時も`build.zig`の修正が不要になります。

## トラブルシューティング

### エラー: "unable to open library directory"

Swiftパスが正しく検出されていない可能性があります。以下を確認してください：

```bash
# パスが正しく取得されるか確認
xcode-select -p
xcrun --show-sdk-path

# 明示的にパスを指定してビルド
zig build -Dplatform=swift \
  -Dswift-toolchain-path=$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain \
  -Dswift-sdk-path=$(xcrun --show-sdk-path)
```

### エラー: "Command Line Tools missing"

Xcode Command Line Toolsが インストールされていない、または古い可能性があります：

```bash
# インストール
xcode-select --install

# 更新
softwareupdate -i -a
```

