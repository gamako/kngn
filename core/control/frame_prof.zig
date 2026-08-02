//! Per-section frame timing for the observation plane.
//!
//! An application splits its frame body into named sections and this module reports, as one
//! line of `k=v`, how long each one took — plus the two numbers without which those section
//! values cannot be read: **the frame body total and the time spent outside it**.
//!
//! ## Why the totals are mandatory
//!
//! A section's cost is not a measure of how much work it does. The processor runs at
//! different rates depending on how idle the frame loop is, and the effect is large: holding
//! the work fixed and only lengthening the gap between frames moves a section's measured
//! time by several times. A reader given `ui_build=612us` alone cannot tell whether the work
//! grew or the loop merely got slower. Given `body_ms` and `gap_ms` next to it, they can.
//! `docs/performance-measurement.md` has the measurements behind this.
//!
//! ## The model
//!
//! - `begin()` starts the frame body. It only starts the clock; it closes no section.
//! - `mark(s)` closes section `s`: everything since the previous mark (or `begin`) is added
//!   to `s`.
//! - `end(s)` closes the last section `s` and completes the frame. Requiring a section here
//!   is what makes `sum(sections) == body` hold by construction — there is no unattributed
//!   tail.
//! - A frame that never reaches `end` is **aborted** and contributes nothing. The next
//!   `begin` notices and counts it. Callers need no special code for this: the paths that
//!   return early (a framebuffer lock that yields nothing, an error on the way to present)
//!   simply never reach `end`.
//!
//! Skipping a `mark` is not the same as a section costing nothing. A section only reads zero
//! when its own `mark` is skipped; the elapsed time then lands in the next mark that does
//! run. Put each `mark` immediately after the work it closes, and put the last mark of a
//! conditional group outside the branch, so that skipping the branch gives the group zeros
//! rather than moving its time somewhere misleading.
//!
//! ## Statistics
//!
//! Every reported average comes from **the same set of frames**, so
//! `frame_ms == body_ms + gap_ms` holds (up to floating-point and display rounding). Two
//! kinds of frame are left out of that set, because neither has a well-defined period:
//! the first completed frame after a reset, and the frame following an abort.
//!
//! ## The clock
//!
//! The caller injects it, and it must be a **real** monotonic clock — `platform.getRealTime`,
//! not `platform.getTime`. Under a replay the latter is the harness's virtual clock, which
//! would report every section as zero and every frame as exactly one virtual tick.
//!
//! Hot path declaration: `begin` / `mark` / `end` run **once per frame each** (they are not
//! per-pixel and they are never called from the real-time audio path). Each does one clock
//! read and a few f64 adds. While disabled they return on a single boolean test.

const std = @import("std");
const harness = @import("harness");
const frame_prof = @This();

/// Selects the profiler independently of the harness.
///
/// | value | effect |
/// |---|---|
/// | `1` | on |
/// | `0` | off, even while the harness is enabled |
/// | unset, or anything else | follow the harness |
///
/// The explicit `0` exists so that a run can read frame rate through the harness while
/// leaving the profiler out — without it there is no way to measure what the profiler costs.
pub const env_var = "KNGN_FRAME_PROF";

/// The probe name to register with `platform.registerProbe`.
pub const probe_name = "frameprof";

/// The action name to register with `platform.registerAction`.
pub const reset_action_name = "frameprof_reset";

/// How many recent body samples the percentile reads. Unlike every other statistic, which
/// covers the whole window since the last reset, `body_p95_ms` covers only this many frames.
pub const percentile_window = 256;

/// Reserved at the front of the digest budget so the truncation marker itself can never be
/// the thing that overflows.
const truncated_suffix = " truncated=1";

