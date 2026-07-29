#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#if defined(KNGN_ENABLE_GAMEPAD)
#import <GameController/GameController.h>
#endif
#include "platform.h"
#if defined(KNGN_ENABLE_MENU)
#include "macos/platform_macos_menu.h"
#endif
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <time.h>

// The CALayer-optimised implementation
#define IMPLEMENTATION_TYPE "CALayer Optimized"

// Forward declarations
@class FramebufferView;

// ========================================
// The event queue and PlatformWindow definitions (referenced from FramebufferView's @implementation)
// ========================================

#define EVENT_QUEUE_SIZE 256

// Extract the modifier keys
static uint32_t extractModifiers(NSEventModifierFlags nsModifiers) {
    uint32_t mods = 0;
    if (nsModifiers & NSEventModifierFlagShift)   mods |= PLATFORM_MOD_SHIFT;
    if (nsModifiers & NSEventModifierFlagControl) mods |= PLATFORM_MOD_CTRL;
    if (nsModifiers & NSEventModifierFlagOption)  mods |= PLATFORM_MOD_ALT;
    if (nsModifiers & NSEventModifierFlagCommand) mods |= PLATFORM_MOD_CMD;
    return mods;
}

// The event queue struct
typedef struct {
    int index;
    uint32_t generation;
    bool valid;
} EventQueueToken;

typedef struct {
    PlatformEvent events[EVENT_QUEUE_SIZE];
    uint32_t slot_generation[EVENT_QUEUE_SIZE];
    int head;  // where the next write goes
    int tail;  // where the next read comes from
    // observation counters (cumulative; the examples watch the difference)
    uint64_t mouse_move_merge_count;
    uint64_t mouse_scroll_merge_count;
    uint64_t event_drop_count;
} EventQueue;

// The platform window struct
struct PlatformWindow {
    NSWindow* window;
    FramebufferView* view;
    EventQueue event_queue;
    __strong id quit_delegate;
    bool quit_requested;
};

// Forward declaration (defined below, after the mouse input helpers; used by the gamepad connect/disconnect handlers).
static EventQueueToken queue_push(EventQueue* q, const PlatformEvent* ev);
static bool queue_mark_none(EventQueue* q, EventQueueToken token);

// The close button does not close the native window but passes a quit request to the consumer.
@interface QuitWindowDelegate : NSObject <NSWindowDelegate>
@property(nonatomic, assign) PlatformWindow* platformWindow;
@end

@implementation QuitWindowDelegate
- (BOOL)windowShouldClose:(NSWindow*)sender {
    (void)sender;
    PlatformWindow* window = self.platformWindow;
    if (!window) return YES;
    if (window->quit_requested) return NO;
    window->quit_requested = true;
    PlatformEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = PLATFORM_EVENT_QUIT;
    queue_push(&window->event_queue, &ev);
    return NO;
}
@end

static bool g_key_trace_enabled = false;
static bool g_ime_trace_enabled = false;

static void key_trace(const char* fmt, ...) {
    if (!g_key_trace_enabled) return;
    va_list args;
    va_start(args, fmt);
    fprintf(stderr, "[key-trace] ");
    vfprintf(stderr, fmt, args);
    fputc('\n', stderr);
    va_end(args);
}

// Diagnostics: a trace of IME and document access as it happens (off by default; KNGN_IME_TRACE=1 enables it).
static void ime_trace(const char* fmt, ...) {
    if (!g_ime_trace_enabled) return;
    va_list args;
    va_start(args, fmt);
    fprintf(stderr, "[ime-trace] ");
    vfprintf(stderr, fmt, args);
    fputc('\n', stderr);
    va_end(args);
}

static void ime_range_desc(NSRange r, char* out, size_t cap) {
    if (!out || cap == 0) return;
    if (r.location == NSNotFound) {
        snprintf(out, cap, "{NSNotFound,%lu}", (unsigned long)r.length);
    } else {
        snprintf(out, cap, "{%lu,%lu}", (unsigned long)r.location, (unsigned long)r.length);
    }
}

static void ime_preview_utf8(const char* s, char* out, size_t cap) {
    if (!out || cap == 0) return;
    if (!s) { out[0] = '\0'; return; }
    // Roughly the first 20 characters (a crude limit in UTF-8 bytes, for diagnostics).
    size_t n = strlen(s);
    if (n > 60) n = 60;
    if (n >= cap) n = cap - 1;
    memcpy(out, s, n);
    out[n] = '\0';
}

// ========================================
// Gamepad input (ADR-009)
// ========================================
//
// Opt-in: the GameController framework uses the same opt-in linking as audio, and only an executable
// that uses a gamepad (examples/22_gamepad) gets `-DKNGN_ENABLE_GAMEPAD` from build.zig
// (see compilePlatformLayer in build_helpers/platform.zig). In an executable without the opt-in this
// whole block is not compiled and no GameController symbol is referenced at all (nor shown by `otool -L`).
#if defined(KNGN_ENABLE_GAMEPAD)
//
// Holds the mapping from GCController to an index (0..PLATFORM_MAX_GAMEPADS-1). Under ARC a strong
// array is fine (the GameController framework retains the GCController itself while it is connected).
// A single window is assumed (as in the rest of the code), so a connect/disconnect event is pushed
// onto the event_queue of the "currently active window" (the window created last).

static GCController* g_gamepad_slots[PLATFORM_MAX_GAMEPADS];
static PlatformWindow* g_gamepad_event_window = NULL;
static BOOL g_gamepad_observers_installed = NO;

// The slot index of a tracked controller, or -1 when it is not tracked.
static int gamepadFindSlot(GCController* controller) {
    for (int i = 0; i < PLATFORM_MAX_GAMEPADS; i++) {
        if (g_gamepad_slots[i] == controller) return i;
    }
    return -1;
}

// The index of a free slot, or -1 when there is none (anything over the limit is ignored).
static int gamepadFindFreeSlot(void) {
    for (int i = 0; i < PLATFORM_MAX_GAMEPADS; i++) {
        if (g_gamepad_slots[i] == nil) return i;
    }
    return -1;
}

// Copy a UTF-8 string, truncated, into PlatformEvent.payload.gamepad.name (a fixed 32 bytes plus NUL).
static void gamepadCopyName(PlatformEvent* ev, NSString* name) {
    memset(ev->payload.gamepad.name, 0, sizeof(ev->payload.gamepad.name));
    const char* utf8 = [name UTF8String];
    if (!utf8) return;
    strncpy(ev->payload.gamepad.name, utf8, sizeof(ev->payload.gamepad.name) - 1);
}

// Take in a GCController connection. Anything without extendedGamepad (a micro gamepad, say), already tracked, or over the limit is ignored.
static void gamepadHandleConnect(GCController* controller) {
    if (!controller.extendedGamepad) return; // not the standard layout, so out of scope
    if (gamepadFindSlot(controller) >= 0) return; // already tracked (defensive)
    if (!g_gamepad_event_window) return; // no window has been created yet
    int idx = gamepadFindFreeSlot();
    if (idx < 0) return; // more than PLATFORM_MAX_GAMEPADS pads
    g_gamepad_slots[idx] = controller;

    PlatformEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = PLATFORM_EVENT_GAMEPAD_CONNECTED;
    ev.payload.gamepad.index = idx;
    gamepadCopyName(&ev, controller.vendorName ?: @"Gamepad");
    queue_push(&g_gamepad_event_window->event_queue, &ev);
}

// Take in a GCController disconnection. An untracked one is ignored.
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

// Install the GCControllerDidConnect/DidDisconnect notification observers exactly once per process.
// [NSOperationQueue mainQueue] is passed explicitly to force delivery on the main thread (with
// queue:nil the observer runs synchronously on whichever thread posted the notification, which
// guarantees nothing). That keeps writes to event_queue and g_gamepad_slots on the same thread as
// pollEvents and the rest of the main thread path, so there is no race even without a lock.
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

// Switch the "active window" as windows are created and destroyed. A slot inherited from another
// window (a controller that connected while the previous window was alive) has its connected event
// resent to the new window, and an untracked controller is taken in by the ordinary connect path
// (without this, a controller that was already connected gets no connected event on the new window).
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
        gamepadHandleConnect(controller); // only an untracked one is really processed (gamepadFindSlot skips the rest)
    }
}

static void gamepadDetachWindow(PlatformWindow* window) {
    if (g_gamepad_event_window == window) {
        g_gamepad_event_window = NULL;
    }
}
#endif // KNGN_ENABLE_GAMEPAD

#if defined(KNGN_ENABLE_MENU)
// The bridge from the shared menu TU. Pushes a MENU_COMMAND onto the objc EventQueue.
void platform_menu_enqueue_command(PlatformWindow* window, uint32_t command_id) {
    if (!window) return;
    PlatformEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = PLATFORM_EVENT_MENU_COMMAND;
    ev.payload.menu.command_id = command_id;
    queue_push(&window->event_queue, &ev);
}
#endif

// ========================================
// Mouse input helpers
// ========================================

// The line→points factor for a non-precise scroll (a rule of thumb)
// It can be tuned while watching the log in example_07.
static const float SCROLL_LINE_TO_POINTS = 16.0f;

// A pointer to the newest event at the tail of the queue, or NULL when it is empty.
static PlatformEvent* queue_peek_tail(EventQueue* q) {
    if (q->head == q->tail) return NULL;
    int prev = (q->head - 1 + EVENT_QUEUE_SIZE) % EVENT_QUEUE_SIZE;
    return &q->events[prev];
}

// Merge a mouse_move into the tail (only when buttons_mask and modifiers match). True once merged.
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

// Merge a mouse_scroll into the tail (only when is_precise, buttons_mask and modifiers match). True once merged.
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

// Push onto the queue (when full, bump the drop counter and discard). Returns the slot token on success.
static EventQueueToken queue_push(EventQueue* q, const PlatformEvent* ev) {
    EventQueueToken invalid = { .index = -1, .generation = 0, .valid = false };
    int next_head = (q->head + 1) % EVENT_QUEUE_SIZE;
    if (next_head == q->tail) {
        q->event_drop_count++;
        return invalid;
    }
    const int index = q->head;
    q->slot_generation[index] += 1;
    q->events[index] = *ev;
    q->head = next_head;
    return (EventQueueToken){ .index = index, .generation = q->slot_generation[index], .valid = true };
}

static bool queue_mark_none(EventQueue* q, EventQueueToken token) {
    if (!token.valid || token.index < 0 || token.index >= EVENT_QUEUE_SIZE) return false;
    if (q->slot_generation[token.index] != token.generation) return false;
    if (q->events[token.index].type != PLATFORM_EVENT_KEY_DOWN) return false;
    q->events[token.index].type = PLATFORM_EVENT_NONE;
    return true;
}

// Convert an NSEvent's locationInWindow into raw physical pixels with the origin at the view's top-left (floored to an integer).
// scale is the current native backing scale. Negative values and positions outside the window are not clamped.
static void event_location_to_platform_raw_coords(NSEvent* event, NSView* view, CGFloat scale, int32_t* out_x, int32_t* out_y) {
    NSPoint windowPt = event.locationInWindow;
    NSPoint viewPt = [view convertPoint:windowPt fromView:nil];
    CGFloat viewHeight = view.bounds.size.height;
    CGFloat s = (scale > 0.0) ? scale : 1.0;
    *out_x = (int32_t)floor(viewPt.x * s);
    *out_y = (int32_t)floor((viewHeight - viewPt.y) * s);  // flip Y
}

