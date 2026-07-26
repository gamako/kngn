//! macOS camera backend (an L1 camera input primitive). It drives AVFoundation through the Objective-C runtime's
//! C ABI (the `objc_msgSend` family, in `core/objc_runtime.zig`). Neither `@cImport` nor Swift is used
//! (the same approach as calling AudioToolbox's C ABI directly. AVFoundation itself has no C API, so libobjc's
//! C ABI is used as the bridge. Only aarch64-darwin is supported; the detailed reasoning is in the comment at the
//! head of `core/objc_runtime.zig`).
//!
//! **Frame delivery**: `AVCaptureVideoDataOutput`'s sample buffer delegate (the dynamically created ObjC
//! subclass `VPCameraCaptureDelegate`) is called on a dispatch queue for capture (a dedicated GCD thread),
//! and publishes the `CVPixelBuffer` (with `kCVPixelFormatType_32BGRA` requested explicitly) straight into
//! `capture_types.TripleBuffer` as canonical BGRA. Normalising it is only a row copy absorbing the stride
//! (`copyBgraRows`, with no per-pixel arithmetic). Because BGRA is requested explicitly, converting from a
//! native format such as YUV happens inside the OS.
//!
//! **The MVP's known simplifications**:
//! - Only one camera can be open at a time (`g_active_state` is a process-wide singleton, and using several
//!   `open()`s at once is unsupported, consistent with opening several devices being out of scope).
//! - `device.config()`'s `frame_rate` is the requested value, not a negotiated one; `format` is always
//!   `.bgra8` and is accurate.
//! - `open()` ignores `device_id` and always takes the default camera, so a specific device cannot be
//!   selected.
//!
//! Hot path declaration:
//! - **The delegate callback (`sampleBufferCallback`) is called every frame on the capture thread (a dedicated
//!   GCD thread, in real time at roughly the camera's fps, 30fps by default)**. Within that region malloc, locking, IO and panic are forbidden
//!   (the same strength as the existing audio backends' real-time contract). All it does is `CVPixelBufferLockBaseAddress`
//!   (a lock the API contract requires, not a general mutex) plus `copyBgraRows` (a row copy) plus
//!   `TripleBuffer.publish()` (with no alloc or lock). The buffers are allocated up front at `open()`.
//! - **`copyBgraRows`**: per frame, over what amounts to every pixel. It is only an `@memcpy` absorbing the stride, with no
//!   per-pixel arithmetic (blending or division), so the performance rules' three rules for an all-pixel loop (SIMD, div255,
//!   clip hoisting) are judged not to apply. It is a plain copy, which if anything matches the existing rule recommending
//!   an `@memset` or bulk-write fast path for an opaque full-area fill. Adding a conversion from a native format
//!   other than BGRA (YUV to RGB, say) would make it per-pixel arithmetic and needs judging afresh.
//! - `enumerate`, `requestPermission`, `open`, `start`, `stop` and `close`: **initialisation time or event time only**
//!   (neither per frame nor per sample).

const std = @import("std");
const types = @import("capture_types");
const objc = @import("objc_runtime");

// ============================================================================
// the AVFoundation, CoreMedia and CoreVideo C ABI (a minimal subset)
// ============================================================================

/// The `NSString * const AVMediaTypeVideo` constant AVFoundation.framework publishes.
extern "c" const AVMediaTypeVideo: objc.Id;

/// CoreMedia.framework: takes the `CVImageBufferRef` (really a `CVPixelBufferRef`) out of a
/// `CMSampleBufferRef` (a C API, needing no ObjC).
extern "c" fn CMSampleBufferGetImageBuffer(sbuf: objc.Id) objc.Id;

/// CoreVideo.framework: the `CVPixelBuffer` C APIs.
extern "c" fn CVPixelBufferLockBaseAddress(pixel_buffer: objc.Id, lock_flags: u64) i32; // CVReturn
extern "c" fn CVPixelBufferUnlockBaseAddress(pixel_buffer: objc.Id, lock_flags: u64) i32;
extern "c" fn CVPixelBufferGetBaseAddress(pixel_buffer: objc.Id) ?*anyopaque;
extern "c" fn CVPixelBufferGetBytesPerRow(pixel_buffer: objc.Id) usize;
extern "c" fn CVPixelBufferGetWidth(pixel_buffer: objc.Id) usize;
extern "c" fn CVPixelBufferGetHeight(pixel_buffer: objc.Id) usize;

