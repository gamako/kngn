//! The headless verification harness: file replay plus the fb probe, and live TCP plus the audio and stats probes.
//!
//! The purpose: to give an existing application, unmodified and through the hooks in `src/platform.zig` (the facade), all of
//!   - input injection (keys, the mouse, scrolling)
//!   - a virtual clock (getTime = frame_index/60)
//!   - probes (`fb` as PNG or a digest, `audio` as WAV or a digest, `stats` as JSON)
//! With the environment unset, every API is a no-op (matching existing behaviour exactly).
//!
//! ## The transports (where a command comes from)
//! - **replay (a file)**: `KNGN_HARNESS_SCRIPT=<file>` is read in full, always on a manual clock. step advances a virtual frame, and EOF or quit exits automatically.
//! - **listen (TCP loopback)**: `KNGN_HARNESS_LISTEN[=port]` listens on `127.0.0.1`.
//!   No value, an empty value or `0` means ephemeral, and a positive value a fixed port. The default is the free-run clock (the application runs itself, with a non-blocking drain).
//!   Adding `KNGN_HARNESS_MANUAL_CLOCK=1` gives the equivalent of the older step-driven behaviour (a blocking accept and read).
//! - **The script format == the listen protocol**: the parser and the execution model are shared. They differ only in the source (a file or a socket) and
//!   the clock mode (manual is driven by the gate, while free-run waits on a frame barrier or an await).
//!
//! ## The response sink and the framing
//! The core payload of a digest or a snapshot is shared; the sink decides the framing:
//!   - replay: to stderr, `[harness] digest <probe> <payload>` / `[harness] snapshot <probe> -> <path> (<info>)`
//!   - live  : to the connection, an unprefixed protocol line `<probe> <payload>` / `<path>`
//!
//! ## record and replay are symmetrical
//! Appending the commands received live to `KNGN_HARNESS_RECORD=<file>` gives a file that can be passed to `KNGN_HARNESS_SCRIPT` and replayed
//! (the grammar and the state transitions are symmetrical. `fb` is bit-deterministic under the virtual clock, while `audio` depends on real time in the RT thread and is not guaranteed bit-identical).
//!
//! ## What it depends on, and what it does not
//! - The imports are `std`, `platform_types.zig` (the shared types), `png` (the encoder plus crc32) and `dsp` (the FFT and spectrum analysis), and nothing else.
//!   It depends on neither a backend (platform_macos, platform_linux*) nor an audio backend. Audio samples are pushed in by the `audio.zig` facade
//!   through `onAudioSamples()` (so the dependency runs audio→harness).
//! - The facade hooks carry no io, so file IO and TCP are done by harness through its own `std.Io.Threaded` io.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const types = @import("platform_types");
const png = @import("png");
const dsp = @import("dsp"); // magnitudeSpectrum (band, centroid, onset). Never called on a real-time path
const capture_synthetic = @import("capture_synthetic"); // the synthetic capture source
pub const action_registry = @import("action_registry.zig"); // the Action and registry split
pub const netsync = @import("netsync.zig"); // PROPOSE/COMMIT/REJECT (sharing the one action_registry instance)

const Event = types.Event;
const KeyCode = types.KeyCode;
const KeyEvent = types.KeyEvent;
const MouseEvent = types.MouseEvent;
const ScrollEvent = types.ScrollEvent;
const MouseButton = types.MouseButton;
const MouseButtons = types.MouseButtons;
const ModifierFlags = types.ModifierFlags;
const EventStats = types.EventStats;
const GamepadButton = types.GamepadButton;
const GamepadState = types.GamepadState;
const GamepadInfo = types.GamepadInfo;
const GamepadDisconnect = types.GamepadDisconnect;
const CompositionPhase = types.CompositionPhase;
const CompositionSnapshot = types.CompositionSnapshot;
const MidiEvent = types.MidiEvent;
const MidiDeviceId = types.MidiDeviceId;
const GAMEPAD_NAME_MAX = types.GAMEPAD_NAME_MAX;
const MAX_GAMEPADS = types.MAX_GAMEPADS;

const net = std.Io.net;

const gpa = std.heap.page_allocator;
const Tok = std.mem.TokenIterator(u8, .any);

/// The virtual frame rate while harness is enabled (a fixed value consistent with getTime=frame/60; it is not a performance measurement).
const VIRTUAL_FPS: f64 = 60.0;

// The audio tap (a latest-wins SPSC queue). The producer, the RT thread, advances head and writes (overwriting even when full);
// the consumer, the main thread, peeks non-destructively at the most recent window.
const AUDIO_CAP: usize = 1 << 16; // the number of interleaved f32 samples (about 0.68s of 48kHz stereo)
const AUDIO_MASK: usize = AUDIO_CAP - 1;
const ANALYZE_FRAMES: usize = 4096; // the digest analysis window (in mono frames; for the existing rms, peak and f0 — do not change it)
const EXT_FRAMES: usize = 32768; // the extended analysis window (large enough for LUFS's 400ms@48k=19200; at most about 0.68s)
const EXT_FFT_N: usize = 4096; // the FFT size for band and centroid
const ONSET_FFT_N: usize = 2048; // the FFT size for onset detection
const ONSET_HOP: usize = 1024; // the hop for onset detection
const LUFS_FLOOR: f32 = -99.0; // the LUFS floor for silence, and for too short a window

// ============================================================================
// module-level state (a debug facility assuming a single process and a single window)
// ============================================================================
const Mode = enum { disabled, replay, live };
/// Clock ownership. replay is always manual. LISTEN defaults to free_run, and MANUAL_CLOCK=1 makes it manual.
const ClockMode = enum { manual, free_run };
var mode: Mode = .disabled;
var clock_mode: ClockMode = .manual;
var initialized = false;

// The shared buffer holding the command source (replay = the whole script; live = the current request)
var cmd_buf: []const u8 = "";
var cursor: usize = 0;
var line_no: usize = 0;
var steps_remaining: usize = 0;
var quit_requested = false;

// The failure counter for expect and assert, plus action (**replay only**; live does not use it, since
// there the outcome is the response line alone). At the end of a replay, >0 exits non-zero. resetForTest clears it.
var expect_failures: usize = 0;

// The script bytes for a replay (held for the life of the process; page_allocator)
var script_bytes: []const u8 = "";

// frame
var frame_index: u64 = 0;

// Where output goes when a snapshot path is omitted. The environment string is valid for the life of the process.
var out_dir: []const u8 = ".";
var port_file_buf: [1024]u8 = undefined;

// This frame's injected events (queued by pollGate and drained by nextEvent)
var inject_buf: [256]Event = undefined;
var inject_count: usize = 0;
var inject_read: usize = 0;

// The synthetic MIDI FIFO and state. Kept independent of the Window event queue, so that
// only the midi facade's pollMidi() reads the FIFO. The state is updated at injection time, so that
// `digest midi` can observe the last logical state even before the application drains it.
const MIDI_FIFO_CAP: usize = 256;
var midi_buf: [MIDI_FIFO_CAP]MidiEvent = undefined;
var midi_count: usize = 0;
var midi_read: usize = 0;
var midi_pressed: [16]u8 = [_]u8{0} ** 16;
var midi_cc_values: [128]u8 = [_]u8{0} ** 128;
var midi_cc_set: [128]bool = [_]bool{false} ** 128;

// The mouse state (for building consistent move, down, up and scroll events)
var mouse_x: i32 = 0;
var mouse_y: i32 = 0;
var mouse_buttons: MouseButtons = .{};

// The gamepad state. Updated by inject gamepad_connect, gamepad_disconnect, gamepad_button and gamepad_axis,
// and read by the facade's Window.getGamepadState and by the built-in `gamepad` probe. null = not connected.
var gamepad_states: [MAX_GAMEPADS]?GamepadState = [_]?GamepadState{null} ** MAX_GAMEPADS;

// A synthetic IME composition. The text is a latest-wins snapshot, and the events notify of a state change.
const COMPOSITION_CAP: usize = 1024;
var composition_text: [COMPOSITION_CAP]u8 = undefined;
var composition_len: usize = 0;
var composition_cursor: usize = 0;
var composition_revision: u32 = 0;
var composition_active = false;

// The current framebuffer view recorded by lockFramebuffer (valid until present or unlock)
var lock_pixels: []const u32 = &.{};
var lock_w: u32 = 0;
var lock_h: u32 = 0;
var lock_valid = false;

// The most recently presented frame (an owned copy, whose buffer is reused as it grows)
var frame_pixels: []u32 = &.{};
var frame_w: u32 = 0;
var frame_h: u32 = 0;
var have_frame = false;

// The most recent EventStats (pushed by present)
var last_stats: EventStats = .{ .mouse_move_merge_count = 0, .mouse_scroll_merge_count = 0, .event_drop_count = 0 };

// Count of injected events that a registered probe's input_blocker reported as consumed.
// Exposed via `digest stats` as `modal_blocked_injections`. Does not affect expect_failures or exit codes.
var modal_blocked_injections: u64 = 0;
// Rate-limit key for the blocked-injection warning: last non-null label that already warned.
// Resets to null when a blocker returns null, so the next non-null label warns again.
var last_blocker_warn_label: ?[]const u8 = null;

// The null runtime query (platform settles KNGN_HEADLESS and exposes it as a compatibility query).
// The primary framebuffer is owned by platform_null.Window; harness only hooks observation.
var config_parsed = false;
var pending_script_path: ?[]const u8 = null;
var pending_listen_raw: ?[]const u8 = null; // The environment value, when present. Interpreting the port is startTransport's job
var pending_manual_clock = false;
var headless_active = false;

// A measurement-only mode that skips the frame copy on each present (the KNGN_HARNESS_SKIP_FRAME_COPY variable).
// The default is false, matching the old behaviour bit for bit. While it is on, the snapshot and digest of `fb`, `canvas` and
// friends hold meaningless values, but `digest stats`'s frame counter still increments, so it remains usable for measuring fps.
var skip_frame_copy = false;

// The synthetic capture source: a fake mic and camera built into harness. There is no facade wiring into
// camera.zig or audio.zig; it is self-contained within this module (the `capture` command plus the `capture` probe).
var capture_synthetic_requested = false; // KNGN_HARNESS_CAPTURE_SYNTHETIC env
var synth_video: ?capture_synthetic.SyntheticVideoDevice = null;
var synth_audio: ?capture_synthetic.SyntheticAudioDevice = null;

// The custom probe registry (an application registers by opting in; the framework does not interpret the contents and merely routes the raw bytes and the digest)
// Being a single-process debug facility, a fixed-length module-level array is enough (there is no dynamic allocation).
const MAX_PROBES = 16;
pub const DIGEST_BUF_LEN = 1024; // The length of the shared buffer handed to a custom digest callback (copilot uses the same contract)
var probes: [MAX_PROBES]Probe = undefined;
var probe_count: usize = 0;

// io (0.16 has no blocking std.fs API, only what goes through std.Io). Used for both file access and TCP.
var threaded: std.Io.Threaded = undefined;
var io_val: std.Io = undefined;

// live transport
var server: net.Server = undefined;
var live_stream: net.Stream = undefined;
var live_req_open = false;
var live_stream_owned = false; // close only once it has been accepted (which guards against a test's simulated request)
var req_bytes: []u8 = &.{}; // The current request (freed when it finishes)
var resp_buf: std.ArrayList(u8) = .empty;

// free-run: the non-blocking read after an accept and before the request is complete (kept apart from manual's blocking receiver)
var freerun_reading = false;
var freerun_acc: std.ArrayList(u8) = .empty;
/// test-only: how many times a free-run empty drain called poll(timeout=0) on the listener.
var test_poll_zero_count: usize = 0;

// record (the log of live commands)
var record_path: ?[]const u8 = null;
var record_buf: std.ArrayList(u8) = .empty;

// The timeout (in ms) of a live fd poll. Only a test may shorten it, to avoid a flaky result.
var test_live_poll_timeout_ms: ?i32 = null;
const live_poll_timeout_default_ms: i32 = 16;

// audio tap
var audio_buf: [AUDIO_CAP]f32 = undefined;
var audio_head: std.atomic.Value(usize) = .init(0);
var audio_channels: std.atomic.Value(u32) = .init(0);
var audio_rate: std.atomic.Value(u32) = .init(0);
var audio_scratch: [AUDIO_CAP]f32 = undefined; // where to peek (the main thread)
var audio_mono: [ANALYZE_FRAMES]f32 = undefined; // the downmix scratch (the main thread; the existing analyzeAudio)
var audio_mono_ext: [EXT_FRAMES]f32 = undefined; // the downmix for the extended analysis (the main thread)
// the FFT scratch (only when a digest is asked for; never touched by the RT thread. Module-level, to avoid an allocation)
var ext_fft_re: [EXT_FFT_N]f32 = undefined;
var ext_fft_im: [EXT_FFT_N]f32 = undefined;
var ext_mags: [EXT_FFT_N / 2]f32 = undefined;
var onset_fft_re: [ONSET_FFT_N]f32 = undefined;
var onset_fft_im: [ONSET_FFT_N]f32 = undefined;
var onset_mags_cur: [ONSET_FFT_N / 2]f32 = undefined;
var onset_mags_prev: [ONSET_FFT_N / 2]f32 = undefined;
var onset_win: [ONSET_FFT_N]f32 = undefined;

// ============================================================================
// public: initialisation and the hook API (called from the platform.zig facade)
// ============================================================================

pub fn isEnabled() bool {
    return mode != .disabled;
}

/// Whether the clock is manual (replay, or LISTEN with MANUAL_CLOCK). What decides a virtual getTime, a no-op frameDelay, and a blocking gate.
pub fn isManualClock() bool {
    return isEnabled() and clock_mode == .manual;
}

/// The flag by which an external control plane (copilot) enables registration in the probe registry.
/// The action side forwards to `action_registry.setEnabled` (an OR condition).
/// The dependency runs one way, copilot→harness; harness never calls a copilot function.
var external_registry_enabled = false;

/// An external transport (copilot, say) opens the registration gate of the probe and action registries.
/// - probe: `registerProbe`'s test becomes `isEnabled() or this flag`.
/// - action: only `v==true` forwards to `action_registry.setEnabled(true)`.
///   `false` is never passed on to action_registry (disabling requires `action_registry.resetForTest`).
pub fn setExternalRegistryEnabled(v: bool) void {
    external_registry_enabled = v;
    if (v) action_registry.setEnabled(true);
}

/// The registration gate of the probe registry (harness enabled, or an external transport enabled).
/// The action gate is `action_registry.enabled` alone (registerProbe's gate stays here).
fn registryEnabled() bool {
    return isEnabled() or external_registry_enabled;
}

/// The native event pump callback harness calls while waiting on an accept or a read, with a real display and live.
/// When `pollFn` returns `false` the live wait is broken off, as a window close or a compositor disconnect.
pub const NativePump = struct {
    ptr: *anyopaque,
    pollFn: *const fn (*anyopaque) bool,

    pub fn poll(self: NativePump) bool {
        return self.pollFn(self.ptr);
    }
};

/// The args signature type shared by actions and probes (action_registry is the single source).
pub const ArgSpec = action_registry.ArgSpec;

/// A probe callback that reports whether an injected event will be consumed by application state
/// (a full-absorb modal, size-dialog confirm keys, inline text edit, …) instead of the main surface.
/// Returns a static label (`"recovery"`, `"confirmation"`, `"size"`, `"text_edit"`, …) when the
/// event is consumed, or null when it is not. The callback may inspect `event` so the answer can
/// depend on the event kind and payload. harness never interprets the label beyond rate-limiting
/// the warning and including it in the message.
pub const InputBlocker = *const fn (ctx: *anyopaque, event: Event) ?[]const u8;

/// A custom probe an application registers. **The framework does not interpret its contents**:
/// it writes the raw bytes snapshot returns straight to a file, and passes the one line digest returns to the existing sink.
/// All the meaning of a probe (turning it into a PNG, formatting JSON) is closed inside the application's callback.
pub const Probe = struct {
    /// The probe name (the argument of a snapshot or digest command. fb, audio, stats, capabilities and capture are reserved and cannot be registered).
    name: []const u8,
    /// The opaque context handed to the callback (a pointer to the application's state).
    ctx: *anyopaque,
    /// The default extension used when a path is omitted ("png", "json", "txt" and so on).
    ext: []const u8 = "bin",
    /// Returns raw bytes allocated with allocator. harness writes them to a file and frees them with the same allocator.
    /// null means snapshot is unsupported.
    snapshot: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 = null,
    /// Writes one line of text into buf (DIGEST_BUF_LEN bytes) and returns it, with no newline in it. null means digest is unsupported.
    digest: ?*const fn (ctx: *anyopaque, buf: []u8) []const u8 = null,
    /// The description for the capabilities listing (optional). At registration `sanitizeDesc` checks for
    /// forbidden characters (`"`, `\`, ASCII control characters) and for over 200 bytes, and empties it on a violation
    /// (this protects the wire framing of the capabilities JSON; it is not an interpretation of the contents).
    desc: []const u8 = "",
    /// The args signature (optional, backwards compatible). The same contract as Action's:
    /// **null = unspecified (no args in the JSON) / an empty slice = explicitly no arguments**. Every probe today leaves it null.
    args: ?[]const ArgSpec = null,
    /// Optional self-report: called only from `nextInjectedEvent` for harness-injected events (never for native input).
    /// A non-null return means application state will consume the event; the event is still delivered unchanged.
    input_blocker: ?InputBlocker = null,
};

/// Registers a custom probe. An application calls it through `platform.registerProbe(...)` after `platform.init()`.
/// - With harness disabled (the environment unset) this is a **no-op** (it does not touch the registry at all, so a normal run has zero regression).
/// - The same name overwrites. fb, audio, stats, capabilities and capture are reserved and rejected. A full registry is skipped (each with a warning).
pub fn registerProbe(p: Probe) void {
    if (!registryEnabled()) return;
    if (isReservedProbeName(p.name)) {
        std.debug.print("[harness] registerProbe: the reserved name '{s}' cannot be registered\n", .{p.name});
        return;
    }
    for (probes[0..probe_count]) |*existing| {
        if (std.mem.eql(u8, existing.name, p.name)) {
            var mp = p;
            mp.desc = sanitizeDesc("probe", p.name, p.desc); // Sanitise only right before actually storing it (so a skip on a full registry emits no pointless warning)
            mp.args = sanitizeArgs("probe", p.name, p.args);
            existing.* = mp; // the same name overwrites
            return;
        }
    }
    if (probe_count >= MAX_PROBES) {
        std.debug.print("[harness] registerProbe: the registry is full ({d}); skipping '{s}'\n", .{ MAX_PROBES, p.name });
        return;
    }
    var mp = p;
    mp.desc = sanitizeDesc("probe", p.name, p.desc);
    mp.args = sanitizeArgs("probe", p.name, p.args);
    probes[probe_count] = mp;
    probe_count += 1;
}

fn isReservedProbeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "fb") or std.mem.eql(u8, name, "audio") or std.mem.eql(u8, name, "stats") or
        std.mem.eql(u8, name, "capabilities") or std.mem.eql(u8, name, "capture") or
        std.mem.eql(u8, name, "gamepad") or std.mem.eql(u8, name, "midi");
}

/// Decides whether a string holds a character that would corrupt a JSON string if embedded unescaped (`"`, `\`,
/// or an ASCII control character `0x00..0x1F`, tab and NUL included). Shared by `sanitizeDesc` (at registration)
/// and by assembling a capabilities entry (at format time, as a defensive check on name and ext).
fn containsUnsafeJsonChar(s: []const u8) bool {
    for (s) |c| {
        if (c == '"' or c == '\\' or c < 0x20) return true;
    }
    return false;
}

/// Sanitises a desc for the capabilities listing at registration time. A desc holding a forbidden character, or over
/// 200 bytes, is warned about and returned as an empty string (registration itself still succeeds and only desc is
/// invalidated. This protects the wire framing for the sake of the JSON buffer's safety; it does not interpret desc's meaning).
const MAX_DESC_LEN = 200;
const MAX_ARG_NAME_LEN = 32;
const MAX_ARG_KIND_LEN = 32;
const MAX_ARG_VALUE_LEN = 64;
const MAX_ARG_PATTERN_LEN = 100;
fn sanitizeDesc(kind: []const u8, name: []const u8, desc: []const u8) []const u8 {
    if (desc.len == 0) return desc;
    if (desc.len > MAX_DESC_LEN or containsUnsafeJsonChar(desc)) {
        std.debug.print("[harness] {s} desc for '{s}' was disabled (a forbidden character, or over 200 bytes)\n", .{ kind, name });
        return "";
    }
    return desc;
}

/// Sanitises a probe's args signature at registration (the same rule as action_registry's; the duplicate definition is deliberate).
/// On a violation it warns and drops args as a whole to null (registration itself still succeeds).
fn sanitizeArgs(kind: []const u8, name: []const u8, args: ?[]const ArgSpec) ?[]const ArgSpec {
    const specs = args orelse return null;
    for (specs) |s| {
        // NaN and Inf cannot be emitted as a JSON number (they would break the always-valid-JSON contract), so they are rejected at registration
        if ((s.min != null and !std.math.isFinite(s.min.?)) or
            (s.max != null and !std.math.isFinite(s.max.?)))
        {
            std.debug.print("[harness] {s} args for {s} was disabled (min or max is not finite)\n", .{ kind, name });
            return null;
        }
        if (s.name.len > MAX_ARG_NAME_LEN or containsUnsafeJsonChar(s.name) or
            s.kind.len > MAX_ARG_KIND_LEN or containsUnsafeJsonChar(s.kind) or
            s.pattern.len > MAX_ARG_PATTERN_LEN or containsUnsafeJsonChar(s.pattern) or
            s.desc.len > MAX_DESC_LEN or containsUnsafeJsonChar(s.desc))
        {
            std.debug.print("[harness] {s} args for '{s}' was disabled (a forbidden character, or over the length limit)\n", .{ kind, name });
            return null;
        }
        for (s.values) |v| {
            if (v.len > MAX_ARG_VALUE_LEN or containsUnsafeJsonChar(v)) {
                std.debug.print("[harness] {s} args for '{s}' was disabled (a forbidden character, or over the length limit)\n", .{ kind, name });
                return null;
            }
        }
    }
    return specs;
}

/// Looks a registered custom probe up by name (an external control plane such as copilot uses it too, which is why it is pub).
pub fn findProbe(name: []const u8) ?*Probe {
    for (probes[0..probe_count]) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

// ============================================================================
// custom actions (moved out into action_registry.zig)
// ============================================================================

/// Action, NetworkPolicy, registerAction and findAction have moved to `action_registry`.
/// They are re-exported here for the existing callers (copilot, and the harness tests).
pub const Action = action_registry.Action;
pub const NetworkPolicy = action_registry.NetworkPolicy;
pub const registerAction = action_registry.registerAction;
pub const findAction = action_registry.findAction;
pub const setActionErrorDetail = action_registry.setActionErrorDetail;

/// The pure interpretation of a `KNGN_HARNESS_LISTEN` value (no IO; for unit testing).
/// - null = the variable is unset (do not listen)
/// - empty or "0" = ephemeral (port=0, ok)
/// - a positive integer = a fixed port
/// - anything else = invalid (which disables the transport)
const ListenPortParse = struct {
    requested: bool,
    port: u16 = 0,
    valid: bool = true,
};

fn parseListenPortValue(raw: ?[]const u8) ListenPortParse {
    const s = raw orelse return .{ .requested = false };
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "0")) {
        return .{ .requested = true, .port = 0, .valid = true };
    }
    const port = std.fmt.parseInt(u16, trimmed, 10) catch {
        return .{ .requested = true, .port = 0, .valid = false };
    };
    if (port == 0) return .{ .requested = true, .port = 0, .valid = true };
    return .{ .requested = true, .port = port, .valid = true };
}

/// The mutual exclusion of SCRIPT, LISTEN and MANUAL_CLOCK, and the clock default (a pure function; for unit testing).
const TransportDecision = struct {
    enable: bool,
    clock: ClockMode,
    listen_port: u16 = 0,
    reason_disabled: ?[]const u8 = null,
};

fn decideTransport(script: bool, listen: ListenPortParse, manual_clock: bool) TransportDecision {
    if (!script and !listen.requested) {
        if (manual_clock) {
            return .{ .enable = false, .clock = .manual, .reason_disabled = "MANUAL_CLOCK requires LISTEN" };
        }
        return .{ .enable = false, .clock = .manual };
    }
    if (script and listen.requested) {
        return .{ .enable = false, .clock = .manual, .reason_disabled = "SCRIPT and LISTEN mutually exclusive" };
    }
    if (listen.requested and !listen.valid) {
        return .{ .enable = false, .clock = .manual, .reason_disabled = "invalid LISTEN port" };
    }
    if (script) {
        // MANUAL_CLOCK is ignored alongside SCRIPT (which is always manual)
        return .{ .enable = true, .clock = .manual };
    }
    // listen
    const clock: ClockMode = if (manual_clock) .manual else .free_run;
    return .{ .enable = true, .clock = clock, .listen_port = listen.port };
}

/// Called exactly once at the very start of platform.init(). It only reads the environment and causes no IO side effect (it neither reads the script nor listens)
/// (it is split into two stages with `startTransport()` so that the transport decision is settled before
/// whether `backend.init()` is needed).
/// headless (`KNGN_HEADLESS`) is settled by platform and passed in through `setHeadlessActive` (this function does not read it).
pub fn parseConfig() void {
    if (config_parsed) return;
    config_parsed = true;

    pending_script_path = getEnv("KNGN_HARNESS_SCRIPT");
    pending_listen_raw = getEnv("KNGN_HARNESS_LISTEN");
    pending_manual_clock = if (getEnv("KNGN_HARNESS_MANUAL_CLOCK")) |v| std.mem.eql(u8, v, "1") else false;
    if (getEnv("KNGN_HARNESS_OUT")) |d| out_dir = d;

    capture_synthetic_requested = getEnv("KNGN_HARNESS_CAPTURE_SYNTHETIC") != null;
    skip_frame_copy = if (getEnv("KNGN_HARNESS_SKIP_FRAME_COPY")) |v| std.mem.eql(u8, v, "1") else false;
}

/// The compatibility setter platform calls once it has settled `KNGN_HEADLESS=1`.
/// audio, midi, capture and the rest consult it through `isHeadlessActive()`. The wasm stub is a no-op.
pub fn setHeadlessActive(active: bool) void {
    headless_active = active;
}

/// The null runtime test (platform sets it through `setHeadlessActive`; the source of truth in the environment is `KNGN_HEADLESS`).
/// Used to decide whether the facade makes a Window a null backend, and to keep audio and midi off the native path.
pub fn isHeadlessActive() bool {
    return headless_active;
}

/// Whether the synthetic capture source (a mic or a camera) is enabled.
/// `true` only when the `KNGN_HARNESS_CAPTURE_SYNTHETIC` variable is set and harness is enabled (replay or live).
/// By default (the variable unset) it is always `false` (zero regression).
///
/// **A caution, and an important limitation**: `core/camera.zig` and `core/audio.zig` are not wired to this, so even
/// when this function returns `true`, `camera.open()` and `audio.openCapture()` still return
/// `error.Unsupported` (they take a placeholder branch). The synthetic capture here is
/// `core/capture_synthetic.zig` plus the `capture` command and probe built into harness, and it is
/// **self-contained within this module**.
/// Wiring it into the facade is not a one-line substitution: the public `VideoDevice` type on `camera.zig`'s side
/// is a concrete alias, so the facade needs a broader change than swapping one implementation in. That is why
/// this module owns its own synthetic devices instead.
///
/// The condition for enabling it follows the same rule as the existing audio output: harness's environment read
/// (`parseConfig()`) runs only through `platform.init()`, so in a capture-only application that never calls
/// `platform.init()` this function always returns `false` (the same known limitation as an audio-only application
/// such as `examples/15_audio_tone` being unable to interpret `KNGN_HEADLESS`).
pub fn isCaptureSyntheticActive() bool {
    return capture_synthetic_requested and isEnabled();
}

/// Called exactly once by platform.init() (after `native_backend.init()`, on a non-null runtime).
/// The real IO of reading the script and of a live listen is confined here (on the split from `parseConfig()`, see above).
pub fn startTransport() void {
    if (initialized) return;
    initialized = true;

    const script_path = pending_script_path;
    const listen = parseListenPortValue(pending_listen_raw);
    const decision = decideTransport(script_path != null, listen, pending_manual_clock);
    if (!decision.enable) {
        if (decision.reason_disabled) |why| {
            std.debug.print("[harness] {s}. Disabling harness.\n", .{why});
        }
        return;
    }

    threaded = std.Io.Threaded.init(gpa, .{});
    io_val = threaded.io();
    clock_mode = decision.clock;

    if (script_path) |path| {
        script_bytes = std.Io.Dir.cwd().readFileAlloc(io_val, path, gpa, .unlimited) catch |err| {
            std.debug.print("[harness] failed to read the script {s}: {s}\n", .{ path, @errorName(err) });
            return; // left disabled
        };
        cmd_buf = script_bytes;
        mode = .replay;
        clock_mode = .manual;
        action_registry.setEnabled(true);
        std.debug.print("[harness] replay enabled: script={s} out={s}\n", .{ path, out_dir });
        return;
    }

    // listen (TCP)
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(decision.listen_port) };
    server = addr.listen(io_val, .{ .reuse_address = true }) catch |err| {
        std.debug.print("[harness] listen failed: {s}\n", .{@errorName(err)});
        return; // left disabled
    };
    record_path = getEnv("KNGN_HARNESS_RECORD");
    mode = .live;
    action_registry.setEnabled(true);
    const chosen = server.socket.address.getPort();
    const clock_label: []const u8 = if (clock_mode == .manual) "manual" else "free-run";
    std.debug.print("[harness] listen enabled ({s}): 127.0.0.1:{d} out={s}\n", .{ clock_label, chosen, out_dir });
    writePortFile(chosen);
}

const CmpOp = enum { eq, ne, gt, lt };
const Cmp = struct { op: CmpOp, key: []const u8, value: []const u8 };
const ExpectExpr = struct {
    probe: []const u8,
    form: union(enum) {
        cmp: Cmp,
        contains: []const u8,
    },
};

/// Continuing to wait for free-run or an await (holding one connection and resuming at a frame boundary).
const PendingWait = union(enum) {
    none,
    frame_barrier: struct { target_frame: u64 },
    predicate: struct {
        expr: ExpectExpr,
        expr_text: []const u8,
        start_frame: u64,
        timeout_frames: usize,
    },
};
var pending_wait: PendingWait = .none;

/// The synchronisation point of frame progress. True when one frame's worth of progress is allowed.
/// False on quit, on EOF (replay), on the window closing (native_continue=false), or on a failed accept (live manual).
/// Under free-run it is always true (the application runs itself and does not stop even with no agent present) — only quit and a native close give false.
pub fn pollGate(native_continue: bool) bool {
    if (mode == .live and clock_mode == .free_run) {
        return pollGateFreeRun(native_continue);
    }
    return pollGateWithPump(native_continue, null);
}

pub fn pollGateWithPump(native_continue: bool, pump: ?NativePump) bool {
    // Even on an early return (native_continue=false from a window close, or having already quit), let the
    // recorded expect failures reach the exit code (one of the three replay exit paths; a no-op for live and a normal run).
    if (quit_requested or !native_continue) {
        replayExitIfFailed();
        return false;
    }
    // the await predicate: when it does not hold, drive one frame and re-evaluate (manual and replay)
    if (resolvePendingWaitManual()) |gate| return gate;

    if (steps_remaining > 0) {
        steps_remaining -= 1;
        return true;
    }
    while (true) {
        if (cursor >= cmd_buf.len) {
            switch (mode) {
                .replay, .disabled => {
                    replayExitIfFailed(); // EOF (a replay exit path)
                    return false;
                },
                .live => {
                    finishLiveRequest();
                    if (quit_requested) return false;
                    if (!acceptLiveRequest(pump)) return false; // a failed accept means the end
                    continue;
                },
            }
        }
        const raw = nextLine() orelse continue;
        // Strip leading whitespace only. Trailing spaces are kept, because `inject commit` and friends preserve them.
        // Drop only a trailing CR (keeping record and replay symmetrical: the whitespace around a commit's text is not lost).
        var line = std.mem.trimStart(u8, raw, " \t");
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0 or line[0] == '#') continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const cmd = it.next() orelse continue;
        if (std.mem.eql(u8, cmd, "step")) {
            const n = parseUsize(it.next()) orelse 1;
            if (n == 0) continue;
            steps_remaining = n - 1;
            return true;
        } else if (std.mem.eql(u8, cmd, "quit")) {
            quit_requested = true;
            if (mode == .live) finishLiveRequest();
            replayExitIfFailed(); // quit (a replay exit path; for live this is a no-op after finishLiveRequest)
            return false;
        } else if (std.mem.eql(u8, cmd, "inject")) {
            handleInject(&it);
        } else if (std.mem.eql(u8, cmd, "snapshot")) {
            handleSnapshot(&it);
        } else if (std.mem.eql(u8, cmd, "digest")) {
            handleDigest(&it);
        } else if (std.mem.eql(u8, cmd, "action")) {
            handleAction(&it);
        } else if (std.mem.eql(u8, cmd, "capture")) {
            handleCapture(&it);
        } else if (std.mem.eql(u8, cmd, "expect")) {
            handleExpect(&it, false);
        } else if (std.mem.eql(u8, cmd, "assert")) {
            handleExpect(&it, true);
        } else if (std.mem.eql(u8, cmd, "await")) {
            if (handleAwait(&it)) return true; // the predicate is pending → drive one frame
        } else {
            warnLine("unknown command");
        }
    }
}

