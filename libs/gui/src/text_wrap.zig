// Text wrapping, paragraph splitting, control-character normalisation, and truncation.
//
// Hot path declaration: layout and wrap run every frame on the GUI layout path.
// They are not a per-pixel loop and do not touch the real-time audio path.
//
// Text model: every text leaf is a sequence of paragraphs. `wrap` only decides
// whether a paragraph is folded at the settled width. Font vtables never see
// control characters.
//
// Font.measure is the sum of per-glyph advances with no kerning, so the sum of
// per-segment measures equals the measure of the concatenation. Wrap and
// measureIntrinsicWidth rely on that.

const std = @import("std");
const Allocator = std.mem.Allocator;

const font_mod = @import("font.zig");

pub const Font = font_mod.Font;

/// Trailing marker used by both the declarative overflow path and `truncate`.
pub const ellipsis = "...";

pub const Overflow = enum { visible, clip, ellipsis };

pub const WrapOpts = struct {
    wrap: bool = false,
    /// 0 means unlimited for `.visible` / `.clip`, and 1 for `.ellipsis`.
    max_lines: u16 = 0,
    overflow: Overflow = .visible,
};

pub const Line = struct {
    /// Slice of the input `text` when no normalisation ran, or of the
    /// allocator-owned normalised buffer when it did. Ellipsis lines are
    /// always an allocator-owned copy.
    text: []const u8,
    y_offset: i32 = 0,
};

pub const TruncateResult = struct {
    text: []const u8,
    truncated: bool = false,
};

/// Result of `wrapParagraphs`.
///
/// Ownership: `lines` is allocator-owned when non-empty (the zero-allocation
/// fast path returns an empty slice). `normalized` is allocator-owned when
/// non-null. Each `Line.text` borrows `text` (no normalisation) or `normalized`
/// (normalisation ran), except ellipsis lines, which are additional
/// allocator-owned copies. A general-allocator caller frees `lines` and, if
/// present, `normalized`. Ellipsis copies die with the allocator (frame arena)
/// or must be freed individually if they do not alias `text` / `normalized`.
pub const WrapResult = struct {
    lines: []Line,
    normalized: ?[]u8 = null,
};

/// Resolve `max_lines` against `overflow`. `.ellipsis` with 0 becomes 1 so an
/// ellipsis request cannot silently become unlimited. `.visible` / `.clip`
/// with 0 is unlimited (`maxInt(u32)`); the i32 height cap is applied separately
/// by `effectiveLineLimit`.
pub fn resolvedMaxLines(opts: WrapOpts) u32 {
    if (opts.max_lines > 0) return opts.max_lines;
    return switch (opts.overflow) {
        .ellipsis => 1,
        .visible, .clip => std.math.maxInt(u32),
    };
}

/// Maximum logical lines whose stacked height still fits in i32.
///
/// One line uses ink height; two or more use `(n - 1) * line_height + ink`.
/// This is a physical i32 constraint, not a user-facing `max_lines`. When
/// `line_height` is 0 the stacked height never grows and there is no cap.
pub fn maxLinesForI32Height(font: Font) u32 {
    const lh_u = font.metrics().line_height;
    if (lh_u == 0) return std.math.maxInt(u32);
    const lh: u32 = @intCast(@min(lh_u, std.math.maxInt(i32)));
    const ink: u32 = @intCast(@max(0, font_mod.fontInkHeight(font)));
    const max_h: u32 = std.math.maxInt(i32);
    if (ink >= max_h) return 1;
    const extra = (max_h - ink) / lh;
    return extra + 1;
}

/// User `max_lines` after the 0-means-unlimited / ellipsis-0-means-1 rule,
/// clamped to the i32 height cap.
pub fn effectiveLineLimit(font: Font, opts: WrapOpts) u32 {
    return @min(resolvedMaxLines(opts), maxLinesForI32Height(font));
}

/// True when `text` contains a byte that contract 1 rewrites or drops.
pub fn needsNormalization(text: []const u8) bool {
    for (text) |b| {
        if (b < 0x20 or b == 0x7F) return true;
    }
    return false;
}

/// Whether a line break may occur immediately before `right` when the previous
/// codepoint was `left`. Grapheme-cluster keeping and kinsoku (no line-start
/// `。`, `、`, `」`, …) are not applied; those rules plug in here later.
pub fn canBreakBefore(left: ?u21, right: u21) bool {
    if (left) |l| {
        if (isAsciiSpace(l)) return true;
        if (isCjk(l) or isCjk(right)) return true;
    }
    return false;
}

fn isAsciiSpace(cp: u21) bool {
    return cp == ' ';
}

fn isDiscardControl(b: u8) bool {
    return (b < 0x20 and b != '\n' and b != '\r' and b != '\t') or b == 0x7F;
}

/// CJK Unified Ideographs, kana, fullwidth forms, CJK symbols, Hangul syllables.
fn isCjk(cp: u21) bool {
    return switch (cp) {
        0x3000...0x303F => true,
        0x3040...0x309F => true,
        0x30A0...0x30FF => true,
        0x31F0...0x31FF => true,
        0x3200...0x32FF => true,
        0x3300...0x33FF => true,
        0x3400...0x4DBF => true,
        0x4E00...0x9FFF => true,
        0xAC00...0xD7AF => true,
        0xF900...0xFAFF => true,
        0xFF00...0xFFEF => true,
        else => false,
    };
}

fn utf8Valid(text: []const u8) bool {
    return std.unicode.utf8ValidateSlice(text);
}

