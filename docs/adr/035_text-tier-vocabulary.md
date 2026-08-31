# ADR-035: Seven role-oriented text tiers

- Status: Accepted
- Date: 2026-09-01
- Scope: `TextTier` and the sizes, weights and colours behind it, as resolved by
  `Context.labelStyled`. The policy that makes an addition to the published
  surface one-way is [020](020_kit-versioning-and-maturity-gate.md); the default
  outline family and the glyph cache these tiers draw from are
  [032](032_default-outline-font-and-glyph-cache.md).

## Context and problem

The tiers were `heading` (20px/700), `body` (16/400), `caption` (13/400) and
`muted` (12/400). One heading level means a screen can express two levels of
hierarchy — heading and body — and nothing between them.

That is a measured shortfall, not a theoretical one. Assembling one screen
(`examples/47_screen_layout`) left the sidebar's "Collections", the inspector's
"Details" and the list's column headers with nowhere to go but `caption` or
`body`, so the lower two thirds of the screen came out at one size and one
weight. A section heading sat at the same visual weight as its own contents, and
the eye had nothing to tell it where a group began.

The goal is not "one more tier". It is that **a design written in a standard
vocabulary can be transcribed without inventing a mapping**. The vocabularies
worth being able to read from are HTML/CSS (`h1`–`h6`, `p`, `small`), Material 3
(display / headline / title / body / label, each in Large / Medium / Small),
Apple HIG (largeTitle, title1–3, headline, subheadline, body, callout, footnote,
caption1–2) and Tailwind (`text-xs` … `text-4xl`).

