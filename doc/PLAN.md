# 実装計画 - video-proto プラットフォーム層

## アーキテクチャ設計

### 提案する3層構造

#### **レイヤー1: プリミティブAPI（platform.h）**
必要最小限の低レベル部品

```c
// ========== コアプリミティブ ==========

// ウィンドウ作成（最小限）
PlatformWindow* platform_create_window(int width, int height, const char* title);

// イベントポーリング（ノンブロッキング）
bool platform_poll_events(PlatformWindow* window);

// イベント取得（1つずつ）
bool platform_get_event(PlatformWindow* window, PlatformEvent* event);

// フレームバッファアクセス
uint32_t* platform_lock_framebuffer(PlatformWindow* window, int* width, int* height);
void platform_unlock_framebuffer(PlatformWindow* window);

// 画面更新（vsync制御可能）
void platform_present(PlatformWindow* window);  // vsync待ち
void platform_present_immediate(PlatformWindow* window);  // vsync待ちなし

// コールバック登録（オプション）
void platform_set_event_callback(PlatformWindow* window, EventCallback callback, void* userdata);
void platform_set_frame_callback(PlatformWindow* window, FrameCallback callback, void* userdata);

// 時刻取得（vsync精度）
double platform_get_time(void);

// ウィンドウ破棄
void platform_destroy_window(PlatformWindow* window);
```

**特徴**：
- ✅ 最小限のAPI、学習曲線が緩やか
- ✅ どんなアーキテクチャでも構築可能
- ✅ オーバーヘッドなし
- ✅ 各部品が独立して使える

---

#### **レイヤー2: ヘルパー関数群（platform_helpers.zig）**
よくあるパターンを関数化

```zig
// platform_helpers.zig

/// ダブルバッファリングヘルパー
pub const DoubleBuffer = struct {
    buffer_a: []u32,
    buffer_b: []u32,
    current: *[]u32,
    display: *[]u32,

    pub fn init(allocator: Allocator, size: usize) !DoubleBuffer { ... }
    pub fn swap(self: *DoubleBuffer) void { ... }
};

/// 固定タイムステップヘルパー
pub const FixedTimeStep = struct {
    accumulator: f64 = 0.0,
    dt: f64,

    pub fn update(self: *FixedTimeStep, frame_time: f64) usize {
        // 何回updateすべきか返す
        self.accumulator += frame_time;
        const steps = @as(usize, @intFromFloat(self.accumulator / self.dt));
        self.accumulator -= @as(f64, @floatFromInt(steps)) * self.dt;
        return steps;
    }
};

/// FPSカウンター
pub const FPSCounter = struct {
    frame_count: usize = 0,
    last_time: f64 = 0.0,
    current_fps: f64 = 0.0,

    pub fn update(self: *FPSCounter, current_time: f64) void { ... }
};

/// スナップショット作成ヘルパー（型安全）
pub fn Snapshot(comptime T: type) type {
    return struct {
        data: T,
        frame_number: u64,
        timestamp: f64,

        pub fn create(state: *const T, frame: u64, time: f64) @This() {
            return .{
                .data = state.*,  // コピー
                .frame_number = frame,
                .timestamp = time,
            };
        }
    };
}
```

**特徴**：
- ✅ オプション（使わなくてもOK）
- ✅ 型安全、Zigの利点を活用
- ✅ コピー&ペーストしてカスタマイズ可能

---

#### **レイヤー3: フレームワーク/テンプレート**

##### テンプレート1: シンプルアプリケーション
```zig
// templates/simple_app.zig

const SimpleApp = struct {
    window: *c.PlatformWindow,
    running: bool = true,

    pub fn init(width: i32, height: i32, title: [*:0]const u8) !SimpleApp {
        if (!c.platform_init()) return error.PlatformInitFailed;

        const window = c.platform_create_window(width, height, title)
            orelse return error.WindowCreationFailed;

        return .{ .window = window };
    }

    pub fn run(self: *SimpleApp, comptime UserApp: type, user_app: *UserApp) !void {
        while (self.running and c.platform_poll_events(self.window)) {
            // イベント処理
            var event: c.PlatformEvent = undefined;
            while (c.platform_get_event(self.window, &event)) {
                if (event.type == c.PLATFORM_EVENT_QUIT) {
                    self.running = false;
                }
                if (@hasDecl(UserApp, "onEvent")) {
                    user_app.onEvent(&event);
                }
            }

            // 描画
            var w: i32 = 0;
            var h: i32 = 0;
            const pixels = c.platform_lock_framebuffer(self.window, &w, &h);
            defer c.platform_unlock_framebuffer(self.window);

            if (@hasDecl(UserApp, "render")) {
                user_app.render(pixels[0..@intCast(w * h)], w, h);
            }

            c.platform_present(self.window);
        }
    }

    pub fn deinit(self: *SimpleApp) void {
        c.platform_destroy_window(self.window);
        c.platform_shutdown();
    }
};
```