/// A frame profiler over `Section`, reading time from `clock` (seconds).
///
/// `Section` is a plain enum whose tags name the sections; the digest uses `@tagName`, so
/// adding a section cannot renumber the others. State is module-level, one set per
/// instantiation — the same single-process assumption the harness and the probe registry
/// make.
pub fn Profiler(comptime Section: type, comptime clock: *const fn () f64) type {
    const info = @typeInfo(Section);
    if (info != .@"enum") @compileError("frame_prof.Profiler: Section must be an enum");
    const fields = info.@"enum".fields;
    if (fields.len == 0) @compileError("frame_prof.Profiler: Section must have at least one tag");
    for (fields, 0..) |f, i| {
        if (f.value != i) @compileError(
            "frame_prof.Profiler: Section tag '" ++ f.name ++
                "' has an explicit value; sections index the accumulator array, so the tags must be 0..n-1",
        );
    }

    return struct {
        const n_sections = fields.len;

        /// Re-exported so a caller names the probe and the action through the same symbol it
        /// takes the callbacks from, and two applications cannot drift apart on the name.
        pub const probe_name = frame_prof.probe_name;
        pub const reset_action_name = frame_prof.reset_action_name;

        var enabled_override: ?bool = null;
        var enabled_cache: ?bool = null;

        // In-flight frame.
        var active: bool = false;
        var t_begin: f64 = 0;
        var t_mark: f64 = 0;
        var cur: [n_sections]f64 = @splat(0);

        // Frame-to-frame linkage.
        var have_prev_end: bool = false;
        var t_prev_end: f64 = 0;
        /// Set when the next completed frame only re-establishes the baseline (its period
        /// would span an aborted frame).
        var skip_next: bool = false;

        // Window accumulators.
        var frames: u64 = 0;
        var aborted: u64 = 0;
        var body_sum: f64 = 0;
        var body_max: f64 = 0;
        var gap_sum: f64 = 0;
        var sec_sum: [n_sections]f64 = @splat(0);

        var ring: [percentile_window]f64 = @splat(0);
        var ring_len: usize = 0;
        var ring_head: usize = 0;

        /// Whether measurement is on. Decided once and cached (see `env_var`).
        pub fn isEnabled() bool {
            if (enabled_cache) |e| return e;
            const e = decide();
            enabled_cache = e;
            return e;
        }

        fn decide() bool {
            if (enabled_override) |o| return o;
            return decideFrom(harness.readEnv(env_var), harness.isEnabled());
        }

        /// Force measurement on or off; `null` restores the `env_var` decision and
        /// re-evaluates it on the next call.
        ///
        /// **A test and benchmark seam. Application code must not call it** — the whole point
        /// of the environment variable is that a run's configuration is visible from outside
        /// the process. Switching always clears the window, because a window holding both
        /// measured and unmeasured frames means nothing, and drops any frame in flight
        /// without counting it as aborted (that frame was interrupted by the switch, not by
        /// the application).
        pub fn setEnabledForTest(v: ?bool) void {
            enabled_override = v;
            enabled_cache = null;
            reset();
        }

        /// Start the frame body.
        pub fn begin() void {
            if (!isEnabled()) return;
            if (active) {
                // The previous frame never reached end(): it did not present.
                aborted += 1;
                skip_next = true;
            }
            const t = clock();
            active = true;
            t_begin = t;
            t_mark = t;
            cur = @splat(0);
        }

        /// Close section `s`.
        pub fn mark(comptime s: Section) void {
            if (!active) return;
            const t = clock();
            cur[@intFromEnum(s)] += t - t_mark;
            t_mark = t;
        }

        /// Close the last section `s` and complete the frame.
        pub fn end(comptime s: Section) void {
            if (!active) return;
            const t = clock();
            cur[@intFromEnum(s)] += t - t_mark;
            active = false;

            const body = t - t_begin;
            if (have_prev_end and !skip_next) {
                frames += 1;
                body_sum += body;
                if (body > body_max) body_max = body;
                gap_sum += t_begin - t_prev_end;
                for (&sec_sum, cur) |*acc, v| acc.* += v;
                ring[ring_head] = body;
                ring_head = (ring_head + 1) % percentile_window;
                if (ring_len < percentile_window) ring_len += 1;
            }
            skip_next = false;
            have_prev_end = true;
            t_prev_end = t;
        }

        /// Drop the window and every frame-to-frame baseline. The next completed frame is
        /// again the excluded first one.
        pub fn reset() void {
            active = false;
            have_prev_end = false;
            skip_next = false;
            frames = 0;
            aborted = 0;
            body_sum = 0;
            body_max = 0;
            gap_sum = 0;
            sec_sum = @splat(0);
            cur = @splat(0);
            ring_len = 0;
            ring_head = 0;
        }

        /// The 95th percentile of the recent body samples, nearest-rank, in seconds.
        fn bodyP95() f64 {
            if (ring_len == 0) return 0;
            var scratch: [percentile_window]f64 = undefined;
            const sorted = scratch[0..ring_len];
            @memcpy(sorted, ring[0..ring_len]);
            std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
            // Nearest-rank: the smallest value at or above 95% of the samples.
            const rank = (ring_len * 95 + 99) / 100; // ceil(0.95 * n)
            const idx = @min(if (rank == 0) 0 else rank - 1, ring_len - 1);
            return sorted[idx];
        }

        /// One line of `k=v` for `digest <probe_name>`. Matches `Probe.digest`; `ctx` is
        /// unused because the state is module-level.
        ///
        /// With no frames in the window it reports `frames=0` and the abort count and stops.
        /// Emitting zeroed averages instead would let `expect frameprof body_ms<16.7` read
        /// "no data" as "fast"; a missing key fails the assertion, which is the honest
        /// outcome.
        pub fn probeDigest(ctx: *anyopaque, buf: []u8) []const u8 {
            _ = ctx;
            if (buf.len <= truncated_suffix.len) return buf[0..0];
            const limit = buf.len - truncated_suffix.len;
            var w = Line{ .buf = buf, .limit = limit };

            _ = w.put("frames={d} aborted={d}", .{ frames, aborted });
            if (frames > 0) {
                const f: f64 = @floatFromInt(frames);
                const body = body_sum / f;
                const gap = gap_sum / f;
                _ = w.put(" frame_ms={d:.3} body_ms={d:.3} gap_ms={d:.3}", .{
                    ms(body + gap), ms(body), ms(gap),
                });
                _ = w.put(" body_p95_ms={d:.3} body_max_ms={d:.3}", .{ ms(bodyP95()), ms(body_max) });
                inline for (fields, 0..) |sec, i| {
                    if (!w.put(" " ++ sec.name ++ "={d:.3}", .{ms(sec_sum[i] / f)})) break;
                }
            }
            if (w.truncated) {
                @memcpy(buf[w.n..][0..truncated_suffix.len], truncated_suffix);
                w.n += truncated_suffix.len;
            }
            return buf[0..w.n];
        }

        /// `action <reset_action_name>`: drop the window. Matches `Action.run`.
        pub fn resetAction(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
            _ = ctx;
            _ = args;
            reset();
            return std.fmt.bufPrint(buf, "{s} reset ok", .{frame_prof.probe_name});
        }
    };
}

