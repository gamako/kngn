// PNG Decoder Test Suite
// Integration tests for PNG parsing (unit tests are in respective modules)

const std = @import("std");
const lib = @import("lib.zig");
const test_cases = @import("test_cases.zig");
const flate_tests = @import("flate.zig");
const filter = @import("filter.zig");
const format = @import("format.zig");

/// Test helper: Read a PNG chunk from data at the specified offset
/// Returns the chunk structure with type and data
fn readChunk(data: []const u8, offset: usize) !lib.png_parser.Chunk {
    if (offset + 8 > data.len) return error.InvalidChunkSize;

    const length = std.mem.readInt(u32, data[offset..][0..4], .big);
    const chunk_type = data[offset + 4 .. offset + 8][0..4].*;

    if (offset + 8 + length > data.len) return error.InvalidChunkSize;

    const chunk_data = data[offset + 8 .. offset + 8 + length];

    return lib.png_parser.Chunk{
        .chunk_type = chunk_type,
        .data = chunk_data,
    };
}

test "All test cases - IHDR verification" {
    const allocator = std.testing.allocator;

    // test_cases の全テストケースについて検証
    for (test_cases.test_cases) |tc| {
        // ファイルを読み込み
        const file_data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, tc.file_path, allocator, .unlimited);
        defer allocator.free(file_data);

        // PNG署名を確認
        try std.testing.expect(lib.png_parser.verifySignature(file_data));

        // 署名をスキップ（8バイト）
        const after_signature = file_data[8..];

        // 最初のチャンクを読み取り（IHDR）
        const chunk = try readChunk(after_signature, 0);

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
            .rgb_checkerboard => try test_cases.generateRGBCheckerboardExpected(
                allocator,
                tc.width,
                tc.height,
            ),
            .rgb_gradient => try test_cases.generateRGBGradientExpected(
                allocator,
                tc.width,
                tc.height,
            ),
            .rgba_checkerboard => try test_cases.generateRGBACheckerboardExpected(
                allocator,
                tc.width,
                tc.height,
            ),
            .rgba_gradient => try test_cases.generateRGBAGradientExpected(
                allocator,
                tc.width,
                tc.height,
            ),
        };
        defer {
            if (tc.pattern == .gradient or tc.pattern == .rgb_checkerboard or tc.pattern == .rgb_gradient or tc.pattern == .rgba_checkerboard or tc.pattern == .rgba_gradient) {
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
    const file_data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test-data/1x1_grayscale.png", allocator, .unlimited);
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
    const file_data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test-data/1x1_grayscale.png", allocator, .unlimited);
    defer allocator.free(file_data);

    // IDAT チャンクを収集
    const idat_data = try lib.png_parser.collectIDATChunks(allocator, file_data);
    defer allocator.free(idat_data);

    // IDAT データが存在することを確認
    try std.testing.expect(idat_data.len > 0);
}

test "Filter - apply filters to decompressed data" {
    const allocator = std.testing.allocator;

    // Process all test cases that have grayscale filter patterns
    const filter_test_cases = [_]struct {
        file_path: []const u8,
        width: u32,
        height: u32,
        step: u8,
    }{
        .{
            .file_path = "test-data/8x8_gray_filter_none.png",
            .width = 8,
            .height = 8,
            .step = 32,
        },
        .{
            .file_path = "test-data/8x8_gray_filter_sub.png",
            .width = 8,
            .height = 8,
            .step = 32,
        },
        .{
            .file_path = "test-data/8x8_gray_filter_up.png",
            .width = 8,
            .height = 8,
            .step = 32,
        },
        .{
            .file_path = "test-data/8x8_gray_filter_average.png",
            .width = 8,
            .height = 8,
            .step = 32,
        },
        .{
            .file_path = "test-data/8x8_gray_filter_paeth.png",
            .width = 8,
            .height = 8,
            .step = 32,
        },
        .{
            .file_path = "test-data/16x16_gray_filter_none.png",
            .width = 16,
            .height = 16,
            .step = 16,
        },
        .{
            .file_path = "test-data/16x16_gray_filter_sub.png",
            .width = 16,
            .height = 16,
            .step = 16,
        },
        .{
            .file_path = "test-data/16x16_gray_filter_up.png",
            .width = 16,
            .height = 16,
            .step = 16,
        },
        .{
            .file_path = "test-data/16x16_gray_filter_average.png",
            .width = 16,
            .height = 16,
            .step = 16,
        },
        .{
            .file_path = "test-data/16x16_gray_filter_paeth.png",
            .width = 16,
            .height = 16,
            .step = 16,
        },
    };

    for (filter_test_cases) |tc| {
        // Read PNG file
        const file_data = try std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            tc.file_path,
            allocator,
            .unlimited,
        );
        defer allocator.free(file_data);

        // Verify signature
        try std.testing.expect(lib.png_parser.verifySignature(file_data));

        // Collect IDAT chunks
        const idat_data = try lib.png_parser.collectIDATChunks(allocator, file_data);
        defer allocator.free(idat_data);

        // Decompress IDAT data
        const decompressed = try flate_tests.decompressZlib(allocator, idat_data);
        defer allocator.free(decompressed);

        // Apply filters (1 byte per pixel for grayscale)
        const filtered = try filter.applyFilters(
            allocator,
            decompressed,
            tc.width,
            tc.height,
            1, // bytes per pixel for grayscale
        );
        defer allocator.free(filtered);

        // Generate expected gradient pattern
        const expected = try test_cases.generateGradientExpected(
            allocator,
            tc.width,
            tc.height,
            tc.step,
        );
        defer allocator.free(expected);

        // Verify filtered data matches expected gradient pattern
        // Each pixel value should be a grayscale value (0-255)
        for (0..tc.height) |y| {
            for (0..tc.width) |x| {
                const idx = y * tc.width + x;
                const gray_value = filtered[idx];
                const expected_gray = @as(u8, @intCast((y * tc.step) & 0xFF));

                try std.testing.expectEqual(
                    expected_gray,
                    gray_value,
                );
            }
        }
    }
}

