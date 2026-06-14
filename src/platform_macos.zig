//! macOS native platform backend
//!
//! C API (`platform/platform.h`) を Zig の高レベル interface に変換するレイヤ。
//! `@cImport` を内部に閉じ込め、caller には Zig native な型のみを公開する。

const std = @import("std");

const c = @cImport({
    @cInclude("platform.h");
});

pub const Error = error{
    InitFailed,
    WindowCreationFailed,
};

pub fn init() Error!void {
    if (!c.platform_init()) return error.InitFailed;
}

pub fn shutdown() void {
    c.platform_shutdown();
}

pub fn getTime() f64 {
    return c.platform_get_time();
}

// ============================================================================
// KeyCode (non-exhaustive enum)
// ============================================================================
//
// 物理キーボードの仮想キーコード。non-exhaustive (`_,`) にしているのは:
//   - 未列挙の C 値が来ても `@enumFromInt` が panic しない
//   - 将来別バックエンド (SDL 等) が独自キーを足したいときの拡張余地

pub const KeyCode = enum(c_int) {
    UNKNOWN = -1,

    SPACE = 32,

    @"0" = 48,
    @"1" = 49,
    @"2" = 50,
    @"3" = 51,
    @"4" = 52,
    @"5" = 53,
    @"6" = 54,
    @"7" = 55,
    @"8" = 56,
    @"9" = 57,

    A = 65, B = 66, C = 67, D = 68, E = 69, F = 70, G = 71, H = 72,
    I = 73, J = 74, K = 75, L = 76, M = 77, N = 78, O = 79, P = 80,
    Q = 81, R = 82, S = 83, T = 84, U = 85, V = 86, W = 87, X = 88,
    Y = 89, Z = 90,

    ESCAPE = 256,
    ENTER = 257,
    TAB = 258,
    BACKSPACE = 259,
    INSERT = 260,
    DELETE = 261,
    LEFT = 263,
    RIGHT = 264,
    UP = 265,
    DOWN = 266,
    PAGE_UP = 267,
    PAGE_DOWN = 268,
    HOME = 269,
    END = 270,

    CAPS_LOCK = 280,
    PRINT_SCREEN = 283,
    PAUSE = 284,

    F1 = 290, F2 = 291, F3 = 292, F4 = 293, F5 = 294,
    F6 = 295, F7 = 296, F8 = 297, F9 = 298, F10 = 299,
    F11 = 300, F12 = 301, F13 = 302, F14 = 303, F15 = 304,
    F16 = 305, F17 = 306, F18 = 307, F19 = 308, F20 = 309,

    KP_0 = 320, KP_1 = 321, KP_2 = 322, KP_3 = 323, KP_4 = 324,
    KP_5 = 325, KP_6 = 326, KP_7 = 327, KP_8 = 328, KP_9 = 329,
    KP_DECIMAL = 330,
    KP_DIVIDE = 331,
    KP_MULTIPLY = 332,
    KP_SUBTRACT = 333,
    KP_ADD = 334,
    KP_ENTER = 335,
    KP_EQUAL = 336,

    LEFT_SHIFT = 340,
    LEFT_CONTROL = 341,
    LEFT_ALT = 342,
    LEFT_SUPER = 343,
    RIGHT_SHIFT = 344,
    RIGHT_CONTROL = 345,
    RIGHT_ALT = 346,
    RIGHT_SUPER = 347,

    _,
};

inline fn keyFromC(raw: c.PlatformKeyCode) KeyCode {
    return @enumFromInt(@as(c_int, raw));
}

// ============================================================================
// ModifierFlags (packed struct, LSB-first で C の bit-mask と一致)
// ============================================================================

pub const ModifierFlags = packed struct(u32) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    cmd: bool = false,
    _reserved: u28 = 0,

    pub inline fn fromC(raw: u32) ModifierFlags {
        return @bitCast(raw);
    }

    pub inline fn toC(self: ModifierFlags) u32 {
        return @bitCast(self);
    }
};

