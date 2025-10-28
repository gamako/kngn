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

**決定**: Zig 0.16.0 の `std.compress.deflate` を使用

**理由:**
- DEFLATE解凍が標準ライブラリに組み込まれている
- 外部依存がゼロ
- 完全にZigのみで実装可能
- DEFLATE実装を自作する必要がない

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

**Python スクリプト（tools/generate_test_png.py）:**
- PIL（Python Imaging Library）でテストPNGを生成
- パラメータで色パターンを指定可能（単色、チェッカーボード、グラデーション等）
- 再実行で常に同じ画像を生成（再現性保証）

**保存方式:**
- 生成されたPNGファイルを `libs/png-decoder/test-data/` に配置
- ファイルサイズが小さい（通常 1-5KB）ため、直接 jj でコミット可能
- スクリプトも保存し、画像の出所を明確に

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
1. Python スクリプトでテストPNG生成
2. Zigコードで期待値を定義
3. Zig test で `zig test src/test.zig`実行
4. 実装が期待値と一致するかを自動検証
5. 次のPhaseに進む前に全テスト合格を確認
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
│   ├── deflate.zig           # std.compress.deflateラッパー
│   ├── filter.zig            # フィルタリング解除
│   ├── format.zig            # ピクセルフォーマット変換
│   ├── test.zig              # テストコード
│   └── test_cases.zig        # テストケース定義・期待値
│
└── test-data/                # テストPNG画像
    ├── 1x1_red.png
    ├── 8x8_checkerboard.png
    ├── 16x16_gradient.png
    ├── 32x32_grayscale.png
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

**deflate.zig:**
- `std.compress.deflate` ラッパー
- 複数のIDATチャンクを連結して解凍

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
1. テストPNG画像を生成（Python）
2. 期待値をZigコードで定義
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

### テストPNG生成スクリプト（tools/generate_test_png.py）

**役割:**
- PIL（Pillow）を使ってテスト用PNG画像を生成
- パラメータでパターンを指定
- 再実行で同じ画像を再生成（再現性保証）

**実装内容:**
- `solid_red`: 1色で塗りつぶし
- `checkerboard`: 黒白チェッカーボード
- `gradient`: グラデーション
- `grayscale`: グレースケール段階

**用途:**
初期セットアップ時に実行：
```bash
cd libs/png-decoder
python3 tools/generate_test_png.py
```

既に生成されたPNGは コミット済みなので、以降は再実行不要ですが、画像の出所（Pythonコード）を保持することで透明性を確保。

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

### ステップ2: テストPNG生成スクリプト実装
```
tools/generate_test_png.py を実装
テストPNGを生成
```

### ステップ3: テストケース定義
```
src/test_cases.zig に期待値を定義
各テストケースの詳細情報を記述
```

### ステップ4: 基本的なPNG解析
```
src/png_parser.zig に実装：
  - PNG署名確認
  - チャンク解析ループ
  - IHDR情報抽出
テストで署名確認をテスト
```

### ステップ5: DEFLATE解凍
```
src/deflate.zig に実装：
  - std.compress.deflate ラッパー
  - IDAT連結処理
テストで解凍されたデータサイズを検証
```

### ステップ6: フィルタリング解除
```
src/filter.zig に実装：
  - フィルタ種類判定
  - None, Sub, Up アルゴリズム
テストでチェッカーボード画像が正しく復元される
```

### ステップ7: ピクセルフォーマット変換
```
src/format.zig に実装：
  - RGB/RGBA/Grayscale → RGBA8888 変換
テストで色値が正確か検証
```

### ステップ8: 公開API作成
```
src/lib.zig に実装：
  - PNGImage構造体
  - decodePNG(), decodePNGFile()
  - 全エラー型
```

### ステップ9: build.zig設定
```
libs/png-decoder/build.zig を記述：
  - テストターゲット定義
  - モジュール定義
```

### ステップ10: メインプロジェクト統合
```
ルート build.zig で png_decoder モジュールを登録
examples/03_sprite_display/main.zig で使用
```

### ステップ11: Phase 2へ進む
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
- [Zig std.compress.deflate](https://ziglang.org/documentation/master/std/#std.compress.deflate)
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
