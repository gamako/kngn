//! The Linux platform backend: the X11/Xlib implementation
//!
//! The dispatcher (`core/platform_linux.zig`) picks it when `build_options.platform_backend == "x11"`.
//! The display-independent `getTime` and file dialogs live in `platform_linux_common.zig` and are re-exported.
//!
//! It is a software framebuffer. The caller writes canonical BGRA `[]u32`
//! (u32 0xAARRGGBB / memory [B,G,R,A]).
//!
//! The blit at present time takes one of two paths, decided by the visual classification (`platform_linux_convert.classifyVisual`):
//!   - **direct**: 32bpp and LSBFirst and rs16/gs8/bs0 and stride==width*4. The low 24 bits of canonical
//!     BGRA match the 0x00RRGGBB of a standard visual, so the caller writes into the XImage or shm buffer
//!     itself (`lockFramebuffer` returns the image data) and present is nothing but XShmPutImage/XPutImage (**no converting copy per frame**).
//!   - **fallback**: a 32bpp, LSBFirst visual with 8 contiguous bits for each of R/G/B, but a non-standard shift or stride padding.
//!     A separate backing (BGRA) is converted by `packPixel` (BGRA→the visual mask) at present time and then blitted.
//!   - **fail**: 16/24bpp, 565, a non-contiguous or overlapping mask, and MSBFirst all make create return WindowCreationFailed (they are not supported).
//!
//! Deciding between direct and fallback, and the conversion itself, are pure logic (`platform_linux_convert.zig`) and unit tested without a display.
//! Input (keys and the mouse) is handled in this file, the file dialogs in `platform_linux_common.zig`,
//! and Wayland in `platform_linux_wayland.zig`.
//!
//! The pure translation of input (keycode→KeyCode, state→modifiers, the EventQueue merging, the KeyDownSet) lives in
//! `platform_linux_input.zig` (pure Zig with no @cImport), and this file only pulls the values out of an XEvent and calls it.
//!
//! XDND (X Drag and Drop) is a stub: neither the atom registration nor the selection exchange is implemented.
//! `Event.file_drop` exists as a type, but this backend never produces one.

const std = @import("std");
const types = @import("platform_types");
const input = @import("platform_linux_input.zig");
const conv = @import("platform_linux_convert.zig");
const common = @import("platform_linux_common.zig");
const build_options = @import("build_options");

const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/Xatom.h"); // XA_ATOM (for setting _NET_WM_STATE when a window is created fullscreen)
    @cInclude("X11/XKBlib.h"); // XkbSetDetectableAutoRepeat
    @cInclude("X11/cursorfont.h"); // XC_left_ptr / XC_crosshair (the system cursors)
    @cInclude("X11/Xresource.h"); // The Xrm API (Xft.dpi → content_scale)
    @cInclude("X11/extensions/XShm.h");
    @cInclude("X11/extensions/shape.h"); // The input shape behind click-through
    @cInclude("sys/ipc.h");
    @cInclude("sys/shm.h");
});

const Error = types.Error;
const Event = types.Event;
const EventStats = types.EventStats;
const MouseButton = types.MouseButton;
const MouseButtons = types.MouseButtons;
const MouseEvent = types.MouseEvent;
const FramebufferMode = types.FramebufferMode;
const WindowSize = types.WindowSize;

// ============================================================================
// The shared high-DPI helpers (unit tested)
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

