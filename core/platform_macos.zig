//! macOS native platform backend
//!
//! The layer that turns the C API (`platform/platform.h`) into a high-level Zig interface.
//! It confines `@cImport` inside itself and exposes nothing but Zig-native types to a caller.
//!
//! `platform_types.zig` is the canonical source of the public types (KeyCode, Event and friends), and
//! this file provides the translation that builds them out of C values, plus `Window`/`Framebuffer` and the functions.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("platform_types");
const command_types = @import("command_types");
const build_options = @import("build_options");

const c = @cImport({
    @cInclude("platform.h");
});

// platform.h keeps the older public C surface, and the quit cancel is an extra ABI belonging to this
// backend alone, whose symbol the native implementations (objc/swift/metal) provide under the same name.
extern fn platform_cancel_quit(window: *c.PlatformWindow) void;

/// The menu C symbols are referenced only with enable_menu and a macOS native backend
/// (objc/swift/metal), which structurally prevents an undefined symbol in an executable without them.
const menu_c_abi = build_options.enable_menu and (std.mem.eql(u8, build_options.platform_backend, "objc") or
    std.mem.eql(u8, build_options.platform_backend, "swift") or
    std.mem.eql(u8, build_options.platform_backend, "metal"));

const MenuC = if (menu_c_abi) struct {
    extern fn platform_menu_available() bool;
    extern fn platform_register_menu(window: ?*c.PlatformWindow, items: [*]const c.PlatformMenuItem, count: u32) void;
    extern fn platform_update_menu(window: ?*c.PlatformWindow, items: [*]const c.PlatformMenuItem, count: u32) void;
    extern fn platform_destroy_menu(window: ?*c.PlatformWindow) void;
} else struct {};

/// The text clipboard C symbols are implemented by all three macOS backends (objc/swift/metal).
/// A unit test (`builtin.is_test`) references no C symbol
/// (the facade's in-memory fallback stands in), which prevents an undefined symbol at link time.
/// It is false on Linux and Windows, and on a macOS backend without support.
const clipboard_c_abi = !builtin.is_test and builtin.os.tag == .macos and
    (std.mem.eql(u8, build_options.platform_backend, "objc") or
        std.mem.eql(u8, build_options.platform_backend, "swift") or
        std.mem.eql(u8, build_options.platform_backend, "metal"));

const ClipboardC = if (clipboard_c_abi) struct {
    extern fn platform_set_clipboard_text(utf8: [*]const u8, len: u32) void;
    extern fn platform_get_clipboard_text(out: [*]u8, cap: u32, out_len: *u32) bool;
} else struct {};

/// The text input focus control C symbol is implemented by all three macOS backends (objc/swift/metal).
/// A unit test references no C symbol (which prevents an undefined symbol at link time).
const text_input_c_abi = !builtin.is_test;

const TextInputC = if (text_input_c_abi) struct {
    extern fn platform_set_text_input_active(window: ?*c.PlatformWindow, active: bool) void;
    extern fn platform_set_text_input_document_access(
        window: ?*c.PlatformWindow,
        callbacks: ?*const c.PlatformTextInputDocumentCallbacks,
        userdata: ?*anyopaque,
    ) void;
} else struct {};

// Aliases of the shared types (platform_types.zig is canonical; these merely keep the signatures short)
const Error = types.Error;
const KeyCode = types.KeyCode;
const ModifierFlags = types.ModifierFlags;
const MouseButton = types.MouseButton;
const MouseButtons = types.MouseButtons;
const KeyEvent = types.KeyEvent;
const CharEvent = types.CharEvent;
const CompositionEvent = types.CompositionEvent;
const CompositionPhase = types.CompositionPhase;
const CompositionSnapshot = types.CompositionSnapshot;
const TextInputRange = types.TextInputRange;
const TextInputSubstring = types.TextInputSubstring;
const TEXT_INPUT_RANGE_NOT_FOUND = types.TEXT_INPUT_RANGE_NOT_FOUND;
const MouseEvent = types.MouseEvent;
const ScrollEvent = types.ScrollEvent;
const Event = types.Event;
const EventStats = types.EventStats;
const SaveDialogOptions = types.SaveDialogOptions;
const OpenDialogOptions = types.OpenDialogOptions;
const DialogError = types.DialogError;
const CursorShape = types.CursorShape;
const GamepadState = types.GamepadState;
const GamepadButtons = types.GamepadButtons;
const GamepadInfo = types.GamepadInfo;
const GamepadDisconnect = types.GamepadDisconnect;
const GAMEPAD_NAME_MAX = types.GAMEPAD_NAME_MAX;
const Command = command_types.Command;

pub fn init() Error!void {
    if (!c.platform_init()) return error.InitFailed;
}

pub fn shutdown() void {
    c.platform_shutdown();
}

pub fn getTime() f64 {
    return c.platform_get_time();
}

