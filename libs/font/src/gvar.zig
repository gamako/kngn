// gvar テーブル: glyph variation store + tuple scalar + packed points/deltas + per-tuple IUP。
//
// ホットパス宣言: gvar.apply / outlineVaried は **ラスタキャッシュミス時のみ**。
// getCached ヒット時は変分計算ゼロ。全画素ループ非該当 → SIMD 対象外。
// 一時バッファ（deltas/has_delta/packed 展開）は per-call alloc + defer free。
//
// ヘッダ（OpenType gvar）: major@0 / minor@2 / axisCount@4 / sharedTupleCount@6 /
// sharedTuplesOffset@8 (Offset32) / glyphCount@12 / flags@14 / glyphVariationDataArrayOffset@16 (Offset32) /
// glyphVariationDataOffsets[glyphCount+1]@20。

const std = @import("std");
const Reader = @import("byte_reader.zig").Reader;
const var_common = @import("var_common.zig");
const outline = @import("outline.zig");

const Vec2f = outline.Vec2f;
const MAX_AXES = var_common.MAX_AXES;
const f2dot14ToF32 = var_common.f2dot14ToF32;

pub const Error = error{ InvalidFont, Unsupported, OutOfMemory };

/// Tuple scalar 計算（OpenType Font Variations Overview）。
/// peak のみ（非 intermediate）または start/peak/end テント。
/// 軸ごとのスカラー積。いずれかが 0 なら 0。
pub fn tupleScalar(
    norm: []const f32,
    peak: []const f32,
    intermediate: bool,
    start: []const f32,
    end: []const f32,
) f32 {
    const n = peak.len;
    if (norm.len < n) return 0;
    var scalar: f32 = 1.0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const pe = peak[i];
        const nv = norm[i];
        var axis_s: f32 = undefined;
        if (intermediate) {
            // peak==0 の軸は IVS/gvar ともスカラー計算に含めない（常に 1）。
            if (pe == 0) {
                axis_s = 1;
            } else {
                const st = start[i];
                const en = end[i];
                if (st > pe or pe > en) {
                    // 無効 region（start>peak / peak>end）は中立 1（OpenType IVS 仕様の必須分岐）
                    axis_s = 1;
                } else if (st < 0 and en > 0) {
                    // ゼロを跨ぐ region（peak≠0）も中立 1（同仕様）
                    axis_s = 1;
                } else if (nv < st or nv > en) {
                    axis_s = 0;
                } else if (nv == pe) {
                    axis_s = 1;
                } else if (nv < pe) {
                    const denom = pe - st;
                    axis_s = if (denom == 0) 1 else (nv - st) / denom;
                } else {
                    const denom = en - pe;
                    axis_s = if (denom == 0) 1 else (en - nv) / denom;
                }
            }
        } else {
            // 非 intermediate: region は 0..peak（peak 側）。peak==0 の軸は無視（scalar=1）。
            if (pe == 0) {
                axis_s = 1;
            } else if (nv < @min(@as(f32, 0), pe) or nv > @max(@as(f32, 0), pe)) {
                axis_s = 0;
            } else if (nv == pe) {
                axis_s = 1;
            } else {
                axis_s = nv / pe;
            }
        }
        if (axis_s == 0) return 0;
        scalar *= axis_s;
    }
    return scalar;
}

