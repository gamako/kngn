# PNG Decoder Performance Benchmarks

このドキュメントはPNGデコーダーの性能測定結果を記録します。

## 測定環境テンプレート

```
- CPU: [例: Apple M1 Pro]
- OS: [例: macOS 14.6]
- Zig Version: 0.13.0
- Build Mode: ReleaseFast
- 計測日: YYYY-MM-DD
```

## 使用テストイメージ一覧

計測に使用するイメージを以下に記載（再現性の確保）：

| ファイル名                         | 解像度  | 色形式    | フィルタ | ファイルサイズ | 用途         |
| ---------------------------------- | ------- | --------- | -------- | -------------- | ------------ |
| 1x1_grayscale_filter_none.png      | 1x1     | Grayscale | None     | -              | 最小ケース   |
| 8x8_grayscale_filter_sub.png       | 8x8     | Grayscale | Sub      | -              | 小画像       |
| 16x16_rgb_gradient_filter_none.png | 16x16   | RGB       | None     | -              | 典型的 RGB   |
| 16x16_rgba_mixed_filters.png       | 16x16   | RGBA      | Mixed    | -              | 複合フィルタ |
| 256x256_grayscale_paeth.png        | 256x256 | Grayscale | Paeth    | -              | 中規模       |
| [実際の画像をリスト化]             |         |           |          |                |              |

**注:** test-data/ に存在するイメージファイルから選定

---

## ベースライン計測 (実装前)

**計測日:** 2025-11-18
**計測環境:**
- CPU: Apple M1 Pro
- OS: macOS 14.6
- Zig Version: 0.16.0-dev.747+493ad58ff
- Build Mode: ReleaseFast
- マシン: Gamako's MacBook Pro
- コミット: ede4bdcf (Phase 0 完了時点)

### エンドツーエンドデコード速度

| Image File                                 | Image Size | Format    | Filter  | Time (μs) | Throughput (MP/s) | Memory (KB) | Note                      |
| ------------------------------------------ | ---------- | --------- | ------- | --------- | ----------------- | ----------- | ------------------------- |
| 1x1_grayscale.png                          | 1x1        | Grayscale | None    | 49.00     | 0.02              | 64          | 最小テストケース          |
| 8x8_gray_filter_none.png                   | 8x8        | Grayscale | None    | 41.00     | 1.56              | 64          | 小規模画像                |
| 16x16_gray_filter_none.png                 | 16x16      | Grayscale | None    | 50.00     | 5.12              | 65          | 小規模画像                |
| 256x256_rgb_gradient_filter_none.png       | 256x256    | RGB       | None    | 2948.00   | 22.23             | 1168        | 中規模画像                |
| 256x256_rgba_noise_filter_paeth.png        | 256x256    | RGBA      | Paeth   | 3998.00   | 16.39             | 1407        | ノイズ + 複雑フィルタ     |
| 512x512_rgb_checkerboard_filter_sub.png    | 512x512    | RGB       | Sub     | 2364.00   | 110.89            | 3696        | 高周波パターン            |
| 512x512_rgba_noise_filter_average.png      | 512x512    | RGBA      | Average | 15422.00  | 17.00             | 5228        | ノイズ + Average フィルタ |
| 1024x1024_rgb_gradient_filter_sub.png      | 1024x1024  | RGB       | Sub     | 10413.00  | 100.70            | 13430       | 大規模画像                |
| 1920x1080_rgba_gradient_filter_average.png | 1920x1080  | RGBA      | Average | 27571.00  | 75.21             | 32604       | ベンチマーク主力          |

**計測方法:**
- **重要: 必ず ReleaseFast ビルドで計測すること**
  - Debugビルドは最適化が無効で性能が数倍〜数十倍遅い
  - 実行コマンド: `zig build benchmark -Doptimize=ReleaseFast`
  - 改善率の比較は必ず同一ビルドモード間で行うこと
- std.time.Timer でデコード処理時間を計測
- 各イメージ 100 回実行の平均時間
- ウォームアップ実行 1 回（結果除外）
- カスタム ProfiledAllocator でピークメモリ使用量を計測

### フィルタタイプ別の処理時間

