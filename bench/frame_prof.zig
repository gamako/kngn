//! What the frame section profiler costs per frame.
//!
//! The claim it has to support is that instrumentation is negligible against a frame body
//! measured in milliseconds. That claim is about one `begin` + N `mark` + `end` sequence, so
//! that is what is timed, in three configurations:
//!
//! - **disabled** — the passthrough path an unprofiled run takes
//! - **enabled, scripted clock** — the bookkeeping alone, with the clock read reduced to a
//!   load and an add
//! - **enabled, real clock** — the same plus the monotonic clock reads, which is what a
//!   profiled run actually pays
//!
//! The difference between the last two is the clock; the difference between the first two is
//! the arithmetic. Reporting only the total would leave it unclear which one to attack if the
//! number ever got large.
//!
//! Each configuration runs a warm-up pass and several trials, and the **median** trial is
//! reported: a single trial on a laptop picks up whatever else the machine was doing.
//!
//! The real clock here is `std.Io.Clock`, not the `platform.getRealTime` an application
//! injects — reaching the platform facade would pull a windowing backend into a benchmark
//! that wants no display. The two are different monotonic clocks, so treat this row as the
//! order of magnitude rather than the exact figure, and settle the question the way the
//! performance rules require anyway: by measuring the application's real frame rate with the
//! profiler forced off and on (`KNGN_FRAME_PROF=0` and `=1`).

const std = @import("std");
const frame_prof = @import("frame_prof");

/// Eleven sections, matching the pixel editor's frame body — the larger of the two wired
/// applications, so this is the upper end of what a mark sequence costs today.
const Section = enum {
    begin,
    events,
    ui_build,
    overlays_pre,
    clear,
    checker,
    composite,
    canvas_blit,
    overlays_post,
    gui_render,
    present,
};

/// A clock that costs a load and an add, so the enabled-versus-disabled difference isolates
/// the profiler's own arithmetic from the cost of reading a real clock.
var scripted: f64 = 0;
fn scriptedClock() f64 {
    scripted += 0.001;
    return scripted;
}

var real_io: std.Io = undefined;
fn realClock() f64 {
    const ns = std.Io.Clock.Timestamp.now(real_io, .awake).raw.nanoseconds;
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}

const Scripted = frame_prof.Profiler(Section, scriptedClock);
const Real = frame_prof.Profiler(Section, realClock);

const frames_per_trial = 20_000;
const trials = 9;

fn oneFrame(comptime P: type) void {
    P.begin();
    P.mark(.begin);
    P.mark(.events);
    P.mark(.ui_build);
    P.mark(.overlays_pre);
    P.mark(.clear);
    P.mark(.checker);
    P.mark(.composite);
    P.mark(.canvas_blit);
    P.mark(.overlays_post);
    P.mark(.gui_render);
    P.end(.present);
}

/// Nanoseconds per frame, taken as the median trial.
///
/// The digest is read at the end of every trial and folded into a checksum the caller prints,
/// so neither the accumulators nor the calls that fill them can be optimised out — without
/// that, "disabled" would measure an empty loop and "enabled" would measure dead stores.
fn measure(comptime P: type, io: std.Io, enabled: bool, checksum: *u64) u64 {
    var results: [trials]u64 = undefined;
    for (0..trials + 1) |t| {
        P.setEnabledForTest(enabled);
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        for (0..frames_per_trial) |_| oneFrame(P);
        const ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);

        var buf: [1024]u8 = undefined;
        var ctx: u8 = 0;
        const line = P.probeDigest(@ptrCast(&ctx), &buf);
        for (line) |c| checksum.* = checksum.* *% 31 +% c;

        if (t == 0) continue; // warm up
        results[t - 1] = ns / frames_per_trial;
    }
    P.setEnabledForTest(null);
    std.mem.sort(u64, &results, {}, std.sort.asc(u64));
    return results[trials / 2];
}

pub fn main(init: std.process.Init) !void {
    real_io = init.io;
    var checksum: u64 = 0;

    const off = measure(Scripted, init.io, false, &checksum);
    const on_scripted = measure(Scripted, init.io, true, &checksum);
    const on_real = measure(Real, init.io, true, &checksum);

    std.debug.print(
        \\frame_prof: one begin + {d} marks + end, {d} frames per trial, median of {d} trials
        \\
    , .{ @typeInfo(Section).@"enum".fields.len - 1, frames_per_trial, trials });
    std.debug.print("  disabled                {d:>6} ns/frame\n", .{off});
    std.debug.print("  enabled, scripted clock {d:>6} ns/frame  (bookkeeping only)\n", .{on_scripted});
    std.debug.print("  enabled, real clock     {d:>6} ns/frame  (what a profiled run pays)\n", .{on_real});
    std.debug.print(
        "  cost of measuring       {d:>6} ns/frame  = {d:.4} ms, against a frame body of a few ms\n",
        .{ on_real - off, @as(f64, @floatFromInt(on_real - off)) / std.time.ns_per_ms },
    );
    std.mem.doNotOptimizeAway(checksum);
}
