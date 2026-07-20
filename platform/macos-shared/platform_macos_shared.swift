import Cocoa
import UniformTypeIdentifiers
#if VP_ENABLE_GAMEPAD
import GameController
#endif

// macOS Swift backend 共有コード (TASK-140)
// swift(CALayer) / metal 両 backend で共通の C ABI・イベントキュー・IME・ゲームパッド・
// メニュー bridge・ウィンドウ生成骨格を集約する。backend 固有の描画実装は
// platform/macos-swift/platform_macos_swift.swift（CALayer）と
// platform/macos-metal/platform_macos_metal.swift（Metal）が PlatformBackendView に適合し、
// makePlatformBackendView() ファクトリで生成する。
//
// 型定義 (PlatformEvent, PlatformEventType, PlatformKeyCode, PLATFORM_* 定数,
//        FrameCallback typealias など) は bridging header (-import-objc-header
//        platform/platform.h) 経由で C ヘッダから自動取得する。
//
// TASK-113.4 / TASK-135: OS ファイル drag & drop（file URL のみ）を objc backend と同一契約で実装。
// 各 backend の view が NSDraggingDestination を実装し、単一 file URL を PLATFORM_EVENT_FILE_DROP として
// event_queue へ inline copy で投入する（複数/非ファイル/空/上限超/NUL は reject）。struct 充填・
// 長さ/NUL 検証は共有ヘルパー enqueueFileDropIfValid（さらに platform.h の platform_fill_file_drop_event）。

// ========================================
// イベント処理用定義 (Swift 側ローカル)
// ========================================

let EVENT_QUEUE_SIZE = 256
let keyTraceEnabled = ProcessInfo.processInfo.environment["VP_KEY_TRACE"] == "1"
// TASK-159 診断: IME / document access の実測トレース（既定 OFF。VP_IME_TRACE=1 で有効）。
let imeTraceEnabled = ProcessInfo.processInfo.environment["VP_IME_TRACE"] == "1"

func keyTrace(_ message: String) {
    guard keyTraceEnabled else { return }
    let line = Data("[key-trace] \(message)\n".utf8)
    FileHandle.standardError.write(line)
}

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

struct EventQueueToken {
    let index: Int
    let generation: UInt32
}

// イベントキュー構造体（固定サイズ配列を使用）
class EventQueue {
    private var events: UnsafeMutablePointer<PlatformEvent>
    private var slotGeneration: [UInt32]
    var head: Int = 0  // 次に書き込む位置
    var tail: Int = 0  // 次に読む位置
    // 観測カウンタ (累積値、example で差分監視に使う)
    var mouseMoveMergeCount: UInt64 = 0
    var mouseScrollMergeCount: UInt64 = 0
    var eventDropCount: UInt64 = 0

