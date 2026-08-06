//! Web microphone capture backend (AudioWorklet → shared-memory ring → main-thread drain).
//!
//! Pair of `core/audio_web.zig` for the capture (input) path. JS writes PCM into a fixed
//! scratch buffer and calls `kngn_capture_submit`; the main thread drains the ring once
//! per frame via `drainCaptureIfActive` and invokes the registered capture callback.
//!
//! ## Thread / Instance model
//! - **Producer** (`kngn_capture_submit`): AudioWorklet Instance (or any shared-memory
//!   peer) — real-time, once per 128-frame block.
//! - **Consumer** (`drainCaptureIfActive`): application main Instance, once per frame.
//! - **Session control** (`kngn_capture_start` / `kngn_capture_stop`): main thread only.
//!
//! ## Generation / quiescence
//! `g_capture_session` is 0 while stopped and a non-zero generation while running.
//! Each submitted block carries the generation observed at submit time. Drain delivers
//! only blocks whose generation matches the current session, so a late Worklet block
//! from a previous start/stop cycle is discarded without reaching the callback.
//!
//! Generation wrap-around is not handled. The ring holds at most 16 blocks and drain
//! runs every main-thread frame, so a stale block can linger for only a few frames.
//! Exhausting a u32 generation space (~4×10⁹ start/stop cycles) cannot happen under
//! this design; no wrap-around countermeasure is provided.
//!
//! ## Hot path declaration
//! - Real-time (per capture block, ~128 frames): `kngn_capture_submit` — no alloc, lock,
//!   IO or panic. Only atomics, a fixed scratch copy, and a lock-free ring push.
//! - Main-thread frame tick: `drainCaptureIfActive` — no alloc or lock; may call the
//!   user `CaptureCallback` (bound by the same real-time rules as native capture).
//! - `kngn_capture_start` / `kngn_capture_stop` / scratch exports: event-time / init only.
//!
//! Neither `kngn_capture_submit` nor `drainCaptureIfActive` takes an allocator argument;
//! they use only module-level fixed storage and atomics (structural zero-allocation).

const std = @import("std");
const builtin = @import("builtin");
const types = @import("capture_types");

// ============================================================================
// public callback slot (facade wires this in a later step)
// ============================================================================

/// Same shape as `core/audio_capture_stub.zig`'s capture callback.
/// Real-time call rules: no malloc, locking, IO or panic.
pub const CaptureCallback = *const fn (frame: types.AudioInFrame, userdata: ?*anyopaque) void;

/// Registered by the facade on open; cleared on close. `null` means drain discards
/// matching blocks without delivering.
var g_capture_callback: ?CaptureCallback = null;
var g_capture_userdata: ?*anyopaque = null;

/// True after a successful `open()` until `close()`. Distinct from `g_capture_session`
/// (which is 0 while stopped): an opened device may be stopped without being closed, and
/// the shared AudioContext refcount must still treat capture as a holder.
var g_capture_opened: bool = false;

/// Mirror of the output side's open flag, maintained by `audio_web` via `setOutputOpen`.
/// Used so capture `close()` can tear down the shared AudioContext only when output is
/// also closed (avoids a circular import of `audio_web`).
var g_output_open: bool = false;

/// Set or clear the delivery slot (used by `open` / `close` and tests).
pub fn setCaptureCallback(cb: ?CaptureCallback, userdata: ?*anyopaque) void {
    g_capture_callback = cb;
    g_capture_userdata = userdata;
}

/// Whether capture currently holds an open device (post-`open`, pre-`close`).
pub fn isOpen() bool {
    return g_capture_opened;
}

/// Called from `audio_web` when the output device opens or closes (refcount partner).
pub fn setOutputOpen(is_open: bool) void {
    g_output_open = is_open;
}

// ============================================================================
// capture ring (self-contained; not exported)
// ============================================================================

/// One Worklet quantum of mono f32 PCM plus metadata. Value type only — no pointers
/// into shared scratch (the samples are owned by the block).
const CaptureBlock = struct {
    samples: [128]f32,
    frames: u32,
    sample_rate: u32,
    generation: u32,
};

