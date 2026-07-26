//! The pure frame pacing logic. It is independent of the OS, the display and platform, so it is unit testable.
//!
//! **Hot path declaration: per frame (once per frame)**. It is neither an all-pixel loop nor a real-time (per-sample) path.
//! The added cost is a few f64 operations plus two or three clock reads, negligible against a frame budget measured in ms.
//!
//! ## Why a deadline plus a correction rather than a fixed sleep (measured on Apple Silicon, ReleaseFast)
//!
//! The mean overshoot and effective fps over 300 iterations at a target period of 16.667ms:
//!
//! | Method | Mean overshoot | Effective fps |
//! |---|---|---|
//! | `nanosleep` (relative) | 3.40ms | 49.8 |
//! | `mach_wait_until` (absolute time) | 3.45ms | 49.7 |
//! | absolute time plus a final 1.5ms busy-wait | 1.69ms | 54.5 |
//! | **overshoot EWMA correction (no busy-wait)** | **-0.10ms** | **60.4** |
//!
//! macOS's overshoot is proportional to roughly 20% of the requested time (timer slack), and **an absolute-time sleep does not remove it**.
//! So the approach is to learn the measured overshoot with an EWMA and subtract it from the request (busy-wait is not used:
//! spinning all the while shifts the mean error towards +0.6ms and lowers fps).
//!
//! The caller (`core/platform.zig`) injects the clock and the sleep into `Driver(clock, sleeper)` at comptime.
//! The tests inject a fake clock and sleep, and assert directly on the requested sleep, the call count and the learned state.

const std = @import("std");

/// The fixed margin for waking early (it absorbs the error in what has been learned).
pub const MARGIN_NS: u64 = 200_000; // 200µs
/// The upper bound on the overshoot estimate. It stops one huge oversleep from wrecking the estimate and stalling pacing forever.
pub const MAX_EST_NS: u64 = 4_000_000; // 4ms
/// A remaining time above this is taken to be a clock jump or a wake from sleep, and resets what has been learned.
pub const MAX_REMAINING_S: f64 = 1.0;
/// The EWMA weight (1/8).
const EWMA_SHIFT: u6 = 3;

/// The result of a pacing decision. Carrying it out (the sleep) is the Driver's job.
pub const Decision = union(enum) {
    /// Do not wait (the deadline has passed, or the input was not finite)
    no_wait,
    /// Reset what has been learned and do not wait (a clock jump or a wake from sleep was detected)
    reset,
    /// Request a sleep of exactly this many ns (0 means "do not sleep, but still decay what has been learned")
    sleep: u64,
};

/// The requested sleep = remaining - (the estimated overshoot + the margin), with a floor of 0.
pub fn requestNs(remaining_ns: u64, est_ns: u64, margin_ns: u64) u64 {
    const deduct = est_ns +| margin_ns;
    if (remaining_ns <= deduct) return 0;
    return remaining_ns - deduct;
}

/// The EWMA update of the overshoot estimate.
/// - The overshoot is `actual - request` (not the other way round). A negative value (waking early) counts as 0.
/// - `request == 0` (a frame that did not sleep) has nothing to observe, so **the estimate is halved** to guarantee recovery.
/// - It is clamped at `MAX_EST_NS` (the safeguard that stops an outlier stalling pacing forever).
pub fn updateEwma(prev_ns: u64, request_ns: u64, actual_ns: u64) u64 {
    if (request_ns == 0) return prev_ns / 2;
    const observed: u64 = if (actual_ns > request_ns) actual_ns - request_ns else 0;
    const clamped = @min(observed, MAX_EST_NS);
    const next = if (clamped >= prev_ns)
        prev_ns + ((clamped - prev_ns) >> EWMA_SHIFT)
    else
        prev_ns - ((prev_ns - clamped) >> EWMA_SHIFT);
    return @min(next, MAX_EST_NS);
}

