//! Keyboard utility module
//!
//! `platform_types.KeyCode` enum に対するヘルパー関数（キー名取得・分類・文字変換）。
//! KeyCode 型自体は `core/platform_types.zig` が単一ソース。libs/gfx は type-only core のみ参照する
//! （ADR-007: libs → type-only core。platform facade 実装には依存しない）。

const std = @import("std");
const platform_types = @import("platform_types");

pub const KeyCode = platform_types.KeyCode;

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

        .F1 => "F1",
        .F2 => "F2",
        .F3 => "F3",
        .F4 => "F4",
        .F5 => "F5",
        .F6 => "F6",
        .F7 => "F7",
        .F8 => "F8",
        .F9 => "F9",
        .F10 => "F10",
        .F11 => "F11",
        .F12 => "F12",
        .F13 => "F13",
        .F14 => "F14",
        .F15 => "F15",
        .F16 => "F16",
        .F17 => "F17",
        .F18 => "F18",
        .F19 => "F19",
        .F20 => "F20",

        .KP_0 => "KP_0",
        .KP_1 => "KP_1",
        .KP_2 => "KP_2",
        .KP_3 => "KP_3",
        .KP_4 => "KP_4",
        .KP_5 => "KP_5",
        .KP_6 => "KP_6",
        .KP_7 => "KP_7",
        .KP_8 => "KP_8",
        .KP_9 => "KP_9",
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

// ============================================================================
// KeyboardState — 押下集合 + 前後フレーム差分エッジ（TASK-111.7）
// ============================================================================

/// キー押下集合を保持し、`isDown` / `justPressed` / `justReleased` を提供する。
///
/// エッジ判定は `src/gamepad.zig` の `justPressed`/`justReleased` と同型で、
/// **前後フレームの最終押下集合の差分**のみを見る。
///
/// 使い方（毎フレーム）:
/// ```
/// state.beginFrame(); // 前フレーム集合を保存
/// // イベント処理中:
/// state.keyDown(key); // / keyUp(key)
/// // 更新/描画:
/// if (state.justPressed(.SPACE)) { ... }
/// if (state.isDown(.LEFT_SHIFT)) { ... }
/// ```
///
/// ## 同一フレーム内 down→up の transient edge 非保持
///
/// 同一フレームで `keyDown(A)` 直後に `keyUp(A)` した場合、フレーム終端の
/// current / previous はどちらも A を含まないため、`justPressed(A)` も
/// `justReleased(A)` も **false** のまま（edge を蓄積しない）。
/// GUI の `keys_pressed` エッジ蓄積とは意味論が異なる点に注意。
///
/// 修飾キー（LEFT_SHIFT 等）も `KeyCode` として同じ集合で扱う。
/// `KeyCode.UNKNOWN` および負値のキーは集合に入れない（`keyDown`/`keyUp` で無視）。
///
/// ホットパス: イベント時の線形探索 + フレーム毎 `O(押下キー数)` の集合コピー。
/// 全画素・RT ループ無し。初回容量確保後は `clearRetainingCapacity` で再確保しない。
pub const KeyboardState = struct {
    alloc: std.mem.Allocator,
    current: std.ArrayList(KeyCode) = .empty,
    previous: std.ArrayList(KeyCode) = .empty,

    pub fn init(alloc: std.mem.Allocator) KeyboardState {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *KeyboardState) void {
        self.current.deinit(self.alloc);
        self.previous.deinit(self.alloc);
        self.* = undefined;
    }

    /// フレーム冒頭で呼ぶ。現フレーム開始時点の押下集合を previous に保存する。
    /// current はそのまま維持し、以降の keyDown/keyUp で更新する。
    pub fn beginFrame(self: *KeyboardState) void {
        self.previous.clearRetainingCapacity();
        self.previous.appendSlice(self.alloc, self.current.items) catch @panic("KeyboardState.beginFrame: OOM");
    }

    /// キーを押下集合に追加する（重複は無視。key repeat 相当の二重登録を防ぐ）。
    /// 負値 / UNKNOWN は無視。
    /// previous の容量もここ（イベント時）で同時確保し、beginFrame のフレーム毎
    /// appendSlice が再確保しないことを保証する（codex レビュー対応。無割当は
    /// FailingAllocator テストで固定）。
    pub fn keyDown(self: *KeyboardState, key: KeyCode) void {
        if (!isTrackable(key)) return;
        if (listContains(self.current.items, key)) return;
        self.current.append(self.alloc, key) catch @panic("KeyboardState.keyDown: OOM");
        self.previous.ensureTotalCapacity(self.alloc, self.current.items.len) catch @panic("KeyboardState.keyDown: OOM");
    }

    /// キーを押下集合から除去する。未押下・負値 / UNKNOWN は no-op。
    pub fn keyUp(self: *KeyboardState, key: KeyCode) void {
        if (!isTrackable(key)) return;
        removeFirst(&self.current, key);
    }

    pub fn isDown(self: *const KeyboardState, key: KeyCode) bool {
        return listContains(self.current.items, key);
    }

    /// 前フレーム非押下 → 今フレーム押下。
    pub fn justPressed(self: *const KeyboardState, key: KeyCode) bool {
        return listContains(self.current.items, key) and !listContains(self.previous.items, key);
    }

    /// 前フレーム押下 → 今フレーム非押下。
    pub fn justReleased(self: *const KeyboardState, key: KeyCode) bool {
        return listContains(self.previous.items, key) and !listContains(self.current.items, key);
    }

    fn isTrackable(key: KeyCode) bool {
        return @intFromEnum(key) >= 0;
    }

    fn listContains(items: []const KeyCode, key: KeyCode) bool {
        return std.mem.indexOfScalar(KeyCode, items, key) != null;
    }

    fn removeFirst(list: *std.ArrayList(KeyCode), key: KeyCode) void {
        if (std.mem.indexOfScalar(KeyCode, list.items, key)) |i| {
            _ = list.orderedRemove(i);
        }
    }
};

