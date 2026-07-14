#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#if defined(VP_ENABLE_GAMEPAD)
#import <GameController/GameController.h>
#endif
#include "platform.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// CALayer最適化版の実装
#define IMPLEMENTATION_TYPE "CALayer Optimized"

// 前方宣言
@class FramebufferView;

// ========================================
// イベントキュー / PlatformWindow 定義 (FramebufferView の @implementation から参照される)
// ========================================

#define EVENT_QUEUE_SIZE 256

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
    // 観測カウンタ (累積値、example で差分監視に使う)
    uint64_t mouse_move_merge_count;
    uint64_t mouse_scroll_merge_count;
    uint64_t event_drop_count;
} EventQueue;

// プラットフォームウィンドウ構造体
struct PlatformWindow {
    NSWindow* window;
    FramebufferView* view;
    EventQueue event_queue;
};

// 前方宣言 (定義は下記マウス入力ヘルパーの後。ゲームパッド connect/disconnect ハンドラから使う)。
static void queue_push(EventQueue* q, const PlatformEvent* ev);

// ========================================
// ゲームパッド入力 (TASK-80.2。ADR-009)
// ========================================
//
// opt-in（TASK-80.2 opt-in 化）: GameController framework は audio と同じ opt-in link 方式で、
// ゲームパッドを使う exe（examples/22_gamepad）だけが build.zig から `-DVP_ENABLE_GAMEPAD` を渡す
// （build_helpers/platform.zig の compilePlatformLayer 参照）。非 opt-in exe はこのブロック全体が
// コンパイル対象外になり GameController のシンボルを一切参照しない（`otool -L` にも出ない）。
#if defined(VP_ENABLE_GAMEPAD)
//
// GCController ↔ index (0..PLATFORM_MAX_GAMEPADS-1) のマッピングを保持する。ARC のため
// 強参照配列でよい（GCController 自体は GameController framework が connect している間保持する）。
// 単一 window 前提（既存コードと同じ）なので、connect/disconnect イベントは
// 「現在アクティブな window」(最後に create された window) の event_queue へ push する。

static GCController* g_gamepad_slots[PLATFORM_MAX_GAMEPADS];
static PlatformWindow* g_gamepad_event_window = NULL;
static BOOL g_gamepad_observers_installed = NO;

// 追跡中の controller の slot index。未追跡なら -1。
static int gamepadFindSlot(GCController* controller) {
    for (int i = 0; i < PLATFORM_MAX_GAMEPADS; i++) {
        if (g_gamepad_slots[i] == controller) return i;
    }
    return -1;
}

// 空きスロットの index。無ければ -1（上限超は無視）。
static int gamepadFindFreeSlot(void) {
    for (int i = 0; i < PLATFORM_MAX_GAMEPADS; i++) {
        if (g_gamepad_slots[i] == nil) return i;
    }
    return -1;
}

// PlatformEvent.payload.gamepad.name（32byte+NUL固定）へ UTF-8 文字列を切り詰めコピーする。
static void gamepadCopyName(PlatformEvent* ev, NSString* name) {
    memset(ev->payload.gamepad.name, 0, sizeof(ev->payload.gamepad.name));
    const char* utf8 = [name UTF8String];
    if (!utf8) return;
    strncpy(ev->payload.gamepad.name, utf8, sizeof(ev->payload.gamepad.name) - 1);
}

// GCController 接続を取り込む。extendedGamepad 非対応（micro gamepad 等）・追跡済み・上限超は無視する。
static void gamepadHandleConnect(GCController* controller) {
    if (!controller.extendedGamepad) return; // 標準レイアウト非対応は対象外
    if (gamepadFindSlot(controller) >= 0) return; // 追跡済み（defensive）
    if (!g_gamepad_event_window) return; // window 未生成中は無視
    int idx = gamepadFindFreeSlot();
    if (idx < 0) return; // PLATFORM_MAX_GAMEPADS 台超は無視
    g_gamepad_slots[idx] = controller;

    PlatformEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = PLATFORM_EVENT_GAMEPAD_CONNECTED;
    ev.payload.gamepad.index = idx;
    gamepadCopyName(&ev, controller.vendorName ?: @"Gamepad");
    queue_push(&g_gamepad_event_window->event_queue, &ev);
}

// GCController 切断を取り込む。未追跡なら無視する。
static void gamepadHandleDisconnect(GCController* controller) {
    int idx = gamepadFindSlot(controller);
    if (idx < 0) return;
    g_gamepad_slots[idx] = nil;
    if (!g_gamepad_event_window) return;

    PlatformEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = PLATFORM_EVENT_GAMEPAD_DISCONNECTED;
    ev.payload.gamepad.index = idx;
    queue_push(&g_gamepad_event_window->event_queue, &ev);
}

// GCControllerDidConnect/DidDisconnect の Notification 監視を 1 プロセス 1 回だけ設置する。
// queue に [NSOperationQueue mainQueue] を明示指定し main thread 配信を強制する（queue:nil だと
// 「通知を post したスレッドで同期実行」になり main thread 保証が無いため。codex レビュー指摘）。
// これにより event_queue / g_gamepad_slots への書き込みが pollEvents 等の main thread 経路と
// 同じスレッドに揃い、lock 無しでも race しない。
static void gamepadInstallObserversIfNeeded(void) {
    if (g_gamepad_observers_installed) return;
    g_gamepad_observers_installed = YES;
    [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification* note) {
        gamepadHandleConnect((GCController*)note.object);
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidDisconnectNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification* note) {
        gamepadHandleDisconnect((GCController*)note.object);
    }];
}

// window の create/destroy に合わせて「アクティブ window」を切替える。既に他 window から引き継いだ
// slot（前 window の生存中に接続済みだった controller）は新 window へ connected event を再送し、
// 未追跡のコントローラは通常の connect 処理で取り込む（codex レビュー指摘: window 再生成時に
// 既接続 controller の connected event が新 window に届かない問題への対応）。
static void gamepadAttachWindow(PlatformWindow* window) {
    g_gamepad_event_window = window;
    gamepadInstallObserversIfNeeded();
    for (int i = 0; i < PLATFORM_MAX_GAMEPADS; i++) {
        if (g_gamepad_slots[i] == nil) continue;
        PlatformEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.type = PLATFORM_EVENT_GAMEPAD_CONNECTED;
        ev.payload.gamepad.index = i;
        gamepadCopyName(&ev, g_gamepad_slots[i].vendorName ?: @"Gamepad");
        queue_push(&window->event_queue, &ev);
    }
    for (GCController* controller in [GCController controllers]) {
        gamepadHandleConnect(controller); // 未追跡のみ実際に処理する（gamepadFindSlot でスキップ）
    }
}

static void gamepadDetachWindow(PlatformWindow* window) {
    if (g_gamepad_event_window == window) {
        g_gamepad_event_window = NULL;
    }
}
#endif // VP_ENABLE_GAMEPAD

// ========================================
// マウス入力ヘルパー (TASK-21.1)
// ========================================

// non-precise scroll の line→points 変換係数 (経験則)
// example_07 でログ確認しつつ調整可能。
static const float SCROLL_LINE_TO_POINTS = 16.0f;

