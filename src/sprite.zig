const std = @import("std");
const png_decoder = @import("png-decoder");

const PremultipliedImage = png_decoder.PremultipliedImage;

/// スプライト構造体
/// Premultiplied Alpha形式のPNG画像データと画面座標を保持
pub const Sprite = struct {
    image: PremultipliedImage,
    x: i32,
    y: i32,

    /// PNGファイルからスプライトを作成
    /// - allocator: メモリアロケータ
    /// - path: PNGファイルのパス
    /// - x: 初期X座標
    /// - y: 初期Y座標
    pub fn init(allocator: std.mem.Allocator, path: []const u8, x: i32, y: i32) !Sprite {
        const image = try png_decoder.decodePNGFilePremultiplied(allocator, path);
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
        const image = try png_decoder.decodePNGPremultiplied(allocator, png_data);
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

/// x / 255 の高速近似計算（ベクトル版）
/// 各要素に対して 0 <= x <= 65025 の範囲で正確
inline fn div255Vec(x: Vec4u16) Vec4u16 {
    const one: Vec4u16 = @splat(1);
    const eight: @Vector(4, u4) = @splat(8);
    return (x + one + (x >> eight)) >> eight;
}

/// u32ピクセルからVec4u16への変換
/// ピクセルフォーマット: 0xAABBGGRR → [R, G, B, A] としてu16ベクトル化
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

/// Premultiplied Alpha形式のアルファブレンディング（SIMD版）
/// out = src_pre + dst * (1 - src_a)
/// ピクセルフォーマット: u32 = 0xAABBGGRR（リトルエンディアン、メモリ上[R,G,B,A]順）
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
/// - framebuffer: フレームバッファ（RGBA8888形式）
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
    var y: u32 = 0;
    while (y < visible_height) : (y += 1) {
        const src_y = src_y_start + y;
        const dst_y = dst_y_start + y;

        var x: u32 = 0;
        while (x < visible_width) : (x += 1) {
            const src_x = src_x_start + x;
            const dst_x = dst_x_start + x;

            const src_idx = src_y * sprite_width + src_x;
            const dst_idx = dst_y * fb_width + dst_x;

            framebuffer[dst_idx] = blendPixel(framebuffer[dst_idx], sprite.image.pixels[src_idx]);
        }
    }
}
