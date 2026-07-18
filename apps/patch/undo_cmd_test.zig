//! TASK-106.4 / TASK-150: CommandAdapter + PatchUndoStore 契約テスト（main.zig 非 import）。
//! pattern/param/mute の値スナップ undo、ring overflow、no-op、redo epoch、履歴分類を固定する。

const std = @import("std");
const testing = std.testing;
const command = @import("command");
const undo = @import("undo.zig");

const MockPatch = struct {
    exec: *command.Executor = undefined,
    store: undo.PatchUndoStore = .{},
    pattern: undo.PatternSnap = .{},
    tempo: f32 = 122.0,
    kick_mute: bool = false,
    last_name: []const u8 = "",

    fn run(ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
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
        if (std.mem.eql(u8, name, "set_param")) {
            // "<name> <value>" — Transport alias のみ（tempo）。
            var it = std.mem.tokenizeAny(u8, args, " \t");
            const pname = it.next() orelse return error.Empty;
            const pval_s = it.next() orelse return error.Empty;
            const pval = try std.fmt.parseFloat(f32, pval_s);
            if (!std.mem.eql(u8, pname, "tempo")) return error.UnknownParam;
            const before = self.tempo;
            self.tempo = pval;
            if (before != pval) {
                var snap = undo.ParamValueSnap{ .mode = 0 };
                snap.setName("tempo");
                snap.value_kind = 0;
                snap.value_bits = @bitCast(before);
                const ref = self.store.push(.{ .param = snap });
                self.exec.noteUndo(ref);
            }
            return write(buf, "ok");
        }
        if (std.mem.eql(u8, name, "set_mute")) {
            var it = std.mem.tokenizeAny(u8, args, " \t");
            const tname = it.next() orelse return error.Empty;
            const ton = it.next() orelse return error.Empty;
            if (!std.mem.eql(u8, tname, "kick")) return error.UnknownTrack;
            const on = std.mem.eql(u8, ton, "1");
            const was = self.kick_mute;
            self.kick_mute = on;
            if (was != on) {
                const ref = self.store.push(.{ .mute = .{ .track = 0, .was_muted = was } });
                self.exec.noteUndo(ref);
            }
            return write(buf, "ok");
        }
        if (std.mem.eql(u8, name, "noop_pattern")) {
            return write(buf, "ok");
        }
        if (std.mem.eql(u8, name, "camera_pan")) {
            // 非 undoable（camera/selection/panel 相当）
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
            .param => |s| {
                if (std.mem.eql(u8, s.name(), "tempo")) {
                    self.tempo = @bitCast(s.value_bits);
                }
            },
            .mute => |s| {
                if (s.track == 0) self.kick_mute = s.was_muted;
            },
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

fn wireExec(app: *MockPatch, log: *command.CommandLog, exec: *command.Executor) void {
    exec.* = command.Executor.init(.{ .ctx = app, .run = MockPatch.run });
    exec.log = log;
    app.exec = exec;
    exec.adapter = .{ .ctx = app, .canUndo = MockPatch.canUndo, .applyUndo = MockPatch.applyUndo, .summarize = MockPatch.summarize };
}

/// History 行分類（main.zig historyCmdRowColor と対応）。
const HistoryRowClass = enum { normal, reverted, revert };

fn classifyHistoryRow(kind: command.CommandKind, reverted: bool) HistoryRowClass {
    return switch (kind) {
        .revert => .revert,
        .normal => if (reverted) .reverted else .normal,
    };
}

/// main.zig `takePendingParamUndoBefore` と同契約の pending slot。
/// param 名一致時のみ消費し、不一致なら pending を残す。
const PendingParamUndo = struct {
    pending: ?undo.ParamValueSnap = null,

    fn takeIfNameMatches(self: *PendingParamUndo, param_name: []const u8) ?undo.ParamValueSnap {
        const p = self.pending orelse return null;
        if (!std.mem.eql(u8, p.name(), param_name)) return null;
        self.pending = null;
        return p;
    }
};

test "pattern toggle_step undo redo restores snap" {
    var app: MockPatch = .{};
    var log: command.CommandLog = .{};
    var exec: command.Executor = undefined;
    wireExec(&app, &log, &exec);

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

test "transport set_param tempo undo redo restores value" {
    var app: MockPatch = .{};
    var log: command.CommandLog = .{};
    var exec: command.Executor = undefined;
    wireExec(&app, &log, &exec);

    var buf: [64]u8 = undefined;
    app.tempo = 122.0;
    _ = try exec.executeAction("set_param", "tempo 140", .{ .actor = .local_user }, &buf);
    try testing.expectEqual(@as(f32, 140.0), app.tempo);
    try testing.expect(log.latest().?.undoable);

    _ = try exec.undoOne(.local_user, &buf);
    try testing.expectEqual(@as(f32, 122.0), app.tempo);

    _ = try exec.redoOne(.local_user, &buf);
    try testing.expectEqual(@as(f32, 140.0), app.tempo);
}

test "set_mute undo redo restores mute flag" {
    var app: MockPatch = .{};
    var log: command.CommandLog = .{};
    var exec: command.Executor = undefined;
    wireExec(&app, &log, &exec);

    var buf: [64]u8 = undefined;
    try testing.expect(!app.kick_mute);
    _ = try exec.executeAction("set_mute", "kick 1", .{ .actor = .local_user }, &buf);
    try testing.expect(app.kick_mute);
    try testing.expect(log.latest().?.undoable);

    _ = try exec.undoOne(.local_user, &buf);
    try testing.expect(!app.kick_mute);

    _ = try exec.redoOne(.local_user, &buf);
    try testing.expect(app.kick_mute);
}

test "same-value set_param is not undoable" {
    var app: MockPatch = .{};
    var log: command.CommandLog = .{};
    var exec: command.Executor = undefined;
    wireExec(&app, &log, &exec);

    var buf: [64]u8 = undefined;
    app.tempo = 122.0;
    _ = try exec.executeAction("set_param", "tempo 122", .{ .actor = .local_user }, &buf);
    try testing.expect(!log.latest().?.undoable);
}

test "non-undoable camera action does not block prior undo" {
    var app: MockPatch = .{};
    var log: command.CommandLog = .{};
    var exec: command.Executor = undefined;
    wireExec(&app, &log, &exec);

    var buf: [64]u8 = undefined;
    app.tempo = 122.0;
    _ = try exec.executeAction("set_param", "tempo 140", .{ .actor = .local_user }, &buf);
    _ = try exec.executeAction("camera_pan", "", .{ .actor = .local_user }, &buf);
    try testing.expect(!log.latest().?.undoable);

    _ = try exec.undoOne(.local_user, &buf);
    try testing.expectEqual(@as(f32, 122.0), app.tempo);
}

test "no-op action is not undoable" {
    var app: MockPatch = .{};
    var log: command.CommandLog = .{};
    var exec: command.Executor = undefined;
    wireExec(&app, &log, &exec);

    var buf: [64]u8 = undefined;
    _ = try exec.executeAction("noop_pattern", "", .{ .actor = .local_user }, &buf);
    try testing.expect(!log.latest().?.undoable);
    const u = try exec.undoOne(.local_user, &buf);
    try testing.expect(!u.happened);
}

test "ring overflow makes old undo_ref canUndo=false" {
    var app: MockPatch = .{};
    var log: command.CommandLog = .{};
    var exec: command.Executor = undefined;
    wireExec(&app, &log, &exec);

    var buf: [64]u8 = undefined;
    _ = try exec.executeAction("toggle_step", "kick 0", .{ .actor = .local_user }, &buf);
    const first_ref = log.latest().?.undo_ref.?;

    var i: usize = 0;
    while (i < undo.MAX_UNDO) : (i += 1) {
        _ = try exec.executeAction("toggle_step", "kick 0", .{ .actor = .local_user }, &buf);
    }
    try testing.expect(!app.store.valid(first_ref));
    try testing.expect(!app.store.valid(first_ref));
}

test "undo then new action invalidates redo epoch" {
    var app: MockPatch = .{};
    var log: command.CommandLog = .{};
    var exec: command.Executor = undefined;
    wireExec(&app, &log, &exec);

    var buf: [64]u8 = undefined;
    _ = try exec.executeAction("toggle_step", "kick 0", .{ .actor = .local_user }, &buf);
    _ = try exec.undoOne(.local_user, &buf);
    _ = try exec.executeAction("toggle_step", "kick 0", .{ .actor = .local_user }, &buf);
    const r = try exec.redoOne(.local_user, &buf);
    try testing.expect(!r.happened);
}

test "undo marks normal record reverted and appends revert kind" {
    var app: MockPatch = .{};
    var log: command.CommandLog = .{};
    var exec: command.Executor = undefined;
    wireExec(&app, &log, &exec);

    var buf: [64]u8 = undefined;
    _ = try exec.executeAction("set_param", "tempo 140", .{ .actor = .local_user }, &buf);
    const edit_seq = log.latest().?.seq;
    _ = try exec.undoOne(.local_user, &buf);

    const undone = log.findBySeq(edit_seq).?;
    try testing.expect(undone.reverted);
    try testing.expectEqual(HistoryRowClass.reverted, classifyHistoryRow(undone.kind, undone.reverted));

    const rev = log.latest().?;
    try testing.expectEqual(command.CommandKind.revert, rev.kind);
    try testing.expectEqual(HistoryRowClass.revert, classifyHistoryRow(rev.kind, rev.reverted));
}

test "redo appends normal record with redo_of" {
    var app: MockPatch = .{};
    var log: command.CommandLog = .{};
    var exec: command.Executor = undefined;
    wireExec(&app, &log, &exec);

    var buf: [64]u8 = undefined;
    _ = try exec.executeAction("set_param", "tempo 140", .{ .actor = .local_user }, &buf);
    const edit_seq = log.latest().?.seq;
    _ = try exec.undoOne(.local_user, &buf);
    _ = try exec.redoOne(.local_user, &buf);

    const redone = log.latest().?;
    try testing.expectEqual(command.CommandKind.normal, redone.kind);
    try testing.expectEqual(@as(?u64, edit_seq), redone.redo_of);
    try testing.expectEqual(HistoryRowClass.normal, classifyHistoryRow(redone.kind, redone.reverted));
    try testing.expectEqual(@as(f32, 140.0), app.tempo);
}

test "history row class mapping" {
    try testing.expectEqual(HistoryRowClass.normal, classifyHistoryRow(.normal, false));
    try testing.expectEqual(HistoryRowClass.reverted, classifyHistoryRow(.normal, true));
    try testing.expectEqual(HistoryRowClass.revert, classifyHistoryRow(.revert, false));
    try testing.expectEqual(HistoryRowClass.revert, classifyHistoryRow(.revert, true));
}

test "pending param before is not consumed by mismatched param name" {
    // pending に param A (tempo) の before を積んだ状態で param B (cutoff) が来ても消費されない。
    var slot: PendingParamUndo = .{};
    var before_a = undo.ParamValueSnap{ .mode = 0 };
    before_a.setName("tempo");
    before_a.value_kind = 0;
    before_a.value_bits = @bitCast(@as(f32, 122.0));
    slot.pending = before_a;

    const taken_b = slot.takeIfNameMatches("cutoff");
    try testing.expect(taken_b == null);
    try testing.expect(slot.pending != null);
    try testing.expectEqualStrings("tempo", slot.pending.?.name());
    try testing.expectEqual(@as(f32, 122.0), @as(f32, @bitCast(slot.pending.?.value_bits)));

    const taken_a = slot.takeIfNameMatches("tempo");
    try testing.expect(taken_a != null);
    try testing.expect(slot.pending == null);
    try testing.expectEqualStrings("tempo", taken_a.?.name());
    try testing.expectEqual(@as(f32, 122.0), @as(f32, @bitCast(taken_a.?.value_bits)));
}