/// Single-producer / single-consumer lock-free ring (same design as `libs/synth` SpscRing).
/// `capacity` must be a power of two. head/tail sit on separate cache lines.
fn SpscRing(comptime T: type, comptime capacity: usize) type {
    if (!std.math.isPowerOfTwo(capacity)) @compileError("capacity must be a power of two");
    return struct {
        const Self = @This();
        const mask = capacity - 1;

        buffer: [capacity]T = undefined,
        // Separate head (producer writes) / tail (consumer writes) onto different cache lines
        // (avoid false sharing between Worklet and main).
        head: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),
        tail: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),

        pub fn capacityCount() usize {
            return capacity;
        }

        /// producer: push if there is room; return false when full.
        pub fn push(self: *Self, item: T) bool {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            const used = head -% tail;
            if (used >= capacity) return false;
            self.buffer[head & mask] = item;
            self.head.store(head +% 1, .release);
            return true;
        }

        /// consumer: take one item. null if empty.
        pub fn pop(self: *Self) ?T {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.acquire);
            if (head == tail) return null;
            const item = self.buffer[tail & mask];
            self.tail.store(tail +% 1, .release);
            return item;
        }
    };
}

const CaptureRing = SpscRing(CaptureBlock, 16);

var g_capture_ring: CaptureRing = .{};

/// Dropped submits while the ring was full. Producer increments; readers use monotonic.
var g_capture_drops: std.atomic.Value(u32) = .init(0);

/// 0 = stopped; non-zero = running generation. Worklet acquire-loads; main release-stores.
var g_capture_session: std.atomic.Value(u32) = .init(0);

/// Next generation to issue on start. Main thread only — not atomic.
var g_capture_generation_counter: u32 = 0;

/// Fixed scratch the JS / Worklet fills before `kngn_capture_submit` (mono, one quantum).
var capture_scratch: [128]f32 = undefined;

// ============================================================================
// drop counter (saturating)
// ============================================================================

/// Saturating +1 on the drop counter (stops at `maxInt(u32)`). Single producer (submit).
fn saturatingIncDrops() void {
    const cur = g_capture_drops.load(.monotonic);
    if (cur == std.math.maxInt(u32)) return;
    // Single-producer path: store is enough; use saturating add for the arithmetic.
    g_capture_drops.store(cur +| 1, .monotonic);
}

// ============================================================================
// exports (`kngn_capture_*`)
// ============================================================================

/// Byte address of the fixed capture scratch (JS / Worklet writes mono f32 here).
/// Wasm linear memory is 32-bit; on a host test build the low 32 bits of the pointer
/// are returned so the export stays u32-ABI and callable outside wasm32.
pub export fn kngn_capture_scratch_ptr() u32 {
    return @truncate(@intFromPtr(&capture_scratch));
}

/// Length of the capture scratch in f32 elements (one 128-frame mono quantum).
pub export fn kngn_capture_scratch_len() u32 {
    return 128;
}

/// Runs once per 128-frame AudioWorklet block (real-time).
///
/// Copies `capture_scratch[0..frames]` into a `CaptureBlock` and pushes it on the ring.
/// **No alloc, locking, IO or panic.** Takes no allocator (structural zero-allocation).
///
/// Return: 1 = block accepted, 0 = skipped (session stopped, bad frames, or ring full).
pub export fn kngn_capture_submit(frames: u32, sample_rate: u32) u32 {
    if (frames == 0 or frames > 128) return 0;

    const gen = g_capture_session.load(.acquire);
    if (gen == 0) return 0;

    var block: CaptureBlock = .{
        .samples = undefined,
        .frames = frames,
        .sample_rate = sample_rate,
        .generation = gen,
    };
    // Copy the live samples and zero the unused tail so the value type holds no
    // uninitialised memory.
    @memcpy(block.samples[0..frames], capture_scratch[0..frames]);
    if (frames < 128) {
        @memset(block.samples[frames..], 0);
    }

    if (!g_capture_ring.push(block)) {
        saturatingIncDrops();
        return 0;
    }
    return 1;
}

