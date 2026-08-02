import Cocoa
#if KNGN_ENABLE_DIALOG
import UniformTypeIdentifiers
#endif
#if KNGN_ENABLE_GAMEPAD
import GameController
#endif

// The shared code of the macOS Swift backends
// It gathers the C ABI, the event queue, the IME, gamepads, the menu bridge and the window creation
// skeleton that the swift (CALayer) and metal backends have in common. The backend-specific drawing
// lives in platform/macos-swift/platform_macos_swift.swift (CALayer) and
// platform/macos-metal/platform_macos_metal.swift (Metal), each conforming to PlatformBackendView
// and created through the makePlatformBackendView() factory.
//
// The type definitions (PlatformEvent, PlatformEventType, PlatformKeyCode, the PLATFORM_* constants,
//        the FrameCallback typealias and so on) come from the C header automatically, through the
//        bridging header (-import-objc-header platform/platform.h).
//
// OS file drag and drop (file URLs only) is implemented on the same contract as the objc backend.
// Each backend's view implements NSDraggingDestination and puts a single file URL onto the event_queue
// as a PLATFORM_EVENT_FILE_DROP by inline copy (several, non-file, empty, over-limit or NUL-containing paths are rejected).
// Filling the struct and validating the length and NULs are the shared helper enqueueFileDropIfValid (and beneath it platform.h's platform_fill_file_drop_event).

// ========================================
// Definitions for event handling (local to the Swift side)
// ========================================

let EVENT_QUEUE_SIZE = 256
let keyTraceEnabled = ProcessInfo.processInfo.environment["KNGN_KEY_TRACE"] == "1"
#if KNGN_ENABLE_TEXT_INPUT
// Diagnostics: a trace of IME and document access as it happens (off by default; KNGN_IME_TRACE=1 enables it).
let imeTraceEnabled = ProcessInfo.processInfo.environment["KNGN_IME_TRACE"] == "1"
#endif

func keyTrace(_ message: String) {
    guard keyTraceEnabled else { return }
    let line = Data("[key-trace] \(message)\n".utf8)
    FileHandle.standardError.write(line)
}

#if KNGN_ENABLE_TEXT_INPUT
func imeTrace(_ message: String) {
    guard imeTraceEnabled else { return }
    let line = Data("[ime-trace] \(message)\n".utf8)
    FileHandle.standardError.write(line)
}

func imeRangeDesc(_ r: NSRange) -> String {
    if r.location == NSNotFound {
        return "{NSNotFound,\(r.length)}"
    }
    return "{\(r.location),\(r.length)}"
}

func imePreview(_ s: String, limit: Int = 20) -> String {
    if s.count <= limit { return s }
    return String(s.prefix(limit)) + "…"
}
#endif // KNGN_ENABLE_TEXT_INPUT

struct EventQueueToken {
    let index: Int
    let generation: UInt32
}

// The event queue struct (backed by a fixed-size array)
class EventQueue {
    private var events: UnsafeMutablePointer<PlatformEvent>
    private var slotGeneration: [UInt32]
    var head: Int = 0  // where the next write goes
    var tail: Int = 0  // where the next read comes from
    // observation counters (cumulative; the examples watch the difference)
    var mouseMoveMergeCount: UInt64 = 0
    var mouseScrollMergeCount: UInt64 = 0
    var eventDropCount: UInt64 = 0

    init() {
        // Allocate the fixed-size memory buffer
        events = UnsafeMutablePointer<PlatformEvent>.allocate(capacity: EVENT_QUEUE_SIZE)
        // Zero every event (type = PLATFORM_EVENT_NONE)
        events.initialize(repeating: PlatformEvent(), count: EVENT_QUEUE_SIZE)
        slotGeneration = [UInt32](repeating: 0, count: EVENT_QUEUE_SIZE)
    }

    subscript(index: Int) -> PlatformEvent {
        get {
            return events[index]
        }
        set {
            events[index] = newValue
        }
    }

    // The newest event at the tail of the queue (nil when empty). Accessed through a pointer, for reading and writing alike.
    func peekTail() -> UnsafeMutablePointer<PlatformEvent>? {
        if head == tail { return nil }
        let prev = (head - 1 + EVENT_QUEUE_SIZE) % EVENT_QUEUE_SIZE
        return events.advanced(by: prev)
    }

    // Merge a mouse_move into the tail (only when buttons_mask and modifiers match). True once merged.
    func tryMergeMouseMove(_ ev: PlatformEvent) -> Bool {
        guard let tail = peekTail() else { return false }
        if tail.pointee.type != PLATFORM_EVENT_MOUSE_MOVE { return false }
        if tail.pointee.payload.mouse.buttons_mask != ev.payload.mouse.buttons_mask { return false }
        if tail.pointee.payload.mouse.modifiers != ev.payload.mouse.modifiers { return false }
        tail.pointee.payload.mouse.x = ev.payload.mouse.x
        tail.pointee.payload.mouse.y = ev.payload.mouse.y
        mouseMoveMergeCount += 1
        return true
    }

    // Merge a mouse_scroll into the tail (only when is_precise, buttons_mask and modifiers match).
    func tryMergeMouseScroll(_ ev: PlatformEvent) -> Bool {
        guard let tail = peekTail() else { return false }
        if tail.pointee.type != PLATFORM_EVENT_MOUSE_SCROLL { return false }
        if tail.pointee.payload.scroll.is_precise != ev.payload.scroll.is_precise { return false }
        if tail.pointee.payload.scroll.buttons_mask != ev.payload.scroll.buttons_mask { return false }
        if tail.pointee.payload.scroll.modifiers != ev.payload.scroll.modifiers { return false }
        tail.pointee.payload.scroll.x = ev.payload.scroll.x
        tail.pointee.payload.scroll.y = ev.payload.scroll.y
        tail.pointee.payload.scroll.dx += ev.payload.scroll.dx
        tail.pointee.payload.scroll.dy += ev.payload.scroll.dy
        mouseScrollMergeCount += 1
        return true
    }

    // Push onto the queue (when full, bump the drop counter and discard)
    // The token is used only to invalidate a gamepad connect after the fact. No other caller needs the
    // return value, hence @discardableResult (which silences swiftc's unused-result warning, as with queue_push on the objc side).
    @discardableResult
    func push(_ ev: PlatformEvent) -> EventQueueToken? {
        let next_head = (head + 1) % EVENT_QUEUE_SIZE
        if next_head == tail {
            eventDropCount += 1
            return nil
        }
        let index = head
        slotGeneration[index] &+= 1
        events[index] = ev
        head = next_head
        return EventQueueToken(index: index, generation: slotGeneration[index])
    }

    func markNone(_ token: EventQueueToken) -> Bool {
        guard token.index >= 0 && token.index < EVENT_QUEUE_SIZE else { return false }
        guard slotGeneration[token.index] == token.generation else { return false }
        guard events[token.index].type == PLATFORM_EVENT_KEY_DOWN else { return false }
        events[token.index].type = PLATFORM_EVENT_NONE
        return true
    }

    deinit {
        events.deinitialize(count: EVENT_QUEUE_SIZE)
        events.deallocate()
    }
}

// ========================================
// Mouse input helpers
// ========================================

// The line→points factor for a non-precise scroll (a rule of thumb)
let SCROLL_LINE_TO_POINTS: Float = 16.0

// The shared scale helpers (the same shape as objc and ADR-011).
// The real scale used for input normalisation (for a query; independent of fb_mode).
func effectiveContentScale(_ rawScale: CGFloat) -> CGFloat {
    return (rawScale > 0 && rawScale.isFinite) ? rawScale : 1.0
}

/// Numerically identical to objc's `(int)lround((double)px * (double)scale)`.
/// Clamps to a finite value in [1, UInt32.max].
func roundToPhysicalPx(_ logicalPx: Int, scale: CGFloat) -> Int {
    let s = Double(effectiveContentScale(scale))
    let v = (Double(logicalPx) * s).rounded()
    if !v.isFinite || v < 1.0 { return 1 }
    if v > Double(UInt32.max) { return Int(UInt32.max) }
    return Int(v)
}

/// The physical framebuffer size. Under .logical it is always the logical size itself.
func effectiveFramebufferSize(physicalMode: Bool, logicalWidth: Int, logicalHeight: Int, scale: CGFloat) -> (Int, Int) {
    if !physicalMode { return (max(1, logicalWidth), max(1, logicalHeight)) }
    return (roundToPhysicalPx(logicalWidth, scale: scale), roundToPhysicalPx(logicalHeight, scale: scale))
}

// Convert NSEvent.locationInWindow into raw physical pixels with the origin at the view's top-left (floored to an integer).
// scale is the current native backing scale (content_scale). The real scale is applied even under
// .logical (the same contract as objc's `event_location_to_platform_raw_coords`; the facade normalises it).
func eventLocationToPlatformCoords(_ event: NSEvent, _ view: NSView, scale: CGFloat) -> (Int32, Int32) {
    let windowPt = event.locationInWindow
    let viewPt = view.convert(windowPt, from: nil)
    let viewHeight = view.bounds.size.height
    let s = effectiveContentScale(scale)
    let x = Int32(floor(viewPt.x * s))
    let y = Int32(floor((viewHeight - viewPt.y) * s))  // flip Y
    return (x, y)
}

// The bitmask of the buttons currently held (& 0x07 excludes X1/X2).
func pressedButtonsMask() -> UInt8 {
    return UInt8(NSEvent.pressedMouseButtons & 0x07)
}

// From NSEvent.buttonNumber to PlatformMouseButton (by physical button).
func buttonFromEvent(_ event: NSEvent) -> PlatformMouseButton {
    switch event.buttonNumber {
        case 0: return PLATFORM_MOUSE_BUTTON_LEFT
        case 1: return PLATFORM_MOUSE_BUTTON_RIGHT
        case 2: return PLATFORM_MOUSE_BUTTON_MIDDLE
        default: return PLATFORM_MOUSE_BUTTON_NONE
    }
}

