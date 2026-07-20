import Cocoa
import MetalKit

// Metal最適化版の backend 実装（Swift。TASK-140 で共有コードを platform_macos_shared.swift へ分離）
// 型定義 (PlatformEvent, PlatformEventType, PlatformKeyCode, PLATFORM_* 定数,
//        FrameCallback typealias など) は bridging header (-import-objc-header
//        platform/platform.h) 経由で C ヘッダから自動取得する。
//
// 本ファイルは PlatformBackendView に適合する MetalFramebufferView（MTKView + triple-slot ring）と
// MetalRenderer、makePlatformBackendView() ファクトリのみを持つ。C ABI・イベントキュー・IME 状態・
// ウィンドウ生成骨格は platform_macos_shared.swift 側。
//
// TASK-113.4 / TASK-135: OS ファイル drag & drop（file URL のみ）を objc backend と同一契約で実装。
// MetalFramebufferView が NSDraggingDestination を実装し、単一 file URL を PLATFORM_EVENT_FILE_DROP
// として event_queue へ inline copy で投入する（複数/非ファイル/空/上限超/NUL は reject）。
// struct 充填は platform.h の共有ヘルパー platform_fill_file_drop_event（objc/swift/metal 単一ソース）。
//
// ========================================
// 1級 frame pacing 契約（ADR-005 / TASK-36）
// ========================================
// この backend は ADR-005 の 1級 backend frame pacing 契約に適合する:
//
// - drawable lifecycle: drawable / renderPassDescriptor の取得・present は MTKView の正規 draw
//   サイクル（draw(in:)）内だけで行う。手動描画は presentManual() が view.draw() を起動して
//   draw(in:) を 1 回呼ぶ。draw サイクル外で currentDrawable を触らないので CAMetalLayerDrawable
//   lifecycle 警告が出ない。
//
// - inflight ownership: CPU pixels + texture を slotCount(=3) の ring で持ち、DispatchSemaphore
//   (value=slotCount-1=2) で最大 inflight を 2 に制限する。present のたびに wait()、command buffer
//   の completion handler で signal()。present された slot は GPU 完了まで backend 所有。
//
// - 再利用安全の不変条件（per-slot フラグ無しで成立。Apple 標準 triple-buffer idiom）:
//   API は「lockFramebuffer → caller が書込 → present(submit)」の順。slot k(=f%slotCount) の前回
//   使用は f-slotCount。slot のテクスチャは present 内で texture.replace される直前に semaphore.wait()
//   を通る。semaphore=slotCount-1 と Metal 単一 command queue の in-order completion により、wait()
//   通過時には f-(slotCount-1) 以前が完了済み = slot k(前回使用 f-slotCount)は free。CPU バッファ自体は
//   texture.replace が同期コピーなので present 後すぐ再利用可能。
//   semaphore 値が slotCount-1 を超えると前回使用フレーム完了を保証できず hazard になる。
//
// - fifo pacing: commandBuffer.present(drawable)（次 vsync 表示）+ CAMetalLayer.displaySyncEnabled
//   + 上記 inflight cap。busy loop でも ~60fps（display refresh）に張り付く。
//
// - lockFramebuffer() は non-null 互換を維持する（frame slot は ring + semaphore で常に確保できる）。
//   null による frame availability gating / beginFrame・waitFrame / fatal 状態分離は本タスク対象外で、
//   ADR-005 の follow-up 方針（TASK-38）に委ねる。
let IMPLEMENTATION_TYPE = "Metal Optimized (Swift)"

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

// Metal用レンダラー
class MetalRenderer: NSObject, MTKViewDelegate {
    private var device: MTLDevice
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?

    private var width: Int
    private var height: Int
    private var callback: FrameCallback?
    private var userdata: UnsafeMutableRawPointer?

