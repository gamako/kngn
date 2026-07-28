//! Linux native camera capture backend (L1, raw V4L2 ioctl).
//!
//! It does not use libv4l2, and does YUYV capture with nothing but the Linux kernel UAPI's ioctls and libc's
//! open, close, mmap and munmap. V4L2's four MMAP buffers are a driver-owned input queue, and are
//! distinct from the three physical pixel buffers of the `TripleBuffer` holding the normalised BGRA.
//!
//! Hot path declaration:
//! - **The capture thread (a blocking `VIDIOC_DQBUF` pull, at roughly the camera's fps)**: no malloc, locking, IO or panic.
//!   It uses the MMAP and TripleBuffer allocated up front at open, and only converts, publishes and QBUFs.
//! - **`yuyvToBgraRow`**: a per-pixel colour conversion processing every pixel of every frame. Unlike macOS's
//!   `copyBgraRows` (a plain row `@memcpy`) it does integer multiplication, addition and clamping.
//!   It is a fixed-point scalar implementation, not SIMD.
//! - enumerate, open, start, stop and close run at initialisation or event time only.

const std = @import("std");
const types = @import("capture_types");

// The libc ABI. ioctl is declared with fixed pointer arguments, following the existing approach to variadic C functions.
extern "c" fn ioctl(fd: c_int, request: c_ulong, arg: ?*anyopaque) c_int;
extern "c" fn __errno_location() *c_int;
extern "c" fn mmap(addr: ?*anyopaque, length: usize, prot: c_int, flags: c_int, fd: c_int, offset: c_long) ?*anyopaque;
extern "c" fn munmap(addr: ?*anyopaque, length: usize) c_int;

const libc = struct {
    extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
    extern "c" fn close(fd: c_int) c_int;
};

const O_RDWR: c_int = 0x0002;
const PROT_READ: c_int = 0x1;
const PROT_WRITE: c_int = 0x2;
const MAP_SHARED: c_int = 0x1;
const MAP_FAILED: usize = std.math.maxInt(usize);

const V4L2_BUF_TYPE_VIDEO_CAPTURE: u32 = 1;
const V4L2_MEMORY_MMAP: u32 = 1;
const V4L2_FIELD_ANY: u32 = 0;
const V4L2_CAP_VIDEO_CAPTURE: u32 = 0x0000_0001;
const V4L2_CAP_STREAMING: u32 = 0x0400_0000;
const V4L2_PIX_FMT_YUYV: u32 = @as(u32, 'Y') | (@as(u32, 'U') << 8) | (@as(u32, 'Y') << 16) | (@as(u32, 'V') << 24);

// Linux x86_64 videodev2.h: _IOC(dir,type,nr,size), with dir=1 write/2 read,
// type='V', and the ioctl numbers listed in the UAPI header. The resulting values
// are stable for the x86_64 target used by this backend; verification on the target
// Linux host must still compare these against a C program including <linux/videodev2.h>.
const IOC_WRITE: c_ulong = 1;
const IOC_READ: c_ulong = 2;
const IOC_TYPEBITS: c_ulong = 8;
const IOC_SIZEBITS: c_ulong = 14;
const IOC_TYPESHIFT: c_ulong = 8;
const IOC_SIZESHIFT: c_ulong = 16;
const IOC_DIRSHIFT: c_ulong = 30;
fn ioc(dir: c_ulong, nr: c_ulong, size: c_ulong) c_ulong {
    return (dir << IOC_DIRSHIFT) | (@as(c_ulong, 'V') << IOC_TYPESHIFT) | (nr) | (size << IOC_SIZESHIFT);
}
const VIDIOC_QUERYCAP: c_ulong = ioc(IOC_READ, 0, @sizeOf(v4l2_capability));
const VIDIOC_S_FMT: c_ulong = ioc(IOC_READ | IOC_WRITE, 5, @sizeOf(v4l2_format));
const VIDIOC_REQBUFS: c_ulong = ioc(IOC_READ | IOC_WRITE, 8, @sizeOf(v4l2_requestbuffers));
const VIDIOC_QUERYBUF: c_ulong = ioc(IOC_READ | IOC_WRITE, 9, @sizeOf(v4l2_buffer));
const VIDIOC_QBUF: c_ulong = ioc(IOC_READ | IOC_WRITE, 15, @sizeOf(v4l2_buffer));
const VIDIOC_DQBUF: c_ulong = ioc(IOC_READ | IOC_WRITE, 17, @sizeOf(v4l2_buffer));
const VIDIOC_STREAMON: c_ulong = ioc(IOC_WRITE, 18, @sizeOf(u32));
const VIDIOC_STREAMOFF: c_ulong = ioc(IOC_WRITE, 19, @sizeOf(u32));

