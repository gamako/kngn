//! Wiring contract test for modular / patch's CommandRecord.
//!
//! Mocks the same `Executor.executeAction` → CommandLog path used by main.zig's `recordedGraphAction` /
//! `recordedAction` + `dispatchModularAction`, fixing the recording contract.
//! (No undo/tx, recording only. command.zig only uses its existing API.)

const std = @import("std");
const command = @import("command");

const graph_actions = [_]struct { name: []const u8, args: []const u8 }{
    .{ .name = "add_node", .args = "vco 100 100" },
    .{ .name = "remove_node", .args = "#31" },
    .{ .name = "connect", .args = "#31 0 #32 0" },
    .{ .name = "disconnect", .args = "#32 0" },
    .{ .name = "move_node", .args = "#31 120 130" },
    .{ .name = "add_macro", .args = "bass_machine 400 300" },
    .{ .name = "remove_macro", .args = "#33 #34 #35 #36 #37" },
};

/// An action that bypasses Executor in main.zig (no `recordedAction` / `recordedGraphAction` wrapper).
const meta_actions = [_][]const u8{
    "save_graph",
    "save_pattern",
    "save_project",
    "recipe_save",
    "load_graph",
    "load_pattern",
    "load_project",
    "recipe_replay",
    "render",
    "select_node",
    "observe_param",
};

const MockApp = struct {
    last_seed: u64 = 0,
    last_action: []const u8 = "",
    last_args: []const u8 = "",

    fn run(ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
        _ = buf;
        const self: *MockApp = @ptrCast(@alignCast(ctx));
        self.last_action = name;
        self.last_args = args;
        if (std.mem.eql(u8, name, "seed")) {
            self.last_seed = std.fmt.parseUnsigned(u64, args, 10) catch return error.InvalidNumber;
            return "ok";
        }
        inline for (graph_actions) |ga| {
            if (std.mem.eql(u8, name, ga.name)) return "ok";
        }
        inline for (meta_actions) |ma| {
            if (std.mem.eql(u8, name, ma)) return "ok";
        }
        return error.UnknownAction;
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

test "CommandRecord: graph actions record canonical #id args as one normal record each" {
    var app: MockApp = .{};
    var log: command.CommandLog = .{};
    var exec = command.Executor.init(.{ .ctx = &app, .run = MockApp.run });
    exec.log = &log;

    var buf: [128]u8 = undefined;
    for (graph_actions) |ga| {
        const before = log.filled;
        const res = try exec.executeAction(ga.name, ga.args, .{
            .actor = .local_agent,
            .record_policy = .record,
        }, &buf);
        try testing.expectEqualStrings("ok", res.output);
        try testing.expectEqual(before + 1, log.filled);
        const rec = log.latest() orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(ga.name, rec.name());
        try testing.expectEqualStrings(ga.args, rec.args());
        try testing.expectEqual(command.CommandKind.normal, rec.kind);
    }
}

test "CommandRecord: graph actions preserve execution order in log" {
    var app: MockApp = .{};
    var log: command.CommandLog = .{};
    var exec = command.Executor.init(.{ .ctx = &app, .run = MockApp.run });
    exec.log = &log;

    var buf: [128]u8 = undefined;
    for (graph_actions) |ga| {
        _ = try exec.executeAction(ga.name, ga.args, .{
            .actor = .local_agent,
            .record_policy = .record,
        }, &buf);
    }

    try testing.expectEqual(@as(u32, graph_actions.len), log.filled);
    for (graph_actions, 0..) |ga, i| {
        const rec = log.recordAt(@intCast(i));
        try testing.expectEqualStrings(ga.name, rec.name());
        try testing.expectEqualStrings(ga.args, rec.args());
        try testing.expectEqual(command.CommandKind.normal, rec.kind);
    }
}

test "CommandRecord: meta actions bypass Executor and are not recorded" {
    var app: MockApp = .{};
    const log: command.CommandLog = .{};
    var buf: [128]u8 = undefined;

    for (meta_actions) |name| {
        const out = try MockApp.run(&app, name, "/tmp/dummy", &buf);
        try testing.expectEqualStrings("ok", out);
        try testing.expectEqual(@as(u32, 0), log.filled);
    }
}

const testing = std.testing;
