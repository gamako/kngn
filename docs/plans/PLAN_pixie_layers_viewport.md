# Historical record: Pixie Layers panel bottom-clip fix

**Historical record**: this plan is kept for context; the current behaviour is described in
[`docs/editor.md`](../editor.md) and [`libs/gui/README.md`](../../libs/gui/README.md)
(`PanelHost` scrollable slots + Layers inner `ScrollArea`). The design below was implemented:
Pixie's right slot uses `scrollable = true`, and the outer ScrollArea plus the Layers inner
ScrollArea cooperate so the bottom row is reachable.

> Status vs current code: `libs/gui/src/panel_host.zig` exposes `SlotOptions.scrollable`, and
> pixie enables it on the right slot only. Prefer the sources above over this plan when they disagree.

## Purpose / background

In a narrow window, Pixie's right slot showed Color / Palette / Tool Options / Layers at once.
With many layers, the bottom Layers row was clipped by the bottom of the right slot. An earlier
change introduced a dedicated `ScrollArea` inside Layers, but left a degradation: when the right
slot's natural height exceeded the viewport, PanelHost-side scrolling was deferred.

This plan applied the existing GUI scroll machinery to the PanelHost right slot and combined it
with Layers' inner scroll so every layer stays reachable. Shrinking other panels' natural height
to "rescue" Layers was rejected.

## Code survey (at plan time)

- `apps/editor/apps/pixie/main.zig` (`layersNaturalContentHeight` / `updateLayersViewportHeight`)
  - Natural height from layer count × 24px, row gaps, padding, and selected Text Layer UI estimate.
  - Viewport height subtracts other visible panel heights, gaps, and Layers chrome from the previous
    right-slot rect.
  - Allocation was "reserve other sections' natural height first; clamp Layers to
    `clamp(natural, 1 row, remaining)`", accepting bottom clip when remaining height was short.
- Layers toolbar sat outside the Layers ScrollArea (always operable). Row height fixed at 24px;
  content used `.fit` so all rows stayed in the content.
- Right-slot declaration order: Color, Palette (default closed), Tool Options, Layers. Default
  width 200px, min 120px; the right slot grew vertically.
- `libs/gui/src/panel_host.zig`: `SlotOptions` had no scroll state; `buildSlot` stacked visible
  panels in a `clip_children = true` column with no `beginScrollArea`/`endScrollArea`.
- Existing `ScrollArea` in GUI already derived scroll range from natural content height; nested
  wheel handling (inner first, remainder to outer at end-of-range) could be reused for
  Layers-inner + PanelHost-outer.
- `digest panels` reported right-slot panel y/h and framebuffer height; after outer scroll,
  natural-content overflow had to be distinguished from visible-slot-boundary safety.

## Adopted approach

### Adopted: existing ScrollArea on the PanelHost right slot

Add `scrollable` to `SlotOptions`; Pixie enables it only on the right slot. A scrollable slot
keeps the current outer chrome (background, padding, clip) and places a vertical ScrollArea
inside. Visible panels stack in declaration order as `.fit` content.

The ScrollArea viewport ID is separate from the slot ID (slot ID still used for `slotRect` /
splitter / layout). When content fits, no scrollbar (same look as before); when it overflows,
panels keep their natural height and scroll inside the slot.

Wheel over Layers is consumed by the inner ScrollArea first; remainder reaches the outer right
slot once Layers hits its end — so after moving the Layers panel into view, the bottom row is
reachable.

### Rejected: change only section height allocation

Giving Layers fixed priority would shrink Color / Palette / Tool Options natural height. Tool
Options has icons, toggles, sliders, Bézier anchor UI, and PanelHost had no shrink/inner-scroll
contract for those. Forced shrink would clip controls and break the "other sections first"
intent; shortage is relieved by the outer PanelHost scrollbar instead.

## Height allocation design

Right-slot priority:

1. Visible and open Color / Palette / Tool Options keep previous-frame measured natural height
   (closed = header only; hidden = 0).
2. Subtract slot padding, gaps between visible panels, and Layers Collapsible header + toolbar (chrome).
3. If remaining height ≥ Layers natural height, use natural height.
4. If remaining < natural, shrink the Layers viewport to at least one row (24px). Even if remaining
   is under 24px, request 24px and let outer content overflow drive the scrollbar.
5. Do not shrink Color / Palette / Tool Options for Layers. Do not change right extent or center
   min width/height. When natural content exceeds the slot viewport, keep each panel's height and
   scroll the panel stack.

Reuse `updateLayersViewportHeight` / `layersNaturalContentHeight` formulae and fixed row height;
update only the degradation comment to "reachable via PanelHost outer scroll". First-frame unset
rects keep the existing fallback; next frame uses previous-frame rects. Outer scroll offset is
transient UI state; Preferences visible/open/extent format is unchanged.

