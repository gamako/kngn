// CFF INDEX structure + Type2 / CFF2 charstring interpreter.
//
// The CFF container (cff.zig) uses Index to parse each INDEX and supply subrs; glyph drawing calls run() /
// runCff2(). run() is CFF1 Type2; runCff2() is CFF2 (blend/vsindex; no width).
//
// Hot-path note: charstring interpretation runs only on raster cache miss.
//
// Accepted limits: arithmetic/logical/storage/conditional 12xx ops are unsupported (Unsupported).
// Flex family (12 34-37) is supported. seac / Type1 charstrings are unsupported. CFF1 width is consumed only (advance from hmtx).

const std = @import("std");
const Reader = @import("byte_reader.zig").Reader;
const outline = @import("outline.zig");
const ivs = @import("ivs.zig");
const var_common = @import("var_common.zig");

pub const Error = error{ InvalidFont, Unsupported, OutOfMemory };

const max_stack = 48;
const max_stack_cff2 = 513;
const max_depth = 10;
const max_stems = 96;
const max_steps = 1 << 20; // Runaway guard (total operator execution count)
const max_regions = 64; // Upper bound on blend region scalars

/// CFF / CFF2 INDEX. count is CFF1=u16 / CFF2=u32.
/// offset[count+1] (1-based) object data.
pub const Index = struct {
    data: []const u8,
    count: u32,
    off_size: u8,
    offsets_start: usize, // Start of the offset array
    obj_base: usize, // Offset value v → byte (obj_base + v). I.e. data-1.
    end: usize, // End of the INDEX (start of the next structure)

    /// CFF1: count(u16) offSize offset[] data
    pub fn parse(data: []const u8, off: usize) Error!Index {
        return parseInner(data, off, false);
    }

    /// CFF2: count(u32) offSize offset[] data
    pub fn parseCff2(data: []const u8, off: usize) Error!Index {
        return parseInner(data, off, true);
    }

    fn parseInner(data: []const u8, off: usize, is_cff2: bool) Error!Index {
        const r = Reader{ .data = data };
        const count_size: usize = if (is_cff2) 4 else 2;
        try r.require(off, count_size);
        const count: u32 = if (is_cff2) try r.u32At(off) else try r.u16At(off);
        if (count == 0) {
            return .{
                .data = data,
                .count = 0,
                .off_size = 0,
                .offsets_start = off + count_size,
                .obj_base = off + count_size,
                .end = off + count_size,
            };
        }
        const off_size = try r.u8At(off + count_size);
        if (off_size < 1 or off_size > 4) return error.InvalidFont;
        const offsets_start = off + count_size + 1;
        const n_off = @as(usize, count) + 1;
        try r.require(offsets_start, n_off * @as(usize, off_size));
        const obj_base = offsets_start + n_off * @as(usize, off_size) - 1;

        var prev: u32 = 0;
        var i: usize = 0;
        while (i < n_off) : (i += 1) {
            const v = readOffset(data, offsets_start, off_size, i);
            if (i == 0) {
                if (v != 1) return error.InvalidFont;
            } else if (v < prev) {
                return error.InvalidFont;
            }
            prev = v;
        }
        const last = prev;
        try r.require(obj_base, last);
        return .{
            .data = data,
            .count = count,
            .off_size = off_size,
            .offsets_start = offsets_start,
            .obj_base = obj_base,
            .end = obj_base + last,
        };
    }

    /// Byte slice for entry i. Out of range → null.
    pub fn get(self: Index, i: usize) ?[]const u8 {
        if (i >= self.count) return null;
        const a = readOffset(self.data, self.offsets_start, self.off_size, i);
        const b = readOffset(self.data, self.offsets_start, self.off_size, i + 1);
        if (b < a) return null;
        return self.data[self.obj_base + a .. self.obj_base + b];
    }
};

fn readOffset(data: []const u8, offsets_start: usize, off_size: u8, i: usize) u32 {
    var v: u32 = 0;
    var k: usize = 0;
    while (k < off_size) : (k += 1) {
        v = (v << 8) | data[offsets_start + i * @as(usize, off_size) + k];
    }
    return v;
}

/// subr bias (depends on count).
pub fn subrBias(count: u32) i32 {
    if (count < 1240) return 107;
    if (count < 33900) return 1131;
    return 32768;
}

const Result = enum { normal, returned, ended };