/// A physical pixel count → logical points: the inverse of `roundToPhysicalPx`, with the same
/// rounding and the same clamps. It is the derivation direction fullscreen needs, because the X11
/// screen dimensions are already physical (ADR-011 R11): the framebuffer size is the screen size
/// verbatim and the logical size is derived from it, never the other way round.
fn logicalFromPhysicalPx(physical_px: u32, scale: f32) u32 {
    const s: f64 = if (scale > 0 and std.math.isFinite(scale)) scale else 1.0;
    const v: f64 = @round(@as(f64, @floatFromInt(physical_px)) / s);
    if (!std.math.isFinite(v) or v < 1.0) return 1;
    if (v > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return std.math.maxInt(u32);
    return @intFromFloat(v);
}

/// The logical size that goes with a physical window size under `fb_mode` — the pair used both when
/// a fullscreen window is created and when a resize notification arrives, so that the logical size
/// cannot differ between the first frame and the first configure (ADR-011 R11).
fn logicalSizeForPhysical(fb_mode: FramebufferMode, physical: WindowSize, scale: f32) WindowSize {
    if (fb_mode == .logical) return physical;
    return .{
        .width = logicalFromPhysicalPx(physical.width, scale),
        .height = logicalFromPhysicalPx(physical.height, scale),
    };
}

/// The physical framebuffer size. Under .logical it is always the logical size itself (which is where the structural guarantee lives).
fn effectiveFramebufferSize(fb_mode: FramebufferMode, logical: WindowSize, scale: f32) WindowSize {
    if (fb_mode == .logical) return logical;
    return .{
        .width = roundToPhysicalPx(logical.width, scale),
        .height = roundToPhysicalPx(logical.height, scale),
    };
}

/// Read content_scale from Xft.dpi (an X resource). A failure is fail-soft and gives 1.0.
/// Xft.dpi is a global value for the whole display, not a per-monitor DPI. It is fixed at start-up.
fn queryXftContentScale(dpy: *c.Display) f32 {
    c.XrmInitialize();
    const rms = c.XResourceManagerString(dpy) orelse return 1.0;
    const db = c.XrmGetStringDatabase(rms);
    if (db == null) return 1.0;
    defer c.XrmDestroyDatabase(db);

    var type_ret: [*c]u8 = undefined;
    var value: c.XrmValue = undefined;
    if (c.XrmGetResource(db, "Xft.dpi", "Xft.Dpi", &type_ret, &value) == 0) return 1.0;
    if (value.addr == null or value.size == 0) return 1.0;

    const addr: [*]const u8 = @ptrCast(value.addr);
    const raw: []const u8 = addr[0..value.size];
    const text = std.mem.trim(u8, raw, " \t\r\n\x00");
    if (text.len == 0) return 1.0;
    const dpi = std.fmt.parseFloat(f64, text) catch return 1.0;
    if (!(dpi > 0) or !std.math.isFinite(dpi)) return 1.0;
    const scale: f32 = @floatCast(dpi / 96.0);
    return effectiveContentScale(scale);
}

comptime {
    // This file is the x11 implementation. The dispatcher (platform_linux.zig) imports it only when
    // build_options.platform_backend=="x11"; the check below is a second line of defence that fails loudly if another backend pulls it in by mistake.
    if (!std.mem.eql(u8, build_options.platform_backend, "x11")) {
        @compileError("platform_linux_x11: the X11 implementation was imported with backend '" ++
            build_options.platform_backend ++ "' (the dispatcher must only pick it for x11)");
    }
}

const alloc = std.heap.c_allocator;

// getTime and the file dialogs (which need no display) live in common. They are re-exported to keep the public surface intact.
pub const getTime = common.getTime;
pub const saveFileDialog = common.saveFileDialog;
pub const openFileDialog = common.openFileDialog;

/// Display refresh via XRandR, loaded at runtime with `std.DynLib` (no link-time Xrandr dependency).
/// Returns null when libXrandr is missing, symbols are absent, or the rate is non-positive.
/// Queried once at startup (event-time), never per frame.
pub fn displayRefreshHz() ?f64 {
    const dpy = g_display orelse return null;
    var lib = std.DynLib.open("libXrandr.so.2") catch return null;
    defer lib.close();

    const XRRScreenConfiguration = opaque {};
    const GetScreenInfoFn = *const fn (?*c.Display, c.Window) callconv(.c) ?*XRRScreenConfiguration;
    const ConfigCurrentRateFn = *const fn (?*XRRScreenConfiguration) callconv(.c) c_short;
    const FreeScreenConfigInfoFn = *const fn (?*XRRScreenConfiguration) callconv(.c) void;

    const get_info = lib.lookup(GetScreenInfoFn, "XRRGetScreenInfo") orelse return null;
    const current_rate = lib.lookup(ConfigCurrentRateFn, "XRRConfigCurrentRate") orelse return null;
    const free_info = lib.lookup(FreeScreenConfigInfoFn, "XRRFreeScreenConfigInfo") orelse return null;

    const screen = c.XDefaultScreen(dpy);
    const root = c.XRootWindow(dpy, screen);
    const config = get_info(dpy, root) orelse return null;
    defer free_info(config);
    const rate = current_rate(config);
    if (rate <= 0) return null;
    return @floatFromInt(rate);
}

/// `XDestroyImage` is an Xlib macro (`(*((img)->f.destroy_image))(img)`), and @cImport translates the
/// optional function pointer without unwrapping it, so it cannot be called as it stands. The function pointer is invoked by hand.
inline fn destroyImage(img: *c.XImage) void {
    _ = img.f.destroy_image.?(img);
}

// ============================================================================
// init and shutdown (one Display per process)
// ============================================================================
var g_display: ?*c.Display = null;

/// Whether detectable auto-repeat could be enabled (a Display-scoped property). init settles it, and create copies it into State.
/// While it is on, a key repeat arrives as consecutive KeyPress events with no KeyRelease (which simplifies deciding is_repeat).
var g_detectable_repeat: bool = false;

pub fn init() Error!void {
    if (g_display != null) return;
    const dpy = c.XOpenDisplay(null) orelse return error.InitFailed;
    g_display = dpy;

    // The first choice for deciding is_repeat. With supported=true, "was it already down" in the KeyDownSet is enough.
    // Where it is unsupported, pollEvents switches to the KeyRelease→KeyPress look-ahead fallback.
    var supported: c.Bool = 0;
    _ = c.XkbSetDetectableAutoRepeat(dpy, 1, &supported);
    g_detectable_repeat = supported != 0;
}

pub fn shutdown() void {
    if (g_display) |d| {
        _ = c.XCloseDisplay(d);
        g_display = null;
    }
}

// ============================================================================
// A temporary X error handler for the XShm attach (it swallows BadAccess and BadShmSeg)
// ============================================================================
var g_shm_error: bool = false;

fn shmErrorHandler(d: ?*c.Display, e: ?*c.XErrorEvent) callconv(.c) c_int {
    _ = d;
    _ = e;
    g_shm_error = true;
    return 0;
}

// ============================================================================
// Window / State
// ============================================================================

const State = struct {
    display: *c.Display,
    window: c.Window,
    gc: c.GC,
    /// The logical size (the coordinates of the application and the GUI; the create argument, held independently rather than derived back through lround).
    logical_width: u32,
    logical_height: u32,
    /// The physical, framebuffer and real window pixel size (the unit of the blit, of present and of ConfigureNotify).
    /// Under `.logical` it equals the logical size; under `.physical` it is `roundToPhysicalPx(logical, scale)`.
    physical_width: u32,
    physical_height: u32,
    /// A backwards-compatible alias: the framebuffer size the existing blit path refers to == physical_*.
    width: u32,
    height: u32,
    fb_mode: FramebufferMode,
    /// For a query (making input raw, and `contentScale()`). X11 does not support a runtime change, so it stays equal to the latched value.
    pending_content_scale: f32,
    /// The latched value (the `lockFramebuffer` snapshot). It is settled at start-up and never changes afterwards (scale_epoch stays 0).
    content_scale: f32,
    scale_epoch: u64,
    wm_delete: c.Atom,
    // The visual and depth at creation are kept, so that a resize can run setupBlit again.
    visual: ?*c.Visual,
    depth: c_uint,

    // The canonical BGRA framebuffer (what the caller writes, and what lockFramebuffer returns).
    // direct: an alias of the image data (nothing extra is allocated). fallback: a separate allocation.
    backing: []u32,

    // blit
    image: *c.XImage,
    bytes_per_line: usize,
    use_shm: bool,
    shminfo: c.XShmSegmentInfo,
    shmat_ok: bool,
    attached: bool,
    // The Zig-owned image data buffer of the XPutImage path (unused on the shm path).
    // It is allocated as []u32 to guarantee u32 alignment (the image data is written or converted as a []u32).
    xfer: []u32,

    // Whether it can be written straight through (the result of classifyVisual). When true, present blits with no converting copy.
    direct: bool,
    // The pixel conversion shifts used by fallback (computed from the visual mask; unused by direct)
    r_shift: u5,
    g_shift: u5,
    b_shift: u5,

    // events
    closing: bool,
    quit_delivered: bool,
    queue: input.EventQueue, // The merging and the drop count are confined to the EventQueue (pure Zig, and testable)

    // The input state (what the backend tracks internally to build the post-state)
    buttons: MouseButtons, // the set of mouse buttons currently held
    keys: input.KeyDownSet, // the set of held keycodes (for is_repeat and the modifier post-state)
    detectable_repeat: bool, // a copy of g_detectable_repeat

    // The system cursors: an X11 Cursor is created lazily per CursorShape (default/crosshair/hidden)
    // and cached (0=None means it has not been created). destroy XFreeCursor's them.
    cursors: [3]c.Cursor = .{ 0, 0, 0 },

    // Transparency, borderless and click-through
    transparent: bool = false,
    borderless: bool = false,
    click_through: bool = false,
    colormap: c.Colormap = 0, // For the transparent ARGB visual (destroy XFreeColormap's it; 0 means none was created, i.e. the default visual)
    own_gc: bool = false, // Whether st.gc was made here with XCreateGC (for a transparent window; destroy XFreeGC's it)
    ct_region_valid: bool = false, // Whether the click-through input shape has been set (unset means the next present computes it once)

    fn enqueue(self: *State, ev: Event) void {
        self.queue.enqueue(ev);
    }

    fn dequeue(self: *State) ?Event {
        return self.queue.dequeue();
    }
};

pub const Window = struct {
    state: *State,

    /// The single window creation entry point of this backend (ADR-019 R1).
    /// Transparency needs a 32-bit ARGB visual (XMatchVisualInfo; without one it gives error.Unsupported) plus a colormap plus XCreateWindow.
    /// **Actually seeing through to what is behind needs a compositor (picom and the like).**
    /// Fullscreen sets the EWMH `_NET_WM_STATE_FULLSCREEN` property before the map, and resolves its
    /// own size, so the width and height are ignored in that case (ADR-019 R3).
    /// Hot path declaration: initialisation only.
    pub fn createWithOptions(width: u32, height: u32, title: [:0]const u8, opts: types.WindowOptions) Error!Window {
        return createInternal(width, height, title, opts.fullscreen, opts);
    }

    /// `width`/`height` are logical points, **except when `fullscreen` is set**: then they are
    /// ignored and the default screen's resolution is used instead, which X11 reports in physical
    /// pixels (ADR-019 R3, ADR-011 R11).
    fn createInternal(width: u32, height: u32, title: [:0]const u8, fullscreen: bool, opts: types.WindowOptions) Error!Window {
        const dpy = g_display orelse return error.WindowCreationFailed;
        if (width == 0 or height == 0) return error.WindowCreationFailed;

        const screen = c.XDefaultScreen(dpy);
        const root = c.XRootWindow(dpy, screen);
        // An explicit position is the client origin (in root coordinates). It is passed as the initial
        // coordinate of XCreate*, and WM_NORMAL_HINTS (PPosition + StaticGravity) is set below so the window
        // manager restores it on the same basis (which avoids a reparenting WM's decoration offset, or it ignoring the position).
        const init_x: c_int = if (opts.position) |p| p.x else 0;
        const init_y: c_int = if (opts.position) |p| p.y else 0;

        // Xft.dpi → content_scale (a failure gives 1.0). The real scale is kept whatever fb_mode is.
        const scale = queryXftContentScale(dpy);
        // Fullscreen resolves its own size, and the screen dimensions X11 reports are already
        // physical pixels, so the derivation runs the other way round: the window (and the
        // framebuffer) is the screen size verbatim and the logical size comes from dividing it. Not
        // doing so would apply the scale twice and ask for a window twice the size of the screen
        // (ADR-011 R11). Off fullscreen this is the ordinary direction: the arguments are logical
        // and `.physical` multiplies up, because X11 applies no scaling of its own.
        const screen_size: WindowSize = if (fullscreen) .{
            .width = @intCast(c.XDisplayWidth(dpy, screen)),
            .height = @intCast(c.XDisplayHeight(dpy, screen)),
        } else undefined;
        const logical: WindowSize = if (fullscreen)
            logicalSizeForPhysical(opts.fb_mode, screen_size, scale)
        else
            .{ .width = width, .height = height };
        const fb_size = if (fullscreen) screen_size else effectiveFramebufferSize(opts.fb_mode, logical, scale);
        if (fb_size.width == 0 or fb_size.height == 0) return error.WindowCreationFailed;
        const win_w = fb_size.width;
        const win_h = fb_size.height;

        var visual: ?*c.Visual = undefined;
        var depth: c_uint = undefined;
        var win: c.Window = undefined;
        var colormap: c.Colormap = 0;
        var own_gc = false;
        var gc: c.GC = undefined;

        if (opts.transparent) {
            // Look for a 32-bit ARGB TrueColor visual (without one there can be no transparency). It is built with a colormap plus XCreateWindow.
            var vinfo: c.XVisualInfo = undefined;
            if (c.XMatchVisualInfo(dpy, screen, 32, c.TrueColor, &vinfo) == 0) return error.Unsupported;
            // Keeping the alpha on the straight-through path of canonical BGRA (0xAARRGGBB) (classifyVisual=direct)
            // requires the standard ARGB layout (R=0xFF0000/G=0xFF00/B=0xFF). A non-standard shift would lose the
            // alpha in the fallback conversion (turning every pixel transparent), so it is rejected here as Unsupported.
            if (vinfo.visual.*.red_mask != 0xFF0000 or vinfo.visual.*.green_mask != 0x00FF00 or vinfo.visual.*.blue_mask != 0x0000FF) {
                return error.Unsupported;
            }
            visual = vinfo.visual;
            depth = 32;
            colormap = c.XCreateColormap(dpy, root, vinfo.visual, c.AllocNone);
            if (colormap == 0) return error.WindowCreationFailed;
            errdefer _ = c.XFreeColormap(dpy, colormap); // only the colormap is guarded inside this branch (it is allocated before win)
            var attrs = std.mem.zeroes(c.XSetWindowAttributes);
            attrs.colormap = colormap;
            attrs.border_pixel = 0;
            attrs.background_pixel = 0; // a transparent background
            attrs.event_mask = c.ExposureMask | c.StructureNotifyMask |
                c.KeyPressMask | c.KeyReleaseMask |
                c.ButtonPressMask | c.ButtonReleaseMask | c.PointerMotionMask;
            const valuemask: c_ulong = c.CWColormap | c.CWBorderPixel | c.CWBackPixel | c.CWEventMask;
            // Under `.physical` the window is created at the physical pixel size (X11 has no automatic OS scaling).
            win = c.XCreateWindow(dpy, root, init_x, init_y, @intCast(win_w), @intCast(win_h), 0, 32, c.InputOutput, vinfo.visual, valuemask, &attrs);
            if (win == 0) return error.WindowCreationFailed; // A failure up to here → the errdefer above frees the colormap
            // A 32-bit drawable needs a GC of a matching depth (the default GC is depth 24 and can give BadMatch).
            gc = c.XCreateGC(dpy, win, 0, null) orelse {
                _ = c.XDestroyWindow(dpy, win);
                return error.WindowCreationFailed; // the colormap is freed by the errdefer
            };
            own_gc = true;
        } else {
            visual = c.XDefaultVisual(dpy, screen);
            if (visual == null) return error.WindowCreationFailed;
            depth = @intCast(c.XDefaultDepth(dpy, screen));
            const black = c.XBlackPixel(dpy, screen);
            // The default visual is required to be TrueColor (DirectColor and the like assume a colormap and are unsupported)
            if (visual.?.class != c.TrueColor) return error.WindowCreationFailed;
            win = c.XCreateSimpleWindow(dpy, root, init_x, init_y, @intCast(win_w), @intCast(win_h), 0, black, black);
            gc = c.XDefaultGC(dpy, screen);
        }
        // A later failure (setupBlit, alloc.create and so on) frees win, the GC and the colormap together (which prevents leaking what transparency allocated).
        // On success State owns them and destroy() frees them, so this errdefer never fires. Without transparency
        // own_gc=false and colormap=0, so only XDestroyWindow runs (as before).
        errdefer {
            if (own_gc) _ = c.XFreeGC(dpy, gc);
            _ = c.XDestroyWindow(dpy, win);
            if (colormap != 0) _ = c.XFreeColormap(dpy, colormap);
        }

        _ = c.XStoreName(dpy, win, title.ptr);
        _ = c.XSelectInput(dpy, win, c.ExposureMask | c.StructureNotifyMask |
            c.KeyPressMask | c.KeyReleaseMask |
            c.ButtonPressMask | c.ButtonReleaseMask | c.PointerMotionMask);

        var wm_delete = c.XInternAtom(dpy, "WM_DELETE_WINDOW", 0);
        _ = c.XSetWMProtocols(dpy, win, &wm_delete, 1);

        if (fullscreen) {
            // EWMH: setting _NET_WM_STATE_FULLSCREEN on _NET_WM_STATE before the map makes a conforming window
            // manager go properly full screen, undecorated, at map time (with no need to send a ClientMessage
            // afterwards). An element of format=32 is an Atom (a c_ulong, which is long-wide on 64-bit).
            const net_wm_state = c.XInternAtom(dpy, "_NET_WM_STATE", 0);
            var fullscreen_atom = c.XInternAtom(dpy, "_NET_WM_STATE_FULLSCREEN", 0);
            _ = c.XChangeProperty(dpy, win, net_wm_state, c.XA_ATOM, 32, c.PropModeReplace, @ptrCast(&fullscreen_atom), 1);
        } else {
            // Resizable. Only a minimum size is given, and no maximum (so it resizes freely).
            // With an explicit position, PPosition and PWinGravity=StaticGravity are set together, which puts
            // saving (the client origin, in root coordinates) and restoring on the same basis.
            var hints = std.mem.zeroes(c.XSizeHints);
            hints.flags = c.PMinSize;
            hints.min_width = 1;
            hints.min_height = 1;
            if (opts.position) |p| {
                hints.flags |= c.PPosition | c.PWinGravity;
                hints.x = p.x;
                hints.y = p.y;
                hints.win_gravity = c.StaticGravity;
            }
            _ = c.XSetWMNormalHints(dpy, win, &hints);
        }

        // borderless drops the decoration through _MOTIF_WM_HINTS and hides the window from the taskbar and pager (for a mascot).
        if (opts.borderless) {
            const motif = c.XInternAtom(dpy, "_MOTIF_WM_HINTS", 0);
            // MotifWmHints: [flags, functions, decorations, input_mode, status]. flags=MWM_HINTS_DECORATIONS(1<<1) and decorations=0.
            var mwm = [5]c_ulong{ 2, 0, 0, 0, 0 };
            _ = c.XChangeProperty(dpy, win, motif, motif, 32, c.PropModeReplace, @ptrCast(&mwm), 5);
            const net_wm_state = c.XInternAtom(dpy, "_NET_WM_STATE", 0);
            var skip = [2]c.Atom{
                c.XInternAtom(dpy, "_NET_WM_STATE_SKIP_TASKBAR", 0),
                c.XInternAtom(dpy, "_NET_WM_STATE_SKIP_PAGER", 0),
            };
            _ = c.XChangeProperty(dpy, win, net_wm_state, c.XA_ATOM, 32, c.PropModeReplace, @ptrCast(&skip), 2);
        }

        const st = alloc.create(State) catch return error.WindowCreationFailed;
        errdefer alloc.destroy(st);

        st.* = .{
            .display = dpy,
            .window = win,
            .gc = gc,
            .logical_width = logical.width,
            .logical_height = logical.height,
            .physical_width = win_w,
            .physical_height = win_h,
            .width = win_w,
            .height = win_h,
            .fb_mode = opts.fb_mode,
            .pending_content_scale = scale,
            .content_scale = scale,
            .scale_epoch = 0,
            .wm_delete = wm_delete,
            .visual = visual,
            .depth = depth,
            .transparent = opts.transparent,
            .borderless = opts.borderless,
            .colormap = colormap,
            .own_gc = own_gc,
            .backing = &.{},
            .image = undefined,
            .bytes_per_line = 0,
            .use_shm = false,
            .shminfo = std.mem.zeroes(c.XShmSegmentInfo),
            .shmat_ok = false,
            .attached = false,
            .xfer = &.{},
            .direct = false,
            .r_shift = 0,
            .g_shift = 0,
            .b_shift = 0,
            .closing = false,
            .quit_delivered = false,
            .queue = .{},
            .buttons = .{},
            .keys = .{},
            .detectable_repeat = g_detectable_repeat,
        };

        // Set up the blit (shm when XShm is available, XPutImage when it is not or it fails).
        // The visual classification decides direct or fallback, and settles st.backing (the canonical BGRA the caller writes).
        // Under `.physical` it is allocated at the physical pixel size.
        try setupBlit(st, visual, depth, win_w, win_h);

        // The map happens only once the blit is ready (so it is never mapped for an instant and then fails)
        _ = c.XMapWindow(dpy, win);
        _ = c.XFlush(dpy);
        return .{ .state = st };
    }

    pub fn destroy(self: Window) void {
        const st = self.state;
        const dpy = st.display;

        teardownBlit(st);
        // The system cursors: free the cached Cursors.
        for (st.cursors) |cur| {
            if (cur != 0) _ = c.XFreeCursor(dpy, cur);
        }
        if (st.own_gc) _ = c.XFreeGC(dpy, st.gc); // Free the GC made by hand for a transparent window
        _ = c.XDestroyWindow(dpy, st.window);
        if (st.colormap != 0) _ = c.XFreeColormap(dpy, st.colormap); // Free the transparent ARGB colormap
        // The fallback backing is a separate allocation. The direct backing is an alias of the image data and has already been freed by teardownBlit.
        if (!st.direct) alloc.free(st.backing);
        alloc.destroy(st);
    }

    pub fn pollEvents(self: Window) bool {
        const st = self.state;
        const dpy = st.display;
        // A loop that checks XPending every time (rather than taking a snapshot of a fixed count), so that the
        // KeyRelease repeat fallback consuming one extra event through XNextEvent cannot leave the count out of step and block.
        while (c.XPending(dpy) > 0) {
            var ev: c.XEvent = undefined;
            _ = c.XNextEvent(dpy, &ev);
            switch (ev.type) {
                c.ClientMessage => {
                    // WM_DELETE_WINDOW
                    const atom: c.Atom = @intCast(ev.xclient.data.l[0]);
                    if (atom == st.wm_delete and !st.closing) {
                        st.closing = true;
                        st.enqueue(.quit);
                    }
                },
                c.ConfigureNotify => {
                    // Free resizing. The blit is reallocated at the new size, in two phases.
                    // pollEvents is called at a frame boundary (outside a lock), so reallocating there is safe.
                    // The width and height of a ConfigureNotify are the real window pixel size
                    // (created at the logical size under `.logical`, at the physical size under `.physical`), so they are the physical size as they stand.
                    const cw: u32 = @intCast(ev.xconfigure.width);
                    const ch: u32 = @intCast(ev.xconfigure.height);
                    applyConfigureSize(st, cw, ch);
                },
                c.Expose => {}, // present is called every frame, so this is a no-op
                c.KeyPress => handleKeyPress(st, &ev.xkey),
                c.KeyRelease => handleKeyRelease(st, dpy, &ev.xkey),
                c.ButtonPress => handleButtonPress(st, &ev.xbutton),
                c.ButtonRelease => handleButtonRelease(st, &ev.xbutton),
                c.MotionNotify => handleMotion(st, &ev.xmotion),
                else => {},
            }
        }
        return !st.quit_delivered;
    }

    pub fn nextEvent(self: Window) ?Event {
        const st = self.state;
        const ev = st.dequeue() orelse return null;
        if (ev == .quit) st.quit_delivered = true;
        return ev;
    }

    /// Release the close latch once the consumer has handled the quit event.
    /// Hot path declaration: quit/close events only.
    pub fn cancelQuit(self: Window) void {
        self.state.closing = false;
        self.state.quit_delivered = false;
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
        // X11 does not support a runtime scale change, so the latch keeps its start-up value (applying it is the identity).
        // The two-mode structure of query and latched is kept, to match the other backends.
        const scale = effectiveContentScale(st.content_scale);
        const logical: WindowSize = .{ .width = st.logical_width, .height = st.logical_height };
        const fb_size: WindowSize = .{ .width = st.physical_width, .height = st.physical_height };
        return .{
            .pixels = st.backing,
            .width = st.physical_width,
            .height = st.physical_height,
            .logical_size = logical,
            .framebuffer_size = fb_size,
            .content_scale = scale,
            .scale_epoch = st.scale_epoch,
            .state = st,
        };
    }

    /// The currently negotiated logical size. Drawing within a frame uses the Framebuffer snapshot.
    pub fn logicalSize(self: Window) WindowSize {
        const st = self.state;
        return .{ .width = st.logical_width, .height = st.logical_height };
    }

    /// The currently negotiated framebuffer size (in physical pixels; equal to the logical one under `.logical`).
    pub fn framebufferSize(self: Window) WindowSize {
        const st = self.state;
        return .{ .width = st.physical_width, .height = st.physical_height };
    }

    /// The currently negotiated content scale (from the real Xft.dpi whether `.logical` or `.physical`; 1.0 on failure).
    pub fn contentScale(self: Window) f32 {
        return effectiveContentScale(self.state.pending_content_scale);
    }

    pub fn present(self: Window) void {
        const st = self.state;
        const dpy = st.display;
        if (st.click_through and !st.ct_region_valid) refreshInputShape(st); // once only, after it is turned on
        // direct has the caller writing the image data itself, so nothing is converted. Only fallback converts the backing into the image data.
        if (!st.direct) convert(st);
        const w: c_uint = @intCast(st.width);
        const h: c_uint = @intCast(st.height);
        if (st.use_shm) {
            _ = c.XShmPutImage(dpy, st.window, st.gc, st.image, 0, 0, 0, 0, w, h, 0);
        } else {
            _ = c.XPutImage(dpy, st.window, st.gc, st.image, 0, 0, 0, 0, w, h);
        }
        _ = c.XFlush(dpy);
    }

    /// Ask the window manager for an interactive window move (_NET_WM_MOVERESIZE). It ungrabs the press and
    /// sends a ClientMessage to root carrying the pointer's current root coordinates, the button and the source.
    /// Hot path declaration: event time only.
    pub fn beginDrag(self: Window) void {
        const st = self.state;
        const dpy = st.display;
        const screen = c.XDefaultScreen(dpy);
        const root = c.XRootWindow(dpy, screen);
        // Read the pointer's root coordinates.
        var rret: c.Window = undefined;
        var cret: c.Window = undefined;
        var rx: c_int = 0;
        var ry: c_int = 0;
        var wx: c_int = 0;
        var wy: c_int = 0;
        var mask: c_uint = 0;
        _ = c.XQueryPointer(dpy, st.window, &rret, &cret, &rx, &ry, &wx, &wy, &mask);
        _ = c.XUngrabPointer(dpy, c.CurrentTime); // ungrab the press and hand the move to the window manager
        const net = c.XInternAtom(dpy, "_NET_WM_MOVERESIZE", 0);
        var ev = std.mem.zeroes(c.XEvent);
        ev.xclient.type = c.ClientMessage;
        ev.xclient.window = st.window;
        ev.xclient.message_type = net;
        ev.xclient.format = 32;
        ev.xclient.data.l[0] = rx; // x_root
        ev.xclient.data.l[1] = ry; // y_root
        ev.xclient.data.l[2] = 8; // _NET_WM_MOVERESIZE_MOVE
        ev.xclient.data.l[3] = 1; // button 1 (left)
        ev.xclient.data.l[4] = 1; // source indication = application
        _ = c.XSendEvent(dpy, root, 0, c.SubstructureRedirectMask | c.SubstructureNotifyMask, &ev);
        _ = c.XFlush(dpy);
    }

    /// Always-on-top (an add/remove ClientMessage for _NET_WM_STATE_ABOVE). It depends on the window manager (and degrades gracefully).
    /// Hot path declaration: event time only.
    pub fn setAlwaysOnTop(self: Window, on: bool) void {
        const st = self.state;
        const dpy = st.display;
        const screen = c.XDefaultScreen(dpy);
        const root = c.XRootWindow(dpy, screen);
        const net_state = c.XInternAtom(dpy, "_NET_WM_STATE", 0);
        const above = c.XInternAtom(dpy, "_NET_WM_STATE_ABOVE", 0);
        var ev = std.mem.zeroes(c.XEvent);
        ev.xclient.type = c.ClientMessage;
        ev.xclient.window = st.window;
        ev.xclient.message_type = net_state;
        ev.xclient.format = 32;
        ev.xclient.data.l[0] = if (on) 1 else 0; // _NET_WM_STATE_ADD / REMOVE
        ev.xclient.data.l[1] = @intCast(above);
        ev.xclient.data.l[2] = 0;
        ev.xclient.data.l[3] = 1; // source = application
        _ = c.XSendEvent(dpy, root, 0, c.SubstructureRedirectMask | c.SubstructureNotifyMask, &ev);
        _ = c.XFlush(dpy);
    }

    /// Click-through (the input shape of the X Shape extension). While on, the next present sets the bounding
    /// box of the opaque pixels as the input shape, so a click on the transparent margin falls through. Off restores the input shape to the whole window.
    /// Hot path declaration: event time only (the bounding box scan in present runs once after it is turned on, gated by ct_region_valid).
    pub fn setClickThrough(self: Window, on: bool) void {
        const st = self.state;
        st.click_through = on;
        st.ct_region_valid = false; // re-enabling scans the silhouette again (on the next present)
        if (!on) {
            // Restore the input shape to the whole window (a NULL region, which matches the bounding shape).
            c.XShapeCombineMask(st.display, st.window, c.ShapeInput, 0, 0, 0, c.ShapeSet);
            _ = c.XFlush(st.display);
        }
    }

    /// Set the cursor shape. A Cursor is created lazily and cached per CursorShape, and applied with XDefineCursor.
    /// Call frequency: event time only (a tool change, a key press), so the performance rules do not apply.
    /// A failed creation is a best-effort no-op (it breaks neither the drawing nor the run).
    pub fn setCursor(self: Window, shape: types.CursorShape) void {
        const st = self.state;
        const idx: usize = @intCast(@intFromEnum(shape));
        if (idx >= st.cursors.len) return; // a non-exhaustive value is ignored
        if (st.cursors[idx] == 0) st.cursors[idx] = createCursor(st, shape);
        const cur = st.cursors[idx];
        if (cur == 0) return; // creation failed
        _ = c.XDefineCursor(st.display, st.window, cur);
        _ = c.XFlush(st.display);
    }

    /// Update the visible title. Event time only.
    pub fn setTitle(self: Window, title: [:0]const u8) void {
        _ = c.XStoreName(self.state.display, self.state.window, title.ptr);
        _ = c.XFlush(self.state.display);
    }

    /// The live-resize redraw callback. X11 has no modal loop and is live to begin with, so this is a no-op stub.
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

/// The current window geometry.
/// The position is the client origin in root coordinates (XTranslateCoordinates). On failure it is position=null.
/// The size is the **logical** content (`logical_width/height`). Restoring uses the same basis, through WM_NORMAL_HINTS's StaticGravity.
/// Module level (the facade's `@hasDecl(backend, "getGeometry")` contract; a Window method would not do).
pub fn getGeometry(win: Window) types.WindowGeometry {
    const st = win.state;
    var root_x: c_int = 0;
    var root_y: c_int = 0;
    var child: c.Window = undefined;
    const ok = c.XTranslateCoordinates(st.display, st.window, c.XDefaultRootWindow(st.display), 0, 0, &root_x, &root_y, &child);
    return .{
        .position = if (ok != 0) .{ .x = root_x, .y = root_y } else null,
        .size = .{ .width = st.logical_width, .height = st.logical_height },
    };
}

/// Create an X11 Cursor for a CursorShape (0=None on failure). default and crosshair come from the
/// standard cursor font, and hidden is a transparent 1x1 pixmap cursor.
fn createCursor(st: *State, shape: types.CursorShape) c.Cursor {
    return switch (shape) {
        .default => c.XCreateFontCursor(st.display, c.XC_left_ptr),
        .crosshair => c.XCreateFontCursor(st.display, c.XC_crosshair),
        .hidden => createHiddenCursor(st),
    };
}

/// The transparent cursor: a 1x1 bitmap of all-zero bits serves as both source and mask for XCreatePixmapCursor.
fn createHiddenCursor(st: *State) c.Cursor {
    var data = [_]u8{0};
    const bmp = c.XCreateBitmapFromData(st.display, st.window, &data, 1, 1);
    if (bmp == 0) return 0;
    defer _ = c.XFreePixmap(st.display, bmp);
    var col = std.mem.zeroes(c.XColor);
    return c.XCreatePixmapCursor(st.display, bmp, bmp, &col, &col, 0, 0);
}

/// A locked framebuffer view (the public contract is canonical BGRA `[]u32`, u32 0xAARRGGBB).
/// In direct mode pixels points straight at the XImage or shm buffer (present copies nothing).
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
        _ = self; // the conversion happens at present time, so unlock itself is a no-op
    }
};

