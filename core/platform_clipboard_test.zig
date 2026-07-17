//! TASK-120: OS テキストクリップボード facade の in-memory round-trip テスト。
//! `builtin.is_test` 経路のため C symbol / NSPasteboard を参照しない。

const std = @import("std");
const platform = @import("platform");

test "clipboard: 未設定は null" {
    platform.resetClipboardForTest();
    var buf: [64]u8 = undefined;
    try std.testing.expect(platform.getClipboardText(&buf) == null);
}

test "clipboard: ASCII set → get round-trip" {
    platform.resetClipboardForTest();
    platform.setClipboardText("hello");
    var buf: [64]u8 = undefined;
    const got = platform.getClipboardText(&buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello", got);
}

test "clipboard: 日本語 UTF-8 set → get round-trip" {
    platform.resetClipboardForTest();
    platform.setClipboardText("こんにちは");
    var buf: [64]u8 = undefined;
    const got = platform.getClipboardText(&buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("こんにちは", got);
}

test "clipboard: 空文字列は empty slice（null ではない）" {
    platform.resetClipboardForTest();
    platform.setClipboardText("");
    var buf: [64]u8 = undefined;
    const got = platform.getClipboardText(&buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

test "clipboard: 小さい buffer は UTF-8 境界で切り詰める" {
    platform.resetClipboardForTest();
    platform.setClipboardText("あいう"); // 9 bytes
    var buf: [4]u8 = undefined; // 1 codepoint (3B) + 1 leftover → truncate to 3
    const got = platform.getClipboardText(&buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("あ", got);
    try std.testing.expect(std.unicode.utf8ValidateSlice(got));
}
