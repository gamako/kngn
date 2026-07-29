# Verification cookbook

[harness.md](harness.md) is a reference organised by mechanism: the
command grammar, the probe and action registries, replay versus live, and the
display-less mode. This document is organised by goal instead: "I changed
something — how do I check that it did what I meant?" Each recipe below is
four things — goal, minimal steps, pass condition, limits — and nothing else;
the command syntax, the probe API and the replay/live setup are one link away
in `docs/harness.md`, not repeated here.

Two operating rules that only exist in this document, because they are not a
harness mechanism but a habit: a change that touches drawing is not done until
someone has looked at a captured frame (see recipe 2), and a change that
touches audio is not done until `digest audio` has been read (see recipe 6).
Code review alone misses layout and mix problems that a screenshot or a level
meter catches immediately.

## The weak default: what `digest fb` can tell you

`digest fb` is a built-in, so it works on every application with no code
changes, but what it returns is thin:

```text
digest fb   # → fb 780x600 crc=031B2F95 top=[#20242C:35%,#4E4E4E:19%,#6A6A6A:19%]
```

Width, height, a whole-frame crc, and the three most common colours. There is
no notion of "which region changed" or "is this layer visible" in that payload
— those questions are only answerable once an application registers its own
probe (recipe 7 is the core of this document for exactly that reason). Until
then, the crc answers one question well: **does this frame match a value I
already know**, either a hard-coded one or the frame from a previous run.

Two things about that comparison are easy to get wrong:

- **The harness keeps no memory of a previous digest.** There is no hidden
  "compare to last frame" behaviour. A script that wants to compare two points
  in time must do one of: bake a known-good value into the script itself
  (`expect fb crc=<value>`); use `action diff_mark` where the application
  supports it (a pixie meta-operation that copies the current composite as the
  baseline for `digest diff`, registered in
  `apps/editor/apps/pixie/main.zig` and listed in `docs/harness.md`); or run
  the harness twice from outside and diff the two outputs yourself.
- **`expect` only reads top-level `key=value` tokens.** A probe's nested
  values (a canvas probe's `l0{v=..,crc=..,nz=..}`) or JSON (the stats
  probe's `{"frame":..}`) collapse into one token during parsing and are
  invisible to `=`/`!=`/`>`/`<` — only `contains` can reach inside them. See
  `docs/harness.md` for the exact grammar. The practical consequence for
  recipe 7: **write your own probe's payload as top-level keys**, or you lose
  the ability to threshold on it.

## Recipes

### 1. Did drawing happen at all

- **Goal**: confirm a change produced a visibly different frame (or, for an
  application with its own probe, a semantically different one).
- **Steps**: `digest fb` before and after the action under test, comparing
  the two crcs externally; or, if the application registers a probe, `digest
  <probe>` and look at a count such as pixie's canvas `nz=` (non-zero pixel
  count per layer).
- **Pass condition**: the crc (or the count) changed in the direction expected.
- **Limits**: a crc change says "something changed", not "the right thing
  changed" — see recipe 7 for that stronger claim.

### 2. Is the layout intact

- **Goal**: catch layout problems — an overlapping panel, a clipped edge, a
  misplaced widget — that a numeric probe does not encode at all.
- **Steps**: `snapshot fb /tmp/out.png`, then look at the file.
- **Pass condition**: a human (or a vision-capable reader) looking at the
  image agrees it is correct.
- **Limits**: this is not automatable by design, and no probe replaces it.
  Coordinates and pixel counts can be perfectly correct while the composition
  still looks wrong to a viewer — a panel that ends one pixel above the frame
  edge passes every bounds check and still looks broken. Do this recipe on
  every change that touches drawing, not only when something looks suspicious.

### 3. Does undo actually undo

- **Goal**: confirm that an undo (or redo) restores exact prior state, not
  merely "close" state.
- **Steps**: `digest fb` before the operation to get a baseline crc, perform
  the operation, undo it (`inject key_down Z cmd` or `action undo`), then
  `expect fb crc=<the baseline>`.
- **Pass condition**: the `expect` passes — bit-exact, not visually close.
- **Limits**: only checks pixel state. If the application also tracks
  non-pixel state (a selection, a tool setting, a cursor position), assert
  those separately through the relevant probe (pixie's `undo` probe reports
  `{"depth":N,"redo":M}` for the history stack itself).

### 4. Is the run deterministic

- **Goal**: confirm a replay script produces bit-identical output every time,
  which is what makes a script usable as a regression check in the first
  place.
- **Steps**: run the same script twice (`KNGN_HARNESS_SCRIPT=... zig build
  run` twice, or twice through `zig build run-pixie`), capturing `digest fb`
  each time.
