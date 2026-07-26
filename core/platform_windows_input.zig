//! The **pure translation logic** of Windows input. Pure Zig, with no `@cImport`.
//!
//! It gathers here only the translation that follows the Win32 message pump (`platform_windows.zig`,
//! Windows only) pulling out the values (the scancode, the virtual key, the wheel delta), so that it
//! can be unit tested on any host with `zig build test-platform-windows-input` (the same design as
//! X11's `platform_linux_input.zig` and Wayland's `platform_wayland_input.zig`).
//!
//! **The scancode is the primary key for a physical key** (matching the "physical position, independent of layout" approach of X11 and Wayland).
//! Bits 16-23 of WM_KEY*'s lParam are the PS/2 set 1 make code, and bit 24 is the extended (E0) flag. The
//! position of a letter, digit or symbol follows from the scancode whatever the layout. `scancodeToKeyCode`
//! leads, and only the special keys missing from that table (Pause, PrintScreen, F13 and above) fall back to
//! `vkToKeyCode` (the virtual key). There is no per-event modifier mask, so the backend reads them with `GetKeyState` (this file holds none).
//!
//! The Windows backend needs no held-key tracking of the KeyDownSet kind (GetKeyState returns the OS's own synchronised state).
//! The EventQueue and the wheel factor are OS independent and reused from `platform_linux_input.zig`.

const std = @import("std");
const types = @import("platform_types");
const linux_input = @import("platform_linux_input.zig");

const KeyCode = types.KeyCode;

// The OS-independent shared machinery is reused from the X11 implementation (as in the Wayland backend).
pub const EventQueue = linux_input.EventQueue;
pub const QUEUE_CAP = linux_input.QUEUE_CAP;
pub const WheelDelta = linux_input.WheelDelta;
/// 1 notch = ±16 points (consistent with X11's wheelDelta and macOS's SCROLL_LINE_TO_POINTS).
pub const SCROLL_LINE_TO_POINTS: f32 = linux_input.SCROLL_LINE_TO_POINTS;

// ============================================================================
// Win32 Virtual-Key Codes (the VK_* of winuser.h). They serve as the fallback for special keys missing
// from the scancode table, and for the backend's GetKeyState modifier reads. Physical keys lead through scancodeToKeyCode.
// ============================================================================
const VK_BACK: u32 = 0x08;
const VK_TAB: u32 = 0x09;
const VK_RETURN: u32 = 0x0D;
const VK_PAUSE: u32 = 0x13;
const VK_CAPITAL: u32 = 0x14;
const VK_ESCAPE: u32 = 0x1B;
const VK_SPACE: u32 = 0x20;
const VK_PRIOR: u32 = 0x21;
const VK_NEXT: u32 = 0x22;
const VK_END: u32 = 0x23;
const VK_HOME: u32 = 0x24;
const VK_LEFT: u32 = 0x25;
const VK_UP: u32 = 0x26;
const VK_RIGHT: u32 = 0x27;
const VK_DOWN: u32 = 0x28;
const VK_SNAPSHOT: u32 = 0x2C;
const VK_INSERT: u32 = 0x2D;
const VK_DELETE: u32 = 0x2E;
const VK_F1: u32 = 0x70;
const VK_F20: u32 = 0x83;

// modifier keys (left and right separately; exposed for the backend's GetKeyState and the vkToKeyCode fallback)
pub const VK_SHIFT: u32 = 0x10;
pub const VK_CONTROL: u32 = 0x11;
pub const VK_MENU: u32 = 0x12; // Alt
pub const VK_LWIN: u32 = 0x5B;
pub const VK_RWIN: u32 = 0x5C;
pub const VK_LSHIFT: u32 = 0xA0;
pub const VK_RSHIFT: u32 = 0xA1;
pub const VK_LCONTROL: u32 = 0xA2;
pub const VK_RCONTROL: u32 = 0xA3;
pub const VK_LMENU: u32 = 0xA4;
pub const VK_RMENU: u32 = 0xA5;

