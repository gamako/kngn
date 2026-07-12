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
/// ブラウザ file picker を発火（allowed_ext ヒント。空可）。二重発火防止は Zig/JS 双方。
extern "env" fn vp_request_open(ext_ptr: [*]const u8, ext_len: u32) void;
/// `navigator.clipboard.writeText`（text/plain）。
extern "env" fn vp_clipboard_write(ptr: [*]const u8, len: u32) void;
/// `navigator.clipboard.readText` を非同期開始。結果は `vp_clipboard_text` で届く。
extern "env" fn vp_request_paste() void;

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

// ============================================================================
// File dialog（TASK-73.3）— パスモデル温存 + JS メモリ FS
// ============================================================================
//
// open: 非同期（browser file picker）。未 pick → DialogPending、pick 後の再呼び出しで path を返す。
// save: 同期に default_name を返す（実体保存は WASI write → JS memfs → Blob download）。
// request 中の再 open は picker を二重発火せず DialogPending のまま待つ。

/// open ダイアログの pending 状態機械（DOM 非依存・単体テスト対象）。
const OpenDialogState = enum { idle, requested, picked, cancelled };

const OpenDialogMachine = struct {
    state: OpenDialogState = .idle,
    path_buf: [256]u8 = undefined,
    path_len: u32 = 0,

    /// openFileDialog 呼び出し時の遷移。`.request` のときだけ JS picker を発火する。
    fn onCall(self: *OpenDialogMachine) enum { request, pending, take_path, cancelled } {
        return switch (self.state) {
            .idle => blk: {
                self.state = .requested;
                break :blk .request;
            },
            .requested => .pending,
            .picked => blk: {
                self.state = .idle;
                break :blk .take_path;
            },
            .cancelled => blk: {
                self.state = .idle;
                self.path_len = 0;
                break :blk .cancelled;
            },
        };
    }

    /// JS が path を scratch 経由で届けたとき。request 中以外は無視（二重 request 防止）。
    fn onPicked(self: *OpenDialogMachine, path: []const u8) void {
        if (self.state != .requested) return;
        const n = @min(path.len, self.path_buf.len);
        if (n > 0) @memcpy(self.path_buf[0..n], path[0..n]);
        self.path_len = @intCast(n);
        self.state = .picked;
    }

    fn onCancelled(self: *OpenDialogMachine) void {
        if (self.state != .requested) return;
        self.path_len = 0;
        self.state = .cancelled;
    }

    fn takePathSlice(self: *const OpenDialogMachine) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    fn reset(self: *OpenDialogMachine) void {
        self.* = .{};
    }
};

/// pick 仮想 path: `pick/<basename>`（path traversal を潰した basename）。
/// 戻り値は `out` 内スライス。名前が空なら `pick/file`。
fn makePickPath(name: []const u8, out: []u8) []const u8 {
    const base = basenameSanitize(name);
    const prefix = "pick/";
    const n = @min(base.len, out.len -| prefix.len);
    if (out.len < prefix.len) return out[0..0];
    @memcpy(out[0..prefix.len], prefix);
    if (n > 0) @memcpy(out[prefix.len..][0..n], base[0..n]);
    return out[0 .. prefix.len + n];
}