/// The free-run gate: a non-blocking drain. When empty it does one listener poll(0) only, and never calls NativePump.
pub fn pollGateFreeRun(native_continue: bool) bool {
    if (quit_requested or !native_continue) {
        if (live_req_open) finishLiveRequest();
        if (freerun_reading) abortFreeRunRead();
        return false;
    }

    // resolving a pending wait (a frame barrier or an await)
    switch (pending_wait) {
        .none => {},
        .frame_barrier => |b| {
            if (frame_index >= b.target_frame) {
                pending_wait = .none;
                // on to the next command
            } else {
                return true; // wait for the application to run itself
            }
        },
        .predicate => {
            switch (evalPendingPredicate()) {
                .pass => {
                    reportAwait(true, pendingPredicateExprText(), null);
                    pending_wait = .none;
                },
                .fail => {
                    reportAwait(false, pendingPredicateExprText(), pendingPredicateActual());
                    pending_wait = .none;
                },
                .pending => return true,
            }
        },
    }

    // Advance the active request's commands (returning once step or await makes it pending)
    if (live_req_open) {
        if (!runFreeRunCommands()) return false; // quit
        if (pending_wait != .none) return true;
        if (cursor >= cmd_buf.len) {
            finishLiveRequest();
        } else {
            return true; // It does not normally reach here (either runFreeRunCommands exhausts it, or it is pending)
        }
    }

    drainFreeRunTransport();
    // If the drain completed a request, handle it in the same frame
    if (live_req_open) {
        if (!runFreeRunCommands()) return false;
        if (pending_wait != .none) return true;
        if (cursor >= cmd_buf.len) finishLiveRequest();
    }
    return true;
}

/// Running commands under free-run. false = quit. With pending_wait set it returns true (and the caller carries the frame on).
fn runFreeRunCommands() bool {
    while (cursor < cmd_buf.len) {
        const raw = nextLine() orelse continue;
        var line = std.mem.trimStart(u8, raw, " \t");
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0 or line[0] == '#') continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const cmd = it.next() orelse continue;
        if (std.mem.eql(u8, cmd, "step")) {
            const n = parseUsize(it.next()) orelse 1;
            if (n == 0) continue;
            pending_wait = .{ .frame_barrier = .{ .target_frame = frame_index + n } };
            return true;
        } else if (std.mem.eql(u8, cmd, "quit")) {
            quit_requested = true;
            finishLiveRequest();
            return false;
        } else if (std.mem.eql(u8, cmd, "inject")) {
            handleInject(&it);
        } else if (std.mem.eql(u8, cmd, "snapshot")) {
            handleSnapshot(&it);
        } else if (std.mem.eql(u8, cmd, "digest")) {
            handleDigest(&it);
        } else if (std.mem.eql(u8, cmd, "action")) {
            handleAction(&it);
        } else if (std.mem.eql(u8, cmd, "capture")) {
            handleCapture(&it);
        } else if (std.mem.eql(u8, cmd, "expect")) {
            handleExpect(&it, false);
        } else if (std.mem.eql(u8, cmd, "assert")) {
            handleExpect(&it, true);
        } else if (std.mem.eql(u8, cmd, "await")) {
            if (handleAwait(&it)) return true;
        } else {
            warnLine("unknown command");
        }
    }
    return true;
}

/// The free-run non-blocking drain. When empty it polls the listener exactly once with poll(0).
fn drainFreeRunTransport() void {
    if (freerun_reading) {
        tryReadFreeRunRequest();
        return;
    }
    if (live_req_open) return;

    switch (pollFdReady(server.socket.handle)) {
        .ready => {
            const stream = server.accept(io_val) catch |err| {
                std.debug.print("[harness] accept failed: {s}\n", .{@errorName(err)});
                return;
            };
            live_stream = stream;
            freerun_reading = true;
            freerun_acc.clearRetainingCapacity();
            resp_buf.clearRetainingCapacity();
            tryReadFreeRunRequest();
        },
        .not_ready, .err => {},
    }
}

const PollReady = enum { ready, not_ready, err };

fn pollFdReady(fd: net.Socket.Handle) PollReady {
    switch (comptime builtin.os.tag) {
        .windows => {
            // Windows: the non-blocking contract is a different API. The free-run unit test assumes POSIX and is skipped.
            // Attempting an accept could block, so an empty drain treats it as not_ready.
            test_poll_zero_count += 1;
            return .not_ready;
        },
        else => {
            test_poll_zero_count += 1;
            var pfds = [_]posix.pollfd{.{
                .fd = fd,
                .events = posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP,
                .revents = 0,
            }};
            const n = posix.poll(&pfds, 0) catch return .err;
            if (n == 0) return .not_ready;
            const revents = pfds[0].revents;
            if (revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) return .err;
            if (revents & (posix.POLL.IN | posix.POLL.HUP) != 0) return .ready;
            return .not_ready;
        },
    }
}

fn tryReadFreeRunRequest() void {
    const fd = live_stream.socket.handle;
    switch (pollFdReady(fd)) {
        .not_ready => return,
        .err => {
            abortFreeRunRead();
            return;
        },
        .ready => {},
    }
    var rbuf: [4096]u8 = undefined;
    var bufs = [_][]u8{rbuf[0..]};
    const n = io_val.vtable.netRead(io_val.userdata, fd, bufs[0..]) catch {
        abortFreeRunRead();
        return;
    };
    if (n == 0) {
        // the peer's half-close → the request is complete
        const bytes = freerun_acc.toOwnedSlice(gpa) catch {
            abortFreeRunRead();
            return;
        };
        freerun_reading = false;
        req_bytes = bytes;
        cmd_buf = bytes;
        cursor = 0;
        line_no = 0;
        live_req_open = true;
        live_stream_owned = true;
        recordRequest(bytes);
        return;
    }
    const limit: usize = 1 << 20;
    if (freerun_acc.items.len + n > limit) {
        appendResp("error: request too large\n");
        // return the response and close
        freerun_reading = false;
        live_req_open = true;
        live_stream_owned = true;
        req_bytes = &.{};
        cmd_buf = "";
        cursor = 0;
        finishLiveRequest();
        return;
    }
    freerun_acc.appendSlice(gpa, rbuf[0..n]) catch {
        abortFreeRunRead();
        return;
    };
}

fn abortFreeRunRead() void {
    if (freerun_reading) {
        live_stream.close(io_val);
        freerun_reading = false;
    }
    freerun_acc.clearRetainingCapacity();
}

/// Resolving a pending await on the manual path. `null` = carry on, `Some(bool)` = return at once.
fn resolvePendingWaitManual() ?bool {
    switch (pending_wait) {
        .none => return null,
        .frame_barrier => {
            // manual does not use frame_barrier (it uses steps_remaining)
            pending_wait = .none;
            return null;
        },
        .predicate => {
            switch (evalPendingPredicate()) {
                .pass => {
                    reportAwait(true, pendingPredicateExprText(), null);
                    pending_wait = .none;
                    return null; // on to the command loop
                },
                .fail => {
                    reportAwait(false, pendingPredicateExprText(), pendingPredicateActual());
                    pending_wait = .none;
                    return null;
                },
                .pending => return true, // drive one frame
            }
        },
    }
}

const PredicateEval = enum { pass, fail, pending };

fn evalPendingPredicate() PredicateEval {
    const p = switch (pending_wait) {
        .predicate => |x| x,
        else => return .fail,
    };
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    switch (digestPayload(p.expr.probe, &buf)) {
        .unavailable => {
            // unavailable does not count as holding
            if (p.timeout_frames == 0 or frame_index >= p.start_frame + p.timeout_frames) {
                pending_pred_actual_buf_set("unavailable");
                return .fail;
            }
            return .pending;
        },
        .ok => |payload| {
            if (evalExpect(payload, p.expr)) return .pass;
            if (p.timeout_frames == 0 or frame_index >= p.start_frame + p.timeout_frames) {
                pending_pred_actual_buf_set(payload);
                return .fail;
            }
            return .pending;
        },
    }
}

// For showing actual when a predicate fails (the digest payload is on the stack, so a short reason is kept)
var pending_pred_actual_storage: [DIGEST_BUF_LEN]u8 = undefined;
var pending_pred_actual_len: usize = 0;

fn pending_pred_actual_buf_set(s: []const u8) void {
    const n = @min(s.len, pending_pred_actual_storage.len);
    @memcpy(pending_pred_actual_storage[0..n], s[0..n]);
    pending_pred_actual_len = n;
}

fn pendingPredicateExprText() []const u8 {
    return switch (pending_wait) {
        .predicate => |p| p.expr_text,
        else => "",
    };
}

fn pendingPredicateActual() ?[]const u8 {
    if (pending_pred_actual_len == 0) return null;
    return pending_pred_actual_storage[0..pending_pred_actual_len];
}

/// Returns one of this frame's injected events, or null once they are exhausted (resetting for the next frame).
/// When a registered probe's `input_blocker` reports a modal label, increments `modal_blocked_injections`
/// and emits a rate-limited warning (same label while it stays non-null warns once; a null reset then
/// a later non-null label warns again). The event is still returned unchanged.
pub fn nextInjectedEvent() ?Event {
    if (inject_read < inject_count) {
        const ev = inject_buf[inject_read];
        inject_read += 1;
        noteModalBlockedInjection(ev);
        return ev;
    }
    inject_read = 0;
    inject_count = 0;
    return null;
}

fn noteModalBlockedInjection(ev: Event) void {
    var label: ?[]const u8 = null;
    for (probes[0..probe_count]) |p| {
        if (p.input_blocker) |blocker| {
            if (blocker(p.ctx, ev)) |l| {
                label = l;
                break;
            }
        }
    }
    if (label) |l| {
        modal_blocked_injections += 1;
        const already = if (last_blocker_warn_label) |prev| std.mem.eql(u8, prev, l) else false;
        if (!already) {
            last_blocker_warn_label = l;
            warnModalBlocked(l);
        }
    } else {
        last_blocker_warn_label = null;
    }
}

fn warnModalBlocked(label: []const u8) void {
    std.debug.print("[harness] warning: an injected event was consumed by \"{s}\"\n", .{label});
    if (mode == .live) {
        appendResp("warning: an injected event was consumed by \"");
        appendResp(label);
        appendResp("\"\n");
    }
}

/// Returns one synthetic MIDI event for this frame, resetting for the next frame once the FIFO is exhausted.
pub fn nextMidiEvent() ?MidiEvent {
    if (midi_read < midi_count) {
        const ev = midi_buf[midi_read];
        midi_read += 1;
        return ev;
    }
    midi_read = 0;
    midi_count = 0;
    return null;
}

/// The latest-wins snapshot of the composition harness injected. It returns the newest revision even after a commit or a cancel.
pub fn getCompositionSnapshot(buf: []u8) CompositionSnapshot {
    const n = @min(composition_len, buf.len);
    @memcpy(buf[0..n], composition_text[0..n]);
    return .{
        .text = buf[0..n],
        .revision = composition_revision,
        .cursor = @intCast(@min(composition_cursor, n)),
    };
}

/// Filtering native (OS) events. For replay determinism only quit passes, and every other OS input is dropped.
pub fn filterNativeEvent(ev: Event) ?Event {
    return switch (ev) {
        .quit => ev,
        else => null,
    };
}

/// The fifth choke point of the facade's `Window.getGamepadState`. An index out of range gives null.
/// It only reads state that is updated at event time (no allocation, no lock; this is not a hot path. See ADR-009).
pub fn getGamepadState(index: u8) ?GamepadState {
    if (index >= gamepad_states.len) return null;
    return gamepad_states[index];
}

/// Records the current pixels and dimensions when lockFramebuffer succeeds (present takes the owned copy).
pub fn onLock(pixels: []const u32, w: u32, h: u32) void {
    lock_pixels = pixels;
    lock_w = w;
    lock_h = h;
    lock_valid = true;
}

/// Called when lockFramebuffer returns null. It invalidates the view so present does not re-copy stale pixels.
pub fn onLockMiss() void {
    lock_valid = false;
}

/// Called just before present. It keeps the newest EventStats for the `stats` probe.
pub fn onStats(s: EventStats) void {
    last_stats = s;
}

/// Called at present: takes the owned copy of the frame to settle it, and advances frame_index.
/// With `KNGN_HARNESS_SKIP_FRAME_COPY=1` (the measurement-only mode) the copy is skipped and only frame_index advances
/// (the snapshot and digest of fb, canvas and friends hold meaningless values, but `digest stats`'s frame, used for measuring fps, still increments).
pub fn onPresent() void {
    if (skip_frame_copy) {
        lock_valid = false;
        frame_index += 1;
        return;
    }
    const n = @as(usize, lock_w) * @as(usize, lock_h);
    if (lock_valid and n > 0 and lock_pixels.len >= n) {
        if (frame_pixels.len < n) {
            if (frame_pixels.len > 0) gpa.free(frame_pixels);
            frame_pixels = gpa.alloc(u32, n) catch {
                warnLine("failed to allocate the frame buffer");
                lock_valid = false;
                frame_index += 1;
                return;
            };
        }
        @memcpy(frame_pixels[0..n], lock_pixels[0..n]);
        frame_w = lock_w;
        frame_h = lock_h;
        have_frame = true;
    }
    lock_valid = false; // the next frame needs its own onLock
    frame_index += 1;
}

/// The virtual clock (driven by frames). It makes the replay of an application that uses getTime deterministic.
pub fn now() f64 {
    return @as(f64, @floatFromInt(frame_index)) / VIRTUAL_FPS;
}

/// Called **on the RT thread** from the render trampoline of the audio facade (`src/audio.zig`).
/// **No allocation, lock, IO or panic.** samples are interleaved (frames*channels).
/// latest-wins: even when full it advances head and overwrites (so samples can be dropped; a probe looks at the most recent window).
pub fn onAudioSamples(samples: []const f32, frames: u32, channels: u32, sample_rate: u32) void {
    if (mode == .disabled) return;
    _ = frames;
    audio_channels.store(channels, .monotonic);
    audio_rate.store(sample_rate, .monotonic);
    var head = audio_head.load(.monotonic);
    for (samples) |s| {
        // A slot can be peeked at by the consumer concurrently. Torn reads are tolerated under latest-wins, but to
        // avoid data race UB in Zig terms it is read and written `.unordered` (on an aligned f32 that is effectively a plain load or store, with no fence).
        @atomicStore(f32, &audio_buf[head & AUDIO_MASK], s, .unordered);
        head +%= 1;
    }
    audio_head.store(head, .release);
}

// ============================================================================
// live transport
// ============================================================================

fn livePollTimeoutMs() i32 {
    return test_live_poll_timeout_ms orelse live_poll_timeout_default_ms;
}

fn runNativePump(pump: ?NativePump) bool {
    const p = pump orelse return true;
    return p.poll();
}

/// Polls until the fd is readable, running the native pump on each timeout.
/// `false` = the pump reported a window close, or the fd errored.
fn waitFdReadable(fd: net.Socket.Handle, pump: ?NativePump) bool {
    switch (comptime builtin.os.tag) {
        .windows => unreachable,
        else => return waitFdReadablePosix(fd, pump),
    }
}

fn waitFdReadablePosix(fd: net.Socket.Handle, pump: ?NativePump) bool {
    const events: i16 = posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP;
    while (true) {
        var pfds = [_]posix.pollfd{.{
            .fd = fd,
            .events = events,
            .revents = 0,
        }};
        const n = posix.poll(&pfds, livePollTimeoutMs()) catch return false;
        if (n == 0) {
            if (!runNativePump(pump)) return false;
            continue;
        }
        const revents = pfds[0].revents;
        if (revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) return false;
        // POLLHUP is used to read the data left after a half-close (a read is attempted whether it comes with IN or alone).
        if (revents & (posix.POLL.IN | posix.POLL.HUP) != 0) return true;
    }
}

fn waitListenerReadable(pump: ?NativePump) bool {
    return waitFdReadable(server.socket.handle, pump);
}

const ReadLiveRequestError = error{
    ReadFailed,
    RequestTooLarge,
};

fn readLiveRequestBody(stream: net.Stream, pump: ?NativePump) ReadLiveRequestError![]u8 {
    var acc: std.ArrayList(u8) = .empty;
    errdefer acc.deinit(gpa);

    var rbuf: [4096]u8 = undefined;
    const fd = stream.socket.handle;
    const limit: usize = 1 << 20;

    while (true) {
        if (!waitFdReadable(fd, pump)) return error.ReadFailed;
        var bufs = [_][]u8{rbuf[0..]};
        const n = io_val.vtable.netRead(io_val.userdata, fd, bufs[0..]) catch return error.ReadFailed;
        if (n == 0) break;
        if (acc.items.len + n > limit) return error.RequestTooLarge;
        acc.appendSlice(gpa, rbuf[0..n]) catch return error.ReadFailed;
    }
    return acc.toOwnedSlice(gpa) catch error.ReadFailed;
}

/// Accepts one connection and reads the whole request (up to the client's half-close) into cmd_buf.
/// A false return = the accept is impossible (the server has finished) → so the application exits.
fn acceptLiveRequest(pump: ?NativePump) bool {
    const use_poll = pump != null and builtin.os.tag != .windows;

    while (true) {
        const stream = if (use_poll) blk: {
            if (!waitListenerReadable(pump)) return false;
            break :blk server.accept(io_val) catch |err| {
                std.debug.print("[harness] accept failed: {s}\n", .{@errorName(err)});
                return false;
            };
        } else server.accept(io_val) catch |err| {
            std.debug.print("[harness] accept failed: {s}\n", .{@errorName(err)});
            return false;
        };
        live_stream = stream;
        live_req_open = true;
        live_stream_owned = true;
        resp_buf.clearRetainingCapacity();

        const bytes = if (use_poll) blk: {
            break :blk readLiveRequestBody(stream, pump) catch |err| {
                switch (err) {
                    ReadLiveRequestError.RequestTooLarge => appendResp("error: request too large\n"),
                    else => appendResp("error: request read failed\n"),
                }
                std.debug.print("[harness] failed to read the request: {s}\n", .{@errorName(err)});
                finishLiveRequest();
                continue;
            };
        } else blk: {
            var rbuf: [4096]u8 = undefined;
            var reader = stream.reader(io_val, &rbuf);
            break :blk reader.interface.allocRemaining(gpa, std.Io.Limit.limited(1 << 20)) catch |err| {
                std.debug.print("[harness] failed to read the request: {s}\n", .{@errorName(err)});
                appendResp("error: request read failed\n");
                finishLiveRequest();
                continue;
            };
        };
        req_bytes = bytes;
        cmd_buf = bytes;
        cursor = 0;
        line_no = 0;
        recordRequest(bytes);
        return true;
    }
}

/// Finishes the current request: flushes the response, closes the stream and tidies the buffers.
fn finishLiveRequest() void {
    if (!live_req_open) return;
    pending_wait = .none;
    if (live_stream_owned) {
        var wbuf: [4096]u8 = undefined;
        var writer = live_stream.writer(io_val, &wbuf);
        writer.interface.writeAll(resp_buf.items) catch {};
        writer.interface.flush() catch {};
        live_stream.close(io_val);
        live_stream_owned = false;
    }
    live_req_open = false;
    if (req_bytes.len > 0) {
        gpa.free(req_bytes);
        req_bytes = &.{};
    }
    cmd_buf = "";
    cursor = 0;
}

fn appendResp(s: []const u8) void {
    resp_buf.appendSlice(gpa, s) catch {};
}

/// Appends a raw request received live to the record file (a comment boundary, the raw text, then a trailing newline).
/// The whole of record_buf is rewritten every time, for crash resilience (this is for debugging and the volume of commands is small).
fn recordRequest(bytes: []const u8) void {
    const path = record_path orelse return;
    record_buf.appendSlice(gpa, "# --- live request ---\n") catch return;
    record_buf.appendSlice(gpa, bytes) catch return;
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') record_buf.appendSlice(gpa, "\n") catch return;
    std.Io.Dir.cwd().writeFile(io_val, .{ .sub_path = path, .data = record_buf.items }) catch |err| {
        std.debug.print("[harness] failed to write the record {s}: {s}\n", .{ path, @errorName(err) });
    };
}

fn writePortFile(port: u16) void {
    const path = getEnv("KNGN_HARNESS_PORT_FILE") orelse (std.fmt.bufPrint(&port_file_buf, "{s}/harness.port", .{out_dir}) catch return);
    var pbuf: [16]u8 = undefined;
    const txt = std.fmt.bufPrint(&pbuf, "{d}\n", .{port}) catch return;
    std.Io.Dir.cwd().writeFile(io_val, .{ .sub_path = path, .data = txt }) catch |err| {
        std.debug.print("[harness] failed to write the port file {s}: {s}\n", .{ path, @errorName(err) });
    };
}

// ============================================================================
// the response sink (the framing branches on the mode)
// ============================================================================

/// Emits a digest result: `<probe> <payload>` (live) or `[harness] digest <probe> <payload>` (replay).
fn emitDigest(probe: []const u8, payload: []const u8) void {
    if (mode == .live) {
        appendResp(probe);
        appendResp(" ");
        appendResp(payload);
        appendResp("\n");
    } else {
        std.debug.print("[harness] digest {s} {s}\n", .{ probe, payload });
    }
}

/// Emits a snapshot result: `<path>` (live) or `[harness] snapshot <probe> -> <path> (<info>)` (replay).
fn emitSnapshot(probe: []const u8, path: []const u8, info: []const u8) void {
    if (mode == .live) {
        appendResp(path);
        appendResp("\n");
    } else {
        std.debug.print("[harness] snapshot {s} -> {s} ({s})\n", .{ probe, path, info });
    }
}

// ============================================================================
// handling a command
// ============================================================================

fn handleInject(it: *Tok) void {
    const kind = it.next() orelse {
        warnLine("inject: the kind is missing");
        return;
    };
    if (std.mem.eql(u8, kind, "key_down") or std.mem.eql(u8, kind, "key_up")) {
        const name = it.next() orelse {
            warnLine("inject key: KEY is missing");
            return;
        };
        const kc = parseKey(name) orelse {
            warnLine("inject key: unknown key");
            return;
        };
        const extras = parseKeyExtras(it) orelse return warnLine("inject: unknown modifier or repeat");
        const ke = KeyEvent{ .key = kc, .is_repeat = extras.repeat, .modifiers = extras.modifiers };
        queue(if (std.mem.eql(u8, kind, "key_down")) Event{ .key_down = ke } else Event{ .key_up = ke });
    } else if (std.mem.eql(u8, kind, "mouse_move")) {
        const x = parseI32(it.next()) orelse return warnLine("inject mouse_move: invalid coordinate");
        const y = parseI32(it.next()) orelse return warnLine("inject mouse_move: invalid coordinate");
        // Parse the modifiers before updating the coordinate state (so failing fast on an unknown modifier does not dirty mouse_x or mouse_y)
        const mods = parseModifiers(it) orelse return warnLine("inject: unknown modifier");
        mouse_x = x;
        mouse_y = y;
        queue(Event{ .mouse_move = .{ .x = x, .y = y, .button = .none, .buttons = mouse_buttons, .modifiers = mods } });
    } else if (std.mem.eql(u8, kind, "mouse_down") or std.mem.eql(u8, kind, "mouse_up")) {
        const btn = parseButton(it.next()) orelse return warnLine("inject mouse: unknown button");
        const down = std.mem.eql(u8, kind, "mouse_down");
        // Parse the modifiers before setButton (so failing fast on an unknown modifier does not dirty mouse_buttons)
        const mods = parseModifiers(it) orelse return warnLine("inject: unknown modifier");
        setButton(&mouse_buttons, btn, down);
        const ev = MouseEvent{ .x = mouse_x, .y = mouse_y, .button = btn, .buttons = mouse_buttons, .modifiers = mods };
        queue(if (down) Event{ .mouse_down = ev } else Event{ .mouse_up = ev });
    } else if (std.mem.eql(u8, kind, "scroll")) {
        const dx = parseF32(it.next()) orelse return warnLine("inject scroll: invalid amount");
        const dy = parseF32(it.next()) orelse return warnLine("inject scroll: invalid amount");
        const mods = parseModifiers(it) orelse return warnLine("inject: unknown modifier");
        queue(Event{ .mouse_scroll = .{ .x = mouse_x, .y = mouse_y, .dx = dx, .dy = dy, .is_precise = false, .buttons = mouse_buttons, .modifiers = mods } });
    } else if (std.mem.eql(u8, kind, "char")) {
        // Inject a settled text character. The argument is either a single character literal, or a hex codepoint starting with 0x or U+.
        // A single digit (5, say) counts as the character '5' (=53), which avoids ambiguity with a control character (a decimal codepoint is unsupported).
        const arg = it.next() orelse return warnLine("inject char: the argument is missing");
        const cp = parseCodepoint(arg) orelse return warnLine("inject char: invalid codepoint or character");
        const mods = parseModifiers(it) orelse return warnLine("inject: unknown modifier");
        queue(Event{ .char_input = .{ .codepoint = cp, .modifiers = mods } });
    } else if (std.mem.eql(u8, kind, "midi")) {
        const event_kind = it.next() orelse return warnLine("inject midi: the event kind is missing");
        if (std.mem.eql(u8, event_kind, "note_on") or std.mem.eql(u8, event_kind, "note_off")) {
            const note = parseMidiValue(it.next()) orelse return warnLine("inject midi note: note must be 0..127");
            const velocity = parseMidiValue(it.next()) orelse return warnLine("inject midi note: velocity must be 0..127");
            if (it.next() != null) return warnLine("inject midi note: too many arguments");
            const event: MidiEvent = if (std.mem.eql(u8, event_kind, "note_on") and velocity != 0)
                .{ .note_on = .{ .device_id = 0, .note = note, .velocity = velocity } }
            else
                .{ .note_off = .{ .device_id = 0, .note = note, .velocity = velocity } };
            if (!queueMidi(event)) return;
            applyMidiState(event);
        } else if (std.mem.eql(u8, event_kind, "cc")) {
            const controller = parseMidiValue(it.next()) orelse return warnLine("inject midi cc: controller must be 0..127");
            const value = parseMidiValue(it.next()) orelse return warnLine("inject midi cc: value must be 0..127");
            if (it.next() != null) return warnLine("inject midi cc: too many arguments");
            const event: MidiEvent = .{ .cc = .{ .device_id = 0, .controller = controller, .value = value } };
            if (!queueMidi(event)) return;
            applyMidiState(event);
        } else {
            return warnLine("inject midi: unknown event");
        }
    } else if (std.mem.eql(u8, kind, "commit")) {
        // Inject a sequence of settled IME text. The rest of the line is taken as UTF-8, decomposed into codepoints, and
        // queued as consecutive char_input events (the same consumption path as a real IME's insertText). The modifiers are empty.
        //
        // Whitespace: `it.rest()` skips every leading delimiter, so the raw text right after the token is used instead.
        // The index after next() sits just past "commit" (on the separating space). Exactly one separator is dropped,
        // and everything after it is injected as it stands, whitespace included (keeping record and replay symmetrical).
        var text = it.buffer[it.index..];
        if (text.len > 0 and (text[0] == ' ' or text[0] == '\t')) text = text[1..];
        if (text.len > 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1];
        if (text.len == 0) {
            if (!composition_active) return warnLine("inject commit: a no-op before an update");
            clearComposition(.commit);
            return;
        }

        const has_composition = composition_active;

        // Pass 1 validates the whole lot, and pass 2 queues it (so a failure part way through injects nothing partially).
        if (!std.unicode.utf8ValidateSlice(text)) return warnLine("inject commit: invalid UTF-8");
        {
            var i: usize = 0;
            while (i < text.len) {
                const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
                    return warnLine("inject commit: invalid UTF-8");
                };
                const cp = std.unicode.utf8Decode(text[i..][0..seq_len]) catch {
                    return warnLine("inject commit: invalid UTF-8");
                };
                // The same filter as parseCodepoint's (printable scalars only; control characters, surrogates and out-of-range values are rejected).
                if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) or cp < 0x20 or cp == 0x7f) {
                    return warnLine("inject commit: non-printable codepoint");
                }
                i += seq_len;
            }
        }
        // Emit a commit event, and empty the snapshot, only while a composition is in progress. A bare commit
        // leaves the composition state alone and queues char_input only, per the backwards-compatibility contract.
        if (has_composition) clearComposition(.commit);

        // Pass 2 queues only what was validated
        {
            var i: usize = 0;
            while (i < text.len) {
                const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch unreachable;
                const cp = std.unicode.utf8Decode(text[i..][0..seq_len]) catch unreachable;
                queue(Event{ .char_input = .{ .codepoint = cp, .modifiers = .{} } });
                i += seq_len;
            }
        }
    } else if (std.mem.eql(u8, kind, "composition")) {
        const phase = it.next() orelse return warnLine("inject composition: the phase is missing");
        if (std.mem.eql(u8, phase, "update")) {
            const cursor_arg = parseUsize(it.next()) orelse return warnLine("inject composition update: invalid cursor");
            var text = it.buffer[it.index..];
            if (text.len > 0 and (text[0] == ' ' or text[0] == '\t')) text = text[1..];
            if (text.len > 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1];
            if (!std.unicode.utf8ValidateSlice(text)) return warnLine("inject composition update: invalid UTF-8");
            const n = utf8SafePrefixLen(text, COMPOSITION_CAP);
            @memcpy(composition_text[0..n], text[0..n]);
            composition_len = n;
            composition_cursor = clampUtf8Offset(composition_text[0..n], cursor_arg);
            const phase_value: CompositionPhase = if (composition_active) .update else .start;
            composition_active = true;
            enqueueComposition(phase_value);
        } else if (std.mem.eql(u8, phase, "cancel")) {
            if (!composition_active) return warnLine("inject composition cancel: a no-op before an update");
            clearComposition(.cancel);
        } else {
            warnLine("inject composition: phase must be update or cancel");
        }
    } else if (std.mem.eql(u8, kind, "file_drop")) {
        // `inject file_drop <path>`. Exactly one separating space after the file_drop token is dropped, and
        // the whole remainder is taken as one path (whitespace inside it and at the end is kept, and quotes get no special treatment).
        // `;` and a newline are the existing command separators, so they cannot appear in a path.
        var path = it.buffer[it.index..];
        if (path.len > 0 and (path[0] == ' ' or path[0] == '\t')) path = path[1..];
        if (path.len > 0 and path[path.len - 1] == '\r') path = path[0 .. path.len - 1];
        it.index = it.buffer.len; // mark the remainder as consumed
        const drop = types.makeFileDropEventFromPath(path) orelse {
            return warnLine("inject file_drop: invalid path (empty, a NUL, bad UTF-8, or over the limit)");
        };
        queue(Event{ .file_drop = drop });
    } else if (std.mem.eql(u8, kind, "gamepad_connect")) {
        const idx = parseGamepadIndex(it.next()) orelse return warnLine("inject gamepad_connect: invalid index");
        const raw_name = std.mem.trim(u8, it.rest(), " \t"); // use the whole remainder as the name (of a kind with char)
        var info = GamepadInfo{ .index = idx };
        const n = @min(raw_name.len, GAMEPAD_NAME_MAX);
        @memcpy(info.name_buf[0..n], raw_name[0..n]);
        info.name_len = @intCast(n);
        gamepad_states[idx] = .{}; // the default state (every button off, sticks at 0, triggers at 0)
        queue(Event{ .gamepad_connected = info });
    } else if (std.mem.eql(u8, kind, "gamepad_disconnect")) {
        const idx = parseGamepadIndex(it.next()) orelse return warnLine("inject gamepad_disconnect: invalid index");
        gamepad_states[idx] = null;
        queue(Event{ .gamepad_disconnected = .{ .index = idx } });
    } else if (std.mem.eql(u8, kind, "gamepad_button")) {
        const idx = parseGamepadIndex(it.next()) orelse return warnLine("inject gamepad_button: invalid index");
        const btn = parseGamepadButton(it.next()) orelse return warnLine("inject gamepad_button: unknown button");
        const v = parseUsize(it.next()) orelse return warnLine("inject gamepad_button: invalid value (0|1)");
        if (v != 0 and v != 1) return warnLine("inject gamepad_button: the value must be 0 or 1");
        if (gamepad_states[idx] == null) return warnLine("inject gamepad_button: the pad is not connected");
        gamepad_states[idx].?.buttons.set(btn, v == 1);
    } else if (std.mem.eql(u8, kind, "gamepad_axis")) {
        const idx = parseGamepadIndex(it.next()) orelse return warnLine("inject gamepad_axis: invalid index");
        const axis = it.next() orelse return warnLine("inject gamepad_axis: axis is missing");
        const v = parseF32(it.next()) orelse return warnLine("inject gamepad_axis: invalid value");
        if (gamepad_states[idx] == null) return warnLine("inject gamepad_axis: the pad is not connected");
        if (!setGamepadAxis(&gamepad_states[idx].?, axis, v)) return warnLine("inject gamepad_axis: unknown axis, or out of range");
    } else {
        warnLine("inject: unknown kind");
    }
}

