// example_17: libs/gui checkbox / toggle(switch) / radio ウィジェット（TASK-48）
//
// - checkbox 2 個（bool を反転）+ toggle スイッチ 1 個（ノブが左右に動く）
// - radio group 3 択（Pen / Eraser / Brush）を caller 管理の排他選択で表示
// - 現在の状態を下にまとめ Label で出す（クリックで即反映されるのが見える）
// - いずれも glyph + label の箱全体がクリック域。ESC / Quit で終了。

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
        .quit => null,
        .char_input => null,
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

const Tool = enum {
    pen,
    eraser,
    brush,

    fn label(self: Tool) []const u8 {
        return switch (self) {
            .pen => "Pen",
            .eraser => "Eraser",
            .brush => "Brush",
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(520, 380, "example_17: gui toggles");
    defer window.destroy();

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    // 状態: checkbox 2 個 + toggle 1 個 + radio group（Tool）
    var grid = true;
    var snap = false;
    var keep_transp = true;
    var tool: Tool = .pen;
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

        ctx.beginBox(.{
            .direction = .column,
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .padding = .{ 12, 12, 12, 12 },
            .gap = 10,
            .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
        });

        // ── Checkbox ──
        ctx.label("Checkbox:");
        _ = ctx.checkbox("Show grid", &grid);
        _ = ctx.checkbox("Snap to pixel", &snap);

        // ── Toggle(switch) ──
        ctx.label("Toggle (switch):");
        _ = ctx.toggle("Keep Transp", &keep_transp);

        // ── Radio group（caller 管理の排他選択）──
        ctx.label("Tool (radio):");
        ctx.beginBox(.{ .direction = .row, .gap = 12 });
        if (ctx.radio("Pen", tool == .pen)) tool = .pen;
        if (ctx.radio("Eraser", tool == .eraser)) tool = .eraser;
        if (ctx.radio("Brush", tool == .brush)) tool = .brush;
        ctx.endBox();

        // ── 現在の状態（クリックで即反映されるのが見える）──
        const summary = try std.fmt.allocPrint(
            ctx.allocator(),
            "grid={s}  snap={s}  keep_transp={s}  tool={s}",
            .{
                if (grid) "on" else "off",
                if (snap) "on" else "off",
                if (keep_transp) "on" else "off",
                tool.label(),
            },
        );
        ctx.labelEx(summary, ctx.style.text_subtle);

        if (ctx.button("Quit")) running = false;

        ctx.endBox();

        ctx.endFrame();

        gui.render(target, &ctx.draw_list, ctx.font);
        window.present();
    }
}
