import Cocoa
import MetalKit

// The Metal-optimised backend, in Swift (the shared code lives in platform_macos_shared.swift)
// The type definitions (PlatformEvent, PlatformEventType, PlatformKeyCode, the PLATFORM_* constants,
//        the FrameCallback typealias and so on) come from the C header automatically, through the
//        bridging header (-import-objc-header platform/platform.h).
//
// This file holds only the MetalFramebufferView that conforms to PlatformBackendView (an MTKView plus
// a triple-slot ring), MetalRenderer, and the makePlatformBackendView() factory. The C ABI, the event
// queue, the IME state and the window creation skeleton are in platform_macos_shared.swift.
//
// OS file drag and drop (file URLs only) is implemented on the same contract as the objc backend.
// MetalFramebufferView implements NSDraggingDestination and puts a single file URL onto the
// event_queue as a PLATFORM_EVENT_FILE_DROP by inline copy (several, non-file, empty, over-limit or NUL-containing paths are rejected).
// Filling the struct is platform.h's shared helper platform_fill_file_drop_event (one source for objc/swift/metal).
//
// ========================================
// The first-class frame pacing contract (ADR-005)
// ========================================
// This backend meets the first-class backend frame pacing contract of ADR-005:
//
// - drawable lifecycle: acquiring and presenting the drawable and the renderPassDescriptor happen
//   only inside MTKView's proper draw cycle (draw(in:)). Manual drawing has presentManual() start
//   view.draw(), which calls draw(in:) once. currentDrawable is never touched outside a draw cycle,
//   so no CAMetalLayerDrawable lifecycle warning appears.
//
// - inflight ownership: the CPU pixels and the texture are held in a ring of slotCount(=3), and a
//   DispatchSemaphore (value=slotCount-1=2) caps the inflight count at 2. Every present wait()s, and
//   the command buffer's completion handler signal()s. A presented slot belongs to the backend until the GPU is done.
//
// - The invariant that makes reuse safe (it holds without a per-slot flag; the standard Apple triple-buffer idiom):
//   the API order is "lockFramebuffer → the caller writes → present (submit)". Slot k(=f%slotCount) was
//   last used at f-slotCount. A slot's texture passes semaphore.wait() immediately before texture.replace
//   inside present. With semaphore=slotCount-1 and the in-order completion of Metal's single command
//   queue, everything up to f-(slotCount-1) has finished by the time wait() returns, so slot k (last used
//   at f-slotCount) is free. The CPU buffer itself is reusable right after a present, since texture.replace copies synchronously.
//   A semaphore value above slotCount-1 could not guarantee the previous frame had finished, which would be a hazard.
//
// - fifo pacing: commandBuffer.present(drawable) (displayed at the next vsync) plus
//   CAMetalLayer.displaySyncEnabled plus the inflight cap above. Even a busy loop sticks at ~60fps (display refresh).
//
// - lockFramebuffer() keeps returning non-null (a frame slot is always available, through the ring plus the semaphore).
//   Gating frame availability through null, beginFrame/waitFrame, and separating out a fatal state are
//   not part of this backend and are left to the follow-up direction of ADR-005.
let IMPLEMENTATION_TYPE = "Metal Optimized (Swift)"

// The Metal Shading Language shader source (inline, as a string)
let SHADER_CODE = """
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut vertexShader(uint vertexId [[vertex_id]]) {
    // Build a full-screen quad (from -1, -1 to 1, 1)
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

    // Sample the texture and display it
    float4 color = framebufferTexture.sample(textureSampler, in.texCoord);
    return color;
}
"""

// The renderer for Metal
class MetalRenderer: NSObject, MTKViewDelegate {
    private var device: MTLDevice
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?

    private var width: Int
    private var height: Int
    private var callback: FrameCallback?
    private var userdata: UnsafeMutableRawPointer?

    // drawableSizeWillChange only records a pending value on the view side (resources are reallocated on the next lock).
    weak var metricsOwner: MetalFramebufferView?

