//! 38_minigame: gfx / sound / font integrated minigame capstone.
//!
//! - FixedTimeStep 60Hz + ActionMap (A/D·arrow move, Space/Z jump)
//! - Code-generated Tile Atlas + TileMap.resolveAabb (separate X/Y)
//! - 4-frame walk Atlas from usako.png + AnimationClip/Player
//! - Camera.follow + world clamp
//! - Code-generated PCM16 WAV → SoundPlayer (BGM loop + jump/land SE)
//! - SCORE / FPS HUD via kit.font OutlineFont
//! - harness custom probe `game`
//!
//! Hot path declaration:
//! - Init only: warm Atlas / TileMap / WAV / SoundPlayer / Font / HUD caches
//! - Per frame: ActionMap eval, FPS, background memset, TileMap.draw / coins / player / HUD
//! - Per fixed logical step: move, gravity, AABB, coins, anim, camera
//! - Event only: keys, SE enqueue, probe digest
//! - RT: SoundPlayer.render only (no new work inside the callback)

const std = @import("std");
const kit = @import("kit");
const platform = kit.platform;
const gfx = kit.gfx;
const gmath = kit.gmath;
const sound = kit.sound;
const audio = kit.audio;

const usako_png = @embedFile("image/usako.png");

const WINDOW_W: u32 = 640;
const WINDOW_H: u32 = 360;
const COLOR_BG: u32 = 0xFF1A2030;
const COLOR_COIN: u32 = 0xFFE8C84A;

const TILE: u32 = 16;
const MAP_W: u32 = 80;
const MAP_H: u32 = 23;

const PLAYER_W: f32 = 12;
const PLAYER_H: f32 = 14;
const MOVE_SPEED: f32 = 2.5;
const GRAVITY: f32 = 0.35;
const MAX_FALL: f32 = 6.0;
const JUMP_V: f32 = -8.0;

const COIN_W: f32 = 12;
const COIN_H: f32 = 8;

const CELL: u32 = 64;
const SHEET_COLS: u32 = 4;
const SHEET_W: u32 = CELL * SHEET_COLS;
const SHEET_H: u32 = CELL;

const FLAG_GROUND = gfx.TileFlags{ .solid = true, .@"opaque" = true };
const FLAG_BRICK = gfx.TileFlags{ .solid = true, .@"opaque" = true };
const FLAG_LEDGE = gfx.TileFlags{ .solid = true, .@"opaque" = true };
const tile_flags = [_]gfx.TileFlags{ FLAG_GROUND, FLAG_BRICK, FLAG_LEDGE };

const cell_offsets = [_]struct { dx: i32, dy: i32 }{
    .{ .dx = 0, .dy = 0 },
    .{ .dx = 2, .dy = -3 },
    .{ .dx = 0, .dy = 0 },
    .{ .dx = -2, .dy = -3 },
};

const walk_frames = [_]u32{ 0, 1, 2, 3, 2, 1 };

const viewport: gfx.camera.Rect = .{
    .x = 0,
    .y = 0,
    .w = @floatFromInt(WINDOW_W),
    .h = @floatFromInt(WINDOW_H),
};

const ActionMap = gfx.ActionMap(8, 8);
const Player = sound.SoundPlayer(8);

const InputState = struct {
    move_x: f32 = 0,
    jump_pressed: bool = false,
};

const GameEvents = struct {
    jumped: bool = false,
    landed: bool = false,
    collected: u32 = 0,
};

const Coin = struct {
    rect: gmath.Rect,
    collected: bool = false,
};

const Game = struct {
    body: gmath.Rect,
    velocity_y: f32 = 0,
    grounded: bool = false,
    facing: i32 = 1,
    score: u32 = 0,
    jump_count: u32 = 0,
    landing_count: u32 = 0,
    coins: [3]Coin,
};

const GameProbe = struct {
    game: *const Game,
    camera: *const gfx.Camera,
    animation: *const gfx.AnimationPlayer,
    fps: *const u32,
    se_count: *const u32,
    bgm: *const u8,
};

const App = struct {
    player: *Player,
    jump_sound: sound.Sound,
    land_sound: sound.Sound,
    bgm_sound: sound.Sound,
};

fn renderAudio(
    buf: []f32,
    frames: u32,
    channels: u32,
    sample_rate: u32,
    userdata: ?*anyopaque,
) void {
    const app: *App = @ptrCast(@alignCast(userdata orelse return));
    app.player.render(buf, frames, channels, sample_rate);
}

