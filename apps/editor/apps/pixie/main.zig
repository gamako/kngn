//! Pixie MVP (TASK-21.8): libs/gui UI + Pen/Eraser/DB16 パレット/Undo/PNG 保存
//!
//! - レイアウト: menu bar / row(canvas, right pane) / timeline placeholder / status bar
//!   の 4 段 Flex（毎フレーム fb サイズから再フロー。リサイズ対応自体は TASK-23）
//! - canvas 入力: press 起点（mouse_pressed_pos）capture。stroke 中は GUI 上に
//!   逸れても継続（座標は clamp なし変換 + ピクセル側 clip）
//! - Undo / Redo: stroke 単位（paint.zig の PaintEngine）
//! - キー: B=Pen / E=Eraser / C=全消去 / Cmd+S=保存 / Cmd+Z=Undo / Cmd+Shift+Z=Redo
//!         ESC・Cmd+Q=終了（ウィンドウクローズ含め running=false の単一経路）

const std = @import("std");
const platform = @import("platform");
const gui = @import("gui");
const core = @import("core");
const paint = @import("paint.zig");

const WINDOW_W: u32 = 780;
const WINDOW_H: u32 = 600;
const CANVAS_W: u32 = 256;
const CANVAS_H: u32 = 256;
const ZOOM: i32 = 2;
const SAVE_PATH = "output.png";
const SAVE_MSG_DURATION: f64 = 3.0;

/// canvas 領域の明示 ID（getNodeRect での外部参照用。自動 ID は不可）
const CANVAS_AREA_ID: gui.Id = 0xC0FFEE01;

const COLOR_WINDOW_BG: u32 = 0xFF_20_20_24;
const COLOR_ERASER: u32 = 0x00000000;

/// DawnBringer 16 パレット（0xRRGGBB）
const db16 = [16]u32{
    0x000000, 0x442434, 0x30346D, 0x4E4A4E,
    0x854C30, 0x346524, 0xD04648, 0x757161,
    0x597DCE, 0xD27D2C, 0x8595A1, 0x6DAA2C,
    0xD2AA99, 0x6DC2CA, 0xDAD45E, 0xDEEED6,
};

/// 0xRRGGBB → gui.Color（不透明）
fn db16Color(i: usize) gui.Color {
    const c = db16[i];
    return gui.Color.rgba(@truncate(c >> 16), @truncate(c >> 8), @truncate(c), 0xFF);
}

/// 0xRRGGBB → canvas pixel（0xAABBGGRR、不透明）。gui.Color と同一ビットレイアウト
fn db16Canvas(i: usize) u32 {
    return @bitCast(db16Color(i));
}

const Tool = enum {
    pen,
    eraser,

    fn name(self: Tool) []const u8 {
        return switch (self) {
            .pen => "Pen",
            .eraser => "Eraser",
        };
    }
};

/// platform.MouseButton → InputEvent の button index（0=left/1=right/2=middle）。
fn buttonToU8(b: platform.MouseButton) u8 {
    return switch (b) {
        .left => 0,
        .right => 1,
        .middle => 2,
        else => 0xFF,
    };
}

/// platform.Event → gui.InputEvent。GUI に関係しない quit は null。
/// key の負値（platform KeyCode.UNKNOWN = -1）は捨てる（libs/gui は u32 code 前提）。
fn toGuiEvent(ev: platform.Event) ?gui.InputEvent {
    return switch (ev) {
        .quit => null,
        .mouse_move => |m| .{ .mouse_move = .{ .x = m.x, .y = m.y, .modifiers = m.modifiers.toC() } },
        .mouse_down => |m| .{ .mouse_down = .{ .x = m.x, .y = m.y, .button = buttonToU8(m.button), .modifiers = m.modifiers.toC() } },
        .mouse_up => |m| .{ .mouse_up = .{ .x = m.x, .y = m.y, .button = buttonToU8(m.button), .modifiers = m.modifiers.toC() } },
        .mouse_scroll => |s| .{ .mouse_scroll = .{ .x = s.x, .y = s.y, .dx = s.dx, .dy = s.dy, .modifiers = s.modifiers.toC() } },
        .key_down => |k| blk: {
            const code = @intFromEnum(k.key);
            if (code < 0) break :blk null;
            break :blk .{ .key_down = .{ .code = @intCast(code), .modifiers = k.modifiers.toC(), .repeat = k.is_repeat } };
        },
        .key_up => |k| blk: {
            const code = @intFromEnum(k.key);
            if (code < 0) break :blk null;
            break :blk .{ .key_up = .{ .code = @intCast(code), .modifiers = k.modifiers.toC() } };
        },
    };
}

