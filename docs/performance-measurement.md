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
- Worked examples of pacing: **an own loop** is `apps/noodle/main.zig` (the defer at the
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
## Measuring a wasm frame in the browser

A native frame rate says nothing about the wasm build: the present path is different
(a channel swizzle, a copy into an `ImageData`, an upload), and the browser schedules
frames itself. The harness for splitting one browser frame into named sections lives in
[experiments/wasm-frame-breakdown/](experiments/wasm-frame-breakdown/); its README is the
how-to, including the temporary marks the measured build needs. This section is the
procedure in outline and the data it produced.

### The procedure

Serve the packaged bundle together with a measurement page and drive a headless browser
from a script, collecting each run's report over HTTP. Nothing connects to a debugging
port, so it runs unattended:

```bash
zig build package-web
python3 docs/experiments/wasm-frame-breakdown/run.py --out /tmp/breakdown.json
python3 docs/experiments/wasm-frame-breakdown/analyze.py /tmp/breakdown.json
```

Three separate quantities, which must not be conflated:

| Quantity | Meaning |
|---|---|
| rAF callback duration | synchronous work in the animation-frame callback |
| rAF start-to-start | effective frame interval; includes scheduler wait, so it is not paint time |
| in-frame sections | wall time between marks, accumulated over the run |

Paint, raster and composite run **after** the callback returns and cannot be seen from
inside it; a browser trace is required for those.

What silently invalidates a run — an application that boots itself when its module loads
(giving two instances), a whole-frame median compared against a sum of per-section means,
a backgrounded headless window that stops issuing animation frames, a canvas larger than
the window (the framebuffer follows the element's client box), and a CSS size that
differs from the backing store — is enumerated in the harness README. Every report
carries the size that actually reached wasm, the clock resolution, the instrument's own
cost and the hash of the module it ran against; `analyze.py` refuses runs that fail those
checks and refuses to pool two builds under one condition.

### Where a frame goes

Measured on aarch64-macos, headless Chromium 150, the pixel editor, `ReleaseSmall` with
`simd128`, device pixel ratio 1. Median across 5 runs of 400 frames from **one build**;
each value is a per-frame mean, in µs. Instrument overhead was 2.0 µs/frame (12 marks)
and the clock resolution 5 µs, so sections in the single digits are aggregate estimates
rather than measurements.

| section | 320x240 | 780x600 | 1600x900 | 2560x1440 |
|---|---:|---:|---:|---:|
| events | 5.1 | 5.1 | 4.9 | 6.1 |
| ui_build | 514.5 | 447.5 | 309.7 | 290.7 |
| post_ui | 4.6 | 3.4 | 3.1 | 3.3 |
| fb_clear | 9.7 | 43.8 | 95.8 | 246.4 |
| canvas_composite | 0.5 | 0.4 | 0.3 | 0.3 |
| canvas_blit | 48.8 | 271.4 | 260.0 | 235.5 |
| overlays | 1.5 | 1.2 | 0.9 | 1.1 |
| gui_render | 73.0 | 168.9 | 183.5 | 254.1 |
| **swizzle** | **103.0** | **530.8** | **1161.2** | **2677.4** |
| **js present** | **43.0** | **132.6** | **323.3** | **908.9** |
| post_present | 0.2 | 0.3 | 0.2 | 0.2 |
| residual | 17.6 | 17.4 | 20.7 | 26.5 |
| **whole frame** | **817.5** | **1603.2** | **2361.7** | **4644.8** |

The sections account for 98–99% of the callback at every size.

**The BGRA→RGBA swizzle is the frame.** It is 58% of a 2560x1440 frame, and together with
the host-side present the two of them are 77%. Everything the application actually draws —
the UI tree, the clear, the canvas blit, the GUI rasterisation — is the remaining 23%.

Splitting the host side (the `split` condition reimplements it so the two halves can be
timed apart; `analyze.py` checks that its total still matches the untouched path):

| size | copy into the ImageData | upload | total |
|---|---:|---:|---:|
| 320x240 | 11.2 | 25.0 | 36.1 |
| 780x600 | 49.2 | 77.9 | 127.1 |
| 1600x900 | 117.0 | 203.0 | 320.0 |
| 2560x1440 | 406.0 | 493.9 | 899.9 |

Skipping the copy while still uploading (a stale `ImageData`) saves rather more than the
copy's own 406 µs, because it also changes the cache state the upload then reads; writing
a few bytes instead of copying gives the same figure, which rules out a "contents
unchanged" shortcut in the browser.

### There is no fixed cost worth the name

A straight-line fit of frame time against pixel count over the four sizes above puts the
intercept at 917 µs — and the two extreme points alone put it at 736 µs, which is the
first sign that the model is wrong. It is: **changing the canvas size changes the
application's workload**, because the framebuffer is the logical size on this backend, so
a bigger window lays out more UI. Intercept and slope are not independent and the
intercept is not a fixed cost.

Measured directly, the sections that do not scale with canvas pixels come to about 537 µs
at 2560x1440, and two of them are the whole story: `ui_build` (291) and `canvas_blit`
(236, which follows the document size and zoom rather than the window).

`ui_build` behaves the opposite way to a pixel cost: 515 µs at 320x240 falling to 291 µs
at 2560x1440, where it is the largest non-present section. Why building the UI tree costs
*more* in a small window is not explained by these measurements.

### Why `simd128` does not show up in the frame time

Enabling `simd128` moves the whole frame by about 1%, and the reason is not that the
feature is inert. Comparing two builds that differ only in that feature, at 2560x1440
(the ratio column is *without* ÷ *with*, so above 1 means `simd128` helped):

| section | with simd128 | without | ratio |
|---|---:|---:|---:|
| whole frame | 4669.1 | 4681.5 | 1.00 |
| swizzle | 2697.9 | 2690.5 | 1.00 |
| gui_render | 254.6 | 268.0 | 1.05 |
| ui_build | 290.4 | 290.7 | 1.00 |
| canvas_blit | 236.6 | 236.9 | 1.00 |
| js present | 908.9 | 906.3 | 1.00 |

The swizzle costs the same in both builds — and the disassembly below shows why: it
contains no SIMD instruction in either, so there was nothing for the feature to change.
`gui_render` does gain 5%, but it is 5.5% of the frame, so the gain is 0.3% of the frame —
smaller than the spread between runs of one condition. That is the whole answer: the one
section large enough to matter is the one that is not being vectorised.

That the feature works is shown by the same comparison against a swizzle written in a
form the backend does vectorise: 758.7 µs with `simd128` against 2610.1 µs without, a
factor of 3.4, and 1.65x on the whole frame.

It is not vectorised because of how the bytes are loaded, not because of the shuffle.
Disassembling the shipped module, the swizzle loop is 16 `i32.load8_u` and 16 `i32.store8`
per 16-byte block — no `v128.load`, no `i8x16.shuffle`. Compiling the same loop standalone
for `wasm32` with `simd128` isolates the trigger:

| formulation | codegen |
|---|---|
| `@shuffle` over `slice[i..][0..16].*` | 16 byte loads + 16 byte stores |
| same `@shuffle`, bytes moved through a `*align(1) @Vector(16, u8)` | `v128.load` + `i8x16.shuffle` + `v128.store` |
| same `@shuffle`, iterating a slice of `@Vector(16, u8)` | `v128.load` + `i8x16.shuffle` + `v128.store` |
| the swap expressed over `@Vector(4, u32)` lanes | `v128.load` + shifts/masks + `v128.store` |

`ReleaseFast` behaves the same as `ReleaseSmall`, so this is not an optimisation-level
setting. Alignment is not the trigger either — `align(1)` vectorises. Nor does it hit
every `@shuffle`: the alpha-broadcast mask the blend helpers use (`{3,3,3,3, 7,7,7,7, …}`)
survives the array-deref form, while a byte permutation does not. The rule that holds
across every case measured is: **on wasm, move the 16 bytes through a `@Vector(16, u8)`
pointer, not through `slice[i..][0..16].*`; a byte-permuting `@shuffle` is scalarised in
the second form.**

The size of the prize, measured in the running application at 2560x1440 by switching the
present path's staging write at runtime (one build, 5 runs each):

| what the present writes | swizzle section | whole frame |
|---|---:|---:|
| the shipped swizzle | 2697.9 | 4669.1 |
| same shuffle through a vector pointer | 758.7 | 2784.9 |
| the swap over u32 lanes | 762.1 | 2789.1 |
| `@memcpy` of the same bytes | 409.1 | 2421.7 |
| nothing | 0.2 | 1902.1 |

Every row here is a section median observed in this harness, not a clean isolated cost:
changing what the present writes also changes the cache state the host-side present reads
next, and the last two rows change it most. Even so the ranking is unambiguous — a
vectorised channel swap lands within a factor of two of a plain copy of the same bytes,
while the scalarised one costs about six times that copy. Fixing the load form is worth
**1.9 ms per frame, a 1.7x whole-frame speedup** at this size, without changing the
algorithm.
