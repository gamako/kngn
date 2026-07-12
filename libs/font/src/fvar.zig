// fvar テーブルパーサ（OpenType Font Variations 軸定義 + named instance）。
//
// ホットパス宣言: **FontFace.init 時のみ**（sbix と同格）。ゼロアロケーション（owned 固定配列）。
//
// ヘッダ（OpenType spec）: majorVersion@0 / minorVersion@2 / axesArrayOffset@4 /
// reserved@6（検証しない）/ axisCount@8 / axisSize@10 / instanceCount@12 / instanceSize@14。

const std = @import("std");
const Reader = @import("byte_reader.zig").Reader;
const var_common = @import("var_common.zig");

pub const Error = var_common.Error;
pub const MAX_AXES = var_common.MAX_AXES;
pub const fixedToF32 = var_common.fixedToF32;
pub const axisTagEq = var_common.axisTagEq;

pub const Axis = struct {
    tag: [4]u8,
    min: f32,
    def: f32,
    max: f32,
    flags: u16,
    name_id: u16,
};

pub const Fvar = struct {
    data: []const u8,
    axis_count: u16,
    axes: [MAX_AXES]Axis,
    instance_count: u16,
    instance_size: u16,
    /// InstanceRecord 配列のテーブル内先頭（遅延読取用）。
    instances_off: usize,

    pub fn axis(self: *const Fvar, i: usize) Axis {
        return self.axes[i];
    }

    pub fn axisIndex(self: *const Fvar, tag: *const [4]u8) ?usize {
        const n = self.axis_count;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (axisTagEq(&self.axes[i].tag, tag)) return i;
        }
        return null;
    }

    fn instanceRecordOff(self: *const Fvar, index: u16) Error!usize {
        if (index >= self.instance_count) return error.InvalidFont;
        return self.instances_off + @as(usize, index) * self.instance_size;
    }

    fn instanceHasPostScriptName(self: *const Fvar) bool {
        const expected_base = @as(usize, self.axis_count) * 4 + 4;
        return self.instance_size == expected_base + 2;
    }

    /// named instance の design coords を読み出す（遅延読取）。
    pub fn namedInstanceCoords(self: *const Fvar, index: u16, out: []f32) Error!void {
        if (out.len < self.axis_count) return error.InvalidFont;
        const off = try self.instanceRecordOff(index);
        const r = Reader{ .data = self.data };
        try r.require(off, self.instance_size);
        const coords_off = off + 4;
        var i: u16 = 0;
        while (i < self.axis_count) : (i += 1) {
            const raw = try r.i32At(coords_off + @as(usize, i) * 4);
            out[i] = fixedToF32(raw);
        }
    }

    pub fn parse(table: []const u8) Error!Fvar {
        const r = Reader{ .data = table };
        try r.require(0, 16);
        const major = try r.u16At(0);
        const minor = try r.u16At(2);
        if (major != 1 or minor != 0) return error.InvalidFont;
        const axes_array_offset = try r.u16At(4);
        _ = try r.u16At(6); // reserved（permanently reserved。値は検証しない）
        const axis_count = try r.u16At(8);
        const axis_size = try r.u16At(10);
        const instance_count = try r.u16At(12);
        const instance_size = try r.u16At(14);

        if (axis_size != 20) return error.InvalidFont;
        if (axis_count == 0 and instance_count > 0) return error.InvalidFont;
        if (axis_count > MAX_AXES) return error.Unsupported;
        if (axes_array_offset < 16) return error.InvalidFont;

        const axes_off: usize = axes_array_offset;
        const axes_bytes = std.math.mul(usize, @as(usize, axis_count), axis_size) catch return error.InvalidFont;
        try r.require(axes_off, axes_bytes);

        var result: Fvar = .{
            .data = table,
            .axis_count = axis_count,
            .axes = undefined,
            .instance_count = instance_count,
            .instance_size = instance_size,
            .instances_off = axes_off + axes_bytes,
        };

        var ai: usize = 0;
        while (ai < axis_count) : (ai += 1) {
            const off = axes_off + ai * axis_size;
            var tag: [4]u8 = undefined;
            tag[0] = try r.u8At(off);
            tag[1] = try r.u8At(off + 1);
            tag[2] = try r.u8At(off + 2);
            tag[3] = try r.u8At(off + 3);
            const min_v = fixedToF32(try r.i32At(off + 4));
            const def_v = fixedToF32(try r.i32At(off + 8));
            const max_v = fixedToF32(try r.i32At(off + 12));
            try var_common.validateAxisRange(min_v, def_v, max_v);
            result.axes[ai] = .{
                .tag = tag,
                .min = min_v,
                .def = def_v,
                .max = max_v,
                .flags = try r.u16At(off + 16),
                .name_id = try r.u16At(off + 18),
            };
        }

        const expected_base = @as(usize, axis_count) * 4 + 4;
        const expected_ps = expected_base + 2;
        if (instance_size != expected_base and instance_size != expected_ps) return error.InvalidFont;

        const instances_bytes = std.math.mul(usize, @as(usize, instance_count), instance_size) catch return error.InvalidFont;
        try r.require(result.instances_off, instances_bytes);

        var ii: u16 = 0;
        while (ii < instance_count) : (ii += 1) {
            const off = try result.instanceRecordOff(ii);
            try r.require(off, instance_size);
            _ = try r.u16At(off); // subfamilyNameID
            _ = try r.u16At(off + 2); // flags
            if (result.instanceHasPostScriptName()) {
                _ = try r.u16At(off + 4 + @as(usize, axis_count) * 4);
            }
            // 全座標を軸 [min,max] で init 時検証
            var ci: u16 = 0;
            while (ci < axis_count) : (ci += 1) {
                const coord = fixedToF32(try r.i32At(off + 4 + @as(usize, ci) * 4));
                const ax = result.axes[ci];
                if (coord < ax.min or coord > ax.max) return error.InvalidFont;
            }
        }

        return result;
    }
};

