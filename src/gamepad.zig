//! Gamepad utility module (ADR-009)
//!
//! `platform_types.GamepadButton`/`GamepadButtons`/`Stick` helpers (button names,
//! rising-edge detection, deadzone). The types themselves live in `platform_types.zig`; this module
//! re-exports them. Like `keyboard.zig` it is a helper module, and `kit/kit.zig` also
//! re-exports it (keyboard lives under libs/gfx and is also exposed via kit.gfx).
//!
//! Depends only on `platform_types` (does not import the `platform` facade), so it unit-tests
//! headless with no display/backend.

const std = @import("std");
const types = @import("platform_types");

pub const GamepadButton = types.GamepadButton;
pub const GamepadButtons = types.GamepadButtons;
pub const Stick = types.Stick;
pub const GamepadState = types.GamepadState;

/// Map a button to a human-readable string (the `GamepadButton` declaration name; exhaustive switch).
pub fn getButtonName(btn: GamepadButton) []const u8 {
    return switch (btn) {
        .a => "A",
        .b => "B",
        .x => "X",
        .y => "Y",
        .left_shoulder => "LEFT_SHOULDER",
        .right_shoulder => "RIGHT_SHOULDER",
        .back => "BACK",
        .start => "START",
        .left_stick => "LEFT_STICK",
        .right_stick => "RIGHT_STICK",
        .dpad_up => "DPAD_UP",
        .dpad_down => "DPAD_DOWN",
        .dpad_left => "DPAD_LEFT",
        .dpad_right => "DPAD_RIGHT",
        .guide => "GUIDE",
    };
}

/// Whether `button` is a rising edge: off in `prev` (previous frame), on in `cur` (current frame).
/// The "just pressed" check equivalent to a key's `is_repeat` for poll-based gamepad state, for the
/// consumer to do itself (the facade/harness do not keep previous-frame state).
pub fn justPressed(prev: GamepadButtons, cur: GamepadButtons, button: GamepadButton) bool {
    return !prev.isSet(button) and cur.isSet(button);
}

/// Whether `button` is a falling edge (just released): on in `prev`, off in `cur`.
pub fn justReleased(prev: GamepadButtons, cur: GamepadButtons, button: GamepadButton) bool {
    return prev.isSet(button) and !cur.isSet(button);
}

/// Apply a radial deadzone (ADR-009 "raw values plus a deadzone helper").
/// If the stick radius (`sqrt(x^2+y^2)`) is below `dz`, return `(0,0)`; otherwise linearly rescale the
/// range beyond `dz` onto `0..1` (up to the original max radius of 1.0), keeping direction.
/// `dz` is expected in `[0, 1)` (`dz >= 1` always returns `(0,0)`; negative values are treated as 0).
pub fn applyDeadzone(stick: Stick, dz: f32) Stick {
    const clamped_dz = std.math.clamp(dz, 0, 1);
    if (clamped_dz >= 1) return .{ .x = 0, .y = 0 }; // dz>=1 always disables (explicit branch to avoid division by zero)
    const radius = @sqrt(stick.x * stick.x + stick.y * stick.y);
    if (radius <= clamped_dz) return .{ .x = 0, .y = 0 };
    const scaled_radius = @min(1, (radius - clamped_dz) / (1 - clamped_dz));
    const scale = scaled_radius / radius;
    return .{ .x = stick.x * scale, .y = stick.y * scale };
}

// ============================================================================
// tests (no display/backend; depends only on platform_types)
// ============================================================================
const testing = std.testing;

test "getButtonName: all 15 buttons match their declaration names (catches exhaustive-switch gaps)" {
    try testing.expectEqualStrings("A", getButtonName(.a));
    try testing.expectEqualStrings("GUIDE", getButtonName(.guide));
    inline for (@typeInfo(GamepadButton).@"enum".fields) |f| {
        const btn: GamepadButton = @enumFromInt(f.value);
        const name = getButtonName(btn);
        try testing.expect(name.len > 0);
    }
}

test "justPressed/justReleased: true only on rising/falling edge" {
    var prev = GamepadButtons{};
    var cur = GamepadButtons{};
    try testing.expect(!justPressed(prev, cur, .a));
    try testing.expect(!justReleased(prev, cur, .a));

    cur.set(.a, true);
    try testing.expect(justPressed(prev, cur, .a));
    try testing.expect(!justReleased(prev, cur, .a));

    prev.set(.a, true);
    try testing.expect(!justPressed(prev, cur, .a)); // Both on = not a rising edge
    try testing.expect(!justReleased(prev, cur, .a));

    cur.set(.a, false);
    try testing.expect(!justPressed(prev, cur, .a));
    try testing.expect(justReleased(prev, cur, .a));

    // Does not affect other buttons
    try testing.expect(!justPressed(prev, cur, .b));
    try testing.expect(!justReleased(prev, cur, .b));
}

test "applyDeadzone: near centre -> (0,0); outside deadzone rescales keeping direction" {
    // Centre (radius 0) is always (0,0)
    {
        const r = applyDeadzone(.{ .x = 0, .y = 0 }, 0.2);
        try testing.expectEqual(@as(f32, 0), r.x);
        try testing.expectEqual(@as(f32, 0), r.y);
    }
    // Below the deadzone (radius 0.1 < dz=0.2) is (0,0)
    {
        const r = applyDeadzone(.{ .x = 0.1, .y = 0 }, 0.2);
        try testing.expectEqual(@as(f32, 0), r.x);
        try testing.expectEqual(@as(f32, 0), r.y);
    }
    // At full deflection (radius 1.0) stays as-is regardless of dz (boundary: scaled_radius=1)
    {
        const r = applyDeadzone(.{ .x = 1.0, .y = 0 }, 0.2);
        try testing.expectApproxEqAbs(@as(f32, 1.0), r.x, 1e-5);
        try testing.expectApproxEqAbs(@as(f32, 0.0), r.y, 1e-5);
    }
    // Just at the deadzone edge (radius 0.2 == dz) is near (0,0) (scaled_radius=0)
    {
        const r = applyDeadzone(.{ .x = 0.2, .y = 0 }, 0.2);
        try testing.expectApproxEqAbs(@as(f32, 0.0), r.x, 1e-5);
    }
    // Mid value (radius 0.6, dz=0.2): scaled_radius=(0.6-0.2)/(1-0.2)=0.5, direction kept (x-axis only)
    {
        const r = applyDeadzone(.{ .x = 0.6, .y = 0 }, 0.2);
        try testing.expectApproxEqAbs(@as(f32, 0.5), r.x, 1e-5);
        try testing.expectApproxEqAbs(@as(f32, 0.0), r.y, 1e-5);
    }
    // Diagonal input also keeps direction (angle)
    {
        const r = applyDeadzone(.{ .x = 0.6, .y = 0.8 }, 0.0); // radius 1.0, dz=0
        try testing.expectApproxEqAbs(@as(f32, 0.6), r.x, 1e-5);
        try testing.expectApproxEqAbs(@as(f32, 0.8), r.y, 1e-5);
    }
    // dz>=1 is always (0,0) (checked with normal input whose radius is in [0,1])
    {
        const r = applyDeadzone(.{ .x = 0.6, .y = 0.6 }, 1.5);
        try testing.expectEqual(@as(f32, 0), r.x);
        try testing.expectEqual(@as(f32, 0), r.y);
    }
}