/// The `env_var` rule, as a pure function of the variable's value and the harness state.
/// Only `"1"` and `"0"` mean anything; every other value is treated as unset, matching how
/// `KNGN_HEADLESS` reads only `"1"`.
fn decideFrom(env: ?[]const u8, harness_on: bool) bool {
    if (env) |v| {
        if (std.mem.eql(u8, v, "1")) return true;
        if (std.mem.eql(u8, v, "0")) return false;
    }
    return harness_on;
}

fn ms(seconds: f64) f64 {
    return seconds * 1000.0;
}

/// Appends to a fixed buffer and remembers whether anything did not fit.
const Line = struct {
    buf: []u8,
    limit: usize,
    n: usize = 0,
    truncated: bool = false,

    fn put(self: *Line, comptime fmt: []const u8, args: anytype) bool {
        if (self.truncated) return false;
        const written = std.fmt.bufPrint(self.buf[self.n..self.limit], fmt, args) catch {
            self.truncated = true;
            return false;
        };
        self.n += written.len;
        return true;
    }
};

// ============================================================================
// tests (a scripted clock, so every statistic has an exact expected value)
// ============================================================================

const testing = std.testing;

var test_clock: f64 = 0;
fn testClock() f64 {
    return test_clock;
}

const TestSection = enum { a, b, c };
const TestProf = Profiler(TestSection, testClock);

