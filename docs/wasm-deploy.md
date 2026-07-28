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

From the repository root:

```bash
# Full package (recommended; cross-compiles wasm from a native target)
zig build package-web

# Individual (native target)
zig build build-pixie-wasm
zig build build-synth-wasm

# When targeting wasm (-Dtarget=wasm32-wasi)
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
