//! The **pure translation logic** of Linux/X11 input.
//!
//! This file does no `@cImport` (X11) at all: it is pure Zig. `platform_linux.zig` pulls the values
//! (keycode, state, button, x and y) out of an `XEvent`, and this file handles only the translation that
//! follows, depending on nothing but the canonical types in `@import("platform_types")`. That is what makes the mapping, the EventQueue and the KeyDownSet **unit testable on a macOS host**.
//!
//! The numeric X constants (the state mask, the button numbers, the evdev keycodes) are ABI-stable values,
//! so they are written out here with their origin stated: `X11/X.h`, and linux evdev (`input-event-codes.h`, where `X keycode = evdev scancode + 8`).

const std = @import("std");
const types = @import("platform_types");

const KeyCode = types.KeyCode;
const ModifierFlags = types.ModifierFlags;
const MouseButton = types.MouseButton;
const MouseButtons = types.MouseButtons;
const Event = types.Event;

// ============================================================================
// The X11 state mask (X11/X.h). The meaning of a modifier is kept symmetrical with macOS.
// ============================================================================
const ShiftMask: u32 = 1 << 0; // 0x01
const ControlMask: u32 = 1 << 2; // 0x04
const Mod1Mask: u32 = 1 << 3; // 0x08  Alt
const Mod4Mask: u32 = 1 << 6; // 0x40  Super (mapped onto macOS's cmd)

// ============================================================================
// evdev keycodes (= a linux scancode + 8). Left and right modifiers are told apart for is_repeat and the post-state.
// ============================================================================
const KC_CTRL_L: u32 = 37;
const KC_SHIFT_L: u32 = 50;
const KC_ALT_L: u32 = 64;
const KC_CTRL_R: u32 = 105;
const KC_ALT_R: u32 = 108; // ISO_Level3_Shift (AltGr) is here too. Treating it as Alt is fine
const KC_SUPER_L: u32 = 133;
const KC_SUPER_R: u32 = 134;
const KC_SHIFT_R: u32 = 62;

// ============================================================================
// keycode (a physical key, independent of layout) → KeyCode
// ============================================================================
//
// A KeySym depends on the layout and is not used. An evdev keymap is assumed (Xorg and Xvfb use xkb+evdev),
// where `X keycode = evdev scancode + 8`. The table covers every key that exists in `platform_types.KeyCode`
// and has a standard evdev assignment; a keycode not in it is `.UNKNOWN` (a non-evdev server, or an unassigned key).
pub fn keycodeToKeyCode(keycode: u32) KeyCode {
    return switch (keycode) {
        // --- letters (by physical position: the keycodes of a QWERTY layout) ---
        38 => .A,
        56 => .B,
        54 => .C,
        40 => .D,
        26 => .E,
        41 => .F,
        42 => .G,
        43 => .H,
        31 => .I,
        44 => .J,
        45 => .K,
        46 => .L,
        58 => .M,
        57 => .N,
        32 => .O,
        33 => .P,
        24 => .Q,
        27 => .R,
        39 => .S,
        28 => .T,
        30 => .U,
        55 => .V,
        25 => .W,
        53 => .X,
        29 => .Y,
        52 => .Z,
        // --- the digit row ---
        10 => .@"1",
        11 => .@"2",
        12 => .@"3",
        13 => .@"4",
        14 => .@"5",
        15 => .@"6",
        16 => .@"7",
        17 => .@"8",
        18 => .@"9",
        19 => .@"0",
        // --- control and editing ---
        65 => .SPACE,
        36 => .ENTER,
        23 => .TAB,
        22 => .BACKSPACE,
        9 => .ESCAPE,
        118 => .INSERT,
        119 => .DELETE,
        110 => .HOME,
        115 => .END,
        112 => .PAGE_UP,
        117 => .PAGE_DOWN,
        66 => .CAPS_LOCK,
        107 => .PRINT_SCREEN,
        127 => .PAUSE,
        // --- arrows ---
        111 => .UP,
        116 => .DOWN,
        113 => .LEFT,
        114 => .RIGHT,
        // --- function keys ---
        67 => .F1,
        68 => .F2,
        69 => .F3,
        70 => .F4,
        71 => .F5,
        72 => .F6,
        73 => .F7,
        74 => .F8,
        75 => .F9,
        76 => .F10,
        95 => .F11,
        96 => .F12,
        191 => .F13,
        192 => .F14,
        193 => .F15,
        194 => .F16,
        195 => .F17,
        196 => .F18,
        197 => .F19,
        198 => .F20,
        // --- the numeric keypad (the physical NumLock keys) ---
        90 => .KP_0,
        87 => .KP_1,
        88 => .KP_2,
        89 => .KP_3,
        83 => .KP_4,
        84 => .KP_5,
        85 => .KP_6,
        79 => .KP_7,
        80 => .KP_8,
        81 => .KP_9,
        91 => .KP_DECIMAL,
        106 => .KP_DIVIDE,
        63 => .KP_MULTIPLY,
        82 => .KP_SUBTRACT,
        86 => .KP_ADD,
        104 => .KP_ENTER,
        125 => .KP_EQUAL,
        // --- modifiers (left and right separately) ---
        KC_SHIFT_L => .LEFT_SHIFT,
        KC_CTRL_L => .LEFT_CONTROL,
        KC_ALT_L => .LEFT_ALT,
        KC_SUPER_L => .LEFT_SUPER,
        KC_SHIFT_R => .RIGHT_SHIFT,
        KC_CTRL_R => .RIGHT_CONTROL,
        KC_ALT_R => .RIGHT_ALT,
        KC_SUPER_R => .RIGHT_SUPER,
        else => .UNKNOWN,
    };
}

