# PNG デコーダーライブラリ - 実装計画

## 概要

PNG画像ファイルをデコードし、ピクセルデータ（RGBA8888形式）に変換するZigライブラリを実装します。

このライブラリは、スプライト表示やフォントビューアーなど、画像を必要とするサンプルプログラムの基盤となります。

**位置づけ:**
- プロジェクト本体から独立した再利用可能なライブラリ
- `libs/png-decoder/` に配置
- 他のプロジェクトでも利用可能な設計

---

## 背景と課題

### 現状

video-proto は現在、フレームバッファへの直接描画機能を持つプラットフォーム層がありますが、PNG画像を読み込む機能がありません。

### なぜ独立ライブラリにするのか

1. **再利用性**: 他のZigプロジェクトでも使用可能
2. **保守性**: PNG処理ロジックが本体から分離され、独立してテスト・更新可能
3. **スコープ管理**: デコーダー機能に集中し、プラットフォーム層との関心を分離
4. **段階的なGitHub化**: 将来的に別リポジトリとして公開する際、構造変更が最小限

### 外部依存の検討

PNG読み込みにはDEFLATE圧縮解凍が必須です。以下を比較検討：

| 方式 | 依存性 | 実装コスト | 採用判断 |
|------|--------|-----------|--------|
| C言語ライブラリ（zlib） | Cバインディング | 低 | ❌ 外部依存増加 |
| Zigネイティブライブラリ | zlibリンク | 低 | ❌ 依存性あり |
| **Zig標準ライブラリ** | **なし** | **中** | **✅ 採用** |

**決定**: Zig 0.16.0 の `std.compress.flate` を使用（zlib形式）

**重要**: PNG IDAT チャンクは **zlib形式**（RFC 1950）で圧縮されています。
- DEFLATE圧縮データにzlibヘッダー（2バイト）とAdler-32チェックサム（4バイト）が付加
- `std.compress.flate.Decompress` を `.zlib` コンテナで初期化することで自動処理される

**理由:**
- zlib形式の解凍が標準ライブラリ（std.compress.flate）に組み込まれている
- 外部依存がゼロ
- 完全にZigのみで実装可能
- ヘッダー・フッター処理が自動で行われる

---

## 重要な設計決定

### 1. PNG読み込みのスコープ（何を実装するか）

PNG仕様は複雑で、すべてを実装するコストが大きいため、段階的に実装します。

#### 対応する色形式と実装順序

**Phase 1（必須）: Grayscale (Color Type = 0, 8bit)**
- 白黒グレースケール画像
- 内部フォーマット的に最もシンプル（1チャンネル）
- 学習曲線が緩やか、デバッグが容易
- テスト: 8x8 グレースケール、16x16 グレースケール

**Phase 2: RGB (Color Type = 2, 8bit)**
- カラー画像（不透明）
- Grayscaleからの自然な拡張（3チャンネル）
- データ構造理解が段階的に進む
- テスト: 8x8 チェッカーボード（RGB）、16x16 グラデーション（RGB）

**Phase 3: RGBA (Color Type = 6, 8bit)**
- 透明度付きカラー画像
- RGBからアルファチャンネルを追加（4チャンネル）
- フォントアトラス、スプライト用として最終的に必要
- テスト: 1x1 赤色（アルファ付き）、16x16 グラデーション（RGBA）

**Phase 4（将来）: Indexed Color、Grayscale + Alpha、1bit深度**
- 実装優先度は低い
- 必要に応じて段階的に追加

#### ビット深度の実装順序

**Phase 1: 8bit（必須）**
- 最も一般的、256段階の色情報
- 標準的なPNG画像のほぼすべてが対応

**Phase 2以降: 1bit, 2bit, 4bit, 16bit**
- 実装優先度は低い
- 必要に応じて追加

#### フィルタリングアルゴリズムの実装順序

PNGの各スキャンラインは5種類のフィルタのいずれかで前処理されています。

**Phase 1（必須）:**
- **None (0)**: フィルタなし、データをそのまま使用
- **Sub (1)**: 左隣のピクセル値を加算
- **Up (2)**: 上のピクセル値を加算

**Phase 2:**
- **Average (3)**: 左と上のピクセル値の平均を加算
- **Paeth (4)**: Paeth予測アルゴリズムを使用（最も複雑）

**理由:**
Phase 1で80%以上のPNG画像に対応可能です。Average と Paeth はテスト駆動で実装を進めながら、必要に応じて追加します。

### 2. テスト戦略（再現性重視）

テスト駆動開発で、「期待値が明示されたテスト」を実施します。

