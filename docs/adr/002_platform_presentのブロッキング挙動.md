# ADR-002: platform_present()のブロッキング挙動の設計決定

**Status:** 承認・実装完了
**Date:** 2025-10-25
**Category:** レンダリング・フレームレート制御

## 概要

video-protoプロジェクトの`platform_present()` APIのブロッキング挙動について決定した。

**決定内容：**
`platform_present()`は即座にリターンする（ブロッキングしない）設計を正式採用する。レンダリングシステム（WindowServer/GPU）が内部的にVBLANKで画面をスワップし、ゲームループのレート制御は呼び出し側の責任とする。

## 背景

### 当初の問題

プロジェクトの初期段階で、`platform.h`に以下のように記載されていた：

```c
// 画面を更新（vsync同期）
// platform_lock_framebuffer()で書き込んだ内容を画面に表示
// この関数はvsyncで待機する
void platform_present(PlatformWindow* window);
```

しかし、実装を確認したところ、すべてのプラットフォーム（macOS CALayer、Metal、Swift）で`platform_present()`は即座にリターンしており、ドキュメントと実装が不一致だった。

### 混同されていた概念

議論の中で、以下の2つの異なる概念が「vsync」という言葉で混同されていたことが判明した：

1. **VBLANK同期（ティアリング対策）**
   - ディスプレイの垂直帰線期間に画面スワップを行う
   - レンダリングシステム（WindowServer/GPU）が自動的に処理
   - ティアリング（画面分割）を防止

2. **ゲームループのレート制御**
   - `while(running)`ループが1秒間に何回実行されるか
   - CPU側で明示的に制御する必要がある
   - `sleep()`などで実装

### 議論のきっかけ

ユーザーから以下の重要な質問があった：

> 「vsyncを待つというのは、どういう動作を期待されるのか？」
> 「シングルスレッドの場合は自動では待ちたくないのでは？」

この質問により、設計意図を明確化する必要性が浮き彫りになった。

## 比較検討

### 選択肢1: ブロッキング（vsyncまで待機）

```zig
platform_present(window);  // ← 次のVBLANKまで待機してリターン
// 自動的に60fps（ディスプレイのリフレッシュレート）
```

**メリット**:
- ✅ フレームレート制御が自動
- ✅ 正確にディスプレイのリフレッシュレートに同期
- ✅ `sleep()`不要

**デメリット**:
- ❌ クロスプラットフォーム実装が困難（特にソフトウェアレンダリング）
- ❌ シングルスレッド設計では待機中に何もできない
- ❌ 可変フレームレート不可
- ❌ ユーザーの柔軟性を奪う

### 選択肢2: ノンブロッキング（即座にリターン）✅ **採用**

```zig
platform_present(window);  // ← すぐリターン
std.Thread.sleep(16_666_666);  // ← 手動でフレームレート制御
```

**メリット**:
- ✅ クロスプラットフォーム実装が容易
- ✅ ユーザーが柔軟にフレームレート制御できる
- ✅ シングルスレッド設計と整合
- ✅ シンプルで予測可能

**デメリット**:
- ⚠️ ユーザーが明示的にフレームレート制御する必要がある
- ⚠️ 初心者には少し複雑

### シングルスレッド vs マルチスレッド

| 実行モデル | ブロッキング挙動 | 適合性 |
|-----------|----------------|--------|
| **マルチスレッド**（レンダリング専用スレッド） | 待機してもOK | ✅ 待機中にメインスレッドが次フレーム計算 |
| **シングルスレッド**（一般的なゲームループ） | 待機すると問題 | ❌ 待機中に何もできない |

video-protoはシングルスレッド設計を前提としているため、ノンブロッキングが適切。

### クロスプラットフォーム実装可能性

#### ソフトウェアレンダリング（現在の設計）でのvsync待機

| プラットフォーム | 実装方法 | 難易度 | 備考 |
|--------------|---------|--------|------|
| **Windows** | `DwmFlush()` | 🟡 中 | Desktop Window Managerを使えば可能だが特殊 |
| **Linux X11** | XSync + 手動タイマー | 🔴 困難 | ソフトウェアレンダリングではvsync情報取得困難 |
| **Linux Wayland** | `wl_surface_frame()` | 🟢 可能 | frameコールバックでvsync同期可能 |
| **macOS** | `CVDisplayLink` | 🟡 中 | **別スレッド**でのコールバック、シングルスレッド設計と矛盾 |

#### GPU API（将来の拡張）でのvsync待機

| API | vsync待機 | 難易度 |
|-----|----------|--------|
| **DirectX** | `Present(1, 0)` | 🟢 簡単 |
| **OpenGL** | `glSwapBuffers()` | 🟢 簡単 |
| **Metal** | `present()` + `waitUntilCompleted()` | 🟡 中 |
| **Vulkan** | `VK_PRESENT_MODE_FIFO_KHR` | 🟢 簡単 |

