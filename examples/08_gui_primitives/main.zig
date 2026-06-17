const std = @import("std");
const platform = @import("platform");
const gui = @import("gui");
const png_decoder = @import("png-decoder");

// サンプル画像: 16x16 RGBA PNG を libs/png-decoder でデコードして image blit する
const sample_png = @embedFile("sample.png");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(800, 600, "example_08: gui primitives");
    defer window.destroy();

    var draw_list = gui.DrawList.init(gpa);
    defer draw_list.deinit();

    // PNG をデコード（straight alpha canonical BGRA = 0xAARRGGBB、libs/gui の image と同フォーマット）
    var sample_img = try png_decoder.decodePNG(gpa, sample_png);
    defer sample_img.deinit(gpa);
    const img_w = sample_img.width;
    const img_h = sample_img.height;

    // 文字列リテラルは static lifetime なので DrawList より長命（text/image の借用契約を満たす）
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

        // 背景クリア（ダークグレー）
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
        // 半透明で重ね合わせ
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

        // ── line: 水平・垂直・斜め ─────────────────────
        // 水平
        try draw_list.line(
            .{ .x = 10, .y = 120 }, .{ .x = 480, .y = 120 },
            gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), 1,
        );
        // 垂直
        try draw_list.line(
            .{ .x = 490, .y = 10 }, .{ .x = 490, .y = 200 },
            gui.Color.rgba(0xFF, 0x80, 0x00, 0xFF), 1,
        );
        // 斜め（任意角度、Bresenham）
        try draw_list.line(
            .{ .x = 10, .y = 140 }, .{ .x = 480, .y = 200 },
            gui.Color.rgba(0x00, 0xFF, 0xFF, 0xFF), 1,
        );
        try draw_list.line(
            .{ .x = 480, .y = 140 }, .{ .x = 10, .y = 200 },
            gui.Color.rgba(0xFF, 0x00, 0xFF, 0xFF), 1,
        );

        // ── text ──────────────────────────────────────
        try draw_list.text(
            .{ .x = 10, .y = 220 },
            "libs/gui TASK-21.3: Hello, World!",
            gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
        );
        try draw_list.text(
            .{ .x = 10, .y = 240 },
            help_text,
            gui.Color.rgba(0xAA, 0xAA, 0xAA, 0xFF),
        );

        // ── image blit ─────────────────────────────────
        // デコードした PNG（16x16）を 3 か所に配置
        try draw_list.image(
            .{ .x = 10, .y = 270, .w = img_w, .h = img_h },
            sample_img.pixels, img_w, img_h,
        );
        try draw_list.image(
            .{ .x = 30, .y = 270, .w = img_w, .h = img_h },
            sample_img.pixels, img_w, img_h,
        );
        try draw_list.image(
            .{ .x = 50, .y = 270, .w = img_w, .h = img_h },
            sample_img.pixels, img_w, img_h,
        );

        // ── clip demo ──────────────────────────────────
        // clip rect のアウトラインを描画
        try draw_list.rectOutline(
            .{ .x = 9, .y = 319, .w = 202, .h = 102 },
            gui.Color.rgba(0xFF, 0xFF, 0x00, 0xFF), 1,
        );
        // clip を設定して大きめの rect を描画 → clip 外はみ出さない
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

        gui.render(target, &draw_list, gui.default_font);

        window.present();
    }
}
