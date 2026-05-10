# Example 01: Timed Window

時間経過で色が変わるウィンドウを2秒間表示し、自動終了するサンプルです。

## 説明

このサンプルは、手動描画APIの基本的な使用方法を示しています：

- `platform.Window.create()` - ウィンドウ作成
- `window.pollEvents()` - イベントポーリング（ノンブロッキング）
- `platform.getTime()` - 高精度時刻取得
- `window.lockFramebuffer()` - フレームバッファへのアクセス開始
- `fb.unlock()` - フレームバッファへのアクセス終了
- `window.present()` - 画面更新

## 動作

- ウィンドウサイズ: 800x600
- 表示時間: 2秒間
- 色の変化: 緑 → 黄 → 赤

## ビルド方法

### Objective-C版（デフォルト）
```bash
cd examples/01_timed_window
zig build
# または
zig build run-objc
```

### Swift版
```bash
zig build -Dplatform=swift
# または
zig build run-swift
```

### Metal版
```bash
zig build -Dplatform=metal
# または
zig build run-metal
```

## 実行

ビルド後、以下のコマンドで実行できます：

```bash
# デフォルト（Objective-C版）
zig build run

# 個別実行
./zig-out/bin/example_01_timed_window        # Objective-C版
./zig-out/bin/example_01_timed_window_swift  # Swift版
./zig-out/bin/example_01_timed_window_metal  # Metal版
```

## 学習ポイント

### 1. 手動描画のフロー

```zig
const platform = @import("platform");

try platform.init();
defer platform.shutdown();

var window = try platform.Window.create(800, 600, "title");
defer window.destroy();

while (window.pollEvents()) {
    // 1. フレームバッファをロック
    if (window.lockFramebuffer()) |fb| {
        defer fb.unlock();

        // 2. ピクセルデータを書き込み
        @memset(fb.pixels, color);

        // 3. 画面を更新
        window.present();
    }
}
```

### 2. 時刻の取得とタイミング制御

```zig
const start_time = platform.getTime();
const elapsed = platform.getTime() - start_time;

if (elapsed >= duration) {
    break; // 終了
}
```

### 3. 色の補間

線形補間を使用して、2つの色の間を滑らかに遷移させています。

## 次のステップ

- `02_keyboard_input` - キーボード入力の処理
- `03_mouse_input` - マウス入力の処理
- `04_animation` - より複雑なアニメーション

## 注意事項

- このサンプルでは `std.time.sleep()` を使用してフレームレートを制御していますが、本格的なアプリケーションではvsync同期やより高度なタイミング制御が推奨されます。
- `window.present()` は現在の実装ではvsync同期を行わないため、画面のティアリング（ずれ）が発生する可能性があります。
