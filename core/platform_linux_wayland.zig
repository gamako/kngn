//! The Linux platform backend: the Wayland implementation
//!
//! The dispatcher (`core/platform_linux.zig`) picks it when `build_options.platform_backend == "wayland"`.
//!
//! It is a software framebuffer. The caller writes canonical BGRA `[]u32` (u32 0xAARRGGBB /
//! memory [B,G,R,A]). On a little-endian host that has the same byte layout as Wayland's XRGB8888,
//! so it can be **written straight into the shm buffer with no converting copy per frame**
//! (lockFramebuffer returns the shm buffer's pixels directly). XRGB8888 is preferred, with ARGB8888 as a fallback.
//!
//! The public contract (a caller-driven poll→present, with no wait for vsync) is the same as X11's. present
//! attaches, damages and commits at once. The `wl_surface.frame` callback is consumed for internal pacing
//! only and never drives the application loop (a frame_pending guard prevents registering it twice). The
//! double buffer is released by `wl_buffer.release`, and while both buffers are busy lockFramebuffer returns null and the caller skips.
//!
//! Input (the keyboard, the mouse and scrolling) arrives here and is translated through the pure logic of
//! `platform_wayland_input.zig`; the file dialogs live in `platform_linux_common.zig`.
//!
//! `wl_data_device`'s offer and receive are a stub: neither is implemented.
//! `Event.file_drop` exists as a type, but this backend never produces one.
//!
//! HiDPI and `.physical`:
//! - content_scale is tracked through a `wl_output` bind plus its scale and `wl_surface.enter|leave` (at event time only).
//! - The registry bind happens at initialisation, and on a hotplug registry event. Pending → latched at the `lockFramebuffer` boundary (incrementing `scale_epoch`).
//! - Only under `.physical` is the shm allocated in physical pixels plus `wl_surface_set_buffer_scale` (a compositor at v3 or above; below that it is a no-op).
//! - Raw physical input = surface-local × content_scale (independent of fb_mode; buffer_scale is not used).
//! - Hot path declaration: detecting the scale, resizing and committing at the lock boundary happen at event time
//!   only, and the registry bind at initialisation and on hotplug registry events (neither per frame nor real time).
//!
//! The C interop convention: the wayland, xdg and xkb headers use bare structs (with no typedef), so the
//! types are `c.struct_wl_*`/`c.struct_xdg_*` and the functions and enum constants keep their C names (`c.wl_*`/`c.WL_SHM_FORMAT_*`).
//! The final field types, nullability and listener signatures are settled by compiling on Linux (this file
//! is not compiled on macOS, since the @cImport is Linux only).

const std = @import("std");
const types = @import("platform_types");
const input = @import("platform_linux_input.zig");
const wlinput = @import("platform_wayland_input.zig");
const common = @import("platform_linux_common.zig");
const build_options = @import("build_options");

const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-cursor.h"); // the system cursor (the wl_cursor_theme, and the buffer for set_cursor)
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("xdg-decoration-unstable-v1-client-protocol.h"); // requesting SSD, with a CSD fallback
});

const csd = @import("platform_wayland_csd.zig"); // the pure decoration logic (the layout, the hit testing and the drawing)

const Error = types.Error;
const Event = types.Event;
const EventStats = types.EventStats;
const MouseButton = types.MouseButton;
const MouseButtons = types.MouseButtons;
const ModifierFlags = types.ModifierFlags;
const FramebufferMode = types.FramebufferMode;
const WindowSize = types.WindowSize;

comptime {
    if (!std.mem.eql(u8, build_options.platform_backend, "wayland")) {
        @compileError("platform_linux_wayland: the Wayland implementation was imported with backend '" ++
            build_options.platform_backend ++ "' (the dispatcher must only pick it for wayland)");
    }
}

// getTime and the file dialogs (which need no display) live in common and are re-exported (as on X11).
pub const getTime = common.getTime;
pub const saveFileDialog = common.saveFileDialog;
pub const openFileDialog = common.openFileDialog;

const alloc = std.heap.c_allocator;

// ============================================================================
// The shared high-DPI helpers (bit-identical to X11's; unit tested)
// Hot path declaration: initialisation and event time only (neither per frame nor real time).
// ============================================================================

/// The real scale used for input normalisation (for a query; re-read each time, before a lock). Independent of fb_mode.
fn effectiveContentScale(raw_scale: f32) f32 {
    return if (raw_scale > 0 and std.math.isFinite(raw_scale)) raw_scale else 1.0;
}

