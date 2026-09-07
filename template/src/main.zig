//! Minimal external app template for kngn. This file is the wiring; the screen it
//! draws is `screen.zig`, which is where an app of your own takes shape.
//!
//! Demonstrates kit-only imports, Runtime(App), a GUI screen wired through the full
//! event-forwarding path (`pollEvents` → `beginFrame` → `pushEvent` → widgets →
//! `endFrame` → `render`), one harness probe, one action, and a pure unit test.
//! Hot path: per-frame full-framebuffer fill via kit.pixelops.fill32 (never @memset).
//! The GUI's own per-frame work is a constant-size DrawList, not a second all-pixel
//! loop, so the SIMD/div255/clip-hoist rules for a new all-pixel loop do not apply
//! here. Probe/action are event-time only.

const std = @import("std");
const kit = @import("kit");
const platform = kit.platform;
const app_runtime = kit.app_runtime;
const gui = kit.gui;
const screen = @import("screen.zig");

const App = struct {
    pub const window = .{
        .w = 320,
        .h = 240,
        .title = "kngn template",
    };

    gpa: std.mem.Allocator,
    state: screen.State,
    frame_count: u64,
    ctx: gui.Context,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !*App {
        _ = io;
        const app = try gpa.create(App);
        app.* = .{
            .gpa = gpa,
            .state = .{},
            .frame_count = 0,
            .ctx = gui.Context.init(gpa, gui.default_font),
        };
        registerHarness(app);
        return app;
    }

    pub fn deinit(self: *App) void {
        self.ctx.deinit();
        self.gpa.destroy(self);
    }

    pub fn frame(self: *App, win: *platform.Window, now: f64) !bool {
        _ = now;
        self.frame_count +%= 1;

        const fb = win.lockFramebuffer() orelse return true; // No frame slot yet; retry next frame.
        defer fb.unlock();

        var running = true;
        // Draining the window's events inside the frame, as below, hands them straight to the
        // widgets built from them. Forwarding them before beginFrame works too — the GUI stages
        // input that arrives outside a frame and applies it when the next one opens — so this
        // order is a readability choice, not a requirement (docs/adr/028).
        self.ctx.beginFrame(fb.width, fb.height);
        while (win.nextEvent()) |ev| {
            switch (ev) {
                .quit => running = false,
                .key_down => |k| if (k.key == .ESCAPE) {
                    running = false;
                },
                else => {},
            }
            if (kit.toGuiEvent(ev)) |ge| self.ctx.pushEvent(ge);
        }

        screen.build(&self.ctx, &self.state);
        self.ctx.endFrame();

        // Per-frame full-pixel fill: use kit.pixelops.fill32 (Performance rules).
        kit.pixelops.fill32(fb.pixels, self.state.color);
        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        gui.render(target, self.ctx.postFrameDrawList(), self.ctx.font, 1.0);
        win.present();

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
        app.state.color & 0xFF_FFFF,
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
    app.state.color = color;
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

    // ctx is untouched by runSetColor, so the GUI context is left undefined here.
    var app: App = .{
        .gpa = undefined,
        .state = .{},
        .frame_count = 0,
        .ctx = undefined,
    };
    var out: [64]u8 = undefined;
    const result = try runSetColor(&app, "FF3366", &out);
    try std.testing.expectEqual(@as(u32, 0xFFFF3366), app.state.color);
    try std.testing.expectEqualStrings("ok color=#FF3366", result);
}