---

### ディレクトリ構成の提案

```
video-proto/
├── platform/
│   ├── platform.h              # レイヤー1: プリミティブAPI
│   ├── macos-metal/
│   │   └── platform_macos_metal.swift
│   └── (将来: windows/, linux/, ...)
│
├── src/
│   ├── platform_helpers.zig    # レイヤー2: ヘルパー関数
│   └── main.zig
│
├── templates/                  # レイヤー3: フレームワーク
│   ├── simple_app.zig
│   ├── game_loop.zig
│   └── snapshot_renderer.zig
│
├── examples/                   # レイヤー4: サンプルコード
│   ├── 01_hello_window/
│   │   ├── main.zig
│   │   └── README.md
│   ├── 02_event_handling/
│   │   ├── main.zig
│   │   └── README.md
│   └── ...
│
└── docs/
    ├── API_REFERENCE.md        # プリミティブAPIリファレンス
    ├── PATTERNS.md             # デザインパターン解説
    └── TUTORIAL.md             # チュートリアル
```

---

## 実装計画の段階

### **フェーズ1: プリミティブAPIの完成**
1. `platform.h`にイベント処理APIを追加
2. macOS Metal版で実装
3. シンプルなテストプログラムで検証

### **フェーズ2: ヘルパー関数群**
4. `platform_helpers.zig`作成
5. よく使うパターンを関数化
6. 単体テスト作成

### **フェーズ3: テンプレートとサンプル**
7. 3つのテンプレート作成
8. 7つのサンプルプログラム作成
9. ドキュメント整備

### **フェーズ4: 検証と改善**
10. 実際に使ってフィードバック収集
11. APIの改善
12. 他のプラットフォーム対応（必要なら）

---

## サンプル実装: 01_timed_window

### サンプルの仕様

```zig
// examples/01_timed_window/main.zig

// 5秒間ウィンドウを表示
// 緑→黄→赤と色が変化
// 5秒後に自動終了
```

### 必要なAPI

- `platform_init()` ✅（既存）
- `platform_create_window()` ✅（既存）
- `platform_poll_events()` ⚠️（新規実装）
- `platform_get_time()` ⚠️（新規実装）
- `platform_lock_framebuffer()` ⚠️（新規実装）
- `platform_unlock_framebuffer()` ⚠️（新規実装）
- `platform_present()` ⚠️（新規実装）
- `platform_destroy_window()` ✅（既存）
- `platform_shutdown()` ✅（既存）

### 実装方針

**既存コードとの共存**：
```c
// 既存API（そのまま）
PlatformWindow* platform_create_window(...);

// 新規API（別の関数名）
PlatformWindow* platform_create_simple_window(int width, int height, const char* title);
uint32_t* platform_lock_framebuffer(...);
void platform_present(...);
```

- 既存コードに影響なし
- 段階的な移行が可能
- 後でAPIを統一できる

### 対象プラットフォーム

3つすべてのプラットフォーム実装：
1. **macos** (Objective-C + CALayer)
2. **macos-swift** (Swift + CADisplayLink)
3. **macos-metal** (Swift + Metal + MTKView)

---

## 実装完了の状態

---

## 設計の利点

### コンポーザビリティの実例

```zig
// 初心者: テンプレートを使う
var app = try SimpleApp.init(800, 600, "App");
try app.run(MyApp, &my_app);

// 中級者: ヘルパーを組み合わせる
const fps = helpers.FPSCounter{};
const double_buffer = try helpers.DoubleBuffer.init(allocator, 800 * 600);
while (platform_poll_events(window)) {
    // 自分でループを書く
}

// 上級者: プリミティブのみ使う
while (platform_poll_events(window)) {
    const pixels = platform_lock_framebuffer(window, &w, &h);
    // 完全にカスタムな実装
    platform_unlock_framebuffer(window);
    platform_present(window);
}
```

