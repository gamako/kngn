// glyf / loca parser. Normalizes TrueType glyph outlines into the shared Outline representation.
// Supports simple glyphs (flags RLE, delta coords, implicit on-curve resolution) and composite glyphs
// (args, F2Dot14 transforms, recursive expansion). Hinting instructions are skipped. Point-matching composites are
// unsupported (error.Unsupported). All reads are bounds-checked via byte_reader + table-local slices.

const std = @import("std");
const Reader = @import("byte_reader.zig").Reader;
const sfnt = @import("sfnt.zig");
const outline = @import("outline.zig");
const gvar_mod = @import("gvar.zig");

const Vec2f = outline.Vec2f;
const Outline = outline.Outline;
const Builder = outline.Builder;
const Gvar = gvar_mod.Gvar;

pub const Error = error{ InvalidFont, Unsupported, OutOfMemory };

/// Hard cap on composite recursion (guards cycles, excessive depth, and stack overflow).
const max_component_depth = 8;

// 2x2 linear transform + translation. apply(p) = (a*x + c*y + dx, b*x + d*y + dy).
const Xform = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    dx: f32 = 0,
    dy: f32 = 0,

    fn apply(self: Xform, p: Vec2f) Vec2f {
        return .{
            .x = self.a * p.x + self.c * p.y + self.dx,
            .y = self.b * p.x + self.d * p.y + self.dy,
        };
    }

    // P ∘ C (parent P, child C): composed.apply(p) = P.apply(C.apply(p))
    fn compose(p: Xform, c: Xform) Xform {
        return .{
            .a = p.a * c.a + p.c * c.b,
            .b = p.b * c.a + p.d * c.b,
            .c = p.a * c.c + p.c * c.d,
            .d = p.b * c.c + p.d * c.d,
            .dx = p.a * c.dx + p.c * c.dy + p.dx,
            .dy = p.b * c.dx + p.d * c.dy + p.dy,
        };
    }
};

fn f2dot14(v: i16) f32 {
    return @as(f32, @floatFromInt(v)) / 16384.0;
}

