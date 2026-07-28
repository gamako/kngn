# KNGN（顕現）

**AI が、自分の作ったものを見られる。ネイティブアプリの土台。**

[![Zig 0.16](https://img.shields.io/badge/zig-0.16.0-f7a41d)](https://ziglang.org/)
[![platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux%20%7C%20Windows-blue)](docs/build.md)
[![zig package deps](https://img.shields.io/badge/zig%20package%20deps-0-brightgreen)](build.zig.zon)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

<!-- TODO: ヒーロー画像。
     「AI が pixie で線を 1 本引いた」だけでは絵として弱いので、題材から別途考える。
     harness で headless 撮影できる（KNGN_HEADLESS=1 + snapshot fb）ので、
     決まればスクリプト 1 本で撮れる。 -->

エージェントは Web アプリなら自分の仕事を確認できます。DOM という既製の観測対象があり、
ヘッドレスブラウザもスクリーンショットも揃っている。ネイティブアプリにはそれがありません。
レイアウトが崩れていても、文字が見切れていても気づけない。**同じエージェントが、出力先次第で、
自分の書いた GUI を見られたり見られなかったりする。**

手段が皆無なわけではありません。スクリーンショットも、アクセシビリティ API も、computer-use も
あります。ただしどれもディスプレイか実セッションが要り、遅く、隔離と再現が重い。

**KNGN はそこを埋めます。** Zig でネイティブアプリを作り、ディスプレイなしでその出力を観測・
操作するための基盤です。macOS / Linux / Windows で動き、**同じ環境・同じビルド・同じ初期状態・
同じ入力なら同じピクセルが出ます**。同梱のピクセルエディタで、ヘッドレス検証 1 サイクルが 0.1 秒。

**pixie は 2.6 MB の単一バイナリ** · **Zig パッケージ依存ゼロ** · **Zig 0.16** ·
macOS (objc/swift/metal) / Linux (x11/wayland) / Windows (gdi/d3d11)

土台はネイティブウィンドウを開いてピクセルを直接書くためのプリミティブだけで、その上に
GUI・フォント・シンセ・ピクセルエディタが任意で乗ります。ヘッドレス検証ハーネスが platform 層に
組み込まれているので、**アプリ側のコードを 1 行も変えずに**入力を注入し、描画されたフレームを
PNG で取り出せます。

*これは [README.md](README.md) の日本語版です。英語版が正になります。*

## 30 秒で見る「エージェントが描いて、自分で確かめる」

同梱のピクセルエディタ `pixie` を、ディスプレイなしで起動し、線を引かせ、結果を PNG で受け取ります。

```bash
cat > /tmp/script.txt <<'EOF'
action set_tool pen
action set_color FF0066
action stroke 10 10 40 40 70 20
step 2
digest canvas
snapshot fb /tmp/out.png
quit
EOF

KNGN_APPSHELL_DIR=/tmp/kngn-demo KNGN_HEADLESS=1 KNGN_HARNESS_SCRIPT=/tmp/script.txt zig build run-pixie
# → /tmp/out.png に描画結果。digest canvas の 1 行はそのまま assert に使える
#   KNGN_APPSHELL_DIR でアプリ状態を隔離しているので、同じビルドなら PNG はビット単位で再現する
```

`set_tool` と `KNGN_APPSHELL_DIR` は決定性のためです。前者はツール状態を、後者は保存された
ウィンドウサイズやパネル配置を固定します。どちらも省くと、手元の pixie の状態次第で絵が変わります。

同じアプリを MCP サーバーとして立てれば、エージェントの道具になります。

```bash
zig build kngn                                   # → zig-out/bin/kngn
KNGN_HEADLESS=1 KNGN_HARNESS_LISTEN= KNGN_HARNESS_PORT_FILE=/tmp/kngn.port zig build run-pixie &
zig-out/bin/kngn mcp --port-file /tmp/kngn.port # stdio JSON-RPC
```

`kngn mcp` はアプリに `digest capabilities` を一度問い合わせ、**登録されている probe と action から
MCP ツール表を自動生成します**。アプリ側に MCP の知識は一切要りません。
`registerProbe` / `registerAction` を呼んだ時点で、そのアプリはエージェントから操作できます。
`snapshot_*` ツールが返すのは**成果物ファイルの絶対パス**です（形式は probe 次第で、`fb` や
`canvas` は PNG、`capabilities` は JSON）。画像そのものを見るかどうかは、MCP クライアントが
そのパスを読めるかによります。

## これは何で、何でないか

Electron は Chromium と Node.js を同梱し、Tauri は OS の WebView（WebView2 / WKWebView /
webkitgtk）を使います。どちらも「Web 技術で UI を書き、ネイティブシェルに載せる」形です。
KNGN には WebView も DOM もなく、`[]u32` のフレームバッファに直接書きます。層として近いのは
raylib / SDL / macroquad / egui の側です。

エージェントから見ると、実は Electron も Tauri も手強い相手です。WebView があるということは
**DOM という既製の観測対象がある**ということで、エージェントはアプリ側の協力なしに中を覗けます。
冒頭の非対称でいえば、この 2 つは**タダで見える側**にいます。

KNGN はそれを WebView なしでやります。ただし**タダではありません**。DOM のように自動では
覗けず、アプリが `registerProbe` / `registerAction` で「何を見せ、何をさせるか」を宣言する必要が
あります。その代わり返ってくるのは DOM ツリーではなく、アプリ自身が定義した意味単位の 1 行です。

**層が薄いことは、速さの話ではありません。** 定常状態の描画なら Chromium の方が速いことすら
あります。比べるべきは描画 FPS ではなく、**エージェントの検証ループ**です。そこに効くのは
4 つ。**起動**（追加の renderer プロセスも V8 初期化も DOM 構築も無い）、**メモリと配布サイズ**、
**ジッタ**、そして **エージェントが抱える概念の数**。

このうち数字で出せたのは配布サイズ・検証サイクルの所要時間・ピーク RSS です。
同梱のピクセルエディタ pixie（レイヤー・選択・ベジェ・undo・PNG 入出力あり）での実測:

- **バイナリ 2.6 MB、単一ファイル**。追加ランタイムなし
- **1 サイクル 102 ms** — 起動して、描いて、780×600 の PNG を書き出して、終了するまで。
  1 度ビルドすれば、入力を変えた検証を毎秒 10 本流せます
- ピーク RSS 34.4 MB

> MacBook Pro (Apple M1 Max, 10-core, 64 GB) / macOS 26.5 / ReleaseFast / Metal バックエンド。
> `KNGN_APPSHELL_DIR` でアプリ状態を隔離した既定ウィンドウ（780×600）で、warm 20 回の平均。
> 初回のみページキャッシュミスで 0.6 s。**数字はウィンドウサイズと保存済み状態に依存します**
> — 復元された大きなウィンドウでは PNG も RSS も増えます。
> ヘッドレスでは `KNGN_HEADLESS=1` が backend の初期化ごと飛ばすので、**時間も RSS も backend に
> ほとんど依存しません**（objc でも 102 ms / 34.3 MB。違うのはバイナリサイズだけで objc は 2.4 MB）。

**ジッタ**は測定値ではなく契約の話です。Zig のランタイムに tracing GC はなく、リアルタイム音声の
コールバック区間では allocation / lock / IO / panic を禁止する契約があります
（[docs/audio-and-synth.md](docs/audio-and-synth.md)）。ただし契約を守るのはアプリ側の責任です。

**4 つ目の「概念の数」が、おそらく一番効きます。** Electron でウィンドウを 1 枚出すには、JS/HTML/CSS の
3 言語、main と renderer のプロセス分離、Node と browser の API 境界、バンドラ設定、
CSP と preload、そして npm の依存ツリーを同時に頭に置く必要があります。KNGN でアプリを書く側が
触るのは Zig 1 言語と、1 画面に収まるプリミティブだけです（リポジトリの内部には macOS 用の
Objective-C / Swift / Metal がありますが、アプリ作者は触りません）。hello world は `build.zig` と
`main.zig` の 2 ファイルで、設定ファイルもマニフェストもありません。Zig パッケージ依存はゼロ。
**エージェント向けの開発契約は [`AGENT.md`](AGENT.md) 1 ファイル 34 KB に集約**してあります
（個々のサブシステムの詳細は [`docs/`](docs/) とソースコメントへ）。

ただしこの比較には裏があります。**LLM は JS/HTML/CSS の訓練データを桁違いに持っていて、Zig は
不利です。** 概念が少なくても、馴染みが薄ければ間違える。だからこそ「見える」ことが効きます。
観測までの待ち時間が 0.1 秒なら、誤りに気づくまでのフィードバックループを短くできる。
見えなければ、馴染みだけが頼りになります。

**まだ無いもの。** シーングラフ・ECS・アセットパイプラインといった「エンジン」層はありません。
ただし部品の方は `libs/gfx` に揃っています — スプライト、アニメーション、アトラス、タイルマップ、
カメラ、アクションマップ、固定タイムステップ。束ねる層がまだ無いだけです。
公開 API も流動的で、バージョンは `0.0.0` です。どちらも現時点で提供していないというだけで、
方向として否定しているわけではありません。

**設計としてやらないこと。** HTML/CSS で UI を書く道は用意しません — WebView を積んだ時点で
Electron や Tauri と同じ土俵になるからです。レイアウトは `libs/gui` の flex をコードで書きます。
Chromium より速く描画することも目指しません。プリミティブが CPU フレームバッファである以上、
勝てるのは起動時間・メモリ・配布サイズ・ヘッドレスの決定性であって、コンポジットのスループット
ではありません。

## Hello, window

```zig
const platform = @import("platform");

pub fn main() !void {
    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(800, 600, "hello");
    defer window.destroy();

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            else => {},
        };

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, 0xFF2E3440); // BGRA (0xAARRGGBB)
            window.present();
        }

        platform.frameDelay(16_666_666);
    }
}
```

アプリが触るのはこれで全部です — `init` / `shutdown`、`Window.create` / `destroy`、
`pollEvents` / `nextEvent`、`lockFramebuffer` / `unlock` / `present`、そして時間まわりの
`getTime` / `frameDelay`。フレームバッファは素の `[]u32` で、間に描画抽象は挟まりません。
`lockFramebuffer()` が `null` を返すのは「このフレームのスロットが取れなかった」という意味で、
エラーではありません（多くの場合は次フレームで取れます）。

## これで自分のアプリを作る

### AI に作らせる場合

やることは 2 つ。**Zig 0.16.0 を用意すること**と、**エージェントに [`AGENT.md`](AGENT.md) を
読ませること**。層構造・API 契約・ビルドコマンド・ハーネスの使い方は全部そこにあります。

```
KNGN (https://github.com/gamako/video-proto-main) を使ってデスクトップアプリを作って。
まず AGENT.md と docs/harness.md を読んで、kit だけを import すること。
実装したら KNGN_HEADLESS=1 + KNGN_HARNESS_SCRIPT でヘッドレス実行して、
snapshot fb で PNG を撮って、自分で見て確認してから報告して。
```

最後の 1 行が要点です。これを入れておくと、エージェントは崩れたレイアウトを自分で見つけて、
自分で直してから戻ってきます。入れないと、コードだけ読んで「できました」と言ってきます。

### 自分で書く場合

外部プロジェクトからは `kit` だけを import します。動く手本が
[tictactoe](https://github.com/gamako/tictactoe) です。

```zig
// build.zig.zon
.dependencies = .{
    .kngn = .{ .path = "../video-proto-main" },   // または zig fetch --save <url>
},
```

```zig
// build.zig
const dep = b.dependency("kngn", .{ .target = target, .optimize = optimize });

exe.root_module.addImport("kit", dep.module("kit"));        // 純 Zig の部分
exe.root_module.linkLibrary(dep.artifact(native_lib_name)); // ネイティブ .o アーカイブ
```

macOS を対象にする場合は、フレームワークと Swift ランタイムのリンクを consumer 側の exe に
適用する必要があります（C 方式）。`build_helpers/macos.zig` と `build_helpers/swift.zig` を
自分のプロジェクトに vendor してください — tictactoe がまさにそれをやっています。

> 現時点で **`dep.module("platform")` による外部利用は macOS 想定**です。Linux は公開モジュール側に
> X11 のリンクが載っていないため、そのままでは動きません（`build.zig` に制限を明記してあります）。

## 何が入っているか

```
apps  →  kit  →  libs  →  core  →  platform      （一方向依存。build.zig が構成時に強制）
```

| 層 | 中身 |
|---|---|
| `platform/` | macOS ネイティブ実装（C ABI: objc / swift / metal）。Linux と Windows のバックエンドは pure Zig で `core/` にあります |
| `core/` | platform ファサードと OS 別バックエンド、オーディオ、MIDI、制御プレーン（ハーネス） |
| `libs/` | 任意で使う部品 — `gui`（イミディエイトモード） `font`（TrueType/CFF/bmfont） `png` `synth` `sound` `pixelops`（SIMD ブレンド） `gfx` `gmath` `appshell` `paint` `modular` `viz` `serde` `recipe` |
| `kit/` | アプリと外部利用者が import する公開アンブレラモジュール |
| `apps/` | `pixie`（ピクセルエディタ） `synth`（PC キーボード演奏） `patch`（モジュラーパッチキャンバス） |
| `examples/` | 41 本のサンプル（`zig build run-example_NN`） |

依存の向きは `build.zig` が構成時に検査し、逆流・層飛ばしがあれば**ビルドを panic で止めます**。

## エージェント向けの仕組み

- **probe（観測）** — アプリが `platform.registerProbe(...)` で状態を公開する。組み込みは
  `fb`（フレームバッファ → PNG または 1 行ダイジェスト）`audio` `stats` `capabilities`。
  pixie は `canvas` `undo` `tool` `cursor` `history` `diff` `palette` `timeline` `panels`
  `menu` `appshell` `presence` の 12 種を登録している。役割は読み出しですが、**純粋性は
  強制されません** — `snapshot` はファイルを書きますし、コールバックはアプリ状態への可変
  ポインタを受け取ります（pixie の `diff` は初回 digest で比較元を取ります）。
- **action（操作）** — `platform.registerAction(...)` で意味単位のコマンドを公開する。
  UI 座標に依存しない。pixie なら `stroke` `undo` `add_layer` `set_color` `save` `open` など。
  UI・キーボードと同じ経路を通るので、**`action stroke` で描いたものは
  `inject key_down Z cmd` で undo できる**。
- **構造化エラー** — 失敗時に `code=file_not_found next=check path or use save first` のような
  自己回復ヒントを返せる。エージェントが次の手を選べる。
- **完全ディスプレイレス** — `KNGN_HEADLESS=1` で `platform.init()` がネイティブ初期化ごと飛ばし、
  実行時に null バックエンドを選ぶ。CI でもコンテナでも動く。
- **決定論と記録** — シードの規約と recipe（コマンド列の保存・再生）があるので、
  同じ入力から同じ出力が再現できる。record → replay 対称。

ハーネスは platform ファサードの 4 フック（`pollEvents` / `nextEvent` / `present` / `getTime`）に
割り込む形で実装されています。環境変数を何も設定しなければ全フックは素通りし、挙動は元のままです。
コマンド言語・probe の追加方法・MCP サーバーの詳細は [`docs/harness.md`](docs/harness.md)。

## ビルドと実行

```bash
direnv allow                  # nix + direnv の場合（推奨）。zig 0.16.0 が PATH に乗る
zig build run-pixie           # ピクセルエディタ。ほかに run / run-synth / run-patch / run-example_NN
zig build test                # 全テスト
```

nix なしのセットアップ（OS ごとの必要パッケージ）、バックエンドの切り替え、クロスコンパイル、
テストの個別実行は [`docs/build.md`](docs/build.md) にあります。
Windows ターゲットだけはどのホストからでもクロスビルドできます。

## 現状

個人プロジェクトです。Zig 0.16 に追従しており、バージョンは `0.0.0`、公開 API は流動的で
semver の保証はありません。プリミティブ API・ハーネス・各バックエンドは実装済みで実機検証も
済んでいますが、上物のライブラリ（特に `modular` / `paint` / `viz`）はまだ形が変わります。

> リポジトリ名は `video-proto-main` のままです（KNGN はプロジェクト名）。
> 開発者向けの技術詳細は [`AGENT.md`](AGENT.md)、サブシステム別の文書は [`docs/`](docs/) に。

## この先（顕現）

KNGN = 顕現。「AI が作れる」「AI が動かせる」の次に置いているのは、**AI が自分自身をユーザーの前に
立ち上げる**ことです。

1. **いま**: AI がアプリを書き、ヘッドレスで動かし、描画結果を見て直せる。作ったアプリは
   そのままエージェントの道具になる（どちらも実装済み）
2. **育てているところ**: 人間と AI が同じアプリを同時に操る。通常の UX と共存する第 3 の
   制御プレーン（`core/control/copilot.zig`）と、undo と同じ意味単位で動くコマンド実行モデルが
   あります。
3. **その先**: AI が「これをこう見せたい」と思ったときに、自分でネイティブアプリを組み上げて顕現させる。
   チャット欄という一つの窓ではなく、伝えたい内容に合った形と手触りを持った器を、AI 自身が作る。

## ライセンス

プロジェクトのコードは [MIT License](LICENSE)。同梱しているサードパーティのアセット・
ライブラリはそれぞれのライセンスに従います（各ディレクトリの LICENSE を参照）:

| コンポーネント | ライセンス | 場所 |
|---|---|---|
| Press Start 2P（フォント） | SIL OFL 1.1 | [`libs/font/LICENSE`](libs/font/LICENSE) |
| Spleen（ビットマップフォント） | BSD-2-Clause | [`libs/gui/LICENSE`](libs/gui/LICENSE) / [`examples/05_text_rendering/assets/LICENSE-spleen`](examples/05_text_rendering/assets/LICENSE-spleen) |
| LodePNG（開発ツール専用。ビルド成果物には含まれない） | zlib License | [`libs/png/tools/lodepng/LICENSE`](libs/png/tools/lodepng/LICENSE) |

`examples/19_color_emoji` などの一部サンプルは OS のシステムフォント（Apple Color Emoji ほか）を
実行時に読み込むだけで、それらのフォントをリポジトリに同梱してはいません。