- **Pass condition**: the two crcs are identical.
- **Limits**: this holds under the virtual clock (manual-clock replay) for
  applications with no real-time audio thread. An application with an audio
  thread (recipe 6's `run-patch` note) draws real-time visualisations into the
  same frame, so its `fb` crc is not expected to repeat — see recipe 6's
  limits.

### 5. Do backends agree

- **Goal**: confirm that switching the rendering backend (objc / swift /
  metal on macOS; x11 / wayland on Linux) does not change what is drawn.
- **Steps**: run the identical script against two backends (`zig build
  run-objc` and `zig build run-metal`, say) and compare `digest fb` crcs.
- **Pass condition**: identical crcs.
- **Limits**: this is already established as a fact for macOS backends
  (`fb` captures the manual-drawing CPU framebuffer, which is backend
  independent, and objc/metal crcs were measured bit-identical) — this recipe
  is how to re-check that fact after a change that could plausibly break it,
  not a claim that needs re-deriving from scratch each time.

### 6. Is there sound, and does it look right

- **Goal**: confirm audio output exists, is not silent when it should not be,
  and falls in the expected band/level range.
- **Steps**: `digest audio`, reading `silent`, `rms`, `peak`, `band_low` /
  `band_mid` / `band_high`, `centroid`, `onsets` and `lufs`. Use live harness
  (`KNGN_HARNESS_LISTEN=...`), because audio is driven by the real-time clock,
  not the virtual one, and a manual-clock replay would starve the audio
  thread of real time to render into.
- **Pass condition**: `silent=0` when sound is expected, and the numeric
  fields fall in the expected range (an `expect audio rms>0.01` style
  threshold, say).
- **Limits**: **an application with an audio thread does not have a
  reproducible `fb` crc** (`run-patch` is the example: a port-activity glow, a
  mini-scope, and a visualisation strip all draw from real-time state, so the
  frame differs run to run even under an identical script). Do not use `fb`
  crc as a regression oracle for such an application. The alternatives are: a
  region-limited pixel diff against a static part of the frame; a coarse box
  comparison once the visualisation has reached a warm, steady state; or
  falling back to a visual look plus `digest audio` for the parts that do
  vary.

### 7. Does the effect look "right" — turn the invariant into a probe

This is the recipe that turns an ad hoc, one-off check written in an external
script into something the harness can `expect` on directly, and it is why a
probe is worth adding even for a one-off investigation.

- **Goal**: assert a domain-specific property that no built-in probe encodes
  — brightness increasing monotonically over a sequence, a periodic pattern
  holding across frames, a histogram staying inside a band, and so on. An
  external agent doing this kind of check today typically writes a one-off
  script against a saved PNG; a probe removes the external script and the
  saved file, because `expect` can read the same number directly from the
  running process.
- **Steps**: have the application compute the invariant it already has the
  data for (it is reading its own canvas or its own DSP state, not
  reverse-engineering pixels from the outside), register a probe that reports
  it as a **top-level `key=value`** (per the limits section above, so
  `expect` can threshold on it), and drive it from a script.

  The shape, minimised to state + a digest callback + one registration call:

  ```zig
  const std = @import("std");
  // Stands in for `@import("platform")`: `core/platform.zig` re-exports this
  // verbatim as `platform.Probe` / `platform.registerProbe` (the same type,
  // the same function), so calling it here type-checks identically to
  // calling it through the facade.
  const platform = @import("harness");

  /// Application-owned invariant: row-to-row brightness variance of the last
  /// composited frame, updated once per frame by the application itself.
  const EffectMeter = struct {
      variance_permille: u32 = 0,
  };

  var effect_meter: EffectMeter = .{};

  fn effectMeterDigest(ctx: *anyopaque, buf: []u8) []const u8 {
      const self: *EffectMeter = @ptrCast(@alignCast(ctx));
      return std.fmt.bufPrint(buf, "variance={d}", .{self.variance_permille}) catch buf[0..0];
  }

  pub fn registerEffectMeter() void {
      platform.registerProbe(.{
          .name = "effect_meter",
          .ctx = &effect_meter,
          .ext = "txt",
          .digest = effectMeterDigest,
      });
  }
  ```

  A script exercising it, using the same command grammar as every other probe
  (see `docs/harness.md` for the grammar itself):

  ```text
  step 10                       # let the effect run for a few frames
  digest effect_meter           # → effect_meter variance=<some number>
  expect effect_meter variance>0
  quit
  ```

- **Pass condition**: `expect` passes — the invariant crossed the threshold
  the application itself is best placed to define, computed from data the
  application already has in hand rather than reconstructed from pixels
  outside it.
- **Limits**: this only reaches state the application chooses to expose. The
  callback runs on the main thread (never from a real-time callback), so
  reading real-time state such as synth voices needs the same best-effort,
  tear-tolerant approach as the built-in `voices`/`patch` probes — see
  `docs/harness.md`'s "Adding a custom probe" for the exact rules and limits
  (registry size, `desc` sanitisation, the non-interpretation invariant).

### 8. Diagnosing a failure: reading `code=` and `next=`

- **Goal**: when an `action` fails, decide the next script step
  programmatically instead of guessing from the message text.
- **Steps**: read the structured error appended to the failure line —
  `code=<c> next=<n>` — which an application attaches with
  `platform.setActionErrorDetail(...)` immediately before returning an error.
  Two worked examples from the editor: a failed `open` gives
  `code=file_not_found next=check path or use save first`; an out-of-range
  `select_layer` gives `code=index_out_of_range next=use add_layer or
  0..N-1`.
- **Pass condition**: not a pass/fail by itself — this is a decision aid. A
  script (or an agent driving live harness) branches on `code=` rather than
  re-parsing `next=`'s free-text sentence.
- **Limits**: the vocabulary of `code` and `next` belongs to the application;
  the harness never interprets it (only wire-framing rules apply — control
  characters are sanitised, `code` is capped at 64 bytes and `next` at 200).
  An action that never calls `setActionErrorDetail` fails with no `code=` and
  no `next=` at all, bit-identical to before that mechanism existed. Full wire
  format and sanitisation rules are in `docs/harness.md`.

## What this cookbook deliberately does not cover

**CI enforcement of bit-exact golden images is not part of this project's
verification approach**, and none of the recipes above should be read as a
step toward one. A fixed reference crc checked automatically on every commit
is brittle while the rendered output still changes often, and it fails for
the wrong reason as much as the right one. The intended use of every recipe
above is interactive and immediate — an agent or a developer runs the script,
reads the digest or the snapshot, and decides right there — not a background
gate that blocks on a stored expectation.
