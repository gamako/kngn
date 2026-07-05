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
const types = @import("platform_types");
const input = @import("platform_linux_input.zig");
const wlinput = @import("platform_wayland_input.zig");
const common = @import("platform_linux_common.zig");
const build_options = @import("build_options");

const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-cursor.h"); // TASK-75.3: system cursor（wl_cursor_theme / set_cursor 用 buffer）
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("xdg-decoration-unstable-v1-client-protocol.h"); // TASK-28.5.6: SSD 要求 / CSD fallback
});

const csd = @import("platform_wayland_csd.zig"); // 装飾の純ロジック（レイアウト/ヒットテスト/描画）

const Error = types.Error;
const Event = types.Event;
const EventStats = types.EventStats;
const MouseButton = types.MouseButton;
const MouseButtons = types.MouseButtons;
const ModifierFlags = types.ModifierFlags;

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
const MAP_PRIVATE: c_int = 0x2; // keymap fd の mmap 用（読み取り専用 private）
const POLLIN: c_short = 0x001;

// wl_seat capability bits / keymap format
const WL_SEAT_CAP_POINTER: u32 = 1;
const WL_SEAT_CAP_KEYBOARD: u32 = 2;

// frame callback 律速の floor 秒。直近 present の wl_surface.frame done が来るまで lockFramebuffer は
// null を返して vsync に律速するが、callback を取りこぼしても固まらないようこの秒数で強制再開する
// （= 最低描画レート ~1/frame_timeout_secs。sleep 無し busy loop の caller の commit flood を防ぐ）。
const frame_timeout_secs: f64 = 0.1;
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
    // この buffer 実体の割り当てサイズ（TASK-23 resize。st.width/height と不一致なら lock 時に再確保）。
    bw: u32 = 0,
    bh: u32 = 0,
};

// ---- CSD（client-side decoration。TASK-28.5.6 Stage 2b） ----

/// pointer focus 対象（ptrEnter の surface 引数で追跡）。content=本体 / deco=装飾 subsurface / other=不明。
/// 装飾上のイベント（motion/button/axis/frame）はアプリ EventQueue に流さず装飾操作へ振り分ける。
const PtrFocus = union(enum) {
    content,
    deco: csd.DecoPart,
    other,
};

/// CSD 装飾 1 枚（4 枚: title/left/right/bottom）。各自 wl_surface + wl_subsurface + 単一 shm buffer。
/// buf は content と同型 ShmBuffer を流用（buffer_listener で release→busy=false を受ける）。
const CsdSurface = struct {
    part: csd.DecoPart,
    surface: ?*c.struct_wl_surface = null,
    subsurface: ?*c.struct_wl_subsurface = null,
    buf: ShmBuffer = .{},
    // 現在 buffer を attach して表示中か。empty(maximized 枠)で attach null すると false。
    // unmap→remap 時に busy-skip で再 attach を取りこぼさないための状態（codex 指摘 #1）。
    mapped: bool = false,
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

    // ウィンドウ装飾（TASK-28.5.6）: SSD 要求 → 不可なら CSD 自前描画。
    subcompositor: ?*c.struct_wl_subcompositor = null, // CSD subsurface 用（Stage 2b）
    deco_manager: ?*c.struct_zxdg_decoration_manager_v1 = null,
    deco_manager_version: u32 = 1,
    deco_obj: ?*c.struct_zxdg_toplevel_decoration_v1 = null,
    // pending: mode 未確定 / ssd: compositor 描画 / csd: 自前描画 / none: 装飾なし（manager/subcompositor 不在）
    deco_state: enum { pending, ssd, csd, none } = .pending,
    // decoration.configure(mode) は即時適用せず latch し、xdg_surface.configure(ack) で反映（既存 pending_resize と同型）。
    // 0=未受信 / 1=client_side / 2=server_side。
    pending_decoration_mode: u32 = 0,
    maximized: bool = false, // toplevel states の maximized/tiled（CSD 枠折り畳み判定）
    pending_maximized: bool = false, // toplevelConfigure が states から latch し ack で maximized へ反映
    // CSD subsurface 群（deco_state==.csd のときのみ構築）。順序固定: 0=title/1=left/2=right/3=bottom。
    csd_surfaces: [4]CsdSurface = .{
        .{ .part = .title }, .{ .part = .left }, .{ .part = .right }, .{ .part = .bottom },
    },
    csd_built: bool = false,
    // pointer focus 追跡（装飾イベントの振り分け）。deco 中は deco_local_x/y に part-local 座標を保持。
    ptr_focus: PtrFocus = .content,
    deco_local_x: i32 = 0,
    deco_local_y: i32 = 0,
    hover_button: csd.Button = .none, // title バーの hover ボタン（変化時のみ再描画）

    // 入力（TASK-28.5.3）
    seat: ?*c.struct_wl_seat = null,
    keyboard: ?*c.struct_wl_keyboard = null,
    pointer: ?*c.struct_wl_pointer = null,
    xkb_context: ?*c.struct_xkb_context = null,
    xkb_keymap: ?*c.struct_xkb_keymap = null,
    xkb_state: ?*c.struct_xkb_state = null,
    keys: input.KeyDownSet = .{}, // keycode は X keycode 系（evdev+8）で揃える
    buttons: MouseButtons = .{}, // post-state（押下中のボタン集合）
    modifiers: ModifierFlags = .{}, // xkb modifier の現在値
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
    repeat: wlinput.RepeatState = .{},

    // system cursor（TASK-75.3）: theme/surface は遅延構築。content focus 中の enter serial を保持し、
    // setCursor / ptrEnter(content) の両方から wl_pointer.set_cursor を発行する。HiDPI は M1 非対応（scale=1）。
    cursor_theme: ?*c.struct_wl_cursor_theme = null,
    cursor_surface: ?*c.struct_wl_surface = null,
    cursor_shape: types.CursorShape = .default,
    pointer_enter_serial: u32 = 0,
    have_pointer_enter: bool = false, // content surface に pointer が入っているか（set_cursor 可否）
    // wl_pointer.frame 内の axis 蓄積。discrete(notch) を優先し、無ければ continuous を fallback。
    scroll_disc: wlinput.ScrollAccumulator = .{},
    scroll_cont: wlinput.ScrollAccumulator = .{},

    width: u32,
    height: u32,
    compositor_version: u32 = 1,

    // resize（TASK-23）。toplevelConfigure が suggested を pending に記録し、xdgSurfaceConfigure(ack)
    // で st.width/height へ適用する（0 は「サイズ指定なし」で無視）。buffer 実体は lockFramebuffer が
    // free buffer を選んだ時に lazy 再確保する（busy buffer には触らない）。
    pending_width: u32 = 0,
    pending_height: u32 = 0,
    pending_resize: bool = false,

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
    frame_deadline: f64 = 0, // frame callback 律速の floor（取りこぼし時もこの時刻で再開）

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
    } else if (std.mem.eql(u8, ifn, "wl_seat")) {
        // min(advertised, 5): keyboard は repeat_info(v4+)、pointer は frame+axis_discrete(v5) を持ち、
        // value120(v8) は来ない（扱う event 集合を限定して null listener crash を避ける）。
        const v = @min(version, 5);
        st.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, v));
        if (st.seat) |seat| _ = c.wl_seat_add_listener(seat, &seat_listener, st);
    } else if (std.mem.eql(u8, ifn, "wl_subcompositor")) {
        // CSD subsurface 用（version 1 固定。negotiation 不要）。不在なら CSD を構築しない（TASK-28.5.6）。
        st.subcompositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_subcompositor_interface, 1));
    } else if (std.mem.eql(u8, ifn, "zxdg_decoration_manager_v1")) {
        // SSD 要求用。min(advertised, 2) で bind（v1/v2 差は set_mode の扱いのみ。TASK-28.5.6）。
        const v = @min(version, 2);
        st.deco_manager = @ptrCast(c.wl_registry_bind(registry, name, &c.zxdg_decoration_manager_v1_interface, v));
        st.deco_manager_version = v;
    }
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

