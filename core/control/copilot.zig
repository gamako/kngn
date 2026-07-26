//! The copilot/assist transport: a third control plane that coexists with the ordinary UX.
//!
//! Opting in through `VP_COPILOT_*` makes it listen on TCP loopback, so an agent can observe through a probe and
//! operate through an action. Unlike harness live (which is verification-only and stops the application at a step gate),
//! it **brings no step gate with it**: commands are handled non-blockingly by `pump()` on each frame, and a user's
//! ordinary operations mix with an agent's within one session. An operate passes through `CommandExecutor`
//! (command.zig) and is recorded in a CommandRecord with `actor=local_agent`.
//!
//! ## Hot path declaration
//! The copilot transport is **event time plus O(1) per frame**: `pump()` is called every frame from the facade's
//! `pollEvents`, but while idle it returns straight away after a single non-blocking poll (one syscall, no allocation,
//! nothing over every pixel or every sample). Handling a command (digest, snapshot, action, tx) happens only when a
//! command arrives. It never touches a real-time path, so the SIMD trio and the benchmarks do not apply. **With the
//! environment unset, pump is an early return on a single bool** (zero regression to existing behaviour).
//!
//! ## The direction of dependency (one-way)
//! copilot.zig → harness.zig (the registry accessors and capabilities) plus command.zig (the executor).
//! harness.zig's reference to copilot is a single namespace re-export line, and harness never calls a copilot
//! function.
//!
//! ## Mutual exclusion (one control transport per process)
//! If any `VP_HARNESS_*` variable exists (SCRIPT, LISTEN, VP_HEADLESS), `VP_COPILOT_*` is warned about and ignored
//! (the decision is based on the variable existing, is settled at `parseConfig()` and is deterministic; it does not depend on whether harness's listen succeeded).
//!
//! ## The connection model (a non-blocking state machine)
//! As with harness live, "one connection = one request (separated by `;` or a newline, settled by the client's half-close) = one response",
//! so `scripts/drive` works unchanged (the wire is compatible). The fd is nonblocking at the OS level. Every phase —
//! read, execute and send — progresses across frames and never blocks the main loop (see `ConnState` and `pump()` for the detail).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const harness = @import("harness.zig");
const command = @import("command.zig");

const net = std.Io.net;
const gpa = std.heap.page_allocator;

/// The wire limit on a request and on a response (64 KiB each). A request over the limit gets an error response,
/// and a response over the limit is truncated and gets an `error: response truncated` line.
pub const MAX_WIRE = 64 * 1024;
/// The budget of command executions per pump (per frame). Even when a great many commands are packed into 64 KiB,
/// no single frame is monopolised (the rest carries over to the next frame).
pub const CMD_BUDGET = 16;
/// The connection deadline (in frames, so about 30 seconds at 60fps). A slow client that does not finish read-to-send is
/// closed, so that it cannot occupy the single-connection model forever (no clock syscall is involved).
pub const DEADLINE_FRAMES = 1800;
/// The limit on read chunks per pump (even a client streaming in fast does not monopolise one frame).
const READ_CHUNKS_PER_PUMP = 16;
const TRUNCATED_LINE = "error: response truncated\n";

// ============================================================================
// module state (touched only while enabled; with the environment unset a normal run never uses any of it)
// ============================================================================

var config_parsed = false;
var transport_started = false;
/// The "try to listen" flag settled by parseConfig (mutual exclusion included).
var enabled_pending = false;
/// The enabled flag raised once the listen succeeds. What `pump()`'s early return tests.
var enabled = false;
var req_port: u16 = 0;
/// During a netsync session an operate (an action or transaction control) is rejected; an observe is still allowed.
var netsync_active = false;

var io_inited = false;
var threaded: std.Io.Threaded = undefined;
var io_val: std.Io = undefined;

var server: net.Server = undefined;

var conn_active = false;
var conn_fd: net.Socket.Handle = undefined;
var conn: ConnState = undefined;

/// Where an operate is recorded (the first consumer of command.zig). Fixed BSS capacity, touched only while enabled.
var command_log: command.CommandLog = undefined;
var executor: command.Executor = undefined;
/// The open transaction the wire's begin_tx, end_tx and cancel_tx manage (one at a time).
var open_tx: ?command.TransactionHandle = null;
/// The application-owned shared executor. When it is set, neither the own executor nor the own log is used:
/// - `action` **calls harness.findAction's run directly** (recording is centralised in the application's own wrapper;
///   going through the own executor would double-record against the application wrapper's executeAction, and with the
///   same executor it would be a ReentrantDispatch).
/// - `begin_tx`, `end_tx` and `cancel_tx` operate on the shared executor with actor=.local_agent
///   (the application wrapper joins automatically through `openTransactionFor(.local_agent)`).
/// While it is unset (null), the behaviour with an own executor and own log is preserved exactly.
var shared_executor: ?*command.Executor = null;

/// Sets the shared executor (delegated from the facade's `platform.setCommandExecutor`.
/// It may be called with harness and copilot disabled, per the no-op rule — it only assigns a module variable).
pub fn setSharedExecutor(exec: ?*command.Executor) void {
    shared_executor = exec;
}

/// Drops just the borrow of the shared executor before teardown (without dereferencing the old pointer).
pub fn forgetSharedExecutor() void {
    shared_executor = null;
}

/// The executor an operate (an action or transaction control) targets, preferring the shared executor.
fn targetExecutor() *command.Executor {
    return shared_executor orelse &executor;
}

/// Where the capabilities JSON is assembled (a reusable scratch buffer, the same shape as harness's capabilities_buf).
var caps_buf: [16 * 1024]u8 = undefined;

pub fn isEnabled() bool {
    return enabled;
}

/// The flag rejecting an operate during a netsync session (platform wires it up through `netsync.setSessionStateCallback`).
pub fn setNetsyncSessionActive(active: bool) void {
    netsync_active = active;
}

// ============================================================================
// lifecycle (called from platform.init and platform.shutdown)
// ============================================================================

/// The pure mutual-exclusion decision, separated from the environment IO for unit testing: if even one of harness's
/// variables exists, copilot is disabled (one control transport per process).
fn decideEnabled(requested: bool, harness_env_present: bool) bool {
    return requested and !harness_env_present;
}

