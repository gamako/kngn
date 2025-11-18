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
    // Calculate bytes_per_scanline safely (prevent u32 overflow)
    const bytes_per_scanline = std.math.mul(usize, @as(usize, width), @as(usize, bytes_per_pixel))
        catch return error.InvalidData;

    // Calculate total_bytes safely (prevent overflow)
    const total_bytes = std.math.mul(usize, bytes_per_scanline, @as(usize, height))
        catch return error.InvalidData;

    // Enforce reasonable size limit (e.g., 1GB)
    const max_size = 1024 * 1024 * 1024; // 1 GB
    if (total_bytes > max_size) {
        return error.InvalidData;
    }

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
                3 => try filterAverage(filt, output, x, output_pos, bytes_per_pixel, bytes_per_scanline),
                4 => try filterPaeth(filt, output, x, output_pos, bytes_per_pixel, bytes_per_scanline),
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

/// Filter Average: Recon(x) = Filt(x) + floor((Recon(x - bytes_per_pixel) + Recon(x - bytes_per_scanline)) / 2)
/// Add the average of the left and above values
fn filterAverage(
    filt: u8,
    output: []u8,
    x: usize,
    output_pos: usize,
    bytes_per_pixel: u32,
    bytes_per_scanline: usize,
) !u8 {
    const left: u8 = if (x >= bytes_per_pixel)
        output[output_pos - bytes_per_pixel]
    else
        0;

    const above: u8 = if (output_pos >= bytes_per_scanline)
        output[output_pos - bytes_per_scanline]
    else
        0;

    // Average: floor((left + above) / 2)
    const avg = @as(u16, left) +% @as(u16, above);
    const avg_floor: u8 = @truncate(avg >> 1); // divide by 2

    return @truncate(@as(u16, filt) +% avg_floor);
}

/// Paeth predictor function
/// Used by the Paeth filter
/// Based on PNG spec: p = a + b - c; pa = abs(p - a); pb = abs(p - b); pc = abs(p - c)
fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    const a_val: i32 = @as(i32, a);
    const b_val: i32 = @as(i32, b);
    const c_val: i32 = @as(i32, c);

    const p = a_val + b_val - c_val;

    // pa = abs(p - a)
    const p_minus_a = p - a_val;
    const pa = if (p_minus_a < 0) -p_minus_a else p_minus_a;

    // pb = abs(p - b)
    const p_minus_b = p - b_val;
    const pb = if (p_minus_b < 0) -p_minus_b else p_minus_b;

    // pc = abs(p - c)
    const p_minus_c = p - c_val;
    const pc = if (p_minus_c < 0) -p_minus_c else p_minus_c;

    return if (pa <= pb and pa <= pc)
        a
    else if (pb <= pc)
        b
    else
        c;
}

/// Filter Paeth: Recon(x) = Filt(x) + PaethPredictor(Recon(x - bytes_per_pixel), Recon(x - bytes_per_scanline), Recon(x - bytes_per_scanline - bytes_per_pixel))
/// Add the Paeth predicted value
fn filterPaeth(
    filt: u8,
    output: []u8,
    x: usize,
    output_pos: usize,
    bytes_per_pixel: u32,
    bytes_per_scanline: usize,
) !u8 {
    const left: u8 = if (x >= bytes_per_pixel)
        output[output_pos - bytes_per_pixel]
    else
        0;

    const above: u8 = if (output_pos >= bytes_per_scanline)
        output[output_pos - bytes_per_scanline]
    else
        0;

    const upper_left: u8 = if (output_pos >= bytes_per_scanline and x >= bytes_per_pixel)
        output[output_pos - bytes_per_scanline - bytes_per_pixel]
    else
        0;

    const pred = paethPredictor(left, above, upper_left);

    return @truncate(@as(u16, filt) +% pred);
}
