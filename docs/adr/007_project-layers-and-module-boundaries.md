# ADR-007: Project layers and public module boundaries (core / libs / apps + kit)

**Status:** Accepted
**Date:** 2026-07-04
**Category:** Architecture, build configuration, module boundaries

## Summary

To grow this project as "a thin, fast multi-platform foundation plus the
applications that use it", `kngn/` is **strictly layered by dependency
direction**, and those boundaries are **enforced by the module graph in
build.zig**. The existing `src/` — a catch-all holding the platform facade, every
backend, audio, the harness, and sprite/text/dsp together — is dismantled, and a
place is prepared in advance so that incoming code (the state-model `framework/`,
`platform_wasm`, and later serde/vg/timeline) lands where it belongs from the start.

**The decision, as explicit rules:**

- **R1 layers and direction**: only `apps → libs → core → platform` is allowed. No
  reverse dependencies and no skipping layers.
  - **L0 `platform/`** — native implementations (the C ABI plus macOS
    objc/swift/metal). Unchanged.
  - **L1 `core/`** — the platform facade (`platform*.zig`), the audio
    facade and backends (`audio*.zig`), and `core/control/`. A **thin base** that
    depends on platform only and never on libs.
  - **L2–L3 `libs/`** — portable reusable libraries. **As a rule they do not depend
    on platform** (so they can be unit tested headless).
  - **L4 `apps/` and `examples/`** — terminal consumers.
- **R2 libs are headless**: a lib does not depend on a platform *implementation*
  (it does not `@import("platform")`). Where it needs shared types such as input
  events, it reaches them only through the type-only module of R6. The editor core
  already follows this discipline; it is extended to every lib.
- **R3 promote the harness into `core/control`**: `src/harness.zig` moves to
  `core/control/` and is promoted from "test-only infrastructure" to a
  **permanent runtime capability** — a control and observation plane (probe,
  action, drive, replay, virtual clock). The default of being a complete no-op when
  its environment variables are unset (zero regression for normal runs) is kept.
- **R4 the `kit` public module**: build.zig defines an umbrella module `kit` that
  re-exports a stable subset (the platform facade, core/control, and selected
  libs). **Applications and external consumers depend on `@import("kit")` alone**,
  never on individual files. This is where the boundary is drawn so that internal
  refactoring does not break consumers.
- **R5 apps are kit-only consumers**: anything under `apps/` can import only kit,
  enforced by build.zig. Even in-repo they are effectively external consumers, so
  the boundary is verified continuously. Apps stay in-repo for now, and can move to
  sibling repositories at the graduation trigger in R8.
- **R6 reclassify by reusable vs terminal**: where code lives is decided by
  "reusable or terminal", not by "under an app directory or not". `apps/editor/core`
  (Canvas/Tool/Undo/PNG I/O — a reusable core shared by several applications) is
  **promoted to libs**, and only the **terminal shells** of the editor and synth
  remain as apps. The shared types in `platform_types.zig` are published from core
  as a type-only module, and libs may reference that alone (never the native
  implementation).
- **R7 heavy and optional capabilities are opt-in modules**: heavy or optional
  capabilities such as GPU compute, video decode and networking are not mixed into
  core but become independent modules, so only the applications that link them pay
  for them. **Core not growing is what "thin" actually means.** The existing rule
  that the audio backend is linked only into executables that use audio is extended
  to every heavy lib. **One exception is on record**: netsync is networking that lives
  in `core/control` rather than in a module of its own, granted because it adds no
  framework or library link dependency and carries the control plane's own commands. ADR-014 states the
  exception, its grounds, and the conditions that would end it. The per-executable
  linking mechanism that R7 relies on is recorded in ADR-013.
- **R8 decide now, migrate later**: the skeleton — creating `core/`, defining
  `kit`, enforcing dependencies in build.zig, and the R6 reclassification — is
  **built now in one deliberate refactor**. Physically moving existing files is
  **opportunistic** (moved into the right family when next touched); there is no
  bulk rewrite. Splitting an app into its own repository happens when its API has
  stabilised or when it wants its own release cadence; until then in-repo is the
  better deal.