/// platform.init() calls this exactly once, after `harness.parseConfig()`. It only reads the environment and causes
/// no IO side effect (no listen, no allocation, no thread).
pub fn parseConfig() void {
    if (config_parsed) return;
    config_parsed = true;

    const requested = getEnv("VP_COPILOT") != null or getEnv("VP_COPILOT_PORT") != null;
    if (!requested) return;

    const harness_env_present = getEnv("VP_HARNESS_SCRIPT") != null or
        getEnv("VP_HARNESS_LISTEN") != null or
        getEnv("VP_HEADLESS") != null;
    if (!decideEnabled(requested, harness_env_present)) {
        std.debug.print("[copilot] VP_HARNESS_* is active, so VP_COPILOT_* is ignored (one control transport per process)\n", .{});
        return;
    }
    if (comptime builtin.os.tag == .windows) {
        std.debug.print("[copilot] the copilot transport is unsupported on Windows; ignoring VP_COPILOT_*\n", .{});
        return;
    }
    if (getEnv("VP_COPILOT_PORT")) |pe| req_port = std.fmt.parseInt(u16, pe, 10) catch 0;
    enabled_pending = true;
}

/// platform.init() calls this exactly once, after `harness.startTransport()`. Only a successful listen settles
/// enabled and opens the registry's OR gate. A failed listen warns and leaves it disabled (start-up continues).
pub fn startTransport() void {
    if (comptime builtin.os.tag != .windows) startTransportPosix();
}

fn startTransportPosix() void {
    if (transport_started) return;
    transport_started = true;
    if (!enabled_pending) return;

    ensureIo();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(req_port) };
    server = addr.listen(io_val, .{ .reuse_address = true }) catch |err| {
        std.debug.print("[copilot] listen failed: {s} (start-up continues with copilot disabled)\n", .{@errorName(err)});
        return;
    };
    if (!setNonblocking(server.socket.handle)) {
        std.debug.print("[copilot] failed to make the listener nonblocking; disabling copilot\n", .{});
        server.deinit(io_val);
        return;
    }
    initExecutorState();
    harness.setExternalRegistryEnabled(true);
    enabled = true;
    const chosen = server.socket.address.getPort();
    std.debug.print("[copilot] enabled: 127.0.0.1:{d}\n", .{chosen});
    writePortFile(chosen);
}

/// Called by platform.shutdown(). It closes the connected stream (discarding a response mid-send), then the listener,
/// then sets enabled=false.
pub fn stopTransport() void {
    if (comptime builtin.os.tag != .windows) stopTransportPosix();
}

fn stopTransportPosix() void {
    if (!enabled) return;
    if (conn_active) {
        closeConn();
    }
    server.deinit(io_val);
    enabled = false;
}

fn ensureIo() void {
    if (io_inited) return;
    io_inited = true;
    threaded = std.Io.Threaded.init(gpa, .{});
    io_val = threaded.io();
}

fn initExecutorState() void {
    command_log = .{};
    executor = command.Executor.init(.{ .ctx = undefined, .run = dispatchHarnessAction });
    executor.log = &command_log;
    open_tx = null;
}

/// The executor's Dispatcher: a name lookup in the harness action registry, then delegation to run()
/// (the framework interprets neither the args nor the return value).
/// As in `action_registry.dispatch`, the structured error is cleared before every run.
fn dispatchHarnessAction(ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = ctx;
    harness.action_registry.clearActionErrorDetail();
    const act = harness.findAction(name) orelse return error.UnknownAction;
    return act.run(act.ctx, args, buf);
}

fn writePortFile(port: u16) void {
    const path = getEnv("VP_COPILOT_PORT_FILE") orelse return; // with it omitted, only the stderr message
    var pbuf: [16]u8 = undefined;
    const txt = std.fmt.bufPrint(&pbuf, "{d}\n", .{port}) catch return;
    std.Io.Dir.cwd().writeFile(io_val, .{ .sub_path = path, .data = txt }) catch |err| {
        std.debug.print("[copilot] failed to write the port file {s}: {s}\n", .{ path, @errorName(err) });
    };
}

/// Reads an environment variable (libc getenv, as harness does; the platform module is always `link_libc`).
fn getEnv(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

// ============================================================================
// pump (every frame; called from the end of the facade's Window.pollEvents)
// ============================================================================

/// Called once per frame. While disabled it is an early return on a single bool (zero regression).
/// The work limit for one pump: one accept, 16 read chunks, 16 commands, and as much send as fits.
pub fn pump() void {
    if (!enabled) return;
    if (comptime builtin.os.tag != .windows) pumpPosix();
}

fn pumpPosix() void {
    if (!conn_active) {
        if (!fdReadable(server.socket.handle)) return;
        const fd = tryAccept() orelse return;
        if (!setNonblocking(fd)) {
            std.debug.print("[copilot] failed to make the accepted fd nonblocking; discarding the connection\n", .{});
            io_val.vtable.netClose(io_val.userdata, (&fd)[0..1]);
            return;
        }
        conn_fd = fd;
        conn.reset();
        conn_active = true;
    }

    if (!conn.tickFrame()) {
        std.debug.print("[copilot] connection deadline exceeded ({d} frames); closing\n", .{DEADLINE_FRAMES});
        closeConn();
        return;
    }

    if (conn.phase == .reading) pumpRead();
    if (conn_active and conn.phase == .executing) conn.executeBudget();
    if (conn_active and conn.phase == .sending) pumpSend();
}

fn closeConn() void {
    io_val.vtable.netClose(io_val.userdata, (&conn_fd)[0..1]);
    conn_active = false;
}

/// Tests whether the listener or the connection fd is readable (a single non-blocking poll with timeout=0).
fn fdReadable(fd: net.Socket.Handle) bool {
    var pfds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP, .revents = 0 }};
    const n = posix.poll(&pfds, 0) catch return false;
    if (n == 0) return false;
    // POLLHUP is used to read the data left after a half-close (settled by exhausting read until read==0).
    return pfds[0].revents & (posix.POLL.IN | posix.POLL.HUP) != 0;
}