/// zxdg_toplevel_decoration_v1.configure(mode)。即時適用せず latch し、xdg_surface.configure(ack) で
/// deco_state に反映する（既存 pending_resize と同型。TASK-28.5.6）。
fn decorationConfigure(data: ?*anyopaque, deco: ?*c.struct_zxdg_toplevel_decoration_v1, mode: u32) callconv(.c) void {
    _ = deco;
    const st: *State = @ptrCast(@alignCast(data.?));
    st.pending_decoration_mode = mode;
}

fn xdgSurfaceConfigure(data: ?*anyopaque, xdg_surface: ?*c.struct_xdg_surface, serial: u32) callconv(.c) void {
    const st: *State = @ptrCast(@alignCast(data.?));
    c.xdg_surface_ack_configure(xdg_surface, serial);
    st.configured = true;
    // maximized/tiled（TASK-28.5.6）: toplevelConfigure が states から latch した値を ack と同じ
    // configure sequence で反映する（size 変換より前 = geo→content が正しい maximized で行われる）。
    st.maximized = st.pending_maximized;
    // 装飾 mode の適用（TASK-28.5.6）: decoration.configure で latch した mode を ack と同じ configure
    // sequence で反映する。deco_obj がある場合のみ（FORCE_CSD/manager 不在は create 側で確定済み）。
    // client_side でも subcompositor 不在なら CSD を構築できないので .none に倒す（AC#5 のガード）。
    if (st.deco_obj != null and st.pending_decoration_mode != 0) {
        st.deco_state = if (st.pending_decoration_mode == c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE)
            .ssd
        else if (st.subcompositor != null) .csd else .none;
    }
    // resize（TASK-23）: pending suggested size を ack 後に適用する。ただし初期 setupBuffers より前
    // （buffers 未確保）は適用せず requested size を維持する（create 中は従来挙動）。
    // buffer 実体は lockFramebuffer が free buffer を lazy 再確保する（busy buffer には触らない）。
    // CSD 時は compositor の suggested size は window geometry 基準なので content へ変換する（TASK-28.5.6）。
    if (st.pending_resize and st.buffers[0].buffer != null) {
        st.pending_resize = false;
        if (st.pending_width != 0 and st.pending_height != 0) {
            if (st.deco_state == .csd) {
                const cs = csd.geometryToContent(@intCast(st.pending_width), @intCast(st.pending_height), .csd, st.maximized);
                st.width = @intCast(cs.w);
                st.height = @intCast(cs.h);
            } else {
                st.width = st.pending_width;
                st.height = st.pending_height;
            }
        }
    }
    // 装飾の構築/再配置（buffers 確保後のみ。create 中の初回 configure は setupBuffers 後に create 側が呼ぶ）。
    if (st.buffers[0].buffer != null) syncDecorations(st);
}

fn toplevelConfigure(data: ?*anyopaque, toplevel: ?*c.struct_xdg_toplevel, width: i32, height: i32, states: ?*c.struct_wl_array) callconv(.c) void {
    _ = toplevel;
    const st: *State = @ptrCast(@alignCast(data.?));
    // states（maximized/fullscreen/tiled）を latch。CSD の枠折り畳み判定（TASK-28.5.6）。latest-wins なので
    // 毎回 states を読み直し、実適用は xdg_surface.configure(ack) 側で行う（size と同 sequence）。
    st.pending_maximized = parseMaximized(states);
    // xdg-shell の 0 は「サイズ指定なし（クライアント裁量）」であり最小化ではない。各 configure は
    // latest-wins なので、両軸 >0 のときだけ pending に記録し、それ以外（0 を含む）は stale pending を
    // 消す（前グループの値を引きずらない）。実適用は xdg_surface.configure(ack) 側で行う。
    if (width > 0 and height > 0) {
        st.pending_width = @intCast(width);
        st.pending_height = @intCast(height);
        st.pending_resize = true;
    } else {
        st.pending_resize = false;
    }
}

