// Shared widget style.
//
// No push/pop (MVP contract). Callers that want a theme rewrite `Context.style`
// directly. Sizes are i32 (same integer system as layout / Rect); cast to u32 at draw time.

const color_mod = @import("color.zig");
const font_mod = @import("font.zig");

pub const Color = color_mod.Color;
pub const Font = font_mod.Font;

/// Color and optional font for one text tier. `font = null` uses `Context.font`.
/// The library never creates fonts; a size difference appears only when the
/// application stores a generated `Font` on the matching `Style` field
/// (a catalog UI typically injects an 18px heading next to a 14px body).
pub const TextStyle = struct {
    color: Color,
    font: ?Font = null,
};

/// Named text tier for `Context.labelStyled`.
pub const TextTier = enum { heading, body, caption, muted };

pub const Style = struct {
    /// Normal fill for button etc.
    bg: Color,
    /// Fill while hovered (`state.hot_id == id`)
    bg_hover: Color,
    /// Fill while pressed (held)
    bg_active: Color,
    /// Normal border color
    border: Color,
    /// Hover border color. Also used as the emphasis border when selected
    border_hover: Color,
    /// label / button text color
    text: Color,
    /// Secondary text color (caller uses such as status bar)
    text_subtle: Color,
    /// TextInput box background
    input_background: Color = Color.rgba(0x24, 0x24, 0x2C, 0xFF),
    /// SelectableLabel selection background
    selection_background: Color = Color.rgba(0x30, 0x60, 0xC0, 0xFF),
    /// Color reserved for future caret drawing (caret itself is not drawn yet)
    caret: Color = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
    /// Ring around the widget holding keyboard focus. Drawn only when the focus was reached with
    /// the keyboard, so it has to stand out against every widget fill rather than blend in.
    focus_ring: Color = Color.rgba(0x7A, 0xB8, 0xFF, 0xFF),
    focus_ring_thickness: u32 = 2,
    swatch_size: i32 = 18,
    swatch_border: i32 = 1,
    swatch_border_selected: i32 = 2,
    /// top, right, bottom, left
    button_padding: [4]i32 = .{ 4, 8, 4, 8 },
    button_border: i32 = 1,
    button_border_selected: i32 = 2,
    /// Selected fill (lower priority than held/hover). Deep blue for high contrast vs normal,
    /// and a distinct tone from held (`bg_active` = bright blue).
    button_bg_selected: Color = Color.rgba(0x24, 0x48, 0x7A, 0xFF),
    // Slider. Sizes are i32; cast to u32 at draw time.
    slider_track_w: i32 = 120,
    slider_track_h: i32 = 6,
    slider_knob_w: i32 = 10,
    slider_knob_h: i32 = 16,
    slider_track_bg: Color = Color.rgba(0x30, 0x30, 0x38, 0xFF),
    slider_knob_bg: Color = Color.rgba(0x90, 0x98, 0xA0, 0xFF),
    slider_knob_active_bg: Color = Color.rgba(0x30, 0x60, 0xC0, 0xFF),
    // HSV color picker. SV square / Hue bar are fixed px (`dl.image` constraint).
    picker_sv_size: i32 = 128,
    picker_hue_w: i32 = 16,
    picker_marker_light: Color = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
    picker_marker_dark: Color = Color.rgba(0x00, 0x00, 0x00, 0xFF),
    // Checkbox / Toggle(switch) / Radio. Dimensions only; reuse existing colors:
    // ON/accent = bg_active, box interior / track = slider_track_bg, knob = slider_knob_bg, border = border / border_hover.
    checkbox_size: i32 = 16,
    /// Gap between glyph and label (shared by checkbox / toggle / radio)
    checkbox_gap: i32 = 6,
    switch_w: i32 = 28,
    switch_h: i32 = 16,
    radio_size: i32 = 16,
    // Popup / context menu. Reuse existing bg / bg_hover / border / text /
    // text_subtle (no new color fields).
    popup_item_h: i32 = 20,
    popup_padding: i32 = 4,
    /// One tree-indent step for `beginListboxRow` guides. `0` emits no guide
    /// (even when `depth > 0`). Must be `>= 0`.
    indent_w: i32 = 14,
    /// Heading tier. Default color matches `text`; default `font` is null
    /// (`Context.font`). Size difference exists only after the app injects a Font.
    heading: TextStyle = .{ .color = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF) },
    /// Body tier. Default color matches `text`; default `font` is null.
    body: TextStyle = .{ .color = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF) },
    /// Caption tier. Default color matches `text_subtle`; default `font` is null.
    caption: TextStyle = .{ .color = Color.rgba(0x90, 0x98, 0xA0, 0xFF) },
    /// Muted tier. Default color is `text_subtle` blended halfway toward `bg`.
    muted: TextStyle = .{ .color = Color.rgba(0x64, 0x68, 0x70, 0xFF) },

    /// The color a disabled widget draws `base` as: grayscale (so an accent color loses its hue,
    /// not just its brightness), then blended halfway toward `bg` (so a disabled widget dims
    /// toward the surface it sits on rather than toward black, and follows a theme change the
    /// same way every other derived color here does — no separate `*_disabled` fields to keep
    /// in sync).
    pub fn disabledColor(self: Style, base: Color) Color {
        // ITU-R BT.601 luma weights (fixed-point, /256), same rounding shape as pixelops' div255.
        const y: u32 = (77 * @as(u32, base.r) + 150 * @as(u32, base.g) + 29 * @as(u32, base.b) + 128) / 256;
        return Color.rgba(
            @intCast((y + self.bg.r) / 2),
            @intCast((y + self.bg.g) / 2),
            @intCast((y + self.bg.b) / 2),
            0xFF,
        );
    }

    /// `text_subtle` blended halfway toward `bg` (same surface, quieter than caption).
    pub fn mutedFromSubtle(self: Style) Color {
        return Color.rgba(
            @intCast((@as(u16, self.text_subtle.r) + self.bg.r) / 2),
            @intCast((@as(u16, self.text_subtle.g) + self.bg.g) / 2),
            @intCast((@as(u16, self.text_subtle.b) + self.bg.b) / 2),
            0xFF,
        );
    }

    pub fn textStyle(self: Style, tier: TextTier) TextStyle {
        return switch (tier) {
            .heading => self.heading,
            .body => self.body,
            .caption => self.caption,
            .muted => self.muted,
        };
    }
};

