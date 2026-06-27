const std = @import("std");
const png = @import("png");

const PremultipliedImage = png.PremultipliedImage;

/// スプライト構造体
/// Premultiplied Alpha形式のPNG画像データと画面座標を保持
pub const Sprite = struct {
    image: PremultipliedImage,
    x: i32,
    y: i32,

    /// PNGファイルからスプライトを作成
    /// - io: I/O 実装（main では `init.io`、テストでは `std.testing.io`）
    /// - allocator: メモリアロケータ
    /// - path: PNGファイルのパス
    /// - x: 初期X座標
    /// - y: 初期Y座標
    pub fn init(io: std.Io, allocator: std.mem.Allocator, path: []const u8, x: i32, y: i32) !Sprite {
        const image = try png.decodePNGFilePremultiplied(io, allocator, path);
        return Sprite{
            .image = image,
            .x = x,
            .y = y,
        };
    }

    /// 埋め込みPNGデータからスプライトを作成
    /// @embedFile で埋め込んだバイナリデータから直接読み込む
    /// - allocator: メモリアロケータ
    /// - png_data: PNGバイナリデータ（@embedFileで取得）
    /// - x: 初期X座標
    /// - y: 初期Y座標
    pub fn initFromData(allocator: std.mem.Allocator, png_data: []const u8, x: i32, y: i32) !Sprite {
        const image = try png.decodePNGPremultiplied(allocator, png_data);
        return Sprite{
            .image = image,
            .x = x,
            .y = y,
        };
    }

    /// スプライトを破棄してメモリを解放
    pub fn deinit(self: *Sprite, allocator: std.mem.Allocator) void {
        self.image.deinit(allocator);
    }

    /// スプライトを移動
    /// - dx: X方向の移動量
    /// - dy: Y方向の移動量
    pub fn move(self: *Sprite, dx: i32, dy: i32) void {
        self.x += dx;
        self.y += dy;
    }
};

// SIMD用の型エイリアス
const Vec4u16 = @Vector(4, u16);
const Vec16u8 = @Vector(16, u8);
const Vec16u16 = @Vector(16, u16);

/// x / 255 の高速近似計算（ベクトル版）
/// 各要素に対して 0 <= x <= 65025 の範囲で正確
inline fn div255Vec(x: Vec4u16) Vec4u16 {
    const one: Vec4u16 = @splat(1);
    const eight: @Vector(4, u4) = @splat(8);
    return (x + one + (x >> eight)) >> eight;
}

/// x / 255 の高速近似計算（16-lane 版）
inline fn div255Vec16(x: Vec16u16) Vec16u16 {
    const one: Vec16u16 = @splat(1);
    const eight: @Vector(16, u4) = @splat(8);
    return (x + one + (x >> eight)) >> eight;
}

/// u32ピクセルからVec4u16への変換
/// ピクセルフォーマット: 0xAARRGGBB → [B, G, R, A] としてu16ベクトル化
inline fn pixelToVec(pixel: u32) Vec4u16 {
    const bytes: [4]u8 = @bitCast(pixel);
    return .{
        @as(u16, bytes[0]),
        @as(u16, bytes[1]),
        @as(u16, bytes[2]),
        @as(u16, bytes[3]),
    };
}

/// Vec4u16からu32ピクセルへの変換
/// アルファチャンネルは0xFFに強制
inline fn vecToPixel(vec: Vec4u16) u32 {
    const result_bytes: [4]u8 = .{
        @truncate(vec[0]),
        @truncate(vec[1]),
        @truncate(vec[2]),
        0xFF,
    };
    return @bitCast(result_bytes);
}

