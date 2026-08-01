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
//!   `cmd=rect_filled x=.. y=.. w=.. h=.. color=#AARRGGBB clip_x=.. clip_y=.. clip_w=.. clip_h=.. offclip=0|1`
//!   `cmd=rect_outline` adds `thickness=..` after `h=..`.
//!   `cmd=line x0=.. y0=.. x1=.. y1=.. thickness=.. color=.. clip_.. offclip=..`
//!   `cmd=text x=.. y=.. color=.. font=default|custom clip_.. offclip=.. text="<escaped content>"`
//!   `cmd=image x=.. y=.. w=.. h=.. src_w=.. src_h=.. pixfnv=#XXXXXXXX clip_.. offclip=..`
//! `offclip=1` means the command's own extent is not fully contained by the clip rect baked
//! into it (for `line`/`text`, "extent" is the endpoints/the draw position — the same signal
//! a truncated shape or a mis-placed label would produce). A scene with nothing accidentally
//! cut off has `offclip=0` on every line.
//!
//! `digest` folds the same per-command fields into one line: a stable hash plus a
//! per-kind count and a total `offclip` count. Two frames whose commands are byte-for-byte
//! the same (including the `text` slice and, for `image`, the pixel content) produce the
//! same `hash`; the counts alone stay stable across a frame with animated coordinates,
//! because they do not fold in position (see docs/harness.md for the trade-off between the
//! two).

const std = @import("std");
const Allocator = std.mem.Allocator;
const draw_mod = @import("draw.zig");
const geom = @import("geom.zig");

pub const DrawCmd = draw_mod.DrawCmd;
pub const DrawList = draw_mod.DrawList;
pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;

/// Whether `r` is entirely inside `clip` (a `rect`/`image` command's requested area is not
/// truncated by its baked-in clip).
fn rectFullyInside(r: Rect, clip: Rect) bool {
    const inter = Rect.intersect(r, clip);
    return inter.x == r.x and inter.y == r.y and inter.w == r.w and inter.h == r.h;
}

fn colorBits(c: draw_mod.Color) u32 {
    return @bitCast(c);
}

fn hashRect(h: *std.hash.Fnv1a_32, r: Rect) void {
    h.update(std.mem.asBytes(&r.x));
    h.update(std.mem.asBytes(&r.y));
    h.update(std.mem.asBytes(&r.w));
    h.update(std.mem.asBytes(&r.h));
}

fn hashVec2(h: *std.hash.Fnv1a_32, v: Vec2) void {
    h.update(std.mem.asBytes(&v.x));
    h.update(std.mem.asBytes(&v.y));
}

/// One line: a stable hash over every command's fields (text content and image pixels
/// included) plus a per-kind count and how many commands are `offclip`. Fits comfortably
/// inside the harness's 1024-byte digest contract regardless of `dl.cmds.len`, because the
/// hash is folded incrementally rather than building a per-command string first.
pub fn digest(dl: *const DrawList, buf: []u8) []const u8 {
    var h = std.hash.Fnv1a_32.init();
    var n_rect_filled: u32 = 0;
    var n_rect_outline: u32 = 0;
    var n_line: u32 = 0;
    var n_text: u32 = 0;
    var n_image: u32 = 0;
    var n_offclip: u32 = 0;

    for (dl.cmds.items) |cmd| {
        switch (cmd) {
            .rect_filled => |c| {
                n_rect_filled += 1;
                if (!rectFullyInside(c.rect, c.clip)) n_offclip += 1;
                h.update("RF");
                hashRect(&h, c.rect);
                h.update(std.mem.asBytes(&colorBits(c.color)));
                hashRect(&h, c.clip);
            },
            .rect_outline => |c| {
                n_rect_outline += 1;
                if (!rectFullyInside(c.rect, c.clip)) n_offclip += 1;
                h.update("RO");
                hashRect(&h, c.rect);
                h.update(std.mem.asBytes(&colorBits(c.color)));
                h.update(std.mem.asBytes(&c.thickness));
                hashRect(&h, c.clip);
            },
            .line => |c| {
                n_line += 1;
                if (!(c.clip.contains(c.p0) and c.clip.contains(c.p1))) n_offclip += 1;
                h.update("LN");
                hashVec2(&h, c.p0);
                hashVec2(&h, c.p1);
                h.update(std.mem.asBytes(&colorBits(c.color)));
                h.update(std.mem.asBytes(&c.thickness));
                hashRect(&h, c.clip);
            },
            .text => |c| {
                n_text += 1;
                if (!c.clip.contains(c.pos)) n_offclip += 1;
                h.update("TX");
                hashVec2(&h, c.pos);
                h.update(std.mem.asBytes(&colorBits(c.color)));
                hashRect(&h, c.clip);
                h.update(c.text);
            },
            .image => |c| {
                n_image += 1;
                if (!rectFullyInside(c.rect, c.clip)) n_offclip += 1;
                h.update("IM");
                hashRect(&h, c.rect);
                h.update(std.mem.asBytes(&c.src_w));
                h.update(std.mem.asBytes(&c.src_h));
                hashRect(&h, c.clip);
                h.update(std.mem.sliceAsBytes(c.pixels));
            },
        }
    }

    return std.fmt.bufPrint(buf, "hash={X:0>8} rect_filled={d} rect_outline={d} line={d} text={d} image={d} offclip={d}", .{
        h.final(), n_rect_filled, n_rect_outline, n_line, n_text, n_image, n_offclip,
    }) catch buf[0..0];
}

