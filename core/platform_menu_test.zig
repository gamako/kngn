//! Contract tests for the platform facade's menu and geometry, needing no display and no backend.

const std = @import("std");
const platform = @import("platform");
const command_types = @import("command_types");

fn nullWindow(w: u32, h: u32) platform.Window {
    return .{ .inner = .{ .null_win = .{ .pixels = &.{}, .width = w, .height = h } } };
}

test "platform menu facade: unavailable under the null runtime, and register/update/destroy are no-ops" {
    const commands = [_]command_types.Command{
        .{ .id = 1, .label = "Undo", .menu = .{ .title = "Edit", .order = 1 }, .enabled = true },
        .{ .id = 0, .kind = .separator, .menu = .{ .title = "Edit", .order = 2 } },
    };
    var window = nullWindow(0, 0);
    try std.testing.expect(!window.nativeMenuAvailable());
    try std.testing.expect(!window.supportsNativeMenus());
    window.registerMenu(&commands);
    window.updateMenu(&commands);
    window.destroyMenu();
}

// getGeometry cannot be called from this display-less test, because the native branch references
// platform_get_window_geometry (the macos .o is not linked, so the symbol is undefined).
// The size contract of null is checked through inner.null_win's width/height and end to end (appshell geom=).
test "platform geometry facade: a null Window keeps its creation size in null_win" {
    const window = nullWindow(640, 480);
    try std.testing.expectEqual(@as(u32, 640), window.inner.null_win.width);
    try std.testing.expectEqual(@as(u32, 480), window.inner.null_win.height);
}

test "platform geometry facade: an unset null size defaults to 0" {
    const window = nullWindow(0, 0);
    try std.testing.expectEqual(@as(u32, 0), window.inner.null_win.width);
    try std.testing.expectEqual(@as(u32, 0), window.inner.null_win.height);
}

test "document access facade: a no-op and unregistered under the null runtime" {
    var window = nullWindow(0, 0);
    var dummy: u8 = 0;
    const cbs = platform.TextInputDocumentCallbacks{
        .getSelectedRange = struct {
            fn f(_: *anyopaque) ?platform.TextInputRange {
                return .{ .location = 0, .length = 0 };
            }
        }.f,
        .getSubstring = struct {
            fn f(_: *anyopaque, _: platform.TextInputRange) ?platform.TextInputSubstring {
                return null;
            }
        }.f,
        .replaceText = struct {
            fn f(_: *anyopaque, _: platform.TextInputRange, _: []const u8) bool {
                return false;
            }
        }.f,
    };
    // null registers nothing (the legacy path: unregistered keeps the char_input route)
    window.setTextInputDocumentAccess(@ptrCast(&dummy), cbs);
    window.setTextInputDocumentAccess(@ptrCast(&dummy), null);
    try std.testing.expect(@hasDecl(platform.Window, "setTextInputDocumentAccess"));
    try std.testing.expectEqual(platform.TEXT_INPUT_RANGE_NOT_FOUND, std.math.maxInt(u64));
    try std.testing.expect((platform.TextInputRange{ .location = platform.TEXT_INPUT_RANGE_NOT_FOUND, .length = 0 }).isNotFound());
}