    // ========================================
    // The triple-slot frame ring (the first-class frame pacing and inflight ownership of ADR-005)
    // ========================================
    // Each slot is a CPU pixel buffer plus a Metal texture. The caller writes into the slot at
    // currentSlotIndex, and present submits it and advances the index to (idx+1)%slotCount.
    // Inflight ownership and the conditions for safe reuse are in the comment at the top of this file.
    private let slotCount = 3
    private var slotBuffers: [UnsafeMutablePointer<UInt32>] = []
    private var slotTextures: [MTLTexture?] = []
    private var currentSlotIndex = 0
    private var lastSubmittedSlot = -1  // the most recently displayed slot, read by the click-through hitTest (-1 = nothing submitted yet)

    // The inflight cap = slotCount - 1 (= 2). It governs the pacing of display sync (fifo).
    // Every present wait()s, and the command buffer's completion handler signal()s.
    private let inflightSemaphore = DispatchSemaphore(value: 2)

    // The flag telling draw(in:) that this is a manual present (starting from present() → view.draw()).
    private var manualPresentPending = false

    // performance measurement
    private var lastFrameTime: CFAbsoluteTime
    private var frameCount: Int
    private var totalFrameTime: Double
    // The FPS log is printed only with KNGN_METAL_FPS_LOG=1 (silent by default)
    private let fpsLogEnabled: Bool

    init(device: MTLDevice, width: Int, height: Int, callback: FrameCallback?, userdata: UnsafeMutableRawPointer?) {
        self.device = device
        self.width = width
        self.height = height
        self.callback = callback
        self.userdata = userdata

        // Initialise the performance measurement
        self.lastFrameTime = CFAbsoluteTimeGetCurrent()
        self.frameCount = 0
        self.totalFrameTime = 0.0
        // The env var is read once at initialisation (avoiding a getenv per frame)
        self.fpsLogEnabled = ProcessInfo.processInfo.environment["KNGN_METAL_FPS_LOG"] == "1"

        super.init()

        // Allocate slotCount CPU buffers (zero-filled)
        let bufferSize = width * height
        for _ in 0..<slotCount {
            let buf = UnsafeMutablePointer<UInt32>.allocate(capacity: bufferSize)
            buf.initialize(repeating: 0, count: bufferSize)
            slotBuffers.append(buf)
        }

        // Create the Metal command queue
        self.commandQueue = device.makeCommandQueue()

        // Create slotCount textures (one per slot, so none is reused while inflight)
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .bgra8Unorm // canonical BGRA: memory [B,G,R,A] = u32 0xAARRGGBB (the same format as the drawable)
        descriptor.width = width
        descriptor.height = height
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .managed
        for _ in 0..<slotCount {
            slotTextures.append(device.makeTexture(descriptor: descriptor))
        }

        // Create the pipeline state
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

    // Only the new pending size and scale are recorded. The CPU buffer and the texture are reallocated on the next lock.
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        metricsOwner?.notePendingDrawableChange(size: size)
    }

    // MTKView's proper draw cycle. Acquiring and presenting the drawable and the renderPassDescriptor
    // must happen only in here (touching currentDrawable outside a draw cycle produces a
    // CAMetalLayerDrawable lifecycle warning). Both a manual present (started by view.draw()) and the
    // callback / display-link path flow into the same submitFrame() helper.
    func draw(in view: MTKView) {
        let isManual = manualPresentPending
        manualPresentPending = false

        if isManual {
            // manual mode: the caller has already written into the current slot obtained from lockFramebuffer().
            if submitFrame(view: view, slotIndex: currentSlotIndex) {
                currentSlotIndex = (currentSlotIndex + 1) % slotCount
            }
        } else if let callback = callback {
            // The callback / display-link path (unused by the Zig facade, whose callback is nil; kept for symmetry with objc and swift).
            callback(slotBuffers[currentSlotIndex], Int32(width), Int32(height), userdata)
            if submitFrame(view: view, slotIndex: currentSlotIndex) {
                currentSlotIndex = (currentSlotIndex + 1) % slotCount
            }
#if KNGN_ENABLE_MASCOT
            // Update click-through on the callback path too (symmetrical with objc and swift; returns immediately while disabled)
            (view as? MetalFramebufferView)?.refreshClickThrough()
#endif
        }
        // Neither of the above (callback=nil and not manual) does nothing.
        // In manual mode isPaused=true, so no empty draw arrives from the display link.
    }

