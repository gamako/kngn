//! Shared text form of a `DrawCmd`: one command per line, `k=v` pairs, space separated.
//!
//! The verb table (`verbs`) is the single list of command names and field columns. The
//! serializer (`appendCmd`) and the parser (`parseDump` / `parseCmdLine`) both look that
//! table up, so adding a verb is a table edit plus the `DrawCmd` payload that goes with
//! it — the parser does not keep a second, silent vocabulary. An unknown verb is an
//! explicit error, never dropped.
//!
//! Hot path declaration: every function here runs at event time only (a probe dump, an
//! overlay inject or clear). Nothing walks pixels per frame or samples per tick.

const std = @import("std");
const Allocator = std.mem.Allocator;
const draw_mod = @import("draw.zig");
const geom = @import("geom.zig");
const wire = @import("drawlist_wire.zig");

pub const DrawCmd = draw_mod.DrawCmd;
pub const DrawList = draw_mod.DrawList;
pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const Color = draw_mod.Color;
pub const PathVerb = draw_mod.PathVerb;
pub const PathWinding = draw_mod.PathWinding;
pub const PathJoin = draw_mod.PathJoin;
pub const PathCap = draw_mod.PathCap;
pub const Vec2f = draw_mod.Vec2f;
pub const Paint = draw_mod.Paint;

/// How many overlay commands a single inject may install. Sized so a full list still
/// fits inside the copilot/harness 64 KiB wire limit at the current per-line width.
pub const MAX_CMDS = 256;

/// Inclusive coordinate range the parser accepts. Same values as `geom`: the
/// renderer-wide DrawCmd domain.
pub const MAX_COORD: i32 = geom.MAX_COORD;
pub const MIN_COORD: i32 = geom.MIN_COORD;

/// Maximum `w` / `h` / `clip_w` / `clip_h`. Same value as `geom.MAX_EXTENT`.
pub const MAX_EXTENT: u32 = geom.MAX_EXTENT;

/// Maximum stroke / outline thickness. Same value as `geom.MAX_THICKNESS`.
pub const MAX_THICKNESS: u32 = geom.MAX_THICKNESS;

/// Clip used when a command omits `clip_*`. Large enough that a typical window is
/// fully inside it, so an annotation that does not name a clip is still drawn.
pub const default_clip = Rect{ .x = 0, .y = 0, .w = 65535, .h = 65535 };

pub const ParseError = error{
    UnknownVerb,
    UnknownField,
    MissingField,
    DuplicateField,
    InvalidValue,
    UnterminatedString,
    InvalidEscape,
    InvalidUtf8,
    TooManyCommands,
    EmptyCommand,
    EmptyInput,
    MalformedInput,
    HeaderCountMismatch,
    ImagePayloadUnavailable,
    FontNotRestorable,
    ValueOutOfRange,
    InvalidPath,
    TooManyVerbs,
    TooManyPoints,
};

pub const FieldRole = enum {
    i32,
    u32,
    color,
    font,
    text,
    /// Written by the serializer; accepted and ignored by the parser (a derived
    /// value such as `offclip` or `pixfnv`, not a `DrawCmd` field).
    derived,
    /// Path winding name (`nonzero`).
    winding,
    /// Path paint style (`fill` or `stroke`).
    path_style,
    /// Stroke join name (`miter` or `bevel`).
    path_join,
    /// Stroke cap name (`butt`, `square`, or `round`).
    path_cap,
    /// Finite f32 (stroke width / miter limit).
    f32,
    /// Compact path-verb string (`MLQCZ`).
    path_verbs,
    /// Path points as comma-separated IEEE-754 hex bits (`xxxxxxxx,yyyyyyyy,...`).
    path_points,
    paint,
    paint_color,
    paint_f32,
};

pub const FieldSpec = struct {
    name: []const u8,
    role: FieldRole,
    required: bool = true,
};

pub const VerbSpec = struct {
    name: []const u8,
    tag: std.meta.Tag(DrawCmd),
    fields: []const FieldSpec,
};

/// The verb table. Field order is the on-the-wire order. Both `appendCmd` and the
/// parser walk this list; they do not keep a private copy of the names.
pub const verbs = [_]VerbSpec{
    .{
        .name = "rect_filled",
        .tag = .rect_filled,
        .fields = &.{
            .{ .name = "x", .role = .i32 },
            .{ .name = "y", .role = .i32 },
            .{ .name = "w", .role = .u32 },
            .{ .name = "h", .role = .u32 },
            .{ .name = "color", .role = .color, .required = false },
            .{ .name = "paint", .role = .paint, .required = false },
            .{ .name = "from", .role = .paint_color, .required = false },
            .{ .name = "to", .role = .paint_color, .required = false },
            .{ .name = "x0", .role = .paint_f32, .required = false },
            .{ .name = "y0", .role = .paint_f32, .required = false },
            .{ .name = "x1", .role = .paint_f32, .required = false },
            .{ .name = "y1", .role = .paint_f32, .required = false },
            .{ .name = "inner", .role = .paint_color, .required = false },
            .{ .name = "outer", .role = .paint_color, .required = false },
            .{ .name = "cx", .role = .paint_f32, .required = false },
            .{ .name = "cy", .role = .paint_f32, .required = false },
            .{ .name = "gr", .role = .paint_f32, .required = false },
            .{ .name = "radius", .role = .u32, .required = false },
            .{ .name = "aa", .role = .u32, .required = false },
            .{ .name = "clip_x", .role = .i32, .required = false },
            .{ .name = "clip_y", .role = .i32, .required = false },
            .{ .name = "clip_w", .role = .u32, .required = false },
            .{ .name = "clip_h", .role = .u32, .required = false },
            .{ .name = "offclip", .role = .derived, .required = false },
        },
    },
    .{
        .name = "rect_outline",
        .tag = .rect_outline,
        .fields = &.{
            .{ .name = "x", .role = .i32 },
            .{ .name = "y", .role = .i32 },
            .{ .name = "w", .role = .u32 },
            .{ .name = "h", .role = .u32 },
            .{ .name = "thickness", .role = .u32 },
            .{ .name = "color", .role = .color },
            .{ .name = "radius", .role = .u32, .required = false },
            .{ .name = "aa", .role = .u32, .required = false },
            .{ .name = "clip_x", .role = .i32, .required = false },
            .{ .name = "clip_y", .role = .i32, .required = false },
            .{ .name = "clip_w", .role = .u32, .required = false },
            .{ .name = "clip_h", .role = .u32, .required = false },
            .{ .name = "offclip", .role = .derived, .required = false },
        },
    },
    .{
        .name = "circle_filled",
        .tag = .circle_filled,
        .fields = &.{
            .{ .name = "x", .role = .i32 },
            .{ .name = "y", .role = .i32 },
            .{ .name = "radius", .role = .u32 },
            .{ .name = "color", .role = .color },
            .{ .name = "aa", .role = .u32, .required = false },
            .{ .name = "clip_x", .role = .i32, .required = false },
            .{ .name = "clip_y", .role = .i32, .required = false },
            .{ .name = "clip_w", .role = .u32, .required = false },
            .{ .name = "clip_h", .role = .u32, .required = false },
            .{ .name = "offclip", .role = .derived, .required = false },
        },
    },
    .{
        .name = "circle_outline",
        .tag = .circle_outline,
        .fields = &.{
            .{ .name = "x", .role = .i32 },
            .{ .name = "y", .role = .i32 },
            .{ .name = "radius", .role = .u32 },
            .{ .name = "thickness", .role = .u32 },
            .{ .name = "color", .role = .color },
            .{ .name = "aa", .role = .u32, .required = false },
            .{ .name = "clip_x", .role = .i32, .required = false },
            .{ .name = "clip_y", .role = .i32, .required = false },
            .{ .name = "clip_w", .role = .u32, .required = false },
            .{ .name = "clip_h", .role = .u32, .required = false },
            .{ .name = "offclip", .role = .derived, .required = false },
        },
    },
    .{
        .name = "line",
        .tag = .line,
        .fields = &.{
            .{ .name = "x0", .role = .i32 },
            .{ .name = "y0", .role = .i32 },
            .{ .name = "x1", .role = .i32 },
            .{ .name = "y1", .role = .i32 },
            .{ .name = "thickness", .role = .u32 },
            .{ .name = "color", .role = .color },
            .{ .name = "clip_x", .role = .i32, .required = false },
            .{ .name = "clip_y", .role = .i32, .required = false },
            .{ .name = "clip_w", .role = .u32, .required = false },
            .{ .name = "clip_h", .role = .u32, .required = false },
            .{ .name = "offclip", .role = .derived, .required = false },
        },
    },
    .{
        .name = "text",
        .tag = .text,
        .fields = &.{
            .{ .name = "x", .role = .i32 },
            .{ .name = "y", .role = .i32 },
            .{ .name = "color", .role = .color },
            .{ .name = "font", .role = .font, .required = false },
            .{ .name = "clip_x", .role = .i32, .required = false },
            .{ .name = "clip_y", .role = .i32, .required = false },
            .{ .name = "clip_w", .role = .u32, .required = false },
            .{ .name = "clip_h", .role = .u32, .required = false },
            .{ .name = "offclip", .role = .derived, .required = false },
            .{ .name = "text", .role = .text },
        },
    },
    .{
        .name = "image",
        .tag = .image,
        .fields = &.{
            .{ .name = "x", .role = .i32 },
            .{ .name = "y", .role = .i32 },
            .{ .name = "w", .role = .u32 },
            .{ .name = "h", .role = .u32 },
            .{ .name = "src_w", .role = .u32 },
            .{ .name = "src_h", .role = .u32 },
            .{ .name = "pixfnv", .role = .derived, .required = false },
            .{ .name = "clip_x", .role = .i32, .required = false },
            .{ .name = "clip_y", .role = .i32, .required = false },
            .{ .name = "clip_w", .role = .u32, .required = false },
            .{ .name = "clip_h", .role = .u32, .required = false },
            .{ .name = "offclip", .role = .derived, .required = false },
        },
    },
    .{
        .name = "path",
        .tag = .path,
        .fields = &.{
            .{ .name = "color", .role = .color },
            .{ .name = "aa", .role = .u32 },
            .{ .name = "winding", .role = .winding },
            .{ .name = "style", .role = .path_style, .required = false },
            .{ .name = "width", .role = .f32, .required = false },
            .{ .name = "join", .role = .path_join, .required = false },
            .{ .name = "cap", .role = .path_cap, .required = false },
            .{ .name = "miter_limit", .role = .f32, .required = false },
            .{ .name = "verbs", .role = .path_verbs },
            .{ .name = "pts", .role = .path_points },
            .{ .name = "clip_x", .role = .i32, .required = false },
            .{ .name = "clip_y", .role = .i32, .required = false },
            .{ .name = "clip_w", .role = .u32, .required = false },
            .{ .name = "clip_h", .role = .u32, .required = false },
            .{ .name = "offclip", .role = .derived, .required = false },
        },
    },
};

