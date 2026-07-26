// Shared widget style.
//
// No push/pop (MVP contract). Callers that want a theme rewrite `Context.style`
// directly. Sizes are i32 (same integer system as layout / Rect); cast to u32 at draw time.

const color_mod = @import("color.zig");

pub const Color = color_mod.Color;

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
};

/// Dark theme in the example 09/10 family. text is white (same as earlier label default).
pub fn defaultStyle() Style {
    return .{
        .bg = Color.rgba(0x38, 0x38, 0x40, 0xFF),
        .bg_hover = Color.rgba(0x50, 0x50, 0x60, 0xFF),
        .bg_active = Color.rgba(0x30, 0x60, 0xC0, 0xFF),
        .border = Color.rgba(0x60, 0x60, 0x6C, 0xFF),
        .border_hover = Color.rgba(0xA0, 0xA0, 0xB0, 0xFF),
        .text = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
        .text_subtle = Color.rgba(0x90, 0x98, 0xA0, 0xFF),
    };
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
