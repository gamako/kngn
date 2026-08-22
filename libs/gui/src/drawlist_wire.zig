//! Binary wire form of a path verb stream (the payload of a `DrawCmd.path`).
//! DrawCmd structure uses the separate canonical text wire in
//! `draw_cmd_text.zig`; adding non-path primitives does not change this schema.
//!
//! The table is the contract the overlay inject parser follows: each verb's
//! tag, how many points it consumes, the schema version, and the error set
//! for a bad stream. This file encodes and validates; it does not decode
//! into a DrawCmd.
//!
//! Layout (little-endian):
//!   u16 schema_version | u32 n_verbs | u32 n_points
//!   [n_verbs] u8 tags
//!   [n_points] f32 x, f32 y   (IEEE-754 bits, little-endian)
//!
//! Unknown tag, truncated input, too many verbs/points, a non-finite coordinate,
//! or a point-count that does not match the verbs are all explicit errors.
//!
//! Hot path declaration: encode / validate run at event time only (a probe dump
//! or an overlay inject). Nothing walks pixels per frame.

const std = @import("std");
const Allocator = std.mem.Allocator;
const draw_mod = @import("draw.zig");

pub const PathVerb = draw_mod.PathVerb;
pub const Vec2f = draw_mod.Vec2f;

/// Bump this when the binary layout changes. Folded into `digest` so a schema
/// change cannot collide with an older dump's hash.
pub const schema_version: u16 = 1;

pub const MAX_VERBS: u32 = 65_536;
pub const MAX_POINTS: u32 = 196_608;

pub const WireError = error{
    Truncated,
    UnknownVerb,
    TooManyVerbs,
    TooManyPoints,
    NonFinite,
    ArgumentMismatch,
    InvalidPath,
};

fn writeU16(out: *std.ArrayList(u8), alloc: Allocator, v: u16) Allocator.Error!void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, v, .little);
    try out.appendSlice(alloc, &buf);
}

fn writeU32(out: *std.ArrayList(u8), alloc: Allocator, v: u32) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try out.appendSlice(alloc, &buf);
}

fn writeF32(out: *std.ArrayList(u8), alloc: Allocator, v: f32) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, @bitCast(v), .little);
    try out.appendSlice(alloc, &buf);
}

fn readU16(bytes: []const u8, i: *usize) WireError!u16 {
    if (i.* + 2 > bytes.len) return error.Truncated;
    const v = std.mem.readInt(u16, bytes[i.*..][0..2], .little);
    i.* += 2;
    return v;
}

fn readU32(bytes: []const u8, i: *usize) WireError!u32 {
    if (i.* + 4 > bytes.len) return error.Truncated;
    const v = std.mem.readInt(u32, bytes[i.*..][0..4], .little);
    i.* += 4;
    return v;
}

fn readF32(bytes: []const u8, i: *usize) WireError!f32 {
    if (i.* + 4 > bytes.len) return error.Truncated;
    const bits = std.mem.readInt(u32, bytes[i.*..][0..4], .little);
    i.* += 4;
    return @bitCast(bits);
}

