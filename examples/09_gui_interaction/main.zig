// example_09: libs/gui raw buttonBehavior + hot/active + frame lifecycle
//
// Composes hot/active from the raw API, then hand-drawn fill and outline
// from the result. Two hit-test sources:
// - The three left buttons pass a caller-supplied (fixed) rect.
// - The "layout hit" box is an explicit-ID beginBox; buttonBehavior reads
//   getNodeRect (previous-frame cache) and the box bg follows that result.
// Hover changes the outline; press changes the fill; release increments the
// clicked counter.
// - A "canvas" region on the right draws a marker at the mouse only when
//   ctx.wantsMouse() is false (checks GUI vs canvas input contention).
// - platform.Event is converted with the published `kit.toGuiEvent` adapter.

const std = @import("std");
const kit = @import("kit");
const platform = kit.platform;
const gui = kit.gui;

const Button = struct { rect: gui.Rect, label: []const u8 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(800, 600, "example_09: gui interaction");
    defer window.destroy();

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    const buttons = [_]Button{
        .{ .rect = .{ .x = 50, .y = 60, .w = 180, .h = 60 }, .label = "Button A" },
        .{ .rect = .{ .x = 50, .y = 140, .w = 180, .h = 60 }, .label = "Button B" },
        .{ .rect = .{ .x = 50, .y = 220, .w = 180, .h = 60 }, .label = "Button C" },
    };
    var click_counts = [_]u32{ 0, 0, 0 };
    var layout_clicks: u32 = 0;
    const layout_id: gui.Id = 0x0901;

    const canvas_rect = gui.Rect{ .x = 300, .y = 60, .w = 450, .h = 480 };

    const help_text: []const u8 = "ESC: quit / hover-click the buttons / layout-hit uses getNodeRect / canvas drops a marker";

    main_loop: while (window.pollEvents()) {
        const fb = window.lockFramebuffer() orelse continue :main_loop;
        defer fb.unlock();

        ctx.beginFrame(fb.width, fb.height);

        // ── Event handling (pushEvent after beginFrame, before widgets) ──
        while (window.nextEvent()) |ev| {
            switch (ev) {
                .quit => break :main_loop,
                .key_down => |ke| {
                    if (ke.key == .ESCAPE) break :main_loop;
                },
                else => {},
            }
            if (kit.toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
        }

        // Clear background (dark grey)
        @memset(fb.pixels, 0xFF_20_20_20);
        const target: gui.RenderTarget = .{
            .pixels = fb.pixels,
            .width = fb.width,
            .height = fb.height,
        };

        const full_clip = gui.Rect{ .x = 0, .y = 0, .w = fb.width, .h = fb.height };

        try ctx.draw_list.text(.{ .x = 50, .y = 24 }, help_text, gui.Color.rgba(0xAA, 0xAA, 0xAA, 0xFF));

        // ── Buttons (direct buttonBehavior) ──
        for (buttons, 0..) |btn, i| {
            const id = ctx.id_stack.make(btn.label);
            const r = gui.buttonBehavior(&ctx, id, btn.rect, full_clip);
            if (r.clicked) click_counts[i] += 1;

            // Fill colour: pressed > hover > normal (hover reads the stable hot_id)
            const fill = if (r.held)
                gui.Color.rgba(0x30, 0x60, 0xC0, 0xFF)
            else if (ctx.state.hot_id == id)
                gui.Color.rgba(0x50, 0x50, 0x60, 0xFF)
            else
                gui.Color.rgba(0x38, 0x38, 0x40, 0xFF);
            try ctx.draw_list.rectFilled(btn.rect, fill);

            const border = if (ctx.state.hot_id == id)
                gui.Color.rgba(0xFF, 0xD0, 0x40, 0xFF)
            else
                gui.Color.rgba(0x80, 0x80, 0x90, 0xFF);
            try ctx.draw_list.rectOutline(btn.rect, border, 2);

            try ctx.draw_list.text(
                .{ .x = btn.rect.x + 12, .y = btn.rect.y + 14 },
                btn.label,
                gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
            );
            // Format the click count on the arena (payload valid until next beginFrame)
            const txt = try std.fmt.allocPrint(ctx.allocator(), "clicks: {d}", .{click_counts[i]});
            try ctx.draw_list.text(
                .{ .x = btn.rect.x + 12, .y = btn.rect.y + 36 },
                txt,
                gui.Color.rgba(0xB0, 0xB0, 0xB0, 0xFF),
            );
        }

        // ── Explicit-ID box: sync hit-test against the previous-frame cache ──
        var layout_res: gui.ButtonResult = .{};
        if (ctx.getNodeRect(layout_id)) |prev| {
            layout_res = gui.buttonBehavior(&ctx, layout_id, prev, full_clip);
        }
        if (layout_res.clicked) layout_clicks += 1;
        const layout_bg = if (layout_res.held)
            gui.Color.rgba(0x30, 0x60, 0xC0, 0xFF)
        else if (ctx.state.hot_id == layout_id)
            gui.Color.rgba(0x50, 0x50, 0x60, 0xFF)
        else
            gui.Color.rgba(0x38, 0x38, 0x40, 0xFF);
        const layout_border = if (ctx.state.hot_id == layout_id)
            gui.Color.rgba(0xFF, 0xD0, 0x40, 0xFF)
        else
            gui.Color.rgba(0x80, 0x80, 0x90, 0xFF);
        ctx.beginBox(.{ .direction = .column, .padding = .{ 298, 0, 0, 50 } });
        ctx.beginBox(.{
            .id = layout_id,
            .padding = .{ 8, 12, 8, 12 },
            .bg = layout_bg,
            .border = .{ .color = layout_border, .thickness = 2 },
        });
        ctx.label("layout hit");
        var layout_buf: [24]u8 = undefined;
        const layout_txt = std.fmt.bufPrint(&layout_buf, "clicks: {d}", .{layout_clicks}) catch "";
        ctx.labelEx(layout_txt, gui.Color.rgba(0xB0, 0xB0, 0xB0, 0xFF));
        ctx.endBox();
        ctx.endBox();

        // ── Canvas region ──
        try ctx.draw_list.rectFilled(canvas_rect, gui.Color.rgba(0x18, 0x18, 0x1C, 0xFF));
        try ctx.draw_list.rectOutline(canvas_rect, gui.Color.rgba(0x60, 0x60, 0x70, 0xFF), 1);
        try ctx.draw_list.text(
            .{ .x = canvas_rect.x + 10, .y = canvas_rect.y + 10 },
            "canvas (wantsMouse == false here)",
            gui.Color.rgba(0x70, 0x70, 0x80, 0xFF),
        );

        // Draw a marker at the mouse inside the canvas only when GUI has not consumed the mouse
        if (!ctx.wantsMouse()) {
            const mp = ctx.input.mouse_pos;
            if (canvas_rect.contains(mp)) {
                try ctx.draw_list.rectFilled(
                    .{ .x = mp.x - 2, .y = mp.y - 2, .w = 5, .h = 5 },
                    gui.Color.rgba(0xFF, 0x50, 0x50, 0xFF),
                );
            }
        }

        ctx.endFrame();

        gui.render(target, &ctx.draw_list, ctx.font, 1.0);
        window.present();
    }
}
