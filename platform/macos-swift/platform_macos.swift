import Cocoa
import QuartzCore

// CALayer最適化版の実装（Swift）
let IMPLEMENTATION_TYPE = "CALayer Optimized (Swift)"

// フレームコールバック型定義（C互換）
typealias FrameCallback = @convention(c) (UnsafeMutablePointer<UInt32>, Int32, Int32, UnsafeMutableRawPointer?) -> Void

// ========================================
// イベント処理用定義
// ========================================

let EVENT_QUEUE_SIZE = 256

// PlatformEvent構造体（C互換）
struct PlatformEvent {
    var type: UInt32
    var keyboard: KeyboardEvent
}

struct KeyboardEvent {
    var key: Int32
    var is_repeat: Bool
    var modifiers: UInt32
}

// イベントタイプ定義
let PLATFORM_EVENT_NONE: UInt32 = 0
let PLATFORM_EVENT_QUIT: UInt32 = 1
let PLATFORM_EVENT_KEY_DOWN: UInt32 = 2
let PLATFORM_EVENT_KEY_UP: UInt32 = 3

// キーコード定義（選択）
let PLATFORM_KEY_UNKNOWN: Int32 = -1
let PLATFORM_KEY_SPACE: Int32 = 32
let PLATFORM_KEY_0: Int32 = 48
let PLATFORM_KEY_1: Int32 = 49
let PLATFORM_KEY_2: Int32 = 50
let PLATFORM_KEY_3: Int32 = 51
let PLATFORM_KEY_4: Int32 = 52
let PLATFORM_KEY_5: Int32 = 53
let PLATFORM_KEY_6: Int32 = 54
let PLATFORM_KEY_7: Int32 = 55
let PLATFORM_KEY_8: Int32 = 56
let PLATFORM_KEY_9: Int32 = 57
let PLATFORM_KEY_A: Int32 = 65
let PLATFORM_KEY_B: Int32 = 66
let PLATFORM_KEY_C: Int32 = 67
let PLATFORM_KEY_D: Int32 = 68
let PLATFORM_KEY_E: Int32 = 69
let PLATFORM_KEY_F: Int32 = 70
let PLATFORM_KEY_G: Int32 = 71
let PLATFORM_KEY_H: Int32 = 72
let PLATFORM_KEY_I: Int32 = 73
let PLATFORM_KEY_J: Int32 = 74
let PLATFORM_KEY_K: Int32 = 75
let PLATFORM_KEY_L: Int32 = 76
let PLATFORM_KEY_M: Int32 = 77
let PLATFORM_KEY_N: Int32 = 78
let PLATFORM_KEY_O: Int32 = 79
let PLATFORM_KEY_P: Int32 = 80
let PLATFORM_KEY_Q: Int32 = 81
let PLATFORM_KEY_R: Int32 = 82
let PLATFORM_KEY_S: Int32 = 83
let PLATFORM_KEY_T: Int32 = 84
let PLATFORM_KEY_U: Int32 = 85
let PLATFORM_KEY_V: Int32 = 86
let PLATFORM_KEY_W: Int32 = 87
let PLATFORM_KEY_X: Int32 = 88
let PLATFORM_KEY_Y: Int32 = 89
let PLATFORM_KEY_Z: Int32 = 90
let PLATFORM_KEY_ESCAPE: Int32 = 256
let PLATFORM_KEY_ENTER: Int32 = 257
let PLATFORM_KEY_LEFT: Int32 = 263
let PLATFORM_KEY_RIGHT: Int32 = 264
let PLATFORM_KEY_UP: Int32 = 265
let PLATFORM_KEY_DOWN: Int32 = 266
let PLATFORM_KEY_CMD: Int32 = 256 + 8

// モディファイアキー定義
let PLATFORM_MOD_SHIFT: UInt32 = 0x01
let PLATFORM_MOD_CTRL: UInt32 = 0x02
let PLATFORM_MOD_ALT: UInt32 = 0x04
let PLATFORM_MOD_CMD: UInt32 = 0x08

// イベントキュー構造体
struct EventQueue {
    var events: [PlatformEvent]
    var head: Int = 0  // 次に書き込む位置
    var tail: Int = 0  // 次に読む位置

