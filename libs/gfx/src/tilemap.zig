//! Tilemap drawing + solid AABB collision / resolution.
//!
//! `TileMap` is a non-owning type; it does not own the Atlas, map array, or flag array.
//! Tile IDs are 1:1 with Atlas frame indices. `EmptyTile` is the empty-cell sentinel.
//!
//! Hot-path declaration:
//! - `draw`: every frame. Walks only candidate tiles from visibleRect; each tile
//!   delegates to `Atlas.drawFrame` → existing `drawSpriteEx` (SIMD path). No new full-pixel loop.
//! - `queryAabb` / `resolveAabb`: every logical update. Walks only AABB candidate tiles; allocation-free.
//! - Map / Atlas / flag allocation is init-time only (outside this module).

const std = @import("std");
const atlas_mod = @import("atlas.zig");
const camera_mod = @import("camera.zig");
const sprite = @import("sprite");
const gmath = @import("gmath");

const Atlas = atlas_mod.Atlas;
const Camera = camera_mod.Camera;
const SpriteDrawOptions = sprite.SpriteDrawOptions;

/// Reserved tile ID for empty cells. Atlas frame index `0` remains a valid tile.
pub const EmptyTile: u16 = std.math.maxInt(u16);

/// Per-tile-kind (Atlas frame) collision and draw flags.
/// Note: `opaque` is a Zig reserved word, so the field is `@"opaque"`.
pub const TileFlags = struct {
    solid: bool = false,
    /// When true, drawing uses the `SpriteDrawOptions.@"opaque"` path (init verifies every pixel alpha=255).
    @"opaque": bool = false,
};

pub const TileMapError = error{
    /// `width * height` does not match `tiles.len`
    DimensionMismatch,
    /// Tile ID is outside the Atlas frame range
    TileIdOutOfRange,
    /// `flags.len` does not match the Atlas frame count
    FlagsLengthMismatch,
    /// Tile size does not match Atlas frames
    TileSizeMismatch,
    /// An `opaque=true` frame has a pixel with alpha≠255
    OpaqueAlphaViolation,
    /// Tile width/height is 0
    ZeroTileSize,
    /// width/height multiplication overflows
    DimensionOverflow,
};

