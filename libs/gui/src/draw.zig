const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const color_mod = @import("color.zig");
const font_mod = @import("font.zig");
const corner_mask = @import("corner_mask.zig");

pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const Color = color_mod.Color;
pub const Font = font_mod.Font;

/// Logical / device-space point used by path verbs. Distinct from integer `Vec2`.
pub const Vec2f = struct { x: f32, y: f32 };

pub const LinearGradient = struct {
    start: Vec2f,
    end: Vec2f,
    start_color: Color,
    end_color: Color,
};

pub const RadialGradient = struct {
    center: Vec2f,
    radius: f32,
    inner_color: Color,
    outer_color: Color,
};

pub const Paint = union(enum) {
    solid: Color,
    linear: LinearGradient,
    radial: RadialGradient,
};

/// Path verbs. `fill` is a command attribute, not a verb.
pub const PathVerb = enum(u8) {
    move,
    line,
    quad,
    cubic,
    close,

    pub fn pointCount(self: PathVerb) u8 {
        return pathVerbSpec(self).point_count;
    }

    pub fn letter(self: PathVerb) u8 {
        return pathVerbSpec(self).letter;
    }

    pub fn wireTag(self: PathVerb) u8 {
        return pathVerbSpec(self).wire_tag;
    }
};

/// One row of the path-verb table. Serializer, parser, and the binary wire
/// all look this up — adding a verb is a table edit plus the `PathVerb` tag.
pub const PathVerbSpec = struct {
    verb: PathVerb,
    letter: u8,
    wire_tag: u8,
    point_count: u8,
};

/// Verb ↔ letter ↔ wire tag ↔ point count. Index equals `@intFromEnum(verb)`.
pub const path_verb_table = [_]PathVerbSpec{
    .{ .verb = .move, .letter = 'M', .wire_tag = 0, .point_count = 1 },
    .{ .verb = .line, .letter = 'L', .wire_tag = 1, .point_count = 1 },
    .{ .verb = .quad, .letter = 'Q', .wire_tag = 2, .point_count = 2 },
    .{ .verb = .cubic, .letter = 'C', .wire_tag = 3, .point_count = 3 },
    .{ .verb = .close, .letter = 'Z', .wire_tag = 4, .point_count = 0 },
};

comptime {
    const tags = std.meta.tags(PathVerb);
    if (tags.len != path_verb_table.len) {
        @compileError("path_verb_table must have one entry per PathVerb");
    }
    for (tags, 0..) |tag, i| {
        if (path_verb_table[i].verb != tag) {
            @compileError("path_verb_table must be in PathVerb declaration order");
        }
    }
}

pub fn pathVerbSpec(v: PathVerb) *const PathVerbSpec {
    return &path_verb_table[@intFromEnum(v)];
}

pub fn pathVerbFromLetter(c: u8) ?PathVerb {
    for (&path_verb_table) |*spec| {
        if (spec.letter == c) return spec.verb;
    }
    return null;
}

pub fn pathVerbFromWireTag(tag: u8) ?PathVerb {
    for (&path_verb_table) |*spec| {
        if (spec.wire_tag == tag) return spec.verb;
    }
    return null;
}

/// Contour state machine shared by the builder, the dump parser, and the
/// binary wire validator. A contour starts with `move`. `line`/`quad`/`cubic`
/// before a `move` is `error.InvalidPath`. After `close`, the next verb must
/// be `move`.
pub const PathContourState = struct {
    in_contour: bool = false,

    pub fn feed(self: *PathContourState, v: PathVerb) error{InvalidPath}!void {
        switch (v) {
            .move => self.in_contour = true,
            .line, .quad, .cubic => if (!self.in_contour) return error.InvalidPath,
            .close => {
                if (!self.in_contour) return error.InvalidPath;
                self.in_contour = false;
            },
        }
    }
};

pub fn validatePathSequence(verbs: []const PathVerb) error{InvalidPath}!void {
    var st: PathContourState = .{};
    for (verbs) |v| try st.feed(v);
}

/// Fill winding. Only nonzero is defined for this vocabulary.
pub const PathWinding = enum(u8) { nonzero };

/// Corner join of a stroked path. `miter` falls back to `bevel` when the
/// miter length / stroke width exceeds `miter_limit`.
pub const PathJoin = enum(u8) {
    miter,
    bevel,
};

/// End cap of an open stroked path. `round` is a flattened semicircle
/// (no dedicated arc verb).
pub const PathCap = enum(u8) {
    butt,
    square,
    round,
};

pub const path_join_table = [_]struct { join: PathJoin, name: []const u8 }{
    .{ .join = .miter, .name = "miter" },
    .{ .join = .bevel, .name = "bevel" },
};

pub const path_cap_table = [_]struct { cap: PathCap, name: []const u8 }{
    .{ .cap = .butt, .name = "butt" },
    .{ .cap = .square, .name = "square" },
    .{ .cap = .round, .name = "round" },
};

