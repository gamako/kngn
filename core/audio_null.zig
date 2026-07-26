//! Null audio output device (an L1 audio output primitive)
//!
//! The output with no real device, for the headless harness (`VP_HEADLESS=1`). Pure Zig and OS independent
//! (no `@cImport`, the same ABI strategy as audio_linux and audio_windows). `start()` spawns a playback thread
//! (`std.Thread`) and pulls the render callback with real-time pacing (sleeping for exactly one period's worth of
//! time), following audio_linux's push-thread pattern. That way the behaviour an application sees — another thread
//! driving the callback in real time — is the same as with a real device.
//!
//! Hot path declaration: `renderThread` is a **backend-owned real-time loop pulling the render callback**. The scratch buffer is allocated up front in `open()`, and
//! within the loop (the callback call plus the sleep) there is **no alloc, lock, IO or panic** (pinned by a test using FailingAllocator).
//! The null device itself does no per-sample arithmetic (generating samples is the caller's own callback).
//!
//! ## The public types are the caller's (the OS backend's), used as they are
//!
//! `NullBackend(comptime B: type)` **re-exports** `B.{Error,Config,EffectiveConfig,RenderCallback}`
//! **as aliases** rather than creating new types. The `audio.zig` facade instantiates this exactly once with
//! `B = backend` (the running OS's backend module), so
//! `NullBackend(backend).Config` is literally the same type as `backend.Config`, and
//! the facade's public `Config`, `Error` and the rest need no change at all (neither the types nor the error sets grow).

const std = @import("std");

pub fn NullBackend(comptime B: type) type {
    return struct {
        pub const Error = B.Error;
        pub const Config = B.Config;
        pub const EffectiveConfig = B.EffectiveConfig;
        pub const RenderCallback = B.RenderCallback;

        /// The state passed to the playback thread and the callback at a stable address. Heap-allocated by `open()`
        /// and destroyed by `close()` (the same shape as a backend implementation).
        const State = struct {
            render_callback: RenderCallback,
            userdata: ?*anyopaque,
            effective: EffectiveConfig,
            running: std.atomic.Value(bool),
            thread: ?std.Thread,
            scratch: []f32, // the interleaved buffer of period * channels (allocated only at open)
            allocator: std.mem.Allocator,
        };

        pub const AudioDevice = struct {
            state: *State,

            pub fn config(self: @This()) EffectiveConfig {
                return self.state.effective;
            }

            /// Starts the playback thread. There is nothing corresponding to a real device's prepare, so it always succeeds
            /// (only a failed spawn gives `error.StartFailed`).
            pub fn start(self: @This()) Error!void {
                const state = self.state;
                if (state.thread != null) return; // a double start is ignored (the same contract as a backend)
                state.running.store(true, .release);
                state.thread = std.Thread.spawn(.{}, renderThread, .{state}) catch {
                    state.running.store(false, .release);
                    return error.StartFailed;
                };
            }

            /// Stops the playback thread: `running=false`, then join.
            pub fn stop(self: @This()) void {
                const state = self.state;
                if (state.thread) |thread| {
                    state.running.store(false, .release);
                    thread.join();
                    state.thread = null;
                }
            }

            /// stop, then free the scratch, then destroy the State.
            pub fn close(self: @This()) void {
                const state = self.state;
                self.stop();
                state.allocator.free(state.scratch);
                state.allocator.destroy(state);
            }
        };

        /// The real-time contract region: the `render_callback` call plus the sleep, and nothing else. No alloc, lock, IO or panic.
        fn renderThread(state: *State) void {
            const ch: usize = state.effective.channels;
            const period: usize = state.effective.max_frames_per_slice;
            const sample_rate = state.effective.sample_rate;
            const period_ns = periodNanos(period, sample_rate);

            while (state.running.load(.acquire)) {
                state.render_callback(
                    state.scratch,
                    @intCast(period),
                    @intCast(ch),
                    sample_rate,
                    state.userdata,
                );
                // Real-time pacing of the same shape as a real device (waiting for exactly one period's playback time).
                sleepNs(period_ns);
            }
        }

        pub fn open(allocator: std.mem.Allocator, cfg: Config) Error!AudioDevice {
            const effective = EffectiveConfig{
                .sample_rate = cfg.sample_rate,
                .channels = cfg.channels,
                .max_frames_per_slice = cfg.buffer_frames,
            };

            const state = allocator.create(State) catch return error.OpenFailed;
            errdefer allocator.destroy(state);

            const scratch = allocator.alloc(f32, @as(usize, effective.max_frames_per_slice) * effective.channels) catch
                return error.OpenFailed;
            errdefer allocator.free(scratch);

            state.* = .{
                .render_callback = cfg.render_callback,
                .userdata = cfg.userdata,
                .effective = effective,
                .running = std.atomic.Value(bool).init(false),
                .thread = null,
                .scratch = scratch,
                .allocator = allocator,
            };

            return .{ .state = state };
        }
    };
}

