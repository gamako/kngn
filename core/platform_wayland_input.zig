//! Wayland 入力の純粋変換ロジック（TASK-28.5.3）。`@cImport` しない純 Zig。
//!
//! wl_keyboard / wl_pointer / xkbcommon を叩く本体（`platform_linux_wayland.zig`、Linux 専用）から
//! 値（整数 / bool）を受け取り、X11 backend と同じ意味論で変換する部分だけをここに集約し、
//! macOS host でも `zig build test-platform-wayland-input` で単体テストできるようにする
//! （X11 の `platform_linux_input.zig` と同じ設計）。
//!
//! 物理キー mapping と KeyDownSet / EventQueue は `platform_linux_input.zig` を再利用する。
//! Wayland 固有の差分（evdev+8 / evdev BTN_* / wl_fixed 座標 / xkb modifier / axis scroll /
//! repeat timing）のみ本ファイルが担う。

const std = @import("std");
const types = @import("platform_types");
const linux_input = @import("platform_linux_input.zig");

const KeyCode = types.KeyCode;
const MouseButton = types.MouseButton;
const ModifierFlags = types.ModifierFlags;

/// 1 notch = ±16 point（X11 wheelDelta / macOS SCROLL_LINE_TO_POINTS に整合）。
pub const SCROLL_LINE_TO_POINTS: f32 = linux_input.SCROLL_LINE_TO_POINTS;

// evdev button code（wl_pointer.button が運ぶ。X11 の 1/2/3 とは別系）
pub const BTN_LEFT: u32 = 0x110;
pub const BTN_RIGHT: u32 = 0x111;
pub const BTN_MIDDLE: u32 = 0x112;

// wl_pointer.axis の axis 値
pub const AXIS_VERTICAL: u32 = 0;
pub const AXIS_HORIZONTAL: u32 = 1;

// ============================================================================
// 物理キー: evdev keycode → KeyCode（layout 非依存・KeySym 不使用）
// ============================================================================

/// `wl_keyboard.key` の evdev keycode を KeyCode へ。前提「X keycode = evdev + 8」より、
/// 既存 X11 表（`keycodeToKeyCode`）を `evdev + 8` で再利用する（28.3 の物理キー契約を維持）。
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
// pointer 座標: wl_fixed(24.8 固定小数) → i32
// ============================================================================

/// `wl_fixed_to_int` 準拠（256 で割り 0 方向へ truncate）。負値も 0 方向（-256→-1, -384→-1）。
pub fn fixedToI32(f: i32) i32 {
    return @divTrunc(f, 256);
}

// ============================================================================
// modifier: xkb の active 状態 → ModifierFlags（cmd↔Super(Mod4), alt↔Mod1。X11 と同じ対応）
// ============================================================================

/// 本体側が `xkb_state_mod_name_is_active("Shift"/"Control"/"Mod1"/"Mod4")` で得た bool を渡す。
pub fn modifiersFromActive(shift: bool, ctrl: bool, alt: bool, super: bool) ModifierFlags {
    return .{ .shift = shift, .ctrl = ctrl, .alt = alt, .cmd = super };
}

// ============================================================================
// scroll: wl_pointer.axis → dx/dy（X11 wheelDelta と同じ符号・係数）
//
// Wayland は「正 = 下 / 右」。X11 wheelDelta は up=+16/down=-16, left=+16/right=-16 なので
// 縦横とも符号を反転する。1 notch = ±SCROLL_LINE_TO_POINTS。
// 最終的な符号/係数の体感は Linux 実機で確認する（plan §3.10）。
// ============================================================================

pub const ScrollDelta = struct { dx: f32 = 0, dy: f32 = 0 };

/// discrete notch（`wl_pointer.axis_discrete`。1 = 1 notch）→ ScrollDelta。
pub fn discreteScroll(axis: u32, discrete: i32) ScrollDelta {
    const mag = @as(f32, @floatFromInt(discrete)) * SCROLL_LINE_TO_POINTS;
    return switch (axis) {
        AXIS_VERTICAL => .{ .dx = 0, .dy = -mag },
        AXIS_HORIZONTAL => .{ .dx = -mag, .dy = 0 },
        else => .{},
    };
}