/// Runs one frame: `a` for `da` seconds, `b` for `db`, `c` for `dc`.
fn runFrame(da: f64, db: f64, dc: f64) void {
    TestProf.begin();
    test_clock += da;
    TestProf.mark(.a);
    test_clock += db;
    TestProf.mark(.b);
    test_clock += dc;
    TestProf.end(.c);
}

fn field(payload: []const u8, key: []const u8) ?f64 {
    var it = std.mem.splitScalar(u8, payload, ' ');
    while (it.next()) |tok| {
        const eq = std.mem.indexOfScalar(u8, tok, '=') orelse continue;
        if (std.mem.eql(u8, tok[0..eq], key)) return std.fmt.parseFloat(f64, tok[eq + 1 ..]) catch null;
    }
    return null;
}

fn digestNow(buf: []u8) []const u8 {
    var dummy: u8 = 0;
    return TestProf.probeDigest(@ptrCast(&dummy), buf);
}

fn startTest() void {
    test_clock = 0;
    TestProf.setEnabledForTest(true);
}

test "only 1 and 0 decide; anything else follows the harness" {
    try testing.expect(decideFrom("1", false));
    try testing.expect(!decideFrom("0", true));
    try testing.expect(decideFrom(null, true));
    try testing.expect(!decideFrom(null, false));
    for ([_][]const u8{ "true", "2", "", "yes", "01", " 1" }) |v| {
        try testing.expect(decideFrom(v, true));
        try testing.expect(!decideFrom(v, false));
    }
}

test "disabled: nothing is recorded and the digest reports an empty window" {
    TestProf.setEnabledForTest(false);
    defer TestProf.setEnabledForTest(null);
    test_clock = 0;
    runFrame(0.001, 0.002, 0.003);
    runFrame(0.001, 0.002, 0.003);

    var buf: [harness.DIGEST_BUF_LEN]u8 = undefined;
    const line = digestNow(&buf);
    try testing.expectEqualStrings("frames=0 aborted=0", line);
}

test "the first completed frame is excluded, so every average shares one sample set" {
    startTest();
    defer TestProf.setEnabledForTest(null);

    runFrame(0.001, 0.002, 0.003); // excluded: no previous end to measure a period against
    var buf: [harness.DIGEST_BUF_LEN]u8 = undefined;
    try testing.expectEqualStrings("frames=0 aborted=0", digestNow(&buf));

    test_clock += 0.004; // gap
    runFrame(0.001, 0.002, 0.003);

    const line = digestNow(&buf);
    try testing.expectEqual(@as(f64, 1), field(line, "frames").?);
    try testing.expectApproxEqAbs(@as(f64, 6), field(line, "body_ms").?, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 4), field(line, "gap_ms").?, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 10), field(line, "frame_ms").?, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 1), field(line, "a").?, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 2), field(line, "b").?, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 3), field(line, "c").?, 1e-6);
}

