import Cocoa
import QuartzCore

// The CALayer-optimised backend, in Swift (the shared code lives in platform_macos_shared.swift)
// The type definitions (PlatformEvent, PlatformEventType, PlatformKeyCode, the PLATFORM_* constants,
//        the FrameCallback typealias and so on) come from the C header automatically, through the
//        bridging header (-import-objc-header platform/platform.h).
//
// This file holds only the FramebufferView that conforms to PlatformBackendView (CALayer plus a
// no-copy CGDataProvider plus a double buffer plus CADisplayLink) and the makePlatformBackendView()
// factory. The C ABI, the event queue, the IME state and the window creation skeleton are in platform_macos_shared.swift.
let IMPLEMENTATION_TYPE = "CALayer Optimized (Swift)"

// A custom NSView: fast CALayer-based drawing plus NSTextInputClient (the IME)
class FramebufferView: NSView, NSTextInputClient, PlatformBackendView {
    var width: Int   // the framebuffer pixel width (equal to the logical one under .logical)
    var height: Int  // framebuffer pixel height
    private var logicalWidth: Int
    private var logicalHeight: Int
    private let physicalMode: Bool
    private var contentScale: CGFloat        // latched (committed by lock)
    private var pendingContentScale: CGFloat // the detected current negotiated scale
    private var scaleEpoch: UInt64 = 0
    private var hasPendingResize = false
    private var pendingLogicalWidth: Int
    private var pendingLogicalHeight: Int
    private var displayLink: CADisplayLink?
    private var callback: FrameCallback?
    private var userdata: UnsafeMutableRawPointer?

    // Double buffering (by swapping pointers)
    private var buffer0: UnsafeMutablePointer<UInt32>
    private var buffer1: UnsafeMutablePointer<UInt32>
    private var currentBuffer: UnsafeMutablePointer<UInt32>  // the buffer the callback writes into
    private var displayBuffer: UnsafeMutablePointer<UInt32>  // the buffer currently on screen

    // the layer
    private var contentLayer: CALayer

    // the CG objects (created at initialisation and reused)
    private var colorSpace: CGColorSpace
    // The no-copy providers (referring straight into buffer0/1). They have to be released before the
    // buffers are, so their lifetime is managed explicitly through an optional.
    private var provider0: CGDataProvider?
    private var provider1: CGDataProvider?

    // performance measurement
    private var lastFrameTime: CFAbsoluteTime
    private var frameCount: Int
    private var totalFrameTime: Double

    // For mouse events. Setting the back-reference propagates it to imeState as well.
    weak var platformWindow: PlatformWindowHandle? {
        didSet { imeState.platformWindow = platformWindow }
    }
    private var trackingArea: NSTrackingArea?

    // The IME state is gathered into the shared PlatformIMEState; NSTextInputClient and the custom IME methods forward to it.
    let imeState = PlatformIMEState()

    // for cursor control
    private var currentCursorShape: PlatformCursorShape = PLATFORM_CURSOR_DEFAULT  // the most recently requested shape
    private var cursorHiddenByThisView: Bool = false  // whether this view owns the [NSCursor hide] (the API is a global reference count, so it must not be called twice)
    private var mouseInsideView: Bool = false         // whether the mouse is inside the view right now (set and hide are held back while it is outside)

    // Live-resize redraw. A separate field from the FrameCallback used by CADisplayLink.
    private var redrawCallback: PlatformRedrawCallback?
    private var redrawUserdata: UnsafeMutableRawPointer?

    // Transparent windows, click-through and interactive dragging
    private var transparentMode: Bool = false  // true makes the CGImage premultiplied alpha and honours the framebuffer alpha
    private var clickThrough: Bool = false     // true lets a click over a transparent pixel fall through to what is behind (per pixel)
    private var clickThroughState: Bool = false // the ignoresMouseEvents value set most recently (only reapplied when it changes)
    private var lastMouseDownEvent: NSEvent?    // the most recent left-button mouse-down (for beginDrag; consumed one-shot)