/// The `NSString * const kCVPixelBufferPixelFormatTypeKey` constant CoreVideo.framework publishes.
extern "c" const kCVPixelBufferPixelFormatTypeKey: objc.Id;
/// The CoreVideo key requesting the output pixel buffer's size. Setting it in videoSettings makes AVFoundation
/// **scale the full field of view to that size** before delivery. Left unset, delivery uses the session preset's native
/// resolution (640x480 and the like) and `onFrame`'s `copyBgraRows` copies only the top-left `min(src, requested)`,
/// so only part of the field of view is shown, cropped.
extern "c" const kCVPixelBufferWidthKey: objc.Id;
extern "c" const kCVPixelBufferHeightKey: objc.Id;

const kCVPixelBufferLock_ReadOnly: u64 = 0x0000_0001;
/// The FourCharCode of 'BGRA' (a numeric constant, not an NSString).
const kCVPixelFormatType_32BGRA: u32 = 0x4247_5241;

/// libdispatch (GCD, built into libSystem, needing no framework link).
extern "c" fn dispatch_queue_create(label: ?[*:0]const u8, attr: ?*anyopaque) ?*anyopaque;
extern "c" fn dispatch_release(object: ?*anyopaque) void;
extern "c" fn dispatch_sync_f(queue: ?*anyopaque, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;

// ============================================================================
// Normalising: a row copy absorbing the stride (per frame; the hot path declaration is at the head of the file)
// ============================================================================

/// Copies `width`x`height` worth, row by row, from `src` (a native BGRA8 buffer padded to
/// `src_bytes_per_row`) into `dst` (a fixed buffer allocated in units of `dst_stride` pixels).
/// A plain `@memcpy` with no per-pixel arithmetic (outside the performance rules; the reasoning is in the hot path declaration at the head of the file).
pub fn copyBgraRows(
    dst: []u32,
    dst_stride: u32,
    src: [*]const u8,
    src_bytes_per_row: usize,
    width: u32,
    height: u32,
) void {
    const row_bytes = @as(usize, width) * 4;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_row = src[@as(usize, y) * src_bytes_per_row ..][0..row_bytes];
        const dst_row_start = @as(usize, y) * dst_stride;
        const dst_row = std.mem.sliceAsBytes(dst[dst_row_start..][0..width]);
        @memcpy(dst_row, src_row);
    }
}

// ============================================================================
// permission
// ============================================================================

fn mapAuthStatus(status: i64) types.PermissionState {
    return switch (status) {
        0 => .not_determined,
        1 => .restricted,
        2 => .denied,
        3 => .granted,
        else => .denied,
    };
}

/// Requests camera permission and returns the settled state (blocking). **Only from not_determined does it
/// actually attempt the TCC dialogue** (when it is already granted, denied or restricted it raises no second dialogue and
/// returns that state at once). Do not call it from an automated test; it is for manual verification.
pub fn requestPermission() types.CaptureError!types.PermissionState {
    const initial = mapAuthStatus(objc.avAuthorizationStatus(AVMediaTypeVideo));
    if (initial != .not_determined) return initial;
    const granted = objc.avRequestAccessBlocking(AVMediaTypeVideo);
    return if (granted) .granted else .denied;
}

// ============================================================================
// enumeration
// ============================================================================

