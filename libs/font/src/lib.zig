// libs/font: 共通フォント抽象 + pixel/geom プリミティブの正準定義。
// gui や将来の OutlineFont/BMFont はこのモジュール（`@import("font")`）を使う。

pub const geom = @import("geom.zig");
pub const color = @import("color.zig");
pub const font = @import("font.zig");
pub const byte_reader = @import("byte_reader.zig");
pub const sfnt = @import("sfnt.zig");
pub const cmap = @import("cmap.zig");
pub const outline = @import("outline.zig");
pub const glyf = @import("glyf.zig");
pub const raster = @import("raster.zig");
pub const charstring = @import("charstring.zig");
pub const cff = @import("cff.zig");
pub const outline_font = @import("outline_font.zig");
pub const bmfont = @import("bmfont.zig");
pub const sbix = @import("sbix.zig");
pub const fvar = @import("fvar.zig");
pub const avar = @import("avar.zig");
pub const gvar = @import("gvar.zig");
pub const hvar = @import("hvar.zig");
pub const var_common = @import("var_common.zig");
pub const text_layer = @import("text_layer.zig");

// pixel/geom プリミティブ（gui が再エクスポートする正準定義）
pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const RenderTarget = geom.RenderTarget;
pub const Color = color.Color;

// 共通フォント抽象
pub const Metrics = font.Metrics;
pub const Font = font.Font;
pub const plotCoverage = font.plotCoverage;
pub const blitCoverage = font.blitCoverage;
pub const blitRGBA = font.blitRGBA;
pub const blitCoverageStraight = font.blitCoverageStraight;
pub const blitRGBAStraight = font.blitRGBAStraight;
pub const clipCoverage = font.clipCoverage;
pub const CovClip = font.CovClip;

// 透明レイヤーへのテキストラスタライズ（TASK-79.4）
pub const TextLayer = text_layer.TextLayer;
pub const renderTextLayer = text_layer.renderTextLayer;
pub const default_font_bytes = text_layer.default_font_bytes;

// sfnt(TrueType/OpenType) コンテナ + cmap + glyf アウトライン
pub const SfntFile = sfnt.SfntFile;
pub const Cmap = cmap.Cmap;
pub const Outline = outline.Outline;
pub const Glyf = glyf.Glyf;
pub const rasterize = raster.rasterize;
pub const Bitmap = raster.Bitmap;
pub const FontFace = outline_font.FontFace;
pub const OutlineFont = outline_font.OutlineFont;
pub const BMFont = bmfont.BMFont;

// sbix(埋め込みカラービットマップ)テーブルパーサ（TASK-26.2。統合は TASK-26.3）
pub const Sbix = sbix.Sbix;

test {
    _ = geom;
    _ = color;
    _ = font;
    _ = byte_reader;
    _ = sfnt;
    _ = cmap;
    _ = outline;
    _ = glyf;
    _ = raster;
    _ = charstring;
    _ = cff;
    _ = outline_font;
    _ = bmfont;
    _ = sbix;
    _ = fvar;
    _ = avar;
    _ = gvar;
    _ = hvar;
    _ = var_common;
    _ = text_layer;
}