pub const Gvar = struct {
    data: []const u8,
    axis_count: u16,
    glyph_count: u16,
    shared_tuple_count: u16,
    shared_tuples_off: usize,
    offset_is_long: bool,
    /// glyphVariationDataOffsets 配列先頭（table 内）。
    offsets_off: usize,
    /// GlyphVariationData 配列のベース（table 内）。
    gvd_array_off: usize,

    pub fn parse(table: []const u8, num_glyphs: u16, axis_count: u16) Error!Gvar {
        const r = Reader{ .data = table };
        try r.require(0, 20);
        const major = try r.u16At(0);
        const minor = try r.u16At(2);
        if (major != 1 or minor != 0) return error.InvalidFont;
        const ac = try r.u16At(4);
        if (ac != axis_count) return error.InvalidFont;
        if (ac > MAX_AXES) return error.Unsupported;
        const shared_tuple_count = try r.u16At(6);
        const shared_tuples_offset = try r.u32At(8);
        const glyph_count = try r.u16At(12);
        if (glyph_count != num_glyphs) return error.InvalidFont;
        const flags = try r.u16At(14);
        const offset_is_long = flags & 1 != 0;
        const gvd_array_offset = try r.u32At(16);

        const offsets_off: usize = 20;
        const entry_size: usize = if (offset_is_long) 4 else 2;
        const n_off = @as(usize, glyph_count) + 1;
        const offsets_bytes = std.math.mul(usize, n_off, entry_size) catch return error.InvalidFont;
        try r.require(offsets_off, offsets_bytes);

        // shared tuples 範囲検証
        if (shared_tuple_count > 0) {
            const st_bytes = std.math.mul(usize, @as(usize, shared_tuple_count), @as(usize, ac) * 2) catch return error.InvalidFont;
            try r.require(shared_tuples_offset, st_bytes);
        }
        try r.require(gvd_array_offset, 0);

        // offset 配列: 単調非減・最終 offset が table 内に収まること
        var i: usize = 0;
        var prev: usize = 0;
        while (i < n_off) : (i += 1) {
            const raw: usize = if (offset_is_long)
                try r.u32At(offsets_off + i * 4)
            else
                @as(usize, try r.u16At(offsets_off + i * 2)) * 2;
            if (i > 0 and raw < prev) return error.InvalidFont;
            const abs = std.math.add(usize, gvd_array_offset, raw) catch return error.InvalidFont;
            if (abs > table.len) return error.InvalidFont;
            prev = raw;
        }

        return .{
            .data = table,
            .axis_count = ac,
            .glyph_count = glyph_count,
            .shared_tuple_count = shared_tuple_count,
            .shared_tuples_off = shared_tuples_offset,
            .offset_is_long = offset_is_long,
            .offsets_off = offsets_off,
            .gvd_array_off = gvd_array_offset,
        };
    }

    /// gid の GlyphVariationData slice。空（デルタ無し）なら null。
    pub fn glyphData(self: *const Gvar, gid: u16) Error!?[]const u8 {
        if (gid >= self.glyph_count) return error.InvalidFont;
        const r = Reader{ .data = self.data };
        const off0_raw: usize = if (self.offset_is_long)
            try r.u32At(self.offsets_off + @as(usize, gid) * 4)
        else
            @as(usize, try r.u16At(self.offsets_off + @as(usize, gid) * 2)) * 2;
        const off1_raw: usize = if (self.offset_is_long)
            try r.u32At(self.offsets_off + (@as(usize, gid) + 1) * 4)
        else
            @as(usize, try r.u16At(self.offsets_off + (@as(usize, gid) + 1) * 2)) * 2;
        if (off1_raw < off0_raw) return error.InvalidFont;
        if (off0_raw == off1_raw) return null;
        const start = std.math.add(usize, self.gvd_array_off, off0_raw) catch return error.InvalidFont;
        const end = std.math.add(usize, self.gvd_array_off, off1_raw) catch return error.InvalidFont;
        if (end > self.data.len or start > end) return error.InvalidFont;
        return self.data[start..end];
    }

    fn readSharedTuple(self: *const Gvar, index: u16, out: []f32) Error!void {
        if (index >= self.shared_tuple_count) return error.InvalidFont;
        if (out.len < self.axis_count) return error.InvalidFont;
        const r = Reader{ .data = self.data };
        const base = self.shared_tuples_off + @as(usize, index) * @as(usize, self.axis_count) * 2;
        var i: u16 = 0;
        while (i < self.axis_count) : (i += 1) {
            out[i] = f2dot14ToF32(try r.i16At(base + @as(usize, i) * 2));
        }
    }

    /// simple glyph の点列に gvar を適用し net deltas を返す。
    /// points は元座標（font units）。長さ = n_outline（phantom 無し）。
    /// end_pts: 各 contour の最終点 index（昇順）。
    /// out_deltas: 長さ n_outline + 4（phantom 含む）。呼び出し側確保。
    /// phantom の X デルタから advance 変分も得られる。
    ///
    /// 戻り: OutOfMemory / InvalidFont。
    pub fn applySimple(
        self: *const Gvar,
        alloc: std.mem.Allocator,
        gid: u16,
        points: []const Vec2f,
        end_pts: []const u16,
        norm: []const f32,
        out_deltas: []Vec2f,
    ) Error!void {
        const n_outline = points.len;
        const n_total = n_outline + 4;
        if (out_deltas.len < n_total) return error.InvalidFont;
        if (norm.len < self.axis_count) return error.InvalidFont;
        @memset(out_deltas[0..n_total], .{ .x = 0, .y = 0 });

        const gvd = (try self.glyphData(gid)) orelse return;
        try applyGlyphVariationData(self, alloc, gvd, points, end_pts, n_outline, norm, out_deltas);
    }

    /// phantom 4 点の X デルタのみ復元（full outline 不要の metrics 経路）。
    /// advance_delta = phantom[1].x - phantom[0].x。
    pub fn phantomAdvanceDelta(
        self: *const Gvar,
        alloc: std.mem.Allocator,
        gid: u16,
        /// outline 点数（phantom の論理 index 基準）。空グリフは 0。
        n_outline: usize,
        /// outline 点座標（IUP に必要。n_outline==0 なら空で可）。
        points: []const Vec2f,
        end_pts: []const u16,
        norm: []const f32,
    ) Error!f32 {
        if (points.len != n_outline) return error.InvalidFont;
        const n_total = n_outline + 4;
        const deltas = try alloc.alloc(Vec2f, n_total);
        defer alloc.free(deltas);
        try self.applySimple(alloc, gid, points, end_pts, norm, deltas);
        // phantom index: n, n+1 = LSB / advance
        return deltas[n_outline + 1].x - deltas[n_outline].x;
    }
};

