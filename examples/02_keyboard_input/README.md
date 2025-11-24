# Example 02: Keyboard Input (Interactive Color Palette)

キーボード入力でインタラクティブに色を変更できるカラーパレットアプリです。

## 説明

このサンプルは、キーボードイベント処理の基本的な使用方法を示しています：

- `platform_poll_events()` - イベントポーリング
- `platform_get_event()` - イベント取得
- `PlatformEvent` - イベント構造体（キーコード、モディファイア、リピート検出）
- `keyboard.zig` - キーコード定義とヘルパー関数
- `platform_lock_framebuffer()` / `platform_unlock_framebuffer()` - フレームバッファアクセス
- `platform_present()` - 画面更新

## 動作

- ウィンドウサイズ: 800x600
- 初期色: オレンジ（HSV: 0°, 0.8, 0.8）
- キーボード操作で色が変化

## 操作方法

### 基本操作

| キー | 動作 |
|------|------|
| **A-Z** | 26色のカラーパレット（A=赤系、N=緑系、...） |
| **0-9** | グレースケール（0=暗い、9=明るい） |
| **↑** | 明度を上げる（+5%） |
| **↓** | 明度を下げる（-5%） |
| **←** | 色相を左に回転（-10°） |
| **→** | 色相を右に回転（+10°） |
| **Space** | ランダムカラー |
| **R** | リセット（初期色に戻る） |
| **ESC / Q** | 終了 |

### モディファイアキー

Shift、Ctrl、Alt、Cmdキーを押すとコンソールに表示されます。

## ビルド方法

### Objective-C版（デフォルト）
```bash
cd examples/02_keyboard_input
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
./zig-out/bin/example_02_keyboard_input        # Objective-C版
./zig-out/bin/example_02_keyboard_input_swift  # Swift版
./zig-out/bin/example_02_keyboard_input_metal  # Metal版
```

## 学習ポイント

### 1. イベントループの基本パターン

```zig
while (platform_poll_events(window)) {
    // イベント処理
    var event: PlatformEvent = undefined;
    while (platform_get_event(window, &event)) {
        if (event.type == PLATFORM_EVENT_QUIT) {
            return; // 終了
        } else if (event.type == PLATFORM_EVENT_KEY_DOWN) {
            // キーボードイベント処理
            const key = event.payload.keyboard.key;
            const modifiers = event.payload.keyboard.modifiers;
            const is_repeat = event.payload.keyboard.is_repeat;

            // キーに応じた処理...
        }
    }

    // 描画処理...
}
```

### 2. キーコードの取得と判定

```zig
const keyboard = @import("keyboard");

// キーコードの判定
if (key == keyboard.Key.ESCAPE) {
    return; // ESC で終了
}

// 範囲判定
if (key >= keyboard.Key.A and key <= keyboard.Key.Z) {
    // A-Z キーが押された
}
```

### 3. モディファイアキーの処理

```zig
// モディファイアキーの検出
if (modifiers & PLATFORM_MOD_SHIFT != 0) {
    std.debug.print("Shift+", .{});
}
if (modifiers & PLATFORM_MOD_CTRL != 0) {
    std.debug.print("Ctrl+", .{});
}
if (modifiers & PLATFORM_MOD_ALT != 0) {
    std.debug.print("Alt+", .{});
}
if (modifiers & PLATFORM_MOD_CMD != 0) {
    std.debug.print("Cmd+", .{});
}
```

### 4. リピートイベントの検出

```zig
if (is_repeat) {
    std.debug.print(" [REPEAT]", .{});
}
```

### 5. keyboard.zig モジュールの活用

```zig
const keyboard = @import("keyboard");

// キー名の取得
const key_name = keyboard.getKeyName(key);
std.debug.print("Key pressed: {s}\n", .{key_name});

// キー情報の取得
const info = keyboard.getKeyInfo(key);
std.debug.print("Category: {s}\n", .{info.category});
```

## コンソール出力例

```
Starting 02_keyboard_input (Interactive Color Palette)...
Window created. Interactive color palette ready.
Controls:
  A-Z: 26 colors (hue variation)
  0-9: Grayscale (10 steps)
  Arrow Keys: Adjust hue/brightness
  Space: Random color
  R: Reset to default
  ESC/Q: Quit
[KEY_DOWN] A (code=4)
[KEY_DOWN] SHIFT+B (code=5)
[KEY_DOWN] CTRL+ALT+C (code=6)
[KEY_DOWN] Space (code=44)
[KEY_DOWN] UP (code=82)
[KEY_DOWN] Q (code=20)
Quit key pressed
Application terminated.
```

## 次のステップ

- `03_mouse_input` - マウス入力の処理（予定）
- `04_animation` - より複雑なアニメーション（予定）
- `05_text_rendering` - テキスト描画（予定）

## 実装の詳細

### HSV色空間

このサンプルでは、色の指定にHSV色空間（色相、彩度、明度）を使用しています：

- **H (Hue)**: 色相（0-360°）- 色の種類
- **S (Saturation)**: 彩度（0.0-1.0）- 色の鮮やかさ
- **V (Value)**: 明度（0.0-1.0）- 色の明るさ

HSVは直感的に色を操作できるため、インタラクティブなカラーパレットに適しています。

### フレームレート制御

現在の実装では `std.Thread.sleep(16_666_666)` (約60FPS) を使用していますが、本格的なアプリケーションではvsync同期やより高度なタイミング制御が推奨されます。

## 注意事項

- キーボードイベントはメインスレッドで処理されます
- リピートイベントは、キーを押し続けたときに複数回発生します
- モディファイアキーの組み合わせは、プラットフォームによって異なる場合があります
