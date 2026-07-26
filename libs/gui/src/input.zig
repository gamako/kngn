// Aggregated input state. Platform-independent: accepts libs/gui's own InputEvent,
// not platform.Event. Conversion from platform.Event → InputEvent is done by a thin
// adapter on the caller side (pixie / sample).
//
// Edges (mouse_pressed/released, keys_pressed/released) are cleared in beginFrame and
// set for the current frame in pushEvent → true for one frame only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");

pub const Vec2 = geom.Vec2;

/// Scroll amount is f32 (keeps trackpad precision without rounding).
pub const Vec2f = struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// Currently held button set (LSB-first; same layout as platform.MouseButtons).
pub const MouseButtons = packed struct(u8) {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
    _reserved: u5 = 0,
};

/// Modifier keys (same layout as platform.ModifierFlags = shift:0x01, ctrl:0x02, alt:0x04, cmd:0x08).
pub const ModifierFlags = packed struct(u32) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    cmd: bool = false,
    _reserved: u28 = 0,
};

/// libs/gui's own input event. button is 0=left/1=right/2=middle; modifiers are raw bits.
/// key code is u32 (negative = platform KeyCode.UNKNOWN is already stripped by the conversion adapter).
pub const InputEvent = union(enum) {
    mouse_move: struct { x: i32, y: i32, modifiers: u32 },
    mouse_down: struct { x: i32, y: i32, button: u8, modifiers: u32 },
    mouse_up: struct { x: i32, y: i32, button: u8, modifiers: u32 },
    mouse_scroll: struct { x: i32, y: i32, dx: f32, dy: f32, modifiers: u32 },
    key_down: struct { code: u32, modifiers: u32, repeat: bool },
    key_up: struct { code: u32, modifiers: u32 },
    char_input: struct { codepoint: u32, modifiers: u32 },
};

/// Sequence that preserves arrival order of key_down and char_input.
pub const OrderedTextEvent = union(enum) {
    key_down: struct { code: u32, modifiers: u32, repeat: bool },
    char_input: struct { codepoint: u32, modifiers: u32 },
};

/// IME composition (in-progress preedit) display-only state. Platform-independent.
/// `text` is a borrowed UTF-8 slice owned by the caller (must remain valid through endFrame).
/// `cursor` is a UTF-8 byte offset within `text` (display caret).
pub const CompositionState = struct {
    active: bool = false,
    text: []const u8 = "",
    cursor: usize = 0,
};

/// long-lived. keys_* are GPA-backed ArrayLists (unmanaged).
pub const Input = struct {
    alloc: Allocator,
    mouse_pos: Vec2 = .{ .x = 0, .y = 0 },
    mouse_prev: Vec2 = .{ .x = 0, .y = 0 },
    mouse_delta: Vec2 = .{ .x = 0, .y = 0 },
    mouse_buttons: MouseButtons = .{}, // current button state
    mouse_pressed: MouseButtons = .{}, // pressed this frame (edge)
    mouse_released: MouseButtons = .{}, // released this frame (edge)
    mouse_pressed_pos: Vec2 = .{ .x = 0, .y = 0 }, // coordinates of the most recent press edge
    mouse_pressed_modifiers: ModifierFlags = .{},
    mouse_released_pos: Vec2 = .{ .x = 0, .y = 0 }, // coordinates of the most recent left release edge
    scroll_delta: Vec2f = .{},
    modifiers: ModifierFlags = .{},

    keys_pressed: std.ArrayList(u32) = .empty, // codes pressed this frame (edge)
    keys_released: std.ArrayList(u32) = .empty, // codes released this frame (edge)
    keys_down: std.ArrayList(u32) = .empty, // currently held code set
    ordered_text_events: std.ArrayList(OrderedTextEvent) = .empty,

    pub fn init(alloc: Allocator) Input {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Input) void {
        self.keys_pressed.deinit(self.alloc);
        self.keys_released.deinit(self.alloc);
        self.keys_down.deinit(self.alloc);
        self.ordered_text_events.deinit(self.alloc);
    }

    /// Call at frame start. Clears edges and saves the previous frame's final position into mouse_prev.
    pub fn beginFrame(self: *Input) void {
        self.mouse_prev = self.mouse_pos;
        self.mouse_delta = .{ .x = 0, .y = 0 };
        self.mouse_pressed = .{};
        self.mouse_released = .{};
        self.scroll_delta = .{};
        self.keys_pressed.clearRetainingCapacity();
        self.keys_released.clearRetainingCapacity();
        self.ordered_text_events.clearRetainingCapacity();
        // keys_down / mouse_buttons / mouse_pos are state, so they persist.
    }

    /// Call between beginFrame and widget invocation.
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
                self.mouse_pressed_modifiers = @bitCast(m.modifiers);
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
                self.ordered_text_events.append(self.alloc, .{ .key_down = .{
                    .code = k.code,
                    .modifiers = k.modifiers,
                    .repeat = k.repeat,
                } }) catch
                    @panic("Input.events: OOM");
                // Edge is first down only (repeat keeps the key held but is not pushed into pressed).
                if (!k.repeat) appendUnique(&self.keys_pressed, self.alloc, k.code);
                appendUnique(&self.keys_down, self.alloc, k.code);
            },
            .key_up => |k| {
                self.modifiers = @bitCast(k.modifiers);
                appendUnique(&self.keys_released, self.alloc, k.code);
                removeFirst(&self.keys_down, k.code);
            },
            .char_input => |ch| {
                self.modifiers = @bitCast(ch.modifiers);
                self.ordered_text_events.append(self.alloc, .{ .char_input = .{
                    .codepoint = ch.codepoint,
                    .modifiers = ch.modifiers,
                } }) catch
                    @panic("Input.events: OOM");
            },
        }
    }

    pub fn orderedTextEvents(self: *const Input) []const OrderedTextEvent {
        return self.ordered_text_events.items;
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

    // ---- internal helpers ----

    fn setMousePos(self: *Input, x: i32, y: i32) void {
        self.mouse_pos = .{ .x = x, .y = y };
        self.mouse_delta = .{ .x = x - self.mouse_prev.x, .y = y - self.mouse_prev.y };
    }

    fn applyButton(self: *Input, button: u8, down: bool) void {
        const mask: u8 = switch (button) {
            0 => @bitCast(MouseButtons{ .left = true }),
            1 => @bitCast(MouseButtons{ .right = true }),
            2 => @bitCast(MouseButtons{ .middle = true }),
            else => return, // ignore unknown buttons
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

test "Input: mouse_pressed/released are edges (one frame only); buttons persist as state" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();

    in.beginFrame();
    in.pushEvent(.{ .mouse_down = .{ .x = 5, .y = 5, .button = 0, .modifiers = 0 } });
    try std.testing.expect(in.mouse_pressed.left);
    try std.testing.expect(in.mouse_buttons.left);

    in.beginFrame(); // next frame
    try std.testing.expect(!in.mouse_pressed.left); // edge cleared
    try std.testing.expect(in.mouse_buttons.left); // state persists

    in.pushEvent(.{ .mouse_up = .{ .x = 5, .y = 5, .button = 0, .modifiers = 0 } });
    try std.testing.expect(in.mouse_released.left);
    try std.testing.expect(!in.mouse_buttons.left);

    in.beginFrame();
    try std.testing.expect(!in.mouse_released.left);
}

test "Input: mouse_pressed_pos keeps the coordinates at the down instant (unchanged by later moves)" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();

    in.beginFrame();
    in.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 20, .button = 0, .modifiers = 0 } });
    in.pushEvent(.{ .mouse_move = .{ .x = 200, .y = 201, .modifiers = 0 } });

    try std.testing.expectEqual(@as(i32, 10), in.mouse_pressed_pos.x);
    try std.testing.expectEqual(@as(i32, 20), in.mouse_pressed_pos.y);
    // mouse_pos is the frame's final position
    try std.testing.expectEqual(@as(i32, 200), in.mouse_pos.x);
    try std.testing.expectEqual(@as(i32, 201), in.mouse_pos.y);
}