/// CFF2 blend context (VariationStore + current vsindex + region scalars).
pub const BlendState = struct {
    table: []const u8,
    ivs_off: usize,
    axis_count: u16,
    vsindex: u16 = 0,
    scalars: [max_regions]f32 = undefined,
    n_regions: u16 = 0,
    scalars_valid: bool = false,

    fn ensureScalars(self: *BlendState, norm: []const f32) Error!void {
        if (self.scalars_valid) return;
        self.n_regions = try ivs.regionScalarsForIvd(
            self.table,
            self.ivs_off,
            self.vsindex,
            norm,
            self.axis_count,
            self.scalars[0..],
        );
        self.scalars_valid = true;
    }

    fn setVsindex(self: *BlendState, idx: u16) void {
        if (self.vsindex != idx) {
            self.vsindex = idx;
            self.scalars_valid = false;
        }
    }
};

const Ctx = struct {
    b: *outline.Builder,
    gsubrs: Index,
    gbias: i32,
    lsubrs: Index,
    lbias: i32,
    nominal_width: f64,
    default_width: f64,
    /// CFF2 mode: no width; blend/vsindex; larger stack
    cff2: bool = false,
    blend: ?*BlendState = null,
    norm: []const f32 = &.{},
    stack_limit: usize = max_stack,

    stack: [max_stack_cff2]f64 = undefined,
    sp: usize = 0,
    x: f64 = 0,
    y: f64 = 0,
    n_stems: u32 = 0,
    width_parsed: bool = false,
    open: bool = false,
    steps: u32 = 0,

    fn push(self: *Ctx, v: f64) Error!void {
        if (self.sp >= self.stack_limit) return error.InvalidFont;
        self.stack[self.sp] = v;
        self.sp += 1;
    }

    fn pt(self: *Ctx) outline.Vec2f {
        return .{ .x = @floatCast(self.x), .y = @floatCast(self.y) };
    }

    fn moveTo(self: *Ctx, dx: f64, dy: f64) Error!void {
        self.x += dx;
        self.y += dy;
        try self.b.moveTo(self.pt());
        self.open = true;
    }
    fn lineTo(self: *Ctx, dx: f64, dy: f64) Error!void {
        self.x += dx;
        self.y += dy;
        try self.b.lineTo(self.pt());
    }
    /// Draw a cubic from three relative control-point deltas (not absolute).
    fn curveTo(self: *Ctx, dx1: f64, dy1: f64, dx2: f64, dy2: f64, dx3: f64, dy3: f64) Error!void {
        const c1x = self.x + dx1;
        const c1y = self.y + dy1;
        const c2x = c1x + dx2;
        const c2y = c1y + dy2;
        self.x = c2x + dx3;
        self.y = c2y + dy3;
        try self.b.cubicTo(.{ .x = @floatCast(c1x), .y = @floatCast(c1y) }, .{ .x = @floatCast(c2x), .y = @floatCast(c2y) }, self.pt());
    }

    /// Consume width on the first stack-clearing operator (advance prefers hmtx, so the value is discarded).
    /// even_args=true: even arg count expected (rmoveto etc.) / false: odd expected (hmoveto/vmoveto/endchar handled separately).
    /// Pass expected arg count; if sp is expected+1, drop the leading width.
    fn maybeWidth(self: *Ctx, expected_parity_odd: bool) void {
        if (self.width_parsed) return;
        self.width_parsed = true;
        const odd = (self.sp % 2) == 1;
        // expected_parity_odd: whether args are inherently odd (hmoveto/vmoveto=1, endchar=0, stem=even).
        // Detect "one more real arg than expected (leading width)" via parity.
        if (odd != expected_parity_odd) {
            // Drop leading width
            shiftLeft(self);
        }
    }

    fn clear(self: *Ctx) void {
        self.sp = 0;
    }
};

fn shiftLeft(self: *Ctx) void {
    if (self.sp == 0) return;
    var i: usize = 1;
    while (i < self.sp) : (i += 1) self.stack[i - 1] = self.stack[i];
    self.sp -= 1;
}

/// Execute a CFF1 Type2 charstring and emit path into Builder.
pub fn run(
    b: *outline.Builder,
    code: []const u8,
    gsubrs: Index,
    lsubrs: Index,
    nominal_width: f64,
    default_width: f64,
) Error!void {
    var ctx = Ctx{
        .b = b,
        .gsubrs = gsubrs,
        .gbias = subrBias(gsubrs.count),
        .lsubrs = lsubrs,
        .lbias = subrBias(lsubrs.count),
        .nominal_width = nominal_width,
        .default_width = default_width,
        .cff2 = false,
        .stack_limit = max_stack,
    };
    _ = try exec(&ctx, code, 0);
}

