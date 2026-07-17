//! 単一行テキストのレイアウト、hit-test、選択状態（TASK-132 契約明文化）。
//!
//! 本タスク時点の観測: default font では codepoint 単位の logical advance（通常 8px）で
//! measure / TextLayout / caret / selection / hit-test を行う。grapheme cluster・複数行・
//! glyph fallback は未実装。改行は TextBuffer 編集経路では挿入拒否、label 表示では
//! 1 codepoint 分の advance を持つが行送りはしない。
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

pub const CopyKind = enum { copy, cut };

pub const CopyRequest = struct {
    id: Id,
    text: []const u8,
    /// 既定は `.copy`（既存呼び出しの後方互換）。
    kind: CopyKind = .copy,
};

pub const TextRange = struct {
    start: usize,
    end: usize,
};

/// codepoint 境界と累積 logical width の対応表。
/// `byte_offsets[i]` / `prefix_widths[i]` は codepoint index `i` の先頭。
/// `count()` = codepoint 数。caret / selection / hitTest の index は byte offset ではなく
/// この codepoint index を使う（UTF-8 継続 byte 内には入らない）。
pub const TextLayout = struct {
    byte_offsets: []const usize,
    prefix_widths: []const u32,
    text: []const u8,

    pub fn count(self: TextLayout) usize {
        std.debug.assert(self.byte_offsets.len == self.prefix_widths.len);
        return self.byte_offsets.len -| 1;
    }
};

/// UTF-8 text の codepoint 境界と各 codepoint の logical advance（Font.measure）を構築する。
/// valid UTF-8 は codepoint 単位、不正 UTF-8 は不正位置の 1 byte 単位で進む（Font 契約と一致）。
/// default font では各 advance は通常 8px。戻り値の配列は allocator 上に確保される。
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

/// local_x（widget 左上原点）から codepoint index を返す。
/// 各 codepoint の logical advance（prefix_widths の差分）の中点を境界とする。
/// 戻り値は byte offset ではなく codepoint index（0..count）。範囲外は [0, count] に clamp。
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
/// selection の byte slice 抽出（copy 等）に使う。index は codepoint 単位。
pub fn byteIndex(text: []const u8, index: usize) usize {
    var pos: usize = 0;
    var i: usize = 0;
    while (pos < text.len and i < index) : (i += 1) {
        pos += codepointByteLength(text, pos);
    }
    return pos;
}

/// ダブルクリック用の単語範囲（codepoint index）。
/// ASCII 英数字/_ の連続、または ASCII 区切りに挟まれた非 ASCII（CJK/emoji 等）の連続列を
/// 1 word とする。grapheme cluster / 言語別分割規則は実装しない。
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

/// caller が所有する単一行 UTF-8 buffer。caret/selection は codepoint index、
/// 実体の ArrayList は UTF-8 byte 列を保持する。
/// 単一行契約: typed char / paste / selection replacement は ASCII 制御文字（0x00-0x1F, 0x7F）
/// と改行を挿入しない（isInsertableCodepoint / replaceSelectionWithTextLimited 参照）。
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

    /// 選択範囲を UTF-8 text で置換し、caret/selection を置換後末尾へ collapse する。
    /// 単一行契約: ASCII 制御文字（0x00-0x1F, 0x7F）と改行は除外。不正 UTF-8 はスキップ。
    /// 戻り値は buffer が変わったか。無制限（max_len=null）版。
    pub fn replaceSelectionWithText(self: *TextBuffer, selection: *SelectionState, text: []const u8) !bool {
        return replaceSelectionWithTextLimited(self, selection, text, null);
    }

    /// `max_len` 付き selection replacement。
    /// - `null`: 無制限（既存 `replaceSelectionWithText` と同等）
    /// - `0`: 挿入をすべて拒否（buffer/selection 不変）
    /// - `n`: 選択解除後の基底文字数を差し引いた残り容量まで codepoint を挿入し、超過分は末尾から捨てる
    /// 既存 buffer が既に max_len 超の場合も自動切り詰めはしない（編集結果にのみ適用）。
    pub fn replaceSelectionWithTextLimited(
        self: *TextBuffer,
        selection: *SelectionState,
        text: []const u8,
        max_len: ?usize,
    ) !bool {
        const range = selection.normalized();
        const count = codepointCount(self.slice());
        const sel_len = range.end - range.start;
        const base = count - sel_len;
        const remaining: ?usize = if (max_len) |limit|
            if (base >= limit) @as(usize, 0) else limit - base
        else
            null;

        // 残り 0 なら挿入不能 → buffer/selection を触らない（初期超過分の自動切り詰めもしない）
        if (remaining) |r| {
            if (r == 0) return false;
        }

        var changed = false;
        if (range.start != range.end) {
            self.deleteRange(range);
            selection.anchor = range.start;
            selection.extent = range.start;
            changed = true;
        }
        var inserted: usize = 0;
        var pos: usize = 0;
        while (pos < text.len) {
            const n = std.unicode.utf8ByteSequenceLength(text[pos]) catch {
                pos += 1;
                continue;
            };
            if (pos + n > text.len) break;
            const piece = text[pos .. pos + n];
            const cp: u32 = std.unicode.utf8Decode(piece) catch {
                pos += 1;
                continue;
            };
            pos += n;
            if (!isPasteInsertableCodepoint(cp)) continue;
            if (remaining) |r| {
                if (inserted >= r) break;
            }
            _ = try self.insertCodepoint(selection.extent, cp);
            selection.anchor += 1;
            selection.extent += 1;
            inserted += 1;
            changed = true;
        }
        return changed;
    }

    /// 選択範囲を 1 codepoint で置換（typed char / IME commit 経路）。
    /// `max_len` 到達時は buffer・caret・selection を変更せず false を返す。
    pub fn replaceSelectionWithCodepoint(
        self: *TextBuffer,
        selection: *SelectionState,
        cp: u32,
        max_len: ?usize,
    ) !bool {
        if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return error.InvalidCodepoint;
        const range = selection.normalized();
        const count = codepointCount(self.slice());
        const sel_len = range.end - range.start;
        const base = count - sel_len;
        if (max_len) |limit| {
            if (base >= limit) return false;
        }
        if (range.start != range.end) {
            self.deleteRange(range);
            selection.anchor = range.start;
            selection.extent = range.start;
        }
        _ = try self.insertCodepoint(selection.extent, cp);
        selection.anchor += 1;
        selection.extent += 1;
        return true;
    }
};

