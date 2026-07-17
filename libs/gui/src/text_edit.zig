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

    /// 選択範囲を保った caret 移動。非 Shift 移動では既存選択を先に collapse する。
    pub fn moveCaret(self: *SelectionState, count: usize, key: MoveKey, shift: bool) void {
        const range = self.normalized();
        const target = switch (key) {
            .left => if (!shift and range.start != range.end)
                range.start
            else
                self.extent -| 1,
            .right => if (!shift and range.start != range.end)
                range.end
            else
                @min(count, self.extent + 1),
            .home => 0,
            .end => count,
        };
        self.setExtent(target, shift);
    }

    /// wordRange と同じ分類で単語境界へ移動する（イベント時のみ）。
    /// 区切り（ASCII 非 word）は連続して越え、非 Shift では既存選択を collapse する。
    pub fn moveWord(self: *SelectionState, layout: TextLayout, direction: WordDirection, shift: bool) void {
        const range = self.normalized();
        const target = blk: {
            if (!shift and range.start != range.end) {
                break :blk if (direction == .left) range.start else range.end;
            }
            break :blk switch (direction) {
                .left => wordBoundaryLeft(layout, self.extent),
                .right => wordBoundaryRight(layout, self.extent),
            };
        };
        self.setExtent(target, shift);
    }

    fn setExtent(self: *SelectionState, target: usize, shift: bool) void {
        if (shift) {
            self.extent = target;
        } else {
            self.anchor = target;
            self.extent = target;
        }
        self.dragging = false;
    }
};

pub const MoveKey = enum { left, right, home, end };
pub const WordDirection = enum { left, right };

/// Option+← 相当: 直前の単語先頭（区切り列はまとめて越える）。
fn wordBoundaryLeft(layout: TextLayout, index: usize) usize {
    if (index == 0) return 0;
    var i = index - 1;
    // 区切り上にいるなら区切り列を左へ越える。
    while (i > 0 and isWordSeparator(codepointAt(layout, i))) : (i -= 1) {}
    // 単語文字の連続の先頭まで戻る。
    while (i > 0 and isWordChar(codepointAt(layout, i - 1))) : (i -= 1) {}
    return i;
}

/// Option+→ 相当: 次の単語末尾（途中なら現在語の末尾。区切り列はまとめて越える）。
fn wordBoundaryRight(layout: TextLayout, index: usize) usize {
    const count = layout.count();
    if (index >= count) return count;
    var i = index;
    // 区切り上にいるなら先に区切りを越えて次語へ。
    while (i < count and isWordSeparator(codepointAt(layout, i))) : (i += 1) {}
    // 単語文字の連続の末尾まで進む。
    while (i < count and isWordChar(codepointAt(layout, i))) : (i += 1) {}
    return i;
}

fn isWordChar(cp: u32) bool {
    return isAsciiWord(cp) or cp > 0x7F;
}

fn isWordSeparator(cp: u32) bool {
    return !isWordChar(cp);
}

/// caller が所有する単一行 UTF-8 buffer。caret/selection は codepoint index を使い、
/// 実体の ArrayList は UTF-8 byte 列を保持する。
pub const TextBuffer = struct {
    bytes: std.ArrayList(u8),
    alloc: Allocator,

    pub fn init(a: Allocator, initial: []const u8) !TextBuffer {
        var self: TextBuffer = .{ .bytes = .empty, .alloc = a };
        errdefer self.deinit();
        try self.bytes.appendSlice(a, initial);
        return self;
    }

    pub fn deinit(self: *TextBuffer) void {
        self.bytes.deinit(self.alloc);
    }

    pub fn slice(self: *const TextBuffer) []const u8 {
        return self.bytes.items;
    }

    /// codepoint を index の位置へ挿入し、新しい caret index を返す。
    pub fn insertCodepoint(self: *TextBuffer, index: usize, cp: u32) !usize {
        if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return error.InvalidCodepoint;
        var encoded: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(@intCast(cp), &encoded);
        const count = codepointCount(self.slice());
        const clamped = @min(index, count);
        try self.bytes.insertSlice(self.alloc, byteIndex(self.slice(), clamped), encoded[0..n]);
        return clamped + 1;
    }

    pub fn deleteRange(self: *TextBuffer, range: TextRange) void {
        const count = codepointCount(self.slice());
        const raw_start = @min(range.start, count);
        const raw_end = @min(range.end, count);
        const start = @min(raw_start, raw_end);
        const end = @max(raw_start, raw_end);
        if (start == end) return;
        const byte_start = byteIndex(self.slice(), start);
        const byte_end = byteIndex(self.slice(), end);
        self.bytes.replaceRange(self.alloc, byte_start, byte_end - byte_start, &.{}) catch
            @panic("TextBuffer.deleteRange: OOM");
    }

    pub fn backspace(self: *TextBuffer, selection: *SelectionState) void {
        const range = selection.normalized();
        if (range.start != range.end) {
            self.deleteRange(range);
            selection.anchor = range.start;
            selection.extent = range.start;
            return;
        }
        if (selection.extent == 0) return;
        const caret = selection.extent;
        self.deleteRange(.{ .start = caret - 1, .end = caret });
        selection.anchor = caret - 1;
        selection.extent = caret - 1;
    }

    pub fn deleteForward(self: *TextBuffer, selection: *SelectionState) void {
        const range = selection.normalized();
        if (range.start != range.end) {
            self.deleteRange(range);
            selection.anchor = range.start;
            selection.extent = range.start;
            return;
        }
        const count = codepointCount(self.slice());
        if (selection.extent >= count) return;
        self.deleteRange(.{ .start = selection.extent, .end = selection.extent + 1 });
    }
};