/// Native display refresh in Hz, or null on failure / non-positive / non-finite.
/// Queried once at startup (event-time), never per frame.
pub fn displayRefreshHz() ?f64 {
    const hz = c.platform_display_refresh_hz();
    if (!std.math.isFinite(hz) or !(hz > 0)) return null;
    return hz;
}

/// Show or hide the Dock icon and the menu bar (application-wide, not per window).
/// visible=false selects accessory (behaving like a background app). Initialisation and event time only.
pub fn setDockVisible(visible: bool) void {
    c.platform_set_dock_visible(visible);
}

// ============================================================================
// From C values to the shared types
// ============================================================================

inline fn keyFromC(raw: c.PlatformKeyCode) KeyCode {
    return @enumFromInt(@as(c_int, raw));
}

inline fn buttonFromC(raw: c.PlatformMouseButton) MouseButton {
    return @enumFromInt(@as(c_int, @intCast(raw)));
}

inline fn makeKeyEvent(ev: c.PlatformEvent) KeyEvent {
    return .{
        .key = keyFromC(ev.payload.keyboard.key),
        .is_repeat = ev.payload.keyboard.is_repeat,
        .modifiers = ModifierFlags.fromC(ev.payload.keyboard.modifiers),
    };
}

inline fn makeMouseEvent(ev: c.PlatformEvent) MouseEvent {
    return .{
        .x = ev.payload.mouse.x,
        .y = ev.payload.mouse.y,
        .button = buttonFromC(ev.payload.mouse.button),
        .buttons = MouseButtons.fromC(ev.payload.mouse.buttons_mask),
        .modifiers = ModifierFlags.fromC(ev.payload.mouse.modifiers),
    };
}

inline fn makeScrollEvent(ev: c.PlatformEvent) ScrollEvent {
    return .{
        .x = ev.payload.scroll.x,
        .y = ev.payload.scroll.y,
        .dx = ev.payload.scroll.dx,
        .dy = ev.payload.scroll.dy,
        .is_precise = ev.payload.scroll.is_precise,
        .buttons = MouseButtons.fromC(ev.payload.scroll.buttons_mask),
        .modifiers = ModifierFlags.fromC(ev.payload.scroll.modifiers),
    };
}

inline fn makeCharEvent(ev: c.PlatformEvent) CharEvent {
    return .{
        .codepoint = ev.payload.character.codepoint,
        .modifiers = ModifierFlags.fromC(ev.payload.character.modifiers),
    };
}

inline fn makeCompositionEvent(ev: c.PlatformEvent) CompositionEvent {
    return .{
        .revision = ev.payload.composition.revision,
        .phase = @as(CompositionPhase, @enumFromInt(ev.payload.composition.phase)),
        .cursor = ev.payload.composition.cursor,
    };
}

/// C `PLATFORM_EVENT_FILE_DROP` → Zig `Event.file_drop`. Anything invalid gives null (the event is dropped).
fn makeFileDropEvent(ev: c.PlatformEvent) ?Event {
    const fd = ev.payload.file_drop;
    if (fd.count != 1) return null;
    if (fd.paths[0].len > types.FILE_DROP_PATH_BYTES) return null;
    const len: usize = fd.paths[0].len;
    const path = fd.paths[0].bytes[0..len];
    const drop = types.makeFileDropEventFromPath(path) orelse return null;
    return .{ .file_drop = drop };
}

inline fn isFacadeSkipEvent(raw: c.PlatformEventType) bool {
    return raw == c.PLATFORM_EVENT_NONE;
}

test "macOS facade NONE skip: the wrap boundary is crossed while FIFO order holds" {
    try std.testing.expect(isFacadeSkipEvent(c.PLATFORM_EVENT_NONE));
    try std.testing.expect(!isFacadeSkipEvent(c.PLATFORM_EVENT_KEY_DOWN));
    var index: usize = 254;
    index = (index + 1) % 256;
    try std.testing.expectEqual(@as(usize, 255), index);
    index = (index + 1) % 256;
    try std.testing.expectEqual(@as(usize, 0), index);
    index = (index + 1) % 256;
    try std.testing.expectEqual(@as(usize, 1), index);
}

test "document access trampoline: registering and unregistering (a unit test links no C)" {
    var dummy: u8 = 0;
    const win: Window = .{ .handle = undefined };
    const cbs = TextInputDocumentCallbacks{
        .getSelectedRange = struct {
            fn f(_: *anyopaque) ?TextInputRange {
                return .{ .location = 0, .length = 0 };
            }
        }.f,
        .getSubstring = struct {
            fn f(_: *anyopaque, _: TextInputRange) ?TextInputSubstring {
                return null;
            }
        }.f,
        .replaceText = struct {
            fn f(_: *anyopaque, _: TextInputRange, _: []const u8) bool {
                return false;
            }
        }.f,
    };
    try std.testing.expect(!textInputDocumentAccessRegisteredForTest());
    win.setTextInputDocumentAccess(@ptrCast(&dummy), cbs);
    try std.testing.expect(textInputDocumentAccessRegisteredForTest());
    try std.testing.expectEqual(TEXT_INPUT_RANGE_NOT_FOUND, textInputRangeNotFoundForTest());
    win.setTextInputDocumentAccess(@ptrCast(&dummy), null);
    try std.testing.expect(!textInputDocumentAccessRegisteredForTest());
}