fn gameDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const p: *const GameProbe = @ptrCast(@alignCast(ctx));
    const g = p.game;
    const state = gameStateName(g);
    const facing: []const u8 = if (g.facing < 0) "left" else "right";
    return std.fmt.bufPrint(buf, "x={d:.3} y={d:.3} vy={d:.3} grounded={d} state={s} facing={s} frame={d} cam_x={d:.3} cam_y={d:.3} score={d} fps={d} jump_count={d} landing_count={d} se_count={d} bgm={d}", .{
        g.body.x,
        g.body.y,
        g.velocity_y,
        @as(u32, @intFromBool(g.grounded)),
        state,
        facing,
        p.animation.currentFrame(),
        p.camera.position.x,
        p.camera.position.y,
        g.score,
        p.fps.*,
        g.jump_count,
        g.landing_count,
        p.se_count.*,
        p.bgm.*,
    }) catch buf[0..0];
}

fn gameStateName(g: *const Game) []const u8 {
    if (g.grounded) return "grounded";
    if (g.velocity_y < 0) return "jumping";
    return "falling";
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WINDOW_W, WINDOW_H, "38: Minigame Capstone");
    defer window.destroy();

    var tile_atlas = try buildTileAtlas(allocator);
    defer tile_atlas.deinit(allocator);
    var player_atlas = try buildPlayerAtlas(allocator);
    defer player_atlas.deinit(allocator);

    const tiles = buildMapTiles();
    const map = try gfx.TileMap.init(&tile_atlas, &tiles, &tile_flags, MAP_W, MAP_H, TILE, TILE);

    const world_bounds: gfx.camera.Rect = .{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(MAP_W * TILE),
        .h = @floatFromInt(MAP_H * TILE),
    };

    var cam = gfx.Camera.init(.{ .x = 0, .y = 0 }, 1);
    cam.clampToWorld(viewport, world_bounds);

    // Coins: bottom = platform/floor top; x within the platform's world range. Place floor→P1→P3 as a climbing path
    // . Floor top y=336 / P1 top=272 (world256..416) / P3 top=144 (world640..784).
    // coin1 (floor) sits in the launch zone right of the step (world208..256) as a score source on the initial right move
    // (supports the e2e score>0 assert). coin2 on P1; coin3 on P3 (summit reward).
    var game = Game{
        .body = .{ .x = 64, .y = 160, .w = PLAYER_W, .h = PLAYER_H },
        .coins = .{
            .{ .rect = .{ .x = 220, .y = 328, .w = COIN_W, .h = COIN_H } },
            .{ .rect = .{ .x = 330, .y = 264, .w = COIN_W, .h = COIN_H } },
            .{ .rect = .{ .x = 700, .y = 136, .w = COIN_W, .h = COIN_H } },
        },
    };

    const clip = gfx.AnimationClip{
        .frames = &walk_frames,
        .fps = 8,
        .loop = true,
    };
    var animation = gfx.AnimationPlayer.init(clip);
    animation.play();

    var keyboard = gfx.KeyboardState.init(allocator);
    defer keyboard.deinit();

    var actions = ActionMap.init();
    const jump = try actions.defineButton("jump");
    const move_x = try actions.defineAxis("move_x");
    try actions.bindKey(jump, .SPACE);
    try actions.bindKey(jump, .Z);
    try actions.bindKeyPair(move_x, .A, .D);
    try actions.bindKeyPair(move_x, .LEFT, .RIGHT);

    var prev_pads: [platform.MAX_GAMEPADS]?platform.GamepadState = .{null} ** platform.MAX_GAMEPADS;
    var cur_pads: [platform.MAX_GAMEPADS]?platform.GamepadState = .{null} ** platform.MAX_GAMEPADS;

    var face = try kit.font.FontFace.init(kit.font.default_font_bytes);
    var outline = kit.font.OutlineFont.init(allocator, &face, 12);
    defer outline.deinit();
    warmFontCache(&outline);

    var fps_counter = gfx.FpsCounter.init(1.0);
    var display_fps: u32 = 60;
    var se_count: u32 = 0;
    var bgm_flag: u8 = 0;

    var app: App = undefined;

    const device = audio.open(allocator, .{
        .sample_rate = 48000,
        .buffer_frames = 512,
        .channels = 2,
        .render_callback = renderAudio,
        .userdata = &app,
    }) catch |err| {
        std.debug.print("audio.open failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer device.close();

    const eff = device.config();
    if (eff.sample_rate != 48000) {
        std.debug.print("device sample_rate={d} != 48000; abort\n", .{eff.sample_rate});
        return;
    }

    const snd_player = try Player.create(allocator, eff.sample_rate);
    defer snd_player.destroy();

    const bgm_wav_bytes = try makeToneWav(allocator, 48000, 110.0, 800, 0.18);
    defer allocator.free(bgm_wav_bytes);
    const jump_wav_bytes = try makeToneWav(allocator, 48000, 660.0, 120, 0.35);
    defer allocator.free(jump_wav_bytes);
    const land_wav_bytes = try makeToneWav(allocator, 48000, 220.0, 100, 0.30);
    defer allocator.free(land_wav_bytes);

    var bgm_decoded = try sound.decodeWav(allocator, bgm_wav_bytes);
    defer bgm_decoded.deinit();
    var jump_decoded = try sound.decodeWav(allocator, jump_wav_bytes);
    defer jump_decoded.deinit();
    var land_decoded = try sound.decodeWav(allocator, land_wav_bytes);
    defer land_decoded.deinit();

    app = .{
        .player = snd_player,
        .jump_sound = .{
            .samples = jump_decoded.samples,
            .sample_rate = jump_decoded.sample_rate,
            .channels = jump_decoded.channels,
        },
        .land_sound = .{
            .samples = land_decoded.samples,
            .sample_rate = land_decoded.sample_rate,
            .channels = land_decoded.channels,
        },
        .bgm_sound = .{
            .samples = bgm_decoded.samples,
            .sample_rate = bgm_decoded.sample_rate,
            .channels = bgm_decoded.channels,
        },
    };

    try device.start();
    defer device.stop();

    try app.player.setBgm(&app.bgm_sound);
    bgm_flag = 1;

    var game_probe = GameProbe{
        .game = &game,
        .camera = &cam,
        .animation = &animation,
        .fps = &display_fps,
        .se_count = &se_count,
        .bgm = &bgm_flag,
    };
    platform.registerProbe(.{
        .name = "game",
        .ctx = &game_probe,
        .ext = "txt",
        .digest = gameDigest,
        .desc = "minigame player, camera, animation, score and audio state",
    });

    var timestep = gfx.FixedTimeStep.init(60.0);
    var last_time = platform.getTime();
    var jump_pending: bool = false;

    main_loop: while (window.pollEvents()) {
        keyboard.beginFrame();
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| {
                if (k.key == .ESCAPE or k.key == .Q) break :main_loop;
                keyboard.keyDown(k.key);
            },
            .key_up => |k| keyboard.keyUp(k.key),
            else => {},
        };

        actions.update(&keyboard, &prev_pads, &cur_pads);

        const axis = actions.axisValue(move_x);
        // justPressed is per outer frame. Hold it until a logical update consumes it so the edge is not lost on
        // frames with zero fixed steps (pass to multiple substeps at most once).
        if (actions.justPressed(jump)) jump_pending = true;

        const now = platform.getTime();
        const frame_time = now - last_time;
        last_time = now;
        if (fps_counter.update(frame_time)) {
            display_fps = fps_counter.getFps();
        }

        const steps_raw = timestep.update(frame_time);
        // If fp error yields steps=0, the justPressed edge never reaches a logical update.
        // While a jump is pending, guarantee 1 step to consume it (normal frames have steps_raw>=1).
        const steps: usize = if (steps_raw == 0 and jump_pending) 1 else steps_raw;
        for (0..steps) |_| {
            const input = InputState{
                .move_x = axis,
                .jump_pressed = jump_pending,
            };
            jump_pending = false;

            const events = updateGame(
                &game,
                input,
                timestep.dt,
                &map,
                &animation,
                &cam,
                viewport,
                world_bounds,
            );

            if (events.jumped) {
                try app.player.playSound(&app.jump_sound, 0.7, 0.0);
                se_count += 1;
            }
            if (events.landed) {
                try app.player.playSound(&app.land_sound, 0.8, 0.0);
                se_count += 1;
            }
        }

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            drawGame(
                &game,
                fb.pixels,
                fb.width,
                fb.height,
                &map,
                cam,
                viewport,
                &player_atlas,
                &animation,
                &outline,
                display_fps,
            );
            window.present();
        }

        // Both audio_null and real devices: RT pull depends on wall clock. Budget one frame for digest audio.
        platform.sleep(16_000_000);
    }
}

