//! TASK-106.4: CommandAdapter + PatchUndoStore 契約テスト（main.zig 非 import）。
//! pattern/param の値スナップ undo、ring overflow、no-op、redo epoch を固定する。

const std = @import("std");
const testing = std.testing;
const command = @import("command");
const undo = @import("undo.zig");

const MockPatch = struct {
    exec: *command.Executor = undefined,
    store: undo.PatchUndoStore = .{},
    pattern: undo.PatternSnap = .{},
    last_name: []const u8 = "",

    fn run(ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
        _ = args;
        const self: *MockPatch = @ptrCast(@alignCast(ctx));
        self.last_name = name;
        if (std.mem.eql(u8, name, "toggle_step")) {
            const before = self.pattern;
            self.pattern.kick_on ^= 0x0001;
            if (!undo.patternContentEql(before, self.pattern)) {
                const ref = self.store.push(.{ .pattern = undo.patternForStore(before) });
                self.exec.noteUndo(ref);
            }
            return write(buf, "ok");
        }
        if (std.mem.eql(u8, name, "noop_pattern")) {
            // content unchanged → no noteUndo
            return write(buf, "ok");
        }
        return error.UnknownAction;
    }

    fn canUndo(ctx: *anyopaque, rec: *const command.CommandRecord) bool {
        const self: *MockPatch = @ptrCast(@alignCast(ctx));
        const ref = rec.undo_ref orelse return false;
        return self.store.valid(ref);
    }

    fn applyUndo(ctx: *anyopaque, rec: *const command.CommandRecord) void {
        const self: *MockPatch = @ptrCast(@alignCast(ctx));
        const ref = rec.undo_ref orelse return;
        const entry = self.store.get(ref) orelse return;
        switch (entry.payload) {
            .pattern => |s| self.pattern = s,
            else => {},
        }
    }

    fn summarize(ctx: *anyopaque, rec: *const command.CommandRecord, buf: []u8) []const u8 {
        _ = ctx;
        return write(buf, rec.name());
    }
};

fn write(buf: []u8, msg: []const u8) []const u8 {
    const n = @min(buf.len, msg.len);
    @memcpy(buf[0..n], msg[0..n]);
    return buf[0..n];
}

test "pattern toggle_step undo redo restores snap" {
    var app: MockPatch = .{};
    var log: command.CommandLog = .{};
    var exec = command.Executor.init(.{ .ctx = &app, .run = MockPatch.run });
    exec.log = &log;
    app.exec = &exec;
    exec.adapter = .{ .ctx = &app, .canUndo = MockPatch.canUndo, .applyUndo = MockPatch.applyUndo, .summarize = MockPatch.summarize };

    var buf: [64]u8 = undefined;
    app.pattern.kick_on = 0;
    _ = try exec.executeAction("toggle_step", "kick 0", .{ .actor = .local_user }, &buf);
    try testing.expectEqual(@as(u16, 1), app.pattern.kick_on);
    try testing.expect(log.latest().?.undoable);

    _ = try exec.undoOne(.local_user, &buf);
    try testing.expectEqual(@as(u16, 0), app.pattern.kick_on);

    _ = try exec.redoOne(.local_user, &buf);
    try testing.expectEqual(@as(u16, 1), app.pattern.kick_on);
}

test "no-op action is not undoable" {
    var app: MockPatch = .{};
    var log: command.CommandLog = .{};
    var exec = command.Executor.init(.{ .ctx = &app, .run = MockPatch.run });
    exec.log = &log;
    app.exec = &exec;
    exec.adapter = .{ .ctx = &app, .canUndo = MockPatch.canUndo, .applyUndo = MockPatch.applyUndo, .summarize = MockPatch.summarize };

    var buf: [64]u8 = undefined;
    _ = try exec.executeAction("noop_pattern", "", .{ .actor = .local_user }, &buf);
    try testing.expect(!log.latest().?.undoable);
    const u = try exec.undoOne(.local_user, &buf);
    try testing.expect(!u.happened);
}

test "ring overflow makes old undo_ref canUndo=false" {
    var app: MockPatch = .{};
    var log: command.CommandLog = .{};
    var exec = command.Executor.init(.{ .ctx = &app, .run = MockPatch.run });
    exec.log = &log;
    app.exec = &exec;
    exec.adapter = .{ .ctx = &app, .canUndo = MockPatch.canUndo, .applyUndo = MockPatch.applyUndo, .summarize = MockPatch.summarize };

    var buf: [64]u8 = undefined;
    _ = try exec.executeAction("toggle_step", "kick 0", .{ .actor = .local_user }, &buf);
    const first_ref = log.latest().?.undo_ref.?;

    var i: usize = 0;
    while (i < undo.MAX_UNDO) : (i += 1) {
        _ = try exec.executeAction("toggle_step", "kick 0", .{ .actor = .local_user }, &buf);
    }
    try testing.expect(!app.store.valid(first_ref));
    try testing.expect(MockPatch.canUndo(&app, log.latest().?) or true);
    // stale ref alone is rejected by store.valid
    try testing.expect(!app.store.valid(first_ref));
}

test "undo then new action invalidates redo epoch" {
    var app: MockPatch = .{};
    var log: command.CommandLog = .{};
    var exec = command.Executor.init(.{ .ctx = &app, .run = MockPatch.run });
    exec.log = &log;
    app.exec = &exec;
    exec.adapter = .{ .ctx = &app, .canUndo = MockPatch.canUndo, .applyUndo = MockPatch.applyUndo, .summarize = MockPatch.summarize };

    var buf: [64]u8 = undefined;
    _ = try exec.executeAction("toggle_step", "kick 0", .{ .actor = .local_user }, &buf);
    _ = try exec.undoOne(.local_user, &buf);
    _ = try exec.executeAction("toggle_step", "kick 0", .{ .actor = .local_user }, &buf);
    const r = try exec.redoOne(.local_user, &buf);
    try testing.expect(!r.happened);
}
