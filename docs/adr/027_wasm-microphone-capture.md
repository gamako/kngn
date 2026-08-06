# ADR-027: Browser microphone capture on the shared-memory AudioWorklet path

- Status: Accepted
- Date: 2026-08-07
- Scope: how browser wasm packages accept microphone input through the existing
  capture facade, how permission and device listing work under a single-threaded
  host, and how capture shares the AudioWorklet / SharedArrayBuffer infrastructure
  with audio output. The real-time callback contract is
  [015](015_real-time-audio-contract.md); build-time audio **output** transport is
  [018](018_wasm-audio-transport-build-time-selection.md); the capture control plane
  is [docs/capture.md](../capture.md); packaging and deploy are
  [docs/wasm-deploy.md](../wasm-deploy.md).

## Context

Native microphone capture already exists behind `core/audio.zig` (macOS AUHAL,
Linux ALSA, Windows WASAPI) with a shared control plane in
`core/capture_types.zig` and the verbs documented in `docs/capture.md`. Browser
wasm had audio **output** on three build-time transports (ADR-018) but no mic
input path.

Constraints that shape the design:

1. **The browser is single-threaded for the main wasm Instance.** There is no
   dedicated capture RT thread. `getUserMedia` is Promise-based; a true blocking
   `requestPermission()` cannot wait on the JS event loop without freezing the app.
2. **Output already uses a second wasm Instance on SharedArrayBuffer** for
   `worklet_shared` (low-latency render). Capture should not invent a second
   wire protocol if the same graph can carry input.
3. **The public capture facade** (`enumerateCaptureDevices`,
   `requestCapturePermission`, `openCapture`, `start` / `stop` / `close`) and
   its error / permission types are shared with native. Changing the contract for
   wasm must not force a parallel API on three native backends.
4. **Lifecycle** is already
   `open → start → running → stop → (start again) → close`. Stop must not destroy
   everything open established.

## Decision

### 1. Capture rides `worklet_shared`, symmetric with output

Browser mic input is implemented only for packages that select
`audio = .worklet_shared` (and `capture = true` on the package spec). The
AudioWorklet `process()` path copies each mono 128-frame quantum into a fixed
scratch buffer in shared linear memory and calls `kngn_capture_submit`. The main
Instance drains a lock-free ring once per frame (`drainCaptureIfActive`) and
invokes the user `CaptureCallback` on the main-thread frame tick.

This is the same dual-Instance / SharedArrayBuffer model as
`kngn_audio_render` for output, with roles reversed (Worklet produces, main
consumes).

`WasmAppSpec.capture = true` requires `audio = .worklet_shared` at configure
time. Capture needs COOP/COEP for the same reason shared output does.

### 2. Permission is an idempotent poll

`requestPermission()` / `requestCapturePermission()` always returns the current
`PermissionState`. While the value is `not_determined`, permission is still
unsettled; any other value is settled. Callers may poll.

- Native backends settle on the first call (unchanged implementations).
- Wasm starts `getUserMedia` on the first poll from `not_determined`, returns
  `not_determined` while the Promise is in flight, then caches
  `granted` / `denied` / `restricted` (restricted is unused on the web path).

Browser failure mapping (also documented in `docs/capture.md`): `NotAllowedError`
→ always `denied` (no post-hoc split of user vs Permissions Policy);
`NotFoundError` → folded into `denied` on the 0–3 wire codes (no dedicated
`NoDevice` code in the permission enum); pre-call rejection (insecure context,
missing API, policy forbidding the feature) surfaces as `Unsupported` or open
failure rather than a separate permission code.

### 3. Enumerate is not part of the permission poll contract

`enumerate` / `enumerateCaptureDevices` keeps returning a caller-owned
`[]DeviceInfo` filled with the passed allocator (`freeDeviceList` ownership
unchanged). On wasm, each call clones the most recently resolved JS snapshot.
An empty list while permission is unsettled means “not known yet”, not a settled
zero devices; reliable lists are taken after `granted`.

### 4. Capture backend is always linked on wasm; wiring decides availability

On `builtin.cpu.arch.isWasm()`, `core/audio.zig` selects
`core/audio_capture_web.zig` unconditionally (not a comptime “capture on/off”
build option). Whether capture works is decided by JS (`data-capture="true"`,
env imports, MediaStream). This matches `core/audio_web.zig`: transport is a
package/JS concern, not a second Zig branch matrix inside the backend module.

Package validation still enforces `capture=true` only with
`audio=worklet_shared`, and HTML `data-capture="true"` must match the spec.

### 5. Quiescence uses a generation-tagged session

`g_capture_session` is a single atomic: `0` = stopped, non-zero = generation N
running. Each submitted block carries the generation observed at submit time.
`drainCaptureIfActive` delivers only blocks whose generation equals the current
session. `start()` publishes a new generation (and may empty the ring as an
early cleanup); `stop()` stores `0`.

Late Worklet blocks from a previous start/stop cycle are discarded without
reaching the callback.

### 6. Capture ring stays private to the wasm backend

The SPSC ring (`CaptureBlock`, capacity 16, cache-line-separated head/tail) and
drop counter live only in `core/audio_capture_web.zig`. They are not added to
`core/capture_types.zig`, which remains the shared type surface for native and
camera as well.

### 7. Stop disconnects the graph edge; close releases tracks

- `start()` advances the Zig session generation and asks JS to connect
  `MediaStreamAudioSourceNode` → AudioWorklet input.
- `stop()` clears the session and asks JS to disconnect the source **without**
  stopping MediaStream tracks.
