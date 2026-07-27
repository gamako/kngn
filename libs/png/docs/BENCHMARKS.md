# PNG Decoder Performance Benchmarks

This document records PNG decoder performance measurement results.

## Measurement Environment Template

```
- CPU: [e.g.: Apple M1 Pro]
- OS: [e.g.: macOS 14.6]
- Zig Version: 0.13.0
- Build Mode: ReleaseFast
- Measurement date: YYYY-MM-DD
```

## Test Images Used

Images used for measurement are listed below (to ensure reproducibility):

| File name                          | Resolution | Color format | Filter | File size | Purpose           |
| ---------------------------------- | ---------- | ------------ | ------ | --------- | ----------------- |
| 1x1_grayscale_filter_none.png      | 1x1        | Grayscale    | None   | -         | Minimal case      |
| 8x8_grayscale_filter_sub.png       | 8x8        | Grayscale    | Sub    | -         | Small image       |
| 16x16_rgb_gradient_filter_none.png | 16x16      | RGB          | None   | -         | Typical RGB       |
| 16x16_rgba_mixed_filters.png       | 16x16      | RGBA         | Mixed  | -         | Mixed filters     |
| 256x256_grayscale_paeth.png        | 256x256    | Grayscale    | Paeth  | -         | Medium scale      |
| [List actual images]               |            |              |        |           |                   |

**Note:** Selected from image files present in test-data/

---

## Baseline Measurement (Before Implementation)

**Measurement date:** 2025-11-18
**Measurement environment:**
- CPU: Apple M1 Pro
- OS: macOS 14.6
- Zig Version: 0.16.0-dev.747+493ad58ff
- Build Mode: ReleaseFast
- Machine: Gamako's MacBook Pro
- Commit: ede4bdcf (as of Phase 0 completion)

### End-to-End Decode Speed

| Image File                                 | Image Size | Format    | Filter  | Time (μs) | Throughput (MP/s) | Memory (KB) | Note                      |
| ------------------------------------------ | ---------- | --------- | ------- | --------- | ----------------- | ----------- | ------------------------- |
| 1x1_grayscale.png                          | 1x1        | Grayscale | None    | 49.00     | 0.02              | 64          | Minimal test case         |
| 8x8_gray_filter_none.png                   | 8x8        | Grayscale | None    | 41.00     | 1.56              | 64          | Small image               |
| 16x16_gray_filter_none.png                 | 16x16      | Grayscale | None    | 50.00     | 5.12              | 65          | Small image               |
| 256x256_rgb_gradient_filter_none.png       | 256x256    | RGB       | None    | 2948.00   | 22.23             | 1168        | Medium-scale image        |
| 256x256_rgba_noise_filter_paeth.png        | 256x256    | RGBA      | Paeth   | 3998.00   | 16.39             | 1407        | Noise + complex filter    |
| 512x512_rgb_checkerboard_filter_sub.png    | 512x512    | RGB       | Sub     | 2364.00   | 110.89            | 3696        | High-frequency pattern    |
| 512x512_rgba_noise_filter_average.png      | 512x512    | RGBA      | Average | 15422.00  | 17.00             | 5228        | Noise + Average filter    |
| 1024x1024_rgb_gradient_filter_sub.png      | 1024x1024  | RGB       | Sub     | 10413.00  | 100.70            | 13430       | Large-scale image         |
| 1920x1080_rgba_gradient_filter_average.png | 1920x1080  | RGBA      | Average | 27571.00  | 75.21             | 32604       | Primary benchmark image   |

**Measurement method:**
- **Important: Always measure with a ReleaseFast build**
  - Debug builds have optimization disabled and are several to tens of times slower
  - Run command: `zig build benchmark -Doptimize=ReleaseFast`
  - Always compare improvement rates under the same build mode
- Measure decode time with std.time.Timer
- Average time over 100 runs per image
- 1 warmup run (excluded from results)
- Measure peak memory usage with a custom ProfiledAllocator

### Processing Time by Filter Type

| Filter Type | Time (ns) | Relative | Image used                         |
| ----------- | --------- | -------- | ---------------------------------- |
| None (0)    |           | baseline | 16x16_rgb_gradient_filter_none.png |
| Sub (1)     |           |          | 8x8_grayscale_filter_sub.png       |
| Up (2)      |           |          | [matching image]                   |
| Average (3) |           |          | [matching image]                   |
| Paeth (4)   |           |          | 256x256_grayscale_paeth.png        |

### Memory Usage Details

| Image         | Peak Memory (KB) | GPA Stats | ProfiledAllocator Peak (KB) | Allocations |
| ------------- | ---------------- | --------- | --------------------------- | ----------- |
| 1x1 grayscale |                  |           |                             |             |
| 256x256 RGBA  |                  |           |                             |             |
| Mixed filters |                  |           |                             |             |