fn updateGame(
    game: *Game,
    input: InputState,
    dt: f64,
    map: *const gfx.TileMap,
    animation: *gfx.AnimationPlayer,
    camera: *gfx.Camera,
    vp: gfx.camera.Rect,
    world_bounds: gfx.camera.Rect,
) GameEvents {
    var events = GameEvents{};
    const was_grounded = game.grounded;

    const dx = input.move_x * MOVE_SPEED;
    if (dx != 0) {
        game.facing = if (dx < 0) -1 else 1;
    }

    game.body.x += dx;
    _ = map.resolveAabb(&game.body);

    if (input.jump_pressed and game.grounded) {
        game.velocity_y = JUMP_V;
        game.grounded = false;
        events.jumped = true;
        game.jump_count += 1;
    }

    game.velocity_y += GRAVITY;
    if (game.velocity_y > MAX_FALL) game.velocity_y = MAX_FALL;
    game.body.y += game.velocity_y;
    const yres = map.resolveAabb(&game.body);
    game.grounded = yres.grounded;
    if (yres.grounded or yres.hit_ceiling) {
        game.velocity_y = 0;
    }

    if (!was_grounded and game.grounded) {
        events.landed = true;
        game.landing_count += 1;
    }

    for (&game.coins) |*coin| {
        if (coin.collected) continue;
        if (overlaps(game.body, coin.rect)) {
            coin.collected = true;
            game.score += 100;
            events.collected += 1;
        }
    }

    const moving = dx != 0;
    if (moving and game.grounded) {
        if (!animation.isPlaying()) animation.play();
        animation.update(dt);
    } else {
        animation.stop();
    }

    const target: gfx.camera.Vec2 = .{
        .x = game.body.x + game.body.w * 0.5,
        .y = game.body.y + game.body.h * 0.5,
    };
    camera.follow(target, vp, world_bounds, 0.2);

    return events;
}