// The bitmask of the buttons currently held (& 0x07 excludes X1/X2).
static uint8_t pressed_buttons_mask(void) {
    return (uint8_t)([NSEvent pressedMouseButtons] & 0x07);
}

// From NSEvent.buttonNumber to PlatformMouseButton (by physical button).
// Control plus a left click also keeps buttonNumber=0, so button=LEFT.
static PlatformMouseButton button_from_event(NSEvent* event) {
    switch (event.buttonNumber) {
        case 0: return PLATFORM_MOUSE_BUTTON_LEFT;
        case 1: return PLATFORM_MOUSE_BUTTON_RIGHT;
        case 2: return PLATFORM_MOUSE_BUTTON_MIDDLE;
        default: return PLATFORM_MOUSE_BUTTON_NONE;
    }
}

// ========================================
// The CALayer-optimised implementation
// ========================================

// The fixed buffer for an IME composition (the preedit, as UTF-8)
#define COMPOSITION_UTF8_CAP 1024

/// The longest prefix of s[0..len] that fits within cap bytes and ends on a UTF-8 code point boundary.
/// Past cap this avoids cutting inside a continuation byte (0b10xxxxxx), keeping only whole code points.
static size_t utf8SafePrefixLen(const char* s, size_t len, size_t cap) {
    size_t i = 0;
    while (i < len && i < cap) {
        const unsigned char c = (unsigned char)s[i];
        size_t need;
        if ((c & 0x80) == 0) need = 1;
        else if ((c & 0xE0) == 0xC0) need = 2;
        else if ((c & 0xF0) == 0xE0) need = 3;
        else if ((c & 0xF8) == 0xF0) need = 4;
        else break; // an invalid lead byte: stop before it
        if (i + need > cap || i + need > len) break;
        i += need;
    }
    return i;
}

// A custom NSView: fast CALayer-based drawing plus NSTextInputClient (the IME)
@interface FramebufferView : NSView <NSTextInputClient, NSDraggingDestination> {
    int width;   // the framebuffer pixel width (equal to the logical one under .logical)
    int height;  // framebuffer pixel height
    int logicalWidth;
    int logicalHeight;
    BOOL physicalMode;
    CGFloat contentScale;        // latched (committed by lock; used by present and the lock snapshot)
    CGFloat pendingContentScale; // the detected current negotiated scale (for a metrics query and for raw input)
    uint64_t scaleEpoch;         // the latched epoch, incremented only atomically with the buffer and scale
    BOOL hasPendingResize;
    int pendingLogicalWidth;
    int pendingLogicalHeight;
    CADisplayLink* displayLink;
    FrameCallback callback;
    void* userdata;

    // Double buffering (by swapping pointers)
    uint32_t* buffer0;
    uint32_t* buffer1;
    uint32_t* currentBuffer;  // the buffer the callback writes into
    uint32_t* displayBuffer;  // the buffer currently on screen

    // the layer
    CALayer* contentLayer;

    // the CG objects (created at initialisation and reused)
    CGColorSpaceRef colorSpace;
    CGDataProviderRef provider0;
    CGDataProviderRef provider1;

    // performance measurement
    CFAbsoluteTime lastFrameTime;
    int frameCount;
    double totalFrameTime;

    // for mouse events
    PlatformWindow* platformWindow;  // an unowned raw pointer, set to NULL on destroy
    NSTrackingArea* trackingArea;

    // for cursor control
    PlatformCursorShape currentCursorShape;  // the most recently requested shape (PLATFORM_CURSOR_DEFAULT by default)
    BOOL cursorHiddenByThisView;             // whether this view owns the [NSCursor hide] (the API is a global reference count, so it must not be called twice)
    BOOL mouseInsideView;                    // whether the mouse is inside the view right now (set and hide are held back while it is outside)

    // live-resize redraw, distinct from FrameCallback. NULL while nothing is registered.
    PlatformRedrawCallback redrawCallback;
    void* redrawUserdata;

    // The IME composition state. The text comes from the snapshot API, a change from PLATFORM_EVENT_COMPOSITION.
    NSMutableString* markedText;
    NSRange imeSelectedRange; // the selection within markedText (in UTF-16 units)

    // Text input focus control. While imeControlled=NO everything goes through the IME as before
    // (backwards compatible). Once the application calls platform_set_text_input_active even once,
    // controlled becomes YES and from then on keyDown reaches the inputContext only while imeActive.
    BOOL imeControlled;
    BOOL imeActive;
    char compositionUtf8[COMPOSITION_UTF8_CAP];
    uint32_t compositionLen;
    uint32_t compositionRevision;
    uint32_t compositionCursor; // the UTF-8 byte offset within the preedit
    NSRect compositionRectPixels; // framebuffer pixels, origin at the content's top-left
    BOOL compositionRectSet;

    // IME document access. With no callback registered it stays NSNotFound/nil/char_input, as before.
    PlatformTextInputDocumentCallbacks docAccessCallbacks;
    void* docAccessUserdata;
    BOOL docAccessEnabled;
    BOOL hasPendingReplacement;
    NSRange pendingReplacement;

    // Transparent windows, click-through and interactive dragging
    BOOL transparentMode;      // YES makes the CGImage premultiplied alpha and honours the framebuffer alpha
    BOOL clickThrough;         // YES lets a click over a transparent pixel fall through to what is behind (per pixel)
    BOOL clickThroughState;    // the ignoresMouseEvents value set most recently (cached so it is only reapplied when it changes)
    NSEvent* lastMouseDownEvent; // the most recent left-button mouse-down (retained for beginDrag; consumed one-shot)
}
- (id)initWithFrame:(NSRect)frame width:(int)w height:(int)h
           callback:(FrameCallback)cb userdata:(void*)ud
     platformWindow:(PlatformWindow*)pw
       physicalMode:(BOOL)physical;
- (void)startDisplayLink;
- (void)stopDisplayLink;
- (void)displayLinkFired:(CADisplayLink*)link;
- (void)dealloc;

// The accessors for manual drawing
- (int)getWidth;
- (int)getHeight;
- (uint32_t*)getCurrentBuffer;
- (void)presentManual;

// Called on destroy. Invalidates the view's back-reference.
- (void)clearPlatformWindow;

// Set the cursor shape. Called from platform_set_cursor.
- (void)setCursorShape:(PlatformCursorShape)shape;

// Register the live-resize redraw callback. cb==NULL unregisters.
- (void)setRedrawCallback:(PlatformRedrawCallback)cb userdata:(void*)ud;

// the composition snapshot (called from platform_get_composition_snapshot)
- (uint32_t)copyCompositionSnapshot:(char*)buf cap:(uint32_t)cap meta:(PlatformCompositionMeta*)meta;
- (void)setCompositionRectPixelsX:(int32_t)x y:(int32_t)y w:(int32_t)w h:(int32_t)h;

// IME document access. callbacks==NULL unregisters.
- (void)setTextInputDocumentAccess:(const PlatformTextInputDocumentCallbacks*)callbacks userdata:(void*)ud;

// transparent window support
- (void)setTransparentMode:(BOOL)on;
- (void)setClickThrough:(BOOL)on;
- (void)refreshClickThrough;
- (NSEvent *)takeLastMouseDownEvent;

// scale latch and metrics
// fillMetrics:forQuery: YES = the current query (the pending scale), NO = the latched snapshot (after a lock)
- (void)fillMetrics:(PlatformFramebufferMetrics*)out forQuery:(BOOL)forQuery;
- (void)applyLatchedMetricsIfNeeded;
- (CGFloat)nativeEventScale;
- (void)refreshPendingContentScale;

@end

@implementation FramebufferView

- (id)initWithFrame:(NSRect)frame width:(int)w height:(int)h
           callback:(FrameCallback)cb userdata:(void*)ud
     platformWindow:(PlatformWindow*)pw
       physicalMode:(BOOL)physical {
    self = [super initWithFrame:frame];
    if (self) {
        physicalMode = physical;
        logicalWidth = w;
        logicalHeight = h;
        hasPendingResize = NO;
        pendingLogicalWidth = w;
        pendingLogicalHeight = h;
        scaleEpoch = 0;
        // The initial scale: no window is attached yet, so mainScreen is used. Unavailable or unsupported gives 1.0.
        CGFloat scale = 1.0;
        NSScreen* screen = [NSScreen mainScreen];
        if (screen) {
            scale = screen.backingScaleFactor;
            if (scale <= 0.0) scale = 1.0;
        }
        contentScale = scale;
        pendingContentScale = scale;

        int fw = w;
        int fh = h;
        if (physicalMode) {
            fw = (int)lround((double)w * (double)scale);
            fh = (int)lround((double)h * (double)scale);
            if (fw < 1) fw = 1;
            if (fh < 1) fh = 1;
        }
        width = fw;
        height = fh;
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
        imeControlled = NO;   // uncontrolled: everything goes through the IME, as before
        imeActive = NO;
        compositionLen = 0;
        compositionRevision = 0;
        compositionCursor = 0;
        memset(compositionUtf8, 0, sizeof(compositionUtf8));
        compositionRectPixels = NSZeroRect;
        compositionRectSet = NO;
        memset(&docAccessCallbacks, 0, sizeof(docAccessCallbacks));
        docAccessUserdata = NULL;
        docAccessEnabled = NO;
        hasPendingReplacement = NO;
        pendingReplacement = NSMakeRange(NSNotFound, 0);
        transparentMode = NO;   // opaque by default (bit-identical to the previous behaviour)
        clickThrough = NO;
        clickThroughState = NO; // matching the initial ignoresMouseEvents=NO
        lastMouseDownEvent = nil;

        // Allocate the double buffer (page alignment is preferable)
        // .logical: logical_w * logical_h, as before. Only .physical uses the physical size.
        buffer0 = (uint32_t*)calloc((size_t)width * (size_t)height, sizeof(uint32_t));
        buffer1 = (uint32_t*)calloc((size_t)width * (size_t)height, sizeof(uint32_t));
        currentBuffer = buffer0;
        displayBuffer = buffer1;

        // Create the CG objects at initialisation, so they can be reused
        // DeviceRGB provokes a ColorSync conversion every frame on a wide-gamut display
        // (measured under .physical, where a sample profile showed the vImage colour conversion dominating).
        // Matching the screen's actual colour space avoids that conversion.
        NSColorSpace *screenCS = [NSScreen mainScreen].colorSpace;
        colorSpace = screenCS ? CGColorSpaceRetain(screenCS.CGColorSpace) : CGColorSpaceCreateDeviceRGB();

        // Create the CGDataProvider for buffer0
        provider0 = CGDataProviderCreateWithData(
            NULL,
            buffer0,
            (size_t)width * (size_t)height * sizeof(uint32_t),
            NULL
        );

        // Create the CGDataProvider for buffer1
        provider1 = CGDataProviderCreateWithData(
            NULL,
            buffer1,
            (size_t)width * (size_t)height * sizeof(uint32_t),
            NULL
        );

        // Make it a layer-backed view
        [self setWantsLayer:YES];

        // Create the content layer (its frame is always in logical points)
        contentLayer = [CALayer layer];
        contentLayer.frame = CGRectMake(0, 0, logicalWidth, logicalHeight);
        contentLayer.opaque = YES;
        contentLayer.geometryFlipped = YES;  // Flip the Y axis, once
        [self.layer addSublayer:contentLayer];
        contentLayer.magnificationFilter = kCAFilterNearest;
        contentLayer.minificationFilter = kCAFilterNearest;
        if (physicalMode) {
            contentLayer.contentsScale = contentScale;
        }

        // Initialise the performance measurement
        lastFrameTime = CFAbsoluteTimeGetCurrent();
        frameCount = 0;
        totalFrameTime = 0.0;

        // OS file drag and drop (file URLs only; the objc backend leads)
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];

        NSLog(@"[%s] Framebuffer initialized: logical=%dx%d fb=%dx%d scale=%.2f physical=%d",
              IMPLEMENTATION_TYPE, logicalWidth, logicalHeight, width, height, contentScale, physicalMode ? 1 : 0);
    }
    return self;
}

