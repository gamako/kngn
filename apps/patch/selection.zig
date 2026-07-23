//! apps/patch: 複数ノード選択集合（TASK-173.3）。
//!
//! 固定 bool 配列の純粋操作。App.selected には依存しないローカル UI 状態。
//! platform / gui / modular を import しない（test-patch で単体テスト可能）。

const std = @import("std");
const testing = std.testing;
const canvas = @import("canvas.zig");
const group = @import("group.zig");

pub const Handle = canvas.Handle;

/// 実 handle（0..GROUP_HANDLE_BASE-1）と group 合成 handle（GROUP_HANDLE_BASE..）の両方を格納。
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
// 単体テスト
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
    // 削除経路相当: clear または set false で陳腐化を防ぐ
    set(&ms, h, false);
    try testing.expect(!contains(&ms, h));
    // 同じ handle が新規ノードに再利用されても選択は引き継がない
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
    // 集合操作は独立。呼び出し側の selected 相当値は触らない（並行 UI 状態）。
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
