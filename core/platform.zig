//! Platform abstraction layer (facade)
//!
//! The Zig interface layer over several backends. `builtin.os.tag` selects the backend.
//!   - macOS → `platform_macos.zig` (through the C ABI `platform.h`; objc/swift/metal differ only in which .o is linked, and the Zig side is shared)
//!   - Linux → `platform_linux.zig` (X11/Wayland; pure Zig calling `@cImport(Xlib)` and friends directly; x11/wayland is picked by build_options.platform_backend)
//!   - Windows → `platform_windows.zig` (a dispatcher; pure Zig calling the Win32 API through extern fn; gdi/d3d11 is picked by build_options.platform_backend)
//!
//! The public types (KeyCode, Event and friends) are re-exported with `platform_types.zig` as the
//! single source, and only `Window`/`Framebuffer` and the functions come from each backend.
//! (Zig 0.16 removed `pub usingnamespace`, so they are listed explicitly.)
//!
//! ## The headless verification harness
//!
//! `Window` is a thin wrapper, and the four input/output choke points are interposed by `harness.zig`:
//!   - `pollEvents` = the synchronisation point of frame progress (replay's step gate)
//!   - `nextEvent`  = injected events (and from native, only quit passes through)
//!   - `present`    = the `fb` probe capture (an owned copy)
//!   - `getTime`    = the virtual clock
//! With env `KNGN_HARNESS_SCRIPT` unset every hook passes straight through (behaviour is identical).
//!
//! ## Fully display-less (the platform/null backend)
//!
//! With `KNGN_HEADLESS=1` the facade picks `platform_null` at runtime and never calls the native
//! backend's `init` or connects to a display. The primary framebuffer is owned by the null `Window`,
//! and the harness only takes observation copies (`onLock`/`onPresent`). SCRIPT/LIVE are optional (a display-less run on its own works).
//! `Framebuffer` is the facade's own struct (`pixels/width/height` plus `unlock()`), holding a
//! tagged union of native and null inside. A caller only uses `fb.pixels/.width/.height/.unlock()`,
//! so it stays source compatible (existing code such as apps/synth is untouched). wasm keeps its
//! DOM canvas backend on a compile-time branch and stays outside the null runtime union.
//!
//! ## The canonical pixel format (shared by every OS)
//!
//! A framebuffer pixel is **canonical BGRA**: u32 `0xAARRGGBB` (in little-endian memory,
//! `[B, G, R, A]`). Packing is `(a<<24)|(r<<16)|(g<<8)|b`, so a web hex `0xRRGGBB` lands exactly in
//! the low 24 bits. Windows (GDI/DXGI), the standard X11 visual and macOS (CGImage/Metal) all handle
//! BGRA natively, so every OS writes it directly, with no conversion layer and no runtime branch.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("platform_types");
const command_types = @import("command_types");
// harness is a shared module (the src/audio.zig facade imports the same instance and shares its module-level state).
// That is why this is a named module import rather than a source-relative `@import("harness.zig")`.
const harness = @import("harness");
// copilot (the assist transport that coexists with the normal UX). It is referenced through the
// namespace re-exported inside the harness module (the semantic dependency is one-way, copilot→harness).
const copilot = harness.copilot;
const netsync = harness.netsync;
// The opt-in flag for the real gamepad backend (the GameController framework), symmetrical with
// audio's `link_audio`. build.zig's `createPlatformModule`/`buildStandalone` always supply this named
// import (the externally published module included), so every caller can reference it safely.
const build_options = @import("build_options");

const native_backend = if (builtin.cpu.arch.isWasm())
    @import("platform_wasm.zig")
else switch (builtin.os.tag) {
    .macos => @import("platform_macos.zig"),
    .linux => @import("platform_linux.zig"),
    .windows => @import("platform_windows.zig"),
    else => @compileError("kngn: unsupported OS for platform backend: " ++ @tagName(builtin.os.tag)),
};

/// The null runtime covers native operating systems only (wasm keeps its compile-time DOM canvas branch).
const null_runtime_supported = !builtin.cpu.arch.isWasm();
const null_backend = if (null_runtime_supported) @import("platform_null.zig") else struct {};

/// The runtime choice settled by `KNGN_HEADLESS=1` (set at the top of `platform.init`; always false on wasm).
var runtime_null: bool = false;

fn envHeadlessOne() bool {
    if (comptime !null_runtime_supported) return false;
    const v = std.c.getenv("KNGN_HEADLESS") orelse return false;
    return std.mem.eql(u8, std.mem.span(v), "1");
}

fn nativePumpPoll(ctx: *anyopaque) bool {
    const inner: *native_backend.Window = @ptrCast(@alignCast(ctx));
    return inner.pollEvents();
}

// ============================================================================
// The live-resize redraw callback
// ============================================================================
//
// An opt-in mechanism by which the OS's modal, nested event-tracking loop (while the frame is being
// dragged) tells the application "draw one frame now", and nothing more.
//
// The contract:
// - The callback runs **while the event pump runs** (inside pollEvents: sendEvent / DispatchMessageW).
// - The callback must not call `pollEvents` (that re-enters the native pump).
// - `nextEvent` only reads the queue (it does not pump), so it may be called.
// - A modal dialog (a file dialog) must not be opened from the callback.
// - An application designed to call pollEvents while holding lockFramebuffer cannot register one.
// - Module-level state, assuming a single process and a single window (the same design as harness / registerProbe).
// - While the harness is enabled (KNGN_HARNESS_*) nothing is registered at all, so that frame_index, the
//   virtual clock and replay's bit determinism stay intact (symmetrical with registerProbe being a no-op while the harness is disabled).

/// The callback type through which a backend asks the application for one frame during an OS modal loop.
pub const RedrawFn = *const fn (ctx: *anyopaque) void;

var redraw_guard: struct {
    ctx: *anyopaque = undefined,
    cb: ?RedrawFn = null,
    in_callback: bool = false,
} = .{};

fn redrawWrapper(ctx: *anyopaque) void {
    _ = ctx;
    if (redraw_guard.in_callback) return;
    const cb = redraw_guard.cb orelse return;
    redraw_guard.in_callback = true;
    defer redraw_guard.in_callback = false;
    cb(redraw_guard.ctx);
}

