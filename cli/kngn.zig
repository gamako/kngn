//! `kngn`: the command line entry point.
//!
//! One binary, one subcommand per line of work:
//!   kngn ctl --port-file <file> '<harness commands>'   drive a running app and print the response
//!   kngn mcp --port-file <file>                        serve that app to an MCP client over stdio
//!
//! Both subcommands talk to the same thing — a running application's verification harness over its
//! TCP loopback listener — so they take the same port arguments. Details are in each module and in
//! docs/harness.md.
//!
//! Pure std + `std.Io.net` only (no platform/audio dependency), so it builds identically on
//! macOS, Linux and Windows.

const std = @import("std");

const ctl = @import("ctl.zig");
const mcp = @import("mcp.zig");

const Subcommand = enum { ctl, mcp };

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer it.deinit();
    _ = it.next(); // program name

    const name = it.next() orelse usage("a subcommand is required");
    const sub = std.meta.stringToEnum(Subcommand, name) orelse usage("unknown subcommand");

    // The iterator keeps its position, so each subcommand sees exactly its own arguments.
    switch (sub) {
        .ctl => try ctl.run(init, &it),
        .mcp => try mcp.run(init, &it),
    }
}

/// Wrong usage is the caller's mistake, not a bug here, so print one line and exit rather than
/// returning an error (which would print a Zig stack trace on top of the message).
fn usage(reason: []const u8) noreturn {
    std.debug.print(
        \\kngn: {s}
        \\
        \\usage: kngn <command> [args]
        \\
        \\  ctl   drive a running app through its verification harness and print the response
        \\  mcp   serve that harness to an MCP client over stdio
        \\
        \\Both commands accept --port <n> or --port-file <path>, and fall back to the
        \\KNGN_HARNESS_LISTEN / KNGN_HARNESS_PORT_FILE environment variables.
        \\
    , .{reason});
    std.process.exit(1);
}