/// アプリ状態（イベント処理と UI 構築の両方から触る）
const App = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: paint.PaintEngine,
    tool: Tool = .pen,
    color_idx: usize = 0, // DB16[0] = 黒
    capturing: bool = false,
    running: bool = true,
    save_msg_buf: [128]u8 = undefined,
    save_msg_len: usize = 0,
    save_msg_until: f64 = 0,

    fn drawColor(self: *const App) u32 {
        return switch (self.tool) {
            .pen => db16Canvas(self.color_idx),
            .eraser => COLOR_ERASER,
        };
    }

    fn setSaveMsg(self: *App, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.save_msg_buf, fmt, args) catch &self.save_msg_buf;
        self.save_msg_len = msg.len;
        self.save_msg_until = platform.getTime() + SAVE_MSG_DURATION;
    }

    fn saveMsg(self: *const App) ?[]const u8 {
        if (self.save_msg_len == 0 or platform.getTime() >= self.save_msg_until) return null;
        return self.save_msg_buf[0..self.save_msg_len];
    }

    fn doSave(self: *App) void {
        // 表示は composite だが、保存は raw layer pixels（21.6 の不変条件:
        // composite を保存すると消しゴムの透明が白に潰れて round-trip が壊れる）
        const layer = self.engine.canvas.layers.items[0];
        core.savePNG(self.io, SAVE_PATH, layer.pixels, CANVAS_W, CANVAS_H, self.gpa) catch |err| {
            self.setSaveMsg("Save failed: {s}", .{@errorName(err)});
            return;
        };
        self.setSaveMsg("Saved: " ++ SAVE_PATH, .{});
    }

    /// 編集系コマンドは stroke 中は無視する（仕様の簡略化指示）
    fn doUndo(self: *App) void {
        if (self.capturing) return;
        self.engine.undo();
    }

    fn doRedo(self: *App) void {
        if (self.capturing) return;
        self.engine.redo();
    }

    fn doClear(self: *App) void {
        if (self.capturing) return;
        self.engine.clearAll();
    }

    fn handleKey(self: *App, k: platform.KeyEvent) void {
        if (k.key == .ESCAPE) {
            self.running = false;
        } else if (k.key == .Q and k.modifiers.cmd) {
            self.running = false;
        } else if (k.key == .S and k.modifiers.cmd) {
            self.doSave();
        } else if (k.key == .Z and k.modifiers.cmd and k.modifiers.shift) {
            self.doRedo();
        } else if (k.key == .Z and k.modifiers.cmd) {
            self.doUndo();
        } else if (k.key == .B) {
            self.tool = .pen;
        } else if (k.key == .E) {
            self.tool = .eraser;
        } else if (k.key == .C) {
            self.doClear();
        }
    }
};

/// canvas_area rect 内に表示領域（256*ZOOM 四方）を中央配置した canvas rect
/// （core.Rect の w/h は canvas ピクセル数。screenToCanvas* がこの形を取る）。
/// 初回フレームは rect キャッシュ未生成なので null（canvas 入力・blit をスキップ）。
fn canvasBlitRect(ctx: *const gui.Context) ?core.Rect {
    const area = ctx.getNodeRect(CANVAS_AREA_ID) orelse return null;
    const vw: i32 = @as(i32, @intCast(CANVAS_W)) * ZOOM;
    const vh: i32 = @as(i32, @intCast(CANVAS_H)) * ZOOM;
    return .{
        .x = area.x + @divFloor(@as(i32, @intCast(area.w)) - vw, 2),
        .y = area.y + @divFloor(@as(i32, @intCast(area.h)) - vh, 2),
        .w = @intCast(CANVAS_W),
        .h = @intCast(CANVAS_H),
    };
}

