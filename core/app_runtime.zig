//! Frame-driven application runtime
//!
//! (1) It absorbs the push/pull difference of frame driving in one place. An App provides init, frame and deinit;
//! on native the existing pull loop is confined here, and on wasm it becomes the `kngn_frame` export driven by rAF.
//! (2) Event delivery, (3) the framebuffer and (4) audio all keep their existing paths.
//!
//! The surface an App provides:
//! - `pub const window = .{ .w: u32, .h: u32, .title: [:0]const u8 }`
//! - `pub fn init(gpa: Allocator, io: std.Io) !*App`
//! - `pub fn frame(self: *App, win: *platform.Window, now: f64) bool` (running)
//! - `pub fn deinit(self: *App) void`
//!
//! opt-in:
//! - `pub fn windowBootstrap(gpa, io) !platform.WindowOptions` — after platform.init, before Window.create
//! - `pub fn onWindowShutdown(self: *App, win: *platform.Window) void` — before destroy and before deinit
//! - `pub const frame_period_s: f64` — native-loop period fallback when `-Dframe-cap` is unset
//!   (1/60 by default; `0` disables pacing). Overridden by `-Dframe-cap=<Hz>` when set.
//!
//! **Hot path declaration**: the wait is once per frame (`framePaceUntil`); display refresh is queried
//! once after Window.create (event-time), never inside the frame loop.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");
const build_options = @import("build_options");

