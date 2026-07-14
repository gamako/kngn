import Cocoa
import MetalKit
import UniformTypeIdentifiers
#if VP_ENABLE_GAMEPAD
import GameController
#endif

// Metal最適化版の実装（Swift）
// 型定義 (PlatformEvent, PlatformEventType, PlatformKeyCode, PLATFORM_* 定数,
//        FrameCallback typealias など) は bridging header (-import-objc-header
//        platform/platform.h) 経由で C ヘッダから自動取得する。
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

    func peekTail() -> UnsafeMutablePointer<PlatformEvent>? {
        if head == tail { return nil }
        let prev = (head - 1 + EVENT_QUEUE_SIZE) % EVENT_QUEUE_SIZE
        return events.advanced(by: prev)
    }

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

let SCROLL_LINE_TO_POINTS: Float = 16.0

func eventLocationToPlatformCoords(_ event: NSEvent, _ view: NSView) -> (Int32, Int32) {
    let windowPt = event.locationInWindow
    let viewPt = view.convert(windowPt, from: nil)
    let viewHeight = view.bounds.size.height
    let x = Int32(floor(viewPt.x))
    let y = Int32(floor(viewHeight - viewPt.y))
    return (x, y)
}

func pressedButtonsMask() -> UInt8 {
    return UInt8(NSEvent.pressedMouseButtons & 0x07)
}

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
    var event_queue: EventQueue

    init(window: NSWindow, metalView: MetalFramebufferView) {
        self.window = window
        self.metalView = metalView
        self.event_queue = EventQueue()
        super.init()
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

    // inflight 上限 = slotCount - 1（= 2）。display sync(fifo) の pacing を司る。
    // present のたびに wait()、command buffer の completion handler で signal()。
    private let inflightSemaphore = DispatchSemaphore(value: 2)

    // manual present（present() → view.draw() 起点）であることを draw(in:) に伝えるフラグ。
    private var manualPresentPending = false

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

        // パフォーマンス測定の初期化
        self.lastFrameTime = CFAbsoluteTimeGetCurrent()
        self.frameCount = 0
        self.totalFrameTime = 0.0

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
    private func updatePerfStats() {
        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        totalFrameTime += now - lastFrameTime
        lastFrameTime = now

        if frameCount % 60 == 0 {
            let avgFrameTime = totalFrameTime / 60.0
            let fps = avgFrameTime > 0 ? 1.0 / avgFrameTime : 0
            NSLog("[\(IMPLEMENTATION_TYPE)] FPS: \(String(format: "%.1f", fps)) | Avg Frame: \(String(format: "%.2f", avgFrameTime * 1000.0))ms")
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
        return true
    }
}

// composition preedit 固定バッファ容量（UTF-8。TASK-79.6.1）
private let compositionUtf8Cap = 1024

/// s[0..<len] のうち cap 以内に収まる最長 UTF-8 codepoint 境界プレフィックス長（codex 修正 A）。
private func utf8SafePrefixLen(_ s: [UInt8], len: Int, cap: Int) -> Int {
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

// カスタムMTKView + NSTextInputClient（TASK-79.6.1 IME）
class MetalFramebufferView: MTKView, NSTextInputClient {
    private var metalRenderer: MetalRenderer?

    // マウスイベント用 (TASK-21.1)
    weak var platformWindow: PlatformWindowHandle?
    private var customTrackingArea: NSTrackingArea?

    // カーソル制御用 (TASK-75.1)
    private var currentCursorShape: PlatformCursorShape = PLATFORM_CURSOR_DEFAULT  // 直近に要求された形状
    private var cursorHiddenByThisView: Bool = false  // このviewが [NSCursor hide] を所有中か（グローバル参照カウントAPIの多重呼び出し防止）
    private var mouseInsideView: Bool = false         // マウスが現在 view 内にあるか（view外では set/hide を保留する）

    // ライブリサイズ再描画 (TASK-23.1)。CADisplayLink 用 FrameCallback とは別 field。
    private var redrawCallback: PlatformRedrawCallback?
    private var redrawUserdata: UnsafeMutableRawPointer?

    // IME composition 状態 (TASK-79.6.1)
    private var markedTextStorage = NSMutableString()
    private var imeSelectedRange = NSRange(location: 0, length: 0)
    private var compositionUtf8 = [UInt8](repeating: 0, count: compositionUtf8Cap)
    private var compositionLen: UInt32 = 0
    private var compositionRevision: UInt32 = 0
    private var compositionCursor: UInt32 = 0

    override init(frame: CGRect, device: MTLDevice?) {
        let metalDevice = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: metalDevice)

        // デリゲートは後で設定
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - NSTextInputClient / IME (TASK-79.6.1)

    override var acceptsFirstResponder: Bool { true }

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
            }
        }
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        // replacementRange: 79.6.2+ で扱う（char_input に置換情報が無い現契約の既知の穴）。
        _ = replacementRange
        let str: String
        if let attr = string as? NSAttributedString {
            str = attr.string
        } else if let s = string as? String {
            str = s
        } else {
            str = ""
        }
        let hadMarked = markedTextStorage.length > 0
        if hadMarked {
            markedTextStorage.setString("")
            imeSelectedRange = NSRange(location: 0, length: 0)
            compositionLen = 0
            compositionCursor = 0
            pushCompositionPhase(UInt8(PLATFORM_COMPOSITION_PHASE_COMMIT.rawValue))
        }
        pushCharInputs(from: str)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // replacementRange: 79.6.2+ で扱う（char_input に置換情報が無い現契約の既知の穴）。
        _ = replacementRange
        let str: String
        if let attr = string as? NSAttributedString {
            str = attr.string
        } else if let s = string as? String {
            str = s
        } else {
            str = ""
        }
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
            if !wasEmpty {
                pushCompositionPhase(UInt8(PLATFORM_COMPOSITION_PHASE_CANCEL.rawValue))
            }
            return
        }
        let phase: UInt8 = wasEmpty
            ? UInt8(PLATFORM_COMPOSITION_PHASE_START.rawValue)
            : UInt8(PLATFORM_COMPOSITION_PHASE_UPDATE.rawValue)
        pushCompositionPhase(phase)
    }

    func unmarkText() {
        guard markedTextStorage.length > 0 else { return }
        markedTextStorage.setString("")
        imeSelectedRange = NSRange(location: 0, length: 0)
        compositionLen = 0
        compositionCursor = 0
        pushCompositionPhase(UInt8(PLATFORM_COMPOSITION_PHASE_CANCEL.rawValue))
    }

    func hasMarkedText() -> Bool {
        return markedTextStorage.length > 0
    }

    func markedRange() -> NSRange {
        if markedTextStorage.length == 0 { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedTextStorage.length)
    }

    func selectedRange() -> NSRange {
        if markedTextStorage.length == 0 { return NSRange(location: NSNotFound, length: 0) }
        return imeSelectedRange
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        if markedTextStorage.length == 0 { return nil }
        let full = NSRange(location: 0, length: markedTextStorage.length)
        let clipped = NSIntersectionRange(full, range)
        if clipped.length == 0 { return nil }
        actualRange?.pointee = clipped
        let sub = markedTextStorage.substring(with: clipped)
        return NSAttributedString(string: sub)
    }

    func characterIndex(for point: NSPoint) -> Int {
        _ = point
        return NSNotFound
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        // MVP: view 左上近傍の固定 rect（候補窓が window 近傍に出ること。caret 供給は 79.6.2）
        var r = NSRect(x: 20.0, y: bounds.size.height - 48.0, width: 1.0, height: 18.0)
        r = convert(r, to: nil)
        if let win = window {
            r = win.convertToScreen(r)
        }
        return r
    }

    override func doCommand(by selector: Selector) {
        // 未処理 command を吸収してビープ抑止。物理キーは key_down 経路で既に届く。
        // super は呼ばない（未処理 command のビープを抑止する NSTextInputClient 契約）。
        _ = selector
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
    }

    func getRenderer() -> MetalRenderer? {
        return metalRenderer
    }

    // NSView がリサイズ時に呼ぶ。renderer の fb を新しい logical サイズへ再確保する（TASK-23）。
    // MTKView の drawableSize は別途自動更新され、texture は drawable へ upscale される。
    // サイズが実際に変わったときだけ redraw callback を発火する（TASK-23.1。
    // callback 内 present は presentManual → view.draw() で同期。manual モードは isPaused=true）。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let renderer = metalRenderer else { return }
        if renderer.resize(width: Int(newSize.width), height: Int(newSize.height)), let cb = redrawCallback {
            cb(redrawUserdata)
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

    let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable] // TASK-23: 自由リサイズ

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

    // Metal用ビューを作成
    guard let metalDevice = MTLCreateSystemDefaultDevice() else {
        NSLog("[\(IMPLEMENTATION_TYPE)] Failed to create Metal device")
        return nil
    }

    let metalView = MetalFramebufferView(frame: frame, device: metalDevice)
    metalView.framebufferOnly = false
    metalView.enableSetNeedsDisplay = false
    // 手動描画経路（callback=nil。Zig facade の lockFramebuffer→present 経路）では display-link を止め、
    // present() が view.draw() で 1 フレームずつ駆動する。callback 経路（objc/swift 対称・未使用）は
    // 従来どおり display-link 駆動のため isPaused=false にする。
    metalView.isPaused = (callback == nil)
    // fifo（display refresh 同期）の意図をコード上で明示する。macOS では CAMetalLayer の既定が true
    // なので必須の挙動変更ではないが、ADR-005 の 1級 backend 契約を明文化する。
    (metalView.layer as? CAMetalLayer)?.displaySyncEnabled = true

    // レンダラーをセットアップ
    metalView.setupRenderer(width: Int(width), height: Int(height), callback: callback, userdata: userdata)

    window.contentView = metalView

    // PlatformWindowハンドルを作成
    let platformWindow = PlatformWindowHandle(window: window, metalView: metalView)
    // view → handle の back-reference を設定 (TASK-21.1)
    metalView.platformWindow = platformWindow
    // setContentView 後に NSTrackingArea を構築
    metalView.updateTrackingAreas()

    // ウィンドウを表示
    window.center()
    window.makeKeyAndOrderFront(nil)
    // IME: view を first responder にして inputContext / interpretKeyEvents が効くようにする（TASK-79.6.1）
    window.makeFirstResponder(metalView)
    app.activate(ignoringOtherApps: true)

    #if VP_ENABLE_GAMEPAD
    // ゲームパッド: このwindowをアクティブにし、既接続コントローラを取り込む (TASK-80.2)
    gamepadAttachWindow(platformWindow)
    #endif

    let handle = UnsafeMutableRawPointer(Unmanaged.passRetained(platformWindow).toOpaque())

    return handle
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

    // ハンドルからPlatformWindowHandleを復元してリリース
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeRetainedValue()
    #if VP_ENABLE_GAMEPAD
    // ゲームパッド: このwindowがアクティブなら参照を外す (TASK-80.2)
    gamepadDetachWindow(handle)
    #endif
    // delegate を解除 (callback から view への参照を断つ)
    handle.metalView.delegate = nil
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

            // keyDown: 物理 key_down を積んだ後 IME/inputContext 経路へ（TASK-79.6.1）。
            // insertText が char_input の唯一の生成元。旧 event.characters 直読みは廃止。
            if event.type == .keyDown {
                handle.metalView.interpretKeyEvents([event])
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
    return handle.metalView.copyCompositionSnapshot(buf: buf, cap: cap, meta: meta)
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

    // MetalFramebufferViewのrendererにアクセス
    guard let renderer = handle.metalView.getRenderer() else { return nil }

    // サイズを返す
    if let out_width = out_width {
        out_width.pointee = Int32(renderer.getWidth())
    }
    if let out_height = out_height {
        out_height.pointee = Int32(renderer.getHeight())
    }

    // 現在の slot の CPU バッファを返す（caller が書き込み、present で submit される）
    return renderer.getCurrentBuffer()
}

@_cdecl("platform_unlock_framebuffer")
func platform_unlock_framebuffer(platformWindow: UnsafeMutableRawPointer?) -> Void {
    // このAPIでは特に何もする必要なし
    // texture への転送・submit・slot 前進は platform_present() で行う
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
    handle.metalView.setCursorShape(s)
}

// ライブリサイズ再描画コールバック登録 (TASK-23.1)。cb==nil で解除。
@_cdecl("platform_set_redraw_callback")
func platform_set_redraw_callback(platformWindow: UnsafeMutableRawPointer?, cb: PlatformRedrawCallback?, userdata: UnsafeMutableRawPointer?) {
    guard let platformWindow = platformWindow else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    handle.metalView.setRedrawCallback(cb, userdata: userdata)
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