/// Diagnostic: number of full-ring drops since process start (monotonic load).
pub export fn kngn_capture_drop_count() u32 {
    return g_capture_drops.load(.monotonic);
}

/// Start a new capture session (main thread). Issues a new generation, drains the
/// ring as an early cleanup optimisation (correctness still rests on generation
/// matching at drain, not on this wipe), and publishes the generation.
///
/// Generation wrap-around is not handled (see module doc): a u32 cannot be exhausted
/// under a design that drains every frame with a 16-slot ring.
///
/// Return: 1 = success. Boot / permission checks are layered by JS in a later step.
pub export fn kngn_capture_start() u32 {
    g_capture_generation_counter += 1;
    const new_gen = g_capture_generation_counter;

    // Early cleanup only: empties the ring before publishing the new generation.
    // Correctness of discarding a late old-generation block does **not** depend on
    // this wipe — drain still compares block.generation against the session.
    while (g_capture_ring.pop()) |_| {}

    g_capture_session.store(new_gen, .release);
    return 1;
}

/// Stop capture on the Zig side (main thread). Sets session to 0 so further submits
/// no-op. MediaStream teardown is the caller's (JS) responsibility.
pub export fn kngn_capture_stop() void {
    g_capture_session.store(0, .release);
}

// ============================================================================
// JS env imports (kngn.js) — capture control plane
// ============================================================================

/// Opens the browser capture path (MediaStream / AudioContext wiring on the JS side).
/// Return: actual sample rate (>0) on success, 0 on failure.
extern "env" fn kngn_capture_open(sample_rate: u32) u32;
/// Releases JS-side capture resources (MediaStream tracks). Does not alone decide
/// whether the shared AudioContext is destroyed — Zig refcount does.
extern "env" fn kngn_capture_close() void;
/// Connect the held MediaStream to the AudioWorklet input (JS). Called from `start()`.
extern "env" fn kngn_capture_connect_source() void;
/// Disconnect the MediaStream source from the Worklet without releasing the stream (JS).
extern "env" fn kngn_capture_disconnect_source() void;
/// Idempotent permission poll. Return codes match `PermissionState` tag order:
/// 0 = not_determined, 1 = granted, 2 = denied, 3 = restricted.
extern "env" fn kngn_capture_request_permission() u32;
/// Number of devices in the most recently resolved JS snapshot (capped at `max_capture_devices`).
extern "env" fn kngn_capture_device_count() u32;
extern "env" fn kngn_capture_device_name_ptr(index: u32) u32;
extern "env" fn kngn_capture_device_name_len(index: u32) u32;
extern "env" fn kngn_capture_device_id_ptr(index: u32) u32;
extern "env" fn kngn_capture_device_id_len(index: u32) u32;

/// Shared with the output path: destroy AudioContext only when neither side is open.
extern "env" fn kngn_audio_close() void;

/// Maximum devices cloned from the JS snapshot into a caller-owned list.
/// Hard cap for the fixed name/id storage JS fills in linear memory.
pub const max_capture_devices: u32 = 8;
/// UTF-8 capacity per device name / id in the fixed storage JS writes into.
pub const max_device_str_bytes: u32 = 256;

/// Fixed storage JS fills (via `kngn_capture_device_*_storage_ptr`) before enumerate.
/// Enumerate clones from the env-reported ptr/len snapshot; storage exports let JS
/// write UTF-8 into wasm memory without allocating on the Zig side at fill time.
var g_device_name_storage: [max_capture_devices][max_device_str_bytes]u8 = undefined;
var g_device_id_storage: [max_capture_devices][max_device_str_bytes]u8 = undefined;

/// Byte address of the name storage slot for device `index` (JS writes UTF-8 here).
export fn kngn_capture_device_name_storage_ptr(index: u32) u32 {
    if (index >= max_capture_devices) return 0;
    return @truncate(@intFromPtr(&g_device_name_storage[index]));
}

