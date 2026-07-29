#ifndef PLATFORM_H
#define PLATFORM_H

#include <stdint.h>
#include <stdbool.h>

// The platform abstraction layer.
// One interface shared by Windows, Linux and macOS.

// An opaque window handle.
typedef struct PlatformWindow PlatformWindow;

// The framebuffer callback type.
// Called once per frame so that user code can update the pixel data.
// pixels: a 32-bit pixel array in canonical BGRA (u32 0xAARRGGBB / memory [B,G,R,A], width * height)
// width, height: the framebuffer size
// userdata: the user data handed to the platform at initialisation
typedef void (*FrameCallback)(uint32_t* pixels, int width, int height, void* userdata);

// Initialise the platform.
// Returns true on success, false on failure.
bool platform_init(void);

// Create a window.
// width, height: the window size in pixels
// title: the window title
// callback: the draw callback invoked once per frame
// userdata: the user data passed to the callback
// Returns: the window handle, or NULL on failure
PlatformWindow* platform_create_window(int width, int height, const char* title,
                                       FrameCallback callback, void* userdata);

// Turn an already-created window into a real fullscreen window.
// The facade's Window.createFullscreen calls this right after create. On macOS this is NSWindow's
// toggleFullScreen: (the same as the green button; a no-op when the window is already fullscreen).
void platform_enter_fullscreen(PlatformWindow* window);

// ========================================
// Transparent / borderless windows and interactive drag-to-move
// ========================================
//
// An extension for the floating, frameless windows that let the desktop show through (a desktop mascot,
// say). Transparency honours the framebuffer alpha (premultiplied alpha is assumed while transparent;
// when opaque, alpha is ignored as before). Drag-to-move is delegated to the OS's interactive window
// move, so that it also works where a client cannot set an absolute position, as on Wayland; on macOS
// it is performWindowDragWithEvent:.

// Window creation options (bit flags). opts==NULL means the default (opaque, with a title bar).
// x/y are read only when PLATFORM_WINDOW_POSITION is set (otherwise the usual placement, centred).
typedef struct PlatformWindowOptions {
    uint32_t flags;     // an OR of PLATFORM_WINDOW_*
    uint32_t reserved;  // reserved for future use (zero-filled; a non-zero value returns NULL)
    int32_t x;          // OS screen coordinates
    int32_t y;
} PlatformWindowOptions;

#define PLATFORM_WINDOW_TRANSPARENT (1u << 0)  // honour the framebuffer alpha (the desktop shows through)
#define PLATFORM_WINDOW_BORDERLESS  (1u << 1)  // no title bar and no frame (borderless)
#define PLATFORM_WINDOW_POSITION    (1u << 2)  // apply x/y as the initial position
#define PLATFORM_WINDOW_FRAMEBUFFER_PHYSICAL (1u << 3)  // opt in to a physical framebuffer; unset = .logical

// The current window geometry. The size is the content/client area; the position is in OS screen coordinates.
// When flags lacks PLATFORM_GEOMETRY_POSITION_VALID, x/y are undefined (position unsupported, or unreadable).
typedef struct PlatformWindowGeometry {
    int32_t x;
    int32_t y;
    uint32_t width;
    uint32_t height;
    uint32_t flags; // an OR of PLATFORM_GEOMETRY_*
} PlatformWindowGeometry;

#define PLATFORM_GEOMETRY_POSITION_VALID (1u << 0)

// Create a window with options (an extension of platform_create_window).
// opts==NULL behaves exactly like platform_create_window. Unknown flags or reserved!=0 return NULL
// rather than being ignored silently (the facade turns that into error.Unsupported).
// The function signature is fixed. The position is read only when PLATFORM_WINDOW_POSITION is set.
PlatformWindow* platform_create_window_ex(int width, int height, const char* title,
                                          FrameCallback callback, void* userdata,
                                          const PlatformWindowOptions* opts);

// Read the current window geometry. A NULL window or a NULL out is a no-op.
// On failure out is zero-filled and nothing crashes (the position is reported as not VALID).
void platform_get_window_geometry(PlatformWindow* window, PlatformWindowGeometry* out);

// Update the title of a visible window (event time only).
void platform_set_title(PlatformWindow* window, const char* title);

// Start the OS's interactive window move from the most recent pointer press (the OS performs the move).
// An application calls this when it receives a mouse_down inside the region the user can grab. macOS
// hands the retained most recent left-button mouse-down NSEvent to performWindowDragWithEvent: and
// clears the retained event (one-shot; a no-op if nothing is retained). Called only on a mouse_down.
void platform_begin_window_drag(PlatformWindow* window);

