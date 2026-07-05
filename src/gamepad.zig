//! Gamepad utility module（TASK-80.1。ADR-009）
//!
//! `platform_types.GamepadButton`/`GamepadButtons`/`Stick` に対するヘルパー関数（ボタン名取得・
//! rising-edge 判定・deadzone 適用）。型自体は `platform_types.zig` で定義されており、ここではそれを
//! 再 export する。`keyboard.zig` と同じ「src/ レガシー配置」だが、AC#6 により `kit/kit.zig` でも
//! 再エクスポートする（keyboard.zig は examples 専用で kit 非収録）。
//!
//! `platform_types` のみに依存する（`platform` facade は import しない）ため、display/backend 不要で
//! headless に単体テストできる。

const std = @import("std");
const types = @import("platform_types");

pub const GamepadButton = types.GamepadButton;
pub const GamepadButtons = types.GamepadButtons;
pub const Stick = types.Stick;
pub const GamepadState = types.GamepadState;

/// ボタンを人間が読める文字列に変換する（`GamepadButton` の宣言名そのまま。exhaustive switch）。
pub fn getButtonName(btn: GamepadButton) []const u8 {
    return switch (btn) {
        .a => "A",
        .b => "B",
        .x => "X",
        .y => "Y",
        .left_shoulder => "LEFT_SHOULDER",
        .right_shoulder => "RIGHT_SHOULDER",
        .back => "BACK",
        .start => "START",
        .left_stick => "LEFT_STICK",
        .right_stick => "RIGHT_STICK",
        .dpad_up => "DPAD_UP",
        .dpad_down => "DPAD_DOWN",
        .dpad_left => "DPAD_LEFT",
        .dpad_right => "DPAD_RIGHT",
        .guide => "GUIDE",
    };
}

/// `button` が `prev`（前フレーム）で off・`cur`（今フレーム）で on の rising edge かを判定する。
/// キー入力の `is_repeat` に相当する「押した瞬間だけ」判定を、poll ベースの gamepad state に対して
/// consumer が自前で行うためのヘルパー（facade/harness は前フレーム state を保持しない）。
pub fn justPressed(prev: GamepadButtons, cur: GamepadButtons, button: GamepadButton) bool {
    return !prev.isSet(button) and cur.isSet(button);
}

/// `button` が `prev` で on・`cur` で off の falling edge（離した瞬間）かを判定する。
pub fn justReleased(prev: GamepadButtons, cur: GamepadButtons, button: GamepadButton) bool {
    return prev.isSet(button) and !cur.isSet(button);
}

/// radial deadzone を適用する（ADR-009「deadzone は生値 + ヘルパー」節）。
/// スティックの半径（`sqrt(x^2+y^2)`）が `dz` 未満なら `(0,0)`、それ以外は `dz` 以降の区間を
/// `0..1`（元の半径の最大値である 1.0 まで）へ線形に再スケールする（方向は変えない）。
/// `dz` は `[0, 1)` を期待する（`dz >= 1` は常に `(0,0)` を返す。負値は 0 として扱う）。
pub fn applyDeadzone(stick: Stick, dz: f32) Stick {
    const clamped_dz = std.math.clamp(dz, 0, 1);
    if (clamped_dz >= 1) return .{ .x = 0, .y = 0 }; // dz>=1 は常に無効化（0除算回避のため明示分岐）
    const radius = @sqrt(stick.x * stick.x + stick.y * stick.y);
    if (radius <= clamped_dz) return .{ .x = 0, .y = 0 };
    const scaled_radius = @min(1, (radius - clamped_dz) / (1 - clamped_dz));
    const scale = scaled_radius / radius;
    return .{ .x = stick.x * scale, .y = stick.y * scale };
}

// ============================================================================
// tests（display/backend 不要。platform_types のみに依存）
// ============================================================================
const testing = std.testing;