const KeyExtras = struct { modifiers: ModifierFlags, repeat: bool };

/// Injecting a key is the one case that accepts a `repeat` token as well as the modifiers.
fn parseKeyExtras(it: *Tok) ?KeyExtras {
    var result: KeyExtras = .{ .modifiers = .{}, .repeat = false };
    while (it.next()) |tok| {
        var buf: [16]u8 = undefined;
        if (tok.len == 0 or tok.len > buf.len) return null;
        for (tok, 0..) |c, i| buf[i] = std.ascii.toLower(c);
        const name = buf[0..tok.len];
        if (std.mem.eql(u8, name, "repeat")) {
            result.repeat = true;
        } else if (std.mem.eql(u8, name, "shift")) {
            result.modifiers.shift = true;
        } else if (std.mem.eql(u8, name, "ctrl")) {
            result.modifiers.ctrl = true;
        } else if (std.mem.eql(u8, name, "alt")) {
            result.modifiers.alt = true;
        } else if (std.mem.eql(u8, name, "cmd")) {
            result.modifiers.cmd = true;
        } else return null;
    }
    return result;
}

fn enqueueComposition(phase: CompositionPhase) void {
    composition_revision +%= 1;
    queue(Event{ .composition_changed = .{
        .revision = composition_revision,
        .phase = phase,
        .cursor = @intCast(composition_cursor),
    } });
}

fn clearComposition(phase: CompositionPhase) void {
    composition_len = 0;
    composition_cursor = 0;
    composition_active = false;
    enqueueComposition(phase);
}

fn utf8SafePrefixLen(text: []const u8, cap: usize) usize {
    var n = @min(text.len, cap);
    while (n > 0 and n < text.len and (text[n] & 0xC0) == 0x80) : (n -= 1) {}
    return n;
}

fn clampUtf8Offset(text: []const u8, offset: usize) usize {
    var n = @min(offset, text.len);
    while (n > 0 and n < text.len and (text[n] & 0xC0) == 0x80) : (n -= 1) {}
    return n;
}

/// Parses a gamepad index token (only 0..MAX_GAMEPADS-1 is valid).
fn parseGamepadIndex(tok: ?[]const u8) ?u8 {
    const v = parseUsize(tok) orelse return null;
    if (v >= MAX_GAMEPADS) return null;
    return @intCast(v);
}

/// Parses a MIDI 7-bit value. It does not clamp, but rejects anything out of range.
fn parseMidiValue(tok: ?[]const u8) ?u8 {
    const v = parseUsize(tok) orelse return null;
    if (v > 127) return null;
    return @intCast(v);
}

/// Parses a gamepad button name token (case-insensitive, matching GamepadButton's declared names).
fn parseGamepadButton(tok: ?[]const u8) ?GamepadButton {
    const name = tok orelse return null;
    var buf: [24]u8 = undefined;
    if (name.len == 0 or name.len > buf.len) return null;
    for (name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return std.meta.stringToEnum(GamepadButton, buf[0..name.len]);
}

/// Reflects `inject gamepad_axis`'s axis name and value into the state.
/// The range is rejected rather than clamped, to keep the raw-value contract: a stick (left_x, left_y, right_x, right_y) is
/// [-1,1], and a trigger (left_trigger, right_trigger) is [0,1]. An unknown axis name, or a value out of range, gives false (leaving the state unchanged).
/// NaN and inf would pass straight through, both comparisons in `v < lo or v > hi` being false, so they are
/// rejected explicitly up front (which closes that hole in the fail-fast behaviour).
fn setGamepadAxis(state: *GamepadState, axis: []const u8, v: f32) bool {
    if (!std.math.isFinite(v)) return false;
    var buf: [16]u8 = undefined;
    if (axis.len == 0 or axis.len > buf.len) return false;
    for (axis, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const name = buf[0..axis.len];
    if (std.mem.eql(u8, name, "left_x")) {
        if (v < -1 or v > 1) return false;
        state.left_stick.x = v;
    } else if (std.mem.eql(u8, name, "left_y")) {
        if (v < -1 or v > 1) return false;
        state.left_stick.y = v;
    } else if (std.mem.eql(u8, name, "right_x")) {
        if (v < -1 or v > 1) return false;
        state.right_stick.x = v;
    } else if (std.mem.eql(u8, name, "right_y")) {
        if (v < -1 or v > 1) return false;
        state.right_stick.y = v;
    } else if (std.mem.eql(u8, name, "left_trigger")) {
        if (v < 0 or v > 1) return false;
        state.left_trigger = v;
    } else if (std.mem.eql(u8, name, "right_trigger")) {
        if (v < 0 or v > 1) return false;
        state.right_trigger = v;
    } else return false;
    return true;
}

/// Turns `inject char`'s argument into a UTF-32 codepoint. 0x.. and U+.. are hex, and anything else is taken as a single
/// UTF-8 character whose codepoint is returned (two or more characters, or invalid UTF-8, gives null). Decimal is unsupported (so a single digit counts as a character).
fn parseCodepoint(tok: []const u8) ?u32 {
    if (tok.len == 0) return null;
    const hex: ?[]const u8 = if (std.mem.startsWith(u8, tok, "0x") or std.mem.startsWith(u8, tok, "0X"))
        tok[2..]
    else if (std.mem.startsWith(u8, tok, "U+") or std.mem.startsWith(u8, tok, "u+"))
        tok[2..]
    else
        null;
    const cp: u32 = if (hex) |h| blk: {
        if (h.len == 0) return null;
        break :blk std.fmt.parseInt(u32, h, 16) catch return null;
    } else blk: {
        // A single UTF-8 character (accepted only when the whole token is exactly one codepoint).
        const seq_len = std.unicode.utf8ByteSequenceLength(tok[0]) catch return null;
        if (seq_len != tok.len) return null;
        break :blk std.unicode.utf8Decode(tok) catch return null;
    };
    // Limited to the "printable Unicode scalar values" a native backend actually produces:
    // a surrogate (0xD800-0xDFFF), out of range (>0x10FFFF), or a control character (<0x20 or 0x7f) is rejected, since a replay cannot produce one.
    if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return null;
    if (cp < 0x20 or cp == 0x7f) return null;
    return cp;
}

fn handleSnapshot(it: *Tok) void {
    const probe = it.next() orelse return warnLine("snapshot: the probe name is missing");
    const path_arg = it.next();
    var path_buf: [1024]u8 = undefined;

    if (std.mem.eql(u8, probe, "fb")) {
        if (!have_frame) return warnLine("snapshot fb: before a present (the frame is unsettled) -> skip");
        const path = path_arg orelse (std.fmt.bufPrint(&path_buf, "{s}/frame_{d}.png", .{ out_dir, frame_index }) catch return warnLine("snapshot: failed to build the path"));
        const n = @as(usize, frame_w) * @as(usize, frame_h);
        png.savePNG(io_val, path, frame_pixels[0..n], frame_w, frame_h, gpa) catch |err| {
            std.debug.print("[harness] snapshot fb failed {s}: {s}\n", .{ path, @errorName(err) });
            return;
        };
        var info_buf: [32]u8 = undefined;
        const info = std.fmt.bufPrint(&info_buf, "{d}x{d}", .{ frame_w, frame_h }) catch "?";
        emitSnapshot("fb", path, info);
    } else if (std.mem.eql(u8, probe, "audio")) {
        const channels = audio_channels.load(.monotonic);
        const rate = audio_rate.load(.monotonic);
        const n = peekRecentAudio(&audio_scratch);
        if (n == 0 or channels == 0) return warnLine("snapshot audio: no samples -> skip");
        const path = path_arg orelse (std.fmt.bufPrint(&path_buf, "{s}/audio_{d}.wav", .{ out_dir, frame_index }) catch return warnLine("snapshot: failed to build the path"));
        writeWav(io_val, path, audio_scratch[0..n], channels, rate, gpa) catch |err| {
            std.debug.print("[harness] snapshot audio failed {s}: {s}\n", .{ path, @errorName(err) });
            return;
        };
        var info_buf: [32]u8 = undefined;
        const info = std.fmt.bufPrint(&info_buf, "{d} samples", .{n}) catch "?";
        emitSnapshot("audio", path, info);
    } else if (std.mem.eql(u8, probe, "stats")) {
        const path = path_arg orelse (std.fmt.bufPrint(&path_buf, "{s}/stats_{d}.json", .{ out_dir, frame_index }) catch return warnLine("snapshot: failed to build the path"));
        var json_buf: [512]u8 = undefined;
        const json = formatStatsPayload(&json_buf);
        std.Io.Dir.cwd().writeFile(io_val, .{ .sub_path = path, .data = json }) catch |err| {
            std.debug.print("[harness] snapshot stats failed {s}: {s}\n", .{ path, @errorName(err) });
            return;
        };
        emitSnapshot("stats", path, "json");
    } else if (std.mem.eql(u8, probe, "capabilities")) {
        const path = path_arg orelse (std.fmt.bufPrint(&path_buf, "{s}/capabilities_{d}.json", .{ out_dir, frame_index }) catch return warnLine("snapshot: failed to build the path"));
        const json = formatCapabilitiesPayload(&capabilities_buf);
        std.Io.Dir.cwd().writeFile(io_val, .{ .sub_path = path, .data = json }) catch |err| {
            std.debug.print("[harness] snapshot capabilities failed {s}: {s}\n", .{ path, @errorName(err) });
            return;
        };
        emitSnapshot("capabilities", path, "json");
    } else if (std.mem.eql(u8, probe, "capture")) {
        if (synth_video) |*dev| {
            const frame = dev.renderFrame(frame_index);
            const path = path_arg orelse (std.fmt.bufPrint(&path_buf, "{s}/capture_{d}.png", .{ out_dir, frame_index }) catch return warnLine("snapshot: failed to build the path"));
            png.savePNG(io_val, path, frame.pixels, frame.width, frame.height, gpa) catch |err| {
                std.debug.print("[harness] snapshot capture failed {s}: {s}\n", .{ path, @errorName(err) });
                return;
            };
            var info_buf: [32]u8 = undefined;
            const info = std.fmt.bufPrint(&info_buf, "{d}x{d}", .{ frame.width, frame.height }) catch "?";
            emitSnapshot("capture", path, info);
        } else {
            warnLine("snapshot capture: video is not open -> skip");
        }
    } else if (std.mem.eql(u8, probe, "gamepad")) {
        const path = path_arg orelse (std.fmt.bufPrint(&path_buf, "{s}/gamepad_{d}.txt", .{ out_dir, frame_index }) catch return warnLine("snapshot: failed to build the path"));
        var buf: [DIGEST_BUF_LEN]u8 = undefined;
        const payload = formatGamepadPayload(&buf);
        std.Io.Dir.cwd().writeFile(io_val, .{ .sub_path = path, .data = payload }) catch |err| {
            std.debug.print("[harness] snapshot gamepad failed {s}: {s}\n", .{ path, @errorName(err) });
            return;
        };
        emitSnapshot("gamepad", path, "txt");
    } else if (findProbe(probe)) |p| {
        snapshotCustom(p, path_arg, &path_buf);
    } else {
        warnLine("snapshot: unknown probe");
    }
}

/// Routes a custom probe's snapshot (without interpreting it): writes the callback's raw bytes to a file and frees them with the same allocator.
fn snapshotCustom(p: *const Probe, path_arg: ?[]const u8, path_buf: []u8) void {
    const snap = p.snapshot orelse return warnLine("snapshot: this probe does not support snapshot");
    const bytes = snap(p.ctx, gpa) catch |err| {
        std.debug.print("[harness] snapshot {s} failed: {s}\n", .{ p.name, @errorName(err) });
        return;
    };
    defer gpa.free(bytes);
    const path = path_arg orelse (std.fmt.bufPrint(path_buf, "{s}/{s}_{d}.{s}", .{ out_dir, p.name, frame_index, p.ext }) catch return warnLine("snapshot: failed to build the path"));
    std.Io.Dir.cwd().writeFile(io_val, .{ .sub_path = path, .data = bytes }) catch |err| {
        std.debug.print("[harness] snapshot {s} failed {s}: {s}\n", .{ p.name, path, @errorName(err) });
        return;
    };
    var info_buf: [32]u8 = undefined;
    const info = std.fmt.bufPrint(&info_buf, "{d} bytes", .{bytes.len}) catch "?";
    emitSnapshot(p.name, path, info);
}

// ============================================================================
// the capabilities probe (introspective listing of the registered probes and actions)
//
// Hot path declaration: at event time or connection time only (handling a digest or snapshot command scans the
// fixed-length registry once: MAX_PROBES custom probes + MAX_ACTIONS actions + the built-ins below). Never per frame or per sample.
// It touches no state shared with the RT thread (only a fixed-length registry read on the main thread).
//
// The invariant of not interpreting the contents: it transcribes name, ext and desc, and **whether** snapshot and digest
// exist (whether the callback is non-null), straight from the registration. It never calls a callback itself.
// ============================================================================

/// Where the capabilities JSON is assembled (a reusable scratch for a single-process debug facility;
/// the same shape as audio_scratch and port_file_buf, and free of contention, running sequentially on the one main thread).
var capabilities_buf: [16 * 1024]u8 = undefined;

/// The minimum buf length `formatCapabilitiesPayload` requires in order to meet its "always returns valid JSON" contract.
/// Passing a buf below this is a caller bug, so an assert brings it down (capabilities_buf, and the explicit
/// buffers in the tests, are always at least this large).
const MIN_CAPABILITIES_BUF_LEN = 128;
/// The bytes reserved for the closing sequence alone. It leaves room over the largest closing string
/// expected, `],"actions":[],"truncated":true}` (34B).
const CAPABILITIES_RESERVED_TAIL = 64;

const CapabilityBuiltin = struct {
    name: []const u8,
    ext: []const u8,
    snapshot: bool = true,
    digest: bool = true,
    desc: []const u8,
};
const CAPABILITY_BUILTINS = [_]CapabilityBuiltin{
    .{ .name = "fb", .ext = "png", .desc = "framebuffer PNG/digest" },
    .{ .name = "audio", .ext = "wav", .desc = "audio tap PCM16 WAV / rms, peak, f0, silent / band, centroid, onsets, lufs" },
    .{ .name = "stats", .ext = "json", .desc = "EventStats + virtual fps JSON" },
    .{ .name = "capabilities", .ext = "json", .desc = "introspective listing of the registered probes and actions" },
    .{ .name = "capture", .ext = "png", .desc = "synthetic mic/camera capture: video PNG snapshot + video/audio state digest" },
    .{ .name = "gamepad", .ext = "txt", .desc = "gamepad state: connected mask + per-pad buttons/sticks/triggers" },
    .{ .name = "midi", .ext = "txt", .snapshot = false, .digest = true, .desc = "MIDI state: device 0 pressed-note bitset + controller values" },
};

/// Writes `s` into `buf[len.*..limit)` only if it fits. If it does not it writes nothing and returns false
/// (so no half-written byte sequence is left behind). **`len` and `limit` are always absolute
/// offsets relative to the whole of `buf`** (so do not slice `buf` itself at the call site: `len` can advance across a
/// phase as far as a larger `limit`, the tail region, and if the coordinate system disagrees with a truncated slice of
/// `buf` then `limit - len` swings negative and panics on overflow. This shape of bug happened
/// during implementation, so it is stated here as a contract).
fn appendRaw(buf: []u8, limit: usize, len: *usize, s: []const u8) bool {
    if (limit < len.* or limit - len.* < s.len) return false;
    @memcpy(buf[len.*..][0..s.len], s);
    len.* += s.len;
    return true;
}

/// Appends one ArgSpec as a JSON object (emitting non-default values only).
/// Without interpreting the contents: it transcribes the registered strings as they are.
fn appendArgSpecEntry(buf: []u8, limit: usize, len: *usize, s: ArgSpec) bool {
    if (containsUnsafeJsonChar(s.name) or containsUnsafeJsonChar(s.kind) or
        containsUnsafeJsonChar(s.pattern) or containsUnsafeJsonChar(s.desc)) return false;
    for (s.values) |v| {
        if (containsUnsafeJsonChar(v)) return false;
    }
    var scratch: [512]u8 = undefined;
    const head = std.fmt.bufPrint(&scratch, "{{\"name\":\"{s}\",\"kind\":\"{s}\"", .{ s.name, s.kind }) catch return false;
    if (!appendRaw(buf, limit, len, head)) return false;
    if (s.min) |m| {
        const part = std.fmt.bufPrint(&scratch, ",\"min\":{d}", .{m}) catch return false;
        if (!appendRaw(buf, limit, len, part)) return false;
    }
    if (s.max) |m| {
        const part = std.fmt.bufPrint(&scratch, ",\"max\":{d}", .{m}) catch return false;
        if (!appendRaw(buf, limit, len, part)) return false;
    }
    if (s.values.len > 0) {
        if (!appendRaw(buf, limit, len, ",\"values\":[")) return false;
        for (s.values, 0..) |v, i| {
            if (i > 0 and !appendRaw(buf, limit, len, ",")) return false;
            const part = std.fmt.bufPrint(&scratch, "\"{s}\"", .{v}) catch return false;
            if (!appendRaw(buf, limit, len, part)) return false;
        }
        if (!appendRaw(buf, limit, len, "]")) return false;
    }
    if (s.pattern.len > 0) {
        const part = std.fmt.bufPrint(&scratch, ",\"pattern\":\"{s}\"", .{s.pattern}) catch return false;
        if (!appendRaw(buf, limit, len, part)) return false;
    }
    if (s.optional and !appendRaw(buf, limit, len, ",\"optional\":true")) return false;
    if (s.variadic and !appendRaw(buf, limit, len, ",\"variadic\":true")) return false;
    if (s.desc.len > 0) {
        const part = std.fmt.bufPrint(&scratch, ",\"desc\":\"{s}\"", .{s.desc}) catch return false;
        if (!appendRaw(buf, limit, len, part)) return false;
    }
    return appendRaw(buf, limit, len, "}");
}

/// Appends `,"args":[...]` only when `args != null` (the caller skips null, keeping it bit-identical to before).
fn appendArgsField(buf: []u8, limit: usize, len: *usize, args: []const ArgSpec) bool {
    if (!appendRaw(buf, limit, len, ",\"args\":[")) return false;
    for (args, 0..) |s, i| {
        if (i > 0 and !appendRaw(buf, limit, len, ",")) return false;
        if (!appendArgSpecEntry(buf, limit, len, s)) return false;
    }
    return appendRaw(buf, limit, len, "]");
}

/// Appends one probe entry into `buf[0..limit)` (through `len`). When name or ext holds a character that would
/// corrupt the JSON, or the entry does not fit, it writes nothing and returns false (and the caller raises the
/// truncated flag). Without interpreting the contents: it transcribes the values and never calls a callback.
/// Appends `"args":[...]` only when `args != null` (a field addition only).
fn appendProbeEntry(buf: []u8, limit: usize, len: *usize, name: []const u8, ext: []const u8, has_snapshot: bool, has_digest: bool, desc: []const u8, args: ?[]const ArgSpec) bool {
    if (containsUnsafeJsonChar(name) or containsUnsafeJsonChar(ext) or containsUnsafeJsonChar(desc)) return false;
    var scratch: [768]u8 = undefined;
    const head = std.fmt.bufPrint(&scratch, "{{\"name\":\"{s}\",\"ext\":\"{s}\",\"snapshot\":{},\"digest\":{},\"desc\":\"{s}\"", .{ name, ext, has_snapshot, has_digest, desc }) catch return false;
    if (!appendRaw(buf, limit, len, head)) return false;
    if (args) |as| {
        if (!appendArgsField(buf, limit, len, as)) return false;
    }
    return appendRaw(buf, limit, len, "}");
}

/// The action version of `appendProbeEntry` (with no `ext`, `snapshot` or `digest` field).
/// Appends `"args":[...]` only when `args != null` (null stays bit-identical to before).
fn appendActionEntry(buf: []u8, limit: usize, len: *usize, name: []const u8, desc: []const u8, args: ?[]const ArgSpec) bool {
    if (containsUnsafeJsonChar(name) or containsUnsafeJsonChar(desc)) return false;
    var scratch: [768]u8 = undefined;
    const head = std.fmt.bufPrint(&scratch, "{{\"name\":\"{s}\",\"desc\":\"{s}\"", .{ name, desc }) catch return false;
    if (!appendRaw(buf, limit, len, head)) return false;
    if (args) |as| {
        if (!appendArgsField(buf, limit, len, as)) return false;
    }
    return appendRaw(buf, limit, len, "}");
}

/// Lists the registered probes (the seven built in, then the custom ones in registration order) and actions (in registration order) as one line of JSON.
/// The contract is that it **always returns valid JSON** (assuming `buf.len >= MIN_CAPABILITIES_BUF_LEN`). When an entry is
/// left out because of the capacity, or because of an invalid character in name or ext, `"truncated":true` is appended at the end.
fn formatCapabilitiesPayload(buf: []u8) []const u8 {
    std.debug.assert(buf.len >= MIN_CAPABILITIES_BUF_LEN);
    // content_limit: the range entries and separators may be written in. buf.len: the range the closing ("]" and so on) may be written in
    // (with the trailing CAPABILITIES_RESERVED_TAIL as the margin). `len` is always an absolute offset relative to the whole
    // of buf, so using a different limit per phase does not make the coordinate system inconsistent (see appendRaw).
    const content_limit = buf.len - CAPABILITIES_RESERVED_TAIL;
    var len: usize = 0;
    var truncated = false;

    _ = appendRaw(buf, content_limit, &len, "{\"probes\":[");
    var first = true;
    probes_blk: {
        for (CAPABILITY_BUILTINS) |b| {
            const saved_len = len; // If appending an entry fails, roll back the separator "," along with it (which prevents a trailing comma)
            if (!first and !appendRaw(buf, content_limit, &len, ",")) {
                len = saved_len;
                truncated = true;
                break :probes_blk;
            }
            if (!appendProbeEntry(buf, content_limit, &len, b.name, b.ext, b.snapshot, b.digest, b.desc, null)) {
                len = saved_len;
                truncated = true;
                break :probes_blk;
            }
            first = false;
        }
        for (probes[0..probe_count]) |p| {
            const saved_len = len;
            if (!first and !appendRaw(buf, content_limit, &len, ",")) {
                len = saved_len;
                truncated = true;
                break :probes_blk;
            }
            if (!appendProbeEntry(buf, content_limit, &len, p.name, p.ext, p.snapshot != null, p.digest != null, p.desc, p.args)) {
                len = saved_len;
                truncated = true;
                break :probes_blk;
            }
            first = false;
        }
    }
    _ = appendRaw(buf, buf.len, &len, "]"); // it always fits, thanks to the RESERVED_TAIL reservation

    // The start of the "actions" section may itself not fit within content_limit, so the return value is checked
    // (and if it does not fit, this falls to the same treatment as having truncated on the probes side. Carrying on
    // without checking would append only the later `]` while never writing `,"actions":[`, giving invalid JSON).
    if (!truncated and appendRaw(buf, content_limit, &len, ",\"actions\":[")) {
        first = true;
        actions_blk: {
            var i: usize = 0;
            while (i < action_registry.actionCount()) : (i += 1) {
                const a = action_registry.actionAt(i).?;
                const saved_len = len;
                if (!first and !appendRaw(buf, content_limit, &len, ",")) {
                    len = saved_len;
                    truncated = true;
                    break :actions_blk;
                }
                if (!appendActionEntry(buf, content_limit, &len, a.name, a.desc, a.args)) {
                    len = saved_len;
                    truncated = true;
                    break :actions_blk;
                }
                first = false;
            }
        }
        _ = appendRaw(buf, buf.len, &len, "]"); // it always fits, thanks to the RESERVED_TAIL reservation
    } else {
        truncated = true;
        _ = appendRaw(buf, buf.len, &len, ",\"actions\":[]"); // either it truncated on the probes side, or "actions":[ itself did not fit
    }

    if (truncated) _ = appendRaw(buf, buf.len, &len, ",\"truncated\":true");
    _ = appendRaw(buf, buf.len, &len, "}");
    return buf[0..len];
}

/// The pub wrapper around `formatCapabilitiesPayload` (used by copilot's `digest capabilities`).
pub fn capabilitiesPayload(buf: []u8) []const u8 {
    return formatCapabilitiesPayload(buf);
}

/// The result of fetching a one-line digest payload. `unavailable` holds the reason it could not be fetched (a static string),
/// which keeps it diagnosable both in the digest command's warning and in expect's and assert's `actual=` display.
const DigestResult = union(enum) {
    ok: []const u8,
    unavailable: []const u8,
};

/// Returns the one-line digest payload for a probe name (shared by the `digest` command and by `expect` and `assert`).
/// buf is where the payload is written. The caller passes `DIGEST_BUF_LEN` so that fb, stats, audio and a custom probe all fit
/// (`capabilities` does not use the `buf` it is given and uses its own `capabilities_buf` (16KB) instead, being separate from
/// the `DIGEST_BUF_LEN=1024` contract meant for custom probe and action callbacks).
/// The invariant of not interpreting the contents holds (the framework does not interpret the payload's meaning).
fn digestPayload(probe: []const u8, buf: []u8) DigestResult {
    if (std.mem.eql(u8, probe, "fb")) {
        if (!have_frame) return .{ .unavailable = "fb not presented" };
        return .{ .ok = formatFbPayload(buf) };
    } else if (std.mem.eql(u8, probe, "audio")) {
        return .{ .ok = formatAudioPayload(buf) };
    } else if (std.mem.eql(u8, probe, "stats")) {
        return .{ .ok = formatStatsPayload(buf) };
    } else if (std.mem.eql(u8, probe, "capabilities")) {
        return .{ .ok = formatCapabilitiesPayload(&capabilities_buf) };
    } else if (std.mem.eql(u8, probe, "capture")) {
        return .{ .ok = formatCapturePayload(buf) };
    } else if (std.mem.eql(u8, probe, "gamepad")) {
        return .{ .ok = formatGamepadPayload(buf) };
    } else if (std.mem.eql(u8, probe, "midi")) {
        return .{ .ok = formatMidiPayload(buf) };
    } else if (findProbe(probe)) |p| {
        const dg = p.digest orelse return .{ .unavailable = "digest unsupported" };
        return .{ .ok = dg(p.ctx, buf) };
    } else {
        return .{ .unavailable = "unknown probe" };
    }
}

fn handleDigest(it: *Tok) void {
    const probe = it.next() orelse return warnLine("digest: the probe name is missing");
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    switch (digestPayload(probe, &buf)) {
        .ok => |payload| emitDigest(probe, payload),
        .unavailable => |reason| warnLine(reason),
    }
}

// ============================================================================
// action (the high-level operation symmetrical with a probe)
//
// The grammar (shared by replay and live): action <name> [args...]
//   args is the raw remainder of the line after <name> (already trimmed, never re-tokenised = the contents are not interpreted).
//   The framework only looks the name up and calls run() (the same invariant as a probe).
//
// A failure (a missing name, an unknown action, an error from run()) rides on the same `expect_failures`
// counter as expect and assert (recorded, then carrying on; there is no immediate abort as with assert). It rides for free on the
// three existing exit paths (EOF, quit, an early return — see replayExitIfFailed), so no new exit path is added.
// ============================================================================

/// The body of the `action` command. `routeLocalAction`, then emitting the result, and nothing else (it neither interprets nor re-tokenises args).
/// reportAction's wire formatting and its recording into expect_failures are unchanged.
fn handleAction(it: *Tok) void {
    const name = it.next() orelse "";
    if (name.len == 0) return reportAction(false, "?", "missing action name");
    const args = std.mem.trim(u8, it.rest(), " \t");
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const result = action_registry.routeLocalAction(name, args, &buf) catch |err| {
        if (err == error.UnknownAction) return reportAction(false, name, "unknown action");
        return reportAction(false, name, @errorName(err));
    };
    reportAction(true, name, result);
}

/// Cuts `msg` at the first CR or LF (which keeps the wire framing even if a callback wrongly returns several lines.
/// It is above all the defence that stops live's leading-`fail ` scan from misfiring on the following line. It is not an interpretation of the contents).
fn firstLine(msg: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, msg, '\n');
    const cr = std.mem.indexOfScalar(u8, msg, '\r');
    const cut = @min(nl orelse msg.len, cr orelse msg.len);
    return msg[0..cut];
}

/// The trailing suffix of a structured error (empty when none is set, keeping it bit-identical to before).
/// ` code=<c> next=<n>` (with a leading space). next is the whole remainder and may contain whitespace.
fn actionErrorDetailSuffix(buf: []u8) []const u8 {
    const d = action_registry.actionErrorDetail() orelse return "";
    return std.fmt.bufPrint(buf, " code={s} next={s}", .{ d.code, d.next }) catch "";
}

/// Emits an action's outcome and records a failure (replay=stderr / live=resp_buf).
/// - replay success: `[harness] action <name> ok <msg>` / failure: `[harness] action <name> FAILED <msg>`
/// - live success  : `<name> <msg>` (bare, in the same style as a digest) / failure: `fail <name> <msg>` (the prefix
///   that puts it on drive's leading-token scan)
/// - On a failure, when the application has called `setActionErrorDetail`, ` code=<c> next=<n>` is appended
///   (with none set it is bit-identical to the old format. The leading `fail ` never changes, so `kngn ctl`'s leading-token scan needs no change)
/// - Only on a failure, and only when `mode == .replay`, `expect_failures` is incremented (there is no immediate abort as with assert).
fn reportAction(pass: bool, name: []const u8, msg: []const u8) void {
    const line = firstLine(msg);
    var detail_buf: [action_registry.MAX_ERROR_CODE_LEN + action_registry.MAX_ERROR_NEXT_LEN + 16]u8 = undefined;
    const suffix = if (!pass) actionErrorDetailSuffix(&detail_buf) else "";
    if (mode == .live) {
        if (pass) {
            appendResp(name);
            appendResp(" ");
            appendResp(line);
        } else {
            appendResp("fail ");
            appendResp(name);
            appendResp(" ");
            appendResp(line);
            appendResp(suffix);
        }
        appendResp("\n");
    } else if (pass) {
        std.debug.print("[harness] action {s} ok {s}\n", .{ name, line });
    } else {
        std.debug.print("[harness] action {s} FAILED {s}{s}\n", .{ name, line, suffix });
    }

    if (!pass and mode == .replay) {
        expect_failures += 1;
    }
}

// ============================================================================
// the synthetic capture source (a fake mic and camera)
//
// The grammar (shared by replay and live):
//   capture video open <w> <h> [fps]   # open the synthetic camera (closing and reopening it if it is already open)
//   capture video close                # close the synthetic camera
//   capture audio open [sr] [ch] [hz]  # open the synthetic mic and start it at once (reopening it if it is already open)
//   capture audio close                # close the synthetic mic (stop, join, close)
//
// While `isCaptureSyntheticActive()` (true only with the `KNGN_HARNESS_CAPTURE_SYNTHETIC` variable set and harness enabled) is
// false, everything fails fast (a warnLine only, with no state change; the same thinking as the existing handling of an
// unknown `inject` token). There is no facade wiring into camera.zig or audio.zig (see `isCaptureSyntheticActive()`'s doc
// comment). The implementation is delegated to `core/capture_synthetic.zig`, and what happens here is only owning the
// harness state (`synth_video`, `synth_audio`), parsing the commands, and assembling the probe payload.
//
// Hot path declaration: at event time only (once per command handled; neither per frame nor per sample).
// ============================================================================

fn handleCapture(it: *Tok) void {
    if (!isCaptureSyntheticActive()) return warnLine("capture: unavailable, KNGN_HARNESS_CAPTURE_SYNTHETIC being unset or harness disabled");
    const domain = it.next() orelse return warnLine("capture: video|audio is missing");
    if (std.mem.eql(u8, domain, "video")) {
        handleCaptureVideo(it);
    } else if (std.mem.eql(u8, domain, "audio")) {
        handleCaptureAudio(it);
    } else {
        warnLine("capture: unknown kind (video|audio)");
    }
}

fn handleCaptureVideo(it: *Tok) void {
    const verb = it.next() orelse return warnLine("capture video: open|close is missing");
    if (std.mem.eql(u8, verb, "open")) {
        const w = parseUsize(it.next()) orelse return warnLine("capture video open: invalid width");
        const h = parseUsize(it.next()) orelse return warnLine("capture video open: invalid height");
        const fps = parseUsize(it.next()) orelse 30;
        if (synth_video) |*dev| dev.close();
        synth_video = capture_synthetic.openVideo(gpa, .{
            .width = std.math.cast(u32, w) orelse return warnLine("capture video open: width is too large"),
            .height = std.math.cast(u32, h) orelse return warnLine("capture video open: height is too large"),
            .frame_rate = std.math.cast(u32, fps) orelse return warnLine("capture video open: fps is too large"),
        }) catch |err| {
            synth_video = null;
            std.debug.print("[harness] capture video open failed: {s}\n", .{@errorName(err)});
            return;
        };
    } else if (std.mem.eql(u8, verb, "close")) {
        if (synth_video) |*dev| {
            dev.close();
            synth_video = null;
        } else {
            warnLine("capture video close: not open");
        }
    } else {
        warnLine("capture video: unknown operation (open|close)");
    }
}

fn noopCaptureAudioCallback(frame: capture_synthetic.AudioInFrame, userdata: ?*anyopaque) void {
    _ = frame;
    _ = userdata;
}

fn handleCaptureAudio(it: *Tok) void {
    const verb = it.next() orelse return warnLine("capture audio: open|close is missing");
    if (std.mem.eql(u8, verb, "open")) {
        const sr = parseUsize(it.next()) orelse 48000;
        const ch = parseUsize(it.next()) orelse 1;
        const hz = parseF32(it.next()) orelse 440.0;
        if (synth_audio) |dev| {
            dev.close();
            synth_audio = null;
        }
        var dev = capture_synthetic.openAudio(gpa, .{
            .sample_rate = std.math.cast(u32, sr) orelse return warnLine("capture audio open: sample_rate is too large"),
            .channels = std.math.cast(u32, ch) orelse return warnLine("capture audio open: channels is too large"),
            .frequency_hz = hz,
            .capture_callback = noopCaptureAudioCallback,
        }) catch |err| {
            std.debug.print("[harness] capture audio open failed: {s}\n", .{@errorName(err)});
            return;
        };
        dev.start() catch |err| {
            std.debug.print("[harness] capture audio start failed: {s}\n", .{@errorName(err)});
            dev.close();
            return;
        };
        synth_audio = dev;
    } else if (std.mem.eql(u8, verb, "close")) {
        if (synth_audio) |dev| {
            dev.close();
            synth_audio = null;
        } else {
            warnLine("capture audio close: not open");
        }
    } else {
        warnLine("capture audio: unknown operation (open|close)");
    }
}

/// The `capture` probe's digest payload (top-level key=value, so expect and assert can match on it).
/// When either video or audio is not open, the fields concerned return 0 (the keys always exist).
fn formatCapturePayload(buf: []u8) []u8 {
    const v_open: u8 = @intFromBool(synth_video != null);
    const v_w: u32 = if (synth_video) |d| d.width else 0;
    const v_h: u32 = if (synth_video) |d| d.height else 0;
    const a_open: u8 = @intFromBool(synth_audio != null);
    const a_frames: u64 = if (synth_audio) |d| d.framesGenerated() else 0;
    const a_peak: f32 = if (synth_audio) |d| d.lastPeak() else 0;
    return std.fmt.bufPrint(buf, "video_open={d} video_w={d} video_h={d} video_frame={d} audio_open={d} audio_frames={d} audio_peak={d:.4}", .{
        v_open, v_w, v_h, frame_index, a_open, a_frames, a_peak,
    }) catch buf[0..0];
}

// ============================================================================
// the gamepad probe (built in)
//
// Hot path declaration: only while handling a digest or snapshot command (at event time only, not per frame).
// ============================================================================

/// Normalises `v` to a positive `0.0` when it is numerically 0 (`-0.0` included). This prevents the `-0.0000` variation in
/// the float formatting and keeps `expect` and `digest` stable (see the "harness state model" section of ADR-009).
fn normalizeZero(v: f32) f32 {
    return if (v == 0) 0 else v;
}

/// `connected=<bitmask> p<idx>_buttons=<hex8> p<idx>_lx=.. p<idx>_ly=.. p<idx>_rx=.. p<idx>_ry=.. p<idx>_lt=.. p<idx>_rt=..`
/// (Only the connected pads are listed. To keep it top-level key=value, each pad gets a `p<idx>_` prefix. Floats are a fixed 4 digits with
/// negative zero normalised.)
fn formatGamepadPayload(buf: []u8) []u8 {
    var len: usize = 0;
    var mask: u32 = 0;
    for (gamepad_states, 0..) |st, i| {
        if (st != null) mask |= @as(u32, 1) << @intCast(i);
    }
    len += (std.fmt.bufPrint(buf[len..], "connected={d}", .{mask}) catch return buf[0..len]).len;
    for (gamepad_states, 0..) |maybe_st, i| {
        const st = maybe_st orelse continue;
        len += (std.fmt.bufPrint(buf[len..], " p{d}_buttons={X:0>8} p{d}_lx={d:.4} p{d}_ly={d:.4} p{d}_rx={d:.4} p{d}_ry={d:.4} p{d}_lt={d:.4} p{d}_rt={d:.4}", .{
            i, st.buttons.toC(),
            i, normalizeZero(st.left_stick.x),
            i, normalizeZero(st.left_stick.y),
            i, normalizeZero(st.right_stick.x),
            i, normalizeZero(st.right_stick.y),
            i, normalizeZero(st.left_trigger),
            i, normalizeZero(st.right_trigger),
        }) catch return buf[0..len]).len;
    }
    return buf[0..len];
}

// ============================================================================
// the MIDI probe (built in)
//
// Hot path declaration: only while handling a digest command (at event time only). It merely scans fixed-length state,
// and is on neither a per-frame nor a real-time path.
// ============================================================================

fn appendMidiHexByte(buf: []u8, len: *usize, value: u8) bool {
    if (buf.len -| len.* < 2) return false;
    const digits = "0123456789ABCDEF";
    buf[len.*] = digits[value >> 4];
    buf[len.* + 1] = digits[value & 0x0F];
    len.* += 2;
    return true;
}

fn formatMidiPayload(buf: []u8) []u8 {
    var note_count: usize = 0;
    for (0..128) |note| {
        if ((midi_pressed[note / 8] & (@as(u8, 1) << @intCast(note % 8))) != 0) note_count += 1;
    }
    var cc_count: usize = 0;
    for (midi_cc_set) |set| {
        if (set) cc_count += 1;
    }

    var len = (std.fmt.bufPrint(buf, "midi device=0 note_count={d} notes=", .{note_count}) catch return buf[0..0]).len;
    for (midi_pressed) |byte| if (!appendMidiHexByte(buf, &len, byte)) return buf[0..len];
    len += (std.fmt.bufPrint(buf[len..], " cc_count={d} cc=", .{cc_count}) catch return buf[0..len]).len;
    for (midi_cc_set, 0..) |set, i| {
        if (set) {
            if (!appendMidiHexByte(buf, &len, midi_cc_values[i])) return buf[0..len];
        } else {
            if (buf.len -| len < 2) return buf[0..len];
            buf[len] = '-';
            buf[len + 1] = '-';
            len += 2;
        }
    }
    return buf[0..len];
}

// ============================================================================
// expect and assert (the assertion layer)
//
// The grammar (shared by replay and live):
//   expect <probe> <key><op><value>     op ∈ {= != > <}
//   expect <probe> contains <substr>
//   assert ... (evaluated as expect is; under replay a failure exits 1 at once)
//   A leading `digest` token (`expect digest fb ...`) is an alias and is skipped.
//
// What is evaluated is the **top-level `key=value`** of the one-line digest payload (separated by whitespace). Nesting (`l0{..}`) and
// JSON (stats) are glued into one token and never leak out, so use `contains` for those. The invariant of not interpreting the contents holds.
// ============================================================================

/// The pure function parsing `expect`'s and `assert`'s argument tokens into an expression (it touches no module-level state, so it is unit testable).
/// A surplus token, a missing op, an empty key or value, a missing substr for contains, or a surplus substr, all give null (failing fast).
fn parseExpectExpr(it: *Tok) ?ExpectExpr {
    var probe = it.next() orelse return null;
    if (std.mem.eql(u8, probe, "digest")) {
        probe = it.next() orelse return null; // the `expect digest fb ...` alias
    }
    const t2 = it.next() orelse return null;
    if (std.mem.eql(u8, t2, "contains")) {
        const sub = it.next() orelse return null; // substr is required
        if (it.next() != null) return null; // a surplus token
        return .{ .probe = probe, .form = .{ .contains = sub } };
    }
    const cmp = parseCmpToken(t2) orelse return null;
    if (it.next() != null) return null; // a surplus token
    return .{ .probe = probe, .form = .{ .cmp = cmp } };
}

/// Splits the single token `key<op>value`. op is one of {= != > <}. The op starts at the first `!`, `=`, `<` or `>` from the front.
/// An empty key or value, no op symbol, or a `!` not followed by `=`, gives null (invalid syntax).
fn parseCmpToken(tok: []const u8) ?Cmp {
    var i: usize = 0;
    while (i < tok.len) : (i += 1) {
        const c = tok[i];
        if (c == '=' or c == '<' or c == '>' or c == '!') break;
    }
    if (i == 0 or i >= tok.len) return null; // an empty key, or no op symbol
    var op: CmpOp = undefined;
    var vstart: usize = undefined;
    switch (tok[i]) {
        '=' => {
            op = .eq;
            vstart = i + 1;
        },
        '>' => {
            op = .gt;
            vstart = i + 1;
        },
        '<' => {
            op = .lt;
            vstart = i + 1;
        },
        '!' => {
            if (i + 1 >= tok.len or tok[i + 1] != '=') return null; // a bare `!` is invalid
            op = .ne;
            vstart = i + 2;
        },
        else => unreachable,
    }
    const value = tok[vstart..];
    if (value.len == 0) return null; // an empty value
    return .{ .op = op, .key = tok[0..i], .value = value };
}

/// The pure function extracting a top-level `key=value`'s value from a digest payload (one line).
/// It tokenises on whitespace (` \t`) alone and returns everything after the `=` of the first token starting with `key ++ "="`.
/// Requiring `tok[key.len]=='='` prevents a prefix collision (`f` wrongly matching `frames=` or `f0=`).
/// Nesting (`l0{..}`) and JSON hold no whitespace and are glued into one token, so they are never picked up.
fn findKeyValue(payload: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, payload, " \t");
    while (it.next()) |tok| {
        if (tok.len > key.len and std.mem.startsWith(u8, tok, key) and tok[key.len] == '=') {
            return tok[key.len + 1 ..];
        }
    }
    return null;
}

