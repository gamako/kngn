//! Brush footprint edge-cell extraction + cache.
//!
//! Hot-path note: refresh() early-returns in O(1) when (size, hardness_q) match the previous call.
//! Only on change does it run O(footprint area) extraction (at most Brush.MAX_OFFSETS=4225 cells when size<=64)
//! and cache the result. Per frame only points() is read (caller draw cost is
//! O(edge-cell count = perimeter order)). The full-pixel-loop three-point set does not apply.
//!
//! Pure logic with no gui/kit dependency (same shape as canvas_input.zig / bezier_input.zig).
//! cursor_overlay.zig (draw-only) consumes EdgeCache. The caller (main.zig) must honor the
//! contract "call refresh only when not busy (no stroke in progress)": Brush.footprint()
//! re-runs buildDab() and overwrites brush.offsets_buf/dab_len on every call, which can break an
//! in-progress stroke (move/up reuse the footprint latched on down).

const std = @import("std");
const core = @import("paint");

/// Edge-cell offsets (relative to brush center). Same dx/dy width as core.Offset.
pub const Point = struct { dx: i16, dy: i16 };

const Brush = core.Brush;
const R_MAX: i32 = @intCast(Brush.MAX_SIZE / 2); // 32
const SPAN: usize = @intCast(2 * R_MAX + 1); // 65
const GRID_LEN: usize = SPAN * SPAN;

/// Same clamp as Brush.buildDab (size is 1..MAX_SIZE). Both EdgeCache and the tool probe (main.zig's
/// cursor digest) go through this function so size interpretation cannot drift.
pub fn clampedSize(brush: *const Brush) u32 {
    return std.math.clamp(brush.size, 1, Brush.MAX_SIZE);
}

/// Cache of edge cells for the current Brush footprint (size, hardness).
pub const EdgeCache = struct {
    size: u32 = 0,
    hardness_q: u8 = 0,
    valid: bool = false,
    pts: [Brush.MAX_OFFSETS]Point = undefined,
    len: usize = 0,
    /// Instrumentation (so tests can assert recomputation count).
    refresh_count: usize = 0,

    /// Recompute edge cells for the brush's current parameters. No-op when (clamped size, hardness_q) match the previous call
    /// (O(1)). On change only: brush.footprint() (runs buildDab) → edge extract O(footprint area).
    pub fn refresh(self: *EdgeCache, brush: *Brush) void {
        const size = clampedSize(brush);
        if (self.valid and self.size == size and self.hardness_q == brush.hardness_q) return;

        self.refresh_count += 1;
        self.size = size;
        self.hardness_q = brush.hardness_q;
        self.valid = true;
        self.len = 0;

        var grid: [GRID_LEN]bool = [_]bool{false} ** GRID_LEN;
        const dab = brush.footprint(); // Rebuild at the current size/hardness (runs buildDab)
        for (dab.offsets) |o| grid[gridIndex(o.dx, o.dy)] = true;
        for (dab.offsets) |o| {
            if (isEdge(&grid, o.dx, o.dy)) {
                std.debug.assert(self.len < Brush.MAX_OFFSETS);
                self.pts[self.len] = .{ .dx = o.dx, .dy = o.dy };
                self.len += 1;
            }
        }
    }

    pub fn points(self: *const EdgeCache) []const Point {
        return self.pts[0..self.len];
    }
};

fn gridIndex(dx: i16, dy: i16) usize {
    const gx: usize = @intCast(@as(i32, dx) + R_MAX);
    const gy: usize = @intCast(@as(i32, dy) + R_MAX);
    return gy * SPAN + gx;
}

/// Whether (dx,dy) is an edge cell of the footprint (edge if any 4-neighbour is non-footprint or outside the footprint bounds).
fn isEdge(grid: *const [GRID_LEN]bool, dx: i16, dy: i16) bool {
    const deltas = [_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
    for (deltas) |d| {
        const nx = @as(i32, dx) + d[0];
        const ny = @as(i32, dy) + d[1];
        if (nx < -R_MAX or nx > R_MAX or ny < -R_MAX or ny > R_MAX) return true;
        if (!grid[gridIndex(@intCast(nx), @intCast(ny))]) return true;
    }
    return false;
}

// ============================================================
// Tests
// ============================================================

test "EdgeCache.refresh: same (size,hardness) does not recompute (refresh_count unchanged)" {
    var b: Brush = .{ .color = 0xFFFF0000, .size = 8, .hardness_q = 255 };
    var cache: EdgeCache = .{};
    cache.refresh(&b);
    try std.testing.expectEqual(@as(usize, 1), cache.refresh_count);
    const len1 = cache.len;
    cache.refresh(&b);
    cache.refresh(&b);
    try std.testing.expectEqual(@as(usize, 1), cache.refresh_count);
    try std.testing.expectEqual(len1, cache.len);
}

test "EdgeCache.refresh: size change triggers recomputation" {
    var b: Brush = .{ .color = 0xFFFF0000, .size = 8, .hardness_q = 255 };
    var cache: EdgeCache = .{};
    cache.refresh(&b);
    try std.testing.expectEqual(@as(usize, 1), cache.refresh_count);
    b.size = 16;
    cache.refresh(&b);
    try std.testing.expectEqual(@as(usize, 2), cache.refresh_count);
}

test "EdgeCache.refresh: hardness_q change also triggers recomputation" {
    var b: Brush = .{ .color = 0xFFFF0000, .size = 16, .hardness_q = 255 };
    var cache: EdgeCache = .{};
    cache.refresh(&b);
    b.hardness_q = 64;
    cache.refresh(&b);
    try std.testing.expectEqual(@as(usize, 2), cache.refresh_count);
}

test "EdgeCache: size=1 has only the center point as an edge cell" {
    var b: Brush = .{ .color = 0xFFFF0000, .size = 1 };
    var cache: EdgeCache = .{};
    cache.refresh(&b);
    try std.testing.expectEqual(@as(usize, 1), cache.len);
    try std.testing.expectEqual(Point{ .dx = 0, .dy = 0 }, cache.points()[0]);
}

test "EdgeCache: size=64 (max) does not overflow; edge cells fewer than full footprint" {
    var b: Brush = .{ .color = 0xFFFF0000, .size = 64, .hardness_q = 255 };
    var cache: EdgeCache = .{};
    cache.refresh(&b);
    try std.testing.expect(cache.len > 0 and cache.len <= Brush.MAX_OFFSETS);
    const dab = b.footprint();
    try std.testing.expect(cache.len < dab.offsets.len); // Contour has fewer cells than the full footprint
}

test "EdgeCache: oversized size assignment still keeps key and footprint aligned via clampedSize" {
    var b: Brush = .{ .color = 0xFFFF0000, .size = 1000 }; // buildDab clamps to MAX_SIZE (64)
    var cache: EdgeCache = .{};
    cache.refresh(&b);
    try std.testing.expectEqual(Brush.MAX_SIZE, cache.size);
    const len1 = cache.len;
    cache.refresh(&b); // Calling again does not recompute: size=1000→clamped 64 is unchanged
    try std.testing.expectEqual(@as(usize, 1), cache.refresh_count);
    try std.testing.expectEqual(len1, cache.len);
}
