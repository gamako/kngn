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
| video-proto libs/gui | libs/gui/src/widgets.zig / popup.zig / menu.zig / stepgrid.zig | workspace tree, 2026-07-17 |

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

### AC#1: Sources, missing sections, cross-cutting holes

- Sources stay in §2, APG 30 patterns in §3, ImGui sections in §4, and the crosswalk in §5.
- The 15 missing items and follow-up categories must match §9 and the gallery missing section.
- Gaps for disabled / focused / semantic role / common query API are recorded in this §10 and §7.

### Disabled

There is no shared disabled property. The gallery shows `PopupItem.enabled` and `Command.enabled` individually; general widget disabled is N/A. Only stepgrid `editable=false` is a partial case.

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

`examples/35_gui_gallery/e2e.txt` runs `digest gallery` and path-omitted `snapshot fb` for each section. Do not add PNGs to the repository; visually inspect runtime artifacts under `VP_HARNESS_OUT`. Fixed window is 1024×640, initial section is overview, font is `gui.default_font`.

## 12. Update rules

1. When APG / ImGui source versions or fetch dates change, update the §3–§5 mapping first.
2. When libs/gui gains an API, update §6, §8, gallery sections, and the E2E probe in the same change.
3. When changing N/A to implemented, leave state evidence via input injection or a unit test.
4. Adding a shared disabled / semantic / query API closes a cross-cutting gap and must be recorded as such.
5. Abnormal / boundary coverage lives in the torture suite; shell, settings, and list screens live in the settings shell and list+menu shell examples.

## 13. Torture suite reference

The abnormal / boundary suite that pairs with the normal path (this matrix + `examples/35_gui_gallery`) is:

- Plan: `docs/plans/PLAN_gui_torture.md`
- Example: `examples/37_gui_torture` (probes: `state` / `layout` / `scroll`)
- Bench: `zig build bench-gui-frame` (full Context frame, 500/1000 rows)
- Leak: `zig build test-gui-leak` (PerIdStateStore cap assert: final=3072, max≤4096)

### Gaps found in the torture suite (summary)

Detail, file:line, and reproduction scripts live with the torture suite plan and example.

1. Nested ScrollArea wheel does not prefer the inner area; outer/inner change together
2. PerIdStateStore had no trim/TTL/cap, so long-lived ID churn grew monotonically → **LRU cap introduced** (see §18)
3. TextBuffer / textInputId has no max-length API
4. Newline / CJK / emoji measure / coverage: default-font observation contract is spelled out in §17
5. Small-screen outer overflow for long popup item text is not yet documented as a contract
6. Hit-test / clip / child rect behavior for zero-size / overflow containers is undefined
7. Rect-cache sync lag when layout changes during drag: current contract is spelled out in §16
8. Auto-ID same-label collisions: current contract and `Id` variant usage rules are spelled out in §17

## AC#5 / AC#6 self-check

- AC#5: §2 records APG URL, living document, no version label, 30 patterns, fetch date; ImGui URL, v1.92.6, fetch date.
- AC#6: §7 and §10 record missing disabled API, individual PopupItem.enabled / Command.enabled handling, stepgrid editable, missing focus and semantic role, and missing dedicated query API.

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

## 16. Layout and input timing contract

> **Observation as of 2026-07-18**: The following is the contract of the current libs/gui implementation.
> If concurrent work changes clip / hit-test boundaries, read that section together with this one.

### 16.1 Frame order

| Stage | Work | Evidence |
|---|---|---|
| `beginFrame` | arena reset; input/id_stack/state init; draw_list reset; layout root created (not yet measured/placed) | `libs/gui/src/context.zig:220-243` |
| widget calls | synchronous hit-test against previous-frame `rect_cache`; build this frame's layout tree | `libs/gui/src/widgets.zig:203-206` |
| `endFrame` | `layout.measure` → `layout.place` → `rect_cache.clearRetainingCapacity` → `updateRectCache` → `emitNode` → `frame_active=false` | `libs/gui/src/context.zig:245-260` |

`endFrame` does not hit-test. Focus clear and active stuck prevention are only the state updates at the end of `endFrame` (`context.zig:261-270`).

### 16.2 When the rect cache is visible

- `updateRectCache` runs only after measure/place in `endFrame` (`context.zig:256-257`).
- Registration covers only `beginBox` nodes with `cfg.id != 0`. Stores `{rect, clip, measured_w, measured_h}` (`context.zig:420-429`).
- `getNodeRect` / `getNodeCachedRect` / `getNodeMeasured` return previous-frame settled values. They are not updated right after `beginFrame` either (`context.zig:377-404`).
- First frame, unknown IDs, and auto-numbered nodes (`beginBox` with `cfg.id==0`) return null.
- Duplicate explicit IDs in the same frame are a Debug assert contract violation (`context.zig:424-425`).

