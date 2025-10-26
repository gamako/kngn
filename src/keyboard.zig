//! Keyboard input module
//! キーコード定義とキー名取得機能を提供するZig標準モジュール
//! platform.hと独立して使用可能

// ============================================================================
// キーコード定義
// ============================================================================

pub const Key = struct {
    pub const UNKNOWN: i32 = -1;

    // 文字キー
    pub const SPACE: i32 = 32;
    pub const @"0": i32 = 48;
    pub const @"1": i32 = 49;
    pub const @"2": i32 = 50;
    pub const @"3": i32 = 51;
    pub const @"4": i32 = 52;
    pub const @"5": i32 = 53;
    pub const @"6": i32 = 54;
    pub const @"7": i32 = 55;
    pub const @"8": i32 = 56;
    pub const @"9": i32 = 57;

    pub const A: i32 = 65;
    pub const B: i32 = 66;
    pub const C: i32 = 67;
    pub const D: i32 = 68;
    pub const E: i32 = 69;
    pub const F: i32 = 70;
    pub const G: i32 = 71;
    pub const H: i32 = 72;
    pub const I: i32 = 73;
    pub const J: i32 = 74;
    pub const K: i32 = 75;
    pub const L: i32 = 76;
    pub const M: i32 = 77;
    pub const N: i32 = 78;
    pub const O: i32 = 79;
    pub const P: i32 = 80;
    pub const Q: i32 = 81;
    pub const R: i32 = 82;
    pub const S: i32 = 83;
    pub const T: i32 = 84;
    pub const U: i32 = 85;
    pub const V: i32 = 86;
    pub const W: i32 = 87;
    pub const X: i32 = 88;
    pub const Y: i32 = 89;
    pub const Z: i32 = 90;

    // 制御キー
    pub const ESCAPE: i32 = 256;
    pub const ENTER: i32 = 257;
    pub const TAB: i32 = 258;
    pub const BACKSPACE: i32 = 259;
    pub const INSERT: i32 = 260;
    pub const DELETE: i32 = 261;
    pub const RIGHT: i32 = 264;
    pub const LEFT: i32 = 263;
    pub const DOWN: i32 = 266;
    pub const UP: i32 = 265;
    pub const PAGE_DOWN: i32 = 268;
    pub const PAGE_UP: i32 = 267;
    pub const HOME: i32 = 269;
    pub const END: i32 = 270;

    // その他の制御キー
    pub const PRINT_SCREEN: i32 = 283;
    pub const PAUSE: i32 = 284;
    pub const CAPS_LOCK: i32 = 280;

    // ファンクションキー
    pub const F1: i32 = 290;
    pub const F2: i32 = 291;
    pub const F3: i32 = 292;
    pub const F4: i32 = 293;
    pub const F5: i32 = 294;
    pub const F6: i32 = 295;
    pub const F7: i32 = 296;
    pub const F8: i32 = 297;
    pub const F9: i32 = 298;
    pub const F10: i32 = 299;
    pub const F11: i32 = 300;
    pub const F12: i32 = 301;
    pub const F13: i32 = 302;
    pub const F14: i32 = 303;
    pub const F15: i32 = 304;
    pub const F16: i32 = 305;
    pub const F17: i32 = 306;
    pub const F18: i32 = 307;
    pub const F19: i32 = 308;
    pub const F20: i32 = 309;

    // テンキー
    pub const KP_0: i32 = 320;
    pub const KP_1: i32 = 321;
    pub const KP_2: i32 = 322;
    pub const KP_3: i32 = 323;
    pub const KP_4: i32 = 324;
    pub const KP_5: i32 = 325;
    pub const KP_6: i32 = 326;
    pub const KP_7: i32 = 327;
    pub const KP_8: i32 = 328;
    pub const KP_9: i32 = 329;
    pub const KP_DECIMAL: i32 = 330;
    pub const KP_DIVIDE: i32 = 331;
    pub const KP_MULTIPLY: i32 = 332;
    pub const KP_SUBTRACT: i32 = 333;
    pub const KP_ADD: i32 = 334;
    pub const KP_ENTER: i32 = 335;
    pub const KP_EQUAL: i32 = 336;

    // モディファイアキー
    pub const LEFT_SHIFT: i32 = 340;
    pub const LEFT_CONTROL: i32 = 341;
    pub const LEFT_ALT: i32 = 342;
    pub const LEFT_SUPER: i32 = 343;      // Command (macOS) / Windows key

    pub const RIGHT_SHIFT: i32 = 344;
    pub const RIGHT_CONTROL: i32 = 345;
    pub const RIGHT_ALT: i32 = 346;
    pub const RIGHT_SUPER: i32 = 347;     // Command (macOS) / Windows key

    // エイリアス（よく使う略記）
    pub const LEFT_CTRL: i32 = LEFT_CONTROL;
    pub const RIGHT_CTRL: i32 = RIGHT_CONTROL;
    pub const LEFT_CMD: i32 = LEFT_SUPER;
    pub const RIGHT_CMD: i32 = RIGHT_SUPER;
};

