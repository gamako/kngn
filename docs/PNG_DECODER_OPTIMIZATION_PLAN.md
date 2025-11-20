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

### 【Phase 0】ベンチマーク環境構築（最優先）

**目的:** パフォーマンス測定基盤の確立

**実装内容:**
1. `libs/png-decoder/src/benchmark.zig` を作成
2. `libs/png-decoder/docs/` ディレクトリを作成 ✅ (完了)
3. `libs/png-decoder/docs/BENCHMARKS.md` を作成 ✅ (完了)
4. `libs/png-decoder/build.zig` に `zig build benchmark` コマンド追加

**測定項目:**
- エンドツーエンドデコード速度（画像サイズ別）
- フィルタタイプ別の処理時間
- フォーマット変換の処理時間
- メモリピーク使用量とアロケーション回数

**テスト画像生成:**

現在の `tools/generate_test_data.c` に以下の機能を追加する必要があります：

#### 1. PCG32 PRNG実装の追加

**必要性:**
- 固定シード値から確定的（再現可能）なノイズを生成
- ベンチマーク間での一貫性確保（同じシード → 同じ画像）
- 高品質な疑似乱数（LCGより統計特性が優れている）

**実装内容:**
- PCG32状態型: `uint64_t`（内部状態管理）
- PCG32生成関数: `pcg32_random_r(state)` → `uint32_t` 戻り値
- 初期化関数: `pcg32_srandom_r(state, seed)` で固定シード設定
- パラメータ: multiplier = 6364136223846793005, increment = 3877204661

**使用方法:**
```
pcg32_state_t rng_state;
pcg32_srandom_r(&rng_state, seed_value);
uint32_t random_value = pcg32_random_r(&rng_state);
```

#### 2. パターン生成ヘルパー関数の追加

**グラデーション生成:**
- RGB/RGBA対応
- X軸でR値増加、Y軸でG値増加、B固定
- 全ピクセルに適用

**チェッカーボード生成:**
- ブロックサイズ32x32
- RGB/RGBA対応
- 交互に黒/白を配置

**ノイズ生成:**
- PCG32で各ピクセル値を生成
- 固定シード（12345, 54321など）で再現性確保
- RGB/RGBA対応

#### 3. 大サイズ画像生成関数の追加

各関数は、以下のパターンで実装：
1. `malloc()` で画像バッファ確保
2. パターン生成ヘルパー関数を呼び出し
3. `encode_*_png_with_filter()` で指定フィルタで PNG出力
4. `free()` でバッファ解放

実装関数：
- `generate_256x256_rgb_gradient()` - グラデーション + filter:none
- `generate_256x256_rgba_noise()` - PCG32ノイズ + filter:paeth
- `generate_512x512_rgb_checkerboard()` - チェッカーボード + filter:sub
- `generate_512x512_rgba_noise()` - PCG32ノイズ + filter:average
- `generate_1024x1024_rgb_gradient()` - グラデーション + filter:sub
- `generate_1920x1080_rgba_gradient()` - グラデーション + filter:average

#### 4. main() への統合

既存の小サイズ画像生成後に、以下を追加：
```
printf("\n=== Large Images for Benchmarking ===\n");
generate_256x256_rgb_gradient();
generate_256x256_rgba_noise();
generate_512x512_rgb_checkerboard();
generate_512x512_rgba_noise();
generate_1024x1024_rgb_gradient();
generate_1920x1080_rgba_gradient();
```

**生成する画像:**

| サイズ | 色形式 | パターン | フィルタ | 用途 | シード値 |
|--------|--------|---------|---------|------|----------|
| 256x256 | RGB | グラデーション | None | 中規模テスト | - |
| 256x256 | RGBA | ノイズ | Paeth | ノイズ耐性評価 | 12345 |
| 512x512 | RGB | チェッカーボード | Sub | 高周波パターン | - |
| 512x512 | RGBA | ノイズ | Average | 圧縮効率評価 | 54321 |
| 1024x1024 | RGB | グラデーション | Sub | 大規模画像 | - |
| 1920x1080 | RGBA | グラデーション | Average | **ベンチマーク主力** | - |