comptime {
    const joins = std.meta.tags(PathJoin);
    if (joins.len != path_join_table.len) {
        @compileError("path_join_table must have one entry per PathJoin");
    }
    for (joins, 0..) |tag, i| {
        if (path_join_table[i].join != tag) {
            @compileError("path_join_table must be in PathJoin declaration order");
        }
    }
    const caps = std.meta.tags(PathCap);
    if (caps.len != path_cap_table.len) {
        @compileError("path_cap_table must have one entry per PathCap");
    }
    for (caps, 0..) |tag, i| {
        if (path_cap_table[i].cap != tag) {
            @compileError("path_cap_table must be in PathCap declaration order");
        }
    }
}

pub fn pathJoinName(j: PathJoin) []const u8 {
    return path_join_table[@intFromEnum(j)].name;
}

pub fn pathCapName(c: PathCap) []const u8 {
    return path_cap_table[@intFromEnum(c)].name;
}

pub fn pathJoinFromName(s: []const u8) ?PathJoin {
    for (&path_join_table) |*row| {
        if (std.mem.eql(u8, row.name, s)) return row.join;
    }
    return null;
}

pub fn pathCapFromName(s: []const u8) ?PathCap {
    for (&path_cap_table) |*row| {
        if (std.mem.eql(u8, row.name, s)) return row.cap;
    }
    return null;
}

/// SVG default: bevel when the miter is longer than 4× the stroke width.
pub const path_miter_limit_default: f32 = 4.0;

/// Largest accepted stroke width (logical px). Matches the integer-thickness
/// cap used by `line` / `rect_outline` so a dump cannot overflow render.
pub const path_stroke_width_max: f32 = 4096.0;

/// Fill attributes of a path command (colour, winding, AA). Not a verb.
pub const PathFill = struct {
    color: Color,
    winding: PathWinding = .nonzero,
    aa: bool = true,
};

/// Stroke attributes of a path command (colour, width, join, cap, AA).
/// Not a verb. `width` is in logical pixels and must be finite and in
/// `(0, path_stroke_width_max]`. `miter_limit` is dimensionless and must
/// be finite and `>= 1`.
pub const PathStroke = struct {
    color: Color,
    width: f32,
    join: PathJoin = .miter,
    cap: PathCap = .butt,
    miter_limit: f32 = path_miter_limit_default,
    aa: bool = true,
};

/// Geometry-only stroke parameters stored on `DrawCmd.path`. Colour and AA
/// stay on the command's shared fields. `null` means fill.
pub const PathStrokeParams = struct {
    width: f32,
    join: PathJoin = .miter,
    cap: PathCap = .butt,
    miter_limit: f32 = path_miter_limit_default,
};

pub const PathError = error{ InvalidPath, OutOfMemory };

pub const RoundedRectOptions = struct {
    radius: u32 = 0,
    aa: bool = true,
};

pub const CircleOptions = struct {
    aa: bool = true,
};

/// One shape's coverage scratch is this many bytes or less. A larger bbox is
/// split into horizontal bands so the peak stays at this cap.
pub const path_scratch_limit_bytes: usize = 4 * 1024 * 1024;

/// area (f32) + cover (f32) + 8bpp coverage. Used to convert the byte cap
/// into a pixel cap and to record the peak.
pub const path_scratch_bytes_per_pixel: usize = @sizeOf(f32) * 2 + @sizeOf(u8);

pub const DrawCmd = union(enum) {
    rect_filled: struct { rect: Rect, paint: Paint, radius: u32 = 0, aa: bool = true, clip: Rect },
    rect_outline: struct { rect: Rect, color: Color, thickness: u32, radius: u32 = 0, aa: bool = true, clip: Rect },
    circle_filled: struct { center: Vec2, radius: u32, color: Color, aa: bool = true, clip: Rect },
    circle_outline: struct { center: Vec2, radius: u32, color: Color, thickness: u32, aa: bool = true, clip: Rect },
    /// Integer-thickness Bresenham span. Widget chrome uses this. Path
    /// stroke does not replace it: a Bresenham span and an analytic AA
    /// offset-contour disagree on pixels, so swapping would change every
    /// existing UI frame. The two stay separate on purpose.
    line: struct { p0: Vec2, p1: Vec2, color: Color, thickness: u32, clip: Rect },
    /// `text` must point at an arena slice that outlives the DrawList (caller responsibility).
    /// If `font` is null, draw with the default font passed to `render()` (override hook).
    text: struct { pos: Vec2, text: []const u8, color: Color, clip: Rect, font: ?Font = null },
    /// `pixels` must point at a caller-owned slice that outlives the DrawList (caller responsibility).
    image: struct { rect: Rect, pixels: []const u32, src_w: u32, src_h: u32, clip: Rect },
    /// Filled or stroked path. `verbs` and `points` are SoA slices the caller
    /// (or the frame arena) owns; the DrawList holds only the references.
    /// `reset` invalidates them. The valid window is after `endFrame` until
    /// the next `beginFrame` (render and the drawlist probe run in that
    /// window). A direct DrawList user supplies the same lifetime.
    /// `stroke == null` is a fill: an unclosed contour is closed implicitly.
    /// `stroke != null` is a stroke: unclosed contours stay open and receive
    /// end caps; closed contours join at the start/end vertex and never
    /// receive caps. A closed contour that collapses to fewer than 3
    /// points is a no-op (no disc, no square).
    path: struct {
        verbs: []const PathVerb,
        points: []const Vec2f,
        color: Color,
        winding: PathWinding,
        aa: bool,
        clip: Rect,
        stroke: ?PathStrokeParams = null,
    },
};

