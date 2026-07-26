//! The single source for the capture input foundation's shared types (the shared control plane conventions plus the data plane types).
//!
//! The microphone facade (the capture extension of `core/audio.zig`) and the camera facade (`core/camera.zig`) share
//! the types here, and that is what makes the control plane unified: the same verb concepts, the same error
//! classification and the same type shapes (no unified `CaptureDevice` union or vtable is created. The naming may
//! differ to suit the host module, but the semantics match). The authority on the design is `docs/capture.md`.
//!
//! `capture_types` is `link()`ed as a named module into **both** the `camera` module and the `audio`
//! module (for the same reason as platform_types.zig: a relative Zig import yields a distinct type instance per
//! module, so a shared type needing type identity must be a named module).
//!
//! Dependencies: std alone (a type-only module like platform_types.zig; ADR-007 also permits libs to reference it).
//!
//! Hot path declaration: this file itself is only type definitions plus `TripleBuffer(T)`'s publish and acquire,
//! and **contains no per-frame (all-pixel) or real-time (per-sample) loop**. `TripleBuffer(T)` is however
//! used to deliver frames from the camera's capture thread to the main thread (the capture thread is expected to call
//! `publish()` once per frame), so `publish` and `acquire` themselves stay O(1) with no alloc or lock
//! (the real-time and capture-thread constraint).

const std = @import("std");

// ============================================================================
// the shared control plane types
// ============================================================================

/// What kind of capture device it is (a microphone or a camera).
pub const DeviceKind = enum { audio_in, video_in };

/// One entry of an enumeration result. `id` and `name` are allocated with the allocator `enumerate()` was
/// given, and the caller frees them with `freeDeviceList()`.
pub const DeviceInfo = struct {
    id: []const u8,
    name: []const u8,
    kind: DeviceKind,
    is_default: bool = false,
};

/// Frees a `[]DeviceInfo` returned by `enumerate()` symmetrically (freeing id and name individually, then the slice).
/// Every backend implements `enumerate()` under this allocator contract.
pub fn freeDeviceList(allocator: std.mem.Allocator, devices: []DeviceInfo) void {
    for (devices) |d| {
        allocator.free(d.id);
        allocator.free(d.name);
    }
    allocator.free(devices);
}

/// The permission state (a classification shared by microphone and camera).
/// - `denied`: the user refused explicitly, and can change it in a settings application.
/// - `restricted`: policy such as an MDM profile makes it unchangeable in the first place (macOS TCC's
///   `authorizationStatus` really does return these four values). It gives a UI the basis to choose between prompting to open Settings and saying it cannot be changed.
pub const PermissionState = enum { not_determined, granted, denied, restricted };

/// The error set the microphone and camera facades share (what the unified control plane actually consists of).
/// An allocator failure (an alloc inside `enumerate` or `open`) is folded into `OpenFailed` (the same conversion
/// convention as the existing output backends' `allocator.create(State) catch return error.OpenFailed;`. `OutOfMemory` is
/// not unioned in — a trade-off preferring the simplicity of a single error set and consistency within the codebase).
pub const CaptureError = error{
    PermissionDenied, // permission is explicitly denied or restricted
    NoDevice, // the device in question does not exist
    DeviceLost, // the device was disconnected while running
    ConfigFailed, // the format negotiation failed
    Unsupported, // an unimplemented backend (every OS stub returns this) or a feature the OS does not support
    OpenFailed, // the device failed to initialise (a general failure, an allocator failure included)
    StartFailed, // start() failed
};

// ============================================================================
// data plane: audio in (PCM)
// ============================================================================

/// One chunk handed to a mic capture callback (a read-only view).
/// Asymmetric with the output `RenderCallback`, which hands over a buffer to write into: an input hands over a finished product.
/// `samples` is valid only while the callback runs (the same lifetime convention as the output `RenderCallback`'s `buf`).
///
/// `CaptureCallback` (the callback function pointer type) and `Config`/`EffectiveConfig` do not live in capture_types
/// but in the microphone-side backend file (`core/audio_capture_stub.zig`), following the same placement convention by which
/// the output's `RenderCallback` and `Config` live in a backend file such as `audio_macos.zig`.
pub const AudioInFrame = struct {
    samples: []const f32, // interleaved
    frames: u32,
    channels: u32,
    sample_rate: u32,
    timestamp_ns: u64,
};

// ============================================================================
// the data plane: video (BGRA frames)
// ============================================================================

/// A capture frame's pixel format. Delivery is always normalised to canonical BGRA (the MVP has `bgra8` alone).
/// Normalising it (converting a native format such as YUY2 or NV12 to BGRA) is the backend's responsibility.
/// It is an enum rather than a bool, so declaring another format stays an additive change.
pub const PixelFormat = enum { bgra8 };