/// 4 ピクセル同時の Premultiplied blend (16-lane SIMD)
/// 入出力レイアウト: メモリ上 [B0 G0 R0 A0 B1 G1 R1 A1 B2 G2 R2 A2 B3 G3 R3 A3]
/// 出力アルファは 0xFF 強制（ウィンドウ常に不透明）
///
/// PRECONDITION: src_pre の各ピクセルは premultiplied 済みで R/G/B <= A を満たすこと。
/// この不変条件を破ると blended の値域が u8 範囲外となり、`@intCast(Vec16u16 -> Vec16u8)`
/// で Debug 時 panic / ReleaseFast 時 UB を引き起こす。PNG デコード時に
/// `decodePNGFilePremultiplied` / `decodePNGPremultiplied` を通せばこの不変は保たれる。
inline fn blend4Pixels(dst: Vec16u8, src_pre: Vec16u8) Vec16u8 {
    // 各ピクセルの A (memory index 3/7/11/15) を 4 lane ぶん複製。
    // 後段の alpha_mask の true 位置 (3/7/11/15) と対応しており、
    // 「ピクセル内 A レーン位置」という共通の解釈で揃えている。
    const alpha_idx: @Vector(16, i32) = .{ 3, 3, 3, 3, 7, 7, 7, 7, 11, 11, 11, 11, 15, 15, 15, 15 };
    const src_a = @shuffle(u8, src_pre, undefined, alpha_idx);

    // u8 -> u16 widening
    const src16: Vec16u16 = @intCast(src_pre);
    const dst16: Vec16u16 = @intCast(dst);
    const src_a16: Vec16u16 = @intCast(src_a);
    const inv_a: Vec16u16 = @as(Vec16u16, @splat(255)) - src_a16;

    // out = src_pre + dst * (255 - src_a) / 255
    const blended16 = src16 + div255Vec16(dst16 * inv_a);
    const blended: Vec16u8 = @intCast(blended16);

    // アルファレーンを 0xFF 強制
    const alpha_mask: @Vector(16, bool) = .{
        false, false, false, true,
        false, false, false, true,
        false, false, false, true,
        false, false, false, true,
    };
    return @select(u8, alpha_mask, @as(Vec16u8, @splat(0xFF)), blended);
}

/// Premultiplied Alpha形式のアルファブレンディング（SIMD版）
/// out = src_pre + dst * (1 - src_a)
/// ピクセルフォーマット: u32 = 0xAARRGGBB（リトルエンディアン、メモリ上[B,G,R,A]順）
///
/// PRECONDITION: src_pre は premultiplied 済みで R/G/B <= A を満たすこと。
/// （`blend4Pixels` の SIMD narrow と同じ前提。スカラー版はオーバーフローしないが、
///  blend 結果の数学的整合性のために同じ不変を要求する）
fn blendPixel(dst: u32, src_pre: u32) u32 {
    const src_a: u8 = @truncate(src_pre >> 24);

    // 早期リターン: 完全透明（出力アルファは常に0xFFに強制）
    if (src_a == 0) return dst | 0xFF000000;

    // 早期リターン: 完全不透明
    if (src_a == 255) return src_pre | 0xFF000000;

    // SIMD計算: 4チャンネル同時にブレンディング
    const src_vec = pixelToVec(src_pre);
    const dst_vec = pixelToVec(dst);
    const inv_a: Vec4u16 = @splat(@as(u16, 255 - src_a));

    // Premultiplied alpha blending: out = src_pre + dst * (255 - src_a) / 255
    const blended = src_vec + div255Vec(dst_vec * inv_a);

    return vecToPixel(blended);
}