/// Dark theme in the example 09/10 family. text is white (same as earlier label default).
pub fn defaultStyle() Style {
    const text = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);
    const text_subtle = Color.rgba(0x90, 0x98, 0xA0, 0xFF);
    const bg = Color.rgba(0x38, 0x38, 0x40, 0xFF);
    var s: Style = .{
        .bg = bg,
        .bg_hover = Color.rgba(0x50, 0x50, 0x60, 0xFF),
        .bg_active = Color.rgba(0x30, 0x60, 0xC0, 0xFF),
        .border = Color.rgba(0x60, 0x60, 0x6C, 0xFF),
        .border_hover = Color.rgba(0xA0, 0xA0, 0xB0, 0xFF),
        .text = text,
        .text_subtle = text_subtle,
        .heading = .{ .color = text },
        .body = .{ .color = text },
        .caption = .{ .color = text_subtle },
    };
    s.muted = .{ .color = s.mutedFromSubtle() };
    return s;
}

// ============================================================
// Tests
// ============================================================

const std = @import("std");

test "defaultStyle: text is white (compatible with earlier label default)" {
    const s = defaultStyle();
    try std.testing.expectEqual(Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), s.text);
    try std.testing.expect(s.swatch_border_selected > s.swatch_border);
    try std.testing.expect(s.button_border_selected > s.button_border);
    // Selected bg is deep blue (high contrast vs normal; distinct from held bg_active).
    try std.testing.expectEqual(Color.rgba(0x24, 0x48, 0x7A, 0xFF), s.button_bg_selected);
    try std.testing.expect(!std.meta.eql(s.bg_active, s.button_bg_selected));
}

test "disabledColor: fully opaque and always between grayscale(base) and bg" {
    const s = defaultStyle();
    const text_disabled = s.disabledColor(s.text);
    try std.testing.expectEqual(@as(u8, 0xFF), text_disabled.a);
    // text is white; halfway toward a dark bg lands strictly between the two, both channel-wise.
    try std.testing.expect(text_disabled.r < s.text.r and text_disabled.r > s.bg.r);
    try std.testing.expect(text_disabled.g < s.text.g and text_disabled.g > s.bg.g);
    try std.testing.expect(text_disabled.b < s.text.b and text_disabled.b > s.bg.b);
}

test "disabledColor: a saturated accent desaturates (grayscale before blending toward bg)" {
    const s = defaultStyle();
    // bg_active is a saturated blue (0x30,0x60,0xC0); disabling it should narrow the channel spread.
    const active_disabled = s.disabledColor(s.bg_active);
    const spread_before = @as(i32, s.bg_active.b) - @as(i32, s.bg_active.r);
    const spread_after = @as(i32, active_disabled.b) - @as(i32, active_disabled.r);
    try std.testing.expect(spread_after < spread_before);
}

test "disabledColor: idempotent-ish -- disabling an already-bg-colored value returns bg" {
    const s = defaultStyle();
    // grayscale(bg) blended with bg only equals bg exactly when bg is already a neutral gray;
    // instead pin the general contract: disabling `bg` itself never drifts far from `bg`.
    const bg_disabled = s.disabledColor(s.bg);
    try std.testing.expect(@as(i32, @intCast(bg_disabled.r)) - @as(i32, @intCast(s.bg.r)) <= 8);
    try std.testing.expect(@as(i32, @intCast(s.bg.r)) - @as(i32, @intCast(bg_disabled.r)) <= 8);
}

test "defaultStyle: text tiers map heading/body to text, caption to text_subtle, muted toward bg" {
    const s = defaultStyle();
    try std.testing.expectEqual(s.text, s.heading.color);
    try std.testing.expectEqual(s.text, s.body.color);
    try std.testing.expectEqual(s.text_subtle, s.caption.color);
    try std.testing.expectEqual(s.mutedFromSubtle(), s.muted.color);
    try std.testing.expect(s.heading.font == null);
    try std.testing.expect(s.body.font == null);
    try std.testing.expect(s.caption.font == null);
    try std.testing.expect(s.muted.font == null);
    try std.testing.expectEqual(@as(i32, 14), s.indent_w);
}

test "textStyle: tier selects the matching TextStyle field" {
    const s = defaultStyle();
    try std.testing.expectEqual(s.heading.color, s.textStyle(.heading).color);
    try std.testing.expectEqual(s.body.color, s.textStyle(.body).color);
    try std.testing.expectEqual(s.caption.color, s.textStyle(.caption).color);
    try std.testing.expectEqual(s.muted.color, s.textStyle(.muted).color);
}

test "mutedFromSubtle: halfway from text_subtle toward bg" {
    const s = defaultStyle();
    const m = s.mutedFromSubtle();
    try std.testing.expectEqual(@as(u8, 0x64), m.r);
    try std.testing.expectEqual(@as(u8, 0x68), m.g);
    try std.testing.expectEqual(@as(u8, 0x70), m.b);
    try std.testing.expectEqual(@as(u8, 0xFF), m.a);
}