comptime {
    // C の SHIFT=0x01, CTRL=0x02, ALT=0x04, CMD=0x08 と packed struct のビット並びが一致することを保証
    std.debug.assert(@as(u32, @bitCast(ModifierFlags{ .shift = true })) == 0x01);
    std.debug.assert(@as(u32, @bitCast(ModifierFlags{ .ctrl = true })) == 0x02);
    std.debug.assert(@as(u32, @bitCast(ModifierFlags{ .alt = true })) == 0x04);
    std.debug.assert(@as(u32, @bitCast(ModifierFlags{ .cmd = true })) == 0x08);
}

// ============================================================================
// MouseButton (物理ボタン基準、C 側 PlatformMouseButton と同じ int 幅)
// ============================================================================

pub const MouseButton = enum(c_int) {
    left = 0,
    right = 1,
    middle = 2,
    none = 0xFF,
    _,
};

inline fn buttonFromC(raw: c.PlatformMouseButton) MouseButton {
    return @enumFromInt(@as(c_int, @intCast(raw)));
}

// ============================================================================
// MouseButtons (packed struct, LSB-first で C の bit-mask と一致)
// ============================================================================

pub const MouseButtons = packed struct(u8) {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
    _reserved: u5 = 0,

    pub inline fn fromC(raw: u8) MouseButtons {
        return @bitCast(raw);
    }

    pub inline fn toC(self: MouseButtons) u8 {
        return @bitCast(self);
    }
};

comptime {
    // C 側 LEFT=0x01, RIGHT=0x02, MIDDLE=0x04 と packed struct のビット並びが一致することを保証
    std.debug.assert(@as(u8, @bitCast(MouseButtons{ .left = true })) == 0x01);
    std.debug.assert(@as(u8, @bitCast(MouseButtons{ .right = true })) == 0x02);
    std.debug.assert(@as(u8, @bitCast(MouseButtons{ .middle = true })) == 0x04);
}

// ============================================================================
// Event
// ============================================================================

pub const KeyEvent = struct {
    key: KeyCode,
    is_repeat: bool,
    modifiers: ModifierFlags,
};

/// マウスイベント。座標は window 座標 (window contentRect 左上原点・logical 単位)。
/// framebuffer / canvas への変換は caller の責任。
pub const MouseEvent = struct {
    x: i32,
    y: i32,
    button: MouseButton,    // mouse_move では .none、mouse_down/up でのみ left/right/middle
    buttons: MouseButtons,  // 現在押下中のボタン集合 (post-state)
    modifiers: ModifierFlags,
};

/// スクロールイベント。dx, dy の単位は window 座標と同じ。
pub const ScrollEvent = struct {
    x: i32,
    y: i32,
    dx: f32,
    dy: f32,
    is_precise: bool,
    buttons: MouseButtons,
    modifiers: ModifierFlags,
};

pub const Event = union(enum) {
    quit,
    key_down: KeyEvent,
    key_up: KeyEvent,
    mouse_move: MouseEvent,
    mouse_down: MouseEvent,
    mouse_up: MouseEvent,
    mouse_scroll: ScrollEvent,
};

/// イベントキューの観測カウンタ (累積値の snapshot)
pub const EventStats = struct {
    mouse_move_merge_count: u64,
    mouse_scroll_merge_count: u64,
    event_drop_count: u64,
};

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

// ============================================================================
// Window / Framebuffer
// ============================================================================

