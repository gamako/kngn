//! The null platform backend
//!
//! An "invisible window" with no display, no compositor, no GPU and no OS window at all.
//! The facade picks it at runtime when `KNGN_HEADLESS=1`. The primary framebuffer is owned by
//! `Window`, and the harness only takes observation copies (onLock/onPresent).
//!
//! Hot path declaration:
//! - `lockFramebuffer`: it returns the pointer and size of a platform-owned buffer, nothing more (no per-frame allocation)
//! - `present`: a no-op (there is nothing to display; observation is the facade's harness.onPresent)
//! - Allocating and zeroing the buffer happen once, in `create*`. There is no per-pixel work per frame.

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

/// A monotonic clock that needs no display and no backend initialisation (it reuses the existing provider contract per target).
/// macOS calls the same `CLOCK_UPTIME_RAW` as `platform_macos.getTime` directly, without importing the
/// macos backend module (the C ABI window), which keeps the null test and a display-less link light.
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

/// Windows QPC. It takes only the frequency, without calling `platform_windows_common.init` (which registers the window class).
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
    logical_size: types.WindowSize,
    framebuffer_size: types.WindowSize,
    content_scale: f32,
    scale_epoch: u64,

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

    /// The single window creation entry point of this backend (ADR-019 R1).
    pub fn createWithOptions(width: u32, height: u32, title: [:0]const u8, opts: WindowOptions) Error!Window {
        _ = title;
        // No scale support: .physical is accepted too, with contentScale=1 and logical==framebuffer (never Unsupported).
        _ = opts.fb_mode;
        // There is no screen here, so fullscreen has no size of its own to resolve: the requested
        // size is honoured as-is (ADR-019 R3, the third class).
        _ = opts.fullscreen;
        // Nothing displays the window, so there is no user to resize it.
        _ = opts.resizable;
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

    pub fn logicalSize(self: Window) types.WindowSize {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn framebufferSize(self: Window) types.WindowSize {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn contentScale(_: Window) f32 {
        return 1.0;
    }

    pub fn lockFramebuffer(self: Window) ?Framebuffer {
        const size: types.WindowSize = .{ .width = self.width, .height = self.height };
        return .{
            .pixels = self.pixels,
            .width = self.width,
            .height = self.height,
            .logical_size = size,
            .framebuffer_size = size,
            .content_scale = 1.0,
            .scale_epoch = 0,
        };
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
// unit tests (no display needed)
// ============================================================================

const testing = std.testing;

test "null window: create→lock→write→present→lock keeps the contents" {
    var win = try Window.createWithOptions(4, 2, "t", .{});
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

test "null window: zeroed right after create, and present does not change the size" {
    var win = try Window.createWithOptions(3, 1, "t", .{});
    defer win.destroy();
    const fb = win.lockFramebuffer() orelse return error.TestUnexpectedResult;
    defer fb.unlock();
    try testing.expectEqual(@as(u32, 0), fb.pixels[0]);
    win.present();
    try testing.expectEqual(@as(u32, 3), win.width);
    try testing.expectEqual(@as(u32, 1), win.height);
}

test "null window: fullscreen honours the requested size, and geometry has position=null" {
    // There is no screen to fill here, so the requested size is the only size there is: the null
    // backend is the third class of ADR-019 R3 and honours it exactly. (The facade's
    // createFullscreen wrapper requests 1920x1080, which is what this backend produced before
    // fullscreen became an option.)
    var win = try Window.createWithOptions(640, 360, "t", .{ .fullscreen = true });
    defer win.destroy();
    try testing.expectEqual(@as(u32, 640), win.width);
    try testing.expectEqual(@as(u32, 360), win.height);
    const geo = getGeometry(win);
    try testing.expect(geo.position == null);
    try testing.expectEqual(@as(u32, 640), geo.size.width);
}

test "null window: fullscreen with .physical keeps scale 1 and the requested size" {
    var win = try Window.createWithOptions(1280, 720, "t", .{ .fullscreen = true, .fb_mode = .physical });
    defer win.destroy();
    try testing.expectEqual(@as(f32, 1.0), win.contentScale());
    try testing.expectEqual(@as(u32, 1280), win.logicalSize().width);
    try testing.expectEqual(@as(u32, 1280), win.framebufferSize().width);
    try testing.expectEqual(@as(u32, 720), win.framebufferSize().height);
}

test "null window: options.size wins, plus the poll/nextEvent/stats no-op interface" {
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

test "null .physical is accepted with scale=1 and an unchanged size, rather than Unsupported" {
    var win = try Window.createWithOptions(800, 600, "t", .{ .fb_mode = .physical });
    defer win.destroy();
    try testing.expectEqual(@as(f32, 1.0), win.contentScale());
    try testing.expectEqual(@as(u32, 800), win.logicalSize().width);
    try testing.expectEqual(@as(u32, 800), win.framebufferSize().width);
    const fb = win.lockFramebuffer() orelse return error.TestUnexpectedResult;
    defer fb.unlock();
    try testing.expectEqual(fb.logical_size.width, fb.framebuffer_size.width);
    try testing.expectEqual(fb.width, fb.framebuffer_size.width);
    try testing.expectEqual(@as(f32, 1.0), fb.content_scale);
    try testing.expectEqual(@as(u64, 0), fb.scale_epoch);
}

test "null .logical keeps the size on the width/height/pixels CRC path, snapshot included" {
    var win = try Window.createWithOptions(4, 2, "t", .{});
    defer win.destroy();
    const fb = win.lockFramebuffer() orelse return error.TestUnexpectedResult;
    defer fb.unlock();
    try testing.expectEqual(@as(u32, 4), fb.width);
    try testing.expectEqual(@as(u32, 2), fb.height);
    try testing.expectEqual(fb.logical_size.width, fb.framebuffer_size.width);
    for (fb.pixels) |*p| p.* = 0xFFAABBCC;
    win.present();
    const fb2 = win.lockFramebuffer() orelse return error.TestUnexpectedResult;
    defer fb2.unlock();
    try testing.expectEqual(@as(u32, 0xFFAABBCC), fb2.pixels[0]);
    try testing.expectEqual(@as(u32, 0xFFAABBCC), fb2.pixels[7]);
}