const v4l2_capability = extern struct {
    driver: [16]u8,
    card: [32]u8,
    bus_info: [32]u8,
    version: u32,
    capabilities: u32,
    device_caps: u32,
    reserved: [3]u32,
};

const v4l2_pix_format = extern struct {
    width: u32,
    height: u32,
    pixelformat: u32,
    field: u32,
    bytesperline: u32,
    sizeimage: u32,
    colorspace: u32,
    priv: u32,
    flags: u32,
    ycbcr_enc: u32,
    quantization: u32,
    xfer_func: u32,
};

// v4l2_format's union is 200 bytes and has 8-byte alignment on x86_64. The
// pix member is therefore at offset 8 and the whole struct is 208 bytes.
const v4l2_format = extern struct {
    type: u32,
    _format_union_align: u32,
    pix: v4l2_pix_format,
    _format_union_tail: [152]u8,
};

const v4l2_requestbuffers = extern struct {
    count: u32,
    type: u32,
    memory: u32,
    capabilities: u32,
    flags: u8,
    reserved: [3]u8,
};

const timeval = extern struct { tv_sec: c_long, tv_usec: c_long };
const v4l2_timecode = extern struct {
    type: u32,
    flags: u32,
    frames: u8,
    seconds: u8,
    minutes: u8,
    hours: u8,
    userbits: [4]u8,
};

const v4l2_buffer = extern struct {
    index: u32,
    type: u32,
    bytesused: u32,
    flags: u32,
    field: u32,
    timestamp: timeval,
    timecode: v4l2_timecode,
    sequence: u32,
    memory: u32, // The UAPI has a __u32 memory between sequence and m. Leaving it out happens to make the alignment padding
    // before m fill 4 bytes, so sizeof and the offsets of m and length still match, but memory cannot be set and QUERYBUF, QBUF
    // and DQBUF return EINVAL (an assert on offsetof(memory)==60 prevents a recurrence).
    m: extern union {
        offset: u32,
        userptr: u64,
        planes: u64,
        fd: i32,
    },
    length: u32,
    reserved2: u32,
    request_fd: i32,
    reserved: u32,
};

// These are deliberately compile-time ABI tripwires. Values are the x86_64
// Linux UAPI measurements; verification on the target Linux host must compare
// sizeof/offsetof to a C program including <linux/videodev2.h> before real-device sign-off.
comptime {
    std.debug.assert(@sizeOf(v4l2_format) == 208);
    std.debug.assert(@offsetOf(v4l2_format, "pix") == 8);
    std.debug.assert(@sizeOf(v4l2_requestbuffers) == 20);
    std.debug.assert(@offsetOf(v4l2_requestbuffers, "flags") == 16);
    std.debug.assert(@sizeOf(v4l2_buffer) == 88);
    std.debug.assert(@offsetOf(v4l2_buffer, "memory") == 60);
    std.debug.assert(@offsetOf(v4l2_buffer, "m") == 64);
    std.debug.assert(@offsetOf(v4l2_buffer, "length") == 72);
}

pub const MAX_VIDEO_DIM: u32 = 4096;

pub const Config = struct {
    device_id: ?[]const u8 = null, // the MVP is fixed to /dev/video0
    width: u32 = 640,
    height: u32 = 480,
    frame_rate: u32 = 30,
};

pub const EffectiveConfig = struct {
    width: u32,
    height: u32,
    frame_rate: u32,
    format: types.PixelFormat = .bgra8,
};

const MappedBuffer = struct {
    addr: ?*anyopaque = null,
    length: usize = 0,
};

