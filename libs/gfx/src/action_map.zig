//! ActionMap — 複数入力ソースを button/axis アクションへ写像（TASK-111.8）。
//!
//! keyboard / gamepad の binding を固定長配列で保持し、毎フレーム `update` で
//! `isDown` / `justPressed` / `axisValue` を評価する。allocator 無し（評価・
//! リバインドとも固定長のみ）。
//!
//! ホットパス宣言: 毎フレーム全 action × 固定上限 binding を走査。
//! 全画素・audio RT・毎サンプル経路ではない。評価中の alloc / lock / IO / panic 無し。

const std = @import("std");
const keyboard = @import("keyboard");
const gamepad = @import("gamepad");
const platform_types = @import("platform_types");

pub const KeyCode = keyboard.KeyCode;
pub const KeyboardState = keyboard.KeyboardState;
pub const GamepadButton = gamepad.GamepadButton;
pub const GamepadState = gamepad.GamepadState;
pub const MAX_GAMEPADS = platform_types.MAX_GAMEPADS;

pub const ActionKind = enum { button, axis };

/// 固定長 action 配列の index。
pub const ActionId = struct {
    index: u16,
};

/// スティック左右（left_stick / right_stick）。
pub const StickSide = enum { left, right };

/// スティックの軸成分。
pub const StickAxis = enum { x, y };

pub const GamepadButtonBinding = struct {
    pad: u8,
    button: GamepadButton,
};

pub const GamepadStickBinding = struct {
    pad: u8,
    stick: StickSide,
    axis: StickAxis,
    deadzone: f32,
};

pub const KeyPairBinding = struct {
    negative: KeyCode,
    positive: KeyCode,
};

/// 1 binding のソース。
pub const Binding = union(enum) {
    key: KeyCode,
    gamepad_button: GamepadButtonBinding,
    gamepad_stick: GamepadStickBinding,
    key_pair: KeyPairBinding,
};

pub const Error = error{
    TooManyActions,
    TooManyBindings,
    WrongKind,
    InvalidAction,
};

