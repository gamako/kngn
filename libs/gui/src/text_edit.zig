//! Single-line text layout, hit-test, and selection state.
//!
//! Under the default font, per-codepoint logical advance (usually 8px) drives
//! measure / TextLayout / caret / selection / hit-test. Grapheme clusters, multi-line layout, and
//! glyph fallback are not implemented. Newlines are rejected on the TextBuffer edit path; label display
//! still advances one codepoint but does not wrap to the next line.
//!
//! Hot-path note:
//! - hitTest and layout-build codepoint walks are O(codepoint) at widget-call time.
//! - SelectionState updates and word selection run on events only.
//! - This file does not paint pixels; widgets.zig emits the rect/text DrawCmds.

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
    /// Default is `.copy` (backward compatible with existing call sites).
    kind: CopyKind = .copy,
};

pub const TextRange = struct {
    start: usize,
    end: usize,
};

/// Mapping between codepoint boundaries and cumulative logical width.
/// `byte_offsets[i]` / `prefix_widths[i]` are the start of codepoint index `i`.
/// `count()` = codepoint count. caret / selection / hitTest indices are codepoint indices, not byte offsets
/// (they never land inside a UTF-8 continuation byte).
pub const TextLayout = struct {
    byte_offsets: []const usize,
    prefix_widths: []const u32,
    text: []const u8,

    pub fn count(self: TextLayout) usize {
        std.debug.assert(self.byte_offsets.len == self.prefix_widths.len);
        return self.byte_offsets.len -| 1;
    }
};

/// Build codepoint boundaries of a UTF-8 text and each codepoint's logical advance (Font.measure).
/// Valid UTF-8 advances per codepoint; invalid UTF-8 advances one byte at the bad position (matches the Font contract).
/// With the default font each advance is usually 8px. Returned arrays are allocator-owned.
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

/// Return a codepoint index from local_x (origin at the widget top-left).
/// Boundaries are midpoints of each codepoint's logical advance (prefix_widths deltas).
/// Return value is a codepoint index (0..count), not a byte offset. Out of range clamps to [0, count].
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

/// Convert a codepoint index to a UTF-8 byte offset in the source text.
/// Used to extract selection byte slices (copy etc.). index is in codepoints.
pub fn byteIndex(text: []const u8, index: usize) usize {
    var pos: usize = 0;
    var i: usize = 0;
    while (pos < text.len and i < index) : (i += 1) {
        pos += codepointByteLength(text, pos);
    }
    return pos;
}

/// Word range for double-click (codepoint indices).
/// A run of ASCII alphanumerics/_ , or a run of non-ASCII (CJK/emoji etc.) bounded by ASCII separators,
/// counts as one word. No grapheme-cluster or language-specific segmentation.
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

    /// Caret move that preserves the selection. Non-Shift moves collapse any existing selection first.
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

    /// Move to word boundaries with the same classification as wordRange (events only).
    /// ASCII non-word separators are crossed as a run; non-Shift collapses any existing selection.
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

/// Option+Left equivalent: start of the previous word (cross separator runs together).
fn wordBoundaryLeft(layout: TextLayout, index: usize) usize {
    if (index == 0) return 0;
    var i = index - 1;
    // If on a separator, cross the separator run leftward.
    while (i > 0 and isWordSeparator(codepointAt(layout, i))) : (i -= 1) {}
    // Step back to the start of the current word-character run.
    while (i > 0 and isWordChar(codepointAt(layout, i - 1))) : (i -= 1) {}
    return i;
}

/// Option+Right equivalent: end of the next word (or end of the current word if mid-word; cross separator runs together).
fn wordBoundaryRight(layout: TextLayout, index: usize) usize {
    const count = layout.count();
    if (index >= count) return count;
    var i = index;
    // If on a separator, cross separators first to reach the next word.
    while (i < count and isWordSeparator(codepointAt(layout, i))) : (i += 1) {}
    // Advance to the end of the word-character run.
    while (i < count and isWordChar(codepointAt(layout, i))) : (i += 1) {}
    return i;
}