### 16.3 Layout changes during drag

Drags that change layout show a one-frame lag (current contract; not adopted as a fix target):

```text
Frame N:
  read previous-frame rect
  → buttonBehavior decides active / held from previous-frame rect
  → layout changes while widgets are built
  → endFrame stores new rect in cache and draws the new layout

Frame N+1:
  hit-test against the new rect cache
```

Frame N draws the new layout and hit-tests the old layout. Hard to observe under ordinary static layout, slider drag, or scroll.

### 16.4 Adopted approach and rejected alternatives

**Adopted**: Keep synchronous hit-test against the previous-frame rect cache as the current contract.

**Rejected** (same-frame rect reflection):

| Option | Why rejected |
|---|---|
| A: Finalize layout before widget construction | Sibling measure and parent sizing mean final rects cannot be known before all widgets are built |
| B: Re-run hit-test after endFrame | Collides with synchronous return APIs (`ButtonResult` / `changed`). Needs event retention, re-evaluation, and ordering rules |
| C: Predicted rect per widget | Not applicable to general widgets with flex/scroll/popup/dynamic label width. Would duplicate layout and hit-test paths |

Real harm is limited to cases such as parent layout change during drag, display switching, and release position mismatch between old and new rects.

### 16.5 Torture-suite E2E evidence

`examples/37_gui_torture/e2e_input_state.txt` pins the observed values for the current contract.

- During F1 layout shift, `active=slider`, `dragging=1`, and `layout_generation=1` are held (`e2e_input_state.txt:17-25`)
- After mouse up, `active_is_zero=1` (`e2e_input_state.txt:27-30`)

### 16.6 Boundary with the wheel contract

Scroll wheel input is a scroll-specific delivery contract: same-frame reflection in `endScrollArea` (inner-first consumption; scroll offset applied to the viewport node). See the `ScrollState` comment at `context.zig:64-66`.

Treat that separately from any general contract that would reflect arbitrary layout changes into same-frame hit-test. Wheel behavior and rect-cache lag are not in conflict.

## 17. Text measure/draw contract

> **Observation as of 2026-07-18**: The following observation contract assumes `gui.default_font` (spleen 8×16 bitmap).
> Glyph coverage and advance for a different `Font` implementation follow that implementation's contract.

### 17.1 Scope and Font dependence

- Targets: `Font.measure` / `Font.drawTo` / `TextLayout` / label-family widgets / `textInputId`
- Default font: ASCII `32..127` 8×16 bitmap (`libs/gui/src/font.zig:13-19`, `font.zig:208-215`)
- No font chain / emoji font / glyph fallback in `libs/gui`

### 17.2 Newlines

| Path | Behavior | Evidence |
|---|---|---|
| label / selectableLabel etc. (display) | `\n` is not stripped. Measured as 1 codepoint at 8px. Draw skips (out of glyph range); advance still moves 8px (no line advance) | `font.zig:18-19`, `font.zig:81-85` |
| TextInput (edit) | Typed char / paste / selection replacement do not insert newlines or ASCII controls | `widgets.zig:500`, `widgets.zig:619-621`, `text_edit.zig:377`, `text_edit.zig:418` |

Default font is a single-line draw contract (no height growth from newlines).

### 17.3 CJK

Valid UTF-8 CJK is handled as one codepoint.

| Item | default font | Evidence |
|---|---|---|
| measure | 8px per character | `font.zig:57-61` |
| TextLayout | byte offset / prefix_width for one codepoint | `text_edit.zig:54-79` |
| draw | no glyph (skipped) | `font.zig:81-85` |
| advance | 8px even without a glyph | `font.zig:64-71` |
| fallback | none | — |

`wordRange` treats a contiguous non-ASCII run as one word. Grapheme clusters / language-specific segmentation are unimplemented (`text_edit.zig:112-128`).

### 17.4 emoji

Emoji that is valid UTF-8 is also per codepoint. Under the default font, like CJK: no glyph drawn, advance 8px.

ZWJ sequences / variation selectors / skin tones are not handled as graphemes; each constituent codepoint is processed. Visual one-emoji units are not guaranteed to match logical width.

### 17.5 Default font coverage and fallback

- Coverage: set bits for ASCII `32..127` bitmaps (`font.zig:101-120`)
- Non-ASCII: not replaced with `.notdef` or a substitute glyph; draw is skipped (`font.zig:81-85`)
- Fallback font / font chain: none