// NSDraggingDestination (hot path: event time only)
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSPasteboard* pb = [sender draggingPasteboard];
    NSArray* urls = [pb readObjectsForClasses:@[[NSURL class]]
                                      options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (urls != nil && urls.count >= 1) {
        return NSDragOperationCopy;
    }
    return NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    if (!platformWindow) return NO;
    NSPasteboard* pb = [sender draggingPasteboard];
    NSArray* urls = [pb readObjectsForClasses:@[[NSURL class]]
                                      options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    // A single file only. A simultaneous multi-file drop rejects the whole event.
    if (urls == nil || urls.count != 1) return NO;
    NSURL* url = urls[0];
    if (![url isFileURL]) return NO;
    NSString* path = [url path];
    if (path == nil) return NO;
    NSData* utf8Data = [path dataUsingEncoding:NSUTF8StringEncoding];
    if (utf8Data == nil) return NO; // invalid UTF-8 (cannot be converted)
    NSUInteger len = [utf8Data length];
    if (len > UINT32_MAX) return NO;

    // Validating the length and NULs, and filling the struct, live in the shared helper (a single source for objc/swift/metal).
    PlatformEvent ev;
    memset(&ev, 0, sizeof(ev));
    if (!platform_fill_file_drop_event(&ev, (const char*)[utf8Data bytes], (uint32_t)len)) return NO;
    // The inline copy is done; nothing depends on the lifetime of the NSString or NSURL any more.
    queue_push(&platformWindow->event_queue, &ev);
    return YES;
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

    // Call the user's callback to produce the pixel data
    if (callback) {
        CFAbsoluteTime callbackStart = CFAbsoluteTimeGetCurrent();
        callback(currentBuffer, width, height, userdata);
        CFAbsoluteTime callbackEnd = CFAbsoluteTimeGetCurrent();

        // Swap the buffers (zero copy)
        uint32_t* temp = currentBuffer;
        currentBuffer = displayBuffer;
        displayBuffer = temp;

        // Pick the CGDataProvider that matches the buffer being displayed
        CFAbsoluteTime renderStart = CFAbsoluteTimeGetCurrent();
        CGDataProviderRef provider = (displayBuffer == buffer0) ? provider0 : provider1;

        // Create the CGImage (needed every frame)
        // In transparent mode, premultiplied alpha honours the framebuffer alpha; by default alpha is skipped, as before.
        CGBitmapInfo bitmapInfo = (transparentMode
            ? (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little)
            : (kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little)); // canonical BGRA: memory [B,G,R,A] = u32 0xAARRGGBB
        CGImageRef image = CGImageCreate(
            width,
            height,
            8,
            32,
            width * 4,
            colorSpace,
            bitmapInfo,
            provider,
            NULL,
            false,
            kCGRenderingIntentDefault
        );

        // Set it as the layer's contents (fast, with no conversion)
        contentLayer.contents = (__bridge id)image;

        // Release the CGImage
        CGImageRelease(image);

        // Update click-through on the callback and display-link path too (returns immediately while disabled)
        [self refreshClickThrough];

        CFAbsoluteTime renderEnd = CFAbsoluteTimeGetCurrent();

        // performance measurement
        frameCount++;
        double frameTime = frameStartTime - lastFrameTime;
        totalFrameTime += frameTime;
        lastFrameTime = frameStartTime;

        // Print the statistics every 60 frames
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

    // Being destroyed while the cursor is hidden would leave the OS cursor gone for good.
    if (cursorHiddenByThisView) {
        [NSCursor unhide];
        cursorHiddenByThisView = NO;
    }

    markedText = nil;

    // Release the CG objects
    if (provider0) CGDataProviderRelease(provider0);
    if (provider1) CGDataProviderRelease(provider1);
    if (colorSpace) CGColorSpaceRelease(colorSpace);

    // Free the buffers
    if (buffer0) free(buffer0);
    if (buffer1) free(buffer1);
}

// The implementation of the manual drawing accessors
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
    // Swap the buffers (zero copy)
    uint32_t* temp = currentBuffer;
    currentBuffer = displayBuffer;
    displayBuffer = temp;

    // Pick the CGDataProvider that matches the buffer being displayed
    CGDataProviderRef provider = (displayBuffer == buffer0) ? provider0 : provider1;

    // Create the CGImage (in transparent mode, premultiplied alpha honours the alpha)
    CGBitmapInfo bitmapInfo = (transparentMode
        ? (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little)
        : (kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little)); // canonical BGRA: memory [B,G,R,A] = u32 0xAARRGGBB
    CGImageRef image = CGImageCreate(
        width,
        height,
        8,
        32,
        width * 4,
        colorSpace,
        bitmapInfo,
        provider,
        NULL,
        false,
        kCGRenderingIntentDefault
    );

    // Set it as the layer's contents
    contentLayer.contents = (__bridge id)image;

    // Release the CGImage
    CGImageRelease(image);

    // Update the cursor-position test for click-through (returns immediately while clickThrough is off)
    [self refreshClickThrough];
}

- (BOOL)isOpaque {
    return transparentMode ? NO : YES; // transparent mode is not opaque
}

// Per-pixel click-through. Returning nil from NSView.hitTest does not let the event through to another
// application behind (that is the window-level ignoresMouseEvents). So on every present the alpha under
// the current cursor position decides whether `window.ignoresMouseEvents` is toggled: over a transparent
// pixel (alpha==0) the click falls through, over the opaque artwork the window gets it (dragging and right
// clicks work), and since the main loop presents every frame it recovers as soon as the cursor returns.
// Hot path declaration: once per present (per frame), but only one pixel sample, a coordinate conversion and a property write.
// The division in the conversion happens a constant number of times per frame (it is not a per-pixel loop), and nothing is allocated, so the all-pixel loop rules do not apply.
- (void)refreshClickThrough {
    if (!clickThrough) return;
    NSWindow* win = self.window;
    if (!win) return;
    uint32_t* buf = displayBuffer ? displayBuffer : currentBuffer;
    if (!buf) return;
    NSPoint screenPt = [NSEvent mouseLocation];
    NSPoint winPt = [win convertPointFromScreen:screenPt];
    NSPoint local = [self convertPoint:winPt fromView:nil]; // window → view (not flipped: the origin is bottom-left)
    NSRect b = self.bounds;
    BOOL passThrough = YES; // let it fall through when the cursor is outside the window or unknown
    // only look at the alpha while the cursor is inside the view rect (outside it stays passThrough=YES)
    if (b.size.width > 0 && b.size.height > 0 &&
        local.x >= 0 && local.x < b.size.width && local.y >= 0 && local.y < b.size.height) {
        int px = (int)(local.x / b.size.width * (CGFloat)width);
        int py = (int)((1.0 - local.y / b.size.height) * (CGFloat)height); // to a top-left origin
        if (px >= width) px = width - 1; // clamp what rounding at the right and bottom edges would push out of range (it would drop the last row)
        if (py >= height) py = height - 1;
        if (px < 0) px = 0;
        if (py < 0) py = 0;
        uint8_t alpha = (uint8_t)(buf[py * width + px] >> 24); // canonical BGRA: the top 8 bits are alpha
        passThrough = (alpha == 0);
    }
    if (passThrough != clickThroughState) { // only write the WindowServer state when the value has changed
        win.ignoresMouseEvents = passThrough;
        clickThroughState = passThrough;
    }
}

// Configure transparency and click-through (called from platform_create_window_ex and platform_set_click_through).
- (void)setTransparentMode:(BOOL)on {
    transparentMode = on;
    contentLayer.opaque = on ? NO : YES;
    [self setNeedsDisplay:YES];
}
- (void)setClickThrough:(BOOL)on {
    clickThrough = on;
    if (!on && self.window) {
        self.window.ignoresMouseEvents = NO; // when it is turned off, always go back to receiving events
        clickThroughState = NO;
    }
}

// Take and consume the most recent left-button mouse-down NSEvent for beginDrag (one-shot).
// The retained event is cleared at the moment of the call, so the same event is never reused (a
// mouse-up sometimes never arrives after performWindowDragWithEvent:, so discarding on mouse-up alone is not enough). nil when there is none.
- (NSEvent *)takeLastMouseDownEvent {
    NSEvent* ev = lastMouseDownEvent;
    lastMouseDownEvent = nil;
    return ev;
}

// ========================================
// Resizing
// ========================================

// Reallocate the framebuffer and the providers for a new size, in two phases.
// The old resources are destroyed only once the new ones have been allocated (on failure the old size is kept).
// .logical: the unit is logical points (the same as mouse coordinates). It is never called while locked (it fires during the event pump).
// A pending .physical apply is made by applyLatchedMetricsIfNeeded, in physical units.
- (BOOL)resizeBuffersTo:(int)w height:(int)h {
    if (!buffer0 || !buffer1) return NO; // do nothing during init (super's setFrameSize)
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    if (w == width && h == height) return YES; // unchanged

    // phase 1: allocate the new resources (the old ones are untouched until this succeeds)
    uint32_t* nb0 = (uint32_t*)calloc((size_t)w * h, sizeof(uint32_t));
    uint32_t* nb1 = (uint32_t*)calloc((size_t)w * h, sizeof(uint32_t));
    if (!nb0 || !nb1) {
        if (nb0) free(nb0);
        if (nb1) free(nb1);
        return NO; // out of memory: keep the old size
    }
    CGDataProviderRef np0 = CGDataProviderCreateWithData(NULL, nb0, (size_t)w * h * sizeof(uint32_t), NULL);
    CGDataProviderRef np1 = CGDataProviderCreateWithData(NULL, nb1, (size_t)w * h * sizeof(uint32_t), NULL);
    if (!np0 || !np1) {
        if (np0) CGDataProviderRelease(np0);
        if (np1) CGDataProviderRelease(np1);
        free(nb0);
        free(nb1);
        return NO; // keep the old size
    }

    // phase 2: destroy the old resources and swap.
    // layer.contents holds a CGImage that refers to the old buffer, so it is detached first to avoid
    // using freed memory (the next present attaches the new image).
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
    if (!physicalMode) {
        // .logical: framebuffer == logical, and the layer frame has the same size (as before).
        logicalWidth = w;
        logicalHeight = h;
        contentLayer.frame = CGRectMake(0, 0, w, h);
    }
    return YES;
}

// Latch the pending logical size and scale at the lock boundary.
// scale_epoch is incremented only when reallocating the buffer and applying the scale both succeed (on OOM the old three values and the old epoch are kept).
- (void)refreshPendingContentScale {
    if (!self.window) return;
    CGFloat live = self.window.backingScaleFactor;
    if (live <= 0.0) live = 1.0;
    pendingContentScale = live;
}

- (void)applyLatchedMetricsIfNeeded {
    // Re-read the live backingScaleFactor at lock time (in case a notification was missed). The epoch is not incremented yet.
    [self refreshPendingContentScale];

    const CGFloat newScale = (pendingContentScale > 0.0) ? pendingContentScale : 1.0;
    const BOOL scaleChanging = fabs(newScale - contentScale) > 1e-6;

    if (!physicalMode) {
        // .logical: the buffer size is left alone. Only when the scale changes are the epoch and the latched scale committed atomically.
        if (scaleChanging) {
            contentScale = newScale;
            scaleEpoch += 1;
        }
        return;
    }

    int lw = hasPendingResize ? pendingLogicalWidth : logicalWidth;
    int lh = hasPendingResize ? pendingLogicalHeight : logicalHeight;
    if (lw < 1) lw = 1;
    if (lh < 1) lh = 1;
    int fw = (int)lround((double)lw * (double)newScale);
    int fh = (int)lround((double)lh * (double)newScale);
    if (fw < 1) fw = 1;
    if (fh < 1) fh = 1;

    const BOOL sizeChanging = (fw != width || fh != height || lw != logicalWidth || lh != logicalHeight);
    if (!sizeChanging && !scaleChanging) {
        hasPendingResize = NO;
        return;
    }

    if (sizeChanging) {
        if (![self resizeBuffersTo:fw height:fh]) {
            // out of memory: keep the old buffer, the old latched scale and the old epoch (the pending value stays for the next lock to retry)
            return;
        }
    }
    // only on success are the logical size, the latched scale and the epoch committed together
    logicalWidth = lw;
    logicalHeight = lh;
    if (scaleChanging) scaleEpoch += 1;
    contentScale = newScale;
    hasPendingResize = NO;
    contentLayer.frame = CGRectMake(0, 0, logicalWidth, logicalHeight);
    contentLayer.contentsScale = contentScale;
}

// forQuery=YES: the current negotiated value (the pending scale), for contentScale() and input normalisation before a lock.
// forQuery=NO: the latched snapshot (buffer, scale and epoch all belong to the same frame), for lock_ex.
- (void)fillMetrics:(PlatformFramebufferMetrics*)out forQuery:(BOOL)forQuery {
    if (!out) return;
    if (forQuery) [self refreshPendingContentScale];
    out->logical_width = (uint32_t)logicalWidth;
    out->logical_height = (uint32_t)logicalHeight;
    out->framebuffer_width = (uint32_t)width;
    out->framebuffer_height = (uint32_t)height;
    const CGFloat scale = forQuery ? pendingContentScale : contentScale;
    out->content_scale = (float)((scale > 0.0) ? scale : 1.0);
    out->scale_epoch = scaleEpoch;
}

- (CGFloat)nativeEventScale {
    [self refreshPendingContentScale];
    return (pendingContentScale > 0.0) ? pendingContentScale : 1.0;
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    CGFloat s = 1.0;
    if (self.window) {
        s = self.window.backingScaleFactor;
        if (s <= 0.0) s = 1.0;
    }
    // Only the pending value is updated. The epoch, the latched scale and the buffer are committed atomically on the next successful lock.
    if (fabs(s - pendingContentScale) > 1e-6) {
        pendingContentScale = s;
        if (physicalMode && redrawCallback) {
            redrawCallback(redrawUserdata);
        }
    }
}

// Called by NSView on a resize. Reallocates the framebuffer for the new logical size.
// The redraw callback fires only when the size really changed (a CATransaction commit puts it on
// screen even inside AppKit's live-resize tracking run loop).
- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    if (physicalMode) {
        int nw = (int)newSize.width;
        int nh = (int)newSize.height;
        if (nw < 1) nw = 1;
        if (nh < 1) nh = 1;
        if (nw != logicalWidth || nh != logicalHeight) {
            pendingLogicalWidth = nw;
            pendingLogicalHeight = nh;
            hasPendingResize = YES;
            // the buffer is applied on the next lock; the redraw prompts the application to lock
            if (redrawCallback) redrawCallback(redrawUserdata);
        }
        return;
    }
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
// NSTextInputClient and IME composition
// ========================================
// keyDown pushes the physical key_down in the poll loop and then hands the event to
// interpretKeyEvents:, making insertText: the only source of char_input.

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (uint32_t)copyCompositionSnapshot:(char*)buf cap:(uint32_t)cap meta:(PlatformCompositionMeta*)meta {
    // latest-wins: always the current preedit. event.revision only detects a missed update (an older revision cannot be read).
    if (meta) {
        meta->revision = compositionRevision;
        meta->cursor = compositionCursor;
        meta->len = 0;
    }
    if (!buf || cap == 0 || compositionLen == 0) {
        if (meta) meta->len = 0;
        return 0;
    }
    // cut on a UTF-8 code point boundary
    uint32_t n = (uint32_t)utf8SafePrefixLen(compositionUtf8, compositionLen, cap);
    memcpy(buf, compositionUtf8, n);
    if (meta) {
        meta->len = n;
        if (meta->cursor > n) meta->cursor = n;
    }
    return n;
}

/// Synchronise markedText into compositionUtf8 / compositionCursor.
- (void)syncCompositionBufferFromMarked {
    const char* utf8 = [markedText UTF8String];
    if (!utf8) {
        compositionLen = 0;
        compositionCursor = 0;
        return;
    }
    size_t raw_len = strlen(utf8);
    // truncate into the fixed buffer on a UTF-8 boundary
    size_t len = utf8SafePrefixLen(utf8, raw_len, COMPOSITION_UTF8_CAP);
    memcpy(compositionUtf8, utf8, len);
    compositionLen = (uint32_t)len;
    // selectedRange.location is in UTF-16 units, so convert it to a UTF-8 offset.
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
    key_trace("composition phase=%u revision=%u cursor=%u", phase, compositionRevision, compositionCursor);
}

/// Split the insertText string into code points and push CHAR_INPUT (excluding control and private-use characters).
/// No char_input is emitted while Cmd or Ctrl is held (which would print a character for an insertText coming from a key binding).
- (void)pushCharInputsFromString:(NSString*)str {
    if (!platformWindow || !str) return;
    uint32_t char_mods = extractModifiers([NSEvent modifierFlags]);
    // the same invariant as the printable filter: nothing with cmd or ctrl is printed
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
            key_trace("char_input cp=U+%X mods=0x%X", cp, char_mods);
        }
    }
}