/// The pacing decision (the input guards live here too, as the single window an implementation cannot bypass).
/// deadline and now are seconds on a monotonic clock. **They are checked while still f64 and only then converted to ns**
/// (converting to an integer first would trap on Inf or on a huge value).
pub fn decide(deadline_s: f64, now_s: f64, est_ns: u64) Decision {
    if (!std.math.isFinite(deadline_s) or !std.math.isFinite(now_s)) return .no_wait;
    const remaining_s = deadline_s - now_s;
    if (!(remaining_s > 0)) return .no_wait; // false even when a NaN gets in
    if (remaining_s > MAX_REMAINING_S) return .reset;
    const remaining_ns: u64 = @intFromFloat(remaining_s * 1_000_000_000.0);
    return .{ .sleep = requestNs(remaining_ns, est_ns, MARGIN_NS) };
}

/// What has been learned (owned by the main thread; never touched from a real-time thread).
pub const Pacer = struct {
    est_overshoot_ns: u64 = 0,

    pub fn reset(self: *Pacer) void {
        self.est_overshoot_ns = 0;
    }
};

/// The pacing executor, with the clock (returning seconds) and the sleep (taking a request in ns) injected at comptime.
/// They are comptime parameters so that no indirect call is created.
pub fn Driver(comptime clock: fn () f64, comptime sleeper: fn (u64) void) type {
    return struct {
        /// Waits best-effort towards `deadline_s`. With `manual_clock=true` (a harness replay, say) it is
        /// **a complete no-op** (it neither reads the clock nor touches what has been learned).
        pub fn pace(pacer: *Pacer, deadline_s: f64, manual_clock: bool) void {
            if (manual_clock) return;
            const before = clock();
            switch (decide(deadline_s, before, pacer.est_overshoot_ns)) {
                .no_wait => {},
                .reset => pacer.reset(),
                .sleep => |request_ns| {
                    if (request_ns == 0) {
                        // Decay the estimate even on a frame that does not sleep (the recovery path).
                        pacer.est_overshoot_ns = updateEwma(pacer.est_overshoot_ns, 0, 0);
                        return;
                    }
                    // The real sleep time is measured as the difference **immediately before and after** the sleep, so the cost of deciding and of updating what is learned is not mixed in.
                    const t0 = clock();
                    sleeper(request_ns);
                    const t1 = clock();
                    const actual_ns: u64 = if (t1 > t0)
                        @intFromFloat(@min((t1 - t0) * 1_000_000_000.0, 1e12))
                    else
                        0;
                    pacer.est_overshoot_ns = updateEwma(pacer.est_overshoot_ns, request_ns, actual_ns);
                },
            }
        }
    };
}

// ============================================================================
// tests (independent of display and OS; a fake clock and sleep are injected to pin the behaviour down)
// ============================================================================

test "requestNs subtracts est+margin from remaining (floored at 0, and never overflowing)" {
    try std.testing.expectEqual(@as(u64, 13_466_666), requestNs(16_666_666, 3_000_000, 200_000));
    try std.testing.expectEqual(@as(u64, 0), requestNs(3_200_000, 3_000_000, 200_000));
    try std.testing.expectEqual(@as(u64, 0), requestNs(1_000_000, 3_000_000, 200_000));
    try std.testing.expectEqual(@as(u64, 0), requestNs(0, 0, 200_000));
    // a saturating add, so it cannot overflow
    try std.testing.expectEqual(@as(u64, 0), requestNs(std.math.maxInt(u64) - 1, std.math.maxInt(u64), 200_000));
}

test "updateEwma learns overshoot=actual-request and counts waking early as 0" {
    // The direction: the overshoot is the amount by which actual exceeds request (not request minus actual)
    try std.testing.expectEqual(@as(u64, 375_000), updateEwma(0, 10_000_000, 13_000_000));
    // waking early (actual < request) gives observed=0, so it falls an eighth of the way down from prev
    try std.testing.expectEqual(@as(u64, 875_000), updateEwma(1_000_000, 10_000_000, 9_000_000));
    // feeding a constant overshoot converges on that value
    var est: u64 = 0;
    for (0..200) |_| est = updateEwma(est, 10_000_000, 13_000_000);
    try std.testing.expect(est > 2_900_000 and est <= 3_000_000);
}

