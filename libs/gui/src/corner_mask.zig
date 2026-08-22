//! Retained canonical quarter-circle coverage masks for rounded primitives.
//!
//! Hot path declaration: lookup runs once per rounded corner set per frame.
//! Rasterization runs only on a cache miss and visits at most `O(radius^2)`
//! coverage cells in horizontal bands. Sharp rectangles never call this file.

const std = @import("std");
const vector = @import("vector");

pub const payload_limit_bytes: usize = 4 * 1024 * 1024;
pub const entry_limit: usize = 64;

pub const CornerMaskKey = struct {
    device_radius: u32,
    scale_bits: u32,

    pub fn init(device_radius: u32, scale: f32) CornerMaskKey {
        return .{ .device_radius = device_radius, .scale_bits = @bitCast(scale) };
    }
};

pub const Diagnostics = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    allocations: u64 = 0,
    retained_bytes: usize = 0,
    entries: usize = 0,
    coverage_pixels: u64 = 0,
};

const Entry = struct {
    key: CornerMaskKey,
    coverage: []u8,
    stamp: u64,
};

pub const Cache = struct {
    entries: std.ArrayList(Entry) = .empty,
    clock: u64 = 0,
    diagnostics: Diagnostics = .{},

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.coverage);
        self.entries.deinit(allocator);
        self.* = .{};
    }

    pub fn key(device_radius: u32, scale: f32) CornerMaskKey {
        return .init(device_radius, scale);
    }

    pub fn payloadBytes(device_radius: u32) ?usize {
        return std.math.mul(usize, device_radius, device_radius) catch null;
    }

    pub fn cacheable(device_radius: u32) bool {
        const bytes = payloadBytes(device_radius) orelse return false;
        return bytes != 0 and bytes <= payload_limit_bytes;
    }

    pub fn lookup(self: *Cache, mask_key: CornerMaskKey) ?[]const u8 {
        self.clock +%= 1;
        for (self.entries.items) |*entry| {
            if (entry.key.device_radius == mask_key.device_radius and entry.key.scale_bits == mask_key.scale_bits) {
                entry.stamp = self.clock;
                self.diagnostics.hits +%= 1;
                return entry.coverage;
            }
        }
        self.diagnostics.misses +%= 1;
        return null;
    }

    /// Takes ownership of `coverage`. Whole least-recently-used entries are
    /// evicted until both cache limits hold.
    pub fn insertOwned(
        self: *Cache,
        allocator: std.mem.Allocator,
        mask_key: CornerMaskKey,
        coverage: []u8,
    ) std.mem.Allocator.Error![]const u8 {
        std.debug.assert(coverage.len == payloadBytes(mask_key.device_radius).?);
        std.debug.assert(coverage.len <= payload_limit_bytes);

        while (self.entries.items.len >= entry_limit) {
            self.evictLru(allocator);
        }

        self.clock +%= 1;
        try self.entries.append(allocator, .{
            .key = mask_key,
            .coverage = coverage,
            .stamp = self.clock,
        });
        self.diagnostics.allocations +%= 1;
        self.diagnostics.retained_bytes += coverage.len;
        self.diagnostics.entries = self.entries.items.len;
        return self.entries.items[self.entries.items.len - 1].coverage;
    }

    pub fn addCoveragePixels(self: *Cache, pixels: usize) void {
        self.diagnostics.coverage_pixels +%= pixels;
    }

    fn evictLru(self: *Cache, allocator: std.mem.Allocator) void {
        std.debug.assert(self.entries.items.len != 0);
        var oldest: usize = 0;
        for (self.entries.items[1..], 1..) |entry, i| {
            if (entry.stamp < self.entries.items[oldest].stamp) oldest = i;
        }
        const removed = self.entries.swapRemove(oldest);
        self.diagnostics.retained_bytes -= removed.coverage.len;
        allocator.free(removed.coverage);
        self.diagnostics.entries = self.entries.items.len;
    }
};

