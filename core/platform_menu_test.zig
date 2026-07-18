//! display/backend 不要の platform facade menu / geometry 契約テスト。

const std = @import("std");
const platform = @import("platform");
const command_types = @import("command_types");

test "platform menu facade: headless は利用不可かつ register/update/destroy が no-op" {
    const commands = [_]command_types.Command{
        .{ .id = 1, .label = "Undo", .menu = .{ .title = "Edit", .order = 1 }, .enabled = true },
        .{ .id = 0, .kind = .separator, .menu = .{ .title = "Edit", .order = 2 } },
    };
    var window = platform.Window{ .inner = undefined, .headless = true };
    try std.testing.expect(!window.nativeMenuAvailable());
    try std.testing.expect(!window.supportsNativeMenus());
    window.registerMenu(&commands);
    window.updateMenu(&commands);
    window.destroyMenu();
}

// getGeometry は backend C ABI（platform_get_window_geometry）を参照するため、
// display-less の本テストでは呼べない（macos .o 未リンクで undefined symbol）。
// headless のサイズ保持契約は create_w/create_h フィールドと E2E（appshell geom=）で検証する。
test "platform geometry facade: headless Window は作成サイズを create_w/h に保持する" {
    const window = platform.Window{ .inner = undefined, .headless = true, .create_w = 640, .create_h = 480 };
    try std.testing.expect(window.headless);
    try std.testing.expectEqual(@as(u32, 640), window.create_w);
    try std.testing.expectEqual(@as(u32, 480), window.create_h);
}

test "platform geometry facade: headless 未設定サイズの既定は 0" {
    const window = platform.Window{ .inner = undefined, .headless = true };
    try std.testing.expectEqual(@as(u32, 0), window.create_w);
    try std.testing.expectEqual(@as(u32, 0), window.create_h);
}

test "TASK-79.6.3: document access facade は headless で no-op・未登録" {
    var window = platform.Window{ .inner = undefined, .headless = true };
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
    // headless は登録しない（legacy path = 未登録 = char_input 経路維持）
    window.setTextInputDocumentAccess(@ptrCast(&dummy), cbs);
    window.setTextInputDocumentAccess(@ptrCast(&dummy), null);
    try std.testing.expect(@hasDecl(platform.Window, "setTextInputDocumentAccess"));
    try std.testing.expectEqual(platform.TEXT_INPUT_RANGE_NOT_FOUND, std.math.maxInt(u64));
    try std.testing.expect((platform.TextInputRange{ .location = platform.TEXT_INPUT_RANGE_NOT_FOUND, .length = 0 }).isNotFound());
}
