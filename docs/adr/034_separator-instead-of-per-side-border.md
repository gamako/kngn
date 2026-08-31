# ADR-034: A separator is a sibling box, not a per-side border

- Status: Accepted
- Date: 2026-09-01
- Scope: how a rule on one edge is drawn in `libs/gui`. It adds
  `gui.separator` / `ctx.separator` and leaves `BoxConfig.border` a four-sided
  value. The policy that makes an addition to the published surface one-way is
  [020](020_kit-versioning-and-maturity-gate.md).

## Context and problem

`BoxConfig.border` is a `Border{ color, thickness }` applied to all four sides.
The most ordinary need in a screen — a rule under the header, a divider between
two panes, a hairline above a footer — is a rule on **one** edge, and there is no
way to ask for it. Every caller writes the same three lines instead: a box that
is `.grow` on one axis, one pixel on the other, with a background colour.

This is not theoretical. Assembling one screen (`examples/47_screen_layout`) hit
it immediately: the header sits on `surface.raised` and the body on
`surface.canvas`, and without a line between them the two areas read as one loose
gradient rather than two regions. The sample had to define a local `rule()`
helper, and every application that draws a divider defines the same one.

Every comparable library has the feature: CSS `border-bottom`, Qt
`QFrame::HLine`, Dear ImGui `Separator()`, Flutter `Divider`.

## Decision

**`Border` stays four-sided. A one-edge rule is a helper that emits one ordinary
box.**

```zig
pub const SeparatorOpts = struct {
    color: ?Color = null,     // null → style.border_tokens.normal, resolved per call
    thickness: i32 = 1,       // must be positive
};

pub fn separator(ctx: *Context, opts: SeparatorOpts) void
```

The box is `thickness` on the parent's **main** axis and `.grow` on its **cross**
axis, so the orientation follows the parent's `direction` — a `.column` parent
gets a horizontal rule, a `.row` parent a vertical one — read from the innermost
box open at the moment of the call. The layout engine, the `Border` type and the
draw path are untouched.

### Why a per-side border does not fit the problem

**A rule occupies space in the flow; a border does not.** The line under a header
takes a pixel of the header's height, and everything below it moves down by that
pixel. `border` is painted inside the box's rect and by contract does not affect
measure or placement. So the two are not the same shape of thing: expressing a
rule as a border would mean either a border that does change layout (breaking the
existing contract for every box that has one) or a rule that does not occupy
space (which is not what a divider is).

**Per-side multiplies the contracts that have to be defined.** Four sides with
independent thickness raises questions the uniform value never had to answer: how
a side interacts with `radius` at each corner, which sides `clip_children` cuts,
what order sides paint in relative to children and to each other, and what
happens where two adjacent boxes' borders meet. None of these have a single
obvious answer, and all of them become part of the published contract.

**It taxes the boxes that draw no rule.** Widening `Border` puts a per-side
branch on the draw path of *every* box, so a tree that never draws a divider pays
for the feature — the failure mode named in `AGENT.md`'s "A new feature costs
nothing to the code that does not use it". A separator adds one box where a
caller asked for one, and nothing anywhere else.

**One field would carry two contracts.** A `Border` value would mean "this
outline, on four sides" in one call and "these sides, each possibly absent" in
another, and a reader could not tell which from the type. Splitting the two ideas
across two names keeps each contract stated once.

## Rejected alternatives

**Extend `Border` to per-side.** Above.

**Take the orientation as an argument, the way `splitter` does.** `splitter`
(`libs/gui/src/widgets.zig`) has the same box shape and takes `.vertical` /
`.horizontal` explicitly. For a separator that would be a silent hazard: a
caller passing `horizontal` inside a `.row` parent gets a box that is `.grow` on
that parent's *main* axis. It still paints, but it consumes the rest of the row and
lays out as a block instead of a divider. Inference cannot pick the wrong axis. The
reason `splitter` differs is that its orientation is part of its interaction
contract — which axis a drag resizes — while a separator's only orientation
question is which way the line runs, and the parent already answers it.

**Include an `inset` (a gap at both ends) now.** A published surface is one-way
(020), and no call site in the tree wants one yet. A caller who needs one wraps
the rule in a padded box.

**Fail loudly when the rule would have zero length.** A `.fit` cross axis with an
intrinsic sibling is a correct and common use, so a debug assertion would stop
working code. See Consequences for what happens instead.

**Use `.percent = 1.0` on the cross axis instead of `.grow`.** Both a `.fit`
parent's measure and a wrap line's cross size count a `.percent` child the same
way they count a `.grow` one, so this changes nothing.

## Consequences

**The rule inherits the layout engine's existing grow-inside-fit behaviour, and
that is the one thing a caller has to know.** Being `.grow` on the cross axis, it
fills a size it does not itself establish — and **who establishes that size is not
the same in a wrap box as in an ordinary one**:

- not wrapping: the parent's resolved content size on the cross axis, from the
  parent's own `.fixed` / `.grow` / `.percent` / `min_*`, or from the max
  `computeMeasured` takes over a `.fit` parent's other children. There a **leaf**
  contributes its intrinsic measure whatever `Sizing` it declares (so a wrapping
  `ctx.text`, created `.grow` on the width axis, does give the rule its length), a
  **box** sized `.fixed` or `.fit` contributes its resolved size, a **box** sized
  `.grow` or `.percent` contributes its `min_*` — zero by default but not always
  zero, since a `min_width = 20` sibling gives the rule 20 — and an **anchored**
  child contributes nothing.
- `wrap = true`: the cross size of the line the rule lands on, which
  `lineCrossSize` takes over **that line's children only**, and **by declared
  `Sizing` alone — there is no leaf exception on this path**. A `.grow`-declared
  leaf therefore contributes its `min_*` rather than its intrinsic size, and the
  parent's own cross sizing does not reach the line at all: a rule alone on a line
  inside a `.fixed`-width wrap box is zero.

Wherever nothing contributes, the rule is zero length and disappears with no error. §5.2 of
[docs/app-authoring.md](../app-authoring.md) describes the symptom of this class of
defect, and the doc comment on `separator` states the rule above and points there
for the symptom.

**An inset divider is a padded wrapper**, and that wrapper needs its own explicit
main-axis size and cross-axis `.grow` — otherwise it walks into the zero-length
case above.

**Nothing existing changes.** `Border` keeps its contract, so every frame that
draws a border is bit-identical, and the draw path gains no branch.