test "frame_ms equals body_ms plus gap_ms, and the sections sum to the body" {
    startTest();
    defer TestProf.setEnabledForTest(null);

    const bodies = [_][3]f64{
        .{ 0.001, 0.002, 0.003 },
        .{ 0.004, 0.001, 0.002 },
        .{ 0.002, 0.002, 0.002 },
        .{ 0.005, 0.003, 0.001 },
    };
    const gaps = [_]f64{ 0.004, 0.009, 0.002, 0.007 };
    runFrame(0.001, 0.001, 0.001); // the excluded first frame
    for (bodies, gaps) |b, g| {
        test_clock += g;
        runFrame(b[0], b[1], b[2]);
    }

    var buf: [harness.DIGEST_BUF_LEN]u8 = undefined;
    const line = digestNow(&buf);
    const body = field(line, "body_ms").?;
    const gap = field(line, "gap_ms").?;
    const frame = field(line, "frame_ms").?;
    try testing.expectApproxEqAbs(frame, body + gap, 1e-3);

    const sections = field(line, "a").? + field(line, "b").? + field(line, "c").?;
    try testing.expectApproxEqAbs(body, sections, 1e-3);
}

test "a skipped mark leaves its section at zero and the body still adds up" {
    startTest();
    defer TestProf.setEnabledForTest(null);

    // Frame shape: `a` always runs, `b` is conditional and skipped, `c` closes the frame.
    for (0..3) |_| {
        test_clock += 0.005;
        TestProf.begin();
        test_clock += 0.001;
        TestProf.mark(.a);
        test_clock += 0.002; // the work `b` would have closed, had its mark run
        TestProf.end(.c);
    }

    var buf: [harness.DIGEST_BUF_LEN]u8 = undefined;
    const line = digestNow(&buf);
    try testing.expectApproxEqAbs(@as(f64, 0), field(line, "b").?, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), field(line, "a").?, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 2), field(line, "c").?, 1e-6);
    const sections = field(line, "a").? + field(line, "b").? + field(line, "c").?;
    try testing.expectApproxEqAbs(field(line, "body_ms").?, sections, 1e-6);
}

test "an aborted frame is counted, and the frame after it is excluded" {
    const Case = struct {
        name: []const u8,
        /// true = a completed frame, false = a frame that begins and never ends.
        script: []const bool,
        frames: u64,
        aborted: u64,
    };
    const cases = [_]Case{
        // The first completed frame is always the excluded baseline.
        .{ .name = "all complete", .script = &.{ true, true, true }, .frames = 2, .aborted = 0 },
        .{ .name = "one abort", .script = &.{ true, false, true, true }, .frames = 1, .aborted = 1 },
        .{ .name = "consecutive aborts", .script = &.{ true, false, false, true, true }, .frames = 1, .aborted = 2 },
        .{ .name = "abort first", .script = &.{ false, true, true }, .frames = 1, .aborted = 1 },
    };
    for (cases) |c| {
        startTest();
        for (c.script) |completes| {
            test_clock += 0.004;
            TestProf.begin();
            test_clock += 0.001;
            TestProf.mark(.a);
            if (!completes) continue; // the early-return path: no end()
            test_clock += 0.001;
            TestProf.end(.c);
        }
        var buf: [harness.DIGEST_BUF_LEN]u8 = undefined;
        const line = digestNow(&buf);
        testing.expectEqual(c.frames, @as(u64, @intFromFloat(field(line, "frames").?))) catch |e| {
            std.debug.print("case '{s}': {s}\n", .{ c.name, line });
            return e;
        };
        testing.expectEqual(c.aborted, @as(u64, @intFromFloat(field(line, "aborted").?))) catch |e| {
            std.debug.print("case '{s}': {s}\n", .{ c.name, line });
            return e;
        };
    }
    TestProf.setEnabledForTest(null);
}

test "the identity survives an abort: the baseline is the previous completed frame" {
    startTest();
    defer TestProf.setEnabledForTest(null);

    runFrame(0.001, 0.001, 0.001); // excluded baseline
    test_clock += 0.003;
    TestProf.begin(); // aborted
    test_clock += 0.002;
    TestProf.mark(.a);
    test_clock += 0.006;
    runFrame(0.001, 0.001, 0.001); // completes, but its period spans the abort → excluded
    test_clock += 0.005;
    runFrame(0.002, 0.002, 0.002); // the only frame in the window

    var buf: [harness.DIGEST_BUF_LEN]u8 = undefined;
    const line = digestNow(&buf);
    try testing.expectEqual(@as(f64, 1), field(line, "frames").?);
    try testing.expectEqual(@as(f64, 1), field(line, "aborted").?);
    try testing.expectApproxEqAbs(@as(f64, 6), field(line, "body_ms").?, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 5), field(line, "gap_ms").?, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 11), field(line, "frame_ms").?, 1e-6);
}