pub const Glyf = struct {
    glyf: []const u8,
    loca: []const u8,
    loc_long: bool,
    num_glyphs: u16,

    pub fn fromTables(glyf: []const u8, loca: []const u8, loc_long: bool, num_glyphs: u16) Error!Glyf {
        const entry: usize = if (loc_long) 4 else 2;
        if (loca.len != (@as(usize, num_glyphs) + 1) * entry) return error.InvalidFont;
        return .{ .glyf = glyf, .loca = loca, .loc_long = loc_long, .num_glyphs = num_glyphs };
    }

    pub fn init(font: *const sfnt.SfntFile) Error!Glyf {
        const glyf = (font.tableSlice("glyf") catch return error.InvalidFont) orelse return error.InvalidFont;
        const loca = (font.tableSlice("loca") catch return error.InvalidFont) orelse return error.InvalidFont;
        return fromTables(glyf, loca, font.index_to_loc_format == 1, font.num_glyphs);
    }

    fn locaAt(self: *const Glyf, i: usize) Error!usize {
        const r = Reader{ .data = self.loca };
        if (self.loc_long) {
            return try r.u32At(i * 4);
        } else {
            return @as(usize, try r.u16At(i * 2)) * 2;
        }
    }

    /// Glyph data for gid (table-local slice). Empty glyphs return null.
    fn glyphData(self: *const Glyf, gid: u16) Error!?[]const u8 {
        if (gid >= self.num_glyphs) return error.InvalidFont;
        const off0 = try self.locaAt(gid);
        const off1 = try self.locaAt(@as(usize, gid) + 1);
        if (off0 > off1 or off1 > self.glyf.len) return error.InvalidFont;
        if (off0 == off1) return null;
        return self.glyf[off0..off1];
    }

    /// Contours for gid as Outline (font units). Empty glyphs yield empty contours.
    /// Default outline without variation (gvar not applied). Backward compatible.
    pub fn outline(self: *const Glyf, alloc: std.mem.Allocator, gid: u16) Error!Outline {
        return self.outlineVaried(alloc, gid, null, &.{});
    }

    /// Variation-aware outline. Bit-identical to the default outline when gvar is null or norm is empty/all zeros.
    /// For composites, only offset varies (virtual points at component indices); scale/2x2 stay fixed.
    pub fn outlineVaried(
        self: *const Glyf,
        alloc: std.mem.Allocator,
        gid: u16,
        gvar: ?*const Gvar,
        norm: []const f32,
    ) Error!Outline {
        var b = Builder.init(alloc);
        errdefer b.deinit();
        try self.appendGlyph(gid, &b, .{}, 0, gvar, norm);
        return try b.finish();
    }

    /// For phantom path: returns simple point count, coords, and endPts (null for composite/empty).
    /// Caller frees pts/end_pts.
    pub fn parseSimpleGeometry(
        self: *const Glyf,
        alloc: std.mem.Allocator,
        gid: u16,
    ) Error!?struct { pts: []Vec2f, end_pts: []u16 } {
        const data = (try self.glyphData(gid)) orelse return null;
        const r = Reader{ .data = data };
        const num_contours_i = try r.i16At(0);
        if (num_contours_i < 0) return null; // composite
        const num_contours: u16 = @intCast(num_contours_i);
        var parsed = try parseSimplePoints(alloc, data, num_contours);
        alloc.free(parsed.flags);
        parsed.flags = &.{};
        if (parsed.pts.len == 0) {
            alloc.free(parsed.pts);
            alloc.free(parsed.end_pts);
            return null;
        }
        // flags are unused. Drop on-curve from pts; return Vec2f only
        const coords = try alloc.alloc(Vec2f, parsed.pts.len);
        errdefer alloc.free(coords);
        for (parsed.pts, 0..) |pt, i| coords[i] = pt.p;
        alloc.free(parsed.pts);
        return .{ .pts = coords, .end_pts = parsed.end_pts };
    }

    /// Composite structure info (for metrics / phantom). null for simple or empty.
    /// Point matching (non-XY) is Unsupported.
    pub const CompositeInfo = struct {
        component_count: u16,
        /// GID of the last USE_MY_METRICS component encountered, or null if none.
        use_my_metrics_gid: ?u16,
    };

    pub fn parseCompositeInfo(self: *const Glyf, gid: u16) Error!?CompositeInfo {
        const data = (try self.glyphData(gid)) orelse return null;
        const r = Reader{ .data = data };
        const num_contours = try r.i16At(0);
        if (num_contours >= 0) return null; // simple
        var p: usize = 10;
        var count: u16 = 0;
        var use_my: ?u16 = null;
        var first = true;
        while (true) {
            const flags = try r.u16At(p);
            p += 2;
            const comp_gid = try r.u16At(p);
            p += 2;
            const arg_words = flags & 0x0001 != 0;
            const args_xy = flags & 0x0002 != 0;
            if (first and !args_xy) return error.Unsupported;
            first = false;
            if (!args_xy) return error.Unsupported;
            if (arg_words) {
                p += 4;
            } else {
                p += 2;
            }
            if (flags & 0x0008 != 0) {
                p += 2; // WE_HAVE_A_SCALE
            } else if (flags & 0x0040 != 0) {
                p += 4; // X_AND_Y_SCALE
            } else if (flags & 0x0080 != 0) {
                p += 8; // TWO_BY_TWO
            }
            if (flags & 0x0200 != 0) use_my = comp_gid; // USE_MY_METRICS (last wins)
            count += 1;
            if (flags & 0x0020 == 0) break; // no MORE_COMPONENTS
        }
        return .{ .component_count = count, .use_my_metrics_gid = use_my };
    }

    fn appendGlyph(
        self: *const Glyf,
        gid: u16,
        b: *Builder,
        xform: Xform,
        depth: u32,
        gvar: ?*const Gvar,
        norm: []const f32,
    ) Error!void {
        if (depth > max_component_depth) return error.InvalidFont;
        const data = (try self.glyphData(gid)) orelse return; // empty glyph
        const r = Reader{ .data = data };
        const num_contours = try r.i16At(0);
        if (num_contours >= 0) {
            try appendSimple(alloc_of(b), data, @intCast(num_contours), b, xform, gvar, gid, norm);
        } else {
            try self.appendComposite(gid, data, b, xform, depth, gvar, norm);
        }
    }

    /// Composite component entry (raw values before gvar offset deltas).
    const CompEntry = struct {
        flags: u16,
        gid: u16,
        dx: f32,
        dy: f32,
        a: f32 = 1,
        b: f32 = 0,
        c: f32 = 0,
        d: f32 = 1,
    };

    fn appendComposite(
        self: *const Glyf,
        composite_gid: u16,
        data: []const u8,
        b: *Builder,
        parent: Xform,
        depth: u32,
        gvar: ?*const Gvar,
        norm: []const f32,
    ) Error!void {
        const alloc = alloc_of(b);
        const r = Reader{ .data = data };
        try r.require(0, 10);

        // 1st pass: parse all components (gvar needs component_count)
        var comps: std.ArrayList(CompEntry) = .empty;
        defer comps.deinit(alloc);
        var p: usize = 10;
        var first = true;
        var last_flags: u16 = 0;
        while (true) {
            const flags = try r.u16At(p);
            p += 2;
            last_flags = flags;
            const gid = try r.u16At(p);
            p += 2;
            const arg_words = flags & 0x0001 != 0;
            const args_xy = flags & 0x0002 != 0;
            if (first and !args_xy) return error.Unsupported;
            first = false;
            if (!args_xy) return error.Unsupported;

            var dx: f32 = 0;
            var dy: f32 = 0;
            if (arg_words) {
                dx = @floatFromInt(try r.i16At(p));
                p += 2;
                dy = @floatFromInt(try r.i16At(p));
                p += 2;
            } else {
                dx = @floatFromInt(@as(i8, @bitCast(try r.u8At(p))));
                p += 1;
                dy = @floatFromInt(@as(i8, @bitCast(try r.u8At(p))));
                p += 1;
            }

            var entry = CompEntry{ .flags = flags, .gid = gid, .dx = dx, .dy = dy };
            if (flags & 0x0008 != 0) {
                const s = f2dot14(try r.i16At(p));
                p += 2;
                entry.a = s;
                entry.d = s;
            } else if (flags & 0x0040 != 0) {
                entry.a = f2dot14(try r.i16At(p));
                p += 2;
                entry.d = f2dot14(try r.i16At(p));
                p += 2;
            } else if (flags & 0x0080 != 0) {
                entry.a = f2dot14(try r.i16At(p));
                p += 2;
                entry.b = f2dot14(try r.i16At(p));
                p += 2;
                entry.c = f2dot14(try r.i16At(p));
                p += 2;
                entry.d = f2dot14(try r.i16At(p));
                p += 2;
            }
            try comps.append(alloc, entry);
            if (flags & 0x0020 == 0) break;
        }
        if (last_flags & 0x0100 != 0) {
            const instr_len = try r.u16At(p);
            p += 2;
            try r.require(p + instr_len, 0);
        }

        const n_comp = comps.items.len;
        // gvar: virtual points at component indices. Add offsets only. No IUP.
        var deltas: ?[]Vec2f = null;
        defer if (deltas) |d| alloc.free(d);
        if (gvar) |gv| {
            if (norm.len >= gv.axis_count and gv.axis_count > 0 and n_comp > 0) {
                const d = try alloc.alloc(Vec2f, n_comp + 4);
                errdefer alloc.free(d);
                try gv.applyComposite(alloc, composite_gid, n_comp, norm, d);
                deltas = d;
            }
        }

        // 2nd pass: after deltas, offset scaling then recurse
        for (comps.items, 0..) |entry, i| {
            var dx = entry.dx;
            var dy = entry.dy;
            // Only ARGS_ARE_XY_VALUES reaches here. Add gvar deltas to offset (scale/2x2 unchanged).
            if (deltas) |d| {
                dx += d[i].x;
                dy += d[i].y;
            }
            var comp = Xform{ .a = entry.a, .b = entry.b, .c = entry.c, .d = entry.d, .dx = dx, .dy = dy };
            // Offset scaling: apply existing SCALED_COMPONENT_OFFSET rules to the post-delta offset.
            if (entry.flags & 0x0800 != 0 and entry.flags & 0x1000 == 0) {
                const odx = comp.a * dx + comp.c * dy;
                const ody = comp.b * dx + comp.d * dy;
                comp.dx = odx;
                comp.dy = ody;
            }
            try self.appendGlyph(entry.gid, b, parent.compose(comp), depth + 1, gvar, norm);
        }
    }
};