/// Enumerates the connected cameras with `AVCaptureDevice.devicesWithMediaType:` (enumeration itself requires no
/// TCC permission. Confirming it against real hardware is for manual verification).
pub fn enumerate(allocator: std.mem.Allocator) types.CaptureError![]types.DeviceInfo {
    const cls = objc.getClass("AVCaptureDevice");
    const devices_ns = objc.msgSend(objc.Id, cls, objc.sel("devicesWithMediaType:"), .{AVMediaTypeVideo});
    if (devices_ns == null) return error.NoDevice;
    const count: i64 = objc.msgSend(i64, devices_ns, objc.sel("count"), .{});
    if (count <= 0) return allocator.alloc(types.DeviceInfo, 0) catch return error.OpenFailed;

    var list: std.ArrayList(types.DeviceInfo) = .empty;
    errdefer {
        for (list.items) |d| {
            allocator.free(d.id);
            allocator.free(d.name);
        }
        list.deinit(allocator);
    }
    var i: i64 = 0;
    while (i < count) : (i += 1) {
        const dev = objc.msgSend(objc.Id, devices_ns, objc.sel("objectAtIndex:"), .{@as(usize, @intCast(i))});
        const name_ns = objc.msgSend(objc.Id, dev, objc.sel("localizedName"), .{});
        const uid_ns = objc.msgSend(objc.Id, dev, objc.sel("uniqueID"), .{});
        const name_c = objc.msgSend([*:0]const u8, name_ns, objc.sel("UTF8String"), .{});
        const uid_c = objc.msgSend([*:0]const u8, uid_ns, objc.sel("UTF8String"), .{});
        const name_dup = allocator.dupe(u8, std.mem.span(name_c)) catch return error.OpenFailed;
        errdefer allocator.free(name_dup);
        const id_dup = allocator.dupe(u8, std.mem.span(uid_c)) catch return error.OpenFailed;
        errdefer allocator.free(id_dup);
        list.append(allocator, .{ .id = id_dup, .name = name_dup, .kind = .video_in, .is_default = (i == 0) }) catch return error.OpenFailed;
    }
    return list.toOwnedSlice(allocator) catch return error.OpenFailed;
}

// ============================================================================
// the dynamic delegate class (receiving sample buffers)
// ============================================================================

var delegate_class: objc.Class = null;

fn noopDrain(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
}

/// Called on the capture thread (a GCD queue). **A real-time contract region**: no malloc, locking, IO or panic
/// (see the hot path declaration at the head of the file). `g_active_state` is read only through an atomic,
/// because `close()` nulls it from another thread, namely main.
fn sampleBufferCallback(self_: objc.Id, _cmd: objc.SEL, output: objc.Id, sample_buffer: objc.Id, connection: objc.Id) callconv(.c) void {
    _ = self_;
    _ = _cmd;
    _ = output;
    _ = connection;
    const state = g_active_state.load(.acquire) orelse return;

    const image_buf = CMSampleBufferGetImageBuffer(sample_buffer) orelse return;
    if (CVPixelBufferLockBaseAddress(image_buf, kCVPixelBufferLock_ReadOnly) != 0) return;
    defer _ = CVPixelBufferUnlockBaseAddress(image_buf, kCVPixelBufferLock_ReadOnly);

    const base = CVPixelBufferGetBaseAddress(image_buf) orelse return;
    const bytes_per_row = CVPixelBufferGetBytesPerRow(image_buf);
    const src_w: usize = CVPixelBufferGetWidth(image_buf);
    const src_h: usize = CVPixelBufferGetHeight(image_buf);
    const w: u32 = @intCast(@min(src_w, state.width));
    const h: u32 = @intCast(@min(src_h, state.height));

    const slot = state.triple.write_idx & 0x03;
    const dst = state.slot_pixels[slot];
    copyBgraRows(dst, state.width, @ptrCast(base), bytes_per_row, w, h);

    const frame_index = state.frame_counter.fetchAdd(1, .monotonic);
    state.triple.publish(.{
        .pixels = dst,
        .width = state.width,
        .height = state.height,
        .stride = state.width,
        .format = .bgra8,
        .timestamp_ns = 0, // MVP: converting CMSampleBuffer's PTS is not implemented
        .frame_index = frame_index,
    });
}

