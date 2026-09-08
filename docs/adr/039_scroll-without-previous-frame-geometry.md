# ADR-039: A scroll area with no previous-frame geometry declines to judge

- Status: Accepted
- Date: 2026-09-08
- Category: GUI, immediate-mode widget API, layout timing

## Context

`beginScrollArea` settles the caller's scroll amount every frame. The amount is owned
by the caller (`scroll: *Vec2f`), and the widget clamps it into `[0, content - viewport]`
so that the offset it hands to layout is inside the range that exists. Both numbers in
that range come from the **previous** frame's rect cache, which is what [ADR-016](016_gui-sync-hit-test-against-previous-frame-rect-cache.md) requires
of a synchronous widget API: this frame's rects do not exist yet at call time.

`rect_cache` is rebuilt from scratch in every `endFrame` that lays out a tree, so it
holds exactly the boxes that were built on the previous such frame. An area that was not
built — a tab that is not selected, a collapsed section, a panel toggled off — therefore
has no entry at all.

On the frame such an area is built again, both reads return null, `viewport` and `content`
both read as zero, and the range computes as zero. The clamp then does what it was told:
it moves the caller's amount to the only position in an empty range. The caller's scroll
position is destroyed, on the first frame the area comes back, by a widget writing into
the caller's own variable. An application cannot defend against it, because assigning
the remembered value immediately before the call is exactly what gets overwritten.

The frame-geometry contract had no answer for "there is no previous frame", and zero was
standing in for it.

## Decision

**A frame without previous-frame geometry does not judge the scroll amount by it.**

`geometry_known` — the viewport rect *and* the content size both present — gates
everything derived from the previous frame, and it is carried in `ScrollState` so that
one condition covers every writer:

- the clamp applies its **lower** bound always and its **upper** bound only when the
  geometry is known. The lower bound is not about the range: it keeps a negative amount,
  and NaN, out of the row arithmetic downstream;
- `max_x` / `max_y` / `need_v` / `need_h` are zero, and the content size is not read
  either. Zeroing rather than half-guessing is what makes the rest of the frame simple to
  reason about: no bar, no thumb geometry, no division by a range that does not exist —
  and which side of the cache is missing stops being a question;
- the wheel appliers (`applyScrollAreaWheel`, and `applyHeaderWheel` for a table's sticky
  header, which drives the same amount) return early. Their amounts are bounded by that
  same range, so applying one would clamp to zero just as the clamp would.

The area settles on the next frame instead, from geometry that exists.

This extends a rule the wheel path already stated — "an area with no previous-frame
viewport is not a wheel target, it becomes one next frame" — to the clamp, which was the
one reader of previous-frame geometry that judged from zeros instead of declining.

### The cost

If the content really did shrink while the area was hidden, the amount is too large for
one frame: the content is drawn scrolled further than its new range allows, the excess is
cut by `clip_children`, and the next frame clamps it. One transitional frame is the same
cost ADR-016 already accepts for every other previous-frame value, and it is paid only by
an area whose content changed while it was invisible.

### Two layers of conversion safety

The clamp was also, incidentally, the thing that kept `@intFromFloat` defined: a caller
that stores `+inf` in its own scroll variable had that value replaced before the
conversion. Without an upper clamp on such a frame the raw value reaches the conversion,
which is undefined for a non-finite or out-of-range input. Two separate bounds answer two
separate questions, and conflating them was wrong in both directions on the way here:

1. **`geom.scrollOffsetToLayout` — unconditional.** It clamps to the largest `f32` that
   converts into `i32` (`2^31 - 128`; `f32` steps by 128 there, so the next value up is
   `2^31`, which `i32` cannot hold). This bound is arithmetic, not policy: no value a
   scroll can legitimately hold is above it, so nothing real is clipped. It closes the
   same hole on the table header path, where the amount is converted before the body area
   opens and so was never settled by any clamp.
2. **The coordinate domain — only where the geometry is unknown.** A placement offset
   ends up in draw commands, and `gui.render` rejects a command outside
   `geom.MIN_COORD..=MAX_COORD` before any clip would cut it. On a frame with no range,
   the amount is a one-frame guess, so holding it to `MAX_COORD` costs nothing real.

The second bound is **not** applied where the geometry is known, because `MAX_COORD` is
the bound on a draw command's coordinates, not a contract on how far a caller may
scroll. A fixed size, and a virtual list's total height, may both exceed it, so an amount
past `MAX_COORD` is legitimate there and passes through untouched. What upper bound a
scroll input is *allowed* to hold, and what should happen to the nested case where each
level adds its own offset, are open questions this record does not answer.

## Alternatives considered

### Keep the content size cached while an area is hidden

The clamp would then have a real range on the frame the area returns, and no transitional
frame at all. Rejected: it puts a lifetime where there is none today.

`rect_cache` is derived state, discarded and rebuilt every laid-out frame, and that is
what makes "everything in this table is the previous frame's geometry" true. The table is
read by `getNodeRect`, `buttonBehavior`, drag and drop, the table widget, and a layer's
`.id` anchor, so entries that outlive their boxes would let a hit-test land on a widget
that is not on screen. Keeping entries also needs eviction: the keys are hashes the
caller supplies, including per-row ids that never come back, so the table would grow
without bound and would need the generation counter, LRU and trim that `PerIdStateStore`
carries — a second lifetime contract, to avoid one transitional frame. And "how stale may
a remembered size be" has no answer, because how long an area stays hidden is up to the
application.

### Clamp only from a size the caller declares

An area could take the content size as an option and clamp against that on the frame it
has no cache. Rejected: it moves a number the library measures into the caller's hands,
and the caller would have to keep it in sync with the content it builds — a worse contract
than one transitional frame, for the same result.

## Consequences

- The frame an area becomes visible again shows no scrollbar, even if it will have one:
  bars follow `need_v` / `need_h`, which are zero without geometry. It appears on the next
  frame, the same one-frame lag bars already have when content size changes.
- `layout`'s `scroll_x` / `scroll_y` contract gains an exception: the caller clamps to
  `[0, content_natural - viewport]` *except* on a frame where it cannot know that range,
  where the offset is bounded only by the coordinate domain.
- A test that hides an area must lay out something else on that frame. A frame that never
  touches the layout API skips the cache rebuild entirely, so an empty frame leaves the
  area's geometry in place — and a test written that way passes while exercising nothing.