/// Numerically identical to objc's (int)lround((double)px * (double)scale).
/// Clamps to a finite value in [1, the maximum u32] (below 1 → 1, above the maximum u32 → the maximum u32).
fn roundToPhysicalPx(logical_px: u32, scale: f32) u32 {
    const s: f64 = if (scale > 0 and std.math.isFinite(scale)) scale else 1.0;
    const v: f64 = @round(@as(f64, @floatFromInt(logical_px)) * s);
    if (!std.math.isFinite(v) or v < 1.0) return 1;
    if (v > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return std.math.maxInt(u32);
    return @intFromFloat(v);
}

/// The physical framebuffer size. Under .logical it is always the logical size itself (which is where the structural guarantee lives).
fn effectiveFramebufferSize(fb_mode: FramebufferMode, logical: WindowSize, scale: f32) WindowSize {
    if (fb_mode == .logical) return logical;
    return .{
        .width = roundToPhysicalPx(logical.width, scale),
        .height = roundToPhysicalPx(logical.height, scale),
    };
}

/// The scale used to allocate a `.physical` buffer. Below compositor (wl_surface) v3 it is 1.0, which avoids a protocol error.
fn framebufferSizeScale(st: *const State) f32 {
    if (st.fb_mode != .physical or st.compositor_version < 3) return 1.0;
    return effectiveContentScale(st.pending_content_scale);
}

/// The integer scale passed to `wl_surface_set_buffer_scale` (1 under `.logical`, and below compositor v3).
fn bufferScaleInt(st: *const State) i32 {
    if (st.fb_mode != .physical or st.compositor_version < 3) return 1;
    const s = effectiveContentScale(st.content_scale);
    const v = @round(@as(f64, s));
    if (!(v >= 1.0) or !std.math.isFinite(v)) return 1;
    if (v > @as(f64, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    return @intFromFloat(v);
}

/// Recompute `st.width`/`st.height` (the physical framebuffer) from the logical content size.
fn refreshPhysicalSizeFromLogical(st: *State) void {
    const logical: WindowSize = .{ .width = st.logical_width, .height = st.logical_height };
    const fb = effectiveFramebufferSize(st.fb_mode, logical, framebufferSizeScale(st));
    st.width = fb.width;
    st.height = fb.height;
}

/// Re-evaluate pending_content_scale from the set of entered outputs (at event time only).
/// The rule: the largest scale among those entered. A tie goes to whichever was entered first (the values are equal, so the first maximum is enough).
fn recomputePendingContentScale(st: *State) void {
    if (st.entered_count == 0) {
        st.pending_content_scale = 1.0;
        return;
    }
    var best: i32 = 0;
    var found = false;
    var i: u8 = 0;
    while (i < st.entered_count) : (i += 1) {
        const idx = st.entered_indices[i];
        if (idx >= max_outputs) continue;
        if (!st.outputs[idx].active) continue;
        const sc = st.outputs[idx].scale;
        if (!found or sc > best) {
            best = sc;
            found = true;
        }
    }
    st.pending_content_scale = if (found and best > 0) @floatFromInt(best) else 1.0;
}

/// pending → latched. When the scale or the physical size changes, `scale_epoch` is incremented (at the next lock boundary, which is effectively event time).
fn applyLatchedMetricsIfNeeded(st: *State) void {
    const new_scale = effectiveContentScale(st.pending_content_scale);
    const old_scale = effectiveContentScale(st.content_scale);
    const prev_w = st.width;
    const prev_h = st.height;
    st.content_scale = new_scale;
    refreshPhysicalSizeFromLogical(st);
    if (new_scale != old_scale or st.width != prev_w or st.height != prev_h) {
        st.scale_epoch +%= 1;
        st.ct_region_valid = false;
        st.buffer_scale_dirty = true;
    }
}

/// Wayland surface-local (effectively logical) → raw physical event coordinates. Always × content_scale, independent of fb_mode.
fn nativeToRawPhysical(st: *const State, native_x: i32, native_y: i32) struct { x: i32, y: i32 } {
    const s = effectiveContentScale(st.pending_content_scale);
    return .{
        .x = @intFromFloat(@floor(@as(f64, @floatFromInt(native_x)) * @as(f64, s))),
        .y = @intFromFloat(@floor(@as(f64, @floatFromInt(native_y)) * @as(f64, s))),
    };
}

/// Find the slot index from a registry name or a wl_output*.
fn findOutputByName(st: *State, name: u32) ?u8 {
    for (&st.outputs, 0..) |*o, i| {
        if (o.active and o.name == name) return @intCast(i);
    }
    return null;
}

fn findOutputByPtr(st: *State, output: ?*c.struct_wl_output) ?u8 {
    if (output == null) return null;
    for (&st.outputs, 0..) |*o, i| {
        if (o.active and o.output == output) return @intCast(i);
    }
    return null;
}

fn removeEnteredIndex(st: *State, idx: u8) void {
    var i: u8 = 0;
    while (i < st.entered_count) : (i += 1) {
        if (st.entered_indices[i] == idx) {
            var j = i;
            while (j + 1 < st.entered_count) : (j += 1) {
                st.entered_indices[j] = st.entered_indices[j + 1];
            }
            st.entered_count -= 1;
            return;
        }
    }
}

fn destroyOutputSlot(st: *State, idx: u8) void {
    if (idx >= max_outputs) return;
    const o = &st.outputs[idx];
    if (!o.active) return;
    removeEnteredIndex(st, idx);
    if (o.output) |out| c.wl_output_destroy(out);
    o.* = .{};
    recomputePendingContentScale(st);
}

// ============================================================================
// The POSIX syscalls (libc; link_libc is on). It follows the extern declaration style of the X11 backend.
// The values are stable and shared by Linux x86_64 and aarch64.
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
const MAP_PRIVATE: c_int = 0x2; // for mmap'ing the keymap fd (read-only and private)
const POLLIN: c_short = 0x001;

// wl_seat capability bits / keymap format
const WL_SEAT_CAP_POINTER: u32 = 1;
const WL_SEAT_CAP_KEYBOARD: u32 = 2;

// The floor, in seconds, of the frame callback pacing. Until the `wl_surface.frame` done of the most recent
// present arrives, lockFramebuffer returns null and paces to vsync; this many seconds force it to resume, so
// that a missed callback cannot freeze it (i.e. a minimum draw rate of ~1/frame_timeout_secs, which stops a sleepless busy-loop caller flooding commits).
const frame_timeout_secs: f64 = 0.1;
const POLLERR: c_short = 0x008;
const POLLHUP: c_short = 0x010;
const MAP_FAILED_INT: usize = @bitCast(@as(isize, -1));

// The wl_shm format (a uint32_t in the protocol). translate-c's enum constants are c_int, so they are brought to u32.
const FMT_XRGB8888: u32 = @intCast(c.WL_SHM_FORMAT_XRGB8888);
const FMT_ARGB8888: u32 = @intCast(c.WL_SHM_FORMAT_ARGB8888);

/// A fixed-length set of outputs and entered outputs (nothing is allocated dynamically, per the hot path rules).
const max_outputs: u8 = 8;
const max_entered: u8 = 8;

/// One wl_output (a registry global). scale is the scale event of protocol v2 and above; a v1 bind fixes scale=1.
const OutputSlot = struct {
    active: bool = false,
    name: u32 = 0, // the registry global name (for matching in global_remove)
    version: u32 = 1,
    output: ?*c.struct_wl_output = null,
    scale: i32 = 1,
    /// Current mode refresh in mHz (wl_output.mode); 0 means unknown / not yet notified.
    refresh_mhz: i32 = 0,
};

/// First valid current-mode refresh seen this process (Hz). Cleared on shutdown of the owning window path via clearOutputRefreshCache.
var g_output_refresh_hz: ?f64 = null;

fn clearOutputRefreshCache() void {
    g_output_refresh_hz = null;
}

/// Display refresh from the first wl_output current mode, or null when none is known yet.
/// Queried once at startup (event-time), never per frame.
pub fn displayRefreshHz() ?f64 {
    return g_output_refresh_hz;
}

// ============================================================================
// init and shutdown (one Display per process)
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
    clearOutputRefreshCache();
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
    // The allocated size of this buffer (on a resize; when it disagrees with st.width/height it is reallocated at lock time).
    bw: u32 = 0,
    bh: u32 = 0,
};

// ---- CSD (client-side decoration) ----

/// What the pointer is focused on (tracked through the surface argument of ptrEnter). content = the window itself, deco = a decoration subsurface, other = unknown.
/// An event on the decoration (a motion, button, axis or frame) is routed to the decoration rather than into the application's EventQueue.
const PtrFocus = union(enum) {
    content,
    deco: csd.DecoPart,
    other,
};

/// One piece of CSD decoration (there are four: title, left, right and bottom). Each has its own wl_surface, wl_subsurface and single shm buffer.
/// buf reuses the same ShmBuffer type as the content (buffer_listener delivers release → busy=false).
const CsdSurface = struct {
    part: csd.DecoPart,
    surface: ?*c.struct_wl_surface = null,
    subsurface: ?*c.struct_wl_subsurface = null,
    buf: ShmBuffer = .{},
    // Whether a buffer is currently attached and shown. Attaching null (an empty maximised frame) makes it false.
    // The state that stops a re-attach being lost to a busy-skip across an unmap and remap.
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

    // The window decoration: SSD is requested, and CSD is drawn by hand when it is refused.
    subcompositor: ?*c.struct_wl_subcompositor = null, // for the CSD subsurfaces
    deco_manager: ?*c.struct_zxdg_decoration_manager_v1 = null,
    deco_manager_version: u32 = 1,
    deco_obj: ?*c.struct_zxdg_toplevel_decoration_v1 = null,
    // pending: the mode is unsettled / ssd: the compositor draws / csd: we draw / none: no decoration (no manager or no subcompositor)
    deco_state: enum { pending, ssd, csd, none } = .pending,
    // decoration.configure(mode) is latched rather than applied at once, and takes effect at xdg_surface.configure (the ack), like the existing pending_resize.
    // 0=nothing received / 1=client_side / 2=server_side.
    pending_decoration_mode: u32 = 0,
    maximized: bool = false, // The maximized and tiled toplevel states (which decide whether the CSD frames fold away)
    pending_maximized: bool = false, // toplevelConfigure latches it from states, and the ack applies it to maximized
    // Fullscreen on its own (ADR-019 R10). The compositor owns the state, so it is read from the
    // configure states rather than remembered from the creation option: the user can change it with
    // a compositor shortcut at any time.
    fullscreen: bool = false,
    pending_fullscreen: bool = false, // toplevelConfigure latches it from states, and the ack applies it to fullscreen
    restore: types.RestoreGeometryLatch = .{ .geometry = .{ .position = null, .size = .{ .width = 0, .height = 0 } } },
    // The CSD subsurfaces (built only while deco_state==.csd). The order is fixed: 0=title, 1=left, 2=right, 3=bottom.
    csd_surfaces: [4]CsdSurface = .{
        .{ .part = .title }, .{ .part = .left }, .{ .part = .right }, .{ .part = .bottom },
    },
    csd_built: bool = false,
    // Pointer focus tracking (which routes decoration events). While on a decoration, deco_local_x/y hold the part-local coordinates.
    ptr_focus: PtrFocus = .content,
    deco_local_x: i32 = 0,
    deco_local_y: i32 = 0,
    hover_button: csd.Button = .none, // The hovered button of the title bar (redrawn only when it changes)

    // input
    seat: ?*c.struct_wl_seat = null,
    keyboard: ?*c.struct_wl_keyboard = null,
    pointer: ?*c.struct_wl_pointer = null,
    xkb_context: ?*c.struct_xkb_context = null,
    xkb_keymap: ?*c.struct_xkb_keymap = null,
    xkb_state: ?*c.struct_xkb_state = null,
    keys: input.KeyDownSet = .{}, // keycodes are kept in the X keycode space (evdev+8)
    buttons: MouseButtons = .{}, // the post-state (the set of buttons currently held)
    modifiers: ModifierFlags = .{}, // the current xkb modifiers
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
    repeat: wlinput.RepeatState = .{},

    // The system cursor: the theme and the surface are built lazily. The enter serial while the content has
    // focus is kept, and both setCursor and ptrEnter(content) issue wl_pointer.set_cursor. HiDPI is not supported (scale=1).
    cursor_theme: ?*c.struct_wl_cursor_theme = null,
    cursor_surface: ?*c.struct_wl_surface = null,
    cursor_shape: types.CursorShape = .default,
    pointer_enter_serial: u32 = 0,
    have_pointer_enter: bool = false, // whether the pointer is inside the content surface (which decides whether set_cursor may be issued)
    // The axis accumulated within one wl_pointer.frame. A discrete (notch) value wins, with the continuous one as a fallback.
    scroll_disc: wlinput.ScrollAccumulator = .{},
    scroll_cont: wlinput.ScrollAccumulator = .{},

    /// The logical content size (the unit of surface-local coordinates, of an xdg configure and of the CSD layout; the create argument, held independently).
    logical_width: u32 = 0,
    logical_height: u32 = 0,
    /// The physical framebuffer size (the unit of the shm buffer and of present's damage_buffer).
    /// Under `.logical` it equals the logical size; under `.physical` (with a compositor at v3 or above) it is `roundToPhysicalPx`.
    /// A backwards-compatible alias: the framebuffer size the existing blit path refers to.
    width: u32,
    height: u32,
    fb_mode: FramebufferMode = .logical,
    /// For a query (making input raw, and `contentScale()`). Updated by wl_output.scale and by a surface enter or leave.
    pending_content_scale: f32 = 1.0,
    /// The latched value (the `lockFramebuffer` snapshot). Kept apart from pending, which supports a runtime change.
    content_scale: f32 = 1.0,
    scale_epoch: u64 = 0,
    /// Whether `wl_surface_set_buffer_scale` has to be issued again before the next present.
    buffer_scale_dirty: bool = true,

    /// The set of wl_outputs (fixed-length). Managed by the registry bind and global_remove.
    outputs: [max_outputs]OutputSlot = [_]OutputSlot{.{}} ** max_outputs,
    /// The outputs[] index of the output the content surface is currently on (in enter order).
    entered_indices: [max_entered]u8 = [_]u8{0} ** max_entered,
    entered_count: u8 = 0,

    compositor_version: u32 = 1,

    // Resizing. toplevelConfigure records the suggested size as pending, and xdgSurfaceConfigure (the ack)
    // applies it to logical_* (a 0 means "no size given" and is ignored). The buffer itself is reallocated
    // lazily when lockFramebuffer picks a free buffer (a busy buffer is never touched).
    pending_width: u32 = 0,
    pending_height: u32 = 0,
    pending_resize: bool = false,

    // shm format negotiation
    has_xrgb8888: bool = false,
    has_argb8888: bool = false,
    shm_format: u32 = 0,

    // Transparency, borderless, click-through and dragging
    transparent: bool = false, // choose ARGB8888 and emit no opaque region (so the desktop shows through)
    borderless: bool = false, // undecorated (deco_state=.none)
    click_through: bool = false, // let a click on a transparent pixel fall through to what is behind (approximated with an input region)
    last_button_serial: u32 = 0, // The serial of the most recent left press on the content (required by beginDrag=xdg_toplevel_move; one-shot)
    ct_region_valid: bool = false, // Whether the click-through input region has been set (unset means the next present computes it once)

    configured: bool = false,
    closing: bool = false,
    quit_enqueued: bool = false,
    quit_delivered: bool = false,
    queue: input.EventQueue = .{},

    buffers: [2]ShmBuffer = .{ .{}, .{} },
    locked_index: ?usize = null,

    frame_callback: ?*c.struct_wl_callback = null,
    frame_pending: bool = false,
    frame_deadline: f64 = 0, // The floor of the frame callback pacing (it resumes at this time even when one is missed)

    fn enqueueQuit(self: *State) void {
        if (self.quit_enqueued) return;
        self.quit_enqueued = true;
        self.queue.enqueue(.quit);
    }

    /// The abnormal path (a connection error and the like): push .quit once and return the result of pollEvents.
    /// After closing it returns false without waiting for the application to drain the .quit (which rescues a lock-first main loop).
    fn fail(self: *State) bool {
        self.closing = true;
        self.enqueueQuit();
        return false;
    }
};

// ============================================================================
// The listeners (with static lifetime; the data pointer carries the State or the ShmBuffer)
// To allow for version-dependent extra fields (xdg_toplevel's configure_bounds, wm_capabilities and so on),
// every field is null-initialised with std.mem.zeroInit before the handlers actually needed are set.
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
        // min(advertised, 5): the keyboard has repeat_info (v4 and above) and the pointer has frame and
        // axis_discrete (v5), while value120 (v8) never arrives (limiting the event set avoids a null listener crash).
        const v = @min(version, 5);
        st.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, v));
        if (st.seat) |seat| _ = c.wl_seat_add_listener(seat, &seat_listener, st);
    } else if (std.mem.eql(u8, ifn, "wl_subcompositor")) {
        // For the CSD subsurfaces (fixed at version 1; nothing to negotiate). Without it, no CSD is built.
        st.subcompositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_subcompositor_interface, 1));
    } else if (std.mem.eql(u8, ifn, "zxdg_decoration_manager_v1")) {
        // For requesting SSD. It binds at min(advertised, 2) (v1 and v2 differ only in how set_mode is handled).
        const v = @min(version, 2);
        st.deco_manager = @ptrCast(c.wl_registry_bind(registry, name, &c.zxdg_decoration_manager_v1_interface, v));
        st.deco_manager_version = v;
    } else if (std.mem.eql(u8, ifn, "wl_output")) {
        // The version is capped at 4. scale and done are protocol v2 and above (a v1 bind fixes scale=1).
        // Hot path declaration: initialisation only (plus a registry event on a hotplug).
        var slot: ?u8 = null;
        for (&st.outputs, 0..) |*o, i| {
            if (!o.active) {
                slot = @intCast(i);
                break;
            }
        }
        if (slot) |idx| {
            const v = @min(version, 4);
            const out: ?*c.struct_wl_output = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, v));
            if (out) |o| {
                st.outputs[idx] = .{
                    .active = true,
                    .name = name,
                    .version = v,
                    .output = o,
                    .scale = 1,
                };
                _ = c.wl_output_add_listener(o, &output_listener, st);
            }
        }
        // When the slots are full an extra output is ignored (fixed-length, and fail-soft).
    }
}

