//! Null platform backend（TASK-165）
//!
//! display / compositor / GPU / OS window を一切持たない「見えないウィンドウ」。
//! `VP_HEADLESS=1` のとき facade が runtime で選択する。一次 framebuffer は
//! `Window` が所有し、harness は観測 copy（onLock/onPresent）だけを行う。
//!
//! ホットパス宣言:
//! - `lockFramebuffer`: platform 所有 buffer のポインタ・寸法返却のみ（フレーム毎の新規確保なし）
//! - `present`: no-op（表示先なし。観測は facade の harness.onPresent）
//! - buffer 確保/ゼロクリアは `create*` 時の一回だけ。フレーム毎の per-pixel 処理は行わない。

const std = @import("std");
const builtin = @import("builtin");
const types = @import("platform_types");
const command_types = @import("command_types");

const Error = types.Error;
const Event = types.Event;
const EventStats = types.EventStats;
const CursorShape = types.CursorShape;
const WindowOptions = types.WindowOptions;
const WindowGeometry = types.WindowGeometry;
const CompositionSnapshot = types.CompositionSnapshot;
const TextInputDocumentCallbacks = types.TextInputDocumentCallbacks;
const GamepadState = types.GamepadState;
const DialogError = types.DialogError;
const SaveDialogOptions = types.SaveDialogOptions;
const OpenDialogOptions = types.OpenDialogOptions;
const Command = command_types.Command;

const gpa = std.heap.page_allocator;

pub fn init() Error!void {}

pub fn shutdown() void {}

/// display/backend 初期化不要の monotonic clock（target 条件で既存 provider 契約を再利用）。
/// macOS は `platform_macos.getTime` と同じ `CLOCK_UPTIME_RAW` を直接呼び、macos backend
/// module（C ABI window）を import しない（null test / display-less リンクを軽く保つ）。
pub fn getTime() f64 {
    if (comptime builtin.cpu.arch.isWasm()) return 0;
    return switch (builtin.os.tag) {
        .macos => macosGetTime(),
        .linux => @import("platform_linux_common.zig").getTime(),
        .windows => windowsGetTime(),
        else => 0,
    };
}

fn macosGetTime() f64 {
    const c = struct {
        extern "c" fn clock_gettime_nsec_np(clock_id: c_int) u64;
        const CLOCK_UPTIME_RAW: c_int = 8; // macOS: matches platform_macos.m
    };
    return @as(f64, @floatFromInt(c.clock_gettime_nsec_np(c.CLOCK_UPTIME_RAW))) / 1e9;
}

/// Windows QPC。`platform_windows_common.init`（ウィンドウクラス登録）を呼ばず周波数だけ取る。
fn windowsGetTime() f64 {
    const win = struct {
        extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) i32;
        extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) i32;
        var freq: f64 = 0;
        var freq_ready: bool = false;
    };
    if (!win.freq_ready) {
        var f: i64 = 0;
        if (win.QueryPerformanceFrequency(&f) != 0 and f != 0) {
            win.freq = @floatFromInt(f);
            win.freq_ready = true;
        } else {
            return 0;
        }
    }
    var counter: i64 = 0;
    if (win.QueryPerformanceCounter(&counter) == 0) return 0;
    return @as(f64, @floatFromInt(counter)) / win.freq;
}

pub fn getGeometry(win: Window) WindowGeometry {
    return .{
        .position = null,
        .size = .{ .width = win.width, .height = win.height },
    };
}

pub fn saveFileDialog(_: std.mem.Allocator, _: std.Io, _: SaveDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    return error.DialogFailed;
}

pub fn openFileDialog(_: std.mem.Allocator, _: std.Io, _: OpenDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    return error.DialogFailed;
}

pub fn clipboardWrite(_: []const u8) void {}
pub fn clipboardRequestPaste() void {}
pub fn clipboardTakePaste() ?[]const u8 {
    return null;
}
pub fn setClipboardText(_: []const u8) void {}
pub fn getClipboardText(_: []u8) ?[]const u8 {
    return null;
}

pub fn setDockVisible(_: bool) void {}

pub fn nativeMenuAvailable(_: Window) bool {
    return false;
}
pub fn registerMenu(_: Window, _: []const Command) void {}
pub fn updateMenu(_: Window, _: []const Command) void {}
pub fn destroyMenu(_: Window) void {}

pub const Framebuffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,

    pub fn unlock(self: Framebuffer) void {
        _ = self;
    }
};

