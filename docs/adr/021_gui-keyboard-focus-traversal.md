# ADR-021: Keyboard focus traversal and the focus ring (`libs/gui`)

- Status: Accepted
- Date: 2026-08-01
- Category: GUI, keyboard interaction, immediate-mode widget API

## Context and problem

`Context` has carried a `focused_id` and a `claimFocus` since text input needed one, and
both are written in terms of a plain widget id, so nothing about them is specific to text.
What was missing is everything around them: no widget except a text field ever claimed the
focus, nothing moved it with the keyboard, and nothing drew it. A checkbox could be clicked
but never reached, and an application that wanted the focus to follow interaction had to
call `claimFocus` itself after every widget — glue that was written out by hand in the
settings-shell example, once per control across three forms.

Building the missing part raises three questions that an immediate-mode library has to
answer differently from a retained-mode one.

**What is the order?** There is no widget tree to walk between frames. The only ordering
that exists is the order in which the application submitted the widgets during the frame,
and that order is only complete once the frame is.

**When does a move take effect?** A frame's widgets have already been submitted by the time
the order is known, so a Tab arriving during the frame cannot change what that frame drew.

**When is a ring wanted?** A user who clicked a widget can see where the focus went. A user
who pressed Tab cannot. Drawing a ring in both cases puts a highlight on the interface every
time anything is clicked.

## Decision

**Traversal order is submission order.** A widget enters the order by calling
`registerFocusable` while it is being submitted, so the order is rebuilt every frame and
matches draw order, which is what the user sees. A widget behind a branch that was not taken
is simply not submitted, and leaves the order without anyone tracking its disappearance.

**A move resolves at the end of the frame and shows on the next one.** `endFrame` resolves a
pending Tab after emitting the draw commands, so the frame that saw the Tab draws with the
old focus and the following frame draws with the new one. This is the generation model
ADR-016 already established for hit-testing, applied to the same problem: the information
needed to answer arrives after the answer was needed. A test or replay script that injects
Tab therefore steps one more frame before observing the result.

**A pointer press in the same frame wins.** Pressing the pointer settles the focus by itself
— onto a widget that claims it, or off everything when it lands on nothing — and that is a
more specific statement than a Tab that happened to arrive in the same frame, so the pending
move is dropped. The rule keys off the press alone rather than off whether a widget claimed
anything, which is what makes the three cases (press on a focusable widget, press on empty
space, press on something that is not focusable) come out consistent.

**The ring means "focus-visible", not "focus".** A second flag, `focus_visible`, records
whether the focus was reached with the keyboard; only Tab sets it, and `claimFocus` clears
it. The distinction is the one CSS draws with `:focus-visible`, and for the same reason.

**The ring is drawn by the node that carries the id.** Widgets build layout nodes and do not
draw at call time, so a widget cannot draw its own ring — it does not know its rect yet.
`emitNode` draws it instead, immediately after the node's border, using that frame's rect.
It follows the border's clipping rule as well, sitting above the node's children and being
clipped by the ancestor rather than by the node's own clip.

**Reachability is geometric, not just structural.** Being submitted puts a widget in the
order; being visible keeps it there. Resolution runs after the rect cache has been refreshed
with the frame's real geometry, and skips anything that measured to nothing or was clipped
entirely away, so Tab cannot land somewhere the user cannot see.

**Activation is part of the contract.** Space and Enter activate a focused button-like
widget, and the arrow keys step a focused slider. Traversal without activation would give
the keyboard a way to point at controls and no way to use them, and would leave the ring
decorative. Auto-repeat does not activate twice, a modifier turns the chord into someone
else's shortcut, and none of these keys are consumed — an application that gives Tab or
Space its own meaning still sees them.

**A selectable label joins the order only when asked.** `selectableLabel` is text a user may
drag across rather than a control, and lists are built out of it: registering it by default
would turn a five-hundred-row list into five hundred Tab stops. `SelectableLabelOpts.focusable`
opts the ones that really are controls, such as a navigation sidebar, back in.

**An open popup suspends all of it.** While a popup is open nothing registers, nothing
activates, and no ring is drawn. The popup has taken over input, and a ring behind it would
point at a widget that cannot be operated. The background focus itself is left alone, so it
is still there when the popup closes.

## Consequences

An application no longer writes focus glue: pressing a widget focuses it, and Tab reaches
it. The settings-shell example lost the whole of its `claimInteract` layer, the click
fallback it needed underneath, and a piece of state that existed only to record which of the
two paths had run.

The one-frame delay is a real property of the contract, not an implementation detail to be
removed later, and tests and replay scripts have to account for it.

`focus_order` is rebuilt each frame into a list that keeps its capacity, so a steady
interface allocates nothing for it after its first frames.

## Deliberately not decided here

- **Escape does not clear the focus.** Applications already give Escape their own meaning.
- **The focus does not scroll itself into view.** Tab reaching a widget that is scrolled off
  screen is a successful move under this contract. Long forms and long lists will want
  better, and that is a question about scroll containers rather than about traversal.
- **Two-dimensional drag widgets stay out.** A saturation square, a hue bar, a splitter and
  a scrollbar thumb have no agreed keyboard behaviour to give them yet.
- **A popup does not take the focus.** Popups run their own hit-testing and are not part of
  the traversal order.
