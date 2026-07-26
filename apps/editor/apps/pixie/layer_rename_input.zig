//! Layer-name inline-edit input state machine.
//!
//! Pure logic with no platform / GUI / paint dependency. Same convention as canvas_input.zig /
//! eyedropper_input.zig: isolate the input state machine in its own file and unit-test it from test-core without a display.
//! `App` in main.zig owns one instance; the Layers context-menu "Rename..." calls `begin`,
//! `char_input` calls `appendCodepoint`, BACKSPACE calls `backspace`, ENTER calls `commit`,
//! ESCAPE calls `cancel` (applying to Canvas and pushing Undo is the caller's = main.zig's job.
//! This module only updates the in-edit buffer).
//!
//! `max_len` matches `libs/paint/src/canvas.zig` `layer_name_max` (32).
//! Defined independently to avoid a circular import; main.zig holds a comptime equality assert.
//!
//! Hot-path note: event-only (once per rename start/char/commit/cancel).
//! Not a per-frame full-pixel loop or an RT path, so the performance rules (SIMD three-point set etc.) do not apply.

const std = @import("std");

/// Same value as `libs/paint/src/canvas.zig` `layer_name_max` (guaranteed by main.zig's comptime assert).
pub const max_len: usize = 32;

pub const LayerRenameInput = struct {
    active: bool = false,
    layer_idx: usize = 0,
    buf: [max_len]u8 = undefined,
    len: u8 = 0,

    /// Copy the layer's current name into the buffer and start editing.
    /// Safely truncates even when `current_name` exceeds `max_len` (never mid UTF-8 continuation byte;
    /// same defense as Layer.setName).
    pub fn begin(self: *LayerRenameInput, layer_idx: usize, current_name: []const u8) void {
        self.active = true;
        self.layer_idx = layer_idx;
        const n = safeUtf8TruncateLen(current_name, max_len);
        @memcpy(self.buf[0..n], current_name[0..n]);
        self.len = @intCast(n);
    }

    /// Append one committed character (`char_input` codepoint). No-op when not active.
    /// ASCII control chars (0x00-0x1F, 0x7F) are ignored (wire-framing guard so newlines etc. cannot break
    /// the digest/probe one-line contract; not a semantic filter). Capacity overflow is also ignored
    /// (fail-safe: do not propagate errors to the caller — at worst a keystroke is dropped, never a crash).
    pub fn appendCodepoint(self: *LayerRenameInput, codepoint: u32) void {
        if (!self.active) return;
        if (codepoint < 0x20 or codepoint == 0x7F) return;
        if (codepoint > std.math.maxInt(u21)) return;
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(codepoint), &enc) catch return; // Ignore invalid / surrogates etc.
        if (@as(usize, self.len) + n > max_len) return;
        @memcpy(self.buf[self.len..][0..n], enc[0..n]);
        self.len += @intCast(n);
    }

    /// Delete the previous codepoint (BACKSPACE). Walk back UTF-8 continuation bytes safely.
    pub fn backspace(self: *LayerRenameInput) void {
        if (!self.active or self.len == 0) return;
        var n: u8 = self.len - 1;
        while (n > 0 and (self.buf[n] & 0xC0) == 0x80) : (n -= 1) {}
        self.len = n;
    }

    /// Current in-edit buffer (uncommitted).
    pub fn text(self: *const LayerRenameInput) []const u8 {
        return self.buf[0..self.len];
    }

    /// Commit the edit and return the committed string (caller applies to Canvas and pushes Undo).
    pub fn commit(self: *LayerRenameInput) []const u8 {
        self.active = false;
        return self.text();
    }

    /// Cancel the edit (does not push Undo).
    pub fn cancel(self: *LayerRenameInput) void {
        self.active = false;
    }

    /// Full in-edit text (Cmd+C). null when not active.
    pub fn clipboardCopy(self: *const LayerRenameInput) ?[]const u8 {
        if (!self.active) return null;
        return self.text();
    }

    /// Return the full text and clear it (Cmd+X). Returned slice stays valid until the next write.
    pub fn clipboardCut(self: *LayerRenameInput) ?[]const u8 {
        if (!self.active) return null;
        const n = self.len;
        self.len = 0;
        return self.buf[0..n];
    }

    /// Replace the full text (Cmd+V). Control chars and newlines are stripped. Truncate at max_len on a UTF-8 boundary.
    pub fn clipboardPaste(self: *LayerRenameInput, incoming: []const u8) void {
        if (!self.active) return;
        self.len = 0;
        var pos: usize = 0;
        while (pos < incoming.len) {
            const first = incoming[pos];
            const seq_len = std.unicode.utf8ByteSequenceLength(first) catch {
                pos += 1;
                continue;
            };
            if (seq_len > 1) {
                if (pos + seq_len > incoming.len) break;
                _ = std.unicode.utf8Decode(incoming[pos .. pos + seq_len]) catch {
                    pos += 1;
                    continue;
                };
            }
            const piece = incoming[pos .. pos + seq_len];
            pos += seq_len;
            const cp: u32 = if (seq_len == 1) piece[0] else std.unicode.utf8Decode(piece) catch continue;
            if (cp < 0x20 or cp == 0x7F) continue;
            if (@as(usize, self.len) + seq_len > max_len) break;
            @memcpy(self.buf[self.len..][0..seq_len], piece);
            self.len += @intCast(seq_len);
        }
    }
};

/// Truncate text to at most max bytes without cutting mid UTF-8 continuation byte (0b10xxxxxx);
/// returns the truncated length (same shape as `libs/paint/src/canvas.zig` `safeUtf8TruncateLen`).
fn safeUtf8TruncateLen(text: []const u8, max: usize) usize {
    var n = @min(text.len, max);
    while (n > 0 and n < text.len and (text[n] & 0xC0) == 0x80) : (n -= 1) {}
    return n;
}

