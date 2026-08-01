# GUI capability matrix v0

## 1. Purpose and scope

This document is capability matrix v0: WAI-ARIA APG, the Dear ImGui demo, and the current libs/gui APIs placed in the same tables. `examples/35_gui_gallery` shows normal / endpoint states for existing widgets and empty sections for unsupported widgets. Abnormal / boundary cases belong to the torture suite; real-screen shells belong to the settings shell and list+menu shell scopes.

The state axes are fixed to these nine columns:

normal / hover / active / focused / disabled / empty / min / max / none

N/A is an explicit cell meaning not applicable; leave no blank cells. `demo` means a cell whose representative widget state is driven by input injection. `partial` means only some of the API's states are represented.

### Hot-path declaration

Gallery widget construction and DrawList appends run every frame. Cost is O(N) in the number of displayed items. No full-framebuffer pixel loops, full framebuffer copies, custom rasterizers, or RT-thread work are added. svSquare / hueBar / stepgrid drawing is delegated to libs/gui, so there is no new per-pixel path. State metadata, images, and Command/PopupItem data use fixed arrays; widget temporaries use the existing Context frame arena.

## 2. Sources

The matrix sources below are the primary documents fetched by the orchestrator via WebFetch on 2026-07-17.

| Source | URL | Version / fetch date |
|---|---|---|
| WAI-ARIA APG Patterns | https://www.w3.org/WAI/ARIA/apg/patterns/ | living document, no version label, 2026-07-17 |
| Dear ImGui | https://github.com/ocornut/imgui | v1.92.6, 2026-07-17 |
| KNGN libs/gui | libs/gui/src/widgets.zig / popup.zig / menu.zig / stepgrid.zig | workspace tree, 2026-07-17 |

## 3. APG 30 patterns

Accordion, Alert, Alert and Message Dialogs, Breadcrumb, Button, Carousel, Checkbox, Combobox, Dialog (Modal), Disclosure, Feed, Grid, Landmarks, Link, Listbox, Menu and Menubar, Menu Button, Meter, Radio Group, Slider, Slider (Multi-Thumb), Spinbutton, Switch, Table, Tabs, Toolbar, Tooltip, Tree View, Treegrid, Window Splitter.

## 4. ImGui demo sections

Basic, Trees, Collapsing Headers, Text, Images, Combo, List boxes, Selectables, Text Input, Tabs, Plotting, Color/Picker widgets, Drag/Slider widgets, Range widgets, Multi-component widgets, Vertical sliders, Drag and Drop, Querying item status, Layout & Scrolling, Popups & Modal windows, Tables, Menus.

## 5. APG × ImGui × libs/gui

