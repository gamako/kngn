# Layout: sizing rules and pitfalls

`src/layout.zig` implements a small flex-style layout engine. This document is the
current contract for `Sizing` (fixed / fit / grow / percent) and the two-pass
measure/place model behind it, worked through an example, plus the pitfalls that
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

## The two passes

Layout runs in exactly two tree walks per frame, in this order:

1. **`measure`** — post-order (children before parents). Each node resolves its
   own `measured_w` / `measured_h`:
   - A **leaf** (text, or a custom-drawn widget) resolves to its own intrinsic
     content size (text ink width/height, or the caller-supplied `measured`
     size) regardless of its declared `Sizing` — `measure` resolves a leaf's
     size before ever looking at its `Sizing`. This governs only the leaf's
     *measured* contribution (what an ancestor computing `.fit` sees). At
     `place` time the leaf is treated exactly like a box: its own declared
     `Sizing` (`.fixed`, `.fit`, `.grow`, `.percent`) still decides how much
     room its direct parent actually gives it — a leaf whose declared size
     differs from its intrinsic content size can end up overflowing (if
     given less) or with unused space around it (if given more).
   - A **box** (a node with children) resolves through `Sizing`:
     `.fixed(n)` resolves to `n` immediately; `.fit` resolves to the sum
     (main axis) or max (cross axis) of the node's children's
     *already-computed* `measured_w`/`measured_h` on that axis, plus padding
     and inter-child gap; **`.grow` and `.percent` resolve to `0` at this
     stage, unconditionally** — regardless of what that node's own children
     need. Both are placement-time concepts (they need to know the actual
     space available, which does not exist yet during a bottom-up measure).
2. **`place`** — pre-order (parents before children), starting from the root
   with an actual `Rect`. Each node's content box (its rect minus padding) is
   now a concrete size, so this pass resolves what `measure` could not:
   `.percent` as a fraction of that concrete content size, and `.grow` as the
   leftover after fixed/fit/percent siblings are subtracted, divided by weight.
   `place` then recurses into each child with *that child's own* resolved rect
   as the new concrete size for its own content box.

## The pitfall: `.grow` on a `.fit` container's main axis is always exactly zero

Follow what happens when a node `N` is sized `.fit` on its **main** axis and
has a direct **box** child `C` sized `.grow` on that same axis (a leaf child
is a separate case — see the leaf exception above; a leaf's own measured
contribution is always its intrinsic size, `Sizing` notwithstanding):

- During `measure`, `C`'s own measured size on that axis is `0` — and so is
  any `.percent` sibling's; the same `.grow, .percent => 0` rule applies to
  both alike at measure time. So when `N` sums its children on that axis to
  resolve its own `.fit` size, neither contributes anything: `N`'s measured
  size on that axis is exactly the sum of its fixed and fit children's
  measured sizes, plus padding and inter-child gap (`.grow`/`.percent`
  siblings add nothing to that sum).
- `N`'s parent then places `N` using exactly that measured value: a `.fit`
  node's placed size on an axis *is* its measured size on that axis, by
  construction. So `N`'s content size (that placed size minus padding), once
  `place` recurses into it, is exactly what was just summed, minus padding.
- When `place` computes the leftover for `.grow` children
  (`content size − everything else`), "everything else" now also includes
  any `.percent` sibling's *actual, resolved* share of that content size
  (`floor(content size * f)` — see below) — a share that was invisible to
  the fixed-and-fit-only sum that established `N`'s content size in the
  first place. So the leftover is never positive: it is exactly `0` with no
  `.percent` siblings (or with a `.percent` sibling that resolves to a `0`
  share — `.percent(0)`, or a nonzero `f` against a `0` content size), and
  it goes *negative* (clamped to `0`) the moment any `.percent` sibling
  resolves to a positive share. `C` resolves to `0` — **unconditionally**,
  regardless of what siblings `C` has: `N`'s content size can never exceed
  what its fixed/fit children alone needed, so there is never a positive
  amount left for `.grow`, and any `.percent` sibling can only make the
  shortfall larger, never smaller.