// ============================================================================
// モディファイアキー定義
// ============================================================================

pub const Modifier = struct {
    pub const SHIFT: i32 = 0x01;
    pub const CTRL: i32 = 0x02;
    pub const ALT: i32 = 0x04;
    pub const CMD: i32 = 0x08;  // macOS Command, Windows Super

    // エイリアス
    pub const CONTROL: i32 = CTRL;
    pub const COMMAND: i32 = CMD;
    pub const SUPER: i32 = CMD;
};

// ============================================================================
// キー名取得機能
// ============================================================================

/// キーコードを人間が読める文字列に変換します
///
/// Usage:
/// ```zig
/// const name = keyboard.getKeyName(Key.A);  // "A"
/// const name = keyboard.getKeyName(Key.F1); // "F1"
/// ```
pub fn getKeyName(key: i32) []const u8 {
    return switch (key) {
        // 文字キー
        Key.A...Key.Z => "LETTER",
        Key.@"0"...Key.@"9" => "DIGIT",

        // 特殊キー
        Key.SPACE => "SPACE",
        Key.ESCAPE => "ESCAPE",
        Key.TAB => "TAB",
        Key.BACKSPACE => "BACKSPACE",
        Key.INSERT => "INSERT",
        Key.DELETE => "DELETE",
        Key.ENTER => "ENTER",
        Key.PAUSE => "PAUSE",
        Key.PRINT_SCREEN => "PRINT_SCREEN",
        Key.CAPS_LOCK => "CAPS_LOCK",

        // 矢印キーとナビゲーション
        Key.LEFT => "LEFT",
        Key.RIGHT => "RIGHT",
        Key.UP => "UP",
        Key.DOWN => "DOWN",
        Key.HOME => "HOME",
        Key.END => "END",
        Key.PAGE_UP => "PAGE_UP",
        Key.PAGE_DOWN => "PAGE_DOWN",

        // ファンクションキー
        Key.F1 => "F1",
        Key.F2 => "F2",
        Key.F3 => "F3",
        Key.F4 => "F4",
        Key.F5 => "F5",
        Key.F6 => "F6",
        Key.F7 => "F7",
        Key.F8 => "F8",
        Key.F9 => "F9",
        Key.F10 => "F10",
        Key.F11 => "F11",
        Key.F12 => "F12",
        Key.F13 => "F13",
        Key.F14 => "F14",
        Key.F15 => "F15",
        Key.F16 => "F16",
        Key.F17 => "F17",
        Key.F18 => "F18",
        Key.F19 => "F19",
        Key.F20 => "F20",

        // テンキー
        Key.KP_0 => "KP_0",
        Key.KP_1 => "KP_1",
        Key.KP_2 => "KP_2",
        Key.KP_3 => "KP_3",
        Key.KP_4 => "KP_4",
        Key.KP_5 => "KP_5",
        Key.KP_6 => "KP_6",
        Key.KP_7 => "KP_7",
        Key.KP_8 => "KP_8",
        Key.KP_9 => "KP_9",
        Key.KP_DECIMAL => "KP_.",
        Key.KP_DIVIDE => "KP_/",
        Key.KP_MULTIPLY => "KP_*",
        Key.KP_SUBTRACT => "KP_-",
        Key.KP_ADD => "KP_+",
        Key.KP_ENTER => "KP_ENTER",
        Key.KP_EQUAL => "KP_=",

        // モディファイアキー
        Key.LEFT_SHIFT => "L_SHIFT",
        Key.RIGHT_SHIFT => "R_SHIFT",
        Key.LEFT_CONTROL => "L_CTRL",
        Key.RIGHT_CONTROL => "R_CTRL",
        Key.LEFT_ALT => "L_ALT",
        Key.RIGHT_ALT => "R_ALT",
        Key.LEFT_SUPER => "L_CMD",
        Key.RIGHT_SUPER => "R_CMD",

        else => "UNKNOWN",
    };
}