test "body_max is the largest body and body_p95 is the nearest-rank sample" {
    startTest();
    defer TestProf.setEnabledForTest(null);

    runFrame(0.001, 0, 0); // excluded baseline
    // Twenty bodies of 1..20 ms. ceil(0.95 * 20) = 19 → the 19th smallest = 19 ms.
    for (1..21) |i| {
        test_clock += 0.001;
        runFrame(@as(f64, @floatFromInt(i)) / 1000.0, 0, 0);
    }

    var buf: [harness.DIGEST_BUF_LEN]u8 = undefined;
    const line = digestNow(&buf);
    try testing.expectApproxEqAbs(@as(f64, 20), field(line, "body_max_ms").?, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 19), field(line, "body_p95_ms").?, 1e-6);
}

test "nearest-rank rounds up: with two samples the percentile is the larger one" {
    startTest();
    defer TestProf.setEnabledForTest(null);

    runFrame(0.001, 0, 0); // excluded baseline
    // ceil(0.95 * 2) = 2, so the answer is the second smallest. Truncating instead of
    // rounding up would pick the first and report 3 ms.
    test_clock += 0.001;
    runFrame(0.003, 0, 0);
    test_clock += 0.001;
    runFrame(0.007, 0, 0);

    var buf: [harness.DIGEST_BUF_LEN]u8 = undefined;
    const line = digestNow(&buf);
    try testing.expectApproxEqAbs(@as(f64, 7), field(line, "body_p95_ms").?, 1e-6);
}

test "the percentile follows the ring, the maximum follows the whole window" {
    startTest();
    defer TestProf.setEnabledForTest(null);

    runFrame(0.001, 0, 0); // excluded baseline
    // Bodies of 1..300 ms. The ring keeps the last 256 of them, 45..300 ms, and
    // ceil(0.95 * 256) = 244 selects the 244th smallest of those: 288 ms. A percentile taken
    // over the whole window instead would answer 285.
    for (1..301) |i| {
        test_clock += 0.001;
        runFrame(@as(f64, @floatFromInt(i)) / 1000.0, 0, 0);
    }

    var buf: [harness.DIGEST_BUF_LEN]u8 = undefined;
    const line = digestNow(&buf);
    try testing.expectEqual(@as(f64, 300), field(line, "frames").?);
    try testing.expectApproxEqAbs(@as(f64, 288), field(line, "body_p95_ms").?, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 300), field(line, "body_max_ms").?, 1e-6);
}

test "reset drops the window, the abort count and every baseline" {
    startTest();
    defer TestProf.setEnabledForTest(null);

    runFrame(0.001, 0.001, 0.001);
    test_clock += 0.002;
    TestProf.begin(); // will be aborted by the next begin
    test_clock += 0.001;
    runFrame(0.001, 0.001, 0.001);
    test_clock += 0.002;
    runFrame(0.001, 0.001, 0.001);

    var buf: [harness.DIGEST_BUF_LEN]u8 = undefined;
    try testing.expect(field(digestNow(&buf), "aborted").? > 0);

    var dummy: u8 = 0;
    const reply = try TestProf.resetAction(@ptrCast(&dummy), "", &buf);
    try testing.expectEqualStrings("frameprof reset ok", reply);
    try testing.expectEqualStrings("frames=0 aborted=0", digestNow(&buf));

    // The first frame after a reset is the excluded baseline again.
    test_clock += 0.002;
    runFrame(0.001, 0.001, 0.001);
    try testing.expectEqualStrings("frames=0 aborted=0", digestNow(&buf));
    test_clock += 0.002;
    runFrame(0.001, 0.001, 0.001);
    try testing.expectEqual(@as(f64, 1), field(digestNow(&buf), "frames").?);
}

