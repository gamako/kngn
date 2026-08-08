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

/// The key codes this library reacts to.
///
/// libs/gui does not import core/platform (ADR-007), so the values are written out here. They
/// are the values of `platform_types.KeyCode`, which the conversion adapter passes through
/// unchanged, and changing one on either side breaks keyboard handling silently.
pub const key = struct {
    pub const space: u32 = 32;
    pub const escape: u32 = 256;
    pub const enter: u32 = 257;
    pub const tab: u32 = 258;
    pub const left: u32 = 263;
    pub const right: u32 = 264;
    pub const up: u32 = 265;
    pub const down: u32 = 266;
};

/// Raw modifier bits, matching `ModifierFlags` above.
pub const mod = struct {
    pub const shift: u32 = 0x01;
    pub const ctrl: u32 = 0x02;
    pub const alt: u32 = 0x04;
    pub const cmd: u32 = 0x08;
    pub const all: u32 = shift | ctrl | alt | cmd;
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

/// Input that arrived while no frame was active.
///
/// Forwarding platform events before opening the frame is the natural order for a native
/// loop (poll the window, then build the interface), so pushing input is not restricted to
/// the inside of a frame. Outside one it is held here and applied by the next `beginFrame`,
/// in arrival order, immediately after the previous frame's edges are cleared — a click or a
/// keystroke can therefore never be lost to the order in which a caller drives its frames.
///
/// Runs at event time only: a handful of events per frame, never over pixels or samples.
/// Storage is fixed, so staging allocates nothing and cannot grow without bound.
pub const StagedInput = struct {
    /// Bound on how much input one gap between frames may hold. This is a memory limit and an
    /// anomaly boundary, not a claim about how many events a system can deliver in a frame.
    pub const capacity = 256;
    /// Preedit text is display-only, so an over-long composition is clamped to this many bytes
    /// at a codepoint boundary instead of being rejected.
    pub const composition_text_capacity = 512;

    events: [capacity]InputEvent = undefined,
    len: usize = 0,
    /// Staged preedit, latest wins. `text` points into `composition_buf`, which this struct
    /// owns — a caller's slice is only valid through the frame it was handed to, and staging
    /// outlives that, so the bytes are copied rather than referenced.
    composition: ?CompositionState = null,
    composition_buf: [composition_text_capacity]u8 = undefined,
    /// How often the clamp above dropped preedit bytes. Internal diagnostics: not a probe and
    /// not part of the published surface.
    composition_truncations: u32 = 0,

    /// Hold one event until the next frame opens.
    ///
    /// A full buffer is compacted first (see `coalesce`, which merges adjacent pairs only, so a
    /// buffer alternating motion and presses has nothing to merge). If nothing can be freed the
    /// call panics, because the events left are ones whose loss would corrupt input state — a
    /// dropped `mouse_up` leaves a button held down for the rest of the run — and failing here
    /// is the only way that does not surface later as unexplained input behaviour.
    pub fn pushEvent(self: *StagedInput, ev: InputEvent) void {
        if (self.len == capacity and self.coalesce() == 0) {
            @panic("gui: staged input capacity exceeded before a frame was opened");
        }
        self.events[self.len] = ev;
        self.len += 1;
    }

    /// Hold the preedit until the next frame opens, copying its bytes.
    pub fn setComposition(self: *StagedInput, state: CompositionState) void {
        const kept = boundaryAtOrBefore(state.text, composition_text_capacity);
        if (kept < state.text.len) self.composition_truncations += 1;
        @memcpy(self.composition_buf[0..kept], state.text[0..kept]);
        self.composition = .{
            .active = state.active,
            .text = self.composition_buf[0..kept],
            // The caret is a byte offset into the text, so it follows the text through the clamp
            // and, like it, has to land on a codepoint boundary.
            .cursor = boundaryAtOrBefore(state.text[0..kept], @min(state.cursor, kept)),
        };
    }

    /// Apply everything held to `input`, in arrival order, and hand back the staged preedit if
    /// there was one. Call after `Input.beginFrame` has cleared the previous frame's edges, and
    /// before any widget reads input.
    pub fn drain(self: *StagedInput, input: *Input) ?CompositionState {
        for (self.events[0..self.len]) |ev| input.pushEvent(ev);
        self.len = 0;
        const staged = self.composition;
        self.composition = null;
        return staged;
    }

    /// Merge adjacent events that carry no information apart from their newest value, and
    /// report how many slots that freed. Motion collapses to where the pointer ended up and
    /// wheel deltas add, which is exactly what applying them one by one would have produced;
    /// presses, releases, keys and characters are discrete and never merge.
    fn coalesce(self: *StagedInput) usize {
        var write: usize = 0;
        for (self.events[0..self.len]) |ev| {
            if (write > 0) {
                if (merge(&self.events[write - 1], ev)) continue;
            }
            self.events[write] = ev;
            write += 1;
        }
        const freed = self.len - write;
        self.len = write;
        return freed;
    }

    /// Fold `next` into `prev` when the pair is redundant. Returns false if they must both stay.
    fn merge(prev: *InputEvent, next: InputEvent) bool {
        switch (prev.*) {
            .mouse_move => switch (next) {
                .mouse_move => {
                    prev.* = next;
                    return true;
                },
                else => return false,
            },
            .mouse_scroll => |p| switch (next) {
                .mouse_scroll => |n| {
                    prev.* = .{ .mouse_scroll = .{
                        .x = n.x,
                        .y = n.y,
                        .dx = p.dx + n.dx,
                        .dy = p.dy + n.dy,
                        .modifiers = n.modifiers,
                    } };
                    return true;
                },
                else => return false,
            },
            else => return false,
        }
    }
};

/// The largest offset into `text` that is at most `limit` and does not split a UTF-8 sequence.
/// Continuation bytes are 0b10xxxxxx, so walking back off them lands on the start of the
/// codepoint the offset fell inside. An offset at or past the end of the text is the end.
fn boundaryAtOrBefore(text: []const u8, limit: usize) usize {
    var end = @min(limit, text.len);
    while (end > 0 and end < text.len and text[end] & 0xC0 == 0x80) end -= 1;
    return end;
}

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

    /// The pointer position a drag in progress must use for this frame.
    ///
    /// A frame can carry several pointer events, and the platform commonly delivers a left
    /// `mouse_up` followed by another `mouse_move` within one frame (lifting a finger off a
    /// trackpad is the everyday case). `mouse_pos` is the frame's *final* position, which is what
    /// hover wants; a drag wants the position the gesture actually ended at. So on the frame the
    /// left button is released this reports `mouse_released_pos`, and otherwise `mouse_pos`.
    ///
    /// Every widget that turns a pointer position into a value while held reads this rather than
    /// `mouse_pos`, so that the value a drag settles on cannot be moved by an event that arrives
    /// after the release edge.
    pub inline fn dragPos(self: *const Input) Vec2 {
        return if (self.mouse_released.left) self.mouse_released_pos else self.mouse_pos;
    }

    /// `dragPos` measured against the previous frame's final position — the delta counterpart of
    /// `dragPos`, for widgets that consume movement rather than absolute position (a splitter, a
    /// scrollbar thumb). Movement delivered after the release edge is excluded, so it matches
    /// `mouse_delta` on every frame except the one a drag ends on.
    pub inline fn dragDelta(self: *const Input) Vec2 {
        const p = self.dragPos();
        return .{ .x = p.x - self.mouse_prev.x, .y = p.y - self.mouse_prev.y };
    }

    pub fn orderedTextEvents(self: *const Input) []const OrderedTextEvent {
        return self.ordered_text_events.items;
    }

    /// Whether this frame carries a fresh press of `code` holding exactly the modifiers asked for:
    /// every bit of `required` set, and no bit of `forbidden`. Auto-repeat does not count.
    ///
    /// Modifiers come from the key_down event itself rather than from `Input.modifiers`, which only
    /// holds the last event of the frame — with several events in one frame it reports the wrong
    /// combination for all but the last. Every keyboard interaction in this library goes through
    /// here so that the repeat and modifier rules stay identical across widgets.
    pub fn pressedPlain(self: *const Input, code: u32, required: u32, forbidden: u32) bool {
        for (self.ordered_text_events.items) |event| switch (event) {
            .key_down => |k| {
                if (k.code != code or k.repeat) continue;
                if (k.modifiers & required != required) continue;
                if (k.modifiers & forbidden != 0) continue;
                return true;
            },
            .char_input => {},
        };
        return false;
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

test "Input: dragPos follows mouse_pos while the button stays down" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();

    in.beginFrame();
    in.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    in.pushEvent(.{ .mouse_move = .{ .x = 40, .y = 30, .modifiers = 0 } });

    try std.testing.expectEqual(@as(i32, 40), in.dragPos().x);
    try std.testing.expectEqual(@as(i32, 30), in.dragPos().y);
    // With no release edge, dragDelta and mouse_delta agree.
    try std.testing.expectEqual(in.mouse_delta.x, in.dragDelta().x);
    try std.testing.expectEqual(in.mouse_delta.y, in.dragDelta().y);
}

test "Input: dragPos reports the release coordinates when a move follows the up in one frame" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();

    // Frame 1: press, then drag to (40, 30).
    in.beginFrame();
    in.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    in.pushEvent(.{ .mouse_move = .{ .x = 40, .y = 30, .modifiers = 0 } });

    // Frame 2: release at (40, 30), then a stray move to (90, 80).
    in.beginFrame();
    in.pushEvent(.{ .mouse_up = .{ .x = 40, .y = 30, .button = 0, .modifiers = 0 } });
    in.pushEvent(.{ .mouse_move = .{ .x = 90, .y = 80, .modifiers = 0 } });

    try std.testing.expectEqual(@as(i32, 40), in.dragPos().x);
    try std.testing.expectEqual(@as(i32, 30), in.dragPos().y);
    // mouse_pos still holds the frame's final position, for hover.
    try std.testing.expectEqual(@as(i32, 90), in.mouse_pos.x);
    try std.testing.expectEqual(@as(i32, 80), in.mouse_pos.y);
}