/// continuous（`wl_pointer.axis` の wl_fixed）→ ScrollDelta（discrete が無い compositor の fallback）。
/// 係数は wl_fixed→point の 1:1（fixed/256）を起点にし、体感は Linux 実機で調整する。
pub fn continuousScroll(axis: u32, value_fixed: i32) ScrollDelta {
    const v = @as(f32, @floatFromInt(value_fixed)) / 256.0;
    return switch (axis) {
        AXIS_VERTICAL => .{ .dx = 0, .dy = -v },
        AXIS_HORIZONTAL => .{ .dx = -v, .dy = 0 },
        else => .{},
    };
}

/// `wl_pointer.frame` 内で縦横 axis を 1 つの scroll delta にまとめる。
/// 本体は axis/axis_discrete を add し、frame で take() して 1 mouse_scroll に変換する。
pub const ScrollAccumulator = struct {
    dx: f32 = 0,
    dy: f32 = 0,
    active: bool = false,

    pub fn add(self: *ScrollAccumulator, d: ScrollDelta) void {
        self.dx += d.dx;
        self.dy += d.dy;
        self.active = true;
    }

    /// frame 終端で呼ぶ。蓄積があれば delta を返してリセット、無ければ null。
    pub fn take(self: *ScrollAccumulator) ?ScrollDelta {
        if (!self.active) return null;
        const d = ScrollDelta{ .dx = self.dx, .dy = self.dy };
        self.* = .{};
        return d;
    }
};

// ============================================================================
// repeat: wl_keyboard.repeat_info(rate, delay) に基づく is_repeat=true 生成の timing 計算
//
// 本体（pollEvents）が getTime() の now を渡す。repeat 対象キーか（modifier 等を除く）は
// xkbcommon の xkb_keymap_key_repeats で本体が判定し、対象のときだけ onKeyDown する。
// ============================================================================

pub const RepeatState = struct {
    /// 現在 repeat 対象の X keycode（evdev+8）。null = repeat 中でない。
    key: ?u32 = null,
    /// 次に key_down(is_repeat=true) を出す時刻（getTime 秒）。
    next: f64 = 0,
    /// repeat_info: rate(keys/sec, 0=無効) / delay(ms)。
    rate_hz: i32 = 0,
    delay_ms: i32 = 0,

    pub fn setInfo(self: *RepeatState, rate_hz: i32, delay_ms: i32) void {
        self.rate_hz = rate_hz;
        self.delay_ms = delay_ms;
        if (rate_hz <= 0) self.key = null; // repeat 無効化
    }

    /// repeat 対象キーの press 時。delay 後に最初の repeat を予定する。
    pub fn onKeyDown(self: *RepeatState, key: u32, now: f64) void {
        if (self.rate_hz <= 0) {
            self.key = null;
            return;
        }
        self.key = key;
        self.next = now + @as(f64, @floatFromInt(self.delay_ms)) / 1000.0;
    }

    /// key release 時。repeat 対象が離されたら停止。
    pub fn onKeyUp(self: *RepeatState, key: u32) void {
        if (self.key == key) self.key = null;
    }

    /// now 時点で repeat を出すべきか。
    pub fn due(self: *const RepeatState, now: f64) bool {
        return self.key != null and self.rate_hz > 0 and now >= self.next;
    }

    /// repeat を 1 回出した後、次の時刻へ進める（now 基準で drift burst を避ける）。
    pub fn advance(self: *RepeatState, now: f64) void {
        self.next = now + 1.0 / @as(f64, @floatFromInt(self.rate_hz));
    }
};

// ============================================================================
// tests（OS 非依存。zig build test-platform-wayland-input）
// ============================================================================
const testing = std.testing;

test "waylandKeyToKeyCode: evdev+8 で既存 X11 表を再利用（layout 非依存）" {
    // KEY_A=30 → X keycode 38 → .A、KEY_Q=16 → X 24 → .Q
    try testing.expectEqual(KeyCode.A, waylandKeyToKeyCode(30));
    try testing.expectEqual(KeyCode.Q, waylandKeyToKeyCode(16));
}