/// CFF2 charstring (no width; blend/vsindex). If blend_state=null, blend is InvalidFont.
pub fn runCff2(
    b: *outline.Builder,
    code: []const u8,
    gsubrs: Index,
    lsubrs: Index,
    blend_state: ?*BlendState,
    norm: []const f32,
) Error!void {
    var ctx = Ctx{
        .b = b,
        .gsubrs = gsubrs,
        .gbias = subrBias(gsubrs.count),
        .lsubrs = lsubrs,
        .lbias = subrBias(lsubrs.count),
        .nominal_width = 0,
        .default_width = 0,
        .cff2 = true,
        .blend = blend_state,
        .norm = norm,
        .stack_limit = max_stack_cff2,
        .width_parsed = true, // No width
    };
    _ = try exec(&ctx, code, 0);
}

fn exec(ctx: *Ctx, code: []const u8, depth: u32) Error!Result {
    if (depth > max_depth) return error.InvalidFont;
    var i: usize = 0;
    while (i < code.len) {
        ctx.steps += 1;
        if (ctx.steps > max_steps) return error.InvalidFont;
        const b0 = code[i];
        i += 1;

        if (b0 >= 32 or b0 == 28 or (ctx.cff2 and b0 == 255)) {
            // Operand (numeric). CFF2 also allows Fixed (255).
            const v = try readOperand(code, &i, b0);
            try ctx.push(v);
            continue;
        }

        switch (b0) {
            1, 3, 18, 23 => { // hstem/vstem/hstemhm/vstemhm
                ctx.maybeWidth(false); // stem takes even args (2*stem)
                addStems(ctx);
                ctx.clear();
            },
            19, 20 => { // hintmask / cntrmask
                ctx.maybeWidth(false);
                addStems(ctx); // Leftover args just before mask imply vstemhm
                ctx.clear();
                const nbytes = (ctx.n_stems + 7) / 8;
                if (i + nbytes > code.len) return error.InvalidFont;
                i += nbytes; // Skip mask bytes
            },
            21 => { // rmoveto
                ctx.maybeWidth(false); // dx dy = 2 args (even)
                if (ctx.sp != 2) return error.InvalidFont;
                try ctx.moveTo(ctx.stack[0], ctx.stack[1]);
                ctx.clear();
            },
            22 => { // hmoveto
                ctx.maybeWidth(true); // dx = 1 arg (odd)
                if (ctx.sp != 1) return error.InvalidFont;
                try ctx.moveTo(ctx.stack[0], 0);
                ctx.clear();
            },
            4 => { // vmoveto
                ctx.maybeWidth(true);
                if (ctx.sp != 1) return error.InvalidFont;
                try ctx.moveTo(0, ctx.stack[0]);
                ctx.clear();
            },
            5 => { // rlineto
                if (ctx.sp == 0 or ctx.sp % 2 != 0) return error.InvalidFont;
                var j: usize = 0;
                while (j + 2 <= ctx.sp) : (j += 2) try ctx.lineTo(ctx.stack[j], ctx.stack[j + 1]);
                ctx.clear();
            },
            6 => { // hlineto (H-leading alternating)
                if (ctx.sp == 0) return error.InvalidFont;
                try altLineto(ctx, true);
                ctx.clear();
            },
            7 => { // vlineto (V-leading alternating)
                if (ctx.sp == 0) return error.InvalidFont;
                try altLineto(ctx, false);
                ctx.clear();
            },
            8 => { // rrcurveto
                if (ctx.sp == 0 or ctx.sp % 6 != 0) return error.InvalidFont;
                var j: usize = 0;
                while (j + 6 <= ctx.sp) : (j += 6)
                    try ctx.curveTo(ctx.stack[j], ctx.stack[j + 1], ctx.stack[j + 2], ctx.stack[j + 3], ctx.stack[j + 4], ctx.stack[j + 5]);
                ctx.clear();
            },
            24 => { // rcurveline: {6}+ 2
                if (ctx.sp < 8 or (ctx.sp - 2) % 6 != 0) return error.InvalidFont;
                const n_curve = ctx.sp - 2;
                var j: usize = 0;
                while (j < n_curve) : (j += 6)
                    try ctx.curveTo(ctx.stack[j], ctx.stack[j + 1], ctx.stack[j + 2], ctx.stack[j + 3], ctx.stack[j + 4], ctx.stack[j + 5]);
                try ctx.lineTo(ctx.stack[n_curve], ctx.stack[n_curve + 1]);
                ctx.clear();
            },
            25 => { // rlinecurve: {2}+ 6
                if (ctx.sp < 8 or (ctx.sp - 6) % 2 != 0) return error.InvalidFont;
                const n_line = ctx.sp - 6;
                var j: usize = 0;
                while (j < n_line) : (j += 2) try ctx.lineTo(ctx.stack[j], ctx.stack[j + 1]);
                try ctx.curveTo(ctx.stack[n_line], ctx.stack[n_line + 1], ctx.stack[n_line + 2], ctx.stack[n_line + 3], ctx.stack[n_line + 4], ctx.stack[n_line + 5]);
                ctx.clear();
            },
            26 => { // vvcurveto: dx1? {dya dxb dyb dyc}+
                if (ctx.sp < 4 or ctx.sp % 4 > 1) return error.InvalidFont;
                var j: usize = 0;
                var dx1: f64 = 0;
                if (ctx.sp % 4 == 1) {
                    dx1 = ctx.stack[0];
                    j = 1;
                }
                while (j + 4 <= ctx.sp) : (j += 4) {
                    try ctx.curveTo(dx1, ctx.stack[j], ctx.stack[j + 1], ctx.stack[j + 2], 0, ctx.stack[j + 3]);
                    dx1 = 0;
                }
                ctx.clear();
            },
            27 => { // hhcurveto: dy1? {dxa dxb dyb dxc}+
                if (ctx.sp < 4 or ctx.sp % 4 > 1) return error.InvalidFont;
                var j: usize = 0;
                var dy1: f64 = 0;
                if (ctx.sp % 4 == 1) {
                    dy1 = ctx.stack[0];
                    j = 1;
                }
                while (j + 4 <= ctx.sp) : (j += 4) {
                    try ctx.curveTo(ctx.stack[j], dy1, ctx.stack[j + 1], ctx.stack[j + 2], ctx.stack[j + 3], 0);
                    dy1 = 0;
                }
                ctx.clear();
            },
            30 => { // vhcurveto (V-leading alternating)
                if (ctx.sp < 4 or ctx.sp % 4 > 1) return error.InvalidFont;
                try altCurveto(ctx, false);
                ctx.clear();
            },
            31 => { // hvcurveto (H-leading alternating)
                if (ctx.sp < 4 or ctx.sp % 4 > 1) return error.InvalidFont;
                try altCurveto(ctx, true);
                ctx.clear();
            },
            10 => { // callsubr
                if (ctx.sp < 1) return error.InvalidFont;
                ctx.sp -= 1;
                const idx = @as(i64, @intFromFloat(ctx.stack[ctx.sp])) + ctx.lbias;
                const sub = subrAt(ctx.lsubrs, idx) orelse return error.InvalidFont;
                const r = try exec(ctx, sub, depth + 1);
                if (r == .ended) return .ended;
            },
            29 => { // callgsubr
                if (ctx.sp < 1) return error.InvalidFont;
                ctx.sp -= 1;
                const idx = @as(i64, @intFromFloat(ctx.stack[ctx.sp])) + ctx.gbias;
                const sub = subrAt(ctx.gsubrs, idx) orelse return error.InvalidFont;
                const r = try exec(ctx, sub, depth + 1);
                if (r == .ended) return .ended;
            },
            11 => { // return
                if (depth == 0) return error.InvalidFont; // top-level return is invalid
                return .returned;
            },
            14 => { // endchar (CFF1). Unused in CFF2, but terminate if seen.
                if (!ctx.cff2) {
                    ctx.maybeWidth(false);
                    if (ctx.sp == 4) return error.Unsupported; // seac
                    if (ctx.sp != 0) return error.InvalidFont;
                }
                return .ended;
            },
            15 => { // CFF2 vsindex
                if (!ctx.cff2) return error.Unsupported;
                if (ctx.sp < 1) return error.InvalidFont;
                ctx.sp -= 1;
                const idx_f = ctx.stack[ctx.sp];
                if (!std.math.isFinite(idx_f) or idx_f < 0 or idx_f > 65535) return error.InvalidFont;
                const bs = ctx.blend orelse return error.InvalidFont;
                bs.setVsindex(@intFromFloat(idx_f));
            },
            16 => { // CFF2 blend
                if (!ctx.cff2) return error.Unsupported;
                try doBlend(ctx);
            },
            12 => { // escape (2-byte op)
                if (i >= code.len) return error.InvalidFont;
                const b1 = code[i];
                i += 1;
                switch (b1) {
                    34 => try hflex(ctx),
                    35 => try flex(ctx),
                    36 => try hflex1(ctx),
                    37 => try flex1(ctx),
                    else => return error.Unsupported, // arithmetic/logical/storage etc.
                }
                ctx.clear();
            },
            else => return error.Unsupported,
        }
    }
    return .normal;
}