/// フレームバッファにスプライトを描画（クリッピング処理付き）
///
/// Premultiplied Alpha形式のアルファブレンディング対応:
/// - 透明ピクセル（alpha=0）は背景を透過
/// - 半透明ピクセルは背景とブレンド
///
/// - framebuffer: フレームバッファ（canonical BGRA 0xAARRGGBB 形式）
/// - fb_width: フレームバッファの幅
/// - fb_height: フレームバッファの高さ
/// - sprite: 描画するスプライト
pub fn drawSprite(
    framebuffer: []u32,
    fb_width: u32,
    fb_height: u32,
    sprite: *const Sprite,
) void {
    const sprite_width = sprite.image.width;
    const sprite_height = sprite.image.height;

    // 早期リターン: スプライトが完全に画面外の場合
    if (sprite.x >= @as(i32, @intCast(fb_width)) or
        sprite.y >= @as(i32, @intCast(fb_height)) or
        sprite.x + @as(i32, @intCast(sprite_width)) <= 0 or
        sprite.y + @as(i32, @intCast(sprite_height)) <= 0)
    {
        return;
    }

    // クリッピング範囲の計算
    // ソース画像の描画開始位置
    const src_x_start: u32 = if (sprite.x < 0) @intCast(-sprite.x) else 0;
    const src_y_start: u32 = if (sprite.y < 0) @intCast(-sprite.y) else 0;

    // フレームバッファの書き込み開始位置
    const dst_x_start: u32 = if (sprite.x < 0) 0 else @intCast(sprite.x);
    const dst_y_start: u32 = if (sprite.y < 0) 0 else @intCast(sprite.y);

    // 実際に描画する幅と高さ
    const visible_width = @min(
        sprite_width - src_x_start,
        fb_width - dst_x_start,
    );
    const visible_height = @min(
        sprite_height - src_y_start,
        fb_height - dst_y_start,
    );

    // ピクセルブレンド（クリップされた範囲のみ）
    // 各行を 4 ピクセル単位の SIMD パス + 残り (0..3 px) のスカラー tail で処理する
    var y: u32 = 0;
    while (y < visible_height) : (y += 1) {
        const src_y = src_y_start + y;
        const dst_y = dst_y_start + y;
        const src_row_base = src_y * sprite_width + src_x_start;
        const dst_row_base = dst_y * fb_width + dst_x_start;

        var x: u32 = 0;
        // SIMD-4 パス
        // ループ条件 x + 4 <= visible_width と visible_width <= sprite_width - src_x_start /
        // fb_width - dst_x_start により、`src_row_base + x + 3 < (src_y+1)*sprite_width` と
        // `dst_row_base + x + 3 < (dst_y+1)*fb_width` が成立し、行をまたぐアクセスは発生しない。
        while (x + 4 <= visible_width) : (x += 4) {
            const src_chunk: *const [4]u32 = sprite.image.pixels[src_row_base + x ..][0..4];
            const dst_chunk: *[4]u32 = framebuffer[dst_row_base + x ..][0..4];
            const sv: Vec16u8 = @bitCast(src_chunk.*);
            const dv: Vec16u8 = @bitCast(dst_chunk.*);
            dst_chunk.* = @bitCast(blend4Pixels(dv, sv));
        }
        // スカラー tail
        while (x < visible_width) : (x += 1) {
            const src_idx = src_row_base + x;
            const dst_idx = dst_row_base + x;
            framebuffer[dst_idx] = blendPixel(framebuffer[dst_idx], sprite.image.pixels[src_idx]);
        }
    }
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

/// Premultiplied 不変条件 (R/G/B <= A) を満たす u32 ピクセルを生成する。
/// `@intCast(Vec16u16 -> Vec16u8)` の narrow が範囲内に収まることを保証するため
/// すべてのテストデータはこのヘルパーを通すこと。
///
/// 注: これは **不変条件のみ** を満たし、厳密な premultiplied 値
/// (R' = R * A / 255) を生成するわけではない。例: R=100, A=128 →
/// 真の premultiplied は 50 だが、本関数は min(100, 128) = 100 を返す。
/// blend4Pixels の `@intCast` narrow を安全に通すための簡易クランプとして使う。
fn makePremulPixel(r: u8, g: u8, b: u8, a: u8) u32 {
    const rr = @min(r, a);
    const gg = @min(g, a);
    const bb = @min(b, a);
    const bytes: [4]u8 = .{ rr, gg, bb, a };
    return @bitCast(bytes);
}

// SIMD 4 ピクセルブレンド結果がスカラー版と完全一致することを保証する。
test "blend4Pixels matches scalar blendPixel" {
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
                // R/G/B が A を超える入力は makePremulPixel でクランプされる
                makePremulPixel(255, 255, 255, 100),
                makePremulPixel(0, 0, 255, 100),
                makePremulPixel(255, 0, 0, 200),
                makePremulPixel(128, 64, 32, 50),
            },
            .dst = .{ 0xFF000000, 0xFFFFFFFF, 0xFF808080, 0xFF7F3F1F },
        },
    };

    for (cases) |c| {
        // expected: scalar blendPixel を 4 回適用
        var expected: [4]u32 = undefined;
        for (0..4) |i| expected[i] = blendPixel(c.dst[i], c.src[i]);

        // actual: blend4Pixels で 1 回
        const sv: Vec16u8 = @bitCast(c.src);
        const dv: Vec16u8 = @bitCast(c.dst);
        const actual: [4]u32 = @bitCast(blend4Pixels(dv, sv));

        testing.expectEqualSlices(u32, &expected, &actual) catch |err| {
            std.debug.print("case '{s}' failed\n", .{c.name});
            return err;
        };
    }
}