/// Dynamically creates `VPCameraCaptureDelegate` (an NSObject subclass implementing only
/// `captureOutput:didOutputSampleBuffer:fromConnection:`) on the first call alone. It is registered exactly once per
/// process (`objc_allocateClassPair` returns null when a class of the same name already exists, and in that case
/// a guard picks up the existing class with `objc_getClass`).
fn ensureDelegateClass() objc.Class {
    if (delegate_class) |c| return c;
    const superclass = objc.getClass("NSObject");
    const cls = objc.objc_allocateClassPair(superclass, "VPCameraCaptureDelegate", 0) orelse {
        delegate_class = objc.getClass("VPCameraCaptureDelegate");
        return delegate_class;
    };
    const sel_name = objc.sel("captureOutput:didOutputSampleBuffer:fromConnection:");
    _ = objc.class_addMethod(cls, sel_name, @ptrCast(&sampleBufferCallback), "v@:@@@");
    // It does not affect the runtime semantics (setSampleBufferDelegate:queue: itself does not check protocol
    // conformance when it goes through the raw runtime), but it is declared for the sake of `conformsToProtocol:` and introspection.
    if (objc.objc_getProtocol("AVCaptureVideoDataOutputSampleBufferDelegate")) |proto| {
        _ = objc.class_addProtocol(cls, proto);
    }
    objc.objc_registerClassPair(cls);
    delegate_class = cls;
    return cls;
}

// ============================================================================
// the public types
// ============================================================================

pub const MAX_VIDEO_DIM: u32 = 4096;

/// The requested settings (hints only). The effective values are read with `device.config()` after `open()`.
pub const Config = struct {
    device_id: ?[]const u8 = null, // unused: the default camera is always opened, so this selects nothing
    width: u32 = 640,
    height: u32 = 480,
    frame_rate: u32 = 30,
};

/// The effective values `open()` returns.
pub const EffectiveConfig = struct {
    width: u32,
    height: u32,
    frame_rate: u32,
    format: types.PixelFormat = .bgra8,
};

const State = struct {
    session: objc.Id,
    device_input: objc.Id,
    output: objc.Id,
    delegate: objc.Id,
    queue: ?*anyopaque,
    width: u32,
    height: u32,
    frame_rate: u32,
    running: bool,
    allocator: std.mem.Allocator,
    triple: types.TripleBuffer(types.VideoFrame),
    frame_counter: std.atomic.Value(u64),
    slot_pixels: [3][]u32, // the physical pixel buffer corresponding to each of the TripleBuffer's three slots
};

/// A process-wide singleton (an MVP simplification; see the comment at the head of the file). It is atomic
/// because both the capture thread and the main thread touch it.
var g_active_state: std.atomic.Value(?*State) = .init(null);

pub const VideoDevice = struct {
    state: *State,

    pub fn config(self: VideoDevice) EffectiveConfig {
        return .{
            .width = self.state.width,
            .height = self.state.height,
            .frame_rate = self.state.frame_rate,
            .format = .bgra8,
        };
    }

    pub fn start(self: VideoDevice) types.CaptureError!void {
        if (self.state.running) return;
        objc.msgSend(void, self.state.session, objc.sel("startRunning"), .{});
        self.state.running = true;
    }

    pub fn stop(self: VideoDevice) void {
        if (!self.state.running) return;
        objc.msgSend(void, self.state.session, objc.sel("stopRunning"), .{});
        self.state.running = false;
    }

    /// stop, then **detach the delegate from the output** (`setSampleBufferDelegate:queue:` with
    /// nil and nil, after which the output enqueues no new callback at all), then null `g_active_state`,
    /// then drain the capture queue (waiting for callbacks that had **already** been enqueued before the detach to
    /// finish, guaranteed by a no-op `dispatch_sync_f` on the same serial queue), then release the ObjC objects,
    /// then free the physical buffers, then destroy the State.
    ///
    /// Detaching before draining matters: nulling `g_active_state` and draining alone would still leave room for
    /// AVFoundation to enqueue a new callback after the drain, which could be a use-after-free on the released
    /// delegate. Detaching the delegate first removes that risk.
    pub fn close(self: VideoDevice) void {
        const state = self.state;
        if (state.running) {
            objc.msgSend(void, state.session, objc.sel("stopRunning"), .{});
            state.running = false;
        }
        objc.msgSend(void, state.output, objc.sel("setSampleBufferDelegate:queue:"), .{ @as(objc.Id, null), @as(?*anyopaque, null) });
        g_active_state.store(null, .release);
        dispatch_sync_f(state.queue, null, noopDrain);

        objc.msgSend(void, state.output, objc.sel("release"), .{});
        objc.msgSend(void, state.device_input, objc.sel("release"), .{});
        objc.msgSend(void, state.session, objc.sel("release"), .{});
        objc.msgSend(void, state.delegate, objc.sel("release"), .{});
        dispatch_release(state.queue);

        for (state.slot_pixels) |buf| state.allocator.free(buf);
        state.allocator.destroy(state);
    }

    /// Gets the most recent frame without blocking. `null` when nothing has been published yet
    /// (right after `open`, or before capture starts).
    pub fn pollLatestFrame(self: VideoDevice) ?types.VideoFrame {
        if (self.state.frame_counter.load(.monotonic) == 0) return null;
        return self.state.triple.acquire().*;
    }
};

