import Cocoa
import QuartzCore

// CALayer最適化版の実装（Swift）
// 型定義 (PlatformEvent, PlatformEventType, PlatformKeyCode, PLATFORM_* 定数,
//        FrameCallback typealias など) は bridging header (-import-objc-header
//        platform/platform.h) 経由で C ヘッダから自動取得する。
let IMPLEMENTATION_TYPE = "CALayer Optimized (Swift)"

// ========================================
// イベント処理用定義 (Swift 側ローカル)
// ========================================

let EVENT_QUEUE_SIZE = 256

// イベントキュー構造体（固定サイズ配列を使用）
class EventQueue {
    private var events: UnsafeMutablePointer<PlatformEvent>
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
    func push(_ ev: PlatformEvent) {
        let next_head = (head + 1) % EVENT_QUEUE_SIZE
        if next_head == tail {
            eventDropCount += 1
            return
        }
        events[head] = ev
        head = next_head
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

// PlatformWindowの不透明型として NSObject を継承（参照カウントのため）
class PlatformWindowHandle: NSObject {
    var window: NSWindow
    var view: FramebufferView
    var event_queue: EventQueue

    init(window: NSWindow, view: FramebufferView) {
        self.window = window
        self.view = view
        self.event_queue = EventQueue()
        super.init()
    }
}

// カスタムNSView - CALayerベースの高速描画
class FramebufferView: NSView {
    private var width: Int
    private var height: Int
    private var displayLink: CADisplayLink?
    private var callback: FrameCallback?
    private var userdata: UnsafeMutableRawPointer?

    // ダブルバッファリング（ポインタスワップ方式）
    private var buffer0: UnsafeMutablePointer<UInt32>
    private var buffer1: UnsafeMutablePointer<UInt32>
    private var currentBuffer: UnsafeMutablePointer<UInt32>  // コールバックが書き込むバッファ
    private var displayBuffer: UnsafeMutablePointer<UInt32>  // 画面に表示中のバッファ

    // レイヤー
    private var contentLayer: CALayer

    // CGオブジェクト（初期化時に作成して再利用）
    private var colorSpace: CGColorSpace
    private var provider0: CGDataProvider
    private var provider1: CGDataProvider

    // パフォーマンス測定
    private var lastFrameTime: CFAbsoluteTime
    private var frameCount: Int
    private var totalFrameTime: Double

    // マウスイベント用 (TASK-21.1)
    weak var platformWindow: PlatformWindowHandle?
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect, width: Int, height: Int, callback: FrameCallback?, userdata: UnsafeMutableRawPointer?) {
        self.width = width
        self.height = height
        self.callback = callback
        self.userdata = userdata

        // ダブルバッファを確保
        let bufferSize = width * height
        self.buffer0 = UnsafeMutablePointer<UInt32>.allocate(capacity: bufferSize)
        self.buffer1 = UnsafeMutablePointer<UInt32>.allocate(capacity: bufferSize)

        // バッファを初期化（ゼロで埋める）
        self.buffer0.initialize(repeating: 0, count: bufferSize)
        self.buffer1.initialize(repeating: 0, count: bufferSize)

        self.currentBuffer = self.buffer0
        self.displayBuffer = self.buffer1

        // CGオブジェクトを初期化
        self.colorSpace = CGColorSpaceCreateDeviceRGB()

        // ダミープロバイダー（毎フレーム新しく作成するため）
        self.provider0 = CGDataProvider(data: CFDataCreate(nil, self.buffer0, bufferSize * MemoryLayout<UInt32>.size)!)!
        self.provider1 = CGDataProvider(data: CFDataCreate(nil, self.buffer1, bufferSize * MemoryLayout<UInt32>.size)!)!

        // レイヤー
        self.contentLayer = CALayer()

        // パフォーマンス測定の初期化
        self.lastFrameTime = CFAbsoluteTimeGetCurrent()
        self.frameCount = 0
        self.totalFrameTime = 0.0

        super.init(frame: frame)

        // レイヤーバックドビューに設定
        self.wantsLayer = true

        // コンテンツレイヤーを作成
        self.contentLayer.frame = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        self.contentLayer.isOpaque = true
        self.contentLayer.isGeometryFlipped = true  // Y軸反転を一度だけ設定
        self.layer?.addSublayer(self.contentLayer)

        NSLog("[\(IMPLEMENTATION_TYPE)] Framebuffer initialized: \(width)x\(height)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startDisplayLink() {
        if #available(macOS 13.0, *) {
            // ビューを含むウィンドウのスクリーンから displayLink を取得
            if let screen = self.window?.screen {
                displayLink = screen.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
                displayLink?.add(to: .main, forMode: .common)
            }
        }
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc
    func displayLinkFired(_ link: CADisplayLink) {
        let frameStartTime = CFAbsoluteTimeGetCurrent()

        // ユーザーのコールバックを呼び出してピクセルデータを生成
        if let callback = callback {
            let callbackStart = CFAbsoluteTimeGetCurrent()
            callback(currentBuffer, Int32(width), Int32(height), userdata)
            let callbackEnd = CFAbsoluteTimeGetCurrent()

            // バッファをスワップ（ゼロコピー）
            let temp = currentBuffer
            currentBuffer = displayBuffer
            displayBuffer = temp

            // 表示するバッファに対応する新しいCGDataProviderを毎フレーム作成
            let renderStart = CFAbsoluteTimeGetCurrent()
            let providerData = CFDataCreate(nil, displayBuffer, width * height * MemoryLayout<UInt32>.size)!
            let provider = CGDataProvider(data: providerData)!

            // CGImageを作成（毎フレーム必要）
            let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )

            // レイヤーのcontentsに設定（変換なしで高速）
            if let cgImage = cgImage {
                contentLayer.contents = cgImage
            }

            let renderEnd = CFAbsoluteTimeGetCurrent()

            // パフォーマンス測定
            frameCount += 1
            let frameTime = frameStartTime - lastFrameTime
            totalFrameTime += frameTime
            lastFrameTime = frameStartTime

            // 60フレームごとに統計を出力
            if frameCount % 60 == 0 {
                let avgFrameTime = totalFrameTime / 60.0
                let fps = 1.0 / avgFrameTime
                let callbackTime = (callbackEnd - callbackStart) * 1000.0
                let renderTime = (renderEnd - renderStart) * 1000.0

                NSLog("[\(IMPLEMENTATION_TYPE)] FPS: \(String(format: "%.1f", fps)) | Avg Frame: \(String(format: "%.2f", avgFrameTime * 1000.0))ms | Callback: \(String(format: "%.2f", callbackTime))ms | Render: \(String(format: "%.2f", renderTime))ms")

                totalFrameTime = 0.0
            }
        }
    }

    // 手動描画用のヘルパーメソッド
    func getWidth() -> Int {
        return width
    }

    func getHeight() -> Int {
        return height
    }

    func getCurrentBuffer() -> UnsafeMutablePointer<UInt32> {
        return currentBuffer
    }

    func presentManual() {
        // バッファをスワップ（ゼロコピー）
        let temp = currentBuffer
        currentBuffer = displayBuffer
        displayBuffer = temp

        // 表示するバッファに対応する新しいCGDataProviderを作成
        let providerData = CFDataCreate(nil, displayBuffer, width * height * MemoryLayout<UInt32>.size)!
        let provider = CGDataProvider(data: providerData)!

        // CGImageを作成
        let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )

        // レイヤーのcontentsに設定
        if let cgImage = cgImage {
            contentLayer.contents = cgImage
        }
    }