- (void)clearPendingReplacementWithReason:(const char*)reason {
    char was[64];
    if (hasPendingReplacement) ime_range_desc(pendingReplacement, was, sizeof(was));
    else snprintf(was, sizeof(was), "none");
    if (hasPendingReplacement || g_ime_trace_enabled) {
        ime_trace("clearPending reason=%s was=%s", reason ? reason : "unspecified", was);
    }
    hasPendingReplacement = NO;
    pendingReplacement = NSMakeRange(NSNotFound, 0);
}

- (void)setTextInputDocumentAccess:(const PlatformTextInputDocumentCallbacks*)callbacks userdata:(void*)ud {
    if (callbacks && callbacks->get_selected_range && callbacks->get_substring && callbacks->replace_text) {
        docAccessCallbacks = *callbacks;
        docAccessUserdata = ud;
        docAccessEnabled = YES;
    } else {
        memset(&docAccessCallbacks, 0, sizeof(docAccessCallbacks));
        docAccessUserdata = NULL;
        docAccessEnabled = NO;
        [self clearPendingReplacementWithReason:"docAccess_disabled"];
    }
}

- (NSRange)resolveReplacementRange:(NSRange)replacementRange {
    // Priority: explicit (length>0) → pending → explicit (length==0, a caret) → selected.
    // Even when insertText states a zero-length caret, a pending range latched for reconversion wins.
    if (replacementRange.location != NSNotFound && replacementRange.length > 0) {
        return replacementRange;
    }
    if (hasPendingReplacement) return pendingReplacement;
    if (replacementRange.location != NSNotFound) return replacementRange;
    if (docAccessEnabled && docAccessCallbacks.get_selected_range) {
        PlatformTextInputRange pr;
        memset(&pr, 0, sizeof(pr));
        if (docAccessCallbacks.get_selected_range(docAccessUserdata, &pr) && pr.location != UINT64_MAX) {
            return NSMakeRange((NSUInteger)pr.location, (NSUInteger)pr.length);
        }
    }
    return NSMakeRange(NSNotFound, 0);
}