pub const Window = struct {
    pixels: []u32,
    width: u32,
    height: u32,

    fn allocBuffer(width: u32, height: u32) Error!Window {
        const n = @as(usize, width) * @as(usize, height);
        const pixels = gpa.alloc(u32, n) catch return error.WindowCreationFailed;
        @memset(pixels, 0);
        return .{ .pixels = pixels, .width = width, .height = height };
    }

    pub fn create(width: u32, height: u32, title: [:0]const u8) Error!Window {
        _ = title;
        return allocBuffer(width, height);
    }

    pub fn createFullscreen(title: [:0]const u8) Error!Window {
        _ = title;
        return allocBuffer(1920, 1080);
    }

    pub fn createWithOptions(width: u32, height: u32, title: [:0]const u8, opts: WindowOptions) Error!Window {
        _ = title;
        const w = if (opts.size) |s| s.width else width;
        const h = if (opts.size) |s| s.height else height;
        return allocBuffer(w, h);
    }

    pub fn destroy(self: Window) void {
        if (self.pixels.len > 0) gpa.free(self.pixels);
    }

    pub fn pollEvents(self: Window) bool {
        _ = self;
        return true;
    }

    pub fn nextEvent(self: Window) ?Event {
        _ = self;
        return null;
    }

    pub fn getEventStats(self: Window) EventStats {
        _ = self;
        return .{ .mouse_move_merge_count = 0, .mouse_scroll_merge_count = 0, .event_drop_count = 0 };
    }

    pub fn lockFramebuffer(self: Window) ?Framebuffer {
        return .{ .pixels = self.pixels, .width = self.width, .height = self.height };
    }

    pub fn present(self: Window) void {
        _ = self;
    }

    pub fn cancelQuit(self: Window) void {
        _ = self;
    }
    pub fn setCursor(self: Window, _: CursorShape) void {
        _ = self;
    }
    pub fn setTitle(self: Window, _: [:0]const u8) void {
        _ = self;
    }
    pub fn beginDrag(self: Window) void {
        _ = self;
    }
    pub fn setAlwaysOnTop(self: Window, _: bool) void {
        _ = self;
    }
    pub fn setClickThrough(self: Window, _: bool) void {
        _ = self;
    }
    pub fn showQuitMenu(self: Window) void {
        _ = self;
    }
    pub fn setRedrawCallback(self: Window, _: *anyopaque, _: *const fn (*anyopaque) void) void {
        _ = self;
    }
    pub fn clearRedrawCallback(self: Window) void {
        _ = self;
    }
    pub fn getCompositionSnapshot(self: Window, buf: []u8) CompositionSnapshot {
        _ = self;
        return .{ .text = buf[0..0], .revision = 0, .cursor = 0 };
    }
    pub fn setCompositionRect(self: Window, _: i32, _: i32, _: i32, _: i32) void {
        _ = self;
    }
    pub fn setTextInputActive(self: Window, _: bool) void {
        _ = self;
    }
    pub fn setTextInputDocumentAccess(self: Window, _: *anyopaque, _: ?TextInputDocumentCallbacks) void {
        _ = self;
    }
    pub fn getGamepadState(self: Window, _: u8) ?GamepadState {
        _ = self;
        return null;
    }
};

// ============================================================================
// unit tests（display 不要）
// ============================================================================

const testing = std.testing;

test "null window: create→lock→write→present→lock で内容保持" {
    var win = try Window.create(4, 2, "t");
    defer win.destroy();

    const fb1 = win.lockFramebuffer() orelse return error.TestUnexpectedResult;
    defer fb1.unlock();
    try testing.expectEqual(@as(usize, 8), fb1.pixels.len);
    for (fb1.pixels) |*p| p.* = 0xFF112233;
    win.present();

    const fb2 = win.lockFramebuffer() orelse return error.TestUnexpectedResult;
    defer fb2.unlock();
    try testing.expectEqual(@as(u32, 0xFF112233), fb2.pixels[0]);
    try testing.expectEqual(@as(u32, 0xFF112233), fb2.pixels[7]);
}

test "null window: create 直後はゼロクリア、present は寸法を変えない" {
    var win = try Window.create(3, 1, "t");
    defer win.destroy();
    const fb = win.lockFramebuffer() orelse return error.TestUnexpectedResult;
    defer fb.unlock();
    try testing.expectEqual(@as(u32, 0), fb.pixels[0]);
    win.present();
    try testing.expectEqual(@as(u32, 3), win.width);
    try testing.expectEqual(@as(u32, 1), win.height);
}

test "null window: fullscreen 既定は 1920x1080、geometry は position=null" {
    var win = try Window.createFullscreen("t");
    defer win.destroy();
    try testing.expectEqual(@as(u32, 1920), win.width);
    try testing.expectEqual(@as(u32, 1080), win.height);
    const geo = getGeometry(win);
    try testing.expect(geo.position == null);
    try testing.expectEqual(@as(u32, 1920), geo.size.width);
}

test "null window: options.size 優先、poll/nextEvent/stats/no-op I/F" {
    var win = try Window.createWithOptions(10, 10, "t", .{ .size = .{ .width = 5, .height = 7 } });
    defer win.destroy();
    try testing.expectEqual(@as(u32, 5), win.width);
    try testing.expectEqual(@as(u32, 7), win.height);
    try testing.expect(win.pollEvents());
    try testing.expect(win.nextEvent() == null);
    const stats = win.getEventStats();
    try testing.expectEqual(@as(u32, 0), stats.mouse_move_merge_count);
    win.cancelQuit();
    win.setCursor(.default);
    win.setTitle("x");
    win.beginDrag();
    win.setAlwaysOnTop(true);
    win.setClickThrough(true);
    win.showQuitMenu();
    try testing.expect(!nativeMenuAvailable(win));
    registerMenu(win, &.{});
    updateMenu(win, &.{});
    destroyMenu(win);
    var buf: [8]u8 = undefined;
    const snap = win.getCompositionSnapshot(&buf);
    try testing.expectEqual(@as(usize, 0), snap.text.len);
    try testing.expect(win.getGamepadState(0) == null);
    try testing.expect(getTime() >= 0);
}
