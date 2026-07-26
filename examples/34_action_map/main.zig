//! 34_action_map: ActionMap demo.
//!
//! - Map move_x / move_y / jump / attack from keyboard + gamepad onto the same actions
//! - WASD / arrows / left stick; SPACE/Ctrl and gamepad A/B
//! - R key switches WASD vs arrow key bindings (runtime rebind)
//! - Observe binding/source/status via harness custom probe `action_map`
//!
//! Hot path declaration: ActionMap.update is O(action×binding cap) every frame.
//! All-pixel loops are background memset + rect fills only. No alloc / lock / panic.

const std = @import("std");
const kit = @import("kit");
const platform = kit.platform;
const gfx = kit.gfx;
const gamepad = kit.gamepad;

const WINDOW_W: u32 = 640;
const WINDOW_H: u32 = 360;
const COLOR_BG: u32 = 0xFF1A1A28;
const COLOR_CHAR: u32 = 0xFFE0C040;
const COLOR_CHAR_JUMP: u32 = 0xFF40E080;
const COLOR_CHAR_ATTACK: u32 = 0xFFE04040;
const COLOR_BAR_BG: u32 = 0xFF303040;
const COLOR_BAR_POS: u32 = 0xFF40A0E0;
const COLOR_BAR_NEG: u32 = 0xFFE08040;
const COLOR_ON: u32 = 0xFF30D060;
const COLOR_OFF: u32 = 0xFF404048;

const CHAR_SIZE: i32 = 24;
const MOVE_SPEED: f32 = 4.0;
const DEADZONE: f32 = 0.15;

const Map = gfx.ActionMap(8, 8);

const BindingMode = enum { wasd, arrows };

const ProbeState = struct {
    binding: []const u8 = "wasd+pad",
    move_source: []const u8 = "none",
    move_x: f32 = 0,
    move_y: f32 = 0,
    jump_down: u8 = 0,
    jump_pressed: u8 = 0,
    attack_down: u8 = 0,
    attack_pressed: u8 = 0,
};

fn actionMapDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const st: *const ProbeState = @ptrCast(@alignCast(ctx));
    return std.fmt.bufPrint(buf, "binding={s} move_source={s} move_x={d:.4} move_y={d:.4} jump_down={d} jump_pressed={d} attack_down={d} attack_pressed={d}", .{
        st.binding,
        st.move_source,
        st.move_x,
        st.move_y,
        st.jump_down,
        st.jump_pressed,
        st.attack_down,
        st.attack_pressed,
    }) catch buf[0..0];
}

fn fillRect(fb: []u32, w: i32, h: i32, x: i32, y: i32, rw: i32, rh: i32, color: u32) void {
    var yy = @max(0, y);
    const y_end = @min(h, y + rh);
    while (yy < y_end) : (yy += 1) {
        var xx = @max(0, x);
        const x_end = @min(w, x + rw);
        while (xx < x_end) : (xx += 1) {
            fb[@as(usize, @intCast(yy)) * @as(usize, @intCast(w)) + @as(usize, @intCast(xx))] = color;
        }
    }
}

/// Simple 5×7 fixed-width dot glyphs (ASCII subset only).
const FONT_W = 5;
const FONT_H = 7;
const FONT_GLYPHS = struct {
    fn bits(c: u8) [FONT_H]u5 {
        return switch (c) {
            ' ' => .{ 0, 0, 0, 0, 0, 0, 0 },
            '+' => .{ 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0, 0 },
            '-' => .{ 0, 0, 0b11111, 0, 0, 0, 0 },
            '.' => .{ 0, 0, 0, 0, 0, 0b00100, 0 },
            '0' => .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 },
            '1' => .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
            '2' => .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 },
            '3' => .{ 0b01110, 0b10001, 0b00001, 0b00110, 0b00001, 0b10001, 0b01110 },
            '4' => .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 },
            '5' => .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 },
            '6' => .{ 0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 },
            '7' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 },
            '8' => .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 },
            '9' => .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100 },
            'A' => .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
            'B' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 },
            'C' => .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 },
            'D' => .{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110 },
            'E' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 },
            'J' => .{ 0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100 },
            'K' => .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 },
            'M' => .{ 0b10001, 0b11011, 0b10101, 0b10001, 0b10001, 0b10001, 0b10001 },
            'N' => .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 },
            'O' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
            'P' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 },
            'R' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 },
            'S' => .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 },
            'T' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 },
            'U' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
            'V' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 },
            'W' => .{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010 },
            'X' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 },
            'Y' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 },
            '=' => .{ 0, 0b11111, 0, 0b11111, 0, 0, 0 },
            ':' => .{ 0, 0b00100, 0, 0, 0b00100, 0, 0 },
            else => .{ 0b11111, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11111 },
        };
    }
};