fn registryGlobalRemove(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32) callconv(.c) void {
    _ = registry;
    const st: *State = @ptrCast(@alignCast(data.?));
    // When an output disconnects: destroy the object, remove it from the entered set, and re-evaluate the scale.
    // Hot path declaration: event time only.
    if (findOutputByName(st, name)) |idx| {
        destroyOutputSlot(st, idx);
    }
}

fn outputGeometry(
    data: ?*anyopaque,
    output: ?*c.struct_wl_output,
    x: i32,
    y: i32,
    physical_width: i32,
    physical_height: i32,
    subpixel: i32,
    make: [*c]const u8,
    model: [*c]const u8,
    transform: i32,
) callconv(.c) void {
    _ = data;
    _ = output;
    _ = x;
    _ = y;
    _ = physical_width;
    _ = physical_height;
    _ = subpixel;
    _ = make;
    _ = model;
    _ = transform;
}

fn outputMode(data: ?*anyopaque, output: ?*c.struct_wl_output, flags: u32, width: i32, height: i32, refresh: i32) callconv(.c) void {
    _ = width;
    _ = height;
    const st: *State = @ptrCast(@alignCast(data.?));
    // Hot path declaration: event time only (compositor mode notify).
    const current: u32 = 0x1; // WL_OUTPUT_MODE_CURRENT
    if ((flags & current) == 0) return;
    if (findOutputByPtr(st, output)) |idx| {
        st.outputs[idx].refresh_mhz = refresh;
    }
    if (refresh > 0 and g_output_refresh_hz == null) {
        g_output_refresh_hz = @as(f64, @floatFromInt(refresh)) / 1000.0;
    }
}

fn outputDone(data: ?*anyopaque, output: ?*c.struct_wl_output) callconv(.c) void {
    _ = data;
    _ = output; // The scale takes effect as its event arrives (no atomic bundling is needed, since it is an integer scale).
}

fn outputScale(data: ?*anyopaque, output: ?*c.struct_wl_output, factor: i32) callconv(.c) void {
    const st: *State = @ptrCast(@alignCast(data.?));
    // Hot path declaration: event time only.
    if (findOutputByPtr(st, output)) |idx| {
        // Below bind version 2 this event is not expected at all. Should it arrive, the scale is applied.
        st.outputs[idx].scale = if (factor > 0) factor else 1;
        // Once entered, pending is re-evaluated (before the first enter it stays 1.0).
        var i: u8 = 0;
        while (i < st.entered_count) : (i += 1) {
            if (st.entered_indices[i] == idx) {
                recomputePendingContentScale(st);
                break;
            }
        }
    }
}

/// The name event of wl_output v4. The display name is unused (a no-op that avoids a null listener crash).
fn outputName(data: ?*anyopaque, output: ?*c.struct_wl_output, name: [*c]const u8) callconv(.c) void {
    _ = data;
    _ = output;
    _ = name;
}

/// The description event of wl_output v4. The display name is unused (a no-op that avoids a null listener crash).
/// On real hardware (sway) this event is sent as well as geometry, mode, done, scale and name, and without a
/// listener libwayland-client aborts with `listener function for opcode 5 of wl_output is NULL` (measured).
fn outputDescription(data: ?*anyopaque, output: ?*c.struct_wl_output, description: [*c]const u8) callconv(.c) void {
    _ = data;
    _ = output;
    _ = description;
}

fn surfaceEnter(data: ?*anyopaque, surface: ?*c.struct_wl_surface, output: ?*c.struct_wl_output) callconv(.c) void {
    _ = surface;
    const st: *State = @ptrCast(@alignCast(data.?));
    // Hot path declaration: event time only. Only the main content surface has this listener registered.
    const idx = findOutputByPtr(st, output) orelse return;
    var i: u8 = 0;
    while (i < st.entered_count) : (i += 1) {
        if (st.entered_indices[i] == idx) return; // already entered
    }
    if (st.entered_count >= max_entered) return;
    st.entered_indices[st.entered_count] = idx;
    st.entered_count += 1;
    recomputePendingContentScale(st);
}