#### テストPNG生成方式

**C言語プログラム（tools/generate_test_data.c）+ LodePNG:**
- LodePNG ライブラリを使用してテストPNGを生成
- **フィルタタイプをスキャンラインごとに完全指定可能**（0=None, 1=Sub, 2=Up, 3=Average, 4=Paeth）
- 色形式も指定可能（Grayscale、RGB、RGBA）
- 単一プログラムでPNG生成と期待値出力（Zigコード）の両方を実施

**特徴:**
- 再現性: 常に同じバイナリ出力で比較可能
- 完全制御: フィルタタイプごとに異なるテストPNGを生成
- シンプル: C言語のみ、外部依存なし

**保存方式:**
- 生成されたPNGファイルを `libs/png-decoder/test-data/` に配置
- ファイルサイズが小さい（通常 1-5KB）ため、直接 jj でコミット可能
- プログラムも保存し、生成方法を明確に

#### テスト期待値の定義

**Zigコード（libs/png-decoder/src/test_cases.zig）:**
```
各テストケースについて：
- 画像ファイル名
- 期待される幅・高さ
- 期待されるピクセルデータ（全ピクセル）
をZigコードに記述
```

期待値をコード内に埋め込むことで：
- テストコードと期待値が同じファイル内にある
- 画像ファイルと期待値の同期が取りやすい
- テスト失敗時の差分が明確

#### テスト実行フロー

```
1. C言語プログラム（generate_test_data.c）でテストPNG生成
   - Makefile で自動ビルド: make generate
   - png-decoder/test-data/ 配下にPNGを出力

2. 同時に期待値をZigコード形式で出力
   - generate_expected_values() 関数で自動生成
   - 標準出力 → test_cases_generated.zig.txt にリダイレクト

3. 期待値コードを test_cases.zig に手動コピー

4. Zig test で `zig test src/test.zig` 実行

5. 実装が期待値と一致するかを自動検証

6. 次のPhaseに進む前に全テスト合格を確認
```

### 3. エラー型の詳細度（Level 3）

適切なエラー情報を提供し、実装の問題点を特定しやすくします。

```
error.InvalidPNGSignature      // PNG署名が正しくない
error.MissingIHDR              // IHDRチャンクがない
error.MissingIDAT              // IDATチャンクがない
error.InvalidColorType         // 色タイプ値が不正（0-6以外）
error.InvalidBitDepth          // ビット深度値が不正
error.UnsupportedColorType     // 色タイプが未対応（実装未済）
error.UnsupportedBitDepth      // ビット深度が未対応（実装未済）
error.InvalidCRC               // CRCチェックサムが不一致
error.DecompressionFailed      // DEFLATE解凍に失敗
error.InvalidFilterType        // フィルタタイプが不正（0-4以外）
error.InvalidDimensions        // 幅または高さが0または異常に大きい
error.OutOfMemory              // メモリ確保に失敗
```

これにより、テストやデバッグ時に「何がどう失敗したか」を特定しやすくなります。

---

## アーキテクチャ設計

### ディレクトリ構造

```
libs/png-decoder/
├── build.zig                  # ライブラリビルド設定
├── zig.build.zon              # 依存関係定義（必要に応じて）
├── README.md                  # ライブラリドキュメント
│
├── src/
│   ├── lib.zig               # 公開API エントリーポイント
│   ├── png_parser.zig        # PNG署名・チャンク解析
│   ├── flate.zig             # std.compress.flate (zlib形式) ラッパー
│   ├── filter.zig            # フィルタリング解除
│   ├── format.zig            # ピクセルフォーマット変換
│   ├── test.zig              # テストコード
│   └── test_cases.zig        # テストケース定義・期待値
│
├── tools/
│   ├── lodepng/              # LodePNGライブラリ（組み込み）
│   │   ├── lodepng.c         # LodePNG実装
│   │   ├── lodepng.h         # LodePNGヘッダー
│   │   ├── LICENSE           # zlibライセンス
│   │   └── README.md         # 出所とバージョン情報
│   ├── generate_test_data.c  # テストPNG生成プログラム
│   └── Makefile              # ビルド・実行スクリプト
│
└── test-data/                # 生成されたテストPNG画像
    ├── 8x8_gray_none.png
    ├── 8x8_gray_sub.png
    ├── 8x8_gray_up.png
    ├── 8x8_checkerboard_rgb.png
    └── ...
```

### 公開API（lib.zig）