// The types are re-exported with platform_types as the single source (they must not drift between backends)
pub const Error = types.Error;
pub const KeyCode = types.KeyCode;
pub const ModifierFlags = types.ModifierFlags;
pub const KeyEvent = types.KeyEvent;
pub const CharEvent = types.CharEvent;
pub const CompositionPhase = types.CompositionPhase;
pub const CompositionEvent = types.CompositionEvent;
pub const CompositionSnapshot = types.CompositionSnapshot;
pub const TextInputRange = types.TextInputRange;
pub const TextInputSubstring = types.TextInputSubstring;
pub const TextInputDocumentCallbacks = types.TextInputDocumentCallbacks;
pub const TEXT_INPUT_RANGE_NOT_FOUND = types.TEXT_INPUT_RANGE_NOT_FOUND;
pub const MouseButton = types.MouseButton;
pub const MouseButtons = types.MouseButtons;
pub const MouseEvent = types.MouseEvent;
pub const ScrollEvent = types.ScrollEvent;
pub const Event = types.Event;
pub const EventStats = types.EventStats;
pub const FileDropPath = types.FileDropPath;
pub const FileDropEvent = types.FileDropEvent;
pub const FILE_DROP_PATH_BYTES = types.FILE_DROP_PATH_BYTES;
pub const FILE_DROP_MAX_PATHS = types.FILE_DROP_MAX_PATHS;
pub const makeFileDropEventFromPath = types.makeFileDropEventFromPath;
pub const CommandId = command_types.CommandId;
pub const Command = command_types.Command;
pub const CommandKind = command_types.CommandKind;
pub const ExecutionPolicy = command_types.ExecutionPolicy;
pub const Shortcut = command_types.Shortcut;
pub const DialogError = types.DialogError;
pub const SaveDialogOptions = types.SaveDialogOptions;
pub const OpenDialogOptions = types.OpenDialogOptions;
pub const CursorShape = types.CursorShape;
pub const WindowOptions = types.WindowOptions; // transparency, borderless, position, size, framebuffer mode
pub const WindowPosition = types.WindowPosition; // a position in OS screen coordinates
pub const WindowSize = types.WindowSize; // a width and a height
pub const WindowGeometry = types.WindowGeometry; // a position plus a size
pub const FramebufferMode = types.FramebufferMode; // .logical or .physical
pub const FramebufferSnapshot = types.FramebufferSnapshot; // the per-frame size and scale snapshot
pub const MAX_GAMEPADS = types.MAX_GAMEPADS;
pub const GamepadButton = types.GamepadButton;
pub const GamepadButtons = types.GamepadButtons;
pub const Stick = types.Stick;
pub const GamepadState = types.GamepadState;
pub const GamepadInfo = types.GamepadInfo;
pub const GamepadDisconnect = types.GamepadDisconnect;

/// A locked framebuffer view (a type of the facade's own).
/// A caller uses `pixels/width/height/unlock()` plus the immutable snapshot of that same frame
/// (`logical_size` / `framebuffer_size` / `content_scale` / `scale_epoch`).
/// `width`/`height` are backwards-compatible aliases of `framebuffer_size`.
/// Inside is a tagged union of native (the compile-time backend) and null (`KNGN_HEADLESS`).
pub const Framebuffer = struct {
    pixels: []u32,
    width: u32, // == framebuffer_size.width
    height: u32, // == framebuffer_size.height
    logical_size: WindowSize,
    framebuffer_size: WindowSize,
    content_scale: f32,
    scale_epoch: u64,
    source: Source,

    const Source = if (null_runtime_supported) union(enum) {
        native: native_backend.Framebuffer,
        null_fb: null_backend.Framebuffer,
    } else union(enum) {
        native: native_backend.Framebuffer,
    };

    pub fn unlock(self: Framebuffer) void {
        if (comptime null_runtime_supported) {
            switch (self.source) {
                .native => |fb| fb.unlock(),
                .null_fb => |fb| fb.unlock(),
            }
        } else {
            self.source.native.unlock();
        }
    }
};

fn snapshotFromBackendFb(fb: anytype) FramebufferSnapshot {
    const Fb = @TypeOf(fb);
    if (@hasField(Fb, "logical_size")) {
        return .{
            .logical_size = fb.logical_size,
            .framebuffer_size = fb.framebuffer_size,
            .content_scale = fb.content_scale,
            .scale_epoch = fb.scale_epoch,
        };
    }
    return .{
        .logical_size = .{ .width = fb.width, .height = fb.height },
        .framebuffer_size = .{ .width = fb.width, .height = fb.height },
        .content_scale = 1.0,
        .scale_epoch = 0,
    };
}

/// Normalise a native mouse/scroll event's raw physical coordinates in place into logical points, using the latched scale.
/// Harness-injected events do not pass through here. A scale <= 0 is corrected to 1.0.
/// pub so that unit tests (platform_clipboard_test and friends) can call it too.
pub fn normalizeEventWithScale(scale_in: f32, event: Event) Event {
    const scale: f32 = if (scale_in > 0) scale_in else 1.0;
    if (scale == 1.0) return event;
    var ev = event;
    switch (ev) {
        .mouse_move, .mouse_down, .mouse_up => |*m| {
            m.x = @intFromFloat(@floor(@as(f32, @floatFromInt(m.x)) / scale));
            m.y = @intFromFloat(@floor(@as(f32, @floatFromInt(m.y)) / scale));
        },
        .mouse_scroll => |*s| {
            s.x = @intFromFloat(@floor(@as(f32, @floatFromInt(s.x)) / scale));
            s.y = @intFromFloat(@floor(@as(f32, @floatFromInt(s.y)) / scale));
            s.dx /= scale;
            s.dy /= scale;
        },
        else => {},
    }
    return ev;
}

