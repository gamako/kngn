//! The platform-independent Command definition that ties menus to application operations.
//!
//! Like `platform_types`, this file is a type-only shared module.
//! It imports neither a backend nor the facade implementation, and sits at the boundary where the side
//! showing a menu and the application side can refer to the same types. A string slice is owned by the
//! user of Command, and need only stay valid for the duration of the `registerMenu` call.

const std = @import("std");
const platform_types = @import("platform_types");

/// The stable command ID an application assigns.
pub const CommandId = u32;

pub const INVALID_COMMAND_ID: CommandId = 0;
pub const FIRST_APP_COMMAND_ID: CommandId = 1;
pub const LAST_APP_COMMAND_ID: CommandId = 0xFFFF;
pub const FIRST_FRAMEWORK_COMMAND_ID: CommandId = 0x1_0000;

/// What kind of execution a menu item is. This is not a NetworkPolicy.
///
/// Deciding relay, reject or undo_own during netsync is the job of the application's action registry and router;
/// this value exists only so that the application's command table can tell an ordinary operation from an undo or a redo.
pub const ExecutionPolicy = enum(u8) {
    normal,
    undo,
    redo,
};
pub const CommandExecutionPolicy = ExecutionPolicy;

/// A physical key plus its modifiers. The backend derives the displayed Cmd+Z or Ctrl+Z from the OS convention.
pub const Shortcut = struct {
    key: platform_types.KeyCode,
    modifiers: platform_types.ModifierFlags = .{},
};
pub const CommandShortcut = Shortcut;

/// Which top-level menu it belongs to, and the display order. A submenu is not held in the MVP.
pub const MenuPath = struct {
    title: []const u8,
    order: u16 = 0,
};

pub const CommandKind = enum(u8) {
    item,
    separator,
};

/// The command definition registered with a native menu.
///
/// The `label`, `menu.title` and `shortcut` slices need only stay valid for the duration of the registration call.
/// It is the facade's contract that the backend copies whatever it needs.
pub const Command = struct {
    id: CommandId,
    label: []const u8 = "",
    menu: MenuPath,
    kind: CommandKind = .item,
    shortcut: ?Shortcut = null,
    enabled: bool = true,
    checked: bool = false,
    execution_policy: ExecutionPolicy = .normal,

    /// A separator holds no ID, and only ordinary items use the range of application command IDs.
    pub fn validate(self: Command) error{ InvalidCommandId, InvalidSeparator }!void {
        if (self.kind == .separator) {
            if (self.id != INVALID_COMMAND_ID) return error.InvalidSeparator;
            return;
        }
        if (!isAppCommandId(self.id)) return error.InvalidCommandId;
    }
};

pub fn isValidCommandId(id: CommandId) bool {
    return id != INVALID_COMMAND_ID;
}

pub fn isAppCommandId(id: CommandId) bool {
    return id >= FIRST_APP_COMMAND_ID and id <= LAST_APP_COMMAND_ID;
}

pub fn isFrameworkCommandId(id: CommandId) bool {
    return id >= FIRST_FRAMEWORK_COMMAND_ID;
}

test "command_types: ID domain and separator validation" {
    try std.testing.expect(!isValidCommandId(INVALID_COMMAND_ID));
    try std.testing.expect(isAppCommandId(1));
    try std.testing.expect(isAppCommandId(LAST_APP_COMMAND_ID));
    try std.testing.expect(!isAppCommandId(FIRST_FRAMEWORK_COMMAND_ID));
    try std.testing.expect(isFrameworkCommandId(FIRST_FRAMEWORK_COMMAND_ID));

    const item: Command = .{ .id = 7, .menu = .{ .title = "Edit", .order = 10 } };
    try item.validate();
    try std.testing.expectError(error.InvalidCommandId, (Command{ .id = 0, .menu = .{ .title = "Edit" } }).validate());
    try std.testing.expectError(error.InvalidSeparator, (Command{ .id = 7, .kind = .separator, .menu = .{ .title = "Edit" } }).validate());
    try (Command{ .id = 0, .kind = .separator, .menu = .{ .title = "Edit" } }).validate();
}

test "command_types: physical shortcut does not contain display text" {
    const shortcut: Shortcut = .{
        .key = .Z,
        .modifiers = .{ .ctrl = true },
    };
    try std.testing.expectEqual(platform_types.KeyCode.Z, shortcut.key);
    try std.testing.expect(shortcut.modifiers.ctrl);
}