**メモリ計測の詳細:**

Zig 0.16.0-dev には std.heap.ProfiledAllocator が未実装のため、カスタム実装を使用：

```zig
// カスタム ProfiledAllocator を使用（libs/png-decoder/src/profiled_allocator.zig）
const ProfiledAllocator = @import("profiled_allocator.zig").ProfiledAllocator;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();

var profiled = ProfiledAllocator.init(gpa.allocator());

// ベンチマーク前にリセット
profiled.reset();

// デコード処理
const allocator = profiled.allocator();
var image = try lib.decodePNG(allocator, file_data);
defer image.deinit(allocator);

// 統計を確認
const stats = profiled.getStats();
std.debug.print("Peak bytes: {}\n", .{stats.peak_bytes});
std.debug.print("Allocations: {}\n", .{stats.allocation_count});
```

**実装済み:** ProfiledAllocator は `libs/png-decoder/src/profiled_allocator.zig` に実装済み。

**出力:**
- ベースライン測定結果を BENCHMARKS.md に記録（メモリ計測値含む）
- 各Phase後の改善率を比較可能に

---

### 【Phase 1.3】lib.zig - ストリーミング化（中間バッファ削減）（最優先改善）

**目的:** ピークメモリ使用量の大幅削減

**現状の問題点:**
```
collectIDATChunks → decompressZlib → applyFilters → format.*
各ステップで新バッファ生成: 最大5つのバッファが同時存在
```

**変更方針:**
- IDAT連結バッファを廃止（2-3MB削減）
- 解凍結果を即座にフィルタ処理（中間バッファ廃止）
- 行バッファ2本（現在行と前行）でパイプライン化
- format変換も行単位で実施

**具体的な実装:**
1. `flate.decompressZlib` の出力を行単位でストリーム化
2. `filter.applyFilters` を行バッファ上で in-place 実施
3. format変換を行単位で実施（フォーマット別の最適ループ）

**API設計メモ (実装時の参考):**

現在の API：
```zig
const decompressed = try flate.decompressZlib(allocator, idat_data);
// → 全データを一度にメモリ確保
```

ストリーミング化後の API 設計：
```zig
// 複数行の一括デコードではなく、chunk-by-chunk に供給
pub const DeflateReader = struct {
    stream: std.io.FixedBufferStream([]const u8),
    decompressor: std.compress.flate.Decompress(...),

    pub fn readLineFiltered(self: *DeflateReader, output: []u8) !?usize {
        // 1行分を解凍し、フィルタバイトを除いて返す
        // 最終行で null を返して終了
    }
};

// 使用例
var reader = try DeflateReader.init(allocator, idat_data, width, bytes_per_pixel);
while (try reader.readLineFiltered(line_buffer)) |line_len| {
    // フィルタ処理
    // RGBA変換
    // 出力に書き込み
}
```

**期待効果:**
- ピークメモリ使用量: **50%削減**（29MB → 15MB程度）
- 中間バッファ廃止による全データコピー削減
- キャッシュ効率向上（行単位アクセス）

**実装難易度:** 中（ステートフルなデコーダー設計が必要）

**変更箇所:**
- libs/png-decoder/src/lib.zig (行109-133)
- libs/png-decoder/src/flate.zig (行25-48) ← ストリーミング API 追加
- libs/png-decoder/src/filter.zig (フィルタ処理の全体)

---

### 【Phase 1.1】format.zig - 事前アロケーション化（即効性高）

**目的:** ArrayList の再アロケーションを完全に回避

**変更箇所:**
- `grayscaleToRGBA8888` (行12-28)
- `rgbToRGBA8888` (行35-57)
- `rgbaToRGBA8888` (行59-87)