comptime {
    const tags = std.meta.tags(std.meta.Tag(DrawCmd));
    if (tags.len != verbs.len) {
        @compileError("draw_cmd_text.verbs must have one entry per DrawCmd tag");
    }
    for (tags) |tag| {
        var found = false;
        for (verbs) |v| {
            if (v.tag == tag) found = true;
        }
        if (!found) {
            @compileError("draw_cmd_text.verbs is missing " ++ @tagName(tag));
        }
    }
}

pub fn verbByName(name: []const u8) ?*const VerbSpec {
    for (&verbs) |*v| {
        if (std.mem.eql(u8, v.name, name)) return v;
    }
    return null;
}

pub fn verbByTag(tag: std.meta.Tag(DrawCmd)) *const VerbSpec {
    for (&verbs) |*v| {
        if (v.tag == tag) return v;
    }
    unreachable;
}

fn rectFullyInside(r: Rect, clip: Rect) bool {
    const inter = Rect.intersect(r, clip);
    return inter.x == r.x and inter.y == r.y and inter.w == r.w and inter.h == r.h;
}

pub fn colorBits(c: Color) u32 {
    return @bitCast(c);
}

pub fn colorFromBits(bits: u32) Color {
    return @bitCast(bits);
}

pub fn offclipOf(cmd: DrawCmd) u32 {
    return switch (cmd) {
        .rect_filled => |c| @intFromBool(!rectFullyInside(c.rect, c.clip)),
        .rect_outline => |c| @intFromBool(!rectFullyInside(c.rect, c.clip)),
        .circle_filled => |c| @intFromBool(!rectFullyInside(circleBounds(c.center, c.radius), c.clip)),
        .circle_outline => |c| @intFromBool(!rectFullyInside(circleBounds(c.center, c.radius), c.clip)),
        .line => |c| @intFromBool(!(c.clip.contains(c.p0) and c.clip.contains(c.p1))),
        .text => |c| @intFromBool(!c.clip.contains(c.pos)),
        .image => |c| @intFromBool(!rectFullyInside(c.rect, c.clip)),
        .path => |c| @intFromBool(!pathPointsInsideClip(c.points, c.clip)),
    };
}

fn circleBounds(center: Vec2, radius: u32) Rect {
    const r: i32 = @intCast(radius);
    return .{ .x = center.x - r, .y = center.y - r, .w = radius * 2, .h = radius * 2 };
}

fn pathPointsInsideClip(points: []const Vec2f, clip: Rect) bool {
    if (points.len == 0) return true;
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    for (points) |p| {
        min_x = @min(min_x, p.x);
        min_y = @min(min_y, p.y);
        max_x = @max(max_x, p.x);
        max_y = @max(max_y, p.y);
    }
    const x0: i32 = @intFromFloat(@floor(min_x));
    const y0: i32 = @intFromFloat(@floor(min_y));
    const x1: i32 = @intFromFloat(@ceil(max_x));
    const y1: i32 = @intFromFloat(@ceil(max_y));
    const w: u32 = if (x1 > x0) @intCast(x1 - x0) else 0;
    const h: u32 = if (y1 > y0) @intCast(y1 - y0) else 0;
    return rectFullyInside(.{ .x = x0, .y = y0, .w = w, .h = h }, clip);
}

fn pixfnvOf(cmd: DrawCmd) u32 {
    return switch (cmd) {
        .image => |c| std.hash.Fnv1a_32.hash(std.mem.sliceAsBytes(c.pixels)),
        else => 0,
    };
}

fn readI32(cmd: DrawCmd, name: []const u8) i32 {
    return switch (cmd) {
        .rect_filled => |c| if (std.mem.eql(u8, name, "x"))
            c.rect.x
        else if (std.mem.eql(u8, name, "y"))
            c.rect.y
        else if (std.mem.eql(u8, name, "clip_x"))
            c.clip.x
        else if (std.mem.eql(u8, name, "clip_y"))
            c.clip.y
        else
            unreachable,
        .rect_outline => |c| if (std.mem.eql(u8, name, "x"))
            c.rect.x
        else if (std.mem.eql(u8, name, "y"))
            c.rect.y
        else if (std.mem.eql(u8, name, "clip_x"))
            c.clip.x
        else if (std.mem.eql(u8, name, "clip_y"))
            c.clip.y
        else
            unreachable,
        .circle_filled => |c| if (std.mem.eql(u8, name, "x"))
            c.center.x
        else if (std.mem.eql(u8, name, "y"))
            c.center.y
        else if (std.mem.eql(u8, name, "clip_x"))
            c.clip.x
        else if (std.mem.eql(u8, name, "clip_y"))
            c.clip.y
        else
            unreachable,
        .circle_outline => |c| if (std.mem.eql(u8, name, "x"))
            c.center.x
        else if (std.mem.eql(u8, name, "y"))
            c.center.y
        else if (std.mem.eql(u8, name, "clip_x"))
            c.clip.x
        else if (std.mem.eql(u8, name, "clip_y"))
            c.clip.y
        else
            unreachable,
        .line => |c| if (std.mem.eql(u8, name, "x0"))
            c.p0.x
        else if (std.mem.eql(u8, name, "y0"))
            c.p0.y
        else if (std.mem.eql(u8, name, "x1"))
            c.p1.x
        else if (std.mem.eql(u8, name, "y1"))
            c.p1.y
        else if (std.mem.eql(u8, name, "clip_x"))
            c.clip.x
        else if (std.mem.eql(u8, name, "clip_y"))
            c.clip.y
        else
            unreachable,
        .text => |c| if (std.mem.eql(u8, name, "x"))
            c.pos.x
        else if (std.mem.eql(u8, name, "y"))
            c.pos.y
        else if (std.mem.eql(u8, name, "clip_x"))
            c.clip.x
        else if (std.mem.eql(u8, name, "clip_y"))
            c.clip.y
        else
            unreachable,
        .image => |c| if (std.mem.eql(u8, name, "x"))
            c.rect.x
        else if (std.mem.eql(u8, name, "y"))
            c.rect.y
        else if (std.mem.eql(u8, name, "clip_x"))
            c.clip.x
        else if (std.mem.eql(u8, name, "clip_y"))
            c.clip.y
        else
            unreachable,
        .path => |c| if (std.mem.eql(u8, name, "clip_x"))
            c.clip.x
        else if (std.mem.eql(u8, name, "clip_y"))
            c.clip.y
        else
            unreachable,
    };
}

fn readU32(cmd: DrawCmd, name: []const u8) u32 {
    return switch (cmd) {
        .rect_filled => |c| if (std.mem.eql(u8, name, "w"))
            c.rect.w
        else if (std.mem.eql(u8, name, "h"))
            c.rect.h
        else if (std.mem.eql(u8, name, "radius"))
            c.radius
        else if (std.mem.eql(u8, name, "aa"))
            @intFromBool(c.aa)
        else if (std.mem.eql(u8, name, "clip_w"))
            c.clip.w
        else if (std.mem.eql(u8, name, "clip_h"))
            c.clip.h
        else
            unreachable,
        .rect_outline => |c| if (std.mem.eql(u8, name, "w"))
            c.rect.w
        else if (std.mem.eql(u8, name, "h"))
            c.rect.h
        else if (std.mem.eql(u8, name, "thickness"))
            c.thickness
        else if (std.mem.eql(u8, name, "radius"))
            c.radius
        else if (std.mem.eql(u8, name, "aa"))
            @intFromBool(c.aa)
        else if (std.mem.eql(u8, name, "clip_w"))
            c.clip.w
        else if (std.mem.eql(u8, name, "clip_h"))
            c.clip.h
        else
            unreachable,
        .circle_filled => |c| if (std.mem.eql(u8, name, "radius"))
            c.radius
        else if (std.mem.eql(u8, name, "aa"))
            @intFromBool(c.aa)
        else if (std.mem.eql(u8, name, "clip_w"))
            c.clip.w
        else if (std.mem.eql(u8, name, "clip_h"))
            c.clip.h
        else
            unreachable,
        .circle_outline => |c| if (std.mem.eql(u8, name, "radius"))
            c.radius
        else if (std.mem.eql(u8, name, "thickness"))
            c.thickness
        else if (std.mem.eql(u8, name, "aa"))
            @intFromBool(c.aa)
        else if (std.mem.eql(u8, name, "clip_w"))
            c.clip.w
        else if (std.mem.eql(u8, name, "clip_h"))
            c.clip.h
        else
            unreachable,
        .line => |c| if (std.mem.eql(u8, name, "thickness"))
            c.thickness
        else if (std.mem.eql(u8, name, "clip_w"))
            c.clip.w
        else if (std.mem.eql(u8, name, "clip_h"))
            c.clip.h
        else
            unreachable,
        .text => |c| if (std.mem.eql(u8, name, "clip_w"))
            c.clip.w
        else if (std.mem.eql(u8, name, "clip_h"))
            c.clip.h
        else
            unreachable,
        .image => |c| if (std.mem.eql(u8, name, "w"))
            c.rect.w
        else if (std.mem.eql(u8, name, "h"))
            c.rect.h
        else if (std.mem.eql(u8, name, "src_w"))
            c.src_w
        else if (std.mem.eql(u8, name, "src_h"))
            c.src_h
        else if (std.mem.eql(u8, name, "clip_w"))
            c.clip.w
        else if (std.mem.eql(u8, name, "clip_h"))
            c.clip.h
        else
            unreachable,
        .path => |c| if (std.mem.eql(u8, name, "aa"))
            @intFromBool(c.aa)
        else if (std.mem.eql(u8, name, "clip_w"))
            c.clip.w
        else if (std.mem.eql(u8, name, "clip_h"))
            c.clip.h
        else
            unreachable,
    };
}