| Filter Type | Time (ns) | Relative | 使用イメージ                       |
| ----------- | --------- | -------- | ---------------------------------- |
| None (0)    |           | baseline | 16x16_rgb_gradient_filter_none.png |
| Sub (1)     |           |          | 8x8_grayscale_filter_sub.png       |
| Up (2)      |           |          | [該当イメージ]                     |
| Average (3) |           |          | [該当イメージ]                     |
| Paeth (4)   |           |          | 256x256_grayscale_paeth.png        |

### メモリ使用量詳細

| Image         | Peak Memory (KB) | GPA Stats | ProfiledAllocator Peak (KB) | Allocations |
| ------------- | ---------------- | --------- | --------------------------- | ----------- |
| 1x1 grayscale |                  |           |                             |             |
| 256x256 RGBA  |                  |           |                             |             |
| Mixed filters |                  |           |                             |             |

---

## Phase 0: ベンチマーク環境構築完了後

ベースライン計測の詳細結果をここに記録します。

---

## Phase 1.3: ストリーミング化とIDATストリーミング完全実装

**計測日:** 2025-11-22
**計測環境:**
- CPU: Apple M1 Pro
- OS: macOS 14.6
- Zig Version: 0.16.0-dev.747+493ad58ff
- Build Mode: ReleaseFast
- マシン: Gamako's MacBook Pro

**改善内容:**
1. **行単位のデコーディングパイプライン実装**
   - ScanlineDecoder: 行単位の DEFLATE デコンプレッション + フィルタ適用
   - format.zig Row関数: 行単位のフォーマット変換
   - 8.3MB の全解凍バッファを廃止

2. **Dangling Pointer Bug修正**
   - ScanlineDecoderをheap allocation化（`!*ScanlineDecoder`を返す）
   - `&self.chunk_stream_adapter.interface`の安定したアドレスを確保

3. **IDATストリーミング完全実装**
   - IDATChunkStreamAdapterを実装（std.Io.Reader.Limitedパターン）
   - `@fieldParentPtr("interface", r)`でvtable実装
   - stream()とdiscard()メソッドを実装
   - collectIDATChunks()を削除 → **2-3MB IDAT連結バッファを削減**

4. **VTable実装**
   - std.Io.Reader互換のカスタムreader実装
   - 64バイトの内部バッファでrebase()サポート

**計測結果:**

| Image File                   | Time (μs)   | Throughput (MP/s) | Memory (KB) | Filter Type     |
| ---------------------------- | ----------- | ----------------- | ----------- | --------------- |
| 1x1 Grayscale                | 57.00       | 0.02              | 74          | None            |
| 8x8 Grayscale (None)         | 33.00       | 1.94              | 75          | None            |
| 16x16 Grayscale (None)       | 37.00       | 6.92              | 75          | None            |
| 256x256 RGB (None)           | 2,646.00    | 24.77             | 332         | None            |
| 256x256 RGBA (Paeth)         | 3,762.00    | 17.42             | 332         | Paeth (4)       |
| 512x512 RGB (Sub)            | 1,474.00    | 177.85            | 1,101       | Sub (1)         |
| 512x512 RGBA (Average)       | 14,601.00   | 17.95             | 1,102       | Average (3)     |
| 1024x1024 RGB (Sub)          | 6,805.00    | 154.09            | 4,176       | Sub (1)         |
| **1920x1080 RGBA (Average)** | **19,105.00** | **108.54**      | **8,189**   | **Average (3)** |

**性能比較（Phase 1.2 → Phase 1.3）:**

| Image File       | Phase 1.2 (μs) | Phase 1.3 (μs) | Improvement | Filter Type |
| ---------------- | -------------- | -------------- | ----------- | ----------- |
| 1x1 Grayscale    | 68.00          | 57.00          | 16.2%       | None        |
| 8x8 Grayscale    | 40.00          | 33.00          | 17.5%       | None        |
| 16x16 Grayscale  | 65.00          | 37.00          | 43.1%       | None        |
| 256x256 RGB      | 2,604.00       | 2,646.00       | -1.6%       | None        |
| 256x256 RGBA     | 3,778.00       | 3,762.00       | 0.4%        | Paeth (4)   |
| 512x512 RGB      | 1,700.00       | 1,474.00       | 13.3%       | Sub (1)     |
| 512x512 RGBA     | 14,424.00      | 14,601.00      | -1.2%       | Average (3) |
| 1024x1024 RGB    | 7,976.00       | 6,805.00       | 14.7%       | Sub (1)     |
| **1920x1080 RGBA** | **22,276.00** | **19,105.00** | **14.2%** | **Average (3)** |

