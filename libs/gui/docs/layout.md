# Layout: sizing rules and pitfalls

`src/layout.zig` implements a small flex-style layout engine. This document is the
current contract for `Sizing` (fixed / fit / grow / percent) and the five-stage
axis-split model behind it, worked through an example, plus the pitfalls that
model creates — most notably a `.fit` container silently reducing a `.grow` child
on its main axis to zero size, and (under a narrower condition) doing the same to
a `.percent` child or a cross-axis `.grow` child. `README.md`'s "Layout engine
limits" section states the headline rule in one line; this document is the fuller
write-up it points at.

## The four sizing modes

`BoxConfig.width` / `.height` is a `Sizing`, chosen independently per axis:

| Mode | Meaning |
|---|---|
| `.fixed(n)` | Exactly `n` px — for how its *own* box gets placed by its parent. See "The two passes" below for the one exception: a leaf's *measured* contribution, as read by an ancestor computing `.fit`, ignores whatever `Sizing` the leaf declares. |
| `.fit` | The sum (main axis) or the max (cross axis) of the box's own children on that axis, plus padding. A leaf (text, a custom-drawn widget) resolves to its own content size instead of a child sum. |
| `.grow(weight)` | Whatever main-axis space is left in the parent's content box after fixed/fit/percent siblings are subtracted, divided among every `.grow` sibling by weight ratio. On the **cross** axis a `.grow` child ignores its weight and simply fills the parent's content size on that axis. |
| `.percent(f)` | `floor(parent_content_size * f)` on either axis. Several `.percent` siblings are not corrected to sum exactly to the parent's size; the leftover px from truncation is absorbed by a `.grow` sibling if one exists (not by another `.percent` sibling). |

A box's `direction` (`.row` or `.column`) decides which of its two axes is "main"
(the axis children are laid out along) and which is "cross" (the axis children
are aligned within, per `align_cross`).

## The five stages

Wrapping text cannot know its height until its width is settled, so layout
splits the two axes. Each frame runs five tree walks, in this order:

1. **`measureWidths`** — post-order. Text leaves take the max intrinsic
   paragraph width (`text_wrap.measureIntrinsicWidth`; layout never calls
   `font.measure` on a leaf string). Custom leaves take their caller-supplied
   width. Boxes resolve `.fixed` / `.fit` on the width axis; **`.grow` and
   `.percent` contribute 0** before their own clamp — `computeMeasured` clamps its
   raw result, so a positive `min_width` still makes the measured value that
   minimum.
2. **`placeWidths`** — pre-order. Resolves `rect.x` / `rect.w` the way the
   historical `place` pass resolved both axes: `.percent` of the parent's
   content width, `.grow` leftover by weight (or fill, on the cross axis).
3. **`wrapText`** — every text leaf is split into logical lines at its placed
   width. `wrap = false` still splits on paragraphs; `wrap = true` also folds
   inside a paragraph. The leaf's `measured_h` is then the line count
   (one line uses ink height so a single-line leaf matches the historical size).
4. **`measureHeights`** — post-order. Re-aggregates `.fit` heights from the
   (now wrap-aware) children. **`.grow` and `.percent` contribute 0** here too,
   before their own clamp — the same rule as width measure, including inside a
   `.fit` parent.
5. **`placeHeights`** — pre-order. Resolves `rect.y` / `rect.h`.

A leaf still ignores its own `Sizing` at measure time (intrinsic contribution
only). At place time it is treated like a box. A wrap / clip / ellipsis leaf
is created with `width = .grow` so a definite-width ancestor gives it a box
to fold into; a `.fit`-width ancestor still sees the intrinsic measure and
grows to max-content, so the leaf does not fold.

`measure` + `place` remain as a convenience for callers that do not wrap
(they seed text height from the paragraph count instead of running `wrapText`).

## Positioned children

A child with `BoxConfig.position != null` is out of its parent's flow. It takes
no part in the parent's fit measure, main-axis cursor, gap, grow share, wrap
line split, or line cross size. Several siblings may be positioned. Draw order
is tree order — a later sibling paints on top.

The containing block is always the **direct parent**: there is no search for a
positioned ancestor, and no way to reach past the parent's box from here.
Placing a subtree against something further up the tree is a different
mechanism, not a wider version of this one.

