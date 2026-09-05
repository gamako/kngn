# ADR-038: Each standalone child gate keeps its own cache and prefix

- Status: Accepted
- Date: 2026-09-05
- Category: Build

## Context

`check-examples-standalone` builds every sample in `examples/` as its own package,
by running a child `zig build` in each sample directory. The full sweep is 47 of
them, and it joins `-Dinstall-all=true`, so it dominates the wall clock of that
build. `addCheckedChildBuild` gives every child its own `--cache-dir` and its own
`--prefix`, both under the parent's cache root.

The obvious suspicion about the cost was the cache separation: the parent has
already compiled `platform`, `core` and the libraries, and each child compiles them
again. If the children shared one cache directory, the argument goes, they would
compile the shared code once between them.

The separation had also acquired a justification it does not support. The comment
read "Each child gets its own cache_subdir, so their build graphs never share
state", which reads as a correctness requirement, and it was in fact defended as one
— by pointing at the way a cache shared between two *different source trees* can
serve a stale hit. That situation is real, but it is not this one, and the comment
was doing no work as written.

## What sharing would buy

Measured on aarch64-macos with Zig 0.16.0, building `examples/30_sound_demo` as a
child package:

| Cache | Wall clock |
|---|---|
| Its own, cold | 27.9s |
| Shared, already warmed by `examples/05_text_rendering` | 25.5s |

On disk, two separate caches came to 42MB + 42MB against 78MB shared.

So sharing saves about 9% of the time and 7% of the space, and the reason it saves
so little is structural rather than accidental. Zig compiles an executable as one
compilation: two samples with different root modules do not share a compiled `kit`,
`gui` or `core`, whatever cache they are pointed at. What the children *can* share
is the Swift object and a couple of small library steps, and that is what the 9% is.
`--summary all` on one child accounts for it: 2s for the executable, 2s for the
`swiftc` invocation, 353ms for the native library.

The dominant cost of the gate was not the compilation but build configuration, which
no cache covers: of the 27.9s cold child build above, 22.4s was spent configuring.

## What the stale-hit mechanism needs, and what was measured here

A cache shared between two source trees can serve a stale hit. The mechanism has two
halves: the manifest key is derived from this invocation's inputs and arguments, and
a file the compiler discovered through `@import` is recorded in that manifest by
absolute path. When two trees produce the same key, the second tree hits the first
tree's manifest, and validation then opens the *first* tree's files. Edits in the
second tree are never read, and a broken source can pass a test.

Both halves are needed. The children are a different shape:

- Some pairs of children **do** produce the same key. The representative gate builds
  `examples/05_text_rendering`, `examples/26_appshell_demo` and
  `examples/30_sound_demo`, and the full sweep builds those same three again as
  separate invocations. Same name, same inputs, same arguments. A hit between them is
  correct: it is the same build of the same tree.
- Other pairs do not. Building `05` and then `30` into one cache directory was
  measured to grow the manifest count from 7 to 9, so `30` wrote its own manifests
  rather than reusing `05`'s.

Neither pair reproduces the shape that goes stale, because a `.path` dependency
resolves the parent to the same absolute path for every child: a recorded absolute
path points into the tree being edited, not into another one. Two fault injections
confirmed that a child in that configuration fails when it should. Each was run with
the target child never built successfully in that cache, so a pass could not be
explained by the child's own ordinary validation:

| Warmed by | Broken file | How it is recorded | Result of the target child's first build |
|---|---|---|---|
| `05` only | `examples/30_sound_demo/main.zig` | relative (a module root; the same string in both children) | fails, reporting `main.zig` |
| `05` only | `core/platform_macos.zig` (reached by `@import("platform_macos.zig")`) | absolute | fails, reporting the path inside the tree being edited |

These are observations about the pairs measured, not a general guarantee. In
particular, a child's root module is recorded relative to its own working directory,
so two children can carry the same path string while denoting different files; that
they did not collide here was measured, not derived. Nothing below rests on the
absence of stale hits: the decision would be the same either way, because it is made
on what sharing is worth.

## Decision

**`--prefix` stays separate.** Taking the full sweep alone, every sample installs a
distinct executable name. But the representative gate and the sweep build three of
the same samples as separate invocations, so a shared prefix would have them
overwrite each other's install output. A prefix per child invocation keeps those
apart.

**`--cache-dir` stays separate, as a choice rather than for correctness.** Nothing
measured here says sharing would go stale, and nothing says it would be fragile
either — Zig locks per manifest and expects a cache to be shared between processes.
The reason is simply that it does not pay: 9% of the time and 7% of the space, against
tying 47 children into one cache namespace, where no single gate's cache can be thrown
away and rebuilt on its own and nothing records which child wrote which entry. Stated
the other way round: were the saving large, the question of whether the mechanism above
can reach this configuration would have to be settled properly rather than sampled.

## Consequences

Each child pays a cold build of the code it shares with the parent and with its
siblings, and the caches add up on disk. That is accepted.

The comment on `addCheckedChildBuild` states the two contracts above rather than the
correctness claim it used to make. Anyone who reads "never share state" and concludes
that sharing would be unsafe is drawing the wrong boundary: the boundary that matters
is between trees, and it has not been shown to fall between children.