/// PremultipliedImage 風の最小データを作るテスト用ヘルパー。
/// テストの allocator で pixels を確保し、Sprite に詰めて返す。
fn makeTestSprite(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    fill: u32,
) !Sprite {
    const pixels = try allocator.alloc(u32, width * height);
    @memset(pixels, fill);
    return Sprite{
        .image = .{ .width = width, .height = height, .pixels = pixels },
        .x = 0,
        .y = 0,
    };
}

// drawSprite の SIMD-4 経路と scalar tail 経路が、SIMD 化前の参照実装と
// 完全一致することを保証する。
//
// visible_width のケース:
//   - 4, 8        : tail なし純 SIMD 経路 (4-pixel chunk 読書き + @bitCast 配線の end-to-end)
//   - 1, 2, 3     : SIMD 経路を通らず全 tail
//   - 5, 6, 7     : SIMD + tail 混在
//
// 比較対象 drawSpriteScalarRef は SIMD 化前と等価な参照実装。
// drawSprite の挙動を変える将来のリファクタでは、こちらのテスト側を
// 先に更新してから本体に手を入れる運用とする。
fn drawSpriteScalarRef(
    framebuffer: []u32,
    fb_width: u32,
    fb_height: u32,
    s: *const Sprite,
) void {
    const sw = s.image.width;
    const sh = s.image.height;
    if (s.x >= @as(i32, @intCast(fb_width)) or
        s.y >= @as(i32, @intCast(fb_height)) or
        s.x + @as(i32, @intCast(sw)) <= 0 or
        s.y + @as(i32, @intCast(sh)) <= 0) return;

    const sxs: u32 = if (s.x < 0) @intCast(-s.x) else 0;
    const sys: u32 = if (s.y < 0) @intCast(-s.y) else 0;
    const dxs: u32 = if (s.x < 0) 0 else @intCast(s.x);
    const dys: u32 = if (s.y < 0) 0 else @intCast(s.y);
    const vw = @min(sw - sxs, fb_width - dxs);
    const vh = @min(sh - sys, fb_height - dys);

    var y: u32 = 0;
    while (y < vh) : (y += 1) {
        var x: u32 = 0;
        while (x < vw) : (x += 1) {
            const si = (sys + y) * sw + (sxs + x);
            const di = (dys + y) * fb_width + (dxs + x);
            framebuffer[di] = blendPixel(framebuffer[di], s.image.pixels[si]);
        }
    }
}