/// Incremental path builder. Verbs and points accumulate on `arena`. `finish`
/// appends one DrawCmd on success; InvalidPath or OOM leaves the DrawList unchanged.
///
/// Contour rules: a contour starts with `move`. `line`/`quad`/`cubic` before a
/// `move` is `error.InvalidPath`. After `close`, the next verb must be `move`
/// (a following segment is not an implicit new contour). Non-finite coordinates
/// are `error.InvalidPath`.
pub const PathBuilder = struct {
    dl: *DrawList,
    arena: Allocator,
    verbs: std.ArrayList(PathVerb) = .empty,
    points: std.ArrayList(Vec2f) = .empty,
    contour: PathContourState = .{},
    err: ?PathError = null,

    fn fail(self: *PathBuilder, e: PathError) PathError {
        if (self.err == null) self.err = e;
        return e;
    }

    fn checkFinite(self: *PathBuilder, p: Vec2f) PathError!void {
        if (!std.math.isFinite(p.x) or !std.math.isFinite(p.y)) {
            return self.fail(error.InvalidPath);
        }
    }

    fn pushVerb(self: *PathBuilder, v: PathVerb) PathError!void {
        self.verbs.append(self.arena, v) catch |e| return self.fail(e);
    }

    fn pushPoint(self: *PathBuilder, p: Vec2f) PathError!void {
        try self.checkFinite(p);
        self.points.append(self.arena, p) catch |e| return self.fail(e);
    }

    fn accept(self: *PathBuilder, v: PathVerb) PathError!void {
        self.contour.feed(v) catch return self.fail(error.InvalidPath);
        try self.pushVerb(v);
    }

    pub fn moveTo(self: *PathBuilder, p: Vec2f) PathError!void {
        if (self.err) |e| return e;
        try self.accept(.move);
        try self.pushPoint(p);
    }

    pub fn lineTo(self: *PathBuilder, p: Vec2f) PathError!void {
        if (self.err) |e| return e;
        try self.accept(.line);
        try self.pushPoint(p);
    }

    pub fn quadTo(self: *PathBuilder, ctrl: Vec2f, p: Vec2f) PathError!void {
        if (self.err) |e| return e;
        try self.accept(.quad);
        try self.pushPoint(ctrl);
        try self.pushPoint(p);
    }

    pub fn cubicTo(self: *PathBuilder, c1: Vec2f, c2: Vec2f, p: Vec2f) PathError!void {
        if (self.err) |e| return e;
        try self.accept(.cubic);
        try self.pushPoint(c1);
        try self.pushPoint(c2);
        try self.pushPoint(p);
    }

    pub fn close(self: *PathBuilder) PathError!void {
        if (self.err) |e| return e;
        try self.accept(.close);
    }

    fn appendPath(
        self: *PathBuilder,
        color: Color,
        winding: PathWinding,
        aa: bool,
        stroke_params: ?PathStrokeParams,
    ) PathError!void {
        const verbs = self.arena.dupe(PathVerb, self.verbs.items) catch |e| return self.fail(e);
        const points = self.arena.dupe(Vec2f, self.points.items) catch |e| return self.fail(e);
        self.dl.cmds.append(self.dl.alloc, .{ .path = .{
            .verbs = verbs,
            .points = points,
            .color = color,
            .winding = winding,
            .aa = aa,
            .clip = self.dl.currentClip(),
            .stroke = stroke_params,
        } }) catch |e| return self.fail(e);
    }

    /// Appends one filled path command. An unclosed contour is kept as-is and
    /// closed implicitly at fill time. Does not append on InvalidPath or OOM.
    pub fn finish(self: *PathBuilder, fill: PathFill) PathError!void {
        if (self.err) |e| return e;
        try self.appendPath(fill.color, fill.winding, fill.aa, null);
    }

    /// Appends one stroked path command. Does not append on InvalidPath or OOM.
    pub fn stroke(self: *PathBuilder, s: PathStroke) PathError!void {
        if (self.err) |e| return e;
        if (!std.math.isFinite(s.width) or s.width <= 0 or s.width > path_stroke_width_max) {
            return self.fail(error.InvalidPath);
        }
        if (!std.math.isFinite(s.miter_limit) or s.miter_limit < 1) {
            return self.fail(error.InvalidPath);
        }
        try self.appendPath(s.color, .nonzero, s.aa, .{
            .width = s.width,
            .join = s.join,
            .cap = s.cap,
            .miter_limit = s.miter_limit,
        });
    }
};

