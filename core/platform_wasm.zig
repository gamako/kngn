//! wasm32-wasi platform backend（TASK-73.1）
//!
//! JS glue（web/vp.js）と `extern "env"` / `export` で接続する。
//! framebuffer は wasm_allocator で確保し、present で BGRA→RGBA swizzle（pixelops SIMD）後に
//! `vp_present` へ渡す。入力は JS が `vp_push_*` でキューへ push、Zig は nextEvent で drain。
//!
//! ホットパス宣言: present の全画素 swizzle はフレーム毎。入力/init はイベント時・初期化時のみ。

const std = @import("std");
const builtin = @import("builtin");
const types = @import("platform_types");
const pixelops = @import("pixelops");

const Error = types.Error;
const Event = types.Event;
const EventStats = types.EventStats;
const KeyCode = types.KeyCode;
const KeyEvent = types.KeyEvent;
const CharEvent = types.CharEvent;
const MouseButton = types.MouseButton;
const MouseButtons = types.MouseButtons;
const MouseEvent = types.MouseEvent;
const ScrollEvent = types.ScrollEvent;
const ModifierFlags = types.ModifierFlags;
const DialogError = types.DialogError;
const SaveDialogOptions = types.SaveDialogOptions;
const OpenDialogOptions = types.OpenDialogOptions;
const CursorShape = types.CursorShape;

// ============================================================================
// JS import table（env）
// ============================================================================

extern "env" fn vp_now() f64;
extern "env" fn vp_present(ptr: [*]const u8, w: u32, h: u32) void;
extern "env" fn vp_log(ptr: [*]const u8, len: u32) void;
extern "env" fn vp_set_cursor(shape: c_int) void;

// ============================================================================
// DOM KeyboardEvent.code → KeyCode（Zig 側純データ表。platform_linux_input 流儀）
// ============================================================================

const DomKeyEntry = struct { code: []const u8, key: KeyCode };

/// pixie が使うキー（英字/数字/矢印/Space/Esc/Enter/Backspace/Tab/修飾）を最低限カバー。
const dom_key_table = [_]DomKeyEntry{
    .{ .code = "KeyA", .key = .A },
    .{ .code = "KeyB", .key = .B },
    .{ .code = "KeyC", .key = .C },
    .{ .code = "KeyD", .key = .D },
    .{ .code = "KeyE", .key = .E },
    .{ .code = "KeyF", .key = .F },
    .{ .code = "KeyG", .key = .G },
    .{ .code = "KeyH", .key = .H },
    .{ .code = "KeyI", .key = .I },
    .{ .code = "KeyJ", .key = .J },
    .{ .code = "KeyK", .key = .K },
    .{ .code = "KeyL", .key = .L },
    .{ .code = "KeyM", .key = .M },
    .{ .code = "KeyN", .key = .N },
    .{ .code = "KeyO", .key = .O },
    .{ .code = "KeyP", .key = .P },
    .{ .code = "KeyQ", .key = .Q },
    .{ .code = "KeyR", .key = .R },
    .{ .code = "KeyS", .key = .S },
    .{ .code = "KeyT", .key = .T },
    .{ .code = "KeyU", .key = .U },
    .{ .code = "KeyV", .key = .V },
    .{ .code = "KeyW", .key = .W },
    .{ .code = "KeyX", .key = .X },
    .{ .code = "KeyY", .key = .Y },
    .{ .code = "KeyZ", .key = .Z },
    .{ .code = "Digit0", .key = .@"0" },
    .{ .code = "Digit1", .key = .@"1" },
    .{ .code = "Digit2", .key = .@"2" },
    .{ .code = "Digit3", .key = .@"3" },
    .{ .code = "Digit4", .key = .@"4" },
    .{ .code = "Digit5", .key = .@"5" },
    .{ .code = "Digit6", .key = .@"6" },
    .{ .code = "Digit7", .key = .@"7" },
    .{ .code = "Digit8", .key = .@"8" },
    .{ .code = "Digit9", .key = .@"9" },
    .{ .code = "Space", .key = .SPACE },
    .{ .code = "Escape", .key = .ESCAPE },
    .{ .code = "Enter", .key = .ENTER },
    .{ .code = "Tab", .key = .TAB },
    .{ .code = "Backspace", .key = .BACKSPACE },
    .{ .code = "Delete", .key = .DELETE },
    .{ .code = "ArrowLeft", .key = .LEFT },
    .{ .code = "ArrowRight", .key = .RIGHT },
    .{ .code = "ArrowUp", .key = .UP },
    .{ .code = "ArrowDown", .key = .DOWN },
    .{ .code = "ShiftLeft", .key = .LEFT_SHIFT },
    .{ .code = "ShiftRight", .key = .RIGHT_SHIFT },
    .{ .code = "ControlLeft", .key = .LEFT_CONTROL },
    .{ .code = "ControlRight", .key = .RIGHT_CONTROL },
    .{ .code = "AltLeft", .key = .LEFT_ALT },
    .{ .code = "AltRight", .key = .RIGHT_ALT },
    .{ .code = "MetaLeft", .key = .LEFT_SUPER },
    .{ .code = "MetaRight", .key = .RIGHT_SUPER },
};

