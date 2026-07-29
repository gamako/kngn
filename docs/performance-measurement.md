# Measuring performance

The rules themselves are in the "Performance rules" section of `AGENT.md`. This document
holds the measurement procedures and the measured data behind them.

## Measuring the application's real frame rate (required alongside a microbenchmark)

A microbenchmark contains none of the presentation cost (CGImage, ColorSync and the
like). **Always also measure the real frame rate at which the application goes from
drawing to submitting a `present()`.** There is a worked example of getting this wrong:
every microbenchmark stayed green while the real frame rate on hardware halved, and it
went unnoticed. Take the difference in `frame` from `digest stats` under free-run (the
real-time clock):

```bash
KNGN_HARNESS_LISTEN= KNGN_HARNESS_PORT_FILE=/tmp/x.port KNGN_HARNESS_SKIP_FRAME_COPY=1 \
  zig build run-pixie -Doptimize=ReleaseFast &
until [ -s /tmp/x.port ]; do sleep 0.1; done         # wait for the port file to appear
sleep 5                                              # warm up
scripts/kngn ctl --port-file /tmp/x.port 'digest stats'  # first reading
sleep 10
scripts/kngn ctl --port-file /tmp/x.port 'digest stats'  # second reading; (frame difference) / (elapsed seconds) = fps
scripts/kngn ctl --port-file /tmp/x.port 'quit'          # always quit (never pkill)
```

- `frame` is **the number of `present()` calls** (present is a non-blocking submit, per
  ADR-002 and ADR-005). It is not the number of times the compositor actually displayed
  anything. **Ignore `virtual_fps`** in the same JSON: it is a fixed value derived from
  the virtual clock.
- `KNGN_HARNESS_SKIP_FRAME_COPY=1` is a measurement-only mode that excludes the harness's
  per-present copy, and **`digest fb` cannot be taken in the same run** (check the
  framebuffer dimensions in a separate run without the skip).

### Three conditions to align before comparing fps

There is a worked example of drawing the wrong conclusion by not aligning these.

1. **The optimisation mode**: `zig build run-*` defaults to **Debug**. Measured on the
   editor with objc on retina at a framebuffer of 3024x1744: Debug gives 27.9fps against
   ReleaseFast's 101fps (about 3.6x). **Interactive checks and performance measurements
   that expect 60fps must use `-Doptimize=ReleaseFast`** (the ratio varies by application
   and conditions, so measure it each time).
2. **The actual framebuffer size**: record the `WxH` from `digest fb` (the editor's size
   changes with its persisted window state).
3. **Whether there is a display**: `KNGN_HEADLESS=1` has no present cost and a 1x
   framebuffer, so it is an order of magnitude away from an on-screen `.physical` 2x
   (the same window measured ≈1020fps headless at 1x against ≈101fps on-screen at 2x).
   Never mix them in a comparison.

## Frame pacing: a low fps is not necessarily a drawing cost

A fixed sleep (`platform.frameDelay(16ms)`) does not subtract the frame's work time, so
`fps = 1/(work + 16ms + the OS timer slack)`. The patch canvas measured 41.8fps at 2x
even though its drawing work was only 5.9ms. **Applications use
`platform.framePaceUntil(frame_t0 + 1.0/60.0)`** — a deadline plus learned overshoot.
Measured: the patch canvas with objc went 41.8 → 60.1fps, with metal 37.0 → 60.4fps, and
the synth 44.2 → 58.7fps.

- **An application using `core/app_runtime.zig` (`Runtime(App)`) has pacing owned by the
  runtime** (the editor and the synth). The period is
  `1 / min(displayRefreshHz(), cap)` computed once after `Window.create`. Cap comes from
  `-Dframe-cap=<Hz>` when set, otherwise from `App.frame_period_s` (default `1/60`; `0`
  disables pacing). Such an application does not call `framePaceUntil` itself.
- **An application with its own main loop** (the patch canvas) calls it itself: take the
  frame start `frame_t0` at the top of the loop and **register
  `defer platform.framePaceUntil(...)` before `lockFramebuffer`**. That way an early
  return or `continue` when `lockFramebuffer() == null` still waits exactly once (so it
  does not become a busy loop), and defer's LIFO order means the wait happens after
  `fb.unlock()` (never sleeping while the framebuffer is locked).