// Set always-on-top. macOS switches NSWindow.level. Event time only.
void platform_set_always_on_top(PlatformWindow* window, bool on);

// Set per-pixel click-through. While on, a click over a pixel whose alpha is 0 in the most recently presented
// frame passes through to the application behind, and only a click over alpha>0 (the visible artwork) reaches
// the window: a mascot can be dragged while its transparent margin falls through. Event time only.
void platform_set_click_through(PlatformWindow* window, bool on);

// Show or hide the Dock icon and the menu bar (application-wide, not per window).
// visible=false selects NSApplicationActivationPolicyAccessory (behaving like a background app).
void platform_set_dock_visible(bool visible);

// Pop up a quit menu (from a right click, say: a native menu with the single item "Quit").
// Choosing it pushes QUIT onto the window's event queue (modal; choosing nothing does nothing).
void platform_show_quit_menu(PlatformWindow* window);

// Start the main event loop (blocking).
// Does not return until the window is closed.
void platform_run(PlatformWindow* window);

// Destroy a window.
void platform_destroy_window(PlatformWindow* window);

// Clean up the platform.
void platform_shutdown(void);

// ========================================
// The manual drawing API (it can coexist with the callback style)
// ========================================

// Poll events (non-blocking).
// Returns true while the window is open, and false once it has been closed.
// Calling this is what makes OS events be processed.
bool platform_poll_events(PlatformWindow* window);

// Read a high-resolution monotonic time (in seconds, as a double).
//
// Properties:
// - Monotonic: the time only increases and never goes backwards
// - Unadjusted (RAW): unaffected by NTP and other system clock adjustments
// - High resolution: sub-microsecond, depending on the platform
//   * Windows: ~100ns (QueryPerformanceCounter)
//   * macOS: ~1ns (CLOCK_UPTIME_RAW)
//   * Linux: ~1ns (CLOCK_MONOTONIC_RAW)
//
// Returns:
// - The seconds elapsed since system boot or process start
// - The absolute value carries no meaning (use it only to compute differences)
//
// Uses:
// - Measuring a frame interval: dt = current_time - last_time
// - Driving animation
// - Benchmarking and profiling
//
// Notes:
// - This clock has nothing to do with the system wall clock
// - Network synchronisation needs separate server-side time management
// - Over a long run the drift against the system clock can accumulate
double platform_get_time(void);

// Display refresh rate in Hz (main screen). Returns 0 on failure / unavailable.
// Queried once at startup (event time), never per frame.
double platform_display_refresh_hz(void);

// Begin accessing the framebuffer.
// out_width, out_height: receive the framebuffer size
// Returns: a pointer to the pixel buffer (canonical BGRA, u32 0xAARRGGBB, 32-bit)
//   - NULL can mean "there is no drawable frame slot right now": a retryable state (frame slot unavailable).
//     The caller may skip drawing that frame, run pollEvents and wait for the next opportunity
//     (the macOS backend never returns NULL today; a first-class backend such as Wayland does, paced by its frame callback and by busy buffers).
//   - Fatal conditions such as a lost device or a destroyed window are handled apart from this NULL (see docs/adr/005).
// Note: the buffer stays held until platform_unlock_framebuffer() is called.
uint32_t* platform_lock_framebuffer(PlatformWindow* window, int* out_width, int* out_height);

// The current and latched metrics: the logical and framebuffer size, content_scale and scale_epoch.
// platform_lock_framebuffer_ex is the atomic unit of lock + scale latch + metrics copy.
// platform_lock_framebuffer is a width/height projection of ex (its signature is unchanged).
typedef struct PlatformFramebufferMetrics {
    uint32_t logical_width;
    uint32_t logical_height;
    uint32_t framebuffer_width;
    uint32_t framebuffer_height;
    float content_scale;
    uint64_t scale_epoch;
} PlatformFramebufferMetrics;

bool platform_get_framebuffer_metrics(
    PlatformWindow* window, PlatformFramebufferMetrics* out);
uint32_t* platform_lock_framebuffer_ex(
    PlatformWindow* window, PlatformFramebufferMetrics* out);

// Finish accessing the framebuffer.
// Pairs with platform_lock_framebuffer().
void platform_unlock_framebuffer(PlatformWindow* window);

// ========================================
// The cursor API
// ========================================