// ============================================================================
// The X state mask → ModifierFlags (cmd ↔ Super(Mod4), alt ↔ Mod1)
// ============================================================================
pub fn stateToModifiers(state: u32) ModifierFlags {
    return .{
        .shift = (state & ShiftMask) != 0,
        .ctrl = (state & ControlMask) != 0,
        .alt = (state & Mod1Mask) != 0,
        .cmd = (state & Mod4Mask) != 0,
    };
}

const Mod = enum { shift, ctrl, alt, cmd };

/// Which modifier a keycode belongs to (left and right give the same modifier). null when it is not a modifier.
fn modifierOf(keycode: u32) ?Mod {
    return switch (keycode) {
        KC_SHIFT_L, KC_SHIFT_R => .shift,
        KC_CTRL_L, KC_CTRL_R => .ctrl,
        KC_ALT_L, KC_ALT_R => .alt,
        KC_SUPER_L, KC_SUPER_R => .cmd,
        else => null,
    };
}

/// The modifiers of a key event (the post-state). X's `state` is the state *before* the event, so pressing
/// or releasing a modifier key itself leaves its own bit out of step. Taking `keys` (the KeyDownSet with this
/// event already applied) as the truth, **only the one bit of the modifier this keycode belongs to** is overwritten with "true when either side is down".
/// Both sides held at once, and the release of the last one, come out right. A modifier unrelated to the event keeps the state mask (which also picks up what was held before focus).
pub fn keyEventModifiers(state: u32, keys: *const KeyDownSet, keycode: u32) ModifierFlags {
    return overrideModifierBit(stateToModifiers(state), keys, keycode);
}

