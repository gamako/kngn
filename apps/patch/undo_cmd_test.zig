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
    /// add_node / move_node の簡易状態（非 harness Executor 直行経路の回帰用）。
    node_count: u32 = 0,
    last_move_id: u64 = 0,
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
            // TASK-160.3: "#<id> <name> <value>" のみ（旧 Transport alias 2 トークンは拒否）。
            var it = std.mem.tokenizeAny(u8, args, " \t");
            const id_tok = it.next() orelse return error.Empty;
            const pname = it.next() orelse return error.Empty;
            const pval_s = it.next() orelse return error.Empty;
            if (it.next() != null) return error.TooManyTokens;
            if (id_tok.len < 2 or id_tok[0] != '#') return error.InvalidNumber;
            _ = try std.fmt.parseUnsigned(u64, id_tok[1..], 10);
            const pval = try std.fmt.parseFloat(f32, pval_s);
            if (!std.mem.eql(u8, pname, "bpm")) return error.UnknownParam;
            const before = self.tempo;
            self.tempo = pval;
            if (before != pval) {
                var snap = undo.ParamValueSnap{ .mode = 1, .node_id = 1 };
                snap.setName("bpm");
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
        if (std.mem.eql(u8, name, "add_node")) {
            // GUI palette / routeUiActionInto 非 netsync 分岐相当: registry 無しで Executor 直行。
            self.node_count += 1;
            const id: u64 = self.node_count;
            const ref = self.store.push(.{ .add_node = .{ .id = id, .kind_tag = 0, .x = 0, .y = 0 } });
            self.exec.noteUndo(ref);
            return std.fmt.bufPrint(buf, "ok id=#{d}", .{id}) catch "ok";
        }
        if (std.mem.eql(u8, name, "move_node")) {
            // "#{id} x y"
            var it = std.mem.tokenizeAny(u8, args, " \t");
            const id_tok = it.next() orelse return error.Empty;
            if (id_tok.len < 2 or id_tok[0] != '#') return error.InvalidNumber;
            const id = try std.fmt.parseUnsigned(u64, id_tok[1..], 10);
            _ = it.next() orelse return error.Empty;
            _ = it.next() orelse return error.Empty;
            self.last_move_id = id;
            const ref = self.store.push(.{ .move_node = .{ .id = id, .x = 0, .y = 0 } });
            self.exec.noteUndo(ref);
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
                if (std.mem.eql(u8, s.name(), "bpm")) {
                    self.tempo = @bitCast(s.value_bits);
                }
            },
            .mute => |s| {
                if (s.track == 0) self.kick_mute = s.was_muted;
            },
            .add_node => {
                if (self.node_count > 0) self.node_count -= 1;
            },
            .move_node => |s| {
                self.last_move_id = s.id; // restore marker only
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

test "set_param #id bpm undo redo restores value" {
    var app: MockPatch = .{};
    var log: command.CommandLog = .{};
    var exec: command.Executor = undefined;
    wireExec(&app, &log, &exec);

    var buf: [64]u8 = undefined;
    app.tempo = 122.0;
    _ = try exec.executeAction("set_param", "#1 bpm 140", .{ .actor = .local_user }, &buf);
    try testing.expectEqual(@as(f32, 140.0), app.tempo);
    try testing.expect(log.latest().?.undoable);

    _ = try exec.undoOne(.local_user, &buf);
    try testing.expectEqual(@as(f32, 122.0), app.tempo);

    _ = try exec.redoOne(.local_user, &buf);
    try testing.expectEqual(@as(f32, 140.0), app.tempo);
}

test "set_param rejects legacy 2-token transport alias" {
    var app: MockPatch = .{};
    var log: command.CommandLog = .{};
    var exec: command.Executor = undefined;
    wireExec(&app, &log, &exec);

    var buf: [64]u8 = undefined;
    try testing.expectError(error.Empty, exec.executeAction("set_param", "tempo 140", .{ .actor = .local_user }, &buf));
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
    _ = try exec.executeAction("set_param", "#1 bpm 122", .{ .actor = .local_user }, &buf);
    try testing.expect(!log.latest().?.undoable);
}

test "non-undoable camera action does not block prior undo" {
    var app: MockPatch = .{};
    var log: command.CommandLog = .{};
    var exec: command.Executor = undefined;
    wireExec(&app, &log, &exec);

    var buf: [64]u8 = undefined;
    app.tempo = 122.0;
    _ = try exec.executeAction("set_param", "#1 bpm 140", .{ .actor = .local_user }, &buf);
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
    _ = try exec.executeAction("set_param", "#1 bpm 140", .{ .actor = .local_user }, &buf);
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
    _ = try exec.executeAction("set_param", "#1 bpm 140", .{ .actor = .local_user }, &buf);
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
    // pending に param A (bpm) の before を積んだ状態で param B (cutoff) が来ても消費されない。
    var slot: PendingParamUndo = .{};
    var before_a = undo.ParamValueSnap{ .mode = 1, .node_id = 1 };
    before_a.setName("bpm");
    before_a.value_kind = 0;
    before_a.value_bits = @bitCast(@as(f32, 122.0));
    slot.pending = before_a;

    const taken_b = slot.takeIfNameMatches("cutoff");
    try testing.expect(taken_b == null);
    try testing.expect(slot.pending != null);
    try testing.expectEqualStrings("bpm", slot.pending.?.name());
    try testing.expectEqual(@as(f32, 122.0), @as(f32, @bitCast(slot.pending.?.value_bits)));

    const taken_a = slot.takeIfNameMatches("bpm");
    try testing.expect(taken_a != null);
    try testing.expect(slot.pending == null);
    try testing.expectEqualStrings("bpm", taken_a.?.name());
    try testing.expectEqual(@as(f32, 122.0), @as(f32, @bitCast(taken_a.?.value_bits)));
}

// main.zig `routeUiActionInto` の非 netsync 分岐相当: registry / router 無しで
// `Executor.executeAction` 直行が add_node / set_param / move_node を成功させ CommandLog に記録する。
// harness 無効時 registerAction が no-op でも GUI が UnknownAction にならない契約を固定する。
test "non-harness routeUiAction path: Executor executeAction without registry" {
    var app: MockPatch = .{};
    var log: command.CommandLog = .{};
    var exec: command.Executor = undefined;
    wireExec(&app, &log, &exec);

    var buf: [64]u8 = undefined;

    // add_node
    const add_res = try exec.executeAction("add_node", "vca 10 20", .{ .actor = .local_user, .record_policy = .record }, &buf);
    try testing.expect(std.mem.startsWith(u8, add_res.output, "ok id=#"));
    try testing.expectEqual(@as(u32, 1), app.node_count);
    try testing.expect(log.latest().?.undoable);
    try testing.expectEqualStrings("add_node", log.latest().?.name());

    // set_param
    app.tempo = 122.0;
    _ = try exec.executeAction("set_param", "#1 bpm 140", .{ .actor = .local_user, .record_policy = .record }, &buf);
    try testing.expectEqual(@as(f32, 140.0), app.tempo);
    try testing.expectEqualStrings("set_param", log.latest().?.name());
    try testing.expect(log.latest().?.undoable);

    // move_node
    _ = try exec.executeAction("move_node", "#1 50 60", .{ .actor = .local_user, .record_policy = .record }, &buf);
    try testing.expectEqual(@as(u64, 1), app.last_move_id);
    try testing.expectEqualStrings("move_node", log.latest().?.name());
    try testing.expect(log.latest().?.undoable);

    // CommandLog に 3 件（いずれも registry を経由していない）
    try testing.expectEqual(@as(u32, 3), log.filled);

    // undo で move → set_param → add_node
    _ = try exec.undoOne(.local_user, &buf);
    _ = try exec.undoOne(.local_user, &buf);
    try testing.expectEqual(@as(f32, 122.0), app.tempo);
    _ = try exec.undoOne(.local_user, &buf);
    try testing.expectEqual(@as(u32, 0), app.node_count);
}