/// Non-owning tilemap that borrows an Atlas.
pub const TileMap = struct {
    atlas: *const Atlas,
    tiles: []const u16,
    flags: []const TileFlags,
    width: u32,
    height: u32,
    tile_width: u32,
    tile_height: u32,

    /// Build a TileMap with validation (ownership is not transferred).
    pub fn init(
        atlas: *const Atlas,
        tiles: []const u16,
        flags: []const TileFlags,
        width: u32,
        height: u32,
        tile_width: u32,
        tile_height: u32,
    ) TileMapError!TileMap {
        if (tile_width == 0 or tile_height == 0) return error.ZeroTileSize;

        const cell_count = std.math.mul(usize, width, height) catch return error.DimensionOverflow;
        if (tiles.len != cell_count) return error.DimensionMismatch;

        const frame_count = atlas.frameCount();
        if (flags.len != frame_count) return error.FlagsLengthMismatch;

        for (atlas.frames) |fr| {
            if (fr.w != tile_width or fr.h != tile_height) return error.TileSizeMismatch;
        }

        for (tiles) |id| {
            if (id == EmptyTile) continue;
            if (@as(usize, id) >= frame_count) return error.TileIdOutOfRange;
        }

        // opaque=true frames require every pixel alpha=255 (srcOverOpaque premise).
        for (flags, 0..) |f, fi| {
            if (!f.@"opaque") continue;
            const fr = atlas.frames[fi];
            var py: u32 = 0;
            while (py < fr.h) : (py += 1) {
                var px: u32 = 0;
                while (px < fr.w) : (px += 1) {
                    const idx = (fr.y + py) * atlas.image.width + (fr.x + px);
                    const a: u8 = @truncate(atlas.image.pixels[idx] >> 24);
                    if (a != 255) return error.OpaqueAlphaViolation;
                }
            }
        }

        return .{
            .atlas = atlas,
            .tiles = tiles,
            .flags = flags,
            .width = width,
            .height = height,
            .tile_width = tile_width,
            .tile_height = tile_height,
        };
    }

    /// Draw only tiles inside the world-visible rect.
    /// Each tile delegates to `Atlas.drawFrame` (no new full-pixel loop).
    pub fn draw(
        self: *const TileMap,
        framebuffer: []u32,
        fb_width: u32,
        fb_height: u32,
        cam: Camera,
        viewport: camera_mod.Rect,
    ) void {
        if (self.width == 0 or self.height == 0) return;

        const vis = cam.visibleRect(viewport);
        const tw: f32 = @floatFromInt(self.tile_width);
        const th: f32 = @floatFromInt(self.tile_height);

        // Visible range → tile indices (@floor is consistent for negatives). Bottom-right is exclusive.
        var tx0: i32 = @intFromFloat(@floor(vis.x / tw));
        var ty0: i32 = @intFromFloat(@floor(vis.y / th));
        var tx1: i32 = @intFromFloat(@ceil((vis.x + vis.w) / tw));
        var ty1: i32 = @intFromFloat(@ceil((vis.y + vis.h) / th));

        // Clamp to map bounds before the loop
        const map_w: i32 = @intCast(self.width);
        const map_h: i32 = @intCast(self.height);
        if (tx0 < 0) tx0 = 0;
        if (ty0 < 0) ty0 = 0;
        if (tx1 > map_w) tx1 = map_w;
        if (ty1 > map_h) ty1 = map_h;
        if (tx0 >= tx1 or ty0 >= ty1) return;

        const zoom = cam.zoom;
        const scale: u32 = if (zoom == 0) 1 else zoom;

        var ty: i32 = ty0;
        while (ty < ty1) : (ty += 1) {
            const row_base: usize = @as(usize, @intCast(ty)) * @as(usize, self.width);
            var tx: i32 = tx0;
            while (tx < tx1) : (tx += 1) {
                const id = self.tiles[row_base + @as(usize, @intCast(tx))];
                if (id == EmptyTile) continue;

                const world_x = @as(f32, @floatFromInt(tx)) * tw;
                const world_y = @as(f32, @floatFromInt(ty)) * th;
                const screen = cam.worldToScreen(.{ .x = world_x, .y = world_y }, viewport);
                const sx: i32 = @intFromFloat(@floor(screen.x));
                const sy: i32 = @intFromFloat(@floor(screen.y));

                const is_opaque = self.flags[id].@"opaque";
                const opts = SpriteDrawOptions{
                    .scale = scale,
                    .@"opaque" = is_opaque,
                };
                self.atlas.drawFrame(framebuffer, fb_width, fb_height, sx, sy, id, opts);
            }
        }
    }

    /// Return an iterator that enumerates solid tiles intersecting the body AABB in row-major order.
    pub fn queryAabb(self: *const TileMap, body: gmath.Rect) QueryIterator {
        var it = QueryIterator{
            .map = self,
            .body = body,
            .tx = 0,
            .ty = 0,
            .tx0 = 0,
            .ty0 = 0,
            .tx1 = 0,
            .ty1 = 0,
            .done = true,
        };
        if (body.isEmpty() or self.width == 0 or self.height == 0) return it;

        const range = self.tileRangeForAabb(body) orelse return it;
        it.tx0 = range.tx0;
        it.ty0 = range.ty0;
        it.tx1 = range.tx1;
        it.ty1 = range.ty1;
        it.tx = range.tx0;
        it.ty = range.ty0;
        it.done = false;
        return it;
    }

    /// Max-penetration-first push-out against solid tiles (fixed iterations; deterministic).
    pub fn resolveAabb(self: *const TileMap, body: *gmath.Rect) ResolveResult {
        var result = ResolveResult{};
        if (body.isEmpty()) return result;

        const max_iter: u8 = ResolveMaxIterations;
        var i: u8 = 0;
        while (i < max_iter) : (i += 1) {
            const contact = self.deepestContact(body.*) orelse {
                result.iterations = i;
                return result;
            };
            result.iterations = i + 1;

            // Push out by normal * depth (normal is tile→body = the direction the body is pushed)
            body.x += contact.collision.normal.x * contact.collision.depth;
            body.y += contact.collision.normal.y * contact.collision.depth;

            if (contact.collision.normal.y < 0) result.grounded = true;
            if (contact.collision.normal.y > 0) result.hit_ceiling = true;
            if (contact.collision.normal.x < 0) result.hit_left = true;
            if (contact.collision.normal.x > 0) result.hit_right = true;
        }
        // Hit max iterations: contact may still remain
        if (self.deepestContact(body.*) != null) {
            result.saturated = true;
        }
        return result;
    }

    /// World AABB of tile (tx, ty).
    pub fn tileWorldRect(self: *const TileMap, tx: u32, ty: u32) gmath.Rect {
        return .{
            .x = @as(f32, @floatFromInt(tx)) * @as(f32, @floatFromInt(self.tile_width)),
            .y = @as(f32, @floatFromInt(ty)) * @as(f32, @floatFromInt(self.tile_height)),
            .w = @floatFromInt(self.tile_width),
            .h = @floatFromInt(self.tile_height),
        };
    }

    fn tileRangeForAabb(self: *const TileMap, body: gmath.Rect) ?struct {
        tx0: u32,
        ty0: u32,
        tx1: u32,
        ty1: u32,
    } {
        const tw: f32 = @floatFromInt(self.tile_width);
        const th: f32 = @floatFromInt(self.tile_height);

        var tx0_i: i32 = @intFromFloat(@floor(body.x / tw));
        var ty0_i: i32 = @intFromFloat(@floor(body.y / th));
        // Half-open: bottom-right exclusive. A point exactly on the edge does not include the next tile.
        var tx1_i: i32 = @intFromFloat(@ceil((body.x + body.w) / tw));
        var ty1_i: i32 = @intFromFloat(@ceil((body.y + body.h) / th));

        const map_w: i32 = @intCast(self.width);
        const map_h: i32 = @intCast(self.height);
        if (tx0_i < 0) tx0_i = 0;
        if (ty0_i < 0) ty0_i = 0;
        if (tx1_i > map_w) tx1_i = map_w;
        if (ty1_i > map_h) ty1_i = map_h;
        if (tx0_i >= tx1_i or ty0_i >= ty1_i) return null;

        return .{
            .tx0 = @intCast(tx0_i),
            .ty0 = @intCast(ty0_i),
            .tx1 = @intCast(tx1_i),
            .ty1 = @intCast(ty1_i),
        };
    }

    /// Return one contact with the largest positive penetration. Ties keep the row-major first.
    fn deepestContact(self: *const TileMap, body: gmath.Rect) ?TileContact {
        var best: ?TileContact = null;
        var it = self.queryAabb(body);
        while (it.next()) |c| {
            if (best) |b| {
                if (c.collision.depth > b.collision.depth) best = c;
                // Same depth: query is row-major, so keep first-wins (do not update)
            } else {
                best = c;
            }
        }
        return best;
    }
};

