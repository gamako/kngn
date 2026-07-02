//! pixie 編集可能パレット + GIMP .gpl I/O（TASK-21.15）。
//! pure（platform / gui を import しない）。色は canonical BGRA 0xAARRGGBB 不透明。
//! 不変条件: colors.len >= 1（最後の1色は削除不可・decode は空を error にする）。

const std = @import("std");
const Allocator = std.mem.Allocator;

/// DawnBringer 16（0xRRGGBB）
pub const db16 = [16]u32{
    0x000000, 0x442434, 0x30346D, 0x4E4A4E,
    0x854C30, 0x346524, 0xD04648, 0x757161,
    0x597DCE, 0xD27D2C, 0x8595A1, 0x6DAA2C,
    0xD2AA99, 0x6DC2CA, 0xDAD45E, 0xDEEED6,
};

/// 0xRRGGBB → canonical BGRA 0xAARRGGBB（不透明）。BGRA では低24bit が 0xRRGGBB に一致する。
pub fn rgbToCanvas(rgb: u32) u32 {
    const r = rgb >> 16 & 0xFF;
    const g = rgb >> 8 & 0xFF;
    const b = rgb & 0xFF;
    return 0xFF000000 | (r << 16) | (g << 8) | b;
}

pub const Palette = struct {
    colors: std.ArrayList(u32) = .empty, // canonical BGRA 0xAARRGGBB 不透明
    selected: usize = 0,

    pub fn initDb16(gpa: Allocator) !Palette {
        var colors: std.ArrayList(u32) = .empty;
        errdefer colors.deinit(gpa);
        try colors.ensureTotalCapacity(gpa, db16.len); // 固定 16 色（TASK-59）
        for (db16) |rgb| colors.appendAssumeCapacity(rgbToCanvas(rgb));
        return .{ .colors = colors, .selected = 0 };
    }

    pub fn deinit(self: *Palette, gpa: Allocator) void {
        self.colors.deinit(gpa);
    }

    /// 現在選択中の色。colors.len>=1 不変条件のもと安全。
    pub fn current(self: *const Palette) u32 {
        return self.colors.items[self.selected];
    }

    pub fn select(self: *Palette, i: usize) void {
        if (self.colors.items.len == 0) return;
        self.selected = @min(i, self.colors.items.len - 1);
    }

    pub fn addColor(self: *Palette, gpa: Allocator, c: u32) !void {
        try self.colors.append(gpa, c);
        self.selected = self.colors.items.len - 1;
    }

    /// 最後の1色は削除不可（colors.len>=1 を保つ）。削除後は selected を再クランプ。
    pub fn removeSelected(self: *Palette) void {
        if (self.colors.items.len <= 1) return;
        _ = self.colors.orderedRemove(self.selected);
        if (self.selected >= self.colors.items.len) self.selected = self.colors.items.len - 1;
    }

    pub fn setSelectedColor(self: *Palette, c: u32) void {
        self.colors.items[self.selected] = c;
    }
};

// ── GIMP .gpl ──────────────────────────────────────────
pub const GplError = error{ InvalidGpl, EmptyPalette };

/// .gpl テキストを生成（owned slice、呼び出し側が free）。α は出力しない。
pub fn encodeGpl(colors: []const u32, name: []const u8, gpa: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    // 上限概算 = ヘッダ + 色行（"255 255 255\tUntitled\n" ≒ 21B < 32B）で事前確保（TASK-59）
    try buf.ensureTotalCapacity(gpa, 32 + name.len + colors.len * 32);
    try buf.appendSlice(gpa, "GIMP Palette\nName: ");
    try buf.appendSlice(gpa, name);
    try buf.appendSlice(gpa, "\nColumns: 0\n#\n");
    for (colors) |c| {
        // canonical BGRA(0xAARRGGBB) から明示抽出。
        const r: u8 = @truncate(c >> 16);
        const g: u8 = @truncate(c >> 8);
        const b: u8 = @truncate(c);
        var line: [48]u8 = undefined;
        const s = try std.fmt.bufPrint(&line, "{d} {d} {d}\tUntitled\n", .{ r, g, b });
        try buf.appendSlice(gpa, s);
    }
    return try buf.toOwnedSlice(gpa);
}