// ============================================================================
// tests（platform facade 不要。platform_types のみ）
// ============================================================================
const testing = std.testing;

test "KeyboardState: idle は全クエリ false" {
    var state = KeyboardState.init(testing.allocator);
    defer state.deinit();
    try testing.expect(!state.isDown(.A));
    try testing.expect(!state.justPressed(.A));
    try testing.expect(!state.justReleased(.A));
}

test "KeyboardState: 単一キー down / hold / up のエッジは 1 フレーム差分だけ" {
    var state = KeyboardState.init(testing.allocator);
    defer state.deinit();

    // frame 1: press A
    state.beginFrame();
    state.keyDown(.A);
    try testing.expect(state.isDown(.A));
    try testing.expect(state.justPressed(.A));
    try testing.expect(!state.justReleased(.A));

    // frame 2: hold A
    state.beginFrame();
    try testing.expect(state.isDown(.A));
    try testing.expect(!state.justPressed(.A));
    try testing.expect(!state.justReleased(.A));

    // frame 3: release A
    state.beginFrame();
    state.keyUp(.A);
    try testing.expect(!state.isDown(.A));
    try testing.expect(!state.justPressed(.A));
    try testing.expect(state.justReleased(.A));

    // frame 4: idle
    state.beginFrame();
    try testing.expect(!state.isDown(.A));
    try testing.expect(!state.justPressed(.A));
    try testing.expect(!state.justReleased(.A));
}

test "KeyboardState: 修飾キー（左右 Shift/Control）も KeyCode 集合で扱う" {
    var state = KeyboardState.init(testing.allocator);
    defer state.deinit();

    state.beginFrame();
    state.keyDown(.LEFT_SHIFT);
    state.keyDown(.RIGHT_CONTROL);
    try testing.expect(state.isDown(.LEFT_SHIFT));
    try testing.expect(state.isDown(.RIGHT_CONTROL));
    try testing.expect(state.justPressed(.LEFT_SHIFT));
    try testing.expect(state.justPressed(.RIGHT_CONTROL));
    try testing.expect(!state.isDown(.RIGHT_SHIFT));
    try testing.expect(!state.isDown(.LEFT_CONTROL));
}