/// GlyphVariationData 1 個分を decode して net deltas に累積。
fn applyGlyphVariationData(
    gvar: *const Gvar,
    alloc: std.mem.Allocator,
    gvd: []const u8,
    points: []const Vec2f,
    end_pts: []const u16,
    n_outline: usize,
    norm: []const f32,
    out_deltas: []Vec2f,
) Error!void {
    const r = Reader{ .data = gvd };
    try r.require(0, 4);
    const tvc = try r.u16At(0);
    const shared_points = tvc & 0x8000 != 0;
    const tuple_count: usize = tvc & 0x0FFF;
    const data_offset = try r.u16At(2);
    if (data_offset > gvd.len) return error.InvalidFont;

    const ac: usize = gvar.axis_count;
    var header_pos: usize = 4;

    // shared point numbers（serialized data 先頭）
    var shared_point_indices: []u16 = &.{};
    defer if (shared_point_indices.len > 0) alloc.free(shared_point_indices);
    var shared_all_points = false;
    var shared_points_end: usize = data_offset;

    if (shared_points) {
        const sp = try decodePackedPointNumbers(alloc, gvd, data_offset, n_outline + 4);
        shared_point_indices = sp.indices;
        shared_all_points = sp.all_points;
        shared_points_end = sp.end_pos;
    }

    var peak_buf: [MAX_AXES]f32 = undefined;
    var start_buf: [MAX_AXES]f32 = undefined;
    var end_buf: [MAX_AXES]f32 = undefined;

    const n_total = n_outline + 4;
    const tuple_dx = try alloc.alloc(f32, n_total);
    defer alloc.free(tuple_dx);
    const tuple_dy = try alloc.alloc(f32, n_total);
    defer alloc.free(tuple_dy);
    const has_delta = try alloc.alloc(bool, n_total);
    defer alloc.free(has_delta);

    var ti: usize = 0;
    var serialized_pos = shared_points_end;
    while (ti < tuple_count) : (ti += 1) {
        try r.require(header_pos, 4);
        const var_data_size = try r.u16At(header_pos);
        const tuple_index = try r.u16At(header_pos + 2);
        header_pos += 4;

        const embedded_peak = tuple_index & 0x8000 != 0;
        const intermediate = tuple_index & 0x4000 != 0;
        const private_points = tuple_index & 0x2000 != 0;
        const shared_idx: u16 = @truncate(tuple_index & 0x0FFF);

        if (embedded_peak) {
            try r.require(header_pos, ac * 2);
            var ai: usize = 0;
            while (ai < ac) : (ai += 1) {
                peak_buf[ai] = f2dot14ToF32(try r.i16At(header_pos + ai * 2));
            }
            header_pos += ac * 2;
        } else {
            try gvar.readSharedTuple(shared_idx, peak_buf[0..ac]);
        }

        if (intermediate) {
            try r.require(header_pos, ac * 4);
            var ai: usize = 0;
            while (ai < ac) : (ai += 1) {
                start_buf[ai] = f2dot14ToF32(try r.i16At(header_pos + ai * 2));
            }
            header_pos += ac * 2;
            ai = 0;
            while (ai < ac) : (ai += 1) {
                end_buf[ai] = f2dot14ToF32(try r.i16At(header_pos + ai * 2));
            }
            header_pos += ac * 2;
        }

        const scalar = tupleScalar(
            norm[0..ac],
            peak_buf[0..ac],
            intermediate,
            start_buf[0..ac],
            end_buf[0..ac],
        );

        // variation data size 分を読む（scalar=0 でも位置を進める）
        const run_start = serialized_pos;
        const run_end = std.math.add(usize, serialized_pos, var_data_size) catch return error.InvalidFont;
        if (run_end > gvd.len) return error.InvalidFont;
        serialized_pos = run_end;

        if (scalar == 0) continue;

        // private or shared points
        var point_indices: []const u16 = undefined;
        var all_points = false;
        var deltas_pos: usize = run_start;
        var owned_points: ?[]u16 = null;
        defer if (owned_points) |op| alloc.free(op);

        if (private_points) {
            const pp = try decodePackedPointNumbers(alloc, gvd, run_start, n_total);
            owned_points = pp.indices;
            point_indices = pp.indices;
            all_points = pp.all_points;
            deltas_pos = pp.end_pos;
        } else if (shared_points) {
            point_indices = shared_point_indices;
            all_points = shared_all_points;
            deltas_pos = run_start;
        } else {
            // shared point numbers 無し・private も無し → 全点（仕様: count=0 と同義扱い）
            all_points = true;
            point_indices = &.{};
            deltas_pos = run_start;
        }

        // 論理点数
        const n_points_logical: usize = if (all_points) n_total else point_indices.len;
        // X deltas + Y deltas
        const n_deltas_logical = n_points_logical * 2;
        const packed_deltas = try decodePackedDeltas(alloc, gvd, deltas_pos, n_deltas_logical);
        defer alloc.free(packed_deltas);

        // tuple_delta 構築
        @memset(tuple_dx, 0);
        @memset(tuple_dy, 0);
        @memset(has_delta, false);

        if (all_points) {
            var pi: usize = 0;
            while (pi < n_total) : (pi += 1) {
                tuple_dx[pi] = packed_deltas[pi];
                tuple_dy[pi] = packed_deltas[n_points_logical + pi];
                has_delta[pi] = true;
            }
        } else {
            var pi: usize = 0;
            while (pi < point_indices.len) : (pi += 1) {
                const pidx = point_indices[pi];
                if (pidx >= n_total) return error.InvalidFont;
                // 同一点番号の累積（仕様）
                tuple_dx[pidx] += packed_deltas[pi];
                tuple_dy[pidx] += packed_deltas[n_points_logical + pi];
                has_delta[pidx] = true;
            }
        }

        // per-tuple IUP（outline 点のみ。phantom は対象外）
        if (n_outline > 0 and !all_points) {
            try iupInfer(points, end_pts, n_outline, has_delta, tuple_dx, tuple_dy);
        }

        // scalar 乗算して累積
        var pi: usize = 0;
        while (pi < n_total) : (pi += 1) {
            out_deltas[pi].x += tuple_dx[pi] * scalar;
            out_deltas[pi].y += tuple_dy[pi] * scalar;
        }
    }
}

const PackedPoints = struct {
    indices: []u16,
    all_points: bool,
    end_pos: usize,
};