Two forces pull against each other. Too few tiers and a design cannot be
transcribed; too many and every call site becomes a decision ("is this a heading
or a subheading?"), which is the cost the previous four-tier set was avoiding.

## Decision

**Seven tiers, named for the role they play rather than for their position in a
heading hierarchy**, declared largest to smallest:

| Tier | Size | Weight | Role |
|---|---:|---:|---|
| `headline` | 24px | 700 | screen title, the topmost visual heading |
| `title` | 20px | 700 | card or window title; a title inside a major section |
| `subtitle` | 18px | 600 | section heading in a sidebar or inspector |
| `body` | 16px | 400 | ordinary prose, descriptions, a list's values |
| `label` | 14px | 600 | column header, form field name, short UI label |
| `caption` | 13px | 400 | a note or aside the reader is still meant to read |
| `muted` | 12px | 400 | lowest-priority hint or optional metadata |

`heading` is renamed to `title`, keeping its 20px/700 exactly, so screens that
used it look unchanged. `body`, `caption` and `muted` keep their names and
values. `headline`, `subtitle` and `label` are new.

Sizes and weights are written in one place (`defaultTextStyles` in
`libs/gui/src/style.zig`) and are the same in both themes; only the colours
differ. `Style` holds one `TextStyle` per tier in an array indexed by the enum,
so adding a tier widens the array rather than requiring a new field and a new
`switch` arm.

### Choosing between 12, 13 and 14 px

Three tiers inside a two-pixel band is deliberate, and size is the least of what
separates them — so the rule is stated by role, not by number:

- `label` (14/600): a short **name** the eye scans to find structure. Column
  headers, form labels, short metadata.
- `caption` (13/400, subtle): a **sentence** that supplements the content and
  that the reader is meant to read.
- `muted` (12/400, derived from subtle): something **droppable** — a hint or
  optional metadata whose absence loses nothing.

### The mappings

HTML/CSS:

| External | Tier |
|---|---|
| `h1` | `headline` |
| `h2` | `title` |
| `h3`, `h4` | `subtitle` |
| `h5`, `h6` | `caption` |
| `p` | `body` |
| `small` | `muted` |

Material 3:

| External | Tier |
|---|---|
| `displayLarge/Medium/Small`, `headlineLarge/Medium/Small` | `headline` |
| `titleLarge` | `title` |
| `titleMedium`, `bodyLarge` | `body` |
| `titleSmall`, `bodyMedium`, `labelLarge` | `label` |
| `bodySmall`, `labelSmall` | `muted` |
| `labelMedium` | `caption` |

Apple HIG:

| External | Tier |
|---|---|
| `largeTitle`, `title1` | `headline` |
| `title2`, `title3` | `title` |
| `headline`, `subheadline` | `subtitle` |
| `body`, `callout` | `body` |
| `footnote`, `caption1` | `caption` |
| `caption2` | `muted` |

Tailwind:

| External | Tier |
|---|---|
| `text-xs` | `muted` |
| `text-sm` | `label` |
| `text-base` | `body` |
| `text-lg` | `subtitle` |
| `text-xl` | `title` |
| `text-2xl`, `text-3xl`, `text-4xl` | `headline` |

These map roles onto a fixed set of seven; they do not reproduce the sources
numerically. What is deliberately not carried over: exact pixel sizes, per-step
line heights, and Tailwind's independent weight modifier.

## Rejected alternatives

**Keep the four tiers.** It cannot express a section heading distinct from its
contents, which is the shortfall that was measured.

**Six tiers, dropping `label`.** Then a column header and a supplementary
sentence share one tier, and the choice between "a short name" and "a sentence"
has no answer — the ambiguity the role naming exists to remove.

**Eight tiers, adding `display` at 32px/700.** It would let HTML `h1`, Material
`display` and Tailwind `text-4xl` each map to their own step. Nothing in this
repository would use it: at a logical 1024x768 window, 32px/700 is a poster
headline, and the largest thing on the sample screen — a window title — is
served by 24px. A published surface is one-way (020), so a tier with no use here
is a promise made for nothing. `h1` maps to `headline` instead.

**Mapping `h5`/`h6` to `label`.** This is the trap the role naming is meant to
avoid: it puts a heading level and a form field name in the same slot, so the
author is back to asking "is this a heading or a label?" at each call. `h5` and
`h6` map to `caption`, and `label` stays off the heading axis. The cost is that
the two smallest HTML heading levels are not visually distinct from each other,
which real designs rarely rely on.

**Relative names (`heading`, `subheading`, …).** A relative name has to be
re-derived for each external vocabulary, which is the work this ADR is trying to
remove. It would also put `heading` next to `headline` in the same enum.

**Per-tier `line_height`.** `TextStyle` carries colour, font, size and weight;
line spacing comes from the resolved font's metrics. Adding a per-tier value
would put the same quantity in two places and widen the layout contract, and no
part of the shortfall being fixed asks for it.

**Keeping one `Style` field per tier plus a `switch` in `textStyle`.** Every new
tier then has to be added to the enum, to `Style`, to the constructor and to the
`switch`, with nothing to catch a miss. The enum-indexed array reduces that to
the enum plus one line in `defaultTextStyles`.

## Consequences

**Existing `.heading` call sites become `.title` and keep their pixels.** The
value is identical, which is what let the change land without altering any
screen that was not the point of it: `examples/46_style_gallery`,
`examples/35_gui_gallery`, `examples/10_gui_layout` and
`examples/37_gui_torture` keep the pixels they had, and every recorded draw-list
hash and layout-sanity count in their end-to-end scripts still holds unedited.
The vocabulary is shown in one place — a new section in
`examples/46_style_gallery` — rather than by widening the `labelStyled` row in
the widget gallery, which would have pushed that section's content past its box.
The only screen whose appearance changes is `examples/47_screen_layout`, whose
flat hierarchy is the shortfall being fixed.

**Seven distinct `(size, weight)` pairs resolve to seven font variants.**
`OutlineFontFamily` creates a variant per pair on demand and they share one
glyph coverage cache (4 MiB / 512 entries), so the tiers raise the pressure on
that cache relative to four. The cache limits are unchanged: a test asserts that
no two tiers share a quantized `(size, weight)` — which would silently collapse
two tiers onto one face — and the frame benchmark is not treated as evidence
about cache pressure, since it does not exercise `labelStyled`.

**A tier added later is carried into the tests and the gallery, and fails loudly
where it is not.** The style tests, the `labelStyled` tests and
`examples/46_style_gallery`'s specimen section all walk `@typeInfo(TextTier)`, so
a new tier is exercised and displayed without anyone wiring it up. Three places
still need an explicit edit, and each one fails until it gets one: its size and
weight in `defaultTextStyles`, its row in the `expected_tiers` table beside the
style tests, and the counts in the gallery's end-to-end script (which reports the
tier count from the enum for exactly this reason). That is the intended shape —
the automatic half removes the work, and the manual half refuses to go green
while a new tier is undesigned or unshown.
