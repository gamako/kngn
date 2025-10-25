import Cocoa
import MetalKit

// Metal最適化版の実装（Swift）
let IMPLEMENTATION_TYPE = "Metal Optimized (Swift)"

// フレームコールバック型定義（C互換）
typealias FrameCallback = @convention(c) (UnsafeMutablePointer<UInt32>, Int32, Int32, UnsafeMutableRawPointer?) -> Void

// Metal Shading Language シェーダーコード（文字列インライン）
let SHADER_CODE = """
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut vertexShader(uint vertexId [[vertex_id]]) {
    // 全画面クワッドを生成（-1, -1から1, 1）
    float4 positions[4] = {
        float4(-1.0, -1.0, 0.0, 1.0),
        float4(1.0, -1.0, 0.0, 1.0),
        float4(-1.0, 1.0, 0.0, 1.0),
        float4(1.0, 1.0, 0.0, 1.0),
    };

    float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0),
    };

    VertexOut out;
    out.position = positions[vertexId];
    out.texCoord = texCoords[vertexId];
    return out;
}

fragment float4 fragmentShader(VertexOut in [[stage_in]],
                              texture2d<float> framebufferTexture [[texture(0)]]) {
    constexpr sampler textureSampler(coord::normalized,
                                     address::clamp_to_edge,
                                     filter::nearest);

    // テクスチャをサンプリングして表示
    float4 color = framebufferTexture.sample(textureSampler, in.texCoord);
    return color;
}
"""

// PlatformWindowの不透明型として NSObject を継承（参照カウントのため）
class PlatformWindowHandle: NSObject {
    var window: NSWindow
    var metalView: MetalFramebufferView

    init(window: NSWindow, metalView: MetalFramebufferView) {
        self.window = window
        self.metalView = metalView
        super.init()
    }
}

// Metal用レンダラー
class MetalRenderer: NSObject, MTKViewDelegate {
    private var device: MTLDevice
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?

    private var width: Int
    private var height: Int
    private var callback: FrameCallback?
    private var userdata: UnsafeMutableRawPointer?

    // ダブルバッファリング
    private var buffer0: UnsafeMutablePointer<UInt32>
    private var buffer1: UnsafeMutablePointer<UInt32>
    private var currentBuffer: UnsafeMutablePointer<UInt32>
    private var displayBuffer: UnsafeMutablePointer<UInt32>

    // Metal テクスチャ
    private var texture0: MTLTexture?
    private var texture1: MTLTexture?

    // パフォーマンス測定
    private var lastFrameTime: CFAbsoluteTime
    private var frameCount: Int
    private var totalFrameTime: Double

    init(device: MTLDevice, width: Int, height: Int, callback: FrameCallback?, userdata: UnsafeMutableRawPointer?) {
        self.device = device
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

        // パフォーマンス測定の初期化
        self.lastFrameTime = CFAbsoluteTimeGetCurrent()
        self.frameCount = 0
        self.totalFrameTime = 0.0

        super.init()

        // メタルコマンドキューを作成
        self.commandQueue = device.makeCommandQueue()

        // テクスチャを作成
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = width
        descriptor.height = height
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .managed

        self.texture0 = device.makeTexture(descriptor: descriptor)
        self.texture1 = device.makeTexture(descriptor: descriptor)

        // パイプラインステートを作成
        setupRenderPipeline()

        NSLog("[\(IMPLEMENTATION_TYPE)] Metal device: \(device.name), Framebuffer initialized: \(width)x\(height)")
    }