/// Given a base modifier (from the state mask on X11, from xkb on Wayland), when this keycode is a modifier
/// key, correct the post-state by overwriting just that one bit with "either side down" from the KeyDownSet (with this event already applied).
/// It absorbs the modifier being out of step across a press or release of the modifier key itself (both sides at once included).
/// The keycode is in the X keycode space (on Wayland, evdev+8).
pub fn overrideModifierBit(base: ModifierFlags, keys: *const KeyDownSet, keycode: u32) ModifierFlags {
    var m = base;
    const which = modifierOf(keycode) orelse return m;
    switch (which) {
        .shift => m.shift = keys.isDown(KC_SHIFT_L) or keys.isDown(KC_SHIFT_R),
        .ctrl => m.ctrl = keys.isDown(KC_CTRL_L) or keys.isDown(KC_CTRL_R),
        .alt => m.alt = keys.isDown(KC_ALT_L) or keys.isDown(KC_ALT_R),
        .cmd => m.cmd = keys.isDown(KC_SUPER_L) or keys.isDown(KC_SUPER_R),
    }
    return m;
}

// ============================================================================
// the char_input codepoint filter
// ============================================================================

/// Whether a codepoint is a committed printable character worth emitting as char_input (applied alike to
/// what x11's XLookupString and wayland's xkb_state_key_get_utf32 return). It excludes control characters
/// (below 0x20), DELETE (0x7f) and 0 (a key that carries no character). An IME and marked text are out of scope here (a committed alphanumeric character is assumed).
pub fn isTextCodepoint(cp: u32) bool {
    return cp >= 0x20 and cp != 0x7f;
}

test "isTextCodepoint: only printable characters pass" {
    try std.testing.expect(!isTextCodepoint(0)); // a key with no character
    try std.testing.expect(!isTextCodepoint(0x08)); // BS
    try std.testing.expect(!isTextCodepoint(0x0d)); // Enter
    try std.testing.expect(!isTextCodepoint(0x1b)); // ESC
    try std.testing.expect(!isTextCodepoint(0x7f)); // DELETE
    try std.testing.expect(isTextCodepoint(0x20)); // Space
    try std.testing.expect(isTextCodepoint('A'));
    try std.testing.expect(isTextCodepoint('5'));
    try std.testing.expect(isTextCodepoint(0x3042)); // a Japanese character
}

// ============================================================================
// mouse button / wheel
// ============================================================================

/// An X button number → MouseButton (1=left, 2=middle, 3=right). A wheel (4-7) and the rest give null.
/// Note: the X numbers and the enum values differ (middle is X=2 and enum=2, but right is X=3 and enum=1).
pub fn buttonToMouseButton(button: u32) ?MouseButton {
    return switch (button) {
        1 => .left,
        2 => .middle,
        3 => .right,
        else => null,
    };
}

pub const WheelDelta = struct { dx: f32, dy: f32 };

/// An X wheel button (4=up, 5=down, 6=left, 7=right) → the dx and dy of a ScrollEvent. Anything else is null.
/// One notch is ±16, matching macOS's non-precise (line) scroll = deltaY(±1) × SCROLL_LINE_TO_POINTS(=16).
pub const SCROLL_LINE_TO_POINTS: f32 = 16.0;
pub fn wheelDelta(button: u32) ?WheelDelta {
    return switch (button) {
        4 => .{ .dx = 0, .dy = SCROLL_LINE_TO_POINTS },
        5 => .{ .dx = 0, .dy = -SCROLL_LINE_TO_POINTS },
        6 => .{ .dx = SCROLL_LINE_TO_POINTS, .dy = 0 },
        7 => .{ .dx = -SCROLL_LINE_TO_POINTS, .dy = 0 },
        else => null,
    };
}

// ============================================================================
// KeyDownSet: the set of held keycodes (0..255), used for is_repeat and the modifier post-state
// ============================================================================
pub const KeyDownSet = struct {
    bits: [4]u64 = .{ 0, 0, 0, 0 },

    pub fn setDown(self: *KeyDownSet, keycode: u32, down: bool) void {
        if (keycode >= 256) return;
        const w = keycode >> 6;
        const bit = @as(u64, 1) << @intCast(keycode & 63);
        if (down) self.bits[w] |= bit else self.bits[w] &= ~bit;
    }

    pub fn isDown(self: *const KeyDownSet, keycode: u32) bool {
        if (keycode >= 256) return false;
        return (self.bits[keycode >> 6] & (@as(u64, 1) << @intCast(keycode & 63))) != 0;
    }
};

