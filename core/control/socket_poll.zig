//! Socket readiness for the harness transport: "can this socket be read right now?".
//!
//! One primitive, every OS. The control plane needs the answer in two shapes — an immediate
//! answer (the free-run drain, which must never block a frame) and a bounded wait (the
//! manual clock, which runs the native event pump between waits) — and both are `readable`
//! with a different timeout. Keeping them one function is what keeps the free-run and
//! manual-clock duals from drifting apart per OS.
//!
//! POSIX gets `poll(2)`. Windows gets the ancillary function driver's poll control code,
//! issued here as a plain Zig call into ntdll: `std.posix.poll` is a compile error on Windows,
//! `std.Io` exposes no readiness operation, and `WSAPoll` cannot answer for these sockets at
//! all (see the note above the Windows section). Reaching the platform entry point directly is
//! how the rest of this repository talks to Win32 (no `@cImport`).
//!
//! Hot path declaration: `readable(fd, 0)` runs **once per frame** while a free-run transport
//! is listening — a single syscall on a single socket, no allocation and no lock, so the
//! all-pixel loop rules do not apply. Every other call is event time (waiting for a peer).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const net = std.Io.net;

/// wasm has no sockets: its transport is the host bridge, which never asks about readiness.
const is_wasm = builtin.target.cpu.arch.isWasm();

pub const Ready = enum {
    /// Readable now: data has arrived, a peer is waiting to be accepted, or the peer hung up
    /// (a hangup counts as readable so the caller drains what is left and sees the zero-length
    /// read that ends the request).
    ready,
    /// Nothing to read yet. The caller decides whether to give up or wait again.
    not_ready,
    /// The socket is unusable (an error or an invalid handle). Never a transient state.
    err,
};

/// Whether `handle` can be read without blocking, waiting up to `timeout_ms` for it.
///
/// `timeout_ms` is clamped to zero from below, so an infinite wait cannot be expressed: bounding
/// the wait is this function's contract, and running the native pump between waits belongs to
/// the caller. Both backends would otherwise read a negative timeout as "wait forever".
pub fn readable(handle: net.Socket.Handle, timeout_ms: i32) Ready {
    const timeout = normalizeTimeoutMs(timeout_ms);
    if (comptime is_wasm) return .not_ready;
    if (comptime builtin.os.tag == .windows) return readableWindows(handle, timeout);
    return readablePosix(handle, timeout);
}

/// The single clamp, applied before either backend is reached (a pure function, so the rule
/// itself is testable without a socket).
fn normalizeTimeoutMs(timeout_ms: i32) i32 {
    return if (timeout_ms < 0) 0 else timeout_ms;
}

fn readablePosix(handle: net.Socket.Handle, timeout_ms: i32) Ready {
    var pfds = [_]posix.pollfd{.{
        .fd = handle,
        .events = posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP,
        .revents = 0,
    }};
    const n = posix.poll(&pfds, timeout_ms) catch return .err;
    if (n == 0) return .not_ready;
    const revents = pfds[0].revents;
    if (revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) return .err;
    if (revents & (posix.POLL.IN | posix.POLL.HUP) != 0) return .ready;
    return .not_ready;
}

// Windows readiness goes through the ancillary function driver (AFD) rather than through
// `WSAPoll`. `std.Io` creates its sockets by opening an AFD endpoint directly
// (`\Device\Afd`, `NtCreateFile`), so `net.Socket.Handle` is a kernel file handle that the
// Winsock user-mode library knows nothing about: passing it to `WSAPoll` answers
// `WSAENOTSOCK`, not a readiness. The driver's own poll control code takes exactly the
// handles the rest of `std.Io` uses.
const windows = std.os.windows;

/// The event bits AFD reports back. Only the readable side is asked for; sending is never
/// what this module waits on.
const AFD_POLL_RECEIVE: windows.ULONG = 0x0001;
const AFD_POLL_DISCONNECT: windows.ULONG = 0x0008;
const AFD_POLL_ABORT: windows.ULONG = 0x0010;
const AFD_POLL_LOCAL_CLOSE: windows.ULONG = 0x0020;
const AFD_POLL_ACCEPT: windows.ULONG = 0x0080;
const AFD_POLL_CONNECT_FAIL: windows.ULONG = 0x0100;

/// A pending connection (`ACCEPT`) on a listener, arrived data (`RECEIVE`) on a stream, and a
/// peer hangup (`DISCONNECT`) all mean "the caller may proceed"; the rest mean the socket is
/// finished. Asking for every one of them in a single request is what lets one function serve
/// a listener and a connection alike.
const afd_poll_events: windows.ULONG =
    AFD_POLL_RECEIVE | AFD_POLL_DISCONNECT | AFD_POLL_ACCEPT |
    AFD_POLL_ABORT | AFD_POLL_LOCAL_CLOSE | AFD_POLL_CONNECT_FAIL;

const AFD_POLL_HANDLE_INFO = extern struct {
    Handle: windows.HANDLE,
    Events: windows.ULONG,
    Status: windows.NTSTATUS,
};

const AFD_POLL_INFO = extern struct {
    /// An NT relative timeout: negative counts 100ns ticks from now, and zero returns at once.
    Timeout: windows.LARGE_INTEGER,
    NumberOfHandles: windows.ULONG,
    Exclusive: windows.ULONG,
    Handles: [1]AFD_POLL_HANDLE_INFO,
};