fn domCodeToKeyCode(code: []const u8) KeyCode {
    for (dom_key_table) |e| {
        if (std.mem.eql(u8, e.code, code)) return e.key;
    }
    return .UNKNOWN;
}

/// JS が KeyboardEvent.code 文字列を書く固定スクラッチ（最大 32B。DOM code は十分収まる）。
var dom_code_scratch: [32]u8 = undefined;

export fn vp_dom_code_scratch() [*]u8 {
    return &dom_code_scratch;
}

/// scratch に書いた DOM code（len バイト）→ KeyCode（i32）。未知は UNKNOWN(-1)。
export fn vp_dom_code_to_keycode(len: u32) i32 {
    const n = @min(len, dom_code_scratch.len);
    return @intFromEnum(domCodeToKeyCode(dom_code_scratch[0..n]));
}

// ============================================================================
// イベントキュー（固定リング）
// ============================================================================

const QUEUE_CAP = 256;
var event_queue: [QUEUE_CAP]Event = undefined;
var queue_head: usize = 0;
var queue_tail: usize = 0;
var queue_len: usize = 0;

fn queuePush(ev: Event) void {
    if (queue_len >= QUEUE_CAP) {
        // 溢れは最古を破棄（drop）
        queue_head = (queue_head + 1) % QUEUE_CAP;
        queue_len -= 1;
    }
    event_queue[queue_tail] = ev;
    queue_tail = (queue_tail + 1) % QUEUE_CAP;
    queue_len += 1;
}

fn queuePop() ?Event {
    if (queue_len == 0) return null;
    const ev = event_queue[queue_head];
    queue_head = (queue_head + 1) % QUEUE_CAP;
    queue_len -= 1;
    return ev;
}

fn modsFromC(raw: u32) ModifierFlags {
    return ModifierFlags.fromC(raw);
}

fn buttonsFromC(raw: u32) MouseButtons {
    return MouseButtons.fromC(@truncate(raw));
}

/// DOM `MouseEvent.button` → `MouseButton`。
/// 入力は共有 enum の discriminant ではなく DOM 値域（0=left, 1=middle, 2=right）。
/// `MouseButton` は left=0 / right=1 / middle=2 なので middle/right の番号が DOM と入れ替わる。
fn buttonFromDom(b: i32) MouseButton {
    return switch (b) {
        0 => .left,
        1 => .middle, // DOM middle（≠ MouseButton.right = 1）
        2 => .right, // DOM right（≠ MouseButton.middle = 2）
        else => .none,
    };
}

/// kind: 0=move, 1=down, 2=up
export fn vp_push_key(down: bool, code: i32, mods: u32, is_repeat: bool) void {
    const key: KeyCode = @enumFromInt(code);
    const kev = KeyEvent{
        .key = key,
        .is_repeat = is_repeat,
        .modifiers = modsFromC(mods),
    };
    queuePush(if (down) .{ .key_down = kev } else .{ .key_up = kev });
}