/// The Window facade. The four hooks are inserted only while the harness is enabled; with it disabled every call passes straight through to the backend.
/// Under the **null runtime**, `inner` holds a `null_backend.Window`, which owns the primary framebuffer.
/// `lockFramebuffer`/`nextEvent` take a `*Window` because they hold the latched snapshot.
/// The loop contract: `pollEvents` → `lockFramebuffer` → `nextEvent` (native input is normalised with the latched scale).
pub const Window = struct {
    inner: Inner,
    /// The frame snapshot latched by the most recent `lockFramebuffer` (the only source of scale for input normalisation).
    latched_snapshot: FramebufferSnapshot = .{
        .logical_size = .{ .width = 0, .height = 0 },
        .framebuffer_size = .{ .width = 0, .height = 0 },
        .content_scale = 1.0,
        .scale_epoch = 0,
    },
    has_latched: bool = false,

    const Inner = if (null_runtime_supported) union(enum) {
        native: native_backend.Window,
        null_win: null_backend.Window,
    } else union(enum) {
        native: native_backend.Window,
    };

    fn isNull(self: Window) bool {
        if (comptime !null_runtime_supported) return false;
        return self.inner == .null_win;
    }

    /// The currently negotiated logical size (within a frame, use `Framebuffer.logical_size` for drawing and input).
    pub fn logicalSize(self: *const Window) WindowSize {
        if (comptime null_runtime_supported) {
            if (self.inner == .null_win) {
                if (@hasDecl(null_backend.Window, "logicalSize")) return self.inner.null_win.logicalSize();
                return .{ .width = self.inner.null_win.width, .height = self.inner.null_win.height };
            }
        }
        if (@hasDecl(native_backend.Window, "logicalSize")) return self.inner.native.logicalSize();
        const geo = self.getGeometry();
        return geo.size;
    }

    /// The currently negotiated framebuffer size (within a frame, use `Framebuffer.framebuffer_size`).
    pub fn framebufferSize(self: *const Window) WindowSize {
        if (comptime null_runtime_supported) {
            if (self.inner == .null_win) {
                if (@hasDecl(null_backend.Window, "framebufferSize")) return self.inner.null_win.framebufferSize();
                return .{ .width = self.inner.null_win.width, .height = self.inner.null_win.height };
            }
        }
        if (@hasDecl(native_backend.Window, "framebufferSize")) return self.inner.native.framebufferSize();
        return self.logicalSize();
    }

    /// The currently negotiated content scale (within a frame, use `Framebuffer.content_scale`).
    pub fn contentScale(self: *const Window) f32 {
        if (comptime null_runtime_supported) {
            if (self.inner == .null_win) {
                if (@hasDecl(null_backend.Window, "contentScale")) return self.inner.null_win.contentScale();
                return 1.0;
            }
        }
        if (@hasDecl(native_backend.Window, "contentScale")) return self.inner.native.contentScale();
        return 1.0;
    }

    fn eventScale(self: *const Window) f32 {
        if (self.has_latched) {
            const s = self.latched_snapshot.content_scale;
            return if (s > 0) s else 1.0;
        }
        const s = self.contentScale();
        return if (s > 0) s else 1.0;
    }

    fn normalizeNativeEvent(self: *Window, event: Event) Event {
        return normalizeEventWithScale(self.eventScale(), event);
    }

    pub fn create(width: u32, height: u32, title: [:0]const u8) Error!Window {
        if (comptime null_runtime_supported) {
            if (runtime_null) {
                return .{ .inner = .{ .null_win = try null_backend.Window.create(width, height, title) } };
            }
        }
        return .{ .inner = .{ .native = try native_backend.Window.create(width, height, title) } };
    }

    /// Create a real fullscreen window: this is the OS-level fullscreen entry point of the API.
    /// When `native_backend.Window` implements `createFullscreen` (Linux x11/wayland) that path is
    /// used; otherwise this falls back to an ordinary window of a fixed size (the macOS and Windows
    /// backends need no change of their own for it).
    /// Hot path declaration: initialisation only (a single window creation).
    pub fn createFullscreen(title: [:0]const u8) Error!Window {
        if (comptime null_runtime_supported) {
            if (runtime_null) {
                return .{ .inner = .{ .null_win = try null_backend.Window.createFullscreen(title) } };
            }
        }
        if (@hasDecl(native_backend.Window, "createFullscreen")) {
            return .{ .inner = .{ .native = try native_backend.Window.createFullscreen(title) } };
        }
        return .{ .inner = .{ .native = try native_backend.Window.create(1920, 1080, title) } };
    }

    /// Create a window with options: transparency, borderless, an initial position and a size.
    /// `.{}` behaves exactly like plain create. w/h are overridden only when `opts.size` is given.
    /// When the backend implements `createWithOptions` that is used; otherwise a request for
    /// transparency or borderless gives `error.Unsupported`, and with neither it falls back to create.
    /// The null runtime (`KNGN_HEADLESS=1`) accepts the options and runs on the CPU framebuffer alone
    /// (nothing is displayed, but the framebuffer alpha can still be checked through a digest; the position is always null).
    /// Hot path declaration: initialisation only (a single window creation).
    pub fn createWithOptions(width: u32, height: u32, title: [:0]const u8, opts: WindowOptions) Error!Window {
        const w = if (opts.size) |s| s.width else width;
        const h = if (opts.size) |s| s.height else height;
        if (comptime null_runtime_supported) {
            if (runtime_null) {
                return .{ .inner = .{ .null_win = try null_backend.Window.createWithOptions(w, h, title, opts) } };
            }
        }
        if (@hasDecl(native_backend.Window, "createWithOptions")) {
            return .{ .inner = .{ .native = try native_backend.Window.createWithOptions(w, h, title, opts) } };
        }
        if (opts.transparent or opts.borderless) return error.Unsupported;
        return .{ .inner = .{ .native = try native_backend.Window.create(w, h, title) } };
    }

    /// Return the current window geometry. It never fails, and falls back to safe defaults.
    /// null gives the creation size with position=null. A backend without support gives size=0 and position=null.
    /// Hot path declaration: window creation, shutdown, and harness digest observation only.
    pub fn getGeometry(self: Window) WindowGeometry {
        if (comptime null_runtime_supported) {
            if (self.inner == .null_win) {
                return null_backend.getGeometry(self.inner.null_win);
            }
        }
        if (comptime @hasDecl(native_backend, "getGeometry")) {
            return native_backend.getGeometry(self.inner.native);
        }
        return .{ .position = null, .size = .{ .width = 0, .height = 0 } };
    }

    pub fn destroy(self: Window) void {
        // Clearing the callback goes through the facade/backend private clear path rather than passing null
        // to the public setRedrawCallback. It guards against a late setFrameSize after destroy.
        redraw_guard = .{};
        if (comptime null_runtime_supported) {
            if (self.inner == .null_win) {
                self.inner.null_win.destroy();
                return;
            }
        }
        // Unregister document access (a dangling userdata otherwise), when the backend implements it.
        if (comptime @hasDecl(native_backend.Window, "setTextInputDocumentAccess")) {
            // userdata is not read on unregister, but the type demands an *anyopaque, so a dummy is passed.
            var dummy: u8 = 0;
            self.inner.native.setTextInputDocumentAccess(@ptrCast(&dummy), null);
        }
        self.inner.native.clearRedrawCallback();
        self.inner.native.destroy();
    }

    /// Let the consumer cancel the OS's close/quit request and keep the window alive.
    /// Hot path declaration: quit/close events only. A no-op under the null runtime.
    pub fn cancelQuit(self: Window) void {
        if (self.isNull()) return;
        if (@hasDecl(native_backend.Window, "cancelQuit")) self.inner.native.cancelQuit();
    }

    pub fn pollEvents(self: Window) bool {
        // netsync.pump runs before the harness gate's early return (on every path, every frame).
        // It returns immediately on an empty queue, and the started guard passes through when the env is unset.
        netsync.pump();
        if (comptime null_runtime_supported) {
            if (self.inner == .null_win) {
                // No native compositor pump is handed to null. With the harness disabled this always continues.
                if (!harness.isEnabled()) return true;
                return harness.pollGate(true);
            }
        }
        var native_win = self.inner.native;
        const native = native_win.pollEvents();
        if (!harness.isEnabled()) {
            // Advance the copilot transport at the end of every frame of the normal UX (a no-op that returns
            // immediately while disabled; exclusivity disables copilot whenever the harness is on, so this placement suffices).
            copilot.pump();
            return native;
        }
        // manual/replay: a blocking gate plus NativePump. free-run: a non-blocking drain (no pump).
        if (harness.isManualClock()) {
            const pump = harness.NativePump{
                .ptr = @ptrCast(&native_win),
                .pollFn = nativePumpPoll,
            };
            return harness.pollGateWithPump(native, pump);
        }
        return harness.pollGateFreeRun(native);
    }

    pub fn nextEvent(self: *Window) ?Event {
        // Hot path declaration: event time only. A native mouse/scroll is a scalar division by the latched scale, nothing more.
        // A harness injection is already in logical units, so it does not go through normalisation.
        if (self.isNull()) return harness.nextInjectedEvent(); // only injected events, since there is no native pump
        if (!harness.isEnabled()) {
            const ev = self.inner.native.nextEvent() orelse return null;
            return self.normalizeNativeEvent(ev);
        }
        // Injected events come first; once they run out, native is drained.
        // manual/replay: injection drives everything, so only quit passes from native (a real click is ignored).
        // free-run: the user works the real display, so native input reaches the application. That is what
        //   makes collaboration possible: a person drives the real window while an agent injects and acts over LISTEN.
        if (harness.nextInjectedEvent()) |ev| return ev;
        const pass_native = !harness.isManualClock();
        while (self.inner.native.nextEvent()) |ev| {
            const normalized = self.normalizeNativeEvent(ev);
            if (pass_native) return normalized;
            if (harness.filterNativeEvent(normalized)) |keep| return keep;
        }
        return null;
    }

    pub fn getEventStats(self: Window) EventStats {
        if (comptime null_runtime_supported) {
            if (self.inner == .null_win) return self.inner.null_win.getEventStats();
        }
        return self.inner.native.getEventStats();
    }

    /// Acquire a drawable frame slot if one is available; otherwise `null`.
    /// `null` is retryable and not fatal (e.g. a Wayland frame callback or busy buffer).
    /// The returned `Framebuffer`'s `width`/`height` are authoritative for that frame.
    /// Contract: docs/adr/002 (revised) and docs/adr/005.
    pub fn lockFramebuffer(self: *Window) ?Framebuffer {
        // Hot path declaration: for native and null alike this only returns a view of the backend buffer, latches the snapshot, and records onLock while the harness is enabled.
        // No per-frame allocation, no per-pixel work and no converting copy (the observation copy happens in onPresent, at present time).
        // Reallocating for a pending scale or size happens at the backend's lock boundary (initialisation, or a scale or resize change).
        if (comptime null_runtime_supported) {
            if (self.inner == .null_win) {
                const fb = self.inner.null_win.lockFramebuffer() orelse return null;
                const snap = snapshotFromBackendFb(fb);
                self.latched_snapshot = snap;
                self.has_latched = true;
                if (harness.isEnabled()) harness.onLock(fb.pixels, fb.width, fb.height);
                return .{
                    .pixels = fb.pixels,
                    .width = snap.framebuffer_size.width,
                    .height = snap.framebuffer_size.height,
                    .logical_size = snap.logical_size,
                    .framebuffer_size = snap.framebuffer_size,
                    .content_scale = snap.content_scale,
                    .scale_epoch = snap.scale_epoch,
                    .source = .{ .null_fb = fb },
                };
            }
        }
        const fb = self.inner.native.lockFramebuffer() orelse {
            if (harness.isEnabled()) harness.onLockMiss();
            return null;
        };
        const snap = snapshotFromBackendFb(fb);
        self.latched_snapshot = snap;
        self.has_latched = true;
        if (harness.isEnabled()) harness.onLock(fb.pixels, fb.width, fb.height);
        return .{
            .pixels = fb.pixels,
            .width = snap.framebuffer_size.width,
            .height = snap.framebuffer_size.height,
            .logical_size = snap.logical_size,
            .framebuffer_size = snap.framebuffer_size,
            .content_scale = snap.content_scale,
            .scale_epoch = snap.scale_epoch,
            .source = .{ .native = fb },
        };
    }

    /// Submit the most recently locked frame to the display queue (the frame commit point; not a vsync wait).
    /// After present the pixels are owned by the backend; the caller must not touch them until the next lock.
    /// Contract: docs/adr/002 (revised) and docs/adr/005.
    pub fn present(self: Window) void {
        // Hot path declaration: while the harness is enabled, onStats→onPresent (an owned observation copy) runs before the backend present.
        // A null present is a no-op. There is no per-frame allocation and no per-pixel work.
        if (harness.isEnabled()) {
            harness.onStats(self.getEventStats());
            harness.onPresent();
        }
        if (comptime null_runtime_supported) {
            if (self.inner == .null_win) {
                self.inner.null_win.present();
                return;
            }
        }
        self.inner.native.present();
    }

    /// Set the cursor shape (the system cursor).
    /// Hot path declaration: called **at event time only** (a tool change and the like), never per frame
    /// or in real time, so the performance rules do not apply. The null runtime (nothing to display, i.e. KNGN_HEADLESS) is a no-op.
    /// It is not a value a probe observes (its effect shows only on screen), so the harness needs no hook for it.
    pub fn setCursor(self: Window, shape: CursorShape) void {
        if (self.isNull()) return;
        self.inner.native.setCursor(shape);
    }

    /// Update the title of the visible OS window. Called only on a state transition.
    /// null and a backend without support are no-ops, and the framebuffer is left alone.
    pub fn setTitle(self: Window, title: [:0]const u8) void {
        if (self.isNull()) return;
        if (@hasDecl(native_backend.Window, "setTitle")) self.inner.native.setTitle(title);
    }

    /// Start the OS's interactive window move from the most recent pointer press.
    /// An application calls it on a mouse_down inside the region the user can grab. A backend without support, and null, are no-ops.
    /// Hot path declaration: only on a mouse_down event.
    pub fn beginDrag(self: Window) void {
        if (self.isNull()) return;
        if (@hasDecl(native_backend.Window, "beginDrag")) self.inner.native.beginDrag();
    }

    /// Set always-on-top. A backend without support, and null, are no-ops. Event time only.
    pub fn setAlwaysOnTop(self: Window, on: bool) void {
        if (self.isNull()) return;
        if (@hasDecl(native_backend.Window, "setAlwaysOnTop")) self.inner.native.setAlwaysOnTop(on);
    }

    /// Set per-pixel click-through, letting a click over a transparent pixel fall through to what is behind.
    /// A backend without support, and null, are no-ops. Event time only.
    pub fn setClickThrough(self: Window, on: bool) void {
        if (self.isNull()) return;
        if (@hasDecl(native_backend.Window, "setClickThrough")) self.inner.native.setClickThrough(on);
    }

    /// Pop up a quit menu (choosing it pushes quit onto the window's event queue).
    /// A backend without support, and null, are no-ops. Event time only.
    pub fn showQuitMenu(self: Window) void {
        if (self.isNull()) return;
        if (@hasDecl(native_backend.Window, "showQuitMenu")) self.inner.native.showQuitMenu();
    }

    /// Opt in to the backend asking the application for one frame during an OS modal loop (a live
    /// resize, say). With nothing registered the backend calls nothing and behaviour is unchanged.
    /// While the harness is enabled (KNGN_HARNESS_*) and under the null runtime nothing is registered at all (a no-op).
    /// The re-entrancy guard lives in the facade's `redrawWrapper` (it blocks a callback during a callback).
    pub fn setRedrawCallback(self: Window, ctx: *anyopaque, cb: RedrawFn) void {
        if (self.isNull() or harness.isEnabled()) return;
        redraw_guard = .{ .ctx = ctx, .cb = cb, .in_callback = false };
        self.inner.native.setRedrawCallback(@ptrCast(&redraw_guard), redrawWrapper);
    }

    /// Read the state of the gamepad at the given index (polling is the main axis; ADR-009).
    /// While the harness is enabled (the null runtime included) this is the facade's fifth choke point:
    /// it delegates to `harness.getGamepadState` and returns the state injected by `inject gamepad_connect/button/axis`
    /// (a synthetic state, whether or not a real backend exists and whatever the opt-in state is).
    /// Without the harness, the real backend (the GameController framework) is reached only on macOS and
    /// only with `build_options.enable_gamepad`, which build.zig opts into per executable, symmetrically
    /// with audio's `link_audio`. Other backends (Linux, Windows) and a macOS executable without the
    /// opt-in stay a stub returning `null` (`builtin.os.tag == .macos` and `build_options.enable_gamepad`
    /// are both comptime-known, so the unselected branch is never analysed. It is the same idiom as this
    /// facade's `sleep()`/`win_sleep`: the Linux and Windows `Window` need no `getGamepadState`, and a
    /// macOS executable without the opt-in references no GameController symbol at all).
    ///
    /// Hot path declaration: called once per frame, but it is a fixed-length copy of four pads with a few
    /// fields each (no allocation, no lock), which is neither an all-pixel loop nor real time. The
    /// performance rules (the three rules for an all-pixel loop and so on) do not apply (see docs/adr/009).
    pub fn getGamepadState(self: Window, index: u8) ?GamepadState {
        if (harness.isEnabled() or harness.isHeadlessActive()) return harness.getGamepadState(index);
        if (builtin.os.tag != .macos) return null; // the Linux and Windows backends do not implement it (macOS only)
        if (!build_options.enable_gamepad) return null; // the opt-in is off
        return self.inner.native.getGamepadState(index);
    }

    // ========================================================================
    // native menus
    // ========================================================================

    /// Whether this backend provides the native menu API.
    ///
    /// A backend implements it as an optional module-level decl. A backend without one, and null,
    /// always answer false. The Command slice need only stay valid for the duration of the
    /// register/update call; the backend copies whatever it needs.
    pub fn nativeMenuAvailable(self: Window) bool {
        if (self.isNull()) return false;
        if (comptime @hasDecl(native_backend, "nativeMenuAvailable")) {
            return native_backend.nativeMenuAvailable(self.inner.native);
        }
        return false;
    }

    /// Register a native menu. A backend without support, and null, are no-ops.
    /// On a backend whose menu bar belongs to the application, as on macOS, window is ignored by
    /// contract and the last registration replaces the whole bar. Windows and the like work per window.
    pub fn registerMenu(self: Window, commands: []const Command) void {
        if (self.isNull()) return;
        if (comptime @hasDecl(native_backend, "registerMenu")) {
            native_backend.registerMenu(self.inner.native, commands);
        }
    }

    /// Update enabled/checked and the like on a registered native menu. A backend without support, and null, are no-ops.
    pub fn updateMenu(self: Window, commands: []const Command) void {
        if (self.isNull()) return;
        if (comptime @hasDecl(native_backend, "updateMenu")) {
            native_backend.updateMenu(self.inner.native, commands);
        }
    }

    /// Destroy the registered native menu. A backend without support, and null, are no-ops.
    pub fn destroyMenu(self: Window) void {
        if (self.isNull()) return;
        if (comptime @hasDecl(native_backend, "destroyMenu")) {
            native_backend.destroyMenu(self.inner.native);
        }
    }

    /// A query alias, so callers need not care which name they know. Its meaning and contract match nativeMenuAvailable.
    pub const supportsNativeMenus = nativeMenuAvailable;

    /// Write the IME composition preedit text into buf.
    /// null and a backend without support always give empty results (zero-length text, revision/cursor 0).
    ///
    /// **The latest-wins contract**: a snapshot is always the *current* uncommitted state.
    /// Several `composition_changed` events within one poll collapse into the latest snapshot. An event's
    /// `revision` exists to detect a missed update; a snapshot of an older revision cannot be obtained.
    ///
    /// Hot path declaration: event time only (reading the preedit before drawing); neither an all-pixel per-frame loop nor real time.
    pub fn getCompositionSnapshot(self: Window, buf: []u8) CompositionSnapshot {
        if (harness.isEnabled()) return harness.getCompositionSnapshot(buf);
        if (comptime null_runtime_supported) {
            if (self.inner == .null_win) return self.inner.null_win.getCompositionSnapshot(buf);
        }
        return self.inner.native.getCompositionSnapshot(buf);
    }

    /// Supply the caret rect the IME candidate window is anchored to, in framebuffer pixels with the origin at the content's top-left.
    /// null and a backend without support are no-ops. Called at event time only, such as when the layout changes.
    pub fn setCompositionRect(self: Window, x: i32, y: i32, w: i32, h: i32) void {
        if (self.isNull()) return;
        if (comptime @hasDecl(native_backend.Window, "setCompositionRect")) {
            self.inner.native.setCompositionRect(x, y, w, h);
        }
    }

    /// A general primitive that tells the platform whether a text editing widget has focus
    /// (the equivalent of SDL's StartTextInput/StopTextInput; it pairs with `setCompositionRect`).
    /// While active=false the IME and composition are kept out of the path, so even with an IME enabled
    /// an unmodified letter key arrives as a shortcut. It is **idempotent**, so a consumer may call it
    /// every frame to track focus (no effect while the effective path is unchanged; a composition is discarded only when it changes). null is a no-op.
    /// A future Linux or Windows implementation must likewise be an idempotent setter that is safe every frame (detecting the change internally).
    /// A backend opts in through the `@hasDecl` gate; today only macOS (objc/swift/metal) implements it.
    /// Once Linux (XIM/ibus/text-input-v3) or Windows (IMM/WM_IME) implements IME composition, adding
    /// this method to the backend Window enables it with no change to the facade or the consumer (a backend without it is a no-op).
    pub fn setTextInputActive(self: Window, active: bool) void {
        if (self.isNull()) return;
        if (comptime @hasDecl(native_backend.Window, "setTextInputActive")) {
            self.inner.native.setTextInputActive(active);
        }
    }

    /// IME document access (reconverting committed text). `callbacks == null` unregisters.
    /// null and a backend without support are no-ops. The facade unregisters as well when the window is destroyed.
    pub fn setTextInputDocumentAccess(
        self: Window,
        userdata: *anyopaque,
        callbacks: ?TextInputDocumentCallbacks,
    ) void {
        if (self.isNull()) return;
        if (comptime @hasDecl(native_backend.Window, "setTextInputDocumentAccess")) {
            self.inner.native.setTextInputDocumentAccess(userdata, callbacks);
        }
    }
};

