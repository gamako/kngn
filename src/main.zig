const std = @import("std");
const video_proto = @import("video_proto");

// C関数をインポート
const c = @cImport({
    @cInclude("math.h");
});

pub fn main() !void {
    // Prints to stderr, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
    try video_proto.bufferedPrint();

    // C言語の関数を呼び出す
    const result_add = c.add(5, 3);
    const result_mul = c.multiply(5, 3);

    std.debug.print("\nC function calls:\n", .{});
    std.debug.print("add(5, 3) = {d}\n", .{result_add});
    std.debug.print("multiply(5, 3) = {d}\n", .{result_mul});
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