// キュー末尾の最新イベントへのポインタ。空なら NULL。
static PlatformEvent* queue_peek_tail(EventQueue* q) {
    if (q->head == q->tail) return NULL;
    int prev = (q->head - 1 + EVENT_QUEUE_SIZE) % EVENT_QUEUE_SIZE;
    return &q->events[prev];
}

// mouse_move の末尾合体 (buttons_mask + modifiers 同一の時のみ)。合体時 true。
static bool try_merge_mouse_move(EventQueue* q, const PlatformEvent* ev) {
    PlatformEvent* tail = queue_peek_tail(q);
    if (!tail || tail->type != PLATFORM_EVENT_MOUSE_MOVE) return false;
    if (tail->payload.mouse.buttons_mask != ev->payload.mouse.buttons_mask) return false;
    if (tail->payload.mouse.modifiers != ev->payload.mouse.modifiers) return false;
    tail->payload.mouse.x = ev->payload.mouse.x;
    tail->payload.mouse.y = ev->payload.mouse.y;
    q->mouse_move_merge_count++;
    return true;
}

// mouse_scroll の末尾合体 (is_precise + buttons_mask + modifiers 同一)。合体時 true。
static bool try_merge_mouse_scroll(EventQueue* q, const PlatformEvent* ev) {
    PlatformEvent* tail = queue_peek_tail(q);
    if (!tail || tail->type != PLATFORM_EVENT_MOUSE_SCROLL) return false;
    if (tail->payload.scroll.is_precise != ev->payload.scroll.is_precise) return false;
    if (tail->payload.scroll.buttons_mask != ev->payload.scroll.buttons_mask) return false;
    if (tail->payload.scroll.modifiers != ev->payload.scroll.modifiers) return false;
    tail->payload.scroll.x = ev->payload.scroll.x;
    tail->payload.scroll.y = ev->payload.scroll.y;
    tail->payload.scroll.dx += ev->payload.scroll.dx;
    tail->payload.scroll.dy += ev->payload.scroll.dy;
    q->mouse_scroll_merge_count++;
    return true;
}

// キューに push (満杯なら drop カウンタを増やして捨てる)
static void queue_push(EventQueue* q, const PlatformEvent* ev) {
    int next_head = (q->head + 1) % EVENT_QUEUE_SIZE;
    if (next_head == q->tail) {
        q->event_drop_count++;
        return;
    }
    q->events[q->head] = *ev;
    q->head = next_head;
}

// NSEvent の locationInWindow を view 内の左上原点座標へ変換 (floor 整数化)。
static void event_location_to_platform_coords(NSEvent* event, NSView* view, int32_t* out_x, int32_t* out_y) {
    NSPoint windowPt = event.locationInWindow;
    NSPoint viewPt = [view convertPoint:windowPt fromView:nil];
    CGFloat viewHeight = view.bounds.size.height;
    *out_x = (int32_t)floor(viewPt.x);
    *out_y = (int32_t)floor(viewHeight - viewPt.y);  // Y フリップ
}

// 現在押下中のボタン bitmask (& 0x07 で X1/X2 を除外)。
static uint8_t pressed_buttons_mask(void) {
    return (uint8_t)([NSEvent pressedMouseButtons] & 0x07);
}

// NSEvent.buttonNumber から PlatformMouseButton へ (物理ボタン基準)。
// Control+左クリックも buttonNumber=0 のままなので button=LEFT。
static PlatformMouseButton button_from_event(NSEvent* event) {
    switch (event.buttonNumber) {
        case 0: return PLATFORM_MOUSE_BUTTON_LEFT;
        case 1: return PLATFORM_MOUSE_BUTTON_RIGHT;
        case 2: return PLATFORM_MOUSE_BUTTON_MIDDLE;
        default: return PLATFORM_MOUSE_BUTTON_NONE;
    }
}

// ========================================
// CALayer最適化版の実装
// ========================================

// IME composition 固定バッファ（preedit UTF-8。TASK-79.6.1）
#define COMPOSITION_UTF8_CAP 1024

/// s[0..len] のうち cap バイト以内に収まる最長の UTF-8 codepoint 境界プレフィックス長。
/// cap を超える場合は continuation (0b10xxxxxx) を含む途中切断を避け、完全な codepoint だけ残す。
static size_t utf8SafePrefixLen(const char* s, size_t len, size_t cap) {
    size_t i = 0;
    while (i < len && i < cap) {
        const unsigned char c = (unsigned char)s[i];
        size_t need;
        if ((c & 0x80) == 0) need = 1;
        else if ((c & 0xE0) == 0xC0) need = 2;
        else if ((c & 0xF0) == 0xE0) need = 3;
        else if ((c & 0xF8) == 0xF0) need = 4;
        else break; // 不正 lead: 手前まで
        if (i + need > cap || i + need > len) break;
        i += need;
    }
    return i;
}

// カスタムNSView - CALayerベースの高速描画 + NSTextInputClient（TASK-79.6.1 IME）
@interface FramebufferView : NSView <NSTextInputClient> {
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

    // マウスイベント用 (TASK-21.1)
    PlatformWindow* platformWindow;  // 非所有の生ポインタ。destroy 時に NULL 化される
    NSTrackingArea* trackingArea;

    // カーソル制御用 (TASK-75.1)
    PlatformCursorShape currentCursorShape;  // 直近に要求された形状（既定 PLATFORM_CURSOR_DEFAULT）
    BOOL cursorHiddenByThisView;             // このviewが [NSCursor hide] を所有中か（グローバル参照カウントAPIの多重呼び出し防止）
    BOOL mouseInsideView;                    // マウスが現在 view 内にあるか（view外では set/hide を保留する）

    // ライブリサイズ再描画 (TASK-23.1)。FrameCallback とは別。未登録時は NULL。
    PlatformRedrawCallback redrawCallback;
    void* redrawUserdata;

    // IME composition 状態 (TASK-79.6.1)。本文は snapshot API、変化は PLATFORM_EVENT_COMPOSITION。
    NSMutableString* markedText;
    NSRange imeSelectedRange; // markedText 内の選択（UTF-16 単位）
    char compositionUtf8[COMPOSITION_UTF8_CAP];
    uint32_t compositionLen;
    uint32_t compositionRevision;
    uint32_t compositionCursor; // preedit 内 UTF-8 バイトオフセット
}
- (id)initWithFrame:(NSRect)frame width:(int)w height:(int)h
           callback:(FrameCallback)cb userdata:(void*)ud
     platformWindow:(PlatformWindow*)pw;
- (void)startDisplayLink;
- (void)stopDisplayLink;
- (void)displayLinkFired:(CADisplayLink*)link;
- (void)dealloc;

// 手動描画用のアクセサメソッド
- (int)getWidth;
- (int)getHeight;
- (uint32_t*)getCurrentBuffer;
- (void)presentManual;

// destroy 時に呼ぶ。view の back-reference を無効化する。
- (void)clearPlatformWindow;

// カーソル形状を設定する (TASK-75.1)。platform_set_cursor から呼ばれる。
- (void)setCursorShape:(PlatformCursorShape)shape;