// The shape of the system cursor. There are only three: identifying the current tool is left to a soft
// overlay drawn by the application, so the hard OS cursor serves the precision point alone and needs
// no more than crosshair, default and hidden.
typedef enum {
    PLATFORM_CURSOR_DEFAULT = 0,   // the standard arrow
    PLATFORM_CURSOR_CROSSHAIR = 1, // a crosshair (for precise work, on a canvas say)
    PLATFORM_CURSOR_HIDDEN = 2,    // hidden (while the application draws a soft overlay, say)
} PlatformCursorShape;

// Set the cursor shape.
// Call frequency: event time only (a tool change, a key press). Never once per frame.
// shape holds a PlatformCursorShape value but is taken as an int rather than as the enum type
// (see the implementation of platform_set_cursor).
// An unknown value falls back to PLATFORM_CURSOR_DEFAULT. On macOS it reaches NSCursor immediately.
void platform_set_cursor(PlatformWindow* window, int shape);

// ========================================
// The live-resize redraw callback
// ========================================
//
// An opt-in way for the OS's modal, nested event-tracking loop (while the frame is being dragged) to
// tell the application "draw one frame now", and nothing more. No pixels are handed over: the
// application runs its usual lockFramebuffer → draw → present.
// cb == NULL unregisters. A single window is assumed.

typedef void (*PlatformRedrawCallback)(void* userdata);
void platform_set_redraw_callback(PlatformWindow* window, PlatformRedrawCallback cb, void* userdata);

// Present: submit the frame most recently locked to the display queue.
// What was written through platform_lock_framebuffer() is sent to the display queue.
//
// Behaviour:
// - This is fundamentally a non-blocking submit (it does not wait for display refresh); blocking
//   briefly under resource pressure or a full set of inflight slots is allowed (see Metal below)
// - It is the frame commit point (the harness commits its frame here)
// - After a present the pixels belong to the backend / WindowServer / GPU, and the caller does not touch them until the next lock
//
// Frame pacing and tearing (this depends on the backend's support tier):
// - A first-class backend (Metal / D3D11-DXGI / Wayland) is fifo, synchronised to display refresh, and treats avoiding tearing as a guarantee
//   * Once Metal reaches its inflight limit (a triple slot plus a semaphore), the submit can block
//     briefly until the next frame slot frees up (that is fifo pacing, paced by display refresh); lockFramebuffer keeps returning non-null
// - A best-effort backend (macOS CALayer objc/swift / X11 / GDI) guarantees neither strict vsync nor freedom from tearing
//
// Notes:
// - Rate control of a game loop is the caller's responsibility (platform_get_time() and sleep(), or a future beginFrame/waitFrame)
// - The authority on the present / lockFramebuffer / frame pacing contracts is docs/adr/002 (revised) and docs/adr/005
void platform_present(PlatformWindow* window);

// ========================================
// The event API
// ========================================

// Event types
typedef enum {
    PLATFORM_EVENT_NONE = 0,
    PLATFORM_EVENT_QUIT,
    PLATFORM_EVENT_KEY_DOWN,
    PLATFORM_EVENT_KEY_UP,
    PLATFORM_EVENT_MOUSE_MOVE,
    PLATFORM_EVENT_MOUSE_DOWN,
    PLATFORM_EVENT_MOUSE_UP,
    PLATFORM_EVENT_MOUSE_SCROLL,
    PLATFORM_EVENT_CHAR_INPUT,   // a committed text character (appended at the end, so backwards compatible)
    PLATFORM_EVENT_GAMEPAD_CONNECTED,    // a gamepad was connected (appended at the end, so backwards compatible)
    PLATFORM_EVENT_GAMEPAD_DISCONNECTED, // a gamepad was disconnected
    PLATFORM_EVENT_COMPOSITION,  // the IME composition state changed (appended at the end, so backwards compatible)
    PLATFORM_EVENT_MENU_COMMAND, // a native menu selection (appended at the end; the payload is a numeric Command id)
    PLATFORM_EVENT_FILE_DROP,    // an OS file drag and drop (appended at the end; the path is inline)
} PlatformEventType;

// The upper bound on a dropped file path (macOS PATH_MAX=1024; anything longer is rejected)
#define PLATFORM_FILE_DROP_PATH_BYTES 1024
#define PLATFORM_FILE_DROP_MAX_PATHS 1

// The IME composition phase (the values match Zig's CompositionPhase)
typedef enum {
    PLATFORM_COMPOSITION_PHASE_START = 0,
    PLATFORM_COMPOSITION_PHASE_UPDATE = 1,
    PLATFORM_COMPOSITION_PHASE_COMMIT = 2,
    PLATFORM_COMPOSITION_PHASE_CANCEL = 3,
} PlatformCompositionPhase;