test "Format conversion - grayscale to RGBA8888" {
    const allocator = std.testing.allocator;

    // Process all test cases for format conversion
    const format_test_cases = [_]struct {
        file_path: []const u8,
        width: u32,
        height: u32,
        step: u8,
    }{
        .{
            .file_path = "test-data/8x8_gray_filter_none.png",
            .width = 8,
            .height = 8,
            .step = 32,
        },
        .{
            .file_path = "test-data/8x8_gray_filter_sub.png",
            .width = 8,
            .height = 8,
            .step = 32,
        },
        .{
            .file_path = "test-data/8x8_gray_filter_up.png",
            .width = 8,
            .height = 8,
            .step = 32,
        },
        .{
            .file_path = "test-data/8x8_gray_filter_average.png",
            .width = 8,
            .height = 8,
            .step = 32,
        },
        .{
            .file_path = "test-data/8x8_gray_filter_paeth.png",
            .width = 8,
            .height = 8,
            .step = 32,
        },
        .{
            .file_path = "test-data/16x16_gray_filter_none.png",
            .width = 16,
            .height = 16,
            .step = 16,
        },
        .{
            .file_path = "test-data/16x16_gray_filter_sub.png",
            .width = 16,
            .height = 16,
            .step = 16,
        },
        .{
            .file_path = "test-data/16x16_gray_filter_up.png",
            .width = 16,
            .height = 16,
            .step = 16,
        },
        .{
            .file_path = "test-data/16x16_gray_filter_average.png",
            .width = 16,
            .height = 16,
            .step = 16,
        },
        .{
            .file_path = "test-data/16x16_gray_filter_paeth.png",
            .width = 16,
            .height = 16,
            .step = 16,
        },
    };

    for (format_test_cases) |tc| {
        // Read PNG file
        const file_data = try std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            tc.file_path,
            allocator,
            .unlimited,
        );
        defer allocator.free(file_data);

        // Verify signature
        try std.testing.expect(lib.png_parser.verifySignature(file_data));

        // Collect IDAT chunks
        const idat_data = try lib.png_parser.collectIDATChunks(allocator, file_data);
        defer allocator.free(idat_data);

        // Decompress IDAT data
        const decompressed = try flate_tests.decompressZlib(allocator, idat_data);
        defer allocator.free(decompressed);

        // Apply filters (1 byte per pixel for grayscale)
        const filtered = try filter.applyFilters(
            allocator,
            decompressed,
            tc.width,
            tc.height,
            1, // bytes per pixel for grayscale
        );
        defer allocator.free(filtered);

        // Convert grayscale to RGBA8888
        const rgba_data = try format.grayscaleToRGBA8888(allocator, filtered);
        defer allocator.free(rgba_data);

        // Verify conversion result
        try std.testing.expectEqual(tc.width * tc.height, rgba_data.len);

        // Verify each pixel value
        for (0..tc.height) |y| {
            for (0..tc.width) |x| {
                const idx = y * tc.width + x;
                const gray_value = filtered[idx];

                // Expected BGRA8888: byte order [B, G, R, A] (u32 = 0xAARRGGBB on little-endian)
                const expected_rgba = test_cases.packRGBA(gray_value, gray_value, gray_value, 0xFF);

                try std.testing.expectEqual(
                    expected_rgba,
                    rgba_data[idx],
                );
            }
        }
    }
}