// Convert a macOS key code into a PlatformKeyCode
// Reference: /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/Headers/Events.h
func mapKeyCodeToPlatform(_ keyCode: UInt16) -> PlatformKeyCode {
    switch keyCode {
        // character keys (the ANSI layout)
        case 0x00: return PLATFORM_KEY_A
        case 0x01: return PLATFORM_KEY_S
        case 0x02: return PLATFORM_KEY_D
        case 0x03: return PLATFORM_KEY_F
        case 0x04: return PLATFORM_KEY_H
        case 0x05: return PLATFORM_KEY_G
        case 0x06: return PLATFORM_KEY_Z
        case 0x07: return PLATFORM_KEY_X
        case 0x08: return PLATFORM_KEY_C
        case 0x09: return PLATFORM_KEY_V
        case 0x0B: return PLATFORM_KEY_B
        case 0x0C: return PLATFORM_KEY_Q
        case 0x0D: return PLATFORM_KEY_W
        case 0x0E: return PLATFORM_KEY_E
        case 0x0F: return PLATFORM_KEY_R
        case 0x10: return PLATFORM_KEY_Y
        case 0x11: return PLATFORM_KEY_T
        case 0x12: return PLATFORM_KEY_1
        case 0x13: return PLATFORM_KEY_2
        case 0x14: return PLATFORM_KEY_3
        case 0x15: return PLATFORM_KEY_4
        case 0x16: return PLATFORM_KEY_6
        case 0x17: return PLATFORM_KEY_5
        case 0x18: return PLATFORM_KEY_UNKNOWN  // kVK_ANSI_Equal (=)
        case 0x19: return PLATFORM_KEY_9
        case 0x1A: return PLATFORM_KEY_7
        case 0x1B: return PLATFORM_KEY_UNKNOWN  // kVK_ANSI_Minus (-)
        case 0x1C: return PLATFORM_KEY_8
        case 0x1D: return PLATFORM_KEY_0
        case 0x1E: return PLATFORM_KEY_UNKNOWN  // kVK_ANSI_RightBracket (])
        case 0x1F: return PLATFORM_KEY_O
        case 0x20: return PLATFORM_KEY_U
        case 0x21: return PLATFORM_KEY_UNKNOWN  // kVK_ANSI_LeftBracket ([)
        case 0x22: return PLATFORM_KEY_I
        case 0x23: return PLATFORM_KEY_P
        case 0x25: return PLATFORM_KEY_L       // kVK_ANSI_L
        case 0x26: return PLATFORM_KEY_J       // kVK_ANSI_J
        case 0x27: return PLATFORM_KEY_UNKNOWN  // kVK_ANSI_Quote (')
        case 0x28: return PLATFORM_KEY_K       // kVK_ANSI_K
        case 0x29: return PLATFORM_KEY_UNKNOWN  // kVK_ANSI_Semicolon (;)
        case 0x2A: return PLATFORM_KEY_UNKNOWN  // kVK_ANSI_Backslash (\)
        case 0x2B: return PLATFORM_KEY_UNKNOWN  // kVK_ANSI_Comma (,)
        case 0x2C: return PLATFORM_KEY_UNKNOWN  // kVK_ANSI_Slash (/)
        case 0x2D: return PLATFORM_KEY_N       // kVK_ANSI_N
        case 0x2E: return PLATFORM_KEY_M       // kVK_ANSI_M
        case 0x2F: return PLATFORM_KEY_UNKNOWN  // kVK_ANSI_Period (.)
        case 0x30: return PLATFORM_KEY_TAB     // kVK_Tab
        case 0x31: return PLATFORM_KEY_SPACE   // kVK_Space
        case 0x32: return PLATFORM_KEY_UNKNOWN  // kVK_ANSI_Grave (`)
        case 0x33: return PLATFORM_KEY_BACKSPACE // kVK_Delete

        // Return/Enter
        case 0x24: return PLATFORM_KEY_ENTER   // kVK_Return

        // Escape
        case 0x35: return PLATFORM_KEY_ESCAPE  // kVK_Escape

        // modifier keys (left)
        case 0x38: return PLATFORM_KEY_LEFT_SHIFT      // kVK_Shift
        case 0x3A: return PLATFORM_KEY_LEFT_ALT        // kVK_Option
        case 0x3B: return PLATFORM_KEY_LEFT_CONTROL    // kVK_Control
        case 0x37: return PLATFORM_KEY_LEFT_SUPER      // kVK_Command
        case 0x39: return PLATFORM_KEY_CAPS_LOCK       // kVK_CapsLock

        // modifier keys (right)
        case 0x3C: return PLATFORM_KEY_RIGHT_SHIFT     // kVK_RightShift
        case 0x3D: return PLATFORM_KEY_RIGHT_ALT       // kVK_RightOption
        case 0x3E: return PLATFORM_KEY_RIGHT_CONTROL   // kVK_RightControl
        case 0x36: return PLATFORM_KEY_RIGHT_SUPER     // kVK_RightCommand

        // function keys
        case 0x7A: return PLATFORM_KEY_F1              // kVK_F1
        case 0x78: return PLATFORM_KEY_F2              // kVK_F2
        case 0x63: return PLATFORM_KEY_F3              // kVK_F3
        case 0x76: return PLATFORM_KEY_F4              // kVK_F4
        case 0x60: return PLATFORM_KEY_F5              // kVK_F5
        case 0x61: return PLATFORM_KEY_F6              // kVK_F6
        case 0x62: return PLATFORM_KEY_F7              // kVK_F7
        case 0x64: return PLATFORM_KEY_F8              // kVK_F8
        case 0x65: return PLATFORM_KEY_F9              // kVK_F9
        case 0x6D: return PLATFORM_KEY_F10             // kVK_F10
        case 0x67: return PLATFORM_KEY_F11             // kVK_F11
        case 0x6F: return PLATFORM_KEY_F12             // kVK_F12
        case 0x69: return PLATFORM_KEY_F13             // kVK_F13
        case 0x6B: return PLATFORM_KEY_F14             // kVK_F14
        case 0x71: return PLATFORM_KEY_F15             // kVK_F15
        case 0x6A: return PLATFORM_KEY_F16             // kVK_F16
        case 0x40: return PLATFORM_KEY_F17             // kVK_F17
        case 0x4F: return PLATFORM_KEY_F18             // kVK_F18
        case 0x50: return PLATFORM_KEY_F19             // kVK_F19
        case 0x5A: return PLATFORM_KEY_F20             // kVK_F20

        // editing keys
        case 0x72: return PLATFORM_KEY_INSERT          // kVK_Help
        case 0x73: return PLATFORM_KEY_HOME            // kVK_Home
        case 0x74: return PLATFORM_KEY_PAGE_UP         // kVK_PageUp
        case 0x75: return PLATFORM_KEY_DELETE          // kVK_ForwardDelete
        case 0x77: return PLATFORM_KEY_END             // kVK_End
        case 0x79: return PLATFORM_KEY_PAGE_DOWN       // kVK_PageDown

        // arrow keys
        case 0x7B: return PLATFORM_KEY_LEFT            // kVK_LeftArrow
        case 0x7C: return PLATFORM_KEY_RIGHT           // kVK_RightArrow
        case 0x7D: return PLATFORM_KEY_DOWN            // kVK_DownArrow
        case 0x7E: return PLATFORM_KEY_UP              // kVK_UpArrow

        // the numeric keypad
        case 0x52: return PLATFORM_KEY_KP_0            // kVK_ANSI_Keypad0
        case 0x53: return PLATFORM_KEY_KP_1            // kVK_ANSI_Keypad1
        case 0x54: return PLATFORM_KEY_KP_2            // kVK_ANSI_Keypad2
        case 0x55: return PLATFORM_KEY_KP_3            // kVK_ANSI_Keypad3
        case 0x56: return PLATFORM_KEY_KP_4            // kVK_ANSI_Keypad4
        case 0x57: return PLATFORM_KEY_KP_5            // kVK_ANSI_Keypad5
        case 0x58: return PLATFORM_KEY_KP_6            // kVK_ANSI_Keypad6
        case 0x59: return PLATFORM_KEY_KP_7            // kVK_ANSI_Keypad7
        case 0x5B: return PLATFORM_KEY_KP_8            // kVK_ANSI_Keypad8
        case 0x5C: return PLATFORM_KEY_KP_9            // kVK_ANSI_Keypad9
        case 0x41: return PLATFORM_KEY_KP_DECIMAL      // kVK_ANSI_KeypadDecimal
        case 0x4B: return PLATFORM_KEY_KP_DIVIDE       // kVK_ANSI_KeypadDivide
        case 0x43: return PLATFORM_KEY_KP_MULTIPLY     // kVK_ANSI_KeypadMultiply
        case 0x4E: return PLATFORM_KEY_KP_SUBTRACT     // kVK_ANSI_KeypadMinus
        case 0x45: return PLATFORM_KEY_KP_ADD          // kVK_ANSI_KeypadPlus
        case 0x4C: return PLATFORM_KEY_KP_ENTER        // kVK_ANSI_KeypadEnter
        case 0x51: return PLATFORM_KEY_KP_EQUAL        // kVK_ANSI_KeypadEquals

        default: return PLATFORM_KEY_UNKNOWN
    }
}

// Extract the modifier keys
func extractModifiers(_ nsModifiers: NSEvent.ModifierFlags) -> UInt32 {
    var mods: UInt32 = 0
    if nsModifiers.contains(.shift)   { mods |= UInt32(PLATFORM_MOD_SHIFT.rawValue) }
    if nsModifiers.contains(.control) { mods |= UInt32(PLATFORM_MOD_CTRL.rawValue) }
    if nsModifiers.contains(.option)  { mods |= UInt32(PLATFORM_MOD_ALT.rawValue) }
    if nsModifiers.contains(.command) { mods |= UInt32(PLATFORM_MOD_CMD.rawValue) }
    return mods
}

// ========================================
// The backend view abstraction
// ========================================
//
// The shared protocol that the views of both the swift (CALayer) and metal backends conform to. The
// shared C ABI drives the view only through backendView, which hides the backend-specific drawing
// (CALayer or the Metal ring). It stays thin: drawing itself and the IME state live in each backend and in PlatformIMEState.
protocol PlatformBackendView: AnyObject {
    var nativeView: NSView { get }
    var width: Int { get }
    var height: Int { get }
    var initialFramebuffer: UnsafeMutablePointer<UInt32>? { get }
    // Present the current write buffer (a swap or a submit) and return the next buffer to write into.
    // The size argument is taken for compatibility, but the implementation uses its internal size.
    func present(
        framebuffer: UnsafeMutablePointer<UInt32>,
        width: Int,
        height: Int
    ) -> UnsafeMutablePointer<UInt32>?
    var implementationType: String { get }
#if KNGN_ENABLE_CURSOR
    func setCursorShape(_ shape: PlatformCursorShape)
#endif
#if KNGN_ENABLE_MASCOT
    func setClickThrough(_ enabled: Bool)
    func takeLastMouseDownEvent() -> NSEvent?
#endif
    func setRedrawCallback(_ cb: PlatformRedrawCallback?, userdata: UnsafeMutableRawPointer?)
    var platformWindow: PlatformWindowHandle? { get set }
    func prepareForDestroy()
#if KNGN_ENABLE_MASCOT
    func setTransparentMode(_ enabled: Bool)
#endif
    func startPresentation()
#if KNGN_ENABLE_TEXT_INPUT
    // The IME surface (used by the shared C ABI and by poll_events)
    func copyCompositionSnapshot(buf: UnsafeMutablePointer<CChar>?, cap: UInt32, meta: UnsafeMutablePointer<PlatformCompositionMeta>?) -> UInt32
    func setCompositionRectPixels(x: Int32, y: Int32, w: Int32, h: Int32)
    func setTextInputActive(_ active: Bool)
    func setTextInputDocumentAccess(callbacks: UnsafePointer<PlatformTextInputDocumentCallbacks>?, userdata: UnsafeMutableRawPointer?)
    func hasMarkedText() -> Bool
    func imeRouteEnabled() -> Bool
#endif
    // The scale latch and metrics (the same shape as objc's fillMetrics / applyLatched / nativeEventScale)
    // forQuery=true: the current negotiated value (the pending scale), for contentScale() and input normalisation before a lock.
    // forQuery=false: the latched snapshot (buffer, scale and epoch all belong to the same frame), for lock_ex.
    func fillMetrics(_ out: UnsafeMutablePointer<PlatformFramebufferMetrics>, forQuery: Bool)
    func applyLatchedMetricsIfNeeded()
    func nativeEventScale() -> CGFloat
}