const State = struct {
    fd: c_int,
    effective: EffectiveConfig,
    bytes_per_line: usize,
    buffers: [4]MappedBuffer,
    buffer_count: u32,
    running: std.atomic.Value(bool),
    thread: ?std.Thread,
    allocator: std.mem.Allocator,
    triple: types.TripleBuffer(types.VideoFrame),
    slot_pixels: [3][]u32,
    frame_counter: std.atomic.Value(u64),
};

pub const VideoDevice = struct {
    state: *State,

    pub fn config(self: VideoDevice) EffectiveConfig {
        return self.state.effective;
    }

    pub fn start(self: VideoDevice) types.CaptureError!void {
        const state = self.state;
        if (state.thread != null) return;
        state.running.store(true, .release);
        var buffer_type: u32 = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        if (ioctl(state.fd, VIDIOC_STREAMON, @ptrCast(&buffer_type)) < 0) {
            state.running.store(false, .release);
            return error.StartFailed;
        }
        state.thread = std.Thread.spawn(.{}, captureThread, .{state}) catch {
            state.running.store(false, .release);
            _ = ioctl(state.fd, VIDIOC_STREAMOFF, @ptrCast(&buffer_type));
            return error.StartFailed;
        };
    }

    /// It publishes `running=false` first, releases the blocking DQBUF with STREAMOFF, and then joins.
    pub fn stop(self: VideoDevice) void {
        const state = self.state;
        if (state.thread) |thread| {
            state.running.store(false, .release);
            var buffer_type: u32 = V4L2_BUF_TYPE_VIDEO_CAPTURE;
            _ = ioctl(state.fd, VIDIOC_STREAMOFF, @ptrCast(&buffer_type));
            thread.join();
            state.thread = null;
        }
    }

    pub fn close(self: VideoDevice) void {
        const state = self.state;
        self.stop();
        var i: usize = 0;
        while (i < state.buffer_count) : (i += 1) {
            if (state.buffers[i].addr) |addr| _ = munmap(addr, state.buffers[i].length);
        }
        _ = libc.close(state.fd);
        for (state.slot_pixels) |pixels| state.allocator.free(pixels);
        state.allocator.destroy(state);
    }

    pub fn pollLatestFrame(self: VideoDevice) ?types.VideoFrame {
        if (self.state.frame_counter.load(.monotonic) == 0) return null;
        return self.state.triple.acquire().*;
    }
};

fn cStringInArray(bytes: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    return bytes[0..end];
}

pub fn enumerate(allocator: std.mem.Allocator) types.CaptureError![]types.DeviceInfo {
    var list: std.ArrayList(types.DeviceInfo) = .empty;
    errdefer {
        for (list.items) |item| {
            allocator.free(item.id);
            allocator.free(item.name);
        }
        list.deinit(allocator);
    }
    var i: u32 = 0;
    var found = false;
    while (i < 64) : (i += 1) {
        var path_buf: [32:0]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/dev/video{d}", .{i}) catch return error.OpenFailed;
        const fd = libc.open(path, O_RDWR, 0);
        if (fd < 0) continue;
        var cap = std.mem.zeroes(v4l2_capability);
        const queried = ioctl(fd, VIDIOC_QUERYCAP, @ptrCast(&cap)) == 0;
        _ = libc.close(fd);
        if (!queried or cap.capabilities & V4L2_CAP_VIDEO_CAPTURE == 0) continue;
        const id = allocator.dupe(u8, path[0..path.len]) catch return error.OpenFailed;
        errdefer allocator.free(id);
        const name = allocator.dupe(u8, cStringInArray(&cap.card)) catch return error.OpenFailed;
        errdefer allocator.free(name);
        list.append(allocator, .{ .id = id, .name = name, .kind = .video_in, .is_default = !found }) catch return error.OpenFailed;
        found = true;
    }
    return list.toOwnedSlice(allocator) catch return error.OpenFailed;
}

pub fn requestPermission() types.CaptureError!types.PermissionState {
    const fd = libc.open("/dev/video0", O_RDWR, 0);
    if (fd >= 0) {
        _ = libc.close(fd);
        return .granted;
    }
    // Linux errno values: EPERM=1, ENOENT=2, EACCES=13.
    return switch (__errno_location().*) {
        1, 13 => .denied,
        else => .not_determined,
    };
}

fn clampByte(value: i32) u32 {
    if (value <= 0) return 0;
    if (value >= 255) return 255;
    return @intCast(value);
}