/// キーコードから詳細な情報を取得します
pub const KeyInfo = struct {
    code: i32,
    name: []const u8,
    is_printable: bool,
    is_modifier: bool,
    is_function: bool,
    is_numpad: bool,
};

pub fn getKeyInfo(key: i32) KeyInfo {
    const name = getKeyName(key);
    const is_printable = (key >= 32 and key <= 90) or (key >= 48 and key <= 57);
    const is_modifier = key >= 340 and key <= 347;
    const is_function = key >= 290 and key <= 309;
    const is_numpad = key >= 320 and key <= 336;

    return KeyInfo{
        .code = key,
        .name = name,
        .is_printable = is_printable,
        .is_modifier = is_modifier,
        .is_function = is_function,
        .is_numpad = is_numpad,
    };
}

// ============================================================================
// モディファイア情報の処理
// ============================================================================

/// モディファイアフラグをチェックします
pub fn hasModifier(modifiers: i32, mod: i32) bool {
    return (modifiers & mod) != 0;
}

/// モディファイアフラグから文字列表現を生成します（簡易版）
/// Usage:
/// ```zig
/// const mods = Modifier.SHIFT | Modifier.CTRL;
/// const str = keyboard.getModifierString(mods);  // "SHIFT+CTRL+"
/// ```
pub fn getModifierString(modifiers: i32, allocator: std.mem.Allocator) ![]const u8 {
    var list = std.ArrayList([]const u8).init(allocator);
    defer list.deinit();

    if (hasModifier(modifiers, Modifier.SHIFT)) {
        try list.append("SHIFT");
    }
    if (hasModifier(modifiers, Modifier.CTRL)) {
        try list.append("CTRL");
    }
    if (hasModifier(modifiers, Modifier.ALT)) {
        try list.append("ALT");
    }
    if (hasModifier(modifiers, Modifier.CMD)) {
        try list.append("CMD");
    }

    if (list.items.len == 0) {
        return "";
    }

    return try std.mem.join(allocator, "+", list.items);
}

// ============================================================================
// 数値範囲チェック
// ============================================================================

pub fn isLetterKey(key: i32) bool {
    return key >= Key.A and key <= Key.Z;
}

pub fn isDigitKey(key: i32) bool {
    return key >= Key.@"0" and key <= Key.@"9";
}

pub fn isFunctionKey(key: i32) bool {
    return key >= Key.F1 and key <= Key.F20;
}

pub fn isNumpadKey(key: i32) bool {
    return key >= Key.KP_0 and key <= Key.KP_EQUAL;
}

pub fn isModifierKey(key: i32) bool {
    return (key >= Key.LEFT_SHIFT and key <= Key.LEFT_SUPER) or
        (key >= Key.RIGHT_SHIFT and key <= Key.RIGHT_SUPER);
}

pub fn isArrowKey(key: i32) bool {
    return key == Key.LEFT or key == Key.RIGHT or
        key == Key.UP or key == Key.DOWN;
}

pub fn isNavigationKey(key: i32) bool {
    return key == Key.HOME or key == Key.END or
        key == Key.PAGE_UP or key == Key.PAGE_DOWN;
}

// ============================================================================
// 文字の取得（文字キーと数字キーから）
// ============================================================================

/// 文字キーのコードからASCII文字を取得します
pub fn getCharFromKey(key: i32) ?u8 {
    if (isLetterKey(key)) {
        return @as(u8, @intCast(key));
    }
    if (isDigitKey(key)) {
        return @as(u8, @intCast(key));
    }
    return null;
}

// 必要なインポート
const std = @import("std");