// ============================================================================
// Translating input events (an XEvent → a platform.Event). The pure logic lives in platform_linux_input.zig.
// ============================================================================

fn handleKeyPress(st: *State, e: *c.XKeyEvent) void {
    const keycode: u32 = @intCast(e.keycode);
    // With detectable auto-repeat on, a repeat arrives as consecutive KeyPress events with no KeyRelease.
    // "Was it already down" therefore is is_repeat (where it is unsupported, the fallback in handleKeyRelease generates the repeat directly).
    const was_down = st.keys.isDown(keycode);
    st.keys.setDown(keycode, true); // the modifier post-state is computed after the set has been updated
    const mods = input.keyEventModifiers(@intCast(e.state), &st.keys, keycode);
    st.enqueue(.{ .key_down = .{
        .key = input.keycodeToKeyCode(keycode),
        .is_repeat = was_down,
        .modifiers = mods,
    } });
    // A committed character: XLookupString takes it and emits char_input. Latin-1 is enough for alphanumerics
    // (UTF-8 and CJK would need XIM or Xutf8LookupString, which is future scope). The key_down path above is unchanged.
    var cbuf: [8]u8 = undefined;
    var keysym: c.KeySym = undefined;
    const n = c.XLookupString(e, &cbuf, cbuf.len, &keysym, null);
    if (n > 0) {
        var i: usize = 0;
        while (i < @as(usize, @intCast(n))) : (i += 1) {
            const cp: u32 = cbuf[i]; // Latin-1 codepoint
            if (input.isTextCodepoint(cp)) {
                st.enqueue(.{ .char_input = .{ .codepoint = cp, .modifiers = mods } });
            }
        }
    }
}

