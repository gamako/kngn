//! apps/patch: multi-node selection set.
//!
//! Pure operations on a fixed bool array. Local UI state independent of App.selected.
//! Does not import platform / gui / modular (unit-testable via test-patch).

const std = @import("std");
const testing = std.testing;
const canvas = @import("canvas.zig");
const group = @import("group.zig");

pub const Handle = canvas.Handle;

/// Stores both real handles (0..GROUP_HANDLE_BASE-1) and composite group handles (GROUP_HANDLE_BASE..).
pub const CAP: usize = group.GROUP_HANDLE_BASE + group.MAX_GROUPS;
pub const MultiSelected = [CAP]bool;

pub fn clear(ms: *MultiSelected) void {
    @memset(ms, false);
}

pub fn empty(ms: *const MultiSelected) bool {
    for (ms.*) |b| {
        if (b) return false;
    }
    return true;
}

pub fn contains(ms: *const MultiSelected, h: Handle) bool {
    if (h >= CAP) return false;
    return ms[h];
}

pub fn set(ms: *MultiSelected, h: Handle, v: bool) void {
    if (h >= CAP) return;
    ms[h] = v;
}

pub fn toggle(ms: *MultiSelected, h: Handle) void {
    if (h >= CAP) return;
    ms[h] = !ms[h];
}

// ============================================================================
// Unit tests
// ============================================================================

test "selection: toggle add/remove and contains" {
    var ms: MultiSelected = [_]bool{false} ** CAP;
    try testing.expect(empty(&ms));
    toggle(&ms, 3);
    try testing.expect(contains(&ms, 3));
    try testing.expect(!empty(&ms));
    toggle(&ms, 3);
    try testing.expect(!contains(&ms, 3));
    try testing.expect(empty(&ms));
}

test "selection: real handle and group composite handle" {
    var ms: MultiSelected = [_]bool{false} ** CAP;
    const real: Handle = 7;
    const gid: group.GroupId = 2;
    const gh = group.handleOfGroup(gid);
    set(&ms, real, true);
    set(&ms, gh, true);
    try testing.expect(contains(&ms, real));
    try testing.expect(contains(&ms, gh));
    try testing.expect(!contains(&ms, 8));
    try testing.expect(!contains(&ms, group.handleOfGroup(3)));
}

test "selection: clear then same handle reuse stays unselected" {
    var ms: MultiSelected = [_]bool{false} ** CAP;
    const h: Handle = 11;
    toggle(&ms, h);
    try testing.expect(contains(&ms, h));
    // Equivalent to the delete path: clear or set false to prevent staleness
    set(&ms, h, false);
    try testing.expect(!contains(&ms, h));
    // Selection is not carried over even if the same handle gets reused for a new node
    try testing.expect(!contains(&ms, h));
    clear(&ms);
    try testing.expect(empty(&ms));
    try testing.expect(!contains(&ms, h));
}

test "selection: clear empties all slots including group handles" {
    var ms: MultiSelected = [_]bool{false} ** CAP;
    set(&ms, 0, true);
    set(&ms, group.handleOfGroup(0), true);
    set(&ms, @intCast(CAP - 1), true);
    clear(&ms);
    try testing.expect(empty(&ms));
    try testing.expect(!contains(&ms, 0));
    try testing.expect(!contains(&ms, group.handleOfGroup(0)));
}

test "selection: multi ops do not require or mutate a single-selected value" {
    // Set operations are independent. Doesn't touch the caller's selected-equivalent value (concurrent UI state).
    var ms: MultiSelected = [_]bool{false} ** CAP;
    var fake_selected: ?Handle = 5;
    toggle(&ms, 9);
    try testing.expectEqual(@as(?Handle, 5), fake_selected);
    clear(&ms);
    try testing.expectEqual(@as(?Handle, 5), fake_selected);
    _ = &fake_selected;
}

test "selection: OOB handle is ignored" {
    var ms: MultiSelected = [_]bool{false} ** CAP;
    const oob: Handle = @intCast(CAP);
    toggle(&ms, oob);
    set(&ms, oob, true);
    try testing.expect(!contains(&ms, oob));
    try testing.expect(empty(&ms));
}
