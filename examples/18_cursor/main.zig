//! 18_cursor: システムカーソル形状の切替サンプル (TASK-75.1)
//!
//! platform.CursorShape + window.setCursor() の動作確認用。02_keyboard_input を土台にした
//! 最小サンプルで、キー入力でカーソル形状を切り替える:
//!   - 1: default（矢印）
//!   - 2: crosshair（十字）
//!   - 0: hidden（非表示）
//!
//! 実際のOSカーソル形状はframebufferに写らないため、状態ごとに背景色も変える。これにより
//! headless replay（VP_HEADLESS）でも「setCursor呼び出しを含む状態遷移がクラッシュせず
//! 動作する」ことを fb digest で確認できる（AC#3 の自動化可能な範囲）。OSカーソルの実際の見た目
//! （矢印/十字/非表示）は手動目視で確認する（AC#2。ヘッドレスでは検証不可）。
//!
//! ホットパス宣言: setCursor 呼び出しはキー入力イベント時のみ（フレーム毎の全画素ループでも
//! RTオーディオ経路でもない）。性能規約の適用対象外。

const std = @import("std");
const platform = @import("platform");

const KeyCode = platform.KeyCode;
const CursorShape = platform.CursorShape;

// カーソル形状ごとの背景色（canonical BGRA, u32 0xAARRGGBB）。実カーソルの代わりに状態を可視化する。
fn backgroundColorFor(shape: CursorShape) u32 {
    return switch (shape) {
        .default => 0xFF303030, // 濃い灰色
        .crosshair => 0xFF1E3A5F, // 濃い青
        .hidden => 0xFF000000, // 黒
    };
}

fn shapeName(shape: CursorShape) []const u8 {
    return switch (shape) {
        .default => "default (arrow)",
        .crosshair => "crosshair",
        .hidden => "hidden",
    };
}

pub fn main() !void {
    std.debug.print("Starting 18_cursor (System Cursor Shape Switching)...\n", .{});

    try platform.init();
    defer platform.shutdown();

    var window = platform.Window.create(
        640,
        480,
        "18: Cursor Shape",
    ) catch |err| {
        std.debug.print("Failed to create window: {s}\n", .{@errorName(err)});
        return;
    };
    defer window.destroy();

    std.debug.print("Window created.\n", .{});
    std.debug.print("Controls:\n", .{});
    std.debug.print("  1: default cursor (arrow)\n", .{});
    std.debug.print("  2: crosshair cursor\n", .{});
    std.debug.print("  0: hidden cursor\n", .{});
    std.debug.print("  ESC/Q: Quit\n", .{});

    var current_shape: CursorShape = .default;
    var current_color: u32 = backgroundColorFor(current_shape);

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => {
                std.debug.print("Quit event received\n", .{});
                break :main_loop;
            },
            .key_down => |k| {
                if (k.key == .ESCAPE or k.key == .Q) {
                    std.debug.print("Quit key pressed\n", .{});
                    break :main_loop;
                }

                const new_shape: ?CursorShape = switch (k.key) {
                    .@"1" => .default,
                    .@"2" => .crosshair,
                    .@"0" => .hidden,
                    else => null,
                };
                if (new_shape) |shape| {
                    current_shape = shape;
                    window.setCursor(shape);
                    current_color = backgroundColorFor(shape);
                    std.debug.print("[CURSOR] -> {s}\n", .{shapeName(shape)});
                }
            },
            .key_up => {},
            else => {},
        };

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, current_color);
            window.present();
        }

        platform.frameDelay(16_666_666);
    }

    std.debug.print("Application terminated.\n", .{});
}
