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
