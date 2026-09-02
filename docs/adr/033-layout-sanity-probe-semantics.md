# Layout Sanity Probe Semantics

Status: accepted

## Context

The GUI layout tree contains the geometry used to place text and boxes before the
draw list is emitted. Visual snapshots and draw-list hashes are useful regression
signals, but they do not identify a structural overflow or an accidental overlap at
the point where it is introduced. A small, opt-in probe can make those conditions
machine-checkable in the existing harness without adding rendering behavior to the
framework.

The probe must describe layout ownership rather than every pixel that happens to be
visible. In particular, intentional clipping, scrolling, out-of-flow placement, and
detached overlays are part of the GUI contract and must not be reported as ordinary
flow-layout failures.

## Decision

The GUI exposes a custom `layout_sanity` digest with three counters:

```text
enabled=1 scanned=1 text_overflow=0 sibling_overlap=0 content_overflow=0 total=0
```

The result is copied out of the frame arena into `Context` storage immediately after
the normal layout tree has been completed. The digest reads only that retained value.
The normal layout root is scanned once per enabled frame. Popup, dialog, tooltip, and
retained overlay layers are emitted outside that root and are not included.

### Text envelope

Each text leaf is checked once. For every placed line, the probe uses the font's
logical advance width and the font's ink height to form an envelope at the line's
placed y offset. The leaf is reported when that envelope leaves the leaf rectangle.
This is deliberately a logical envelope rather than a rasterized glyph bounding box:
it follows the public font measurement contract, is stable across rendering backends,
and does not require allocating or drawing a temporary bitmap.

Text with `overflow = visible` is eligible. Ellipsis and clipped text are intentional
boundaries and are excluded. A text leaf below an ancestor with `clip_children` is
also excluded, as is text in a scroll viewport. Wrapping is checked after line
placement, so lines that fit their leaf are not reported merely because the source
string is long.

### Flow sibling overlap

Only direct, in-flow children of the same parent participate. A pair counts
when the intersection has positive width and positive height. Touching edges are not
overlap, and positioned children are excluded both from the pair check and from their
parent's flow extent.

Children are sorted by their x coordinate. Each item is compared only with later
items whose x ranges still intersect the current item's right edge. For `k` siblings
the work is `O(k log k + C)`, where `C` is the number of x-overlapping candidate
pairs. A scene in which every sibling overlaps necessarily has `C = O(k^2)`.
The temporary item array is allocated from the frame allocator only while the probe
is enabled.

### Content extent

For each non-leaf flow box, the probe computes the furthest direct flow-child edge,
including an un-clipped child's measured content extent, then adds the box padding.
The box is reported when that extent exceeds its width or height. Positioned children
do not contribute. A box with `clip_children`, a non-zero scroll offset, or an
explicit min/max constraint is an intentional boundary and is excluded; a direct
flow child with an explicit min/max constraint likewise marks the parent's constrained
extent as intentional. This keeps constraint demos from being classified as broken
content while leaving ordinary unconstrained overflow observable.

### Arming and cost

`KNGN_LAYOUT_SANITY=1` enables the scan and `=0` disables it. Unset and unknown values
follow harness enablement. The disabled path performs only the `endFrame` enable check;
it does not walk nodes, allocate scratch storage, or measure fonts. The enabled path
does not alter the layout tree, draw list, framebuffer, or overlay state.

## Verification

Pure layout fixtures cover fixed-width text, overlapping flow siblings, and content
extent beyond a fixed box. Exclusion fixtures cover clipping, scrolling, ellipsis,
normal wrapping, anchored children, detached popup layers, and min/max constraints.
Gallery and torture-example checkpoints exercise the probe through the harness while
retaining their existing DrawList expectations. Disabled and harness-following gate
states are checked through `KNGN_LAYOUT_SANITY`; framebuffer snapshots are inspected
to confirm that the probe remains observational.

No widget-name exception table is part of this contract. Intentional demonstrations
are pinned with their measured non-zero counter, so changing the demonstration itself
is visible to the same regression check.