fn surfaceLeave(data: ?*anyopaque, surface: ?*c.struct_wl_surface, output: ?*c.struct_wl_output) callconv(.c) void {
    _ = surface;
    const st: *State = @ptrCast(@alignCast(data.?));
    // Hot path declaration: event time only.
    const idx = findOutputByPtr(st, output) orelse return;
    removeEnteredIndex(st, idx);
    recomputePendingContentScale(st);
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

/// zxdg_toplevel_decoration_v1.configure(mode). It is latched rather than applied at once, and takes effect
/// on deco_state at xdg_surface.configure (the ack), like the existing pending_resize.
fn decorationConfigure(data: ?*anyopaque, deco: ?*c.struct_zxdg_toplevel_decoration_v1, mode: u32) callconv(.c) void {
    _ = deco;
    const st: *State = @ptrCast(@alignCast(data.?));
    st.pending_decoration_mode = mode;
}

fn xdgSurfaceConfigure(data: ?*anyopaque, xdg_surface: ?*c.struct_xdg_surface, serial: u32) callconv(.c) void {
    const st: *State = @ptrCast(@alignCast(data.?));
    c.xdg_surface_ack_configure(xdg_surface, serial);
    st.configured = true;
    // maximized and tiled: the value toplevelConfigure latched from states is applied in the same configure
    // sequence as the ack (before the size conversion, so geo→content runs with the right maximised state).
    st.maximized = st.pending_maximized;
    // Applying the decoration mode: the mode latched by decoration.configure is applied in the same configure
    // sequence as the ack. Only when deco_obj exists (FORCE_CSD and a missing manager are settled in create).
    // Even with client_side, no CSD can be built without a subcompositor, so it falls back to .none.
    // borderless keeps .none, with no decoration (even having asked for CLIENT_SIDE it never falls to csd,
    // because csd would make geometryToContent cut the content height by a phantom title bar).
    if (!st.borderless and st.deco_obj != null and st.pending_decoration_mode != 0) {
        st.deco_state = if (st.pending_decoration_mode == c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE)
            .ssd
        else if (st.subcompositor != null) .csd else .none;
    }
    // Resizing: the pending suggested size is applied after the ack. Before the initial setupBuffers
    // (with no buffers allocated) it is not applied and the requested size is kept (behaviour during create is unchanged).
    // The buffer itself is reallocated lazily by lockFramebuffer when it picks a free buffer (a busy buffer is never touched).
    // Under CSD the compositor's suggested size is in terms of the window geometry, so it is converted into a content size.
    // A configure size is always logical (surface-local). The physical framebuffer comes from refreshPhysicalSizeFromLogical.
    if (st.pending_resize and st.buffers[0].buffer != null) {
        st.pending_resize = false;
        if (st.pending_width != 0 and st.pending_height != 0) {
            const prev_w = st.width;
            const prev_h = st.height;
            var logical_w: u32 = undefined;
            var logical_h: u32 = undefined;
            if (st.deco_state == .csd) {
                const cs = csd.geometryToContent(@intCast(st.pending_width), @intCast(st.pending_height), .csd, st.maximized);
                logical_w = @intCast(cs.w);
                logical_h = @intCast(cs.h);
            } else {
                logical_w = st.pending_width;
                logical_h = st.pending_height;
            }
            st.logical_width = logical_w;
            st.logical_height = logical_h;
            refreshPhysicalSizeFromLogical(st);
            // A size change makes the click-through input region be recomputed (the old bounding box is stale).
            if (st.width != prev_w or st.height != prev_h) st.ct_region_valid = false;
        }
    }
    // Fullscreen and the geometry to persist (ADR-019 R10). The state and the size travel in the
    // same configure group, so both are settled here, **after** the size above has been applied:
    // recording before it would store the fullscreen size as the geometry to restore.
    st.fullscreen = st.pending_fullscreen;
    // Only once the buffers exist, which is the same boundary the resize above uses: the configure
    // that runs during window creation is still looking at the placeholder size.
    if (st.buffers[0].buffer != null) st.restore.observe(st.fullscreen, currentGeometry(st));
    // Building and repositioning the decoration (only once the buffers exist; during create the first configure is called by create, after setupBuffers).
    if (st.buffers[0].buffer != null) syncDecorations(st);
}

fn toplevelConfigure(data: ?*anyopaque, toplevel: ?*c.struct_xdg_toplevel, width: i32, height: i32, states: ?*c.struct_wl_array) callconv(.c) void {
    _ = toplevel;
    const st: *State = @ptrCast(@alignCast(data.?));
    // Latch states (maximized/fullscreen/tiled), which decide whether the CSD frames fold away, and
    // fullscreen on its own, which is the live window state an application observes (ADR-019 R10).
    // It is latest-wins, so states is re-read every time and applied at xdg_surface.configure (the
    // ack), in the same sequence as the size.
    st.pending_maximized = parseMaximized(states);
    st.pending_fullscreen = parseFullscreen(states);
    // A 0 in xdg-shell means "no size given, the client decides" and is not a minimise. Each configure is
    // latest-wins, so pending is recorded only when both axes are > 0; anything else (a 0 included) clears the
    // stale pending (which stops a value carrying over from the previous group). It is applied at xdg_surface.configure (the ack).
    if (width > 0 and height > 0) {
        st.pending_width = @intCast(width);
        st.pending_height = @intCast(height);
        st.pending_resize = true;
    } else {
        st.pending_resize = false;
    }
}

/// Decide from the toplevel states array (a wl_array of uint32 enums) whether the frames should fold away.
/// maximized, fullscreen and each of the tiled states count (the frames are 0 for maximised and tiled).
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

/// Whether the toplevel states array carries the fullscreen state. Unlike `parseMaximized`, which
/// answers a question about the decoration, this is the window state itself: a maximised or tiled
/// window is not fullscreen (ADR-019 R10).
fn parseFullscreen(states: ?*c.struct_wl_array) bool {
    const arr = states orelse return false;
    const raw = arr.data orelse return false;
    const n = arr.size / @sizeOf(u32);
    if (n == 0) return false;
    const vals: [*]const u32 = @ptrCast(@alignCast(raw));
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (vals[i] == c.XDG_TOPLEVEL_STATE_FULLSCREEN) return true;
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

// ---- input (wl_seat, wl_keyboard, wl_pointer and xkbcommon) ----
// libwayland calls listener[opcode] without a null check, so every event the bound version (seat ≤ 5) can
// send has a non-null handler (an unused one is a no-op).

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
    _ = name; // a no-op (a non-null handler is needed so that receiving it does not crash)
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
    // Discard the held keys, the repeat, the modifiers and xkb (so that an old modifier cannot linger on a pointer event after the keyboard is lost).
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
    // Even on the capability-lost path (which comes with no leave), the focus and serial are dropped so that
    // set_cursor is never issued with a stale enter serial. After it is regained it is a no-op until the next enter.
    st.have_pointer_enter = false;
    st.pointer_enter_serial = 0;
    st.ptr_focus = .content;
}

// ---- wl_keyboard ----

fn kbKeymap(data: ?*anyopaque, kbd: ?*c.struct_wl_keyboard, format: u32, fd: c_int, size: u32) callconv(.c) void {
    _ = kbd;
    const st: *State = @ptrCast(@alignCast(data.?));
    // Anything but XKB_V1(=1) is ignored. The fd is always closed.
    if (format != 1) {
        _ = close(fd);
        return;
    }
    const raw = mmap(null, size, PROT_READ, MAP_PRIVATE, fd, 0) orelse {
        _ = close(fd);
        return;
    };
    if (@intFromPtr(raw) == MAP_FAILED_INT) {
        _ = close(fd); // MAP_FAILED must not be munmap'd (it is not a valid address)
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
    _ = keys; // Focus gained. Reproducing the keys already held is out of scope (a no-op).
}

fn kbLeave(data: ?*anyopaque, kbd: ?*c.struct_wl_keyboard, serial: u32, surface: ?*c.struct_wl_surface) callconv(.c) void {
    _ = kbd;
    _ = serial;
    _ = surface;
    const st: *State = @ptrCast(@alignCast(data.?));
    // Focus lost: the held keys and the repeat are cleared (which prevents a key looking stuck down).
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
        st.keys.setDown(x_keycode, true); // the modifier post-state is computed after the set has been updated
        // The event of a modifier key itself can arrive out of order with the xkb modifiers (a separate event), so the post-state is corrected from the KeyDownSet (as on X11).
        const mods = input.overrideModifierBit(st.modifiers, &st.keys, x_keycode);
        st.queue.enqueue(.{ .key_down = .{ .key = kc, .is_repeat = was_down, .modifiers = mods } });
        // A committed character: xkb_state_key_get_utf32 gives the committed codepoint with the current modifiers
        // applied, and char_input is emitted (0 = a key with no character, and control characters fall out in isTextCodepoint). The key_down path is unchanged.
        // Anything with Ctrl, Alt or Cmd counts as a shortcut and is suppressed (xkb returns a character even with a
        // modifier, so it is excluded explicitly; the other backends exclude it naturally. shift is allowed, giving a capital).
        if (st.xkb_state) |xs| {
            if (!mods.ctrl and !mods.alt and !mods.cmd) {
                const cp = c.xkb_state_key_get_utf32(xs, x_keycode);
                if (input.isTextCodepoint(cp)) {
                    st.queue.enqueue(.{ .char_input = .{ .codepoint = cp, .modifiers = mods } });
                }
            }
        }
        // xkbcommon decides whether a key repeats at all (a modifier does not), and only then does the repeat start.
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

/// Build a MouseEvent. buttons comes from the internal tracking (the post-state), and modifiers from the current xkb modifiers.
/// The coordinates are raw physical (`pointer_x/y`; the facade normalises them into logical with the latched content_scale).
fn mouseEvent(st: *State, button: MouseButton) types.MouseEvent {
    return .{
        .x = st.pointer_x,
        .y = st.pointer_y,
        .button = button,
        .buttons = st.buttons,
        .modifiers = st.modifiers,
    };
}

/// Decide which surface has focus from the surface argument of ptrEnter.
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
            // surface-local → raw physical (always × content_scale; a decoration needs no conversion).
            const raw = nativeToRawPhysical(st, lx, ly);
            st.pointer_x = raw.x;
            st.pointer_y = raw.y;
            // Keep the serial of the moment the pointer entered the content and apply the current cursor_shape
            // (a compositor asks the client to set_cursor on every enter).
            st.pointer_enter_serial = serial;
            st.have_pointer_enter = true;
            applyCursor(st);
        },
        .deco => |part| {
            st.have_pointer_enter = false; // the content cursor is not shown over a decoration
            st.deco_local_x = lx; // a decoration stays surface-local (it never reaches the application)
            st.deco_local_y = ly;
            // The scroll accumulating on the content is not carried over the moment the pointer moves onto a decoration.
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
            // Leaving a decoration: the hover is cleared (and title is redrawn).
            if (st.hover_button != .none) {
                st.hover_button = .none;
                redrawTitle(st);
            }
        },
        else => {},
    }
    // After a leave, the set_cursor serial is invalid until the next enter.
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
            const raw = nativeToRawPhysical(st, lx, ly);
            st.pointer_x = raw.x;
            st.pointer_y = raw.y;
            st.queue.enqueue(.{ .mouse_move = mouseEvent(st, .none) });
        },
        .deco => |part| {
            st.deco_local_x = lx;
            st.deco_local_y = ly;
            if (part == .title) updateHover(st, lx, ly); // a decoration never reaches the application
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
            // Keep the serial of a left press on the content for beginDrag (xdg_toplevel_move).
            if (pressed and mb == .left) st.last_button_serial = serial;
            setButton(st, mb, pressed); // bring it to the post-state before building the event
            const ev = mouseEvent(st, mb);
            st.queue.enqueue(if (pressed) .{ .mouse_down = ev } else .{ .mouse_up = ev });
        },
        .deco => |part| {
            // A click on a decoration goes to move, resize, close, maximise or minimise, and never to the application.
            if (pressed and mb == .left) handleDecoPress(st, part, serial);
        },
        .other => {},
    }
}