/// A non-blocking accept (EAGAIN and EINTR mean "no progress this frame" = null. EINTR is not retried within the
/// same pump either but carries over to the next frame, so a burst of signals cannot monopolise a frame.
/// The listener is nonblocking, so losing the connection between the poll and the accept does not block).
fn tryAccept() ?net.Socket.Handle {
    const rc = std.c.accept(server.socket.handle, null, null);
    switch (posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .INTR, .AGAIN => return null,
        else => |e| {
            std.debug.print("[copilot] accept failed: {s}\n", .{@tagName(e)});
            return null;
        },
    }
}

/// Makes an fd nonblocking at the OS level. A failure (F_GETFL or F_SETFL) gives false, on which the caller
/// disables the transport for a listener, or discards the connection for an accepted fd. Carrying on with a
/// blocking fd would leave everything resting on the poll(0) decision alone and break the non-blocking contract, so it is not swallowed.
fn setNonblocking(fd: net.Socket.Handle) bool {
    const fl = std.c.fcntl(fd, posix.F.GETFL, @as(c_int, 0));
    if (fl < 0) return false;
    const nonblock: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    return std.c.fcntl(fd, posix.F.SETFL, fl | nonblock) >= 0;
}

/// Reads whatever is available (a nonblocking read; EAGAIN and EINTR mean no progress this frame and carry over to the
/// next, and read==0 settles the half-close). Raw `std.c.read` is used because `posix.read` retries EINTR internally
/// without limit (matching the contract of never looping without limit within one pump).
///
/// Upholding the priority of HUP: `fdReadable` returns true for either POLLIN or POLLHUP, and the decision to close
/// rests on **the result of the read in this function alone** (read==0 together with `finishRead()==false`, meaning no
/// data, or a read error). No branch inspects the POLLHUP bit and closes directly, so when unread data and a HUP arrive
/// together right after a half-close, the read is exhausted first and the request runs normally.
fn pumpRead() void {
    var chunks: usize = 0;
    var rbuf: [4096]u8 = undefined;
    while (chunks < READ_CHUNKS_PER_PUMP) : (chunks += 1) {
        const rc = std.c.read(conn_fd, &rbuf, rbuf.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) {
                    // a half-close settles the request. A HUP with no data closes with no response.
                    if (!conn.finishRead()) closeConn();
                    return;
                }
                conn.feed(rbuf[0..n]);
            },
            .INTR, .AGAIN => return, // carried over to the next frame
            else => {
                closeConn(); // a read error closes the connection and resets the state
                return;
            },
        }
    }
}

/// Sends whatever fits (a nonblocking send, so a client that does not read cannot stall the main thread.
/// EAGAIN and EINTR both mean "no progress this frame" = carried over to the next frame).
fn pumpSend() void {
    while (conn.sent < conn.resp_len) {
        const rc = std.c.send(conn_fd, conn.resp[conn.sent..].ptr, conn.resp_len - conn.sent, posix.MSG.NOSIGNAL);
        switch (posix.errno(rc)) {
            .SUCCESS => conn.sent += @intCast(rc),
            .INTR, .AGAIN => return, // carried over to the next frame
            else => {
                closeConn(); // a HUP or an error mid-send closes
                return;
            },
        }
    }
    closeConn(); // once it is all sent, close (one connection = one response)
}

// ============================================================================
// ConnState (a byte-sequence state machine, separated from the fd so it is unit testable without a socket)
// ============================================================================

pub const Phase = enum { reading, executing, sending };

/// The request and response state for one connection. It advances the three phases across frames: read (feed and
/// finishRead), execute (executeBudget), then send (the transport side sends resp[sent..resp_len]).
pub const ConnState = struct {
    phase: Phase = .reading,
    req: [MAX_WIRE]u8 = undefined,
    req_len: usize = 0,
    req_overflow: bool = false,
    /// The command execution cursor (where a carried-over budget resumes).
    cursor: usize = 0,
    resp: [MAX_WIRE]u8 = undefined,
    resp_len: usize = 0,
    resp_truncated: bool = false,
    /// How many bytes have been sent (the transport side advances it).
    sent: usize = 0,
    frames_alive: u32 = 0,

    /// Initialises the scalars only and leaves the fixed-length arrays alone (avoiding a 128 KiB memset per connection).
    pub fn reset(self: *ConnState) void {
        self.phase = .reading;
        self.req_len = 0;
        self.req_overflow = false;
        self.cursor = 0;
        self.resp_len = 0;
        self.resp_truncated = false;
        self.sent = 0;
        self.frames_alive = 0;
    }

    /// Accumulates received bytes (up to MAX_WIRE; over the limit sets the overflow flag and discards later reads).
    pub fn feed(self: *ConnState, bytes: []const u8) void {
        if (self.phase != .reading or self.req_overflow) return;
        if (self.req_len + bytes.len > MAX_WIRE) {
            self.req_overflow = true;
            return;
        }
        @memcpy(self.req[self.req_len..][0..bytes.len], bytes);
        self.req_len += bytes.len;
    }

    /// A half-close (read==0) settles the request. A false return means a HUP with no data (it is fine to close with no response).
    /// Over the limit nothing runs and only an error response is produced (going straight to the send phase).
    pub fn finishRead(self: *ConnState) bool {
        if (self.phase != .reading) return true;
        if (self.req_overflow) {
            self.appendResp("error: request too large\n");
            self.beginSend();
            return true;
        }
        if (self.req_len == 0) return false;
        self.phase = .executing;
        return true;
    }

    /// The connection's frame counter. Past the deadline it is false (and the caller closes).
    pub fn tickFrame(self: *ConnState) bool {
        self.frames_alive += 1;
        return self.frames_alive <= DEADLINE_FRAMES;
    }

    /// Runs at most CMD_BUDGET commands per pump. Once they are all consumed, on to the send phase.
    pub fn executeBudget(self: *ConnState) void {
        if (self.phase != .executing) return;
        var executed: usize = 0;
        while (executed < CMD_BUDGET) {
            const raw = self.nextLine() orelse {
                self.beginSend();
                return;
            };
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            executeCommand(self, line);
            executed += 1;
        }
        // the budget is spent; the rest carries over to the next frame (the phase stays .executing)
    }

    /// Returns the next command fragment (separated by a newline or `;`, as in harness's command language), or null once exhausted.
    fn nextLine(self: *ConnState) ?[]const u8 {
        if (self.cursor >= self.req_len) return null;
        const start = self.cursor;
        var end = start;
        while (end < self.req_len and self.req[end] != '\n' and self.req[end] != ';') end += 1;
        self.cursor = end + 1;
        return self.req[start..end];
    }

    /// Appends to the response (up to MAX_WIRE minus the reservation for the truncated line; the excess is cut and the flag set).
    fn appendResp(self: *ConnState, s: []const u8) void {
        if (self.resp_truncated) return;
        const limit = MAX_WIRE - TRUNCATED_LINE.len;
        if (self.resp_len + s.len > limit) {
            self.resp_truncated = true;
            return;
        }
        @memcpy(self.resp[self.resp_len..][0..s.len], s);
        self.resp_len += s.len;
    }

    fn beginSend(self: *ConnState) void {
        if (self.resp_truncated) {
            // appendResp always reserves TRUNCATED_LINE.len, so this always fits
            @memcpy(self.resp[self.resp_len..][0..TRUNCATED_LINE.len], TRUNCATED_LINE);
            self.resp_len += TRUNCATED_LINE.len;
        }
        self.phase = .sending;
    }
};