/// 最大 `max_actions` 個の action、各 action 最大 `max_bindings_per_action` 個の binding。
/// 上限: max_actions は 1..=65535（action_count が u16）、max_bindings_per_action は
/// 1..=255（binding_count が u8）。範囲外は comptime エラー。
pub fn ActionMap(comptime max_actions: usize, comptime max_bindings_per_action: usize) type {
    comptime {
        std.debug.assert(max_actions >= 1 and max_actions <= std.math.maxInt(u16));
        std.debug.assert(max_bindings_per_action >= 1 and max_bindings_per_action <= std.math.maxInt(u8));
    }
    return struct {
        const Self = @This();

        const ActionSlot = struct {
            kind: ActionKind = .button,
            name: []const u8 = "",
            binding_count: u8 = 0,
            bindings: [max_bindings_per_action]Binding = undefined,
        };

        const ButtonState = struct {
            is_down: bool = false,
            just_pressed: bool = false,
        };

        const AxisState = struct {
            value: f32 = 0,
        };

        action_count: u16 = 0,
        actions: [max_actions]ActionSlot = [_]ActionSlot{.{}} ** max_actions,
        button_states: [max_actions]ButtonState = [_]ButtonState{.{}} ** max_actions,
        axis_states: [max_actions]AxisState = [_]AxisState{.{}} ** max_actions,

        pub fn init() Self {
            return .{};
        }

        pub fn defineButton(self: *Self, name: []const u8) Error!ActionId {
            return self.define(.button, name);
        }

        pub fn defineAxis(self: *Self, name: []const u8) Error!ActionId {
            return self.define(.axis, name);
        }

        fn define(self: *Self, kind: ActionKind, name: []const u8) Error!ActionId {
            if (self.action_count >= max_actions) return error.TooManyActions;
            const id = ActionId{ .index = self.action_count };
            self.actions[id.index] = .{
                .kind = kind,
                .name = name,
                .binding_count = 0,
            };
            self.button_states[id.index] = .{};
            self.axis_states[id.index] = .{};
            self.action_count += 1;
            return id;
        }

        fn slot(self: *Self, id: ActionId) Error!*ActionSlot {
            if (id.index >= self.action_count) return error.InvalidAction;
            return &self.actions[id.index];
        }

        fn slotConst(self: *const Self, id: ActionId) Error!*const ActionSlot {
            if (id.index >= self.action_count) return error.InvalidAction;
            return &self.actions[id.index];
        }

        fn requireKind(s: *const ActionSlot, kind: ActionKind) Error!void {
            if (s.kind != kind) return error.WrongKind;
        }

        fn appendBinding(s: *ActionSlot, b: Binding) Error!void {
            if (s.binding_count >= max_bindings_per_action) return error.TooManyBindings;
            s.bindings[s.binding_count] = b;
            s.binding_count += 1;
        }

        pub fn bindKey(self: *Self, id: ActionId, key: KeyCode) Error!void {
            const s = try self.slot(id);
            try requireKind(s, .button);
            try appendBinding(s, .{ .key = key });
        }

        pub fn bindGamepadButton(self: *Self, id: ActionId, pad: u8, button: GamepadButton) Error!void {
            const s = try self.slot(id);
            try requireKind(s, .button);
            try appendBinding(s, .{ .gamepad_button = .{ .pad = pad, .button = button } });
        }

        pub fn bindKeyPair(self: *Self, id: ActionId, negative: KeyCode, positive: KeyCode) Error!void {
            const s = try self.slot(id);
            try requireKind(s, .axis);
            try appendBinding(s, .{ .key_pair = .{ .negative = negative, .positive = positive } });
        }

        pub fn bindGamepadStick(
            self: *Self,
            id: ActionId,
            pad: u8,
            stick: StickSide,
            axis: StickAxis,
            deadzone: f32,
        ) Error!void {
            const s = try self.slot(id);
            try requireKind(s, .axis);
            try appendBinding(s, .{
                .gamepad_stick = .{
                    .pad = pad,
                    .stick = stick,
                    .axis = axis,
                    .deadzone = deadzone,
                },
            });
        }

        pub fn clearBindings(self: *Self, id: ActionId) Error!void {
            const s = try self.slot(id);
            s.binding_count = 0;
        }

        /// 容量検証後に binding を一括置換する。容量不足時は既存 binding を保持したままエラー。
        pub fn replaceBindings(self: *Self, id: ActionId, new_bindings: []const Binding) Error!void {
            const s = try self.slot(id);
            if (new_bindings.len > max_bindings_per_action) return error.TooManyBindings;
            for (new_bindings) |b| {
                switch (b) {
                    .key, .gamepad_button => try requireKind(s, .button),
                    .key_pair, .gamepad_stick => try requireKind(s, .axis),
                }
            }
            s.binding_count = 0;
            for (new_bindings) |b| {
                s.bindings[s.binding_count] = b;
                s.binding_count += 1;
            }
        }

        /// 毎フレーム呼ぶ。`prev_pads` / `cur_pads` は呼び出し側が保持する固定長配列。
        pub fn update(
            self: *Self,
            kb: *const KeyboardState,
            prev_pads: *const [MAX_GAMEPADS]?GamepadState,
            cur_pads: *const [MAX_GAMEPADS]?GamepadState,
        ) void {
            var i: u16 = 0;
            while (i < self.action_count) : (i += 1) {
                const s = &self.actions[i];
                switch (s.kind) {
                    .button => self.button_states[i] = evalButton(s, kb, prev_pads, cur_pads),
                    .axis => self.axis_states[i] = .{ .value = evalAxis(s, kb, cur_pads) },
                }
            }
        }

        pub fn isDown(self: *const Self, id: ActionId) bool {
            if (id.index >= self.action_count) return false;
            if (self.actions[id.index].kind != .button) return false;
            return self.button_states[id.index].is_down;
        }

        pub fn justPressed(self: *const Self, id: ActionId) bool {
            if (id.index >= self.action_count) return false;
            if (self.actions[id.index].kind != .button) return false;
            return self.button_states[id.index].just_pressed;
        }

        pub fn axisValue(self: *const Self, id: ActionId) f32 {
            if (id.index >= self.action_count) return 0;
            if (self.actions[id.index].kind != .axis) return 0;
            return self.axis_states[id.index].value;
        }

        pub fn actionName(self: *const Self, id: ActionId) []const u8 {
            if (id.index >= self.action_count) return "";
            return self.actions[id.index].name;
        }

        pub fn actionKind(self: *const Self, id: ActionId) ?ActionKind {
            if (id.index >= self.action_count) return null;
            return self.actions[id.index].kind;
        }

        pub fn bindingCount(self: *const Self, id: ActionId) u8 {
            if (id.index >= self.action_count) return 0;
            return self.actions[id.index].binding_count;
        }

        fn evalButton(
            s: *const ActionSlot,
            kb: *const KeyboardState,
            prev_pads: *const [MAX_GAMEPADS]?GamepadState,
            cur_pads: *const [MAX_GAMEPADS]?GamepadState,
        ) ButtonState {
            var is_down = false;
            var just_pressed = false;
            var bi: u8 = 0;
            while (bi < s.binding_count) : (bi += 1) {
                switch (s.bindings[bi]) {
                    .key => |key| {
                        if (kb.isDown(key)) is_down = true;
                        if (kb.justPressed(key)) just_pressed = true;
                    },
                    .gamepad_button => |gb| {
                        if (gb.pad >= MAX_GAMEPADS) continue;
                        const cur = cur_pads[gb.pad];
                        const prev = prev_pads[gb.pad];
                        if (cur) |c| {
                            if (c.buttons.isSet(gb.button)) is_down = true;
                            const prev_buttons = if (prev) |p| p.buttons else gamepad.GamepadButtons{};
                            if (gamepad.justPressed(prev_buttons, c.buttons, gb.button)) just_pressed = true;
                        }
                    },
                    .key_pair, .gamepad_stick => {},
                }
            }
            return .{ .is_down = is_down, .just_pressed = just_pressed };
        }

        fn evalAxis(
            s: *const ActionSlot,
            kb: *const KeyboardState,
            cur_pads: *const [MAX_GAMEPADS]?GamepadState,
        ) f32 {
            // スティック候補（deadzone 後に非ゼロ）と key pair 候補を登録順に走査し、
            // 絶対値最大を採用。同値時は先勝ち（登録順）。
            var best_stick: ?f32 = null;
            var best_stick_abs: f32 = -1;
            var best_key: ?f32 = null;
            var best_key_abs: f32 = -1;

            var bi: u8 = 0;
            while (bi < s.binding_count) : (bi += 1) {
                switch (s.bindings[bi]) {
                    .gamepad_stick => |gs| {
                        const v = stickAxisValue(gs, cur_pads);
                        if (v == 0) continue;
                        const a = @abs(v);
                        if (a > best_stick_abs) {
                            best_stick_abs = a;
                            best_stick = v;
                        }
                    },
                    .key_pair => |kp| {
                        const v = keyPairValue(kb, kp.negative, kp.positive);
                        if (v == 0) continue;
                        const a = @abs(v);
                        if (a > best_key_abs) {
                            best_key_abs = a;
                            best_key = v;
                        }
                    },
                    .key, .gamepad_button => {},
                }
            }

            // スティックが 1 つでも非ゼロならスティック優先（キー同時入力時もスティック勝ち）。
            if (best_stick) |v| return clampAxis(v);
            if (best_key) |v| return clampAxis(v);
            return 0;
        }

        fn stickAxisValue(
            gs: GamepadStickBinding,
            cur_pads: *const [MAX_GAMEPADS]?GamepadState,
        ) f32 {
            if (gs.pad >= MAX_GAMEPADS) return 0;
            const pad = cur_pads[gs.pad] orelse return 0;
            const raw: gamepad.Stick = switch (gs.stick) {
                .left => pad.left_stick,
                .right => pad.right_stick,
            };
            const filtered = gamepad.applyDeadzone(raw, gs.deadzone);
            return switch (gs.axis) {
                .x => filtered.x,
                .y => filtered.y,
            };
        }

        fn keyPairValue(kb: *const KeyboardState, negative: KeyCode, positive: KeyCode) f32 {
            const neg = kb.isDown(negative);
            const pos = kb.isDown(positive);
            if (neg and pos) return 0;
            if (neg) return -1;
            if (pos) return 1;
            return 0;
        }

        fn clampAxis(v: f32) f32 {
            return std.math.clamp(v, -1, 1);
        }
    };
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

const TestMap = ActionMap(8, 8);
const EmptyPads = [_]?GamepadState{null} ** MAX_GAMEPADS;

fn emptyPads() [MAX_GAMEPADS]?GamepadState {
    return EmptyPads;
}

fn makePads(pad0: ?GamepadState) [MAX_GAMEPADS]?GamepadState {
    var pads = emptyPads();
    pads[0] = pad0;
    return pads;
}

test "ActionMap: defineButton/defineAxis が ActionId を連番割当" {
    var map = TestMap.init();
    const jump = try map.defineButton("jump");
    const move_x = try map.defineAxis("move_x");
    const attack = try map.defineButton("attack");
    try testing.expectEqual(@as(u16, 0), jump.index);
    try testing.expectEqual(@as(u16, 1), move_x.index);
    try testing.expectEqual(@as(u16, 2), attack.index);
    try testing.expectEqual(ActionKind.button, map.actionKind(jump).?);
    try testing.expectEqual(ActionKind.axis, map.actionKind(move_x).?);
    try testing.expectEqualStrings("jump", map.actionName(jump));
}

test "ActionMap: action 上限 / binding 上限 / 種別不一致エラー" {
    var tiny = ActionMap(1, 1).init();
    const a = try tiny.defineButton("a");
    try testing.expectError(error.TooManyActions, tiny.defineButton("b"));
    try tiny.bindKey(a, .SPACE);
    try testing.expectError(error.TooManyBindings, tiny.bindKey(a, .ENTER));

    var map = TestMap.init();
    const btn = try map.defineButton("btn");
    const axis = try map.defineAxis("axis");
    try testing.expectError(error.WrongKind, map.bindKeyPair(btn, .A, .D));
    try testing.expectError(error.WrongKind, map.bindKey(axis, .SPACE));
    try testing.expectError(error.WrongKind, map.bindGamepadStick(btn, 0, .left, .x, 0.15));
    try testing.expectError(error.WrongKind, map.bindGamepadButton(axis, 0, .a));
}

test "ActionMap: key button の isDown / justPressed / hold edge" {
    var map = TestMap.init();
    const jump = try map.defineButton("jump");
    try map.bindKey(jump, .SPACE);

    var kb = KeyboardState.init(testing.allocator);
    defer kb.deinit();
    const pads = emptyPads();

    // frame 1: press
    kb.beginFrame();
    kb.keyDown(.SPACE);
    map.update(&kb, &pads, &pads);
    try testing.expect(map.isDown(jump));
    try testing.expect(map.justPressed(jump));

    // frame 2: hold
    kb.beginFrame();
    map.update(&kb, &pads, &pads);
    try testing.expect(map.isDown(jump));
    try testing.expect(!map.justPressed(jump));

    // frame 3: release
    kb.beginFrame();
    kb.keyUp(.SPACE);
    map.update(&kb, &pads, &pads);
    try testing.expect(!map.isDown(jump));
    try testing.expect(!map.justPressed(jump));
}

test "ActionMap: gamepad button の isDown / justPressed" {
    var map = TestMap.init();
    const jump = try map.defineButton("jump");
    try map.bindGamepadButton(jump, 0, .a);

    var kb = KeyboardState.init(testing.allocator);
    defer kb.deinit();
    kb.beginFrame();

    var prev = emptyPads();
    var cur = makePads(.{ .buttons = blk: {
        var b = gamepad.GamepadButtons{};
        b.set(.a, true);
        break :blk b;
    } });

    map.update(&kb, &prev, &cur);
    try testing.expect(map.isDown(jump));
    try testing.expect(map.justPressed(jump));

    prev = cur;
    map.update(&kb, &prev, &cur);
    try testing.expect(map.isDown(jump));
    try testing.expect(!map.justPressed(jump));

    cur = emptyPads();
    map.update(&kb, &prev, &cur);
    try testing.expect(!map.isDown(jump));
    try testing.expect(!map.justPressed(jump));
}

test "ActionMap: key と gamepad button の複数 binding は論理 OR" {
    var map = TestMap.init();
    const jump = try map.defineButton("jump");
    try map.bindKey(jump, .SPACE);
    try map.bindGamepadButton(jump, 0, .a);

    var kb = KeyboardState.init(testing.allocator);
    defer kb.deinit();
    const empty = emptyPads();

    // key only
    kb.beginFrame();
    kb.keyDown(.SPACE);
    map.update(&kb, &empty, &empty);
    try testing.expect(map.isDown(jump));
    try testing.expect(map.justPressed(jump));

    // gamepad only
    kb.beginFrame();
    kb.keyUp(.SPACE);
    var prev = emptyPads();
    var cur = makePads(.{ .buttons = blk: {
        var b = gamepad.GamepadButtons{};
        b.set(.a, true);
        break :blk b;
    } });
    map.update(&kb, &prev, &cur);
    try testing.expect(map.isDown(jump));
    try testing.expect(map.justPressed(jump));

    // both
    kb.beginFrame();
    kb.keyDown(.SPACE);
    prev = cur;
    map.update(&kb, &prev, &cur);
    try testing.expect(map.isDown(jump));
    try testing.expect(map.justPressed(jump)); // key rising
}

test "ActionMap: key pair は -1 / 0 / +1 合成" {
    var map = TestMap.init();
    const move_x = try map.defineAxis("move_x");
    try map.bindKeyPair(move_x, .A, .D);

    var kb = KeyboardState.init(testing.allocator);
    defer kb.deinit();
    const pads = emptyPads();

    kb.beginFrame();
    kb.keyDown(.D);
    map.update(&kb, &pads, &pads);
    try testing.expectEqual(@as(f32, 1), map.axisValue(move_x));

    kb.beginFrame();
    kb.keyUp(.D);
    kb.keyDown(.A);
    map.update(&kb, &pads, &pads);
    try testing.expectEqual(@as(f32, -1), map.axisValue(move_x));

    kb.beginFrame();
    kb.keyDown(.D); // both
    map.update(&kb, &pads, &pads);
    try testing.expectEqual(@as(f32, 0), map.axisValue(move_x));

    kb.beginFrame();
    kb.keyUp(.A);
    kb.keyUp(.D);
    map.update(&kb, &pads, &pads);
    try testing.expectEqual(@as(f32, 0), map.axisValue(move_x));
}

test "ActionMap: gamepad stick deadzone 適用と -1..1 範囲" {
    var map = TestMap.init();
    const move_x = try map.defineAxis("move_x");
    try map.bindGamepadStick(move_x, 0, .left, .x, 0.15);

    var kb = KeyboardState.init(testing.allocator);
    defer kb.deinit();
    kb.beginFrame();
    const prev = emptyPads();

    // deadzone 内
    var cur = makePads(.{ .left_stick = .{ .x = 0.1, .y = 0 } });
    map.update(&kb, &prev, &cur);
    try testing.expectEqual(@as(f32, 0), map.axisValue(move_x));

    // 0.5 raw → (0.5-0.15)/0.85 ≈ 0.4117647
    cur = makePads(.{ .left_stick = .{ .x = 0.5, .y = 0 } });
    map.update(&kb, &prev, &cur);
    try testing.expectApproxEqAbs(@as(f32, 0.4117647), map.axisValue(move_x), 1e-5);

    // フル
    cur = makePads(.{ .left_stick = .{ .x = -1, .y = 0 } });
    map.update(&kb, &prev, &cur);
    try testing.expectApproxEqAbs(@as(f32, -1), map.axisValue(move_x), 1e-5);
}

test "ActionMap: stick と key pair 同時入力は stick 優先" {
    var map = TestMap.init();
    const move_x = try map.defineAxis("move_x");
    try map.bindKeyPair(move_x, .A, .D);
    try map.bindGamepadStick(move_x, 0, .left, .x, 0.15);

    var kb = KeyboardState.init(testing.allocator);
    defer kb.deinit();
    kb.beginFrame();
    kb.keyDown(.D); // key = +1
    const prev = emptyPads();
    const cur = makePads(.{ .left_stick = .{ .x = 0.5, .y = 0 } }); // stick ≈ 0.4118
    map.update(&kb, &prev, &cur);
    try testing.expectApproxEqAbs(@as(f32, 0.4117647), map.axisValue(move_x), 1e-5);

    // stick を 0 にすると key にフォールバック
    const cur2 = makePads(.{ .left_stick = .{ .x = 0, .y = 0 } });
    map.update(&kb, &prev, &cur2);
    try testing.expectEqual(@as(f32, 1), map.axisValue(move_x));
}

test "ActionMap: 複数 stick 候補は絶対値最大、同値時は登録順" {
    var map = TestMap.init();
    const move_x = try map.defineAxis("move_x");
    // pad0 先登録、pad1 後登録
    try map.bindGamepadStick(move_x, 0, .left, .x, 0);
    try map.bindGamepadStick(move_x, 1, .left, .x, 0);

    var kb = KeyboardState.init(testing.allocator);
    defer kb.deinit();
    kb.beginFrame();
    const prev = emptyPads();

    // |pad1| > |pad0| → pad1
    var cur = emptyPads();
    cur[0] = .{ .left_stick = .{ .x = 0.3, .y = 0 } };
    cur[1] = .{ .left_stick = .{ .x = -0.8, .y = 0 } };
    map.update(&kb, &prev, &cur);
    try testing.expectApproxEqAbs(@as(f32, -0.8), map.axisValue(move_x), 1e-5);

    // 同絶対値 → 登録順（pad0 先勝ち）
    cur[0] = .{ .left_stick = .{ .x = 0.5, .y = 0 } };
    cur[1] = .{ .left_stick = .{ .x = -0.5, .y = 0 } };
    map.update(&kb, &prev, &cur);
    try testing.expectApproxEqAbs(@as(f32, 0.5), map.axisValue(move_x), 1e-5);
}

test "ActionMap: gamepad 切断時は button が落ち justPressed も false" {
    var map = TestMap.init();
    const jump = try map.defineButton("jump");
    try map.bindGamepadButton(jump, 0, .a);

    var kb = KeyboardState.init(testing.allocator);
    defer kb.deinit();
    kb.beginFrame();

    var prev = makePads(.{ .buttons = blk: {
        var b = gamepad.GamepadButtons{};
        b.set(.a, true);
        break :blk b;
    } });
    var cur = prev;
    map.update(&kb, &prev, &cur);
    try testing.expect(map.isDown(jump));

    // 切断
    prev = cur;
    cur = emptyPads();
    map.update(&kb, &prev, &cur);
    try testing.expect(!map.isDown(jump));
    try testing.expect(!map.justPressed(jump));
}

test "ActionMap: replaceBindings 成功と容量不足時の旧 binding 保持" {
    var map = ActionMap(4, 2).init();
    const jump = try map.defineButton("jump");
    try map.bindKey(jump, .SPACE);
    try testing.expectEqual(@as(u8, 1), map.bindingCount(jump));

    // 容量超過 → 旧 binding 保持
    const too_many = [_]Binding{
        .{ .key = .A },
        .{ .key = .B },
        .{ .key = .C },
    };
    try testing.expectError(error.TooManyBindings, map.replaceBindings(jump, &too_many));
    try testing.expectEqual(@as(u8, 1), map.bindingCount(jump));

    var kb = KeyboardState.init(testing.allocator);
    defer kb.deinit();
    const pads = emptyPads();
    kb.beginFrame();
    kb.keyDown(.SPACE);
    map.update(&kb, &pads, &pads);
    try testing.expect(map.isDown(jump)); // 旧 SPACE が残っている

    // 成功置換
    const ok = [_]Binding{
        .{ .key = .ENTER },
        .{ .gamepad_button = .{ .pad = 0, .button = .b } },
    };
    try map.replaceBindings(jump, &ok);
    try testing.expectEqual(@as(u8, 2), map.bindingCount(jump));

    kb.beginFrame();
    kb.keyUp(.SPACE);
    kb.keyDown(.ENTER);
    map.update(&kb, &pads, &pads);
    try testing.expect(map.isDown(jump));

    kb.beginFrame();
    kb.keyUp(.ENTER);
    map.update(&kb, &pads, &pads);
    try testing.expect(!map.isDown(jump));
}

test "ActionMap: update は allocator 不要（固定長 state のみ更新）" {
    var map = TestMap.init();
    const jump = try map.defineButton("jump");
    const move_x = try map.defineAxis("move_x");
    try map.bindKey(jump, .SPACE);
    try map.bindKeyPair(move_x, .A, .D);
    try map.bindGamepadStick(move_x, 0, .left, .x, 0.15);

    // KeyboardState のイベント容量は事前確保（ActionMap 本体の評価は alloc しない）
    var kb = KeyboardState.init(testing.allocator);
    defer kb.deinit();
    kb.beginFrame();
    kb.keyDown(.SPACE);
    kb.keyDown(.D);

    // ActionMap は allocator を持たず固定長 state のみ更新する（読取は kb / pads のみ）。
    const prev = emptyPads();
    const cur = makePads(.{ .left_stick = .{ .x = 0.5, .y = 0 } });
    map.update(&kb, &prev, &cur);
    try testing.expect(map.isDown(jump));
    try testing.expectApproxEqAbs(@as(f32, 0.4117647), map.axisValue(move_x), 1e-5);
}