/// toplevel states 配列（uint32 enum の wl_array）から「枠を折り畳むべき状態」を判定する。
/// maximized / fullscreen / 各 tiled を対象（plan: maximized・tiled 系は枠 0）。
fn parseMaximized(states: ?*c.struct_wl_array) bool {
    const arr = states orelse return false;
    const raw = arr.data orelse return false;
    const n = arr.size / @sizeOf(u32);
    if (n == 0) return false;
    const vals: [*]const u32 = @ptrCast(@alignCast(raw));
    var i: usize = 0;
    while (i < n) : (i += 1) {
        switch (vals[i]) {
            c.XDG_TOPLEVEL_STATE_MAXIMIZED,
            c.XDG_TOPLEVEL_STATE_FULLSCREEN,
            c.XDG_TOPLEVEL_STATE_TILED_LEFT,
            c.XDG_TOPLEVEL_STATE_TILED_RIGHT,
            c.XDG_TOPLEVEL_STATE_TILED_TOP,
            c.XDG_TOPLEVEL_STATE_TILED_BOTTOM,
            => return true,
            else => {},
        }
    }
    return false;
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

// ---- 入力（wl_seat / wl_keyboard / wl_pointer / xkbcommon。TASK-28.5.3） ----
// libwayland は listener[opcode] を null チェックせず呼ぶため、bound version(seat≤5)が送りうる
// 全 event に非 null handler を置く（未使用は no-op）。

fn seatCapabilities(data: ?*anyopaque, seat: ?*c.struct_wl_seat, caps: u32) callconv(.c) void {
    _ = seat;
    const st: *State = @ptrCast(@alignCast(data.?));
    const has_kbd = (caps & WL_SEAT_CAP_KEYBOARD) != 0;
    const has_ptr = (caps & WL_SEAT_CAP_POINTER) != 0;
    if (has_kbd and st.keyboard == null) setupKeyboard(st);
    if (!has_kbd and st.keyboard != null) releaseKeyboard(st);
    if (has_ptr and st.pointer == null) setupPointer(st);
    if (!has_ptr and st.pointer != null) releasePointer(st);
}

fn seatName(data: ?*anyopaque, seat: ?*c.struct_wl_seat, name: [*c]const u8) callconv(.c) void {
    _ = data;
    _ = seat;
    _ = name; // no-op（送られても crash しないため非 null が必要）
}

fn setupKeyboard(st: *State) void {
    const seat = st.seat orelse return;
    st.keyboard = c.wl_seat_get_keyboard(seat);
    if (st.keyboard) |kbd| _ = c.wl_keyboard_add_listener(kbd, &keyboard_listener, st);
}

fn releaseKeyboard(st: *State) void {
    if (st.keyboard) |kbd| {
        c.wl_keyboard_destroy(kbd);
        st.keyboard = null;
    }
    // 押下状態・repeat・modifier・xkb を破棄（keyboard 喪失後に古い modifier が pointer event に残らないように）。
    st.keys = .{};
    st.repeat.key = null;
    st.modifiers = .{};
    if (st.xkb_state) |s| c.xkb_state_unref(s);
    if (st.xkb_keymap) |k| c.xkb_keymap_unref(k);
    st.xkb_state = null;
    st.xkb_keymap = null;
}

fn setupPointer(st: *State) void {
    const seat = st.seat orelse return;
    st.pointer = c.wl_seat_get_pointer(seat);
    if (st.pointer) |ptr| _ = c.wl_pointer_add_listener(ptr, &pointer_listener, st);
}

fn releasePointer(st: *State) void {
    if (st.pointer) |ptr| {
        c.wl_pointer_destroy(ptr);
        st.pointer = null;
    }
    st.buttons = .{};
    // TASK-75.3: capability 喪失経路（leave を伴わない）でも stale な enter serial で
    // set_cursor しないよう focus/serial を落とす。再取得後は次の enter まで no-op。
    st.have_pointer_enter = false;
    st.pointer_enter_serial = 0;
    st.ptr_focus = .content;
}

// ---- wl_keyboard ----

fn kbKeymap(data: ?*anyopaque, kbd: ?*c.struct_wl_keyboard, format: u32, fd: c_int, size: u32) callconv(.c) void {
    _ = kbd;
    const st: *State = @ptrCast(@alignCast(data.?));
    // XKB_V1(=1) 以外は無視。fd は必ず閉じる。
    if (format != 1) {
        _ = close(fd);
        return;
    }
    const raw = mmap(null, size, PROT_READ, MAP_PRIVATE, fd, 0) orelse {
        _ = close(fd);
        return;
    };
    if (@intFromPtr(raw) == MAP_FAILED_INT) {
        _ = close(fd); // MAP_FAILED は munmap しない（不正アドレス）
        return;
    }
    defer {
        _ = munmap(raw, size);
        _ = close(fd);
    }

    if (st.xkb_context == null) st.xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
    const ctx = st.xkb_context orelse return;
    const keymap = c.xkb_keymap_new_from_string(
        ctx,
        @ptrCast(raw),
        c.XKB_KEYMAP_FORMAT_TEXT_V1,
        c.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return;
    const state = c.xkb_state_new(keymap) orelse {
        c.xkb_keymap_unref(keymap);
        return;
    };
    if (st.xkb_state) |s| c.xkb_state_unref(s);
    if (st.xkb_keymap) |k| c.xkb_keymap_unref(k);
    st.xkb_keymap = keymap;
    st.xkb_state = state;
}

fn kbEnter(data: ?*anyopaque, kbd: ?*c.struct_wl_keyboard, serial: u32, surface: ?*c.struct_wl_surface, keys: ?*c.struct_wl_array) callconv(.c) void {
    _ = data;
    _ = kbd;
    _ = serial;
    _ = surface;
    _ = keys; // focus 取得。MVP では押下中キーの再現はしない（no-op）。
}

fn kbLeave(data: ?*anyopaque, kbd: ?*c.struct_wl_keyboard, serial: u32, surface: ?*c.struct_wl_surface) callconv(.c) void {
    _ = kbd;
    _ = serial;
    _ = surface;
    const st: *State = @ptrCast(@alignCast(data.?));
    // focus 喪失: 押下状態と repeat をクリア（押しっぱなし誤検出を防ぐ）。
    st.keys = .{};
    st.repeat.key = null;
}

fn kbKey(data: ?*anyopaque, kbd: ?*c.struct_wl_keyboard, serial: u32, time: u32, key: u32, state: u32) callconv(.c) void {
    _ = kbd;
    _ = serial;
    _ = time;
    const st: *State = @ptrCast(@alignCast(data.?));
    const x_keycode = key + 8; // xkb/X keycode = evdev + 8
    const kc = wlinput.waylandKeyToKeyCode(key);
    const pressed = state != 0; // WL_KEYBOARD_KEY_STATE_PRESSED=1, RELEASED=0
    if (pressed) {
        const was_down = st.keys.isDown(x_keycode);
        st.keys.setDown(x_keycode, true); // 修飾 post-state 算出は反映後に行う
        // 修飾キー自身の event は xkb modifiers(別 event)と順序がずれ得るため、KeyDownSet で post-state 補正（X11 と同じ）。
        const mods = input.overrideModifierBit(st.modifiers, &st.keys, x_keycode);
        st.queue.enqueue(.{ .key_down = .{ .key = kc, .is_repeat = was_down, .modifiers = mods } });
        // 確定文字 (TASK-22): xkb_state_key_get_utf32 で現在の modifier を反映した確定 codepoint を取り
        // char_input を流す（0=文字なしキー / 制御文字は isTextCodepoint で除外）。key_down 経路は不変。
        // Ctrl/Alt/Cmd 付きはショートカット扱いで抑止する（xkb は修飾付きでも文字を返すため明示除外。
        // 他 backend は制御文字化/未生成で自然に除外される。shift は許容=大文字。codex 指摘）。
        if (st.xkb_state) |xs| {
            if (!mods.ctrl and !mods.alt and !mods.cmd) {
                const cp = c.xkb_state_key_get_utf32(xs, x_keycode);
                if (input.isTextCodepoint(cp)) {
                    st.queue.enqueue(.{ .char_input = .{ .codepoint = cp, .modifiers = mods } });
                }
            }
        }
        // repeat 対象か（modifier 等は対象外）を xkbcommon に判定させ、対象のみ repeat 開始。
        if (st.xkb_keymap) |km| {
            if (c.xkb_keymap_key_repeats(km, x_keycode) != 0) st.repeat.onKeyDown(x_keycode, common.getTime());
        }
    } else {
        st.keys.setDown(x_keycode, false);
        st.repeat.onKeyUp(x_keycode);
        const mods = input.overrideModifierBit(st.modifiers, &st.keys, x_keycode);
        st.queue.enqueue(.{ .key_up = .{ .key = kc, .is_repeat = false, .modifiers = mods } });
    }
}

fn kbModifiers(data: ?*anyopaque, kbd: ?*c.struct_wl_keyboard, serial: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.c) void {
    _ = kbd;
    _ = serial;
    const st: *State = @ptrCast(@alignCast(data.?));
    const state = st.xkb_state orelse return;
    _ = c.xkb_state_update_mask(state, mods_depressed, mods_latched, mods_locked, 0, 0, group);
    const eff = c.XKB_STATE_MODS_EFFECTIVE;
    st.modifiers = wlinput.modifiersFromActive(
        c.xkb_state_mod_name_is_active(state, "Shift", eff) > 0,
        c.xkb_state_mod_name_is_active(state, "Control", eff) > 0,
        c.xkb_state_mod_name_is_active(state, "Mod1", eff) > 0, // alt
        c.xkb_state_mod_name_is_active(state, "Mod4", eff) > 0, // super → cmd
    );
}

fn kbRepeatInfo(data: ?*anyopaque, kbd: ?*c.struct_wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
    _ = kbd;
    const st: *State = @ptrCast(@alignCast(data.?));
    st.repeat.setInfo(rate, delay);
}

// ---- wl_pointer ----

fn setButton(st: *State, mb: MouseButton, down: bool) void {
    switch (mb) {
        .left => st.buttons.left = down,
        .right => st.buttons.right = down,
        .middle => st.buttons.middle = down,
        else => {},
    }
}

/// MouseEvent を組む。buttons は内部追跡(post-state)、modifiers は現在の xkb modifier。
fn mouseEvent(st: *State, button: MouseButton) types.MouseEvent {
    return .{
        .x = st.pointer_x,
        .y = st.pointer_y,
        .button = button,
        .buttons = st.buttons,
        .modifiers = st.modifiers,
    };
}

/// ptrEnter の surface からどの surface に focus したか判定する（TASK-28.5.6）。
fn resolveFocus(st: *State, surface: ?*c.struct_wl_surface) PtrFocus {
    if (surface == null) return .other;
    if (surface == st.surface) return .content;
    for (&st.csd_surfaces) |*cs| {
        if (cs.surface != null and surface == cs.surface) return .{ .deco = cs.part };
    }
    return .other;
}

fn ptrEnter(data: ?*anyopaque, ptr: ?*c.struct_wl_pointer, serial: u32, surface: ?*c.struct_wl_surface, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
    _ = ptr;
    const st: *State = @ptrCast(@alignCast(data.?));
    const lx = wlinput.fixedToI32(sx);
    const ly = wlinput.fixedToI32(sy);
    const focus = resolveFocus(st, surface);
    st.ptr_focus = focus;
    switch (focus) {
        .content => {
            st.pointer_x = lx;
            st.pointer_y = ly;
            // TASK-75.3: content に入った瞬間の serial を保持し、現在の cursor_shape を適用する
            // （compositor は enter ごとに client の set_cursor を要求する）。
            st.pointer_enter_serial = serial;
            st.have_pointer_enter = true;
            applyCursor(st);
        },
        .deco => |part| {
            st.have_pointer_enter = false; // 装飾上は content カーソルを出さない
            st.deco_local_x = lx;
            st.deco_local_y = ly;
            // 装飾へ移った瞬間、content 側で蓄積途中の scroll を持ち越さない（plan）。
            st.scroll_disc = .{};
            st.scroll_cont = .{};
            if (part == .title) updateHover(st, lx, ly);
        },
        .other => st.have_pointer_enter = false,
    }
}

fn ptrLeave(data: ?*anyopaque, ptr: ?*c.struct_wl_pointer, serial: u32, surface: ?*c.struct_wl_surface) callconv(.c) void {
    _ = ptr;
    _ = serial;
    const st: *State = @ptrCast(@alignCast(data.?));
    switch (resolveFocus(st, surface)) {
        .deco => {
            // 装飾から離脱: hover を解除（title なら再描画）。
            if (st.hover_button != .none) {
                st.hover_button = .none;
                redrawTitle(st);
            }
        },
        else => {},
    }
    // leave 後は次の enter まで set_cursor の serial が無効（TASK-75.3）。
    st.have_pointer_enter = false;
    st.ptr_focus = .content;
}

fn ptrMotion(data: ?*anyopaque, ptr: ?*c.struct_wl_pointer, time: u32, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
    _ = ptr;
    _ = time;
    const st: *State = @ptrCast(@alignCast(data.?));
    const lx = wlinput.fixedToI32(sx);
    const ly = wlinput.fixedToI32(sy);
    switch (st.ptr_focus) {
        .content => {
            st.pointer_x = lx;
            st.pointer_y = ly;
            st.queue.enqueue(.{ .mouse_move = mouseEvent(st, .none) });
        },
        .deco => |part| {
            st.deco_local_x = lx;
            st.deco_local_y = ly;
            if (part == .title) updateHover(st, lx, ly); // 装飾は app へ流さない
        },
        .other => {},
    }
}

fn ptrButton(data: ?*anyopaque, ptr: ?*c.struct_wl_pointer, serial: u32, time: u32, button: u32, state: u32) callconv(.c) void {
    _ = ptr;
    _ = time;
    const st: *State = @ptrCast(@alignCast(data.?));
    const mb = wlinput.evdevButtonToMouseButton(button) orelse return;
    const pressed = state != 0; // WL_POINTER_BUTTON_STATE_PRESSED=1
    switch (st.ptr_focus) {
        .content => {
            setButton(st, mb, pressed); // post-state にしてから event を組む
            const ev = mouseEvent(st, mb);
            st.queue.enqueue(if (pressed) .{ .mouse_down = ev } else .{ .mouse_up = ev });
        },
        .deco => |part| {
            // 装飾クリックは move/resize/close/max/min へ。app へは流さない（TASK-28.5.6）。
            if (pressed and mb == .left) handleDecoPress(st, part, serial);
        },
        .other => {},
    }
}

/// 装飾上の左押下を hitTest して move/resize/ボタンへ配線する（xdg_toplevel_move/resize は serial 必須）。
fn handleDecoPress(st: *State, part: csd.DecoPart, serial: u32) void {
    const cw: i32 = @intCast(st.width);
    const ch: i32 = @intCast(st.height);
    const target = csd.hitTest(part, st.deco_local_x, st.deco_local_y, cw, ch, st.maximized);
    const tl = st.toplevel orelse return;
    const seat = st.seat orelse return;
    switch (target) {
        .none => {},
        .move => c.xdg_toplevel_move(tl, seat, serial),
        .resize => |edge| c.xdg_toplevel_resize(tl, seat, serial, @intFromEnum(edge)),
        .button => |b| switch (b) {
            .close => st.enqueueQuit(),
            .maximize => if (st.maximized) c.xdg_toplevel_unset_maximized(tl) else c.xdg_toplevel_set_maximized(tl),
            .minimize => c.xdg_toplevel_set_minimized(tl),
            .none => {},
        },
    }
}

fn ptrAxis(data: ?*anyopaque, ptr: ?*c.struct_wl_pointer, time: u32, axis: u32, value: c.wl_fixed_t) callconv(.c) void {
    _ = ptr;
    _ = time;
    const st: *State = @ptrCast(@alignCast(data.?));
    switch (st.ptr_focus) {
        .content => st.scroll_cont.add(wlinput.continuousScroll(axis, value)),
        else => {}, // 装飾上の scroll は無視
    }
}

fn ptrAxisDiscrete(data: ?*anyopaque, ptr: ?*c.struct_wl_pointer, axis: u32, discrete: i32) callconv(.c) void {
    _ = ptr;
    const st: *State = @ptrCast(@alignCast(data.?));
    switch (st.ptr_focus) {
        .content => st.scroll_disc.add(wlinput.discreteScroll(axis, discrete)),
        else => {},
    }
}

fn ptrAxisSource(data: ?*anyopaque, ptr: ?*c.struct_wl_pointer, axis_source: u32) callconv(.c) void {
    _ = data;
    _ = ptr;
    _ = axis_source; // no-op
}

fn ptrAxisStop(data: ?*anyopaque, ptr: ?*c.struct_wl_pointer, time: u32, axis: u32) callconv(.c) void {
    _ = data;
    _ = ptr;
    _ = time;
    _ = axis; // no-op
}

fn ptrFrame(data: ?*anyopaque, ptr: ?*c.struct_wl_pointer) callconv(.c) void {
    _ = ptr;
    const st: *State = @ptrCast(@alignCast(data.?));
    // 装飾上では scroll を蓄積しないので accumulator を捨てて終了（frame ごとの持ち越しを防ぐ）。
    switch (st.ptr_focus) {
        .content => {},
        else => {
            st.scroll_disc = .{};
            st.scroll_cont = .{};
            return;
        },
    }
    // discrete(notch) を優先、無ければ continuous を fallback。frame ごとに 1 mouse_scroll。
    const disc = st.scroll_disc.take();
    const cont = st.scroll_cont.take();
    const d = disc orelse cont orelse return;
    st.queue.enqueue(.{ .mouse_scroll = .{
        .x = st.pointer_x,
        .y = st.pointer_y,
        .dx = d.dx,
        .dy = d.dy,
        .is_precise = false,
        .buttons = st.buttons,
        .modifiers = st.modifiers,
    } });
}

const registry_listener = std.mem.zeroInit(c.struct_wl_registry_listener, .{
    .global = &registryGlobal,
    .global_remove = &registryGlobalRemove,
});
const shm_listener = std.mem.zeroInit(c.struct_wl_shm_listener, .{ .format = &shmFormat });
const wm_base_listener = std.mem.zeroInit(c.struct_xdg_wm_base_listener, .{ .ping = &wmBasePing });
const decoration_listener = std.mem.zeroInit(c.struct_zxdg_toplevel_decoration_v1_listener, .{ .configure = &decorationConfigure });
const xdg_surface_listener = std.mem.zeroInit(c.struct_xdg_surface_listener, .{ .configure = &xdgSurfaceConfigure });
const toplevel_listener = std.mem.zeroInit(c.struct_xdg_toplevel_listener, .{
    .configure = &toplevelConfigure,
    .close = &toplevelClose,
});
const buffer_listener = std.mem.zeroInit(c.struct_wl_buffer_listener, .{ .release = &bufferRelease });
const frame_listener = std.mem.zeroInit(c.struct_wl_callback_listener, .{ .done = &frameDone });

// 入力 listener（zeroInit で未知 field を null 初期化しつつ、bound version が送りうる event は全て設定）。
const seat_listener = std.mem.zeroInit(c.struct_wl_seat_listener, .{
    .capabilities = &seatCapabilities,
    .name = &seatName,
});
const keyboard_listener = std.mem.zeroInit(c.struct_wl_keyboard_listener, .{
    .keymap = &kbKeymap,
    .enter = &kbEnter,
    .leave = &kbLeave,
    .key = &kbKey,
    .modifiers = &kbModifiers,
    .repeat_info = &kbRepeatInfo,
});
const pointer_listener = std.mem.zeroInit(c.struct_wl_pointer_listener, .{
    .enter = &ptrEnter,
    .leave = &ptrLeave,
    .motion = &ptrMotion,
    .button = &ptrButton,
    .axis = &ptrAxis,
    .frame = &ptrFrame,
    .axis_source = &ptrAxisSource,
    .axis_stop = &ptrAxisStop,
    .axis_discrete = &ptrAxisDiscrete,
});

// ============================================================================
// CSD（client-side decoration）構築・配置・描画・破棄（TASK-28.5.6 Stage 2b）
// すべて「イベント時のみ」実行（configure/resize/hover/maximized 変化）。純幾何/描画は csd.zig。
// ============================================================================

/// xdg_surface.set_window_geometry を発行（xdg_surface がある場合のみ）。
fn setWindowGeometry(st: *State, r: csd.Rect) void {
    if (st.xdg_surface) |xs| c.xdg_surface_set_window_geometry(xs, r.x, r.y, r.w, r.h);
}

/// deco_state に応じて装飾を同期する。csd: subsurface 構築+配置+geometry。それ以外: 既存 CSD を破棄。
/// 「subsurface 位置/描画更新 → window geometry → 親 surface commit」の順を守る（plan: 位置は親 commit 依存）。
fn syncDecorations(st: *State) void {
    if (st.deco_state == .csd) {
        if (ensureCsdCreated(st)) {
            layoutCsd(st);
        } else {
            // CSD 構築失敗（subcompositor 不在 / proxy 作成失敗 / OOM）→ 装飾なしへフォールバック。
            // geometry は content のまま（装飾込み geometry を発行して subsurface が欠ける不整合を避ける。codex 指摘 #2）。
            st.deco_state = .none;
            const cw: i32 = @intCast(st.width);
            const ch: i32 = @intCast(st.height);
            setWindowGeometry(st, csd.windowGeometry(cw, ch, .none, false));
            if (st.surface) |s| c.wl_surface_commit(s);
        }
    } else if (st.csd_built) {
        // csd→ssd/none 遷移: CSD を破棄し window geometry を content へ戻す。
        destroyCsd(st);
        const cw: i32 = @intCast(st.width);
        const ch: i32 = @intCast(st.height);
        setWindowGeometry(st, csd.windowGeometry(cw, ch, .none, false));
        if (st.surface) |s| c.wl_surface_commit(s);
    }
    // 純 ssd/none（CSD を作ったことがない）は geometry 既定（surface bounds=content）のまま。
}

/// CSD の 4 subsurface を（未構築なら）生成する。4 枚すべて作れたら true。subcompositor 不在や
/// 途中の proxy 作成失敗では部分構築を巻き戻して false を返す（csd_built は true にしない。codex 指摘 #2）。
fn ensureCsdCreated(st: *State) bool {
    if (st.csd_built) return true;
    const subc = st.subcompositor orelse return false;
    const comp = st.compositor orelse return false;
    const parent = st.surface orelse return false;
    var ok = true;
    for (&st.csd_surfaces) |*cs| {
        const surf = c.wl_compositor_create_surface(comp) orelse {
            ok = false;
            break;
        };
        const ss = c.wl_subcompositor_get_subsurface(subc, surf, parent) orelse {
            c.wl_surface_destroy(surf);
            ok = false;
            break;
        };
        c.wl_subsurface_set_desync(ss); // 自 buffer 再描画を親 commit に依存させない
        cs.surface = surf;
        cs.subsurface = ss;
    }
    if (!ok) {
        destroyCsd(st); // 部分構築分を破棄（csd_built=false のまま。focus/hover も reset）
        return false;
    }
    st.csd_built = true;
    return true;
}

/// 現在の content 寸法+maximized で全 subsurface を配置・描画し、window geometry を発行して親を 1 回 commit。
fn layoutCsd(st: *State) void {
    const cw: i32 = @intCast(st.width);
    const ch: i32 = @intCast(st.height);
    const lay = csd.layout(cw, ch, st.maximized);
    for (&st.csd_surfaces) |*cs| {
        const surf = cs.surface orelse continue;
        const ss = cs.subsurface orelse continue;
        const r = lay.rectOf(cs.part);
        c.wl_subsurface_set_position(ss, r.x, r.y); // 親 commit で適用
        if (r.empty()) {
            // maximized の枠等: buffer を外して非表示（unmap）。mapped=false にして次回 non-empty で
            // busy-skip に取りこぼされず確実に再 attach させる（codex 指摘 #1）。
            c.wl_surface_attach(surf, null, 0, 0);
            c.wl_surface_commit(surf);
            cs.mapped = false;
            continue;
        }
        drawCsdPart(st, cs, r.w, r.h, cw);
    }
    // window geometry（装飾込み）→ 親 commit（subsurface 位置を確定）。
    setWindowGeometry(st, csd.windowGeometry(cw, ch, .csd, st.maximized));
    if (st.surface) |s| c.wl_surface_commit(s);
}

/// subsurface 1 枚のバッファを (w,h) に確保し csd.draw で描いて attach+commit（desync=即時反映）。
/// 同サイズで busy 中（compositor が読み取り中）なら再描画を skip する（single buffer。次イベントで追い付く）。
fn drawCsdPart(st: *State, cs: *CsdSurface, w: i32, h: i32, content_w: i32) void {
    const surf = cs.surface orelse return;
    const uw: u32 = @intCast(w);
    const uh: u32 = @intCast(h);
    // 「既存 buffer へ再描画してよい」= 同サイズ かつ 現在 mapped（表示中）。未 mapped（hide からの復帰）や
    // サイズ変更時は新 buffer を確保して確実に再 attach する（codex 指摘 #1: unmap→remap の取りこぼし防止）。
    const reusable = (cs.buf.buffer != null and cs.buf.bw == uw and cs.buf.bh == uh and cs.mapped);
    if (reusable) {
        if (cs.buf.busy) return; // 表示中バッファへの上書きは避け次イベントで追い付く（hover のちらつき許容）
    } else {
        if (!allocShmBufferSized(st, &cs.buf, w, h)) return; // 再確保失敗（OOM）→ skip
    }
    const hover: csd.Button = if (cs.part == .title) st.hover_button else .none;
    csd.draw(cs.part, cs.buf.pixels, w, h, content_w, hover);
    c.wl_surface_attach(surf, cs.buf.buffer, 0, 0);
    if (st.compositor_version >= 4) {
        c.wl_surface_damage_buffer(surf, 0, 0, w, h);
    } else {
        c.wl_surface_damage(surf, 0, 0, w, h);
    }
    c.wl_surface_commit(surf);
    cs.buf.busy = true;
    cs.mapped = true;
}

/// title バーの hover ボタンを更新し、変化時のみ title subsurface を再描画する（pointer motion 毎の
/// 無条件 redraw はしない。plan）。lx/ly は title-local 座標。
fn updateHover(st: *State, lx: i32, ly: i32) void {
    if (!st.csd_built) return;
    const cw: i32 = @intCast(st.width);
    const nh = csd.hoverButtonAt(lx, ly, cw);
    if (nh == st.hover_button) return;
    st.hover_button = nh;
    redrawTitle(st);
}

/// title subsurface だけを現在の hover で再描画する（位置不変=親 commit 不要。desync で即時反映）。
fn redrawTitle(st: *State) void {
    if (!st.csd_built) return;
    const cw: i32 = @intCast(st.width);
    const ch: i32 = @intCast(st.height);
    const lay = csd.layout(cw, ch, st.maximized);
    if (lay.title.empty()) return;
    drawCsdPart(st, &st.csd_surfaces[0], lay.title.w, lay.title.h, cw); // index 0 = title
}

/// *ShmBuffer を (w,h) の新 shm buffer へ two-phase 再確保する（新確保成功後に旧を破棄）。
/// buffer_listener を新 buffer に束ねる（release→busy=false）。失敗時は旧を残さず false。
fn allocShmBufferSized(st: *State, b: *ShmBuffer, w: i32, h: i32) bool {
    if (w <= 0 or h <= 0) return false;
    const dims = computeShmDims(@intCast(w), @intCast(h)) orelse return false;
    const fd = memfd_create("video-proto-wayland-csd", MFD_CLOEXEC);
    if (fd < 0) return false;
    if (ftruncate(fd, @intCast(dims.size)) != 0) {
        _ = close(fd);
        return false;
    }
    const raw = mmap(null, dims.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) orelse {
        _ = close(fd);
        return false;
    };
    if (@intFromPtr(raw) == MAP_FAILED_INT) {
        _ = close(fd);
        return false;
    }
    const pool = c.wl_shm_create_pool(st.shm, fd, dims.size_i32) orelse {
        _ = munmap(raw, dims.size);
        _ = close(fd);
        return false;
    };
    const wl_buf = c.wl_shm_pool_create_buffer(pool, 0, dims.w_i32, dims.h_i32, dims.stride_i32, st.shm_format) orelse {
        c.wl_shm_pool_destroy(pool);
        _ = munmap(raw, dims.size);
        _ = close(fd);
        return false;
    };
    c.wl_shm_pool_destroy(pool);
    // 旧リソース破棄（呼び出しは同サイズ busy でない or サイズ変更時のみ）。
    if (b.buffer) |old| c.wl_buffer_destroy(old);
    if (b.map_ptr) |p| _ = munmap(p, b.map_size);
    if (b.fd >= 0) _ = close(b.fd);
    const px: [*]u32 = @ptrCast(@alignCast(raw));
    b.* = .{
        .fd = fd,
        .map_ptr = raw,
        .map_size = dims.size,
        .buffer = wl_buf,
        .pixels = px[0..dims.pixel_count],
        .busy = false,
        .bw = @intCast(w),
        .bh = @intCast(h),
    };
    _ = c.wl_buffer_add_listener(wl_buf, &buffer_listener, b);
    return true;
}

/// CSD subsurface 群を破棄する（子=subsurface を親 surface より先に。plan の破棄順序）。
fn destroyCsd(st: *State) void {
    for (&st.csd_surfaces) |*cs| {
        if (cs.subsurface) |ss| c.wl_subsurface_destroy(ss);
        if (cs.surface) |s| c.wl_surface_destroy(s);
        if (cs.buf.buffer) |b| c.wl_buffer_destroy(b);
        if (cs.buf.map_ptr) |p| _ = munmap(p, cs.buf.map_size);
        if (cs.buf.fd >= 0) _ = close(cs.buf.fd);
        cs.* = .{ .part = cs.part };
    }
    st.csd_built = false;
    // focus/hover が破棄済み subsurface を指さないよう content へ戻す（use-after-free 防止）。
    st.ptr_focus = .content;
    st.hover_button = .none;
}

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

        // 装飾 mode の決定（TASK-28.5.6）。toplevel 生成後・初回 commit の前に行う（v1 の順序制約）。
        // FORCE_CSD（debug）は decoration object を作らず即 csd 確定。manager 不在も即確定（csd or none）。
        // 0.16 std には libc 非依存 getenv が無いため libc getenv を使う（x11 backend と同じ）。
        const force_csd = std.c.getenv("VP_WAYLAND_FORCE_CSD") != null;
        if (!force_csd and st.deco_manager != null) {
            st.deco_obj = c.zxdg_decoration_manager_v1_get_toplevel_decoration(st.deco_manager, st.toplevel);
            if (st.deco_obj) |d| {
                _ = c.zxdg_toplevel_decoration_v1_add_listener(d, &decoration_listener, st);
                c.zxdg_toplevel_decoration_v1_set_mode(d, c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
            } else {
                st.deco_state = if (st.subcompositor != null) .csd else .none;
            }
        } else {
            // manager 不在 / FORCE_CSD: subcompositor があれば CSD、無ければ装飾なし。
            st.deco_state = if (st.subcompositor != null) .csd else .none;
        }

        // 初回 commit は buffer を attach しない（初回 xdg_surface.configure を誘発）。
        c.wl_surface_commit(st.surface);
        // decoration object を作った場合は「初回 configure 前の buffer attach 禁止」制約のため、
        // xdg_surface configure に加えて decoration mode 確定（deco_state != .pending）も待つ（TASK-28.5.6）。
        while (!st.configured or (st.deco_obj != null and st.deco_state == .pending)) {
            if (c.wl_display_dispatch(dpy) < 0) return error.WindowCreationFailed;
        }

        // configure 後に shm ダブルバッファを確保。
        try setupBuffers(st);
        // 初期 configure が suggested size を pending に積んでいても、初期 buffer は requested size で
        // 確保済みなので消費して破棄する（stale pending が次回 configure で誤適用されるのを防ぐ）。
        // 以後 compositor が別サイズを要求すれば map 後の configure で再適用される。
        st.pending_resize = false;

        // 装飾の初回構築（deco_state は configure 待ちループで確定済み）。csd なら subsurface を建て、
        // ssd/none は何もしない。buffers 確保後なのでここが唯一の初回ビルド点（configure ハンドラは
        // buffers 未確保の初回は skip する）。
        syncDecorations(st);

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

        // keyboard repeat（repeat_info ベースに is_repeat=true を生成。AC#3）。
        // repeat.key は X keycode 系(evdev+8)なので keycodeToKeyCode をそのまま使う。
        const now = common.getTime();
        if (st.repeat.due(now)) {
            if (st.repeat.key) |xk| {
                st.queue.enqueue(.{ .key_down = .{
                    .key = input.keycodeToKeyCode(xk),
                    .is_repeat = true,
                    .modifiers = st.modifiers,
                } });
                // repeat 中も char_input を出す（押しっぱなしのテキスト入力。codex 指摘 #4）。
                // kbKey の初回発火と同じ抑止条件（Ctrl/Alt/Cmd 除外 + isTextCodepoint）。
                if (st.xkb_state) |xs| {
                    if (!st.modifiers.ctrl and !st.modifiers.alt and !st.modifiers.cmd) {
                        const cp = c.xkb_state_key_get_utf32(xs, xk);
                        if (input.isTextCodepoint(cp)) {
                            st.queue.enqueue(.{ .char_input = .{ .codepoint = cp, .modifiers = st.modifiers } });
                        }
                    }
                }
                st.repeat.advance(now);
            }
        }

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

        // frame callback 律速（AC#6 改訂方針）: 直近 present の wl_surface.frame done が未到着なら
        // この frame を skip して vsync に律速する。これで sleep の無い busy loop の caller
        // （例: example_07）でも commit を撃ちまくらず compositor を飽和させない。frame done は
        // pollEvents で dispatch され frame_pending が解除される。caller は null を「描画 skip」として扱う。
        // ただし callback を取りこぼしても固まらないよう、frame_deadline 超過時は stale callback を
        // 破棄して present を再開させる（最低 ~1/frame_timeout_secs のレートを保証）。
        if (st.frame_pending) {
            if (common.getTime() < st.frame_deadline) return null;
            if (st.frame_callback) |cb| c.wl_callback_destroy(cb);
            st.frame_callback = null;
            st.frame_pending = false;
        }

        // free buffer を選び、サイズが現在値と違えば lazy 再確保してから lock する（TASK-23）。
        if (freeBufferIndex(st)) |i| {
            if (ensureBufferSize(st, i)) return lockAt(st, i);
            return null; // 再確保失敗（OOM 等）→ frame skip。次回 lock で再試行
        }

        // 両 buffer busy: release を取りこぼしていないか軽く dispatch して再試行（ブロックしない）。
        _ = c.wl_display_dispatch_pending(st.display);
        _ = c.wl_display_flush(st.display);
        if (freeBufferIndex(st)) |i| {
            if (ensureBufferSize(st, i)) return lockAt(st, i);
            return null;
        }
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
                st.frame_deadline = common.getTime() + frame_timeout_secs;
            }
        }

        c.wl_surface_commit(surface);
        _ = c.wl_display_flush(st.display);

        buf.busy = true;
        st.locked_index = null;
    }

    /// カーソル形状の設定（TASK-75.3）。shape を保持し、pointer が content 上にあれば即適用する。
    /// 呼び出し頻度: イベント時のみ（性能規約 対象外）。theme/surface 取得失敗は best-effort no-op。
    pub fn setCursor(self: Window, shape: types.CursorShape) void {
        const st = self.state;
        st.cursor_shape = shape;
        applyCursor(st); // content 外（have_pointer_enter=false）なら no-op、次の enter で反映
    }
};

