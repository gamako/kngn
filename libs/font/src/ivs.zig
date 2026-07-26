// Shared ItemVariationStore implementation (HVAR / CFF2 VariationStore).
//
// Hot-path note: region scalar / itemDelta run **only on metrics-cache miss, raster miss, or axis change**.
// Never on the per-frame path.

const std = @import("std");
const Reader = @import("byte_reader.zig").Reader;
const var_common = @import("var_common.zig");
const gvar_mod = @import("gvar.zig");

const MAX_AXES = var_common.MAX_AXES;
const f2dot14ToF32 = var_common.f2dot14ToF32;

pub const Error = error{ InvalidFont, Unsupported, OutOfMemory };

/// Validate IVS header (format / region list / item variation data offsets).
pub fn validateIvs(table: []const u8, ivs_off: usize, axis_count: u16) Error!void {
    const r = Reader{ .data = table };
    try r.require(ivs_off, 8);
    const format = try r.u16At(ivs_off);
    if (format != 1) return error.InvalidFont;
    const region_list_off = try r.u32At(ivs_off + 2);
    const region_abs = std.math.add(usize, ivs_off, region_list_off) catch return error.InvalidFont;
    try r.require(region_abs, 4);
    const ac = try r.u16At(region_abs);
    if (ac != axis_count) return error.InvalidFont;
    const region_count = try r.u16At(region_abs + 2);
    if (region_count & 0x8000 != 0) return error.InvalidFont;
    const region_bytes = std.math.mul(usize, @as(usize, region_count), @as(usize, ac) * 6) catch return error.InvalidFont;
    try r.require(region_abs + 4, region_bytes);

    const ivd_count = try r.u16At(ivs_off + 6);
    const offsets_off = ivs_off + 8;
    const offsets_bytes = std.math.mul(usize, @as(usize, ivd_count), 4) catch return error.InvalidFont;
    try r.require(offsets_off, offsets_bytes);
}

/// Read axisCount from the IVS region list (for CFF2 checks independent of fvar).
pub fn axisCountFromIvs(table: []const u8, ivs_off: usize) Error!u16 {
    const r = Reader{ .data = table };
    try r.require(ivs_off, 8);
    if (try r.u16At(ivs_off) != 1) return error.InvalidFont;
    const region_list_off = try r.u32At(ivs_off + 2);
    const region_abs = std.math.add(usize, ivs_off, region_list_off) catch return error.InvalidFont;
    try r.require(region_abs, 4);
    return try r.u16At(region_abs);
}

/// Write scalars at the current norm for each region of ItemVariationData[outer] into out.
/// Return value = region count (k). out must be at least regionIndexCount long.
pub fn regionScalarsForIvd(
    table: []const u8,
    ivs_off: usize,
    outer: u16,
    norm: []const f32,
    axis_count: u16,
    out: []f32,
) Error!u16 {
    const r = Reader{ .data = table };
    const ivd_count = try r.u16At(ivs_off + 6);
    if (outer >= ivd_count) return error.InvalidFont;
    const ivd_rel = try r.u32At(ivs_off + 8 + @as(usize, outer) * 4);
    if (ivd_rel == 0) return error.InvalidFont;
    const ivd_abs = std.math.add(usize, ivs_off, ivd_rel) catch return error.InvalidFont;
    try r.require(ivd_abs, 6);
    const region_index_count = try r.u16At(ivd_abs + 4);
    if (out.len < region_index_count) return error.InvalidFont;

    const region_indexes_off = ivd_abs + 6;
    try r.require(region_indexes_off, @as(usize, region_index_count) * 2);

    const region_list_rel = try r.u32At(ivs_off + 2);
    const region_list_abs = std.math.add(usize, ivs_off, region_list_rel) catch return error.InvalidFont;
    const region_count = try r.u16At(region_list_abs + 2);
    const ac: usize = axis_count;

    // Pad norm to axis_count (missing axes are 0)
    var norm_buf: [MAX_AXES]f32 = .{0} ** MAX_AXES;
    if (ac > MAX_AXES) return error.Unsupported;
    const ncopy = @min(norm.len, ac);
    if (ncopy > 0) @memcpy(norm_buf[0..ncopy], norm[0..ncopy]);

    var col: usize = 0;
    while (col < region_index_count) : (col += 1) {
        const region_idx = try r.u16At(region_indexes_off + col * 2);
        if (region_idx >= region_count) return error.InvalidFont;
        const region_off = region_list_abs + 4 + @as(usize, region_idx) * ac * 6;
        var peak_buf: [MAX_AXES]f32 = undefined;
        var start_buf: [MAX_AXES]f32 = undefined;
        var end_buf: [MAX_AXES]f32 = undefined;
        var ai: usize = 0;
        while (ai < ac) : (ai += 1) {
            const base = region_off + ai * 6;
            start_buf[ai] = f2dot14ToF32(try r.i16At(base));
            peak_buf[ai] = f2dot14ToF32(try r.i16At(base + 2));
            end_buf[ai] = f2dot14ToF32(try r.i16At(base + 4));
        }
        out[col] = gvar_mod.tupleScalar(norm_buf[0..ac], peak_buf[0..ac], true, start_buf[0..ac], end_buf[0..ac]);
    }
    return region_index_count;
}

