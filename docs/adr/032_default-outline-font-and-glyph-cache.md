# ADR-032: Default outline font and shared glyph coverage cache

## Status

Accepted.

## Context

The GUI's fixed bitmap font is deterministic but cannot draw Japanese and provides no
anti-aliased outline at fractional display scales. Text tiers also carried colour and an
optional font only, so a tier could not express its intended size or weight.

The replacement must be deterministic for native, WebAssembly, headless replay, and
standalone consumers. Runtime system-font lookup is not deterministic enough for that
contract. The font bytes must therefore enter the build through a content-hashed URL
dependency without adding a binary asset to this repository.

## Decision

The public `gui.default_font` is a lazy proxy for a Noto Sans JP variable TrueType face.
The face is obtained from the versioned Noto CJK `Sans2.004` release archive in
`build.zig.zon`, with Zig's package hash as the content identity. The package exposes only
`Variable/TTF/Subset/NotoSansJP-VF.ttf`; the archive itself is not copied into the source
tree. The exact URL, source commit, archive hash, TTF hash, and byte size are recorded in
`libs/font/LICENSE`.

`default_bitmap_font` remains an explicit opt-in for callers that need the fixed 8x16
bitmap contract. A default outline family owns stable size/weight variants and one
`GlyphCoverageCache`. A variant borrows the family cache; a standalone `OutlineFont`
retains its private cache.

The coverage key is `(gid, logical_size_q, weight_q, scale_q)`, where pixel sizes and draw
scales are quantised to 1/64. Cache payload is capped at 4 MiB and entries at 512. Entries
are evicted least-recently-used. A glyph larger than the payload limit becomes a negative
entry, so repeated frames do not retry rasterisation. Diagnostics expose rasterisation
count, eviction count, retained payload bytes, and entry count without updating a hit
counter on the steady-state path.

Text measurement and wrapping use advances and metrics only. They never populate the
coverage cache. `Context.labelStyled` resolves an explicit `TextStyle.font` first; when
the context has the default outline family it resolves the tier's size and weight to a
stable variant. Bitmap fonts and custom fonts without a family use the context font and
ignore tier size and weight. A face without a `wght` axis ignores weight rather than
generating synthetic bold.

Coverage blitting uses the existing `pixelops.srcOverCoverage4` four-pixel primitive and
its matching scalar tail. Clip intersection, destination stride, and source colour are
computed outside the per-pixel work. The coverage loop is frame-time, full-pixel work;
allocation and outline rasterisation remain cache-miss-only operations.

One variant is created per tier `(size, weight)` pair, and the pairs are listed in
[035](035_text-tier-vocabulary.md), which owns the tier vocabulary. What matters here is
the count: each distinct pair is one `OutlineFont` sharing this coverage cache.

## Alternatives rejected

### Repository-embedded TTF

Embedding the font would remove the first-build network request but would add a large
binary to the source repository and duplicate the source-of-truth relationship that a
content-hashed package already provides.

### Runtime system font lookup

System fonts vary by operating system, installed version, language coverage, and headless
environment. That changes metrics, raster output, and replay results, so it cannot provide
the default-font contract.

### Raw single-file URL

Zig 0.16 rejects the Google Fonts raw URL for a naked TTF as a package dependency. The
versioned Noto CJK release archive contains the same upstream variable-font source family,
has a stable release URL, and is accepted by Zig's fetcher. The archive path is pinned in
the manifest's `paths` list so unrelated archive files do not become build inputs.

## Consequences

The first build requires network access or a pre-populated Zig package cache. Warm and
offline-cache builds reuse the same content hash. The Noto bytes are included in native
and WebAssembly artifacts, increasing their size, but the application receives the same
font bytes on every target. Cache memory is bounded, while multi-size screens may evict
old glyphs and rasterise them again after eviction.

The bitmap font remains available for pixel-oriented clients, while the GUI default now
supports Japanese labels and anti-aliased text without an application-side font setup.
