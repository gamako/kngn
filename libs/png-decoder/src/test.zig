// PNG Decoder Test Suite
// Tests for PNG signature verification from actual PNG file

const std = @import("std");
const lib = @import("lib.zig");
const test_cases = @import("test_cases.zig");

test "1x1 grayscale PNG signature verification" {
    // Read the actual PNG file
    const file = try std.fs.cwd().openFile("test-data/1x1_grayscale.png", .{});
    defer file.close();

    var buffer: [1024]u8 = undefined;
    const bytes_read = try file.read(buffer[0..]);

    // Verify PNG signature from the actual file
    try std.testing.expect(lib.png_parser.verifySignature(buffer[0..bytes_read]));
}

test "Invalid PNG data rejection" {
    const invalid_png = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    try std.testing.expect(!lib.png_parser.verifySignature(&invalid_png));
}