// ============================================================================
// The command language (a subset of harness's, plus transaction control)
//   observe: digest <probe> / snapshot <probe> <path>   … a failure is an `error: <reason>` line
//   operate: action <name> [args...] / begin_tx [label] / end_tx / cancel_tx
//            … success `<name> <msg>` / `ok tx=<id>` / `ok`; failure a `fail <name> <reason>` line
// ============================================================================

fn executeCommand(conn_state: *ConnState, line: []const u8) void {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const cmd = it.next() orelse return;
    if (std.mem.eql(u8, cmd, "digest")) {
        handleDigestCmd(conn_state, &it);
    } else if (std.mem.eql(u8, cmd, "snapshot")) {
        handleSnapshotCmd(conn_state, &it);
    } else if (std.mem.eql(u8, cmd, "action")) {
        handleActionCmd(conn_state, &it);
    } else if (std.mem.eql(u8, cmd, "begin_tx")) {
        handleBeginTx(conn_state, &it);
    } else if (std.mem.eql(u8, cmd, "end_tx")) {
        handleEndTx(conn_state);
    } else if (std.mem.eql(u8, cmd, "cancel_tx")) {
        handleCancelTx(conn_state);
    } else if (std.mem.eql(u8, cmd, "quit")) {
        // the application's lifetime is owned by the user (the dividing line against harness, which is for verification)
        failResp(conn_state, "quit", "unsupported (app lifetime is owned by the user)");
    } else {
        failResp(conn_state, cmd, "unknown command");
    }
}

/// The built-in probes copilot does not expose (so that per-frame memcpy for framebuffer capture and the like is not
/// added to the ordinary UX. Custom probes plus capabilities are enough to observe with, and this can be widened additively).
fn isCopilotUnavailableBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "fb") or std.mem.eql(u8, name, "audio") or std.mem.eql(u8, name, "stats") or
        std.mem.eql(u8, name, "capture") or std.mem.eql(u8, name, "gamepad");
}

fn errorResp(conn_state: *ConnState, reason: []const u8) void {
    conn_state.appendResp("error: ");
    conn_state.appendResp(reason);
    conn_state.appendResp("\n");
}

fn failResp(conn_state: *ConnState, name: []const u8, reason: []const u8) void {
    failRespEx(conn_state, name, reason, false);
}

/// For an action run failure only: when the application has called `setActionErrorDetail`, ` code=<c> next=<n>` is appended.
/// (With none set this is identical to `failResp`, bit-for-bit as before. The leading `fail ` never changes.)
fn failActionResp(conn_state: *ConnState, name: []const u8, reason: []const u8) void {
    failRespEx(conn_state, name, reason, true);
}

fn failRespEx(conn_state: *ConnState, name: []const u8, reason: []const u8, with_detail: bool) void {
    conn_state.appendResp("fail ");
    conn_state.appendResp(name);
    conn_state.appendResp(" ");
    conn_state.appendResp(firstLine(reason));
    if (with_detail) {
        if (harness.action_registry.actionErrorDetail()) |d| {
            conn_state.appendResp(" code=");
            conn_state.appendResp(d.code);
            conn_state.appendResp(" next=");
            conn_state.appendResp(d.next);
        }
    }
    conn_state.appendResp("\n");
}

/// Cuts `msg` at the first CR or LF (protecting the wire framing, the same defence as harness's reportAction).
fn firstLine(msg: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, msg, '\n');
    const cr = std.mem.indexOfScalar(u8, msg, '\r');
    const cut = @min(nl orelse msg.len, cr orelse msg.len);
    return msg[0..cut];
}

/// digest: custom probes plus `capabilities` only (the built-in fb, audio, stats, capture and gamepad are out of scope).
fn handleDigestCmd(conn_state: *ConnState, it: *std.mem.TokenIterator(u8, .any)) void {
    const probe = it.next() orelse return errorResp(conn_state, "digest: missing probe name");
    if (std.mem.eql(u8, probe, "capabilities")) {
        const payload = harness.capabilitiesPayload(&caps_buf);
        conn_state.appendResp("capabilities ");
        conn_state.appendResp(payload);
        conn_state.appendResp("\n");
        return;
    }
    if (isCopilotUnavailableBuiltin(probe)) return errorResp(conn_state, "probe not available via copilot (custom probes + capabilities only)");
    const p = harness.findProbe(probe) orelse return errorResp(conn_state, "unknown probe");
    const dg = p.digest orelse return errorResp(conn_state, "digest unsupported");
    var buf: [harness.DIGEST_BUF_LEN]u8 = undefined;
    const payload = dg(p.ctx, &buf);
    conn_state.appendResp(probe);
    conn_state.appendResp(" ");
    conn_state.appendResp(firstLine(payload));
    conn_state.appendResp("\n");
}