    override var isOpaque: Bool {
        return true
    }

    // ========================================
    // マウスイベント関連 (TASK-21.1)
    // ========================================

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea {
            self.removeTrackingArea(ta)
            trackingArea = nil
        }
        let opts: NSTrackingArea.Options = [.mouseMoved, .activeInKeyWindow, .inVisibleRect]
        let ta = NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil)
        self.addTrackingArea(ta)
        trackingArea = ta
    }

    private func enqueueMouseEvent(type: PlatformEventType, button: PlatformMouseButton, from event: NSEvent) {
        guard let handle = platformWindow else { return }
        let (x, y) = eventLocationToPlatformCoords(event, self)
        var ev = PlatformEvent()
        ev.type = type
        ev.payload.mouse.x = x
        ev.payload.mouse.y = y
        ev.payload.mouse.button = button
        ev.payload.mouse.buttons_mask = pressedButtonsMask()
        ev.payload.mouse.modifiers = extractModifiers(event.modifierFlags)
        if type == PLATFORM_EVENT_MOUSE_MOVE && handle.event_queue.tryMergeMouseMove(ev) { return }
        handle.event_queue.push(ev)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let handle = platformWindow else { return }
        let (x, y) = eventLocationToPlatformCoords(event, self)
        let isPrecise = event.hasPreciseScrollingDeltas
        var dx = Float(event.scrollingDeltaX)
        var dy = Float(event.scrollingDeltaY)
        if !isPrecise {
            dx *= SCROLL_LINE_TO_POINTS
            dy *= SCROLL_LINE_TO_POINTS
        }
        var ev = PlatformEvent()
        ev.type = PLATFORM_EVENT_MOUSE_SCROLL
        ev.payload.scroll.x = x
        ev.payload.scroll.y = y
        ev.payload.scroll.dx = dx
        ev.payload.scroll.dy = dy
        ev.payload.scroll.is_precise = isPrecise
        ev.payload.scroll.buttons_mask = pressedButtonsMask()
        ev.payload.scroll.modifiers = extractModifiers(event.modifierFlags)
        if handle.event_queue.tryMergeMouseScroll(ev) { return }
        handle.event_queue.push(ev)
    }

    override func mouseDown(with event: NSEvent) {
        enqueueMouseEvent(type: PLATFORM_EVENT_MOUSE_DOWN, button: buttonFromEvent(event), from: event)
    }
    override func mouseUp(with event: NSEvent) {
        enqueueMouseEvent(type: PLATFORM_EVENT_MOUSE_UP, button: buttonFromEvent(event), from: event)
    }
    override func mouseDragged(with event: NSEvent) {
        enqueueMouseEvent(type: PLATFORM_EVENT_MOUSE_MOVE, button: PLATFORM_MOUSE_BUTTON_NONE, from: event)
    }
    override func rightMouseDown(with event: NSEvent) {
        enqueueMouseEvent(type: PLATFORM_EVENT_MOUSE_DOWN, button: buttonFromEvent(event), from: event)
    }
    override func rightMouseUp(with event: NSEvent) {
        enqueueMouseEvent(type: PLATFORM_EVENT_MOUSE_UP, button: buttonFromEvent(event), from: event)
    }
    override func rightMouseDragged(with event: NSEvent) {
        enqueueMouseEvent(type: PLATFORM_EVENT_MOUSE_MOVE, button: PLATFORM_MOUSE_BUTTON_NONE, from: event)
    }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber != 2 { return }
        enqueueMouseEvent(type: PLATFORM_EVENT_MOUSE_DOWN, button: PLATFORM_MOUSE_BUTTON_MIDDLE, from: event)
    }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber != 2 { return }
        enqueueMouseEvent(type: PLATFORM_EVENT_MOUSE_UP, button: PLATFORM_MOUSE_BUTTON_MIDDLE, from: event)
    }
    override func otherMouseDragged(with event: NSEvent) {
        if event.buttonNumber != 2 { return }
        enqueueMouseEvent(type: PLATFORM_EVENT_MOUSE_MOVE, button: PLATFORM_MOUSE_BUTTON_NONE, from: event)
    }
    override func mouseMoved(with event: NSEvent) {
        enqueueMouseEvent(type: PLATFORM_EVENT_MOUSE_MOVE, button: PLATFORM_MOUSE_BUTTON_NONE, from: event)
    }

    deinit {
        stopDisplayLink()

        // バッファを解放
        let bufferSize = width * height
        buffer0.deinitialize(count: bufferSize)
        buffer0.deallocate()
        buffer1.deinitialize(count: bufferSize)
        buffer1.deallocate()
    }
}