- **Both relative and absolute OS sleeps overshoot the requested time.** On macOS the
  timer slack is about 20% of the request: a 16.67ms request overshoots by 3.4ms on
  average, giving 49.8fps. The absolute `mach_wait_until` behaves the same.
  `framePaceUntil` learns the measured overshoot with an EWMA and subtracts it from the
  request (it does not busy-wait). The pure logic is `core/frame_pacing.zig`
  (`test-frame-pacing`).
- The contract is "**the caller adds no fixed period and waits only for what remains of
  the deadline**". Time a backend spent waiting (on vsync and so on) counts towards the
  elapsed time since the frame start and is subtracted from the remainder, so even a
  first-class backend (metal, D3D11, Wayland) lands near the target period.
  **"The backend waits first" is not a guarantee**: measured on metal, present did not
  block and the caller waited 9.6ms on average to produce 60.4fps (the real OS wait was
  11.0ms at p95, with one sleep call per frame).
- `frameDelay` (a fixed sleep) remains for compatibility but **is not used in new code**.
  The examples use deadline pacing (`framePaceUntil`), except `examples/30_sound_demo` and
  `examples/38_minigame`, which budget a real-time frame with bare `platform.sleep` so the
  audio pull still advances under a manual clock, and `examples/15_audio_tone`, whose sleep
  is the program's own lifetime.
- Worked examples of pacing: **an own loop** is `apps/patch/main.zig` (the defer at the
  top of the loop body); **through the runtime** is `core/app_runtime.zig` (its consumers,
  the editor and the synth, never call it themselves).

The breakdown within a frame is more reliably obtained by **timing sections** (inserting
`getTime()` at each stage of the frame body) than by sampling — with sampling, things
like `@memset` are attributed inline and end up as "unidentified".

## What is known about the `.physical` (HiDPI) frame budget

Measured on the editor with objc, ReleaseFast, at a framebuffer of 3024x1744 (5.27Mpx),
timing sections inside the frame body, averaged over 300 frames: clearing every pixel
5.55ms, `gui.render` 1.85, the canvas blit 1.55, the checker 0.73, building the UI and
ending the frame 0.12. The sections sum to 9.80ms; the whole frame body under the same
conditions is 10.43ms, so the 0.63ms difference is present and other unmeasured work.
(The real fps was 101 under the different condition of `SKIP_FRAME_COPY=1`.)
**The largest term is clearing every pixel, not the blit.** Those section figures predate
`pixelops.fill32`; at the same framebuffer size the clear now measures 3.7-4.0ms paced and
4.8ms free-run with objc, and 0.44ms with metal, and unpaced throughput went 94.8 to
116.6fps.

- **A whole-framebuffer u32 fill goes through `pixelops.fill32`, not `@memset`**: measured
  on aarch64-macos with zig 0.16 and ReleaseFast, a `@memset` of a u32 pattern that does
  not repeat per byte (`COLOR_WINDOW_BG` and the like) does not lower to libc memset but
  to a scalar four-byte store loop (1.66ms for 21.1MB, or 12.7GB/s; clang's u32 loop does
  0.64ms and `memset_pattern4` 0.42ms). `fill32` seeds one 4 KiB block and replicates it
  with `@memcpy`, which measures 0.35ms (60GB/s) for the same 21.1MB, and it takes
  **metal's clear section from 1.78ms to 0.44ms** in the editor at 3024x1744. The
  strategy comparison behind that choice — `@memset`, a `@Vector(16, u32)` store loop, a
  replicated block at several block sizes, and a byte-wide `memset` for a byte-repeating
  value — is `zig build bench-fill`, and the decision rule is in AGENT.md's performance
  rules. On the replicated block size, that bench measures 256, 1024, 4096 and 16384 pixels
  as indistinguishable (61-63GB/s) and 65536 as slower (55-58GB/s), so `fill32` uses 1024
  (4 KiB); no other target has been measured, which is why the number is a tuned default
  rather than a proven optimum. A `@Vector(16, u32)` store loop measures the same 60-62GB/s
  as the replicated block, and the block was chosen because the same shape also fills the
  rows of `fillRect32` and because it delegates to a bulk copy the target tunes itself.