/// Copy C's `gamepad.name` (a fixed buffer of 32 bytes plus NUL) into `GamepadInfo.name_buf`.
/// The valid length runs to the NUL, as `strlen` would have it, and anything past `GAMEPAD_NAME_MAX` is truncated
/// (the backend has already truncated it, so this does not normally happen; the bound is kept here defensively).
inline fn makeGamepadInfo(ev: c.PlatformEvent) GamepadInfo {
    var info = GamepadInfo{ .index = @intCast(ev.payload.gamepad.index) };
    const raw_name: [*:0]const u8 = @ptrCast(&ev.payload.gamepad.name);
    const len = @min(std.mem.len(raw_name), GAMEPAD_NAME_MAX);
    @memcpy(info.name_buf[0..len], raw_name[0..len]);
    info.name_len = @intCast(len);
    return info;
}

inline fn makeGamepadDisconnect(ev: c.PlatformEvent) GamepadDisconnect {
    return .{ .index = @intCast(ev.payload.gamepad.index) };
}

var key_trace_state: ?bool = null;
var ime_trace_state: ?bool = null;

fn keyTraceEnabled() bool {
    if (key_trace_state) |enabled| return enabled;
    const enabled = if (std.c.getenv("KNGN_KEY_TRACE")) |value|
        std.mem.eql(u8, std.mem.span(value), "1")
    else
        false;
    key_trace_state = enabled;
    return enabled;
}

fn imeTraceEnabled() bool {
    if (ime_trace_state) |enabled| return enabled;
    const enabled = if (std.c.getenv("KNGN_IME_TRACE")) |value|
        std.mem.eql(u8, std.mem.span(value), "1")
    else
        false;
    ime_trace_state = enabled;
    return enabled;
}

fn traceFacadeEvent(ev: Event) void {
    if (!keyTraceEnabled()) return;
    switch (ev) {
        .key_down => |k| std.debug.print("[key-trace] facade key_down key={d} repeat={d} mods=0x{X}\n", .{ @intFromEnum(k.key), @intFromBool(k.is_repeat), k.modifiers.toC() }),
        .key_up => |k| std.debug.print("[key-trace] facade key_up key={d} mods=0x{X}\n", .{ @intFromEnum(k.key), k.modifiers.toC() }),
        .char_input => |ch| std.debug.print("[key-trace] facade char_input cp=U+{X} mods=0x{X}\n", .{ ch.codepoint, ch.modifiers.toC() }),
        .composition_changed => |co| std.debug.print("[key-trace] facade composition phase={s} rev={d} cursor={d}\n", .{ @tagName(co.phase), co.revision, co.cursor }),
        else => {},
    }
}

// ============================================================================
// The live-resize redraw trampoline
// ============================================================================
//
// The C ABI's `PlatformRedrawCallback` has to be `callconv(.c)`, so the Zig `RedrawFn` handed over by
// the facade is kept at module level and called from a C trampoline. A single window is assumed.

pub const RedrawFn = *const fn (ctx: *anyopaque) void;

var redraw_trampoline: struct {
    ctx: *anyopaque = undefined,
    cb: ?RedrawFn = null,
} = .{};

fn macosRedrawTrampoline(userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    const cb = redraw_trampoline.cb orelse return;
    cb(redraw_trampoline.ctx);
}

// ============================================================================
// The IME document access trampolines
// ============================================================================
//
// A C ABI callback is callconv(.c). The Zig consumer's function pointers are kept at module level and
// called synchronously from a C trampoline. A single window is assumed (the same shape as redraw).

pub const TextInputDocumentCallbacks = types.TextInputDocumentCallbacks;

var doc_access_trampoline: struct {
    userdata: *anyopaque = undefined,
    callbacks: ?TextInputDocumentCallbacks = null,
} = .{};

fn docAccessGetSelectedRange(userdata: ?*anyopaque, out_range: ?*c.PlatformTextInputRange) callconv(.c) bool {
    _ = userdata;
    const out = out_range orelse return false;
    const cbs = doc_access_trampoline.callbacks orelse return false;
    const range = cbs.getSelectedRange(doc_access_trampoline.userdata) orelse {
        if (imeTraceEnabled()) std.debug.print("[ime-trace] doc.get_selected_range -> null\n", .{});
        return false;
    };
    out.* = .{ .location = range.location, .length = range.length };
    if (imeTraceEnabled()) {
        std.debug.print("[ime-trace] doc.get_selected_range -> {{{d},{d}}}\n", .{ range.location, range.length });
    }
    return true;
}

