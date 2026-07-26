//! The pure translation logic of Wayland input. Pure Zig, with no `@cImport`.
//!
//! It takes the values (integers and bools) from the part that drives wl_keyboard, wl_pointer and
//! xkbcommon (`platform_linux_wayland.zig`, Linux only), and gathers here only the translation, on the
//! same semantics as the X11 backend, so that it can be unit tested on a macOS host with
//! `zig build test-platform-wayland-input` (the same design as X11's `platform_linux_input.zig`).
//!
//! The physical key mapping, the KeyDownSet and the EventQueue are reused from `platform_linux_input.zig`.
//! Only what is specific to Wayland (evdev+8, the evdev BTN_* codes, wl_fixed coordinates, xkb
//! modifiers, axis scrolling and repeat timing) lives in this file.

const std = @import("std");
const types = @import("platform_types");
const linux_input = @import("platform_linux_input.zig");

const KeyCode = types.KeyCode;
const MouseButton = types.MouseButton;
const ModifierFlags = types.ModifierFlags;

/// 1 notch = ±16 points (consistent with X11's wheelDelta and macOS's SCROLL_LINE_TO_POINTS).
pub const SCROLL_LINE_TO_POINTS: f32 = linux_input.SCROLL_LINE_TO_POINTS;

// evdev button codes (what wl_pointer.button carries; a different space from X11's 1/2/3)
pub const BTN_LEFT: u32 = 0x110;
pub const BTN_RIGHT: u32 = 0x111;
pub const BTN_MIDDLE: u32 = 0x112;

// the axis values of wl_pointer.axis
pub const AXIS_VERTICAL: u32 = 0;
pub const AXIS_HORIZONTAL: u32 = 1;

// ============================================================================
// physical keys: an evdev keycode → KeyCode (independent of layout; no KeySym)
// ============================================================================

/// From the evdev keycode of `wl_keyboard.key` to a KeyCode. Since `X keycode = evdev + 8`, the
/// existing X11 table (`keycodeToKeyCode`) is reused through `evdev + 8` (keeping the physical key contract).
pub fn waylandKeyToKeyCode(evdev_key: u32) KeyCode {
    return linux_input.keycodeToKeyCode(evdev_key + 8);
}

// ============================================================================
// mouse button: evdev BTN_* → MouseButton
// ============================================================================

pub fn evdevButtonToMouseButton(code: u32) ?MouseButton {
    return switch (code) {
        BTN_LEFT => .left,
        BTN_RIGHT => .right,
        BTN_MIDDLE => .middle,
        else => null,
    };
}

// ============================================================================
// pointer coordinates: wl_fixed (24.8 fixed point) → i32
// ============================================================================

/// Follows `wl_fixed_to_int` (divide by 256 and truncate towards zero). Negative values truncate towards zero too (-256→-1, -384→-1).
pub fn fixedToI32(f: i32) i32 {
    return @divTrunc(f, 256);
}

// ============================================================================
// modifiers: the active xkb state → ModifierFlags (cmd↔Super(Mod4), alt↔Mod1, as on X11)
// ============================================================================

/// The caller passes the bools it obtained from `xkb_state_mod_name_is_active("Shift"/"Control"/"Mod1"/"Mod4")`.
pub fn modifiersFromActive(shift: bool, ctrl: bool, alt: bool, super: bool) ModifierFlags {
    return .{ .shift = shift, .ctrl = ctrl, .alt = alt, .cmd = super };
}

// ============================================================================
// scroll: wl_pointer.axis → dx/dy (the same signs and factors as X11's wheelDelta)
//
// On Wayland positive means down and right. X11's wheelDelta is up=+16/down=-16 and left=+16/right=-16,
// so both axes are negated. One notch is ±SCROLL_LINE_TO_POINTS.
// How the final signs and factors feel is confirmed on Linux hardware.
// ============================================================================

pub const ScrollDelta = struct { dx: f32 = 0, dy: f32 = 0 };

