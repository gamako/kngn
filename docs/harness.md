# The headless verification harness

A way for an agent to inspect what an application actually produced.
`core/control/harness.zig` is interposed on four hooks in `core/platform.zig` (the
facade) — `pollEvents`, `nextEvent`, `present` and `getTime` — so that input
injection, frame capture and a virtual clock work **without modifying the
application**. With none of its environment variables set, every hook passes
straight through and behaviour is identical to before.

Phases, all implemented:

- **File replay** plus the built-in `fb` probe (framebuffer → PNG, or a one-line
  digest) and the virtual clock.
- **Live control** (TCP loopback plus the `kngn ctl` CLI), the built-in
  `audio` and `stats` probes, and record → replay.
- **A custom probe registry**: an application opts in with
  `platform.registerProbe(...)` (the editor registers twelve, `canvas` and `undo` and
  `tool` among them; the synth registers `voices` and `patch`). See "Adding a custom
  probe".
- **Fully display-less** operation: `KNGN_HEADLESS=1` makes `platform.init()` skip
  the native `backend.init()` entirely and select `platform_null` at runtime. A
  script or a listener is optional, so a display-less run needs neither. See
  "Fully display-less" below.
  - The `fb` probe captures **the CPU framebuffer of the manual drawing API**, so
    it is backend-independent: `snapshot fb` works on objc, swift and metal alike
    (metal supplies the same CPU buffer, and the framebuffer crcs were measured
    bit-identical to objc).
- **Out of scope**: reading back Metal's GPU drawable (the composited surface after
  drawing). `snapshot fb` and `digest fb` already work in a metal build through the
  CPU framebuffer above, with crcs measured bit-identical to objc, and a readback
  would add nothing to what the harness is for — verifying what the application
  drew.
- **An action registry**: the write and operate counterpart to a probe (read). An
  application opts in with `platform.registerAction(...)` and it is invoked as
  `action <name> [args...]`. See "Adding a custom action".
- **capabilities, an introspection probe**: the built-in `capabilities` probe lists
  the registered probes and actions as one line of JSON
  (`digest capabilities` / `snapshot capabilities`). See the command language below.

## The command language (identical for file replay and live)

One command per line, separated by a newline **or `;`**; `#` starts a comment. The
syntax is **the same in file replay and live**:

```text
inject key_down A          # key_down/key_up <KEY> [modifiers...] (a KeyCode name, case-insensitive: A / SPACE / ESCAPE / LEFT / 0)
inject key_down S cmd shift # zero or more of shift/ctrl/alt/cmd at the end (any order, case-insensitive), e.g. Cmd+Shift+S
inject mouse_move 100 120  # mouse_move <x> <y> [modifiers...]
inject mouse_down left alt # mouse_down/up <left|right|middle> [modifiers...]
inject scroll 0 -3 ctrl    # scroll <dx> <dy> [modifiers...]
step 5                     # manual/replay: drive 5 frames / free-run: a frame barrier of 5 presents
await fb crc=8702DD71 60   # await <probe> <key><op><value> [timeout]  (timeout is a frame budget; 0 = compare once)
await audio silent=0       # free-run holds the connection and waits for the app; manual drives frames and waits
snapshot fb  /tmp/out.png  # save the most recent presented frame as PNG (default $KNGN_HARNESS_OUT/frame_<n>.png)
snapshot audio /tmp/a.wav  # save the most recent audio tap as PCM16 WAV (default audio_<n>.wav)
snapshot stats /tmp/s.json # save stats as JSON (default stats_<n>.json)
digest fb                  # fb <w>x<h> crc=<hex> top=[#RRGGBB:NN%,...]
digest audio               # audio rms=<f> peak=<f> f0=<Hz> silent=<0|1> frames=<n> band_low/mid/high=<0..1> centroid=<Hz> onsets=<n> lufs=<f>
digest stats               # {"frame":..,"virtual_fps":60.0,"mouse_move_merge_count":..,"mouse_scroll_merge_count":..,"event_drop_count":..,"modal_blocked_injections":..} (one line of JSON)
digest capabilities        # {"probes":[{"name":..,"ext":..,"snapshot":bool,"digest":bool,"desc":..(,"args":[...])},...],"actions":[{"name":..,"desc":..(,"args":[...])},...]}
snapshot capabilities /tmp/c.json # save capabilities as JSON (default capabilities_<n>.json)
action <name> [args...]    # run a high-level operation the app registered (the write counterpart to a probe's read)
expect fb crc=8702DD71     # expect <probe> <key><op><value>  (op ∈ = != > <). Compared against top-level k=v in the digest payload
expect audio silent=0      # match → ok, mismatch → fail. Replay accumulates failures and exits non-zero; live returns an ok/fail line
assert fb crc=8702DD71     # evaluated like expect. In replay it exits non-zero immediately on failure (fail-fast abort)
expect fb contains crc=87  # contains <substr>: a substring match against the one-line digest (use this for nested values and JSON)
quit                       # terminate (EOF also terminates)
```