fn drawText(fb: []u32, w: i32, h: i32, x0: i32, y0: i32, text: []const u8, color: u32) void {
    var x = x0;
    for (text) |c| {
        const rows = FONT_GLYPHS.bits(if (c >= 'a' and c <= 'z') c - 32 else c);
        var row: i32 = 0;
        while (row < FONT_H) : (row += 1) {
            const bits = rows[@intCast(row)];
            var col: i32 = 0;
            while (col < FONT_W) : (col += 1) {
                if ((bits >> @intCast(FONT_W - 1 - col)) & 1 != 0) {
                    const px = x + col;
                    const py = y0 + row;
                    if (px >= 0 and py >= 0 and px < w and py < h) {
                        fb[@as(usize, @intCast(py)) * @as(usize, @intCast(w)) + @as(usize, @intCast(px))] = color;
                    }
                }
            }
        }
        x += FONT_W + 1;
    }
}

fn applyMoveKeyBindings(actions: *Map, move_x: gfx.ActionId, move_y: gfx.ActionId, mode: BindingMode) !void {
    // Keep the pad stick; switch only the key pair (clear + re-bind).
    try actions.clearBindings(move_x);
    try actions.clearBindings(move_y);
    switch (mode) {
        .wasd => {
            try actions.bindKeyPair(move_x, .A, .D);
            try actions.bindKeyPair(move_y, .W, .S);
        },
        .arrows => {
            try actions.bindKeyPair(move_x, .LEFT, .RIGHT);
            try actions.bindKeyPair(move_y, .UP, .DOWN);
        },
    }
    try actions.bindGamepadStick(move_x, 0, .left, .x, DEADZONE);
    try actions.bindGamepadStick(move_y, 0, .left, .y, DEADZONE);
}