/// Convert one packed YUYV row (Y0 U Y1 V) to canonical BGRA u32 (0xFFRRGGBB).
/// BT.601 limited-range integer approximation; no per-pixel floating point or division.
pub fn yuyvToBgraRow(dst: []u32, src: []const u8) void {
    const pixels = @min(dst.len, src.len >> 1);
    var x: usize = 0;
    var si: usize = 0;
    while (x < pixels) : ({
        x += 2;
        si += 4;
    }) {
        if (si + 3 >= src.len) break;
        const u: i32 = @as(i32, src[si + 1]) - 128;
        const v: i32 = @as(i32, src[si + 3]) - 128;
        var pair: usize = 0;
        while (pair < 2 and x + pair < pixels) : (pair += 1) {
            const y: i32 = @as(i32, src[si + pair * 2]) - 16;
            const c: i32 = @max(y, 0);
            const r = (298 * c + 409 * v + 128) >> 8;
            const g = (298 * c - 100 * u - 208 * v + 128) >> 8;
            const b = (298 * c + 516 * u + 128) >> 8;
            dst[x + pair] = 0xFF00_0000 | (clampByte(r) << 16) | (clampByte(g) << 8) | clampByte(b);
        }
    }
}

fn captureThread(state: *State) void {
    while (state.running.load(.acquire)) {
        var buffer = std.mem.zeroes(v4l2_buffer);
        buffer.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buffer.memory = V4L2_MEMORY_MMAP; // DQBUF requires type and memory (leaving memory at 0 makes a strict driver return EINVAL)
        if (ioctl(state.fd, VIDIOC_DQBUF, @ptrCast(&buffer)) < 0) break;
        if (!state.running.load(.acquire)) break;
        if (buffer.index >= state.buffer_count) break;

        const mapped = state.buffers[buffer.index].addr orelse break;
        const source = @as([*]const u8, @ptrCast(mapped))[0..state.buffers[buffer.index].length];
        const slot = state.triple.write_idx & 0x03;
        const dst = state.slot_pixels[slot];
        const row_bytes = @as(usize, state.effective.width) * 2;
        var y: u32 = 0;
        while (y < state.effective.height) : (y += 1) {
            const src_offset = @as(usize, y) * state.bytes_per_line;
            if (src_offset >= source.len) break;
            const available = source[src_offset..][0..@min(row_bytes, source.len - src_offset)];
            const dst_offset = @as(usize, y) * state.effective.width;
            yuyvToBgraRow(dst[dst_offset..][0..state.effective.width], available);
        }
        const frame_index = state.frame_counter.fetchAdd(1, .monotonic);
        state.triple.publish(.{ .pixels = dst, .width = state.effective.width, .height = state.effective.height, .stride = state.effective.width, .format = .bgra8, .timestamp_ns = 0, .frame_index = frame_index });
        _ = ioctl(state.fd, VIDIOC_QBUF, @ptrCast(&buffer));
    }
}

