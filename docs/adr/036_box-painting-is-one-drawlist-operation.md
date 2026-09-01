# ADR-036: Box painting is one DrawList operation

- Status: Accepted
- Date: 2026-09-02
- Scope: the background, uniform border, corner radius and outer shadow of a box in
  `libs/gui`, and the elision of a shadow's covered center

## Context

Seven box shadows in a 1440x900 dashboard composited 986,936 pixels per frame, 76% of
the framebuffer. Disabling only the center slice of the nine-slice reduced the shadow
bucket by 79% and total raster time by 41%, and the resulting framebuffer was
byte-identical: every center was immediately covered by an opaque panel background.
The mask cache was not the problem — two misses in 1200 frames — the blit was.

The center cannot be dropped unconditionally. A shadow with nothing over it, or with a
translucent surface over it, needs its center, and two existing tests say so.

What made the waste systematic is that the three calls always arrive together:

```zig
dl.shadow(rect, black, .{ .radius = r, .blur = b, .offset = o });
dl.rectFilledEx(rect, surface, .{ .radius = r });
dl.rectOutlineEx(rect, border, 1, .{ .radius = r });
```

That is the ordinary way to draw a raised card — a CSS `box-shadow` over a background,
Material Design's elevation — so every author writes it, and the library's own widgets
would too. The relationship between the shadow and the surface that hides it is obvious
to the author and invisible to the renderer, because it is spread across three
independent commands.

## Conventional vocabulary is part of the usability contract

Applications built on this repository are frequently written by agents that arrive with
general CSS box-model and Material Design knowledge and no history with the project. An
API that cannot be guessed cannot be searched for, and an author who cannot find one
reimplements it — which is how the measured dashboard came to be 1,194 lines of
rectangles and text with the layout engine never once used.

The public operation is therefore named `box`, and its parts are `background`, `border`,
`radius` and `shadow`: the words the author already has. It is not named after the
renderer's nine-slice, and not after the optimization that motivated it.

## Decision

`DrawList.box(rect, BoxOptions)` paints, in this order, an optional outer shadow, an
optional background, and an optional uniform border, over one rectangle:

```zig
pub const BoxOptions = struct {
    background: ?Paint = null,
    border: ?Border = null,
    radius: u32 = 0,
    shadow: ?BoxShadow = null,
    aa: bool = true,
};
```

- **One radius.** `BoxOptions.radius` applies to all three parts, as `border-radius`
  does. `BoxShadow.radius_override` exists only for a shadow whose silhouette is
  deliberately a different shape from the box that casts it; the dialog in `popup.zig`
  is the case that needs it.
- **`Border` is the existing type**, unchanged: uniform, four-sided, painted inside the
  rect, no effect on layout. A rule along one edge remains a `separator` (ADR-034), and
  this operation introduces no per-side border.
- **Everything is optional.** All-null appends nothing. A background alone is a filled
  rect; a border alone is an outline; a shadow alone behaves exactly as before.
- **Out of scope**: `spread`, inset shadows, and multiple shadows. They exist in the
  vocabulary this API borrows, but publishing a name is one-way (ADR-020) and none of
  them is implemented.

## Lowering, and what it costs a caller who does not use it

`box` appends the existing `shadow`, `rect_filled` and `rect_outline` commands. There is
no `.box` payload and no side table:

- A payload holding a `Paint`, a `Border` and a `BoxShadow` would very likely be the
  widest variant of `DrawCmd`, which is a per-command cost paid by every command in
  every list.
- A side table would add a field to every `DrawList`, work to `reset`, and an index to
  resolve in the dump, the parser and the overlay — again for lists that never call
  `box`.

The three commands are reserved first and appended together, so running out of memory
leaves the list exactly as it was rather than a shadow with nothing over it.

What the shadow command gains is one `u32`, `opaque_cover_radius`: the corner radius of
an opaque background that `box` has already queued over the same rectangle and clip, or
a sentinel meaning there is none. It fits inside the existing padding of a payload that
is not the widest, so a list with no shadows is byte for byte what it was. The render
buckets are unchanged, which also means before-and-after profiles compare directly.

`DrawList.box` is the only writer. The sentinel is the default, so a command assembled
by hand paints its center: the safe answer is the one you get by doing nothing.

## When the center is dropped

