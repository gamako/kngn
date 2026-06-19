//! Linux platform backend — Wayland 実装（display MVP。TASK-28.5.1 土台 / 28.5.2 表示）
//!
//! `src/platform_linux.zig`（dispatcher）が `build_options.platform_backend == "wayland"` のとき選ぶ。
//!
//! ソフトウェアフレームバッファ方式。caller は canonical BGRA `[]u32`（u32 0xAARRGGBB /
//! メモリ [B,G,R,A]）を書く。これは little-endian host 上で Wayland の XRGB8888 と byte layout が
//! 一致するため、**毎フレーム変換コピー無しで shm buffer に直書き**できる（lockFramebuffer が
//! shm buffer の pixels を直接返す）。XRGB8888 第一候補 / ARGB8888 fallback。
//!
//! 公開契約（caller 駆動 poll→present、vsync 待ち無し）は X11 と同一。present は即時
//! attach+damage+commit。`wl_surface.frame` callback は内部 pacing のみに消費し、アプリ loop
//! 駆動には使わない（frame_pending ガードで多重登録しない）。`wl_buffer.release` で busy を解除する
//! ダブルバッファで、両 buffer busy 時は lockFramebuffer が null を返し caller が skip する。
//!
//! 入力（keyboard/mouse/scroll）は TASK-28.5.3、pixie/dialog は 28.5.4。本ファイルは quit のみ扱う。
//! 設計の正は docs/plans/28.5-plan.md §2/§3.2/§3.4-3.6。
//!
//! C-interop 規約: wayland/xdg/xkb ヘッダは bare struct（typedef 無し）のため、型は
//! `c.struct_wl_*`/`c.struct_xdg_*`、関数/enum 定数は C 名そのまま（`c.wl_*`/`c.WL_SHM_FORMAT_*`）。
//! 最終的な field 型・nullable・listener signature は shiso の compile で確定する（macOS では
//! Linux 専用 @cImport のため本ファイルはコンパイルされない）。

const std = @import("std");
const types = @import("platform_types.zig");
const input = @import("platform_linux_input.zig");
const common = @import("platform_linux_common.zig");
const build_options = @import("build_options");

const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xdg-shell-client-protocol.h");
});

const Error = types.Error;
const Event = types.Event;
const EventStats = types.EventStats;

comptime {
    if (!std.mem.eql(u8, build_options.platform_backend, "wayland")) {
        @compileError("platform_linux_wayland: backend '" ++ build_options.platform_backend ++
            "' で Wayland 実装が import された（dispatcher は wayland のときだけ選ぶはず）");
    }
}

// getTime / ファイルダイアログ（display 非依存）は common に分離し re-export（X11 と同じ）。
pub const getTime = common.getTime;
pub const saveFileDialog = common.saveFileDialog;
pub const openFileDialog = common.openFileDialog;

const alloc = std.heap.c_allocator;

// ============================================================================
// POSIX syscalls（libc。link_libc 済み）。X11 backend の extern 宣言方針に倣う。
// 値は Linux x86_64/aarch64 共通の安定値。
// ============================================================================
extern fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;
extern fn ftruncate(fd: c_int, length: c_long) c_int;
extern fn mmap(addr: ?*anyopaque, length: usize, prot: c_int, flags: c_int, fd: c_int, offset: c_long) ?*anyopaque;
extern fn munmap(addr: ?*anyopaque, length: usize) c_int;
extern fn close(fd: c_int) c_int;

const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short };
extern fn poll(fds: [*]PollFd, nfds: c_ulong, timeout: c_int) c_int;

const MFD_CLOEXEC: c_uint = 0x0001;
const PROT_READ: c_int = 0x1;
const PROT_WRITE: c_int = 0x2;
const MAP_SHARED: c_int = 0x1;
const POLLIN: c_short = 0x001;
const POLLERR: c_short = 0x008;
const POLLHUP: c_short = 0x010;
const MAP_FAILED_INT: usize = @bitCast(@as(isize, -1));

// wl_shm format（protocol 上 uint32_t）。translate-c の enum 定数は c_int なので u32 へ揃える。
const FMT_XRGB8888: u32 = @intCast(c.WL_SHM_FORMAT_XRGB8888);
const FMT_ARGB8888: u32 = @intCast(c.WL_SHM_FORMAT_ARGB8888);

// ============================================================================
// init / shutdown（プロセス単一の Display）
// ============================================================================
var g_display: ?*c.struct_wl_display = null;

