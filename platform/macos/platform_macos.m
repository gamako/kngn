#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include "platform.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

// CALayer最適化版の実装
#define IMPLEMENTATION_TYPE "CALayer Optimized"

// 前方宣言
@class FramebufferView;

// ========================================
// CALayer最適化版の実装
// ========================================

// カスタムNSView - CALayerベースの高速描画
@interface FramebufferView : NSView {
    int width;
    int height;
    CADisplayLink* displayLink;
    FrameCallback callback;
    void* userdata;

    // ダブルバッファリング（ポインタスワップ方式）
    uint32_t* buffer0;
    uint32_t* buffer1;
    uint32_t* currentBuffer;  // コールバックが書き込むバッファ
    uint32_t* displayBuffer;  // 画面に表示中のバッファ

    // レイヤー
    CALayer* contentLayer;

    // CGオブジェクト（初期化時に作成して再利用）
    CGColorSpaceRef colorSpace;
    CGDataProviderRef provider0;
    CGDataProviderRef provider1;

    // パフォーマンス測定
    CFAbsoluteTime lastFrameTime;
    int frameCount;
    double totalFrameTime;
}
- (id)initWithFrame:(NSRect)frame width:(int)w height:(int)h
           callback:(FrameCallback)cb userdata:(void*)ud;
- (void)startDisplayLink;
- (void)stopDisplayLink;
- (void)displayLinkFired:(CADisplayLink*)link;
- (void)dealloc;

// 手動描画用のアクセサメソッド
- (int)getWidth;
- (int)getHeight;
- (uint32_t*)getCurrentBuffer;
- (void)presentManual;

@end

@implementation FramebufferView

- (id)initWithFrame:(NSRect)frame width:(int)w height:(int)h
           callback:(FrameCallback)cb userdata:(void*)ud {
    self = [super initWithFrame:frame];
    if (self) {
        width = w;
        height = h;
        callback = cb;
        userdata = ud;

        // ダブルバッファを確保（ページアラインメント推奨）
        buffer0 = (uint32_t*)calloc(width * height, sizeof(uint32_t));
        buffer1 = (uint32_t*)calloc(width * height, sizeof(uint32_t));
        currentBuffer = buffer0;
        displayBuffer = buffer1;

        // CGオブジェクトを初期化時に作成（再利用するため）
        colorSpace = CGColorSpaceCreateDeviceRGB();

        // buffer0用のCGDataProviderを作成
        provider0 = CGDataProviderCreateWithData(
            NULL,
            buffer0,
            width * height * sizeof(uint32_t),
            NULL
        );

        // buffer1用のCGDataProviderを作成
        provider1 = CGDataProviderCreateWithData(
            NULL,
            buffer1,
            width * height * sizeof(uint32_t),
            NULL
        );

        // レイヤーバックドビューに設定
        [self setWantsLayer:YES];

        // コンテンツレイヤーを作成
        contentLayer = [CALayer layer];
        contentLayer.frame = CGRectMake(0, 0, width, height);
        contentLayer.opaque = YES;
        contentLayer.geometryFlipped = YES;  // Y軸反転を一度だけ設定
        [self.layer addSublayer:contentLayer];

        // パフォーマンス測定の初期化
        lastFrameTime = CFAbsoluteTimeGetCurrent();
        frameCount = 0;
        totalFrameTime = 0.0;

        NSLog(@"[%s] Framebuffer initialized: %dx%d", IMPLEMENTATION_TYPE, width, height);
    }
    return self;
}

