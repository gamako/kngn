# ADR-009: Gamepad input (types, API shape, harness alignment)

**Status:** Accepted (the design is settled; the macOS GameController backend is implemented; Linux and Windows hardware backends remain follow-up)
**Date:** 2026-07-05
**Category:** Platform API, input

## Summary

Settles the design of gamepad (controller) input. The backend-independent
skeleton — types, the facade, harness injection and a probe, helpers, and an
example — is in place. **macOS** now implements hardware polling through the
GameController framework (opt-in per executable via `build_options.enable_gamepad`).
**Linux and Windows** hardware backends remain follow-up; without the harness they
still return `null` from `Window.getGamepadState`.

**The decision, in short:**

1. **Polling first, plus connection events**: continuous button and axis values are
   read by polling `Window.getGamepadState(idx)`. Only connect and disconnect are
   reported as one-shot events, `Event.gamepad_connected` and
   `Event.gamepad_disconnected`.
2. **Normalise to a standard layout**: every backend is contracted to normalise its
   native raw reports into the fixed layout settled here (15 `GamepadButton` values
   plus 2 sticks plus 2 triggers).
3. **Triggers are axes only**: L2 and R2 are not exposed as buttons. They exist only
   as the analog axes `left_trigger` and `right_trigger` (f32 0..1).
4. **Raw values plus a deadzone helper**: the facade and harness return raw values;
   applying a deadzone is left to `applyDeadzone()` in `src/gamepad.zig` (opt-in).
5. **The harness state model**: the harness holds
   `gamepad_states: [MAX_GAMEPADS]?GamepadState` and updates it from
   `inject gamepad_connect/disconnect/button/axis`. `Window.getGamepadState` becomes
   the facade's fifth choke point, interposed by the harness.
6. **Append to `Event`**: `gamepad_connected: GamepadInfo` and
   `gamepad_disconnected: GamepadDisconnect` are appended to the end of the `Event`
   union — the same "append at the end, then fix every consumer linearly" pattern
   used when `char_input` was added.

## Context

This project already has keyboard (`KeyCode`, `KeyEvent`) and mouse (`MouseButton`,
`MouseEvent`, `ScrollEvent`) as shared types in `core/platform_types.zig`, with
`core/platform.zig` (the facade) providing the event path and
`core/control/harness.zig` providing input injection and observation. Gamepads
differ:

- There are many buttons and axes (15 buttons, 2 sticks, 2 triggers), and the main
  use is reading continuous values every frame (event notifications of "pressed" and
  "released" alone would be redundant).
- Connect and disconnect are intrinsically asynchronous events — a concept that does
  not exist for keyboard or mouse.
- The shape of the raw report differs greatly between macOS
  (IOKit / GameController.framework), Linux (evdev / the js API) and Windows (XInput
  / DirectInput), so passing them through unchanged could never produce a consistent
  API across backends.

For those reasons the keyboard and mouse "events only" model is not carried over
directly, and the decisions above are settled here.

## Terms

| Term | Definition |
|---|---|
| **standard layout** | The backend-independent set of buttons and axes defined here (see "Decision"). The names follow an Xbox-style arrangement, but mapping the actual physical layout is the backend's normalisation job. |
| **normalisation** | Each backend mapping its native raw report (HID usage, evdev code, XInput bitmask) onto the standard layout — the responsibility of the backend work. |
| **deadzone** | Ignoring small jitter near the centre of a stick. The facade and harness do not apply it; the consumer opts in via `applyDeadzone()`. |

## Decision

### 1. The standard layout