test "Input: dragDelta excludes movement delivered after the release edge" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();

    in.beginFrame();
    in.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });

    in.beginFrame(); // mouse_prev = (10, 10)
    in.pushEvent(.{ .mouse_move = .{ .x = 25, .y = 18, .modifiers = 0 } });
    in.pushEvent(.{ .mouse_up = .{ .x = 25, .y = 18, .button = 0, .modifiers = 0 } });
    in.pushEvent(.{ .mouse_move = .{ .x = 200, .y = 300, .modifiers = 0 } });

    try std.testing.expectEqual(@as(i32, 15), in.dragDelta().x);
    try std.testing.expectEqual(@as(i32, 8), in.dragDelta().y);
    // mouse_delta keeps counting the stray move.
    try std.testing.expectEqual(@as(i32, 190), in.mouse_delta.x);
    try std.testing.expectEqual(@as(i32, 290), in.mouse_delta.y);
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

test "StagedInput: events held outside a frame arrive in order once it opens" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();
    var staged: StagedInput = .{};

    staged.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 20, .modifiers = 0 } });
    staged.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 20, .button = 0, .modifiers = 0 } });
    staged.pushEvent(.{ .mouse_up = .{ .x = 12, .y = 22, .button = 0, .modifiers = 0 } });
    staged.pushEvent(.{ .key_down = .{ .code = key.enter, .modifiers = 0, .repeat = false } });

    // Nothing reaches Input before the frame opens.
    try std.testing.expect(!in.mouse_pressed.left);

    in.beginFrame();
    try std.testing.expectEqual(@as(?CompositionState, null), staged.drain(&in));

    // The press and release edges survive the frame boundary that used to discard them.
    try std.testing.expect(in.mouse_pressed.left);
    try std.testing.expect(in.mouse_released.left);
    try std.testing.expect(in.wasPressed(key.enter));
    try std.testing.expectEqual(@as(i32, 12), in.mouse_pos.x);
    try std.testing.expectEqual(@as(i32, 10), in.mouse_pressed_pos.x);
    try std.testing.expectEqual(@as(usize, 0), staged.len);
}

