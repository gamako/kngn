//! Visual diff: u32 pixel compare of a baseline snapshot against the current frame.
//! std only; unit-testable without App/kit. Runs on events only (digest/diff_mark).

const std = @import("std");

pub const DiffResult = struct {
    changed: u32,
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
    from: u32,
    to: u32,
};

/// Compare `base`/`cur` for exact u32 match (including alpha); return changed count, bounding box, and most-frequent before/after colors.
/// bbox is inclusive. When changed=0, bbox/from/to are 0 (caller maps that to a none display).
/// Most-frequent-color ties break by ascending color (independent of hashmap iteration order).
pub fn computeDiff(allocator: std.mem.Allocator, base: []const u32, cur: []const u32, w: u32, h: u32) !DiffResult {
    std.debug.assert(base.len == cur.len);
    std.debug.assert(base.len == @as(usize, w) * @as(usize, h));

    var changed: u32 = 0;
    var x0: u32 = w; // sentinel: unchanged → changed=0
    var y0: u32 = h;
    var x1: u32 = 0;
    var y1: u32 = 0;

    var from_counts = std.AutoHashMap(u32, u32).init(allocator);
    defer from_counts.deinit();
    var to_counts = std.AutoHashMap(u32, u32).init(allocator);
    defer to_counts.deinit();

    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = @as(usize, y) * @as(usize, w);
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const i = row + x;
            const b = base[i];
            const c = cur[i];
            if (b == c) continue;
            changed += 1;
            if (x < x0) x0 = x;
            if (y < y0) y0 = y;
            if (x > x1) x1 = x;
            if (y > y1) y1 = y;
            {
                const gop = try from_counts.getOrPut(b);
                if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
            }
            {
                const gop = try to_counts.getOrPut(c);
                if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
            }
        }
    }

    if (changed == 0) {
        return .{ .changed = 0, .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0, .from = 0, .to = 0 };
    }
    return .{
        .changed = changed,
        .x0 = x0,
        .y0 = y0,
        .x1 = x1,
        .y1 = y1,
        .from = modeColor(from_counts),
        .to = modeColor(to_counts),
    };
}

fn modeColor(counts: std.AutoHashMap(u32, u32)) u32 {
    var best_color: u32 = 0;
    var best_count: u32 = 0;
    var it = counts.iterator();
    while (it.next()) |e| {
        const color = e.key_ptr.*;
        const count = e.value_ptr.*;
        if (count > best_count or (count == best_count and color < best_color)) {
            best_count = count;
            best_color = color;
        }
    }
    return best_color;
}

