//! 20_capture_demo: dogfooding demo for the capture input foundation (see docs/capture.md).
//!
//! mic → waveform (oscilloscope) + FFT spectrogram + level-meter viz (reuses libs/viz;
//! apps/synth is the model), camera → canvas (framebuffer) display, both on one screen.
//!
//! ## Choosing the data source (production vs headless verification)
//!
//! Branches on `harness.isCaptureSyntheticActive()` (true only when `KNGN_HARNESS_CAPTURE_SYNTHETIC=1`
//! and the harness is enabled; core/control/harness.zig):
//! - **Production (default)**: `core/camera.zig` (macOS=AVFoundation real backend / else stub) and
//!   the capture extension of `core/audio.zig` (macOS=AUHAL input real backend / else stub).
//!   Needs a real camera/mic plus the macOS TCC permission dialog (manual, hardware-dependent verification).
//! - **Headless verification**: uses `core/capture_synthetic.zig` directly (harness-built-in synthetic
//!   mic/camera source). Deterministic patterns with no real device/TCC.
//!
//! Both paths join the same `App`/draw/probe path (types are structurally identical via the shared named
//! module `capture_types.VideoFrame`/`AudioInFrame` on the camera.zig and capture_synthetic.zig sides).
//!
//! ## Scope (wiring to the capture facade / kit promotion)
//!
//! See docs/capture.md for the capture control/data-plane contract. This demo's role is a minimal
//! mic/camera app plus a kit-promotion decision. This demo **does not promote camera into kit** and
//! lives under `examples/` (outside ADR-007 R5's kit-only force; see the build.zig header).
//! Reason: headless verification needs a direct import of `core/capture_synthetic.zig` (harness-built-in; not wired
//! through the camera/audio facade). That is only allowed under the traditional examples wiring
//! (R5 "apps are kit-only" does not apply here). Promoting camera alone into kit still would not kit-ify
//! the synthetic path (an intentionally decoupled internal tool; putting it on kit's public surface
//! would dilute that design), so placement stays under examples. camera.zig/audio.zig
//! themselves (facade APIs) are unchanged here (consume only). Revisit kit promotion when a full camera app under
//! apps/ is needed.
//!
//! Hot path declaration:
//! - Per-frame full clear (background `@memset`) + canvas blit of the camera frame (`drawVideoFrame`) are
//!   **per-frame all-pixel-class loops** (under the performance rules). The blit is an opaque row copy with
//!   no blend/division (same class as `copyBgraRows` in `camera_macos.zig`); clip is computed once outside
//!   the loop and the inside is unchecked `@memcpy`. With no blend, the `pixelops` SIMD three-point set
//!   does not apply (same rationale as `copyBgraRows` itself).
//! - mic capture callback (`micCallback`): **RT (per-sample class; called per block)**.
//!   No malloc/lock/IO/panic. Only `SampleTap.write()` (alloc/lock-free SPSC drop-on-full).
//! - `capture_synthetic.SyntheticVideoDevice.renderFrame`: treated as
//!   **event-only** (this demo calls it every frame, but the target is a small 320x240 synthetic image and
//!   is not treated like the real-camera draw hot path; same rationale as the synthetic source design).
//! - probe digest build (`captureDemoDigest`): event-only (when a `digest` command is issued).

const std = @import("std");
const platform = @import("platform");
const harness = @import("harness");
const camera = @import("camera");
const audio = @import("audio");
const capture_synthetic = @import("capture_synthetic");
const spectrogram = @import("spectrogram");
const scope = @import("scope");
const synthlib = @import("synth");

const FRAME_PERIOD_S: f64 = 0.016;

// ============================================================================
// Layout
// ============================================================================
const WIN_W = 920;
const WIN_H = 300;

const CAM_X0 = 20;
const CAM_Y0 = 20;
const CAM_W = 320;
const CAM_H = 240;

const SPEC_X0 = 360;
const SPEC_Y0 = 20;
const SPEC_W = 340;
const SPEC_H = 110;

const SCOPE_X0 = 360;
const SCOPE_Y0 = 150;
const SCOPE_W = 300;
const SCOPE_H = 110;

const METER_X0 = 680;
const METER_Y0 = 150;
const METER_W = 40;
const METER_H = 110;