- (const char*)resolveReplacementPath:(NSRange)replacementRange {
    if (replacementRange.location != NSNotFound && replacementRange.length > 0) return "explicit_len";
    if (hasPendingReplacement) return "pending";
    if (replacementRange.location != NSNotFound) return "explicit_zero";
    if (docAccessEnabled && docAccessCallbacks.get_selected_range) {
        PlatformTextInputRange pr;
        memset(&pr, 0, sizeof(pr));
        if (docAccessCallbacks.get_selected_range(docAccessUserdata, &pr) && pr.location != UINT64_MAX) {
            return "selected";
        }
    }
    return "none";
}

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    key_trace("insertText");
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

    if (docAccessEnabled && docAccessCallbacks.replace_text) {
        const char* path = [self resolveReplacementPath:replacementRange];
        NSRange useRange = [self resolveReplacementRange:replacementRange];
        char ex[64], fin[64], pend[64], prev[80];
        ime_range_desc(replacementRange, ex, sizeof(ex));
        ime_range_desc(useRange, fin, sizeof(fin));
        if (hasPendingReplacement) ime_range_desc(pendingReplacement, pend, sizeof(pend));
        else snprintf(pend, sizeof(pend), "none");
        ime_preview_utf8(str ? [str UTF8String] : "", prev, sizeof(prev));
        ime_trace("insertText text=\"%s\" explicit=%s path=%s final=%s pending_before_clear=%s",
                  prev, ex, path, fin, pend);
        [self clearPendingReplacementWithReason:"insertText"];
        if (useRange.location == NSNotFound) return;
        // A failed UTF-8 conversion is rejected (the buffer is untouched and no char_input is emitted)
        if (!str) str = @"";
        NSData* data = [str dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
        if (!data && str.length > 0) return;
        const uint8_t* utf8 = data ? (const uint8_t*)[data bytes] : (const uint8_t*)"";
        uint32_t len = data ? (uint32_t)[data length] : 0;
        PlatformTextInputRange rr = {
            .location = (uint64_t)useRange.location,
            .length = (uint64_t)useRange.length,
        };
        docAccessCallbacks.replace_text(docAccessUserdata, rr, utf8, len);
        return;
    }

    char ex2[64], prev2[80];
    ime_range_desc(replacementRange, ex2, sizeof(ex2));
    ime_preview_utf8(str ? [str UTF8String] : "", prev2, sizeof(prev2));
    ime_trace("insertText text=\"%s\" explicit=%s path=char_input (no docAccess)", prev2, ex2);
    [self clearPendingReplacementWithReason:"insertText_char_input"];
    [self pushCharInputsFromString:str];
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    key_trace("setMarkedText");
    NSString* str = [string isKindOfClass:[NSAttributedString class]]
        ? [(NSAttributedString*)string string]
        : (NSString*)string;
    if (!str) str = @"";
    char before[64], after[64], repl[64], sel[64], prev[80];
    if (hasPendingReplacement) ime_range_desc(pendingReplacement, before, sizeof(before));
    else snprintf(before, sizeof(before), "none");
    // A valid replacementRange is latched exactly once per reconversion or composition.
    // A later NSNotFound or zero-length caret does not overwrite it.
    //
    // When the pending range is discarded (an empty setMarkedText is not a cancel: Japanese input reconversion
    // arrives as setMarkedText(" ", range) → setMarkedText("") → setMarkedText(candidate) → insertText, and
    // dropping the pending range on the empty mark would turn insertText into a plain caret insertion, duplicating the text):
    //   - right after insertText consumed it
    //   - unmarkText (ESC and the like)
    //   - setTextInputActive:NO, unregistering document access, or destroying the window
    // The safety valve: a new valid replacementRange is latched only while hasPending==NO
    // (the start of the next session, after the previous one was consumed or discarded). An empty mark or an NSNotFound update discards nothing.
    if (replacementRange.location != NSNotFound && !hasPendingReplacement) {
        hasPendingReplacement = YES;
        pendingReplacement = replacementRange;
    }
    if (hasPendingReplacement) ime_range_desc(pendingReplacement, after, sizeof(after));
    else snprintf(after, sizeof(after), "none");
    ime_range_desc(replacementRange, repl, sizeof(repl));
    ime_range_desc(selectedRange, sel, sizeof(sel));
    ime_preview_utf8([str UTF8String], prev, sizeof(prev));
    ime_trace("setMarkedText text=\"%s\" selected=%s replacement=%s pending %s->%s",
              prev, sel, repl, before, after);
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
        // An empty mark only clears the preedit display; the pending range is kept.
        // No CANCEL phase is emitted either (a real cancel is unmarkText).
        char keep[64];
        if (hasPendingReplacement) ime_range_desc(pendingReplacement, keep, sizeof(keep));
        else snprintf(keep, sizeof(keep), "none");
        ime_trace("setMarkedText empty-mark keep pending=%s wasEmpty=%d", keep, wasEmpty);
        return;
    }
    uint8_t phase = wasEmpty
        ? PLATFORM_COMPOSITION_PHASE_START
        : PLATFORM_COMPOSITION_PHASE_UPDATE;
    [self pushCompositionPhase:phase];
}

- (void)unmarkText {
    char pend[64];
    if (hasPendingReplacement) ime_range_desc(pendingReplacement, pend, sizeof(pend));
    else snprintf(pend, sizeof(pend), "none");
    ime_trace("unmarkText markedLen=%lu pending=%s", (unsigned long)markedText.length, pend);
    if (markedText.length == 0) {
        [self clearPendingReplacementWithReason:"unmarkText_already_empty"];
        return;
    }
    [markedText setString:@""];
    imeSelectedRange = NSMakeRange(0, 0);
    compositionLen = 0;
    compositionCursor = 0;
    [self clearPendingReplacementWithReason:"unmarkText"];
    [self pushCompositionPhase:PLATFORM_COMPOSITION_PHASE_CANCEL];
}

- (BOOL)hasMarkedText {
    return markedText.length > 0;
}

// Whether keyDown should go to the IME (inputContext). Uncontrolled means always YES, as before.
- (BOOL)imeRouteEnabled {
    return imeControlled ? imeActive : YES;
}

// Receive the presence of text editing focus from the application. When the effective path goes
// YES→NO (the first inactive from uncontrolled, i.e. always-YES, included) a pending composition is discarded.
- (void)setTextInputActive:(BOOL)active {
    BOOL wasRouting = [self imeRouteEnabled];     // the effective path before the change (YES while uncontrolled)
    imeControlled = YES;
    imeActive = active;                           // the effective path after the change = active
    if (wasRouting && !active) {
        [self unmarkText];                        // clear markedText, emit the CANCEL phase and discard the pending range
        [[self inputContext] discardMarkedText];  // discard the IME's conversion session too (closing the candidate window)
        [self clearPendingReplacementWithReason:"setTextInputActive_false"];
    }
}

- (NSRange)markedRange {
    if (markedText.length == 0) return NSMakeRange(NSNotFound, 0);
    return NSMakeRange(0, markedText.length);
}

- (NSRange)selectedRange {
    if (markedText.length == 0) {
        if (docAccessEnabled && docAccessCallbacks.get_selected_range) {
            PlatformTextInputRange pr;
            memset(&pr, 0, sizeof(pr));
            if (docAccessCallbacks.get_selected_range(docAccessUserdata, &pr) && pr.location != UINT64_MAX) {
                NSRange r = NSMakeRange((NSUInteger)pr.location, (NSUInteger)pr.length);
                char desc[64];
                ime_range_desc(r, desc, sizeof(desc));
                ime_trace("selectedRange (doc) -> %s", desc);
                return r;
            }
        }
        NSRange r = NSMakeRange(NSNotFound, 0);
        char desc[64];
        ime_range_desc(r, desc, sizeof(desc));
        ime_trace("selectedRange (empty) -> %s", desc);
        return r;
    }
    char desc[64];
    ime_range_desc(imeSelectedRange, desc, sizeof(desc));
    ime_trace("selectedRange (marked) -> %s", desc);
    return imeSelectedRange;
}

- (NSArray<NSAttributedStringKey>*)validAttributesForMarkedText {
    return @[];
}

- (NSAttributedString*)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    char prop[64];
    ime_range_desc(range, prop, sizeof(prop));
    if (markedText.length == 0) {
        if (!docAccessEnabled || !docAccessCallbacks.get_substring) {
            ime_trace("attributedSubstring proposed=%s -> nil (no docAccess)", prop);
            return nil;
        }
        if (range.location == NSNotFound) {
            ime_trace("attributedSubstring proposed=%s -> nil (NSNotFound)", prop);
            return nil;
        }
        PlatformTextInputRange proposed = {
            .location = (uint64_t)range.location,
            .length = (uint64_t)range.length,
        };
        const uint8_t* utf8 = NULL;
        uint32_t len = 0;
        PlatformTextInputRange actual = {0, 0};
        if (!docAccessCallbacks.get_substring(docAccessUserdata, proposed, &utf8, &len, &actual)) {
            ime_trace("attributedSubstring proposed=%s -> nil (callback false)", prop);
            return nil;
        }
        NSRange actualNS = NSMakeRange((NSUInteger)actual.location, (NSUInteger)actual.length);
        if (actualRange) {
            *actualRange = actualNS;
        }
        char act[64], prev[80];
        ime_range_desc(actualNS, act, sizeof(act));
        if (len == 0) {
            ime_trace("attributedSubstring proposed=%s actual=%s text=\"\" len=0", prop, act);
            return [[NSAttributedString alloc] initWithString:@""];
        }
        if (!utf8) {
            ime_trace("attributedSubstring proposed=%s -> nil (null utf8)", prop);
            return nil;
        }
        NSString* s = [[NSString alloc] initWithBytes:utf8 length:len encoding:NSUTF8StringEncoding];
        if (!s) {
            ime_trace("attributedSubstring proposed=%s -> nil (bad utf8)", prop);
            return nil;
        }
        ime_preview_utf8([s UTF8String], prev, sizeof(prev));
        ime_trace("attributedSubstring proposed=%s actual=%s text=\"%s\" len=%lu",
                  prop, act, prev, (unsigned long)s.length);
        return [[NSAttributedString alloc] initWithString:s];
    }
    NSRange full = NSMakeRange(0, markedText.length);
    NSRange clipped = NSIntersectionRange(full, range);
    if (clipped.length == 0) {
        ime_trace("attributedSubstring (marked) proposed=%s -> nil (empty clip)", prop);
        return nil;
    }
    if (actualRange) *actualRange = clipped;
    NSString* sub = [markedText substringWithRange:clipped];
    char act[64], prev[80];
    ime_range_desc(clipped, act, sizeof(act));
    ime_preview_utf8([sub UTF8String], prev, sizeof(prev));
    ime_trace("attributedSubstring (marked) proposed=%s actual=%s text=\"%s\" len=%lu",
              prop, act, prev, (unsigned long)sub.length);
    return [[NSAttributedString alloc] initWithString:sub];
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    ime_trace("characterIndex point=(%.1f,%.1f) -> NSNotFound", point.x, point.y);
    (void)point;
    return NSNotFound;
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    if (actualRange) *actualRange = range;
    // Convert the application's framebuffer pixel rect into view points. The framebuffer is not a Retina
    // backing: contentLayer scales it across the whole of bounds, so the conversion is the bounds ratio (the inverse of the mouse conversion).
    NSRect r;
    if (compositionRectSet && compositionRectPixels.size.width > 0 && compositionRectPixels.size.height > 0) {
        const NSRect bounds = self.bounds;
        CGFloat sx = (width > 0) ? bounds.size.width / (CGFloat)width : 1.0;
        CGFloat sy = (height > 0) ? bounds.size.height / (CGFloat)height : 1.0;
        CGFloat x = compositionRectPixels.origin.x * sx;
        CGFloat top = compositionRectPixels.origin.y * sy;
        CGFloat w = compositionRectPixels.size.width * sx;
        CGFloat h = compositionRectPixels.size.height * sy;
        x = MAX(bounds.origin.x, MIN(x, NSMaxX(bounds)));
        top = MAX(0.0, MIN(top, bounds.size.height));
        w = MIN(w, MAX(0.0, NSMaxX(bounds) - x));
        h = MIN(h, MAX(0.0, bounds.size.height - top));
        r = NSMakeRect(x, bounds.size.height - top - h, w, h);
    } else {
        // Nothing supplied, or a zero size, falls back to the existing fixed rect.
        r = NSMakeRect(20.0, self.bounds.size.height - 48.0, 1.0, 18.0);
    }
    r = [self convertRect:r toView:nil];
    if (self.window) {
        r = [self.window convertRectToScreen:r];
    }
    char desc[64];
    ime_range_desc(range, desc, sizeof(desc));
    ime_trace("firstRect range=%s -> (%.1f,%.1f,%.1f,%.1f)", desc, r.origin.x, r.origin.y, r.size.width, r.size.height);
    return r;
}

- (void)doCommandBySelector:(SEL)selector {
    // Absorb an unhandled command to suppress the beep. A physical key such as BACKSPACE or ENTER already arrives through the key_down path.
    key_trace("doCommandBySelector=%s", selector ? sel_getName(selector) : "(null)");
}

- (void)setCompositionRectPixelsX:(int32_t)x y:(int32_t)y w:(int32_t)w h:(int32_t)h {
    NSRect next = NSMakeRect(x, y, w, h);
    if (NSEqualRects(compositionRectPixels, next) && compositionRectSet == (w > 0 && h > 0)) return;
    compositionRectPixels = next;
    compositionRectSet = w > 0 && h > 0;
    [self.inputContext invalidateCharacterCoordinates];
}