// ライブリサイズ再描画コールバック登録 (TASK-23.1)。cb==NULL で解除。
- (void)setRedrawCallback:(PlatformRedrawCallback)cb userdata:(void*)ud;

// composition snapshot（platform_get_composition_snapshot から呼ぶ）
- (uint32_t)copyCompositionSnapshot:(char*)buf cap:(uint32_t)cap meta:(PlatformCompositionMeta*)meta;

@end

@implementation FramebufferView

- (id)initWithFrame:(NSRect)frame width:(int)w height:(int)h
           callback:(FrameCallback)cb userdata:(void*)ud
     platformWindow:(PlatformWindow*)pw {
    self = [super initWithFrame:frame];
    if (self) {
        width = w;
        height = h;
        callback = cb;
        userdata = ud;
        platformWindow = pw;
        trackingArea = nil;
        currentCursorShape = PLATFORM_CURSOR_DEFAULT;
        cursorHiddenByThisView = NO;
        mouseInsideView = NO;
        redrawCallback = NULL;
        redrawUserdata = NULL;
        markedText = [[NSMutableString alloc] init];
        imeSelectedRange = NSMakeRange(0, 0);
        compositionLen = 0;
        compositionRevision = 0;
        compositionCursor = 0;
        memset(compositionUtf8, 0, sizeof(compositionUtf8));

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
            kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little, // canonical BGRA: メモリ [B,G,R,A] = u32 0xAARRGGBB
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

    // カーソルを hide したまま破棄されると OS カーソルが消えたままになる (TASK-75.1 codex レビュー指摘)。
    if (cursorHiddenByThisView) {
        [NSCursor unhide];
        cursorHiddenByThisView = NO;
    }

    markedText = nil;

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
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little, // canonical BGRA: メモリ [B,G,R,A] = u32 0xAARRGGBB
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

// ========================================
// リサイズ (TASK-23)
// ========================================

// 新サイズへフレームバッファ/プロバイダを two-phase で再確保する。
// 新リソースの確保に成功してから旧リソースを破棄する（失敗時は旧サイズを維持）。
// 単位は logical points（mouse 座標と同一）。lock 中には呼ばれない（イベントポンプ中に発火）。
- (BOOL)resizeBuffersTo:(int)w height:(int)h {
    if (!buffer0 || !buffer1) return NO; // init 途中（super の setFrameSize）では何もしない
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    if (w == width && h == height) return YES; // 変化なし

    // phase 1: 新リソースを確保（成功するまで旧リソースには触れない）
    uint32_t* nb0 = (uint32_t*)calloc((size_t)w * h, sizeof(uint32_t));
    uint32_t* nb1 = (uint32_t*)calloc((size_t)w * h, sizeof(uint32_t));
    if (!nb0 || !nb1) {
        if (nb0) free(nb0);
        if (nb1) free(nb1);
        return NO; // OOM: 旧サイズ維持
    }
    CGDataProviderRef np0 = CGDataProviderCreateWithData(NULL, nb0, (size_t)w * h * sizeof(uint32_t), NULL);
    CGDataProviderRef np1 = CGDataProviderCreateWithData(NULL, nb1, (size_t)w * h * sizeof(uint32_t), NULL);
    if (!np0 || !np1) {
        if (np0) CGDataProviderRelease(np0);
        if (np1) CGDataProviderRelease(np1);
        free(nb0);
        free(nb1);
        return NO; // 旧サイズ維持
    }

    // phase 2: 旧リソースを破棄して swap。
    // layer.contents は旧 buffer を参照する CGImage を保持しているので、先に外して
    // use-after-free を避ける（次の present で新 image を貼る）。
    contentLayer.contents = nil;
    CGDataProviderRelease(provider0);
    CGDataProviderRelease(provider1);
    free(buffer0);
    free(buffer1);

    buffer0 = nb0;
    buffer1 = nb1;
    provider0 = np0;
    provider1 = np1;
    currentBuffer = buffer0;
    displayBuffer = buffer1;
    width = w;
    height = h;
    contentLayer.frame = CGRectMake(0, 0, w, h);
    return YES;
}

// NSView がリサイズ時に呼ぶ。新しい logical サイズに合わせて fb を再確保する。
// サイズが実際に変わったときだけ redraw callback を発火する（TASK-23.1。
// AppKit の live-resize tracking run loop 中でも CATransaction commit により画面反映される）。
- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    const int old_w = width;
    const int old_h = height;
    if ([self resizeBuffersTo:(int)newSize.width height:(int)newSize.height]) {
        if ((width != old_w || height != old_h) && redrawCallback) {
            redrawCallback(redrawUserdata);
        }
    }
}

- (void)setRedrawCallback:(PlatformRedrawCallback)cb userdata:(void*)ud {
    redrawCallback = cb;
    redrawUserdata = ud;
}

// ========================================
// NSTextInputClient / IME composition (TASK-79.6.1)
// ========================================
// keyDown は poll ループで物理 key_down を積んだ後 interpretKeyEvents: に渡し、
// insertText: が char_input の唯一の生成元になる（旧 event.characters 直読みは廃止）。

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (uint32_t)copyCompositionSnapshot:(char*)buf cap:(uint32_t)cap meta:(PlatformCompositionMeta*)meta {
    // latest-wins: 常に現在 preedit。event.revision は取りこぼし検知用（過去 revision は取れない）。
    if (meta) {
        meta->revision = compositionRevision;
        meta->cursor = compositionCursor;
        meta->len = 0;
    }
    if (!buf || cap == 0 || compositionLen == 0) {
        if (meta) meta->len = 0;
        return 0;
    }
    // UTF-8 codepoint 境界で切断（codex 修正 A）
    uint32_t n = (uint32_t)utf8SafePrefixLen(compositionUtf8, compositionLen, cap);
    memcpy(buf, compositionUtf8, n);
    if (meta) {
        meta->len = n;
        if (meta->cursor > n) meta->cursor = n;
    }
    return n;
}

/// markedText → compositionUtf8 / compositionCursor を同期する。
- (void)syncCompositionBufferFromMarked {
    const char* utf8 = [markedText UTF8String];
    if (!utf8) {
        compositionLen = 0;
        compositionCursor = 0;
        return;
    }
    size_t raw_len = strlen(utf8);
    // 固定バッファへ UTF-8 境界で truncate（codex 修正 A）
    size_t len = utf8SafePrefixLen(utf8, raw_len, COMPOSITION_UTF8_CAP);
    memcpy(compositionUtf8, utf8, len);
    compositionLen = (uint32_t)len;
    // selectedRange.location は UTF-16 単位。UTF-8 オフセットへ変換する。
    NSUInteger loc = imeSelectedRange.location;
    if (loc > markedText.length) loc = markedText.length;
    NSString* prefix = [markedText substringToIndex:loc];
    const char* pfx = [prefix UTF8String];
    compositionCursor = pfx ? (uint32_t)strlen(pfx) : 0;
    if (compositionCursor > compositionLen) compositionCursor = compositionLen;
}

- (void)pushCompositionPhase:(uint8_t)phase {
    if (!platformWindow) return;
    compositionRevision += 1;
    PlatformEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = PLATFORM_EVENT_COMPOSITION;
    ev.payload.composition.revision = compositionRevision;
    ev.payload.composition.phase = phase;
    ev.payload.composition.cursor = compositionCursor;
    queue_push(&platformWindow->event_queue, &ev);
}

/// insertText の文字列を codepoint 分解して CHAR_INPUT を積む（制御/private-use 除外）。
/// Cmd/Ctrl 押下中は char_input を出さない（キーバインド経由 insertText の誤印字防止。codex 修正 B）。
- (void)pushCharInputsFromString:(NSString*)str {
    if (!platformWindow || !str) return;
    uint32_t char_mods = extractModifiers([NSEvent modifierFlags]);
    // printable フィルタと同列の invariant: cmd/ctrl 付きは印字しない
    if (char_mods & (PLATFORM_MOD_CMD | PLATFORM_MOD_CTRL)) return;
    NSUInteger clen = str.length;
    for (NSUInteger ci = 0; ci < clen;) {
        unichar hi = [str characterAtIndex:ci];
        uint32_t cp;
        if (CFStringIsSurrogateHighCharacter(hi) && ci + 1 < clen) {
            unichar lo = [str characterAtIndex:ci + 1];
            cp = CFStringGetLongCharacterForSurrogatePair(hi, lo);
            ci += 2;
        } else {
            cp = hi;
            ci += 1;
        }
        if (cp >= 0x20 && cp != 0x7f && !(cp >= 0xF700 && cp <= 0xF8FF)) {
            PlatformEvent char_event;
            memset(&char_event, 0, sizeof(char_event));
            char_event.type = PLATFORM_EVENT_CHAR_INPUT;
            char_event.payload.character.codepoint = cp;
            char_event.payload.character.modifiers = char_mods;
            queue_push(&platformWindow->event_queue, &char_event);
        }
    }
}

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    // replacementRange: 79.6.2+ で扱う（char_input に置換情報が無い現契約の既知の穴）。
    (void)replacementRange;
    NSString* str = [string isKindOfClass:[NSAttributedString class]]
        ? [(NSAttributedString*)string string]
        : (NSString*)string;
    BOOL hadMarked = (markedText.length > 0);
    if (hadMarked) {
        [markedText setString:@""];
        imeSelectedRange = NSMakeRange(0, 0);
        compositionLen = 0;
        compositionCursor = 0;
        [self pushCompositionPhase:PLATFORM_COMPOSITION_PHASE_COMMIT];
    }
    [self pushCharInputsFromString:str];
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    // replacementRange: 79.6.2+ で扱う（char_input に置換情報が無い現契約の既知の穴）。
    (void)replacementRange;
    NSString* str = [string isKindOfClass:[NSAttributedString class]]
        ? [(NSAttributedString*)string string]
        : (NSString*)string;
    if (!str) str = @"";
    BOOL wasEmpty = (markedText.length == 0);
    [markedText setString:str];
    imeSelectedRange = selectedRange;
    if (selectedRange.location == NSNotFound) {
        imeSelectedRange = NSMakeRange(markedText.length, 0);
    }
    [self syncCompositionBufferFromMarked];
    if (markedText.length == 0) {
        compositionLen = 0;
        compositionCursor = 0;
        if (!wasEmpty) {
            [self pushCompositionPhase:PLATFORM_COMPOSITION_PHASE_CANCEL];
        }
        return;
    }
    uint8_t phase = wasEmpty
        ? PLATFORM_COMPOSITION_PHASE_START
        : PLATFORM_COMPOSITION_PHASE_UPDATE;
    [self pushCompositionPhase:phase];
}

