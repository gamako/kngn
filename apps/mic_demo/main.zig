//! apps/mic_demo — wasm microphone capture demo.
//!
//! Polls capture permission (idempotent), opens the default mic, drains the capture ring
//! each frame, and draws a simple RMS level bar. Intended for the worklet_shared +
//! data-capture web package; native builds compile but hit OS capture or Unsupported.

const std = @import("std");
const kit = @import("kit");
const platform = kit.platform;
const audio = kit.audio;
const app_runtime = kit.app_runtime;

const WIN_W: u32 = 640;
const WIN_H: u32 = 360;

/// Opaque dark slate (0xAARRGGBB).
const BG: u32 = 0xFF18_1820;
const BAR_BG: u32 = 0xFF28_2830;
const BAR_FG: u32 = 0xFF40_C070;
const STATUS_REQUESTING: u32 = 0xFFC0_A040;
const STATUS_RUNNING: u32 = 0xFF30_9040;
const STATUS_DENIED: u32 = 0xFFA0_3040;
const STATUS_UNSUPPORTED: u32 = 0xFF60_3080;
const STATUS_OPEN_FAILED: u32 = 0xFFC0_6030;

const UiPhase = enum {
    requesting,
    running,
    denied,
    unsupported,
    open_failed,
};

/// Latest mono RMS written by the capture callback.
/// Atomic so a native RT capture thread and the main frame can share it safely.
var g_latest_rms: std.atomic.Value(f32) = .init(0);

/// Capture callback: compute mono RMS for one block and publish it.
///
/// **Real-time rules** (no malloc, lock, IO, or panic). The only transcendental is
/// `@sqrt` once per block (~128 frames), not per sample. That is block-rate work in the
/// sense of AGENT.md Performance rules ("Concentrate them at block rate" for
/// transcendentals) — equivalent to `updateParams` / `prepareBlock` frequency, not an
/// inner per-sample loop — so a single `sqrt` here is acceptable.
fn captureCallback(frame: audio.AudioInFrame, userdata: ?*anyopaque) void {
    _ = userdata;
    var sum: f32 = 0;
    const n = frame.frames;
    if (n == 0) {
        g_latest_rms.store(0, .monotonic);
        return;
    }
    // Mono path: samples length is `frames` (channels == 1).
    const samples = frame.samples;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const s = samples[i];
        sum += s * s;
    }
    const mean = sum / @as(f32, @floatFromInt(n));
    const rms = @sqrt(mean);
    g_latest_rms.store(rms, .monotonic);
}

const App = struct {
    pub const window = .{
        .w = WIN_W,
        .h = WIN_H,
        .title = "mic_demo - microphone level",
    };

    gpa: std.mem.Allocator,
    phase: UiPhase = .requesting,
    device: ?audio.CaptureDevice = null,
    open_attempted: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !*App {
        _ = io;
        // Keep wasm audio infrastructure exports alive against DCE (no-op on native).
        // enableWebAudioExports: shared-memory worklet boot needs kngn_audio_set_sentinel /
        // check_sentinel / stack_top / render_buf even when this app never opens output.
        // enableWebCaptureExports: kngn_capture_* for the mic path.
        audio.enableWebAudioExports();
        audio.enableWebCaptureExports();

        const app = try gpa.create(App);
        app.* = .{ .gpa = gpa };
        return app;
    }

    pub fn deinit(self: *App) void {
        if (self.device) |*dev| {
            dev.close();
            self.device = null;
        }
        self.gpa.destroy(self);
    }

    pub fn frame(self: *App, win: *platform.Window, now: f64) !bool {
        _ = now;

        // Drain first (main-thread frame tick): delivers blocks and runs the callback.
        audio.drainCaptureIfActive();

        self.pollCaptureLifecycle();

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
            self.draw(fb);
            win.present();
        }

        return running;
    }

    fn pollCaptureLifecycle(self: *App) void {
        switch (self.phase) {
            .denied, .unsupported, .open_failed => return,
            .running => return,
            .requesting => {},
        }

        const perm = audio.requestCapturePermission() catch |err| {
            self.phase = switch (err) {
                error.Unsupported => .unsupported,
                error.PermissionDenied => .denied,
                else => .open_failed,
            };
            return;
        };

        switch (perm) {
            .not_determined => {},
            .denied, .restricted => self.phase = .denied,
            .granted => {
                if (self.open_attempted) return;
                self.open_attempted = true;
                const dev = audio.openCapture(self.gpa, .{
                    .capture_callback = captureCallback,
                    .sample_rate = 48000,
                    .channels = 1,
                }) catch |err| {
                    self.phase = switch (err) {
                        error.Unsupported => .unsupported,
                        error.PermissionDenied => .denied,
                        else => .open_failed,
                    };
                    return;
                };
                self.device = dev;
                self.device.?.start() catch {
                    self.device.?.close();
                    self.device = null;
                    self.phase = .open_failed;
                    return;
                };
                self.phase = .running;
            },
        }
    }

    fn draw(self: *const App, fb: platform.Framebuffer) void {
        const pixels = fb.pixels;
        const stride = fb.width;
        kit.pixelops.fill32(pixels, BG);

        // Status strip (colour codes the phase when text is unavailable).
        const status_color: u32 = switch (self.phase) {
            .requesting => STATUS_REQUESTING,
            .running => STATUS_RUNNING,
            .denied => STATUS_DENIED,
            .unsupported => STATUS_UNSUPPORTED,
            .open_failed => STATUS_OPEN_FAILED,
        };
        kit.pixelops.fillRect32(pixels, stride, 0, 0, WIN_W, 12, status_color);

        // Level meter track.
        const track_x: u32 = 40;
        const track_y: u32 = WIN_H / 2 - 24;
        const track_w: u32 = WIN_W - 80;
        const track_h: u32 = 48;
        kit.pixelops.fillRect32(pixels, stride, track_x, track_y, track_w, track_h, BAR_BG);

        if (self.phase == .running) {
            const rms = g_latest_rms.load(.monotonic);
            // Speech is well below full-scale; gain so typical levels fill most of the bar.
            const gain: f32 = 6.0;
            const t = std.math.clamp(rms * gain, 0.0, 1.0);
            const bar_w: u32 = @intFromFloat(@as(f32, @floatFromInt(track_w)) * t);
            if (bar_w > 0) {
                kit.pixelops.fillRect32(pixels, stride, track_x, track_y, bar_w, track_h, BAR_FG);
            }
        }
    }
};

const Rt = app_runtime.Runtime(App);

pub fn enableWasmRuntime() void {
    Rt.enableWasmExports();
    // Both hooks: worklet_shared boot always needs the audio sentinel exports
    // (see docs/wasm-deploy.md); capture adds the mic path.
    audio.enableWebAudioExports();
    audio.enableWebCaptureExports();
}

pub fn main(process_init: std.process.Init) !void {
    std.debug.print("apps/mic_demo: mic level meter (ESC quits)\n", .{});
    std.debug.print("  status strip: yellow=requesting green=running red=denied purple=unsupported orange=open_failed\n", .{});
    try Rt.runNative(process_init);
}
