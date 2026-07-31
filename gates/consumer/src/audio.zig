//! Links `kit.audio` the way an external package does.
//!
//! The point is the link, not the run. `kit.audio` reaches the OS through `extern fn`, so
//! the symbols it needs are resolved when the executable is assembled — and only if the
//! consumer opted into `enable_audio`. Naming the types would compile and link cleanly
//! while proving nothing, so this calls `open` and `close` for real.
//!
//! Runs at gate time only, and in fact never has to run at all: a missing link is a build
//! failure, not a runtime one.

const std = @import("std");
const kit = @import("kit");

fn render(buf: []f32, frames: u32, channels: u32, sample_rate: u32, userdata: ?*anyopaque) void {
    _ = frames;
    _ = channels;
    _ = sample_rate;
    _ = userdata;
    @memset(buf, 0);
}

pub fn main() !void {
    var device = try kit.audio.open(std.heap.page_allocator, .{ .render_callback = render });
    device.close();
}