// The opaque PlatformWindow type inherits NSObject (for reference counting)
final class PlatformWindowHandle: NSObject {
    let window: NSWindow
    let backendView: any PlatformBackendView
    var currentFramebuffer: UnsafeMutablePointer<UInt32>?
    let width: Int   // The size at creation. lock and present use backendView.width/height (live and resize-safe).
    let height: Int
    let event_queue: EventQueue  // The name event_queue is kept (gamepad and existing code refer to it)
    var quitRequested: Bool = false
    var quitDelegate: QuitWindowDelegate?
#if KNGN_ENABLE_FULLSCREEN
    // Fullscreen (platform_set_fullscreen / platform_is_fullscreen / platform_get_windowed_geometry).
    // The window delegate keeps these up to date across both user-started and program-started transitions.
    var fsDesired: Bool = false      // the state most recently asked for (applied when a transition in flight ends)
    var fsTransition: Bool = false   // a transition is in flight (between will- and did-)
    var fsWindowedHeld: Bool = false  // fsWindowed is the geometry to persist (held for the whole fullscreen period)
    var fsWindowed = PlatformWindowGeometry()
#endif

    init(window: NSWindow, backendView: any PlatformBackendView) {
        self.window = window
        self.backendView = backendView
        self.width = backendView.width
        self.height = backendView.height
        self.currentFramebuffer = backendView.initialFramebuffer
        self.event_queue = EventQueue()
        super.init()
        let delegate = QuitWindowDelegate()
        delegate.handle = self
        self.quitDelegate = delegate
        window.delegate = delegate
    }
}

// Turn the close button into a quit request; the window is not closed until the consumer decides.
final class QuitWindowDelegate: NSObject, NSWindowDelegate {
    weak var handle: PlatformWindowHandle?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        _ = sender
        guard let handle = handle else { return true }
        if handle.quitRequested { return false }
        handle.quitRequested = true
        var ev = PlatformEvent()
        ev.type = PLATFORM_EVENT_QUIT
        handle.event_queue.push(ev)
        return false
    }

#if KNGN_ENABLE_FULLSCREEN
    // The fullscreen transition, whoever started it (platform_set_fullscreen, the green button, or
    // Cmd+Ctrl+F). Entering snapshots the geometry to persist; that snapshot is held until the exit
    // transition has finished, so it also covers the exit animation, during which the window still
    // fills the screen. A request that arrived mid-transition is applied here.
    func windowWillEnterFullScreen(_ notification: Notification) {
        _ = notification
        guard let handle = handle else { return }
        handle.fsTransition = true
        handle.fsDesired = true
        if !handle.fsWindowedHeld {
            handle.fsWindowed = windowGeometry(handle)
            handle.fsWindowedHeld = true
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        _ = notification
        guard let handle = handle else { return }
        handle.fsTransition = false
        if !handle.fsDesired {
            platform_set_fullscreen(platformWindow: Unmanaged.passUnretained(handle).toOpaque(), enable: false)
        }
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        _ = notification
        guard let handle = handle else { return }
        handle.fsTransition = true
        handle.fsDesired = false
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        _ = notification
        guard let handle = handle else { return }
        handle.fsTransition = false
        handle.fsWindowedHeld = false
        if handle.fsDesired {
            platform_set_fullscreen(platformWindow: Unmanaged.passUnretained(handle).toOpaque(), enable: true)
        }
    }
#endif // KNGN_ENABLE_FULLSCREEN
}

// ========================================
// Gamepad input (ADR-009)
// ========================================
//
// Opt-in: the GameController framework uses the same opt-in linking as audio, and only an executable
// that uses a gamepad (examples/22_gamepad) gets `-DKNGN_ENABLE_GAMEPAD` from build.zig
// (see compilePlatformLayer in build_helpers/platform.zig). In an executable without the opt-in this
// whole block is not compiled and no GameController symbol is referenced at all (nor shown by `otool -L`).
#if KNGN_ENABLE_GAMEPAD
//
// The mapping from GCController to an index (0..<PLATFORM_MAX_GAMEPADS) is held as module-level state.
// A single window is assumed (as in the rest of the code), so a connect/disconnect event is pushed
// onto the event_queue of the "currently active window" (the window created last).

/// The index→GCController mapping of the connected controllers. nil = a free slot.
var gamepadSlots: [GCController?] = Array(repeating: nil, count: Int(PLATFORM_MAX_GAMEPADS))
/// The window that connect and disconnect events are pushed to.
weak var gamepadEventWindow: PlatformWindowHandle?
/// Whether the GCControllerDidConnect/DidDisconnect observers are installed (once per process).
var gamepadObserversInstalled = false

func gamepadFindSlot(for controller: GCController) -> Int? {
    return gamepadSlots.firstIndex { $0 === controller }
}

func gamepadFindFreeSlot() -> Int? {
    return gamepadSlots.firstIndex { $0 == nil }
}

/// Copy a UTF-8 string, truncated, into PlatformEvent.payload.gamepad.name (a fixed 33 bytes, NUL-terminated).
func setGamepadEventName(_ ev: inout PlatformEvent, _ name: String) {
    withUnsafeMutableBytes(of: &ev.payload.gamepad.name) { raw in
        for i in 0..<raw.count { raw[i] = 0 }
        let bytes = Array(name.utf8.prefix(raw.count - 1))
        for (i, b) in bytes.enumerated() { raw[i] = b }
    }
}

/// Take in a GCController connection. Anything without extendedGamepad (a micro gamepad, say), already tracked, or over the limit is ignored.
func gamepadHandleConnect(_ controller: GCController) {
    guard controller.extendedGamepad != nil else { return } // not the standard layout, so out of scope
    guard gamepadFindSlot(for: controller) == nil else { return } // already tracked (defensive)
    guard let handle = gamepadEventWindow else { return } // no window has been created yet
    guard let idx = gamepadFindFreeSlot() else { return } // more than PLATFORM_MAX_GAMEPADS pads
    gamepadSlots[idx] = controller

    var ev = PlatformEvent()
    ev.type = PLATFORM_EVENT_GAMEPAD_CONNECTED
    ev.payload.gamepad.index = Int32(idx)
    setGamepadEventName(&ev, controller.vendorName ?? "Gamepad")
    handle.event_queue.push(ev)
}

/// Take in a GCController disconnection. An untracked one is ignored.
func gamepadHandleDisconnect(_ controller: GCController) {
    guard let idx = gamepadFindSlot(for: controller) else { return }
    gamepadSlots[idx] = nil
    guard let handle = gamepadEventWindow else { return }

    var ev = PlatformEvent()
    ev.type = PLATFORM_EVENT_GAMEPAD_DISCONNECTED
    ev.payload.gamepad.index = Int32(idx)
    handle.event_queue.push(ev)
}

/// Install the GCControllerDidConnect/DidDisconnect observers exactly once per process.
/// `queue: .main` is given explicitly to force delivery on the main thread (with `queue: nil` the
/// observer runs synchronously on whichever thread posted the notification, which guarantees
/// nothing). That keeps writes to event_queue and gamepadSlots on the same thread as pollEvents and
/// the rest of the main thread path, so there is no race even without a lock.
func gamepadInstallObserversIfNeeded() {
    if gamepadObserversInstalled { return }
    gamepadObserversInstalled = true
    NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
        guard let controller = note.object as? GCController else { return }
        gamepadHandleConnect(controller)
    }
    NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { note in
        guard let controller = note.object as? GCController else { return }
        gamepadHandleDisconnect(controller)
    }
}

/// Switch the "active window" as windows are created and destroyed. A slot inherited from another
/// window (a controller that connected while the previous window was alive) has its connected event
/// resent to the new window, and an untracked controller is taken in by the ordinary connect path
/// (without this, a controller that was already connected gets no connected event on the new window).
func gamepadAttachWindow(_ handle: PlatformWindowHandle) {
    gamepadEventWindow = handle
    gamepadInstallObserversIfNeeded()
    for (idx, controller) in gamepadSlots.enumerated() {
        guard let controller = controller else { continue }
        var ev = PlatformEvent()
        ev.type = PLATFORM_EVENT_GAMEPAD_CONNECTED
        ev.payload.gamepad.index = Int32(idx)
        setGamepadEventName(&ev, controller.vendorName ?? "Gamepad")
        handle.event_queue.push(ev)
    }
    for controller in GCController.controllers() {
        gamepadHandleConnect(controller) // only an untracked one is really processed (gamepadFindSlot skips the rest)
    }
}

func gamepadDetachWindow(_ handle: PlatformWindowHandle) {
    if gamepadEventWindow === handle {
        gamepadEventWindow = nil
    }
}
#endif // KNGN_ENABLE_GAMEPAD

// ========================================
// The native menu bridge
// ========================================
//
// The shared platform_macos_menu.m holds the NSMenu itself; this backend only pushes a
// MENU_COMMAND onto the EventQueue and asks whether a keyEquivalent was consumed.
#if KNGN_ENABLE_MENU

@_silgen_name("platform_menu_consume_key_equivalent")
func platform_menu_consume_key_equivalent(_ ns_event: UnsafeMutableRawPointer?) -> Bool

@_silgen_name("platform_menu_window_will_destroy")
func platform_menu_window_will_destroy(_ window: UnsafeMutableRawPointer?)

@_cdecl("platform_menu_enqueue_command")
func platform_menu_enqueue_command(_ window: UnsafeMutableRawPointer?, _ command_id: UInt32) {
    guard let window = window else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(window).takeUnretainedValue()
    var ev = PlatformEvent()
    ev.type = PLATFORM_EVENT_MENU_COMMAND
    ev.payload.menu.command_id = command_id
    _ = handle.event_queue.push(ev)
}

#endif // KNGN_ENABLE_MENU

// ========================================
// The IME state, shared by both backends (KNGN_ENABLE_TEXT_INPUT)
// ========================================
#if KNGN_ENABLE_TEXT_INPUT
//
// The NSTextInputClient logic and the composition and document-access state are gathered into PlatformIMEState.
// Each backend's view holds `let imeState = PlatformIMEState()` and forwards the NSTextInputClient
// methods and the custom IME methods to it. firstRect is computed from hostView.bounds and the
// framebuffer size (updated through updateFramebufferSize).

// The capacity of the fixed composition preedit buffer (in UTF-8 bytes)
let compositionUtf8Cap = 1024

/// The longest prefix of s[0..<len] that fits within cap and ends on a UTF-8 code point boundary.
func utf8SafePrefixLen(_ s: [UInt8], len: Int, cap: Int) -> Int {
    var i = 0
    let n = min(len, s.count)
    let limit = min(n, cap)
    while i < limit {
        let c = s[i]
        let need: Int
        if (c & 0x80) == 0 { need = 1 }
        else if (c & 0xE0) == 0xC0 { need = 2 }
        else if (c & 0xF0) == 0xE0 { need = 3 }
        else if (c & 0xF8) == 0xF0 { need = 4 }
        else { break }
        if i + need > limit { break }
        i += need
    }
    return i
}