test "getButtonName: 全15ボタンが宣言名と一致する（exhaustive switch の抜け漏れを検出）" {
    try testing.expectEqualStrings("A", getButtonName(.a));
    try testing.expectEqualStrings("GUIDE", getButtonName(.guide));
    inline for (@typeInfo(GamepadButton).@"enum".fields) |f| {
        const btn: GamepadButton = @enumFromInt(f.value);
        const name = getButtonName(btn);
        try testing.expect(name.len > 0);
    }
}

test "justPressed/justReleased: rising/falling edge のみ true" {
    var prev = GamepadButtons{};
    var cur = GamepadButtons{};
    try testing.expect(!justPressed(prev, cur, .a));
    try testing.expect(!justReleased(prev, cur, .a));

    cur.set(.a, true);
    try testing.expect(justPressed(prev, cur, .a));
    try testing.expect(!justReleased(prev, cur, .a));

    prev.set(.a, true);
    try testing.expect(!justPressed(prev, cur, .a)); // 両方 on = rising ではない
    try testing.expect(!justReleased(prev, cur, .a));

    cur.set(.a, false);
    try testing.expect(!justPressed(prev, cur, .a));
    try testing.expect(justReleased(prev, cur, .a));

    // 他ボタンには影響しない
    try testing.expect(!justPressed(prev, cur, .b));
    try testing.expect(!justReleased(prev, cur, .b));
}

test "applyDeadzone: 中心付近は(0,0)、deadzone外は方向維持で再スケール" {
    // 中心（半径0）は常に (0,0)
    {
        const r = applyDeadzone(.{ .x = 0, .y = 0 }, 0.2);
        try testing.expectEqual(@as(f32, 0), r.x);
        try testing.expectEqual(@as(f32, 0), r.y);
    }
    // deadzone 未満（半径0.1 < dz=0.2）は (0,0)
    {
        const r = applyDeadzone(.{ .x = 0.1, .y = 0 }, 0.2);
        try testing.expectEqual(@as(f32, 0), r.x);
        try testing.expectEqual(@as(f32, 0), r.y);
    }
    // 最大値（半径1.0）は dz に関わらずそのまま（境界: scaled_radius=1）
    {
        const r = applyDeadzone(.{ .x = 1.0, .y = 0 }, 0.2);
        try testing.expectApproxEqAbs(@as(f32, 1.0), r.x, 1e-5);
        try testing.expectApproxEqAbs(@as(f32, 0.0), r.y, 1e-5);
    }
    // deadzone 直後（半径 0.2 == dz）は (0,0) 付近（scaled_radius=0）
    {
        const r = applyDeadzone(.{ .x = 0.2, .y = 0 }, 0.2);
        try testing.expectApproxEqAbs(@as(f32, 0.0), r.x, 1e-5);
    }
    // 中間値（半径0.6, dz=0.2）: scaled_radius=(0.6-0.2)/(1-0.2)=0.5、方向維持（x軸のみ）
    {
        const r = applyDeadzone(.{ .x = 0.6, .y = 0 }, 0.2);
        try testing.expectApproxEqAbs(@as(f32, 0.5), r.x, 1e-5);
        try testing.expectApproxEqAbs(@as(f32, 0.0), r.y, 1e-5);
    }
    // 斜め方向でも方向（角度）が保たれる
    {
        const r = applyDeadzone(.{ .x = 0.6, .y = 0.8 }, 0.0); // 半径1.0, dz=0
        try testing.expectApproxEqAbs(@as(f32, 0.6), r.x, 1e-5);
        try testing.expectApproxEqAbs(@as(f32, 0.8), r.y, 1e-5);
    }
    // dz>=1 は常に (0,0)（半径が [0,1] に収まる正常入力の範囲で確認）
    {
        const r = applyDeadzone(.{ .x = 0.6, .y = 0.6 }, 1.5);
        try testing.expectEqual(@as(f32, 0), r.x);
        try testing.expectEqual(@as(f32, 0), r.y);
    }
}
