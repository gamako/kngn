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
│   └── macos-swift/
│       └── platform_macos.swift  # macOS実装（Swift版）
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

### 3. カスタムパス指定（CI環境用）

SwiftツールチェーンパスとSDKパスを明示的に指定できます：

```bash
zig build -Dplatform=swift \
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

### 4. その他のビルドコマンド

```bash
# 両方のバージョンをビルド・インストール
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

### 汎用実行（プラットフォームオプション従う）

```bash
zig build run
```

## パス自動検出の仕組み

Swift版をビルドする際、以下のコマンドで環境から動的にパスを取得しています：

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

