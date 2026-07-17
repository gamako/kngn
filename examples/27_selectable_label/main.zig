//! 27_selectable_label: read-only SelectableLabel の drag / double-click / Cmd+C デモ。
//!
//! ホットパス宣言: 選択更新とコピー要求はイベント時のみ。描画は既存 gui.render / Font 経路と
//! 選択 rect/text DrawCmd を使い、新規の全画素ループを作らない。

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
        .quit, .gamepad_connected, .gamepad_disconnected, .composition_changed, .menu_command => null,
        .mouse_move => |m| .{ .mouse_move = .{ .x = m.x, .y = m.y, .modifiers = m.modifiers.toC() } },
        .mouse_down => |m| .{ .mouse_down = .{ .x = m.x, .y = m.y, .button = buttonToU8(m.button), .modifiers = m.modifiers.toC() } },
        .mouse_up => |m| .{ .mouse_up = .{ .x = m.x, .y = m.y, .button = buttonToU8(m.button), .modifiers = m.modifiers.toC() } },
        .mouse_scroll => |s| .{ .mouse_scroll = .{ .x = s.x, .y = s.y, .dx = s.dx, .dy = s.dy, .modifiers = s.modifiers.toC() } },
        .char_input => |ch| .{ .char_input = .{ .codepoint = ch.codepoint, .modifiers = ch.modifiers.toC() } },
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
            if (toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
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
        gui.render(target, &ctx.draw_list, ctx.font);
        window.present();
    }
}