/// snapshot: writes a custom probe's raw bytes to an explicit path (required) and returns the path.
fn handleSnapshotCmd(conn_state: *ConnState, it: *std.mem.TokenIterator(u8, .any)) void {
    const probe = it.next() orelse return errorResp(conn_state, "snapshot: missing probe name");
    const path = it.next() orelse return errorResp(conn_state, "snapshot: path required");
    if (std.mem.eql(u8, probe, "capabilities") or isCopilotUnavailableBuiltin(probe)) {
        return errorResp(conn_state, "snapshot not available via copilot (custom probes only)");
    }
    const p = harness.findProbe(probe) orelse return errorResp(conn_state, "unknown probe");
    const snap = p.snapshot orelse return errorResp(conn_state, "snapshot unsupported");
    ensureIo();
    const bytes = snap(p.ctx, gpa) catch |err| {
        std.debug.print("[copilot] snapshot {s} failed: {s}\n", .{ probe, @errorName(err) });
        return errorResp(conn_state, "snapshot failed");
    };
    defer gpa.free(bytes);
    std.Io.Dir.cwd().writeFile(io_val, .{ .sub_path = path, .data = bytes }) catch |err| {
        std.debug.print("[copilot] snapshot {s} failed to write {s}: {s}\n", .{ probe, path, @errorName(err) });
        return errorResp(conn_state, "snapshot write failed");
    };
    conn_state.appendResp(path);
    conn_state.appendResp("\n");
}

/// action: runs it through the executor and records it with `actor=local_agent` (tagging it if a transaction is open).
fn handleActionCmd(conn_state: *ConnState, it: *std.mem.TokenIterator(u8, .any)) void {
    const name = it.next() orelse return failResp(conn_state, "?", "missing action name");
    if (netsync_active) return failResp(conn_state, name, "netsync session active (operate disabled)");
    const args = std.mem.trim(u8, it.rest(), " \t");
    var buf: [harness.DIGEST_BUF_LEN]u8 = undefined;
    if (shared_executor != null) {
        // With a shared executor set: call the registry's run directly (the application wrapper centralises recording
        // through the executor, so passing through the own executor here would double-record or be a ReentrantDispatch).
        const act = harness.findAction(name) orelse return failResp(conn_state, name, "unknown action");
        // a direct run does not pass through action_registry.dispatch, so clear the structured error by hand
        harness.action_registry.clearActionErrorDetail();
        const result = act.run(act.ctx, args, &buf) catch |err| {
            return failActionResp(conn_state, name, @errorName(err));
        };
        conn_state.appendResp(name);
        conn_state.appendResp(" ");
        conn_state.appendResp(firstLine(result));
        conn_state.appendResp("\n");
        return;
    }
    const result = executor.executeAction(name, args, .{
        .actor = .local_agent,
        .transaction = open_tx,
        .record_policy = .record,
    }, &buf) catch |err| {
        if (err == error.UnknownAction) return failResp(conn_state, name, "unknown action");
        return failActionResp(conn_state, name, @errorName(err));
    };
    conn_state.appendResp(name);
    conn_state.appendResp(" ");
    conn_state.appendResp(firstLine(result.output));
    conn_state.appendResp("\n");
}

fn handleBeginTx(conn_state: *ConnState, it: *std.mem.TokenIterator(u8, .any)) void {
    if (netsync_active) return failResp(conn_state, "begin_tx", "netsync session active (operate disabled)");
    if (open_tx != null) return failResp(conn_state, "begin_tx", "transaction already open");
    const label = std.mem.trim(u8, it.rest(), " \t");
    const exec = targetExecutor();
    const handle = exec.beginTransaction(.local_agent, label) catch |err| {
        return failResp(conn_state, "begin_tx", @errorName(err));
    };
    open_tx = handle;
    var buf: [32]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "ok tx={d}\n", .{exec.tx_table[handle.index].id}) catch "ok\n";
    conn_state.appendResp(line);
}

fn handleEndTx(conn_state: *ConnState) void {
    if (netsync_active) return failResp(conn_state, "end_tx", "netsync session active (operate disabled)");
    const handle = open_tx orelse return failResp(conn_state, "end_tx", "no open transaction");
    open_tx = null;
    targetExecutor().endTransaction(handle, .local_agent) catch |err| {
        return failResp(conn_state, "end_tx", @errorName(err));
    };
    conn_state.appendResp("ok\n");
}

fn handleCancelTx(conn_state: *ConnState) void {
    if (netsync_active) return failResp(conn_state, "cancel_tx", "netsync session active (operate disabled)");
    const handle = open_tx orelse return failResp(conn_state, "cancel_tx", "no open transaction");
    open_tx = null;
    targetExecutor().cancelTransaction(handle, .local_agent) catch |err| {
        return failResp(conn_state, "cancel_tx", @errorName(err));
    };
    conn_state.appendResp("ok\n");
}

// ============================================================================
// tests (mostly calling directly, without a socket. A real socket and non-interference with a concurrent UX are checked by the E2E)
// The names are prefixed "copilot:" (build.zig's test-copilot step selects them by filter).
// ============================================================================

const testing = std.testing;

/// A test reset of copilot's module state (it does not start the transport).
fn resetCopilotForTest() void {
    ensureIo();
    initExecutorState();
    netsync_active = false;
    enabled = false;
    shared_executor = null;
    harness.setExternalRegistryEnabled(false);
    // false does not reach action_registry, so disabling requires resetForTest.
    harness.action_registry.resetForTest();
}

/// A test convenience: feed one request's bytes through a ConnState, run every command, and return the response slice.
fn handleRequest(cs: *ConnState, bytes: []const u8) []const u8 {
    cs.reset();
    cs.feed(bytes);
    if (!cs.finishRead()) return cs.resp[0..0];
    while (cs.phase == .executing) cs.executeBudget();
    return cs.resp[0..cs.resp_len];
}

const TestActionCtx = struct { calls: u32 = 0 };

fn testActionPing(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const c: *TestActionCtx = @ptrCast(@alignCast(ctx));
    c.calls += 1;
    return std.fmt.bufPrint(buf, "pong {s}", .{args}) catch "pong";
}

fn testActionBoomDetail(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = ctx;
    _ = buf;
    if (std.mem.eql(u8, args, "set")) {
        harness.setActionErrorDetail("file_not_found", "check path or use save first");
    }
    return error.Boom;
}

const TestProbeCtx = struct { value: u32 = 7 };