fn unitAt(text: []const u8, i: usize, valid: bool) struct { cp: u21, len: usize } {
    if (i >= text.len) return .{ .cp = 0, .len = 0 };
    if (!valid) return .{ .cp = text[i], .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return .{ .cp = text[i], .len = 1 };
    if (i + len > text.len) return .{ .cp = text[i], .len = 1 };
    const cp = std.unicode.utf8Decode(text[i .. i + len]) catch return .{ .cp = text[i], .len = 1 };
    return .{ .cp = cp, .len = len };
}

fn firstUnitLen(text: []const u8) usize {
    if (text.len == 0) return 0;
    return unitAt(text, 0, utf8Valid(text)).len;
}

fn satAdd(a: i32, b: i32) i32 {
    const s = @as(i64, a) + @as(i64, b);
    if (s > std.math.maxInt(i32)) return std.math.maxInt(i32);
    if (s < 0) return 0;
    return @intCast(s);
}

fn satMul(count: u32, unit: i32) i32 {
    if (unit <= 0 or count == 0) return 0;
    const p = @as(i64, count) * @as(i64, unit);
    if (p > std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intCast(p);
}

fn advanceWidth(font: Font, piece: []const u8) i32 {
    if (piece.len == 0) return 0;
    return @intCast(font.measure(piece));
}

/// Leaf height for `line_count` logical lines. One line uses ink height so a
/// single-line leaf matches the historical text-leaf size. Two or more lines
/// use `(n - 1) * line_height + ink`, saturated to i32.
pub fn heightForLineCount(font: Font, line_count: u32) i32 {
    if (line_count == 0) return 0;
    const ink = font_mod.fontInkHeight(font);
    if (line_count == 1) return ink;
    const lh: i32 = @intCast(@min(font.metrics().line_height, std.math.maxInt(i32)));
    return satAdd(satMul(line_count - 1, lh), ink);
}

/// Longest prefix of `text` whose measure is `<= max_w`.
///
/// Unbreakable Latin words that do not fit a line are cut with this search:
/// `Font.measure(prefix)` walks the whole prefix, so one segment of length m
/// costs O(log m) vtable calls and O(m log m) bytes scanned. That is preferred
/// over a per-codepoint measure (O(m) vtable calls, O(m²) bytes scanned).
///
/// Boundaries are codepoint edges on valid UTF-8 and byte edges on invalid UTF-8.
pub fn longestPrefixThatFits(font: Font, text: []const u8, max_w: i32) usize {
    if (text.len == 0 or max_w <= 0) return 0;
    if (advanceWidth(font, text) <= max_w) return text.len;

    const valid = utf8Valid(text);
    var units: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        i += unitAt(text, i, valid).len;
        units += 1;
    }
    if (units == 0) return 0;

    var lo: usize = 0;
    var hi: usize = units;
    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        const prefix_len = prefixUnitsLen(text, mid, valid);
        if (advanceWidth(font, text[0..prefix_len]) <= max_w) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    return prefixUnitsLen(text, lo, valid);
}

fn prefixUnitsLen(text: []const u8, n: usize, valid: bool) usize {
    var i: usize = 0;
    var k: usize = 0;
    while (k < n and i < text.len) : (k += 1) {
        i += unitAt(text, i, valid).len;
    }
    return i;
}

/// Next unbreakable run starting at `i`: one CJK codepoint, or a run of
/// non-space non-CJK units.
fn nextUnbreakable(text: []const u8, i: usize, valid: bool) []const u8 {
    if (i >= text.len) return text[i..i];
    const first = unitAt(text, i, valid);
    if (isCjk(first.cp)) return text[i .. i + first.len];
    var j = i + first.len;
    while (j < text.len) {
        const u = unitAt(text, j, valid);
        if (isAsciiSpace(u.cp) or isCjk(u.cp)) break;
        j += u.len;
    }
    return text[i..j];
}

fn skipParaBreak(text: []const u8, i: usize) usize {
    if (i >= text.len) return i;
    if (text[i] == '\r') {
        if (i + 1 < text.len and text[i + 1] == '\n') return i + 2;
        return i + 1;
    }
    if (text[i] == '\n') return i + 1;
    return i;
}

fn isParaBreak(b: u8) bool {
    return b == '\n' or b == '\r';
}

/// Max intrinsic width of the paragraphs in `text` after contract-1 normalisation.
/// Empty text is width 0. Does not allocate: discarded controls are skipped and
/// paragraph widths are summed from per-unit measures (no kerning).
pub fn measureIntrinsicWidth(font: Font, text: []const u8) i32 {
    if (text.len == 0) return 0;
    if (!needsNormalization(text)) return advanceWidth(font, text);

    const space_w = advanceWidth(font, " ");
    var max_w: i32 = 0;
    var para_w: i32 = 0;
    var i: usize = 0;
    const valid = utf8Valid(text);
    while (i < text.len) {
        const b = text[i];
        if (isParaBreak(b)) {
            max_w = @max(max_w, para_w);
            para_w = 0;
            i = skipParaBreak(text, i);
            continue;
        }
        if (b == '\t') {
            para_w = satAdd(para_w, space_w);
            i += 1;
            continue;
        }
        if (isDiscardControl(b)) {
            i += 1;
            continue;
        }
        const u = unitAt(text, i, valid);
        para_w = satAdd(para_w, advanceWidth(font, text[i .. i + u.len]));
        i += u.len;
    }
    return @max(max_w, para_w);
}

/// Number of paragraphs under contract 1. `""` is 1; a trailing break adds an
/// empty paragraph (`"a\n"` and `"\n"` are both 2).
pub fn paragraphCount(text: []const u8) u32 {
    var n: u32 = 1;
    var i: usize = 0;
    while (i < text.len) {
        if (isParaBreak(text[i])) {
            n += 1;
            i = skipParaBreak(text, i);
        } else {
            i += 1;
        }
    }
    return n;
}

fn normalizeParagraphs(allocator: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len);
    const valid = utf8Valid(text);
    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (isParaBreak(b)) {
            try out.append(allocator, '\n');
            i = skipParaBreak(text, i);
            continue;
        }
        if (b == '\t') {
            try out.append(allocator, ' ');
            i += 1;
            continue;
        }
        if (isDiscardControl(b)) {
            i += 1;
            continue;
        }
        const u = unitAt(text, i, valid);
        try out.appendSlice(allocator, text[i .. i + u.len]);
        i += u.len;
    }
    return out.toOwnedSlice(allocator);
}