// ============================================================================
// EventQueue: a fixed ring plus the same coalescing as macOS (mouse_move and mouse_scroll) plus a drop count
// ============================================================================
pub const QUEUE_CAP = 256;

fn modsEql(a: ModifierFlags, b: ModifierFlags) bool {
    return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
}
fn btnsEql(a: MouseButtons, b: MouseButtons) bool {
    return @as(u8, @bitCast(a)) == @as(u8, @bitCast(b));
}

pub const EventQueue = struct {
    buf: [QUEUE_CAP]Event = undefined,
    head: usize = 0,
    len: usize = 0,
    mouse_move_merge_count: u64 = 0,
    mouse_scroll_merge_count: u64 = 0,
    event_drop_count: u64 = 0,

    fn tailPtr(self: *EventQueue) ?*Event {
        if (self.len == 0) return null;
        return &self.buf[(self.head + self.len - 1) % QUEUE_CAP];
    }

    pub fn enqueue(self: *EventQueue, ev: Event) void {
        // merged into the tail (the same semantics as the macOS backend)
        if (self.tailPtr()) |t| {
            switch (ev) {
                .mouse_move => |m| if (std.meta.activeTag(t.*) == .mouse_move) {
                    const tm = t.mouse_move;
                    if (btnsEql(tm.buttons, m.buttons) and modsEql(tm.modifiers, m.modifiers)) {
                        t.mouse_move.x = m.x;
                        t.mouse_move.y = m.y;
                        self.mouse_move_merge_count += 1;
                        return;
                    }
                },
                .mouse_scroll => |s| if (std.meta.activeTag(t.*) == .mouse_scroll) {
                    const ts = t.mouse_scroll;
                    if (ts.is_precise == s.is_precise and btnsEql(ts.buttons, s.buttons) and modsEql(ts.modifiers, s.modifiers)) {
                        t.mouse_scroll.x = s.x;
                        t.mouse_scroll.y = s.y;
                        t.mouse_scroll.dx += s.dx;
                        t.mouse_scroll.dy += s.dy;
                        self.mouse_scroll_merge_count += 1;
                        return;
                    }
                },
                else => {},
            }
        }
        if (self.len >= QUEUE_CAP) {
            self.event_drop_count += 1;
            return;
        }
        self.buf[(self.head + self.len) % QUEUE_CAP] = ev;
        self.len += 1;
    }

    pub fn dequeue(self: *EventQueue) ?Event {
        if (self.len == 0) return null;
        const ev = self.buf[self.head];
        self.head = (self.head + 1) % QUEUE_CAP;
        self.len -= 1;
        return ev;
    }
};

// ============================================================================
// tests (they run on a host too; no X needed)
// ============================================================================
const testing = std.testing;

test "keycodeToKeyCode: by physical key (an evdev keycode)" {
    try testing.expectEqual(KeyCode.Q, keycodeToKeyCode(24));
    try testing.expectEqual(KeyCode.A, keycodeToKeyCode(38));
    try testing.expectEqual(KeyCode.Z, keycodeToKeyCode(52));
    try testing.expectEqual(KeyCode.@"1", keycodeToKeyCode(10));
    try testing.expectEqual(KeyCode.@"0", keycodeToKeyCode(19));
    try testing.expectEqual(KeyCode.SPACE, keycodeToKeyCode(65));
    try testing.expectEqual(KeyCode.ESCAPE, keycodeToKeyCode(9));
    try testing.expectEqual(KeyCode.UP, keycodeToKeyCode(111));
    try testing.expectEqual(KeyCode.LEFT_SHIFT, keycodeToKeyCode(50));
    try testing.expectEqual(KeyCode.RIGHT_SHIFT, keycodeToKeyCode(62));
    try testing.expectEqual(KeyCode.F12, keycodeToKeyCode(96));
    try testing.expectEqual(KeyCode.KP_5, keycodeToKeyCode(84));
    // unassigned or out of range → UNKNOWN
    try testing.expectEqual(KeyCode.UNKNOWN, keycodeToKeyCode(8));
    try testing.expectEqual(KeyCode.UNKNOWN, keycodeToKeyCode(250));
}