fn isWordChar(cp: u32) bool {
    return isAsciiWord(cp) or cp > 0x7F;
}

fn isWordSeparator(cp: u32) bool {
    return !isWordChar(cp);
}

/// Caller-owned single-line UTF-8 buffer. caret/selection are codepoint indices;
/// the underlying ArrayList holds the UTF-8 byte sequence.
/// Single-line contract: typed char / paste / selection replacement never insert ASCII controls (0x00-0x1F, 0x7F)
/// or newlines (see isInsertableCodepoint / replaceSelectionWithTextLimited).
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

    /// Insert a codepoint at index and return the new caret index.
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

    /// Replace the selection with UTF-8 text and collapse caret/selection to the end of the replacement.
    /// Single-line contract: ASCII controls (0x00-0x1F, 0x7F) and newlines are excluded. Invalid UTF-8 is skipped.
    /// Return value is whether the buffer changed. Unlimited (max_len=null) variant.
    pub fn replaceSelectionWithText(self: *TextBuffer, selection: *SelectionState, text: []const u8) !bool {
        return replaceSelectionWithTextLimited(self, selection, text, null);
    }

    /// Selection replacement with `max_len`.
    /// - `null`: unlimited (same as existing `replaceSelectionWithText`)
    /// - `0`: reject all insertion (buffer/selection unchanged)
    /// - `n`: insert codepoints up to remaining capacity after clearing the selection; excess is dropped from the end
    /// An existing buffer already over max_len is not auto-truncated (the limit applies only to edit results).
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

        // Remaining 0 → cannot insert; leave buffer/selection untouched (also no auto-truncate of a prior overshoot)
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

    /// Replace the selection with one codepoint (typed char / IME commit path).
    /// When `max_len` is already reached, leave buffer/caret/selection unchanged and return false.
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

    // ----------------------------------------------------------
    // UTF-16 document adapter (IME reconversion)
    // ----------------------------------------------------------

    /// UTF-16 code-unit count of the whole document.
    pub fn utf16Length(self: *const TextBuffer) u64 {
        return utf16LengthOf(self.slice());
    }

    /// codepoint index → UTF-16 code-unit offset.
    pub fn codepointIndexToUtf16(self: *const TextBuffer, index: usize) u64 {
        return codepointIndexToUtf16Offset(self.slice(), index);
    }

    /// Current selection as a UTF-16 range.
    pub fn selectedRangeUtf16(self: *const TextBuffer, selection: SelectionState) Utf16Range {
        const range = selection.normalized();
        const start = codepointIndexToUtf16Offset(self.slice(), range.start);
        const end = codepointIndexToUtf16Offset(self.slice(), range.end);
        return .{ .location = start, .length = end - start };
    }

    /// Clamp a proposed UTF-16 range to the document and return the scalar-aligned actual range plus UTF-8 slice.
    /// - `location == doc` (end caret) → empty slice + actual `{location=doc,length=0}` (primary reconversion path).
    /// - `location == doc, length > 0` also clamps to an empty range at the end (same shape as Apple intersection).
    /// - `location > doc` → null (fully out of range). Empty document (0,0) → empty slice.
    pub fn substringForUtf16Range(self: *const TextBuffer, proposed: Utf16Range) ?Utf16Substring {
        const text = self.slice();
        const actual = clampUtf16RangeToScalars(text, proposed) orelse return null;
        const start_cp = utf16OffsetToCodepointIndex(text, actual.location) orelse return null;
        const end_cp = utf16OffsetToCodepointIndex(text, actual.location + actual.length) orelse return null;
        const byte_start = byteIndex(text, start_cp);
        const byte_end = byteIndex(text, end_cp);
        return .{
            .utf8 = text[byte_start..byte_end],
            .actual_range = actual,
        };
    }

    /// Replace via a UTF-16 replacement range. Out of range, mid-scalar, or invalid UTF-8 is rejected with buffer unchanged.
    /// On success, selection collapses to the end of the replacement (same contract as `replaceSelectionWithTextLimited`).
    pub fn replaceUtf16RangeLimited(
        self: *TextBuffer,
        selection: *SelectionState,
        range: Utf16Range,
        text: []const u8,
        max_len: ?usize,
    ) !bool {
        if (!std.unicode.utf8ValidateSlice(text)) return false;
        const cp_range = validateUtf16RangeForReplace(self.slice(), range) orelse return false;
        selection.anchor = cp_range.start;
        selection.extent = cp_range.end;
        return replaceSelectionWithTextLimited(self, selection, text, max_len);
    }

    /// Shared by document access / TextInput: after replacement, collapse caret to selection.extent.
    pub fn replaceUtf16RangeAndCollapseCaret(
        self: *TextBuffer,
        selection: *SelectionState,
        caret: *usize,
        range: Utf16Range,
        text: []const u8,
        max_len: ?usize,
    ) !bool {
        const did = try self.replaceUtf16RangeLimited(selection, range, text, max_len);
        if (did) caret.* = selection.extent;
        return did;
    }
};