```zig
pub const MAX_GAMEPADS: u8 = 4;

pub const GamepadButton = enum(u8) {
    a, b, x, y,
    left_shoulder, right_shoulder,
    back, start,
    left_stick, right_stick, // pressing the stick down (a click)
    dpad_up, dpad_down, dpad_left, dpad_right,
    guide, // the Xbox button (home)
};

pub const GamepadButtons = packed struct(u32) {
    a: bool = false, b: bool = false, x: bool = false, y: bool = false,
    left_shoulder: bool = false, right_shoulder: bool = false,
    back: bool = false, start: bool = false,
    left_stick: bool = false, right_stick: bool = false,
    dpad_up: bool = false, dpad_down: bool = false,
    dpad_left: bool = false, dpad_right: bool = false,
    guide: bool = false,
    _reserved: u17 = 0,
    // provides isSet(btn) / set(btn, value) / toC() / fromC()
};

pub const Stick = struct { x: f32 = 0, y: f32 = 0 }; // -1.0..1.0 (raw, no deadzone)

pub const GamepadState = struct {
    buttons: GamepadButtons = .{},
    left_stick: Stick = .{},
    right_stick: Stick = .{},
    left_trigger: f32 = 0,  // 0.0..1.0 (raw)
    right_trigger: f32 = 0, // 0.0..1.0 (raw)
};

pub const GAMEPAD_NAME_MAX: usize = 32;
pub const GamepadInfo = struct {
    index: u8,
    name_len: u8 = 0,
    name_buf: [GAMEPAD_NAME_MAX]u8 = [_]u8{0} ** GAMEPAD_NAME_MAX,
    pub fn name(self: *const GamepadInfo) []const u8 { return self.name_buf[0..self.name_len]; }
};

pub const GamepadDisconnect = struct { index: u8 };
```

**Sub-decisions:**

1. **`GamepadButton` is an exhaustive enum** (no trailing `_,`). It is a fixed
   15-value standard layout, and appending a value at the end suffices if it ever
   needs extending. Making it non-exhaustive would require an "unknown value" branch
   in `isSet`, `set`, `getButtonName` and the harness parser, where the cost
   outweighs the benefit.