`Position` carries one `Inset` per edge plus a `pivot`. An inset is measured
**inward** from its edge of the parent content box, and holds a pixel offset
and a percentage that add, so one edge expresses CSS
`calc(<percentage> + <length>)`. Either part may be negative, which moves the
box outward past that edge.

Which insets are set decides the shape of the placement on each axis
independently:

| leading | trailing | Size | Position of the leading edge |
|---|---|---|---|
| `auto` | `auto` | the box's own `Sizing` | content origin, less the pivot |
| set | `auto` | the box's own `Sizing` | origin + leading, less the pivot |
| `auto` | set | the box's own `Sizing` | the trailing edge, less size and the pivot |
| set | set | `content - leading - trailing` | origin + leading; the pivot does not apply |

The `pivot` is the fraction of the box's **own** size subtracted after the
insets resolve, the way CSS pairs `left: 50%` with `translate: -50%`: `0` puts
the leading edge on the resolved point, `0.5` the centre, `1.0` the trailing
edge. Any finite value is legal, including outside `[0, 1]`, which overshoots
on purpose. Both terms floor independently, so centring is
`floor(content * 0.5) - floor(size * 0.5)`.

Pinning both edges is the only case where the parent decides the size, which is
why the pivot has nothing to shift there. It also means the axis must not carry
a `Sizing` that states a size of its own: `.fixed` and `.percent` are rejected
there, because the insets and the size would be saying different things.
`.fit` and `.grow` — the two that mean "whatever is available" — are what two
insets supply.

Where the box's own `Sizing` does decide the size, it resolves against the
parent content box (border-box minus padding):

| Mode | Result |
|---|---|
| `.fixed(n)` | `n` |
| `.fit` | the child's own measured size |
| `.percent(f)` | `floor(parent_content * f)` |
| `.grow` | fill the parent content on that axis (weight is ignored) |

`min_*` / `max_*` clamp still applies — the same uniform rule as every other
`Sizing`, applied last. When both edges are pinned and the clamp disagrees with
the distance between them, the leading edge wins and the difference is given up
at the trailing end.

`placeWidths` resolves widths after the flow pass; `wrapText` still visits the
positioned subtree; `measureHeights` measures that subtree without folding it
into the parent's fit height; `placeHeights` applies the placement.

Content extent: a positioned child is not part of the layout size. A parent
with `clip_children = false` still folds whatever of it is actually visible (the usual extent rule) so a ScrollArea can reach it. A clipping
parent does not include it.

An explicit `id` is cached and hit-tested like any other box.

## Main-axis alignment

`BoxConfig.align_main` (CSS `justify-content`, limited to `.start` / `.center` /
`.end`) decides where the flow children sit along the main axis. It places the
main-axis space **no child took** — the space that otherwise stays as a trailing
gap — by shifting the whole line: `.start` leaves it at the end, `.center` splits
it (floored), `.end` moves it in front. The `gap` between children never changes,
so distributing the leftover *between* children (CSS `space-between` and friends)
is not available; a row with a group at each end still puts a `.grow` box between
the groups.

The rule that matters in practice is when it does nothing:

| Situation | Leftover | `align_main` |
|---|---|---|
| A weight>0 `.grow` child on the main axis | 0 — it takes the rest | no effect |
| Every weight>0 `.grow` child frozen at its own `min_*` / `max_*`, remainder left | that remainder | applies |
| Only weight-0 `.grow` children (they never take the remainder) | the remainder | applies |
| Children overflow the parent | clamped to 0 | no effect |
| A `.fit` main axis | 0, unless something made the placed size exceed what the children take: the box's own main-axis `min_*`, a negative `gap` or `padding` that clamped the raw sum up to `0`, or a leaf placed smaller than it measured | usually no effect |

The freeze exception covers a min-side freeze, a max-side freeze, and a mix of
both: what matters is that no unfrozen weight>0 `.grow` child is left to absorb
the rest. So "a `.grow` child makes `align_main` inert" is the practical rule, not
the exact one.

In a `wrap` box **each line is aligned on its own leftover**, which is what CSS
`justify-content` does; the cross-axis stacking of the lines is not affected
(there is no `align_content`). Anchored children are placed by their own `Anchor`
and ignore `align_main` entirely.

Content extent follows the children: a `.center` or `.end` box's `content_w` /
`content_h` grows by the offset, because the extent is measured from the content
origin. A `.fixed`-size box therefore reports an extent up to its own content
size under `.end`.