    init(frame: NSRect, width w: Int, height h: Int, callback: FrameCallback?, userdata: UnsafeMutableRawPointer?, physical: Bool) {
        self.physicalMode = physical
        self.logicalWidth = max(1, w)
        self.logicalHeight = max(1, h)
        self.pendingLogicalWidth = self.logicalWidth
        self.pendingLogicalHeight = self.logicalHeight
        // The initial scale: no window is attached yet, so mainScreen is used. Unavailable or unsupported gives 1.0.
        var scale: CGFloat = 1.0
        if let screen = NSScreen.main {
            let s = screen.backingScaleFactor
            if s > 0 { scale = s }
        }
        self.contentScale = scale
        self.pendingContentScale = scale
        let (fw, fh) = effectiveFramebufferSize(
            physicalMode: physical,
            logicalWidth: self.logicalWidth,
            logicalHeight: self.logicalHeight,
            scale: scale
        )
        self.width = fw
        self.height = fh
        self.callback = callback
        self.userdata = userdata

        // Allocate the double buffer (calloc zero-fills, and gives nil on OOM; the same shape as the objc version)
        let bufferSize = fw * fh
        guard let raw0 = calloc(bufferSize, MemoryLayout<UInt32>.size),
              let raw1 = calloc(bufferSize, MemoryLayout<UInt32>.size) else {
            fatalError("FramebufferView: OOM allocating framebuffers")
        }
        self.buffer0 = raw0.assumingMemoryBound(to: UInt32.self)
        self.buffer1 = raw1.assumingMemoryBound(to: UInt32.self)

        self.currentBuffer = self.buffer0
        self.displayBuffer = self.buffer1

        // Create the CG objects
        // DeviceRGB provokes a ColorSync conversion every frame on a wide-gamut display and costs a great
        // deal of frame rate (most visibly under .physical, where it was measured).
        // Matching the screen's actual colour space avoids that conversion (as in objc's platform_macos.m).
        let screenCS = NSScreen.main?.colorSpace
        self.colorSpace = screenCS?.cgColorSpace ?? CGColorSpaceCreateDeviceRGB()

        // The no-copy providers (the same shape as objc's CGDataProviderCreateWithData).
        // The buffers belong to the view, so releaseData is a no-op.
        guard let p0 = Self.makeNoCopyProvider(buffer: self.buffer0, count: bufferSize),
              let p1 = Self.makeNoCopyProvider(buffer: self.buffer1, count: bufferSize) else {
            free(raw0)
            free(raw1)
            fatalError("FramebufferView: failed to create CGDataProvider")
        }
        self.provider0 = p0
        self.provider1 = p1

        // the layer
        self.contentLayer = CALayer()

        // Initialise the performance measurement
        self.lastFrameTime = CFAbsoluteTimeGetCurrent()
        self.frameCount = 0
        self.totalFrameTime = 0.0

        super.init(frame: frame)

        // Hand the host view and the framebuffer size to the IME state (firstRect converts with them)
        imeState.hostView = self
        imeState.updateFramebufferSize(width: fw, height: fh)

        // Make it a layer-backed view
        self.wantsLayer = true

        // Create the content layer (its frame is always in logical points)
        self.contentLayer.frame = CGRect(x: 0, y: 0, width: CGFloat(self.logicalWidth), height: CGFloat(self.logicalHeight))
        self.contentLayer.isOpaque = true
        self.contentLayer.isGeometryFlipped = true  // Flip the Y axis, once
        self.contentLayer.magnificationFilter = .nearest
        self.contentLayer.minificationFilter = .nearest
        if physical {
            self.contentLayer.contentsScale = scale
        }
        self.layer?.addSublayer(self.contentLayer)

        // OS file drag and drop (file URLs only, following the objc backend)
        self.registerForDraggedTypes([.fileURL])

        NSLog("[\(IMPLEMENTATION_TYPE)] Framebuffer initialized: logical=\(self.logicalWidth)x\(self.logicalHeight) fb=\(fw)x\(fh) scale=\(String(format: "%.2f", Double(scale))) physical=\(physical ? 1 : 0)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - PlatformBackendView

    var nativeView: NSView { return self }
    var implementationType: String { return IMPLEMENTATION_TYPE }
    var initialFramebuffer: UnsafeMutablePointer<UInt32>? { return currentBuffer }

    // present: the same swap and layer update as presentManual, returning the next buffer to write into.
    // The size argument is taken for compatibility but ignored; the internal size is used.
    func present(framebuffer: UnsafeMutablePointer<UInt32>, width: Int, height: Int) -> UnsafeMutablePointer<UInt32>? {
        presentManual()
        return currentBuffer
    }

    func prepareForDestroy() {
        stopDisplayLink()
    }

    func startPresentation() {
        startDisplayLink()
    }

    // MARK: - NSTextInputClient forwarding (delegated to the shared PlatformIMEState)

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

    // MARK: - NSDraggingDestination / file drop (hot path: event time only)
    // The same contract as the objc backend (platform/macos/platform_macos.m): a single file URL, UTF-8,
    // with empty, over-limit (PLATFORM_FILE_DROP_PATH_BYTES) or NUL-containing paths rejected. Filling the struct is the shared helper's job.

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

    // MARK: - CADisplayLink and drawing

    func startDisplayLink() {
        if #available(macOS 13.0, *) {
            // Get the displayLink from the screen of the window holding the view
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

    /// Make a no-copy CGDataProvider that refers straight into buffer (nothing is copied).
    /// nil on failure (no force unwrap; this is the recoverable path of resizeBuffers).
    /// Every reference to the provider (layer.contents included) must be cut before the buffer is freed.
    private static func makeNoCopyProvider(buffer: UnsafeMutablePointer<UInt32>, count: Int) -> CGDataProvider? {
        return CGDataProvider(
            dataInfo: nil,
            data: UnsafeRawPointer(buffer),
            size: count * MemoryLayout<UInt32>.size,
            releaseData: { _, _, _ in } // the buffer belongs to the view (a no-op)
        )
    }

    /// Make a CGImage from the no-copy provider of the buffer being displayed (no pixels are copied).
    /// It is called every frame, but all it creates is a reference object.
    private func makeDisplayImage() -> CGImage? {
        guard let provider = (displayBuffer == buffer0) ? provider0 : provider1 else { return nil }
        // In transparent mode, premultiplied alpha honours the framebuffer alpha; by default alpha is skipped, as before.
        let alphaInfo = transparentMode ? CGImageAlphaInfo.premultipliedFirst.rawValue
                                        : CGImageAlphaInfo.noneSkipFirst.rawValue
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: alphaInfo | CGBitmapInfo.byteOrder32Little.rawValue), // canonical BGRA: memory [B,G,R,A] = u32 0xAARRGGBB
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    @objc
    func displayLinkFired(_ link: CADisplayLink) {
        let frameStartTime = CFAbsoluteTimeGetCurrent()

        // Call the user's callback to produce the pixel data
        if let callback = callback {
            let callbackStart = CFAbsoluteTimeGetCurrent()
            callback(currentBuffer, Int32(width), Int32(height), userdata)
            let callbackEnd = CFAbsoluteTimeGetCurrent()

            // Swap the buffers (zero copy)
            let temp = currentBuffer
            currentBuffer = displayBuffer
            displayBuffer = temp

            // Make the CGImage from the displayed buffer's no-copy provider (nothing is copied)
            let renderStart = CFAbsoluteTimeGetCurrent()
            if let cgImage = makeDisplayImage() {
                contentLayer.contents = cgImage
            }

            // Update click-through on the callback and display-link path too (returns immediately while disabled)
            refreshClickThrough()

            let renderEnd = CFAbsoluteTimeGetCurrent()

            // performance measurement
            frameCount += 1
            let frameTime = frameStartTime - lastFrameTime
            totalFrameTime += frameTime
            lastFrameTime = frameStartTime

            // Print the statistics every 60 frames
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

    func presentManual() {
        // Swap the buffers (zero copy)
        let temp = currentBuffer
        currentBuffer = displayBuffer
        displayBuffer = temp

        // Make the CGImage from the displayed buffer's no-copy provider (nothing is copied)
        if let cgImage = makeDisplayImage() {
            contentLayer.contents = cgImage
        }

        // Update the cursor-position test for click-through (returns immediately while clickThrough is off)
        refreshClickThrough()
    }

    override var isOpaque: Bool {
        return !transparentMode // transparent mode is not opaque
    }

    // Per-pixel click-through. Returning nil from NSView.hitTest does not let it through to an application behind
    // (that is the window-level ignoresMouseEvents). On every present the alpha under the current cursor position
    // toggles `window.ignoresMouseEvents` (over a transparent pixel it falls through, over the artwork the window gets it).
    // Hot path declaration: once per present, but only one pixel sample and a property write (no per-pixel loop).
    func refreshClickThrough() {
        if !clickThrough { return }
        guard let win = window else { return }
        let screenPt = NSEvent.mouseLocation
        let winPt = win.convertPoint(fromScreen: screenPt)
        let local = convert(winPt, from: nil) // window → view (not flipped: the origin is bottom-left)
        let b = bounds
        var passThrough = true // let it fall through when the cursor is outside the window or unknown
        if b.width > 0 && b.height > 0 &&
           local.x >= 0 && local.x < b.width && local.y >= 0 && local.y < b.height {
            var px = Int(local.x / b.width * CGFloat(width))
            var py = Int((1.0 - local.y / b.height) * CGFloat(height)) // to a top-left origin
            if px >= width { px = width - 1 } // clamp what rounding at the right and bottom edges would push out (it would drop the last row)
            if py >= height { py = height - 1 }
            if px < 0 { px = 0 }
            if py < 0 { py = 0 }
            let alpha = UInt8((displayBuffer[py * width + px] >> 24) & 0xFF)
            passThrough = (alpha == 0)
        }
        if passThrough != clickThroughState { // only write the WindowServer state when the value has changed
            win.ignoresMouseEvents = passThrough
            clickThroughState = passThrough
        }
    }

    // Configure transparency and click-through, and consume the event kept for beginDrag (one-shot).
    func setTransparentMode(_ on: Bool) {
        transparentMode = on
        contentLayer.isOpaque = !on
        needsDisplay = true
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
        lastMouseDownEvent = nil // consumed as it is taken (never reused, in case the mouse-up never arrives)
        return ev
    }

    // ========================================
    // Mouse events
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
        // .cursorUpdate: have cursorUpdate(with:) called when the mouse re-enters, so the cursor recovers
        // even after the OS resets it on a window switch.
        // .mouseEnteredAndExited: track entering and leaving the view, releasing ownership of hidden (exited)
        // and applying the shape (entered). Hiding and unhiding happen only while inside the view.
        let opts: NSTrackingArea.Options = [.mouseMoved, .cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        let ta = NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil)
        self.addTrackingArea(ta)
        trackingArea = ta
    }

    // ========================================
    // Cursor control
    // ========================================
    //
    // The policy: NSCursor.hide/unhide is a process-wide reference-counted API, so cursorHiddenByThisView
    // tracks strictly whether this view currently owns the hide (hide only on a false→true transition,
    // unhide only on true→false). On top of that, set and hide are really applied only while
    // mouseInsideView is true; a setCursor arriving while the mouse is outside merely stores the shape.

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

    override func mouseDown(with event: NSEvent) {
        lastMouseDownEvent = event // keep the most recent left down for beginDrag
        enqueueMouseEvent(type: PLATFORM_EVENT_MOUSE_DOWN, button: buttonFromEvent(event), from: event)
    }
    override func mouseUp(with event: NSEvent) {
        lastMouseDownEvent = nil // discard the stale event on up
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

    // Reallocate the buffers for a new size, in two phases.
    // The unit is framebuffer pixels (physical under .physical; logical == fb under .logical).
    // Because a provider refers to a buffer **without copying**, the order before freeing the old buffer
    // must be: cut the layer.contents reference, then release the old provider (as in the objc version).
    // It is never called while locked (it fires during the event pump, or from applyLatched).
    // Returns: true when the size really changed and the buffers were reallocated. No change, OOM or a
    // failed provider gives false (the old size is kept, the redraw callback does not fire, and no allocate trap is used).
    @discardableResult
    func resizeBuffersTo(width w0: Int, height h0: Int) -> Bool {
        let w = max(1, w0)
        let h = max(1, h0)
        if w == width && h == height { return false } // unchanged
        let newSize = w * h

        // phase 1: allocate the new buffers and new no-copy providers (the old resources are untouched until this succeeds)
        guard let raw0 = calloc(newSize, MemoryLayout<UInt32>.size) else { return false }
        guard let raw1 = calloc(newSize, MemoryLayout<UInt32>.size) else {
            free(raw0)
            return false
        }
        let nb0 = raw0.assumingMemoryBound(to: UInt32.self)
        let nb1 = raw1.assumingMemoryBound(to: UInt32.self)

        guard let np0 = Self.makeNoCopyProvider(buffer: nb0, count: newSize) else {
            free(raw0)
            free(raw1)
            return false
        }
        guard let np1 = Self.makeNoCopyProvider(buffer: nb1, count: newSize) else {
            free(raw0)
            free(raw1)
            return false // np0 is released by local ARC
        }

        // phase 2: cut every reference to the old buffer first (contents, then provider)
        contentLayer.contents = nil
        provider0 = nil
        provider1 = nil
        // phase 3: destroy the old buffers and swap them in (calloc owns them, so free)
        free(UnsafeMutableRawPointer(buffer0))
        free(UnsafeMutableRawPointer(buffer1))
        buffer0 = nb0
        buffer1 = nb1
        provider0 = np0
        provider1 = np1
        currentBuffer = buffer0
        displayBuffer = buffer1
        width = w
        height = h
        if !physicalMode {
            // .logical: framebuffer == logical, and the layer frame has the same size (as before).
            logicalWidth = w
            logicalHeight = h
            contentLayer.frame = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        }
        return true
    }

    // Latch the pending logical size and scale at the lock boundary (the same shape as objc).
    func refreshPendingContentScale() {
        guard let win = window else { return }
        var live = win.backingScaleFactor
        if live <= 0 { live = 1.0 }
        pendingContentScale = live
    }

    func applyLatchedMetricsIfNeeded() {
        // Re-read the live backingScaleFactor at lock time (in case a notification was missed)
        refreshPendingContentScale()

        let newScale = effectiveContentScale(pendingContentScale)
        let scaleChanging = abs(newScale - contentScale) > 1e-6

        if !physicalMode {
            // .logical: the buffer size is left alone. Only when the scale changes are the epoch and the latched scale committed atomically.
            if scaleChanging {
                contentScale = newScale
                scaleEpoch &+= 1
            }
            return
        }

        var lw = hasPendingResize ? pendingLogicalWidth : logicalWidth
        var lh = hasPendingResize ? pendingLogicalHeight : logicalHeight
        if lw < 1 { lw = 1 }
        if lh < 1 { lh = 1 }
        let fw = roundToPhysicalPx(lw, scale: newScale)
        let fh = roundToPhysicalPx(lh, scale: newScale)

        let sizeChanging = (fw != width || fh != height || lw != logicalWidth || lh != logicalHeight)
        if !sizeChanging && !scaleChanging {
            hasPendingResize = false
            return
        }

        if sizeChanging {
            if !resizeBuffersTo(width: fw, height: fh) {
                // out of memory: keep the old buffer, the old latched scale and the old epoch (the pending value stays for the next lock to retry)
                return
            }
            platformWindow?.currentFramebuffer = currentBuffer
            imeState.updateFramebufferSize(width: width, height: height)
        }
        // only on success are the logical size, the latched scale and the epoch committed together
        logicalWidth = lw
        logicalHeight = lh
        if scaleChanging { scaleEpoch &+= 1 }
        contentScale = newScale
        hasPendingResize = false
        contentLayer.frame = CGRect(x: 0, y: 0, width: CGFloat(logicalWidth), height: CGFloat(logicalHeight))
        contentLayer.contentsScale = contentScale
    }

    func fillMetrics(_ out: UnsafeMutablePointer<PlatformFramebufferMetrics>, forQuery: Bool) {
        if forQuery { refreshPendingContentScale() }
        out.pointee.logical_width = UInt32(logicalWidth)
        out.pointee.logical_height = UInt32(logicalHeight)
        out.pointee.framebuffer_width = UInt32(width)
        out.pointee.framebuffer_height = UInt32(height)
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
        // Only the pending value is updated. The epoch, the latched scale and the buffer are committed atomically on the next successful lock.
        if abs(s - pendingContentScale) > 1e-6 {
            pendingContentScale = s
            if physicalMode, let cb = redrawCallback {
                cb(redrawUserdata)
            }
        }
    }

    // Called by NSView on a resize. Reallocates the framebuffer for the new logical size.
    // .physical only records the pending value and commits it on the next lock (the same shape as objc).
    // .logical resizes at once, and the redraw callback fires only on success.
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
                // the buffer is applied on the next lock; the redraw prompts the application to lock
                if let cb = redrawCallback {
                    cb(redrawUserdata)
                }
            }
            return
        }
        if resizeBuffersTo(width: Int(newSize.width), height: Int(newSize.height)) {
            // Point the handle at the new write buffer after reallocation (so the next lock and present use the right one).
            platformWindow?.currentFramebuffer = currentBuffer
            imeState.updateFramebufferSize(width: width, height: height)
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

    deinit {
        stopDisplayLink()

        // Being destroyed while the cursor is hidden would leave the OS cursor gone for good.
        if cursorHiddenByThisView {
            NSCursor.unhide()
            cursorHiddenByThisView = false
        }

        // Since a no-copy provider refers to the buffer, the release order is
        // contents → provider → buffer (which prevents a stored property being released automatically
        // after the buffer has gone, and using freed memory)
        contentLayer.contents = nil
        provider0 = nil
        provider1 = nil
        free(UnsafeMutableRawPointer(buffer0))
        free(UnsafeMutableRawPointer(buffer1))
    }
}

// ========================================
// The backend factory
// ========================================
// Called from the shared createWindowImpl, it creates the view of the CALayer backend. View-level
// settings such as transparent mode are made here (window-level transparency is on the shared side).
func makePlatformBackendView(
    frame: NSRect,
    width: Int,
    height: Int,
    callback: FrameCallback?,
    userdata: UnsafeMutableRawPointer?,
    transparent: Bool,
    physical: Bool
) -> (any PlatformBackendView)? {
    let view = FramebufferView(
        frame: frame,
        width: width,
        height: height,
        callback: callback,
        userdata: userdata,
        physical: physical
    )
    if transparent {
        view.setTransparentMode(true) // Make the CGImage premultiplied alpha
    }
    return view
}
