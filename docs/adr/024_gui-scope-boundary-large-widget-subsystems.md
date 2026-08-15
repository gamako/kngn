# ADR-024: GUI scope boundary — multiline text editing, list virtualization, and window docking

- Status: Proposed for §1 and §3. §2 (list virtualization) is accepted and
  implemented. The record as a whole stays Proposed because docking and
  multiline editing are still open.
- Date: 2026-08-02
- Updated: 2026-08-16
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
  every backend (macOS metal, X11/Wayland, GDI/D3D11) before floating panels are
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

### 2. List virtualization — implemented (narrow experiment)

**Trigger.** An external `kit` consumer needed a gallery of several hundred composite
thumbnails. The every-row-every-frame model forced that app into manual paging — a
product-shape problem at the data size it already had, not a crossing of this ADR's
≈4ms GUI-Context-frame bar. That is what opened the work. Variable row height and a
lazily-fetched data source stay out of scope.

**What shipped.** `Context.beginVirtualList` / `endVirtualList` /
`virtualScrollToRow` in `libs/gui/src/widgets.zig`: a thin helper on
`beginScrollArea`, not a replacement. Fixed row height, in-memory source. The
caller builds only the half-open `VirtualRange` (plus overscan). Content height is
declared `.fixed = total_h`, so ScrollArea's declared-fixed → recorded extent →
measured order uses the full list height even though only the visible rows are
children. Horizontal scroll is off (`content_width = .grow`). Vertical padding is
illegal (it would shift the first row and under-size the range); extra vertical
space belongs on an outer box. The leading spacer is emitted only when
`first > 0`. Rows themselves are the only supported focus target (the
`beginListboxRow` roving tab stop); a focusable widget inside a virtual row is
unsupported. `pollListNav` is unchanged: the caller applies nav, then
`virtualScrollToRow`, then `beginVirtualList`, so the selected row is in the same
frame's window. An unbuilt row is not touched in `PerIdStateStore` and may return
at defaults after a capacity trim; focused / active / hot entries stay protected.

**Wheel timing.** Previous-frame geometry decides *who* is first: each
`endScrollArea` records `{id, viewport rect, depth, end-order serial}` and
`beginFrame` keeps that registry. The chain head is the deepest recorded area
under the cursor; same-depth overlaps use reverse end-order so the order matches
end-time LIFO. Only that head consumes wheel in `beginScrollArea`, from its
*current* `scroll` and content size (the registry never stores a previous-frame
max). Other areas that have a previous-frame viewport consume leftover wheel
in `endScrollArea`. An area on its first frame has no previous-frame rect, so
it is not a wheel target; it becomes one on the next frame. The cursor used
for every wheel hit-test this frame is the one sealed with the chain (a later
`mouse_move` does not retarget consumption). Scroll writes settle in this
order: caller (`virtualScrollToRow` and similar) → thumb drag → chain-head
wheel → clamp. This is the same class of previous-frame hit-test trade-off as
ADR-016 / ADR-028.

**ADR-016 interaction.** A row that is first built this frame is not in
`rect_cache` and is not hit-testable until the next frame. Overscan hides that
lag for ordinary wheel steps (those rows were already built). Overscan is not a
resolution of the lag: a jump that lands past the overscan window still has a
one-frame hit-test delay. Wheel-at-begin plus overscan is the contract; it does
not claim the delay is gone.

**Measurement.** `zig build bench-gui-list-menu` (full `Context` frame —
`beginFrame` through `endFrame` and render — ReleaseFast, 1024×768, warmup 100,
1000 iterations, headless, zig 0.16.0, Apple M1 Max, 2026-08-16). Four points, 500 /
5000 rows × full / virtual. After warm-up every case had 0 GPA alloc calls.
The ≈4ms bar below is this ADR's own re-check threshold, not a repository-wide
performance rule.

| rows | mode | avg | min | p95 | arena peak | vs ≈4ms bar |
|---|---|---|---|---|---|---|
| 500 | full | 483µs | 475µs | 494µs | 1.12 MiB | under |
| 500 | virtual | 229µs | 225µs | 234µs | 109 KiB | under |
| 5000 | full | 3.32ms | 3.20ms | 3.56ms | 9.52 MiB | under (p95 ≈89% of the bar) |
| 5000 | virtual | 227µs | 224µs | 234µs | 109 KiB | under |

The 2026-08-02 500-row full-build figures (avg 448–471µs, Apple M1 Max, zig
0.16.0) remain the pre-virtualization baseline. 5000-row full build stays
under the ≈4ms bar on this host; virtualization's value at that size is the
flat ~230µs and the 100× smaller arena, not a bar crossing. The bench is
still a headless microbenchmark, not the shell's real on-screen frame; pair
it with `docs/performance-measurement.md`'s present-path measurement when
making a performance claim.

**What is still out of scope.** Variable row height, lazily-fetched rows, and
any contract where a virtual row contains its own focusable widgets.

### 3. Multiline text editing — likely wanted, not built yet

**Current state.** Display wrapping and declarative overflow are implemented
(`Context.text` with `TextOptions.wrap` / `.overflow`). `label` / `labelEx` split on
paragraphs but do not auto-wrap. `labelEllipsis` / `ellipsizeText` stay for callers that
need `truncated` in the same frame (examples 40 / 42 / 43). That is display only.

`libs/gui/src/text_edit.zig`'s own doc comment still states the *editing* contract:
grapheme clusters, multi-line layout, and glyph fallback are not implemented, and
newlines are rejected on the `TextBuffer` edit path. This ADR's open item is multiline
*editing* (`textInputId` remains single-line), not display wrap. Grapheme clusters and
glyph fallback are already a separate, already-documented boundary of the same file;
adding line wrap on the display path does not close those, and this record does not fold
them into what "multiline editing" needs.

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

§2 is implemented as the narrow experiment described there. §1 (docking) and §3
(multiline editing) are unchanged: they stay documented absences with explicit
re-opening conditions. Callers that want a large fixed-row in-memory list use
`beginVirtualList` and skip out-of-range `beginListboxRow` calls; the every-row
`beginScrollArea` path remains for lists that are already cheap to build in
full. Wheel consumption for the deepest ScrollArea under the cursor moves from
`endScrollArea` to `beginScrollArea`; nested remainder propagation, the
sealed-cursor hit-test, and a new area not being a wheel target on its first
frame are part of that contract.

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