/// UTF-16 code-unit range (same meaning as NSRange / PlatformTextInputRange).
pub const Utf16Range = struct {
    location: u64,
    length: u64,
};

pub const Utf16Substring = struct {
    utf8: []const u8,
    actual_range: Utf16Range,
};

fn utf16UnitsForCodepoint(cp: u32) u64 {
    return if (cp >= 0x10000) 2 else 1;
}

fn decodeAt(text: []const u8, pos: usize) struct { cp: u32, bytes: usize } {
    const n = codepointByteLength(text, pos);
    if (n == 1) return .{ .cp = text[pos], .bytes = 1 };
    const cp = std.unicode.utf8Decode(text[pos .. pos + n]) catch return .{ .cp = text[pos], .bytes = 1 };
    return .{ .cp = cp, .bytes = n };
}

fn utf16LengthOf(text: []const u8) u64 {
    var pos: usize = 0;
    var units: u64 = 0;
    while (pos < text.len) {
        const d = decodeAt(text, pos);
        units += utf16UnitsForCodepoint(d.cp);
        pos += d.bytes;
    }
    return units;
}

fn codepointIndexToUtf16Offset(text: []const u8, index: usize) u64 {
    var pos: usize = 0;
    var cp_i: usize = 0;
    var utf16: u64 = 0;
    while (pos < text.len and cp_i < index) {
        const d = decodeAt(text, pos);
        utf16 += utf16UnitsForCodepoint(d.cp);
        pos += d.bytes;
        cp_i += 1;
    }
    return utf16;
}

/// UTF-16 offset → codepoint index. Mid-surrogate or out of range → null.
fn utf16OffsetToCodepointIndex(text: []const u8, offset: u64) ?usize {
    var pos: usize = 0;
    var cp_i: usize = 0;
    var utf16: u64 = 0;
    while (pos < text.len) {
        if (utf16 == offset) return cp_i;
        const d = decodeAt(text, pos);
        const units = utf16UnitsForCodepoint(d.cp);
        if (offset > utf16 and offset < utf16 + units) return null;
        utf16 += units;
        pos += d.bytes;
        cp_i += 1;
    }
    if (utf16 == offset) return cp_i;
    return null;
}

/// If offset is mid-surrogate, step down to the pair start. Out of range → end of doc.
fn alignUtf16OffsetDown(text: []const u8, offset: u64) u64 {
    const doc = utf16LengthOf(text);
    if (offset >= doc) return doc;
    if (utf16OffsetToCodepointIndex(text, offset) != null) return offset;
    // mid-surrogate → step down 1 to the pair start
    return offset -| 1;
}

/// If offset is mid-surrogate, step up to the pair end.
fn alignUtf16OffsetUp(text: []const u8, offset: u64) u64 {
    const doc = utf16LengthOf(text);
    if (offset >= doc) return doc;
    if (utf16OffsetToCodepointIndex(text, offset) != null) return offset;
    return @min(offset + 1, doc);
}