// ---- system cursor（TASK-75.3）----
// wl_cursor_theme / cursor_surface は遅延構築。default/crosshair は default theme の名前付きカーソル、
// hidden は set_cursor(surface=null)。HiDPI(output scale) は M1 非対応（scale=1・size=24 固定）。

/// 現在の cursor_shape を pointer へ適用する（content focus 中のみ発行）。失敗は no-op。
fn applyCursor(st: *State) void {
    if (!st.have_pointer_enter) return;
    const ptr = st.pointer orelse return;
    if (st.cursor_shape == .hidden) {
        // 透明カーソル: surface=null を渡す。
        c.wl_pointer_set_cursor(ptr, st.pointer_enter_serial, null, 0, 0);
        _ = c.wl_display_flush(st.display);
        return;
    }
    const surf = ensureCursorSurface(st) orelse return;
    const image = loadCursorImage(st, st.cursor_shape) orelse return;
    const buffer = c.wl_cursor_image_get_buffer(image);
    if (buffer == null) return;
    // 先に set_cursor で surface へ cursor role を与えてから buffer を attach/commit する
    // （canonical な cursor 更新順。初回適用/hotspot 変更の反映が compositor 依存になりにくい）。
    c.wl_pointer_set_cursor(ptr, st.pointer_enter_serial, surf, @intCast(image.hotspot_x), @intCast(image.hotspot_y));
    c.wl_surface_attach(surf, buffer, 0, 0);
    c.wl_surface_damage(surf, 0, 0, @intCast(image.width), @intCast(image.height));
    c.wl_surface_commit(surf);
    _ = c.wl_display_flush(st.display);
}

