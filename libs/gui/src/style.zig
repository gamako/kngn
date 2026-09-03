// Shared widget style.
//
// No push/pop (MVP contract). Callers that want a theme rewrite `Context.style`
// directly. Sizes are i32 (same integer system as layout / Rect); cast to u32 at draw time.

const color_mod = @import("color.zig");
const font_mod = @import("font.zig");

pub const Color = color_mod.Color;
pub const Font = font_mod.Font;

/// Color, size, weight, and optional explicit font for one text tier. `font = null` lets Context
/// resolve the size/weight through its default family; an explicit font always wins and ignores
/// the tier size/weight.
pub const TextStyle = struct {
    color: Color,
    font: ?Font = null,
    size: f32 = 16,
    weight: u16 = 400,
};

/// Named text tier for `Context.labelStyled`. Seven role-oriented levels, chosen so that a
/// design written in an external vocabulary can be transcribed without inventing a mapping;
/// `docs/adr/035_text-tier-vocabulary.md` holds the mapping tables and why the count is seven. The declaration order
/// is largest to smallest and is what indexes `Style.text_styles`.
pub const TextTier = enum {
    /// Screen title, the topmost visual heading. 24px / 700.
    headline,
    /// Card or window title, a title inside a major section. 20px / 700.
    title,
    /// Section heading in a sidebar or inspector. 18px / 600.
    subtitle,
    /// Ordinary prose, descriptions, a list's values. 16px / 400.
    body,
    /// Column header, form field name, short UI label — a name the eye scans rather than
    /// reads. 14px / 600.
    label,
    /// A note or aside the reader is still meant to read. 13px / 400, subtle colour.
    caption,
    /// The lowest-priority hint or optional metadata: droppable without losing the point.
    /// 12px / 400.
    muted,
};

/// One `TextStyle` per `TextTier`, indexed by the enum's declaration order. Adding a tier to
/// the enum makes this array wider, which is what keeps the two from drifting apart.
pub const TextStyles = [@typeInfo(TextTier).@"enum".fields.len]TextStyle;

/// Index of `tier` into a `TextStyles`.
pub fn tierIndex(tier: TextTier) usize {
    return @intFromEnum(tier);
}

pub const AnimationStyle = struct {
    enabled: bool = false,
    hover_tau_s: f32 = 0.10,
    press_tau_s: f32 = 0.06,
};

pub const SpacingScale = struct {
    xs: i32 = 2,
    sm: i32 = 4,
    md: i32 = 6,
    lg: i32 = 8,
};

pub const SpacingTokens = struct {
    scale: SpacingScale = .{},
    /// Top, right, bottom, left.
    control_padding: [4]i32 = .{ 4, 8, 4, 8 },
    control_gap: i32 = 6,
    popup_inset: i32 = 4,
    popup_item_height: i32 = 24,
    dialog_panel_inset: i32 = 20,
    dialog_title_top: i32 = 16,
    dialog_body_top: i32 = 48,
    dialog_action_height: i32 = 32,
    dialog_action_gap: i32 = 8,
    dialog_action_label_inset: i32 = 8,
};

pub const SurfaceTokens = struct {
    canvas: Color,
    panel: Color,
    raised: Color,
    elevated: Color,
    control: Color,
    control_hover: Color,
    input: Color,
    control_subtle: Color,
    success: Color,
    info: Color,
    warning: Color,
    danger_subtle: Color,
    danger: Color,
    danger_strong: Color,
};

pub const AccentTokens = struct {
    primary: Color,
    selected: Color,
    selection: Color,
    danger: Color,
    focus: Color,
};

pub const BorderTokens = struct {
    normal: Color,
    hover: Color,
};

pub const TextTokens = struct {
    primary: Color,
    subtle: Color,
};

pub const ElevationTokens = struct {
    shadow: Color,
};

/// Partial color override for button-like widgets. A null field keeps the active theme token.
/// Disabled colors are always derived from the effective override, never stored separately.
pub const WidgetStyle = struct {
    background: ?Color = null,
    hover: ?Color = null,
    active: ?Color = null,
    selected: ?Color = null,
    border: ?Color = null,
    hover_border: ?Color = null,
    text: ?Color = null,
};

