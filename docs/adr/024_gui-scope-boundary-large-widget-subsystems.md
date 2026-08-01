# ADR-024: GUI scope boundary — multiline text editing, list virtualization, and window docking

- Status: Proposed. This record is a proposal awaiting sign-off, not yet an accepted
  decision; nothing in `libs/gui` changes as a result of writing it.
- Date: 2026-08-02
- Category: GUI, immediate-mode widget API, scope

## Context and problem

The widget-repertoire measurement work (a widget gallery cross-referenced against WAI-ARIA
APG and the Dear ImGui demo, plus several reproduction shells — a settings form, a
file/issue list with menus, a tracker-style grid, a game inventory) surfaced three feature
areas that other GUI toolkits offer and `libs/gui` does not: a multi-line text editor, a
virtualized (windowed) list for large item counts, and window docking (dragging a panel out
of its slot, drop-guide overlays, floating and tabbed panel groups). None of the three is a
gap the widget-repertoire work can close by adding one more widget. Each changes the shape
of a contract that already exists and works for what has been built so far:
`libs/gui/src/text_edit.zig`'s single-line text model, the list+menu shell's
every-row-every-frame model, and `libs/gui/src/panel_host.zig`'s fixed-slot panel model.
Building any of the three ahead of a concrete need means guessing at a contract this
document has no evidence to shape yet.

The three do not carry the same weight, and this record keeps them separate rather than
issuing one blanket "not now":

- **Docking** is a firm non-goal at the current project scale.
- **List virtualization** is not implemented and not ruled out — the opposite: this
  document's author expects a real need for it soon, and records what triggers building it.
- **Multiline text editing** sits in between: not needed by anything built so far, likely
  wanted eventually, recorded so the eventual work starts from an explicit list of what it
  requires rather than from scratch.

## Decision

### 1. Window docking — a firm non-goal for now

