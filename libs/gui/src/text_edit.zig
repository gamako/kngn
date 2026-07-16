//! 単一行テキストのレイアウト、hit-test、選択状態。
//!
//! ホットパス宣言:
//! - hitTest と layout 構築の codepoint 走査は widget 呼び出し時の O(codepoint)。
//! - SelectionState の更新と単語選択はイベント時のみ。
//! - このファイルは画素を直接描画せず、widgets.zig が rect/text DrawCmd を発行する。

const std = @import("std");
const Allocator = std.mem.Allocator;

const font_mod = @import("font.zig");
const id_mod = @import("id.zig");

pub const Font = font_mod.Font;
pub const Id = id_mod.Id;

pub const CopyRequest = struct {
    id: Id,
    text: []const u8,
};

pub const TextRange = struct {
    start: usize,
    end: usize,
};

/// byte_offsets は codepoint 数 + 1 個、prefix_widths も同じ長さを持つ。
/// text は wordRange が ASCII / 非 ASCII の規則を判定するための借用 slice である。
/// byte_offsets と prefix_widths の所有権は buildTextLayout に渡した allocator にある。
pub const TextLayout = struct {
    byte_offsets: []const usize,
    prefix_widths: []const u32,
    text: []const u8,

    pub fn count(self: TextLayout) usize {
        std.debug.assert(self.byte_offsets.len == self.prefix_widths.len);
        return self.byte_offsets.len -| 1;
    }
};

/// UTF-8 の codepoint 境界と各 codepoint の logical advance を構築する。
/// 正常な UTF-8 は codepoint 単位、不正な UTF-8 は不正位置の 1 byte 単位で進む。
pub fn buildTextLayout(a: Allocator, font: Font, text: []const u8) !TextLayout {
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < text.len) {
        pos += codepointByteLength(text, pos);
        count += 1;
    }

    const byte_offsets = try a.alloc(usize, count + 1);
    errdefer a.free(byte_offsets);
    const prefix_widths = try a.alloc(u32, count + 1);
    errdefer a.free(prefix_widths);

    byte_offsets[0] = 0;
    prefix_widths[0] = 0;
    pos = 0;
    var i: usize = 0;
    var width: u32 = 0;
    while (pos < text.len) : (i += 1) {
        const n = codepointByteLength(text, pos);
        const end = pos + n;
        width += font.measure(text[pos..end]);
        pos = end;
        byte_offsets[i + 1] = pos;
        prefix_widths[i + 1] = width;
    }

    return .{
        .byte_offsets = byte_offsets,
        .prefix_widths = prefix_widths,
        .text = text,
    };
}

/// glyph advance の中点で境界を選ぶ。範囲外は [0, codepoint 数] に clamp する。
pub fn hitTest(layout: TextLayout, local_x: i32) usize {
    const count = layout.count();
    if (count == 0 or local_x <= 0) return 0;
    const x: u32 = @intCast(local_x);
    for (0..count) |i| {
        const left = layout.prefix_widths[i];
        const right = layout.prefix_widths[i + 1];
        const midpoint = left + (right - left + 1) / 2;
        if (x < midpoint) return i;
    }
    return count;
}

/// codepoint index から元テキストの UTF-8 byte offset へ変換する。
pub fn byteIndex(text: []const u8, index: usize) usize {
    var pos: usize = 0;
    var i: usize = 0;
    while (pos < text.len and i < index) : (i += 1) {
        pos += codepointByteLength(text, pos);
    }
    return pos;
}

/// ASCII 英数字/_ の連続、または ASCII 区切りに挟まれた非 ASCII 連続列を返す。
/// 空白・句読点自身を押した場合は、その codepoint だけを選択する。
pub fn wordRange(layout: TextLayout, index: usize) TextRange {
    const count = layout.count();
    if (count == 0 or index >= count) return .{ .start = index, .end = index };

    const cp = codepointAt(layout, index);
    if (isAsciiWord(cp)) {
        var start = index;
        while (start > 0 and isAsciiWord(codepointAt(layout, start - 1))) : (start -= 1) {}
        var end = index + 1;
        while (end < count and isAsciiWord(codepointAt(layout, end))) : (end += 1) {}
        return .{ .start = start, .end = end };
    }

    if (cp > 0x7F) {
        var start = index;
        while (start > 0 and codepointAt(layout, start - 1) > 0x7F) : (start -= 1) {}
        var end = index + 1;
        while (end < count and codepointAt(layout, end) > 0x7F) : (end += 1) {}
        return .{ .start = start, .end = end };
    }

    return .{ .start = index, .end = index + 1 };
}

