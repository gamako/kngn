# ADR-005: Platform support tiers and the frame pacing contract

**Status:** Accepted (the decision is accepted; the D3D11-DXGI backend and Metal first-class pacing are implemented; `beginFrame` / `waitFrame` and fatal-state separation remain follow-up — see Follow-up ④)
**Date:** 2026-06-27
**Category:** Platform strategy, rendering, frame control

## Summary

With games in mind, this defines **support tiers** for platform backends (a
hierarchy of what is guaranteed) and the **frame pacing / vsync / buffer ownership
contract** shared by first-class backends.

**The decision, in short:**

- Backends fall into two tiers.
  - **First-class backends**: macOS **Metal**, Windows **D3D11-DXGI**, Linux
    **Wayland**. Frame pacing (fifo), buffer ownership and present semantics are
    aligned for game use, and avoiding tearing is guaranteed.
  - **Best-effort backends** (compatibility backends): macOS **CALayer**
    (objc/swift), Linux **X11**, Windows **GDI**. They present the same API shape,
    but strict vsync, low jitter, freedom from tearing and frame latency control are
    **not guaranteed**.
- `present()` is a **non-blocking operation and the frame commit point** that
  submits the most recently locked frame to the display queue (keeping the
  non-blocking stance of [ADR-002](002_present-blocking-behaviour.md)).
- Frame pacing is not expressed by blocking in present. It is expressed by **frame
  availability** (a successful `lockFramebuffer()`) and, in future, by
  **`beginFrame(wait)` / `waitFrame(timeout)`**.
- `lockFramebuffer() == null` means a retryable **frame slot unavailable**.
  **Fatal** conditions (device lost, window destroyed, backend fatal) are reported
  through a **separate path**.
- This ADR **supersedes** [ADR-004](004_platform-support-strategy.md) (the strategy
  of excluding X11).

> **Scope of this ADR**: the **definitions** of the contract, the policy and the
> tiers. The D3D11-DXGI backend and Metal first-class pacing have since been
> **implemented** (see Follow-up ①–② and the per-backend sections). Implementing
> `beginFrame`/`waitFrame` and the fatal-separation API in Zig remains
> **follow-up** (Follow-up ④; the API shape is settled in
> [ADR-008](008_frame-pacing-api-and-fatal-state.md)). The signature and behaviour
> of the current `lockFramebuffer() ?Framebuffer` and `present()` are unchanged
> here.

## Context

- [ADR-002](002_present-blocking-behaviour.md) was decided when only the macOS
  backend existed: present is non-blocking, rate control is the caller's `sleep`
  responsibility, and tearing does not occur (because the window server and GPU swap
  at vblank). Since then the X11, Wayland and Windows GDI backends were implemented
  and the premises widened.
  - **Wayland** already returns `null` from `lockFramebuffer()` (the frame callback
    has not arrived, or both buffers are busy before `wl_buffer.release`). That
    exists to hold back a busy loop's flood of presents at the rate of the frame
    callback, and it is a meaning that does not appear in ADR-002's "present is
    simply non-blocking" model.
  - **X11 and GDI** blit without waiting for vblank, so tearing appears at high
    frame rates (a reduction for X11 is planned as best-effort work).
  - **Metal** does `commandBuffer.present(drawable)+commit` without
    `waitUntilCompleted`, but there is no explicit pacing contract for drawables and
    inflight buffers, and no clean handling of the CAMetalLayerDrawable lifecycle.
- [ADR-004](004_platform-support-strategy.md) decided to leave Linux/X11 out for the
  time being, but X11, Wayland and Windows GDI are all implemented now, so that
  premise is reversed.
- As Windows moves to D3D11-DXGI, macOS to Metal and Linux to Wayland as the
  intended targets, those three need an aligned frame pacing contract as
  **first-class backends**, with the remainder explicitly marked best-effort.

## Terms

