// CFF INDEX 構造 + Type2 charstring インタプリタ。
//
// CFF コンテナ(cff.zig)が各 INDEX のパースと subr の供給に Index を使い、glyph 描画で run() を
// 呼ぶ（cff → charstring の一方向依存）。run() は charstring を解釈し outline.Builder へ
// moveTo/lineTo/cubicTo を発行する（Type2 は 3 次 Bezier）。
//
// 制限（受け入れ済み）: arithmetic/logical/storage/conditional の 12xx は非対応(Unsupported)。
// flex 系(12 34-37)は対応。seac / Type1 charstring は非対応。width は消費のみ(advance は hmtx 優先)。

const std = @import("std");
const Reader = @import("byte_reader.zig").Reader;
const outline = @import("outline.zig");

pub const Error = error{ InvalidFont, Unsupported, OutOfMemory };

const max_stack = 48;
const max_depth = 10;
const max_stems = 96;
const max_steps = 1 << 20; // 暴走防止（総オペレータ実行数）

/// CFF INDEX（Name / Top DICT / String / Subr / CharStrings 共通）。
/// count(u16) offSize(u8) offset[count+1](1-based) object-data。
pub const Index = struct {
    data: []const u8,
    count: u32,
    off_size: u8,
    offsets_start: usize, // offset 配列の先頭
    obj_base: usize, // offset 値 v → byte (obj_base + v)。すなわち data-1。
    end: usize, // INDEX の末尾（次の構造の開始）

    /// data[off..] の INDEX をパースし検証する。
    pub fn parse(data: []const u8, off: usize) Error!Index {
        const r = Reader{ .data = data };
        const count: u32 = try r.u16At(off);
        if (count == 0) {
            return .{ .data = data, .count = 0, .off_size = 0, .offsets_start = off + 2, .obj_base = off + 2, .end = off + 2 };
        }
        const off_size = try r.u8At(off + 2);
        if (off_size < 1 or off_size > 4) return error.InvalidFont;
        const offsets_start = off + 3;
        const n_off = count + 1;
        try r.require(offsets_start, n_off * @as(usize, off_size));
        const obj_base = offsets_start + n_off * @as(usize, off_size) - 1;

        // offset[0]==1、単調非減少、末尾が data 内を検証
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
        const last = prev; // offset[count]
        try r.require(obj_base, last); // obj_base + last <= data.len
        return .{ .data = data, .count = count, .off_size = off_size, .offsets_start = offsets_start, .obj_base = obj_base, .end = obj_base + last };
    }

    /// entry i のバイト列。範囲外は null。
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

/// subr bias（count に依存）。
pub fn subrBias(count: u32) i32 {
    if (count < 1240) return 107;
    if (count < 33900) return 1131;
    return 32768;
}

const Result = enum { normal, returned, ended };

const Ctx = struct {
    b: *outline.Builder,
    gsubrs: Index,
    gbias: i32,
    lsubrs: Index,
    lbias: i32,
    nominal_width: f64,
    default_width: f64,

    stack: [max_stack]f64 = undefined,
    sp: usize = 0,
    x: f64 = 0,
    y: f64 = 0,
    n_stems: u32 = 0,
    width_parsed: bool = false,
    open: bool = false,
    steps: u32 = 0,

    fn push(self: *Ctx, v: f64) Error!void {
        if (self.sp >= max_stack) return error.InvalidFont;
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
    /// 絶対制御点でなく現在点からの差分 3 組で cubic を引く。
    fn curveTo(self: *Ctx, dx1: f64, dy1: f64, dx2: f64, dy2: f64, dx3: f64, dy3: f64) Error!void {
        const c1x = self.x + dx1;
        const c1y = self.y + dy1;
        const c2x = c1x + dx2;
        const c2y = c1y + dy2;
        self.x = c2x + dx3;
        self.y = c2y + dy3;
        try self.b.cubicTo(.{ .x = @floatCast(c1x), .y = @floatCast(c1y) }, .{ .x = @floatCast(c2x), .y = @floatCast(c2y) }, self.pt());
    }

    /// 最初の stack-clearing オペレータで width を消費する（advance は hmtx 優先なので値は捨てる）。
    /// even_args=true: 引数が偶数想定（rmoveto 等）/ false: 奇数想定（hmoveto/vmoveto/endchar 等は別途）。
    /// 引数個数 expected を渡し、sp が expected+1 なら先頭を width として除去。
    fn maybeWidth(self: *Ctx, expected_parity_odd: bool) void {
        if (self.width_parsed) return;
        self.width_parsed = true;
        const odd = (self.sp % 2) == 1;
        // expected_parity_odd: 引数本来が奇数個か（hmoveto/vmoveto=1, endchar=0, stem=偶数）。
        // 「実引数が想定より 1 多い（先頭が width）」を parity で検出する。
        if (odd != expected_parity_odd) {
            // 先頭を width として落とす
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

/// charstring を実行し Builder へパスを発行する。
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

        if (b0 >= 32 or b0 == 28) {
            // operand（数値）
            const v = try readOperand(code, &i, b0);
            try ctx.push(v);
            continue;
        }

        switch (b0) {
            1, 3, 18, 23 => { // hstem/vstem/hstemhm/vstemhm
                ctx.maybeWidth(false); // stem は偶数引数（2*stem）
                addStems(ctx);
                ctx.clear();
            },
            19, 20 => { // hintmask / cntrmask
                ctx.maybeWidth(false);
                addStems(ctx); // mask 直前に残った引数は暗黙 vstemhm
                ctx.clear();
                const nbytes = (ctx.n_stems + 7) / 8;
                if (i + nbytes > code.len) return error.InvalidFont;
                i += nbytes; // mask byte を読み飛ばす
            },
            21 => { // rmoveto
                ctx.maybeWidth(false); // dx dy = 2 引数（偶数）
                if (ctx.sp != 2) return error.InvalidFont;
                try ctx.moveTo(ctx.stack[0], ctx.stack[1]);
                ctx.clear();
            },
            22 => { // hmoveto
                ctx.maybeWidth(true); // dx = 1 引数（奇数）
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
            6 => { // hlineto（H 始まり交互）
                if (ctx.sp == 0) return error.InvalidFont;
                try altLineto(ctx, true);
                ctx.clear();
            },
            7 => { // vlineto（V 始まり交互）
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
            30 => { // vhcurveto（V 始まり交互）
                if (ctx.sp < 4 or ctx.sp % 4 > 1) return error.InvalidFont;
                try altCurveto(ctx, false);
                ctx.clear();
            },
            31 => { // hvcurveto（H 始まり交互）
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
                if (depth == 0) return error.InvalidFont; // top-level return は不正
                return .returned;
            },
            14 => { // endchar
                ctx.maybeWidth(false);
                // seac 風(width 消費後に 4 引数)は非対応。余剰引数は黙殺せず弾く。
                if (ctx.sp == 4) return error.Unsupported; // seac
                if (ctx.sp != 0) return error.InvalidFont;
                return .ended;
            },
            12 => { // escape（2 byte op）
                if (i >= code.len) return error.InvalidFont;
                const b1 = code[i];
                i += 1;
                switch (b1) {
                    34 => try hflex(ctx),
                    35 => try flex(ctx),
                    36 => try hflex1(ctx),
                    37 => try flex1(ctx),
                    else => return error.Unsupported, // arithmetic/logical/storage 等
                }
                ctx.clear();
            },
            else => return error.Unsupported,
        }
    }
    return .normal;
}

fn addStems(ctx: *Ctx) void {
    ctx.n_stems += @intCast(ctx.sp / 2);
    if (ctx.n_stems > max_stems) ctx.n_stems = max_stems; // 上限クランプ（mask byte 数は (n+7)/8）
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
            // H 始まり: c1=(dx,0) c2=(dxb,dyb) end=(extra, dyc)
            try ctx.curveTo(ctx.stack[j], 0, ctx.stack[j + 1], ctx.stack[j + 2], extra, ctx.stack[j + 3]);
        } else {
            // V 始まり: c1=(0,dy) c2=(dxb,dyb) end=(dxc, extra)
            try ctx.curveTo(0, ctx.stack[j], ctx.stack[j + 1], ctx.stack[j + 2], ctx.stack[j + 3], extra);
        }
        j += if (rem == 5) 5 else 4;
        horiz = !horiz;
    }
}

// flex 系（cubic 2 本に展開）
fn flex(ctx: *Ctx) Error!void {
    if (ctx.sp != 13) return error.InvalidFont;
    const s = ctx.stack;
    try ctx.curveTo(s[0], s[1], s[2], s[3], s[4], s[5]);
    try ctx.curveTo(s[6], s[7], s[8], s[9], s[10], s[11]);
    // s[12] = fd（flex depth）無視
}
fn hflex(ctx: *Ctx) Error!void {
    if (ctx.sp != 7) return error.InvalidFont;
    const s = ctx.stack;
    // 第1: (dx1,0)(dx2,dy2)(dx3,0) / 第2: (dx4,0)(dx5,-dy2)(dx6,0)
    try ctx.curveTo(s[0], 0, s[1], s[2], s[3], 0);
    try ctx.curveTo(s[4], 0, s[5], -s[2], s[6], 0);
}
fn hflex1(ctx: *Ctx) Error!void {
    if (ctx.sp != 9) return error.InvalidFont;
    const s = ctx.stack;
    // 第1: (dx1,dy1)(dx2,dy2)(dx3,0) / 第2: (dx4,0)(dx5,dy5)(dx6, -(dy1+dy2+dy5))
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

/// Type2 operand を読む（b0 は先頭バイト、i は b0 の次を指す）。
fn readOperand(code: []const u8, i: *usize, b0: u8) Error!f64 {
    if (b0 == 28) {
        if (i.* + 2 > code.len) return error.InvalidFont;
        const v: i16 = @bitCast((@as(u16, code[i.*]) << 8) | code[i.* + 1]);
        i.* += 2;
        return @floatFromInt(v);
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
    // 255: 16.16 固定小数
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

/// charstring を実行して Outline を得る（テスト用）。
fn runToOutline(a: std.mem.Allocator, code: []const u8) !outline.Outline {
    var b = outline.Builder.init(a);
    errdefer b.deinit();
    try run(&b, code, empty_index, empty_index, 0, 0);
    return b.finish();
}

// 整数 operand（32..246 は b0-139）。例: 値 v (|v|<=107) → byte (v+139)。
fn op8(v: i32) u8 {
    return @intCast(v + 139);
}

test "charstring: rmoveto + rlineto で三角形（直線）" {
    const a = testing.allocator;
    // rmoveto 10 10 ; rlineto 40 0 ; rlineto -20 40 ; endchar
    const code = [_]u8{ op8(10), op8(10), 21, op8(40), op8(0), 5, op8(-20), op8(40), 5, 14 };
    var o = try runToOutline(a, &code);
    defer o.deinit(a);
    try testing.expectEqual(@as(usize, 1), o.contours.len);
    const c = o.contours[0];
    try testing.expectEqual(@as(f32, 10), c.start.x);
    try testing.expectEqual(@as(f32, 10), c.start.y);
    try testing.expectEqual(@as(usize, 2), c.segments.len); // 2 lineTo（閉路は rasterizer 側）
    try testing.expectEqual(@as(f32, 50), c.segments[0].line.x); // 10+40
    try testing.expectEqual(@as(f32, 30), c.segments[1].line.x); // 50-20
    try testing.expectEqual(@as(f32, 50), c.segments[1].line.y); // 10+40
}

test "charstring: rrcurveto は cubic を生成" {
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

test "charstring: hlineto の交互（H,V,H）" {
    const a = testing.allocator;
    // rmoveto 0 0 ; hlineto 10 20 30 ; endchar  → H:+10, V:+20, H:+30
    const code = [_]u8{ op8(0), op8(0), 21, op8(10), op8(20), op8(30), 6, 14 };
    var o = try runToOutline(a, &code);
    defer o.deinit(a);
    const c = o.contours[0];
    try testing.expectEqual(@as(usize, 3), c.segments.len);
    try testing.expectEqual(@as(f32, 10), c.segments[0].line.x); // H
    try testing.expectEqual(@as(f32, 0), c.segments[0].line.y);
    try testing.expectEqual(@as(f32, 10), c.segments[1].line.x); // V（x 不変）
    try testing.expectEqual(@as(f32, 20), c.segments[1].line.y);
    try testing.expectEqual(@as(f32, 40), c.segments[2].line.x); // H +30
}

test "charstring: vvcurveto の先頭 dx1（odd arg）" {
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

test "charstring: callsubr / return（local subr）" {
    const a = testing.allocator;
    // local subr 0: rlineto 40 0 ; return
    const sub0 = [_]u8{ op8(40), op8(0), 5, 11 };
    // INDEX を手書き（count=1, offSize=1, offsets=[1, 1+len], data=sub0）
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
    // subr 0 を呼ぶには operand = 0 - bias = -107
    const code = [_]u8{ op8(0), op8(0), 21, op8(-107), 10, 14 };

    var bld = outline.Builder.init(a);
    errdefer bld.deinit();
    try run(&bld, &code, empty_index, lsubrs, 0, 0);
    var o = try bld.finish();
    defer o.deinit(a);
    const c = o.contours[0];
    try testing.expectEqual(@as(usize, 1), c.segments.len);
    try testing.expectEqual(@as(f32, 40), c.segments[0].line.x); // subr 内の rlineto
}

test "charstring: hintmask は (numStems+7)/8 byte を読み飛ばす" {
    const a = testing.allocator;
    // hstem で 2 stem（4 引数）→ numStems=2 → mask 1 byte。
    // 100 200 100 200 hstemhm ; hintmask <1byte> ; rmoveto 0 0 ; rlineto 10 0 ; endchar
    const code = [_]u8{
        op8(100), op8(100), op8(100), op8(100), 18, // hstemhm (2 stems)
        19, 0xFF, // hintmask + 1 mask byte
        op8(0),  op8(0),   21, // rmoveto
        op8(10), op8(0),   5, // rlineto
        14,
    };
    var o = try runToOutline(a, &code);
    defer o.deinit(a);
    const c = o.contours[0];
    try testing.expectEqual(@as(f32, 10), c.segments[0].line.x); // mask byte が正しく skip され rlineto に到達
}

test "charstring: 不正引数個数は InvalidFont（余剰引数を黙殺しない）" {
    const a = testing.allocator;
    var b = outline.Builder.init(a);
    defer b.deinit();
    // rmoveto 0 0 ; rrcurveto に 5 引数（6 の倍数でない）→ InvalidFont
    const bad = [_]u8{ op8(0), op8(0), 21, op8(1), op8(1), op8(1), op8(1), op8(1), 8 };
    try testing.expectError(error.InvalidFont, run(&b, &bad, empty_index, empty_index, 0, 0));

    var b2 = outline.Builder.init(a);
    defer b2.deinit();
    // hvcurveto に 6 引数（4n / 4n+1 でない）→ InvalidFont
    const bad2 = [_]u8{ op8(0), op8(0), 21, op8(1), op8(1), op8(1), op8(1), op8(1), op8(1), 31 };
    try testing.expectError(error.InvalidFont, run(&b2, &bad2, empty_index, empty_index, 0, 0));

    var b3 = outline.Builder.init(a);
    defer b3.deinit();
    // rcurveline に 3 引数（< 8）→ underflow せず InvalidFont
    const bad3 = [_]u8{ op8(0), op8(0), 21, op8(1), op8(1), op8(1), 24 };
    try testing.expectError(error.InvalidFont, run(&b3, &bad3, empty_index, empty_index, 0, 0));
}

test "charstring: top-level return は InvalidFont" {
    const a = testing.allocator;
    var b = outline.Builder.init(a);
    defer b.deinit();
    try testing.expectError(error.InvalidFont, run(&b, &[_]u8{11}, empty_index, empty_index, 0, 0));
}

test "charstring: 非対応 12xx（add）は Unsupported" {
    const a = testing.allocator;
    var b = outline.Builder.init(a);
    defer b.deinit();
    // 12 10 = add
    try testing.expectError(error.Unsupported, run(&b, &[_]u8{ op8(1), op8(2), 12, 10 }, empty_index, empty_index, 0, 0));
}

test "charstring: 28(int16) と 255(16.16) operand" {
    const a = testing.allocator;
    // rmoveto (28 0x01 0x00 = 256) (28 0x00 0x0A = 10) ; endchar
    const code = [_]u8{ 28, 0x01, 0x00, 28, 0x00, 0x0A, 21, 14 };
    var o = try runToOutline(a, &code);
    defer o.deinit(a);
    // 退化 contour（move のみ）は捨てられるので contour 0。start は確認できないが trap しないこと。
    try testing.expectEqual(@as(usize, 0), o.contours.len);
}

test "Index: parse と get" {
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

test "Index: offset[0]!=1 は InvalidFont" {
    const bytes = [_]u8{ 0, 1, 1, 0, 2, 'A' }; // offset[0]=0
    try testing.expectError(error.InvalidFont, Index.parse(&bytes, 0));
}