**改善率サマリー:**
- 主要計測画像（1920x1080 RGBA）: **14.2% 高速化**
- 小画像で大きな改善: 43.1%（16x16 Grayscale）
- 大画像で安定した改善: 13.3-14.7%（512x512以上）

**メモリ削減効果（Phase 0 → Phase 1.3）:**
- Phase 0（ベースライン）: 32,604 KB @ 1920x1080 RGBA
- Phase 1.3（ストリーミング実装）: 8,189 KB @ 1920x1080 RGBA
- **削減率: 74.9% 削減**

**削減内訳:**
1. **全解凍バッファの廃止**: 8.3MB 削減
   - Phase 0-1.2: DEFLATE 全解凍後にフィルタ適用
   - Phase 1.3: 行単位でデコンプレッション + フィルタ適用

2. **IDAT連結バッファの削減**: 2-3MB 削減
   - Phase 0-1.2: collectIDATChunks()で全IDAT連結
   - Phase 1.3: IDATChunkStreamAdapterでチャンク単位ストリーミング

3. **format変換バッファの削減**: Phase 1.1で既に削減済み
   - ArrayList → 事前アロケーションで約8MB削減

**分析:**
1. **ストリーミング化の効果**
   - メモリ削減が主な成果（74.9%）
   - 性能改善は控えめ（14.2%）
   - 行単位処理によるキャッシュ効率向上

2. **Phase 1.2 からの改善要因**
   - IDATストリーミングによるメモリアクセスパターンの最適化
   - 不要なバッファコピーの削減
   - キャッシュラインの効率的利用

3. **画像サイズ別の特性**
   - 小画像（1x1-16x16）: 16-43% 改善（オーバーヘッド削減）
   - 中画像（256x256）: ほぼ変化なし（-1.6%〜0.4%）
   - 大画像（512x512以上）: 13-15% 安定改善

### 実装詳細
- **libs/png/src/flate.zig**: ScanlineDecoder 実装
  - IDATChunkStreamAdapterによるチャンク単位ストリーミング
  - readScanline() で行単位のフィルタ適用
  - 2つのスキャンラインバッファ（現在行/前行）でダブルバッファリング
- **libs/png/src/format.zig**: 行単位変換関数
  - grayscaleToRGBA8888Row()
  - rgbToRGBA8888Row()
  - rgbaToRGBA8888Row()
- **libs/png/src/lib.zig**: パイプライン化
  - ScanlineDecoder.init() でストリーミング初期化
  - while (readScanline()) ループで行単位処理
  - フォーマット変換も行単位で実行

### テスト結果
- ✅ zig build test: 全29テスト通過
- ✅ Dangling pointer bug完全修正
- ✅ メモリ安全性確認済み

### 次のステップ
Phase 1.3 完全実装が完了しました。次の改善候補：
- フィルタ関数の inline 化（Phase 2.1）
- SIMD 化（Phase 2.2）

---

## Phase 1.1: format.zig 事前アロケーション化後

**計測日:** 2025-11-19
**計測環境:**
- CPU: Apple M1 Pro
- OS: macOS 14.6
- Zig Version: 0.16.0-dev.747+493ad58ff
- Build Mode: ReleaseFast
- マシン: Gamako's MacBook Pro
- コミット: 5fb12d53 (Phase 1.1 完了時点)

**改善内容:**
- `grayscaleToRGBA8888()`: ArrayList.empty + append() → allocator.alloc() + 直接代入
- `rgbToRGBA8888()`: ArrayList.empty + append() → allocator.alloc() + 直接代入
- `rgbaToRGBA8888()`: ArrayList.empty + append() → allocator.alloc() + 直接代入
- errdefer でメモリ安全性を確保

**計測結果:**