| Term | Definition |
|---|---|
| **first-class backend** | A backend where frame pacing (fifo), buffer ownership and present semantics are guaranteed for game use: Metal, D3D11-DXGI, Wayland. |
| **best-effort backend** (compatibility backend) | A backend presenting the same API shape without guaranteeing strict vsync, low jitter, freedom from tearing or frame latency control: CALayer objc/swift, X11, GDI. |
| **frame availability** | "May this frame be drawn now?" Drawing is allowed only when `lockFramebuffer()` succeeds (returns non-null). |
| **frame slot unavailable** | A retryable state in which no drawable backbuffer or frame slot exists right now, expressed by `lockFramebuffer() == null`. Not fatal. |
| **present = submit** | `present()` is the non-blocking operation that sends the most recently locked frame to the display queue. It does not wait for display refresh. |
| **frame commit point** | The moment `present()` is called. The frame to be displayed is fixed, and it is the reference point for the verification harness's frame index, snapshots and digests. |
| **buffer ownership** | The right to write to the pixels obtained by locking. After present it passes to the backend, the compositor or the GPU. |
| **fifo / immediate** | Present modes. fifo synchronises with display refresh (no tearing; the standard for games); immediate submits as soon as possible (low latency, for benchmarks; tearing is accepted or OS dependent). |

## Support tiers

| Tier | Backend | Tearing avoided | Frame pacing (fifo) | Low jitter / frame latency control | Notes |
|---|---|---|---|---|---|
| **first-class** | macOS Metal | guaranteed | guaranteed | goal | promoted (triple slot + inflight semaphore) |
| **first-class** | Windows D3D11-DXGI | guaranteed | guaranteed | goal | implemented (`core/platform_windows_d3d11.zig`; `-Dplatform=d3d11`; GDI remains the Windows default) |
| **first-class** | Linux Wayland | guaranteed by the compositor | already achieved, paced by the frame callback | compositor dependent | frame availability already implemented |
| **best-effort** | macOS CALayer (objc/swift) | left to the window server (effectively absent) | not guaranteed | not guaranteed | CADisplayLink runs underneath, but there is no explicit contract |
| **best-effort** | Linux X11 | **not guaranteed** (can occur) | not guaranteed | not guaranteed | best-effort reduction planned |
| **best-effort** | Windows GDI | **not guaranteed** (can occur) | not guaranteed | not guaranteed | software blit; migrating to D3D11 |

Each OS's **first-class backend is the intended target**, and the best-effort
backends remain for portability, as a compatibility path, and for headless
verification. Tiers correspond to the build-time backend selection (`-Dplatform`),
but this ADR defines what a tier **means** (what is guaranteed); it changes no build
wiring.

## The frame pacing contract (shared by first-class backends)

1. **Frame availability**: only a frame for which `lockFramebuffer()` succeeded
   (non-null) may be drawn.
   - `null` is a retryable frame slot unavailable (below).
   - On `null` the caller skips drawing that frame and can pump `pollEvents()` and
     wait for the next opportunity.
2. **Buffer ownership**: the `Framebuffer.pixels` returned by `lockFramebuffer()` is
   a temporary view, writable only until `present()`.
   - After `present()` the caller must neither read nor write those pixels.
   - After `present()` the backend owns the buffer until the display queue, the GPU
     or the compositor is done with it. Before reuse it satisfies a backend-specific
     completion condition (Wayland: `wl_buffer.release`; D3D11: present and frame
     latency completion; Metal: command buffer and drawable/inflight completion).
     Double buffering at minimum; triple or inflight where needed.
3. **Present semantics**: `present()` is the non-blocking operation and frame commit
   point that submits the most recently locked frame to the display queue. It does
   not necessarily wait for display refresh (a brief block is acceptable under
   resource pressure or because of an OS API). A frame unlocked without a present is
   not considered committed for display.
