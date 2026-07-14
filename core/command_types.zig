//! メニューとアプリ操作を結ぶ、platform 非依存の Command 定義。
//!
//! このファイルは `platform_types` と同じく type-only の共有 module である。
//! backend や facade の実装を import せず、メニューを表示する側と app 側が同じ
//! 型を参照できる境界に置く。文字列 slice の所有権は Command の利用側にあり、
//! `registerMenu` の呼び出し中だけ有効でよい。

const std = @import("std");
const platform_types = @import("platform_types");

/// app が割り当てる stable な command ID。
pub const CommandId = u32;

pub const INVALID_COMMAND_ID: CommandId = 0;
pub const FIRST_APP_COMMAND_ID: CommandId = 1;
pub const LAST_APP_COMMAND_ID: CommandId = 0xFFFF;
pub const FIRST_FRAMEWORK_COMMAND_ID: CommandId = 0x1_0000;

/// メニュー項目の実行種別。NetworkPolicy ではない。
///
/// netsync 中の relay/reject/undo_own 判定は app の action registry/router が担い、
/// この値は app の command table が通常操作と undo/redo 操作を区別するためだけに使う。
pub const ExecutionPolicy = enum(u8) {
    normal,
    undo,
    redo,
};
pub const CommandExecutionPolicy = ExecutionPolicy;

/// 物理キーと修飾キー。表示用の Cmd+Z / Ctrl+Z は backend が OS 規約から導出する。
pub const Shortcut = struct {
    key: platform_types.KeyCode,
    modifiers: platform_types.ModifierFlags = .{},
};
pub const CommandShortcut = Shortcut;

/// トップメニュー一段分の所属と表示順。submenu は MVP では持たない。
pub const MenuPath = struct {
    title: []const u8,
    order: u16 = 0,
};

pub const CommandKind = enum(u8) {
    item,
    separator,
};

/// ネイティブメニューに登録する command 定義。
///
/// `label`/`menu.title`/`shortcut` の slice は登録呼び出し中だけ有効でよい。
/// backend が必要な分を copy することが facade の契約である。
pub const Command = struct {
    id: CommandId,
    label: []const u8 = "",
    menu: MenuPath,
    kind: CommandKind = .item,
    shortcut: ?Shortcut = null,
    enabled: bool = true,
    checked: bool = false,
    execution_policy: ExecutionPolicy = .normal,

    /// separator は ID を持たず、通常項目だけが app command ID の範囲を使う。
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
