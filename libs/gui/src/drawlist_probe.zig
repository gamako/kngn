//! Turns a `DrawList` into text an AI or a test can assert on, instead of only a rendered
//! bitmap. An application wires `digest` and `dumpAlloc` into a `platform.registerProbe`
//! callback (harness's `drawlist` custom probe; see docs/harness.md) so `digest drawlist`
//! and `snapshot drawlist` work the same way `digest canvas` and `snapshot canvas` do for
//! the pixel editor.
//!
//! Hot path declaration: both functions walk `dl.cmds` once. They run only when a
//! `digest`/`snapshot` request asks for the `drawlist` probe (event-time only), never on
//! the per-frame draw path, so the per-pixel and real-time performance rules do not apply.
//!
//! Text format (one command per line, k=v pairs, space separated):
//!   Solid rectangles use `color=#AARRGGBB`; gradient rectangles use `paint=linear` or
//!   `paint=radial` followed by canonical colors and IEEE-754 bit fields.
//!   `cmd=rect_filled x=.. y=.. w=.. h=.. color=#AARRGGBB clip_x=.. clip_y=.. clip_w=.. clip_h=.. offclip=0|1`
//!   `cmd=rect_outline` adds `thickness=..` after `h=..`.
//!   Rounded rectangles add `radius=..`; default AA is omitted and AA off adds `aa=0`.
//!   `cmd=circle_filled` / `cmd=circle_outline` always carry `radius`; outline adds `thickness`.
//!   `cmd=line x0=.. y0=.. x1=.. y1=.. thickness=.. color=.. clip_.. offclip=..`
//!   `cmd=text x=.. y=.. color=.. font=default|custom clip_.. offclip=.. text="<escaped content>"`
//!   `cmd=image x=.. y=.. w=.. h=.. src_w=.. src_h=.. pixfnv=#XXXXXXXX clip_.. offclip=..`
//!   `cmd=path color=.. aa=0|1 winding=nonzero style=fill|stroke width=.. join=miter|bevel cap=butt|square|round miter_limit=.. verbs="MLQCZ" pts="<f32-hex pairs>" clip_.. offclip=..`
//!   `cmd=shadow x=.. y=.. w=.. h=.. color=.. radius=.. blur=.. dx=.. dy=.. cover_radius=.. clip_.. offclip=..`
//! `cover_radius=N` appears only on a shadow that `DrawList.box` queued under an opaque
//! background, and is the corner radius of that background: it says the renderer is
//! allowed to skip the shadow's center where the background will overwrite it. Its
//! absence means the center is painted. Like `offclip`, it is an observation — the
//! parser reads it back as absent, so an injected list cannot claim a cover.
//!
//! `offclip=1` means the command's own extent is not fully contained by the clip rect baked
//! into it (for `line`/`text`, "extent" is the endpoints/the draw position — the same signal
//! a truncated shape or a mis-placed label would produce). A scene with nothing accidentally
//! cut off has `offclip=0` on every line.
//!
//! `digest` hashes the same per-command text `dumpAlloc` emits (plus the path-wire
//! schema version) and reports a per-kind count and a total `offclip` count. Two
//! frames whose dump lines are byte-for-byte the same produce the same `hash`; the
//! counts alone stay stable across a frame with animated coordinates, because they
//! do not fold in position (see docs/harness.md for the trade-off between the two).
//! The schema version folded into the hash is the path-verb binary wire version;
//! the command dump itself is the canonical public text wire.

const std = @import("std");
const Allocator = std.mem.Allocator;
const draw_mod = @import("draw.zig");
const geom = @import("geom.zig");
const cmd_text = @import("draw_cmd_text.zig");
const wire = @import("drawlist_wire.zig");

pub const DrawCmd = draw_mod.DrawCmd;
pub const DrawList = draw_mod.DrawList;
pub const Rect = geom.Rect;

/// Whether `r` is entirely inside `clip` (a `rect`/`image` command's requested area is not
/// truncated by its baked-in clip).
fn rectFullyInside(r: Rect, clip: Rect) bool {
    const inter = Rect.intersect(r, clip);
    return inter.x == r.x and inter.y == r.y and inter.w == r.w and inter.h == r.h;
}

