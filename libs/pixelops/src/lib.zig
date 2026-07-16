//! libs/pixelops: ピクセルブレンドの共有プリミティブ（TASK-51）。
//!
//! 3 箇所に分散していたブレンド実装（旧 src/sprite.zig＝現 libs/gfx/src/sprite.zig の premultiplied SIMD /
//! apps/editor/core/blend.zig の straight scalar / libs/font/src/color.zig の
//! opaque-dst scalar）をここへ統合した。「速い実装がデフォルトの実装」の置き場。
//!
//! ピクセル形式: canonical BGRA — u32 = 0xAARRGGBB（little-endian、メモリ上 [B,G,R,A] 順）。
//! alpha 規約は関数ごとに premultiplied 系 / straight（非 premultiplied）系を明示する。
//! 他 module（font/gui/core 等）に依存しない u32 ベース API（import 循環なし）。
//!
//! ここの関数群は**フレーム毎の全画素ループから呼ばれるホットパス**の building block。
//! 性能規約（AGENT.md）の SIMD 3点セット（SIMD + div255 + clip-hoist）の正準実装。

const std = @import("std");

pub const Vec4u16 = @Vector(4, u16);
pub const Vec16u8 = @Vector(16, u8);
pub const Vec16u16 = @Vector(16, u16);
pub const Vec16f32 = @Vector(16, f32);

// ============================================================
// div255: /255 の per-pixel 整数除算を置き換える高速近似
// ============================================================

/// floor(x / 255)。0 <= x <= 65025（255*255）の範囲で正確。
pub inline fn div255(x: u32) u32 {
    return (x + 1 + (x >> 8)) >> 8;
}

/// floor(x / 255) の 4-lane 版。
pub inline fn div255Vec(x: Vec4u16) Vec4u16 {
    const one: Vec4u16 = @splat(1);
    const eight: @Vector(4, u4) = @splat(8);
    return (x + one + (x >> eight)) >> eight;
}

/// floor(x / 255) の 16-lane 版。
pub inline fn div255Vec16(x: Vec16u16) Vec16u16 {
    const one: Vec16u16 = @splat(1);
    const eight: @Vector(16, u4) = @splat(8);
    return (x + one + (x >> eight)) >> eight;
}

/// (x + 127) / 255 と bit 一致する丸め版。0 <= x <= 65025 の範囲で正確。
/// （既存 scalar 実装の `(sa*src + inv*dst + 127) / 255` を SIMD 化するときに使う）
pub inline fn div255Round(x: u32) u32 {
    return (x + 128 + ((x + 127) >> 8)) >> 8;
}

/// (x + 127) / 255 の 16-lane 版。u16 lane 内で 65025+128+254=65407 < 65536 に収まる。
pub inline fn div255RoundVec16(x: Vec16u16) Vec16u16 {
    const c128: Vec16u16 = @splat(128);
    const c127: Vec16u16 = @splat(127);
    const eight: @Vector(16, u4) = @splat(8);
    return (x + c128 + ((x + c127) >> eight)) >> eight;
}

// ============================================================
// premultiplied 系（旧 src/sprite.zig / 現 libs/gfx/src/sprite.zig blendPixel / blend4Pixels）
// ============================================================

/// u32 ピクセル → Vec4u16（メモリ順 [B,G,R,A]）。
inline fn pixelToVec(pixel: u32) Vec4u16 {
    const bytes: [4]u8 = @bitCast(pixel);
    return .{
        @as(u16, bytes[0]),
        @as(u16, bytes[1]),
        @as(u16, bytes[2]),
        @as(u16, bytes[3]),
    };
}

/// Vec4u16 → u32 ピクセル。アルファは 0xFF 強制。
inline fn vecToPixel(vec: Vec4u16) u32 {
    const result_bytes: [4]u8 = .{
        @truncate(vec[0]),
        @truncate(vec[1]),
        @truncate(vec[2]),
        0xFF,
    };
    return @bitCast(result_bytes);
}

/// Premultiplied alpha ブレンド（scalar）。out = src_pre + dst * (255 - src_a) / 255。
/// 出力アルファは 0xFF 強制（不透明フレームバッファ前提）。
///
/// PRECONDITION: src_pre は premultiplied 済みで R/G/B <= A を満たすこと。
/// （SIMD 版 `blendPremul4` の narrow と同じ前提。スカラー版はオーバーフローしないが、
///  blend 結果の数学的整合性のために同じ不変を要求する）
pub fn blendPremul(dst: u32, src_pre: u32) u32 {
    const src_a: u8 = @truncate(src_pre >> 24);

    // 早期リターン: 完全透明（出力アルファは常に 0xFF に強制）
    if (src_a == 0) return dst | 0xFF000000;

    // 早期リターン: 完全不透明
    if (src_a == 255) return src_pre | 0xFF000000;

    const src_vec = pixelToVec(src_pre);
    const dst_vec = pixelToVec(dst);
    const inv_a: Vec4u16 = @splat(@as(u16, 255 - src_a));

    const blended = src_vec + div255Vec(dst_vec * inv_a);
    return vecToPixel(blended);
}