pub const SelectionState = struct {
    anchor: usize = 0,
    extent: usize = 0,
    dragging: bool = false,

    pub fn beginDrag(self: *SelectionState, index: usize, extend: bool) void {
        if (!extend) self.anchor = index;
        self.extent = index;
        self.dragging = true;
    }

    pub fn updateDrag(self: *SelectionState, index: usize) void {
        self.extent = index;
    }

    pub fn selectWord(self: *SelectionState, range: TextRange) void {
        self.anchor = range.start;
        self.extent = range.end;
        self.dragging = false;
    }

    pub fn normalized(self: SelectionState) TextRange {
        return if (self.anchor <= self.extent)
            .{ .start = self.anchor, .end = self.extent }
        else
            .{ .start = self.extent, .end = self.anchor };
    }
};

fn codepointByteLength(text: []const u8, pos: usize) usize {
    const first = text[pos];
    const n = std.unicode.utf8ByteSequenceLength(first) catch return 1;
    if (n == 1 or pos + n > text.len) return 1;
    _ = std.unicode.utf8Decode(text[pos .. pos + n]) catch return 1;
    return n;
}

fn codepointAt(layout: TextLayout, index: usize) u32 {
    const start = layout.byte_offsets[index];
    const end = layout.byte_offsets[index + 1];
    if (end - start == 1) return layout.text[start];
    return std.unicode.utf8Decode(layout.text[start..end]) catch layout.text[start];
}

fn isAsciiWord(cp: u32) bool {
    return switch (cp) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => true,
        else => false,
    };
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "TextLayout: ASCII / 可変幅 / 日本語混在の prefix と byte 境界" {
    const TestFont = struct {
        const value: Font = .{ .ptr = undefined, .vtable = &.{
            .measure = measure,
            .drawTo = undefined,
            .metrics = undefined,
        } };
        fn measure(_: *const anyopaque, text: []const u8) u32 {
            return switch (text.len) {
                1 => 2,
                3 => 7,
                else => 0,
            };
        }
    };

    const text = "AあB";
    const layout = try buildTextLayout(testing.allocator, TestFont.value, text);
    defer testing.allocator.free(layout.byte_offsets);
    defer testing.allocator.free(layout.prefix_widths);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 4, 5 }, layout.byte_offsets);
    try testing.expectEqualSlices(u32, &.{ 0, 2, 9, 11 }, layout.prefix_widths);
    try testing.expectEqual(@as(usize, 0), hitTest(layout, 0));
    try testing.expectEqual(@as(usize, 1), hitTest(layout, 2));
    try testing.expectEqual(@as(usize, 2), hitTest(layout, 9));
    try testing.expectEqual(@as(usize, 3), hitTest(layout, 100));
    try testing.expectEqual(@as(usize, 5), byteIndex(text, 3));
}

test "TextLayout: 不正 UTF-8 は byte 単位で境界を保つ" {
    const layout = try buildTextLayout(testing.allocator, font_mod.default_font, &.{ 0xFF, 'a', 0xC3, 0x28 });
    defer testing.allocator.free(layout.byte_offsets);
    defer testing.allocator.free(layout.prefix_widths);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4 }, layout.byte_offsets);
    try testing.expectEqual(@as(usize, 4), layout.count());
    try testing.expectEqual(@as(usize, 4), byteIndex(layout.text, 4));
}

test "SelectionState: 左右ドラッグ、Shift+click、空選択" {
    var selection: SelectionState = .{};
    selection.beginDrag(4, false);
    selection.updateDrag(1);
    try testing.expectEqual(TextRange{ .start = 1, .end = 4 }, selection.normalized());
    selection.beginDrag(2, true);
    try testing.expectEqual(TextRange{ .start = 2, .end = 4 }, selection.normalized());
    selection.beginDrag(2, false);
    try testing.expectEqual(TextRange{ .start = 2, .end = 2 }, selection.normalized());
}

test "wordRange: ASCII word / 空白・句読点 / 日本語連続列" {
    const text = "hello, 日本語 world";
    const layout = try buildTextLayout(testing.allocator, font_mod.default_font, text);
    defer testing.allocator.free(layout.byte_offsets);
    defer testing.allocator.free(layout.prefix_widths);

    try testing.expectEqual(TextRange{ .start = 0, .end = 5 }, wordRange(layout, 1));
    try testing.expectEqual(TextRange{ .start = 5, .end = 6 }, wordRange(layout, 5));
    try testing.expectEqual(TextRange{ .start = 7, .end = 10 }, wordRange(layout, 8));
    try testing.expectEqual(TextRange{ .start = 11, .end = 16 }, wordRange(layout, 11));
}
