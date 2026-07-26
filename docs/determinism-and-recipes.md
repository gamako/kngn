# Seeds, determinism and recipes

## The seed and determinism convention

A shared convention so that a seed plus a sequence of commands (a recipe) reproduces a
piece completely. The framework does not reserve or interpret the action name (an
application registers it as an ordinary custom action). A recipe reproduces the seed by
replaying the command sequence.

1. **The action name** is `seed` everywhere. Its argument is one u64 as a decimal
   string.
2. **When it takes effect**: not immediately, but at **the next generation boundary**
   (for the modular engine, the next bar boundary). Quantising the seam of
   reproducibility to a boundary is what makes `seed` plus the replay of the following
   commands deterministic.
3. **What determinism means**: after `action seed N` is applied, the generated output is
   bit-deterministic for the same following command sequence and the same render chunk
   division.
4. **The semantics of applying a seed**: **initialise the generative state and restart**
   (in the modular engine, the mutation RNG, the background generation RNG, the pattern
   anchor, the sequencer position and the clock phase all return to the state derived
   from the seed). The unit of reproducibility is "this piece, from the beginning, with
   that seed" — not "the random numbers change from here on".
5. **Recording into a `CommandRecord`**: recorded as an ordinary recorded command (no
   dedicated field).

**What a reset covers**: applying a seed resets the **generative state** (patterns,
mutation, the generation RNG, the sequencer position, the clock phase). It does **not**
cover acoustic transients (reverb and delay tails, envelope followers, anti-click
ramps). Bit determinism of the output holds for a fresh start plus a replay of the
command sequence (the execution model of a recipe, below), and changing the seed while
running guarantees "the generative layer starts from the beginning". Transients are
non-generative state that decays, and a large buffer memset in a real-time callback is
avoided.

**Injecting the RNG**: an application concentrates this into a base seed (u64) plus
per-purpose derivation (splitmix64 style). The fixed seeds used for timbre (the
synthesised drums' `"KICK"`, `"HAT1"`, `"CLAP"`) exist to keep **the timbre identical**
and stay independent of the base seed (outside this convention).

**Hot path**: accepting and recording a seed happens only on an event. Reaching the
real-time side uses the existing lock-free handover (atomics and a Mailbox) plus a latch
or re-initialisation at a generation boundary. No allocation, locking or per-sample
branch is added to the real-time path.

## Recipes

A sequence of `CommandRecord`s (semantic commands) is saved to and replayed from a file,
so a piece can be reproduced and shared. The implementation is `libs/recipe`
(`kit.recipe`) plus the `recipe_save` and `recipe_replay` actions in the editor and the
modular engine.

### How this differs from a harness replay script

| | A harness replay script | A recipe |
|---|---|---|
| Content | Low-level input (`inject`, `step`, `snapshot`, `digest`, `action`) | Semantic commands (an action name and arguments only) |
| Purpose | Verification and reproduction tests (the headless harness) | Saving, sharing and reproducing a piece |
| Execution | The harness interprets the script | The application applies them one by one through `routeLocalAction` |
| Format | Text lines (`;` may separate) | A serde versioned container (magic `RCP1`, format_version 1) |

They do not replace one another. A harness script can call
`action recipe_replay <path>`, but a script is not a substitute for a recipe.

### The format

- **Header**: `app_name` (≤64 bytes) plus `format_version=1`
- **Entries**: a sequence of `{name, args}` — the `CommandLog`'s **kind=normal** entries
  written out **in seq order**
- Corruption (a bad CRC), a version mismatch and an over-long `app_name` are errors
- `recipe_replay` verifies `header.app_name` and, on a mismatch, reports
  `code=app_mismatch` (open it with the right application)

### Together with the seed convention

`seed` is saved and replayed as an ordinary normal command. **A seed plus the following
command sequence is the complete reproduction of a piece** (see the convention above).
In the modular engine, `action seed N` is part of the recipe, so a replay starts from
the same generative state.

### Current limits

- **Reverts are not supported**: `CommandLog` entries with kind=revert are not saved
  (reproducing "replay the undos too" depends on the wire path and is out of scope).
- **Nesting is rejected**: a `recipe_replay` during a `recipe_replay` is rejected with
  `code=nested_replay`.
- **A failure stops**: if an entry fails part-way it stops there and reports
  `code=replay_failed_at_N` (1-based).
- Remixing (partial application, substituting parameters) is future scope.
