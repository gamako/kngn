const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const color_mod = @import("color.zig");
const font_mod = @import("font.zig");

pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const Color = color_mod.Color;
pub const Font = font_mod.Font;

pub const DrawCmd = union(enum) {
    rect_filled: struct { rect: Rect, color: Color, clip: Rect },
    rect_outline: struct { rect: Rect, color: Color, thickness: u32, clip: Rect },
    line: struct { p0: Vec2, p1: Vec2, color: Color, thickness: u32, clip: Rect },
    /// text は DrawList より長く生かした arena 上の slice を指すこと（caller 責任）。
    /// font が null なら render() に渡した既定フォントで描画する（override 用）。
    text: struct { pos: Vec2, text: []const u8, color: Color, clip: Rect, font: ?Font = null },
    /// pixels は DrawList より長く生かした caller 所有の slice を指すこと（caller 責任）
    image: struct { rect: Rect, pixels: []const u32, src_w: u32, src_h: u32, clip: Rect },
};

/// ArrayList が unmanaged なので alloc フィールドを自前で保持する。
/// 使用前に必ず reset(w, h) を呼ぶこと。
pub const DrawList = struct {
    alloc: Allocator,
    cmds: std.ArrayList(DrawCmd) = .empty,
    clip_stack: std.ArrayList(Rect) = .empty,

    pub fn init(alloc: Allocator) DrawList {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *DrawList) void {
        self.cmds.deinit(self.alloc);
        self.clip_stack.deinit(self.alloc);
    }

    /// 毎フレーム最初に呼ぶこと。root clip = Rect{0,0,w,h} を設定する。
    /// w/h は論理サイズ（物理 framebuffer 寸法ではない。scale は render() 側で適用）。
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
        try self.cmds.append(self.alloc, .{ .rect_filled = .{
            .rect = rect,
            .color = col,
            .clip = self.currentClip(),
        } });
    }

    pub fn rectOutline(self: *DrawList, rect: Rect, col: Color, thickness: u32) Allocator.Error!void {
        try self.cmds.append(self.alloc, .{ .rect_outline = .{
            .rect = rect,
            .color = col,
            .thickness = thickness,
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

    /// str は DrawList より長く生かした arena 上の文字列を指すこと。
    /// 描画フォントは render() に渡した既定フォント。
    pub fn text(self: *DrawList, pos: Vec2, str: []const u8, col: Color) Allocator.Error!void {
        try self.textEx(pos, str, col, null);
    }

    /// font override 付き text。font が null なら既定フォントで描画する。
    pub fn textEx(self: *DrawList, pos: Vec2, str: []const u8, col: Color, font: ?Font) Allocator.Error!void {
        try self.cmds.append(self.alloc, .{ .text = .{
            .pos = pos,
            .text = str,
            .color = col,
            .clip = self.currentClip(),
            .font = font,
        } });
    }

    /// pixels は DrawList より長く生かした caller 所有の slice を指すこと。
    /// assert: pixels.len == src_w * src_h。destination rect は source と異寸でもよい（nearest）。
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

    /// clip を stack に push。現在の clip との intersection を取る。
    pub fn pushClip(self: *DrawList, rect: Rect) Allocator.Error!void {
        const current = self.currentClip();
        const clipped = Rect.intersect(current, rect);
        try self.clip_stack.append(self.alloc, clipped);
    }

    /// root clip は pop 不可（assert(len > 1)）
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

test "DrawList: pushClip / popClip intersection" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();

    dl.reset(100, 100);
    try dl.pushClip(.{ .x = 10, .y = 10, .w = 50, .h = 50 });
    try std.testing.expectEqual(@as(usize, 2), dl.clip_stack.items.len);
    const inner = dl.clip_stack.items[1];
    try std.testing.expectEqual(@as(i32, 10), inner.x);
    try std.testing.expectEqual(@as(u32, 50), inner.w);

    // 入れ子 clip
    try dl.pushClip(.{ .x = 20, .y = 20, .w = 100, .h = 100 });
    const nested = dl.clip_stack.items[2];
    try std.testing.expectEqual(@as(i32, 20), nested.x);
    try std.testing.expectEqual(@as(u32, 40), nested.w); // min(50-10, 100) + offset

    dl.popClip();
    try std.testing.expectEqual(@as(usize, 2), dl.clip_stack.items.len);
    dl.popClip();
    try std.testing.expectEqual(@as(usize, 1), dl.clip_stack.items.len);
}

test "DrawList: cmd clip焼き込み（pushClip後）" {
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