This follows directly from a bottom-up pass (`measure`) being asked to size
something that is only known top-down (`grow`): a `.fit` container has no way
to reserve room for a child whose size it cannot see yet.

### `.percent`, and `.grow` on the cross axis, are different: conditional, not unconditional

It is tempting to assume `.percent` collapses the same way `.grow` does under
a `.fit` main-axis parent, but it does not, because of how `place` resolves
each one. A `.grow` child's size comes from *leftover* space (`content size
− everything else`), which is always exactly zero under a `.fit` main axis as
shown above. A `.percent` child's size, in contrast, is `floor(content size *
f)` — a **direct** fraction of the container's actual content size, not a
leftover. If that content size is nonzero (because some *other* sibling is
`.fixed` or `.fit` and contributes a nonzero amount), the `.percent` child
gets a real, nonzero size too, even though it also measured as `0`.

For example: a `.fit`-main-axis container with a `.fixed(100)` sibling and a
`.percent(0.5)` child has content size `100` (the `.fixed` sibling's
contribution; the `.percent` child still contributed `0` at measure time).
At `place`, the `.percent` child resolves to `floor(100 * 0.5) = 50` — not
zero. A `.grow` child in the same position would still resolve to `0`.

The same distinction holds for `.grow` on the **cross** axis: a cross-axis
`.grow` child's size is "the container's content size on that axis" taken
directly (weight is ignored), not a leftover — see "Related pitfalls" below.
So `.percent` under a `.fit` main axis, and `.grow`/`.percent` under a `.fit`
cross axis, only degrade to zero in the narrower case where **nothing at all**
establishes a nonzero content size on that axis: no *box* sibling is sized
`.fixed`/`.fit` with a nonzero result, **and** no leaf sibling has a nonzero
intrinsic content size on that axis either — a leaf always contributes its
own intrinsic size to this sum/max regardless of its own declared `Sizing`
(the leaf exception above), so a leaf sibling with nonzero intrinsic content
on that axis (a non-empty label, for instance; an empty string or a
zero-sized custom leaf contributes nothing and does not break the collapse)
breaks the collapse on its own.

### Worked example

```zig
// direction = .row (width is the main axis here)
var container: Node = .{ .cfg = .{ .direction = .row, .width = .fit, .height = .{ .fixed = 20 } } };
var highlight: Node = .{ .cfg = .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 20 } } };
appendChild(&container, &highlight);

measure(&container, font);
// container.measured_w == 0: `.fit` summed its one child's measured_w, which is 0 (`.grow`).

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
  `.grow`-width row is the unconditional case: it resolves to zero width no
  matter what its siblings are.
- With the default `.direction = .column` (rows stacked vertically), width is
  the content box's **cross** axis, so a `.grow`-width row only resolves to
  zero *when* no sibling row establishes a nonzero width either (per the
  conditional rule above — a `.fixed`/`.fit` box sibling, or a leaf sibling
  with nonzero intrinsic width, would break the collapse). That condition
  does hold for a common and easy pattern to reach: a list where every row is
  a plain background/highlight box using `width = .{ .grow = 1 }` — none of
  them is `.fixed` or `.fit`, and none is a leaf with its own nonzero width,
  so nothing establishes a nonzero width and the whole list's rows collapse
  together. It does *not* hold the moment some other row (or a non-empty
  label leaf directly inside the content box) is sized `.fixed`/`.fit`, or is
  a leaf with nonzero intrinsic width, instead — then that sibling's nonzero
  width carries through to every `.grow`-width row.

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
  it is not a leftover distribution. So it only collapses to zero when no
  sibling establishes a nonzero max on that axis, not unconditionally.
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

## Verification

`zig build test-gui` runs `layout.zig`'s own `measure`/`place` unit tests
(literal `Node` trees checked against hand-computed rects, in the same style as
the worked example above). A fix or a regression test for the fit/grow
interaction described here belongs there.
