# libs/vector

Analytic coverage rasterizer for filled paths (area/cover dual buffers,
adaptive de Casteljau flatten). Headless, `std` only.

| File | Role |
|---|---|
| `src/lib.zig` | Public API root |
| `src/outline.zig` | `Outline` / `Builder` / line-quad-cubic `Segment` (caller units) |
| `src/raster.zig` | Area/cover fill, adaptive flatten, `ScaleTranslate` |

## Type split with `libs/font`

- `Outline` lives here: it is a generic f32 path. Font parsers emit font-unit
  coordinates into it; the rasterizer does not interpret the units.
- `Transform` (font units → device px, conventionally `sy < 0`) stays in
  `libs/font`. The rasterizer applies the generic `ScaleTranslate`.

## Not on kit

Applications do not import this module. Path fills go through a consumer
such as `libs/font`. Promote into kit only when a direct application API is
required, following the kit maturity gate (ADR-020).

