//! Minimal external app template for kngn.
//!
//! Demonstrates kit-only imports, Runtime(App), one harness probe, one action,
//! and a pure unit test. Hot path: per-frame full-framebuffer fill via
//! kit.pixelops.fill32 (never @memset). Probe/action are event-time only.

const std = @import("std");
const kit = @import("kit");
const platform = kit.platform;
const app_runtime = kit.app_runtime;

/// Default solid fill (opaque dark slate, 0xAARRGGBB).
const default_color: u32 = 0xFF2E3440;

const App = struct {
    pub const window = .{
        .w = 320,
        .h = 240,
        .title = "kngn template",
    };

    gpa: std.mem.Allocator,
    color: u32,
    frame_count: u64,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !*App {
        _ = io;
        const app = try gpa.create(App);
        app.* = .{
            .gpa = gpa,
            .color = default_color,
            .frame_count = 0,
        };
        registerHarness(app);
        return app;
    }

    pub fn deinit(self: *App) void {
        self.gpa.destroy(self);
    }

    pub fn frame(self: *App, win: *platform.Window, now: f64) !bool {
        _ = now;
        self.frame_count +%= 1;

        var running = true;
        while (win.nextEvent()) |ev| {
            switch (ev) {
                .quit => running = false,
                .key_down => |k| if (k.key == .ESCAPE) {
                    running = false;
                },
                else => {},
            }
        }

        if (win.lockFramebuffer()) |fb| {
            defer fb.unlock();
            // Per-frame full-pixel fill: use kit.pixelops.fill32 (Performance rules).
            kit.pixelops.fill32(fb.pixels, self.color);
            win.present();
        }

        return running;
    }
};

fn registerHarness(app: *App) void {
    platform.registerProbe(.{
        .name = "state",
        .ctx = app,
        .ext = "txt",
        .digest = digestState,
        .desc = "template application state",
    });
    platform.registerAction(.{
        .name = "set_color",
        .ctx = app,
        .args = &.{.{ .name = "color", .kind = "string" }},
        .network_policy = .local_only,
        .run = runSetColor,
    });
}

fn digestState(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    return std.fmt.bufPrint(buf, "color=#{X:0>6} frames={d}", .{
        app.color & 0xFF_FFFF,
        app.frame_count,
    }) catch buf[0..0];
}

/// Parse RRGGBB hex into opaque 0xAARRGGBB. Pure: no platform init.
fn parseColorHex(args: []const u8) !u32 {
    const hex = std.mem.trim(u8, args, " \t\r\n");
    if (hex.len != 6) return error.InvalidArgument;
    const rgb = std.fmt.parseInt(u32, hex, 16) catch return error.InvalidArgument;
    return 0xFF00_0000 | rgb;
}

fn runSetColor(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const color = try parseColorHex(args);
    app.color = color;
    return std.fmt.bufPrint(buf, "ok color=#{X:0>6}", .{color & 0xFF_FFFF}) catch error.BufferTooSmall;
}

const Rt = app_runtime.Runtime(App);

pub fn enableWasmRuntime() void {
    Rt.enableWasmExports();
}

pub fn main(init: std.process.Init) !void {
    try Rt.runNative(init);
}

test "set_color updates application state" {
    try std.testing.expectEqual(@as(u32, 0xFFFF3366), try parseColorHex("FF3366"));
    try std.testing.expectEqual(@as(u32, 0xFF000000), try parseColorHex("000000"));
    try std.testing.expectError(error.InvalidArgument, parseColorHex("FFF"));
    try std.testing.expectError(error.InvalidArgument, parseColorHex("GGHHII"));

    var app: App = .{
        .gpa = undefined,
        .color = default_color,
        .frame_count = 0,
    };
    var out: [64]u8 = undefined;
    const result = try runSetColor(&app, "FF3366", &out);
    try std.testing.expectEqual(@as(u32, 0xFFFF3366), app.color);
    try std.testing.expectEqualStrings("ok color=#FF3366", result);
}
