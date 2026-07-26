//! The wasm32-wasi platform backend
//!
//! It connects to the JS glue (web/vp.js) through `extern "env"` and `export`.
//! The framebuffer is allocated with wasm_allocator, and present hands it to `vp_present` after a
//! BGRA→RGBA swizzle (pixelops SIMD). JS pushes input onto the queue with `vp_push_*`, and Zig drains it in nextEvent.
//!
//! Hot path declaration: the all-pixel swizzle in present runs every frame. Input and init happen at event time and at initialisation only.

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
// The JS import table (env)
// ============================================================================

extern "env" fn vp_now() f64;
extern "env" fn vp_present(ptr: [*]const u8, w: u32, h: u32) void;
extern "env" fn vp_log(ptr: [*]const u8, len: u32) void;
extern "env" fn vp_set_cursor(shape: c_int) void;
/// Fire the browser file picker (allowed_ext is a hint and may be empty). Both Zig and JS guard against firing it twice.
extern "env" fn vp_request_open(ext_ptr: [*]const u8, ext_len: u32) void;
/// `navigator.clipboard.writeText` (text/plain).
extern "env" fn vp_clipboard_write(ptr: [*]const u8, len: u32) void;
/// Start `navigator.clipboard.readText` asynchronously. The result arrives through `vp_clipboard_text`.
extern "env" fn vp_request_paste() void;

// ============================================================================
// A DOM KeyboardEvent.code → KeyCode (a pure data table on the Zig side, in the style of platform_linux_input)
// ============================================================================

const DomKeyEntry = struct { code: []const u8, key: KeyCode };

/// It covers the minimum the pixel editor uses: letters, digits, arrows, Space, Esc, Enter, Backspace, Tab and the modifiers.
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

/// The fixed scratch JS writes a KeyboardEvent.code string into (up to 32B, which a DOM code fits comfortably).
var dom_code_scratch: [32]u8 = undefined;

export fn vp_dom_code_scratch() [*]u8 {
    return &dom_code_scratch;
}

/// The DOM code written into scratch (len bytes) → a KeyCode (i32). Anything unknown is UNKNOWN(-1).
export fn vp_dom_code_to_keycode(len: u32) i32 {
    const n = @min(len, dom_code_scratch.len);
    return @intFromEnum(domCodeToKeyCode(dom_code_scratch[0..n]));
}

// ============================================================================
// The event queue (a fixed ring)
// ============================================================================

const QUEUE_CAP = 256;
var event_queue: [QUEUE_CAP]Event = undefined;
var queue_head: usize = 0;
var queue_tail: usize = 0;
var queue_len: usize = 0;