pub fn init() Error!void {
    // The frame pacing learning state. Re-initialising the process must not carry a bad value over.
    pacer.reset();
    // KNGN_HEADLESS is settled before harness.parseConfig. Only the value "1" selects the null runtime.
    // The copilot order is: harness.parseConfig → copilot.parseConfig → backend init →
    // harness.startTransport → copilot.startTransport (exclusivity is settled at parseConfig time, from which env vars are present).
    runtime_null = envHeadlessOne();
    harness.setHeadlessActive(runtime_null);
    harness.parseConfig();
    copilot.parseConfig();
    if (runtime_null) {
        if (comptime null_runtime_supported) {
            try null_backend.init();
        }
    } else {
        try native_backend.init();
    }
    harness.startTransport();
    copilot.startTransport();
    // A netsync session makes copilot reject operate calls (registered before initFromEnv's enableRouter).
    netsync.setSessionStateCallback(copilot.setNetsyncSessionActive);
    // netsync starts on the null runtime branch too (with the env unset, initFromEnv returns immediately).
    netsync.initFromEnv();
    // The observation probe, only while enabled. It is registered from platform to avoid a netsync→harness reverse dependency.
    if (netsync.isEnabled()) {
        harness.registerProbe(.{
            .name = "netsync",
            .ctx = @ptrFromInt(1),
            .ext = "json",
            .desc = "netsync role/peers/last_seq/pending/awaiting_sync/last_reject",
            .digest = netsync.probeDigest,
            .snapshot = netsync.probeSnapshot,
        });
    }
}