/// ArrayList is unmanaged, so keep the alloc field ourselves.
/// Always call `reset(w, h)` before use.
pub const DrawList = struct {
    alloc: Allocator,
    cmds: std.ArrayList(DrawCmd) = .empty,
    clip_stack: std.ArrayList(Rect) = .empty,

    /// Coverage scratch reused across path commands. `reset` keeps capacity;
    /// `deinit` frees it. One DrawList is single-threaded; `render` must not
    /// be re-entered or called concurrently on the same list.
    path_area: []f32 = &.{},
    path_cover: []f32 = &.{},
    path_coverage: []u8 = &.{},
    path_scratch_pixels: usize = 0,
    path_scratch_peak_bytes: usize = 0,
    /// Flattened device-space polylines reused across path commands. `reset`
    /// keeps capacity; `deinit` frees them. Grown only when a shape needs more
    /// points or contours than the last peak.
    path_flat_pts: std.ArrayList(Vec2f) = .empty,
    path_contour_ends: std.ArrayList(usize) = .empty,
    /// Parallel to `path_contour_ends`: 1 if that contour saw an explicit
    /// `close`, 0 if it is open. Fill ignores this (every contour is closed
    /// at rasterize). Stroke uses it to choose joins vs end caps.
    path_contour_closed: std.ArrayList(u8) = .empty,
    /// Offset polygons for a stroke command. Same reuse contract as
    /// `path_flat_pts`. `path_stroke_aux` is the collapsed centerline;
    /// `path_stroke_left` / `path_stroke_right` are the two offset chains
    /// while a contour is assembled.
    path_stroke_pts: std.ArrayList(Vec2f) = .empty,
    path_stroke_ends: std.ArrayList(usize) = .empty,
    path_stroke_aux: std.ArrayList(Vec2f) = .empty,
    path_stroke_left: std.ArrayList(Vec2f) = .empty,
    path_stroke_right: std.ArrayList(Vec2f) = .empty,
    /// Requested scratch cap in bytes. The effective cap is clamped to
    /// `[@max(one_row, @min(path_scratch_limit, path_scratch_limit_bytes))]`
    /// so a value of 0 still draws (one row at a time) and a value above the
    /// production ceiling cannot break the 4 MiB peak.
    path_scratch_limit: usize = path_scratch_limit_bytes,
    /// Rounded masks survive `reset` and are released by `deinit`. The cache
    /// and its counters are touched only by non-zero-radius primitives.
    corner_masks: corner_mask.Cache = .{},
    /// Retained outer coverage for an uncached giant quarter-ring band. The
    /// ordinary cached path does not use this buffer.
    corner_band: []u8 = &.{},
    /// Retained fixed-point x contribution for linear gradient rows. It is
    /// grown only when a gradient command needs a wider visible row.
    linear_gradient_columns: []i64 = &.{},
    /// Retained radial distance correction table. Solid and linear-only frames
    /// never allocate it.
    radial_gradient_lut: []u8 = &.{},
    radial_gradient_lut_ready: bool = false,

    pub fn init(alloc: Allocator) DrawList {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *DrawList) void {
        self.cmds.deinit(self.alloc);
        self.clip_stack.deinit(self.alloc);
        if (self.path_area.len != 0) self.alloc.free(self.path_area);
        if (self.path_cover.len != 0) self.alloc.free(self.path_cover);
        if (self.path_coverage.len != 0) self.alloc.free(self.path_coverage);
        self.path_area = &.{};
        self.path_cover = &.{};
        self.path_coverage = &.{};
        self.path_scratch_pixels = 0;
        self.path_flat_pts.deinit(self.alloc);
        self.path_contour_ends.deinit(self.alloc);
        self.path_contour_closed.deinit(self.alloc);
        self.path_stroke_pts.deinit(self.alloc);
        self.path_stroke_ends.deinit(self.alloc);
        self.path_stroke_aux.deinit(self.alloc);
        self.path_stroke_left.deinit(self.alloc);
        self.path_stroke_right.deinit(self.alloc);
        self.corner_masks.deinit(self.alloc);
        if (self.corner_band.len != 0) self.alloc.free(self.corner_band);
        self.corner_band = &.{};
        if (self.linear_gradient_columns.len != 0) self.alloc.free(self.linear_gradient_columns);
        self.linear_gradient_columns = &.{};
        if (self.radial_gradient_lut.len != 0) self.alloc.free(self.radial_gradient_lut);
        self.radial_gradient_lut = &.{};
        self.radial_gradient_lut_ready = false;
    }

    /// Call at the start of every frame. Sets root clip = Rect{0,0,w,h}.
    /// w/h are logical size (not physical framebuffer dims; scale is applied in `render()`).
    pub fn reset(self: *DrawList, w: u32, h: u32) void {
        self.cmds.clearRetainingCapacity();
        self.clip_stack.clearRetainingCapacity();
        self.clip_stack.append(self.alloc, .{ .x = 0, .y = 0, .w = w, .h = h }) catch
            @panic("DrawList.reset: OOM");
    }

    fn currentClip(self: *const DrawList) Rect {
        std.debug.assert(self.clip_stack.items.len > 0);
        return self.clip_stack.items[self.clip_stack.items.len - 1];
    }

    pub fn rectFilled(self: *DrawList, rect: Rect, col: Color) Allocator.Error!void {
        return self.rectFilledPaint(rect, .{ .solid = col });
    }

    pub fn rectFilledPaint(self: *DrawList, rect: Rect, paint: Paint) Allocator.Error!void {
        try self.cmds.append(self.alloc, .{ .rect_filled = .{
            .rect = rect,
            .paint = paint,
            .radius = 0,
            .aa = true,
            .clip = self.currentClip(),
        } });
    }

    pub fn rectFilledEx(self: *DrawList, rect: Rect, col: Color, options: RoundedRectOptions) Allocator.Error!void {
        return self.rectFilledPaintEx(rect, .{ .solid = col }, options);
    }

    pub fn rectFilledPaintEx(self: *DrawList, rect: Rect, paint: Paint, options: RoundedRectOptions) Allocator.Error!void {
        try self.cmds.append(self.alloc, .{ .rect_filled = .{
            .rect = rect,
            .paint = paint,
            .radius = options.radius,
            .aa = options.aa,
            .clip = self.currentClip(),
        } });
    }

    pub fn rectOutline(self: *DrawList, rect: Rect, col: Color, thickness: u32) Allocator.Error!void {
        try self.cmds.append(self.alloc, .{ .rect_outline = .{
            .rect = rect,
            .color = col,
            .thickness = thickness,
            .radius = 0,
            .aa = true,
            .clip = self.currentClip(),
        } });
    }

    pub fn rectOutlineEx(
        self: *DrawList,
        rect: Rect,
        col: Color,
        thickness: u32,
        options: RoundedRectOptions,
    ) Allocator.Error!void {
        try self.cmds.append(self.alloc, .{ .rect_outline = .{
            .rect = rect,
            .color = col,
            .thickness = thickness,
            .radius = options.radius,
            .aa = options.aa,
            .clip = self.currentClip(),
        } });
    }

    pub fn circleFilled(
        self: *DrawList,
        center: Vec2,
        radius: u32,
        col: Color,
        options: CircleOptions,
    ) Allocator.Error!void {
        try self.cmds.append(self.alloc, .{ .circle_filled = .{
            .center = center,
            .radius = radius,
            .color = col,
            .aa = options.aa,
            .clip = self.currentClip(),
        } });
    }

    pub fn circleOutline(
        self: *DrawList,
        center: Vec2,
        radius: u32,
        col: Color,
        thickness: u32,
        options: CircleOptions,
    ) Allocator.Error!void {
        try self.cmds.append(self.alloc, .{ .circle_outline = .{
            .center = center,
            .radius = radius,
            .color = col,
            .thickness = thickness,
            .aa = options.aa,
            .clip = self.currentClip(),
        } });
    }

    pub fn line(self: *DrawList, p0: Vec2, p1: Vec2, col: Color, thickness: u32) Allocator.Error!void {
        try self.cmds.append(self.alloc, .{ .line = .{
            .p0 = p0,
            .p1 = p1,
            .color = col,
            .thickness = thickness,
            .clip = self.currentClip(),
        } });
    }

    /// `str` must point at an arena string that outlives the DrawList.
    /// Drawn with the default font passed to `render()`.
    pub fn text(self: *DrawList, pos: Vec2, str: []const u8, col: Color) Allocator.Error!void {
        try self.textEx(pos, str, col, null);
    }

    /// Text with optional font override. null font → default font.
    pub fn textEx(self: *DrawList, pos: Vec2, str: []const u8, col: Color, font: ?Font) Allocator.Error!void {
        try self.cmds.append(self.alloc, .{ .text = .{
            .pos = pos,
            .text = str,
            .color = col,
            .clip = self.currentClip(),
            .font = font,
        } });
    }

    /// `pixels` must point at a caller-owned slice that outlives the DrawList.
    /// assert: `pixels.len == src_w * src_h`. Destination rect may differ from source (nearest).
    pub fn image(
        self: *DrawList,
        rect: Rect,
        pixels: []const u32,
        src_w: u32,
        src_h: u32,
    ) Allocator.Error!void {
        std.debug.assert(pixels.len == @as(usize, src_w) * @as(usize, src_h));
        try self.cmds.append(self.alloc, .{ .image = .{
            .rect = rect,
            .pixels = pixels,
            .src_w = src_w,
            .src_h = src_h,
            .clip = self.currentClip(),
        } });
    }

    /// Start a filled path. `arena` owns the verb and point slices; they must
    /// outlive this DrawList (the Context frame arena is the usual owner).
    pub fn beginPath(self: *DrawList, arena: Allocator) PathBuilder {
        return .{ .dl = self, .arena = arena };
    }

    /// Grow the path coverage scratch to at least `pixels` cells. Failure is
    /// a panic (same as `reset`). Capacity is kept across `reset`.
    pub fn ensurePathScratch(self: *DrawList, pixels: usize) void {
        if (pixels <= self.path_scratch_pixels) return;
        if (self.path_area.len == 0) {
            self.path_area = self.alloc.alloc(f32, pixels) catch
                @panic("DrawList.ensurePathScratch: OOM");
            self.path_cover = self.alloc.alloc(f32, pixels) catch
                @panic("DrawList.ensurePathScratch: OOM");
            self.path_coverage = self.alloc.alloc(u8, pixels) catch
                @panic("DrawList.ensurePathScratch: OOM");
        } else {
            self.path_area = self.alloc.realloc(self.path_area, pixels) catch
                @panic("DrawList.ensurePathScratch: OOM");
            self.path_cover = self.alloc.realloc(self.path_cover, pixels) catch
                @panic("DrawList.ensurePathScratch: OOM");
            self.path_coverage = self.alloc.realloc(self.path_coverage, pixels) catch
                @panic("DrawList.ensurePathScratch: OOM");
        }
        self.path_scratch_pixels = pixels;
        const used = pixels * path_scratch_bytes_per_pixel;
        if (used > self.path_scratch_peak_bytes) self.path_scratch_peak_bytes = used;
    }

    pub fn ensureCornerBand(self: *DrawList, pixels: usize) void {
        if (pixels <= self.corner_band.len) return;
        if (self.corner_band.len == 0) {
            self.corner_band = self.alloc.alloc(u8, pixels) catch
                @panic("DrawList.ensureCornerBand: OOM");
        } else {
            self.corner_band = self.alloc.realloc(self.corner_band, pixels) catch
                @panic("DrawList.ensureCornerBand: OOM");
        }
    }

    pub fn ensureLinearGradientColumns(self: *DrawList, columns: usize) []i64 {
        if (columns > self.linear_gradient_columns.len) {
            self.linear_gradient_columns = if (self.linear_gradient_columns.len == 0)
                self.alloc.alloc(i64, columns) catch @panic("DrawList linear gradient scratch: OOM")
            else
                self.alloc.realloc(self.linear_gradient_columns, columns) catch
                    @panic("DrawList linear gradient scratch: OOM");
        }
        return self.linear_gradient_columns[0..columns];
    }

    pub fn ensureRadialGradientLut(self: *DrawList) []u8 {
        if (self.radial_gradient_lut.len == 0) {
            self.radial_gradient_lut = self.alloc.alloc(u8, 1024) catch
                @panic("DrawList radial gradient LUT: OOM");
        }
        return self.radial_gradient_lut;
    }

    pub fn cornerMaskDiagnostics(self: *const DrawList) corner_mask.Diagnostics {
        return self.corner_masks.diagnostics;
    }

    /// Push clip onto the stack. Intersects with the current clip.
    pub fn pushClip(self: *DrawList, rect: Rect) Allocator.Error!void {
        const current = self.currentClip();
        const clipped = Rect.intersect(current, rect);
        try self.clip_stack.append(self.alloc, clipped);
    }

    /// Root clip cannot be popped (`assert(len > 1)`).
    pub fn popClip(self: *DrawList) void {
        std.debug.assert(self.clip_stack.items.len > 1);
        _ = self.clip_stack.pop();
    }
};