// C互換の関数でエクスポート

@_cdecl("platform_init")
func platform_init() -> Bool {
    // macOSでは特に初期化不要
    return true
}

@_cdecl("platform_create_window")
func platform_create_window(width: Int32, height: Int32, title: UnsafePointer<CChar>, callback: FrameCallback?, userdata: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let windowWidth = CGFloat(width)
    let windowHeight = CGFloat(height)
    let frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

    let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]

    let window = NSWindow(
        contentRect: frame,
        styleMask: styleMask,
        backing: .buffered,
        defer: false
    )

    // タイトルを設定
    window.title = String(cString: title)

    // hover の mouseMoved を受け取るために必須 (TASK-21.1)
    window.acceptsMouseMovedEvents = true

    // カスタムビューを作成して設定
    let view = FramebufferView(
        frame: frame,
        width: Int(width),
        height: Int(height),
        callback: callback,
        userdata: userdata
    )
    window.contentView = view

    // PlatformWindowハンドルを作成
    let platformWindow = PlatformWindowHandle(window: window, view: view)
    // view → handle の back-reference を設定 (TASK-21.1)
    view.platformWindow = platformWindow
    // setContentView 後に NSTrackingArea を構築
    view.updateTrackingAreas()

    // ウィンドウを表示
    window.center()
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)

    // CADisplayLinkを開始
    view.startDisplayLink()

    let handle = UnsafeMutableRawPointer(Unmanaged.passRetained(platformWindow).toOpaque())

    return handle
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

    // ハンドルからPlatformWindowHandleを復元してリリース
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeRetainedValue()
    // CADisplayLink を停止 (callback から view への参照を断つ)
    handle.view.stopDisplayLink()
    // window を閉じる
    handle.window.close()
    // weak var platformWindow は自動で nil 化される
    // handleはここで自動的にdeallocされる
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
            var platform_event = PlatformEvent()
            platform_event.type = (event.type == .keyDown) ? PLATFORM_EVENT_KEY_DOWN : PLATFORM_EVENT_KEY_UP
            platform_event.payload.keyboard.key = mapKeyCodeToPlatform(event.keyCode)
            platform_event.payload.keyboard.is_repeat = event.isARepeat
            platform_event.payload.keyboard.modifiers = extractModifiers(event.modifierFlags)
            handle.event_queue.push(platform_event)

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
    guard let platformWindow = platformWindow else { return nil }

    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    let view = handle.view

    // サイズを返す
    if let out_width = out_width {
        out_width.pointee = Int32(view.getWidth())
    }
    if let out_height = out_height {
        out_height.pointee = Int32(view.getHeight())
    }

    // currentBufferを返す
    return view.getCurrentBuffer()
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
    let view = handle.view

    // バッファをスワップして画面に表示
    view.presentManual()
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
