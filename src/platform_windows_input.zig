//! Windows 入力の **純粋な変換ロジック**（TASK-31）。`@cImport` しない純 Zig。
//!
//! Win32 のメッセージポンプ本体（`platform_windows.zig`、Windows 専用）から値
//! （virtual key code / wheel delta / button）を取り出した後の変換だけをここに集約し、
//! 任意の host で `zig build test-platform-windows-input` で単体テストできるようにする
//! （X11 の `platform_linux_input.zig` / Wayland の `platform_wayland_input.zig` と同じ設計）。
//!
//! KeyDownSet / EventQueue / wheel の係数は OS 非依存なので `platform_linux_input.zig` を再利用し
//! （Wayland backend と同じ）、Windows 固有の差分（VK → KeyCode / 修飾の左右解決 / WM_MOUSEWHEEL の
//! 符号）のみ本ファイルが担う。
//!
//! VK 定数は Win32 ABI 安定値（`winuser.h` の `VK_*`）なのでここに直書きし、由来を併記する。

const std = @import("std");
const types = @import("platform_types.zig");
const linux_input = @import("platform_linux_input.zig");

const KeyCode = types.KeyCode;
const ModifierFlags = types.ModifierFlags;
const MouseButton = types.MouseButton;

// OS 非依存の共通機構は X11 実装から再利用（Wayland backend と同じ方針）。
pub const KeyDownSet = linux_input.KeyDownSet;
pub const EventQueue = linux_input.EventQueue;
pub const QUEUE_CAP = linux_input.QUEUE_CAP;
pub const WheelDelta = linux_input.WheelDelta;
/// 1 notch = ±16 point（X11 wheelDelta / macOS SCROLL_LINE_TO_POINTS に整合）。
pub const SCROLL_LINE_TO_POINTS: f32 = linux_input.SCROLL_LINE_TO_POINTS;

// ============================================================================
// Win32 Virtual-Key Codes（winuser.h の VK_*）。物理キー解決は backend が行い、ここは VK → KeyCode。
// ============================================================================
const VK_BACK: u32 = 0x08;
const VK_TAB: u32 = 0x09;
const VK_RETURN: u32 = 0x0D;
const VK_PAUSE: u32 = 0x13;
const VK_CAPITAL: u32 = 0x14; // Caps Lock
const VK_ESCAPE: u32 = 0x1B;
const VK_SPACE: u32 = 0x20;
const VK_PRIOR: u32 = 0x21; // Page Up
const VK_NEXT: u32 = 0x22; // Page Down
const VK_END: u32 = 0x23;
const VK_HOME: u32 = 0x24;
const VK_LEFT: u32 = 0x25;
const VK_UP: u32 = 0x26;
const VK_RIGHT: u32 = 0x27;
const VK_DOWN: u32 = 0x28;
const VK_SNAPSHOT: u32 = 0x2C; // Print Screen
const VK_INSERT: u32 = 0x2D;
const VK_DELETE: u32 = 0x2E;
const VK_LWIN: u32 = 0x5B;
const VK_RWIN: u32 = 0x5C;
const VK_NUMPAD0: u32 = 0x60;
const VK_NUMPAD9: u32 = 0x69;
const VK_MULTIPLY: u32 = 0x6A;
const VK_ADD: u32 = 0x6B;
const VK_SEPARATOR: u32 = 0x6C;
const VK_SUBTRACT: u32 = 0x6D;
const VK_DECIMAL: u32 = 0x6E;
const VK_DIVIDE: u32 = 0x6F;
const VK_F1: u32 = 0x70;
const VK_F20: u32 = 0x83;