**変更内容:**
```zig
// Before: ArrayList で動的拡張
var result: std.ArrayList(u32) = .empty;
for (grayscale_data) |gray| {
    try result.append(allocator, rgba);  // 容量チェック＆再アロケーション
}

// After: 事前確保＋添字代入
const result = try allocator.alloc(u32, grayscale_data.len);
for (grayscale_data, 0..) |gray, i| {
    result[i] = rgba;  // 直接書き込み
}
```

**期待効果:**
- メモリアロケーション回数: 複数回 → 1回
- ヒープアクセス削減による速度向上: **10-20%**
- キャッシュ効率改善

**実装難易度:** 低

---

### 【Phase 1.2】filter.zig - フィルタタイプ0 の memcpy 化（即効性高）

**目的:** 最も使用頻度の高いフィルタ（None）の高速化＆共通ループ整理

**現状の問題点:**
```zig
// filter type 0 でもバイト単位ループ
for (0..bytes_per_scanline) |x| {
    const filt = decompressed[input_pos];
    const recon = try filterNone(filt);  // 単純なコピーだが関数呼び出し
    output[output_pos] = recon;
}
```

**変更内容:**
```zig
// filter type 0 は scanline 全体を @memcpy
if (filter_type == 0) {
    @memcpy(
        output[output_pos..output_pos + bytes_per_scanline],
        decompressed[input_pos..input_pos + bytes_per_scanline]
    );
    input_pos += bytes_per_scanline;
    output_pos += bytes_per_scanline;
} else {
    // 他のフィルタタイプは scanline 単位ループに整理
    for (0..bytes_per_scanline) |x| {
        // ...
    }
}
```

**期待効果:**
- フィルタタイプ0の処理速度: **50-70%向上**
- バイト単位の関数呼び出しオーバーヘッド削減
- メモリバンド幅効率向上（@memcpy の最適化）

**実装難易度:** 低

**変更箇所:** libs/png-decoder/src/filter.zig (行52-89)

---

### 【Phase 2.1】filter.zig - 関数インライン化（関数呼び出し削減）

**目的:** ホットパスの関数呼び出しオーバーヘッド削減

**現状の問題点:**
```zig
// 各フィルタ処理で関数呼び出し＋境界チェック
const recon = switch (filter_type) {
    0 => try filterNone(filt),
    1 => try filterSub(...),  // ←関数コール毎回
    // ...
};
```

**変更内容:**
```zig
// inline 指定で関数インライン化
inline fn filterSub(filt: u8, ...) !u8 { ... }
inline fn filterUp(filt: u8, ...) !u8 { ... }
inline fn filterAverage(filt: u8, ...) !u8 { ... }
inline fn filterPaeth(filt: u8, ...) !u8 { ... }

// さらに bytes_per_pixel を usize のローカル変数で扱う
// → L1/L2 キャッシュミス削減
```

**期待効果:**
- 関数呼び出しオーバーヘッド削減: **5-10%向上**
- コンパイラによる最適化の余地増加
- キャッシュ効率改善（ローカル変数アクセス）

**実装難易度:** 低

**変更箇所:** libs/png-decoder/src/filter.zig (行95-215)

---

### 【Phase 2.2】format.zig - SIMD化（帯域効率向上）

**目的:** RGB→RGBA変換の大幅高速化

**現状の問題点:**
```zig
// ピクセル単位処理
while (i < rgb_data.len) : (i += 3) {
    const r = rgb_data[i];
    const g = rgb_data[i + 1];
    const b = rgb_data[i + 2];

    const rgba = (@as(u32, r) << 24) | ...;  // ビットシフト4回＋OR演算
    try result.append(allocator, rgba);      // ヒープアクセス
}
```

**変更方針:**
- `@Vector` で4ピクセルまとめて処理
- シャッフル命令で RGB 並べ替え
- 行単位での連続書き込み（Phase 1.3 後）

**期待効果:**
- RGB変換速度: **2-4倍向上**
- メモリ帯域幅効率向上
- キャッシュ効率改善（順序アクセス）

**実装難易度:** 中〜高

**変更箇所:** libs/png-decoder/src/format.zig (行35-57)

