//! A retained DrawList drawn on top of the application's own frame.
//!
//! The list is owned here: an inject parses the shared DrawCmd text form
//! (`draw_cmd_text.zig`) into a private copy and keeps it until the next
//! replace or an explicit clear. Copilot and the harness only deliver that
//! text; they do not hold DrawCmd values and they are not consulted on the
//! per-frame path.
//!
//! Hot path declaration: `drawList` / `render` run every frame. When the
//! overlay is empty, `drawList` is one null check and `render` returns at
//! once — no walk of commands, no pixel writes. Inject and clear run at
//! event time only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const draw_mod = @import("draw.zig");
const geom = @import("geom.zig");
const font_mod = @import("font.zig");
const render_mod = @import("render.zig");
const text = @import("draw_cmd_text.zig");

pub const DrawList = draw_mod.DrawList;
pub const DrawCmd = draw_mod.DrawCmd;
pub const RenderTarget = geom.RenderTarget;
pub const Font = font_mod.Font;
pub const MAX_CMDS = text.MAX_CMDS;

fn cloneCmd(arena: Allocator, cmd: DrawCmd) Allocator.Error!DrawCmd {
    return switch (cmd) {
        .text => |c| .{ .text = .{
            .pos = c.pos,
            .text = try arena.dupe(u8, c.text),
            .color = c.color,
            .clip = c.clip,
            .font = c.font,
        } },
        .image => |c| .{ .image = .{
            .rect = c.rect,
            .pixels = try arena.dupe(u32, c.pixels),
            .src_w = c.src_w,
            .src_h = c.src_h,
            .clip = c.clip,
        } },
        .path => |c| .{ .path = .{
            .verbs = try arena.dupe(draw_mod.PathVerb, c.verbs),
            .points = try arena.dupe(draw_mod.Vec2f, c.points),
            .color = c.color,
            .winding = c.winding,
            .aa = c.aa,
            .clip = c.clip,
            .stroke = c.stroke,
        } },
        else => cmd,
    };
}