// ============================================================================
// a scancode (a PS/2 set 1 make code) → KeyCode (physical position, independent of layout)
// ============================================================================
//
// Bits 16-23 of lParam are the make code and bit 24 is the extended (E0) flag. A letter or digit follows from
// its physical position whatever the layout (the scancode of the 'Q' position is 0x10 on US and JIS alike).
// The table holds only keys that exist in `platform_types.KeyCode`; a symbol position, an unassigned code, and NumLock/ScrollLock (none of which are in KeyCode) all give `.UNKNOWN`.
// The extended flag tells the numpad from the editing and arrow cluster, left Ctrl/Alt from right, and KP Enter/Divide from their siblings.
pub fn scancodeToKeyCode(scancode: u32, extended: bool) KeyCode {
    if (extended) {
        // with an E0 prefix (an extended key).
        return switch (scancode) {
            0x1C => .KP_ENTER,
            0x1D => .RIGHT_CONTROL,
            0x35 => .KP_DIVIDE,
            0x37 => .PRINT_SCREEN, // E0 37 (the make of PrintScreen; the VK_SNAPSHOT route also exists, and both are handled)
            0x38 => .RIGHT_ALT, // AltGr included
            0x47 => .HOME,
            0x48 => .UP,
            0x49 => .PAGE_UP,
            0x4B => .LEFT,
            0x4D => .RIGHT,
            0x4F => .END,
            0x50 => .DOWN,
            0x51 => .PAGE_DOWN,
            0x52 => .INSERT,
            0x53 => .DELETE,
            0x5B => .LEFT_SUPER,
            0x5C => .RIGHT_SUPER,
            else => .UNKNOWN,
        };
    }
    return switch (scancode) {
        0x01 => .ESCAPE,
        // the digit row (1..9, 0)
        0x02 => .@"1",
        0x03 => .@"2",
        0x04 => .@"3",
        0x05 => .@"4",
        0x06 => .@"5",
        0x07 => .@"6",
        0x08 => .@"7",
        0x09 => .@"8",
        0x0A => .@"9",
        0x0B => .@"0",
        0x0E => .BACKSPACE,
        0x0F => .TAB,
        // the top row, QWERTYUIOP
        0x10 => .Q,
        0x11 => .W,
        0x12 => .E,
        0x13 => .R,
        0x14 => .T,
        0x15 => .Y,
        0x16 => .U,
        0x17 => .I,
        0x18 => .O,
        0x19 => .P,
        0x1C => .ENTER,
        0x1D => .LEFT_CONTROL,
        // the home row, ASDFGHJKL
        0x1E => .A,
        0x1F => .S,
        0x20 => .D,
        0x21 => .F,
        0x22 => .G,
        0x23 => .H,
        0x24 => .J,
        0x25 => .K,
        0x26 => .L,
        0x2A => .LEFT_SHIFT,
        // the bottom row, ZXCVBNM
        0x2C => .Z,
        0x2D => .X,
        0x2E => .C,
        0x2F => .V,
        0x30 => .B,
        0x31 => .N,
        0x32 => .M,
        0x36 => .RIGHT_SHIFT,
        0x37 => .KP_MULTIPLY,
        0x38 => .LEFT_ALT,
        0x39 => .SPACE,
        0x3A => .CAPS_LOCK,
        // function keys F1..F10
        0x3B => .F1,
        0x3C => .F2,
        0x3D => .F3,
        0x3E => .F4,
        0x3F => .F5,
        0x40 => .F6,
        0x41 => .F7,
        0x42 => .F8,
        0x43 => .F9,
        0x44 => .F10,
        // the numeric keypad (the physical NumLock keys)
        0x47 => .KP_7,
        0x48 => .KP_8,
        0x49 => .KP_9,
        0x4A => .KP_SUBTRACT,
        0x4B => .KP_4,
        0x4C => .KP_5,
        0x4D => .KP_6,
        0x4E => .KP_ADD,
        0x4F => .KP_1,
        0x50 => .KP_2,
        0x51 => .KP_3,
        0x52 => .KP_0,
        0x53 => .KP_DECIMAL,
        0x57 => .F11,
        0x58 => .F12,
        else => .UNKNOWN, // a symbol position, NumLock(0x45), ScrollLock(0x46) and the like are absent from KeyCode
    };
}

