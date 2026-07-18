import Cocoa
import QuartzCore

// CALayer最適化版の backend 実装（Swift。TASK-140 で共有コードを platform_macos_shared.swift へ分離）
// 型定義 (PlatformEvent, PlatformEventType, PlatformKeyCode, PLATFORM_* 定数,
//        FrameCallback typealias など) は bridging header (-import-objc-header
//        platform/platform.h) 経由で C ヘッダから自動取得する。
//
// 本ファイルは PlatformBackendView に適合する FramebufferView（CALayer + no-copy CGDataProvider +
// double buffer + CADisplayLink）と makePlatformBackendView() ファクトリのみを持つ。C ABI・
// イベントキュー・IME 状態・ウィンドウ生成骨格は platform_macos_shared.swift 側。
let IMPLEMENTATION_TYPE = "CALayer Optimized (Swift)"

// カスタムNSView - CALayerベースの高速描画 + NSTextInputClient（TASK-79.6.1 IME）
class FramebufferView: NSView, NSTextInputClient, PlatformBackendView {
    var width: Int
    var height: Int
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
    // no-copy provider（buffer0/1 を直接参照。TASK-55）。resize/deinit で buffer より先に
    // 解放する必要があるため optional で寿命を明示管理する。
    private var provider0: CGDataProvider?
    private var provider1: CGDataProvider?

    // パフォーマンス測定
    private var lastFrameTime: CFAbsoluteTime
    private var frameCount: Int
    private var totalFrameTime: Double

    // マウスイベント用 (TASK-21.1)。back-ref 設定時に imeState へも伝播する。
    weak var platformWindow: PlatformWindowHandle? {
        didSet { imeState.platformWindow = platformWindow }
    }
    private var trackingArea: NSTrackingArea?

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
    private var transparentMode: Bool = false  // true で CGImage を premultiplied alpha 化し fb の alpha を honor
    private var clickThrough: Bool = false     // true で透明画素上のクリックを背後へ抜けさせる（per-pixel）
    private var clickThroughState: Bool = false // 直近設定した ignoresMouseEvents 値（変化時のみ再設定）
    private var lastMouseDownEvent: NSEvent?    // 直近の左ボタン mouse-down（beginDrag 用。one-shot 消費）

