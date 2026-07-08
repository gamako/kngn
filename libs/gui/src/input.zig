// 入力状態の集約。platform 非依存（21.3 指摘 3-6）のため、platform.Event ではなく
// libs/gui 独自の InputEvent を受ける。platform.Event → InputEvent の変換は
// 呼び出し側（pixie / sample）の薄いアダプタが行う。
//
// edge（mouse_pressed/released・keys_pressed/released）は beginFrame でクリアし、
// pushEvent で当フレーム分を立てる → 1 フレームのみ true になる。

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");

pub const Vec2 = geom.Vec2;

/// スクロール量は f32（trackpad の精密スクロールを丸めずに保持）。
pub const Vec2f = struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// 現在押下中のボタン集合（LSB-first、platform.MouseButtons と同レイアウト）。
pub const MouseButtons = packed struct(u8) {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
    _reserved: u5 = 0,
};

/// 修飾キー（platform.ModifierFlags と同レイアウト = shift:0x01, ctrl:0x02, alt:0x04, cmd:0x08）。
pub const ModifierFlags = packed struct(u32) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    cmd: bool = false,
    _reserved: u28 = 0,
};

/// libs/gui 独自の入力イベント。button は 0=left/1=right/2=middle、modifiers は raw bits。
/// key の code は u32（負値 = platform KeyCode.UNKNOWN は変換アダプタ側で除去済み）。
pub const InputEvent = union(enum) {
    mouse_move: struct { x: i32, y: i32, modifiers: u32 },
    mouse_down: struct { x: i32, y: i32, button: u8, modifiers: u32 },
    mouse_up: struct { x: i32, y: i32, button: u8, modifiers: u32 },
    mouse_scroll: struct { x: i32, y: i32, dx: f32, dy: f32, modifiers: u32 },
    key_down: struct { code: u32, modifiers: u32, repeat: bool },
    key_up: struct { code: u32, modifiers: u32 },
};