/// Appends a value formatted with `fmt` to `list`, falling back to an allocated scratch
/// buffer for the rare field wider than the inline stack buffer (no field emitted by
/// `appendCmdLine` is expected to exceed it; the fallback only guards against a future field).
fn appendFmt(list: *std.ArrayList(u8), allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
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
/// quote inside it does not break the one-line-per-command contract). The same escape
/// table as a JSON string (`history_summary.zig`'s `appendJsonStr`), duplicated here
/// because this file has no JSON dependency of its own.
fn appendEscapedText(list: *std.ArrayList(u8), allocator: Allocator, s: []const u8) !void {
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

fn appendCmdLine(list: *std.ArrayList(u8), allocator: Allocator, cmd: DrawCmd) !void {
    switch (cmd) {
        .rect_filled => |c| try appendFmt(list, allocator, "cmd=rect_filled x={d} y={d} w={d} h={d} color=#{X:0>8} clip_x={d} clip_y={d} clip_w={d} clip_h={d} offclip={d}\n", .{
            c.rect.x, c.rect.y, c.rect.w, c.rect.h, colorBits(c.color),
            c.clip.x, c.clip.y, c.clip.w, c.clip.h, @intFromBool(!rectFullyInside(c.rect, c.clip)),
        }),
        .rect_outline => |c| try appendFmt(list, allocator, "cmd=rect_outline x={d} y={d} w={d} h={d} thickness={d} color=#{X:0>8} clip_x={d} clip_y={d} clip_w={d} clip_h={d} offclip={d}\n", .{
            c.rect.x, c.rect.y, c.rect.w, c.rect.h, c.thickness, colorBits(c.color),
            c.clip.x, c.clip.y, c.clip.w, c.clip.h, @intFromBool(!rectFullyInside(c.rect, c.clip)),
        }),
        .line => |c| try appendFmt(list, allocator, "cmd=line x0={d} y0={d} x1={d} y1={d} thickness={d} color=#{X:0>8} clip_x={d} clip_y={d} clip_w={d} clip_h={d} offclip={d}\n", .{
            c.p0.x, c.p0.y, c.p1.x, c.p1.y, c.thickness, colorBits(c.color),
            c.clip.x, c.clip.y, c.clip.w, c.clip.h, @intFromBool(!(c.clip.contains(c.p0) and c.clip.contains(c.p1))),
        }),
        .text => |c| {
            try appendFmt(list, allocator, "cmd=text x={d} y={d} color=#{X:0>8} font={s} clip_x={d} clip_y={d} clip_w={d} clip_h={d} offclip={d} text=", .{
                c.pos.x, c.pos.y, colorBits(c.color), if (c.font == null) "default" else "custom",
                c.clip.x, c.clip.y, c.clip.w, c.clip.h, @intFromBool(!c.clip.contains(c.pos)),
            });
            try appendEscapedText(list, allocator, c.text);
            try list.append(allocator, '\n');
        },
        .image => |c| {
            const pixfnv = std.hash.Fnv1a_32.hash(std.mem.sliceAsBytes(c.pixels));
            try appendFmt(list, allocator, "cmd=image x={d} y={d} w={d} h={d} src_w={d} src_h={d} pixfnv=#{X:0>8} clip_x={d} clip_y={d} clip_w={d} clip_h={d} offclip={d}\n", .{
                c.rect.x, c.rect.y, c.rect.w, c.rect.h, c.src_w, c.src_h, pixfnv,
                c.clip.x, c.clip.y, c.clip.w, c.clip.h, @intFromBool(!rectFullyInside(c.rect, c.clip)),
            });
        },
    }
}

/// Full structure dump: `cmds=<N>` then one line per command, oldest first (draw order).
/// Unlike `digest`, `image` pixels are never embedded (only their dimensions and a content
/// hash); `text` content is embedded in full, unescaped-length included.
pub fn dumpAlloc(allocator: Allocator, dl: *const DrawList) Allocator.Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try appendFmt(&list, allocator, "cmds={d}\n", .{dl.cmds.items.len});
    for (dl.cmds.items) |cmd| {
        try appendCmdLine(&list, allocator, cmd);
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