```
呼び出し側（examples/03_sprite_display等）は以下を使用：

pub const PNGImage = struct {
    width: u32,
    height: u32,
    pixels: []u32,           // RGBA8888形式
}

pub fn decodePNG(allocator, file_data: []const u8) !PNGImage
  ファイルデータ全体を受け取ってデコード

pub fn decodePNGFile(allocator, path: []const u8) !PNGImage
  ファイルパスから読み込んでデコード
```

メモリ管理：
- `allocator` で確保したメモリの解放は呼び出し側の責任
- `allocator.free(image.pixels)` で明示的に解放

### 内部モジュール分割

**png_parser.zig:**
- PNG署名確認
- チャンク構造解析（IHDR、IDAT、IEND等）
- チャンク順序検証

**flate.zig:**
- `std.compress.flate.Decompress` ラッパー（zlib形式対応）
- 複数のIDATチャンクを連結してzlib形式で解凍
- RFC 1950 zlib フォーマットのヘッダー・フッター自動処理

**filter.zig:**
- スキャンラインごとのフィルタ種類を判定
- フィルタアルゴリズム（None, Sub, Up, Average, Paeth）実装
- 前処理済みデータ → 生ピクセルデータ変換

**format.zig:**
- バイト列 → RGBA8888 u32値に変換
- 色形式の違い（RGB, Grayscale等）に対応

---

## 実装方針

### テスト駆動で段階的実装

各Phaseは以下のループで実装：

```
1. テストPNG画像を生成（C言語/LodePNG）
   - make generate でビルド・実行
2. 期待値をZigコードで定義
   - 標準出力をコピー＆ペースト
3. テストコードを記述（失敗を確認）
4. 機能を実装（テスト合格を確認）
5. jj でコミット
```

### Phase 1: Grayscale (8bit) + フィルター (None, Sub, Up)

**テストケース:**
- `8x8_grayscale.png`: グレースケール（最小複雑度）
- `16x16_grayscale.png`: より複雑なパターン

**実装スコープ:**
- PNG署名確認（8バイト固定）
- IHDRチャンク解析（幅・高さ・ビット深度・色タイプ）
- IDATチャンク収集・連結
- DEFLATE解凍
- フィルタリング解除（None, Sub, Up）
- Grayscale → RGBA8888 ピクセル変換（Gray値を全チャンネルにコピー）

**完了条件:**
- テスト全合格
- 1チャンネルデータの処理が正確に機能
- フィルタリングアルゴリズムが正しく動作

### Phase 2: RGB (8bit) + フィルター (Average, Paeth)

**テストケース:**
- `8x8_checkerboard_rgb.png`: RGB形式のチェッカーボード
- `16x16_gradient_rgb.png`: RGB形式のグラデーション

**実装:**
- RGB → RGBA8888 変換（アルファを255で埋める）
- Average フィルタ実装（Phase 1のNone/Sub/Upを拡張）
- Paeth フィルタ実装
- 3チャンネルデータの処理検証

**完了条件:**
- テスト全合格
- Grayscaleとの組み合わせテストで後退がない

### Phase 3: RGBA (8bit)

**テストケース:**
- `1x1_red.png`: RGBA形式の赤いピクセル（アルファ付き）
- `16x16_gradient_rgba.png`: RGBA形式のグラデーション

**実装:**
- RGBA → RGBA8888 変換（直接コピー）
- アルファチャンネル処理の検証
- 透明度付き画像の正確性確認

**完了条件:**
- テスト全合格
- RGB/Grayscaleとの組み合わせテストで後退がない
- フォントアトラス、スプライト用途で正しく表示可能

### Phase 4（将来）

必要に応じて段階的に追加：
- Indexed Color (パレット)
- Grayscale + Alpha
- 1bit深度（白黒）
- CRC検証の強化（エラー詳細度UP）

---

## テスト戦略の詳細

### テストケース定義（src/test_cases.zig）

**構造:**
```
各テストケースに以下を定義：
- ファイル名
- 期待される幅・高さ
- 期待されるピクセルデータ（u32配列）
- テストの説明
```

**例:**
```
test_1x1_red:
  - ファイル: test-data/1x1_red.png
  - 期待される幅: 1
  - 期待される高さ: 1
  - 期待されるピクセル: [0xFF0000FF]  // 赤
```

### テストコード（src/test.zig）

**構成:**
- 各テストケースについて、期待値と一致するかを検証
- ピクセルごとの差分を検出（失敗時に具体的な情報を出力）
- メモリリークがないか確認

**実行:**
```bash
cd libs/png-decoder
zig test src/test.zig
```

---

## LodePNGライブラリについて

### 概要