fn handleKeyRelease(st: *State, dpy: *c.Display, e: *c.XKeyEvent) void {
    const keycode: u32 = @intCast(e.keycode);

    // The repeat fallback where auto-repeat is not detectable: when a KeyPress for the same keycode and the
    // same time is waiting right behind a KeyRelease, that is a repeat (the key was never let go). The release
    // is swallowed and that KeyPress is really consumed and emitted with is_repeat=true (a peek does not consume it).
    if (!st.detectable_repeat and c.XPending(dpy) > 0) {
        var next: c.XEvent = undefined;
        _ = c.XPeekEvent(dpy, &next);
        if (next.type == c.KeyPress and next.xkey.keycode == e.keycode and next.xkey.time == e.time) {
            _ = c.XNextEvent(dpy, &next); // really consume the KeyPress that was peeked at
            // keys stays down (it was never released).
            const rmods = input.keyEventModifiers(@intCast(next.xkey.state), &st.keys, keycode);
            st.enqueue(.{ .key_down = .{
                .key = input.keycodeToKeyCode(keycode),
                .is_repeat = true,
                .modifiers = rmods,
            } });
            // char_input is emitted during a repeat too (so holding a key types). The consumed KeyPress goes through
            // XLookupString (Ctrl+A and the like become control characters and fall out naturally in isTextCodepoint).
            var cbuf: [8]u8 = undefined;
            var ksym: c.KeySym = undefined;
            const rn = c.XLookupString(&next.xkey, &cbuf, cbuf.len, &ksym, null);
            if (rn > 0) {
                var i: usize = 0;
                while (i < @as(usize, @intCast(rn))) : (i += 1) {
                    const cp: u32 = cbuf[i];
                    if (input.isTextCodepoint(cp)) {
                        st.enqueue(.{ .char_input = .{ .codepoint = cp, .modifiers = rmods } });
                    }
                }
            }
            return;
        }
    }

    // an ordinary release
    st.keys.setDown(keycode, false);
    st.enqueue(.{ .key_up = .{
        .key = input.keycodeToKeyCode(keycode),
        .is_repeat = false,
        .modifiers = input.keyEventModifiers(@intCast(e.state), &st.keys, keycode),
    } });
}