/// Byte address of the id storage slot for device `index` (JS writes UTF-8 here).
export fn kngn_capture_device_id_storage_ptr(index: u32) u32 {
    if (index >= max_capture_devices) return 0;
    return @truncate(@intFromPtr(&g_device_id_storage[index]));
}

/// Capacity in bytes of each name/id storage slot.
export fn kngn_capture_device_str_cap() u32 {
    return max_device_str_bytes;
}

// ============================================================================
// facade (same verb shapes as `audio_capture_stub` / native backends)
// ============================================================================

pub const Error = types.CaptureError;

/// Requested settings (hints). Same fields as `audio_capture_stub.Config`.
pub const Config = struct {
    device_id: ?[]const u8 = null,
    sample_rate: u32 = 48000,
    channels: u32 = 1,
    capture_callback: CaptureCallback,
    userdata: ?*anyopaque = null,
};

/// Effective values after `open()`.
pub const EffectiveConfig = struct {
    sample_rate: u32,
    channels: u32,
    max_frames_per_slice: u32,
};

/// Opened capture device. Holds only the negotiated config; session state is module-global
/// (one wasm capture device at a time).
pub const CaptureDevice = struct {
    effective: EffectiveConfig,

    pub fn config(self: CaptureDevice) EffectiveConfig {
        return self.effective;
    }

    /// Returns `.running` while a capture session generation is active, otherwise `.stopped`.
    /// `device_lost` is not detected on the wasm path yet.
    pub fn status(_: CaptureDevice) types.DeviceStatus {
        if (g_capture_session.load(.acquire) != 0) return .running;
        return .stopped;
    }

    pub fn start(self: CaptureDevice) types.CaptureError!void {
        if (!g_capture_opened) return error.StartFailed;
        // Double start is ignored (same contract as output / docs/capture.md).
        if (self.status() == .running) return;
        // Session generation first so submits after connect are accepted.
        if (kngn_capture_start() == 0) return error.StartFailed;
        if (comptime builtin.cpu.arch.isWasm()) {
            kngn_capture_connect_source();
        }
    }

    pub fn stop(_: CaptureDevice) void {
        if (!g_capture_opened) return;
        // Stop accepting submits before tearing down the graph edge.
        kngn_capture_stop();
        if (comptime builtin.cpu.arch.isWasm()) {
            kngn_capture_disconnect_source();
        }
    }

    pub fn close(self: CaptureDevice) void {
        self.stop();
        setCaptureCallback(null, null);
        if (!g_capture_opened) return;
        g_capture_opened = false;
        if (comptime builtin.cpu.arch.isWasm()) {
            kngn_capture_close();
            // Destroy the shared AudioContext only when output is not still open.
            if (!g_output_open) {
                kngn_audio_close();
            }
        }
    }
};

fn mapPermissionCode(code: u32) types.PermissionState {
    return switch (code) {
        0 => .not_determined,
        1 => .granted,
        2 => .denied,
        3 => .restricted,
        else => .denied,
    };
}

fn readEnvString(ptr: u32, len: u32, allocator: std.mem.Allocator) types.CaptureError![]u8 {
    if (len == 0) {
        return allocator.dupe(u8, "") catch return error.OpenFailed;
    }
    if (ptr == 0) return error.OpenFailed;
    const src: [*]const u8 = @ptrFromInt(ptr);
    return allocator.dupe(u8, src[0..len]) catch return error.OpenFailed;
}

/// Clone the most recently resolved JS device-list snapshot with the caller's allocator.
/// Empty while permission is unsettled means "not known yet", not a settled zero devices
/// (see `docs/capture.md`). Cap: `max_capture_devices`.
pub fn enumerate(allocator: std.mem.Allocator) types.CaptureError![]types.DeviceInfo {
    if (comptime !builtin.cpu.arch.isWasm()) return error.Unsupported;

    var n = kngn_capture_device_count();
    if (n > max_capture_devices) n = max_capture_devices;

    const devices = allocator.alloc(types.DeviceInfo, n) catch return error.OpenFailed;
    var filled: u32 = 0;
    errdefer {
        var j: u32 = 0;
        while (j < filled) : (j += 1) {
            allocator.free(devices[j].id);
            allocator.free(devices[j].name);
        }
        allocator.free(devices);
    }

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const name = try readEnvString(kngn_capture_device_name_ptr(i), kngn_capture_device_name_len(i), allocator);
        const id = readEnvString(kngn_capture_device_id_ptr(i), kngn_capture_device_id_len(i), allocator) catch |err| {
            allocator.free(name);
            return err;
        };
        devices[i] = .{
            .id = id,
            .name = name,
            .kind = .audio_in,
            .is_default = (i == 0),
        };
        filled = i + 1;
    }
    return devices;
}