/// One contact from `queryAabb`.
pub const TileContact = struct {
    tile_x: u32,
    tile_y: u32,
    tile_id: u16,
    tile_rect: gmath.Rect,
    collision: gmath.Collision,
};

/// Allocation-free solid-contact iterator (row-major).
pub const QueryIterator = struct {
    map: *const TileMap,
    body: gmath.Rect,
    tx: u32,
    ty: u32,
    tx0: u32,
    ty0: u32,
    tx1: u32,
    ty1: u32,
    done: bool,

    pub fn next(self: *QueryIterator) ?TileContact {
        if (self.done) return null;

        while (self.ty < self.ty1) {
            while (self.tx < self.tx1) {
                const tx = self.tx;
                const ty = self.ty;
                self.tx += 1;

                const id = self.map.tiles[@as(usize, ty) * @as(usize, self.map.width) + tx];
                if (id == EmptyTile) continue;
                if (!self.map.flags[id].solid) continue;

                const tile_rect = self.map.tileWorldRect(tx, ty);
                const col = gmath.aabbVsAabb(self.body, tile_rect);
                // depth=0 edge-only contacts are not push-out targets
                if (!col.hit or col.depth <= 0) continue;

                return .{
                    .tile_x = tx,
                    .tile_y = ty,
                    .tile_id = id,
                    .tile_rect = tile_rect,
                    .collision = col,
                };
            }
            self.tx = self.tx0;
            self.ty += 1;
        }
        self.done = true;
        return null;
    }
};