fn readColor(cmd: DrawCmd) u32 {
    return switch (cmd) {
        .rect_filled => |c| switch (c.paint) {
            .solid => |color| colorBits(color),
            else => 0,
        },
        .rect_outline => |c| colorBits(c.color),
        .circle_filled => |c| colorBits(c.color),
        .circle_outline => |c| colorBits(c.color),
        .line => |c| colorBits(c.color),
        .text => |c| colorBits(c.color),
        .image => 0,
        .path => |c| colorBits(c.color),
    };
}

fn readPaintName(cmd: DrawCmd) []const u8 {
    return switch (cmd) {
        .rect_filled => |c| switch (c.paint) {
            .solid => "solid",
            .linear => "linear",
            .radial => "radial",
        },
        else => unreachable,
    };
}

fn readPaintColor(cmd: DrawCmd, name: []const u8) u32 {
    return switch (cmd) {
        .rect_filled => |c| switch (c.paint) {
            .linear => |g| if (std.mem.eql(u8, name, "from"))
                colorBits(g.start_color)
            else
                colorBits(g.end_color),
            .radial => |g| if (std.mem.eql(u8, name, "inner"))
                colorBits(g.inner_color)
            else
                colorBits(g.outer_color),
            .solid => unreachable,
        },
        else => unreachable,
    };
}

fn readPaintF32(cmd: DrawCmd, name: []const u8) f32 {
    return switch (cmd) {
        .rect_filled => |c| switch (c.paint) {
            .linear => |g| if (std.mem.eql(u8, name, "x0"))
                g.start.x
            else if (std.mem.eql(u8, name, "y0"))
                g.start.y
            else if (std.mem.eql(u8, name, "x1"))
                g.end.x
            else
                g.end.y,
            .radial => |g| if (std.mem.eql(u8, name, "cx"))
                g.center.x
            else if (std.mem.eql(u8, name, "cy"))
                g.center.y
            else
                g.radius,
            .solid => unreachable,
        },
        else => unreachable,
    };
}

fn readFont(cmd: DrawCmd) []const u8 {
    return switch (cmd) {
        .text => |c| if (c.font == null) "default" else "custom",
        else => "default",
    };
}

fn readText(cmd: DrawCmd) []const u8 {
    return switch (cmd) {
        .text => |c| c.text,
        else => "",
    };
}

fn windingName(cmd: DrawCmd) []const u8 {
    return switch (cmd) {
        .path => |c| switch (c.winding) {
            .nonzero => "nonzero",
        },
        else => "nonzero",
    };
}

fn styleName(cmd: DrawCmd) []const u8 {
    return switch (cmd) {
        .path => |c| if (c.stroke != null) "stroke" else "fill",
        else => "fill",
    };
}

fn joinName(cmd: DrawCmd) []const u8 {
    return switch (cmd) {
        .path => |c| draw_mod.pathJoinName(if (c.stroke) |s| s.join else .miter),
        else => "miter",
    };
}

fn capName(cmd: DrawCmd) []const u8 {
    return switch (cmd) {
        .path => |c| draw_mod.pathCapName(if (c.stroke) |s| s.cap else .butt),
        else => "butt",
    };
}

fn readF32(cmd: DrawCmd, name: []const u8) f32 {
    return switch (cmd) {
        .path => |c| if (std.mem.eql(u8, name, "width"))
            if (c.stroke) |s| s.width else 0
        else if (std.mem.eql(u8, name, "miter_limit"))
            if (c.stroke) |s| s.miter_limit else draw_mod.path_miter_limit_default
        else
            unreachable,
        else => 0,
    };
}

fn appendPathVerbs(list: *std.ArrayList(u8), allocator: Allocator, cmd: DrawCmd) !void {
    const path_verbs = switch (cmd) {
        .path => |c| c.verbs,
        else => return,
    };
    for (path_verbs) |v| try list.append(allocator, v.letter());
}

fn appendPathPoints(list: *std.ArrayList(u8), allocator: Allocator, cmd: DrawCmd) !void {
    const points = switch (cmd) {
        .path => |c| c.points,
        else => return,
    };
    for (points, 0..) |p, i| {
        if (i != 0) try list.append(allocator, ',');
        const xb: u32 = @bitCast(p.x);
        const yb: u32 = @bitCast(p.y);
        try appendFmt(list, allocator, "{x:0>8},{x:0>8}", .{ xb, yb });
    }
}

/// Appends a value formatted with `fmt` to `list`.
pub fn appendFmt(list: *std.ArrayList(u8), allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
    var tmp: [128]u8 = undefined;
    if (std.fmt.bufPrint(&tmp, fmt, args)) |s| {
        try list.appendSlice(allocator, s);
    } else |_| {
        const s = try std.fmt.allocPrint(allocator, fmt, args);
        defer allocator.free(s);
        try list.appendSlice(allocator, s);
    }
}

/// Appends `s` as a double-quoted, escaped token (so a `text` field with a space or a
/// quote inside it does not break the one-line-per-command contract).
pub fn appendEscapedText(list: *std.ArrayList(u8), allocator: Allocator, s: []const u8) !void {
    try list.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    try appendFmt(list, allocator, "\\u{x:0>4}", .{c});
                } else {
                    try list.append(allocator, c);
                }
            },
        }
    }
    try list.append(allocator, '"');
}

/// Writes one command line (including the trailing newline) by walking `verbs`.
pub fn appendCmd(list: *std.ArrayList(u8), allocator: Allocator, cmd: DrawCmd) !void {
    const verb = verbByTag(cmd);
    try appendFmt(list, allocator, "cmd={s}", .{verb.name});
    for (verb.fields) |field| {
        if (!shouldEmitField(cmd, field)) continue;
        try list.append(allocator, ' ');
        switch (field.role) {
            .i32 => try appendFmt(list, allocator, "{s}={d}", .{ field.name, readI32(cmd, field.name) }),
            .u32 => try appendFmt(list, allocator, "{s}={d}", .{ field.name, readU32(cmd, field.name) }),
            .color => try appendFmt(list, allocator, "{s}=#{X:0>8}", .{ field.name, readColor(cmd) }),
            .font => try appendFmt(list, allocator, "{s}={s}", .{ field.name, readFont(cmd) }),
            .text => {
                try appendFmt(list, allocator, "{s}=", .{field.name});
                try appendEscapedText(list, allocator, readText(cmd));
            },
            .derived => {
                if (std.mem.eql(u8, field.name, "offclip")) {
                    try appendFmt(list, allocator, "{s}={d}", .{ field.name, offclipOf(cmd) });
                } else if (std.mem.eql(u8, field.name, "pixfnv")) {
                    try appendFmt(list, allocator, "{s}=#{X:0>8}", .{ field.name, pixfnvOf(cmd) });
                } else {
                    try appendFmt(list, allocator, "{s}=0", .{field.name});
                }
            },
            .winding => try appendFmt(list, allocator, "{s}={s}", .{ field.name, windingName(cmd) }),
            .path_style => try appendFmt(list, allocator, "{s}={s}", .{ field.name, styleName(cmd) }),
            .path_join => try appendFmt(list, allocator, "{s}={s}", .{ field.name, joinName(cmd) }),
            .path_cap => try appendFmt(list, allocator, "{s}={s}", .{ field.name, capName(cmd) }),
            .f32 => try appendFmt(list, allocator, "{s}={d}", .{ field.name, readF32(cmd, field.name) }),
            .paint => try appendFmt(list, allocator, "{s}={s}", .{ field.name, readPaintName(cmd) }),
            .paint_color => try appendFmt(list, allocator, "{s}=#{X:0>8}", .{ field.name, readPaintColor(cmd, field.name) }),
            .paint_f32 => try appendFmt(list, allocator, "{s}={X:0>8}", .{ field.name, @as(u32, @bitCast(readPaintF32(cmd, field.name))) }),
            .path_verbs => {
                try appendFmt(list, allocator, "{s}=\"", .{field.name});
                try appendPathVerbs(list, allocator, cmd);
                try list.append(allocator, '"');
            },
            .path_points => {
                try appendFmt(list, allocator, "{s}=\"", .{field.name});
                try appendPathPoints(list, allocator, cmd);
                try list.append(allocator, '"');
            },
        }
    }
    try list.append(allocator, '\n');
}