fn setButton(st: *State, mb: MouseButton, down: bool) void {
    switch (mb) {
        .left => st.buttons.left = down,
        .right => st.buttons.right = down,
        .middle => st.buttons.middle = down,
        else => {},
    }
}

/// Build a MouseEvent. buttons comes from the internal tracking (the post-state), and modifiers from the state mask (a mouse event does not change a modifier).
/// The coordinates are raw physical (the facade normalises them into logical with the latched content_scale).
/// The X11 contract: `.logical` → `native × content_scale`, `.physical` → `native` (with no multiplication).
fn mouseEvent(st: *State, x: c_int, y: c_int, button: MouseButton, state: u32) MouseEvent {
    const raw = nativeToRawPhysical(st, x, y);
    return .{
        .x = raw.x,
        .y = raw.y,
        .button = button,
        .buttons = st.buttons,
        .modifiers = input.stateToModifiers(state),
    };
}

/// X11 native (real window pixel coordinates) → raw physical event coordinates.
fn nativeToRawPhysical(st: *const State, native_x: c_int, native_y: c_int) struct { x: i32, y: i32 } {
    if (st.fb_mode == .physical) {
        return .{ .x = native_x, .y = native_y };
    }
    // `.logical`: the window is at the logical size, so native is a logical value. It is multiplied into raw physical, which pairs with the facade's normalisation.
    const s = effectiveContentScale(st.pending_content_scale);
    return .{
        .x = @intFromFloat(@floor(@as(f64, @floatFromInt(native_x)) * @as(f64, s))),
        .y = @intFromFloat(@floor(@as(f64, @floatFromInt(native_y)) * @as(f64, s))),
    };
}

