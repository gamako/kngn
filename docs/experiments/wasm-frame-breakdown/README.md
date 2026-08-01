# Where a wasm frame goes

A harness that splits one browser frame of a kngn application into named sections, so
that "the frame takes N ms" can be turned into "N ms, of which this much is here".

It exists because a whole-frame number cannot answer the questions that matter. Enabling
`simd128` did not move the frame time, and with only a total there was no way to tell
whether the vectorised code was a small part of the frame, was not being vectorised, or
was limited by something other than arithmetic.

The measured results, and what they mean for this codebase, live in
[../../performance-measurement.md](../../performance-measurement.md). This file is the
how-to.

## What it measures

Three quantities, which are **not** interchangeable:

| Quantity | What it is | What it is not |
|---|---|---|
| rAF callback duration | synchronous work in one animation-frame callback | the cost of displaying the frame |
| rAF start-to-start | effective frame interval | paint/raster/composite time — it also contains scheduler wait and unrelated browser work |
| in-frame sections | wall time between marks inside the app, accumulated over the run | anything happening outside `kngn_frame` |

Paint, raster and composite happen **after** the callback returns. No arrangement of
timers inside the callback can see them; a browser trace is required for that. The
harness therefore reports the interval separately and never presents it as paint time.

Sections come from an accumulator block inside wasm: each mark closes the interval since
the previous mark and adds it to a slot. Accumulating over hundreds of frames is
deliberate — the host clock is quantised (5 µs under cross-origin isolation), which is
the same order as the smallest sections, so per-frame values would be mostly quantisation
noise while the sum over a run is not.

Every report carries the cost of the instrument itself (measured on the spot by calling
the host clock in a tight loop) and the clock's effective resolution, so a section can be
checked against the floor rather than assumed to be above it.

**The harness serves COOP/COEP for the clock, not only for the audio transport.** A page
that is not cross-origin isolated gets a coarser `performance.now()` — coarse enough to
swamp the smaller sections. The measured resolution is reported per run: 5 µs isolated
against 100 µs not, so a run whose reported resolution jumped by twenty times is telling
you the headers did not apply, not that the machine changed.

## Prerequisites

The measured build needs section marks compiled into it. They are **not** part of the
normal build: a profiler wired into the observation plane is separate work, and shipping
marks in the present path only to support an experiment would be paying for it forever.

Add them temporarily:

1. A profiler holding an accumulator block, a `mark(section)` entry point, and exports
   for the host to read the block, reset it, and calibrate the clock.
2. `mark` calls at the section boundaries you care about. In the measured configuration
   these were: after event drain, after the UI tree is built, before and after the
   framebuffer clear, around the canvas composite and blit, around `gui.render`, and
   around the swizzle and the host present call inside the backend's `present`.
3. A runtime switch for what the present path writes into the staging buffer
   (the real swizzle, a plain `@memcpy` of the same size, or nothing), so the
   channel-shuffle cost can be separated from the cost of writing that many bytes
   without rebuilding between conditions.

### The contract between the patch and this page

`bench.html` reads the accumulator through the memory view, so the layout is a contract.
It must export:

| Export | Meaning |
|---|---|
| `kngn_prof_block() -> ptr` | address of a `f64` block |
| `kngn_prof_len() -> u32` | length of that block, which must be `sections + 4` |
| `kngn_prof_reset()` | zero the block and the mark counter |
| `kngn_prof_marks() -> f64` | marks recorded so far, so marks-per-frame can be checked |
| `kngn_prof_calibrate(n) -> f64` | call the host clock `n` times; write the total seconds into the `now cost` slot and return the smallest non-zero delta seen (the effective clock resolution) |
| `kngn_prof_set_swizzle_mode(u32)` | select the staging write: 0 real, 1 `@memcpy`, 2 nothing, plus any extra formulation under test (the mode numbers are the table under "Conditions") |
| `kngn_prof_equivalence_failed() -> u32` | non-zero if the staging writes being compared do not produce the same bytes. `bench.html` refuses to report without this export, because a cheaper formulation that computes something else is not a cheaper formulation |

The block is `sections + 4` `f64` slots: one accumulated seconds per section in the order
`bench.html` lists in `SECTIONS`, then frame count, framebuffer width, framebuffer height,
and the total seconds spent inside the clock call during calibration.

