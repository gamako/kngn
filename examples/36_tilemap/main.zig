//! 36_tilemap: タイルマップ描画 + solid AABB 衝突デモ（TASK-111.5）。
//!
//! - 固定 60Hz FixedTimeStep・左右移動・重力・着地
//! - `gfx.TileMap` で地形描画（Camera + visibleRect カリング）
//! - X/Y 分離 resolve で壁・床の安定接触
//!
//! 決定論の前提（CRC 固定値はこれに依存）:
//! - 640×360・固定背景色・固定マップ / タイルセット / 初期 AABB
//! - harness 仮想クロック（getTime = frame/60）と fixed 60Hz の組合せ
//! - 整数定数のみの物理パラメータ（乱数・壁時計なし）
//!
//! ホットパス宣言:
//! - TileMap.draw → Atlas.drawFrame → drawSpriteEx（全画素は既存経路）
//! - resolveAabb は論理更新毎・候補タイルのみ
//! - フレームバッファは @memset で初期化

const std = @import("std");
const kit = @import("kit");
const platform = kit.platform;
const gfx = kit.gfx;
const gmath = kit.gmath;

const WINDOW_W: u32 = 640;
const WINDOW_H: u32 = 360;
const COLOR_BG: u32 = 0xFF1A2030;
const COLOR_PLAYER: u32 = 0xFFE8C84A;

const TILE: u32 = 16;
const MAP_W: u32 = 40; // 640 world px
const MAP_H: u32 = 23; // 368 world px（画面より少し高い）

const PLAYER_W: f32 = 12;
const PLAYER_H: f32 = 14;
const MOVE_SPEED: f32 = 2.5; // world px / fixed update
const GRAVITY: f32 = 0.35;
const MAX_FALL: f32 = 6.0;
const JUMP_V: f32 = -5.5;

/// タイル種別: 0=地面, 1=レンガ, 2=足場（半ブロック色）
const FLAG_GROUND = gfx.TileFlags{ .solid = true, .@"opaque" = true };
const FLAG_BRICK = gfx.TileFlags{ .solid = true, .@"opaque" = true };
const FLAG_LEDGE = gfx.TileFlags{ .solid = true, .@"opaque" = true };
const tile_flags = [_]gfx.TileFlags{ FLAG_GROUND, FLAG_BRICK, FLAG_LEDGE };

const viewport: gfx.camera.Rect = .{
    .x = 0,
    .y = 0,
    .w = @floatFromInt(WINDOW_W),
    .h = @floatFromInt(WINDOW_H),
};

const Held = struct {
    left: bool = false,
    right: bool = false,
    jump: bool = false,
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WINDOW_W, WINDOW_H, "36: TileMap + Collision");
    defer window.destroy();

    var atlas = try buildTileAtlas(allocator);
    defer atlas.deinit(allocator);

    const tiles = buildMapTiles();
    const map = try gfx.TileMap.init(&atlas, &tiles, &tile_flags, MAP_W, MAP_H, TILE, TILE);

    const world_bounds: gfx.camera.Rect = .{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(MAP_W * TILE),
        .h = @floatFromInt(MAP_H * TILE),
    };

    var cam = gfx.Camera.init(.{ .x = 0, .y = 0 }, 1);
    cam.clampToWorld(viewport, world_bounds);

    // 初期: 左寄り・空中から落下（着地を E2E で見せる）
    var body: gmath.Rect = .{ .x = 48, .y = 40, .w = PLAYER_W, .h = PLAYER_H };
    var vel_y: f32 = 0;
    var grounded: bool = false;
    var held: Held = .{};

    var timestep = gfx.FixedTimeStep.init(60.0);
    var last_time = platform.getTime();

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| switch (k.key) {
                .ESCAPE, .Q => break :main_loop,
                .LEFT, .A => held.left = true,
                .RIGHT, .D => held.right = true,
                .UP, .W, .SPACE, .Z => held.jump = true,
                else => {},
            },
            .key_up => |k| switch (k.key) {
                .LEFT, .A => held.left = false,
                .RIGHT, .D => held.right = false,
                .UP, .W, .SPACE, .Z => held.jump = false,
                else => {},
            },
            else => {},
        };

        const now = platform.getTime();
        const frame_time = now - last_time;
        last_time = now;

        const steps = timestep.update(frame_time);
        for (0..steps) |_| {
            // 水平移動 + X resolve
            var dx: f32 = 0;
            if (held.left) dx -= MOVE_SPEED;
            if (held.right) dx += MOVE_SPEED;
            body.x += dx;
            _ = map.resolveAabb(&body);

            // ジャンプ / 重力 + Y resolve
            if (held.jump and grounded) {
                vel_y = JUMP_V;
                grounded = false;
            }
            vel_y += GRAVITY;
            if (vel_y > MAX_FALL) vel_y = MAX_FALL;
            body.y += vel_y;
            const yres = map.resolveAabb(&body);
            grounded = yres.grounded;
            if (yres.grounded or yres.hit_ceiling) {
                vel_y = 0;
            }

            // カメラはプレイヤー中央を緩やかに追従（固定 alpha）
            const target: gfx.camera.Vec2 = .{
                .x = body.x + body.w * 0.5,
                .y = body.y + body.h * 0.5,
            };
            cam.follow(target, viewport, world_bounds, 0.2);
        }

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, COLOR_BG);
            map.draw(fb.pixels, fb.width, fb.height, cam, viewport);
            drawPlayer(fb.pixels, fb.width, fb.height, cam, body);
            window.present();
        }

        platform.frameDelay(16_666_666);
    }
}