pub const Style = struct {
    /// Meaning-based colors. The legacy flat fields below mirror these values for source-level
    /// consumers that still draw directly with the public Style object.
    surface: SurfaceTokens,
    accent: AccentTokens,
    border_tokens: BorderTokens,
    text_tokens: TextTokens,
    elevation: ElevationTokens,
    /// Time-based button and tab color transitions. Disabled by default.
    animation: AnimationStyle = .{},
    spacing: SpacingTokens = .{},
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
    /// Radius shared by button-like chrome and focus rings.
    control_radius: u32 = 6,
    /// Radius used by the checkbox glyph's rounded rectangles.
    checkbox_radius: u32 = 4,
    swatch_size: i32 = 18,
    swatch_border: i32 = 1,
    swatch_border_selected: i32 = 2,
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
    switch_w: i32 = 28,
    switch_h: i32 = 16,
    radio_size: i32 = 16,
    /// One tree-indent step for `beginListboxRow` guides. `0` emits no guide
    /// (even when `depth > 0`). Must be `>= 0`.
    indent_w: i32 = 14,
    /// One entry per `TextTier`, in the enum's declaration order. Read it through
    /// `textStyle(tier)` rather than by index. The sizes and weights are the same in both
    /// themes; only the colours differ.
    text_styles: TextStyles = defaultTextStyles(
        Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
        Color.rgba(0x90, 0x98, 0xA0, 0xFF),
        Color.rgba(0x64, 0x68, 0x70, 0xFF),
    ),

    /// The color a disabled widget draws `base` as: grayscale (so an accent color loses its hue,
    /// not just its brightness), then blended halfway toward `bg` (so a disabled widget dims
    /// toward the surface it sits on rather than toward black, and follows a theme change the
    /// same way every other derived color here does — no separate `*_disabled` fields to keep
    /// in sync).
    pub fn disabledColor(self: Style, base: Color) Color {
        // ITU-R BT.601 luma weights (fixed-point, /256), same rounding shape as pixelops' div255.
        const y: u32 = (77 * @as(u32, base.r) + 150 * @as(u32, base.g) + 29 * @as(u32, base.b) + 128) / 256;
        return Color.rgba(
            @intCast((y + self.surface.control.r) / 2),
            @intCast((y + self.surface.control.g) / 2),
            @intCast((y + self.surface.control.b) / 2),
            0xFF,
        );
    }

    /// `text_tokens.subtle` blended halfway toward `surface.control`.
    pub fn mutedFromSubtle(self: Style) Color {
        return Color.rgba(
            @intCast((@as(u16, self.text_tokens.subtle.r) + self.surface.control.r) / 2),
            @intCast((@as(u16, self.text_tokens.subtle.g) + self.surface.control.g) / 2),
            @intCast((@as(u16, self.text_tokens.subtle.b) + self.surface.control.b) / 2),
            0xFF,
        );
    }

    pub fn textStyle(self: Style, tier: TextTier) TextStyle {
        return self.text_styles[tierIndex(tier)];
    }
};

/// The one place the size and weight of every tier is written. `primary` colours the tiers
/// that carry structure, `subtle` the caption, `muted` the lowest tier — the caller derives
/// `muted` from a built `Style` (see `styleForTokens`), so it is passed in rather than
/// computed here.
fn defaultTextStyles(primary: Color, subtle: Color, muted: Color) TextStyles {
    var out: TextStyles = undefined;
    out[tierIndex(.headline)] = .{ .color = primary, .size = 24, .weight = 700 };
    out[tierIndex(.title)] = .{ .color = primary, .size = 20, .weight = 700 };
    out[tierIndex(.subtitle)] = .{ .color = primary, .size = 18, .weight = 600 };
    out[tierIndex(.body)] = .{ .color = primary, .size = 16, .weight = 400 };
    out[tierIndex(.label)] = .{ .color = primary, .size = 14, .weight = 600 };
    out[tierIndex(.caption)] = .{ .color = subtle, .size = 13, .weight = 400 };
    out[tierIndex(.muted)] = .{ .color = muted, .size = 12, .weight = 400 };
    return out;
}

