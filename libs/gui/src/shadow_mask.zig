//! Retained nine-slice coverage masks for box shadows.
//!
//! Hot path declaration: lookup and the nine-slice blit are per-frame operations.
//! Distance evaluation and allocation happen only when a bounded cache is filled.

const std = @import("std");

pub const payload_limit_bytes: usize = 4 * 1024 * 1024;
pub const retained_limit_bytes: usize = 8 * 1024 * 1024;
pub const entry_limit: usize = 32;

pub const ShadowMaskKey = struct {
    radius: u32,
    blur: u32,
    scale_bits: u32,

    pub fn init(radius: u32, blur: u32, scale: f32) ShadowMaskKey {
        return .{ .radius = radius, .blur = blur, .scale_bits = @bitCast(scale) };
    }
};

pub const Diagnostics = struct {
    evaluations: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    allocations: u64 = 0,
    retained_bytes: usize = 0,
    entries: usize = 0,
    blit_pixels: u64 = 0,
    evictions: u64 = 0,
};

pub const Mask = struct {
    radius: u32,
    blur: u32,
    extent: u32,
    corner: []const u8,
    edge: []const u8,
};

const Entry = struct {
    key: ShadowMaskKey,
    payload: []u8,
    stamp: u64,
};

pub const Error = std.mem.Allocator.Error || error{KeyTooLarge};

pub const Cache = struct {
    entries: std.ArrayList(Entry) = .empty,
    clock: u64 = 0,
    diagnostics: Diagnostics = .{},

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.payload);
        self.entries.deinit(allocator);
        self.* = .{};
    }

    pub fn reset(self: *Cache, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
    }

    pub fn payloadBytes(radius: u32, blur: u32) ?usize {
        const extent = extentFor(radius, blur) orelse return null;
        const corner = std.math.mul(usize, extent, extent) catch return null;
        return std.math.add(usize, corner, extent) catch null;
    }

    pub fn extentFor(radius: u32, blur: u32) ?u32 {
        const sum = std.math.add(u32, radius, blur) catch return null;
        return @max(sum, 1);
    }

    pub fn cacheable(radius: u32, blur: u32) bool {
        const bytes = payloadBytes(radius, blur) orelse return false;
        return bytes <= payload_limit_bytes and bytes <= retained_limit_bytes;
    }

    pub fn lookup(self: *Cache, key: ShadowMaskKey) ?Mask {
        self.clock +%= 1;
        for (self.entries.items) |*entry| {
            if (std.meta.eql(entry.key, key)) {
                entry.stamp = self.clock;
                self.diagnostics.hits +%= 1;
                return view(entry);
            }
        }
        self.diagnostics.misses +%= 1;
        return null;
    }

    pub fn getOrCreate(
        self: *Cache,
        allocator: std.mem.Allocator,
        key: ShadowMaskKey,
    ) Error!Mask {
        if (self.lookup(key)) |mask| return mask;
        const bytes = payloadBytes(key.radius, key.blur) orelse return error.KeyTooLarge;
        if (!cacheable(key.radius, key.blur)) return error.KeyTooLarge;

        const payload = try allocator.alloc(u8, bytes);
        errdefer allocator.free(payload);
        generate(payload, key.radius, key.blur);
        self.diagnostics.evaluations +%= 1;

        while (self.entries.items.len >= entry_limit or
            self.diagnostics.retained_bytes + bytes > retained_limit_bytes)
        {
            self.evictLru(allocator);
        }

        self.clock +%= 1;
        try self.entries.append(allocator, .{ .key = key, .payload = payload, .stamp = self.clock });
        self.diagnostics.allocations +%= 1;
        self.diagnostics.retained_bytes += bytes;
        self.diagnostics.entries = self.entries.items.len;
        return view(&self.entries.items[self.entries.items.len - 1]);
    }

    pub fn addBlitPixels(self: *Cache, pixels: usize) void {
        self.diagnostics.blit_pixels +%= pixels;
    }

    fn evictLru(self: *Cache, allocator: std.mem.Allocator) void {
        std.debug.assert(self.entries.items.len != 0);
        var oldest: usize = 0;
        for (self.entries.items[1..], 1..) |entry, i| {
            if (entry.stamp < self.entries.items[oldest].stamp) oldest = i;
        }
        const removed = self.entries.swapRemove(oldest);
        self.diagnostics.retained_bytes -= removed.payload.len;
        self.diagnostics.entries = self.entries.items.len;
        self.diagnostics.evictions +%= 1;
        allocator.free(removed.payload);
    }
};

fn view(entry: *const Entry) Mask {
    const extent = Cache.extentFor(entry.key.radius, entry.key.blur).?;
    const corner_len = @as(usize, extent) * extent;
    return .{
        .radius = entry.key.radius,
        .blur = entry.key.blur,
        .extent = extent,
        .corner = entry.payload[0..corner_len],
        .edge = entry.payload[corner_len..],
    };
}