// ============================================================
// Tests
// ============================================================

test "DrawList: reset clears cmds and sets root clip (logical size)" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();

    dl.reset(800, 600);
    try std.testing.expectEqual(@as(usize, 0), dl.cmds.items.len);
    try std.testing.expectEqual(@as(usize, 1), dl.clip_stack.items.len);
    const root = dl.clip_stack.items[0];
    try std.testing.expectEqual(@as(i32, 0), root.x);
    try std.testing.expectEqual(@as(i32, 0), root.y);
    try std.testing.expectEqual(@as(u32, 800), root.w);
    try std.testing.expectEqual(@as(u32, 600), root.h);
}

test "DrawList.image: destination may differ from source size" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    const img = [_]u32{ 0xFF0000FF, 0xFF00FF00, 0xFFFF0000, 0xFFFFFFFF };
    try dl.image(.{ .x = 0, .y = 0, .w = 16, .h = 16 }, &img, 2, 2);
    try std.testing.expectEqual(@as(u32, 16), dl.cmds.items[0].image.rect.w);
    try std.testing.expectEqual(@as(u32, 2), dl.cmds.items[0].image.src_w);
    try std.testing.expectEqual(@as(u32, 2), dl.cmds.items[0].image.src_h);
}

test "DrawList: rectFilled bakes in clip" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();

    dl.reset(100, 100);
    try dl.rectFilled(.{ .x = 0, .y = 0, .w = 50, .h = 50 }, Color.rgba(0xFF, 0, 0, 0xFF));
    try std.testing.expectEqual(@as(usize, 1), dl.cmds.items.len);
    const clip = dl.cmds.items[0].rect_filled.clip;
    try std.testing.expectEqual(@as(u32, 100), clip.w);
}