/// One line: a stable hash of the dump text of every command (plus the path-wire
/// schema version) and a per-kind count plus how many commands are `offclip`.
/// Fits inside the harness's 1024-byte digest contract regardless of `dl.cmds.len`.
pub fn digest(dl: *const DrawList, buf: []u8) []const u8 {
    var h = std.hash.Fnv1a_32.init();
    h.update(std.mem.asBytes(&wire.schema_version));
    var n_rect_filled: u32 = 0;
    var n_rect_outline: u32 = 0;
    var n_line: u32 = 0;
    var n_text: u32 = 0;
    var n_image: u32 = 0;
    var n_path: u32 = 0;
    var n_circle_filled: u32 = 0;
    var n_circle_outline: u32 = 0;
    var n_shadow: u32 = 0;
    var n_offclip: u32 = 0;

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(std.heap.page_allocator);

    for (dl.cmds.items) |cmd| {
        line.clearRetainingCapacity();
        cmd_text.appendCmd(&line, std.heap.page_allocator, cmd) catch return buf[0..0];
        h.update(line.items);
        switch (cmd) {
            .rect_filled => |c| {
                n_rect_filled += 1;
                if (!rectFullyInside(c.rect, c.clip)) n_offclip += 1;
            },
            .rect_outline => |c| {
                n_rect_outline += 1;
                if (!rectFullyInside(c.rect, c.clip)) n_offclip += 1;
            },
            .circle_filled => {
                n_circle_filled += 1;
                if (cmd_text.offclipOf(cmd) == 1) n_offclip += 1;
            },
            .circle_outline => {
                n_circle_outline += 1;
                if (cmd_text.offclipOf(cmd) == 1) n_offclip += 1;
            },
            .line => |c| {
                n_line += 1;
                if (!(c.clip.contains(c.p0) and c.clip.contains(c.p1))) n_offclip += 1;
            },
            .text => |c| {
                n_text += 1;
                if (!c.clip.contains(c.pos)) n_offclip += 1;
            },
            .image => |c| {
                n_image += 1;
                if (!rectFullyInside(c.rect, c.clip)) n_offclip += 1;
            },
            .path => {
                n_path += 1;
                if (cmd_text.offclipOf(cmd) == 1) n_offclip += 1;
            },
            .shadow => {
                n_shadow += 1;
                if (cmd_text.offclipOf(cmd) == 1) n_offclip += 1;
            },
        }
    }

    return std.fmt.bufPrint(buf, "hash={X:0>8} rect_filled={d} rect_outline={d} line={d} text={d} image={d} path={d} circle_filled={d} circle_outline={d} shadow={d} offclip={d}", .{
        h.final(), n_rect_filled, n_rect_outline, n_line, n_text, n_image, n_path, n_circle_filled, n_circle_outline, n_shadow, n_offclip,
    }) catch buf[0..0];
}

/// Full structure dump: `cmds=<N>` then one line per command, oldest first (draw order).
/// Unlike `digest`, `image` pixels are never embedded (only their dimensions and a content
/// hash); `text` content is embedded in full, unescaped-length included.
/// Each command line is emitted by walking the shared verb table in `draw_cmd_text.zig`.
pub fn dumpAlloc(allocator: Allocator, dl: *const DrawList) Allocator.Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try cmd_text.appendFmt(&list, allocator, "cmds={d}\n", .{dl.cmds.items.len});
    for (dl.cmds.items) |cmd| {
        try cmd_text.appendCmd(&list, allocator, cmd);
    }
    return list.toOwnedSlice(allocator);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "digest: fully-inside commands report offclip=0" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(100, 100);
    try dl.rectFilled(.{ .x = 10, .y = 10, .w = 20, .h = 20 }, draw_mod.Color.rgba(0xFF, 0, 0, 0xFF));
    try dl.text(.{ .x = 5, .y = 5 }, "hello", draw_mod.Color.rgba(0, 0, 0, 0xFF));

    var buf: [1024]u8 = undefined;
    const line = digest(&dl, &buf);
    try testing.expect(std.mem.indexOf(u8, line, "rect_filled=1") != null);
    try testing.expect(std.mem.indexOf(u8, line, "text=1") != null);
    try testing.expect(std.mem.indexOf(u8, line, "offclip=0") != null);
}