    init(frame: NSRect, width: Int, height: Int, callback: FrameCallback?, userdata: UnsafeMutableRawPointer?) {
        self.width = width
        self.height = height
        self.callback = callback
        self.userdata = userdata

        // ダブルバッファを確保（calloc = ゼロ初期化 + OOM は nil。objc 版と同型）
        let bufferSize = width * height
        guard let raw0 = calloc(bufferSize, MemoryLayout<UInt32>.size),
              let raw1 = calloc(bufferSize, MemoryLayout<UInt32>.size) else {
            fatalError("FramebufferView: OOM allocating framebuffers")
        }
        self.buffer0 = raw0.assumingMemoryBound(to: UInt32.self)
        self.buffer1 = raw1.assumingMemoryBound(to: UInt32.self)

        self.currentBuffer = self.buffer0
        self.displayBuffer = self.buffer1

        // CGオブジェクトを初期化
        self.colorSpace = CGColorSpaceCreateDeviceRGB()

        // no-copy provider（objc 版 CGDataProviderCreateWithData と同型。TASK-55）。
        // バッファは view が所有するため releaseData は no-op。
        guard let p0 = Self.makeNoCopyProvider(buffer: self.buffer0, count: bufferSize),
              let p1 = Self.makeNoCopyProvider(buffer: self.buffer1, count: bufferSize) else {
            free(raw0)
            free(raw1)
            fatalError("FramebufferView: failed to create CGDataProvider")
        }
        self.provider0 = p0
        self.provider1 = p1

        // レイヤー
        self.contentLayer = CALayer()

        // パフォーマンス測定の初期化
        self.lastFrameTime = CFAbsoluteTimeGetCurrent()
        self.frameCount = 0
        self.totalFrameTime = 0.0

        super.init(frame: frame)

        // IME 状態に host view / fb サイズを渡す（firstRect の換算に使う。TASK-140）
        imeState.hostView = self
        imeState.updateFramebufferSize(width: width, height: height)

        // レイヤーバックドビューに設定
        self.wantsLayer = true

        // コンテンツレイヤーを作成
        self.contentLayer.frame = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        self.contentLayer.isOpaque = true
        self.contentLayer.isGeometryFlipped = true  // Y軸反転を一度だけ設定
        self.layer?.addSublayer(self.contentLayer)

        // TASK-135: OS ファイル drag & drop（file URL のみ。objc backend 先行の横展開）
        self.registerForDraggedTypes([.fileURL])

        NSLog("[\(IMPLEMENTATION_TYPE)] Framebuffer initialized: \(width)x\(height)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - PlatformBackendView (TASK-140)

    var nativeView: NSView { return self }
    var implementationType: String { return IMPLEMENTATION_TYPE }
    var initialFramebuffer: UnsafeMutablePointer<UInt32>? { return currentBuffer }

    // present: 既存 presentManual と同じ swap + layer 更新を行い、次の書込バッファを返す。
    // size 引数は互換のため受けるが内部サイズを使う（引数は無視）。
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
    // objc backend（platform/macos/platform_macos.m）と同一契約: 単一 file URL・UTF-8・
    // 空/上限超(PLATFORM_FILE_DROP_PATH_BYTES)/NUL 含有は reject。struct 充填は共有ヘルパー。

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

    // MARK: - CADisplayLink / 描画

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

    /// buffer を直接参照する no-copy CGDataProvider を作る（コピーなし。TASK-55）。
    /// 失敗時は nil（force unwrap しない。resizeBuffers の回復可能経路用）。
    /// buffer の解放前に provider の参照（layer.contents 含む）を必ず切ること。
    private static func makeNoCopyProvider(buffer: UnsafeMutablePointer<UInt32>, count: Int) -> CGDataProvider? {
        return CGDataProvider(
            dataInfo: nil,
            data: UnsafeRawPointer(buffer),
            size: count * MemoryLayout<UInt32>.size,
            releaseData: { _, _, _ in } // バッファは view 所有（no-op）
        )
    }

    /// 表示中バッファに対応する no-copy provider から CGImage を作る（ピクセルコピーなし）。
    /// フレーム毎に呼ばれるが、生成されるのは参照オブジェクトのみ。
    private func makeDisplayImage() -> CGImage? {
        guard let provider = (displayBuffer == buffer0) ? provider0 : provider1 else { return nil }
        // TASK-104: 透過モードは premultiplied alpha で fb の alpha を honor。既定は従来どおり alpha skip。
        let alphaInfo = transparentMode ? CGImageAlphaInfo.premultipliedFirst.rawValue
                                        : CGImageAlphaInfo.noneSkipFirst.rawValue
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: alphaInfo | CGBitmapInfo.byteOrder32Little.rawValue), // canonical BGRA: メモリ [B,G,R,A] = u32 0xAARRGGBB
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
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

            // 表示バッファの no-copy provider から CGImage を作成（コピーなし。TASK-55）
            let renderStart = CFAbsoluteTimeGetCurrent()
            if let cgImage = makeDisplayImage() {
                contentLayer.contents = cgImage
            }

            // TASK-104: callback/display-link 経路でも click-through を更新（無効時は即 return）
            refreshClickThrough()

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

    func presentManual() {
        // バッファをスワップ（ゼロコピー）
        let temp = currentBuffer
        currentBuffer = displayBuffer
        displayBuffer = temp

        // 表示バッファの no-copy provider から CGImage を作成（コピーなし。TASK-55）
        if let cgImage = makeDisplayImage() {
            contentLayer.contents = cgImage
        }

        // TASK-104: クリック透過のカーソル位置判定を更新（clickThrough 無効時は即 return）
        refreshClickThrough()
    }

    override var isOpaque: Bool {
        return !transparentMode // TASK-104: 透過モードは非不透明
    }

    // TASK-104: クリック透過（per-pixel）。NSView.hitTest で nil を返しても背後の別アプリへは抜けない
    // （それは window-level の ignoresMouseEvents）。present 毎に現在のカーソル位置の alpha を見て
    // `window.ignoresMouseEvents` をトグルする（透明画素上なら背後へ抜け、本体上なら window が受ける）。
    // ホットパス宣言: present 毎だが 1 画素サンプル + プロパティ設定のみ（per-pixel ループなし）。
    func refreshClickThrough() {
        if !clickThrough { return }
        guard let win = window else { return }
        let screenPt = NSEvent.mouseLocation
        let winPt = win.convertPoint(fromScreen: screenPt)
        let local = convert(winPt, from: nil) // window → view（非 flipped = 左下原点）
        let b = bounds
        var passThrough = true // カーソルが window 外/未確定なら抜けさせる
        if b.width > 0 && b.height > 0 &&
           local.x >= 0 && local.x < b.width && local.y >= 0 && local.y < b.height {
            var px = Int(local.x / b.width * CGFloat(width))
            var py = Int((1.0 - local.y / b.height) * CGFloat(height)) // top-left 原点へ
            if px >= width { px = width - 1 } // 右端/下端の丸め込み clamp（下端1px落ち防止）
            if py >= height { py = height - 1 }
            if px < 0 { px = 0 }
            if py < 0 { py = 0 }
            let alpha = UInt8((displayBuffer[py * width + px] >> 24) & 0xFF)
            passThrough = (alpha == 0)
        }
        if passThrough != clickThroughState { // 値が変わったときだけ WindowServer 状態を書く
            win.ignoresMouseEvents = passThrough
            clickThroughState = passThrough
        }
    }

    // TASK-104: 透過/クリック透過モードの設定・beginDrag 用 event の消費（one-shot）。
    func setTransparentMode(_ on: Bool) {
        transparentMode = on
        contentLayer.isOpaque = !on
        needsDisplay = true
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
        lastMouseDownEvent = nil // 呼び出し時に消費（mouse-up 未達に備え再利用しない）
        return ev
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
        // .cursorUpdate: マウス再入時に cursorUpdate(with:) を呼んでもらい、OS がウィンドウ切替等で
        // カーソルをリセットしても復帰できるようにする (TASK-75.1)。
        // .mouseEnteredAndExited: view 内外を追跡し、hidden の所有権解除（exited）と形状の適用（entered）を
        // 行う（codex レビュー: hide/unhide は view 内にいる時のみ行う）。
        let opts: NSTrackingArea.Options = [.mouseMoved, .cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        let ta = NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil)
        self.addTrackingArea(ta)
        trackingArea = ta
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

    override func mouseDown(with event: NSEvent) {
        lastMouseDownEvent = event // TASK-104: beginDrag 用に直近の左 down を保持
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

    // TASK-23 / TASK-23.1: 新サイズへ two-phase でバッファを再確保する。
    // TASK-55 で provider が buffer を **no-copy 参照**するため、旧 buffer の解放前に
    // 「layer.contents の参照を切る → 旧 provider を解放する」順序が必須（objc 版と同順序）。
    // 単位は logical points（mouse 座標と同一）。lock 中には呼ばれない（イベントポンプ中に発火）。
    // 戻り値: サイズが実際に変わって再確保した場合 true。変化なし / OOM / provider 失敗は
    // false（旧サイズ維持・redraw callback 非発火。allocate trap は使わない）。
    @discardableResult
    func resizeBuffers(width w0: Int, height h0: Int) -> Bool {
        let w = max(1, w0)
        let h = max(1, h0)
        if w == width && h == height { return false } // 変化なし
        let newSize = w * h

        // phase 1: 新バッファ + 新 no-copy provider を確保（成功するまで旧リソースには触れない）
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
            return false // np0 はローカル ARC で解放
        }

        // phase 2: 旧 buffer への参照を先に全て切る（contents → provider の順。TASK-55）
        contentLayer.contents = nil
        provider0 = nil
        provider1 = nil
        // phase 3: 旧バッファを破棄して差し替え（calloc 所有なので free）
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
        contentLayer.frame = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        return true
    }

    // NSView がリサイズ時に呼ぶ。新しい logical サイズに合わせて fb を再確保する。
    // resizeBuffers 成功（実サイズ変化）のときだけ redraw callback を発火する（TASK-23.1）。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if resizeBuffers(width: Int(newSize.width), height: Int(newSize.height)) {
            // TASK-140: 再確保後の新書込バッファを handle へ反映する（次 lock/present が正しい buffer を指す）。
            platformWindow?.currentFramebuffer = currentBuffer
            imeState.updateFramebufferSize(width: width, height: height)
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

    deinit {
        stopDisplayLink()

        // カーソルを hide したまま破棄されると OS カーソルが消えたままになる (TASK-75.1 codex レビュー指摘)。
        if cursorHiddenByThisView {
            NSCursor.unhide()
            cursorHiddenByThisView = false
        }

        // no-copy provider が buffer を参照するため、解放順序は
        // contents → provider → buffer（stored property の自動解放が buffer 解放後に
        // 走って use-after-free する事故を防ぐ。TASK-55）
        contentLayer.contents = nil
        provider0 = nil
        provider1 = nil
        free(UnsafeMutableRawPointer(buffer0))
        free(UnsafeMutableRawPointer(buffer1))
    }
}

// ========================================
// backend ファクトリ (TASK-140)
// ========================================
// 共有 createWindowImpl から呼ばれ、CALayer backend の view を生成する。透過モード等の view 側
// 設定はここで行う（window レベルの透過は共有側）。
func makePlatformBackendView(
    frame: NSRect,
    width: Int,
    height: Int,
    callback: FrameCallback?,
    userdata: UnsafeMutableRawPointer?,
    transparent: Bool
) -> (any PlatformBackendView)? {
    let view = FramebufferView(
        frame: frame,
        width: width,
        height: height,
        callback: callback,
        userdata: userdata
    )
    if transparent {
        view.setTransparentMode(true) // CGImage を premultiplied alpha 化
    }
    return view
}
