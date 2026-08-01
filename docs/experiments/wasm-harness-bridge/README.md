# Driving the harness in a browser

`drive.py` runs harness commands against a kngn wasm application in a headless browser and
prints the responses. It exists because the observation plane is only useful if something
outside the page can reach it: an agent verifying `digest audio` on the shared-memory synth,
or `digest window` at a device pixel ratio the machine running the build does not have.

What the bridge is, and what it cannot do, is in
[../../harness.md](../../harness.md) under "wasm: the host bridge". This file is the how-to.

## Prerequisites

The observation plane is not in a normal wasm build. Package it in:

```bash
zig build package-web -Dwasm-harness=true
```

`drive.py` refuses to start if the requested module is missing from `zig-out/web`, but it
cannot tell a module built with the bridge from one built without — that shows up as the
page reporting `the module exports no harness bridge`.

Chrome or Chromium must be installed. Nothing connects to a debugging port.

## Running

```bash
python3 docs/experiments/wasm-harness-bridge/drive.py -c 'step 10
digest window'

python3 docs/experiments/wasm-harness-bridge/drive.py --script /tmp/window.txt
```

Each `-c` and each `--script` is one **batch**: the whole text goes to the harness as one
request, the way the TCP transport receives one connection's worth of commands, and the
response is printed under a `# batch N` header. Batches run in order, each waiting for the
previous one's response, so `step` and `await` inside a batch behave exactly as they do
over TCP.

Useful flags:

| Flag | Meaning |
|---|---|
| `--wasm` | which module to boot (`pixie.wasm`, `synth.wasm`, `synth_postmessage.wasm`) |
| `--audio-transport` | `none`, `worklet_shared` (needs the isolation the server already sends), `worklet_postmessage` |
| `--device-scale-factor` | the browser's `devicePixelRatio` for the run. **Launch-time only** — a browser cannot change it afterwards |
| `--capture-frames` | let the harness copy every framebuffer, which `digest fb` needs and which costs a frame-sized memcpy per frame |
| `--size` | the canvas CSS box, `WxH` |
| `--console-log` | write the browser's stderr, which carries the application's own output, to a file |
| `--json` | one JSON object per batch instead of the human format |

The exit status is non-zero if the page failed to boot, a batch timed out, or a batch
reported an error. A `expect`/`assert` failure is **not** an exit status: it is an `fail`
line in the response, the same as over TCP, so read the output.

## Page commands

A batch beginning with `@` is handled by the driver page rather than the harness. They
exist for the things that are properties of the *host*, which the command language has no
way to reach:

| Command | Meaning |
|---|---|
| `@resize <w> <h> <dpr>` | drive the platform resize seam — the call `ResizeObserver` and the DPR watcher make. It exercises how the backend commits a ratio change, and therefore `scale_epoch`. It is **not** a change of the browser's own device pixel ratio |
| `@env` | report `devicePixelRatio`, the canvas CSS and backing-store sizes, and whether the page is cross-origin isolated |

The distinction in `@resize` matters when reading a result. A run launched with
`--device-scale-factor=2` and asserting `scale=2.0000` is evidence that the backend follows
the browser. A `@resize` asserting `epoch=1` is evidence that the backend commits a ratio
change correctly. Neither substitutes for the other.

## Worked examples

The device pixel ratio the browser really reports, then a ratio change through the seam:

```bash
python3 docs/experiments/wasm-harness-bridge/drive.py --device-scale-factor=2 \
  -c '@env' \
  -c 'step 10
digest window
assert window scale=2.0000
assert window epoch=0' \
  -c '@resize 640 480 1.5' \
  -c 'step 5
digest window
assert window scale=1.5000
assert window epoch=1'
```

Audio out of the shared-memory synth, whose worklet runs a second instance over the same
memory — so a non-silent digest here is also evidence that the tap the real-time thread
writes and the digest reads is in fact shared:

```bash
python3 docs/experiments/wasm-harness-bridge/drive.py \
  --wasm synth.wasm --audio-transport worklet_shared --size 1080x520 \
  -c 'step 30
digest audio' \
  -c 'inject key_down A
step 90
digest audio
assert audio silent=0'
```

## Things that quietly invalidate a run

- **A backgrounded headless window stops running animation frames**, and the harness only
  reaches a frame boundary inside one. `drive.py` passes the three flags that prevent it;
  without them a batch simply times out.
- **An `AudioContext` waits for a user gesture** an unattended run cannot make.
  `--autoplay-policy=no-user-gesture-required` is passed for the same reason.
- **`--device-scale-factor` is launch-time.** Asserting a ratio change within one run needs
  `@resize`, which is a different claim — see above.
- **`digest fb` without `--capture-frames`** reads a framebuffer that was deliberately not
  copied. The frame copy is off by default so that observing a run does not change its cost.
- **The framebuffer follows the element's client box**, so `--size` larger than the window
  silently measures a smaller one. `@env` reports what the canvas actually got.
