//! display/backend 不要の platform facade menu 契約テスト。

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