- `close()` stops tracks, clears the stream, and participates in AudioContext
  teardown only when output is also closed.

A second `start()` after `stop()` can reconnect without another permission
prompt while the grant and stream remain valid.

### 8. Running intent and open refcount are separate axes

Whether the AudioContext should be running is driven by output and/or capture
**start** intent (capture sets `audioWantRunning` on connect). Whether the
shared AudioContext may be destroyed is a separate open/close refcount: output
`close` skips `kngn_audio_close` while capture is still open, and capture
`close` skips destroying the context while output is still open.

Stopping output alone must not suspend a context that capture still needs.

### 9. Every `worklet_shared` package calls `enableWebAudioExports()`

Shared-memory Worklet boot always uses `kngn_audio_set_sentinel` /
`kngn_audio_check_sentinel` (and stack top / render buffer exports) to prove the
second Instance shares linear memory. Those symbols are kept against DCE only if
the app calls `audio.enableWebAudioExports()`.

Capture-only apps that call only `enableWebCaptureExports()` lose the sentinel
exports and fail boot with `missing kngn_audio_set_sentinel`. Opening audio
output is optional; without `open()` the render path stays idle.

Documented in [docs/wasm-deploy.md](../wasm-deploy.md).

### 10. Automated browser check uses fake media and CDP navigation

Headless verification (`tests/e2e/mic-capture-headless.sh`) packages the web
bundle, serves it with COOP/COEP, runs Chrome with
`--use-fake-device-for-media-stream`, `--use-fake-ui-for-media-stream`, and a
generated sine WAV as fake capture, and asserts state logs (`permission
granted`, `capture started`, stable `captureMismatches=0`).

Navigation is driven through the Chrome DevTools Protocol (and optional
`?e2e=1` POST of log lines) because launching headless Chrome with only a URL
argument does not reliably load the page in all environments.

## Rejected alternatives

**JS `setTimeout` polling that copies from a fixed export buffer into wasm
(outside the Worklet).** Rejected: higher and less predictable latency than a
hardware-paced Worklet quantum, and asymmetric with the existing
`worklet_shared` output protocol (second Instance already on the shared memory
path).

**Make the whole capture facade async (callbacks / futures) for wasm.**
Rejected: would force native macOS/Linux/Windows callers into a second API shape
or a large facade rewrite. Idempotent polling extends the existing
`PermissionState` return type without splitting platforms.

**Fold device enumeration into the same “poll until settled” state machine as
permission.** Rejected: would change the meaning of an empty list and/or the
allocator ownership contract of `enumerate*`. Snapshot clone keeps the type and
ownership rules stable.

**Comptime build option to link `audio_capture_stub` vs `audio_capture_web` on
wasm.** Rejected: `audio_web` does not comptime-branch on transport; transport
is package + JS. Capture follows that precedent—one wasm backend module, host
wiring decides behaviour.

**A boolean “capture active” flag without generation tags.** Rejected: after
`stop`/`start`, a block already in flight or in the ring can carry samples from
the previous session. Generation equality at drain is the quiescence rule.

**Put the capture SPSC ring in `capture_types` next to `TripleBuffer`.**
Rejected: the ring is an implementation detail of the wasm mic backend, not a
cross-backend data-plane type. Widening `capture_types` would imply a public
contract that does not exist on native paths.

**Release MediaStream tracks on `stop()`.** Rejected: would force another
permission / `getUserMedia` cycle for a normal stop→start and would diverge from
the documented open/start/stop/close lifecycle where stop returns to “opened”.

**Tie AudioContext suspend solely to output `stop`, or destroy the context on
the first of output/capture close.** Rejected: either starves capture when
output stops, or tears down the peer path still holding an open device.

**Rely on `rdynamic` alone without `enableWebAudioExports` for capture-only
apps.** Rejected in practice: without a live reference from the app graph, the
sentinel exports are DCE’d and Worklet boot fails.

**Assert capture health only by manual browser clicking.** Rejected for
regression: fake media flags plus scripted navigation give a repeatable gate
(alongside the micro-benchmark for the Zig submit path).

## Consequences

- Mic capture on wasm requires `worklet_shared`, COOP/COEP, and
  `data-capture="true"` aligned with `WasmAppSpec.capture`.
- Apps poll `requestCapturePermission` until settled, then `openCapture` /
  `start`, and call `drainCaptureIfActive` at the start of each frame.
- `CaptureCallback` on wasm runs on the main-thread frame tick under the same
  no-malloc / no-lock / no-IO / no-panic rules as native (execution context
  differs; rules do not)—see `docs/capture.md` and the `AudioInFrame` docs.
- Output and capture may share one AudioContext; open/close refcounting and
  start/stop running intent must both be respected in Zig and JS.
- Every `worklet_shared` app (including capture-only demos) must call
  `enableWebAudioExports()` from the wasm entry / init path.
- Headless e2e under `tests/e2e/` is the scripted smoke for the full stack;
  `zig build bench-capture-ring` measures Zig-side submit cost only.

## Related

- [docs/capture.md](../capture.md) — control plane verbs, permission poll, data plane
- [docs/wasm-deploy.md](../wasm-deploy.md) — transports, COOP/COEP, `enableWebAudioExports`
- [ADR-015](015_real-time-audio-contract.md) — RT region rules
- [ADR-018](018_wasm-audio-transport-build-time-selection.md) — output transport build choice
- `core/audio_capture_web.zig` — wasm backend (ring, session, exports, facade)
- `web/kngn.js` / `web/kngn-worklet.js` — env imports, Worklet copy path
- `tests/e2e/mic-capture-headless.sh` — automated browser check
