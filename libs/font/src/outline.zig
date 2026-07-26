// Shared outline representation. Produced by both the glyf (TrueType, quadratic) and CFF (OpenType, cubic) parsers;
// the rasterizer flattens and fills. Coordinates are f32 in font units.
// A Contour is a closed path (implicitly closes from the last segment end back to start).

const std = @import("std");

pub const Vec2f = struct { x: f32, y: f32 };

pub const Segment = union(enum) {
    line: Vec2f, // → end
    quad: struct { ctrl: Vec2f, end: Vec2f }, // Quadratic Bezier (TrueType)
    cubic: struct { c1: Vec2f, c2: Vec2f, end: Vec2f }, // Cubic Bezier (CFF)
};

pub const Contour = struct {
    start: Vec2f,
    segments: []const Segment,
};

pub const Outline = struct {
    contours: []const Contour,

    pub fn deinit(self: *Outline, alloc: std.mem.Allocator) void {
        for (self.contours) |c| alloc.free(c.segments);
        alloc.free(self.contours);
        self.* = undefined;
    }
};

/// Build an Outline incrementally. moveTo starts a contour; lineTo/quadTo/cubicTo append.
/// Degenerate contours (zero segments) are discarded. finish() returns an owned Outline.
/// On error, deinit() frees partial state.
pub const Builder = struct {
    alloc: std.mem.Allocator,
    contours: std.ArrayList(Contour) = .empty,
    cur_segments: std.ArrayList(Segment) = .empty,
    cur_start: Vec2f = .{ .x = 0, .y = 0 },
    has_current: bool = false,

    pub fn init(alloc: std.mem.Allocator) Builder {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Builder) void {
        for (self.contours.items) |c| self.alloc.free(c.segments);
        self.contours.deinit(self.alloc);
        self.cur_segments.deinit(self.alloc);
        self.* = undefined;
    }

    fn flushCurrent(self: *Builder) std.mem.Allocator.Error!void {
        if (!self.has_current) return;
        self.has_current = false;
        if (self.cur_segments.items.len == 0) {
            self.cur_segments.clearRetainingCapacity(); // Discard degenerate contours
            return;
        }
        const segs = try self.cur_segments.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(segs);
        try self.contours.append(self.alloc, .{ .start = self.cur_start, .segments = segs });
    }

    pub fn moveTo(self: *Builder, p: Vec2f) std.mem.Allocator.Error!void {
        try self.flushCurrent();
        self.cur_start = p;
        self.has_current = true;
    }

    pub fn lineTo(self: *Builder, p: Vec2f) std.mem.Allocator.Error!void {
        try self.cur_segments.append(self.alloc, .{ .line = p });
    }

    pub fn quadTo(self: *Builder, ctrl: Vec2f, p: Vec2f) std.mem.Allocator.Error!void {
        try self.cur_segments.append(self.alloc, .{ .quad = .{ .ctrl = ctrl, .end = p } });
    }

    pub fn cubicTo(self: *Builder, c1: Vec2f, c2: Vec2f, p: Vec2f) std.mem.Allocator.Error!void {
        try self.cur_segments.append(self.alloc, .{ .cubic = .{ .c1 = c1, .c2 = c2, .end = p } });
    }

    pub fn finish(self: *Builder) std.mem.Allocator.Error!Outline {
        try self.flushCurrent(); // Implicitly close an unclosed contour
        const contours = try self.contours.toOwnedSlice(self.alloc);
        return .{ .contours = contours };
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "Builder: contour and degenerate-contour handling" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();

    try b.moveTo(.{ .x = 0, .y = 0 });
    try b.lineTo(.{ .x = 10, .y = 0 });
    try b.lineTo(.{ .x = 0, .y = 10 });

    // Degenerate contour (move only, no segments) → discarded
    try b.moveTo(.{ .x = 5, .y = 5 });

    try b.moveTo(.{ .x = 0, .y = 0 });
    try b.quadTo(.{ .x = 5, .y = 5 }, .{ .x = 10, .y = 0 });

    var o = try b.finish();
    defer o.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), o.contours.len); // Degenerates excluded
    try testing.expectEqual(@as(usize, 2), o.contours[0].segments.len);
    try testing.expect(o.contours[0].segments[0] == .line);
    try testing.expectEqual(@as(usize, 1), o.contours[1].segments.len);
    try testing.expect(o.contours[1].segments[0] == .quad);
}

test "Builder: empty (no contours)" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var o = try b.finish();
    defer o.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), o.contours.len);
}
