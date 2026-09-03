# ADR-028: GUI input is accepted outside a frame and staged for the next one

Status: Accepted

## Context

`libs/gui` is immediate mode: a caller opens a frame with `beginFrame`, hands the frame its
input, builds widgets, and closes the frame with `endFrame`. Until now `pushEvent` and
`setComposition` used to require the frame-build interval, so input was only legal between those two calls.

An application author writing against `kit` forwarded window events in the order a native
loop makes natural — poll the window, hand the events to the GUI, then open the frame — and
the assert fired. That is the visible half of the problem. The invisible half is worse:
`std.debug.assert` compiles to `unreachable`, which is removed in `ReleaseFast` and
`ReleaseSmall`. In those modes the events are applied to `Input` immediately, and then
`Input.beginFrame` clears exactly the fields they set:

| Field | Kind | Survives the next `beginFrame`? |
|---|---|---|
| `mouse_pressed` / `mouse_released` / `keys_pressed` / `keys_released` / `scroll_delta` / `ordered_text_events` | edge | no — cleared |
| `mouse_pos` / `mouse_buttons` / `keys_down` | level | yes |

So a shipped build does not crash. It loses every click, keystroke and wheel notch while the
pointer keeps moving normally — a failure that reproduces only in the configuration the
author is least able to debug, and that points nowhere near the line responsible.

## Decision

**Input may be handed to the GUI at any point in the loop.** Inside a frame it applies
immediately, as before. Outside a frame it is staged and applied by the next `beginFrame`,
in arrival order, immediately after `Input.beginFrame` has cleared the previous frame's
edges and before any widget reads input.

The restriction is removed rather than enforced: the only reason it existed was that
`Input.beginFrame` clears edges, which is an implementation detail of this library and not
something a caller should have to work around. Ordering input relative to the frame is now a
free choice, and both orders produce the same result — a property a test pins directly.

`pushEvent` keeps returning `void`. Calling it outside a frame is not a failure, so there is
nothing for a caller to handle; the one way the call can still fail is exceeding the staging
capacity below, which is a separate contract and panics rather than returning.

### Staging is bounded

Staging is a fixed array (`StagedInput.capacity`, 256 events) plus a fixed buffer for preedit
text. It allocates nothing and cannot grow, so a caller that stops opening frames cannot turn
staging into an unbounded queue. The number is a memory bound and an anomaly boundary; it is
not a claim about how much input a system can deliver between two frames.

**Capacity is a separate contract from ordering, and exceeding it is not silent.** When the
buffer is full, adjacent events that carry nothing but their newest value are merged first:
consecutive motion collapses to where the pointer ended up, consecutive wheel events sum their
deltas. Both are exactly what applying them one at a time would have produced, so merging is
not a loss. Merging is adjacent-only, so a buffer holding alternating motion and presses has
nothing to merge even though it is not all discrete events. If no merge frees a slot, the call
panics.

This is reachable by a correct application, not only by one that never opens a frame: a long
enough gap between frames with enough discrete input in it will get there. It is a capacity
limit being exceeded, which is why it is stated as its own contract rather than folded into
the ordering rule above.

Dropping a discrete event is not an option, because they are not interchangeable: losing a
`mouse_up` leaves a button held down for the rest of the run, and losing a `key_up` leaves a
key held. A policy of "drop the oldest" or "drop the newest" would reintroduce, at a different
address, precisely the silent input corruption this decision exists to remove.

### Preedit text is copied

`CompositionState.text` is a borrowed slice, valid through the frame it is handed to. Staging
outlives that frame, so a staged composition copies the bytes into a buffer the GUI owns; the
alternative — telling callers their slice must now stay alive until the *next* frame opens —
would replace one hidden lifetime rule with another. Staged compositions are latest-wins, and
text longer than the buffer is clamped at a codepoint boundary (a preedit is display-only, so
clamping it degrades what is shown rather than corrupting state); the caret offset follows the
same clamp, since it is a byte index into that text. A counter of how often clamping happened
is kept next to the buffer as an internal diagnostic — it is not a probe and not part of the
published surface.

Staging is stored inline in `Context`, which grows it by a few kilobytes. `Context` is a
long-lived per-application object, so this is a one-off cost rather than a per-frame one; it is
noted here because a `Context` held on the stack grows by the same amount.

## The contract by phase

| | `pushEvent` / `setComposition` | Widget calls, `endFrame` | `beginFrame` |
|---|---|---|---|
| Before any frame | staged for the next frame | contract violation | opens the frame |
| Frame open | applied immediately | expected | contract violation (double open) |
| After `endFrame` | staged for the next frame | contract violation | opens the next frame |

Only the input row changes with this decision. Structural violations — opening a frame twice,
building widgets outside a frame, leaving a box, a disabled scope or a slider group unclosed,
and the frame-boundary rules of the popup and menu APIs — remain violations, because a Context
in that state cannot produce a meaningful frame.

**Those are out of scope here.** Unlike input ordering, they cannot be answered by accepting
the call, so they need a different mechanism — a check that survives optimisation, and a way to
test that a shipped build still has it. Scoping the two together would have made this decision
about a mechanism rather than about a contract. The boundary is drawn where the answers differ:
input is accepted, structure is rejected, and only the first is settled here. The second is
settled in [ADR-029](029_gui-lifecycle-violations-fail-in-every-build.md).

## Verification

| Property | How it is checked |
|---|---|
| Staged input arrives, in order, with its edges intact | unit test in `input.zig`, running in every optimisation mode |
| Staging before the frame equals pushing inside it | unit test comparing two `Input` instances event for event |
| Motion and wheel coalesce without losing the total | unit tests filling the buffer past capacity |
| Discrete events are never merged away | unit test asserting a full buffer of presses frees nothing |
| Preedit is copied, clamped on a codepoint boundary, latest-wins | unit test that overwrites the caller's buffer after the call |
| The hit-test, drag and scroll contracts are unchanged | the existing `libs/gui` suite and the GUI torture example's end-to-end cases |

The path being changed runs at event time — a handful of events per frame — and applying the
staged buffer is proportional to the events held, never to pixels or samples. The performance
rules for all-pixel and real-time code therefore do not apply to it.

## Alternatives rejected

**Document the ordering rule and leave the assert.** The rule would be correctly written and
still silently violated in shipped builds, because the check is not present there. Writing
down a contract that the code stops enforcing exactly when it matters most is not a fix.

**Make out-of-frame input fatal in every build.** This enforces a restriction that has no
reason to exist. It converts a natural loop ordering into a crash rather than into behaviour.

**Return an error from `pushEvent`.** Same objection, plus it pushes a failure case into every
call site of every consumer for a condition that can simply be handled here. A caller cannot do
anything more useful with `error.OutsideFrame` than what staging already does.

**A frame token: `beginFrame` returns a value that `pushEvent` requires.** This looks like it
makes the misuse unrepresentable, and it does prevent the "before the first `beginFrame`" case.
It does not prevent the rest: Zig has neither move semantics nor lifetimes, so a token can be
copied and kept, then used after `endFrame` or during the following frame. Guaranteeing
temporal validity would still need a generation counter checked at run time — the token buys a
partial compile-time check at the cost of an API that still has to do the whole check anyway.

**Split `Context` into a persistent half and a frame half, moving the widget API onto the frame
half.** This is the complete form of the token idea and inherits the same run-time check. It
also mismodels the library as it stands: `endFrame` is not the end of GUI work. The pixel
editor draws its overlay and its menu-bar popup after `endFrame`, and the menu API is a
post-frame contract by design. A two-way "inside the frame / outside the frame" split cannot
express an API that is legitimately used after the frame closes.