test "stateToModifiers: cmd↔Mod4, alt↔Mod1" {
    const m = stateToModifiers(ShiftMask | ControlMask | Mod1Mask | Mod4Mask);
    try testing.expect(m.shift and m.ctrl and m.alt and m.cmd);
    const none = stateToModifiers(0);
    try testing.expect(!none.shift and !none.ctrl and !none.alt and !none.cmd);
    // Mod2 (NumLock) and Lock (Caps) are ignored
    const ignored = stateToModifiers((1 << 1) | (1 << 4));
    try testing.expect(!ignored.shift and !ignored.ctrl and !ignored.alt and !ignored.cmd);
}

test "keyEventModifiers: the post-state of a modifier key itself (both sides held at once)" {
    var keys = KeyDownSet{};
    // Left Shift pressed: state still has shift=0 (the pre-state). It becomes true once the down set is applied.
    keys.setDown(KC_SHIFT_L, true);
    var m = keyEventModifiers(0, &keys, KC_SHIFT_L);
    try testing.expect(m.shift);

    // Right Shift pressed while Left is still held → both are down.
    keys.setDown(KC_SHIFT_R, true);
    m = keyEventModifiers(ShiftMask, &keys, KC_SHIFT_R);
    try testing.expect(m.shift);

    // Right Shift released (Left still down) → shift stays true (an AND-NOT would wrongly make it false here).
    keys.setDown(KC_SHIFT_R, false);
    m = keyEventModifiers(ShiftMask, &keys, KC_SHIFT_R);
    try testing.expect(m.shift);

    // Finally Left Shift is released too → shift=false.
    keys.setDown(KC_SHIFT_L, false);
    m = keyEventModifiers(ShiftMask, &keys, KC_SHIFT_L);
    try testing.expect(!m.shift);
}

test "keyEventModifiers: an unrelated modifier keeps the state mask" {
    var keys = KeyDownSet{};
    keys.setDown(38, true); // 'A' pressed (not a modifier)
    // Ctrl is set in state (held since before focus, say) → the A event keeps ctrl.
    const m = keyEventModifiers(ControlMask, &keys, 38);
    try testing.expect(m.ctrl and !m.shift);
}

test "buttonToMouseButton / wheelDelta" {
    try testing.expectEqual(MouseButton.left, buttonToMouseButton(1).?);
    try testing.expectEqual(MouseButton.middle, buttonToMouseButton(2).?);
    try testing.expectEqual(MouseButton.right, buttonToMouseButton(3).?);
    try testing.expect(buttonToMouseButton(4) == null);

    try testing.expectEqual(@as(f32, 16.0), wheelDelta(4).?.dy);
    try testing.expectEqual(@as(f32, -16.0), wheelDelta(5).?.dy);
    try testing.expectEqual(@as(f32, 16.0), wheelDelta(6).?.dx);
    try testing.expectEqual(@as(f32, -16.0), wheelDelta(7).?.dx);
    try testing.expect(wheelDelta(1) == null);
}

test "KeyDownSet: set/clear/isDown at the boundaries" {
    var s = KeyDownSet{};
    try testing.expect(!s.isDown(0));
    s.setDown(0, true);
    s.setDown(63, true);
    s.setDown(64, true);
    s.setDown(255, true);
    try testing.expect(s.isDown(0) and s.isDown(63) and s.isDown(64) and s.isDown(255));
    s.setDown(64, false);
    try testing.expect(!s.isDown(64) and s.isDown(63));
    s.setDown(256, true); // out of range is a no-op
    try testing.expect(!s.isDown(256));
}