test "Phase 1 - end-to-end decodePNG test (8x8 grayscale)" {
    const allocator = std.testing.allocator;

    // Read PNG file
    const file_data = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "test-data/8x8_gray_filter_none.png",
        allocator,
        .unlimited,
    );
    defer allocator.free(file_data);

    // Decode PNG
    var png_image = try lib.decodePNG(allocator, file_data);
    defer png_image.deinit(allocator);

    // Verify dimensions
    try std.testing.expectEqual(@as(u32, 8), png_image.width);
    try std.testing.expectEqual(@as(u32, 8), png_image.height);

    // Verify pixel count
    try std.testing.expectEqual(@as(usize, 64), png_image.pixels.len);

    // Verify RGBA values (all pixels should have A=255)
    for (png_image.pixels) |pixel| {
        const alpha = pixel >> 24;
        try std.testing.expectEqual(@as(u32, 0xFF), alpha);
    }
}

test "Phase 1 - end-to-end decodePNG test (16x16 grayscale)" {
    const allocator = std.testing.allocator;

    // Read PNG file
    const file_data = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "test-data/16x16_gray_filter_none.png",
        allocator,
        .unlimited,
    );
    defer allocator.free(file_data);

    // Decode PNG
    var png_image = try lib.decodePNG(allocator, file_data);
    defer png_image.deinit(allocator);

    // Verify dimensions
    try std.testing.expectEqual(@as(u32, 16), png_image.width);
    try std.testing.expectEqual(@as(u32, 16), png_image.height);

    // Verify pixel count
    try std.testing.expectEqual(@as(usize, 256), png_image.pixels.len);

    // Verify RGBA values (all pixels should have A=255)
    for (png_image.pixels) |pixel| {
        const alpha = pixel >> 24;
        try std.testing.expectEqual(@as(u32, 0xFF), alpha);
    }
}

test "Phase 2 - end-to-end decodePNG test (Average filter)" {
    const allocator = std.testing.allocator;

    // Read PNG file with Average filter
    const file_data = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "test-data/8x8_gray_filter_average.png",
        allocator,
        .unlimited,
    );
    defer allocator.free(file_data);

    // Decode PNG
    var png_image = try lib.decodePNG(allocator, file_data);
    defer png_image.deinit(allocator);

    // Verify dimensions
    try std.testing.expectEqual(@as(u32, 8), png_image.width);
    try std.testing.expectEqual(@as(u32, 8), png_image.height);

    // Verify pixel count
    try std.testing.expectEqual(@as(usize, 64), png_image.pixels.len);

    // Verify RGBA values (all pixels should have A=255)
    for (png_image.pixels) |pixel| {
        const alpha = pixel >> 24;
        try std.testing.expectEqual(@as(u32, 0xFF), alpha);
    }
}

test "Phase 2 - end-to-end decodePNG test (Paeth filter)" {
    const allocator = std.testing.allocator;

    // Read PNG file with Paeth filter
    const file_data = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "test-data/8x8_gray_filter_paeth.png",
        allocator,
        .unlimited,
    );
    defer allocator.free(file_data);

    // Decode PNG
    var png_image = try lib.decodePNG(allocator, file_data);
    defer png_image.deinit(allocator);

    // Verify dimensions
    try std.testing.expectEqual(@as(u32, 8), png_image.width);
    try std.testing.expectEqual(@as(u32, 8), png_image.height);

    // Verify pixel count
    try std.testing.expectEqual(@as(usize, 64), png_image.pixels.len);

    // Verify RGBA values (all pixels should have A=255)
    for (png_image.pixels) |pixel| {
        const alpha = pixel >> 24;
        try std.testing.expectEqual(@as(u32, 0xFF), alpha);
    }
}