fn alloc_of(b: *Builder) std.mem.Allocator {
    return b.alloc;
}

// ── simple glyphs ─────────────────────────────────────────

const Pt = struct { p: Vec2f, on: bool };

const ParsedSimple = struct {
    pts: []Pt,
    end_pts: []u16,
    flags: []u8,
};

/// Reconstruct simple point stream (flags RLE + x/y deltas). Caller frees all slices.
fn parseSimplePoints(alloc: std.mem.Allocator, data: []const u8, num_contours: u16) Error!ParsedSimple {
    const r = Reader{ .data = data };
    try r.require(0, 10);

    const end_pts_off = 10;
    var prev: i32 = -1;
    var ci: usize = 0;
    while (ci < num_contours) : (ci += 1) {
        const e = try r.u16At(end_pts_off + 2 * ci);
        if (@as(i32, e) <= prev) return error.InvalidFont;
        prev = e;
    }
    const num_points: usize = if (num_contours == 0) 0 else @as(usize, @intCast(prev)) + 1;

    const instr_len_off = end_pts_off + 2 * @as(usize, num_contours);
    const instr_len = try r.u16At(instr_len_off);
    var pos: usize = instr_len_off + 2 + instr_len;
    try r.require(pos, 0);

    const end_pts = try alloc.alloc(u16, num_contours);
    errdefer alloc.free(end_pts);
    ci = 0;
    while (ci < num_contours) : (ci += 1) {
        end_pts[ci] = try r.u16At(end_pts_off + 2 * ci);
    }

    if (num_points == 0) {
        return .{ .pts = try alloc.alloc(Pt, 0), .end_pts = end_pts, .flags = try alloc.alloc(u8, 0) };
    }

    const flags = try alloc.alloc(u8, num_points);
    errdefer alloc.free(flags);
    {
        var i: usize = 0;
        while (i < num_points) {
            const f = try r.u8At(pos);
            pos += 1;
            flags[i] = f;
            i += 1;
            if (f & 0x08 != 0) {
                const rep = try r.u8At(pos);
                pos += 1;
                if (rep > num_points - i) return error.InvalidFont;
                var k: usize = 0;
                while (k < rep) : (k += 1) {
                    flags[i] = f;
                    i += 1;
                }
            }
        }
    }

    const pts = try alloc.alloc(Pt, num_points);
    errdefer alloc.free(pts);
    {
        var x: i32 = 0;
        var i: usize = 0;
        while (i < num_points) : (i += 1) {
            const f = flags[i];
            if (f & 0x02 != 0) {
                const d = try r.u8At(pos);
                pos += 1;
                x += if (f & 0x10 != 0) @as(i32, d) else -@as(i32, d);
            } else if (f & 0x10 == 0) {
                x += try r.i16At(pos);
                pos += 2;
            }
            pts[i].p.x = @floatFromInt(x);
        }
    }
    {
        var y: i32 = 0;
        var i: usize = 0;
        while (i < num_points) : (i += 1) {
            const f = flags[i];
            if (f & 0x04 != 0) {
                const d = try r.u8At(pos);
                pos += 1;
                y += if (f & 0x20 != 0) @as(i32, d) else -@as(i32, d);
            } else if (f & 0x20 == 0) {
                y += try r.i16At(pos);
                pos += 2;
            }
            pts[i].p.y = @floatFromInt(y);
            pts[i].on = flags[i] & 0x01 != 0;
        }
    }
    return .{ .pts = pts, .end_pts = end_pts, .flags = flags };
}

fn appendSimple(
    alloc: std.mem.Allocator,
    data: []const u8,
    num_contours: u16,
    b: *Builder,
    xform: Xform,
    gvar: ?*const Gvar,
    gid: u16,
    norm: []const f32,
) Error!void {
    var parsed = try parseSimplePoints(alloc, data, num_contours);
    defer {
        alloc.free(parsed.pts);
        alloc.free(parsed.end_pts);
        alloc.free(parsed.flags);
    }
    if (parsed.pts.len == 0) return;

    // Apply gvar (font-unit point space, before buildContour)
    if (gvar) |gv| {
        if (norm.len >= gv.axis_count and gv.axis_count > 0) {
            const n = parsed.pts.len;
            const deltas = try alloc.alloc(Vec2f, n + 4);
            defer alloc.free(deltas);
            const coords = try alloc.alloc(Vec2f, n);
            defer alloc.free(coords);
            for (parsed.pts, 0..) |pt, i| coords[i] = pt.p;
            try gv.applySimple(alloc, gid, coords, parsed.end_pts, norm, deltas);
            for (parsed.pts, 0..) |*pt, i| {
                pt.p.x += deltas[i].x;
                pt.p.y += deltas[i].y;
            }
        }
    }

    var start_idx: usize = 0;
    var ci: usize = 0;
    while (ci < num_contours) : (ci += 1) {
        const end_idx = parsed.end_pts[ci];
        const seg = parsed.pts[start_idx .. @as(usize, end_idx) + 1];
        start_idx = @as(usize, end_idx) + 1;
        try buildContour(b, seg, xform);
    }
}

fn mid(a: Vec2f, b: Vec2f) Vec2f {
    return .{ .x = (a.x + b.x) * 0.5, .y = (a.y + b.y) * 0.5 };
}