### 17.6 measure / draw advance / ink width

Default font `measure`:

- valid UTF-8: codepoint count × 8
- invalid UTF-8: byte count × 8
- missing glyph / newline / CJK / emoji: all advance 8px

`drawTo` also advances 8px per codepoint, so logical measure and draw-cursor width match. Because glyphs may be skipped, **logical width is not ink pixel width**.

Layout text leaf: width = `Font.measure`, height = `Font.metrics().line_height` (`libs/gui/src/layout.zig:166-169`).

### 17.7 TextLayout / caret / selection / hit-test

`buildTextLayout` builds per-codepoint UTF-8 byte offsets, logical advance, and cumulative `prefix_widths` (`text_edit.zig:54-79`).

- `selectableLabel`: width = `prefix_widths[count]`, height = line_height (`widgets.zig:294-298`)
- `textInputId`: selection / caret / scroll / hit-test use `prefix_widths` (`widgets.zig:351-378`)
- `.fit` width = `Font.measure` + padding (`widgets.zig:596-600`)
- ink height = `ascent + descent` (not line_height; `widgets.zig:531-533`)

`hitTest` returns a **codepoint index** (not a byte offset), using advance midpoints as boundaries (`text_edit.zig:91-100`).

### 17.8 Auto ID and same-label collisions

Label-family auto IDs are `IdStack.make(label)` = current seed + label hash (`libs/gui/src/id.zig:83-85`).

Covered APIs: `button` / `buttonEx` / `selectableLabel` / `sliderI32` / `sliderF32` / `svSquare` / `hueBar` / `checkbox` / `toggle` / `radio` (each `id_stack.make` call is in `widgets.zig`). `colorSwatch` uses `makeInt(color value)`. `textInputId` has no auto-ID variant.

Same label in the same `IdStack` scope → same ID → Debug assert in `endFrame`'s `updateRectCache` (`context.zig:424-425`).

Negative E2E: `examples/37_gui_torture/negative_auto_id.sh` (expects non-zero exit plus assert/panic traces).

**Usage rule**: For adjacent same labels, use explicit-ID variants such as `buttonId` / `selectableLabelId`, or split scope with `id_stack.push(i)`.

Last-wins overwrite in Release builds is not a contracted allowed behavior; the premise is "do not use duplicate IDs".

### 17.9 Usage rules and non-goals

| Item | Status |
|---|---|
| Multi-line layout / wrapping | Unsupported (single-line contract) |
| Grapheme cluster handling | Unsupported (codepoint unit) |
| Glyph fallback / emoji font | Not added |
| Newline line advance (label display) | Unsupported (advance only) |
| Auto-ID same label | Detected by Debug assert (at `endFrame` cache update) |

Observation E2E: `examples/37_gui_torture/e2e_text.txt` (ASCII/CJK/emoji/newline labels, 500-codepoint measure, TextInput caret/selection at codepoint boundaries).

## 18. PerIdStateStore lifetime / LRU cap

`PerIdStateStore` (`libs/gui/src/state.zig`) holds per-ID selection / caret / double-click / TextInput horizontal scroll.

| Item | Contract |
|---|---|
| Method | frame-generation touch + ID-linked LRU |
| Default caps | `max_entries=4096`, `trim_to=3072` |
| touch | `getOrPut` (`Context.perIdState`) records the current frame and moves to LRU tail. `get` does not touch |
| trim trigger | Only at the frame boundary at the end of `Context.endFrame` (when `count > max_entries`) |
| Protected | current-frame touch / `active_id` / `focused_id` / `hot_id` / `next_hot_id` |
| Hidden | When over cap, oldest LRU entries may be discarded. On re-show, `PerIdState` returns to defaults |
| Caller-owned | `TextBuffer` and ScrollArea `*Vec2f` live outside the store (unaffected by trim) |

| widget | store state | Behavior after trim |
|---|---|---|
| `selectableLabelId` | selection / dragging / double-click | Initial selection on recreate |
| `textInputId` | selection / caret / `scroll_x` / blink | TextBuffer kept; edit state reset |
| `beginScrollArea` | caller-owned `Vec2f` | Unaffected by store trim |

Verification entry points:

- unit: `zig build test-gui` (LRU / protect / re-init tests in `state.zig` / `context.zig`)
- leak: `zig build test-gui-leak` (even with 30,000 unique IDs: final=3072, max_observed≤4096)
- E2E: `examples/39_settings_shell/e2e.sh` scenario 5 (`editor_scroll_y` kept by the app while another section is shown; rect_cache miss clamp right after re-show is ScrollArea contract)