- (void)unmarkText {
    if (markedText.length == 0) return;
    [markedText setString:@""];
    imeSelectedRange = NSMakeRange(0, 0);
    compositionLen = 0;
    compositionCursor = 0;
    [self pushCompositionPhase:PLATFORM_COMPOSITION_PHASE_CANCEL];
}

- (BOOL)hasMarkedText {
    return markedText.length > 0;
}

- (NSRange)markedRange {
    if (markedText.length == 0) return NSMakeRange(NSNotFound, 0);
    return NSMakeRange(0, markedText.length);
}

- (NSRange)selectedRange {
    if (markedText.length == 0) return NSMakeRange(NSNotFound, 0);
    return imeSelectedRange;
}

- (NSArray<NSAttributedStringKey>*)validAttributesForMarkedText {
    return @[];
}

- (NSAttributedString*)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    if (markedText.length == 0) return nil;
    NSRange full = NSMakeRange(0, markedText.length);
    NSRange clipped = NSIntersectionRange(full, range);
    if (clipped.length == 0) return nil;
    if (actualRange) *actualRange = clipped;
    return [[NSAttributedString alloc] initWithString:[markedText substringWithRange:clipped]];
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    (void)point;
    return NSNotFound;
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    if (actualRange) *actualRange = range;
    // MVP: view 左上近傍の固定 rect（候補窓が window 近傍に出ること。caret 供給は 79.6.2）。
    // AppKit view 座標は下原点。bounds 上端付近へ置く。
    NSRect r = NSMakeRect(20.0, self.bounds.size.height - 48.0, 1.0, 18.0);
    r = [self convertRect:r toView:nil];
    if (self.window) {
        r = [self.window convertRectToScreen:r];
    }
    return r;
}

- (void)doCommandBySelector:(SEL)selector {
    // 未処理 command を吸収してビープ抑止。BACKSPACE/ENTER 等の物理キーは key_down 経路で既に届く。
    (void)selector;
}

// ========================================
// マウスイベント関連 (TASK-21.1)
// ========================================

- (void)clearPlatformWindow {
    platformWindow = NULL;
}

// 非アクティブ window への最初のクリックでも mouseDown: を受け取る
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    (void)event;
    return YES;
}

// NSTrackingArea を view サイズに合わせて再構築
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (trackingArea) {
        [self removeTrackingArea:trackingArea];
        trackingArea = nil;
    }
    // NSTrackingCursorUpdate: マウスが再入した際に cursorUpdate: を呼んでもらい、OS が
    // ウィンドウ切替等でカーソルをリセットしても復帰できるようにする (TASK-75.1)。
    // NSTrackingMouseEnteredAndExited: view 内外を追跡し、hidden の所有権解除（mouseExited）と
    // 形状の適用（mouseEntered）を行う（codex レビュー: hide/unhide は view 内にいる時のみ行う）。
    NSTrackingAreaOptions opts = NSTrackingMouseMoved
                                | NSTrackingCursorUpdate
                                | NSTrackingMouseEnteredAndExited
                                | NSTrackingActiveInKeyWindow
                                | NSTrackingInVisibleRect;
    trackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                options:opts
                                                  owner:self
                                               userInfo:nil];
    [self addTrackingArea:trackingArea];
}

// ========================================
// カーソル制御 (TASK-75.1)
// ========================================
//
// 方針: NSCursor hide/unhide はプロセス全体の参照カウント API のため、view が「今 hide を
// 所有しているか」を cursorHiddenByThisView で厳密に管理する（hide は false→true 遷移時のみ、
// unhide は true→false 遷移時のみ呼ぶ）。加えて set/hide の実適用は mouseInsideView が true の
// 間だけ行い、view 外にいる間に来た setCursor はまだ反映せず形状のみ保存する（マウスが view 外
// にある状態で誤って全体のカーソルを hide/変形させないため）。

