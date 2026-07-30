# ADR-020: kit versioning and the maturity gate for promoting a lib into kit

- Status: Accepted.
- Date: 2026-07-30
- Category: Build configuration, public API, module boundaries
- Related: ADR-007 (R4 defines `kit`, R6 positions `libs/paint`, R8 states this
  ADR was deferred, and the "Open questions" note on versioning is closed by
  this ADR)

## Context

ADR-007 drew the `kit` boundary (R4: an umbrella module apps and external
consumers import instead of individual files) and staged its contents "by
maturity, starting narrow", explicitly leaving two things for later:

- "The versioning and semver of `kit` is not settled here. It is decided by a
  separate ADR when external shipping actually approaches."
- The **maturity gate** — the condition under which a lib still in flux
  (`app_direct_ok = true` in `build.zig`, meaning apps may import it directly
  as "internal, may break") is promoted into `kit` and thereby, per R4's own
  wording, becomes "covered by semver".

Both questions stayed open because at the time there was no external shipping
story and no external consumer other than `tictactoe`. Since then:

- `tictactoe` (a `.path` dependency) has broken silently once already, when
  `gui.render` gained a `scale` parameter and the external build was not
  checked before merging.
- `kit`'s re-export list has grown well past ADR-007's original "initial kit"
  set (`platform`, `control`, `types`, `audio`, `gui`, `png`, `font`, `dsp`,
  `synth`) to also include `gamepad`, `midi`, `recipe`, `gmath`, `gfx`,
  `appshell`, `app_runtime`, `sound`, `pixelops`, `command_types`, and the
  `GuiFont` type (`kit/kit.zig`, current top-level `pub const` list).
- The flux allow-list (`app_direct_ok = true` in `build.zig`) currently holds
  five libs: `modular`, `paint`, `spectrogram`, `scope` (the two halves of the
  `libs/viz` family), and `serde`. Only `paint` ships a `README.md`; the other
  four do not. All five have a headless unit test (`test-modular`,
  `test-core` covers `paint`, `test-spectrogram`, `test-scope`, `test-serde`).