/// The pure function comparing actual with expected under an op.
/// `>` and `<` require both sides to parse as f64 (failing if they cannot). `=` and `!=` compare numerically when both sides parse as f64, and as strings otherwise.
fn compareValues(actual: []const u8, op: CmpOp, expected: []const u8) bool {
    const af: ?f64 = std.fmt.parseFloat(f64, actual) catch null;
    const ef: ?f64 = std.fmt.parseFloat(f64, expected) catch null;
    return switch (op) {
        .gt => af != null and ef != null and af.? > ef.?,
        .lt => af != null and ef != null and af.? < ef.?,
        .eq => if (af != null and ef != null) af.? == ef.? else std.mem.eql(u8, actual, expected),
        .ne => if (af != null and ef != null) af.? != ef.? else !std.mem.eql(u8, actual, expected),
    };
}

/// The pure function evaluating an expression against a payload (one digest line). true=pass. A missing key is a fail.
fn evalExpect(payload: []const u8, expr: ExpectExpr) bool {
    switch (expr.form) {
        .contains => |sub| return std.mem.indexOf(u8, payload, sub) != null,
        .cmp => |c| {
            const actual = findKeyValue(payload, c.key) orelse return false; // a missing key = a fail
            return compareValues(actual, c.op, c.value);
        },
    }
}

/// The body of the `expect` and `assert` commands. It takes the probe's digest payload, evaluates the expression, and emits and records the outcome.
/// - replay: a failure is recorded into `expect_failures`. assert calls `replayExitIfFailed()` at once (a fail-fast abort).
/// - live  : it does not end the process and merely returns an `ok` or `fail` line (recording nothing). Hence under live, expect and assert behave the same.
fn handleExpect(it: *Tok, is_assert: bool) void {
    const kind: []const u8 = if (is_assert) "assert" else "expect";
    const expr_text = std.mem.trim(u8, it.rest(), " \t"); // For the diagnostic display (captured before the parse; a slice into cmd_buf)
    const expr = parseExpectExpr(it) orelse return reportExpect(kind, false, expr_text, "invalid syntax", is_assert);
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    switch (digestPayload(expr.probe, &buf)) {
        .unavailable => |reason| reportExpect(kind, false, expr_text, reason, is_assert),
        .ok => |payload| {
            const pass = evalExpect(payload, expr);
            reportExpect(kind, pass, expr_text, if (pass) null else payload, is_assert);
        },
    }
}

/// `await <probe> <key><op><value> [timeout]`. The same predicate as expect's. timeout is a frame budget (0 = evaluate once).
/// A true return = the predicate did not hold and the wait has begun (so the caller advances the frame, or holds the connection).
fn handleAwait(it: *Tok) bool {
    const expr_text = std.mem.trim(u8, it.rest(), " \t");
    const parsed = parseAwaitExpr(it) orelse {
        reportAwait(false, expr_text, "invalid syntax");
        return false;
    };
    // evaluate once, immediately
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const pass = switch (digestPayload(parsed.expr.probe, &buf)) {
        .unavailable => false,
        .ok => |payload| evalExpect(payload, parsed.expr),
    };
    if (pass) {
        reportAwait(true, expr_text, null);
        return false;
    }
    if (parsed.timeout_frames == 0) {
        const actual: ?[]const u8 = switch (digestPayload(parsed.expr.probe, &buf)) {
            .unavailable => |r| r,
            .ok => |payload| payload,
        };
        reportAwait(false, expr_text, actual);
        return false;
    }
    pending_wait = .{ .predicate = .{
        .expr = parsed.expr,
        .expr_text = expr_text,
        .start_frame = frame_index,
        .timeout_frames = parsed.timeout_frames,
    } };
    pending_pred_actual_len = 0;
    return true;
}

const AwaitParsed = struct {
    expr: ExpectExpr,
    timeout_frames: usize,
};

/// The pure parse of await's arguments, with an optional trailing timeout (usize). A surplus or invalid token gives null.
fn parseAwaitExpr(it: *Tok) ?AwaitParsed {
    var probe = it.next() orelse return null;
    if (std.mem.eql(u8, probe, "digest")) {
        probe = it.next() orelse return null;
    }
    const t2 = it.next() orelse return null;
    const expr: ExpectExpr = if (std.mem.eql(u8, t2, "contains")) blk: {
        const sub = it.next() orelse return null;
        break :blk .{ .probe = probe, .form = .{ .contains = sub } };
    } else blk: {
        const cmp = parseCmpToken(t2) orelse return null;
        break :blk .{ .probe = probe, .form = .{ .cmp = cmp } };
    };
    var timeout_frames: usize = 0;
    if (it.next()) |tok| {
        timeout_frames = parseUsize(tok) orelse return null;
        if (it.next() != null) return null;
    }
    return .{ .expr = expr, .timeout_frames = timeout_frames };
}

fn reportAwait(pass: bool, expr_text: []const u8, actual: ?[]const u8) void {
    if (mode == .live) {
        appendResp(if (pass) "ok " else "fail ");
        appendResp(expr_text);
        if (!pass) {
            if (actual) |a| {
                appendResp(" actual=");
                appendResp(a);
            }
        }
        appendResp("\n");
    } else if (pass) {
        std.debug.print("[harness] await ok line {d}: {s}\n", .{ line_no, expr_text });
    } else if (actual) |a| {
        std.debug.print("[harness] await FAILED line {d}: {s} actual={s}\n", .{ line_no, expr_text, a });
        expect_failures += 1;
    } else {
        std.debug.print("[harness] await FAILED line {d}: {s}\n", .{ line_no, expr_text });
        expect_failures += 1;
    }
}

/// Emits the outcome (replay=stderr / live=resp_buf) and records a replay failure.
/// actual is meaningful only on a failure (either the payload or the reason it is unavailable; null on a pass).
fn reportExpect(kind: []const u8, pass: bool, expr_text: []const u8, actual: ?[]const u8, is_assert: bool) void {
    if (mode == .live) {
        appendResp(if (pass) "ok " else "fail ");
        appendResp(expr_text);
        if (!pass) {
            if (actual) |a| {
                appendResp(" actual=");
                appendResp(a);
            }
        }
        appendResp("\n");
    } else if (pass) {
        std.debug.print("[harness] {s} ok line {d}: {s}\n", .{ kind, line_no, expr_text });
    } else if (actual) |a| {
        std.debug.print("[harness] {s} FAILED line {d}: {s} actual={s}\n", .{ kind, line_no, expr_text, a });
    } else {
        std.debug.print("[harness] {s} FAILED line {d}: {s}\n", .{ kind, line_no, expr_text });
    }

    if (!pass and mode == .replay) {
        expect_failures += 1;
        if (is_assert) replayExitIfFailed(); // assert aborts at once
    }
}

/// At the end of a replay: if there were failures, print a summary and exit non-zero.
/// **The mode gate is closed inside the function**, so for live and for a normal run (disabled) it is always a no-op (it never calls process.exit).
fn replayExitIfFailed() void {
    if (mode == .replay and expect_failures > 0) {
        std.debug.print("[harness] verification failures: {d} (expect/assert/action)\n", .{expect_failures});
        std.process.exit(1);
    }
}

// ============================================================================
// fb probe payload
// ============================================================================

/// Writes `<w>x<h> crc=<hex> top=[#RRGGBB:NN%,...]` (the top three colours) into buf and returns it.
fn formatFbPayload(buf: []u8) []u8 {
    const n = @as(usize, frame_w) * @as(usize, frame_h);
    const px = frame_pixels[0..n];
    const crc = png.crc32(std.mem.sliceAsBytes(px));

    const Top = struct { color: u32 = 0, count: u32 = 0 };
    var top = [_]Top{.{}} ** 3;
    var counts = std.AutoHashMap(u32, u32).init(gpa);
    defer counts.deinit();
    var ok = true;
    for (px) |p| {
        const gop = counts.getOrPut(p) catch {
            ok = false;
            break;
        };
        if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
    }
    if (ok) {
        // Make the tie-break explicit (descending count, and ascending colour when equal). Do not let it depend on the hashmap iterator order.
        const cmp = struct {
            fn better(a: Top, b: Top) bool {
                return a.count > b.count or (a.count == b.count and a.color < b.color);
            }
        }.better;
        var cit = counts.iterator();
        while (cit.next()) |e| {
            const cand = Top{ .color = e.key_ptr.*, .count = e.value_ptr.* };
            if (cmp(cand, top[0])) {
                top[2] = top[1];
                top[1] = top[0];
                top[0] = cand;
            } else if (cmp(cand, top[1])) {
                top[2] = top[1];
                top[1] = cand;
            } else if (cmp(cand, top[2])) {
                top[2] = cand;
            }
        }
    }

    var len: usize = 0;
    len += (std.fmt.bufPrint(buf[len..], "{d}x{d} crc={X:0>8} top=[", .{ frame_w, frame_h, crc }) catch return buf[0..len]).len;
    var first = true;
    for (top) |t| {
        if (t.count == 0) continue;
        const pct = @as(u64, t.count) * 100 / n;
        const sep = if (first) "" else ",";
        first = false;
        len += (std.fmt.bufPrint(buf[len..], "{s}#{X:0>6}:{d}%", .{ sep, t.color & 0xFFFFFF, pct }) catch break).len;
    }
    len += (std.fmt.bufPrint(buf[len..], "]", .{}) catch return buf[0..len]).len;
    return buf[0..len];
}

// ============================================================================
// the audio probe (draining the tap, the analysis, and WAV)
// ============================================================================

/// Takes the most recent `dst.len` samples (at most AUDIO_CAP) non-destructively, without moving tail
/// (a peek, so that a digest and a snapshot see the same recent window). The return value is how many were taken.
fn peekRecentAudio(dst: []f32) usize {
    const head = audio_head.load(.acquire);
    const want = @min(dst.len, @min(AUDIO_CAP, head));
    const start = head -% want;
    var i: usize = 0;
    // An `.unordered` load, symmetrical with the producer's `.unordered` store (tolerating a torn read while avoiding data race UB).
    while (i < want) : (i += 1) dst[i] = @atomicLoad(f32, &audio_buf[(start +% i) & AUDIO_MASK], .unordered);
    return want;
}

const AudioStats = struct { rms: f32, peak: f32, f0: f32, silent: bool, frames: usize };

/// The result of the extended analysis (independent of the existing AudioStats; for the additive keys).
const AudioExtStats = struct {
    band_low: f32,
    band_mid: f32,
    band_high: f32,
    centroid: f32,
    onsets: u32,
    lufs: f32,
};

const audio_ext_zero = AudioExtStats{
    .band_low = 0,
    .band_mid = 0,
    .band_high = 0,
    .centroid = 0,
    .onsets = 0,
    .lufs = LUFS_FLOOR,
};

/// Downmixes the most recent min(frames, mono_scratch.len) frames of interleaved samples to mono and computes RMS, peak, f0 and silent.
/// Pure logic (unit testable). mono_scratch is passed in by the caller (there is no hidden global).
/// **This function, AudioStats and ANALYZE_FRAMES do not change** (keeping the existing keys bit-stable).
fn analyzeAudio(interleaved: []const f32, channels: u32, sample_rate: u32, mono_scratch: []f32) AudioStats {
    if (channels == 0 or interleaved.len < channels) return .{ .rms = 0, .peak = 0, .f0 = 0, .silent = true, .frames = 0 };
    const ch: usize = channels;
    const total_frames = interleaved.len / ch;
    const w = @min(total_frames, mono_scratch.len);
    const off = total_frames - w; // the most recent w frames
    var i: usize = 0;
    while (i < w) : (i += 1) {
        var acc: f32 = 0;
        var c: usize = 0;
        while (c < ch) : (c += 1) acc += interleaved[(off + i) * ch + c];
        mono_scratch[i] = acc / @as(f32, @floatFromInt(ch));
    }
    const mono = mono_scratch[0..w];

    var sumsq: f64 = 0;
    var peak: f32 = 0;
    for (mono) |s| {
        sumsq += @as(f64, s) * @as(f64, s);
        const a = @abs(s);
        if (a > peak) peak = a;
    }
    const rms: f32 = if (w > 0) @floatCast(@sqrt(sumsq / @as(f64, @floatFromInt(w)))) else 0;
    const silent = rms < 1e-4;
    const f0: f32 = if (silent) 0 else estimateF0(mono, sample_rate);
    return .{ .rms = rms, .peak = peak, .f0 = f0, .silent = silent, .frames = w };
}

/// band, centroid, onsets and lufs. Called only when a digest is asked for (at event time). It never touches a real-time path.
/// Pure logic (a unit test can call it directly). mono_scratch is passed in by the caller (up to EXT_FRAMES).
/// sample_rate==0, channels==0, or a window of 0 → all zeros plus the lufs floor. Too short a window degrades the computation (and gives the floor at 0).
fn analyzeAudioExt(interleaved: []const f32, channels: u32, sample_rate: u32, mono_scratch: []f32) AudioExtStats {
    if (channels == 0 or sample_rate == 0 or interleaved.len < channels) return audio_ext_zero;
    const ch: usize = channels;
    const total_frames = interleaved.len / ch;
    if (total_frames == 0) return audio_ext_zero;
    const w = @min(total_frames, mono_scratch.len);
    const off = total_frames - w;
    var i: usize = 0;
    while (i < w) : (i += 1) {
        var acc: f32 = 0;
        var c: usize = 0;
        while (c < ch) : (c += 1) acc += interleaved[(off + i) * ch + c];
        mono_scratch[i] = acc / @as(f32, @floatFromInt(ch));
    }
    const mono = mono_scratch[0..w];
    const sr: f32 = @floatFromInt(sample_rate);

    const bands = computeBandCentroid(mono, sr);
    const onsets = countOnsets(mono, sr);
    const lufs = computeLufsMomentary(mono, sample_rate);
    return .{
        .band_low = bands.low,
        .band_mid = bands.mid,
        .band_high = bands.high,
        .centroid = bands.centroid,
        .onsets = onsets,
        .lufs = lufs,
    };
}

/// Applies a Hann window and magnitudeSpectrum to the most recent 4096 frames (zero-padded when there are fewer), and returns
/// the normalised energy ratios band_low(20–250), band_mid(250–2000) and band_high(2000–Nyquist), plus
/// the spectral centroid in Hz. When the energy across every band is 0, they are all 0.
fn computeBandCentroid(mono: []const f32, sample_rate: f32) struct { low: f32, mid: f32, high: f32, centroid: f32 } {
    if (mono.len == 0 or sample_rate <= 0) return .{ .low = 0, .mid = 0, .high = 0, .centroid = 0 };

    // Put the most recent min(len, 4096) at the end of the buffer and zero-pad the front
    @memset(ext_fft_re[0..], 0);
    const n_copy = @min(mono.len, EXT_FFT_N);
    const src_off = mono.len - n_copy;
    const dst_off = EXT_FFT_N - n_copy;
    @memcpy(ext_fft_re[dst_off..][0..n_copy], mono[src_off..][0..n_copy]);
    // magnitudeSpectrum copies samples and applies Hann to them, so re is snapshotted for samples' sake
    var samples: [EXT_FFT_N]f32 = undefined;
    @memcpy(samples[0..], ext_fft_re[0..]);
    dsp.magnitudeSpectrum(samples[0..], ext_fft_re[0..], ext_fft_im[0..], ext_mags[0..]);

    const n_bins = EXT_FFT_N / 2;
    const bin_hz = sample_rate / @as(f32, @floatFromInt(EXT_FFT_N));
    const nyquist = sample_rate * 0.5;
    var e_low: f64 = 0;
    var e_mid: f64 = 0;
    var e_high: f64 = 0;
    var sum_mag: f64 = 0;
    var sum_f_mag: f64 = 0;
    var k: usize = 0;
    while (k < n_bins) : (k += 1) {
        const f = @as(f32, @floatFromInt(k)) * bin_hz;
        if (f < 20.0 or f > nyquist) continue;
        const mag = ext_mags[k];
        const e = @as(f64, mag) * @as(f64, mag);
        sum_mag += mag;
        sum_f_mag += @as(f64, f) * mag;
        if (f < 250.0) {
            e_low += e;
        } else if (f < 2000.0) {
            e_mid += e;
        } else {
            e_high += e;
        }
    }
    const e_tot = e_low + e_mid + e_high;
    if (e_tot <= 0) return .{ .low = 0, .mid = 0, .high = 0, .centroid = 0 };
    const centroid: f32 = if (sum_mag > 0) @floatCast(sum_f_mag / sum_mag) else 0;
    return .{
        .low = @floatCast(e_low / e_tot),
        .mid = @floatCast(e_mid / e_tot),
        .high = @floatCast(e_high / e_tot),
        .centroid = centroid,
    };
}

/// Builds the spectral flux sequence (the sum of positive differences) at hop=1024 and FFT=2048, and
/// counts the local peaks above threshold=mean+1.5σ (deterministically, with fixed coefficients).
/// A plateau that stays above the threshold counts its first peak only (which prevents counting one onset several times).
fn countOnsets(mono: []const f32, sample_rate: f32) u32 {
    _ = sample_rate;
    if (mono.len < ONSET_FFT_N) return 0;

    // the maximum number of hops: (EXT_FRAMES - ONSET_FFT_N) / ONSET_HOP + 1 ≤ 31
    const max_hops = (EXT_FRAMES - ONSET_FFT_N) / ONSET_HOP + 1;
    var flux: [max_hops]f64 = undefined;
    var n_flux: usize = 0;

    var have_prev = false;
    var frame_start: usize = 0;
    while (frame_start + ONSET_FFT_N <= mono.len) : (frame_start += ONSET_HOP) {
        @memcpy(onset_win[0..], mono[frame_start..][0..ONSET_FFT_N]);
        dsp.magnitudeSpectrum(onset_win[0..], onset_fft_re[0..], onset_fft_im[0..], onset_mags_cur[0..]);
        if (have_prev) {
            var sum: f64 = 0;
            var k: usize = 0;
            while (k < ONSET_FFT_N / 2) : (k += 1) {
                const d = onset_mags_cur[k] - onset_mags_prev[k];
                if (d > 0) sum += d;
            }
            if (n_flux < max_hops) {
                flux[n_flux] = sum;
                n_flux += 1;
            }
        }
        @memcpy(onset_mags_prev[0..], onset_mags_cur[0..]);
        have_prev = true;
    }
    if (n_flux == 0) return 0;

    // mean + 1.5σ
    var mean: f64 = 0;
    for (flux[0..n_flux]) |v| mean += v;
    mean /= @as(f64, @floatFromInt(n_flux));
    var var_acc: f64 = 0;
    for (flux[0..n_flux]) |v| {
        const d = v - mean;
        var_acc += d * d;
    }
    const sigma = @sqrt(var_acc / @as(f64, @floatFromInt(n_flux)));
    const thresh = mean + 1.5 * sigma;

    var count: u32 = 0;
    var i: usize = 0;
    while (i < n_flux) : (i += 1) {
        if (flux[i] <= thresh) continue;
        const left_ok = (i == 0) or (flux[i] >= flux[i - 1]);
        const right_ok = (i + 1 >= n_flux) or (flux[i] > flux[i + 1]); // the right-hand side is a strict > so a plateau counts once
        if (left_ok and right_ok) count += 1;
    }
    return count;
}

/// BS.1770 K-weighting (two biquads, a high shelf plus a high pass; the coefficients are derived from sample_rate by the design formulas)
/// → the mean square of the most recent 400ms → -0.691 + 10·log10(ms). Treated as mono, 1 channel. Silence gives the floor of -99.0.
fn computeLufsMomentary(mono: []const f32, sample_rate: u32) f32 {
    if (mono.len == 0 or sample_rate == 0) return LUFS_FLOOR;
    const sr: f64 = @floatFromInt(sample_rate);
    const win_n = @min(mono.len, @as(usize, @intFromFloat(0.4 * sr)));
    if (win_n == 0) return LUFS_FLOOR;
    const off = mono.len - win_n;

    // Stage 1: the high shelf (the ITU-R BS.1770 analogue prototype → bilinear)
    // f0=1681.974... Hz, G=3.999... dB, Q=0.707175...
    const hs = kWeightShelfCoeffs(sr);
    // Stage 2: high-pass f0=38.135... Hz, Q=0.500327...
    const hp = kWeightHpCoeffs(sr);

    var z1_hs: f64 = 0;
    var z2_hs: f64 = 0;
    var z1_hp: f64 = 0;
    var z2_hp: f64 = 0;
    var sum_sq: f64 = 0;
    var i: usize = 0;
    while (i < win_n) : (i += 1) {
        const x: f64 = mono[off + i];
        // Direct Form I transposed: y = b0*x + z1; z1 = b1*x - a1*y + z2; z2 = b2*x - a2*y
        const y1 = hs.b0 * x + z1_hs;
        z1_hs = hs.b1 * x - hs.a1 * y1 + z2_hs;
        z2_hs = hs.b2 * x - hs.a2 * y1;
        const y2 = hp.b0 * y1 + z1_hp;
        z1_hp = hp.b1 * y1 - hp.a1 * y2 + z2_hp;
        z2_hp = hp.b2 * y1 - hp.a2 * y2;
        sum_sq += y2 * y2;
    }
    const ms = sum_sq / @as(f64, @floatFromInt(win_n));
    if (ms <= 1e-12) return LUFS_FLOOR;
    const lufs = -0.691 + 10.0 * std.math.log10(ms);
    if (lufs < LUFS_FLOOR) return LUFS_FLOOR;
    return @floatCast(lufs);
}