// ============================================================================
// VK → KeyCode (the fallback for special keys missing from the scancode table; only keys that are layout independent)
// ============================================================================
//
// When scancodeToKeyCode gives `.UNKNOWN`, the backend fills in from wParam (the virtual key). It is for
// Pause, PrintScreen, F13-F20 and the like, whose scancode is a multi-byte sequence or does not fit a one-byte
// table. Letters, digits and symbols are **left to the scancode and not handled here**, since their VK can depend on the layout (which would break the physical key contract).
pub fn vkToKeyCode(vk: u32) KeyCode {
    return switch (vk) {
        VK_PAUSE => .PAUSE,
        VK_SNAPSHOT => .PRINT_SCREEN,
        VK_CAPITAL => .CAPS_LOCK,
        VK_ESCAPE => .ESCAPE,
        VK_RETURN => .ENTER,
        VK_BACK => .BACKSPACE,
        VK_TAB => .TAB,
        VK_SPACE => .SPACE,
        VK_INSERT => .INSERT,
        VK_DELETE => .DELETE,
        VK_HOME => .HOME,
        VK_END => .END,
        VK_PRIOR => .PAGE_UP,
        VK_NEXT => .PAGE_DOWN,
        VK_UP => .UP,
        VK_DOWN => .DOWN,
        VK_LEFT => .LEFT,
        VK_RIGHT => .RIGHT,
        VK_F1...VK_F20 => @enumFromInt(@intFromEnum(KeyCode.F1) + @as(c_int, @intCast(vk - VK_F1))),
        VK_LSHIFT => .LEFT_SHIFT,
        VK_RSHIFT => .RIGHT_SHIFT,
        VK_LCONTROL => .LEFT_CONTROL,
        VK_RCONTROL => .RIGHT_CONTROL,
        VK_LMENU => .LEFT_ALT,
        VK_RMENU => .RIGHT_ALT,
        VK_LWIN => .LEFT_SUPER,
        VK_RWIN => .RIGHT_SUPER,
        else => .UNKNOWN,
    };
}

// ============================================================================
// wheel: the delta of WM_MOUSEWHEEL / WM_MOUSEHWHEEL → dx/dy
//
// A Win32 wheel delta is HIWORD(wParam) read as a signed short, and is a multiple of WHEEL_DELTA(=120).
// The signs are: WM_MOUSEWHEEL positive = forward (up), WM_MOUSEHWHEEL positive = right.
// They are brought into line with X11 and Wayland (up=+16 / down=-16 / left=+16 / right=-16), so the
// vertical delta/120*16 becomes dy as it is, and the horizontal one is negated, since right is positive.
// ============================================================================
pub const WHEEL_DELTA: i32 = 120;

/// `delta` is the signed wheel value (a multiple of WHEEL_DELTA). `horizontal=true` means WM_MOUSEHWHEEL.
pub fn wheelDelta(delta: i32, horizontal: bool) WheelDelta {
    const notches = @as(f32, @floatFromInt(delta)) / @as(f32, @floatFromInt(WHEEL_DELTA));
    const mag = notches * SCROLL_LINE_TO_POINTS;
    return if (horizontal)
        .{ .dx = -mag, .dy = 0 } // WM_MOUSEHWHEEL positive = right → right becomes negative
    else
        .{ .dx = 0, .dy = mag }; // WM_MOUSEWHEEL positive = up → up stays positive
}

/// Whether a codepoint is a committed printable character worth emitting as char_input (applied to WM_CHAR's codepoint).
/// It excludes control characters (below 0x20) and DELETE (0x7f). The same contract as platform_linux_input.isTextCodepoint.
pub fn isTextCodepoint(cp: u32) bool {
    return cp >= 0x20 and cp != 0x7f;
}

// ============================================================================
// tests (they run on any host; no Win32 needed)
// ============================================================================
const testing = std.testing;

test "isTextCodepoint: only printable characters pass" {
    try testing.expect(!isTextCodepoint(0x08)); // BS
    try testing.expect(!isTextCodepoint(0x0d)); // Enter
    try testing.expect(!isTextCodepoint(0x1b)); // ESC
    try testing.expect(!isTextCodepoint(0x7f)); // DELETE
    try testing.expect(isTextCodepoint(0x20)); // Space
    try testing.expect(isTextCodepoint('A'));
    try testing.expect(isTextCodepoint('5'));
}

test "scancodeToKeyCode: physical keys (a set 1 make code, independent of layout)" {
    // the physical positions of the top, home and bottom rows (the same scancode on US and JIS)
    try testing.expectEqual(KeyCode.Q, scancodeToKeyCode(0x10, false));
    try testing.expectEqual(KeyCode.A, scancodeToKeyCode(0x1E, false));
    try testing.expectEqual(KeyCode.Z, scancodeToKeyCode(0x2C, false));
    try testing.expectEqual(KeyCode.M, scancodeToKeyCode(0x32, false));
    // the digit row and control keys
    try testing.expectEqual(KeyCode.@"1", scancodeToKeyCode(0x02, false));
    try testing.expectEqual(KeyCode.@"0", scancodeToKeyCode(0x0B, false));
    try testing.expectEqual(KeyCode.SPACE, scancodeToKeyCode(0x39, false));
    try testing.expectEqual(KeyCode.ESCAPE, scancodeToKeyCode(0x01, false));
    try testing.expectEqual(KeyCode.ENTER, scancodeToKeyCode(0x1C, false));
    // function keys
    try testing.expectEqual(KeyCode.F1, scancodeToKeyCode(0x3B, false));
    try testing.expectEqual(KeyCode.F10, scancodeToKeyCode(0x44, false));
    try testing.expectEqual(KeyCode.F11, scancodeToKeyCode(0x57, false));
    try testing.expectEqual(KeyCode.F12, scancodeToKeyCode(0x58, false));
    // left and right modifiers are told apart by the scancode plus the extended flag
    try testing.expectEqual(KeyCode.LEFT_SHIFT, scancodeToKeyCode(0x2A, false));
    try testing.expectEqual(KeyCode.RIGHT_SHIFT, scancodeToKeyCode(0x36, false));
    try testing.expectEqual(KeyCode.LEFT_CONTROL, scancodeToKeyCode(0x1D, false));
    try testing.expectEqual(KeyCode.LEFT_ALT, scancodeToKeyCode(0x38, false));
}

