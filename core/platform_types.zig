//! The shared types of the platform layer (pure Zig types, independent of any backend)
//!
//! The canonical type contract that each backend (macOS, Linux and the rest) refers to. It does not
//! depend on the C ABI (`platform.h`); each backend builds these types out of its own native values
//! (a C struct, an Xlib event, and so on). `core/platform.zig` (the facade) publishes these as the single
//! source, and re-exports only `Window`/`Framebuffer` and the functions from each backend.

const std = @import("std");

pub const Error = error{
    InitFailed,
    WindowCreationFailed,
    /// The backend does not support a requested window feature (transparency, borderless and the like).
    Unsupported,
};

/// The initial window position (in OS screen coordinates).
pub const WindowPosition = struct {
    x: i32,
    y: i32,
};

/// The window's content/client size.
pub const WindowSize = struct {
    width: u32,
    height: u32,
};

/// The current window geometry.
/// `position == null` means reading or applying a position is unsupported or failed (Wayland, wasm, headless).
pub const WindowGeometry = struct {
    position: ?WindowPosition,
    size: WindowSize,
};

/// The geometry an application persists, held for a window that can go fullscreen (ADR-019 R10).
///
/// While fullscreen, the window's current geometry is the screen, so persisting it produces a
/// screen-sized window on the next run. The contract this latch implements is "the last geometry
/// observed while **not** fullscreen": a backend feeds it every settled geometry change together
/// with the fullscreen state that goes with it, and reads it back through `get`.
///
/// The basis is whatever the backend's `getGeometry` uses (a logical content size, plus a position
/// where the backend can report one), so the value round-trips into `WindowOptions` unchanged.
/// A window that has never been windowed — one created fullscreen — keeps the geometry it was
/// seeded with at creation, which is the size the application asked for.
///
/// Hot path declaration: event time only (a settled resize or a fullscreen transition).
pub const RestoreGeometryLatch = struct {
    /// The last geometry observed while not fullscreen (seeded at window creation).
    geometry: WindowGeometry,
    /// The fullscreen state that came with the most recent observation.
    fullscreen: bool = false,

    /// Record one settled observation. While fullscreen the stored geometry is left alone, which is
    /// what makes it survive the transition.
    pub fn observe(self: *RestoreGeometryLatch, fullscreen: bool, current: WindowGeometry) void {
        self.fullscreen = fullscreen;
        if (!fullscreen) self.geometry = current;
    }

    /// The geometry to persist: the current one while windowed, the latched one while fullscreen.
    pub fn get(self: RestoreGeometryLatch, current: WindowGeometry) WindowGeometry {
        return if (self.fullscreen) self.geometry else current;
    }
};

/// The framebuffer resolution mode. The default `.logical` and the opt-in `.physical` size the
/// framebuffer from the display area (ADR-011 R1); `.fixed` sizes it from the value it carries and
/// leaves present to magnify it into a letterbox (ADR-030 R1).
///
/// It is a union rather than an enum plus a separate size field so that selecting `.fixed` makes
/// the size mandatory and attaching a size to another mode is not a program: the contract lives in
/// the type instead of being split between the type and `validateWindowOptions`.
pub const FramebufferMode = union(enum) {
    /// A framebuffer the size of the window in logical points; the display scales it up.
    logical,
    /// A framebuffer in physical pixels, while application coordinates stay logical.
    physical,
    /// A framebuffer of exactly this size, whatever the window does. The application sees one
    /// coordinate space at scale 1.0 and present magnifies into a letterbox (ADR-030 R2, R3).
    fixed: WindowSize,

    /// True when the framebuffer is sized in physical pixels and follows the window.
    ///
    /// This and the predicate below are how a backend asks which space its framebuffer is in.
    /// **A fixed framebuffer is in neither**, so both answer false for it, and these two exhaustive
    /// switches are the only place that decides. Comparing the mode against a tag at the call site
    /// instead would put a fixed framebuffer on whichever branch the comparison happened to leave
    /// it on, silently — a tagged union compares equal to an enum literal perfectly happily.
    pub fn tracksPhysicalPixels(self: FramebufferMode) bool {
        return switch (self) {
            .physical => true,
            .logical, .fixed => false,
        };
    }

    /// True when the framebuffer is sized in logical points and follows the window.
    pub fn tracksLogicalPoints(self: FramebufferMode) bool {
        return switch (self) {
            .logical => true,
            .physical, .fixed => false,
        };
    }
};