4. **Present mode**: the design allows at least the two concepts `fifo` and
   `immediate`. The initial implementation may support `fifo` alone, but the API and
   this ADR leave room to extend (`mailbox` and similar are not defined here).

   ```zig
   pub const PresentMode = enum {
       fifo,      // synchronised with display refresh. No tearing. The standard for games.
       immediate, // submit as soon as possible. Low latency / benchmarks. Tearing accepted or OS dependent.
   };
   ```

   Roughly: Wayland `fifo` = allow the next frame availability from the
   `wl_surface.frame` callback; D3D11 `fifo` = DXGI `Present(1, 0)` plus frame
   latency management; Metal `fifo` = display sync, drawable pacing and an inflight
   semaphore.
5. **Resize contract**: the `Framebuffer.width/height` returned by a successful
   `lockFramebuffer()` is **authoritative for that frame's buffer dimensions**. The
   caller checks `fb.width/height` every frame for the drawable size. **GUI layout uses
   logical size** (`fb.logical_size` or `window.logicalSize()`), not `fb.width/height`,
   under `.physical` mode — see [ADR-011](011_high-dpi-coordinates-and-fb-modes.md) R2.
   After a resize the old framebuffer pointer is invalid. The backend recreates the swap
   chain, `wl_buffer` or Metal texture at a frame boundary and never returns a stale
   pointer to the caller. (D3D11 implements this through `resizeSwapChain` /
   `ResizeBuffers`, and the X11 and Wayland backends track size changes; device-lost
   recovery remains follow-up work.)

   **What the caller owes in return.** A size change is committed at exactly one point —
   the `lockFramebuffer()` boundary — and that is what lets the backend guarantee the
   above. Two obligations follow, and a caller that breaks either can be handed a freed
   buffer:
   - `fb.pixels` is valid until the next `lockFramebuffer()` and is never cached across
     frames.
   - The event pump is not run while a `Framebuffer` is held. `pollEvents()` between a
     lock and its `present()` is out, and so is anything that pumps on the caller's
     behalf — which is why an application that pumps while holding a lock cannot register
     a live-resize redraw callback (`core/platform.zig`).

## Wait/skip policy, and beginFrame / waitFrame

- **The current `lockFramebuffer() ?Framebuffer` is the non-blocking compatibility
  path.** It organises availability, ownership and submit semantics; on its own it is
  not game-grade frame pacing.
  - It returns a `Framebuffer` when a drawable buffer exists and `null` otherwise.
    The caller chooses to skip, poll, sleep, or gate on a harness step.
- **Game-grade pacing is designed as `beginFrame(wait)` / `waitFrame(timeout)`**,
  which include a blocking wait. The caller **deliberately chooses** to wait or not
  (skip), and single-threaded code gets a path that can wait.

  ```zig
  pub const FrameWait = enum { nonblocking, wait };
  pub fn beginFrame(window: Window, wait: FrameWait) ?Framebuffer;
  pub fn waitFrame(window: Window, timeout_ns: u64) bool;
  ```

  Expected implementations: Metal — wake the main loop via the display link,
  drawable availability or a semaphore; Wayland — wait for the frame callback in the
  event dispatch; D3D11 — `Present(1,0)` or a frame latency waitable object.
- **Scope**: the above is **policy** in this ADR. Adding and implementing the Zig
  API is **follow-up**. The migration keeps the current `lockFramebuffer()`
  compatibility path while layering a game-oriented pacing API above it.

> **The API shape is settled in [ADR-008](008_frame-pacing-api-and-fatal-state.md)**
> (`Window.beginFrame(wait) FrameResult` / `Window.waitFrame(timeout_ns) WaitResult`
> as methods, plus the lifecycle rules and harness alignment).

## Fatal state policy — separating null from fatal

`lockFramebuffer() == null` means **frame slot unavailable (retryable)** only and is
**never used for fatal**. Device lost (D3D), a destroyed window and backend fatal
errors need a separate channel. The current API (`?Framebuffer`) cannot express
fatal, so this ADR **decides the policy only** and leaves the API shape to
follow-up.

Candidates (one to be chosen in follow-up):

