//! The OS-independent MIDI null backend (see ADR-010).
//!
//! On every target OS it makes open succeed and delivers no events.
//! It takes an allocator so that the facade contract is uniform, but the null backend never uses it.

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

test "midi_null: open succeeds, poll is always null, and close is a no-op" {
    const device = try open(std.testing.allocator);
    try std.testing.expectEqual(@as(?types.MidiEvent, null), device.pollMidi());
    try std.testing.expectEqual(@as(?types.MidiEvent, null), device.pollMidi());
    device.close();
}
