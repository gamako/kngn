// example_10: libs/gui Flex レイアウトエンジン（TASK-21.4）
//
// - ツールバー: fit 箱 3 + grow スペーサ + fit 箱 2（ウィンドウ幅に追従して再フロー）
// - 3 カラム: fixed 200 / grow / fixed 240
// - ネスト box の padding / gap
// - clip_children: 長いテキストが枠でクリップされる
// - 明示 ID + getNodeRect + buttonBehavior による「前フレーム rect の同期 hit-test」デモ
//   （widget 層は 21.5 で実装するため、ここでは生 API を組み合わせる）

const std = @import("std");
const platform = @import("platform");
const gui = @import("gui");

/// platform.MouseButton → InputEvent の button index（0=left/1=right/2=middle）。
fn buttonToU8(b: platform.MouseButton) u8 {
    return switch (b) {
        .left => 0,
        .right => 1,
        .middle => 2,
        else => 0xFF,
    };
}

/// platform.Event → gui.InputEvent。GUI に関係しない quit は null。
/// key の負値（platform KeyCode.UNKNOWN = -1）は捨てる（libs/gui は u32 code 前提）。
fn toGuiEvent(ev: platform.Event) ?gui.InputEvent {
    return switch (ev) {
        .quit => null,
        .char_input => null,
        .gamepad_connected, .gamepad_disconnected => null, // TASK-80.1: GUI 未消費（cross-cutting Event 追加）
        .composition_changed => null, // TASK-79.6.1: composition 未消費（inline preedit は 79.6.2）
        .menu_command => null, // TASK-97.1: app の共通 dispatch 入口で消費
        .file_drop => null, // TASK-113.4: GUI へ転送しない
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

/// fit サイズのツールバー項目（見た目だけの箱。インタラクションなし）。
fn toolItem(ctx: *gui.Context, name: []const u8) void {
    ctx.beginBox(.{
        .padding = .{ 6, 10, 6, 10 },
        .bg = gui.Color.rgba(0x38, 0x38, 0x40, 0xFF),
    });
    ctx.label(name);
    ctx.endBox();
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(900, 600, "example_10: gui layout");
    defer window.destroy();

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    var click_count: u32 = 0;

    main_loop: while (window.pollEvents()) {
        const fb = window.lockFramebuffer() orelse continue :main_loop;
        defer fb.unlock();

        ctx.beginFrame(fb.width, fb.height);

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

        @memset(fb.pixels, 0xFF_18_18_1C);
        const target: gui.RenderTarget = .{
            .pixels = fb.pixels,
            .width = fb.width,
            .height = fb.height,
        };
        const full_clip = gui.Rect{ .x = 0, .y = 0, .w = fb.width, .h = fb.height };

        // ── 同期 hit-test: 前フレームの rect キャッシュで widget 呼び出し時に判定 ──
        // （初回フレームは rect 未確定なので非ヒット扱い）
        const btn_id = ctx.id_stack.make("demo_button");
        var btn_res: gui.ButtonResult = .{};
        if (ctx.getNodeRect(btn_id)) |prev_rect| {
            btn_res = gui.buttonBehavior(&ctx, btn_id, prev_rect, full_clip);
        }
        if (btn_res.clicked) click_count += 1;

        // ── ツールバー: fit 3 + grow スペーサ + fit 2 ──
        ctx.beginBox(.{
            .direction = .row,
            .width = .{ .grow = 1 },
            .padding = .{ 8, 8, 8, 8 },
            .gap = 8,
            .bg = gui.Color.rgba(0x28, 0x28, 0x30, 0xFF),
        });
        toolItem(&ctx, "New");
        toolItem(&ctx, "Open");
        toolItem(&ctx, "Save");
        ctx.beginBox(.{ .width = .{ .grow = 1 } }); // スペーサ
        ctx.endBox();
        toolItem(&ctx, "Help");
        toolItem(&ctx, "Quit");
        ctx.endBox();

        // ── 3 カラム: fixed 200 / grow / fixed 240 ──
        ctx.beginBox(.{
            .direction = .row,
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .padding = .{ 8, 8, 8, 8 },
            .gap = 8,
        });

        // 左ペイン（fixed 200）: ネスト box の padding / gap デモ
        ctx.beginBox(.{
            .width = .{ .fixed = 200 },
            .height = .{ .grow = 1 },
            .padding = .{ 8, 8, 8, 8 },
            .gap = 6,
            .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
        });
        ctx.label("left (fixed 200)");
        ctx.beginBox(.{
            .width = .{ .grow = 1 },
            .padding = .{ 6, 6, 6, 6 },
            .gap = 4,
            .bg = gui.Color.rgba(0x2C, 0x32, 0x3C, 0xFF),
        });
        ctx.label("nested box");
        ctx.label("padding 6 / gap 4");
        ctx.endBox();
        ctx.endBox();

        // 中央（grow）: clip デモ + hit-test デモボタン
        ctx.beginBox(.{
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .padding = .{ 8, 8, 8, 8 },
            .gap = 8,
            .bg = gui.Color.rgba(0x1C, 0x20, 0x26, 0xFF),
        });
        ctx.label("center (grow)");

        // clip_children: 長文が 200x28 の枠でクリップされる
        ctx.beginBox(.{
            .width = .{ .fixed = 200 },
            .height = .{ .fixed = 28 },
            .padding = .{ 6, 6, 6, 6 },
            .clip_children = true,
            .bg = gui.Color.rgba(0x40, 0x30, 0x30, 0xFF),
        });
        ctx.label("clipped: this long text does not escape the box ----");
        ctx.endBox();

        // 明示 ID のボタン箱（hover/held で bg 変化、クリックでカウンタ）
        const btn_bg = if (btn_res.held)
            gui.Color.rgba(0x30, 0x60, 0xC0, 0xFF)
        else if (ctx.state.hot_id == btn_id)
            gui.Color.rgba(0x50, 0x50, 0x60, 0xFF)
        else
            gui.Color.rgba(0x38, 0x38, 0x40, 0xFF);
        ctx.beginBox(.{
            .id = btn_id,
            .padding = .{ 8, 12, 8, 12 },
            .bg = btn_bg,
        });
        const btn_txt = try std.fmt.allocPrint(ctx.allocator(), "click me: {d}", .{click_count});
        ctx.label(btn_txt);
        ctx.endBox();
        ctx.endBox();

        // 右ペイン（fixed 240）: align_cross = center
        ctx.beginBox(.{
            .width = .{ .fixed = 240 },
            .height = .{ .grow = 1 },
            .padding = .{ 8, 8, 8, 8 },
            .gap = 6,
            .align_cross = .center,
            .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
        });
        ctx.label("right (fixed 240)");
        ctx.label("align_cross:");
        ctx.label("center");
        ctx.endBox();

        ctx.endBox(); // 3 カラム

        ctx.endFrame();

        gui.render(target, &ctx.draw_list, ctx.font);
        window.present();
    }
}