/// ピクセル内 A レーン位置（memory index 3/7/11/15）を各ピクセル 4 lane へ複製する shuffle。
const alpha_idx: @Vector(16, i32) = .{ 3, 3, 3, 3, 7, 7, 7, 7, 11, 11, 11, 11, 15, 15, 15, 15 };

/// アルファレーン（memory index 3/7/11/15）だけ true のマスク。
const alpha_mask: @Vector(16, bool) = .{
    false, false, false, true,
    false, false, false, true,
    false, false, false, true,
    false, false, false, true,
};

/// 4 ピクセル同時の premultiplied blend（16-lane SIMD）。`blendPremul` と bit 一致。
/// 入出力レイアウト: メモリ上 [B0 G0 R0 A0 B1 G1 R1 A1 B2 G2 R2 A2 B3 G3 R3 A3]。
/// 出力アルファは 0xFF 強制（ウィンドウ常に不透明）。
///
/// PRECONDITION: src_pre の各ピクセルは premultiplied 済みで R/G/B <= A を満たすこと。
/// この不変条件を破ると blended の値域が u8 範囲外となり、`@intCast(Vec16u16 -> Vec16u8)`
/// で Debug 時 panic / ReleaseFast 時 UB を引き起こす。PNG デコード時に
/// `decodePNGFilePremultiplied` / `decodePNGPremultiplied` を通せばこの不変は保たれる。
pub inline fn blendPremul4(dst: Vec16u8, src_pre: Vec16u8) Vec16u8 {
    const src_a = @shuffle(u8, src_pre, undefined, alpha_idx);

    // u8 -> u16 widening
    const src16: Vec16u16 = @intCast(src_pre);
    const dst16: Vec16u16 = @intCast(dst);
    const src_a16: Vec16u16 = @intCast(src_a);
    const inv_a: Vec16u16 = @as(Vec16u16, @splat(255)) - src_a16;

    // out = src_pre + dst * (255 - src_a) / 255
    const blended16 = src16 + div255Vec16(dst16 * inv_a);
    const blended: Vec16u8 = @intCast(blended16);

    return @select(u8, alpha_mask, @as(Vec16u8, @splat(0xFF)), blended);
}

// ============================================================
// straight 系・一般（旧 apps/editor/core/blend.zig）
// ============================================================

inline fn ch(c: u32, comptime shift: u5) u32 {
    return (c >> shift) & 0xFF;
}

/// src OVER dst（**引数順: dst が先・src が後**）。straight-alpha src-over。
/// dst のアルファも任意（out_a を正しく計算する）。partial alpha は per-pixel の
/// 可変除算（÷ out_a*255）を含むため、全画素ループでは opaque-dst 前提にできる場合
/// `srcOverOpaque` / `srcOverOpaque4` を優先する。
pub fn srcOver(dst: u32, src: u32) u32 {
    const sa = ch(src, 24);
    if (sa == 255) return src; // 完全不透明 src は dst を完全に置換
    if (sa == 0) return dst; // 完全透明 src は dst のまま
    const da = ch(dst, 24);
    const inv = 255 - sa;
    const oa255 = sa * 255 + da * inv; // = out_a * 255（>0: sa>0 なので）
    const out_a = (oa255 + 127) / 255;
    const b = (ch(src, 0) * sa * 255 + ch(dst, 0) * da * inv + oa255 / 2) / oa255;
    const g = (ch(src, 8) * sa * 255 + ch(dst, 8) * da * inv + oa255 / 2) / oa255;
    const r = (ch(src, 16) * sa * 255 + ch(dst, 16) * da * inv + oa255 / 2) / oa255;
    return (out_a << 24) | (r << 16) | (g << 8) | b;
}

/// 白(不透明)背景に src を src-over した不透明色（composite 表示用）。
pub fn overWhite(src: u32) u32 {
    return srcOver(0xFFFFFFFF, src);
}

/// 色の alpha に coverage(0..255) を乗算（RGB 不変、a' = (a*cov+127)/255）。
pub fn scaleAlpha(c: u32, cov: u8) u32 {
    const a = ch(c, 24);
    const na = (a * cov + 127) / 255;
    return (c & 0x00FFFFFF) | (na << 24);
}

// ============================================================
// straight 系・opaque-dst（旧 libs/font/src/color.zig Color.blend と bit 一致）
// ============================================================