/// Same extract as toolDigest: u32 >>16=R, >>8=G, &0xFF=B (alpha ignored).
pub fn rgbChannels(c: u32) struct { r: u8, g: u8, b: u8 } {
    return .{
        .r = @truncate(c >> 16),
        .g = @truncate(c >> 8),
        .b = @truncate(c),
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn fill(buf: []u32, color: u32) void {
    @memset(buf, color);
}

fn idx(x: u32, y: u32, w: u32) usize {
    return @as(usize, y) * @as(usize, w) + @as(usize, x);
}

test "byte layout: 0xAARRGGBB >>16/>>8/&FF are R/G/B" {
    // compositeStraight / palette convention is u32=0xAARRGGBB (little-endian memory: B,G,R,A).
    // Pin with one pixel that the same extract as toolDigest yields #RRGGBB.
    const px: u32 = 0xFF112233; // A=FF R=11 G=22 B=33
    const rgb = rgbChannels(px);
    try testing.expectEqual(@as(u8, 0x11), rgb.r);
    try testing.expectEqual(@as(u8, 0x22), rgb.g);
    try testing.expectEqual(@as(u8, 0x33), rgb.b);
    // little-endian memory order: [B,G,R,A]
    const bytes = std.mem.asBytes(&px);
    try testing.expectEqual(@as(u8, 0x33), bytes[0]);
    try testing.expectEqual(@as(u8, 0x22), bytes[1]);
    try testing.expectEqual(@as(u8, 0x11), bytes[2]);
    try testing.expectEqual(@as(u8, 0xFF), bytes[3]);
}

test "unchanged: changed=0" {
    const w: u32 = 4;
    const h: u32 = 4;
    var base: [16]u32 = undefined;
    fill(&base, 0xFF000000);
    var cur = base;
    const r = try computeDiff(testing.allocator, &base, &cur, w, h);
    try testing.expectEqual(@as(u32, 0), r.changed);
}

test "one pixel changed: changed=1 / bbox / from/to" {
    const w: u32 = 8;
    const h: u32 = 8;
    var base: [64]u32 = undefined;
    fill(&base, 0xFF112233);
    var cur = base;
    const from_c: u32 = 0xFF112233;
    const to_c: u32 = 0xFFAABBCC;
    cur[idx(3, 5, w)] = to_c;
    const r = try computeDiff(testing.allocator, &base, &cur, w, h);
    try testing.expectEqual(@as(u32, 1), r.changed);
    try testing.expectEqual(@as(u32, 3), r.x0);
    try testing.expectEqual(@as(u32, 5), r.y0);
    try testing.expectEqual(@as(u32, 3), r.x1);
    try testing.expectEqual(@as(u32, 5), r.y1);
    try testing.expectEqual(from_c, r.from);
    try testing.expectEqual(to_c, r.to);
}

test "two distant pixels: bbox is the enclosing rect" {
    const w: u32 = 16;
    const h: u32 = 16;
    var base: [256]u32 = undefined;
    fill(&base, 0xFF000000);
    var cur = base;
    cur[idx(2, 3, w)] = 0xFFFF0000;
    cur[idx(10, 12, w)] = 0xFF00FF00;
    const r = try computeDiff(testing.allocator, &base, &cur, w, h);
    try testing.expectEqual(@as(u32, 2), r.changed);
    try testing.expectEqual(@as(u32, 2), r.x0);
    try testing.expectEqual(@as(u32, 3), r.y0);
    try testing.expectEqual(@as(u32, 10), r.x1);
    try testing.expectEqual(@as(u32, 12), r.y1);
}

test "most-frequent color: 3px A→B and 1px C→D → from=A to=B" {
    const w: u32 = 8;
    const h: u32 = 8;
    const A: u32 = 0xFF111111;
    const B: u32 = 0xFF222222;
    const C: u32 = 0xFF333333;
    const D: u32 = 0xFF444444;
    var base: [64]u32 = undefined;
    fill(&base, 0xFF000000);
    base[idx(0, 0, w)] = A;
    base[idx(1, 0, w)] = A;
    base[idx(2, 0, w)] = A;
    base[idx(3, 0, w)] = C;
    var cur = base;
    cur[idx(0, 0, w)] = B;
    cur[idx(1, 0, w)] = B;
    cur[idx(2, 0, w)] = B;
    cur[idx(3, 0, w)] = D;
    const r = try computeDiff(testing.allocator, &base, &cur, w, h);
    try testing.expectEqual(@as(u32, 4), r.changed);
    try testing.expectEqual(A, r.from);
    try testing.expectEqual(B, r.to);
}

test "all pixels changed: changed=65536 / bbox=0,0,255,255" {
    const w: u32 = 256;
    const h: u32 = 256;
    const n = @as(usize, w) * @as(usize, h);
    const base = try testing.allocator.alloc(u32, n);
    defer testing.allocator.free(base);
    const cur = try testing.allocator.alloc(u32, n);
    defer testing.allocator.free(cur);
    fill(base, 0xFF000000);
    fill(cur, 0xFFFFFFFF);
    const r = try computeDiff(testing.allocator, base, cur, w, h);
    try testing.expectEqual(@as(u32, 65536), r.changed);
    try testing.expectEqual(@as(u32, 0), r.x0);
    try testing.expectEqual(@as(u32, 0), r.y0);
    try testing.expectEqual(@as(u32, 255), r.x1);
    try testing.expectEqual(@as(u32, 255), r.y1);
    try testing.expectEqual(@as(u32, 0xFF000000), r.from);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), r.to);
}

test "edge (0,0 and 255,255) bbox" {
    const w: u32 = 256;
    const h: u32 = 256;
    const n = @as(usize, w) * @as(usize, h);
    const base = try testing.allocator.alloc(u32, n);
    defer testing.allocator.free(base);
    const cur = try testing.allocator.alloc(u32, n);
    defer testing.allocator.free(cur);
    fill(base, 0xFF000000);
    @memcpy(cur, base);
    cur[idx(0, 0, w)] = 0xFFFF0000;
    cur[idx(255, 255, w)] = 0xFF00FF00;
    const r = try computeDiff(testing.allocator, base, cur, w, h);
    try testing.expectEqual(@as(u32, 2), r.changed);
    try testing.expectEqual(@as(u32, 0), r.x0);
    try testing.expectEqual(@as(u32, 0), r.y0);
    try testing.expectEqual(@as(u32, 255), r.x1);
    try testing.expectEqual(@as(u32, 255), r.y1);
}
