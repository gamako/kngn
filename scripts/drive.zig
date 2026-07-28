//! drive: CLI driver for the headless harness listen transport (TCP loopback).
//!
//! Send one request and get one response against a background app listening on
//! `KNGN_HARNESS_LISTEN[=port]`. State lives in the app process (connections are disposable).
//!
//! Usage:
//!   drive --port 54321 'inject key_down A; step 3; digest fb'
//!   drive --port-file /tmp/vp.port 'step 1; digest fb'
//!   (when --port / --port-file are omitted, read env KNGN_HARNESS_LISTEN (positive port) / KNGN_HARNESS_PORT_FILE)
//!
//! The command string is the remaining args joined with spaces. The harness splits on `;` / newlines into multiple commands.
//! After send, half-close the write side and print the response (digest text / snapshot path) to stdout, then exit.
//!
//! Pure std + `std.Io.net` only (no platform/audio dependency). Same code on mac/Linux/Windows.

const std = @import("std");
const net = std.Io.net;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // Short-lived CLI: use an arena (all allocs freed at process exit; no manual free / leak report).
    const gpa = init.arena.allocator();

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer it.deinit();
    _ = it.next(); // program name

    var port_opt: ?u16 = null;
    var port_file: ?[]const u8 = null;
    var cmd: std.ArrayList(u8) = .empty;

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const v = it.next() orelse return die("--port requires a value\n");
            port_opt = std.fmt.parseInt(u16, v, 10) catch return die("--port value is invalid\n");
        } else if (std.mem.eql(u8, arg, "--port-file")) {
            port_file = it.next() orelse return die("--port-file requires a value\n");
        } else {
            if (cmd.items.len > 0) try cmd.append(gpa, ' ');
            try cmd.appendSlice(gpa, arg);
        }
    }
    if (cmd.items.len == 0) return die("missing command string (example: drive --port-file /tmp/vp.port 'step 1; digest fb')\n");

    // port resolution: --port > --port-file > env KNGN_HARNESS_LISTEN (positive) > env KNGN_HARNESS_PORT_FILE
    const port: u16 = port_opt orelse blk: {
        if (port_file) |pf| break :blk try readPortFile(io, gpa, pf);
        if (init.environ_map.get("KNGN_HARNESS_LISTEN")) |pe| {
            const trimmed = std.mem.trim(u8, pe, " \t");
            if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "0")) {
                break :blk std.fmt.parseInt(u16, trimmed, 10) catch return die("KNGN_HARNESS_LISTEN value is invalid\n");
            }
        }
        if (init.environ_map.get("KNGN_HARNESS_PORT_FILE")) |pf| break :blk try readPortFile(io, gpa, pf);
        return die("port is unknown (set one of --port / --port-file / KNGN_HARNESS_LISTEN / KNGN_HARNESS_PORT_FILE)\n");
    };

    // connect → send → write half-close → receive response → stdout
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    var stream = addr.connect(io, .{ .mode = .stream }) catch |err| {
        return die2("failed to connect to 127.0.0.1: {s}\n", .{@errorName(err)});
    };
    defer stream.close(io);

    {
        var wbuf: [4096]u8 = undefined;
        var writer = stream.writer(io, &wbuf);
        try writer.interface.writeAll(cmd.items);
        try writer.interface.flush();
    }
    stream.shutdown(io, .send) catch {}; // Tell the peer EOF (the harness reads until here)

    var rbuf: [4096]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    const resp = reader.interface.allocRemaining(gpa, std.Io.Limit.limited(1 << 20)) catch |err| {
        return die2("failed to receive response: {s}\n", .{@errorName(err)});
    };

    var obuf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &obuf);
    try stdout.interface.writeAll(resp);
    try stdout.interface.flush();

    // expect/assert outcome propagation: scan **each line** of the response; if any starts with `fail `,
    // drive itself exits non-zero (useful for agent self-loops). stdout passthrough already finished above.
    // Detect only a leading `fail ` (do not treat harness warnLine `error:` and other benign warnings as failure).
    // Also catch `fail ` on line 2+ when multiple commands share one request (line scan, not whole-buffer startsWith).
    // Assertion failure is not a drive bug, so prefer a single stderr line + `exit(1)` over `return error`
    // (which would print a Zig stack trace). stdout is already passed through; omitting defer close is fine with no further work.
    var lines = std.mem.splitScalar(u8, resp, '\n');
    while (lines.next()) |ln| {
        if (std.mem.startsWith(u8, ln, "fail ")) {
            std.debug.print("drive: expect/assert failed (non-zero exit)\n", .{});
            std.process.exit(1);
        }
    }
}

fn readPortFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !u16 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, std.Io.Limit.limited(64)) catch |err| {
        return die2("failed to read port file {s}: {s}\n", .{ path, @errorName(err) });
    };
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    return std.fmt.parseInt(u16, trimmed, 10) catch return die("port file contents are invalid\n");
}

fn die(msg: []const u8) error{DriveFailed} {
    std.debug.print("drive: {s}", .{msg});
    return error.DriveFailed;
}

fn die2(comptime fmt: []const u8, args: anytype) error{DriveFailed} {
    std.debug.print("drive: " ++ fmt, args);
    return error.DriveFailed;
}