pub fn init() Error!void {
    if (g_display != null) return;
    g_display = c.wl_display_connect(null) orelse return error.InitFailed;
}

pub fn shutdown() void {
    if (g_display) |d| {
        c.wl_display_disconnect(d);
        g_display = null;
    }
}

// ============================================================================
// shm buffer / State
// ============================================================================

const ShmBuffer = struct {
    fd: c_int = -1,
    map_ptr: ?*anyopaque = null,
    map_size: usize = 0,
    buffer: ?*c.struct_wl_buffer = null,
    pixels: []u32 = &.{},
    busy: bool = false,
};

const State = struct {
    display: *c.struct_wl_display,
    registry: ?*c.struct_wl_registry = null,
    compositor: ?*c.struct_wl_compositor = null,
    shm: ?*c.struct_wl_shm = null,
    wm_base: ?*c.struct_xdg_wm_base = null,
    surface: ?*c.struct_wl_surface = null,
    xdg_surface: ?*c.struct_xdg_surface = null,
    toplevel: ?*c.struct_xdg_toplevel = null,

    width: u32,
    height: u32,
    compositor_version: u32 = 1,

    // shm format negotiation
    has_xrgb8888: bool = false,
    has_argb8888: bool = false,
    shm_format: u32 = 0,

    configured: bool = false,
    closing: bool = false,
    quit_delivered: bool = false,
    quit_enqueued: bool = false,
    queue: input.EventQueue = .{},

    buffers: [2]ShmBuffer = .{ .{}, .{} },
    locked_index: ?usize = null,

    frame_callback: ?*c.struct_wl_callback = null,
    frame_pending: bool = false,

    fn enqueueQuit(self: *State) void {
        if (self.quit_enqueued) return;
        self.quit_enqueued = true;
        self.closing = true;
        self.queue.enqueue(.quit);
    }

    /// connection error 等の異常系: .quit を 1 回積んで pollEvents の戻り値を返す。
    fn fail(self: *State) bool {
        self.enqueueQuit();
        return !self.quit_delivered;
    }
};

// ============================================================================
// listeners（静的 lifetime。data ポインタで State/ShmBuffer を受ける）
// version 依存の追加 field（xdg_toplevel の configure_bounds/wm_capabilities 等）に備え
// std.mem.zeroInit で全 field を null 初期化してから必要 handler だけ設定する。
// ============================================================================

fn registryGlobal(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32, iface: [*c]const u8, version: u32) callconv(.c) void {
    const st: *State = @ptrCast(@alignCast(data.?));
    const ifn = std.mem.span(iface);
    if (std.mem.eql(u8, ifn, "wl_compositor")) {
        const v = @min(version, 4);
        st.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, v));
        st.compositor_version = v;
    } else if (std.mem.eql(u8, ifn, "wl_shm")) {
        st.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
        if (st.shm) |shm| _ = c.wl_shm_add_listener(shm, &shm_listener, st);
    } else if (std.mem.eql(u8, ifn, "xdg_wm_base")) {
        st.wm_base = @ptrCast(c.wl_registry_bind(registry, name, &c.xdg_wm_base_interface, 1));
        if (st.wm_base) |wm| _ = c.xdg_wm_base_add_listener(wm, &wm_base_listener, st);
    }
    // wl_seat（入力）は TASK-28.5.3 で listener と共に bind する。
}

fn registryGlobalRemove(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = name; // MVP: globals の動的削除には対応しない
}

fn shmFormat(data: ?*anyopaque, shm: ?*c.struct_wl_shm, format: u32) callconv(.c) void {
    _ = shm;
    const st: *State = @ptrCast(@alignCast(data.?));
    if (format == FMT_XRGB8888) st.has_xrgb8888 = true;
    if (format == FMT_ARGB8888) st.has_argb8888 = true;
}

fn wmBasePing(data: ?*anyopaque, wm_base: ?*c.struct_xdg_wm_base, serial: u32) callconv(.c) void {
    _ = data;
    c.xdg_wm_base_pong(wm_base, serial);
}

fn xdgSurfaceConfigure(data: ?*anyopaque, xdg_surface: ?*c.struct_xdg_surface, serial: u32) callconv(.c) void {
    const st: *State = @ptrCast(@alignCast(data.?));
    c.xdg_surface_ack_configure(xdg_surface, serial);
    st.configured = true;
}

