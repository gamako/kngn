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

// プラットフォームウィンドウ構造体
struct PlatformWindow {
    NSWindow* window;
    FramebufferView* view;
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
            [app sendEvent:event];
            [app updateWindows];
        }

        // ウィンドウが閉じられているか確認
        return [platformWindow->window isVisible];
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
