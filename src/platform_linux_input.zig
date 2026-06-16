//! Linux/X11 入力の **純粋な変換ロジック**（TASK-28.3）。
//!
//! このファイルは `@cImport`（X11）を一切しない純 Zig。`platform_linux.zig` が `XEvent` から
//! 値（keycode / state / button / x,y）を取り出した後の変換だけを担い、`@import("platform_types")`
//! の正準型のみに依存する。これにより mapping / EventQueue / KeyDownSet を **macOS host でも単体テスト**できる。
//!
//! X の数値定数（state mask / button 番号 / evdev keycode）は ABI 安定値なのでここに直書きし、
//! 由来を `X11/X.h` / linux evdev (`input-event-codes.h`, `X keycode = evdev scancode + 8`) として明記する。

const std = @import("std");
const types = @import("platform_types.zig");

const KeyCode = types.KeyCode;
const ModifierFlags = types.ModifierFlags;
const MouseButton = types.MouseButton;
const MouseButtons = types.MouseButtons;
const Event = types.Event;

// ============================================================================
// X11 state mask（X11/X.h）。修飾の意味論は macOS と対称に揃える。
// ============================================================================
const ShiftMask: u32 = 1 << 0; // 0x01
const ControlMask: u32 = 1 << 2; // 0x04
const Mod1Mask: u32 = 1 << 3; // 0x08  Alt
const Mod4Mask: u32 = 1 << 6; // 0x40  Super（macOS の cmd に対応させる）

// ============================================================================
// evdev keycode（= linux scancode + 8）。修飾キーの左右を is_repeat / post-state 判定に使う。
// ============================================================================
const KC_CTRL_L: u32 = 37;
const KC_SHIFT_L: u32 = 50;
const KC_ALT_L: u32 = 64;
const KC_CTRL_R: u32 = 105;
const KC_ALT_R: u32 = 108; // ISO_Level3_Shift(AltGr) もここ。Alt 扱いで可
const KC_SUPER_L: u32 = 133;
const KC_SUPER_R: u32 = 134;
const KC_SHIFT_R: u32 = 62;