/// Opens the camera. When `cfg.width`, `height` or `frame_rate` is 0, or exceeds `MAX_VIDEO_DIM`,
/// it calls no AVFoundation at all and gives `error.ConfigFailed` (this path is automatically tested, and it prevents a runaway allocation).
/// The other path, which really does assemble an `AVCaptureSession`, depends on a real device and on TCC permission,
/// so it is not called from an automated test; it is for manual verification.
///
/// **Only one camera can be open at a time** (`g_active_state` is a process-wide singleton: letting a second
/// `open()` through would let the callback or `close()` of the device already open wreck the later
/// `State`). When one is already active it calls no AVFoundation and gives
/// `error.OpenFailed` at once (a fail-fast check). It is checked again at the end of the function with `cmpxchgStrong`
/// to prevent a race between two concurrent `open()`s (the loser frees everything acquired so far through errdefer).
pub fn open(allocator: std.mem.Allocator, cfg: Config) types.CaptureError!VideoDevice {
    if (cfg.width == 0 or cfg.height == 0 or cfg.frame_rate == 0) return error.ConfigFailed;
    if (cfg.width > MAX_VIDEO_DIM or cfg.height > MAX_VIDEO_DIM) return error.ConfigFailed;
    if (g_active_state.load(.acquire) != null) return error.OpenFailed; // fail-fast (one camera is already open)

    const device = objc.msgSend(objc.Id, objc.getClass("AVCaptureDevice"), objc.sel("defaultDeviceWithMediaType:"), .{AVMediaTypeVideo});
    if (device == null) return error.NoDevice;

    const device_input = objc.msgSend(objc.Id, objc.getClass("AVCaptureDeviceInput"), objc.sel("deviceInputWithDevice:error:"), .{ device, @as(objc.Id, null) });
    if (device_input == null) return error.OpenFailed;
    _ = objc.msgSend(objc.Id, device_input, objc.sel("retain"), .{});
    errdefer objc.msgSend(void, device_input, objc.sel("release"), .{});

    const session = objc.msgSend(objc.Id, objc.msgSend(objc.Id, objc.getClass("AVCaptureSession"), objc.sel("alloc"), .{}), objc.sel("init"), .{});
    if (session == null) return error.OpenFailed;
    errdefer objc.msgSend(void, session, objc.sel("release"), .{});
    objc.msgSend(void, session, objc.sel("addInput:"), .{device_input});

    const output = objc.msgSend(objc.Id, objc.msgSend(objc.Id, objc.getClass("AVCaptureVideoDataOutput"), objc.sel("alloc"), .{}), objc.sel("init"), .{});
    if (output == null) return error.OpenFailed;
    errdefer objc.msgSend(void, output, objc.sel("release"), .{});

    // videoSettings = { kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA (numeric) }
    const dict = objc.msgSend(objc.Id, objc.msgSend(objc.Id, objc.getClass("NSMutableDictionary"), objc.sel("alloc"), .{}), objc.sel("init"), .{});
    if (dict == null) return error.OpenFailed;
    const num = objc.msgSend(objc.Id, objc.getClass("NSNumber"), objc.sel("numberWithUnsignedInt:"), .{@as(u32, kCVPixelFormatType_32BGRA)});
    objc.msgSend(void, dict, objc.sel("setObject:forKey:"), .{ num, kCVPixelBufferPixelFormatTypeKey });
    // Give the requested size so the full field of view is scaled before delivery (left unset it is cropped at the native resolution).
    const wnum = objc.msgSend(objc.Id, objc.getClass("NSNumber"), objc.sel("numberWithUnsignedInt:"), .{cfg.width});
    objc.msgSend(void, dict, objc.sel("setObject:forKey:"), .{ wnum, kCVPixelBufferWidthKey });
    const hnum = objc.msgSend(objc.Id, objc.getClass("NSNumber"), objc.sel("numberWithUnsignedInt:"), .{cfg.height});
    objc.msgSend(void, dict, objc.sel("setObject:forKey:"), .{ hnum, kCVPixelBufferHeightKey });
    objc.msgSend(void, output, objc.sel("setVideoSettings:"), .{dict});
    objc.msgSend(void, dict, objc.sel("release"), .{});
    objc.msgSend(void, output, objc.sel("setAlwaysDiscardsLateVideoFrames:"), .{true});

    const queue = dispatch_queue_create("video-proto.camera.capture", null);
    if (queue == null) return error.OpenFailed;
    errdefer dispatch_release(queue);

    const delegate_cls = ensureDelegateClass();
    const delegate = objc.msgSend(objc.Id, objc.msgSend(objc.Id, delegate_cls, objc.sel("alloc"), .{}), objc.sel("init"), .{});
    if (delegate == null) return error.OpenFailed;
    errdefer objc.msgSend(void, delegate, objc.sel("release"), .{});

    objc.msgSend(void, output, objc.sel("setSampleBufferDelegate:queue:"), .{ delegate, queue });
    objc.msgSend(void, session, objc.sel("addOutput:"), .{output});

    const n = @as(usize, cfg.width) * @as(usize, cfg.height);
    var slot_pixels: [3][]u32 = undefined;
    var allocated: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < allocated) : (i += 1) allocator.free(slot_pixels[i]);
    }
    while (allocated < 3) : (allocated += 1) {
        slot_pixels[allocated] = allocator.alloc(u32, n) catch return error.OpenFailed;
        @memset(slot_pixels[allocated], 0xFF00_0000); // opaque black before anything is published (symmetrical with the framebuffer's initial value)
    }

    const state = allocator.create(State) catch return error.OpenFailed;
    errdefer allocator.destroy(state);
    var triple = types.TripleBuffer(types.VideoFrame).init(.{
        .pixels = slot_pixels[0],
        .width = cfg.width,
        .height = cfg.height,
        .stride = cfg.width,
        .format = .bgra8,
        .timestamp_ns = 0,
        .frame_index = 0,
    });
    // init() copies the same initial value into all three slots, so each slot is explicitly re-pinned to
    // point at its own physical buffer (satisfying "fixed to three physical pixel buffers" from `open()`
    // onwards).
    triple.bufs[0].pixels = slot_pixels[0];
    triple.bufs[1].pixels = slot_pixels[1];
    triple.bufs[2].pixels = slot_pixels[2];

    state.* = .{
        .session = session,
        .device_input = device_input,
        .output = output,
        .delegate = delegate,
        .queue = queue,
        .width = cfg.width,
        .height = cfg.height,
        .frame_rate = cfg.frame_rate,
        .running = false,
        .allocator = allocator,
        .triple = triple,
        .frame_counter = .init(0),
        .slot_pixels = slot_pixels,
    };

    // Check again with cmpxchg (guarding against a race between two concurrent open()s. If another open() got
    // in first after the fail-fast check, everything acquired so far is freed through errdefer and this one fails).
    if (g_active_state.cmpxchgStrong(null, state, .acq_rel, .acquire) != null) {
        return error.OpenFailed;
    }
    return .{ .state = state };
}