- `Error!?Framebuffer`: `error.DeviceLost` and friends are errors, `null` is frame
  slot unavailable, non-null is drawable.
- `FrameResult` (a tagged union): one value returning
  `.framebuffer / .unavailable / .fatal`.
- **A fatal event**: `lockFramebuffer()` returns only null or non-null, and fatal
  arrives as an event from `nextEvent()` (for example `.device_lost`, or the existing
  `.quit`).

Whichever is chosen, the condition is that the fatal path is added **without
breaking the current `?Framebuffer` compatibility path**, to avoid breaking the API
later.

> **The separation is settled in
> [ADR-008](008_frame-pacing-api-and-fatal-state.md)**: a `FrameResult` tagged union
> plus sticky fatal state. The old `lockFramebuffer()` keeps returning `null` after a
> fatal, while `nextEvent()`/`pollEvents()` surface it.

## Per-backend differences

### Wayland — null from the frame callback and busy buffers

The existing Wayland backend (`core/platform_linux_wayland.zig`) already returns `null`
from `lockFramebuffer()` when: not yet
configured, closing, or already locked; `frame_pending` and before the deadline (the
`wl_surface.frame` callback has not arrived); or both buffers are busy
(`wl_buffer.release` has not arrived). That implementation holds back a busy loop's
flood of presents at the rate of the frame callback (effectively compositor vsync),
and it is hereby recognised as **the existing worked example** of this ADR's frame
availability and frame slot unavailable semantics (a `frame_timeout_secs` fallback
recovers a dropped callback). Wayland already satisfies fifo pacing for a first-class
backend in practice.

### Metal — meeting the first-class frame pacing contract (implemented)

Before this work, `present()` copied the CPU framebuffer into a texture and called
`commandBuffer.present(drawable)` and commit without `waitUntilCompleted`. There was
no explicit pacing contract for drawables and inflight buffers, and the manual
present path touched `currentDrawable` outside `MTKView.draw(in:)`, leaving a
CAMetalLayerDrawable lifecycle warning.

`platform/macos-metal/platform_macos_metal.swift` was then brought into line with
this contract:

- **The drawable lifecycle warning is gone**: acquiring the drawable and the render
  pass descriptor, and presenting, happen only inside MTKView's proper draw cycle
  (`draw(in:)`). Manual drawing goes `present()` → `presentManual()`, which starts
  `view.draw()` and so calls `draw(in:)` exactly once (manual mode sets
  `isPaused = true`). `currentDrawable` is never touched outside the draw cycle.
- **Inflight ownership is explicit**: CPU pixels plus texture are held in a ring of
  **three slots**, with a `DispatchSemaphore` (value = slotCount - 1 = 2) capping
  inflight frames at two. Each present `wait()`s, and the command buffer's completion
  handler `signal()`s. A presented slot is owned by the backend until the GPU is
  done. Safe reuse holds without per-slot flags, thanks to in-order completion on
  Metal's single command queue plus the semaphore — Apple's standard triple-buffer
  idiom (the detailed invariants are in the comment at the top of that source file).
- **fifo pacing**: `commandBuffer.present(drawable)` (displayed at the next vsync)
  plus an explicit `CAMetalLayer.displaySyncEnabled = true` plus the inflight cap
  above. Even a busy loop stays pinned to display refresh (~60fps).
- **`lockFramebuffer()`**: non-null compatibility is preserved (a slot is always
  obtainable thanks to the ring plus semaphore). Gating frame availability with
  `null`, `beginFrame`/`waitFrame`, and separating fatal state were out of scope for
  that work and are left to the follow-up policy in the two sections above.

### D3D11-DXGI — implemented as Windows' first-class backend