test "Phase 2 - end-to-end decodePNG test (RGB checkerboard)" {
    const allocator = std.testing.allocator;

    // Read PNG file (RGB format)
    const file_data = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "test-data/8x8_rgb_checkerboard_filter_none.png",
        allocator,
        .unlimited,
    );
    defer allocator.free(file_data);

    // Decode PNG
    var png_image = try lib.decodePNG(allocator, file_data);
    defer png_image.deinit(allocator);

    // Verify dimensions
    try std.testing.expectEqual(@as(u32, 8), png_image.width);
    try std.testing.expectEqual(@as(u32, 8), png_image.height);

    // Verify pixel count
    try std.testing.expectEqual(@as(usize, 64), png_image.pixels.len);

    // Verify RGBA values match checkerboard pattern
    const expected = try test_cases.generateRGBCheckerboardExpected(allocator, 8, 8);
    defer allocator.free(expected);

    for (0..64) |i| {
        try std.testing.expectEqual(expected[i], png_image.pixels[i]);
    }
}

test "Phase 2 - end-to-end decodePNG test (RGB gradient)" {
    const allocator = std.testing.allocator;

    // Read PNG file (RGB format)
    const file_data = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "test-data/16x16_rgb_gradient_filter_none.png",
        allocator,
        .unlimited,
    );
    defer allocator.free(file_data);

    // Decode PNG
    var png_image = try lib.decodePNG(allocator, file_data);
    defer png_image.deinit(allocator);

    // Verify dimensions
    try std.testing.expectEqual(@as(u32, 16), png_image.width);
    try std.testing.expectEqual(@as(u32, 16), png_image.height);

    // Verify pixel count
    try std.testing.expectEqual(@as(usize, 256), png_image.pixels.len);

    // Verify RGBA values match gradient pattern
    const expected = try test_cases.generateRGBGradientExpected(allocator, 16, 16);
    defer allocator.free(expected);

    for (0..256) |i| {
        try std.testing.expectEqual(expected[i], png_image.pixels[i]);
    }
}

test "Phase 3 - end-to-end decodePNG test (RGBA checkerboard)" {
    const allocator = std.testing.allocator;

    // Read PNG file (RGBA format)
    const file_data = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "test-data/8x8_rgba_checkerboard_filter_none.png",
        allocator,
        .unlimited,
    );
    defer allocator.free(file_data);

    // Decode PNG
    var png_image = try lib.decodePNG(allocator, file_data);
    defer png_image.deinit(allocator);

    // Verify dimensions
    try std.testing.expectEqual(@as(u32, 8), png_image.width);
    try std.testing.expectEqual(@as(u32, 8), png_image.height);

    // Verify pixel count
    try std.testing.expectEqual(@as(usize, 64), png_image.pixels.len);

    // Verify RGBA values match checkerboard pattern (with transparency)
    const expected = try test_cases.generateRGBACheckerboardExpected(allocator, 8, 8);
    defer allocator.free(expected);

    for (0..64) |i| {
        try std.testing.expectEqual(expected[i], png_image.pixels[i]);
    }
}

test "Phase 3 - end-to-end decodePNG test (RGBA gradient)" {
    const allocator = std.testing.allocator;

    // Read PNG file (RGBA format)
    const file_data = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "test-data/16x16_rgba_gradient_filter_none.png",
        allocator,
        .unlimited,
    );
    defer allocator.free(file_data);

    // Decode PNG
    var png_image = try lib.decodePNG(allocator, file_data);
    defer png_image.deinit(allocator);

    // Verify dimensions
    try std.testing.expectEqual(@as(u32, 16), png_image.width);
    try std.testing.expectEqual(@as(u32, 16), png_image.height);

    // Verify pixel count
    try std.testing.expectEqual(@as(usize, 256), png_image.pixels.len);

    // Verify RGBA values match gradient pattern (with varying alpha)
    const expected = try test_cases.generateRGBAGradientExpected(allocator, 16, 16);
    defer allocator.free(expected);

    for (0..256) |i| {
        try std.testing.expectEqual(expected[i], png_image.pixels[i]);
    }
}