// ============================ tests ============================

const testing = std.testing;

test "begin: copies current name and becomes active" {
    var r: LayerRenameInput = .{};
    r.begin(3, "Background");
    try testing.expect(r.active);
    try testing.expectEqual(@as(usize, 3), r.layer_idx);
    try testing.expectEqualStrings("Background", r.text());
}

test "appendCodepoint: can append ASCII one character at a time" {
    var r: LayerRenameInput = .{};
    r.begin(0, "");
    r.appendCodepoint('S');
    r.appendCodepoint('k');
    r.appendCodepoint('y');
    try testing.expectEqualStrings("Sky", r.text());
}

test "appendCodepoint: can append multibyte (Japanese) via the char_input path" {
    var r: LayerRenameInput = .{};
    r.begin(0, "");
    // U+3042 (hiragana a)
    r.appendCodepoint(0x3042);
    r.appendCodepoint('日');
    try testing.expectEqualStrings("あ日", r.text());
}

test "appendCodepoint: ignored while not active" {
    var r: LayerRenameInput = .{};
    r.appendCodepoint('X');
    try testing.expectEqual(@as(u8, 0), r.len);
}

test "appendCodepoint: ASCII controls ignored (keep digest one-line contract)" {
    var r: LayerRenameInput = .{};
    r.begin(0, "");
    r.appendCodepoint('A');
    r.appendCodepoint('\n');
    r.appendCodepoint(0x7F); // DEL
    r.appendCodepoint('B');
    try testing.expectEqualStrings("AB", r.text());
}

test "appendCodepoint: over capacity ignored (no crash)" {
    var r: LayerRenameInput = .{};
    r.begin(0, "");
    var i: usize = 0;
    while (i < max_len) : (i += 1) r.appendCodepoint('A');
    try testing.expectEqual(@as(u8, @intCast(max_len)), r.len);
    r.appendCodepoint('B'); // Full → ignore
    try testing.expectEqual(@as(u8, @intCast(max_len)), r.len);
    try testing.expect(std.mem.allEqual(u8, r.text(), 'A'));

    // When a multibyte char would not fit, ignore the whole write (no partial write)
    var r2: LayerRenameInput = .{};
    r2.begin(0, "");
    i = 0;
    while (i < max_len - 1) : (i += 1) r2.appendCodepoint('A'); // 1 byte left
    r2.appendCodepoint(0x3042); // U+3042 needs 3 bytes → reject wholesale
    try testing.expectEqual(@as(u8, @intCast(max_len - 1)), r2.len);
    try testing.expect(std.unicode.utf8ValidateSlice(r2.text()));
}

test "backspace: deletes one codepoint (does not break multibyte)" {
    var r: LayerRenameInput = .{};
    r.begin(0, "");
    r.appendCodepoint('A');
    r.appendCodepoint(0x3042); // U+3042
    try testing.expectEqualStrings("Aあ", r.text());
    r.backspace();
    try testing.expectEqualStrings("A", r.text());
    try testing.expect(std.unicode.utf8ValidateSlice(r.text()));
    r.backspace();
    try testing.expectEqualStrings("", r.text());
    r.backspace(); // No-op even when empty (does not crash)
    try testing.expectEqualStrings("", r.text());
}

test "backspace: ignored while not active" {
    var r: LayerRenameInput = .{};
    r.backspace();
    try testing.expectEqual(@as(u8, 0), r.len);
}

test "commit: sets active false and returns the committed string" {
    var r: LayerRenameInput = .{};
    r.begin(1, "Old");
    r.backspace(); // "Old" → "Ol"
    r.appendCodepoint('t'); // "Ol" → "Olt"
    const committed = r.commit();
    try testing.expectEqualStrings("Olt", committed);
    try testing.expect(!r.active);
}

test "cancel: only sets active false (does not touch the buffer)" {
    var r: LayerRenameInput = .{};
    r.begin(0, "X");
    r.appendCodepoint('Y');
    r.cancel();
    try testing.expect(!r.active);
    try testing.expectEqualStrings("XY", r.text()); // Harmless unless the caller retains a reference
}

test "begin: over-max_len current name truncates without breaking UTF-8 boundaries" {
    var r: LayerRenameInput = .{};
    const long_name = "あ" ** 11; // 33 bytes (10 chars = 30B fit in 32; 11 would overflow)
    r.begin(0, long_name);
    try testing.expect(r.len <= max_len);
    try testing.expect(std.unicode.utf8ValidateSlice(r.text()));
    try testing.expectEqualStrings("あ" ** 10, r.text());
}

test "clipboardCopy/Cut/Paste and composition no-op contract" {
    var r: LayerRenameInput = .{};
    try testing.expect(r.clipboardCopy() == null);
    try testing.expect(r.clipboardCut() == null);
    r.clipboardPaste("nope");
    try testing.expectEqual(@as(u8, 0), r.len);

    r.begin(0, "Layer");
    try testing.expectEqualStrings("Layer", r.clipboardCopy().?);
    const cut = r.clipboardCut().?;
    try testing.expectEqualStrings("Layer", cut);
    try testing.expectEqualStrings("", r.text());

    r.clipboardPaste("新\n名");
    try testing.expectEqualStrings("新名", r.text());

    // Over-length truncates on a UTF-8 boundary
    r.clipboardPaste("あ" ** 20);
    try testing.expectEqual(@as(u8, 30), r.len);
    try testing.expect(std.unicode.utf8ValidateSlice(r.text()));
}