final class PlatformIMEState {
    // where events are pushed, and the source of bounds, inputContext, convert and the window reference
    weak var platformWindow: PlatformWindowHandle?
    weak var hostView: NSView?

    // the current framebuffer size, used to convert firstRect from pixels into bounds (updated on a resize)
    private var fbWidth: Int = 0
    private var fbHeight: Int = 0

    // The IME composition state
    private var markedTextStorage = NSMutableString()
    private var imeSelectedRange = NSRange(location: 0, length: 0)
    // Text input focus control. While imeControlled=false everything goes through the IME, as before.
    private var imeControlled = false
    private var imeActive = false
    private var compositionUtf8 = [UInt8](repeating: 0, count: compositionUtf8Cap)
    private var compositionLen: UInt32 = 0
    private var compositionRevision: UInt32 = 0
    private var compositionCursor: UInt32 = 0
    private var compositionRectPixels = NSRect.zero
    private var compositionRectSet = false

    // IME document access
    private var docAccessCallbacks = PlatformTextInputDocumentCallbacks()
    private var docAccessUserdata: UnsafeMutableRawPointer?
    private var docAccessEnabled = false
    private var hasPendingReplacement = false
    private var pendingReplacement = NSRange(location: NSNotFound, length: 0)

    // Update the framebuffer size (the backend calls it right after init and on a resize). It is used by the firstRect conversion.
    func updateFramebufferSize(width: Int, height: Int) {
        fbWidth = width
        fbHeight = height
    }

    func copyCompositionSnapshot(buf: UnsafeMutablePointer<CChar>?, cap: UInt32, meta: UnsafeMutablePointer<PlatformCompositionMeta>?) -> UInt32 {
        // latest-wins: always the current preedit. event.revision only detects a missed update (an older revision cannot be read).
        if let meta = meta {
            meta.pointee.revision = compositionRevision
            meta.pointee.cursor = compositionCursor
            meta.pointee.len = 0
        }
        guard let buf = buf, cap > 0, compositionLen > 0 else { return 0 }
        // cut on a UTF-8 code point boundary
        let n = UInt32(utf8SafePrefixLen(compositionUtf8, len: Int(compositionLen), cap: Int(cap)))
        compositionUtf8.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(buf, base, Int(n))
            }
        }
        if let meta = meta {
            meta.pointee.len = n
            if meta.pointee.cursor > n { meta.pointee.cursor = n }
        }
        return n
    }

    private func syncCompositionBufferFromMarked() {
        let str = markedTextStorage as String
        guard let data = str.data(using: .utf8) else {
            compositionLen = 0
            compositionCursor = 0
            return
        }
        // truncate into the fixed buffer on a UTF-8 boundary
        var tmp = [UInt8](repeating: 0, count: data.count)
        data.copyBytes(to: &tmp, count: data.count)
        let len = utf8SafePrefixLen(tmp, len: data.count, cap: compositionUtf8Cap)
        for i in 0..<len { compositionUtf8[i] = tmp[i] }
        compositionLen = UInt32(len)
        var loc = imeSelectedRange.location
        if loc == NSNotFound { loc = markedTextStorage.length }
        if loc > markedTextStorage.length { loc = markedTextStorage.length }
        let prefix = markedTextStorage.substring(to: loc)
        if let pdata = prefix.data(using: .utf8) {
            compositionCursor = UInt32(min(pdata.count, Int(compositionLen)))
        } else {
            compositionCursor = 0
        }
        if compositionCursor > compositionLen { compositionCursor = compositionLen }
    }

    private func pushCompositionPhase(_ phase: UInt8) {
        guard let handle = platformWindow else { return }
        compositionRevision &+= 1
        var ev = PlatformEvent()
        ev.type = PLATFORM_EVENT_COMPOSITION
        ev.payload.composition.revision = compositionRevision
        ev.payload.composition.phase = phase
        ev.payload.composition.cursor = compositionCursor
        handle.event_queue.push(ev)
        keyTrace("composition phase=\(phase) revision=\(compositionRevision) cursor=\(compositionCursor)")
    }

    /// No char_input is emitted while Cmd or Ctrl is held (which would print a character for an insertText coming from a key binding).
    private func pushCharInputs(from str: String) {
        guard let handle = platformWindow else { return }
        let charMods = extractModifiers(NSEvent.modifierFlags)
        // the same invariant as the printable filter: nothing with cmd or ctrl is printed
        if (charMods & (UInt32(PLATFORM_MOD_CMD.rawValue) | UInt32(PLATFORM_MOD_CTRL.rawValue))) != 0 {
            return
        }
        for scalar in str.unicodeScalars {
            let cp = scalar.value
            if cp >= 0x20 && cp != 0x7f && !(cp >= 0xF700 && cp <= 0xF8FF) {
                var charEvent = PlatformEvent()
                charEvent.type = PLATFORM_EVENT_CHAR_INPUT
                charEvent.payload.character.codepoint = cp
                charEvent.payload.character.modifiers = charMods
                handle.event_queue.push(charEvent)
                keyTrace(String(format: "char_input cp=U+%X mods=0x%X", cp, charMods))
            }
        }
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let str: String
        if let attr = string as? NSAttributedString {
            str = attr.string
        } else if let s = string as? String {
            str = s
        } else {
            str = ""
        }
        keyTrace("insertText")
        let hadMarked = markedTextStorage.length > 0
        if hadMarked {
            markedTextStorage.setString("")
            imeSelectedRange = NSRange(location: 0, length: 0)
            compositionLen = 0
            compositionCursor = 0
            pushCompositionPhase(UInt8(PLATFORM_COMPOSITION_PHASE_COMMIT.rawValue))
        }

        if docAccessEnabled, let replaceFn = docAccessCallbacks.replace_text {
            let resolved = resolveReplacementRangeDetailed(replacementRange)
            imeTrace("insertText text=\"\(imePreview(str))\" explicit=\(imeRangeDesc(replacementRange)) path=\(resolved.path) final=\(imeRangeDesc(resolved.range)) pending_before_clear=\(hasPendingReplacement ? imeRangeDesc(pendingReplacement) : "none")")
            clearPendingReplacement(reason: "insertText")
            guard resolved.range.location != NSNotFound else { return }
            // Invalid UTF-8 is rejected (no substitution through String(decoding:))
            guard let data = str.data(using: .utf8) else { return }
            var rr = PlatformTextInputRange()
            rr.location = UInt64(resolved.range.location)
            rr.length = UInt64(resolved.range.length)
            data.withUnsafeBytes { raw in
                let ptr = raw.bindMemory(to: UInt8.self).baseAddress
                _ = replaceFn(docAccessUserdata, rr, ptr, UInt32(data.count))
            }
            return
        }

        imeTrace("insertText text=\"\(imePreview(str))\" explicit=\(imeRangeDesc(replacementRange)) path=char_input (no docAccess)")
        clearPendingReplacement(reason: "insertText_char_input")
        pushCharInputs(from: str)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        keyTrace("setMarkedText")
        let str: String
        if let attr = string as? NSAttributedString {
            str = attr.string
        } else if let s = string as? String {
            str = s
        } else {
            str = ""
        }
        let pendingBefore = hasPendingReplacement ? imeRangeDesc(pendingReplacement) : "none"
        // A valid replacementRange is latched exactly once per reconversion or composition.
        // A later NSNotFound or zero-length caret does not overwrite it.
        //
        // When the pending range is discarded (an empty setMarkedText is not a cancel: Japanese input reconversion
        // arrives as setMarkedText(" ", range) → setMarkedText("") → setMarkedText(candidate) → insertText, and
        // dropping the pending range on the empty mark would turn insertText into a plain caret insertion, duplicating the text):
        //   - right after insertText consumed it
        //   - unmarkText (ESC and the like)
        //   - setTextInputActive(false), unregistering document access, or destroying the window
        // The safety valve: a new valid replacementRange is latched only while hasPending==false
        // (the start of the next session, after the previous one was consumed or discarded). An empty mark or an NSNotFound update discards nothing.
        if replacementRange.location != NSNotFound && !hasPendingReplacement {
            hasPendingReplacement = true
            pendingReplacement = replacementRange
        }
        let pendingAfter = hasPendingReplacement ? imeRangeDesc(pendingReplacement) : "none"
        imeTrace("setMarkedText text=\"\(imePreview(str))\" selected=\(imeRangeDesc(selectedRange)) replacement=\(imeRangeDesc(replacementRange)) pending \(pendingBefore)->\(pendingAfter)")
        let wasEmpty = markedTextStorage.length == 0
        markedTextStorage.setString(str)
        imeSelectedRange = selectedRange
        if selectedRange.location == NSNotFound {
            imeSelectedRange = NSRange(location: markedTextStorage.length, length: 0)
        }
        syncCompositionBufferFromMarked()
        if markedTextStorage.length == 0 {
            compositionLen = 0
            compositionCursor = 0
            // An empty mark only clears the preedit display; the pending range is kept.
            // No CANCEL phase is emitted either (a real cancel is unmarkText).
            imeTrace("setMarkedText empty-mark keep pending=\(hasPendingReplacement ? imeRangeDesc(pendingReplacement) : "none") wasEmpty=\(wasEmpty)")
            return
        }
        let phase: UInt8 = wasEmpty
            ? UInt8(PLATFORM_COMPOSITION_PHASE_START.rawValue)
            : UInt8(PLATFORM_COMPOSITION_PHASE_UPDATE.rawValue)
        pushCompositionPhase(phase)
    }

    func unmarkText() {
        imeTrace("unmarkText markedLen=\(markedTextStorage.length) pending=\(hasPendingReplacement ? imeRangeDesc(pendingReplacement) : "none")")
        if markedTextStorage.length == 0 {
            clearPendingReplacement(reason: "unmarkText_already_empty")
            return
        }
        markedTextStorage.setString("")
        imeSelectedRange = NSRange(location: 0, length: 0)
        compositionLen = 0
        compositionCursor = 0
        clearPendingReplacement(reason: "unmarkText")
        pushCompositionPhase(UInt8(PLATFORM_COMPOSITION_PHASE_CANCEL.rawValue))
    }

    func hasMarkedText() -> Bool {
        return markedTextStorage.length > 0
    }

    // Whether keyDown should go to the IME (inputContext). Uncontrolled means always true, as before.
    func imeRouteEnabled() -> Bool {
        return imeControlled ? imeActive : true
    }

    // Receive the presence of text editing focus from the application. When the effective path goes
    // YES→NO (the first inactive from uncontrolled, i.e. always-YES, included) a pending composition is discarded.
    func setTextInputActive(_ active: Bool) {
        let wasRouting = imeRouteEnabled()      // the effective path before the change (true while uncontrolled)
        imeControlled = true
        imeActive = active                      // the effective path after the change = active
        if wasRouting && !active {
            unmarkText()                        // clear markedText, emit the CANCEL phase and discard the pending range
            hostView?.inputContext?.discardMarkedText()   // discard the IME's conversion session too (closing the candidate window)
            clearPendingReplacement(reason: "setTextInputActive_false")
        }
    }

    func clearPendingReplacement(reason: String = "unspecified") {
        if hasPendingReplacement || imeTraceEnabled {
            imeTrace("clearPending reason=\(reason) was=\(hasPendingReplacement ? imeRangeDesc(pendingReplacement) : "none")")
        }
        hasPendingReplacement = false
        pendingReplacement = NSRange(location: NSNotFound, length: 0)
    }

    func setTextInputDocumentAccess(
        callbacks: UnsafePointer<PlatformTextInputDocumentCallbacks>?,
        userdata: UnsafeMutableRawPointer?
    ) {
        if let callbacks,
           callbacks.pointee.get_selected_range != nil,
           callbacks.pointee.get_substring != nil,
           callbacks.pointee.replace_text != nil {
            docAccessCallbacks = callbacks.pointee
            docAccessUserdata = userdata
            docAccessEnabled = true
        } else {
            docAccessCallbacks = PlatformTextInputDocumentCallbacks()
            docAccessUserdata = nil
            docAccessEnabled = false
            clearPendingReplacement(reason: "docAccess_disabled")
        }
    }

    func resolveReplacementRange(_ replacementRange: NSRange) -> NSRange {
        return resolveReplacementRangeDetailed(replacementRange).range
    }

    /// For insertText: the resolved range plus the name of the path taken (explicit_len/pending/explicit_zero/selected/none).
    private func resolveReplacementRangeDetailed(_ replacementRange: NSRange) -> (range: NSRange, path: String) {
        // Priority: explicit (length>0) → pending → explicit (length==0, a caret) → selected.
        // Even when insertText states a zero-length caret, a pending range latched for reconversion wins.
        if replacementRange.location != NSNotFound && replacementRange.length > 0 {
            return (replacementRange, "explicit_len")
        }
        if hasPendingReplacement {
            return (pendingReplacement, "pending")
        }
        if replacementRange.location != NSNotFound {
            return (replacementRange, "explicit_zero")
        }
        if docAccessEnabled, let getSel = docAccessCallbacks.get_selected_range {
            var pr = PlatformTextInputRange()
            if getSel(docAccessUserdata, &pr), pr.location != UInt64.max {
                return (NSRange(location: Int(pr.location), length: Int(pr.length)), "selected")
            }
        }
        return (NSRange(location: NSNotFound, length: 0), "none")
    }

    func markedRange() -> NSRange {
        if markedTextStorage.length == 0 { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedTextStorage.length)
    }

    func selectedRange() -> NSRange {
        let result: NSRange
        if markedTextStorage.length == 0 {
            if docAccessEnabled, let getSel = docAccessCallbacks.get_selected_range {
                var pr = PlatformTextInputRange()
                if getSel(docAccessUserdata, &pr), pr.location != UInt64.max {
                    result = NSRange(location: Int(pr.location), length: Int(pr.length))
                    imeTrace("selectedRange (doc) -> \(imeRangeDesc(result))")
                    return result
                }
            }
            result = NSRange(location: NSNotFound, length: 0)
            imeTrace("selectedRange (empty) -> \(imeRangeDesc(result))")
            return result
        }
        result = imeSelectedRange
        imeTrace("selectedRange (marked) -> \(imeRangeDesc(result))")
        return result
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        if markedTextStorage.length == 0 {
            guard docAccessEnabled, let getSub = docAccessCallbacks.get_substring else {
                imeTrace("attributedSubstring proposed=\(imeRangeDesc(range)) -> nil (no docAccess)")
                return nil
            }
            guard range.location != NSNotFound else {
                imeTrace("attributedSubstring proposed=\(imeRangeDesc(range)) -> nil (NSNotFound)")
                return nil
            }
            var proposed = PlatformTextInputRange()
            proposed.location = UInt64(range.location)
            proposed.length = UInt64(range.length)
            var utf8Ptr: UnsafePointer<UInt8>? = nil
            var len: UInt32 = 0
            var actual = PlatformTextInputRange()
            guard getSub(docAccessUserdata, proposed, &utf8Ptr, &len, &actual) else {
                imeTrace("attributedSubstring proposed=\(imeRangeDesc(range)) -> nil (callback false)")
                return nil
            }
            let actualNS = NSRange(location: Int(actual.location), length: Int(actual.length))
            actualRange?.pointee = actualNS
            if len == 0 {
                imeTrace("attributedSubstring proposed=\(imeRangeDesc(range)) actual=\(imeRangeDesc(actualNS)) text=\"\" len=0")
                return NSAttributedString(string: "")
            }
            guard let utf8Ptr else {
                imeTrace("attributedSubstring proposed=\(imeRangeDesc(range)) -> nil (null utf8)")
                return nil
            }
            let data = Data(bytes: utf8Ptr, count: Int(len))
            // invalid UTF-8 gives nil (nothing is substituted)
            guard let s = String(data: data, encoding: .utf8) else {
                imeTrace("attributedSubstring proposed=\(imeRangeDesc(range)) -> nil (bad utf8)")
                return nil
            }
            imeTrace("attributedSubstring proposed=\(imeRangeDesc(range)) actual=\(imeRangeDesc(actualNS)) text=\"\(imePreview(s))\" len=\(s.count)")
            return NSAttributedString(string: s)
        }
        let full = NSRange(location: 0, length: markedTextStorage.length)
        let clipped = NSIntersectionRange(full, range)
        if clipped.length == 0 {
            imeTrace("attributedSubstring (marked) proposed=\(imeRangeDesc(range)) -> nil (empty clip)")
            return nil
        }
        actualRange?.pointee = clipped
        let sub = markedTextStorage.substring(with: clipped)
        imeTrace("attributedSubstring (marked) proposed=\(imeRangeDesc(range)) actual=\(imeRangeDesc(clipped)) text=\"\(imePreview(sub))\" len=\(sub.count)")
        return NSAttributedString(string: sub)
    }

    func characterIndex(for point: NSPoint) -> Int {
        imeTrace("characterIndex point=(\(point.x),\(point.y)) -> NSNotFound")
        _ = point
        return NSNotFound
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        guard let hostView = hostView else {
            imeTrace("firstRect range=\(imeRangeDesc(range)) -> .zero (no hostView)")
            return .zero
        }
        let bounds = hostView.bounds
        let width = fbWidth
        let height = fbHeight
        var r: NSRect
        if compositionRectSet && compositionRectPixels.width > 0 && compositionRectPixels.height > 0 {
            // The framebuffer is not a Retina backing: the layer scales it across the whole of bounds, so the
            // conversion is the bounds ratio (the inverse of the mouse conversion).
            let sx = width > 0 ? bounds.width / CGFloat(width) : 1.0
            let sy = height > 0 ? bounds.height / CGFloat(height) : 1.0
            var x = compositionRectPixels.origin.x * sx
            var top = compositionRectPixels.origin.y * sy
            var w = compositionRectPixels.width * sx
            var h = compositionRectPixels.height * sy
            x = max(bounds.minX, min(x, bounds.maxX))
            top = max(0.0, min(top, bounds.height))
            w = min(w, max(0.0, bounds.maxX - x))
            h = min(h, max(0.0, bounds.height - top))
            r = NSRect(x: x, y: bounds.height - top - h, width: w, height: h)
        } else {
            r = NSRect(x: 20.0, y: bounds.size.height - 48.0, width: 1.0, height: 18.0)
        }
        r = hostView.convert(r, to: nil)
        if let win = hostView.window {
            r = win.convertToScreen(r)
        }
        imeTrace("firstRect range=\(imeRangeDesc(range)) -> (\(r.origin.x),\(r.origin.y),\(r.size.width),\(r.size.height))")
        return r
    }

    func doCommand(by selector: Selector) {
        // Absorb an unhandled command to suppress the beep. A physical key already arrives through the key_down path.
        // super is not called (the NSTextInputClient contract that suppresses the beep of an unhandled command).
        keyTrace("doCommandBySelector=\(NSStringFromSelector(selector))")
    }

    func setCompositionRectPixels(x: Int32, y: Int32, w: Int32, h: Int32) {
        let next = NSRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
        let nextSet = w > 0 && h > 0
        guard next != compositionRectPixels || nextSet != compositionRectSet else { return }
        compositionRectPixels = next
        compositionRectSet = nextSet
        hostView?.inputContext?.invalidateCharacterCoordinates()
    }
}