The center slice is dropped only when its clipped physical rectangle lies inside the
region the later background is *guaranteed* to overwrite. That region is the two strips
that cross at the middle of a rounded fill — the shape `drawRoundedFilledDevice` paints
with a plain fill and no coverage mask — intersected with the clip. Opacity requires
both the paint's alpha and the shape's coverage to be 255.

Consequences of stating it that way:

- **An antialiased corner never counts as cover.** A pixel inside a corner mask may in
  fact be fully opaque; the answer is "not covered" rather than reasoning about
  coverage. The rule admits false negatives and no false positives: a wrong "no" costs
  one redundant blit, a wrong "yes" shows the shadow through the panel.
- **A border is never evidence.** It touches only the rim, a translucent or antialiased
  one reads the destination, and an unusually thick one is not worth a special case.
- **A paint variant added later is not opaque** until someone says so, so a new paint
  cannot silently license the optimization.
- Both radii are physicalized before they are compared. Comparing a scaled shadow radius
  against an unscaled fill radius would drop a center that is not covered.

The practical rule that falls out: with a shadow radius `R`, a background radius `r` and
an offset `o`, the center is covered when `R >= r + |o.x|` and `R >= |o.y|`, or the same
with the axes swapped. A sharp-cornered shadow with a downward offset therefore keeps
its center — the band below the box *is* the shadow.

## Measurements

All on one machine, ReleaseFast, headless.

The dashboard that motivated the change (1440x900, seven shadowed panels, medians of
three runs): frame body p50 1.864 ms to 1.130 ms, of which rasterisation 1.763 ms to
1.028 ms — a 41.7% cut to raster time. The framebuffer is byte-identical across the
change.

`bench-rounded-primitives`, one 1280x700 panel, comparing two scenes that differ only in
the background's alpha:

| corner radius | opaque background | one alpha step short |
|---|---|---|
| 8 | 202,530 ns, 95,808 pixels blitted | 2,382,930 ns, 960,384 pixels |
| 32 | 301,435 ns, 187,008 pixels | 2,392,012 ns, 960,384 pixels |

What the operation costs the code that does not use it:

- A full GUI frame with no shadows (`bench-gui-frame`, 500 and 1000 rows at scale 1.0,
  1.5 and 2.0): between -0.8% and +0.5% across all six rows, which is the run-to-run
  spread.
- A standalone shadow, which pays the cover test and always fails it (three runs each,
  median of the averages and the smallest minimum): radius 8, 870,426 ns to 864,343 ns
  average and 842,583 ns to 843,375 ns minimum; radius 32, 873,897 ns to 875,098 ns and
  850,333 ns to 851,291 ns. The minimum is the less contaminated statistic and moves by
  about a tenth of a percent, which is one sentinel comparison per shadow.

## Alternatives rejected

**A caller-provided covered-center flag** exposes a renderer optimization rather than a
paint contract. Omitting it silently loses performance, while setting it incorrectly can
corrupt the framebuffer, and revalidating the hint in the renderer would make the public
flag redundant.

**A general occlusion pass** introduces a second coverage model over the command stream.
Handling clips, rounded antialiased shapes, gradients, images, paths and command order
correctly requires region accumulation and shape-specific opacity rules. That taxes
command lists that use no shadows at all, and duplicates rasterizer semantics to
recover a relationship that is already explicit where the box is built.

**A peephole on the next command** was rejected because adjacency is not the paint
contract. Semantically identical construction can stop matching — a debug marker between
the two calls, a different fill helper, a reordered outline — and the optimization
disappears with no visible change, which is the hardest kind of regression to notice.

**The name `shadowedRect`** puts the shadow at the center of an operation where it is
optional and is one part of three. An author who needs a background, a border, a corner
radius and an elevation together is looking for a box.

## Consequences

- The common panel is one call, and the library's own dialog is written that way.
- A standalone shadow and a translucent background keep their center, unchanged.
- The dump reports `cover_radius` so a probe can see that a box lowered as intended; the
  parser ignores it, so a text list cannot claim a background that was never queued.
- Only the center rectangle is dropped. The parts of the edge and corner slices that an
  opaque background also hides are left for later: the center alone accounts for the
  measured 79%, and taking more requires splitting slices while preserving their source
  coordinates.
- A change to how a rounded fill paints its interior changes what counts as cover. The
  rule names `drawRoundedFilledDevice` for that reason.
