//! 実アプリ向け system OutlineFont 注入ヘルパ（TASK-138）。
//!
//! 借用チェーン bytes ← FontFace ← OutlineFont ← Font（asFont は借用 view）のため、
//! **最終配置後に in-place load**し、ctx.font は後から再ポイントする。
//! ホットパス: 起動時（初期化時）のみ。フレーム毎・RT の新規経路は追加しない。

const std = @import("std");
const builtin = @import("builtin");
const gui = @import("gui");
const font = @import("font");

/// GUI Context へ注入する system OutlineFont の所有束。
/// App/ローカルの最終配置先に置き、`load` は pointer receiver でその場に詰めること。
pub const GuiFont = struct {
    gpa: std.mem.Allocator = undefined,
    bytes: ?[]u8 = null,
    face: ?font.FontFace = null,
    outline: ?font.OutlineFont = null,

    /// system text face を読み、self 上に bytes/face/outline を構築する。
    /// 未検出・失敗時は outline=null のまま警告を出し、`asFont` が default_font へ落ちる（AC3）。
    pub fn load(self: *GuiFont, io: std.Io, gpa: std.mem.Allocator) void {
        self.gpa = gpa;
        // wasm には native システムフォントパスが無い（旧 loadSystemTextFontBytes の
        // "pixie 用" isWasm guard を踏襲）。outline=null のまま default_font へ落ちる。
        if (builtin.cpu.arch.isWasm()) return;
        const loaded = font.loadSystemTextFace(io, gpa) orelse {
            std.log.warn("GuiFont: no usable system font; falling back to gui.default_font", .{});
            return;
        };
        self.bytes = loaded.bytes;
        self.face = loaded.face;
        // `&self.face.?` は最終配置済み self 内の安定アドレス（move 後に取らない）。
        self.outline = font.OutlineFont.init(gpa, &self.face.?, 16);
    }

    /// OutlineFont があればその借用 Font、無ければ `gui.default_font`。
    pub fn asFont(self: *GuiFont) gui.Font {
        if (self.outline) |*o| return o.asFont();
        return gui.default_font;
    }

    /// canvas 用に同じ bytes を参照（二重ロード回避）。所有は GuiFont。
    pub fn systemBytes(self: *const GuiFont) ?[]const u8 {
        return self.bytes;
    }

    /// Context.deinit の後に呼ぶこと。順序: outline.deinit → free(bytes)。
    pub fn deinit(self: *GuiFont) void {
        if (self.outline) |*o| o.deinit();
        self.outline = null;
        self.face = null;
        if (self.bytes) |b| self.gpa.free(b);
        self.bytes = null;
    }
};

test "GuiFont fallback: unloaded asFont metrics match default_font" {
    var gf: GuiFont = .{};
    const got = gf.asFont().metrics();
    const want = gui.default_font.metrics();
    try std.testing.expectEqual(want.line_height, got.line_height);
    try std.testing.expectEqual(want.ascent, got.ascent);
    try std.testing.expectEqual(want.descent, got.descent);
}