fn drawGame(
    game: *const Game,
    framebuffer: []u32,
    fb_width: u32,
    fb_height: u32,
    map: *const gfx.TileMap,
    camera: gfx.Camera,
    vp: gfx.camera.Rect,
    player_atlas: *const gfx.Atlas,
    animation: *const gfx.AnimationPlayer,
    font: *kit.font.OutlineFont,
    fps: u32,
) void {
    @memset(framebuffer, COLOR_BG);
    map.draw(framebuffer, fb_width, fb_height, camera, vp);

    for (game.coins) |coin| {
        if (coin.collected) continue;
        drawCoin(framebuffer, fb_width, fb_height, camera, vp, coin.rect);
    }

    const sprite_wx = game.body.x - 26;
    const sprite_wy = game.body.y + game.body.h - 58;
    const screen = camera.worldToScreen(.{ .x = sprite_wx, .y = sprite_wy }, vp);
    const sx = @as(i32, @intFromFloat(@floor(screen.x)));
    const sy = @as(i32, @intFromFloat(@floor(screen.y)));
    player_atlas.drawFrame(
        framebuffer,
        fb_width,
        fb_height,
        sx,
        sy,
        animation.currentFrame(),
        .{ .flip_x = game.facing < 0 },
    );

    drawHud(framebuffer, fb_width, fb_height, font, game.score, fps);
}

fn drawHud(
    framebuffer: []u32,
    fb_width: u32,
    fb_height: u32,
    font: *kit.font.OutlineFont,
    score: u32,
    fps: u32,
) void {
    var score_buf: [16]u8 = undefined;
    const score_text = std.fmt.bufPrint(&score_buf, "SCORE {d:0>3}", .{score}) catch "SCORE ???";
    var fps_buf: [16]u8 = undefined;
    const fps_text = std.fmt.bufPrint(&fps_buf, "FPS {d}", .{fps}) catch "FPS ?";

    const target = kit.font.RenderTarget{ .pixels = framebuffer, .width = fb_width, .height = fb_height };
    const clip = kit.font.Rect{ .x = 0, .y = 0, .w = fb_width, .h = fb_height };
    const white = kit.font.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);
    const cyan = kit.font.Color.rgba(0xAA, 0xDD, 0xFF, 0xFF);

    font.asFont().drawTo(target, .{ .x = 8, .y = 6 }, score_text, white, clip, 1.0);
    font.asFont().drawTo(target, .{ .x = 8, .y = 22 }, fps_text, cyan, clip, 1.0);
    font.asFont().drawTo(target, .{ .x = 8, .y = 38 }, "A/D MOVE  SPACE JUMP", cyan, clip, 1.0);
}