/// How a framebuffer maps onto the window, in both directions (ADR-030 R3, R4).
///
/// **The two directions do not share a denominator**, and merging them silently breaks `.physical`.
/// The forward direction leaves *framebuffer* space; the inverse arrives in the *application's*
/// coordinate space, and under `.physical` those are different spaces — the framebuffer is in
/// physical pixels while the application still thinks in logical points (ADR-011 R3):
///
/// | Mode | origin | fb_size (forward) | app_size (inverse) | dst_size |
/// |---|---|---|---|---|
/// | `.logical` | 0 | the framebuffer | the same, and equal to it | the window in physical pixels |
/// | `.physical` | 0 | the framebuffer | the logical size, which is smaller | the framebuffer |
/// | `.fixed` | the letterbox origin | the fixed size | the same, and equal to it | the magnified rectangle |
///
/// Everything is a ratio of integers, computed the way a nearest-neighbour upscale computes
/// `sx = x * src_w / dst_w`. That is not an implementation detail: doing it in floating point makes
/// the forward and the inverse disagree at the edges by a pixel — enough to leave the outermost
/// column of the framebuffer impossible to point at — and makes both disagree with the present that
/// magnifies the pixels. Integers make the three exact by construction.
///
/// Coordinates use a **pixel-edge** convention: framebuffer pixel `k` covers the destination range
/// `[k * dst / fb, (k + 1) * dst / fb)`. The inverse is the floored division a nearest-neighbour
/// upscale performs, and the forward is the **ceiling** of the same ratio — the first whole
/// destination pixel that lands inside `k`'s range, which is what makes the inverse undo it. Taking
/// the floor there instead would name a pixel belonging to `k - 1` whenever the magnification is
/// fractional, and the round trip would drift by one.
pub const PresentMapping = struct {
    /// Top-left of the destination rectangle, in physical window pixels. Zero unless `.fixed`.
    origin: WindowPosition = .{ .x = 0, .y = 0 },
    /// The destination rectangle, in physical window pixels.
    dst_size: WindowSize = .{ .width = 1, .height = 1 },
    /// The window's content area this mapping was worked out against, in physical window pixels.
    ///
    /// **It cannot be recovered from the fields above**: the origin is floored, so a letterbox whose
    /// two bars differ by a pixel makes `origin * 2 + dst` a pixel short of the window. Carrying it
    /// is what lets a backend place the rectangle and paint the bars from the mapping alone, instead
    /// of reading its own window size again — which would be a *different* window size whenever a
    /// resize landed in between, and would put the content somewhere the mapping does not describe.
    viewport: WindowSize = .{ .width = 1, .height = 1 },
    /// The framebuffer, and so the denominator of the forward direction.
    fb_size: WindowSize = .{ .width = 1, .height = 1 },
    /// The application's coordinate space, and so the numerator of the inverse direction.
    app_size: WindowSize = .{ .width = 1, .height = 1 },

    /// The letterboxed destination rectangle of `.fixed`: the aspect ratio preserved, the
    /// magnification arbitrary, everything floored, and all of it computed in physical pixels so
    /// that this and its inverse agree exactly (ADR-030 R3).
    ///
    /// A window with no area gets a mapping with no area, which present skips. Otherwise the
    /// destination is at least one pixel on each axis — **the one case that does not preserve the
    /// aspect ratio**, taken because a mapping that exists beats a rule that holds.
    ///
    /// Hot path declaration: window-size changes only (never per frame, never per pixel).
    pub fn letterbox(win_physical: WindowSize, fb: WindowSize) PresentMapping {
        if (win_physical.width == 0 or win_physical.height == 0 or fb.width == 0 or fb.height == 0) {
            return .{
                .dst_size = .{ .width = 0, .height = 0 },
                .viewport = win_physical,
                .fb_size = fb,
                .app_size = fb,
            };
        }
        // The axis that runs out first sets the magnification. Comparing the two candidate
        // destinations by cross-multiplication keeps the choice exact and integral.
        const win_w: u64 = win_physical.width;
        const win_h: u64 = win_physical.height;
        const fb_w: u64 = fb.width;
        const fb_h: u64 = fb.height;
        var dst_w: u64 = undefined;
        var dst_h: u64 = undefined;
        if (win_w * fb_h <= win_h * fb_w) {
            dst_w = win_w;
            dst_h = win_w * fb_h / fb_w;
        } else {
            dst_h = win_h;
            dst_w = win_h * fb_w / fb_h;
        }
        const w: u32 = @intCast(std.math.clamp(dst_w, 1, win_w));
        const h: u32 = @intCast(std.math.clamp(dst_h, 1, win_h));
        return .{
            .origin = .{
                .x = @intCast((win_physical.width - w) / 2),
                .y = @intCast((win_physical.height - h) / 2),
            },
            .dst_size = .{ .width = w, .height = h },
            .viewport = win_physical,
            .fb_size = fb,
            // Under a fixed framebuffer the application's space *is* the framebuffer (ADR-030 R2).
            .app_size = fb,
        };
    }

    /// The mapping for a framebuffer that covers the window, synthesised from the mode the window
    /// was created with and this frame's snapshot. **Never used for `.fixed`**, whose mapping comes
    /// from the backend.
    ///
    /// The mode has to be passed in because the snapshot cannot be divided back out: a `.physical`
    /// framebuffer is `round(logical * scale)`, so recovering the scale lands beside 1.0 rather than
    /// on it. Told the mode, the answer is exact.
    ///
    /// Hot path declaration: once per frame (a handful of scalar operations).
    pub fn covering(mode: FramebufferMode, snap: FramebufferSnapshot) PresentMapping {
        const fb = atLeastOne(snap.framebuffer_size);
        const logical = atLeastOne(snap.logical_size);
        return switch (mode) {
            // The framebuffer is in logical points and the display scales it up, so the window in
            // physical pixels is what the framebuffer becomes on screen.
            .logical => .{
                .dst_size = scaleSize(fb, snap.content_scale),
                // The framebuffer covers the window, so the destination *is* the window.
                .viewport = scaleSize(fb, snap.content_scale),
                .fb_size = fb,
                .app_size = logical,
            },
            // The framebuffer is already the window in physical pixels.
            .physical => .{
                .dst_size = fb,
                .viewport = fb,
                .fb_size = fb,
                .app_size = logical,
            },
            // A fixed framebuffer reaches here only with no window to measure — the headless null
            // runtime, where the framebuffer is all there is and maps onto itself.
            .fixed => .{
                .dst_size = fb,
                .viewport = fb,
                .fb_size = fb,
                .app_size = fb,
            },
        };
    }

    /// Map a framebuffer coordinate to physical window pixels: the first whole destination pixel
    /// that falls inside the range this framebuffer pixel covers.
    pub fn framebufferToPhysical(self: PresentMapping, x: i32, y: i32) WindowPosition {
        return .{
            .x = saturate(@as(i128, self.origin.x) + ratioCeil(x, self.dst_size.width, self.fb_size.width)),
            .y = saturate(@as(i128, self.origin.y) + ratioCeil(y, self.dst_size.height, self.fb_size.height)),
        };
    }

    /// Map a physical window coordinate into the application's coordinate space.
    ///
    /// **A position over the letterbox is not pulled back inside**: it comes out negative, or past
    /// the framebuffer's last row or column, and says so (ADR-030 R4). The only limit applied is the
    /// range of the result type, which no real window comes near.
    pub fn physicalToApp(self: PresentMapping, x: i32, y: i32) WindowPosition {
        return .{
            .x = saturate(ratio(@as(i128, x) - @as(i128, self.origin.x), self.app_size.width, self.dst_size.width)),
            .y = saturate(ratio(@as(i128, y) - @as(i128, self.origin.y), self.app_size.height, self.dst_size.height)),
        };
    }

    /// Scale a scroll delta into the application's coordinate space. A delta is a movement of a
    /// position and takes the same ratio the position takes: scaling the two differently is what
    /// stops the content under the pointer from staying under the pointer.
    ///
    /// **Each axis takes its own ratio.** Flooring the destination rectangle leaves the two axes
    /// with ratios that are close but not equal — a 300x200 framebuffer in a 1000x999 window
    /// becomes 1000x666, so `dy` divides by 666/200 while `dx` divides by 1000/300.
    pub fn deltaToApp(self: PresentMapping, dx: f32, dy: f32) struct { dx: f32, dy: f32 } {
        return .{
            .dx = scaleDelta(dx, self.app_size.width, self.dst_size.width),
            .dy = scaleDelta(dy, self.app_size.height, self.dst_size.height),
        };
    }

    fn scaleDelta(d: f32, num: u32, den: u32) f32 {
        if (den == 0) return d;
        return d * @as(f32, @floatFromInt(num)) / @as(f32, @floatFromInt(den));
    }

    /// `floor(v * num / den)`, floored towards minus infinity so that a position outside the
    /// destination rectangle keeps going the way it was heading.
    ///
    /// The product is taken in `i128`. A coordinate is bounded only by `i32` and a size only by
    /// `u32`, so their product does not fit an `i64` and Zig traps on the overflow rather than
    /// wrapping. A size that large is a bug in whatever supplied it, and it should surface as a
    /// wrong number rather than as a crash inside a coordinate transform.
    fn ratio(v: i128, num: u32, den: u32) i128 {
        if (den == 0) return v;
        return @divFloor(v * @as(i128, num), @as(i128, den));
    }

    pub fn saturate(v: i128) i32 {
        return @intCast(std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32)));
    }

    /// `ceil(v * num / den)`, the same arithmetic rounded the other way.
    fn ratioCeil(v: i128, num: u32, den: u32) i128 {
        if (den == 0) return v;
        const d = @as(i128, den);
        return @divFloor(v * @as(i128, num) + d - 1, d);
    }

    fn atLeastOne(size: WindowSize) WindowSize {
        return .{ .width = @max(size.width, 1), .height = @max(size.height, 1) };
    }

    fn scaleSize(size: WindowSize, scale_in: f32) WindowSize {
        const scale: f64 = if (std.math.isFinite(scale_in) and scale_in > 0) scale_in else 1.0;
        return .{ .width = scaleDim(size.width, scale), .height = scaleDim(size.height, scale) };
    }

    /// `round(dim * scale)`, clamped into the range a size can hold: a scale big enough to leave it
    /// is nonsense rather than a number worth propagating, and `@intFromFloat` would trap on it.
    fn scaleDim(dim: u32, scale: f64) u32 {
        const v = @round(@as(f64, @floatFromInt(dim)) * scale);
        if (!(v >= 1)) return 1;
        if (v >= @as(f64, std.math.maxInt(u32))) return std.math.maxInt(u32);
        return @intFromFloat(v);
    }
};

/// Map a whole framebuffer rectangle to physical window pixels. **Both edges are converted and the
/// extent taken as their difference** rather than the extent being scaled on its own, so that
/// adjacent rectangles stay adjacent — no gap, no overlap — under the pixel-edge convention.
pub fn framebufferRectToPhysical(m: PresentMapping, x: i32, y: i32, w: i32, h: i32) struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
} {
    const near = m.framebufferToPhysical(x, y);
    const far = m.framebufferToPhysical(x +| w, y +| h);
    return .{
        .x = near.x,
        .y = near.y,
        .w = PresentMapping.saturate(@as(i128, far.x) - @as(i128, near.x)),
        .h = PresentMapping.saturate(@as(i128, far.y) - @as(i128, near.y)),
    };
}

