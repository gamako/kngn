//! Frame-driven application runtime（TASK-73）
//!
//! ①フレーム駆動の push/pull 差を 1 箇所で吸収する。App は init/frame/deinit を提供し、
//! native では既存 pull ループをここに閉じ込め、wasm では rAF 経由の `vp_frame` export になる。
//! ②イベント配送 / ③FB / ④audio は経路不変。
//!
//! App が提供する面:
//! - `pub const window = .{ .w: u32, .h: u32, .title: [:0]const u8 }`
//! - `pub fn init(gpa: Allocator, io: std.Io) !*App`
//! - `pub fn frame(self: *App, win: *platform.Window, now: f64) bool`（running）
//! - `pub fn deinit(self: *App) void`
//!
//! opt-in（TASK-117）:
//! - `pub fn windowBootstrap(gpa, io) !platform.WindowOptions` — platform.init 後・Window.create 前
//! - `pub fn onWindowShutdown(self: *App, win: *platform.Window) void` — destroy 前・deinit 前
//! - `pub const frame_period_s: f64` — native ループの目標周期（既定 1/60。`0` で pacing 無効。TASK-180）

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");

pub fn Runtime(comptime App: type) type {
    return struct {
        const Self = @This();

        /// 目標フレーム周期（秒）。既定 60fps。App が `pub const frame_period_s: f64` を持てば上書きし、
        /// `0`（以下）なら pacing 無効＝自走（deadline が現在時刻以前になり `framePaceUntil` が即 return する）。
        /// native ループのみに効く（wasm は rAF 律速なので pacing しない）。
        const frame_period_s: f64 = if (@hasDecl(App, "frame_period_s")) App.frame_period_s else 1.0 / 60.0;

        fn createAppWindow(gpa: std.mem.Allocator, io: std.Io) !platform.Window {
            if (@hasDecl(App, "windowBootstrap")) {
                const opts = try App.windowBootstrap(gpa, io);
                return platform.Window.createWithOptions(App.window.w, App.window.h, App.window.title, opts);
            }
            return platform.Window.create(App.window.w, App.window.h, App.window.title);
        }

        /// native: `std.process.Init` を受けて pull ループを所有する。
        /// 既存 pixie と同型: `while (running and pollEvents()) { running = frame(...) }`。
        /// **frame pacing は runtime が所有する**（TASK-180）: 各周回で `framePaceUntil(t0 + frame_period_s)` を
        /// `defer` で 1 回呼ぶ（`app.frame` が error / running=false を返した経路でも 1 回だけ待つ）。
        /// 周期は `frame_period_s`（既定 60fps。`App.frame_period_s` で上書き・`0` で pacing 無効）。
        /// deadline の基準は `app.frame` へ渡す `now` と**同一の `t0`**（二重待ちにならない）。
        /// harness の manual clock（replay）では `framePaceUntil` が no-op なので replay 速度は落ちない。
        /// shutdown 順序は `onWindowShutdown → App.deinit → Window.destroy`（TASK-117）。
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

            // window 生成後の opt-in 配線点（ライブリサイズ redraw callback 等。TASK-23.1 統合）。
            // native のみ: wasm はモーダルループが無く rAF が回り続けるため不要。
            if (@hasDecl(App, "onWindowReady")) app.onWindowReady(&win);

            var running = true;
            while (running and win.pollEvents()) {
                // フレーム起点。`app.frame` の `now` と pacing の deadline で同じ値を使う。
                const t0 = platform.getTime();
                defer platform.framePaceUntil(t0 + frame_period_s);
                running = try app.frame(&win, t0);
            }
        }

        // ------------------------------------------------------------------
        // wasm: グローバル保持 + export
        // ------------------------------------------------------------------

        var g_app: ?*App = null;
        var g_win: ?platform.Window = null;
        var g_running: bool = false;

        /// wasm root が参照することで export を解析対象に載せる。
        pub fn enableWasmExports() void {
            if (!builtin.cpu.arch.isWasm()) return;
            _ = &vp_init;
            _ = &vp_frame;
        }

        export fn vp_init() void {
            if (!builtin.cpu.arch.isWasm()) return;
            const gpa = std.heap.wasm_allocator;
            // H1: wasi 改訂 — Io.Threaded single-threaded global 由来の実 std.Io
            // （debug_io 既定 singleton と整合。thread spawn しない同期 I/O）。
            const io = std.Io.Threaded.global_single_threaded.io();

            platform.init() catch {
                const msg = "vp_init: platform.init failed";
                const env = struct {
                    extern "env" fn vp_log(ptr: [*]const u8, len: u32) void;
                };
                env.vp_log(msg, msg.len);
                return;
            };

            const win = createAppWindow(gpa, io) catch {
                const msg = "vp_init: Window.create failed";
                const env = struct {
                    extern "env" fn vp_log(ptr: [*]const u8, len: u32) void;
                };
                env.vp_log(msg, msg.len);
                platform.shutdown();
                return;
            };
            g_win = win;

            const app_ptr = App.init(gpa, io) catch {
                const msg = "vp_init: App.init failed";
                const env = struct {
                    extern "env" fn vp_log(ptr: [*]const u8, len: u32) void;
                };
                env.vp_log(msg, msg.len);
                // native 経路の defer window.destroy / platform.shutdown と対称
                win.destroy();
                g_win = null;
                platform.shutdown();
                return;
            };
            g_app = app_ptr;
            g_running = true;
        }

        export fn vp_frame(now_ms: f64) void {
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
