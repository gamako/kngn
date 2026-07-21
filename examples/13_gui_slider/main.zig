// example_13: libs/gui Slider ウィジェット（TASK-21.9）
//
// - sliderI32 2 本（Size 1..64 / Opacity 0..255）+ sliderF32 2 本（Hue 0..360 step1 / Alpha 0..1 step0.05）
// - 各 slider の現在値は widget 自身が右側に数値表示する。下にまとめ Label も出す。
// - Reset ボタンで全 slider を初期値へ戻す。
// - drag は knob を掴んで左右に動かす（track だけクリックでは飛ばない = AC#4）。
//
// リサイズ再フローは毎フレーム fb サイズから行う。track は固定幅なので幅変更で崩れない。

const std = @import("std");
const platform = @import("platform");
const gui = @import("gui");

fn buttonToU8(b: platform.MouseButton) u8 {
    return switch (b) {
        .left => 0,
        .right => 1,
        .middle => 2,
        else => 0xFF,
    };
}

fn toGuiEvent(ev: platform.Event) ?gui.InputEvent {
    return switch (ev) {
        .quit => null,
        .char_input => null,
        .gamepad_connected, .gamepad_disconnected => null, // TASK-80.1: GUI 未消費（cross-cutting Event 追加）
        .composition_changed => null, // TASK-79.6.1: composition 未消費（inline preedit は 79.6.2）
        .menu_command => null, // TASK-97.1: app の共通 dispatch 入口で消費
        .file_drop => null, // TASK-113.4: GUI へ転送しない
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

const INIT_SIZE: i32 = 8;
const INIT_OPACITY: i32 = 200;
const INIT_HUE: f32 = 180;
const INIT_ALPHA: f32 = 0.5;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(520, 360, "example_13: gui slider");
    defer window.destroy();

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    var size: i32 = INIT_SIZE;
    var opacity: i32 = INIT_OPACITY;
    var hue: f32 = INIT_HUE;
    var alpha: f32 = INIT_ALPHA;
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

        ctx.beginBox(.{
            .direction = .column,
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .padding = .{ 12, 12, 12, 12 },
            .gap = 10,
            .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
        });

        ctx.label("Sliders (drag the knob):");

        _ = ctx.sliderI32Id(0x5001, "Size   ", &size, .{ .min = 1, .max = 64 });
        _ = ctx.sliderI32Id(0x5002, "Opacity", &opacity, .{ .min = 0, .max = 255 });
        _ = ctx.sliderF32Id(0x5003, "Hue    ", &hue, .{ .min = 0, .max = 360, .step = 1 });
        _ = ctx.sliderF32Id(0x5004, "Alpha  ", &alpha, .{ .min = 0, .max = 1, .step = 0.05 });

        const summary = try std.fmt.allocPrint(
            ctx.allocator(),
            "size={d}  opacity={d}  hue={d:.0}  alpha={d:.2}",
            .{ size, opacity, hue, alpha },
        );
        ctx.labelEx(summary, ctx.style.text_subtle);

        ctx.beginBox(.{ .direction = .row, .gap = 8 });
        if (ctx.button("Reset")) {
            size = INIT_SIZE;
            opacity = INIT_OPACITY;
            hue = INIT_HUE;
            alpha = INIT_ALPHA;
        }
        if (ctx.button("Quit")) running = false;
        ctx.endBox();

        ctx.endBox();

        ctx.endFrame();

        gui.render(target, &ctx.draw_list, ctx.font, 1.0);
        window.present();
    }
}