/// packed point numbers を decode。all_points なら indices は空で all_points=true。
fn decodePackedPointNumbers(alloc: std.mem.Allocator, data: []const u8, pos: usize, max_point: usize) Error!PackedPoints {
    const r = Reader{ .data = data };
    try r.require(pos, 1);
    const first = try r.u8At(pos);
    var p = pos + 1;
    var count: usize = undefined;
    if (first == 0) {
        return .{ .indices = &.{}, .all_points = true, .end_pos = p };
    } else if (first & 0x80 == 0) {
        count = first;
    } else {
        try r.require(p, 1);
        const second = try r.u8At(p);
        p += 1;
        count = (@as(usize, first & 0x7F) << 8) | second;
    }
    if (count == 0) return error.InvalidFont; // 0 は all-points 専用（first==0 で処理済み）
    if (count > max_point + 16) return error.InvalidFont; // 異常に大きい

    const indices = try alloc.alloc(u16, count);
    errdefer alloc.free(indices);

    var filled: usize = 0;
    var last: u16 = 0;
    while (filled < count) {
        try r.require(p, 1);
        const control = try r.u8At(p);
        p += 1;
        const words = control & 0x80 != 0;
        const run_count = @as(usize, control & 0x7F) + 1;
        if (filled + run_count > count) return error.InvalidFont;
        var k: usize = 0;
        while (k < run_count) : (k += 1) {
            const delta: u16 = if (words) blk: {
                try r.require(p, 2);
                const v = try r.u16At(p);
                p += 2;
                break :blk v;
            } else blk: {
                try r.require(p, 1);
                const v = try r.u8At(p);
                p += 1;
                break :blk v;
            };
            // 累積（overflow は InvalidFont）
            const next = @as(u32, last) + delta;
            if (next > std.math.maxInt(u16)) return error.InvalidFont;
            last = @intCast(next);
            indices[filled] = last;
            filled += 1;
        }
    }
    return .{ .indices = indices, .all_points = false, .end_pos = p };
}

/// packed deltas を論理 count 個 decode。
fn decodePackedDeltas(alloc: std.mem.Allocator, data: []const u8, pos: usize, count: usize) Error![]f32 {
    const r = Reader{ .data = data };
    const out = try alloc.alloc(f32, count);
    errdefer alloc.free(out);
    var filled: usize = 0;
    var p = pos;
    while (filled < count) {
        try r.require(p, 1);
        const control = try r.u8At(p);
        p += 1;
        const zeros = control & 0x80 != 0;
        const words = control & 0x40 != 0;
        const run_count = @as(usize, control & 0x3F) + 1;
        if (filled + run_count > count) return error.InvalidFont;
        if (zeros) {
            var k: usize = 0;
            while (k < run_count) : (k += 1) {
                out[filled] = 0;
                filled += 1;
            }
        } else if (words) {
            var k: usize = 0;
            while (k < run_count) : (k += 1) {
                try r.require(p, 2);
                out[filled] = @floatFromInt(try r.i16At(p));
                p += 2;
                filled += 1;
            }
        } else {
            var k: usize = 0;
            while (k < run_count) : (k += 1) {
                try r.require(p, 1);
                const b = try r.u8At(p);
                p += 1;
                out[filled] = @floatFromInt(@as(i8, @bitCast(b)));
                filled += 1;
            }
        }
    }
    return out;
}

/// per-tuple IUP: 未指定 outline 点の delta を推論（phantom は触らない）。
/// has_delta / tuple_dx / tuple_dy は n_total 長だが IUP は [0, n_outline) のみ。
fn iupInfer(
    points: []const Vec2f,
    end_pts: []const u16,
    n_outline: usize,
    has_delta: []bool,
    tuple_dx: []f32,
    tuple_dy: []f32,
) Error!void {
    _ = n_outline;
    var start: usize = 0;
    for (end_pts) |ep| {
        const end: usize = @as(usize, ep) + 1;
        if (end <= start or end > points.len) return error.InvalidFont;
        const cont_len = end - start;
        if (cont_len == 0) {
            start = end;
            continue;
        }
        // この contour 内の参照点数
        var ref_count: usize = 0;
        var first_ref: ?usize = null;
        var i: usize = start;
        while (i < end) : (i += 1) {
            if (has_delta[i]) {
                ref_count += 1;
                if (first_ref == null) first_ref = i;
            }
        }
        if (ref_count == 0) {
            // no-op
        } else if (ref_count == 1) {
            // 全点に同じ delta
            const ri = first_ref.?;
            const dx = tuple_dx[ri];
            const dy = tuple_dy[ri];
            i = start;
            while (i < end) : (i += 1) {
                if (!has_delta[i]) {
                    tuple_dx[i] = dx;
                    tuple_dy[i] = dy;
                    // has_delta は明示点のみのまま（IUP 結果を別 tuple の参照に使わない）
                }
            }
        } else {
            // 各未参照点について前後参照点で補間
            i = start;
            while (i < end) : (i += 1) {
                if (has_delta[i]) continue;
                const prev = findPrevRef(has_delta, start, end, i);
                const next = findNextRef(has_delta, start, end, i);
                tuple_dx[i] = iupComponent(points[prev].x, points[next].x, points[i].x, tuple_dx[prev], tuple_dx[next]);
                tuple_dy[i] = iupComponent(points[prev].y, points[next].y, points[i].y, tuple_dy[prev], tuple_dy[next]);
            }
        }
        start = end;
    }
}

fn findPrevRef(has_delta: []const bool, start: usize, end: usize, target: usize) usize {
    // target より前で最大の参照点。無ければ contour 内最高の参照点。
    var i: isize = @intCast(target);
    i -= 1;
    while (i >= @as(isize, @intCast(start))) : (i -= 1) {
        if (has_delta[@intCast(i)]) return @intCast(i);
    }
    // wrap: end-1 から
    i = @intCast(end - 1);
    while (i > @as(isize, @intCast(target))) : (i -= 1) {
        if (has_delta[@intCast(i)]) return @intCast(i);
    }
    return target; // 到達しないはず
}

fn findNextRef(has_delta: []const bool, start: usize, end: usize, target: usize) usize {
    var i = target + 1;
    while (i < end) : (i += 1) {
        if (has_delta[i]) return i;
    }
    i = start;
    while (i < target) : (i += 1) {
        if (has_delta[i]) return i;
    }
    return target;
}