/// The guard a backend calls while it has no present that magnifies a framebuffer into a letterbox
/// (ADR-030 R3). Called at the very top of `createWithOptions` — before a display is opened or
/// anything is allocated — so the caller is told `Unsupported` rather than being handed a
/// framebuffer of a size it did not ask for, or a creation failure that says nothing.
///
/// A backend that gains that present deletes its call, which is the one line that marks the change.
pub fn refuseFixedFramebuffer(mode: FramebufferMode) Error!void {
    switch (mode) {
        .fixed => return error.Unsupported,
        .logical, .physical => {},
    }
}

/// The scale and size snapshot of one frame, returned by `lockFramebuffer` (ADR-011 R2).
pub const FramebufferSnapshot = struct {
    logical_size: WindowSize,
    framebuffer_size: WindowSize,
    content_scale: f32,
    scale_epoch: u64,
};

/// Window creation options. The default `.{}` behaves exactly as before (opaque, with a title, a logical framebuffer).
/// Transparency is per-pixel alpha (premultiplied alpha is assumed). borderless has no frame and no title bar.
/// When `size` is given it overrides the w/h of `Window.createWithOptions`. `position` applies only on a backend that supports it.
pub const WindowOptions = struct {
    transparent: bool = false,
    borderless: bool = false,
    position: ?WindowPosition = null,
    size: ?WindowSize = null,
    fb_mode: FramebufferMode = .logical,
    /// Ask that the user cannot resize the window. **How strong that is depends on the platform**:
    /// macOS and Windows drop the resizing affordance from the window itself, so it holds; X11
    /// (`WM_NORMAL_HINTS`) and Wayland (`set_min_size`/`set_max_size`) can only *advise* the window
    /// manager or compositor, which may resize anyway; on the web it is a no-op, because a canvas
    /// cannot stop its viewport from changing. It therefore **does not promise that the framebuffer
    /// size never changes** — an application still handles resizes and follows `fb.width`/`fb.height`.
    /// With `fullscreen` it is accepted and adds nothing: a fullscreen window is not user-resizable
    /// to begin with, and it cannot stop the compositor resizing it.
    resizable: bool = true,
    /// Create the window fullscreen. This is the **initial state only**: entering or leaving
    /// fullscreen at run time is `Window.setFullscreen`, and the state at any later moment —
    /// including one the user changed — is `Window.isFullscreen` (ADR-019 R2, R10). Exclusive
    /// fullscreen and choosing a monitor remain separate APIs with separate contracts.
    /// With `fullscreen = true` the width and height are an initial *request*: a backend that knows
    /// the fullscreen size ignores them, one that negotiates asynchronously may replace them, and
    /// only a backend with no notion of fullscreen honours them (ADR-019 R3). Which option
    /// combinations are refused is ADR-019 R4, decided once in the facade.
    fullscreen: bool = false,
};

// ============================================================================
// KeyCode (non-exhaustive enum)
// ============================================================================
//
// The virtual key codes of a physical keyboard. It is non-exhaustive (`_,`) so that:
//   - `@enumFromInt` does not panic on a value that is not listed
//   - another backend (Linux/X11, say) has room to add keys of its own
//
// The values equal PlatformKeyCode in `platform.h` (the macOS backend passes the C values straight through).

pub const KeyCode = enum(c_int) {
    UNKNOWN = -1,

    SPACE = 32,

    @"0" = 48,
    @"1" = 49,
    @"2" = 50,
    @"3" = 51,
    @"4" = 52,
    @"5" = 53,
    @"6" = 54,
    @"7" = 55,
    @"8" = 56,
    @"9" = 57,

    A = 65,
    B = 66,
    C = 67,
    D = 68,
    E = 69,
    F = 70,
    G = 71,
    H = 72,
    I = 73,
    J = 74,
    K = 75,
    L = 76,
    M = 77,
    N = 78,
    O = 79,
    P = 80,
    Q = 81,
    R = 82,
    S = 83,
    T = 84,
    U = 85,
    V = 86,
    W = 87,
    X = 88,
    Y = 89,
    Z = 90,

    ESCAPE = 256,
    ENTER = 257,
    TAB = 258,
    BACKSPACE = 259,
    INSERT = 260,
    DELETE = 261,
    LEFT = 263,
    RIGHT = 264,
    UP = 265,
    DOWN = 266,
    PAGE_UP = 267,
    PAGE_DOWN = 268,
    HOME = 269,
    END = 270,

    CAPS_LOCK = 280,
    PRINT_SCREEN = 283,
    PAUSE = 284,

    F1 = 290,
    F2 = 291,
    F3 = 292,
    F4 = 293,
    F5 = 294,
    F6 = 295,
    F7 = 296,
    F8 = 297,
    F9 = 298,
    F10 = 299,
    F11 = 300,
    F12 = 301,
    F13 = 302,
    F14 = 303,
    F15 = 304,
    F16 = 305,
    F17 = 306,
    F18 = 307,
    F19 = 308,
    F20 = 309,

    KP_0 = 320,
    KP_1 = 321,
    KP_2 = 322,
    KP_3 = 323,
    KP_4 = 324,
    KP_5 = 325,
    KP_6 = 326,
    KP_7 = 327,
    KP_8 = 328,
    KP_9 = 329,
    KP_DECIMAL = 330,
    KP_DIVIDE = 331,
    KP_MULTIPLY = 332,
    KP_SUBTRACT = 333,
    KP_ADD = 334,
    KP_ENTER = 335,
    KP_EQUAL = 336,

    LEFT_SHIFT = 340,
    LEFT_CONTROL = 341,
    LEFT_ALT = 342,
    LEFT_SUPER = 343,
    RIGHT_SHIFT = 344,
    RIGHT_CONTROL = 345,
    RIGHT_ALT = 346,
    RIGHT_SUPER = 347,

    _,
};

// ============================================================================
// ModifierFlags (a packed struct, LSB-first, matching the C bit-mask)
// ============================================================================

pub const ModifierFlags = packed struct(u32) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    cmd: bool = false,
    _reserved: u28 = 0,

    pub inline fn fromC(raw: u32) ModifierFlags {
        return @bitCast(raw);
    }

    pub inline fn toC(self: ModifierFlags) u32 {
        return @bitCast(self);
    }
};

comptime {
    // Guarantees that the bit order of the packed struct matches C's SHIFT=0x01, CTRL=0x02, ALT=0x04, CMD=0x08
    std.debug.assert(@as(u32, @bitCast(ModifierFlags{ .shift = true })) == 0x01);
    std.debug.assert(@as(u32, @bitCast(ModifierFlags{ .ctrl = true })) == 0x02);
    std.debug.assert(@as(u32, @bitCast(ModifierFlags{ .alt = true })) == 0x04);
    std.debug.assert(@as(u32, @bitCast(ModifierFlags{ .cmd = true })) == 0x08);
}

// ============================================================================
// MouseButton (physical buttons, the same int width as C's PlatformMouseButton)
// ============================================================================

pub const MouseButton = enum(c_int) {
    left = 0,
    right = 1,
    middle = 2,
    none = 0xFF,
    _,
};

// ============================================================================
// MouseButtons (a packed struct, LSB-first, matching the C bit-mask)
// ============================================================================

pub const MouseButtons = packed struct(u8) {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
    _reserved: u5 = 0,

    pub inline fn fromC(raw: u8) MouseButtons {
        return @bitCast(raw);
    }

    pub inline fn toC(self: MouseButtons) u8 {
        return @bitCast(self);
    }
};

comptime {
    // Guarantees that the bit order of the packed struct matches C's LEFT=0x01, RIGHT=0x02, MIDDLE=0x04
    std.debug.assert(@as(u8, @bitCast(MouseButtons{ .left = true })) == 0x01);
    std.debug.assert(@as(u8, @bitCast(MouseButtons{ .right = true })) == 0x02);
    std.debug.assert(@as(u8, @bitCast(MouseButtons{ .middle = true })) == 0x04);
}