/// CFF2 blend: stack = [ … def0..defN-1, deltas(n*k), n ]
/// result_i = def_i + sum_j(delta[i*k+j] * scalar[j])
fn doBlend(ctx: *Ctx) Error!void {
    const bs = ctx.blend orelse return error.InvalidFont;
    try bs.ensureScalars(ctx.norm);
    const k: usize = bs.n_regions;
    if (ctx.sp < 1) return error.InvalidFont;
    const n_f = ctx.stack[ctx.sp - 1];
    if (!std.math.isFinite(n_f) or n_f < 1 or n_f != @floor(n_f)) return error.InvalidFont;
    const n: usize = @intFromFloat(n_f);
    // need n defaults + n*k deltas + 1 (n)
    const need = n + n * k + 1;
    if (ctx.sp < need) return error.InvalidFont;
    const base = ctx.sp - need;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var v = ctx.stack[base + i];
        var j: usize = 0;
        while (j < k) : (j += 1) {
            const d = ctx.stack[base + n + i * k + j];
            v += d * @as(f64, bs.scalars[j]);
        }
        ctx.stack[base + i] = v;
    }
    ctx.sp = base + n;
}

fn addStems(ctx: *Ctx) void {
    ctx.n_stems += @intCast(ctx.sp / 2);
    if (ctx.n_stems > max_stems) ctx.n_stems = max_stems; // Clamp upper bound (mask byte count is (n+7)/8)
}

