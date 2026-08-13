//! 45_path_drawing: filled paths (curves, a concave shape, a hole, AA on/off).
//!
//! A still frame. Curves, a chevron, a ring with a hole, and the same curve
//! with anti-aliasing on and off sit side by side so the edge difference is
//! visible. Built only from the root (`zig build run-example_45`).

const std = @import("std");
const platform = @import("platform");
const gui = @import("gui");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(800, 520, "example_45: path drawing");
    defer window.destroy();

    var draw_list = gui.DrawList.init(gpa);
    defer draw_list.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const help: []const u8 = "ESC: quit  / filled paths (curve, concave, hole, AA on/off)";

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |ke| {
                if (ke.key == .ESCAPE) break :main_loop;
            },
            else => {},
        };

        const fb = window.lockFramebuffer() orelse continue :main_loop;
        defer fb.unlock();

        @memset(fb.pixels, 0xFF_18_18_1C);

        const target: gui.RenderTarget = .{
            .pixels = fb.pixels,
            .width = fb.width,
            .height = fb.height,
        };

        _ = arena.reset(.retain_capacity);
        draw_list.reset(fb.width, fb.height);

        try draw_list.text(.{ .x = 16, .y = 12 }, help, gui.Color.rgba(0xAA, 0xAA, 0xB0, 0xFF));

        try draw_list.text(.{ .x = 16, .y = 44 }, "cubic blob", gui.Color.rgba(0x88, 0x88, 0x90, 0xFF));
        {
            var p = draw_list.beginPath(arena.allocator());
            try p.moveTo(.{ .x = 40, .y = 160 });
            try p.cubicTo(.{ .x = 40, .y = 60 }, .{ .x = 200, .y = 60 }, .{ .x = 200, .y = 160 });
            try p.cubicTo(.{ .x = 200, .y = 240 }, .{ .x = 40, .y = 240 }, .{ .x = 40, .y = 160 });
            try p.close();
            try p.finish(.{ .color = gui.Color.rgba(0x40, 0xA0, 0xFF, 0xFF) });
        }

        try draw_list.text(.{ .x = 240, .y = 44 }, "concave chevron", gui.Color.rgba(0x88, 0x88, 0x90, 0xFF));
        {
            var p = draw_list.beginPath(arena.allocator());
            try p.moveTo(.{ .x = 250, .y = 70 });
            try p.lineTo(.{ .x = 430, .y = 70 });
            try p.lineTo(.{ .x = 430, .y = 250 });
            try p.lineTo(.{ .x = 340, .y = 160 });
            try p.lineTo(.{ .x = 250, .y = 250 });
            try p.close();
            try p.finish(.{ .color = gui.Color.rgba(0x50, 0xD0, 0x70, 0xFF) });
        }

        try draw_list.text(.{ .x = 460, .y = 44 }, "hole (nonzero)", gui.Color.rgba(0x88, 0x88, 0x90, 0xFF));
        {
            var p = draw_list.beginPath(arena.allocator());
            try p.moveTo(.{ .x = 480, .y = 70 });
            try p.lineTo(.{ .x = 700, .y = 70 });
            try p.lineTo(.{ .x = 700, .y = 250 });
            try p.lineTo(.{ .x = 480, .y = 250 });
            try p.close();
            try p.moveTo(.{ .x = 530, .y = 120 });
            try p.lineTo(.{ .x = 530, .y = 200 });
            try p.lineTo(.{ .x = 650, .y = 200 });
            try p.lineTo(.{ .x = 650, .y = 120 });
            try p.close();
            try p.finish(.{ .color = gui.Color.rgba(0xF0, 0xC0, 0x40, 0xFF) });
        }

        try draw_list.text(.{ .x = 16, .y = 280 }, "AA on", gui.Color.rgba(0x88, 0x88, 0x90, 0xFF));
        {
            var p = draw_list.beginPath(arena.allocator());
            try p.moveTo(.{ .x = 30, .y = 460 });
            try p.quadTo(.{ .x = 140, .y = 300 }, .{ .x = 250, .y = 460 });
            try p.lineTo(.{ .x = 220, .y = 480 });
            try p.quadTo(.{ .x = 140, .y = 360 }, .{ .x = 60, .y = 480 });
            try p.close();
            try p.finish(.{ .color = gui.Color.rgba(0xFF, 0x70, 0x90, 0xFF), .aa = true });
        }

        try draw_list.text(.{ .x = 280, .y = 280 }, "AA off", gui.Color.rgba(0x88, 0x88, 0x90, 0xFF));
        {
            var p = draw_list.beginPath(arena.allocator());
            try p.moveTo(.{ .x = 300, .y = 460 });
            try p.quadTo(.{ .x = 410, .y = 300 }, .{ .x = 520, .y = 460 });
            try p.lineTo(.{ .x = 490, .y = 480 });
            try p.quadTo(.{ .x = 410, .y = 360 }, .{ .x = 330, .y = 480 });
            try p.close();
            try p.finish(.{ .color = gui.Color.rgba(0xFF, 0x70, 0x90, 0xFF), .aa = false });
        }

        try draw_list.text(.{ .x = 560, .y = 280 }, "translucent", gui.Color.rgba(0x88, 0x88, 0x90, 0xFF));
        try draw_list.rectFilled(.{ .x = 560, .y = 320, .w = 200, .h = 160 }, gui.Color.rgba(0x40, 0x40, 0x80, 0xFF));
        {
            var p = draw_list.beginPath(arena.allocator());
            try p.moveTo(.{ .x = 580, .y = 340 });
            try p.cubicTo(.{ .x = 640, .y = 300 }, .{ .x = 700, .y = 460 }, .{ .x = 740, .y = 460 });
            try p.lineTo(.{ .x = 740, .y = 480 });
            try p.lineTo(.{ .x = 580, .y = 480 });
            try p.close();
            try p.finish(.{ .color = gui.Color.rgba(0xFF, 0xFF, 0xFF, 0x90) });
        }

        gui.render(target, &draw_list, gui.default_font, 1.0);
        window.present();
    }
}
