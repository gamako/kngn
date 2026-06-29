// example_16: libs/gui 縦横スクロール領域（TASK-46）
//
// - viewport より大きい 12x12 グリッドを beginScrollArea/endScrollArea に入れる。
// - 縦横ホイールでスクロール、両軸スクロールバー thumb のドラッグでもスクロール。
// - 各セルは座標ラベル付き（どの範囲が見えているか snapshot で分かる）。
// - 左上 0,0 / 右下 11,11 まで到達できることがスクロール動作の確認になる。

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

const ROWS: usize = 12;
const COLS: usize = 12;
const CELL_W: i32 = 48;
const CELL_H: i32 = 24;
const SCROLL_ID: gui.Id = 0x5C0011;
const CELL_ID_BASE: gui.Id = 0x5CE11_000;

fn cellColor(r: usize, c: usize) gui.Color {
    const rr: u8 = @intCast(28 + r * 18);
    const bb: u8 = @intCast(28 + c * 18);
    return gui.Color.rgba(rr, 0x44, bb, 0xFF);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(380, 300, "example_16: gui scroll");
    defer window.destroy();

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    var scroll: gui.Vec2f = .{};
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
            .padding = .{ 10, 10, 10, 10 },
            .gap = 8,
            .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
        });

        const header = try std.fmt.allocPrint(
            ctx.allocator(),
            "scroll demo  wheel / drag bar   scroll=({d},{d})",
            .{ @as(i32, @intFromFloat(@round(scroll.x))), @as(i32, @intFromFloat(@round(scroll.y))) },
        );
        ctx.label(header);

        // 縦横スクロール領域: viewport より大きい 12x12 グリッド
        ctx.beginScrollArea(SCROLL_ID, &scroll, .{
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .padding = .{ 4, 4, 4, 4 },
            .gap = 4,
            .bg = gui.Color.rgba(0x16, 0x18, 0x1E, 0xFF),
            .border = .{ .color = ctx.style.border, .thickness = 1 },
            .bar_thickness = 10,
        });
        var r: usize = 0;
        while (r < ROWS) : (r += 1) {
            ctx.beginBox(.{ .direction = .row, .gap = 4 });
            var c: usize = 0;
            while (c < COLS) : (c += 1) {
                const cell_id: gui.Id = CELL_ID_BASE + @as(gui.Id, @intCast(r * COLS + c));
                ctx.beginBox(.{
                    .id = cell_id,
                    .width = .{ .fixed = CELL_W },
                    .height = .{ .fixed = CELL_H },
                    .align_cross = .center,
                    .bg = cellColor(r, c),
                    .clip_children = true,
                });
                const label = try std.fmt.allocPrint(ctx.allocator(), "{d},{d}", .{ r, c });
                ctx.label(label);
                ctx.endBox();
            }
            ctx.endBox();
        }
        ctx.endScrollArea();

        ctx.endBox();

        ctx.endFrame();

        gui.render(target, &ctx.draw_list, ctx.font);
        window.present();
    }
}