#endif // KNGN_ENABLE_TEXT_INPUT

// ========================================
// The shared file drop helper
// ========================================
// The same contract as the objc backend (platform/macos/platform_macos.m): a single file URL, UTF-8,
// with empty, over-limit (PLATFORM_FILE_DROP_PATH_BYTES) or NUL-containing paths rejected. Filling the
// struct and validating the length and NULs are platform.h's shared helper platform_fill_file_drop_event (one source for objc/swift/metal).
// Once the inline copy is done, nothing depends on the URL's lifetime.
func enqueueFileDropIfValid(handle: PlatformWindowHandle, url: URL) -> Bool {
    guard url.isFileURL else { return false }
    guard let data = url.path.data(using: .utf8), data.count <= Int(UInt32.max) else { return false }
    var ev = PlatformEvent()
    let ok = data.withUnsafeBytes { raw -> Bool in
        let base = raw.bindMemory(to: CChar.self).baseAddress
        return platform_fill_file_drop_event(&ev, base, UInt32(data.count))
    }
    guard ok else { return false }
    // The inline copy is done; nothing depends on the lifetime of the NSURL or the String.
    handle.event_queue.push(ev)
    return true
}

#if KNGN_ENABLE_MASCOT
// A borderless window cannot become key or main by default. A subclass answers true to
// canBecomeKey/Main, so that input, the IME first responder and performWindowDragWithEvent: work.
class MascotWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}

// The target of the quit menu (the action raises a flag, read once popUp returns from its modal loop).
class QuitMenuTarget: NSObject {
    var quitChosen = false
    @objc func onQuit(_ sender: Any?) { quitChosen = true }
}
#endif // KNGN_ENABLE_MASCOT

// ========================================
// Exported as C-compatible functions (@_cdecl)
// ========================================

@_cdecl("platform_init")
func platform_init() -> Bool {
    // macOS needs no particular initialisation
    return true
}

@_cdecl("platform_create_window")
func platform_create_window(width: Int32, height: Int32, title: UnsafePointer<CChar>, callback: FrameCallback?, userdata: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    return createWindowImpl(width: width, height: height, title: title, callback: callback, userdata: userdata, transparent: false, borderless: false, position: nil, physical: false)
}

