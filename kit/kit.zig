//! kit — public umbrella module (ADR-007 R4)
//!
//! The **only public surface** apps/ and external consumers may depend on. Import via
//! `@import("kit")` rather than individual modules, so internal refactors stay behind this boundary.
//!
//! Contents are "stable libs only" (ADR-007 staging: being in kit means covered by future semver):
//! - platform: core/platform.zig facade (window / event / manual draw / getTime)
//! - control:  core/control/harness.zig (control+obs plane: probe / replay / live / virtual clock)
//! - types:    core/platform_types.zig (type-only shared types: KeyCode / Event, …)
//! - audio:    core/audio.zig facade (L1 audio output)
//! - gui / png / font / dsp / synth / sound / gmath / gfx / appshell / pixelops: stable libs
//! - gamepad: src/gamepad.zig (gamepad input helper; platform_types-only
//!   headless lib at layer=.lib. Keyboard and other gfx helpers live under libs/gfx and
//!   are also exposed via kit.gfx)
//! - recipe: libs/recipe (save/replay of CommandRecord sequences; std + serde only)
//! - sound: libs/sound (WAV decode + SE/BGM mixer; dsp + synth)
//! - gfx: libs/gfx (sprite / fixed_timestep / fps_counter / keyboard / atlas / animation)
//! - pixelops: libs/pixelops (shared SIMD blend / u32 fill for all-pixel loops)
//!
//! **Libs still in flux (modular / paint / viz, …) stay out.** Apps import those directly as
//! "internal / may break", and promote them into kit once the API settles (maturity gate).
//!
//! Note: because platform is a per-backend module, kit is also generated per backend
//! (makeKitModule in build.zig). Adding an import here requires matching wiring in build.zig.

pub const platform = @import("platform");
pub const control = @import("harness");
pub const frame_prof = @import("frame_prof");
pub const types = @import("platform_types");
pub const command_types = @import("command_types");
pub const audio = @import("audio");
pub const gui = @import("gui");
pub const png = @import("png");
pub const font = @import("font");
pub const GuiFont = @import("gui_font.zig").GuiFont;
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
pub const pixelops = @import("pixelops");

// ============================================================================
// platform.Event → gui.InputEvent adapter
// ============================================================================

/// platform.MouseButton → gui.InputEvent button index (0=left / 1=right / 2=middle).
/// Unknown buttons map to `0xFF` (sentinel the gui side may ignore; pixie is canonical).
fn buttonToU8(b: platform.MouseButton) u8 {
    return switch (b) {
        .left => 0,
        .right => 1,
        .middle => 2,
        else => 0xFF,
    };
}

/// Canonical `platform.Event` → `gui.InputEvent` adapter (pixie's current semantics).
///
/// GUI-unrelated events return `null`:
/// - `quit`
/// - `char_input` (IME-committed char; whether to forward to GUI is app-owned. examples/27 and 28 pass it themselves)
/// - `gamepad_connected` / `gamepad_disconnected`
/// - `composition_changed`
/// - `menu_command` / `file_drop` (menu: App.dispatchCommand; drop: app-owned)
///
/// Negative key values (`KeyCode.UNKNOWN = -1`, …) are discarded (libs/gui assumes u32 codes).
///
/// Usage:
/// ```
/// if (kit.toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
/// ```
///
/// Hot path: on event arrival only. No per-pixel / RT / per-frame allocation.
pub fn toGuiEvent(ev: platform.Event) ?gui.InputEvent {
    return switch (ev) {
        .quit => null,
        .char_input => null,
        .gamepad_connected, .gamepad_disconnected => null,
        .composition_changed => null,
        .menu_command => null,
        .file_drop => null,
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
// tests (adapter; collected via test-kit)
// ============================================================================
const std = @import("std");
const testing = std.testing;

// Pull in gui_font.zig's test block (`pub const GuiFont = @import(...).GuiFont` alone does not
// make Zig collect sibling-file tests. Same ref pattern as libs/gui).
test {
    _ = @import("gui_font.zig");
}

test "toGuiEvent: mouse move/down/up/scroll values and modifiers" {
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

test "toGuiEvent: left/right/middle and unknown button" {
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

test "toGuiEvent: key down/up and repeat; discard UNKNOWN" {
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

test "toGuiEvent: events ignored by pixie return null" {
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
    try testing.expect(toGuiEvent(.{ .file_drop = platform.makeFileDropEventFromPath("/tmp/a.png").? }) == null);
}