// Mouse buttons (physical buttons, matching NSEvent.buttonNumber)
// A C enum has no specified storage type, so it is int wide; the Zig side takes it as enum(c_int).
typedef enum {
    PLATFORM_MOUSE_BUTTON_NONE = 0xFF,    // when the button field is meaningless, as in MOUSE_MOVE
    PLATFORM_MOUSE_BUTTON_LEFT = 0,
    PLATFORM_MOUSE_BUTTON_RIGHT = 1,
    PLATFORM_MOUSE_BUTTON_MIDDLE = 2,
} PlatformMouseButton;

// The bit-mask form of PlatformMouseButton (LSB first: 0x01=left, 0x02=right, 0x04=middle)
typedef enum {
    PLATFORM_MOUSE_BUTTON_FLAG_LEFT   = 0x01,
    PLATFORM_MOUSE_BUTTON_FLAG_RIGHT  = 0x02,
    PLATFORM_MOUSE_BUTTON_FLAG_MIDDLE = 0x04,
} PlatformMouseButtonFlags;

// Key codes
// Virtual key codes based on the physical position on the keyboard
typedef enum {
    PLATFORM_KEY_UNKNOWN = -1,

    // printable characters (ASCII compatible)
    PLATFORM_KEY_SPACE = 32,
    PLATFORM_KEY_0 = 48,
    PLATFORM_KEY_1 = 49,
    PLATFORM_KEY_2 = 50,
    PLATFORM_KEY_3 = 51,
    PLATFORM_KEY_4 = 52,
    PLATFORM_KEY_5 = 53,
    PLATFORM_KEY_6 = 54,
    PLATFORM_KEY_7 = 55,
    PLATFORM_KEY_8 = 56,
    PLATFORM_KEY_9 = 57,
    PLATFORM_KEY_A = 65,
    PLATFORM_KEY_B = 66,
    PLATFORM_KEY_C = 67,
    PLATFORM_KEY_D = 68,
    PLATFORM_KEY_E = 69,
    PLATFORM_KEY_F = 70,
    PLATFORM_KEY_G = 71,
    PLATFORM_KEY_H = 72,
    PLATFORM_KEY_I = 73,
    PLATFORM_KEY_J = 74,
    PLATFORM_KEY_K = 75,
    PLATFORM_KEY_L = 76,
    PLATFORM_KEY_M = 77,
    PLATFORM_KEY_N = 78,
    PLATFORM_KEY_O = 79,
    PLATFORM_KEY_P = 80,
    PLATFORM_KEY_Q = 81,
    PLATFORM_KEY_R = 82,
    PLATFORM_KEY_S = 83,
    PLATFORM_KEY_T = 84,
    PLATFORM_KEY_U = 85,
    PLATFORM_KEY_V = 86,
    PLATFORM_KEY_W = 87,
    PLATFORM_KEY_X = 88,
    PLATFORM_KEY_Y = 89,
    PLATFORM_KEY_Z = 90,

    // editing keys
    PLATFORM_KEY_TAB = 258,
    PLATFORM_KEY_BACKSPACE = 259,
    PLATFORM_KEY_INSERT = 260,
    PLATFORM_KEY_DELETE = 261,
    PLATFORM_KEY_PAGE_UP = 267,
    PLATFORM_KEY_PAGE_DOWN = 268,
    PLATFORM_KEY_HOME = 269,
    PLATFORM_KEY_END = 270,

    // special keys
    PLATFORM_KEY_ESCAPE = 256,
    PLATFORM_KEY_ENTER = 257,
    PLATFORM_KEY_LEFT = 263,
    PLATFORM_KEY_RIGHT = 264,
    PLATFORM_KEY_UP = 265,
    PLATFORM_KEY_DOWN = 266,

    // function keys (F1-F20)
    PLATFORM_KEY_F1 = 290,
    PLATFORM_KEY_F2 = 291,
    PLATFORM_KEY_F3 = 292,
    PLATFORM_KEY_F4 = 293,
    PLATFORM_KEY_F5 = 294,
    PLATFORM_KEY_F6 = 295,
    PLATFORM_KEY_F7 = 296,
    PLATFORM_KEY_F8 = 297,
    PLATFORM_KEY_F9 = 298,
    PLATFORM_KEY_F10 = 299,
    PLATFORM_KEY_F11 = 300,
    PLATFORM_KEY_F12 = 301,
    PLATFORM_KEY_F13 = 302,
    PLATFORM_KEY_F14 = 303,
    PLATFORM_KEY_F15 = 304,
    PLATFORM_KEY_F16 = 305,
    PLATFORM_KEY_F17 = 306,
    PLATFORM_KEY_F18 = 307,
    PLATFORM_KEY_F19 = 308,
    PLATFORM_KEY_F20 = 309,

    // the numeric keypad
    PLATFORM_KEY_KP_0 = 320,
    PLATFORM_KEY_KP_1 = 321,
    PLATFORM_KEY_KP_2 = 322,
    PLATFORM_KEY_KP_3 = 323,
    PLATFORM_KEY_KP_4 = 324,
    PLATFORM_KEY_KP_5 = 325,
    PLATFORM_KEY_KP_6 = 326,
    PLATFORM_KEY_KP_7 = 327,
    PLATFORM_KEY_KP_8 = 328,
    PLATFORM_KEY_KP_9 = 329,
    PLATFORM_KEY_KP_DECIMAL = 330,
    PLATFORM_KEY_KP_DIVIDE = 331,
    PLATFORM_KEY_KP_MULTIPLY = 332,
    PLATFORM_KEY_KP_SUBTRACT = 333,
    PLATFORM_KEY_KP_ADD = 334,
    PLATFORM_KEY_KP_ENTER = 335,
    PLATFORM_KEY_KP_EQUAL = 336,

    // modifier keys (for pressing them on their own)
    PLATFORM_KEY_LEFT_SHIFT = 340,
    PLATFORM_KEY_LEFT_CONTROL = 341,
    PLATFORM_KEY_LEFT_ALT = 342,
    PLATFORM_KEY_LEFT_SUPER = 343,        // Command (macOS) / Windows key
    PLATFORM_KEY_RIGHT_SHIFT = 344,
    PLATFORM_KEY_RIGHT_CONTROL = 345,
    PLATFORM_KEY_RIGHT_ALT = 346,
    PLATFORM_KEY_RIGHT_SUPER = 347,       // Command (macOS) / Windows key

    // other keys
    PLATFORM_KEY_CAPS_LOCK = 280,
    PLATFORM_KEY_PRINT_SCREEN = 283,
    PLATFORM_KEY_PAUSE = 284,
} PlatformKeyCode;