**What already exists and is not part of this non-goal.** `libs/gui/src/panel_host.zig`
implements a dock-*slot* system today: three fixed panel slots (left / right / bottom),
each stacking its registered panels vertically with a collapsible header, plus a fourth
slot, center, that holds no registered panels at all — `Panel.slot = .center` is rejected
at init time (`InitError.PanelInCenterSlot`) and the center rect is handed to the app as
plain content space. `gui.splitter` resizes the boundary between slots (the capability
matrix's "Window Splitter" row), and `panel_host.zig` already has its own persistence hooks
(`Persistence.read`/`write`, keyed by `PersistKey.slot` for a slot's `visible`/`extent` and
`PersistKey.panel` for a panel's `visible`/`open`). `Persistence` is a caller-supplied
read/write callback pair, not a built-in store: `examples/41_panel_host` demonstrates it
with an in-memory backing store (its own doc comment says so — "in-memory persistence"),
showing save and restore within a run. Carrying that across an actual process restart, onto
disk or wherever an application chooses, is the caller's own backend to write against this
same `read`/`write` interface. A user can resize slots and show or hide a panel today, and
the hook to save and restore that state already exists; that is already shipped and this
ADR does not touch it.

**What is out of scope.** True docking — dragging a panel by its tab so it detaches into a
floating window or redocks at an arbitrary position via a drop-guide overlay, several
panels sharing one region as a tab group the user assembled at runtime, an arbitrary
(non-four-slot) split layout, and persisting such a layout — is not implemented and is not
planned.

**Why not now.**

- Only one part of the above needs a new platform capability: a **floating** detached panel
  is a second top-level window, and `core/platform.zig` documents its window handling as "a
  single process and a single window" at module-storage level (the comment above `Window`'s
  module-level state). Multi-window support would have to land in `core/platform.zig` across
  every backend (objc/swift/metal, X11/Wayland, GDI/D3D11) before floating panels are
  possible at all. The rest — an arbitrary split layout replacing the three fixed slots, a
  drop-guide overlay, tab-group compositing, and persisting the result — could in principle
  be built inside a single window, and this ADR does not claim otherwise. It bundles all of
  it into one non-goal because even the single-window parts are, on their own, a project on
  the scale of the rest of `libs/gui`'s layout and widget system combined, and nothing built
  so far has asked for any piece of it (not just the floating half).
- Dear ImGui, the reference immediate-mode implementation this document's other comparisons
  already draw on (§5 of the capability matrix cross-references its demo), is publicly known
  to have developed docking in its own separate branch for a long stretch before merging it —
  offered here only as informal scale context for what "docking" tends to mean as an
  engineering effort in this style of GUI library, not a measurement this repository has
  taken, a specific duration this record asserts, or something this decision depends on.
- No shell built so far — settings form, list+menu, tracker grid, game inventory, the
  editor's own panel layout — has needed more than the three fixed slots plus resize,
  show/hide, and the persistence already described above.

**What would be required if this is revisited**, grouped by whether it needs a new platform
capability or fits inside the existing single-window model:

Buildable within a single window today:

1. A real layout tree for panel regions (arbitrary nested splits), replacing the three fixed
   slots (plus the reserved center) in `panel_host.zig`.
2. Hit-testable drop-guide overlays shown during a panel drag, built on the drag-and-drop
   primitive `libs/gui/src/dnd.zig` already provides (that primitive itself would not need
   to change; a docking system would be a consumer of it, the way `examples/43_game_inventory`
   is today).
3. Tab-group compositing: several panels sharing one region, switched by a tab strip
   (`Context.tabId` already exists and is a candidate building block, but panel identity and
   ordering across a runtime-assembled tab group is new).
4. Extending `panel_host.zig`'s existing `Persistence` mechanism from the current fixed
   fields (a slot's visibility/extent, a panel's visibility/open state) to an arbitrary
   layout topology and per-slot tab order — an extension of what is there, not new
   infrastructure from nothing.

Blocked on a platform capability this repository does not have:

5. A floating top-level window, which needs multi-window support in `core/platform.zig`
   across every backend.

**Concrete signal to reconsider.** An application in this repository needs to rearrange its
panels beyond resize, show/hide, and the persisted layout `panel_host.zig` already offers —
for example, popping a panel out to a second monitor, or letting the user assemble a custom
tab group — and the three-slot-plus-center model demonstrably cannot express what is
wanted. The concrete place such a gap would surface is the same place every other gap in
this measurement family has: a "custom / hack" entry in one of the reproduction shells'
observation sections in `docs/plans/PLAN_gui_capability_matrix.md` (for example §14.2, §15.2,
§16.2, §17), recording that an app had to build panel rearrangement by hand because
`panel_host.zig` could not express it.

### 2. List virtualization — not implemented, not ruled out

**Current state.** `examples/40_list_menu` — the reproduction shell built to exercise a
scrolling list — builds and lays out all 500 rows every frame with
`gui.beginListboxRow`/`endListboxRow` (each row also using `Context.labelEllipsis` and
`Context.labelEx` for its cells). `Context.beginScrollArea`/`endScrollArea` clips and offsets
the viewport; it does not skip building or measuring rows that fall outside it. There is no
visible-range computation, no row-height cache, and no API for a caller to supply rows lazily
from a data source larger than what is materialized per frame. (`examples/40_list_menu/ui.zig`'s
`ROW_H` constant already fixes every row to the same height in this shell — a smaller,
narrower experiment than general virtualization would be to compute the visible range from
that fixed height and skip building rows outside it, without yet solving variable row
height or a lazily-fetched data source. That narrower experiment is a candidate first step,
not something this record has built or measured.)

**The measurement this decision rests on.** `zig build bench-gui-list-menu` (500-row
list+menu shell, full `Context` frame — `beginFrame` through `endFrame` and render —
ReleaseFast, 1024×768, warmup 100, 1000 iterations; measured on Apple M1 Max, zig 0.16.0,
2026-08-02, across 3 runs): **avg 448–471µs, min 427–448µs, p95 459–524µs**. For comparison,
the plainer `bench-gui-frame` benchmark measures avg ≈263µs at 500 bare `buttonId` rows and
avg ≈416µs at 1000 bare `buttonId` rows, at the same scale and viewport. That second
benchmark has no toolbar, menu bar, or filter row and a different per-row shape, so this ADR
does not read the two totals as a validated per-row cost multiplier — only as two whole-shell
figures that both land in the same order of magnitude. Both figures are recorded in
`docs/plans/PLAN_gui_capability_matrix.md` §15.1 item 1. Against a 60fps frame's software-path
budget (a 16.67ms period, documented in `docs/performance-measurement.md`), the list+menu
shell's ≈0.45–0.47ms **GUI-Context-frame time** (not a whole application frame — see below)
is under 3% of one such period. This record sets its own, narrower bar for "comfortably under
budget" when re-checking this decision: staying under roughly a quarter of that period (≈4ms)
for this GUI-Context-frame measurement alone, leaving headroom for the rest of an actual
frame (clearing, blitting, presenting) that this benchmark does not include — a bar today's
figures clear by a wide margin. This ≈4ms figure is this ADR's own re-check threshold, not a
repository-wide performance rule. The benchmark itself is a headless, display-less
microbenchmark of `beginFrame`→`endFrame`→`gui.render` only, not the shell's real per-frame
cost: it excludes a backend's blit/present cost, so it is one of the two measurements
`docs/performance-measurement.md` says a performance claim needs — a microbenchmark plus the
application's real, on-screen frame rate — and only the first exists for this shell today.

**Why not now.** The measurement above says the every-row-every-frame approach is not a
performance problem at the row counts measured (500, and 1000 in the plainer benchmark), and
no shipped application in this family — settings form, list+menu, tracker grid, game
inventory, all of them reproduction shells built to exercise `libs/gui` rather than end-user
products — has an actual requirement for a list larger than 500 rows. (`bench-gui-frame`'s
1000-row case and `examples/37_gui_torture`'s "volume" case, which can switch between 500 and
1000 rows, are synthetic stress tests exercised for their own sake, not an application asking
for more than 500 rows.) Building a virtualization contract ahead of a concrete consumer means
guessing at the shape that consumer will actually need (fixed vs. variable row height,
whether rows come from an in-memory array or a lazily-fetched source, how selection and
keyboard nav track an index that is no longer 1:1 with "the row currently built") — guesses
this document has no evidence to make well. This entry is deliberately not phrased as "we
will never build this": of the three features in this ADR, this is the one closest to being
needed.

**What would be required when it is.** At minimum: a visible-range computation derived from
scroll offset and a row height (fixed, or cached per row for variable-height content); an
index mapping from scroll position to data index, so an app can supply rows from a source
larger than what is ever materialized in one frame; and a `libs/gui`-facing contract change
where `beginListboxRow` call sites for out-of-view rows are skipped entirely rather than
built and clipped. That last part interacts with ADR-016's one-frame lag: a row's rect only
enters `rect_cache` once it has been built at least once, so a row that scrolls into view for
the first time is not yet hit-testable on the frame it appears — a real, and currently
unresolved, consequence of combining virtualization with the existing hit-test timing
contract.

**Concrete signal to reconsider.** Any of:

- An application in this repository has an actual requirement for a list past 500 rows. The
  right trigger is re-running `bench-gui-list-menu` (or an equivalent bench for the new
  shell) at the new row count and finding the measured GUI-Context-frame time is no longer
  comfortably under the ≈4ms bar this ADR defined above — not a row count guessed in
  advance; this document deliberately does not project today's 500-row figure out to an
  untested N.
- The application's real, on-screen frame rate (the second measurement
  `docs/performance-measurement.md` calls for, which this record has not taken) shows the
  existing 500-row shells are not comfortably inside budget once blit/present cost and a
  slower backend are included — a best-effort software-blit backend (X11, GDI) or a Debug
  build (measured elsewhere in this repository at roughly 3.6× a ReleaseFast build) are the
  concrete cases to check before assuming the headless microbenchmark above still applies.