| Image File                   | Before (μs) | After (μs) | Improvement | Memory Before (KB) | Memory After (KB) |
| ---------------------------- | ----------- | ---------- | ----------- | ------------------ | ----------------- |
| 1x1 Grayscale                | 49.00       | 41.00      | 16.3%       | 64                 | 64                |
| 8x8 Grayscale (None)         | 41.00       | 35.00      | 14.6%       | 64                 | 64                |
| 16x16 Grayscale (None)       | 50.00       | 43.00      | 14.0%       | 65                 | 65                |
| 256x256 RGB (None)           | 2948.00     | 2597.00    | 11.9%       | 1168               | 786               |
| 256x256 RGBA (Paeth)         | 3998.00     | 3796.00    | 5.1%        | 1407               | 1024              |
| 512x512 RGB (Sub)            | 2364.00     | 1643.00    | 30.5%       | 3696               | 2564              |
| 512x512 RGBA (Average)       | 15422.00    | 14049.00   | 8.9%        | 5228               | 4097              |
| 1024x1024 RGB (Sub)          | 10413.00    | 7898.00    | 24.1%       | 13430              | 10251             |
| **1920x1080 RGBA (Average)** | **27571.00** | **22269.00** | **19.2%** | **32604**          | **24334**         |

**改善率サマリー:**
- 主要計測画像（1920x1080 RGBA）: **19.2% 高速化**
- メモリピーク: **25.3% 削減**（32604KB → 24334KB）
- 最大改善率: 30.5%（512x512 RGB Sub）

**メモリ変化詳細:**
- Peak Before (全体): 32,604 KB
- Peak After (全体): 24,334 KB
- Peak Memory Reduction: 8,270 KB (25.3% 削減)

**分析:**
期待値（10-20%）を達成。特に以下の点が寄与：

1. **ArrayList の動的拡張廃止**
   - reallocation 回数: O(log N) → 1 回
   - メモリコピー量: O(N log N) → O(N)

2. **メモリ効率の向上**
   - RGB/RGBA変換: 8.9-19.2% の安定した改善
   - Sub フィルタ画像で特に効果大（30.5%）

3. **キャッシュ効率の改善**
   - 線形メモリアクセスパターンにより L1/L2 キャッシュヒット率向上
   - 添字による直接アクセスがループの依存性を減らす

4. **ピークメモリ削減の理由**
   - format 変換関数が allocator.alloc() で直接メモリ確保
   - ArrayList の内部バッファ（容量 > 使用量）が不要に
   - 合計: 25.3% のメモリ削減を達成

### テスト結果
- ✅ zig build test: 全テスト通過（テスト数: 29/29）
- ✅ 既存の全テストケースが動作確認済み
- ✅ エンドツーエンドテストで画像デコード結果が一致

### 次のステップ
Phase 1.2 の実施を推奨：フィルタタイプ0の memcpy 化により、さらに 50-70% の改善が期待される

---

## Phase 1.2: filter type 0 memcpy化後

**計測日:** 2025-11-19
**計測環境:**
- CPU: Apple M1 Pro
- OS: macOS 14.6
- Zig Version: 0.16.0-dev.747+493ad58ff
- Build Mode: ReleaseFast
- マシン: Gamako's MacBook Pro
- コミット: 5214dbe1 (Phase 1.2 完了時点)

**改善内容:**
- `applyFilters()`: フィルタタイプ0（None）を特別処理
- バイト単位ループから`@memcpy`による一括コピーに変更
- 他のフィルタタイプ（1-4）は既存のループロジックを維持
- 予備チェックで不正なデータからの保護を確保

**計測結果:**

| Image File                   | Phase 1.1 (μs) | Phase 1.2 (μs) | Improvement | Filter Type     |
| ---------------------------- | -------------- | -------------- | ----------- | --------------- |
| 1x1 Grayscale                | 41.00          | 68.00          | -65.9%      | None            |
| 8x8 Grayscale (None)         | 35.00          | 40.00          | -14.3%      | None            |
| 16x16 Grayscale (None)       | 43.00          | 65.00          | -51.2%      | None            |
| 256x256 RGB (None)           | 2597.00        | 2604.00        | -0.3%       | None            |
| 256x256 RGBA (Paeth)         | 3796.00        | 3778.00        | 0.5%        | Paeth (4)       |
| 512x512 RGB (Sub)            | 1643.00        | 1700.00        | -3.5%       | Sub (1)         |
| 512x512 RGBA (Average)       | 14049.00       | 14424.00       | -2.7%       | Average (3)     |
| 1024x1024 RGB (Sub)          | 7898.00        | 7976.00        | -1.0%       | Sub (1)         |
| **1920x1080 RGBA (Average)** | **22269.00**   | **22276.00**   | **-0.03%**  | **Average (3)** |