// Modifier keys
typedef enum {
    PLATFORM_MOD_SHIFT = 0x01,
    PLATFORM_MOD_CTRL = 0x02,
    PLATFORM_MOD_ALT = 0x04,
    PLATFORM_MOD_CMD = 0x08,  // macOS Command, Windows Super
} PlatformModifierFlags;

// The event struct
typedef struct PlatformEvent {
    PlatformEventType type;

    union {
        struct {
            PlatformKeyCode key;
            bool is_repeat;
            uint32_t modifiers;
        } keyboard;
        struct {
            // x, y: the origin is the top-left of the window contentRect, in window logical units (the same
            // units as view.bounds), already floored to integers; converting to framebuffer or canvas coordinates is the caller's job.
            // While a button is held, coordinates outside the window are passed through unclamped, negative values included.
            int32_t x, y;
            PlatformMouseButton button;   // valid for MOUSE_DOWN / MOUSE_UP only; PLATFORM_MOUSE_BUTTON_NONE on MOUSE_MOVE
            uint8_t buttons_mask;         // a bitmask of the buttons currently held (post-state, already masked with & 0x07)
            uint32_t modifiers;
        } mouse;
        struct {
            int32_t x, y;                 // window coordinates (the same units as mouse)
            float dx, dy;                 // the same units as window coordinates (line units are already scaled by scrollerLineHeight)
            bool is_precise;              // true: a trackpad (continuous); false: a wheel (already converted from lines to window units)
            uint8_t buttons_mask;         // post-state
            uint32_t modifiers;
        } scroll;
        struct {
            uint32_t codepoint;           // the Unicode scalar value of the committed character (UTF-32)
            uint32_t modifiers;
        } character;
        struct {
            int32_t index;                // a pad index within the PLATFORM_MAX_GAMEPADS range
            char name[33];                 // a NUL-terminated device name (32 bytes + NUL; anything longer is truncated).
                                            // Set on CONNECTED only; empty on DISCONNECTED.
        } gamepad;
        struct {
            uint32_t revision;            // for matching a snapshot; incremented on every setMarkedText/unmark/insert
            uint8_t phase;                // PlatformCompositionPhase
            uint32_t cursor;              // the UTF-8 byte offset within the preedit (the caret)
        } composition;                    // the text itself comes from platform_get_composition_snapshot
        struct {
            uint32_t command_id;          // the application's CommandId (numeric)
        } menu;
        // An OS file drop. bytes[0..len] is the UTF-8 path itself (NUL termination is not part of the contract).
        // The PlatformEvent queued here owns the path; no separate free function is added for a drag.
        // count is 0 or 1 (a single file; a simultaneous multi-file drop rejects the whole event).
        struct {
            uint32_t count;
            struct {
                uint32_t len;
                char bytes[PLATFORM_FILE_DROP_PATH_BYTES];
            } paths[PLATFORM_FILE_DROP_MAX_PATHS];
        } file_drop;
    } payload;
} PlatformEvent;