LodePNG は Lode Vandevenne が開発したオープンソースの PNG エンコーダー・デコーダーライブラリです。

**プロジェクトでの用途:**
- テストPNG画像の生成用
- **フィルタタイプをスキャンラインごとに指定可能**（重要）
- C言語のシンプルなAPI

**特徴:**
- ✅ ヘッダーファイル（lodepng.h）とC実装（lodepng.c）の2ファイルのみ
- ✅ 外部依存なし（標準C機能のみ使用）
- ✅ クロスプラットフォーム対応
- ✅ シンプルなAPI（エンコード・デコード両対応）

### ライセンス

**License: zlib License**

LodePNG は zlib License で公開されています。

**制約:**
- ✅ 商用利用可能
- ✅ 改変・再配布可能
- ✅ 制約が少ない

**必須要件:**
- 著作権表示を保持すること
- ライセンス文を含めること

### プロジェクトへの組み込み

**方針: ソースコードを直接配置**

理由：
1. ネットワーク接続不要（オフラインビルド可能）
2. バージョン固定（再現性確保）
3. jj（バージョン管理）と相性良い
4. サブモジュール不要

**配置場所:**
```
libs/png-decoder/tools/lodepng/
├── lodepng.c          # LodePNG実装（約18KB）
├── lodepng.h          # LodePNGヘッダー（約2KB）
├── LICENSE            # zlibライセンス全文
└── README.md          # 出所・バージョン情報
```

### ライセンス準拠

**コミット時の記載例:**
```
feat: LodePNGライブラリを追加

テストPNG画像生成用にLodePNGを組み込み。
- Version: [GitHub commit hash or version]
- License: zlib License
- Source: https://github.com/lvandeve/lodepng
- Purpose: フィルタタイプ指定可能なテストPNG生成

ライセンス準拠:
- lodepng/LICENSE ファイルを同梱
- 著作権表示を lodepng/README.md に記載
```

---

## エラー処理の方針

### エラー型の役割

```zig
error.InvalidPNGSignature  // 「何が」失敗したか
error.DecompressionFailed  // を明確にする
```

呼び出し側（examples/03_sprite_display）は：
- エラーの種類に応じてログ出力、ユーザー通知等を実施
- デコーダーはエラー型を返すだけ

### デバッグ情報

詳細なエラー情報（行番号、詳細メッセージ等）は：
- Phase 1では最小限（エラー型のみ）
- Phase 2以降で、必要に応じて std.debug ルーティングを追加

---

## 実装手順（具体的ステップ）

### ステップ1: ディレクトリ・ファイル作成
```
libs/png-decoder/ ディレクトリ構造を作成
各 .zig ファイルのスケルトン作成
```

### ステップ2: LodePNGライブラリ組み込み
```
1. tools/lodepng/ ディレクトリ作成
2. LodePNG ソースをダウンロード
   - lodepng.c, lodepng.h を配置
   - LICENSE ファイルを配置
   - README.md に出所・バージョン情報を記載

3. tools/generate_test_data.c を実装
   - LodePNG使用
   - PNG生成関数（フィルタタイプ指定可能）
   - 期待値出力関数（Zigコード形式）

4. tools/Makefile を作成
   - ビルド自動化
   - make generate で実行
```

### ステップ3: テストPNG生成 + 期待値出力
```
cd libs/png-decoder/tools
make generate

出力:
  - ../test-data/*.png （生成されたテストPNG）
  - 標準出力 （Zigコード形式の期待値）
```

### ステップ4: テストケース定義
```
src/test_cases.zig に期待値を定義
ステップ3の出力をコピー＆ペースト
各テストケースの詳細情報を記述
```

### ステップ5: 基本的なPNG解析
```
src/png_parser.zig に実装：
  - PNG署名確認
  - チャンク解析ループ
  - IHDR情報抽出
テストで署名確認をテスト
```

### ステップ6: zlib形式DEFLATE解凍
```
src/flate.zig に実装：
  - std.compress.flate.Decompress ラッパー（zlib形式対応）
  - IDAT連結処理
  - .zlib コンテナで初期化（RFC 1950形式）
テストで解凍されたデータサイズを検証
```

### ステップ7: フィルタリング解除
```
src/filter.zig に実装：
  - フィルタ種類判定
  - None, Sub, Up アルゴリズム
テストでグレースケール画像が正しく復元される
```

### ステップ8: ピクセルフォーマット変換
```
src/format.zig に実装：
  - Grayscale/RGB/RGBA → RGBA8888 変換
テストで色値が正確か検証
```