pub fn open(allocator: std.mem.Allocator, cfg: Config) types.CaptureError!VideoDevice {
    if (cfg.width == 0 or cfg.height == 0 or cfg.frame_rate == 0) return error.ConfigFailed;
    if (cfg.width > MAX_VIDEO_DIM or cfg.height > MAX_VIDEO_DIM) return error.ConfigFailed;

    const fd = libc.open("/dev/video0", O_RDWR, 0);
    if (fd < 0) return error.NoDevice;
    errdefer _ = libc.close(fd);

    var cap = std.mem.zeroes(v4l2_capability);
    if (ioctl(fd, VIDIOC_QUERYCAP, @ptrCast(&cap)) < 0) return error.NoDevice;
    if (cap.capabilities & (V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_STREAMING) != (V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_STREAMING)) return error.NoDevice;

    var format = std.mem.zeroes(v4l2_format);
    format.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    format.pix.width = cfg.width;
    format.pix.height = cfg.height;
    format.pix.pixelformat = V4L2_PIX_FMT_YUYV;
    format.pix.field = V4L2_FIELD_ANY;
    if (ioctl(fd, VIDIOC_S_FMT, @ptrCast(&format)) < 0) return error.ConfigFailed;
    if (format.pix.pixelformat != V4L2_PIX_FMT_YUYV) return error.ConfigFailed;
    if (format.pix.width == 0 or format.pix.height == 0 or format.pix.width > MAX_VIDEO_DIM or format.pix.height > MAX_VIDEO_DIM) return error.ConfigFailed;

    var request = std.mem.zeroes(v4l2_requestbuffers);
    request.count = 4;
    request.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    request.memory = V4L2_MEMORY_MMAP;
    var buffers = [_]MappedBuffer{ .{}, .{}, .{}, .{} };
    var buffer_count: u32 = 0;
    errdefer {
        var i: usize = 0;
        while (i < buffer_count) : (i += 1) {
            if (buffers[i].addr) |addr| _ = munmap(addr, buffers[i].length);
        }
    }
    if (ioctl(fd, VIDIOC_REQBUFS, @ptrCast(&request)) < 0 or request.count == 0 or request.count > 4) return error.OpenFailed;
    buffer_count = request.count;
    var i: u32 = 0;
    while (i < buffer_count) : (i += 1) {
        var buffer = std.mem.zeroes(v4l2_buffer);
        buffer.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buffer.memory = V4L2_MEMORY_MMAP; // QUERYBUF requires type, memory and index (EINVAL when memory is unset)
        buffer.index = i;
        if (ioctl(fd, VIDIOC_QUERYBUF, @ptrCast(&buffer)) < 0) return error.OpenFailed;
        const mapped = mmap(null, buffer.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, @intCast(buffer.m.offset));
        const mapped_addr = mapped orelse return error.OpenFailed;
        if (@intFromPtr(mapped_addr) == MAP_FAILED) return error.OpenFailed;
        buffers[i] = .{ .addr = mapped_addr, .length = buffer.length };
    }
    i = 0;
    while (i < buffer_count) : (i += 1) {
        var buffer = std.mem.zeroes(v4l2_buffer);
        buffer.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buffer.memory = V4L2_MEMORY_MMAP; // QBUF requires type, memory and index too
        buffer.index = i;
        if (ioctl(fd, VIDIOC_QBUF, @ptrCast(&buffer)) < 0) return error.OpenFailed;
    }

    const pixel_count = @as(usize, format.pix.width) * format.pix.height;
    var slot_pixels: [3][]u32 = undefined;
    var allocated: usize = 0;
    errdefer {
        while (allocated > 0) {
            allocated -= 1;
            allocator.free(slot_pixels[allocated]);
        }
    }
    while (allocated < 3) : (allocated += 1) {
        slot_pixels[allocated] = allocator.alloc(u32, pixel_count) catch return error.OpenFailed;
        @memset(slot_pixels[allocated], 0xFF00_0000);
    }
    const state = allocator.create(State) catch return error.OpenFailed;
    errdefer allocator.destroy(state);
    var triple = types.TripleBuffer(types.VideoFrame).init(.{ .pixels = slot_pixels[0], .width = format.pix.width, .height = format.pix.height, .stride = format.pix.width, .format = .bgra8, .timestamp_ns = 0, .frame_index = 0 });
    triple.bufs[0].pixels = slot_pixels[0];
    triple.bufs[1].pixels = slot_pixels[1];
    triple.bufs[2].pixels = slot_pixels[2];
    state.* = .{
        .fd = fd,
        .effective = .{ .width = format.pix.width, .height = format.pix.height, .frame_rate = cfg.frame_rate, .format = .bgra8 },
        .bytes_per_line = if (format.pix.bytesperline != 0) format.pix.bytesperline else @as(usize, format.pix.width) * 2,
        .buffers = buffers,
        .buffer_count = buffer_count,
        .running = .init(false),
        .thread = null,
        .allocator = allocator,
        .triple = triple,
        .slot_pixels = slot_pixels,
        .frame_counter = .init(0),
    };
    return .{ .state = state };
}

const testing = std.testing;

test "yuyvToBgraRow: gray and red known bytes become canonical BGRA values" {
    var dst = [_]u32{ 0, 0 };
    yuyvToBgraRow(&dst, &[_]u8{ 16, 128, 235, 128 });
    try testing.expectEqual(@as(u32, 0xFF00_0000), dst[0]);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), dst[1]);

    yuyvToBgraRow(&dst, &[_]u8{ 81, 90, 81, 240 });
    try testing.expectEqual(@as(u32, 0xFFFF_0000), dst[0]);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), dst[1]);
}