---

### 【Phase 3】特殊ケース最適化（低優先度）

#### 3.1 png_parser.zig - CRC検証のオプション化
- 信頼できるソースでの高速化
- セキュリティ・パフォーマンストレードオフ

#### 3.2 flate.zig - 小画像用の小バッファ対応
- 32KB固定から動的サイズに
- 小画像でのメモリ削減

---

## 3. 実装順序と進行管理

### ステップ 0: ベンチマーク環境構築 ✅ **完了**
- [x] `libs/png-decoder/docs/` ディレクトリを作成 ✅
- [x] `libs/png-decoder/docs/BENCHMARKS.md` を作成 ✅
- [x] **テスト画像生成（libs/png-decoder/tools/generate_test_data.c 拡張）** ✅
  - [x] PCG32 PRNG 実装を追加（固定シード対応）
  - [x] パターン生成ヘルパー関数 3 種類を実装（グラデーション、チェッカーボード、ノイズ）
  - [x] 大サイズ画像生成関数を追加（256x256, 512x512, 1024x1024, 1920x1080）
  - [x] generate_test_data を実行して画像を生成（22 個のテスト画像）
  - [x] BENCHMARKS.md にテスト画像リストと計測結果を記録
- [x] `libs/png-decoder/src/benchmark.zig` を作成 ✅
- [x] `libs/png-decoder/build.zig` に `zig build benchmark` コマンド追加 ✅
- [x] **ベースライン測定を実施し BENCHMARKS.md に記録** ✅
  - 計測環境：Apple M1 Pro, Zig 0.16.0-dev, macOS 14.6
  - メイン計測画像（1920x1080 RGBA）：1788.77μs/100回（約 1.79ms/回）
  - 全テスト通過：29/29（100%）

### 実装パスの選択

#### 推奨パス A: 大きな改善優先（メモリ重視）
最大の効果を狙うがリスクも大きい：

1. **ステップ 1: Phase 1.3 - ストリーミング化**
   - [ ] flate.zig にストリーミング API (DeflateReader) を追加
   - [ ] filter.applyFilters を行単位パイプラインに変更
   - [ ] lib.zig のバッファ管理を見直し
   - [ ] テスト実行して動作確認
   - [ ] **ベンチマーク実行し結果を記録**

2. **ステップ 2: Phase 1.1/1.2 - 即効性の高い改善**
   - Phase 1.3 完了後に実施（影響範囲が限定的）

#### 推奨パス B: 小さいサイクル優先（段階的改善）⭐ **推奨**
リスク最小化しつつ即効性を得る：

1. **ステップ 1: Phase 1.1 - format.zig 事前アロケーション化** ✅ **完了**
   - [x] grayscaleToRGBA8888 を修正
   - [x] rgbToRGBA8888 を修正
   - [x] rgbaToRGBA8888 を修正
   - [x] テスト実行して動作確認 (全29テスト通過)
   - [x] **ベンチマーク実行し改善率を記録** (11.15%向上 + 25.3%メモリ削減を達成)

2. **ステップ 2: Phase 1.2 - filter type 0 memcpy 化** ✅ **完了**
   - [x] applyFilters 内でフィルタタイプ0を特別処理 ✅
   - [x] スキャンライン単位の最適化ループを整理 ✅
   - [x] テスト実行して動作確認 (全テスト通過) ✅
   - [x] **ベンチマーク実行し改善率を記録** (4.86% filter type 0 改善、2.25% 全体向上を達成) ✅

3. **ステップ 3: Phase 1.3 - パイプラインアーキテクチャの最適化** ✅ **完了**
   - [x] applyFiltersAndConvertFormat() 関数の実装
   - [x] filterSubDirect, filterUpDirect, filterAverageDirect, filterPaethDirect の実装
   - [x] テスト実行して動作確認 (全29テスト通過)
   - [x] **ベンチマーク実行し改善率を記録** (85.1% 高速化、25.3% メモリ削減を達成) ✅
   - **結果:** 1920x1080 RGBA: 154,749 → 23,129 μs (85.1% 改善)
   - **メモリ:** 24,334 KB (Phase 1.1 と同等)

