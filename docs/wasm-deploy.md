# wasm deploy

How to gather the browser wasm artefacts into `zig-out/web/` and publish them to static hosting.

## Artefacts

Output of `zig build package-web` (`zig-out/web/`):

| File | Role | COOP/COEP |
|----------|------|-----------|
| `index.html` | Pixie entry | not required |
| `pixie.wasm` | Pixie wasm | not required |
| `pixie.single.html` | Pixie single-file package | not required |
| `synth.html` | Synth (shared audio) | **required** |
| `synth.wasm` | Synth wasm (shared memory) | **required** |
| `synth-postmessage.html` | Synth (postMessage audio) | not required |
| `synth_postmessage.wasm` | Synth wasm (non-shared) | not required |
| `synth.single.html` | Synth single-file (postMessage audio) | not required |
| `kngn.js` | Shared JS glue | — |
| `kngn-worklet.js` | AudioWorklet (shared + postMessage) | — |
| `_headers` | Cloudflare Pages | shared synth header rules |
| `netlify.toml` | Netlify (may be copied to the repo root) | shared synth header rules |
| `serve-coop-coep.py` | Local COOP/COEP check | development |

### HTML / JS fetch paths

- `index.html` → `data-wasm="pixie.wasm"` + `data-audio-transport="none"`
- `synth.html` → `data-wasm="synth.wasm"` + `data-audio-transport="worklet_shared"` (needs isolation)
- `synth-postmessage.html` → `data-wasm="synth_postmessage.wasm"` + `data-audio-transport="worklet_postmessage"`

Audio transport comes from `data-audio-transport` or embedded options; the glue does not guess from the app name.

### Audio transports

| Transport | Where render runs | SharedArrayBuffer | Typical use |
|---|---|---|---|
| `.none` | — | no | Pixie / silent apps |
| `.worklet_shared` | AudioWorklet (2nd wasm Instance) | **yes** (COOP/COEP) | Live keyboard synth |
| `.worklet_postmessage` | **main thread**, worklet plays ring | no | file:// / GitHub Pages |

**postMessage contract**: main-thread `kngn_audio_render` shares the rAF thread with drawing.
Heavy frames underrun audio. Queue = 8 blocks × 128 frames (~21 ms @ 48 kHz prefill);
refill when ≤4 blocks remain. Larger queue raises latency. Underruns surface on `#kngn-error`
(no silent fallback to `.none`).

### Delivery matrix (measured / designed)

| Delivery | `.none` | `.worklet_postmessage` | `.worklet_shared` | Latency |
|---|---|---|---|---|
| `file://` | single HTML OK | single HTML OK; **user gesture** for AudioContext | **no** (no headers) | none: n/a; postMessage: ~24–30 ms |
| GitHub Pages | single HTML OK | single HTML OK | **no** (no custom headers) | postMessage: ~24–30 ms |
| Cloudflare / Netlify | single HTML OK | single HTML OK | multi-file OK with headers; single HTML = **build error** | shared: low ms; postMessage: ~24–30 ms |
| `serve-coop-coep.py` | OK | OK | multi-file OK | shared: low ms |

It is not “single file vs SharedArrayBuffer” that conflict — it is **hosts that cannot set
COOP/COEP** vs shared audio. `.worklet_shared` × `single_html` is a hard build error.

### Single-file HTML (`package-web-single`)

Produces `pixie.single.html` and `synth.single.html` (postMessage audio + embedded worklet).

Marker `<!-- kngn:inline-module -->` before the glue script; packer embeds wasm base64 + glue
(+ worklet source for postMessage). Self-containment is markup-scanned (not raw `grep` for `fetch`).

Host-only packer unit tests: `zig build test-pack-single-html` (also in `zig build test`).

### Audio measurement notes

Browser wasm has no harness `digest audio` probe. Verification uses the same field names via an
optional `?audio_probe=1` path: an `AnalyserNode` after the worklet, then
`fetch('/report?d=transport=…&silent=…&rms=…&peak=…')` on plain HTTP. Values are **not** required
to match native `digest audio` bit-for-bit.

Diagnostic `?audio_probe=1` injects one note through `kngn_push_key` (same path as the DOM
keyboard) and reports AnalyserNode levels (not a harness probe). Example access-log lines:

```text
transport=worklet_postmessage&silent=0&rms=0.070515&peak=0.171650&sr=48000&n=4096&probe_note=KeyA
transport=worklet_shared&silent=0&rms=0.069330&peak=0.171650&sr=48000&n=4096&probe_note=KeyA
```

Native harness with a held note (`inject key_down A`):

```text
digest audio rms=0.0770 peak=0.2147 silent=0 frames=4096
```

### Single-file sizes (ReleaseSmall default, aarch64-macos)

| Artefact | raw bytes |
|---|---:|
| `pixie.wasm` | ~1.16 MiB |
| `pixie.single.html` | ~1.52 MiB |
| `synth.wasm` (shared) | ~425 KiB |
| `synth_postmessage.wasm` | ~425 KiB |
| `synth.single.html` (postMessage) | ~626 KiB |