/// long-lived。keys_* は gpa 保持の ArrayList（unmanaged）。
pub const Input = struct {
    alloc: Allocator,
    mouse_pos: Vec2 = .{ .x = 0, .y = 0 },
    mouse_prev: Vec2 = .{ .x = 0, .y = 0 },
    mouse_delta: Vec2 = .{ .x = 0, .y = 0 },
    mouse_buttons: MouseButtons = .{}, // 現在のボタン状態
    mouse_pressed: MouseButtons = .{}, // このフレームで押された (edge)
    mouse_released: MouseButtons = .{}, // このフレームで離された (edge)
    mouse_pressed_pos: Vec2 = .{ .x = 0, .y = 0 }, // 直近の press edge の座標
    mouse_released_pos: Vec2 = .{ .x = 0, .y = 0 }, // 直近の左 release edge の座標
    scroll_delta: Vec2f = .{},
    modifiers: ModifierFlags = .{},

    keys_pressed: std.ArrayList(u32) = .empty, // このフレームで押された code（edge）
    keys_released: std.ArrayList(u32) = .empty, // このフレームで離された code（edge）
    keys_down: std.ArrayList(u32) = .empty, // 現在押下中の code 集合

    pub fn init(alloc: Allocator) Input {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Input) void {
        self.keys_pressed.deinit(self.alloc);
        self.keys_released.deinit(self.alloc);
        self.keys_down.deinit(self.alloc);
    }

    /// フレーム冒頭で呼ぶ。edge をクリアし、前フレーム最終位置を mouse_prev に保存。
    pub fn beginFrame(self: *Input) void {
        self.mouse_prev = self.mouse_pos;
        self.mouse_delta = .{ .x = 0, .y = 0 };
        self.mouse_pressed = .{};
        self.mouse_released = .{};
        self.scroll_delta = .{};
        self.keys_pressed.clearRetainingCapacity();
        self.keys_released.clearRetainingCapacity();
        // keys_down / mouse_buttons / mouse_pos は状態なので維持する。
    }

    /// beginFrame と widget 呼び出しの間で呼ぶ。
    pub fn pushEvent(self: *Input, ev: InputEvent) void {
        switch (ev) {
            .mouse_move => |m| {
                self.setMousePos(m.x, m.y);
                self.modifiers = @bitCast(m.modifiers);
            },
            .mouse_down => |m| {
                self.setMousePos(m.x, m.y);
                self.modifiers = @bitCast(m.modifiers);
                self.mouse_pressed_pos = .{ .x = m.x, .y = m.y };
                self.applyButton(m.button, true);
            },
            .mouse_up => |m| {
                self.setMousePos(m.x, m.y);
                self.modifiers = @bitCast(m.modifiers);
                if (m.button == 0) self.mouse_released_pos = .{ .x = m.x, .y = m.y };
                self.applyButton(m.button, false);
            },
            .mouse_scroll => |m| {
                self.setMousePos(m.x, m.y);
                self.modifiers = @bitCast(m.modifiers);
                self.scroll_delta.x += m.dx;
                self.scroll_delta.y += m.dy;
            },
            .key_down => |k| {
                self.modifiers = @bitCast(k.modifiers);
                // edge は初回 down のみ（repeat は押下継続だが pressed には積まない）。
                if (!k.repeat) appendUnique(&self.keys_pressed, self.alloc, k.code);
                appendUnique(&self.keys_down, self.alloc, k.code);
            },
            .key_up => |k| {
                self.modifiers = @bitCast(k.modifiers);
                appendUnique(&self.keys_released, self.alloc, k.code);
                removeFirst(&self.keys_down, k.code);
            },
        }
    }

    pub fn isDown(self: *const Input, code: u32) bool {
        return listContains(self.keys_down.items, code);
    }
    pub fn wasPressed(self: *const Input, code: u32) bool {
        return listContains(self.keys_pressed.items, code);
    }
    pub fn wasReleased(self: *const Input, code: u32) bool {
        return listContains(self.keys_released.items, code);
    }

    // ---- 内部ヘルパ ----

    fn setMousePos(self: *Input, x: i32, y: i32) void {
        self.mouse_pos = .{ .x = x, .y = y };
        self.mouse_delta = .{ .x = x - self.mouse_prev.x, .y = y - self.mouse_prev.y };
    }

    fn applyButton(self: *Input, button: u8, down: bool) void {
        const mask: u8 = switch (button) {
            0 => @bitCast(MouseButtons{ .left = true }),
            1 => @bitCast(MouseButtons{ .right = true }),
            2 => @bitCast(MouseButtons{ .middle = true }),
            else => return, // 未知ボタンは無視
        };
        const cur: u8 = @bitCast(self.mouse_buttons);
        if (down) {
            self.mouse_buttons = @bitCast(cur | mask);
            self.mouse_pressed = @bitCast(@as(u8, @bitCast(self.mouse_pressed)) | mask);
        } else {
            self.mouse_buttons = @bitCast(cur & ~mask);
            self.mouse_released = @bitCast(@as(u8, @bitCast(self.mouse_released)) | mask);
        }
    }
};

fn listContains(items: []const u32, code: u32) bool {
    for (items) |c| {
        if (c == code) return true;
    }
    return false;
}

fn appendUnique(list: *std.ArrayList(u32), alloc: Allocator, code: u32) void {
    if (listContains(list.items, code)) return;
    list.append(alloc, code) catch @panic("Input.keys: OOM");
}

fn removeFirst(list: *std.ArrayList(u32), code: u32) void {
    for (list.items, 0..) |c, i| {
        if (c == code) {
            _ = list.orderedRemove(i);
            return;
        }
    }
}

// ============================================================
// Tests
// ============================================================

test "Input: mouse_pressed/released は edge（1 フレームのみ）・buttons は状態継続" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();

    in.beginFrame();
    in.pushEvent(.{ .mouse_down = .{ .x = 5, .y = 5, .button = 0, .modifiers = 0 } });
    try std.testing.expect(in.mouse_pressed.left);
    try std.testing.expect(in.mouse_buttons.left);

    in.beginFrame(); // 次フレーム
    try std.testing.expect(!in.mouse_pressed.left); // edge クリア
    try std.testing.expect(in.mouse_buttons.left); // 状態は継続

    in.pushEvent(.{ .mouse_up = .{ .x = 5, .y = 5, .button = 0, .modifiers = 0 } });
    try std.testing.expect(in.mouse_released.left);
    try std.testing.expect(!in.mouse_buttons.left);

    in.beginFrame();
    try std.testing.expect(!in.mouse_released.left);
}