    init() {
        // 固定サイズのメモリバッファを確保
        events = UnsafeMutablePointer<PlatformEvent>.allocate(capacity: EVENT_QUEUE_SIZE)
        // すべてのイベントを 0 初期化 (type = PLATFORM_EVENT_NONE)
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

    // キュー末尾の最新イベント (空なら nil)。読み書き両用にポインタ経由でアクセス。
    func peekTail() -> UnsafeMutablePointer<PlatformEvent>? {
        if head == tail { return nil }
        let prev = (head - 1 + EVENT_QUEUE_SIZE) % EVENT_QUEUE_SIZE
        return events.advanced(by: prev)
    }

    // mouse_move の末尾合体 (buttons_mask + modifiers 同一時のみ)。合体時 true。
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

    // mouse_scroll の末尾合体 (is_precise + buttons_mask + modifiers 同一時のみ)。
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

    // キューに push (満杯なら drop カウンタを増やして捨てる)
    // token は gamepad connect の後追い無効化にのみ使う。他の呼び出し元は戻り値不要のため
    // @discardableResult（swiftc の unused-result 警告を抑止。objc 側の queue_push と同じ扱い）。
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
// マウス入力ヘルパー (TASK-21.1)
// ========================================

// non-precise scroll の line→points 変換係数 (経験則)
let SCROLL_LINE_TO_POINTS: Float = 16.0

// NSEvent.locationInWindow を view 内の左上原点座標へ変換 (floor 整数化)。
func eventLocationToPlatformCoords(_ event: NSEvent, _ view: NSView) -> (Int32, Int32) {
    let windowPt = event.locationInWindow
    let viewPt = view.convert(windowPt, from: nil)
    let viewHeight = view.bounds.size.height
    let x = Int32(floor(viewPt.x))
    let y = Int32(floor(viewHeight - viewPt.y))  // Y フリップ
    return (x, y)
}

// 現在押下中のボタン bitmask (& 0x07 で X1/X2 を除外)。
func pressedButtonsMask() -> UInt8 {
    return UInt8(NSEvent.pressedMouseButtons & 0x07)
}

// NSEvent.buttonNumber から PlatformMouseButton へ (物理ボタン基準)。
func buttonFromEvent(_ event: NSEvent) -> PlatformMouseButton {
    switch event.buttonNumber {
        case 0: return PLATFORM_MOUSE_BUTTON_LEFT
        case 1: return PLATFORM_MOUSE_BUTTON_RIGHT
        case 2: return PLATFORM_MOUSE_BUTTON_MIDDLE
        default: return PLATFORM_MOUSE_BUTTON_NONE
    }
}

// macOSのキーコードをPlatformKeyCodeに変換
// 参考: /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/Headers/Events.h
func mapKeyCodeToPlatform(_ keyCode: UInt16) -> PlatformKeyCode {
    switch keyCode {
        // 文字キー（ANSI配列）
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

        // モディファイアキー（左）
        case 0x38: return PLATFORM_KEY_LEFT_SHIFT      // kVK_Shift
        case 0x3A: return PLATFORM_KEY_LEFT_ALT        // kVK_Option
        case 0x3B: return PLATFORM_KEY_LEFT_CONTROL    // kVK_Control
        case 0x37: return PLATFORM_KEY_LEFT_SUPER      // kVK_Command
        case 0x39: return PLATFORM_KEY_CAPS_LOCK       // kVK_CapsLock

        // モディファイアキー（右）
        case 0x3C: return PLATFORM_KEY_RIGHT_SHIFT     // kVK_RightShift
        case 0x3D: return PLATFORM_KEY_RIGHT_ALT       // kVK_RightOption
        case 0x3E: return PLATFORM_KEY_RIGHT_CONTROL   // kVK_RightControl
        case 0x36: return PLATFORM_KEY_RIGHT_SUPER     // kVK_RightCommand

        // ファンクションキー
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

        // 編集キー
        case 0x72: return PLATFORM_KEY_INSERT          // kVK_Help
        case 0x73: return PLATFORM_KEY_HOME            // kVK_Home
        case 0x74: return PLATFORM_KEY_PAGE_UP         // kVK_PageUp
        case 0x75: return PLATFORM_KEY_DELETE          // kVK_ForwardDelete
        case 0x77: return PLATFORM_KEY_END             // kVK_End
        case 0x79: return PLATFORM_KEY_PAGE_DOWN       // kVK_PageDown

        // 矢印キー
        case 0x7B: return PLATFORM_KEY_LEFT            // kVK_LeftArrow
        case 0x7C: return PLATFORM_KEY_RIGHT           // kVK_RightArrow
        case 0x7D: return PLATFORM_KEY_DOWN            // kVK_DownArrow
        case 0x7E: return PLATFORM_KEY_UP              // kVK_UpArrow

        // テンキー
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

// モディファイアキーを抽出
func extractModifiers(_ nsModifiers: NSEvent.ModifierFlags) -> UInt32 {
    var mods: UInt32 = 0
    if nsModifiers.contains(.shift)   { mods |= UInt32(PLATFORM_MOD_SHIFT.rawValue) }
    if nsModifiers.contains(.control) { mods |= UInt32(PLATFORM_MOD_CTRL.rawValue) }
    if nsModifiers.contains(.option)  { mods |= UInt32(PLATFORM_MOD_ALT.rawValue) }
    if nsModifiers.contains(.command) { mods |= UInt32(PLATFORM_MOD_CMD.rawValue) }
    return mods
}

// ========================================
// backend view 抽象 (TASK-140)
// ========================================
//
// swift(CALayer) / metal 両 backend の view が適合する共有プロトコル。共有 C ABI は
// backendView 経由でのみ view を操作し、backend 固有の描画実装（CALayer / Metal ring）を
// 隠蔽する。thin に保ち、描画本体・IME 状態は各 backend / PlatformIMEState 側に置く。
protocol PlatformBackendView: AnyObject {
    var nativeView: NSView { get }
    var width: Int { get }
    var height: Int { get }
    var initialFramebuffer: UnsafeMutablePointer<UInt32>? { get }
    // 現在の書込バッファを present（swap / submit）し、次に書込むバッファを返す。
    // size 引数は互換のため受けるが実装は内部サイズを使う。
    func present(
        framebuffer: UnsafeMutablePointer<UInt32>,
        width: Int,
        height: Int
    ) -> UnsafeMutablePointer<UInt32>?
    var implementationType: String { get }
    func setCursorShape(_ shape: PlatformCursorShape)
    func setClickThrough(_ enabled: Bool)
    func takeLastMouseDownEvent() -> NSEvent?
    func setRedrawCallback(_ cb: PlatformRedrawCallback?, userdata: UnsafeMutableRawPointer?)
    var platformWindow: PlatformWindowHandle? { get set }
    func prepareForDestroy()
    func setTransparentMode(_ enabled: Bool)
    func startPresentation()
    // IME surface（共有 C ABI / poll_events から使う）
    func copyCompositionSnapshot(buf: UnsafeMutablePointer<CChar>?, cap: UInt32, meta: UnsafeMutablePointer<PlatformCompositionMeta>?) -> UInt32
    func setCompositionRectPixels(x: Int32, y: Int32, w: Int32, h: Int32)
    func setTextInputActive(_ active: Bool)
    func setTextInputDocumentAccess(callbacks: UnsafePointer<PlatformTextInputDocumentCallbacks>?, userdata: UnsafeMutableRawPointer?)
    func hasMarkedText() -> Bool
    func imeRouteEnabled() -> Bool
}

// PlatformWindowの不透明型として NSObject を継承（参照カウントのため）
final class PlatformWindowHandle: NSObject {
    let window: NSWindow
    let backendView: any PlatformBackendView
    var currentFramebuffer: UnsafeMutablePointer<UInt32>?
    let width: Int   // create 時サイズ。lock/present は backendView.width/height（live・resize-safe）を使う。
    let height: Int
    let event_queue: EventQueue  // 名前 event_queue は維持（gamepad/既存コードが参照）
    var quitRequested: Bool = false
    var quitDelegate: QuitWindowDelegate?

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

// close ボタンを終了要求へ変換し、consumer が判断するまで window を閉じない。
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
}

// ========================================
// ゲームパッド入力 (TASK-80.2。ADR-009)
// ========================================
//
// opt-in（TASK-80.2 opt-in 化）: GameController framework は audio と同じ opt-in link 方式で、
// ゲームパッドを使う exe（examples/22_gamepad）だけが build.zig から `-DVP_ENABLE_GAMEPAD` を渡す
// （build_helpers/platform.zig の compilePlatformLayer 参照）。非 opt-in exe はこのブロック全体が
// コンパイル対象外になり GameController のシンボルを一切参照しない（`otool -L` にも出ない）。
#if VP_ENABLE_GAMEPAD
//
// GCController ↔ index (0..<PLATFORM_MAX_GAMEPADS) のマッピングを module-level state として保持する。
// 単一 window 前提（既存コードと同じ）なので、connect/disconnect イベントは「現在アクティブな
// window」(最後に create された window) の event_queue へ push する。

/// 接続中コントローラの index→GCController マッピング。nil = 空きスロット。
var gamepadSlots: [GCController?] = Array(repeating: nil, count: Int(PLATFORM_MAX_GAMEPADS))
/// connect/disconnect イベントを push する先の window。
weak var gamepadEventWindow: PlatformWindowHandle?
/// GCControllerDidConnect/DidDisconnect の Notification 監視を設置済みか（1プロセス1回）。
var gamepadObserversInstalled = false

func gamepadFindSlot(for controller: GCController) -> Int? {
    return gamepadSlots.firstIndex { $0 === controller }
}

func gamepadFindFreeSlot() -> Int? {
    return gamepadSlots.firstIndex { $0 == nil }
}

/// PlatformEvent.payload.gamepad.name（固定33バイト、NUL終端）へ UTF-8 文字列を切り詰めコピーする。
func setGamepadEventName(_ ev: inout PlatformEvent, _ name: String) {
    withUnsafeMutableBytes(of: &ev.payload.gamepad.name) { raw in
        for i in 0..<raw.count { raw[i] = 0 }
        let bytes = Array(name.utf8.prefix(raw.count - 1))
        for (i, b) in bytes.enumerated() { raw[i] = b }
    }
}

/// GCController 接続を取り込む。extendedGamepad 非対応（micro gamepad 等）・追跡済み・上限超は無視する。
func gamepadHandleConnect(_ controller: GCController) {
    guard controller.extendedGamepad != nil else { return } // 標準レイアウト非対応は対象外
    guard gamepadFindSlot(for: controller) == nil else { return } // 追跡済み（defensive）
    guard let handle = gamepadEventWindow else { return } // window 未生成中は無視
    guard let idx = gamepadFindFreeSlot() else { return } // PLATFORM_MAX_GAMEPADS 台超は無視
    gamepadSlots[idx] = controller

    var ev = PlatformEvent()
    ev.type = PLATFORM_EVENT_GAMEPAD_CONNECTED
    ev.payload.gamepad.index = Int32(idx)
    setGamepadEventName(&ev, controller.vendorName ?? "Gamepad")
    handle.event_queue.push(ev)
}

/// GCController 切断を取り込む。未追跡なら無視する。
func gamepadHandleDisconnect(_ controller: GCController) {
    guard let idx = gamepadFindSlot(for: controller) else { return }
    gamepadSlots[idx] = nil
    guard let handle = gamepadEventWindow else { return }

    var ev = PlatformEvent()
    ev.type = PLATFORM_EVENT_GAMEPAD_DISCONNECTED
    ev.payload.gamepad.index = Int32(idx)
    handle.event_queue.push(ev)
}

/// GCControllerDidConnect/DidDisconnect の Notification 監視を 1 プロセス 1 回だけ設置する。
/// `queue: .main` を明示指定し main thread 配信を強制する（`queue: nil` だと「通知を post した
/// スレッドで同期実行」になり main thread 保証が無いため。codex レビュー指摘）。これにより
/// event_queue / gamepadSlots への書き込みが pollEvents 等の main thread 経路と同じスレッドに揃い、
/// lock 無しでも race しない。
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

/// window の create/destroy に合わせて「アクティブ window」を切替える。既に他 window から引き継いだ
/// slot（前 window の生存中に接続済みだった controller）は新 window へ connected event を再送し、
/// 未追跡のコントローラは通常の connect 処理で取り込む（codex レビュー指摘: window 再生成時に
/// 既接続 controller の connected event が新 window に届かない問題への対応）。
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
        gamepadHandleConnect(controller) // 未追跡のみ実際に処理する（gamepadFindSlot でスキップ）
    }
}

func gamepadDetachWindow(_ handle: PlatformWindowHandle) {
    if gamepadEventWindow === handle {
        gamepadEventWindow = nil
    }
}
#endif // VP_ENABLE_GAMEPAD

// ========================================
// native メニュー bridge (TASK-122)
// ========================================
//
// 共有 platform_macos_menu.m が NSMenu 本体を持ち、本 backend は EventQueue への
// MENU_COMMAND 積込みと keyEquivalent 消費判定の呼び出しだけを担う。
#if VP_ENABLE_MENU

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

#endif // VP_ENABLE_MENU

// ========================================
// IME 状態 (TASK-79.6.1 / 79.6.3 / 142) — 共有 (TASK-140)
// ========================================
//
// NSTextInputClient のロジックと composition/document-access 状態を PlatformIMEState に集約する。
// 各 backend の view は `let imeState = PlatformIMEState()` を持ち、NSTextInputClient メソッド +
// カスタム IME メソッドを imeState へ転送する。firstRect は hostView.bounds + fb サイズ
// （updateFramebufferSize で更新）から算出する。

// composition preedit 固定バッファ容量（UTF-8。TASK-79.6.1）
let compositionUtf8Cap = 1024

/// s[0..<len] のうち cap 以内に収まる最長 UTF-8 codepoint 境界プレフィックス長（codex 修正 A）。
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
    // event_queue への push 先 / bounds・inputContext・convert・window 参照元
    weak var platformWindow: PlatformWindowHandle?
    weak var hostView: NSView?

    // firstRect の pixel→bounds 換算に使う現在の fb サイズ（resize で更新）
    private var fbWidth: Int = 0
    private var fbHeight: Int = 0

    // IME composition 状態 (TASK-79.6.1)
    private var markedTextStorage = NSMutableString()
    private var imeSelectedRange = NSRange(location: 0, length: 0)
    // テキスト入力フォーカス制御 (TASK-142)。imeControlled=false の間は従来どおり常時 IME 経路。
    private var imeControlled = false
    private var imeActive = false
    private var compositionUtf8 = [UInt8](repeating: 0, count: compositionUtf8Cap)
    private var compositionLen: UInt32 = 0
    private var compositionRevision: UInt32 = 0
    private var compositionCursor: UInt32 = 0
    private var compositionRectPixels = NSRect.zero
    private var compositionRectSet = false

    // IME document access (TASK-79.6.3)
    private var docAccessCallbacks = PlatformTextInputDocumentCallbacks()
    private var docAccessUserdata: UnsafeMutableRawPointer?
    private var docAccessEnabled = false
    private var hasPendingReplacement = false
    private var pendingReplacement = NSRange(location: NSNotFound, length: 0)

    // fb サイズを更新する（init 直後と resize 時に backend が呼ぶ）。firstRect の換算に使う。
    func updateFramebufferSize(width: Int, height: Int) {
        fbWidth = width
        fbHeight = height
    }

    func copyCompositionSnapshot(buf: UnsafeMutablePointer<CChar>?, cap: UInt32, meta: UnsafeMutablePointer<PlatformCompositionMeta>?) -> UInt32 {
        // latest-wins: 常に現在 preedit。event.revision は取りこぼし検知用（過去 revision は取れない）。
        if let meta = meta {
            meta.pointee.revision = compositionRevision
            meta.pointee.cursor = compositionCursor
            meta.pointee.len = 0
        }
        guard let buf = buf, cap > 0, compositionLen > 0 else { return 0 }
        // UTF-8 codepoint 境界で切断（codex 修正 A）
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
        // 固定バッファへ UTF-8 境界で truncate（codex 修正 A）
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

    /// Cmd/Ctrl 押下中は char_input を出さない（キーバインド経由 insertText の誤印字防止。codex 修正 B）。
    private func pushCharInputs(from str: String) {
        guard let handle = platformWindow else { return }
        let charMods = extractModifiers(NSEvent.modifierFlags)
        // printable フィルタと同列の invariant: cmd/ctrl 付きは印字しない
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
            // 不正 UTF-8 は拒否（String(decoding:) による置換は行わない）
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
        // TASK-159: 有効な replacementRange は同一 reconversion/composition で一度だけ latch する。
        // 後続の NSNotFound / caret 零長では上書きしない。
        //
        // pending 破棄条件（空 setMarkedText は cancel ではない — 日本語 IM 再変換は
        // setMarkedText(" ", range) → setMarkedText("") → setMarkedText(候補) → insertText
        // の列で来る。空 mark で pending を消すと insertText が caret 純挿入になり二重化する）:
        //   - insertText で消費した直後
        //   - unmarkText（ESC 等）
        //   - setTextInputActive(false) / document access 解除 / window destroy 経路
        // 安全弁: 新規の有効 replacementRange は hasPending==false のときだけ latch
        // （消費・破棄後の次セッション開始）。空 mark や NSNotFound 更新では破棄しない。
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
            // TASK-159: 空 mark は preedit 表示のクリアのみ。pending は保持する。
            // CANCEL phase も出さない（真の cancel は unmarkText）。
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

    // TASK-142: keyDown を IME(inputContext) へ渡すべきか。未制御=従来どおり常時 true。
    func imeRouteEnabled() -> Bool {
        return imeControlled ? imeActive : true
    }

    // TASK-142: テキスト編集フォーカスの有無を app から受ける。実効経路が YES→NO へ変わるとき
    // （未制御=常時 YES からの初回 inactive も含む）保留 composition を破棄する。
    func setTextInputActive(_ active: Bool) {
        let wasRouting = imeRouteEnabled()      // 変更前の実効経路（未制御なら true）
        imeControlled = true
        imeActive = active                      // 変更後の実効経路 = active
        if wasRouting && !active {
            unmarkText()                        // markedText クリア + CANCEL phase + pending 破棄
            hostView?.inputContext?.discardMarkedText()   // IME の変換セッションも破棄（候補窓を閉じる）
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

    /// insertText 用: 解決 range と経路名（explicit_len/pending/explicit_zero/selected/none）。
    private func resolveReplacementRangeDetailed(_ replacementRange: NSRange) -> (range: NSRange, path: String) {
        // 優先順: 明示（length>0）→ pending → 明示（length==0 / caret）→ selected。
        // TASK-159: insertText が caret 零長を明示しても、再変換 latch 済み pending を優先する。
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
            // 不正 UTF-8 は nil（置換しない）
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
            // fb は Retina backing ではなく layer が bounds 全面へ拡縮表示するため、換算は
            // bounds 比（mouse 変換の逆写像と同型）。
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
        // 未処理 command を吸収してビープ抑止。物理キーは key_down 経路で既に届く。
        // super は呼ばない（未処理 command のビープを抑止する NSTextInputClient 契約）。
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

// ========================================
// ファイル drop 共有ヘルパー (TASK-135 / TASK-140)
// ========================================
// objc backend（platform/macos/platform_macos.m）と同一契約: 単一 file URL・UTF-8・
// 空/上限超(PLATFORM_FILE_DROP_PATH_BYTES)/NUL 含有は reject。struct 充填・長さ/NUL 検証は
// platform.h の共有ヘルパー platform_fill_file_drop_event（objc/swift/metal 単一ソース）。
// inline copy 完了後は URL 寿命に非依存。
func enqueueFileDropIfValid(handle: PlatformWindowHandle, url: URL) -> Bool {
    guard url.isFileURL else { return false }
    guard let data = url.path.data(using: .utf8), data.count <= Int(UInt32.max) else { return false }
    var ev = PlatformEvent()
    let ok = data.withUnsafeBytes { raw -> Bool in
        let base = raw.bindMemory(to: CChar.self).baseAddress
        return platform_fill_file_drop_event(&ev, base, UInt32(data.count))
    }
    guard ok else { return false }
    // inline copy 完了。NSURL/String の寿命に依存しない。
    handle.event_queue.push(ev)
    return true
}

// TASK-104: borderless ウィンドウは既定では key/main になれない。subclass で canBecomeKey/Main を
// true にし、入力・IME first responder・performWindowDragWithEvent: を効かせる。
class MascotWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}

// 終了メニュー用ターゲット（action でフラグを立て、popUp のモーダル復帰後に読む）。
class QuitMenuTarget: NSObject {
    var quitChosen = false
    @objc func onQuit(_ sender: Any?) { quitChosen = true }
}

// ========================================
// C 互換の関数でエクスポート (@_cdecl)
// ========================================

@_cdecl("platform_init")
func platform_init() -> Bool {
    // macOSでは特に初期化不要
    return true
}

@_cdecl("platform_create_window")
func platform_create_window(width: Int32, height: Int32, title: UnsafePointer<CChar>, callback: FrameCallback?, userdata: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    return createWindowImpl(width: width, height: height, title: title, callback: callback, userdata: userdata, transparent: false, borderless: false, position: nil)
}

// TASK-104 / TASK-117: options 付きウィンドウ作成。opts==NULL は従来動作。unknown flags / reserved!=0 は NULL。
@_cdecl("platform_create_window_ex")
func platform_create_window_ex(width: Int32, height: Int32, title: UnsafePointer<CChar>, callback: FrameCallback?, userdata: UnsafeMutableRawPointer?, opts: UnsafePointer<PlatformWindowOptions>?) -> UnsafeMutableRawPointer? {
    var transparent = false
    var borderless = false
    var position: (x: Int32, y: Int32)? = nil
    if let opts = opts {
        let flags = opts.pointee.flags
        let known = UInt32(PLATFORM_WINDOW_TRANSPARENT) | UInt32(PLATFORM_WINDOW_BORDERLESS) | UInt32(PLATFORM_WINDOW_POSITION) | UInt32(PLATFORM_WINDOW_FRAMEBUFFER_PHYSICAL)
        if (flags & ~known) != 0 || opts.pointee.reserved != 0 { return nil }
        transparent = (flags & UInt32(PLATFORM_WINDOW_TRANSPARENT)) != 0
        borderless = (flags & UInt32(PLATFORM_WINDOW_BORDERLESS)) != 0
        // TASK-156.1: PHYSICAL flag は受理するが P1 の Swift/Metal buffer は scale=1 のまま（P5 送り）
        _ = (flags & UInt32(PLATFORM_WINDOW_FRAMEBUFFER_PHYSICAL)) != 0
        if (flags & UInt32(PLATFORM_WINDOW_POSITION)) != 0 {
            position = (opts.pointee.x, opts.pointee.y)
        }
    }
    return createWindowImpl(width: width, height: height, title: title, callback: callback, userdata: userdata, transparent: transparent, borderless: borderless, position: position)
}

// ウィンドウ生成の共有骨格。backend 固有の view 生成は makePlatformBackendView() ファクトリへ委譲する
// （各 backend ファイルが定義）。window レベルの style / 透過 / 位置決めは共通。
private func createWindowImpl(width: Int32, height: Int32, title: UnsafePointer<CChar>, callback: FrameCallback?, userdata: UnsafeMutableRawPointer?, transparent: Bool, borderless: Bool, position: (x: Int32, y: Int32)?) -> UnsafeMutableRawPointer? {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let windowWidth = CGFloat(width)
    let windowHeight = CGFloat(height)
    let frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

    let styleMask: NSWindow.StyleMask = borderless
        ? [.borderless]                                    // TASK-104: 枠なし
        : [.titled, .closable, .miniaturizable, .resizable] // TASK-23: 自由リサイズ

    // borderless は key window になれる subclass を使う（transparent 単独は通常 NSWindow で可）
    let window: NSWindow = borderless
        ? MascotWindow(contentRect: frame, styleMask: styleMask, backing: .buffered, defer: false)
        : NSWindow(contentRect: frame, styleMask: styleMask, backing: .buffered, defer: false)
    // TASK-139: window tabbing を無効化（保存 defaults / システム設定に依存させず描画領域を full height に保つ）
    window.tabbingMode = .disallowed

    // タイトルを設定
    window.title = String(cString: title)

    // hover の mouseMoved を受け取るために必須 (TASK-21.1)
    window.acceptsMouseMovedEvents = true

    // TASK-104: 透過ウィンドウ設定（背後が透ける）
    if transparent {
        window.isOpaque = false
        window.backgroundColor = NSColor.clear
    }
    // borderless は透過有無に関わらず矩形影を消し、ドラッグ移動可能にする（設計契約）
    if borderless {
        window.hasShadow = false
        window.isMovable = true
    }

    // backend 固有 view を生成（CALayer / Metal）。透過モード等の view 側設定はファクトリ内で行う。
    guard let backendView = makePlatformBackendView(
        frame: frame,
        width: Int(width),
        height: Int(height),
        callback: callback,
        userdata: userdata,
        transparent: transparent
    ) else {
        return nil
    }
    window.contentView = backendView.nativeView

    // PlatformWindowハンドルを作成
    let platformWindow = PlatformWindowHandle(window: window, backendView: backendView)
    // view → handle の back-reference を設定 (TASK-21.1)
    backendView.platformWindow = platformWindow
    // setContentView 後に NSTrackingArea を構築
    backendView.nativeView.updateTrackingAreas()

    // ウィンドウを表示（TASK-117: 明示位置があれば setFrameOrigin、なければ center）
    if let position = position {
        window.setFrameOrigin(NSPoint(x: CGFloat(position.x), y: CGFloat(position.y)))
    } else {
        window.center()
    }
    window.makeKeyAndOrderFront(nil)
    // IME: view を first responder にして inputContext / interpretKeyEvents が効くようにする（TASK-79.6.1）
    window.makeFirstResponder(backendView.nativeView)
    app.activate(ignoringOtherApps: true)

    // 描画駆動を開始（swift: CADisplayLink 開始 / metal: no-op。isPaused はファクトリで設定済み）
    backendView.startPresentation()

    #if VP_ENABLE_GAMEPAD
    // ゲームパッド: このwindowをアクティブにし、既接続コントローラを取り込む (TASK-80.2)
    gamepadAttachWindow(platformWindow)
    #endif

    let handle = UnsafeMutableRawPointer(Unmanaged.passRetained(platformWindow).toOpaque())

    return handle
}

// TASK-117: 現在のウィンドウ geometry。位置=frame.origin、サイズ=content サイズ。
@_cdecl("platform_get_window_geometry")
func platform_get_window_geometry(window: UnsafeMutableRawPointer?, out: UnsafeMutablePointer<PlatformWindowGeometry>?) {
    guard let out = out else { return }
    out.pointee.x = 0
    out.pointee.y = 0
    out.pointee.width = 0
    out.pointee.height = 0
    out.pointee.flags = 0
    guard let window = window else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(window).takeUnretainedValue()
    let frame = handle.window.frame
    let content = handle.window.contentRect(forFrameRect: frame)
    out.pointee.x = Int32(frame.origin.x)
    out.pointee.y = Int32(frame.origin.y)
    out.pointee.width = UInt32(lround(Double(content.size.width)))
    out.pointee.height = UInt32(lround(Double(content.size.height)))
    out.pointee.flags = UInt32(PLATFORM_GEOMETRY_POSITION_VALID)
}

// 表示中のウィンドウタイトルを更新する（イベント時のみ）。
@_cdecl("platform_set_title")
func platform_set_title(platformWindow: UnsafeMutableRawPointer?, title: UnsafePointer<CChar>?) -> Void {
    guard let platformWindow = platformWindow, let title = title else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    handle.window.title = String(cString: title)
}

// TASK-104: 透過 / borderless ウィンドウ + ドラッグ移動 の C ABI 実装
@_cdecl("platform_begin_window_drag")
func platform_begin_window_drag(platformWindow: UnsafeMutableRawPointer?) -> Void {
    guard let platformWindow = platformWindow else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    guard let ev = handle.backendView.takeLastMouseDownEvent() else { return } // one-shot 消費
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
    // 現在のマウス位置（view ローカル）にポップアップ（モーダル。選択されるまで戻らない）。
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

// TASK-100.1: 既存ウィンドウをネイティブフルスクリーン化する（緑ボタンと同じ toggleFullScreen(nil)）。
// 既にフルスクリーンなら no-op（二重 toggle 防止）。
@_cdecl("platform_enter_fullscreen")
func platform_enter_fullscreen(platformWindow: UnsafeMutableRawPointer?) -> Void {
    guard let platformWindow = platformWindow else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    let window = handle.window
    if !window.collectionBehavior.contains(.fullScreenPrimary) {
        window.collectionBehavior.insert(.fullScreenPrimary)
    }
    if !window.styleMask.contains(.fullScreen) {
        window.toggleFullScreen(nil)
    }
}

@_cdecl("platform_run")
func platform_run(platformWindow: UnsafeMutableRawPointer?) -> Void {
    guard let platformWindow = platformWindow else { return }

    // ハンドルからPlatformWindowHandleを復元（ウィンドウを保持）
    let _ = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()

    let app = NSApplication.shared
    app.run()
}

@_cdecl("platform_destroy_window")
func platform_destroy_window(platformWindow: UnsafeMutableRawPointer?) -> Void {
    guard let platformWindow = platformWindow else { return }

    #if VP_ENABLE_MENU
    // menu: 解放前に配送先を外し、遅延 MenuTarget action の UAF を防ぐ (TASK-122 r2)
    platform_menu_window_will_destroy(platformWindow)
    #endif

    // ハンドルからPlatformWindowHandleを復元してリリース
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeRetainedValue()
    #if VP_ENABLE_GAMEPAD
    // ゲームパッド: このwindowがアクティブなら参照を外す (TASK-80.2)
    gamepadDetachWindow(handle)
    #endif
    // 描画駆動を停止し callback から view への参照を断つ（swift: CADisplayLink / metal: MTKView delegate）
    handle.backendView.prepareForDestroy()
    // delegate を外してから自己終了する（windowShouldClose の誤 quit を防止）
    handle.window.delegate = nil
    handle.quitDelegate?.handle = nil
    handle.quitDelegate = nil
    // window を閉じる
    handle.window.close()
    handle.window.orderOut(nil)
    // weak var platformWindow は自動で nil 化される
    // handleはここで自動的にdeallocされる
}

// consumer が close request をキャンセルして window を継続する。
@_cdecl("platform_cancel_quit")
func platform_cancel_quit(platformWindow: UnsafeMutableRawPointer?) -> Void {
    guard let platformWindow = platformWindow else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    handle.quitRequested = false
}

@_cdecl("platform_shutdown")
func platform_shutdown() -> Void {
    // macOSでは特にクリーンアップ不要
}

// ========================================
// 手動描画用API実装
// ========================================

@_cdecl("platform_poll_events")
func platform_poll_events(platformWindow: UnsafeMutableRawPointer?) -> Bool {
    guard let platformWindow = platformWindow else { return false }

    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    let app = NSApplication.shared

    // イベントをポーリング（ブロックしない）
    while let event = app.nextEvent(matching: .any, until: Date.distantPast, inMode: .default, dequeue: true) {
        // キーボードイベントをイベントキューに追加
        if event.type == .keyDown || event.type == .keyUp {
            #if VP_ENABLE_MENU
            // TASK-97.3 AC#2 / TASK-122: keyEquivalent 二重発火防止。
            // 共有 menu TU へ performKeyEquivalent を委譲し、消費時は key_down を積まず
            // inputContext にも渡さない（objc と同意味論）。
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

            // keyDown: 物理 key_down を積んだ後 IME/inputContext 経路へ（TASK-79.6.1）。
            // insertText が char_input の唯一の生成元。旧 event.characters 直読みは廃止。
            if event.type == .keyDown {
                let backendView = handle.backendView
                let nsView = backendView.nativeView
                let hadMarked = backendView.hasMarkedText()
                let hasInputContext = nsView.inputContext != nil
                // TASK-142: text input を制御しているなら active のときだけ IME へ渡す（未制御=常時）。
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

            // キーイベントは処理済みなので、システムに渡さない（ビープ音を防ぐ）
            continue
        }

        app.sendEvent(event)
        app.updateWindows()
    }

    // ウィンドウが閉じられているか確認
    if !handle.window.isVisible {
        // QUITイベントをキューに追加
        var quit_event = PlatformEvent()
        quit_event.type = PLATFORM_EVENT_QUIT
        handle.event_queue.push(quit_event)
        return false
    }

    return true
}

// IME composition preedit snapshot（TASK-79.6.1）
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

// TASK-142: テキスト入力フォーカスの有無を platform へ伝える（objc と同意味論）。
@_cdecl("platform_set_text_input_active")
func platform_set_text_input_active(platformWindow: UnsafeMutableRawPointer?, active: Bool) {
    guard let platformWindow = platformWindow else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    handle.backendView.setTextInputActive(active)
}

// TASK-79.6.3: IME document access
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

// イベントキューカウンタの snapshot 取得 (TASK-21.1)
@_cdecl("platform_get_event_stats")
func platform_get_event_stats(platformWindow: UnsafeMutableRawPointer?, out: UnsafeMutablePointer<PlatformEventStats>?) -> Void {
    guard let platformWindow = platformWindow, let out = out else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    let q = handle.event_queue
    out.pointee.mouse_move_merge_count = q.mouseMoveMergeCount
    out.pointee.mouse_scroll_merge_count = q.mouseScrollMergeCount
    out.pointee.event_drop_count = q.eventDropCount
}

// 高精度モノトニック時刻を取得（調整なし）
@_cdecl("platform_get_time")
func platform_get_time() -> Double {
    let ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    return Double(ns) / 1e9
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

// TASK-156.1: scale=1 stub（Swift/Metal の物理 buffer は P5）。logical == framebuffer。
@_cdecl("platform_get_framebuffer_metrics")
func platform_get_framebuffer_metrics(platformWindow: UnsafeMutableRawPointer?, out: UnsafeMutablePointer<PlatformFramebufferMetrics>?) -> Bool {
    guard let platformWindow = platformWindow, let out = out else { return false }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    let w = UInt32(handle.backendView.width)
    let h = UInt32(handle.backendView.height)
    out.pointee.logical_width = w
    out.pointee.logical_height = h
    out.pointee.framebuffer_width = w
    out.pointee.framebuffer_height = h
    out.pointee.content_scale = 1.0
    out.pointee.scale_epoch = 0
    return true
}

@_cdecl("platform_lock_framebuffer_ex")
func platform_lock_framebuffer_ex(platformWindow: UnsafeMutableRawPointer?, out: UnsafeMutablePointer<PlatformFramebufferMetrics>?) -> UnsafeMutablePointer<UInt32>? {
    guard let platformWindow = platformWindow else { return nil }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    let w = UInt32(handle.backendView.width)
    let h = UInt32(handle.backendView.height)
    if let out = out {
        out.pointee.logical_width = w
        out.pointee.logical_height = h
        out.pointee.framebuffer_width = w
        out.pointee.framebuffer_height = h
        out.pointee.content_scale = 1.0
        out.pointee.scale_epoch = 0
    }
    return handle.currentFramebuffer
}

@_cdecl("platform_unlock_framebuffer")
func platform_unlock_framebuffer(platformWindow: UnsafeMutableRawPointer?) -> Void {
    // このAPIでは特に何もする必要なし
    // バッファのスワップはplatform_present()で行う
}

@_cdecl("platform_present")
func platform_present(platformWindow: UnsafeMutableRawPointer?) -> Void {
    guard let platformWindow = platformWindow else { return }

    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    guard let fb = handle.currentFramebuffer else { return }
    let view = handle.backendView

    // present して次の書込バッファを受け取り保存する（swift: swap / metal: submit + slot 前進）
    if let next = view.present(framebuffer: fb, width: view.width, height: view.height) {
        handle.currentFramebuffer = next
    }
}

// カーソル形状を設定する (TASK-75.1)。未知値は PLATFORM_CURSOR_DEFAULT にフォールバックする。
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

// ライブリサイズ再描画コールバック登録 (TASK-23.1)。cb==nil で解除。
@_cdecl("platform_set_redraw_callback")
func platform_set_redraw_callback(platformWindow: UnsafeMutableRawPointer?, cb: PlatformRedrawCallback?, userdata: UnsafeMutableRawPointer?) {
    guard let platformWindow = platformWindow else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    handle.backendView.setRedrawCallback(cb, userdata: userdata)
}

// イベント取得API
@_cdecl("platform_get_event")
func platform_get_event(window: UnsafeMutableRawPointer?, event: UnsafeMutableRawPointer?) -> Bool {
    guard let window = window, let event = event else { return false }

    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(window).takeUnretainedValue()
    let queue = handle.event_queue

    // キューが空の場合
    if queue.head == queue.tail {
        return false
    }

    // キューから次のイベントを取得（メモリコピー）
    let eventPtr = event.bindMemory(to: PlatformEvent.self, capacity: 1)
    eventPtr.pointee = queue[queue.tail]

    queue.tail = (queue.tail + 1) % EVENT_QUEUE_SIZE

    return true
}

// ========================================
// ゲームパッド入力 (TASK-80.2。ADR-009)
// ========================================
//
// opt-in（TASK-80.2 opt-in 化）: `platform_get_gamepad_state` は platform.h（bridging header）で
// 常時宣言されるため、シンボル自体は non-opt-in exe でも定義する必要がある。GameController 型を
// 一切参照しない always-false fallback を #else 側に用意し、リンクエラーの可能性を Zig 側の
// dead-code-elimination 頼みにしない（防御的設計）。
#if VP_ENABLE_GAMEPAD
//
// GCExtendedGamepad.buttonA/B/X/Y は Apple が「物理位置ベース」で既に正規化済み
// （Nintendo 系コントローラの A/B・X/Y 入替も GameController framework 側で吸収される）ため、
// 本実装は 1:1 マッピングするだけで良い。stick の Y 軸は GameController の raw 値
// （上入力 = +1）をそのまま渡す（screen 座標へのフリップは consumer 責務。ADR-009 の raw値契約を継承）。
//
// ホットパス宣言: フレーム毎に呼ばれる想定だが 4台×少数フィールドの固定長 copy
// （alloc/lock 無し）で全画素ループでも RT でもないため性能規約の適用対象外（ADR-009 参照）。
@_cdecl("platform_get_gamepad_state")
func platform_get_gamepad_state(window: UnsafeMutableRawPointer?, index: Int32, out_state: UnsafeMutablePointer<PlatformGamepadState>?) -> Bool {
    guard let out_state = out_state else { return false }
    guard index >= 0 && Int(index) < gamepadSlots.count else { return false }
    guard let controller = gamepadSlots[Int(index)] else { return false }
    guard let pad = controller.extendedGamepad else { return false } // 接続後に非対応プロファイルへ変化した場合の防御

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
    return false // opt-in 無効（TASK-80.2 opt-in 化。GameController型を一切参照しない）
}
#endif // VP_ENABLE_GAMEPAD

// ========================================
// ファイル選択ダイアログ (TASK-24)
// ========================================
// 拡張子フィルタは allowedContentTypes (UTType) を使う（macOS 11+ 専用。allowedFileTypes は
// macOS 12 で deprecated なため移行）。未知拡張子で UTType が nil の場合はフィルタ未設定（全許可）にフォールバック。
// withUnsafeFileSystemRepresentation の ptr は Optional。non-null を確認してから strdup する。

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

// ========================================
// OS テキストクリップボード (TASK-120 / TASK-161)
// ========================================
// objc (platform_macos.m) と bit 同一意味論:
// UTF-8 境界切り詰め / clearContents→setString / 空文字 / null ガード。

/// cap 超過時に UTF-8 コードポイント境界まで後退する（objc clipboardUtf8TruncateLen と同一）。
private func clipboardUtf8TruncateLen(_ bytes: UnsafePointer<UInt8>, _ len: UInt32, _ cap: UInt32) -> UInt32 {
    var n = min(len, cap)
    while n > 0 && n < len && (bytes[Int(n)] & 0xC0) == 0x80 {
        n -= 1
    }
    return n
}

/// OS clipboard へ UTF-8 テキストを書く。len はバイト長（NUL 終端不要）。
/// utf8==nil && len>0 は即 return。不正 UTF-8 は clear 後に return（set しない）。
@_cdecl("platform_set_clipboard_text")
func platform_set_clipboard_text(_ utf8: UnsafePointer<CChar>?, _ len: UInt32) {
    if utf8 == nil && len > 0 { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    let str: String?
    if len == 0 {
        str = ""
    } else if let utf8 = utf8 {
        // String(decoding:as:) は置換文字になるので使わない（不正 UTF-8 は nil→return）
        str = String(bytes: UnsafeRawBufferPointer(start: UnsafeRawPointer(utf8), count: Int(len)), encoding: .utf8)
    } else {
        return
    }
    guard let str = str else { return }
    pb.setString(str, forType: .string)
}

/// OS clipboard から UTF-8 テキストを caller buffer へ読む。
/// 成功時 true（空文字列含む）。文字列無し・失敗は false。cap 超過は UTF-8 境界で切り詰め。
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
            return true // 空データ = 空文字成功
        }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let len = UInt32(data.count)
        let n = clipboardUtf8TruncateLen(bytes, len, cap)
        // CChar↔UInt8 符号差は UnsafeMutableRawPointer 経由で回避
        UnsafeMutableRawPointer(out).copyMemory(from: bytes, byteCount: Int(n))
        outLen?.pointee = n
        return true
    }
}