    // The shared path that submits the given slot to the GPU. Called from both manual and callback.
    // Returns: true once it really submitted (then the caller advances the slot index).
    @discardableResult
    private func submitFrame(view: MTKView, slotIndex: Int) -> Bool {
        guard let pipelineState = self.pipelineState,
              let commandQueue = self.commandQueue,
              let texture = slotTextures[slotIndex] else {
            return false
        }

        // 1. Take an inflight slot. Capping the inflight count at slotCount-1 is what makes the pacing of
        //    display sync (fifo) work (even a busy loop cannot submit without bound).
        inflightSemaphore.wait()

        // 2. The drawable and the renderPassDescriptor are valid only inside MTKView's draw cycle.
        //    When they cannot be obtained, the inflight slot taken above is returned and this is skipped.
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            inflightSemaphore.signal()
            return false
        }

        // 3. Transfer the CPU pixels into the texture (a synchronous copy into managed storage).
        //    This slot's texture is safe to reuse, because its previous use (slotCount frames ago) has finished
        //    (the invariant is in the comment at the top of this file).
        let region = MTLRegionMake2D(0, 0, width, height)
        let bytesPerRow = width * MemoryLayout<UInt32>.size
        texture.replace(region: region, mipmapLevel: 0, withBytes: slotBuffers[slotIndex], bytesPerRow: bytesPerRow)
        lastSubmittedSlot = slotIndex // for the click-through hitTest (the CPU buffer currently displayed)

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setFragmentTexture(texture, index: 0)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()

        // 4. present(drawable): displayed at the next display refresh (fifo).
        commandBuffer.present(drawable)
        // 5. Release the inflight slot on completion. Only the semaphore is captured, not self or the slot (avoiding a retain cycle).
        commandBuffer.addCompletedHandler { [inflightSemaphore] _ in
            inflightSemaphore.signal()
        }
        commandBuffer.commit()

        updatePerfStats()
        return true
    }

    // Log the FPS every 60 frames (so that sticking at ~60fps can be observed when checking fifo pacing).
    // It prints only while fpsLogEnabled (KNGN_METAL_FPS_LOG=1); the measurement itself always runs.
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

    // The helper methods for manual drawing
    func getWidth() -> Int {
        return width
    }

    func getHeight() -> Int {
        return height
    }

    func getCurrentBuffer() -> UnsafeMutablePointer<UInt32> {
        return slotBuffers[currentSlotIndex]
    }

    // Read the alpha of the most recently displayed frame, for click-through (best-effort).
    // Nothing submitted yet (-1) counts as opaque (255) and does not fall through. Out of range gives 0 (it does).
    func sampleAlpha(x: Int, y: Int) -> UInt8 {
        if x < 0 || y < 0 || x >= width || y >= height { return 0 }
        if lastSubmittedSlot < 0 { return 255 } // Before the first present it counts as opaque (the zeroed buffer is never read)
        let pixel = slotBuffers[lastSubmittedSlot][y * width + x]
        return UInt8((pixel >> 24) & 0xFF)
    }

    // The manual present. It does not touch the drawable but merely starts MTKView's draw cycle.
    // The actual upload, encode and present happen inside draw(in:) → submitFrame().
    func presentManual(view: MTKView) {
        manualPresentPending = true
        view.draw()
    }

    // Reallocate the slot buffers and textures for a new size, in two phases.
    // The unit is framebuffer pixels (physical under .physical; logical == fb under .logical).
    // It is called from setFrameSize (.logical) and applyLatchedMetricsIfNeeded (.physical), and runs
    // serially on the same main thread as present (submitFrame), so there is no concurrency.
    // - The old CPU buffer: submitFrame already copied it synchronously through texture.replace, so the GPU holds no asynchronous reference and freeing it is safe.
    // - The old texture: an inflight command buffer retains it through ARC until completion, so removing it from the array is safe.
    // Returns: true when the size really changed and everything was reallocated (which decides whether the redraw fires).
    @discardableResult
    func resize(width w0: Int, height h0: Int) -> Bool {
        let w = max(1, w0)
        let h = max(1, h0)
        if w == width && h == height { return false } // unchanged
        let newSize = w * h

        // phase 1: allocate the new resources
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
        // When allocating a texture fails, the new CPU buffer is freed and the old state kept (two-phase: swap only once everything is in place)
        if newTextures.contains(where: { $0 == nil }) {
            for buf in newBuffers {
                buf.deinitialize(count: newSize)
                buf.deallocate()
            }
            return false
        }

        // phase 2: free the old CPU buffers and swap (the textures are left to ARC)
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
        lastSubmittedSlot = -1 // A freshly zeroed buffer must not be misread as "displayed", so it counts as opaque until the next submit
        return true
    }
}