### 重要な原則

- **学習曲線のグラデーション**: 初心者は`SimpleApp`テンプレートから、上級者は直接プリミティブAPIを使える
- **Unix哲学との親和性**: 小さな部品（`platform_poll_events`、`platform_present`など）を組み合わせて複雑な機能を作る
- **段階的な複雑性**: 必要に応じて下のレイヤーに降りられる。テンプレートのコードをコピーしてカスタマイズも可能

---

## 設計思想と判断基準

このセクションは、やりとりから明示的・暗黙的に読み取れる設計の方針や考え方をまとめたものです。

### 核となる設計原則

#### 1. **シンプルさを最優先**
- **スレッドセーフティ**: 「一番シンプルに解決したい」という明確な要求
  - 解決策: すべてのコールバックをメインスレッドで実行（ロック不要）
  - 参考: GLFW、Unity、多くのゲームエンジンと同じアプローチ
- **コールバック設計**: 「一つにできるならしてシンプルにしたほうがよい」
  - 解決策: 単一のEventCallbackで統一（複数のコールバック関数ではなく）
- **API設計**: 最小限の部品を組み合わせる（Unix哲学）

#### 2. **プラットフォームの自然さへの配慮**
- 「プラットフォームによっては不自然かもしれない」という懸念
  - 検証結果: すべてのプラットフォーム（macOS、Windows、Linux）でメインスレッド実行は自然
  - 業界標準（GLFW、SDL）との比較を重視

#### 3. **後方互換性と段階的な移行**
- **既存コードを壊さない**: 「既存コードはそのままで、新しいAPIを追加」
- **段階的な移行**: 失敗してもロールバック可能
- **検証してから統一**: 新しいAPIを検証してから既存APIと統合

---

### 想定用途と要件

#### 対象アプリケーション
- **インタラクティブなアプリ** と **ゲーム** の両方を想定
- どちらの場合でも **イベント処理は必要**
- コールバック方式とポーリング方式、**どちらも考えている**

#### レンダリング方式
- **現状**: ソフトウェアレンダリング（CPUでピクセル描画）
- **将来**: GPU最適化の可能性あり
  - 「GPU最適化の方向性になったら、ピクセルバッファ方式ではなくなりそう」
  - スナップショット方式の検討（レンダリングとロジックの分離）

---

### 技術的な判断基準

#### スレッドセーフティ
- **メインスレッド保証**: すべてのコールバックをメインスレッドで実行
  - メリット: ロック不要、ユーザーはスレッドセーフティを意識しなくてよい
  - すべてのプラットフォームで一貫した動作

#### 業界標準との整合性
- **GLFW**: すべてのコールバックは`glfwPollEvents()`内でメインスレッド実行
- **Unity**: すべてのAPI呼び出しをメインスレッドに制限
- **SDL3**: ポーリング専用の設計（最新トレンド）

#### クロスプラットフォーム対応
| プラットフォーム | メインスレッド要求 | 提案設計との相性 |
|----------------|------------------|----------------|
| macOS (Cocoa) | 必須 | ✅ 自然 |
| Windows (Win32) | ウィンドウ作成スレッド | ✅ メインで作成すればOK |
| Linux (X11) | 任意のスレッド | ✅ メインでも問題なし |
| Linux (Wayland) | メインスレッド推奨 | ✅ 自然 |

---

### 開発アプローチ

#### インクリメンタルな開発
- **方針**: 「サンプル一つずつ作って、必要最低限のplatform側の実装を作って、動作を確認しながら進める」
- **メリット**:
  - 早期にフィードバックを得られる
  - 問題点の早期発見（Objective-Cのprivateメンバーアクセス、Zigの`sleep` API変更など）
  - 失敗してもリスクが小さい

#### サンプル駆動開発
1. 最小限のサンプル（01_timed_window）
   - 時間制限自動終了
   - 時間経過で色が変わる
   - イベント処理不要（次のサンプルで実装）
2. 次のサンプル（02_keyboard_input）
   - キーボード入力の実装
3. 段階的に機能追加

---

### 決定保留事項とその理由

これらの項目は、実際の使用例やレンダリング方式が確定するまで決定を保留しています。