/// Encode `verbs`/`points` into the binary wire form. Rejects a point count
/// that does not match the verbs, a non-finite coordinate, or a stream over
/// the verb/point cap.
pub fn encode(
    alloc: Allocator,
    verbs: []const PathVerb,
    points: []const Vec2f,
) (WireError || Allocator.Error)![]u8 {
    if (verbs.len > MAX_VERBS) return error.TooManyVerbs;
    if (points.len > MAX_POINTS) return error.TooManyPoints;
    draw_mod.validatePathSequence(verbs) catch return error.InvalidPath;
    var need: usize = 0;
    for (verbs) |v| need += v.pointCount();
    if (need != points.len) return error.ArgumentMismatch;
    for (points) |p| {
        if (!std.math.isFinite(p.x) or !std.math.isFinite(p.y)) return error.NonFinite;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try writeU16(&out, alloc, schema_version);
    try writeU32(&out, alloc, @intCast(verbs.len));
    try writeU32(&out, alloc, @intCast(points.len));
    for (verbs) |v| try out.append(alloc, v.wireTag());
    for (points) |p| {
        try writeF32(&out, alloc, p.x);
        try writeF32(&out, alloc, p.y);
    }
    return out.toOwnedSlice(alloc);
}

/// Walk `bytes` and return an explicit error on any contract violation.
/// A well-formed stream (including an empty path) returns void.
pub fn validate(bytes: []const u8) WireError!void {
    var i: usize = 0;
    const ver = try readU16(bytes, &i);
    if (ver != schema_version) return error.UnknownVerb;
    const n_verbs = try readU32(bytes, &i);
    const n_points = try readU32(bytes, &i);
    if (n_verbs > MAX_VERBS) return error.TooManyVerbs;
    if (n_points > MAX_POINTS) return error.TooManyPoints;
    if (i + n_verbs > bytes.len) return error.Truncated;
    const tags = bytes[i .. i + n_verbs];
    i += n_verbs;

    var need: u64 = 0;
    var contour: draw_mod.PathContourState = .{};
    for (tags) |tag| {
        const verb = draw_mod.pathVerbFromWireTag(tag) orelse return error.UnknownVerb;
        contour.feed(verb) catch return error.InvalidPath;
        need += verb.pointCount();
    }
    if (need != n_points) return error.ArgumentMismatch;

    var pi: u32 = 0;
    while (pi < n_points) : (pi += 1) {
        const x = try readF32(bytes, &i);
        const y = try readF32(bytes, &i);
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return error.NonFinite;
    }
    if (i != bytes.len) return error.Truncated;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "drawlist_wire: encode matches a fixed fixture" {
    const verbs = [_]PathVerb{ .move, .line, .quad, .cubic, .close };
    const points = [_]Vec2f{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 2 },
        .{ .x = 3, .y = 4 },
        .{ .x = 5, .y = 6 },
        .{ .x = 7, .y = 8 },
        .{ .x = 9, .y = 10 },
        .{ .x = 11, .y = 12 },
    };
    const got = try encode(testing.allocator, &verbs, &points);
    defer testing.allocator.free(got);

    // schema=1, n_verbs=5, n_points=7, tags 0,1,2,3,4, then 14 f32s.
    var expect: std.ArrayList(u8) = .empty;
    defer expect.deinit(testing.allocator);
    try writeU16(&expect, testing.allocator, 1);
    try writeU32(&expect, testing.allocator, 5);
    try writeU32(&expect, testing.allocator, 7);
    try expect.appendSlice(testing.allocator, &.{ 0, 1, 2, 3, 4 });
    for (points) |p| {
        try writeF32(&expect, testing.allocator, p.x);
        try writeF32(&expect, testing.allocator, p.y);
    }
    try testing.expectEqualSlices(u8, expect.items, got);
    try validate(got);
}

test "drawlist_wire: validate rejects truncated, unknown tag, overflow, NaN, mismatch" {
    try testing.expectError(error.Truncated, validate(&.{}));
    try testing.expectError(error.Truncated, validate(&.{ 1, 0 }));

    // schema 1, 1 verb, 0 points, tag 99 (unknown)
    const unknown = [_]u8{
        1,  0,
        1,  0,
        0,  0,
        0,  0,
        0,  0,
        99,
    };
    try testing.expectError(error.UnknownVerb, validate(&unknown));

    // n_verbs = MAX_VERBS+1
    var too_many_v: [10]u8 = undefined;
    std.mem.writeInt(u16, too_many_v[0..2], 1, .little);
    std.mem.writeInt(u32, too_many_v[2..6], MAX_VERBS + 1, .little);
    std.mem.writeInt(u32, too_many_v[6..10], 0, .little);
    try testing.expectError(error.TooManyVerbs, validate(&too_many_v));

    // move (1 point) with n_points=0
    const mismatch = [_]u8{
        1, 0,
        1, 0,
        0, 0,
        0, 0,
        0, 0,
        0,
    };
    try testing.expectError(error.ArgumentMismatch, validate(&mismatch));

    const nan_bits: u32 = @bitCast(std.math.nan(f32));
    var nan_buf: [19]u8 = undefined;
    std.mem.writeInt(u16, nan_buf[0..2], 1, .little);
    std.mem.writeInt(u32, nan_buf[2..6], 1, .little);
    std.mem.writeInt(u32, nan_buf[6..10], 1, .little);
    nan_buf[10] = 0; // move
    std.mem.writeInt(u32, nan_buf[11..15], nan_bits, .little);
    std.mem.writeInt(u32, nan_buf[15..19], 0, .little);
    try testing.expectError(error.NonFinite, validate(&nan_buf));
}

test "drawlist_wire: encode rejects non-finite and a point-count mismatch" {
    const verbs = [_]PathVerb{.move};
    const bad_pts = [_]Vec2f{.{ .x = std.math.inf(f32), .y = 0 }};
    try testing.expectError(error.NonFinite, encode(testing.allocator, &verbs, &bad_pts));
    try testing.expectError(error.ArgumentMismatch, encode(testing.allocator, &verbs, &.{}));
}

test "drawlist_wire: invalid verb order is InvalidPath" {
    const line_first = [_]PathVerb{ .line, .move, .line };
    const pts3 = [_]Vec2f{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 } };
    try testing.expectError(error.InvalidPath, encode(testing.allocator, &line_first, &pts3));

    const close_then_line = [_]PathVerb{ .close, .line };
    const pts1 = [_]Vec2f{.{ .x = 0, .y = 0 }};
    try testing.expectError(error.InvalidPath, encode(testing.allocator, &close_then_line, &pts1));

    // schema 1, 1 verb (line, tag 1), 1 point at origin — line before move
    var buf: [19]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], 1, .little);
    std.mem.writeInt(u32, buf[2..6], 1, .little);
    std.mem.writeInt(u32, buf[6..10], 1, .little);
    buf[10] = 1; // line
    std.mem.writeInt(u32, buf[11..15], 0, .little);
    std.mem.writeInt(u32, buf[15..19], 0, .little);
    try testing.expectError(error.InvalidPath, validate(&buf));
}