- `build.zig.zon` (both this package and `tictactoe`'s) carries a single
  `.version = "0.0.0"` field with no per-module breakdown.

This ADR settles both open items — what unit `kit` versions at, what `0.0.0`
currently means, and what a lib must satisfy before it is promoted into
`kit` — and additionally records a recommended (not yet confirmed) trigger
for when to leave `0.0.0`.

## Decision

### 1. One version number for the whole package, not one per module

`kit` versions as a whole through the single `.version` field in
`build.zig.zon`. There is no separate version for `kit` versus `platform`
versus `build_helpers`.

The reason is mechanical, not stylistic: Zig's own dependency resolution does
not read `.version` for anything yet. The field's own comment in
`build.zig.zon` says so — "In a future version of Zig it will be used for
package deduplication" — and both `.path` dependencies (as `tictactoe` uses)
and `zig fetch` (hash- or URL-addressed) resolve without consulting it today.
A per-module version would therefore be a purely human-facing label with no
tooling consumer, and splitting it into several labels would only multiply
the places that must be kept in sync for no resolver benefit.

### 2. `0.0.0` means semver's initial-development clause applies — no public API is promised stable

ADR-007 R4 states "being in `kit` means being covered by semver." Read at
version `0.0.0`, this is semver's own initial-development clause (`0.y.z`):
anything may change at any time, and being "covered by semver" at this stage
means only that a *future* increment will signal a change — it commits to no
stability now. This is not a reversal of R4; it is `0.0.0` making explicit a
stage R4 always implied but never named. `tictactoe` also pins `.version =
"0.0.0"`, so the external consumer already reflects this stage.

### 3. The version number is a declaration, so it waits until there is someone to declare to

A version here carries no mechanism. Zig resolves a fetched dependency by hash
— a dependency entry in the consumer's `build.zig.zon` records a URL and a
hash, and Zig has no notion of a version *range*, so nothing in the resolver
can pick a different version than the one already pinned. A consumer is
therefore **never upgraded silently**: moving to a newer commit of this
package is always a deliberate act on the consumer's side, even when the
dependency is expressed as a URL rather than `tictactoe`'s `.path`.

What a version number would add on top of that is advance notice — the ability
to tell, *before* changing the hash, whether the change is expected to break —
and nothing else. That bounds the cost of staying at `0.0.0` to the absence of
that notice, which is why this ADR sets no calendar milestone and no
build-artefact milestone as the trigger.

**The package stays at `0.0.0` until there is a party the declaration is for.**
Either of these is the trigger:

- a consumer outside this repository asks for a stability guarantee, or
- a decision is taken to announce releases (a tagged distribution with
  release notes), which is itself a promise to an audience.

Until one of those happens, incrementing the version would announce a promise
to nobody, and the tooling would not read it either.

Rejected alternative: bump to `0.1.0` on the mere existence of an external
consumer (for instance, once an app-authoring scaffold ships and somebody
builds against it). Rejected because a consumer existing is not the same as a
consumer needing a promise — with hash pinning, that consumer's build does not
move until they move it, so the declaration buys them nothing they did not
already have. Rejected alternative: tie the bump to the first tagged release
unconditionally. Rejected as a standalone rule because tagging is a
distribution decision independent of whether the API has settled; it appears
above only in the form that matters, namely announcing releases to an
audience.

### 4. The maturity gate: what a flux lib must satisfy before promotion into `kit`

A lib on the `app_direct_ok = true` allow-list is promoted into `kit` — and
thereby becomes subject to the semver commitment of Decision §2 once `kit`
leaves `0.0.0` — only once it satisfies all of:

1. Its public API has had no breaking change in its commit history over the
   past 90 days (or over its whole history, if it is younger than that). The
   evidence is the lib's own commit log — checkable directly, with no
   separate record to maintain.
2. It ships a `README.md` that a reader with only this repository can follow
   on its own.
3. It has a headless unit test that runs with no display and no audio device
   (an existing `test-*` build step, per `AGENT.md`'s "Common commands").
4. At least one test root that is part of the aggregate `zig build test` gate
   imports the lib through `kit` rather than reaching it directly. This is
   stricter than it looks: today, every flux lib's test coverage either
   roots the test binary directly in the lib's own source (`test-modular`,
   `test-serde`, `test-spectrogram`, `test-scope` build their root module
   straight from the lib) or wires it through a direct named import the same
   way an `app_direct_ok` consumer does (`test-app-modular`'s modules,
   `test-core`'s paint input-state tests, and so on) — so **none of them
   currently satisfy this condition as written**. Promotion requires adding
   or converting at least one test root to go through `kit` specifically, not
   merely switching the consuming app's import. Without this, promoting the
   lib into `kit` would not be
   exercised by anything the aggregate test actually runs, and a break in
   the `kit`-re-exported path could pass `zig build test` unnoticed.

As of this ADR, no lib on the flux allow-list satisfies all four:
`modular`, `spectrogram`, `scope`, and `serde` fail condition 2 (no
`README.md`); `paint` passes 1–3 but, like every flux lib today, fails
condition 4 until a `kit`-routed test root exists for it. Separately from
the gate, ADR-007 R6 positions `libs/paint` as the editor family's shared lib
rather than a general-purpose one; that family-scoped positioning is its own
axis, independent of the maturity gate — a lib could satisfy every gate
condition and still stay out of `kit` because it was never meant to be
general-purpose. Meeting the gate is necessary for promotion; for a
family-scoped lib it is not sufficient.

### 5. How a breaking change to `kit` is caught today (not through the version number)

Choosing to stay at `0.0.0` (Decision §2) is also choosing not to signal
breaking changes through the version number for now. The current, and only,
safeguard is procedural: **a branch that changes the public API surface
reachable through `kit` builds `tictactoe` against that branch before
merging.** This covers two cases, not one: changing what `kit` re-exports
(adding or removing an entry), and changing the API of something already
re-exported without touching the export list at all — the second is exactly
what happened when `gui.render` gained its `scale` parameter: `gui` stayed on
`kit`'s re-export list throughout, yet the external consumer broke silently
because nobody built it against that branch. `AGENT.md`'s "Common commands"
section states the requirement ("Build it against your branch when you
change anything `kit` re-exports"), and is read here as covering both cases.

This safeguard has a known limit: `tictactoe` lives in a separate repository,
so running its build against a `kit`-changing branch is a manual step, not
one the aggregate `zig build test` enforces. An external-app-authoring
scaffold, once it exists, is expected to live inside the aggregate build gate
the same way the in-tree example and app builds already do, which would make
that half of the check mechanical; `tictactoe` would stay a manual check
regardless, being a separate repository by design. A changelog or a similar
written announcement for `0.1.0` and beyond is deliberately not decided here —
it is deferred to whenever the trigger in Decision §3 actually fires.

## Rejected alternatives

**Per-module semver** (separate `.version` fields for `kit`, `platform`,
`build_helpers`, …). Rejected per Decision §1: nothing in the toolchain reads
`.version` for resolution today, so splitting it multiplies bookkeeping for
no consumer.

**Signalling breaking changes by bumping the version number while remaining
in the `0.y.z` series** (e.g. `0.0.0` → `0.0.1` or `0.0.0` → `0.1.0` without
otherwise changing Decision §2's stance). Semver's own initial-development
clause makes every `0.y.z` release implicitly "may break", so such a bump
carries no signal a reader could act on beyond what `0.y.z` already says.
The procedural safeguard in Decision §5 is the one that currently has teeth;
a version bump that stays inside `0.y.z` would not add one.

**Promoting a flux lib into `kit` on API stability alone**, without the
README and test conditions. Rejected: `kit` is the surface an external reader
with no access to this project's development history meets first, and a lib
promoted with no `README.md` or no headless test would expose that reader to
confusion — and to the lack of a safety net — right at the public boundary.

## Consequences

- `build.zig.zon`'s `.version` stays a single field; no build-graph change
  follows from this ADR.
- The maturity-gate conditions in Decision §4 are a checklist the next
  promotion candidate is judged against; `libs/modular`, `libs/viz`
  (`spectrogram`/`scope`), and `libs/serde` each need at minimum a
  `README.md` before they are even eligible.
- `libs/paint` stays out of `kit` on the family-scoped axis regardless of how
  the gate conditions evolve; this ADR does not reopen ADR-007 R6.
- Until a Decision §3 trigger fires, every `kit` consumer — in-tree and
  external — is on notice that the API carries no stability guarantee, per the
  initial-development clause of Decision §2. Hash pinning is what makes that
  workable: a consumer's build does not change until the consumer changes it.
- The `tictactoe` build-before-merge check (Decision §5) remains the operative
  safeguard against breaking an external consumer and is unchanged by this
  ADR; it is recorded here as the reason `0.0.0` is a workable choice rather
  than a gap.
- A separate, pre-existing gap surfaced while writing this ADR, and it bears on
  the hash-addressed consumption Decision §3 reasons about:
  `build.zig.zon`'s `.paths` list (`build.zig`,
  `build.zig.zon`, `src`, `platform`, `libs`, `build_helpers`, `apps`,
  `examples`, `web`, `cli`, `LICENSE`) does not include `core/` or `kit/`,
  even though `build.zig` reads `core/*.zig` and `kit/kit.zig` directly. Zig's
  package manager keeps on disk, and hashes, only the paths listed here, so a
  consumer that fetches this package by URL (rather than `tictactoe`'s
  `.path` dependency, which reads the working tree directly and is
  unaffected) would receive a package missing the very modules `kit`
  re-exports. Fixing `.paths` is outside this ADR's scope (it changes
  `build.zig.zon`, not a versioning or maturity-gate decision), but it is a
  precondition for the URL-addressed consumption this ADR reasons about: until
  the gap is closed, a consumer who fetches by URL cannot build at all, so no
  version number this ADR might assign would mean anything to them.

## Related

- ADR-007 (R4 `kit`, R6 `libs/paint`'s family-scoped positioning, R8's
  deferral of this exact ADR)
- `AGENT.md`, "Common commands" — the `tictactoe` build-before-merge
  requirement this ADR relies on in Decision §5
- `kit/kit.zig` — the current re-export list cited in Context
- `build.zig` — the `app_direct_ok` allow-list and the `TaggedModule` /
  `link()` machinery that mechanically separates flux libs from `kit`

## Revision history

- 2026-07-30 First version (accepted), closing the versioning and maturity-gate
  items ADR-007 R8 deferred. Decision §3 states the trigger for leaving
  `0.0.0` in terms of who the declaration is for, rather than in terms of a
  build artefact or a date, because hash pinning leaves a version number with
  no mechanical role.