fn docAccessGetSubstring(
    userdata: ?*anyopaque,
    proposed_range: c.PlatformTextInputRange,
    out_utf8: ?*?[*]const u8,
    out_len: ?*u32,
    out_actual_range: ?*c.PlatformTextInputRange,
) callconv(.c) bool {
    _ = userdata;
    const utf8_slot = out_utf8 orelse return false;
    const len_slot = out_len orelse return false;
    const actual_slot = out_actual_range orelse return false;
    const cbs = doc_access_trampoline.callbacks orelse return false;
    const proposed: TextInputRange = .{ .location = proposed_range.location, .length = proposed_range.length };
    const sub = cbs.getSubstring(doc_access_trampoline.userdata, proposed) orelse {
        if (imeTraceEnabled()) {
            std.debug.print("[ime-trace] doc.get_substring proposed={{{d},{d}}} -> null\n", .{ proposed.location, proposed.length });
        }
        return false;
    };
    // The .ptr of an empty slice can be undefined, so a length of 0 returns a static empty buffer.
    utf8_slot.* = if (sub.utf8.len == 0) @ptrCast(&empty_doc_utf8) else sub.utf8.ptr;
    len_slot.* = @intCast(sub.utf8.len);
    actual_slot.* = .{ .location = sub.actual_range.location, .length = sub.actual_range.length };
    if (imeTraceEnabled()) {
        const preview_len = @min(sub.utf8.len, 20);
        std.debug.print("[ime-trace] doc.get_substring proposed={{{d},{d}}} actual={{{d},{d}}} len={d} text=\"{s}\"\n", .{
            proposed.location,
            proposed.length,
            sub.actual_range.location,
            sub.actual_range.length,
            sub.utf8.len,
            sub.utf8[0..preview_len],
        });
    }
    return true;
}

fn docAccessReplaceText(
    userdata: ?*anyopaque,
    replacement_range: c.PlatformTextInputRange,
    utf8: ?[*]const u8,
    len: u32,
) callconv(.c) bool {
    _ = userdata;
    const cbs = doc_access_trampoline.callbacks orelse return false;
    const range: TextInputRange = .{ .location = replacement_range.location, .length = replacement_range.length };
    const slice: []const u8 = if (utf8) |p| p[0..len] else &.{};
    const ok = cbs.replaceText(doc_access_trampoline.userdata, range, slice);
    if (imeTraceEnabled()) {
        const preview_len = @min(slice.len, 20);
        std.debug.print("[ime-trace] doc.replace_text range={{{d},{d}}} len={d} text=\"{s}\" ok={}\n", .{
            range.location,
            range.length,
            slice.len,
            slice[0..preview_len],
            ok,
        });
    }
    return ok;
}

const doc_access_c_callbacks = c.PlatformTextInputDocumentCallbacks{
    .get_selected_range = docAccessGetSelectedRange,
    .get_substring = docAccessGetSubstring,
    .replace_text = docAccessReplaceText,
};

/// A stable pointer for an empty substring (never a stack temporary).
const empty_doc_utf8: [1]u8 = .{0};

/// For unit tests: whether document access is registered with the facade.
pub fn textInputDocumentAccessRegisteredForTest() bool {
    return doc_access_trampoline.callbacks != null;
}

/// For unit tests: the NOT_FOUND sentinel (matching the C ABI).
pub fn textInputRangeNotFoundForTest() u64 {
    return TEXT_INPUT_RANGE_NOT_FOUND;
}

fn clearDocumentAccess() void {
    doc_access_trampoline = .{};
}

// ============================================================================
// Window / Framebuffer
// ============================================================================