/// Works out a period's playback time in nanoseconds from the period (in frames) and the sample_rate (pure logic, testable).
fn periodNanos(period: usize, sample_rate: u32) u64 {
    if (sample_rate == 0) return 0;
    return @as(u64, period) * std.time.ns_per_s / sample_rate;
}

// ============================================================================
// An OS-independent sleep (the same implementation as `sleep()` in `src/platform.zig`. The audio layer does not depend on
// platform by design, so rather than importing it the same pattern is duplicated here: POSIX uses nanosleep, Windows uses Sleep).
// ============================================================================
const builtin = @import("builtin");

const win_sleep = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
} else struct {};

fn sleepNs(nanoseconds: u64) void {
    if (builtin.os.tag == .windows) {
        win_sleep.Sleep(@intCast(nanoseconds / 1_000_000));
    } else {
        var req = std.c.timespec{
            .sec = @intCast(nanoseconds / 1_000_000_000),
            .nsec = @intCast(nanoseconds % 1_000_000_000),
        };
        _ = std.c.nanosleep(&req, null);
    }
}

// ============================================================================
// tests (no display or real device needed, and OS independent)
// ============================================================================
const testing = std.testing;

/// The set of backend types used by the tests alone (the same signature as audio_{macos,linux,windows}.zig).
const TestBackend = struct {
    pub const Error = error{
        OpenFailed,
        NoDevice,
        ConfigFailed,
        InitializeFailed,
        QueryFailed,
        StartFailed,
    };
    pub const RenderCallback = *const fn (buf: []f32, frames: u32, channels: u32, sample_rate: u32, userdata: ?*anyopaque) void;
    pub const Config = struct {
        sample_rate: u32 = 48000,
        buffer_frames: u32 = 512,
        channels: u32 = 2,
        render_callback: RenderCallback,
        userdata: ?*anyopaque = null,
    };
    pub const EffectiveConfig = struct {
        sample_rate: u32,
        channels: u32,
        max_frames_per_slice: u32,
    };
};
const TestNull = NullBackend(TestBackend);

test "periodNanos: sample_rate=0 gives 0, and otherwise period/sample_rate seconds" {
    try testing.expectEqual(@as(u64, 0), periodNanos(512, 0));
    try testing.expectEqual(@as(u64, std.time.ns_per_s), periodNanos(48000, 48000));
    try testing.expectEqual(@as(u64, std.time.ns_per_s / 2), periodNanos(24000, 48000));
}

const CallCtx = struct {
    count: std.atomic.Value(u32) = .init(0),
    last_frames: std.atomic.Value(u32) = .init(0),
};

fn countingCallback(buf: []f32, frames: u32, channels: u32, sample_rate: u32, userdata: ?*anyopaque) void {
    _ = sample_rate;
    const ctx: *CallCtx = @ptrCast(@alignCast(userdata.?));
    @memset(buf[0 .. @as(usize, frames) * channels], 0.5);
    ctx.last_frames.store(frames, .monotonic);
    _ = ctx.count.fetchAdd(1, .monotonic);
}

test "open/start/stop/close: the callback is called several times in real time and the join finishes safely" {
    var ctx = CallCtx{};
    const device = try TestNull.open(testing.allocator, .{
        .sample_rate = 48000,
        .buffer_frames = 128, // go round several times quickly with a short period (about 2.7ms each)
        .channels = 2,
        .render_callback = countingCallback,
        .userdata = &ctx,
    });
    defer device.close();

    try testing.expectEqual(@as(u32, 48000), device.config().sample_rate);
    try testing.expectEqual(@as(u32, 128), device.config().max_frames_per_slice);

    try device.start();
    sleepNs(30 * std.time.ns_per_ms); // 30ms is enough for several times round
    device.stop();

    try testing.expect(ctx.count.load(.monotonic) >= 2);
    try testing.expectEqual(@as(u32, 128), ctx.last_frames.load(.monotonic));

    // a double stop or start is safe (a no-op)
    device.stop();
}

test "the real-time contract: no allocation happens after open while the pull loop runs (FailingAllocator)" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();

    var ctx = CallCtx{};
    const device = try TestNull.open(alloc, .{
        .sample_rate = 48000,
        .buffer_frames = 64,
        .channels = 1,
        .render_callback = countingCallback,
        .userdata = &ctx,
    });
    defer device.close();

    const allocs_after_open = failing.allocations;
    // From here on, pin it so that a single allocation would give OOM.
    failing.fail_index = allocs_after_open;

    try device.start();
    sleepNs(30 * std.time.ns_per_ms);
    device.stop();

    try testing.expectEqual(allocs_after_open, failing.allocations); // no allocation during the pull loop
    try testing.expect(ctx.count.load(.monotonic) >= 1); // the callback really is called
}