// ============================================================================
// Event
// ============================================================================

pub const KeyEvent = struct {
    key: KeyCode,
    is_repeat: bool,
    modifiers: ModifierFlags,
};

/// A text input event: a committed character, notified independently of key_down (a physical key).
/// codepoint is UTF-32 (a Unicode scalar value). A character committed by an IME also arrives here
/// (on macOS, insertText → char_input). The preedit text being converted comes through
/// `composition_changed` plus `getCompositionSnapshot`. Control characters (below 0x20, and DELETE
/// 0x7f) are filtered out by the backend, so only printable characters flow through.
pub const CharEvent = struct {
    codepoint: u32,
    modifiers: ModifierFlags,
};

/// The state transition phase of an IME composition (the preedit being converted).
/// The text itself is not carried on the event but read through a per-window snapshot API (which keeps the lifetime contract unambiguous).
pub const CompositionPhase = enum(u8) {
    start = 0,
    update = 1,
    commit = 2,
    cancel = 3,
};

/// The composition_changed event itself. revision is the counter used to match it against a snapshot.
/// cursor is the UTF-8 byte offset within the preedit (the caret).
pub const CompositionEvent = struct {
    revision: u32,
    phase: CompositionPhase,
    cursor: u32,
};

/// The return value of `Window.getCompositionSnapshot` (a slice of the UTF-8 written into the caller's buf).
pub const CompositionSnapshot = struct {
    text: []const u8,
    revision: u32,
    cursor: u32,
};

/// A UTF-16 code unit range for IME document access.
/// `location == TEXT_INPUT_RANGE_NOT_FOUND` is the equivalent of NSNotFound.
pub const TEXT_INPUT_RANGE_NOT_FOUND: u64 = std.math.maxInt(u64);

pub const TextInputRange = struct {
    location: u64,
    length: u64,

    pub fn isNotFound(self: TextInputRange) bool {
        return self.location == TEXT_INPUT_RANGE_NOT_FOUND;
    }
};

/// The borrowed UTF-8 that `getSubstring` returns, plus the UTF-16 range actually taken.
pub const TextInputSubstring = struct {
    utf8: []const u8,
    actual_range: TextInputRange,
};

/// The bundle of Zig callbacks for IME document access.
/// Called synchronously from a C trampoline. getSubstring's utf8 is valid until the callback returns.
pub const TextInputDocumentCallbacks = struct {
    getSelectedRange: *const fn (*anyopaque) ?TextInputRange,
    getSubstring: *const fn (*anyopaque, TextInputRange) ?TextInputSubstring,
    replaceText: *const fn (*anyopaque, TextInputRange, []const u8) bool,
};

/// A mouse event. Coordinates are window coordinates (origin at the top-left of the window contentRect, in logical units).
/// Converting them to framebuffer or canvas coordinates is the caller's job.
pub const MouseEvent = struct {
    x: i32,
    y: i32,
    button: MouseButton, // .none on mouse_move; left/right/middle only on mouse_down/up
    buttons: MouseButtons, // the set of buttons currently held (post-state)
    modifiers: ModifierFlags,
};

/// A scroll event. dx and dy are in the same units as window coordinates.
pub const ScrollEvent = struct {
    x: i32,
    y: i32,
    dx: f32,
    dy: f32,
    is_precise: bool,
    buttons: MouseButtons,
    modifiers: ModifierFlags,
};

pub const Event = union(enum) {
    quit,
    key_down: KeyEvent,
    key_up: KeyEvent,
    char_input: CharEvent, // a committed text character (independent of key_down)
    mouse_move: MouseEvent,
    mouse_down: MouseEvent,
    mouse_up: MouseEvent,
    mouse_scroll: ScrollEvent,
    gamepad_connected: GamepadInfo, // a gamepad was connected (ADR-009)
    gamepad_disconnected: GamepadDisconnect, // a gamepad was disconnected
    /// Notification that the IME composition state changed. The text is read through the snapshot API.
    /// **Appended at the end**, so the breakage of exhaustive switches is confined the same way as for char_input.
    composition_changed: CompositionEvent,
    /// The id delivered to the application's command table from a native or GUI menu.
    /// **Always append at the end**; the backend's C ABI conversion happens on the backend side.
    menu_command: u32,
    /// An OS file drag and drop. **Appended at the end**. The path is inline owned bytes.
    /// The limit is `FILE_DROP_PATH_BYTES` (1024, macOS PATH_MAX). Over the limit, a NUL, or invalid UTF-8 is never constructed.
    file_drop: FileDropEvent,
};

/// The inline limit on a dropped file path (macOS PATH_MAX=1024; a longer path is rejected).
/// Putting 4KB into the Event union would waste a value copy on every event, so it is held to 1024.
pub const FILE_DROP_PATH_BYTES: usize = 1024;
/// Only a single file for now. The array length is kept for a future extension to several paths.
pub const FILE_DROP_MAX_PATHS: usize = 1;