fn testProbeDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const c: *TestProbeCtx = @ptrCast(@alignCast(ctx));
    return std.fmt.bufPrint(buf, "value={d}", .{c.value}) catch "value=?";
}

fn testProbeSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    _ = ctx;
    return allocator.dupe(u8, "SNAPBYTES");
}

test "copilot: 1 with the environment unset it is a no-op (isEnabled=false, pump a no-op, register a no-op as before)" {
    resetCopilotForTest();
    try testing.expect(!isEnabled());
    pump(); // disabled → return at once (and do not crash)
    // harness disabled plus the external gate off → registerAction is a no-op
    try testing.expect(!harness.isEnabled());
    var c = TestActionCtx{};
    harness.registerAction(.{ .name = "copilot_noreg", .ctx = &c, .run = testActionPing });
    try testing.expect(harness.findAction("copilot_noreg") == null);
}

test "copilot: 2 the OR gate, so setExternalRegistryEnabled lets registerProbe and registerAction reach the registry" {
    resetCopilotForTest();
    try testing.expect(!harness.isEnabled()); // the premise: harness stays disabled
    harness.setExternalRegistryEnabled(true);
    defer {
        harness.setExternalRegistryEnabled(false);
        harness.action_registry.resetForTest();
    }
    var ac = TestActionCtx{};
    var pc = TestProbeCtx{};
    harness.registerAction(.{ .name = "copilot_gate_a", .ctx = &ac, .run = testActionPing });
    harness.registerProbe(.{ .name = "copilot_gate_p", .ctx = &pc, .digest = testProbeDigest });
    try testing.expect(harness.findAction("copilot_gate_a") != null);
    try testing.expect(harness.findProbe("copilot_gate_p") != null);
}

test "copilot: 3 the action response format, plus a CommandLog record with actor=local_agent and kind=normal" {
    resetCopilotForTest();
    harness.setExternalRegistryEnabled(true);
    defer {
        harness.setExternalRegistryEnabled(false);
        harness.action_registry.resetForTest();
    }
    var ac = TestActionCtx{};
    harness.registerAction(.{ .name = "ping", .ctx = &ac, .run = testActionPing });

    var cs: ConnState = undefined;
    const resp = handleRequest(&cs, "action ping hello");
    try testing.expectEqualStrings("ping pong hello\n", resp);
    try testing.expectEqual(@as(u32, 1), ac.calls);

    try testing.expectEqual(@as(u32, 1), command_log.filled);
    const rec = command_log.findBySeq(1).?;
    try testing.expect(rec.actor.eql(.local_agent));
    try testing.expectEqual(command.CommandKind.normal, rec.kind);
    try testing.expectEqualStrings("ping", rec.name());
    try testing.expectEqualStrings("hello", rec.args());
    try testing.expect(!rec.undoable); // there is no caller of noteUndo yet
}

test "copilot: 3b failActionResp carries the structured error (code= and next=), is bit-identical when unset, and keeps the leading fail" {
    resetCopilotForTest();
    harness.setExternalRegistryEnabled(true);
    defer {
        harness.setExternalRegistryEnabled(false);
        harness.action_registry.resetForTest();
    }
    var ac = TestActionCtx{};
    harness.registerAction(.{ .name = "boom", .ctx = &ac, .run = testActionBoomDetail });

    var cs: ConnState = undefined;
    const resp1 = handleRequest(&cs, "action boom set");
    try testing.expect(std.mem.startsWith(u8, resp1, "fail boom "));
    try testing.expectEqualStrings("fail boom Boom code=file_not_found next=check path or use save first\n", resp1);

    // the equivalent of dispatch's clear: the next failure, with no detail set, is bit-identical to the old format
    const resp2 = handleRequest(&cs, "action boom noset");
    try testing.expectEqualStrings("fail boom Boom\n", resp2);

    // a non-action failure (begin_tx and friends) attaches no detail
    const resp3 = handleRequest(&cs, "end_tx");
    try testing.expectEqualStrings("fail end_tx no open transaction\n", resp3);
}

test "copilot: 4 begin_tx then action then end_tx attaches a transaction_id, while a doubled begin or an inconsistent handle fails" {
    resetCopilotForTest();
    harness.setExternalRegistryEnabled(true);
    defer {
        harness.setExternalRegistryEnabled(false);
        harness.action_registry.resetForTest();
    }
    var ac = TestActionCtx{};
    harness.registerAction(.{ .name = "ping", .ctx = &ac, .run = testActionPing });

    var cs: ConnState = undefined;
    const resp = handleRequest(&cs, "begin_tx macro; action ping x; end_tx");
    try testing.expectEqualStrings("ok tx=1\nping pong x\nok\n", resp);
    const rec = command_log.findBySeq(1).?;
    try testing.expectEqual(@as(?u64, 1), rec.transaction_id);
    try testing.expect(open_tx == null);

    // a doubled begin fails the second time
    const resp2 = handleRequest(&cs, "begin_tx a; begin_tx b");
    try testing.expectEqualStrings("ok tx=2\nfail begin_tx transaction already open\n", resp2);
    _ = handleRequest(&cs, "end_tx");

    // an end_tx or cancel_tx with nothing open fails (the wire's expression of an inconsistent handle)
    const resp3 = handleRequest(&cs, "end_tx; cancel_tx");
    try testing.expectEqualStrings("fail end_tx no open transaction\nfail cancel_tx no open transaction\n", resp3);

    // an action after cancel_tx carries no transaction tag
    const resp4 = handleRequest(&cs, "begin_tx m2; cancel_tx; action ping y");
    try testing.expect(std.mem.endsWith(u8, resp4, "ping pong y\n"));
    const rec_last = command_log.findBySeq(command_log.next_seq - 1).?;
    try testing.expectEqual(@as(?u64, null), rec_last.transaction_id);
}