const BiquadCoeffs = struct { b0: f64, b1: f64, b2: f64, a1: f64, a2: f64 };

/// The coefficients of the BS.1770 pre-filter (a high shelf). They depend on sample_rate (never hard-code 48k).
fn kWeightShelfCoeffs(sample_rate: f64) BiquadCoeffs {
    const f0 = 1681.974450955533;
    const G = 3.999843853973347;
    const Q = 0.7071752369554196;
    const K = @tan(std.math.pi * f0 / sample_rate);
    const Vh = std.math.pow(f64, 10.0, G / 20.0);
    const Vb = std.math.pow(f64, Vh, 0.4996667741545416);
    const a0 = 1.0 + K / Q + K * K;
    return .{
        .b0 = (Vh + Vb * K / Q + K * K) / a0,
        .b1 = 2.0 * (K * K - Vh) / a0,
        .b2 = (Vh - Vb * K / Q + K * K) / a0,
        .a1 = 2.0 * (K * K - 1.0) / a0,
        .a2 = (1.0 - K / Q + K * K) / a0,
    };
}

/// The coefficients of BS.1770 RLB-weighting (a high pass). They depend on sample_rate.
fn kWeightHpCoeffs(sample_rate: f64) BiquadCoeffs {
    const f0 = 38.13547087602444;
    const Q = 0.5003270373238773;
    const K = @tan(std.math.pi * f0 / sample_rate);
    const a0 = 1.0 + K / Q + K * K;
    return .{
        .b0 = 1.0 / a0,
        .b1 = -2.0 / a0,
        .b2 = 1.0 / a0,
        .a1 = 2.0 * (K * K - 1.0) / a0,
        .a2 = (1.0 - K / Q + K * K) / a0,
    };
}

/// Estimates the fundamental frequency by autocorrelation (50–2000Hz). It is strong on a clean tone. Undetectable or silent gives 0.
fn estimateF0(mono: []const f32, sample_rate: u32) f32 {
    const n = mono.len;
    if (n < 64 or sample_rate == 0) return 0;
    const sr: f32 = @floatFromInt(sample_rate);

    var mean: f32 = 0;
    for (mono) |s| mean += s;
    mean /= @floatFromInt(n);

    var energy: f64 = 0;
    for (mono) |s| {
        const c = s - mean;
        energy += @as(f64, c) * @as(f64, c);
    }
    if (energy <= 1e-9) return 0;

    const min_lag: usize = @max(2, @as(usize, @intFromFloat(sr / 2000.0)));
    const max_lag: usize = @min(n / 2, @as(usize, @intFromFloat(sr / 50.0)));
    if (max_lag <= min_lag) return 0;

    var best_lag: usize = 0;
    var best_corr: f64 = 0;
    var lag = min_lag;
    while (lag <= max_lag) : (lag += 1) {
        var corr: f64 = 0;
        var i = lag;
        while (i < n) : (i += 1) {
            corr += @as(f64, mono[i] - mean) * @as(f64, mono[i - lag] - mean);
        }
        if (corr > best_corr) {
            best_corr = corr;
            best_lag = lag;
        }
    }
    if (best_lag == 0 or best_corr / energy < 0.3) return 0;
    return sr / @as(f32, @floatFromInt(best_lag));
}

fn formatAudioPayload(buf: []u8) []u8 {
    const channels = audio_channels.load(.monotonic);
    const rate = audio_rate.load(.monotonic);
    const n = peekRecentAudio(&audio_scratch);
    // Keep the key set identical between the branches (which prevents expect failing on a missing key).
    if (n == 0 or channels == 0) {
        return std.fmt.bufPrint(buf, "rms=0.0000 peak=0.0000 f0=0.0 silent=1 frames=0 band_low=0.0000 band_mid=0.0000 band_high=0.0000 centroid=0 onsets=0 lufs=-99.0", .{}) catch buf[0..0];
    }
    const st = analyzeAudio(audio_scratch[0..n], channels, rate, &audio_mono);
    const ext = analyzeAudioExt(audio_scratch[0..n], channels, rate, &audio_mono_ext);
    return std.fmt.bufPrint(buf, "rms={d:.4} peak={d:.4} f0={d:.1} silent={d} frames={d} band_low={d:.4} band_mid={d:.4} band_high={d:.4} centroid={d:.0} onsets={d} lufs={d:.1}", .{
        st.rms,       st.peak,      st.f0,         @intFromBool(st.silent), st.frames,
        ext.band_low, ext.band_mid, ext.band_high, ext.centroid,            ext.onsets,
        ext.lufs,
    }) catch buf[0..0];
}

/// Encodes PCM16 little-endian RIFF/WAVE (pure logic, unit testable).
fn encodeWav(interleaved: []const f32, channels: u32, sample_rate: u32, allocator: std.mem.Allocator) ![]u8 {
    const num_samples = interleaved.len;
    const data_size: u32 = @intCast(num_samples * 2);
    const total = 44 + @as(usize, data_size);
    const buf = try allocator.alloc(u8, total);
    errdefer allocator.free(buf);

    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 36 + data_size, .little);
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little); // subchunk1 size (PCM)
    std.mem.writeInt(u16, buf[20..22], 1, .little); // audio format = PCM
    std.mem.writeInt(u16, buf[22..24], @intCast(channels), .little);
    std.mem.writeInt(u32, buf[24..28], sample_rate, .little);
    std.mem.writeInt(u32, buf[28..32], sample_rate * channels * 2, .little); // byte_rate
    std.mem.writeInt(u16, buf[32..34], @intCast(channels * 2), .little); // block_align
    std.mem.writeInt(u16, buf[34..36], 16, .little); // bits_per_sample
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_size, .little);

    var off: usize = 44;
    for (interleaved) |s| {
        const clamped = std.math.clamp(s, -1.0, 1.0);
        const v: i16 = @intFromFloat(clamped * 32767.0);
        std.mem.writeInt(i16, buf[off..][0..2], v, .little);
        off += 2;
    }
    return buf;
}

fn writeWav(io: std.Io, path: []const u8, interleaved: []const f32, channels: u32, sample_rate: u32, allocator: std.mem.Allocator) !void {
    const bytes = try encodeWav(interleaved, channels, sample_rate, allocator);
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

// ============================================================================
// stats probe
// ============================================================================

fn formatStatsPayload(buf: []u8) []u8 {
    return std.fmt.bufPrint(buf, "{{\"frame\":{d},\"virtual_fps\":{d:.1},\"mouse_move_merge_count\":{d},\"mouse_scroll_merge_count\":{d},\"event_drop_count\":{d},\"modal_blocked_injections\":{d}}}", .{
        frame_index,
        VIRTUAL_FPS,
        last_stats.mouse_move_merge_count,
        last_stats.mouse_scroll_merge_count,
        last_stats.event_drop_count,
        modal_blocked_injections,
    }) catch buf[0..0];
}

// ============================================================================
// helpers
// ============================================================================

fn queue(ev: Event) void {
    if (inject_count >= inject_buf.len) {
        warnLine("the inject queue overflowed: dropping");
        return;
    }
    inject_buf[inject_count] = ev;
    inject_count += 1;
}

fn queueMidi(ev: MidiEvent) bool {
    if (midi_count >= midi_buf.len) {
        warnLine("the midi FIFO overflowed: dropping");
        return false;
    }
    midi_buf[midi_count] = ev;
    midi_count += 1;
    return true;
}

fn applyMidiState(ev: MidiEvent) void {
    switch (ev) {
        .note_on => |note| midi_pressed[note.note / 8] |= @as(u8, 1) << @intCast(note.note % 8),
        .note_off => |note| midi_pressed[note.note / 8] &= ~(@as(u8, 1) << @intCast(note.note % 8)),
        .cc => |cc| {
            midi_cc_values[cc.controller] = cc.value;
            midi_cc_set[cc.controller] = true;
        },
    }
}

/// Returns the next single command. The separators are a newline and `;` (so that `'inject A; step 3; digest fb'` can be written as one argument).
fn nextLine() ?[]const u8 {
    if (cursor >= cmd_buf.len) return null;
    const start = cursor;
    var end = cursor;
    while (end < cmd_buf.len and cmd_buf[end] != '\n' and cmd_buf[end] != ';') end += 1;
    cursor = if (end < cmd_buf.len) end + 1 else end;
    line_no += 1;
    return cmd_buf[start..end];
}

fn setButton(b: *MouseButtons, btn: MouseButton, down: bool) void {
    switch (btn) {
        .left => b.left = down,
        .right => b.right = down,
        .middle => b.middle = down,
        else => {},
    }
}

fn parseKey(name: []const u8) ?KeyCode {
    var buf: [32]u8 = undefined;
    if (name.len == 0 or name.len > buf.len) return null;
    for (name, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    return std.meta.stringToEnum(KeyCode, buf[0..name.len]);
}

fn parseButton(tok: ?[]const u8) ?MouseButton {
    const name = tok orelse return null;
    var buf: [16]u8 = undefined;
    if (name.len == 0 or name.len > buf.len) return null;
    for (name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return std.meta.stringToEnum(MouseButton, buf[0..name.len]);
}

/// Matches the remaining tokens against shift, ctrl, alt and cmd (case-insensitive) and raises the flags.
/// If even one token is unknown it returns null (and the caller warns and drops that event, failing fast.
/// The same convention as parseKey's and parseButton's: an invalid token gives null and the caller warns).
/// With 0 tokens remaining it gives empty ModifierFlags (which is non-null).
fn parseModifiers(it: *Tok) ?ModifierFlags {
    var m = ModifierFlags{};
    while (it.next()) |tok| {
        var buf: [16]u8 = undefined;
        if (tok.len == 0 or tok.len > buf.len) return null;
        for (tok, 0..) |c, i| buf[i] = std.ascii.toLower(c);
        const name = buf[0..tok.len];
        if (std.mem.eql(u8, name, "shift")) {
            m.shift = true;
        } else if (std.mem.eql(u8, name, "ctrl")) {
            m.ctrl = true;
        } else if (std.mem.eql(u8, name, "alt")) {
            m.alt = true;
        } else if (std.mem.eql(u8, name, "cmd")) {
            m.cmd = true;
        } else {
            return null;
        }
    }
    return m;
}

fn parseUsize(tok: ?[]const u8) ?usize {
    return std.fmt.parseInt(usize, tok orelse return null, 10) catch null;
}

fn parseI32(tok: ?[]const u8) ?i32 {
    return std.fmt.parseInt(i32, tok orelse return null, 10) catch null;
}

fn parseF32(tok: ?[]const u8) ?f32 {
    return std.fmt.parseFloat(f32, tok orelse return null) catch null;
}

fn warnLine(msg: []const u8) void {
    std.debug.print("[harness] line {d}: {s}\n", .{ line_no, msg });
    if (mode == .live) {
        appendResp("error: ");
        appendResp(msg);
        appendResp("\n");
    }
}

/// Reads an environment variable. 0.16's std has no libc-independent getenv, so libc getenv is used
/// (the platform module is always built with `link_libc`).
fn getEnv(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

// ============================================================================
// tests (no display needed; absolute-value asserts to catch a wrong implementation)
// ============================================================================
const testing = std.testing;

fn resetForTest() void {
    mode = .replay; // Settle the behaviour at EOF as a replay would (the tests amount to a file source)
    clock_mode = .manual;
    cmd_buf = "";
    cursor = 0;
    line_no = 0;
    steps_remaining = 0;
    quit_requested = false;
    pending_wait = .none;
    expect_failures = 0;
    frame_index = 0;
    modal_blocked_injections = 0;
    last_blocker_warn_label = null;
    inject_count = 0;
    inject_read = 0;
    midi_count = 0;
    midi_read = 0;
    @memset(&midi_pressed, 0);
    @memset(&midi_cc_values, 0);
    @memset(&midi_cc_set, false);
    mouse_x = 0;
    mouse_y = 0;
    mouse_buttons = .{};
    gamepad_states = [_]?GamepadState{null} ** MAX_GAMEPADS;
    @memset(&composition_text, 0);
    composition_len = 0;
    composition_cursor = 0;
    composition_revision = 0;
    composition_active = false;
    lock_pixels = &.{};
    lock_w = 0;
    lock_h = 0;
    lock_valid = false;
    frame_w = 0;
    frame_h = 0;
    have_frame = false;
    audio_head = .init(0);
    audio_channels = .init(0);
    audio_rate = .init(0);
    probe_count = 0;
    external_registry_enabled = false;
    // The action registry is a separate module. After the reset, setEnabled(true) keeps
    // the older behaviour (registerAction working with mode=.replay) as the tests' default.
    action_registry.resetForTest();
    action_registry.setEnabled(true);
    // The synthetic capture source: tidy away any state left over from the previous test (video's pixel buffer, audio's
    // generating thread) for certain, and start clean (which prevents a leak between tests).
    if (synth_video) |*dev| dev.close();
    synth_video = null;
    if (synth_audio) |dev| dev.close();
    synth_audio = null;
    capture_synthetic_requested = false;
    skip_frame_copy = false;
    headless_active = false;
    freerun_reading = false;
    freerun_acc.clearRetainingCapacity();
    test_poll_zero_count = 0;
    pending_pred_actual_len = 0;
    live_stream_owned = false;
}

test "parseKey: a name to a KeyCode (case-insensitive, and digits)" {
    try testing.expectEqual(KeyCode.A, parseKey("a").?);
    try testing.expectEqual(KeyCode.A, parseKey("A").?);
    try testing.expectEqual(KeyCode.ESCAPE, parseKey("escape").?);
    try testing.expectEqual(KeyCode.SPACE, parseKey("Space").?);
    try testing.expectEqual(KeyCode.@"0", parseKey("0").?);
    try testing.expectEqual(@as(?KeyCode, null), parseKey("nope"));
}

test "parseButton: a name to a MouseButton" {
    try testing.expectEqual(MouseButton.left, parseButton("left").?);
    try testing.expectEqual(MouseButton.right, parseButton("RIGHT").?);
    try testing.expectEqual(MouseButton.middle, parseButton("Middle").?);
    try testing.expectEqual(@as(?MouseButton, null), parseButton("x"));
}

test "parseModifiers: none means empty, one, several (case-insensitive), and unknown means null" {
    {
        var it = std.mem.tokenizeAny(u8, "", " \t");
        const m = parseModifiers(&it).?;
        try testing.expect(!m.shift and !m.ctrl and !m.alt and !m.cmd);
    }
    {
        var it = std.mem.tokenizeAny(u8, "cmd", " \t");
        const m = parseModifiers(&it).?;
        try testing.expect(m.cmd and !m.shift and !m.ctrl and !m.alt);
    }
    {
        var it = std.mem.tokenizeAny(u8, "Cmd SHIFT", " \t"); // mixed case
        const m = parseModifiers(&it).?;
        try testing.expect(m.cmd and m.shift and !m.ctrl and !m.alt);
    }
    {
        var it = std.mem.tokenizeAny(u8, "shift ctrl alt cmd", " \t");
        const m = parseModifiers(&it).?;
        try testing.expect(m.shift and m.ctrl and m.alt and m.cmd);
    }
    {
        var it = std.mem.tokenizeAny(u8, "bogus", " \t");
        try testing.expectEqual(@as(?ModifierFlags, null), parseModifiers(&it));
    }
    {
        var it = std.mem.tokenizeAny(u8, "cmd bogus", " \t"); // even with a recognised one first, one unknown mixed in gives null
        try testing.expectEqual(@as(?ModifierFlags, null), parseModifiers(&it));
    }
}

test "parseKeyExtras: repeat is delivered as a token of key_down" {
    var it = std.mem.tokenizeAny(u8, "cmd repeat", " \t");
    const extras = parseKeyExtras(&it).?;
    try testing.expect(extras.repeat);
    try testing.expect(extras.modifiers.cmd);
    var bad = std.mem.tokenizeAny(u8, "repeatt", " \t");
    try testing.expectEqual(@as(?KeyExtras, null), parseKeyExtras(&bad));
}

test "inject composition: the latest-wins state contract of update, commit and cancel" {
    resetForTest();
    cmd_buf =
        "inject composition update 4 あい\n" ++
        "inject composition update 2 あい\n" ++
        "inject commit 確\n" ++
        "inject composition cancel\n" ++
        "step 1\nquit";
    try testing.expect(pollGate(true));

    // The order of start, update, commit and char is preserved.
    const start = nextInjectedEvent().?;
    try testing.expect(start == .composition_changed and start.composition_changed.phase == .start);
    const update = nextInjectedEvent().?;
    try testing.expect(update == .composition_changed and update.composition_changed.phase == .update);
    const commit = nextInjectedEvent().?;
    try testing.expect(commit == .composition_changed and commit.composition_changed.phase == .commit);
    try testing.expectEqual(@as(u32, 3), commit.composition_changed.revision);
    const ch = nextInjectedEvent().?;
    try testing.expect(ch == .char_input and ch.char_input.codepoint == '確');
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    var buf: [COMPOSITION_CAP]u8 = undefined;
    const snapshot = getCompositionSnapshot(&buf);
    try testing.expectEqualStrings("", snapshot.text);
    try testing.expectEqual(@as(u32, 3), snapshot.revision);
    try testing.expectEqual(@as(u32, 0), snapshot.cursor);
}

test "inject commit: a bare commit delivers char_input with no composition_changed" {
    resetForTest();
    cmd_buf =
        "inject commit AB\n" ++
        "step 1\nquit";
    try testing.expect(pollGate(true));

    const a = nextInjectedEvent().?;
    try testing.expect(a == .char_input and a.char_input.codepoint == 'A');
    const b = nextInjectedEvent().?;
    try testing.expect(b == .char_input and b.char_input.codepoint == 'B');
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    var buf: [COMPOSITION_CAP]u8 = undefined;
    const snapshot = getCompositionSnapshot(&buf);
    try testing.expectEqualStrings("", snapshot.text);
    try testing.expectEqual(@as(u32, 0), snapshot.revision);
    try testing.expectEqual(@as(u32, 0), snapshot.cursor);
}

test "inject composition: an empty update is allowed, cancel is a no-op before an update, and cursor is clamped to a UTF-8 boundary" {
    resetForTest();
    cmd_buf =
        "inject composition cancel\n" ++
        "inject composition update 99\n" ++
        "inject composition update 4 あい\n" ++
        "step 1\nquit";
    try testing.expect(pollGate(true));
    const empty = nextInjectedEvent().?;
    try testing.expect(empty == .composition_changed and empty.composition_changed.phase == .start);
    const update = nextInjectedEvent().?;
    try testing.expect(update == .composition_changed and update.composition_changed.cursor == 3);
    var buf: [COMPOSITION_CAP]u8 = undefined;
    const snapshot = getCompositionSnapshot(&buf);
    try testing.expectEqualStrings("あい", snapshot.text);
    try testing.expectEqual(@as(u32, 3), snapshot.cursor);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
}

test "inject file_drop: a single path, spaces kept, and consecutive and trailing whitespace kept" {
    resetForTest();
    cmd_buf =
        \\inject file_drop /tmp/a.png
        \\step 1
        \\inject file_drop /tmp/My Image.png
        \\step 1
        \\inject file_drop /tmp/trailing  
        \\step 1
        \\inject file_drop /tmp/a  b.png
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    var e = nextInjectedEvent().?;
    try testing.expect(e == .file_drop);
    try testing.expectEqual(@as(u8, 1), e.file_drop.count);
    try testing.expectEqualStrings("/tmp/a.png", e.file_drop.paths[0].slice());
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expectEqualStrings("/tmp/My Image.png", e.file_drop.paths[0].slice());
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expectEqualStrings("/tmp/trailing  ", e.file_drop.paths[0].slice());
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expectEqualStrings("/tmp/a  b.png", e.file_drop.paths[0].slice());
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
    try testing.expect(!pollGate(true));
}

test "inject file_drop: an empty path, invalid UTF-8, and going over the limit are rejected" {
    resetForTest();
    cmd_buf =
        "inject file_drop\n" ++
        "inject file_drop \n" ++
        "inject file_drop \xff\n" ++
        "step 1\nquit";
    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
    try testing.expect(!pollGate(true));

    // over the limit (FILE_DROP_PATH_BYTES+1)
    resetForTest();
    var script_buf: [48 + types.FILE_DROP_PATH_BYTES + 1]u8 = undefined;
    const prefix = "inject file_drop ";
    @memcpy(script_buf[0..prefix.len], prefix);
    @memset(script_buf[prefix.len..][0 .. types.FILE_DROP_PATH_BYTES + 1], 'x');
    const mid = prefix.len + types.FILE_DROP_PATH_BYTES + 1;
    const suffix = "\nstep 1\nquit";
    @memcpy(script_buf[mid..][0..suffix.len], suffix);
    cmd_buf = script_buf[0 .. mid + suffix.len];
    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
    try testing.expect(!pollGate(true));
}

test "inject file_drop: several tokens are not read as several files" {
    resetForTest();
    cmd_buf =
        \\inject file_drop /tmp/a.png /tmp/b.png
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    const e = nextInjectedEvent().?;
    try testing.expect(e == .file_drop);
    try testing.expectEqual(@as(u8, 1), e.file_drop.count);
    try testing.expectEqualStrings("/tmp/a.png /tmp/b.png", e.file_drop.paths[0].slice());
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
}

test "inject file_drop: the path bytes of a live raw record and of a replay match" {
    resetForTest();
    const raw = "inject file_drop /tmp/My Image.png";
    // The contract is that a live record stores the raw request as it stands, and that a replay interprets the same line.
    cmd_buf = raw ++ "\nstep 1\nquit";
    try testing.expect(pollGate(true));
    const live_ev = nextInjectedEvent().?;
    try testing.expectEqualStrings("/tmp/My Image.png", live_ev.file_drop.paths[0].slice());
    const live_bytes = live_ev.file_drop.paths[0].slice();

    resetForTest();
    cmd_buf = raw ++ "\nstep 1\nquit";
    try testing.expect(pollGate(true));
    const replay_ev = nextInjectedEvent().?;
    try testing.expectEqualStrings(live_bytes, replay_ev.file_drop.paths[0].slice());
}

test "inject file_drop: with harness disabled the inject queue stays empty (the existing no-op)" {
    resetForTest();
    mode = .disabled;
    cmd_buf = "";
    try testing.expect(!pollGate(true));
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
}

test "inject modifiers: reflected on all six paths, and empty when unspecified" {
    resetForTest();
    cmd_buf =
        \\inject key_down S cmd
        \\step 1
        \\inject key_up A shift
        \\step 1
        \\inject key_down S cmd shift
        \\step 1
        \\inject mouse_move 10 20 ctrl
        \\step 1
        \\inject mouse_down left alt
        \\step 1
        \\inject mouse_up right cmd
        \\step 1
        \\inject scroll 0 -3 ctrl
        \\step 1
        \\inject key_down A
        \\step 1
        \\quit
    ;

    // key_down S cmd
    try testing.expect(pollGate(true));
    var e = nextInjectedEvent().?;
    try testing.expect(e == .key_down and e.key_down.key == .S);
    try testing.expect(e.key_down.modifiers.cmd and !e.key_down.modifiers.shift and !e.key_down.modifiers.ctrl and !e.key_down.modifiers.alt);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    // key_up A shift (the key_up branch)
    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expect(e == .key_up and e.key_up.key == .A and e.key_up.modifiers.shift and !e.key_up.modifiers.cmd);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    // key_down S cmd shift (several)
    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expect(e == .key_down and e.key_down.modifiers.cmd and e.key_down.modifiers.shift and !e.key_down.modifiers.ctrl);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    // mouse_move 10 20 ctrl (the mouse_move branch, keeping the coordinates)
    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expect(e == .mouse_move and e.mouse_move.x == 10 and e.mouse_move.y == 20 and e.mouse_move.modifiers.ctrl);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    // mouse_down left alt (keeping button and buttons)
    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expect(e == .mouse_down and e.mouse_down.button == .left and e.mouse_down.buttons.left and e.mouse_down.modifiers.alt);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    // mouse_up right cmd (the mouse_up branch)
    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expect(e == .mouse_up and e.mouse_up.button == .right and e.mouse_up.modifiers.cmd);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    // scroll 0 -3 ctrl (keeping dx and dy)
    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expect(e == .mouse_scroll and e.mouse_scroll.dx == 0 and e.mouse_scroll.dy == -3 and e.mouse_scroll.modifiers.ctrl);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    // key_down A (no modifiers → all false)
    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expect(e == .key_down and e.key_down.key == .A);
    const m = e.key_down.modifiers;
    try testing.expect(!m.shift and !m.ctrl and !m.alt and !m.cmd);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    try testing.expect(!pollGate(true));
}

test "inject modifiers: an unknown modifier fails fast (nothing is injected and the state is not dirtied)" {
    resetForTest();
    cmd_buf =
        \\inject mouse_down left bogus
        \\inject mouse_move 10 20 bogus
        \\inject key_down S bogus
        \\step 1
        \\inject mouse_down left
        \\step 1
        \\quit
    ;

    // frame 1: all 3 fail fast and are not queued
    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
    // mouse_down left bogus does not reach setButton (so the button state is not dirtied)
    try testing.expect(!mouse_buttons.left);

    // frame 2: a valid mouse_down left. The coordinates were not dirtied by mouse_move 10 20 bogus and stay at their initial (0,0)
    try testing.expect(pollGate(true));
    const e = nextInjectedEvent().?;
    try testing.expect(e == .mouse_down and e.mouse_down.button == .left and e.mouse_down.buttons.left);
    try testing.expect(e.mouse_down.x == 0 and e.mouse_down.y == 0);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    try testing.expect(!pollGate(true));
}

test "the execution model: inject to nextEvent is FIFO, and step gates the frame" {
    resetForTest();
    cmd_buf =
        \\inject key_down A
        \\inject mouse_down left
        \\step 1
        \\step 2
        \\quit
    ;
    // frame 1: step 1 (with 2 injections queued just before)
    try testing.expect(pollGate(true));
    const e0 = nextInjectedEvent().?;
    try testing.expect(e0 == .key_down and e0.key_down.key == .A);
    const e1 = nextInjectedEvent().?;
    try testing.expect(e1 == .mouse_down and e1.mouse_down.button == .left and e1.mouse_down.buttons.left);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    // frames 2 and 3: step 2 (with no injections)
    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    // quit → the end
    try testing.expect(!pollGate(true));
}

test "the execution model: native_continue=false stops it" {
    resetForTest();
    cmd_buf = "step 5\n";
    try testing.expect(!pollGate(false));
}

test "the virtual clock: getTime = frame_index/60, advancing on a present" {
    resetForTest();
    try testing.expectEqual(@as(f64, 0.0), now());
    const px = [_]u32{0xFF112233};
    onLock(&px, 1, 1);
    onPresent();
    try testing.expectEqual(@as(f64, 1.0 / 60.0), now());
    onLock(&px, 1, 1);
    onPresent();
    try testing.expectEqual(@as(f64, 2.0 / 60.0), now());
    try testing.expect(have_frame);
    try testing.expectEqual(@as(u32, 0xFF112233), frame_pixels[0]);
}

test "skip_frame_copy: while it is on, only frame_index advances and the @memcpy is skipped" {
    resetForTest();
    skip_frame_copy = true;
    defer skip_frame_copy = false;
    const px = [_]u32{0xFF445566};
    onLock(&px, 1, 1);
    onPresent();
    try testing.expectEqual(@as(u64, 1), frame_index);
    try testing.expectEqual(@as(f64, 1.0 / 60.0), now());
    // The frame is not copied as owned, so have_frame is not raised.
    try testing.expect(!have_frame);
    onLock(&px, 1, 1);
    onPresent();
    try testing.expectEqual(@as(u64, 2), frame_index);
    try testing.expect(!have_frame);
}

test "a lock miss: a present after a null lock does not re-copy stale pixels" {
    resetForTest();
    const px = [_]u32{0xFFAABBCC};
    onLock(&px, 1, 1);
    onPresent();
    try testing.expect(have_frame);
    try testing.expectEqual(@as(u32, 0xFFAABBCC), frame_pixels[0]);
    onLockMiss();
    onPresent();
    try testing.expectEqual(@as(u32, 0xFFAABBCC), frame_pixels[0]);
    try testing.expectEqual(@as(u64, 2), frame_index);
}

test "snapshot and digest: skipped before a present (safe even with the io or the frame unsettled)" {
    resetForTest();
    cmd_buf =
        \\snapshot fb /tmp/should_not_write.png
        \\digest fb
        \\quit
    ;
    try testing.expect(!pollGate(true));
    try testing.expect(!have_frame);
}

test "the fb payload: known pixels, asserting crc and top against absolute values" {
    resetForTest();
    // 2x2: 3px = 0xFF000000, 1px = 0xFF0000FF
    var px = [_]u32{ 0xFF000000, 0xFF000000, 0xFF000000, 0xFF0000FF };
    frame_pixels = px[0..];
    frame_w = 2;
    frame_h = 2;
    have_frame = true;
    const crc = png.crc32(std.mem.sliceAsBytes(px[0..4]));
    var expect_buf: [128]u8 = undefined;
    const expected = std.fmt.bufPrint(&expect_buf, "2x2 crc={X:0>8} top=[#000000:75%,#0000FF:25%]", .{crc}) catch unreachable;
    var buf: [256]u8 = undefined;
    const payload = formatFbPayload(&buf);
    try testing.expectEqualStrings(expected, payload);
    // frame_pixels belongs to the test, so harness must not free it
    frame_pixels = &.{};
}

test "the audio ring: latest-wins, so only the most recent capacity can be peeked at" {
    resetForTest();
    mode = .replay; // anything but disabled
    audio_head = .init(0);
    // writing past the capacity: 0,1,2,...,AUDIO_CAP+99, one sample at a time
    var v: usize = 0;
    const overflow = AUDIO_CAP + 100;
    while (v < overflow) : (v += 1) {
        const s = [_]f32{@floatFromInt(v)};
        onAudioSamples(&s, 1, 1, 48000);
    }
    var dst: [8]f32 = undefined;
    const n = peekRecentAudio(&dst);
    try testing.expectEqual(@as(usize, 8), n);
    // the most recent 8 samples = overflow-8 .. overflow-1
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try testing.expectEqual(@as(f32, @floatFromInt(overflow - 8 + i)), dst[i]);
    }
}

test "analyzeAudio: silence, a constant, and a 440Hz sine, asserted against absolute values" {
    var mono: [4096]f32 = undefined;

    // silence
    var sil = [_]f32{0} ** 256;
    const a0 = analyzeAudio(&sil, 1, 48000, &mono);
    try testing.expect(a0.silent);
    try testing.expectApproxEqAbs(@as(f32, 0), a0.rms, 1e-6);
    try testing.expectEqual(@as(f32, 0), a0.f0);

    // a 440Hz sine of amplitude 0.5 (mono, 48000Hz, 4800 samples = 0.1s)
    const sr: f32 = 48000;
    const freq: f32 = 440;
    var sine: [4800]f32 = undefined;
    var i: usize = 0;
    while (i < sine.len) : (i += 1) {
        sine[i] = 0.5 * @sin(2.0 * std.math.pi * freq * @as(f32, @floatFromInt(i)) / sr);
    }
    const a1 = analyzeAudio(&sine, 1, 48000, &mono);
    try testing.expect(!a1.silent);
    try testing.expectApproxEqAbs(@as(f32, 0.5), a1.peak, 0.02); // amplitude 0.5
    try testing.expectApproxEqAbs(@as(f32, 0.3536), a1.rms, 0.02); // 0.5/√2
    try testing.expectApproxEqAbs(@as(f32, 440), a1.f0, 5.0); // ±5Hz
}

/// Fills a mono buffer with a known sine (of amplitude amp, frequency freq_hz, at sr).
fn fillSine(dst: []f32, amp: f32, freq_hz: f32, sample_rate: f32) void {
    for (dst, 0..) |*s, i| {
        s.* = amp * @sin(2.0 * std.math.pi * freq_hz * @as(f32, @floatFromInt(i)) / sample_rate);
    }
}

test "analyzeAudioExt: a 440Hz sine — band_mid dominates, centroid is about 440, onsets=0" {
    var mono_ext: [EXT_FRAMES]f32 = undefined;
    var sine: [4800]f32 = undefined;
    fillSine(&sine, 0.5, 440, 48000);
    const ext = analyzeAudioExt(&sine, 1, 48000, &mono_ext);
    try testing.expect(ext.band_mid > 0.9);
    try testing.expectApproxEqAbs(@as(f32, 440), ext.centroid, 20.0);
    try testing.expectEqual(@as(u32, 0), ext.onsets);
}

test "analyzeAudioExt: 100Hz makes band_low dominate, and 6kHz makes band_high dominate" {
    var mono_ext: [EXT_FRAMES]f32 = undefined;
    var low: [4800]f32 = undefined;
    fillSine(&low, 0.5, 100, 48000);
    const e_low = analyzeAudioExt(&low, 1, 48000, &mono_ext);
    try testing.expect(e_low.band_low > 0.9);

    var high: [4800]f32 = undefined;
    fillSine(&high, 0.5, 6000, 48000);
    const e_high = analyzeAudioExt(&high, 1, 48000, &mono_ext);
    try testing.expect(e_high.band_high > 0.9);
}

test "analyzeAudioExt: the LUFS of a 997Hz sine at amplitude 0.5 is about -9.1" {
    // BS.1770 K-weighting boosts 997Hz slightly, so the momentary value of a
    // continuous sine at amp=0.5 is about -9.07 (roughly +0.65 dB over the unweighted theoretical -9.72).
    // "K≈0dB → -9.7" is an approximation; the implementation is faithful to the standard design formulas.
    var mono_ext: [EXT_FRAMES]f32 = undefined;
    // 400ms @48k = 19200 samples or more (which fills the momentary window)
    var sine: [24000]f32 = undefined;
    fillSine(&sine, 0.5, 997, 48000);
    const ext = analyzeAudioExt(&sine, 1, 48000, &mono_ext);
    try testing.expectApproxEqAbs(@as(f32, -9.1), ext.lufs, 0.5);
}

test "analyzeAudioExt: silence then 3 bursts gives onsets=3" {
    var mono_ext: [EXT_FRAMES]f32 = undefined;
    const sr: usize = 48000;
    const burst_n = sr * 50 / 1000; // 50ms
    const gap_n = sr * 150 / 1000; // 150ms
    // leading silence + 3 bursts + 2 gaps + trailing silence (which avoids a plateau at the end)
    const total = 4096 + 3 * burst_n + 2 * gap_n + 4096;
    var buf: [32768]f32 = undefined;
    try testing.expect(total <= buf.len);
    @memset(buf[0..total], 0);
    var pos: usize = 4096; // leading silence
    var b: usize = 0;
    while (b < 3) : (b += 1) {
        // A deterministic burst close to broadband (LCG noise). A pure sine splits the flux by phase and easily misses the threshold.
        var rng: u32 = 0xA341316C +% @as(u32, @intCast(b)) *% 0x9E3779B9;
        var j: usize = 0;
        while (j < burst_n) : (j += 1) {
            rng = rng *% 1664525 +% 1013904223;
            const u = @as(f32, @floatFromInt(rng >> 8)) * (1.0 / 16777216.0); // [0,1)
            buf[pos + j] = (u * 2.0 - 1.0) * 0.8;
        }
        pos += burst_n;
        if (b + 1 < 3) pos += gap_n;
    }
    const ext = analyzeAudioExt(buf[0..total], 1, 48000, &mono_ext);
    try testing.expectEqual(@as(u32, 3), ext.onsets);
}

test "analyzeAudioExt: silence gives 0 for the new keys and lufs=-99.0" {
    var mono_ext: [EXT_FRAMES]f32 = undefined;
    var sil = [_]f32{0} ** 4096;
    const ext = analyzeAudioExt(&sil, 1, 48000, &mono_ext);
    try testing.expectEqual(@as(f32, 0), ext.band_low);
    try testing.expectEqual(@as(f32, 0), ext.band_mid);
    try testing.expectEqual(@as(f32, 0), ext.band_high);
    try testing.expectEqual(@as(f32, 0), ext.centroid);
    try testing.expectEqual(@as(u32, 0), ext.onsets);
    try testing.expectEqual(@as(f32, LUFS_FLOOR), ext.lufs);
}

test "analyzeAudioExt: sample_rate=0 and channels=0 are guarded to the floor" {
    var mono_ext: [EXT_FRAMES]f32 = undefined;
    var sine: [256]f32 = undefined;
    fillSine(&sine, 0.5, 440, 48000);
    const e0 = analyzeAudioExt(&sine, 1, 0, &mono_ext);
    try testing.expectEqual(@as(f32, LUFS_FLOOR), e0.lufs);
    try testing.expectEqual(@as(f32, 0), e0.band_mid);
    const e1 = analyzeAudioExt(&sine, 0, 48000, &mono_ext);
    try testing.expectEqual(@as(f32, LUFS_FLOOR), e1.lufs);
}

test "formatAudioPayload: the prefix of existing keys is bit-identical to before, the new keys are present, and it stays within 1024B" {
    resetForTest();
    mode = .replay;
    audio_head = .init(0);
    audio_channels = .init(0);
    audio_rate = .init(0);

    // An empty buffer: the silent branch. The part with the existing keys stays bit-identical to before, and the new keys follow.
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const empty = formatAudioPayload(&buf);
    try testing.expect(std.mem.startsWith(u8, empty, "rms=0.0000 peak=0.0000 f0=0.0 silent=1 frames=0"));
    try testing.expect(std.mem.indexOf(u8, empty, "band_low=0.0000") != null);
    try testing.expect(std.mem.indexOf(u8, empty, "band_mid=0.0000") != null);
    try testing.expect(std.mem.indexOf(u8, empty, "band_high=0.0000") != null);
    try testing.expect(std.mem.indexOf(u8, empty, "centroid=0") != null);
    try testing.expect(std.mem.indexOf(u8, empty, "onsets=0") != null);
    try testing.expect(std.mem.indexOf(u8, empty, "lufs=-99.0") != null);
    try testing.expect(empty.len < DIGEST_BUF_LEN);

    // Push a 440Hz sine through the ring: the prefix of existing keys is bit-identical to analyzeAudio's and the new keys are additive.
    var sine: [4800]f32 = undefined;
    fillSine(&sine, 0.5, 440, 48000);
    onAudioSamples(&sine, 4800, 1, 48000);
    const payload = formatAudioPayload(&buf);
    try testing.expect(std.mem.indexOf(u8, payload, "silent=0") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "band_mid=") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "centroid=") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "onsets=") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "lufs=") != null);
    try testing.expect(payload.len < DIGEST_BUF_LEN);

    // Compare only the part with the existing keys, bit for bit, against analyzeAudio's format (the prefix with the new keys removed = zero regression)
    var mono: [ANALYZE_FRAMES]f32 = undefined;
    // Build the legacy form over the same recent window as formatAudioPayload's (the whole sine put into the ring)
    const st = analyzeAudio(&sine, 1, 48000, &mono);
    var legacy: [128]u8 = undefined;
    const legacy_s = try std.fmt.bufPrint(&legacy, "rms={d:.4} peak={d:.4} f0={d:.1} silent={d} frames={d}", .{
        st.rms, st.peak, st.f0, @intFromBool(st.silent), st.frames,
    });
    try testing.expect(std.mem.startsWith(u8, payload, legacy_s));
}