fn warmFontCache(font: *kit.font.OutlineFont) void {
    var scratch: [64 * 64]u32 = undefined;
    @memset(&scratch, 0);
    const target = kit.font.RenderTarget{ .pixels = &scratch, .width = 64, .height = 64 };
    const clip = kit.font.Rect{ .x = 0, .y = 0, .w = 64, .h = 64 };
    const white = kit.font.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);
    font.asFont().drawTo(target, .{ .x = 0, .y = 0 }, "SCORE 000", white, clip, 1.0);
    font.asFont().drawTo(target, .{ .x = 0, .y = 16 }, "FPS 60", white, clip, 1.0);
    font.asFont().drawTo(target, .{ .x = 0, .y = 32 }, "A/D MOVE  SPACE JUMP", white, clip, 1.0);
}

fn drawCoin(
    framebuffer: []u32,
    fb_width: u32,
    fb_height: u32,
    camera: gfx.Camera,
    vp: gfx.camera.Rect,
    rect: gmath.Rect,
) void {
    const z: f32 = @floatFromInt(camera.zoom);
    const s0 = camera.worldToScreen(.{ .x = rect.x, .y = rect.y }, vp);
    const s1x = s0.x + rect.w * z;
    const s1y = s0.y + rect.h * z;

    var x0 = @as(i32, @intFromFloat(@floor(s0.x)));
    var y0 = @as(i32, @intFromFloat(@floor(s0.y)));
    var x1 = @as(i32, @intFromFloat(@ceil(s1x)));
    var y1 = @as(i32, @intFromFloat(@ceil(s1y)));

    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > @as(i32, @intCast(fb_width))) x1 = @intCast(fb_width);
    if (y1 > @as(i32, @intCast(fb_height))) y1 = @intCast(fb_height);
    if (x0 >= x1 or y0 >= y1) return;

    const ux0: u32 = @intCast(x0);
    const uy0: u32 = @intCast(y0);
    const ux1: u32 = @intCast(x1);
    const uy1: u32 = @intCast(y1);
    var y: u32 = uy0;
    while (y < uy1) : (y += 1) {
        const row = y * fb_width;
        @memset(framebuffer[row + ux0 .. row + ux1], COLOR_COIN);
    }
}

fn overlaps(a: gmath.Rect, b: gmath.Rect) bool {
    return a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y;
}