test "drawSprite SIMD path matches scalar reference (various visible_width)" {
    const allocator = testing.allocator;

    // 各 width で sprite と framebuffer を作り、SIMD 版と参照版の結果を比較する。
    // sprite の中身は premultiplied 不変を守った混在パターン。
    const widths = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 11, 16, 17, 32 };

    for (widths) |w| {
        const fb_w: u32 = w; // sprite を画面いっぱいに描画 → visible_width = w
        const fb_h: u32 = 3;

        // sprite を作成
        var s = try makeTestSprite(allocator, w, fb_h, 0);
        defer allocator.free(s.image.pixels);

        // sprite に premultiplied な混在パターンを書く
        var prng = std.Random.DefaultPrng.init(0xCAFEBABE +% w);
        const rng = prng.random();
        for (s.image.pixels) |*p| {
            const a = rng.int(u8);
            const r = rng.int(u8);
            const g = rng.int(u8);
            const b = rng.int(u8);
            p.* = makePremulPixel(r, g, b, a);
        }

        // framebuffer 2 枚を同じ初期値で用意
        const fb_simd = try allocator.alloc(u32, fb_w * fb_h);
        defer allocator.free(fb_simd);
        const fb_ref = try allocator.alloc(u32, fb_w * fb_h);
        defer allocator.free(fb_ref);

        for (fb_simd, fb_ref, 0..) |*ps, *pr, i| {
            // 適当な背景パターン (alpha=0xFF, RGB は位置依存)
            const v: u32 = 0xFF000000 | (@as(u32, @truncate(i)) *% 0x010203);
            ps.* = v;
            pr.* = v;
        }

        drawSprite(fb_simd, fb_w, fb_h, &s);
        drawSpriteScalarRef(fb_ref, fb_w, fb_h, &s);

        testing.expectEqualSlices(u32, fb_ref, fb_simd) catch |err| {
            std.debug.print("width={d} mismatch\n", .{w});
            return err;
        };
    }
}

test "drawSprite clipping at screen edges matches scalar reference" {
    const allocator = testing.allocator;

    // 画面端 (左・右・上・下) でスプライトを半分はみ出させ、
    // src_x_start / src_y_start != 0 経路と visible_width が 4 で割り切れない経路を踏む。
    const fb_w: u32 = 10;
    const fb_h: u32 = 8;
    const sw: u32 = 6;
    const sh: u32 = 5;

    var s = try makeTestSprite(allocator, sw, sh, 0);
    defer allocator.free(s.image.pixels);

    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const rng = prng.random();
    for (s.image.pixels) |*p| {
        p.* = makePremulPixel(rng.int(u8), rng.int(u8), rng.int(u8), rng.int(u8));
    }

    const positions = [_]struct { x: i32, y: i32 }{
        .{ .x = -3, .y = 0 }, // 左端はみ出し
        .{ .x = 7, .y = 0 }, // 右端はみ出し
        .{ .x = 0, .y = -2 }, // 上端はみ出し
        .{ .x = 0, .y = 5 }, // 下端はみ出し
        .{ .x = -3, .y = -2 }, // 左上はみ出し
        .{ .x = 7, .y = 5 }, // 右下はみ出し
    };

    for (positions) |pos| {
        s.x = pos.x;
        s.y = pos.y;

        const fb_simd = try allocator.alloc(u32, fb_w * fb_h);
        defer allocator.free(fb_simd);
        const fb_ref = try allocator.alloc(u32, fb_w * fb_h);
        defer allocator.free(fb_ref);
        @memset(fb_simd, 0xFF202020);
        @memset(fb_ref, 0xFF202020);

        drawSprite(fb_simd, fb_w, fb_h, &s);
        drawSpriteScalarRef(fb_ref, fb_w, fb_h, &s);

        testing.expectEqualSlices(u32, fb_ref, fb_simd) catch |err| {
            std.debug.print("pos=({d},{d}) mismatch\n", .{ pos.x, pos.y });
            return err;
        };
    }
}