// ============================================================================
// keycode（物理キー・layout 非依存）→ KeyCode
// ============================================================================
//
// KeySym は layout 依存なので使わない。evdev keymap 前提（Xorg / Xvfb は xkb+evdev）で
// `X keycode = evdev scancode + 8`。`platform_types.KeyCode` に存在し evdev に標準割当のあるキーを網羅し、
// 表に無い keycode は `.UNKNOWN`（非 evdev サーバや未割当キー）。
pub fn keycodeToKeyCode(keycode: u32) KeyCode {
    return switch (keycode) {
        // --- 英字（物理位置基準。QWERTY 配列の keycode）---
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
        // --- 数字列 ---
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
        // --- 制御・編集 ---
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
        // --- 矢印 ---
        111 => .UP,
        116 => .DOWN,
        113 => .LEFT,
        114 => .RIGHT,
        // --- ファンクション ---
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
        // --- テンキー（NumLock 物理キー）---
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
        // --- 修飾キー（左右別）---
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
// X state mask → ModifierFlags（cmd ↔ Super(Mod4), alt ↔ Mod1）
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

/// keycode がどの修飾に属するか（左右いずれも同じ修飾）。修飾でなければ null。
fn modifierOf(keycode: u32) ?Mod {
    return switch (keycode) {
        KC_SHIFT_L, KC_SHIFT_R => .shift,
        KC_CTRL_L, KC_CTRL_R => .ctrl,
        KC_ALT_L, KC_ALT_R => .alt,
        KC_SUPER_L, KC_SUPER_R => .cmd,
        else => null,
    };
}

/// key event 用の修飾（post-state）。X の `state` は「イベント直前」なので、修飾キー自身の
/// 押下/解放では当該ビットがずれる。`keys`（当該 event 反映後の KeyDownSet）を真として、
/// **この keycode が属する修飾の 1 ビットだけ**「左右いずれかが down なら true」で上書きする。
/// 左右同時押し・最後の 1 個解放も正しい。event に無関係な修飾は state mask（focus 前の保持も拾える）を使う。
pub fn keyEventModifiers(state: u32, keys: *const KeyDownSet, keycode: u32) ModifierFlags {
    var m = stateToModifiers(state);
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
// mouse button / wheel
// ============================================================================

/// X button 番号 → MouseButton（1=left, 2=middle, 3=right）。wheel(4-7) 等は null。
/// 注: X の番号と enum 値は異なる（middle が X=2 だが enum=2、right が X=3 だが enum=1）。
pub fn buttonToMouseButton(button: u32) ?MouseButton {
    return switch (button) {
        1 => .left,
        2 => .middle,
        3 => .right,
        else => null,
    };
}

pub const WheelDelta = struct { dx: f32, dy: f32 };

/// X wheel button(4=up,5=down,6=left,7=right) → ScrollEvent の dx,dy。それ以外は null。
/// macOS の非 precise(line) scroll = deltaY(±1) × SCROLL_LINE_TO_POINTS(=16) に揃え 1 notch=±16。
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
// KeyDownSet: keycode(0..255) の押下集合（is_repeat / 修飾 post-state 判定に使う）
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
// EventQueue: 固定リング + macOS と同じ coalesce（mouse_move / mouse_scroll）+ drop カウント
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
        // 末尾合体（macOS backend と同一意味論）
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
// tests（host でも回る。X 不要）
// ============================================================================
const testing = std.testing;

test "keycodeToKeyCode: 物理キー基準（evdev keycode）" {
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
    // 未割当 / 範囲外 → UNKNOWN
    try testing.expectEqual(KeyCode.UNKNOWN, keycodeToKeyCode(8));
    try testing.expectEqual(KeyCode.UNKNOWN, keycodeToKeyCode(250));
}

test "stateToModifiers: cmd↔Mod4, alt↔Mod1" {
    const m = stateToModifiers(ShiftMask | ControlMask | Mod1Mask | Mod4Mask);
    try testing.expect(m.shift and m.ctrl and m.alt and m.cmd);
    const none = stateToModifiers(0);
    try testing.expect(!none.shift and !none.ctrl and !none.alt and !none.cmd);
    // Mod2(NumLock)/Lock(Caps) は無視する
    const ignored = stateToModifiers((1 << 1) | (1 << 4));
    try testing.expect(!ignored.shift and !ignored.ctrl and !ignored.alt and !ignored.cmd);
}

test "keyEventModifiers: 修飾キー自身の post-state（左右同時押し）" {
    var keys = KeyDownSet{};
    // Left Shift 押下: state はまだ shift=0（pre-state）。down set 反映後に true になる。
    keys.setDown(KC_SHIFT_L, true);
    var m = keyEventModifiers(0, &keys, KC_SHIFT_L);
    try testing.expect(m.shift);

    // Left を押したまま Right Shift も押下 → 両方 down。
    keys.setDown(KC_SHIFT_R, true);
    m = keyEventModifiers(ShiftMask, &keys, KC_SHIFT_R);
    try testing.expect(m.shift);

    // Right Shift を離す（Left はまだ down）→ shift は true のまま（AND-NOT なら誤って false になるケース）。
    keys.setDown(KC_SHIFT_R, false);
    m = keyEventModifiers(ShiftMask, &keys, KC_SHIFT_R);
    try testing.expect(m.shift);

    // 最後に Left Shift も離す → shift=false。
    keys.setDown(KC_SHIFT_L, false);
    m = keyEventModifiers(ShiftMask, &keys, KC_SHIFT_L);
    try testing.expect(!m.shift);
}

test "keyEventModifiers: 無関係な修飾は state mask を保持" {
    var keys = KeyDownSet{};
    keys.setDown(38, true); // 'A' を押下（修飾でない）
    // Ctrl が state に立っている（focus 前から保持していた想定）→ A の event でも ctrl を維持。
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

test "KeyDownSet: set/clear/isDown（境界）" {
    var s = KeyDownSet{};
    try testing.expect(!s.isDown(0));
    s.setDown(0, true);
    s.setDown(63, true);
    s.setDown(64, true);
    s.setDown(255, true);
    try testing.expect(s.isDown(0) and s.isDown(63) and s.isDown(64) and s.isDown(255));
    s.setDown(64, false);
    try testing.expect(!s.isDown(64) and s.isDown(63));
    s.setDown(256, true); // 範囲外は no-op
    try testing.expect(!s.isDown(256));
}

test "EventQueue: mouse_move 合体（同 buttons/modifiers）" {
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

test "EventQueue: 異なる buttons は合体しない" {
    var q = EventQueue{};
    q.enqueue(.{ .mouse_move = .{ .x = 1, .y = 1, .button = .none, .buttons = .{}, .modifiers = .{} } });
    q.enqueue(.{ .mouse_move = .{ .x = 2, .y = 2, .button = .none, .buttons = .{ .left = true }, .modifiers = .{} } });
    try testing.expectEqual(@as(usize, 2), q.len);
    try testing.expectEqual(@as(u64, 0), q.mouse_move_merge_count);
}

test "EventQueue: mouse_scroll 合体は dx/dy 加算" {
    var q = EventQueue{};
    q.enqueue(.{ .mouse_scroll = .{ .x = 0, .y = 0, .dx = 0, .dy = 16, .is_precise = false, .buttons = .{}, .modifiers = .{} } });
    q.enqueue(.{ .mouse_scroll = .{ .x = 5, .y = 5, .dx = 0, .dy = 16, .is_precise = false, .buttons = .{}, .modifiers = .{} } });
    try testing.expectEqual(@as(usize, 1), q.len);
    try testing.expectEqual(@as(u64, 1), q.mouse_scroll_merge_count);
    const ev = q.dequeue().?;
    try testing.expectEqual(@as(f32, 32.0), ev.mouse_scroll.dy);
    try testing.expectEqual(@as(i32, 5), ev.mouse_scroll.x);
}

test "EventQueue: 異種イベントは合体しない / FIFO 順" {
    var q = EventQueue{};
    q.enqueue(.quit);
    q.enqueue(.{ .mouse_move = .{ .x = 1, .y = 1, .button = .none, .buttons = .{}, .modifiers = .{} } });
    q.enqueue(.{ .mouse_move = .{ .x = 2, .y = 2, .button = .none, .buttons = .{}, .modifiers = .{} } });
    // quit と move は別、move 同士は合体 → 2 件
    try testing.expectEqual(@as(usize, 2), q.len);
    try testing.expect(q.dequeue().? == .quit);
    try testing.expectEqual(@as(i32, 2), q.dequeue().?.mouse_move.x);
    try testing.expect(q.dequeue() == null);
}

test "EventQueue: 満杯で drop カウント" {
    var q = EventQueue{};
    // 合体されない別種（key_down, keycode を変えて）で満たす
    var i: usize = 0;
    while (i < QUEUE_CAP) : (i += 1) {
        q.enqueue(.{ .key_down = .{ .key = .A, .is_repeat = false, .modifiers = .{} } });
    }
    try testing.expectEqual(@as(usize, QUEUE_CAP), q.len);
    q.enqueue(.{ .key_down = .{ .key = .B, .is_repeat = false, .modifiers = .{} } });
    try testing.expectEqual(@as(usize, QUEUE_CAP), q.len);
    try testing.expectEqual(@as(u64, 1), q.event_drop_count);
}