fn handleButtonPress(st: *State, e: *c.XButtonEvent) void {
    const button: u32 = @intCast(e.button);
    if (input.buttonToMouseButton(button)) |mb| {
        setButton(st, mb, true); // bring it to the post-state (the press included) before building the event
        st.enqueue(.{ .mouse_down = mouseEvent(st, e.x, e.y, mb, @intCast(e.state)) });
    } else if (input.wheelDelta(button)) |d| {
        const raw = nativeToRawPhysical(st, e.x, e.y);
        st.enqueue(.{ .mouse_scroll = .{
            .x = raw.x,
            .y = raw.y,
            .dx = d.dx,
            .dy = d.dy,
            .is_precise = false,
            .buttons = st.buttons,
            .modifiers = input.stateToModifiers(@intCast(e.state)),
        } });
    }
    // any other button is ignored
}

fn handleButtonRelease(st: *State, e: *c.XButtonEvent) void {
    const button: u32 = @intCast(e.button);
    if (input.buttonToMouseButton(button)) |mb| {
        setButton(st, mb, false); // bring it to the post-state (the release applied) before building the event
        st.enqueue(.{ .mouse_up = mouseEvent(st, e.x, e.y, mb, @intCast(e.state)) });
    }
    // the Release of a wheel (4-7) is ignored
}

fn handleMotion(st: *State, e: *c.XMotionEvent) void {
    st.enqueue(.{ .mouse_move = mouseEvent(st, e.x, e.y, .none, @intCast(e.state)) });
}

// ============================================================================
// Setting up the blit, and the pixel conversion
// ============================================================================

/// For click-through, build a **per-pixel 1-bit mask** out of the opaque pixels (alpha>0) and set it as
/// the X Shape input shape (a click on a transparent pixel, alpha 0, falls through exactly, and the opaque artwork receives clicks).
/// A bounding box would let the window catch the transparent corners of a round picture too (click-through would not work), hence a per-pixel mask.
/// It is gated by ct_region_valid and runs once after it is turned on (never an all-pixel loop per frame, which keeps the performance rules).
/// The alpha of canonical BGRA is the top 8 bits. XCreateBitmapFromData is LSB-first and pads each row to a byte boundary.
fn refreshInputShape(st: *State) void {
    const w = st.width;
    const h = st.height;
    const px = st.backing;
    if (px.len < @as(usize, w) * @as(usize, h)) return;
    const stride = (w + 7) / 8; // the bytes per row (8px per byte, padded to a byte boundary)
    const data = alloc.alloc(u8, @as(usize, stride) * @as(usize, h)) catch return;
    defer alloc.free(data);
    @memset(data, 0);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = @as(usize, y) * @as(usize, w);
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            if ((px[row + x] >> 24) != 0) { // an opaque pixel → set the bit (this pixel receives clicks)
                data[@as(usize, y) * @as(usize, stride) + (x >> 3)] |= (@as(u8, 1) << @intCast(x & 7));
            }
        }
    }
    const bmp = c.XCreateBitmapFromData(st.display, st.window, @ptrCast(data.ptr), @intCast(w), @intCast(h));
    if (bmp == 0) return; // on failure valid is left unset and the next present retries
    c.XShapeCombineMask(st.display, st.window, c.ShapeInput, 0, 0, bmp, c.ShapeSet);
    _ = c.XFreePixmap(st.display, bmp);
    _ = c.XFlush(st.display);
    st.ct_region_valid = true;
}

fn setupBlit(st: *State, visual: ?*c.Visual, depth: c_uint, width: u32, height: u32) Error!void {
    const dpy = st.display;

    // Try the shm path when XShm is available.
    // Setting the environment variable KNGN_DISABLE_XSHM skips XShm and forces the XPutImage path
    // (which is how the fallback is checked in an environment where XShm does work).
    const disable_shm = std.c.getenv("KNGN_DISABLE_XSHM") != null;
    if (!disable_shm and c.XShmQueryExtension(dpy) != 0) {
        if (trySetupShm(st, visual, depth, width, height)) {
            try classifyAndSetupBacking(st, width, height);
            return;
        }
        // failed → fall back
    }
    try setupPutImage(st, visual, depth, width, height);
    try classifyAndSetupBacking(st, width, height);
}