#### 1. **vsync同期の要否**
- **理由**: 「ビットマップへのレンダリング処理がどのようなものかを全く想定できていない」
- **選択肢**:
  - vsync自動同期（60FPS固定） - ゲーム、アニメーション向き
  - 手動描画（ユーザー制御） - 変更時のみ描画、省電力
  - ハイブリッド（イベント駆動 + vsync） - 両方の利点

#### 2. **描画タイミングの制御**
- **理由**: 用途が確定していない（ゲーム vs ツール）
- **選択肢**:
  - 常に60FPS描画 - ゲーム、アニメーション
  - 変更時のみ描画 - エディタ、ツール（`platform_request_redraw()`が便利）

#### 3. **レンダリングとロジックの分離度合い**
- **将来の検討事項**: スナップショット方式の採用
  - メリット: レンダリングとゲームロジックの並列実行
  - デメリット: レイテンシ増加、メモリ使用量増加、デバッグの困難さ
- **理由**: 実用上の必要性が不明（パフォーマンスが問題になってから検討）
- **段階的アプローチ**:
  1. シンプル実装（即座レンダリング、すべてメインスレッド）
  2. 部分的分離（重要な判定は即座、描画は分離）
  3. 完全分離（必要な場合のみ）

#### 4. **GPU API（OpenGL/Metal/Vulkan）の直接サポート**
- **理由**: 「まだ決まっていない」（柔軟に対応したい）
- **選択肢**:
  - ピクセルバッファのみ（学習・実験用）
  - GPU API追加（本格的なゲームエンジン）
  - 両方サポート（汎用プラットフォーム層）
- **推奨**: フェーズ1でピクセルバッファ完成、フェーズ2でGPU拡張（必要になったら）

---

### 設計の落とし所

#### コンポーザビリティ重視の階層化
> 「どの場合でも組み合わせて使うことになるシンプルな部品と、典型的な使い方をパッケージングしたフレームワーク、もしくはテンプレートやサンプルコードというのがいい落とし所」

この哲学に基づいて、以下の3層構造を採用：

1. **プリミティブAPI**: 最小限の部品（`platform_poll_events`、`platform_present`など）
2. **ヘルパー関数**: よくあるパターン（`FixedTimeStep`、`FPSCounter`など）
3. **フレームワーク/テンプレート**: 典型的な使い方（`SimpleApp`、`GameLoop`など）

**利点**:
- 初心者から上級者まで対応
- Unix哲学（小さな部品を組み合わせる）との親和性
- 必要に応じて下のレイヤーに降りられる

---

### 将来の拡張性についての考え

#### GPU最適化への移行
- **認識**: 「たぶんGPU最適化の方向性になったら、ピクセルバッファ方式ではなくなりそう」
- **準備**: レンダーコンテキストの抽象化
  - ソフトウェアレンダリングモード: `SoftwareRenderContext`
  - Metalモード: `MetalRenderContext`
  - OpenGLモード: `OpenGLRenderContext`
- **切り替えの柔軟性**: スナップショット方式の検討

#### スナップショットベースアーキテクチャ
- **目的**: 将来のGPU最適化に備えた設計
- **3層アーキテクチャ**:
  1. ゲームロジック（メインスレッド） - 可変状態
  2. レンダースナップショット（不変、スレッド間通信）
  3. レンダリング（レンダースレッド） - スナップショットのみ使用
- **デメリットも理解済み**:
  - レイテンシ（1-3フレーム遅延）
  - メモリ使用量増加（2倍程度）
  - デバッグの困難さ
- **実用的な折衷案**: ハイブリッドアプローチ
  - 重要な情報は同期的に取得（例: マウスピッキング）
  - 最適化用の情報は非同期でOK（例: オクルージョンクエリ）

---

### まとめ: 設計の指針

1. **シンプルさ優先** - ロック不要、学習曲線が緩やか
2. **業界標準に準拠** - GLFW、SDLの実証済みパターン
3. **段階的な実装** - 最小限から始めて、必要に応じて拡張
4. **柔軟性の確保** - 将来のGPU最適化やスナップショット方式に対応可能
5. **後方互換性** - 既存コードを壊さない
6. **クロスプラットフォーム** - すべてのプラットフォームで一貫した動作

**重要な原則**: 「決めきれない」ことは**決定を保留**し、実際の使用例から学ぶ。