/// Rasterizes a canonical top-left quarter-circle sub-rectangle without
/// allocating. The caller bands the request so all three buffers fit its
/// retained scratch ceiling.
pub fn rasterizeBand(
    device_radius: u32,
    source_x: u32,
    source_y: u32,
    width: u32,
    height: u32,
    area: []f32,
    cover: []f32,
    coverage: []u8,
) void {
    if (device_radius == 0 or width == 0 or height == 0) return;
    std.debug.assert(source_x + width <= device_radius);
    std.debug.assert(source_y + height <= device_radius);

    const r: f32 = @floatFromInt(device_radius);
    const k: f32 = 0.5522847498307936;
    const segments = [_]vector.Segment{
        .{ .cubic = .{
            .c1 = .{ .x = r * (1.0 - k), .y = 0 },
            .c2 = .{ .x = 0, .y = r * (1.0 - k) },
            .end = .{ .x = 0, .y = r },
        } },
        .{ .line = .{ .x = r, .y = r } },
    };
    const contours = [_]vector.Contour{.{
        .start = .{ .x = r, .y = 0 },
        .segments = &segments,
    }};
    vector.rasterizeInto(
        .{ .contours = &contours },
        .{
            .sx = 1,
            .sy = 1,
            .dx = -@as(f32, @floatFromInt(source_x)),
            .dy = -@as(f32, @floatFromInt(source_y)),
        },
        width,
        height,
        area,
        cover,
        coverage,
    );
}

test "corner mask: canonical coverage has an empty outside corner and full inside corner" {
    const r: u32 = 8;
    var area: [r * r]f32 = undefined;
    var cover: [r * r]f32 = undefined;
    var coverage: [r * r]u8 = undefined;
    rasterizeBand(r, 0, 0, r, r, &area, &cover, &coverage);
    try std.testing.expect(coverage[0] < 128);
    try std.testing.expect(coverage[(r - 1) * r + (r - 1)] == 255);
}

test "corner mask: exact scale bits select distinct cache entries" {
    var cache: Cache = .{};
    defer cache.deinit(std.testing.allocator);
    const a = try std.testing.allocator.alloc(u8, 16);
    @memset(a, 1);
    _ = try cache.insertOwned(std.testing.allocator, .init(4, 1.0), a);
    try std.testing.expect(cache.lookup(.init(4, 1.0)) != null);
    try std.testing.expect(cache.lookup(.init(4, 1.5)) == null);
    try std.testing.expectEqual(@as(u64, 1), cache.diagnostics.hits);
    try std.testing.expectEqual(@as(u64, 1), cache.diagnostics.misses);
}

test "corner mask: reset retention is represented by cache lifetime and deinit is leak-free" {
    var cache: Cache = .{};
    defer cache.deinit(std.testing.allocator);
    const bytes = try std.testing.allocator.alloc(u8, 64);
    @memset(bytes, 7);
    _ = try cache.insertOwned(std.testing.allocator, .init(8, 2.0), bytes);
    try std.testing.expectEqual(@as(usize, 64), cache.diagnostics.retained_bytes);
    try std.testing.expect(cache.lookup(.init(8, 2.0)) != null);
}

test "corner mask: entry and payload limits evict whole least-recently-used entries" {
    var cache: Cache = .{};
    defer cache.deinit(std.testing.allocator);
    var radius: u32 = 1;
    while (radius <= entry_limit + 1) : (radius += 1) {
        const len = Cache.payloadBytes(radius).?;
        const bytes = try std.testing.allocator.alloc(u8, len);
        @memset(bytes, @intCast(radius));
        _ = try cache.insertOwned(std.testing.allocator, .init(radius, 1.0), bytes);
    }
    try std.testing.expectEqual(entry_limit, cache.entries.items.len);
    try std.testing.expect(cache.lookup(.init(1, 1.0)) == null);
    try std.testing.expect(cache.diagnostics.retained_bytes <= payload_limit_bytes);
    try std.testing.expect(!Cache.cacheable(2049));
}
