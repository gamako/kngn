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

        // パターンに応じて期待値を取得（検証用）
        const expected_pixels = switch (tc.pattern) {
            .hardcoded => |pixels| pixels,
            .gradient => |g| try test_cases.generateGradientExpected(
                allocator,
                tc.width,
                tc.height,
                g.step,
            ),
        };
        defer {
            if (tc.pattern == .gradient) {
                allocator.free(expected_pixels);
            }
        }

        // テストケースが有効（ここでは期待値の存在確認）
        try std.testing.expect(expected_pixels.len == tc.width * tc.height);
    }
}

test "ChunkIterator - iterate all chunks" {
    const allocator = std.testing.allocator;

    // 1x1_grayscale.png を読み込み
    const file_data = try std.fs.cwd().readFileAlloc(
        "test-data/1x1_grayscale.png",
        allocator,
        .unlimited
    );
    defer allocator.free(file_data);

    // PNG署名を確認
    try std.testing.expect(lib.png_parser.verifySignature(file_data));

    // チャンクイテレータを初期化
    var iter = lib.png_parser.ChunkIterator.init(file_data);

    // チャンク列を読み取り
    var chunks: std.ArrayList([4]u8) = .empty;
    defer chunks.deinit(allocator);

    while (try iter.next()) |chunk| {
        try chunks.append(allocator, chunk.chunk_type);
    }

    // チャンクの順序を検証
    try std.testing.expect(chunks.items.len >= 3); // IHDR, IDAT, IEND

    // 最初のチャンクがIHDR
    try std.testing.expectEqualSlices(u8, "IHDR", chunks.items[0][0..]);

    // 最後のチャンクがIEND
    const last_chunk = chunks.items[chunks.items.len - 1];
    try std.testing.expectEqualSlices(u8, "IEND", last_chunk[0..]);

    // IHDR と IEND の間に IDAT が存在
    var found_idat = false;
    for (chunks.items[1 .. chunks.items.len - 1]) |chunk| {
        if (std.mem.eql(u8, chunk[0..], "IDAT")) {
            found_idat = true;
            break;
        }
    }
    try std.testing.expect(found_idat);
}

test "Collect IDAT chunks" {
    const allocator = std.testing.allocator;

    // 1x1_grayscale.png を読み込み
    const file_data = try std.fs.cwd().readFileAlloc(
        "test-data/1x1_grayscale.png",
        allocator,
        .unlimited
    );
    defer allocator.free(file_data);

    // IDAT チャンクを収集
    const idat_data = try lib.png_parser.collectIDATChunks(allocator, file_data);
    defer allocator.free(idat_data);

    // IDAT データが存在することを確認
    try std.testing.expect(idat_data.len > 0);
}