test "DrawList: sharp wrappers append explicit zero-radius payloads" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(32, 32);
    try dl.rectFilled(.{ .x = 1, .y = 2, .w = 3, .h = 4 }, Color.rgba(1, 2, 3, 4));
    try dl.rectOutline(.{ .x = 5, .y = 6, .w = 7, .h = 8 }, Color.rgba(5, 6, 7, 8), 2);
    try std.testing.expectEqual(@as(u32, 0), dl.cmds.items[0].rect_filled.radius);
    try std.testing.expectEqual(@as(u32, 0), dl.cmds.items[1].rect_outline.radius);
}

test "DrawList: paint wrappers retain solid, linear, and radial payloads" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    const solid = Color.rgba(1, 2, 3, 4);
    const linear: Paint = .{ .linear = .{
        .start = .{ .x = 0, .y = 1 },
        .end = .{ .x = 32, .y = 33 },
        .start_color = solid,
        .end_color = Color.rgba(5, 6, 7, 8),
    } };
    const radial: Paint = .{ .radial = .{
        .center = .{ .x = 16, .y = 17 },
        .radius = 12,
        .inner_color = solid,
        .outer_color = Color.rgba(9, 10, 11, 12),
    } };
    try dl.rectFilled(.{ .x = 0, .y = 0, .w = 8, .h = 8 }, solid);
    try dl.rectFilledPaint(.{ .x = 8, .y = 0, .w = 8, .h = 8 }, linear);
    try dl.rectFilledPaintEx(.{ .x = 16, .y = 0, .w = 8, .h = 8 }, radial, .{ .radius = 3 });
    try std.testing.expectEqualDeep(Paint{ .solid = solid }, dl.cmds.items[0].rect_filled.paint);
    try std.testing.expectEqualDeep(linear, dl.cmds.items[1].rect_filled.paint);
    try std.testing.expectEqualDeep(radial, dl.cmds.items[2].rect_filled.paint);
}