### Built-in probes (owned by the framework)

`fb` (framebuffer → PNG/digest), `audio` (output tapped by the `core/audio.zig`
facade → WAV/digest), `stats` (`EventStats` plus the virtual fps → JSON), and
`capabilities` (introspection, below).

`audio` measures **the most recent window (latest wins)**, so "what is playing right
now" can be asserted (silence is `silent=1`, `f0=0`). Its keys are additive and the
existing ones stay bit-stable: `band_low`/`band_mid`/`band_high` (normalised energy
ratios summing to ≈1), `centroid` in Hz, `onsets` (peaks in the spectral flux), and
`lufs` (LUFS: BS.1770 K-weighted momentary over 400ms, with a silence floor of -99.0).
No second probe name (`audio2` and the like) is created; keys are added to `audio`.
Analysis runs only when a digest is requested, so the real-time path is unchanged.
`virtual_fps` is a fixed value derived from the virtual clock (≈60) and is **not**
real performance. `modal_blocked_injections` counts injected events that a registered
probe's `input_blocker` reported as consumed by application state (see "Blocked
injection warnings" below). Existing keys are unchanged; this key is additive.

### capabilities (the introspection probe)

`digest capabilities` and `snapshot capabilities [path]` (ext=json) list the
registered probes and actions as one line of JSON: the seven built-ins
(`fb`, `audio`, `stats`, `capabilities` itself, `capture`, `gamepad`, `midi`, each
with a fixed description), then custom probes in registration order, then actions in
registration order. Each probe entry carries `name`, `ext`, `snapshot` (bool),
`digest` (bool) and `desc`; each action entry carries `name` and `desc`. `args` can
be added **by adding a field only** (below). **The invariant that the framework does
not interpret content is preserved**: it transcribes the registry's metadata, never
calls a callback, and does not even validate the vocabulary of `kind`. It runs only
on an event or a connection (not per frame, not per sample) and is not a hot path.

- **Argument signatures**: `registerAction` and `registerProbe` accept
  `args: ?[]const ArgSpec = null` (optional, backward compatible), where
  `ArgSpec = {name, kind, min?, max?, values, pattern, optional, variadic, desc}`.
  **null means unspecified** (no `args` field in the JSON, bit-identical to before);
  **an empty slice means `"args":[]`** (explicitly no arguments — distinguished from
  null so a consumer can tell them apart). Only when `args != null` is
  `"args":[{"name":..,"kind":..(,"min":..)(,"max":..)(,"values":[..])(,"pattern":..)(,"optional":true)(,"variadic":true)(,"desc":..)},...]`
  appended, **emitting non-default values only**. `kind` is a string (recommended:
  `int`, `float`, `string`, `bool`, `enum`, `path`; an application may use its own,
  and interpretation belongs to the consumer).
- **The contract of always returning valid JSON**: the registry limits (16 custom
  probes, 48 actions, 7 built-ins) and the sanitisation of `desc` and `args` at
  registration time (below) mean this normally cannot happen, but as a fail-safe an
  entry that does not fit, or whose `name` or `ext` contains a character that would
  break the JSON, ends the listing there and appends `"truncated":true` (the field is
  omitted entirely when it would be false). For compatibility with future clients,
  fields are only ever added, never changed.
- It is the entry point for a client to discover "what can be observed and operated
  on in this application right now".

### Custom probes (owned by the application, opt-in)

A name the application registered with `platform.registerProbe(...)`.
`snapshot <name>` and `digest <name>` then work with the same syntax and output as a
built-in. Currently:

- The editor: `canvas` (a flat transparent composited PNG /
  `WxH layers=N selected=.. comp=XXXXXXXX lN{v=..,op=..,crc=..,nz=..,name=..}`),
  `undo` (`{"depth":N,"redo":M}`), `tool` (`tool=Pen color=#RRGGBB`), `cursor`,
  `history`, `diff` (`changed=N bbox=x0,y0,x1,y1 from=#RRGGBB to=#RRGGBB`; the
  baseline comes from `action diff_mark` or is initialised on the first digest — so
  the first `digest diff` writes as well as reads; when `changed=0` it reads
  `bbox=none from=none to=none`), `palette`
  (`colors=N used=M top=[#RRGGBB:NN%,...]` — the palette size, the number of unique
  colours in the composite, and the top four), plus `timeline`, `panels`, `menu`,
  `appshell` and `presence`. Twelve in total.
  - `appshell` payload:
    `dirty=0|1 path=... confirm=none|close|new|open recent=N recent0=... recovery=pending|none modal=recovery|confirmation|size|none autosave=0|1 netsync=0|1 title=... geom=WxH pos=...`.
    `modal=` is the top-level modal kind (priority: recovery → confirmation → size → none).
    `recovery=` and `confirm=` stay for compatibility.
