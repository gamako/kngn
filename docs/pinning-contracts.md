# Pinning a contract with a test, a benchmark or a probe

`AGENT.md` states the rules in one line each. This document holds the reasoning and the
worked examples behind them, so that the rules stay short and a reader who wants to know
*why* has somewhere to go.

## A contract stated as an absolute is pinned the same way as a performance claim

The performance rules require that "zero allocation", "recomputed at block rate" and
"SIMD matches scalar" be pinned by an executable test. The same applies to every contract
phrased as *never*, *always*, or *unbounded*: "the declarative path never exceeds the width
it was given", "zero means no line limit", "the chain is fixed for the frame". Such a
sentence is prose until a test states it in the form that fails.

Prefer the form that quantifies over inputs rather than one example of it: a case built
from the one input the author had in mind passes while the general claim is false. Two
defects that reached review here read exactly that way — an ellipsis that respected the
width on its last line only, and an "unbounded" line count that was silently capped a few
thousand lines in. Both had tests, and both tests agreed with the implementation, because
the same reading produced them.

That is the reason a contract is worth restating in a review request in the words of the
design, not in the words of the code: a reader comparing prose against code is the only
check that survives an author who misread the prose.

## Asserting on a whole frame, not a microbenchmark

The component-level pins (a `FailingAllocator`, an upper bound on recomputations, a
SIMD-versus-scalar comparison) pin one piece. To pin **the assembled frame**, assert on the
`frameprof` probe (`core/control/frame_prof.zig`; the pixel editor and the patch canvas are
wired). It works in a replay script and against a live process alike:

```bash
KNGN_FRAME_PROF=1 KNGN_HARNESS_SCRIPT=/tmp/s.txt zig build run-pixie -Doptimize=ReleaseFast
#   step 300
#   expect frameprof body_ms<16.7
```

**Assert on `body_ms`, and read `gap_ms` before believing it.** A section's measured cost
tracks how idle the loop is, not only how much work it does, so a frame body that grew may
mean more work or may only mean the loop got slower — `gap_ms` on the same line is what
separates the two. The probe reports both totals next to every section for exactly this
reason, and `frame_ms == body_ms + gap_ms` holds by construction.
[harness.md](harness.md) has the key list and
[performance-measurement.md](performance-measurement.md) the measurements behind the rule.
Reserve `frame_ms` assertions for a frame rate claim; use `body_ms` for a claim about the
work.

A caveat that applies to any number this produces: these are wall-clock values on the
machine that ran them. **Do not put a frame-time assertion in a build gate** — the drift
between runs on one machine is already the size of the effects worth catching.

## A new feature costs nothing to the code that does not use it

A feature added to a shared path — layout, the frame build, a widget everything else is
built from — must not make the trees that never use it slower. The trap is that the
behaviour is correct either way, so nothing fails: detecting "is this feature present
here?" by walking the children every frame is a perfectly correct implementation, and it
taxes every caller that does not use the feature.

**Record the answer where the structure is built, not where it is consumed.** A flag set
when a child is inserted turns a per-frame search into a branch. `has_positioned_child` in
`libs/gui/src/layout.zig` is the worked example: without it, a tree holding no overlay
still paid two extra walks per box per frame.

Two obligations follow for such a change:

1. Its benchmark carries **a scenario where the feature is switched off or absent**, next
   to the scenarios that exercise it.
2. That scenario is reported **against the numbers from before the change**. A zero-case
   scenario measured only after the fact says nothing: it reports what the new path costs,
   not whether the old path grew.

## A test, a benchmark or a probe that cannot fail proves nothing

Writing a check and having a check are different things, and the difference is invisible
in a green run. Three real cases, all of which passed while measuring nothing:

- a horizontal-scroll benchmark whose columns summed to a third of the table width, so it
  never scrolled;
- a digest that reported the number of wrap lines but not the spacing between them, so
  setting `cross_gap` to zero still satisfied it;
- an assertion on a widget that had already been proven by the surrounding test.

**Before trusting a new test, benchmark or probe key, break the thing it watches and
confirm it reacts** — set the gap to zero, shrink the container until it overflows, remove
the clamp. Record in the change notes that this was done. A check that stays green under
the fault it is named after is worse than no check, because it also removes the doubt.

## Filling a large area with one u32

`@memset` on a `[]u32` becomes the target's bulk fill (libc `memset`, wasm `memory.fill`)
only when the compiler can see that the four bytes of the value are equal. A background
colour such as `0xFF12161B`, or any value that is not a compile-time constant, cannot be
expressed as one byte-valued fill, and it becomes a scalar four-byte store loop instead.
Measured with `zig build bench-fill` on aarch64-macos at 21.1MB: `@memset` 1.79ms
(11.8 GB/s) against `pixelops.fill32` 0.35ms (60 GB/s). A compile-time constant whose four
bytes are equal (`0`, `0xFFFFFFFF`) is already the fastest form as `@memset` (109 GB/s
measured, against 62 for a vector store loop).

`fill32` takes the byte-repeating case to a byte-wide `memset` itself, so a caller whose
value happens to be byte-repeated reaches that path without knowing the value up front.
For a value that is **not** byte-repeated, the gain scales with the length of **each
contiguous run**, not the area, because the seed costs the same per call — a fill whose
colour changes every row pays it per row
([performance-measurement.md](performance-measurement.md) measures the ratio).

## SIMD on wasm: how the bytes are loaded decides whether SIMD happens

On wasm, load and store a `@Vector(16, u8)` through a vector pointer rather than
`slice[i..][0..16].*`: in the second form a byte-permuting `@shuffle` is emitted as 16
scalar byte loads and stores, in `ReleaseSmall` and `ReleaseFast` alike. Writing SIMD is
not the same as getting it — check the disassembly.
[performance-measurement.md](performance-measurement.md) has the measured cost of getting
this wrong.
