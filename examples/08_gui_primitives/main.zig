const std = @import("std");
const platform = @import("platform");
const gui = @import("gui");
const png = @import("png");

// Sample image: decode a 16x16 RGBA PNG with libs/png and blit it
const sample_png = @embedFile("sample.png");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(800, 600, "example_08: gui primitives");
    defer window.destroy();

    var draw_list = gui.DrawList.init(gpa);
    defer draw_list.deinit();

    // Decode the PNG (straight-alpha canonical BGRA = 0xAARRGGBB; same format as libs/gui image)
    var sample_img = try png.decodePNG(gpa, sample_png);
    defer sample_img.deinit(gpa);
    const img_w = sample_img.width;
    const img_h = sample_img.height;

    // String literals have static lifetime so they outlive DrawList (satisfies text/image borrow rules)
    const help_text: []const u8 = "ESC: quit  / libs-gui Phase1+2 demo";

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

        // Clear background (dark grey)
        @memset(fb.pixels, 0xFF_20_20_20);

        const target: gui.RenderTarget = .{
            .pixels = fb.pixels,
            .width = fb.width,
            .height = fb.height,
        };

        draw_list.reset(fb.width, fb.height);

        // ── rect_filled ────────────────────────────────
        try draw_list.rectFilled(
            .{ .x = 10, .y = 10, .w = 120, .h = 80 },
            gui.Color.rgba(0xFF, 0x40, 0x40, 0xFF),
        );
        // Overlay with translucency
        try draw_list.rectFilled(
            .{ .x = 60, .y = 40, .w = 120, .h = 80 },
            gui.Color.rgba(0x40, 0x40, 0xFF, 0x80),
        );

        // ── rect_outline ───────────────────────────────
        try draw_list.rectOutline(
            .{ .x = 200, .y = 10, .w = 120, .h = 80 },
            gui.Color.rgba(0x40, 0xFF, 0x40, 0xFF),
            2,
        );
        // thickness=4
        try draw_list.rectOutline(
            .{ .x = 340, .y = 10, .w = 120, .h = 80 },
            gui.Color.rgba(0xFF, 0xFF, 0x00, 0xFF),
            4,
        );

        // ── line: horizontal / vertical / diagonal ─────────────────────
        // Horizontal
        try draw_list.line(
            .{ .x = 10, .y = 120 },
            .{ .x = 480, .y = 120 },
            gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
            1,
        );
        // Vertical
        try draw_list.line(
            .{ .x = 490, .y = 10 },
            .{ .x = 490, .y = 200 },
            gui.Color.rgba(0xFF, 0x80, 0x00, 0xFF),
            1,
        );
        // Diagonal (arbitrary angle, Bresenham)
        try draw_list.line(
            .{ .x = 10, .y = 140 },
            .{ .x = 480, .y = 200 },
            gui.Color.rgba(0x00, 0xFF, 0xFF, 0xFF),
            1,
        );
        try draw_list.line(
            .{ .x = 480, .y = 140 },
            .{ .x = 10, .y = 200 },
            gui.Color.rgba(0xFF, 0x00, 0xFF, 0xFF),
            1,
        );

        // ── text ──────────────────────────────────────
        try draw_list.text(
            .{ .x = 10, .y = 220 },
            "libs/gui: Hello, World!",
            gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
        );
        try draw_list.text(
            .{ .x = 10, .y = 240 },
            help_text,
            gui.Color.rgba(0xAA, 0xAA, 0xAA, 0xFF),
        );

        // ── image blit ─────────────────────────────────
        // Place the decoded PNG (16x16) in 3 spots
        try draw_list.image(
            .{ .x = 10, .y = 270, .w = img_w, .h = img_h },
            sample_img.pixels,
            img_w,
            img_h,
        );
        try draw_list.image(
            .{ .x = 30, .y = 270, .w = img_w, .h = img_h },
            sample_img.pixels,
            img_w,
            img_h,
        );
        try draw_list.image(
            .{ .x = 50, .y = 270, .w = img_w, .h = img_h },
            sample_img.pixels,
            img_w,
            img_h,
        );

        // ── clip demo ──────────────────────────────────
        // Draw the clip-rect outline
        try draw_list.rectOutline(
            .{ .x = 9, .y = 319, .w = 202, .h = 102 },
            gui.Color.rgba(0xFF, 0xFF, 0x00, 0xFF),
            1,
        );
        // Set clip and draw a larger rect → must not spill outside the clip
        try draw_list.pushClip(.{ .x = 10, .y = 320, .w = 200, .h = 100 });
        try draw_list.rectFilled(
            .{ .x = -20, .y = 310, .w = 300, .h = 150 },
            gui.Color.rgba(0x80, 0x40, 0xFF, 0xFF),
        );
        try draw_list.text(
            .{ .x = 15, .y = 360 },
            "CLIPPED TEXT (outside is hidden)",
            gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
        );
        draw_list.popClip();

        // ── section labels ────────────────────────────
        try draw_list.text(.{ .x = 10, .y = 296 }, "image blit:", gui.Color.rgba(0xAA, 0xAA, 0xAA, 0xFF));
        try draw_list.text(.{ .x = 10, .y = 308 }, "clip demo:", gui.Color.rgba(0xAA, 0xAA, 0xAA, 0xFF));

        gui.render(target, &draw_list, gui.default_font, 1.0);

        window.present();
    }
}