pub fn shutdown() void {
    // Close the OS resource behind frame pacing (Windows's waitable timer handle).
    if (comptime builtin.os.tag == .windows) windows_wait.deinit();
    // app_runtime's defers run in reverse order of registration, so App.deinit runs first.
    // The borrow is dropped first, so netsync and copilot never dereference the executor after the borrowed App is freed.
    netsync.forgetSharedExecutor();
    copilot.forgetSharedExecutor();
    netsync.shutdown(); // setRouter(null) on the main thread; a no-op while disabled
    copilot.stopTransport(); // close the connected stream, then the listener (a no-op while disabled)
    if (runtime_null) {
        if (comptime null_runtime_supported) null_backend.shutdown();
        return;
    }
    native_backend.shutdown();
}

pub fn getTime() f64 {
    // Only a manual clock (replay, or LISTEN+MANUAL_CLOCK) is virtual; free-run reads the backend's real
    // time (clock ownership is kept separate from the control channel).
    if (harness.isManualClock()) return harness.now();
    if (runtime_null) {
        if (comptime null_runtime_supported) return null_backend.getTime();
        return 0;
    }
    return native_backend.getTime();
}

/// Show or hide the Dock icon and the menu bar (application-wide, not per window).
/// visible=false makes it behave like a background app (on macOS, the accessory policy). A backend without support, and null, are no-ops.
/// Hot path declaration: initialisation and event time only.
pub fn setDockVisible(visible: bool) void {
    if (runtime_null) return;
    if (@hasDecl(native_backend, "setDockVisible")) native_backend.setDockVisible(visible);
}

