const std = @import("std");
const png = @import("png");
const pixelops = @import("pixelops");

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
/// 毎フレーム全画素相当を走るホットパス。ブレンド/clip は libs/pixelops の
/// 共有実装（blendPremul4 / blendPremul / clipBlit。TASK-51 で移設）を使う。
pub fn drawSprite(
    framebuffer: []u32,
    fb_width: u32,
    fb_height: u32,
    sprite: *const Sprite,
) void {
    // clip 交差はループ外で 1 回計算（clip-hoist）。完全画面外は早期リターン。
    const clip = pixelops.clipBlit(
        fb_width,
        fb_height,
        sprite.image.width,
        sprite.image.height,
        sprite.x,
        sprite.y,
    ) orelse return;

    // ピクセルブレンド（クリップされた範囲のみ）
    // 各行を 4 ピクセル単位の SIMD パス + 残り (0..3 px) のスカラー tail で処理する
    var y: u32 = 0;
    while (y < clip.h) : (y += 1) {
        const src_row_base = (clip.src_y + y) * sprite.image.width + clip.src_x;
        const dst_row_base = (clip.dst_y + y) * fb_width + clip.dst_x;

        var x: u32 = 0;
        // SIMD-4 パス
        // ループ条件 x + 4 <= clip.w と clip.w <= sprite_width - clip.src_x /
        // fb_width - clip.dst_x により、`src_row_base + x + 3 < (src_y+1)*sprite_width` と
        // `dst_row_base + x + 3 < (dst_y+1)*fb_width` が成立し、行をまたぐアクセスは発生しない。
        while (x + 4 <= clip.w) : (x += 4) {
            const src_chunk: *const [4]u32 = sprite.image.pixels[src_row_base + x ..][0..4];
            const dst_chunk: *[4]u32 = framebuffer[dst_row_base + x ..][0..4];
            const sv: pixelops.Vec16u8 = @bitCast(src_chunk.*);
            const dv: pixelops.Vec16u8 = @bitCast(dst_chunk.*);
            dst_chunk.* = @bitCast(pixelops.blendPremul4(dv, sv));
        }
        // スカラー tail
        while (x < clip.w) : (x += 1) {
            const src_idx = src_row_base + x;
            const dst_idx = dst_row_base + x;
            framebuffer[dst_idx] = pixelops.blendPremul(framebuffer[dst_idx], sprite.image.pixels[src_idx]);
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
/// pixelops.blendPremul4 の `@intCast` narrow を安全に通すための簡易クランプとして使う。
fn makePremulPixel(r: u8, g: u8, b: u8, a: u8) u32 {
    const rr = @min(r, a);
    const gg = @min(g, a);
    const bb = @min(b, a);
    const bytes: [4]u8 = .{ rr, gg, bb, a };
    return @bitCast(bytes);
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
            framebuffer[di] = pixelops.blendPremul(framebuffer[di], s.image.pixels[si]);
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
