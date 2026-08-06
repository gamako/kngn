# ADR-018: Build-time selection of wasm audio transport

- Status: Accepted
- Date: 2026-07-30
- Scope: how a browser wasm app chooses among no audio, shared-memory
  AudioWorklet, and main-thread postMessage audio. The real-time callback
  contract is [015](015_real-time-audio-contract.md); deploy packaging is
  [docs/wasm-deploy.md](../wasm-deploy.md).

## Context

kngn ships browser builds of apps that either need no sound (e.g. pixie) or a
keyboard synthesizer (synth). Hosting environments split into two incompatible
classes:

1. **Can set COOP/COEP** (self-hosted static with headers, Cloudflare/Netlify
   config, `serve-coop-coep.py`) → `crossOriginIsolated` and
   `SharedArrayBuffer` are available.
2. **Cannot** (`file://`, GitHub Pages, many pastebins) → shared memory is
   unavailable; any build that *requires* shared linear memory fails at
   instantiate or at AudioWorklet setup.

The Zig audio export `kngn_audio_render` is transport-neutral: both the worklet
and the main thread may call it. The question is which **wasm module memory
layout and JS transport** the package selects at **build time**.

## Decision

Each wasm app's package spec carries an explicit audio transport enum:

| Value | Wasm memory | Where `kngn_audio_render` runs | Headers |
|---|---|---|---|
| `none` | non-shared | never | none |
| `worklet_shared` | `shared: true`, import memory, atomics | AudioWorklet second Instance | **COOP/COEP required** |
| `worklet_postmessage` | non-shared | **main thread**; worklet plays a fixed ring fed by transferable `postMessage` | not required |

Root package outputs (current in-tree layout):

- Multi-file **shared** synth → `synth.html` + `synth.wasm`
- Multi-file **postMessage** synth → `synth-postmessage.html` + `synth_postmessage.wasm`
- Single-file postMessage synth → `synth.single.html` (embedded wasm + glue + worklet source)
- Pixie remains `none` (also `pixie.single.html` for `file://`)

`.worklet_shared` combined with `single_html` is a **build error**: a single file
cannot attach COOP/COEP response headers.

## Why one binary cannot serve both transports at runtime

A module linked with shared linear memory expects `WebAssembly.Memory({ shared:
true })` (and typically `import_memory`). Instantiating that module without a
shared memory fails. Shared memory in the browser requires
`SharedArrayBuffer`, which requires cross-origin isolation. Therefore a
**shared-memory build cannot be the fallback** for hosts that lack headers.

Conversely, a non-shared build cannot host the dual-Instance shared worklet
path that the low-latency keyboard design relies on. Transport is therefore a
**package/build choice**, not a silent runtime switch.

## Rejected alternatives

**Runtime fallback (try shared, then postMessage, then silence).** Rejected:
users would get a quieter or glitchier instrument without a clear reason, and
deploy docs could not state a hard requirement. Failures for the chosen
transport are **visible** (`#kngn-error`); they do not degrade in place.

**Always postMessage.** Rejected for interactive keyboard playing: the render
runs on the main thread next to rAF. Queue settings (8 × 128 frames @ 48 kHz ≈
21 ms of pure buffer, ~24–30 ms effective with control latency and scheduler
jitter) are acceptable for demos and for hosts without headers, but not for the
primary “play the PC keyboard” product path.

**Always shared.** Rejected for distribution: `file://` and GitHub Pages cannot
set COOP/COEP, so the primary synth package would be undeliverable there.

## Measurements

PostMessage queue (design and verification):

| Parameter | Value |
|---|---|
| Block size | 128 frames × 2 channels |
| Prefill | 8 blocks |
| Refill when | ≤ 4 blocks in flight |
| Buffer latency @ 48 kHz | 8 × 128 / 48000 ≈ **21.3 ms** |
| Effective (design estimate) | **~24–30 ms** including control delay and jitter |

AC-style levels (same field names as harness `digest audio`; browser uses an
`AnalyserNode` after the worklet — **not** a literal harness probe):

| Path | silent | rms | peak |
|---|---|---|---|
| Native harness, held note (`inject key_down A`) | 0 | ~0.077 | ~0.215 |
| Browser postMessage, `audio_probe=1` (KeyA via `kngn_push_key`) | 0 | ~0.071 | ~0.172 |
| Browser shared (COOP/COEP), same probe | 0 | ~0.069 | ~0.172 |

Idle browser probe without a note reports silence; the probe mode therefore
injects one note through the same export path as the DOM keyboard. Ordinary
page loads (no `audio_probe` query) never inject notes.

## Consequences

- Package authors pick transport per app and per delivery story; two synth
  artefacts (shared multi-file vs postMessage multi/single) are intentional.
- Single-HTML packaging embeds worklet source for postMessage only; shared
  single-HTML is refused at configure time.
- PostMessage underruns surface as diagnostics when the main thread is busy;
  deepening the queue trades latency for robustness. The contract is documented
  in `docs/wasm-deploy.md` and in JS comments next to the queue constants.
- Zig `core/audio_web.zig` stays transport-neutral: one `kngn_audio_render`
  ABI, no per-transport Zig branches.

## Related

- [docs/wasm-deploy.md](../wasm-deploy.md) — deploy matrix and artefact names
- [ADR-015](015_real-time-audio-contract.md) — RT callback region
- [ADR-027](027_wasm-microphone-capture.md) — browser mic input on the shared-memory Worklet path