test "updateEwma clamps at the upper bound and always recovers when request==0 (so it never stalls forever)" {
    // even an outlier worth a 1 second oversleep does not exceed the 4ms bound
    try std.testing.expect(updateEwma(0, 10_000_000, 1_010_000_000) <= MAX_EST_NS);
    // once it is pinned at the bound, a run of frames that do not sleep halves it back down
    var est: u64 = MAX_EST_NS;
    var frames: u32 = 0;
    while (est > MARGIN_NS and frames < 32) : (frames += 1) est = updateEwma(est, 0, 0);
    try std.testing.expect(frames <= 6); // 4ms to 200µs is five halvings
    // after recovering, the remainder of 16.67ms again produces a sizeable sleep request
    try std.testing.expect(requestNs(16_666_666, est, MARGIN_NS) > 15_000_000);
}

test "decide's input guards (not finite, a deadline in the past, a clock jump)" {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    try std.testing.expectEqual(Decision.no_wait, decide(nan, 100.0, 0));
    try std.testing.expectEqual(Decision.no_wait, decide(100.0, nan, 0));
    try std.testing.expectEqual(Decision.no_wait, decide(inf, 100.0, 0)); // not finite takes priority over remaining>1s
    try std.testing.expectEqual(Decision.no_wait, decide(-inf, 100.0, 0));
    try std.testing.expectEqual(Decision.no_wait, decide(100.0, 100.0, 0)); // the same instant
    try std.testing.expectEqual(Decision.no_wait, decide(99.9, 100.0, 0)); // in the past
    try std.testing.expectEqual(Decision.reset, decide(101.5, 100.0, 0)); // over 1 second = a clock jump
    switch (decide(100.016_666_666, 100.0, 0)) { // the ordinary case
        .sleep => |ns| try std.testing.expect(ns > 16_000_000 and ns < 16_666_666),
        else => return error.TestUnexpectedResult,
    }
    switch (decide(100.001, 100.0, 4_000_000)) { // the estimate eats up the whole remainder
        .sleep => |ns| try std.testing.expectEqual(@as(u64, 0), ns),
        else => return error.TestUnexpectedResult,
    }
}

/// A fake clock and fake sleep for the tests. `sleeper` pretends that the requested ns plus overshoot_ns elapsed.
const Fake = struct {
    var now_s: f64 = 100.0;
    var overshoot_ns: u64 = 0;
    var sleep_calls: u32 = 0;
    var last_request_ns: u64 = 0;

    fn clock() f64 {
        return now_s;
    }
    fn sleeper(ns: u64) void {
        sleep_calls += 1;
        last_request_ns = ns;
        now_s += @as(f64, @floatFromInt(ns + overshoot_ns)) / 1e9;
    }
    fn reset(overshoot: u64) void {
        now_s = 100.0;
        overshoot_ns = overshoot;
        sleep_calls = 0;
        last_request_ns = 0;
    }
};
const FakeDriver = Driver(Fake.clock, Fake.sleeper);

test "Driver: under a manual clock neither the sleep nor the learning update happens" {
    Fake.reset(0);
    var pacer: Pacer = .{ .est_overshoot_ns = 1_234_567 };
    FakeDriver.pace(&pacer, Fake.now_s + 10.0, true); // a no-op even for a deadline far in the future
    try std.testing.expectEqual(@as(u32, 0), Fake.sleep_calls);
    try std.testing.expectEqual(@as(f64, 100.0), Fake.now_s); // it does not even read the clock (which therefore does not advance)
    try std.testing.expectEqual(@as(u64, 1_234_567), pacer.est_overshoot_ns);
}

