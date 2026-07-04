//! Windows 入力の **純粋な変換ロジック**（TASK-31）。`@cImport` しない純 Zig。
//!
//! Win32 のメッセージポンプ本体（`platform_windows.zig`、Windows 専用）から値（scancode / virtual
//! key / wheel delta）を取り出した後の変換だけをここに集約し、任意の host で
//! `zig build test-platform-windows-input` で単体テストできるようにする
//! （X11 の `platform_linux_input.zig` / Wayland の `platform_wayland_input.zig` と同じ設計）。
//!
//! **物理キーは scancode を主キーにする**（X11/Wayland の「物理位置・layout 非依存」方針に揃える）。
//! WM_KEY* の lParam bits16-23 が PS/2 set1 の make code。bit24 が拡張(E0)フラグ。英字/数字/記号位置は
//! layout に依らず scancode で決まる。`scancodeToKeyCode` を主とし、scancode 表に無い特殊キー（Pause /
//! PrintScreen / F13+ 等）だけ `vkToKeyCode`（virtual key）に fallback する。修飾は per-event mask が
//! 無いので backend が `GetKeyState` で読む（このファイルは保持しない）。
//!
//! KeyDownSet 相当の押下追跡は Windows backend では使わない（GetKeyState が OS 同期状態を返すため）。
//! EventQueue / wheel 係数は OS 非依存なので `platform_linux_input.zig` を再利用する。

const std = @import("std");
const types = @import("platform_types");
const linux_input = @import("platform_linux_input.zig");

const KeyCode = types.KeyCode;

// OS 非依存の共通機構は X11 実装から再利用（Wayland backend と同方針）。
pub const EventQueue = linux_input.EventQueue;
pub const QUEUE_CAP = linux_input.QUEUE_CAP;
pub const WheelDelta = linux_input.WheelDelta;
/// 1 notch = ±16 point（X11 wheelDelta / macOS SCROLL_LINE_TO_POINTS に整合）。
pub const SCROLL_LINE_TO_POINTS: f32 = linux_input.SCROLL_LINE_TO_POINTS;

// ============================================================================
// Win32 Virtual-Key Codes（winuser.h の VK_*）。scancode 表に無い特殊キーの fallback と、
// backend の GetKeyState 修飾読み取りに使う。物理キー本線は scancodeToKeyCode。
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