/// Hit test a left press on the decoration and wire it to move, resize or a button (xdg_toplevel_move and resize both need a serial).
fn handleDecoPress(st: *State, part: csd.DecoPart, serial: u32) void {
    const cw: i32 = @intCast(st.logical_width);
    const ch: i32 = @intCast(st.logical_height);
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

/// Set the click-through input region. Each row's runs of opaque pixels (alpha>0) are added to a wl_region
/// as 1px-high rectangles (per-row spans), and that becomes the wl_surface's input region.
/// A click on the transparent margin and the corners then falls through, following the outline of a round
/// picture (a single bounding box would not let the corners through; this solves it near per pixel, the equivalent of X11's per-pixel mask).
/// **Avoiding a hot path**: the all-pixel scan is gated by `ct_region_valid` and runs exactly once, at the
/// first present after click_through is turned on (never an all-pixel loop per frame, so the three rules do not apply).
/// A still mascot is assumed. Where the silhouette changes, calling setClickThrough again invalidates it.
/// buf.pixels is canonical BGRA (u32 0xAARRGGBB) whose alpha is the top 8 bits. The caller's present does the commit.
/// The input region is in surface-local (logical) coordinates. Under `.physical` opacity is decided on the
/// logical grid (a logical pixel is opaque when any of its scale×scale physical pixels is), and the region is built in logical coordinates.
fn refreshInputRegion(st: *State, buf: *ShmBuffer, surface: *c.struct_wl_surface) void {
    if (st.ct_region_valid) return; // Once set, nothing is scanned (which avoids an all-pixel loop per frame)
    const compositor = st.compositor orelse return;
    const scale_i = bufferScaleInt(st);
    const lw: i32 = @intCast(st.logical_width);
    const lh: i32 = @intCast(st.logical_height);
    const bw: i32 = @intCast(st.width);
    const bh: i32 = @intCast(st.height);
    const px = buf.pixels;
    if (px.len < @as(usize, @intCast(bw)) * @as(usize, @intCast(bh))) return;

    const region = c.wl_compositor_create_region(compositor) orelse return; // on failure valid is left unset and the next present retries

    if (scale_i <= 1) {
        // logical == physical: the existing per-row physical spans go in as surface-local as they are.
        var y: i32 = 0;
        while (y < bh) : (y += 1) {
            const row = @as(usize, @intCast(y)) * @as(usize, @intCast(bw));
            var x: i32 = 0;
            while (x < bw) {
                if ((px[row + @as(usize, @intCast(x))] >> 24) == 0) {
                    x += 1;
                    continue;
                }
                const run_start = x;
                while (x < bw and (px[row + @as(usize, @intCast(x))] >> 24) != 0) : (x += 1) {}
                c.wl_region_add(region, run_start, y, x - run_start, 1);
            }
        }
    } else {
        // The logical grid: a 1x1 goes in whenever any pixel of a logical pixel's scale×scale block is opaque.
        var ly: i32 = 0;
        while (ly < lh) : (ly += 1) {
            var lx: i32 = 0;
            while (lx < lw) {
                var is_opaque = false;
                var dy: i32 = 0;
                while (dy < scale_i and !is_opaque) : (dy += 1) {
                    const py = ly * scale_i + dy;
                    if (py >= bh) break;
                    const row = @as(usize, @intCast(py)) * @as(usize, @intCast(bw));
                    var dx: i32 = 0;
                    while (dx < scale_i) : (dx += 1) {
                        const px_x = lx * scale_i + dx;
                        if (px_x >= bw) break;
                        if ((px[row + @as(usize, @intCast(px_x))] >> 24) != 0) {
                            is_opaque = true;
                            break;
                        }
                    }
                }
                if (!is_opaque) {
                    lx += 1;
                    continue;
                }
                const run_start = lx;
                while (lx < lw) {
                    var run_opaque = false;
                    var dy2: i32 = 0;
                    while (dy2 < scale_i and !run_opaque) : (dy2 += 1) {
                        const py = ly * scale_i + dy2;
                        if (py >= bh) break;
                        const row = @as(usize, @intCast(py)) * @as(usize, @intCast(bw));
                        var dx2: i32 = 0;
                        while (dx2 < scale_i) : (dx2 += 1) {
                            const px_x = lx * scale_i + dx2;
                            if (px_x >= bw) break;
                            if ((px[row + @as(usize, @intCast(px_x))] >> 24) != 0) {
                                run_opaque = true;
                                break;
                            }
                        }
                    }
                    if (!run_opaque) break;
                    lx += 1;
                }
                c.wl_region_add(region, run_start, ly, lx - run_start, 1);
            }
        }
    }

    c.wl_surface_set_input_region(surface, region);
    c.wl_region_destroy(region);
    st.ct_region_valid = true; // settled only once it has been set successfully (on failure the orelse return above leaves valid alone)
}

fn ptrAxis(data: ?*anyopaque, ptr: ?*c.struct_wl_pointer, time: u32, axis: u32, value: c.wl_fixed_t) callconv(.c) void {
    _ = ptr;
    _ = time;
    const st: *State = @ptrCast(@alignCast(data.?));
    switch (st.ptr_focus) {
        .content => st.scroll_cont.add(wlinput.continuousScroll(axis, value)),
        else => {}, // a scroll over a decoration is ignored
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
    // No scroll accumulates over a decoration, so the accumulator is dropped (which prevents it carrying across frames).
    switch (st.ptr_focus) {
        .content => {},
        else => {
            st.scroll_disc = .{};
            st.scroll_cont = .{};
            return;
        },
    }
    // A discrete (notch) value wins, with the continuous one as a fallback. One mouse_scroll per frame.
    // Both the coordinates and the delta are multiplied by content_scale (the facade turns them back into logical with the latched scale).
    const disc = st.scroll_disc.take();
    const cont = st.scroll_cont.take();
    const d = disc orelse cont orelse return;
    const s = effectiveContentScale(st.pending_content_scale);
    st.queue.enqueue(.{ .mouse_scroll = .{
        .x = st.pointer_x,
        .y = st.pointer_y,
        .dx = d.dx * s,
        .dy = d.dy * s,
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
// The output and surface enter-leave listeners (zeroInit leaves v3+ preferred_buffer_* and friends null).
const output_listener = std.mem.zeroInit(c.struct_wl_output_listener, .{
    .geometry = &outputGeometry,
    .mode = &outputMode,
    .done = &outputDone,
    .scale = &outputScale,
    .name = &outputName, // v4. Unused, but not left null (the same approach as the existing seat and pointer)
    .description = &outputDescription, // v4. On real hardware it arrives after geometry, mode, done, scale and name (measured)
});
const surface_listener = std.mem.zeroInit(c.struct_wl_surface_listener, .{
    .enter = &surfaceEnter,
    .leave = &surfaceLeave,
});

// The input listeners (zeroInit null-initialises the unknown fields, while every event the bound version can send is set).
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
// Building, placing, drawing and destroying the CSD (client-side decoration)
// Everything runs "at event time only" (a configure, a resize, a hover or a maximised change). The pure geometry and drawing live in csd.zig.
// ============================================================================

/// Issue xdg_surface.set_window_geometry (only when there is an xdg_surface).
fn setWindowGeometry(st: *State, r: csd.Rect) void {
    if (st.xdg_surface) |xs| c.xdg_surface_set_window_geometry(xs, r.x, r.y, r.w, r.h);
}

/// Bring the decoration into line with deco_state. csd: build, place and set the geometry of the subsurfaces. Anything else: destroy any existing CSD.
/// The order "update the subsurface positions and drawing → the window geometry → commit the parent surface" is kept (a position depends on the parent's commit).
fn syncDecorations(st: *State) void {
    // borderless draws no decoration at all (asking for CLIENT_SIDE stops SSD, and no CSD is built here either).
    if (st.borderless) {
        if (st.csd_built) destroyCsd(st);
        return;
    }
    if (st.deco_state == .csd) {
        if (ensureCsdCreated(st)) {
            layoutCsd(st);
        } else {
            // A failed CSD build (no subcompositor, a failed proxy creation, an OOM) falls back to no decoration.
            // The geometry stays the content (issuing a decoration-inclusive geometry while the subsurfaces are missing would be inconsistent).
            st.deco_state = .none;
            const cw: i32 = @intCast(st.logical_width);
            const ch: i32 = @intCast(st.logical_height);
            setWindowGeometry(st, csd.windowGeometry(cw, ch, .none, false));
            if (st.surface) |s| c.wl_surface_commit(s);
        }
    } else if (st.csd_built) {
        // A csd→ssd/none transition: destroy the CSD and put the window geometry back to the content.
        destroyCsd(st);
        const cw: i32 = @intCast(st.logical_width);
        const ch: i32 = @intCast(st.logical_height);
        setWindowGeometry(st, csd.windowGeometry(cw, ch, .none, false));
        if (st.surface) |s| c.wl_surface_commit(s);
    }
    // Pure ssd and none (where no CSD was ever built) keep the default geometry (the surface bounds, i.e. the content).
}

/// Create the four CSD subsurfaces (unless they exist already). It returns true once all four are built.
/// Without a subcompositor, or on a proxy creation failing part way, the partial build is rolled back and it returns false (csd_built is not set).
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
        c.wl_subsurface_set_desync(ss); // so that redrawing its own buffer does not depend on the parent's commit
        cs.surface = surf;
        cs.subsurface = ss;
    }
    if (!ok) {
        destroyCsd(st); // Discard what was partially built (csd_built stays false, and the focus and hover are reset)
        return false;
    }
    st.csd_built = true;
    return true;
}

/// Place and draw every subsurface at the current content size and maximised state, issue the window geometry, and commit the parent once.
fn layoutCsd(st: *State) void {
    const cw: i32 = @intCast(st.logical_width);
    const ch: i32 = @intCast(st.logical_height);
    const lay = csd.layout(cw, ch, st.maximized);
    for (&st.csd_surfaces) |*cs| {
        const surf = cs.surface orelse continue;
        const ss = cs.subsurface orelse continue;
        const r = lay.rectOf(cs.part);
        c.wl_subsurface_set_position(ss, r.x, r.y); // applied by the parent's commit
        if (r.empty()) {
            // A frame while maximised: the buffer is detached and it is hidden (unmapped). mapped=false makes sure the
            // next non-empty one really re-attaches rather than being lost to a busy-skip.
            c.wl_surface_attach(surf, null, 0, 0);
            c.wl_surface_commit(surf);
            cs.mapped = false;
            continue;
        }
        drawCsdPart(st, cs, r.w, r.h, cw);
    }
    // The window geometry (decoration included) → a parent commit (which settles the subsurface positions).
    setWindowGeometry(st, csd.windowGeometry(cw, ch, .csd, st.maximized));
    if (st.surface) |s| c.wl_surface_commit(s);
}

/// Allocate one subsurface's buffer at (w,h), draw it with csd.draw, and attach and commit it (desync, so it takes effect at once).
/// When it is busy at the same size (the compositor is reading it) the redraw is skipped (a single buffer; the next event catches up).
fn drawCsdPart(st: *State, cs: *CsdSurface, w: i32, h: i32, content_w: i32) void {
    const surf = cs.surface orelse return;
    const uw: u32 = @intCast(w);
    const uh: u32 = @intCast(h);
    // "The existing buffer may be redrawn into" means the same size and currently mapped. When it is not mapped
    // (recovering from being hidden) or the size changed, a new buffer is allocated so the re-attach is certain.
    const reusable = (cs.buf.buffer != null and cs.buf.bw == uw and cs.buf.bh == uh and cs.mapped);
    if (reusable) {
        if (cs.buf.busy) return; // Avoid overwriting a buffer on screen and catch up at the next event (a flicker on hover is acceptable)
    } else {
        if (!allocShmBufferSized(st, &cs.buf, w, h)) return; // a failed reallocation (an OOM) → skip
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

/// Update the title bar's hovered button and redraw the title subsurface only when it changed (never an
/// unconditional redraw per pointer motion). lx/ly are title-local coordinates.
fn updateHover(st: *State, lx: i32, ly: i32) void {
    if (!st.csd_built) return;
    const cw: i32 = @intCast(st.logical_width);
    const nh = csd.hoverButtonAt(lx, ly, cw);
    if (nh == st.hover_button) return;
    st.hover_button = nh;
    redrawTitle(st);
}

/// Redraw the title subsurface alone at the current hover (its position is unchanged, so no parent commit is needed; desync makes it immediate).
fn redrawTitle(st: *State) void {
    if (!st.csd_built) return;
    const cw: i32 = @intCast(st.logical_width);
    const ch: i32 = @intCast(st.logical_height);
    const lay = csd.layout(cw, ch, st.maximized);
    if (lay.title.empty()) return;
    drawCsdPart(st, &st.csd_surfaces[0], lay.title.w, lay.title.h, cw); // index 0 = title
}

/// Reallocate a *ShmBuffer into a new shm buffer of (w,h), in two phases (the old is destroyed only once the new is allocated).
/// buffer_listener is bound to the new buffer (release → busy=false). On failure it returns false without keeping the old one.
fn allocShmBufferSized(st: *State, b: *ShmBuffer, w: i32, h: i32) bool {
    if (w <= 0 or h <= 0) return false;
    const dims = computeShmDims(@intCast(w), @intCast(h)) orelse return false;
    const fd = memfd_create("kngn-wayland-csd", MFD_CLOEXEC);
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
    // Destroy the old resources (this is only called when it is not busy at the same size, or the size changed).
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

/// Destroy the CSD subsurfaces (the children, the subsurfaces, before the parent surface).
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
    // The focus and hover are put back to the content so that neither points at a destroyed subsurface (which would use freed memory).
    st.ptr_focus = .content;
    st.hover_button = .none;
}

// ============================================================================
// Window / Framebuffer
// ============================================================================

pub const Window = struct {
    state: *State,

    /// The single window creation entry point of this backend (ADR-019 R1).
    /// Transparency needs ARGB8888 (without it, error.Unsupported). borderless has no decoration.
    /// Fullscreen asks for `xdg_toplevel_set_fullscreen` before the first commit and takes its size
    /// from the compositor, so the width and height are ignored in that case (ADR-019 R3).
    /// Hot path declaration: initialisation only.
    pub fn createWithOptions(width: u32, height: u32, title: [:0]const u8, opts: types.WindowOptions) Error!Window {
        return createInternal(width, height, title, opts.fullscreen, opts);
    }

    /// `width`/`height` are logical points, **except when `fullscreen` is set**: the compositor
    /// reports the real size in the first configure, so they are replaced by a 1x1 placeholder that
    /// allocates nothing worth reallocating (ADR-019 R3, the asynchronous class).
    fn createInternal(req_width: u32, req_height: u32, title: [:0]const u8, fullscreen: bool, opts: types.WindowOptions) Error!Window {
        const dpy = g_display orelse return error.WindowCreationFailed;
        if (req_width == 0 or req_height == 0) return error.WindowCreationFailed;
        const width: u32 = if (fullscreen) 1 else req_width;
        const height: u32 = if (fullscreen) 1 else req_height;

        // The initial scale falls back to 1.0 before any enter. The physical size follows fb_mode.
        const logical: WindowSize = .{ .width = width, .height = height };
        const init_fb = effectiveFramebufferSize(opts.fb_mode, logical, 1.0);

        const st = alloc.create(State) catch return error.WindowCreationFailed;
        st.* = .{
            .display = dpy,
            .logical_width = width,
            .logical_height = height,
            .width = init_fb.width,
            .height = init_fb.height,
            .fb_mode = opts.fb_mode,
            .pending_content_scale = 1.0,
            .content_scale = 1.0,
            .scale_epoch = 0,
            .buffer_scale_dirty = true,
            .transparent = opts.transparent,
            .borderless = opts.borderless,
            .fullscreen = fullscreen,
            .pending_fullscreen = fullscreen,
            // Seeded with the size that was asked for — not the 1x1 placeholder — so a window
            // created fullscreen still reports a geometry an application can persist, having never
            // been windowed (ADR-019 R10).
            .restore = .{
                .geometry = .{ .position = null, .size = .{ .width = req_width, .height = req_height } },
                .fullscreen = fullscreen,
            },
        };
        errdefer {
            teardown(st);
            alloc.destroy(st);
        }

        // registry → bind the globals (the shm and wm_base listeners are registered inside the global handler).
        st.registry = c.wl_display_get_registry(dpy) orelse return error.WindowCreationFailed;
        _ = c.wl_registry_add_listener(st.registry, &registry_listener, st);
        // The first round binds the globals. The second collects the wl_shm.format events that arrive after the bind.
        if (c.wl_display_roundtrip(dpy) < 0) return error.WindowCreationFailed;
        if (c.wl_display_roundtrip(dpy) < 0) return error.WindowCreationFailed;

        if (st.compositor == null or st.shm == null or st.wm_base == null) return error.WindowCreationFailed;

        // Choosing the shm format. Transparency requires ARGB8888 (to honour the alpha). Without it XRGB8888 is preferred, as before.
        if (opts.transparent) {
            if (st.has_argb8888) {
                st.shm_format = FMT_ARGB8888;
            } else {
                return error.Unsupported; // transparency was asked for, but ARGB8888 is unsupported
            }
        } else if (st.has_xrgb8888) {
            st.shm_format = FMT_XRGB8888;
        } else if (st.has_argb8888) {
            st.shm_format = FMT_ARGB8888;
        } else {
            return error.WindowCreationFailed;
        }

        // surface → xdg_surface → toplevel.
        st.surface = c.wl_compositor_create_surface(st.compositor) orelse return error.WindowCreationFailed;
        // The content surface's enter and leave track the set of outputs (the CSD subsurfaces get no such listener).
        _ = c.wl_surface_add_listener(st.surface, &surface_listener, st);
        st.xdg_surface = c.xdg_wm_base_get_xdg_surface(st.wm_base, st.surface) orelse return error.WindowCreationFailed;
        _ = c.xdg_surface_add_listener(st.xdg_surface, &xdg_surface_listener, st);
        st.toplevel = c.xdg_surface_get_toplevel(st.xdg_surface) orelse return error.WindowCreationFailed;
        _ = c.xdg_toplevel_add_listener(st.toplevel, &toplevel_listener, st);
        c.xdg_toplevel_set_title(st.toplevel, title.ptr);

        if (fullscreen) {
            // output=null (the compositor matches the output the surface is on). It is requested before the first commit.
            c.xdg_toplevel_set_fullscreen(st.toplevel, null);
        } else if (!opts.resizable) {
            // A minimum equal to the maximum is how xdg-shell expresses "do not resize me", in
            // surface-local (logical) coordinates. It is **advice**: the compositor may still send a
            // configure with another size, and the client is obliged to honour a configure, so the
            // resize path still has to work. Fullscreen skips it, because pinning the size there
            // would fight the fullscreen configure itself.
            c.xdg_toplevel_set_min_size(st.toplevel, @intCast(width), @intCast(height));
            c.xdg_toplevel_set_max_size(st.toplevel, @intCast(width), @intCast(height));
        }

        // Deciding the decoration mode. It happens after the toplevel is created and before the first commit (v1's ordering constraint).
        // FORCE_CSD (for debugging) creates no decoration object and settles on csd at once. A missing manager settles it at once too (csd or none).
        // The 0.16 std has no libc-independent getenv, so libc's getenv is used (as in the x11 backend).
        const force_csd = std.c.getenv("KNGN_WAYLAND_FORCE_CSD") != null;
        if (fullscreen) {
            // Fullscreen is always undecorated. No deco_obj is created and it settles on .none (so no CSD title bar is
            // built). On a compositor with no decoration manager the ordinary path would fall to .csd depending on
            // whether a subcompositor exists, and syncDecorations would build a CSD title bar, which is why creating no
            // deco_obj here matters.
            st.deco_state = .none;
        } else if (opts.borderless) {
            // borderless shows no decoration at all. To stop the compositor drawing SSD it asks xdg-decoration for
            // CLIENT_SIDE explicitly (when there is a manager; sway and others draw SSD by default, so it is
            // required), and it draws no CSD of its own either (syncDecorations is a no-op while st.borderless).
            // A compositor with no manager has no SSD to begin with, so .none is enough. Whatever
            // KNGN_WAYLAND_FORCE_CSD (which forces CSD on an ordinary window, for debugging) says, CLIENT_SIDE is requested whenever a manager exists (borderless means zero decoration).
            if (st.deco_manager != null) {
                st.deco_obj = c.zxdg_decoration_manager_v1_get_toplevel_decoration(st.deco_manager, st.toplevel);
                if (st.deco_obj) |d| {
                    _ = c.zxdg_toplevel_decoration_v1_add_listener(d, &decoration_listener, st);
                    c.zxdg_toplevel_decoration_v1_set_mode(d, c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
                }
            }
            // borderless is always fixed to .none, with no decoration (CLIENT_SIDE stops SSD, and no CSD is built).
            // Setting deco_state to .csd would make geometryToContent cut the content height by a phantom title bar,
            // so it must be .none (and xdgSurfaceConfigure applies no mode while borderless either).
            st.deco_state = .none;
        } else if (!force_csd and st.deco_manager != null) {
            st.deco_obj = c.zxdg_decoration_manager_v1_get_toplevel_decoration(st.deco_manager, st.toplevel);
            if (st.deco_obj) |d| {
                _ = c.zxdg_toplevel_decoration_v1_add_listener(d, &decoration_listener, st);
                c.zxdg_toplevel_decoration_v1_set_mode(d, c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
            } else {
                st.deco_state = if (st.subcompositor != null) .csd else .none;
            }
        } else {
            // No manager, or FORCE_CSD: CSD when there is a subcompositor, and no decoration otherwise.
            st.deco_state = if (st.subcompositor != null) .csd else .none;
        }

        // The first commit attaches no buffer (which provokes the first xdg_surface.configure).
        c.wl_surface_commit(st.surface);
        // When a decoration object was created, the constraint "no buffer may be attached before the first
        // configure" means waiting for the decoration mode to settle (deco_state != .pending) as well as for the xdg_surface configure.
        while (!st.configured or (st.deco_obj != null and st.deco_state == .pending)) {
            if (c.wl_display_dispatch(dpy) < 0) return error.WindowCreationFailed;
        }

        // Fullscreen: the suggested size of the first configure (the output's real resolution) is applied by hand
        // before setupBuffers. The ordinary resize path (xdgSurfaceConfigure) is guarded to work only once the
        // buffers exist, so during create it would otherwise be thrown away (leaving the 1x1 placeholder).
        // The suggested size is kept as a logical size, and the physical framebuffer comes from refreshPhysicalSizeFromLogical.
        if (fullscreen and st.pending_resize and st.pending_width != 0 and st.pending_height != 0) {
            st.logical_width = st.pending_width;
            st.logical_height = st.pending_height;
            refreshPhysicalSizeFromLogical(st);
        }

        // The shm double buffer is allocated after the configure.
        try setupBuffers(st);
        // Even when the initial configure left a suggested size pending, the initial buffers were allocated at the
        // requested size, so it is consumed and discarded (which prevents a stale pending being misapplied at the next configure).
        // Should the compositor ask for a different size later, the configure after the map applies it again.
        st.pending_resize = false;

        // The initial decoration build (deco_state was settled by the configure wait loop). csd builds the
        // subsurfaces, and ssd and none do nothing. It comes after the buffers are allocated, which makes this the
        // only initial build point (the configure handler skips the first one, before the buffers exist).
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

        // Dispatch whatever is already in the queue. A failure counts as a connection error and turns into a quit.
        if (c.wl_display_dispatch_pending(dpy) < 0) return st.fail();

        // Read newly arrived events without blocking (the equivalent of X11's while(XPending)).
        // While prepare_read returns != 0 there are unprocessed events, so they are dispatched and it is retried.
        // Once prepare_read returns 0, exactly one of read_events or cancel_read must be called.
        while (c.wl_display_prepare_read(dpy) != 0) {
            if (c.wl_display_dispatch_pending(dpy) < 0) return st.fail();
        }
        // A failed flush is not necessarily fatal (EAGAIN, a saturated send buffer), so it continues; a
        // disconnection is detected by the POLLHUP/POLLERR below and by read_events failing.
        _ = c.wl_display_flush(dpy);

        var pfd = [1]PollFd{.{ .fd = c.wl_display_get_fd(dpy), .events = POLLIN, .revents = 0 }};
        const n = poll(&pfd, 1, 0);
        const re = pfd[0].revents;
        if (n < 0) {
            // poll itself failed (EINTR and the like). The read is cancelled and it continues (while closing, it returns false below).
            c.wl_display_cancel_read(dpy);
            return !st.closing;
        }
        if ((re & (POLLERR | POLLHUP)) != 0) {
            // The compositor disconnected. No read is attempted: it cancels and quits.
            c.wl_display_cancel_read(dpy);
            return st.fail();
        }
        if (n > 0 and (re & POLLIN) != 0) {
            if (c.wl_display_read_events(dpy) < 0) return st.fail();
        } else {
            c.wl_display_cancel_read(dpy);
        }
        if (c.wl_display_dispatch_pending(dpy) < 0) return st.fail();

        // The keyboard repeat (is_repeat=true is generated from repeat_info).
        // repeat.key is in the X keycode space (evdev+8), so keycodeToKeyCode applies as it is.
        // Nothing is pushed while closing (which avoids a pointless enqueue right before the loop ends).
        if (!st.closing) {
            const now = common.getTime();
            if (st.repeat.due(now)) {
                if (st.repeat.key) |xk| {
                    st.queue.enqueue(.{ .key_down = .{
                        .key = input.keycodeToKeyCode(xk),
                        .is_repeat = true,
                        .modifiers = st.modifiers,
                    } });
                    // char_input is emitted during a repeat too (so holding a key types).
                    // The same suppression as the first firing in kbKey (Ctrl/Alt/Cmd excluded, plus isTextCodepoint).
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
        }

        // While closing, false is returned without depending on the application draining the .quit.
        // On Wayland lockFramebuffer is permanently null while closing, so waiting for quit_delivered would leave
        // a lock-first main loop unable to reach nextEvent, and it would spin forever.
        // macOS has the equivalent contract: it enqueues on detecting the close and returns false at once (with no drain).
        return !st.closing;
    }

    pub fn nextEvent(self: Window) ?Event {
        const st = self.state;
        const ev = st.queue.dequeue() orelse return null;
        if (ev == .quit) st.quit_delivered = true;
        return ev;
    }

    /// Let the consumer cancel the quit request and go back to running normally.
    /// The closing of a fatal connection failure is never cancelled.
    /// Hot path declaration: quit/close events only.
    pub fn cancelQuit(self: Window) void {
        const st = self.state;
        if (!st.closing) {
            st.quit_enqueued = false;
            st.quit_delivered = false;
        }
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

        // Latch the pending scale and size (the commit point of a runtime scale change).
        // Hot path declaration: the lock boundary only (never an all-pixel loop per frame).
        applyLatchedMetricsIfNeeded(st);

        // Frame callback pacing: while the `wl_surface.frame` done of the most recent present has not arrived, this
        // frame is skipped and it paces to vsync. That stops a sleepless busy-loop caller (example_07, say) firing
        // commits and saturating the compositor. The frame done is dispatched by pollEvents, which clears
        // frame_pending. The caller treats a null as "skip drawing".
        // So that a missed callback cannot freeze it, though, passing frame_deadline discards the stale callback
        // and lets present resume (which guarantees a rate of at least ~1/frame_timeout_secs).
        if (st.frame_pending) {
            if (common.getTime() < st.frame_deadline) return null;
            if (st.frame_callback) |cb| c.wl_callback_destroy(cb);
            st.frame_callback = null;
            st.frame_pending = false;
        }

        // Pick a free buffer, and when its size differs from the current one reallocate it lazily before locking.
        if (freeBufferIndex(st)) |i| {
            if (ensureBufferSize(st, i)) return lockAt(st, i);
            return null; // a failed reallocation (an OOM, say) → skip the frame. The next lock retries
        }

        // Both buffers are busy: dispatch lightly in case a release was missed, and retry (without blocking).
        _ = c.wl_display_dispatch_pending(st.display);
        _ = c.wl_display_flush(st.display);
        if (freeBufferIndex(st)) |i| {
            if (ensureBufferSize(st, i)) return lockAt(st, i);
            return null;
        }
        return null;
    }

    /// The currently negotiated logical size. Drawing within a frame uses the Framebuffer snapshot.
    pub fn logicalSize(self: Window) WindowSize {
        const st = self.state;
        return .{ .width = st.logical_width, .height = st.logical_height };
    }

    /// The currently negotiated framebuffer size (in physical pixels; equal to the logical one under `.logical`).
    pub fn framebufferSize(self: Window) WindowSize {
        const st = self.state;
        return .{ .width = st.width, .height = st.height };
    }

    /// The currently negotiated content scale (the real output scale whether `.logical` or `.physical`; 1.0 before any enter).
    pub fn contentScale(self: Window) f32 {
        return effectiveContentScale(self.state.pending_content_scale);
    }

    pub fn present(self: Window) void {
        const st = self.state;
        if (!st.configured or st.closing) return;
        const i = st.locked_index orelse return;
        const buf = &st.buffers[i];
        const surface = st.surface.?;
        const buf_w: i32 = @intCast(st.width);
        const buf_h: i32 = @intCast(st.height);
        const surf_w: i32 = @intCast(st.logical_width);
        const surf_h: i32 = @intCast(st.logical_height);

        // set_buffer_scale must precede the next attach and commit (the protocol requires it). It is not called below compositor v3.
        if (st.compositor_version >= 3 and st.buffer_scale_dirty) {
            c.wl_surface_set_buffer_scale(surface, bufferScaleInt(st));
            st.buffer_scale_dirty = false;
        }

        c.wl_surface_attach(surface, buf.buffer, 0, 0);
        // damage_buffer is wl_surface v4 and above (in buffer coordinates). An older compositor falls back to surface-local damage.
        if (st.compositor_version >= 4) {
            c.wl_surface_damage_buffer(surface, 0, 0, buf_w, buf_h);
        } else {
            c.wl_surface_damage(surface, 0, 0, surf_w, surf_h);
        }

        // The frame callback is internal pacing only. It is not registered twice while one is pending (which would leak callbacks).
        if (!st.frame_pending) {
            if (c.wl_surface_frame(surface)) |cb| {
                _ = c.wl_callback_add_listener(cb, &frame_listener, st);
                st.frame_callback = cb;
                st.frame_pending = true;
                st.frame_deadline = common.getTime() + frame_timeout_secs;
            }
        }

        // While click-through is on, the input region is updated from the opaque pixel bounding box of the frame
        // being presented (set_input_region only when the box changed; the commit happens once, below).
        if (st.click_through) refreshInputRegion(st, buf, surface);

        c.wl_surface_commit(surface);
        _ = c.wl_display_flush(st.display);

        buf.busy = true;
        st.locked_index = null;
    }

    /// Start the OS's interactive window move from the most recent left press on the content.
    /// Without a serial (nothing has been pressed yet) it is a no-op. Hot path declaration: event time only.
    pub fn beginDrag(self: Window) void {
        const st = self.state;
        const tl = st.toplevel orelse return;
        const seat = st.seat orelse return;
        if (st.last_button_serial == 0) return;
        const serial = st.last_button_serial;
        st.last_button_serial = 0; // consumed one-shot (used only in response to a button press, symmetrically with the macOS implementation)
        c.xdg_toplevel_move(tl, seat, serial);
    }

    /// Set click-through (approximated per pixel). Turning it on invalidates it, and the next present scans the
    /// opaque pixels' bounding box exactly once and sets it as the input region (so a click on the transparent
    /// margin falls through). Off puts the input region back to null (the whole surface receives clicks).
    /// Hot path declaration: event time only. The all-pixel bounding box scan runs exactly once at the present
    /// after an invalidate (gated by ct_region_valid) and is never an all-pixel loop per frame.
    pub fn setClickThrough(self: Window, on: bool) void {
        const st = self.state;
        st.click_through = on;
        st.ct_region_valid = false; // Always invalidate, so that re-enabling scans the silhouette again (recomputed at the next present)
        if (!on) {
            if (st.surface) |s| {
                c.wl_surface_set_input_region(s, null); // receive over the whole surface
                c.wl_surface_commit(s);
            }
        }
    }

    /// Set the cursor shape. It keeps the shape, and applies it at once while the pointer is over the content.
    /// Call frequency: event time only. A failure to get the theme or the surface is a best-effort no-op.
    pub fn setCursor(self: Window, shape: types.CursorShape) void {
        const st = self.state;
        st.cursor_shape = shape;
        applyCursor(st); // outside the content (have_pointer_enter=false) it is a no-op, and the next enter applies it
    }

    /// Update the visible title. Event time only.
    pub fn setTitle(self: Window, title: [:0]const u8) void {
        c.xdg_toplevel_set_title(self.state.toplevel, title.ptr);
        c.wl_surface_commit(self.state.surface.?);
        _ = c.wl_display_flush(self.state.display);
    }

    /// The live-resize redraw callback. Wayland has no modal loop and is live to begin with, so this is a no-op stub.
    pub fn setRedrawCallback(self: Window, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque) void) void {
        _ = self;
        _ = ctx;
        _ = cb;
    }

    /// The private clear path used by destroy (a no-op).
    pub fn clearRedrawCallback(self: Window) void {
        _ = self;
    }

    /// The IME composition snapshot. The Linux IME is not implemented, so this is always empty.
    pub fn getCompositionSnapshot(self: Window, buf: []u8) types.CompositionSnapshot {
        _ = self;
        return .{ .text = buf[0..0], .revision = 0, .cursor = 0 };
    }
};

/// The current window geometry. Wayland has no position API, so position=null and only the size is given.
/// The size is the logical content size (surface-local).
fn currentGeometry(st: *State) types.WindowGeometry {
    return .{
        .position = null,
        .size = .{ .width = st.logical_width, .height = st.logical_height },
    };
}

/// Module level (the facade's `@hasDecl(backend, "getGeometry")` contract; a Window method would not do).
pub fn getGeometry(win: Window) types.WindowGeometry {
    return currentGeometry(win.state);
}

/// Whether the window is fullscreen right now, including a fullscreen the user started with a
/// compositor shortcut (ADR-019 R10). The value is the one the most recent configure carried, so it
/// costs nothing to read.
/// Hot path declaration: event time only.
pub fn isFullscreen(win: Window) bool {
    return win.state.fullscreen;
}

/// Ask the compositor to enter or leave fullscreen. `output = null` lets the compositor pick the
/// output the surface is on, the same choice window creation makes. It is a request: the compositor
/// answers with a configure, and `isFullscreen` reports the state from that.
/// Hot path declaration: event time only.
pub fn setFullscreen(win: Window, enable: bool) void {
    const st = win.state;
    const toplevel = st.toplevel orelse return;
    if (enable) {
        c.xdg_toplevel_set_fullscreen(toplevel, null);
    } else {
        c.xdg_toplevel_unset_fullscreen(toplevel);
    }
    _ = c.wl_display_flush(st.display);
}

/// The geometry an application should persist (ADR-019 R10): the current one while windowed, and
/// the one held from before the transition while fullscreen.
/// Hot path declaration: window shutdown and event time only.
pub fn windowedGeometry(win: Window) types.WindowGeometry {
    const st = win.state;
    return st.restore.get(currentGeometry(st));
}

// ---- the system cursor ----
// The wl_cursor_theme and the cursor_surface are built lazily. default and crosshair are named cursors of
// the default theme, and hidden is set_cursor(surface=null). HiDPI (the output scale) is unsupported (scale=1, size=24).

/// Apply the current cursor_shape to the pointer (issued only while the content has focus). A failure is a no-op.
fn applyCursor(st: *State) void {
    if (!st.have_pointer_enter) return;
    const ptr = st.pointer orelse return;
    if (st.cursor_shape == .hidden) {
        // The transparent cursor: surface=null is passed.
        c.wl_pointer_set_cursor(ptr, st.pointer_enter_serial, null, 0, 0);
        _ = c.wl_display_flush(st.display);
        return;
    }
    const surf = ensureCursorSurface(st) orelse return;
    const image = loadCursorImage(st, st.cursor_shape) orelse return;
    const buffer = c.wl_cursor_image_get_buffer(image);
    if (buffer == null) return;
    // set_cursor gives the surface its cursor role first, and only then is the buffer attached and committed
    // (the canonical order for a cursor update, which makes the first application and a hotspot change less compositor dependent).
    c.wl_pointer_set_cursor(ptr, st.pointer_enter_serial, surf, @intCast(image.hotspot_x), @intCast(image.hotspot_y));
    c.wl_surface_attach(surf, buffer, 0, 0);
    c.wl_surface_damage(surf, 0, 0, @intCast(image.width), @intCast(image.height));
    c.wl_surface_commit(surf);
    _ = c.wl_display_flush(st.display);
}

/// Create the wl_surface that carries the cursor image, lazily.
fn ensureCursorSurface(st: *State) ?*c.struct_wl_surface {
    if (st.cursor_surface) |s| return s;
    const comp = st.compositor orelse return null;
    const s = c.wl_compositor_create_surface(comp); // it returns a [*c], so it is compared against null
    if (s == null) return null;
    st.cursor_surface = s;
    return s;
}

/// Load the default cursor theme lazily (shm is required).
fn ensureCursorTheme(st: *State) ?*c.struct_wl_cursor_theme {
    if (st.cursor_theme) |t| return t;
    const shm = st.shm orelse return null;
    const t = c.wl_cursor_theme_load(null, 24, shm); // name=null → the default theme, size=24
    if (t == null) return null;
    st.cursor_theme = t;
    return t;
}

/// Return the cursor image (its first frame) for a shape. Without that name in the theme it gives null.
fn loadCursorImage(st: *State, shape: types.CursorShape) ?*c.struct_wl_cursor_image {
    const theme = ensureCursorTheme(st) orelse return null;
    const name: [*c]const u8 = switch (shape) {
        .default => "left_ptr",
        .crosshair => "crosshair",
        .hidden => return null, // hidden goes through the surface=null path (and never reaches here)
    };
    const cursor = c.wl_cursor_theme_get_cursor(theme, name);
    if (cursor == null) return null;
    if (cursor.*.image_count == 0) return null;
    const img = cursor.*.images[0];
    if (img == null) return null;
    return img;
}

/// A locked framebuffer view (the public contract is canonical BGRA `[]u32`, u32 0xAARRGGBB).
/// pixels points straight at the shm buffer (present copies nothing).
pub const Framebuffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    logical_size: types.WindowSize,
    framebuffer_size: types.WindowSize,
    content_scale: f32,
    scale_epoch: u64,
    state: *State,

    pub fn unlock(self: Framebuffer) void {
        _ = self; // the commit happens at present time, so unlock itself is a no-op
    }
};

// ============================================================================
// internal helpers
// ============================================================================

fn freeBufferIndex(st: *State) ?usize {
    for (&st.buffers, 0..) |*b, i| {
        if (!b.busy and b.buffer != null) return i;
    }
    return null;
}

fn lockAt(st: *State, i: usize) Framebuffer {
    st.locked_index = i;
    const logical: types.WindowSize = .{ .width = st.logical_width, .height = st.logical_height };
    const fb_size: types.WindowSize = .{ .width = st.width, .height = st.height };
    const scale = effectiveContentScale(st.content_scale);
    return .{
        .pixels = st.buffers[i].pixels,
        .width = st.width,
        .height = st.height,
        .logical_size = logical,
        .framebuffer_size = fb_size,
        .content_scale = scale,
        .scale_epoch = st.scale_epoch,
        .state = st,
    };
}

/// The size of an shm buffer (already checked for overflow and against wl_shm's int32 protocol boundary).
/// A failed computation (an overflow, or exceeding i32) gives null (the caller treats it as a failed allocation).
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
        // wl_shm_create_pool and create_buffer are int32_t based. A huge resize must not trap or pass a bad value.
        .w_i32 = std.math.cast(i32, w) orelse return null,
        .h_i32 = std.math.cast(i32, h) orelse return null,
        .stride_i32 = std.math.cast(i32, stride) orelse return null,
        .size_i32 = std.math.cast(i32, size) orelse return null,
    };
}

/// Allocate the shm double buffer. Each buffer gets its own memfd, mmap and pool (the pool is destroyed once the buffer is created).
fn setupBuffers(st: *State) Error!void {
    const dims = computeShmDims(st.width, st.height) orelse return error.WindowCreationFailed;
    for (&st.buffers) |*b| {
        try setupOneBuffer(st, b, dims);
    }
}

fn setupOneBuffer(st: *State, b: *ShmBuffer, dims: ShmDims) Error!void {
    const fd = memfd_create("kngn-wayland", MFD_CLOEXEC);
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
    c.wl_shm_pool_destroy(pool); // the pool is unneeded once the buffer exists (the fd and the mmap are kept)

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

/// Bring a free (not busy) buffer's size into line with the current st.width/height. A match is a no-op.
/// A mismatch reallocates in two phases (the old is destroyed only once the new is allocated). true on success.
/// The caller (lockFramebuffer) must only call it for a free buffer (a busy buffer is never touched).
fn ensureBufferSize(st: *State, i: usize) bool {
    const b = &st.buffers[i];
    if (b.buffer != null and b.bw == st.width and b.bh == st.height) return true;
    return reallocBuffer(st, i);
}

/// Reallocate a free buffer slot at the new size, in two phases. The old is destroyed only once the new is
/// allocated, and the new wl_buffer's listener is bound to the slot address (&st.buffers[i]), which keeps the listener data stable.
/// On failure the slot is left as it was (the next lock retries; on an OOM the frame is skipped).
fn reallocBuffer(st: *State, i: usize) bool {
    const b = &st.buffers[i];
    const dims = computeShmDims(st.width, st.height) orelse return false;

    // phase 1: allocate the new resources into locals
    const fd = memfd_create("kngn-wayland", MFD_CLOEXEC);
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

    // phase 2: destroy the old resources (b is free, so it is safe) → write the new ones into the slot and rebind the listener
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

/// Free the allocated resources, null-checking each. Shared by create's errdefer and by destroy.
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
    // the input resources
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
    // Destroy the wl_outputs (and clear the entered set).
    for (&st.outputs) |*o| {
        if (o.active) {
            if (o.output) |out| c.wl_output_destroy(out);
            o.* = .{};
        }
    }
    st.entered_count = 0;
    // The system cursor: cursor_surface goes before the compositor, and the theme's buffers come from shm, so
    // they go before shm (this teardown order sits above the compositor and shm destruction below).
    if (st.cursor_surface) |s| c.wl_surface_destroy(s);
    if (st.cursor_theme) |t| c.wl_cursor_theme_destroy(t);
    st.cursor_surface = null;
    st.cursor_theme = null;
    // The decoration: children first. The decoration object is destroyed before the xdg_toplevel.
    if (st.deco_obj) |d| c.zxdg_toplevel_decoration_v1_destroy(d);
    st.deco_obj = null;
    if (st.toplevel) |t| c.xdg_toplevel_destroy(t);
    if (st.xdg_surface) |x| c.xdg_surface_destroy(x);
    // The CSD subsurfaces are destroyed before the parent content surface.
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

// ============================================================================
// Structural unit tests of the shared helpers (no display and no compositor needed)
// They run when this module is part of the test root, on Linux with `-Dplatform=wayland`.
// ============================================================================

test "effectiveFramebufferSize .logical returns the logical size, independent of scale" {
    const logical: WindowSize = .{ .width = 800, .height = 600 };
    const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0, 3.0 };
    for (scales) |s| {
        const fb = effectiveFramebufferSize(.logical, logical, s);
        try std.testing.expectEqual(logical.width, fb.width);
        try std.testing.expectEqual(logical.height, fb.height);
    }
}

test "effectiveFramebufferSize .physical applies roundToPhysicalPx" {
    const logical: WindowSize = .{ .width = 800, .height = 600 };
    const fb2 = effectiveFramebufferSize(.physical, logical, 2.0);
    try std.testing.expectEqual(@as(u32, 1600), fb2.width);
    try std.testing.expectEqual(@as(u32, 1200), fb2.height);

    const fb15 = effectiveFramebufferSize(.physical, logical, 1.5);
    try std.testing.expectEqual(@as(u32, 1200), fb15.width);
    try std.testing.expectEqual(@as(u32, 900), fb15.height);
}

test "roundToPhysicalPx matches objc lround and clamps to the range" {
    try std.testing.expectEqual(@as(u32, 1), roundToPhysicalPx(0, 2.0)); // 0*2→0 → clamp to 1
    try std.testing.expectEqual(@as(u32, 1600), roundToPhysicalPx(800, 2.0));
    try std.testing.expectEqual(@as(u32, 1200), roundToPhysicalPx(800, 1.5));
    try std.testing.expectEqual(@as(u32, 800), roundToPhysicalPx(800, 0.0)); // invalid scale → 1.0
    try std.testing.expectEqual(@as(u32, 800), roundToPhysicalPx(800, std.math.nan(f32)));
}

test "effectiveContentScale corrects a non-positive or non-finite value to 1.0" {
    try std.testing.expectEqual(@as(f32, 2.0), effectiveContentScale(2.0));
    try std.testing.expectEqual(@as(f32, 1.0), effectiveContentScale(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), effectiveContentScale(-1.0));
    try std.testing.expectEqual(@as(f32, 1.0), effectiveContentScale(std.math.nan(f32)));
    try std.testing.expectEqual(@as(f32, 1.0), effectiveContentScale(std.math.inf(f32)));
}