fn isPasteInsertableCodepoint(cp: u32) bool {
    return cp >= 0x20 and cp != 0x7F and cp <= 0x10FFFF and !(cp >= 0xD800 and cp <= 0xDFFF);
}

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

test "TASK-120: replaceSelectionWithText ASCII / 日本語 / 空選択 paste" {
    var buffer = try TextBuffer.init(testing.allocator, "abXYZcd");
    defer buffer.deinit();
    var selection: SelectionState = .{ .anchor = 2, .extent = 5 };
    try testing.expect(try buffer.replaceSelectionWithText(&selection, "あ"));
    try testing.expectEqualStrings("abあcd", buffer.slice());
    try testing.expectEqual(TextRange{ .start = 3, .end = 3 }, selection.normalized());

    selection = .{ .anchor = 3, .extent = 3 };
    try testing.expect(try buffer.replaceSelectionWithText(&selection, "!"));
    try testing.expectEqualStrings("abあ!cd", buffer.slice());
    try testing.expectEqual(@as(usize, 4), selection.extent);
}

test "TASK-120: replaceSelectionWithText は制御文字・改行を除外し不正 UTF-8 で壊れない" {
    var buffer = try TextBuffer.init(testing.allocator, "X");
    defer buffer.deinit();
    var selection: SelectionState = .{ .anchor = 1, .extent = 1 };
    try testing.expect(try buffer.replaceSelectionWithText(&selection, "A\nB\x00C"));
    try testing.expectEqualStrings("XABC", buffer.slice());

    selection = .{ .anchor = 4, .extent = 4 };
    // 不正先頭バイトはスキップ、後続 ASCII は入る
    _ = try buffer.replaceSelectionWithText(&selection, &.{ 0xFF, 'Z' });
    try testing.expectEqualStrings("XABCZ", buffer.slice());
    try testing.expect(std.unicode.utf8ValidateSlice(buffer.slice()));
}

test "TASK-120: cut 相当の deleteRange 後 selection collapse" {
    var buffer = try TextBuffer.init(testing.allocator, "hello");
    defer buffer.deinit();
    var selection: SelectionState = .{ .anchor = 1, .extent = 4 };
    const range = selection.normalized();
    buffer.deleteRange(range);
    selection.anchor = range.start;
    selection.extent = range.start;
    try testing.expectEqualStrings("ho", buffer.slice());
    try testing.expectEqual(TextRange{ .start = 1, .end = 1 }, selection.normalized());
}

test "TASK-128: ASCII max_len 直前・到達・超過" {
    var buffer = try TextBuffer.init(testing.allocator, "ab");
    defer buffer.deinit();
    var selection: SelectionState = .{ .anchor = 2, .extent = 2 };
    // 直前: max_len=3 で 1 文字挿入可
    try testing.expect(try buffer.replaceSelectionWithCodepoint(&selection, 'c', 3));
    try testing.expectEqualStrings("abc", buffer.slice());
    // 到達: これ以上は拒否
    try testing.expect(!try buffer.replaceSelectionWithCodepoint(&selection, 'd', 3));
    try testing.expectEqualStrings("abc", buffer.slice());
    try testing.expectEqual(@as(usize, 3), selection.extent);
    // 超過 paste は切り詰め
    try testing.expect(!try buffer.replaceSelectionWithTextLimited(&selection, "XYZ", 3));
    try testing.expectEqualStrings("abc", buffer.slice());
}

