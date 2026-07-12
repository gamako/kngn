// example_14: libs/gui HSV カラーピッカー（TASK-21.14）
//
// - 2D SV スクエア（saturation×value）+ 縦 Hue バー
// - H/S/V を数値 Slider（21.9）でも編集（双方向に反映）
// - 選択色プレビュー矩形
// - Reset で初期値へ
//
// SV スクエア/Hue バーは固定 px（dl.image の制約）。ウィンドウ幅変更でも widget は崩れない。

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

const INIT_HUE: f32 = 200;
const INIT_S: f32 = 0.7;
const INIT_V: f32 = 0.9;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(420, 420, "example_14: HSV color picker");
    defer window.destroy();

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    var hue: f32 = INIT_HUE;
    var s: f32 = INIT_S;
    var v: f32 = INIT_V;
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

        ctx.label("HSV Color Picker");

        // SV スクエア + Hue バー + プレビュー
        ctx.beginBox(.{ .direction = .row, .gap = 10, .align_cross = .start });
        _ = ctx.svSquareId(0x6001, hue, &s, &v, .{});
        _ = ctx.hueBarId(0x6002, &hue, .{});
        ctx.beginBox(.{ .direction = .column, .gap = 4 });
        ctx.labelEx("preview", ctx.style.text_subtle);
        ctx.beginBox(.{
            .width = .{ .fixed = 56 },
            .height = .{ .fixed = 56 },
            .bg = gui.Color.fromHsv(hue, s, v),
            .border = .{ .color = ctx.style.border, .thickness = 1 },
        });
        ctx.endBox();
        ctx.endBox();
        ctx.endBox();

        // 数値 Slider（双方向）
        _ = ctx.sliderF32Id(0x6003, "H", &hue, .{ .min = 0, .max = 360, .step = 1 });
        _ = ctx.sliderF32Id(0x6004, "S", &s, .{ .min = 0, .max = 1, .step = 0.01 });
        _ = ctx.sliderF32Id(0x6005, "V", &v, .{ .min = 0, .max = 1, .step = 0.01 });
        hue = @min(hue, 360 - 1e-3); // hueBar と同じ [0,360) 契約に正規化（H slider が 360 を入れ得る）

        const summary = try std.fmt.allocPrint(
            ctx.allocator(),
            "H={d:.0} S={d:.2} V={d:.2}",
            .{ hue, s, v },
        );
        ctx.labelEx(summary, ctx.style.text_subtle);

        ctx.beginBox(.{ .direction = .row, .gap = 8 });
        if (ctx.button("Reset")) {
            hue = INIT_HUE;
            s = INIT_S;
            v = INIT_V;
        }
        if (ctx.button("Quit")) running = false;
        ctx.endBox();

        ctx.endBox();

        ctx.endFrame();

        gui.render(target, &ctx.draw_list, ctx.font);
        window.present();
    }
}