/// .gpl テキストを解析して colors（canonical BGRA 0xAARRGGBB）を返す（owned）。
/// ヘッダ欠落は InvalidGpl、有効色 0 件は EmptyPalette。範囲外/トークン不足行はスキップ（clamp しない）。
pub fn decodeGpl(gpa: Allocator, bytes: []const u8) !std.ArrayList(u32) {
    var colors: std.ArrayList(u32) = .empty;
    errdefer colors.deinit(gpa);
    // 上限 = 行数（色行以外はスキップされる）。事前確保してループ内の再確保を排除（TASK-59）
    try colors.ensureTotalCapacity(gpa, std.mem.count(u8, bytes, "\n") + 1);

    var header_ok = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (!header_ok) {
            // 先頭の非空行は "GIMP Palette" でなければ失敗
            if (std.mem.startsWith(u8, line, "GIMP Palette")) {
                header_ok = true;
                continue;
            }
            return GplError.InvalidGpl;
        }
        if (line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "Name:")) continue;
        if (std.mem.startsWith(u8, line, "Columns:")) continue;
        // 色行: R G B [name...]
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const rs = it.next() orelse continue;
        const gs = it.next() orelse continue;
        const bs = it.next() orelse continue;
        const r = std.fmt.parseInt(u8, rs, 10) catch continue; // 範囲外/負/非数字 → スキップ
        const g = std.fmt.parseInt(u8, gs, 10) catch continue;
        const b = std.fmt.parseInt(u8, bs, 10) catch continue;
        const c = 0xFF000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
        colors.appendAssumeCapacity(c);
    }
    if (!header_ok) return GplError.InvalidGpl; // 空 / 全行空白
    if (colors.items.len == 0) return GplError.EmptyPalette;
    return colors;
}

// ============================================================
// Tests
// ============================================================

test "Palette: initDb16 / select / add / removeSelected / setSelectedColor" {
    const gpa = std.testing.allocator;
    var p = try Palette.initDb16(gpa);
    defer p.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 16), p.colors.items.len);
    try std.testing.expectEqual(rgbToCanvas(0x000000), p.current());

    p.select(100); // クランプ
    try std.testing.expectEqual(@as(usize, 15), p.selected);

    try p.addColor(gpa, 0xFF112233);
    try std.testing.expectEqual(@as(usize, 17), p.colors.items.len);
    try std.testing.expectEqual(@as(usize, 16), p.selected); // 追加色を選択
    try std.testing.expectEqual(@as(u32, 0xFF112233), p.current());

    p.setSelectedColor(0xFF445566);
    try std.testing.expectEqual(@as(u32, 0xFF445566), p.current());

    p.removeSelected(); // 17→16、selected 再クランプ
    try std.testing.expectEqual(@as(usize, 16), p.colors.items.len);
    try std.testing.expectEqual(@as(usize, 15), p.selected);
}

test "Palette: 最後の1色は削除不可" {
    const gpa = std.testing.allocator;
    var p: Palette = .{};
    defer p.deinit(gpa);
    try p.addColor(gpa, 0xFF000000);
    try std.testing.expectEqual(@as(usize, 1), p.colors.items.len);
    p.removeSelected(); // len==1 → no-op
    try std.testing.expectEqual(@as(usize, 1), p.colors.items.len);
}

test "gpl: encode→decode round-trip" {
    const gpa = std.testing.allocator;
    const colors = [_]u32{ 0xFF112233, 0xFFAABBCC, 0xFF000000, 0xFFFFFFFF };
    const bytes = try encodeGpl(&colors, "test", gpa);
    defer gpa.free(bytes);

    var decoded = try decodeGpl(gpa, bytes);
    defer decoded.deinit(gpa);
    try std.testing.expectEqualSlices(u32, &colors, decoded.items);
}

test "gpl: ヘッダ/コメント/空行/名前行を許容、不正行はスキップ" {
    const gpa = std.testing.allocator;
    const text =
        "GIMP Palette\n" ++
        "Name: My Palette\n" ++
        "Columns: 4\n" ++
        "#\n" ++
        "\n" ++
        "255 0 0\tRed\n" ++
        "0 256 0 Bad\n" ++ // G=256 範囲外 → スキップ
        "1 2\n" ++ // トークン不足 → スキップ
        "10 20 30\n" ++
        "  40  50  60  named with spaces\n";
    var decoded = try decodeGpl(gpa, text);
    defer decoded.deinit(gpa);
    // 有効: (255,0,0), (10,20,30), (40,50,60)
    try std.testing.expectEqual(@as(usize, 3), decoded.items.len);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), decoded.items[0]); // R=255 → 0xAARRGGBB=0xFFFF0000
    try std.testing.expectEqual(@as(u32, 0xFF0A141E), decoded.items[1]); // (10,20,30)
}

test "gpl: ヘッダ欠落は InvalidGpl" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(GplError.InvalidGpl, decodeGpl(gpa, "255 0 0\n128 128 128\n"));
}

test "gpl: 有効ヘッダだが色 0 件は EmptyPalette" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(GplError.EmptyPalette, decodeGpl(gpa, "GIMP Palette\nName: x\n#\n"));
    // 全色行が不正でも EmptyPalette
    try std.testing.expectError(GplError.EmptyPalette, decodeGpl(gpa, "GIMP Palette\n999 0 0\nfoo bar\n"));
}