/// window 座標が canvas 表示領域（ZOOM 倍後）内か
fn blitRectContains(rect: core.Rect, x: i32, y: i32) bool {
    return x >= rect.x and y >= rect.y and
        x < rect.x + rect.w * ZOOM and y < rect.y + rect.h * ZOOM;
}

/// canvas composite を canvas rect へ ZOOM 倍 nearest-neighbor で転送（fb 境界 clip）
fn blitCanvasZoom(fb: []u32, fb_w: u32, fb_h: u32, composite: []const u32, rect: core.Rect) void {
    for (0..CANVAS_H) |cy| {
        for (0..CANVAS_W) |cx| {
            const color = composite[cy * CANVAS_W + cx] | 0xFF000000;
            const base_fx: i32 = rect.x + @as(i32, @intCast(cx)) * ZOOM;
            const base_fy: i32 = rect.y + @as(i32, @intCast(cy)) * ZOOM;
            for (0..@as(usize, @intCast(ZOOM))) |dy| {
                for (0..@as(usize, @intCast(ZOOM))) |dx| {
                    const fx: i32 = base_fx + @as(i32, @intCast(dx));
                    const fy: i32 = base_fy + @as(i32, @intCast(dy));
                    if (fx < 0 or fy < 0) continue;
                    const ufx: u32 = @intCast(fx);
                    const ufy: u32 = @intCast(fy);
                    if (ufx >= fb_w or ufy >= fb_h) continue;
                    fb[ufy * fb_w + ufx] = color;
                }
            }
        }
    }
}