/// One camera frame. `pixels` is canonical BGRA (the same representation as the framebuffer of `core/platform.zig`:
/// a u32 `0xAARRGGBB`). The lifetime convention of the view `VideoDevice.pollLatestFrame()` returns is "valid until
/// `pollLatestFrame()` is next called" (the `front` slot contract of `TripleBuffer`).
pub const VideoFrame = struct {
    pixels: []const u32, // row-major, in units of stride (one element = one pixel)
    width: u32,
    height: u32,
    stride: u32, // the pixel count per row (>= width, to absorb native padding)
    format: PixelFormat = .bgra8,
    timestamp_ns: u64,
    frame_index: u64,
};

// ============================================================================
// the latest-wins handover of video frames (three fixed slots, from the capture thread to the main thread)
// ============================================================================

/// A three-slot SPSC built on the single atomic `shared` (designed so the producer never writes the read slot).
/// The same shape as `libs/modular`'s `Mailbox(T)`, but core cannot depend on libs (ADR-007 R2), so
/// a self-contained copy lives here inside core (the same approach by which `core/audio_null.zig`
/// duplicates the equivalent of `platform.sleep()`, following the existing rule of not re-importing across layers).
///
/// `T` is expected to be **a POD or view type only, since publishing copies by value**. A type owning memory
/// that needs `deinit` does not go in `T`. `VideoFrame` qualifies, holding `pixels: []const u32` only as a
/// view onto an externally fixed buffer.
///
/// The producer (the capture thread) only calls `publish()` and never blocks. The consumer (main) only calls
/// `acquire()`. The three indices (`write_idx`, `read_idx` and the low 2 bits of `shared`) are always a permutation of
/// `{0,1,2}`, and the producer never writes the slot currently being read or ready (a test pins the invariant).
pub fn TripleBuffer(comptime T: type) type {
    return struct {
        const Self = @This();
        const FRESH: u8 = 0x80;
        const IDX_MASK: u8 = 0x03;

        bufs: [3]T,
        shared: std.atomic.Value(u8),
        write_idx: u8, // producer(capture thread)-private
        read_idx: u8, // consumer(main)-private

        pub fn init(initial: T) Self {
            return .{
                .bufs = .{ initial, initial, initial },
                .shared = .init(2), // slot2 published(no fresh) / write=0 / read=1
                .write_idx = 0,
                .read_idx = 1,
            };
        }

        /// The producer (the capture thread): it writes into its private write slot and then swaps it with ready. It never blocks.
        pub fn publish(self: *Self, value: T) void {
            self.bufs[self.write_idx] = value;
            const new: u8 = self.write_idx | FRESH;
            const old = self.shared.swap(new, .acq_rel);
            self.write_idx = old & IDX_MASK;
        }

        /// The consumer (main): when something is fresh it swaps the read slot with ready to latch the newest, and otherwise
        /// keeps the previous view (latest-wins, so frames may be dropped).
        pub fn acquire(self: *Self) *const T {
            const s = self.shared.load(.acquire);
            if (s & FRESH != 0) {
                const old = self.shared.swap(self.read_idx, .acq_rel);
                self.read_idx = old & IDX_MASK;
            }
            return &self.bufs[self.read_idx];
        }

        /// For the tests: confirms the three indices are a permutation of {0,1,2} (the invariant).
        pub fn indicesArePermutation(self: *const Self) bool {
            const a = self.write_idx & IDX_MASK;
            const b = self.read_idx & IDX_MASK;
            const c = self.shared.load(.monotonic) & IDX_MASK;
            return a != b and b != c and a != c and a < 3 and b < 3 and c < 3;
        }
    };
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "DeviceInfo and freeDeviceList: allocation and freeing follow the allocator contract (leak detection through testing.allocator)" {
    const allocator = testing.allocator;
    var devices = try allocator.alloc(DeviceInfo, 2);
    devices[0] = .{ .id = try allocator.dupe(u8, "dev-0"), .name = try allocator.dupe(u8, "Built-in Mic"), .kind = .audio_in, .is_default = true };
    devices[1] = .{ .id = try allocator.dupe(u8, "dev-1"), .name = try allocator.dupe(u8, "USB Cam"), .kind = .video_in };
    freeDeviceList(allocator, devices);
    // testing.allocator detects a leak at the end of the function, so reaching here means the freeing is correct.
}

test "CaptureError: every member is present in the single capture_types source (an existence check)" {
    const a: CaptureError = error.PermissionDenied;
    const b: CaptureError = error.NoDevice;
    const c: CaptureError = error.DeviceLost;
    const d: CaptureError = error.ConfigFailed;
    const e: CaptureError = error.Unsupported;
    const f: CaptureError = error.OpenFailed;
    const g: CaptureError = error.StartFailed;
    try testing.expectError(error.PermissionDenied, @as(CaptureError!void, a));
    try testing.expectError(error.NoDevice, @as(CaptureError!void, b));
    try testing.expectError(error.DeviceLost, @as(CaptureError!void, c));
    try testing.expectError(error.ConfigFailed, @as(CaptureError!void, d));
    try testing.expectError(error.Unsupported, @as(CaptureError!void, e));
    try testing.expectError(error.OpenFailed, @as(CaptureError!void, f));
    try testing.expectError(error.StartFailed, @as(CaptureError!void, g));
}

test "PermissionState: pinned at four values (a design distinguishing not_determined, granted, denied and restricted)" {
    try testing.expectEqual(@as(usize, 4), @typeInfo(PermissionState).@"enum".fields.len);
}

test "AudioInFrame and VideoFrame: they are POD (handled by value copy, needing no allocator)" {
    const frame = AudioInFrame{ .samples = &.{}, .frames = 0, .channels = 1, .sample_rate = 48000, .timestamp_ns = 0 };
    const copy = frame;
    try testing.expectEqual(frame.sample_rate, copy.sample_rate);

    const vf = VideoFrame{ .pixels = &.{}, .width = 0, .height = 0, .stride = 0, .timestamp_ns = 0, .frame_index = 0 };
    const vf_copy = vf;
    try testing.expectEqual(vf.format, vf_copy.format);
}

test "TripleBuffer: before a publish, the value from just after init is visible" {
    var tb = TripleBuffer(u32).init(42);
    try testing.expectEqual(@as(u32, 42), tb.acquire().*);
}

test "TripleBuffer: publish then acquire shows the newest value (a latest-wins round trip)" {
    var tb = TripleBuffer(u32).init(0);
    tb.publish(1);
    try testing.expectEqual(@as(u32, 1), tb.acquire().*);
    tb.publish(2);
    tb.publish(3);
    // Publishing several times without an intervening acquire still shows only the newest value at the next acquire (frames may be dropped).
    try testing.expectEqual(@as(u32, 3), tb.acquire().*);
}

test "TripleBuffer: an acquire with nothing published keeps the previous view (with nothing fresh it does not re-latch)" {
    var tb = TripleBuffer(u32).init(7);
    _ = tb.acquire();
    // Nothing was published, so acquiring any number of times gives the same value.
    try testing.expectEqual(@as(u32, 7), tb.acquire().*);
    try testing.expectEqual(@as(u32, 7), tb.acquire().*);
}

test "TripleBuffer: the three indices are always a permutation of {0,1,2} (the invariant that the producer never writes the read slot)" {
    var tb = TripleBuffer(u32).init(0);
    try testing.expect(tb.indicesArePermutation());
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        tb.publish(i);
        try testing.expect(tb.indicesArePermutation());
        if (i % 3 == 0) {
            _ = tb.acquire();
            try testing.expect(tb.indicesArePermutation());
        }
    }
}