const MIC_SAMPLE_RATE = 48000;
const MIC_CHANNELS = 1;

const BG_COLOR: u32 = 0xFF14141C;
const CAM_EMPTY_COLOR: u32 = 0xFF202028; // Placeholder background when no camera frame
const BORDER_COLOR: u32 = 0xFF404858;

const Spec = spectrogram.Spectrogram(SPEC_W, SPEC_H);
const Scope = scope.Oscilloscope(SCOPE_W, SCOPE_H);
const Tap = synthlib.SampleTap(8192);

// ============================================================================
// Data source (production = real backend / headless verification = synthetic)
// ============================================================================

const VideoSource = union(enum) {
    none,
    real: camera.VideoDevice,
    synthetic: capture_synthetic.SyntheticVideoDevice,
};

const MicSource = union(enum) {
    none,
    real: audio.CaptureDevice,
    synthetic: capture_synthetic.SyntheticAudioDevice,
};

fn videoSourceName(vs: VideoSource) []const u8 {
    return @tagName(std.meta.activeTag(vs));
}

fn micSourceName(ms: MicSource) []const u8 {
    return @tagName(std.meta.activeTag(ms));
}

fn closeVideoSource(vs: *VideoSource) void {
    switch (vs.*) {
        .none => {},
        .real => |dev| dev.close(),
        .synthetic => |*dev| dev.close(),
    }
    vs.* = .none;
}

fn closeMicSource(ms: *MicSource) void {
    switch (ms.*) {
        .none => {},
        .real => |dev| dev.close(),
        .synthetic => |dev| dev.close(),
    }
    ms.* = .none;
}

/// Fetch the latest video frame. synthetic is pull-style (`renderFrame` every time);
/// real is poll-style peeking the latest frame published by the capture thread (TripleBuffer).
fn pollVideoFrame(vs: *VideoSource, tick: *u64) ?camera.VideoFrame {
    return switch (vs.*) {
        .none => null,
        .real => |dev| dev.pollLatestFrame(),
        .synthetic => |*dev| blk: {
            tick.* += 1;
            break :blk dev.renderFrame(tick.*);
        },
    };
}

fn micCallback(frame: audio.AudioInFrame, userdata: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(userdata.?));
    app.tap.write(frame.samples);
}

/// Request camera permission; on deny/unsupported log the reason and return `.none` (TCC visual checks
/// are in the manual verification range).
///
/// **Headless guard**: when `harness.isHeadlessActive()` is true, never call AVFoundation and return
/// `.none` immediately. `requestPermission()` (`avRequestAccessBlocking`) blocks waiting on a completion
/// handler via the runloop, so with no display/runloop in headless the reply may never arrive and it can
/// hang. Trying real capture headless (no way to show a TCC dialog) is meaningless, so
/// fail-fast.
fn openRealVideo(allocator: std.mem.Allocator) VideoSource {
    if (harness.isHeadlessActive()) {
        std.debug.print("[capture_demo] headless active: not attempting real camera (TCC wait can hang; use KNGN_HARNESS_CAPTURE_SYNTHETIC=1)\n", .{});
        return .none;
    }
    const perm = camera.requestPermission() catch |err| {
        std.debug.print("[capture_demo] camera.requestPermission failed: {s} (real camera disabled)\n", .{@errorName(err)});
        return .none;
    };
    if (perm != .granted) {
        std.debug.print("[capture_demo] camera permission = {t} (real camera disabled; TCC dialog is manual verification)\n", .{perm});
        return .none;
    }
    var dev = camera.open(allocator, .{ .width = CAM_W, .height = CAM_H, .frame_rate = 30 }) catch |err| {
        std.debug.print("[capture_demo] camera.open failed: {s}\n", .{@errorName(err)});
        return .none;
    };
    dev.start() catch |err| {
        std.debug.print("[capture_demo] camera.start failed: {s}\n", .{@errorName(err)});
        dev.close();
        return .none;
    };
    std.debug.print("[capture_demo] real camera opened {d}x{d}\n", .{ dev.config().width, dev.config().height });
    return .{ .real = dev };
}