fn shouldEmitField(cmd: DrawCmd, field: FieldSpec) bool {
    if (cmd == .rect_filled) {
        const paint = cmd.rect_filled.paint;
        if (std.mem.eql(u8, field.name, "color")) return paint == .solid;
        if (std.mem.eql(u8, field.name, "paint")) return paint != .solid;
        if (field.role == .paint_color or field.role == .paint_f32) {
            return switch (paint) {
                .solid => false,
                .linear => std.mem.eql(u8, field.name, "from") or std.mem.eql(u8, field.name, "to") or
                    std.mem.eql(u8, field.name, "x0") or std.mem.eql(u8, field.name, "y0") or
                    std.mem.eql(u8, field.name, "x1") or std.mem.eql(u8, field.name, "y1"),
                .radial => std.mem.eql(u8, field.name, "inner") or std.mem.eql(u8, field.name, "outer") or
                    std.mem.eql(u8, field.name, "cx") or std.mem.eql(u8, field.name, "cy") or
                    std.mem.eql(u8, field.name, "gr"),
            };
        }
    }
    if (std.mem.eql(u8, field.name, "radius")) {
        return switch (cmd) {
            .rect_filled => |c| c.radius != 0,
            .rect_outline => |c| c.radius != 0,
            .circle_filled, .circle_outline => true,
            else => true,
        };
    }
    if (std.mem.eql(u8, field.name, "aa")) {
        return switch (cmd) {
            .rect_filled => |c| c.radius != 0 and !c.aa,
            .rect_outline => |c| c.radius != 0 and !c.aa,
            .circle_filled => |c| !c.aa,
            .circle_outline => |c| !c.aa,
            else => true,
        };
    }
    return true;
}

const Pair = struct { key: []const u8, value: []const u8 };

fn skipWs(s: []const u8, i: *usize) void {
    while (i.* < s.len and (s[i.*] == ' ' or s[i.*] == '\t')) i.* += 1;
}

fn nextPair(line: []const u8, i: *usize) ParseError!?Pair {
    skipWs(line, i);
    if (i.* >= line.len) return null;
    const key_start = i.*;
    while (i.* < line.len and line[i.*] != '=') i.* += 1;
    if (i.* >= line.len or i.* == key_start) return error.InvalidValue;
    const key = line[key_start..i.*];
    i.* += 1;
    if (i.* >= line.len) return error.InvalidValue;
    if (line[i.*] == '"') {
        i.* += 1;
        const val_start = i.*;
        var escaped = false;
        while (i.* < line.len) {
            const c = line[i.*];
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                const raw = line[val_start..i.*];
                i.* += 1;
                return .{ .key = key, .value = raw };
            }
            i.* += 1;
        }
        return error.UnterminatedString;
    }
    const val_start = i.*;
    while (i.* < line.len and line[i.*] != ' ' and line[i.*] != '\t') i.* += 1;
    return .{ .key = key, .value = line[val_start..i.*] };
}

fn unescape(allocator: Allocator, raw: []const u8) (ParseError || Allocator.Error)![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '\\') {
            try out.append(allocator, raw[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= raw.len) return error.InvalidEscape;
        switch (raw[i]) {
            '"' => try out.append(allocator, '"'),
            '\\' => try out.append(allocator, '\\'),
            'n' => try out.append(allocator, '\n'),
            'r' => try out.append(allocator, '\r'),
            't' => try out.append(allocator, '\t'),
            'u' => {
                i += 1;
                if (i + 4 > raw.len) return error.InvalidEscape;
                const code = std.fmt.parseUnsigned(u8, raw[i..][0..4], 16) catch return error.InvalidEscape;
                try out.append(allocator, code);
                i += 3;
            },
            else => return error.InvalidEscape,
        }
        i += 1;
    }
    const owned = try out.toOwnedSlice(allocator);
    if (!std.unicode.utf8ValidateSlice(owned)) {
        allocator.free(owned);
        return error.InvalidUtf8;
    }
    return owned;
}

fn parseIntI32(s: []const u8) ParseError!i32 {
    return std.fmt.parseInt(i32, s, 10) catch error.InvalidValue;
}

fn parseIntU32(s: []const u8) ParseError!u32 {
    return std.fmt.parseUnsigned(u32, s, 10) catch error.InvalidValue;
}

fn parseColorBits(s: []const u8) ParseError!u32 {
    const hex = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (hex.len != 8) return error.InvalidValue;
    return std.fmt.parseUnsigned(u32, hex, 16) catch error.InvalidValue;
}

fn parsePaintF32(s: []const u8) ParseError!f32 {
    if (s.len != 8) return error.InvalidValue;
    const bits = std.fmt.parseUnsigned(u32, s, 16) catch return error.InvalidValue;
    const value: f32 = @bitCast(bits);
    if (!std.math.isFinite(value)) return error.InvalidValue;
    return value;
}