fn toplevelConfigure(data: ?*anyopaque, toplevel: ?*c.struct_xdg_toplevel, width: i32, height: i32, states: ?*c.struct_wl_array) callconv(.c) void {
    _ = data;
    _ = toplevel;
    _ = width;
    _ = height;
    _ = states; // 固定サイズ運用（resize 非対応）。suggested size は無視する。
}

fn toplevelClose(data: ?*anyopaque, toplevel: ?*c.struct_xdg_toplevel) callconv(.c) void {
    _ = toplevel;
    const st: *State = @ptrCast(@alignCast(data.?));
    st.enqueueQuit();
}

fn bufferRelease(data: ?*anyopaque, buffer: ?*c.struct_wl_buffer) callconv(.c) void {
    _ = buffer;
    const buf: *ShmBuffer = @ptrCast(@alignCast(data.?));
    buf.busy = false;
}

fn frameDone(data: ?*anyopaque, cb: ?*c.struct_wl_callback, time: u32) callconv(.c) void {
    _ = time;
    const st: *State = @ptrCast(@alignCast(data.?));
    if (cb) |callback| c.wl_callback_destroy(callback);
    st.frame_callback = null;
    st.frame_pending = false;
}

const registry_listener = std.mem.zeroInit(c.struct_wl_registry_listener, .{
    .global = &registryGlobal,
    .global_remove = &registryGlobalRemove,
});
const shm_listener = std.mem.zeroInit(c.struct_wl_shm_listener, .{ .format = &shmFormat });
const wm_base_listener = std.mem.zeroInit(c.struct_xdg_wm_base_listener, .{ .ping = &wmBasePing });
const xdg_surface_listener = std.mem.zeroInit(c.struct_xdg_surface_listener, .{ .configure = &xdgSurfaceConfigure });
const toplevel_listener = std.mem.zeroInit(c.struct_xdg_toplevel_listener, .{
    .configure = &toplevelConfigure,
    .close = &toplevelClose,
});
const buffer_listener = std.mem.zeroInit(c.struct_wl_buffer_listener, .{ .release = &bufferRelease });
const frame_listener = std.mem.zeroInit(c.struct_wl_callback_listener, .{ .done = &frameDone });

// ============================================================================
// Window / Framebuffer
// ============================================================================