fn styleForTokens(
    surface: SurfaceTokens,
    accent: AccentTokens,
    border_tokens: BorderTokens,
    text_tokens: TextTokens,
    elevation: ElevationTokens,
) Style {
    var s: Style = .{
        .surface = surface,
        .accent = accent,
        .border_tokens = border_tokens,
        .text_tokens = text_tokens,
        .elevation = elevation,
        .bg = surface.control,
        .bg_hover = surface.control_hover,
        .bg_active = accent.primary,
        .border = border_tokens.normal,
        .border_hover = border_tokens.hover,
        .text = text_tokens.primary,
        .text_subtle = text_tokens.subtle,
        .input_background = surface.input,
        .selection_background = accent.selection,
        .caret = text_tokens.primary,
        .focus_ring = accent.focus,
        .button_bg_selected = accent.selected,
        .slider_track_bg = surface.control_subtle,
        .slider_knob_bg = text_tokens.subtle,
        .slider_knob_active_bg = accent.primary,
        .picker_marker_light = text_tokens.primary,
        .picker_marker_dark = Color.rgba(0x00, 0x00, 0x00, 0xFF),
        // `mutedFromSubtle` needs a built Style, so the muted colour is seeded with `subtle`
        // here and rewritten once `s` exists.
        .text_styles = defaultTextStyles(text_tokens.primary, text_tokens.subtle, text_tokens.subtle),
    };
    s.text_styles[tierIndex(.muted)].color = s.mutedFromSubtle();
    return s;
}

/// Canonical dark theme. Every legacy flat color is derived from the semantic values here.
pub fn defaultStyle() Style {
    return styleForTokens(
        .{
            .canvas = Color.rgba(0x18, 0x1C, 0x24, 0xFF),
            .panel = Color.rgba(0x20, 0x24, 0x2C, 0xFF),
            .raised = Color.rgba(0x28, 0x30, 0x3C, 0xFF),
            .elevated = Color.rgba(0x30, 0x38, 0x48, 0xFF),
            .control = Color.rgba(0x38, 0x38, 0x40, 0xFF),
            .control_hover = Color.rgba(0x50, 0x50, 0x60, 0xFF),
            .input = Color.rgba(0x24, 0x24, 0x2C, 0xFF),
            .control_subtle = Color.rgba(0x30, 0x30, 0x38, 0xFF),
            .success = Color.rgba(0x28, 0x40, 0x38, 0xFF),
            .info = Color.rgba(0x18, 0x28, 0x38, 0xFF),
            .warning = Color.rgba(0x38, 0x38, 0x30, 0xFF),
            .danger_subtle = Color.rgba(0x30, 0x24, 0x2C, 0xFF),
            .danger = Color.rgba(0x40, 0x30, 0x38, 0xFF),
            .danger_strong = Color.rgba(0x50, 0x20, 0x20, 0xFF),
        },
        .{
            .primary = Color.rgba(0x30, 0x60, 0xC0, 0xFF),
            .selected = Color.rgba(0x24, 0x48, 0x7A, 0xFF),
            .selection = Color.rgba(0x30, 0x60, 0xC0, 0xFF),
            .danger = Color.rgba(0xC0, 0x30, 0x30, 0xFF),
            .focus = Color.rgba(0x7A, 0xB8, 0xFF, 0xFF),
        },
        .{ .normal = Color.rgba(0x60, 0x60, 0x6C, 0xFF), .hover = Color.rgba(0xA0, 0xA0, 0xB0, 0xFF) },
        .{ .primary = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), .subtle = Color.rgba(0x90, 0x98, 0xA0, 0xFF) },
        .{ .shadow = Color.rgba(0x00, 0x00, 0x00, 0xB0) },
    );
}

