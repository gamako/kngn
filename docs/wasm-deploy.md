# wasm deploy

How to gather the browser wasm artefacts into `zig-out/web/` and publish them to static hosting.

## Artefacts

Output of `zig build package-web` (`zig-out/web/`):

| File | Role | COOP/COEP |
|----------|------|-----------|
| `index.html` | Pixie entry | not required |
| `pixie.wasm` | Pixie wasm | not required |
| `synth.html` | Synth entry | **required** |
| `synth.wasm` | Synth wasm (shared memory) | **required** |
| `kngn.js` | Shared JS glue | load from an isolated page when using synth |
| `kngn-worklet.js` | AudioWorklet | load from an isolated page when using synth |
| `_headers` | Cloudflare Pages | synth header rules |
| `netlify.toml` | Netlify (may be copied to the repo root) | synth header rules |
| `serve-coop-coep.py` | Local COOP/COEP check | development |

### HTML / JS fetch paths

Dev (`web/`) and packaged (`zig-out/web/`) use the **same directory-relative paths**:

- `index.html` → `./kngn.js` → default `./pixie.wasm`
- `synth.html` (`data-wasm="synth.wasm"`) → `./kngn.js` → `./synth.wasm` + `./kngn-worklet.js`

`kngn.js` fetches wasm with `new URL("./<wasm>", import.meta.url)`, so every file above must sit in
the same directory.

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
| `package-web` | Compiles pixie + synth wasm and installs wasm + static assets into `zig-out/web/` | **yes** |
| `build-pixie-wasm` / `build-synth-wasm` | Compile-only (depends on the compile step only) | **no** |
| `-Dtarget=wasm32-wasi build-pixie` / `build-synth-wasm` | Same compile-only shape under a direct wasm target | **no** (unless the step is also pulled into an install graph) |

Use **`zig build package-web`** whenever you need distributable files under `zig-out/web/`.

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

### simd128 (WebAssembly SIMD)

Both pixie and synth wasm targets enable the **`simd128`** CPU feature so `libs/pixelops`
`@Vector(16, u8)` paths emit real SIMD instructions instead of scalar expansion.

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