export fn vp_push_char(codepoint: u32, mods: u32) void {
    // 制御文字は流さない（platform_types CharEvent 契約）
    if (codepoint < 0x20 or codepoint == 0x7f) return;
    queuePush(.{ .char_input = .{ .codepoint = codepoint, .modifiers = modsFromC(mods) } });
}

export fn vp_push_mouse(kind: i32, x: i32, y: i32, button: i32, buttons: u32, mods: u32) void {
    const mev = MouseEvent{
        .x = x,
        .y = y,
        .button = buttonFromDom(button),
        .buttons = buttonsFromC(buttons),
        .modifiers = modsFromC(mods),
    };
    queuePush(switch (kind) {
        1 => .{ .mouse_down = mev },
        2 => .{ .mouse_up = mev },
        else => .{ .mouse_move = mev },
    });
}

export fn vp_push_scroll(x: i32, y: i32, dx: f32, dy: f32, mods: u32) void {
    queuePush(.{
        .mouse_scroll = .{
            .x = x,
            .y = y,
            .dx = dx,
            .dy = dy,
            .is_precise = false,
            .buttons = .{},
            .modifiers = modsFromC(mods),
        },
    });
}

// ============================================================================
// framebuffer state
// ============================================================================

var pixels_buf: []u32 = &.{};
var rgba_buf: []u8 = &.{};
var fb_w: u32 = 0;
var fb_h: u32 = 0;
/// 0 = 保留なし。vp_resize がセットし、次の lockFramebuffer 冒頭で適用（フレーム境界）。
var pending_w: u32 = 0;
var pending_h: u32 = 0;
const default_gpa: std.mem.Allocator = if (builtin.cpu.arch.isWasm())
    std.heap.wasm_allocator
else
    std.heap.page_allocator;
/// テストから OOM を注入できるよう var（本番では default_gpa 固定。init/resize 時のみ使用）。
var gpa: std.mem.Allocator = default_gpa;

const MIN_FB_W: u32 = 320;
const MIN_FB_H: u32 = 240;
const MAX_FB_W: u32 = 8192;
const MAX_FB_H: u32 = 8192;

fn clampResizeDim(w: u32, h: u32) struct { w: u32, h: u32 } {
    return .{
        .w = @max(MIN_FB_W, @min(w, MAX_FB_W)),
        .h = @max(MIN_FB_H, @min(h, MAX_FB_H)),
    };
}

/// JS ResizeObserver から呼ぶ。フレーム中のバッファ差し替えを避け pending に保持する。
export fn vp_resize(w: u32, h: u32) void {
    const c = clampResizeDim(w, h);
    pending_w = c.w;
    pending_h = c.h;
}

/// 失敗時は pending を保持したまま返す（旧 framebuffer は two-phase 確保で無傷なので
/// 旧サイズで描画継続 + 次の lockFramebuffer で再試行）。
fn applyPendingResize() void {
    if (pending_w == 0 or pending_h == 0) return;
    ensureFramebuffer(pending_w, pending_h) catch return;
    pending_w = 0;
    pending_h = 0;
}

fn ensureFramebuffer(w: u32, h: u32) Error!void {
    const n = @as(usize, w) * @as(usize, h);
    if (pixels_buf.len == n and fb_w == w and fb_h == h) return;

    // two-phase commit: 新バッファ 2 枚の確保が両方成功してから旧バッファを解放する。
    // 途中失敗しても旧 framebuffer は無傷（OOM 後も旧サイズで描画継続できる）。
    const new_pixels = gpa.alloc(u32, n) catch return error.WindowCreationFailed;
    const new_rgba = gpa.alloc(u8, n * 4) catch {
        gpa.free(new_pixels);
        return error.WindowCreationFailed;
    };
    if (pixels_buf.len != 0) gpa.free(pixels_buf);
    if (rgba_buf.len != 0) gpa.free(rgba_buf);
    pixels_buf = new_pixels;
    rgba_buf = new_rgba;
    @memset(pixels_buf, 0);
    fb_w = w;
    fb_h = h;
}

