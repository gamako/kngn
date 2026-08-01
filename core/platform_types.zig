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

/// The framebuffer resolution mode (ADR-011 R1). The default `.logical` keeps today's behaviour;
/// `.physical` is opt-in (a framebuffer in physical pixels while the coordinates stay logical).
pub const FramebufferMode = enum {
    logical,
    physical,
};

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