test "digest: a rect that pokes out of a pushed clip is offclip" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(100, 100);
    // Root clip is 0,0,100,100; narrow it to 0,0,30,30 and draw a rect that spills past it
    // (the same shape a panel with an under-cut bottom edge would leave behind).
    try dl.pushClip(.{ .x = 0, .y = 0, .w = 30, .h = 30 });
    try dl.rectFilled(.{ .x = 0, .y = 0, .w = 50, .h = 50 }, draw_mod.Color.rgba(0, 0xFF, 0, 0xFF));
    dl.popClip();

    var buf: [1024]u8 = undefined;
    const line = digest(&dl, &buf);
    try testing.expect(std.mem.indexOf(u8, line, "offclip=1") != null);
}

test "digest: a text position outside its own clip is offclip" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(100, 100);
    try dl.pushClip(.{ .x = 0, .y = 0, .w = 20, .h = 20 });
    try dl.text(.{ .x = 50, .y = 50 }, "off", draw_mod.Color.rgba(0, 0, 0, 0xFF));
    dl.popClip();

    var buf: [1024]u8 = undefined;
    const line = digest(&dl, &buf);
    try testing.expect(std.mem.indexOf(u8, line, "text=1") != null);
    try testing.expect(std.mem.indexOf(u8, line, "offclip=1") != null);
}

test "digest: deterministic across repeated calls on the same DrawList" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    try dl.rectFilled(.{ .x = 1, .y = 2, .w = 3, .h = 4 }, draw_mod.Color.rgba(1, 2, 3, 4));
    try dl.line(.{ .x = 0, .y = 0 }, .{ .x = 10, .y = 10 }, draw_mod.Color.rgba(5, 6, 7, 8), 2);

    var buf_a: [1024]u8 = undefined;
    var buf_b: [1024]u8 = undefined;
    const a = digest(&dl, &buf_a);
    const b = digest(&dl, &buf_b);
    try testing.expectEqualStrings(a, b);
}

test "digest: gradients keep the command counts and use the canonical paint dump" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    try dl.rectFilledPaint(.{ .x = 4, .y = 5, .w = 20, .h = 12 }, .{ .linear = .{
        .start = .{ .x = 4, .y = 5 },
        .end = .{ .x = 24, .y = 17 },
        .start_color = draw_mod.Color.rgba(0x10, 0x20, 0x30, 0xFF),
        .end_color = draw_mod.Color.rgba(0xA0, 0xB0, 0xC0, 0x80),
    } });

    var digest_buf: [1024]u8 = undefined;
    const line = digest(&dl, &digest_buf);
    try testing.expect(std.mem.indexOf(u8, line, "rect_filled=1") != null);
    try testing.expect(std.mem.indexOf(u8, line, "offclip=0") != null);

    const dump = try dumpAlloc(testing.allocator, &dl);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "paint=linear") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "color=") == null);
    try testing.expect(std.mem.indexOf(u8, dump, "x0=40800000") != null);
}

test "digest: circle counts append after the existing command counts" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    try dl.circleFilled(.{ .x = 20, .y = 20 }, 8, draw_mod.Color.rgba(1, 2, 3, 4), .{});
    try dl.circleOutline(.{ .x = 40, .y = 40 }, 9, draw_mod.Color.rgba(5, 6, 7, 8), 2, .{});
    var buf: [1024]u8 = undefined;
    const line = digest(&dl, &buf);
    try testing.expect(std.mem.indexOf(u8, line, "path=0 circle_filled=1 circle_outline=1 shadow=0 offclip=0") != null);
}

test "digest: hash changes when text content changes (position and counts held equal)" {
    var dl1 = DrawList.init(testing.allocator);
    defer dl1.deinit();
    dl1.reset(64, 64);
    try dl1.text(.{ .x = 1, .y = 1 }, "abc", draw_mod.Color.rgba(0, 0, 0, 0xFF));

    var dl2 = DrawList.init(testing.allocator);
    defer dl2.deinit();
    dl2.reset(64, 64);
    try dl2.text(.{ .x = 1, .y = 1 }, "xyz", draw_mod.Color.rgba(0, 0, 0, 0xFF));

    var buf1: [1024]u8 = undefined;
    var buf2: [1024]u8 = undefined;
    const d1 = digest(&dl1, &buf1);
    const d2 = digest(&dl2, &buf2);
    try testing.expect(!std.mem.eql(u8, d1, d2));
}