test "a section count that does not fit is truncated inside the digest budget" {
    const Wide = enum {
        section_name_00,
        section_name_01,
        section_name_02,
        section_name_03,
        section_name_04,
        section_name_05,
        section_name_06,
        section_name_07,
        section_name_08,
        section_name_09,
        section_name_10,
        section_name_11,
        section_name_12,
        section_name_13,
        section_name_14,
        section_name_15,
        section_name_16,
        section_name_17,
        section_name_18,
        section_name_19,
        section_name_20,
        section_name_21,
        section_name_22,
        section_name_23,
        section_name_24,
        section_name_25,
        section_name_26,
        section_name_27,
        section_name_28,
        section_name_29,
        section_name_30,
        section_name_31,
        section_name_32,
        section_name_33,
        section_name_34,
        section_name_35,
        section_name_36,
        section_name_37,
        section_name_38,
        section_name_39,
        section_name_40,
        section_name_41,
        section_name_42,
        section_name_43,
        section_name_44,
        section_name_45,
        section_name_46,
        section_name_47,
        section_name_48,
        section_name_49,
    };
    const Wp = Profiler(Wide, testClock);
    Wp.setEnabledForTest(true);
    defer Wp.setEnabledForTest(null);
    test_clock = 0;
    for (0..2) |_| {
        test_clock += 0.001;
        Wp.begin();
        test_clock += 0.001;
        Wp.end(.section_name_00);
    }

    var dummy: u8 = 0;
    var buf: [harness.DIGEST_BUF_LEN]u8 = undefined;
    const line = Wp.probeDigest(@ptrCast(&dummy), &buf);
    try testing.expect(line.len <= harness.DIGEST_BUF_LEN);
    try testing.expect(std.mem.endsWith(u8, line, truncated_suffix));
    try testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, line, '\n'));
}

test "a digest that fits carries no truncation marker" {
    startTest();
    defer TestProf.setEnabledForTest(null);
    runFrame(0.001, 0.001, 0.001);
    test_clock += 0.001;
    runFrame(0.001, 0.001, 0.001);

    var buf: [harness.DIGEST_BUF_LEN]u8 = undefined;
    const line = digestNow(&buf);
    try testing.expect(line.len <= harness.DIGEST_BUF_LEN);
    try testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, line, truncated_suffix));
    try testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, line, '\n'));
}

test "section names come from the enum, so adding one does not renumber the rest" {
    const Before = enum { alpha, beta };
    const After = enum { alpha, inserted, beta };
    test_clock = 0;
    const B = Profiler(Before, testClock);
    B.setEnabledForTest(true);
    for (0..2) |_| {
        test_clock += 0.001;
        B.begin();
        test_clock += 0.002;
        B.mark(.alpha);
        test_clock += 0.003;
        B.end(.beta);
    }
    var dummy: u8 = 0;
    var buf_b: [harness.DIGEST_BUF_LEN]u8 = undefined;
    const line_b = B.probeDigest(@ptrCast(&dummy), &buf_b);
    B.setEnabledForTest(null);

    test_clock = 0;
    const A = Profiler(After, testClock);
    A.setEnabledForTest(true);
    for (0..2) |_| {
        test_clock += 0.001;
        A.begin();
        test_clock += 0.002;
        A.mark(.alpha);
        test_clock += 0.003;
        A.end(.beta);
    }
    var buf_a: [harness.DIGEST_BUF_LEN]u8 = undefined;
    const line_a = A.probeDigest(@ptrCast(&dummy), &buf_a);
    A.setEnabledForTest(null);

    try testing.expectApproxEqAbs(field(line_b, "alpha").?, field(line_a, "alpha").?, 1e-9);
    try testing.expectApproxEqAbs(field(line_b, "beta").?, field(line_a, "beta").?, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), field(line_a, "inserted").?, 1e-9);
}
