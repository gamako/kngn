//! macOS native platform backend
//!
//! C API (`platform/platform.h`) を Zig の高レベル interface に変換するレイヤ。
//! `@cImport` を内部に閉じ込め、caller には Zig native な型のみを公開する。
//!
//! 公開型（KeyCode / Event 等）は `platform_types.zig` を正準ソースとし、本ファイルは
//! C 値からそれらを構築する変換層と、`Window`/`Framebuffer`・関数群を提供する。

const std = @import("std");
const types = @import("platform_types");

const c = @cImport({
    @cInclude("platform.h");
});

// 共有型のエイリアス（platform_types.zig が正準。signature 記述を簡潔にするため）
const Error = types.Error;
const KeyCode = types.KeyCode;
const ModifierFlags = types.ModifierFlags;
const MouseButton = types.MouseButton;
const MouseButtons = types.MouseButtons;
const KeyEvent = types.KeyEvent;
const MouseEvent = types.MouseEvent;
const ScrollEvent = types.ScrollEvent;
const Event = types.Event;
const EventStats = types.EventStats;
const SaveDialogOptions = types.SaveDialogOptions;
const OpenDialogOptions = types.OpenDialogOptions;
const DialogError = types.DialogError;
const CursorShape = types.CursorShape;

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
// C 値 → 共有型 への変換
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

    /// カーソル形状を設定する（TASK-75.1）。イベント時のみ呼ぶ想定（性能規約の対象外）。
    pub fn setCursor(self: Window, shape: CursorShape) void {
        c.platform_set_cursor(self.handle, @intFromEnum(shape));
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

/// 保存先をユーザーに選ばせる。
pub fn saveFileDialog(gpa: std.mem.Allocator, io: std.Io, opts: SaveDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    _ = io; // macOS は native panel（io 不要）。全 OS 共通シグネチャのため受け取る。
    var c_opts: c.PlatformSaveDialogOptions = .{
        .default_name = if (opts.default_name) |s| s.ptr else null,
        .allowed_ext = if (opts.allowed_ext) |s| s.ptr else null,
    };
    const p = c.platform_save_file_dialog(&c_opts) orelse return null;
    return try dupePathAndFree(gpa, p);
}

/// 開くファイルをユーザーに選ばせる（単一選択・ファイルのみ）。
pub fn openFileDialog(gpa: std.mem.Allocator, io: std.Io, opts: OpenDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    _ = io; // macOS は native panel（io 不要）。全 OS 共通シグネチャのため受け取る。
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