// A contract helper, shared by objc/swift/metal, that fills in a file_drop event struct.
// Swift's C importer cannot import an anonymous struct holding a nested array (file_drop.paths[].bytes)
// as a field, so the Swift and Metal backends can only build a file_drop through this C helper; objc uses
// the same function, which single-sources the contract (a single file; empty, over-long or NUL-containing
// paths are rejected). It validates utf8[0..len), fills ev as a FILE_DROP and returns true on success, or
// returns false with ev untouched. The caller passes a zero-initialised ev (Swift PlatformEvent(), objc memset; no string.h).
static inline bool platform_fill_file_drop_event(PlatformEvent* ev, const char* utf8, uint32_t len) {
    if (len == 0 || len > PLATFORM_FILE_DROP_PATH_BYTES) return false;
    for (uint32_t i = 0; i < len; i++) {
        if (utf8[i] == 0) return false; // a NUL inside the path is rejected (the contract)
    }
    ev->type = PLATFORM_EVENT_FILE_DROP;
    ev->payload.file_drop.count = 1;
    ev->payload.file_drop.paths[0].len = len;
    for (uint32_t i = 0; i < len; i++) {
        ev->payload.file_drop.paths[0].bytes[i] = utf8[i];
    }
    return true;
}

// The metadata of an IME composition snapshot (the text goes into the caller's buf, as UTF-8)
typedef struct PlatformCompositionMeta {
    uint32_t revision;
    uint32_t cursor;   // the UTF-8 byte offset within the preedit
    uint32_t len;      // the bytes written into buf (already truncated to cap; no NUL appended)
} PlatformCompositionMeta;

// Write the current preedit text into buf. Returns the bytes written (0 = empty, or not composing).
// meta is always filled in (revision/cursor/len = 0 when empty). A non-macOS or unsupported backend always returns 0.
// meta is filled in even when cap==0 or buf==NULL (only the text is not written).
uint32_t platform_get_composition_snapshot(PlatformWindow* window, char* buf, uint32_t cap, PlatformCompositionMeta* meta);

// Set the caret rect the IME candidate window is anchored to, in framebuffer pixels with the origin at the window content's top-left.
// The backend applies the backing scale when it answers firstRectForCharacterRange.
void platform_set_composition_rect(PlatformWindow* window, int32_t x, int32_t y, int32_t w, int32_t h);

// Tell the platform whether a text editing widget currently has focus.
// While active=false, keyDown is not handed to the inputContext (the IME), so even with an IME enabled an
// unmodified letter key is not swallowed into marked text and reaches the facade as key_down (shortcuts keep working).
// An application that never calls this keeps the always-IME path. A transition to false discards any pending composition.
void platform_set_text_input_active(PlatformWindow* window, bool active);

// ========================================
// IME document access (reconverting already-committed text)
// ========================================
//
// The application supplies the document that NSTextInputClient's selectedRange, attributedSubstring and
// insertText(replacementRange:) refer to. A range is in **UTF-16 code units** (the same contract as
// NSString/NSRange). location == UINT64_MAX is the NSNotFound sentinel.
//
// The callbacks are **for synchronous calls only**. The UTF-8 pointer returned by get_substring is borrowed
// only until that callback returns (the native side copies it into an NSString right afterwards). With no
// callbacks registered, selectedRange=NSNotFound / attributedSubstring=nil / insertText→char_input holds.

typedef struct PlatformTextInputRange {
    uint64_t location;
    uint64_t length;
} PlatformTextInputRange;

typedef bool (*PlatformTextInputGetSelectedRangeFn)(
    void* userdata,
    PlatformTextInputRange* out_range);