### ステップ9: 公開API作成
```
src/lib.zig に実装：
  - PNGImage構造体
  - decodePNG(), decodePNGFile()
  - 全エラー型
```

### ステップ10: build.zig設定
```
libs/png-decoder/build.zig を記述：
  - テストターゲット定義
  - モジュール定義
```

### ステップ11: メインプロジェクト統合
```
ルート build.zig で png_decoder モジュールを登録
examples/03_sprite_display/main.zig で使用
```

### ステップ12: Phase 2へ進む
```
同じサイクルで Average, Paeth フィルタを実装
RGB色形式対応
テスト駆動で進める
```

---

## 未決定事項（実装時に判断が必要）

### CRC検証のタイミング

PNGの各チャンクは CRC（循環冗長符号）でデータ整合性を検証できます。

**選択肢1: Phase 1では実装しない**
- テストが成功するまで最小限に保つ
- Phase 2で `error.InvalidCRC` を実装

**選択肢2: Phase 1で実装**
- 腐ったPNGを早期に検出
- 実装コスト追加

**推奨: Phase 1では実装しない** （テスト駆動の優先）

### 最大画像サイズの制限

デコード時にメモリを大量に消費する画像をチェックするか？

**選択肢:**
- 制限なし（OS任せ）
- 予め上限を定義（例：4096x4096）
- 段階的に実装

**推奨: 制限なし** （必要に応じて Phase 2で追加）

### インターレース（Adam7）対応

PNGの「インターレース」機能により、段階的に画像を表示するような形式があります。

**選択肢:**
- 未対応のPNGは error.UnsupportedFormat を返す
- 対応させる

**推奨: 当面未対応** （フォント用途では不要）

---

## 検証方法（完成後の確認項目）

### Phase 1完了時

**機能検証:**
- ✅ 8x8 グレースケール画像が正しくデコードされる
- ✅ 16x16 グレースケール画像が正しくデコードされる
- ✅ フィルタリング（None, Sub, Up）が正しく動作する
- ✅ 1チャンネルデータが正確にRGBA8888に変換される

**非機能検証:**
- ✅ メモリリークなし（各テストで allocator.free）
- ✅ zig test で全テスト合格
- ✅ エラー処理が機能（不正なPNGでエラー返却）

### Phase 2完了時

**新規テストケース合格**
- ✅ RGB形式チェッカーボード画像のテスト
- ✅ RGB形式グラデーション画像のテスト
- ✅ Average/Paeth フィルタのテスト

**既存テスト後退なし**
- ✅ Phase 1のテストは全合格を維持

### Phase 3完了時

**新規テストケース合格**
- ✅ RGBA形式画像（1x1赤色）のテスト
- ✅ RGBA形式グラデーション画像のテスト
- ✅ アルファチャンネル処理が正確か検証

**既存テスト後退なし**
- ✅ Phase 1, 2のテストは全合格を維持

**統合テスト**
- ✅ examples/03_sprite_display でカラー画像が正しく表示される

---

## 実装者へのメモ

### 設計の原則

1. **テスト駆動で進める**: 実装前にテストを記述し、失敗→実装→合格というサイクルを回す
2. **段階的実装**: 欲張らず、Phaseごとに機能を整理する
3. **依存性最小化**: Zig標準ライブラリのみで完結させる
4. **後方互換性**: 既存のAPI（PNGImage、decodePNG等）は変更しない

### 参考資料

- [PNG仕様（RFC 2083）](https://tools.ietf.org/html/rfc2083)
- [Zig std.compress.flate](https://ziglang.org/documentation/master/std/#std.compress.flate) - PNG IDAT はzlib形式なので `.zlib` container を使用
- [LodePNG（GitHub）](https://github.com/lvandeve/lodepng) - テストデータ生成用
- [テストPNG（色、フィルタパターン別）](test-data/)

### コミットのポイント

各Phaseの完了時に jj commit で記録：
```
feat: PNG デコーダー Phase 1 実装
  - Grayscale (8bit) 対応
  - フィルタリング (None, Sub, Up) 実装
  - テストケース 2個合格
  - 1チャンネルデータ処理の基礎確立

feat: PNG デコーダー Phase 2 実装
  - RGB (8bit) 対応
  - フィルタリング (Average, Paeth) 実装
  - テストケース 2個合格
  - 3チャンネルデータ処理対応

feat: PNG デコーダー Phase 3 実装
  - RGBA (8bit) 対応
  - アルファチャンネル処理
  - テストケース 2個合格
  - フォント/スプライト用途で使用可能に
```

変更は小分けにして、各変更が何をしたのか明確にすること。