- (void)startDisplayLink {
    if (@available(macOS 12.0, *)) {
        displayLink = [self displayLinkWithTarget:self selector:@selector(displayLinkFired:)];
        [displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
}

- (void)stopDisplayLink {
    if (displayLink) {
        [displayLink invalidate];
        displayLink = nil;
    }
}

- (void)displayLinkFired:(CADisplayLink*)link {
    (void)link;

    CFAbsoluteTime frameStartTime = CFAbsoluteTimeGetCurrent();

    // ユーザーのコールバックを呼び出してピクセルデータを生成
    if (callback) {
        CFAbsoluteTime callbackStart = CFAbsoluteTimeGetCurrent();
        callback(currentBuffer, width, height, userdata);
        CFAbsoluteTime callbackEnd = CFAbsoluteTimeGetCurrent();

        // バッファをスワップ（ゼロコピー）
        uint32_t* temp = currentBuffer;
        currentBuffer = displayBuffer;
        displayBuffer = temp;

        // 表示するバッファに対応するCGDataProviderを選択
        CFAbsoluteTime renderStart = CFAbsoluteTimeGetCurrent();
        CGDataProviderRef provider = (displayBuffer == buffer0) ? provider0 : provider1;

        // CGImageを作成（毎フレーム必要）
        CGImageRef image = CGImageCreate(
            width,
            height,
            8,
            32,
            width * 4,
            colorSpace,
            kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big,
            provider,
            NULL,
            false,
            kCGRenderingIntentDefault
        );

        // レイヤーのcontentsに設定（変換なしで高速）
        contentLayer.contents = (__bridge id)image;

        // CGImageを解放
        CGImageRelease(image);

        CFAbsoluteTime renderEnd = CFAbsoluteTimeGetCurrent();

        // パフォーマンス測定
        frameCount++;
        double frameTime = frameStartTime - lastFrameTime;
        totalFrameTime += frameTime;
        lastFrameTime = frameStartTime;

        // 60フレームごとに統計を出力
        if (frameCount % 60 == 0) {
            double avgFrameTime = totalFrameTime / 60.0;
            double fps = 1.0 / avgFrameTime;
            double callbackTime = (callbackEnd - callbackStart) * 1000.0;
            double renderTime = (renderEnd - renderStart) * 1000.0;

            NSLog(@"[%s] FPS: %.1f | Avg Frame: %.2fms | Callback: %.2fms | Render: %.2fms",
                  IMPLEMENTATION_TYPE, fps, avgFrameTime * 1000.0, callbackTime, renderTime);

            totalFrameTime = 0.0;
        }
    }
}

- (void)dealloc {
    [self stopDisplayLink];

    // CGオブジェクトを解放
    if (provider0) CGDataProviderRelease(provider0);
    if (provider1) CGDataProviderRelease(provider1);
    if (colorSpace) CGColorSpaceRelease(colorSpace);

    // バッファを解放
    if (buffer0) free(buffer0);
    if (buffer1) free(buffer1);
}

// 手動描画用のアクセサメソッド実装
- (int)getWidth {
    return width;
}

- (int)getHeight {
    return height;
}

- (uint32_t*)getCurrentBuffer {
    return currentBuffer;
}

- (void)presentManual {
    // バッファをスワップ（ゼロコピー）
    uint32_t* temp = currentBuffer;
    currentBuffer = displayBuffer;
    displayBuffer = temp;

    // 表示するバッファに対応するCGDataProviderを選択
    CGDataProviderRef provider = (displayBuffer == buffer0) ? provider0 : provider1;

    // CGImageを作成
    CGImageRef image = CGImageCreate(
        width,
        height,
        8,
        32,
        width * 4,
        colorSpace,
        kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big,
        provider,
        NULL,
        false,
        kCGRenderingIntentDefault
    );

    // レイヤーのcontentsに設定
    contentLayer.contents = (__bridge id)image;

    // CGImageを解放
    CGImageRelease(image);
}

- (BOOL)isOpaque {
    return YES;
}

@end

// ========================================
// イベント処理用定義
// ========================================

#define EVENT_QUEUE_SIZE 256

// macOSのキーコードをPlatformKeyCodeに変換
static PlatformKeyCode mapKeyCodeToPlatform(unsigned short keyCode) {
    // macOSのキーコード（ANSI配列）から標準キーコードへの変換
    switch (keyCode) {
        case 0x00: return PLATFORM_KEY_A;
        case 0x01: return PLATFORM_KEY_S;
        case 0x02: return PLATFORM_KEY_D;
        case 0x03: return PLATFORM_KEY_F;
        case 0x04: return PLATFORM_KEY_H;
        case 0x05: return PLATFORM_KEY_G;
        case 0x06: return PLATFORM_KEY_Z;
        case 0x07: return PLATFORM_KEY_X;
        case 0x08: return PLATFORM_KEY_C;
        case 0x09: return PLATFORM_KEY_V;
        case 0x0B: return PLATFORM_KEY_B;
        case 0x0C: return PLATFORM_KEY_Q;
        case 0x0D: return PLATFORM_KEY_W;
        case 0x0E: return PLATFORM_KEY_E;
        case 0x0F: return PLATFORM_KEY_R;
        case 0x10: return PLATFORM_KEY_Y;
        case 0x11: return PLATFORM_KEY_T;
        case 0x12: return PLATFORM_KEY_1;
        case 0x13: return PLATFORM_KEY_2;
        case 0x14: return PLATFORM_KEY_3;
        case 0x15: return PLATFORM_KEY_4;
        case 0x16: return PLATFORM_KEY_6;
        case 0x17: return PLATFORM_KEY_5;
        case 0x1A: return PLATFORM_KEY_9;
        case 0x1B: return PLATFORM_KEY_0;
        case 0x1C: return PLATFORM_KEY_U;
        case 0x1D: return PLATFORM_KEY_O;
        case 0x1E: return PLATFORM_KEY_I;
        case 0x1F: return PLATFORM_KEY_P;
        case 0x20: return PLATFORM_KEY_UNKNOWN;  // [
        case 0x21: return PLATFORM_KEY_UNKNOWN;  // ]
        case 0x23: return PLATFORM_KEY_UNKNOWN;  // keypad .
        case 0x24: return PLATFORM_KEY_UNKNOWN;  // keypad 0
        case 0x25: return PLATFORM_KEY_UNKNOWN;  // keypad 1
        case 0x26: return PLATFORM_KEY_UNKNOWN;  // keypad 2
        case 0x27: return PLATFORM_KEY_UNKNOWN;  // keypad 3
        case 0x28: return PLATFORM_KEY_UNKNOWN;  // keypad 4
        case 0x29: return PLATFORM_KEY_UNKNOWN;  // keypad 5
        case 0x2A: return PLATFORM_KEY_UNKNOWN;  // keypad 6
        case 0x2B: return PLATFORM_KEY_UNKNOWN;  // keypad ,
        case 0x2C: return PLATFORM_KEY_UNKNOWN;  // keypad 7
        case 0x2D: return PLATFORM_KEY_UNKNOWN;  // keypad 8
        case 0x2E: return PLATFORM_KEY_UNKNOWN;  // keypad 9
        case 0x2F: return PLATFORM_KEY_UNKNOWN;  // keypad .
        case 0x31: return PLATFORM_KEY_SPACE;
        case 0x33: return PLATFORM_KEY_UNKNOWN;  // Delete/Backspace
        case 0x35: return PLATFORM_KEY_ESCAPE;
        case 0x37: return PLATFORM_KEY_UNKNOWN;  // Command (左)
        case 0x38: return PLATFORM_KEY_UNKNOWN;  // Shift (左)
        case 0x39: return PLATFORM_KEY_UNKNOWN;  // Caps Lock
        case 0x3A: return PLATFORM_KEY_UNKNOWN;  // Alt (左)
        case 0x3B: return PLATFORM_KEY_UNKNOWN;  // Control (左)
        case 0x3C: return PLATFORM_KEY_UNKNOWN;  // Shift (右)
        case 0x3D: return PLATFORM_KEY_UNKNOWN;  // Alt (右)
        case 0x3E: return PLATFORM_KEY_UNKNOWN;  // Control (右)
        case 0x3F: return PLATFORM_KEY_UNKNOWN;  // Fn
        case 0x7A: return PLATFORM_KEY_UNKNOWN;  // F1
        case 0x78: return PLATFORM_KEY_UNKNOWN;  // F2
        case 0x63: return PLATFORM_KEY_UNKNOWN;  // F3
        case 0x76: return PLATFORM_KEY_UNKNOWN;  // F4
        case 0x60: return PLATFORM_KEY_UNKNOWN;  // F5
        case 0x61: return PLATFORM_KEY_UNKNOWN;  // F6
        case 0x62: return PLATFORM_KEY_UNKNOWN;  // F7
        case 0x64: return PLATFORM_KEY_UNKNOWN;  // F8
        case 0x65: return PLATFORM_KEY_UNKNOWN;  // F9
        case 0x6D: return PLATFORM_KEY_UNKNOWN;  // F10
        case 0x67: return PLATFORM_KEY_UNKNOWN;  // F11
        case 0x6F: return PLATFORM_KEY_UNKNOWN;  // F12
        case 0x69: return PLATFORM_KEY_UNKNOWN;  // F13
        case 0x6B: return PLATFORM_KEY_UNKNOWN;  // F14
        case 0x71: return PLATFORM_KEY_UNKNOWN;  // F15
        case 0x6A: return PLATFORM_KEY_UNKNOWN;  // F16
        case 0x40: return PLATFORM_KEY_UNKNOWN;  // F17
        case 0x4F: return PLATFORM_KEY_UNKNOWN;  // F18
        case 0x50: return PLATFORM_KEY_UNKNOWN;  // F19
        case 0x5A: return PLATFORM_KEY_UNKNOWN;  // F20
        case 0x7D: return PLATFORM_KEY_DOWN;
        case 0x7E: return PLATFORM_KEY_UP;
        case 0x7B: return PLATFORM_KEY_LEFT;
        case 0x7C: return PLATFORM_KEY_RIGHT;
        case 0x4C: return PLATFORM_KEY_ENTER;    // keypad Enter
        default: return PLATFORM_KEY_UNKNOWN;
    }
}

// モディファイアキーを抽出
static uint32_t extractModifiers(NSEventModifierFlags nsModifiers) {
    uint32_t mods = 0;
    if (nsModifiers & NSEventModifierFlagShift)   mods |= PLATFORM_MOD_SHIFT;
    if (nsModifiers & NSEventModifierFlagControl) mods |= PLATFORM_MOD_CTRL;
    if (nsModifiers & NSEventModifierFlagOption)  mods |= PLATFORM_MOD_ALT;
    if (nsModifiers & NSEventModifierFlagCommand) mods |= PLATFORM_MOD_CMD;
    return mods;
}

// イベントキュー構造体
typedef struct {
    PlatformEvent events[EVENT_QUEUE_SIZE];
    int head;  // 次に書き込む位置
    int tail;  // 次に読む位置
} EventQueue;

// プラットフォームウィンドウ構造体
struct PlatformWindow {
    NSWindow* window;
    FramebufferView* view;
    EventQueue event_queue;
};

// プラットフォーム初期化
bool platform_init(void) {
    // macOSでは特に初期化不要
    return true;
}

// ウィンドウ作成
PlatformWindow* platform_create_window(int width, int height, const char* title,
                                      FrameCallback callback, void* userdata) {
    PlatformWindow* platformWindow = (PlatformWindow*)malloc(sizeof(PlatformWindow));
    if (!platformWindow) return NULL;

    // イベントキューを初期化
    memset(&platformWindow->event_queue, 0, sizeof(EventQueue));

    @autoreleasepool {
        // NSApplicationを取得
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        // ウィンドウを作成
        NSRect frame = NSMakeRect(0, 0, width, height);
        NSWindowStyleMask styleMask = NSWindowStyleMaskTitled |
                                       NSWindowStyleMaskClosable |
                                       NSWindowStyleMaskMiniaturizable;

        platformWindow->window = [[NSWindow alloc] initWithContentRect:frame
                                                             styleMask:styleMask
                                                               backing:NSBackingStoreBuffered
                                                                 defer:NO];

        [platformWindow->window setTitle:[NSString stringWithUTF8String:title]];

        // カスタムビューを作成して設定
        platformWindow->view = [[FramebufferView alloc] initWithFrame:frame
                                                               width:width
                                                              height:height
                                                            callback:callback
                                                            userdata:userdata];
        [platformWindow->window setContentView:platformWindow->view];

        // ウィンドウを表示
        [platformWindow->window center];
        [platformWindow->window makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];

        // CADisplayLinkを開始
        [platformWindow->view startDisplayLink];
    }

    return platformWindow;
}

// メインループ
void platform_run(PlatformWindow* platformWindow) {
    if (!platformWindow) return;

    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        [app run];
    }
}

// ウィンドウ破棄
void platform_destroy_window(PlatformWindow* platformWindow) {
    if (!platformWindow) return;

    // ビューのdeallocでCADisplayLinkは自動的に停止される
    free(platformWindow);
}

// プラットフォームシャットダウン
void platform_shutdown(void) {
    // macOSでは特にクリーンアップ不要
}

// ========================================
// 手動描画用API実装
// ========================================

// イベントをポーリング（ノンブロッキング）
bool platform_poll_events(PlatformWindow* platformWindow) {
    if (!platformWindow) return false;

    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];

        // イベントをポーリング（ブロックしない）
        NSEvent* event;
        while ((event = [app nextEventMatchingMask:NSEventMaskAny
                                         untilDate:[NSDate distantPast]
                                            inMode:NSDefaultRunLoopMode
                                           dequeue:YES])) {
            // キーボードイベントをイベントキューに追加
            if (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) {
                EventQueue* queue = &platformWindow->event_queue;
                int next_head = (queue->head + 1) % EVENT_QUEUE_SIZE;

                // キューがいっぱいでない場合のみ追加
                if (next_head != queue->tail) {
                    PlatformEvent platform_event;
                    platform_event.type = (event.type == NSEventTypeKeyDown)
                        ? PLATFORM_EVENT_KEY_DOWN
                        : PLATFORM_EVENT_KEY_UP;
                    platform_event.keyboard.key = mapKeyCodeToPlatform(event.keyCode);
                    platform_event.keyboard.is_repeat = event.isARepeat;
                    platform_event.keyboard.modifiers = extractModifiers(event.modifierFlags);

                    queue->events[queue->head] = platform_event;
                    queue->head = next_head;
                }
            }

            [app sendEvent:event];
            [app updateWindows];
        }

        // ウィンドウが閉じられているか確認
        if (![platformWindow->window isVisible]) {
            // QUITイベントをキューに追加
            EventQueue* queue = &platformWindow->event_queue;
            int next_head = (queue->head + 1) % EVENT_QUEUE_SIZE;
            if (next_head != queue->tail) {
                PlatformEvent quit_event;
                quit_event.type = PLATFORM_EVENT_QUIT;
                queue->events[queue->head] = quit_event;
                queue->head = next_head;
            }
            return false;
        }

        return true;
    }
}