/// カーソル画像を載せる wl_surface を遅延生成。
fn ensureCursorSurface(st: *State) ?*c.struct_wl_surface {
    if (st.cursor_surface) |s| return s;
    const comp = st.compositor orelse return null;
    const s = c.wl_compositor_create_surface(comp); // [*c] を返すため == null で判定
    if (s == null) return null;
    st.cursor_surface = s;
    return s;
}

/// default cursor theme を遅延ロード（shm 必須）。
fn ensureCursorTheme(st: *State) ?*c.struct_wl_cursor_theme {
    if (st.cursor_theme) |t| return t;
    const shm = st.shm orelse return null;
    const t = c.wl_cursor_theme_load(null, 24, shm); // name=null → 既定テーマ、size=24
    if (t == null) return null;
    st.cursor_theme = t;
    return t;
}

/// shape に対応する cursor image（1 フレーム目）を返す。theme に該当名が無ければ null。
fn loadCursorImage(st: *State, shape: types.CursorShape) ?*c.struct_wl_cursor_image {
    const theme = ensureCursorTheme(st) orelse return null;
    const name: [*c]const u8 = switch (shape) {
        .default => "left_ptr",
        .crosshair => "crosshair",
        .hidden => return null, // hidden は surface=null 経路（ここには来ない）
    };
    const cursor = c.wl_cursor_theme_get_cursor(theme, name);
    if (cursor == null) return null;
    if (cursor.*.image_count == 0) return null;
    const img = cursor.*.images[0];
    if (img == null) return null;
    return img;
}

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