pub const Overlay = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    dl: DrawList,
    /// False when there is nothing to draw. The per-frame path tests this
    /// once via `drawList()` and does no other work when it is false.
    active: bool = false,

    pub fn init(gpa: Allocator) Overlay {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .dl = DrawList.init(gpa),
        };
    }

    pub fn deinit(self: *Overlay) void {
        self.dl.deinit();
        self.arena.deinit();
        self.active = false;
    }

    /// The retained list, or null when empty. One optional check is the
    /// whole per-frame cost of an unset overlay.
    pub fn drawList(self: *const Overlay) ?*const DrawList {
        if (!self.active) return null;
        return &self.dl;
    }

    /// Always the retained list (possibly empty). For probes / dumps.
    pub fn retainedList(self: *const Overlay) *const DrawList {
        return &self.dl;
    }

    pub fn clear(self: *Overlay) void {
        self.dl.cmds.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        self.active = false;
    }

    /// Replace the retained list with the commands in `src`. On parse
    /// failure the previous list is left unchanged.
    pub fn replaceFromText(self: *Overlay, src: []const u8) !void {
        var new_arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer new_arena.deinit();
        var new_dl = DrawList.init(self.gpa);
        errdefer new_dl.deinit();
        try text.parseDump(&new_dl, new_arena.allocator(), src, MAX_CMDS);

        self.dl.deinit();
        self.arena.deinit();
        self.dl = new_dl;
        self.arena = new_arena;
        self.active = new_dl.cmds.items.len > 0;
    }

    /// Append the commands in `src` to the retained list.
    /// Parsed into a temporary arena first. On success the new commands are
    /// cloned into the retained list. On failure the command list is left
    /// as it was before the call. Memory a failed attempt allocated in the
    /// retained arena is reclaimed on the next replace or clear (an arena
    /// cannot free a mid-block allocation).
    pub fn appendFromText(self: *Overlay, src: []const u8) !void {
        var tmp_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer tmp_arena.deinit();
        var tmp_dl = DrawList.init(self.gpa);
        defer tmp_dl.deinit();
        try text.parseDump(&tmp_dl, tmp_arena.allocator(), src, MAX_CMDS);
        if (self.dl.cmds.items.len + tmp_dl.cmds.items.len > MAX_CMDS) return error.TooManyCommands;
        try self.dl.cmds.ensureUnusedCapacity(self.gpa, tmp_dl.cmds.items.len);
        const committed = self.dl.cmds.items.len;
        errdefer self.dl.cmds.shrinkRetainingCapacity(committed);
        for (tmp_dl.cmds.items) |cmd| {
            self.dl.cmds.appendAssumeCapacity(try cloneCmd(self.arena.allocator(), cmd));
        }
        self.active = self.dl.cmds.items.len > 0;
    }

    /// Draw the overlay, or return immediately when it is empty.
    /// Takes `*Overlay` because `gui.render` writes into the DrawList's path scratch.
    pub fn render(self: *Overlay, target: RenderTarget, font: Font, scale: f32) void {
        if (!self.active) return;
        render_mod.render(target, &self.dl, font, scale);
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "overlay: empty drawList is null and render writes no pixels" {
    var overlay = Overlay.init(testing.allocator);
    defer overlay.deinit();
    try testing.expect(overlay.drawList() == null);

    var pixels = [_]u32{0xDEADBEEF} ** 16;
    overlay.render(.{ .pixels = &pixels, .width = 4, .height = 4 }, font_mod.default_font, 1.0);
    for (pixels) |p| {
        try testing.expectEqual(@as(u32, 0xDEADBEEF), p);
    }
}

test "overlay: replaceFromText then render draws, clear returns to null" {
    var overlay = Overlay.init(testing.allocator);
    defer overlay.deinit();
    try overlay.replaceFromText("cmd=rect_filled x=0 y=0 w=2 h=2 color=#FF00FF00");
    try testing.expect(overlay.drawList() != null);
    try testing.expectEqual(@as(usize, 1), overlay.drawList().?.cmds.items.len);

    var pixels = [_]u32{0} ** 16;
    overlay.render(.{ .pixels = &pixels, .width = 4, .height = 4 }, font_mod.default_font, 1.0);
    // Opaque green (0xAARRGGBB with A=FF, R=00, G=FF, B=00) in the 2×2 rect.
    try testing.expectEqual(@as(u32, 0xFF00FF00), pixels[0]);
    try testing.expectEqual(@as(u32, 0xFF00FF00), pixels[1]);
    try testing.expectEqual(@as(u32, 0), pixels[2]);
    try testing.expectEqual(@as(u32, 0), pixels[8]);

    overlay.clear();
    try testing.expect(overlay.drawList() == null);
    @memset(&pixels, 0x11111111);
    overlay.render(.{ .pixels = &pixels, .width = 4, .height = 4 }, font_mod.default_font, 1.0);
    for (pixels) |p| {
        try testing.expectEqual(@as(u32, 0x11111111), p);
    }
}

test "overlay: failed replace leaves the previous list in place" {
    var overlay = Overlay.init(testing.allocator);
    defer overlay.deinit();
    try overlay.replaceFromText("cmd=rect_filled x=1 y=1 w=1 h=1 color=#FFFFFFFF");
    try testing.expectError(error.UnknownVerb, overlay.replaceFromText("cmd=not_a_verb x=0"));
    try testing.expect(overlay.drawList() != null);
    try testing.expectEqual(@as(i32, 1), overlay.drawList().?.cmds.items[0].rect_filled.rect.x);
}

test "overlay: apply and render do not use an action registry" {
    // This file lives in libs/gui and cannot import core/control. The draw
    // path is Overlay.replaceFromText + Overlay.render; an empty action
    // registry (harness disabled) cannot affect it because it is never
    // consulted. This test is the pin for that contract.
    var overlay = Overlay.init(testing.allocator);
    defer overlay.deinit();
    try overlay.replaceFromText(
        \\cmd=line x0=0 y0=0 x1=3 y1=0 thickness=1 color=#FFFFFFFF
        \\cmd=text x=0 y=1 color=#FFFFFFFF text="hi"
    );
    const dl = overlay.drawList().?;
    try testing.expectEqual(@as(usize, 2), dl.cmds.items.len);
    try testing.expectEqualStrings("hi", dl.cmds.items[1].text.text);

    var pixels = [_]u32{0} ** 16;
    overlay.render(.{ .pixels = &pixels, .width = 4, .height = 4 }, font_mod.default_font, 1.0);
    try testing.expect(pixels[0] != 0);
}

test "overlay: appendFromText OOM mid-clone leaves the command list unchanged" {
    const src_base = "cmd=rect_filled x=0 y=0 w=1 h=1 color=#FF000000";
    const src_append =
        \\cmd=text x=0 y=0 color=#FFFFFFFF text="a" cmd=text x=1 y=0 color=#FFFFFFFF text="b" cmd=text x=2 y=0 color=#FFFFFFFF text="c"
    ;

    var probe = testing.FailingAllocator.init(testing.allocator, .{});
    {
        var overlay = Overlay.init(probe.allocator());
        defer overlay.deinit();
        try overlay.replaceFromText(src_base);
        try overlay.appendFromText(src_append);
    }
    // The last three successful allocs of a successful append are the three
    // cloneCmd text dupes (ensureUnusedCapacity runs before the loop). Fail
    // on the second of those so the first clone has already been appended.
    const fail_index = probe.alloc_index - 3 + 1;

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
    var overlay = Overlay.init(failing.allocator());
    defer overlay.deinit();
    try overlay.replaceFromText(src_base);
    const before = overlay.retainedList().cmds.items.len;
    try testing.expectEqual(@as(usize, 1), before);
    try testing.expectError(error.OutOfMemory, overlay.appendFromText(src_append));
    try testing.expectEqual(before, overlay.retainedList().cmds.items.len);
}

test "overlay: failed appendFromText does not grow the arena" {
    var overlay = Overlay.init(testing.allocator);
    defer overlay.deinit();
    try overlay.replaceFromText("cmd=text x=0 y=0 color=#FFFFFFFF text=\"ok\"");
    const before = overlay.arena.queryCapacity();
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        try testing.expectError(error.UnknownVerb, overlay.appendFromText("cmd=not_a_verb x=0"));
        try testing.expectError(error.MalformedInput, overlay.appendFromText("garbage"));
        try testing.expectError(error.EmptyInput, overlay.appendFromText(""));
    }
    try testing.expectEqual(before, overlay.arena.queryCapacity());
    try testing.expectEqual(@as(usize, 1), overlay.drawList().?.cmds.items.len);
}

test "overlay: command cap matches the text-form cap" {
    var overlay = Overlay.init(testing.allocator);
    defer overlay.deinit();
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    var n: usize = 0;
    while (n < MAX_CMDS + 1) : (n += 1) {
        try list.appendSlice(testing.allocator, "cmd=rect_filled x=0 y=0 w=1 h=1 color=#FF000000 ");
    }
    try testing.expectError(error.TooManyCommands, overlay.replaceFromText(list.items));
    try testing.expect(overlay.drawList() == null);
}