// ========================================
// Mouse events
// ========================================

- (void)clearPlatformWindow {
    platformWindow = NULL;
}

// Receive mouseDown: even for the first click on an inactive window
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    (void)event;
    return YES;
}

// Rebuild the NSTrackingArea to match the view size
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (trackingArea) {
        [self removeTrackingArea:trackingArea];
        trackingArea = nil;
    }
    // NSTrackingCursorUpdate: have cursorUpdate: called when the mouse re-enters, so the cursor
    // recovers even after the OS resets it (on a window switch, say).
    // NSTrackingMouseEnteredAndExited: track entering and leaving the view, releasing ownership of
    // hidden (mouseExited) and applying the shape (mouseEntered). Hiding and unhiding happen only while inside the view.
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
// Cursor control
// ========================================
//
// The policy: NSCursor hide/unhide is a process-wide reference-counted API, so cursorHiddenByThisView
// tracks strictly whether this view currently owns the hide (hide only on a false→true transition,
// unhide only on true→false). On top of that, set and hide are really applied only while
// mouseInsideView is true; a setCursor arriving while the mouse is outside merely stores the shape
// (so the cursor of the whole system is never hidden or reshaped by mistake while the mouse is elsewhere).

// Return the NSCursor matching currentCursorShape (PLATFORM_CURSOR_HIDDEN is not handled here).
// An unsupported shape falls back to the arrow.
- (NSCursor *)nsCursorForShape:(PlatformCursorShape)shape {
    switch (shape) {
        case PLATFORM_CURSOR_CROSSHAIR:
            return [NSCursor crosshairCursor];
        case PLATFORM_CURSOR_DEFAULT:
        default:
            return [NSCursor arrowCursor];
    }
}

// Really apply currentCursorShape, assuming mouseInsideView (including the transfer of hide ownership).
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

// Called from platform_set_cursor. Stores the shape and applies it at once while inside the view.
- (void)setCursorShape:(PlatformCursorShape)shape {
    currentCursorShape = shape;
    [self applyCursorShapeIfInside];
}

// The mouse re-entered the view. Apply the current shape.
- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    mouseInsideView = YES;
    [self applyCursorShapeIfInside];
}

// The mouse left the view. Whenever this view owns the hide, it must release it
// (otherwise the OS cursor stays gone while outside the view).
- (void)mouseExited:(NSEvent *)event {
    (void)event;
    mouseInsideView = NO;
    if (cursorHiddenByThisView) {
        [NSCursor unhide];
        cursorHiddenByThisView = NO;
    }
}

// Called by AppKit when the tracking area is re-entered. The cursor recovers even after the OS reset it on an application switch.
- (void)cursorUpdate:(NSEvent *)event {
    (void)event;
    // cursorUpdate is only called inside the tracking rect (NSTrackingCursorUpdate), so this counts as being inside the view.
    // That applies the shape even when mouseEntered did not fire, when the order differs, or when recovering from a cursor reset after a window switch.
    mouseInsideView = YES;
    [self applyCursorShapeIfInside];
}

