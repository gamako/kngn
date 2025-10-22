import Cocoa
import QuartzCore

// CALayer最適化版の実装（Swift）
let IMPLEMENTATION_TYPE = "CALayer Optimized (Swift)"

// フレームコールバック型定義（C互換）
typealias FrameCallback = @convention(c) (UnsafeMutablePointer<UInt32>, Int32, Int32, UnsafeMutableRawPointer?) -> Void

// PlatformWindowの不透明型として NSObject を継承（参照カウントのため）
class PlatformWindowHandle: NSObject {
    var window: NSWindow
    var view: FramebufferView

    init(window: NSWindow, view: FramebufferView) {
        self.window = window
        self.view = view
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
