//! 27_selectable_label: read-only SelectableLabel drag / double-click / Cmd+C demo.
//!
//! Hot path declaration: selection updates and copy requests are event-only. Drawing uses the existing gui.render / Font path and
//! selection rect/text DrawCmd; no new all-pixel loop. This demo does not
//! emit path commands and does not inspect the DrawCmd union.

const std = @import("std");
const kit = @import("kit");
const platform = kit.platform;
const gui = kit.gui;

const CopyProbe = struct {
    count: u32 = 0,
    bytes: usize = 0,

    fn digest(ctx: *anyopaque, buf: []u8) []const u8 {
        const self: *const CopyProbe = @ptrCast(@alignCast(ctx));
        return std.fmt.bufPrint(buf, "count={d} bytes={d}", .{ self.count, self.bytes }) catch buf[0..0];
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(640, 360, "example_27: selectable label");
    defer window.destroy();

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    var copy_probe: CopyProbe = .{};
    platform.registerProbe(.{
        .name = "copy",
        .ctx = &copy_probe,
        .ext = "txt",
        .digest = CopyProbe.digest,
        .desc = "SelectableLabel copy requests",
    });

    var running = true;
    main_loop: while (running and window.pollEvents()) {
        const fb = window.lockFramebuffer() orelse continue :main_loop;
        defer fb.unlock();

        ctx.beginFrameAt(fb.width, fb.height, platform.getTime());
        while (window.nextEvent()) |ev| {
            if (ev == .quit) running = false;
            if (kit.toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
        }

        @memset(fb.pixels, 0xFF_18181C);
        ctx.beginBox(.{
            .direction = .column,
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .padding = .{ 72, 24, 0, 24 },
            .gap = 12,
        });
        const first = ctx.selectableLabelId(0x2701, "SelectableLabel drag across ASCII and 日本語 text", .{});
        const second = ctx.selectableLabelId(0x2702, "短い日本語ラベル", .{});
        ctx.labelEx("drag / double-click / Cmd+C", gui.Color.rgba(0xA0, 0xA8, 0xB8, 0xFF));
        ctx.endBox();

        if (first.copy_request) |r| {
            platform.setClipboardText(r.text);
            copy_probe.count += 1;
            copy_probe.bytes += r.text.len;
        }
        if (second.copy_request) |r| {
            platform.setClipboardText(r.text);
            copy_probe.count += 1;
            copy_probe.bytes += r.text.len;
        }

        ctx.endFrame();
        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        gui.render(target, ctx.postFrameDrawList(), ctx.font, 1.0);
        window.present();
    }
}