test "encodeWav: the byte offsets of the PCM16 RIFF/WAVE header, asserted against absolute values" {
    const interleaved = [_]f32{ 0, 0, 0, 0 }; // 4 samples, 2ch → 2 frames
    const bytes = try encodeWav(&interleaved, 2, 48000, testing.allocator);
    defer testing.allocator.free(bytes);

    try testing.expectEqual(@as(usize, 44 + 8), bytes.len);
    try testing.expectEqualStrings("RIFF", bytes[0..4]);
    try testing.expectEqual(@as(u32, 36 + 8), std.mem.readInt(u32, bytes[4..8], .little));
    try testing.expectEqualStrings("WAVE", bytes[8..12]);
    try testing.expectEqualStrings("fmt ", bytes[12..16]);
    try testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, bytes[16..20], .little));
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, bytes[20..22], .little)); // PCM
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, bytes[22..24], .little)); // channels
    try testing.expectEqual(@as(u32, 48000), std.mem.readInt(u32, bytes[24..28], .little)); // sample_rate
    try testing.expectEqual(@as(u32, 48000 * 2 * 2), std.mem.readInt(u32, bytes[28..32], .little)); // byte_rate
    try testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, bytes[32..34], .little)); // block_align
    try testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, bytes[34..36], .little)); // bits
    try testing.expectEqualStrings("data", bytes[36..40]);
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, bytes[40..44], .little)); // data_size
}

test "the stats payload: one line of JSON (frame, virtual_fps, EventStats, modal_blocked_injections)" {
    resetForTest();
    frame_index = 12;
    last_stats = .{ .mouse_move_merge_count = 3, .mouse_scroll_merge_count = 1, .event_drop_count = 0 };
    modal_blocked_injections = 2;
    var buf: [512]u8 = undefined;
    const json = formatStatsPayload(&buf);
    try testing.expectEqualStrings(
        "{\"frame\":12,\"virtual_fps\":60.0,\"mouse_move_merge_count\":3,\"mouse_scroll_merge_count\":1,\"event_drop_count\":0,\"modal_blocked_injections\":2}",
        json,
    );
}

const TestBlockerCtx = struct { label: ?[]const u8 = null, calls: usize = 0 };
fn testInputBlocker(ctx: *anyopaque, event: Event) ?[]const u8 {
    _ = event;
    const c: *TestBlockerCtx = @ptrCast(@alignCast(ctx));
    c.calls += 1;
    return c.label;
}

test "input_blocker: non-null label warns once per stretch and increments modal_blocked_injections" {
    resetForTest();
    var c = TestBlockerCtx{ .label = "recovery" };
    registerProbe(.{ .name = "appshell", .ctx = &c, .digest = testProbeDigest, .input_blocker = testInputBlocker });

    // Capture stderr is impractical here; assert the counter and rate-limit state instead.
    const move = Event{ .mouse_move = .{ .x = 1, .y = 2, .button = .none, .buttons = .{}, .modifiers = .{} } };
    queue(move);
    queue(.{ .mouse_move = .{ .x = 3, .y = 4, .button = .none, .buttons = .{}, .modifiers = .{} } });
    _ = nextInjectedEvent();
    try testing.expectEqual(@as(u64, 1), modal_blocked_injections);
    try testing.expectEqualStrings("recovery", last_blocker_warn_label.?);
    _ = nextInjectedEvent();
    try testing.expectEqual(@as(u64, 2), modal_blocked_injections);
    try testing.expectEqualStrings("recovery", last_blocker_warn_label.?); // same label: no second warn state change
    try testing.expectEqual(@as(usize, 0), expect_failures);

    // null resets the rate-limit key
    c.label = null;
    queue(.{ .mouse_move = .{ .x = 5, .y = 6, .button = .none, .buttons = .{}, .modifiers = .{} } });
    _ = nextInjectedEvent();
    try testing.expectEqual(@as(u64, 2), modal_blocked_injections); // not blocked
    try testing.expect(last_blocker_warn_label == null);

    // a later non-null label warns again
    c.label = "confirmation";
    queue(.{ .mouse_move = .{ .x = 7, .y = 8, .button = .none, .buttons = .{}, .modifiers = .{} } });
    _ = nextInjectedEvent();
    try testing.expectEqual(@as(u64, 3), modal_blocked_injections);
    try testing.expectEqualStrings("confirmation", last_blocker_warn_label.?);
    try testing.expectEqual(@as(usize, 0), expect_failures);
    probe_count = 0;
}

test "input_blocker: null return does not warn or increment" {
    resetForTest();
    var c = TestBlockerCtx{ .label = null };
    registerProbe(.{ .name = "appshell", .ctx = &c, .digest = testProbeDigest, .input_blocker = testInputBlocker });
    queue(.{ .key_down = .{ .key = .A, .is_repeat = false, .modifiers = .{} } });
    _ = nextInjectedEvent();
    try testing.expectEqual(@as(u64, 0), modal_blocked_injections);
    try testing.expect(last_blocker_warn_label == null);
    try testing.expectEqual(@as(usize, 1), c.calls);
    probe_count = 0;
}

test "input_blocker: size and text_edit labels rate-limit independently" {
    resetForTest();
    var c = TestBlockerCtx{ .label = "size" };
    registerProbe(.{ .name = "appshell", .ctx = &c, .digest = testProbeDigest, .input_blocker = testInputBlocker });

    queue(.{ .key_down = .{ .key = .ENTER, .is_repeat = false, .modifiers = .{} } });
    queue(.{ .key_down = .{ .key = .ESCAPE, .is_repeat = false, .modifiers = .{} } });
    _ = nextInjectedEvent();
    try testing.expectEqual(@as(u64, 1), modal_blocked_injections);
    try testing.expectEqualStrings("size", last_blocker_warn_label.?);
    _ = nextInjectedEvent();
    try testing.expectEqual(@as(u64, 2), modal_blocked_injections);
    try testing.expectEqualStrings("size", last_blocker_warn_label.?);

    c.label = null;
    queue(.{ .mouse_move = .{ .x = 1, .y = 1, .button = .none, .buttons = .{}, .modifiers = .{} } });
    _ = nextInjectedEvent();
    try testing.expect(last_blocker_warn_label == null);

    c.label = "text_edit";
    queue(.{ .char_input = .{ .codepoint = 'a', .modifiers = .{} } });
    queue(.{ .key_down = .{ .key = .A, .is_repeat = false, .modifiers = .{} } });
    _ = nextInjectedEvent();
    try testing.expectEqual(@as(u64, 3), modal_blocked_injections);
    try testing.expectEqualStrings("text_edit", last_blocker_warn_label.?);
    _ = nextInjectedEvent();
    try testing.expectEqual(@as(u64, 4), modal_blocked_injections);
    try testing.expectEqualStrings("text_edit", last_blocker_warn_label.?);
    try testing.expectEqual(@as(usize, 0), expect_failures);
    probe_count = 0;
}

test "input_blocker: capabilities JSON form is unchanged when a blocker is registered" {
    resetForTest();
    var c = TestBlockerCtx{ .label = "recovery" };
    registerProbe(.{ .name = "appshell", .ctx = &c, .ext = "txt", .desc = "d", .digest = testProbeDigest, .input_blocker = testInputBlocker });
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    _ = &buf;
    const json = formatCapabilitiesPayload(&capabilities_buf);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"appshell\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "input_blocker") == null);
    probe_count = 0;
}

const TestProbeCtx = struct { value: u32 };
fn testProbeDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const c: *TestProbeCtx = @ptrCast(@alignCast(ctx));
    return std.fmt.bufPrint(buf, "value={d}", .{c.value}) catch buf[0..0];
}

test "a custom probe: register plus digest routing (generic, unparsed by the framework, live framing)" {
    resetForTest(); // mode=.replay (anything but disabled → registration is enabled)
    var c = TestProbeCtx{ .value = 42 };
    registerProbe(.{ .name = "test", .ctx = &c, .ext = "bin", .digest = testProbeDigest });
    try testing.expectEqual(@as(usize, 1), probe_count);

    // live framing: no prefix, "test value=42" followed by a newline
    mode = .live;
    resp_buf.clearRetainingCapacity();
    defer resp_buf.clearRetainingCapacity();
    var it = std.mem.tokenizeAny(u8, "test", " \t");
    handleDigest(&it);
    try testing.expectEqualStrings("test value=42\n", resp_buf.items);
    probe_count = 0;
}

test "a custom probe: while disabled registerProbe is a no-op (zero regression)" {
    resetForTest();
    mode = .disabled;
    probe_count = 0;
    var c = TestProbeCtx{ .value = 1 };
    registerProbe(.{ .name = "x", .ctx = &c, .digest = testProbeDigest });
    try testing.expectEqual(@as(usize, 0), probe_count);
}

test "a custom probe: the same name overwrites, a reserved name is rejected, and a full registry is skipped" {
    resetForTest();
    probe_count = 0;
    var c1 = TestProbeCtx{ .value = 1 };
    var c2 = TestProbeCtx{ .value = 2 };
    registerProbe(.{ .name = "p", .ctx = &c1, .digest = testProbeDigest });
    registerProbe(.{ .name = "p", .ctx = &c2, .digest = testProbeDigest }); // the same name overwrites
    try testing.expectEqual(@as(usize, 1), probe_count);
    const got: *TestProbeCtx = @ptrCast(@alignCast(findProbe("p").?.ctx));
    try testing.expectEqual(@as(u32, 2), got.value);

    // a reserved name is not registered
    registerProbe(.{ .name = "fb", .ctx = &c1, .digest = testProbeDigest });
    registerProbe(.{ .name = "audio", .ctx = &c1, .digest = testProbeDigest });
    registerProbe(.{ .name = "stats", .ctx = &c1, .digest = testProbeDigest });
    registerProbe(.{ .name = "capture", .ctx = &c1, .digest = testProbeDigest }); // the reserved name added for the synthetic capture source
    registerProbe(.{ .name = "gamepad", .ctx = &c1, .digest = testProbeDigest }); // the reserved name added for the gamepad probe
    try testing.expectEqual(@as(usize, 1), probe_count);

    // Pack it full (up to MAX_PROBES) and the excess is skipped (filling with the existing "p" plus new unique names)
    const names = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "q", "r" };
    for (names) |nm| registerProbe(.{ .name = nm, .ctx = &c1, .digest = testProbeDigest });
    try testing.expectEqual(@as(usize, MAX_PROBES), probe_count); // it tops out at 16 (the 17th and beyond are skipped)
    probe_count = 0;
}

test "live framing: a digest and a snapshot go onto the response buffer without a prefix" {
    resetForTest();
    mode = .live;
    resp_buf.clearRetainingCapacity();
    defer resp_buf.clearRetainingCapacity();
    // emit an fb digest live
    var px = [_]u32{0xFF010203};
    frame_pixels = px[0..];
    frame_w = 1;
    frame_h = 1;
    have_frame = true;
    var buf: [256]u8 = undefined;
    emitDigest("fb", formatFbPayload(&buf));
    emitSnapshot("audio", "/tmp/a.wav", "10 samples");
    // the response is "fb ..." then "/tmp/a.wav", each followed by a newline
    try testing.expect(std.mem.startsWith(u8, resp_buf.items, "fb 1x1 crc="));
    try testing.expect(std.mem.endsWith(u8, resp_buf.items, "/tmp/a.wav\n"));
    try testing.expect(std.mem.indexOf(u8, resp_buf.items, "[harness]") == null);
    frame_pixels = &.{};
}

// ============================================================================
// expect and assert (the assertion layer) tests
// ============================================================================

test "parseExpectExpr: the valid cases (the four comparison operators, contains, the digest alias, and a negative fraction)" {
    {
        var it = std.mem.tokenizeAny(u8, "fb crc=ABCD1234", " \t");
        const e = parseExpectExpr(&it).?;
        try testing.expectEqualStrings("fb", e.probe);
        try testing.expect(e.form == .cmp);
        try testing.expectEqual(CmpOp.eq, e.form.cmp.op);
        try testing.expectEqualStrings("crc", e.form.cmp.key);
        try testing.expectEqualStrings("ABCD1234", e.form.cmp.value);
    }
    {
        var it = std.mem.tokenizeAny(u8, "audio silent!=1", " \t");
        const e = parseExpectExpr(&it).?;
        try testing.expectEqual(CmpOp.ne, e.form.cmp.op);
        try testing.expectEqualStrings("silent", e.form.cmp.key);
        try testing.expectEqualStrings("1", e.form.cmp.value);
    }
    {
        var it = std.mem.tokenizeAny(u8, "canvas nz>0", " \t");
        const e = parseExpectExpr(&it).?;
        try testing.expectEqual(CmpOp.gt, e.form.cmp.op);
        try testing.expectEqualStrings("nz", e.form.cmp.key);
    }
    {
        var it = std.mem.tokenizeAny(u8, "audio f0<500", " \t");
        const e = parseExpectExpr(&it).?;
        try testing.expectEqual(CmpOp.lt, e.form.cmp.op);
    }
    {
        // a negative and a fractional value (everything after the op is the value)
        var it = std.mem.tokenizeAny(u8, "audio rms>-0.5", " \t");
        const e = parseExpectExpr(&it).?;
        try testing.expectEqualStrings("rms", e.form.cmp.key);
        try testing.expectEqualStrings("-0.5", e.form.cmp.value);
    }
    {
        // the `expect digest fb ...` alias (the second token, digest, is skipped)
        var it = std.mem.tokenizeAny(u8, "digest fb crc=ABCD", " \t");
        const e = parseExpectExpr(&it).?;
        try testing.expectEqualStrings("fb", e.probe);
        try testing.expectEqualStrings("ABCD", e.form.cmp.value);
    }
    {
        var it = std.mem.tokenizeAny(u8, "fb contains #FF0000", " \t");
        const e = parseExpectExpr(&it).?;
        try testing.expect(e.form == .contains);
        try testing.expectEqualStrings("#FF0000", e.form.contains);
    }
}

test "parseExpectExpr: the invalid cases give null (failing fast on a missing op, an empty value, a surplus token, or a bare !)" {
    const bad = [_][]const u8{
        "fb crcABCD", // no op symbol
        "fb", // no expression
        "", // no probe
        "fb =5", // an empty key
        "fb crc=", // an empty value
        "fb crc!5", // a bare `!` (with no `=` following)
        "fb crc=A extra", // a surplus token
        "fb contains", // a missing substr
        "fb contains a b", // a surplus substr
        "digest", // no probe after the alias
        "digest fb", // only a probe after the alias, with no expression
    };
    for (bad) |s| {
        var it = std.mem.tokenizeAny(u8, s, " \t");
        try testing.expect(parseExpectExpr(&it) == null);
    }
}

test "findKeyValue: extracting at the top level, preventing a prefix collision, and not extracting from nesting or JSON" {
    const audio = "rms=0.5000 peak=0.7000 f0=440.0 silent=0 frames=4096";
    try testing.expectEqualStrings("0.5000", findKeyValue(audio, "rms").?);
    try testing.expectEqualStrings("440.0", findKeyValue(audio, "f0").?);
    try testing.expectEqualStrings("4096", findKeyValue(audio, "frames").?);
    try testing.expectEqualStrings("0", findKeyValue(audio, "silent").?);
    // a prefix collision: "f" does not wrongly match f0= or frames= (thanks to requiring tok[key.len]=='=')
    try testing.expect(findKeyValue(audio, "f") == null);
    try testing.expect(findKeyValue(audio, "nope") == null);

    // nesting (canvas-like): the top-level layers and comp are picked up, and the inner crc and nz do not leak
    const canvas = "32x32 layers=2 selected=0 comp=DEADBEEF l0{v=1,op=1.00,crc=CAFEBABE,nz=42}";
    try testing.expectEqualStrings("2", findKeyValue(canvas, "layers").?);
    try testing.expectEqualStrings("DEADBEEF", findKeyValue(canvas, "comp").?);
    try testing.expect(findKeyValue(canvas, "nz") == null); // a nested key does not leak
    try testing.expect(findKeyValue(canvas, "crc") == null); // the inner crc is distinct from the top-level comp

    // JSON (stats-like): it is not in `key=` form so it is not picked up → the intent is to use contains
    const json = "{\"frame\":123,\"virtual_fps\":60.0}";
    try testing.expect(findKeyValue(json, "frame") == null);
}

test "compareValues: switching between numeric, string and ordering comparison" {
    // numeric = (0.5 ≒ 0.5000)
    try testing.expect(compareValues("0.5000", .eq, "0.5"));
    try testing.expect(!compareValues("0.5000", .eq, "0.6"));
    // string = (a crc hex is non-numeric → an exact match)
    try testing.expect(compareValues("ABCD1234", .eq, "ABCD1234"));
    try testing.expect(!compareValues("ABCD1234", .eq, "ABCD9999"));
    // !=
    try testing.expect(compareValues("ABCD", .ne, "DCBA"));
    try testing.expect(!compareValues("5", .ne, "5.0")); // numerically equal → so != is false
    // > and < (both sides must be numeric)
    try testing.expect(compareValues("4096", .gt, "4000"));
    try testing.expect(!compareValues("4096", .gt, "5000"));
    try testing.expect(compareValues("440.0", .lt, "500"));
    // > and < fail on a non-numeric value (both sides must be f64)
    try testing.expect(!compareValues("ABCD", .gt, "0"));
    try testing.expect(!compareValues("5", .lt, "xyz"));
}

test "evalExpect: a comparison, contains, and a missing key" {
    const audio = "rms=0.5000 peak=0.7000 f0=440.0 silent=0 frames=4096";
    try testing.expect(evalExpect(audio, .{ .probe = "audio", .form = .{ .cmp = .{ .op = .eq, .key = "silent", .value = "0" } } }));
    try testing.expect(evalExpect(audio, .{ .probe = "audio", .form = .{ .cmp = .{ .op = .gt, .key = "rms", .value = "0" } } }));
    try testing.expect(!evalExpect(audio, .{ .probe = "audio", .form = .{ .cmp = .{ .op = .gt, .key = "nope", .value = "0" } } })); // a missing key = a fail
    try testing.expect(evalExpect(audio, .{ .probe = "audio", .form = .{ .contains = "f0=440.0" } }));
    try testing.expect(!evalExpect(audio, .{ .probe = "audio", .form = .{ .contains = "nonexistent" } }));
}

test "expect under replay: expect_failures holds on success, and rises by one on a failure and on an unknown probe (avoiding the exit by never reaching EOF)" {
    resetForTest(); // mode=.replay
    // Prepare a known fb frame (2x2) to settle the crc
    var px = [_]u32{ 0xFF000000, 0xFF000000, 0xFF000000, 0xFF0000FF };
    frame_pixels = px[0..];
    frame_w = 2;
    frame_h = 2;
    have_frame = true;
    defer frame_pixels = &.{};
    const crc = png.crc32(std.mem.sliceAsBytes(px[0..4]));

    var sbuf: [256]u8 = undefined;
    // A correct crc (pass) → step / a wrong crc (fail) → step / an unknown probe (fail) → step.
    // **Do not let it reach EOF or quit** (stop at step, and do not call pollGate at the end), which avoids replayExitIfFailed's exit.
    cmd_buf = std.fmt.bufPrint(&sbuf, "expect fb crc={X:0>8}\nstep 1\nexpect fb crc=00000000\nstep 1\nexpect nosuch x=1\nstep 1\n", .{crc}) catch unreachable;
    cursor = 0;

    try testing.expect(pollGate(true)); // frame1: the correct crc (pass) → step
    try testing.expectEqual(@as(usize, 0), expect_failures);
    try testing.expect(pollGate(true)); // frame2: a wrong crc (fail) → step
    try testing.expectEqual(@as(usize, 1), expect_failures);
    try testing.expect(pollGate(true)); // frame3: an unknown probe (fail) → step
    try testing.expectEqual(@as(usize, 2), expect_failures);
    // Calling pollGate again here would hit EOF and exit(1) through replayExitIfFailed, so **it is not called**.
    expect_failures = 0; // Preventing a leak into the next test (explicitly; resetForTest follows as well)
}

test "expect under live: the ok and fail lines go onto resp_buf, live records nothing, and assert does not exit either" {
    resetForTest();
    mode = .live;
    resp_buf.clearRetainingCapacity();
    defer resp_buf.clearRetainingCapacity();
    var px = [_]u32{0xFF010203};
    frame_pixels = px[0..];
    frame_w = 1;
    frame_h = 1;
    have_frame = true;
    defer frame_pixels = &.{};
    const crc = png.crc32(std.mem.sliceAsBytes(px[0..1]));

    // pass → "ok fb crc=..."
    var lbuf: [64]u8 = undefined;
    {
        const line = std.fmt.bufPrint(&lbuf, "fb crc={X:0>8}", .{crc}) catch unreachable;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        handleExpect(&it, false);
    }
    try testing.expect(std.mem.startsWith(u8, resp_buf.items, "ok fb crc="));
    resp_buf.clearRetainingCapacity();

    // a fail (with actual= attached). Being live, expect_failures does not rise
    {
        var it = std.mem.tokenizeAny(u8, "fb crc=00000000", " \t");
        handleExpect(&it, false);
    }
    try testing.expect(std.mem.startsWith(u8, resp_buf.items, "fail fb crc=00000000 actual="));
    try testing.expectEqual(@as(usize, 0), expect_failures);
    resp_buf.clearRetainingCapacity();

    // assert with an unknown probe does not exit under live either, and gives only a fail line plus the reason
    {
        var it = std.mem.tokenizeAny(u8, "nosuch x=1", " \t");
        handleExpect(&it, true);
    }
    try testing.expect(std.mem.startsWith(u8, resp_buf.items, "fail nosuch x=1 actual=unknown probe"));
    try testing.expectEqual(@as(usize, 0), expect_failures);
}

// ============================================================================
// action (the high-level operation symmetrical with a probe) tests
// ============================================================================

const TestActionCtx = struct {
    calls: usize = 0,
    args_buf: [256]u8 = undefined,
    args_len: usize = 0,

    fn lastArgs(self: *const TestActionCtx) []const u8 {
        return self.args_buf[0..self.args_len];
    }
};

fn testActionRun(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const c: *TestActionCtx = @ptrCast(@alignCast(ctx));
    c.calls += 1;
    @memcpy(c.args_buf[0..args.len], args);
    c.args_len = args.len;
    return std.fmt.bufPrint(buf, "ok:{s}", .{args}) catch buf[0..0];
}

fn testActionErr(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = ctx;
    _ = args;
    _ = buf;
    return error.Boom;
}

test "firstLine: cuts at the first CR or LF (returning the whole thing when there is none, defending against a callback returning several lines)" {
    try testing.expectEqualStrings("abc", firstLine("abc\ndef"));
    try testing.expectEqualStrings("abc", firstLine("abc\r\ndef"));
    try testing.expectEqualStrings("abc", firstLine("abc"));
    try testing.expectEqualStrings("", firstLine("\nabc"));
}

test "registerAction: a no-op while disabled (zero regression)" {
    resetForTest();
    mode = .disabled;
    action_registry.resetForTest(); // enabled=false (harness.resetForTest calls setEnabled as the tests' default)
    var c = TestActionCtx{};
    registerAction(.{ .name = "x", .ctx = &c, .run = testActionRun });
    try testing.expectEqual(@as(usize, 0), action_registry.actionCount());
}

test "registerAction: the same name overwrites, an invalid name (empty, whitespace, ;, a newline) is rejected, and a full registry is skipped" {
    resetForTest();
    var c1 = TestActionCtx{};
    var c2 = TestActionCtx{};
    registerAction(.{ .name = "a", .ctx = &c1, .run = testActionRun });
    registerAction(.{ .name = "a", .ctx = &c2, .run = testActionRun }); // the same name overwrites
    try testing.expectEqual(@as(usize, 1), action_registry.actionCount());
    try testing.expectEqual(@as(*anyopaque, &c2), findAction("a").?.ctx);

    registerAction(.{ .name = "", .ctx = &c1, .run = testActionRun }); // an empty name
    registerAction(.{ .name = "b c", .ctx = &c1, .run = testActionRun }); // whitespace mixed in
    registerAction(.{ .name = "b;c", .ctx = &c1, .run = testActionRun }); // a `;` mixed in
    registerAction(.{ .name = "b\nc", .ctx = &c1, .run = testActionRun }); // a newline mixed in
    try testing.expectEqual(@as(usize, 1), action_registry.actionCount()); // all are rejected and the count does not rise

    // a full registry is skipped: registering "a" plus MAX_ACTIONS or more still tops out at MAX_ACTIONS (=48)
    var name_bufs: [action_registry.MAX_ACTIONS + 4][8]u8 = undefined;
    for (&name_bufs, 0..) |*nb, i| {
        const nm = std.fmt.bufPrint(nb, "act{d}", .{i}) catch unreachable;
        registerAction(.{ .name = nm, .ctx = &c1, .run = testActionRun });
    }
    try testing.expectEqual(@as(usize, action_registry.MAX_ACTIONS), action_registry.actionCount());
}

test "action dispatch: raw args pass through (never re-tokenised, keeping consecutive whitespace and a JSON-like payload)" {
    resetForTest();
    var c = TestActionCtx{};
    registerAction(.{ .name = "foo", .ctx = &c, .run = testActionRun });
    defer action_registry.resetForTest();
    cmd_buf =
        \\action foo 1 2  3
        \\step 1
        \\action foo key=val {"a":1,"b":2}
        \\step 1
        \\quit
    ;

    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(usize, 1), c.calls);
    try testing.expectEqualStrings("1 2  3", c.lastArgs()); // consecutive whitespace is not collapsed = it was not re-tokenised

    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(usize, 2), c.calls);
    try testing.expectEqualStrings("key=val {\"a\":1,\"b\":2}", c.lastArgs()); // a JSON-like payload comes through as it stands too

    try testing.expect(!pollGate(true)); // quit
}