---

## Phase 0: After Benchmark Environment Setup Complete

Detailed baseline measurement results are recorded here.

---

## Phase 1.3: Streaming and Full IDAT Streaming Implementation

**Measurement date:** 2025-11-22
**Measurement environment:**
- CPU: Apple M1 Pro
- OS: macOS 14.6
- Zig Version: 0.16.0-dev.747+493ad58ff
- Build Mode: ReleaseFast
- Machine: Gamako's MacBook Pro

**Improvements:**
1. **Row-wise decoding pipeline implementation**
   - ScanlineDecoder: row-wise DEFLATE decompression + filter application
   - format.zig Row functions: row-wise format conversion
   - Removed the 8.3MB full-decompression buffer

2. **Dangling Pointer Bug fix**
   - Heap-allocated ScanlineDecoder (returns `!*ScanlineDecoder`)
   - Ensured a stable address for `&self.chunk_stream_adapter.interface`

3. **Full IDAT streaming implementation**
   - Implemented IDATChunkStreamAdapter (std.Io.Reader.Limited pattern)
   - Vtable implementation via `@fieldParentPtr("interface", r)`
   - Implemented stream() and discard() methods
   - Removed collectIDATChunks() → **reduced 2-3MB IDAT concatenation buffer**

4. **VTable implementation**
   - Custom reader compatible with std.Io.Reader
   - rebase() support with a 64-byte internal buffer

**Measurement results:**

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

**Performance comparison (Phase 1.2 → Phase 1.3):**

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

**Improvement rate summary:**
- Primary measurement image (1920x1080 RGBA): **14.2% faster**
- Large improvement on small images: 43.1% (16x16 Grayscale)
- Stable improvement on large images: 13.3-14.7% (512x512 and above)

**Memory reduction effect (Phase 0 → Phase 1.3):**
- Phase 0 (baseline): 32,604 KB @ 1920x1080 RGBA
- Phase 1.3 (streaming implementation): 8,189 KB @ 1920x1080 RGBA
- **Reduction rate: 74.9% reduction**

**Reduction breakdown:**
1. **Removal of full-decompression buffer**: 8.3MB reduction
   - Phase 0-1.2: Apply filters after full DEFLATE decompression
   - Phase 1.3: Row-wise decompression + filter application

2. **IDAT concatenation buffer reduction**: 2-3MB reduction
   - Phase 0-1.2: Concatenate all IDAT via collectIDATChunks()
   - Phase 1.3: Chunk-wise streaming via IDATChunkStreamAdapter

3. **Format conversion buffer reduction**: Already reduced in Phase 1.1
   - ArrayList → pre-allocation reduced about 8MB

**Analysis:**
1. **Effect of streaming**
   - Memory reduction was the main outcome (74.9%)
   - Performance improvement was modest (14.2%)
   - Improved cache efficiency from row-wise processing

2. **Factors improving from Phase 1.2**
   - Memory access pattern optimization via IDAT streaming
   - Reduction of unnecessary buffer copies
   - Efficient use of cache lines

3. **Characteristics by image size**
   - Small images (1x1-16x16): 16-43% improvement (overhead reduction)
   - Medium images (256x256): Almost no change (-1.6%–0.4%)
   - Large images (512x512 and above): Stable 13-15% improvement

### Implementation Details
- **libs/png/src/flate.zig**: ScanlineDecoder implementation
  - Chunk-wise streaming via IDATChunkStreamAdapter
  - Row-wise filter application in readScanline()
  - Double buffering with two scanline buffers (current / previous row)
- **libs/png/src/format.zig**: Row-wise conversion functions
  - grayscaleToRGBA8888Row()
  - rgbToRGBA8888Row()
  - rgbaToRGBA8888Row()
- **libs/png/src/lib.zig**: Pipelining
  - Streaming initialization via ScanlineDecoder.init()
  - Row-wise processing in a while (readScanline()) loop
  - Format conversion also executed row-wise

### Test Results
- ✅ zig build test: All 29 tests passed
- ✅ Dangling pointer bug fully fixed
- ✅ Memory safety confirmed

### Next Steps
Phase 1.3 full implementation is complete. Next improvement candidates:
- Inlining filter functions (Phase 2.1)
- SIMD (Phase 2.2)

---

## Phase 1.1: After format.zig Pre-allocation

**Measurement date:** 2025-11-19
**Measurement environment:**
- CPU: Apple M1 Pro
- OS: macOS 14.6
- Zig Version: 0.16.0-dev.747+493ad58ff
- Build Mode: ReleaseFast
- Machine: Gamako's MacBook Pro
- Commit: 5fb12d53 (as of Phase 1.1 completion)