`file://` uses raw HTML size (no gzip).

## Build

> **The wasm targets are not covered by `zig build -Dinstall-all=true` or by `zig build test`.**
> A change can therefore break the wasm build without any of the usual gates noticing — which is
> exactly what happened to `build-pixie-wasm` (the harness stub drifted behind the platform facade,
> and `std.c.getenv` is unavailable without libc). **Run the two steps below whenever you touch
> `core/control/`, the platform facade, `libs/appshell`, or anything a wasm root imports.**

### Optimize mode

- **Default for wasm** (`zig build package-web` and `-Dtarget=wasm32-wasi` without `-Doptimize`):
  **ReleaseSmall**. Native apps still default to Debug.
- **Explicit wins**: `-Doptimize=Debug` / `ReleaseFast` / `ReleaseSafe` / `ReleaseSmall`, and
  `--release=fast` / `safe` / `small`, always override the default.

### Install behaviour of individual wasm build steps

| Step | What it does | Writes `zig-out/web/`? |
|------|----------------|------------------------|
| `package-web` | Compiles pixie + synth wasm and installs multi-file wasm + static assets | **yes** |
| `package-web-single` | Packs `pixie.single.html` and `synth.single.html` (embedded wasm + glue; synth uses postMessage audio) | **yes** (single HTML only) |
| `build-pixie-wasm` / `build-synth-wasm` | Compile-only (depends on the compile step only) | **no** |
| `-Dtarget=wasm32-wasi build-pixie` / `build-synth-wasm` | Same compile-only shape under a direct wasm target | **no** (unless the step is also pulled into an install graph) |

Use **`zig build package-web`** for the multi-file deploy root, and **`zig build package-web-single`**
when you need a self-contained `file://` HTML.

### Binary size by optimize (measured)

Sizes below are for the **final wasm artefacts after `simd128` was enabled** on both pixie and
synth targets (`zig build -Doptimize=… package-web` on aarch64-macos, 2026-07-30).
KB values are `file_size / 1024` floored.

| optimize | pixie.wasm | synth.wasm | notes |
|----------|----------:|----------:|-------|
| Debug | 5811 KB | 3538 KB | explicit `-Doptimize=Debug` |
| ReleaseFast | 4111 KB | 1669 KB | explicit `-Doptimize=ReleaseFast` |
| ReleaseSmall | 1129 KB | 425 KB | default for `package-web` when `-Doptimize` is omitted |

Pre-`simd128` reference (2026-07-29 macOS, `package-web`): Debug 5865 / 3549 KB,
ReleaseFast 4088 / 1672 KB, ReleaseSmall 1133 / 426 KB.

**What ReleaseSmall costs, measured** (same setup as the `simd128` measurement below —
Chrome 150 headless, aarch64-macos, 2026-07-30, per-frame work inside the
`requestAnimationFrame` callback, both builds with `simd128`):

| Canvas | ReleaseSmall | ReleaseFast |
|---|---|---|
| 2560x1440 | 4.34 / 4.34 ms median | **4.27 / 4.235 ms** median |
| 780x600 | 1.375 ms median, 2.165 ms p95 | **1.295 ms** median, **1.89 ms** p95 |

ReleaseSmall costs roughly **2% of per-frame CPU at 2560x1440 and 6% at 780x600** against
ReleaseFast, and neither build dropped a frame on a 120Hz display (the `requestAnimationFrame`
interval stayed at 8.33ms in every run, against 4.3ms of work). It is the default anyway,
because 3.6x smaller delivery matters more than that margin for a build whose point is being
downloadable. A deployment that needs the margin passes `-Doptimize=ReleaseFast` explicitly.

### simd128 (WebAssembly SIMD)

Both pixie and synth wasm targets enable the **`simd128`** CPU feature so `libs/pixelops`
`@Vector(16, u8)` paths emit real SIMD instructions instead of scalar expansion.

**What this bought, measured** (Chrome 150 headless, aarch64-macos, 2026-07-30, pixie
`ReleaseSmall`, 400 frames per run with the first 60 discarded, timing the work inside the
`requestAnimationFrame` callback):

| Canvas | Without `simd128` (median per run) | With `simd128` (median per run) |
|---|---|---|
| 780x600 | 1.29 / 1.445 / 1.40 / 1.335 ms | 1.53 / 1.31 / 1.48 / 1.415 ms |
| 2560x1440 | 4.355 / 4.345 ms | 4.325 / 4.34 ms |

**No difference that can be distinguished from run-to-run variation**, at either size — the
ordering even flips between runs at the smaller size. Enlarging the canvas 7.9x does not
separate them either, so the per-frame cost is dominated by something other than the
vectorisable pixel loops. The instructions are genuinely in the binary (`wasm-objdump -d`
counts 1190 `v128.*`, 192 `i8x16.*`, 412 `i16x8.*` and 164 `i32x4.*` in `pixie.wasm`), and
the feature stays enabled for that reason: the shared implementation the performance rules
mandate is no longer silently scalar on this target. Do not cite `simd128` as a frame-rate
improvement.

**Browser baseline** (ships without a polyfill):