test "TASK-128: max_len=0 は挿入拒否" {
    var buffer = try TextBuffer.init(testing.allocator, "");
    defer buffer.deinit();
    var selection: SelectionState = .{};
    try testing.expect(!try buffer.replaceSelectionWithCodepoint(&selection, 'A', 0));
    try testing.expect(!try buffer.replaceSelectionWithTextLimited(&selection, "Hi", 0));
    try testing.expectEqualStrings("", buffer.slice());
}

test "TASK-128: max_len=null は無制限（既存同等）" {
    var buffer = try TextBuffer.init(testing.allocator, "");
    defer buffer.deinit();
    var selection: SelectionState = .{};
    try testing.expect(try buffer.replaceSelectionWithCodepoint(&selection, 'A', null));
    try testing.expect(try buffer.replaceSelectionWithTextLimited(&selection, "BC", null));
    try testing.expectEqualStrings("ABC", buffer.slice());
}

test "TASK-128: 日本語 UTF-8 3byte は 1 codepoint" {
    var buffer = try TextBuffer.init(testing.allocator, "");
    defer buffer.deinit();
    var selection: SelectionState = .{};
    try testing.expect(try buffer.replaceSelectionWithCodepoint(&selection, 'あ', 1));
    try testing.expectEqualStrings("あ", buffer.slice());
    try testing.expectEqual(@as(usize, 3), buffer.slice().len);
    try testing.expect(!try buffer.replaceSelectionWithCodepoint(&selection, 'い', 1));
    try testing.expectEqualStrings("あ", buffer.slice());
}

test "TASK-128: 絵文字 UTF-8 4byte は 1 codepoint" {
    var buffer = try TextBuffer.init(testing.allocator, "");
    defer buffer.deinit();
    var selection: SelectionState = .{};
    const grin: u32 = 0x1F600; // 😀
    try testing.expect(try buffer.replaceSelectionWithCodepoint(&selection, grin, 1));
    try testing.expectEqual(@as(usize, 4), buffer.slice().len);
    try testing.expect(!try buffer.replaceSelectionWithCodepoint(&selection, 'A', 1));
    try testing.expectEqual(@as(usize, 4), buffer.slice().len);
}

test "TASK-128: 選択範囲置換 paste は空いた容量を使う" {
    var buffer = try TextBuffer.init(testing.allocator, "abcdef");
    defer buffer.deinit();
    var selection: SelectionState = .{ .anchor = 1, .extent = 5 }; // "bcde"
    // base=2 ("a"+"f"), max_len=4 → 残り 2
    try testing.expect(try buffer.replaceSelectionWithTextLimited(&selection, "XYZ", 4));
    try testing.expectEqualStrings("aXYf", buffer.slice());
    try testing.expectEqual(@as(usize, 3), selection.extent);
}

test "TASK-128: 選択範囲置換 typed char" {
    var buffer = try TextBuffer.init(testing.allocator, "abcd");
    defer buffer.deinit();
    var selection: SelectionState = .{ .anchor = 1, .extent = 3 }; // "bc"
    try testing.expect(try buffer.replaceSelectionWithCodepoint(&selection, 'Z', 3));
    try testing.expectEqualStrings("aZd", buffer.slice());
}

test "TASK-128: paste 途中で max_len 到達時は切り詰め" {
    var buffer = try TextBuffer.init(testing.allocator, "ab");
    defer buffer.deinit();
    var selection: SelectionState = .{ .anchor = 2, .extent = 2 };
    try testing.expect(try buffer.replaceSelectionWithTextLimited(&selection, "CDEF", 4));
    try testing.expectEqualStrings("abCD", buffer.slice());
    try testing.expectEqual(@as(usize, 4), selection.extent);
}

test "TASK-128: 制御文字・改行・不正 UTF-8 と max_len" {
    var buffer = try TextBuffer.init(testing.allocator, "");
    defer buffer.deinit();
    var selection: SelectionState = .{};
    // 制御・改行は除外され、挿入可能 2 文字だけが入る（max_len=2）
    try testing.expect(try buffer.replaceSelectionWithTextLimited(&selection, "A\nB\x00C", 2));
    try testing.expectEqualStrings("AB", buffer.slice());
    // 不正 UTF-8 スキップ後の Z は上限で拒否
    try testing.expect(!try buffer.replaceSelectionWithTextLimited(&selection, &.{ 0xFF, 'Z' }, 2));
    try testing.expectEqualStrings("AB", buffer.slice());
    try testing.expect(std.unicode.utf8ValidateSlice(buffer.slice()));
}