Keep existing raw `digest panels` keys (`Color_y` / `Color_h`, …). If needed, add slot y/h or
in-clip bottom keys so `ok` means visible-slot-boundary validity, distinguishing raw overflow
from unreachability.

## Implementation steps (as planned)

1. Add scrollable flag + PanelHost-owned persistent `Vec2f` state and a stable per-slot viewport ID
   in `panel_host.zig`. Offset starts at zero; ScrollArea clamps each frame to content natural height.
2. Split `buildSlot` into scrollable / non-scrollable paths. Non-scrollable unchanged; scrollable =
   outer padding/bg/clip + `beginScrollArea`/`endScrollArea` + fit panel content. Always pair
   begin/end even on callback error.
3. Panel `hitTest` uses `getNodeCachedRect` effective clip and `pointHitsVisible` so panels scrolled
   out of view are not treated as hit. Splitter / center priority unchanged.
4. Pixie PanelHost init: right slot only `scrollable = true`. Keep Layers inner ScrollArea, toolbar
   outside scroll, and existing height formulae; align comments and `digest panels` visible-boundary
   observation.
5. Unit tests: overflow scrollbar/offset; wheel/thumb brings lower panel into view; non-scrollable
   regression; out-of-clip panels not hit; next frame builds after callback error.
6. Run `zig build test-gui` and `zig build bench-gui-frame`. Confirm the new path is panel/widget
   count order only — no full-framebuffer, audio RT, or lock additions.

## Verification method (as planned)

Set `KNGN_APPSHELL_DIR` to a temp dir and size Pixie around 420×360 via existing `window_state.ash`.
Open Palette + Color / Tool Options / Layers; `action add_layer` 15–20 times. Do not commit ash/PNG.

Representative replay (Palette open prepared via header click or persisted PanelHost settings;
coordinates confirmed on first snapshot):

```text
step 3
action add_layer       # 15–20 times
step 3
digest panels
snapshot fb /tmp/pixie-layers-viewport-before.png
inject scroll 0 -3     # repeat to Layers inner end
inject scroll 0 -3     # then propagates outward
inject scroll 0 -3
step 8
digest panels
snapshot fb /tmp/pixie-layers-viewport-after.png
quit
```

Replay with `KNGN_HEADLESS=1 KNGN_HARNESS_SCRIPT=... KNGN_HARNESS_OUT=... zig build run-pixie` and visually
inspect `snapshot fb` PNGs. Before: Layers viewport and/or PanelHost scrollbar visible. After:
bottom thumbnail / name / visibility / opacity controls fully visible; Tool Options slider/toggle
and Color/Palette bottoms intact. Optionally thumb-drag the outer scrollbar. On a real macOS
backend, run the same replay once to confirm scrollbar input and draw parity.

`expect panels ok=1` uses the visible-slot-boundary meaning. Raw natural-content rects may leave
the screen; evidence is a clamped scroll offset with the last Layers row visible in the snapshot.

## Hot-path declaration

`PanelHost.build`, `updateLayersViewportHeight`, panel callbacks, and Layers row construction are
per-frame UI (order of visible panels / widgets / layer rows). Outer ScrollArea layout is per-frame;
wheel offset updates only on input frames. No audio RT, per-sample, or full-framebuffer loops.

No new per-pixel division, inner-loop bounds/clip checks, per-frame registry copies, or RT
alloc/lock/panic. Scroll stack capacity grows only at warm-up; ordinary frames reuse GUI state.
Compare `bench-gui-frame` before/after; SIMD suite and audio RT benches are out of scope (layout
only, not pixel or per-sample work).

## Files touched (as planned)

- `libs/gui/src/panel_host.zig`: scrollable slot, outer ScrollArea, clip-aware hit-test, unit tests
- `apps/editor/apps/pixie/main.zig`: enable right-slot scroll; comments; optional digest keys
- `libs/gui/src/widgets.zig`: reuse ScrollArea; change only if nested-wheel tests expose a gap
  without breaking the wheel contract
- `build.zig` / harness: no new targets or golden images; existing test/bench/replay/snapshot/digest

## Acceptance mapping

- All Layers rows reachable via inner ScrollArea; when needed, outer right-slot ScrollArea moves
  the Layers panel into the viewport. Bottom row confirmed by snapshot.
- Color / Palette / Tool Options keep natural height priority; Layers shortage does not steal from
  them. Tool Options slider/toggle not improperly clipped (snapshot + panel rect probe).

## Decisions

- Reuse existing `beginScrollArea`/`endScrollArea` outside slot content; do not invent a new scroll.
- Pixie: right slot only scrollable; left/bottom contracts unchanged.
- Keep "other sections' natural height first" for Layers; shrinking Tool Options rejected.
- Whether `digest panels` `ok`/`bottom` should mean raw rect vs visible boundary was left to
  post-implementation probe compatibility; do not silently change existing raw key meanings —
  add visible-boundary keys if needed.
