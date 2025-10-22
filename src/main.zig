const std = @import("std");
const video_proto = @import("video_proto");

// C関数をインポート
const c = @cImport({
    @cInclude("math.h");
    @cInclude("external.h");
    @cInclude("platform.h");
});

pub fn main() !void {
    // Prints to stderr, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
    try video_proto.bufferedPrint();

    // プラットフォーム初期化
    std.debug.print("\nInitializing platform...\n", .{});
    const platform_initialized = c.platform_init();
    std.debug.print("Platform initialized: {}\n", .{platform_initialized});

    // math.c の関数を呼び出す
    const result_add = c.add(5, 3);
    const result_mul = c.multiply(5, 3);

    std.debug.print("\nC function calls (math.c):\n", .{});
    std.debug.print("add(5, 3) = {d}\n", .{result_add});
    std.debug.print("multiply(5, 3) = {d}\n", .{result_mul});

    // external.c の関数を呼び出す
    const external_add_result = c.external_add(10, 7);
    const external_mul_result = c.external_multiply(10, 7);
    const external_div_result = c.external_divide(15, 3);

    std.debug.print("\nC function calls (external.c):\n", .{});
    std.debug.print("external_add(10, 7) = {d}\n", .{external_add_result});
    std.debug.print("external_multiply(10, 7) = {d}\n", .{external_mul_result});
    std.debug.print("external_divide(15, 3) = {d}\n", .{external_div_result});

    // external.m (Objective-C) の関数を呼び出す
    const external_add_objc_result = c.external_add_objc(20, 8);
    const external_mul_objc_result = c.external_multiply_objc(20, 8);
    const external_div_objc_result = c.external_divide_objc(20, 4);

    std.debug.print("\nObjective-C function calls (external.m):\n", .{});
    std.debug.print("external_add_objc(20, 8) = {d}\n", .{external_add_objc_result});
    std.debug.print("external_multiply_objc(20, 8) = {d}\n", .{external_mul_objc_result});
    std.debug.print("external_divide_objc(20, 4) = {d}\n", .{external_div_objc_result});

    // external.swift (Swift) の関数を呼び出す
    const external_add_swift_result = c.external_add_swift(12, 6);
    const external_mul_swift_result = c.external_multiply_swift(12, 6);
    const external_div_swift_result = c.external_divide_swift(30, 5);

    std.debug.print("\nSwift function calls (external.swift):\n", .{});
    std.debug.print("external_add_swift(12, 6) = {d}\n", .{external_add_swift_result});
    std.debug.print("external_multiply_swift(12, 6) = {d}\n", .{external_mul_swift_result});
    std.debug.print("external_divide_swift(30, 5) = {d}\n", .{external_div_swift_result});
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