**Target layout** (grouped by family, since there will be more than eight libs):

```
kngn/
├── platform/            # L0 native (unchanged)
├── core/                # L1 thin base (depends on platform, never on libs)
│   ├── platform*.zig    #   facade + x11/wayland/gdi/d3d11/wasm backends
│   ├── audio*.zig       #   audio facade + backends
│   └── control/         #   ← the promoted harness (probe/action/drive/replay/virtual clock)
├── libs/                # L2–L3 portable (platform-independent as a rule, unit testable)
│   ├── sys/   → serde / task / net …
│   ├── gfx/   → vg / color / png / font
│   ├── ui/    → gui
│   ├── audio/ → dsp (moved out of src/) / synth
│   ├── time/  → timeline
│   └── paint/ → the promoted editor core (Canvas/Tool/Undo/PNG I/O)
├── apps/                # L4 kit-only consumers: editor (pixie…) / synth
├── examples/            # small single-purpose demos (teaching material)
└── docs/  (adr/ plans/)
```

## Context

- The project's banner is "an AI-agent-friendly, thin, fast multi-platform
  foundation plus applications built on it". That banner should be **held up by the
  structure too**: headless libs (easy for an agent to unit test and observe), a
  first-class control plane, and a core that does not bloat — enforced by the build
  rather than by convention.
- `src/` currently holds the platform facade, every backend, the audio facade and
  backends, the harness, and sprite/text/dsp side by side. Piling new code on top of
  that is certain to collapse. Two pieces of incoming work — the state-model
  `framework/` (action/serialize/network) and `platform_wasm` — need a home for new
  files right now.
- Where reusable code lives is already inconsistent: `src/dsp` versus
  `libs/synth`; `sprite` and `text` in `src/` while `png`, `gui` and `font` are in
  `libs/`. More foundation libs are queued (serde, vg, timeline, net, job), and
  without a decided shape they will scatter.
- External consumption is already demonstrated by `tictactoe` depending on this one
  with a `.path` dependency, so there is a working example of the public boundary. In-repo
  applications, by contrast, can reach straight into internal files, which makes
  **boundary rot** a structural risk.

## Comparison

### Option A: keep things as they are (flat `src/`, apps reaching inside)

- **Benefit**: no extra cost. Can keep writing immediately.
- **Cost**: `src/` collapses under the incoming work. Applications reference
  internal files directly and the public boundary rots. Nothing holds up "thin" or
  "headless libs". → **rejected**.

### Option B: split repositories now (platform and apps into separate repositories)

- **Benefit**: the strongest outward signal that "this is the foundation product,
  the apps are separate". The boundary is physically enforced.
- **Cost**: the platform API is still moving fast (frame pacing, the control plane,
  serde and vg unimplemented). Splitting here **freezes the API too early** and
  makes cross-cutting renames non-atomic. The outer `video-proto/` is already a set of
  sibling jj repositories, and `tictactoe`'s `.path` consumption is proven — so
  **splitting stays cheap and can be done at any time**, and there is no gain in rushing. →
  **rejected as premature**.

### Option C: layers + build.zig enforcement + the kit boundary (draw the boundary in the build graph, inside the monorepo) — chosen

- **Benefit**: keeps **atomic cross-cutting refactors** in-repo (a platform change
  and its consumers land in one commit, detected immediately by `zig build test`),
  while kit-only consumption **verifies the public boundary continuously**, and R7
  protects thinness. The split of option B — cheap and available at any time — is
  deferred to the point where it is actually wanted (R8).
- **Cost**: the module graph in build.zig gets more complex. `kit` takes on
  backward-compatibility responsibility (versioning is out of scope here).
- **Verdict**: given the three banners (thin, fast, agent-friendly) and the current
  API churn, C is the only option that satisfies all the trade-offs.

### A supporting point: classifying by reusable vs terminal (R6)

Cutting along "apps versus platform" gets `apps/editor/core` wrong. It is a
**reusable core shared by several applications — a lib** — not an app. Changing the
axis to "reusable or terminal" shrinks the boundary problem down to **the terminal
shells alone**, which makes the judgement simple (R6, R8).