2. **Triggers are not part of the button set.** Controllers on which they physically
   are buttons (some inexpensive models) are unified into axes during normalisation
   (the backend's responsibility).
3. **The encoding contract for `GamepadInfo.name`**: copy a UTF-8 byte sequence up to
   `GAMEPAD_NAME_MAX` (32) bytes. The Zig side tracks the used length in
   `name_len: u8` (no NUL terminator needed) and `name()` simply returns
   `name_buf[0..name_len]`. On the C ABI side (`gamepad.name[33]` in `platform.h`)
   the buffer is a fixed 32 + NUL, and the implementation must NUL-terminate and
   truncate anything beyond 32 bytes at the source.
4. **`MAX_GAMEPADS = 4`** has `core/platform_types.zig` as its single source; both the
   facade (`platform.MAX_GAMEPADS`) and the harness (the length of `gamepad_states`)
   derive from it rather than defining it twice.

### 2. The API shape

```zig
// core/platform.zig (the facade)
pub fn getGamepadState(self: Window, index: u8) ?GamepadState;
```

- **The polling function is a `Window` method**, matching the shape of the existing
  `lockFramebuffer` and `present`.
- **Facade dispatch (current behaviour)**: when the harness is enabled it returns
  injected state; otherwise on **macOS with `build_options.enable_gamepad`** it
  dispatches to `platform_macos.Window.getGamepadState` (GameController via the C
  ABI); on Linux, Windows, wasm, or macOS without the opt-in it returns `null`.
  > **Supersedes the skeleton-era note**: when this ADR was accepted every backend
  > returned `null` and the backend files were untouched. That is no longer true on
  > macOS (`platform/macos/platform_macos.m`,
  > `platform/macos-shared/platform_macos_shared.swift`, and
  > `core/platform_macos.zig`). Linux / Windows / DirectInput / XInput /
  > evdev hardware backends remain follow-up.
- **Connect and disconnect go through `Event`.** On macOS the GameController
  connect/disconnect observers enqueue `Event.gamepad_connected` and
  `gamepad_disconnected`. The harness's `inject gamepad_connect/disconnect` remains
  the synthetic path for every OS.

### 3. The C ABI (for the macOS backend; consumed by the backend work)

```c
typedef enum {
    PLATFORM_GAMEPAD_BUTTON_A = 0x0001,
    PLATFORM_GAMEPAD_BUTTON_B = 0x0002,
    PLATFORM_GAMEPAD_BUTTON_X = 0x0004,
    PLATFORM_GAMEPAD_BUTTON_Y = 0x0008,
    PLATFORM_GAMEPAD_BUTTON_LEFT_SHOULDER = 0x0010,
    PLATFORM_GAMEPAD_BUTTON_RIGHT_SHOULDER = 0x0020,
    PLATFORM_GAMEPAD_BUTTON_BACK = 0x0040,
    PLATFORM_GAMEPAD_BUTTON_START = 0x0080,
    PLATFORM_GAMEPAD_BUTTON_LEFT_STICK = 0x0100,
    PLATFORM_GAMEPAD_BUTTON_RIGHT_STICK = 0x0200,
    PLATFORM_GAMEPAD_BUTTON_DPAD_UP = 0x0400,
    PLATFORM_GAMEPAD_BUTTON_DPAD_DOWN = 0x0800,
    PLATFORM_GAMEPAD_BUTTON_DPAD_LEFT = 0x1000,
    PLATFORM_GAMEPAD_BUTTON_DPAD_RIGHT = 0x2000,
    PLATFORM_GAMEPAD_BUTTON_GUIDE = 0x4000,
} PlatformGamepadButtonFlags;

typedef struct PlatformGamepadState {
    uint32_t buttons_mask;
    float left_stick_x, left_stick_y;
    float right_stick_x, right_stick_y;
    float left_trigger, right_trigger;
} PlatformGamepadState;

#define PLATFORM_MAX_GAMEPADS 4

bool platform_get_gamepad_state(PlatformWindow* window, int index, PlatformGamepadState* out_state);
```

- Bit positions match the declaration order of `GamepadButtons` on the Zig side
  (`a=bit0` … `guide=bit14`).
- `PLATFORM_EVENT_GAMEPAD_CONNECTED` and `PLATFORM_EVENT_GAMEPAD_DISCONNECTED` are
  appended to `PlatformEventType`, and `gamepad{ int32_t index; char name[33]; }` is
  added to `PlatformEvent.payload` (`name` is empty for the disconnect event).
- **macOS implements `platform_get_gamepad_state`** (objc and the shared Swift path)
  when gamepad support is linked. Linux and Windows still have no native
  implementation; the Zig facade returns `null` there (see §2).

### 4. Effect on the harness

1. **State**: `gamepad_states: [MAX_GAMEPADS]?GamepadState` is held as module-level
   state, matching the existing "single-process debug facility" design of
   `inject_buf` and `mouse_buttons`.
2. **Injection commands**, in the same syntax family as the existing `key_down` and
   `mouse_down`:
   ```text
   inject gamepad_connect <idx> [name]     # mark idx connected and create a default (all-zero) GamepadState
   inject gamepad_disconnect <idx>         # mark idx disconnected
   inject gamepad_button <idx> <button> <0|1>
   inject gamepad_axis <idx> <axis> <value>  # axis ∈ left_x/left_y/right_x/right_y/left_trigger/right_trigger
   ```
   - `gamepad_button` and `gamepad_axis` **reject operations on a disconnected pad
     fail-fast**, matching the existing injection principle that an invalid token is
     not injected and does not dirty state.
   - `gamepad_axis` **rejects out-of-range values fail-fast** (sticks `[-1,1]`,
     triggers `[0,1]`). To hold the raw-value contract — no deadzone, but the range is
     normalised — it rejects rather than clamps.
3. **The built-in probe `gamepad`** (a reserved name alongside `fb`, `audio`,
   `stats`, `capabilities` and `capture`):
   ```text
   digest gamepad
   # connected=<bitmask> p0_buttons=<hex8> p0_lx=<d.4> p0_ly=<d.4> p0_rx=<d.4> p0_ry=<d.4> p0_lt=<d.4> p0_rt=<d.4> [p1_... ...]
   ```
   - Only connected pads are listed (`connected` is the connection bitmask for all
     pads, so `expect gamepad connected>0` works).
   - Keys carry a `p<idx>_` prefix per pad so they stay top-level `k=v` pairs
     separated by spaces, matching the existing `findKeyValue` rule that only top-level
     keys are extracted.
   - Floats are a fixed four decimals (`{d:.4}`) with negative zero normalised (`+0.0`
     when `v == 0`), so formatting variation cannot break a string comparison
     in `expect`.
   - `buttons` is hex8 (`{X:0>8}`), the same width as the existing `crc={X:0>8}`.
     Comparing a hex value containing letters works the same way as crc: copy and
     paste, with a string comparison as the fallback when the value does not parse as a
     number.
4. **`Window.getGamepadState` becomes the facade's fifth choke point** interposed by
   the harness, after `pollEvents`, `nextEvent`, `present` and `getTime`.
5. **capabilities**: `gamepad` is appended to the end of `CAPABILITY_BUILTINS`,
   continuing the existing order (fb → audio → stats → capabilities → capture).

### 5. Helpers

`src/gamepad.zig` (depends only on `core/platform_types.zig`; no platform facade, so
it is unit testable headless):

```zig
pub fn getButtonName(btn: GamepadButton) []const u8;
pub fn justPressed(prev: GamepadButtons, cur: GamepadButtons, button: GamepadButton) bool;
pub fn applyDeadzone(stick: Stick, dz: f32) Stick; // radial deadzone
```

It is re-exported from `kit/kit.zig` as `pub const gamepad = @import("gamepad");`.
The other legacy helpers in `src/` (`keyboard.zig` and friends) are for examples only
and are not in kit, but gamepad is included on the assumption that applications will
use it directly.

## Verification against existing contracts

- **Existing callers need no changes**: appending to the `Event` union does not
  affect a switch that has an `else =>`. The exhaustive switches without an `else`
  (the `toGuiEvent` family in the examples, `apps/noodle`, and parts of
  `apps/editor/apps/pixie`) each gain a one-line no-op branch — the same scope of change as when
  `char_input` was added.
- **Backends implement independently**: macOS has done so (GameController). Linux and
  Windows can still land later without changing the settled layout or harness
  contract.
- **Harness determinism**: `gamepad_states` is updated only while handling an
  injection (on events only, so not a hot path). The per-frame `getGamepadState` call
  itself just reads existing state, with no allocation and no locking.

## Consequences

- `core/platform_types.zig`: adds `MAX_GAMEPADS`, `GamepadButton`, `GamepadButtons`,
  `Stick`, `GamepadState`, `GamepadInfo` and `GamepadDisconnect`, plus two variants on
  the `Event` union.
- `platform/platform.h`: backward-compatible appends of the C ABI types, the event
  kinds and the function prototype.
- `core/platform.zig`: `Window.getGamepadState` (harness choke point; macOS opt-in
  dispatch; otherwise `null`).
- `core/platform_macos.zig` plus the macOS C ABI
  (`platform/macos/platform_macos.m`,
  `platform/macos-shared/platform_macos_shared.swift`): GameController polling and
  connect/disconnect events (**implemented** after this ADR was accepted).
- `core/control/harness.zig`: the `gamepad_states` state, four injection commands and
  the built-in `gamepad` probe.
- `src/gamepad.zig`: helpers (re-exported from `kit/kit.zig`).
- `examples/22_gamepad`: the example (`run-example_22`).
- Linux and Windows hardware backends remain follow-up (facade returns `null`).

## Hot-path declaration

`Window.getGamepadState(idx)` is expected to be called every frame (the example calls
it four times per frame, for pads 0..3). It is a fixed-size copy of a few fields for
four pads, with no allocation and no locking, and it is neither an all-pixel loop nor
a real-time per-sample path, so the performance rules in `AGENT.md` (the SIMD trio,
cache line separation and so on) do not apply. Updating `gamepad_states` and
producing the `gamepad` digest happen only on events (once per injection or digest
command) and are not hot paths.

## Revision history

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-07-05 | First version. Settles the standard layout, polling first plus connection events, triggers as axes only, raw values plus a deadzone helper, the harness state model, appending to `Event`, and the C ABI types. |
| 1.1 | 2026-07-27 | Status / §2 / C ABI / Consequences updated for the implemented macOS GameController backend. The decision (layout, polling-first, triggers-as-axes, harness model) is unchanged. Linux/Windows hardware backends remain follow-up. |