pub const Window = struct {
    handle: *c.PlatformWindow,

    /// The single window creation entry point of this backend (ADR-019 R1), carrying the
    /// transparency, borderless, position, framebuffer-mode and fullscreen options. Unknown flags
    /// make the C side return NULL (→ WindowCreationFailed). Transparency assumes premultiplied
    /// alpha.
    ///
    /// Fullscreen is **composed on this side** out of two entry points the C ABI already has — the
    /// extended creation call, which carries the option flags, and the fullscreen call
    /// (`NSWindow toggleFullScreen:`) — so no native implementation changes (ADR-019 R7). The
    /// requested size is a placeholder valid only for the instant before the transition, which is
    /// asynchronous; the real size becomes the screen resolution and the framebuffer follows
    /// through the existing frame-size path, so an application follows `fb.width`/`fb.height`
    /// (ADR-019 R3).
    /// Hot path declaration: initialisation only (a single window creation).
    pub fn createWithOptions(width: u32, height: u32, title: [:0]const u8, opts: types.WindowOptions) Error!Window {
        var flags: u32 = 0;
        if (opts.transparent) flags |= c.PLATFORM_WINDOW_TRANSPARENT;
        if (opts.borderless) flags |= c.PLATFORM_WINDOW_BORDERLESS;
        if (opts.fb_mode == .physical) flags |= c.PLATFORM_WINDOW_FRAMEBUFFER_PHYSICAL;
        if (!opts.resizable) flags |= c.PLATFORM_WINDOW_NOT_RESIZABLE;
        var copts = c.PlatformWindowOptions{ .flags = flags, .reserved = 0, .x = 0, .y = 0 };
        if (opts.position) |pos| {
            copts.flags |= c.PLATFORM_WINDOW_POSITION;
            copts.x = pos.x;
            copts.y = pos.y;
        }
        const w = c.platform_create_window_ex(
            @intCast(width),
            @intCast(height),
            title.ptr,
            null,
            null,
            &copts,
        ) orelse return error.WindowCreationFailed;
        if (opts.fullscreen) c.platform_enter_fullscreen(w);
        return .{ .handle = w };
    }

    /// Update the title of the visible OS window. Called only at an event boundary.
    pub fn setTitle(self: Window, title: [:0]const u8) void {
        c.platform_set_title(self.handle, title.ptr);
    }

    /// Start the OS's interactive window move from the most recent pointer press. Event time only.
    pub fn beginDrag(self: Window) void {
        c.platform_begin_window_drag(self.handle);
    }

    /// Set always-on-top. Event time only.
    pub fn setAlwaysOnTop(self: Window, on: bool) void {
        c.platform_set_always_on_top(self.handle, on);
    }

    /// Set per-pixel click-through, letting a click over a transparent pixel fall through to what is behind.
    pub fn setClickThrough(self: Window, on: bool) void {
        c.platform_set_click_through(self.handle, on);
    }

    /// Pop up a quit menu (choosing it pushes quit onto the window's event queue).
    pub fn showQuitMenu(self: Window) void {
        c.platform_show_quit_menu(self.handle);
    }

    pub fn destroy(self: Window) void {
        // Unregister document access (which prevents a dangling userdata; the native side discards its pending range too).
        if (comptime text_input_c_abi) {
            TextInputC.platform_set_text_input_document_access(self.handle, null, null);
        }
        clearDocumentAccess();
        c.platform_destroy_window(self.handle);
    }

    /// Let the consumer cancel the quit request pushed by the close delegate.
    /// Hot path declaration: quit/close events only.
    pub fn cancelQuit(self: Window) void {
        platform_cancel_quit(self.handle);
    }

    pub fn pollEvents(self: Window) bool {
        return c.platform_poll_events(self.handle);
    }

    pub fn nextEvent(self: Window) ?Event {
        while (true) {
            var ev: c.PlatformEvent = undefined;
            if (!c.platform_get_event(self.handle, &ev)) return null;
            if (isFacadeSkipEvent(ev.type)) continue;
            const mapped: ?Event = switch (ev.type) {
                c.PLATFORM_EVENT_QUIT => .quit,
                c.PLATFORM_EVENT_KEY_DOWN => Event{ .key_down = makeKeyEvent(ev) },
                c.PLATFORM_EVENT_KEY_UP => Event{ .key_up = makeKeyEvent(ev) },
                c.PLATFORM_EVENT_MOUSE_MOVE => Event{ .mouse_move = makeMouseEvent(ev) },
                c.PLATFORM_EVENT_MOUSE_DOWN => Event{ .mouse_down = makeMouseEvent(ev) },
                c.PLATFORM_EVENT_MOUSE_UP => Event{ .mouse_up = makeMouseEvent(ev) },
                c.PLATFORM_EVENT_MOUSE_SCROLL => Event{ .mouse_scroll = makeScrollEvent(ev) },
                c.PLATFORM_EVENT_CHAR_INPUT => Event{ .char_input = makeCharEvent(ev) },
                c.PLATFORM_EVENT_GAMEPAD_CONNECTED => Event{ .gamepad_connected = makeGamepadInfo(ev) },
                c.PLATFORM_EVENT_GAMEPAD_DISCONNECTED => Event{ .gamepad_disconnected = makeGamepadDisconnect(ev) },
                c.PLATFORM_EVENT_COMPOSITION => Event{ .composition_changed = makeCompositionEvent(ev) },
                c.PLATFORM_EVENT_MENU_COMMAND => Event{ .menu_command = ev.payload.menu.command_id },
                c.PLATFORM_EVENT_FILE_DROP => makeFileDropEvent(ev),
                else => null,
            };
            if (mapped) |event| {
                traceFacadeEvent(event);
                return event;
            }
        }
    }

    /// Write the IME composition preedit text into buf. When it is empty, text has length 0.
    /// latest-wins: always the current state. event.revision only detects a missed update; an older revision cannot be read.
    pub fn getCompositionSnapshot(self: Window, buf: []u8) CompositionSnapshot {
        var meta: c.PlatformCompositionMeta = .{
            .revision = 0,
            .cursor = 0,
            .len = 0,
        };
        const n = c.platform_get_composition_snapshot(
            self.handle,
            if (buf.len > 0) buf.ptr else null,
            @intCast(buf.len),
            &meta,
        );
        const len: usize = @min(@as(usize, n), buf.len);
        return .{
            .text = buf[0..len],
            .revision = meta.revision,
            .cursor = meta.cursor,
        };
    }

    /// Supply the caret rect the IME candidate window is anchored to, in framebuffer pixels (event time only).
    pub fn setCompositionRect(self: Window, x: i32, y: i32, w: i32, h: i32) void {
        c.platform_set_composition_rect(self.handle, x, y, w, h);
    }

    /// Tell the platform whether a text editing widget has focus (idempotent: a consumer may call it every
    /// frame to track focus, and a composition is discarded only when the effective path changes).
    /// It takes effect on all three backends, objc/swift/metal (while active=false, keyDown does not reach the IME).
    pub fn setTextInputActive(self: Window, active: bool) void {
        if (comptime text_input_c_abi) TextInputC.platform_set_text_input_active(self.handle, active);
    }

    /// IME document access (for reconversion). `callbacks == null` unregisters.
    /// A single window is assumed. Headless and unit tests call no C and merely keep the registration state.
    /// The C userdata handed to native is always null (this is a single-window design in which the Zig
    /// trampoline reads module-level state; the consumer's userdata is held by doc_access_trampoline).
    pub fn setTextInputDocumentAccess(
        self: Window,
        userdata: *anyopaque,
        callbacks: ?TextInputDocumentCallbacks,
    ) void {
        if (callbacks) |cbs| {
            doc_access_trampoline = .{ .userdata = userdata, .callbacks = cbs };
            if (comptime text_input_c_abi) {
                TextInputC.platform_set_text_input_document_access(self.handle, &doc_access_c_callbacks, null);
            }
        } else {
            clearDocumentAccess();
            if (comptime text_input_c_abi) {
                TextInputC.platform_set_text_input_document_access(self.handle, null, null);
            }
        }
    }

    pub fn getEventStats(self: Window) EventStats {
        var s: c.PlatformEventStats = undefined;
        c.platform_get_event_stats(self.handle, &s);
        return .{
            .mouse_move_merge_count = s.mouse_move_merge_count,
            .mouse_scroll_merge_count = s.mouse_scroll_merge_count,
            .event_drop_count = s.event_drop_count,
        };
    }

    pub fn lockFramebuffer(self: Window) ?Framebuffer {
        var metrics: c.PlatformFramebufferMetrics = .{
            .logical_width = 0,
            .logical_height = 0,
            .framebuffer_width = 0,
            .framebuffer_height = 0,
            .content_scale = 1.0,
            .scale_epoch = 0,
        };
        const px = c.platform_lock_framebuffer_ex(self.handle, &metrics) orelse return null;
        const fw = metrics.framebuffer_width;
        const fh = metrics.framebuffer_height;
        const len = @as(usize, fw) * @as(usize, fh);
        return .{
            .pixels = px[0..len],
            .width = fw,
            .height = fh,
            .logical_size = .{ .width = metrics.logical_width, .height = metrics.logical_height },
            .framebuffer_size = .{ .width = fw, .height = fh },
            .content_scale = metrics.content_scale,
            .scale_epoch = metrics.scale_epoch,
            .window_handle = self.handle,
        };
    }

    /// The currently negotiated logical size. Drawing within a frame uses the Framebuffer snapshot.
    pub fn logicalSize(self: Window) types.WindowSize {
        const m = getMetrics(self) orelse return .{ .width = 0, .height = 0 };
        return .{ .width = m.logical_width, .height = m.logical_height };
    }

    pub fn framebufferSize(self: Window) types.WindowSize {
        const m = getMetrics(self) orelse return .{ .width = 0, .height = 0 };
        return .{ .width = m.framebuffer_width, .height = m.framebuffer_height };
    }

    pub fn contentScale(self: Window) f32 {
        const m = getMetrics(self) orelse return 1.0;
        return if (m.content_scale > 0) m.content_scale else 1.0;
    }

    pub fn present(self: Window) void {
        c.platform_present(self.handle);
    }

    /// Set the cursor shape. Expected to be called at event time only (so the performance rules do not apply).
    pub fn setCursor(self: Window, shape: CursorShape) void {
        c.platform_set_cursor(self.handle, @intFromEnum(shape));
    }

    /// Register the live-resize redraw callback.
    /// The Zig function handed over by the facade is passed to native through a C trampoline.
    /// A single window is assumed (`{ctx, cb}` is kept at module level).
    pub fn setRedrawCallback(self: Window, ctx: *anyopaque, cb: RedrawFn) void {
        redraw_trampoline = .{ .ctx = ctx, .cb = cb };
        c.platform_set_redraw_callback(self.handle, macosRedrawTrampoline, null);
    }

    /// The private clear path used by destroy (null never goes through the public API).
    pub fn clearRedrawCallback(self: Window) void {
        redraw_trampoline = .{};
        c.platform_set_redraw_callback(self.handle, null, null);
    }

    /// Read the state of the gamepad at the given index (through the GameController framework; ADR-009).
    /// Disconnected, or an index out of range, gives null.
    ///
    /// Hot path declaration: called once per frame, but it is a fixed-length copy of four pads with a few fields
    /// each (no allocation, no lock), which is neither an all-pixel loop nor real time, so the performance rules do not apply (see ADR-009).
    pub fn getGamepadState(self: Window, index: u8) ?GamepadState {
        var s: c.PlatformGamepadState = undefined;
        if (!c.platform_get_gamepad_state(self.handle, @intCast(index), &s)) return null;
        return .{
            .buttons = GamepadButtons.fromC(s.buttons_mask),
            .left_stick = .{ .x = s.left_stick_x, .y = s.left_stick_y },
            .right_stick = .{ .x = s.right_stick_x, .y = s.right_stick_y },
            .left_trigger = s.left_trigger,
            .right_trigger = s.right_trigger,
        };
    }

    // ========================================================================
};