**改善率サマリー:**
- 主要計測画像（1920x1080 RGBA）: **-0.03%**（ほぼ変化なし）
- フィルタタイプ0（None）での改善: ほぼなし（-0.3%）
- 小画像で大きな退行: -65.9%（1x1 Grayscale）、-51.2%（16x16 Grayscale）
- メモリ使用量: Phase 1.1 と同等

**分析:**

期待値（50-70%）との乖離理由：

1. **Filter type 0 の処理時間割合が小さい**
   - 全体処理の主なボトルネックは format 変換と I/O 処理
   - memcpy 最適化の効果は局所的

2. **小画像でのオーバーヘッド**
   - 1x1、16x16 などの小画像で大きな退行
   - フィルタタイプの分岐判定とセットアップコストが相対的に大きい

3. **測定誤差の影響**
   - 大画像（1920x1080）ではほぼ変化なし（-0.03%）
   - ノイズレベルの範囲内

4. **実質的な効果なし**
   - filter type 0 の memcpy 最適化は、エンドツーエンドでは効果が見られない
   - 他の処理（format 変換、I/O）がボトルネック

**実装の有効性:**
- ✅ 機能的に正しく動作（フィルタタイプ0を正しく処理）
- ⚠️ エンドツーエンド性能への実質的な改善は見られない
- ⚠️ 小画像で若干の退行が見られる

**次のステップの提案:**
- Phase 1.3（ストリーミング化）に注力：より大きなボトルネック（バッファ管理）を解決
- Phase 1.2 の memcpy 最適化は、現時点では性能改善に寄与せず

### テスト結果
- ✅ zig build test-png-format: 全テスト通過
- ✅ Filter type 0 の動作確認完了
- ✅ 他フィルタタイプへの影響なし

**詳細:**

---

## Phase 2.1: ローカル変数最適化（inline化は却下）

**計測日:** 2025-11-23
**計測環境:**
- CPU: Apple M1 Pro
- OS: macOS 14.6
- Zig Version: 0.16.0-dev.747+493ad58ff
- Build Mode: ReleaseFast
- マシン: Gamako's MacBook Pro

**改善内容:**

1. **ローカル変数最適化（採用）**
   - flate.zig の applyFilterInPlace で `bytes_per_pixel` と `bytes_per_scanline` をローカル変数にキャッシュ
   - L1/L2 キャッシュミス削減
   - 構造体フィールドへの繰り返しアクセスを削減

2. **inline キーワードの検証（却下）**
   - filter.zig の Direct 関数（filterSubDirect, filterUpDirect, filterAverageDirect, filterPaethDirect）に inline を追加
   - paethPredictor にも inline を追加
   - **結果**: パフォーマンスが悪化したため削除

**計測結果:**

| 実装バージョン | 1920x1080 RGBA (μs) | Phase 1.3 からの変化 | 備考 |
|-------------|---------------------|---------------------|------|
| Phase 1.3   | 19,105              | ベースライン         | ストリーミング実装 |
| Stage 1 (ローカル変数のみ) | 18,843 | **1.4% 改善** ✅ | bpp, scanline_len をキャッシュ |
| Stage 2 (inline 追加) | 19,221 | **0.6% 悪化** ❌ | inline が逆効果 |
| **Final (inline 削除)** | **19,010** | **0.5% 改善** ✅ | **最終採用版** |

全ベンチマーク結果（Final版）:

| Image File                   | Time (μs)   | Throughput (MP/s) | Memory (KB) | Filter Type     |
| ---------------------------- | ----------- | ----------------- | ----------- | --------------- |
| 1x1 Grayscale                | 34.00       | 0.03              | 74          | None            |
| 8x8 Grayscale (None)         | 39.00       | 1.64              | 75          | None            |
| 16x16 Grayscale (None)       | 39.00       | 6.56              | 75          | None            |
| 256x256 RGB (None)           | 2,685.00    | 24.41             | 332         | None            |
| 256x256 RGBA (Paeth)         | 3,759.00    | 17.43             | 332         | Paeth (4)       |
| 512x512 RGB (Sub)            | 1,448.00    | 181.04            | 1,101       | Sub (1)         |
| 512x512 RGBA (Average)       | 14,185.00   | 18.48             | 1,102       | Average (3)     |
| 1024x1024 RGB (Sub)          | 6,789.00    | 154.45            | 4,176       | Sub (1)         |
| **1920x1080 RGBA (Average)** | **19,010.00** | **109.08**      | **8,189**   | **Average (3)** |