/// The XShm path. true on success, false when it should fall back.
fn trySetupShm(st: *State, visual: ?*c.Visual, depth: c_uint, width: u32, height: u32) bool {
    const dpy = st.display;
    // shminfo stays referenced by the image and by the X server, so the stable address (st.shminfo, on the heap) is used directly.
    // Passing a local would leave it dangling after the function returns, and XShmPutImage would give BadShmSeg.
    st.shminfo = std.mem.zeroes(c.XShmSegmentInfo);

    const image = c.XShmCreateImage(dpy, visual, depth, c.ZPixmap, null, &st.shminfo, @intCast(width), @intCast(height)) orelse return false;

    const bpl: c_int = image.*.bytes_per_line;
    if (bpl <= 0) {
        destroyImage(image);
        return false;
    }
    const size = std.math.mul(usize, @intCast(bpl), height) catch {
        destroyImage(image);
        return false;
    };

    const shmid = c.shmget(c.IPC_PRIVATE, @intCast(size), c.IPC_CREAT | 0o600);
    if (shmid < 0) {
        destroyImage(image);
        return false;
    }
    st.shminfo.shmid = shmid;

    const addr = c.shmat(shmid, null, 0);
    if (@intFromPtr(addr) == @as(usize, @bitCast(@as(isize, -1)))) {
        _ = c.shmctl(shmid, c.IPC_RMID, null);
        destroyImage(image);
        return false;
    }
    st.shminfo.shmaddr = @ptrCast(addr);
    image.*.data = @ptrCast(addr);
    st.shminfo.readOnly = 0;

    // Drain any outstanding X error before swapping the handler in (which prevents a false positive in the attach check)
    _ = c.XSync(dpy, 0);
    g_shm_error = false;
    const old = c.XSetErrorHandler(shmErrorHandler);
    _ = c.XShmAttach(dpy, &st.shminfo);
    _ = c.XSync(dpy, 0);
    _ = c.XSetErrorHandler(old);

    if (g_shm_error) {
        // attach failed: XShmDetach is not called
        _ = c.shmdt(st.shminfo.shmaddr);
        _ = c.shmctl(st.shminfo.shmid, c.IPC_RMID, null);
        image.*.data = null;
        destroyImage(image);
        return false;
    }

    // attach succeeded → mark it "deleted automatically on the last detach" (exactly once, here)
    _ = c.shmctl(st.shminfo.shmid, c.IPC_RMID, null);

    st.image = image;
    st.shmat_ok = true;
    st.attached = true;
    st.use_shm = true;
    st.bytes_per_line = @intCast(bpl);
    return true;
}

/// The XPutImage path (when XShm is unavailable or failed). The data belongs to Zig.
fn setupPutImage(st: *State, visual: ?*c.Visual, depth: c_uint, width: u32, height: u32) Error!void {
    const dpy = st.display;
    // created with data=null, which settles bytes_per_line
    const image = c.XCreateImage(dpy, visual, depth, c.ZPixmap, 0, null, @intCast(width), @intCast(height), 32, 0) orelse return error.WindowCreationFailed;

    const bpl: c_int = image.*.bytes_per_line;
    if (bpl <= 0) {
        destroyImage(image);
        return error.WindowCreationFailed;
    }
    const size = std.math.mul(usize, @intCast(bpl), height) catch {
        destroyImage(image);
        return error.WindowCreationFailed;
    };

    // The image data is aliased as a []u32 (direct) or written through a conversion (fallback), so it is
    // allocated in u32 units and the alignment is guaranteed by the type. The size is rounded up to a count of u32 (>= size bytes).
    const u32_len = (size + 3) / 4;
    const buf = alloc.alloc(u32, u32_len) catch {
        destroyImage(image);
        return error.WindowCreationFailed;
    };
    @memset(buf, 0);
    image.*.data = @ptrCast(buf.ptr);

    st.image = image;
    st.xfer = buf;
    st.use_shm = false;
    st.bytes_per_line = @intCast(bpl);
}

/// After the XImage is created, classifyVisual classifies the visual and settles the direct or fallback backing.
/// fail (not 32bpp, MSBFirst, a non-contiguous or overlapping mask, 16/24bpp, 565 and so on) gives WindowCreationFailed.
fn classifyAndSetupBacking(st: *State, width: u32, height: u32) Error!void {
    const img = st.image;
    const bpp: u32 = @intCast(img.*.bits_per_pixel);
    const byte_order: conv.ByteOrder = if (img.*.byte_order == c.MSBFirst) .msb_first else .lsb_first;
    const rm: u64 = img.*.red_mask;
    const gm: u64 = img.*.green_mask;
    const bm: u64 = img.*.blue_mask;

    const px_count = std.math.mul(usize, width, height) catch return failBlit(st);

    switch (conv.classifyVisual(bpp, byte_order, st.bytes_per_line, width, rm, gm, bm)) {
        .fail => return failBlit(st),
        .direct => {
            // A standard visual: the low 24 bits match 0x00RRGGBB, so the caller writes the image data itself (with no converting copy).
            // The backing is an alias of the image data (nothing extra is allocated).
            st.direct = true;
            const base: [*]u32 = @ptrCast(@alignCast(img.*.data));
            st.backing = base[0..px_count];
            @memset(st.backing, 0);
        },
        .fallback => {
            // A non-standard shift or stride padding: a separate backing (BGRA) is kept and converted by packPixel at present time.
            st.direct = false;
            st.r_shift = conv.maskShift(rm) orelse return failBlit(st);
            st.g_shift = conv.maskShift(gm) orelse return failBlit(st);
            st.b_shift = conv.maskShift(bm) orelse return failBlit(st);
            const buf = alloc.alloc(u32, px_count) catch return failBlit(st);
            @memset(buf, 0);
            st.backing = buf;
        },
    }
}

/// Free the blit resources (the XImage, and either the XShm segment or the Zig-owned transfer buffer). Shared by `destroy` and `failBlit`.
/// RMID was already done when the attach succeeded, so it is not done here.
fn teardownBlit(st: *State) void {
    if (st.use_shm) {
        if (st.attached) _ = c.XShmDetach(st.display, &st.shminfo);
        destroyImage(st.image);
        if (st.shmat_ok) _ = c.shmdt(st.shminfo.shmaddr);
    } else {
        // The XPutImage path: the image data belongs to Zig (st.xfer). XDestroyImage must not free it.
        st.image.data = null;
        destroyImage(st.image);
        if (st.xfer.len != 0) alloc.free(st.xfer);
    }
}

fn failBlit(st: *State) Error {
    // When the checks fail, the blit resources already allocated are freed before the failure is returned
    // (the backing is not settled yet and needs no freeing, and create's errdefer frees the window and the State).
    teardownBlit(st);
    return error.WindowCreationFailed;
}

// ── Resizing. Two-phase: the old blit is freed only once the new one has been allocated ──

/// A snapshot of the blit fields. It is what makes the resize two-phase (allocate the new, free the old; restore the old on failure).
const BlitState = struct {
    backing: []u32,
    image: *c.XImage,
    bytes_per_line: usize,
    use_shm: bool,
    shminfo: c.XShmSegmentInfo,
    shmat_ok: bool,
    attached: bool,
    xfer: []u32,
    direct: bool,
    r_shift: u5,
    g_shift: u5,
    b_shift: u5,
};

fn captureBlit(st: *const State) BlitState {
    return .{
        .backing = st.backing,
        .image = st.image,
        .bytes_per_line = st.bytes_per_line,
        .use_shm = st.use_shm,
        .shminfo = st.shminfo,
        .shmat_ok = st.shmat_ok,
        .attached = st.attached,
        .xfer = st.xfer,
        .direct = st.direct,
        .r_shift = st.r_shift,
        .g_shift = st.g_shift,
        .b_shift = st.b_shift,
    };
}