// 高精度モノトニック時刻を取得（調整なし）
double platform_get_time(void) {
    uint64_t ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    return (double)ns / 1e9;
}

// フレームバッファへのアクセスを開始
uint32_t* platform_lock_framebuffer(PlatformWindow* platformWindow, int* out_width, int* out_height) {
    if (!platformWindow) return NULL;

    FramebufferView* view = platformWindow->view;

    // アクセサメソッドを使用してバッファにアクセス
    if (out_width) *out_width = [view getWidth];
    if (out_height) *out_height = [view getHeight];

    // currentBufferを返す（ユーザーが書き込むバッファ）
    return [view getCurrentBuffer];
}

// フレームバッファへのアクセスを終了
void platform_unlock_framebuffer(PlatformWindow* platformWindow) {
    // このAPIでは特に何もする必要なし
    // バッファのスワップはplatform_present()で行う
    (void)platformWindow;
}

// 画面を更新
void platform_present(PlatformWindow* platformWindow) {
    if (!platformWindow) return;

    @autoreleasepool {
        FramebufferView* view = platformWindow->view;

        // アクセサメソッドを使用して手動描画
        [view presentManual];
    }
}

// イベント取得API
bool platform_get_event(PlatformWindow* window, PlatformEvent* event) {
    if (!window || !event) return false;

    EventQueue* queue = &window->event_queue;

    // キューが空の場合
    if (queue->head == queue->tail) {
        return false;
    }

    // キューから次のイベントを取得
    *event = queue->events[queue->tail];
    queue->tail = (queue->tail + 1) % EVENT_QUEUE_SIZE;

    return true;
}