/// dst を不透明とみなす straight src-over（scalar）。出力アルファは 0xFF 固定。
/// partial alpha: 各チャネル (sa*src + (255-sa)*dst + 127) / 255 と bit 一致。
/// `srcOver` の dst 不透明時とも bit 一致（テストで固定）。
pub fn srcOverOpaque(dst: u32, src: u32) u32 {
    const sa = ch(src, 24);
    if (sa == 0) return dst | 0xFF000000;
    if (sa == 255) return src | 0xFF000000;
    const inv = 255 - sa;
    const b = div255Round(ch(src, 0) * sa + ch(dst, 0) * inv);
    const g = div255Round(ch(src, 8) * sa + ch(dst, 8) * inv);
    const r = div255Round(ch(src, 16) * sa + ch(dst, 16) * inv);
    return 0xFF000000 | (r << 16) | (g << 8) | b;
}

/// 4 ピクセル同時の straight opaque-dst blend（16-lane SIMD）。`srcOverOpaque` と bit 一致。
/// 入出力レイアウトは `blendPremul4` と同じ。出力アルファは 0xFF 強制。
/// straight のため premultiplied 前提は不要（任意の R/G/B/A 組み合わせで値域内）。
pub inline fn srcOverOpaque4(dst: Vec16u8, src: Vec16u8) Vec16u8 {
    const src_a = @shuffle(u8, src, undefined, alpha_idx);

    const src16: Vec16u16 = @intCast(src);
    const dst16: Vec16u16 = @intCast(dst);
    const src_a16: Vec16u16 = @intCast(src_a);
    const inv_a: Vec16u16 = @as(Vec16u16, @splat(255)) - src_a16;

    // out = (src * sa + dst * (255 - sa) + 127) / 255（div255Round で bit 一致）
    const blended16 = div255RoundVec16(src16 * src_a16 + dst16 * inv_a);
    const blended: Vec16u8 = @intCast(blended16);

    return @select(u8, alpha_mask, @as(Vec16u8, @splat(0xFF)), blended);
}

/// 4 ピクセル同時の scaleAlpha（16-lane）。`scaleAlpha` と bit 一致
/// （a' = div255Round(a*cov) = (a*cov+127)/255、RGB 不変）。
pub inline fn scaleAlpha4(c: Vec16u8, cov: u8) Vec16u8 {
    const c16: Vec16u16 = @intCast(c);
    const cov16: Vec16u16 = @splat(cov);
    // 全 lane を一括スケールし（値域 ≤ 255*255 で u16 内）、alpha lane だけ採用する
    const scaled: Vec16u8 = @intCast(div255RoundVec16(c16 * cov16));
    return @select(u8, alpha_mask, scaled, c);
}

// ============================================================
// straight 系・一般 SIMD（dst alpha 可変。TASK-52）
//
// 可変 out_a の除算は div255（除数 255 固定）で表現できないため f32 除算を使う。
// 積・和の値域は ≤ 255*65025 = 16,581,375 < 2^24 で f32 に正確表現される
// （u16 lane の積和は溢れるので禁止。必ず f32 へ widen してから積和する）。
// 保証するのは srcOverStraightScalar ↔ srcOverStraight4 の bit 一致のみ
// （整数版 `srcOver` とは丸めが僅かに異なりうる）。
// ============================================================

/// straight src-over + layer opacity 融合のスカラー参照実装（f32 演算）。
/// `srcOverStraight4` と bit 一致（テストで固定）。out = srcOver(dst, scaleAlpha(src, opacity)) 相当。
/// 不変条件: sa'==0 のとき dst alpha > 0 なら dst を bit そのまま返す。dst alpha == 0 なら
/// 0x00000000 を返す（dst が「a=0 ⇒ RGB=0」を満たす前提＝canvas cache 不変条件下では
/// dst の bit 保持と同値。呼び出し側の skip fast path はこの前提で等価になる）。
pub fn srcOverStraightScalar(dst: u32, src: u32, opacity: u8) u32 {
    const sa_scaled = div255Round(ch(src, 24) * opacity);
    const da = ch(dst, 24);
    const inv = 255 - sa_scaled;
    const den_i = sa_scaled * 255 + da * inv; // ≤ 65025
    if (den_i == 0) return 0; // 完全透明どうし（cache 不変条件で dst==0）
    const den: f32 = @floatFromInt(den_i);
    // 整数で組み立てた分子は ≤ 16.6M で u32 に収まり、f32 変換も正確（< 2^24）
    const b = straightChannel(ch(src, 0), ch(dst, 0), sa_scaled, da, inv, den);
    const g = straightChannel(ch(src, 8), ch(dst, 8), sa_scaled, da, inv, den);
    const r = straightChannel(ch(src, 16), ch(dst, 16), sa_scaled, da, inv, den);
    const out_a: u32 = @intFromFloat(@round(den / 255.0));
    return (out_a << 24) | (r << 16) | (g << 8) | b;
}

inline fn straightChannel(sc: u32, dc: u32, sa: u32, da: u32, inv: u32, den: f32) u32 {
    const num: f32 = @floatFromInt(sc * sa * 255 + dc * da * inv);
    return @intFromFloat(@round(num / den));
}