typedef bool (*PlatformTextInputGetSubstringFn)(
    void* userdata,
    PlatformTextInputRange proposed_range,
    const uint8_t** out_utf8,
    uint32_t* out_len,
    PlatformTextInputRange* out_actual_range);

typedef bool (*PlatformTextInputReplaceTextFn)(
    void* userdata,
    PlatformTextInputRange replacement_range,
    const uint8_t* utf8,
    uint32_t len);

typedef struct PlatformTextInputDocumentCallbacks {
    PlatformTextInputGetSelectedRangeFn get_selected_range;
    PlatformTextInputGetSubstringFn get_substring;
    PlatformTextInputReplaceTextFn replace_text;
} PlatformTextInputDocumentCallbacks;

// callbacks==NULL unregisters (and discards any pending replacement range). A single window is assumed.
void platform_set_text_input_document_access(
    PlatformWindow* window,
    const PlatformTextInputDocumentCallbacks* callbacks,
    void* userdata);

// Take one event at a time.
// Pops a single event from the window's event queue.
// Returns true if there was one, false if there was not.
bool platform_get_event(PlatformWindow* window, PlatformEvent* event);

// Counters observed on the event queue (cumulative values, read as a snapshot).
// Used by the examples to watch merging and to detect overflow.
typedef struct PlatformEventStats {
    uint64_t mouse_move_merge_count;    // how many times a mouse_move was merged into the tail
    uint64_t mouse_scroll_merge_count;  // how many times a mouse_scroll was merged into the tail
    uint64_t event_drop_count;          // how many events were dropped because the queue was full
} PlatformEventStats;

// Take a snapshot of the event queue counters
void platform_get_event_stats(PlatformWindow* window, PlatformEventStats* out);

// ========================================
// Gamepad input (ADR-009)
// ========================================
//
// The authority on the design is GamepadButton/GamepadButtons/GamepadState in core/platform_types.zig
// together with docs/adr/009_gamepad-input.md. A button's bit position follows the declaration order of
// the enum below (a=bit0 … guide=bit14) and matches the field order of GamepadButtons on the Zig side.
// Triggers are exposed as axes only, never as buttons. Sticks and triggers carry raw values (no deadzone).
//
// The macOS backends implement this behind `KNGN_ENABLE_GAMEPAD`, which build.zig passes only to an
// executable that uses a gamepad.

// The bit-mask form of PlatformGamepadState.buttons_mask
typedef enum {
    PLATFORM_GAMEPAD_BUTTON_A = 0x0001,
    PLATFORM_GAMEPAD_BUTTON_B = 0x0002,
    PLATFORM_GAMEPAD_BUTTON_X = 0x0004,
    PLATFORM_GAMEPAD_BUTTON_Y = 0x0008,
    PLATFORM_GAMEPAD_BUTTON_LEFT_SHOULDER = 0x0010,
    PLATFORM_GAMEPAD_BUTTON_RIGHT_SHOULDER = 0x0020,
    PLATFORM_GAMEPAD_BUTTON_BACK = 0x0040,
    PLATFORM_GAMEPAD_BUTTON_START = 0x0080,
    PLATFORM_GAMEPAD_BUTTON_LEFT_STICK = 0x0100,   // pressing the stick in (a click)
    PLATFORM_GAMEPAD_BUTTON_RIGHT_STICK = 0x0200,
    PLATFORM_GAMEPAD_BUTTON_DPAD_UP = 0x0400,
    PLATFORM_GAMEPAD_BUTTON_DPAD_DOWN = 0x0800,
    PLATFORM_GAMEPAD_BUTTON_DPAD_LEFT = 0x1000,
    PLATFORM_GAMEPAD_BUTTON_DPAD_RIGHT = 0x2000,
    PLATFORM_GAMEPAD_BUTTON_GUIDE = 0x4000,        // the Xbox button (the home button)
} PlatformGamepadButtonFlags;

// How many gamepads are supported at once
#define PLATFORM_MAX_GAMEPADS 4

// The normalised, pollable state of a gamepad
typedef struct PlatformGamepadState {
    uint32_t buttons_mask;              // a bit-or of PlatformGamepadButtonFlags
    float left_stick_x, left_stick_y;   // -1.0..1.0 (raw; no deadzone applied)
    float right_stick_x, right_stick_y; // -1.0..1.0
    float left_trigger, right_trigger;  // 0.0..1.0 (raw; triggers are exposed as axes only)
} PlatformGamepadState;

// Read the state of the gamepad at the given index (polling).
// Returns: true when it is connected (out_state has been written); false when disconnected or out of range.
bool platform_get_gamepad_state(PlatformWindow* window, int index, PlatformGamepadState* out_state);