test "action: an unknown action, a missing name and an error from run() are recorded (incrementing expect_failures, avoiding the exit by never reaching EOF)" {
    resetForTest();
    var c = TestActionCtx{};
    registerAction(.{ .name = "boom", .ctx = &c, .run = testActionErr });
    defer action_registry.resetForTest();
    cmd_buf =
        \\action nosuch
        \\step 1
        \\action
        \\step 1
        \\action boom
        \\step 1
    ;

    try testing.expect(pollGate(true)); // an unknown action
    try testing.expectEqual(@as(usize, 1), expect_failures);
    try testing.expect(pollGate(true)); // a missing name
    try testing.expectEqual(@as(usize, 2), expect_failures);
    try testing.expect(pollGate(true)); // an error from run() (it does not crash)
    try testing.expectEqual(@as(usize, 3), expect_failures);
    // Calling pollGate again here would hit EOF and exit(1) through replayExitIfFailed, so **it is not called**.
    expect_failures = 0; // preventing a leak into the next test
}

test "action under live: success is a bare `<name> <msg>` and failure is `fail <name> <msg>` (which drive detects), and live records nothing" {
    resetForTest();
    mode = .live;
    resp_buf.clearRetainingCapacity();
    defer resp_buf.clearRetainingCapacity();
    var c = TestActionCtx{};
    registerAction(.{ .name = "foo", .ctx = &c, .run = testActionRun });
    defer action_registry.resetForTest();

    {
        var it = std.mem.tokenizeAny(u8, "foo bar", " \t");
        handleAction(&it);
    }
    try testing.expectEqualStrings("foo ok:bar\n", resp_buf.items);
    resp_buf.clearRetainingCapacity();

    {
        var it = std.mem.tokenizeAny(u8, "nosuch", " \t");
        handleAction(&it);
    }
    try testing.expect(std.mem.startsWith(u8, resp_buf.items, "fail nosuch unknown action"));
    try testing.expectEqual(@as(usize, 0), expect_failures); // live does not record
}

fn testActionErrWithDetail(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = ctx;
    _ = args;
    _ = buf;
    action_registry.setActionErrorDetail("file_not_found", "check path or use save first");
    return error.Boom;
}

fn testActionErrMaybeDetail(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = ctx;
    _ = buf;
    if (std.mem.eql(u8, args, "set")) {
        action_registry.setActionErrorDetail("stale_code", "should not leak to next fail");
    }
    return error.Boom;
}

test "an action's structured error: code= and next= are appended to a live failure line, it is bit-identical to before when unset, and the leading fail never changes" {
    resetForTest();
    mode = .live;
    resp_buf.clearRetainingCapacity();
    defer resp_buf.clearRetainingCapacity();
    var c = TestActionCtx{};
    registerAction(.{ .name = "boom", .ctx = &c, .run = testActionErrWithDetail });
    registerAction(.{ .name = "plain", .ctx = &c, .run = testActionErr });
    defer action_registry.resetForTest();

    {
        var it = std.mem.tokenizeAny(u8, "boom", " \t");
        handleAction(&it);
    }
    // the leading `fail ` never changes → a regression check on `kngn ctl`'s leading-`fail ` scan
    try testing.expect(std.mem.startsWith(u8, resp_buf.items, "fail boom "));
    try testing.expectEqualStrings("fail boom Boom code=file_not_found next=check path or use save first\n", resp_buf.items);
    resp_buf.clearRetainingCapacity();

    // with no detail set it is bit-identical to the old format (no code= or next= at all)
    {
        var it = std.mem.tokenizeAny(u8, "plain", " \t");
        handleAction(&it);
    }
    try testing.expectEqualStrings("fail plain Boom\n", resp_buf.items);
    try testing.expect(std.mem.indexOf(u8, resp_buf.items, "code=") == null);
    try testing.expect(std.mem.indexOf(u8, resp_buf.items, "next=") == null);
    try testing.expectEqual(@as(usize, 0), expect_failures); // live does not record
}

test "an action's structured error: clearing on every dispatch stops the previous detail leaking into the next failure" {
    resetForTest();
    mode = .live;
    resp_buf.clearRetainingCapacity();
    defer resp_buf.clearRetainingCapacity();
    var c = TestActionCtx{};
    registerAction(.{ .name = "maybe", .ctx = &c, .run = testActionErrMaybeDetail });
    defer action_registry.resetForTest();

    {
        var it = std.mem.tokenizeAny(u8, "maybe set", " \t");
        handleAction(&it);
    }
    try testing.expectEqualStrings("fail maybe Boom code=stale_code next=should not leak to next fail\n", resp_buf.items);
    resp_buf.clearRetainingCapacity();

    {
        var it = std.mem.tokenizeAny(u8, "maybe noset", " \t");
        handleAction(&it);
    }
    try testing.expectEqualStrings("fail maybe Boom\n", resp_buf.items);
}

test "an action's structured error: next keeps its whitespace, and sanitising turns a newline into _" {
    resetForTest();
    mode = .live;
    resp_buf.clearRetainingCapacity();
    defer resp_buf.clearRetainingCapacity();
    var c = TestActionCtx{};
    const run = struct {
        fn f(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
            _ = ctx;
            _ = args;
            _ = buf;
            action_registry.setActionErrorDetail("a b\nc", "use add_layer or 0..N-1");
            return error.Bad;
        }
    }.f;
    registerAction(.{ .name = "x", .ctx = &c, .run = run });
    defer action_registry.resetForTest();

    {
        var it = std.mem.tokenizeAny(u8, "x", " \t");
        handleAction(&it);
    }
    try testing.expectEqualStrings("fail x Bad code=a_b_c next=use add_layer or 0..N-1\n", resp_buf.items);
}

test "an action's structured error: the suffix form on both the replay and live wires (empty when unset)" {
    resetForTest();
    var sbuf: [128]u8 = undefined;
    // none set → empty (the grounds for it being bit-identical to before)
    try testing.expectEqualStrings("", actionErrorDetailSuffix(&sbuf));

    action_registry.setActionErrorDetail("file_not_found", "check path or use save first");
    const suf = actionErrorDetailSuffix(&sbuf);
    try testing.expectEqualStrings(" code=file_not_found next=check path or use save first", suf);

    // live: `fail <name> <msg>` + suffix / replay: `[harness] action <name> FAILED <msg>` + suffix
    // (both sinks share the one suffix, which reportAction assembles)
    try testing.expect(std.mem.endsWith(u8, "fail boom Boom code=file_not_found next=check path or use save first", suf));
    try testing.expect(std.mem.endsWith(u8, "[harness] action boom FAILED Boom code=file_not_found next=check path or use save first", suf));
    try testing.expect(std.mem.startsWith(u8, "fail boom Boom", "fail ")); // drive's leading-token scan
}

// ============================================================================
// the capabilities probe (introspective listing of the registered probes and actions) tests
// ============================================================================

fn testProbeSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    _ = ctx;
    return allocator.dupe(u8, "snap");
}

/// Parses the capabilities JSON and returns a `std.json.Parsed(std.json.Value)` (the caller calls `deinit()`).
fn parseCapabilities(payload: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
}

test "capabilities: registration is refused for a reserved name" {
    resetForTest();
    var c = TestProbeCtx{ .value = 1 };
    registerProbe(.{ .name = "capabilities", .ctx = &c, .digest = testProbeDigest });
    try testing.expectEqual(@as(usize, 0), probe_count);
}

test "capabilities: with no custom probe or action, the 7 built-in probes plus actions:[]" {
    resetForTest();
    var buf: [MIN_CAPABILITIES_BUF_LEN]u8 = undefined;
    _ = &buf; // unused (capabilities_buf is used directly)
    const payload = formatCapabilitiesPayload(&capabilities_buf);

    var parsed = try parseCapabilities(payload);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(?std.json.Value, null), root.get("truncated"));
    const probes_arr = root.get("probes").?.array.items;
    try testing.expectEqual(@as(usize, 7), probes_arr.len);
    const expected_names = [_][]const u8{ "fb", "audio", "stats", "capabilities", "capture", "gamepad", "midi" };
    for (probes_arr, 0..) |entry, i| {
        try testing.expectEqualStrings(expected_names[i], entry.object.get("name").?.string);
        try testing.expect(if (i == 6) !entry.object.get("snapshot").?.bool else entry.object.get("snapshot").?.bool);
        try testing.expect(entry.object.get("digest").?.bool);
    }
    try testing.expectEqual(@as(usize, 0), root.get("actions").?.array.items.len);
}

test "capabilities: a custom probe and action appear with their field values, in registration order" {
    resetForTest();
    var c1 = TestProbeCtx{ .value = 1 };
    var c2 = TestProbeCtx{ .value = 2 };
    registerProbe(.{ .name = "p1", .ctx = &c1, .ext = "png", .desc = "d1", .digest = testProbeDigest }); // digest-only
    registerProbe(.{ .name = "p2", .ctx = &c2, .ext = "json", .snapshot = testProbeSnapshot }); // snapshot-only, with desc omitted
    var ac1 = TestActionCtx{};
    var ac2 = TestActionCtx{};
    registerAction(.{ .name = "a1", .ctx = &ac1, .run = testActionRun, .desc = "ad1" });
    registerAction(.{ .name = "a2", .ctx = &ac2, .run = testActionRun }); // desc omitted

    var parsed = try parseCapabilities(formatCapabilitiesPayload(&capabilities_buf));
    defer parsed.deinit();
    const root = parsed.value.object;
    const probes_arr = root.get("probes").?.array.items;
    try testing.expectEqual(@as(usize, 9), probes_arr.len); // the 7 built in plus the 2 custom

    const p1 = probes_arr[7].object;
    try testing.expectEqualStrings("p1", p1.get("name").?.string);
    try testing.expectEqualStrings("png", p1.get("ext").?.string);
    try testing.expectEqualStrings("d1", p1.get("desc").?.string);
    try testing.expect(!p1.get("snapshot").?.bool);
    try testing.expect(p1.get("digest").?.bool);

    const p2 = probes_arr[8].object;
    try testing.expectEqualStrings("p2", p2.get("name").?.string);
    try testing.expectEqualStrings("json", p2.get("ext").?.string);
    try testing.expectEqualStrings("", p2.get("desc").?.string);
    try testing.expect(p2.get("snapshot").?.bool);
    try testing.expect(!p2.get("digest").?.bool);

    const actions_arr = root.get("actions").?.array.items;
    try testing.expectEqual(@as(usize, 2), actions_arr.len);
    try testing.expectEqualStrings("a1", actions_arr[0].object.get("name").?.string);
    try testing.expectEqualStrings("ad1", actions_arr[0].object.get("desc").?.string);
    try testing.expectEqualStrings("a2", actions_arr[1].object.get("name").?.string);
    try testing.expectEqualStrings("", actions_arr[1].object.get("desc").?.string);
}

test "capabilities: a desc breaking the rules (a forbidden character, or over 200 bytes) is emptied at registration" {
    resetForTest();
    var c = TestProbeCtx{ .value = 1 };
    registerProbe(.{ .name = "badp", .ctx = &c, .digest = testProbeDigest, .desc = "bad\"desc" });
    try testing.expectEqual(@as(usize, 0), findProbe("badp").?.desc.len);

    const long_desc = [_]u8{'a'} ** (MAX_DESC_LEN + 1);
    registerProbe(.{ .name = "badp2", .ctx = &c, .digest = testProbeDigest, .desc = &long_desc });
    try testing.expectEqual(@as(usize, 0), findProbe("badp2").?.desc.len);

    var ac = TestActionCtx{};
    registerAction(.{ .name = "bada", .ctx = &ac, .run = testActionRun, .desc = "bad\"desc" });
    try testing.expectEqual(@as(usize, 0), findAction("bada").?.desc.len);
}

test "capabilities: an invalid character in name (a \" or a control character) leaves the entry out and gives truncated=true (the valid entries before it survive)" {
    resetForTest();
    var c1 = TestProbeCtx{ .value = 1 };
    var c2 = TestProbeCtx{ .value = 2 };
    registerProbe(.{ .name = "good1", .ctx = &c1, .digest = testProbeDigest }); // valid (registered first)
    registerProbe(.{ .name = "bad\"name", .ctx = &c2, .digest = testProbeDigest }); // holds a `"`
    try testing.expectEqual(@as(usize, 2), probe_count); // the registration itself does succeed

    var parsed = try parseCapabilities(formatCapabilitiesPayload(&capabilities_buf));
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(root.get("truncated").?.bool);
    const probes_arr = root.get("probes").?.array.items;
    try testing.expectEqual(@as(usize, 8), probes_arr.len); // the 7 built in plus good1 (bad is left out)
    try testing.expectEqualStrings("good1", probes_arr[7].object.get("name").?.string);
}

test "capabilities: a control character in an action name (a NUL, which passes isValidActionName but is invalid in JSON) leaves the entry out and gives truncated" {
    resetForTest();
    var ac = TestActionCtx{};
    registerAction(.{ .name = "bad\x00name", .ctx = &ac, .run = testActionRun });
    try testing.expectEqual(@as(usize, 1), action_registry.actionCount()); // registerAction itself does succeed

    var parsed = try parseCapabilities(formatCapabilitiesPayload(&capabilities_buf));
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(root.get("truncated").?.bool);
    try testing.expectEqual(@as(usize, 0), root.get("actions").?.array.items.len);
}

test "capabilities: an invalid character in ext (a tab) also leaves the entry out and gives truncated=true" {
    resetForTest();
    var c = TestProbeCtx{ .value = 1 };
    registerProbe(.{ .name = "p", .ctx = &c, .ext = "bad\text", .digest = testProbeDigest });

    var parsed = try parseCapabilities(formatCapabilitiesPayload(&capabilities_buf));
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(root.get("truncated").?.bool);
    try testing.expectEqual(@as(usize, 7), root.get("probes").?.array.items.len); // the 7 built in only (p is left out)
}

test "capabilities: even a buf of exactly MIN_CAPABILITIES_BUF_LEN gives valid JSON plus truncated=true, by the fail-safe" {
    resetForTest();
    var small_buf: [MIN_CAPABILITIES_BUF_LEN]u8 = undefined;
    const payload = formatCapabilitiesPayload(&small_buf);

    var parsed = try parseCapabilities(payload);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(root.get("truncated").?.bool);
    try testing.expectEqual(@as(usize, 0), root.get("probes").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), root.get("actions").?.array.items.len);
}

test "capabilities: an exhaustive check of the buf boundaries (always valid JSON, including the boundary where probes fit but `,\"actions\":[` does not)" {
    // A regression test for the real bug the review found (ignoring a failed append of the "actions" section start and
    // producing invalid JSON). Rather than one pinpoint magic number, it sweeps a wide range from MIN_CAPABILITIES_BUF_LEN
    // one byte at a time, pinning that every buf size gives valid JSON.
    resetForTest();
    var big_buf: [MIN_CAPABILITIES_BUF_LEN + 700]u8 = undefined;
    var n: usize = MIN_CAPABILITIES_BUF_LEN;
    while (n <= big_buf.len) : (n += 1) {
        const payload = formatCapabilitiesPayload(big_buf[0..n]);
        var parsed = parseCapabilities(payload) catch |err| {
            std.debug.print("invalid JSON at buf len={d}: {s}\npayload={s}\n", .{ n, @errorName(err), payload });
            return err;
        };
        parsed.deinit();
    }
}

test "capabilities: the same JSON comes back through digestPayload (digest capabilities) too" {
    resetForTest();
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    switch (digestPayload("capabilities", &buf)) {
        .ok => |payload| {
            var parsed = try parseCapabilities(payload);
            defer parsed.deinit();
            try testing.expectEqual(@as(usize, 7), parsed.value.object.get("probes").?.array.items.len);
        },
        .unavailable => try testing.expect(false),
    }
}

test "capabilities: it is handled without exception through pollGate (the digest capabilities command) too" {
    resetForTest();
    cmd_buf = "digest capabilities";
    try testing.expect(!pollGate(true)); // EOF → the replay ends (and does not exit, expect_failures being 0)
}

// ============================================================================
// the null runtime query — the primary buffer is platform_null's. Only the compatibility setter and query live here.
// ============================================================================

test "setHeadlessActive and isHeadlessActive: the platform compatibility query" {
    resetForTest();
    defer resetForTest();
    try testing.expect(!isHeadlessActive());
    setHeadlessActive(true);
    try testing.expect(isHeadlessActive());
    setHeadlessActive(false);
    try testing.expect(!isHeadlessActive());
}

// ============================================================================
// the synthetic capture source tests
// ============================================================================

test "isCaptureSyntheticActive: by default (the environment unset) it is false whether harness is enabled or not" {
    resetForTest(); // mode=.replay
    defer resetForTest();
    try testing.expect(!isCaptureSyntheticActive());
    mode = .disabled;
    try testing.expect(!isCaptureSyntheticActive());
}

test "isCaptureSyntheticActive: true only when it is requested and harness is enabled (replay or live)" {
    resetForTest(); // mode=.replay
    defer resetForTest();
    capture_synthetic_requested = true;
    try testing.expect(isCaptureSyntheticActive());
    mode = .live;
    try testing.expect(isCaptureSyntheticActive());
    mode = .disabled;
    try testing.expect(!isCaptureSyntheticActive()); // false even when requested, if harness is disabled
}

test "the capture command: while synthetic is disabled it fails fast (a warning only, with no state change)" {
    resetForTest();
    defer resetForTest();
    // capture_synthetic_requested stays at its default of false = synthetic is disabled
    cmd_buf = "capture video open 8 8\ncapture audio open\nquit";
    while (pollGate(true)) {}
    try testing.expect(synth_video == null);
    try testing.expect(synth_audio == null);
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    try testing.expectEqualStrings("video_open=0 video_w=0 video_h=0 video_frame=0 audio_open=0 audio_frames=0 audio_peak=0.0000", formatCapturePayload(&buf));
}

test "capture video: video_frame follows harness's virtual clock (frame_index), advancing on a present" {
    resetForTest();
    defer resetForTest();
    capture_synthetic_requested = true;
    cmd_buf = "capture video open 8 8 24\nquit";
    while (pollGate(true)) {}
    try testing.expect(synth_video != null);

    // The contract is that frame_index advances on the application's onPresent() call, not on the `step` command itself
    // (see the virtual clock section). Here, with no application, three frames are presented directly and the virtual clock is
    // confirmed to have advanced, along with the `capture` probe's `video_frame` following it.
    const px = [_]u32{0xFF000000};
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        onLock(&px, 1, 1);
        onPresent();
    }
    try testing.expectEqual(@as(u64, 3), frame_index);

    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    try testing.expectEqualStrings("video_open=1 video_w=8 video_h=8 video_frame=3 audio_open=0 audio_frames=0 audio_peak=0.0000", formatCapturePayload(&buf));

    if (synth_video) |*dev| dev.close();
    synth_video = null;
}

test "capture video open: the state is reflected in the digest (before the close)" {
    resetForTest();
    defer resetForTest();
    capture_synthetic_requested = true;
    cmd_buf = "capture video open 16 8\nquit";
    while (pollGate(true)) {}
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    try testing.expectEqualStrings("video_open=1 video_w=16 video_h=8 video_frame=0 audio_open=0 audio_frames=0 audio_peak=0.0000", formatCapturePayload(&buf));
}

test "capture video open: width or height of 0 gives ConfigFailed and leaves synth_video null" {
    resetForTest();
    defer resetForTest();
    capture_synthetic_requested = true;
    cmd_buf = "capture video open 0 8\nquit";
    while (pollGate(true)) {}
    try testing.expect(synth_video == null);
}

test "capture video open: a second open closes the previous device before reopening (with no leak)" {
    resetForTest();
    defer resetForTest();
    capture_synthetic_requested = true;
    cmd_buf = "capture video open 8 8\ncapture video open 4 4\nquit";
    while (pollGate(true)) {}
    try testing.expect(synth_video != null);
    try testing.expectEqual(@as(u32, 4), synth_video.?.width);
}

test "capture video: a snapshot is skipped while video is not open (the same thinking as skipping fb before a present)" {
    resetForTest();
    defer resetForTest();
    capture_synthetic_requested = true;
    cmd_buf = "snapshot capture /tmp/should_not_write_capture.png\nquit";
    while (pollGate(true)) {}
    try testing.expect(synth_video == null);
}

test "capture audio: an open then a close resets the probe state (the real-time check lives in capture_synthetic.zig's own unit test)" {
    resetForTest();
    defer resetForTest();
    capture_synthetic_requested = true;
    cmd_buf = "capture audio open 48000 1 440\nquit";
    while (pollGate(true)) {}
    try testing.expect(synth_audio != null);
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const payload = formatCapturePayload(&buf);
    try testing.expect(std.mem.indexOf(u8, payload, "audio_open=1") != null);

    resetForTest(); // Confirm that the cleanup (stop, join, close) finishes safely
    try testing.expect(synth_audio == null);
}

test "capabilities: the capture probe is in the built-in list" {
    resetForTest();
    var parsed = try parseCapabilities(formatCapabilitiesPayload(&capabilities_buf));
    defer parsed.deinit();
    const probes_arr = parsed.value.object.get("probes").?.array.items;
    var found = false;
    for (probes_arr) |entry| {
        if (std.mem.eql(u8, entry.object.get("name").?.string, "capture")) {
            found = true;
            try testing.expectEqualStrings("png", entry.object.get("ext").?.string);
            try testing.expect(entry.object.get("snapshot").?.bool);
            try testing.expect(entry.object.get("digest").?.bool);
        }
    }
    try testing.expect(found);
}

test "capabilities: the gamepad probe is in the built-in list" {
    resetForTest();
    var parsed = try parseCapabilities(formatCapabilitiesPayload(&capabilities_buf));
    defer parsed.deinit();
    const probes_arr = parsed.value.object.get("probes").?.array.items;
    var found = false;
    for (probes_arr) |entry| {
        if (std.mem.eql(u8, entry.object.get("name").?.string, "gamepad")) {
            found = true;
            try testing.expectEqualStrings("txt", entry.object.get("ext").?.string);
            try testing.expect(entry.object.get("snapshot").?.bool);
            try testing.expect(entry.object.get("digest").?.bool);
        }
    }
    try testing.expect(found);
}

test "capabilities: the midi probe is digest-only and is in the built-in list" {
    resetForTest();
    var parsed = try parseCapabilities(formatCapabilitiesPayload(&capabilities_buf));
    defer parsed.deinit();
    const probes_arr = parsed.value.object.get("probes").?.array.items;
    var found = false;
    for (probes_arr) |entry| {
        if (std.mem.eql(u8, entry.object.get("name").?.string, "midi")) {
            found = true;
            try testing.expectEqualStrings("txt", entry.object.get("ext").?.string);
            try testing.expect(!entry.object.get("snapshot").?.bool);
            try testing.expect(entry.object.get("digest").?.bool);
        }
    }
    try testing.expect(found);
}

// ============================================================================
// the capabilities args signature tests
// ============================================================================

test "capabilities: an action or probe with args=null gives JSON matching the old form string for string (with no args field)" {
    resetForTest();
    var c = TestProbeCtx{ .value = 1 };
    var ac = TestActionCtx{};
    // registered with .args omitted (= null)
    registerProbe(.{ .name = "pnull", .ctx = &c, .ext = "txt", .desc = "pd", .digest = testProbeDigest });
    registerAction(.{ .name = "anull", .ctx = &ac, .run = testActionRun, .desc = "ad" });

    var saved: [capabilities_buf.len]u8 = undefined;
    const payload0 = formatCapabilitiesPayload(&capabilities_buf);
    @memcpy(saved[0..payload0.len], payload0);
    const payload = saved[0..payload0.len];
    // the "args" key does not appear at all, even at the string level (zero regression for the field-addition-only policy)
    try testing.expect(std.mem.indexOf(u8, payload, "\"args\"") == null);

    // the entry shape is name and desc as before (plus ext, snapshot and digest for a probe)
    var parsed = try parseCapabilities(payload);
    defer parsed.deinit();
    const probes_arr = parsed.value.object.get("probes").?.array.items;
    const p = probes_arr[probes_arr.len - 1].object;
    try testing.expectEqualStrings("pnull", p.get("name").?.string);
    try testing.expect(p.get("args") == null);
    const a = parsed.value.object.get("actions").?.array.items[0].object;
    try testing.expectEqualStrings("anull", a.get("name").?.string);
    try testing.expectEqualStrings("ad", a.get("desc").?.string);
    try testing.expect(a.get("args") == null);

    // an explicit .args=null is bit-identical to omitting it
    resetForTest();
    registerProbe(.{ .name = "pnull", .ctx = &c, .ext = "txt", .desc = "pd", .digest = testProbeDigest, .args = null });
    registerAction(.{ .name = "anull", .ctx = &ac, .run = testActionRun, .desc = "ad", .args = null });
    const payload2 = formatCapabilitiesPayload(&capabilities_buf);
    try testing.expectEqualStrings(payload, payload2);
}

test "capabilities: an action with args emits the non-default fields only" {
    resetForTest();
    var ac = TestActionCtx{};
    const specs = [_]ArgSpec{
        .{
            .name = "tool",
            .kind = "enum",
            .values = &.{ "pen", "eraser" },
            .optional = true,
            .desc = "tool name",
        },
        .{
            .name = "n",
            .kind = "int",
            .min = 0,
            .max = 255,
            .variadic = true,
        },
        .{
            .name = "color",
            .kind = "string",
            .pattern = "#?RRGGBB",
        },
    };
    registerAction(.{ .name = "full", .ctx = &ac, .run = testActionRun, .args = &specs });

    var parsed = try parseCapabilities(formatCapabilitiesPayload(&capabilities_buf));
    defer parsed.deinit();
    const a = parsed.value.object.get("actions").?.array.items[0].object;
    const args_arr = a.get("args").?.array.items;
    try testing.expectEqual(@as(usize, 3), args_arr.len);

    const t0 = args_arr[0].object;
    try testing.expectEqualStrings("tool", t0.get("name").?.string);
    try testing.expectEqualStrings("enum", t0.get("kind").?.string);
    try testing.expectEqual(@as(usize, 2), t0.get("values").?.array.items.len);
    try testing.expectEqualStrings("pen", t0.get("values").?.array.items[0].string);
    try testing.expect(t0.get("optional").?.bool);
    try testing.expectEqualStrings("tool name", t0.get("desc").?.string);
    try testing.expect(t0.get("min") == null);
    try testing.expect(t0.get("max") == null);
    try testing.expect(t0.get("pattern") == null);
    try testing.expect(t0.get("variadic") == null); // false is left out

    const t1 = args_arr[1].object;
    // a JSON number can be .integer when it is an integer literal (0 and 255)
    const min_f: f64 = switch (t1.get("min").?) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return error.TestUnexpectedResult,
    };
    const max_f: f64 = switch (t1.get("max").?) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(f64, 0), min_f);
    try testing.expectEqual(@as(f64, 255), max_f);
    try testing.expect(t1.get("variadic").?.bool);
    try testing.expect(t1.get("values") == null);
    try testing.expect(t1.get("optional") == null);

    const t2 = args_arr[2].object;
    try testing.expectEqualStrings("#?RRGGBB", t2.get("pattern").?.string);
    try testing.expect(t2.get("desc") == null);
}

test "capabilities: an empty slice makes args:[] appear, distinguishing it from null" {
    resetForTest();
    var ac = TestActionCtx{};
    const empty: []const ArgSpec = &.{};
    registerAction(.{ .name = "none", .ctx = &ac, .run = testActionRun, .args = empty });

    const payload = formatCapabilitiesPayload(&capabilities_buf);
    try testing.expect(std.mem.indexOf(u8, payload, "\"args\":[]") != null);

    var parsed = try parseCapabilities(payload);
    defer parsed.deinit();
    const a = parsed.value.object.get("actions").?.array.items[0].object;
    try testing.expectEqual(@as(usize, 0), a.get("args").?.array.items.len);
}

test "capabilities: an args sanitising violation (a control character in kind, a \" in values, a pattern over 100B) warns and drops args, while the registration succeeds" {
    resetForTest();
    var ac = TestActionCtx{};
    var c = TestProbeCtx{ .value = 1 };

    // a control character in kind
    const bad_kind = [_]ArgSpec{.{ .name = "x", .kind = "in\tt" }};
    registerAction(.{ .name = "bk", .ctx = &ac, .run = testActionRun, .args = &bad_kind });
    try testing.expect(findAction("bk") != null);
    try testing.expect(findAction("bk").?.args == null);

    // a `"` in values
    const bad_val = [_]ArgSpec{.{ .name = "x", .kind = "enum", .values = &.{"a\"b"} }};
    registerAction(.{ .name = "bv", .ctx = &ac, .run = testActionRun, .args = &bad_val });
    try testing.expect(findAction("bv") != null);
    try testing.expect(findAction("bv").?.args == null);

    // a pattern over 100B
    const long_pat = [_]u8{'p'} ** (MAX_ARG_PATTERN_LEN + 1);
    const bad_pat = [_]ArgSpec{.{ .name = "x", .kind = "string", .pattern = &long_pat }};
    registerAction(.{ .name = "bp", .ctx = &ac, .run = testActionRun, .args = &bad_pat });
    try testing.expect(findAction("bp") != null);
    try testing.expect(findAction("bp").?.args == null);

    // the same rule on the probe side
    const bad_probe = [_]ArgSpec{.{ .name = "x", .kind = "in\tt" }};
    registerProbe(.{ .name = "bp2", .ctx = &c, .digest = testProbeDigest, .args = &bad_probe });
    try testing.expect(findProbe("bp2") != null);
    try testing.expect(findProbe("bp2").?.args == null);

    // args does not reach the capabilities JSON either (once it is gone)
    const payload = formatCapabilitiesPayload(&capabilities_buf);
    try testing.expect(std.mem.indexOf(u8, payload, "\"args\"") == null);

    // a non-finite min or max (NaN and Inf are not JSON numbers) → args is gone and the registration succeeds
    const nan_min = [_]ArgSpec{.{ .name = "x", .kind = "int", .min = std.math.nan(f64) }};
    registerAction(.{ .name = "bnan", .ctx = &ac, .run = testActionRun, .args = &nan_min });
    try testing.expect(findAction("bnan") != null);
    try testing.expect(findAction("bnan").?.args == null);
    const inf_max = [_]ArgSpec{.{ .name = "x", .kind = "int", .max = std.math.inf(f64) }};
    registerProbe(.{ .name = "binf", .ctx = &c, .digest = testProbeDigest, .args = &inf_max });
    try testing.expect(findProbe("binf") != null);
    try testing.expect(findProbe("binf").?.args == null);
}

test "capabilities: even when a great many args overflow the buf, the existing truncated mechanism keeps the JSON valid" {
    resetForTest();
    var ac = TestActionCtx{};
    // Load on many ArgSpecs with a huge desc, to take the path where an entry does not fit within content_limit
    const long_desc = [_]u8{'d'} ** 200;
    var many: [40]ArgSpec = undefined;
    for (&many) |*s| {
        s.* = .{ .name = "argname", .kind = "string", .desc = &long_desc };
    }
    registerAction(.{ .name = "huge", .ctx = &ac, .run = testActionRun, .args = &many });

    // Assemble capabilities with a smallish buf → it must be valid JSON
    var small: [MIN_CAPABILITIES_BUF_LEN + 200]u8 = undefined;
    const payload = formatCapabilitiesPayload(&small);
    var parsed = try parseCapabilities(payload);
    defer parsed.deinit();
    // Whether it truncated or it fitted, all that matters is that it is valid JSON
    _ = parsed.value.object.get("probes");
    _ = parsed.value.object.get("actions");
}

// ============================================================================
// MIDI tests
// ============================================================================