// ============================================================================
// Window / Framebuffer
// ============================================================================

pub const Window = struct {
    width: u32,
    height: u32,

    pub fn create(width: u32, height: u32, _: [:0]const u8) Error!Window {
        try ensureFramebuffer(width, height);
        return .{ .width = fb_w, .height = fb_h };
    }

    pub fn destroy(_: Window) void {
        if (pixels_buf.len != 0) {
            gpa.free(pixels_buf);
            pixels_buf = &.{};
        }
        if (rgba_buf.len != 0) {
            gpa.free(rgba_buf);
            rgba_buf = &.{};
        }
        fb_w = 0;
        fb_h = 0;
    }

    pub fn pollEvents(_: Window) bool {
        return true;
    }

    pub fn nextEvent(_: Window) ?Event {
        return queuePop();
    }

    pub fn getEventStats(_: Window) EventStats {
        return .{
            .mouse_move_merge_count = 0,
            .mouse_scroll_merge_count = 0,
            .event_drop_count = 0,
        };
    }

    pub fn lockFramebuffer(_: Window) ?Framebuffer {
        applyPendingResize();
        if (pixels_buf.len == 0) return null;
        return .{
            .pixels = pixels_buf,
            .width = fb_w,
            .height = fb_h,
        };
    }

    pub fn present(_: Window) void {
        if (pixels_buf.len == 0 or rgba_buf.len == 0) return;
        const src = std.mem.sliceAsBytes(pixels_buf);
        pixelops.swizzleBgraToRgba(rgba_buf, src);
        vp_present(rgba_buf.ptr, fb_w, fb_h);
    }

    pub fn setCursor(_: Window, shape: CursorShape) void {
        vp_set_cursor(@intFromEnum(shape));
    }

    /// ライブリサイズ再描画コールバック（TASK-23.1）。ブラウザは OS モーダルループが無く
    /// リサイズ中も rAF が回り続けるため no-op スタブ（X11/Wayland と同型）。
    pub fn setRedrawCallback(self: Window, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque) void) void {
        _ = self;
        _ = ctx;
        _ = cb;
    }

    /// destroy 用の private clear 経路（no-op。TASK-23.1）。
    pub fn clearRedrawCallback(self: Window) void {
        _ = self;
    }

    pub fn getGamepadState(_: Window, _: u8) ?types.GamepadState {
        return null;
    }
};

pub const Framebuffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,

    pub fn unlock(_: Framebuffer) void {}
};

pub fn init() Error!void {}

pub fn shutdown() void {}

pub fn getTime() f64 {
    return vp_now();
}

pub fn saveFileDialog(_: std.mem.Allocator, _: std.Io, _: SaveDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    return error.DialogUnavailable;
}

pub fn openFileDialog(_: std.mem.Allocator, _: std.Io, _: OpenDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    return error.DialogUnavailable;
}

/// freestanding 向け log（std_options.logFn から呼ぶ想定）。
pub fn logMessage(msg: []const u8) void {
    if (msg.len == 0) return;
    vp_log(msg.ptr, @intCast(msg.len));
}

test "buttonFromDom: DOM MouseEvent.button → MouseButton" {
    // DOM: 0=left, 1=middle, 2=right（JS buttonIndex がこの値域を渡す）
    try std.testing.expectEqual(MouseButton.left, buttonFromDom(0));
    try std.testing.expectEqual(MouseButton.middle, buttonFromDom(1));
    try std.testing.expectEqual(MouseButton.right, buttonFromDom(2));
    try std.testing.expectEqual(MouseButton.none, buttonFromDom(-1));
    try std.testing.expectEqual(MouseButton.none, buttonFromDom(3));
}

test "domCodeToKeyCode: pixie 最低限キー" {
    try std.testing.expectEqual(KeyCode.A, domCodeToKeyCode("KeyA"));
    try std.testing.expectEqual(KeyCode.SPACE, domCodeToKeyCode("Space"));
    try std.testing.expectEqual(KeyCode.ESCAPE, domCodeToKeyCode("Escape"));
    try std.testing.expectEqual(KeyCode.LEFT, domCodeToKeyCode("ArrowLeft"));
    try std.testing.expectEqual(KeyCode.UNKNOWN, domCodeToKeyCode("F13"));
}

