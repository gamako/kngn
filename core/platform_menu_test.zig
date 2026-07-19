//! display/backend 不要の platform facade menu / geometry 契約テスト。

const std = @import("std");
const platform = @import("platform");
const command_types = @import("command_types");

fn nullWindow(w: u32, h: u32) platform.Window {
    return .{ .inner = .{ .null_win = .{ .pixels = &.{}, .width = w, .height = h } } };
}

test "platform menu facade: null runtime は利用不可かつ register/update/destroy が no-op" {
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

// getGeometry は native branch が platform_get_window_geometry を参照するため、
// display-less の本テストでは呼べない（macos .o 未リンクで undefined symbol）。
// null のサイズ契約は inner.null_win の width/height と E2E（appshell geom=）で検証する。
test "platform geometry facade: null Window は作成サイズを null_win に保持する" {
    const window = nullWindow(640, 480);
    try std.testing.expectEqual(@as(u32, 640), window.inner.null_win.width);
    try std.testing.expectEqual(@as(u32, 480), window.inner.null_win.height);
}

test "platform geometry facade: null 未設定サイズの既定は 0" {
    const window = nullWindow(0, 0);
    try std.testing.expectEqual(@as(u32, 0), window.inner.null_win.width);
    try std.testing.expectEqual(@as(u32, 0), window.inner.null_win.height);
}

test "TASK-79.6.3: document access facade は null runtime で no-op・未登録" {
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
    // null は登録しない（legacy path = 未登録 = char_input 経路維持）
    window.setTextInputDocumentAccess(@ptrCast(&dummy), cbs);
    window.setTextInputDocumentAccess(@ptrCast(&dummy), null);
    try std.testing.expect(@hasDecl(platform.Window, "setTextInputDocumentAccess"));
    try std.testing.expectEqual(platform.TEXT_INPUT_RANGE_NOT_FOUND, std.math.maxInt(u64));
    try std.testing.expect((platform.TextInputRange{ .location = platform.TEXT_INPUT_RANGE_NOT_FOUND, .length = 0 }).isNotFound());
}