fn subrAt(idx_set: Index, idx: i64) ?[]const u8 {
    if (idx < 0) return null;
    return idx_set.get(@intCast(idx));
}

fn altLineto(ctx: *Ctx, start_horizontal: bool) Error!void {
    var horiz = start_horizontal;
    var j: usize = 0;
    while (j < ctx.sp) : (j += 1) {
        if (horiz) try ctx.lineTo(ctx.stack[j], 0) else try ctx.lineTo(0, ctx.stack[j]);
        horiz = !horiz;
    }
}

fn altCurveto(ctx: *Ctx, start_horizontal: bool) Error!void {
    var horiz = start_horizontal;
    var j: usize = 0;
    while (ctx.sp - j >= 4) {
        const rem = ctx.sp - j;
        const extra: f64 = if (rem == 5) ctx.stack[j + 4] else 0;
        if (horiz) {
            // H-leading: c1=(dx,0) c2=(dxb,dyb) end=(extra, dyc)
            try ctx.curveTo(ctx.stack[j], 0, ctx.stack[j + 1], ctx.stack[j + 2], extra, ctx.stack[j + 3]);
        } else {
            // V-leading: c1=(0,dy) c2=(dxb,dyb) end=(dxc, extra)
            try ctx.curveTo(0, ctx.stack[j], ctx.stack[j + 1], ctx.stack[j + 2], ctx.stack[j + 3], extra);
        }
        j += if (rem == 5) 5 else 4;
        horiz = !horiz;
    }
}