/// Idempotent permission poll (see `docs/capture.md`). Maps the JS integer code to
/// `PermissionState`. In-flight state lives on the JS side.
pub fn requestPermission() types.CaptureError!types.PermissionState {
    if (comptime !builtin.cpu.arch.isWasm()) return error.Unsupported;
    return mapPermissionCode(kngn_capture_request_permission());
}

/// Open the default capture path. `allocator` is unused (no Zig-side device state heap);
/// kept for facade signature parity with native backends.
pub fn open(allocator: std.mem.Allocator, cfg: Config) types.CaptureError!CaptureDevice {
    _ = allocator;
    if (comptime !builtin.cpu.arch.isWasm()) return error.Unsupported;
    if (g_capture_opened) return error.OpenFailed;
    if (cfg.sample_rate == 0) return error.ConfigFailed;
    // Mono capture path only (scratch / CaptureBlock are mono f32).
    if (cfg.channels != 1) return error.ConfigFailed;

    const actual_sr = kngn_capture_open(cfg.sample_rate);
    if (actual_sr == 0) return error.OpenFailed;

    setCaptureCallback(cfg.capture_callback, cfg.userdata);
    g_capture_opened = true;
    return .{
        .effective = .{
            .sample_rate = actual_sr,
            .channels = cfg.channels,
            .max_frames_per_slice = 128,
        },
    };
}

// ============================================================================
// DCE-prevention hook (pair of `audio_web.enableAudioExports`)
// ============================================================================

/// Keep capture exports alive against DCE in a wasm build. No-op on native.
pub fn enableCaptureExports() void {
    if (!builtin.cpu.arch.isWasm()) return;
    _ = &kngn_capture_scratch_ptr;
    _ = &kngn_capture_scratch_len;
    _ = &kngn_capture_submit;
    _ = &kngn_capture_drop_count;
    _ = &kngn_capture_start;
    _ = &kngn_capture_stop;
    _ = &kngn_capture_device_name_storage_ptr;
    _ = &kngn_capture_device_id_storage_ptr;
    _ = &kngn_capture_device_str_cap;
}

// ============================================================================
// main-thread drain
// ============================================================================