test "Driver: it does not sleep for a deadline in the past or a clock jump (and reset clears what has been learned)" {
    Fake.reset(0);
    var pacer: Pacer = .{ .est_overshoot_ns = 3_000_000 };
    FakeDriver.pace(&pacer, Fake.now_s - 0.01, false); // in the past
    try std.testing.expectEqual(@as(u32, 0), Fake.sleep_calls);
    try std.testing.expectEqual(@as(u64, 3_000_000), pacer.est_overshoot_ns); // no_wait does not touch what has been learned

    FakeDriver.pace(&pacer, Fake.now_s + 5.0, false); // over 1 second = a clock jump
    try std.testing.expectEqual(@as(u32, 0), Fake.sleep_calls);
    try std.testing.expectEqual(@as(u64, 0), pacer.est_overshoot_ns); // reset
}

test "Driver: with 20% timer slack the mean period converges on the target (reproducing the measurement)" {
    // Reproduce the real machine's property (exceeding the request by 20%) with the fake sleep, and pin that it converges on the 60fps target.
    const period_s: f64 = 1.0 / 60.0;
    Fake.reset(0);
    var pacer: Pacer = .{};
    // The slack is 20% of the request, so a fixed value cannot express it; it is updated on each sleeper call instead
    var last_period_err_ns: i64 = 0;
    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        const t0 = Fake.now_s;
        // Set the next frame's overshoot to 20% of the previous request (slack proportional to the request)
        Fake.overshoot_ns = @intFromFloat(@as(f64, @floatFromInt(@max(Fake.last_request_ns, 1))) * 0.20);
        FakeDriver.pace(&pacer, t0 + period_s, false);
        last_period_err_ns = @as(i64, @intFromFloat((Fake.now_s - t0) * 1e9)) - @as(i64, @intFromFloat(period_s * 1e9));
    }
    // after convergence the per-frame error is within ±0.5ms (an effective 59-61fps)
    try std.testing.expect(last_period_err_ns > -500_000 and last_period_err_ns < 500_000);
    // what has been learned sits around the slack (20% of a request of about 13ms, so about 2.6ms)
    try std.testing.expect(pacer.est_overshoot_ns > 1_500_000 and pacer.est_overshoot_ns <= MAX_EST_NS);
    // the design never busy-waits, so there is at most one sleep call per frame
    try std.testing.expect(Fake.sleep_calls <= 300);
}

test "Driver: what has been learned decays even on a frame where request==0 (through the Driver path)" {
    Fake.reset(0);
    // Making the estimate eat the whole remainder (1ms left against a 4ms estimate) makes decide return a sleep of 0.
    var pacer: Pacer = .{ .est_overshoot_ns = MAX_EST_NS };
    FakeDriver.pace(&pacer, Fake.now_s + 0.001, false);
    try std.testing.expectEqual(@as(u32, 0), Fake.sleep_calls); // the OS sleep is not called
    try std.testing.expectEqual(MAX_EST_NS / 2, pacer.est_overshoot_ns); // but what has been learned is halved
    // repeating it keeps bringing it down, so it never stalls forever
    const before = pacer.est_overshoot_ns;
    FakeDriver.pace(&pacer, Fake.now_s + 0.001, false);
    try std.testing.expect(pacer.est_overshoot_ns < before);
    try std.testing.expectEqual(@as(u32, 0), Fake.sleep_calls);
}

test "Driver: pacing comes back within a few frames even after a huge oversleep" {
    const period_s: f64 = 1.0 / 60.0;
    Fake.reset(1_000_000_000); // a pathological sleep that oversleeps by 1 second
    var pacer: Pacer = .{};
    FakeDriver.pace(&pacer, Fake.now_s + period_s, false);
    try std.testing.expect(pacer.est_overshoot_ns <= MAX_EST_NS);

    // From here on the sleep behaves normally. While the estimate eats the remainder it sleeps 0 (decaying what is learned), and eventually the sleep comes back.
    Fake.overshoot_ns = 0;
    var recovered = false;
    var frames: u32 = 0;
    while (frames < 16) : (frames += 1) {
        const calls_before = Fake.sleep_calls;
        FakeDriver.pace(&pacer, Fake.now_s + period_s, false);
        if (Fake.sleep_calls > calls_before) {
            recovered = true;
            break;
        }
    }
    try std.testing.expect(recovered);
    try std.testing.expect(frames <= 6);
}