/// 4 ピクセル同時の straight src-over + layer opacity 融合（16-lane、f32 除算）。
/// `srcOverStraightScalar` と bit 一致。dst alpha 可変（compositeStraight 向け）。
pub inline fn srcOverStraight4(dst: Vec16u8, src: Vec16u8, opacity: u8) Vec16u8 {
    // sa' = div255Round(sa * opacity)（整数。u16 内）
    const src_a = @shuffle(u8, src, undefined, alpha_idx);
    const dst_a = @shuffle(u8, dst, undefined, alpha_idx);
    const sa16: Vec16u16 = @intCast(src_a);
    const op16: Vec16u16 = @splat(opacity);
    const sa_scaled16 = div255RoundVec16(sa16 * op16);
    const inv16 = @as(Vec16u16, @splat(255)) - sa_scaled16;

    // f32 へ widen（u16 の積和は禁止: 分子 ≤ 16.6M）
    const sa_f: Vec16f32 = @floatFromInt(sa_scaled16);
    const inv_f: Vec16f32 = @floatFromInt(inv16);
    const da_f: Vec16f32 = @floatFromInt(@as(Vec16u16, @intCast(dst_a)));
    const src_f: Vec16f32 = @floatFromInt(@as(Vec16u16, @intCast(src)));
    const dst_f: Vec16f32 = @floatFromInt(@as(Vec16u16, @intCast(dst)));

    const c255: Vec16f32 = @splat(255.0);
    const den = sa_f * c255 + da_f * inv_f; // per-pixel 値（alpha 複製で 4 lane 同値）
    const num = src_f * sa_f * c255 + dst_f * da_f * inv_f;

    const zero: Vec16f32 = @splat(0.0);
    const den_is_zero = den == zero;
    const safe_den = @select(f32, den_is_zero, @as(Vec16f32, @splat(1.0)), den);
    const color = @select(f32, den_is_zero, zero, @round(num / safe_den));
    const alpha = @round(den / c255); // den==0 なら 0
    const out_f = @select(f32, alpha_mask, alpha, color);
    const out16: Vec16u16 = @intFromFloat(out_f);
    return @intCast(out16);
}

// ============================================================
// clip-hoist: blit の clip 交差をループ外で 1 回計算する
// ============================================================

pub const Clip = struct {
    src_x: u32,
    src_y: u32,
    dst_x: u32,
    dst_y: u32,
    w: u32,
    h: u32,
};

// ============================================================
// BGRA↔RGBA byte swizzle（TASK-73.1。wasm present ホットパス）
// ============================================================
//
// canonical BGRA u32 = 0xAARRGGBB（LE メモリ [B,G,R,A]）→ ImageData [R,G,B,A]。
// ホットパス宣言: フレーム毎・全画素 1 パス。per-pixel 除算/関数呼び出し/bounds 検査なし。
// SIMD=@Vector(16,u8) で 4px 同時 + scalar tail。行連続・clip 無し（同一 w×h 連続領域）。

/// スカラー参照版。1 画素の [B,G,R,A] → [R,G,B,A]。
pub fn swizzleBgraToRgbaScalar(dst: []u8, src: []const u8) void {
    std.debug.assert(dst.len == src.len);
    std.debug.assert(dst.len % 4 == 0);
    var i: usize = 0;
    while (i < src.len) : (i += 4) {
        dst[i + 0] = src[i + 2]; // R
        dst[i + 1] = src[i + 1]; // G
        dst[i + 2] = src[i + 0]; // B
        dst[i + 3] = src[i + 3]; // A
    }
}

/// SIMD 版（4px=@Vector(16,u8) byte shuffle + scalar tail）。SIMD=scalar bit 一致をテストで担保。
pub fn swizzleBgraToRgba(dst: []u8, src: []const u8) void {
    std.debug.assert(dst.len == src.len);
    std.debug.assert(dst.len % 4 == 0);
    // shuffle mask: out[i] = in[mask[i]]。BGRA→RGBA = B↔R 入替（4px 分）。
    const perm: @Vector(16, i32) = .{
        2,  1,  0,  3,
        6,  5,  4,  7,
        10, 9,  8,  11,
        14, 13, 12, 15,
    };
    var i: usize = 0;
    const simd_end = src.len - (src.len % 16);
    while (i < simd_end) : (i += 16) {
        const in: @Vector(16, u8) = src[i..][0..16].*;
        dst[i..][0..16].* = @shuffle(u8, in, undefined, perm);
    }
    // scalar tail（0..3 px）
    while (i < src.len) : (i += 4) {
        dst[i + 0] = src[i + 2];
        dst[i + 1] = src[i + 1];
        dst[i + 2] = src[i + 0];
        dst[i + 3] = src[i + 3];
    }
}