pub const Window = struct {
    state: *State,

    pub fn create(width: u32, height: u32, title: [:0]const u8) Error!Window {
        const dpy = g_display orelse return error.WindowCreationFailed;
        if (width == 0 or height == 0) return error.WindowCreationFailed;

        const st = alloc.create(State) catch return error.WindowCreationFailed;
        st.* = .{ .display = dpy, .width = width, .height = height };
        errdefer {
            teardown(st);
            alloc.destroy(st);
        }

        // registry → globals bind（global handler 内で shm/wm_base listener も登録）。
        st.registry = c.wl_display_get_registry(dpy) orelse return error.WindowCreationFailed;
        _ = c.wl_registry_add_listener(st.registry, &registry_listener, st);
        // 1 回目: globals bind。2 回目: bind 後に届く wl_shm.format を収集。
        if (c.wl_display_roundtrip(dpy) < 0) return error.WindowCreationFailed;
        if (c.wl_display_roundtrip(dpy) < 0) return error.WindowCreationFailed;

        if (st.compositor == null or st.shm == null or st.wm_base == null) return error.WindowCreationFailed;

        // shm format 選択（XRGB8888 優先、無ければ ARGB8888、どちらも無ければ失敗）。
        if (st.has_xrgb8888) {
            st.shm_format = FMT_XRGB8888;
        } else if (st.has_argb8888) {
            st.shm_format = FMT_ARGB8888;
        } else {
            return error.WindowCreationFailed;
        }

        // surface → xdg_surface → toplevel。
        st.surface = c.wl_compositor_create_surface(st.compositor) orelse return error.WindowCreationFailed;
        st.xdg_surface = c.xdg_wm_base_get_xdg_surface(st.wm_base, st.surface) orelse return error.WindowCreationFailed;
        _ = c.xdg_surface_add_listener(st.xdg_surface, &xdg_surface_listener, st);
        st.toplevel = c.xdg_surface_get_toplevel(st.xdg_surface) orelse return error.WindowCreationFailed;
        _ = c.xdg_toplevel_add_listener(st.toplevel, &toplevel_listener, st);
        c.xdg_toplevel_set_title(st.toplevel, title.ptr);

        // 初回 commit は buffer を attach しない（初回 xdg_surface.configure を誘発）。
        c.wl_surface_commit(st.surface);
        while (!st.configured) {
            if (c.wl_display_dispatch(dpy) < 0) return error.WindowCreationFailed;
        }

        // configure 後に shm ダブルバッファを確保。
        try setupBuffers(st);

        return .{ .state = st };
    }

    pub fn destroy(self: Window) void {
        const st = self.state;
        teardown(st);
        alloc.destroy(st);
    }

    pub fn pollEvents(self: Window) bool {
        const st = self.state;
        const dpy = st.display;

        // 既に queue にある分を dispatch。失敗は connection error とみなし quit 化。
        if (c.wl_display_dispatch_pending(dpy) < 0) return st.fail();

        // non-blocking に新着 event を読む（X11 の while(XPending) 相当）。
        // prepare_read が !=0 を返す間は未処理 event があるので dispatch して再試行。
        // prepare_read が 0 を返した後は、read_events か cancel_read のどちらかを必ず 1 回呼ぶ。
        while (c.wl_display_prepare_read(dpy) != 0) {
            if (c.wl_display_dispatch_pending(dpy) < 0) return st.fail();
        }
        // flush 失敗は EAGAIN（送信 buffer 飽和）等で必ずしも致命的でないため継続し、
        // 切断は下の POLLHUP/POLLERR と read_events 失敗で検知する。
        _ = c.wl_display_flush(dpy);

        var pfd = [1]PollFd{.{ .fd = c.wl_display_get_fd(dpy), .events = POLLIN, .revents = 0 }};
        const n = poll(&pfd, 1, 0);
        const re = pfd[0].revents;
        if (n < 0) {
            // poll 自体の失敗（EINTR 等）。read を解除して継続。
            c.wl_display_cancel_read(dpy);
            return !st.quit_delivered;
        }
        if ((re & (POLLERR | POLLHUP)) != 0) {
            // compositor 切断。read は試みず cancel して quit。
            c.wl_display_cancel_read(dpy);
            return st.fail();
        }
        if (n > 0 and (re & POLLIN) != 0) {
            if (c.wl_display_read_events(dpy) < 0) return st.fail();
        } else {
            c.wl_display_cancel_read(dpy);
        }
        if (c.wl_display_dispatch_pending(dpy) < 0) return st.fail();

        return !st.quit_delivered;
    }

    pub fn nextEvent(self: Window) ?Event {
        const st = self.state;
        const ev = st.queue.dequeue() orelse return null;
        if (ev == .quit) st.quit_delivered = true;
        return ev;
    }

    pub fn getEventStats(self: Window) EventStats {
        const q = &self.state.queue;
        return .{
            .mouse_move_merge_count = q.mouse_move_merge_count,
            .mouse_scroll_merge_count = q.mouse_scroll_merge_count,
            .event_drop_count = q.event_drop_count,
        };
    }

    pub fn lockFramebuffer(self: Window) ?Framebuffer {
        const st = self.state;
        if (!st.configured or st.closing or st.locked_index != null) return null;

        if (freeBufferIndex(st)) |i| return lockAt(st, i);

        // 両 buffer busy: release を取りこぼしていないか軽く dispatch して再試行（ブロックしない）。
        _ = c.wl_display_dispatch_pending(st.display);
        _ = c.wl_display_flush(st.display);
        if (freeBufferIndex(st)) |i| return lockAt(st, i);
        return null;
    }

    pub fn present(self: Window) void {
        const st = self.state;
        if (!st.configured or st.closing) return;
        const i = st.locked_index orelse return;
        const buf = &st.buffers[i];
        const surface = st.surface.?;
        const w: i32 = @intCast(st.width);
        const h: i32 = @intCast(st.height);

        c.wl_surface_attach(surface, buf.buffer, 0, 0);
        // damage_buffer は wl_surface v4+。古い compositor では wl_surface_damage に fallback。
        if (st.compositor_version >= 4) {
            c.wl_surface_damage_buffer(surface, 0, 0, w, h);
        } else {
            c.wl_surface_damage(surface, 0, 0, w, h);
        }

        // frame callback は内部 pacing のみ。pending 中は多重登録しない（callback リーク防止）。
        if (!st.frame_pending) {
            if (c.wl_surface_frame(surface)) |cb| {
                _ = c.wl_callback_add_listener(cb, &frame_listener, st);
                st.frame_callback = cb;
                st.frame_pending = true;
            }
        }

        c.wl_surface_commit(surface);
        _ = c.wl_display_flush(st.display);

        buf.busy = true;
        st.locked_index = null;
    }
};