test "Input: mouse_pressed_pos は down の瞬間の座標を保持（down 後 move でも不変）" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();

    in.beginFrame();
    in.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 20, .button = 0, .modifiers = 0 } });
    in.pushEvent(.{ .mouse_move = .{ .x = 200, .y = 201, .modifiers = 0 } });

    try std.testing.expectEqual(@as(i32, 10), in.mouse_pressed_pos.x);
    try std.testing.expectEqual(@as(i32, 20), in.mouse_pressed_pos.y);
    // mouse_pos はフレーム最終位置
    try std.testing.expectEqual(@as(i32, 200), in.mouse_pos.x);
    try std.testing.expectEqual(@as(i32, 201), in.mouse_pos.y);
}

test "Input: mouse_released_pos は up の瞬間の座標を保持（up 後 move でも不変）" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();

    in.beginFrame();
    in.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 20, .button = 0, .modifiers = 0 } });
    in.pushEvent(.{ .mouse_move = .{ .x = 200, .y = 201, .modifiers = 0 } });

    try std.testing.expectEqual(@as(i32, 10), in.mouse_released_pos.x);
    try std.testing.expectEqual(@as(i32, 20), in.mouse_released_pos.y);
    try std.testing.expectEqual(@as(i32, 200), in.mouse_pos.x);
    try std.testing.expectEqual(@as(i32, 201), in.mouse_pos.y);
}

test "Input: mouse_released_pos は左 up の座標のみ latch（同フレーム右 up で上書きしない）" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();

    in.beginFrame();
    in.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 20, .button = 0, .modifiers = 0 } });
    in.pushEvent(.{ .mouse_up = .{ .x = 99, .y = 88, .button = 1, .modifiers = 0 } });

    try std.testing.expectEqual(@as(i32, 10), in.mouse_released_pos.x);
    try std.testing.expectEqual(@as(i32, 20), in.mouse_released_pos.y);
    try std.testing.expect(in.mouse_released.left);
    try std.testing.expect(in.mouse_released.right);
}

test "Input: mouse_pos は move を伴わない up でも最新化される" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();

    in.beginFrame();
    in.pushEvent(.{ .mouse_up = .{ .x = 33, .y = 44, .button = 0, .modifiers = 0 } });
    try std.testing.expectEqual(@as(i32, 33), in.mouse_pos.x);
    try std.testing.expectEqual(@as(i32, 44), in.mouse_pos.y);
}

test "Input: key edge（pressed/released は 1 フレーム、down は継続）" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();

    in.beginFrame();
    in.pushEvent(.{ .key_down = .{ .code = 65, .modifiers = 0, .repeat = false } });
    try std.testing.expect(in.wasPressed(65));
    try std.testing.expect(in.isDown(65));

    in.beginFrame();
    try std.testing.expect(!in.wasPressed(65)); // edge クリア
    try std.testing.expect(in.isDown(65)); // down は継続

    in.pushEvent(.{ .key_up = .{ .code = 65, .modifiers = 0 } });
    try std.testing.expect(in.wasReleased(65));
    try std.testing.expect(!in.isDown(65));
}

test "Input: key repeat は pressed edge に積まないが down にはする" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();

    in.beginFrame();
    in.pushEvent(.{ .key_down = .{ .code = 65, .modifiers = 0, .repeat = true } });
    try std.testing.expect(!in.wasPressed(65));
    try std.testing.expect(in.isDown(65));
}

test "Input: scroll_delta は累積しフレームでリセット" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();

    in.beginFrame();
    in.pushEvent(.{ .mouse_scroll = .{ .x = 0, .y = 0, .dx = 1.5, .dy = -2.0, .modifiers = 0 } });
    in.pushEvent(.{ .mouse_scroll = .{ .x = 0, .y = 0, .dx = 0.5, .dy = 1.0, .modifiers = 0 } });
    try std.testing.expectEqual(@as(f32, 2.0), in.scroll_delta.x);
    try std.testing.expectEqual(@as(f32, -1.0), in.scroll_delta.y);

    in.beginFrame();
    try std.testing.expectEqual(@as(f32, 0), in.scroll_delta.x);
    try std.testing.expectEqual(@as(f32, 0), in.scroll_delta.y);
}

test "Input: modifiers が raw bits から変換される" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();

    in.beginFrame();
    in.pushEvent(.{ .mouse_down = .{ .x = 0, .y = 0, .button = 0, .modifiers = 0x01 } }); // shift
    try std.testing.expect(in.modifiers.shift);
    try std.testing.expect(!in.modifiers.ctrl);
}