/// IUP 1 成分: 仕様分岐（同座標同delta / 同座標異delta→0 / 範囲外→近接 / 範囲内線形）。
pub fn iupComponent(coord_prev: f32, coord_next: f32, coord_target: f32, delta_prev: f32, delta_next: f32) f32 {
    if (coord_prev == coord_next) {
        if (delta_prev == delta_next) return delta_prev;
        return 0;
    }
    const cmin = @min(coord_prev, coord_next);
    const cmax = @max(coord_prev, coord_next);
    if (coord_target <= cmin) {
        // 近い側 = 座標が小さい側
        return if (coord_prev < coord_next) delta_prev else delta_next;
    }
    if (coord_target >= cmax) {
        return if (coord_prev > coord_next) delta_prev else delta_next;
    }
    // 範囲内線形
    const proportion = (coord_target - coord_prev) / (coord_next - coord_prev);
    return (1.0 - proportion) * delta_prev + proportion * delta_next;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn putU16(buf: []u8, off: usize, v: u16) void {
    buf[off] = @intCast(v >> 8);
    buf[off + 1] = @truncate(v);
}
fn putU32(buf: []u8, off: usize, v: u32) void {
    buf[off] = @truncate(v >> 24);
    buf[off + 1] = @truncate(v >> 16);
    buf[off + 2] = @truncate(v >> 8);
    buf[off + 3] = @truncate(v);
}
fn putI16(buf: []u8, off: usize, v: i16) void {
    putU16(buf, off, @bitCast(v));
}
fn f2d(v: f32) i16 {
    return var_common.f32ToF2dot14(v);
}

test "gvar: tupleScalar non-intermediate peak=1 → norm 比例" {
    const peak = [_]f32{1.0};
    try testing.expectApproxEqAbs(@as(f32, 1.0), tupleScalar(&.{1.0}, &peak, false, &.{}, &.{}), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), tupleScalar(&.{0.5}, &peak, false, &.{}, &.{}), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), tupleScalar(&.{0.0}, &peak, false, &.{}, &.{}), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), tupleScalar(&.{-0.5}, &peak, false, &.{}, &.{}), 0.001);
}

test "gvar: tupleScalar peak=0 軸は無視（積に 1）" {
    const peak = [_]f32{ 1.0, 0.0 };
    try testing.expectApproxEqAbs(@as(f32, 0.5), tupleScalar(&.{ 0.5, 0.9 }, &peak, false, &.{}, &.{}), 0.001);
}

test "gvar: tupleScalar 2 軸交差積" {
    const peak = [_]f32{ 1.0, 1.0 };
    // (0.2, 0.7) → 0.2 * 0.7 = 0.14
    try testing.expectApproxEqAbs(@as(f32, 0.14), tupleScalar(&.{ 0.2, 0.7 }, &peak, false, &.{}, &.{}), 0.001);
}

test "gvar: tupleScalar intermediate テント" {
    const peak = [_]f32{0.5};
    const start = [_]f32{0.0};
    const end = [_]f32{1.0};
    try testing.expectApproxEqAbs(@as(f32, 1.0), tupleScalar(&.{0.5}, &peak, true, &start, &end), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), tupleScalar(&.{0.25}, &peak, true, &start, &end), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), tupleScalar(&.{0.75}, &peak, true, &start, &end), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), tupleScalar(&.{1.0}, &peak, true, &start, &end), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), tupleScalar(&.{-0.1}, &peak, true, &start, &end), 0.001);
}

test "gvar: tupleScalar 無効/ゼロ跨ぎ region は中立 1（仕様必須分岐）" {
    // start > peak: region 無効 → その軸は 1（他軸のみ効く）
    try testing.expectApproxEqAbs(@as(f32, 1.0), tupleScalar(&.{0.3}, &.{0.5}, true, &.{0.8}, &.{1.0}), 0.001);
    // peak > end: region 無効 → 1
    try testing.expectApproxEqAbs(@as(f32, 1.0), tupleScalar(&.{0.3}, &.{0.9}, true, &.{0.0}, &.{0.5}), 0.001);
    // start < 0 < end（peak≠0）: ゼロ跨ぎ → 1
    try testing.expectApproxEqAbs(@as(f32, 1.0), tupleScalar(&.{0.3}, &.{0.5}, true, &.{-0.5}, &.{1.0}), 0.001);
}

test "gvar: IUP 中間補間 手計算（仕様例）" {
    // P1.x=245 d=+28, P3.x=305 d=-42, P2.x=260 → proportion=(260-245)/(305-245)=15/60=0.25
    // delta = (1-0.25)*28 + 0.25*(-42) = 21 - 10.5 = 10.5
    try testing.expectApproxEqAbs(@as(f32, 10.5), iupComponent(245, 305, 260, 28, -42), 0.001);
}

test "gvar: IUP 同座標異 delta → 0 / 同座標同 delta → 同値" {
    try testing.expectEqual(@as(f32, 0), iupComponent(10, 10, 10, 5, 7));
    try testing.expectEqual(@as(f32, 5), iupComponent(10, 10, 10, 5, 5));
}

test "gvar: IUP 範囲外 → 近い側" {
    // target が prev 側外
    try testing.expectEqual(@as(f32, 10), iupComponent(0, 100, -10, 10, 20));
    // target が next 側外
    try testing.expectEqual(@as(f32, 20), iupComponent(0, 100, 150, 10, 20));
}