fn testResetFramebufferState() void {
    gpa = default_gpa;
    if (pixels_buf.len != 0) {
        gpa.free(pixels_buf);
        pixels_buf = &.{};
    }
    if (rgba_buf.len != 0) {
        gpa.free(rgba_buf);
        rgba_buf = &.{};
    }
    fb_w = 0;
    fb_h = 0;
    pending_w = 0;
    pending_h = 0;
}

test "vp_resize: lockFramebuffer で寸法反映" {
    testResetFramebufferState();
    defer testResetFramebufferState();

    var win = try Window.create(320, 240, "t");
    defer win.destroy();

    vp_resize(640, 480);
    const fb = win.lockFramebuffer() orelse unreachable;
    try std.testing.expectEqual(@as(u32, 640), fb.width);
    try std.testing.expectEqual(@as(u32, 480), fb.height);
    try std.testing.expectEqual(@as(usize, 640 * 480), fb.pixels.len);
}

test "vp_resize: 複数回は最後の値が勝つ" {
    testResetFramebufferState();
    defer testResetFramebufferState();

    vp_resize(400, 300);
    vp_resize(500, 400);
    vp_resize(640, 480);
    try std.testing.expectEqual(@as(u32, 640), pending_w);
    try std.testing.expectEqual(@as(u32, 480), pending_h);
}

test "vp_resize: clamp min 320x240 max 8192" {
    testResetFramebufferState();
    defer testResetFramebufferState();

    vp_resize(10, 10);
    try std.testing.expectEqual(@as(u32, 320), pending_w);
    try std.testing.expectEqual(@as(u32, 240), pending_h);

    vp_resize(10000, 10000);
    try std.testing.expectEqual(@as(u32, 8192), pending_w);
    try std.testing.expectEqual(@as(u32, 8192), pending_h);
}

test "vp_resize: OOM 失敗時は旧 fb 温存 + pending 保持で再試行（codex P1）" {
    testResetFramebufferState();
    defer testResetFramebufferState();

    var win = try Window.create(320, 240, "t");
    defer win.destroy();

    // 以後の alloc を全て失敗させる（two-phase なので旧バッファは無傷のはず）
    var failing = std.testing.FailingAllocator.init(default_gpa, .{ .fail_index = 0 });
    gpa = failing.allocator();

    vp_resize(640, 480);
    const fb = win.lockFramebuffer() orelse unreachable; // 旧 fb で描画継続
    try std.testing.expectEqual(@as(u32, 320), fb.width);
    try std.testing.expectEqual(@as(u32, 240), fb.height);
    try std.testing.expectEqual(@as(u32, 640), pending_w); // pending は保持（再試行対象）
    try std.testing.expectEqual(@as(u32, 480), pending_h);

    // alloc が回復したら次の lockFramebuffer で適用される
    gpa = default_gpa;
    const fb2 = win.lockFramebuffer() orelse unreachable;
    try std.testing.expectEqual(@as(u32, 640), fb2.width);
    try std.testing.expectEqual(@as(u32, 480), fb2.height);
    try std.testing.expectEqual(@as(u32, 0), pending_w);
}

test "vp_resize: pending 未消化中は旧 fb サイズのまま" {
    testResetFramebufferState();
    defer testResetFramebufferState();

    var win = try Window.create(320, 240, "t");
    defer win.destroy();

    _ = win.lockFramebuffer() orelse unreachable;
    vp_resize(640, 480);
    try std.testing.expectEqual(@as(u32, 320), fb_w);
    try std.testing.expectEqual(@as(u32, 240), fb_h);
    try std.testing.expectEqual(@as(usize, 320 * 240), pixels_buf.len);

    const fb2 = win.lockFramebuffer() orelse unreachable;
    try std.testing.expectEqual(@as(u32, 640), fb2.width);
    try std.testing.expectEqual(@as(u32, 480), fb2.height);
}
