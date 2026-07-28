# ADR-008: The frame pacing API (beginFrame/waitFrame) and separating fatal state

**Status:** Accepted (the API shape, state transitions, harness alignment and migration policy are settled; implementing it in every backend is follow-up work)
**Date:** 2026-07-05
**Category:** Platform API, rendering, frame control

## Summary

Settles as a Zig API the two points that
[ADR-005](005_platform-support-tiers-and-frame-pacing.md) deliberately left as
"policy only".

1. Game-grade pacing: `beginFrame(wait)` / `waitFrame(timeout)`, including a
   blocking wait
2. Separating `lockFramebuffer() == null` (frame slot unavailable, retryable) from
   **fatal** (device lost, window destroyed, backend fatal)

**The decision, in short:**

- The new API is added as **`Window` methods**:
  `window.beginFrame(wait: FrameWait) FrameResult` and
  `window.waitFrame(timeout_ns: u64) WaitResult`.
- Null and fatal are separated by the **`FrameResult` tagged union**
  (`.framebuffer(Framebuffer) / .unavailable / .fatal(FatalReason)`).
- **Fatal is sticky state** (one per `Window`, holding the first reason detected).
  **Whichever call path detects it** — `present()` included — it then shows up
  consistently through `beginFrame`, `waitFrame`, `nextEvent` (a `.fatal` event) and
  `pollEvents` (fixed `false`).
- **The current `lockFramebuffer() ?Framebuffer` and `present() void` are unchanged**
  for compatibility. After a fatal, `lockFramebuffer()` keeps returning `null`
  (its signature cannot express fatal). But **`null` alone is never used as the
  fatal notification**: the `.fatal` event from `nextEvent()` and
  `pollEvents() == false` are **always used alongside it** to surface the fatal
  ("degrade to null only", without the event and pollEvents side, is rejected —
  reasons below). **A `null` in the normal state is a retryable frame slot
  unavailable; a `null` after sticky fatal is a terminal "no more frames"**, and the
  authority on the fatal itself is always `nextEvent`/`pollEvents`.
- The harness's `present = frame commit point`, `pollEvents = step gate` and virtual
  clock are **unchanged**. A loop built on `beginFrame(wait)` alone is explicitly
  outside the harness step gate.
- Implementing this in every backend (including making it a no-op on best-effort
  backends), and connecting it to the D3D11 device-lost and waitable-swap-chain
  work, is **follow-up work**.

## Context

- ADR-005 defined the support tiers and the frame pacing contract (frame
  availability, buffer ownership, present semantics, present mode), but left the API
  shape of "pacing with a blocking wait" and "separating null from fatal" to
  follow-up — this ADR.
- Two pieces of work were already filed waiting on this decision: D3D11 device-lost
  recovery ("notifying the caller when recovery is impossible aligns with the fatal
  API") and the D3D11 waitable swap chain ("connect to the beginFrame/waitFrame API
  once it is decided").
- The facade's `Window.lockFramebuffer()` and `Window.present()` have an external
  consumer (`tictactoe`, via a `.path` dependency), so their signature and semantics
  cannot be broken.
- The harness already interposes on the facade's `pollEvents` (the step gate
  `pollGate`), `nextEvent`, `lockFramebuffer` (`onLock`/`onLockMiss`), `present` (the
  frame commit point, `frame_index++` in `onPresent`) and `getTime`
  (`frame_index/60`). The new API has to sit on top of that without breaking
  determinism.

## Terms