// ============================================================================
// tests (only the range needing no display or real device runs automatically; the manual tests are at the end)
// ============================================================================
const testing = std.testing;

test "copyBgraRows: it extracts correctly from a padded source, absorbing the stride" {
    const width: u32 = 3;
    const height: u32 = 2;
    const bytes_per_row: usize = 16; // width*4=12 + 4 byte padding
    const row0 = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0xFF, 0xFF, 0xFF, 0xFF };
    const row1 = [_]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0xFF, 0xFF, 0xFF, 0xFF };
    var src: [32]u8 = undefined;
    @memcpy(src[0..16], &row0);
    @memcpy(src[16..32], &row1);

    var dst: [6]u32 = undefined; // stride == width == 3 (no padding)
    copyBgraRows(&dst, 3, &src, bytes_per_row, width, height);

    var expected: [24]u8 = undefined;
    @memcpy(expected[0..12], row0[0..12]);
    @memcpy(expected[12..24], row1[0..12]);
    try testing.expectEqualSlices(u8, &expected, std.mem.sliceAsBytes(dst[0..]));
}

test "copyBgraRows: even with dst_stride > width it writes the correct columns (absorbing the padding on the dst side too)" {
    const width: u32 = 2;
    const height: u32 = 2;
    const bytes_per_row: usize = 8; // width*4=8, a source with no padding
    const row0 = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const row1 = [_]u8{ 9, 10, 11, 12, 13, 14, 15, 16 };
    var src: [16]u8 = undefined;
    @memcpy(src[0..8], &row0);
    @memcpy(src[8..16], &row1);

    var dst = [_]u32{0xDEADBEEF} ** 8; // stride=4 (width=2 + padding 2px)
    copyBgraRows(&dst, 4, &src, bytes_per_row, width, height);

    const dst_bytes = std.mem.sliceAsBytes(dst[0..]);
    try testing.expectEqualSlices(u8, &row0, dst_bytes[0..8]); // row0's real data
    try testing.expectEqual(@as(u32, 0xDEADBEEF), dst[2]); // row0's padding columns are unchanged
    try testing.expectEqual(@as(u32, 0xDEADBEEF), dst[3]);
    try testing.expectEqualSlices(u8, &row1, dst_bytes[16..24]); // row1 (from the dst_stride=4 position)
}