test "DrawList: rounded and circle APIs bake options and clip" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    try dl.pushClip(.{ .x = 4, .y = 5, .w = 40, .h = 41 });
    try dl.rectFilledEx(.{ .x = 1, .y = 2, .w = 20, .h = 18 }, Color.rgba(1, 2, 3, 4), .{ .radius = 7, .aa = false });
    try dl.rectOutlineEx(.{ .x = 2, .y = 3, .w = 20, .h = 18 }, Color.rgba(5, 6, 7, 8), 3, .{ .radius = 8 });
    try dl.circleFilled(.{ .x = 20, .y = 21 }, 9, Color.rgba(9, 10, 11, 12), .{ .aa = false });
    try dl.circleOutline(.{ .x = 30, .y = 31 }, 10, Color.rgba(13, 14, 15, 16), 4, .{});
    dl.popClip();
    try std.testing.expectEqual(@as(u32, 7), dl.cmds.items[0].rect_filled.radius);
    try std.testing.expect(!dl.cmds.items[0].rect_filled.aa);
    try std.testing.expectEqual(@as(i32, 4), dl.cmds.items[0].rect_filled.clip.x);
    try std.testing.expectEqual(@as(u32, 8), dl.cmds.items[1].rect_outline.radius);
    try std.testing.expectEqual(@as(u32, 9), dl.cmds.items[2].circle_filled.radius);
    try std.testing.expect(!dl.cmds.items[2].circle_filled.aa);
    try std.testing.expectEqual(@as(u32, 4), dl.cmds.items[3].circle_outline.thickness);
}

test "DrawList: pushClip / popClip intersection" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();

    dl.reset(100, 100);
    try dl.pushClip(.{ .x = 10, .y = 10, .w = 50, .h = 50 });
    try std.testing.expectEqual(@as(usize, 2), dl.clip_stack.items.len);
    const inner = dl.clip_stack.items[1];
    try std.testing.expectEqual(@as(i32, 10), inner.x);
    try std.testing.expectEqual(@as(u32, 50), inner.w);

    // Nested clip
    try dl.pushClip(.{ .x = 20, .y = 20, .w = 100, .h = 100 });
    const nested = dl.clip_stack.items[2];
    try std.testing.expectEqual(@as(i32, 20), nested.x);
    try std.testing.expectEqual(@as(u32, 40), nested.w); // min(50-10, 100) + offset

    dl.popClip();
    try std.testing.expectEqual(@as(usize, 2), dl.clip_stack.items.len);
    dl.popClip();
    try std.testing.expectEqual(@as(usize, 1), dl.clip_stack.items.len);
}

test "DrawList: cmd bakes in clip (after pushClip)" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();

    dl.reset(200, 200);
    try dl.pushClip(.{ .x = 50, .y = 50, .w = 100, .h = 100 });
    try dl.rectFilled(.{ .x = 0, .y = 0, .w = 200, .h = 200 }, Color.rgba(0, 0xFF, 0, 0xFF));
    const clip = dl.cmds.items[0].rect_filled.clip;
    try std.testing.expectEqual(@as(i32, 50), clip.x);
    try std.testing.expectEqual(@as(u32, 100), clip.w);
    dl.popClip();
}

test "PathBuilder: finish appends one path command" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = dl.beginPath(arena.allocator());
    try b.moveTo(.{ .x = 0, .y = 0 });
    try b.lineTo(.{ .x = 10, .y = 0 });
    try b.lineTo(.{ .x = 10, .y = 10 });
    try b.close();
    try b.finish(.{ .color = Color.rgba(0xFF, 0, 0, 0xFF) });

    try std.testing.expectEqual(@as(usize, 1), dl.cmds.items.len);
    const p = dl.cmds.items[0].path;
    try std.testing.expectEqual(@as(usize, 4), p.verbs.len);
    try std.testing.expectEqual(PathVerb.move, p.verbs[0]);
    try std.testing.expectEqual(PathVerb.close, p.verbs[3]);
    try std.testing.expectEqual(@as(usize, 3), p.points.len);
    try std.testing.expect(p.aa);
    try std.testing.expectEqual(PathWinding.nonzero, p.winding);
    try std.testing.expectEqual(@as(u32, 64), p.clip.w);
}

test "PathBuilder: segment before move is InvalidPath and does not append" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = dl.beginPath(arena.allocator());
    try std.testing.expectError(error.InvalidPath, b.lineTo(.{ .x = 1, .y = 1 }));
    try std.testing.expectError(error.InvalidPath, b.finish(.{ .color = Color.rgba(0, 0, 0, 0xFF) }));
    try std.testing.expectEqual(@as(usize, 0), dl.cmds.items.len);
}