## The pitfall: `.grow` on a `.fit` container's main axis collapses to zero

Follow what happens when a node `N` is sized `.fit` on its **main** axis and has
a direct child `C` sized `.grow` on that same axis. The collapse is stated for
this shape:

- `C` is an **in-flow box**. A leaf child takes the leaf exception above (its
  measured contribution is always its intrinsic size, `Sizing` notwithstanding),
  and a positioned child is not in the flow measure at all — it resolves `.grow`
  against `N`'s content box directly, so it fills whatever that is.
- `C` carries **no `min_*`** of its own on the axis. That clamp is the way out,
  and the last step of the walk-through is where it comes in.
- `N` carries **no `min_*` / `max_*`** of its own on the axis. `computeMeasured`
  clamps `N`'s own fit sum too, so `N`'s minimum becomes content `C` can take:
  a `.fit` box with `min_width = 100` and one `.grow` child places that child at
  100.
- `N` is **placed by its parent at its measured size**, which is what `.fit`
  means. A root handed a rectangle directly (`place` / `layoutTree` set the root's
  rect from their argument) is sized by that argument instead, and a `.grow` child
  takes the room it brings.
- `N`'s `padding` is **non-negative** and its `gap` is **not negative enough to
  drive the fit sum below zero**, and `C`'s siblings are boxes rather than leaves.
  These are covered under "Where the sum and the placement disagree" below,
  because they break the argument in the same way.

With those held, the walk-through:

- During `measure`, the raw size of a `.grow` or `.percent` child on that axis
  is `0` — the same `.grow, .percent => 0` rule applies to both alike. But
  `computeMeasured` clamps that raw value before returning it
  (`return clampAxis(node, axis, raw)`), so what such a child actually
  contributes is **its own `min_*` on that axis**, and `0` only when that
  minimum is `0`. `C` here carries none, so `C` contributes `0`. `N`'s measured
  size is therefore the sum of every flow child's *clamped* measured size —
  fixed and fit children at what they measured, `.grow` and `.percent` children
  at their own minimum — plus padding and inter-child gap. A `.grow` sibling
  with `min_width = 20` does widen `N`; it is not invisible to the sum.
- `N`'s parent then places `N` using exactly that measured value: a `.fit`
  node's placed size on an axis *is* its measured size on that axis, by
  construction. So `N`'s content size (that placed size minus padding), once
  `place` recurses into it, is exactly what was just summed, minus padding.
- When `place` computes the leftover for `.grow` children
  (`content size − everything else`), every **box** sibling takes **at least what
  it contributed** to the sum that established that content size, and some take
  more:

  | The box sibling | Contributed at measure | Takes at place |
  |---|---|---|
  | `.fixed` / `.fit` | its clamped measured size | the same |
  | `.grow` with a positive `min_*` | that minimum | it freezes at the minimum, or takes more |
  | `.percent` | its `min_*` (`0` without one) | `clamp(floor(content size * f))`, a direct share of the whole content size that was invisible to the measure sum |

  So the leftover is never positive. It is exactly `0` when every sibling takes
  precisely what it contributed, and it goes *negative* (clamped to `0`) as soon
  as one takes more — which any `.percent` sibling resolving above its minimum
  does. `C` resolves to `0` **whatever box siblings `C` has**: the content size
  `N` was placed at is the sum of the siblings' contributions, and no box sibling
  gives part of its contribution back, so nothing is left for a `.grow` child
  that contributed nothing itself.
- What does take `C` out of it is **`C`'s own `min_*`**. The clamp applies to
  every `Sizing`, so `C` measures at its minimum, `N`'s `.fit` sum carries that
  minimum, and `C` is placed at it. The collapse is a property of a `.grow` box
  with no minimum, not of `.grow` as such.

This follows directly from a bottom-up pass (`measure`) being asked to size
something that is only known top-down (`grow`): a `.fit` container has no way to
reserve room for a child whose size it cannot see yet. A `min_*` is precisely the
part of that size it *can* see, which is why both `C`'s own minimum and `N`'s are
ways out of it.

### Where the sum and the placement disagree

The argument above rests on `N`'s content size being the sum of what its children
contributed, and on no child handing part of that contribution back at `place`.
Three things break that, and each hands `C` a real size:

- **A leaf sibling.** A leaf contributes its intrinsic size at measure whatever
  `Sizing` it declares, but at `place` it is treated like a box and resolved from
  that declared `Sizing`. A leaf declaring `.grow` — which is what a wrapping
  `ctx.text` is — therefore contributes its intrinsic width to `N`'s sum and then
  shares the leftover with `C` instead of keeping it. A leaf declaring a `.fixed`
  smaller than its intrinsic size gives back the difference the same way.
- **A `gap` negative enough to drive the sum below zero.** `gapTotal` is
  `gap × (n − 1)`, and it enters both the measure sum and `place`'s `used`
  identically, so a mildly negative gap changes nothing. What breaks the argument
  is the raw sum going *negative*: `computeMeasured` clamps it to `0` (the default
  minimum) while `place` still subtracts the same negative total from `used`, and
  the difference is a positive remainder for `C`. With one `.fixed(100)` sibling,
  `gap = -10` leaves `C` at zero; `gap = -300` gives it 200.
- **Negative `padding`, again only where it drives the raw sum below zero.** Not
  rejected by `assertBoxConfigValid`, and it fails exactly like a negative gap:
  the raw fit sum clamps up to `0` while `place` still adds the negative padding
  back when it derives the content size from the rect. A negative padding that
  leaves the sum positive changes nothing, the same way `gap = -10` does not.

### `.percent`, and `.grow` on the cross axis, are different: conditional, not unconditional

It is tempting to assume `.percent` collapses the same way `.grow` does under
a `.fit` main-axis parent, but it does not, because of how `place` resolves
each one. A `.grow` child's size comes from *leftover* space (`content size
− everything else`), which is zero under a `.fit` main axis as shown above
(the child's own `min_*` being the way out). A `.percent` child's size, in contrast, is `floor(content size *
f)` — a **direct** fraction of the container's actual content size, not a
leftover. If some *other* sibling contributed enough that
`clamp(floor(content size * f))` comes out positive — a `.fixed` or `.fit` sibling
at its measured size, or a `.grow` / `.percent` sibling at a positive `min_*` —
the `.percent` child gets a real, nonzero size too — even where it measured as `0`, which is the case
for a **box** `.percent` child carrying no `min_*` of its own (a leaf measures at
its intrinsic size whatever it declares).

For example: a `.fit`-main-axis container with a `.fixed(100)` sibling and a
`.percent(0.5)` child, neither carrying a `min_*`, has content size `100` (the
`.fixed` sibling's contribution; the `.percent` child, having no minimum to
clamp its raw `0` up to, contributed nothing at measure time).
At `place`, the `.percent` child resolves to `floor(100 * 0.5) = 50` — not
zero. A `.grow` child in the same position would still resolve to `0`.

The same distinction holds for `.grow` on the **cross** axis: a cross-axis
`.grow` child's size is "the container's content size on that axis" taken
directly (weight is ignored), not a leftover — see "Related pitfalls" below.
So `.percent` under a `.fit` main axis, and `.grow`/`.percent` under a `.fit`
cross axis, only degrade to zero in the narrower case where **nothing at all**
establishes a content size big enough for the child's own resolution to come out
positive — for `.percent`, `floor(content size * f)` still truncates a small
content size to `0` (`floor(1 * 0.5)`). **Outside a `wrap` box** — the wrap path is
the paragraph after this one — that includes the container itself: its own `min_*`
sets a floor on the `.fit` result, and on an axis where it is not `.fit` at all its
own `.fixed` / `.grow` / `.percent` resolution *is* the content size, children
notwithstanding. Otherwise: no *box* sibling is sized
`.fixed`/`.fit` with a nonzero result, no *box* sibling carries a positive
`min_*` on that axis (the clamp inside `computeMeasured` makes such a sibling
measure at its minimum), **and** no leaf sibling has a nonzero
intrinsic content size on that axis either — a leaf always contributes its
own intrinsic size to this sum/max regardless of its own declared `Sizing`
(the leaf exception above), so a leaf sibling with nonzero intrinsic content
on that axis (a non-empty label, for instance; an empty string or a
zero-sized custom leaf contributes nothing and does not break the collapse)
breaks the collapse on its own. And, as on the main axis, a **negative axis
`padding`** that drives the raw `.fit` result below zero breaks it too: the clamp
raises the measured value to `0` while `place` still derives the content size as
`rect − padding`, which is then positive.

**That leaf exception is the non-wrapping path only.** Inside a `wrap` box the
cross size of a line comes from `lineCrossSize`, which reads each child's declared
`Sizing` and takes no leaf exception, so a leaf declaring `.grow` / `.percent`
contributes its `min_*` there rather than its intrinsic size — and the container's
own cross sizing does not reach the line at all. A `.grow`-cross child alone on a
line with such a leaf collapses even inside a `.fixed` parent. `separator`'s doc
comment in `src/widgets.zig` states both paths side by side, and
`docs/adr/034` records why.

### Worked example

```zig
// direction = .row (width is the main axis here)
var container: Node = .{ .cfg = .{ .direction = .row, .width = .fit, .height = .{ .fixed = 20 } } };
var highlight: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 20 } } };
appendChild(&container, &highlight);