### 3. Multiline text editing — likely wanted, not built yet

**Current state.** `libs/gui/src/text_edit.zig`'s own doc comment already states the
contract precisely: "Grapheme clusters, multi-line layout, and glyph fallback are not
implemented. Newlines are rejected on the `TextBuffer` edit path; label display still
advances one codepoint but does not wrap to the next line." This is not a gap this ADR is
discovering — it is an existing, deliberate boundary of `Context.textInputId`, restated
here only to record why it has been left alone rather than closed as part of the
widget-repertoire work. Grapheme clusters and glyph fallback are already a separate,
already-documented boundary of the same file; adding line wrap does not by itself require
solving either of those, and this record does not fold them into what "multiline" needs.

**Why not now.** Every reproduction shell built so far — the settings form, the list+menu
filter field, the tracker's per-track detail panel — uses single-line `textInputId` and none
of them has needed more. No shell in this family has exercised a text area, and no
measurement exists showing single-line input is a bottleneck for anything currently in the
tree.

**What would be required when it is.** A line-layout/wrap model, replacing
`text_edit.zig`'s per-codepoint single-line `TextLayout` with a paragraph model that tracks
wrap points (independent of, and not requiring, grapheme-cluster segmentation — wrapping can
be decided at codepoint boundaries the same way the current single-line layout already
walks codepoints); a caret and selection model across lines (vertical caret movement, and a
wrap-aware distinction between "start/end of the visual line" and "start/end of the logical
line", which single-line input does not need to distinguish); intra-widget scrolling (a text
view scrolling its own content independently of the widget's position, distinct from
`beginScrollArea`'s whole-region model, the way a text editor's own vertical scrollbar
differs from a page scrollbar); and IME composition running correctly across a buffer that
wraps and scrolls, which is a materially larger surface than composing into a single visible
line.