// 修飾キー（左右別。backend の GetKeyState / vkToKeyCode fallback 用に公開）
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
// scancode（PS/2 set1 make code）→ KeyCode（物理位置・layout 非依存）
// ============================================================================
//
// lParam bits16-23 が make code、bit24 が拡張(E0)フラグ。英字/数字は配列に依らず物理位置で決まる
// （US でも JIS でも 'Q' 位置の scancode は 0x10）。`platform_types.KeyCode` に在るキーのみ表に持ち、
// 記号位置（KeyCode に無い）や未割当・NumLock/ScrollLock（KeyCode に無い）は `.UNKNOWN` を返す。
// 拡張フラグは numpad と編集/矢印クラスタ、左右 Ctrl/Alt、KP Enter/Divide の判別に使う。
pub fn scancodeToKeyCode(scancode: u32, extended: bool) KeyCode {
    if (extended) {
        // E0 プレフィックス付き（拡張キー）。
        return switch (scancode) {
            0x1C => .KP_ENTER,
            0x1D => .RIGHT_CONTROL,
            0x35 => .KP_DIVIDE,
            0x37 => .PRINT_SCREEN, // E0 37（PrintScreen の make。VK_SNAPSHOT 経路もあるが両対応）
            0x38 => .RIGHT_ALT, // AltGr 含む
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
        // 数字列（1..9,0）
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
        // 上段 QWERTYUIOP
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
        // 中段 ASDFGHJKL
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
        // 下段 ZXCVBNM
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
        // ファンクション F1..F10
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
        // テンキー（NumLock 物理キー）
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
        else => .UNKNOWN, // 記号位置 / NumLock(0x45) / ScrollLock(0x46) 等は KeyCode に無い
    };
}

// ============================================================================
// VK → KeyCode（scancode 表に無い特殊キーの fallback。layout 非依存な特殊キーのみ）
// ============================================================================
//
// scancodeToKeyCode が `.UNKNOWN` のとき backend が wParam(virtual key) で補う。Pause / PrintScreen /
// F13-F20 等、scancode が多バイト列だったり 1 バイト表に収まらないキー向け。英字/数字/記号は
// VK が layout 依存になりうるので **ここでは扱わず scancode に委ねる**（物理キー契約を壊さないため）。
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
// wheel: WM_MOUSEWHEEL / WM_MOUSEHWHEEL の delta → dx/dy
//
// Win32 の wheel delta は HIWORD(wParam) を signed short にした値で WHEEL_DELTA(=120) の倍数。
// 符号は WM_MOUSEWHEEL: 正 = forward(up)、WM_MOUSEHWHEEL: 正 = right。
// X11/Wayland と符号を揃える: up=+16 / down=-16 / left=+16 / right=-16。
// → 縦は delta/120*16 をそのまま dy、横は right(正) を負にするため符号反転。
// ============================================================================
pub const WHEEL_DELTA: i32 = 120;

/// `delta` は signed wheel 値（WHEEL_DELTA の倍数）。`horizontal=true` で WM_MOUSEHWHEEL。
pub fn wheelDelta(delta: i32, horizontal: bool) WheelDelta {
    const notches = @as(f32, @floatFromInt(delta)) / @as(f32, @floatFromInt(WHEEL_DELTA));
    const mag = notches * SCROLL_LINE_TO_POINTS;
    return if (horizontal)
        .{ .dx = -mag, .dy = 0 } // WM_MOUSEHWHEEL 正=right → 右は負
    else
        .{ .dx = 0, .dy = mag }; // WM_MOUSEWHEEL 正=up → 上は正
}

// ============================================================================
// tests（任意 host で回る。Win32 不要）
// ============================================================================
const testing = std.testing;

test "scancodeToKeyCode: 物理キー（set1 make code・layout 非依存）" {
    // 上段/中段/下段の物理位置（US でも JIS でも同 scancode）
    try testing.expectEqual(KeyCode.Q, scancodeToKeyCode(0x10, false));
    try testing.expectEqual(KeyCode.A, scancodeToKeyCode(0x1E, false));
    try testing.expectEqual(KeyCode.Z, scancodeToKeyCode(0x2C, false));
    try testing.expectEqual(KeyCode.M, scancodeToKeyCode(0x32, false));
    // 数字列・制御
    try testing.expectEqual(KeyCode.@"1", scancodeToKeyCode(0x02, false));
    try testing.expectEqual(KeyCode.@"0", scancodeToKeyCode(0x0B, false));
    try testing.expectEqual(KeyCode.SPACE, scancodeToKeyCode(0x39, false));
    try testing.expectEqual(KeyCode.ESCAPE, scancodeToKeyCode(0x01, false));
    try testing.expectEqual(KeyCode.ENTER, scancodeToKeyCode(0x1C, false));
    // ファンクション
    try testing.expectEqual(KeyCode.F1, scancodeToKeyCode(0x3B, false));
    try testing.expectEqual(KeyCode.F10, scancodeToKeyCode(0x44, false));
    try testing.expectEqual(KeyCode.F11, scancodeToKeyCode(0x57, false));
    try testing.expectEqual(KeyCode.F12, scancodeToKeyCode(0x58, false));
    // 左右修飾は scancode/拡張で判別
    try testing.expectEqual(KeyCode.LEFT_SHIFT, scancodeToKeyCode(0x2A, false));
    try testing.expectEqual(KeyCode.RIGHT_SHIFT, scancodeToKeyCode(0x36, false));
    try testing.expectEqual(KeyCode.LEFT_CONTROL, scancodeToKeyCode(0x1D, false));
    try testing.expectEqual(KeyCode.LEFT_ALT, scancodeToKeyCode(0x38, false));
}

test "scancodeToKeyCode: テンキー（非拡張）と編集/矢印（拡張）の判別" {
    // 非拡張 = テンキー
    try testing.expectEqual(KeyCode.KP_7, scancodeToKeyCode(0x47, false));
    try testing.expectEqual(KeyCode.KP_5, scancodeToKeyCode(0x4C, false));
    try testing.expectEqual(KeyCode.KP_0, scancodeToKeyCode(0x52, false));
    try testing.expectEqual(KeyCode.KP_DECIMAL, scancodeToKeyCode(0x53, false));
    try testing.expectEqual(KeyCode.KP_MULTIPLY, scancodeToKeyCode(0x37, false));
    // 同じ scancode + 拡張 = 編集/矢印クラスタ
    try testing.expectEqual(KeyCode.HOME, scancodeToKeyCode(0x47, true));
    try testing.expectEqual(KeyCode.UP, scancodeToKeyCode(0x48, true));
    try testing.expectEqual(KeyCode.LEFT, scancodeToKeyCode(0x4B, true));
    try testing.expectEqual(KeyCode.INSERT, scancodeToKeyCode(0x52, true));
    try testing.expectEqual(KeyCode.DELETE, scancodeToKeyCode(0x53, true));
    // 拡張の右修飾 / KP Enter / KP Divide
    try testing.expectEqual(KeyCode.RIGHT_CONTROL, scancodeToKeyCode(0x1D, true));
    try testing.expectEqual(KeyCode.RIGHT_ALT, scancodeToKeyCode(0x38, true));
    try testing.expectEqual(KeyCode.KP_ENTER, scancodeToKeyCode(0x1C, true));
    try testing.expectEqual(KeyCode.KP_DIVIDE, scancodeToKeyCode(0x35, true));
    try testing.expectEqual(KeyCode.LEFT_SUPER, scancodeToKeyCode(0x5B, true));
    // KeyCode に無い物理キー（NumLock=0x45 / 記号）は UNKNOWN
    try testing.expectEqual(KeyCode.UNKNOWN, scancodeToKeyCode(0x45, false));
    try testing.expectEqual(KeyCode.UNKNOWN, scancodeToKeyCode(0x0C, false)); // '-' 位置
}

test "vkToKeyCode: scancode 表に無い特殊キーの fallback" {
    try testing.expectEqual(KeyCode.PAUSE, vkToKeyCode(VK_PAUSE));
    try testing.expectEqual(KeyCode.PRINT_SCREEN, vkToKeyCode(VK_SNAPSHOT));
    try testing.expectEqual(KeyCode.F13, vkToKeyCode(0x7C));
    try testing.expectEqual(KeyCode.UP, vkToKeyCode(VK_UP));
    // generic 修飾（解決前）や英字 VK はここでは扱わない → UNKNOWN（scancode に委ねる）
    try testing.expectEqual(KeyCode.UNKNOWN, vkToKeyCode(VK_SHIFT));
    try testing.expectEqual(KeyCode.UNKNOWN, vkToKeyCode(0x41)); // 'A' VK は scancode 側で
}

test "wheelDelta: 符号・係数（X11 と整合）" {
    try testing.expectEqual(@as(f32, 16.0), wheelDelta(WHEEL_DELTA, false).dy);
    try testing.expectEqual(@as(f32, -16.0), wheelDelta(-WHEEL_DELTA, false).dy);
    try testing.expectEqual(@as(f32, 0.0), wheelDelta(WHEEL_DELTA, false).dx);
    try testing.expectEqual(@as(f32, -16.0), wheelDelta(WHEEL_DELTA, true).dx);
    try testing.expectEqual(@as(f32, 16.0), wheelDelta(-WHEEL_DELTA, true).dx);
    try testing.expectEqual(@as(f32, 32.0), wheelDelta(2 * WHEEL_DELTA, false).dy);
}
