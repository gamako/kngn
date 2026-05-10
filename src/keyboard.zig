//! Keyboard utility module
//!
//! `platform.KeyCode` enum に対するヘルパー関数（キー名取得・分類・文字変換）。
//! KeyCode 型自体は `platform.zig` で定義されており、ここではそれを再 export する。

const std = @import("std");
const platform = @import("platform");

pub const KeyCode = platform.KeyCode;

/// キーコードを人間が読める文字列に変換します。
/// 文字キー（A-Z）と数字キー（0-9）は実際の文字を返します。
pub fn getKeyName(key: KeyCode) []const u8 {
    if (isLetterKey(key)) {
        const letter_names = [_][]const u8{
            "A", "B", "C", "D", "E", "F", "G", "H", "I", "J",
            "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T",
            "U", "V", "W", "X", "Y", "Z",
        };
        const idx: usize = @intCast(@intFromEnum(key) - @intFromEnum(KeyCode.A));
        return letter_names[idx];
    }
    if (isDigitKey(key)) {
        const digit_names = [_][]const u8{
            "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
        };
        const idx: usize = @intCast(@intFromEnum(key) - @intFromEnum(KeyCode.@"0"));
        return digit_names[idx];
    }

    return switch (key) {
        .SPACE => "SPACE",
        .ESCAPE => "ESCAPE",
        .TAB => "TAB",
        .BACKSPACE => "BACKSPACE",
        .INSERT => "INSERT",
        .DELETE => "DELETE",
        .ENTER => "ENTER",
        .PAUSE => "PAUSE",
        .PRINT_SCREEN => "PRINT_SCREEN",
        .CAPS_LOCK => "CAPS_LOCK",

        .LEFT => "LEFT",
        .RIGHT => "RIGHT",
        .UP => "UP",
        .DOWN => "DOWN",
        .HOME => "HOME",
        .END => "END",
        .PAGE_UP => "PAGE_UP",
        .PAGE_DOWN => "PAGE_DOWN",

        .F1 => "F1", .F2 => "F2", .F3 => "F3", .F4 => "F4", .F5 => "F5",
        .F6 => "F6", .F7 => "F7", .F8 => "F8", .F9 => "F9", .F10 => "F10",
        .F11 => "F11", .F12 => "F12", .F13 => "F13", .F14 => "F14", .F15 => "F15",
        .F16 => "F16", .F17 => "F17", .F18 => "F18", .F19 => "F19", .F20 => "F20",

        .KP_0 => "KP_0", .KP_1 => "KP_1", .KP_2 => "KP_2", .KP_3 => "KP_3",
        .KP_4 => "KP_4", .KP_5 => "KP_5", .KP_6 => "KP_6", .KP_7 => "KP_7",
        .KP_8 => "KP_8", .KP_9 => "KP_9",
        .KP_DECIMAL => "KP_.",
        .KP_DIVIDE => "KP_/",
        .KP_MULTIPLY => "KP_*",
        .KP_SUBTRACT => "KP_-",
        .KP_ADD => "KP_+",
        .KP_ENTER => "KP_ENTER",
        .KP_EQUAL => "KP_=",

        .LEFT_SHIFT => "L_SHIFT",
        .RIGHT_SHIFT => "R_SHIFT",
        .LEFT_CONTROL => "L_CTRL",
        .RIGHT_CONTROL => "R_CTRL",
        .LEFT_ALT => "L_ALT",
        .RIGHT_ALT => "R_ALT",
        .LEFT_SUPER => "L_CMD",
        .RIGHT_SUPER => "R_CMD",

        else => "UNKNOWN",
    };
}

pub const KeyInfo = struct {
    code: c_int,
    name: []const u8,
    is_printable: bool,
    is_modifier: bool,
    is_function: bool,
    is_numpad: bool,
};

pub fn getKeyInfo(key: KeyCode) KeyInfo {
    const code = @intFromEnum(key);
    const name = getKeyName(key);
    // KeyCode に列挙されている範囲では SPACE / A-Z / 0-9 のみが printable
    // （`!"#$%`... 等の記号は KeyCode に存在しない）
    const is_printable = key == .SPACE or isLetterKey(key) or isDigitKey(key);

    return KeyInfo{
        .code = code,
        .name = name,
        .is_printable = is_printable,
        .is_modifier = isModifierKey(key),
        .is_function = isFunctionKey(key),
        .is_numpad = isNumpadKey(key),
    };
}

pub fn isLetterKey(key: KeyCode) bool {
    const code = @intFromEnum(key);
    return code >= @intFromEnum(KeyCode.A) and code <= @intFromEnum(KeyCode.Z);
}

pub fn isDigitKey(key: KeyCode) bool {
    const code = @intFromEnum(key);
    return code >= @intFromEnum(KeyCode.@"0") and code <= @intFromEnum(KeyCode.@"9");
}

pub fn isFunctionKey(key: KeyCode) bool {
    const code = @intFromEnum(key);
    return code >= @intFromEnum(KeyCode.F1) and code <= @intFromEnum(KeyCode.F20);
}

pub fn isNumpadKey(key: KeyCode) bool {
    const code = @intFromEnum(key);
    return code >= @intFromEnum(KeyCode.KP_0) and code <= @intFromEnum(KeyCode.KP_EQUAL);
}

pub fn isModifierKey(key: KeyCode) bool {
    const code = @intFromEnum(key);
    return code >= @intFromEnum(KeyCode.LEFT_SHIFT) and code <= @intFromEnum(KeyCode.RIGHT_SUPER);
}

pub fn isArrowKey(key: KeyCode) bool {
    return switch (key) {
        .LEFT, .RIGHT, .UP, .DOWN => true,
        else => false,
    };
}

pub fn isNavigationKey(key: KeyCode) bool {
    return switch (key) {
        .HOME, .END, .PAGE_UP, .PAGE_DOWN => true,
        else => false,
    };
}

/// 文字キー (A-Z) / 数字キー (0-9) からASCII文字を取得します
pub fn getCharFromKey(key: KeyCode) ?u8 {
    if (isLetterKey(key) or isDigitKey(key)) {
        return @intCast(@intFromEnum(key));
    }
    return null;
}