#if KNGN_ENABLE_TEXT_INPUT
// NSTextInputClient conformance is declared in an extension rather than in the inheritance
// clause, because the methods that satisfy it are compiled only with the text input opt-in and
// Swift cannot make an inheritance clause conditional.
extension MetalFramebufferView: NSTextInputClient {}
#endif

// A custom MTKView plus NSTextInputClient (the IME)
class MetalFramebufferView: MTKView, PlatformBackendView {
    private var metalRenderer: MetalRenderer?

    // logical and framebuffer sizes kept apart, plus the scale latch (the same shape as objc's Framebuffer)
    private var logicalWidth: Int = 1
    private var logicalHeight: Int = 1
    private var physicalMode: Bool = false
    private var contentScale: CGFloat = 1.0
    private var pendingContentScale: CGFloat = 1.0
    private var scaleEpoch: UInt64 = 0
    private var hasPendingResize = false
    private var pendingLogicalWidth: Int = 1
    private var pendingLogicalHeight: Int = 1

    // For mouse events. Setting the back-reference propagates it to imeState as well.
    weak var platformWindow: PlatformWindowHandle? {
        didSet {
#if KNGN_ENABLE_TEXT_INPUT
            imeState.platformWindow = platformWindow
#endif
        }
    }
    private var customTrackingArea: NSTrackingArea?

#if KNGN_ENABLE_TEXT_INPUT
    // The IME state is gathered into the shared PlatformIMEState; NSTextInputClient and the custom IME methods forward to it.
    let imeState = PlatformIMEState()
#endif

#if KNGN_ENABLE_CURSOR
    // for cursor control
    private var currentCursorShape: PlatformCursorShape = PLATFORM_CURSOR_DEFAULT  // the most recently requested shape
    private var cursorHiddenByThisView: Bool = false  // whether this view owns the [NSCursor hide] (the API is a global reference count, so it must not be called twice)
    private var mouseInsideView: Bool = false         // whether the mouse is inside the view right now (set and hide are held back while it is outside)
#endif

    // Live-resize redraw. A separate field from the FrameCallback used by CADisplayLink.
    private var redrawCallback: PlatformRedrawCallback?
    private var redrawUserdata: UnsafeMutableRawPointer?

#if KNGN_ENABLE_MASCOT
    // Transparent windows, click-through and interactive dragging
    private var transparentMode: Bool = false
    private var clickThrough: Bool = false
    private var clickThroughState: Bool = false // the ignoresMouseEvents value set most recently (only reapplied when it changes)
    private var lastMouseDownEvent: NSEvent?
#endif

    override init(frame: CGRect, device: MTLDevice?) {
        let metalDevice = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: metalDevice)

#if KNGN_ENABLE_TEXT_INPUT
        // Hand the host view to the IME state (the framebuffer size is updated in setupRenderer)
        imeState.hostView = self
#endif

        // The delegate is set later
        // OS file drag and drop (file URLs only, following the objc backend)
        self.registerForDraggedTypes([.fileURL])
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - PlatformBackendView

    var nativeView: NSView { return self }
    var implementationType: String { return IMPLEMENTATION_TYPE }
    var width: Int { return metalRenderer?.getWidth() ?? 0 }
    var height: Int { return metalRenderer?.getHeight() ?? 0 }
    var initialFramebuffer: UnsafeMutablePointer<UInt32>? { return metalRenderer?.getCurrentBuffer() }