/// Result of `resolveAabb`.
pub const ResolveResult = struct {
    grounded: bool = false,
    hit_ceiling: bool = false,
    hit_left: bool = false,
    hit_right: bool = false,
    iterations: u8 = 0,
    saturated: bool = false,
};

/// Max push-out iterations (fixed. On saturation, `saturated=true`).
pub const ResolveMaxIterations: u8 = 8;

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

fn makeOpaquePixel(r: u8, g: u8, b: u8) u32 {
    // premul + alpha=255
    const bytes: [4]u8 = .{ b, g, r, 255 };
    return @bitCast(bytes);
}

fn makeAtlasGrid(
    allocator: std.mem.Allocator,
    cols: u32,
    rows: u32,
    cell_w: u32,
    cell_h: u32,
    fill: u32,
) !Atlas {
    const img_w = cols * cell_w;
    const img_h = rows * cell_h;
    const pixels = try allocator.alloc(u32, img_w * img_h);
    @memset(pixels, fill);
    const image: sprite.PremultipliedImage = .{
        .width = img_w,
        .height = img_h,
        .pixels = pixels,
    };
    return Atlas.initGrid(allocator, image, cell_w, cell_h);
}

fn solidFlags(n: usize) []const TileFlags {
    // For tests: all frames solid + opaque
    const static_flags = [_]TileFlags{
        .{ .solid = true, .@"opaque" = true },
        .{ .solid = true, .@"opaque" = true },
        .{ .solid = true, .@"opaque" = true },
        .{ .solid = true, .@"opaque" = true },
        .{ .solid = true, .@"opaque" = true },
        .{ .solid = true, .@"opaque" = true },
        .{ .solid = true, .@"opaque" = true },
        .{ .solid = true, .@"opaque" = true },
    };
    std.debug.assert(n <= static_flags.len);
    return static_flags[0..n];
}

test "TileMap rejects dimension mismatch" {
    const allocator = testing.allocator;
    var atlas = try makeAtlasGrid(allocator, 2, 1, 8, 8, makeOpaquePixel(10, 20, 30));
    defer atlas.deinit(allocator);

    const tiles = [_]u16{ 0, 0, 0 };
    const flags = solidFlags(2);
    const err = TileMap.init(&atlas, &tiles, flags, 2, 2, 8, 8);
    try testing.expectError(error.DimensionMismatch, err);
}

test "TileMap rejects out-of-range tile id" {
    const allocator = testing.allocator;
    var atlas = try makeAtlasGrid(allocator, 1, 1, 4, 4, makeOpaquePixel(1, 2, 3));
    defer atlas.deinit(allocator);

    const tiles = [_]u16{ 0, 1 }; // frame count = 1
    const flags = solidFlags(1);
    const err = TileMap.init(&atlas, &tiles, flags, 2, 1, 4, 4);
    try testing.expectError(error.TileIdOutOfRange, err);
}

test "TileMap EmptyTile and non-solid are excluded from query" {
    const allocator = testing.allocator;
    var atlas = try makeAtlasGrid(allocator, 2, 1, 16, 16, makeOpaquePixel(40, 50, 60));
    defer atlas.deinit(allocator);

    // frame 0: solid, frame 1: non-solid
    const flags = [_]TileFlags{
        .{ .solid = true, .@"opaque" = true },
        .{ .solid = false, .@"opaque" = true },
    };
    // map 2x1: empty | non-solid
    const tiles = [_]u16{ EmptyTile, 1 };
    const map = try TileMap.init(&atlas, &tiles, &flags, 2, 1, 16, 16);

    // body covers whole map
    var it = map.queryAabb(.{ .x = 0, .y = 0, .w = 32, .h = 16 });
    try testing.expect(it.next() == null);
}