/// Single-line normalisation for `truncate`: LF / CR / TAB become one space;
/// other C0 and DEL are dropped. Paragraphs are not split.
fn normalizeInline(allocator: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len);
    const valid = utf8Valid(text);
    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (isParaBreak(b)) {
            try out.append(allocator, ' ');
            i = skipParaBreak(text, i);
            continue;
        }
        if (b == '\t') {
            try out.append(allocator, ' ');
            i += 1;
            continue;
        }
        if (isDiscardControl(b)) {
            i += 1;
            continue;
        }
        const u = unitAt(text, i, valid);
        try out.appendSlice(allocator, text[i .. i + u.len]);
        i += u.len;
    }
    return out.toOwnedSlice(allocator);
}

const Append = enum { added, full };

fn appendLine(lines: *std.ArrayList(Line), allocator: Allocator, text: []const u8, cap: u32) Allocator.Error!Append {
    if (lines.items.len >= cap) return .full;
    try lines.append(allocator, .{ .text = text, .y_offset = 0 });
    return .added;
}

/// Returns true when `para` still has undrawn content after hitting `cap`.
fn wrapParagraph(
    lines: *std.ArrayList(Line),
    allocator: Allocator,
    font: Font,
    para: []const u8,
    avail_w: i32,
    cap: u32,
) Allocator.Error!bool {
    if (lines.items.len >= cap) return true;
    if (para.len == 0) {
        _ = try appendLine(lines, allocator, para, cap);
        return false;
    }
    if (avail_w <= 0) {
        _ = try appendLine(lines, allocator, para[0..0], cap);
        return false;
    }

    const valid = utf8Valid(para);
    var i: usize = 0;
    var line_start: usize = 0;
    var line_end: usize = 0;
    var line_w: i32 = 0;
    var pending_space_end: usize = 0;
    var pending_space_w: i32 = 0;

    while (i < para.len) {
        if (para[i] == ' ') {
            var j = i;
            while (j < para.len and para[j] == ' ') j += 1;
            const sw = advanceWidth(font, para[i..j]);
            if (line_end == line_start and pending_space_end == line_start) {
                if (sw <= avail_w) {
                    line_end = j;
                    line_w = sw;
                    pending_space_end = j;
                    pending_space_w = 0;
                }
                // Leading spaces that do not fit are dropped.
                i = j;
                continue;
            }
            pending_space_end = j;
            pending_space_w = satAdd(pending_space_w, sw);
            i = j;
            continue;
        }

        const seg = nextUnbreakable(para, i, valid);
        const seg_w = advanceWidth(font, seg);

        if (line_end == line_start) {
            if (seg_w <= avail_w) {
                line_end = i + seg.len;
                line_w = seg_w;
                pending_space_end = line_end;
                pending_space_w = 0;
                i += seg.len;
                continue;
            }
            if (try forceSplitSegment(lines, allocator, font, seg, avail_w, cap)) return true;
            i += seg.len;
            line_start = i;
            line_end = i;
            line_w = 0;
            pending_space_end = i;
            pending_space_w = 0;
            continue;
        }

        const need = satAdd(pending_space_w, seg_w);
        if (satAdd(line_w, need) <= avail_w) {
            line_end = i + seg.len;
            line_w = satAdd(line_w, need);
            pending_space_end = line_end;
            pending_space_w = 0;
            i += seg.len;
            continue;
        }

        if (try appendLine(lines, allocator, para[line_start..line_end], cap) == .full) return true;
        line_start = i;
        line_end = i;
        line_w = 0;
        pending_space_end = i;
        pending_space_w = 0;
        // `seg` is retried on the new line (do not advance i).
    }

    // Trailing spaces at the end of a paragraph stay on the line when they fit.
    // Spaces consumed at a wrap point (pending when a following word did not
    // fit) are already excluded because `line_end` was not advanced over them.
    if (pending_space_end > line_end and satAdd(line_w, pending_space_w) <= avail_w) {
        line_end = pending_space_end;
    }

    if (line_end > line_start) {
        return (try appendLine(lines, allocator, para[line_start..line_end], cap)) == .full;
    }
    if (line_end == line_start and i >= para.len and lines.items.len == 0) {
        _ = try appendLine(lines, allocator, para[0..0], cap);
    }
    return false;
}

/// Returns true when `seg` still has undrawn bytes after hitting `cap`.
fn forceSplitSegment(
    lines: *std.ArrayList(Line),
    allocator: Allocator,
    font: Font,
    seg: []const u8,
    avail_w: i32,
    cap: u32,
) Allocator.Error!bool {
    var rest = seg;
    while (rest.len > 0) {
        if (lines.items.len >= cap) return true;
        var n = longestPrefixThatFits(font, rest, avail_w);
        if (n == 0) n = firstUnitLen(rest);
        if (n == 0) break;
        _ = try appendLine(lines, allocator, rest[0..n], cap);
        rest = rest[n..];
    }
    return false;
}

