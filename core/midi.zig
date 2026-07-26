//! The MIDI facade (see ADR-010).
//!
//! The seam where the real backend is chosen by `builtin.os.tag`. macOS uses CoreMIDI and
//! every other OS the null backend. While harness is enabled it does not open a native backend, and instead
//! polls the shared harness module's synthetic FIFO from the main thread.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("platform_types");
const harness = @import("harness");

// macOS uses CoreMIDI, and every other OS plus wasm uses null. A later backend replaces this comptime choice.
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

    /// Takes one MIDI event, or null when there is none. Under harness it drains the synthetic FIFO.
    pub fn pollMidi(self: *Device) ?MidiEvent {
        if (self.harness_owned) {
            if (comptime @hasDecl(harness, "nextMidiEvent")) return harness.nextMidiEvent();
            return null;
        }
        const inner = self.inner orelse return null;
        return inner.pollMidi();
    }

    /// Teardown. The null backend and the harness device are no-ops, and a native backend is delegated to.
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

/// Opens a MIDI device. Under harness or headless it does not open a native backend.
pub fn open(allocator: std.mem.Allocator) Error!Device {
    if (harness.isEnabled() or harness.isHeadlessActive()) {
        return .{ .inner = null, .harness_owned = true };
    }
    return .{ .inner = try backend.open(allocator), .harness_owned = false };
}

test "the midi facade: while harness is disabled it opens the native or null backend, and stays empty after close" {
    if (harness.isEnabled() or harness.isHeadlessActive()) return error.SkipZigTest;

    var device = try open(std.testing.allocator);
    // null unless real hardware is sending at the same time. After close the facade detaches inner and it is always null.
    _ = device.pollMidi();
    device.close();
    try std.testing.expectEqual(@as(?MidiEvent, null), device.pollMidi());
}

test "the midi facade: it re-exports the shared types" {
    const ev: MidiEvent = .{ .note_off = .{ .device_id = 0, .note = 127, .velocity = 0 } };
    try std.testing.expectEqual(@as(u8, 127), ev.note_off.note);
}
