//! Spritesheet / atlas.
//!
//! Owns one PremultipliedImage and a frame-rect table (by index / by name).
//! Drawing delegates to `drawSpriteEx` (no full-pixel loop in this file).
//!
//! Hot-path declaration:
//! - `drawFrame`: every-frame draw path (delegates to drawSpriteEx; no allocation)
//! - `indexOf`: init / event-time only (linear search)

const std = @import("std");
const sprite = @import("sprite");

pub const PremultipliedImage = sprite.PremultipliedImage;
pub const SourceRect = sprite.SourceRect;
pub const Sprite = sprite.Sprite;
pub const SpriteDrawOptions = sprite.SpriteDrawOptions;
pub const drawSpriteEx = sprite.drawSpriteEx;

/// Spec for one frame at init (name is optional).
pub const FrameSpec = struct {
    rect: SourceRect,
    name: ?[]const u8 = null,
};

pub const AtlasError = error{
    /// Cell width or height is 0
    ZeroCellSize,
    /// Image size is not divisible by the cell size
    ImageNotDivisible,
    /// Rect width/height is 0
    EmptyRect,
    /// Rect is outside the image, or coordinate addition overflows
    RectOutOfBounds,
    /// Cell-count multiplication overflows
    GridOverflow,
};

/// Spritesheet. Owns the image and the frame-rect table.
pub const Atlas = struct {
    image: PremultipliedImage,
    frames: []SourceRect,
    /// Same length as `frames`. Unnamed frames are null. Each non-null name is allocator-owned.
    names: []?[]u8,

    /// Build an Atlas that owns the image and frame table.
    /// Spec names are copied; they do not depend on the caller's temporary buffer.
    pub fn init(allocator: std.mem.Allocator, image: PremultipliedImage, specs: []const FrameSpec) (AtlasError || std.mem.Allocator.Error)!Atlas {
        errdefer {
            var img = image;
            img.deinit(allocator);
        }

        const frames = try allocator.alloc(SourceRect, specs.len);
        errdefer allocator.free(frames);
        const names = try allocator.alloc(?[]u8, specs.len);
        errdefer {
            for (names) |n| if (n) |s| allocator.free(s);
            allocator.free(names);
        }
        @memset(names, null);

        for (specs, 0..) |spec, i| {
            try validateRect(image.width, image.height, spec.rect);
            frames[i] = spec.rect;
            if (spec.name) |n| {
                names[i] = try allocator.dupe(u8, n);
            }
        }

        return .{
            .image = image,
            .frames = frames,
            .names = names,
        };
    }

    /// Build an Atlas by splitting the image into equal cells (row-major).
    /// Errors if image width/height is not divisible by the cell, or cell size is 0.
    pub fn initGrid(
        allocator: std.mem.Allocator,
        image: PremultipliedImage,
        cell_width: u32,
        cell_height: u32,
    ) (AtlasError || std.mem.Allocator.Error)!Atlas {
        errdefer {
            var img = image;
            img.deinit(allocator);
        }

        if (cell_width == 0 or cell_height == 0) return error.ZeroCellSize;
        if (image.width % cell_width != 0 or image.height % cell_height != 0) {
            return error.ImageNotDivisible;
        }

        const cols = image.width / cell_width;
        const rows = image.height / cell_height;
        const count = std.math.mul(u32, cols, rows) catch return error.GridOverflow;

        const frames = try allocator.alloc(SourceRect, count);
        errdefer allocator.free(frames);
        const names = try allocator.alloc(?[]u8, count);
        errdefer allocator.free(names);
        @memset(names, null);

        var i: u32 = 0;
        var row: u32 = 0;
        while (row < rows) : (row += 1) {
            var col: u32 = 0;
            while (col < cols) : (col += 1) {
                frames[i] = .{
                    .x = col * cell_width,
                    .y = row * cell_height,
                    .w = cell_width,
                    .h = cell_height,
                };
                i += 1;
            }
        }

        return .{
            .image = image,
            .frames = frames,
            .names = names,
        };
    }

    pub fn deinit(self: *Atlas, allocator: std.mem.Allocator) void {
        self.image.deinit(allocator);
        for (self.names) |n| if (n) |s| allocator.free(s);
        allocator.free(self.names);
        allocator.free(self.frames);
        self.* = undefined;
    }

    pub fn frameCount(self: *const Atlas) usize {
        return self.frames.len;
    }

    /// Frame rect. Out of range → null.
    pub fn frame(self: *const Atlas, index: usize) ?SourceRect {
        if (index >= self.frames.len) return null;
        return self.frames[index];
    }

    /// Frame rect. Out of range → null (alias of `frame`).
    pub fn frameRect(self: *const Atlas, index: usize) ?SourceRect {
        return self.frame(index);
    }

    /// Look up a frame index by name. Duplicate names match the first. Not found → null.
    pub fn indexOf(self: *const Atlas, name: []const u8) ?u32 {
        for (self.names, 0..) |n, i| {
            if (n) |s| {
                if (std.mem.eql(u8, s, name)) return @intCast(i);
            }
        }
        return null;
    }

    /// Draw the given frame via `drawSpriteEx`.
    /// Out-of-range index is a no-op. No allocation.
    /// `opts.src` is overwritten with the frame rect.
    pub fn drawFrame(
        self: *const Atlas,
        framebuffer: []u32,
        fb_width: u32,
        fb_height: u32,
        x: i32,
        y: i32,
        index: usize,
        opts: SpriteDrawOptions,
    ) void {
        const rect = self.frame(index) orelse return;
        // The Atlas owns the image. Do not call Sprite.deinit.
        const spr = Sprite{
            .image = self.image,
            .x = x,
            .y = y,
        };
        var draw_opts = opts;
        draw_opts.src = rect;
        drawSpriteEx(framebuffer, fb_width, fb_height, &spr, draw_opts);
    }
};