Windows keeps GDI as a best-effort software blit and selects D3D11-DXGI with
`-Dplatform=d3d11` (`core/platform_windows_d3d11.zig`; the Windows default remains
GDI). The D3D11 backend meets this contract via an **upload path**:
`UpdateSubresource` (CPU backing → a DEFAULT texture) → `CopyResource` (→ the swap
chain backbuffer) → `IDXGISwapChain.Present(1, 0)` (fifo submit). Canonical BGRA
needs no conversion (`DXGI_FORMAT_B8G8R8A8_UNORM`). Window, input, dialogs,
`getTime`, the event queue and the CPU backing are shared with GDI through
`core/platform_windows_common.zig`. Remaining gaps called out in that source (lost-device
recovery, a waitable swap chain / frame-latency waitable object, and
`beginFrame`/`waitFrame`) are still follow-up; they do not change the tier
assignment.

### GDI / X11 / CALayer — what is not guaranteed

For best-effort backends the following are explicitly **not guaranteed**:

- Strict vsync synchronisation
- Low jitter (stable frame intervals)
- Freedom from tearing (X11 and GDI blit without a guard and can tear; CALayer is
  left to the window server and effectively does not tear, but the contract does not
  guarantee it)
- Frame latency control and inflight buffer management
- Gating frame availability via `lockFramebuffer() == null` (X11, GDI and CALayer
  currently always return non-null, so the caller must pace itself with `sleep` or a
  fixed timestep)

These non-guarantees are documented for users in `AGENT.md` (the platform backends
table and the support-tier summary) and in
[docs/platform-verification.md](../platform-verification.md).

## Migrating Windows from GDI to D3D11-DXGI, and coexistence

- **GDI stays as a best-effort backend** (it is not removed). It is useful as a
  software framebuffer, for portability, and as a stepping stone for headless
  verification. It remains the **Windows default** (`-Dplatform=gdi`).
- **D3D11-DXGI is Windows' first-class backend** and is selected with
  `-Dplatform=d3d11` (opt-in; implemented in `core/platform_windows_d3d11.zig`).
- The canonical pixel format is already BGRA on every OS, so uploading a CPU
  framebuffer into a D3D11 texture needs no conversion.
- The public API shape (`lockFramebuffer`, `present`, events, `getTime`) is
  unchanged, and the D3D11 backend sits as one implementation behind the facade
  dispatcher — the same pattern as the Linux x11/wayland dispatcher.
- The original implementation breakdown (device / swap chain / upload path;
  BGRA present = submit; fifo present; resize and device-lost handling) is largely
  done. Remaining gaps (lost-device recovery, a waitable swap chain) are noted in
  the D3D11 source header and do not reopen the tier decision.

## Alignment with the verification harness

> **Premise**: the harness (`core/control/harness.zig`, plus wrapping the facade) is merged.
> `core/platform.zig` is no longer a pass-through re-export but a thin wrapper that
> interposes on
> `pollEvents`, `nextEvent`, `lockFramebuffer`, `present` and `getTime`, passing
> straight through only when its environment variables are unset. This section
> confirms that the merged harness and this contract agree.

The harness interposes on the facade's `pollEvents`, `nextEvent`,
`lockFramebuffer`, `present` and `getTime`. This contract keeps the harness's replay
determinism (frame index, virtual clock, digests) intact as long as:

- `present()` remains the **frame commit point** (the harness takes an owned copy of
  the framebuffer there and increments the frame index; the virtual clock is
  `getTime = frame_index/60`).
- On `lockFramebuffer() == null` the harness does not re-copy a stale frame via
  `onLockMiss()` (the frame index still advances). That matches the frame slot
  unavailable semantics here.
- Making buffer ownership after present stricter does not conflict with the harness
  taking its owned copy **just before** present.

**A future decision point**: if `beginFrame()` / `waitFrame()` are introduced, revisit
whether the synchronisation point for frame progress (the step gate) stays on
`pollEvents()` or moves to the frame boundary (beginFrame/present). Either keep
"present = the frame commit point and the condition for advancing the frame index"
unchanged, or define separately how to migrate without breaking replay determinism.

