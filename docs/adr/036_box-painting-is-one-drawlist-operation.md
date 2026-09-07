# ADR-036: Box painting is one DrawList operation

- Status: Accepted (revised 2026-09-06: a box carries several shadow layers, and a
  layout box reaches them through an elevation step)
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

`DrawList.box(rect, BoxOptions)` paints, in this order, the outer shadow layers, an
optional background, and an optional uniform border, over one rectangle:

```zig
pub const BoxOptions = struct {
    background: ?Paint = null,
    border: ?Border = null,
    radius: u32 = 0,
    shadows: []const BoxShadow = &.{},
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
- **Several shadow layers, in paint order.** `shadows[0]` is painted first and sits
  furthest back. Two layers is the ordinary shape of a raised surface, and the reason
  is not decoration: a real penumbra is sharper near the contact point and softer
  further out, which one blur radius cannot express. A single tight layer reads as
  glued down, a single wide one as a smudge. CSS lists shadows front-to-back, so a
  `box-shadow` value is reversed when transcribed into this slice — stated in the doc
  comment, because a list order is only a contract if it is written down.
- **Out of scope**: `spread` and inset shadows. They exist in the vocabulary this API
  borrows, but publishing a name is one-way (ADR-020) and neither is implemented.

## Lowering, and what it costs a caller who does not use it

`box` appends the existing `shadow` commands (one per layer), `rect_filled` and
`rect_outline`. There is no `.box` payload and no side table:

- A payload holding a `Paint`, a `Border` and a `BoxShadow` would very likely be the
  widest variant of `DrawCmd`, which is a per-command cost paid by every command in
  every list.
- A side table would add a field to every `DrawList`, work to `reset`, and an index to
  resolve in the dump, the parser and the overlay — again for lists that never call
  `box`.

Every command a box needs is reserved first and appended together, so running out of
memory leaves the list exactly as it was rather than a shadow with nothing over it — the
same rule with two shadow layers as with one.

What the shadow command gains is one `u32`, `opaque_cover_radius`: the corner radius of
an opaque background that `box` has already queued over the same rectangle and clip, or
a sentinel meaning there is none. **Every layer of a multi-layer shadow gets it**, since
the one background covers them all; the geometry test still runs per layer, because it
reads that layer's own radius and offset. It fits inside the existing padding of a payload that
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

## Revision, 2026-09-06: the layout box carries an elevation

The decision above gave the operation to `DrawList`, where a caller owns the rectangle.
That left the layout box — which paints a background, a border and a corner radius — with
no way to say it is raised. The consequences were larger than the missing convenience:

- **The optimization above was unreachable from the layout.** A card built from boxes had
  to paint its shadow through `mainDrawList` while its background came from the layout's
  emit, so `opaque_cover_radius` was always the sentinel and the center was always
  painted. The 41.7% below was not available to the path most screens are built on.
- **It had no users.** At the time of this revision the only caller of `box` outside the
  tests was the style gallery sample, and the library's own dialog, popup menu, menu bar
  and tooltip — every surface that floats over content — carried no shadow at all. The
  Consequences section below claimed the dialog was written with `box`; it was not, and
  the claim is corrected here rather than left standing.
- **Authors did the thing the API made available.** An outside author asked to reproduce
  a dashboard laid the cards out with boxes and then recomputed the card rectangles by
  hand — `content_x + i * (width + gap)` — to place two shadow layers under them. A
  second coordinate system that silently disagrees with the first the moment the tree
  changes.

### What a box says

`BoxConfig.elevation` is a step of a scale — `none`, `raised`, `elevated`, `overlay` —
and the theme (`Style.elevation.levels`) says what each step looks like. The box states a
height; it does not describe a shadow. That is the Android and Material shape rather than
the CSS one, chosen over `shadow: ?BoxShadow` for reasons that are measurable:

- **It costs the trees that do not use it nothing measurable.** `?BoxShadow` grows
  `BoxConfig` from 176 to 208 bytes and `layout.Node` from 344 to 376, paid by every box
  in every frame. An `enum(u8)` fits the existing padding: both stay at 176 and 344.
  `Style` grows by the one pointer, 600 to 608 bytes. Measured with `bench-gui-frame`
  across 500/1000 rows at scale 1.0/1.5/2.0, the six no-shadow rows move between -0.2%
  and -2.5% on the minimum, which is the run-to-run spread.
- **The number of layers stays out of the published names.** A step is a slice, so the
  theme decides whether a raised surface is one shadow or three without any application
  changing a line. Publishing `shadow: ?BoxShadow` would have fixed that at one, and the
  design system the sample was reproducing asks for two.
- **The lowering stays internal.** Dropping a covered center is a fact about a CPU
  rasterizer. Keeping the public surface at "how high is this box" leaves that free to
  change — including to nothing at all, on a GPU where an analytic shadow shader makes
  the whole question moot.
- **The same shadow for a step, everywhere.** The values live in one table per theme,
  and light and dark differ in tint and not only in alpha. How a step is built up — two
  layers here — is the table's business, so it can change without an application saying
  anything different.

`emitNode` keeps the rest-state path exactly as it was: a box at `.none` reads no table
and assembles no `box`, so what the feature costs a tree that never uses it is one field
load and one branch. `Style.shadowsFor` is the only reader of the table, so the number of
layers, their order and which one is the contact edge stay the theme's business — a box
painted by hand asks for a step rather than indexing.

**Rejected on the way there.** A pointer on `BoxConfig` (`?*const BoxShadow`) does not fit
the padding either — 184 bytes — so it buys a per-frame, per-box lifetime hazard for
nothing. `LayerSpec.shadow`, which would have cost ordinary boxes nothing, reaches the
popup menu (whose layer root is its visible surface) but not the dialog, whose layer root
is the full-screen scrim and whose panel is an ordinary child; and it never reaches a card
that does not float. A table stored in `Style` by value grows a 600-byte struct that
eighteen call sites copy wholesale, fourteen of them per widget per frame.

**What it does not do.** The scale cannot express an arbitrary shadow — a coloured glow, a
one-off silhouette. That case paints with `DrawList.box` and owns its rectangle, which is
the same two-tier arrangement Android and Flutter settled on. `Style.shadowsFor` exists so
that a hand-painted box can still take the theme's shadow without reading the table.

## Consequences

- The common panel is one call, and a layout box says how high it sits.
- A standalone shadow and a translucent background keep their center, unchanged.
- The dump reports `cover_radius` so a probe can see that a box lowered as intended; the
  parser ignores it, so a text list cannot claim a background that was never queued.
- Only the center rectangle is dropped. The parts of the edge and corner slices that an
  opaque background also hides are left for later: the center alone accounts for the
  measured 79%, and taking more requires splitting slices while preserving their source
  coordinates.
- A two-layer box costs about two elided shadows rather than one elided and one whole.
  Measured with `bench-rounded-primitives` on a 1280x700 panel, radius 8: one opaque
  layer blits 95,808 pixels, two blit 168,128, and the same box with nothing covering it
  blits 960,384. Hinting only the layer nearest the surface would land near 1,056,000,
  and the benchmark fails if it does.
- **What an elevation step costs is decided by its offset against the box's corner
  radius**, not by how far up the scale it is. A shadow displaced further down than the
  radius shows below the box, so its center is not covered and is painted whole — the
  correct answer, and an expensive one. Blitted pixels for the same 1280x700 panel:

  | corner radius | `raised` | `elevated` | `overlay` | one uncovered shadow |
  |---|---|---|---|---|
  | 8 | 168,128 | 1,128,736 | 1,190,208 | 960,384 |
  | 32 | 350,528 | 446,560 | 508,032 | 960,384 |

  `raised` (1px and 8px down) stays elided at both. The wide layer of `elevated` (16px)
  and `overlay` (24px) is elided at radius 32 and painted whole at radius 8, which is why
  the two tall steps cost roughly seven times as much there. A surface that wants a tall
  step cheaply wants a corner radius at least as large as the offset; the alternative is
  a flatter scale. `bench-rounded-primitives` asserts this relationship in both
  directions, so neither the values nor the cover rule can drift without it failing.
- A change to how a rounded fill paints its interior changes what counts as cover. The
  rule names `drawRoundedFilledDevice` for that reason.

## Revision, 2026-09-07: the library's own floating surfaces take a step

The revision above gave the layout box an elevation and left every surface this library
draws itself flat. That was deliberate — the step changes what every application looks
like, so it wanted its own review — and this revision is that decision.

### The assignment

| Surface | Step | Why |
|---|---|---|
| `popupMenu`'s root, and the menu-bar dropdown built on it | `elevated` | opens over the content and is dismissed by clicking away from it |
| A tooltip's root, both a text tip and a `tooltipBox` subtree | `elevated` | the same relationship to the content; it is read, not operated |
| `dialog`'s panel | `overlay` | frontmost, and read against a scrim that has already darkened the tree |
| `dialog`'s scrim | none | a shadow under a full-viewport sheet falls off the screen |

Every one of these is a surface the library owns, so the step is not a parameter. An
application that wants a flatter look replaces `Style.elevation.levels`, which is the one
knob for the whole scale; adding a per-call step would put the same contract in two places
and make each consumer answer a question the theme already answers.

### The scrim became a token, and its two themes are not the same value

`dialog` filled its root with a literal `rgba(0, 0, 0, 0x88)`. That is now
`Style.surface.scrim`, and the two canonical themes give it different alpha: `0x88` in dark,
`0x52` in light.

The reason is not symmetry but what each theme's shadow can do. The light steps are far
weaker than the dark ones — the same alpha over white reads as dirt rather than depth — so
on a light ground the scrim is what separates a modal, and a sheet at 53% both darkens the
ground below the panel and leaves the panel's own shadow with nothing to be seen against. On
a dark ground the shadow does that work, and the sheet stays strong.

Material Design keeps one scrim for both schemes. It can, because its dark surfaces are
mid-greys; this dark canvas is `0x181C24`, and a sheet weak enough to suit the light theme
is nearly invisible over it. `SurfaceTokens` is a per-theme structure, so nothing was gained
by tying the two together.

Rejected: strengthening `light_elevation_levels` so the panel's shadow reads through a 53%
sheet. The shadow was not the problem — a raised card on a light ground already reads
correctly, and darkening the steps to fix a modal would darken every card with them.

An alpha of zero is left legal and means "no dimming". It does not change the modal route,
which absorbs the main tree either way, and a test states that.

### What it costs

Measured with `bench-gui-frame` and `bench-gui-tooltip` (ReleaseFast, 1024x768 logical),
before against after, per frame:

| Scenario | Before | After | Shadow pixels blitted |
|---|---|---|---|
| `popup-8` | 32.5 µs | 132.3 µs | 98,604 |
| `menu-8` | 33.7 µs | 114.5 µs | 79,760 |
| `dialog-1` | 1367.8 µs | 1562.9 µs | 170,560 |
| `popup-8` at scale 2 | 84.9 µs | 467.8 µs | 394,416 |
| `dialog-1` at scale 2 | 5421 µs | 6259 µs | 682,240 |
| tooltip `showing` | 15.9 µs | 80.9 µs | — |
| `layer-0` … `layer-32` (no floating surface) | 49.7 / 55.6 µs | 48.4 / 55.2 µs | 0 |
| tooltip `baseline` / `hidden` / `pending` | 12.8 / 9.7 / 6.8 µs | 10.2 / 8.3 / 7.4 µs | 0 |

Three things in that table are worth stating plainly.

- **A tree with no floating surface is unchanged**, which is the obligation a feature added
  to a shared path carries. The two rows at the bottom are the scenarios where the feature
  is absent, and they are reported against the numbers from before the change rather than
  measured only afterwards.
- **The dialog's cost is not its shadow.** It was already 1.37 ms per frame before this
  change, because the scrim blends a translucent fill over the whole viewport every frame;
  the shadow adds 14%. A frame with a modal open is expensive for a reason that predates
  the step and is not addressed here.
- **The shadow of a step is priced by the offset against the corner radius**, per the table
  in the revision above, and the dialog panel is the case that table warned about: its
  radius is 8 against `overlay`'s 24px offset, so the wide layer is painted whole rather
  than elided. A panel that wanted the step cheaply would want a larger radius.

In the assembled application (`pixie`, ReleaseFast, 780x600, the File menu held open for 309
frames, `frameprof`) the frame body went from 0.472–0.496 ms to 0.600–0.644 ms — about
+0.14 ms while a menu is open, against a 16.7 ms budget. Two runs each, because the spread
between runs on one machine is a third of the effect.

## Revision, 2026-09-07: the penumbra is smooth at both of its ends

The mask's coverage profile was a straight ramp, `1 - distance / blur`. A straight ramp has
the right values and the wrong shape: its slope is at full size where the shadow meets full
coverage and again where it meets the ground, and a slope that stops abruptly is read as a
line. Both ends of every shadow in this repository had one.

The light theme is what made it visible. Measured down the centre of a light modal (a 360x168
panel on a 1024x640 viewport, the column below its bottom edge), the profile was:

| distance below the panel | value | slope |
|---|---|---|
| 0–8 px | 122, flat | 0 |
| 8–24 px | 122 → 139 | +1.1 / px |
| 24–32 px | 139 → 142 | +0.38 / px |
| 32–88 px | 142 → 166 | +0.4 / px |
| 88 px | 166, the ground | **still +0.5 / px when it arrived** |

Two artefacts are in that table. The slope change at 24 px is the near layer of the step
ending while the wide one continues — two layers of different widths always produce a
shoulder. The one at 88 px is the ramp itself stopping, and that is the one worth removing.

`coverage` is now `t * t * (3 - 2t)` over the same `t = 1 - distance / blur`, so its slope
reaches zero at both ends. The profile's steps then widen out as it approaches the ground
instead of continuing at full size and halting: the last levels of a light modal's shadow now
hold for five pixels each, where before they were two apart and then gone.

**This is free at frame time.** A mask is generated once per `(radius, blur, scale)` and
retained, so the curve costs nothing per frame, and it changes no geometry: the blitted pixel
counts in the table of the previous revision — 168,128 / 1,128,736 / 1,190,208 at radius 8 and
350,528 / 446,560 / 508,032 at radius 32 — came back bit-identical from
`bench-rounded-primitives` after the change, because a profile's shape does not move the
extent it covers or what an opaque background hides. `bench-gui-frame` likewise reproduced its
popup, menu and dialog timings.

A curve cannot add levels, though, and the light theme's problem was partly that it has so
few. Measured on the rendered frame, a light modal's shadow runs from 122 to a ground of 166 —
**about forty levels in total** — because a shadow read against a light ground has to stay
faint to avoid looking like dirt. Spreading forty levels over the dark theme's 64px of blur
puts a band every other pixel.

The light steps that float over content are therefore **drawn shorter than the same step in
the dark table**, and given a higher peak *than they had before* to keep their contrast:
`overlay` is 40px of blur at 18px of offset against the dark table's 64 at 24, and `elevated`
is 28 at 12 against 48 at 16. Both remain far fainter than their dark counterparts in absolute
terms — `0x3A` against `0x80` — since fainter is the whole reason they have few levels to
spend. The light modal's bands now sit about 1.2px apart instead of 1.9px, and it reads as one
shadow rather than a smudge.

**Shortening one step of a theme is not a local edit.** Tightening `overlay` alone left the
light table with a modal that spread less than the menu below it, inverting what the scale
means, and the ordering test did not catch it because it only ever looked at the dark table.
It now runs over every theme, and `elevated` was brought in with `overlay` for that reason as
much as for its own banding.

`raised` keeps the dark distance. It is fifteen levels deep in total, so it has no band in it
to remove, and no sample in this repository renders it on a light ground — a change there
could not have been reviewed by looking at anything. The dark table is untouched: its ground
gives a shadow room the light one does not, and its values were chosen with that in mind.

Rejected:

- **The curve alone.** It removes the line at the end of the ramp and nothing else; the light
  modal still banded every other pixel.
- **Tightening the dark steps to match.** Nothing was wrong with them: a dark ground reads a
  wide, faint shadow correctly, and the measurement that motivated the change does not exist
  there.
- **Dithering the mask.** It would trade a band for noise, break the nine-slice's position
  independence — a mask is blitted at four corners and four edges, so a dither pattern baked
  into it repeats visibly — and it addresses a symptom of the token values rather than the
  values.

What the curve has to keep is stated as tests rather than as this paragraph, in two parts.

The shape: along the edge strip and the corner diagonal alike, the profile's first and last
steps are each less than half its steepest step, and it never falls as it goes from the
outside in. A straight ramp fails the first part because all of its steps are equal, and a
curve smooth at one end only fails it too; a wobble fails the second. Two details of that test
were wrong before they were right, and both are the same mistake — measuring next to the thing
rather than the thing. The span has to end at the first fully covered sample, because the array
continues into the flat interior, and a test reading the array's last element measures that
interior instead of the knee where the ramp meets full coverage. And the comparison has to be
against the steepest step rather than the middle sample, because the sample grid does not land
on the steepest point: a 32px penumbra peaks at 12 levels per sample two entries before its
midpoint, which reads as 11.

The identity: three points of the curve itself (`0.25 → 40`, `0.5 → 128`, `0.75 → 215`). Every
relative property above is satisfied by other smooth monotone curves — a cosine ease among
them — so without these the profile could be replaced by a different shape and nothing would
say so.