- The synth: `voices`
  (`{"active":N,"capacity":16,"voices":[{"note":..,"stage":".."}]}`) and `patch`
  (the current patch as JSON).

**The framework does not interpret the contents of a custom probe** (it only routes
raw bytes and a one-line digest).

### Where a digest goes

Replay writes `[harness] digest <probe> <payload>` to stderr; live returns
`<probe> <payload>` in the connection response with no prefix. A snapshot is saved to
a file, and live returns that path.

### Modifier tokens on inject

Adding zero or more of `shift`, `ctrl`, `alt`, `cmd` after the required arguments of
`inject` sets them in that `KeyEvent` or `MouseEvent`'s `modifiers` (any order,
case-insensitive). It
works on every path: key_down/up, mouse_move/down/up and scroll. For example
`inject key_down S cmd` (Cmd+S), `inject key_down Z cmd` (undo),
`inject mouse_down left alt`. **A single unknown token produces a warning and the
event is not injected at all** (fail-fast, so a typo in a modifier name is never
swallowed). With no modifiers, the set is empty as before.

### expect and assert (the assertion layer)

Compares an expected value against a probe's **one-line digest payload**, so a script
can turn a result into an **exit code or a response** — the multiplier that lets an
agent iterate without looking at anything.

- Syntax: `expect <probe> <key><op><value>` / `assert <probe> <key><op><value>` /
  `expect <probe> contains <substr>`. A second token of `digest`
  (`expect digest <probe> ...`) is accepted as an alias and skipped. The operators are
  the minimal set `=`, `!=`, `>`, `<`, plus `contains`.
- **Comparison rules**: `>` and `<` require both sides to parse as f64 (failure to
  parse fails the comparison). For `=` and `!=`, if both sides parse as f64 it is a
  numeric comparison (`rms=0.5` ≈ `0.5000`); otherwise it is an exact string match
  (which is how crc hex works). The practice for a crc is to **copy and paste the
  eight digits** from the digest output, because passing a shortened value for an
  all-digit crc could pass by numeric equality.
- **Keys are extracted from top-level `k=v` pairs only** (space separated). Nested
  values (the canvas probe's `l0{v=..,crc=..,nz=..}`) and JSON (the stats probe's
  `{"frame":..}`) glue into a single token and are not picked up as keys — use
  `contains` for those (the substring is one token and cannot contain a space).
- **Result and exit code**: in replay, stderr carries
  `[harness] expect ok/FAILED line N: <expr> [actual=<payload|reason>]`. An `expect`
  failure is accumulated and **exits non-zero at termination if there is at least one**
  (whether termination came from EOF, `quit` or the window closing); an `assert`
  failure **exits non-zero immediately** (a fail-fast abort — `exit(1)` skips cleanup,
  which is debug behaviour). In live, a response line of `ok` or
  `fail <probe> <expr> [actual=..]` is returned and **the process does not terminate**
  (so in live, expect and assert behave identically). `kngn ctl` scans **every
  response line** and exits non-zero itself if any starts with `fail ` (warnings such
  as `error:` do not make it non-zero).
- **Fail-fast, so a typo is never swallowed**: an unknown probe name, malformed syntax
  (a missing operator, an empty key or value, a bare `!`), surplus tokens, a missing
  key, and an undetermined payload (before the first framebuffer present) all count as
  failures.
- Record → replay symmetry, and being a no-op when the harness is disabled, are
  unchanged (this rides on the existing mechanism).

### action (the high-level counterpart to a probe)

A name the application registered with `platform.registerAction(...)`, invoked as
`action <name> [args...]`. It is the write and operate path, letting an application's
semantic commands run directly without depending on UI coordinates — the foundation
for a shared command unit across undo and networking.

- Syntax: everything after `action <name>` on the line is passed to the callback as
  `args` **as raw text** (trimmed only, never re-tokenised). **`;` and a newline are
  command separators and therefore cannot appear in `args`** (the text is limited to
  one command fragment).