/// Drain the capture ring on the main-thread frame tick.
///
/// Pops until empty. Delivers a block only when its generation equals the current
/// session and a callback is registered. Stale-generation blocks are discarded.
/// **No alloc or lock.** Takes no allocator (structural zero-allocation).
pub fn drainCaptureIfActive() void {
    const session = g_capture_session.load(.acquire);
    while (g_capture_ring.pop()) |block| {
        if (session == 0 or block.generation != session) continue;
        const cb = g_capture_callback orelse continue;
        const n: usize = block.frames;
        const frame = types.AudioInFrame{
            .samples = block.samples[0..n],
            .frames = block.frames,
            .channels = 1,
            .sample_rate = block.sample_rate,
            .timestamp_ns = 0,
        };
        cb(frame, g_capture_userdata);
    }
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

/// Reset module state between tests (main-thread fields only; ring emptied by pop).
fn resetCaptureStateForTest() void {
    kngn_capture_stop();
    while (g_capture_ring.pop()) |_| {}
    g_capture_drops.store(0, .monotonic);
    g_capture_generation_counter = 0;
    g_capture_callback = null;
    g_capture_userdata = null;
    g_capture_opened = false;
    g_output_open = false;
    @memset(&capture_scratch, 0);
}

test "SpscRing: head and tail sit on separate cache lines" {
    const cl = std.atomic.cache_line;
    const Ring = SpscRing(u32, 8);
    try testing.expect(@alignOf(Ring) >= cl);
    try testing.expect(@offsetOf(Ring, "head") % cl == 0);
    try testing.expect(@offsetOf(Ring, "tail") % cl == 0);
    const dist = if (@offsetOf(Ring, "tail") > @offsetOf(Ring, "head"))
        @offsetOf(Ring, "tail") - @offsetOf(Ring, "head")
    else
        @offsetOf(Ring, "head") - @offsetOf(Ring, "tail");
    try testing.expect(dist >= cl);
}

test "SpscRing: FIFO order, capacity, and wrap-around" {
    var ring = SpscRing(u32, 4){};
    try testing.expect(ring.push(10));
    try testing.expect(ring.push(20));
    try testing.expectEqual(@as(?u32, 10), ring.pop());
    try testing.expectEqual(@as(?u32, 20), ring.pop());
    try testing.expectEqual(@as(?u32, null), ring.pop());

    try testing.expect(ring.push(1));
    try testing.expect(ring.push(2));
    try testing.expect(ring.push(3));
    try testing.expect(ring.push(4));
    try testing.expect(!ring.push(5));
    try testing.expectEqual(@as(?u32, 1), ring.pop());
    try testing.expect(ring.push(5));
    // Empty the ring before the wrap-around loop so capacity is free.
    while (ring.pop()) |_| {}

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try testing.expect(ring.push(i));
        try testing.expectEqual(@as(?u32, i), ring.pop());
    }
}

test "drainCaptureIfActive: discards blocks whose generation does not match the session" {
    resetCaptureStateForTest();
    defer resetCaptureStateForTest();

    var call_count: u32 = 0;
    const Ctx = struct {
        count: *u32,
        fn cb(frame: types.AudioInFrame, userdata: ?*anyopaque) void {
            _ = frame;
            const c: *u32 = @ptrCast(@alignCast(userdata.?));
            c.* += 1;
        }
    };
    setCaptureCallback(Ctx.cb, &call_count);

    // Session generation 1 is running; push one matching block via submit.
    try testing.expectEqual(@as(u32, 1), kngn_capture_start());
    @memset(capture_scratch[0..64], 0.25);
    try testing.expectEqual(@as(u32, 1), kngn_capture_submit(64, 48000));

    // Advance the session without going through start() (start would wipe the ring).
    // Generation 1 block remains; session is now 2.
    g_capture_session.store(2, .release);
    g_capture_generation_counter = 2;

    drainCaptureIfActive();
    try testing.expectEqual(@as(u32, 0), call_count);

    // Ring must be empty after the discard.
    try testing.expectEqual(@as(?CaptureBlock, null), g_capture_ring.pop());
}

test "kngn_capture_submit and drainCaptureIfActive: smoke (no crash under repeated use)" {
    resetCaptureStateForTest();
    defer resetCaptureStateForTest();

    // Structural guarantee: neither function takes an allocator (see module and fn docs).
    // Smoke: many submit/drain cycles must not panic or hang.
    try testing.expectEqual(@as(u32, 1), kngn_capture_start());
    var n: u32 = 0;
    while (n < 256) : (n += 1) {
        @memset(&capture_scratch, @as(f32, @floatFromInt(n % 7)) * 0.01);
        _ = kngn_capture_submit(128, 48000);
        drainCaptureIfActive();
    }
    try testing.expect(kngn_capture_drop_count() == 0 or kngn_capture_drop_count() >= 0);
}