/// (x, y) に src_w×src_h を置いたとき、dst_w×dst_h 内に収まる可視範囲を返す。
/// 完全に外（または dst/src が 0 サイズ）なら null。null でなければ w/h >= 1。
/// 内側ループは戻り値の範囲を無検査で走査してよい（per-pixel clip 比較の禁止に対応）。
///
/// PRECONDITION: 各サイズは i32 に収まること（x + src_w の i32 加算がオーバーフローしない範囲）。
pub fn clipBlit(dst_w: u32, dst_h: u32, src_w: u32, src_h: u32, x: i32, y: i32) ?Clip {
    if (dst_w == 0 or dst_h == 0 or src_w == 0 or src_h == 0) return null;
    if (x >= @as(i32, @intCast(dst_w)) or y >= @as(i32, @intCast(dst_h))) return null;
    if (x + @as(i32, @intCast(src_w)) <= 0 or y + @as(i32, @intCast(src_h)) <= 0) return null;

    const src_x: u32 = if (x < 0) @intCast(-x) else 0;
    const src_y: u32 = if (y < 0) @intCast(-y) else 0;
    const dst_x: u32 = if (x < 0) 0 else @intCast(x);
    const dst_y: u32 = if (y < 0) 0 else @intCast(y);
    return .{
        .src_x = src_x,
        .src_y = src_y,
        .dst_x = dst_x,
        .dst_y = dst_y,
        .w = @min(src_w - src_x, dst_w - dst_x),
        .h = @min(src_h - src_y, dst_h - dst_y),
    };
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

test "div255: floor(x/255) と全域一致 (0..65025)" {
    var x: u32 = 0;
    while (x <= 65025) : (x += 1) {
        try testing.expectEqual(x / 255, div255(x));
    }
}

test "div255Round: (x+127)/255 と全域一致 (0..65025)" {
    var x: u32 = 0;
    while (x <= 65025) : (x += 1) {
        try testing.expectEqual((x + 127) / 255, div255Round(x));
    }
}

test "div255Vec16 / div255RoundVec16: scalar 版と一致（境界値 + 乱数）" {
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rng = prng.random();
    var trial: usize = 0;
    while (trial < 1000) : (trial += 1) {
        var vals: [16]u16 = undefined;
        for (&vals, 0..) |*v, i| {
            v.* = switch (i) {
                0 => 0,
                1 => 254,
                2 => 255,
                3 => 256,
                4 => 65024,
                5 => 65025,
                else => rng.uintLessThan(u16, 65026),
            };
        }
        const vec: Vec16u16 = vals;
        const floor_out: [16]u16 = div255Vec16(vec);
        const round_out: [16]u16 = div255RoundVec16(vec);
        for (vals, 0..) |v, i| {
            try testing.expectEqual(@as(u16, @intCast(@as(u32, v) / 255)), floor_out[i]);
            try testing.expectEqual(@as(u16, @intCast((@as(u32, v) + 127) / 255)), round_out[i]);
        }
    }
}

/// Premultiplied 不変条件 (R/G/B <= A) を満たす u32 ピクセルを生成するテスト用ヘルパー。
fn makePremulPixel(r: u8, g: u8, b: u8, a: u8) u32 {
    const bytes: [4]u8 = .{ @min(b, a), @min(g, a), @min(r, a), a };
    return @bitCast(bytes);
}

// SIMD 4 ピクセルブレンド結果がスカラー版と完全一致することを保証する（旧 sprite.zig テスト移設）。
test "blendPremul4 matches scalar blendPremul" {
    const Case = struct { name: []const u8, src: [4]u32, dst: [4]u32 };
    const cases = [_]Case{
        .{
            .name = "all alpha=0 (fully transparent)",
            .src = .{
                makePremulPixel(0, 0, 0, 0),
                makePremulPixel(0, 0, 0, 0),
                makePremulPixel(0, 0, 0, 0),
                makePremulPixel(0, 0, 0, 0),
            },
            .dst = .{ 0xFF112233, 0xFF445566, 0xFF778899, 0xFFAABBCC },
        },
        .{
            .name = "all alpha=255 (fully opaque)",
            .src = .{
                makePremulPixel(100, 150, 200, 255),
                makePremulPixel(50, 60, 70, 255),
                makePremulPixel(10, 20, 30, 255),
                makePremulPixel(200, 100, 50, 255),
            },
            .dst = .{ 0xFFAAAAAA, 0xFFBBBBBB, 0xFFCCCCCC, 0xFFDDDDDD },
        },
        .{
            .name = "all alpha=128 (mid translucent)",
            .src = .{
                makePremulPixel(40, 60, 80, 128),
                makePremulPixel(20, 30, 40, 128),
                makePremulPixel(100, 110, 120, 128),
                makePremulPixel(0, 0, 0, 128),
            },
            .dst = .{ 0xFF101010, 0xFF202020, 0xFF303030, 0xFF404040 },
        },
        .{
            .name = "mixed alphas (0/64/192/255)",
            .src = .{
                makePremulPixel(0, 0, 0, 0),
                makePremulPixel(30, 40, 50, 64),
                makePremulPixel(150, 160, 170, 192),
                makePremulPixel(200, 210, 220, 255),
            },
            .dst = .{ 0xFF112233, 0xFF445566, 0xFF778899, 0xFFAABBCC },
        },
        .{
            .name = "RGB extreme + premultiplied clamp",
            .src = .{
                makePremulPixel(255, 255, 255, 100),
                makePremulPixel(0, 0, 255, 100),
                makePremulPixel(255, 0, 0, 200),
                makePremulPixel(128, 64, 32, 50),
            },
            .dst = .{ 0xFF000000, 0xFFFFFFFF, 0xFF808080, 0xFF7F3F1F },
        },
    };

    for (cases) |c| {
        var expected: [4]u32 = undefined;
        for (0..4) |i| expected[i] = blendPremul(c.dst[i], c.src[i]);

        const sv: Vec16u8 = @bitCast(c.src);
        const dv: Vec16u8 = @bitCast(c.dst);
        const actual: [4]u32 = @bitCast(blendPremul4(dv, sv));

        testing.expectEqualSlices(u32, &expected, &actual) catch |err| {
            std.debug.print("case '{s}' failed\n", .{c.name});
            return err;
        };
    }
}

test "srcOverOpaque4 matches scalar srcOverOpaque（境界 alpha + 乱数）" {
    var prng = std.Random.DefaultPrng.init(0xB1E4D);
    const rng = prng.random();
    // 境界 alpha（0/1/127/128/254/255）を必ず通し、残りは乱数
    const forced_alphas = [_]u8{ 0, 1, 127, 128, 254, 255 };
    var trial: usize = 0;
    while (trial < 2000) : (trial += 1) {
        var src: [4]u32 = undefined;
        var dst: [4]u32 = undefined;
        for (&src, &dst, 0..) |*s, *d, i| {
            const a: u8 = if (trial < forced_alphas.len) forced_alphas[trial] else rng.int(u8);
            const bytes: [4]u8 = .{ rng.int(u8), rng.int(u8), rng.int(u8), a };
            s.* = @bitCast(bytes);
            d.* = rng.int(u32);
            _ = i;
        }
        var expected: [4]u32 = undefined;
        for (0..4) |i| expected[i] = srcOverOpaque(dst[i], src[i]);
        const actual: [4]u32 = @bitCast(srcOverOpaque4(@bitCast(dst), @bitCast(src)));
        try testing.expectEqualSlices(u32, &expected, &actual);
    }
}

test "srcOverOpaque == srcOver（dst 不透明時）: (sa, src, dst) per-channel 等価" {
    // 全チャネル同値のピクセルで per-channel 式の等価性を確認する。
    // sa/src は全数、dst は境界 + 中間のサンプル（全数 16.7M は codex レビューで別途確認済み）。
    const dst_samples = [_]u32{ 0, 1, 2, 63, 64, 127, 128, 129, 191, 192, 253, 254, 255 };
    var sa: u32 = 0;
    while (sa <= 255) : (sa += 1) {
        var sc: u32 = 0;
        while (sc <= 255) : (sc += 1) {
            const src = (sa << 24) | (sc * 0x010101);
            for (dst_samples) |dc| {
                const dst = 0xFF000000 | (dc * 0x010101);
                try testing.expectEqual(srcOver(dst, src), srcOverOpaque(dst, src));
            }
        }
    }
}

test "scaleAlpha4 matches scalar scaleAlpha（境界 + 乱数）" {
    var prng = std.Random.DefaultPrng.init(0x5CA1E);
    const rng = prng.random();
    const covs = [_]u8{ 0, 1, 127, 128, 254, 255, 200 };
    for (covs) |cov| {
        var trial: usize = 0;
        while (trial < 500) : (trial += 1) {
            var px: [4]u32 = undefined;
            for (&px) |*p| p.* = rng.int(u32);
            var expected: [4]u32 = undefined;
            for (0..4) |i| expected[i] = scaleAlpha(px[i], cov);
            const actual: [4]u32 = @bitCast(scaleAlpha4(@bitCast(px), cov));
            try testing.expectEqualSlices(u32, &expected, &actual);
        }
    }
}

test "srcOverStraight4 matches scalar srcOverStraightScalar（境界 alpha 強制 + 乱数）" {
    var prng = std.Random.DefaultPrng.init(0x57A1);
    const rng = prng.random();
    const forced_alphas = [_]u8{ 0, 1, 127, 128, 254, 255 };
    const opacities = [_]u8{ 255, 200, 128, 1, 0 };
    for (opacities) |op| {
        var trial: usize = 0;
        while (trial < 1000) : (trial += 1) {
            var src: [4]u32 = undefined;
            var dst: [4]u32 = undefined;
            for (&src, &dst) |*s, *d| {
                const sa: u8 = if (trial < forced_alphas.len) forced_alphas[trial] else rng.int(u8);
                const da: u8 = if (trial < forced_alphas.len) forced_alphas[forced_alphas.len - 1 - trial] else rng.int(u8);
                const sb: [4]u8 = .{ rng.int(u8), rng.int(u8), rng.int(u8), sa };
                const db: [4]u8 = .{ rng.int(u8), rng.int(u8), rng.int(u8), da };
                s.* = @bitCast(sb);
                d.* = @bitCast(db);
            }
            var expected: [4]u32 = undefined;
            for (0..4) |i| expected[i] = srcOverStraightScalar(dst[i], src[i], op);
            const actual: [4]u32 = @bitCast(srcOverStraight4(@bitCast(dst), @bitCast(src), op));
            try testing.expectEqualSlices(u32, &expected, &actual);
        }
    }
}

test "srcOverStraightScalar: 恒等性（dst=0・opacity=255・a>0 で src を bit 保持）と sa'==0 で dst 保持" {
    var prng = std.Random.DefaultPrng.init(0x1DE2);
    const rng = prng.random();
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        // a>0 の src は透明 dst 上で bit 保持（compositeStraight 単層恒等の基礎）
        const a: u8 = rng.intRangeAtMost(u8, 1, 255);
        const bytes: [4]u8 = .{ rng.int(u8), rng.int(u8), rng.int(u8), a };
        const src: u32 = @bitCast(bytes);
        try testing.expectEqual(src, srcOverStraightScalar(0x00000000, src, 255));

        // sa'==0（src a=0）は dst を bit そのまま返す（skip fast path と等価）。
        // 例外: dst も a=0 なら 0 を返す（cache 不変条件 a=0⇒RGB=0 の下では dst==0 と同値）
        const dst = rng.int(u32);
        const expected: u32 = if ((dst >> 24) == 0) 0x00000000 else dst;
        try testing.expectEqual(expected, srcOverStraightScalar(dst, rng.int(u32) & 0x00FFFFFF, 255));
    }
}