test "TripleBuffer: a VideoFrame (a view type) can be handled by value (the POD and view contract needing no deinit)" {
    var backing = [_]u32{ 0xFF000000, 0xFF00FF00 };
    var tb = TripleBuffer(VideoFrame).init(.{ .pixels = &.{}, .width = 0, .height = 0, .stride = 0, .timestamp_ns = 0, .frame_index = 0 });
    tb.publish(.{ .pixels = &backing, .width = 2, .height = 1, .stride = 2, .timestamp_ns = 123, .frame_index = 1 });
    const got = tb.acquire();
    try testing.expectEqual(@as(u32, 2), got.width);
    try testing.expectEqual(@as(usize, 2), got.pixels.len);
    try testing.expectEqual(@as(u64, 1), got.frame_index);
}

test "TripleBuffer: the real-time contract — publish and acquire take no allocator argument (pinning zero allocation through the type signature)" {
    // publish and acquire take no std.mem.Allocator at all, so the call itself cannot allocate. In line with the
    // performance rule that a performance claim is pinned by a test, the argument count of the signature is fixed at
    // comptime (a change adding an argument, letting an alloc creep in, becomes a compile error through this test's type mismatch).
    const PublishFn = @TypeOf(TripleBuffer(u32).publish);
    const AcquireFn = @TypeOf(TripleBuffer(u32).acquire);
    try testing.expectEqual(@as(usize, 2), @typeInfo(PublishFn).@"fn".params.len);
    try testing.expectEqual(@as(usize, 1), @typeInfo(AcquireFn).@"fn".params.len);

    // It really does work over a great many round trips (a functional re-check).
    var tb = TripleBuffer(u32).init(0);
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        tb.publish(i);
        _ = tb.acquire();
    }
    try testing.expectEqual(@as(u32, 999), tb.acquire().*);
}