    // ========================================
    // Triple-slot frame ring（ADR-005 1級 frame pacing / inflight ownership）
    // ========================================
    // 各 slot = CPU pixels バッファ + Metal texture。caller は currentSlotIndex の slot へ書き、
    // present が submit して index を (idx+1)%slotCount へ前進させる。
    // inflight ownership と再利用安全条件はファイル冒頭コメント参照。
    private let slotCount = 3
    private var slotBuffers: [UnsafeMutablePointer<UInt32>] = []
    private var slotTextures: [MTLTexture?] = []
    private var currentSlotIndex = 0
    private var lastSubmittedSlot = -1  // TASK-104: click-through hitTest が読む直近表示済み slot（-1=未 submit）

    // inflight 上限 = slotCount - 1（= 2）。display sync(fifo) の pacing を司る。
    // present のたびに wait()、command buffer の completion handler で signal()。
    private let inflightSemaphore = DispatchSemaphore(value: 2)

    // manual present（present() → view.draw() 起点）であることを draw(in:) に伝えるフラグ。
    private var manualPresentPending = false

    // パフォーマンス測定
    private var lastFrameTime: CFAbsoluteTime
    private var frameCount: Int
    private var totalFrameTime: Double
    // FPS ログは VP_METAL_FPS_LOG=1 のときのみ（既定=無出力。TASK-158）
    private let fpsLogEnabled: Bool

    init(device: MTLDevice, width: Int, height: Int, callback: FrameCallback?, userdata: UnsafeMutableRawPointer?) {
        self.device = device
        self.width = width
        self.height = height
        self.callback = callback
        self.userdata = userdata

        // パフォーマンス測定の初期化
        self.lastFrameTime = CFAbsoluteTimeGetCurrent()
        self.frameCount = 0
        self.totalFrameTime = 0.0
        // env は初期化時に1回だけ読む（フレーム毎の getenv を避ける）
        self.fpsLogEnabled = ProcessInfo.processInfo.environment["VP_METAL_FPS_LOG"] == "1"

        super.init()

        // slotCount 個の CPU バッファを確保（ゼロ初期化）
        let bufferSize = width * height
        for _ in 0..<slotCount {
            let buf = UnsafeMutablePointer<UInt32>.allocate(capacity: bufferSize)
            buf.initialize(repeating: 0, count: bufferSize)
            slotBuffers.append(buf)
        }

        // メタルコマンドキューを作成
        self.commandQueue = device.makeCommandQueue()

        // slotCount 個のテクスチャを作成（各 slot に 1 枚。inflight 中の再利用を避ける）
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .bgra8Unorm // canonical BGRA: メモリ [B,G,R,A] = u32 0xAARRGGBB（drawable と同形式）
        descriptor.width = width
        descriptor.height = height
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .managed
        for _ in 0..<slotCount {
            slotTextures.append(device.makeTexture(descriptor: descriptor))
        }

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

    // MTKView の正規 draw サイクル。drawable / renderPassDescriptor の取得・present は
    // 必ずこの中だけで行う（draw サイクル外で currentDrawable を触ると CAMetalLayerDrawable
    // lifecycle 警告が出るため）。manual present（view.draw() 起点）と callback/display-link
    // 起点の双方から同じ submitFrame() helper へ流す。
    func draw(in view: MTKView) {
        let isManual = manualPresentPending
        manualPresentPending = false

        if isManual {
            // manual mode: caller が lockFramebuffer() で得た現在 slot を既に書き込み済み。
            if submitFrame(view: view, slotIndex: currentSlotIndex) {
                currentSlotIndex = (currentSlotIndex + 1) % slotCount
            }
        } else if let callback = callback {
            // callback/display-link 経路（Zig facade は callback=nil なので未使用。objc/swift 対称性のため維持）。
            callback(slotBuffers[currentSlotIndex], Int32(width), Int32(height), userdata)
            if submitFrame(view: view, slotIndex: currentSlotIndex) {
                currentSlotIndex = (currentSlotIndex + 1) % slotCount
            }
            // TASK-104: callback 経路でも click-through を更新（objc/swift 対称。無効時は即 return）
            (view as? MetalFramebufferView)?.refreshClickThrough()
        }
        // 上記いずれでもない（callback=nil かつ manual でない起動）は何もしない。
        // manual mode は isPaused=true なので display-link 由来の空 draw は来ない。
    }

    // 指定 slot を GPU へ submit する共通経路。manual / callback 双方から呼ぶ。
    // 戻り値: 実際に submit したら true（呼び出し側が slot index を前進させる）。
    @discardableResult
    private func submitFrame(view: MTKView, slotIndex: Int) -> Bool {
        guard let pipelineState = self.pipelineState,
              let commandQueue = self.commandQueue,
              let texture = slotTextures[slotIndex] else {
            return false
        }

        // ① inflight 枠を確保。最大 inflight = slotCount-1 に制限し、display sync(fifo) の
        //    pacing を成立させる（busy loop でも unbounded submit にならない）。
        inflightSemaphore.wait()

        // ② drawable / renderPassDescriptor は MTKView の draw サイクル内でのみ有効。
        //    取れない場合は確保した inflight 枠を戻して skip する。
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            inflightSemaphore.signal()
            return false
        }

        // ③ CPU pixels → texture へ転送（managed storage への同期コピー）。
        //    この slot のテクスチャは前回使用(slotCount フレーム前)が完了済みなので再利用安全
        //    （不変条件はファイル冒頭コメント参照）。
        let region = MTLRegionMake2D(0, 0, width, height)
        let bytesPerRow = width * MemoryLayout<UInt32>.size
        texture.replace(region: region, mipmapLevel: 0, withBytes: slotBuffers[slotIndex], bytesPerRow: bytesPerRow)
        lastSubmittedSlot = slotIndex // TASK-104: click-through hitTest 用（直近表示中の CPU buffer）

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setFragmentTexture(texture, index: 0)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()

        // ④ present(drawable): 次の display refresh で表示（fifo）。
        commandBuffer.present(drawable)
        // ⑤ 完了時に inflight 枠を解放。self / slot を捕捉せず semaphore のみ（retain cycle 回避）。
        commandBuffer.addCompletedHandler { [inflightSemaphore] _ in
            inflightSemaphore.signal()
        }
        commandBuffer.commit()

        updatePerfStats()
        return true
    }