test "copilot: 5 during a netsync session an operate is rejected and an observe is allowed" {
    resetCopilotForTest();
    harness.setExternalRegistryEnabled(true);
    defer {
        harness.setExternalRegistryEnabled(false);
        harness.action_registry.resetForTest();
    }
    var ac = TestActionCtx{};
    var pc = TestProbeCtx{ .value = 42 };
    harness.registerAction(.{ .name = "ping", .ctx = &ac, .run = testActionPing });
    harness.registerProbe(.{ .name = "cp_probe", .ctx = &pc, .digest = testProbeDigest, .snapshot = testProbeSnapshot });

    setNetsyncSessionActive(true);
    defer setNetsyncSessionActive(false);

    var cs: ConnState = undefined;
    const resp = handleRequest(&cs, "action ping x; begin_tx m; end_tx; cancel_tx");
    try testing.expectEqualStrings(
        "fail ping netsync session active (operate disabled)\n" ++
            "fail begin_tx netsync session active (operate disabled)\n" ++
            "fail end_tx netsync session active (operate disabled)\n" ++
            "fail cancel_tx netsync session active (operate disabled)\n",
        resp,
    );
    try testing.expectEqual(@as(u32, 0), ac.calls); // not dispatched
    try testing.expectEqual(@as(u32, 0), command_log.filled); // and not recorded either

    // an observe (digest) is allowed
    const resp2 = handleRequest(&cs, "digest cp_probe; digest capabilities");
    try testing.expect(std.mem.startsWith(u8, resp2, "cp_probe value=42\ncapabilities {"));

    // an observe (snapshot) is allowed too (only the four operate commands are rejected during netsync)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/netsync_snap.bin", .{tmp.sub_path});
    var req_buf: [256]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "snapshot cp_probe {s}", .{path});
    var expect_buf: [192]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expect_buf, "{s}\n", .{path});
    try testing.expectEqualStrings(expected, handleRequest(&cs, req));
    const written = try std.Io.Dir.cwd().readFileAlloc(io_val, path, gpa, .unlimited);
    defer gpa.free(written);
    try testing.expectEqualStrings("SNAPBYTES", written);
}

test "copilot: 6 the response formats for digest, snapshot and the unknown (capabilities, custom, an explicit path, the fail form, quit unsupported)" {
    resetCopilotForTest();
    harness.setExternalRegistryEnabled(true);
    defer {
        harness.setExternalRegistryEnabled(false);
        harness.action_registry.resetForTest();
    }
    var pc = TestProbeCtx{ .value = 9 };
    harness.registerProbe(.{ .name = "cp_probe", .ctx = &pc, .digest = testProbeDigest, .snapshot = testProbeSnapshot });

    var cs: ConnState = undefined;
    // digest: custom, capabilities, a built-in that is not exposed, and an unknown one
    try testing.expectEqualStrings("cp_probe value=9\n", handleRequest(&cs, "digest cp_probe"));
    try testing.expect(std.mem.startsWith(u8, handleRequest(&cs, "digest capabilities"), "capabilities {\"probes\":["));
    try testing.expectEqualStrings("error: probe not available via copilot (custom probes + capabilities only)\n", handleRequest(&cs, "digest fb"));
    try testing.expectEqualStrings("error: unknown probe\n", handleRequest(&cs, "digest nosuch"));

    // snapshot: writes to an explicit path and returns it; omitting the path is an error
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/copilot_snap.bin", .{tmp.sub_path});
    var req_buf: [256]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "snapshot cp_probe {s}", .{path});
    var expect_buf: [192]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expect_buf, "{s}\n", .{path});
    try testing.expectEqualStrings(expected, handleRequest(&cs, req));
    const written = try std.Io.Dir.cwd().readFileAlloc(io_val, path, gpa, .unlimited);
    defer gpa.free(written);
    try testing.expectEqualStrings("SNAPBYTES", written);
    try testing.expectEqualStrings("error: snapshot: path required\n", handleRequest(&cs, "snapshot cp_probe"));

    // an unknown action, an unknown command, and quit being unsupported
    try testing.expectEqualStrings("fail nosuch unknown action\n", handleRequest(&cs, "action nosuch x"));
    try testing.expectEqualStrings("fail bogus unknown command\n", handleRequest(&cs, "bogus 1 2"));
    try testing.expect(std.mem.startsWith(u8, handleRequest(&cs, "quit"), "fail quit "));
}

test "copilot: 7 a request over 64KiB gets an error response and is not run" {
    resetCopilotForTest();
    var cs: ConnState = undefined;
    cs.reset();
    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 'a');
    var fed: usize = 0;
    while (fed <= MAX_WIRE) : (fed += chunk.len) cs.feed(&chunk);
    try testing.expect(cs.req_overflow);
    try testing.expect(cs.finishRead());
    try testing.expectEqual(Phase.sending, cs.phase); // the execute phase is never entered
    try testing.expectEqualStrings("error: request too large\n", cs.resp[0..cs.resp_len]);
}

test "copilot: 8 mutual exclusion, so copilot is disabled alongside VP_HARNESS_*" {
    try testing.expect(!decideEnabled(true, true)); // the presence of a harness variable disables it
    try testing.expect(decideEnabled(true, false));
    try testing.expect(!decideEnabled(false, false));
    try testing.expect(!decideEnabled(false, true));
}

