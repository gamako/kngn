//! An in-memory round-trip test of the OS text clipboard facade.
//! It goes through the `builtin.is_test` path, so it references no C symbol and no NSPasteboard.

const std = @import("std");
const platform = @import("platform");

test "clipboard: unset gives null" {
    platform.resetClipboardForTest();
    var buf: [64]u8 = undefined;
    try std.testing.expect(platform.getClipboardText(&buf) == null);
}

test "clipboard: an ASCII set → get round trip" {
    platform.resetClipboardForTest();
    platform.setClipboardText("hello");
    var buf: [64]u8 = undefined;
    const got = platform.getClipboardText(&buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello", got);
}

test "clipboard: a Japanese UTF-8 set → get round trip" {
    platform.resetClipboardForTest();
    platform.setClipboardText("こんにちは");
    var buf: [64]u8 = undefined;
    const got = platform.getClipboardText(&buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("こんにちは", got);
}

test "clipboard: an empty string is an empty slice, not null" {
    platform.resetClipboardForTest();
    platform.setClipboardText("");
    var buf: [64]u8 = undefined;
    const got = platform.getClipboardText(&buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

test "clipboard: a small buffer truncates on a UTF-8 boundary" {
    platform.resetClipboardForTest();
    platform.setClipboardText("あいう"); // 9 bytes
    var buf: [4]u8 = undefined; // 1 codepoint (3B) + 1 leftover → truncate to 3
    const got = platform.getClipboardText(&buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("あ", got);
    try std.testing.expect(std.unicode.utf8ValidateSlice(got));
}