    // 60 フレームごとに FPS をログ出力（fifo pacing の検証用に ~60fps 張り付きを観測できる）。
    // 出力は fpsLogEnabled（VP_METAL_FPS_LOG=1）のときのみ。計測ロジック自体は常時走らせる。
    private func updatePerfStats() {
        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        totalFrameTime += now - lastFrameTime
        lastFrameTime = now

        if frameCount % 60 == 0 {
            let avgFrameTime = totalFrameTime / 60.0
            let fps = avgFrameTime > 0 ? 1.0 / avgFrameTime : 0
            if fpsLogEnabled {
                NSLog("[\(IMPLEMENTATION_TYPE)] FPS: \(String(format: "%.1f", fps)) | Avg Frame: \(String(format: "%.2f", avgFrameTime * 1000.0))ms")
            }
            totalFrameTime = 0.0
        }
    }

    deinit {
        let bufferSize = width * height
        for buf in slotBuffers {
            buf.deinitialize(count: bufferSize)
            buf.deallocate()
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
        return slotBuffers[currentSlotIndex]
    }

    // TASK-104: click-through 用に直近表示中フレームの alpha を読む（best-effort）。
    // 未 submit（-1）は不透明扱い（255）で抜けさせない。範囲外は 0（抜けさせる）。
    func sampleAlpha(x: Int, y: Int) -> UInt8 {
        if x < 0 || y < 0 || x >= width || y >= height { return 0 }
        if lastSubmittedSlot < 0 { return 255 } // 初回 present 前は不透明扱い（ゼロ buffer を読まない）
        let pixel = slotBuffers[lastSubmittedSlot][y * width + x]
        return UInt8((pixel >> 24) & 0xFF)
    }

    // 手動描画の present。drawable を直接触らず、MTKView の draw サイクルを起動するだけ。
    // 実際の upload / encode / present は draw(in:) → submitFrame() 内で行う。
    func presentManual(view: MTKView) {
        manualPresentPending = true
        view.draw()
    }

    // TASK-23: 新サイズへ slot buffers/textures を two-phase で再確保する。
    // 単位は logical points（mouse 座標と同一。drawableSize=pixels ではない。texture は drawable へ
    // upscale されるので Retina 挙動は従来どおり）。setFrameSize（イベントポンプ中）から呼ばれ、
    // present(submitFrame) とは同一メインスレッドで直列なので非並行。
    // - 旧 CPU buffer: submitFrame で texture.replace により同期コピー済み → GPU は非同期参照しない → 解放安全。
    // - 旧 texture: inflight command buffer が ARC で完了まで保持 → 配列から外しても安全。
    // 戻り値: サイズが実際に変わって再確保した場合 true（TASK-23.1 redraw 発火判定用）。
    @discardableResult
    func resize(width w0: Int, height h0: Int) -> Bool {
        let w = max(1, w0)
        let h = max(1, h0)
        if w == width && h == height { return false } // 変化なし
        let newSize = w * h

        // phase 1: 新リソースを確保
        var newBuffers: [UnsafeMutablePointer<UInt32>] = []
        for _ in 0..<slotCount {
            let buf = UnsafeMutablePointer<UInt32>.allocate(capacity: newSize)
            buf.initialize(repeating: 0, count: newSize)
            newBuffers.append(buf)
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.width = w
        descriptor.height = h
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .managed
        var newTextures: [MTLTexture?] = []
        for _ in 0..<slotCount {
            newTextures.append(device.makeTexture(descriptor: descriptor))
        }
        // texture 確保失敗時は新 CPU buffer を解放して旧状態を維持する（two-phase: 全部揃った時だけ swap）
        if newTextures.contains(where: { $0 == nil }) {
            for buf in newBuffers {
                buf.deinitialize(count: newSize)
                buf.deallocate()
            }
            return false
        }

        // phase 2: 旧 CPU buffer を解放して swap（texture は ARC に任せる）
        let oldSize = width * height
        for buf in slotBuffers {
            buf.deinitialize(count: oldSize)
            buf.deallocate()
        }
        slotBuffers = newBuffers
        slotTextures = newTextures
        width = w
        height = h
        currentSlotIndex = 0
        lastSubmittedSlot = -1 // TASK-104: 新規ゼロ buffer を「表示済み」と誤読しないよう次 submit まで不透明扱い
        return true
    }
}

// カスタムMTKView + NSTextInputClient（TASK-79.6.1 IME）
class MetalFramebufferView: MTKView, NSTextInputClient, PlatformBackendView {
    private var metalRenderer: MetalRenderer?

    // マウスイベント用 (TASK-21.1)。back-ref 設定時に imeState へも伝播する。
    weak var platformWindow: PlatformWindowHandle? {
        didSet { imeState.platformWindow = platformWindow }
    }
    private var customTrackingArea: NSTrackingArea?

    // IME 状態は共有 PlatformIMEState に集約（TASK-140）。NSTextInputClient / カスタム IME メソッドを転送する。
    let imeState = PlatformIMEState()

    // カーソル制御用 (TASK-75.1)
    private var currentCursorShape: PlatformCursorShape = PLATFORM_CURSOR_DEFAULT  // 直近に要求された形状
    private var cursorHiddenByThisView: Bool = false  // このviewが [NSCursor hide] を所有中か（グローバル参照カウントAPIの多重呼び出し防止）
    private var mouseInsideView: Bool = false         // マウスが現在 view 内にあるか（view外では set/hide を保留する）

    // ライブリサイズ再描画 (TASK-23.1)。CADisplayLink 用 FrameCallback とは別 field。
    private var redrawCallback: PlatformRedrawCallback?
    private var redrawUserdata: UnsafeMutableRawPointer?

    // 透過ウィンドウ / クリック透過 / 対話的ドラッグ (TASK-104)
    private var transparentMode: Bool = false
    private var clickThrough: Bool = false
    private var clickThroughState: Bool = false // 直近設定した ignoresMouseEvents 値（変化時のみ再設定）
    private var lastMouseDownEvent: NSEvent?

    override init(frame: CGRect, device: MTLDevice?) {
        let metalDevice = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: metalDevice)

        // IME 状態に host view を渡す（fb サイズは setupRenderer で更新。TASK-140）
        imeState.hostView = self

        // デリゲートは後で設定
        // TASK-135: OS ファイル drag & drop（file URL のみ。objc backend 先行の横展開）
        self.registerForDraggedTypes([.fileURL])
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - PlatformBackendView (TASK-140)

    var nativeView: NSView { return self }
    var implementationType: String { return IMPLEMENTATION_TYPE }
    var width: Int { return metalRenderer?.getWidth() ?? 0 }
    var height: Int { return metalRenderer?.getHeight() ?? 0 }
    var initialFramebuffer: UnsafeMutablePointer<UInt32>? { return metalRenderer?.getCurrentBuffer() }

    // present: 既存 presentManual(view:) + refreshClickThrough を行い、次の書込バッファを返す。
    // size 引数は互換のため受けるが renderer の内部サイズを使う（引数は無視）。
    func present(framebuffer: UnsafeMutablePointer<UInt32>, width: Int, height: Int) -> UnsafeMutablePointer<UInt32>? {
        guard let renderer = metalRenderer else { return nil }
        // 手動で描画
        renderer.presentManual(view: self)
        // TASK-104: クリック透過のカーソル位置判定を更新（clickThrough 無効時は即 return）
        refreshClickThrough()
        // present 後の現在 slot（submit で前進済み）の CPU バッファを返す
        return renderer.getCurrentBuffer()
    }

    func prepareForDestroy() {
        // delegate を解除 (callback から view への参照を断つ)
        self.delegate = nil
    }

    func startPresentation() {
        // Metal は isPaused / display-link 設定をファクトリで済ませているため no-op。
        // 手動 present 経路は present() が view.draw() で 1 フレームずつ駆動する。
    }

    // MARK: - NSTextInputClient 転送（共有 PlatformIMEState へ委譲。TASK-140）

    func copyCompositionSnapshot(buf: UnsafeMutablePointer<CChar>?, cap: UInt32, meta: UnsafeMutablePointer<PlatformCompositionMeta>?) -> UInt32 {
        return imeState.copyCompositionSnapshot(buf: buf, cap: cap, meta: meta)
    }
    func setCompositionRectPixels(x: Int32, y: Int32, w: Int32, h: Int32) {
        imeState.setCompositionRectPixels(x: x, y: y, w: w, h: h)
    }
    func setTextInputActive(_ active: Bool) {
        imeState.setTextInputActive(active)
    }
    func setTextInputDocumentAccess(
        callbacks: UnsafePointer<PlatformTextInputDocumentCallbacks>?,
        userdata: UnsafeMutableRawPointer?
    ) {
        imeState.setTextInputDocumentAccess(callbacks: callbacks, userdata: userdata)
    }
    func imeRouteEnabled() -> Bool { return imeState.imeRouteEnabled() }

    func insertText(_ string: Any, replacementRange: NSRange) {
        imeState.insertText(string, replacementRange: replacementRange)
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        imeState.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
    func unmarkText() { imeState.unmarkText() }
    func hasMarkedText() -> Bool { return imeState.hasMarkedText() }
    func markedRange() -> NSRange { return imeState.markedRange() }
    func selectedRange() -> NSRange { return imeState.selectedRange() }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { return imeState.validAttributesForMarkedText() }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return imeState.attributedSubstring(forProposedRange: range, actualRange: actualRange)
    }
    func characterIndex(for point: NSPoint) -> Int { return imeState.characterIndex(for: point) }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        return imeState.firstRect(forCharacterRange: range, actualRange: actualRange)
    }
    override func doCommand(by selector: Selector) { imeState.doCommand(by: selector) }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - NSDraggingDestination / file drop (TASK-135。ホットパス: イベント時のみ)
    // objc backend（platform/macos/platform_macos.m）と同一契約。struct 充填・長さ/NUL 検証は
    // platform.h の共有ヘルパー platform_fill_file_drop_event（共有ヘルパー enqueueFileDropIfValid 経由）。

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        if let urls = urls, urls.count >= 1 {
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let handle = platformWindow else { return false }
        let pb = sender.draggingPasteboard
        // MVP は単一ファイルのみ。複数同時 drop はイベント全体を reject。
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              urls.count == 1 else { return false }
        return enqueueFileDropIfValid(handle: handle, url: urls[0])
    }

    deinit {
        // カーソルを hide したまま破棄されると OS カーソルが消えたままになる (TASK-75.1 codex レビュー指摘)。
        if cursorHiddenByThisView {
            NSCursor.unhide()
            cursorHiddenByThisView = false
        }
    }

    func setupRenderer(width: Int, height: Int, callback: FrameCallback?, userdata: UnsafeMutableRawPointer?) {
        guard let device = self.device else { return }
        metalRenderer = MetalRenderer(device: device, width: width, height: height, callback: callback, userdata: userdata)
        self.delegate = metalRenderer
        // IME firstRect の pixel→bounds 換算に使う fb サイズを反映（TASK-140）
        imeState.updateFramebufferSize(width: width, height: height)
    }

    // NSView がリサイズ時に呼ぶ。renderer の fb を新しい logical サイズへ再確保する（TASK-23）。
    // MTKView の drawableSize は別途自動更新され、texture は drawable へ upscale される。
    // サイズが実際に変わったときだけ redraw callback を発火する（TASK-23.1。
    // callback 内 present は presentManual → view.draw() で同期。manual モードは isPaused=true）。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let renderer = metalRenderer else { return }
        if renderer.resize(width: Int(newSize.width), height: Int(newSize.height)) {
            // TASK-140: 再確保後の新書込バッファを handle へ反映する（次 lock/present が正しい buffer を指す）。
            platformWindow?.currentFramebuffer = renderer.getCurrentBuffer()
            imeState.updateFramebufferSize(width: renderer.getWidth(), height: renderer.getHeight())
            if let cb = redrawCallback {
                cb(redrawUserdata)
            }
        }
    }

