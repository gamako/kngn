# PNG デコーダー 最適化プラン

作成日: 2025-11-18

## 概要

このドキュメントは、libs/png-decoder/ の性能分析結果と最適化プランをまとめたものです。

## 1. パフォーマンス分析結果

### 1.1 メモリ使用の問題点

#### ピークメモリ使用量が過剰
- **現状:** 1920x1080 RGBA画像で約29MB
- **原因:** 5つのバッファが同時に存在
  - file_data (入力ファイル全体): 約2-3MB
  - idat_data (圧縮データ): 約2MB
  - decompressed (解凍データ): 約8.3MB
  - filtered (フィルタ除去済み): 約8.3MB
  - rgba_pixels (最終出力): 約8.3MB

#### 不要なメモリコピーが多い
- **現状:** 最低4回の全データコピーが発生
  1. collectIDATChunks: チャンクデータを収集
  2. decompressZlib: 圧縮データを解凍
  3. applyFilters: フィルタ除去
  4. format変換: RGBA変換

#### ArrayList の誤用
- **問題箇所:** libs/png-decoder/src/format.zig
- **現状:** 出力サイズが既知なのに `.empty` で初期化し動的拡張
- **影響:** 内部で複数回の再アロケーションが発生

### 1.2 速度の問題点

#### ホットパスの最適化不足
- **filter.zig:** 8,294,400バイト (1920x1080 RGBA) を1バイトずつ処理
  - 各バイトで switch 分岐
  - 関数呼び出しオーバーヘッド
- **format.zig:** ピクセル単位のループ処理
  - ArrayList.append の呼び出し
  - 容量チェックと再アロケーション

#### SIMD の未活用
- RGB→RGBA変換: 並列処理可能
- フィルタタイプ0 (None): 単純なメモリコピー
- フィルタタイプ1 (Sub): bytes_per_pixel 単位で並列処理可能

## 2. 最適化プラン

### Phase 1: 即効性の高い改善（高優先度）

#### 2.1.1 format.zig - 事前アロケーション化

**目的:** ArrayList の再アロケーションを完全に回避

**変更箇所:**
- `grayscaleToRGBA8888` (行12-28)
- `rgbToRGBA8888` (行35-57)
- `rgbaToRGBA8888` (行59-87)

**変更内容:**
```zig
// Before
var result: std.ArrayList(u32) = .empty;
for (grayscale_data) |gray| {
    try result.append(allocator, rgba);
}

// After
const result = try allocator.alloc(u32, grayscale_data.len);
for (grayscale_data, 0..) |gray, i| {
    result[i] = rgba;
}
```

**期待効果:**
- メモリアロケーション回数: 複数回 → 1回
- 速度向上: 約10-20%
- 実装難易度: 低

#### 2.1.2 filter.zig - フィルタタイプ0 の最適化

**目的:** 最も使用頻度の高いフィルタの高速化

**変更箇所:** libs/png-decoder/src/filter.zig 行72-79

**変更内容:**
```zig
// Before
for (0..bytes_per_scanline) |x| {
    const filt = decompressed[input_pos];
    input_pos += 1;
    const recon = try filterNone(filt);
    output[output_pos] = recon;
    output_pos += 1;
}

// After
if (filter_type == 0) {
    @memcpy(
        output[output_pos..output_pos + bytes_per_scanline],
        decompressed[input_pos..input_pos + bytes_per_scanline]
    );
    input_pos += bytes_per_scanline;
    output_pos += bytes_per_scanline;
}
```

**期待効果:**
- フィルタタイプ0の処理速度: 約50-70%向上
- 実装難易度: 低

#### 2.1.3 lib.zig - 中間バッファの削減

**目的:** ピークメモリ使用量の削減

**変更方針:**
1. `decompressed` と `filtered` を統合
2. in-place フィルタ処理を検討
3. パイプライン処理の導入

**期待効果:**
- ピークメモリ使用量: 約40-50%削減
- 実装難易度: 中

### Phase 2: 更なる性能向上（中優先度）

#### 2.2.1 filter.zig - 関数インライン化

**目的:** 関数呼び出しオーバーヘッドの削減

**変更内容:**
```zig
inline fn filterSub(...) !u8 { ... }
inline fn filterUp(...) !u8 { ... }
inline fn filterAverage(...) !u8 { ... }
inline fn filterPaeth(...) !u8 { ... }
```

**期待効果:**
- 速度向上: 約5-10%
- 実装難易度: 低

#### 2.2.2 format.zig - SIMD化

**目的:** RGB→RGBA変換の大幅高速化

**変更方針:**
- `@Vector` を使用した4ピクセル並列処理
- シャッフル命令での並べ替え

**期待効果:**
- RGB変換速度: 約2-4倍向上
- 実装難易度: 中〜高

### Phase 3: 特殊ケースの最適化（低優先度）

#### 2.3.1 png_parser.zig - CRC検証のオプション化

**目的:** 信頼できるソースでの高速化

**注意:** セキュリティトレードオフあり

#### 2.3.2 flate.zig - 小画像用の小バッファ対応

**目的:** 小画像でのメモリ削減

**変更内容:**
```zig
// 画像サイズに応じて動的にバッファサイズを決定
const window_size = @min(expected_size, std.compress.flate.max_window_len);
```

## 3. 実装順序

### ステップ1: Phase 1.1 - format.zig 最適化
- [ ] grayscaleToRGBA8888 を修正
- [ ] rgbToRGBA8888 を修正
- [ ] rgbaToRGBA8888 を修正
- [ ] テスト実行して動作確認

### ステップ2: Phase 1.2 - filter.zig フィルタタイプ0 最適化
- [ ] フィルタタイプ0の処理を @memcpy に変更
- [ ] テスト実行して動作確認

### ステップ3: Phase 2.1 - 関数インライン化
- [ ] filter.zig の関数に inline 追加
- [ ] ベンチマーク実行

### ステップ4: Phase 1.3 - 中間バッファ削減
- [ ] lib.zig のバッファ管理を見直し
- [ ] in-place フィルタ処理の実装
- [ ] テスト実行

### ステップ5: Phase 2.2 - SIMD化（余裕があれば）
- [ ] RGB→RGBA変換をSIMD実装
- [ ] ベンチマーク実行

## 4. 成功指標

### メモリ使用量
- **目標:** ピークメモリ 50%削減
- **測定方法:** 1920x1080 RGBA画像でのピークメモリ計測

### 速度
- **目標:** デコード速度 30-50%向上
- **測定方法:** test_cases.zig でのベンチマーク

## 5. リスク管理

### 破壊的変更のリスク
- 各Phase後に必ずテスト実行
- 既存のテストケースが全て通ることを確認

### パフォーマンス低下のリスク
- ベンチマーク計測を各Phase後に実施
- 改悪の場合は即座にロールバック

## 6. 参考情報

### 関連ファイル
- libs/png-decoder/src/lib.zig
- libs/png-decoder/src/filter.zig
- libs/png-decoder/src/format.zig
- libs/png-decoder/src/flate.zig
- libs/png-decoder/src/png_parser.zig

### ベンチマーク方法
```bash
zig test libs/png-decoder/src/test.zig
```