/// For substring: clamp to the document and align to scalar boundaries.
/// Only `location > doc` is fully out of range (null). `location == doc` is accepted as an empty end range
/// (consistent with the `>` check in `validateUtf16RangeForReplace`; for end-caret queries during reconversion).
fn clampUtf16RangeToScalars(text: []const u8, proposed: Utf16Range) ?Utf16Range {
    const doc = utf16LengthOf(text);
    if (doc == 0) {
        if (proposed.location == 0) return .{ .location = 0, .length = 0 };
        return null;
    }
    if (proposed.location > doc) return null;
    var start = proposed.location;
    var end = proposed.location +| proposed.length;
    if (end > doc) end = doc;
    start = alignUtf16OffsetDown(text, start);
    end = alignUtf16OffsetUp(text, end);
    if (end < start) end = start;
    return .{ .location = start, .length = end - start };
}

/// For replacement: reject out of range and mid-scalar.
fn validateUtf16RangeForReplace(text: []const u8, range: Utf16Range) ?TextRange {
    const doc = utf16LengthOf(text);
    const end_off = range.location +| range.length;
    if (range.location > doc or end_off > doc) return null;
    const start_cp = utf16OffsetToCodepointIndex(text, range.location) orelse return null;
    const end_cp = utf16OffsetToCodepointIndex(text, end_off) orelse return null;
    return .{ .start = @min(start_cp, end_cp), .end = @max(start_cp, end_cp) };
}

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

test "TextLayout: ASCII / variable-width / mixed-Japanese prefix and byte boundaries" {
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

test "TextLayout: invalid UTF-8 keeps boundaries per byte" {
    const layout = try buildTextLayout(testing.allocator, font_mod.default_font, &.{ 0xFF, 'a', 0xC3, 0x28 });
    defer testing.allocator.free(layout.byte_offsets);
    defer testing.allocator.free(layout.prefix_widths);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4 }, layout.byte_offsets);
    try testing.expectEqual(@as(usize, 4), layout.count());
    try testing.expectEqual(@as(usize, 4), byteIndex(layout.text, 4));
}

test "SelectionState: left/right drag, Shift+click, and empty selection" {
    var selection: SelectionState = .{};
    selection.beginDrag(4, false);
    selection.updateDrag(1);
    try testing.expectEqual(TextRange{ .start = 1, .end = 4 }, selection.normalized());
    selection.beginDrag(2, true);
    try testing.expectEqual(TextRange{ .start = 2, .end = 4 }, selection.normalized());
    selection.beginDrag(2, false);
    try testing.expectEqual(TextRange{ .start = 2, .end = 2 }, selection.normalized());
}

test "wordRange: ASCII word / whitespace-punctuation / CJK runs" {
    const text = "hello, 日本語 world";
    const layout = try buildTextLayout(testing.allocator, font_mod.default_font, text);
    defer testing.allocator.free(layout.byte_offsets);
    defer testing.allocator.free(layout.prefix_widths);

    try testing.expectEqual(TextRange{ .start = 0, .end = 5 }, wordRange(layout, 1));
    try testing.expectEqual(TextRange{ .start = 5, .end = 6 }, wordRange(layout, 5));
    try testing.expectEqual(TextRange{ .start = 7, .end = 10 }, wordRange(layout, 8));
    try testing.expectEqual(TextRange{ .start = 11, .end = 16 }, wordRange(layout, 11));
}

