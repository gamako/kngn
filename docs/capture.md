# Capture input: microphones and cameras

Capture is split deliberately: the **control plane is unified** and the **data plane is
separated**. Microphone and camera share one set of verbs, one lifecycle and one
error and permission classification; the frames themselves travel by different means,
because audio and video have different delivery requirements.

There is no unified runtime type (no `CaptureDevice` union or vtable). Native APIs are
split on some systems (ALSA and V4L2 are unrelated) and unified on others (an
`AVCaptureSession` handles both), so a single runtime abstraction would add pointless
indirection on the split systems and throw away expressiveness on the unified ones.
**Unification stops at the level of a convention** — the same signatures, naming and
error classification — and never becomes a shared runtime base type.

| Layer | Where |
|---|---|
| Shared types (type-only, the single source) | `core/capture_types.zig` (`@import("capture_types")`) |
| Microphone facade | the capture section of `core/audio.zig` |
| Camera facade | `core/camera.zig` |
| Backends | macOS: `core/camera_macos.zig` (AVFoundation) and the `capture` namespace of `core/audio_macos.zig` (AUHAL). Linux: `core/camera_v4l2.zig` (V4L2) and the `capture` namespace of `core/audio_linux.zig` (ALSA). Anywhere else: `core/camera_stub.zig` and `core/audio_capture_stub.zig`, where every verb returns `error.Unsupported` |
| Synthetic source | `core/capture_synthetic.zig`, driven by the harness (see [harness.md](harness.md)) |

`capture_types` is a **named module linked into both `camera` and `audio`**. A relative
`@import` of the same path from two different modules produces two distinct nominal
types, so sharing it as a named module is what makes `camera`'s and `audio`'s
`DeviceInfo` literally the same type (`core/platform_types.zig` is shared between
`platform` and `harness` for the same reason).

## The verbs

| Verb | Meaning | Type |
|---|---|---|
| `enumerate(allocator)` | list the connected devices | `CaptureError![]DeviceInfo` |
| `requestPermission()` | request permission and return the settled state (blocking) | `CaptureError!PermissionState` |
| `open(allocator, config)` | open a device, negotiating the format internally | `CaptureError!Device` |
| `device.config()` | read the effective values | `EffectiveConfig` |
| `device.start()` | begin capturing | `CaptureError!void` |
| `device.stop()` | stop capturing (a no-op when already stopped) | `void` |
| `device.close()` | dispose of it | `void` |

The camera adds `pollLatestFrame()` for video; the microphone is callback-driven like
audio output and adds nothing.

**The call names are asymmetric on purpose.** `core/audio.zig` already holds the output
`Error`, `Config`, `EffectiveConfig`, `AudioDevice` and `open`, so the microphone side
inserts `Capture` to avoid the collision; `core/camera.zig` is a file of its own and uses
the bare verb names. Unification is defined as the argument and return shapes
(`CaptureError`, `PermissionState`, `EffectiveConfig`) and the semantics matching — not
the function names matching.

| | camera | microphone |
|---|---|---|
| enumerate | `camera.enumerate(allocator)` | `audio.enumerateCaptureDevices(allocator)` |
| requestPermission | `camera.requestPermission()` | `audio.requestCapturePermission()` |
| open | `camera.open(allocator, cfg)` | `audio.openCapture(allocator, cfg)` |
| device type | `VideoDevice` | `CaptureDevice` |
| config types | `camera.Config` / `camera.EffectiveConfig` | `audio.CaptureConfig` / `audio.CaptureEffectiveConfig` |

There is no separate `configure()`. `open(config)` takes the requested values as hints
and negotiates internally, and `device.config()` returns what was actually settled —
the same style as the existing audio output. Renegotiating an already-open device (say
changing resolution while running) is out of scope.

## Lifecycle

`(unopened) → open() → opened → start() → running → stop() → opened → close() → (end)`

Misuse — `start()` while running, `stop()` before starting — is held to the same
strength of contract as the existing audio output: **a double start or stop is ignored**
(`core/audio_null.zig` is the worked example), and no explicit state-machine enum or
error is added. Reusing a device after `close()` is undefined and the caller's
responsibility. There is deliberately no state query such as `isRunning()`, since the
existing audio output has none.

## The allocator contract for enumerate

`enumerate()` returns `[]DeviceInfo` in which **the slice and each `DeviceInfo.id` and
`.name` are all allocated with the allocator passed in**, and the caller owns them.
`capture_types.zig` provides the symmetric `freeDeviceList(allocator, devices)`, and
every backend follows the same allocation convention.