// ---- straight 一般（旧 core/blend.zig テスト移設）----

test "srcOver: 端値（a=0 は dst のまま / a=255 は src へ置換）" {
    const dst: u32 = 0xFF112233; // 不透明
    try testing.expectEqual(dst, srcOver(dst, 0x00AABBCC)); // src a=0 → dst
    try testing.expectEqual(@as(u32, 0xFFAABBCC), srcOver(dst, 0xFFAABBCC)); // src a=255 → src
}

test "srcOver: 透明 dst へ半透明 src（out_a 計算）" {
    // dst 完全透明 (a=0)、src a=128 の青(B=255)
    const out = srcOver(0x00000000, 0x80_00_00_FF);
    const oa = (out >> 24) & 0xFF;
    try testing.expectEqual(@as(u32, 128), oa); // out_a = sa + 0 = 128
    try testing.expectEqual(@as(u32, 255), out & 0xFF); // B は保持
}

test "srcOver: 透明 dst は src をそのまま返す（compositeStraight の恒等性の基礎）" {
    // a>0 の任意の (色, alpha) で dst=0x00000000 への srcOver が src と bit 一致すること。
    // a=0 は「完全透明 src は dst のまま」の早期 return が仕様（RGB 非ゼロでも dst=0 を返す）。
    var prng = std.Random.DefaultPrng.init(0x1DE1);
    const rng = prng.random();
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const src = rng.int(u32);
        const expected: u32 = if ((src >> 24) == 0) 0x00000000 else src;
        try testing.expectEqual(expected, srcOver(0x00000000, src));
    }
}

