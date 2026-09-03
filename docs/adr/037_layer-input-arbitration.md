# ADR-037: Frame-latched input routing for declarative GUI layers

- Status: Accepted
- Date: 2026-09-03
- Category: GUI, layers, input arbitration

## Context

GUI layers are declared at the point where an application builds a box, but their final
geometry is not known until `endFrame`. Widget results, on the other hand, are returned while
the tree is being built and must use the previous completed frame's geometry, as established by
ADR-016. A route derived from the current marker submission would therefore depend on build
order: a low layer could claim a press before a higher layer is encountered, and the result could
not be revoked.

The layer marker is also the declaration of presence. The application owns the state that decides
whether a marker is submitted; the context does not keep a second open bit.

## Decision

At `beginFrame`, the context selects one route owner from the modal layer slots that were placed
in the previous completed frame. The layer ordering is the same z/serial order used for emission,
so the frontmost previous-frame placed modal layer owns the generic route. A layer first submitted
in the current frame is drawn there, but cannot own input until the next frame. Current build
order cannot change the route.

The route stores the owner's `LayerKey`, not an index into the retained slot array. Layer slots
are compacted at frame seal, so retaining an index would make a later focus or gate read silently
refer to another layer. Wheel records expose only `root_order`; z, serial and key details remain
inside the context.

The route gives the owner an O(1) scope containing pointer, keyboard, focus and wheel permissions.
The main scope is disabled while a modal route exists. Focus entries are recorded with their owner
metadata, and one `focusEntryAllowed` helper chooses the frontmost scope during traversal. This
keeps main entries available for restoration without allowing them into a modal traversal. Main
focus is saved when a modal route first appears and restored when the route goes away, but focus
owned by a layer whose submitted marker is unplaceable is cleared at that frame's seal and is not
restored if the layer later reappears.

`wantsMouse`, `wantsKeyboard` and `wantsTextInput` use the begin-frame generic-layer latch and
therefore have the same answer everywhere in the frame. The legacy popup contribution remains
the existing frame-local predicate until the popup migration unifies the two systems. Raw
`ctx.input` is intentionally not filtered; hosts that handle raw shortcuts gate them with the
corresponding `wants*` result.

## Synchronization-frame consequences

If a marker is submitted but its anchor is missing, its previous-frame modal route remains for
that frame even though the layer is not drawn. Pointer and keyboard input are absorbed from the
main tree. The missing layer has no reachable current geometry, so focus traversal cannot select
its controls and any existing focus owned by it is cleared at seal. Raw input remains available to
the layer consumer, including Escape handling. This one-frame invisible absorption follows from
ADR-016's requirement that input agree with the last visible geometry as closely as the synchronous
API permits.

If the marker is omitted because the application closed it, the previous route remains for one
frame, then the slot is released at that frame's seal. The main tree owns the following frame.
This is the result of marker presence and previous-frame routing; no pending close state is added.

The legacy popup route has higher priority than a generic layer when both are present. Popups are
emitted in the final-overlay phase after layer emission, so the input winner follows visual order.
The eventual popup migration will replace the separate popup predicates and route storage with
this single ordered route rather than add another arbitration rule.

## Rejected alternatives

| Alternative | Reason |
|---|---|
| Build-order route selection | A lower layer can claim a synchronous press before a higher layer is submitted, and the result cannot be revoked. |
| Context-owned open bit | It duplicates application state, creates pending/current phase semantics, and delays drawing without solving the previous-frame hit-test constraint. |
| Retain a slot index in the route | Slot sealing uses swap-remove compaction, so an index can silently name the wrong layer after the route has been latched. |
| Filter raw `ctx.input` in place | Raw event state is also used by application-level shortcuts; changing it would make the input object mean different things depending on GUI submission. Host gates are the single boundary for raw consumers. |

## Related

- [ADR-016: Widget hit-test runs against the previous frame's rect cache](016_gui-sync-hit-test-against-previous-frame-rect-cache.md)
- [ADR-021: Keyboard focus traversal and the focus ring](021_gui-keyboard-focus-traversal.md)
- [ADR-028: Input staging outside a frame](028_gui-input-staging-outside-a-frame.md)
- `libs/gui/docs/layout.md`, "Layer input timing"