/// The save file dialog. Under the null runtime the backend is uninitialised (there is no native
/// panel and no zenity to call), so it returns `error.DialogFailed` immediately.
pub fn saveFileDialog(gpa: std.mem.Allocator, io: std.Io, opts: SaveDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    if (runtime_null) return error.DialogFailed;
    return native_backend.saveFileDialog(gpa, io, opts);
}

/// The open file dialog. Under the null runtime it returns `error.DialogFailed` immediately, for the same reason as `saveFileDialog`.
/// On wasm it is asynchronous: until something is picked it gives `error.DialogPending` (retry on the next frame).
pub fn openFileDialog(gpa: std.mem.Allocator, io: std.Io, opts: OpenDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    if (runtime_null) return error.DialogFailed;
    return native_backend.openFileDialog(gpa, io, opts);
}

// ============================================================================
// The system clipboard (the wasm colour clipboard; native is a no-op / unimplemented)
// A path distinct from setClipboardText/getClipboardText (OS text). Do not mix the two.
// ============================================================================

/// Write text to the system clipboard. A no-op when the backend does not implement it.
pub fn clipboardWrite(text: []const u8) void {
    if (comptime @hasDecl(native_backend, "clipboardWrite")) {
        native_backend.clipboardWrite(text);
    }
}

/// Ask for the system clipboard text asynchronously. A no-op when the backend does not implement it.
pub fn clipboardRequestPaste() void {
    if (comptime @hasDecl(native_backend, "clipboardRequestPaste")) {
        native_backend.clipboardRequestPaste();
    }
}

/// Return and consume the text once it has arrived. Not yet arrived, or unimplemented, gives null.
pub fn clipboardTakePaste() ?[]const u8 {
    if (comptime @hasDecl(native_backend, "clipboardTakePaste")) {
        return native_backend.clipboardTakePaste();
    }
    return null;
}

// ============================================================================
// The OS text clipboard
// ============================================================================
//
// Hot path declaration: event time only (Cmd+C/X/V). Never called per frame or in real time.
// The null runtime and unit tests use a fixed-length in-memory fallback; the ordinary native runtime
// delegates to the backend (on macOS objc, NSPasteboard).

const MEMORY_CLIPBOARD_CAP: usize = 4096;

var memory_clipboard: [MEMORY_CLIPBOARD_CAP]u8 = undefined;
var memory_clipboard_len: usize = 0;
var memory_clipboard_set: bool = false;

fn useMemoryClipboard() bool {
    return builtin.is_test or runtime_null;
}

fn utf8TruncateLen(text: []const u8, max: usize) usize {
    var n = @min(text.len, max);
    while (n > 0 and n < text.len and (text[n] & 0xC0) == 0x80) : (n -= 1) {}
    return n;
}

/// Reset the in-memory clipboard between tests (effective only under `builtin.is_test`).
pub fn resetClipboardForTest() void {
    if (!builtin.is_test) return;
    memory_clipboard_len = 0;
    memory_clipboard_set = false;
}

/// Write UTF-8 text to the OS clipboard. A backend without support is a no-op.
pub fn setClipboardText(text: []const u8) void {
    if (useMemoryClipboard()) {
        const n = utf8TruncateLen(text, MEMORY_CLIPBOARD_CAP);
        @memcpy(memory_clipboard[0..n], text[0..n]);
        memory_clipboard_len = n;
        memory_clipboard_set = true;
        return;
    }
    if (comptime @hasDecl(native_backend, "setClipboardText")) {
        native_backend.setClipboardText(text);
    }
}

/// Copy the OS clipboard's UTF-8 text into a caller-owned buffer.
/// null = unsupported, unset, or a failure. An empty string is `buf[0..0]`. Anything over capacity is truncated at a UTF-8 boundary.
pub fn getClipboardText(buf: []u8) ?[]const u8 {
    if (useMemoryClipboard()) {
        if (!memory_clipboard_set) return null;
        const n = utf8TruncateLen(memory_clipboard[0..memory_clipboard_len], buf.len);
        @memcpy(buf[0..n], memory_clipboard[0..n]);
        return buf[0..n];
    }
    if (comptime @hasDecl(native_backend, "getClipboardText")) {
        return native_backend.getClipboardText(buf);
    }
    return null;
}

// ============================================================================
// custom probes (the headless verification harness)
//
// An application opts a probe in with `platform.registerProbe(.{ .name, .ctx, .snapshot, .digest })`.
// The platform module already imports the shared harness module, so a re-export exposes it and build.zig needs no change.
// With the harness disabled (the env unset) registerProbe is a no-op. The framework never interprets a probe's contents.
// ============================================================================
pub const Probe = harness.Probe;
pub const registerProbe = harness.registerProbe;

// ============================================================================
// custom actions (they live in action_registry)
//
// An application opts a high-level operation in with `platform.registerAction(.{ .name, .ctx, .run })`.
// It is the write side, symmetrical with a probe's read side, and points at `action_registry` (the same instance, reached through harness).
// With harness and action_registry disabled (the env unset) registerAction is a no-op.
// The framework never interprets an action's contents (the same invariant as a probe).
// ============================================================================
pub const Action = harness.action_registry.Action;
pub const NetworkPolicy = harness.action_registry.NetworkPolicy;
pub const registerAction = harness.action_registry.registerAction;
/// The structured error for a failed action (code + suggested_next_action). Opt-in.
pub const setActionErrorDetail = harness.action_registry.setActionErrorDetail;

pub const StateSync = netsync.StateSync;
/// Register the document/patch synchronisation adapter used when netsync joins (while disabled it only stores it, so it is always safe to call).
pub const registerStateSync = netsync.registerStateSync;

/// Whether a netsync session is live (a host or client is connected). Used to switch the keyboard undo/redo path.
pub const netsyncActive = netsync.isEnabled;

/// Whether this process is the netsync host (it decides who distributes the pattern_state).
pub const netsyncIsHost = netsync.isHost;

/// How many outbound proposals a client has pending (0 on a host and while disabled).
pub const netsyncPendingProposalCount = netsync.pendingProposalCount;
/// The capacity of the client's pending proposal queue (the limit on a batched PROPOSE at release time).
pub const netsyncPendingCap = netsync.PENDING_CAP;

/// The number of connected peers (on a host, the active clients; on a client, the active catalog entries). A transparent generic facade.
pub const netsyncPeerCount = netsync.peerCount;

/// Resolving a peer origin. Applications never import the netsync implementation types directly.
pub const NetsyncPeerOriginView = netsync.PeerOriginView;
pub const netsyncResolvePeerOrigin = netsync.resolvePeerOrigin;
pub const netsyncPeerMetadataRevision = netsync.peerMetadataRevision;
pub const netsyncLocalPeerId = netsync.localPeerId;

/// Broadcast a host-generated internal action as a COMMIT (name and args pass through; the framework does not interpret them).
/// A non-host, or netsync disabled, gives `error.NotHost`. Never call it from the real-time thread (main thread event boundaries only).
pub fn commitHostAction(name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    if (!netsync.isEnabled() or !netsync.isHost()) return error.NotHost;
    return netsync.commitAndBroadcast(name, args, buf);
}