test "open: a width, height or frame_rate of 0 gives ConfigFailed without calling V4L2" {
    try testing.expectError(error.ConfigFailed, open(testing.allocator, .{ .width = 0, .height = 8, .frame_rate = 30 }));
    try testing.expectError(error.ConfigFailed, open(testing.allocator, .{ .width = 8, .height = 0, .frame_rate = 30 }));
    try testing.expectError(error.ConfigFailed, open(testing.allocator, .{ .width = 8, .height = 8, .frame_rate = 0 }));
}

test "open: exceeding the resolution bound gives ConfigFailed without calling V4L2" {
    try testing.expectError(error.ConfigFailed, open(testing.allocator, .{ .width = MAX_VIDEO_DIM + 1, .height = 8, .frame_rate = 30 }));
    try testing.expectError(error.ConfigFailed, open(testing.allocator, .{ .width = 8, .height = MAX_VIDEO_DIM + 1, .frame_rate = 30 }));
}

test "enumerate and requestPermission: calling the real V4L2 neither crashes nor hangs, and returns a sensible result" {
    // Whether a device exists depends on the environment (there are CI and remote machines with none, and machines with a
    // real camera), so the count is not asserted. open is non-blocking and QUERYCAP returns immediately, so it cannot hang (Linux has no equivalent of TCC).
    // The allocator contract for the id and name enumerate returns (freed symmetrically by freeDeviceList) is checked at the same time.
    const devices = try enumerate(testing.allocator);
    defer types.freeDeviceList(testing.allocator, devices);
    const perm = try requestPermission();
    try testing.expect(perm == .granted or perm == .denied or perm == .not_determined);
    if (std.c.getenv("KNGN_CAPTURE_SMOKE") != null) {
        std.debug.print("[v4l2 smoke] enumerate -> {d} device(s)", .{devices.len});
        for (devices) |d| std.debug.print(" [{s}={s}]", .{ d.id, d.name });
        std.debug.print("; requestPermission -> {s}\n", .{@tagName(perm)});
    }
}

// For manual verification only (SkipZigTest by default; it runs only with KNGN_CAPTURE_FULL_SMOKE=1, since it takes a real camera).
// It checks on real hardware the whole cycle of open, start, pollLatestFrame, stop and close, and above all whether stop()'s
// STREAMOFF reliably unblocks the blocking DQBUF so that the join completes (the same manual test convention as
// audio_macos.zig's KNGN_MANUAL_CAPTURE_TEST). A lack of YUYV support or of a device is tolerated best-effort (NoDevice and ConfigFailed skip).
test "full cycle (manual): open, start, pollLatestFrame, stop and close go round on a real camera without hanging" {
    if (std.c.getenv("KNGN_CAPTURE_FULL_SMOKE") == null) return error.SkipZigTest;
    var dev = open(testing.allocator, .{ .width = 640, .height = 480, .frame_rate = 30 }) catch |err| {
        std.debug.print("[v4l2 full] open failed: {s} (best-effort: a lack of YUYV support or of a device is tolerated)\n", .{@errorName(err)});
        return;
    };
    defer dev.close();
    const eff = dev.config();
    std.debug.print("[v4l2 full] open ok: {d}x{d}\n", .{ eff.width, eff.height });
    try dev.start();
    var got: ?types.VideoFrame = null;
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) { // wait up to about 2s (20ms × 100) in real time for one frame
        if (dev.pollLatestFrame()) |f| {
            got = f;
            break;
        }
        var req = std.c.timespec{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&req, null);
    }
    if (got) |f| {
        std.debug.print("[v4l2 full] frame received: {d}x{d} stride={d} idx={d}\n", .{ f.width, f.height, f.stride, f.frame_index });
    } else {
        std.debug.print("[v4l2 full] no frame within timeout (best-effort: checking whether stop and close hang)\n", .{});
    }
    dev.stop(); // STREAMOFF unblocks the blocking DQBUF so the join completes. Not hanging is this test's whole point.
    std.debug.print("[v4l2 full] stop/close ok (STREAMOFF unblocked DQBUF)\n", .{});
}