// 修飾キー（左右別。backend が generic VK_SHIFT/CONTROL/MENU を scancode / 拡張ビットで左右へ解決してから渡す）
pub const VK_LSHIFT: u32 = 0xA0;
pub const VK_RSHIFT: u32 = 0xA1;
pub const VK_LCONTROL: u32 = 0xA2;
pub const VK_RCONTROL: u32 = 0xA3;
pub const VK_LMENU: u32 = 0xA4; // 左 Alt
pub const VK_RMENU: u32 = 0xA5; // 右 Alt（AltGr もここ。Alt 扱いで可）

// generic 修飾（解決前。backend で左右へ解決するため通常 vkToKeyCode には渡らない）
pub const VK_SHIFT: u32 = 0x10;
pub const VK_CONTROL: u32 = 0x11;
pub const VK_MENU: u32 = 0x12;

// ============================================================================
// VK → KeyCode（物理キー。layout 非依存）
// ============================================================================
//
// 英字 / 数字は VK が ASCII 大文字・数字に一致し KeyCode 値とも一致するが、明示 switch で網羅する
// （non-exhaustive enum の取り違えを防ぎ、表として読めるようにする）。修飾キーは左右別 VK を前提
// （generic VK_SHIFT 等は backend が解決済みのはず。未解決で来た場合は .UNKNOWN）。
pub fn vkToKeyCode(vk: u32) KeyCode {
    return switch (vk) {
        // --- 英字（'A'..'Z' = 0x41..0x5A）---
        0x41 => .A,
        0x42 => .B,
        0x43 => .C,
        0x44 => .D,
        0x45 => .E,
        0x46 => .F,
        0x47 => .G,
        0x48 => .H,
        0x49 => .I,
        0x4A => .J,
        0x4B => .K,
        0x4C => .L,
        0x4D => .M,
        0x4E => .N,
        0x4F => .O,
        0x50 => .P,
        0x51 => .Q,
        0x52 => .R,
        0x53 => .S,
        0x54 => .T,
        0x55 => .U,
        0x56 => .V,
        0x57 => .W,
        0x58 => .X,
        0x59 => .Y,
        0x5A => .Z,
        // --- 数字列（'0'..'9' = 0x30..0x39）---
        0x30 => .@"0",
        0x31 => .@"1",
        0x32 => .@"2",
        0x33 => .@"3",
        0x34 => .@"4",
        0x35 => .@"5",
        0x36 => .@"6",
        0x37 => .@"7",
        0x38 => .@"8",
        0x39 => .@"9",
        // --- 制御・編集 ---
        VK_SPACE => .SPACE,
        VK_RETURN => .ENTER,
        VK_TAB => .TAB,
        VK_BACK => .BACKSPACE,
        VK_ESCAPE => .ESCAPE,
        VK_INSERT => .INSERT,
        VK_DELETE => .DELETE,
        VK_HOME => .HOME,
        VK_END => .END,
        VK_PRIOR => .PAGE_UP,
        VK_NEXT => .PAGE_DOWN,
        VK_CAPITAL => .CAPS_LOCK,
        VK_SNAPSHOT => .PRINT_SCREEN,
        VK_PAUSE => .PAUSE,
        // --- 矢印 ---
        VK_UP => .UP,
        VK_DOWN => .DOWN,
        VK_LEFT => .LEFT,
        VK_RIGHT => .RIGHT,
        // --- ファンクション（F1..F20 = 0x70..0x83 連番）---
        VK_F1...VK_F20 => @enumFromInt(@intFromEnum(KeyCode.F1) + @as(c_int, @intCast(vk - VK_F1))),
        // --- テンキー（NumLock 物理キー。VK_NUMPAD0..9 = 0x60..0x69 連番）---
        VK_NUMPAD0...VK_NUMPAD9 => @enumFromInt(@intFromEnum(KeyCode.KP_0) + @as(c_int, @intCast(vk - VK_NUMPAD0))),
        VK_DECIMAL => .KP_DECIMAL,
        VK_DIVIDE => .KP_DIVIDE,
        VK_MULTIPLY => .KP_MULTIPLY,
        VK_SUBTRACT => .KP_SUBTRACT,
        VK_ADD => .KP_ADD,
        VK_SEPARATOR => .KP_ENTER, // テンキー Enter（VK_RETURN+拡張ビットで来る場合は backend が VK_SEPARATOR に正規化）
        // --- 修飾キー（左右別。backend が解決済み）---
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
// 修飾 ModifierFlags（Windows は per-event の modifier mask が無いので KeyDownSet（post-state）から算出）
// ============================================================================
//
// X11 の `keyEventModifiers`（pre-state mask + 左右 override）と違い、Windows は WM_KEY* に修飾 mask が
// 載らない。backend が当該 event を反映した後の KeyDownSet（VK で索引）から「左右いずれか down」で
// 全修飾を組み立てる。これで修飾キー自身の押下/解放・左右同時押し・最後の 1 個解放まで正しい。
// cmd は Windows キー（VK_LWIN/RWIN）に対応させる（X11 の Super↔cmd と対称）。
pub fn modifiersFromKeys(keys: *const KeyDownSet) ModifierFlags {
    return .{
        .shift = keys.isDown(VK_LSHIFT) or keys.isDown(VK_RSHIFT),
        .ctrl = keys.isDown(VK_LCONTROL) or keys.isDown(VK_RCONTROL),
        .alt = keys.isDown(VK_LMENU) or keys.isDown(VK_RMENU),
        .cmd = keys.isDown(VK_LWIN) or keys.isDown(VK_RWIN),
    };
}

/// generic 修飾 VK（VK_SHIFT/CONTROL/MENU）か。backend は true のとき scancode / 拡張ビットで
/// 左右の VK_L*/VK_R* へ解決してから KeyDownSet 更新・vkToKeyCode に渡す。
pub fn isGenericModifier(vk: u32) bool {
    return vk == VK_SHIFT or vk == VK_CONTROL or vk == VK_MENU;
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

test "vkToKeyCode: 英字・数字（VK == ASCII）" {
    try testing.expectEqual(KeyCode.A, vkToKeyCode(0x41));
    try testing.expectEqual(KeyCode.Z, vkToKeyCode(0x5A));
    try testing.expectEqual(KeyCode.Q, vkToKeyCode(0x51));
    try testing.expectEqual(KeyCode.@"0", vkToKeyCode(0x30));
    try testing.expectEqual(KeyCode.@"9", vkToKeyCode(0x39));
}

test "vkToKeyCode: 制御・矢印・編集" {
    try testing.expectEqual(KeyCode.SPACE, vkToKeyCode(VK_SPACE));
    try testing.expectEqual(KeyCode.ENTER, vkToKeyCode(VK_RETURN));
    try testing.expectEqual(KeyCode.ESCAPE, vkToKeyCode(VK_ESCAPE));
    try testing.expectEqual(KeyCode.BACKSPACE, vkToKeyCode(VK_BACK));
    try testing.expectEqual(KeyCode.TAB, vkToKeyCode(VK_TAB));
    try testing.expectEqual(KeyCode.UP, vkToKeyCode(VK_UP));
    try testing.expectEqual(KeyCode.LEFT, vkToKeyCode(VK_LEFT));
    try testing.expectEqual(KeyCode.PAGE_UP, vkToKeyCode(VK_PRIOR));
    try testing.expectEqual(KeyCode.DELETE, vkToKeyCode(VK_DELETE));
    try testing.expectEqual(KeyCode.CAPS_LOCK, vkToKeyCode(VK_CAPITAL));
}

test "vkToKeyCode: ファンクション・テンキー（連番）" {
    try testing.expectEqual(KeyCode.F1, vkToKeyCode(VK_F1));
    try testing.expectEqual(KeyCode.F12, vkToKeyCode(0x7B));
    try testing.expectEqual(KeyCode.F20, vkToKeyCode(VK_F20));
    try testing.expectEqual(KeyCode.KP_0, vkToKeyCode(VK_NUMPAD0));
    try testing.expectEqual(KeyCode.KP_5, vkToKeyCode(0x65));
    try testing.expectEqual(KeyCode.KP_9, vkToKeyCode(VK_NUMPAD9));
    try testing.expectEqual(KeyCode.KP_ADD, vkToKeyCode(VK_ADD));
    try testing.expectEqual(KeyCode.KP_DIVIDE, vkToKeyCode(VK_DIVIDE));
    try testing.expectEqual(KeyCode.KP_ENTER, vkToKeyCode(VK_SEPARATOR));
}

test "vkToKeyCode: 修飾キー（左右別）と未割当" {
    try testing.expectEqual(KeyCode.LEFT_SHIFT, vkToKeyCode(VK_LSHIFT));
    try testing.expectEqual(KeyCode.RIGHT_SHIFT, vkToKeyCode(VK_RSHIFT));
    try testing.expectEqual(KeyCode.LEFT_CONTROL, vkToKeyCode(VK_LCONTROL));
    try testing.expectEqual(KeyCode.RIGHT_ALT, vkToKeyCode(VK_RMENU));
    try testing.expectEqual(KeyCode.LEFT_SUPER, vkToKeyCode(VK_LWIN));
    // generic 修飾は解決前なので KeyCode に対応せず UNKNOWN（backend が左右へ解決する契約）
    try testing.expectEqual(KeyCode.UNKNOWN, vkToKeyCode(VK_SHIFT));
    try testing.expectEqual(KeyCode.UNKNOWN, vkToKeyCode(0x07)); // 未割当
    try testing.expect(isGenericModifier(VK_SHIFT));
    try testing.expect(isGenericModifier(VK_MENU));
    try testing.expect(!isGenericModifier(VK_LSHIFT));
}

test "modifiersFromKeys: 左右いずれか down で立つ（post-state）" {
    var keys = KeyDownSet{};
    var m = modifiersFromKeys(&keys);
    try testing.expect(!m.shift and !m.ctrl and !m.alt and !m.cmd);

    keys.setDown(VK_LSHIFT, true);
    m = modifiersFromKeys(&keys);
    try testing.expect(m.shift);

    // 右 Shift も押す → 立ったまま。左を離しても右が down なら維持。
    keys.setDown(VK_RSHIFT, true);
    keys.setDown(VK_LSHIFT, false);
    m = modifiersFromKeys(&keys);
    try testing.expect(m.shift);

    // 最後の 1 個（右）を離す → false
    keys.setDown(VK_RSHIFT, false);
    m = modifiersFromKeys(&keys);
    try testing.expect(!m.shift);

    // ctrl / alt / cmd（Win キー）
    keys.setDown(VK_RCONTROL, true);
    keys.setDown(VK_LMENU, true);
    keys.setDown(VK_LWIN, true);
    m = modifiersFromKeys(&keys);
    try testing.expect(m.ctrl and m.alt and m.cmd and !m.shift);
}

test "wheelDelta: 符号・係数（X11 と整合）" {
    // 縦: 正=up=+16, 負=down=-16
    try testing.expectEqual(@as(f32, 16.0), wheelDelta(WHEEL_DELTA, false).dy);
    try testing.expectEqual(@as(f32, -16.0), wheelDelta(-WHEEL_DELTA, false).dy);
    try testing.expectEqual(@as(f32, 0.0), wheelDelta(WHEEL_DELTA, false).dx);
    // 横: 正=right=-16, 負=left=+16
    try testing.expectEqual(@as(f32, -16.0), wheelDelta(WHEEL_DELTA, true).dx);
    try testing.expectEqual(@as(f32, 16.0), wheelDelta(-WHEEL_DELTA, true).dx);
    // 2 notch
    try testing.expectEqual(@as(f32, 32.0), wheelDelta(2 * WHEEL_DELTA, false).dy);
}