/// A discrete notch (`wl_pointer.axis_discrete`, where 1 = one notch) → a ScrollDelta.
pub fn discreteScroll(axis: u32, discrete: i32) ScrollDelta {
    const mag = @as(f32, @floatFromInt(discrete)) * SCROLL_LINE_TO_POINTS;
    return switch (axis) {
        AXIS_VERTICAL => .{ .dx = 0, .dy = -mag },
        AXIS_HORIZONTAL => .{ .dx = -mag, .dy = 0 },
        else => .{},
    };
}

/// A continuous value (the wl_fixed of `wl_pointer.axis`) → a ScrollDelta (the fallback for a compositor without discrete events).
/// The factor starts from the 1:1 of wl_fixed→point (fixed/256), and how it feels is tuned on Linux hardware.
pub fn continuousScroll(axis: u32, value_fixed: i32) ScrollDelta {
    const v = @as(f32, @floatFromInt(value_fixed)) / 256.0;
    return switch (axis) {
        AXIS_VERTICAL => .{ .dx = 0, .dy = -v },
        AXIS_HORIZONTAL => .{ .dx = -v, .dy = 0 },
        else => .{},
    };
}

/// Combine the vertical and horizontal axes within one `wl_pointer.frame` into a single scroll delta.
/// The caller adds each axis and axis_discrete, then take()s at the frame and turns it into one mouse_scroll.
pub const ScrollAccumulator = struct {
    dx: f32 = 0,
    dy: f32 = 0,
    active: bool = false,

    pub fn add(self: *ScrollAccumulator, d: ScrollDelta) void {
        self.dx += d.dx;
        self.dy += d.dy;
        self.active = true;
    }

    /// Called at the end of a frame. It returns the delta and resets when anything accumulated, and null otherwise.
    pub fn take(self: *ScrollAccumulator) ?ScrollDelta {
        if (!self.active) return null;
        const d = ScrollDelta{ .dx = self.dx, .dy = self.dy };
        self.* = .{};
        return d;
    }
};

// ============================================================================
// repeat: the timing that generates is_repeat=true, from wl_keyboard.repeat_info(rate, delay)
//
// The caller (pollEvents) passes now from getTime(). Whether a key repeats at all (modifiers do not) is
// decided by the caller through xkbcommon's xkb_keymap_key_repeats, which only then calls onKeyDown.
// ============================================================================

pub const RepeatState = struct {
    /// The X keycode (evdev+8) currently repeating. null = nothing is repeating.
    key: ?u32 = null,
    /// When the next key_down(is_repeat=true) is due (in getTime seconds).
    next: f64 = 0,
    /// repeat_info: rate (keys/sec, 0 = disabled) and delay (ms).
    rate_hz: i32 = 0,
    delay_ms: i32 = 0,

    pub fn setInfo(self: *RepeatState, rate_hz: i32, delay_ms: i32) void {
        self.rate_hz = rate_hz;
        self.delay_ms = delay_ms;
        if (rate_hz <= 0) self.key = null; // repeat disabled
    }

    /// On the press of a repeating key. The first repeat is scheduled after delay.
    pub fn onKeyDown(self: *RepeatState, key: u32, now: f64) void {
        if (self.rate_hz <= 0) {
            self.key = null;
            return;
        }
        self.key = key;
        self.next = now + @as(f64, @floatFromInt(self.delay_ms)) / 1000.0;
    }

    /// On a key release. Repeating stops once the repeating key is let go.
    pub fn onKeyUp(self: *RepeatState, key: u32) void {
        if (self.key == key) self.key = null;
    }

    /// Whether a repeat is due as of now.
    pub fn due(self: *const RepeatState, now: f64) bool {
        return self.key != null and self.rate_hz > 0 and now >= self.next;
    }

    /// After emitting one repeat, advance to the next time (relative to now, which avoids a drift burst).
    pub fn advance(self: *RepeatState, now: f64) void {
        self.next = now + 1.0 / @as(f64, @floatFromInt(self.rate_hz));
    }
};

// ============================================================================
// tests (OS independent; zig build test-platform-wayland-input)
// ============================================================================
const testing = std.testing;