// Create a window with options. opts==NULL keeps the previous behaviour, and unknown flags or reserved!=0 give NULL.
@_cdecl("platform_create_window_ex")
func platform_create_window_ex(width: Int32, height: Int32, title: UnsafePointer<CChar>, callback: FrameCallback?, userdata: UnsafeMutableRawPointer?, opts: UnsafePointer<PlatformWindowOptions>?) -> UnsafeMutableRawPointer? {
    var transparent = false
    var borderless = false
    var physical = false
    var notResizable = false
    var position: (x: Int32, y: Int32)? = nil
    if let opts = opts {
        let flags = opts.pointee.flags
        // Without the mascot opt-in TRANSPARENT and BORDERLESS are not known flags, so asking for
        // one fails the same way an unknown flag does rather than yielding an ordinary window.
#if KNGN_ENABLE_MASCOT
        let known = UInt32(PLATFORM_WINDOW_TRANSPARENT) | UInt32(PLATFORM_WINDOW_BORDERLESS) | UInt32(PLATFORM_WINDOW_POSITION) | UInt32(PLATFORM_WINDOW_FRAMEBUFFER_PHYSICAL) | UInt32(PLATFORM_WINDOW_NOT_RESIZABLE)
#else
        let known = UInt32(PLATFORM_WINDOW_POSITION) | UInt32(PLATFORM_WINDOW_FRAMEBUFFER_PHYSICAL) | UInt32(PLATFORM_WINDOW_NOT_RESIZABLE)
#endif
        if (flags & ~known) != 0 || opts.pointee.reserved != 0 { return nil }
#if KNGN_ENABLE_MASCOT
        transparent = (flags & UInt32(PLATFORM_WINDOW_TRANSPARENT)) != 0
        borderless = (flags & UInt32(PLATFORM_WINDOW_BORDERLESS)) != 0
#endif
        physical = (flags & UInt32(PLATFORM_WINDOW_FRAMEBUFFER_PHYSICAL)) != 0
        notResizable = (flags & UInt32(PLATFORM_WINDOW_NOT_RESIZABLE)) != 0
        if (flags & UInt32(PLATFORM_WINDOW_POSITION)) != 0 {
            position = (opts.pointee.x, opts.pointee.y)
        }
    }
    return createWindowImpl(width: width, height: height, title: title, callback: callback, userdata: userdata, transparent: transparent, borderless: borderless, position: position, physical: physical, notResizable: notResizable)
}

// The shared skeleton of window creation. Creating the backend-specific view is delegated to the
// makePlatformBackendView() factory (defined in each backend file). The window-level style, transparency and placement are shared.
private func createWindowImpl(width: Int32, height: Int32, title: UnsafePointer<CChar>, callback: FrameCallback?, userdata: UnsafeMutableRawPointer?, transparent: Bool, borderless: Bool, position: (x: Int32, y: Int32)?, physical: Bool, notResizable: Bool = false) -> UnsafeMutableRawPointer? {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let windowWidth = CGFloat(width)
    let windowHeight = CGFloat(height)
    let frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

    // Without .resizable the frame has no drag handles and the zoom button is inactive, so the user
    // cannot resize the window (the app still can).
    let styleMask: NSWindow.StyleMask = borderless
        ? [.borderless]                            // frameless
        : (notResizable
            ? [.titled, .closable, .miniaturizable]
            : [.titled, .closable, .miniaturizable, .resizable])

    // borderless uses the subclass that can become the key window (transparent on its own works with a plain NSWindow)
#if KNGN_ENABLE_MASCOT
    let window: NSWindow = borderless
        ? MascotWindow(contentRect: frame, styleMask: styleMask, backing: .buffered, defer: false)
        : NSWindow(contentRect: frame, styleMask: styleMask, backing: .buffered, defer: false)
#else
    let window = NSWindow(contentRect: frame, styleMask: styleMask, backing: .buffered, defer: false)
#endif
    // Disable window tabbing (so the drawing area stays full height regardless of saved defaults or a system setting)
    window.tabbingMode = .disallowed

    // Set the title
    window.title = String(cString: title)

    // Required in order to receive a hover mouseMoved
    window.acceptsMouseMovedEvents = true

#if KNGN_ENABLE_MASCOT
    // Configure the transparent window (the desktop shows through)
    if transparent {
        window.isOpaque = false
        window.backgroundColor = NSColor.clear
    }
    // Borderless drops the rectangular shadow and becomes draggable whether or not it is transparent (the design contract)
    if borderless {
        window.hasShadow = false
        window.isMovable = true
    }
#endif

    // Create the backend-specific view (CALayer or Metal). View-level settings such as transparency and physical mode are made inside the factory.
    guard let backendView = makePlatformBackendView(
        frame: frame,
        width: Int(width),
        height: Int(height),
        callback: callback,
        userdata: userdata,
        transparent: transparent,
        physical: physical
    ) else {
        return nil
    }
    window.contentView = backendView.nativeView

    // Create the PlatformWindow handle
    let platformWindow = PlatformWindowHandle(window: window, backendView: backendView)
    // Set the view → handle back-reference
    backendView.platformWindow = platformWindow
    // Build the NSTrackingArea after setContentView
    backendView.nativeView.updateTrackingAreas()

    // Show the window (with an explicit position, setFrameOrigin; otherwise center)
    if let position = position {
        window.setFrameOrigin(NSPoint(x: CGFloat(position.x), y: CGFloat(position.y)))
    } else {
        window.center()
    }
    window.makeKeyAndOrderFront(nil)
    // IME: make the view the first responder so that inputContext and interpretKeyEvents work
    window.makeFirstResponder(backendView.nativeView)
    app.activate(ignoringOtherApps: true)

    // Start driving the drawing (swift: start the CADisplayLink; metal: a no-op, since isPaused is set in the factory)
    backendView.startPresentation()

    #if KNGN_ENABLE_GAMEPAD
    // Gamepads: make this window the active one and take in the controllers already connected
    gamepadAttachWindow(platformWindow)
    #endif

    let handle = UnsafeMutableRawPointer(Unmanaged.passRetained(platformWindow).toOpaque())

    return handle
}

// The current window geometry. The position is frame.origin, the size is the content size.
// The current window geometry: the position is frame.origin and the size is the content size.
func windowGeometry(_ handle: PlatformWindowHandle) -> PlatformWindowGeometry {
    var geo = PlatformWindowGeometry()
    let frame = handle.window.frame
    let content = handle.window.contentRect(forFrameRect: frame)
    geo.x = Int32(frame.origin.x)
    geo.y = Int32(frame.origin.y)
    geo.width = UInt32(lround(Double(content.size.width)))
    geo.height = UInt32(lround(Double(content.size.height)))
    geo.flags = UInt32(PLATFORM_GEOMETRY_POSITION_VALID)
    return geo
}

@_cdecl("platform_get_window_geometry")
func platform_get_window_geometry(window: UnsafeMutableRawPointer?, out: UnsafeMutablePointer<PlatformWindowGeometry>?) {
    guard let out = out else { return }
    out.pointee = PlatformWindowGeometry()
    guard let window = window else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(window).takeUnretainedValue()
    out.pointee = windowGeometry(handle)
}

// Update the title of the visible window (event time only).
@_cdecl("platform_set_title")
func platform_set_title(platformWindow: UnsafeMutableRawPointer?, title: UnsafePointer<CChar>?) -> Void {
    guard let platformWindow = platformWindow, let title = title else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    handle.window.title = String(cString: title)
}

// The C ABI implementation of transparent / borderless windows plus drag-to-move (KNGN_ENABLE_MASCOT)
#if KNGN_ENABLE_MASCOT

@_cdecl("platform_begin_window_drag")
func platform_begin_window_drag(platformWindow: UnsafeMutableRawPointer?) -> Void {
    guard let platformWindow = platformWindow else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    guard let ev = handle.backendView.takeLastMouseDownEvent() else { return } // consumed one-shot
    handle.window.performDrag(with: ev)
}

@_cdecl("platform_set_always_on_top")
func platform_set_always_on_top(platformWindow: UnsafeMutableRawPointer?, on: Bool) -> Void {
    guard let platformWindow = platformWindow else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    handle.window.level = on ? .statusBar : .normal
}

@_cdecl("platform_set_click_through")
func platform_set_click_through(platformWindow: UnsafeMutableRawPointer?, on: Bool) -> Void {
    guard let platformWindow = platformWindow else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    handle.backendView.setClickThrough(on)
}

@_cdecl("platform_set_dock_visible")
func platform_set_dock_visible(visible: Bool) -> Void {
    NSApplication.shared.setActivationPolicy(visible ? .regular : .accessory)
}