    // ライブリサイズ再描画コールバック登録 (TASK-23.1)。cb==nil で解除。
    func setRedrawCallback(_ cb: PlatformRedrawCallback?, userdata: UnsafeMutableRawPointer?) {
        redrawCallback = cb
        redrawUserdata = userdata
    }

    // ========================================
    // マウスイベント関連 (TASK-21.1)
    // ========================================

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = customTrackingArea {
            self.removeTrackingArea(ta)
            customTrackingArea = nil
        }
        // .cursorUpdate: マウス再入時に cursorUpdate(with:) を呼んでもらい、OS がウィンドウ切替等で
        // カーソルをリセットしても復帰できるようにする (TASK-75.1)。
        // .mouseEnteredAndExited: view 内外を追跡し、hidden の所有権解除（exited）と形状の適用（entered）を
        // 行う（codex レビュー: hide/unhide は view 内にいる時のみ行う）。
        let opts: NSTrackingArea.Options = [.mouseMoved, .cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        let ta = NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil)
        self.addTrackingArea(ta)
        customTrackingArea = ta
    }

    // ========================================
    // カーソル制御 (TASK-75.1)
    // ========================================
    //
    // 方針: NSCursor.hide/unhide はプロセス全体の参照カウント API のため、view が「今 hide を
    // 所有しているか」を cursorHiddenByThisView で厳密に管理する（hide は false→true 遷移時のみ、
    // unhide は true→false 遷移時のみ呼ぶ）。加えて set/hide の実適用は mouseInsideView が true の
    // 間だけ行い、view 外にいる間に来た setCursor はまだ反映せず形状のみ保存する。

    // currentCursorShape に対応する NSCursor を返す（PLATFORM_CURSOR_HIDDEN はここでは扱わない）。
    // 未対応形状は arrow にフォールバックする。
    private func nsCursor(for shape: PlatformCursorShape) -> NSCursor {
        switch shape {
        case PLATFORM_CURSOR_CROSSHAIR: return .crosshair
        default: return .arrow // PLATFORM_CURSOR_DEFAULT および未対応形状のフォールバック
        }
    }

    // mouseInsideView 前提で currentCursorShape を実際に適用する（hide 所有権の遷移も含む）。
    private func applyCursorShapeIfInside() {
        guard mouseInsideView else { return }
        if currentCursorShape == PLATFORM_CURSOR_HIDDEN {
            if !cursorHiddenByThisView {
                NSCursor.hide()
                cursorHiddenByThisView = true
            }
        } else {
            if cursorHiddenByThisView {
                NSCursor.unhide()
                cursorHiddenByThisView = false
            }
            nsCursor(for: currentCursorShape).set()
        }
    }

    // platform_set_cursor から呼ばれる。形状を保存し、view 内にいれば即時反映する。
    func setCursorShape(_ shape: PlatformCursorShape) {
        currentCursorShape = shape
        applyCursorShapeIfInside()
    }

    // マウスが view に再入した (TASK-75.1)。現在の形状を反映する。
    override func mouseEntered(with event: NSEvent) {
        mouseInsideView = true
        applyCursorShapeIfInside()
    }

    // マウスが view から出た (TASK-75.1)。hide を所有中なら必ず解放する
    // （view 外で OS カーソルが消えたままになるのを防ぐ。codex レビュー指摘）。
    override func mouseExited(with event: NSEvent) {
        mouseInsideView = false
        if cursorHiddenByThisView {
            NSCursor.unhide()
            cursorHiddenByThisView = false
        }
    }

    // AppKit がトラッキングエリア再入時に呼ぶ。他アプリ切替等で OS がカーソルをリセットしても復帰する。
    override func cursorUpdate(with event: NSEvent) {
        // cursorUpdate は tracking rect 内でのみ呼ばれる（.cursorUpdate）ので view 内扱いにする。
        // mouseEntered 未発火・順序差・window 切替後の cursor reset 復帰でも形状を反映するため（codex レビュー指摘）。
        mouseInsideView = true
        applyCursorShapeIfInside()
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

    // TASK-104: 透過モード（isOpaque）/ クリック透過（per-pixel hitTest）/ beginDrag 用 event。
    override var isOpaque: Bool {
        return !transparentMode
    }
    // TASK-104: クリック透過（per-pixel）。present 毎に現在のカーソル位置の alpha を見て
    // `window.ignoresMouseEvents` をトグルする（NSView.hitTest では背後の別アプリへ抜けないため）。
    // alpha は renderer が持つ直近表示 slot から読む。ホットパス宣言: present 毎だが 1 画素サンプルのみ。
    func refreshClickThrough() {
        guard clickThrough, let win = window, let r = metalRenderer else { return }
        let screenPt = NSEvent.mouseLocation
        let winPt = win.convertPoint(fromScreen: screenPt)
        let local = convert(winPt, from: nil) // window → view（非 flipped = 左下原点）
        let b = bounds
        let w = r.getWidth()
        let h = r.getHeight()
        var passThrough = true // カーソルが window 外/未確定なら抜けさせる
        if b.width > 0 && b.height > 0 &&
           local.x >= 0 && local.x < b.width && local.y >= 0 && local.y < b.height {
            var px = Int(local.x / b.width * CGFloat(w))
            var py = Int((1.0 - local.y / b.height) * CGFloat(h)) // top-left 原点へ
            if px >= w { px = w - 1 } // 右端/下端の丸め込み clamp（下端1px落ち防止）
            if py >= h { py = h - 1 }
            if px < 0 { px = 0 }
            if py < 0 { py = 0 }
            passThrough = (r.sampleAlpha(x: px, y: py) == 0)
        }
        if passThrough != clickThroughState { // 値が変わったときだけ WindowServer 状態を書く
            win.ignoresMouseEvents = passThrough
            clickThroughState = passThrough
        }
    }
    func setTransparentMode(_ on: Bool) {
        transparentMode = on
    }
    func setClickThrough(_ on: Bool) {
        clickThrough = on
        if !on {
            window?.ignoresMouseEvents = false // 無効化時は受け取りへ戻す
            clickThroughState = false
        }
    }
    func takeLastMouseDownEvent() -> NSEvent? {
        let ev = lastMouseDownEvent
        lastMouseDownEvent = nil
        return ev
    }

    override func mouseDown(with event: NSEvent) {
        lastMouseDownEvent = event // TASK-104: beginDrag 用に保持
        enqueueMouseEvent(type: PLATFORM_EVENT_MOUSE_DOWN, button: buttonFromEvent(event), from: event)
    }
    override func mouseUp(with event: NSEvent) {
        lastMouseDownEvent = nil // TASK-104: up で stale 破棄
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
}

// ========================================
// backend ファクトリ (TASK-140)
// ========================================
// 共有 createWindowImpl から呼ばれ、Metal backend の view を生成する。Metal device 生成・
// framebufferOnly/enableSetNeedsDisplay・透過 clearColor・isPaused・displaySyncEnabled・renderer
// セットアップはここで行う（旧 createWindowImpl の metal 分岐相当。frame pacing 契約は不変）。
func makePlatformBackendView(
    frame: NSRect,
    width: Int,
    height: Int,
    callback: FrameCallback?,
    userdata: UnsafeMutableRawPointer?,
    transparent: Bool
) -> (any PlatformBackendView)? {
    // Metal用ビューを作成
    guard let metalDevice = MTLCreateSystemDefaultDevice() else {
        NSLog("[\(IMPLEMENTATION_TYPE)] Failed to create Metal device")
        return nil
    }

    let metalView = MetalFramebufferView(frame: frame, device: metalDevice)
    metalView.framebufferOnly = false
    metalView.enableSetNeedsDisplay = false
    // TASK-104: Metal の透過（drawable の alpha を保持し CAMetalLayer で背後合成）
    if transparent {
        metalView.setTransparentMode(true) // isOpaque override が false を返す
        metalView.layer?.isOpaque = false
        metalView.clearColor = MTLClearColorMake(0, 0, 0, 0) // 透明クリア
    }
    // 手動描画経路（callback=nil。Zig facade の lockFramebuffer→present 経路）では display-link を止め、
    // present() が view.draw() で 1 フレームずつ駆動する。callback 経路（objc/swift 対称・未使用）は
    // 従来どおり display-link 駆動のため isPaused=false にする。
    metalView.isPaused = (callback == nil)
    // fifo（display refresh 同期）の意図をコード上で明示する。macOS では CAMetalLayer の既定が true
    // なので必須の挙動変更ではないが、ADR-005 の 1級 backend 契約を明文化する。
    (metalView.layer as? CAMetalLayer)?.displaySyncEnabled = true

    // レンダラーをセットアップ
    metalView.setupRenderer(width: width, height: height, callback: callback, userdata: userdata)

    return metalView
}