fn fieldSpec(verb: *const VerbSpec, name: []const u8) ?*const FieldSpec {
    for (verb.fields) |*f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

const Staging = struct {
    x: ?i32 = null,
    y: ?i32 = null,
    w: ?u32 = null,
    h: ?u32 = null,
    x0: ?i32 = null,
    y0: ?i32 = null,
    x1: ?i32 = null,
    y1: ?i32 = null,
    thickness: ?u32 = null,
    radius: ?u32 = null,
    color: ?u32 = null,
    paint: ?enum { linear, radial, solid } = null,
    paint_from: ?u32 = null,
    paint_to: ?u32 = null,
    paint_inner: ?u32 = null,
    paint_outer: ?u32 = null,
    paint_x0: ?f32 = null,
    paint_y0: ?f32 = null,
    paint_x1: ?f32 = null,
    paint_y1: ?f32 = null,
    paint_cx: ?f32 = null,
    paint_cy: ?f32 = null,
    paint_gr: ?f32 = null,
    clip_x: ?i32 = null,
    clip_y: ?i32 = null,
    clip_w: ?u32 = null,
    clip_h: ?u32 = null,
    font: []const u8 = "default",
    text: ?[]const u8 = null,
    src_w: ?u32 = null,
    src_h: ?u32 = null,
    aa: ?u32 = null,
    winding: ?PathWinding = null,
    path_style: ?enum { fill, stroke } = null,
    path_width: ?f32 = null,
    path_join: ?PathJoin = null,
    path_cap: ?PathCap = null,
    path_miter_limit: ?f32 = null,
    path_verbs: ?[]const PathVerb = null,
    path_points: ?[]const Vec2f = null,

    fn putI32(self: *Staging, name: []const u8, v: i32) ParseError!void {
        if (std.mem.eql(u8, name, "x")) {
            if (self.x != null) return error.DuplicateField;
            self.x = v;
        } else if (std.mem.eql(u8, name, "y")) {
            if (self.y != null) return error.DuplicateField;
            self.y = v;
        } else if (std.mem.eql(u8, name, "x0")) {
            if (self.x0 != null) return error.DuplicateField;
            self.x0 = v;
        } else if (std.mem.eql(u8, name, "y0")) {
            if (self.y0 != null) return error.DuplicateField;
            self.y0 = v;
        } else if (std.mem.eql(u8, name, "x1")) {
            if (self.x1 != null) return error.DuplicateField;
            self.x1 = v;
        } else if (std.mem.eql(u8, name, "y1")) {
            if (self.y1 != null) return error.DuplicateField;
            self.y1 = v;
        } else if (std.mem.eql(u8, name, "clip_x")) {
            if (self.clip_x != null) return error.DuplicateField;
            self.clip_x = v;
        } else if (std.mem.eql(u8, name, "clip_y")) {
            if (self.clip_y != null) return error.DuplicateField;
            self.clip_y = v;
        } else return error.UnknownField;
    }

    fn putU32(self: *Staging, name: []const u8, v: u32) ParseError!void {
        if (std.mem.eql(u8, name, "w")) {
            if (self.w != null) return error.DuplicateField;
            self.w = v;
        } else if (std.mem.eql(u8, name, "h")) {
            if (self.h != null) return error.DuplicateField;
            self.h = v;
        } else if (std.mem.eql(u8, name, "thickness")) {
            if (self.thickness != null) return error.DuplicateField;
            self.thickness = v;
        } else if (std.mem.eql(u8, name, "radius")) {
            if (self.radius != null) return error.DuplicateField;
            self.radius = v;
        } else if (std.mem.eql(u8, name, "src_w")) {
            if (self.src_w != null) return error.DuplicateField;
            self.src_w = v;
        } else if (std.mem.eql(u8, name, "src_h")) {
            if (self.src_h != null) return error.DuplicateField;
            self.src_h = v;
        } else if (std.mem.eql(u8, name, "clip_w")) {
            if (self.clip_w != null) return error.DuplicateField;
            self.clip_w = v;
        } else if (std.mem.eql(u8, name, "clip_h")) {
            if (self.clip_h != null) return error.DuplicateField;
            self.clip_h = v;
        } else if (std.mem.eql(u8, name, "aa")) {
            if (self.aa != null) return error.DuplicateField;
            self.aa = v;
        } else return error.UnknownField;
    }

    fn putPaintColor(self: *Staging, name: []const u8, v: u32) ParseError!void {
        if (std.mem.eql(u8, name, "from")) {
            if (self.paint_from != null) return error.DuplicateField;
            self.paint_from = v;
        } else if (std.mem.eql(u8, name, "to")) {
            if (self.paint_to != null) return error.DuplicateField;
            self.paint_to = v;
        } else if (std.mem.eql(u8, name, "inner")) {
            if (self.paint_inner != null) return error.DuplicateField;
            self.paint_inner = v;
        } else if (std.mem.eql(u8, name, "outer")) {
            if (self.paint_outer != null) return error.DuplicateField;
            self.paint_outer = v;
        } else return error.UnknownField;
    }

    fn putPaintF32(self: *Staging, name: []const u8, v: f32) ParseError!void {
        if (std.mem.eql(u8, name, "x0")) {
            if (self.paint_x0 != null) return error.DuplicateField;
            self.paint_x0 = v;
        } else if (std.mem.eql(u8, name, "y0")) {
            if (self.paint_y0 != null) return error.DuplicateField;
            self.paint_y0 = v;
        } else if (std.mem.eql(u8, name, "x1")) {
            if (self.paint_x1 != null) return error.DuplicateField;
            self.paint_x1 = v;
        } else if (std.mem.eql(u8, name, "y1")) {
            if (self.paint_y1 != null) return error.DuplicateField;
            self.paint_y1 = v;
        } else if (std.mem.eql(u8, name, "cx")) {
            if (self.paint_cx != null) return error.DuplicateField;
            self.paint_cx = v;
        } else if (std.mem.eql(u8, name, "cy")) {
            if (self.paint_cy != null) return error.DuplicateField;
            self.paint_cy = v;
        } else if (std.mem.eql(u8, name, "gr")) {
            if (self.paint_gr != null) return error.DuplicateField;
            self.paint_gr = v;
        } else return error.UnknownField;
    }

    fn putPaint(self: *Staging, name: []const u8, value: []const u8) ParseError!void {
        if (self.paint != null) return error.DuplicateField;
        if (std.mem.eql(u8, value, "linear")) {
            self.paint = .linear;
        } else if (std.mem.eql(u8, value, "radial")) {
            self.paint = .radial;
        } else if (std.mem.eql(u8, value, "solid")) {
            self.paint = .solid;
        } else {
            _ = name;
            return error.InvalidValue;
        }
    }

    fn clip(self: Staging) Rect {
        return .{
            .x = self.clip_x orelse default_clip.x,
            .y = self.clip_y orelse default_clip.y,
            .w = self.clip_w orelse default_clip.w,
            .h = self.clip_h orelse default_clip.h,
        };
    }
};

fn requireI32(v: ?i32) ParseError!i32 {
    return v orelse error.MissingField;
}

fn requireU32(v: ?u32) ParseError!u32 {
    return v orelse error.MissingField;
}

fn requirePaintF32(v: ?f32) ParseError!f32 {
    return v orelse error.MissingField;
}

fn checkPaintCoord(v: f32) ParseError!f32 {
    if (!std.math.isFinite(v) or v < @as(f32, @floatFromInt(MIN_COORD)) or
        v > @as(f32, @floatFromInt(MAX_COORD))) return error.ValueOutOfRange;
    return v;
}

fn buildRectPaint(st: Staging) ParseError!Paint {
    if (st.paint == null) {
        return .{ .solid = colorFromBits(st.color orelse return error.MissingField) };
    }
    if (st.color != null) return error.InvalidValue;
    return switch (st.paint.?) {
        .solid => .{ .solid = colorFromBits(st.color orelse return error.MissingField) },
        .linear => blk: {
            const x0 = try checkPaintCoord(try requirePaintF32(st.paint_x0));
            const y0 = try checkPaintCoord(try requirePaintF32(st.paint_y0));
            const x1 = try checkPaintCoord(try requirePaintF32(st.paint_x1));
            const y1 = try checkPaintCoord(try requirePaintF32(st.paint_y1));
            if (x0 == x1 and y0 == y1) return error.InvalidValue;
            break :blk .{ .linear = .{
                .start = .{ .x = x0, .y = y0 },
                .end = .{ .x = x1, .y = y1 },
                .start_color = colorFromBits(st.paint_from orelse return error.MissingField),
                .end_color = colorFromBits(st.paint_to orelse return error.MissingField),
            } };
        },
        .radial => blk: {
            const cx = try checkPaintCoord(try requirePaintF32(st.paint_cx));
            const cy = try checkPaintCoord(try requirePaintF32(st.paint_cy));
            const radius = try checkPaintCoord(try requirePaintF32(st.paint_gr));
            if (radius <= 0) return error.InvalidValue;
            break :blk .{ .radial = .{
                .center = .{ .x = cx, .y = cy },
                .radius = radius,
                .inner_color = colorFromBits(st.paint_inner orelse return error.MissingField),
                .outer_color = colorFromBits(st.paint_outer orelse return error.MissingField),
            } };
        },
    };
}

fn checkCoord(v: i32) ParseError!i32 {
    if (v < MIN_COORD or v > MAX_COORD) return error.ValueOutOfRange;
    return v;
}

fn checkExtent(v: u32) ParseError!u32 {
    if (v > MAX_EXTENT) return error.ValueOutOfRange;
    return v;
}

fn checkThickness(v: u32) ParseError!u32 {
    if (v > MAX_THICKNESS) return error.ValueOutOfRange;
    return v;
}

fn checkClip(r: Rect) ParseError!Rect {
    _ = try checkCoord(r.x);
    _ = try checkCoord(r.y);
    _ = try checkExtent(r.w);
    _ = try checkExtent(r.h);
    return r;
}

fn buildCmd(verb: *const VerbSpec, st: Staging, arena: Allocator) (ParseError || Allocator.Error)!DrawCmd {
    const clip = try checkClip(st.clip());
    return switch (verb.tag) {
        .rect_filled => .{ .rect_filled = .{
            .rect = .{
                .x = try checkCoord(try requireI32(st.x)),
                .y = try checkCoord(try requireI32(st.y)),
                .w = try checkExtent(try requireU32(st.w)),
                .h = try checkExtent(try requireU32(st.h)),
            },
            .paint = try buildRectPaint(st),
            .radius = try checkExtent(st.radius orelse 0),
            .aa = blk: {
                const aa = st.aa orelse 1;
                if (aa > 1) return error.InvalidValue;
                break :blk aa != 0;
            },
            .clip = clip,
        } },
        .rect_outline => .{ .rect_outline = .{
            .rect = .{
                .x = try checkCoord(try requireI32(st.x)),
                .y = try checkCoord(try requireI32(st.y)),
                .w = try checkExtent(try requireU32(st.w)),
                .h = try checkExtent(try requireU32(st.h)),
            },
            .color = colorFromBits(st.color orelse return error.MissingField),
            .thickness = try checkThickness(try requireU32(st.thickness)),
            .radius = try checkExtent(st.radius orelse 0),
            .aa = blk: {
                const aa = st.aa orelse 1;
                if (aa > 1) return error.InvalidValue;
                break :blk aa != 0;
            },
            .clip = clip,
        } },
        .circle_filled => .{ .circle_filled = .{
            .center = .{ .x = try checkCoord(try requireI32(st.x)), .y = try checkCoord(try requireI32(st.y)) },
            .radius = try checkExtent(try requireU32(st.radius)),
            .color = colorFromBits(st.color orelse return error.MissingField),
            .aa = blk: {
                const aa = st.aa orelse 1;
                if (aa > 1) return error.InvalidValue;
                break :blk aa != 0;
            },
            .clip = clip,
        } },
        .circle_outline => .{ .circle_outline = .{
            .center = .{ .x = try checkCoord(try requireI32(st.x)), .y = try checkCoord(try requireI32(st.y)) },
            .radius = try checkExtent(try requireU32(st.radius)),
            .color = colorFromBits(st.color orelse return error.MissingField),
            .thickness = try checkThickness(try requireU32(st.thickness)),
            .aa = blk: {
                const aa = st.aa orelse 1;
                if (aa > 1) return error.InvalidValue;
                break :blk aa != 0;
            },
            .clip = clip,
        } },
        .line => .{ .line = .{
            .p0 = .{ .x = try checkCoord(try requireI32(st.x0)), .y = try checkCoord(try requireI32(st.y0)) },
            .p1 = .{ .x = try checkCoord(try requireI32(st.x1)), .y = try checkCoord(try requireI32(st.y1)) },
            .color = colorFromBits(st.color orelse return error.MissingField),
            .thickness = try checkThickness(try requireU32(st.thickness)),
            .clip = clip,
        } },
        .text => blk: {
            const raw = st.text orelse return error.MissingField;
            const owned = try arena.dupe(u8, raw);
            break :blk .{ .text = .{
                .pos = .{ .x = try checkCoord(try requireI32(st.x)), .y = try checkCoord(try requireI32(st.y)) },
                .text = owned,
                .color = colorFromBits(st.color orelse return error.MissingField),
                .clip = clip,
                .font = null,
            } };
        },
        // The dump form never carries pixels (only src_w/src_h and a content hash).
        // Reconstructing a zeroed buffer would draw something other than what was sent.
        .image => return error.ImagePayloadUnavailable,
        .path => blk: {
            const path_verbs = st.path_verbs orelse return error.MissingField;
            const points = st.path_points orelse return error.MissingField;
            const aa = st.aa orelse return error.MissingField;
            if (aa > 1) return error.InvalidValue;
            if (path_verbs.len > wire.MAX_VERBS) return error.TooManyVerbs;
            if (points.len > wire.MAX_POINTS) return error.TooManyPoints;
            draw_mod.validatePathSequence(path_verbs) catch return error.InvalidPath;
            var need: usize = 0;
            for (path_verbs) |v| need += v.pointCount();
            if (need != points.len) return error.InvalidValue;
            for (points) |p| {
                if (!std.math.isFinite(p.x) or !std.math.isFinite(p.y)) return error.InvalidValue;
            }
            const style = st.path_style orelse .fill;
            var stroke: ?draw_mod.PathStrokeParams = null;
            if (style == .stroke) {
                const width = st.path_width orelse return error.MissingField;
                if (!std.math.isFinite(width) or width <= 0 or width > draw_mod.path_stroke_width_max) {
                    return error.ValueOutOfRange;
                }
                const miter_limit = st.path_miter_limit orelse draw_mod.path_miter_limit_default;
                if (!std.math.isFinite(miter_limit) or miter_limit < 1) {
                    return error.ValueOutOfRange;
                }
                stroke = .{
                    .width = width,
                    .join = st.path_join orelse .miter,
                    .cap = st.path_cap orelse .butt,
                    .miter_limit = miter_limit,
                };
            }
            break :blk .{ .path = .{
                .verbs = path_verbs,
                .points = points,
                .color = colorFromBits(st.color orelse return error.MissingField),
                .winding = st.winding orelse .nonzero,
                .aa = aa != 0,
                .clip = clip,
                .stroke = stroke,
            } };
        },
    };
}

fn parseWinding(s: []const u8) ParseError!PathWinding {
    if (std.mem.eql(u8, s, "nonzero")) return .nonzero;
    return error.InvalidValue;
}

fn parsePathVerbs(arena: Allocator, s: []const u8) (ParseError || Allocator.Error)![]PathVerb {
    if (s.len > wire.MAX_VERBS) return error.TooManyVerbs;
    var out: std.ArrayList(PathVerb) = .empty;
    errdefer out.deinit(arena);
    for (s) |c| {
        const v = draw_mod.pathVerbFromLetter(c) orelse return error.InvalidValue;
        try out.append(arena, v);
    }
    return out.toOwnedSlice(arena);
}

fn parsePathPoints(arena: Allocator, s: []const u8) (ParseError || Allocator.Error)![]Vec2f {
    if (s.len == 0) return try arena.alloc(Vec2f, 0);
    var count: usize = 1;
    for (s) |c| {
        if (c == ',') count += 1;
    }
    if (count % 2 != 0) return error.InvalidValue;
    const n = count / 2;
    if (n > wire.MAX_POINTS) return error.TooManyPoints;
    const out = try arena.alloc(Vec2f, n);
    var it = std.mem.splitScalar(u8, s, ',');
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const xs = it.next() orelse return error.InvalidValue;
        const ys = it.next() orelse return error.InvalidValue;
        if (xs.len != 8 or ys.len != 8) return error.InvalidValue;
        const xb = std.fmt.parseUnsigned(u32, xs, 16) catch return error.InvalidValue;
        const yb = std.fmt.parseUnsigned(u32, ys, 16) catch return error.InvalidValue;
        out[i] = .{ .x = @bitCast(xb), .y = @bitCast(yb) };
    }
    if (it.next() != null) return error.InvalidValue;
    return out;
}