| Term | Definition |
|---|---|
| **frame slot unavailable** | A retryable state with no drawable backbuffer right now (defined in ADR-005). Expressed by `FrameResult.unavailable` or the existing `lockFramebuffer() == null`. |
| **fatal** | Device lost, window destroyed, backend fatal error — a state where **continuing is impossible even after attempting recovery**. Retrying does not help. |
| **sticky fatal state** | The "first fatal reason detected", held inside the `Window`. Once set it never returns to `false` or `.unavailable`, and it appears consistently in every later API call. |
| **frame commit point** | The moment `present()` is called (defined in ADR-005; the reference for the harness's `frame_index`). Unchanged here. |
| **manual drawing API** | The path where the caller explicitly acquires and commits a frame: `lockFramebuffer`, `present`, `beginFrame`, `waitFrame`. Distinct from the callback style (`platform_run` / `FrameCallback`). |

## Decision

### 1. The API shape

```zig
pub const FrameWait = enum { nonblocking, wait };

pub const FatalReason = enum {
    device_lost,       // the GPU/drawing device was lost (D3D11 DEVICE_REMOVED/RESET), and recovery failed
    window_destroyed,  // an operation on a window that is already destroyed
    backend_fatal,     // a fatal internal backend error that fits neither of the above
};

pub const FrameResult = union(enum) {
    framebuffer: Framebuffer, // drawable; follows ADR-005's buffer ownership contract
    unavailable,              // frame slot unavailable (retryable; equivalent to the existing null)
    fatal: FatalReason,       // unrecoverable; retrying does not help
};

pub const WaitResult = union(enum) {
    ready,             // a drawable frame slot arrived (does NOT guarantee the next beginFrame(.nonblocking) succeeds; see §3)
    timed_out,         // it did not arrive within timeout_ns
    fatal: FatalReason,
};

/// Added as Window methods, matching the shape of the existing lockFramebuffer/present.
pub fn beginFrame(self: Window, wait: FrameWait) FrameResult;
pub fn waitFrame(self: Window, timeout_ns: u64) WaitResult;
```

**Settled sub-decisions:**

1. **Two functions**: `beginFrame` (wait plus lock, combined) and `waitFrame` (wait
   only, with locking as a separate call) **both exist**, as sketched in ADR-005. The
   caller states "wait or don't" through `FrameWait`, and can also choose to pace with
   `waitFrame` alone and lock with the existing `lockFramebuffer()`.
2. **They are `Window` methods**, matching the existing `lockFramebuffer` and
   `present` (a change from ADR-005's free-function sketch). Called as
   `window.beginFrame(.wait)`.
3. **Event handling while waiting**: a wait **may advance the OS or native event
   queue** (the Wayland frame callback arriving, a macOS runloop tick, the equivalent
   of a Win32 message pump). But a **non-reentrancy contract** applies: a wait must
   not invoke caller callbacks or deliver user-visible events equivalent to
   `nextEvent()`. User-visible events are always observed only through `pollEvents()`
   and `nextEvent()`. A wait is purely a function that returns on one of the next
   frame slot, a timeout, or a fatal.
4. **Timeout semantics**: `timeout_ns: u64`. `0` means "decide ready or timed_out
   immediately", equivalent to nonblocking; `std.math.maxInt(u64)` is effectively an
   infinite wait. **Spurious wakeups are allowed**: the contract states explicitly
   that a `beginFrame(.nonblocking)` immediately after `waitFrame` returned `.ready`
   may still be `.unavailable` (the caller is expected to retry in a loop, because
   neither a D3D11 waitable object nor a Wayland frame callback can rule out spurious
   wakeups).
5. **How best-effort backends degrade**: on objc/swift/X11/GDI a frame slot is always
   available, so `waitFrame` is a **no-op returning `.ready` immediately** and
   `beginFrame(.wait)` returns a framebuffer without waiting. This is consistent with
   ADR-005's tier definition of "pacing not guaranteed".
   - **Performance goal**: the no-op path allocates nothing and does not sleep in real
     time. With the harness disabled, the overhead stays at roughly the same single
     branch as the existing `lockFramebuffer` (one `isEnabled()` check), since it sits
     on the per-frame path.
6. **Relationship to present mode (fifo/immediate)**: not covered here (as in
   ADR-005, only the room to extend is noted).
7. **Lifecycle and state transitions**: defined as a table of rules in the lifecycle
   section below.
8. **Relationship to the C ABI and the callback style**: `beginFrame` and `waitFrame`
   are **for the manual drawing API only**. They are **not exposed** to the callback
   style (`platform_run` / `FrameCallback` in `platform.h`, and the callback argument
   of `platform_create_window`). All three macOS backends (objc/swift/metal) are
   **no-op waits in the initial implementation**, so no new export is needed in
   `platform.h` (the existing manual drawing exports are enough). Giving Metal's
   inflight semaphore wait real meaning inside `beginFrame` would require a new
   export and is treated as an **independent follow-up**, outside this ADR's scope
   (see 5-4).

### 2. How null and fatal are separated

The **`FrameResult` tagged union** (candidate 2 in ADR-005) is adopted.

**Why the others were rejected:**

- `Error!?Framebuffer` (candidate 1): it needs two levels of unwrapping (`try` plus
  `orelse`), and it does not express the states between `.unavailable` and `.fatal`
  (such as `.timed_out` from the wait API) naturally.
- **A fatal event only** (candidate 3, where `lockFramebuffer` stays `?Framebuffer`
  and fatal is reported solely through `nextEvent()`): the new API's return value
  alone could not detect a fatal, leaving it to the caller's discipline of checking
  `nextEvent()` each time. For a brand-new API it is safer to be self-contained in
  the return value.

**Settled sub-decisions:**

1. **Fatal classification**: the three `FatalReason` values (`device_lost`,
   `window_destroyed`, `backend_fatal`). `device_lost` means "the backend attempted
   recovery internally and still cannot continue" (device-lost recovery tries
   best-effort first, and does not raise a fatal at all if it succeeds).
2. **Fatal is sticky state**: the `Window` implementation fixes one internal
   `?FatalReason` when it detects a fatal and never resets it (it lives until
   `Window.destroy()`). Recovery by reconnecting or recreating means creating a new
   `Window`; recovering the *same* `Window` instance from a fatal is out of scope
   here.
3. **A fatal raised by `present()`** (the main detection point for D3D11 device
   lost): D3D11's `DXGI_ERROR_DEVICE_REMOVED`/`RESET` are usually detected during
   operations such as `Present` and `GetBuffer`. The current
   `present(self: Window) void` returns nothing and its signature stays unchanged for compatibility. **When
   `present()` detects a fatal internally, it is recorded in the sticky fatal state**
   rather than returned, so the fatal is then visible consistently from
   `beginFrame`, `waitFrame`, `nextEvent` (a `.fatal` event) and `pollEvents` (fixed
   `false`). This is what makes a present-originated fatal reach the caller through
   the new API, which the device-lost work requires.
4. **Rules for API calls after a fatal** (how the sticky state actually shows up):
   - `beginFrame` / `waitFrame`: return `.fatal(reason)` on every call (the same
     reason however many times it is called; duplicate notification is accepted, and a
     caller wanting to handle it exactly once uses the single `.fatal` event from
     `nextEvent()`).
   - `nextEvent()`: fires a new `Event.fatal: FatalReason` exactly once, immediately
     after the fatal is detected (added to the `Event` union in
     `platform_types.zig`; the implementation is follow-up). It does not fire again,
     and is treated like `.quit` — a notification meant to be consumed once.
   - `pollEvents()`: always returns `false` after a fatal — the same termination
     signal as the ordinary "the window was closed" case, so the caller's main loop
     ends naturally.
   - `lockFramebuffer()` (the old API): **keeps returning `null` after a fatal**. That
     contradicts the existing "retryable" contract, but **used together with**
     `nextEvent()`'s `.fatal` event and `pollEvents() == false`, a caller using only
     the old API can still handle a fatal through the ordinary loop convention of
     "terminate when `pollEvents()==false`". "Degrade to null only" — without the
     `nextEvent`/`pollEvents` side — is **rejected**, because an old caller could then
     mistake the `null` for a plain retryable state and spin forever; the two are
     always provided as a set.
   - `present()`: after a fatal, calling it does not crash and behaves as a no-op (the
     backend does nothing internally).
5. **Sources of fatal per backend** (a table for implementation time; this ADR only
   enumerates them):

   | Backend | Source of fatal |
   |---|---|
   | D3D11 | `DXGI_ERROR_DEVICE_REMOVED`/`RESET` (detected in `Present`, `GetBuffer` and similar; the reason comes from `GetDeviceRemovedReason`) |
   | Wayland | a `wl_display` error (`wl_display_get_error`), or the compositor disconnecting (socket close) |
   | X11 | a fatal I/O error equivalent to `XSetIOErrorHandler` (the display disconnecting) |
   | macOS (objc/swift) | window close and internal CALayer errors (in practice there is no source of fatal today; the classification exists for the future) |
   | macOS (Metal) | asynchronous command buffer errors (`MTLCommandBuffer.error`), or persistent failure to acquire a drawable |
   | GDI | operating on an `hwnd` after it was destroyed |

### 3. Lifecycle state machine (the caller's contract)

The manual drawing state of a `Window` is defined by the following rules — a contract
each backend satisfies, expressed as a table of call-order rules rather than a strict
typestate machine:

| Current state / call | Result |
|---|---|
| `beginFrame`/`lockFramebuffer` while unlocked | normal: returns `.framebuffer`/non-null, or `.unavailable`/null |
| `beginFrame`/`lockFramebuffer` again **while locked** (the previous `Framebuffer` was neither unlocked nor presented) | **not undefined behaviour**: the implementation implicitly invalidates the previous lock and returns a new one (following the behaviour existing backends already have; a double lock is not forbidden, and "the last lock wins"). ADR-005's buffer ownership contract (write rights until `present()`) is unchanged. |
| Acquiring a `Framebuffer`, then calling `unlock()` **without `present()`** | that frame is not committed for display (as defined in ADR-005). The next `beginFrame` may request a new frame slot. |
| Acquiring a `Framebuffer`, then calling `present()` **without `unlock()`** | allowed (`present()` does the necessary cleanup internally; this is the existing code pattern of `lockFramebuffer`/`present`, and `unlock()` is treated as an idempotent operation that is safe to call or omit). |
| **A double `present()`** on the same `Framebuffer` | the second is a no-op (an already committed frame is not re-submitted). It does not become fatal. |
| `beginFrame(.nonblocking)` immediately after `waitFrame` returned `.ready` | **success is not guaranteed** (spurious wakeups are allowed; it may return `.unavailable`, and the caller writes a retry loop). |
| The window closing during a wait (`beginFrame(.wait)`/`waitFrame`) | treated as the ordinary `.quit`, not as `.fatal(.window_destroyed)` — closing a window is a normal termination path, not a fatal, and keeps the same treatment as the existing `Event.quit`. |
| A fatal (device lost and similar) occurring during a wait | the wait function itself returns `.fatal(reason)` (and the sticky state is set at the same time). |
| Any call after a fatal is fixed | follows "rules for API calls after a fatal" above (sticky; the same result however many times it is called) |

### 4. Effect on the harness

1. **How the new API is interposed**: `beginFrame` and `waitFrame` get hooks
   symmetric to `lockFramebuffer` (the equivalents of `onLock`/`onLockMiss` mapped
   onto the branches of `FrameResult`/`WaitResult`). **While the harness is enabled,
   `wait` and `timeout` do not wait in real time and decide immediately**, which keeps
   the virtual clock consistent and replay deterministic. What "decide immediately"
   means differs between headless and non-headless:
   - **Headless** (`KNGN_HEADLESS=1`): the null window never calls a backend, so a frame
     slot is always immediately available (fixed `.framebuffer`/`.ready`).
   - **Non-headless** (a native window with replay or live): `beginFrame` and
     `waitFrame` respect the native backend's lock result as-is and merely **skip the
     real-time sleep or dispatch wait** — the decision is immediate, but the result may
     be `.unavailable` or `timed_out` depending on the native side. Cases where a
     native backend such as Wayland returns null or busy go through the existing
     `onLockMiss`-equivalent hook; a `.framebuffer` is never fabricated.
2. **The condition for advancing `frame_index` is unchanged**: `present()` remains the
   frame commit point. `beginFrame` and `waitFrame` do not advance `frame_index`
   themselves (the same position as the existing `lockFramebuffer`).
3. **How the harness represents fatal**: the harness **does not generate** fatals
   (pass-through only). For replay determinism, a backend-originated fatal is a
   non-deterministic event and is not part of the replay script's `inject`/`expect`
   vocabulary (a `.fatal` event arises only from a native backend and is not on the
   harness's injection path).
4. **Complete pass-through when the environment is unset is preserved**: as with the
   existing four hooks, the new hooks pass straight through when
   `KNGN_HARNESS_SCRIPT`/`LIVE` are unset. The bit-identical `fb` digest must not regress.
5. **A loop built on `beginFrame(wait)` alone is explicitly outside the harness step
   gate**: the step gate (`pollGate`) stays anchored on `pollEvents()`. A caller that
   never calls `pollEvents()` and loops on `beginFrame(.wait)` alone is not covered by
   the harness's replay determinism, and this ADR states that such a caller is out of
   harness scope. **The standard loop order is
   `pollEvents() → beginFrame/waitFrame → draw → present()`**, and existing examples
   and applications are expected to follow it. Moving the step gate to `beginFrame` is
   not adopted here; if it is ever needed, its effect on replay determinism is
   re-evaluated in a separate ADR or follow-up.

### 5. Migration alongside the existing `lockFramebuffer()` path

1. **`lockFramebuffer()` is kept permanently as the nonblocking compatibility path**
   (it is not deprecated), because an external consumer (`tictactoe`) uses it directly
   through a `.path` dependency.
2. **The semantics of `beginFrame(.nonblocking)` versus `lockFramebuffer()`**: before
   a fatal they are exactly equivalent (`.framebuffer`/non-null ↔ `.unavailable`/null,
   one to one). They differ only after a fatal (`beginFrame` can return `.fatal`,
   while `lockFramebuffer` keeps returning `null` and the fatal is surfaced through
   `nextEvent`/`pollEvents` — see the rules above).
3. **Staged breakdown** (the granularity of follow-up work):
   1. Add `beginFrame`, `waitFrame`, `FrameResult`, `WaitResult` and `FatalReason` to
      the facade (`core/platform.zig`) and every backend (macOS objc/swift/metal,
      Linux x11/wayland, Windows gdi/d3d11). Best-effort backends get a no-op wait,
      and fatal is implemented only as far as each backend can detect it (many
      backends will raise no fatal for now, returning only `.framebuffer` or
      `.unavailable`). Add `.fatal: FatalReason` to the `Event` union in
      `platform_types.zig`.
   2. Connect the D3D11 device-lost work to the sticky fatal state and the fatal
      classification here, and the D3D11 waitable swap chain to the actual
      `waitFrame`.
   3. (Optional) Migrate examples and applications to the new API — low priority,
      since existing code needs no changes.
4. **How far this reaches the C ABI (`platform.h`)**: **in the initial stage all three
   macOS backends (objc/swift/metal) are no-op waits**, so no new export is added
   (the existing call pattern of `platform_lock_framebuffer`/`platform_present` is
   enough to implement `beginFrame`/`waitFrame` in the Zig facade and
   `core/platform_macos.zig`). Moving Metal's inflight semaphore wait — currently
   inside `present()` — to become a meaningful wait in `beginFrame` **would add a new
   export** and is treated as an independent follow-up, outside this ADR and outside
   stage 1 (a separate task is filed if it becomes necessary).

## Verification against existing contracts

- **Existing callers need no changes**: the signatures and return values of
  `lockFramebuffer` and `present` are unchanged, so every example, the editor, synth,
  modular, patch, the main program and the external `tictactoe` build and run without
  source changes (the new API is purely additive and changes no existing type).
- **The backends can implement this**: all five backend families can be written
  naturally as a no-op, a partial implementation, or a future connection (see the
  per-backend table and the C ABI policy above).
- **Per-frame overhead**: with the harness disabled it is about one `isEnabled()`
  branch, the same as the existing `lockFramebuffer`. The best-effort `waitFrame`
  no-op neither sleeps nor allocates.
- **Harness determinism**: `present = frame commit point`, `pollEvents = step gate`
  and the virtual clock are all unchanged. The harness does not generate fatals
  (pass-through only), so replay determinism is unaffected.
- **Adequacy as the landing place for the D3D11 work**: the "notify the caller when
  recovery is impossible" requirement is met by the sticky fatal state plus
  `FatalReason.device_lost` plus the `.fatal` event. The "connect to
  beginFrame/waitFrame" requirement is met by the `WaitResult`/`FrameResult` types and
  the shape of the `waitFrame` call.

## Consequences

- [ADR-005](005_platform-support-tiers-and-frame-pacing.md): both the wait/skip
  policy and fatal state policy sections gained a reference to this ADR for the API
  shape, plus a revision-history entry (v1.2), in the same commit as this work.
- `core/platform_types.zig`: adding `.fatal: FatalReason` to the `Event` union is
  documented here as a proposed type definition only; the actual code change is
  follow-up work (this ADR changes no code).
- Adding hooks to `core/platform.zig`, the backends and `core/control/harness.zig` is
  follow-up work (stage 1 above). This ADR itself carries no code change.
- Implementation code (the behaviour and signatures of `lockFramebuffer`/`present`,
  `build.zig`, the facade) is unchanged here.

## Hot-path declaration

This ADR is a design document with no code change (no new per-frame or real-time
loop). The API it settles does sit on a path called every frame from the main loop,
so per-frame overhead — zero allocation and zero sleep on a no-op backend, and
pass-through cost equal to the existing path when the harness is disabled — is
stated explicitly as an evaluation criterion above.

## Revision history

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-07-05 | First version. Settles the beginFrame/waitFrame API shape, separating null from fatal via `FrameResult`, sticky fatal state, the lifecycle rules, harness alignment, and the migration policy alongside `lockFramebuffer`. |