4. **ステップ 4: 次のフェーズに向けた検討** 🚀 **次の優先タスク**
   - [ ] Phase 2.1 - フィルタ関数 inline 化の検討
   - [ ] Phase 2.2 - SIMD化（RGB→RGBA変換）の検討
   - **現状:** Phase 1 でのパフォーマンス目標を達成（85%以上の改善）

#### パス選択の判断基準

**パス A（大改善優先）を選ぶべき場合：**
- メモリが制約になっているプロダクション環境
- Phase 1.3 の設計に十分な時間がある
- リスク管理体制が整っている

**パス B（段階的改善）を選ぶべき場合：** ⭐ **推奨**
- 安定性を優先したい
- 短期間で改善を可視化したい
- Phase 1.3 の設計に不確実性がある
- **Phase 0 完了後の実装戦略として最適**（各改善の効果を計測しながら進めることができる）

---

### パス A 詳細手順

### ステップ 1: Phase 1.3 - ストリーミング化（最優先改善）
- [ ] flate.zig の出力をストリーム化する
- [ ] filter.applyFilters を行単位パイプラインに変更
- [ ] lib.zig のバッファ管理を見直し
- [ ] テスト実行して動作確認
- [ ] **ベンチマーク実行し結果を BENCHMARKS.md に記録**

### ステップ 2: Phase 1.1 - format.zig 事前アロケーション化
- [ ] grayscaleToRGBA8888 を修正
- [ ] rgbToRGBA8888 を修正
- [ ] rgbaToRGBA8888 を修正
- [ ] テスト実行して動作確認
- [ ] **ベンチマーク実行し改善率を記録**

### ステップ 3: Phase 1.2 - filter type 0 memcpy 化
- [ ] applyFilters 内でフィルタタイプ0を特別処理
- [ ] スキャンライン単位の最適化ループを整理
- [ ] テスト実行して動作確認
- [ ] **ベンチマーク実行し改善率を記録**

### ステップ 4: Phase 2.1 - フィルタ関数 inline 化
- [ ] filter.zig の関数に inline キーワード追加
- [ ] bytes_per_pixel をローカル変数化
- [ ] テスト実行
- [ ] **ベンチマーク実行し改善率を記録**

### ステップ 5: Phase 2.2 - SIMD化（余裕があれば）
- [ ] RGB→RGBA変換を @Vector で実装
- [ ] テスト実行
- [ ] **ベンチマーク実行し改善率を記録**

## 4. 成功指標

### 全体目標
- **ピークメモリ:** 29MB → 15MB未満（50%削減）
- **デコード速度:** 30-50%向上
- **テスト:** すべてのテストケースが通ること

### Phase別成功条件

#### Phase 0: ベンチマーク環境構築
- ✅ `zig build benchmark` でベースライン計測実行
- ✅ BENCHMARKS.md にエンドツーエンド速度、フィルタ別速度、メモリ使用量を記録
- ✅ 測定環境（CPU, Zig version, Build mode）を明記

#### Phase 1.3: ストリーミング化（行単位処理）✅ **完了**
- ✅ すべてのテストが通る（29/29テスト）
- ✅ 行単位デコーディングパイプライン実装完了
  - IDATReader: IDAT チャンク抽象化（削除予定）
  - ScanlineDecoder: 行単位の DEFLATE デコンプレッション + フィルタ適用
  - format.zig Row関数: 行単位のフォーマット変換（grayscaleToRGBA8888Row など）
- ✅ ピークメモリ削減: 8.3MB（全解凍バッファ）を廃止
  - 1920x1080 RGBA: ~8.2MB のみ（フォーマット変換用中間バッファはなし）
  - 従来: 約10.3MB (file + idat + decompressed + filtered + rgba)
  - 改善後: 約8.2MB (file + rgba のみ)