/// UI ツリー構築（widget の同期 hit-test もここで走る）
fn buildUi(ctx: *gui.Context, app: *App, canvas_rect: ?core.Rect) !void {
    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 4, 4, 4, 4 },
        .gap = 4,
    });

    // ── 1 段目: menu bar ──
    ctx.beginBox(.{
        .direction = .row,
        .width = .{ .grow = 1 },
        .padding = .{ 4, 4, 4, 4 },
        .gap = 8,
        .bg = gui.Color.rgba(0x28, 0x28, 0x30, 0xFF),
    });
    if (ctx.button("Save")) app.doSave();
    if (ctx.button("Undo")) app.doUndo();
    if (ctx.button("Redo")) app.doRedo();
    ctx.endBox();

    // ── 2 段目: canvas area (grow) + right pane (fixed 200) ──
    ctx.beginBox(.{
        .direction = .row,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .gap = 8,
    });

    // canvas area: 明示 ID・中身空（blit は endFrame 後に別パスで行う）。
    // GUI render は canvas blit の後に重ねるため、bg を持たせると canvas を上塗り
    // してしまう → bg なし（ウィンドウ背景がそのまま見える）
    ctx.beginBox(.{
        .id = CANVAS_AREA_ID,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
    });
    ctx.endBox();

    // right pane: Palette + Tool
    ctx.beginBox(.{
        .width = .{ .fixed = 200 },
        .height = .{ .grow = 1 },
        .padding = .{ 8, 8, 8, 8 },
        .gap = 6,
        .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
    });
    ctx.label("Palette");
    var idx: usize = 0;
    var row: u32 = 0;
    while (row < 4) : (row += 1) {
        ctx.beginBox(.{ .direction = .row, .gap = 3 });
        var col: u32 = 0;
        while (col < 4) : (col += 1) {
            const swatch_id: gui.Id = 0x1000 + @as(gui.Id, idx);
            if (ctx.colorSwatchId(swatch_id, .{
                .color = db16Color(idx),
                .selected = idx == app.color_idx,
                .size = 24,
            }).clicked) {
                app.color_idx = idx;
                app.tool = .pen; // 色を選んだらペンに戻す
            }
            idx += 1;
        }
        ctx.endBox();
    }
    ctx.label("Tool");
    ctx.beginBox(.{ .direction = .row, .gap = 4 });
    if (ctx.buttonEx("Pen", .{ .selected = app.tool == .pen, .min_w = 64 }).clicked) app.tool = .pen;
    if (ctx.buttonEx("Eraser", .{ .selected = app.tool == .eraser, .min_w = 64 }).clicked) app.tool = .eraser;
    ctx.endBox();
    ctx.endBox(); // right pane

    ctx.endBox(); // 2 段目

    // ── 3 段目: timeline placeholder（将来用、高さ 0） ──
    ctx.beginBox(.{ .width = .{ .grow = 1 }, .height = .{ .fixed = 0 } });
    ctx.endBox();

    // ── 4 段目: status bar ──
    ctx.beginBox(.{
        .direction = .row,
        .width = .{ .grow = 1 },
        .padding = .{ 2, 6, 2, 6 },
        .gap = 16,
        .bg = gui.Color.rgba(0x28, 0x28, 0x30, 0xFF),
    });
    const arena = ctx.allocator();
    // cursor の canvas 座標（表示領域外は "-"）。rect は前フレーム値（同期 hit-test 契約と同じ）
    const cursor_txt = blk: {
        if (canvas_rect) |rect| {
            if (core.screenToCanvas(
                .{ .x = ctx.input.mouse_pos.x, .y = ctx.input.mouse_pos.y },
                rect,
                ZOOM,
            )) |cp| {
                break :blk try std.fmt.allocPrint(arena, "cursor: ({d}, {d})", .{ cp.x, cp.y });
            }
        }
        break :blk "cursor: -";
    };
    ctx.labelEx(cursor_txt, ctx.style.text_subtle);
    ctx.labelEx(
        try std.fmt.allocPrint(arena, "color: #{X:0>6}", .{db16[app.color_idx]}),
        ctx.style.text_subtle,
    );
    ctx.labelEx(
        try std.fmt.allocPrint(arena, "tool: {s}", .{app.tool.name()}),
        ctx.style.text_subtle,
    );
    if (app.saveMsg()) |msg| ctx.label(msg);
    ctx.endBox();

    ctx.endBox(); // root
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    try platform.init();
    defer platform.shutdown();

    const window = try platform.Window.create(WINDOW_W, WINDOW_H, "Pixie");
    defer window.destroy();

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    var app: App = .{
        .io = init.io,
        .gpa = gpa,
        .engine = try paint.PaintEngine.init(gpa, CANVAS_W, CANVAS_H),
    };
    defer app.engine.deinit();

    main_loop: while (app.running and window.pollEvents()) {
        const fb = window.lockFramebuffer() orelse continue :main_loop;
        defer fb.unlock();

        ctx.beginFrame(fb.width, fb.height);

        while (window.nextEvent()) |ev| {
            switch (ev) {
                .quit => app.running = false, // ウィンドウクローズも同一経路
                .key_down => |k| app.handleKey(k),
                else => {},
            }
            if (toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
        }

        // canvas rect は前フレームの layout 結果（初回フレームは null）
        const canvas_rect = canvasBlitRect(&ctx);

        try buildUi(&ctx, &app, canvas_rect);
        ctx.endFrame();

        // ── canvas 入力（press 起点 capture。GUI と canvas は重ならない前提） ──
        if (canvas_rect) |rect| {
            const in = &ctx.input;
            if (!app.capturing and in.mouse_pressed.left and
                blitRectContains(rect, in.mouse_pressed_pos.x, in.mouse_pressed_pos.y))
            {
                app.capturing = true;
                // stroke の始点は press 起点（mouse_prev は前フレーム最終位置なので使わない）
                const cp = core.screenToCanvasRaw(
                    .{ .x = in.mouse_pressed_pos.x, .y = in.mouse_pressed_pos.y },
                    rect,
                    ZOOM,
                );
                app.engine.beginStroke(cp.x, cp.y, app.drawColor());
            }
            if (app.capturing) {
                // clamp なし変換（canvas 外は PaintEngine 側で clip）→ GUI 上でも stroke 継続
                const cp = core.screenToCanvasRaw(
                    .{ .x = in.mouse_pos.x, .y = in.mouse_pos.y },
                    rect,
                    ZOOM,
                );
                app.engine.strokeTo(cp.x, cp.y);
                if (in.mouse_released.left) {
                    app.engine.endStroke();
                    app.capturing = false;
                }
            }
        }

        // ── 描画: bg → canvas blit → GUI（上に重ねる） ──
        @memset(fb.pixels, COLOR_WINDOW_BG);
        if (canvas_rect) |rect| {
            blitCanvasZoom(fb.pixels, fb.width, fb.height, app.engine.canvas.composite(), rect);
        }
        gui.render(
            .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height },
            &ctx.draw_list,
            ctx.font,
        );
        window.present();
    }
}
