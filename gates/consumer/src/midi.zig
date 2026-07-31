//! Links `kit.midi` the way an external package does. The reasoning is the one in
//! `audio.zig`: call the API so real symbols have to resolve.
//!
//! This builds on every system, but only macOS resolves against a system framework
//! (CoreMIDI). Everywhere else `kit.midi` is the null backend, so the executable proves
//! that the facade still compiles and links for a consumer, not that a framework was found.

const std = @import("std");
const kit = @import("kit");

pub fn main() !void {
    var input = try kit.midi.open(std.heap.page_allocator);
    input.close();
}
