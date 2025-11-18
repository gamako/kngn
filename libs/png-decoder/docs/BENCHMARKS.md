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

| ファイル名 | 解像度 | 色形式 | フィルタ | ファイルサイズ | 用途 |
|-----------|--------|--------|---------|--------------|------|
| 1x1_grayscale_filter_none.png | 1x1 | Grayscale | None | - | 最小ケース |
| 8x8_grayscale_filter_sub.png | 8x8 | Grayscale | Sub | - | 小画像 |
| 16x16_rgb_gradient_filter_none.png | 16x16 | RGB | None | - | 典型的 RGB |
| 16x16_rgba_mixed_filters.png | 16x16 | RGBA | Mixed | - | 複合フィルタ |
| 256x256_grayscale_paeth.png | 256x256 | Grayscale | Paeth | - | 中規模 |
| [実際の画像をリスト化] | | | | | |

**注:** test-data/ に存在するイメージファイルから選定

---

## ベースライン計測 (実装前)

**計測日:** 2025-11-18
**計測環境:**
- CPU: Apple M1 Pro
- OS: macOS 14.6
- Zig Version: 0.16.0-dev.747+493ad58ff
- Build Mode: Debug
- マシン: Gamako's MacBook Pro

### エンドツーエンドデコード速度

| Image File | Image Size | Format    | Filter  | Time (μs) | Throughput (MP/s) | Note |
|------------|------------|-----------|---------|-----------|-------------------|------|
| 1x1_grayscale.png | 1x1 | Grayscale | None | 19.78 | 0.00 | 最小テストケース |
| 8x8_gray_filter_none.png | 8x8 | Grayscale | None | 20.26 | 0.00 | 小規模画像 |
| 16x16_gray_filter_none.png | 16x16 | Grayscale | None | 25.00 | 0.01 | 小規模画像 |
| 256x256_rgb_gradient_filter_none.png | 256x256 | RGB | None | 214.52 | 0.03 | 中規模画像 |
| 256x256_rgba_noise_filter_paeth.png | 256x256 | RGBA | Paeth | 333.61 | 0.02 | ノイズ + 複雑フィルタ |
| 512x512_rgb_checkerboard_filter_sub.png | 512x512 | RGB | Sub | 200.15 | 0.13 | 高周波パターン |
| 512x512_rgba_noise_filter_average.png | 512x512 | RGBA | Average | 976.08 | 0.03 | ノイズ + Average フィルタ |
| 1024x1024_rgb_gradient_filter_sub.png | 1024x1024 | RGB | Sub | 671.82 | 0.16 | 大規模画像 |
| 1920x1080_rgba_gradient_filter_average.png | 1920x1080 | RGBA | Average | 1788.77 | 0.12 | ベンチマーク主力 |

**計測方法:**
- std.time.Timer でデコード処理時間を計測
- 各イメージ 100 回実行の平均時間
- ウォームアップ実行 1 回（結果除外）
- メモリ計測は未実装（今後 ProfiledAllocator で追加予定）

### フィルタタイプ別の処理時間

| Filter Type | Time (ns) | Relative | 使用イメージ |
|-------------|-----------|----------|-----------|
| None (0)    |           | baseline | 16x16_rgb_gradient_filter_none.png |
| Sub (1)     |           |          | 8x8_grayscale_filter_sub.png |
| Up (2)      |           |          | [該当イメージ] |
| Average (3) |           |          | [該当イメージ] |
| Paeth (4)   |           |          | 256x256_grayscale_paeth.png |

### メモリ使用量詳細

| Image | Peak Memory (KB) | GPA Stats | ProfiledAllocator Peak (KB) | Allocations |
|-------|-----------------|-----------|---------------------------|-------------|
| 1x1 grayscale | | | | |
| 256x256 RGBA | | | | |
| Mixed filters | | | | |

---

## Phase 0: ベンチマーク環境構築完了後

ベースライン計測の詳細結果をここに記録します。

---

## Phase 1.3: ストリーミング化後

**計測日:**

**改善率:**
- ピークメモリ: __ % 削減
- 処理速度: __ % 変化

**詳細:**

---

## Phase 1.1: format.zig 事前アロケーション化後

**計測日:**

**改善率:**
- 処理速度: __ % 向上
- メモリアロケーション: __ 回数削減

**詳細:**

---

## Phase 1.2: filter type 0 memcpy化後

**計測日:**

**改善率:**
- フィルタタイプ0処理: __ % 向上
- 全体処理: __ % 向上

**詳細:**

---

## Phase 2.1: フィルタ関数inline化後

**計測日:**

**改善率:**
- 処理速度: __ % 向上

**詳細:**

---

## Phase 2.2: SIMD化後

**計測日:**

**改善率:**
- RGB変換速度: __ % 向上

**詳細:**

---

## 最終結果サマリー

| 指標 | ベースライン | 最適化後 | 改善率 |
|------|------------|--------|--------|
| ピークメモリ | 29MB | __ MB | __ % |
| 処理速度 | __ μs | __ μs | __ % |

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
- ✅ zig test libs/png-decoder/src/test.zig: PASS
- ✅ 全テストケース通過
```

---

## 実装時の注意点

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

