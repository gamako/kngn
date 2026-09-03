// example_14: libs/gui HSV colour picker
//
// - 2D SV square (saturation×value) + vertical Hue bar
// - H/S/V also editable via numeric Sliders (reflect both ways)
// - Selected-colour preview rect
// - Reset restores the initial values
//
// SV square / Hue bar are fixed px (dl.image constraint). Widgets stay intact when the window width changes.

const std = @import("std");
const kit = @import("kit");
const platform = kit.platform;
const gui = kit.gui;

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
            if (kit.toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
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

        // SV square + Hue bar + preview
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

        // Numeric Sliders (bidirectional)
        _ = ctx.sliderF32Id(0x6003, "H", &hue, .{ .min = 0, .max = 360, .step = 1 });
        _ = ctx.sliderF32Id(0x6004, "S", &s, .{ .min = 0, .max = 1, .step = 0.01 });
        _ = ctx.sliderF32Id(0x6005, "V", &v, .{ .min = 0, .max = 1, .step = 0.01 });
        hue = @min(hue, 360 - 1e-3); // Normalise to the same [0,360) contract as hueBar (the H slider can enter 360)

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

        gui.render(target, ctx.postFrameDrawList(), ctx.font, 1.0);
        window.present();
    }
}