// currentCursorShape に対応する NSCursor を返す（PLATFORM_CURSOR_HIDDEN はここでは扱わない）。
// 未対応形状は arrow にフォールバックする。
- (NSCursor *)nsCursorForShape:(PlatformCursorShape)shape {
    switch (shape) {
        case PLATFORM_CURSOR_CROSSHAIR:
            return [NSCursor crosshairCursor];
        case PLATFORM_CURSOR_DEFAULT:
        default:
            return [NSCursor arrowCursor];
    }
}

// mouseInsideView 前提で currentCursorShape を実際に適用する（hide 所有権の遷移も含む）。
- (void)applyCursorShapeIfInside {
    if (!mouseInsideView) return;
    if (currentCursorShape == PLATFORM_CURSOR_HIDDEN) {
        if (!cursorHiddenByThisView) {
            [NSCursor hide];
            cursorHiddenByThisView = YES;
        }
    } else {
        if (cursorHiddenByThisView) {
            [NSCursor unhide];
            cursorHiddenByThisView = NO;
        }
        [[self nsCursorForShape:currentCursorShape] set];
    }
}

// platform_set_cursor から呼ばれる。形状を保存し、view 内にいれば即時反映する。
- (void)setCursorShape:(PlatformCursorShape)shape {
    currentCursorShape = shape;
    [self applyCursorShapeIfInside];
}

// マウスが view に再入した (TASK-75.1)。現在の形状を反映する。
- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    mouseInsideView = YES;
    [self applyCursorShapeIfInside];
}

// マウスが view から出た (TASK-75.1)。hide を所有中なら必ず解放する
// （view 外で OS カーソルが消えたままになるのを防ぐ。codex レビュー指摘）。
- (void)mouseExited:(NSEvent *)event {
    (void)event;
    mouseInsideView = NO;
    if (cursorHiddenByThisView) {
        [NSCursor unhide];
        cursorHiddenByThisView = NO;
    }
}

// AppKit がトラッキングエリア再入時に呼ぶ。他アプリ切替等で OS がカーソルをリセットしても復帰する。
- (void)cursorUpdate:(NSEvent *)event {
    (void)event;
    // cursorUpdate は tracking rect 内でのみ呼ばれる（NSTrackingCursorUpdate）ので view 内扱いにする。
    // mouseEntered 未発火・順序差・window 切替後の cursor reset 復帰でも形状を反映するため（codex レビュー指摘）。
    mouseInsideView = YES;
    [self applyCursorShapeIfInside];
}

// 共通: mouse_down / mouse_up / mouse_move (button 押下中含む) を enqueue
- (void)enqueueMouseEvent:(PlatformEventType)type withButton:(PlatformMouseButton)btn from:(NSEvent*)event {
    if (!platformWindow) return;
    int32_t x, y;
    event_location_to_platform_coords(event, self, &x, &y);
    PlatformEvent ev;
    ev.type = type;
    ev.payload.mouse.x = x;
    ev.payload.mouse.y = y;
    ev.payload.mouse.button = btn;
    ev.payload.mouse.buttons_mask = pressed_buttons_mask();
    ev.payload.mouse.modifiers = extractModifiers(event.modifierFlags);

    EventQueue* q = &platformWindow->event_queue;
    if (type == PLATFORM_EVENT_MOUSE_MOVE && try_merge_mouse_move(q, &ev)) return;
    queue_push(q, &ev);
}

// scrollWheel: は別 payload なので個別実装
- (void)scrollWheel:(NSEvent *)event {
    if (!platformWindow) return;
    int32_t x, y;
    event_location_to_platform_coords(event, self, &x, &y);

    BOOL is_precise = event.hasPreciseScrollingDeltas;
    float dx = (float)event.scrollingDeltaX;
    float dy = (float)event.scrollingDeltaY;
    if (!is_precise) {
        dx *= SCROLL_LINE_TO_POINTS;
        dy *= SCROLL_LINE_TO_POINTS;
    }

    PlatformEvent ev;
    ev.type = PLATFORM_EVENT_MOUSE_SCROLL;
    ev.payload.scroll.x = x;
    ev.payload.scroll.y = y;
    ev.payload.scroll.dx = dx;
    ev.payload.scroll.dy = dy;
    ev.payload.scroll.is_precise = is_precise;
    ev.payload.scroll.buttons_mask = pressed_buttons_mask();
    ev.payload.scroll.modifiers = extractModifiers(event.modifierFlags);

    EventQueue* q = &platformWindow->event_queue;
    if (try_merge_mouse_scroll(q, &ev)) return;
    queue_push(q, &ev);
}

// mouseDown / mouseUp / mouseDragged: 左ボタン
- (void)mouseDown:(NSEvent *)event {
    [self enqueueMouseEvent:PLATFORM_EVENT_MOUSE_DOWN withButton:button_from_event(event) from:event];
}
- (void)mouseUp:(NSEvent *)event {
    [self enqueueMouseEvent:PLATFORM_EVENT_MOUSE_UP withButton:button_from_event(event) from:event];
}
- (void)mouseDragged:(NSEvent *)event {
    [self enqueueMouseEvent:PLATFORM_EVENT_MOUSE_MOVE withButton:PLATFORM_MOUSE_BUTTON_NONE from:event];
}

// rightMouseDown / rightMouseUp / rightMouseDragged
// Control+左クリックもここに流れるが、buttonNumber=0 のままなので button=LEFT として扱う
- (void)rightMouseDown:(NSEvent *)event {
    [self enqueueMouseEvent:PLATFORM_EVENT_MOUSE_DOWN withButton:button_from_event(event) from:event];
}
- (void)rightMouseUp:(NSEvent *)event {
    [self enqueueMouseEvent:PLATFORM_EVENT_MOUSE_UP withButton:button_from_event(event) from:event];
}
- (void)rightMouseDragged:(NSEvent *)event {
    [self enqueueMouseEvent:PLATFORM_EVENT_MOUSE_MOVE withButton:PLATFORM_MOUSE_BUTTON_NONE from:event];
}

// otherMouseDown / otherMouseUp / otherMouseDragged: middle (buttonNumber=2) のみ受ける、X1/X2 は無視
- (void)otherMouseDown:(NSEvent *)event {
    if (event.buttonNumber != 2) return;
    [self enqueueMouseEvent:PLATFORM_EVENT_MOUSE_DOWN withButton:PLATFORM_MOUSE_BUTTON_MIDDLE from:event];
}
- (void)otherMouseUp:(NSEvent *)event {
    if (event.buttonNumber != 2) return;
    [self enqueueMouseEvent:PLATFORM_EVENT_MOUSE_UP withButton:PLATFORM_MOUSE_BUTTON_MIDDLE from:event];
}
- (void)otherMouseDragged:(NSEvent *)event {
    if (event.buttonNumber != 2) return;
    [self enqueueMouseEvent:PLATFORM_EVENT_MOUSE_MOVE withButton:PLATFORM_MOUSE_BUTTON_NONE from:event];
}