pub const FileDropPath = struct {
    bytes: [FILE_DROP_PATH_BYTES]u8 = [_]u8{0} ** FILE_DROP_PATH_BYTES,
    len: u32 = 0,

    pub fn slice(self: *const FileDropPath) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const FileDropEvent = struct {
    paths: [FILE_DROP_MAX_PATHS]FileDropPath = undefined,
    count: u8 = 0,
};

/// Build a `FileDropEvent` from a single path (shared by the harness and the macOS facade).
/// Empty, containing a NUL, invalid UTF-8, or longer than `FILE_DROP_PATH_BYTES` gives `null` (no event is produced).
pub fn makeFileDropEventFromPath(path: []const u8) ?FileDropEvent {
    if (path.len == 0) return null;
    if (path.len > FILE_DROP_PATH_BYTES) return null;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return null;
    if (!std.unicode.utf8ValidateSlice(path)) return null;
    var drop: FileDropEvent = .{ .count = 1, .paths = undefined };
    drop.paths[0] = .{};
    @memcpy(drop.paths[0].bytes[0..path.len], path);
    drop.paths[0].len = @intCast(path.len);
    return drop;
}

// ============================================================================
// MIDI (ADR-010)
// ============================================================================
//
// MIDI has a different arrival rate and ownership model from window events, so it is not added to
// the Event union but published through the polling facade in core/midi.zig. note, controller and
// value hold the MIDI standard's 7-bit range (0..127) in a u8. The value range is validated at the
// backend boundary, before this type is built.

pub const MidiDeviceId = u32;

pub const MidiNoteEvent = struct {
    device_id: MidiDeviceId,
    note: u8, // MIDI note number: 0..127
    velocity: u8, // note_on velocity / note_off release velocity: 0..127
};

pub const MidiCcEvent = struct {
    device_id: MidiDeviceId,
    controller: u8, // MIDI controller number: 0..127
    value: u8, // MIDI controller value: 0..127
};

pub const MidiEvent = union(enum) {
    note_on: MidiNoteEvent,
    note_off: MidiNoteEvent,
    cc: MidiCcEvent,
};

/// Counters observed on the event queue (a snapshot of cumulative values)
pub const EventStats = struct {
    mouse_move_merge_count: u64,
    mouse_scroll_merge_count: u64,
    event_drop_count: u64,
};

// ============================================================================
// gamepads (ADR-009)
// ============================================================================
//
// The authority on the design is docs/adr/009_gamepad-input.md: polling is the main axis
// (Window.getGamepadState), with connection events (Event.gamepad_connected/disconnected). Only
// values already normalised to the standard layout are exposed (a native raw report stays inside the
// backend), and triggers are axes only, never buttons. The raw values are returned with no deadzone
// applied (a stick is -1..1, a trigger 0..1); applying one is left to `applyDeadzone()` in `src/gamepad.zig`.
//
// Call frequency: `GamepadState` is expected to be polled once per frame, but it is a fixed-length
// copy of four pads with a few fields each (no allocation, no lock), which is neither an all-pixel
// loop nor real time, so the performance rules do not apply (see the hot path declaration in ADR-009).

/// How many gamepads are supported at once (the single source for the length of the `gamepad_states`
/// array in `Window.getGamepadState` and in the harness).
pub const MAX_GAMEPADS: u8 = 4;

/// The buttons of the standard layout (15 of them; an exhaustive enum, per ADR-009).
/// The layout is fixed, so appending a value at the end is enough to extend it. Making it
/// non-exhaustive would demand an unknown-value branch in isSet, set, getButtonName and the harness parser alike.
pub const GamepadButton = enum(u8) {
    a,
    b,
    x,
    y,
    left_shoulder,
    right_shoulder,
    back,
    start,
    left_stick, // pressing the stick in (a click)
    right_stick,
    dpad_up,
    dpad_down,
    dpad_left,
    dpad_right,
    guide, // the Xbox button (the home button)
};

// ============================================================================
// GamepadButtons (a packed struct, LSB-first, matching C's PlatformGamepadButtonFlags)
// ============================================================================

pub const GamepadButtons = packed struct(u32) {
    a: bool = false,
    b: bool = false,
    x: bool = false,
    y: bool = false,
    left_shoulder: bool = false,
    right_shoulder: bool = false,
    back: bool = false,
    start: bool = false,
    left_stick: bool = false,
    right_stick: bool = false,
    dpad_up: bool = false,
    dpad_down: bool = false,
    dpad_left: bool = false,
    dpad_right: bool = false,
    guide: bool = false,
    _reserved: u17 = 0,

    pub inline fn fromC(raw: u32) GamepadButtons {
        return @bitCast(raw);
    }

    pub inline fn toC(self: GamepadButtons) u32 {
        return @bitCast(self);
    }

    pub fn isSet(self: GamepadButtons, btn: GamepadButton) bool {
        return switch (btn) {
            .a => self.a,
            .b => self.b,
            .x => self.x,
            .y => self.y,
            .left_shoulder => self.left_shoulder,
            .right_shoulder => self.right_shoulder,
            .back => self.back,
            .start => self.start,
            .left_stick => self.left_stick,
            .right_stick => self.right_stick,
            .dpad_up => self.dpad_up,
            .dpad_down => self.dpad_down,
            .dpad_left => self.dpad_left,
            .dpad_right => self.dpad_right,
            .guide => self.guide,
        };
    }

    pub fn set(self: *GamepadButtons, btn: GamepadButton, value: bool) void {
        switch (btn) {
            .a => self.a = value,
            .b => self.b = value,
            .x => self.x = value,
            .y => self.y = value,
            .left_shoulder => self.left_shoulder = value,
            .right_shoulder => self.right_shoulder = value,
            .back => self.back = value,
            .start => self.start = value,
            .left_stick => self.left_stick = value,
            .right_stick => self.right_stick = value,
            .dpad_up => self.dpad_up = value,
            .dpad_down => self.dpad_down = value,
            .dpad_left => self.dpad_left = value,
            .dpad_right => self.dpad_right = value,
            .guide => self.guide = value,
        }
    }
};

comptime {
    // Guarantees the bit positions match C's PlatformGamepadButtonFlags (a=bit0 … guide=bit14)
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .a = true })) == 0x0001);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .b = true })) == 0x0002);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .x = true })) == 0x0004);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .y = true })) == 0x0008);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .left_shoulder = true })) == 0x0010);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .right_shoulder = true })) == 0x0020);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .back = true })) == 0x0040);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .start = true })) == 0x0080);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .left_stick = true })) == 0x0100);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .right_stick = true })) == 0x0200);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .dpad_up = true })) == 0x0400);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .dpad_down = true })) == 0x0800);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .dpad_left = true })) == 0x1000);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .dpad_right = true })) == 0x2000);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .guide = true })) == 0x4000);
}

/// An analogue stick (raw values, -1.0..1.0, with no deadzone applied; ADR-009).
pub const Stick = struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// The normalised, pollable state of a gamepad (what `Window.getGamepadState` returns).
pub const GamepadState = struct {
    buttons: GamepadButtons = .{},
    left_stick: Stick = .{},
    right_stick: Stick = .{},
    left_trigger: f32 = 0, // raw values, 0.0..1.0
    right_trigger: f32 = 0, // raw values, 0.0..1.0
};

/// The maximum byte length of `GamepadInfo.name` (a UTF-8 byte sequence; no NUL is needed, since name_len holds the length).
pub const GAMEPAD_NAME_MAX: usize = 32;