test "TileMap queryAabb normals from left/right/top/bottom" {
    const allocator = testing.allocator;
    var atlas = try makeAtlasGrid(allocator, 1, 1, 16, 16, makeOpaquePixel(80, 80, 80));
    defer atlas.deinit(allocator);

    const flags = [_]TileFlags{.{ .solid = true, .@"opaque" = true }};
    // single solid tile at (0,0)
    const tiles = [_]u16{0};
    const map = try TileMap.init(&atlas, &tiles, &flags, 1, 1, 16, 16);
    const tile: gmath.Rect = .{ .x = 0, .y = 0, .w = 16, .h = 16 };

    // from left: body overlaps tile from left
    {
        const body: gmath.Rect = .{ .x = -4, .y = 2, .w = 8, .h = 8 };
        var it = map.queryAabb(body);
        const c = it.next().?;
        try testing.expectEqual(@as(u32, 0), c.tile_x);
        try testing.expect(c.collision.hit);
        try testing.expectApproxEqAbs(@as(f32, 4), c.collision.depth, 1e-4);
        // body center left of tile → normal (-1, 0)
        try testing.expectEqual(gmath.Vec2{ .x = -1, .y = 0 }, c.collision.normal);
        try testing.expect(it.next() == null);
        _ = tile;
    }
    // from right
    {
        const body: gmath.Rect = .{ .x = 12, .y = 2, .w = 8, .h = 8 };
        var it = map.queryAabb(body);
        const c = it.next().?;
        try testing.expectApproxEqAbs(@as(f32, 4), c.collision.depth, 1e-4);
        try testing.expectEqual(gmath.Vec2{ .x = 1, .y = 0 }, c.collision.normal);
    }
    // from top (above tile, y smaller)
    {
        const body: gmath.Rect = .{ .x = 2, .y = -4, .w = 8, .h = 8 };
        var it = map.queryAabb(body);
        const c = it.next().?;
        try testing.expectApproxEqAbs(@as(f32, 4), c.collision.depth, 1e-4);
        try testing.expectEqual(gmath.Vec2{ .x = 0, .y = -1 }, c.collision.normal);
    }
    // from bottom
    {
        const body: gmath.Rect = .{ .x = 2, .y = 12, .w = 8, .h = 8 };
        var it = map.queryAabb(body);
        const c = it.next().?;
        try testing.expectApproxEqAbs(@as(f32, 4), c.collision.depth, 1e-4);
        try testing.expectEqual(gmath.Vec2{ .x = 0, .y = 1 }, c.collision.normal);
    }
}

test "TileMap queryAabb enumerates multi-tile candidates row-major" {
    const allocator = testing.allocator;
    var atlas = try makeAtlasGrid(allocator, 1, 1, 10, 10, makeOpaquePixel(1, 1, 1));
    defer atlas.deinit(allocator);

    const flags = [_]TileFlags{.{ .solid = true, .@"opaque" = true }};
    // 3x2 solid grid (all tile id 0)
    const tiles = [_]u16{ 0, 0, 0, 0, 0, 0 };
    const map = try TileMap.init(&atlas, &tiles, &flags, 3, 2, 10, 10);

    // body spans tiles (0,0)(1,0)(0,1)(1,1)
    const body: gmath.Rect = .{ .x = 5, .y = 5, .w = 10, .h = 10 };
    var it = map.queryAabb(body);
    var count: usize = 0;
    var prev_y: u32 = 0;
    var prev_x: u32 = 0;
    var first = true;
    while (it.next()) |c| {
        count += 1;
        if (!first) {
            // row-major: ty non-decreasing; same ty → tx increasing
            try testing.expect(c.tile_y > prev_y or (c.tile_y == prev_y and c.tile_x > prev_x));
        }
        first = false;
        prev_x = c.tile_x;
        prev_y = c.tile_y;
    }
    try testing.expectEqual(@as(usize, 4), count);
}

test "TileMap queryAabb clamps out-of-map candidates" {
    const allocator = testing.allocator;
    var atlas = try makeAtlasGrid(allocator, 1, 1, 8, 8, makeOpaquePixel(9, 9, 9));
    defer atlas.deinit(allocator);

    const flags = [_]TileFlags{.{ .solid = true, .@"opaque" = true }};
    const tiles = [_]u16{0};
    const map = try TileMap.init(&atlas, &tiles, &flags, 1, 1, 8, 8);

    // body mostly outside map (negative coords)
    var it = map.queryAabb(.{ .x = -20, .y = -20, .w = 24, .h = 24 });
    const c = it.next().?;
    try testing.expectEqual(@as(u32, 0), c.tile_x);
    try testing.expectEqual(@as(u32, 0), c.tile_y);
    try testing.expect(it.next() == null);

    // body entirely outside → no contacts
    var it2 = map.queryAabb(.{ .x = 100, .y = 100, .w = 4, .h = 4 });
    try testing.expect(it2.next() == null);
}