**Concrete signal to reconsider.** An application in this repository needs to accept more
than a single line of user-authored text — a multi-line note, comment, or code field —
and no existing widget can stand in for it (a single-line `textInputId` silently dropping
newlines, as it does today, is not an acceptable substitute the moment such a field is
needed for real content).

## Consequences

Nothing in `libs/gui` changes because of this record. It documents, for a reader of this
repository who has no access to any private task tracker, why three toolkit-standard
features are visibly absent from the widget-repertoire measurement's capability matrix, and
gives each a re-opening condition stated in terms of an application need or a measurement,
not a calendar date. The list-virtualization figures this ADR cites (§2) were re-measured
on 2026-08-02 against the shell's current `beginListboxRow`-based implementation and are
recorded, with method and conditions, in `docs/plans/PLAN_gui_capability_matrix.md` §15.1
item 1; they are expected to be re-measured again, not re-derived by extrapolation, the next
time list size becomes a live question.

## Related

- `docs/plans/PLAN_gui_capability_matrix.md` §5 (the APG × ImGui × `libs/gui` crosswalk;
  window docking does not appear in either reference pattern list), §15.1 item 1 (the
  `bench-gui-list-menu` figures cited above), and §14.2/§15.2/§16.2/§17 (the per-shell
  "custom / hack" records that are this project's actual signal for "a widget or subsystem
  is missing").
- `libs/gui/src/text_edit.zig` (the existing single-line contract, restated in §3 above).
- `libs/gui/src/panel_host.zig` and `examples/41_panel_host` (the three-slot-plus-center
  panel system, including its existing persistence hooks, distinct from the docking
  non-goal in §1).
- ADR-016 (the previous-frame rect-cache hit-test contract, relevant to virtualization's
  first-frame-visible row problem in §2).
- `docs/performance-measurement.md` (the 60fps/16.67ms frame budget, the requirement to
  pair a microbenchmark with a real on-screen frame-rate measurement, and the measured
  Debug/ReleaseFast gap cited in §2).
