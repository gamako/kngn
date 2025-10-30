// PNG Decoder Test Suite
// Integration tests for PNG parsing (unit tests are in respective modules)

const std = @import("std");
const lib = @import("lib.zig");
const test_cases = @import("test_cases.zig");

test "All test cases - IHDR verification" {
    const allocator = std.testing.allocator;

    // test_cases の全テストケースについて検証
    for (test_cases.test_cases) |tc| {
        // ファイルを読み込み
        const file_data = try std.fs.cwd().readFileAlloc(
            tc.file_path,
            allocator,
            .unlimited
        );
        defer allocator.free(file_data);

        // PNG署名を確認
        try std.testing.expect(lib.png_parser.verifySignature(file_data));

        // 署名をスキップ（8バイト）
        const after_signature = file_data[8..];

        // 最初のチャンクを読み取り（IHDR）
        const chunk = try lib.png_parser.readChunk(after_signature, 0);

        // IHDRチャンクであることを確認
        try std.testing.expectEqualSlices(u8, "IHDR", &chunk.chunk_type);
        try std.testing.expect(chunk.data.len == 13);

        // IHDR情報を解析して、期待値と一致することを確認
        const ihdr = try lib.png_parser.parseIHDR(chunk);
        try std.testing.expectEqual(tc.width, ihdr.width);
        try std.testing.expectEqual(tc.height, ihdr.height);
    }
}