    // present: does the existing presentManual(view:) plus refreshClickThrough, and returns the next buffer to write into.
    // The size argument is taken for compatibility but ignored; the renderer's internal size is used.
    func present(framebuffer: UnsafeMutablePointer<UInt32>, width: Int, height: Int) -> UnsafeMutablePointer<UInt32>? {
        guard let renderer = metalRenderer else { return nil }
        // Draw manually
        renderer.presentManual(view: self)
#if KNGN_ENABLE_MASCOT
        // Update the cursor-position test for click-through (returns immediately while clickThrough is off)
        refreshClickThrough()
#endif
        // Return the CPU buffer of the current slot after the present (submit has already advanced it)
        return renderer.getCurrentBuffer()
    }

    func prepareForDestroy() {
        // Detach the delegate (cutting the callback's reference to the view)
        self.delegate = nil
    }

    func startPresentation() {
        // A no-op for Metal, since isPaused and the display-link settings are made in the factory.
        // On the manual present path, present() drives one frame at a time through view.draw().
    }

    // MARK: - NSTextInputClient forwarding (delegated to the shared PlatformIMEState)
#if KNGN_ENABLE_TEXT_INPUT

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
#endif // KNGN_ENABLE_TEXT_INPUT

    override var acceptsFirstResponder: Bool { true }

