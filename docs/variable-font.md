# Variable fonts (OpenType Font Variations) API

How to use OpenType variable fonts in `libs/font` (TrueType glyf + CFF2). The axis API is local
to an `OutlineFont` instance. Standalone fonts own their coverage cache; variants produced by
`OutlineFontFamily` share the family's bounded coverage cache. Advance data is invalidated and
rebuilt when axes change. [`docs/adr/032`](adr/032_default-outline-font-and-glyph-cache.md) records
how that cache is bounded and why the default outline font is chosen the way it is.

## Overview

| Table | Role |
|----------|------|
| `fvar` | Axis definitions and named instances (enables the variable API when present) |
| `avar` | Optional non-linear map of normalised coordinates |
| `gvar` | Tuple variation of glyf points / composite offsets |
| `HVAR` | Advance variation (preferred; otherwise gvar phantoms) |
| `CFF2` | CFF2 outlines + VariationStore + charstring `blend` / `vsindex` |

- **Static CFF1** works as before. **CFF coexisting with CFF2, or glyf coexisting with CFF/CFF2,
  is `InvalidFont`**.
- **pixelMetrics** (ascender and so on) do not follow MVAR, so they are an **axis-independent
  approximation** (from the default instance).

## Basic usage

```zig
const font = @import("font");

const face = try font.FontFace.init(ttf_bytes);
var of = font.OutlineFont.init(allocator, &face, 48);
defer of.deinit();

// Axis count / tag / range
const n = of.axisCount(); // 0 = not variable
if (n > 0) {
    const tag = of.axisTag(0).?; // e.g. "wght"
    const range = of.axisRange(0).?; // .min / .def / .max
    _ = tag;
    _ = range;
}

// Set one axis in design space (out of range is clamped; unknown tag / non-VF → Unsupported)
const wght = [4]u8{ 'w', 'g', 'h', 't' };
try of.setAxis(&wght, 700);

// Set every axis at once
try of.setAxes(&.{700}); // len == axisCount

// Named instance (fvar index)
try of.selectNamedInstance(0);

// Back to defaults
try of.resetAxes();

// Read-back
_ = of.axisValue(0);
var norm: [16]f32 = undefined;
of.normalizedAxes(&norm); // normalised coords after avar
```

## Caches and advance

- **Standalone raster cache** / **sbix colour cache**: cleared by `setAxis` / `setAxes` /
  `selectNamedInstance` / `resetAxes`.
- **Family coverage cache**: keyed by `(gid, logical size, wght value, draw scale)`, capped at
  4 MiB and 512 entries, and shared by all size/weight variants. A weight-axis change selects
  a different key; a non-weight axis clears the shared cache because it is not represented in
  the key. Oversized glyphs are retained as negative entries.
- **Diagnostics**: `rasterizationCount`, `evictionCount`, `retainedCoverageBytes`, and
  `coverageEntryCount` expose bounded-cache behaviour. Cache hits do not increment a counter.
- **advance_cache** (`?[]f32`, length `numGlyphs`): **eagerly built** on axis change.
  - `measure` / wrapping / colour drawing read the built cache read-only (no per-frame gvar/HVAR decode).
  - Coverage rasterisation is draw-only; measure, intrinsic width, and wrapping never fill it.
  - Allocation failure surfaces as `error.OutOfMemory` from the axis-change API.
- **Advance priority**:
  1. If a composite has `USE_MY_METRICS` → advance of the **last** such component (recursive: HVAR > phantom > hmtx)
  2. Otherwise → that gid's HVAR > gvar phantom > hmtx

## CFF2 variable fonts

- `FontFace.init` accepts a `CFF2` table (`OutlineSource.cff2`).
- Outline variation uses charstring **`blend` / `vsindex`** and the TopDICT **VariationStore**
  (ItemVariationStore; shared foundation with HVAR).
- Respects the Private DICT's initial `vsindex`. CharString `vsindex` may override it.
- **Advance is not inside CFF2** → use `hmtx` / `HVAR` (via the metrics cache). Width operands are not read.
- Axis coordinates use the same `setAxis` / `axis_norm` latch as glyf VF and are passed to
  `Cff2Font.outline(..., norm)`.
- `gvar` / IUP are not used for CFF2.

```zig
// CFF2 VF uses the same axis API
const face = try font.FontFace.init(otf_cff2_bytes);
var of = font.OutlineFont.init(allocator, &face, 48);
defer of.deinit();
try of.setAxis(&wght, 700);
of.drawTo(target, pos, "あ", col, clip); // outline follows the axes
```

## Composites and gvar

- gvar point indices are **component indices** (not expanded outline points).
- Deltas apply only to placement offsets when `ARGS_ARE_XY_VALUES`. scale / 2×2 are not varied.
- The SCALED_COMPONENT_OFFSET rule for offsets is applied **after** the delta, as before.
- Composites do **not** run IUP (unreferenced component deltas stay 0).
- Point-matched composites (non-XY) are `Unsupported` in low-level `Glyf`, and `InvalidFont` on
  the public `OutlineFont` path.

## Error policy

| Situation | Result |
|------|------|
| `setAxis` on a non-variable face | `error.Unsupported` |
| Broken fvar/avar/gvar/HVAR | `FontFace.init` → `error.InvalidFont` |
| Missing table | non-variable / default outline / phantom fallback |
| OOM during axis change | `error.OutOfMemory` |

## GUI default asset

The GUI default family is built from the Noto Sans JP variable TTF declared in the root
`build.zig.zon`. The manifest pins a versioned archive URL, a package hash, and the exact
archive path; the TTF is not copied into the repository.

An ordinary `zig build` fetches the package on a cold cache. To prefetch it explicitly, run
`zig fetch --save-exact=noto_sans_jp https://github.com/notofonts/noto-cjk/releases/download/Sans2.004/02_NotoSansCJK-TTF-VF.zip` from the repository root,
or run the normal build once while network access is available. Warm and offline-cache
builds reuse the same content-addressed package. Native and WebAssembly builds consume the
same generated `@embedFile` wrapper, so they use identical font bytes.

## Related

- Implementation: `libs/font/src/{fvar,avar,gvar,hvar,glyf,outline_font,var_common}.zig`
- Tests: `zig build test-font`