fn applyYOffsets(lines: []Line, font: Font) void {
    const lh: i32 = @intCast(@min(font.metrics().line_height, std.math.maxInt(i32)));
    for (lines, 0..) |*line, i| {
        line.y_offset = satMul(@intCast(i), lh);
    }
}

fn ellipsizeLine(
    allocator: Allocator,
    font: Font,
    line: []const u8,
    avail_w: i32,
) Allocator.Error![]const u8 {
    const ell_w = advanceWidth(font, ellipsis);
    if (ell_w > avail_w) {
        const n = longestPrefixThatFits(font, line, avail_w);
        const owned = try allocator.alloc(u8, n);
        @memcpy(owned, line[0..n]);
        return owned;
    }
    const budget = avail_w - ell_w;
    const n = longestPrefixThatFits(font, line, budget);
    const owned = try allocator.alloc(u8, n + ellipsis.len);
    @memcpy(owned[0..n], line[0..n]);
    @memcpy(owned[n..], ellipsis);
    return owned;
}

/// Split `text` into logical lines at `avail_w`.
///
/// A single-paragraph, non-wrap, `.visible` leaf that needs no normalisation
/// returns an empty `lines` slice and does not allocate. `emitNode` treats that
/// as one command using the original string.
///
/// `max_lines = 0` is unlimited for `.visible` / `.clip`. The only hard stop is
/// `maxLinesForI32Height`: stacked line height must fit in i32. Hitting that
/// cap with leftover text is treated as undrawn content (`.ellipsis` marks it;
/// `.visible` / `.clip` drop the rest).
///
/// `.ellipsis` applies a per-line width guarantee: every visible line that
/// exceeds `avail_w` is ellipsized, and the last line is also ellipsized when
/// undrawn text remains after `max_lines` or the height cap.
///
/// Lifetime: see `WrapResult`. Callers must keep `text` alive while reading
/// borrowed line slices. Context paths dupe the input onto the frame arena
/// first, so both cases stay valid through `endFrame`.
///
/// Hot path: runs every frame on the GUI layout path (not a per-pixel loop,
/// not the real-time audio path).
pub fn wrapParagraphs(
    allocator: Allocator,
    font: Font,
    text: []const u8,
    avail_w: i32,
    opts: WrapOpts,
) Allocator.Error!WrapResult {
    const limit = effectiveLineLimit(font, opts);
    if (!opts.wrap and opts.overflow == .visible and !needsNormalization(text)) {
        return .{ .lines = &.{}, .normalized = null };
    }

    const owned_norm: ?[]u8 = if (needsNormalization(text))
        try normalizeParagraphs(allocator, text)
    else
        null;
    errdefer if (owned_norm) |buf| allocator.free(buf);
    const working: []const u8 = owned_norm orelse text;

    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(allocator);
    const para_n = paragraphCount(working);
    const text_est: usize = if (opts.wrap) working.len + para_n else para_n;
    const estimate = @min(text_est, @as(usize, limit));
    if (estimate > 0) try lines.ensureTotalCapacity(allocator, estimate);

    var leftover = false;
    var i: usize = 0;
    while (i <= working.len) {
        const start = i;
        while (i < working.len and working[i] != '\n') i += 1;
        const para = working[start..i];
        const at_end = i >= working.len;
        if (opts.wrap) {
            leftover = try wrapParagraph(&lines, allocator, font, para, avail_w, limit);
        } else {
            leftover = (try appendLine(&lines, allocator, para, limit)) == .full;
        }
        if (leftover) break;
        if (at_end) break;
        i += 1;
        if (i == working.len) {
            leftover = (try appendLine(&lines, allocator, working[i..i], limit)) == .full;
            break;
        }
    }

    if (opts.overflow == .ellipsis and lines.items.len > 0) {
        for (lines.items, 0..) |*line, idx| {
            const is_last = idx + 1 == lines.items.len;
            const overflows = advanceWidth(font, line.text) > avail_w;
            if (overflows or (is_last and leftover)) {
                line.text = try ellipsizeLine(allocator, font, line.text, avail_w);
            }
        }
    }

    const out = try lines.toOwnedSlice(allocator);
    applyYOffsets(out, font);
    return .{ .lines = out, .normalized = owned_norm };
}

/// Low-level single-line truncate. Same semantics as the historical
/// `ellipsizeText`: when `"..."` itself does not fit `max_w`, the result is
/// `"..."` and may exceed `max_w`. The declarative wrap path must never exceed
/// the box, so it drops the marker and hard-clips instead. Pixie caret / IME
/// composition depends on this low-level contract.
///
/// Control characters are normalised the same way as contract 1, but LF / CR
/// become a space rather than a paragraph break (this API is single-line).
///
/// Lifetime: returns `text` (or the normalised copy) when nothing is truncated.
/// The caller must keep `text` alive while reading a borrowed result.
pub fn truncate(
    allocator: Allocator,
    font: Font,
    text: []const u8,
    max_w: i32,
) Allocator.Error!TruncateResult {
    const working: []const u8 = if (needsNormalization(text))
        try normalizeInline(allocator, text)
    else
        text;

    if (max_w <= 0) return .{ .text = working, .truncated = false };
    if (advanceWidth(font, working) <= max_w) return .{ .text = working, .truncated = false };

    const ell_w = advanceWidth(font, ellipsis);
    if (ell_w >= max_w) {
        const owned = try allocator.dupe(u8, ellipsis);
        return .{ .text = owned, .truncated = true };
    }
    const budget = max_w - ell_w;
    const keep = longestPrefixThatFits(font, working, budget);
    const owned = try allocator.alloc(u8, keep + ellipsis.len);
    @memcpy(owned[0..keep], working[0..keep]);
    @memcpy(owned[keep..], ellipsis);
    return .{ .text = owned, .truncated = true };
}