test "TileMap resolveAabb floors grounded" {
    const allocator = testing.allocator;
    var atlas = try makeAtlasGrid(allocator, 1, 1, 16, 16, makeOpaquePixel(70, 70, 70));
    defer atlas.deinit(allocator);

    const flags = [_]TileFlags{.{ .solid = true, .@"opaque" = true }};
    // floor tile at (0,1): world y=16..32
    const tiles = [_]u16{ EmptyTile, 0 };
    const map = try TileMap.init(&atlas, &tiles, &flags, 1, 2, 16, 16);

    // body resting into floor
    var body: gmath.Rect = .{ .x = 2, .y = 12, .w = 8, .h = 8 }; // bottom at 20 → 4px into floor
    const res = map.resolveAabb(&body);
    try testing.expect(res.grounded);
    try testing.expect(!res.hit_ceiling);
    try testing.expect(!res.saturated);
    try testing.expectApproxEqAbs(@as(f32, 8), body.y, 1e-3); // pushed up to sit on y=16
}

test "TileMap resolveAabb ceiling" {
    const allocator = testing.allocator;
    var atlas = try makeAtlasGrid(allocator, 1, 1, 16, 16, makeOpaquePixel(70, 70, 70));
    defer atlas.deinit(allocator);

    const flags = [_]TileFlags{.{ .solid = true, .@"opaque" = true }};
    // ceiling tile at (0,0)
    const tiles = [_]u16{ 0, EmptyTile };
    const map = try TileMap.init(&atlas, &tiles, &flags, 1, 2, 16, 16);

    var body: gmath.Rect = .{ .x = 2, .y = 12, .w = 8, .h = 8 }; // top into ceiling
    const res = map.resolveAabb(&body);
    try testing.expect(res.hit_ceiling);
    try testing.expect(!res.grounded);
    try testing.expectApproxEqAbs(@as(f32, 16), body.y, 1e-3);
}

test "TileMap resolveAabb left and right walls" {
    const allocator = testing.allocator;
    var atlas = try makeAtlasGrid(allocator, 1, 1, 16, 16, makeOpaquePixel(70, 70, 70));
    defer atlas.deinit(allocator);

    const flags = [_]TileFlags{.{ .solid = true, .@"opaque" = true }};
    // wall tiles at (0,0) and (2,0); empty middle
    const tiles = [_]u16{ 0, EmptyTile, 0 };
    const map = try TileMap.init(&atlas, &tiles, &flags, 3, 1, 16, 16);

    // hit left wall from right of tile 0
    {
        var body: gmath.Rect = .{ .x = 12, .y = 2, .w = 8, .h = 8 };
        const res = map.resolveAabb(&body);
        try testing.expect(res.hit_right); // body pushed right (normal +x)
        try testing.expectApproxEqAbs(@as(f32, 16), body.x, 1e-3);
    }
    // hit right wall from left of tile 2
    {
        var body: gmath.Rect = .{ .x = 28, .y = 2, .w = 8, .h = 8 };
        const res = map.resolveAabb(&body);
        try testing.expect(res.hit_left); // body pushed left
        try testing.expectApproxEqAbs(@as(f32, 24), body.x, 1e-3);
    }
}

test "TileMap resolveAabb corner multi-contact is deterministic" {
    const allocator = testing.allocator;
    var atlas = try makeAtlasGrid(allocator, 1, 1, 16, 16, makeOpaquePixel(70, 70, 70));
    defer atlas.deinit(allocator);

    const flags = [_]TileFlags{.{ .solid = true, .@"opaque" = true }};
    // L shape: tiles (0,1) floor and (1,1) floor and (1,0) wall
    // 2x2: empty, wall / floor, floor
    const tiles = [_]u16{ EmptyTile, 0, 0, 0 };
    const map = try TileMap.init(&atlas, &tiles, &flags, 2, 2, 16, 16);

    var body: gmath.Rect = .{ .x = 10, .y = 10, .w = 10, .h = 10 };
    const res1 = map.resolveAabb(&body);
    const pos1 = body;

    body = .{ .x = 10, .y = 10, .w = 10, .h = 10 };
    const res2 = map.resolveAabb(&body);
    try testing.expectEqual(res1.grounded, res2.grounded);
    try testing.expectEqual(res1.hit_left, res2.hit_left);
    try testing.expectEqual(res1.hit_right, res2.hit_right);
    try testing.expectEqual(res1.hit_ceiling, res2.hit_ceiling);
    try testing.expectEqual(res1.iterations, res2.iterations);
    try testing.expectApproxEqAbs(pos1.x, body.x, 0);
    try testing.expectApproxEqAbs(pos1.y, body.y, 0);
    // bit-identical positions
    try testing.expectEqual(@as(u32, @bitCast(pos1.x)), @as(u32, @bitCast(body.x)));
    try testing.expectEqual(@as(u32, @bitCast(pos1.y)), @as(u32, @bitCast(body.y)));
}