`enumerate()` and `open()` return `CaptureError` only — `std.mem.Allocator.Error` is not
unioned in — so an internal allocation failure is **folded into `error.OpenFailed`**.
This follows the conversion the existing output backends already use. The trade-off is
that the out-of-memory signal is lost, in exchange for keeping `CaptureError` a single
closed error set.

## Permissions and errors

```zig
pub const PermissionState = enum { not_determined, granted, denied, restricted };
pub const CaptureError = error{
    PermissionDenied, NoDevice, DeviceLost,
    ConfigFailed, Unsupported, OpenFailed, StartFailed,
};
```

- **`denied` and `restricted` are distinct.** `denied` means the user refused and can
  change it in a settings application; `restricted` means policy (an MDM profile, say)
  makes it unchangeable. macOS's `authorizationStatus` really does return these four
  values, and a UI needs the distinction to choose between "open Settings" and "this
  cannot be changed", so `restricted` is never folded into `denied`.
- **A silent refusal is never treated as normal.** A privacy toggle can express refusal
  by returning no error and delivering empty or silent data indefinitely. Whenever such
  a refusal is detected it must surface as `PermissionState.denied` or
  `CaptureError.PermissionDenied`; a stream that appears to run while actually feeding
  silence or blank frames forever is not an acceptable success case.
- Microphone and camera share the same `CaptureError` and `PermissionState`. Zig error
  values match by name across declaring error sets, so `error.NoDevice` compares equal
  from either facade.

## The data plane

**Microphone** frames arrive on a real-time callback as one `AudioInFrame` POD struct
(rather than a flat argument list, so that adding a field does not add a parameter).
The callback is bound by the real-time contract — no malloc, locking, IO or panic —
exactly as audio output is; see [audio-and-synth.md](audio-and-synth.md).

**Camera** frames are always normalised to canonical BGRA (`u32` `0xAARRGGBB`), the same
representation as the framebuffer of `core/platform.zig`, so a frame can be fed straight
to the existing sprite and canvas paths. Converting from a native format (YUY2, NV12)
is the backend's responsibility. `PixelFormat` stays an enum with the single variant
`bgra8` so that a future variant can declare a native format for diagnostics.

Video is delivered from the capture thread to the main thread through a **triple buffer,
latest-wins and non-blocking** — not a callback. A capture rate and a draw rate need not
agree (30fps against 60fps), and forcing them to synchronise in a callback pushes the
capture thread into either blocking until the main thread collects or doing lengthy work
inside the callback. `TripleBuffer(T)` lives in `core/capture_types.zig` as a
self-contained copy of the same SPSC three-slot mechanism as `libs/modular`'s `Mailbox`,
because core cannot depend on libs (ADR-007 R2).

- `T` must be a POD or view type, since publishing copies by value. A type owning memory
  that needs `deinit` does not belong in `T`. `VideoFrame` qualifies: its
  `pixels: []const u32` is only a view onto an externally fixed buffer.
- **The producer never writes the read slot** — the three indices are always a
  permutation of `{0,1,2}`. There is one atomic rather than an independent head/tail
  pair, so the cache-line separation rule does not apply (there are not two atomics to
  falsely share).
- A backend **allocates three physical pixel buffers once at `open()`** at the effective
  resolution, and each `VideoFrame.pixels` is fixed to one of them, so nothing is
  reallocated per frame.
- The main side polls without blocking: `VideoDevice.pollLatestFrame() ?VideoFrame`
  returns `null` when no frame has arrived yet, and frames may be dropped. The `pixels`
  it returns stay valid **until the next `pollLatestFrame()` call**.

## The synthetic source

The branch point sits at the head of each facade verb, on
`harness.isCaptureSyntheticActive()` — the same shape as audio output's `open()`
consulting `harness.isHeadlessActive()` to substitute the null device. The synthetic
source replaces the backend outright rather than wrapping it.

Video from the synthetic source is generated deterministically against the harness's
virtual clock, so a replay reproduces it. The synthetic microphone is driven by a
real-time pull thread like `core/audio_null.zig` and is **not** bit-deterministic, which
matches the existing `audio` probe not guaranteeing a bit-identical record-and-replay.

Enabling it follows the same rule as the existing audio: the harness reads its
environment only through `platform.init()`, so a capture-only application that never
calls `platform.init()` always behaves as though the harness were disabled. See
[harness.md](harness.md) for the commands and probes.

## Out of scope

Recording, encoding and writing files; opening several devices at once and watching for
device changes (hotplug); delivering video in a non-BGRA format without conversion; and
a unified API treating microphone and camera in one loop (permanently declined, per the
reasoning at the top).