test "gvar: packed point numbers 全形式" {
    const a = testing.allocator;
    // count=3, run of 3 bytes: 0,1,1 → points 0,1,2
    const data1 = [_]u8{ 3, 0x02, 0, 1, 1 };
    const p1 = try decodePackedPointNumbers(a, &data1, 0, 10);
    defer a.free(p1.indices);
    try testing.expectEqual(@as(usize, 3), p1.indices.len);
    try testing.expectEqual(@as(u16, 0), p1.indices[0]);
    try testing.expectEqual(@as(u16, 1), p1.indices[1]);
    try testing.expectEqual(@as(u16, 2), p1.indices[2]);
    try testing.expect(!p1.all_points);

    // all points
    const data0 = [_]u8{0};
    const p0 = try decodePackedPointNumbers(a, &data0, 0, 10);
    try testing.expect(p0.all_points);
    try testing.expectEqual(@as(usize, 0), p0.indices.len);

    // 2-byte count: 0x80|0, 0x02 → count=2, then words run
    const data2 = [_]u8{ 0x80, 0x02, 0x81, 0x00, 0x00, 0x00, 0x05 }; // count=2, run words count=2: 0, 5
    const p2 = try decodePackedPointNumbers(a, &data2, 0, 20);
    defer a.free(p2.indices);
    try testing.expectEqual(@as(usize, 2), p2.indices.len);
    try testing.expectEqual(@as(u16, 0), p2.indices[0]);
    try testing.expectEqual(@as(u16, 5), p2.indices[1]);
}

test "gvar: packed deltas 全 run 形式" {
    const a = testing.allocator;
    // 例: 03 0A 97 00 C6 87 41 10 22 FB 34
    // run1: 4 × i8 = 10, -105, 0, -58
    // run2: 8 zeros
    // run3: 2 × i16 = 0x1022=4130, 0xFB34=-1228
    const data = [_]u8{ 0x03, 0x0A, 0x97, 0x00, 0xC6, 0x87, 0x41, 0x10, 0x22, 0xFB, 0x34 };
    const d = try decodePackedDeltas(a, &data, 0, 14);
    defer a.free(d);
    try testing.expectEqual(@as(f32, 10), d[0]);
    try testing.expectEqual(@as(f32, -105), d[1]);
    try testing.expectEqual(@as(f32, 0), d[2]);
    try testing.expectEqual(@as(f32, -58), d[3]);
    try testing.expectEqual(@as(f32, 0), d[4]);
    try testing.expectEqual(@as(f32, 4130), d[12]);
    try testing.expectEqual(@as(f32, -1228), d[13]);
}

/// 最小 gvar: 1 軸・1 glyph・embedded peak=1・全点明示デルタ。
/// n_outline 点 + 4 phantom。deltas_x/y は n_total 長。
fn buildMinimalGvar(
    alloc: std.mem.Allocator,
    n_outline: usize,
    deltas_x: []const i16,
    deltas_y: []const i16,
) ![]u8 {
    const n_total = n_outline + 4;
    std.debug.assert(deltas_x.len == n_total and deltas_y.len == n_total);

    var ser: std.ArrayList(u8) = .empty;
    defer ser.deinit(alloc);
    try ser.append(alloc, 0); // all points
    try appendDeltaRuns(&ser, alloc, deltas_x);
    try appendDeltaRuns(&ser, alloc, deltas_y);

    var gvd: std.ArrayList(u8) = .empty;
    defer gvd.deinit(alloc);
    const data_off: u16 = 4 + 4 + 2; // count+offset + varSize+tupleIndex + peak
    try appendU16(&gvd, alloc, 1);
    try appendU16(&gvd, alloc, data_off);
    try appendU16(&gvd, alloc, @intCast(ser.items.len));
    try appendU16(&gvd, alloc, 0x8000 | 0x2000); // EMBEDDED_PEAK | PRIVATE_POINT_NUMBERS
    try appendI16(&gvd, alloc, f2d(1.0));
    try gvd.appendSlice(alloc, ser.items);

    var table: std.ArrayList(u8) = .empty;
    errdefer table.deinit(alloc);
    try appendU16(&table, alloc, 1);
    try appendU16(&table, alloc, 0);
    try appendU16(&table, alloc, 1);
    try appendU16(&table, alloc, 0);
    try appendU32(&table, alloc, 0);
    try appendU16(&table, alloc, 1);
    try appendU16(&table, alloc, 1);
    try appendU32(&table, alloc, 28);
    try appendU32(&table, alloc, 0);
    try appendU32(&table, alloc, @intCast(gvd.items.len));
    try table.appendSlice(alloc, gvd.items);
    return table.toOwnedSlice(alloc);
}

fn appendU16(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u16) !void {
    try list.append(alloc, @intCast(v >> 8));
    try list.append(alloc, @truncate(v));
}
fn appendU32(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u32) !void {
    try list.append(alloc, @truncate(v >> 24));
    try list.append(alloc, @truncate(v >> 16));
    try list.append(alloc, @truncate(v >> 8));
    try list.append(alloc, @truncate(v));
}
fn appendI16(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: i16) !void {
    try appendU16(list, alloc, @bitCast(v));
}

fn appendDeltaRuns(list: *std.ArrayList(u8), alloc: std.mem.Allocator, deltas: []const i16) !void {
    var i: usize = 0;
    while (i < deltas.len) {
        const remaining = deltas.len - i;
        const run = @min(remaining, 64);
        const control: u8 = 0x40 | @as(u8, @intCast(run - 1)); // WORDS
        try list.append(alloc, control);
        var k: usize = 0;
        while (k < run) : (k += 1) {
            try appendI16(list, alloc, deltas[i + k]);
        }
        i += run;
    }
}