/// The payload of a gamepad connection event. Only `name_len` bytes of `name` are valid
/// (a fixed-length buffer plus the length used, so it needs no allocator and rides in the Event union by value).
pub const GamepadInfo = struct {
    index: u8,
    name_len: u8 = 0,
    name_buf: [GAMEPAD_NAME_MAX]u8 = [_]u8{0} ** GAMEPAD_NAME_MAX,

    pub fn name(self: *const GamepadInfo) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// The payload of a gamepad disconnection event.
pub const GamepadDisconnect = struct {
    index: u8,
};

// ============================================================================
// file selection dialogs
// ============================================================================

/// The errors of a file dialog (used in the return type shared by every OS).
/// - DialogUnavailable: the dialog mechanism is unusable (on Linux, zenity is absent).
///   macOS and Windows do not normally return it (it is declared for type compatibility).
/// - DialogFailed: an unexpected failure (an abnormal exit, a signal, a broken environment).
/// - DialogPending: an asynchronous dialog is in progress (the wasm file picker; retry on the next frame).
///   A native backend never returns it (it is declared for type compatibility).
/// A user cancelling is not an error but a null. Running out of memory is an Allocator.Error.
pub const DialogError = error{ DialogUnavailable, DialogFailed, DialogPending };

pub const SaveDialogOptions = struct {
    default_name: ?[:0]const u8 = null,
    allowed_ext: ?[:0]const u8 = null,
};

pub const OpenDialogOptions = struct {
    allowed_ext: ?[:0]const u8 = null,
};

// ============================================================================
// CursorShape (the system cursor)
// ============================================================================
//
// There are only three values: identifying the current tool is left to a soft overlay, so the hard OS
// cursor serves the precision point alone and needs no more than crosshair, default and hidden. The
// values equal PlatformCursorShape in `platform.h` (the macOS backend passes the C values straight through).
//
// Call frequency: **at event time only** (a tool change, a key press). It is neither an all-pixel
// per-frame loop nor a real-time (per sample) path, so the performance rules do not apply.
pub const CursorShape = enum(c_int) {
    default = 0,
    crosshair = 1,
    hidden = 2,
};

test "ModifierFlags round trip via @bitCast" {
    const m = ModifierFlags{ .shift = true, .cmd = true };
    const raw = m.toC();
    try std.testing.expectEqual(@as(u32, 0x09), raw);
    const back = ModifierFlags.fromC(raw);
    try std.testing.expect(back.shift);
    try std.testing.expect(!back.ctrl);
    try std.testing.expect(!back.alt);
    try std.testing.expect(back.cmd);
}

test "GamepadButtons: isSet/set act independently on all 15 buttons and dirty no other bit" {
    var b = GamepadButtons{};
    inline for (@typeInfo(GamepadButton).@"enum".fields) |f| {
        const btn: GamepadButton = @enumFromInt(f.value);
        try std.testing.expect(!b.isSet(btn));
    }
    b.set(.a, true);
    b.set(.start, true);
    try std.testing.expect(b.isSet(.a));
    try std.testing.expect(b.isSet(.start));
    try std.testing.expect(!b.isSet(.b));
    try std.testing.expect(!b.isSet(.guide));
    b.set(.a, false);
    try std.testing.expect(!b.isSet(.a));
    try std.testing.expect(b.isSet(.start)); // the other bits are unchanged
}

test "GamepadButtons round trip via @bitCast (toC/fromC)" {
    var b = GamepadButtons{};
    b.set(.a, true);
    b.set(.guide, true);
    const raw = b.toC();
    try std.testing.expectEqual(@as(u32, 0x0001 | 0x4000), raw);
    const back = GamepadButtons.fromC(raw);
    try std.testing.expect(back.isSet(.a));
    try std.testing.expect(back.isSet(.guide));
    try std.testing.expect(!back.isSet(.b));
}

test "GamepadInfo.name: only the range name_len points at is returned" {
    var info = GamepadInfo{ .index = 0 };
    const src = "Pad";
    @memcpy(info.name_buf[0..src.len], src);
    info.name_len = src.len;
    try std.testing.expectEqualStrings("Pad", info.name());
}

test "Event: menu_command delivers the numeric id unchanged" {
    const ev: Event = .{ .menu_command = 0x1234 };
    switch (ev) {
        .menu_command => |id| try std.testing.expectEqual(@as(u32, 0x1234), id),
        else => return error.UnexpectedEvent,
    }
}

test "FileDrop: the copy and len of an ASCII path" {
    const drop = makeFileDropEventFromPath("/tmp/a.png").?;
    try std.testing.expectEqual(@as(u8, 1), drop.count);
    try std.testing.expectEqualStrings("/tmp/a.png", drop.paths[0].slice());
}

test "FileDrop: a path containing a space is kept" {
    const drop = makeFileDropEventFromPath("/tmp/My Image.png").?;
    try std.testing.expectEqualStrings("/tmp/My Image.png", drop.paths[0].slice());
}

test "FileDrop: a UTF-8 path is kept" {
    const drop = makeFileDropEventFromPath("/tmp/画像.png").?;
    try std.testing.expectEqualStrings("/tmp/画像.png", drop.paths[0].slice());
}

test "FileDrop: an empty path is rejected" {
    try std.testing.expect(makeFileDropEventFromPath("") == null);
}

test "FileDrop: a path containing a NUL is rejected" {
    try std.testing.expect(makeFileDropEventFromPath("a\x00b.png") == null);
}

test "FileDrop: a path of exactly the maximum length is accepted" {
    var buf: [FILE_DROP_PATH_BYTES]u8 = undefined;
    @memset(&buf, 'a');
    const drop = makeFileDropEventFromPath(&buf).?;
    try std.testing.expectEqual(@as(u32, FILE_DROP_PATH_BYTES), drop.paths[0].len);
}

test "FileDrop: a path over the maximum length is rejected" {
    var buf: [FILE_DROP_PATH_BYTES + 1]u8 = undefined;
    @memset(&buf, 'a');
    try std.testing.expect(makeFileDropEventFromPath(&buf) == null);
}

test "Event: file_drop is the last variant" {
    const tags = std.meta.tags(std.meta.Tag(Event));
    try std.testing.expectEqual(tags[tags.len - 1], .file_drop);
}

test "FileDrop: the fixed contract of count == 1" {
    const drop = makeFileDropEventFromPath("/tmp/x.png").?;
    try std.testing.expectEqual(@as(u8, 1), drop.count);
}

test "MidiEvent: all three variants keep the device id and the payload" {
    const note_on: MidiEvent = .{ .note_on = .{ .device_id = 7, .note = 60, .velocity = 100 } };
    const note_off: MidiEvent = .{ .note_off = .{ .device_id = 7, .note = 60, .velocity = 12 } };
    const cc: MidiEvent = .{ .cc = .{ .device_id = 7, .controller = 74, .value = 96 } };

    try std.testing.expectEqual(@as(MidiDeviceId, 7), note_on.note_on.device_id);
    try std.testing.expectEqual(@as(u8, 60), note_on.note_on.note);
    try std.testing.expectEqual(@as(u8, 100), note_on.note_on.velocity);
    try std.testing.expectEqual(@as(u8, 12), note_off.note_off.velocity);
    try std.testing.expectEqual(@as(u8, 74), cc.cc.controller);
    try std.testing.expectEqual(@as(u8, 96), cc.cc.value);
}

test "MidiEvent: the MIDI 7-bit boundary values 0 and 127 are kept" {
    const low: MidiEvent = .{ .cc = .{ .device_id = 0, .controller = 0, .value = 0 } };
    const high: MidiEvent = .{ .note_on = .{ .device_id = std.math.maxInt(MidiDeviceId), .note = 127, .velocity = 127 } };

    try std.testing.expectEqual(@as(u8, 0), low.cc.controller);
    try std.testing.expectEqual(@as(u8, 0), low.cc.value);
    try std.testing.expectEqual(@as(MidiDeviceId, std.math.maxInt(MidiDeviceId)), high.note_on.device_id);
    try std.testing.expectEqual(@as(u8, 127), high.note_on.note);
    try std.testing.expectEqual(@as(u8, 127), high.note_on.velocity);
}

test "WindowOptions: the defaults are backwards compatible (no transparency, no borderless, no position or size, a logical fb, resizable, not fullscreen)" {
    const opts: WindowOptions = .{};
    try std.testing.expect(!opts.transparent);
    try std.testing.expect(!opts.borderless);
    try std.testing.expect(opts.position == null);
    try std.testing.expect(opts.size == null);
    try std.testing.expectEqual(FramebufferMode.logical, opts.fb_mode);
    // An ordinary window is resizable and not fullscreen, so `.{}` still means what it always did.
    try std.testing.expect(opts.resizable);
    try std.testing.expect(!opts.fullscreen);
}

test "FramebufferMode: logical is the default and physical is opt-in" {
    try std.testing.expectEqual(FramebufferMode.logical, (WindowOptions{}).fb_mode);
    const phys: WindowOptions = .{ .fb_mode = .physical };
    try std.testing.expectEqual(FramebufferMode.physical, phys.fb_mode);
}

test "FramebufferSnapshot: logical==framebuffer under logical, and physical scale=2 doubles the size" {
    const logical: FramebufferSnapshot = .{
        .logical_size = .{ .width = 800, .height = 600 },
        .framebuffer_size = .{ .width = 800, .height = 600 },
        .content_scale = 1.0,
        .scale_epoch = 0,
    };
    try std.testing.expectEqual(logical.logical_size.width, logical.framebuffer_size.width);
    try std.testing.expectEqual(logical.logical_size.height, logical.framebuffer_size.height);

    const physical: FramebufferSnapshot = .{
        .logical_size = .{ .width = 800, .height = 600 },
        .framebuffer_size = .{ .width = 1600, .height = 1200 },
        .content_scale = 2.0,
        .scale_epoch = 1,
    };
    try std.testing.expectEqual(@as(u32, 800), physical.logical_size.width);
    try std.testing.expectEqual(@as(u32, 1600), physical.framebuffer_size.width);
    try std.testing.expectEqual(@as(f32, 2.0), physical.content_scale);
}

test "WindowOptions: the optional position and size values are kept" {
    const opts: WindowOptions = .{
        .position = .{ .x = 40, .y = -10 },
        .size = .{ .width = 720, .height = 480 },
    };
    try std.testing.expectEqual(@as(i32, 40), opts.position.?.x);
    try std.testing.expectEqual(@as(i32, -10), opts.position.?.y);
    try std.testing.expectEqual(@as(u32, 720), opts.size.?.width);
    try std.testing.expectEqual(@as(u32, 480), opts.size.?.height);
}

test "WindowGeometry: the position null contract (unsupported, or unreadable)" {
    const geo: WindowGeometry = .{
        .position = null,
        .size = .{ .width = 780, .height = 600 },
    };
    try std.testing.expect(geo.position == null);
    try std.testing.expectEqual(@as(u32, 780), geo.size.width);
    try std.testing.expectEqual(@as(u32, 600), geo.size.height);
}

test "RestoreGeometryLatch: a windowed observation is the value, a fullscreen one is ignored" {
    const windowed: WindowGeometry = .{ .position = .{ .x = 10, .y = 20 }, .size = .{ .width = 780, .height = 600 } };
    const screen: WindowGeometry = .{ .position = .{ .x = 0, .y = 0 }, .size = .{ .width = 3456, .height = 2234 } };

    var latch: RestoreGeometryLatch = .{ .geometry = windowed };
    // Windowed: the latch simply follows the current geometry.
    latch.observe(false, windowed);
    try std.testing.expectEqualDeep(windowed, latch.get(windowed));

    // Fullscreen: the current geometry is the screen, and the windowed value survives it.
    latch.observe(true, screen);
    try std.testing.expectEqualDeep(windowed, latch.get(screen));

    // Repeated fullscreen observations (a resize while fullscreen, a display change) never overwrite it.
    latch.observe(true, .{ .position = .{ .x = 0, .y = 0 }, .size = .{ .width = 1920, .height = 1080 } });
    try std.testing.expectEqualDeep(windowed, latch.get(screen));

    // Leaving fullscreen: the value only moves once the restored geometry has been observed.
    const restored: WindowGeometry = .{ .position = .{ .x = 10, .y = 20 }, .size = .{ .width = 900, .height = 700 } };
    latch.observe(false, restored);
    try std.testing.expectEqualDeep(restored, latch.get(restored));
}

test "RestoreGeometryLatch: a window created fullscreen keeps the geometry it was seeded with" {
    // Nothing windowed is ever observed, so the seed — the size the application asked for — is what
    // an application persists, instead of the screen it is filling.
    const requested: WindowGeometry = .{ .position = null, .size = .{ .width = 1280, .height = 720 } };
    var latch: RestoreGeometryLatch = .{ .geometry = requested, .fullscreen = true };
    const screen: WindowGeometry = .{ .position = null, .size = .{ .width = 2560, .height = 1440 } };
    latch.observe(true, screen);
    try std.testing.expectEqualDeep(requested, latch.get(screen));
}

test "TextInputRange NOT_FOUND sentinel is UINT64_MAX" {
    try std.testing.expectEqual(std.math.maxInt(u64), TEXT_INPUT_RANGE_NOT_FOUND);
    const nf: TextInputRange = .{ .location = TEXT_INPUT_RANGE_NOT_FOUND, .length = 0 };
    try std.testing.expect(nf.isNotFound());
    const ok: TextInputRange = .{ .location = 0, .length = 3 };
    try std.testing.expect(!ok.isNotFound());
}

// ============================================================================
// PresentMapping (ADR-030 R3, R4)
// ============================================================================

// The scenarios the upscale benchmark measures, so that the mapping the benchmark assumes and the
// mapping the platform computes cannot drift apart.
test "PresentMapping.letterbox: the destination rectangle and its origin, in physical pixels" {
    const fb: WindowSize = .{ .width = 640, .height = 400 };
    const Case = struct { win: WindowSize, dst: WindowSize, origin: WindowPosition };
    const cases = [_]Case{
        // A wider window than the framebuffer's aspect: bars on the left and right.
        .{ .win = .{ .width = 5120, .height = 2880 }, .dst = .{ .width = 4608, .height = 2880 }, .origin = .{ .x = 256, .y = 0 } },
        .{ .win = .{ .width = 3840, .height = 2160 }, .dst = .{ .width = 3456, .height = 2160 }, .origin = .{ .x = 192, .y = 0 } },
        // The same aspect ratio: no bars, a whole-number magnification.
        .{ .win = .{ .width = 2560, .height = 1600 }, .dst = .{ .width = 2560, .height = 1600 }, .origin = .{ .x = 0, .y = 0 } },
        .{ .win = .{ .width = 1280, .height = 800 }, .dst = .{ .width = 1280, .height = 800 }, .origin = .{ .x = 0, .y = 0 } },
        // Taller than the framebuffer's aspect: bars above and below.
        .{ .win = .{ .width = 900, .height = 1600 }, .dst = .{ .width = 900, .height = 562 }, .origin = .{ .x = 0, .y = 519 } },
        // Smaller than the framebuffer: the same rule with a magnification below one.
        .{ .win = .{ .width = 400, .height = 400 }, .dst = .{ .width = 400, .height = 250 }, .origin = .{ .x = 0, .y = 75 } },
    };
    for (cases) |c| {
        const m = PresentMapping.letterbox(c.win, fb);
        try std.testing.expectEqual(c.dst.width, m.dst_size.width);
        try std.testing.expectEqual(c.dst.height, m.dst_size.height);
        try std.testing.expectEqual(c.origin.x, m.origin.x);
        try std.testing.expectEqual(c.origin.y, m.origin.y);
        // The rectangle always fits inside the window it was derived from.
        try std.testing.expect(m.origin.x >= 0 and m.origin.y >= 0);
        try std.testing.expect(m.dst_size.width + @as(u32, @intCast(m.origin.x)) <= c.win.width);
        try std.testing.expect(m.dst_size.height + @as(u32, @intCast(m.origin.y)) <= c.win.height);
    }
}

test "PresentMapping.letterbox: a window with no area maps nothing" {
    const fb: WindowSize = .{ .width = 640, .height = 400 };
    for ([_]WindowSize{
        .{ .width = 0, .height = 600 },
        .{ .width = 800, .height = 0 },
        .{ .width = 0, .height = 0 },
    }) |win| {
        const m = PresentMapping.letterbox(win, fb);
        try std.testing.expectEqual(@as(u32, 0), m.dst_size.width);
        try std.testing.expectEqual(@as(u32, 0), m.dst_size.height);
    }
}

test "PresentMapping.letterbox: the one-pixel clamp is the only case that drops the aspect ratio" {
    const fb: WindowSize = .{ .width = 640, .height = 400 };
    // A window one pixel tall cannot hold a 640x400 aspect at any whole size, so the clamp decides.
    const m = PresentMapping.letterbox(.{ .width = 640, .height = 1 }, fb);
    try std.testing.expectEqual(@as(u32, 1), m.dst_size.height);
    try std.testing.expect(m.dst_size.width >= 1);
    // A mapping that exists beats a rule that holds: the aspect ratio is not preserved here.
    const aspect_fb = @as(f64, 640.0) / 400.0;
    const aspect_dst = @as(f64, @floatFromInt(m.dst_size.width)) / @as(f64, @floatFromInt(m.dst_size.height));
    try std.testing.expect(aspect_dst != aspect_fb);
}

test "PresentMapping: magnifying, the inverse undoes the forward for every framebuffer pixel" {
    const fb: WindowSize = .{ .width = 64, .height = 40 };
    for ([_]WindowSize{
        .{ .width = 512, .height = 288 }, // bars left and right, a fractional magnification
        .{ .width = 256, .height = 160 }, // exactly 4x, no bars
        .{ .width = 90, .height = 160 }, // bars above and below
    }) |win| {
        const m = PresentMapping.letterbox(win, fb);
        try std.testing.expect(m.dst_size.width >= m.fb_size.width);
        var x: i32 = 0;
        while (x < @as(i32, @intCast(fb.width))) : (x += 1) {
            var y: i32 = 0;
            while (y < @as(i32, @intCast(fb.height))) : (y += 1) {
                const p = m.framebufferToPhysical(x, y);
                const back = m.physicalToApp(p.x, p.y);
                try std.testing.expectEqual(x, back.x);
                try std.testing.expectEqual(y, back.y);
            }
        }
    }
}

test "PresentMapping: magnifying, the first and last destination pixels reach the framebuffer's edges" {
    // The defect this pins: an inverse that disagrees with the forward by one pixel leaves the
    // outermost column or row of the framebuffer impossible to point at.
    const fb: WindowSize = .{ .width = 640, .height = 400 };
    for ([_]WindowSize{
        .{ .width = 5120, .height = 2880 },
        .{ .width = 1280, .height = 800 },
        .{ .width = 900, .height = 1600 },
    }) |win| {
        const m = PresentMapping.letterbox(win, fb);
        const first = m.physicalToApp(m.origin.x, m.origin.y);
        try std.testing.expectEqual(@as(i32, 0), first.x);
        try std.testing.expectEqual(@as(i32, 0), first.y);
        const last = m.physicalToApp(
            m.origin.x + @as(i32, @intCast(m.dst_size.width)) - 1,
            m.origin.y + @as(i32, @intCast(m.dst_size.height)) - 1,
        );
        try std.testing.expectEqual(@as(i32, @intCast(fb.width)) - 1, last.x);
        try std.testing.expectEqual(@as(i32, @intCast(fb.height)) - 1, last.y);
    }
}

test "PresentMapping: minifying, the inverse stays in range and never goes backwards" {
    // Several framebuffer pixels share one destination pixel here, so the round trip is not the
    // identity and the endpoint assertion above does not hold. What must hold is that every
    // destination pixel names a framebuffer pixel that exists, in order.
    const fb: WindowSize = .{ .width = 640, .height = 400 };
    const m = PresentMapping.letterbox(.{ .width = 320, .height = 200 }, fb);
    try std.testing.expect(m.dst_size.width < m.fb_size.width);
    var prev: i32 = -1;
    var x: i32 = 0;
    while (x < @as(i32, @intCast(m.dst_size.width))) : (x += 1) {
        const app = m.physicalToApp(m.origin.x + x, m.origin.y);
        try std.testing.expect(app.x >= 0 and app.x < @as(i32, @intCast(fb.width)));
        try std.testing.expect(app.x >= prev);
        prev = app.x;
    }
}

test "PresentMapping: over the letterbox the result is outside the framebuffer, not clamped" {
    const fb: WindowSize = .{ .width = 640, .height = 400 };
    const m = PresentMapping.letterbox(.{ .width = 5120, .height = 2880 }, fb);
    try std.testing.expect(m.origin.x > 0);
    // A pixel to the left of the destination rectangle is a negative framebuffer coordinate.
    const left = m.physicalToApp(m.origin.x - 1, m.origin.y);
    try std.testing.expect(left.x < 0);
    // One past the right edge is past the framebuffer's last column.
    const right = m.physicalToApp(m.origin.x + @as(i32, @intCast(m.dst_size.width)), m.origin.y);
    try std.testing.expect(right.x >= @as(i32, @intCast(fb.width)));
}

test "PresentMapping.covering: the mode decides, because the snapshot cannot be divided back out" {
    // `.physical` allocates round(logical * scale), so recovering the scale by division lands beside
    // 1.0 rather than on it. 801 x 1.5 -> 1201.5 -> 1202 is the case that shows it.
    const physical: FramebufferSnapshot = .{
        .logical_size = .{ .width = 801, .height = 601 },
        .framebuffer_size = .{ .width = 1202, .height = 902 },
        .content_scale = 1.5,
        .scale_epoch = 1,
    };
    const pm = PresentMapping.covering(.physical, physical);
    // The framebuffer is the window, exactly: forward is the identity.
    try std.testing.expectEqual(@as(i32, 1201), pm.framebufferToPhysical(1201, 0).x);
    // And the inverse still divides by the real scale, because the application is in logical points.
    try std.testing.expectEqual(@as(i32, 800), pm.physicalToApp(1201, 0).x);
    try std.testing.expectEqual(@as(u32, 1202), pm.dst_size.width);

    const logical: FramebufferSnapshot = .{
        .logical_size = .{ .width = 801, .height = 601 },
        .framebuffer_size = .{ .width = 801, .height = 601 },
        .content_scale = 1.5,
        .scale_epoch = 1,
    };
    const lm = PresentMapping.covering(.logical, logical);
    // The framebuffer is in logical points, so the forward direction magnifies by the scale, and
    // the two directions still undo one another.
    try std.testing.expectEqual(@as(u32, 1202), lm.dst_size.width);
    const lp = lm.framebufferToPhysical(800, 0);
    try std.testing.expectEqual(@as(i32, 800), lm.physicalToApp(lp.x, 0).x);
    try std.testing.expectEqual(@as(i32, 0), lm.origin.x);

    // A fullscreen window resolves its own size in physical pixels and derives the logical one, so
    // the two do not round-trip; the mode still answers exactly.
    const fs: FramebufferSnapshot = .{
        .logical_size = .{ .width = 1707, .height = 960 },
        .framebuffer_size = .{ .width = 2560, .height = 1440 },
        .content_scale = 1.5,
        .scale_epoch = 2,
    };
    const fsm = PresentMapping.covering(.physical, fs);
    try std.testing.expectEqual(@as(i32, 2559), fsm.framebufferToPhysical(2559, 0).x);
}

test "PresentMapping.covering: a content scale that is not a usable number falls back to 1.0" {
    const snap: FramebufferSnapshot = .{
        .logical_size = .{ .width = 320, .height = 200 },
        .framebuffer_size = .{ .width = 320, .height = 200 },
        .content_scale = 0.0,
        .scale_epoch = 0,
    };
    try std.testing.expectEqual(@as(u32, 320), PresentMapping.covering(.logical, snap).dst_size.width);
    const nan_snap: FramebufferSnapshot = .{
        .logical_size = .{ .width = 320, .height = 200 },
        .framebuffer_size = .{ .width = 320, .height = 200 },
        .content_scale = std.math.nan(f32),
        .scale_epoch = 0,
    };
    try std.testing.expectEqual(@as(u32, 320), PresentMapping.covering(.logical, nan_snap).dst_size.width);
}

test "framebufferRectToPhysical: both edges are converted, so adjacent rectangles stay adjacent" {
    const m = PresentMapping.letterbox(.{ .width = 1000, .height = 1000 }, .{ .width = 300, .height = 300 });
    // 1000/300 is not a whole number, which is where scaling an extent on its own drifts.
    const a = framebufferRectToPhysical(m, 0, 0, 7, 7);
    const b = framebufferRectToPhysical(m, 7, 7, 7, 7);
    try std.testing.expectEqual(a.x + a.w, b.x);
    try std.testing.expectEqual(a.y + a.h, b.y);
    // And the whole framebuffer maps onto the whole destination rectangle.
    const all = framebufferRectToPhysical(m, 0, 0, 300, 300);
    try std.testing.expectEqual(m.origin.x, all.x);
    try std.testing.expectEqual(@as(i32, @intCast(m.dst_size.width)), all.w);
}

test "FramebufferMode: a fixed framebuffer carries its size" {
    const opts: WindowOptions = .{ .fb_mode = .{ .fixed = .{ .width = 640, .height = 400 } } };
    switch (opts.fb_mode) {
        .fixed => |size| {
            try std.testing.expectEqual(@as(u32, 640), size.width);
            try std.testing.expectEqual(@as(u32, 400), size.height);
        },
        .logical, .physical => return error.TestUnexpectedResult,
    }
}

test "refuseFixedFramebuffer: only a fixed framebuffer is refused" {
    try std.testing.expectError(error.Unsupported, refuseFixedFramebuffer(.{ .fixed = .{ .width = 640, .height = 400 } }));
    try refuseFixedFramebuffer(.logical);
    try refuseFixedFramebuffer(.physical);
}

test "FramebufferMode: a fixed framebuffer follows neither the window's pixels nor its points" {
    try std.testing.expect((FramebufferMode{ .physical = {} }).tracksPhysicalPixels());
    try std.testing.expect(!(FramebufferMode{ .physical = {} }).tracksLogicalPoints());
    try std.testing.expect((FramebufferMode{ .logical = {} }).tracksLogicalPoints());
    try std.testing.expect(!(FramebufferMode{ .logical = {} }).tracksPhysicalPixels());
    const fixed: FramebufferMode = .{ .fixed = .{ .width = 640, .height = 400 } };
    try std.testing.expect(!fixed.tracksPhysicalPixels());
    try std.testing.expect(!fixed.tracksLogicalPoints());
}