**結論**: ソフトウェアレンダリングでは多くのプラットフォームでvsync待機が困難または不自然。ノンブロッキング設計が現実的。

## 決定理由

以下の理由から、ノンブロッキング設計を正式採用した：

1. **クロスプラットフォームでの実装の容易さ**
   - すべてのプラットフォームで一貫した実装が可能
   - ソフトウェアレンダリングでも実装可能

2. **ユーザーの柔軟性**
   - 60fps固定、可変フレームレート、無制限fpsなど自由に選択可能
   - ゲーム、ツール、アニメーションなど用途に応じた制御が可能

3. **シングルスレッド設計との整合性**
   - シングルスレッドのゲームループで自然な実装
   - 待機中に他の処理ができる

4. **既存実装との整合性**
   - すべてのプラットフォーム実装が既にノンブロッキング
   - ドキュメント修正のみで対応可能

5. **DRY原則（Don't Repeat Yourself）**
   - API仕様を`platform.h`に一元化
   - 実装ファイルでの重複コメントを削除

## 決定による影響

### ティアリング対策

**結論**: ティアリングは発生しない

**理由**:
- レンダリングシステム（WindowServer/GPU）が内部的に次のVBLANKで画面をスワップ
- 書き込みバッファと表示バッファを分離（ダブルバッファリングまたはマルチバッファリング）
- いつ`platform_present()`を呼び出しても安全

**プラットフォームごとの実装**:

| プラットフォーム | 仕組み | ティアリング |
|--------------|--------|------------|
| **macOS CALayer** | WindowServerがVBLANKでスワップ | ❌ なし |
| **macOS Metal** | GPUドライバがVBLANKでスワップ | ❌ なし |
| **DirectX (参考)** | FIFOモード（デフォルト） | ❌ なし |

### ゲームループのレート制御

**責任**: 呼び出し側

**実装方法**:

```zig
// 基本的な制御（固定sleep）
while (running) {
    update();
    render();
    platform_present();
    std.Thread.sleep(16_666_666); // 16.67ms = 60fps
}
```

```zig
// 推奨される制御（デルタタイム）
const target_frame_time = 1.0 / 60.0; // 60fps

while (running) {
    const frame_start = platform_get_time();

    update();
    render();
    platform_present();

    const elapsed = platform_get_time() - frame_start;
    const sleep_time = target_frame_time - elapsed;

    if (sleep_time > 0) {
        std.Thread.sleep(@intFromFloat(sleep_time * 1e9));
    }
}
```

### 将来の拡張可能性

ノンブロッキング設計を基本としつつ、将来的に以下の拡張が可能：

1. **`platform_present_sync()`の追加**
   ```c
   // ブロッキング版（将来追加するなら）
   void platform_present_sync(PlatformWindow* window);
   ```

2. **vsync制御フラグ**
   ```c
   void platform_set_vsync(PlatformWindow* window, bool enable);
   ```

3. **ヘルパー関数の提供**
   ```zig
   // platform_helpers.zig
   pub const FrameRateLimiter = struct {
       target_fps: f64,
       last_frame_time: f64,

       pub fn waitForNextFrame(self: *FrameRateLimiter) void {
           // フレームレート制御の実装
       }
   };
   ```

## 実装詳細

### platform.h のAPI仕様

```c
// 画面を更新
// platform_lock_framebuffer()で書き込んだ内容を画面に表示
//
// 動作:
// - この関数は即座にリターンする（ブロッキングしない）
// - レンダリングシステム（WindowServer/GPU）が内部的に次のVBLANKで画面をスワップする
// - 書き込みバッファと表示バッファを分離しているため、いつ呼び出してもティアリングは発生しない
//
// 注意:
// - ゲームループのレート制御（何回呼ぶか）は呼び出し側の責任
// - フレームレート制限が必要な場合、platform_get_time()とsleep()を使用すること
void platform_present(PlatformWindow* window);
```

### プラットフォーム実装

#### macOS CALayer (Objective-C)

```objc
void platform_present(PlatformWindow* platformWindow) {
    if (!platformWindow) return;
    @autoreleasepool {
        FramebufferView* view = platformWindow->view;
        [view presentManual];  // 即座にリターン
    }
}
```

`presentManual`の内部：
```objc
- (void)presentManual {
    // バッファスワップ
    uint32_t* temp = currentBuffer;
    currentBuffer = displayBuffer;
    displayBuffer = temp;

    // CALayerに設定（即座にリターン）
    CGImageRef image = CGImageCreate(...);
    contentLayer.contents = (__bridge id)image;
    CGImageRelease(image);

    // WindowServerが次のVBLANKでスワップ（非同期）
}
```