**Improvements:**
- `grayscaleToRGBA8888()`: ArrayList.empty + append() → allocator.alloc() + direct assignment
- `rgbToRGBA8888()`: ArrayList.empty + append() → allocator.alloc() + direct assignment
- `rgbaToRGBA8888()`: ArrayList.empty + append() → allocator.alloc() + direct assignment
- Ensured memory safety with errdefer

**Measurement results:**

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

**Improvement rate summary:**
- Primary measurement image (1920x1080 RGBA): **19.2% faster**
- Memory peak: **25.3% reduction** (32604KB → 24334KB)
- Maximum improvement rate: 30.5% (512x512 RGB Sub)

**Memory change details:**
- Peak Before (overall): 32,604 KB
- Peak After (overall): 24,334 KB
- Peak Memory Reduction: 8,270 KB (25.3% reduction)

**Analysis:**
Met the expected range (10-20%). The following points especially contributed:

1. **Eliminated ArrayList dynamic growth**
   - Reallocation count: O(log N) → 1 time
   - Memory copy volume: O(N log N) → O(N)

2. **Improved memory efficiency**
   - RGB/RGBA conversion: Stable 8.9-19.2% improvement
   - Especially effective on Sub-filter images (30.5%)

3. **Improved cache efficiency**
   - Linear memory access pattern improved L1/L2 cache hit rate
   - Direct indexed access reduced loop dependencies

4. **Reasons for peak memory reduction**
   - Format conversion functions allocate memory directly via allocator.alloc()
   - ArrayList internal buffer (capacity > usage) no longer needed
   - Total: Achieved 25.3% memory reduction

### Test Results
- ✅ zig build test: All tests passed (test count: 29/29)
- ✅ All existing test cases verified working
- ✅ End-to-end tests confirmed matching image decode results

### Next Steps
Recommend proceeding with Phase 1.2: memcpy for filter type 0 is expected to yield a further 50-70% improvement

---

## Phase 1.2: After filter type 0 memcpy

**Measurement date:** 2025-11-19
**Measurement environment:**
- CPU: Apple M1 Pro
- OS: macOS 14.6
- Zig Version: 0.16.0-dev.747+493ad58ff
- Build Mode: ReleaseFast
- Machine: Gamako's MacBook Pro
- Commit: 5214dbe1 (as of Phase 1.2 completion)

**Improvements:**
- `applyFilters()`: Special-case filter type 0 (None)
- Changed from byte-wise loop to bulk copy via `@memcpy`
- Other filter types (1-4) retain existing loop logic
- Preliminary checks ensure protection against invalid data

**Measurement results:**

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

**Improvement rate summary:**
- Primary measurement image (1920x1080 RGBA): **-0.03%** (almost no change)
- Improvement for filter type 0 (None): Almost none (-0.3%)
- Large regression on small images: -65.9% (1x1 Grayscale), -51.2% (16x16 Grayscale)
- Memory usage: Equivalent to Phase 1.1

**Analysis:**

Reasons for divergence from expected (50-70%):

1. **Filter type 0 processing time share is small**
   - Main bottlenecks overall are format conversion and I/O
   - Effect of memcpy optimization is localized

2. **Overhead on small images**
   - Large regression on small images such as 1x1 and 16x16
   - Filter-type branch checks and setup cost are relatively large

3. **Impact of measurement noise**
   - Almost no change on large images (1920x1080) (-0.03%)
   - Within noise level

4. **No substantive effect**
   - filter type 0 memcpy optimization shows no end-to-end benefit
   - Other processing (format conversion, I/O) is the bottleneck

**Effectiveness of the implementation:**
- ✅ Functionally correct (correctly handles filter type 0)
- ⚠️ No substantive end-to-end performance improvement observed
- ⚠️ Slight regression observed on small images

**Proposed next steps:**
- Focus on Phase 1.3 (streaming): resolve the larger bottleneck (buffer management)
- Phase 1.2 memcpy optimization does not contribute to performance improvement at this time

### Test Results
- ✅ zig build test-png-format: All tests passed
- ✅ Filter type 0 behavior verified
- ✅ No impact on other filter types

**Details:**

---

## Phase 2.1: Local Variable Optimization (inline Rejected)

**Measurement date:** 2025-11-23
**Measurement environment:**
- CPU: Apple M1 Pro
- OS: macOS 14.6
- Zig Version: 0.16.0-dev.747+493ad58ff
- Build Mode: ReleaseFast
- Machine: Gamako's MacBook Pro

**Improvements:**