// Shared: enqueue mouse_down / mouse_up / mouse_move (including a move with a button held)
- (void)enqueueMouseEvent:(PlatformEventType)type withButton:(PlatformMouseButton)btn from:(NSEvent*)event {
    if (!platformWindow) return;
    int32_t x, y;
    event_location_to_platform_raw_coords(event, self, [self nativeEventScale], &x, &y);
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

// scrollWheel: has its own payload, so it is implemented separately
- (void)scrollWheel:(NSEvent *)event {
    if (!platformWindow) return;
    int32_t x, y;
    CGFloat scale = [self nativeEventScale];
    event_location_to_platform_raw_coords(event, self, scale, &x, &y);

    BOOL is_precise = event.hasPreciseScrollingDeltas;
    float dx = (float)event.scrollingDeltaX;
    float dy = (float)event.scrollingDeltaY;
    if (!is_precise) {
        dx *= SCROLL_LINE_TO_POINTS;
        dy *= SCROLL_LINE_TO_POINTS;
    }
    // raw physical units (the facade turns them into logical ones with the latched scale)
    dx *= (float)scale;
    dy *= (float)scale;

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

// mouseDown / mouseUp / mouseDragged: the left button
- (void)mouseDown:(NSEvent *)event {
    lastMouseDownEvent = event; // keep the most recent left down for beginDrag (ARC strong)
    [self enqueueMouseEvent:PLATFORM_EVENT_MOUSE_DOWN withButton:button_from_event(event) from:event];
}
- (void)mouseUp:(NSEvent *)event {
    lastMouseDownEvent = nil; // discard the stale event on up (once a drag has started it is already consumed)
    [self enqueueMouseEvent:PLATFORM_EVENT_MOUSE_UP withButton:button_from_event(event) from:event];
}
- (void)mouseDragged:(NSEvent *)event {
    [self enqueueMouseEvent:PLATFORM_EVENT_MOUSE_MOVE withButton:PLATFORM_MOUSE_BUTTON_NONE from:event];
}

// rightMouseDown / rightMouseUp / rightMouseDragged
// Control plus a left click comes here too, but buttonNumber stays 0, so it counts as button=LEFT
- (void)rightMouseDown:(NSEvent *)event {
    [self enqueueMouseEvent:PLATFORM_EVENT_MOUSE_DOWN withButton:button_from_event(event) from:event];
}
- (void)rightMouseUp:(NSEvent *)event {
    [self enqueueMouseEvent:PLATFORM_EVENT_MOUSE_UP withButton:button_from_event(event) from:event];
}
- (void)rightMouseDragged:(NSEvent *)event {
    [self enqueueMouseEvent:PLATFORM_EVENT_MOUSE_MOVE withButton:PLATFORM_MOUSE_BUTTON_NONE from:event];
}

// otherMouseDown / otherMouseUp / otherMouseDragged: only middle (buttonNumber=2) is taken; X1/X2 are ignored
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

// A hover move (with no button held). It needs NSWindow.acceptsMouseMovedEvents = YES plus an NSTrackingArea
- (void)mouseMoved:(NSEvent *)event {
    [self enqueueMouseEvent:PLATFORM_EVENT_MOUSE_MOVE withButton:PLATFORM_MOUSE_BUTTON_NONE from:event];
}

@end

// ========================================
// Key code conversion
// ========================================

// Convert a macOS key code into a PlatformKeyCode
// Reference: /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/Headers/Events.h
static PlatformKeyCode mapKeyCodeToPlatform(unsigned short keyCode) {
    // From a macOS key code (the ANSI layout) to the standard key code
    switch (keyCode) {
        // character keys (the ANSI layout)
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

        // modifier keys (left)
        case 0x38: return PLATFORM_KEY_LEFT_SHIFT;      // kVK_Shift
        case 0x3A: return PLATFORM_KEY_LEFT_ALT;        // kVK_Option
        case 0x3B: return PLATFORM_KEY_LEFT_CONTROL;    // kVK_Control
        case 0x37: return PLATFORM_KEY_LEFT_SUPER;      // kVK_Command
        case 0x39: return PLATFORM_KEY_CAPS_LOCK;       // kVK_CapsLock

        // modifier keys (right)
        case 0x3C: return PLATFORM_KEY_RIGHT_SHIFT;     // kVK_RightShift
        case 0x3D: return PLATFORM_KEY_RIGHT_ALT;       // kVK_RightOption
        case 0x3E: return PLATFORM_KEY_RIGHT_CONTROL;   // kVK_RightControl
        case 0x36: return PLATFORM_KEY_RIGHT_SUPER;     // kVK_RightCommand

        // function keys
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

        // editing keys
        case 0x72: return PLATFORM_KEY_INSERT;          // kVK_Help
        case 0x73: return PLATFORM_KEY_HOME;            // kVK_Home
        case 0x74: return PLATFORM_KEY_PAGE_UP;         // kVK_PageUp
        case 0x75: return PLATFORM_KEY_DELETE;          // kVK_ForwardDelete
        case 0x77: return PLATFORM_KEY_END;             // kVK_End
        case 0x79: return PLATFORM_KEY_PAGE_DOWN;       // kVK_PageDown

        // arrow keys
        case 0x7B: return PLATFORM_KEY_LEFT;            // kVK_LeftArrow
        case 0x7C: return PLATFORM_KEY_RIGHT;           // kVK_RightArrow
        case 0x7D: return PLATFORM_KEY_DOWN;            // kVK_DownArrow
        case 0x7E: return PLATFORM_KEY_UP;              // kVK_UpArrow

        // the numeric keypad
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

// Platform initialisation
bool platform_init(void) {
    const char* trace = getenv("KNGN_KEY_TRACE");
    g_key_trace_enabled = trace && strcmp(trace, "1") == 0;
    const char* ime = getenv("KNGN_IME_TRACE");
    g_ime_trace_enabled = ime && strcmp(ime, "1") == 0;
    return true;
}

// A borderless window cannot become key or main by default. NSWindow is subclassed to answer YES
// to canBecomeKeyWindow/canBecomeMainWindow, so that input, the IME first responder and
// performWindowDragWithEvent: work. It is used only for a transparent or borderless window.
@interface MascotWindow : NSWindow
@end
@implementation MascotWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

// Create a window (the existing API; no opts = opaque with a title, as before)
PlatformWindow* platform_create_window(int width, int height, const char* title,
                                      FrameCallback callback, void* userdata) {
    return platform_create_window_ex(width, height, title, callback, userdata, NULL);
}

// Create a window with options. opts==NULL keeps the previous behaviour.
PlatformWindow* platform_create_window_ex(int width, int height, const char* title,
                                          FrameCallback callback, void* userdata,
                                          const PlatformWindowOptions* opts) {
    // Unknown flags or reserved!=0 give NULL (never ignored silently; the facade turns it into error.Unsupported)
    BOOL transparent = NO, borderless = NO, has_position = NO, physical = NO;
    int pos_x = 0, pos_y = 0;
    if (opts) {
        const uint32_t known = PLATFORM_WINDOW_TRANSPARENT | PLATFORM_WINDOW_BORDERLESS |
                               PLATFORM_WINDOW_POSITION | PLATFORM_WINDOW_FRAMEBUFFER_PHYSICAL;
        if ((opts->flags & ~known) != 0 || opts->reserved != 0) return NULL;
        transparent = (opts->flags & PLATFORM_WINDOW_TRANSPARENT) != 0;
        borderless = (opts->flags & PLATFORM_WINDOW_BORDERLESS) != 0;
        physical = (opts->flags & PLATFORM_WINDOW_FRAMEBUFFER_PHYSICAL) != 0;
        if ((opts->flags & PLATFORM_WINDOW_POSITION) != 0) {
            has_position = YES;
            pos_x = opts->x;
            pos_y = opts->y;
        }
    }

    PlatformWindow* platformWindow = (PlatformWindow*)malloc(sizeof(PlatformWindow));
    if (!platformWindow) return NULL;

    // Initialise the event queue
    memset(&platformWindow->event_queue, 0, sizeof(EventQueue));
    platformWindow->quit_delegate = nil;
    platformWindow->quit_requested = false;

    @autoreleasepool {
        // Get the NSApplication
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        // Create the window
        NSRect frame = NSMakeRect(0, 0, width, height);
        NSWindowStyleMask styleMask;
        if (borderless) {
            styleMask = NSWindowStyleMaskBorderless; // frameless (for a mascot and the like)
        } else {
            styleMask = NSWindowStyleMaskTitled |
                        NSWindowStyleMaskClosable |
                        NSWindowStyleMaskMiniaturizable |
                        NSWindowStyleMaskResizable; // freely resizable
        }

        // borderless uses the subclass that can become the key window (transparent on its own works with a plain NSWindow)
        Class windowClass = borderless ? [MascotWindow class] : [NSWindow class];
        platformWindow->window = [[windowClass alloc] initWithContentRect:frame
                                                               styleMask:styleMask
                                                                 backing:NSBackingStoreBuffered
                                                                   defer:NO];
        // Disable window tabbing (so the drawing area stays full height regardless of saved defaults or a system setting)
        [platformWindow->window setTabbingMode:NSWindowTabbingModeDisallowed];

        [platformWindow->window setTitle:[NSString stringWithUTF8String:title]];

        // Required in order to receive a hover mouseMoved:
        [platformWindow->window setAcceptsMouseMovedEvents:YES];

        // Configure the transparent window (the desktop shows through)
        if (transparent) {
            [platformWindow->window setOpaque:NO];
            [platformWindow->window setBackgroundColor:[NSColor clearColor]];
        }
        // Borderless drops the rectangular shadow and becomes draggable whether or not it is transparent (the design contract)
        if (borderless) {
            [platformWindow->window setHasShadow:NO];
            [platformWindow->window setMovable:YES];
        }

        // Create and install the custom view
        platformWindow->view = [[FramebufferView alloc] initWithFrame:frame
                                                               width:width
                                                              height:height
                                                            callback:callback
                                                             userdata:userdata
                                                     platformWindow:platformWindow
                                                       physicalMode:physical];
        QuitWindowDelegate* quitDelegate = [[QuitWindowDelegate alloc] init];
        quitDelegate.platformWindow = platformWindow;
        platformWindow->quit_delegate = quitDelegate;
        [platformWindow->window setDelegate:quitDelegate];
        if (transparent) {
            [platformWindow->view setTransparentMode:YES]; // Make the CGImage premultiplied alpha
        }
        [platformWindow->window setContentView:platformWindow->view];
        // Call updateTrackingAreas after setContentView (the view's bounds are settled by then, so the tracking area is built correctly)
        [platformWindow->view updateTrackingAreas];

        // Show the window (with an explicit position, setFrameOrigin; otherwise center)
        if (has_position) {
            [platformWindow->window setFrameOrigin:NSMakePoint(pos_x, pos_y)];
        } else {
            [platformWindow->window center];
        }
        [platformWindow->window makeKeyAndOrderFront:nil];
        // IME: make the view the first responder so that inputContext and interpretKeyEvents work
        [platformWindow->window makeFirstResponder:platformWindow->view];
        [app activateIgnoringOtherApps:YES];

        // Start the CADisplayLink
        [platformWindow->view startDisplayLink];
    }

#if defined(KNGN_ENABLE_GAMEPAD)
    // Gamepads: make this window the active one and take in the controllers already connected
    gamepadAttachWindow(platformWindow);
#endif

    return platformWindow;
}

// The current window geometry. The position is frame.origin, the size is the content size.
void platform_get_window_geometry(PlatformWindow* platformWindow, PlatformWindowGeometry* out) {
    if (!out) return;
    out->x = 0;
    out->y = 0;
    out->width = 0;
    out->height = 0;
    out->flags = 0;
    if (!platformWindow || !platformWindow->window) return;
    @autoreleasepool {
        NSWindow* w = platformWindow->window;
        NSRect frame = [w frame];
        NSRect content = [w contentRectForFrameRect:frame];
        out->x = (int32_t)frame.origin.x;
        out->y = (int32_t)frame.origin.y;
        out->width = (uint32_t)lround(content.size.width);
        out->height = (uint32_t)lround(content.size.height);
        out->flags = PLATFORM_GEOMETRY_POSITION_VALID;
    }
}

// Update the title of the visible window (event time only).
void platform_set_title(PlatformWindow* platformWindow, const char* title) {
    if (!platformWindow || !title) return;
    @autoreleasepool {
        [platformWindow->window setTitle:[NSString stringWithUTF8String:title]];
    }
}

// Make an existing window natively fullscreen (the same toggleFullScreen: as the green button).
// A titled, resizable window can go fullscreen by default, but FullScreenPrimary is set on
// collectionBehavior first, to be safe. Already fullscreen is a no-op (no double toggle).
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

// ========================================
// The C ABI implementation of transparent / borderless windows plus drag-to-move
// ========================================

// Start the OS's interactive window move using the most recent left mouse-down.
void platform_begin_window_drag(PlatformWindow* window) {
    if (!window || !window->view || !window->window) return;
    @autoreleasepool {
        NSEvent* ev = [window->view takeLastMouseDownEvent]; // consumed one-shot (cleared as it is taken)
        if (!ev) return; // a no-op when no event is retained
        [window->window performWindowDragWithEvent:ev];
    }
}

void platform_set_always_on_top(PlatformWindow* window, bool on) {
    if (!window || !window->window) return;
    @autoreleasepool {
        // The status level sits above the Dock and above most windows. Turning it off goes back to the normal level.
        [window->window setLevel:(on ? NSStatusWindowLevel : NSNormalWindowLevel)];
    }
}

void platform_set_click_through(PlatformWindow* window, bool on) {
    if (!window || !window->view) return;
    [window->view setClickThrough:(on ? YES : NO)];
}

void platform_set_dock_visible(bool visible) {
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        // accessory = a background app with no Dock icon and no menu bar. regular = an ordinary app.
        [app setActivationPolicy:(visible ? NSApplicationActivationPolicyRegular
                                          : NSApplicationActivationPolicyAccessory)];
    }
}

// The target of the quit menu. The action raises a flag, read once popUp returns from its modal loop.
@interface QuitMenuTarget : NSObject
@property (nonatomic) BOOL quitChosen;
- (void)onQuit:(id)sender;
@end
@implementation QuitMenuTarget
- (void)onQuit:(id)sender { (void)sender; self.quitChosen = YES; }
@end

void platform_show_quit_menu(PlatformWindow* window) {
    if (!window || !window->view) return;
    @autoreleasepool {
        QuitMenuTarget* target = [[QuitMenuTarget alloc] init];
        target.quitChosen = NO;
        NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Mascot"];
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:@"終了"
                                                      action:@selector(onQuit:)
                                               keyEquivalent:@""];
        [item setTarget:target];
        [menu addItem:item];
        // Pop up at the current mouse position (in view coordinates). It is modal and does not return until something is chosen.
        NSPoint screenPt = [NSEvent mouseLocation];
        NSPoint winPt = [window->window convertPointFromScreen:screenPt];
        NSPoint viewPt = [window->view convertPoint:winPt fromView:nil];
        [menu popUpMenuPositioningItem:nil atLocation:viewPt inView:window->view];
        if (target.quitChosen) {
            PlatformEvent ev;
            memset(&ev, 0, sizeof(ev));
            ev.type = PLATFORM_EVENT_QUIT;
            queue_push(&window->event_queue, &ev);
        }
    }
}

// The main loop
void platform_run(PlatformWindow* platformWindow) {
    if (!platformWindow) return;

    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        [app run];
    }
}

// Destroying a window
void platform_destroy_window(PlatformWindow* platformWindow) {
    if (!platformWindow) return;

#if defined(KNGN_ENABLE_MENU)
    // menu: detach the delivery target before releasing, so a late MenuTarget action cannot use freed memory
    platform_menu_window_will_destroy(platformWindow);
#endif
#if defined(KNGN_ENABLE_GAMEPAD)
    // gamepads: drop the reference when this window is the active one
    gamepadDetachWindow(platformWindow);
#endif

    @autoreleasepool {
        // 1. invalidate the view's back-reference (a later mouseDown: and friends return early)
        [platformWindow->view clearPlatformWindow];

        // 2. stop the CADisplayLink (cutting the callback's reference to the view)
        [platformWindow->view stopDisplayLink];

        // 3. detach the delegate before closing ourselves (so windowShouldClose does not wrongly push a quit).
        [platformWindow->window setDelegate:nil];
        platformWindow->quit_delegate = nil;
        // 4. close the window → NSWindow releases the contentView (the view)
        [platformWindow->window close];
    }

    // 5. free the PlatformWindow itself
    free(platformWindow);
}

// The consumer cancels the close request and keeps the window alive.
void platform_cancel_quit(PlatformWindow* platformWindow) {
    if (!platformWindow) return;
    platformWindow->quit_requested = false;
}

// Platform shutdown
void platform_shutdown(void) {
    // macOS needs no particular cleanup
}

// ========================================
// The implementation of the manual drawing API
// ========================================

// Poll events (non-blocking)
bool platform_poll_events(PlatformWindow* platformWindow) {
    if (!platformWindow) return false;

    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];

        // Poll events (without blocking)
        NSEvent* event;
        while ((event = [app nextEventMatchingMask:NSEventMaskAny
                                         untilDate:[NSDate distantPast]
                                            inMode:NSDefaultRunLoopMode
                                           dequeue:YES])) {
            // Add a keyboard event to the event queue
            if (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) {
#if defined(KNGN_ENABLE_MENU)
                // Preventing a keyEquivalent from firing twice:
                // this loop does not [NSApp sendEvent:] a key event but pushes it straight onto the C event queue,
                // so AppKit's standard sendEvent → mainMenu performKeyEquivalent path is never taken.
                // performKeyEquivalent is therefore delegated to the shared menu TU explicitly, and once it is consumed no key_down is pushed.
                // A menu action pushes PLATFORM_EVENT_MENU_COMMAND onto the queue synchronously.
                if (event.type == NSEventTypeKeyDown) {
                    if (platform_menu_consume_key_equivalent((__bridge void*)event)) {
                        continue;
                    }
                }
#endif
                PlatformEvent platform_event;
                memset(&platform_event, 0, sizeof(platform_event));
                platform_event.type = (event.type == NSEventTypeKeyDown)
                    ? PLATFORM_EVENT_KEY_DOWN
                    : PLATFORM_EVENT_KEY_UP;
                platform_event.payload.keyboard.key = mapKeyCodeToPlatform(event.keyCode);
                platform_event.payload.keyboard.is_repeat = event.isARepeat;
                platform_event.payload.keyboard.modifiers = extractModifiers(event.modifierFlags);
                EventQueueToken token = queue_push(&platformWindow->event_queue, &platform_event);
                key_trace("key_%s push=%d slot=%d gen=%u key=%d mods=0x%X", event.type == NSEventTypeKeyDown ? "down" : "up", token.valid, token.index, token.generation, platform_event.payload.keyboard.key, platform_event.payload.keyboard.modifiers);

                // keyDown: push the physical key_down and then go on to the IME / inputContext path.
                // insertText: is the only source of char_input; the event.characters are never read directly
                // (which would double the input and bypass the IME). sendEvent is not called (the beep is absorbed by doCommandBySelector).
                if (event.type == NSEventTypeKeyDown && platformWindow->view) {
                    FramebufferView* view = platformWindow->view;
                    const BOOL hadMarked = [view hasMarkedText];
                    BOOL handled = NO;
                    const BOOL hasInputContext = [view inputContext] != nil;
                    // When the application controls text input, hand the event to the IME only while it is active.
                    // Uncontrolled (imeControlled==NO) always hands it over, as before. When it is not handed over,
                    // insertText/setMarkedText never fire, so the physical key_down is not tombstoned and survives.
                    const BOOL routeToIme = [view imeRouteEnabled];
                    if (hasInputContext && routeToIme) {
                        handled = [[view inputContext] handleEvent:event];
                    }
                    const BOOL hasMarked = [view hasMarkedText];
                    const BOOL commandModified = (platform_event.payload.keyboard.modifiers & (PLATFORM_MOD_CMD | PLATFORM_MOD_CTRL)) != 0;
                    const BOOL tombstone = token.valid && hasInputContext && routeToIme && !commandModified && (hadMarked || hasMarked) && queue_mark_none(&platformWindow->event_queue, token);
                    key_trace("handleEvent bool=%d marked=%d->%d route=%d tombstone=%d", handled, hadMarked, hasMarked, routeToIme, tombstone);
                }

                // The key event has been handled, so it is not passed on to the system (which prevents the beep)
                continue;
            }

            [app sendEvent:event];
            [app updateWindows];
        }

        // Check whether the window has been closed
        if (![platformWindow->window isVisible]) {
            // Add a QUIT event to the queue
            PlatformEvent quit_event;
            quit_event.type = PLATFORM_EVENT_QUIT;
            queue_push(&platformWindow->event_queue, &quit_event);
            return false;
        }

        return true;
    }
}

