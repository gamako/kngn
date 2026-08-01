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
| Listbox | List boxes | Unsupported | list+menu shell |
| Menu and Menubar | Menus | menuBar / menuBarPopup / popup | list+menu shell |
| Meter | Plotting / Range | Unsupported | settings shell |
| Radio Group | Selectables | radio; exclusive state owned by the caller | settings shell / list+menu shell |
| Slider / Spinbutton | Drag/Slider widgets | sliderI32 / sliderF32; Spinbutton unsupported | settings shell |
| Slider (Multi-Thumb) | Range widgets | Unsupported | deferred |
| Switch | Basic | toggle | settings shell |
| Table | Tables | Column table unsupported | list+menu shell |
| Tabs | Tabs | Unsupported | settings shell |
| Toolbar | Basic / Layout | row + button; no dedicated API | settings shell / list+menu shell |
| Tooltip | — | Unsupported | settings shell / deferred |
| Tree View / Treegrid | Trees / Tables | Unsupported | list+menu shell / deferred |
| Window Splitter | Layout & Scrolling | splitter | settings shell |

## 6. Current libs/gui API inventory

| Category | Concrete API |
|---|---|
| Basic | Context.buttonId, Context.label |
| Text | gui.selectableLabelId, Context.textInputId |
| Values | Context.sliderI32Id, Context.sliderF32Id, Context.checkboxId, Context.toggleId, Context.radioId |
| Color / Image | Context.colorSwatchId, Context.svSquareId, Context.hueBarId, Context.imageBox |
| Layout | gui.splitter, Context.beginScrollArea/endScrollArea |
| Popup / Menu | Context.popupMenu, gui.menuBar, gui.menuBarPopup |
| Step grid | gui.stepgrid.widgetRow |

Use only Id-bearing variants that actually exist in libs/gui, and avoid collisions within a section. Do not change libs/gui itself for this matrix work.

## 7. State rules

`normal` is the caller's owned initial value. `hover` and `active` are live states from the previous-frame rect cache and `Context.state.hot_id` / `active_id`. `focused` is TextInput focus. `disabled` is covered only where `PopupItem.enabled` / `Command.enabled` apply individually.

`empty` is an empty label / empty text. `min` / `max` are slider, picker, and layout endpoints. `none` is a "no value" display such as radio. There is no shared disabled property, semantic role, ARIA attribute, or dedicated focus-visible API in the current surface.

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
| stepgrid | ✓ | demo | demo | N/A | partial (editable=false) | ✓ | N/A | N/A | ✓ |

## 9. Unsupported-widget empty sections

The missing section shows these 15 items: Accordion, Alert / Message Dialog, Breadcrumb, Carousel, Combobox, Dialog (Modal), Disclosure, Listbox, Meter, Spinbutton, Table, Tabs, Tooltip, Tree View, Treegrid. Each item is only a rectangle, NOT IMPLEMENTED, and a follow-up category (torture suite / settings shell / list+menu shell / deferred). No widget implementation is included.

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

Two widgets remain outside this scope by construction, because each hand-assembles its own hit-test instead
of calling `behaviorFromCache`, and neither consults `ctx.isDisabled()`:

- `gui.stepgrid.widgetRow` (calls `buttonBehavior` directly). §16.1 (the tracker/session grid shell) hits
  this directly: wrapping a `stepgrid.widgetRow` call in `beginDisabled`/`endDisabled` has no effect, so the
  example substitutes the widget's own `editable=false` option, which suppresses clicks but draws no
  grayed-out look.
- `gui.beginListboxRow` (calls `buttonBehavior` directly, by its own doc comment, to keep the roving-tab-stop
  rule from being defeated by `behaviorFromCache`'s unconditional `registerFocusable`). Not exercised by any
  reproduction bench so far (no shell has disabled an individual list row), so this is a documentation-level
  finding rather than an example-pinned one.

Closing either gap means changing that widget's own hit-test path to check `isDisabled()`, not adding a new
widget.

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

### 16.1 New cross-cutting gap: stepgrid does not consult the disabled scope

See §10 "Disabled" for the full writeup. In short: `gui.stepgrid.widgetRow` hand-assembles its own hit-test
(`buttonBehavior`, not `behaviorFromCache`) and never checks `ctx.isDisabled()`, so wrapping a step-grid row
in `beginDisabled`/`endDisabled` changes nothing about it. The shell works around this with the widget's own
`editable` option (`editable = !track.muted`), which suppresses the click but draws no greyed-out look —
counted as a hack below, not as a widget the shell chose to skip.

### 16.2 custom / hack counts (example side)

| Kind | Count | Detail |
|---|---:|---|
| track row hit-test + right-click context-menu glue | 1 | `hitTestTrack` + `getNodeCachedRect`; the right press is not forwarded to gui so it cannot dismiss the popup it just opened (same shape as §15.2's row/context glue) |
| keyboard up/down nav | 1 | `gui.pollListNav` result applied by hand: move `selected_track`, `claimFocus` onto the new row |
| stepgrid disabled non-compliance workaround | 1 | `editable = !track.muted` substitutes for a real disabled look (§16.1) |
| custom draw | 0 | No `ctx.custom` / direct DrawList / custom rasterizer beyond `stepgrid`'s own library-side draw |

### 16.3 Scorecard

| Axis | Score | Note |
|---|---:|---|
| Structure | 5 | 640×360 / 1024×768 / 1440×900 all lay out without overflow, once the detail column and slider `track_w` were sized against the widest form-row content at each width tier (§16.4) |
| Interaction | 5 | All 5 scenarios harness-automated: pattern tab switch, track select (mouse) + Up/Down (keyboard), step-grid toggle, mute → Volume drag rejected (disabled) → context-menu checked toggle → unmute → the same drag now changes Volume |
| Information | 4 | Selection / mute / solo / checked / disabled are all visualized; the one gap is the step grid itself not visually reflecting "disabled" (§16.1) |
| Ergonomics | 3 | 3 hacks (§16.2), 0 custom draw |

Missing (priority): 1) stepgrid disabled non-compliance (§16.1, also §10) 2) no dedicated Grid/Table APG
widget — the step grid is still `stepgrid` plus a hand-wrapped row box, not a general grid/table widget
3) `openPopupStacked`/`popupMenuStacked` not exercised here (single popup only; see §15 for that evidence).

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