fn openSyntheticVideo(allocator: std.mem.Allocator) VideoSource {
    const dev = capture_synthetic.openVideo(allocator, .{ .width = CAM_W, .height = CAM_H, .frame_rate = 30 }) catch |err| {
        std.debug.print("[capture_demo] capture_synthetic.openVideo failed: {s}\n", .{@errorName(err)});
        return .none;
    };
    std.debug.print("[capture_demo] synthetic camera opened {d}x{d}\n", .{ CAM_W, CAM_H });
    return .{ .synthetic = dev };
}

/// Request mic permission; on deny/unsupported log the reason and return `.none` (symmetric with openRealVideo).
/// Headless guard has the same reason as openRealVideo (`requestCapturePermission()` can also hang via
/// the same `avRequestAccessBlocking`).
fn openRealMic(allocator: std.mem.Allocator, app: *App) MicSource {
    if (harness.isHeadlessActive()) {
        std.debug.print("[capture_demo] headless active: not attempting real mic (TCC wait can hang; use KNGN_HARNESS_CAPTURE_SYNTHETIC=1)\n", .{});
        return .none;
    }
    const perm = audio.requestCapturePermission() catch |err| {
        std.debug.print("[capture_demo] audio.requestCapturePermission failed: {s} (real mic disabled)\n", .{@errorName(err)});
        return .none;
    };
    if (perm != .granted) {
        std.debug.print("[capture_demo] mic permission = {t} (real mic disabled; TCC dialog is manual verification)\n", .{perm});
        return .none;
    }
    var dev = audio.openCapture(allocator, .{
        .sample_rate = MIC_SAMPLE_RATE,
        .channels = MIC_CHANNELS,
        .capture_callback = micCallback,
        .userdata = app,
    }) catch |err| {
        std.debug.print("[capture_demo] audio.openCapture failed: {s}\n", .{@errorName(err)});
        return .none;
    };
    dev.start() catch |err| {
        std.debug.print("[capture_demo] mic start failed: {s}\n", .{@errorName(err)});
        dev.close();
        return .none;
    };
    std.debug.print("[capture_demo] real mic opened sr={d} ch={d}\n", .{ dev.config().sample_rate, dev.config().channels });
    // The viz pipeline (tap→spec/osc/meter) assumes mono (1ch). If the real device negotiates a different
    // channel count than requested, warn explicitly (no downmix; when channels disagree the frequency axis /
    // waveform can look shifted relative to the real signal).
    if (dev.config().channels != MIC_CHANNELS) {
        std.debug.print("[capture_demo] warning: real mic negotiated channels={d} (requested {d}); viz assumes mono so it may look shifted\n", .{ dev.config().channels, MIC_CHANNELS });
    }
    return .{ .real = dev };
}

fn openSyntheticMic(allocator: std.mem.Allocator, app: *App) MicSource {
    var dev = capture_synthetic.openAudio(allocator, .{
        .sample_rate = MIC_SAMPLE_RATE,
        .channels = MIC_CHANNELS,
        .capture_callback = micCallback,
        .userdata = app,
    }) catch |err| {
        std.debug.print("[capture_demo] capture_synthetic.openAudio failed: {s}\n", .{@errorName(err)});
        return .none;
    };
    dev.start() catch |err| {
        std.debug.print("[capture_demo] synthetic mic start failed: {s}\n", .{@errorName(err)});
        dev.close();
        return .none;
    };
    std.debug.print("[capture_demo] synthetic mic opened sr={d} ch={d}\n", .{ MIC_SAMPLE_RATE, MIC_CHANNELS });
    return .{ .synthetic = dev };
}

/// Read the effective sample rate (open source's `.config().sample_rate`; default when not open).
/// A real mic may settle to a value other than `MIC_SAMPLE_RATE` via AUHAL hardware negotiation, so
/// the spectrogram frequency axis must be recomputed from this value.
fn micSampleRate(ms: MicSource) u32 {
    return switch (ms) {
        .none => MIC_SAMPLE_RATE,
        .real => |dev| dev.config().sample_rate,
        .synthetic => |dev| dev.config().sample_rate,
    };
}

// ============================================================================
// App state
// ============================================================================

const App = struct {
    video: VideoSource = .none,
    video_tick: u64 = 0,
    video_frames_seen: u64 = 0,

    mic: MicSource = .none,
    tap: Tap = .{},
    mic_frames_seen: u64 = 0,

    spec: Spec = .{},
    osc: Scope = .{},
    meter: scope.LevelMeter = .{},
};