    // MARK: - NSDraggingDestination / file drop (hot path: event time only)
    // The same contract as the objc backend (platform/macos/platform_macos.m). Filling the struct and
    // validating the length and NULs are platform.h's shared helper platform_fill_file_drop_event (reached through the shared enqueueFileDropIfValid).

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
        // A single file only. A simultaneous multi-file drop rejects the whole event.
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              urls.count == 1 else { return false }
        return enqueueFileDropIfValid(handle: handle, url: urls[0])
    }

    deinit {
#if KNGN_ENABLE_CURSOR
        // Being destroyed while the cursor is hidden would leave the OS cursor gone for good.
        if cursorHiddenByThisView {
            NSCursor.unhide()
            cursorHiddenByThisView = false
        }
#endif
    }

    func setupRenderer(width w: Int, height h: Int, callback: FrameCallback?, userdata: UnsafeMutableRawPointer?, physical: Bool) {
        physicalMode = physical
        logicalWidth = max(1, w)
        logicalHeight = max(1, h)
        pendingLogicalWidth = logicalWidth
        pendingLogicalHeight = logicalHeight
        hasPendingResize = false
        scaleEpoch = 0
        // The initial scale: no window is attached yet, so mainScreen is used. Unavailable or unsupported gives 1.0.
        var scale: CGFloat = 1.0
        if let screen = NSScreen.main {
            let s = screen.backingScaleFactor
            if s > 0 { scale = s }
        }
        contentScale = scale
        pendingContentScale = scale
        let (fw, fh) = effectiveFramebufferSize(
            physicalMode: physical,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            scale: scale
        )

        guard let device = self.device else { return }
        let renderer = MetalRenderer(device: device, width: fw, height: fh, callback: callback, userdata: userdata)
        renderer.metricsOwner = self
        metalRenderer = renderer
        self.delegate = renderer
        // Apply the framebuffer size used to convert the IME firstRect from pixels into bounds
#if KNGN_ENABLE_TEXT_INPUT
        imeState.updateFramebufferSize(width: fw, height: fh)
#endif
        NSLog("[\(IMPLEMENTATION_TYPE)] Framebuffer metrics: logical=\(logicalWidth)x\(logicalHeight) fb=\(fw)x\(fh) scale=\(String(format: "%.2f", Double(scale))) physical=\(physical ? 1 : 0)")
    }

    // The pending record coming from mtkView drawableSizeWillChange (no resource is touched).
    func notePendingDrawableChange(size: CGSize) {
        _ = size
        refreshPendingContentScale()
        // For the size, setFrameSize (in logical points) is the primary source.
        // Here only a missed scale change is caught (applyLatched re-checks on the next lock).
    }

    func refreshPendingContentScale() {
        guard let win = window else { return }
        var live = win.backingScaleFactor
        if live <= 0 { live = 1.0 }
        pendingContentScale = live
    }

    func applyLatchedMetricsIfNeeded() {
        refreshPendingContentScale()

        let newScale = effectiveContentScale(pendingContentScale)
        let scaleChanging = abs(newScale - contentScale) > 1e-6

        if !physicalMode {
            if scaleChanging {
                contentScale = newScale
                scaleEpoch &+= 1
            }
            return
        }

        guard let renderer = metalRenderer else { return }

        var lw = hasPendingResize ? pendingLogicalWidth : logicalWidth
        var lh = hasPendingResize ? pendingLogicalHeight : logicalHeight
        if lw < 1 { lw = 1 }
        if lh < 1 { lh = 1 }
        let fw = roundToPhysicalPx(lw, scale: newScale)
        let fh = roundToPhysicalPx(lh, scale: newScale)

        let sizeChanging = (fw != renderer.getWidth() || fh != renderer.getHeight() || lw != logicalWidth || lh != logicalHeight)
        if !sizeChanging && !scaleChanging {
            hasPendingResize = false
            return
        }

        if sizeChanging {
            if !renderer.resize(width: fw, height: fh) {
                // OOM or a failed texture: the old state is kept. The pending value stays for the next lock to retry.
                return
            }
            platformWindow?.currentFramebuffer = renderer.getCurrentBuffer()
#if KNGN_ENABLE_TEXT_INPUT
            imeState.updateFramebufferSize(width: renderer.getWidth(), height: renderer.getHeight())
#endif
        }
        logicalWidth = lw
        logicalHeight = lh
        if scaleChanging { scaleEpoch &+= 1 }
        contentScale = newScale
        hasPendingResize = false
    }

    func fillMetrics(_ out: UnsafeMutablePointer<PlatformFramebufferMetrics>, forQuery: Bool) {
        if forQuery { refreshPendingContentScale() }
        let fw = metalRenderer?.getWidth() ?? 0
        let fh = metalRenderer?.getHeight() ?? 0
        out.pointee.logical_width = UInt32(logicalWidth)
        out.pointee.logical_height = UInt32(logicalHeight)
        out.pointee.framebuffer_width = UInt32(fw)
        out.pointee.framebuffer_height = UInt32(fh)
        let scale = forQuery ? pendingContentScale : contentScale
        out.pointee.content_scale = Float(effectiveContentScale(scale))
        out.pointee.scale_epoch = scaleEpoch
    }

    func nativeEventScale() -> CGFloat {
        refreshPendingContentScale()
        return effectiveContentScale(pendingContentScale)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        var s: CGFloat = 1.0
        if let win = window {
            s = win.backingScaleFactor
            if s <= 0 { s = 1.0 }
        }
        if abs(s - pendingContentScale) > 1e-6 {
            pendingContentScale = s
            if physicalMode, let cb = redrawCallback {
                cb(redrawUserdata)
            }
        }
    }

    // Called by NSView on a resize. .physical only records the pending value, .logical resizes at once (the same shape as objc).
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if physicalMode {
            var nw = Int(newSize.width)
            var nh = Int(newSize.height)
            if nw < 1 { nw = 1 }
            if nh < 1 { nh = 1 }
            if nw != logicalWidth || nh != logicalHeight {
                pendingLogicalWidth = nw
                pendingLogicalHeight = nh
                hasPendingResize = true
                if let cb = redrawCallback {
                    cb(redrawUserdata)
                }
            }
            return
        }
        guard let renderer = metalRenderer else { return }
        if renderer.resize(width: Int(newSize.width), height: Int(newSize.height)) {
            logicalWidth = renderer.getWidth()
            logicalHeight = renderer.getHeight()
            platformWindow?.currentFramebuffer = renderer.getCurrentBuffer()
#if KNGN_ENABLE_TEXT_INPUT
            imeState.updateFramebufferSize(width: renderer.getWidth(), height: renderer.getHeight())
#endif
            if let cb = redrawCallback {
                cb(redrawUserdata)
            }
        }
    }

    // Register the live-resize redraw callback. cb==nil unregisters.
    func setRedrawCallback(_ cb: PlatformRedrawCallback?, userdata: UnsafeMutableRawPointer?) {
        redrawCallback = cb
        redrawUserdata = userdata
    }

    // ========================================
    // Mouse events
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
        // .cursorUpdate: have cursorUpdate(with:) called when the mouse re-enters, so the cursor recovers
        // even after the OS resets it on a window switch.
        // .mouseEnteredAndExited: track entering and leaving the view, releasing ownership of hidden (exited)
        // and applying the shape (entered). Hiding and unhiding happen only while inside the view.
        let opts: NSTrackingArea.Options = [.mouseMoved, .cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        let ta = NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil)
        self.addTrackingArea(ta)
        customTrackingArea = ta
    }

    // ========================================
    // Cursor control (KNGN_ENABLE_CURSOR)
    // ========================================
    //
    // The policy: NSCursor.hide/unhide is a process-wide reference-counted API, so cursorHiddenByThisView
    // tracks strictly whether this view currently owns the hide (hide only on a false→true transition,
    // unhide only on true→false). On top of that, set and hide are really applied only while
    // mouseInsideView is true; a setCursor arriving while the mouse is outside merely stores the shape.