/// Locked framebuffer view（公開 contract は canonical BGRA `[]u32`、u32 0xAARRGGBB）。
/// pixels は shm buffer を直接指す（present で変換コピーされない）。
pub const Framebuffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    state: *State,

    pub fn unlock(self: Framebuffer) void {
        _ = self; // present 時に commit するので unlock 自体は no-op
    }
};

// ============================================================================
// 内部ヘルパー
// ============================================================================

fn freeBufferIndex(st: *State) ?usize {
    for (&st.buffers, 0..) |*b, i| {
        if (!b.busy and b.buffer != null) return i;
    }
    return null;
}

fn lockAt(st: *State, i: usize) Framebuffer {
    st.locked_index = i;
    return .{
        .pixels = st.buffers[i].pixels,
        .width = st.width,
        .height = st.height,
        .state = st,
    };
}

/// shm ダブルバッファ確保。各 buffer は独立した memfd + mmap + pool（pool は buffer 作成後 destroy）。
fn setupBuffers(st: *State) Error!void {
    const stride = std.math.mul(usize, st.width, 4) catch return error.WindowCreationFailed;
    const size = std.math.mul(usize, stride, st.height) catch return error.WindowCreationFailed;
    for (&st.buffers) |*b| {
        try setupOneBuffer(st, b, stride, size);
    }
}

fn setupOneBuffer(st: *State, b: *ShmBuffer, stride: usize, size: usize) Error!void {
    const fd = memfd_create("video-proto-wayland", MFD_CLOEXEC);
    if (fd < 0) return error.WindowCreationFailed;
    errdefer _ = close(fd);
    if (ftruncate(fd, @intCast(size)) != 0) return error.WindowCreationFailed;

    const raw = mmap(null, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) orelse return error.WindowCreationFailed;
    if (@intFromPtr(raw) == MAP_FAILED_INT) return error.WindowCreationFailed;
    errdefer _ = munmap(raw, size);

    const pool = c.wl_shm_create_pool(st.shm, fd, @intCast(size)) orelse return error.WindowCreationFailed;
    const wl_buf = c.wl_shm_pool_create_buffer(
        pool,
        0,
        @intCast(st.width),
        @intCast(st.height),
        @intCast(stride),
        st.shm_format,
    ) orelse {
        c.wl_shm_pool_destroy(pool);
        return error.WindowCreationFailed;
    };
    c.wl_shm_pool_destroy(pool); // pool は buffer 作成後に不要（fd/mmap は保持）

    _ = c.wl_buffer_add_listener(wl_buf, &buffer_listener, b);

    const px: [*]u32 = @ptrCast(@alignCast(raw));
    b.fd = fd;
    b.map_ptr = raw;
    b.map_size = size;
    b.buffer = wl_buf;
    b.pixels = px[0 .. st.width * st.height];
    b.busy = false;
}

/// 確保済みリソースを null-check しつつ解放。create の errdefer と destroy で共用。
fn teardown(st: *State) void {
    if (st.frame_callback) |cb| {
        c.wl_callback_destroy(cb);
        st.frame_callback = null;
    }
    for (&st.buffers) |*b| {
        if (b.buffer) |wl_buf| c.wl_buffer_destroy(wl_buf);
        if (b.map_ptr) |p| _ = munmap(p, b.map_size);
        if (b.fd >= 0) _ = close(b.fd);
        b.* = .{};
    }
    if (st.toplevel) |t| c.xdg_toplevel_destroy(t);
    if (st.xdg_surface) |x| c.xdg_surface_destroy(x);
    if (st.surface) |s| c.wl_surface_destroy(s);
    if (st.wm_base) |w| c.xdg_wm_base_destroy(w);
    if (st.shm) |s| c.wl_shm_destroy(s);
    if (st.compositor) |co| c.wl_compositor_destroy(co);
    if (st.registry) |r| c.wl_registry_destroy(r);
    st.toplevel = null;
    st.xdg_surface = null;
    st.surface = null;
    st.wm_base = null;
    st.shm = null;
    st.compositor = null;
    st.registry = null;
}
