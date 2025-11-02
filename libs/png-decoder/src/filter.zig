// PNG Filter Removal Module
// Implements PNG filterning algorithms (RFC 2083)
// Each scanline is prefixed with a filter type (0-4)
// This module removes the filter to restore original pixel data

const std = @import("std");

/// Apply PNG filters to remove filtering from scanlines
///
/// PNG stores each scanline with a filter byte at the start:
/// [FilterType (1 byte)] [FilteredPixelData (width bytes)]
///
/// This function removes the filter based on FilterType and restores the original pixel data.
///
/// Args:
///   allocator: Memory allocator
///   decompressed: Decompressed IDAT data (includes filter bytes)
///   width: Image width in pixels
///   height: Image height in pixels
///   bytes_per_pixel: 1 for grayscale, 3 for RGB, 4 for RGBA
///
/// Returns:
///   Filtered pixel data (newly allocated, caller must free)
pub fn applyFilters(
    allocator: std.mem.Allocator,
    decompressed: []const u8,
    width: u32,
    height: u32,
    bytes_per_pixel: u32,
) ![]u8 {
    const bytes_per_scanline = width * bytes_per_pixel;
    const total_bytes = width * height * bytes_per_pixel;

    // Allocate output buffer
    const output = try allocator.alloc(u8, total_bytes);
    errdefer allocator.free(output);

    var input_pos: usize = 0;
    var output_pos: usize = 0;

    for (0..height) |_| {
        // Read filter type for this scanline
        if (input_pos >= decompressed.len) {
            return error.InvalidData;
        }
        const filter_type = decompressed[input_pos];
        input_pos += 1;

        // Get the current scanline (for filters that reference previous scanline)
        const current_scanline_start = output_pos;

        // Process each byte in this scanline based on filter type
        for (0..bytes_per_scanline) |x| {
            if (input_pos >= decompressed.len) {
                return error.InvalidData;
            }

            const filt = decompressed[input_pos];
            input_pos += 1;

            const recon = switch (filter_type) {
                0 => try filterNone(filt),
                1 => try filterSub(filt, output, x, bytes_per_pixel, current_scanline_start),
                2 => try filterUp(filt, output, x, output_pos, bytes_per_scanline),
                else => return error.UnsupportedFilterType,
            };

            output[output_pos] = recon;
            output_pos += 1;
        }
    }

    return output;
}

/// Filter None: Recon(x) = Filt(x)
/// No filtering, just copy the data
fn filterNone(filt: u8) !u8 {
    return filt;
}

/// Filter Sub: Recon(x) = Filt(x) + Recon(x - bytes_per_pixel)
/// Add the value to the left (if it exists)
fn filterSub(
    filt: u8,
    output: []u8,
    x: usize,
    bytes_per_pixel: u32,
    scanline_start: usize,
) !u8 {
    const left: u8 = if (x >= bytes_per_pixel)
        output[scanline_start + x - bytes_per_pixel]
    else
        0;

    return @truncate(@as(u16, filt) +% left);
}

/// Filter Up: Recon(x) = Filt(x) + Recon(x - bytes_per_scanline)
/// Add the value above (if it exists)
fn filterUp(
    filt: u8,
    output: []u8,
    x: usize,
    output_pos: usize,
    bytes_per_scanline: usize,
) !u8 {
    _ = x; // x is already accounted for in output_pos

    const above: u8 = if (output_pos >= bytes_per_scanline)
        output[output_pos - bytes_per_scanline]
    else
        0;

    return @truncate(@as(u16, filt) +% above);
}