#if KNGN_ENABLE_CURSOR
    // Return the NSCursor matching currentCursorShape (PLATFORM_CURSOR_HIDDEN is not handled here).
    // An unsupported shape falls back to the arrow.
    private func nsCursor(for shape: PlatformCursorShape) -> NSCursor {
        switch shape {
        case PLATFORM_CURSOR_CROSSHAIR: return .crosshair
        default: return .arrow // PLATFORM_CURSOR_DEFAULT, and the fallback for an unsupported shape
        }
    }

    // Really apply currentCursorShape, assuming mouseInsideView (including the transfer of hide ownership).
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

    // Called from platform_set_cursor. Stores the shape and applies it at once while inside the view.
    func setCursorShape(_ shape: PlatformCursorShape) {
        currentCursorShape = shape
        applyCursorShapeIfInside()
    }

    // The mouse re-entered the view. Apply the current shape.
    override func mouseEntered(with event: NSEvent) {
        mouseInsideView = true
        applyCursorShapeIfInside()
    }

    // The mouse left the view. Whenever this view owns the hide, it must release it
    // (otherwise the OS cursor stays gone while outside the view).
    override func mouseExited(with event: NSEvent) {
        mouseInsideView = false
        if cursorHiddenByThisView {
            NSCursor.unhide()
            cursorHiddenByThisView = false
        }
    }

    // Called by AppKit when the tracking area is re-entered. The cursor recovers even after the OS reset it on an application switch.
    override func cursorUpdate(with event: NSEvent) {
        // cursorUpdate is only called inside the tracking rect (.cursorUpdate), so this counts as being inside the view.
        // That applies the shape even when mouseEntered did not fire, when the order differs, or when recovering from a cursor reset after a window switch.
        mouseInsideView = true
        applyCursorShapeIfInside()
    }