fn codepointCount(text: []const u8) usize {
    var pos: usize = 0;
    var count: usize = 0;
    while (pos < text.len) : (count += 1) pos += codepointByteLength(text, pos);
    return count;
}

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

test "TextBuffer: ASCII / 日本語 insert と前後削除" {
    var buffer = try TextBuffer.init(testing.allocator, "Ab");
    defer buffer.deinit();

    try testing.expectEqual(@as(usize, 3), try buffer.insertCodepoint(2, 'あ'));
    try testing.expectEqualStrings("Abあ", buffer.slice());
    var selection: SelectionState = .{ .anchor = 3, .extent = 3 };
    buffer.backspace(&selection);
    try testing.expectEqualStrings("Ab", buffer.slice());
    try testing.expectEqual(@as(usize, 2), selection.extent);
    buffer.deleteForward(&selection);
    try testing.expectEqualStrings("Ab", buffer.slice());
    selection.extent = 1;
    buffer.deleteForward(&selection);
    try testing.expectEqualStrings("A", buffer.slice());
}

test "TextBuffer: selection replacement と容量拡張" {
    var buffer = try TextBuffer.init(testing.allocator, "0123456789");
    defer buffer.deinit();

    var selection: SelectionState = .{ .anchor = 2, .extent = 8 };
    const range = selection.normalized();
    buffer.deleteRange(range);
    selection.anchor = range.start;
    selection.extent = range.start;
    _ = try buffer.insertCodepoint(selection.extent, 'あ');
    selection.anchor += 1;
    selection.extent += 1;
    try testing.expectEqualStrings("01あ89", buffer.slice());
    try testing.expectEqual(@as(usize, 3), selection.extent);
}

test "SelectionState: Left/Right/Home/End と Shift selection" {
    var selection: SelectionState = .{ .anchor = 2, .extent = 2 };
    selection.moveCaret(5, .left, false);
    try testing.expectEqual(TextRange{ .start = 1, .end = 1 }, selection.normalized());
    selection.moveCaret(5, .right, true);
    try testing.expectEqual(TextRange{ .start = 1, .end = 2 }, selection.normalized());
    selection.moveCaret(5, .end, true);
    try testing.expectEqual(TextRange{ .start = 1, .end = 5 }, selection.normalized());
    selection.moveCaret(5, .left, false);
    try testing.expectEqual(TextRange{ .start = 1, .end = 1 }, selection.normalized());
    selection.moveCaret(5, .home, false);
    try testing.expectEqual(TextRange{ .start = 0, .end = 0 }, selection.normalized());
}

test "TASK-119: SelectionState の word movement と Shift extension" {
    // "hi, 日本語 ok" = h i , sp 日 本 語 sp o k  (10 codepoints)
    const text = "hi, 日本語 ok";
    const layout = try buildTextLayout(testing.allocator, font_mod.default_font, text);
    defer testing.allocator.free(layout.byte_offsets);
    defer testing.allocator.free(layout.prefix_widths);
    const count = layout.count();
    try testing.expectEqual(@as(usize, 10), count);

    var selection: SelectionState = .{ .anchor = 0, .extent = 0 };
    // ASCII word 末尾へ
    selection.moveWord(layout, .right, false);
    try testing.expectEqual(TextRange{ .start = 2, .end = 2 }, selection.normalized());
    // 区切り ", " を越えて日本語列の末尾へ
    selection.moveWord(layout, .right, false);
    try testing.expectEqual(TextRange{ .start = 7, .end = 7 }, selection.normalized());
    // 空白を越えて "ok" 末尾へ
    selection.moveWord(layout, .right, false);
    try testing.expectEqual(TextRange{ .start = 10, .end = 10 }, selection.normalized());
    // 末尾で no-op
    selection.moveWord(layout, .right, false);
    try testing.expectEqual(TextRange{ .start = 10, .end = 10 }, selection.normalized());

    // 左: "ok" 先頭 → 日本語先頭 → "hi" 先頭 → 先頭 no-op
    selection.moveWord(layout, .left, false);
    try testing.expectEqual(TextRange{ .start = 8, .end = 8 }, selection.normalized());
    selection.moveWord(layout, .left, false);
    try testing.expectEqual(TextRange{ .start = 4, .end = 4 }, selection.normalized());
    selection.moveWord(layout, .left, false);
    try testing.expectEqual(TextRange{ .start = 0, .end = 0 }, selection.normalized());
    selection.moveWord(layout, .left, false);
    try testing.expectEqual(TextRange{ .start = 0, .end = 0 }, selection.normalized());

    // 非 Shift: 既存選択は端へ collapse（追加移動なし）
    selection = .{ .anchor = 0, .extent = 5 };
    selection.moveWord(layout, .right, false);
    try testing.expectEqual(TextRange{ .start = 5, .end = 5 }, selection.normalized());
    selection = .{ .anchor = 0, .extent = 5 };
    selection.moveWord(layout, .left, false);
    try testing.expectEqual(TextRange{ .start = 0, .end = 0 }, selection.normalized());

    // Shift+Option: 選択拡張（anchor 固定）
    selection = .{ .anchor = 2, .extent = 2 };
    selection.moveWord(layout, .right, true);
    try testing.expectEqual(TextRange{ .start = 2, .end = 7 }, selection.normalized());
    selection.moveWord(layout, .left, true);
    try testing.expectEqual(TextRange{ .start = 2, .end = 4 }, selection.normalized());
}
