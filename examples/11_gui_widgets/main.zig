// example_11: libs/gui 基本ウィジェット（TASK-21.5）
//
// - ツールバー: button 3 個 + grow スペーサ + button 2 個（Quit は実際に終了する）
// - Pen / Eraser: buttonEx(selected) によるツール選択トグル表示
// - DB16 パレット: colorSwatchId の 4x4 グリッド。クリックで選択、選択中は太枠
// - 半透明 swatch: チェック柄 + blend のデモ
// - カウンタ: button クリックで +1（Label 表示更新）
//
// リサイズ再フローは毎フレーム fb サイズから行う（最終確認は TASK-23 完了後）。

const std = @import("std");
const platform = @import("platform");
const gui = @import("gui");

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
        .char_input => null,
        .gamepad_connected, .gamepad_disconnected => null, // TASK-80.1: GUI 未消費（cross-cutting Event 追加）
        .composition_changed => null, // TASK-79.6.1: composition 未消費（inline preedit は 79.6.2）
        .menu_command => null, // TASK-97.1: app の共通 dispatch 入口で消費
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

/// DawnBringer 16 パレット（0xRRGGBB）。
const db16 = [16]u32{
    0x000000, 0x442434, 0x30346D, 0x4E4A4E,
    0x854C30, 0x346524, 0xD04648, 0x757161,
    0x597DCE, 0xD27D2C, 0x8595A1, 0x6DAA2C,
    0xD2AA99, 0x6DC2CA, 0xDAD45E, 0xDEEED6,
};

fn db16Color(i: usize) gui.Color {
    const c = db16[i];
    return gui.Color.rgba(@truncate(c >> 16), @truncate(c >> 8), @truncate(c), 0xFF);
}

const Tool = enum { pen, eraser };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(640, 480, "example_11: gui widgets");
    defer window.destroy();

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    var click_count: u32 = 0;
    var tool: Tool = .pen;
    var selected_color: usize = 6; // DB16 の赤
    var running = true;

    main_loop: while (running and window.pollEvents()) {
        const fb = window.lockFramebuffer() orelse continue :main_loop;
        defer fb.unlock();

        ctx.beginFrame(fb.width, fb.height);

        while (window.nextEvent()) |ev| {
            switch (ev) {
                .quit => running = false,
                .key_down => |ke| {
                    if (ke.key == .ESCAPE) running = false;
                },
                else => {},
            }
            if (toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
        }

        @memset(fb.pixels, 0xFF_18_18_1C);
        const target: gui.RenderTarget = .{
            .pixels = fb.pixels,
            .width = fb.width,
            .height = fb.height,
        };

        // ── ツールバー: button 3 + grow スペーサ + button 2（AC#5） ──
        ctx.beginBox(.{
            .direction = .row,
            .width = .{ .grow = 1 },
            .padding = .{ 8, 8, 8, 8 },
            .gap = 8,
            .bg = gui.Color.rgba(0x28, 0x28, 0x30, 0xFF),
        });
        if (ctx.button("New")) click_count += 1;
        if (ctx.button("Open")) click_count += 1;
        if (ctx.button("Save")) click_count += 1;
        ctx.beginBox(.{ .width = .{ .grow = 1 } }); // スペーサ
        ctx.endBox();
        if (ctx.button("Help")) click_count += 1;
        if (ctx.button("Quit")) running = false;
        ctx.endBox();

        // ── コンテンツ行: 左 = ツール / カウンタ、右 = パレット ──
        ctx.beginBox(.{
            .direction = .row,
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .padding = .{ 8, 8, 8, 8 },
            .gap = 12,
        });

        // 左ペイン: ツール選択（selected トグル表示）とカウンタ
        ctx.beginBox(.{
            .width = .{ .fixed = 220 },
            .height = .{ .grow = 1 },
            .padding = .{ 8, 8, 8, 8 },
            .gap = 6,
            .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
        });
        ctx.label("Tool:");
        ctx.beginBox(.{ .direction = .row, .gap = 4 });
        if (ctx.buttonEx("Pen", .{ .selected = tool == .pen, .min_w = 60 }).clicked) tool = .pen;
        if (ctx.buttonEx("Eraser", .{ .selected = tool == .eraser, .min_w = 60 }).clicked) tool = .eraser;
        ctx.endBox();
        ctx.labelEx(if (tool == .pen) "current: Pen" else "current: Eraser", ctx.style.text_subtle);
        ctx.label("--------");
        if (ctx.button("count up")) click_count += 1;
        const count_txt = try std.fmt.allocPrint(ctx.allocator(), "count: {d}", .{click_count});
        ctx.label(count_txt);
        ctx.endBox();

        // 右ペイン: DB16 パレット（4x4）+ 半透明デモ
        ctx.beginBox(.{
            .padding = .{ 8, 8, 8, 8 },
            .gap = 6,
            .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
        });
        ctx.label("Palette (DB16)");
        var idx: usize = 0;
        var row: u32 = 0;
        while (row < 4) : (row += 1) {
            ctx.beginBox(.{ .direction = .row, .gap = 3 });
            var col: u32 = 0;
            while (col < 4) : (col += 1) {
                const swatch_id: gui.Id = 0x1000 + @as(gui.Id, idx);
                if (ctx.colorSwatchId(swatch_id, .{
                    .color = db16Color(idx),
                    .selected = idx == selected_color,
                }).clicked) selected_color = idx;
                idx += 1;
            }
            ctx.endBox();
        }
        const color_txt = try std.fmt.allocPrint(
            ctx.allocator(),
            "color: #{X:0>6}",
            .{db16[selected_color]},
        );
        ctx.labelEx(color_txt, ctx.style.text_subtle);
        ctx.label("alpha 50% demo:");
        ctx.beginBox(.{ .direction = .row, .gap = 3 });
        var t: usize = 0;
        while (t < 4) : (t += 1) {
            var c = db16Color(t + 6);
            c.a = 0x80;
            _ = ctx.colorSwatchId(0x2000 + @as(gui.Id, t), .{ .color = c, .size = 24 });
        }
        ctx.endBox();
        ctx.endBox();

        ctx.endBox(); // コンテンツ行

        ctx.endFrame();

        gui.render(target, &ctx.draw_list, ctx.font);
        window.present();
    }
}