fn generate(payload: []u8, radius: u32, blur: u32) void {
    const extent = Cache.extentFor(radius, blur).?;
    const corner_len = @as(usize, extent) * extent;
    const edge = payload[corner_len..];

    var i: u32 = 0;
    while (i < extent) : (i += 1) {
        edge[i] = coverage(sampleDistance(radius, blur, @as(f32, @floatFromInt(i)) + 0.5 - @as(f32, @floatFromInt(blur))), blur);
    }

    var y: u32 = 0;
    while (y < extent) : (y += 1) {
        var x: u32 = 0;
        while (x < extent) : (x += 1) {
            const fx = @as(f32, @floatFromInt(x)) + 0.5 - @as(f32, @floatFromInt(blur));
            const fy = @as(f32, @floatFromInt(y)) + 0.5 - @as(f32, @floatFromInt(blur));
            payload[@as(usize, y) * extent + x] = coverage(cornerDistance(radius, blur, fx, fy), blur);
        }
    }
}

fn cornerDistance(radius: u32, blur: u32, x: f32, y: f32) f32 {
    _ = blur;
    if (radius == 0) return @max(-x, -y);
    const r: f32 = @floatFromInt(radius);
    const qx = r - x;
    const qy = r - y;
    return @sqrt(qx * qx + qy * qy) - r;
}

fn sampleDistance(radius: u32, blur: u32, distance: f32) f32 {
    _ = radius;
    if (blur == 0) return -1.0;
    return -distance;
}

fn coverage(distance: f32, blur: u32) u8 {
    if (distance <= 0) return 255;
    if (blur == 0) return 0;
    const falloff = distance / @as(f32, @floatFromInt(blur));
    return @intFromFloat(@round(std.math.clamp(1.0 - falloff, 0.0, 1.0) * 255.0));
}

test "shadow mask: warm lookup does not evaluate or allocate" {
    var cache: Cache = .{};
    defer cache.deinit(std.testing.allocator);
    const key = ShadowMaskKey.init(12, 8, 1.0);
    _ = try cache.getOrCreate(std.testing.allocator, key);
    const cold = cache.diagnostics;
    _ = try cache.getOrCreate(std.testing.allocator, key);
    try std.testing.expectEqual(cold.evaluations, cache.diagnostics.evaluations);
    try std.testing.expectEqual(cold.allocations, cache.diagnostics.allocations);
    try std.testing.expectEqual(@as(u64, 1), cache.diagnostics.hits);
}

test "shadow mask: radius, blur, and scale bits select distinct entries" {
    var cache: Cache = .{};
    defer cache.deinit(std.testing.allocator);
    _ = try cache.getOrCreate(std.testing.allocator, ShadowMaskKey.init(8, 4, 1.0));
    _ = try cache.getOrCreate(std.testing.allocator, ShadowMaskKey.init(9, 4, 1.0));
    _ = try cache.getOrCreate(std.testing.allocator, ShadowMaskKey.init(9, 5, 1.0));
    _ = try cache.getOrCreate(std.testing.allocator, ShadowMaskKey.init(9, 5, 1.5));
    try std.testing.expectEqual(@as(u64, 4), cache.diagnostics.evaluations);
    try std.testing.expectEqual(@as(usize, 4), cache.diagnostics.entries);
}

test "shadow mask: bounded cache evicts least recently used entries" {
    var cache: Cache = .{};
    defer cache.deinit(std.testing.allocator);
    var radius: u32 = 1;
    while (radius <= entry_limit + 1) : (radius += 1) {
        _ = try cache.getOrCreate(std.testing.allocator, ShadowMaskKey.init(radius, 0, 1.0));
    }
    try std.testing.expectEqual(entry_limit, cache.entries.items.len);
    try std.testing.expect(cache.lookup(ShadowMaskKey.init(1, 0, 1.0)) == null);
    try std.testing.expect(cache.diagnostics.evictions > 0);
    try std.testing.expect(cache.diagnostics.retained_bytes <= retained_limit_bytes);
}

test "shadow mask: oversized payload fails instead of falling back" {
    var cache: Cache = .{};
    defer cache.deinit(std.testing.allocator);
    try std.testing.expectError(error.KeyTooLarge, cache.getOrCreate(std.testing.allocator, ShadowMaskKey.init(4096, 4096, 1.0)));
    try std.testing.expectEqual(@as(u64, 0), cache.diagnostics.evaluations);
}

test "shadow mask: zero radius and blur still provide an opaque center sample" {
    var cache: Cache = .{};
    defer cache.deinit(std.testing.allocator);
    const mask = try cache.getOrCreate(std.testing.allocator, ShadowMaskKey.init(0, 0, 1.0));
    try std.testing.expectEqual(@as(u32, 1), mask.extent);
    try std.testing.expectEqual(@as(u8, 255), mask.corner[0]);
    try std.testing.expectEqual(@as(u8, 255), mask.edge[0]);
}

test "shadow mask: blur profile fades from the outside toward the panel" {
    var cache: Cache = .{};
    defer cache.deinit(std.testing.allocator);
    const mask = try cache.getOrCreate(std.testing.allocator, ShadowMaskKey.init(12, 8, 1.0));
    try std.testing.expect(mask.edge[0] < 32);
    try std.testing.expect(mask.edge[7] > 200);
}