// ============================================================
// Tests
// ============================================================

const test_font = font_mod.default_font;

fn wrapTest(arena: Allocator, text: []const u8, avail_w: i32, opts: WrapOpts) ![]Line {
    return (try wrapParagraphs(arena, test_font, text, avail_w, opts)).lines;
}

fn countingFont(counter: *u32) Font {
    const Holder = struct {
        var c: *u32 = undefined;
        fn measure(_: *const anyopaque, text: []const u8) u32 {
            c.* += 1;
            return test_font.measure(text);
        }
        fn drawTo(_: *const anyopaque, _: font_mod.RenderTarget, _: font_mod.Vec2, _: []const u8, _: font_mod.Color, _: font_mod.Rect, _: f32) void {}
        fn metrics(_: *const anyopaque) font_mod.Metrics {
            return test_font.metrics();
        }
        const vt: Font.VTable = .{ .measure = measure, .drawTo = drawTo, .metrics = metrics };
    };
    Holder.c = counter;
    return .{ .ptr = counter, .vtable = &Holder.vt };
}

test "paragraphCount: empty, trailing break, lone break, consecutive" {
    try std.testing.expectEqual(@as(u32, 1), paragraphCount(""));
    try std.testing.expectEqual(@as(u32, 1), paragraphCount("a"));
    try std.testing.expectEqual(@as(u32, 2), paragraphCount("a\n"));
    try std.testing.expectEqual(@as(u32, 2), paragraphCount("\n"));
    try std.testing.expectEqual(@as(u32, 2), paragraphCount("a\nb"));
    try std.testing.expectEqual(@as(u32, 3), paragraphCount("a\n\nb"));
    try std.testing.expectEqual(@as(u32, 2), paragraphCount("a\r\nb"));
    try std.testing.expectEqual(@as(u32, 2), paragraphCount("a\rb"));
}

test "needsNormalization: control bytes only" {
    try std.testing.expect(!needsNormalization("hello"));
    try std.testing.expect(!needsNormalization(""));
    try std.testing.expect(!needsNormalization("あいう"));
    try std.testing.expect(needsNormalization("a\nb"));
    try std.testing.expect(needsNormalization("a\tb"));
    try std.testing.expect(needsNormalization("a\x00b"));
    try std.testing.expect(needsNormalization("a\x7Fb"));
}

test "measureIntrinsicWidth: max paragraph, empty, trailing break" {
    try std.testing.expectEqual(@as(i32, 0), measureIntrinsicWidth(test_font, ""));
    try std.testing.expectEqual(@as(i32, 40), measureIntrinsicWidth(test_font, "Hello"));
    try std.testing.expectEqual(@as(i32, 8), measureIntrinsicWidth(test_font, "a\n"));
    try std.testing.expectEqual(@as(i32, 0), measureIntrinsicWidth(test_font, "\n"));
    try std.testing.expectEqual(@as(i32, 24), measureIntrinsicWidth(test_font, "ab\nabc"));
    try std.testing.expectEqual(@as(i32, 24), measureIntrinsicWidth(test_font, "a\tb"));
    try std.testing.expectEqual(@as(i32, 16), measureIntrinsicWidth(test_font, "a\x00b"));
}

test "wrapParagraphs: no-control non-wrap visible path allocates nothing" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const text = "Hello";
    const r = try wrapParagraphs(failing.allocator(), test_font, text, 1000, .{});
    try std.testing.expectEqual(@as(usize, 0), r.lines.len);
    try std.testing.expect(r.normalized == null);
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
}

test "wrapParagraphs: empty visible non-wrap allocates nothing" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const r = try wrapParagraphs(failing.allocator(), test_font, "", 100, .{});
    try std.testing.expectEqual(@as(usize, 0), r.lines.len);
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
}

test "wrapParagraphs: LF / CR LF / CR split paragraphs without wrap" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    {
        const lines = try wrapTest(a, "a\nb", 100, .{});
        try std.testing.expectEqual(@as(usize, 2), lines.len);
        try std.testing.expectEqualStrings("a", lines[0].text);
        try std.testing.expectEqualStrings("b", lines[1].text);
    }
    {
        const lines = try wrapTest(a, "a\r\nb", 100, .{});
        try std.testing.expectEqual(@as(usize, 2), lines.len);
        try std.testing.expectEqualStrings("a", lines[0].text);
        try std.testing.expectEqualStrings("b", lines[1].text);
    }
    {
        const lines = try wrapTest(a, "a\rb", 100, .{});
        try std.testing.expectEqual(@as(usize, 2), lines.len);
        try std.testing.expectEqualStrings("a", lines[0].text);
        try std.testing.expectEqualStrings("b", lines[1].text);
    }
    {
        const lines = try wrapTest(a, "a\n", 100, .{});
        try std.testing.expectEqual(@as(usize, 2), lines.len);
        try std.testing.expectEqualStrings("a", lines[0].text);
        try std.testing.expectEqualStrings("", lines[1].text);
    }
    {
        const lines = try wrapTest(a, "\n", 100, .{});
        try std.testing.expectEqual(@as(usize, 2), lines.len);
        try std.testing.expectEqualStrings("", lines[0].text);
        try std.testing.expectEqualStrings("", lines[1].text);
    }
    {
        const lines = try wrapTest(a, "a\n\nb", 100, .{});
        try std.testing.expectEqual(@as(usize, 3), lines.len);
        try std.testing.expectEqualStrings("a", lines[0].text);
        try std.testing.expectEqualStrings("", lines[1].text);
        try std.testing.expectEqualStrings("b", lines[2].text);
    }
}