// ============================================================================
// native menus
// ============================================================================
//
// Hot path declaration: registration and state updates happen at initialisation or on a state change
// event, and a selection only at event time. The performance rules do not apply.
//
// The facade (core/platform.zig) dispatches by looking for a **module-level decl** with
// `@hasDecl(backend, "nativeMenuAvailable")`. Making it a method of the Window struct turns that
// comptime check silently false, and native menus stay disabled forever while every build is green
// (a real bug, invisible to the headless end-to-end tests, whose expected value is the fallback).
// Do not move it off module level.

pub fn nativeMenuAvailable(win: Window) bool {
    _ = win;
    if (comptime !menu_c_abi) return false;
    return MenuC.platform_menu_available();
}

// ============================================================================
// window geometry
// ============================================================================
//
// Hot path declaration: window creation, shutdown, and harness digest observation only.
//
// getGeometry must be a **module-level decl** for the same reason as nativeMenuAvailable:
// as a method of the Window struct the facade's `@hasDecl(backend, "getGeometry")` goes silently
// false and it always returns 0x0 and null (the same wiring bug).

pub fn getGeometry(win: Window) types.WindowGeometry {
    var geo: c.PlatformWindowGeometry = .{
        .x = 0,
        .y = 0,
        .width = 0,
        .height = 0,
        .flags = 0,
    };
    c.platform_get_window_geometry(win.handle, &geo);
    return .{
        .position = if ((geo.flags & c.PLATFORM_GEOMETRY_POSITION_VALID) != 0)
            .{ .x = geo.x, .y = geo.y }
        else
            null,
        .size = .{ .width = geo.width, .height = geo.height },
    };
}