test "mapAuthStatus: it maps AVAuthorizationStatus's four values correctly" {
    try testing.expectEqual(types.PermissionState.not_determined, mapAuthStatus(0));
    try testing.expectEqual(types.PermissionState.restricted, mapAuthStatus(1));
    try testing.expectEqual(types.PermissionState.denied, mapAuthStatus(2));
    try testing.expectEqual(types.PermissionState.granted, mapAuthStatus(3));
    try testing.expectEqual(types.PermissionState.denied, mapAuthStatus(99)); // an unknown value errs on the safe side (denied)
}

test "open: a width, height or frame_rate of 0 gives ConfigFailed without calling AVFoundation" {
    try testing.expectError(error.ConfigFailed, open(testing.allocator, .{ .width = 0, .height = 8, .frame_rate = 30 }));
    try testing.expectError(error.ConfigFailed, open(testing.allocator, .{ .width = 8, .height = 0, .frame_rate = 30 }));
    try testing.expectError(error.ConfigFailed, open(testing.allocator, .{ .width = 8, .height = 8, .frame_rate = 0 }));
}

test "open: exceeding the resolution bound gives ConfigFailed without calling AVFoundation" {
    try testing.expectError(error.ConfigFailed, open(testing.allocator, .{ .width = MAX_VIDEO_DIM + 1, .height = 8, .frame_rate = 30 }));
    try testing.expectError(error.ConfigFailed, open(testing.allocator, .{ .width = 8, .height = MAX_VIDEO_DIM + 1, .frame_rate = 30 }));
}

// ============================================================================
// Tests for manual verification only (SkipZigTest by default; a real camera is opened only when
// `VP_MANUAL_CAPTURE_TEST=1` is set on real hardware. They touch the TCC dialogue and a real device, so they are not in the automated tests)
// ============================================================================

fn sleepMs(ms: u64) void {
    var req = std.c.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = std.c.nanosleep(&req, null);
}

test "[MANUAL] open a real camera and confirm a few frames arrive (runs only with VP_MANUAL_CAPTURE_TEST=1)" {
    if (std.c.getenv("VP_MANUAL_CAPTURE_TEST") == null) return error.SkipZigTest;
    const allocator = testing.allocator;

    const perm = try requestPermission();
    std.debug.print("[manual] camera permission = {t}\n", .{perm});
    if (perm != .granted) return error.SkipZigTest;

    var dev = try open(allocator, .{ .width = 320, .height = 240, .frame_rate = 30 });
    defer dev.close();
    try dev.start();
    defer dev.stop();

    var got = false;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        sleepMs(50);
        if (dev.pollLatestFrame()) |f| {
            std.debug.print("[manual] got frame {d}x{d} frame_index={d}\n", .{ f.width, f.height, f.frame_index });
            got = true;
            break;
        }
    }
    try testing.expect(got);
}