test "scancodeToKeyCode: telling the numeric keypad (not extended) from the editing and arrow cluster (extended)" {
    // not extended = the numeric keypad
    try testing.expectEqual(KeyCode.KP_7, scancodeToKeyCode(0x47, false));
    try testing.expectEqual(KeyCode.KP_5, scancodeToKeyCode(0x4C, false));
    try testing.expectEqual(KeyCode.KP_0, scancodeToKeyCode(0x52, false));
    try testing.expectEqual(KeyCode.KP_DECIMAL, scancodeToKeyCode(0x53, false));
    try testing.expectEqual(KeyCode.KP_MULTIPLY, scancodeToKeyCode(0x37, false));
    // the same scancode plus extended = the editing and arrow cluster
    try testing.expectEqual(KeyCode.HOME, scancodeToKeyCode(0x47, true));
    try testing.expectEqual(KeyCode.UP, scancodeToKeyCode(0x48, true));
    try testing.expectEqual(KeyCode.LEFT, scancodeToKeyCode(0x4B, true));
    try testing.expectEqual(KeyCode.INSERT, scancodeToKeyCode(0x52, true));
    try testing.expectEqual(KeyCode.DELETE, scancodeToKeyCode(0x53, true));
    // the extended right modifiers, KP Enter and KP Divide
    try testing.expectEqual(KeyCode.RIGHT_CONTROL, scancodeToKeyCode(0x1D, true));
    try testing.expectEqual(KeyCode.RIGHT_ALT, scancodeToKeyCode(0x38, true));
    try testing.expectEqual(KeyCode.KP_ENTER, scancodeToKeyCode(0x1C, true));
    try testing.expectEqual(KeyCode.KP_DIVIDE, scancodeToKeyCode(0x35, true));
    try testing.expectEqual(KeyCode.LEFT_SUPER, scancodeToKeyCode(0x5B, true));
    // a physical key absent from KeyCode (NumLock=0x45, a symbol) is UNKNOWN
    try testing.expectEqual(KeyCode.UNKNOWN, scancodeToKeyCode(0x45, false));
    try testing.expectEqual(KeyCode.UNKNOWN, scancodeToKeyCode(0x0C, false)); // the '-' position
}

test "vkToKeyCode: the fallback for special keys missing from the scancode table" {
    try testing.expectEqual(KeyCode.PAUSE, vkToKeyCode(VK_PAUSE));
    try testing.expectEqual(KeyCode.PRINT_SCREEN, vkToKeyCode(VK_SNAPSHOT));
    try testing.expectEqual(KeyCode.F13, vkToKeyCode(0x7C));
    try testing.expectEqual(KeyCode.UP, vkToKeyCode(VK_UP));
    // a generic modifier (before it is resolved) and a letter VK are not handled here → UNKNOWN (left to the scancode)
    try testing.expectEqual(KeyCode.UNKNOWN, vkToKeyCode(VK_SHIFT));
    try testing.expectEqual(KeyCode.UNKNOWN, vkToKeyCode(0x41)); // the 'A' VK goes through the scancode
}

test "wheelDelta: the signs and factors, consistent with X11" {
    try testing.expectEqual(@as(f32, 16.0), wheelDelta(WHEEL_DELTA, false).dy);
    try testing.expectEqual(@as(f32, -16.0), wheelDelta(-WHEEL_DELTA, false).dy);
    try testing.expectEqual(@as(f32, 0.0), wheelDelta(WHEEL_DELTA, false).dx);
    try testing.expectEqual(@as(f32, -16.0), wheelDelta(WHEEL_DELTA, true).dx);
    try testing.expectEqual(@as(f32, 16.0), wheelDelta(-WHEEL_DELTA, true).dx);
    try testing.expectEqual(@as(f32, 32.0), wheelDelta(2 * WHEEL_DELTA, false).dy);
}
