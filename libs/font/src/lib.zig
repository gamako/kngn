// libs/font: canonical shared font abstraction plus pixel/geom primitives.
// gui and future OutlineFont/BMFont use this module (`@import("font")`).

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
pub const ivs = @import("ivs.zig");
pub const text_layer = @import("text_layer.zig");
pub const system_font = @import("system_font.zig");

// pixel/geom primitives (canonical definitions re-exported by gui)
pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const RenderTarget = geom.RenderTarget;
pub const Color = color.Color;

// Shared font abstraction
pub const Metrics = font.Metrics;
pub const Font = font.Font;
pub const plotCoverage = font.plotCoverage;
pub const blitCoverage = font.blitCoverage;
pub const blitRGBA = font.blitRGBA;
pub const blitCoverageStraight = font.blitCoverageStraight;
pub const blitRGBAStraight = font.blitRGBAStraight;
pub const clipCoverage = font.clipCoverage;
pub const CovClip = font.CovClip;

// Text rasterization onto a transparent layer
pub const TextLayer = text_layer.TextLayer;
pub const renderTextLayer = text_layer.renderTextLayer;
pub const default_font_bytes = text_layer.default_font_bytes;
pub const LoadedSystemFontFace = system_font.LoadedFace;
pub const loadSystemTextFace = system_font.loadSystemTextFace;
pub const loadSystemTextFontBytes = system_font.loadSystemTextFontBytes;

// sfnt (TrueType/OpenType) container + cmap + glyf outlines
pub const SfntFile = sfnt.SfntFile;
pub const Cmap = cmap.Cmap;
pub const Outline = outline.Outline;
pub const Glyf = glyf.Glyf;
pub const rasterize = raster.rasterize;
pub const Bitmap = raster.Bitmap;
pub const FontFace = outline_font.FontFace;
pub const OutlineFont = outline_font.OutlineFont;
pub const BMFont = bmfont.BMFont;

// sbix (embedded color bitmap) table parser
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
    _ = ivs;
    _ = text_layer;
    _ = system_font;
}

test "system_font public exports are reachable" {
    _ = LoadedSystemFontFace;
    _ = loadSystemTextFace;
    _ = loadSystemTextFontBytes;
}