test "KeyboardState: 複数キー同時押下と一部解放" {
    var state = KeyboardState.init(testing.allocator);
    defer state.deinit();

    state.beginFrame();
    state.keyDown(.W);
    state.keyDown(.A);
    state.keyDown(.D);
    try testing.expect(state.isDown(.W) and state.isDown(.A) and state.isDown(.D));

    state.beginFrame();
    state.keyUp(.A);
    try testing.expect(state.isDown(.W));
    try testing.expect(!state.isDown(.A));
    try testing.expect(state.isDown(.D));
    try testing.expect(state.justReleased(.A));
    try testing.expect(!state.justReleased(.W));
    try testing.expect(!state.justPressed(.D));
}

test "KeyboardState: 重複 keyDown（repeat 相当）で二重登録されない" {
    var state = KeyboardState.init(testing.allocator);
    defer state.deinit();

    state.beginFrame();
    state.keyDown(.SPACE);
    state.keyDown(.SPACE);
    state.keyDown(.SPACE);
    try testing.expectEqual(@as(usize, 1), state.current.items.len);
    try testing.expect(state.isDown(.SPACE));
    try testing.expect(state.justPressed(.SPACE));

    state.beginFrame();
    state.keyDown(.SPACE); // hold + repeat
    try testing.expectEqual(@as(usize, 1), state.current.items.len);
    try testing.expect(state.isDown(.SPACE));
    try testing.expect(!state.justPressed(.SPACE));
}

test "KeyboardState: UNKNOWN / 負値キーは集合に入らない" {
    var state = KeyboardState.init(testing.allocator);
    defer state.deinit();

    state.beginFrame();
    state.keyDown(.UNKNOWN);
    state.keyDown(@enumFromInt(-2));
    try testing.expectEqual(@as(usize, 0), state.current.items.len);
    try testing.expect(!state.isDown(.UNKNOWN));
    try testing.expect(!state.justPressed(.UNKNOWN));

    state.keyUp(.UNKNOWN); // no-op
    try testing.expectEqual(@as(usize, 0), state.current.items.len);
}

test "KeyboardState: 同一フレーム down→up は transient edge を保持しない" {
    // plan §7 / Claude 設計レビュー付記: 前後フレーム最終状態差分方式では
    // 同一フレーム内の押下後即解放は justPressed/justReleased に現れない。
    var state = KeyboardState.init(testing.allocator);
    defer state.deinit();

    state.beginFrame();
    state.keyDown(.ESCAPE);
    state.keyUp(.ESCAPE);
    try testing.expect(!state.isDown(.ESCAPE));
    try testing.expect(!state.justPressed(.ESCAPE));
    try testing.expect(!state.justReleased(.ESCAPE));
}

test "KeyboardState: 容量安定後の beginFrame はゼロアロケーション（FailingAllocator で実測）" {
    var state = KeyboardState.init(std.testing.allocator);
    defer state.deinit();
    // イベント時（keyDown）に current/previous の容量を確保しておく
    state.beginFrame();
    state.keyDown(.A);
    state.keyDown(.B);
    state.keyDown(.LEFT_SHIFT);
    try std.testing.expect(state.justPressed(.A)); // prev=[] / current={A,B,SHIFT}
    // 以降のフレーム毎 beginFrame は一切割り当てないことを FailingAllocator で固定
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    state.alloc = failing.allocator();
    state.beginFrame(); // prev={A,B,SHIFT} へコピー（容量確保済み → 無割当）
    try std.testing.expect(!state.justPressed(.A));
    try std.testing.expect(state.isDown(.B));
    state.beginFrame();
    try std.testing.expect(state.isDown(.LEFT_SHIFT));
    // 後始末用に通常 allocator へ戻す（deinit の free は FailingAllocator でも可だが明示的に戻す）
    state.alloc = std.testing.allocator;
}