test "wrapParagraphs: TAB becomes a space; other C0 and DEL are dropped" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const lines = try wrapTest(arena_inst.allocator(), "a\tb\x00c\x7Fd", 1000, .{});
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("a bcd", lines[0].text);
}

test "wrapParagraphs: mixed controls normalise then split" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const lines = try wrapTest(arena_inst.allocator(), "a\t\nb\x01c", 1000, .{});
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("a ", lines[0].text);
    try std.testing.expectEqualStrings("bc", lines[1].text);
}

test "wrapParagraphs: Latin word boundary drops the wrapping space" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const lines = try wrapTest(arena_inst.allocator(), "hello world", 40, .{ .wrap = true });
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("hello", lines[0].text);
    try std.testing.expectEqualStrings("world", lines[1].text);
}

test "wrapParagraphs: leading, trailing, and consecutive spaces" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    {
        const lines = try wrapTest(a, "  hi", 1000, .{ .wrap = true });
        try std.testing.expectEqual(@as(usize, 1), lines.len);
        try std.testing.expectEqualStrings("  hi", lines[0].text);
    }
    {
        const lines = try wrapTest(a, "hi  ", 1000, .{ .wrap = true });
        try std.testing.expectEqual(@as(usize, 1), lines.len);
        try std.testing.expectEqualStrings("hi  ", lines[0].text);
    }
    {
        const lines = try wrapTest(a, "hi  there", 40, .{ .wrap = true });
        try std.testing.expectEqual(@as(usize, 2), lines.len);
        try std.testing.expectEqualStrings("hi", lines[0].text);
        try std.testing.expectEqualStrings("there", lines[1].text);
    }
}

test "wrapParagraphs: CJK breaks at any codepoint" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const lines = try wrapTest(arena_inst.allocator(), "日本語", 16, .{ .wrap = true });
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("日本", lines[0].text);
    try std.testing.expectEqualStrings("語", lines[1].text);
}

test "wrapParagraphs: mixed Latin and CJK" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const lines = try wrapTest(arena_inst.allocator(), "hi日本語", 24, .{ .wrap = true });
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("hi日", lines[0].text);
    try std.testing.expectEqualStrings("本語", lines[1].text);
}

test "wrapParagraphs: long Latin word is force-split on a codepoint boundary" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const lines = try wrapTest(arena_inst.allocator(), "abcdefghij", 24, .{ .wrap = true });
    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expectEqualStrings("abc", lines[0].text);
    try std.testing.expectEqualStrings("def", lines[1].text);
    try std.testing.expectEqualStrings("ghi", lines[2].text);
    try std.testing.expectEqualStrings("j", lines[3].text);
}

test "longestPrefixThatFits: m=0,1,2 valid UTF-8" {
    try std.testing.expectEqual(@as(usize, 0), longestPrefixThatFits(test_font, "", 8));
    try std.testing.expectEqual(@as(usize, 1), longestPrefixThatFits(test_font, "a", 8));
    try std.testing.expectEqual(@as(usize, 0), longestPrefixThatFits(test_font, "a", 0));
    try std.testing.expectEqual(@as(usize, 1), longestPrefixThatFits(test_font, "ab", 8));
    try std.testing.expectEqual(@as(usize, 2), longestPrefixThatFits(test_font, "ab", 16));
    const jp = "あい";
    try std.testing.expectEqual(@as(usize, 3), longestPrefixThatFits(test_font, jp, 8));
    try std.testing.expectEqual(@as(usize, 6), longestPrefixThatFits(test_font, jp, 16));
}

test "longestPrefixThatFits: invalid UTF-8 uses byte boundaries" {
    const bad = [_]u8{ 'a', 0xFF, 'b' };
    try std.testing.expectEqual(@as(usize, 1), longestPrefixThatFits(test_font, &bad, 8));
    try std.testing.expectEqual(@as(usize, 2), longestPrefixThatFits(test_font, &bad, 16));
    try std.testing.expectEqual(@as(usize, 3), longestPrefixThatFits(test_font, &bad, 24));
}

test "wrapParagraphs: invalid UTF-8 force-split is byte-wise" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const bad = [_]u8{ 0xFF, 0xFE, 0xFD };
    const lines = try wrapTest(arena_inst.allocator(), &bad, 8, .{ .wrap = true });
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqual(@as(usize, 1), lines[0].text.len);
    try std.testing.expectEqual(@as(u8, 0xFF), lines[0].text[0]);
}

test "wrapParagraphs: max_lines + ellipsis on the last visible line" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const lines = try wrapTest(arena_inst.allocator(), "one two three four", 24, .{
        .wrap = true,
        .max_lines = 2,
        .overflow = .ellipsis,
    });
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expect(std.mem.endsWith(u8, lines[1].text, "..."));
}

test "wrapParagraphs: exactly max_lines with no leftover does not add ellipsis" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const lines = try wrapTest(arena_inst.allocator(), "one two", 24, .{
        .wrap = true,
        .max_lines = 2,
        .overflow = .ellipsis,
    });
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("one", lines[0].text);
    try std.testing.expectEqualStrings("two", lines[1].text);
}