// hover (ボタン未押下時) の移動。NSWindow.acceptsMouseMovedEvents = YES + NSTrackingArea が必要
- (void)mouseMoved:(NSEvent *)event {
    [self enqueueMouseEvent:PLATFORM_EVENT_MOUSE_MOVE withButton:PLATFORM_MOUSE_BUTTON_NONE from:event];
}

@end

// ========================================
// キーコード変換
// ========================================

// macOSのキーコードをPlatformKeyCodeに変換
// 参考: /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/Headers/Events.h
static PlatformKeyCode mapKeyCodeToPlatform(unsigned short keyCode) {
    // macOSのキーコード（ANSI配列）から標準キーコードへの変換
    switch (keyCode) {
        // 文字キー（ANSI配列）
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
        case 0x18: return PLATFORM_KEY_UNKNOWN;  // kVK_ANSI_Equal (=)
        case 0x19: return PLATFORM_KEY_9;
        case 0x1A: return PLATFORM_KEY_7;
        case 0x1B: return PLATFORM_KEY_UNKNOWN;  // kVK_ANSI_Minus (-)
        case 0x1C: return PLATFORM_KEY_8;
        case 0x1D: return PLATFORM_KEY_0;
        case 0x1E: return PLATFORM_KEY_UNKNOWN;  // kVK_ANSI_RightBracket (])
        case 0x1F: return PLATFORM_KEY_O;
        case 0x20: return PLATFORM_KEY_U;
        case 0x21: return PLATFORM_KEY_UNKNOWN;  // kVK_ANSI_LeftBracket ([)
        case 0x22: return PLATFORM_KEY_I;
        case 0x23: return PLATFORM_KEY_P;
        case 0x25: return PLATFORM_KEY_L;       // kVK_ANSI_L
        case 0x26: return PLATFORM_KEY_J;       // kVK_ANSI_J
        case 0x27: return PLATFORM_KEY_UNKNOWN;  // kVK_ANSI_Quote (')
        case 0x28: return PLATFORM_KEY_K;       // kVK_ANSI_K
        case 0x29: return PLATFORM_KEY_UNKNOWN;  // kVK_ANSI_Semicolon (;)
        case 0x2A: return PLATFORM_KEY_UNKNOWN;  // kVK_ANSI_Backslash (\)
        case 0x2B: return PLATFORM_KEY_UNKNOWN;  // kVK_ANSI_Comma (,)
        case 0x2C: return PLATFORM_KEY_UNKNOWN;  // kVK_ANSI_Slash (/)
        case 0x2D: return PLATFORM_KEY_N;       // kVK_ANSI_N
        case 0x2E: return PLATFORM_KEY_M;       // kVK_ANSI_M
        case 0x2F: return PLATFORM_KEY_UNKNOWN;  // kVK_ANSI_Period (.)
        case 0x30: return PLATFORM_KEY_TAB;     // kVK_Tab
        case 0x31: return PLATFORM_KEY_SPACE;   // kVK_Space
        case 0x32: return PLATFORM_KEY_UNKNOWN;  // kVK_ANSI_Grave (`)
        case 0x33: return PLATFORM_KEY_BACKSPACE; // kVK_Delete

        // Return/Enter
        case 0x24: return PLATFORM_KEY_ENTER;   // kVK_Return

        // Escape
        case 0x35: return PLATFORM_KEY_ESCAPE;  // kVK_Escape

        // モディファイアキー（左）
        case 0x38: return PLATFORM_KEY_LEFT_SHIFT;      // kVK_Shift
        case 0x3A: return PLATFORM_KEY_LEFT_ALT;        // kVK_Option
        case 0x3B: return PLATFORM_KEY_LEFT_CONTROL;    // kVK_Control
        case 0x37: return PLATFORM_KEY_LEFT_SUPER;      // kVK_Command
        case 0x39: return PLATFORM_KEY_CAPS_LOCK;       // kVK_CapsLock

        // モディファイアキー（右）
        case 0x3C: return PLATFORM_KEY_RIGHT_SHIFT;     // kVK_RightShift
        case 0x3D: return PLATFORM_KEY_RIGHT_ALT;       // kVK_RightOption
        case 0x3E: return PLATFORM_KEY_RIGHT_CONTROL;   // kVK_RightControl
        case 0x36: return PLATFORM_KEY_RIGHT_SUPER;     // kVK_RightCommand

        // ファンクションキー
        case 0x7A: return PLATFORM_KEY_F1;              // kVK_F1
        case 0x78: return PLATFORM_KEY_F2;              // kVK_F2
        case 0x63: return PLATFORM_KEY_F3;              // kVK_F3
        case 0x76: return PLATFORM_KEY_F4;              // kVK_F4
        case 0x60: return PLATFORM_KEY_F5;              // kVK_F5
        case 0x61: return PLATFORM_KEY_F6;              // kVK_F6
        case 0x62: return PLATFORM_KEY_F7;              // kVK_F7
        case 0x64: return PLATFORM_KEY_F8;              // kVK_F8
        case 0x65: return PLATFORM_KEY_F9;              // kVK_F9
        case 0x6D: return PLATFORM_KEY_F10;             // kVK_F10
        case 0x67: return PLATFORM_KEY_F11;             // kVK_F11
        case 0x6F: return PLATFORM_KEY_F12;             // kVK_F12
        case 0x69: return PLATFORM_KEY_F13;             // kVK_F13
        case 0x6B: return PLATFORM_KEY_F14;             // kVK_F14
        case 0x71: return PLATFORM_KEY_F15;             // kVK_F15
        case 0x6A: return PLATFORM_KEY_F16;             // kVK_F16
        case 0x40: return PLATFORM_KEY_F17;             // kVK_F17
        case 0x4F: return PLATFORM_KEY_F18;             // kVK_F18
        case 0x50: return PLATFORM_KEY_F19;             // kVK_F19
        case 0x5A: return PLATFORM_KEY_F20;             // kVK_F20

        // 編集キー
        case 0x72: return PLATFORM_KEY_INSERT;          // kVK_Help
        case 0x73: return PLATFORM_KEY_HOME;            // kVK_Home
        case 0x74: return PLATFORM_KEY_PAGE_UP;         // kVK_PageUp
        case 0x75: return PLATFORM_KEY_DELETE;          // kVK_ForwardDelete
        case 0x77: return PLATFORM_KEY_END;             // kVK_End
        case 0x79: return PLATFORM_KEY_PAGE_DOWN;       // kVK_PageDown

        // 矢印キー
        case 0x7B: return PLATFORM_KEY_LEFT;            // kVK_LeftArrow
        case 0x7C: return PLATFORM_KEY_RIGHT;           // kVK_RightArrow
        case 0x7D: return PLATFORM_KEY_DOWN;            // kVK_DownArrow
        case 0x7E: return PLATFORM_KEY_UP;              // kVK_UpArrow

        // テンキー
        case 0x52: return PLATFORM_KEY_KP_0;            // kVK_ANSI_Keypad0
        case 0x53: return PLATFORM_KEY_KP_1;            // kVK_ANSI_Keypad1
        case 0x54: return PLATFORM_KEY_KP_2;            // kVK_ANSI_Keypad2
        case 0x55: return PLATFORM_KEY_KP_3;            // kVK_ANSI_Keypad3
        case 0x56: return PLATFORM_KEY_KP_4;            // kVK_ANSI_Keypad4
        case 0x57: return PLATFORM_KEY_KP_5;            // kVK_ANSI_Keypad5
        case 0x58: return PLATFORM_KEY_KP_6;            // kVK_ANSI_Keypad6
        case 0x59: return PLATFORM_KEY_KP_7;            // kVK_ANSI_Keypad7
        case 0x5B: return PLATFORM_KEY_KP_8;            // kVK_ANSI_Keypad8
        case 0x5C: return PLATFORM_KEY_KP_9;            // kVK_ANSI_Keypad9
        case 0x41: return PLATFORM_KEY_KP_DECIMAL;      // kVK_ANSI_KeypadDecimal
        case 0x4B: return PLATFORM_KEY_KP_DIVIDE;       // kVK_ANSI_KeypadDivide
        case 0x43: return PLATFORM_KEY_KP_MULTIPLY;     // kVK_ANSI_KeypadMultiply
        case 0x4E: return PLATFORM_KEY_KP_SUBTRACT;     // kVK_ANSI_KeypadMinus
        case 0x45: return PLATFORM_KEY_KP_ADD;          // kVK_ANSI_KeypadPlus
        case 0x4C: return PLATFORM_KEY_KP_ENTER;        // kVK_ANSI_KeypadEnter
        case 0x51: return PLATFORM_KEY_KP_EQUAL;        // kVK_ANSI_KeypadEquals

        default: return PLATFORM_KEY_UNKNOWN;
    }
}

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
                                       NSWindowStyleMaskMiniaturizable |
                                       NSWindowStyleMaskResizable; // TASK-23: 自由リサイズ

        platformWindow->window = [[NSWindow alloc] initWithContentRect:frame
                                                             styleMask:styleMask
                                                               backing:NSBackingStoreBuffered
                                                                 defer:NO];

        [platformWindow->window setTitle:[NSString stringWithUTF8String:title]];

        // hover の mouseMoved: を受け取るために必須 (TASK-21.1)
        [platformWindow->window setAcceptsMouseMovedEvents:YES];

        // カスタムビューを作成して設定
        platformWindow->view = [[FramebufferView alloc] initWithFrame:frame
                                                               width:width
                                                              height:height
                                                            callback:callback
                                                            userdata:userdata
                                                     platformWindow:platformWindow];
        [platformWindow->window setContentView:platformWindow->view];
        // setContentView 後に updateTrackingAreas を呼ぶ (view の bounds が確定したタイミングで TrackingArea を構築)
        [platformWindow->view updateTrackingAreas];

        // ウィンドウを表示
        [platformWindow->window center];
        [platformWindow->window makeKeyAndOrderFront:nil];
        // IME: view を first responder にして inputContext / interpretKeyEvents が効くようにする（TASK-79.6.1）
        [platformWindow->window makeFirstResponder:platformWindow->view];
        [app activateIgnoringOtherApps:YES];

        // CADisplayLinkを開始
        [platformWindow->view startDisplayLink];
    }

