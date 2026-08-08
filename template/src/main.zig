//! Minimal external app template for kngn.
//!
//! Demonstrates kit-only imports, Runtime(App), a GUI widget wired through the full
//! event-forwarding path (`pollEvents` → `beginFrame` → `pushEvent` → widget →
//! `endFrame` → `render`), one harness probe, one action, and a pure unit test.
//! Hot path: per-frame full-framebuffer fill via kit.pixelops.fill32 (never @memset),
//! plus the GUI's own per-frame `beginFrame`/`endFrame`/`render` on a single button —
//! a constant-size DrawList, not a new all-pixel loop, so the SIMD/div255/clip-hoist
//! rules for a new all-pixel loop do not apply here. Probe/action are event-time only.

const std = @import("std");
const kit = @import("kit");
const platform = kit.platform;
const app_runtime = kit.app_runtime;
const gui = kit.gui;

/// Default solid fill (opaque dark slate, 0xAARRGGBB).
const default_color: u32 = 0xFF2E3440;
/// Fill the "Toggle color" button switches to (opaque light blue, 0xAARRGGBB).
const alt_color: u32 = 0xFF88C0D0;

const App = struct {
    pub const window = .{
        .w = 320,
        .h = 240,
        .title = "kngn template",
    };

    gpa: std.mem.Allocator,
    color: u32,
    frame_count: u64,
    ctx: gui.Context,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !*App {
        _ = io;
        const app = try gpa.create(App);
        app.* = .{
            .gpa = gpa,
            .color = default_color,
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
            if (toGuiEvent(ev)) |ge| self.ctx.pushEvent(ge);
        }

        if (self.ctx.button("Toggle color")) {
            self.color = if (self.color == default_color) alt_color else default_color;
        }
        self.ctx.endFrame();

        // Per-frame full-pixel fill: use kit.pixelops.fill32 (Performance rules).
        kit.pixelops.fill32(fb.pixels, self.color);
        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        gui.render(target, &self.ctx.draw_list, self.ctx.font, 1.0);
        win.present();

        return running;
    }
};

/// platform.MouseButton → InputEvent button index (0=left/1=right/2=middle).
fn buttonToU8(b: platform.MouseButton) u8 {
    return switch (b) {
        .left => 0,
        .right => 1,
        .middle => 2,
        else => 0xFF,
    };
}

/// platform.Event → gui.InputEvent, the caller-owned conversion every GUI app needs
/// (mirrors apps/synth/main.zig and examples/09_gui_interaction). Events the GUI has
/// no use for become null and are simply not forwarded.
fn toGuiEvent(ev: platform.Event) ?gui.InputEvent {
    return switch (ev) {
        .mouse_move => |m| .{ .mouse_move = .{ .x = m.x, .y = m.y, .modifiers = m.modifiers.toC() } },
        .mouse_down => |m| .{ .mouse_down = .{ .x = m.x, .y = m.y, .button = buttonToU8(m.button), .modifiers = m.modifiers.toC() } },
        .mouse_up => |m| .{ .mouse_up = .{ .x = m.x, .y = m.y, .button = buttonToU8(m.button), .modifiers = m.modifiers.toC() } },
        .mouse_scroll => |s| .{ .mouse_scroll = .{ .x = s.x, .y = s.y, .dx = s.dx, .dy = s.dy, .modifiers = s.modifiers.toC() } },
        .key_down => |k| blk: {
            const code = @intFromEnum(k.key);
            if (code < 0) break :blk null;
            break :blk .{ .key_down = .{ .code = @intCast(code), .modifiers = k.modifiers.toC(), .repeat = k.is_repeat } };
        },
        .key_up => |k| blk: {
            const code = @intFromEnum(k.key);
            if (code < 0) break :blk null;
            break :blk .{ .key_up = .{ .code = @intCast(code), .modifiers = k.modifiers.toC() } };
        },
        else => null,
    };
}

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

    // ctx is untouched by runSetColor, so the GUI context is left undefined here.
    var app: App = .{
        .gpa = undefined,
        .color = default_color,
        .frame_count = 0,
        .ctx = undefined,
    };
    var out: [64]u8 = undefined;
    const result = try runSetColor(&app, "FF3366", &out);
    try std.testing.expectEqual(@as(u32, 0xFFFF3366), app.color);
    try std.testing.expectEqualStrings("ok color=#FF3366", result);
}