test "wrapParagraphs: ellipsis + max_lines=0 resolves to one line" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const lines = try wrapTest(arena_inst.allocator(), "abcdefghij", 40, .{
        .wrap = true,
        .overflow = .ellipsis,
    });
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expect(std.mem.endsWith(u8, lines[0].text, "..."));
    try std.testing.expect(advanceWidth(test_font, lines[0].text) <= 40);
}

test "wrapParagraphs: visible + max_lines=0 is unlimited" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const lines = try wrapTest(arena_inst.allocator(), "one two three four five", 24, .{ .wrap = true });
    try std.testing.expect(lines.len > 1);
}

test "wrapParagraphs: clip + max_lines>0 hard-cuts without ellipsis" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const lines = try wrapTest(arena_inst.allocator(), "one two three four", 24, .{
        .wrap = true,
        .max_lines = 2,
        .overflow = .clip,
    });
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expect(!std.mem.endsWith(u8, lines[1].text, "..."));
}

test "wrapParagraphs: ellipsis narrower than the marker hard-clips; width 0 is empty" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    {
        const lines = try wrapTest(a, "abcdefgh", 16, .{ .overflow = .ellipsis });
        try std.testing.expectEqual(@as(usize, 1), lines.len);
        try std.testing.expect(!std.mem.endsWith(u8, lines[0].text, "..."));
        try std.testing.expect(advanceWidth(test_font, lines[0].text) <= 16);
    }
    {
        const lines = try wrapTest(a, "abcdefgh", 0, .{ .overflow = .ellipsis });
        try std.testing.expectEqual(@as(usize, 1), lines.len);
        try std.testing.expectEqualStrings("", lines[0].text);
    }
}

test "wrapParagraphs: width 1 and 2 with an 8px font hard-clip to empty under ellipsis" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    inline for (.{ 1, 2 }) |w| {
        const lines = try wrapTest(arena_inst.allocator(), "abc", w, .{ .overflow = .ellipsis });
        try std.testing.expectEqual(@as(usize, 1), lines.len);
        try std.testing.expectEqualStrings("", lines[0].text);
    }
}

test "heightForLineCount: one line is ink; many lines saturate" {
    try std.testing.expectEqual(@as(i32, 16), heightForLineCount(test_font, 1));
    try std.testing.expectEqual(@as(i32, 32), heightForLineCount(test_font, 2));
    const huge = struct {
        fn measure(_: *const anyopaque, _: []const u8) u32 {
            return 0;
        }
        fn drawTo(_: *const anyopaque, _: font_mod.RenderTarget, _: font_mod.Vec2, _: []const u8, _: font_mod.Color, _: font_mod.Rect, _: f32) void {}
        fn metrics(_: *const anyopaque) font_mod.Metrics {
            return .{ .line_height = std.math.maxInt(i32), .ascent = std.math.maxInt(i32), .descent = 0 };
        }
        const dummy: u8 = 0;
        const vt: Font.VTable = .{ .measure = measure, .drawTo = drawTo, .metrics = metrics };
        const font: Font = .{ .ptr = &dummy, .vtable = &vt };
    };
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), heightForLineCount(huge.font, 2));
}

test "measureIntrinsicWidth agrees with wrapParagraphs paragraphs" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const samples = [_][]const u8{ "Hello", "a\nb", "ab\nabc", "a\r\nb\tc", "\n", "a\n", "" };
    for (samples) |s| {
        const w = measureIntrinsicWidth(test_font, s);
        const r = try wrapParagraphs(a, test_font, s, std.math.maxInt(i32), .{});
        if (r.lines.len == 0) {
            try std.testing.expectEqual(w, advanceWidth(test_font, s));
            continue;
        }
        var max_line: i32 = 0;
        for (r.lines) |line| max_line = @max(max_line, advanceWidth(test_font, line.text));
        try std.testing.expectEqual(w, max_line);
    }
}

test "truncate: CR LF folds to one space" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const r = try truncate(arena_inst.allocator(), test_font, "a\r\nb", 1000);
    try std.testing.expectEqualStrings("a b", r.text);
    try std.testing.expect(!r.truncated);
}

test "truncate: fits returns a borrow when no normalisation ran" {
    const text = "short";
    const r = try truncate(std.testing.allocator, test_font, text, 1000);
    try std.testing.expectEqual(text.ptr, r.text.ptr);
    try std.testing.expect(!r.truncated);
}

test "truncate: long text is cut and may exceed max_w when only the marker fits" {
    const r = try truncate(std.testing.allocator, test_font, "abcdefghijklmnop", 40);
    defer std.testing.allocator.free(r.text);
    try std.testing.expect(r.truncated);
    try std.testing.expect(std.mem.endsWith(u8, r.text, "..."));
    try std.testing.expect(advanceWidth(test_font, r.text) <= 40);

    const tiny = try truncate(std.testing.allocator, test_font, "abcdefgh", 16);
    defer std.testing.allocator.free(tiny.text);
    try std.testing.expect(tiny.truncated);
    try std.testing.expectEqualStrings("...", tiny.text);
}

test "truncate: max_w<=0 returns the (normalised) source" {
    const r = try truncate(std.testing.allocator, test_font, "anything", 0);
    try std.testing.expectEqualStrings("anything", r.text);
    try std.testing.expect(!r.truncated);
}

test "wrapParagraphs: normalised lines do not borrow the input pointer" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const text = "a\nb";
    const r = try wrapParagraphs(arena_inst.allocator(), test_font, text, 100, .{});
    try std.testing.expect(r.normalized != null);
    try std.testing.expect(r.lines[0].text.ptr != text.ptr);
}

