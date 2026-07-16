// widget 共通スタイル（TASK-21.5）。
//
// push/pop は非対応（MVP 契約）。テーマを変えたい caller は Context.style を
// 直接書き換える。サイズ系は i32（layout / Rect と同じ整数系）、描画時に u32 へ cast。

const color_mod = @import("color.zig");

pub const Color = color_mod.Color;

pub const Style = struct {
    /// button 等の通常時の塗り
    bg: Color,
    /// hover（state.hot_id == id）時の塗り
    bg_hover: Color,
    /// 押下（held）時の塗り
    bg_active: Color,
    /// 通常時の枠色
    border: Color,
    /// hover 時の枠色。selected 表示の強調枠色にも使う
    border_hover: Color,
    /// label / button 文字色
    text: Color,
    /// 補助テキスト色（status bar 等の caller 用途）
    text_subtle: Color,
    /// SelectableLabel の選択範囲の背景色
    selection_background: Color = Color.rgba(0x30, 0x60, 0xC0, 0xFF),
    /// 将来の caret 描画で使う色（113.1 では caret 自体を描画しない）
    caret: Color = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
    swatch_size: i32 = 18,
    swatch_border: i32 = 1,
    swatch_border_selected: i32 = 2,
    /// top, right, bottom, left
    button_padding: [4]i32 = .{ 4, 8, 4, 8 },
    button_border: i32 = 1,
    button_border_selected: i32 = 2,
    // Slider（TASK-21.9）。サイズ系は i32、描画時に u32 へ cast。
    slider_track_w: i32 = 120,
    slider_track_h: i32 = 6,
    slider_knob_w: i32 = 10,
    slider_knob_h: i32 = 16,
    slider_track_bg: Color = Color.rgba(0x30, 0x30, 0x38, 0xFF),
    slider_knob_bg: Color = Color.rgba(0x90, 0x98, 0xA0, 0xFF),
    slider_knob_active_bg: Color = Color.rgba(0x30, 0x60, 0xC0, 0xFF),
    // HSV カラーピッカー（TASK-21.14）。SV スクエア / Hue バーは固定 px（dl.image の制約）。
    picker_sv_size: i32 = 128,
    picker_hue_w: i32 = 16,
    picker_marker_light: Color = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
    picker_marker_dark: Color = Color.rgba(0x00, 0x00, 0x00, 0xFF),
    // Checkbox / Toggle(switch) / Radio（TASK-48）。寸法のみ。色は既存を再利用する:
    // ON/accent = bg_active、box 内部 / track = slider_track_bg、knob = slider_knob_bg、枠 = border / border_hover。
    checkbox_size: i32 = 16,
    /// glyph ↔ label のギャップ（checkbox / toggle / radio 共通）
    checkbox_gap: i32 = 6,
    switch_w: i32 = 28,
    switch_h: i32 = 16,
    radio_size: i32 = 16,
    // ポップアップ/コンテキストメニュー（TASK-79.1）。色は既存 bg/bg_hover/border/text/
    // text_subtle を再利用する（新規色フィールドは追加しない）。
    popup_item_h: i32 = 20,
    popup_padding: i32 = 4,
};

/// 既存 example（09/10）系統のダークテーマ。text は白（21.4 までの label 既定色と同じ）。
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

test "defaultStyle: text は白（21.4 までの label 既定色と互換）" {
    const s = defaultStyle();
    try std.testing.expectEqual(Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), s.text);
    try std.testing.expect(s.swatch_border_selected > s.swatch_border);
    try std.testing.expect(s.button_border_selected > s.button_border);
}