## Consequences

- New code lands **in the right place from the start**: `framework/` next to
  `core/control`, `platform_wasm` in `core/`. Preparing the shape first pays off
  immediately.
- Moving existing files is **deferred** (R8). No big-bang rewrite, so regression
  risk stays low. The low-risk moves go first: `src/dsp` → `libs/audio`,
  `sprite`/`text` → `libs/gfx`, the harness → `core/control`, the editor core →
  `libs/paint`.
- build.zig defines the module graph and the `kit` re-exports. **A dependency
  violation becomes a build error**, so the rules are kept mechanically.
- **Handling shared types** is the crux of the implementation: `platform_types`
  (KeyCode, Event and friends) is published from core as a type-only module, and
  libs reference only that (never the native implementation). How `libs/gui` takes
  event types is settled during migration (open at the time of writing).
- The **granularity of `kit`** — which libs are on the public face — is **staged by
  maturity, starting narrow** (the details to be fixed by a separate ADR when
  external shipping approaches):
  - **The initial `kit` holds stable libs only**: the platform facade, control,
    types, audio, gui, png, font, dsp, synth.
  - **Libs still in flux (serde, vg, timeline, net) are not in `kit`.** Applications
    import them directly for now, on the understanding that they are internal and
    may break, and they are **promoted into `kit`** once the API settles (a maturity
    gate).
  - The paint lib (the former editor core) is treated as **the shared lib of the
    editor family** rather than part of the general-purpose `kit`, and only the
    applications that need it depend on it.
  - This staging is the other side of versioning: **being in `kit` means being
    covered by semver**, so anything that cannot promise semver does not go in.

### Settled during the skeleton implementation (2026-07-04)

- **Open question #1 settled**: `platform_types` is published as a **type-only
  module owned by core** (`TaggedModule{ .layer=.core, .type_only=true }` in
  build.zig), and libs may reference only those core modules that are type-only
  (enforced by the `.lib => dep.layer == .core and dep.type_only` branch in
  `link()`). `libs/gui` uses its own input types today so nothing changed there;
  if it ever needs to share event types it will reference `platform_types` directly
  (never the native implementation or the facade).
- **`audio` (the `core/audio` facade) was added to the initial `kit` set** — decided
  during implementation rather than in the original list — because the synth,
  modular and patch applications all require the L1 output facade and the facade is
  already stable. `types` was put on kit explicitly as well.
- **How R1 is checked**: build.zig gains a `Layer` enum (core=1 / lib=2 / kit=3 /
  app=4) plus `TaggedModule` and `link()`. Reverse dependencies, skipped layers and
  disallowed direct imports by apps stop the build with `std.debug.panic` **during
  build configuration**. Physically, each layer also has its module root in its own
  directory, so a relative `@import` into an unwired layer becomes a "file outside
  module path" compile error — two lines of defence.
- **Only localised exceptions**, each behind an explicit API. The authoritative
  list is the `linkCoreException` / `linkAppException` call sites in `build.zig`
  (also summarised in `AGENT.md`). The current set is five edges:
  ① `linkCoreException` — `harness(core/control) → png(libs/png)` (encoding
  snapshots and crc32; png is a dependency-free pure Zig leaf lib, so headlessness is
  preserved); ② `harness(core/control) → dsp` (spectrum analysis behind the audio
  digest: band, centroid, onset; analysis runs only when a digest is requested, never
  touching the real-time path); ③ `platform(core) → pixelops(libs/pixelops)`
  (BGRA→RGBA SIMD swizzle for wasm present). ④–⑤ `linkAppException` —
  `example_26 → paint` (demo direct import); `apps/patch/lofi.zig → synth` and
  `→ dsp` (generative-layer types such as `SampleTap` / `AtomicF32` and FFT
  band-energy checks, keeping a pure-test root platform-free). Apps reach pixelops
  through `kit.pixelops` (stable re-export), not a direct exception. Kit and a
  direct import of the same lib are the same module instance, so type identity holds.
