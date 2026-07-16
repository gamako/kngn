//! OS 非依存 MIDI null backend（TASK-115.1・ADR-010）。
//!
//! 実機 backend を追加するまで、全対象 OS で open 成功・イベント無しを提供する。
//! allocator は facade 契約を揃えるため受け取るが、null backend 内では使用しない。

const std = @import("std");
const types = @import("platform_types");

pub const Error = error{OpenFailed};
pub const Device = struct {
    pub fn pollMidi(_: @This()) ?types.MidiEvent {
        return null;
    }

    pub fn close(_: @This()) void {}
};

pub fn open(_: std.mem.Allocator) Error!Device {
    return .{};
}

test "midi_null: open 成功・poll は常に null・close は no-op" {
    const device = try open(std.testing.allocator);
    try std.testing.expectEqual(@as(?types.MidiEvent, null), device.pollMidi());
    try std.testing.expectEqual(@as(?types.MidiEvent, null), device.pollMidi());
    device.close();
}