/// A general post-apply hook, run once a netsync COMMIT has been applied (an opaque ctx plus raw information only).
/// Unregistered, or netsync disabled, is a no-op. Unregister with `setNetsyncPostApplyHook(null, null)` before freeing the App.
pub const NetsyncPostApplyContext = netsync.PostApplyContext;
pub const NetsyncPostApplyHook = netsync.PostApplyHook;
pub fn setNetsyncPostApplyHook(ctx: ?*anyopaque, hook: ?NetsyncPostApplyHook) void {
    netsync.setPostApplyHook(ctx, hook);
}

/// Run an action through the netsync router (equivalent to dispatch when no router is set).
pub const routeAction = harness.action_registry.routeLocalAction;

// ============================================================================
// the command model
//
// The types with which an application owns a CommandLog and an Executor and records who (an ActorId) ran what.
// command.zig depends on std alone (not on platform or harness), but it is re-exported through the
// harness module so that a single instance of the types is shared. Applications reach it as
// `kit.platform.command` (since command is std-only, this adds no dependency under the layer rules).
// ============================================================================
pub const command = harness.command;
/// The adapter contract connecting an application's `dispatchCommand(id)` to the Executor and the router.
pub const command_adapter = harness.command;

/// Set the executor shared by copilot and netsync (delegating to each setSharedExecutor).
/// Once it is set, the copilot transport's `action` dispatches straight to the application-side
/// wrapper (which centralises recording through the executor), and `begin_tx`/`end_tx`/`cancel_tx` act on this executor.
/// **It is safe to call with the harness and copilot disabled** (by contract a no-op that only assigns a module variable).
/// The Executor is a borrow owned by the caller, and platform.shutdown drops the borrow during
/// teardown, so the application need not unregister. It must not keep the Executor alive past platform.shutdown.
pub fn setCommandExecutor(exec: ?*command.Executor) void {
    copilot.setSharedExecutor(exec);
    netsync.setSharedExecutor(exec); // applying a remote COMMIT (no_record); with none set, netsync falls back to dispatch
}

// ============================================================================
// sleep (an OS-independent frame wait)
//
// zig 0.16 dropped std.time.sleep and routes sleep through std.Io, so the facade keeps the simple
// delay that main and the examples share. A comptime OS branch is enough, with no extra backend (POSIX nanosleep, Windows Sleep).
// The unselected branch is comptime-known and never analysed (the winapi extern does not break POSIX).
// ============================================================================
const win_sleep = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
} else struct {};

/// Sleep for at least the given nanoseconds (the resolution depends on the OS).
/// A no-op on wasm (rAF does the pacing; the nanosleep reference is excluded at comptime).
const sleep_impl = if (builtin.cpu.arch.isWasm()) struct {
    fn call(_: u64) void {}
} else struct {
    fn call(nanoseconds: u64) void {
        if (builtin.os.tag == .windows) {
            win_sleep.Sleep(@intCast(nanoseconds / 1_000_000));
        } else {
            var req = std.c.timespec{
                .sec = @intCast(nanoseconds / 1_000_000_000),
                .nsec = @intCast(nanoseconds % 1_000_000_000),
            };
            _ = std.c.nanosleep(&req, null);
        }
    }
};

pub fn sleep(nanoseconds: u64) void {
    sleep_impl.call(nanoseconds);
}

// ── A high-resolution sleep (for framePaceUntil alone) ──────────────────────
// Each OS's most precise wait is used. Since the EWMA correction absorbs whatever each one overshoots,
// the difference between the primitives shows up as the jitter left after learning. On failure this falls back to `sleep()`.

const darwin_wait = if (builtin.os.tag == .macos) struct {
    const TimebaseInfo = extern struct { numer: u32, denom: u32 };
    extern "c" fn mach_absolute_time() u64;
    extern "c" fn mach_timebase_info(info: *TimebaseInfo) c_int;
    extern "c" fn mach_wait_until(deadline: u64) c_int;

    var timebase: TimebaseInfo = .{ .numer = 0, .denom = 0 };

    /// ns → mach ticks. The timebase is read once, on the first call, and cached.
    fn ticks(nanoseconds: u64) ?u64 {
        if (timebase.numer == 0 or timebase.denom == 0) {
            if (mach_timebase_info(&timebase) != 0) return null;
            if (timebase.numer == 0 or timebase.denom == 0) return null;
        }
        return nanoseconds *| @as(u64, timebase.denom) / @as(u64, timebase.numer);
    }

    fn call(nanoseconds: u64) void {
        const t = ticks(nanoseconds) orelse return sleep(nanoseconds);
        if (mach_wait_until(mach_absolute_time() +| t) != 0) sleep(nanoseconds);
    }
} else struct {};

const linux_wait = if (builtin.os.tag == .linux) struct {
    /// `clock_nanosleep(CLOCK_MONOTONIC, ABSTIME)`. Since getTime() reads MONOTONIC_RAW, CLOCK_MONOTONIC
    /// is **read at the moment of the wait** and the relative request is added to it to form the absolute
    /// deadline passed in (the clock domains are never mixed). EINTR is retried.
    fn call(nanoseconds: u64) void {
        var target: std.c.timespec = undefined;
        if (std.c.clock_gettime(.MONOTONIC, &target) != 0) return sleep(nanoseconds);
        const add_sec: i64 = @intCast(nanoseconds / 1_000_000_000);
        const add_nsec: i64 = @intCast(nanoseconds % 1_000_000_000);
        target.sec += add_sec;
        target.nsec += add_nsec;
        if (target.nsec >= 1_000_000_000) {
            target.sec += 1;
            target.nsec -= 1_000_000_000;
        }
        // Per the POSIX contract, `clock_nanosleep` **returns the error number rather than setting errno**.
        // EINTR retries with the same absolute target (being absolute, the remaining time needs no recomputing).
        var attempts: u8 = 0;
        while (attempts < 8) : (attempts += 1) {
            const rc = std.c.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = true }, &target, null);
            if (rc == 0) return;
            if (rc != @intFromEnum(std.c.E.INTR)) return sleep(nanoseconds);
        }
        // When EINTR keeps happening and the attempt limit is reached: **measure the remaining time again**
        // **and fill it with a relative sleep** (returning here would come back before the deadline and break pacing).
        var now: std.c.timespec = undefined;
        if (std.c.clock_gettime(.MONOTONIC, &now) != 0) return;
        const remain_sec = target.sec - now.sec;
        const remain_nsec = target.nsec - now.nsec;
        const remain_ns: i128 = @as(i128, remain_sec) * 1_000_000_000 + @as(i128, remain_nsec);
        if (remain_ns > 0) sleep(@intCast(@min(remain_ns, @as(i128, nanoseconds))));
    }
} else struct {};