test "digest: image pixel content changes the hash without changing counts" {
    var dl1 = DrawList.init(testing.allocator);
    defer dl1.deinit();
    dl1.reset(64, 64);
    const px_a = [_]u32{ 0xFF000000, 0xFF000000, 0xFF000000, 0xFF000000 };
    try dl1.image(.{ .x = 0, .y = 0, .w = 2, .h = 2 }, &px_a, 2, 2);

    var dl2 = DrawList.init(testing.allocator);
    defer dl2.deinit();
    dl2.reset(64, 64);
    const px_b = [_]u32{ 0xFFFFFFFF, 0xFF000000, 0xFF000000, 0xFF000000 };
    try dl2.image(.{ .x = 0, .y = 0, .w = 2, .h = 2 }, &px_b, 2, 2);

    var buf1: [1024]u8 = undefined;
    var buf2: [1024]u8 = undefined;
    const d1 = digest(&dl1, &buf1);
    const d2 = digest(&dl2, &buf2);
    try testing.expect(!std.mem.eql(u8, d1, d2));
    try testing.expect(std.mem.indexOf(u8, d1, "image=1") != null);
    try testing.expect(std.mem.indexOf(u8, d2, "image=1") != null);
}

test "dumpAlloc: one line per command, in draw order, text content embedded" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    try dl.rectFilled(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, draw_mod.Color.rgba(0xFF, 0, 0, 0xFF));
    try dl.text(.{ .x = 1, .y = 1 }, "hi there", draw_mod.Color.rgba(0, 0, 0, 0xFF));

    const dump = try dumpAlloc(testing.allocator, &dl);
    defer testing.allocator.free(dump);

    try testing.expect(std.mem.indexOf(u8, dump, "cmds=2\n") != null);
    const rect_idx = std.mem.indexOf(u8, dump, "cmd=rect_filled").?;
    const text_idx = std.mem.indexOf(u8, dump, "cmd=text").?;
    try testing.expect(rect_idx < text_idx); // draw order preserved
    try testing.expect(std.mem.indexOf(u8, dump, "text=\"hi there\"") != null);
}

test "dumpAlloc: a quote and a newline inside text are escaped (stays one line)" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    try dl.text(.{ .x = 0, .y = 0 }, "a\"b\nc", draw_mod.Color.rgba(0, 0, 0, 0xFF));

    const dump = try dumpAlloc(testing.allocator, &dl);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "text=\"a\\\"b\\nc\"") != null);
    // Exactly two lines (the header plus the one command): no stray raw newline escaped from text.
    var newline_count: usize = 0;
    for (dump) |c| {
        if (c == '\n') newline_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), newline_count);
}

test "dumpAlloc: empty DrawList still has the header line" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(10, 10);
    const dump = try dumpAlloc(testing.allocator, &dl);
    defer testing.allocator.free(dump);
    try testing.expectEqualStrings("cmds=0\n", dump);
}

test "digest: a path command is counted and changes the hash" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = dl.beginPath(arena.allocator());
    try b.moveTo(.{ .x = 0, .y = 0 });
    try b.lineTo(.{ .x = 8, .y = 0 });
    try b.lineTo(.{ .x = 0, .y = 8 });
    try b.close();
    try b.finish(.{ .color = draw_mod.Color.rgba(0xFF, 0, 0, 0xFF) });

    var buf: [1024]u8 = undefined;
    const line = digest(&dl, &buf);
    try testing.expect(std.mem.indexOf(u8, line, "path=1") != null);
    try testing.expect(std.mem.indexOf(u8, line, "offclip=0") != null);
}

test "digest: a stroked path dumps width join and cap" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = dl.beginPath(arena.allocator());
    try b.moveTo(.{ .x = 2, .y = 2 });
    try b.lineTo(.{ .x = 20, .y = 2 });
    try b.stroke(.{
        .color = draw_mod.Color.rgba(0, 0, 0xFF, 0xFF),
        .width = 4,
        .join = .miter,
        .cap = .square,
    });

    const dump = try dumpAlloc(testing.allocator, &dl);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "style=stroke") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "width=4") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "join=miter") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "cap=square") != null);

    var buf: [1024]u8 = undefined;
    const line = digest(&dl, &buf);
    try testing.expect(std.mem.indexOf(u8, line, "path=1") != null);
}