test "gvar: 1 tuple 全点明示デルタ・norm=1 で座標一致" {
    const a = testing.allocator;
    // 3 outline points + 4 phantom
    const dx = [_]i16{ 10, 20, 30, 0, 5, 0, 0 }; // phantom: lsb=0, adv=+5
    const dy = [_]i16{ 1, 2, 3, 0, 0, 0, 0 };
    const table = try buildMinimalGvar(a, 3, &dx, &dy);
    defer a.free(table);

    const gv = try Gvar.parse(table, 1, 1);
    const pts = [_]Vec2f{
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
        .{ .x = 50, .y = 80 },
    };
    const end_pts = [_]u16{2};
    var deltas: [7]Vec2f = undefined;
    try gv.applySimple(a, 0, &pts, &end_pts, &.{1.0}, &deltas);
    try testing.expectApproxEqAbs(@as(f32, 10), deltas[0].x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 20), deltas[1].x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 30), deltas[2].x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1), deltas[0].y, 0.01);
    // phantom advance delta = 5 - 0 = 5
    try testing.expectApproxEqAbs(@as(f32, 5), deltas[4].x - deltas[3].x, 0.01);
}

test "gvar: norm=0 で deltas ゼロ" {
    const a = testing.allocator;
    const dx = [_]i16{ 10, 20, 30, 0, 5, 0, 0 };
    const dy = [_]i16{ 1, 2, 3, 0, 0, 0, 0 };
    const table = try buildMinimalGvar(a, 3, &dx, &dy);
    defer a.free(table);
    const gv = try Gvar.parse(table, 1, 1);
    const pts = [_]Vec2f{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 }, .{ .x = 50, .y = 80 } };
    const end_pts = [_]u16{2};
    var deltas: [7]Vec2f = undefined;
    try gv.applySimple(a, 0, &pts, &end_pts, &.{0.0}, &deltas);
    for (deltas) |d| {
        try testing.expectEqual(@as(f32, 0), d.x);
        try testing.expectEqual(@as(f32, 0), d.y);
    }
}

/// 部分点デルタ gvar（IUP 検証用）: private points で点 0 と 2 のみ明示。
fn buildPartialPointsGvar(
    alloc: std.mem.Allocator,
    /// 明示する点 index（outline のみ想定）
    point_ids: []const u16,
    dx: []const i16,
    dy: []const i16,
    peak: f32,
) ![]u8 {
    std.debug.assert(point_ids.len == dx.len and dx.len == dy.len);
    var ser: std.ArrayList(u8) = .empty;
    defer ser.deinit(alloc);
    // private points: count + run
    try ser.append(alloc, @intCast(point_ids.len));
    // 1 run of bytes (assuming small indices, cumulative)
    try ser.append(alloc, @intCast(point_ids.len - 1)); // run count-1, bytes
    var last: u16 = 0;
    for (point_ids) |pid| {
        const delta: u8 = @intCast(pid - last);
        try ser.append(alloc, delta);
        last = pid;
    }
    try appendDeltaRuns(&ser, alloc, dx);
    try appendDeltaRuns(&ser, alloc, dy);

    var gvd: std.ArrayList(u8) = .empty;
    defer gvd.deinit(alloc);
    const data_off: u16 = 4 + 4 + 2;
    try appendU16(&gvd, alloc, 1);
    try appendU16(&gvd, alloc, data_off);
    try appendU16(&gvd, alloc, @intCast(ser.items.len));
    try appendU16(&gvd, alloc, 0x8000 | 0x2000); // EMBEDDED | PRIVATE
    try appendI16(&gvd, alloc, f2d(peak));
    try gvd.appendSlice(alloc, ser.items);

    var table: std.ArrayList(u8) = .empty;
    errdefer table.deinit(alloc);
    try appendU16(&table, alloc, 1);
    try appendU16(&table, alloc, 0);
    try appendU16(&table, alloc, 1);
    try appendU16(&table, alloc, 0);
    try appendU32(&table, alloc, 0);
    try appendU16(&table, alloc, 1);
    try appendU16(&table, alloc, 1);
    try appendU32(&table, alloc, 28);
    try appendU32(&table, alloc, 0);
    try appendU32(&table, alloc, @intCast(gvd.items.len));
    try table.appendSlice(alloc, gvd.items);
    return table.toOwnedSlice(alloc);
}

test "gvar: IUP 中間点推論が手計算一致" {
    const a = testing.allocator;
    // 3 点 contour: p0=(0,0), p1=(50,0), p2=(100,0)。明示 p0.dx=0, p2.dx=40 → p1 中間 = 20
    const table = try buildPartialPointsGvar(a, &.{ 0, 2 }, &.{ 0, 40 }, &.{ 0, 0 }, 1.0);
    defer a.free(table);
    const gv = try Gvar.parse(table, 1, 1);
    const pts = [_]Vec2f{
        .{ .x = 0, .y = 0 },
        .{ .x = 50, .y = 0 },
        .{ .x = 100, .y = 0 },
    };
    const end_pts = [_]u16{2};
    var deltas: [7]Vec2f = undefined;
    try gv.applySimple(a, 0, &pts, &end_pts, &.{1.0}, &deltas);
    try testing.expectApproxEqAbs(@as(f32, 0), deltas[0].x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 20), deltas[1].x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 40), deltas[2].x, 0.01);
}