- **On objc and swift (a CALayer plus a CGImage per present), the first write to every
  page of the framebuffer costs about 4.3ms per frame extra** (metal does not have this).
  The 4.3ms comes from the clear section in the row-`@memcpy` experiment: objc 4.72ms
  minus metal 0.40ms. The difference between the first and second identical memset gives
  5.38 − 2.30 = 3.1ms. **The mechanism is not established** (buffer ownership with the
  compositor, copy-on-write and page sharing are the candidates).
  The observations are: a second identical memset drops from 5.38 to 2.30ms; metal is
  1.87ms from the first; going back to `CGColorSpaceCreateDeviceRGB()` makes this cost
  disappear but the ColorSync conversion drops 98.9 → 41.1fps (so removing the colour
  space fix is not an option, and the conversion cost is paid outside the frame body and
  therefore does not show up in the section timings).
- This is one measurement point (the editor, objc, 2x) and is **not** a substitute for
  the performance matrix ADR-011 R10 asks for (1x/1.5x/2x × gui/font/canvas/viz × frame
  time and peak memory).

## Frame-cap measurement (`-Dframe-cap`, free-run)

Caps are measured one at a time (rebuild per cap). Free-run harness, ReleaseFast, objc:

```bash
for hz in 60 30 20 10; do
  rm -f /tmp/kngn-frame-cap-${hz}.port
  KNGN_HARNESS_LISTEN= \
  KNGN_HARNESS_PORT_FILE=/tmp/kngn-frame-cap-${hz}.port \
  KNGN_HARNESS_OUT=/tmp/kngn-frame-cap \
  KNGN_HARNESS_SKIP_FRAME_COPY=1 \
    zig build run-pixie -Dplatform=objc -Doptimize=ReleaseFast -Dframe-cap=$hz &
  until [ -s /tmp/kngn-frame-cap-${hz}.port ]; do sleep 0.1; done
  sleep 5
  scripts/kngn ctl --port-file /tmp/kngn-frame-cap-${hz}.port 'digest stats'   # frame1
  sleep 10
  scripts/kngn ctl --port-file /tmp/kngn-frame-cap-${hz}.port 'digest stats'   # frame2
  scripts/kngn ctl --port-file /tmp/kngn-frame-cap-${hz}.port 'quit'
  # fps = (frame2 - frame1) / 10; ignore virtual_fps
done
```

Pass criterion: `(measured - target) / target` within ±2%. The target is
`min(reported refresh, cap)`, not the cap: a cap above the refresh is clamped, so
`-Dframe-cap=120` on a 60Hz display targets 60.

**Measure with nothing else running.** A concurrent build starves the loop and the
numbers come out far below target — in one run a contaminated measurement read 36fps
against a 60fps target, which looks exactly like a pacing bug.

Each run prints its resolved target once, so a recorded number can be checked later:

```text
info: frame pacing: display refresh 60 Hz, cap 30 Hz, period 33.33 ms
```

Measured on aarch64-macos, the editor, objc, ReleaseFast, `.physical` 2x, 10s windows
after a 5s warm-up:

| backend | reported refresh | cap | target fps | measured fps | error | pass |
|---|---:|---:|---:|---:|---:|---|
| objc | 60 | 60 | 60 | 59.84 | -0.27% | yes |
| objc | 60 | 30 | 30 | 29.96 | -0.13% | yes |
| objc | 60 | 20 | 20 | 19.81 | -0.95% | yes |
| objc | 60 | 10 | 10 | 9.87 | -1.30% | yes |
| objc | 60 | 24 | 24 | 23.75 | -1.04% | yes (judder warning) |
| objc | 60 | 25 | 25 | 24.70 | -1.20% | yes (judder warning) |
| objc | 60 | 40 | 40 | 39.70 | -0.75% | yes (judder warning) |
| objc | 60 | 120 | 60 | 59.97 | -0.05% | yes (cap clamped to refresh) |

Two things this pins down:

- The timer path reaches its target across 10–60fps, so the utilisation cap on the
  learned overshoot (a quarter of the frame period) is doing its job at long periods.
- **A cap that is not a divisor of the refresh still reaches its rate.** 24, 25 and 40Hz
  all land within 1.2% of target on a 60Hz display; what the warning is about is the
  *evenness* of display intervals (a 2-3 refresh pattern), not the average rate.