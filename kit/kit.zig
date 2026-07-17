//! kit — 公開 umbrella モジュール（ADR-007 R4）
//!
//! apps/ と外部消費者が依存してよい**唯一の公開面**。個別モジュールの直 import ではなく
//! `@import("kit")` 経由で参照することで、内部リファクタが消費者を壊さない境界をここで引く。
//!
//! 収録は「安定 lib のみ」（ADR-007 未決#2 の段階化方針。kit に載る＝将来 semver で守る対象）:
//! - platform: core/platform.zig facade（window / event / 手動描画 / getTime）
//! - control:  core/control/harness.zig（制御＋観測プレーン: probe / replay / live / 仮想クロック）
//! - types:    core/platform_types.zig（KeyCode / Event 等の type-only 共有型）
//! - audio:    core/audio.zig facade（L1 オーディオ出力）
//! - gui / png / font / dsp / synth / sound / gmath / gfx / appshell: 安定 libs
//! - gamepad: src/gamepad.zig（ゲームパッド入力ヘルパー。TASK-80.1。platform_types のみに依存する
//!   headless lib として layer=.lib で扱う。keyboard 等の gfx ヘルパーは TASK-111.2 で libs/gfx へ
//!   移設し kit.gfx 経由でも公開する）
//! - recipe: libs/recipe（CommandRecord 列の save/replay。TASK-62.5.8。std + serde のみ）
//! - sound: libs/sound（WAV デコード + SE/BGM ミキサー。TASK-111.6。dsp + synth）
//! - gfx: libs/gfx（sprite / fixed_timestep / fps_counter / keyboard / atlas / animation。TASK-111.2/111.3）
//!
//! **流動中の lib（modular / paint / viz 等）は載せない**。apps はそれらを「内部・壊れうる」
//! 前提の直 import で使い、API が固まったら kit へ昇格する（成熟ゲート）。
//!
//! 注意: platform が backend 毎の module のため、kit も backend 毎に生成される
//! （build.zig の makeKitModule）。ここに import を足す場合は build.zig 側の配線も揃えること。

pub const platform = @import("platform");
pub const control = @import("harness");
pub const types = @import("platform_types");
pub const command_types = @import("command_types");
pub const audio = @import("audio");
pub const gui = @import("gui");
pub const png = @import("png");
pub const font = @import("font");
pub const dsp = @import("dsp");
pub const synth = @import("synth");
pub const gamepad = @import("gamepad");
pub const midi = @import("midi");
pub const recipe = @import("recipe");
pub const gmath = @import("gmath");
pub const gfx = @import("gfx");
pub const appshell = @import("appshell");
pub const app_runtime = @import("app_runtime");
pub const sound = @import("sound");

// ============================================================================
// platform.Event → gui.InputEvent アダプタ（TASK-111.7）
// ============================================================================

/// platform.MouseButton → gui.InputEvent の button index（0=left / 1=right / 2=middle）。
/// 未知の button は `0xFF`（gui 側で無視されうる sentinel。pixie 正準）。
fn buttonToU8(b: platform.MouseButton) u8 {
    return switch (b) {
        .left => 0,
        .right => 1,
        .middle => 2,
        else => 0xFF,
    };
}