fn captureDemoDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const mic_silent: u32 = if (app.meter.disp_rms < 1e-4) 1 else 0;
    return std.fmt.bufPrint(buf, "video_source={s} video_w={d} video_h={d} video_frames={d} mic_source={s} mic_frames={d} mic_rms={d:.4} mic_peak={d:.4} mic_silent={d}", .{
        videoSourceName(app.video),
        CAM_W,
        CAM_H,
        app.video_frames_seen,
        micSourceName(app.mic),
        app.mic_frames_seen,
        app.meter.disp_rms,
        app.meter.disp_peak,
        mic_silent,
    }) catch buf[0..0];
}

// ============================================================================
// Drawing
// ============================================================================

/// framebuffer pixel u32 packing (same as gui.Color / scope.zig: memory B,G,R,A = u32 0xAARRGGBB).
fn fillRect(pixels: []u32, fb_w: usize, fb_h: usize, x0: usize, y0: usize, w: usize, h: usize, color: u32) void {
    const copy_w = if (x0 >= fb_w) 0 else @min(w, fb_w - x0);
    const copy_h = if (y0 >= fb_h) 0 else @min(h, fb_h - y0);
    var y: usize = 0;
    while (y < copy_h) : (y += 1) {
        @memset(pixels[(y0 + y) * fb_w + x0 ..][0..copy_w], color);
    }
}

fn drawBorder(pixels: []u32, fb_w: usize, fb_h: usize, x0: usize, y0: usize, w: usize, h: usize, color: u32) void {
    if (w == 0 or h == 0) return;
    fillRect(pixels, fb_w, fb_h, x0, y0, w, 1, color);
    fillRect(pixels, fb_w, fb_h, x0, y0 + h - 1, w, 1, color);
    fillRect(pixels, fb_w, fb_h, x0, y0, 1, h, color);
    fillRect(pixels, fb_w, fb_h, x0 + w - 1, y0, 1, h, color);
}

/// Draw a camera frame into the canvas region (fixed x0,y0).
///
/// Hot path declaration: an all-pixel-class loop called on each arriving frame, but an opaque row copy with
/// no blend/division (same class as `copyBgraRows` in `core/camera_macos.zig`). Clip is computed once
/// outside the loop; inside is unchecked `@memcpy` (row-contiguous). With no blend,
/// the `pixelops` SIMD three-point set does not apply (same rationale as copyBgraRows).
/// Fit the camera frame into the CAM_W×CAM_H box with nearest-neighbour.
///
/// The frame's actual size (`frame.width/height`) can disagree with the request for driver reasons (V4L2 rounds
/// the requested resolution to a supported discrete value; e.g. 320×240 request → uvcvideo returns 640×480). Blitting
/// at native size would spill into the neighbouring viz panel, so always scale to the box. When aspects match
/// as in 640×480→320×240 the full FOV fits without distortion (non-matching aspects become anisotropic, which
/// is acceptable for a demo preview).
///
/// Hot path declaration: every frame runs over all CAM_W×CAM_H box pixels. To avoid per-pixel division, build the
/// column source-x map once outside the loop (performance rule "no per-pixel division"). No SIMD
/// (fast enough at camera fps / 320×240 demo preview; nearest-neighbour gather gains little from SIMD).
fn drawVideoFrame(pixels: []u32, fb_w: usize, fb_h: usize, x0: usize, y0: usize, frame: camera.VideoFrame) void {
    if (x0 >= fb_w or y0 >= fb_h or frame.width == 0 or frame.height == 0) return;
    const box_w = @min(@as(usize, CAM_W), fb_w - x0); // Clip at the fb edge (only the part of the box that is off-screen)
    const box_h = @min(@as(usize, CAM_H), fb_h - y0);
    // Column map (box x → frame x) once outside the loop. box_w <= CAM_W so [CAM_W]usize is enough.
    var x_map: [CAM_W]usize = undefined;
    var dx: usize = 0;
    while (dx < box_w) : (dx += 1) x_map[dx] = dx * @as(usize, frame.width) / CAM_W;
    var dy: usize = 0;
    while (dy < box_h) : (dy += 1) {
        const sy = dy * @as(usize, frame.height) / CAM_H; // Source y for the row (per-row; not per-pixel)
        const src_base = sy * @as(usize, frame.stride);
        const dst_base = (y0 + dy) * fb_w + x0;
        dx = 0;
        while (dx < box_w) : (dx += 1) pixels[dst_base + dx] = frame.pixels[src_base + x_map[dx]];
    }
}