test "srcOver: 不透明青の上に半透明赤（中間ブレンド）" {
    const dst: u32 = 0xFF0000FF; // 不透明青（b=FF）
    const src: u32 = 0x80FF0000; // a=80, r=FF（赤）
    const out = srcOver(dst, src);
    try testing.expectEqual(@as(u32, 0xFF), (out >> 24) & 0xFF); // out_a=255（da=255）
    const b = out & 0xFF;
    const r = (out >> 16) & 0xFF;
    try testing.expect(b > 120 and b < 135); // 青が約半分
    try testing.expect(r > 120 and r < 135); // 赤が約半分
}

test "overWhite: a=255 は元色 / a=0 は白" {
    try testing.expectEqual(@as(u32, 0xFF0000FF), overWhite(0xFF0000FF));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), overWhite(0x000000FF));
}

test "scaleAlpha: alpha に coverage を乗算" {
    try testing.expectEqual(@as(u32, 0xFF0000FF), scaleAlpha(0xFF0000FF, 255)); // 不変
    try testing.expectEqual(@as(u32, 0x000000FF), scaleAlpha(0xFF0000FF, 0)); // a=0
    const half = scaleAlpha(0xFF0000FF, 128);
    try testing.expectEqual(@as(u32, 128), (half >> 24) & 0xFF); // a≈128
    try testing.expectEqual(@as(u32, 0xFF), half & 0xFF); // RGB 不変
}