test "PathBuilder: segment after close without move is InvalidPath" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = dl.beginPath(arena.allocator());
    try b.moveTo(.{ .x = 0, .y = 0 });
    try b.lineTo(.{ .x = 4, .y = 0 });
    try b.close();
    try std.testing.expectError(error.InvalidPath, b.lineTo(.{ .x = 1, .y = 1 }));
    try std.testing.expectError(error.InvalidPath, b.finish(.{ .color = Color.rgba(0, 0, 0, 0xFF) }));
    try std.testing.expectEqual(@as(usize, 0), dl.cmds.items.len);
}

test "PathBuilder: non-finite coordinate is InvalidPath and does not append" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = dl.beginPath(arena.allocator());
    try std.testing.expectError(error.InvalidPath, b.moveTo(.{ .x = std.math.nan(f32), .y = 0 }));
    try std.testing.expectError(error.InvalidPath, b.finish(.{ .color = Color.rgba(0, 0, 0, 0xFF) }));
    try std.testing.expectEqual(@as(usize, 0), dl.cmds.items.len);

    var b2 = dl.beginPath(arena.allocator());
    try b2.moveTo(.{ .x = 0, .y = 0 });
    try std.testing.expectError(error.InvalidPath, b2.lineTo(.{ .x = std.math.inf(f32), .y = 1 }));
    try std.testing.expectError(error.InvalidPath, b2.finish(.{ .color = Color.rgba(0, 0, 0, 0xFF) }));
    try std.testing.expectEqual(@as(usize, 0), dl.cmds.items.len);
}

test "PathBuilder: several moves are several contours" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = dl.beginPath(arena.allocator());
    try b.moveTo(.{ .x = 0, .y = 0 });
    try b.lineTo(.{ .x = 4, .y = 0 });
    try b.lineTo(.{ .x = 0, .y = 4 });
    try b.moveTo(.{ .x = 8, .y = 8 });
    try b.lineTo(.{ .x = 12, .y = 8 });
    try b.lineTo(.{ .x = 8, .y = 12 });
    try b.finish(.{ .color = Color.rgba(0, 0xFF, 0, 0xFF), .aa = false });
    try std.testing.expectEqual(@as(usize, 1), dl.cmds.items.len);
    const p = dl.cmds.items[0].path;
    try std.testing.expectEqual(@as(usize, 6), p.verbs.len);
    try std.testing.expectEqual(PathVerb.move, p.verbs[0]);
    try std.testing.expectEqual(PathVerb.move, p.verbs[3]);
    try std.testing.expect(!p.aa);
}

test "validatePathSequence: line before move and segment after close are InvalidPath" {
    try std.testing.expectError(error.InvalidPath, validatePathSequence(&.{ .line, .move, .line }));
    try std.testing.expectError(error.InvalidPath, validatePathSequence(&.{ .close, .line }));
    try std.testing.expectError(error.InvalidPath, validatePathSequence(&.{ .move, .close, .line }));
    try validatePathSequence(&.{ .move, .line, .close, .move, .line });
    try validatePathSequence(&.{});
}

test "PathBuilder: stroke appends params; non-finite or non-positive width is InvalidPath" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var ok = dl.beginPath(arena.allocator());
    try ok.moveTo(.{ .x = 0, .y = 0 });
    try ok.lineTo(.{ .x = 8, .y = 0 });
    try ok.stroke(.{
        .color = Color.rgba(0, 0, 0xFF, 0xFF),
        .width = 3,
        .join = .bevel,
        .cap = .square,
        .miter_limit = 2,
        .aa = false,
    });
    try std.testing.expectEqual(@as(usize, 1), dl.cmds.items.len);
    const s = dl.cmds.items[0].path.stroke.?;
    try std.testing.expectEqual(@as(f32, 3), s.width);
    try std.testing.expectEqual(PathJoin.bevel, s.join);
    try std.testing.expectEqual(PathCap.square, s.cap);
    try std.testing.expectEqual(@as(f32, 2), s.miter_limit);
    try std.testing.expect(!dl.cmds.items[0].path.aa);

    var bad = dl.beginPath(arena.allocator());
    try bad.moveTo(.{ .x = 0, .y = 0 });
    try bad.lineTo(.{ .x = 1, .y = 0 });
    try std.testing.expectError(error.InvalidPath, bad.stroke(.{
        .color = Color.rgba(0, 0, 0, 0xFF),
        .width = 0,
    }));
    try std.testing.expectEqual(@as(usize, 1), dl.cmds.items.len);

    var nan_w = dl.beginPath(arena.allocator());
    try nan_w.moveTo(.{ .x = 0, .y = 0 });
    try nan_w.lineTo(.{ .x = 1, .y = 0 });
    try std.testing.expectError(error.InvalidPath, nan_w.stroke(.{
        .color = Color.rgba(0, 0, 0, 0xFF),
        .width = std.math.nan(f32),
    }));

    var bad_limit = dl.beginPath(arena.allocator());
    try bad_limit.moveTo(.{ .x = 0, .y = 0 });
    try bad_limit.lineTo(.{ .x = 1, .y = 0 });
    try std.testing.expectError(error.InvalidPath, bad_limit.stroke(.{
        .color = Color.rgba(0, 0, 0, 0xFF),
        .width = 1,
        .miter_limit = 0.5,
    }));
    try std.testing.expectEqual(@as(usize, 1), dl.cmds.items.len);
}