fn queuePush(ev: Event) void {
    if (queue_len >= QUEUE_CAP) {
        // On overflow the oldest is discarded (a drop)
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

/// A DOM `MouseEvent.button` → a `MouseButton`.
/// The input is the DOM's own range (0=left, 1=middle, 2=right), not the shared enum's discriminant.
/// `MouseButton` is left=0 / right=1 / middle=2, so the numbers of middle and right are swapped relative to the DOM.
fn buttonFromDom(b: i32) MouseButton {
    return switch (b) {
        0 => .left,
        1 => .middle, // DOM middle (≠ MouseButton.right = 1)
        2 => .right, // DOM right (≠ MouseButton.middle = 2)
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
    // Control characters are not emitted (the CharEvent contract of platform_types)
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
/// 0 = nothing pending. vp_resize sets it, and the top of the next lockFramebuffer applies it (at a frame boundary).
var pending_w: u32 = 0;
var pending_h: u32 = 0;
const default_gpa: std.mem.Allocator = if (builtin.cpu.arch.isWasm())
    std.heap.wasm_allocator
else
    std.heap.page_allocator;
/// A var so that a test can inject an OOM (in production it is fixed to default_gpa, and used only at init and resize).
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

/// Called from the JS ResizeObserver. It keeps the value pending, rather than swapping the buffer mid-frame.
export fn vp_resize(w: u32, h: u32) void {
    const c = clampResizeDim(w, h);
    pending_w = c.w;
    pending_h = c.h;
}

/// On failure it returns with the pending value still held (the old framebuffer is untouched, thanks to
/// the two-phase allocation, so drawing continues at the old size and the next lockFramebuffer retries).
fn applyPendingResize() void {
    if (pending_w == 0 or pending_h == 0) return;
    ensureFramebuffer(pending_w, pending_h) catch return;
    pending_w = 0;
    pending_h = 0;
}

fn ensureFramebuffer(w: u32, h: u32) Error!void {
    const n = @as(usize, w) * @as(usize, h);
    if (pixels_buf.len == n and fb_w == w and fb_h == h) return;

    // A two-phase commit: the old buffers are freed only once both new buffers have been allocated.
    // A failure part way through leaves the old framebuffer untouched (drawing continues at the old size even after an OOM).
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

    /// Transparency, borderless and an explicit size. wasm has no display position, so position is ignored.
    /// transparent and borderless mean little on a DOM canvas either, but they are accepted so that the size can be overridden.
    pub fn createWithOptions(width: u32, height: u32, title: [:0]const u8, opts: types.WindowOptions) Error!Window {
        _ = opts.transparent;
        _ = opts.borderless;
        _ = opts.position;
        const w = if (opts.size) |s| s.width else width;
        const h = if (opts.size) |s| s.height else height;
        return create(w, h, title);
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
        const size: types.WindowSize = .{ .width = fb_w, .height = fb_h };
        return .{
            .pixels = pixels_buf,
            .width = fb_w,
            .height = fb_h,
            .logical_size = size,
            .framebuffer_size = size,
            .content_scale = 1.0,
            .scale_epoch = 0,
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

    /// wasm has no OS window title, so this is a no-op.
    pub fn setTitle(_: Window, _: [:0]const u8) void {}

    /// The live-resize redraw callback. A browser has no OS modal loop and rAF keeps running during a
    /// resize, so this is a no-op stub (the same shape as X11 and Wayland).
    pub fn setRedrawCallback(self: Window, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque) void) void {
        _ = self;
        _ = ctx;
        _ = cb;
    }

    /// The private clear path used by destroy (a no-op).
    pub fn clearRedrawCallback(self: Window) void {
        _ = self;
    }

    pub fn getGamepadState(_: Window, _: u8) ?types.GamepadState {
        return null;
    }

    /// The IME composition snapshot. A web IME is separate work, so this is always empty.
    pub fn getCompositionSnapshot(_: Window, buf: []u8) types.CompositionSnapshot {
        return .{ .text = buf[0..0], .revision = 0, .cursor = 0 };
    }
};

/// The current window geometry. wasm has no position, and the size is the current framebuffer's.
/// Module level (the facade's `@hasDecl` contract).
pub fn getGeometry(win: Window) types.WindowGeometry {
    _ = win;
    return .{
        .position = null,
        .size = .{ .width = fb_w, .height = fb_h },
    };
}

pub const Framebuffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    logical_size: types.WindowSize,
    framebuffer_size: types.WindowSize,
    content_scale: f32,
    scale_epoch: u64,

    pub fn unlock(_: Framebuffer) void {}
};

pub fn init() Error!void {}

pub fn shutdown() void {}

pub fn getTime() f64 {
    return vp_now();
}

// ============================================================================
// File dialogs: the path model is kept, over a JS in-memory FS
// ============================================================================
//
// open: asynchronous (the browser file picker). Before anything is picked it gives DialogPending, and a later call returns the path.
// save: it returns default_name synchronously (the actual saving is a WASI write → the JS memfs → a Blob download).
// A second open while a request is outstanding does not fire the picker twice and stays DialogPending.

/// The pending state machine of the open dialog (DOM independent, and unit tested).
const OpenDialogState = enum { idle, requested, picked, cancelled };

const OpenDialogMachine = struct {
    state: OpenDialogState = .idle,
    path_buf: [256]u8 = undefined,
    path_len: u32 = 0,

    /// The transition made by a call to openFileDialog. Only `.request` fires the JS picker.
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

    /// When JS delivers a path through scratch. It is ignored unless a request is outstanding (which prevents a second request).
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

/// The virtual path of a pick: `pick/<basename>` (a basename with any path traversal removed).
/// The return value is a slice of `out`. An empty name gives `pick/file`.
fn makePickPath(name: []const u8, out: []u8) []const u8 {
    const base = basenameSanitize(name);
    const prefix = "pick/";
    const n = @min(base.len, out.len -| prefix.len);
    if (out.len < prefix.len) return out[0..0];
    @memcpy(out[0..prefix.len], prefix);
    if (n > 0) @memcpy(out[prefix.len..][0..n], base[0..n]);
    return out[0 .. prefix.len + n];
}

/// It strips `/` and `\`, and turns `.` and `..` into `file`.
fn basenameSanitize(name: []const u8) []const u8 {
    var s = name;
    // drop a trailing path separator
    while (s.len > 0 and (s[s.len - 1] == '/' or s[s.len - 1] == '\\')) s = s[0 .. s.len - 1];
    // everything after the last separator
    if (std.mem.lastIndexOfAny(u8, s, "/\\")) |i| s = s[i + 1 ..];
    if (s.len == 0 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return "file";
    return s;
}

var open_dialog: OpenDialogMachine = .{};

/// The fixed scratch JS writes a picked path string into (up to 256B).
var file_path_scratch: [256]u8 = undefined;

export fn vp_file_path_scratch() [*]u8 {
    return &file_path_scratch;
}

/// Deliver the virtual path written into scratch (len bytes) to the open state machine, making it picked.
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
        // JS reads len=0 as "no filter" and never reads ptr.
        vp_request_open(@as([*]const u8, @ptrFromInt(1)), 0);
    } else {
        vp_request_open(ext.ptr, @intCast(ext.len));
    }
}

pub fn saveFileDialog(allocator: std.mem.Allocator, _: std.Io, opts: SaveDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    // Synchronous: the browser's download UI decides where it goes, so default_name is returned as the path.
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
// Clipboard: the text/plain of a #RRGGBB colour
// ============================================================================

const ClipboardPasteState = enum { idle, requested, delivered };

var clipboard_paste_state: ClipboardPasteState = .idle;
/// The fixed scratch for pasted text (it is for #RRGGBB, so anything long is truncated).
var clipboard_text_scratch: [64]u8 = undefined;
var clipboard_text_len: u32 = 0;

export fn vp_clipboard_text_scratch() [*]u8 {
    return &clipboard_text_scratch;
}

/// Called after JS has written the readText result into scratch.
export fn vp_clipboard_text(len: u32) void {
    const n = @min(len, clipboard_text_scratch.len);
    clipboard_text_len = n;
    clipboard_paste_state = .delivered;
}

/// Write text to the system clipboard (on wasm, the Clipboard API; on native this path is a no-op).
pub fn clipboardWrite(text: []const u8) void {
    if (text.len == 0) return;
    if (builtin.is_test) return;
    vp_clipboard_write(text.ptr, @intCast(text.len));
}

/// Request a paste asynchronously. A second request is ignored.
pub fn clipboardRequestPaste() void {
    if (clipboard_paste_state == .requested) return;
    clipboard_paste_state = .requested;
    clipboard_text_len = 0;
    if (builtin.is_test) return;
    vp_request_paste();
}

/// Return the text slice once it has arrived and go back to idle. Not yet arrived gives null.
pub fn clipboardTakePaste() ?[]const u8 {
    if (clipboard_paste_state != .delivered) return null;
    clipboard_paste_state = .idle;
    return clipboard_text_scratch[0..clipboard_text_len];
}

fn clipboardResetForTest() void {
    clipboard_paste_state = .idle;
    clipboard_text_len = 0;
}

/// Logging for freestanding (expected to be called from std_options.logFn).
pub fn logMessage(msg: []const u8) void {
    if (msg.len == 0) return;
    vp_log(msg.ptr, @intCast(msg.len));
}

test "buttonFromDom: a DOM MouseEvent.button → a MouseButton" {
    // DOM: 0=left, 1=middle, 2=right (the JS buttonIndex passes this range)
    try std.testing.expectEqual(MouseButton.left, buttonFromDom(0));
    try std.testing.expectEqual(MouseButton.middle, buttonFromDom(1));
    try std.testing.expectEqual(MouseButton.right, buttonFromDom(2));
    try std.testing.expectEqual(MouseButton.none, buttonFromDom(-1));
    try std.testing.expectEqual(MouseButton.none, buttonFromDom(3));
}

test "domCodeToKeyCode: the minimum keys the pixel editor needs" {
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

test "vp_resize: lockFramebuffer applies the new size" {
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

test "vp_resize: with several calls, the last value wins" {
    testResetFramebufferState();
    defer testResetFramebufferState();

    vp_resize(400, 300);
    vp_resize(500, 400);
    vp_resize(640, 480);
    try std.testing.expectEqual(@as(u32, 640), pending_w);
    try std.testing.expectEqual(@as(u32, 480), pending_h);
}

test "vp_resize: clamped to a minimum of 320x240 and a maximum of 8192" {
    testResetFramebufferState();
    defer testResetFramebufferState();

    vp_resize(10, 10);
    try std.testing.expectEqual(@as(u32, 320), pending_w);
    try std.testing.expectEqual(@as(u32, 240), pending_h);

    vp_resize(10000, 10000);
    try std.testing.expectEqual(@as(u32, 8192), pending_w);
    try std.testing.expectEqual(@as(u32, 8192), pending_h);
}

test "vp_resize: on an OOM the old framebuffer survives and the pending value is kept for a retry" {
    testResetFramebufferState();
    defer testResetFramebufferState();

    var win = try Window.create(320, 240, "t");
    defer win.destroy();

    // make every later alloc fail (two-phase, so the old buffers should be untouched)
    var failing = std.testing.FailingAllocator.init(default_gpa, .{ .fail_index = 0 });
    gpa = failing.allocator();

    vp_resize(640, 480);
    const fb = win.lockFramebuffer() orelse unreachable; // drawing continues on the old framebuffer
    try std.testing.expectEqual(@as(u32, 320), fb.width);
    try std.testing.expectEqual(@as(u32, 240), fb.height);
    try std.testing.expectEqual(@as(u32, 640), pending_w); // the pending value is kept (it is what gets retried)
    try std.testing.expectEqual(@as(u32, 480), pending_h);

    // once alloc recovers, the next lockFramebuffer applies it
    gpa = default_gpa;
    const fb2 = win.lockFramebuffer() orelse unreachable;
    try std.testing.expectEqual(@as(u32, 640), fb2.width);
    try std.testing.expectEqual(@as(u32, 480), fb2.height);
    try std.testing.expectEqual(@as(u32, 0), pending_w);
}

test "vp_resize: the framebuffer keeps its old size while the pending value is unconsumed" {
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

// ---- the open dialog state machine, the picked path, and the clipboard pending state ----

/// A tick expressing the dialog_op latch rule of App.runPendingFileOp as pure logic.
/// `dialog_op` wins, `pending` is discarded at the top of a tick, and a pending result keeps the latch.
fn dialogOpLatchTick(dialog_op: *?u8, pending: *?u8, result_pending: bool) ?u8 {
    const op = dialog_op.* orelse (pending.* orelse return null);
    // Another request queued while a dialog is outstanding is discarded (which prevents the picker's result being delivered to the wrong one)
    pending.* = null;
    if (result_pending) {
        dialog_op.* = op;
    } else {
        dialog_op.* = null;
    }
    return op;
}

test "dialog_op latch: another op requested while one is pending is discarded, and dialog_op is kept" {
    // 1=open, 2=save_as (standing in for App.FileOp; platform_wasm does not import App)
    var dialog_op: ?u8 = null;
    var pending: ?u8 = null;

    // frame1: user open → DialogPending
    pending = 1;
    try std.testing.expectEqual(@as(?u8, 1), dialogOpLatchTick(&dialog_op, &pending, true));
    try std.testing.expectEqual(@as(?u8, 1), dialog_op);
    try std.testing.expectEqual(@as(?u8, null), pending);

    // save_as is requested while waiting (queued as pending) → the next tick discards it and open continues
    pending = 2;
    try std.testing.expectEqual(@as(?u8, 1), dialogOpLatchTick(&dialog_op, &pending, true));
    try std.testing.expectEqual(@as(?u8, 1), dialog_op);
    try std.testing.expectEqual(@as(?u8, null), pending);

    // the picker finished → open succeeded and dialog_op is cleared. Nothing is left pending
    try std.testing.expectEqual(@as(?u8, 1), dialogOpLatchTick(&dialog_op, &pending, false));
    try std.testing.expectEqual(@as(?u8, null), dialog_op);
    try std.testing.expectEqual(@as(?u8, null), pending);

    // only once that is done can save_as run
    pending = 2;
    try std.testing.expectEqual(@as(?u8, 2), dialogOpLatchTick(&dialog_op, &pending, false));
    try std.testing.expectEqual(@as(?u8, null), dialog_op);
    try std.testing.expectEqual(@as(?u8, null), pending);
}

test "open dialog machine: request → picked → take the path → idle" {
    open_dialog.reset();
    defer open_dialog.reset();

    try std.testing.expectEqual(.request, open_dialog.onCall());
    try std.testing.expectEqual(OpenDialogState.requested, open_dialog.state);

    // a second call while a request is outstanding is pending (no second request)
    try std.testing.expectEqual(.pending, open_dialog.onCall());
    try std.testing.expectEqual(OpenDialogState.requested, open_dialog.state);

    open_dialog.onPicked("pick/foo.png");
    try std.testing.expectEqual(OpenDialogState.picked, open_dialog.state);
    try std.testing.expectEqualStrings("pick/foo.png", open_dialog.takePathSlice());

    try std.testing.expectEqual(.take_path, open_dialog.onCall());
    try std.testing.expectEqual(OpenDialogState.idle, open_dialog.state);
}

test "open dialog machine: cancel → the equivalent of null → idle" {
    open_dialog.reset();
    defer open_dialog.reset();

    try std.testing.expectEqual(.request, open_dialog.onCall());
    open_dialog.onCancelled();
    try std.testing.expectEqual(OpenDialogState.cancelled, open_dialog.state);
    try std.testing.expectEqual(.cancelled, open_dialog.onCall());
    try std.testing.expectEqual(OpenDialogState.idle, open_dialog.state);
}

test "open dialog machine: a pick or cancel is ignored unless a request is outstanding" {
    open_dialog.reset();
    defer open_dialog.reset();

    open_dialog.onPicked("pick/x.png"); // ignored while idle
    try std.testing.expectEqual(OpenDialogState.idle, open_dialog.state);
    open_dialog.onCancelled();
    try std.testing.expectEqual(OpenDialogState.idle, open_dialog.state);

    _ = open_dialog.onCall(); // → requested
    open_dialog.onPicked("pick/a.png");
    open_dialog.onPicked("pick/b.png"); // already picked: ignored
    try std.testing.expectEqualStrings("pick/a.png", open_dialog.takePathSlice());
}

test "openFileDialog: request→DialogPending / picked→the path / cancel→null" {
    open_dialog.reset();
    defer open_dialog.reset();
    const a = std.testing.allocator;

    // 1st call: request + DialogPending
    try std.testing.expectError(error.DialogPending, openFileDialog(a, undefined, .{ .allowed_ext = "png" }));

    // a 2nd call while waiting: still pending (which prevents a second request)
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

test "saveFileDialog: default_name is returned synchronously" {
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
    // a second request leaves the state as it is
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