    init() {
        var events = [PlatformEvent]()
        for _ in 0..<EVENT_QUEUE_SIZE {
            var event = PlatformEvent(type: PLATFORM_EVENT_NONE, keyboard: KeyboardEvent(key: 0, is_repeat: false, modifiers: 0))
            events.append(event)
        }
        self.events = events
    }
}

// macOSのキーコードをPlatformKeyCodeに変換
func mapKeyCodeToPlatform(_ keyCode: UInt16) -> Int32 {
    switch keyCode {
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
        case 0x1A: return PLATFORM_KEY_9
        case 0x1B: return PLATFORM_KEY_0
        case 0x1C: return PLATFORM_KEY_U
        case 0x1D: return PLATFORM_KEY_O
        case 0x1E: return PLATFORM_KEY_I
        case 0x1F: return PLATFORM_KEY_P
        case 0x31: return PLATFORM_KEY_SPACE
        case 0x35: return PLATFORM_KEY_ESCAPE
        case 0x7B: return PLATFORM_KEY_LEFT
        case 0x7C: return PLATFORM_KEY_RIGHT
        case 0x7D: return PLATFORM_KEY_DOWN
        case 0x7E: return PLATFORM_KEY_UP
        case 0x24: return PLATFORM_KEY_ENTER
        case 0x4C: return PLATFORM_KEY_ENTER
        default: return PLATFORM_KEY_UNKNOWN
    }
}

// モディファイアキーを抽出
func extractModifiers(_ nsModifiers: NSEvent.ModifierFlags) -> UInt32 {
    var mods: UInt32 = 0
    if nsModifiers.contains(.shift)   { mods |= PLATFORM_MOD_SHIFT }
    if nsModifiers.contains(.control) { mods |= PLATFORM_MOD_CTRL }
    if nsModifiers.contains(.option)  { mods |= PLATFORM_MOD_ALT }
    if nsModifiers.contains(.command) { mods |= PLATFORM_MOD_CMD }
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

    // カスタムビューを作成して設定
    let view = FramebufferView(
        frame: frame,
        width: Int(width),
        height: Int(height),
        callback: callback,
        userdata: userdata
    )
    window.contentView = view

    // ウィンドウを表示
    window.center()
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)

    // CADisplayLinkを開始
    view.startDisplayLink()

    // PlatformWindowハンドルを作成
    let platformWindow = PlatformWindowHandle(window: window, view: view)
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
    handle.view.stopDisplayLink()
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
            var queue = handle.event_queue
            let next_head = (queue.head + 1) % EVENT_QUEUE_SIZE

            // キューがいっぱいでない場合のみ追加
            if next_head != queue.tail {
                var platform_event = PlatformEvent(type: PLATFORM_EVENT_NONE, keyboard: KeyboardEvent(key: 0, is_repeat: false, modifiers: 0))
                platform_event.type = (event.type == .keyDown) ? PLATFORM_EVENT_KEY_DOWN : PLATFORM_EVENT_KEY_UP
                platform_event.keyboard.key = mapKeyCodeToPlatform(event.keyCode)
                platform_event.keyboard.is_repeat = event.isARepeat
                platform_event.keyboard.modifiers = extractModifiers(event.modifierFlags)

                queue.events[queue.head] = platform_event
                queue.head = next_head
                handle.event_queue = queue
            }
        }

        app.sendEvent(event)
        app.updateWindows()
    }

    // ウィンドウが閉じられているか確認
    if !handle.window.isVisible {
        // QUITイベントをキューに追加
        var queue = handle.event_queue
        let next_head = (queue.head + 1) % EVENT_QUEUE_SIZE
        if next_head != queue.tail {
            var quit_event = PlatformEvent(type: PLATFORM_EVENT_QUIT, keyboard: KeyboardEvent(key: 0, is_repeat: false, modifiers: 0))
            queue.events[queue.head] = quit_event
            queue.head = next_head
            handle.event_queue = queue
        }
        return false
    }

    return true
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
    var queue = handle.event_queue

    // キューが空の場合
    if queue.head == queue.tail {
        return false
    }

    // キューから次のイベントを取得（メモリコピー）
    memcpy(event, &queue.events[queue.tail], MemoryLayout<PlatformEvent>.size)

    queue.tail = (queue.tail + 1) % EVENT_QUEUE_SIZE
    handle.event_queue = queue

    return true
}
