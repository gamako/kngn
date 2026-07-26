// example_09: libs/gui input management + hot/active + frame lifecycle
//
// - Three buttons that call buttonBehavior directly (widgets land later; here they are
//   hand-drawn with buttonBehavior + rectFilled / rectOutline).
//   Hover changes the outline; press changes the fill; release increments the clicked counter.
// - A "canvas" region on the right draws a marker at the mouse only when
//   ctx.wantsMouse() is false (checks GUI vs canvas input contention).
// - Converting platform.Event → gui.InputEvent is the caller's job (this sample).

const std = @import("std");
const platform = @import("platform");
const gui = @import("gui");

/// platform.MouseButton → InputEvent button index (0=left/1=right/2=middle).
fn buttonToU8(b: platform.MouseButton) u8 {
    return switch (b) {
        .left => 0,
        .right => 1,
        .middle => 2,
        else => 0xFF,
    };
}

/// platform.Event → gui.InputEvent. quit (irrelevant to GUI) becomes null.
/// Discard negative key codes (platform KeyCode.UNKNOWN = -1); libs/gui expects u32 codes.
fn toGuiEvent(ev: platform.Event) ?gui.InputEvent {
    return switch (ev) {
        .quit => null,
        .char_input => null,
        .gamepad_connected, .gamepad_disconnected => null, // Unused by GUI (cross-cutting Event)
        .composition_changed => null, // composition unused (inline preedit lives elsewhere)
        .menu_command => null, // Consumed at the app's common dispatch entry
        .file_drop => null, // Not forwarded to GUI
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

    const canvas_rect = gui.Rect{ .x = 300, .y = 60, .w = 450, .h = 480 };

    const help_text: []const u8 = "ESC: quit / hover-click the buttons / move into the right canvas to drop a marker";

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
            if (toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
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
