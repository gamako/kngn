# Example 02: Keyboard Input - 実装方針書

## 概要

02_keyboard_inputサンプルは、キーボード入力処理を実装する最初のインタラクティブなサンプルです。このドキュメントは、イベント処理システムの設計決定とその理由を記録します。

## サンプルの内容

### 「インタラクティブ・カラーパレット」

全画面の背景色をキーボード入力でリアルタイムに変更するサンプルです。

**機能:**
- **A-Z キー**: 26色の異なる色に即座に切り替え（HSV色空間で均等分配）
- **0-9 キー**: 10段階のグレースケール
- **矢印キー**: 現在の色を微調整（↑↓:明度、←→:色相）
- **Space キー**: ランダムカラー
- **R キー**: デフォルト色にリセット
- **ESC/Q キー**: プログラム終了

**技術的なデモンストレーション:**
- イベント取得: `platform_get_event()`の使用
- キーコード判定: 仮想キーコードの活用
- キーリピート: `is_repeat`フラグの処理
- モディファイアキー: Shift押下で彩度変更（オプション）

## 背景と課題

### 現状
- `platform_poll_events()`は実装済みだが、イベント取得のみ
- `platform_get_event()`およびPlatformEvent型は未定義
- イベント処理をどこで行うかが設計上の重要な判断点

### 検討した課題
1. **イベント変換の実装場所**
   - Platform層（C/Swift）で変換 vs Zig層で変換
2. **プラットフォームサポート範囲**
   - Linux/X11のサポート可否
3. **キーリピート処理**
   - プラットフォーム間での一貫性

## 重要な設計決定

### 1. イベント変換はPlatform層で実施

**決定内容：**
各プラットフォーム実装（Objective-C/Swift）内でネイティブイベントをPlatformEvent構造体に変換し、統一されたC APIとして提供する。

**理由：**
- **FFI境界のシンプル化**: 明確に定義された構造体でやり取りするため、デバッグが容易
- **プラットフォーム固有の最適化**: 各実装で最適な方法を選択可能
- **将来の複雑な機能への対応**: IMEなどの高度な機能は結局Platform層が厚くなる

**却下した代替案：**
Zig層で変換する案も検討したが、以下の問題があった：
- FFI境界が複雑化（生データの受け渡し）
- プラットフォーム数が限定的（macOS、将来Windows）なので共通化のメリットが薄い
- デバッグ時に両側のコードを確認する必要がある

### 2. Linux/X11は当面サポートしない

**決定内容：**
初期実装ではmacOSのみ、将来的にWindowsとLinux/Waylandを優先し、X11は需要があれば検討。

**理由：**
- **実装の複雑性**: X11はキーリピート検出APIが存在せず、回避策が必要
- **将来性**: Waylandが主流になりつつある
- **メンテナンスコスト**: 限られたリソースで品質を保つため

**影響：**
API設計ではキーリピート検出を「保証される機能」として扱える。

### 3. キーリピートはフラグで提供

**決定内容：**
```c
typedef struct {
    PlatformKeyCode key;
    bool is_repeat;  // キーリピートかどうか
    uint32_t modifiers;
} keyboard;
```

**理由：**
- **情報を失わない**: ユーザーが用途に応じて判断可能
- **実装がシンプル**: 特別なイベントタイプを増やさない
- **拡張性**: 将来的にテキスト入力にも対応しやすい

**サンプルでの活用:**
- 色変更キーはリピートを受け入れ（連続的な色変化）
- 終了キーはリピートを無視（誤操作防止）

## アーキテクチャ設計

### イベントフロー
```
ユーザー入力
    ↓
OS (NSEvent/MSG)
    ↓
Platform層 [変換・キュー管理]
    ↓
PlatformEvent (統一構造体)
    ↓
Zigアプリケーション
```

### 責任の分離
- **Platform層の責任**:
  - ネイティブイベントの取得
  - 仮想キーコードへの変換
  - イベントキューの管理（リングバッファ）
  - モディファイアキーの状態管理

- **Zig層の責任**:
  - イベントの解釈とゲームロジック
  - 複数キーの組み合わせ判定
  - アプリケーション固有の処理（色計算など）

## 実装方針

### 段階的実装アプローチ

#### Phase 1: 最小限の実装（02_keyboard_input）
- 基本的なキー（A-Z、0-9、矢印、Space、ESC、Enter）
- KEY_DOWN、KEY_UP、QUITイベントのみ
- is_repeatフラグ付き