measure(&container, font);
// container.measured_w == 0: `.fit` summed its one child's measured_w, which is 0
// (`.grow`, and no `min_width` for the clamp in `computeMeasured` to raise it to).

// container's own parent would place it at exactly that measured width (0) — reproduced
// directly here for a minimal example, rather than adding a further ancestor node:
place(&container, .{ .x = 0, .y = 0, .w = 0, .h = 20 });
// container.rect.w == 0.
// Inside place(), content_main == 0, so `highlight` (the only child, `.grow`) gets
// main_size == 0 too: there was no leftover space to distribute.
```

Nothing here is inconsistent with the rules above — `container` genuinely has
zero children with a nonzero *measured* main-axis size, so `.fit` genuinely
resolves to zero. The mistake, if there is one, is upstream: expecting a
`.grow` child to be visible to an ancestor sized `.fit` on the same axis.

### Where this shows up in practice: `ScrollArea`

`ScrollArea` (`src/widgets.zig`, `ScrollAreaOpts`) wraps an inner content box
whose `content_width` / `content_height` **default to `.fit`** — that is what
makes two-axis scrolling possible at all: the content is measured at its full
natural size (which can exceed the viewport), and the viewport clips and
scrolls it. A caller who pushes a row into that content box and gives the row
`width = .{ .grow = 1 }` — intending "span the full viewport width", for
instance to draw a full-width selection highlight behind a list row — can hit
either case above, depending on `opts.direction` (the content box's own
direction, which decides whether width is its main or cross axis):

- With `.direction = .row`, width is the content box's **main** axis, so a
  `.grow`-width row is the unconditional case: it resolves to zero width whatever
  its *box* siblings are. (`ScrollAreaOpts`'s `padding` and `gap` reach the content
  box unchecked, so the negative-value escapes above are reachable here too — as
  an accident rather than a technique.)
- With the default `.direction = .column` (rows stacked vertically), width is
  the content box's **cross** axis, so a `.grow`-width row only resolves to
  zero *when* nothing else establishes a nonzero width (per the conditional
  rule above — a `.fixed`/`.fit` box sibling, a box sibling with a positive
  `min_width`, a leaf sibling with nonzero intrinsic width, or a `min_width` on
  the content box itself would each break the collapse). That condition does
  hold for a common and easy pattern to reach: a list where every row is a plain
  background/highlight box using `width = .{ .grow = 1 }` — none of them is
  `.fixed` or `.fit`, none carries a `min_width`, and none is a leaf with its own
  nonzero width, so nothing establishes a nonzero width and the whole list's rows
  collapse together — barring a negative horizontal `padding` on the content box,
  which reaches it unchecked from `ScrollAreaOpts` and clamps the raw `.fit` result
  up to `0` while `place` still derives a positive content width. It stops holding the moment some other row (or a non-empty
  label leaf directly inside the content box) contributes a width instead — then
  that nonzero width carries through to every `.grow`-width row.

When the condition does hold, the visible effect is the same regardless of
direction: a selection highlight (or whichever row relies on `.grow` to reach
full width) that the code looks like it draws, but which is zero-pixels wide
and therefore invisible.

The fix already documented on `ScrollAreaOpts.content_width`'s doc comment is
the general fix for this whole class of pitfall: stop asking that axis to be
`.fit`. `content_width = .{ .grow = 1 }` makes the content box fill the
viewport's width instead of measuring to its children's natural width — at
the cost of no longer being able to scroll horizontally (there is no natural
width larger than the viewport left to scroll to). `content_height`'s own
measurement stays a separate, independently chosen axis, but viewport
*geometry* can still shift slightly: `endScrollArea` only reserves the
horizontal-scrollbar row when horizontal overflow is detected, so removing
that overflow (by switching to `content_width = .{ .grow = 1 }`) can free up
a `bar_thickness`-px strip of height for the viewport.

## Related pitfalls

- **The rule is per-axis, not per-node.** A box can be `.fit` on one axis and
  `.grow` on the other with no interaction between them — the pitfall above
  only applies to a child whose `.grow`/`.percent` axis matches an ancestor's
  `.fit` axis on that *same* axis.
- **The cross axis follows the conditional rule, not the unconditional one.**
  `.fit` resolves the cross axis as a **max** over children, not a sum, and a
  cross-axis `.grow` child's size is taken directly from the container's
  content size (see "`.percent`, and `.grow` on the cross axis" above) —
  it is not a leftover distribution. So it only collapses to zero when neither a
  sibling nor the container itself establishes a nonzero size on that axis (the
  container's own `min_*`, or its own `.fixed` / `.grow` / `.percent` resolution
  where it is not `.fit` there, is enough on its own), not unconditionally.
  A negative axis `padding` that clamps the raw `.fit` result up to `0` is an
  escape here as well, for the same reason it is on the main axis.
  **In a `wrap` box the container's own sizing is not one of those escapes**: the
  line's cross size comes from `lineCrossSize` over that line's children by
  declared `Sizing` alone, so only a sibling on the same line can establish it.
- **Percent truncation leftover needs a `.grow` sibling (with a positive
  weight) to land somewhere.** `.percent` uses `floor` with no correction
  across siblings, so a set of `.percent` children rarely sums to exactly
  the parent's content size. The few leftover px are absorbed by a `.grow`
  sibling with a positive weight, if one is present and there is nonzero
  space left to distribute (a `.grow(0)` sibling receives none of it);
  without a suitable `.grow` sibling those px are simply unaccounted-for
  trailing gap (not an error, just an easy thing to miss when a layout
  looks a few pixels short).
- **No shrink.** If fixed and fit children alone already exceed the parent's
  content size, they are not shrunk to fit — they overflow. `clip_children`
  never changes measured or placed sizes (layout math is unaffected); it
  only restricts where children are drawn and hit-tested, clamping both to
  the intersection of the parent's rect and any effective ancestor clip.

## Layout catalog (`examples/10_gui_layout`)

`examples/10_gui_layout` is a live catalog of these rules. The width slider
(or harness `action layout_width <px>`) re-solves every item on the same
screen. Each item prints the resolved numbers (child widths, wrap line
membership, leftover, visible range). `digest layout` exposes the same
figures for harness `expect`, including `pos_plain_h` / `pos_ovl_h` / `pos_dh`
(a positioned child does not change parent size), `pos_badge_x` /
`pos_badge_y` (placement), and `wrap_gap_y0` / `wrap_gap_y1` / `wrap_gap_dy` (measured
cross-axis spacing).

| Contract | Catalog item |
|---|---|
| fixed / fit / grow / percent mix: grow stretches, percent follows the content box, fixed and fit hold | 1. Mixed sizing |
| min/max clamp is orthogonal to `Sizing`; a clamped child freezes and the remainder is redistributed; weight-0 + min still meets min | 2. min/max clamp |
| leftover remainder is a trailing gap when every grow child is max-frozen | 3. Leftover |
| wrap line split: percent enters at its resolved size, grow enters at its min; `cross_gap` is independent of `gap` | 4. Wrap |
| wrap cross-axis grow fills its own line, not the container | 5. Wrap cross grow |
| a positioned child is out of flow: it takes no part in fit, cursor, gap, grow share, or wrap line split | 6. Position |
| ScrollArea scroll range is declared fixed → recorded content extent → measured | 7. Content extent |
| table columns: fit is content-sized, fixed holds, grow absorbs the remainder | 8. Table columns |
| virtual list visible window (`first..end`) follows height and scroll, not width | 9. Virtual list |

## Verification

`zig build test-gui` runs `layout.zig`'s own `measure`/`place` unit tests
(literal `Node` trees checked against hand-computed rects, in the same style as
the worked example above). A fix or a regression test for the fit/grow
interaction described here belongs there.
