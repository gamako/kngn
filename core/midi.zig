//! MIDI facade（TASK-115.1/115.2・ADR-010）。
//!
//! `builtin.os.tag` による実機 backend 選択の継ぎ目。macOS は CoreMIDI（TASK-115.2）、
//! 他 OS は null backend。harness が有効なときは native backend を開かず、共有 harness
//! module の synthetic FIFO を main thread からポーリングする。

const std = @import("std");
const builtin = @import("builtin");
const types = @import("platform_types");
const harness = @import("harness");

// macOS = CoreMIDI（TASK-115.2）。他 OS / wasm は null。後続 backend はこの comptime 選択点を置き換える。
const backend = if (builtin.cpu.arch.isWasm())
    @import("midi_null.zig")
else switch (builtin.os.tag) {
    .macos => @import("midi_macos.zig"),
    .linux, .windows => @import("midi_null.zig"),
    else => @import("midi_null.zig"),
};

pub const Error = backend.Error;
pub const MidiDeviceId = types.MidiDeviceId;
pub const MidiNoteEvent = types.MidiNoteEvent;
pub const MidiCcEvent = types.MidiCcEvent;
pub const MidiEvent = types.MidiEvent;

pub const Device = struct {
    inner: ?backend.Device,
    harness_owned: bool,

    /// MIDI イベントを1件取得する。空なら null。harness 時は synthetic FIFO を drain する。
    pub fn pollMidi(self: *Device) ?MidiEvent {
        if (self.harness_owned) {
            if (comptime @hasDecl(harness, "nextMidiEvent")) return harness.nextMidiEvent();
            return null;
        }
        const inner = self.inner orelse return null;
        return inner.pollMidi();
    }

    /// 終了処理。null backend と harness device は no-op、native backend は委譲する。
    pub fn close(self: *Device) void {
        if (self.harness_owned) {
            self.harness_owned = false;
            return;
        }
        if (self.inner) |inner| {
            inner.close();
            self.inner = null;
        }
    }
};

/// MIDI device を開く。harness/headless 時は native backend を開かない。
pub fn open(allocator: std.mem.Allocator) Error!Device {
    if (harness.isEnabled() or harness.isHeadlessActive()) {
        return .{ .inner = null, .harness_owned = true };
    }
    return .{ .inner = try backend.open(allocator), .harness_owned = false };
}

test "midi facade: harness 無効時は native/null backend を開き close 後も空" {
    if (harness.isEnabled() or harness.isHeadlessActive()) return error.SkipZigTest;

    var device = try open(std.testing.allocator);
    // 実機が同時に送っていなければ null。close 後は facade が inner を外して常に null。
    _ = device.pollMidi();
    device.close();
    try std.testing.expectEqual(@as(?MidiEvent, null), device.pollMidi());
}

test "midi facade: 共有型を facade から再エクスポートする" {
    const ev: MidiEvent = .{ .note_off = .{ .device_id = 0, .note = 127, .velocity = 0 } };
    try std.testing.expectEqual(@as(u8, 127), ev.note_off.note);
}
