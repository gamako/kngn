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
//! - `pub const frame_period_s: f64` — the native loop's target period (1/60 by default; `0` disables pacing)

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");

pub fn Runtime(comptime App: type) type {
    return struct {
        const Self = @This();

        /// The target frame period in seconds, 60fps by default. An App holding `pub const frame_period_s: f64` overrides it, and
        /// `0` (or less) disables pacing so the loop runs freely (the deadline lands at or before now, and `framePaceUntil` returns at once).
        /// It applies to the native loop only (wasm is paced by rAF, so it does not pace).
        const frame_period_s: f64 = if (@hasDecl(App, "frame_period_s")) App.frame_period_s else 1.0 / 60.0;

        fn createAppWindow(gpa: std.mem.Allocator, io: std.Io) !platform.Window {
            if (@hasDecl(App, "windowBootstrap")) {
                const opts = try App.windowBootstrap(gpa, io);
                return platform.Window.createWithOptions(App.window.w, App.window.h, App.window.title, opts);
            }
            return platform.Window.create(App.window.w, App.window.h, App.window.title);
        }

        /// native: takes a `std.process.Init` and owns the pull loop.
        /// The same shape as the existing editor: `while (running and pollEvents()) { running = frame(...) }`.
        /// **The runtime owns the frame pacing**: each time round the loop it calls `framePaceUntil(t0 + frame_period_s)` once,
        /// through `defer` (so it waits exactly once even on the path where `app.frame` returns an error or running=false).
        /// The period is `frame_period_s` (60fps by default, overridden by `App.frame_period_s`, and `0` disables pacing).
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
