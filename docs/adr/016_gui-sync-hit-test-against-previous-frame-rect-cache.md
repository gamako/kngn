# ADR-016: Widget hit-test runs against the previous frame's rect cache (`libs/gui`)

- Status: Accepted
- Date: 2026-07-29
- Category: GUI, immediate-mode widget API, layout timing

## Context and problem

`libs/gui`'s widget calls (`ctx.button(...)`, `ctx.checkbox(...)` and so on) return
their result — clicked, changed, dragging — synchronously, in the Dear ImGui style.
But a widget's own final rect for *this* frame is not known at call time: layout
(`layout.measure` then `layout.place`) only runs once, in `Context.endFrame`, after
every widget for the frame has been built. Sibling measurement and parent sizing
(flex, percent, fit-to-content) mean a widget's rect can depend on widgets built
after it, so there is no way to know final rects mid-build.

A synchronous API still needs *something* to hit-test against while building the
tree. The question is what.

## Decision

Hit-test synchronously, at widget-call time, against the **rect cache from the
previous completed frame** (`Context.rect_cache`, populated by `updateRectCache` at
the end of the prior `endFrame`). This is a deliberate one-frame lag: only on a
frame where a drag or other input changes the layout do draw (this frame's new
rects) and hit-test (last frame's rects) disagree, and only for that one frame.
Ordinary static layout, a slider drag that does not reflow, or scrolling do not
show it.

The full lifecycle contract (what runs in `beginFrame` vs `endFrame`, what the rect
cache holds, when it updates) is documented as the current contract at the top of
`libs/gui/src/context.zig` and on `getNodeRect` / `getNodeCachedRect` /
`getNodeMeasured` / `updateRectCache`; this ADR does not restate it, only the
choice and the alternatives.

## Rejected alternatives

| Option | Why rejected |
|---|---|
| A: Finalize layout before widget construction | Sibling measurement and parent sizing mean a widget's final rect cannot be known before every widget for the frame has been built — layout cannot run before the widgets that produce its tree. |
| B: Re-run hit-test after `endFrame` | Collides with the synchronous-return shape of the API (`ButtonResult`, `changed`) — a widget call already returned its answer before `endFrame` runs. Making that answer eventual instead would need event retention, a re-evaluation pass, and new ordering rules across the whole widget surface. |
| C: A predicted rect per widget | Not generally computable for widgets whose size depends on flex/scroll/popup state or dynamic label width — would need a second layout-and-hit-test path running alongside the real one, duplicating both. |

## Consequences

Real-world impact is confined to: a parent's layout changing while a child is
being dragged, a display or window-size change mid-drag, and a mouse release
landing on the boundary between the old and the new rect. `examples/37_gui_torture`
pins the observed values for a layout-shifting drag frame (`e2e_input_state.txt`,
case `input_state`: `active`, `dragging` and `layout_generation` held across the
shift, then `active_is_zero=1` after release).

`endScrollArea`'s wheel handling is a separate, same-frame contract — wheel input
is consumed inner-first (LIFO across nested `ScrollArea`s) and reflected into the
viewport's scroll offset in the same frame, not the next one. That is documented
on the `ScrollState` doc comment in `context.zig` and summarized in
`libs/gui/README.md`'s "Frame order and hit-test timing" section. It is not in
tension with the one-frame lag decided here: general widget rects settle one
frame late; scroll offset settles the same frame.

## Related

- `libs/gui/README.md`, "Frame order and hit-test timing"
- `examples/37_gui_torture/README.md` (the `input_state` case, and the nested-
  scroll unit tests in `libs/gui/src/widgets.zig`)

## Revision history

- 2026-07-29 First version. Records the previous-frame-rect-cache hit-test
  decision and its three rejected alternatives. The contract itself is older than
  this record: the torture-suite evidence quoted above was observed on 2026-07-18.