fn validateRect(img_w: u32, img_h: u32, rect: SourceRect) AtlasError!void {
    if (rect.w == 0 or rect.h == 0) return error.EmptyRect;
    const x1 = std.math.add(u32, rect.x, rect.w) catch return error.RectOutOfBounds;
    const y1 = std.math.add(u32, rect.y, rect.h) catch return error.RectOutOfBounds;
    if (x1 > img_w or y1 > img_h) return error.RectOutOfBounds;
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

fn makeImage(allocator: std.mem.Allocator, w: u32, h: u32, fill: u32) !PremultipliedImage {
    const pixels = try allocator.alloc(u32, w * h);
    @memset(pixels, fill);
    return .{ .width = w, .height = h, .pixels = pixels };
}

test "Atlas initGrid is row-major" {
    const allocator = testing.allocator;
    const img = try makeImage(allocator, 6, 4, 0xFF112233);
    var atlas = try Atlas.initGrid(allocator, img, 3, 2);
    defer atlas.deinit(allocator);

    try testing.expectEqual(@as(usize, 4), atlas.frameCount());
    try testing.expectEqual(SourceRect{ .x = 0, .y = 0, .w = 3, .h = 2 }, atlas.frame(0).?);
    try testing.expectEqual(SourceRect{ .x = 3, .y = 0, .w = 3, .h = 2 }, atlas.frame(1).?);
    try testing.expectEqual(SourceRect{ .x = 0, .y = 2, .w = 3, .h = 2 }, atlas.frame(2).?);
    try testing.expectEqual(SourceRect{ .x = 3, .y = 2, .w = 3, .h = 2 }, atlas.frame(3).?);
}

test "Atlas name lookup / missing / duplicate first-wins" {
    const allocator = testing.allocator;
    const img = try makeImage(allocator, 4, 2, 0xFF000000);
    const specs = [_]FrameSpec{
        .{ .rect = .{ .x = 0, .y = 0, .w = 2, .h = 2 }, .name = "idle" },
        .{ .rect = .{ .x = 2, .y = 0, .w = 2, .h = 2 }, .name = "walk" },
        .{ .rect = .{ .x = 0, .y = 0, .w = 2, .h = 2 }, .name = "walk" }, // duplicate
        .{ .rect = .{ .x = 2, .y = 0, .w = 2, .h = 2 }, .name = null },
    };
    var atlas = try Atlas.init(allocator, img, &specs);
    defer atlas.deinit(allocator);

    try testing.expectEqual(@as(?u32, 0), atlas.indexOf("idle"));
    try testing.expectEqual(@as(?u32, 1), atlas.indexOf("walk")); // first match
    try testing.expectEqual(@as(?u32, null), atlas.indexOf("jump"));
    try testing.expectEqual(@as(?u32, null), atlas.indexOf(""));
}

test "Atlas rejects zero cell / non-divisible / out-of-bounds rect" {
    const allocator = testing.allocator;

    {
        const img = try makeImage(allocator, 4, 4, 0);
        const err = Atlas.initGrid(allocator, img, 0, 2);
        try testing.expectError(error.ZeroCellSize, err);
    }
    {
        const img = try makeImage(allocator, 4, 4, 0);
        const err = Atlas.initGrid(allocator, img, 3, 2);
        try testing.expectError(error.ImageNotDivisible, err);
    }
    {
        const img = try makeImage(allocator, 4, 4, 0);
        const specs = [_]FrameSpec{
            .{ .rect = .{ .x = 0, .y = 0, .w = 0, .h = 2 } },
        };
        const err = Atlas.init(allocator, img, &specs);
        try testing.expectError(error.EmptyRect, err);
    }
    {
        const img = try makeImage(allocator, 4, 4, 0);
        const specs = [_]FrameSpec{
            .{ .rect = .{ .x = 3, .y = 0, .w = 2, .h = 2 } },
        };
        const err = Atlas.init(allocator, img, &specs);
        try testing.expectError(error.RectOutOfBounds, err);
    }
}

test "Atlas frame bounds and empty atlas" {
    const allocator = testing.allocator;
    const img = try makeImage(allocator, 2, 2, 0xFFAABBCC);
    var atlas = try Atlas.init(allocator, img, &[_]FrameSpec{});
    defer atlas.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), atlas.frameCount());
    try testing.expect(atlas.frame(0) == null);
    try testing.expect(atlas.frameRect(0) == null);
    try testing.expect(atlas.indexOf("x") == null);

    // drawFrame is a no-op (does not panic)
    var fb: [4]u32 = .{ 1, 2, 3, 4 };
    atlas.drawFrame(&fb, 2, 2, 0, 0, 0, .{});
    try testing.expectEqual(@as(u32, 1), fb[0]);
}
