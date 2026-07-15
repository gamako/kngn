//! modular の CommandRecord 配線（TASK-62.5.7）の最小契約テスト。
//!
//! main.zig の `recordedAction` + `dispatchModularAction` と同じ
//! `Executor.executeAction` → CommandLog 経路で、`seed` が
//! CommandRecord{name="seed", args="42"} として記録されることを固定する。
//! （undo/tx なし・記録のみ。command.zig は既存 API の利用のみ。）

const std = @import("std");
const command = @import("command");

const MockApp = struct {
    last_seed: u64 = 0,

    fn run(ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
        _ = buf;
        const self: *MockApp = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, name, "seed")) return error.UnknownAction;
        self.last_seed = std.fmt.parseUnsigned(u64, args, 10) catch return error.InvalidNumber;
        return "ok";
    }
};

test "CommandRecord: seed action is recorded as name=seed args=42" {
    var app: MockApp = .{};
    var log: command.CommandLog = .{};
    var exec = command.Executor.init(.{ .ctx = &app, .run = MockApp.run });
    exec.log = &log;

    var buf: [64]u8 = undefined;
    const res = try exec.executeAction("seed", "42", .{
        .actor = .local_agent,
        .record_policy = .record,
    }, &buf);
    try testing.expectEqualStrings("ok", res.output);
    try testing.expectEqual(@as(u64, 42), app.last_seed);

    const rec = log.latest() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("seed", rec.name());
    try testing.expectEqualStrings("42", rec.args());
    try testing.expectEqual(command.CommandKind.normal, rec.kind);
}

const testing = std.testing;