#### macOS Metal (Swift)

```swift
func platform_present(platformWindow: UnsafeMutableRawPointer?) {
    guard let platformWindow = platformWindow else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    guard let renderer = handle.metalView.getRenderer() else { return }
    renderer.presentManual(view: handle.metalView)  // 即座にリターン
}
```

`presentManual`の内部：
```swift
func presentManual(view: MTKView) {
    // バッファスワップ
    let temp = currentBuffer
    currentBuffer = displayBuffer
    displayBuffer = temp

    // Metalコマンド送信（即座にリターン）
    commandBuffer.present(drawable)
    commandBuffer.commit()

    // GPUが次のVBLANKでスワップ（非同期）
}
```

## 用語の整理

今回の議論で明確になった用語の定義：

| 用語 | 意味 | 誰が制御するか |
|------|------|--------------|
| **リフレッシュレート** | ディスプレイの更新周波数（通常60Hz、固定） | ハードウェア |
| **VBLANK同期** | 画面スワップをVBLANK期間に行うこと（ティアリング対策） | WindowServer/GPU（自動） |
| **ゲームループのレート** | `while(running)`が1秒間に何回実行されるか | ユーザーコード（手動） |
| **フレームレート制御** | ゲームループの実行回数を制限すること | ユーザーコード（sleep等） |

**重要な認識**:
- 「vsync」という用語は曖昧で、ティアリング対策とフレームレート制御の両方を指す可能性がある
- 本プロジェクトでは明確に分離：
  - **VBLANK同期**: レンダリングシステムが自動処理（ティアリング防止）
  - **ゲームループのレート制御**: ユーザーの責任（sleep等で実装）

## 関連する設計原則

### DRY原則の適用

**決定前**: 各プラットフォーム実装にAPI仕様を重複して記載

**決定後**: `platform.h`に一元化

| ファイル | 役割 |
|---------|------|
| `platform/platform.h` | API仕様（何をするか、どう使うか） |
| `platform/*/platform_*.m/swift` | 実装詳細（どう実装しているか） |

**効果**:
- ドキュメント更新が1箇所で済む
- 保守性向上
- 3つの実装で一貫性

### 責任の分離

```
┌─────────────────────────────────┐
│  ユーザーコード                   │
│  - ゲームロジック                 │
│  - フレームレート制御（sleep）    │ ← ユーザーの責任
└─────────────────────────────────┘
           ↓ platform_present()
┌─────────────────────────────────┐
│  platform API                   │
│  - バッファスワップ               │
│  - レンダリングシステムへ送信      │ ← platform層の責任
└─────────────────────────────────┘
           ↓ 非同期
┌─────────────────────────────────┐
│  WindowServer / GPU             │
│  - VBLANK待機                   │
│  - 画面スワップ                   │ ← システムの責任
└─────────────────────────────────┘
```

## 変更履歴

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-10-25 | 初版記録、ドキュメント修正完了 |

### 修正されたファイル

1. **platform/platform.h** (+9行, -3行)
   - API仕様コメントを詳細化
   - ブロッキングしない挙動を明記
   - ゲームループのレート制御について説明追加

2. **examples/01_timed_window/main.zig** (+2行, -2行)
   - 「フレームレート制御」→「ゲームループのレート制御」に用語修正
   - コメントを明確化

3. **platform/macos/platform_macos.m** (-4行)
   - 重複コメントを削除（DRY原則）

4. **docs/PLAN.md** (+12行, -5行)
   - vsync同期の設計決定を記録
   - 「決定保留」→「設計決定✅」に変更

### コミット情報

```
Commit: f9343e8a
Type: docs
Message: platform_present()のAPI仕様を明確化
```

## 関連リソース

- `platform/platform.h` - API仕様
- `platform/macos/platform_macos.m` - macOS Objective-C実装
- `platform/macos-swift/platform_macos.swift` - macOS Swift実装
- `platform/macos-metal/platform_macos_metal.swift` - macOS Metal実装
- `examples/01_timed_window/main.zig` - サンプル実装（フレームレート制御の例）
- `docs/PLAN.md` - プロジェクト計画、設計決定の記録
- `docs/adr/001_モノトニック時計の選択.md` - 関連するタイマーAPIの設計決定

## 参考情報

### 業界標準との整合性

| ライブラリ/エンジン | `present()`の挙動 | 備考 |
|------------------|-----------------|------|
| **GLFW** | ノンブロッキング | `glfwSwapBuffers()`は即座にリターン、vsyncはドライバ設定 |
| **SDL3** | ノンブロッキング | 最新トレンドはポーリング専用設計 |
| **Unity** | メインスレッド制限 | すべてのAPI呼び出しをメインスレッドに制限 |

video-protoの設計は業界標準と整合している。