/// `platform.Event` → `gui.InputEvent` の公式アダプタ（pixie 現行意味論が正準）。
///
/// GUI に関係しないイベントは `null`:
/// - `quit`
/// - `char_input`（IME 確定文字。GUI へ渡すかは app 側判断。examples/27・28 は自前で渡す）
/// - `gamepad_connected` / `gamepad_disconnected`
/// - `composition_changed`
/// - `menu_command`（App.dispatchCommand で消費）
///
/// キーの負値（`KeyCode.UNKNOWN = -1` 等）は破棄（libs/gui は u32 code 前提）。
///
/// 使い方:
/// ```
/// if (kit.toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
/// ```
///
/// ホットパス: イベント到着時のみ。全画素・RT・フレーム毎 allocation 無し。
pub fn toGuiEvent(ev: platform.Event) ?gui.InputEvent {
    return switch (ev) {
        .quit => null,
        .char_input => null,
        .gamepad_connected, .gamepad_disconnected => null,
        .composition_changed => null,
        .menu_command => null,
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

// ============================================================================
// tests（adapter。test-kit 経由で収集。TASK-111.7）
// ============================================================================
const std = @import("std");
const testing = std.testing;

test "toGuiEvent: mouse move/down/up/scroll の値と modifier" {
    const shift = platform.ModifierFlags{ .shift = true };
    const move = toGuiEvent(.{ .mouse_move = .{
        .x = 10,
        .y = 20,
        .button = .none,
        .buttons = .{},
        .modifiers = shift,
    } }).?;
    try testing.expect(move == .mouse_move);
    try testing.expectEqual(@as(i32, 10), move.mouse_move.x);
    try testing.expectEqual(@as(i32, 20), move.mouse_move.y);
    try testing.expectEqual(shift.toC(), move.mouse_move.modifiers);

    const down = toGuiEvent(.{ .mouse_down = .{
        .x = 1,
        .y = 2,
        .button = .left,
        .buttons = .{ .left = true },
        .modifiers = .{ .ctrl = true },
    } }).?;
    try testing.expect(down == .mouse_down);
    try testing.expectEqual(@as(u8, 0), down.mouse_down.button);
    try testing.expectEqual((platform.ModifierFlags{ .ctrl = true }).toC(), down.mouse_down.modifiers);

    const up = toGuiEvent(.{ .mouse_up = .{
        .x = 3,
        .y = 4,
        .button = .right,
        .buttons = .{},
        .modifiers = .{},
    } }).?;
    try testing.expect(up == .mouse_up);
    try testing.expectEqual(@as(u8, 1), up.mouse_up.button);

    const scroll = toGuiEvent(.{ .mouse_scroll = .{
        .x = 5,
        .y = 6,
        .dx = 1.5,
        .dy = -2.25,
        .is_precise = true,
        .buttons = .{},
        .modifiers = .{ .alt = true },
    } }).?;
    try testing.expect(scroll == .mouse_scroll);
    try testing.expectEqual(@as(f32, 1.5), scroll.mouse_scroll.dx);
    try testing.expectEqual(@as(f32, -2.25), scroll.mouse_scroll.dy);
    try testing.expectEqual((platform.ModifierFlags{ .alt = true }).toC(), scroll.mouse_scroll.modifiers);
}

test "toGuiEvent: left/right/middle と未知 button" {
    const left = toGuiEvent(.{ .mouse_down = .{
        .x = 0,
        .y = 0,
        .button = .left,
        .buttons = .{},
        .modifiers = .{},
    } }).?;
    try testing.expectEqual(@as(u8, 0), left.mouse_down.button);

    const right = toGuiEvent(.{ .mouse_down = .{
        .x = 0,
        .y = 0,
        .button = .right,
        .buttons = .{},
        .modifiers = .{},
    } }).?;
    try testing.expectEqual(@as(u8, 1), right.mouse_down.button);

    const middle = toGuiEvent(.{ .mouse_down = .{
        .x = 0,
        .y = 0,
        .button = .middle,
        .buttons = .{},
        .modifiers = .{},
    } }).?;
    try testing.expectEqual(@as(u8, 2), middle.mouse_down.button);

    const unknown = toGuiEvent(.{ .mouse_down = .{
        .x = 0,
        .y = 0,
        .button = @enumFromInt(99),
        .buttons = .{},
        .modifiers = .{},
    } }).?;
    try testing.expectEqual(@as(u8, 0xFF), unknown.mouse_down.button);
}

test "toGuiEvent: key down/up と repeat、UNKNOWN 破棄" {
    const kd = toGuiEvent(.{ .key_down = .{
        .key = .A,
        .is_repeat = true,
        .modifiers = .{ .cmd = true },
    } }).?;
    try testing.expect(kd == .key_down);
    try testing.expectEqual(@as(u32, @intCast(@intFromEnum(platform.KeyCode.A))), kd.key_down.code);
    try testing.expect(kd.key_down.repeat);
    try testing.expectEqual((platform.ModifierFlags{ .cmd = true }).toC(), kd.key_down.modifiers);

    const ku = toGuiEvent(.{ .key_up = .{
        .key = .ESCAPE,
        .is_repeat = false,
        .modifiers = .{},
    } }).?;
    try testing.expect(ku == .key_up);
    try testing.expectEqual(@as(u32, @intCast(@intFromEnum(platform.KeyCode.ESCAPE))), ku.key_up.code);

    try testing.expect(toGuiEvent(.{ .key_down = .{
        .key = .UNKNOWN,
        .is_repeat = false,
        .modifiers = .{},
    } }) == null);
    try testing.expect(toGuiEvent(.{ .key_up = .{
        .key = .UNKNOWN,
        .is_repeat = false,
        .modifiers = .{},
    } }) == null);
}

test "toGuiEvent: pixie と同じ無視対象イベントは null" {
    try testing.expect(toGuiEvent(.quit) == null);
    try testing.expect(toGuiEvent(.{ .char_input = .{ .codepoint = 'a', .modifiers = .{} } }) == null);
    try testing.expect(toGuiEvent(.{ .gamepad_connected = .{ .index = 0 } }) == null);
    try testing.expect(toGuiEvent(.{ .gamepad_disconnected = .{ .index = 0 } }) == null);
    try testing.expect(toGuiEvent(.{ .composition_changed = .{
        .revision = 1,
        .phase = .update,
        .cursor = 0,
    } }) == null);
    try testing.expect(toGuiEvent(.{ .menu_command = 42 }) == null);
}