| APG | ImGui | Current API / gallery category | Follow-up category |
|---|---|---|---|
| Accordion / Disclosure | Collapsing Headers | Unsupported; empty section | settings shell |
| Alert | Querying / message UI | Out of normal-path scope; reference only | torture suite |
| Alert and Message Dialogs | Popups & Modal windows | Unsupported | torture suite / settings shell |
| Breadcrumb / Landmarks | Layout | Unsupported at the semantic shell layer | settings shell |
| Button | Basic / Selectables | button / buttonEx / buttonId | settings shell / list+menu shell |
| Carousel / Feed | — | Unsupported | deferred |
| Checkbox | Basic | checkbox / checkboxId | settings shell / list+menu shell |
| Combobox / Menu Button | Combo / Menus | Composition only; no dedicated API | settings shell / list+menu shell |
| Dialog (Modal) | Popups & Modal windows | Distinct from popup modal absorption | settings shell |
| Grid | Tables / Selectables | stepgrid is not a substitute for APG Grid | list+menu shell / deferred |
| Link | Basic | No dedicated API. Do not substitute button | settings shell |
| Listbox | List boxes | `beginListboxRow`/`endListboxRow` + `gui.pollListNav` (roving tab stop, single selection) | list+menu shell / tracker shell |
| Menu and Menubar | Menus | menuBar / menuBarPopup / popup | list+menu shell |
| Meter | Plotting / Range | Unsupported | settings shell |
| Radio Group | Selectables | radio; exclusive state owned by the caller | settings shell / list+menu shell |
| Slider / Spinbutton | Drag/Slider widgets | sliderI32 / sliderF32; Spinbutton unsupported | settings shell |
| Slider (Multi-Thumb) | Range widgets | Unsupported | deferred |
| Switch | Basic | toggle | settings shell |
| Table | Tables | Column table unsupported | list+menu shell |
| Tabs | Tabs | `ctx.tabId` (selection follows focus, radioId's caller-owns-selection convention) | settings shell / tracker shell |
| Toolbar | Basic / Layout | row + button; no dedicated API | settings shell / list+menu shell |
| Tooltip | — | `ctx.tooltip(text)` (500ms hover delay, virtual-clock deterministic, screen-edge clamp via `popupContentWidth`'s clamp rules) | game inventory shell |
| Tree View / Treegrid | Trees / Tables | Unsupported | list+menu shell / deferred |
| Window Splitter | Layout & Scrolling | splitter | settings shell |

**Correction (2026-08-02, found while building the tracker and game-inventory reproduction benches):**
Tabs, Listbox and Tooltip were all already implemented — Tabs and Listbox by the widget-extension
round this matrix's own maintainer ran just before these two shells, and Tooltip much earlier
(predating this document; `ctx.tooltip` has its own hover-delay/clamp/leave test suite). None of the
three landing updated this file, so the three rows above, and the corresponding three entries this
document's §9 used to list as unsupported, were stale until this pass. `examples/35_gui_gallery`'s own
`MISSING` array was a second, separate place the same kind of staleness hid — a later pass (see §18)
reconciled it against this section and dropped its numeric task-target column, but the array itself
remains a second place that must be updated in the same change as this document whenever a widget
lands or a gap closes; nothing technical ties the two together.

## 6. Current libs/gui API inventory

| Category | Concrete API |
|---|---|
| Basic | Context.buttonId, Context.label |
| Text | gui.selectableLabelId, Context.textInputId, Context.labelEllipsis / gui.ellipsizeText |
| Values | Context.sliderI32Id, Context.sliderF32Id, Context.checkboxId, Context.toggleId, Context.radioId |
| Color / Image | Context.colorSwatchId, Context.svSquareId, Context.hueBarId, Context.imageBox |
| Layout | gui.splitter, Context.beginScrollArea/endScrollArea, Context.beginFormRow/endFormRow |
| Selection | Context.tabId, Context.beginListboxRow/endListboxRow + gui.pollListNav |
| State | Context.beginDisabled/endDisabled/isDisabled |
| Popup / Menu | Context.popupMenu / popupMenuEx (PopupItem.checked, keep_open_on_select), gui.openPopupStacked/popupMenuStacked, gui.menuBar, gui.menuBarPopup, Context.tooltip |
| Step grid | gui.stepgrid.widgetRow |

Use only Id-bearing variants that actually exist in libs/gui, and avoid collisions within a section. Do not change libs/gui itself for this matrix work.

## 7. State rules

`normal` is the caller's owned initial value. `hover` and `active` are live states from the previous-frame rect cache and `Context.state.hot_id` / `active_id`. `focused` is TextInput focus. `disabled` is covered only where `PopupItem.enabled` / `Command.enabled` apply individually.

`empty` is an empty label / empty text. `min` / `max` are slider, picker, and layout endpoints. `none` is a "no value" display such as radio. A shared disabled property (`Context.beginDisabled`/`endDisabled`/`isDisabled`, see §10) and a keyboard focus-visible ring (see the focus-traversal ADR) both now exist; there is still no semantic role or ARIA-equivalent attribute in the current surface.

## 8. Current widget state matrix

| widget | normal | hover | active | focused | disabled | empty | min | max | none |
|---|---|---|---|---|---|---|---|---|---|
| button | ✓ | demo | demo | N/A | N/A | ✓ | N/A | N/A | N/A |
| label | ✓ | N/A | N/A | N/A | N/A | ✓ | N/A | N/A | N/A |
| selectableLabel | ✓ | N/A | drag | ✓ | N/A | ✓ | N/A | N/A | ✓ |
| textInputId | ✓ | demo | demo | ✓ | N/A | ✓ | N/A | N/A | ✓ |
| slider i32/f32 | ✓ | demo | demo | N/A | N/A | N/A | ✓ | ✓ | N/A |
| checkbox | ✓ | demo | demo | N/A | N/A | ✓ | N/A | N/A | N/A |
| toggle | ✓ | demo | demo | N/A | N/A | ✓ | N/A | N/A | N/A |
| radio | ✓ | demo | demo | N/A | N/A | ✓ | N/A | N/A | ✓ |
| colorSwatch | ✓ | demo | demo | N/A | N/A | N/A | N/A | N/A | ✓ |
| SV square / hue bar | ✓ | demo | demo | N/A | N/A | N/A | ✓ | ✓ | N/A |
| imageBox | ✓ | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A |
| splitter | ✓ | demo | demo | N/A | N/A | N/A | ✓ | ✓ | N/A |
| scrollArea | ✓ | demo | demo | N/A | N/A | N/A | ✓ | ✓ | N/A |
| popup / contextMenu | ✓ | ✓ | ✓ | N/A | ✓ item | N/A | N/A | N/A | ✓ |
| menuBar | ✓ | demo | demo | N/A | ✓ command | N/A | N/A | N/A | ✓ |
| stepgrid | ✓ | demo | demo | N/A | ✓ | ✓ | N/A | N/A | ✓ |

## 9. Unsupported-widget empty sections

The missing section originally showed 15 items. Tabs, Listbox and Tooltip have since gained real APIs
(`ctx.tabId`, `beginListboxRow`/`endListboxRow`/`gui.pollListNav`, `ctx.tooltip`; see §5's correction
note), leaving these 12: Accordion, Alert / Message Dialog, Breadcrumb, Carousel, Combobox, Dialog
(Modal), Disclosure, Meter, Spinbutton, Table, Tree View, Treegrid. Each item is only a rectangle, NOT
IMPLEMENTED, and a follow-up category (torture suite / settings shell / list+menu shell / deferred). No
widget implementation is included. `examples/35_gui_gallery`'s own placeholder count and `MISSING` array
have not been re-synced to this correction (see §5's note) — this section's count is the corrected one.

## 10. Cross-cutting gaps

### Sources, missing sections, and cross-cutting holes

- Sources stay in §2, APG 30 patterns in §3, ImGui sections in §4, and the crosswalk in §5.
- The 15 missing items and follow-up categories must match §9 and the gallery missing section.
- Gaps for disabled / focused / semantic role / common query API are recorded in this §10 and §7.

### Disabled

A shared disabled scope now exists: `Context.beginDisabled()` / `endDisabled()` / `isDisabled()`, nestable,
wired into `behaviorFromCache` (covers button / colorSwatch / iconButton / checkbox / toggle / radio /
beginCollapsible / tabId) plus `sliderCore` and `textInputId` directly. A disabled widget leaves the Tab
order, never hit-tests, and releases any focus/hover/active it held before becoming disabled; the four
representative widgets (button/checkbox/toggle/radio/slider/textInputId) also draw with
`Style.disabledColor`.

Two widgets used to remain outside this scope by construction, because each hand-assembles its own
hit-test instead of calling `behaviorFromCache`. Both now consult `ctx.isDisabled()` directly (via the
shared `Context.clearDisabledInteraction` helper `behaviorFromCache` itself uses), closing the gap without
adding a new widget:

- `gui.stepgrid.widgetRow` skips the per-cell hit-test and draws with `Style.disabledColor` while disabled.
  §16.1 (the tracker/session grid shell) is the evidence: the shell no longer needs the widget's own
  `editable` option to work around this, and now wraps the whole muted row (grid plus its volume/pan
  sliders) in one `beginDisabled`/`endDisabled` scope.
- `gui.beginListboxRow` skips the hit-test and registerFocusable call while disabled, and greys its
  selected-row background. Still not exercised by any reproduction bench (no shell disables an individual
  list row), so this remains a documentation-level fix rather than an example-pinned one.

### Focused / semantic

`Context.state.focused_id` and textInputId focus are observable, but there is no widget-wide API to declare ARIA role, name, description, or keyboard interaction policy. Landmark, toolbar, link, and tabs semantics are also unsupported; re-evaluate in the settings shell.

### Querying item status

There is no dedicated query API. The gallery observes representative widget hot / active / focused categories via `ButtonResult` and a custom gallery probe. The probe digest format is fixed as:

section=<name> index=<i> widgets=<n> missing=<n> schema=v0 hot=<name|none> active=<name|none> focused=<name|none>

## 11. Gallery sections and E2E snapshot

| index | section | widgets | missing | Main demos |
|---:|---|---:|---:|---|
| 0 | overview | 0 | 15 | Three axes, sources, overall counts |
| 1 | basic | 2 | 0 | button / label |
| 2 | text | 2 | 0 | textInputId / selectableLabelId |
| 3 | values | 4 | 0 | i32/f32 slider / checkbox / toggle / radio |
| 4 | color | 3 | 0 | swatch / SV+hue / image |
| 5 | layout | 2 | 0 | splitter / scrollArea |
| 6 | menus | 2 | 0 | popup/context / menuBar |
| 7 | stepgrid | 1 | 0 | 16 step row |
| 8 | missing | 15 | 15 | 15 placeholders |

`examples/35_gui_gallery/e2e.txt` runs `digest gallery` and path-omitted `snapshot fb` for each section. Do not add PNGs to the repository; visually inspect runtime artifacts under `KNGN_HARNESS_OUT`. Fixed window is 1024×640, initial section is overview, font is `gui.default_font`.

## 12. Update rules

1. When APG / ImGui source versions or fetch dates change, update the §3–§5 mapping first.
2. When libs/gui gains an API, update §6, §8, gallery sections, and the E2E probe in the same change.
3. When changing N/A to implemented, leave state evidence via input injection or a unit test.
4. Adding a shared disabled / semantic / query API closes a cross-cutting gap and must be recorded as such.
5. Abnormal / boundary coverage lives in the torture suite; shell, settings, and list screens live in the settings shell and list+menu shell examples.

## 13. Torture suite reference

The abnormal / boundary suite that pairs with the normal path (this matrix + `examples/35_gui_gallery`) is:

- README: `examples/37_gui_torture/README.md`
- Example: `examples/37_gui_torture` (probes: `state` / `layout` / `scroll`)
- Bench: `zig build bench-gui-frame` (full Context frame, 500/1000 rows)
- Leak: `zig build test-gui-leak` (PerIdStateStore cap assert: final=3072, max≤4096)

### Gaps found in the torture suite (summary)

Detail, file:line, and reproduction scripts live with the torture suite example.

1. Nested ScrollArea wheel does not prefer the inner area; outer/inner change together → **resolved**: wheel consumption is LIFO inner-first, with an edge-remainder propagating outward, in `endScrollArea` (see "Frame order and hit-test timing" in `libs/gui/README.md`, and the nested-wheel unit tests in `libs/gui/src/widgets.zig`)
2. PerIdStateStore had no trim/TTL/cap, so long-lived ID churn grew monotonically → **LRU cap introduced** (see "PerIdStateStore lifetime and LRU cap" in `libs/gui/README.md`)
3. TextBuffer / textInputId has no max-length API
4. Newline / CJK / emoji measure / coverage: default-font observation contract is spelled out in "Text measurement and drawing" in `libs/gui/README.md`
5. Small-screen outer overflow for long popup item text is not yet documented as a contract
6. Hit-test / clip / child rect behavior for zero-size / overflow containers is undefined
7. Rect-cache sync lag when layout changes during drag: current contract is spelled out in "Frame order and hit-test timing" in `libs/gui/README.md`
8. Auto-ID same-label collisions: current contract and `Id` variant usage rules are spelled out in "Text measurement and drawing" in `libs/gui/README.md`

## 14. Settings shell observations

Results from building a left nav + three forms (General / Editor / Audio, 36 controls total) with current APIs only in `examples/39_settings_shell`. libs/gui itself was not changed.

### 14.1 Evidence against existing Missing rows (do not duplicate rows)

| Item | Observation in the settings shell |
|---|---|
| Tabs | No dedicated API. Left-nav section switching uses `selectableLabelId` + an app-side section enum. |
| Accordion / Disclosure | No dedicated widget. Forms use a flat always-expanded list inside `ScrollArea`. |
| Combobox / dropdown / select | No dedicated widget. theme / indent / font / output / buffer use groups of `radioId`. |
| Meter | Unused and still unimplemented (Audio `show_meter` is a checkbox flag only). |
| Spinbutton | Numbers use `sliderI32Id` / `sliderF32Id` instead. |
| Tooltip | Form description uses fixed `labelEx` text. No dedicated hover tooltip API. |
| Dialog (Modal) | Not needed in this shell. Modal confirm UI was not exercised. |

### 14.2 New gaps observed in the settings shell

1. **`selectableLabelId` has no clicked result; nav activation needs focus-dependent app glue**  
   `claimFocus` runs on click but is not "section select" semantics. The app maps `focused_id` to a section enum. When focus does not apply, `hot_id` + `mouse_pressed` click glue is required (hack).
2. **No dedicated API for Tabs-equivalent selected section semantics**  
   Selected background is drawn by the app via an outer `beginBox` bg. `selectableLabel` selection background remains for text selection.
3. **No composable API for shared form row / label-for / field description**  
   Each control is a hand-stacked labeled widget plus helper `labelEx`. There is no field-to-description binding API.
4. **No shared disabled-state API for general widgets**  
   Cannot express disabling a setting (e.g. volume when audio is off). Only PopupItem/Command per-item enabled exists.
5. **No keyboard focus traversal / tab-order API for non-text widgets**  
   checkbox / toggle / radio / slider do not claim focus. For E2E `focused=` expectations the app must add `claimFocus` glue (hack).
6. **No shared focus-visible drawing-state API**  
   Cannot declare a focus ring for keyboard interaction across widgets.
7. **Explicit ID management is required for 3 forms / 36 controls**  
   Auto IDs are avoided; ID ranges are split per section. Probe / harness coordinate derivation depends on that same ID table.
8. **ScrollArea long-form hit-test works, but post-scroll rect re-fetch is caller duty**  
   Re-take the layout probe after scroll and recompute coordinates (the harness has no coordinate variables).

### 14.3 Relation to torture-suite records

- Nested ScrollArea wheel, PerIdStateStore caps, TextBuffer max length, and similar items are not re-filed from this shell.
- The settings screen uses one independent ScrollArea per section and did not include a nested-wheel reproduction path.

## 15. List+menu shell observations

Evidence example: `examples/40_list_menu` (probes: `state` / `layout`; E2E: `e2e.sh` 7 scenarios; ports 9230–9239).
Bench: `zig build bench-gui-list-menu` (500-row full Context frame, ReleaseFast, 1024×768).
libs/gui itself was not changed. Gaps are recorded as example-side custom/hack or Missing.

### 15.1 Observations (complete Missing list)

1. **500-row full Context frame time** — Every frame builds all rows with `selectableLabelId`. Measure avg/min/p95 with `bench-gui-list-menu` (compare against the 500-row values from existing `bench-gui-frame`). No virtualization.
2. **No dedicated Listbox semantics** — `selectableLabelId` is for text selection, not a single-line listbox selection model. Row select / highlight is app state (`selected_row` / `active_row`).
3. **No list keyboard navigation API** — Up/down active-row movement is a custom app handler for `key_down UP/DOWN`. List nav is suppressed while a popup is open.
4. **No checkbox-backed persistent multi-select popup** — `PopupItem` has no checked state. Filters rebuild `[on]`/`[off]` labels and, after item selection closes the popup, the app reopens to simulate multi-select (`filter_reopen_count`).
5. **At most one popup at a time** — `PopupState` holds only one. menuBar and context/filter cannot be held together. E2E scenario 7: right-clicking a row while the File menu is open still yields `popup_count=1` (observed: after right-click the menu keeps the popup / context does not fully replace it, or the menu reclaims on the next frame). Overlaying menu and context is impossible.
6. **No standard ellipsis API** — Long filenames are truncated by the app with `font.measure` then `...`. No custom rasterizer / direct `DrawList` use.
7. **No virtualization API** — All 500 rows are built and laid out every frame. Scrolling is `beginScrollArea` only.
8. **No multi-row select / drag select** — This screen is single-select only. The probe explicitly reports `multi_select=0` / `drag_select=0`.
9. **No dedicated Toolbar API** — Back / New / Refresh are a `buttonId` row.
10. **No Table / column / tree view** — The list is hand-built from row box + kind label + selectableLabel + detail. No column layout or tree.

### 15.2 custom / hack counts (example side)

| Kind | Count | Detail |
|---|---:|---|
| row hit-test + single-select glue | 1 | Left/right click selects a row via `getNodeCachedRect` |
| filter popup reopen | 1 | After selection, `filter_open_request` reopens next frame |
| keyboard up/down nav | 1 | `UP`/`DOWN` → `navigateRows` |
| ellipsis string build | 1 | `ellipsize` + frame arena |
| menu/context switch control | 1 | Apply context-open request after menuBarPopup; do not forward right-press to gui |
| custom draw | 0 | No `ctx.custom` / direct DrawList / custom rasterizer |

### 15.3 Size checks

Launch 640×360 / 1024×768 / 1440×900 as separate processes and visually inspect path-omitted `snapshot fb`. Adjust padding/gap by width; do not use fixed absolute placement.

## 16. Tracker / Session View grid shell observations

Evidence example: `examples/42_tracker_grid` (probes: `state` / `layout`; E2E: `e2e.sh`, 5 scenarios; ports
9240–9249). A music tracker / Ableton Session View style grid: pattern tabs across the top, a track list at
the left, an 8-track × 16-step grid in the middle (the existing `gui.stepgrid.widgetRow`, not a new widget),
and a per-track detail panel on the right. libs/gui itself was not changed by this shell (`beginDisabled`
already existed from the disabled-scope task).

This shell exercises every widget this document's disabled-scope and popup-extension entries above cover,
all in one screen: `ctx.tabId` (pattern
switch, selection follows focus), `beginListboxRow`/`endListboxRow`/`gui.pollListNav` (track list, roving
tab stop), `ctx.labelEllipsis` (track names) and `ctx.beginFormRow`/`endFormRow` (detail-panel rows, one
using only `description` with no `label`), `ctx.beginDisabled`/`endDisabled` (a muted track's own
Volume/Pan controls), and `ctx.popupMenuEx` with `PopupItem.checked` plus `keep_open_on_select` (the
right-click track context menu: Mute / Solo / Clear Pattern, checked marks reflecting current state,
staying open across toggles). It does not exercise `openPopupStacked`/`popupMenuStacked` — only one popup
is ever open here, so the list+menu shell (§15) remains the evidence for simultaneous popups.

### 16.1 Resolved: stepgrid now consults the disabled scope

See §10 "Disabled" for the full writeup. `gui.stepgrid.widgetRow` now checks `ctx.isDisabled()` the same way
`behaviorFromCache`-backed widgets do, so wrapping a step-grid row in `beginDisabled`/`endDisabled` rejects
its clicks and greys its cells. The shell no longer needs the widget's own `editable` option as a
workaround — the muted row (grid plus its volume/pan sliders) shares one `beginDisabled`/`endDisabled`
scope.

### 16.2 custom / hack counts (example side)

| Kind | Count | Detail |
|---|---:|---|
| track row hit-test + right-click context-menu glue | 1 | `hitTestTrack` + `getNodeCachedRect`; the right press is not forwarded to gui so it cannot dismiss the popup it just opened (same shape as §15.2's row/context glue) |
| keyboard up/down nav | 1 | `gui.pollListNav` result applied by hand: move `selected_track`, `claimFocus` onto the new row |
| custom draw | 0 | No `ctx.custom` / direct DrawList / custom rasterizer beyond `stepgrid`'s own library-side draw |

### 16.3 Scorecard

| Axis | Score | Note |
|---|---:|---|
| Structure | 5 | 640×360 / 1024×768 / 1440×900 all lay out without overflow, once the detail column and slider `track_w` were sized against the widest form-row content at each width tier (§16.4) |
| Interaction | 5 | All 5 scenarios harness-automated: pattern tab switch, track select (mouse) + Up/Down (keyboard), step-grid toggle, mute → grid + Volume drag both rejected (disabled) → context-menu checked toggle → unmute → both now respond again |
| Information | 5 | Selection / mute / solo / checked / disabled are all visualized, the step grid included (§16.1) |
| Ergonomics | 4 | 2 hacks (§16.2), 0 custom draw |

Missing (priority): 1) no dedicated Grid/Table APG widget — the step grid is still `stepgrid` plus a
hand-wrapped row box, not a general grid/table widget 2) `openPopupStacked`/`popupMenuStacked` not
exercised here (single popup only; see §15 for that evidence).

### 16.4 Size checks

Launch 640×360 / 1024×768 / 1440×900 as separate processes and visually inspect path-omitted `snapshot fb`.
The first pass at this shell overflowed the detail panel: `sliderF32Id`'s `[label][track][value]` row and
the two description labels both exceeded the panel's `.fixed` column width, and a `.fixed`-width box does
not clip its own over-wide children, so the overflow bled all the way to the window's right edge in the
harness screenshot rather than being merely cramped. Fixed by sizing the detail column and the slider
`track_w` against the widest row's content at each width tier, and shortening the two description strings
(a live example of the fit×grow layout trap: a `.fixed`-width box sizes itself from its own opts alone and
never shrinks its children to fit, so an over-wide child inside it silently overflows rather than clipping
or wrapping).

## 17. Game inventory shell observations

Evidence example: `examples/43_game_inventory` (probes: `state` / `layout`; E2E: `e2e.sh`, 8 scenarios;
ports 9250–9259). A 6×4 item grid with a 2D cursor, drag-and-drop, a hover tooltip, a rotary "Min Rarity"
filter knob, and a right-click Lock/Discard context menu. libs/gui itself was not changed by this shell.

This shell was asked to reproduce four capabilities (drag-and-drop, tooltip, gamepad navigation, a knob).
Only two of the four are genuine gaps:

- **Drag and drop**: no dedicated API. Pointer glue in `main.zig` (press-on-a-filled-slot starts a drag,
  release hit-tests the destination) plus a translucent ghost square drawn directly onto `ctx.draw_list`
  after `endFrame` (the same "overlay after the layout tree" placement `popup.zig` uses for popups and
  `ctx.tooltip`) are both example-side. **Requested here; not filed as a new task** per this family's
  standing rule — recorded as a hack (pointer glue) plus a custom draw (the ghost) in §17.2.
- **Knob**: no rotary/dial widget. `ui.zig`'s "Min Rarity" control is a fixed-size base plate plus a small
  indicator dot placed by angle (`sin`/`cos` against the current value, not a per-pixel circle rasterizer)
  plus hand-rolled vertical-drag interaction in `main.zig`. **Requested here; not filed as a new task** —
  recorded as a hack plus a custom draw in §17.2.

The other two turned out not to be gaps at all:

- **Tooltip**: `ctx.tooltip(text)` already exists (§5/§9's correction note traces this to a widget-history
  commit long predating this matrix; `jj file annotate` on `libs/gui/src/context.zig` finds it, not a
  reference kept in this document). This shell calls it directly — `ctx.noteLastInteractive` plus `ctx.tooltip`, the
  same pairing `iconButtonId`'s own hover path uses internally, added by hand only because a grid slot is a
  plain `beginBox` rather than a widget that already calls `noteLastInteractive` for itself. Confirmed
  visually: hovering a filled, locked slot for the library's own 500ms delay raises a correctly positioned,
  clamped overlay reading `<name> (rarity N) [locked]`. **Not a hack, not a custom draw** — ordinary use of
  an existing API.
- **Gamepad navigation**: `platform` + `gamepad` (`src/gamepad.zig`, `justPressed` edge detection) already
  exist and are exactly what `examples/22_gamepad` already uses directly (this example does not import
  `kit` either). What is genuinely hand-rolled is the *2D grid cursor* the dpad drives — `gui.pollListNav`
  is one-dimensional (a listbox), so moving a cursor across a 6×4 grid by row/col has no library
  counterpart. Recorded as one hack in §17.2 (not two): the same `moveCursor`/`activateCursor` pair serves
  keyboard (arrows + Enter/Space) and the gamepad (dpad + A) alike, so there is exactly one 2D-nav gap, not
  a separate one per input device. `platform`/`gamepad` themselves are not counted as a gap.

### 17.1 New cross-cutting finding: two capability-matrix entries were stale, not missing

Tooltip's status here matches §5/§9's correction: this document said "Unsupported" for a widget that has
had a full implementation and test suite since well before this matrix existed. This shell is the second
and third data point
(after the tracker shell's stepgrid finding) that a widget landing does not reliably propagate to this
document — worth a standing habit, not just a one-time fix: **before recording a widget as "requested,
unimplemented" in this family, grep libs/gui/src for the capability first.**

### 17.2 custom / hack counts (example side)

| Kind | Count | Detail |
|---|---:|---|
| drag-and-drop pointer glue | 1 | press-on-filled-slot starts drag / release hit-tests destination / locked slots and locked destinations reject it (`ui.beginDrag`/`endDrag`) |
| 2D grid cursor nav | 1 | `moveCursor`/`activateCursor`, shared by keyboard arrows+Enter/Space and gamepad dpad+A (one gap, two input devices) |
| knob interaction | 1 | vertical mouse-drag → value, hand-rolled hit-test against a reserved `beginBox` |
| drag ghost (custom draw) | 1 | translucent `rectFilled` at the cursor, direct `ctx.draw_list` use after `endFrame` |
| knob face + indicator (custom draw) | 1 | base-plate `rectFilled`/`rectOutline` plus one angle-placed indicator dot, direct `ctx.draw_list` use |
| rarity-dim overlay (custom draw) | 1 | a translucent `rectFilled` over each slot below the knob's threshold, direct `ctx.draw_list` use |

### 17.3 Scorecard

| Axis | Score | Note |
|---|---:|---|
| Structure | 5 | 640×360 / 1024×768 / 1440×900 all lay out without overflow (grid + detail panel sizes are responsive to `screen_w`, following §16.4's lesson from the start this time) |
| Interaction | 5 | All 8 scenarios harness-automated: initial state, hover→tooltip, drag-and-drop onto an empty slot (plus the reverse), a locked slot rejecting a drag, keyboard nav, gamepad dpad nav, gamepad A pickup/drop, the rarity knob drag, and the Lock/Discard context menu |
| Information | 4 | Cursor / locked / dragging / rarity-dim / checked are all visualized; no visual distinction for "why did this drag get rejected" (a locked source or a locked destination look identical to the player: nothing moves) |
| Ergonomics | 3 | 3 hacks + 3 custom draws (§17.2) — the highest custom-draw count of the family so far, expected: this shell's four requested capabilities are two genuine gaps (dnd, knob) each needing both an interaction hack and a visual, plus one gap (2D nav) that is interaction-only, plus one capability (tooltip) that needed no hack at all |

Missing (priority): 1) drag-and-drop (§17, "requested here") 2) knob / rotary control (§17, "requested
here") 3) no dedicated 2D grid/cursor-nav widget (distinct from `Table`/`Grid`'s existing missing entries,
which are about tabular *display*, not keyboard/gamepad *navigation* over one).

### 17.4 Size checks

Launch 640×360 / 1024×768 / 1440×900 as separate processes and visually inspect path-omitted `snapshot fb`.
Grid `slot` size, detail-panel width and padding all key off `screen_w` from the first draft (learned from
§16.4), and no overflow was observed at any of the three sizes.

## 18. Gallery MISSING-array reconciliation

§5's 2026-08-02 correction flagged `examples/35_gui_gallery`'s own `MISSING` array as a second place the
same "a widget landed, this document did not get updated" staleness hides. This section closes that gap
for the set of widgets current at the time of this pass, and records the rule that keeps it closed.

**What changed:** `MISSING` dropped `Listbox` and `Tabs` (both implemented; §5/§9 already reflected this)
and gained `Accordion` (§9's 12-item list already carried it; the gallery array never had — an
independent staleness in the other direction, not introduced by this pass). Net count: 13 → 12, matching
§9 exactly. Each entry's second field changed from a numeric task-target string (e.g. `"121.3"`) to the
follow-up category name from §5's own crosswalk (`"settings shell"`, `"deferred"`, and so on) — a
task-tracker id has no meaning to a reader of this public repository, per the comment and documentation
policy's rule 3 (`kngn/AGENT.md`), and unlike a source comment this field is drawn straight onto screen
as a user-visible string, so it is not exempt from that rule.

**Why this keeps drifting:** the array duplicates §9's list by hand, in a different file, in a different
form (Zig struct literals versus a comma-separated sentence). Nothing catches the two falling out of sync
except a human noticing. Two counter-measures, one mechanical and one procedural:

- Mechanical (done here): `examples/35_gui_gallery/main.zig`'s `SECTIONS` table used to hardcode the
  missing-widget count twice more (the `overview` and `missing` entries' `.missing`/`.widgets` fields),
  a *third* place the same number could drift from `MISSING.len`. Both now read `MISSING.len` directly,
  so within this one file the count has a single source; the E2E script's `expect gallery missing=N` /
  `widgets=N` lines still hardcode the number (the harness digest protocol has no comptime access to the
  array) and had to be updated by hand alongside this change.
- Procedural (not mechanical — no lint enforces it): §12's update rules already say "when libs/gui gains
  an API, update §6, §8, gallery sections, and the E2E probe in the same change" for the *implemented*
  side. The matching rule for the *unimplemented* side is: when a widget's status changes in §5/§9 (a gap
  opens or closes), update `examples/35_gui_gallery`'s `MISSING` array and its two E2E `missing=`/`widgets=`
  assertions in the same change. This document and the gallery's array are not the same source, so keeping
  them in sync is a discipline, not a guarantee — as this section itself is evidence of.