#if defined(VP_ENABLE_GAMEPAD)
    // ゲームパッド: このwindowをアクティブにし、既接続コントローラを取り込む (TASK-80.2)
    gamepadAttachWindow(platformWindow);
#endif

    return platformWindow;
}

// TASK-100.1: 既存ウィンドウをネイティブフルスクリーン化する（緑ボタンと同じ toggleFullScreen:）。
// titled+resizable window は既定でフルスクリーン可だが、念のため collectionBehavior に
// FullScreenPrimary を立ててから toggle する。既にフルスクリーンなら no-op（二重 toggle 防止）。
void platform_enter_fullscreen(PlatformWindow* window) {
    if (!window) return;
    @autoreleasepool {
        NSWindow* w = window->window;
        if (!w) return;
        if (!([w collectionBehavior] & NSWindowCollectionBehaviorFullScreenPrimary)) {
            [w setCollectionBehavior:[w collectionBehavior] | NSWindowCollectionBehaviorFullScreenPrimary];
        }
        if (!([w styleMask] & NSWindowStyleMaskFullScreen)) {
            [w toggleFullScreen:nil];
        }
    }
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

#if defined(VP_ENABLE_GAMEPAD)
    // ゲームパッド: このwindowがアクティブなら参照を外す (TASK-80.2)
    gamepadDetachWindow(platformWindow);
#endif

    @autoreleasepool {
        // 1. view の back-reference を無効化 (以降の mouseDown: 等は早期 return)
        [platformWindow->view clearPlatformWindow];

        // 2. CADisplayLink を停止 (callback から view への参照を断つ)
        [platformWindow->view stopDisplayLink];

        // 3. window を閉じる → NSWindow が contentView (view) を release
        [platformWindow->window close];
    }

    // 4. PlatformWindow 自体を解放
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
                PlatformEvent platform_event;
                memset(&platform_event, 0, sizeof(platform_event));
                platform_event.type = (event.type == NSEventTypeKeyDown)
                    ? PLATFORM_EVENT_KEY_DOWN
                    : PLATFORM_EVENT_KEY_UP;
                platform_event.payload.keyboard.key = mapKeyCodeToPlatform(event.keyCode);
                platform_event.payload.keyboard.is_repeat = event.isARepeat;
                platform_event.payload.keyboard.modifiers = extractModifiers(event.modifierFlags);
                queue_push(&platformWindow->event_queue, &platform_event);

                // keyDown: 物理 key_down を積んだ後 IME/inputContext 経路へ（TASK-79.6.1）。
                // insertText: が char_input の唯一の生成元。旧 event.characters 直読みは廃止
                // （二重入力・IME 迂回防止）。sendEvent は呼ばない（ビープは doCommandBySelector で吸収）。
                if (event.type == NSEventTypeKeyDown && platformWindow->view) {
                    [platformWindow->view interpretKeyEvents:@[event]];
                }

                // キーイベントは処理済みなので、システムに渡さない（ビープ音を防ぐ）
                continue;
            }

            [app sendEvent:event];
            [app updateWindows];
        }

        // ウィンドウが閉じられているか確認
        if (![platformWindow->window isVisible]) {
            // QUITイベントをキューに追加
            PlatformEvent quit_event;
            quit_event.type = PLATFORM_EVENT_QUIT;
            queue_push(&platformWindow->event_queue, &quit_event);
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

// カーソル形状を設定する (TASK-75.1)。未知値は PLATFORM_CURSOR_DEFAULT にフォールバックする。
void platform_set_cursor(PlatformWindow* platformWindow, int shape) {
    if (!platformWindow) return;

    PlatformCursorShape s;
    switch (shape) {
        case PLATFORM_CURSOR_CROSSHAIR: s = PLATFORM_CURSOR_CROSSHAIR; break;
        case PLATFORM_CURSOR_HIDDEN:    s = PLATFORM_CURSOR_HIDDEN; break;
        default:                        s = PLATFORM_CURSOR_DEFAULT; break;
    }

    @autoreleasepool {
        [platformWindow->view setCursorShape:s];
    }
}

// ライブリサイズ再描画コールバック登録 (TASK-23.1)。cb==NULL で解除。
void platform_set_redraw_callback(PlatformWindow* platformWindow, PlatformRedrawCallback cb, void* userdata) {
    if (!platformWindow) return;
    @autoreleasepool {
        [platformWindow->view setRedrawCallback:cb userdata:userdata];
    }
}

// IME composition preedit snapshot（TASK-79.6.1）
uint32_t platform_get_composition_snapshot(PlatformWindow* window, char* buf, uint32_t cap, PlatformCompositionMeta* meta) {
    if (meta) {
        meta->revision = 0;
        meta->cursor = 0;
        meta->len = 0;
    }
    if (!window || !window->view) return 0;
    return [window->view copyCompositionSnapshot:buf cap:cap meta:meta];
}

// イベントキューカウンタの snapshot 取得 (TASK-21.1)
void platform_get_event_stats(PlatformWindow* window, PlatformEventStats* out) {
    if (!window || !out) return;
    EventQueue* q = &window->event_queue;
    out->mouse_move_merge_count = q->mouse_move_merge_count;
    out->mouse_scroll_merge_count = q->mouse_scroll_merge_count;
    out->event_drop_count = q->event_drop_count;
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

// ========================================
// ゲームパッド入力 (TASK-80.2。ADR-009)
// ========================================
//
// opt-in（TASK-80.2 opt-in 化）: `platform_get_gamepad_state` は platform.h で常時宣言されるため
// シンボル自体は non-opt-in exe でも定義する必要がある。GameController 型を一切参照しない
// always-false fallback を #else 側に用意し、リンクエラーの可能性を Zig 側の dead-code-elimination
// 頼みにしない（防御的設計）。
#if defined(VP_ENABLE_GAMEPAD)
//
// GCExtendedGamepad.buttonA/B/X/Y は Apple が「物理位置ベース」で既に正規化済み
// （Nintendo 系コントローラの A/B・X/Y 入替も GameController framework 側で吸収される。
// Apple公式ドキュメント: "refer to conceptual roles based on physical position, similar to
// Xbox layout"）ため、本実装は 1:1 マッピングするだけで良い。stick の Y 軸は GameController の
// raw 値（上入力 = +1）をそのまま渡す（screen 座標へのフリップは consumer 責務。ADR-009 の
// raw値契約を継承）。
//
// ホットパス宣言: フレーム毎に呼ばれる想定だが 4台×少数フィールドの固定長 copy
// （alloc/lock 無し）で全画素ループでも RT でもないため性能規約の適用対象外（ADR-009 参照）。
bool platform_get_gamepad_state(PlatformWindow* window, int index, PlatformGamepadState* out_state) {
    (void)window;
    if (!out_state || index < 0 || index >= PLATFORM_MAX_GAMEPADS) return false;
    GCController* controller = g_gamepad_slots[index];
    if (!controller) return false;
    GCExtendedGamepad* pad = controller.extendedGamepad;
    if (!pad) return false; // 接続後に非対応プロファイルへ変化した場合の防御（通常発生しない）

    uint32_t mask = 0;
    if (pad.buttonA.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_A;
    if (pad.buttonB.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_B;
    if (pad.buttonX.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_X;
    if (pad.buttonY.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_Y;
    if (pad.leftShoulder.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_LEFT_SHOULDER;
    if (pad.rightShoulder.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_RIGHT_SHOULDER;
    if (pad.buttonMenu.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_START;
    if (pad.buttonOptions.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_BACK; // nullable。nilメッセージングでfalse
    if (pad.leftThumbstickButton.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_LEFT_STICK; // nullable
    if (pad.rightThumbstickButton.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_RIGHT_STICK; // nullable
    if (pad.dpad.up.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_DPAD_UP;
    if (pad.dpad.down.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_DPAD_DOWN;
    if (pad.dpad.left.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_DPAD_LEFT;
    if (pad.dpad.right.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_DPAD_RIGHT;
    if (pad.buttonHome.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_GUIDE; // nullable

    out_state->buttons_mask = mask;
    out_state->left_stick_x = pad.leftThumbstick.xAxis.value;
    out_state->left_stick_y = pad.leftThumbstick.yAxis.value;
    out_state->right_stick_x = pad.rightThumbstick.xAxis.value;
    out_state->right_stick_y = pad.rightThumbstick.yAxis.value;
    out_state->left_trigger = pad.leftTrigger.value;
    out_state->right_trigger = pad.rightTrigger.value;
    return true;
}
#else
bool platform_get_gamepad_state(PlatformWindow* window, int index, PlatformGamepadState* out_state) {
    (void)window;
    (void)index;
    (void)out_state;
    return false; // opt-in 無効（TASK-80.2 opt-in 化。GameController型を一切参照しない）
}
#endif // VP_ENABLE_GAMEPAD

// ========================================
// ファイル選択ダイアログ (TASK-24)
// ========================================
// 拡張子フィルタは allowedContentTypes (UTType) を使う（macOS 11+ 専用。allowedFileTypes は
// macOS 12 で deprecated なため移行。UniformTypeIdentifiers framework をリンクする）。
// 未知拡張子で UTType が nil の場合はフィルタ未設定（全許可）にフォールバックする。
// fileSystemRepresentation は autorelease プール生存中のみ有効なので、その場で strdup する。

char* platform_save_file_dialog(const PlatformSaveDialogOptions* opts) {
    @autoreleasepool {
        NSSavePanel* panel = [NSSavePanel savePanel];
        if (opts) {
            if (opts->allowed_ext) {
                UTType* type = [UTType typeWithFilenameExtension:[NSString stringWithUTF8String:opts->allowed_ext]];
                if (type) {
                    panel.allowedContentTypes = @[ type ];
                }
            }
            if (opts->default_name) {
                panel.nameFieldStringValue = [NSString stringWithUTF8String:opts->default_name];
            }
        }
        if ([panel runModal] != NSModalResponseOK) return NULL;
        NSURL* url = [panel URL];
        if (!url) return NULL;
        const char* path = [url fileSystemRepresentation];
        if (!path) return NULL;
        return strdup(path);
    }
}

char* platform_open_file_dialog(const PlatformOpenDialogOptions* opts) {
    @autoreleasepool {
        NSOpenPanel* panel = [NSOpenPanel openPanel];
        panel.canChooseFiles = YES;
        panel.canChooseDirectories = NO;
        panel.allowsMultipleSelection = NO;
        if (opts && opts->allowed_ext) {
            UTType* type = [UTType typeWithFilenameExtension:[NSString stringWithUTF8String:opts->allowed_ext]];
            if (type) {
                panel.allowedContentTypes = @[ type ];
            }
        }
        if ([panel runModal] != NSModalResponseOK) return NULL;
        NSURL* url = [panel URL];
        if (!url) return NULL;
        const char* path = [url fileSystemRepresentation];
        if (!path) return NULL;
        return strdup(path);
    }
}

void platform_free_path(char* path) {
    if (path) free(path);
}