test "EventQueue: mouse_move merges when buttons and modifiers match" {
    var q = EventQueue{};
    const base = types.MouseEvent{ .x = 1, .y = 1, .button = .none, .buttons = .{}, .modifiers = .{} };
    q.enqueue(.{ .mouse_move = base });
    q.enqueue(.{ .mouse_move = .{ .x = 2, .y = 3, .button = .none, .buttons = .{}, .modifiers = .{} } });
    try testing.expectEqual(@as(usize, 1), q.len);
    try testing.expectEqual(@as(u64, 1), q.mouse_move_merge_count);
    const ev = q.dequeue().?;
    try testing.expectEqual(@as(i32, 2), ev.mouse_move.x);
    try testing.expectEqual(@as(i32, 3), ev.mouse_move.y);
}

test "EventQueue: different buttons do not merge" {
    var q = EventQueue{};
    q.enqueue(.{ .mouse_move = .{ .x = 1, .y = 1, .button = .none, .buttons = .{}, .modifiers = .{} } });
    q.enqueue(.{ .mouse_move = .{ .x = 2, .y = 2, .button = .none, .buttons = .{ .left = true }, .modifiers = .{} } });
    try testing.expectEqual(@as(usize, 2), q.len);
    try testing.expectEqual(@as(u64, 0), q.mouse_move_merge_count);
}

test "EventQueue: merging mouse_scroll adds up dx and dy" {
    var q = EventQueue{};
    q.enqueue(.{ .mouse_scroll = .{ .x = 0, .y = 0, .dx = 0, .dy = 16, .is_precise = false, .buttons = .{}, .modifiers = .{} } });
    q.enqueue(.{ .mouse_scroll = .{ .x = 5, .y = 5, .dx = 0, .dy = 16, .is_precise = false, .buttons = .{}, .modifiers = .{} } });
    try testing.expectEqual(@as(usize, 1), q.len);
    try testing.expectEqual(@as(u64, 1), q.mouse_scroll_merge_count);
    const ev = q.dequeue().?;
    try testing.expectEqual(@as(f32, 32.0), ev.mouse_scroll.dy);
    try testing.expectEqual(@as(i32, 5), ev.mouse_scroll.x);
}

test "EventQueue: events of different kinds do not merge, and the order is FIFO" {
    var q = EventQueue{};
    q.enqueue(.quit);
    q.enqueue(.{ .mouse_move = .{ .x = 1, .y = 1, .button = .none, .buttons = .{}, .modifiers = .{} } });
    q.enqueue(.{ .mouse_move = .{ .x = 2, .y = 2, .button = .none, .buttons = .{}, .modifiers = .{} } });
    // quit and move are distinct, two moves merge → 2 entries
    try testing.expectEqual(@as(usize, 2), q.len);
    try testing.expect(q.dequeue().? == .quit);
    try testing.expectEqual(@as(i32, 2), q.dequeue().?.mouse_move.x);
    try testing.expect(q.dequeue() == null);
}

test "EventQueue: a full queue counts a drop" {
    var q = EventQueue{};
    // filled with a different kind that does not merge (key_down, with a different keycode)
    var i: usize = 0;
    while (i < QUEUE_CAP) : (i += 1) {
        q.enqueue(.{ .key_down = .{ .key = .A, .is_repeat = false, .modifiers = .{} } });
    }
    try testing.expectEqual(@as(usize, QUEUE_CAP), q.len);
    q.enqueue(.{ .key_down = .{ .key = .B, .is_repeat = false, .modifiers = .{} } });
    try testing.expectEqual(@as(usize, QUEUE_CAP), q.len);
    try testing.expectEqual(@as(u64, 1), q.event_drop_count);
}