@_cdecl("platform_show_quit_menu")
func platform_show_quit_menu(platformWindow: UnsafeMutableRawPointer?) -> Void {
    guard let platformWindow = platformWindow else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    let target = QuitMenuTarget()
    let menu = NSMenu(title: "Mascot")
    let item = NSMenuItem(title: "終了", action: #selector(QuitMenuTarget.onQuit(_:)), keyEquivalent: "")
    item.target = target
    menu.addItem(item)
    // Pop up at the current mouse position (in view coordinates). It is modal and does not return until something is chosen.
    let view = handle.backendView.nativeView
    let screenPt = NSEvent.mouseLocation
    let winPt = handle.window.convertPoint(fromScreen: screenPt)
    let viewPt = view.convert(winPt, from: nil)
    menu.popUp(positioning: nil, at: viewPt, in: view)
    if target.quitChosen {
        var ev = PlatformEvent()
        ev.type = PLATFORM_EVENT_QUIT
        handle.event_queue.push(ev)
    }
}

#endif // KNGN_ENABLE_MASCOT

#if KNGN_ENABLE_FULLSCREEN

// Ask the window to enter or leave fullscreen (the same toggleFullScreen(nil) transition as the
// green button). toggleFullScreen is a toggle, not a set, so the request is compared against the
// current state, and a request arriving while a transition is in flight is only recorded — the
// delegate applies it when that transition finishes.
@_cdecl("platform_set_fullscreen")
func platform_set_fullscreen(platformWindow: UnsafeMutableRawPointer?, enable: Bool) -> Void {
    guard let platformWindow = platformWindow else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    let window = handle.window
    handle.fsDesired = enable
    if handle.fsTransition { return } // applied by windowDidEnter/ExitFullScreen
    if !window.collectionBehavior.contains(.fullScreenPrimary) {
        window.collectionBehavior.insert(.fullScreenPrimary)
    }
    if window.styleMask.contains(.fullScreen) != enable {
        window.toggleFullScreen(nil)
    }
}

// The settled fullscreen state, as the window system reports it. It covers a fullscreen the user
// started, which is the whole reason this is read rather than remembered from the creation option.
@_cdecl("platform_is_fullscreen")
func platform_is_fullscreen(platformWindow: UnsafeMutableRawPointer?) -> Bool {
    guard let platformWindow = platformWindow else { return false }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    return handle.window.styleMask.contains(.fullScreen)
}

// The geometry an application should persist. While the window is fullscreen (from the moment the
// transition starts until the exit transition has finished) that is the snapshot taken before it
// entered, so persisting it does not save the screen.
@_cdecl("platform_get_windowed_geometry")
func platform_get_windowed_geometry(platformWindow: UnsafeMutableRawPointer?, out: UnsafeMutablePointer<PlatformWindowGeometry>?) {
    guard let out = out else { return }
    out.pointee = PlatformWindowGeometry()
    guard let platformWindow = platformWindow else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    out.pointee = handle.fsWindowedHeld ? handle.fsWindowed : windowGeometry(handle)
}

#endif // KNGN_ENABLE_FULLSCREEN

@_cdecl("platform_run")
func platform_run(platformWindow: UnsafeMutableRawPointer?) -> Void {
    guard let platformWindow = platformWindow else { return }

    // Recover the PlatformWindowHandle from the handle (retaining the window)
    let _ = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()

    let app = NSApplication.shared
    app.run()
}

@_cdecl("platform_destroy_window")
func platform_destroy_window(platformWindow: UnsafeMutableRawPointer?) -> Void {
    guard let platformWindow = platformWindow else { return }

    #if KNGN_ENABLE_MENU
    // menu: detach the delivery target before releasing, so a late MenuTarget action cannot use freed memory
    platform_menu_window_will_destroy(platformWindow)
    #endif

    // Recover the PlatformWindowHandle from the handle and release it
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeRetainedValue()
    #if KNGN_ENABLE_GAMEPAD
    // gamepads: drop the reference when this window is the active one
    gamepadDetachWindow(handle)
    #endif
    // Stop driving the drawing and cut the callback's reference to the view (swift: CADisplayLink; metal: the MTKView delegate)
    handle.backendView.prepareForDestroy()
    // Detach the delegate before closing ourselves (so windowShouldClose does not wrongly push a quit)
    handle.window.delegate = nil
    handle.quitDelegate?.handle = nil
    handle.quitDelegate = nil
    // Close the window
    handle.window.close()
    handle.window.orderOut(nil)
    // weak var platformWindow is nilled automatically
    // the handle is deallocated automatically here
}

// The consumer cancels the close request and keeps the window alive.
@_cdecl("platform_cancel_quit")
func platform_cancel_quit(platformWindow: UnsafeMutableRawPointer?) -> Void {
    guard let platformWindow = platformWindow else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    handle.quitRequested = false
}

@_cdecl("platform_shutdown")
func platform_shutdown() -> Void {
    // macOS needs no particular cleanup
}

// ========================================
// The implementation of the manual drawing API
// ========================================

@_cdecl("platform_poll_events")
func platform_poll_events(platformWindow: UnsafeMutableRawPointer?) -> Bool {
    guard let platformWindow = platformWindow else { return false }

    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    let app = NSApplication.shared

    // Poll events (without blocking)
    while let event = app.nextEvent(matching: .any, until: Date.distantPast, inMode: .default, dequeue: true) {
        // Add a keyboard event to the event queue
        if event.type == .keyDown || event.type == .keyUp {
            #if KNGN_ENABLE_MENU
            // Preventing a keyEquivalent from firing twice.
            // performKeyEquivalent is delegated to the shared menu TU, and once it is consumed no key_down is
            // pushed and nothing goes to the inputContext either (the same semantics as objc).
            if event.type == .keyDown {
                if platform_menu_consume_key_equivalent(Unmanaged.passUnretained(event).toOpaque()) {
                    continue
                }
            }
            #endif
            var platform_event = PlatformEvent()
            platform_event.type = (event.type == .keyDown) ? PLATFORM_EVENT_KEY_DOWN : PLATFORM_EVENT_KEY_UP
            platform_event.payload.keyboard.key = mapKeyCodeToPlatform(event.keyCode)
            platform_event.payload.keyboard.is_repeat = event.isARepeat
            platform_event.payload.keyboard.modifiers = extractModifiers(event.modifierFlags)
            let token = handle.event_queue.push(platform_event)
            keyTrace("key_\(event.type == .keyDown ? "down" : "up") push=\(token != nil) key=\(platform_event.payload.keyboard.key) mods=0x\(String(platform_event.payload.keyboard.modifiers, radix: 16))")

#if KNGN_ENABLE_TEXT_INPUT
            // keyDown: push the physical key_down and then go on to the IME / inputContext path.
            // insertText is the only source of char_input; the event.characters are never read directly.
            if event.type == .keyDown {
                let backendView = handle.backendView
                let nsView = backendView.nativeView
                let hadMarked = backendView.hasMarkedText()
                let hasInputContext = nsView.inputContext != nil
                // When text input is controlled, hand the event to the IME only while it is active (uncontrolled always hands it over).
                let routeToIme = backendView.imeRouteEnabled()
                var handled = false
                if routeToIme, let inputContext = nsView.inputContext {
                    handled = inputContext.handleEvent(event)
                }
                let hasMarked = backendView.hasMarkedText()
                let commandModified = (platform_event.payload.keyboard.modifiers & (UInt32(PLATFORM_MOD_CMD.rawValue) | UInt32(PLATFORM_MOD_CTRL.rawValue))) != 0
                let tombstone = routeToIme && hasInputContext && !commandModified && (hadMarked || hasMarked) && token.map { handle.event_queue.markNone($0) } == true
                keyTrace("handleEvent bool=\(handled) marked=\(hadMarked)->\(hasMarked) route=\(routeToIme) tombstone=\(tombstone)")
            }
#endif // KNGN_ENABLE_TEXT_INPUT

            // The key event has been handled, so it is not passed on to the system (which prevents the beep)
            continue
        }

        app.sendEvent(event)
        app.updateWindows()
    }

    // Check whether the window has been closed
    if !handle.window.isVisible {
        // Add a QUIT event to the queue
        var quit_event = PlatformEvent()
        quit_event.type = PLATFORM_EVENT_QUIT
        handle.event_queue.push(quit_event)
        return false
    }

    return true
}

#if KNGN_ENABLE_TEXT_INPUT

// The IME composition preedit snapshot
@_cdecl("platform_get_composition_snapshot")
func platform_get_composition_snapshot(
    platformWindow: UnsafeMutableRawPointer?,
    buf: UnsafeMutablePointer<CChar>?,
    cap: UInt32,
    meta: UnsafeMutablePointer<PlatformCompositionMeta>?
) -> UInt32 {
    if let meta = meta {
        meta.pointee.revision = 0
        meta.pointee.cursor = 0
        meta.pointee.len = 0
    }
    guard let platformWindow = platformWindow else { return 0 }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    return handle.backendView.copyCompositionSnapshot(buf: buf, cap: cap, meta: meta)
}

@_cdecl("platform_set_composition_rect")
func platform_set_composition_rect(platformWindow: UnsafeMutableRawPointer?, x: Int32, y: Int32, w: Int32, h: Int32) {
    guard let platformWindow = platformWindow else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    handle.backendView.setCompositionRectPixels(x: x, y: y, w: w, h: h)
}

// Tell the platform whether a text editing widget has focus (the same semantics as objc).
@_cdecl("platform_set_text_input_active")
func platform_set_text_input_active(platformWindow: UnsafeMutableRawPointer?, active: Bool) {
    guard let platformWindow = platformWindow else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    handle.backendView.setTextInputActive(active)
}

// IME document access
@_cdecl("platform_set_text_input_document_access")
func platform_set_text_input_document_access(
    platformWindow: UnsafeMutableRawPointer?,
    callbacks: UnsafePointer<PlatformTextInputDocumentCallbacks>?,
    userdata: UnsafeMutableRawPointer?
) {
    guard let platformWindow = platformWindow else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    handle.backendView.setTextInputDocumentAccess(callbacks: callbacks, userdata: userdata)
}

#endif // KNGN_ENABLE_TEXT_INPUT

// Take a snapshot of the event queue counters
@_cdecl("platform_get_event_stats")
func platform_get_event_stats(platformWindow: UnsafeMutableRawPointer?, out: UnsafeMutablePointer<PlatformEventStats>?) -> Void {
    guard let platformWindow = platformWindow, let out = out else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    let q = handle.event_queue
    out.pointee.mouse_move_merge_count = q.mouseMoveMergeCount
    out.pointee.mouse_scroll_merge_count = q.mouseScrollMergeCount
    out.pointee.event_drop_count = q.eventDropCount
}

// Read a high-resolution monotonic time (unadjusted)
@_cdecl("platform_get_time")
func platform_get_time() -> Double {
    let ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    return Double(ns) / 1e9
}

// Main-screen refresh rate in Hz. Returns 0 when unavailable.
// Queried once at startup (event time), never per frame.
@_cdecl("platform_display_refresh_hz")
func platform_display_refresh_hz() -> Double {
    guard let screen = NSScreen.main else { return 0 }
    let fps = screen.maximumFramesPerSecond
    if fps <= 0 { return 0 }
    return Double(fps)
}

@_cdecl("platform_lock_framebuffer")
func platform_lock_framebuffer(platformWindow: UnsafeMutableRawPointer?, out_width: UnsafeMutablePointer<Int32>?, out_height: UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<UInt32>? {
    var metrics = PlatformFramebufferMetrics(
        logical_width: 0,
        logical_height: 0,
        framebuffer_width: 0,
        framebuffer_height: 0,
        content_scale: 1.0,
        scale_epoch: 0
    )
    guard let px = platform_lock_framebuffer_ex(platformWindow: platformWindow, out: &metrics) else { return nil }
    if let out_width = out_width {
        out_width.pointee = Int32(metrics.framebuffer_width)
    }
    if let out_height = out_height {
        out_height.pointee = Int32(metrics.framebuffer_height)
    }
    return px
}

// The metrics for a query (the pending scale is re-read each time).
@_cdecl("platform_get_framebuffer_metrics")
func platform_get_framebuffer_metrics(platformWindow: UnsafeMutableRawPointer?, out: UnsafeMutablePointer<PlatformFramebufferMetrics>?) -> Bool {
    guard let platformWindow = platformWindow, let out = out else { return false }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    handle.backendView.fillMetrics(out, forQuery: true)
    return true
}

@_cdecl("platform_lock_framebuffer_ex")
func platform_lock_framebuffer_ex(platformWindow: UnsafeMutableRawPointer?, out: UnsafeMutablePointer<PlatformFramebufferMetrics>?) -> UnsafeMutablePointer<UInt32>? {
    guard let platformWindow = platformWindow else { return nil }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    // Latch the pending scale and size (only on success are the buffer, scale and epoch committed atomically)
    handle.backendView.applyLatchedMetricsIfNeeded()
    // the latched snapshot (all four fields belong to the same frame)
    if let out = out {
        handle.backendView.fillMetrics(out, forQuery: false)
    }
    // Return currentBuffer (the same shape as objc's getCurrentBuffer: the write buffer after the latch)
    if let live = handle.backendView.initialFramebuffer {
        handle.currentFramebuffer = live
    }
    return handle.currentFramebuffer
}

@_cdecl("platform_unlock_framebuffer")
func platform_unlock_framebuffer(platformWindow: UnsafeMutableRawPointer?) -> Void {
    // Nothing in particular is needed in this API
    // The buffers are swapped in platform_present()
}

@_cdecl("platform_present")
func platform_present(platformWindow: UnsafeMutableRawPointer?) -> Void {
    guard let platformWindow = platformWindow else { return }

    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    guard let fb = handle.currentFramebuffer else { return }
    let view = handle.backendView

    // Present, then receive and store the next write buffer (swift: a swap; metal: a submit plus a slot advance)
    if let next = view.present(framebuffer: fb, width: view.width, height: view.height) {
        handle.currentFramebuffer = next
    }
}

// Set the cursor shape. An unknown value falls back to PLATFORM_CURSOR_DEFAULT.
#if KNGN_ENABLE_CURSOR
@_cdecl("platform_set_cursor")
func platform_set_cursor(platformWindow: UnsafeMutableRawPointer?, shape: Int32) -> Void {
    guard let platformWindow = platformWindow else { return }

    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    let s: PlatformCursorShape
    switch shape {
    case Int32(PLATFORM_CURSOR_CROSSHAIR.rawValue): s = PLATFORM_CURSOR_CROSSHAIR
    case Int32(PLATFORM_CURSOR_HIDDEN.rawValue):    s = PLATFORM_CURSOR_HIDDEN
    default:                                         s = PLATFORM_CURSOR_DEFAULT
    }
    handle.backendView.setCursorShape(s)
}
#endif // KNGN_ENABLE_CURSOR

// Register the live-resize redraw callback. cb==nil unregisters.
@_cdecl("platform_set_redraw_callback")
func platform_set_redraw_callback(platformWindow: UnsafeMutableRawPointer?, cb: PlatformRedrawCallback?, userdata: UnsafeMutableRawPointer?) {
    guard let platformWindow = platformWindow else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    handle.backendView.setRedrawCallback(cb, userdata: userdata)
}

// The event API
@_cdecl("platform_get_event")
func platform_get_event(window: UnsafeMutableRawPointer?, event: UnsafeMutableRawPointer?) -> Bool {
    guard let window = window, let event = event else { return false }

    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(window).takeUnretainedValue()
    let queue = handle.event_queue

    // when the queue is empty
    if queue.head == queue.tail {
        return false
    }

    // Take the next event from the queue (a memory copy)
    let eventPtr = event.bindMemory(to: PlatformEvent.self, capacity: 1)
    eventPtr.pointee = queue[queue.tail]

    queue.tail = (queue.tail + 1) % EVENT_QUEUE_SIZE

    return true
}

// ========================================
// Gamepad input (ADR-009)
// ========================================
//
// Opt-in: `platform_get_gamepad_state` is declared unconditionally in platform.h (the bridging
// header), so the symbol has to be defined even in an executable without the opt-in. An always-false
// fallback that references no GameController type is provided in the #else branch, rather than relying
// on dead code elimination on the Zig side to avoid a link error (defensive by design).
#if KNGN_ENABLE_GAMEPAD
//
// GCExtendedGamepad.buttonA/B/X/Y are already normalised by Apple by physical position (the A/B and
// X/Y swap of a Nintendo-style controller is absorbed by the GameController framework itself), so this
// implementation only has to map them one to one. A stick's Y axis passes on GameController's raw
// value (up = +1); flipping it into screen coordinates is the consumer's job (inheriting the raw value contract of ADR-009).
//
// Hot path declaration: called once per frame, but it is a fixed-length copy of four pads with a few
// fields each (no allocation, no lock), which is neither an all-pixel loop nor real time, so the performance rules do not apply (see ADR-009).
@_cdecl("platform_get_gamepad_state")
func platform_get_gamepad_state(window: UnsafeMutableRawPointer?, index: Int32, out_state: UnsafeMutablePointer<PlatformGamepadState>?) -> Bool {
    guard let out_state = out_state else { return false }
    guard index >= 0 && Int(index) < gamepadSlots.count else { return false }
    guard let controller = gamepadSlots[Int(index)] else { return false }
    guard let pad = controller.extendedGamepad else { return false } // A guard for a profile that changes to an unsupported one after connecting

    var mask: UInt32 = 0
    if pad.buttonA.isPressed { mask |= UInt32(PLATFORM_GAMEPAD_BUTTON_A.rawValue) }
    if pad.buttonB.isPressed { mask |= UInt32(PLATFORM_GAMEPAD_BUTTON_B.rawValue) }
    if pad.buttonX.isPressed { mask |= UInt32(PLATFORM_GAMEPAD_BUTTON_X.rawValue) }
    if pad.buttonY.isPressed { mask |= UInt32(PLATFORM_GAMEPAD_BUTTON_Y.rawValue) }
    if pad.leftShoulder.isPressed { mask |= UInt32(PLATFORM_GAMEPAD_BUTTON_LEFT_SHOULDER.rawValue) }
    if pad.rightShoulder.isPressed { mask |= UInt32(PLATFORM_GAMEPAD_BUTTON_RIGHT_SHOULDER.rawValue) }
    if pad.buttonMenu.isPressed { mask |= UInt32(PLATFORM_GAMEPAD_BUTTON_START.rawValue) }
    if pad.buttonOptions?.isPressed == true { mask |= UInt32(PLATFORM_GAMEPAD_BUTTON_BACK.rawValue) } // nullable
    if pad.leftThumbstickButton?.isPressed == true { mask |= UInt32(PLATFORM_GAMEPAD_BUTTON_LEFT_STICK.rawValue) } // nullable
    if pad.rightThumbstickButton?.isPressed == true { mask |= UInt32(PLATFORM_GAMEPAD_BUTTON_RIGHT_STICK.rawValue) } // nullable
    if pad.dpad.up.isPressed { mask |= UInt32(PLATFORM_GAMEPAD_BUTTON_DPAD_UP.rawValue) }
    if pad.dpad.down.isPressed { mask |= UInt32(PLATFORM_GAMEPAD_BUTTON_DPAD_DOWN.rawValue) }
    if pad.dpad.left.isPressed { mask |= UInt32(PLATFORM_GAMEPAD_BUTTON_DPAD_LEFT.rawValue) }
    if pad.dpad.right.isPressed { mask |= UInt32(PLATFORM_GAMEPAD_BUTTON_DPAD_RIGHT.rawValue) }
    if pad.buttonHome?.isPressed == true { mask |= UInt32(PLATFORM_GAMEPAD_BUTTON_GUIDE.rawValue) } // nullable

    out_state.pointee.buttons_mask = mask
    out_state.pointee.left_stick_x = pad.leftThumbstick.xAxis.value
    out_state.pointee.left_stick_y = pad.leftThumbstick.yAxis.value
    out_state.pointee.right_stick_x = pad.rightThumbstick.xAxis.value
    out_state.pointee.right_stick_y = pad.rightThumbstick.yAxis.value
    out_state.pointee.left_trigger = pad.leftTrigger.value
    out_state.pointee.right_trigger = pad.rightTrigger.value
    return true
}
#else
@_cdecl("platform_get_gamepad_state")
func platform_get_gamepad_state(window: UnsafeMutableRawPointer?, index: Int32, out_state: UnsafeMutablePointer<PlatformGamepadState>?) -> Bool {
    return false // the opt-in is off (no GameController type is referenced at all)
}
#endif // KNGN_ENABLE_GAMEPAD

// ========================================
// File selection dialogs (KNGN_ENABLE_DIALOG)
// ========================================
#if KNGN_ENABLE_DIALOG
// The extension filter uses allowedContentTypes (UTType), which is macOS 11 and later only
// (allowedFileTypes was deprecated in macOS 12). When UTType is nil for an unknown extension, it falls back to no filter (everything allowed).
// The ptr of withUnsafeFileSystemRepresentation is Optional. It is strdup'd only once it is known to be non-null.

@_cdecl("platform_save_file_dialog")
func platform_save_file_dialog(opts: UnsafePointer<PlatformSaveDialogOptions>?) -> UnsafeMutablePointer<CChar>? {
    let panel = NSSavePanel()
    if let opts = opts {
        if let ext = opts.pointee.allowed_ext,
           let type = UTType(filenameExtension: String(cString: ext)) {
            panel.allowedContentTypes = [type]
        }
        if let name = opts.pointee.default_name {
            panel.nameFieldStringValue = String(cString: name)
        }
    }
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return url.withUnsafeFileSystemRepresentation { ptr in
        guard let ptr = ptr else { return nil }
        return strdup(ptr)
    }
}

@_cdecl("platform_open_file_dialog")
func platform_open_file_dialog(opts: UnsafePointer<PlatformOpenDialogOptions>?) -> UnsafeMutablePointer<CChar>? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    if let opts = opts, let ext = opts.pointee.allowed_ext,
       let type = UTType(filenameExtension: String(cString: ext)) {
        panel.allowedContentTypes = [type]
    }
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return url.withUnsafeFileSystemRepresentation { ptr in
        guard let ptr = ptr else { return nil }
        return strdup(ptr)
    }
}

@_cdecl("platform_free_path")
func platform_free_path(path: UnsafeMutablePointer<CChar>?) -> Void {
    if let path = path { free(path) }
}

#endif // KNGN_ENABLE_DIALOG

// ========================================
// The OS text clipboard
// ========================================
// Bit-identical semantics to objc (platform_macos.m):
// truncating on a UTF-8 boundary, clearContents→setString, the empty string, and the null guards.

/// Step back to a UTF-8 code point boundary when cap is exceeded (identical to objc's clipboardUtf8TruncateLen).
private func clipboardUtf8TruncateLen(_ bytes: UnsafePointer<UInt8>, _ len: UInt32, _ cap: UInt32) -> UInt32 {
    var n = min(len, cap)
    while n > 0 && n < len && (bytes[Int(n)] & 0xC0) == 0x80 {
        n -= 1
    }
    return n
}

/// Write UTF-8 text to the OS clipboard. len is a byte length (no NUL termination is needed).
/// utf8==nil && len>0 returns immediately. Invalid UTF-8 clears and then returns (nothing is set).
@_cdecl("platform_set_clipboard_text")
func platform_set_clipboard_text(_ utf8: UnsafePointer<CChar>?, _ len: UInt32) {
    if utf8 == nil && len > 0 { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    let str: String?
    if len == 0 {
        str = ""
    } else if let utf8 = utf8 {
        // String(decoding:as:) is not used, since it substitutes a replacement character (invalid UTF-8 gives nil and returns)
        str = String(bytes: UnsafeRawBufferPointer(start: UnsafeRawPointer(utf8), count: Int(len)), encoding: .utf8)
    } else {
        return
    }
    guard let str = str else { return }
    pb.setString(str, forType: .string)
}

/// Read UTF-8 text from the OS clipboard into the caller's buffer.
/// true on success (an empty string included). No string present, or a failure, gives false. Anything past cap is truncated on a UTF-8 boundary.
@_cdecl("platform_get_clipboard_text")
func platform_get_clipboard_text(
    _ out: UnsafeMutablePointer<CChar>?,
    _ cap: UInt32,
    _ outLen: UnsafeMutablePointer<UInt32>?
) -> Bool {
    outLen?.pointee = 0
    guard let out = out, cap > 0 else { return false }
    guard let str = NSPasteboard.general.string(forType: .string) else { return false }
    guard let data = str.data(using: .utf8) else { return false }
    return data.withUnsafeBytes { rawBuffer -> Bool in
        guard let base = rawBuffer.baseAddress else {
            outLen?.pointee = 0
            return true // empty data = an empty string, successfully
        }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let len = UInt32(data.count)
        let n = clipboardUtf8TruncateLen(bytes, len, cap)
        // The sign difference between CChar and UInt8 is avoided by going through UnsafeMutableRawPointer
        UnsafeMutableRawPointer(out).copyMemory(from: bytes, byteCount: Int(n))
        outLen?.pointee = n
        return true
    }
}