`bench.html` refuses to report if the exports are missing or if the block length does not
match its own section list, rather than reading plausible numbers out of the wrong slots.

Then package the web bundle:

```
zig build package-web
```

## Running

```
python3 docs/experiments/wasm-frame-breakdown/run.py --out /tmp/breakdown.json
python3 docs/experiments/wasm-frame-breakdown/analyze.py /tmp/breakdown.json
```

`run.py` serves `zig-out/web` together with `bench.html` from one directory, launches one
browser per condition, and collects each run's JSON report over HTTP. Nothing connects to
a debugging port, so it runs unattended.

Useful flags: `--sizes`, `--present`, `--swizzle`, `--repeats`, `--frames`,
`--matrix full` for the cartesian product instead of one-axis-at-a-time.

`analyze.py` prints per-condition medians with bootstrap confidence intervals, and
`--compare A B` prints the difference between two conditions with a CI on the difference.

## Conditions

`present` selects what the host side of the present does:

| Value | Behaviour | Read it as |
|---|---|---|
| `real` | the application's own present, untouched | the baseline |
| `split` | the same steps, reimplemented so the copy and the upload are timed apart | the split; its total should match `real`'s `js_present`, which is the check that the reimplementation is faithful |
| `stale` | skip the copy, still upload | upload cost with unchanged pixels |
| `touch` | write a few bytes instead of copying, still upload | guards `stale` against a "contents unchanged" optimisation |
| `none` | skip both | **observer effect**: the canvas stops updating, so paint and composite disappear too. A lower bound on synchronous cost, not a measurement of the present |

`swizzle` selects what the backend writes into the staging buffer. The first three are the
baseline and the two cost floors below it; the last three are formulations of the swizzle
itself, kept selectable so that "which way of writing this is fastest on this target" stays a
measurement:

| Value | Read it as |
|---|---|
| `real` | the shipped implementation: the baseline |
| `memcpy` | same bytes written, no channel shuffle. `real − memcpy` is the shuffle |
| `noop` | nothing written. `memcpy − noop` estimates writing a frame's worth of bytes — an estimate, because cache state and what the host reads next both change too |
| `vecptr` | the byte `@shuffle` with the 16 bytes moved through a `*align(1) @Vector(16, u8)`. This is what the shipped one does, so it is a duplicate of `real` unless that changes |
| `u32` | the same swap expressed over `@Vector(4, u32)` lanes: equivalent output, different instruction mix |
| `deref` | the byte `@shuffle` with the 16 bytes moved through `slice[i..][0..16].*`. **wasm scalarises this form** — 16 byte loads and stores per block — so it is the cost of getting the load form wrong |

A mode this page does not know is an error, not a fall back to `real`: a misspelt
`--swizzle` would otherwise become a silent duplicate of the baseline and the comparison
between them would read as "no difference".

## Things that quietly invalidate a run

- **The application boots itself when its module loads.** A page that also calls `boot()`
  gets two instances, two frame loops, and numbers that look plausible. Set
  `globalThis.__kngnManualBoot` before importing. `bench.html` reports both the frames the
  app ran and the animation frames that elapsed; if they disagree, something else is
  driving frames.
- **Section values are means; a whole-frame median is not comparable to their sum.** The
  distribution is right-skewed, so a sum of means minus a median produces a negative
  residual. `bench.html` reports the callback mean for exactly this reconciliation, and
  the residual is the honest measure of what the sections fail to explain.
- **A backgrounded headless window stops running animation frames.** Without
  `--disable-background-timer-throttling`, `--disable-backgrounding-occluded-windows` and
  `--disable-renderer-backgrounding`, no report is ever produced.
- **The framebuffer size follows the element's client box.** Asking for a canvas larger
  than the window silently measures a smaller one. Every report carries the size that
  actually reached wasm, the CSS size, the backing-store size and the device pixel ratio;
  check them before comparing two sizes.
- **A CSS size that differs from the backing store** makes the browser resample on
  composite. `bench.html` sets both from the same number.
- **Fixed condition order leaves an order effect** indistinguishable from a condition
  effect. `run.py` shuffles, seeded.
- **Headless does not necessarily pace to a real display.** Treat the interval as this
  configuration's effective interval, not as the display refresh.