/// Light theme with the same dimensions, text tiers, and animation defaults as dark.
pub fn lightStyle() Style {
    return styleForTokens(
        .{
            .canvas = Color.rgba(0xF5, 0xF7, 0xFA, 0xFF),
            .panel = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
            .raised = Color.rgba(0xEE, 0xF2, 0xF7, 0xFF),
            .elevated = Color.rgba(0xE2, 0xE8, 0xF0, 0xFF),
            .control = Color.rgba(0xE8, 0xED, 0xF3, 0xFF),
            .control_hover = Color.rgba(0xD7, 0xE0, 0xEB, 0xFF),
            .input = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
            .control_subtle = Color.rgba(0xC7, 0xD0, 0xDC, 0xFF),
            .success = Color.rgba(0xDC, 0xFC, 0xE7, 0xFF),
            .info = Color.rgba(0xDB, 0xEA, 0xFE, 0xFF),
            .warning = Color.rgba(0xFE, 0xF3, 0xC7, 0xFF),
            .danger_subtle = Color.rgba(0xFE, 0xE2, 0xE2, 0xFF),
            .danger = Color.rgba(0xC0, 0x39, 0x2B, 0xFF),
            .danger_strong = Color.rgba(0x99, 0x1B, 0x1B, 0xFF),
        },
        .{
            .primary = Color.rgba(0x25, 0x63, 0xEB, 0xFF),
            .selected = Color.rgba(0x1D, 0x4E, 0xD8, 0xFF),
            .selection = Color.rgba(0xBB, 0xD3, 0xFF, 0xFF),
            .danger = Color.rgba(0xC0, 0x39, 0x2B, 0xFF),
            .focus = Color.rgba(0x25, 0x63, 0xEB, 0xFF),
        },
        .{ .normal = Color.rgba(0xAA, 0xB6, 0xC6, 0xFF), .hover = Color.rgba(0x63, 0x73, 0x8A, 0xFF) },
        .{ .primary = Color.rgba(0x17, 0x20, 0x33, 0xFF), .subtle = Color.rgba(0x52, 0x61, 0x76, 0xFF) },
        .{ .shadow = Color.rgba(0x00, 0x00, 0x00, 0x38) },
    );
}

// ============================================================
// Tests
// ============================================================

const std = @import("std");

test "default styles expose the canonical spacing tokens" {
    const dark = defaultStyle();
    const light = lightStyle();

    try std.testing.expectEqual(@as(i32, 2), dark.spacing.scale.xs);
    try std.testing.expectEqual(@as(i32, 4), dark.spacing.scale.sm);
    try std.testing.expectEqual(@as(i32, 6), dark.spacing.scale.md);
    try std.testing.expectEqual(@as(i32, 8), dark.spacing.scale.lg);
    try std.testing.expectEqualSlices(i32, &.{ 4, 8, 4, 8 }, &dark.spacing.control_padding);
    try std.testing.expectEqual(@as(i32, 6), dark.spacing.control_gap);
    try std.testing.expectEqual(@as(i32, 4), dark.spacing.popup_inset);
    try std.testing.expectEqual(@as(i32, 24), dark.spacing.popup_item_height);
    try std.testing.expectEqual(@as(i32, 20), dark.spacing.dialog_panel_inset);
    try std.testing.expectEqual(@as(i32, 16), dark.spacing.dialog_title_top);
    try std.testing.expectEqual(@as(i32, 48), dark.spacing.dialog_body_top);
    try std.testing.expectEqual(@as(i32, 32), dark.spacing.dialog_action_height);
    try std.testing.expectEqual(@as(i32, 8), dark.spacing.dialog_action_gap);
    try std.testing.expectEqual(@as(i32, 8), dark.spacing.dialog_action_label_inset);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&dark.spacing), std.mem.asBytes(&light.spacing));
}