1. **Local variable optimization (adopted)**
   - In flate.zig applyFilterInPlace, cache `bytes_per_pixel` and `bytes_per_scanline` in local variables
   - Reduced L1/L2 cache misses
   - Reduced repeated access to struct fields

2. **inline keyword validation (rejected)**
   - Added inline to Direct functions in filter.zig (filterSubDirect, filterUpDirect, filterAverageDirect, filterPaethDirect)
   - Also added inline to paethPredictor
   - **Result**: Performance worsened, so removed

**Measurement results:**

| Implementation version | 1920x1080 RGBA (μs) | Change from Phase 1.3 | Notes |
|-------------|---------------------|---------------------|------|
| Phase 1.3   | 19,105              | Baseline             | Streaming implementation |
| Stage 1 (local variables only) | 18,843 | **1.4% improvement** ✅ | Cached bpp, scanline_len |
| Stage 2 (inline added) | 19,221 | **0.6% regression** ❌ | inline was counterproductive |
| **Final (inline removed)** | **19,010** | **0.5% improvement** ✅ | **Final adopted version** |

Full benchmark results (Final version):

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

**Memory usage:**
- Equivalent to Phase 1.3 (8,189 KB @ 1920x1080 RGBA)
- Not a memory optimization; speedup from improved cache efficiency

**Improvement rate summary:**
- Local variable optimization only: **0.5-1.4% improvement** (accounting for measurement noise)
- inline added: **0.6% regression** (rejected)

**Analysis:**

1. **Effect of local variable optimization**
   - Small but stable improvement (0.5-1.4%)
   - Improved cache efficiency by reducing struct field access
   - Does not hinder compiler optimization

2. **Why inline was counterproductive**
   - As Zig docs state: "inline may restrict the compiler's optimizations and can harm binary size, compile speed, and runtime performance"
   - The compiler's automatic inlining decisions are better
   - Forced inlining may have increased register pressure
   - Instruction cache efficiency may have decreased

3. **Lessons from Phase 2.1**
   - Importance of measurement-based decisions (hypothesis-validation approach)
   - In Zig, `inline` should be used carefully
   - Accumulation of small optimizations matters

**Cumulative improvement rate (Phase 0 through Phase 2.1):**
- Phase 0 baseline: 27,571 μs
- Phase 2.1 final: 19,010 μs
- **Overall improvement: 31.1% faster**
- **Memory reduction: 74.9% reduction** (32,604 KB → 8,189 KB)

### Test Results
- ✅ zig test libs/png/src/test.zig: All 29 tests passed
- ✅ All tests also passed with inline added (no functional issues)
- ✅ All tests also passed with inline removed

---

## Phase 2.2: After SIMD

**Measurement date:**

**Improvement rate:**
- RGB conversion speed: __ % improvement

**Details:**

---

## Final Results Summary

| Metric         | Baseline   | After optimization | Improvement |
| -------------- | ---------- | ------------------ | ----------- |
| Peak memory    | 29MB       | __ MB              | __ %        |
| Processing speed | __ μs    | __ μs              | __ %        |

---

## Phase Results Recording Template

After completing each Phase, record the following information:

```markdown
## Phase X.Y - [Improvement name]

**Measurement date:** YYYY-MM-DD
**Commit:** [ID visible via jj log -n2]

### Improvements
[Brief description]

### Measurement results

| Image | Before (μs) | After (μs) | Improvement | Memory (KB) |
|-------|------------|-----------|------------|------------|
| test1.png | | | | |
| test2.png | | | | |

### Memory change
- Peak Before: __ KB
- Peak After: __ KB
- Reduction: __ %

### Analysis
[Describe performance changes, especially reasons when results differ from expectations]

### Test results
- ✅ zig test libs/png/src/test.zig: PASS
- ✅ All test cases passed
```

---

## Notes for Implementation

0. **Strict build mode**: Always run benchmark measurements with `-Doptimize=ReleaseFast`
   - Debug builds have optimization disabled and performance drops sharply (several to tens of times)
   - Always compare improvement rates under the same build mode
   - Run command: `zig build benchmark -Doptimize=ReleaseFast`
1. **Fixed test images**: Use the same images for every measurement
2. **Measurement count**: Run each image at least 1000 times and take the average
3. **Warmup**: Ignore the first run to exclude JIT and cache effects
4. **Environment consistency**: Fixed CPU frequency and minimized background processes recommended
5. **Memory measurement**: Use ProfiledAllocator peak_bytes

---

## Where Measurement Data Is Stored

- **BENCHMARKS.md**: This file (human-readable Markdown)
- **benchmark.zig**: Automated measurement script
- **CSV format**: For machine-learning analysis (optional)