/// What the completion event is used for: waiting on it, and letting the driver signal it
/// (the two low specific bits of an event object are query state and modify state).
const event_access: windows.ACCESS_MASK = .{
    .SPECIFIC = .{ .bits = 0x0003 },
    .STANDARD = .{ .SYNCHRONIZE = true },
};

/// The completion event for the poll request, created once and reused. A synchronization
/// event resets itself when a wait on it is satisfied, so consecutive calls need no cleanup.
/// Single threaded by contract, like the rest of the harness transport.
var afd_event: ?windows.HANDLE = null;

fn afdEvent() ?windows.HANDLE {
    if (afd_event) |h| return h;
    var h: windows.HANDLE = undefined;
    if (windows.ntdll.NtCreateEvent(&h, event_access, null, .Synchronization, .FALSE) != .SUCCESS) return null;
    afd_event = h;
    return h;
}

fn readableWindows(handle: net.Socket.Handle, timeout_ms: i32) Ready {
    const event = afdEvent() orelse return .err;
    var info = AFD_POLL_INFO{
        .Timeout = -@as(windows.LARGE_INTEGER, timeout_ms) * 10_000,
        .NumberOfHandles = 1,
        .Exclusive = 0,
        .Handles = .{.{ .Handle = handle, .Events = afd_poll_events, .Status = .SUCCESS }},
    };
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    switch (windows.ntdll.NtDeviceIoControlFile(
        handle,
        event,
        null,
        null,
        &iosb,
        windows.IOCTL.AFD.POLL,
        &info,
        @sizeOf(AFD_POLL_INFO),
        &info,
        @sizeOf(AFD_POLL_INFO),
    )) {
        .SUCCESS => {},
        // The driver took the request: the event is signalled once it finishes, which the
        // request's own timeout guarantees will happen.
        .PENDING => if (windows.ntdll.NtWaitForSingleObject(event, .FALSE, null) != .SUCCESS) return .err,
        else => return .err,
    }
    switch (iosb.u.Status) {
        .SUCCESS => {},
        // Running out of time is an answer, not a failure.
        .TIMEOUT => return .not_ready,
        else => return .err,
    }
    // No handle reported back means the request finished with nothing to say. The count is
    // also what the request was sent with, so the byte count the driver wrote is what decides
    // whether a handle slot came back filled in — treating a short answer as "nothing to
    // report" keeps an unexpected reply from being read as an event.
    if (iosb.Information < @sizeOf(AFD_POLL_INFO)) return .not_ready;
    if (info.NumberOfHandles == 0) return .not_ready;
    const events = info.Handles[0].Events;
    if (events & (AFD_POLL_ABORT | AFD_POLL_LOCAL_CLOSE | AFD_POLL_CONNECT_FAIL) != 0) return .err;
    if (events & (AFD_POLL_RECEIVE | AFD_POLL_DISCONNECT | AFD_POLL_ACCEPT) != 0) return .ready;
    return .not_ready;
}

const testing = std.testing;

test "a negative timeout is clamped to zero, and every other value passes through" {
    try testing.expectEqual(@as(i32, 0), normalizeTimeoutMs(-1));
    try testing.expectEqual(@as(i32, 0), normalizeTimeoutMs(std.math.minInt(i32)));
    try testing.expectEqual(@as(i32, 0), normalizeTimeoutMs(0));
    try testing.expectEqual(@as(i32, 5), normalizeTimeoutMs(5));
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), normalizeTimeoutMs(std.math.maxInt(i32)));
}

test "readable answers over a loopback connection: idle, pending peer, data, hangup" {
    if (comptime is_wasm) return error.SkipZigTest;

    // Single threaded on purpose: a loopback connect completes against the listen backlog
    // without a peer accepting it, so every step below is ordered by construction and the
    // test cannot go flaky under load.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    var server = addr.listen(io, .{ .reuse_address = true }) catch return error.SkipZigTest;
    defer server.deinit(io);

    // Nobody has connected yet.
    try testing.expectEqual(Ready.not_ready, readable(server.socket.handle, 0));

    const port = server.socket.address.getPort();
    const client_addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    const client = client_addr.connect(io, .{ .mode = .stream }) catch return error.SkipZigTest;
    defer client.close(io);

    // A peer is waiting: the listener is readable, and accepting it produces an idle connection.
    try testing.expectEqual(Ready.ready, readable(server.socket.handle, 1000));
    const conn = server.accept(io) catch return error.SkipZigTest;
    defer conn.close(io);
    try testing.expectEqual(Ready.not_ready, readable(conn.socket.handle, 0));

    // Data written by the peer makes it readable.
    var wbuf: [16]u8 = undefined;
    var writer = client.writer(io, &wbuf);
    try writer.interface.writeAll("hi");
    try writer.interface.flush();
    try testing.expectEqual(Ready.ready, readable(conn.socket.handle, 1000));

    var rbuf: [16]u8 = undefined;
    var bufs = [_][]u8{rbuf[0..]};
    try testing.expectEqual(@as(usize, 2), try io.vtable.netRead(io.userdata, conn.socket.handle, bufs[0..]));

    // A half-close counts as readable, and the read that follows reports end of stream.
    try client.shutdown(io, .send);
    try testing.expectEqual(Ready.ready, readable(conn.socket.handle, 1000));
    try testing.expectEqual(@as(usize, 0), try io.vtable.netRead(io.userdata, conn.socket.handle, bufs[0..]));
}