> **A constraint on real code**: the harness is now a real hook in `core/platform.zig`,
> not a design. If backend work changes the behaviour, the signatures, or the condition
> for advancing the frame index of `present` or `lockFramebuffer`, then **the hooks in
> `core/control/harness.zig` (`onLock`, `onLockMiss`, `onPresent`, `pollGate`, the virtual clock)
> must follow in the same change**. Pass-through when the environment is unset, and replay
> determinism (bit-identical framebuffers), must not regress.

## Alignment with X11 vsync work

Synchronising the X11 backend to vsync and removing its tearing is positioned as
**reducing tearing and improving a best-effort backend, not as the frame pacing
guarantee of a first-class backend**. Whether it is implemented with the X Present
extension or with a frame rate cap, X11 is **not promoted** to first class. That
work's requirement that "the caller-driven contract of the public drawing API
(lockFramebuffer/present) is unchanged" agrees with this ADR.

## Follow-up

This ADR goes as far as defining the contract, the policy and the tiers. The
following were filed as follow-up work:

1. **The D3D11-DXGI first-class backend** (coexisting with GDI; making Windows first
   class). **Done** — `core/platform_windows_d3d11.zig`, selected with
   `-Dplatform=d3d11` (GDI remains the Windows default).
2. **Bringing the Metal backend in line with the first-class frame pacing contract**
   (removing the CAMetalLayerDrawable warning; drawable and inflight ownership; fifo
   pacing). **Done** — see the Metal section above (revision 1.1).
3. **Documenting the non-guarantees of best-effort backends** for users (README,
   AGENT.md, docs). **Done** — `AGENT.md` (platform backends table and tier
   summary) and [docs/platform-verification.md](../platform-verification.md).
4. **Designing `beginFrame` / `waitFrame` and the fatal-state separation API** (the
   home for the two policies above). **Still open for implementation** — the API
   shape is settled in [ADR-008](008_frame-pacing-api-and-fatal-state.md); backends
   have not yet grown `beginFrame` / `waitFrame`.

## Consequences

- [ADR-002](002_present-blocking-behaviour.md): reorganised so that present is a
  non-blocking submit and the frame commit point, with the detailed contract
  delegated to this ADR (revised).
- [ADR-004](004_platform-support-strategy.md): superseded (its X11 exclusion
  strategy is the reverse of the implementation).
- Comments brought into line with this contract: `platform/platform.h` (the present
  and lockFramebuffer comments), `AGENT.md` (the manual drawing section),
  `examples/01_timed_window/README.md`.
- The public signatures of `present` and `lockFramebuffer` stay as they were when
  this ADR was accepted. First-class pacing for Metal and D3D11, and the
  best-effort documentation, are now in place (Follow-up ①–③). Implementing
  `beginFrame` / `waitFrame` remains Follow-up ④.

## Caller-side target period (refresh follow + rate cap)

The pull-loop target period is no longer a fixed `1/60`. After `Window.create`,
`core/app_runtime.zig` queries `platform.displayRefreshHz()` **once** (event-time; never
inside the frame loop) and computes

```text
period = 1 / min(refresh_hz, cap_hz)
```

via `frame_pacing.targetPeriodS`. Cap selection:

1. **`-Dframe-cap=<Hz>`** (build option) wins when set.
2. Otherwise `App.frame_period_s` is treated as the period fallback
   (`cap = 1/period`; default `1/60`; `<= 0` disables pacing).
3. Runtime mutation (`setFrameCap`, Preferences) is **not** provided — comptime /
   build-time only keeps learning-state reset trivial (`pacer.reset` on `platform.init`).

wasm is paced by rAF and ignores the native cap option.

### Overshoot estimate hold vs utilisation

`MAX_EST_NS` (the EWMA hold ceiling) is **64ms**, so long periods (e.g. 10fps) can keep a
learned overshoot proportional to timer slack. Each `decide` call utilises at most
**one quarter of the target frame period** (`period_ns / 4`, learned from consecutive
deadlines; falls back to `remaining_ns / 4` on the first frame or after a discarded
delta). A 60fps period therefore still spends at most ~4.17ms on correction — matching
the historical hard 4ms ceiling even when work has already consumed part of the remainder.