/// `/` `\` を除き、`.` `..` を `file` に落とす。
fn basenameSanitize(name: []const u8) []const u8 {
    var s = name;
    // 末尾の path 区切りを落とす
    while (s.len > 0 and (s[s.len - 1] == '/' or s[s.len - 1] == '\\')) s = s[0 .. s.len - 1];
    // 最後の区切り以降
    if (std.mem.lastIndexOfAny(u8, s, "/\\")) |i| s = s[i + 1 ..];
    if (s.len == 0 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return "file";
    return s;
}

var open_dialog: OpenDialogMachine = .{};

/// JS が pick path 文字列を書く固定スクラッチ（最大 256B）。
var file_path_scratch: [256]u8 = undefined;

export fn vp_file_path_scratch() [*]u8 {
    return &file_path_scratch;
}

/// scratch に書いた仮想 path（len バイト）を open 状態機械へ届け、picked にする。
export fn vp_file_picked(len: u32) void {
    const n = @min(len, file_path_scratch.len);
    open_dialog.onPicked(file_path_scratch[0..n]);
}

export fn vp_file_cancelled() void {
    open_dialog.onCancelled();
}

fn requestOpenJs(ext: []const u8) void {
    if (builtin.is_test) return;
    if (ext.len == 0) {
        // JS は len=0 を「フィルタ無し」と解釈。ptr は読まない。
        vp_request_open(@as([*]const u8, @ptrFromInt(1)), 0);
    } else {
        vp_request_open(ext.ptr, @intCast(ext.len));
    }
}

pub fn saveFileDialog(allocator: std.mem.Allocator, _: std.Io, opts: SaveDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    // 同期: ブラウザ download UI が保存先を担うので default_name をそのまま path として返す。
    const name = opts.default_name orelse "download.bin";
    return try allocator.dupe(u8, name);
}

pub fn openFileDialog(allocator: std.mem.Allocator, _: std.Io, opts: OpenDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    switch (open_dialog.onCall()) {
        .request => {
            const ext = opts.allowed_ext orelse "";
            requestOpenJs(ext);
            return error.DialogPending;
        },
        .pending => return error.DialogPending,
        .take_path => {
            const slice = open_dialog.takePathSlice();
            if (slice.len == 0) return null;
            return try allocator.dupe(u8, slice);
        },
        .cancelled => return null,
    }
}

// ============================================================================
// Clipboard（TASK-73.3）— 色 #RRGGBB の text/plain
// ============================================================================

const ClipboardPasteState = enum { idle, requested, delivered };

var clipboard_paste_state: ClipboardPasteState = .idle;
/// paste テキスト固定スクラッチ（#RRGGBB 用途。長文は切り詰め）。
var clipboard_text_scratch: [64]u8 = undefined;
var clipboard_text_len: u32 = 0;

export fn vp_clipboard_text_scratch() [*]u8 {
    return &clipboard_text_scratch;
}

/// JS が readText 結果を scratch に書いたあと呼ぶ。
export fn vp_clipboard_text(len: u32) void {
    const n = @min(len, clipboard_text_scratch.len);
    clipboard_text_len = n;
    clipboard_paste_state = .delivered;
}

/// システム clipboard へ text を書く（wasm: Clipboard API。native は no-op 経路）。
pub fn clipboardWrite(text: []const u8) void {
    if (text.len == 0) return;
    if (builtin.is_test) return;
    vp_clipboard_write(text.ptr, @intCast(text.len));
}

/// paste を非同期要求。二重 request は無視。
pub fn clipboardRequestPaste() void {
    if (clipboard_paste_state == .requested) return;
    clipboard_paste_state = .requested;
    clipboard_text_len = 0;
    if (builtin.is_test) return;
    vp_request_paste();
}

/// 届いていれば text スライスを返し idle に戻す。未着は null。
pub fn clipboardTakePaste() ?[]const u8 {
    if (clipboard_paste_state != .delivered) return null;
    clipboard_paste_state = .idle;
    return clipboard_text_scratch[0..clipboard_text_len];
}

fn clipboardResetForTest() void {
    clipboard_paste_state = .idle;
    clipboard_text_len = 0;
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

// ---- TASK-73.3: open dialog 状態機械 / pick path / clipboard pending ----

/// App.runPendingFileOp の dialog_op latch 規約（修正1）を純ロジックで表現した tick。
/// `dialog_op` 優先、tick 冒頭で `pending` を破棄、pending 結果なら latch 維持。
fn dialogOpLatchTick(dialog_op: *?u8, pending: *?u8, result_pending: bool) ?u8 {
    const op = dialog_op.* orelse (pending.* orelse return null);
    // dialog 待ち中に積まれた別要求は破棄（picker 結果の誤配送防止）
    pending.* = null;
    if (result_pending) {
        dialog_op.* = op;
    } else {
        dialog_op.* = null;
    }
    return op;
}

test "dialog_op latch: pending 中の別 op 要求は破棄され dialog_op が維持される" {
    // 1=open, 2=save_as（App.FileOp の代理。platform_wasm から App を import しない）
    var dialog_op: ?u8 = null;
    var pending: ?u8 = null;

    // frame1: user open → DialogPending
    pending = 1;
    try std.testing.expectEqual(@as(?u8, 1), dialogOpLatchTick(&dialog_op, &pending, true));
    try std.testing.expectEqual(@as(?u8, 1), dialog_op);
    try std.testing.expectEqual(@as(?u8, null), pending);

    // 待ち中に save_as を要求（pending に積む）→ 次 tick で破棄され open が継続
    pending = 2;
    try std.testing.expectEqual(@as(?u8, 1), dialogOpLatchTick(&dialog_op, &pending, true));
    try std.testing.expectEqual(@as(?u8, 1), dialog_op);
    try std.testing.expectEqual(@as(?u8, null), pending);

    // picker 完了 → open 成功、dialog_op クリア。残留 pending 無し
    try std.testing.expectEqual(@as(?u8, 1), dialogOpLatchTick(&dialog_op, &pending, false));
    try std.testing.expectEqual(@as(?u8, null), dialog_op);
    try std.testing.expectEqual(@as(?u8, null), pending);

    // 完了後に初めて save_as が走れる
    pending = 2;
    try std.testing.expectEqual(@as(?u8, 2), dialogOpLatchTick(&dialog_op, &pending, false));
    try std.testing.expectEqual(@as(?u8, null), dialog_op);
    try std.testing.expectEqual(@as(?u8, null), pending);
}

test "open dialog machine: request → picked → take path → idle" {
    open_dialog.reset();
    defer open_dialog.reset();

    try std.testing.expectEqual(.request, open_dialog.onCall());
    try std.testing.expectEqual(OpenDialogState.requested, open_dialog.state);

    // request 中の再 call は pending（二重 request しない）
    try std.testing.expectEqual(.pending, open_dialog.onCall());
    try std.testing.expectEqual(OpenDialogState.requested, open_dialog.state);

    open_dialog.onPicked("pick/foo.png");
    try std.testing.expectEqual(OpenDialogState.picked, open_dialog.state);
    try std.testing.expectEqualStrings("pick/foo.png", open_dialog.takePathSlice());

    try std.testing.expectEqual(.take_path, open_dialog.onCall());
    try std.testing.expectEqual(OpenDialogState.idle, open_dialog.state);
}

test "open dialog machine: cancel → null 相当 → idle" {
    open_dialog.reset();
    defer open_dialog.reset();

    try std.testing.expectEqual(.request, open_dialog.onCall());
    open_dialog.onCancelled();
    try std.testing.expectEqual(OpenDialogState.cancelled, open_dialog.state);
    try std.testing.expectEqual(.cancelled, open_dialog.onCall());
    try std.testing.expectEqual(OpenDialogState.idle, open_dialog.state);
}

test "open dialog machine: pick/cancel は request 中以外無視" {
    open_dialog.reset();
    defer open_dialog.reset();

    open_dialog.onPicked("pick/x.png"); // idle 中は無視
    try std.testing.expectEqual(OpenDialogState.idle, open_dialog.state);
    open_dialog.onCancelled();
    try std.testing.expectEqual(OpenDialogState.idle, open_dialog.state);

    _ = open_dialog.onCall(); // → requested
    open_dialog.onPicked("pick/a.png");
    open_dialog.onPicked("pick/b.png"); // already picked: 無視
    try std.testing.expectEqualStrings("pick/a.png", open_dialog.takePathSlice());
}

test "openFileDialog: request→DialogPending / picked→path / cancel→null" {
    open_dialog.reset();
    defer open_dialog.reset();
    const a = std.testing.allocator;

    // 1st call: request + DialogPending
    try std.testing.expectError(error.DialogPending, openFileDialog(a, undefined, .{ .allowed_ext = "png" }));

    // 2nd call while waiting: still pending（二重 request 防止）
    try std.testing.expectError(error.DialogPending, openFileDialog(a, undefined, .{ .allowed_ext = "png" }));

    // simulate JS deliver
    const path_src = "pick/usako.png";
    @memcpy(file_path_scratch[0..path_src.len], path_src);
    vp_file_picked(@intCast(path_src.len));

    const got = try openFileDialog(a, undefined, .{ .allowed_ext = "png" });
    defer if (got) |p| a.free(p);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings(path_src, got.?);

    // cancel path
    try std.testing.expectError(error.DialogPending, openFileDialog(a, undefined, .{}));
    vp_file_cancelled();
    const cancelled = try openFileDialog(a, undefined, .{});
    try std.testing.expect(cancelled == null);
}

test "saveFileDialog: default_name を同期返却" {
    const a = std.testing.allocator;
    const got = try saveFileDialog(a, undefined, .{ .default_name = "untitled.png", .allowed_ext = "png" });
    defer if (got) |p| a.free(p);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("untitled.png", got.?);

    const got2 = try saveFileDialog(a, undefined, .{});
    defer if (got2) |p| a.free(p);
    try std.testing.expectEqualStrings("download.bin", got2.?);
}

test "makePickPath / basenameSanitize" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("pick/foo.png", makePickPath("foo.png", &buf));
    try std.testing.expectEqualStrings("pick/bar.pix", makePickPath("/tmp/evil/../bar.pix", &buf));
    try std.testing.expectEqualStrings("pick/file", makePickPath("..", &buf));
    try std.testing.expectEqualStrings("pick/file", makePickPath("", &buf));
    try std.testing.expectEqualStrings("pick/a.png", makePickPath("dir\\a.png", &buf));
}

test "clipboard paste machine: request → deliver → take → idle" {
    clipboardResetForTest();
    defer clipboardResetForTest();

    try std.testing.expect(clipboardTakePaste() == null);
    clipboardRequestPaste();
    try std.testing.expectEqual(ClipboardPasteState.requested, clipboard_paste_state);
    // 二重 request は state 維持
    clipboardRequestPaste();
    try std.testing.expectEqual(ClipboardPasteState.requested, clipboard_paste_state);

    const text = "#FF00AA";
    @memcpy(clipboard_text_scratch[0..text.len], text);
    vp_clipboard_text(@intCast(text.len));
    try std.testing.expectEqual(ClipboardPasteState.delivered, clipboard_paste_state);

    const got = clipboardTakePaste() orelse unreachable;
    try std.testing.expectEqualStrings(text, got);
    try std.testing.expectEqual(ClipboardPasteState.idle, clipboard_paste_state);
    try std.testing.expect(clipboardTakePaste() == null);
}