// The limit of this coverage, stated plainly: the real-socket timing of POLLIN and POLLHUP arriving together (unread
// data plus a HUP right after a half-close) cannot be reproduced deterministically in a unit test (it depends on the
// OS's buffering and would make a brittle test, so it is not added). What upholds it in the code is the structure
// described in `pumpRead`'s doc comment — "the close decision rests on the read result alone, and no POLLHUP bit
// closes directly" — and the equivalent branches at the ConnState layer (data present = run / no data = close) are
// exercised directly by the tests below. The real socket path is upheld by the E2E (scripts/drive always takes it, going write → half-close → read).
test "copilot: 9 ConnState transport behaviour (a partial feed, running exactly once, truncated, the deadline, the budget carrying over)" {
    resetCopilotForTest();
    harness.setExternalRegistryEnabled(true);
    defer {
        harness.setExternalRegistryEnabled(false);
        harness.action_registry.resetForTest();
    }
    var ac = TestActionCtx{};
    harness.registerAction(.{ .name = "ping", .ctx = &ac, .run = testActionPing });

    // A HUP with no data: half-close without receiving a single byte → finishRead()=false (the transport closes with no response)
    var cs: ConnState = undefined;
    cs.reset();
    try testing.expect(!cs.finishRead());

    // A HUP with data: if there is unread data the execute phase is reached even with a simultaneous HUP (a partial feed,
    // then a half-close, running exactly once)
    cs.reset();
    cs.feed("action pi");
    cs.feed("ng abc");
    try testing.expect(cs.finishRead());
    cs.executeBudget();
    try testing.expectEqual(Phase.sending, cs.phase);
    try testing.expectEqualStrings("ping pong abc\n", cs.resp[0..cs.resp_len]);
    try testing.expectEqual(@as(u32, 1), ac.calls);
    cs.executeBudget(); // from .sending on it is a no-op (nothing runs twice)
    try testing.expectEqual(@as(u32, 1), ac.calls);

    // a response over 64KiB gets a truncated line
    cs.reset();
    var big: [4096]u8 = undefined;
    @memset(&big, 'x');
    var appended: usize = 0;
    while (appended <= MAX_WIRE) : (appended += big.len) cs.appendResp(&big);
    try testing.expect(cs.resp_truncated);
    cs.beginSend();
    try testing.expect(std.mem.endsWith(u8, cs.resp[0..cs.resp_len], TRUNCATED_LINE));

    // deadline: true up to DEADLINE_FRAMES times, false beyond it (the close decision)
    cs.reset();
    var i: u32 = 0;
    while (i < DEADLINE_FRAMES) : (i += 1) {
        try testing.expect(cs.tickFrame());
    }
    try testing.expect(!cs.tickFrame());

    // budget carry-over: 17 commands are split across 2 pumps
    ac.calls = 0;
    cs.reset();
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(testing.allocator);
    var n: usize = 0;
    while (n < CMD_BUDGET + 1) : (n += 1) {
        try req.appendSlice(testing.allocator, "action ping x\n");
    }
    cs.feed(req.items);
    try testing.expect(cs.finishRead());
    cs.executeBudget();
    try testing.expectEqual(@as(u32, CMD_BUDGET), ac.calls); // the first pump does only the budget's worth
    try testing.expectEqual(Phase.executing, cs.phase); // carried over
    cs.executeBudget();
    try testing.expectEqual(@as(u32, CMD_BUDGET + 1), ac.calls); // the second pump consumes the rest
    try testing.expectEqual(Phase.sending, cs.phase);
}

test "copilot: 10 setSharedExecutor (an action is a direct dispatch not recorded in the own log, a transaction goes to the shared executor, and unset restores the old behaviour)" {
    resetCopilotForTest();
    harness.setExternalRegistryEnabled(true);
    defer {
        harness.setExternalRegistryEnabled(false);
        harness.action_registry.resetForTest();
    }
    var ac = TestActionCtx{};
    harness.registerAction(.{ .name = "ping", .ctx = &ac, .run = testActionPing });

    // set a shared executor (the application would own it; here it is local to the test)
    var shared_log: command.CommandLog = .{};
    var shared_exec = command.Executor.init(.{ .ctx = undefined, .run = dispatchHarnessAction });
    shared_exec.log = &shared_log;
    setSharedExecutor(&shared_exec);
    defer setSharedExecutor(null);

    // action: dispatched directly without reaching the own log (recording is the application wrapper's job, so here nothing is recorded)
    var cs: ConnState = undefined;
    const resp = handleRequest(&cs, "action ping hello");
    try testing.expectEqualStrings("ping pong hello\n", resp);
    try testing.expectEqual(@as(u32, 1), ac.calls); // the dispatch does happen
    try testing.expectEqual(@as(u32, 0), command_log.filled); // nothing lands in the own log
    try testing.expectEqual(@as(u32, 0), shared_log.filled); // nor through the executor (with no application wrapper there is no record)

    // begin_tx opens on the shared executor and is visible through openTransactionFor(.local_agent)
    const resp2 = handleRequest(&cs, "begin_tx macro");
    try testing.expectEqualStrings("ok tx=1\n", resp2);
    try testing.expect(shared_exec.openTransactionFor(.local_agent) != null);
    try testing.expect(executor.openTransactionFor(.local_agent) == null); // the own executor is unrelated
    const resp3 = handleRequest(&cs, "end_tx");
    try testing.expectEqualStrings("ok\n", resp3);
    try testing.expect(shared_exec.openTransactionFor(.local_agent) == null);

    // putting it back to unset restores the old behaviour (recorded in the own log through the own executor)
    setSharedExecutor(null);
    const resp4 = handleRequest(&cs, "action ping x");
    try testing.expectEqualStrings("ping pong x\n", resp4);
    try testing.expectEqual(@as(u32, 1), command_log.filled); // recorded in the own log
    try testing.expect(command_log.latest().?.actor.eql(.local_agent));
}

test "copilot: 8 wiring the netsync session callback rejects an operate, and ending it restores" {
    resetCopilotForTest();
    harness.netsync.resetForTest();
    harness.setExternalRegistryEnabled(true);
    defer {
        harness.setExternalRegistryEnabled(false);
        harness.action_registry.resetForTest();
        harness.netsync.resetForTest();
        setNetsyncSessionActive(false);
    }

    var ac = TestActionCtx{};
    var pc = TestProbeCtx{ .value = 7 };
    harness.registerAction(.{ .name = "ping", .ctx = &ac, .run = testActionPing });
    harness.registerProbe(.{ .name = "cp_probe", .ctx = &pc, .digest = testProbeDigest, .snapshot = testProbeSnapshot });

    // the equivalent of platform.init (the callback comes before enableRouter)
    harness.netsync.setSessionStateCallback(setNetsyncSessionActive);
    harness.netsync.initHost(0);
    try testing.expect(netsync_active);

    var cs: ConnState = undefined;
    const denied = handleRequest(&cs, "action ping x; begin_tx m");
    try testing.expectEqualStrings(
        "fail ping netsync session active (operate disabled)\n" ++
            "fail begin_tx netsync session active (operate disabled)\n",
        denied,
    );
    try testing.expectEqual(@as(u32, 0), ac.calls);

    const obs = handleRequest(&cs, "digest cp_probe");
    try testing.expectEqualStrings("cp_probe value=7\n", obs);

    harness.netsync.shutdown();
    try testing.expect(!netsync_active);

    const ok = handleRequest(&cs, "action ping y");
    try testing.expectEqualStrings("ping pong y\n", ok);
    try testing.expectEqual(@as(u32, 1), ac.calls);
}