// ========================================
// Native menus (the ADR contract is Command in core/command_types.zig)
// ========================================
//
// The C ABI contract:
// - Registration takes an array of PlatformMenuItem plus an explicit count (no sentinel terminator).
// - Strings are UTF-8, NUL-terminated, and **valid only for the duration of the call** (the backend copies them).
// - The hierarchy is one level of top menu plus its items (no submenus; a separator is expressed through kind).
// - The menu bar belongs to the application, so the window argument is ignored and the last registration replaces the whole bar.
// - Implemented by the macOS objc/swift/metal backends, compiled conditionally on `#if defined(KNGN_ENABLE_MENU)`
//   (the same shape as the gamepad opt-in; the shared translation unit is platform_macos_menu.m).
//   An executable that does not use menus references no menu symbol at all.

#define PLATFORM_MENU_KIND_NORMAL    0
#define PLATFORM_MENU_KIND_SEPARATOR 1

typedef struct PlatformMenuItem {
    uint32_t command_id;       // 0 for a separator
    uint8_t kind;              // PLATFORM_MENU_KIND_*
    const char* top_menu;      // the top menu name (for example "File"); NUL-terminated, valid only during the call
    const char* label;         // the item label; may be empty for a separator; NUL-terminated, valid only during the call
    int32_t shortcut_key;      // a PlatformKeyCode; -1 for no shortcut
    uint32_t shortcut_mods;    // PlatformModifierFlags; ignored when shortcut_key < 0
    uint8_t enabled;           // 0/1
    uint8_t checked;           // 0/1 (a toggle item)
} PlatformMenuItem;

// Whether native menus are available in this build (KNGN_ENABLE_MENU plus a macOS native implementation).
bool platform_menu_available(void);

// Replace the menu bar with items[0..count) (the last registration is the whole bar). window is ignored by contract.
void platform_register_menu(PlatformWindow* window, const PlatformMenuItem* items, uint32_t count);

// Update enabled/checked on the registered items, matched by command_id (the structure is left alone).
void platform_update_menu(PlatformWindow* window, const PlatformMenuItem* items, uint32_t count);

// Destroy the registered menu (returning mainMenu to empty).
void platform_destroy_menu(PlatformWindow* window);

// ========================================
// File selection dialogs
// ========================================
//
// Show a native file selection dialog synchronously and modally (application-modal, not tied to a
// window). It blocks the calling thread (the main thread) and does not return until the user dismisses
// the dialog. Never call it while the framebuffer is locked.

// Options for the save dialog
typedef struct PlatformSaveDialogOptions {
    const char* default_name;  // the initial file name (may be NULL)
    const char* allowed_ext;   // an extension filter, for example "png" (NULL = anything)
} PlatformSaveDialogOptions;

// Options for the open dialog
typedef struct PlatformOpenDialogOptions {
    const char* allowed_ext;   // an extension filter, for example "png" (NULL = anything)
} PlatformOpenDialogOptions;

// Let the user choose where to save.
// Returns: the chosen absolute path (NUL-terminated, malloc'd). The caller frees it with platform_free_path().
//          NULL on cancel or on error.
char* platform_save_file_dialog(const PlatformSaveDialogOptions* opts);

// Let the user choose a file to open (a single selection, files only).
// Returns: the chosen absolute path (NUL-terminated, malloc'd). The caller frees it with platform_free_path().
//          NULL on cancel or on error.
char* platform_open_file_dialog(const PlatformOpenDialogOptions* opts);

// Free a path string returned by platform_*_file_dialog(). NULL safe.
void platform_free_path(char* path);

// ========================================
// The OS text clipboard
// ========================================
//
// UTF-8 text only. Images, RTF and compound formats are out of scope.
// The implementation is NSPasteboard, provided by all three macOS backends (objc / swift / metal).
// (objc: platform_macos.m; swift and metal: platform_macos_shared.swift. The backends link exclusively.)

// Write UTF-8 text to the OS clipboard (len is a byte length; no NUL termination needed).
void platform_set_clipboard_text(const char* utf8, uint32_t len);

// Read UTF-8 text from the OS clipboard into a caller-owned buffer.
// Returns true on success (an empty string included; *out_len holds the byte length). Unsupported, no
// string present, or a failure returns false. Anything past cap is truncated at a UTF-8 code point boundary.
bool platform_get_clipboard_text(char* out, uint32_t cap, uint32_t* out_len);

#endif // PLATFORM_H