test "Input: mouse_released_pos keeps the coordinates at the up instant (unchanged by later moves)" {
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

test "Input: mouse_released_pos latches left-up coordinates only (same-frame right-up does not overwrite)" {
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

test "Input: mouse_pos updates even on up without a move" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();

    in.beginFrame();
    in.pushEvent(.{ .mouse_up = .{ .x = 33, .y = 44, .button = 0, .modifiers = 0 } });
    try std.testing.expectEqual(@as(i32, 33), in.mouse_pos.x);
    try std.testing.expectEqual(@as(i32, 44), in.mouse_pos.y);
}

test "Input: key edge (pressed/released last one frame; down persists)" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();

    in.beginFrame();
    in.pushEvent(.{ .key_down = .{ .code = 65, .modifiers = 0, .repeat = false } });
    try std.testing.expect(in.wasPressed(65));
    try std.testing.expect(in.isDown(65));

    in.beginFrame();
    try std.testing.expect(!in.wasPressed(65)); // edge cleared
    try std.testing.expect(in.isDown(65)); // down persists

    in.pushEvent(.{ .key_up = .{ .code = 65, .modifiers = 0 } });
    try std.testing.expect(in.wasReleased(65));
    try std.testing.expect(!in.isDown(65));
}

test "Input: key repeat is not pushed to the pressed edge but is added to down" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();

    in.beginFrame();
    in.pushEvent(.{ .key_down = .{ .code = 65, .modifiers = 0, .repeat = true } });
    try std.testing.expect(!in.wasPressed(65));
    try std.testing.expect(in.isDown(65));
}

test "Input: scroll_delta accumulates and resets each frame" {
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

test "Input: modifiers are converted from raw bits" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();

    in.beginFrame();
    in.pushEvent(.{ .mouse_down = .{ .x = 0, .y = 0, .button = 0, .modifiers = 0x01 } }); // shift
    try std.testing.expect(in.modifiers.shift);
    try std.testing.expect(!in.modifiers.ctrl);
}

test "Input: preserves char_input and key_down order, and resets each frame" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();

    in.beginFrame();
    in.pushEvent(.{ .char_input = .{ .codepoint = 'あ', .modifiers = 0 } });
    in.pushEvent(.{ .key_down = .{ .code = 67, .modifiers = 8, .repeat = false } });
    try std.testing.expectEqual(@as(usize, 2), in.orderedTextEvents().len);
    try std.testing.expectEqual(@as(u32, 'あ'), in.orderedTextEvents()[0].char_input.codepoint);
    try std.testing.expectEqual(@as(u32, 67), in.orderedTextEvents()[1].key_down.code);

    in.beginFrame();
    try std.testing.expectEqual(@as(usize, 0), in.orderedTextEvents().len);
}