#endif // KNGN_ENABLE_CURSOR

    private func enqueueMouseEvent(type: PlatformEventType, button: PlatformMouseButton, from event: NSEvent) {
        guard let handle = platformWindow else { return }
        let (x, y) = eventLocationToPlatformCoords(event, self, scale: nativeEventScale())
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
        let scale = nativeEventScale()
        let (x, y) = eventLocationToPlatformCoords(event, self, scale: scale)
        let isPrecise = event.hasPreciseScrollingDeltas
        var dx = Float(event.scrollingDeltaX)
        var dy = Float(event.scrollingDeltaY)
        if !isPrecise {
            dx *= SCROLL_LINE_TO_POINTS
            dy *= SCROLL_LINE_TO_POINTS
        }
        // raw physical units (the facade turns them into logical ones with the latched scale)
        dx *= Float(scale)
        dy *= Float(scale)
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

    // Transparent mode (isOpaque), click-through (a per-pixel hitTest), and the event kept for beginDrag.
    override var isOpaque: Bool {
#if KNGN_ENABLE_MASCOT
        return !transparentMode
#else
        return true // without the mascot opt-in a window is always opaque
#endif
    }
#if KNGN_ENABLE_MASCOT
    // Per-pixel click-through. On every present the alpha under the current cursor position toggles
    // `window.ignoresMouseEvents` (NSView.hitTest alone would not let it through to an application behind).
    // The alpha is read from the renderer's most recently displayed slot. Hot path declaration: once per present, but only one pixel sample.
    func refreshClickThrough() {
        guard clickThrough, let win = window, let r = metalRenderer else { return }
        let screenPt = NSEvent.mouseLocation
        let winPt = win.convertPoint(fromScreen: screenPt)
        let local = convert(winPt, from: nil) // window → view (not flipped: the origin is bottom-left)
        let b = bounds
        let w = r.getWidth()
        let h = r.getHeight()
        var passThrough = true // let it fall through when the cursor is outside the window or unknown
        if b.width > 0 && b.height > 0 &&
           local.x >= 0 && local.x < b.width && local.y >= 0 && local.y < b.height {
            var px = Int(local.x / b.width * CGFloat(w))
            var py = Int((1.0 - local.y / b.height) * CGFloat(h)) // to a top-left origin
            if px >= w { px = w - 1 } // clamp what rounding at the right and bottom edges would push out (it would drop the last row)
            if py >= h { py = h - 1 }
            if px < 0 { px = 0 }
            if py < 0 { py = 0 }
            passThrough = (r.sampleAlpha(x: px, y: py) == 0)
        }
        if passThrough != clickThroughState { // only write the WindowServer state when the value has changed
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
            window?.ignoresMouseEvents = false // go back to receiving events when it is turned off
            clickThroughState = false
        }
    }
    func takeLastMouseDownEvent() -> NSEvent? {
        let ev = lastMouseDownEvent
        lastMouseDownEvent = nil
        return ev
    }
#endif // KNGN_ENABLE_MASCOT

    override func mouseDown(with event: NSEvent) {
#if KNGN_ENABLE_MASCOT
        lastMouseDownEvent = event // kept for beginDrag
#endif
        enqueueMouseEvent(type: PLATFORM_EVENT_MOUSE_DOWN, button: buttonFromEvent(event), from: event)
    }
    override func mouseUp(with event: NSEvent) {
#if KNGN_ENABLE_MASCOT
        lastMouseDownEvent = nil // discard the stale event on up
#endif
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
// The backend factory
// ========================================
// Called from the shared createWindowImpl, it creates the view of the Metal backend. Creating the
// Metal device, framebufferOnly/enableSetNeedsDisplay, the transparent clearColor, isPaused,
// displaySyncEnabled and the renderer setup all happen here (the frame pacing contract is unchanged).
func makePlatformBackendView(
    frame: NSRect,
    width: Int,
    height: Int,
    callback: FrameCallback?,
    userdata: UnsafeMutableRawPointer?,
    transparent: Bool,
    physical: Bool
) -> (any PlatformBackendView)? {
    // Create the view for Metal
    guard let metalDevice = MTLCreateSystemDefaultDevice() else {
        NSLog("[\(IMPLEMENTATION_TYPE)] Failed to create Metal device")
        return nil
    }

    let metalView = MetalFramebufferView(frame: frame, device: metalDevice)
    metalView.framebufferOnly = false
    metalView.enableSetNeedsDisplay = false
#if KNGN_ENABLE_MASCOT
    // Metal transparency (the drawable's alpha is kept and CAMetalLayer composites what is behind)
    if transparent {
        metalView.setTransparentMode(true) // the isOpaque override returns false
        metalView.layer?.isOpaque = false
        metalView.clearColor = MTLClearColorMake(0, 0, 0, 0) // a transparent clear
    }
#else
    _ = transparent // no window can be transparent without the mascot opt-in
#endif
    // On the manual drawing path (callback=nil, the Zig facade's lockFramebuffer→present path) the
    // display link is stopped and present() drives one frame at a time through view.draw(). The callback
    // path (symmetrical with objc and swift, and unused) keeps isPaused=false and is display-link driven.
    metalView.isPaused = (callback == nil)
    // This states the intent of fifo (synchronised to display refresh) in the code. On macOS CAMetalLayer
    // defaults to true, so it changes no behaviour, but it makes the first-class backend contract of ADR-005 explicit.
    (metalView.layer as? CAMetalLayer)?.displaySyncEnabled = true

    // Set up the renderer (under .physical the CPU buffer and the texture are allocated at the physical size)
    metalView.setupRenderer(width: width, height: height, callback: callback, userdata: userdata, physical: physical)

    return metalView
}