/// Parses one `cmd=<verb> k=v ...` line into a `DrawCmd`. `text` payloads are
/// allocated from `arena` and must outlive the command. `image` is always
/// `error.ImagePayloadUnavailable` (the dump form does not carry pixels).
pub fn parseCmdLine(line: []const u8, arena: Allocator) (ParseError || Allocator.Error)!DrawCmd {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return error.EmptyCommand;

    var i: usize = 0;
    const first = (try nextPair(trimmed, &i)) orelse return error.EmptyCommand;
    if (!std.mem.eql(u8, first.key, "cmd")) return error.InvalidValue;
    const verb = verbByName(first.value) orelse return error.UnknownVerb;
    if (verb.tag == .image) return error.ImagePayloadUnavailable;

    var seen: [32]bool = [_]bool{false} ** 32;
    var st: Staging = .{};
    while (try nextPair(trimmed, &i)) |pair| {
        const spec = fieldSpec(verb, pair.key) orelse return error.UnknownField;
        const idx = indexOfField(verb, spec.name) orelse return error.UnknownField;
        if (seen[idx]) return error.DuplicateField;
        seen[idx] = true;
        switch (spec.role) {
            .i32 => try st.putI32(spec.name, try parseIntI32(pair.value)),
            .u32 => try st.putU32(spec.name, try parseIntU32(pair.value)),
            .color => {
                if (st.color != null) return error.DuplicateField;
                st.color = try parseColorBits(pair.value);
            },
            .paint => try st.putPaint(spec.name, pair.value),
            .paint_color => try st.putPaintColor(spec.name, try parseColorBits(pair.value)),
            .paint_f32 => try st.putPaintF32(spec.name, try parsePaintF32(pair.value)),
            .font => {
                if (!std.mem.eql(u8, pair.value, "default")) return error.FontNotRestorable;
                st.font = pair.value;
            },
            .text => {
                const owned = try unescape(arena, pair.value);
                st.text = owned;
            },
            .derived => {},
            .winding => {
                if (st.winding != null) return error.DuplicateField;
                st.winding = try parseWinding(pair.value);
            },
            .path_style => {
                if (st.path_style != null) return error.DuplicateField;
                if (std.mem.eql(u8, pair.value, "fill")) {
                    st.path_style = .fill;
                } else if (std.mem.eql(u8, pair.value, "stroke")) {
                    st.path_style = .stroke;
                } else return error.InvalidValue;
            },
            .path_join => {
                if (st.path_join != null) return error.DuplicateField;
                st.path_join = draw_mod.pathJoinFromName(pair.value) orelse return error.InvalidValue;
            },
            .path_cap => {
                if (st.path_cap != null) return error.DuplicateField;
                st.path_cap = draw_mod.pathCapFromName(pair.value) orelse return error.InvalidValue;
            },
            .f32 => {
                const v = std.fmt.parseFloat(f32, pair.value) catch return error.InvalidValue;
                if (std.mem.eql(u8, spec.name, "width")) {
                    if (st.path_width != null) return error.DuplicateField;
                    st.path_width = v;
                } else if (std.mem.eql(u8, spec.name, "miter_limit")) {
                    if (st.path_miter_limit != null) return error.DuplicateField;
                    st.path_miter_limit = v;
                } else return error.UnknownField;
            },
            .path_verbs => {
                if (st.path_verbs != null) return error.DuplicateField;
                st.path_verbs = try parsePathVerbs(arena, pair.value);
            },
            .path_points => {
                if (st.path_points != null) return error.DuplicateField;
                st.path_points = try parsePathPoints(arena, pair.value);
            },
        }
    }

    for (verb.fields, 0..) |f, fi| {
        if (f.required and !seen[fi]) return error.MissingField;
    }
    return buildCmd(verb, st, arena);
}

fn indexOfField(verb: *const VerbSpec, name: []const u8) ?usize {
    for (verb.fields, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) return i;
    }
    return null;
}

/// True when `s[i..]` is a top-level `cmd=` (not inside a quoted `text` value).
fn isCmdAt(s: []const u8, i: usize) bool {
    if (i + 4 > s.len) return false;
    if (!std.mem.eql(u8, s[i..][0..4], "cmd=")) return false;
    if (i == 0) return true;
    const prev = s[i - 1];
    return prev == ' ' or prev == '\t' or prev == '\n' or prev == '\r';
}

/// End of the current `cmd=` group: the next top-level `cmd=`, or a newline / CR.
fn cmdSpanEnd(s: []const u8, start: usize) usize {
    var j = start + 4;
    var in_quote = false;
    var escaped = false;
    while (j < s.len) : (j += 1) {
        const c = s[j];
        if (in_quote) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_quote = false;
            }
            continue;
        }
        if (c == '"') {
            in_quote = true;
            continue;
        }
        if (c == '\n' or c == '\r') return j;
        if (isCmdAt(s, j)) return j;
    }
    return s.len;
}

/// Parses a dump (the `dumpAlloc` form, or several `cmd=` groups on one line) into
/// `dl`, allocating `text` payloads from `arena`. Existing commands in `dl` are
/// kept; the caller clears first when replacing. Caps at `max_cmds` total.
///
/// Tokens outside a `cmd=` group are an error (`MalformedInput`), except a single
/// `cmds=N` header whose N must match the number of commands this call adds.
/// Zero commands is `EmptyInput` — clearing is `overlay clear`, not an empty dump.
pub fn parseDump(
    dl: *DrawList,
    arena: Allocator,
    src: []const u8,
    max_cmds: usize,
) (ParseError || Allocator.Error)!void {
    var collected: std.ArrayList(DrawCmd) = .empty;
    defer collected.deinit(dl.alloc);
    var expected: ?usize = null;
    var i: usize = 0;
    while (i < src.len) {
        while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\r')) i += 1;
        if (i >= src.len) break;
        if (src[i] == '\n') {
            i += 1;
            continue;
        }
        if (isCmdAt(src, i)) {
            const end = cmdSpanEnd(src, i);
            const line = std.mem.trim(u8, src[i..end], " \t\r");
            i = end;
            if (line.len == 0) continue;
            if (collected.items.len >= max_cmds) return error.TooManyCommands;
            try collected.append(dl.alloc, try parseCmdLine(line, arena));
            continue;
        }
        if (std.mem.startsWith(u8, src[i..], "cmds=")) {
            if (expected != null) return error.MalformedInput;
            i += "cmds=".len;
            const num_start = i;
            while (i < src.len and src[i] >= '0' and src[i] <= '9') i += 1;
            if (i == num_start) return error.MalformedInput;
            expected = std.fmt.parseUnsigned(usize, src[num_start..i], 10) catch return error.MalformedInput;
            continue;
        }
        return error.MalformedInput;
    }

    if (collected.items.len == 0) return error.EmptyInput;
    if (expected) |n| {
        if (n != collected.items.len) return error.HeaderCountMismatch;
    }
    if (dl.cmds.items.len + collected.items.len > max_cmds) return error.TooManyCommands;
    try dl.cmds.appendSlice(dl.alloc, collected.items);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "draw_cmd_text: verb table covers every DrawCmd tag by name" {
    try testing.expectEqual(@as(usize, 8), verbs.len);
    try testing.expect(verbByName("rect_filled") != null);
    try testing.expect(verbByName("rect_outline") != null);
    try testing.expect(verbByName("circle_filled") != null);
    try testing.expect(verbByName("circle_outline") != null);
    try testing.expect(verbByName("line") != null);
    try testing.expect(verbByName("text") != null);
    try testing.expect(verbByName("image") != null);
    try testing.expect(verbByName("path") != null);
}

test "draw_cmd_text: serialize walks the table field order" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    try dl.rectFilled(.{ .x = 1, .y = 2, .w = 3, .h = 4 }, Color.rgba(1, 2, 3, 4));

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try appendCmd(&list, testing.allocator, dl.cmds.items[0]);

    const verb = verbByName("rect_filled").?;
    var pos: usize = 0;
    try testing.expect(std.mem.startsWith(u8, list.items, "cmd=rect_filled "));
    pos = "cmd=rect_filled ".len;
    for (verb.fields) |f| {
        if (!shouldEmitField(dl.cmds.items[0], f)) continue;
        const needle = try std.fmt.allocPrint(testing.allocator, "{s}=", .{f.name});
        defer testing.allocator.free(needle);
        const found = std.mem.indexOfPos(u8, list.items, pos, needle) orelse {
            std.debug.print("missing field {s} in {s}\n", .{ f.name, list.items });
            return error.TestExpectedEqual;
        };
        try testing.expectEqual(pos, found);
        pos = found + needle.len;
        while (pos < list.items.len and list.items[pos] != ' ' and list.items[pos] != '\n') pos += 1;
        if (pos < list.items.len and list.items[pos] == ' ') pos += 1;
    }
}