// Flex family (expand to two cubics)
fn flex(ctx: *Ctx) Error!void {
    if (ctx.sp != 13) return error.InvalidFont;
    const s = ctx.stack;
    try ctx.curveTo(s[0], s[1], s[2], s[3], s[4], s[5]);
    try ctx.curveTo(s[6], s[7], s[8], s[9], s[10], s[11]);
    // s[12] = fd (flex depth); ignored
}
fn hflex(ctx: *Ctx) Error!void {
    if (ctx.sp != 7) return error.InvalidFont;
    const s = ctx.stack;
    // 1st: (dx1,0)(dx2,dy2)(dx3,0) / 2nd: (dx4,0)(dx5,-dy2)(dx6,0)
    try ctx.curveTo(s[0], 0, s[1], s[2], s[3], 0);
    try ctx.curveTo(s[4], 0, s[5], -s[2], s[6], 0);
}
fn hflex1(ctx: *Ctx) Error!void {
    if (ctx.sp != 9) return error.InvalidFont;
    const s = ctx.stack;
    // 1st: (dx1,dy1)(dx2,dy2)(dx3,0) / 2nd: (dx4,0)(dx5,dy5)(dx6, -(dy1+dy2+dy5))
    try ctx.curveTo(s[0], s[1], s[2], s[3], s[4], 0);
    try ctx.curveTo(s[5], 0, s[6], s[7], s[8], -(s[1] + s[3] + s[7]));
}
fn flex1(ctx: *Ctx) Error!void {
    if (ctx.sp != 11) return error.InvalidFont;
    const s = ctx.stack;
    const dx = s[0] + s[2] + s[4] + s[6] + s[8];
    const dy = s[1] + s[3] + s[5] + s[7] + s[9];
    try ctx.curveTo(s[0], s[1], s[2], s[3], s[4], s[5]);
    if (@abs(dx) > @abs(dy)) {
        try ctx.curveTo(s[6], s[7], s[8], s[9], s[10], -dy);
    } else {
        try ctx.curveTo(s[6], s[7], s[8], s[9], -dx, s[10]);
    }
}