    private func setupRenderPipeline() {
        guard let library = try? device.makeLibrary(source: SHADER_CODE, options: nil) else {
            NSLog("[\(IMPLEMENTATION_TYPE)] Failed to compile shaders")
            return
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertexShader")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragmentShader")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            NSLog("[\(IMPLEMENTATION_TYPE)] Failed to create render pipeline: \(error)")
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 描画サイズ変更時の処理（特になし）
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let pipelineState = self.pipelineState,
              let commandQueue = self.commandQueue else {
            return
        }

        let frameStartTime = CFAbsoluteTimeGetCurrent()

        // ユーザーのコールバックを呼び出してピクセルデータを生成
        if let callback = callback {
            let callbackStart = CFAbsoluteTimeGetCurrent()
            callback(currentBuffer, Int32(width), Int32(height), userdata)
            let callbackEnd = CFAbsoluteTimeGetCurrent()

            // バッファをスワップ
            let temp = currentBuffer
            currentBuffer = displayBuffer
            displayBuffer = temp

            // テクスチャを選択
            let renderStart = CFAbsoluteTimeGetCurrent()
            let texture = (displayBuffer == buffer0) ? texture0 : texture1

            // 表示するバッファをテクスチャに転送
            if let texture = texture {
                let region = MTLRegionMake2D(0, 0, width, height)
                let bytesPerRow = width * MemoryLayout<UInt32>.size
                texture.replace(region: region, mipmapLevel: 0, withBytes: displayBuffer, bytesPerRow: bytesPerRow)
            }

            // コマンドバッファを作成
            guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

            // レンダーコマンドエンコーダを作成
            guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

            // パイプラインを設定
            renderEncoder.setRenderPipelineState(pipelineState)

            // テクスチャを設定
            if let texture = texture {
                renderEncoder.setFragmentTexture(texture, index: 0)
            }

            // ドローコール（4頂点で全画面クワッドを描画）
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            renderEncoder.endEncoding()

            // レンダリング完了後にpresentと実行をスケジュール
            commandBuffer.present(drawable)
            commandBuffer.commit()

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

    deinit {
        let bufferSize = width * height
        buffer0.deinitialize(count: bufferSize)
        buffer0.deallocate()
        buffer1.deinitialize(count: bufferSize)
        buffer1.deallocate()
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

    func presentManual(view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let pipelineState = self.pipelineState,
              let commandQueue = self.commandQueue else {
            return
        }

        // バッファをスワップ
        let temp = currentBuffer
        currentBuffer = displayBuffer
        displayBuffer = temp

        // テクスチャを選択
        let texture = (displayBuffer == buffer0) ? texture0 : texture1

        // 表示するバッファをテクスチャに転送
        if let texture = texture {
            let region = MTLRegionMake2D(0, 0, width, height)
            let bytesPerRow = width * MemoryLayout<UInt32>.size
            texture.replace(region: region, mipmapLevel: 0, withBytes: displayBuffer, bytesPerRow: bytesPerRow)
        }

        // コマンドバッファを作成
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // レンダーコマンドエンコーダを作成
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        // パイプラインを設定
        renderEncoder.setRenderPipelineState(pipelineState)

        // テクスチャを設定
        if let texture = texture {
            renderEncoder.setFragmentTexture(texture, index: 0)
        }

        // ドローコール（4頂点で全画面クワッドを描画）
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()

        // レンダリング完了後にpresentと実行をスケジュール
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// カスタムMTKView
class MetalFramebufferView: MTKView {
    private var metalRenderer: MetalRenderer?

    override init(frame: CGRect, device: MTLDevice?) {
        let metalDevice = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: metalDevice)

        // デリゲートは後で設定
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setupRenderer(width: Int, height: Int, callback: FrameCallback?, userdata: UnsafeMutableRawPointer?) {
        guard let device = self.device else { return }
        metalRenderer = MetalRenderer(device: device, width: width, height: height, callback: callback, userdata: userdata)
        self.delegate = metalRenderer
    }

    func getRenderer() -> MetalRenderer? {
        return metalRenderer
    }
}

// C互換の関数でエクスポート

@_cdecl("platform_init")
func platform_init() -> Bool {
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

    // Metal用ビューを作成
    guard let metalDevice = MTLCreateSystemDefaultDevice() else {
        NSLog("[\(IMPLEMENTATION_TYPE)] Failed to create Metal device")
        return nil
    }

    let metalView = MetalFramebufferView(frame: frame, device: metalDevice)
    metalView.framebufferOnly = false
    metalView.enableSetNeedsDisplay = false

    // レンダラーをセットアップ
    metalView.setupRenderer(width: Int(width), height: Int(height), callback: callback, userdata: userdata)

    window.contentView = metalView

    // ウィンドウを表示
    window.center()
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)

    // PlatformWindowハンドルを作成
    let platformWindow = PlatformWindowHandle(window: window, metalView: metalView)
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
    handle.metalView.delegate = nil
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
        app.sendEvent(event)
        app.updateWindows()
    }

    // ウィンドウが閉じられているか確認
    return handle.window.isVisible
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

    // MetalFramebufferViewのrendererにアクセス
    guard let renderer = handle.metalView.getRenderer() else { return nil }

    // サイズを返す
    if let out_width = out_width {
        out_width.pointee = Int32(renderer.getWidth())
    }
    if let out_height = out_height {
        out_height.pointee = Int32(renderer.getHeight())
    }

    // currentBufferを返す
    return renderer.getCurrentBuffer()
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

    // MetalFramebufferViewのrendererにアクセス
    guard let renderer = handle.metalView.getRenderer() else { return }

    // 手動で描画
    renderer.presentManual(view: handle.metalView)
}