test "waylandKeyToKeyCode: evdev+8 reuses the existing X11 table (independent of layout)" {
    // KEY_A=30 → X keycode 38 → .A, and KEY_Q=16 → X 24 → .Q
    try testing.expectEqual(KeyCode.A, waylandKeyToKeyCode(30));
    try testing.expectEqual(KeyCode.Q, waylandKeyToKeyCode(16));
}

test "evdevButtonToMouseButton: the BTN_* mapping" {
    try testing.expectEqual(MouseButton.left, evdevButtonToMouseButton(BTN_LEFT).?);
    try testing.expectEqual(MouseButton.right, evdevButtonToMouseButton(BTN_RIGHT).?);
    try testing.expectEqual(MouseButton.middle, evdevButtonToMouseButton(BTN_MIDDLE).?);
    try testing.expect(evdevButtonToMouseButton(0x113) == null);
    try testing.expect(evdevButtonToMouseButton(0) == null);
}

test "fixedToI32: follows wl_fixed_to_int (truncating towards zero)" {
    try testing.expectEqual(@as(i32, 0), fixedToI32(0));
    try testing.expectEqual(@as(i32, 1), fixedToI32(256));
    try testing.expectEqual(@as(i32, 1), fixedToI32(384)); // 1.5 → 1
    try testing.expectEqual(@as(i32, -1), fixedToI32(-256));
    try testing.expectEqual(@as(i32, -1), fixedToI32(-384)); // -1.5 → -1 (towards zero)
    try testing.expectEqual(@as(i32, 100), fixedToI32(25600));
}

test "modifiersFromActive: cmd↔super, alt↔mod1" {
    const m = modifiersFromActive(true, false, true, false);
    try testing.expect(m.shift and m.alt and !m.ctrl and !m.cmd);
    const s = modifiersFromActive(false, false, false, true);
    try testing.expect(s.cmd and !s.shift and !s.ctrl and !s.alt);
}

test "discreteScroll: the signs match X11 wheelDelta (down=-16, right=-16)" {
    const down = discreteScroll(AXIS_VERTICAL, 1); // on wayland, positive is down
    try testing.expectEqual(@as(f32, 0), down.dx);
    try testing.expectEqual(@as(f32, -16.0), down.dy);
    const up = discreteScroll(AXIS_VERTICAL, -1);
    try testing.expectEqual(@as(f32, 16.0), up.dy);
    const right = discreteScroll(AXIS_HORIZONTAL, 1); // on wayland, positive is right
    try testing.expectEqual(@as(f32, -16.0), right.dx);
    try testing.expectEqual(@as(f32, 0), right.dy);
}

test "continuousScroll: fixed/256 with the sign flipped" {
    const d = continuousScroll(AXIS_VERTICAL, 256); // 1.0 down
    try testing.expectEqual(@as(f32, -1.0), d.dy);
}

test "ScrollAccumulator: both axes of a frame combine into one delta, and take resets it" {
    var acc: ScrollAccumulator = .{};
    try testing.expect(acc.take() == null);
    acc.add(discreteScroll(AXIS_VERTICAL, 1)); // dy=-16
    acc.add(discreteScroll(AXIS_HORIZONTAL, 2)); // dx=-32
    const d = acc.take().?;
    try testing.expectEqual(@as(f32, -32.0), d.dx);
    try testing.expectEqual(@as(f32, -16.0), d.dy);
    try testing.expect(acc.take() == null); // take resets it
}

test "RepeatState: delay→repeat→rate progression, stopping on release, disabled at rate 0" {
    var r: RepeatState = .{};
    r.setInfo(25, 600); // 25Hz = a 0.04s interval, delay 600ms = 0.6s
    r.onKeyDown(38, 0.0);
    try testing.expect(!r.due(0.5)); // before the delay
    try testing.expect(r.due(0.6)); // the delay has passed
    r.advance(0.6);
    try testing.expect(!r.due(0.62));
    try testing.expect(r.due(0.64)); // 0.6 + 0.04
    r.onKeyUp(38);
    try testing.expect(!r.due(1.0)); // the release stops it

    r.setInfo(0, 600); // rate 0 = repeat disabled
    r.onKeyDown(38, 0.0);
    try testing.expect(!r.due(10.0));
}