/// 2 tuple の gvar: tuple A は点 0 のみ、tuple B は点 1 のみ。汚染防止検証用。
fn buildTwoTupleIupGvar(alloc: std.mem.Allocator) ![]u8 {
    // 両 tuple: peak=1, private points, 1 point each
    // tuple A: point 0, dx=100
    // tuple B: point 1, dx=50
    // 点 2 はどちらにも無い → IUP: 各 tuple 独立
    //   tuple A: refs={0}, 全点に 100 → *scalar
    //   tuple B: refs={1}, 全点に 50
    // でも wait: 1 ref → 全 contour に同じ delta。
    // 汚染ケース: tuple A が点 0 のみ、tuple B が点 2 のみ。
    // 点 1 は A では IUP(from 0 only=100), B では IUP(from 2 only=50)。
    // 累積 = 100*s + 50*s。
    // もし全 tuple 累積後に一度 IUP すると: explicit = {0:100, 2:50}, 点1 は線形 = 75。
    // → 結果が異なる。

    // Serialize tuple A data
    var ser_a: std.ArrayList(u8) = .empty;
    defer ser_a.deinit(alloc);
    try ser_a.append(alloc, 1); // count=1
    try ser_a.append(alloc, 0); // run: 1 element (count-1=0), bytes
    try ser_a.append(alloc, 0); // point 0
    try ser_a.append(alloc, 0x40); // 1 word delta X
    try appendI16(&ser_a, alloc, 100);
    try ser_a.append(alloc, 0x40); // 1 word delta Y
    try appendI16(&ser_a, alloc, 0);

    var ser_b: std.ArrayList(u8) = .empty;
    defer ser_b.deinit(alloc);
    try ser_b.append(alloc, 1);
    try ser_b.append(alloc, 0);
    try ser_b.append(alloc, 2); // point 2
    try ser_b.append(alloc, 0x40);
    try appendI16(&ser_b, alloc, 50);
    try ser_b.append(alloc, 0x40);
    try appendI16(&ser_b, alloc, 0);

    // GVD with 2 tuples, both EMBEDDED_PEAK | PRIVATE
    // dataOffset = 4 + 2*(4+2) = 4+12 = 16
    var gvd: std.ArrayList(u8) = .empty;
    defer gvd.deinit(alloc);
    try appendU16(&gvd, alloc, 2); // 2 tuples
    try appendU16(&gvd, alloc, 16); // dataOffset
    // header A
    try appendU16(&gvd, alloc, @intCast(ser_a.items.len));
    try appendU16(&gvd, alloc, 0x8000 | 0x2000);
    try appendI16(&gvd, alloc, f2d(1.0));
    // header B
    try appendU16(&gvd, alloc, @intCast(ser_b.items.len));
    try appendU16(&gvd, alloc, 0x8000 | 0x2000);
    try appendI16(&gvd, alloc, f2d(1.0));
    try gvd.appendSlice(alloc, ser_a.items);
    try gvd.appendSlice(alloc, ser_b.items);

    var table: std.ArrayList(u8) = .empty;
    errdefer table.deinit(alloc);
    try appendU16(&table, alloc, 1);
    try appendU16(&table, alloc, 0);
    try appendU16(&table, alloc, 1);
    try appendU16(&table, alloc, 0);
    try appendU32(&table, alloc, 0);
    try appendU16(&table, alloc, 1);
    try appendU16(&table, alloc, 1);
    try appendU32(&table, alloc, 28);
    try appendU32(&table, alloc, 0);
    try appendU32(&table, alloc, @intCast(gvd.items.len));
    try table.appendSlice(alloc, gvd.items);
    return table.toOwnedSlice(alloc);
}

test "gvar: per-tuple IUP 汚染防止（別 tuple 明示点を参照しない）" {
    const a = testing.allocator;
    const table = try buildTwoTupleIupGvar(a);
    defer a.free(table);
    const gv = try Gvar.parse(table, 1, 1);
    // 3 点等間隔
    const pts = [_]Vec2f{
        .{ .x = 0, .y = 0 },
        .{ .x = 50, .y = 0 },
        .{ .x = 100, .y = 0 },
    };
    const end_pts = [_]u16{2};
    var deltas: [7]Vec2f = undefined;
    try gv.applySimple(a, 0, &pts, &end_pts, &.{1.0}, &deltas);

    // per-tuple: A は 1 参照点 → 全点 100, B は 1 参照点 → 全点 50
    // 累積: 各点 150
    // もし post-accumulate IUP なら点1 = 線形(100,50)=75
    try testing.expectApproxEqAbs(@as(f32, 150), deltas[0].x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 150), deltas[1].x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 150), deltas[2].x, 0.01);
}

test "gvar: malformed offset は InvalidFont" {
    var bad: [28]u8 = .{0} ** 28;
    putU16(&bad, 0, 1);
    putU16(&bad, 4, 1); // axisCount
    putU16(&bad, 12, 1); // glyphCount
    putU16(&bad, 14, 1); // long offsets
    putU32(&bad, 16, 28);
    putU32(&bad, 20, 100); // off0 too large
    putU32(&bad, 24, 200);
    try testing.expectError(error.InvalidFont, Gvar.parse(&bad, 1, 1));
}

test "gvar: axisCount 不一致は InvalidFont" {
    const a = testing.allocator;
    const dx = [_]i16{ 0, 0, 0, 0, 0, 0, 0 };
    const dy = [_]i16{ 0, 0, 0, 0, 0, 0, 0 };
    const table = try buildMinimalGvar(a, 3, &dx, &dy);
    defer a.free(table);
    try testing.expectError(error.InvalidFont, Gvar.parse(table, 1, 2));
}

test "gvar: X と Y で IUP 結果が独立" {
    // p0=(0,0) d=(10,100), p2=(100,100) d=(30,0), p1=(50,10)
    // X: 中間 → 20
    // Y: p1.y=10 は [0,100] 内 → proportion = 10/100 = 0.1 → (1-0.1)*100 + 0.1*0 = 90
    try testing.expectApproxEqAbs(@as(f32, 20), iupComponent(0, 100, 50, 10, 30), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 90), iupComponent(0, 100, 10, 100, 0), 0.01);
}
