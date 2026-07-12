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

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");

pub fn Runtime(comptime App: type) type {
    return struct {
        const Self = @This();

        /// native: `std.process.Init` を受けて pull ループを所有する。
        /// 既存 pixie と同型: `while (running and pollEvents()) { running = frame(...) }`。
        /// frameDelay は呼ばない（pixie は backend の vsync/poll に委ねており従来同等を保つ）。
        pub fn runNative(process_init: std.process.Init) !void {
            const gpa = process_init.gpa;
            const io = process_init.io;

            try platform.init();
            defer platform.shutdown();

            var win = try platform.Window.create(App.window.w, App.window.h, App.window.title);
            defer win.destroy();

            const app = try App.init(gpa, io);
            defer app.deinit();

            // window 生成後の opt-in 配線点（ライブリサイズ redraw callback 等。TASK-23.1 統合）。
            // native のみ: wasm はモーダルループが無く rAF が回り続けるため不要。
            if (@hasDecl(App, "onWindowReady")) app.onWindowReady(&win);

            var running = true;
            while (running and win.pollEvents()) {
                running = try app.frame(&win, platform.getTime());
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

            const win = platform.Window.create(App.window.w, App.window.h, App.window.title) catch {
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
                app.deinit();
                win.destroy();
                platform.shutdown();
                g_app = null;
                g_win = null;
            }
        }
    };
}
