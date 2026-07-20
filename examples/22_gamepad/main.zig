//! example_22: ゲームパッド入力デモ（TASK-80.1 雛形。ADR-009）
//!
//! **実 backend は全 OS で未実装**（TASK-80.2 で対応予定）。通常起動では接続表示が「未接続」の
//! ままだが、harness の `inject gamepad_connect/disconnect/button/axis` で駆動すれば接続表示・
//! 点移動・色変化を確認できる（headless replay で self-check 可能。AGENT.md「ヘッドレス検証 harness」節）。
//!
//! 当初の想定番号は `examples/20_gamepad` だったが `20_capture_demo` が既に存在するため
//! `examples/22_gamepad`（`run-example_22`）に読み替えている（TASK-80.1 plan 参照）。
//!
//! 検証項目:
//! - `platform.MAX_GAMEPADS` 分の接続インジケータ（左上の正方形。connected=緑 / disconnected=暗灰）
//! - pad0 の左スティックで中央の点を移動（raw 値に `gamepad.applyDeadzone` を適用）
//! - pad0 の A ボタン rising edge（`gamepad.justPressed`）で点の色をパレット内で切替
//!
//! ホットパス宣言: `Window.getGamepadState` はフレーム毎に `MAX_GAMEPADS` 回（pad0..3 で4回）呼ぶ。
//! pad0 の state は1回だけ取得し、移動/ボタン判定/インジケータ表示に再利用する（pad0 を2回読まない）。
//! 4台×少数フィールドの固定長 copy（alloc/lock 無し）で全画素ループでも RT でもないため性能規約
//! （SIMD 3点セット等）の適用対象外（docs/adr/009 参照）。

const std = @import("std");
const platform = @import("platform");
const gamepad = @import("gamepad");

const WINDOW_W = 480;
const WINDOW_H = 320;

const COLOR_BG: u32 = 0xFF14141E;
const COLOR_INDICATOR_ON: u32 = 0xFF30D060;
const COLOR_INDICATOR_OFF: u32 = 0xFF303038;
const PALETTE = [_]u32{ 0xFFE0E0E0, 0xFFE04040, 0xFF40A0E0, 0xFFE0C040 };

const INDICATOR_SIZE: i32 = 16;
const INDICATOR_GAP: i32 = 20;
const INDICATOR_MARGIN: i32 = 8;
// 型注釈なし（comptime_int）: point_x/y（f32）の境界計算に混ぜても暗黙変換できるようにするため
// i32 に固定しない（fillRect への引用時は comptime_int→i32 の暗黙変換で通る）。
const POINT_SIZE = 10;
const MOVE_SPEED: f32 = 3.0;
const DEADZONE: f32 = 0.15;

/// 塗りつぶし矩形（clip 済み。example の雛形なので簡易実装）。
fn fillRect(fb: []u32, w: i32, h: i32, x: i32, y: i32, size: i32, color: u32) void {
    var yy = @max(0, y);
    const y_end = @min(h, y + size);
    while (yy < y_end) : (yy += 1) {
        var xx = @max(0, x);
        const x_end = @min(w, x + size);
        while (xx < x_end) : (xx += 1) {
            fb[@as(usize, @intCast(yy)) * @as(usize, @intCast(w)) + @as(usize, @intCast(xx))] = color;
        }
    }
}

pub fn main() !void {
    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WINDOW_W, WINDOW_H, "22 - Gamepad Input (stub, ADR-009)");
    defer window.destroy();

    var point_x: f32 = (WINDOW_W - POINT_SIZE) / 2;
    var point_y: f32 = (WINDOW_H - POINT_SIZE) / 2;
    var color_idx: usize = 0;
    var prev_buttons: platform.GamepadButtons = .{};

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| if (k.key == .ESCAPE) break :main_loop,
            .gamepad_connected => |info| {
                std.debug.print("[GAMEPAD] connected idx={d} name={s}\n", .{ info.index, info.name() });
            },
            .gamepad_disconnected => |d| {
                std.debug.print("[GAMEPAD] disconnected idx={d}\n", .{d.index});
            },
            else => {},
        };

        // pad0 の state は1回だけ取得し、移動/ボタン判定/インジケータ表示に再利用する（ホットパス宣言参照）。
        const pad0 = window.getGamepadState(0);
        if (pad0) |state| {
            const stick = gamepad.applyDeadzone(state.left_stick, DEADZONE);
            // stick.y は raw値（上入力=+1。ADR-009/TASK-80.2）。framebuffer の Y は下方向が正なので
            // 符号を反転し、実機で「上に入れると点が上へ動く」直感に合わせる（TASK-80.2 微調整）。
            point_x = std.math.clamp(point_x + stick.x * MOVE_SPEED, 0, WINDOW_W - POINT_SIZE);
            point_y = std.math.clamp(point_y - stick.y * MOVE_SPEED, 0, WINDOW_H - POINT_SIZE);
            if (gamepad.justPressed(prev_buttons, state.buttons, .a)) {
                color_idx = (color_idx + 1) % PALETTE.len;
                std.debug.print("[GAMEPAD] {s} pressed -> color {d}\n", .{ gamepad.getButtonName(.a), color_idx });
            }
            prev_buttons = state.buttons;
        } else {
            prev_buttons = .{};
        }

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, COLOR_BG);

            const w_i32: i32 = @intCast(fb.width);
            const h_i32: i32 = @intCast(fb.height);

            // 接続インジケータ（pad0 は上で取得済みの state を再利用し2回読まない）。
            var i: u8 = 0;
            while (i < platform.MAX_GAMEPADS) : (i += 1) {
                const connected = if (i == 0) (pad0 != null) else window.getGamepadState(i) != null;
                const x = INDICATOR_MARGIN + @as(i32, i) * INDICATOR_GAP;
                fillRect(fb.pixels, w_i32, h_i32, x, INDICATOR_MARGIN, INDICATOR_SIZE, if (connected) COLOR_INDICATOR_ON else COLOR_INDICATOR_OFF);
            }

            fillRect(fb.pixels, w_i32, h_i32, @intFromFloat(point_x), @intFromFloat(point_y), POINT_SIZE, PALETTE[color_idx]);
            window.present();
        }

        platform.frameDelay(16_666_666);
    }
}