- **The allow-list for direct imports by apps** (libs not in kit because they are
  still in flux): modular, paint, viz (spectrogram/scope). It is managed by
  `TaggedModule.app_direct_ok=true`, and wiring an app directly to a lib that *is*
  in kit panics.
- **Examples are outside the scope of R5 (kit-only)**: as teaching material they
  keep their individual module wiring, and `src/main.zig` is treated the same way.
- **Which files actually moved** (the low-risk set only): `src/platform*` and
  `src/audio*` → `core/`; `src/harness.zig` → `core/control/harness.zig`;
  `apps/editor/core/` → `libs/paint/src/` (root `paint.zig`);
  `apps/synth/{spectrogram,scope}.zig` → `libs/viz/src/`. **`src/dsp`, `sprite`, `text` and others stay put under R8**
  (to be moved into libs/audio and libs/gfx by whichever task next touches them).
  The harness keeps the module name `"harness"` to minimise churn; renaming it to
  `"control"` is decided when `control/` grows beyond one file.
- The **versioning and semver** of `kit` is not settled here. It is decided by a
  separate ADR when external shipping actually approaches.
- The `build_helpers` symlink workaround for standalone example builds — including
  the Windows limitation described in `AGENT.md` — is out of scope here. Moving to
  `kit` opens a path to removing it later, but it is untouched now.
- Splitting an app into its own repository (graduating under R8) can be done as a
  **non-event**, because the app depends on `kit` alone.

## Related

- ADR-005 (platform support tiers and the frame pacing contract) — a related
  existing decision
- The "directory structure" and "editor (apps/editor + libs/paint + libs/gui)"
  sections of `AGENT.md`, and `libs/paint/README.md`
- `tictactoe` (a `.path` dependency) — the worked example of external consumption
- Implementation: build.zig (`Layer`, `TaggedModule`, `link()`,
  `linkCoreException`, `linkAppException`) and `kit/kit.zig`

## Revision history

- 2026-07-04 First version (proposal). Crystallises the direction discussed until
  then — the agent-native wedge, promoting the harness to a control and observation
  plane, the candidate platform and lib topics, and reclassifying the app boundary
  as reusable versus terminal — into a structural decision.
- 2026-07-04 Added the interim policy for open question #2 (the granularity of
  `kit`): stage by maturity, start narrow.
- 2026-07-04 Accepted. Open question #1 (how the shared `platform_types` is
  handled) was left to the skeleton implementation task.
- 2026-07-04 Skeleton implemented: `core/` created, `kit` defined, dependencies
  enforced in build.zig, `libs/paint` promoted, `libs/viz` separated. Open
  question #1 settled by publishing a type-only module; audio and types added to the
  initial kit; exceptions localised to harness→png and the app test root. Details in
  the section above.
- 2026-07-11 Added harness→dsp to `linkCoreException` (the FFT behind the audio
  digest's band, centroid and onset keys). The existing rms/peak/f0/silent/frames
  keys stayed bit-stable; the extension is additive and creates no new probe name.
- 2026-07-27 Exception inventory refreshed to the current seven
  `linkCoreException` / `linkAppException` edges in `build.zig` (platform→pixelops;
  pixie→pixelops; example_26→paint; `apps/patch/lofi.zig`→synth/dsp). Replaced the
  stale `apps/modular/patch.zig` path with `apps/patch/lofi.zig`. The R1–R8
  decisions themselves are unchanged.
- 2026-07-27 R7 gained a pointer to its one recorded exception (netsync in
  `core/control`, stated in ADR-014) and to the linking mechanism it relies on
  (ADR-013). R7 itself is unchanged: the exception is narrow, its grounds are
  written down, and the conditions that would end it are too.
- 2026-07-30 pixelops promoted into kit (`kit.pixelops`). The two
  `linkAppException` edges `apps/editor/apps/pixie → pixelops` and
  `apps/patch → pixelops` were removed; apps use the kit re-export. Remaining
  exception set is five edges (three `linkCoreException`, two
  `linkAppException`). `platform → pixelops` stays (core cannot link libs
  without an exception; needed for wasm present). The R1–R8 decisions themselves
  are unchanged.
