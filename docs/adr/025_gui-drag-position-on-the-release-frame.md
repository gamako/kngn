# ADR-025: A drag reads the release-edge position on the frame it ends (`libs/gui`)

- Status: Accepted
- Date: 2026-08-02
- Category: GUI, immediate-mode widget API, input event ordering

## Context and problem

`libs/gui` aggregates a frame's pointer events into one `Input` state. `pushEvent`
applies each event of the frame in turn to a single `mouse_pos`, so after the frame's
events are drained `mouse_pos` holds the position of the **last** event of the frame,
whichever kind it was.

That is what hover needs. It is not what a drag needs. A frame routinely carries more
than one pointer event, and the platform commonly delivers a left `mouse_up` followed
by a further `mouse_move` inside the same frame — lifting a finger off a trackpad is
the everyday case, because the contact patch shifts as it leaves the surface. On that
frame:

1. `mouse_pos` ends up at the post-release position, not at the position the gesture
   ended at.
2. `buttonBehavior` deliberately still reports `held = true` on the release frame
   before clearing `active_id`, so that a drag gets one last chance to settle on its
   final value.
3. A widget that turns a pointer position into a value while held — a slider knob, the
   saturation/value square, the hue bar — reads `mouse_pos` inside that `held` branch.

Together those three mean the value a drag settles on is taken from a position the user
reached *after* letting go. A slider visibly slides to a different value at the moment
of release. The same shape reaches widgets that consume movement rather than absolute
position (a splitter, a scrollbar thumb, which read `mouse_delta`), the click test in
`buttonBehavior` itself (a click can be lost, or granted, by a post-release move), and
the drop-target hit-test in `dnd.zig` (a drop can be lost).

`Input` already latched the coordinates of both pointer edges — `mouse_pressed_pos` and
`mouse_released_pos` — and `buttonBehavior` already used `mouse_pressed_pos` to decide
where a press originated, for exactly the mirror-image reason (a same-frame "down
outside then move inside" must not acquire). The release side of that pair had no
counterpart rule.

## Decision

`Input` owns the notion of the **effective drag position** and exposes it as a contract
that every drag site reads:

```zig
pub inline fn dragPos(self: *const Input) Vec2 {
    return if (self.mouse_released.left) self.mouse_released_pos else self.mouse_pos;
}

pub inline fn dragDelta(self: *const Input) Vec2 {
    const p = self.dragPos();
    return .{ .x = p.x - self.mouse_prev.x, .y = p.y - self.mouse_prev.y };
}
```

- While a drag continues, `dragPos` is the frame's latest pointer position. On the frame
  the left button is released it is the position at the release edge, so an event that
  arrives after that edge cannot move the value the drag settles on.
- `dragDelta` is the same rule for widgets that consume movement. It equals `mouse_delta`
  on every frame except the one a drag ends on.
- `mouse_pos` keeps its meaning unchanged: the frame's final position. Hover, the cursor
  readout and the wheel-target test go on reading it, because "where is the pointer now"
  is a different question from "where did this gesture end".
- `buttonBehavior`'s existing contract is untouched: it still reports `held = true` on
  the release frame and then clears `active_id`. Only the *coordinates* a drag uses move;
  *when* a drag ends does not.

Placing the rule on `Input` rather than in each widget is the point of the decision. The
alternative — every drag site deciding for itself — is how the defect arose in the first
place: the press side of the pair was wired through every site, the release side through
none, and nothing in the code made that asymmetry visible.

`buttonBehavior`'s click test reads `dragPos` too, giving press and release symmetric
treatment: the press must originate inside the visible region (`mouse_pressed_pos`), and
the release must land inside it (`dragPos`, which is `mouse_released_pos` on that frame).

## Rejected alternative

**Have `buttonBehavior` stop reporting `held` on the release frame and return a
`released` result carrying the release coordinates instead**, letting each widget finish
its drag from that.

| Why rejected | |
|---|---|
| Wrong shape for the problem | The defect is not about *when* `held` ends; it is about *which coordinates* a drag uses. Changing the end-of-drag signal addresses a question nobody asked, and leaves the coordinate question still to be answered per widget. |
| It removes a wanted behaviour | Settling on a final value on the release frame is the behaviour a drag should have. Dropping `held` there would force every drag widget to reimplement that settling step against a second result field, multiplying the code paths that can get it wrong. |
| It does not fix the delta consumers | A splitter and a scrollbar thumb read movement, not position. A `released` result carrying a position leaves them broken, so a `dragDelta` equivalent is needed regardless — at which point the `Input`-level contract is already doing the work and the `buttonBehavior` change buys nothing. |

## Relationship to ADR-016

ADR-016 and this record address different timing problems and neither depends on the
other. ADR-016 is about **cross-frame** timing: a widget hit-tests against the previous
frame's rect cache because this frame's layout is not known at widget-call time. This
record is about **intra-frame** timing: several pointer events land within one frame and
their order decides which position a gesture is judged by. A drag reads a rect from the
previous frame (ADR-016) and a position from this frame's release edge (this record);
the two compose without interacting.

## Consequences

- Every widget that turns a held pointer into a value reads `Input.dragPos` or
  `Input.dragDelta` rather than `mouse_pos` or `mouse_delta`: the slider knob, the
  saturation/value square, the hue bar, the splitter, both scrollbar thumbs, and the
  drop-target hit-test.
- `buttonBehavior` confirms a click against the release-edge position, so a click is
  neither lost nor invented by a post-release move.
- Widgets that already latched the release edge themselves keep working unchanged
  (single-line text selection gates its live drag on `mouse_buttons.left`, which is
  already false on the release frame, and handles the release in its own branch).
- Applications that consume raw pointer positions from their own event snapshot rather
  than through a widget must apply the same rule at their boundary; the pixel editor's
  canvas, selection, shape, bezier and eyedropper paths each carry the release position
  in their per-frame input struct for this reason.
- Hover, the cursor position readout and the wheel-target test are deliberately *not*
  changed. They ask where the pointer is, and `mouse_pos` remains the answer.
- The rule is pinned by tests driving the input sequence
  `down(X0) → move(X1) → up(X1) → move(X2)` and asserting that each drag consumer settles
  on `X1`.
