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

test "IHDR chunk parsing from 1x1 grayscale PNG" {
    const allocator = std.testing.allocator;

    // ファイル全体を読み込み
    const file_data = try std.fs.cwd().readFileAlloc(
        "test-data/1x1_grayscale.png",
        allocator,
        .unlimited
    );
    defer allocator.free(file_data);

    // 署名をスキップ（8バイト）
    const after_signature = file_data[8..];

    // 最初のチャンクを読み取り（IHDR）
    const chunk = try lib.png_parser.readChunk(after_signature, 0);

    // IHDRチャンクであることを確認
    try std.testing.expectEqualSlices(u8, "IHDR", &chunk.chunk_type);
    try std.testing.expect(chunk.data.len == 13);

    // IHDR情報を解析
    const ihdr = try lib.png_parser.parseIHDR(chunk);
    try std.testing.expectEqual(@as(u32, 1), ihdr.width);
    try std.testing.expectEqual(@as(u32, 1), ihdr.height);
    try std.testing.expectEqual(@as(u8, 8), ihdr.bit_depth);
    try std.testing.expectEqual(@as(u8, 0), ihdr.color_type);  // Grayscale
}