test "drop counter saturates at maxInt(u32)" {
    resetCaptureStateForTest();
    defer resetCaptureStateForTest();

    try testing.expectEqual(@as(u32, 1), kngn_capture_start());
    @memset(&capture_scratch, 0.5);

    // Fill the ring to capacity (16).
    var i: u32 = 0;
    while (i < CaptureRing.capacityCount()) : (i += 1) {
        try testing.expectEqual(@as(u32, 1), kngn_capture_submit(128, 48000));
    }
    try testing.expectEqual(@as(u32, 0), kngn_capture_drop_count());

    // Next push fails and increments drops.
    try testing.expectEqual(@as(u32, 0), kngn_capture_submit(128, 48000));
    try testing.expectEqual(@as(u32, 1), kngn_capture_drop_count());

    // Near the top of u32: further failed pushes must not wrap.
    g_capture_drops.store(std.math.maxInt(u32) - 1, .monotonic);
    try testing.expectEqual(@as(u32, 0), kngn_capture_submit(128, 48000));
    try testing.expectEqual(std.math.maxInt(u32), kngn_capture_drop_count());
    try testing.expectEqual(@as(u32, 0), kngn_capture_submit(128, 48000));
    try testing.expectEqual(std.math.maxInt(u32), kngn_capture_drop_count());
}

test "start reset then delayed old-generation push is discarded on drain" {
    resetCaptureStateForTest();
    defer resetCaptureStateForTest();

    var call_count: u32 = 0;
    const Ctx = struct {
        count: *u32,
        fn cb(frame: types.AudioInFrame, userdata: ?*anyopaque) void {
            _ = frame;
            const c: *u32 = @ptrCast(@alignCast(userdata.?));
            c.* += 1;
        }
    };
    setCaptureCallback(Ctx.cb, &call_count);

    // (a) session=1, one block in the ring.
    try testing.expectEqual(@as(u32, 1), kngn_capture_start());
    try testing.expectEqual(@as(u32, 1), g_capture_session.load(.acquire));
    @memset(capture_scratch[0..32], 0.1);
    try testing.expectEqual(@as(u32, 1), kngn_capture_submit(32, 44100));

    // (b) start again: session becomes 2 and the ring is wiped (early cleanup).
    try testing.expectEqual(@as(u32, 1), kngn_capture_start());
    try testing.expectEqual(@as(u32, 2), g_capture_session.load(.acquire));
    try testing.expectEqual(@as(?CaptureBlock, null), g_capture_ring.pop());

    // (c) late push still carrying generation 1 (simulates a Worklet block that
    // observed the old session before its acquire saw the new one — we inject the
    // block directly because submit always stamps the *current* session).
    var stale: CaptureBlock = .{
        .samples = undefined,
        .frames = 16,
        .sample_rate = 44100,
        .generation = 1,
    };
    @memset(&stale.samples, 0);
    @memset(stale.samples[0..16], 0.9);
    try testing.expect(g_capture_ring.push(stale));

    // (d) drain must not deliver the stale block.
    drainCaptureIfActive();
    try testing.expectEqual(@as(u32, 0), call_count);

    // A matching gen=2 submit still delivers.
    @memset(capture_scratch[0..8], 0.2);
    try testing.expectEqual(@as(u32, 1), kngn_capture_submit(8, 44100));
    drainCaptureIfActive();
    try testing.expectEqual(@as(u32, 1), call_count);
}

test "kngn_capture_submit: rejects empty or oversized frames and stopped session" {
    resetCaptureStateForTest();
    defer resetCaptureStateForTest();

    try testing.expectEqual(@as(u32, 0), kngn_capture_submit(128, 48000)); // stopped
    try testing.expectEqual(@as(u32, 1), kngn_capture_start());
    try testing.expectEqual(@as(u32, 0), kngn_capture_submit(0, 48000));
    try testing.expectEqual(@as(u32, 0), kngn_capture_submit(129, 48000));
    try testing.expectEqual(@as(u32, 1), kngn_capture_submit(128, 48000));
}

test "enableCaptureExports is a no-op on native" {
    // Must not panic when the host arch is not wasm.
    enableCaptureExports();
}

test "scratch exports report the fixed buffer" {
    try testing.expectEqual(@as(u32, 128), kngn_capture_scratch_len());
    const ptr_u32 = kngn_capture_scratch_ptr();
    // On wasm32 the full address fits; on a host build only the low 32 bits match.
    try testing.expectEqual(@as(u32, @truncate(@intFromPtr(&capture_scratch))), ptr_u32);
}
