// 共通アウトライン表現。glyf(TrueType, 2次) と CFF(OpenType, 3次) の両パーサが生成し、
// ラスタライザ(TASK-25.5)が平坦化して塗る。座標は font units の f32。
// Contour は閉路（最後のセグメント end から start へ暗黙に閉じる）。

const std = @import("std");

pub const Vec2f = struct { x: f32, y: f32 };

pub const Segment = union(enum) {
    line: Vec2f, // → end
    quad: struct { ctrl: Vec2f, end: Vec2f }, // 2次 Bezier（TrueType）
    cubic: struct { c1: Vec2f, c2: Vec2f, end: Vec2f }, // 3次 Bezier（CFF）
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

/// Outline を逐次構築する。moveTo で contour を開始し、lineTo/quadTo/cubicTo を積む。
/// 退化 contour（セグメント 0 本）は捨てる。finish() で所有権付き Outline を返す。
/// エラー時は deinit() で部分状態を解放する。
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
            self.cur_segments.clearRetainingCapacity(); // 退化 contour は捨てる
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
        try self.flushCurrent(); // 未 close の contour を暗黙 close
        const contours = try self.contours.toOwnedSlice(self.alloc);
        return .{ .contours = contours };
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "Builder: contour と退化 contour の扱い" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();

    try b.moveTo(.{ .x = 0, .y = 0 });
    try b.lineTo(.{ .x = 10, .y = 0 });
    try b.lineTo(.{ .x = 0, .y = 10 });

    // 退化 contour（move のみ・segment なし）→ 捨てられる
    try b.moveTo(.{ .x = 5, .y = 5 });

    try b.moveTo(.{ .x = 0, .y = 0 });
    try b.quadTo(.{ .x = 5, .y = 5 }, .{ .x = 10, .y = 0 });

    var o = try b.finish();
    defer o.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), o.contours.len); // 退化は除外
    try testing.expectEqual(@as(usize, 2), o.contours[0].segments.len);
    try testing.expect(o.contours[0].segments[0] == .line);
    try testing.expectEqual(@as(usize, 1), o.contours[1].segments.len);
    try testing.expect(o.contours[1].segments[0] == .quad);
}

test "Builder: 空（contour なし）" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var o = try b.finish();
    defer o.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), o.contours.len);
}