// parse は allocator 引数を取らない（ゼロアロケーション契約）
comptime {
    const parse_fn = @TypeOf(Fvar.parse);
    const params = @typeInfo(parse_fn).@"fn".params;
    for (params) |p| {
        const ty = p.type orelse continue;
        if (@typeInfo(ty) == .pointer) {
            const ptr = @typeInfo(ty).pointer;
            if (ptr.size == .one and ptr.child == std.mem.Allocator) @compileError("Fvar.parse must not take Allocator");
        }
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

const FvarTestTable = struct {
    buf: [256]u8,
    len: usize,
};

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
fn putI32(buf: []u8, off: usize, v: i32) void {
    putU32(buf, off, @bitCast(v));
}
fn putTag(buf: []u8, off: usize, tag: [4]u8) void {
    @memcpy(buf[off..][0..4], &tag);
}

/// OpenType 仕様どおりの 1 軸 wght fvar テーブルを組む。戻り値の有効長は `tableLen`。
fn buildFvar1Axis(
    axis_tag: [4]u8,
    min_v: i32,
    def_v: i32,
    max_v: i32,
    instance_count: u16,
    instance_size: u16,
    instances_body: []const u8,
) FvarTestTable {
    const axes_off: usize = 16;
    const axis_bytes: usize = 20;
    const inst_off = axes_off + axis_bytes;
    const total = inst_off + instances_body.len;
    var result: FvarTestTable = .{ .buf = undefined, .len = total };
    @memset(&result.buf, 0);
    putU16(&result.buf, 0, 1);
    putU16(&result.buf, 2, 0);
    putU16(&result.buf, 4, @intCast(axes_off));
    putU16(&result.buf, 6, 2);
    putU16(&result.buf, 8, 1);
    putU16(&result.buf, 10, @intCast(axis_bytes));
    putU16(&result.buf, 12, instance_count);
    putU16(&result.buf, 14, instance_size);
    putTag(&result.buf, axes_off, axis_tag);
    putI32(&result.buf, axes_off + 4, min_v);
    putI32(&result.buf, axes_off + 8, def_v);
    putI32(&result.buf, axes_off + 12, max_v);
    if (instances_body.len > 0) {
        @memcpy(result.buf[inst_off..][0..instances_body.len], instances_body);
    }
    return result;
}

test "fvar: parse axisCount/tag/min/def/max" {
    const wght = [4]u8{ 'w', 'g', 'h', 't' };
    const built = buildFvar1Axis(wght, 100 * 65536, 400 * 65536, 900 * 65536, 0, 8, &.{});
    const f = try Fvar.parse(built.buf[0..built.len]);

    try testing.expectEqual(@as(u16, 1), f.axis_count);
    try testing.expect(axisTagEq(&f.axes[0].tag, &wght));
    try testing.expectEqual(@as(f32, 100), f.axes[0].min);
    try testing.expectEqual(@as(f32, 400), f.axes[0].def);
    try testing.expectEqual(@as(f32, 900), f.axes[0].max);
}

test "fvar: MAX_AXES 超過は Unsupported" {
    var buf: [16]u8 = undefined;
    @memset(&buf, 0);
    putU16(&buf, 0, 1);
    putU16(&buf, 4, 16);
    putU16(&buf, 8, 17); // axisCount > MAX_AXES
    putU16(&buf, 10, 20);
    try testing.expectError(error.Unsupported, Fvar.parse(&buf));
}

test "fvar: named instance 範囲外レコードは InvalidFont" {
    const wght = [4]u8{ 'w', 'g', 'h', 't' };
    const built = buildFvar1Axis(wght, 0, 400 * 65536, 900 * 65536, 1, 8, &.{ 0, 0, 0, 0 });
    try testing.expectError(error.InvalidFont, Fvar.parse(built.buf[0..built.len]));
}

test "fvar: named instance 座標が軸範囲外は InvalidFont" {
    const wght = [4]u8{ 'w', 'g', 'h', 't' };
    var inst_fixed: [8]u8 = .{ 0, 1, 0, 0, 0, 0, 0, 0 };
    putI32(&inst_fixed, 4, 2000 * 65536); // wght=2000 > max=900
    const built = buildFvar1Axis(wght, 100 * 65536, 400 * 65536, 900 * 65536, 1, 8, &inst_fixed);
    try testing.expectError(error.InvalidFont, Fvar.parse(built.buf[0..built.len]));
}

test "fvar: min>def は InvalidFont" {
    const wght = [4]u8{ 'w', 'g', 'h', 't' };
    const built = buildFvar1Axis(wght, 500 * 65536, 400 * 65536, 900 * 65536, 0, 8, &.{});
    try testing.expectError(error.InvalidFont, Fvar.parse(built.buf[0..built.len]));
}

test "fvar: axesArrayOffset < 16 は InvalidFont" {
    const wght = [4]u8{ 'w', 'g', 'h', 't' };
    var built = buildFvar1Axis(wght, 100 * 65536, 400 * 65536, 900 * 65536, 0, 8, &.{});
    putU16(&built.buf, 4, 0); // axesArrayOffset=0 < header size 16
    try testing.expectError(error.InvalidFont, Fvar.parse(built.buf[0..built.len]));
}
