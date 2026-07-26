//! Keyboard utility module
//!
//! Helpers on the `platform_types.KeyCode` enum (name lookup, classification, char conversion).
//! KeyCode itself is sourced from `core/platform_types.zig`. libs/gfx depends on type-only core only
//! (ADR-007: libs → type-only core; no dependency on the platform facade implementation).

const std = @import("std");
const platform_types = @import("platform_types");

pub const KeyCode = platform_types.KeyCode;

/// Convert a key code to a human-readable string.
/// Letter keys (A-Z) and digit keys (0-9) return the actual character.
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
    // Within KeyCode's enumerated range, only SPACE / A-Z / 0-9 are printable
    // (punctuation like `!"#$%`... is not present in KeyCode)
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

/// Get an ASCII character from a letter key (A-Z) / digit key (0-9)
pub fn getCharFromKey(key: KeyCode) ?u8 {
    if (isLetterKey(key) or isDigitKey(key)) {
        return @intCast(@intFromEnum(key));
    }
    return null;
}

// ============================================================================
// KeyboardState — pressed-key set + previous/current frame edge
// ============================================================================

/// Holds the pressed-key set and provides `isDown` / `justPressed` / `justReleased`.
///
/// Edge detection matches `src/gamepad.zig`'s `justPressed`/`justReleased`:
/// it looks only at the **difference between the final pressed sets of consecutive frames**.
///
/// Usage (every frame):
/// ```
/// state.beginFrame(); // save previous-frame set
/// // During event handling:
/// state.keyDown(key); // / keyUp(key)
/// // Update/draw:
/// if (state.justPressed(.SPACE)) { ... }
/// if (state.isDown(.LEFT_SHIFT)) { ... }
/// ```
///
/// ## No transient edge for same-frame down→up
///
/// If `keyDown(A)` is immediately followed by `keyUp(A)` in the same frame, both
/// current and previous at frame end exclude A, so `justPressed(A)` and
/// `justReleased(A)` stay **false** (edges are not accumulated).
/// Note: this differs semantically from GUI `keys_pressed` edge accumulation.
///
/// Modifier keys (LEFT_SHIFT, etc.) are in the same set as ordinary `KeyCode`s.
/// `KeyCode.UNKNOWN` and negative key values are never added (`keyDown`/`keyUp` ignore them).
///
/// Hot path: linear search on events + per-frame `O(pressed key count)` set copy.
/// No full-pixel or RT loops. After the first capacity reserve, `clearRetainingCapacity` avoids realloc.
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

    /// Call at the start of a frame. Saves the pressed set at frame start into previous.
    /// current is kept as-is and then updated by subsequent keyDown/keyUp.
    pub fn beginFrame(self: *KeyboardState) void {
        self.previous.clearRetainingCapacity();
        self.previous.appendSlice(self.alloc, self.current.items) catch @panic("KeyboardState.beginFrame: OOM");
    }

    /// Add a key to the pressed set (duplicates ignored; prevents double-insert equivalent to key repeat).
    /// Negative / UNKNOWN are ignored.
    /// Also reserves previous's capacity here (on the event) so beginFrame's per-frame
    /// appendSlice does not realloc (zero-alloc after warm-up is pinned by the
    /// FailingAllocator test).
    pub fn keyDown(self: *KeyboardState, key: KeyCode) void {
        if (!isTrackable(key)) return;
        if (listContains(self.current.items, key)) return;
        self.current.append(self.alloc, key) catch @panic("KeyboardState.keyDown: OOM");
        self.previous.ensureTotalCapacity(self.alloc, self.current.items.len) catch @panic("KeyboardState.keyDown: OOM");
    }

    /// Remove a key from the pressed set. Not-pressed / negative / UNKNOWN are no-ops.
    pub fn keyUp(self: *KeyboardState, key: KeyCode) void {
        if (!isTrackable(key)) return;
        removeFirst(&self.current, key);
    }

    pub fn isDown(self: *const KeyboardState, key: KeyCode) bool {
        return listContains(self.current.items, key);
    }

    /// True only on the rising edge (not pressed previous frame → pressed this frame).
    pub fn justPressed(self: *const KeyboardState, key: KeyCode) bool {
        return listContains(self.current.items, key) and !listContains(self.previous.items, key);
    }

    /// True only on the falling edge (pressed previous frame → not pressed this frame).
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
// tests (no platform facade; platform_types only)
// ============================================================================
const testing = std.testing;

test "KeyboardState: idle makes every query false" {
    var state = KeyboardState.init(testing.allocator);
    defer state.deinit();
    try testing.expect(!state.isDown(.A));
    try testing.expect(!state.justPressed(.A));
    try testing.expect(!state.justReleased(.A));
}

test "KeyboardState: single-key down / hold / up edges are only the 1-frame difference" {
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

test "KeyboardState: modifiers (left/right Shift/Control) are also in the KeyCode set" {
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

test "KeyboardState: multiple keys held and partial release" {
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

test "KeyboardState: duplicate keyDown (repeat-equivalent) does not double-insert" {
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

test "KeyboardState: UNKNOWN / negative keys are not added to the set" {
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

test "KeyboardState: same-frame down→up does not keep a transient edge" {
    // Same-frame press-then-release does not surface on justPressed/justReleased
    // under the previous/current final-state diff model.
    var state = KeyboardState.init(testing.allocator);
    defer state.deinit();

    state.beginFrame();
    state.keyDown(.ESCAPE);
    state.keyUp(.ESCAPE);
    try testing.expect(!state.isDown(.ESCAPE));
    try testing.expect(!state.justPressed(.ESCAPE));
    try testing.expect(!state.justReleased(.ESCAPE));
}

test "KeyboardState: beginFrame after capacity warm-up is zero-alloc (pinned with FailingAllocator)" {
    var state = KeyboardState.init(std.testing.allocator);
    defer state.deinit();
    // Reserve current/previous capacity on the event (keyDown)
    state.beginFrame();
    state.keyDown(.A);
    state.keyDown(.B);
    state.keyDown(.LEFT_SHIFT);
    try std.testing.expect(state.justPressed(.A)); // prev=[] / current={A,B,SHIFT}
    // Pin with FailingAllocator that later per-frame beginFrame allocates nothing
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    state.alloc = failing.allocator();
    state.beginFrame(); // Copy into prev={A,B,SHIFT} (capacity already reserved → zero alloc)
    try std.testing.expect(!state.justPressed(.A));
    try std.testing.expect(state.isDown(.B));
    state.beginFrame();
    try std.testing.expect(state.isDown(.LEFT_SHIFT));
    // Switch back to a normal allocator for cleanup (deinit free works on FailingAllocator too, but be explicit)
    state.alloc = std.testing.allocator;
}