test "StagedInput: staging before a frame matches pushing inside it" {
    const events = [_]InputEvent{
        .{ .mouse_move = .{ .x = 5, .y = 5, .modifiers = 0 } },
        .{ .mouse_down = .{ .x = 5, .y = 5, .button = 0, .modifiers = 0 } },
        .{ .mouse_scroll = .{ .x = 5, .y = 5, .dx = 0, .dy = -3, .modifiers = 0 } },
        .{ .char_input = .{ .codepoint = 'a', .modifiers = 0 } },
    };

    var direct = Input.init(std.testing.allocator);
    defer direct.deinit();
    direct.beginFrame();
    for (events) |ev| direct.pushEvent(ev);

    var through_staging = Input.init(std.testing.allocator);
    defer through_staging.deinit();
    var staged: StagedInput = .{};
    for (events) |ev| staged.pushEvent(ev);
    through_staging.beginFrame();
    _ = staged.drain(&through_staging);

    try std.testing.expectEqual(direct.mouse_pos, through_staging.mouse_pos);
    try std.testing.expectEqual(direct.mouse_pressed.left, through_staging.mouse_pressed.left);
    try std.testing.expectEqual(direct.scroll_delta.y, through_staging.scroll_delta.y);
    try std.testing.expectEqual(direct.orderedTextEvents().len, through_staging.orderedTextEvents().len);
}