// ---- clipBlit ----

test "clipBlit: table-driven 境界" {
    const Case = struct {
        name: []const u8,
        dst_w: u32,
        dst_h: u32,
        src_w: u32,
        src_h: u32,
        x: i32,
        y: i32,
        expect: ?Clip,
    };
    const cases = [_]Case{
        .{ .name = "全部見える", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = 2, .y = 1, .expect = .{ .src_x = 0, .src_y = 0, .dst_x = 2, .dst_y = 1, .w = 4, .h = 3 } },
        .{ .name = "左はみ出し", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = -2, .y = 0, .expect = .{ .src_x = 2, .src_y = 0, .dst_x = 0, .dst_y = 0, .w = 2, .h = 3 } },
        .{ .name = "上はみ出し", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = 0, .y = -1, .expect = .{ .src_x = 0, .src_y = 1, .dst_x = 0, .dst_y = 0, .w = 4, .h = 2 } },
        .{ .name = "右はみ出し", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = 8, .y = 0, .expect = .{ .src_x = 0, .src_y = 0, .dst_x = 8, .dst_y = 0, .w = 2, .h = 3 } },
        .{ .name = "下はみ出し", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = 0, .y = 6, .expect = .{ .src_x = 0, .src_y = 0, .dst_x = 0, .dst_y = 6, .w = 4, .h = 2 } },
        .{ .name = "右にちょうど外（x=dst_w）", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = 10, .y = 0, .expect = null },
        .{ .name = "右に 1px だけ見える", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = 9, .y = 0, .expect = .{ .src_x = 0, .src_y = 0, .dst_x = 9, .dst_y = 0, .w = 1, .h = 3 } },
        .{ .name = "左にちょうど外（x+src_w=0）", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = -4, .y = 0, .expect = null },
        .{ .name = "左に 1px だけ見える", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = -3, .y = 0, .expect = .{ .src_x = 3, .src_y = 0, .dst_x = 0, .dst_y = 0, .w = 1, .h = 3 } },
        .{ .name = "下にちょうど外（y=dst_h）", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = 0, .y = 8, .expect = null },
        .{ .name = "上にちょうど外（y+src_h=0）", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 3, .x = 0, .y = -3, .expect = null },
        .{ .name = "src 0 幅", .dst_w = 10, .dst_h = 8, .src_w = 0, .src_h = 3, .x = 0, .y = 0, .expect = null },
        .{ .name = "src 0 高さ", .dst_w = 10, .dst_h = 8, .src_w = 4, .src_h = 0, .x = 0, .y = 0, .expect = null },
        .{ .name = "dst 0 サイズ", .dst_w = 0, .dst_h = 0, .src_w = 4, .src_h = 3, .x = -1, .y = 0, .expect = null },
        .{ .name = "dst と同サイズぴったり", .dst_w = 4, .dst_h = 3, .src_w = 4, .src_h = 3, .x = 0, .y = 0, .expect = .{ .src_x = 0, .src_y = 0, .dst_x = 0, .dst_y = 0, .w = 4, .h = 3 } },
        .{ .name = "src が dst を包含", .dst_w = 4, .dst_h = 3, .src_w = 10, .src_h = 9, .x = -3, .y = -4, .expect = .{ .src_x = 3, .src_y = 4, .dst_x = 0, .dst_y = 0, .w = 4, .h = 3 } },
    };
    for (cases) |c| {
        const got = clipBlit(c.dst_w, c.dst_h, c.src_w, c.src_h, c.x, c.y);
        testing.expectEqualDeep(c.expect, got) catch |err| {
            std.debug.print("case '{s}' failed\n", .{c.name});
            return err;
        };
    }
}

test "swizzleBgraToRgba matches scalar（境界長 + 乱数）" {
    var prng = std.Random.DefaultPrng.init(0x73015A12);
    const rng = prng.random();
    // 0/1/3/4/5/7/8/15/16/17 px（SIMD 境界と tail）を強制し、残りは乱数長
    const forced_px = [_]usize{ 0, 1, 3, 4, 5, 7, 8, 15, 16, 17, 64, 65, 127, 128 };
    var trial: usize = 0;
    while (trial < 200) : (trial += 1) {
        const px: usize = if (trial < forced_px.len) forced_px[trial] else (rng.int(usize) % 400);
        const nbytes = px * 4;
        const src = try testing.allocator.alloc(u8, nbytes);
        defer testing.allocator.free(src);
        rng.bytes(src);
        const dst_simd = try testing.allocator.alloc(u8, nbytes);
        defer testing.allocator.free(dst_simd);
        const dst_scalar = try testing.allocator.alloc(u8, nbytes);
        defer testing.allocator.free(dst_scalar);
        swizzleBgraToRgba(dst_simd, src);
        swizzleBgraToRgbaScalar(dst_scalar, src);
        try testing.expectEqualSlices(u8, dst_scalar, dst_simd);
    }
}