/// shm buffer の寸法（overflow / wl_shm の int32 protocol 境界を検査済み）。
/// 計算に失敗（overflow / i32 超過）したら null（caller は確保失敗扱い）。
const ShmDims = struct {
    size: usize,
    pixel_count: usize,
    w_i32: i32,
    h_i32: i32,
    stride_i32: i32,
    size_i32: i32,
};

fn computeShmDims(w: u32, h: u32) ?ShmDims {
    const stride = std.math.mul(usize, w, 4) catch return null;
    const size = std.math.mul(usize, stride, h) catch return null;
    const pixel_count = std.math.mul(usize, w, h) catch return null;
    return .{
        .size = size,
        .pixel_count = pixel_count,
        // wl_shm_create_pool / create_buffer は int32_t 系。巨大 resize で trap/不正値にしない。
        .w_i32 = std.math.cast(i32, w) orelse return null,
        .h_i32 = std.math.cast(i32, h) orelse return null,
        .stride_i32 = std.math.cast(i32, stride) orelse return null,
        .size_i32 = std.math.cast(i32, size) orelse return null,
    };
}

/// shm ダブルバッファ確保。各 buffer は独立した memfd + mmap + pool（pool は buffer 作成後 destroy）。
fn setupBuffers(st: *State) Error!void {
    const dims = computeShmDims(st.width, st.height) orelse return error.WindowCreationFailed;
    for (&st.buffers) |*b| {
        try setupOneBuffer(st, b, dims);
    }
}