/// Read a Type2 / CFF2 operand (b0 is the first byte; i points just after b0).
fn readOperand(code: []const u8, i: *usize, b0: u8) Error!f64 {
    if (b0 == 28) {
        if (i.* + 2 > code.len) return error.InvalidFont;
        const v: i16 = @bitCast((@as(u16, code[i.*]) << 8) | code[i.* + 1]);
        i.* += 2;
        return @floatFromInt(v);
    }
    if (b0 == 255) {
        // Fixed 16.16 (CFF2 CharString only)
        if (i.* + 4 > code.len) return error.InvalidFont;
        const raw: i32 = @bitCast((@as(u32, code[i.*]) << 24) |
            (@as(u32, code[i.* + 1]) << 16) |
            (@as(u32, code[i.* + 2]) << 8) |
            code[i.* + 3]);
        i.* += 4;
        return @as(f64, @floatFromInt(raw)) / 65536.0;
    }
    if (b0 < 247) { // 32..246
        return @as(f64, @floatFromInt(@as(i32, b0) - 139));
    }
    if (b0 < 251) { // 247..250
        if (i.* >= code.len) return error.InvalidFont;
        const b1 = code[i.*];
        i.* += 1;
        return @floatFromInt((@as(i32, b0) - 247) * 256 + @as(i32, b1) + 108);
    }
    if (b0 < 255) { // 251..254
        if (i.* >= code.len) return error.InvalidFont;
        const b1 = code[i.*];
        i.* += 1;
        return @floatFromInt(-(@as(i32, b0) - 251) * 256 - @as(i32, b1) - 108);
    }
    // 255: 16.16 fixed-point
    if (i.* + 4 > code.len) return error.InvalidFont;
    const raw: i32 = @bitCast((@as(u32, code[i.*]) << 24) | (@as(u32, code[i.* + 1]) << 16) | (@as(u32, code[i.* + 2]) << 8) | code[i.* + 3]);
    i.* += 4;
    return @as(f64, @floatFromInt(raw)) / 65536.0;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

const empty_index = Index{ .data = &[_]u8{}, .count = 0, .off_size = 0, .offsets_start = 0, .obj_base = 0, .end = 0 };

/// Run a charstring and obtain an Outline (for tests).
fn runToOutline(a: std.mem.Allocator, code: []const u8) !outline.Outline {
    var b = outline.Builder.init(a);
    errdefer b.deinit();
    try run(&b, code, empty_index, empty_index, 0, 0);
    return b.finish();
}

// Integer operand (32..246 is b0-139). E.g. value v (|v|<=107) → byte (v+139).
fn op8(v: i32) u8 {
    return @intCast(v + 139);
}

test "charstring: triangle via rmoveto + rlineto (lines)" {
    const a = testing.allocator;
    // rmoveto 10 10 ; rlineto 40 0 ; rlineto -20 40 ; endchar
    const code = [_]u8{ op8(10), op8(10), 21, op8(40), op8(0), 5, op8(-20), op8(40), 5, 14 };
    var o = try runToOutline(a, &code);
    defer o.deinit(a);
    try testing.expectEqual(@as(usize, 1), o.contours.len);
    const c = o.contours[0];
    try testing.expectEqual(@as(f32, 10), c.start.x);
    try testing.expectEqual(@as(f32, 10), c.start.y);
    try testing.expectEqual(@as(usize, 2), c.segments.len); // 2 lineTo (closure is on the rasterizer side)
    try testing.expectEqual(@as(f32, 50), c.segments[0].line.x); // 10+40
    try testing.expectEqual(@as(f32, 30), c.segments[1].line.x); // 50-20
    try testing.expectEqual(@as(f32, 50), c.segments[1].line.y); // 10+40
}

test "charstring: rrcurveto produces a cubic" {
    const a = testing.allocator;
    // rmoveto 0 0 ; rrcurveto 10 20 10 20 10 -20 ; endchar
    const code = [_]u8{ op8(0), op8(0), 21, op8(10), op8(20), op8(10), op8(20), op8(10), op8(-20), 8, 14 };
    var o = try runToOutline(a, &code);
    defer o.deinit(a);
    const c = o.contours[0];
    try testing.expectEqual(@as(usize, 1), c.segments.len);
    try testing.expect(c.segments[0] == .cubic);
    try testing.expectEqual(@as(f32, 10), c.segments[0].cubic.c1.x);
    try testing.expectEqual(@as(f32, 20), c.segments[0].cubic.c2.x); // 10+10
    try testing.expectEqual(@as(f32, 30), c.segments[0].cubic.end.x); // 20+10
}

test "charstring: hlineto alternation (H,V,H)" {
    const a = testing.allocator;
    // rmoveto 0 0 ; hlineto 10 20 30 ; endchar  → H:+10, V:+20, H:+30
    const code = [_]u8{ op8(0), op8(0), 21, op8(10), op8(20), op8(30), 6, 14 };
    var o = try runToOutline(a, &code);
    defer o.deinit(a);
    const c = o.contours[0];
    try testing.expectEqual(@as(usize, 3), c.segments.len);
    try testing.expectEqual(@as(f32, 10), c.segments[0].line.x); // H
    try testing.expectEqual(@as(f32, 0), c.segments[0].line.y);
    try testing.expectEqual(@as(f32, 10), c.segments[1].line.x); // V (x unchanged)
    try testing.expectEqual(@as(f32, 20), c.segments[1].line.y);
    try testing.expectEqual(@as(f32, 40), c.segments[2].line.x); // H +30
}

test "charstring: vvcurveto leading dx1 (odd arg)" {
    const a = testing.allocator;
    // rmoveto 0 0 ; vvcurveto 5 10 10 10 10 (dx1=5, dya=10 dxb=10 dyb=10 dyc=10) ; endchar
    const code = [_]u8{ op8(0), op8(0), 21, op8(5), op8(10), op8(10), op8(10), op8(10), 26, 14 };
    var o = try runToOutline(a, &code);
    defer o.deinit(a);
    const c = o.contours[0];
    try testing.expect(c.segments[0] == .cubic);
    // c1 = (0+dx1, 0+dya) = (5,10)
    try testing.expectEqual(@as(f32, 5), c.segments[0].cubic.c1.x);
    try testing.expectEqual(@as(f32, 10), c.segments[0].cubic.c1.y);
}

test "charstring: callsubr / return (local subr)" {
    const a = testing.allocator;
    // local subr 0: rlineto 40 0 ; return
    const sub0 = [_]u8{ op8(40), op8(0), 5, 11 };
    // Hand-written INDEX (count=1, offSize=1, offsets=[1, 1+len], data=sub0)
    var idx_bytes: std.ArrayList(u8) = .empty;
    defer idx_bytes.deinit(a);
    try idx_bytes.append(a, 0);
    try idx_bytes.append(a, 1); // count=1
    try idx_bytes.append(a, 1); // offSize=1
    try idx_bytes.append(a, 1); // offset[0]
    try idx_bytes.append(a, @intCast(1 + sub0.len)); // offset[1]
    try idx_bytes.appendSlice(a, &sub0);
    const lsubrs = try Index.parse(idx_bytes.items, 0);

    // main: rmoveto 0 0 ; callsubr (bias 107 → index for subr 0 = -107) ; endchar
    // To call subr 0, operand = 0 - bias = -107
    const code = [_]u8{ op8(0), op8(0), 21, op8(-107), 10, 14 };

    var bld = outline.Builder.init(a);
    errdefer bld.deinit();
    try run(&bld, &code, empty_index, lsubrs, 0, 0);
    var o = try bld.finish();
    defer o.deinit(a);
    const c = o.contours[0];
    try testing.expectEqual(@as(usize, 1), c.segments.len);
    try testing.expectEqual(@as(f32, 40), c.segments[0].line.x); // rlineto inside the subr
}

test "charstring: hintmask skips (numStems+7)/8 bytes" {
    const a = testing.allocator;
    // hstem with 2 stems (4 args) → numStems=2 → mask 1 byte.
    // 100 200 100 200 hstemhm ; hintmask <1byte> ; rmoveto 0 0 ; rlineto 10 0 ; endchar
    const code = [_]u8{
        op8(100), op8(100), op8(100), op8(100), 18, // hstemhm (2 stems)
        19, 0xFF, // hintmask + 1 mask byte
        op8(0), op8(0), 21, // rmoveto
        op8(10), op8(0), 5, // rlineto
        14,
    };
    var o = try runToOutline(a, &code);
    defer o.deinit(a);
    const c = o.contours[0];
    try testing.expectEqual(@as(f32, 10), c.segments[0].line.x); // Mask byte is skipped correctly and execution reaches rlineto
}

test "charstring: wrong arity is InvalidFont (surplus args not ignored)" {
    const a = testing.allocator;
    var b = outline.Builder.init(a);
    defer b.deinit();
    // rmoveto 0 0 ; rrcurveto with 5 args (not a multiple of 6) → InvalidFont
    const bad = [_]u8{ op8(0), op8(0), 21, op8(1), op8(1), op8(1), op8(1), op8(1), 8 };
    try testing.expectError(error.InvalidFont, run(&b, &bad, empty_index, empty_index, 0, 0));

    var b2 = outline.Builder.init(a);
    defer b2.deinit();
    // hvcurveto with 6 args (not 4n / 4n+1) → InvalidFont
    const bad2 = [_]u8{ op8(0), op8(0), 21, op8(1), op8(1), op8(1), op8(1), op8(1), op8(1), 31 };
    try testing.expectError(error.InvalidFont, run(&b2, &bad2, empty_index, empty_index, 0, 0));

    var b3 = outline.Builder.init(a);
    defer b3.deinit();
    // rcurveline with 3 args (< 8) → InvalidFont without underflow
    const bad3 = [_]u8{ op8(0), op8(0), 21, op8(1), op8(1), op8(1), 24 };
    try testing.expectError(error.InvalidFont, run(&b3, &bad3, empty_index, empty_index, 0, 0));
}

test "charstring: top-level return is InvalidFont" {
    const a = testing.allocator;
    var b = outline.Builder.init(a);
    defer b.deinit();
    try testing.expectError(error.InvalidFont, run(&b, &[_]u8{11}, empty_index, empty_index, 0, 0));
}

test "charstring: unsupported 12xx (add) is Unsupported" {
    const a = testing.allocator;
    var b = outline.Builder.init(a);
    defer b.deinit();
    // 12 10 = add
    try testing.expectError(error.Unsupported, run(&b, &[_]u8{ op8(1), op8(2), 12, 10 }, empty_index, empty_index, 0, 0));
}

test "charstring: 28(int16) and 255(16.16) operands" {
    const a = testing.allocator;
    // rmoveto (28 0x01 0x00 = 256) (28 0x00 0x0A = 10) ; endchar
    const code = [_]u8{ 28, 0x01, 0x00, 28, 0x00, 0x0A, 21, 14 };
    var o = try runToOutline(a, &code);
    defer o.deinit(a);
    // Degenerate contour (move only) is dropped so contour count is 0. start cannot be checked, but must not trap.
    try testing.expectEqual(@as(usize, 0), o.contours.len);
}

test "Index: parse and get" {
    const a = testing.allocator;
    _ = a;
    // count=2, offSize=1, offsets=[1,3,5], data="AB","CD"
    const bytes = [_]u8{ 0, 2, 1, 1, 3, 5, 'A', 'B', 'C', 'D' };
    const idx = try Index.parse(&bytes, 0);
    try testing.expectEqual(@as(u32, 2), idx.count);
    try testing.expectEqualStrings("AB", idx.get(0).?);
    try testing.expectEqualStrings("CD", idx.get(1).?);
    try testing.expectEqual(@as(?[]const u8, null), idx.get(2));
    try testing.expectEqual(@as(usize, 10), idx.end);
}

test "Index: offset[0]!=1 is InvalidFont" {
    const bytes = [_]u8{ 0, 1, 1, 0, 2, 'A' }; // offset[0]=0
    try testing.expectError(error.InvalidFont, Index.parse(&bytes, 0));
}