| Browser | Minimum version |
|---------|-----------------|
| Chrome | 91+ |
| Firefox | 89+ |
| Safari | 16.4+ |

Older Safari (and other engines without SIMD) are **out of support** for these wasm builds.
Synth still also needs `atomics` + `bulk_memory` (SharedArrayBuffer / AudioWorklet); that is
unchanged and still requires COOP/COEP isolation (see below).

From the repository root:

```bash
# Full package (recommended; cross-compiles wasm from a native target)
# Default optimize is ReleaseSmall when -Doptimize is omitted.
zig build package-web

# Individual compile-only steps (do NOT install into zig-out/web/)
zig build build-pixie-wasm
zig build build-synth-wasm

# When targeting wasm (-Dtarget=wasm32-wasi); same ReleaseSmall default
zig build -Dtarget=wasm32-wasi package-web
zig build -Dtarget=wasm32-wasi build-pixie
zig build -Dtarget=wasm32-wasi build-synth-wasm
```

## Local verification

### Pixie (COOP/COEP not required)

```bash
zig build package-web
cd zig-out/web
python3 -m http.server 8080
# http://127.0.0.1:8080/index.html
```

Fetch-path smoke (another terminal):

```bash
curl -sf -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/index.html
curl -sf -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/kngn.js
curl -sf -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/pixie.wasm
```

Every response must be `200`.

> **A fetch-path smoke and a passing `zig build package-web` are not enough.** Open
> `http://127.0.0.1:8080/index.html` (pixie) in a browser and check both DevTools →
> Console (no `App.init failed`, no uncaught error) and the canvas itself (a visible
> UI, not a black screen). A regression here can compile clean and pass every fetch
> check while still failing only inside the wasm runtime — see the note under
> "Build" above.

### Synth (COOP/COEP required)

SharedArrayBuffer + AudioWorklet need **cross-origin isolation**.

```bash
python3 zig-out/web/serve-coop-coep.py 8080
# http://127.0.0.1:8080/synth.html
```

`scripts/serve-web.py` in the repository does the same (optional root argument).

> Note: `serve-coop-coep.py` attaches COOP/COEP/CORP to **every** response (including
> `index.html`). Pixie still runs under cross-origin isolation; that does not hurt standalone
> use. To verify pixie the way production serves it (no headers), use `python3 -m http.server`.

### Checking COOP/COEP (DevTools)

1. Open the page in a browser
2. In DevTools → Console, evaluate `crossOriginIsolated`
3. **synth**: must be `true`
4. **pixie**: may be `false` (isolation not required)

## Publishing to static hosting

Upload the **contents** of `zig-out/web/` as the publish directory.

### Cloudflare Pages

1. `zig build package-web`
2. Use `zig-out/web/` as the deploy root (or run `zig build package-web` in CI)
3. `zig-out/web/_headers` is applied automatically (COOP/COEP only for synth)

> **Caveat seen in a real deploy**: Cloudflare Pages redirects `/synth.html` to `308 /synth`
> (extensionless clean URL). `_headers` rules must match the **path that is actually served**,
> so write the same COOP/COEP rules for **`/synth` as well as `/synth.html`**
> (`web/deploy/_headers` already defines both). With only one of them, the page the browser
> reads (`/synth`) has no headers, `crossOriginIsolated === false`, and synth makes no sound.
> After deploy, confirm headers on the **post-redirect** path:
> `curl -sI https://<project>.pages.dev/synth | grep -i cross-origin`
> (curling `/synth.html` alone will not catch this).

### Netlify

1. Copy `web/deploy/netlify.toml` to the repository root, or merge its contents into an existing config
2. Set `publish = "zig-out/web"` and `command = "zig build package-web"`
3. Synth headers come from `[[headers]]`

### GitHub Pages

- **Pixie only** (`index.html` + `pixie.wasm` + `kngn.js`). Custom response headers cannot be set, so COOP/COEP is unavailable.
- **Synth is not possible** (SharedArrayBuffer required). A client-side fake isolation via
  [coi-serviceworker](https://github.com/gzuidhof/coi-serviceworker) exists but needs a first-load
  reload and is **not** bundled here.
- Prefer Cloudflare Pages / Netlify or any static host that **can set response headers**.

## `.wasm` MIME type

`WebAssembly.instantiateStreaming` expects `Content-Type: application/wasm`.

| Host | Default |
|--------|------|
| `python3 -m http.server` | `.wasm` → `application/wasm` (3.7+) |
| Cloudflare Pages / Netlify | set explicitly in `_headers` / `netlify.toml` |
| GitHub Pages | often `application/wasm` (verify; fall back to `instantiate` if needed) |

`kngn.js` falls back to `compile` + `instantiate` when streaming fails, but production should still
serve `application/wasm`.

## Public-URL smoke check

After choosing a host and deploying:

1. Build as above and upload `zig-out/web/`
2. On the Pixie URL, visually confirm pen drawing and key input
3. On the Synth URL, confirm sound under COOP/COEP (`crossOriginIsolated === true`)

Local verification is enough to validate the package; real hosting is a separate hand-off.