test "draw_cmd_text: sharp rectangle fixture and FNV hash stay byte-identical" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    try dl.rectFilled(.{ .x = 1, .y = 2, .w = 3, .h = 4 }, Color.rgba(1, 2, 3, 4));
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try appendCmd(&list, testing.allocator, dl.cmds.items[0]);
    const fixture = "cmd=rect_filled x=1 y=2 w=3 h=4 color=#04010203 clip_x=0 clip_y=0 clip_w=64 clip_h=64 offclip=0\n";
    try testing.expectEqualStrings(fixture, list.items);
    try testing.expectEqual(@as(u32, 0x194031E0), std.hash.Fnv1a_32.hash(list.items));
}

test "draw_cmd_text: omitted and explicit sharp defaults canonicalize to the same text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const omitted = "cmd=rect_filled x=1 y=2 w=3 h=4 color=#04010203 clip_x=0 clip_y=0 clip_w=64 clip_h=64 offclip=0";
    const explicit = "cmd=rect_filled x=1 y=2 w=3 h=4 color=#04010203 radius=0 aa=1 clip_x=0 clip_y=0 clip_w=64 clip_h=64 offclip=0";
    const a = try parseCmdLine(omitted, arena.allocator());
    const b = try parseCmdLine(explicit, arena.allocator());
    var a_text: std.ArrayList(u8) = .empty;
    defer a_text.deinit(testing.allocator);
    var b_text: std.ArrayList(u8) = .empty;
    defer b_text.deinit(testing.allocator);
    try appendCmd(&a_text, testing.allocator, a);
    try appendCmd(&b_text, testing.allocator, b);
    try testing.expectEqualSlices(u8, a_text.items, b_text.items);
    try testing.expect(std.mem.indexOf(u8, a_text.items, "radius=") == null);
    try testing.expect(std.mem.indexOf(u8, a_text.items, " aa=") == null);
}

test "draw_cmd_text: rounded rectangles emit radius and only non-default AA" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    try dl.rectFilledEx(.{ .x = 1, .y = 2, .w = 20, .h = 16 }, Color.rgba(1, 2, 3, 4), .{ .radius = 6 });
    try dl.rectOutlineEx(.{ .x = 3, .y = 4, .w = 22, .h = 18 }, Color.rgba(5, 6, 7, 8), 2, .{ .radius = 7, .aa = false });
    var first: std.ArrayList(u8) = .empty;
    defer first.deinit(testing.allocator);
    var second: std.ArrayList(u8) = .empty;
    defer second.deinit(testing.allocator);
    try appendCmd(&first, testing.allocator, dl.cmds.items[0]);
    try appendCmd(&second, testing.allocator, dl.cmds.items[1]);
    try testing.expect(std.mem.indexOf(u8, first.items, "radius=6") != null);
    try testing.expect(std.mem.indexOf(u8, first.items, " aa=") == null);
    try testing.expect(std.mem.indexOf(u8, second.items, "radius=7 aa=0") != null);
}

test "draw_cmd_text: gradient dumps use canonical IEEE bit fields and round trip" {
    var src = DrawList.init(testing.allocator);
    defer src.deinit();
    src.reset(64, 64);
    try src.rectFilledPaint(.{ .x = 1, .y = 2, .w = 20, .h = 16 }, .{ .linear = .{
        .start = .{ .x = 0.5, .y = 1.0 },
        .end = .{ .x = 20.25, .y = 18.0 },
        .start_color = Color.rgba(1, 2, 3, 4),
        .end_color = Color.rgba(5, 6, 7, 8),
    } });
    var first: std.ArrayList(u8) = .empty;
    defer first.deinit(testing.allocator);
    try appendCmd(&first, testing.allocator, src.cmds.items[0]);
    try testing.expect(std.mem.indexOf(u8, first.items, "paint=linear") != null);
    try testing.expect(std.mem.indexOf(u8, first.items, "x0=3F000000") != null);
    try testing.expect(std.mem.indexOf(u8, first.items, "color=") == null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try parseCmdLine(std.mem.trimEnd(u8, first.items, "\n"), arena.allocator());
    var second: std.ArrayList(u8) = .empty;
    defer second.deinit(testing.allocator);
    try appendCmd(&second, testing.allocator, parsed);
    try testing.expectEqualSlices(u8, first.items, second.items);
}

test "draw_cmd_text: invalid gradient domains are rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidValue, parseCmdLine(
        "cmd=rect_filled x=0 y=0 w=4 h=4 paint=linear from=#FF000000 to=#FFFFFFFF x0=00000000 y0=00000000 x1=00000000 y1=00000000",
        arena.allocator(),
    ));
    try testing.expectError(error.InvalidValue, parseCmdLine(
        "cmd=rect_filled x=0 y=0 w=4 h=4 paint=radial inner=#FFFFFFFF outer=#FF000000 cx=00000000 cy=00000000 gr=00000000",
        arena.allocator(),
    ));
}

test "draw_cmd_text: circle canonical dump round trips" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(80, 80);
    try dl.circleFilled(.{ .x = 20, .y = 21 }, 9, Color.rgba(1, 2, 3, 4), .{});
    try dl.circleOutline(.{ .x = 40, .y = 41 }, 10, Color.rgba(5, 6, 7, 8), 3, .{ .aa = false });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (dl.cmds.items) |cmd| {
        var first: std.ArrayList(u8) = .empty;
        defer first.deinit(testing.allocator);
        try appendCmd(&first, testing.allocator, cmd);
        const parsed = try parseCmdLine(std.mem.trimEnd(u8, first.items, "\n"), arena.allocator());
        var second: std.ArrayList(u8) = .empty;
        defer second.deinit(testing.allocator);
        try appendCmd(&second, testing.allocator, parsed);
        try testing.expectEqualSlices(u8, first.items, second.items);
    }
}

test "draw_cmd_text: rounded radius and AA differences change the canonical hash" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    const rect = Rect{ .x = 1, .y = 2, .w = 20, .h = 16 };
    const color = Color.rgba(1, 2, 3, 4);
    try dl.rectFilledEx(rect, color, .{ .radius = 5 });
    try dl.rectFilledEx(rect, color, .{ .radius = 6 });
    try dl.rectFilledEx(rect, color, .{ .radius = 5, .aa = false });
    var hashes: [3]u32 = undefined;
    for (dl.cmds.items, 0..) |cmd, i| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(testing.allocator);
        try appendCmd(&text, testing.allocator, cmd);
        hashes[i] = std.hash.Fnv1a_32.hash(text.items);
    }
    try testing.expect(hashes[0] != hashes[1]);
    try testing.expect(hashes[0] != hashes[2]);
}

test "draw_cmd_text: rect/line/text dump parses back" {
    var src = DrawList.init(testing.allocator);
    defer src.deinit();
    src.reset(64, 64);
    try src.rectFilled(.{ .x = 1, .y = 2, .w = 3, .h = 4 }, Color.rgba(0xFF, 0, 0, 0xFF));
    try src.line(.{ .x = 0, .y = 0 }, .{ .x = 10, .y = 10 }, Color.rgba(5, 6, 7, 8), 2);
    try src.text(.{ .x = 3, .y = 4 }, "hi there", Color.rgba(0, 0, 0, 0xFF));

    var dump_list: std.ArrayList(u8) = .empty;
    defer dump_list.deinit(testing.allocator);
    for (src.cmds.items) |cmd| try appendCmd(&dump_list, testing.allocator, cmd);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var dst = DrawList.init(testing.allocator);
    defer dst.deinit();
    try parseDump(&dst, arena.allocator(), dump_list.items, MAX_CMDS);

    try testing.expectEqual(src.cmds.items.len, dst.cmds.items.len);
    try testing.expectEqual(src.cmds.items[0].rect_filled.rect, dst.cmds.items[0].rect_filled.rect);
    try testing.expectEqual(src.cmds.items[0].rect_filled.paint, dst.cmds.items[0].rect_filled.paint);
    try testing.expectEqual(src.cmds.items[1].line.p0, dst.cmds.items[1].line.p0);
    try testing.expectEqual(src.cmds.items[1].line.p1, dst.cmds.items[1].line.p1);
    try testing.expectEqualStrings("hi there", dst.cmds.items[2].text.text);
}

test "draw_cmd_text: unknown verb is an explicit error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnknownVerb, parseCmdLine("cmd=bogus x=0 y=0", arena.allocator()));
}

