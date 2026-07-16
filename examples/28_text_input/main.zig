//! 28_text_input: 単一行 TextInput の focus / UTF-8 編集 / selection / scroll デモ。
//!
//! ホットパス宣言: 編集・caret・selection・scroll はイベント時のみ。描画は既存 DrawCmd と
//! Font 経路を再利用し、caret blink は Context の仮想時刻だけで決定する。

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

const InputProbe = struct {
    focus: u32 = 0,
    len: usize = 0,
    caret: usize = 0,
    selection_start: usize = 0,
    selection_end: usize = 0,
    scroll: i32 = 0,

    fn update(self: *InputProbe, buffer: *const gui.TextBuffer, result: gui.TextInputResult, caret: usize) void {
        self.focus = if (result.focused) 1 else 0;
        self.len = buffer.slice().len;
        self.caret = caret;
        self.selection_start = result.selection.start;
        self.selection_end = result.selection.end;
    }

    fn digest(ctx: *anyopaque, buf: []u8) []const u8 {
        const self: *const InputProbe = @ptrCast(@alignCast(ctx));
        return std.fmt.bufPrint(buf, "focus={d} len={d} caret={d} selection={d}:{d} scroll={d}", .{
            self.focus,
            self.len,
            self.caret,
            self.selection_start,
            self.selection_end,
            self.scroll,
        }) catch buf[0..0];
    }
};

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

    var window = try platform.Window.create(640, 360, "example_28: text input");
    defer window.destroy();

    var first_buffer = try gui.TextBuffer.init(gpa, "");
    defer first_buffer.deinit();
    var second_buffer = try gui.TextBuffer.init(gpa, "A long second input demonstrates horizontal caret scrolling");
    defer second_buffer.deinit();

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    var input_probe: InputProbe = .{};
    var copy_probe: CopyProbe = .{};
    platform.registerProbe(.{
        .name = "input",
        .ctx = &input_probe,
        .ext = "txt",
        .digest = InputProbe.digest,
        .desc = "TextInput focus/edit state",
    });
    platform.registerProbe(.{
        .name = "copy",
        .ctx = &copy_probe,
        .ext = "txt",
        .digest = CopyProbe.digest,
        .desc = "TextInput copy requests",
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
            .gap = 24,
        });
        const first = ctx.textInputId(0x2801, &first_buffer, .{
            .width = .{ .fixed = 320 },
            .placeholder = "Type ASCII or 日本語...",
        });
        const second = ctx.textInputId(0x2802, &second_buffer, .{
            .width = .{ .fixed = 320 },
            .placeholder = "Second input",
        });
        ctx.labelEx("single-line UTF-8 input / Shift selection / Cmd+C", gui.Color.rgba(0xA0, 0xA8, 0xB8, 0xFF));
        ctx.endBox();

        if (first.focused or ctx.focusedId() == 0) {
            input_probe.update(&first_buffer, first, ctx.perIdState(0x2801).caret);
            input_probe.scroll = ctx.perIdState(0x2801).scroll_x;
        } else {
            input_probe.update(&second_buffer, second, ctx.perIdState(0x2802).caret);
            input_probe.scroll = ctx.perIdState(0x2802).scroll_x;
        }
        if (ctx.focusedId() == 0) input_probe.focus = 0;
        if (first.copy_request) |r| {
            platform.clipboardWrite(r.text);
            copy_probe.count += 1;
            copy_probe.bytes += r.text.len;
        }
        if (second.copy_request) |r| {
            platform.clipboardWrite(r.text);
            copy_probe.count += 1;
            copy_probe.bytes += r.text.len;
        }

        ctx.endFrame();
        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        gui.render(target, &ctx.draw_list, ctx.font);
        window.present();
    }
}