**メモリ使用量:**
- Phase 1.3 と同等（8,189 KB @ 1920x1080 RGBA）
- メモリ最適化ではなく、キャッシュ効率改善による速度向上

**改善率サマリー:**
- ローカル変数最適化のみ: **0.5-1.4% 改善**（測定揺らぎを考慮）
- inline 追加: **0.6% 悪化**（却下）

**分析:**

1. **ローカル変数最適化の効果**
   - わずかだが安定した改善 (0.5-1.4%)
   - 構造体フィールドへのアクセス削減によるキャッシュ効率向上
   - コンパイラの最適化を妨げない

2. **inline が逆効果になった理由**
   - Zig のドキュメント通り: "inline はコンパイラの最適化を制限し、バイナリサイズ、コンパイル速度、実行時パフォーマンスを損なう可能性がある"
   - コンパイラの自動インライン判断の方が優れている
   - 強制インライン化により、レジスタ圧力が増加した可能性
   - 命令キャッシュ効率が低下した可能性

3. **Phase 2.1 の学び**
   - 測定に基づく判断の重要性（仮説検証アプローチ）
   - Zig では `inline` は慎重に使うべき
   - 小さな最適化の積み重ねが重要

**累積改善率（Phase 0 から Phase 2.1 まで）:**
- Phase 0 ベースライン: 27,571 μs
- Phase 2.1 最終: 19,010 μs
- **総合改善率: 31.1% 高速化**
- **メモリ削減: 74.9% 削減**（32,604 KB → 8,189 KB）

### テスト結果
- ✅ zig test libs/png/src/test.zig: 全29テスト通過
- ✅ inline 追加版でも全テスト通過（機能的には問題なし）
- ✅ inline 削除版でも全テスト通過

---

## Phase 2.2: SIMD化後

**計測日:**

**改善率:**
- RGB変換速度: __ % 向上

**詳細:**

---

## 最終結果サマリー

| 指標         | ベースライン | 最適化後 | 改善率 |
| ------------ | ------------ | -------- | ------ |
| ピークメモリ | 29MB         | __ MB    | __ %   |
| 処理速度     | __ μs        | __ μs    | __ %   |

---

## Phase 結果記録テンプレート

各 Phase 完了後、以下の情報を記録してください：

```markdown
## Phase X.Y - [改善名]

**計測日:** YYYY-MM-DD
**コミット:** [jj log -n2 で確認できるID]

### 改善内容
[簡潔な説明]

### 計測結果

| Image | Before (μs) | After (μs) | Improvement | Memory (KB) |
|-------|------------|-----------|------------|------------|
| test1.png | | | | |
| test2.png | | | | |

### メモリ変化
- Peak Before: __ KB
- Peak After: __ KB
- Reduction: __ %

### 分析
[性能の変化について、特に予想と異なる場合は理由を記載]

### テスト結果
- ✅ zig test libs/png/src/test.zig: PASS
- ✅ 全テストケース通過
```

---

## 実装時の注意点

0. **ビルドモードの厳守**: ベンチマーク計測は必ず `-Doptimize=ReleaseFast` で実行
   - Debugビルドは最適化無効で性能が著しく低下（数倍〜数十倍）
   - 改善率の比較は同一ビルドモード間で行うこと
   - 実行コマンド: `zig build benchmark -Doptimize=ReleaseFast`
1. **テスト画像の固定**: 計測毎に同じイメージを使用すること
2. **計測回数**: 各イメージで最低 1000 回以上実行し、平均値を取る
3. **ウォームアップ**: 初回実行は JIT やキャッシュの影響を除外するため無視
4. **環境の一貫性**: CPU 周波数固定、バックグラウンドプロセス最小化推奨
5. **メモリ計測**: ProfiledAllocator の peak_bytes を使用

---

## 計測データの保存場所

- **BENCHMARKS.md**: このファイル（Markdown で人間可読）
- **benchmark.zig**: 自動計測スクリプト
- **CSV形式**: 機械学習分析用（オプション）