#### Phase 2: 拡張（必要に応じて）
- ファンクションキー
- テキスト入力イベント
- マウスイベント（03_mouse_input）

### イベントキューの設計
- **固定サイズリングバッファ**: 256要素（約6KB）
- **オーバーフロー時**: 最古のイベントを上書き
- **理由**: 動的メモリ管理を避け、予測可能な動作を保証

### キーコードマッピング
- **仮想キーコード方式**: GLFWと互換性のある設計
- **プラットフォーム固有コードから変換**: switch文による高速変換
- **未知のキー**: PLATFORM_KEY_UNKNOWNを返す

## API設計の詳細

### PlatformEvent構造体
```c
// platform.h への追加

// イベントタイプ
typedef enum {
    PLATFORM_EVENT_NONE = 0,
    PLATFORM_EVENT_QUIT,
    PLATFORM_EVENT_KEY_DOWN,
    PLATFORM_EVENT_KEY_UP,
} PlatformEventType;

// キーコード（GLFWと互換）
typedef enum {
    PLATFORM_KEY_UNKNOWN = -1,

    // 印字可能文字（ASCII互換）
    PLATFORM_KEY_SPACE = 32,
    PLATFORM_KEY_0 = 48,
    PLATFORM_KEY_1 = 49,
    // ... 2-8 ...
    PLATFORM_KEY_9 = 57,
    PLATFORM_KEY_A = 65,
    PLATFORM_KEY_B = 66,
    // ... C-Y ...
    PLATFORM_KEY_Z = 90,

    // 特殊キー
    PLATFORM_KEY_ESCAPE = 256,
    PLATFORM_KEY_ENTER = 257,
    PLATFORM_KEY_LEFT = 263,
    PLATFORM_KEY_RIGHT = 264,
    PLATFORM_KEY_UP = 265,
    PLATFORM_KEY_DOWN = 266,
} PlatformKeyCode;

// モディファイアキー
typedef enum {
    PLATFORM_MOD_SHIFT = 0x01,
    PLATFORM_MOD_CTRL = 0x02,
    PLATFORM_MOD_ALT = 0x04,
    PLATFORM_MOD_CMD = 0x08,  // macOS Command, Windows Super
} PlatformModifierFlags;

// イベント構造体
typedef struct PlatformEvent {
    PlatformEventType type;

    union {
        struct {
            PlatformKeyCode key;
            bool is_repeat;
            uint32_t modifiers;
        } keyboard;
        // 将来的にマウス、タッチなど追加
    };
} PlatformEvent;

// イベント取得API
bool platform_get_event(PlatformWindow* window, PlatformEvent* event);
```

## 将来の拡張性

### 考慮している拡張
1. **テキスト入力**: PLATFORM_EVENT_TEXT_INPUTイベント追加で対応
2. **Windows対応**: 同じAPIで実装可能（lParamでリピート判定）
3. **Linux/Wayland**: 専用コールバックでクリーンに実装

### 複雑な機能への対応戦略
- **IME（日本語入力）**: Platform層で処理（OS APIとの密結合が必要）
- **ジェスチャー認識**: 基本イベントはPlatform層、認識ロジックはZig層
- **原則**: 必要になったときに実装する（YAGNI原則）

## 設計原則との整合性

このイベント処理設計は、プロジェクトの設計原則と整合しています：

1. **シンプルさ優先**: FFI境界が明確で理解しやすい
2. **Unix哲学**: `platform_poll_events()`と`platform_get_event()`を分離
3. **段階的な実装**: 最小限から始めて必要に応じて拡張
4. **後方互換性**: 既存APIを壊さない

## 検証方法

実装完了後、以下を確認：

### 機能テスト
- 3つのmacOS実装（ObjC/Swift/Metal）で動作
- すべてのキーが正しい色にマッピングされる
- 矢印キーによる色調整が機能する
- キーリピートが正しく検出される

### 非機能テスト
- イベントの取りこぼしがない
- メモリリークがない
- CPU使用率が適切（アイドル時は低い）

## 実装者へのメモ

このサンプルは以下を実証することを目的としています：
1. **イベント駆動アーキテクチャ**: ポーリングではなくイベントベース
2. **キーリピート処理**: 用途に応じた使い分け
3. **視覚的フィードバック**: 即座に反応する直感的なUI

シンプルさを保ちながら、イベント処理の基礎をすべてカバーすることを心がけてください。