fn buildTileAtlas(allocator: std.mem.Allocator) !gfx.Atlas {
    const cols: u32 = 3;
    const img_w = cols * TILE;
    const img_h = TILE;
    const pixels = try allocator.alloc(u32, img_w * img_h);
    errdefer allocator.free(pixels);

    const colors = [_]u32{
        0xFF3A6B3A,
        0xFF8B5A3C,
        0xFF5A7A9A,
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

fn buildPlayerAtlas(allocator: std.mem.Allocator) !gfx.Atlas {
    var src = try gfx.Sprite.initFromData(allocator, usako_png, 0, 0);
    defer src.deinit(allocator);

    const src_w = src.image.width;
    const src_h = src.image.height;

    const pixels = try allocator.alloc(u32, SHEET_W * SHEET_H);
    errdefer allocator.free(pixels);
    @memset(pixels, 0);

    const marker: u32 = 0xFFFFFF00;

    for (cell_offsets, 0..) |off, cell_i| {
        const base_x: i32 = @intCast(cell_i * CELL);
        var sy: u32 = 0;
        while (sy < src_h) : (sy += 1) {
            var sx: u32 = 0;
            while (sx < src_w) : (sx += 1) {
                const dx = base_x + @as(i32, @intCast(sx)) + off.dx;
                const dy = @as(i32, @intCast(sy)) + off.dy;
                if (dx < base_x or dx >= base_x + @as(i32, @intCast(CELL))) continue;
                if (dy < 0 or dy >= @as(i32, @intCast(CELL))) continue;
                const dst_x: u32 = @intCast(dx);
                const dst_y: u32 = @intCast(dy);
                pixels[dst_y * SHEET_W + dst_x] = src.image.pixels[sy * src_w + sx];
            }
        }
        var my: u32 = 26;
        while (my < 38) : (my += 1) {
            var mx: u32 = CELL - 6;
            while (mx < CELL - 2) : (mx += 1) {
                pixels[my * SHEET_W + @as(u32, @intCast(base_x)) + mx] = marker;
            }
        }
    }

    const sheet: gfx.PremultipliedImage = .{
        .width = SHEET_W,
        .height = SHEET_H,
        .pixels = pixels,
    };
    return gfx.Atlas.initGrid(allocator, sheet, CELL, CELL);
}

fn buildMapTiles() [MAP_W * MAP_H]u16 {
    var tiles: [MAP_W * MAP_H]u16 = undefined;
    @memset(&tiles, gfx.EmptyTile);

    var x: u32 = 0;
    while (x < MAP_W) : (x += 1) {
        setTile(&tiles, x, 22, 0);
        setTile(&tiles, x, 21, 0);
    }

    var y: u32 = 0;
    while (y < 21) : (y += 1) {
        setTile(&tiles, 0, y, 1);
        setTile(&tiles, 79, y, 1);
    }

    // Step x=9..12, y=19,18
    x = 9;
    while (x <= 12) : (x += 1) {
        setTile(&tiles, x, 19, 1);
        setTile(&tiles, x, 18, 1);
    }

    // Floating platforms: stair-like climb left→right. Avoid direct vertical overlap; leave ≈2–3 tile horizontal gaps so
    // arc jumps can land one step at a time. resolveAabb stops with hit_ceiling if an ascending body hits a ceiling tile,
    // so platforms are offset sideways rather than stacked directly above. Each is 4 tiles = 64px tall.
    // Leave launch space right of the step overhang (x9..12); P1 starts at x16.
    // P1 row17(top272) x16..25 world256..416 / P2 row13(top208) x28..37 world448..592
    // / P3 row9 (top144) x40..49 world640..784.
    x = 16;
    while (x <= 25) : (x += 1) setTile(&tiles, x, 17, 2);
    x = 28;
    while (x <= 37) : (x += 1) setTile(&tiles, x, 13, 2);
    x = 40;
    while (x <= 49) : (x += 1) setTile(&tiles, x, 9, 2);

    return tiles;
}

fn setTile(tiles: *[MAP_W * MAP_H]u16, tx: u32, ty: u32, id: u16) void {
    tiles[ty * MAP_W + tx] = id;
}

/// Code-generate a PCM16 mono RIFF/WAVE (init only; never called from RT).
fn makeToneWav(
    allocator: std.mem.Allocator,
    sample_rate: u32,
    frequency: f32,
    duration_ms: u32,
    amplitude: f32,
) ![]u8 {
    const n_samples: u32 = sample_rate * duration_ms / 1000;
    const data_bytes: u32 = n_samples * 2;
    const total: usize = 44 + data_bytes;
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);

    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], @intCast(36 + data_bytes), .little);
    @memcpy(out[8..12], "WAVE");
    @memcpy(out[12..16], "fmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little); // PCM fmt chunk size
    std.mem.writeInt(u16, out[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, out[22..24], 1, .little); // mono
    std.mem.writeInt(u32, out[24..28], sample_rate, .little);
    std.mem.writeInt(u32, out[28..32], sample_rate * 2, .little); // byte rate
    std.mem.writeInt(u16, out[32..34], 2, .little); // block align
    std.mem.writeInt(u16, out[34..36], 16, .little); // bits
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], data_bytes, .little);

    const two_pi = std.math.tau;
    var i: u32 = 0;
    while (i < n_samples) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
        // Short SE uses linear decay; BGM (longer) uses constant amplitude
        const env: f32 = if (duration_ms <= 200)
            1.0 - @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n_samples))
        else
            1.0;
        const s = @sin(two_pi * frequency * t) * amplitude * env;
        const clamped = std.math.clamp(s, -1.0, 1.0);
        const sample: i16 = @intFromFloat(clamped * 32767.0);
        const off: usize = 44 + @as(usize, i) * 2;
        std.mem.writeInt(i16, out[off..][0..2], sample, .little);
    }

    return out;
}