fn detectMoveSource(
    kb: *const gfx.KeyboardState,
    cur_pads: *const [platform.MAX_GAMEPADS]?platform.GamepadState,
    mode: BindingMode,
    move_x: f32,
) []const u8 {
    if (move_x == 0) {
        // y is separate in the probe. source uses move_x as the primary axis (matches the e2e scenario).
        if (cur_pads[0]) |p| {
            const s = gamepad.applyDeadzone(p.left_stick, DEADZONE);
            if (s.y != 0) return "stick";
        }
        const neg: gfx.KeyCode, const pos: gfx.KeyCode = switch (mode) {
            .wasd => .{ .W, .S },
            .arrows => .{ .UP, .DOWN },
        };
        if (kb.isDown(neg) or kb.isDown(pos)) return "key";
        return "none";
    }
    if (cur_pads[0]) |p| {
        const s = gamepad.applyDeadzone(p.left_stick, DEADZONE);
        if (s.x != 0) return "stick";
    }
    return "key";
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WINDOW_W, WINDOW_H, "34: ActionMap (keyboard + gamepad)");
    defer window.destroy();

    var kb = gfx.KeyboardState.init(allocator);
    defer kb.deinit();

    var actions = Map.init();
    const jump = try actions.defineButton("jump");
    const attack = try actions.defineButton("attack");
    const move_x = try actions.defineAxis("move_x");
    const move_y = try actions.defineAxis("move_y");

    try actions.bindKey(jump, .SPACE);
    try actions.bindGamepadButton(jump, 0, .a);
    try actions.bindKey(attack, .LEFT_CONTROL);
    try actions.bindGamepadButton(attack, 0, .b);

    var mode: BindingMode = .wasd;
    try applyMoveKeyBindings(&actions, move_x, move_y, mode);

    var prev_pads: [platform.MAX_GAMEPADS]?platform.GamepadState = .{null} ** platform.MAX_GAMEPADS;
    var cur_pads: [platform.MAX_GAMEPADS]?platform.GamepadState = .{null} ** platform.MAX_GAMEPADS;

    var char_x: f32 = @as(f32, @floatFromInt(WINDOW_W - CHAR_SIZE)) / 2;
    var char_y: f32 = @as(f32, @floatFromInt(WINDOW_H - CHAR_SIZE)) / 2;

    var probe: ProbeState = .{};
    platform.registerProbe(.{
        .name = "action_map",
        .ctx = &probe,
        .ext = "txt",
        .digest = actionMapDigest,
        .desc = "ActionMap binding/source/axis/button status",
    });

    main_loop: while (window.pollEvents()) {
        kb.beginFrame();
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| {
                if (k.key == .ESCAPE or k.key == .Q) break :main_loop;
                kb.keyDown(k.key);
            },
            .key_up => |k| kb.keyUp(k.key),
            else => {},
        };

        // Poll gamepad state into a fixed-length array
        prev_pads = cur_pads;
        var pi: u8 = 0;
        while (pi < platform.MAX_GAMEPADS) : (pi += 1) {
            cur_pads[pi] = window.getGamepadState(pi);
        }

        // R switches key bindings (edge via KeyboardState.justPressed)
        if (kb.justPressed(.R)) {
            mode = if (mode == .wasd) .arrows else .wasd;
            try applyMoveKeyBindings(&actions, move_x, move_y, mode);
        }

        actions.update(&kb, &prev_pads, &cur_pads);

        const dx = actions.axisValue(move_x);
        const dy = actions.axisValue(move_y);
        // stick.y up=+1. Screen Y is down-positive, so invert.
        char_x = std.math.clamp(char_x + dx * MOVE_SPEED, 0, @as(f32, @floatFromInt(WINDOW_W - CHAR_SIZE)));
        char_y = std.math.clamp(char_y - dy * MOVE_SPEED, 0, @as(f32, @floatFromInt(WINDOW_H - CHAR_SIZE)));

        probe.binding = if (mode == .wasd) "wasd+pad" else "arrows+pad";
        probe.move_source = detectMoveSource(&kb, &cur_pads, mode, dx);
        // When move_y is non-zero and move_x is 0, re-derive source from y
        if (dx == 0 and dy != 0) {
            if (cur_pads[0]) |p| {
                const s = gamepad.applyDeadzone(p.left_stick, DEADZONE);
                probe.move_source = if (s.y != 0) "stick" else "key";
            } else {
                probe.move_source = "key";
            }
        }
        probe.move_x = dx;
        probe.move_y = dy;
        probe.jump_down = @intFromBool(actions.isDown(jump));
        probe.jump_pressed = @intFromBool(actions.justPressed(jump));
        probe.attack_down = @intFromBool(actions.isDown(attack));
        probe.attack_pressed = @intFromBool(actions.justPressed(attack));

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, COLOR_BG);
            const wi: i32 = @intCast(fb.width);
            const hi: i32 = @intCast(fb.height);

            // axis bar
            fillRect(fb.pixels, wi, hi, 16, 16, 200, 10, COLOR_BAR_BG);
            fillRect(fb.pixels, wi, hi, 16, 32, 200, 10, COLOR_BAR_BG);
            const mid: i32 = 16 + 100;
            if (dx >= 0) {
                fillRect(fb.pixels, wi, hi, mid, 16, @intFromFloat(dx * 100), 10, COLOR_BAR_POS);
            } else {
                const bw: i32 = @intFromFloat(-dx * 100);
                fillRect(fb.pixels, wi, hi, mid - bw, 16, bw, 10, COLOR_BAR_NEG);
            }
            if (dy >= 0) {
                fillRect(fb.pixels, wi, hi, mid, 32, @intFromFloat(dy * 100), 10, COLOR_BAR_POS);
            } else {
                const bw: i32 = @intFromFloat(-dy * 100);
                fillRect(fb.pixels, wi, hi, mid - bw, 32, bw, 10, COLOR_BAR_NEG);
            }

            // button indicator
            fillRect(fb.pixels, wi, hi, 16, 52, 14, 14, if (probe.jump_down != 0) COLOR_ON else COLOR_OFF);
            fillRect(fb.pixels, wi, hi, 40, 52, 14, 14, if (probe.attack_down != 0) COLOR_ON else COLOR_OFF);

            drawText(fb.pixels, wi, hi, 16, 80, "ACTION MAP", 0xFFC0C0D0);
            drawText(fb.pixels, wi, hi, 16, 92, probe.binding, 0xFFE0E0F0);
            drawText(fb.pixels, wi, hi, 16, 104, probe.move_source, 0xFFA0E0FF);
            drawText(fb.pixels, wi, hi, 16, 116, "R:REBIND", 0xFF9090A0);

            var color = COLOR_CHAR;
            if (probe.attack_down != 0) color = COLOR_CHAR_ATTACK;
            if (probe.jump_down != 0) color = COLOR_CHAR_JUMP;
            fillRect(fb.pixels, wi, hi, @intFromFloat(char_x), @intFromFloat(char_y), CHAR_SIZE, CHAR_SIZE, color);

            window.present();
        }

        platform.frameDelay(16_666_666);
    }
}