pub fn registerMenu(win: Window, commands: []const Command) void {
    if (comptime !menu_c_abi) return;
    var scratch: MenuScratch = .{};
    const items = scratch.fill(commands);
    MenuC.platform_register_menu(win.handle, items.ptr, @intCast(items.len));
}

pub fn updateMenu(win: Window, commands: []const Command) void {
    if (comptime !menu_c_abi) return;
    var scratch: MenuScratch = .{};
    const items = scratch.fill(commands);
    MenuC.platform_update_menu(win.handle, items.ptr, @intCast(items.len));
}

pub fn destroyMenu(win: Window) void {
    if (comptime !menu_c_abi) return;
    MenuC.platform_destroy_menu(win.handle);
}

/// The temporary buffer used to convert a Command into a PlatformMenuItem.
/// The strings are valid only during the call (the backend copies them). Fixed-length on the stack, with no allocation.
const MENU_SCRATCH_CAP = 64;
const MENU_STR_CAP = 256;

const MenuScratch = struct {
    items: [MENU_SCRATCH_CAP]c.PlatformMenuItem = undefined,
    titles: [MENU_SCRATCH_CAP][MENU_STR_CAP]u8 = undefined,
    labels: [MENU_SCRATCH_CAP][MENU_STR_CAP]u8 = undefined,

    fn fill(self: *MenuScratch, commands: []const Command) []const c.PlatformMenuItem {
        if (commands.len > MENU_SCRATCH_CAP) {
            std.log.warn("platform_macos menu: command count {d} exceeds MENU_SCRATCH_CAP={d}; truncating", .{
                commands.len,
                MENU_SCRATCH_CAP,
            });
        }
        const n = @min(commands.len, MENU_SCRATCH_CAP);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const cmd = commands[i];
            const title_z = copyZUtf8(&self.titles[i], cmd.menu.title);
            const label_z = copyZUtf8(&self.labels[i], cmd.label);
            self.items[i] = .{
                .command_id = cmd.id,
                .kind = if (cmd.kind == .separator) c.PLATFORM_MENU_KIND_SEPARATOR else c.PLATFORM_MENU_KIND_NORMAL,
                .top_menu = title_z,
                .label = label_z,
                .shortcut_key = if (cmd.shortcut) |sc| @intFromEnum(sc.key) else -1,
                .shortcut_mods = if (cmd.shortcut) |sc| sc.modifiers.toC() else 0,
                .enabled = if (cmd.enabled) 1 else 0,
                .checked = if (cmd.checked) 1 else 0,
            };
        }
        return self.items[0..n];
    }

    /// Copy safely into a NUL terminator in UTF-8. When the byte limit cuts, it steps back to a code point
    /// boundary (cutting inside a continuation byte, 0b10xxxxxx, would make ObjC's stringWithUTF8String: return nil).
    fn copyZUtf8(buf: *[MENU_STR_CAP]u8, src: []const u8) [*:0]const u8 {
        const max = MENU_STR_CAP - 1;
        const capped = @min(src.len, max);
        var n = capped;
        // drop the trailing continuation bytes and step back onto the lead
        while (n > 0 and (src[n - 1] & 0xC0) == 0x80) n -= 1;
        // when only an incomplete multi-byte lead is left, drop the lead too
        if (n > 0) {
            const lead = src[n - 1];
            const need: usize = if (lead < 0x80)
                1
            else if (lead < 0xE0)
                2
            else if (lead < 0xF0)
                3
            else if (lead < 0xF8)
                4
            else
                1;
            if ((n - 1) + need > capped) n -= 1;
        }
        @memcpy(buf[0..n], src[0..n]);
        buf[n] = 0;
        return buf[0..n :0].ptr;
    }
};