test "StagedInput: a full buffer of motion coalesces to the latest position" {
    var staged: StagedInput = .{};
    for (0..StagedInput.capacity) |i| {
        staged.pushEvent(.{ .mouse_move = .{ .x = @intCast(i), .y = 0, .modifiers = 0 } });
    }
    try std.testing.expectEqual(StagedInput.capacity, staged.len);

    // Pushing into a full buffer of motion collapses it rather than dropping anything.
    staged.pushEvent(.{ .mouse_move = .{ .x = 999, .y = 0, .modifiers = 0 } });
    try std.testing.expectEqual(@as(usize, 2), staged.len);

    var in = Input.init(std.testing.allocator);
    defer in.deinit();
    in.beginFrame();
    _ = staged.drain(&in);
    try std.testing.expectEqual(@as(i32, 999), in.mouse_pos.x);
}

test "StagedInput: coalesced wheel keeps the total delta" {
    var staged: StagedInput = .{};
    for (0..StagedInput.capacity) |_| {
        staged.pushEvent(.{ .mouse_scroll = .{ .x = 0, .y = 0, .dx = 0, .dy = -1, .modifiers = 0 } });
    }
    staged.pushEvent(.{ .mouse_scroll = .{ .x = 0, .y = 0, .dx = 0, .dy = -1, .modifiers = 0 } });

    var in = Input.init(std.testing.allocator);
    defer in.deinit();
    in.beginFrame();
    _ = staged.drain(&in);
    const total: f32 = -@as(f32, @floatFromInt(StagedInput.capacity + 1));
    try std.testing.expectEqual(total, in.scroll_delta.y);
}

test "StagedInput: discrete events are never merged away" {
    var staged: StagedInput = .{};
    // Motion between presses cannot merge across them, so the sequence keeps every edge.
    for (0..StagedInput.capacity / 2) |i| {
        staged.pushEvent(.{ .mouse_move = .{ .x = @intCast(i), .y = 0, .modifiers = 0 } });
        staged.pushEvent(.{ .mouse_down = .{ .x = @intCast(i), .y = 0, .button = 0, .modifiers = 0 } });
    }
    const freed = staged.coalesce();
    try std.testing.expectEqual(@as(usize, 0), freed);
    try std.testing.expectEqual(StagedInput.capacity, staged.len);
}

test "StagedInput: composition is copied, latest wins, and clamps on a codepoint boundary" {
    var staged: StagedInput = .{};
    {
        var scratch: [7]u8 = "preedit".*;
        staged.setComposition(.{ .active = true, .text = &scratch, .cursor = 3 });
        // Overwrite the caller's buffer: staging must not be looking at it any more.
        @memset(&scratch, 'x');
    }
    try std.testing.expectEqualStrings("preedit", staged.composition.?.text);
    try std.testing.expectEqual(@as(usize, 3), staged.composition.?.cursor);

    const long = "あ" ** 300; // 900 bytes of 3-byte codepoints
    staged.setComposition(.{ .active = true, .text = long, .cursor = long.len });
    const kept = staged.composition.?.text;
    try std.testing.expect(kept.len <= StagedInput.composition_text_capacity);
    try std.testing.expectEqual(@as(usize, 0), kept.len % 3); // no split sequence
    try std.testing.expectEqual(kept.len, staged.composition.?.cursor);
    try std.testing.expectEqual(@as(u32, 1), staged.composition_truncations);
}

test "StagedInput: a caret inside a codepoint moves back to its start" {
    var staged: StagedInput = .{};
    // Byte 1 and byte 2 are continuation bytes of the first codepoint.
    staged.setComposition(.{ .active = true, .text = "あい", .cursor = 2 });
    try std.testing.expectEqual(@as(usize, 0), staged.composition.?.cursor);

    staged.setComposition(.{ .active = true, .text = "あい", .cursor = 3 });
    try std.testing.expectEqual(@as(usize, 3), staged.composition.?.cursor);

    // A caret past the end lands on the end, which is always a boundary.
    staged.setComposition(.{ .active = true, .text = "あい", .cursor = 99 });
    try std.testing.expectEqual(@as(usize, 6), staged.composition.?.cursor);
}
