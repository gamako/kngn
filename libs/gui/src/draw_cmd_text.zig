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
pub const Vec2f = draw_mod.Vec2f;

/// How many overlay commands a single inject may install. Sized so a full list still
/// fits inside the copilot/harness 64 KiB wire limit at the current per-line width.
pub const MAX_CMDS = 256;

/// Inclusive coordinate range the parser accepts. At a supported `content_scale`
/// (the usual window scale, around 1–2) these bounds keep `render.zig`'s integer
/// arithmetic (`@intCast` of thickness, `@abs(x1 - x0)`, `x + w`) inside i32.
/// 2^20 is larger than any window we present (8K is 7680). They do not cover an
/// arbitrary caller-supplied scale; that is the renderer's contract.
pub const MAX_COORD: i32 = 1 << 20;
pub const MIN_COORD: i32 = -(1 << 20);

/// Maximum `w` / `h` / `clip_w` / `clip_h`. Same 2^20 bound as `MAX_COORD` so
/// `x + w` stays inside i32 when `x` is also in range, at a supported scale.
pub const MAX_EXTENT: u32 = 1 << 20;

/// Maximum stroke / outline thickness. 4096 px is already a filled slab, not a
/// stroke. Together with `MAX_COORD`, `coord + thickness + thickness / 2` stays
/// inside i32 at a supported scale.
pub const MAX_THICKNESS: u32 = 4096;

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
    /// Compact path-verb string (`MLQCZ`).
    path_verbs,
    /// Path points as comma-separated IEEE-754 hex bits (`xxxxxxxx,yyyyyyyy,...`).
    path_points,
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
            .{ .name = "color", .role = .color },
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
        .line => |c| @intFromBool(!(c.clip.contains(c.p0) and c.clip.contains(c.p1))),
        .text => |c| @intFromBool(!c.clip.contains(c.pos)),
        .image => |c| @intFromBool(!rectFullyInside(c.rect, c.clip)),
        .path => |c| @intFromBool(!pathPointsInsideClip(c.points, c.clip)),
    };
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
        .rect_filled => |c| colorBits(c.color),
        .rect_outline => |c| colorBits(c.color),
        .line => |c| colorBits(c.color),
        .text => |c| colorBits(c.color),
        .image => 0,
        .path => |c| colorBits(c.color),
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
    color: ?u32 = null,
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
            .color = colorFromBits(st.color orelse return error.MissingField),
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
            break :blk .{ .path = .{
                .verbs = path_verbs,
                .points = points,
                .color = colorFromBits(st.color orelse return error.MissingField),
                .winding = st.winding orelse .nonzero,
                .aa = aa != 0,
                .clip = clip,
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
    try testing.expectEqual(@as(usize, 6), verbs.len);
    try testing.expect(verbByName("rect_filled") != null);
    try testing.expect(verbByName("rect_outline") != null);
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
    try testing.expectEqual(colorBits(src.cmds.items[0].rect_filled.color), colorBits(dst.cmds.items[0].rect_filled.color));
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