// Read a high-resolution monotonic time (unadjusted)
double platform_get_time(void) {
    uint64_t ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    return (double)ns / 1e9;
}

// Main-screen refresh rate in Hz. Returns 0 when unavailable.
// Queried once at startup (event time), never per frame.
double platform_display_refresh_hz(void) {
    NSScreen* screen = [NSScreen mainScreen];
    if (!screen) return 0.0;
    const NSInteger fps = screen.maximumFramesPerSecond;
    if (fps <= 0) return 0.0;
    return (double)fps;
}

// Begin accessing the framebuffer (the existing wrapper; the width/height projection of lock_ex)
uint32_t* platform_lock_framebuffer(PlatformWindow* platformWindow, int* out_width, int* out_height) {
    PlatformFramebufferMetrics metrics;
    uint32_t* px = platform_lock_framebuffer_ex(platformWindow, &metrics);
    if (!px) return NULL;
    if (out_width) *out_width = (int)metrics.framebuffer_width;
    if (out_height) *out_height = (int)metrics.framebuffer_height;
    return px;
}

bool platform_get_framebuffer_metrics(PlatformWindow* platformWindow, PlatformFramebufferMetrics* out) {
    if (!platformWindow || !out) return false;
    FramebufferView* view = platformWindow->view;
    if (!view) return false;
    // The current query: it reflects the pending or current negotiated scale at once (for normalising input before a lock)
    [view fillMetrics:out forQuery:YES];
    return true;
}

uint32_t* platform_lock_framebuffer_ex(PlatformWindow* platformWindow, PlatformFramebufferMetrics* out) {
    if (!platformWindow) return NULL;
    FramebufferView* view = platformWindow->view;
    if (!view) return NULL;

    // Latch the pending scale and size (only on success are the buffer, scale and epoch committed atomically)
    [view applyLatchedMetricsIfNeeded];
    // the latched snapshot (all four fields belong to the same frame)
    if (out) [view fillMetrics:out forQuery:NO];

    // Return currentBuffer (the buffer the user writes into)
    return [view getCurrentBuffer];
}

// Finish accessing the framebuffer
void platform_unlock_framebuffer(PlatformWindow* platformWindow) {
    // Nothing in particular is needed in this API
    // The buffers are swapped in platform_present()
    (void)platformWindow;
}

// Update the screen
void platform_present(PlatformWindow* platformWindow) {
    if (!platformWindow) return;

    @autoreleasepool {
        FramebufferView* view = platformWindow->view;

        // Draw manually, through the accessors
        [view presentManual];
    }
}

// Set the cursor shape. An unknown value falls back to PLATFORM_CURSOR_DEFAULT.
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

// Register the live-resize redraw callback. cb==NULL unregisters.
void platform_set_redraw_callback(PlatformWindow* platformWindow, PlatformRedrawCallback cb, void* userdata) {
    if (!platformWindow) return;
    @autoreleasepool {
        [platformWindow->view setRedrawCallback:cb userdata:userdata];
    }
}

// The IME composition preedit snapshot
uint32_t platform_get_composition_snapshot(PlatformWindow* window, char* buf, uint32_t cap, PlatformCompositionMeta* meta) {
    if (meta) {
        meta->revision = 0;
        meta->cursor = 0;
        meta->len = 0;
    }
    if (!window || !window->view) return 0;
    return [window->view copyCompositionSnapshot:buf cap:cap meta:meta];
}

void platform_set_composition_rect(PlatformWindow* window, int32_t x, int32_t y, int32_t w, int32_t h) {
    if (!window || !window->view) return;
    [window->view setCompositionRectPixelsX:x y:y w:w h:h];
}

// Tell the platform whether a text editing widget has focus. One call makes it controlled from then
// on, and keyDown reaches the IME (inputContext) only while active (an application that never calls it always hands it over, as before).
// A transition to active==false discards any pending composition (the equivalent of MacVim's abandonMarkedText).
void platform_set_text_input_active(PlatformWindow* window, bool active) {
    if (!window || !window->view) return;
    [window->view setTextInputActive:(active ? YES : NO)];
}

void platform_set_text_input_document_access(
    PlatformWindow* window,
    const PlatformTextInputDocumentCallbacks* callbacks,
    void* userdata
) {
    if (!window || !window->view) return;
    [window->view setTextInputDocumentAccess:callbacks userdata:userdata];
}

// Take a snapshot of the event queue counters
void platform_get_event_stats(PlatformWindow* window, PlatformEventStats* out) {
    if (!window || !out) return;
    EventQueue* q = &window->event_queue;
    out->mouse_move_merge_count = q->mouse_move_merge_count;
    out->mouse_scroll_merge_count = q->mouse_scroll_merge_count;
    out->event_drop_count = q->event_drop_count;
}

// The event API
bool platform_get_event(PlatformWindow* window, PlatformEvent* event) {
    if (!window || !event) return false;

    EventQueue* queue = &window->event_queue;

    // when the queue is empty
    if (queue->head == queue->tail) {
        return false;
    }

    // Take the next event from the queue
    *event = queue->events[queue->tail];
    queue->tail = (queue->tail + 1) % EVENT_QUEUE_SIZE;

    return true;
}

// The native menu itself lives in platform_macos_menu.m (the shared TU).
// This file holds only the EventQueue bridge (platform_menu_enqueue_command) and the
// keyEquivalent consumption call in the poll loop.

// ========================================
// Gamepad input (ADR-009)
// ========================================
//
// Opt-in: `platform_get_gamepad_state` is declared unconditionally in platform.h, so the symbol has
// to be defined even in an executable without the opt-in. An always-false fallback that references
// no GameController type is provided in the #else branch, rather than relying on dead code
// elimination on the Zig side to avoid a link error (defensive by design).
#if defined(KNGN_ENABLE_GAMEPAD)
//
// GCExtendedGamepad.buttonA/B/X/Y are already normalised by Apple by physical position (the A/B and
// X/Y swap of a Nintendo-style controller is absorbed by the GameController framework itself; Apple's
// documentation says they "refer to conceptual roles based on physical position, similar to Xbox
// layout"), so this implementation only has to map them one to one. A stick's Y axis passes on
// GameController's raw value (up = +1); flipping it into screen coordinates is the consumer's job
// (inheriting the raw value contract of ADR-009).
//
// Hot path declaration: called once per frame, but it is a fixed-length copy of four pads with a few
// fields each (no allocation, no lock), which is neither an all-pixel loop nor real time, so the performance rules do not apply (see ADR-009).
bool platform_get_gamepad_state(PlatformWindow* window, int index, PlatformGamepadState* out_state) {
    (void)window;
    if (!out_state || index < 0 || index >= PLATFORM_MAX_GAMEPADS) return false;
    GCController* controller = g_gamepad_slots[index];
    if (!controller) return false;
    GCExtendedGamepad* pad = controller.extendedGamepad;
    if (!pad) return false; // A guard for a profile that changes to an unsupported one after connecting (it does not normally happen)

    uint32_t mask = 0;
    if (pad.buttonA.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_A;
    if (pad.buttonB.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_B;
    if (pad.buttonX.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_X;
    if (pad.buttonY.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_Y;
    if (pad.leftShoulder.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_LEFT_SHOULDER;
    if (pad.rightShoulder.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_RIGHT_SHOULDER;
    if (pad.buttonMenu.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_START;
    if (pad.buttonOptions.isPressed) mask |= PLATFORM_GAMEPAD_BUTTON_BACK; // nullable; messaging nil gives false
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
    return false; // the opt-in is off (no GameController type is referenced at all)
}
#endif // KNGN_ENABLE_GAMEPAD

// ========================================
// File selection dialogs
// ========================================
// The extension filter uses allowedContentTypes (UTType), which is macOS 11 and later only
// (allowedFileTypes was deprecated in macOS 12). It links the UniformTypeIdentifiers framework.
// When UTType is nil for an unknown extension, this falls back to no filter (everything allowed).
// fileSystemRepresentation is valid only while the autorelease pool lives, so it is strdup'd on the spot.

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

// ========================================
// The OS text clipboard
// ========================================

static uint32_t clipboardUtf8TruncateLen(const char* bytes, uint32_t len, uint32_t cap) {
    uint32_t n = len < cap ? len : cap;
    while (n > 0 && n < len && (((unsigned char)bytes[n]) & 0xC0) == 0x80) {
        n--;
    }
    return n;
}

void platform_set_clipboard_text(const char* utf8, uint32_t len) {
    if (!utf8 && len > 0) return;
    @autoreleasepool {
        NSPasteboard* pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        NSString* str = [[NSString alloc] initWithBytes:(utf8 ? utf8 : "")
                                                 length:len
                                               encoding:NSUTF8StringEncoding];
        if (!str) return;
        [pb setString:str forType:NSPasteboardTypeString];
    }
}

bool platform_get_clipboard_text(char* out, uint32_t cap, uint32_t* out_len) {
    if (out_len) *out_len = 0;
    if (!out || cap == 0) return false;
    @autoreleasepool {
        NSPasteboard* pb = [NSPasteboard generalPasteboard];
        NSString* str = [pb stringForType:NSPasteboardTypeString];
        if (!str) return false;
        NSData* data = [str dataUsingEncoding:NSUTF8StringEncoding];
        if (!data) return false;
        const char* bytes = (const char*)[data bytes];
        const uint32_t len = (uint32_t)[data length];
        const uint32_t n = clipboardUtf8TruncateLen(bytes, len, cap);
        memcpy(out, bytes, n);
        if (out_len) *out_len = n;
        return true;
    }
}
