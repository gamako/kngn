//! Helper that injects a system OutlineFont for real apps.
//!
//! Borrowing chain: bytes ← FontFace ← OutlineFont ← Font (asFont is a borrowed view), so
//! **load in place after the final placement**, then re-point ctx.font.
//! Hot path: startup (init) only. No new per-frame or RT path.

const std = @import("std");
const builtin = @import("builtin");
const gui = @import("gui");
const font = @import("font");

/// Pixel size for the small node-title font. Smaller than the usual GUI 16px so
/// patch-canvas node titles stay at a readable density.
const TITLE_FONT_PX: f32 = 11;

/// Owned bundle of a system OutlineFont injected into the GUI Context.
/// Place at the App/local final site; `load` must fill in place via a pointer receiver.
pub const GuiFont = struct {
    gpa: std.mem.Allocator = undefined,
    bytes: ?[]u8 = null,
    face: ?font.FontFace = null,
    outline: ?font.OutlineFont = null,
    /// For smaller sizes (node titles, etc.). Reuses the same face; does not double-load.
    outline_small: ?font.OutlineFont = null,

    /// Load the system text face and build bytes/face/outline(/outline_small) on self.
    /// On miss/failure, leave outline=null, warn, and let `asFont`/`asTitleFont` fall back to default_font.
    pub fn load(self: *GuiFont, io: std.Io, gpa: std.mem.Allocator) void {
        self.gpa = gpa;
        // wasm has no native system font path (same isWasm guard as the former
        // loadSystemTextFontBytes "for pixie"). Leave outline=null and fall back to default_font.
        if (builtin.cpu.arch.isWasm()) return;
        const loaded = font.loadSystemTextFace(io, gpa) orelse {
            std.log.warn("GuiFont: no usable system font; falling back to gui.default_font", .{});
            return;
        };
        self.bytes = loaded.bytes;
        self.face = loaded.face;
        // `&self.face.?` is a stable address inside the finally-placed self (do not take it after a move).
        self.outline = font.OutlineFont.init(gpa, &self.face.?, 16);
        self.outline_small = font.OutlineFont.init(gpa, &self.face.?, TITLE_FONT_PX);
    }

    /// Borrowed Font from OutlineFont when present; otherwise `gui.default_font`.
    pub fn asFont(self: *GuiFont) gui.Font {
        if (self.outline) |*o| return o.asFont();
        return gui.default_font;
    }

    /// Borrowed Font from the small title OutlineFont when present; otherwise `gui.default_font`
    /// (same fallback contract as asFont).
    pub fn asTitleFont(self: *GuiFont) gui.Font {
        if (self.outline_small) |*o| return o.asFont();
        return gui.default_font;
    }

    /// Borrow the same bytes for canvas use (avoid double-load). Ownership stays with GuiFont.
    pub fn systemBytes(self: *const GuiFont) ?[]const u8 {
        return self.bytes;
    }

    /// Call after Context.deinit. Order: outline(_small).deinit → free(bytes).
    pub fn deinit(self: *GuiFont) void {
        if (self.outline_small) |*o| o.deinit();
        self.outline_small = null;
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