test "MIDI inject: the FIFO order of note, cc and note-off, and the state update" {
    resetForTest();
    cmd_buf =
        "inject midi note_on 60 100\n" ++
        "inject midi cc 7 96\n" ++
        "inject midi note_off 60 12\n" ++
        "step 1\nquit";
    try testing.expect(pollGate(true));

    const first = nextMidiEvent().?;
    try testing.expect(first == .note_on);
    try testing.expectEqual(@as(MidiDeviceId, 0), first.note_on.device_id);
    try testing.expectEqual(@as(u8, 60), first.note_on.note);
    const second = nextMidiEvent().?;
    try testing.expect(second == .cc);
    try testing.expectEqual(@as(u8, 7), second.cc.controller);
    const third = nextMidiEvent().?;
    try testing.expect(third == .note_off);
    try testing.expectEqual(@as(u8, 12), third.note_off.velocity);
    try testing.expectEqual(@as(?MidiEvent, null), nextMidiEvent());

    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const digest = switch (digestPayload("midi", &buf)) {
        .ok => |payload| payload,
        .unavailable => return error.UnexpectedResult,
    };
    try testing.expect(std.mem.startsWith(u8, digest, "midi device=0 note_count=0 notes="));
    try testing.expect(std.mem.indexOf(u8, digest, "cc_count=1") != null);
    const cc_pos = std.mem.indexOf(u8, digest, "cc=").? + 3;
    try testing.expectEqualStrings("60", digest[cc_pos + 7 * 2 ..][0..2]);
}

test "MIDI inject: a note_on with velocity 0 is normalised to a note_off" {
    resetForTest();
    cmd_buf = "inject midi note_on 9 0\nstep 1";
    try testing.expect(pollGate(true));
    const ev = nextMidiEvent().?;
    try testing.expect(ev == .note_off);
    try testing.expectEqual(@as(u8, 9), ev.note_off.note);
    try testing.expectEqual(@as(?MidiEvent, null), nextMidiEvent());

    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const digest = switch (digestPayload("midi", &buf)) {
        .ok => |payload| payload,
        .unavailable => return error.UnexpectedResult,
    };
    try testing.expect(std.mem.indexOf(u8, digest, "note_count=0") != null);
}

test "MIDI inject: out of range, an unknown event, and a missing argument leave the queue and state unchanged" {
    resetForTest();
    cmd_buf =
        "inject midi note_on 60 100\n" ++
        "inject midi note_on 128 1\n" ++
        "inject midi cc 8 128\n" ++
        "inject midi bogus 1 2\n" ++
        "inject midi note_off\n" ++
        "step 1";
    try testing.expect(pollGate(true));
    const ev = nextMidiEvent().?;
    try testing.expect(ev == .note_on);
    try testing.expectEqual(@as(?MidiEvent, null), nextMidiEvent());

    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const digest = switch (digestPayload("midi", &buf)) {
        .ok => |payload| payload,
        .unavailable => return error.UnexpectedResult,
    };
    try testing.expect(std.mem.indexOf(u8, digest, "note_count=1") != null);
    try testing.expect(std.mem.indexOf(u8, digest, "cc_count=0") != null);
}

test "MIDI digest: the empty state is a fixed order and a fixed length, under 1024B" {
    resetForTest();
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const digest = switch (digestPayload("midi", &buf)) {
        .ok => |payload| payload,
        .unavailable => return error.UnexpectedResult,
    };
    try testing.expect(digest.len < DIGEST_BUF_LEN);
    try testing.expect(std.mem.startsWith(u8, digest, "midi device=0 note_count=0 notes="));
    try testing.expect(std.mem.indexOf(u8, digest, " cc_count=0 cc=") != null);
    try testing.expectEqual(@as(usize, 256), digest[digest.len - 256 ..].len);

    // Emit note 0 and 127, and controller 0 and 127, in ascending wire order.
    midi_pressed[0] |= 1;
    midi_pressed[15] |= 0x80;
    midi_cc_values[0] = 0;
    midi_cc_values[127] = 127;
    midi_cc_set[0] = true;
    midi_cc_set[127] = true;
    const ordered = switch (digestPayload("midi", &buf)) {
        .ok => |payload| payload,
        .unavailable => return error.UnexpectedResult,
    };
    const notes_pos = std.mem.indexOf(u8, ordered, "notes=").? + 6;
    try testing.expectEqualStrings("01", ordered[notes_pos..][0..2]);
    try testing.expectEqualStrings("80", ordered[notes_pos + 30 ..][0..2]);
    const cc_pos = std.mem.indexOf(u8, ordered, "cc=").? + 3;
    try testing.expectEqualStrings("00", ordered[cc_pos..][0..2]);
    try testing.expectEqualStrings("7F", ordered[cc_pos + 127 * 2 ..][0..2]);
}

test "MIDI reset: the state and the FIFO become empty" {
    resetForTest();
    cmd_buf = "inject midi note_on 1 1\ninject midi cc 2 3\nstep 1";
    try testing.expect(pollGate(true));
    resetForTest();
    try testing.expectEqual(@as(?MidiEvent, null), nextMidiEvent());
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const digest = switch (digestPayload("midi", &buf)) {
        .ok => |payload| payload,
        .unavailable => return error.UnexpectedResult,
    };
    try testing.expect(std.mem.indexOf(u8, digest, "note_count=0") != null);
    try testing.expect(std.mem.indexOf(u8, digest, "cc_count=0") != null);
}

// ============================================================================
// gamepad tests
// ============================================================================

test "gamepad: with none connected getGamepadState is null for every index" {
    resetForTest();
    var i: u8 = 0;
    while (i < MAX_GAMEPADS) : (i += 1) {
        try testing.expectEqual(@as(?GamepadState, null), getGamepadState(i));
    }
    try testing.expectEqual(@as(?GamepadState, null), getGamepadState(MAX_GAMEPADS)); // out of range
}

test "inject gamepad_connect and gamepad_disconnect: the state update, the event firing, and the digest's connected bit" {
    resetForTest();
    cmd_buf =
        \\inject gamepad_connect 0 TestPad
        \\step 1
        \\digest gamepad
        \\inject gamepad_disconnect 0
        \\step 1
        \\digest gamepad
        \\quit
    ;

    try testing.expect(pollGate(true));
    var e = nextInjectedEvent().?;
    try testing.expect(e == .gamepad_connected);
    try testing.expectEqual(@as(u8, 0), e.gamepad_connected.index);
    try testing.expectEqualStrings("TestPad", e.gamepad_connected.name());
    try testing.expect(std.meta.eql(getGamepadState(0).?, GamepadState{})); // the default state (all zeros)

    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    try testing.expectEqualStrings(
        "connected=1 p0_buttons=00000000 p0_lx=0.0000 p0_ly=0.0000 p0_rx=0.0000 p0_ry=0.0000 p0_lt=0.0000 p0_rt=0.0000",
        formatGamepadPayload(&buf),
    );

    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expect(e == .gamepad_disconnected);
    try testing.expectEqual(@as(u8, 0), e.gamepad_disconnected.index);
    try testing.expectEqual(@as(?GamepadState, null), getGamepadState(0));
    try testing.expectEqualStrings("connected=0", formatGamepadPayload(&buf));

    try testing.expect(!pollGate(true));
}

test "inject gamepad_button and gamepad_axis: they update a connected pad's state" {
    resetForTest();
    cmd_buf =
        \\inject gamepad_connect 0
        \\inject gamepad_button 0 a 1
        \\inject gamepad_button 0 start 1
        \\inject gamepad_axis 0 left_x 0.5
        \\inject gamepad_axis 0 left_y -0.25
        \\inject gamepad_axis 0 right_trigger 1
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    const st = getGamepadState(0).?;
    try testing.expect(st.buttons.isSet(.a));
    try testing.expect(st.buttons.isSet(.start));
    try testing.expect(!st.buttons.isSet(.b));
    try testing.expectApproxEqAbs(@as(f32, 0.5), st.left_stick.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.25), st.left_stick.y, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), st.right_trigger, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), st.right_stick.x, 1e-6);

    // turning another button off leaves the other buttons unchanged (the bits are independent)
    cmd_buf = "inject gamepad_button 0 a 0\nstep 1\nquit";
    cursor = 0;
    try testing.expect(pollGate(true));
    const st2 = getGamepadState(0).?;
    try testing.expect(!st2.buttons.isSet(.a));
    try testing.expect(st2.buttons.isSet(.start));
}

test "inject gamepad_button and gamepad_axis: operating on an unconnected pad fails fast (the state is unchanged and nothing is injected)" {
    resetForTest();
    cmd_buf =
        \\inject gamepad_button 0 a 1
        \\inject gamepad_axis 0 left_x 0.5
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(?GamepadState, null), getGamepadState(0));
}

test "inject gamepad_button: an unknown button name, and an invalid value (anything but 0 or 1), are rejected" {
    resetForTest();
    cmd_buf =
        \\inject gamepad_connect 0
        \\inject gamepad_button 0 nosuch 1
        \\inject gamepad_button 0 a 2
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    const st = getGamepadState(0).?;
    try testing.expect(!st.buttons.isSet(.a)); // both are rejected and the state stays at its default
}

test "inject gamepad_axis: out of range (for a stick or a trigger) is rejected (leaving the state unchanged)" {
    resetForTest();
    cmd_buf =
        \\inject gamepad_connect 0
        \\inject gamepad_axis 0 left_x 1.5
        \\inject gamepad_axis 0 left_trigger -0.1
        \\inject gamepad_axis 0 nosuch 0.5
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    const st = getGamepadState(0).?;
    try testing.expectEqual(@as(f32, 0), st.left_stick.x);
    try testing.expectEqual(@as(f32, 0), st.left_trigger);
}

test "inject gamepad_axis: NaN and inf are rejected rather than passing through (a regression check on the hole the review found)" {
    // `v < lo or v > hi` can let a NaN through, both sides being false, so an explicit reject is needed.
    resetForTest();
    cmd_buf =
        \\inject gamepad_connect 0
        \\inject gamepad_axis 0 left_x nan
        \\inject gamepad_axis 0 left_y inf
        \\inject gamepad_axis 0 left_trigger -inf
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    const st = getGamepadState(0).?;
    try testing.expectEqual(@as(f32, 0), st.left_stick.x);
    try testing.expectEqual(@as(f32, 0), st.left_stick.y);
    try testing.expectEqual(@as(f32, 0), st.left_trigger);
}

test "setGamepadAxis: NaN and inf give false even on a direct call (leaving the state unchanged)" {
    var st = GamepadState{};
    try testing.expect(!setGamepadAxis(&st, "left_x", std.math.nan(f32)));
    try testing.expect(!setGamepadAxis(&st, "right_trigger", std.math.inf(f32)));
    try testing.expectEqual(@as(f32, 0), st.left_stick.x);
    try testing.expectEqual(@as(f32, 0), st.right_trigger);
}

test "inject gamepad_connect, gamepad_button and gamepad_disconnect: an index out of range is rejected" {
    resetForTest();
    cmd_buf =
        \\inject gamepad_connect 99
        \\inject gamepad_button 99 a 1
        \\inject gamepad_disconnect 99
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    var i: u8 = 0;
    while (i < MAX_GAMEPADS) : (i += 1) try testing.expectEqual(@as(?GamepadState, null), getGamepadState(i));
}

test "inject commit: a UTF-8 string is decomposed into codepoints and queued as consecutive char_input events" {
    resetForTest();
    // the Japanese fixture below = U+3053 U+3093 U+306B U+3061 U+306F (5 codepoints)
    cmd_buf =
        \\inject composition update 0 x
        \\inject commit こんにちは
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    try testing.expect(nextInjectedEvent().? == .composition_changed);
    try testing.expect(nextInjectedEvent().? == .composition_changed);
    const expected = [_]u32{ 0x3053, 0x3093, 0x306B, 0x3061, 0x306F };
    for (expected) |want| {
        const e = nextInjectedEvent().?;
        try testing.expect(e == .char_input);
        try testing.expectEqual(want, e.char_input.codepoint);
        try testing.expect(!e.char_input.modifiers.shift);
        try testing.expect(!e.char_input.modifiers.ctrl);
        try testing.expect(!e.char_input.modifiers.alt);
        try testing.expect(!e.char_input.modifiers.cmd);
    }
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
    try testing.expect(!pollGate(true));
}

test "inject commit: empty text and invalid UTF-8 fail fast (injecting nothing)" {
    resetForTest();
    cmd_buf =
        \\inject commit
        \\inject commit 
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
    try testing.expect(!pollGate(true));
}

test "inject commit: invalid UTF-8 injects nothing at all rather than part way through" {
    resetForTest();
    // The leading 'A' is valid but the 0xFF after it is not. Pass 1's whole-input validation rejects it, so not even A is queued.
    cmd_buf = "inject composition update 0 x\ninject commit A\xffZ\nstep 1\nquit";
    try testing.expect(pollGate(true));
    try testing.expect(nextInjectedEvent().? == .composition_changed);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
    try testing.expect(!pollGate(true));
}

test "inject commit: the whitespace around the text after the separator is kept (keeping record and replay symmetrical)" {
    resetForTest();
    // After the one separating space right after `commit`: " a b " (a leading space, a, a space, b, a trailing space)
    // → 5 codepoints. The trailing space survives, the policy being to trim the line on the left only.
    cmd_buf = "inject composition update 0 x\ninject commit  a b \nstep 1\nquit";
    try testing.expect(pollGate(true));
    try testing.expect(nextInjectedEvent().? == .composition_changed);
    try testing.expect(nextInjectedEvent().? == .composition_changed);
    const expected = [_]u32{ ' ', 'a', ' ', 'b', ' ' };
    for (expected) |want| {
        const e = nextInjectedEvent().?;
        try testing.expect(e == .char_input);
        try testing.expectEqual(want, e.char_input.codepoint);
    }
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
}

test "inject commit: mixed-in ASCII also gives consecutive char_input events (the same path as inject char)" {
    resetForTest();
    cmd_buf =
        \\inject composition update 0 x
        \\inject commit Ab
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    try testing.expect(nextInjectedEvent().? == .composition_changed);
    try testing.expect(nextInjectedEvent().? == .composition_changed);
    const e0 = nextInjectedEvent().?;
    try testing.expect(e0 == .char_input and e0.char_input.codepoint == 'A');
    const e1 = nextInjectedEvent().?;
    try testing.expect(e1 == .char_input and e1.char_input.codepoint == 'b');
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
}

test "the gamepad probe digest: with several pads connected the connected bitmask and the p<idx>_ prefix coexist" {
    resetForTest();
    cmd_buf =
        \\inject gamepad_connect 0
        \\inject gamepad_connect 2
        \\inject gamepad_axis 2 right_y -1
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const payload = formatGamepadPayload(&buf);
    try testing.expect(std.mem.startsWith(u8, payload, "connected=5 ")); // pad0(bit0)+pad2(bit2) = 0b101 = 5
    try testing.expect(std.mem.indexOf(u8, payload, "p0_buttons=") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "p1_buttons=") == null); // pad1 is not connected
    try testing.expect(std.mem.indexOf(u8, payload, "p2_ry=-1.0000") != null);
}

test "the gamepad probe: the same payload comes back through the digest command too (the self-check path of a headless replay)" {
    resetForTest(); // mode=.replay
    cmd_buf = "inject gamepad_connect 0\nstep 1\nquit";
    try testing.expect(pollGate(true)); // consume the injections, then step
    try testing.expect(!pollGate(true)); // quit → the end

    // The routing of a digest itself is checked through live framing (in the same shape as the existing "custom probe: register + digest routing").
    mode = .live;
    resp_buf.clearRetainingCapacity();
    defer resp_buf.clearRetainingCapacity();
    var it = std.mem.tokenizeAny(u8, "gamepad", " \t");
    handleDigest(&it);
    try testing.expect(std.mem.startsWith(u8, resp_buf.items, "gamepad connected=1 "));
}

test "harness onLock and onPresent: the observation copy goes from the borrowed platform buffer into frame_pixels" {
    resetForTest();
    defer resetForTest();

    var pixels = [_]u32{ 0xFF112233, 0xFF112233, 0xFF112233, 0xFF112233 };
    onLock(&pixels, 2, 2);
    onPresent();
    try testing.expect(have_frame);
    try testing.expectEqual(@as(u32, 0xFF112233), frame_pixels[0]);
    try testing.expectEqual(@as(u32, 0xFF112233), frame_pixels[3]);
}

fn testSleepMs(ms: u64) void {
    const sec: i64 = @intCast(ms / 1000);
    const nsec: i64 = @intCast((ms % 1000) * 1_000_000);
    const req = std.posix.timespec{ .sec = sec, .nsec = nsec };
    _ = std.c.nanosleep(&req, null);
}

fn initLiveServerForTest() !u16 {
    threaded = std.Io.Threaded.init(gpa, .{});
    io_val = threaded.io();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    server = try addr.listen(io_val, .{ .reuse_address = true });
    mode = .live;
    clock_mode = .manual; // the existing live pump test relies on the blocking contract
    cmd_buf = "";
    cursor = 0;
    line_no = 0;
    steps_remaining = 0;
    quit_requested = false;
    pending_wait = .none;
    live_req_open = false;
    freerun_reading = false;
    req_bytes = &.{};
    resp_buf.clearRetainingCapacity();
    return server.socket.address.getPort();
}

fn deinitLiveServerForTest() void {
    if (live_req_open) finishLiveRequest();
    server.deinit(io_val);
    test_live_poll_timeout_ms = null;
    mode = .replay;
    cmd_buf = "";
    cursor = 0;
}

test "pollGateWithPump: a null pump behaves as pollGate does (under replay)" {
    const runSequence = struct {
        fn run(use_with_pump: bool) [2]bool {
            resetForTest();
            cmd_buf = "step 1\nquit";
            return .{
                if (use_with_pump) pollGateWithPump(true, null) else pollGate(true),
                if (use_with_pump) pollGateWithPump(true, null) else pollGate(true),
            };
        }
    }.run;
    try testing.expectEqual(runSequence(false), runSequence(true));
}

test "pollGateWithPump: under replay the fake pump is not called" {
    resetForTest();
    cmd_buf = "step 1\nquit";
    var pump_count: usize = 0;
    const PumpCtx = struct { count: *usize };
    var ctx = PumpCtx{ .count = &pump_count };
    const pump = NativePump{
        .ptr = @ptrCast(&ctx),
        .pollFn = struct {
            fn poll(p: *anyopaque) bool {
                const c: *PumpCtx = @ptrCast(@alignCast(p));
                c.count.* += 1;
                return true;
            }
        }.poll,
    };
    try testing.expect(pollGateWithPump(true, pump));
    try testing.expectEqual(@as(usize, 0), pump_count);
}

test "pollGateWithPump: a false from the fake pump breaks off the live accept wait" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    resetForTest();
    test_live_poll_timeout_ms = 5;
    _ = initLiveServerForTest() catch return error.SkipZigTest;
    defer deinitLiveServerForTest();

    const pump = NativePump{
        .ptr = undefined,
        .pollFn = struct {
            fn poll(_: *anyopaque) bool {
                return false;
            }
        }.poll,
    };
    try testing.expect(!pollGateWithPump(true, pump));
}

test "the live pump: the fake pump is called while waiting on an accept" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    resetForTest();
    test_live_poll_timeout_ms = 5;
    const port = initLiveServerForTest() catch return error.SkipZigTest;
    defer deinitLiveServerForTest();

    var pump_count: usize = 0;
    const PumpCtx = struct { count: *usize };
    var ctx = PumpCtx{ .count = &pump_count };
    const pump = NativePump{
        .ptr = @ptrCast(&ctx),
        .pollFn = struct {
            fn poll(p: *anyopaque) bool {
                const c: *PumpCtx = @ptrCast(@alignCast(p));
                c.count.* += 1;
                return true;
            }
        }.poll,
    };

    const Connect = struct {
        fn run(port_val: u16) void {
            var client_threaded = std.Io.Threaded.init(gpa, .{});
            const client_io = client_threaded.io();
            testSleepMs(50);
            const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port_val) };
            const stream = addr.connect(client_io, .{ .mode = .stream }) catch return;
            defer stream.close(client_io);
            var wbuf: [64]u8 = undefined;
            var writer = stream.writer(client_io, &wbuf);
            writer.interface.writeAll("step 1\n") catch return;
            writer.interface.flush() catch return;
            stream.shutdown(client_io, .send) catch {};
        }
    };
    const t = std.Thread.spawn(.{}, Connect.run, .{port}) catch return error.SkipZigTest;
    defer t.join();

    try testing.expect(pollGateWithPump(true, pump));
    try testing.expect(pump_count >= 3);
}

test "the live pump: the fake pump is called while reading a request too" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    resetForTest();
    test_live_poll_timeout_ms = 5;
    const port = initLiveServerForTest() catch return error.SkipZigTest;
    defer deinitLiveServerForTest();

    var pump_count: usize = 0;
    const PumpCtx = struct { count: *usize };
    var ctx = PumpCtx{ .count = &pump_count };
    const pump = NativePump{
        .ptr = @ptrCast(&ctx),
        .pollFn = struct {
            fn poll(p: *anyopaque) bool {
                const c: *PumpCtx = @ptrCast(@alignCast(p));
                c.count.* += 1;
                return true;
            }
        }.poll,
    };

    const SlowConnect = struct {
        fn run(port_val: u16) void {
            var client_threaded = std.Io.Threaded.init(gpa, .{});
            const client_io = client_threaded.io();
            const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port_val) };
            const stream = addr.connect(client_io, .{ .mode = .stream }) catch return;
            defer stream.close(client_io);
            var wbuf: [4096]u8 = undefined;
            var writer = stream.writer(client_io, &wbuf);
            writer.interface.writeAll("step") catch return;
            writer.interface.flush() catch return;
            testSleepMs(50);
            writer.interface.writeAll(" 1\n") catch return;
            writer.interface.flush() catch return;
            stream.shutdown(client_io, .send) catch {};
        }
    };
    const t = std.Thread.spawn(.{}, SlowConnect.run, .{port}) catch return error.SkipZigTest;
    defer t.join();

    try testing.expect(pollGateWithPump(true, pump));
    try testing.expect(pump_count >= 3);
}

test "the live pump: the next connection can still be accepted after a request goes over 1 MiB" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    resetForTest();
    test_live_poll_timeout_ms = 5;
    const port = initLiveServerForTest() catch return error.SkipZigTest;
    defer deinitLiveServerForTest();

    const always_pump = NativePump{
        .ptr = undefined,
        .pollFn = struct {
            fn poll(_: *anyopaque) bool {
                return true;
            }
        }.poll,
    };

    const HugeThenStep = struct {
        fn run(port_val: u16) void {
            var client_threaded = std.Io.Threaded.init(gpa, .{});
            const client_io = client_threaded.io();
            {
                const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port_val) };
                const stream = addr.connect(client_io, .{ .mode = .stream }) catch return;
                var wbuf: [8192]u8 = undefined;
                var writer = stream.writer(client_io, &wbuf);
                var chunk: [65536]u8 = undefined;
                @memset(&chunk, 'a');
                var sent: usize = 0;
                const over = (1 << 20) + 1;
                while (sent < over) : (sent += chunk.len) {
                    const n = @min(chunk.len, over - sent);
                    writer.interface.writeAll(chunk[0..n]) catch return;
                }
                writer.interface.flush() catch return;
                stream.shutdown(client_io, .send) catch {};
                stream.close(client_io);
            }
            {
                const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port_val) };
                const stream = addr.connect(client_io, .{ .mode = .stream }) catch return;
                defer stream.close(client_io);
                var wbuf: [64]u8 = undefined;
                var writer = stream.writer(client_io, &wbuf);
                writer.interface.writeAll("step 1\n") catch return;
                writer.interface.flush() catch return;
                stream.shutdown(client_io, .send) catch {};
            }
        }
    };
    const t = std.Thread.spawn(.{}, HugeThenStep.run, .{port}) catch return error.SkipZigTest;
    defer t.join();

    try testing.expect(pollGateWithPump(true, always_pump));
}

test "the netsync probe: unregistered while disabled, and expect role=host on an enabled host" {
    resetForTest();
    defer resetForTest();
    // while disabled (before the register), netsync does not appear in capabilities
    try testing.expect(findProbe("netsync") == null);
    {
        var parsed = try parseCapabilities(formatCapabilitiesPayload(&capabilities_buf));
        defer parsed.deinit();
        const probe_list = parsed.value.object.get("probes").?.array;
        for (probe_list.items) |item| {
            const name = item.object.get("name").?.string;
            try testing.expect(!std.mem.eql(u8, name, "netsync"));
        }
    }

    netsync.resetForTest();
    defer netsync.resetForTest();
    netsync.initHost(0);
    registerProbe(.{
        .name = "netsync",
        .ctx = @ptrFromInt(1),
        .ext = "json",
        .desc = "netsync stats",
        .digest = netsync.probeDigest,
        .snapshot = netsync.probeSnapshot,
    });
    try testing.expect(findProbe("netsync") != null);

    // headless replay: expect netsync role=host
    var sbuf: [128]u8 = undefined;
    cmd_buf = "expect netsync role=host\nstep 1\n";
    _ = &sbuf;
    cursor = 0;
    expect_failures = 0;
    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(usize, 0), expect_failures);
}

// ============================================================================
// the free-run clock, LISTEN and await
// ============================================================================

test "parseListenPortValue: absent/empty/0/fixed/invalid" {
    try testing.expect(!parseListenPortValue(null).requested);
    {
        const p = parseListenPortValue("");
        try testing.expect(p.requested);
        try testing.expect(p.valid);
        try testing.expectEqual(@as(u16, 0), p.port);
    }
    {
        const p = parseListenPortValue("0");
        try testing.expect(p.requested and p.valid);
        try testing.expectEqual(@as(u16, 0), p.port);
    }
    {
        const p = parseListenPortValue("9110");
        try testing.expect(p.requested and p.valid);
        try testing.expectEqual(@as(u16, 9110), p.port);
    }
    {
        const p = parseListenPortValue("abc");
        try testing.expect(p.requested);
        try testing.expect(!p.valid);
    }
}

test "decideTransport: SCRIPT/LISTEN/MANUAL_CLOCK exclusivity and clock defaults" {
    const ephemeral = ListenPortParse{ .requested = true, .port = 0, .valid = true };
    const none = ListenPortParse{ .requested = false };
    const bad = ListenPortParse{ .requested = true, .port = 0, .valid = false };

    {
        const d = decideTransport(false, none, false);
        try testing.expect(!d.enable);
    }
    {
        const d = decideTransport(false, none, true);
        try testing.expect(!d.enable);
        try testing.expect(d.reason_disabled != null);
    }
    {
        const d = decideTransport(true, ephemeral, false);
        try testing.expect(!d.enable);
    }
    {
        const d = decideTransport(false, bad, false);
        try testing.expect(!d.enable);
    }
    {
        const d = decideTransport(true, none, false);
        try testing.expect(d.enable);
        try testing.expect(d.clock == .manual);
    }
    {
        const d = decideTransport(true, none, true); // MANUAL_CLOCK on SCRIPT ignored
        try testing.expect(d.enable);
        try testing.expect(d.clock == .manual);
    }
    {
        const d = decideTransport(false, ephemeral, false);
        try testing.expect(d.enable);
        try testing.expect(d.clock == .free_run);
    }
    {
        const d = decideTransport(false, ephemeral, true);
        try testing.expect(d.enable);
        try testing.expect(d.clock == .manual);
    }
}

test "free-run: empty drain does poll(0) exactly once and returns true" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    resetForTest();
    _ = initLiveServerForTest() catch return error.SkipZigTest;
    defer deinitLiveServerForTest();
    clock_mode = .free_run;
    test_poll_zero_count = 0;

    try testing.expect(pollGateFreeRun(true));
    try testing.expectEqual(@as(usize, 1), test_poll_zero_count);
    try testing.expect(!live_req_open);
    try testing.expect(!freerun_reading);
}

test "step dual: manual uses steps_remaining, free-run uses frame barrier" {
    // manual
    resetForTest();
    cmd_buf = "step 3\nquit";
    clock_mode = .manual;
    try testing.expect(pollGate(true)); // frame 1, steps_remaining=2
    try testing.expectEqual(@as(usize, 2), steps_remaining);
    try testing.expect(pending_wait == .none);
    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(usize, 1), steps_remaining);
    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(usize, 0), steps_remaining);
    try testing.expect(!pollGate(true)); // quit

    // the free-run barrier (a live server plus an in-memory request)
    if (builtin.os.tag == .windows) return;

    resetForTest();
    _ = initLiveServerForTest() catch return;
    defer deinitLiveServerForTest();
    clock_mode = .free_run;
    // Load the request directly (checking the barrier alone, without going through a socket)
    req_bytes = try gpa.dupe(u8, "step 2\n");
    cmd_buf = req_bytes;
    cursor = 0;
    live_req_open = true;
    frame_index = 10;
    try testing.expect(pollGateFreeRun(true));
    try testing.expect(pending_wait == .frame_barrier);
    try testing.expectEqual(@as(u64, 12), pending_wait.frame_barrier.target_frame);
    // not reached
    frame_index = 11;
    try testing.expect(pollGateFreeRun(true));
    try testing.expect(pending_wait == .frame_barrier);
    // reached → the commands run out and it finishes (finishLiveRequest frees req_bytes)
    frame_index = 12;
    try testing.expect(pollGateFreeRun(true));
    try testing.expect(pending_wait == .none);
    try testing.expect(!live_req_open);
}

test "await: timeout 0 checks once; positive waits across frames (manual)" {
    resetForTest();
    // before a present: fb is unavailable → so timeout 0 fails at once (without quitting, which avoids replayExitIfFailed)
    cmd_buf = "await fb crc=DEADBEEF 0\nstep 1\n";
    expect_failures = 0;
    try testing.expect(pollGate(true)); // await fail + step
    try testing.expectEqual(@as(usize, 1), expect_failures);
    try testing.expect(pending_wait == .none);

    resetForTest();
    var pixels = [_]u32{0xFF0000FF} ** 4;
    onLock(&pixels, 2, 2);
    onPresent(); // frame_index=1, have_frame
    // a mismatch plus timeout 1: it does not fail at once but goes pending → and fails one frame later
    cmd_buf = "await fb crc=00000000 1\nstep 1\n";
    try testing.expect(pollGate(true)); // start await → pending → return true
    try testing.expect(pending_wait == .predicate);
    // advance the frame to reach the deadline
    onPresent(); // frame_index=2; start was 1; timeout 1 → deadline=2
    try testing.expect(pollGate(true)); // fail await + step
    try testing.expect(pending_wait == .none);
    try testing.expect(expect_failures >= 1);
}

test "await: timeout 0 pass when predicate already true" {
    resetForTest();
    var pixels = [_]u32{0xFF112233} ** 4;
    onLock(&pixels, 2, 2);
    onPresent();
    var digbuf: [DIGEST_BUF_LEN]u8 = undefined;
    const payload = formatFbPayload(&digbuf);
    // pull crc= out of the payload
    const crc_tok = blk: {
        var it = std.mem.tokenizeAny(u8, payload, " \t");
        while (it.next()) |t| {
            if (std.mem.startsWith(u8, t, "crc=")) break :blk t;
        }
        return error.SkipZigTest;
    };
    var script_buf: [128]u8 = undefined;
    const script = try std.fmt.bufPrint(&script_buf, "await fb {s} 0\nstep 1\n", .{crc_tok});
    const owned = try gpa.dupe(u8, script);
    defer gpa.free(owned);
    cmd_buf = owned;
    expect_failures = 0;
    try testing.expect(pollGate(true)); // await ok → step
    try testing.expectEqual(@as(usize, 0), expect_failures);
}

test "parseAwaitExpr: optional timeout and surplus reject" {
    {
        var it = std.mem.tokenizeAny(u8, "fb crc=ABC", " \t");
        const a = parseAwaitExpr(&it).?;
        try testing.expectEqual(@as(usize, 0), a.timeout_frames);
        try testing.expectEqualStrings("fb", a.expr.probe);
    }
    {
        var it = std.mem.tokenizeAny(u8, "audio silent=0 5", " \t");
        const a = parseAwaitExpr(&it).?;
        try testing.expectEqual(@as(usize, 5), a.timeout_frames);
    }
    {
        var it = std.mem.tokenizeAny(u8, "fb crc=ABC 1 extra", " \t");
        try testing.expect(parseAwaitExpr(&it) == null);
    }
}

test "the free-run execution model: true every frame even with no agent present" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    resetForTest();
    _ = initLiveServerForTest() catch return error.SkipZigTest;
    defer deinitLiveServerForTest();
    clock_mode = .free_run;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try testing.expect(pollGateFreeRun(true));
    }
    try testing.expect(!quit_requested);
}

// ============================================================================
// The namespace re-export of copilot (the third control plane).
// It is a single line purely so that the facade reaches it as `@import("harness").copilot`;
// harness never calls a copilot function (the semantic dependency runs one way, copilot→harness).
// ============================================================================
pub const copilot = @import("copilot.zig");

// The namespace re-export of the command model. As with copilot, this shares the one
// instance of the types (so the facade reaches it as `@import("harness").command`; command.zig is std only).
pub const command = @import("command.zig");