// ============================================================================
// main
// ============================================================================

pub fn main() !void {
    std.debug.print("20_capture_demo: mic waveform/FFT + camera canvas. ESC to quit.\n", .{});

    const allocator = std.heap.c_allocator;

    var app = try allocator.create(App);
    defer allocator.destroy(app);
    app.* = .{};

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WIN_W, WIN_H, "20_capture_demo - mic viz + camera canvas");
    defer window.destroy();

    // Data-source choice: synthetic only when KNGN_HARNESS_CAPTURE_SYNTHETIC=1 and harness is enabled
    // (harness.isCaptureSyntheticActive() in core/control/harness.zig). Default is production (real backend).
    const synthetic_mode = harness.isCaptureSyntheticActive();
    std.debug.print("[capture_demo] mode={s}\n", .{if (synthetic_mode) "synthetic (headless verification)" else "real (production; requires camera/mic + TCC permission)"});

    app.video = if (synthetic_mode) openSyntheticVideo(allocator) else openRealVideo(allocator);
    defer closeVideoSource(&app.video);

    app.mic = if (synthetic_mode) openSyntheticMic(allocator, app) else openRealMic(allocator, app);
    defer closeMicSource(&app.mic);
    // Spectrogram log-frequency axis uses the effective sample rate (a real mic may settle away from
    // MIC_SAMPLE_RATE via AUHAL hardware negotiation). Call after open, before feed
    // (unopened mic / synthetic stays at the requested MIC_SAMPLE_RATE).
    app.spec.init(@floatFromInt(micSampleRate(app.mic)));

    // Register the headless harness custom probe (no-op when harness is disabled).
    platform.registerProbe(.{ .name = "capture_demo", .ctx = app, .digest = captureDemoDigest });

    var mono_scratch: [4096]f32 = undefined;
    var running = true;

    main_loop: while (running and window.pollEvents()) {
        const frame_t0 = platform.getTime();
        defer platform.framePaceUntil(frame_t0 + FRAME_PERIOD_S);

        const fb = window.lockFramebuffer() orelse continue :main_loop;
        defer fb.unlock();

        while (window.nextEvent()) |ev| {
            switch (ev) {
                .quit => running = false,
                .key_down => |k| if (k.key == .ESCAPE) {
                    running = false;
                },
                else => {},
            }
        }

        // Drain the mic tap → feed oscilloscope / spectrogram / level meter.
        while (true) {
            const n = app.tap.read(&mono_scratch);
            if (n == 0) break;
            app.mic_frames_seen += n;
            app.spec.feed(mono_scratch[0..n]);
            app.osc.feed(mono_scratch[0..n]);
            app.meter.feed(mono_scratch[0..n]);
        }

        // Draw: background → camera region (placeholder or real frame) → mic viz.
        @memset(fb.pixels, BG_COLOR);

        fillRect(fb.pixels, fb.width, fb.height, CAM_X0, CAM_Y0, CAM_W, CAM_H, CAM_EMPTY_COLOR);
        if (pollVideoFrame(&app.video, &app.video_tick)) |frame| {
            drawVideoFrame(fb.pixels, fb.width, fb.height, CAM_X0, CAM_Y0, frame);
            app.video_frames_seen += 1;
        }
        drawBorder(fb.pixels, fb.width, fb.height, CAM_X0, CAM_Y0, CAM_W, CAM_H, BORDER_COLOR);

        app.spec.draw(fb.pixels, fb.width, fb.height, SPEC_X0, SPEC_Y0);
        app.osc.draw(fb.pixels, fb.width, fb.height, SCOPE_X0, SCOPE_Y0);
        app.meter.draw(fb.pixels, fb.width, fb.height, METER_X0, METER_Y0, METER_W, METER_H);

        window.present();
    }
}