/// Evaluate the outer/inner delta sum from ItemVariationStore.
pub fn itemDelta(
    table: []const u8,
    ivs_off: usize,
    outer: u16,
    inner: u16,
    norm: []const f32,
    axis_count: u16,
) Error!f32 {
    const r = Reader{ .data = table };
    const ivd_count = try r.u16At(ivs_off + 6);
    if (outer >= ivd_count) return error.InvalidFont;
    const ivd_rel = try r.u32At(ivs_off + 8 + @as(usize, outer) * 4);
    if (ivd_rel == 0) return 0;
    const ivd_abs = std.math.add(usize, ivs_off, ivd_rel) catch return error.InvalidFont;

    try r.require(ivd_abs, 6);
    const item_count = try r.u16At(ivd_abs);
    const word_delta_count_raw = try r.u16At(ivd_abs + 2);
    const long_words = word_delta_count_raw & 0x8000 != 0;
    const word_delta_count: usize = word_delta_count_raw & 0x7FFF;
    const region_index_count = try r.u16At(ivd_abs + 4);
    if (word_delta_count > region_index_count) return error.InvalidFont;
    if (inner >= item_count) return error.InvalidFont;

    const region_indexes_off = ivd_abs + 6;
    try r.require(region_indexes_off, @as(usize, region_index_count) * 2);

    const region_list_rel = try r.u32At(ivs_off + 2);
    const region_list_abs = std.math.add(usize, ivs_off, region_list_rel) catch return error.InvalidFont;
    const region_count = try r.u16At(region_list_abs + 2);
    const ac: usize = axis_count;

    var norm_buf: [MAX_AXES]f32 = .{0} ** MAX_AXES;
    if (ac > MAX_AXES) return error.Unsupported;
    const ncopy = @min(norm.len, ac);
    if (ncopy > 0) @memcpy(norm_buf[0..ncopy], norm[0..ncopy]);

    const short_count = region_index_count - word_delta_count;
    const row_bytes: usize = if (long_words)
        word_delta_count * 4 + short_count * 2
    else
        word_delta_count * 2 + short_count * 1;

    const delta_sets_off = region_indexes_off + @as(usize, region_index_count) * 2;
    const row_off = delta_sets_off + @as(usize, inner) * row_bytes;
    try r.require(row_off, row_bytes);

    var total: f32 = 0;
    var col: usize = 0;
    var byte_pos = row_off;
    while (col < region_index_count) : (col += 1) {
        const region_idx = try r.u16At(region_indexes_off + col * 2);
        if (region_idx >= region_count) return error.InvalidFont;

        const delta: f32 = if (col < word_delta_count) blk: {
            if (long_words) {
                const v = try r.i32At(byte_pos);
                byte_pos += 4;
                break :blk @floatFromInt(v);
            } else {
                const v = try r.i16At(byte_pos);
                byte_pos += 2;
                break :blk @floatFromInt(v);
            }
        } else blk: {
            if (long_words) {
                const v = try r.i16At(byte_pos);
                byte_pos += 2;
                break :blk @floatFromInt(v);
            } else {
                const b = try r.u8At(byte_pos);
                byte_pos += 1;
                break :blk @floatFromInt(@as(i8, @bitCast(b)));
            }
        };

        const region_off = region_list_abs + 4 + @as(usize, region_idx) * ac * 6;
        var peak_buf: [MAX_AXES]f32 = undefined;
        var start_buf: [MAX_AXES]f32 = undefined;
        var end_buf: [MAX_AXES]f32 = undefined;
        var ai: usize = 0;
        while (ai < ac) : (ai += 1) {
            const base = region_off + ai * 6;
            start_buf[ai] = f2dot14ToF32(try r.i16At(base));
            peak_buf[ai] = f2dot14ToF32(try r.i16At(base + 2));
            end_buf[ai] = f2dot14ToF32(try r.i16At(base + 4));
        }
        const scalar = gvar_mod.tupleScalar(norm_buf[0..ac], peak_buf[0..ac], true, start_buf[0..ac], end_buf[0..ac]);
        total += delta * scalar;
    }
    return total;
}