/// One contour (cyclic point sequence) with implicit on-curve resolution into Builder; xform applied at emit.
fn buildContour(b: *Builder, pts: []const Pt, xform: Xform) Error!void {
    const n = pts.len;
    if (n < 2) return; // Drop degenerate 0/1-point contours (not a real outline)

    // Choose the starting on-curve point and processing order.
    var start: Vec2f = undefined;
    var seq_first: usize = 0; // Start index in pts after start (cyclic)
    if (pts[0].on) {
        start = pts[0].p;
        seq_first = 1;
    } else if (pts[n - 1].on) {
        start = pts[n - 1].p;
        seq_first = 0; // Process pts[0]..pts[n-2] (pts[n-1] is start)
    } else {
        start = mid(pts[0].p, pts[n - 1].p); // Synthesized start point
        seq_first = 0;
    }

    try b.moveTo(xform.apply(start));

    var pending: ?Vec2f = null; // Pending off-curve control point (pre-xform)
    // Walk the cyclic point sequence. When pts[0].on, seq_first=1 so process pts[1..n-1] then close at end.
    // Otherwise process pts[0..n-1] (when pts[n-1] is on it is start, so exclude it:
    // if n-1 is on then start=pts[n-1] and the range is pts[0..n-2]).
    const count: usize = if (pts[0].on) n - 1 else if (pts[n - 1].on) n - 1 else n;
    var k: usize = 0;
    while (k < count) : (k += 1) {
        const idx = (seq_first + k) % n;
        const q = pts[idx];
        if (q.on) {
            if (pending) |c| {
                try b.quadTo(xform.apply(c), xform.apply(q.p));
                pending = null;
            } else {
                try b.lineTo(xform.apply(q.p));
            }
        } else {
            if (pending) |c| {
                const m = mid(c, q.p);
                try b.quadTo(xform.apply(c), xform.apply(m));
                pending = q.p;
            } else {
                pending = q.p;
            }
        }
    }
    // Close back to start
    if (pending) |c| {
        try b.quadTo(xform.apply(c), xform.apply(start));
    } else {
        try b.lineTo(xform.apply(start));
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn putU16(buf: []u8, off: usize, v: u16) void {
    buf[off] = @intCast(v >> 8);
    buf[off + 1] = @truncate(v);
}

/// Build a simple glyph with all 2-byte deltas and explicit flags. contours is the point list per contour.
fn buildSimpleGlyph(alloc: std.mem.Allocator, contours: []const []const Pt) ![]u8 {
    var num_points: usize = 0;
    for (contours) |c| num_points += c.len;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    // header
    try appendI16(&out, alloc, @intCast(contours.len)); // numberOfContours
    for (0..4) |_| try appendI16(&out, alloc, 0); // bbox
    // endPtsOfContours
    var acc: i32 = -1;
    for (contours) |c| {
        acc += @intCast(c.len);
        try appendU16(&out, alloc, @intCast(acc));
    }
    try appendU16(&out, alloc, 0); // instructionLength
    // flags: on-curve bit only (all 2-byte deltas → bit1/bit2/bit4/bit5 = 0)
    for (contours) |c| for (c) |pt| {
        try out.append(alloc, if (pt.on) @as(u8, 0x01) else 0x00);
    };
    // x deltas (2-byte)
    var px: i32 = 0;
    for (contours) |c| for (c) |pt| {
        const xi: i32 = @intFromFloat(pt.p.x);
        try appendI16(&out, alloc, @intCast(xi - px));
        px = xi;
    };
    // y deltas
    var py: i32 = 0;
    for (contours) |c| for (c) |pt| {
        const yi: i32 = @intFromFloat(pt.p.y);
        try appendI16(&out, alloc, @intCast(yi - py));
        py = yi;
    };
    if (out.items.len % 2 != 0) try out.append(alloc, 0); // Even length (for short loca)
    return out.toOwnedSlice(alloc);
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

/// Build glyf + loca(short) from glyph blobs and return Glyf. Caller frees glyf/loca.
const TestFont = struct {
    glyf: []u8,
    loca: []u8,
    fn make(alloc: std.mem.Allocator, glyphs: []const []const u8) !TestFont {
        var glyf: std.ArrayList(u8) = .empty;
        errdefer glyf.deinit(alloc);
        var loca: std.ArrayList(u8) = .empty;
        errdefer loca.deinit(alloc);
        var off: u32 = 0;
        for (glyphs) |g| {
            try appendU16(&loca, alloc, @intCast(off / 2)); // short loca
            try glyf.appendSlice(alloc, g);
            off += @intCast(g.len);
        }
        try appendU16(&loca, alloc, @intCast(off / 2)); // Sentinel
        return .{ .glyf = try glyf.toOwnedSlice(alloc), .loca = try loca.toOwnedSlice(alloc) };
    }
    fn deinit(self: *TestFont, alloc: std.mem.Allocator) void {
        alloc.free(self.glyf);
        alloc.free(self.loca);
    }
    fn glyfObj(self: TestFont, num_glyphs: u16) !Glyf {
        return Glyf.fromTables(self.glyf, self.loca, false, num_glyphs);
    }
};

test "glyf simple: triangle (all on-curve · 3 lines)" {
    const a = testing.allocator;
    const tri = [_]Pt{
        .{ .p = .{ .x = 0, .y = 0 }, .on = true },
        .{ .p = .{ .x = 100, .y = 0 }, .on = true },
        .{ .p = .{ .x = 50, .y = 100 }, .on = true },
    };
    const g0 = try buildSimpleGlyph(a, &.{&tri});
    defer a.free(g0);
    var tf = try TestFont.make(a, &.{g0});
    defer tf.deinit(a);
    const glyf = try tf.glyfObj(1);

    var o = try glyf.outline(a, 0);
    defer o.deinit(a);
    try testing.expectEqual(@as(usize, 1), o.contours.len);
    const c = o.contours[0];
    try testing.expectEqual(@as(f32, 0), c.start.x);
    // start=p0, process p1,p2, close→p0 = 3 lines
    try testing.expectEqual(@as(usize, 3), c.segments.len);
    try testing.expect(c.segments[0] == .line);
    try testing.expectEqual(@as(f32, 100), c.segments[0].line.x);
    try testing.expectEqual(@as(f32, 50), c.segments[1].line.x);
    try testing.expectEqual(@as(f32, 0), c.segments[2].line.x); // close to start
}

test "glyf simple: includes off-curve (produces quad)" {
    const a = testing.allocator;
    // on, off, on → 1 quad (ctrl=off), then close
    const pts = [_]Pt{
        .{ .p = .{ .x = 0, .y = 0 }, .on = true },
        .{ .p = .{ .x = 50, .y = 80 }, .on = false }, // Control point
        .{ .p = .{ .x = 100, .y = 0 }, .on = true },
    };
    const g0 = try buildSimpleGlyph(a, &.{&pts});
    defer a.free(g0);
    var tf = try TestFont.make(a, &.{g0});
    defer tf.deinit(a);
    const glyf = try tf.glyfObj(1);

    var o = try glyf.outline(a, 0);
    defer o.deinit(a);
    const c = o.contours[0];
    // start=p0, p1(off)→pending, p2(on)→quad(p1,p2), close p2→start=line
    try testing.expect(c.segments[0] == .quad);
    try testing.expectEqual(@as(f32, 50), c.segments[0].quad.ctrl.x);
    try testing.expectEqual(@as(f32, 100), c.segments[0].quad.end.x);
    try testing.expect(c.segments[1] == .line); // close to start
}

test "glyf simple: first and last off-curve (synthetic start)" {
    const a = testing.allocator;
    // off, on, off → start is mid(p0,p2)
    const pts = [_]Pt{
        .{ .p = .{ .x = 0, .y = 100 }, .on = false },
        .{ .p = .{ .x = 50, .y = 0 }, .on = true },
        .{ .p = .{ .x = 100, .y = 100 }, .on = false },
    };
    const g0 = try buildSimpleGlyph(a, &.{&pts});
    defer a.free(g0);
    var tf = try TestFont.make(a, &.{g0});
    defer tf.deinit(a);
    const glyf = try tf.glyfObj(1);

    var o = try glyf.outline(a, 0);
    defer o.deinit(a);
    const c = o.contours[0];
    // start = mid(p0,p2) = (50,100)
    try testing.expectEqual(@as(f32, 50), c.start.x);
    try testing.expectEqual(@as(f32, 100), c.start.y);
    // All quads (offs intercalated)
    for (c.segments) |s| try testing.expect(s == .quad);
}

test "glyf: empty glyph (equal loca) has empty contours" {
    const a = testing.allocator;
    const tri = [_]Pt{
        .{ .p = .{ .x = 0, .y = 0 }, .on = true },
        .{ .p = .{ .x = 100, .y = 0 }, .on = true },
        .{ .p = .{ .x = 50, .y = 100 }, .on = true },
    };
    const g1 = try buildSimpleGlyph(a, &.{&tri});
    defer a.free(g1);
    // Make gid 0 empty (length 0)
    var tf = try TestFont.make(a, &.{ &.{}, g1 });
    defer tf.deinit(a);
    const glyf = try tf.glyfObj(2);

    var o0 = try glyf.outline(a, 0);
    defer o0.deinit(a);
    try testing.expectEqual(@as(usize, 0), o0.contours.len);

    var o1 = try glyf.outline(a, 1);
    defer o1.deinit(a);
    try testing.expectEqual(@as(usize, 1), o1.contours.len);
}

test "glyf composite: references another glyph with XY offset" {
    const a = testing.allocator;
    const tri = [_]Pt{
        .{ .p = .{ .x = 0, .y = 0 }, .on = true },
        .{ .p = .{ .x = 100, .y = 0 }, .on = true },
        .{ .p = .{ .x = 50, .y = 100 }, .on = true },
    };
    const g0 = try buildSimpleGlyph(a, &.{&tri});
    defer a.free(g0);

    // composite gid1: reference gid0 offset by (dx=200, dy=10) (word args, XY)
    var comp: std.ArrayList(u8) = .empty;
    defer comp.deinit(a);
    try appendI16(&comp, a, -1); // numberOfContours < 0
    for (0..4) |_| try appendI16(&comp, a, 0); // bbox
    try appendU16(&comp, a, 0x0001 | 0x0002); // ARG_1_AND_2_ARE_WORDS | ARGS_ARE_XY_VALUES
    try appendU16(&comp, a, 0); // glyphIndex = 0
    try appendI16(&comp, a, 200); // dx
    try appendI16(&comp, a, 10); // dy
    const g1 = try comp.toOwnedSlice(a);
    defer a.free(g1);

    var tf = try TestFont.make(a, &.{ g0, g1 });
    defer tf.deinit(a);
    const glyf = try tf.glyfObj(2);

    var o = try glyf.outline(a, 1);
    defer o.deinit(a);
    try testing.expectEqual(@as(usize, 1), o.contours.len);
    // start = (0,0)+(200,10)
    try testing.expectEqual(@as(f32, 200), o.contours[0].start.x);
    try testing.expectEqual(@as(f32, 10), o.contours[0].start.y);
    try testing.expectEqual(@as(f32, 300), o.contours[0].segments[0].line.x); // 100+200
}

test "glyf composite: negative i8 XY offset via byte args" {
    const a = testing.allocator;
    const tri = [_]Pt{
        .{ .p = .{ .x = 0, .y = 0 }, .on = true },
        .{ .p = .{ .x = 100, .y = 0 }, .on = true },
        .{ .p = .{ .x = 50, .y = 100 }, .on = true },
    };
    const g0 = try buildSimpleGlyph(a, &.{&tri});
    defer a.free(g0);

    var comp: std.ArrayList(u8) = .empty;
    defer comp.deinit(a);
    try appendI16(&comp, a, -1);
    for (0..4) |_| try appendI16(&comp, a, 0);
    try appendU16(&comp, a, 0x0002); // ARGS_ARE_XY_VALUES (byte args)
    try appendU16(&comp, a, 0); // glyphIndex
    try comp.append(a, @bitCast(@as(i8, -10))); // dx = -10
    try comp.append(a, @bitCast(@as(i8, 5))); // dy = 5
    const g1 = try comp.toOwnedSlice(a);
    defer a.free(g1);

    var tf = try TestFont.make(a, &.{ g0, g1 });
    defer tf.deinit(a);
    const glyf = try tf.glyfObj(2);

    var o = try glyf.outline(a, 1);
    defer o.deinit(a);
    try testing.expectEqual(@as(f32, -10), o.contours[0].start.x);
    try testing.expectEqual(@as(f32, 5), o.contours[0].start.y);
}

test "glyf: gid out of range is InvalidFont" {
    const a = testing.allocator;
    const tri = [_]Pt{
        .{ .p = .{ .x = 0, .y = 0 }, .on = true },
        .{ .p = .{ .x = 10, .y = 0 }, .on = true },
        .{ .p = .{ .x = 5, .y = 10 }, .on = true },
    };
    const g0 = try buildSimpleGlyph(a, &.{&tri});
    defer a.free(g0);
    var tf = try TestFont.make(a, &.{g0});
    defer tf.deinit(a);
    const glyf = try tf.glyfObj(1);
    try testing.expectError(error.InvalidFont, glyf.outline(a, 1)); // gid 1 >= numGlyphs 1
}

test "glyf composite: self-reference (recursion depth exceeded) is InvalidFont" {
    const a = testing.allocator;
    // composite where gid0 references gid0
    var comp: std.ArrayList(u8) = .empty;
    defer comp.deinit(a);
    try appendI16(&comp, a, -1);
    for (0..4) |_| try appendI16(&comp, a, 0);
    try appendU16(&comp, a, 0x0002); // XY, byte args
    try appendU16(&comp, a, 0); // glyphIndex = 0 (self-reference)
    try comp.append(a, 0);
    try comp.append(a, 0);
    if (comp.items.len % 2 != 0) try comp.append(a, 0);
    const g0 = try comp.toOwnedSlice(a);
    defer a.free(g0);
    var tf = try TestFont.make(a, &.{g0});
    defer tf.deinit(a);
    const glyf = try tf.glyfObj(1);
    try testing.expectError(error.InvalidFont, glyf.outline(a, 0));
}

test "glyf composite: point matching (non-XY) is Unsupported" {
    const a = testing.allocator;
    const tri = [_]Pt{
        .{ .p = .{ .x = 0, .y = 0 }, .on = true },
        .{ .p = .{ .x = 10, .y = 0 }, .on = true },
        .{ .p = .{ .x = 5, .y = 10 }, .on = true },
    };
    const g0 = try buildSimpleGlyph(a, &.{&tri});
    defer a.free(g0);
    var comp: std.ArrayList(u8) = .empty;
    defer comp.deinit(a);
    try appendI16(&comp, a, -1);
    for (0..4) |_| try appendI16(&comp, a, 0);
    try appendU16(&comp, a, 0x0001); // ARG_1_AND_2_ARE_WORDS (no XY = point matching)
    try appendU16(&comp, a, 0);
    try appendU16(&comp, a, 0);
    try appendU16(&comp, a, 0);
    const g1 = try comp.toOwnedSlice(a);
    defer a.free(g1);
    var tf = try TestFont.make(a, &.{ g0, g1 });
    defer tf.deinit(a);
    const glyf = try tf.glyfObj(2);
    try testing.expectError(error.Unsupported, glyf.outline(a, 1));
}

test "glyf: loca.len mismatch is InvalidFont" {
    const glyf_bytes = [_]u8{0} ** 12;
    const loca_bytes = [_]u8{0} ** 2; // With numGlyphs=1, need (1+1)*2=4
    try testing.expectError(error.InvalidFont, Glyf.fromTables(&glyf_bytes, &loca_bytes, false, 1));
}

test "glyf composite: WE_HAVE_A_SCALE scales coordinates" {
    const a = testing.allocator;
    const tri = [_]Pt{
        .{ .p = .{ .x = 0, .y = 0 }, .on = true },
        .{ .p = .{ .x = 100, .y = 0 }, .on = true },
        .{ .p = .{ .x = 50, .y = 100 }, .on = true },
    };
    const g0 = try buildSimpleGlyph(a, &.{&tri});
    defer a.free(g0);

    var comp: std.ArrayList(u8) = .empty;
    defer comp.deinit(a);
    try appendI16(&comp, a, -1);
    for (0..4) |_| try appendI16(&comp, a, 0);
    try appendU16(&comp, a, 0x0002 | 0x0008); // ARGS_ARE_XY_VALUES | WE_HAVE_A_SCALE (byte args)
    try appendU16(&comp, a, 0); // glyphIndex
    try comp.append(a, 0); // dx=0
    try comp.append(a, 0); // dy=0
    try appendI16(&comp, a, 0x2000); // F2Dot14 0.5
    const g1 = try comp.toOwnedSlice(a);
    defer a.free(g1);

    var tf = try TestFont.make(a, &.{ g0, g1 });
    defer tf.deinit(a);
    const glyf = try tf.glyfObj(2);
    var o = try glyf.outline(a, 1);
    defer o.deinit(a);
    // (100,0)→(50,0), (50,100)→(25,50)
    try testing.expectEqual(@as(f32, 50), o.contours[0].segments[0].line.x);
    try testing.expectEqual(@as(f32, 25), o.contours[0].segments[1].line.x);
    try testing.expectEqual(@as(f32, 50), o.contours[0].segments[1].line.y);
}

test "glyf simple: REPEAT overrun is InvalidFont" {
    const a = testing.allocator;
    var g: std.ArrayList(u8) = .empty;
    defer g.deinit(a);
    try appendI16(&g, a, 1); // numberOfContours
    for (0..4) |_| try appendI16(&g, a, 0); // bbox
    try appendU16(&g, a, 1); // endPts[0]=1 (2 points)
    try appendU16(&g, a, 0); // instructionLength
    try g.append(a, 0x09); // ON|REPEAT
    try g.append(a, 10); // repeat 10 (excessive for the remaining 1 point)
    const g0 = try g.toOwnedSlice(a);
    defer a.free(g0);
    var tf = try TestFont.make(a, &.{g0});
    defer tf.deinit(a);
    const glyf = try tf.glyfObj(1);
    try testing.expectError(error.InvalidFont, glyf.outline(a, 0));
}

test "glyf: truncated instructions on 0-contour is InvalidFont" {
    const a = testing.allocator;
    var g: std.ArrayList(u8) = .empty;
    defer g.deinit(a);
    try appendI16(&g, a, 0); // numberOfContours=0
    for (0..4) |_| try appendI16(&g, a, 0); // bbox
    try appendU16(&g, a, 5); // instructionLength=5
    try g.append(a, 0); // Only 1 byte actually present (short of 5)
    if (g.items.len % 2 != 0) try g.append(a, 0);
    const g0 = try g.toOwnedSlice(a);
    defer a.free(g0);
    var tf = try TestFont.make(a, &.{g0});
    defer tf.deinit(a);
    const glyf = try tf.glyfObj(1);
    // Even padding adds 1 byte, so size large enough that instructionLength=5 is still insufficient
    try testing.expectError(error.InvalidFont, glyf.outline(a, 0));
}

test "glyf composite: truncated WE_HAVE_INSTRUCTIONS trailing data is InvalidFont" {
    const a = testing.allocator;
    const tri = [_]Pt{
        .{ .p = .{ .x = 0, .y = 0 }, .on = true },
        .{ .p = .{ .x = 10, .y = 0 }, .on = true },
        .{ .p = .{ .x = 5, .y = 10 }, .on = true },
    };
    const g0 = try buildSimpleGlyph(a, &.{&tri});
    defer a.free(g0);
    var comp: std.ArrayList(u8) = .empty;
    defer comp.deinit(a);
    try appendI16(&comp, a, -1);
    for (0..4) |_| try appendI16(&comp, a, 0);
    try appendU16(&comp, a, 0x0002 | 0x0100); // XY | WE_HAVE_INSTRUCTIONS (no MORE_COMPONENTS)
    try appendU16(&comp, a, 0); // glyphIndex
    try comp.append(a, 0); // dx
    try comp.append(a, 0); // dy
    try appendU16(&comp, a, 5); // instructionLength=5 but body is 0 bytes
    const g1 = try comp.toOwnedSlice(a);
    defer a.free(g1);
    var tf = try TestFont.make(a, &.{ g0, g1 });
    defer tf.deinit(a);
    const glyf = try tf.glyfObj(2);
    try testing.expectError(error.InvalidFont, glyf.outline(a, 1));
}

test "glyf: composite+gvar varies offset only; transform unchanged; matches at norm0" {
    const a = testing.allocator;
    const tri = [_]Pt{
        .{ .p = .{ .x = 0, .y = 0 }, .on = true },
        .{ .p = .{ .x = 100, .y = 0 }, .on = true },
        .{ .p = .{ .x = 50, .y = 100 }, .on = true },
    };
    const g0 = try buildSimpleGlyph(a, &.{&tri});
    defer a.free(g0);

    // composite: 2 components — gid0@ (0,0) scale 0.5, gid0@ (200,0) no scale
    // flags: WORDS|XY|SCALE for first, WORDS|XY|MORE for first, WORDS|XY for second
    var comp: std.ArrayList(u8) = .empty;
    defer comp.deinit(a);
    try appendI16(&comp, a, -1);
    for (0..4) |_| try appendI16(&comp, a, 0);
    // component 0: XY words + WE_HAVE_A_SCALE + MORE_COMPONENTS
    try appendU16(&comp, a, 0x0001 | 0x0002 | 0x0008 | 0x0020);
    try appendU16(&comp, a, 0);
    try appendI16(&comp, a, 0); // dx
    try appendI16(&comp, a, 0); // dy
    try appendI16(&comp, a, 0x2000); // F2Dot14 0.5
    // component 1: XY words
    try appendU16(&comp, a, 0x0001 | 0x0002);
    try appendU16(&comp, a, 0);
    try appendI16(&comp, a, 200);
    try appendI16(&comp, a, 0);
    if (comp.items.len % 2 != 0) try comp.append(a, 0);
    const g1 = try comp.toOwnedSlice(a);
    defer a.free(g1);

    var tf = try TestFont.make(a, &.{ g0, g1 });
    defer tf.deinit(a);
    const glyf = try tf.glyfObj(2);

    // gvar for gid1 (composite): component 1 dx += 50 at peak=1
    // reuse pattern from gvar tests: 2 virtual points + 4 phantom, private point 1
    var ser: std.ArrayList(u8) = .empty;
    defer ser.deinit(a);
    try ser.append(a, 1);
    try ser.append(a, 0);
    try ser.append(a, 1); // point 1
    try ser.append(a, 0x40);
    try appendI16(&ser, a, 50);
    try ser.append(a, 0x40);
    try appendI16(&ser, a, 0);
    var gvd: std.ArrayList(u8) = .empty;
    defer gvd.deinit(a);
    try appendU16(&gvd, a, 1);
    try appendU16(&gvd, a, 10);
    try appendU16(&gvd, a, @intCast(ser.items.len));
    try appendU16(&gvd, a, 0x8000 | 0x2000);
    try appendI16(&gvd, a, var_common_f2d(1.0));
    try gvd.appendSlice(a, ser.items);
    // gvar: 2 glyphs (gid0 empty, gid1 = gvd)
    var gvar_tbl: std.ArrayList(u8) = .empty;
    defer gvar_tbl.deinit(a);
    try appendU16(&gvar_tbl, a, 1);
    try appendU16(&gvar_tbl, a, 0);
    try appendU16(&gvar_tbl, a, 1);
    try appendU16(&gvar_tbl, a, 0);
    try appendU32(&gvar_tbl, a, 0);
    try appendU16(&gvar_tbl, a, 2);
    try appendU16(&gvar_tbl, a, 1); // long
    try appendU32(&gvar_tbl, a, 20 + 3 * 4); // gvd array after 3 offsets
    try appendU32(&gvar_tbl, a, 0); // gid0 empty
    try appendU32(&gvar_tbl, a, 0);
    try appendU32(&gvar_tbl, a, @intCast(gvd.items.len));
    try gvar_tbl.appendSlice(a, gvd.items);
    const gv = try gvar_mod.Gvar.parse(gvar_tbl.items, 2, 1);

    // norm=0: matches current outline
    var o_def = try glyf.outline(a, 1);
    defer o_def.deinit(a);
    var o0 = try glyf.outlineVaried(a, 1, &gv, &.{0});
    defer o0.deinit(a);
    try testing.expectEqual(o_def.contours.len, o0.contours.len);
    try testing.expectEqual(o_def.contours[0].start.x, o0.contours[0].start.x);
    try testing.expectEqual(o_def.contours[1].start.x, o0.contours[1].start.x);

    // default: contour0 scaled 0.5 from origin, contour1 at (200,0)
    try testing.expectApproxEqAbs(@as(f32, 0), o_def.contours[0].start.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 50), o_def.contours[0].segments[0].line.x, 0.01); // 100*0.5
    try testing.expectApproxEqAbs(@as(f32, 200), o_def.contours[1].start.x, 0.01);

    // norm=1: component1 offset 200+50=250; scale on component0 unchanged
    var o1 = try glyf.outlineVaried(a, 1, &gv, &.{1.0});
    defer o1.deinit(a);
    try testing.expectApproxEqAbs(@as(f32, 0), o1.contours[0].start.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 50), o1.contours[0].segments[0].line.x, 0.01); // scale unchanged
    try testing.expectApproxEqAbs(@as(f32, 250), o1.contours[1].start.x, 0.01); // offset variation
    try testing.expectApproxEqAbs(@as(f32, 350), o1.contours[1].segments[0].line.x, 0.01); // 100+250
}

fn var_common_f2d(v: f32) i16 {
    return @import("var_common.zig").f32ToF2dot14(v);
}

test "glyf: parseCompositeInfo USE_MY_METRICS last-wins" {
    const a = testing.allocator;
    const tri = [_]Pt{
        .{ .p = .{ .x = 0, .y = 0 }, .on = true },
        .{ .p = .{ .x = 10, .y = 0 }, .on = true },
        .{ .p = .{ .x = 5, .y = 10 }, .on = true },
    };
    const g0 = try buildSimpleGlyph(a, &.{&tri});
    defer a.free(g0);
    const g1 = try buildSimpleGlyph(a, &.{&tri});
    defer a.free(g1);

    // composite: comp0 USE_MY_METRICS gid0, comp1 USE_MY_METRICS gid1 → last=g1
    var comp: std.ArrayList(u8) = .empty;
    defer comp.deinit(a);
    try appendI16(&comp, a, -1);
    for (0..4) |_| try appendI16(&comp, a, 0);
    try appendU16(&comp, a, 0x0002 | 0x0200 | 0x0020); // XY | USE_MY_METRICS | MORE
    try appendU16(&comp, a, 0);
    try comp.append(a, 0);
    try comp.append(a, 0);
    try appendU16(&comp, a, 0x0002 | 0x0200); // XY | USE_MY_METRICS
    try appendU16(&comp, a, 1);
    try comp.append(a, 10);
    try comp.append(a, 0);
    if (comp.items.len % 2 != 0) try comp.append(a, 0);
    const g2 = try comp.toOwnedSlice(a);
    defer a.free(g2);

    var tf = try TestFont.make(a, &.{ g0, g1, g2 });
    defer tf.deinit(a);
    const glyf = try tf.glyfObj(3);
    const info = (try glyf.parseCompositeInfo(2)).?;
    try testing.expectEqual(@as(u16, 2), info.component_count);
    try testing.expectEqual(@as(?u16, 1), info.use_my_metrics_gid);
}

test "glyf simple: flag branches (X_SHORT ± / X_SAME·Y_SAME no-byte / REPEAT) — raw bytes" {
    const a = testing.allocator;
    // 1 contour, 4 points, all on-curve.
    //   p0=(10,20)  p1=(5,20)  p2=(5,20)  p3=(5,20)
    //   p0: all short positive. p1: X_SHORT negative, Y_SAME. p2,p3: X_SAME, Y_SAME via REPEAT.
    var g: std.ArrayList(u8) = .empty;
    defer g.deinit(a);
    try appendI16(&g, a, 1); // numberOfContours
    for (0..4) |_| try appendI16(&g, a, 0); // bbox
    try appendU16(&g, a, 3); // endPts[0] = 3 (4 points)
    try appendU16(&g, a, 0); // instructionLength
    // flags:
    //   p0: ON|X_SHORT|X_POS|Y_SHORT|Y_POS = 0x37
    //   p1: ON|X_SHORT(bit4=0→neg)|Y_SAME(bit5=1,!Y_SHORT) = 0x23
    //   p2,p3: ON|X_SAME(bit4=1,!X_SHORT)|Y_SAME(bit5=1) | REPEAT = 0x31|0x08 = 0x39, repeat=1
    try g.append(a, 0x37);
    try g.append(a, 0x23);
    try g.append(a, 0x39);
    try g.append(a, 1); // repeat count (apply 0x31-equivalent to p2,p3)
    // x coords: p0 +10, p1 -5 (value 5, bit4=0), p2/p3 same (no bytes)
    try g.append(a, 10);
    try g.append(a, 5);
    // y coords: p0 +20, p1/p2/p3 same (no bytes)
    try g.append(a, 20);
    if (g.items.len % 2 != 0) try g.append(a, 0);
    const g0 = try g.toOwnedSlice(a);
    defer a.free(g0);

    var tf = try TestFont.make(a, &.{g0});
    defer tf.deinit(a);
    const glyf = try tf.glyfObj(1);
    var o = try glyf.outline(a, 0);
    defer o.deinit(a);
    const c = o.contours[0];
    try testing.expectEqual(@as(f32, 10), c.start.x); // p0
    try testing.expectEqual(@as(f32, 20), c.start.y);
    try testing.expectEqual(@as(f32, 5), c.segments[0].line.x); // p1 = 10-5
    try testing.expectEqual(@as(f32, 20), c.segments[0].line.y); // y same
    try testing.expectEqual(@as(f32, 5), c.segments[1].line.x); // p2 same
    try testing.expectEqual(@as(f32, 5), c.segments[2].line.x); // p3 same (REPEAT)
}
