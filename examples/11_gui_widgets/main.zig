// example_11: libs/gui basic widgets
//
// - Toolbar: 3 buttons + grow spacer + 2 buttons (Quit actually exits)
// - Pen / Eraser: tool-selection toggle via buttonEx(selected)
// - DB16 palette: 4x4 grid of colorSwatchId. Click to select; selection gets a thick border
// - Translucent swatch: checkerboard + blend demo
// - Counter: button click increments (+1) and updates the Label
//
// Reflow on resize uses the fb size every frame.

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

/// DawnBringer 16 palette (0xRRGGBB).
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
    var selected_color: usize = 6; // DB16 red
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

        // ── Toolbar: button 3 + grow spacer + button 2 ──
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
        ctx.beginBox(.{ .width = .{ .grow = 1 } }); // Spacer
        ctx.endBox();
        if (ctx.button("Help")) click_count += 1;
        if (ctx.button("Quit")) running = false;
        ctx.endBox();

        // ── Content row: left = tools / counter, right = palette ──
        ctx.beginBox(.{
            .direction = .row,
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .padding = .{ 8, 8, 8, 8 },
            .gap = 12,
        });

        // Left pane: tool selection (selected toggle) and counter
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

        // Right pane: DB16 palette (4x4) + translucent demo
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

        ctx.endBox(); // Content row

        ctx.endFrame();

        gui.render(target, &ctx.draw_list, ctx.font, 1.0);
        window.present();
    }
}
