# PLAN: GUI layout torture suite

## Purpose

Where `examples/35_gui_gallery` is the happy-path catalogue, this suite regression-tests
`libs/gui` edge and failure cases (nesting, zero-size, overflow, leftover state, ID
independence, volume) through the harness.

**`libs/gui` itself is not modified** (observe public API / pub state only).

## Hot-path declaration

- `examples/37_gui_torture/main.zig`: widget construction is per-frame O(N). No full-framebuffer
  loops or RT paths are added.
- `bench/gui_frame.zig`: bench runs only (warmup 100 × measure 1000).
- `tests/gui_leak.zig`: 300-frame measurement only. Does not affect the standing path.

## Layout

| Path | Role |
|---|---|
| `examples/37_gui_torture/main.zig` | Case switching + custom probes `state` / `layout` / `scroll` |
| `examples/37_gui_torture/e2e_*.txt` | Headless replay (ordinary cases) |
| `examples/37_gui_torture/negative_auto_id.{txt,sh}` | Debug-assert negative case (expect non-zero exit) |
| `bench/gui_frame.zig` | Full Context frame bench (`bench-gui-frame`) |
| `tests/gui_leak.zig` | PerIdStateStore leak measurement (`test-gui-leak`) |

## Case selection

- env: `VP_GUI_TORTURE_CASE=layout|text|input_state|ids_popup|volume|negative_auto_id`
- or PAGE_DOWN / PAGE_UP (during volume, toggles 500/1000 rows)
- Window size: `VP_GUI_WIDTH` / `VP_GUI_HEIGHT` (default 1024x768; 0 / parse failure → warn + default; clamp 4096)
- Volume rows: `VP_GUI_TORTURE_ROWS=500|1000` (default 500)

## Probe contract (DIGEST_BUF_LEN=1024, top-level k=v)

- **state**: `case` / `active` / `hot` / `active_is_zero` / `dragging` / `focused_id` / `wants_mouse` / `popup_open` / `popup_dismissed` / `layout_generation` + per-case fields (text metrics, behind_clicks, button_count, row_count, …)
- **layout**: `case` / `screen_w` / `screen_h` / `overflow` / `draw_ok` / `layout_completed` / `render_completed` + per-case rects (pane*/slider/text_input/popup_*, …)
- **scroll**: `outer_scroll_y` / `inner_scroll_y` / viewport rects

Key names match the digests observed after implementation. Scripts bake the **first headless
replay measurements**, not invented expectations.

## Running

```bash
# Ordinary E2E (e.g. layout)
VP_HEADLESS=1 \
VP_GUI_TORTURE_CASE=layout \
VP_HARNESS_SCRIPT=examples/37_gui_torture/e2e_layout.txt \
VP_HARNESS_OUT=$(mktemp -d) \
zig build run-example_37

# 100x100 in a separate process
VP_GUI_WIDTH=100 VP_GUI_HEIGHT=100 VP_GUI_TORTURE_CASE=layout \
VP_HEADLESS=1 VP_HARNESS_SCRIPT=examples/37_gui_torture/e2e_layout_100x100.txt \
VP_HARNESS_OUT=$(mktemp -d) zig build run-example_37

# Negative
bash examples/37_gui_torture/negative_auto_id.sh

# bench / leak
zig build bench-gui-frame   # ReleaseFast fixed
zig build test-gui-leak

# standalone
cd examples/37_gui_torture && zig build
```

## Expectation lock-in rules

1. Measure with `digest` alone first.
2. Write measured numbers / rects / scroll into `expect` (no invention).
3. Spec gaps become Missing items (file follow-up work separately).

## Related

- Happy-path matrix: `docs/plans/PLAN_gui_capability_matrix.md`
