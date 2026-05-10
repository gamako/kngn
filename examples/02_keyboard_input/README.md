# Example 02: Keyboard Input (Interactive Color Palette)

キーボード入力でインタラクティブに色を変更できるカラーパレットアプリです。

## 説明

このサンプルは、キーボードイベント処理の基本的な使用方法を示しています：

- `platform.init()` / `platform.shutdown()` - プラットフォーム初期化・終了
- `platform.Window.create()` / `window.destroy()` - ウィンドウ管理
- `window.pollEvents()` - イベントポーリング（ノンブロッキング）
- `window.nextEvent()` - イベント取得（tagged union）
- `platform.Event` - `quit` / `key_down` / `key_up` の sum type
- `platform.KeyEvent` - キーコード、モディファイア、リピート検出
- `platform.KeyCode` - 強型化されたキーコード enum
- `platform.ModifierFlags` - SHIFT/CTRL/ALT/CMD を packed struct で表現
- `keyboard.zig` - キー名・分類などの utility 関数
- `window.lockFramebuffer()` / `fb.unlock()` - フレームバッファアクセス
- `window.present()` - 画面更新

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

`platform.zig` の高レベル API ではイベントは tagged union として取得し、`switch` で網羅的に処理します。

```zig
const platform = @import("platform");

try platform.init();
defer platform.shutdown();

var window = try platform.Window.create(800, 600, "title");
defer window.destroy();

main_loop: while (window.pollEvents()) {
    while (window.nextEvent()) |ev| switch (ev) {
        .quit => break :main_loop,
        .key_down => |k| {
            // k.key, k.modifiers, k.is_repeat にアクセス可能
        },
        .key_up => {},
    };

    // 描画処理...
}
```

### 2. キーコードの判定（KeyCode enum）

`KeyCode` は `enum(c_int)` で強型化されており、`switch` で網羅的に扱えます。

```zig
const platform = @import("platform");
const KeyCode = platform.KeyCode;

// 単一キーの比較
if (k.key == .ESCAPE) return;

// switch での網羅
switch (k.key) {
    .UP    => move_up(),
    .DOWN  => move_down(),
    .LEFT  => move_left(),
    .RIGHT => move_right(),
    .SPACE => fire(),
    else   => {},
}

// 範囲判定（keyboard utility 経由）
const keyboard = @import("keyboard");
if (keyboard.isLetterKey(k.key)) {
    const offset = @intFromEnum(k.key) - @intFromEnum(KeyCode.A);
    // 0..25 の index として利用
}
```

### 3. モディファイアキーの処理（packed struct）

`ModifierFlags` は `packed struct(u32)` で、フィールドアクセスで読みやすく扱えます。

```zig
const mods = k.modifiers;

if (mods.shift) std.debug.print("Shift+", .{});
if (mods.ctrl)  std.debug.print("Ctrl+",  .{});
if (mods.alt)   std.debug.print("Alt+",   .{});
if (mods.cmd)   std.debug.print("Cmd+",   .{});
```

### 4. リピートイベントの検出

```zig
if (k.is_repeat) {
    std.debug.print(" [REPEAT]", .{});
}
```

### 5. keyboard.zig モジュールの活用

`keyboard` モジュールは `platform.KeyCode` を引数に取る utility を提供します。

```zig
const keyboard = @import("keyboard");

// キー名の取得
const key_name = keyboard.getKeyName(k.key);
std.debug.print("Key pressed: {s}\n", .{key_name});

// キー情報の取得
const info = keyboard.getKeyInfo(k.key);
std.debug.print("printable={any} modifier={any} function={any} numpad={any}\n", .{
    info.is_printable, info.is_modifier, info.is_function, info.is_numpad,
});

// A-Z / 0-9 を ASCII char に変換
if (keyboard.getCharFromKey(k.key)) |ch| {
    std.debug.print("char='{c}'\n", .{ch});
}
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
[KEY_DOWN] A (code=65)
[KEY_DOWN] SHIFT+B (code=66)
[KEY_DOWN] CTRL+ALT+C (code=67)
[KEY_DOWN] SPACE (code=32)
[KEY_DOWN] UP (code=265)
[KEY_DOWN] Q (code=81)
Quit key pressed
Application terminated.
```

## 実装の詳細

### HSV色空間

このサンプルでは、色の指定にHSV色空間（色相、彩度、明度）を使用しています：

- **H (Hue)**: 色相（0-360°）- 色の種類
- **S (Saturation)**: 彩度（0.0-1.0）- 色の鮮やかさ
- **V (Value)**: 明度（0.0-1.0）- 色の明るさ

HSVは直感的に色を操作できるため、インタラクティブなカラーパレットに適しています。

### フレームレート制御

現在の実装では `std.c.nanosleep(16_666_666ns)` (約60FPS) を使用していますが、本格的なアプリケーションではvsync同期やより高度なタイミング制御が推奨されます。

## 注意事項

- キーボードイベントはメインスレッドで処理されます
- リピートイベントは、キーを押し続けたときに複数回発生します
- モディファイアキーの組み合わせは、プラットフォームによって異なる場合があります
- `KeyCode` は non-exhaustive enum (`_` 末尾) なので、`switch` には常に `else` 句が必要です