### Display refresh query

| Backend | Source | Failure → |
|---|---|---|
| macOS objc / swift / metal | `NSScreen.maximumFramesPerSecond` via `platform_display_refresh_hz` | facade 60Hz |
| Windows GDI / D3D11 | `GetDeviceCaps(VREFRESH)` on the primary DC | facade 60Hz |
| Linux X11 | XRandR current rate via **`std.DynLib` (`libXrandr.so.2`)** | facade 60Hz |
| Linux Wayland | first `wl_output.mode` with `WL_OUTPUT_MODE_CURRENT` (mHz→Hz) | facade 60Hz |
| headless / manual clock / missing decl | no native query | facade 60Hz |

**XRandR is deliberately not linked.** Linking `Xrandr` would push a new system-library
requirement into `build_helpers/` standalone builds and into external consumers that
depend on this package via `.path` and link their own platform stack. Runtime `dlopen` of
`libXrandr.so.2` keeps the link graph unchanged; a missing library or symbol yields
`null` and the 60Hz facade fallback.

The cache lives in `core/platform.zig` (same main-thread ownership as the pacer).
`init` / `shutdown` invalidate it. **Known limits:**

- Moving the window to another display does not re-query refresh.
- Windows `GetDeviceCaps` and X11's default screen may not match the monitor that
  currently hosts the window (multi-monitor).
- Wayland uses the first valid current mode, not a window-local output.
- A cap that is not an integer divisor of refresh produces judder; the runtime logs a
  one-shot warning. Recommended caps on a 60Hz display: 60 / 30 / 20 / 15 / 12 / 10.
  The warning is about the *evenness* of display intervals, not the average rate:
  measured on a 60Hz display, caps of 24, 25 and 40Hz each reach their rate within 1.2%
  (see the frame-cap table in
  [../performance-measurement.md](../performance-measurement.md)).
- Caps in the 10–30Hz range reduce input responsiveness; they are for power saving, not
  interactive editing.

## Revision history

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-06-27 | First version. Defines the support tiers and the frame pacing contract. Supersedes ADR-004, revises ADR-002. |
| 1.1 | 2026-06-28 | The Metal backend meets the first-class frame pacing contract (triple slot + inflight semaphore; the drawable warning removed by keeping everything inside `draw(in:)`; `displaySyncEnabled` set explicitly). The tier table and the Metal section updated to implemented. |
| 1.2 | 2026-07-05 | Added references to [ADR-008](008_frame-pacing-api-and-fatal-state.md) from the wait/skip policy and fatal state policy sections, now that the API shape and the separation are settled. The decision itself is unchanged. |
| 1.3 | 2026-07-27 | Status / tier table / D3D11 section / Follow-up ①–③ updated to match the implemented D3D11 backend and the documented best-effort non-guarantees. Follow-up ④ and the decision itself are unchanged. |
| 1.4 | 2026-07-27 | Resize contract wording distinguishes buffer dimensions (`fb.width/height`) from GUI layout size (`logical_size` / `logicalSize()`), citing [ADR-011](011_high-dpi-coordinates-and-fb-modes.md). The decision itself is unchanged. |
| 1.5 | 2026-07-29 | Caller-side target period: display-refresh follow, `-Dframe-cap`, 64ms EWMA hold with period/4 utilisation (remaining/4 only when the period is unknown), XRandR via DynLib, and known multi-monitor / judder / input-latency limits. |
| 1.6 | 2026-08-02 | Resize contract states what the caller owes: `fb.pixels` is not cached across frames, and the event pump is not run while a `Framebuffer` is held — the obligations the single lock-boundary commit point rests on. The conditional "once resize is supported" is dropped, resize being implemented on every backend. The decision itself is unchanged. |