pub const Window = struct {
    handle: *c.PlatformWindow,

    pub fn create(width: u32, height: u32, title: [:0]const u8) Error!Window {
        const w = c.platform_create_window(
            @intCast(width),
            @intCast(height),
            title.ptr,
            null,
            null,
        ) orelse return error.WindowCreationFailed;
        return .{ .handle = w };
    }

    pub fn destroy(self: Window) void {
        c.platform_destroy_window(self.handle);
    }

    pub fn pollEvents(self: Window) bool {
        return c.platform_poll_events(self.handle);
    }

    pub fn nextEvent(self: Window) ?Event {
        while (true) {
            var ev: c.PlatformEvent = undefined;
            if (!c.platform_get_event(self.handle, &ev)) return null;
            return switch (ev.type) {
                c.PLATFORM_EVENT_QUIT => .quit,
                c.PLATFORM_EVENT_KEY_DOWN => Event{ .key_down = makeKeyEvent(ev) },
                c.PLATFORM_EVENT_KEY_UP => Event{ .key_up = makeKeyEvent(ev) },
                c.PLATFORM_EVENT_MOUSE_MOVE => Event{ .mouse_move = makeMouseEvent(ev) },
                c.PLATFORM_EVENT_MOUSE_DOWN => Event{ .mouse_down = makeMouseEvent(ev) },
                c.PLATFORM_EVENT_MOUSE_UP => Event{ .mouse_up = makeMouseEvent(ev) },
                c.PLATFORM_EVENT_MOUSE_SCROLL => Event{ .mouse_scroll = makeScrollEvent(ev) },
                else => continue,
            };
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
        var w: c_int = 0;
        var h: c_int = 0;
        const px = c.platform_lock_framebuffer(self.handle, &w, &h) orelse return null;
        const len = @as(usize, @intCast(w)) * @as(usize, @intCast(h));
        return .{
            .pixels = px[0..len],
            .width = @intCast(w),
            .height = @intCast(h),
            .window_handle = self.handle,
        };
    }

    pub fn present(self: Window) void {
        c.platform_present(self.handle);
    }
};

/// Locked framebuffer view. `unlock` を 1 度だけ呼ぶ慣習で運用する
/// （`if (window.lockFramebuffer()) |fb| { defer fb.unlock(); ... }`）。
pub const Framebuffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    window_handle: *c.PlatformWindow,

    pub fn unlock(self: Framebuffer) void {
        c.platform_unlock_framebuffer(self.window_handle);
    }
};

// ============================================================================
// ファイル選択ダイアログ (TASK-24)
// ============================================================================
//
// 同期モーダル（app-modal）。**framebuffer lock 中には呼ばないこと**（caller 責任）。
// 戻り値は gpa 所有スライス（caller が gpa.free すること）。キャンセル時は null、
// メモリ確保失敗時は error.OutOfMemory。

pub const SaveDialogOptions = struct {
    default_name: ?[:0]const u8 = null,
    allowed_ext: ?[:0]const u8 = null,
};

pub const OpenDialogOptions = struct {
    allowed_ext: ?[:0]const u8 = null,
};

/// 保存先をユーザーに選ばせる。
pub fn saveFileDialog(gpa: std.mem.Allocator, opts: SaveDialogOptions) std.mem.Allocator.Error!?[]u8 {
    var c_opts: c.PlatformSaveDialogOptions = .{
        .default_name = if (opts.default_name) |s| s.ptr else null,
        .allowed_ext = if (opts.allowed_ext) |s| s.ptr else null,
    };
    const p = c.platform_save_file_dialog(&c_opts) orelse return null;
    return try dupePathAndFree(gpa, p);
}

/// 開くファイルをユーザーに選ばせる（単一選択・ファイルのみ）。
pub fn openFileDialog(gpa: std.mem.Allocator, opts: OpenDialogOptions) std.mem.Allocator.Error!?[]u8 {
    var c_opts: c.PlatformOpenDialogOptions = .{
        .allowed_ext = if (opts.allowed_ext) |s| s.ptr else null,
    };
    const p = c.platform_open_file_dialog(&c_opts) orelse return null;
    return try dupePathAndFree(gpa, p);
}

/// C 側が確保したパス文字列を gpa 所有スライスへ複製し、C 側を必ず解放する。
/// dupe が OOM でも defer で platform_free_path を呼ぶので C 側はリークしない。
fn dupePathAndFree(gpa: std.mem.Allocator, p: [*c]u8) std.mem.Allocator.Error![]u8 {
    defer c.platform_free_path(p);
    return try gpa.dupe(u8, std.mem.span(p));
}

test "ModifierFlags round trip via @bitCast" {
    const m = ModifierFlags{ .shift = true, .cmd = true };
    const raw = m.toC();
    try std.testing.expectEqual(@as(u32, 0x09), raw);
    const back = ModifierFlags.fromC(raw);
    try std.testing.expect(back.shift);
    try std.testing.expect(!back.ctrl);
    try std.testing.expect(!back.alt);
    try std.testing.expect(back.cmd);
}