test "defaultStyle: text is white (compatible with earlier label default)" {
    const s = defaultStyle();
    try std.testing.expect(!s.animation.enabled);
    try std.testing.expectEqual(@as(f32, 0.10), s.animation.hover_tau_s);
    try std.testing.expectEqual(@as(f32, 0.06), s.animation.press_tau_s);
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

/// The tier table as prose, so the test below fails when a size or weight in `style.zig`
/// changes without this list changing with it. `docs/adr/035_text-tier-vocabulary.md` is where
/// the numbers come from.
const expected_tiers = [_]struct { tier: TextTier, size: f32, weight: u16 }{
    .{ .tier = .headline, .size = 24, .weight = 700 },
    .{ .tier = .title, .size = 20, .weight = 700 },
    .{ .tier = .subtitle, .size = 18, .weight = 600 },
    .{ .tier = .body, .size = 16, .weight = 400 },
    .{ .tier = .label, .size = 14, .weight = 600 },
    .{ .tier = .caption, .size = 13, .weight = 400 },
    .{ .tier = .muted, .size = 12, .weight = 400 },
};

test "TextTier: the enum and the expected table hold the same tiers" {
    // Adding a tier without extending the table (or the gallery) leaves it unmeasured.
    try std.testing.expectEqual(expected_tiers.len, @typeInfo(TextTier).@"enum".fields.len);
    inline for (@typeInfo(TextTier).@"enum".fields, 0..) |field, i| {
        try std.testing.expectEqual(i, tierIndex(@field(TextTier, field.name)));
        try std.testing.expectEqualStrings(field.name, @tagName(expected_tiers[i].tier));
    }
}

test "defaultStyle: every tier has the designed size and weight, in both themes" {
    inline for (.{ defaultStyle(), lightStyle() }) |s| {
        for (expected_tiers) |want| {
            const got = s.textStyle(want.tier);
            try std.testing.expectEqual(want.size, got.size);
            try std.testing.expectEqual(want.weight, got.weight);
            // A null font is what lets Context resolve the size/weight through the family.
            try std.testing.expect(got.font == null);
        }
    }
}

test "defaultStyle: tier colors follow the tokens, and sizes descend strictly" {
    const s = defaultStyle();
    // Structure-carrying tiers take the primary text colour; caption the subtle one; muted is
    // derived from subtle so it stays the weakest.
    for ([_]TextTier{ .headline, .title, .subtitle, .body, .label }) |tier| {
        try std.testing.expectEqual(s.text, s.textStyle(tier).color);
    }
    try std.testing.expectEqual(s.text_subtle, s.textStyle(.caption).color);
    try std.testing.expectEqual(s.mutedFromSubtle(), s.textStyle(.muted).color);
    // Declaration order is largest to smallest, and no two tiers share a size: a duplicate
    // would make two tiers indistinguishable and share one font variant.
    inline for (@typeInfo(TextTier).@"enum".fields, 0..) |_, i| {
        if (i == 0) continue;
        const prev = s.text_styles[i - 1];
        const cur = s.text_styles[i];
        try std.testing.expect(cur.size < prev.size);
    }
    try std.testing.expectEqual(@as(i32, 14), s.indent_w);
}

test "defaultStyle: muted is derived from subtle in both themes and in the field default" {
    // `styleForTokens` seeds muted with `subtle` and rewrites it once the Style exists, so the
    // two-step is worth asserting on the value it produces, per theme.
    inline for (.{ defaultStyle(), lightStyle() }) |s| {
        try std.testing.expectEqual(s.mutedFromSubtle(), s.textStyle(.muted).color);
        // Weaker than caption is the point of the tier; if the seed leaked through they match.
        try std.testing.expect(@as(u32, @bitCast(s.textStyle(.muted).color)) != @as(u32, @bitCast(s.textStyle(.caption).color)));
    }
    try std.testing.expectEqual(Color.rgba(0x64, 0x68, 0x70, 0xFF), defaultStyle().textStyle(.muted).color);
    // The `Style.text_styles` field default is a separate table from `styleForTokens`; a
    // caller building a Style by hand gets these.
    const bare: Style = .{
        .surface = defaultStyle().surface,
        .accent = defaultStyle().accent,
        .border_tokens = defaultStyle().border_tokens,
        .text_tokens = defaultStyle().text_tokens,
        .elevation = defaultStyle().elevation,
        .bg = defaultStyle().bg,
        .bg_hover = defaultStyle().bg_hover,
        .bg_active = defaultStyle().bg_active,
        .border = defaultStyle().border,
        .border_hover = defaultStyle().border_hover,
        .text = defaultStyle().text,
        .text_subtle = defaultStyle().text_subtle,
    };
    for (expected_tiers) |want| {
        try std.testing.expectEqual(want.size, bare.textStyle(want.tier).size);
        try std.testing.expectEqual(want.weight, bare.textStyle(want.tier).weight);
    }
    try std.testing.expectEqual(Color.rgba(0x64, 0x68, 0x70, 0xFF), bare.textStyle(.muted).color);
}

test "textStyle: tier selects the matching array element" {
    const s = defaultStyle();
    inline for (@typeInfo(TextTier).@"enum".fields, 0..) |field, i| {
        const tier = @field(TextTier, field.name);
        try std.testing.expectEqual(s.text_styles[i].color, s.textStyle(tier).color);
        try std.testing.expectEqual(s.text_styles[i].size, s.textStyle(tier).size);
    }
}

test "mutedFromSubtle: halfway from text_subtle toward bg" {
    const s = defaultStyle();
    const m = s.mutedFromSubtle();
    try std.testing.expectEqual(@as(u8, 0x64), m.r);
    try std.testing.expectEqual(@as(u8, 0x68), m.g);
    try std.testing.expectEqual(@as(u8, 0x70), m.b);
    try std.testing.expectEqual(@as(u8, 0xFF), m.a);
}

test "defaultStyle: widget radii use the compact control defaults" {
    const s = defaultStyle();
    try std.testing.expectEqual(@as(u32, 6), s.control_radius);
    try std.testing.expectEqual(@as(u32, 4), s.checkbox_radius);
}

test "defaultStyle: semantic dark tokens preserve every canonical surface color" {
    const s = defaultStyle();
    try std.testing.expectEqual(Color.rgba(0x18, 0x1C, 0x24, 0xFF), s.surface.canvas);
    try std.testing.expectEqual(Color.rgba(0x20, 0x24, 0x2C, 0xFF), s.surface.panel);
    try std.testing.expectEqual(Color.rgba(0x28, 0x30, 0x3C, 0xFF), s.surface.raised);
    try std.testing.expectEqual(Color.rgba(0x30, 0x38, 0x48, 0xFF), s.surface.elevated);
    try std.testing.expectEqual(Color.rgba(0x38, 0x38, 0x40, 0xFF), s.surface.control);
    try std.testing.expectEqual(Color.rgba(0x50, 0x50, 0x60, 0xFF), s.surface.control_hover);
    try std.testing.expectEqual(Color.rgba(0x24, 0x24, 0x2C, 0xFF), s.surface.input);
    try std.testing.expectEqual(Color.rgba(0x30, 0x30, 0x38, 0xFF), s.surface.control_subtle);
    try std.testing.expectEqual(Color.rgba(0x28, 0x40, 0x38, 0xFF), s.surface.success);
    try std.testing.expectEqual(Color.rgba(0x18, 0x28, 0x38, 0xFF), s.surface.info);
    try std.testing.expectEqual(Color.rgba(0x38, 0x38, 0x30, 0xFF), s.surface.warning);
    try std.testing.expectEqual(Color.rgba(0x30, 0x24, 0x2C, 0xFF), s.surface.danger_subtle);
    try std.testing.expectEqual(Color.rgba(0x40, 0x30, 0x38, 0xFF), s.surface.danger);
    try std.testing.expectEqual(Color.rgba(0x50, 0x20, 0x20, 0xFF), s.surface.danger_strong);
}

test "defaultStyle: semantic dark accent border text and elevation tokens are exact" {
    const s = defaultStyle();
    try std.testing.expectEqual(Color.rgba(0x30, 0x60, 0xC0, 0xFF), s.accent.primary);
    try std.testing.expectEqual(Color.rgba(0x24, 0x48, 0x7A, 0xFF), s.accent.selected);
    try std.testing.expectEqual(Color.rgba(0x30, 0x60, 0xC0, 0xFF), s.accent.selection);
    try std.testing.expectEqual(Color.rgba(0xC0, 0x30, 0x30, 0xFF), s.accent.danger);
    try std.testing.expectEqual(Color.rgba(0x7A, 0xB8, 0xFF, 0xFF), s.accent.focus);
    try std.testing.expectEqual(Color.rgba(0x60, 0x60, 0x6C, 0xFF), s.border_tokens.normal);
    try std.testing.expectEqual(Color.rgba(0xA0, 0xA0, 0xB0, 0xFF), s.border_tokens.hover);
    try std.testing.expectEqual(Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), s.text_tokens.primary);
    try std.testing.expectEqual(Color.rgba(0x90, 0x98, 0xA0, 0xFF), s.text_tokens.subtle);
    try std.testing.expectEqual(Color.rgba(0x00, 0x00, 0x00, 0xB0), s.elevation.shadow);
    try std.testing.expectEqual(Color.rgba(0x24, 0x24, 0x2C, 0xFF), s.input_background);
    try std.testing.expectEqual(Color.rgba(0x30, 0x60, 0xC0, 0xFF), s.selection_background);
    try std.testing.expectEqual(Color.rgba(0x30, 0x30, 0x38, 0xFF), s.slider_track_bg);
    try std.testing.expectEqual(Color.rgba(0x90, 0x98, 0xA0, 0xFF), s.slider_knob_bg);
    try std.testing.expectEqual(Color.rgba(0x30, 0x60, 0xC0, 0xFF), s.slider_knob_active_bg);
    try std.testing.expectEqual(Color.rgba(0x7A, 0xB8, 0xFF, 0xFF), s.focus_ring);
    try std.testing.expectEqual(Color.rgba(0x24, 0x48, 0x7A, 0xFF), s.button_bg_selected);
}

