//! Fixed-size native-menu signature for dirty checks.
//!
//! `rebuildMenuCommands` runs every frame; native `updateMenu` must only run when
//! enabled/checked/item-count change. This module is pure (std only) so the
//! equality and dirty-decision rules are unit-testable without a Window.
//!
//! Hot path: per-frame fixed-size mask build and integer compare (no allocation).

const std = @import("std");
const testing = std.testing;

/// Fixed-size menu signature (enabled/checked bitmasks + non-separator item count).
pub const MenuStateSignature = struct {
    enabled_mask: u16 = 0,
    checked_mask: u16 = 0,
    item_count: u8 = 0,

    pub fn eql(a: MenuStateSignature, b: MenuStateSignature) bool {
        return a.enabled_mask == b.enabled_mask and a.checked_mask == b.checked_mask and a.item_count == b.item_count;
    }
};

/// One non-separator menu item's dynamic state.
pub const ItemState = struct {
    enabled: bool = true,
    checked: bool = false,
};

/// What native menu bridge call (if any) a signature transition requires.
pub const SyncKind = enum {
    /// Signature unchanged: do not call updateMenu / registerMenu.
    none,
    /// enabled/checked changed, item count same: updateMenu.
    update,
    /// First registration or item count changed: registerMenu.
    register,
};

/// Build a signature from non-separator item flags (order = mask bit order).
/// At most 16 items contribute bits (u16 masks).
pub fn signatureOf(items: []const ItemState) MenuStateSignature {
    var sig: MenuStateSignature = .{};
    var n: u8 = 0;
    for (items) |it| {
        if (n >= 16) break;
        const bit: u16 = @as(u16, 1) << @intCast(n);
        if (it.enabled) sig.enabled_mask |= bit;
        if (it.checked) sig.checked_mask |= bit;
        n += 1;
    }
    sig.item_count = n;
    return sig;
}

/// Decide whether the native menu bridge must be touched.
pub fn syncKind(prev_valid: bool, prev: MenuStateSignature, next: MenuStateSignature) SyncKind {
    if (!prev_valid) return .register;
    if (MenuStateSignature.eql(prev, next)) return .none;
    if (prev.item_count != next.item_count) return .register;
    return .update;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test "menu_sig: identical state yields equal signature and sync none" {
    const items = [_]ItemState{
        .{ .enabled = true }, // Undo
        .{ .enabled = true }, // Redo
        .{ .enabled = true }, // Auto Layout
        .{ .enabled = false }, // Auto Layout Selected
        .{ .enabled = true }, // Save
        .{ .enabled = true }, // Open
        .{ .enabled = true }, // Quit
        .{ .enabled = true, .checked = true }, // History
    };
    const a = signatureOf(&items);
    const b = signatureOf(&items);
    try testing.expect(MenuStateSignature.eql(a, b));
    try testing.expectEqual(SyncKind.none, syncKind(true, a, b));
    // Empty selection contract: bits 0,1,2,4,5,6,7 → 0xF7
    try testing.expectEqual(@as(u16, 0xF7), a.enabled_mask);
    try testing.expectEqual(@as(u8, 8), a.item_count);
    try testing.expectEqual(@as(u16, 0x80), a.checked_mask); // History = bit 7
}

test "menu_sig: selection enables Auto Layout Selected (F7 → FF)" {
    var items = [_]ItemState{
        .{ .enabled = true },
        .{ .enabled = true },
        .{ .enabled = true },
        .{ .enabled = false },
        .{ .enabled = true },
        .{ .enabled = true },
        .{ .enabled = true },
        .{ .enabled = true, .checked = true },
    };
    const empty = signatureOf(&items);
    try testing.expectEqual(@as(u16, 0xF7), empty.enabled_mask);

    items[3].enabled = true;
    const selected = signatureOf(&items);
    try testing.expectEqual(@as(u16, 0xFF), selected.enabled_mask);
    try testing.expect(!MenuStateSignature.eql(empty, selected));
    try testing.expectEqual(SyncKind.update, syncKind(true, empty, selected));
}

test "menu_sig: item_count change requests register not update" {
    const a = signatureOf(&[_]ItemState{ .{}, .{}, .{} });
    const b = signatureOf(&[_]ItemState{ .{}, .{}, .{}, .{} });
    try testing.expectEqual(@as(u8, 3), a.item_count);
    try testing.expectEqual(@as(u8, 4), b.item_count);
    try testing.expectEqual(SyncKind.register, syncKind(true, a, b));
}

test "menu_sig: first frame always register" {
    const next = signatureOf(&[_]ItemState{.{}});
    try testing.expectEqual(SyncKind.register, syncKind(false, .{}, next));
}

test "menu_sig: checked-only change is update" {
    const a = signatureOf(&[_]ItemState{.{ .enabled = true, .checked = false }});
    const b = signatureOf(&[_]ItemState{.{ .enabled = true, .checked = true }});
    try testing.expectEqual(SyncKind.update, syncKind(true, a, b));
    try testing.expectEqual(@as(u16, 0), a.checked_mask);
    try testing.expectEqual(@as(u16, 1), b.checked_mask);
}
