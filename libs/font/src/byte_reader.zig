// big-endian 範囲チェック読み取り（sfnt / cmap 等が共有）。
// セキュリティ上重要な境界チェックをここ 1 箇所に集約する。範囲外は error.InvalidFont。
// off + size は overflow-safe に判定する（off > len か len - off < n）。

const std = @import("std");

pub const Reader = struct {
    data: []const u8,

    pub fn require(self: Reader, off: usize, n: usize) error{InvalidFont}!void {
        if (off > self.data.len or self.data.len - off < n) return error.InvalidFont;
    }
    pub fn u8At(self: Reader, off: usize) error{InvalidFont}!u8 {
        try self.require(off, 1);
        return self.data[off];
    }
    pub fn u16At(self: Reader, off: usize) error{InvalidFont}!u16 {
        try self.require(off, 2);
        return (@as(u16, self.data[off]) << 8) | self.data[off + 1];
    }
    pub fn i16At(self: Reader, off: usize) error{InvalidFont}!i16 {
        return @bitCast(try self.u16At(off));
    }
    pub fn u32At(self: Reader, off: usize) error{InvalidFont}!u32 {
        try self.require(off, 4);
        return (@as(u32, self.data[off]) << 24) |
            (@as(u32, self.data[off + 1]) << 16) |
            (@as(u32, self.data[off + 2]) << 8) |
            self.data[off + 3];
    }
};

test "Reader: BE 読み取りと範囲チェック" {
    const data = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A };
    const r = Reader{ .data = &data };
    try std.testing.expectEqual(@as(u8, 0x12), try r.u8At(0));
    try std.testing.expectEqual(@as(u16, 0x1234), try r.u16At(0));
    try std.testing.expectEqual(@as(u32, 0x12345678), try r.u32At(0));
    try std.testing.expectEqual(@as(i16, 0x789A), try r.i16At(3)); // bytes[3..5] = 0x78,0x9A
}

test "Reader: 範囲外は InvalidFont" {
    const data = [_]u8{ 0x00, 0x01 };
    const r = Reader{ .data = &data };
    try std.testing.expectError(error.InvalidFont, r.u32At(0));
    try std.testing.expectError(error.InvalidFont, r.u16At(1));
    try std.testing.expectError(error.InvalidFont, r.u8At(2));
    try std.testing.expectError(error.InvalidFont, r.require(1, 2));
}