fn setupOneBuffer(st: *State, b: *ShmBuffer, dims: ShmDims) Error!void {
    const fd = memfd_create("video-proto-wayland", MFD_CLOEXEC);
    if (fd < 0) return error.WindowCreationFailed;
    errdefer _ = close(fd);
    if (ftruncate(fd, @intCast(dims.size)) != 0) return error.WindowCreationFailed;

    const raw = mmap(null, dims.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) orelse return error.WindowCreationFailed;
    if (@intFromPtr(raw) == MAP_FAILED_INT) return error.WindowCreationFailed;
    errdefer _ = munmap(raw, dims.size);

    const pool = c.wl_shm_create_pool(st.shm, fd, dims.size_i32) orelse return error.WindowCreationFailed;
    const wl_buf = c.wl_shm_pool_create_buffer(
        pool,
        0,
        dims.w_i32,
        dims.h_i32,
        dims.stride_i32,
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
    b.map_size = dims.size;
    b.buffer = wl_buf;
    b.pixels = px[0..dims.pixel_count];
    b.busy = false;
    b.bw = st.width;
    b.bh = st.height;
}

/// free（非 busy）buffer のサイズを現在の st.width/height に合わせる。一致なら no-op。
/// 不一致なら two-phase 再確保（新リソース確保成功後に旧を破棄）。成功で true。
/// 呼び出し側（lockFramebuffer）が free buffer に対してのみ呼ぶこと（busy buffer には触らない）。
fn ensureBufferSize(st: *State, i: usize) bool {
    const b = &st.buffers[i];
    if (b.buffer != null and b.bw == st.width and b.bh == st.height) return true;
    return reallocBuffer(st, i);
}

/// free buffer slot を新サイズへ two-phase 再確保する。新リソースの確保に成功してから旧を破棄し、
/// 新 wl_buffer のリスナは slot アドレス（&st.buffers[i]）に束ねる（listener data の安定性を保つ）。
/// 失敗時は slot を旧のまま残す（次回 lock で再試行。OOM 時はフレーム skip）。
fn reallocBuffer(st: *State, i: usize) bool {
    const b = &st.buffers[i];
    const dims = computeShmDims(st.width, st.height) orelse return false;

    // phase 1: 新リソースを locals に確保
    const fd = memfd_create("video-proto-wayland", MFD_CLOEXEC);
    if (fd < 0) return false;
    if (ftruncate(fd, @intCast(dims.size)) != 0) {
        _ = close(fd);
        return false;
    }
    const raw = mmap(null, dims.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) orelse {
        _ = close(fd);
        return false;
    };
    if (@intFromPtr(raw) == MAP_FAILED_INT) {
        _ = close(fd);
        return false;
    }
    const pool = c.wl_shm_create_pool(st.shm, fd, dims.size_i32) orelse {
        _ = munmap(raw, dims.size);
        _ = close(fd);
        return false;
    };
    const wl_buf = c.wl_shm_pool_create_buffer(pool, 0, dims.w_i32, dims.h_i32, dims.stride_i32, st.shm_format) orelse {
        c.wl_shm_pool_destroy(pool);
        _ = munmap(raw, dims.size);
        _ = close(fd);
        return false;
    };
    c.wl_shm_pool_destroy(pool);

    // phase 2: 旧リソース破棄（b は free なので安全）→ 新リソースを slot へ書き込み、listener を再束ね
    if (b.buffer) |old_buf| c.wl_buffer_destroy(old_buf);
    if (b.map_ptr) |p| _ = munmap(p, b.map_size);
    if (b.fd >= 0) _ = close(b.fd);

    const px: [*]u32 = @ptrCast(@alignCast(raw));
    b.fd = fd;
    b.map_ptr = raw;
    b.map_size = dims.size;
    b.buffer = wl_buf;
    b.pixels = px[0..dims.pixel_count];
    b.busy = false;
    b.bw = st.width;
    b.bh = st.height;
    _ = c.wl_buffer_add_listener(wl_buf, &buffer_listener, b);
    return true;
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
    // 入力リソース（TASK-28.5.3）
    if (st.keyboard) |k| c.wl_keyboard_destroy(k);
    if (st.pointer) |p| c.wl_pointer_destroy(p);
    if (st.seat) |s| c.wl_seat_destroy(s);
    if (st.xkb_state) |s| c.xkb_state_unref(s);
    if (st.xkb_keymap) |k| c.xkb_keymap_unref(k);
    if (st.xkb_context) |ctx| c.xkb_context_unref(ctx);
    st.keyboard = null;
    st.pointer = null;
    st.seat = null;
    st.xkb_state = null;
    st.xkb_keymap = null;
    st.xkb_context = null;
    // system cursor（TASK-75.3）: cursor_surface は compositor より前、theme の buffer は shm 由来なので
    // shm より前に破棄する（この teardown 順序は下の compositor/shm 破棄より上）。
    if (st.cursor_surface) |s| c.wl_surface_destroy(s);
    if (st.cursor_theme) |t| c.wl_cursor_theme_destroy(t);
    st.cursor_surface = null;
    st.cursor_theme = null;
    // 装飾（TASK-28.5.6）: 子オブジェクト優先破棄。decoration object は xdg_toplevel より前に destroy。
    if (st.deco_obj) |d| c.zxdg_toplevel_decoration_v1_destroy(d);
    st.deco_obj = null;
    if (st.toplevel) |t| c.xdg_toplevel_destroy(t);
    if (st.xdg_surface) |x| c.xdg_surface_destroy(x);
    // CSD subsurface 群は親 content surface の破棄より前に destroy する（plan の破棄順序）。
    destroyCsd(st);
    if (st.surface) |s| c.wl_surface_destroy(s);
    if (st.deco_manager) |m| c.zxdg_decoration_manager_v1_destroy(m);
    if (st.subcompositor) |sc| c.wl_subcompositor_destroy(sc);
    st.deco_manager = null;
    st.subcompositor = null;
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