const windows_wait = if (builtin.os.tag == .windows) struct {
    const HANDLE = *anyopaque;
    const CREATE_WAITABLE_TIMER_HIGH_RESOLUTION: u32 = 0x2;
    const TIMER_ALL_ACCESS: u32 = 0x1F0003;
    const INFINITE: u32 = 0xFFFFFFFF;

    extern "kernel32" fn CreateWaitableTimerExW(
        lpTimerAttributes: ?*anyopaque,
        lpTimerName: ?[*:0]const u16,
        dwFlags: u32,
        dwDesiredAccess: u32,
    ) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn SetWaitableTimer(
        hTimer: HANDLE,
        lpDueTime: *const i64,
        lPeriod: i32,
        pfnCompletionRoutine: ?*anyopaque,
        lpArgToCompletionRoutine: ?*anyopaque,
        fResume: i32,
    ) callconv(.winapi) i32;
    extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) i32;

    /// A three-step fallback: a high-resolution timer, a normal timer, then `Sleep(ms)`. The handle is created once and cached.
    var timer: ?HANDLE = null;
    var timer_tried = false;

    fn handle() ?HANDLE {
        if (timer) |h| return h;
        if (timer_tried) return null;
        timer_tried = true;
        timer = CreateWaitableTimerExW(null, null, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS) orelse
            CreateWaitableTimerExW(null, null, 0, TIMER_ALL_ACCESS);
        return timer;
    }

    fn call(nanoseconds: u64) void {
        const h = handle() orelse return sleep(nanoseconds);
        // A negative value means relative (in 100ns units). Anything short enough to round to 0 does not wait.
        const hundred_ns: i64 = @intCast(@min(nanoseconds / 100, @as(u64, @intCast(std.math.maxInt(i64)))));
        if (hundred_ns == 0) return;
        const due: i64 = -hundred_ns;
        if (SetWaitableTimer(h, &due, 0, null, null, 0) == 0) return sleep(nanoseconds);
        _ = WaitForSingleObject(h, INFINITE);
    }

    fn deinit() void {
        if (timer) |h| {
            _ = CloseHandle(h);
            timer = null;
        }
        timer_tried = false;
    }
} else struct {};

/// The per-OS high-resolution sleep (for `framePaceUntil` alone; a no-op on wasm).
fn sleepPrecise(nanoseconds: u64) void {
    if (comptime builtin.cpu.arch.isWasm()) return;
    switch (comptime builtin.os.tag) {
        .macos => darwin_wait.call(nanoseconds),
        .linux => linux_wait.call(nanoseconds),
        .windows => windows_wait.call(nanoseconds),
        else => sleep(nanoseconds),
    }
}

/// Deprecated: new frame loops use `framePaceUntil` with a deadline.
/// This function waits for the requested fixed duration and does not subtract time spent doing frame work.
/// Under a manual clock (replay, or LISTEN+MANUAL_CLOCK), it is a no-op.
/// It remains available for callers that require a fixed relative wait.
pub fn frameDelay(nanoseconds: u64) void {
    if (harness.isManualClock()) return;
    sleep(nanoseconds);
}

// ============================================================================
// frame pacing (a deadline plus overshoot correction)
//
// Pacing that waits until a target time, called once per frame. Unlike a fixed sleep (frameDelay) it subtracts the work time.
// Both relative and absolute OS sleeps overshoot the requested time (on macOS the timer slack is about
// 20% of the request: 16.67ms requested overshoots by 3.4ms on average, i.e. 49.8fps). **An absolute-time
// sleep does not fix it**, so the measured overshoot is learned with an EWMA and subtracted from the request (measured: a mean error of -0.10ms, i.e. 60.4fps, with no busy-wait).
//
// Hot path declaration: per frame (once per frame). Neither an all-pixel loop nor a real-time (per sample) path.
// ============================================================================

/// The pure pacing logic (the decision, the EWMA learning and the constants) lives in `core/frame_pacing.zig` (OS independent, and unit tested).
const frame_pacing = @import("frame_pacing.zig");

/// The pacing learning state, owned by the main thread alone. The real-time thread never touches it.
var pacer: frame_pacing.Pacer = .{};

/// The pacing driver with the clock and the high-resolution sleep injected (injected at comptime, so no indirect call).
const PaceDriver = frame_pacing.Driver(getTime, sleepPrecise);

/// Pace the frame **best-effort** towards a target time (in seconds, on the same monotonic clock as `getTime()`).
/// Call it exactly once per frame (in place of `frameDelay`).
///
/// This is not a hard deadline guarantee: the mean period matches the target, but an individual frame
/// may return up to `frame_pacing.MARGIN_NS` (200µs) early, and the jitter from the OS timer slack
/// (measured on macOS at a p95 of about 2ms) remains. A deadline in the past, or a non-finite one, returns immediately.
///
/// Under a manual clock (replay, or LISTEN+MANUAL_CLOCK) it is a **complete no-op** (it reads no OS clock and touches no learning state).
///
/// How it relates to a first-class backend (Metal / D3D11-DXGI / Wayland): time the backend spent
/// waiting on vsync counts towards the elapsed time since the frame started, so it is subtracted from
/// the remaining time and only the remainder is waited out (with a non-blocking present the wait stays on the caller's side; this is no guarantee against waiting twice).
pub fn framePaceUntil(deadline_seconds: f64) void {
    PaceDriver.pace(&pacer, deadline_seconds, harness.isManualClock());
}

// ============================================================================
// unit tests for input normalisation and the snapshot contract (no display needed)
// ============================================================================

test "normalizeEventWithScale floors the divide (scale=2 raw to logical)" {
    const raw_move: Event = .{ .mouse_move = .{
        .x = 20,
        .y = 10,
        .button = .none,
        .buttons = .{},
        .modifiers = .{},
    } };
    const logical = normalizeEventWithScale(2.0, raw_move);
    try std.testing.expectEqual(@as(i32, 10), logical.mouse_move.x);
    try std.testing.expectEqual(@as(i32, 5), logical.mouse_move.y);

    const neg: Event = .{ .mouse_down = .{
        .x = -3,
        .y = 7,
        .button = .left,
        .buttons = .{ .left = true },
        .modifiers = .{},
    } };
    const neg_l = normalizeEventWithScale(2.0, neg);
    try std.testing.expectEqual(@as(i32, -2), neg_l.mouse_down.x); // floor(-3/2)=floor(-1.5)=-2
    try std.testing.expectEqual(@as(i32, 3), neg_l.mouse_down.y);

    const scroll: Event = .{ .mouse_scroll = .{
        .x = 40,
        .y = 20,
        .dx = 4.0,
        .dy = -6.0,
        .is_precise = true,
        .buttons = .{},
        .modifiers = .{},
    } };
    const scroll_l = normalizeEventWithScale(2.0, scroll);
    try std.testing.expectEqual(@as(i32, 20), scroll_l.mouse_scroll.x);
    try std.testing.expectEqual(@as(i32, 10), scroll_l.mouse_scroll.y);
    try std.testing.expectEqual(@as(f32, 2.0), scroll_l.mouse_scroll.dx);
    try std.testing.expectEqual(@as(f32, -3.0), scroll_l.mouse_scroll.dy);
}

test "normalizeEventWithScale is the identity at scale=1 and corrects scale<=0" {
    const ev: Event = .{ .mouse_move = .{
        .x = 11,
        .y = 22,
        .button = .none,
        .buttons = .{},
        .modifiers = .{},
    } };
    const same = normalizeEventWithScale(1.0, ev);
    try std.testing.expectEqual(@as(i32, 11), same.mouse_move.x);
    const fixed = normalizeEventWithScale(0.0, ev);
    try std.testing.expectEqual(@as(i32, 11), fixed.mouse_move.x);
}

test "FramebufferSnapshot logical and physical size contract" {
    const logical: FramebufferSnapshot = .{
        .logical_size = .{ .width = 800, .height = 600 },
        .framebuffer_size = .{ .width = 800, .height = 600 },
        .content_scale = 1.0,
        .scale_epoch = 0,
    };
    try std.testing.expectEqual(logical.logical_size.width, logical.framebuffer_size.width);

    const physical: FramebufferSnapshot = .{
        .logical_size = .{ .width = 800, .height = 600 },
        .framebuffer_size = .{ .width = 1600, .height = 1200 },
        .content_scale = 2.0,
        .scale_epoch = 1,
    };
    try std.testing.expectEqual(@as(u32, 1600), physical.framebuffer_size.width);
    try std.testing.expectEqual(@as(u32, 800), physical.logical_size.width);
}