test "evdevButtonToMouseButton: BTN_* mapping" {
    try testing.expectEqual(MouseButton.left, evdevButtonToMouseButton(BTN_LEFT).?);
    try testing.expectEqual(MouseButton.right, evdevButtonToMouseButton(BTN_RIGHT).?);
    try testing.expectEqual(MouseButton.middle, evdevButtonToMouseButton(BTN_MIDDLE).?);
    try testing.expect(evdevButtonToMouseButton(0x113) == null);
    try testing.expect(evdevButtonToMouseButton(0) == null);
}

test "fixedToI32: wl_fixed_to_int 準拠（0 方向 truncate）" {
    try testing.expectEqual(@as(i32, 0), fixedToI32(0));
    try testing.expectEqual(@as(i32, 1), fixedToI32(256));
    try testing.expectEqual(@as(i32, 1), fixedToI32(384)); // 1.5 → 1
    try testing.expectEqual(@as(i32, -1), fixedToI32(-256));
    try testing.expectEqual(@as(i32, -1), fixedToI32(-384)); // -1.5 → -1（0 方向）
    try testing.expectEqual(@as(i32, 100), fixedToI32(25600));
}

test "modifiersFromActive: cmd↔super, alt↔mod1" {
    const m = modifiersFromActive(true, false, true, false);
    try testing.expect(m.shift and m.alt and !m.ctrl and !m.cmd);
    const s = modifiersFromActive(false, false, false, true);
    try testing.expect(s.cmd and !s.shift and !s.ctrl and !s.alt);
}

test "discreteScroll: 符号は X11 wheelDelta に一致（down=-16, right=-16）" {
    const down = discreteScroll(AXIS_VERTICAL, 1); // wayland 正=下
    try testing.expectEqual(@as(f32, 0), down.dx);
    try testing.expectEqual(@as(f32, -16.0), down.dy);
    const up = discreteScroll(AXIS_VERTICAL, -1);
    try testing.expectEqual(@as(f32, 16.0), up.dy);
    const right = discreteScroll(AXIS_HORIZONTAL, 1); // wayland 正=右
    try testing.expectEqual(@as(f32, -16.0), right.dx);
    try testing.expectEqual(@as(f32, 0), right.dy);
}

test "continuousScroll: fixed/256 を符号反転" {
    const d = continuousScroll(AXIS_VERTICAL, 256); // 1.0 下
    try testing.expectEqual(@as(f32, -1.0), d.dy);
}

test "ScrollAccumulator: frame 内の縦横を 1 delta にまとめ take でリセット" {
    var acc: ScrollAccumulator = .{};
    try testing.expect(acc.take() == null);
    acc.add(discreteScroll(AXIS_VERTICAL, 1)); // dy=-16
    acc.add(discreteScroll(AXIS_HORIZONTAL, 2)); // dx=-32
    const d = acc.take().?;
    try testing.expectEqual(@as(f32, -32.0), d.dx);
    try testing.expectEqual(@as(f32, -16.0), d.dy);
    try testing.expect(acc.take() == null); // take 後はリセット
}

test "RepeatState: delay→repeat→rate 進行、release で停止、rate0 で無効" {
    var r: RepeatState = .{};
    r.setInfo(25, 600); // 25Hz=0.04s 間隔, delay 600ms=0.6s
    r.onKeyDown(38, 0.0);
    try testing.expect(!r.due(0.5)); // delay 前
    try testing.expect(r.due(0.6)); // delay 経過
    r.advance(0.6);
    try testing.expect(!r.due(0.62));
    try testing.expect(r.due(0.64)); // 0.6 + 0.04
    r.onKeyUp(38);
    try testing.expect(!r.due(1.0)); // release で停止

    r.setInfo(0, 600); // rate 0 = repeat 無効
    r.onKeyDown(38, 0.0);
    try testing.expect(!r.due(10.0));
}