fn drawPlayer(
    pixels: []u32,
    fb_w: u32,
    fb_h: u32,
    cam: gfx.Camera,
    body: gmath.Rect,
) void {
    const s0 = cam.worldToScreen(.{ .x = body.x, .y = body.y }, viewport);
    const z: f32 = @floatFromInt(cam.zoom);
    const s1x = s0.x + body.w * z;
    const s1y = s0.y + body.h * z;

    var x0 = @as(i32, @intFromFloat(@floor(s0.x)));
    var y0 = @as(i32, @intFromFloat(@floor(s0.y)));
    var x1 = @as(i32, @intFromFloat(@ceil(s1x)));
    var y1 = @as(i32, @intFromFloat(@ceil(s1y)));

    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > @as(i32, @intCast(fb_w))) x1 = @intCast(fb_w);
    if (y1 > @as(i32, @intCast(fb_h))) y1 = @intCast(fb_h);
    if (x0 >= x1 or y0 >= y1) return;

    const ux0: u32 = @intCast(x0);
    const uy0: u32 = @intCast(y0);
    const ux1: u32 = @intCast(x1);
    const uy1: u32 = @intCast(y1);
    var y: u32 = uy0;
    while (y < uy1) : (y += 1) {
        const row = y * fb_w;
        @memset(pixels[row + ux0 .. row + ux1], COLOR_PLAYER);
    }
}

/// 決定的な 3 セル Atlas（地面 / レンガ / 足場）。乱数なし。
fn buildTileAtlas(allocator: std.mem.Allocator) !gfx.Atlas {
    const cols: u32 = 3;
    const img_w = cols * TILE;
    const img_h = TILE;
    const pixels = try allocator.alloc(u32, img_w * img_h);
    errdefer allocator.free(pixels);

    const colors = [_]u32{
        0xFF3A6B3A, // ground green
        0xFF8B5A3C, // brick brown
        0xFF5A7A9A, // ledge blue-gray
    };
    const edge = [_]u32{
        0xFF2A4A2A,
        0xFF6B3A2C,
        0xFF3A5A7A,
    };

    var c: u32 = 0;
    while (c < cols) : (c += 1) {
        var py: u32 = 0;
        while (py < TILE) : (py += 1) {
            var px: u32 = 0;
            while (px < TILE) : (px += 1) {
                const border = px == 0 or py == 0 or px == TILE - 1 or py == TILE - 1;
                const color = if (border) edge[c] else colors[c];
                pixels[py * img_w + c * TILE + px] = color;
            }
        }
    }

    const image: gfx.PremultipliedImage = .{
        .width = img_w,
        .height = img_h,
        .pixels = pixels,
    };
    return gfx.Atlas.initGrid(allocator, image, TILE, TILE);
}

/// 固定地形: 床・段差・浮遊足場・壁。Zig 配列（@embedFile なし）。
fn buildMapTiles() [MAP_W * MAP_H]u16 {
    var tiles: [MAP_W * MAP_H]u16 = undefined;
    @memset(&tiles, gfx.EmptyTile);

    // 地面 2 段（y = MAP_H-2, MAP_H-1）
    var x: u32 = 0;
    while (x < MAP_W) : (x += 1) {
        setTile(&tiles, x, MAP_H - 1, 0);
        setTile(&tiles, x, MAP_H - 2, 0);
    }

    // 左壁
    var y: u32 = 0;
    while (y < MAP_H - 2) : (y += 1) {
        setTile(&tiles, 0, y, 1);
    }

    // 段差（左寄り）
    x = 8;
    while (x < 14) : (x += 1) {
        setTile(&tiles, x, MAP_H - 3, 1);
        setTile(&tiles, x, MAP_H - 4, 1);
    }

    // 浮遊足場
    x = 18;
    while (x < 26) : (x += 1) {
        setTile(&tiles, x, MAP_H - 8, 2);
    }
    x = 28;
    while (x < 34) : (x += 1) {
        setTile(&tiles, x, MAP_H - 12, 2);
    }

    // 天井の一部（右上）
    x = 30;
    while (x < 38) : (x += 1) {
        setTile(&tiles, x, 2, 1);
    }

    return tiles;
}

fn setTile(tiles: *[MAP_W * MAP_H]u16, tx: u32, ty: u32, id: u16) void {
    tiles[ty * MAP_W + tx] = id;
}
