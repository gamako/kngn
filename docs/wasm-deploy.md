# wasm デプロイ手順（TASK-73.4）

ブラウザ向け wasm 成果物を `zig-out/web/` に集約し、静的ホスティングへ配置する手順。

## 成果物

`zig build package-web` の出力（`zig-out/web/`）:

| ファイル | 用途 | COOP/COEP |
|----------|------|-----------|
| `index.html` | Pixie エントリ | 不要 |
| `pixie.wasm` | Pixie wasm | 不要 |
| `synth.html` | Synth エントリ | **必須** |
| `synth.wasm` | Synth wasm（shared memory） | **必須** |
| `vp.js` | 共通 JS glue | synth 利用時は隔離ページから読み込み |
| `vp-worklet.js` | AudioWorklet | synth 利用時は隔離ページから読み込み |
| `_headers` | Cloudflare Pages 用 | synth 向けヘッダ定義 |
| `netlify.toml` | Netlify 用（リポジトリ root にコピー可） | synth 向けヘッダ定義 |
| `serve-coop-coep.py` | ローカル COOP/COEP 検証用 | 開発用 |

### HTML / JS の fetch パス

開発時（`web/`）も配布時（`zig-out/web/`）も**同一ディレクトリ相対パス**:

- `index.html` → `./vp.js` → 既定 `./pixie.wasm`
- `synth.html`（`data-wasm="synth.wasm"`）→ `./vp.js` → `./synth.wasm` + `./vp-worklet.js`

`vp.js` は `new URL("./<wasm>", import.meta.url)` で wasm を取得するため、上記ファイルはすべて同じディレクトリに置く。

## ビルド

リポジトリ root で:

```bash
# 配布一式（推奨。native ターゲットから wasm を cross-compile）
zig build package-web

# 個別（native ターゲット時）
zig build build-pixie-wasm
zig build build-synth-wasm

# wasm ターゲット指定時（-Dtarget=wasm32-wasi）
zig build -Dtarget=wasm32-wasi package-web
zig build -Dtarget=wasm32-wasi build-pixie
zig build -Dtarget=wasm32-wasi build-synth-wasm
```

## ローカル検証

### Pixie（COOP/COEP 不要）

```bash
zig build package-web
cd zig-out/web
python3 -m http.server 8080
# http://127.0.0.1:8080/index.html
```

fetch パス smoke（別ターミナル）:

```bash
curl -sf -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/index.html
curl -sf -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/vp.js
curl -sf -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/pixie.wasm
```

いずれも `200` であること。

### Synth（COOP/COEP 必須）

SharedArrayBuffer + AudioWorklet のため **cross-origin isolation** が必要。

```bash
python3 zig-out/web/serve-coop-coep.py 8080
# http://127.0.0.1:8080/synth.html
```

リポジトリ内の `scripts/serve-web.py` も同様（引数で root を指定可）。

> 注: `serve-coop-coep.py` は**全レスポンス**（`index.html` 含む）に COOP/COEP/CORP を付与する。
> pixie も cross-origin isolated で配信されるが単独動作に支障はない。pixie を本番同等
> （ヘッダ無し）で検証したい場合は `python3 -m http.server` を使う。

### COOP/COEP の確認（DevTools）

1. ブラウザでページを開く
2. DevTools → Console で `crossOriginIsolated` を実行
3. **synth**: `true` であること
4. **pixie**: `false` でも動作する（隔離不要）

## 静的ホスティングへの配置

`zig-out/web/` の**中身**を publish directory としてアップロードする。

### Cloudflare Pages

1. `zig build package-web`
2. `zig-out/web/` を deploy root にする（または CI で `zig build package-web`）
3. `zig-out/web/_headers` が自動適用される（synth.html のみ COOP/COEP）

> **注意（実配置で踏んだ罠）**: Cloudflare Pages は `/synth.html` へのリクエストを自動で
> `308 /synth`（拡張子なし clean URL）へリダイレクトする。`_headers` のルールは**実際に
> 配信されるパス**に一致しないと適用されないため、`/synth.html` だけでなく **`/synth` にも
> 同じ COOP/COEP ルールを書く**必要がある（`web/deploy/_headers` は両方定義済み）。
> 片方だけだとブラウザが読むページ（`/synth`）にヘッダが付かず
> `crossOriginIsolated === false` になり synth が発音しない。デプロイ後は
> `curl -sI https://<project>.pages.dev/synth | grep -i cross-origin` で**リダイレクト後の
> パス**にヘッダが付くことを確認すること（`/synth.html` への curl だけでは見抜けない）。

### Netlify

1. リポジトリ root に `web/deploy/netlify.toml` をコピーするか、内容を既存設定にマージ
2. `publish = "zig-out/web"`、`command = "zig build package-web"` を設定
3. synth 向けヘッダは `[[headers]]` で付与

### GitHub Pages

- **Pixie のみ可**（`index.html` + `pixie.wasm` + `vp.js`）。カスタムレスポンスヘッダを設定できないため COOP/COEP 不可。
- **Synth は不可**（SharedArrayBuffer が必要）。代替として [coi-serviceworker](https://github.com/gzuidhof/coi-serviceworker) によるクライアント側の擬似隔離があるが、初回リロードが入る既知のハックであり、本リポジトリでは未同梱。
- 第一候補は Cloudflare Pages / Netlify 等、**レスポンスヘッダを設定できる**静的ホスト。

## .wasm の MIME タイプ

`WebAssembly.instantiateStreaming` は `Content-Type: application/wasm` を期待する。

| ホスト | 既定 |
|--------|------|
| `python3 -m http.server` | `.wasm` は `application/wasm`（3.7+） |
| Cloudflare Pages / Netlify | `_headers` / `netlify.toml` で明示 |
| GitHub Pages | 多くの場合 `application/wasm`（要確認。問題時は `instantiate` フォールバック） |

`vp.js` は streaming 失敗時に `compile` + `instantiate` へフォールバックするが、本番でも `application/wasm` を設定すること。

## 公開 URL での動作確認（AC#2）

アカウント作成・実 deploy は作業者のホスト選定後に実施。手順:

1. 上記ビルド → `zig-out/web/` をホストへ配置
2. Pixie 公開 URL で pen 描画・キー入力を目視確認
3. Synth 公開 URL で COOP/COEP 下の発音を確認（`crossOriginIsolated === true`）

ローカル検証までを本タスクの完了とし、実配置は申し送り。