pub fn Runtime(comptime App: type) type {
    return struct {
        const Self = @This();

        /// Fallback period from the App (or 1/60). Used only when `-Dframe-cap` is unset.
        const app_frame_period_s: f64 = if (@hasDecl(App, "frame_period_s")) App.frame_period_s else 1.0 / 60.0;

        /// Cap in Hz from `-Dframe-cap`, or derived from `app_frame_period_s` when the option is unset.
        /// `0` disables pacing. wasm ignores this (rAF paces).
        fn resolveCapHz() f64 {
            if (comptime build_options.has_frame_cap) {
                return @floatFromInt(build_options.frame_cap_hz);
            }
            if (!(app_frame_period_s > 0) or !std.math.isFinite(app_frame_period_s)) return 0;
            return 1.0 / app_frame_period_s;
        }

        fn createAppWindow(gpa: std.mem.Allocator, io: std.Io) !platform.Window {
            if (@hasDecl(App, "windowBootstrap")) {
                const opts = try App.windowBootstrap(gpa, io);
                return platform.Window.createWithOptions(App.window.w, App.window.h, App.window.title, opts);
            }
            return platform.Window.create(App.window.w, App.window.h, App.window.title);
        }

        /// Warn once when the cap is not an integer divisor of the display refresh (judder risk).
        fn warnIfNonDivisorCap(refresh_hz: f64, cap_hz: f64) void {
            if (!(cap_hz > 0) or !(refresh_hz > 0)) return;
            if (!(cap_hz < refresh_hz)) return;
            const ratio = refresh_hz / cap_hz;
            const nearest = @round(ratio);
            if (@abs(ratio - nearest) > 0.01) {
                std.log.warn("frame cap {d:.0} Hz is not an integer divisor of display refresh {d:.0} Hz; display intervals may judder", .{ cap_hz, refresh_hz });
            }
        }

        /// native: takes a `std.process.Init` and owns the pull loop.
        /// The same shape as the existing editor: `while (running and pollEvents()) { running = frame(...) }`.
        /// **The runtime owns the frame pacing**: each time round the loop it calls `framePaceUntil(t0 + period_s)` once,
        /// through `defer` (so it waits exactly once even on the path where `app.frame` returns an error or running=false).
        /// The period is `1/min(displayRefreshHz(), cap)` computed once after Window.create (refresh is never queried per frame).
        /// Cap comes from `-Dframe-cap` when set, otherwise from `App.frame_period_s` (default 1/60; `0` disables pacing).
        /// The deadline is based on **the same `t0`** that is passed to `app.frame` as `now`, so there is no double wait.
        /// Under the harness's manual clock (a replay) `framePaceUntil` is a no-op, so replay speed does not drop.
        /// The shutdown order is `onWindowShutdown → App.deinit → Window.destroy`.
        pub fn runNative(process_init: std.process.Init) !void {
            const gpa = process_init.gpa;
            const io = process_init.io;

            try platform.init();
            defer platform.shutdown();

            var win = try createAppWindow(gpa, io);
            defer win.destroy();

            // Event-time: query refresh once after the window exists; never again in the frame loop.
            const refresh_hz = platform.displayRefreshHz();
            const cap_hz = resolveCapHz();
            const frame_period_s = platform.targetPeriodS(refresh_hz, cap_hz);
            // One line, once per process: the pacing target is otherwise invisible, and a measured
            // frame rate cannot be judged without knowing which refresh the run resolved (a machine
            // with an adaptive-refresh or multi-display setup does not always report the same value).
            std.log.info("frame pacing: display refresh {d:.0} Hz, cap {d:.0} Hz, period {d:.2} ms", .{
                refresh_hz,
                cap_hz,
                frame_period_s * 1000.0,
            });
            warnIfNonDivisorCap(refresh_hz, cap_hz);

            const app = try App.init(gpa, io);
            defer app.deinit();
            defer if (@hasDecl(App, "onWindowShutdown")) app.onWindowShutdown(&win);

            // The opt-in wiring point once the window exists (a live-resize redraw callback, say).
            // native only: wasm has no modal loop and rAF keeps running, so it is unnecessary.
            if (@hasDecl(App, "onWindowReady")) app.onWindowReady(&win);

            var running = true;
            while (running and win.pollEvents()) {
                // The frame's starting point. The same value is used for `app.frame`'s `now` and for the pacing deadline.
                const t0 = platform.getTime();
                defer platform.framePaceUntil(t0 + frame_period_s);
                running = try app.frame(&win, t0);
            }
        }

        // ------------------------------------------------------------------
        // wasm: hold it globally, plus the export
        // ------------------------------------------------------------------

        var g_app: ?*App = null;
        var g_win: ?platform.Window = null;
        var g_running: bool = false;

        /// Referencing it from the wasm root brings the export into the analysis.
        pub fn enableWasmExports() void {
            if (!builtin.cpu.arch.isWasm()) return;
            _ = &kngn_init;
            _ = &kngn_frame;
            _ = &kngn_declared_window_w;
            _ = &kngn_declared_window_h;
        }

        /// `App.window.w`/`.h`, read by the JS glue right after instantiation, before it starts
        /// observing the canvas's CSS box. A canvas has no OS window to size, so the glue uses
        /// these to seed the canvas's intrinsic `width`/`height` attribute — but only when the
        /// host page left both attributes unset, so an author's own explicit markup is never
        /// overridden. This is not a one-frame default: a canvas with no CSS box renders at its
        /// intrinsic attribute size, so absent a CSS override this value holds for the whole run
        /// (the same "current box is truth" model native uses once a window is resized, just
        /// with nothing here to trigger a change). The moment the page's CSS gives the canvas an
        /// explicit box, that box wins instead, continuously, from the next resize report on.
        /// The raw `App.window` value returned here is not clamped to `[320, 8192]` — the wasm
        /// backend's `Window.createWithOptions` applies that clamp itself when it allocates the
        /// framebuffer, so a declared size outside that range still ends up with a consistent,
        /// clamped framebuffer rather than a one-frame mismatch.
        ///
        /// Known gap: an app whose `windowBootstrap` returns a `WindowOptions.size` that
        /// differs from `App.window` on wasm will still have the canvas seeded from the
        /// declared `App.window` value, not the effective size `createWithOptions` ends up
        /// using — computing the effective size would mean running `windowBootstrap` before
        /// the JS glue can prime the canvas, which is not how boot is sequenced today. None of
        /// the in-tree wasm apps hit this (pixie's `windowBootstrap` always falls back to
        /// `App.window`'s own constants on wasm; synth and the template have no
        /// `windowBootstrap` at all).
        export fn kngn_declared_window_w() u32 {
            if (!builtin.cpu.arch.isWasm()) return 0;
            return App.window.w;
        }

        export fn kngn_declared_window_h() u32 {
            if (!builtin.cpu.arch.isWasm()) return 0;
            return App.window.h;
        }

        export fn kngn_init() void {
            if (!builtin.cpu.arch.isWasm()) return;
            const gpa = std.heap.wasm_allocator;
            // A real std.Io coming from Io.Threaded's single-threaded global
            // (consistent with the debug_io default singleton; it spawns no thread and does synchronous I/O).
            const io = std.Io.Threaded.global_single_threaded.io();

            platform.init() catch {
                const msg = "kngn_init: platform.init failed";
                const env = struct {
                    extern "env" fn kngn_log(ptr: [*]const u8, len: u32) void;
                };
                env.kngn_log(msg, msg.len);
                return;
            };

            const win = createAppWindow(gpa, io) catch {
                const msg = "kngn_init: Window.create failed";
                const env = struct {
                    extern "env" fn kngn_log(ptr: [*]const u8, len: u32) void;
                };
                env.kngn_log(msg, msg.len);
                platform.shutdown();
                return;
            };
            g_win = win;

            const app_ptr = App.init(gpa, io) catch {
                const msg = "kngn_init: App.init failed";
                const env = struct {
                    extern "env" fn kngn_log(ptr: [*]const u8, len: u32) void;
                };
                env.kngn_log(msg, msg.len);
                // symmetrical with the native path's defer window.destroy and platform.shutdown
                win.destroy();
                g_win = null;
                platform.shutdown();
                return;
            };
            g_app = app_ptr;
            g_running = true;
        }

        export fn kngn_frame(now_ms: f64) void {
            if (!builtin.cpu.arch.isWasm()) return;
            const app = g_app orelse return;
            var win = g_win orelse return;
            if (!g_running) return;
            const now_sec = now_ms / 1000.0;
            _ = win.pollEvents();
            g_running = app.frame(&win, now_sec) catch false;
            if (!g_running) {
                if (@hasDecl(App, "onWindowShutdown")) app.onWindowShutdown(&win);
                app.deinit();
                win.destroy();
                platform.shutdown();
                g_app = null;
                g_win = null;
            }
        }
    };
}