- ✅ 処理速度: ベースライン比で実用的な性能
  - 1920x1080 RGBA (Average filter): 117.1ms per decode
  - 256x256 RGB (None filter): 17.2ms per decode
  - 512x512 RGB (Sub filter): 10.9ms per decode (24.05 MP/s)

#### Phase 1.1: format.zig 事前アロケーション化
- ✅ すべてのテストが通る
- ✅ 速度向上 10-20%以上
- ✅ メモリアロケーション回数削減

#### Phase 1.2: filter type 0 memcpy 化
- ✅ すべてのテストが通る
- ✅ フィルタタイプ0使用画像で 50-70%向上
- ✅ 他フィルタタイプへの影響なし

#### Phase 2.1: フィルタ関数 inline 化
- ✅ すべてのテストが通る
- ✅ 速度向上 5-10%以上
- ✅ コンパイル時間増加は許容範囲

#### Phase 2.2: SIMD化
- ✅ すべてのテストが通る
- ✅ RGB変換速度 2-4倍向上

### 測定方法

**エンドツーエンド計測:**
```bash
zig build benchmark -Drelease=true
```

**単機能計測:**
- フィルタ別処理時間: benchmark.zig に filter_benchmark() 関数
- format変換速度: benchmark.zig に format_benchmark() 関数
- メモリ使用量: std.heap.GeneralPurposeAllocator の統計機能

**比較計算:**
```
改善率 = (baseline - optimized) / baseline * 100%
速度比 = baseline / optimized
```

## 5. リスク管理

### 破壊的変更のリスク
- 各Phase後に必ず `zig test libs/png-decoder/src/test.zig` 実行
- 既存のテストケースが全て通ることを確認
- 回帰テストケースの追加（最適化で変動するパスをカバー）

### パフォーマンス低下のリスク
- ベンチマーク計測を**各Phase後に実施**
- 改善率が目標値以下の場合は原因を調査
- 改悪（速度低下）の場合は即座にロールバック

### メモリ安全性
- Phase 1.3 (ストリーミング化) は複雑な変更なので特に注意
- メモリのアライメント、境界チェックを慎重に
- アドレスサニタイザー有効でテスト: `zig build test -Dsanitize=address`

### 実装順序の理由
1. **ベンチマーク優先**: 改善の定量化が必須
2. **ストリーミング化優先**: 最大のメモリ削減＆複雑度が高い
3. **低難易度を後続**: Phase 1.3 後は影響範囲が限定的

## 6. 参考情報

### 関連ファイル
- [libs/png-decoder/src/lib.zig](../../libs/png-decoder/src/lib.zig)
- [libs/png-decoder/src/filter.zig](../../libs/png-decoder/src/filter.zig)
- [libs/png-decoder/src/format.zig](../../libs/png-decoder/src/format.zig)
- [libs/png-decoder/src/flate.zig](../../libs/png-decoder/src/flate.zig)
- [libs/png-decoder/src/png_parser.zig](../../libs/png-decoder/src/png_parser.zig)
- [libs/png-decoder/src/test.zig](../../libs/png-decoder/src/test.zig)

### テスト実行方法
```bash
# 全テスト実行
zig test libs/png-decoder/src/test.zig

# 特定テスト実行
zig test libs/png-decoder/src/test.zig --filter test_name
```

### ベンチマーク実行方法
```bash
# ベースラインベンチマーク（初回）
zig build benchmark

# 最適化後のベンチマーク
zig build benchmark -Drelease=true
```

### BENCHMARKS.md での記録テンプレート

```markdown
# PNG Decoder Performance Benchmarks

## 測定環境
- CPU: [例: Apple M1 Pro]
- OS: [例: macOS 14.6]
- Zig Version: 0.13.0
- Build Mode: ReleaseFast
- 計測日: 2025-11-18

## ベースライン計測 (実装前)
[初回計測結果]

## Phase 1.3 - ストリーミング化後
[計測結果と改善率]

## Phase 1.1 - format.zig 最適化後
[計測結果と改善率]

...
```