test "draw_cmd_text: path dump parses back" {
    var src = DrawList.init(testing.allocator);
    defer src.deinit();
    src.reset(64, 64);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = src.beginPath(arena.allocator());
    try b.moveTo(.{ .x = 1.5, .y = 2.25 });
    try b.lineTo(.{ .x = 10, .y = 0 });
    try b.quadTo(.{ .x = 12, .y = 4 }, .{ .x = 8, .y = 8 });
    try b.cubicTo(.{ .x = 6, .y = 9 }, .{ .x = 4, .y = 9 }, .{ .x = 2, .y = 8 });
    try b.close();
    try b.finish(.{ .color = Color.rgba(0xFF, 0, 0, 0x80), .aa = false });

    var dump_list: std.ArrayList(u8) = .empty;
    defer dump_list.deinit(testing.allocator);
    try appendCmd(&dump_list, testing.allocator, src.cmds.items[0]);

    var dst = DrawList.init(testing.allocator);
    defer dst.deinit();
    try parseDump(&dst, arena.allocator(), dump_list.items, MAX_CMDS);
    try testing.expectEqual(@as(usize, 1), dst.cmds.items.len);
    const p = dst.cmds.items[0].path;
    try testing.expectEqual(src.cmds.items[0].path.verbs.len, p.verbs.len);
    try testing.expectEqual(src.cmds.items[0].path.points.len, p.points.len);
    try testing.expectEqual(colorBits(src.cmds.items[0].path.color), colorBits(p.color));
    try testing.expect(!p.aa);
    try testing.expectEqual(src.cmds.items[0].path.points[0].x, p.points[0].x);
    try testing.expectEqual(src.cmds.items[0].path.points[0].y, p.points[0].y);
    try testing.expect(p.stroke == null);
}

test "draw_cmd_text: stroke dump includes width join cap and parses back" {
    var src = DrawList.init(testing.allocator);
    defer src.deinit();
    src.reset(64, 64);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = src.beginPath(arena.allocator());
    try b.moveTo(.{ .x = 0, .y = 0 });
    try b.lineTo(.{ .x = 8, .y = 0 });
    try b.stroke(.{
        .color = Color.rgba(0, 0x80, 0xFF, 0xFF),
        .width = 3.5,
        .join = .bevel,
        .cap = .round,
        .miter_limit = 2.5,
    });

    var dump_list: std.ArrayList(u8) = .empty;
    defer dump_list.deinit(testing.allocator);
    try appendCmd(&dump_list, testing.allocator, src.cmds.items[0]);
    try testing.expect(std.mem.indexOf(u8, dump_list.items, "style=stroke") != null);
    try testing.expect(std.mem.indexOf(u8, dump_list.items, "width=3.5") != null);
    try testing.expect(std.mem.indexOf(u8, dump_list.items, "join=bevel") != null);
    try testing.expect(std.mem.indexOf(u8, dump_list.items, "cap=round") != null);
    try testing.expect(std.mem.indexOf(u8, dump_list.items, "miter_limit=2.5") != null);

    var dst = DrawList.init(testing.allocator);
    defer dst.deinit();
    try parseDump(&dst, arena.allocator(), dump_list.items, MAX_CMDS);
    const s = dst.cmds.items[0].path.stroke.?;
    try testing.expectEqual(@as(f32, 3.5), s.width);
    try testing.expectEqual(PathJoin.bevel, s.join);
    try testing.expectEqual(PathCap.round, s.cap);
    try testing.expectEqual(@as(f32, 2.5), s.miter_limit);
}

test "draw_cmd_text: unknown field is an explicit error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(
        error.UnknownField,
        parseCmdLine("cmd=rect_filled x=0 y=0 w=1 h=1 color=#FF000000 bogus=1", arena.allocator()),
    );
}

test "draw_cmd_text: several cmd= groups on one line parse as several commands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    const src =
        \\cmd=rect_filled x=1 y=2 w=3 h=4 color=#FF0000FF cmd=text x=5 y=6 color=#FFFFFFFF text="hi"
    ;
    try parseDump(&dl, arena.allocator(), src, MAX_CMDS);
    try testing.expectEqual(@as(usize, 2), dl.cmds.items.len);
    try testing.expectEqual(@as(i32, 1), dl.cmds.items[0].rect_filled.rect.x);
    try testing.expectEqualStrings("hi", dl.cmds.items[1].text.text);
}

test "draw_cmd_text: escaped quote and newline in text survive a parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cmd = try parseCmdLine("cmd=text x=0 y=0 color=#000000FF text=\"a\\\"b\\nc\"", arena.allocator());
    try testing.expectEqualStrings("a\"b\nc", cmd.text.text);
}

test "draw_cmd_text: cmds= header must match the command count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    try parseDump(&dl, arena.allocator(), "cmds=1\ncmd=rect_filled x=0 y=0 w=1 h=1 color=#FF000000\n", MAX_CMDS);
    try testing.expectEqual(@as(usize, 1), dl.cmds.items.len);
}

test "draw_cmd_text: command cap is enforced" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    try testing.expectError(
        error.TooManyCommands,
        parseDump(&dl, arena.allocator(), "cmd=rect_filled x=0 y=0 w=1 h=1 color=#FF000000 cmd=rect_filled x=0 y=0 w=1 h=1 color=#FF000000", 1),
    );
}

test "draw_cmd_text: omitted clip uses the default clip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cmd = try parseCmdLine("cmd=rect_filled x=1 y=2 w=3 h=4 color=#11223344", arena.allocator());
    try testing.expectEqual(default_clip, cmd.rect_filled.clip);
}

test "draw_cmd_text: serializer still emits image lines" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(8, 8);
    const px = [_]u32{ 0xFF000000, 0xFF000000, 0xFF000000, 0xFF000000 };
    try dl.image(.{ .x = 0, .y = 0, .w = 2, .h = 2 }, &px, 2, 2);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try appendCmd(&list, testing.allocator, dl.cmds.items[0]);
    try testing.expect(std.mem.startsWith(u8, list.items, "cmd=image "));
    try testing.expect(std.mem.indexOf(u8, list.items, "src_w=2") != null);
}

test "draw_cmd_text: image cannot be reconstructed from the dump form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(
        error.ImagePayloadUnavailable,
        parseCmdLine("cmd=image x=0 y=0 w=2 h=2 src_w=2 src_h=2 pixfnv=#AABBCCDD", arena.allocator()),
    );
}

test "draw_cmd_text: garbage outside cmd= is malformed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    try testing.expectError(error.MalformedInput, parseDump(&dl, arena.allocator(), "garbage", MAX_CMDS));
    try testing.expectEqual(@as(usize, 0), dl.cmds.items.len);
}

test "draw_cmd_text: cmds= header that does not match the count is an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    try testing.expectError(
        error.HeaderCountMismatch,
        parseDump(&dl, arena.allocator(), "cmds=2\ncmd=rect_filled x=0 y=0 w=1 h=1 color=#FF000000\n", MAX_CMDS),
    );
    try testing.expectEqual(@as(usize, 0), dl.cmds.items.len);
}

test "draw_cmd_text: empty input is an error (clear is overlay clear)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    try testing.expectError(error.EmptyInput, parseDump(&dl, arena.allocator(), "", MAX_CMDS));
    try testing.expectError(error.EmptyInput, parseDump(&dl, arena.allocator(), "   \n\n", MAX_CMDS));
    try testing.expectError(error.EmptyInput, parseDump(&dl, arena.allocator(), "cmds=0\n", MAX_CMDS));
    try testing.expectEqual(@as(usize, 0), dl.cmds.items.len);
}

test "draw_cmd_text: thickness that would overflow render is rejected" {
    // render.zig drawLine does `@intCast(t)` and `@intCast(t / 2)` into i32.
    // thickness=4294967295 panics there (confirmed against that path). Parse
    // must refuse it so an overlay inject cannot take the process down.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(
        error.ValueOutOfRange,
        parseCmdLine("cmd=line x0=0 y0=0 x1=1 y1=1 thickness=4294967295 color=#FFFFFFFF", arena.allocator()),
    );
}

test "draw_cmd_text: extreme coordinates that would overflow render are rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(
        error.ValueOutOfRange,
        parseCmdLine("cmd=rect_filled x=-2147483648 y=0 w=1 h=1 color=#FF000000", arena.allocator()),
    );
    try testing.expectError(
        error.ValueOutOfRange,
        parseCmdLine("cmd=rect_filled x=0 y=0 w=4294967295 h=1 color=#FF000000", arena.allocator()),
    );
}

test "draw_cmd_text: font=custom is not restorable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(
        error.FontNotRestorable,
        parseCmdLine("cmd=text x=0 y=0 color=#FFFFFFFF font=custom text=\"hi\"", arena.allocator()),
    );
}

test "draw_cmd_text: text payload must be valid UTF-8" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // A lone 0xE9 (Latin-1 'é') is not UTF-8.
    try testing.expectError(
        error.InvalidUtf8,
        parseCmdLine("cmd=text x=0 y=0 color=#FFFFFFFF text=\"\xE9\"", arena.allocator()),
    );
}

test "draw_cmd_text: path verb order and caps are explicit errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(
        error.InvalidPath,
        parseCmdLine("cmd=path color=#FF0000FF aa=1 winding=nonzero verbs=\"LML\" pts=\"00000000,00000000,00000000,00000000,00000000,00000000\"", arena.allocator()),
    );
    try testing.expectError(
        error.InvalidPath,
        parseCmdLine("cmd=path color=#FF0000FF aa=1 winding=nonzero verbs=\"ZL\" pts=\"00000000,00000000\"", arena.allocator()),
    );

    const too_many = try testing.allocator.alloc(u8, "cmd=path color=#FF0000FF aa=1 winding=nonzero verbs=\"".len + wire.MAX_VERBS + 2 + "\" pts=\"\" ".len + 8);
    defer testing.allocator.free(too_many);
    var n: usize = 0;
    const head = "cmd=path color=#FF0000FF aa=1 winding=nonzero verbs=\"";
    @memcpy(too_many[n..][0..head.len], head);
    n += head.len;
    @memset(too_many[n..][0 .. wire.MAX_VERBS + 1], 'M');
    n += wire.MAX_VERBS + 1;
    const tail = "\" pts=\"\"";
    @memcpy(too_many[n..][0..tail.len], tail);
    n += tail.len;
    try testing.expectError(error.TooManyVerbs, parseCmdLine(too_many[0..n], arena.allocator()));
}