fn restoreBlit(st: *State, b: BlitState) void {
    st.backing = b.backing;
    st.image = b.image;
    st.bytes_per_line = b.bytes_per_line;
    st.use_shm = b.use_shm;
    st.shminfo = b.shminfo;
    st.shmat_ok = b.shmat_ok;
    st.attached = b.attached;
    st.xfer = b.xfer;
    st.direct = b.direct;
    st.r_shift = b.r_shift;
    st.g_shift = b.g_shift;
    st.b_shift = b.b_shift;
}

/// Free the resources of a BlitState (a snapshot value). The value form of teardownBlit, plus freeing the fallback backing.
fn freeBlitState(dpy: *c.Display, b: *BlitState) void {
    if (b.use_shm) {
        if (b.attached) _ = c.XShmDetach(dpy, &b.shminfo);
        destroyImage(b.image);
        if (b.shmat_ok) _ = c.shmdt(b.shminfo.shmaddr);
    } else {
        b.image.data = null;
        destroyImage(b.image);
        if (b.xfer.len != 0) alloc.free(b.xfer);
    }
    // The fallback backing is a separate allocation. The direct backing is an alias of the image data and was freed above.
    if (!b.direct and b.backing.len != 0) alloc.free(b.backing);
}

/// Apply the real window pixel size of a ConfigureNotify to logical and physical, and reallocate the blit.
/// Hot path declaration: resize events only.
fn applyConfigureSize(st: *State, new_phys_w: u32, new_phys_h: u32) void {
    if (new_phys_w == 0 or new_phys_h == 0) return;
    if (new_phys_w == st.physical_width and new_phys_h == st.physical_height) return;

    // A Configure size is always the real window pixel size = physical = the framebuffer. The
    // derivation is the same helper window creation uses, so a fullscreen window's logical size
    // cannot change between the first frame and the first configure (ADR-011 R11).
    const new_logical = logicalSizeForPhysical(
        st.fb_mode,
        .{ .width = new_phys_w, .height = new_phys_h },
        effectiveContentScale(st.content_scale),
    );
    const new_logical_w: u32 = new_logical.width;
    const new_logical_h: u32 = new_logical.height;

    resizeBlit(st, new_phys_w, new_phys_h);
    // physical is updated only when resizeBlit succeeds. On failure the old size is kept, so logical is left alone too.
    if (st.physical_width == new_phys_w and st.physical_height == new_phys_h) {
        st.logical_width = new_logical_w;
        st.logical_height = new_logical_h;
    }
}

/// Called on a ConfigureNotify. It tries setupBlit at the new size, and on success frees the old blit and
/// updates physical/width/height. On a failure (an OOM, say) it restores the old blit and keeps the old size (never breaking the window).
fn resizeBlit(st: *State, new_w: u32, new_h: u32) void {
    if (new_w == 0 or new_h == 0) return; // minimised, or zero, is ignored
    if (new_w == st.physical_width and new_h == st.physical_height) return;

    var old = captureBlit(st);
    // setupBlit overwrites st's blit fields with the new resources (on failure its internal failBlit frees the
    // new resources, but st's fields are left dangling → the catch below restores the old values).
    setupBlit(st, st.visual, st.depth, new_w, new_h) catch {
        restoreBlit(st, old);
        return;
    };
    st.physical_width = new_w;
    st.physical_height = new_h;
    st.width = new_w;
    st.height = new_h;
    st.ct_region_valid = false; // A size change makes the click-through input shape be recomputed (the old mask is stale)
    freeBlitState(st.display, &old);
}

/// The fallback path: convert the canonical BGRA (0xAARRGGBB) backing into the image data (in the visual's mask layout).
/// Stride padding is absorbed by reading bytes_per_line. It is never called on the direct path.
fn convert(st: *State) void {
    const w = st.width;
    const h = st.height;
    const data: [*]u8 = @ptrCast(st.image.*.data);
    const bpl = st.bytes_per_line;

    var y: usize = 0;
    while (y < h) : (y += 1) {
        const row: [*]u32 = @ptrCast(@alignCast(data + y * bpl));
        const src = st.backing[y * w ..][0..w];
        var x: usize = 0;
        while (x < w) : (x += 1) {
            row[x] = conv.packPixel(src[x], st.r_shift, st.g_shift, st.b_shift);
        }
    }
}

// ============================================================================
// Structural unit tests of the shared helpers (no display needed)
// They run when this module is part of the test root, on Linux with `-Dplatform=x11`.
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

test "logicalFromPhysicalPx is the inverse of roundToPhysicalPx and clamps to the range" {
    try std.testing.expectEqual(@as(u32, 800), logicalFromPhysicalPx(1600, 2.0));
    try std.testing.expectEqual(@as(u32, 800), logicalFromPhysicalPx(1200, 1.5));
    try std.testing.expectEqual(@as(u32, 1600), logicalFromPhysicalPx(1600, 1.0));
    try std.testing.expectEqual(@as(u32, 1600), logicalFromPhysicalPx(1600, 0.0)); // invalid scale -> 1.0
    try std.testing.expectEqual(@as(u32, 1600), logicalFromPhysicalPx(1600, std.math.nan(f32)));
    try std.testing.expectEqual(@as(u32, 1), logicalFromPhysicalPx(1, 2.0)); // 1/2 rounds to 0 -> clamp to 1
    // A scale below 1 divides up; the result is clamped to the u32 range rather than wrapping.
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), logicalFromPhysicalPx(std.math.maxInt(u32), 0.5));
    // Round-tripping an exact multiple returns the same physical size.
    const scales = [_]f32{ 1.0, 1.5, 2.0, 3.0 };
    for (scales) |s| {
        const phys = roundToPhysicalPx(640, s);
        try std.testing.expectEqual(@as(u32, 640), logicalFromPhysicalPx(phys, s));
    }
}

test "logicalSizeForPhysical: a fullscreen screen size is physical, so the logical size is derived" {
    // The size a fullscreen window resolves for itself is already in physical pixels: under
    // .physical the logical size divides by the scale, and under .logical it is that same size.
    const screen: WindowSize = .{ .width = 3840, .height = 2160 };
    const derived = logicalSizeForPhysical(.physical, screen, 2.0);
    try std.testing.expectEqual(@as(u32, 1920), derived.width);
    try std.testing.expectEqual(@as(u32, 1080), derived.height);

    const same = logicalSizeForPhysical(.logical, screen, 2.0);
    try std.testing.expectEqual(screen.width, same.width);
    try std.testing.expectEqual(screen.height, same.height);

    // Applying the scale in the wrong direction would ask for a window twice the size of the
    // screen, which is the mistake this pair of helpers exists to prevent.
    try std.testing.expectEqual(@as(u32, 7680), effectiveFramebufferSize(.physical, screen, 2.0).width);
}

test "a fullscreen logical size does not move when the first resize reports the same physical size" {
    // The creation path and the resize path derive the logical size through the same helper, so a
    // window created fullscreen keeps the logical size of its first frame.
    const screen: WindowSize = .{ .width = 3840, .height = 2160 };
    const at_creation = logicalSizeForPhysical(.physical, screen, 2.0);
    const after_configure = logicalSizeForPhysical(.physical, screen, 2.0);
    try std.testing.expectEqual(at_creation.width, after_configure.width);
    try std.testing.expectEqual(at_creation.height, after_configure.height);

    // A scale that is not an integer keeps the same property (the rounding is the same rounding).
    const odd: WindowSize = .{ .width = 2560, .height = 1440 };
    const a = logicalSizeForPhysical(.physical, odd, 1.5);
    const b = logicalSizeForPhysical(.physical, odd, 1.5);
    try std.testing.expectEqual(a.width, b.width);
    try std.testing.expectEqual(@as(u32, 1707), a.width); // 2560/1.5 = 1706.67 -> 1707
}