test "lightStyle: values and derived colors are theme-local" {
    const s = lightStyle();
    try std.testing.expectEqual(Color.rgba(0xF5, 0xF7, 0xFA, 0xFF), s.surface.canvas);
    try std.testing.expectEqual(Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), s.surface.panel);
    try std.testing.expectEqual(Color.rgba(0xEE, 0xF2, 0xF7, 0xFF), s.surface.raised);
    try std.testing.expectEqual(Color.rgba(0xE2, 0xE8, 0xF0, 0xFF), s.surface.elevated);
    try std.testing.expectEqual(Color.rgba(0xE8, 0xED, 0xF3, 0xFF), s.surface.control);
    try std.testing.expectEqual(Color.rgba(0xD7, 0xE0, 0xEB, 0xFF), s.surface.control_hover);
    try std.testing.expectEqual(Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), s.surface.input);
    try std.testing.expectEqual(Color.rgba(0xC7, 0xD0, 0xDC, 0xFF), s.surface.control_subtle);
    try std.testing.expectEqual(Color.rgba(0x25, 0x63, 0xEB, 0xFF), s.accent.primary);
    try std.testing.expectEqual(Color.rgba(0x1D, 0x4E, 0xD8, 0xFF), s.accent.selected);
    try std.testing.expectEqual(Color.rgba(0xBB, 0xD3, 0xFF, 0xFF), s.accent.selection);
    try std.testing.expectEqual(Color.rgba(0xAA, 0xB6, 0xC6, 0xFF), s.border_tokens.normal);
    try std.testing.expectEqual(Color.rgba(0x63, 0x73, 0x8A, 0xFF), s.border_tokens.hover);
    try std.testing.expectEqual(Color.rgba(0x17, 0x20, 0x33, 0xFF), s.text_tokens.primary);
    try std.testing.expectEqual(Color.rgba(0x52, 0x61, 0x76, 0xFF), s.text_tokens.subtle);
    try std.testing.expectEqual(Color.rgba(0x25, 0x63, 0xEB, 0xFF), s.accent.focus);
    try std.testing.expectEqual(Color.rgba(0xC0, 0x39, 0x2B, 0xFF), s.accent.danger);
    try std.testing.expectEqual(Color.rgba(0x00, 0x00, 0x00, 0x38), s.elevation.shadow);
    try std.testing.expectEqual(Color.rgba(0xEA, 0xEC, 0xEF, 0xFF), s.disabledColor(s.surface.control));
    try std.testing.expectEqual(Color.rgba(0x9D, 0xA7, 0xB4, 0xFF), s.mutedFromSubtle());
    try std.testing.expectEqual(s.text_tokens.primary, s.textStyle(.title).color);
    try std.testing.expectEqual(s.text_tokens.subtle, s.textStyle(.caption).color);
}

test "WidgetStyle: every override is optional" {
    const empty: WidgetStyle = .{};
    try std.testing.expect(empty.background == null);
    try std.testing.expect(empty.hover == null);
    try std.testing.expect(empty.active == null);
    try std.testing.expect(empty.selected == null);
    try std.testing.expect(empty.border == null);
    try std.testing.expect(empty.hover_border == null);
    try std.testing.expect(empty.text == null);
}