/// A locked framebuffer view. The convention is to call `unlock` exactly once
/// (`if (window.lockFramebuffer()) |fb| { defer fb.unlock(); ... }`).
pub const Framebuffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    logical_size: types.WindowSize,
    framebuffer_size: types.WindowSize,
    content_scale: f32,
    scale_epoch: u64,
    window_handle: *c.PlatformWindow,

    pub fn unlock(self: Framebuffer) void {
        c.platform_unlock_framebuffer(self.window_handle);
    }
};

fn getMetrics(win: Window) ?c.PlatformFramebufferMetrics {
    var metrics: c.PlatformFramebufferMetrics = .{
        .logical_width = 0,
        .logical_height = 0,
        .framebuffer_width = 0,
        .framebuffer_height = 0,
        .content_scale = 1.0,
        .scale_epoch = 0,
    };
    if (!c.platform_get_framebuffer_metrics(win.handle, &metrics)) return null;
    return metrics;
}

// ============================================================================
// File selection dialogs
// ============================================================================
//
// Synchronous and modal (application-modal). **Never call it while the framebuffer is locked** (the caller's responsibility).
// The return value is a slice owned by gpa (the caller frees it with gpa.free). A cancel gives null,
// and a failed allocation gives error.OutOfMemory.

/// Let the user choose where to save.
pub fn saveFileDialog(gpa: std.mem.Allocator, io: std.Io, opts: SaveDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    _ = io; // macOS uses a native panel (io is unused). It is taken because the signature is shared by every OS.
    var c_opts: c.PlatformSaveDialogOptions = .{
        .default_name = if (opts.default_name) |s| s.ptr else null,
        .allowed_ext = if (opts.allowed_ext) |s| s.ptr else null,
    };
    const p = c.platform_save_file_dialog(&c_opts) orelse return null;
    return try dupePathAndFree(gpa, p);
}

/// Let the user choose a file to open (a single selection, files only).
pub fn openFileDialog(gpa: std.mem.Allocator, io: std.Io, opts: OpenDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    _ = io; // macOS uses a native panel (io is unused). It is taken because the signature is shared by every OS.
    var c_opts: c.PlatformOpenDialogOptions = .{
        .allowed_ext = if (opts.allowed_ext) |s| s.ptr else null,
    };
    const p = c.platform_open_file_dialog(&c_opts) orelse return null;
    return try dupePathAndFree(gpa, p);
}

/// Duplicate the path string allocated by the C side into a gpa-owned slice, and always free the C side.
/// Even when the dupe runs out of memory, the defer calls platform_free_path, so the C side never leaks.
fn dupePathAndFree(gpa: std.mem.Allocator, p: [*c]u8) std.mem.Allocator.Error![]u8 {
    defer c.platform_free_path(p);
    return try gpa.dupe(u8, std.mem.span(p));
}

// ============================================================================
// The OS text clipboard
// ============================================================================

/// Write UTF-8 text to the OS clipboard. A no-op on anything but the three macOS backends (objc/swift/metal).
pub fn setClipboardText(text: []const u8) void {
    if (comptime !clipboard_c_abi) return;
    ClipboardC.platform_set_clipboard_text(text.ptr, @intCast(text.len));
}

/// Copy the OS clipboard's UTF-8 text into the caller's buffer.
/// An unsupported backend, no string, or a failure gives null. An empty string is `buf[0..0]`.
/// All three macOS backends implement it through NSPasteboard.
pub fn getClipboardText(buf: []u8) ?[]const u8 {
    if (comptime !clipboard_c_abi) return null;
    if (buf.len == 0) return null;
    var out_len: u32 = 0;
    if (!ClipboardC.platform_get_clipboard_text(buf.ptr, @intCast(buf.len), &out_len)) return null;
    return buf[0..out_len];
}