- The callback is `run(ctx, args, buf) anyerror![]const u8` (`buf` follows the same
  1024-byte contract as `digest`, and the returned line contains no newline).
  **The framework interprets neither `args` nor the meaning of the return value** (the
  same invariant as a probe; not emitting anything past a newline is wire framing
  protection, not interpretation). The callback runs **on the main thread** (inside
  `pollGate`, at a step or frame boundary) and is never called from a real-time
  callback (synchronising application state shared with the real-time thread is the
  application's responsibility).
- **Result and exit code**: an unknown action, a missing name, and an error from
  `run()` all count as failures and ride the same `expect_failures` counter as
  `expect`/`assert` (recorded, then execution continues; there is no immediate-abort
  variant like `assert`). Replay exits non-zero at termination if at least one was
  recorded (whether from EOF, `quit` or the window closing); live does not terminate
  the process and returns the result in the response line only.
- **Wire format**: replay stderr is `[harness] action <name> ok <msg>` on success and
  `[harness] action <name> FAILED <msg>` on failure. A live response is
  `<name> <msg>` on success (**bare, in the same style as a digest's
  `<probe> <payload>`**) and `fail <name> <msg>` on failure (**with the `fail `
  prefix, so `kngn ctl`'s line scan makes it exit non-zero**). If a callback
  mistakenly returns several lines, `msg` is cut at the first `\r` or `\n` before
  emitting (wire framing protection, not interpretation).
- **Structured errors (`code` + `suggested_next_action`, opt-in)**: a wire extension
  letting an application attach a self-recovery hint to a failure.
  - **API**: `platform.setActionErrorDetail(code, suggested_next_action)` (main thread
    only; a module variable of `action_registry`). A handler calls it **immediately
    before returning an error**. It is cleared at the start of every `dispatch` (and
    before a direct run), so not calling it leaves the failure line **bit-identical to
    before** (no ` code=` and no ` next=` at all).
  - **Sanitisation**: wire framing protection only (the meaning is not interpreted).
    Control characters and `DEL` become `_`, with limits of `code=64B` and
    `next=200B`. Because `code` is meant to be one token, ASCII whitespace also
    becomes `_`; `next` may contain spaces (`next=` is the final field and takes the
    rest of the line).
  - **Wire (appended to the failure line only)**: live is
    `fail <name> <msg> code=<c> next=<n>` and replay is
    `[harness] action <name> FAILED <msg> code=<c> next=<n>`. **The leading `fail ` is
    unchanged**, so `kngn ctl`'s prefix scan and non-zero exit keep working
    untouched. The netsync REJECT reason and the capabilities JSON are outside this
    extension.
  - **Worked examples in the editor**: a failed `open` (`ReadFailed` or `FileNotFound`)
    gives `code=file_not_found` and
    `next=check path or use save first`; an `OutOfRange` from `select_layer` gives
    `code=index_out_of_range` and `next=use add_layer or 0..N-1`.
  - **The non-interpretation invariant**: the vocabulary of `code` and the suggestion
    belong to the application. The framework is transparent (framing protection only,
    as with `desc`). The MCP bridge reads this wire directly as a tool error.
- **Registration**: `registerAction` is a no-op when the harness is disabled,
  overwrites a duplicate name, rejects an empty name and a name containing whitespace,
  `;` or a newline, and skips when the registry is full (48 entries). There are no
  built-in actions, so there is no notion of a reserved name either (the framework
  interprets nothing about an action's content).
- **The editor's registered actions** (the write counterparts to its `canvas`, `undo`,
  `tool`, `cursor`, `history`, `diff` and `palette` probes): `undo`, `redo`, `clear`,
  `add_layer`, `delete_layer`, `select_layer <idx>`,
  `set_layer_visible <idx> <0|1>`, `set_layer_opacity <idx> <0-255>`,
  `move_layer <+1|-1>`, `set_color <RRGGBB>` (per-peer local),
  `set_tool <pen|eraser|brush|bezier|select|fill>` (per-peer local),
  `stroke [layer=#<id>] [tool=...] [color=...] [size=...] [opacity=...] [hardness=...] <x0> <y0> [x y ...]`
  (canvas coordinates; an odd count fails; the relay wire bakes in the origin context
  and a stable layer id), `save <path>`, `open <path>`, `recipe_save <path>`,
  `recipe_replay <path>`, `diff_mark` (copy the current composite as the baseline for
  `digest diff`; no arguments, and as a meta operation it is not recorded in the
  command log), `replace_color [#<id>|<index>] <from> <to>` (the layer reference is
  optional and defaults to the selected layer; during a netsync session `#id` is
  required and the policy is `.relay`; two hex values alone stays compatible with
  before and is undoable), `palette_ramp <seed_hex> <n>` (an OKLCH lightness ramp,
  n=2..32, replacing the whole palette, `.reject_when_synced`),
  `palette_from_png <path>` (frequency extraction from a PNG replacing the whole
  palette, up to 64, `.reject_when_synced`), and `palette_set <hex...>` (1..64 colours
  replacing the whole palette, `.reject_when_synced`). The palette actions are
  document state (the `.pix` PLTE chunk, and part of a netsync SYNC), so a local change
  during a session is rejected. **`.pix` compatibility** is backward only: a v4 reader
  reads v2 and v3 (a v3 reader rejects schema > 3, so an older reader cannot read v4).
  Every action goes through the same `App.do*` methods as the UI and the keyboard, so
  the undo path matches (what `action stroke` drew can be undone with
  `inject key_down Z cmd`). The implementation is
  `apps/editor/apps/pixie/main.zig` (dispatch plus `registerActions`) and `actions.zig`
  (a pure parser, testable without App or kit). The detailed action-to-undo-command
  table is in the doc comment of that section of `main.zig`.

## Using it: replay (the file transport)

```bash
cat > /tmp/script.txt <<'EOF'
inject key_down A; step 2; digest fb; snapshot fb /tmp/out.png
quit
EOF
KNGN_HARNESS_SCRIPT=/tmp/script.txt KNGN_HARNESS_OUT=/tmp zig build run            # the main program (examples, synth and so on work unmodified too)
# → read /tmp/*.png to look at it, and assert on the digest
#   (re-running the same script produces bit-identical PNGs — it is deterministic)

zig build test-harness   # unit tests (parser, execution model, virtual clock, audio analysis, WAV, stats). No display needed, backend independent
```

## Using it: live (TCP loopback plus the driver CLI)

Start the application in the background and use `kngn ctl` for one connection
per request per response. State stays in the process.

```bash
zig build kngn                                   # build zig-out/bin/kngn once (a plain zig build includes it)
KNGN_HARNESS_LISTEN= KNGN_HARNESS_PORT_FILE=/tmp/kngn.port KNGN_HARNESS_OUT=/tmp \
  KNGN_HARNESS_RECORD=/tmp/live.txt zig build run-synth &        # background (the ephemeral port is written to /tmp/kngn.port)
# For a fixed port use KNGN_HARNESS_LISTEN=<n>. The port also appears on stderr.
# For the old step-driven behaviour, add KNGN_HARNESS_MANUAL_CLOCK=1.
scripts/kngn ctl --port-file /tmp/kngn.port 'inject key_down A; step 5; digest fb'   # → returns fb ... on stdout
scripts/kngn ctl --port-file /tmp/kngn.port 'digest audio'                          # → audio rms=.. f0=.. ..
scripts/kngn ctl --port-file /tmp/kngn.port 'snapshot fb /tmp/out.png'              # → /tmp/out.png
scripts/kngn ctl --port-file /tmp/kngn.port 'quit'                                  # terminate the application
# Record → replay symmetry: replaying the log above reproduces the same command sequence
KNGN_HARNESS_SCRIPT=/tmp/live.txt KNGN_HARNESS_OUT=/tmp zig build run-synth
```

| Environment variable | Role |
|---|---|
| `KNGN_HARNESS_SCRIPT=<file>` | enables **replay** (the file transport; always a manual clock) |
| `KNGN_HARNESS_LISTEN[=port]` | enables **listening** (TCP loopback; no value, empty or `0` means ephemeral, a positive value is a fixed port; free-run by default) |
| `KNGN_HARNESS_MANUAL_CLOCK=1` | subordinate to LISTEN: makes the socket a manual clock, equivalent to the old step-driven behaviour (blocking) |
| `KNGN_HARNESS_PORT_FILE=<file>` | where the chosen port is written (default `$KNGN_HARNESS_OUT/harness.port`) |
| `KNGN_HARNESS_RECORD=<file>` | append the commands received while listening (replayable via `KNGN_HARNESS_SCRIPT`) |
| `KNGN_HARNESS_OUT=<dir>` | the default directory for an omitted snapshot path and for the port file |
| `KNGN_HEADLESS=1` | **fully display-less**: `platform.init` selects the null backend. A script or listener is optional (it can run alone). See below |

### App-data isolation for unattended runs

`libs/appshell` redirects the default application-data directory to a per-process
temporary path when a run is unattended. Explicit `KNGN_APPSHELL_DIR` always wins
(automatic isolation does not apply). See ADR-017.

| env state | isolate |
|---|---:|
| `KNGN_HARNESS_SCRIPT` present | yes |
| `KNGN_HEADLESS` is `1` | yes |
| `KNGN_HARNESS_LISTEN` present, `KNGN_HEADLESS` unset | no |
| `KNGN_HARNESS_MANUAL_CLOCK` alone | no |
| copilot env only | no |

The temporary path is `<temp>/kngn-appdata-<pid>-<nonce>/<app_name>`, where `<temp>` is
`TEMP` / `TMP` / `%LOCALAPPDATA%\Temp` on Windows and `TMPDIR` or `/tmp` elsewhere. It is
created once per process and logged once to stderr. It is not deleted on exit.

### Blocked injection warnings

When an application registers a probe with `input_blocker` and that callback returns a
static label for an injected event, the harness treats the event as consumed by
application state — not only a full-absorb modal (`"recovery"`, `"confirmation"`), but
also event-specific sinks such as size-dialog confirm keys (`"size"`) or inline text
edit (`"text_edit"`). The callback may inspect the event so the answer can depend on
kind and payload.

The harness then:

- still delivers the event unchanged;
- increments `modal_blocked_injections` in `digest stats`;
- prints
  `[harness] warning: an injected event was consumed by "<label>"`
  to stderr (and, in live, a `warning: ...` response line).

The same label while it stays non-null warns once; after a null return, a later non-null
label warns again. This does not affect `expect_failures` or exit codes.

The counter says "application state took this event", not "this was a mistake": a script that
deliberately drives a modal (clicking its buttons through `inject`) increments it too.
Read it as "injection went to a consuming state instead of the main surface" and decide from the
script's intent — a non-zero count on a script that never meant to touch that state is the
signal worth chasing.

> Specifying SCRIPT and LISTEN together is an error and disables the harness (one
> transport per process). MANUAL_CLOCK alone, without LISTEN, is also invalid. With
> none of them set, every hook passes straight through.

> **Free-run LISTEN is not supported on Windows (a known limitation)**: the
> non-blocking accept of free-run currently exists only as a POSIX `poll(0)`
> implementation, and the Windows branch always reports `not_ready` (a silent no-op
> that never accepts a connection — the port file and the listen log appear, but
> `kngn ctl` cannot connect). **On Windows, add `KNGN_HARNESS_MANUAL_CLOCK=1`** to use the
> old step-driven path (a blocking accept). macOS and Linux are fine with the free-run
> default.

## Fully display-less

With `KNGN_HEADLESS=1`, `platform.init()` does not call the native `backend.init()` at
all (no X11 or Wayland display connection, and no macOS WindowServer connection). It
selects `core/platform_null.zig` at runtime, where the `Window` owns a primary CPU
framebuffer (a `w*h` buffer of `u32`). The harness merely takes an observation copy in
`onLock` and `onPresent` (it holds no primary buffer). A script or listener is
optional, so a display-less run with no transport at all is possible.
**No per-backend offscreen implementation (an X11 Pixmap and the like) is used.**

- **Replay and listening work as they are over plain SSH** (with no `DISPLAY` and no
  `WAYLAND_DISPLAY`), because there is no display connection.
- **Audio runs without a real device too**: `core/audio_null.zig` (pure Zig,
  OS-independent) drives the render callback with the same push-thread pattern as the
  Linux and Windows backends (a real-time pull thread) and feeds
  `harness.onAudioSamples()`, so the `audio` probe works with no real sink.
- **Replay is no longer rate-limited by sleeping**: `platform.framePaceUntil(deadline)`
  is the frame wait in a main loop. Under a manual clock it is a complete no-op (it
  reads no OS clock and touches no learning state); the virtual clock and `pollGate`
  decide frame progress. Two audio examples deliberately use bare `platform.sleep`
  instead, because audio pull is driven by the real clock and a no-op wait would leave
  `digest audio` reading a silent window: `examples/30_sound_demo` and
  `examples/38_minigame`. The three-second sleep in `examples/15_audio_tone` is the
  application's lifetime itself and is out of scope.
- **The framebuffer crc is bit-identical to a non-headless run** (measured; headless
  changes nothing about what is drawn).
- A known limit: an audio-only application that never calls `platform.init()` (such as
  `examples/15_audio_tone`) cannot interpret `KNGN_HEADLESS`, because the decision is
  made in `platform.init()`. That said, the harness assumes a frame loop
  (`window.pollEvents()`), and an application without a window could never be driven by
  a replay script in the first place (there is no synchronisation point corresponding
  to `step`), so there is no real harm.
- Verified on hardware (2026-07-04): on **Linux (Ubuntu, plain SSH over a VPN)** the
  x11 and wayland builds are green, headless replay works over plain SSH with
  `DISPLAY` and `WAYLAND_DISPLAY` unset (the framebuffer crc is bit-identical to
  macOS), and `audio_null` produces sound with no sink present (`digest audio` gives
  f0 ≈ 262Hz, `silent=0`). On **Windows hardware** the full gdi and d3d11 builds are
  green, and the pure Zig `test-harness` and `test-audio-null` compile and pass (the
  facade type change was confirmed to compile on the Windows backend; runtime headless
  is OS-independent and was proven on macOS and Linux).

## Adding a custom probe

An application exposes internal state as a probe, opt-in. **No probe-specific code is
added to the framework** (`core/control/harness.zig`) — the invariant is that it does
not parse content. Steps:

1. In the application (which already has `@import("platform")`), write the probe
   callbacks:
   - `digest: fn(ctx: *anyopaque, buf: []u8) []const u8` — write one line of text into
     `buf` (at most 1024B) and return it (no newline).
   - `snapshot: fn(ctx: *anyopaque, allocator) anyerror![]u8` — return a raw byte
     sequence allocated with `allocator` (the harness writes it to a file and **frees it
     with the same allocator**). May be null.
   - `ctx` is a pointer to application state (`*App`, say), recovered inside the
     callback with `@ptrCast(@alignCast(ctx))`.
2. Register after `platform.init()` and before the main loop:
   ```zig
   platform.registerProbe(.{ .name = "canvas", .ctx = &app, .ext = "png",
       .snapshot = canvasSnapshot, .digest = canvasDigest });
   ```
3. That is all: `snapshot canvas [path]` and `digest canvas` now work in both replay
   and live.

Rules and limits:

- **A snapshot is raw bytes, a digest is one line; images are PNG and structured data
  is JSON or text** (the same rules as the built-ins).
- `fb`, `audio`, `stats` and `capabilities` are reserved names (registration is
  rejected). A custom probe with a duplicate name overwrites. The registry limit is 16.
- `registerProbe` is **a no-op when the harness is disabled** (its environment
  variables unset), so it never affects a normal run and can always be called.
- Reading state touched by the audio real-time thread (the synth's `voices` and
  `patch`) is a best-effort snapshot that may tear. **Do not add synchronisation,
  allocation or locking to the real-time path.**
- **`desc` (the description used by the capabilities listing; optional) is sanitised at
  registration**: a `desc` containing `"`, `\` or an ASCII control character (tab, NUL
  and so on), or longer than 200 bytes, produces a warning and becomes the empty string
  (registration itself still succeeds; only `desc` is dropped). **The capabilities JSON
  embeds `desc` without escaping it**, so these forbidden characters are wire framing
  protection, not interpretation of meaning.
- **`args` (optional) is sanitised the same way**: the same forbidden-character rule
  plus length limits apply to each `ArgSpec`'s string fields (name and kind 32B, each
  value 64B, pattern 100B, desc 200B). **On violation it warns and drops `args`
  entirely to null** (the same fail-safe shape as blanking `desc`; registration still
  succeeds). The framework does not interpret the meaning of `kind`.
- Worked examples: the editor's `canvas`, `undo` and `tool`
  (`apps/editor/apps/pixie/main.zig`), and the synth's `voices` and `patch`
  (`apps/synth/main.zig`).

## Adding a custom action

An application exposes a high-level internal operation as an action, opt-in. The
registration steps mirror a probe's (read), except that **the write callback returns
success or failure**. **No action-specific code is added to the framework** (the
non-parsing invariant is the same as for a probe). Steps:

1. In the application, write the action callback:
   - `run: fn(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8` —
     take `args` (the rest of the line after `action <name>` as raw text, trimmed and
     never re-tokenised), change state, and write one line of result into `buf` (at most
     1024B) and return it (no newline; the same contract as `Probe.digest`).
     Returning an error is recorded as a `run()` failure.
   - `ctx` is a pointer to application state, recovered with
     `@ptrCast(@alignCast(ctx))`.
2. Register after `platform.init()` and before the main loop:
   ```zig
   platform.registerAction(.{ .name = "undo", .ctx = &app, .run = appUndo });
   ```
3. That is all: `action undo [args...]` now works in both replay and live.

Rules and limits:

- **`args` passes through as raw text (the framework does not interpret it), but it
  cannot contain `;` or a newline** (they are command separators for `nextLine()`, so
  the text is limited to one command fragment).
- **Name rules**: an empty name, or one containing whitespace, `;` or a newline, is
  rejected (it could not be invoked in the command language anyway). A duplicate custom
  name overwrites. The registry limit is 48. There are no reserved names (no built-in
  actions exist).
- `registerAction` is **a no-op when the harness is disabled**, so it never affects a
  normal run and can always be called.
- **The callback runs on the main thread** (inside `pollGate`, at a step or frame
  boundary). It is never called from a real-time callback. If the callback touches
  application state shared with the real-time thread, synchronising it is the
  application's responsibility (the same rule as a probe's digest and snapshot
  callbacks).
- **Failures**: an unknown action, a missing name and an error from `run()` are recorded
  on the same `expect_failures` counter as `expect`/`assert` (recorded, then execution
  continues; there is no immediate-abort variant). The detailed wire format is in the
  action section of the command language above.
- **Structured errors (opt-in)**: calling
  `platform.setActionErrorDetail(code, suggested_next_action)` immediately before
  returning an error appends ` code=<c> next=<n>` to the failure line (bit-identical to
  before when not called). The vocabulary belongs to the application and the framework
  does not interpret it. Details in the action section above.
- No built-in actions are created. Registering actions on the application side happens
  in whichever task adopts them.
- **`desc` (optional) is sanitised by the same rule as a probe's**: containing `"`, `\`
  or an ASCII control character, or exceeding 200 bytes, warns and becomes the empty
  string (registration still succeeds).
- **`args` (optional) is sanitised by the same rule as a probe's**: a forbidden
  character or a length violation in name, kind, values, pattern or desc warns and drops
  `args` to null (registration still succeeds; null, meaning `args` is omitted from the
  JSON, is distinguished from an empty slice, meaning `"args":[]`). The editor attaches
  a signature to every action it registers (`stroke` takes a variadic coordinate list,
  `set_tool` is an enum, `set_color` is a hex pattern, the path actions are paths).

## The execution model

- Anything that is not a step (inject, snapshot, digest, action, and an `await` that
  succeeds immediately) runs immediately. `step N` in **manual and replay** makes
  `pollEvents` return true N times to drive frames; in **free-run** it is a barrier on
  `frame_index >= X+N` that waits for the application to present. `await` re-evaluates
  the same predicate as `expect` within a frame budget (a timeout of 0 means compare
  once). While listening in free-run, the application keeps running even with no
  commands outstanding, and an empty drain is a single `poll(0)` on the listener.
  Under **manual LISTEN** (`KNGN_HARNESS_MANUAL_CLOCK=1`), it blocks on accepting and
  reading the next connection, as before. With **a real display plus manual**, the
  native `pollEvents()` is pumped at a short interval through the facade even while
  waiting. **Free-run does not use `NativePump`** (to avoid polling twice).
  **Headless** does not pass a pump callback at all, since nothing is connected to a
  compositor.
- **The virtual clock**: only under a manual clock is `getTime()` equal to
  `frame_index/60`. Free-run uses the backend's real time.
- **Limits**: creating a real window is required only when `KNGN_HEADLESS` is unset (a
  display is needed: usually fine on macOS, Xvfb or a real session on Linux).
  **`KNGN_HEADLESS=1` is fully display-less** (see above). `audio` depends on real time
  on the real-time thread, so a bit-identical digest across record → replay is not
  guaranteed (`fb` is bit-deterministic under the manual virtual clock, and equally so
  headless — the framebuffer crc was measured bit-identical between headless and
  non-headless). **But an application with audio (the modular and patch runs) has a
  non-deterministic framebuffer crc too**: port-activity glow, the mini scopes and the
  visualisation strip all draw from real-time state, and consecutive runs of the same
  program were measured with differing crcs (2026-07-15). So do not use the framebuffer
  crc as a regression oracle there. Instead: (a) compare pixels within a limited region
  (decode the PNG and compare an area), (b) compare macro box snapshots bit-exactly
  with a warm cache, or (c) read a `snapshot fb` and look at it — and judge the sound
  with `digest audio` (silent, rms, band). For an application without audio (the
  editor) the framebuffer crc stays bit-deterministic as before. Capturing `fb` goes
  through the CPU framebuffer, so **objc, swift and metal all work** (the framebuffer
  crc of objc and metal was measured bit-identical). Reading back Metal's GPU drawable
  is out of scope (see above).
- **The driver is a single `std.Io.net` implementation** shared by macOS, Linux and
  Windows (`kngn` is installed unconditionally, with no OS gate; running it on Windows
  is untested). `scripts/kngn` is a thin wrapper that execs `zig-out/bin/kngn`
  directly, so it does not pollute the response on stdout.

## kngn mcp (the MCP server)

A stdio JSON-RPC adapter that attaches as one client of the harness's live TCP and
generates MCP tools dynamically from capabilities (the application is unmodified).

```bash
zig build kngn                    # → zig-out/bin/kngn
# with the application started headless and listening:
KNGN_HEADLESS=1 KNGN_HARNESS_LISTEN= KNGN_HARNESS_PORT_FILE=/tmp/kngn.port zig build run-pixie &
zig-out/bin/kngn mcp --port-file /tmp/kngn.port
# or scripts/kngn mcp --port-file /tmp/kngn.port
```

- **Arguments**: `--port` and `--port-file` (the same precedence as `kngn ctl`, plus the
  environment variables `KNGN_HARNESS_LISTEN` for a positive value and
  `KNGN_HARNESS_PORT_FILE`), plus `--out <dir>` for where snapshots go (default
  `$TMPDIR/kngn-mcp-<port>`; made absolute and created at startup).
- **At startup** it takes `digest capabilities` once and fails to start if
  `"truncated":true`. The tool table is fixed from then on (it does not follow an
  application restart).
- **MCP**: protocolVersion `2025-06-18` fixed; an initialize → notifications/initialized
  gate; tools/list, tools/call and ping; stdout carries JSON-RPC only (logs go to
  stderr).
- **Tools**: a probe becomes `digest_<name>` and `snapshot_<name>` (with no path
  argument — kngn mcp injects an absolute path under `--out`); an action becomes
  `<name>` (or `a_<name>` on a collision).
- **Verification**: `zig build test-mcp` (unit tests of the pure functions).