test "TileMap resolveAabb already grounded / free space / saturation" {
    const allocator = testing.allocator;
    var atlas = try makeAtlasGrid(allocator, 1, 1, 16, 16, makeOpaquePixel(70, 70, 70));
    defer atlas.deinit(allocator);

    const flags = [_]TileFlags{.{ .solid = true, .@"opaque" = true }};
    const tiles = [_]u16{ EmptyTile, 0 }; // floor at y=16
    const map = try TileMap.init(&atlas, &tiles, &flags, 1, 2, 16, 16);

    // already sitting on floor (depth=0 edge contact only → no push)
    {
        var body: gmath.Rect = .{ .x = 2, .y = 8, .w = 8, .h = 8 }; // bottom = 16
        const res = map.resolveAabb(&body);
        try testing.expectEqual(@as(u8, 0), res.iterations);
        try testing.expect(!res.grounded);
        try testing.expectApproxEqAbs(@as(f32, 8), body.y, 1e-4);
    }
    // free space
    {
        var body: gmath.Rect = .{ .x = 2, .y = 0, .w = 8, .h = 8 };
        const res = map.resolveAabb(&body);
        try testing.expectEqual(@as(u8, 0), res.iterations);
        try testing.expect(!res.saturated);
        try testing.expectApproxEqAbs(@as(f32, 0), body.y, 1e-4);
    }
    // deep embed into a solid 1x1 map → may saturate after max iters
    {
        const tiles2 = [_]u16{0};
        const map2 = try TileMap.init(&atlas, &tiles2, &flags, 1, 1, 16, 16);
        var body: gmath.Rect = .{ .x = 2, .y = 2, .w = 12, .h = 12 };
        const res = map2.resolveAabb(&body);
        // After resolve, body should be outside or on edge; either not saturated or saturated
        // with finite iterations == max. At least iterations > 0.
        try testing.expect(res.iterations > 0);
        try testing.expect(res.iterations <= ResolveMaxIterations);
    }
}

test "TileMap rejects opaque frame with partial alpha" {
    const allocator = testing.allocator;
    var atlas = try makeAtlasGrid(allocator, 1, 1, 4, 4, makeOpaquePixel(1, 2, 3));
    defer atlas.deinit(allocator);
    // poke one translucent pixel
    atlas.image.pixels[0] = 0x80010203;

    const flags = [_]TileFlags{.{ .solid = true, .@"opaque" = true }};
    const tiles = [_]u16{0};
    const err = TileMap.init(&atlas, &tiles, &flags, 1, 1, 4, 4);
    try testing.expectError(error.OpaqueAlphaViolation, err);
}

test "TileMap rejects flags length mismatch and tile size mismatch" {
    const allocator = testing.allocator;
    var atlas = try makeAtlasGrid(allocator, 2, 1, 8, 8, makeOpaquePixel(1, 1, 1));
    defer atlas.deinit(allocator);

    const tiles = [_]u16{ 0, 1 };
    {
        const flags = solidFlags(1); // need 2
        const err = TileMap.init(&atlas, &tiles, flags, 2, 1, 8, 8);
        try testing.expectError(error.FlagsLengthMismatch, err);
    }
    {
        const flags = solidFlags(2);
        const err = TileMap.init(&atlas, &tiles, flags, 2, 1, 4, 8); // wrong tile width
        try testing.expectError(error.TileSizeMismatch, err);
    }
}