test "TextBuffer: ASCII / Japanese insert and forward/back delete" {
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

test "TextBuffer: selection replacement and capacity growth" {
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

test "SelectionState: Left/Right/Home/End and Shift selection" {
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

test "SelectionState word movement and Shift extension" {
    // The Japanese fixture below: h i , sp + 3 CJK + sp o k (10 codepoints)
    const text = "hi, 日本語 ok";
    const layout = try buildTextLayout(testing.allocator, font_mod.default_font, text);
    defer testing.allocator.free(layout.byte_offsets);
    defer testing.allocator.free(layout.prefix_widths);
    const count = layout.count();
    try testing.expectEqual(@as(usize, 10), count);

    var selection: SelectionState = .{ .anchor = 0, .extent = 0 };
    // To the end of the ASCII word
    selection.moveWord(layout, .right, false);
    try testing.expectEqual(TextRange{ .start = 2, .end = 2 }, selection.normalized());
    // Cross the ", " separators to the end of the CJK run
    selection.moveWord(layout, .right, false);
    try testing.expectEqual(TextRange{ .start = 7, .end = 7 }, selection.normalized());
    // Cross the space to the end of "ok"
    selection.moveWord(layout, .right, false);
    try testing.expectEqual(TextRange{ .start = 10, .end = 10 }, selection.normalized());
    // no-op at the end
    selection.moveWord(layout, .right, false);
    try testing.expectEqual(TextRange{ .start = 10, .end = 10 }, selection.normalized());

    // Left: start of "ok" → start of CJK run → start of "hi" → no-op at start
    selection.moveWord(layout, .left, false);
    try testing.expectEqual(TextRange{ .start = 8, .end = 8 }, selection.normalized());
    selection.moveWord(layout, .left, false);
    try testing.expectEqual(TextRange{ .start = 4, .end = 4 }, selection.normalized());
    selection.moveWord(layout, .left, false);
    try testing.expectEqual(TextRange{ .start = 0, .end = 0 }, selection.normalized());
    selection.moveWord(layout, .left, false);
    try testing.expectEqual(TextRange{ .start = 0, .end = 0 }, selection.normalized());

    // Non-Shift: existing selection collapses to an endpoint (no further move)
    selection = .{ .anchor = 0, .extent = 5 };
    selection.moveWord(layout, .right, false);
    try testing.expectEqual(TextRange{ .start = 5, .end = 5 }, selection.normalized());
    selection = .{ .anchor = 0, .extent = 5 };
    selection.moveWord(layout, .left, false);
    try testing.expectEqual(TextRange{ .start = 0, .end = 0 }, selection.normalized());

    // Shift+Option: extend selection (anchor fixed)
    selection = .{ .anchor = 2, .extent = 2 };
    selection.moveWord(layout, .right, true);
    try testing.expectEqual(TextRange{ .start = 2, .end = 7 }, selection.normalized());
    selection.moveWord(layout, .left, true);
    try testing.expectEqual(TextRange{ .start = 2, .end = 4 }, selection.normalized());
}

test "replaceSelectionWithText ASCII / Japanese / empty-selection paste" {
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

test "replaceSelectionWithText excludes controls/newlines and stays intact on invalid UTF-8" {
    var buffer = try TextBuffer.init(testing.allocator, "X");
    defer buffer.deinit();
    var selection: SelectionState = .{ .anchor = 1, .extent = 1 };
    try testing.expect(try buffer.replaceSelectionWithText(&selection, "A\nB\x00C"));
    try testing.expectEqualStrings("XABC", buffer.slice());

    selection = .{ .anchor = 4, .extent = 4 };
    // Skip a bad leading byte; following ASCII still inserts
    _ = try buffer.replaceSelectionWithText(&selection, &.{ 0xFF, 'Z' });
    try testing.expectEqualStrings("XABCZ", buffer.slice());
    try testing.expect(std.unicode.utf8ValidateSlice(buffer.slice()));
}

test "selection collapse after cut-equivalent deleteRange" {
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

test "ASCII max_len just-before / at / over the limit" {
    var buffer = try TextBuffer.init(testing.allocator, "ab");
    defer buffer.deinit();
    var selection: SelectionState = .{ .anchor = 2, .extent = 2 };
    // Just before: max_len=3 allows one more character
    try testing.expect(try buffer.replaceSelectionWithCodepoint(&selection, 'c', 3));
    try testing.expectEqualStrings("abc", buffer.slice());
    // At the limit: further inserts are rejected
    try testing.expect(!try buffer.replaceSelectionWithCodepoint(&selection, 'd', 3));
    try testing.expectEqualStrings("abc", buffer.slice());
    try testing.expectEqual(@as(usize, 3), selection.extent);
    // Over-limit paste is truncated
    try testing.expect(!try buffer.replaceSelectionWithTextLimited(&selection, "XYZ", 3));
    try testing.expectEqualStrings("abc", buffer.slice());
}

test "max_len=0 rejects insertion" {
    var buffer = try TextBuffer.init(testing.allocator, "");
    defer buffer.deinit();
    var selection: SelectionState = .{};
    try testing.expect(!try buffer.replaceSelectionWithCodepoint(&selection, 'A', 0));
    try testing.expect(!try buffer.replaceSelectionWithTextLimited(&selection, "Hi", 0));
    try testing.expectEqualStrings("", buffer.slice());
}

test "max_len=null is unlimited (same as before)" {
    var buffer = try TextBuffer.init(testing.allocator, "");
    defer buffer.deinit();
    var selection: SelectionState = .{};
    try testing.expect(try buffer.replaceSelectionWithCodepoint(&selection, 'A', null));
    try testing.expect(try buffer.replaceSelectionWithTextLimited(&selection, "BC", null));
    try testing.expectEqualStrings("ABC", buffer.slice());
}

test "Japanese UTF-8 3-byte is 1 codepoint" {
    var buffer = try TextBuffer.init(testing.allocator, "");
    defer buffer.deinit();
    var selection: SelectionState = .{};
    try testing.expect(try buffer.replaceSelectionWithCodepoint(&selection, 'あ', 1));
    try testing.expectEqualStrings("あ", buffer.slice());
    try testing.expectEqual(@as(usize, 3), buffer.slice().len);
    try testing.expect(!try buffer.replaceSelectionWithCodepoint(&selection, 'い', 1));
    try testing.expectEqualStrings("あ", buffer.slice());
}

test "emoji UTF-8 4-byte is 1 codepoint" {
    var buffer = try TextBuffer.init(testing.allocator, "");
    defer buffer.deinit();
    var selection: SelectionState = .{};
    const grin: u32 = 0x1F600; // 😀
    try testing.expect(try buffer.replaceSelectionWithCodepoint(&selection, grin, 1));
    try testing.expectEqual(@as(usize, 4), buffer.slice().len);
    try testing.expect(!try buffer.replaceSelectionWithCodepoint(&selection, 'A', 1));
    try testing.expectEqual(@as(usize, 4), buffer.slice().len);
}

test "selection-replacement paste uses remaining capacity" {
    var buffer = try TextBuffer.init(testing.allocator, "abcdef");
    defer buffer.deinit();
    var selection: SelectionState = .{ .anchor = 1, .extent = 5 }; // "bcde"
    // base=2 ("a"+"f"), max_len=4 → remaining 2
    try testing.expect(try buffer.replaceSelectionWithTextLimited(&selection, "XYZ", 4));
    try testing.expectEqualStrings("aXYf", buffer.slice());
    try testing.expectEqual(@as(usize, 3), selection.extent);
}

test "selection-replacement typed char" {
    var buffer = try TextBuffer.init(testing.allocator, "abcd");
    defer buffer.deinit();
    var selection: SelectionState = .{ .anchor = 1, .extent = 3 }; // "bc"
    try testing.expect(try buffer.replaceSelectionWithCodepoint(&selection, 'Z', 3));
    try testing.expectEqualStrings("aZd", buffer.slice());
}

test "paste truncates when max_len is hit mid-paste" {
    var buffer = try TextBuffer.init(testing.allocator, "ab");
    defer buffer.deinit();
    var selection: SelectionState = .{ .anchor = 2, .extent = 2 };
    try testing.expect(try buffer.replaceSelectionWithTextLimited(&selection, "CDEF", 4));
    try testing.expectEqualStrings("abCD", buffer.slice());
    try testing.expectEqual(@as(usize, 4), selection.extent);
}

test "controls / newlines / invalid UTF-8 with max_len" {
    var buffer = try TextBuffer.init(testing.allocator, "");
    defer buffer.deinit();
    var selection: SelectionState = .{};
    // Controls/newlines excluded; only 2 insertable chars enter (max_len=2)
    try testing.expect(try buffer.replaceSelectionWithTextLimited(&selection, "A\nB\x00C", 2));
    try testing.expectEqualStrings("AB", buffer.slice());
    // After skipping invalid UTF-8, Z is rejected at the cap
    try testing.expect(!try buffer.replaceSelectionWithTextLimited(&selection, &.{ 0xFF, 'Z' }, 2));
    try testing.expectEqualStrings("AB", buffer.slice());
    try testing.expect(std.unicode.utf8ValidateSlice(buffer.slice()));
}

test "UTF-16 offset ASCII / BMP Japanese" {
    var buffer = try TextBuffer.init(testing.allocator, "AあB");
    defer buffer.deinit();
    // A=1, U+3042=1, B=1 → total 3 UTF-16 units, 3 codepoints
    try testing.expectEqual(@as(u64, 3), buffer.utf16Length());
    try testing.expectEqual(@as(u64, 0), buffer.codepointIndexToUtf16(0));
    try testing.expectEqual(@as(u64, 1), buffer.codepointIndexToUtf16(1));
    try testing.expectEqual(@as(u64, 2), buffer.codepointIndexToUtf16(2));
    try testing.expectEqual(@as(u64, 3), buffer.codepointIndexToUtf16(3));
    const sel: SelectionState = .{ .anchor = 1, .extent = 2 };
    const r = buffer.selectedRangeUtf16(sel);
    try testing.expectEqual(@as(u64, 1), r.location);
    try testing.expectEqual(@as(u64, 1), r.length);
}

test "UTF-16 offset supplementary-plane emoji (surrogate pair)" {
    var buffer = try TextBuffer.init(testing.allocator, "");
    defer buffer.deinit();
    var selection: SelectionState = .{};
    try testing.expect(try buffer.replaceSelectionWithCodepoint(&selection, 0x1F600, null)); // 😀
    try testing.expectEqual(@as(u64, 2), buffer.utf16Length());
    try testing.expectEqual(@as(u64, 0), buffer.codepointIndexToUtf16(0));
    try testing.expectEqual(@as(u64, 2), buffer.codepointIndexToUtf16(1));
    // mid-surrogate: clamp for substring, reject for replacement
    const mid = buffer.substringForUtf16Range(.{ .location = 1, .length = 1 }) orelse unreachable;
    try testing.expectEqual(@as(u64, 0), mid.actual_range.location);
    try testing.expectEqual(@as(u64, 2), mid.actual_range.length);
    try testing.expectEqualStrings("😀", mid.utf8);
    try testing.expect(!try buffer.replaceUtf16RangeLimited(&selection, .{ .location = 1, .length = 1 }, "X", null));
    try testing.expectEqualStrings("😀", buffer.slice());
}

test "substring actual range and empty document" {
    var empty = try TextBuffer.init(testing.allocator, "");
    defer empty.deinit();
    const e = empty.substringForUtf16Range(.{ .location = 0, .length = 0 }) orelse unreachable;
    try testing.expectEqualStrings("", e.utf8);
    try testing.expect(empty.substringForUtf16Range(.{ .location = 1, .length = 0 }) == null);

    var buffer = try TextBuffer.init(testing.allocator, "漢字");
    defer buffer.deinit();
    // clamp overshoot length
    const sub = buffer.substringForUtf16Range(.{ .location = 1, .length = 99 }) orelse unreachable;
    try testing.expectEqual(@as(u64, 1), sub.actual_range.location);
    try testing.expectEqual(@as(u64, 1), sub.actual_range.length);
    try testing.expectEqualStrings("字", sub.utf8);
    try testing.expect(buffer.substringForUtf16Range(.{ .location = 10, .length = 1 }) == null);
}

test "substring end caret (location == doc, length == 0) is an empty range" {
    var buffer = try TextBuffer.init(testing.allocator, "AB");
    defer buffer.deinit();
    try testing.expectEqual(@as(u64, 2), buffer.utf16Length());
    const at_end = buffer.substringForUtf16Range(.{ .location = 2, .length = 0 }) orelse unreachable;
    try testing.expectEqualStrings("", at_end.utf8);
    try testing.expectEqual(@as(u64, 2), at_end.actual_range.location);
    try testing.expectEqual(@as(u64, 0), at_end.actual_range.length);
}

test "substring location == doc with length > 0 clamps to an empty range at the end" {
    // Spec: location == doc is accepted; clamp end to doc → empty range (only location > doc is fully out of range → null).
    var buffer = try TextBuffer.init(testing.allocator, "AB");
    defer buffer.deinit();
    const clamped = buffer.substringForUtf16Range(.{ .location = 2, .length = 5 }) orelse unreachable;
    try testing.expectEqualStrings("", clamped.utf8);
    try testing.expectEqual(@as(u64, 2), clamped.actual_range.location);
    try testing.expectEqual(@as(u64, 0), clamped.actual_range.length);
    try testing.expect(buffer.substringForUtf16Range(.{ .location = 3, .length = 0 }) == null);
}

test "replacement apply / selection collapse / max_len / reject" {
    var buffer = try TextBuffer.init(testing.allocator, "ab漢字cd");
    defer buffer.deinit();
    var selection: SelectionState = .{ .anchor = 0, .extent = 0 };
    var caret: usize = 0;
    // The CJK fixture below = codepoints 2..4 = utf16 2..4
    try testing.expect(try buffer.replaceUtf16RangeAndCollapseCaret(
        &selection,
        &caret,
        .{ .location = 2, .length = 2 },
        "XY",
        null,
    ));
    try testing.expectEqualStrings("abXYcd", buffer.slice());
    try testing.expectEqual(TextRange{ .start = 4, .end = 4 }, selection.normalized());
    try testing.expectEqual(@as(usize, 4), caret);

    // Reject out of range
    try testing.expect(!try buffer.replaceUtf16RangeLimited(&selection, .{ .location = 0, .length = 99 }, "Z", null));
    try testing.expectEqualStrings("abXYcd", buffer.slice());

    // Reject invalid UTF-8
    try testing.expect(!try buffer.replaceUtf16RangeLimited(&selection, .{ .location = 2, .length = 0 }, &.{0xFF}, null));
    try testing.expectEqualStrings("abXYcd", buffer.slice());

    // max_len: already at the cap → reject insert
    selection = .{ .anchor = 6, .extent = 6 };
    try testing.expect(!try buffer.replaceUtf16RangeLimited(&selection, .{ .location = 6, .length = 0 }, "!", 6));
    try testing.expectEqualStrings("abXYcd", buffer.slice());
}

test "replacement into an empty document and caret at start/end" {
    var buffer = try TextBuffer.init(testing.allocator, "");
    defer buffer.deinit();
    var selection: SelectionState = .{};
    var caret: usize = 0;
    try testing.expect(try buffer.replaceUtf16RangeAndCollapseCaret(
        &selection,
        &caret,
        .{ .location = 0, .length = 0 },
        "あ",
        null,
    ));
    try testing.expectEqualStrings("あ", buffer.slice());
    try testing.expectEqual(@as(usize, 1), caret);
    // Insert at end
    try testing.expect(try buffer.replaceUtf16RangeAndCollapseCaret(
        &selection,
        &caret,
        .{ .location = 1, .length = 0 },
        "B",
        null,
    ));
    try testing.expectEqualStrings("あB", buffer.slice());
    try testing.expectEqual(@as(usize, 2), caret);
}
