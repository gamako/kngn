//! example_29: MIDI monitor sketch (see docs/adr/010_midi-input-facade.md).
//!
//! Shows note 0..127 press state and CC 0..127 values with existing framebuffer rectangle draws only.
//! Even before a real-device backend exists, headless verification works via harness `inject midi`.
//!
//! Hot path declaration: MIDI poll/state updates are event-only. Drawing is per-frame but uses the existing
//! framebuffer path for fixed-size note/CC rects; not an RT (per-sample) path.

const platform = @import("platform");
const midi = @import("midi");
const std = @import("std");

const FRAME_PERIOD_S: f64 = 1.0 / 60.0;

const WINDOW_W = 640;
const WINDOW_H = 420;
const NOTE_COLS = 16;
const NOTE_CELL = 32;
const NOTE_TOP = 16;
const CC_TOP = 292;
const CC_BAR_W = 5;
const CC_BAR_GAP = 0;
const CC_MAX_H = 96;

const COLOR_BG: u32 = 0xFF101018;
const COLOR_NOTE_OFF: u32 = 0xFF292938;
const COLOR_NOTE_ON: u32 = 0xFF46C8E8;
const COLOR_CC_TRACK: u32 = 0xFF252535;
const COLOR_CC_VALUE: u32 = 0xFFE0A040;

const MonitorState = struct {
    pressed: [16]u8 = [_]u8{0} ** 16,
    cc_values: [128]u8 = [_]u8{0} ** 128,
};

fn fillRect(fb: []u32, w: i32, h: i32, x: i32, y: i32, width: i32, height: i32, color: u32) void {
    const x0 = @max(0, x);
    const y0 = @max(0, y);
    const x1 = @min(w, x + width);
    const y1 = @min(h, y + height);
    var yy = y0;
    const stride: usize = @intCast(@max(w, 0));
    while (yy < y1) : (yy += 1) {
        const row_start = @as(usize, @intCast(yy)) * stride;
        if (row_start >= fb.len) break;
        const row_limit = @min(@as(usize, @intCast(@max(x1, 0))), fb.len - row_start);
        var xx = x0;
        while (@as(usize, @intCast(xx)) < row_limit) : (xx += 1) {
            fb[row_start + @as(usize, @intCast(xx))] = color;
        }
    }
}

fn noteIsPressed(state: MonitorState, note: usize) bool {
    return (state.pressed[note / 8] & (@as(u8, 1) << @intCast(note % 8))) != 0;
}

fn setNote(state: *MonitorState, note: u8, on: bool) void {
    const mask = @as(u8, 1) << @intCast(note % 8);
    if (on) {
        state.pressed[note / 8] |= mask;
    } else {
        state.pressed[note / 8] &= ~mask;
    }
}

fn drawMonitor(state: MonitorState, fb: []u32, w: i32, h: i32) void {
    @memset(fb, COLOR_BG);

    var note: usize = 0;
    while (note < 128) : (note += 1) {
        const col = note % NOTE_COLS;
        const row = note / NOTE_COLS;
        const x: i32 = @intCast(col * NOTE_CELL + 8);
        const y: i32 = @intCast(row * NOTE_CELL + NOTE_TOP);
        fillRect(fb, w, h, x, y, NOTE_CELL - 2, NOTE_CELL - 2, if (noteIsPressed(state, note)) COLOR_NOTE_ON else COLOR_NOTE_OFF);
    }

    var controller: usize = 0;
    while (controller < 128) : (controller += 1) {
        const x: i32 = @intCast(controller * (CC_BAR_W + CC_BAR_GAP));
        fillRect(fb, w, h, x, CC_TOP, CC_BAR_W, CC_MAX_H, COLOR_CC_TRACK);
        const value_height: i32 = @intCast(@as(usize, state.cc_values[controller]) * CC_MAX_H / 127);
        fillRect(fb, w, h, x, CC_TOP + CC_MAX_H - value_height, CC_BAR_W, value_height, COLOR_CC_VALUE);
    }
}

pub fn main() !void {
    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WINDOW_W, WINDOW_H, "29: MIDI Monitor");
    defer window.destroy();

    var device = try midi.open(std.heap.page_allocator);
    defer device.close();

    var state: MonitorState = .{};
    main_loop: while (window.pollEvents()) {
        const frame_t0 = platform.getTime();
        defer platform.framePaceUntil(frame_t0 + FRAME_PERIOD_S);

        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |key| if (key.key == .ESCAPE) break :main_loop,
            else => {},
        };

        while (device.pollMidi()) |ev| switch (ev) {
            .note_on => |note| setNote(&state, note.note, true),
            .note_off => |note| setNote(&state, note.note, false),
            .cc => |cc| state.cc_values[cc.controller] = cc.value,
        };

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            drawMonitor(state, fb.pixels, @intCast(fb.width), @intCast(fb.height));
            window.present();
        }
    }
}