test "wrapParagraphs: general allocator can free the normalised buffer" {
    const text = "a\nb";
    const r = try wrapParagraphs(std.testing.allocator, test_font, text, 100, .{});
    defer std.testing.allocator.free(r.lines);
    defer if (r.normalized) |buf| std.testing.allocator.free(buf);
    try std.testing.expectEqual(@as(usize, 2), r.lines.len);
    try std.testing.expectEqualStrings("a", r.lines[0].text);
    try std.testing.expectEqualStrings("b", r.lines[1].text);
    const buf = r.normalized.?;
    const line_addr = @intFromPtr(r.lines[0].text.ptr);
    const buf_addr = @intFromPtr(buf.ptr);
    try std.testing.expect(line_addr >= buf_addr);
    try std.testing.expect(line_addr < buf_addr + buf.len);
}

test "binary search uses O(log m) measure calls on a long word" {
    var counter: u32 = 0;
    const font = countingFont(&counter);
    const word = "a" ** 64;
    _ = longestPrefixThatFits(font, word, 8 * 30);
    try std.testing.expect(counter <= 16);
    try std.testing.expect(counter >= 1);
}

test "resolvedMaxLines: ellipsis 0 becomes 1; visible 0 is unlimited" {
    try std.testing.expectEqual(@as(u32, 1), resolvedMaxLines(.{ .overflow = .ellipsis }));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), resolvedMaxLines(.{}));
    try std.testing.expectEqual(@as(u32, 3), resolvedMaxLines(.{ .max_lines = 3, .overflow = .ellipsis }));
}

test "canBreakBefore: space and CJK; hook exists for kinsoku" {
    try std.testing.expect(canBreakBefore(' ', 'a'));
    try std.testing.expect(canBreakBefore('日', '本'));
    try std.testing.expect(canBreakBefore('a', '日'));
    try std.testing.expect(!canBreakBefore('a', 'b'));
    try std.testing.expect(!canBreakBefore(null, 'a'));
}

test "maxLinesForI32Height: default font is far above 4096; huge line_height is 1" {
    try std.testing.expect(maxLinesForI32Height(test_font) > 4096);
    const huge = struct {
        fn measure(_: *const anyopaque, _: []const u8) u32 {
            return 8;
        }
        fn drawTo(_: *const anyopaque, _: font_mod.RenderTarget, _: font_mod.Vec2, _: []const u8, _: font_mod.Color, _: font_mod.Rect, _: f32) void {}
        fn metrics(_: *const anyopaque) font_mod.Metrics {
            return .{ .line_height = std.math.maxInt(i32), .ascent = 16, .descent = 0 };
        }
        const dummy: u8 = 0;
        const vt: Font.VTable = .{ .measure = measure, .drawTo = drawTo, .metrics = metrics };
        const font: Font = .{ .ptr = &dummy, .vtable = &vt };
    };
    try std.testing.expectEqual(@as(u32, 1), maxLinesForI32Height(huge.font));
}

test "wrapParagraphs: visible max_lines=0 is not silently capped at 4096" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const n: usize = 4097;
    const buf = try arena_inst.allocator().alloc(u8, n * 2 - 1);
    for (0..n) |i| {
        buf[i * 2] = 'a';
        if (i + 1 < n) buf[i * 2 + 1] = '\n';
    }
    const lines = try wrapTest(arena_inst.allocator(), buf, 100, .{});
    try std.testing.expectEqual(n, lines.len);
}

test "wrapParagraphs: i32 height cap cuts visible and marks ellipsis leftover" {
    const huge = struct {
        fn measure(_: *const anyopaque, text: []const u8) u32 {
            return 8 * @as(u32, @intCast(text.len));
        }
        fn drawTo(_: *const anyopaque, _: font_mod.RenderTarget, _: font_mod.Vec2, _: []const u8, _: font_mod.Color, _: font_mod.Rect, _: f32) void {}
        fn metrics(_: *const anyopaque) font_mod.Metrics {
            return .{ .line_height = std.math.maxInt(i32), .ascent = 16, .descent = 0 };
        }
        const dummy: u8 = 0;
        const vt: Font.VTable = .{ .measure = measure, .drawTo = drawTo, .metrics = metrics };
        const font: Font = .{ .ptr = &dummy, .vtable = &vt };
    };
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    {
        const r = try wrapParagraphs(a, huge.font, "a\nb\nc", 100, .{});
        try std.testing.expectEqual(@as(usize, 1), r.lines.len);
        try std.testing.expectEqualStrings("a", r.lines[0].text);
        try std.testing.expect(!std.mem.endsWith(u8, r.lines[0].text, "..."));
    }
    {
        const r = try wrapParagraphs(a, huge.font, "a\nb\nc", 100, .{ .overflow = .ellipsis, .max_lines = 10 });
        try std.testing.expectEqual(@as(usize, 1), r.lines.len);
        try std.testing.expect(std.mem.endsWith(u8, r.lines[0].text, "..."));
    }
}

test "wrapParagraphs: ellipsis width-guarantees every visible line" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const lines = try wrapTest(arena_inst.allocator(), "abcdefgh\nx", 40, .{
        .max_lines = 2,
        .overflow = .ellipsis,
    });
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expect(advanceWidth(test_font, lines[0].text) <= 40);
    try std.testing.expect(std.mem.endsWith(u8, lines[0].text, "..."));
    try std.testing.expectEqualStrings("x", lines[1].text);
    try std.testing.expect(advanceWidth(test_font, lines[1].text) <= 40);
}
