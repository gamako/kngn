# video-proto

クロスプラットフォーム対応のビデオ/グラフィックスプロトタイピング環境。Zig で書いたアプリケーション層と、
各 OS ネイティブの低レベル実装によるプラットフォーム層で構成されます。最小限のプリミティブ API
（イベント / 手動描画 / 時刻）を土台に、GUI・エディタ・オーディオ/シンセ・ヘッドレス検証 harness までを載せています。

> **詳細な技術ドキュメントは [`AGENT.md`](AGENT.md) を参照**（ディレクトリ構成・platform API・各 backend・
> ビルド/テスト・ヘッドレス検証 harness・オーディオ層など）。本 README は概要とクイックスタートに絞ります。

## 対応プラットフォーム

| OS | backend（`-Dplatform`） | 実装 |
|----|------------------------|------|
| **macOS** | `objc`（既定）/ `swift` / `metal` | Objective-C(CALayer) / Swift(CADisplayLink) / Metal(GPU) |
| **Linux** | `x11`（既定）/ `wayland` | 純 Zig（Xlib 直接 / wl_shm + xdg-shell 直接） |
| **Windows** | `gdi`（既定）/ `d3d11` | 純 Zig（Win32/GDI 直接 / D3D11-DXGI COM 手書き） |

`-Dplatform` の有効値は OS で決まる（macOS で `x11` を指定する等の不整合は build エラー）。frame pacing の
support tier（1級 = Metal / D3D11-DXGI / Wayland、best-effort = CALayer / X11 / GDI）は `docs/adr/005` を参照。

## プロジェクト構成

```
.
├── src/          # Zig コード（main / platform facade+各 backend / audio / dsp / harness / helpers）
├── platform/     # macOS のネイティブ実装（C ABI。macos / macos-swift / macos-metal）
├── examples/     # サンプル 01〜17（run-example_NN で実行）+ image/（共有アセット）
├── libs/         # 再利用ライブラリ（png / gui / font / synth）
├── apps/         # アプリ（editor/pixie: ドット絵エディタ、synth: PC キーボード演奏）
└── docs/         # 設計ドキュメント（サブシステム別ドキュメント / adr/）
```

## 前提環境

| 項目 | 用途 |
|------|------|
| nix（flake 対応）+ direnv | `flake.nix`（`aarch64-darwin` / `x86_64-linux`）が zig 0.16.0 + zls + 各種依存を供給。推奨 |
| macOS（Apple Silicon）+ Xcode | macOS backend の SDK / framework / `swiftc` 提供 |
| Linux（x86_64） | X11/Wayland dev lib 等は flake の devShell が供給 |
| Windows | zig 0.16.0 を現地導入しネイティブビルド（flake 非対応） |

```bash
direnv allow      # 初回のみ（.envrc を許可）。以降ディレクトリに入ると zig が PATH に通る
zig version       # → 0.16.0
```

direnv を使わない場合は `nix develop --command zig build ...` のように呼ぶ。

## ビルド・実行

```bash
# メインプログラム（HSV 虹色グラデーション）
zig build run                 # 既定 backend（macOS=objc / Linux=x11 / Windows=gdi）
zig build run-objc            # backend を明示（macOS: run-objc / run-swift / run-metal）
zig build run -Dplatform=metal  # 既定 run の backend を切替（例: Metal）

# アプリ
zig build run-pixie           # ドット絵エディタ（-Dplatform で backend 切替）
zig build run-synth           # シンセ（PC キーボード演奏。A..K = C4..C5、ESC 終了）

# サンプル（ルートから。01〜17）
zig build run-example_01      # 01_timed_window
zig build run-example_15      # 15_audio_tone …（run-example_NN）

# 全 backend / 全サンプルのビルド回帰
zig build -Dinstall-all=true

# リリースビルド
zig build --release=fast
```

## テスト

```bash
zig build test                # 全テスト集約（全 test-* を束ねる）
zig build test-gui            # 個別（例: libs/gui）。他に test-core / test-png-roundtrip /
                              # test-synth / test-dsp / test-font / test-harness など
```

macOS の Swift/Metal ビルドで使う SDK / Swift ツールチェーンのパスは `xcrun` / `xcode-select` から
自動検出します（Xcode 更新時も `build.zig` の修正は不要）。CI 等で明示指定したい場合は
`-Dswift-toolchain-path=` / `-Dswift-sdk-path=` を渡せます。

## ライセンス

本プロジェクトのコードは [MIT License](LICENSE) で公開しています。ただし同梱の第三者アセット・ライブラリは
それぞれ元のライセンスに従います（各ディレクトリの LICENSE を参照）:

| コンポーネント | ライセンス | 場所 |
|---|---|---|
| Press Start 2P（フォント） | SIL OFL 1.1 | [`libs/font/LICENSE`](libs/font/LICENSE) |
| Spleen（ビットマップフォント） | BSD-2-Clause | [`libs/gui/LICENSE`](libs/gui/LICENSE) / [`examples/05_text_rendering/assets/LICENSE-spleen`](examples/05_text_rendering/assets/LICENSE-spleen) |
| LodePNG（開発ツールのみ・ビルド非同梱） | zlib License | [`libs/png/tools/lodepng/LICENSE`](libs/png/tools/lodepng/LICENSE) |

なお `examples/19_color_emoji` 等の一部サンプルは OS のシステムフォント（Apple Color Emoji 等）を実行時に
読み込むだけで、リポジトリには同梱していません。
