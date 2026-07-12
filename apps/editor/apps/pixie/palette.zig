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

// ── OKLCH / ランプ生成（TASK-89）────────────────────────────────
// Björn Ottosson OKLab 変換。純関数・f64・完全決定論。
// ホットパス宣言: action/digest イベント時のみ。フレーム毎には走らない。

pub const Oklch = struct { L: f64, C: f64, H: f64 };

/// ランプ / palette_set の色数上限（action と共有）。
pub const MAX_PALETTE_COLORS: usize = 64;
/// generateRamp / palette_ramp の n 上限。
pub const MAX_RAMP_N: u8 = 32;
/// generateRamp / palette_ramp の n 下限。
pub const MIN_RAMP_N: u8 = 2;

fn srgbChannelToLinear(c: f64) f64 {
    if (c <= 0.04045) return c / 12.92;
    return std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
}

fn linearToSrgbChannel(c: f64) f64 {
    if (c <= 0.0031308) return 12.92 * c;
    return 1.055 * std.math.pow(f64, c, 1.0 / 2.4) - 0.055;
}

fn cbrt(x: f64) f64 {
    return std.math.pow(f64, x, 1.0 / 3.0);
}

/// canonical BGRA 0xAARRGGBB → OKLCH（alpha 無視）。
pub fn srgbToOklch(color: u32) Oklch {
    const r = srgbChannelToLinear(@as(f64, @floatFromInt(color >> 16 & 0xFF)) / 255.0);
    const g = srgbChannelToLinear(@as(f64, @floatFromInt(color >> 8 & 0xFF)) / 255.0);
    const b = srgbChannelToLinear(@as(f64, @floatFromInt(color & 0xFF)) / 255.0);

    const l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
    const m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
    const s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;

    const l_ = cbrt(l);
    const m_ = cbrt(m);
    const s_ = cbrt(s);

    const L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
    const a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_;
    const bb = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_;

    const C = @sqrt(a * a + bb * bb);
    const H = std.math.atan2(bb, a); // radians
    return .{ .L = L, .C = C, .H = H };
}

/// OKLCH → canonical BGRA 0xAARRGGBB（不透明）。sRGB gamut 外はチャネル clamp。
pub fn oklchToSrgb(ok: Oklch) u32 {
    const a = ok.C * @cos(ok.H);
    const bb = ok.C * @sin(ok.H);
    const L = ok.L;

    const l_ = L + 0.3963377774 * a + 0.2158037573 * bb;
    const m_ = L - 0.1055613458 * a - 0.0638541728 * bb;
    const s_ = L - 0.0894841775 * a - 1.2914855480 * bb;

    const l = l_ * l_ * l_;
    const m = m_ * m_ * m_;
    const s = s_ * s_ * s_;

    var r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
    var g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
    var b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;

    r = linearToSrgbChannel(r);
    g = linearToSrgbChannel(g);
    b = linearToSrgbChannel(b);

    const ri: u8 = @intFromFloat(std.math.clamp(@round(r * 255.0), 0.0, 255.0));
    const gi: u8 = @intFromFloat(std.math.clamp(@round(g * 255.0), 0.0, 255.0));
    const bi: u8 = @intFromFloat(std.math.clamp(@round(b * 255.0), 0.0, 255.0));
    return 0xFF000000 | (@as(u32, ri) << 16) | (@as(u32, gi) << 8) | @as(u32, bi);
}

/// シード色から OKLCH 明暗ランプを生成（L を 0..1 等間隔、C/H は seed 維持、端 clamp）。
/// `n` は 2..=MAX_RAMP_N。`out.len >= n` 必須。完全決定論（同一入力→bit 同一）。
pub fn generateRamp(seed_color: u32, n: u8, out: []u32) void {
    std.debug.assert(n >= MIN_RAMP_N and n <= MAX_RAMP_N);
    std.debug.assert(out.len >= n);
    const seed = srgbToOklch(seed_color);
    const denom: f64 = @floatFromInt(n - 1);
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / denom;
        out[i] = oklchToSrgb(.{ .L = t, .C = seed.C, .H = seed.H });
    }
}

/// RGBA/BGRA 画素列から一意色を頻度降順で抽出（上限 `max_colors`、不透明化）。
/// 戻りは owned slice（caller free）。イベント時のみ。
pub fn extractColorsByFrequency(gpa: Allocator, pixels: []const u32, max_colors: usize) ![]u32 {
    var counts = std.AutoHashMap(u32, u32).init(gpa);
    defer counts.deinit();
    for (pixels) |p| {
        // 完全透明はスキップ（パレットノイズにしない）
        if (p & 0xFF000000 == 0) continue;
        const c = 0xFF000000 | (p & 0x00FFFFFF);
        const gop = try counts.getOrPut(c);
        if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
    }
    const Entry = struct { color: u32, count: u32 };
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(gpa);
    try entries.ensureTotalCapacity(gpa, counts.count());
    var it = counts.iterator();
    while (it.next()) |e| {
        entries.appendAssumeCapacity(.{ .color = e.key_ptr.*, .count = e.value_ptr.* });
    }
    // 頻度降順・同数は color 昇順（決定論）
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            if (a.count != b.count) return a.count > b.count;
            return a.color < b.color;
        }
    }.less);
    const n = @min(entries.items.len, max_colors);
    const out = try gpa.alloc(u32, n);
    for (0..n) |i| out[i] = entries.items[i].color;
    return out;
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

test "OKLCH: sRGB round-trip は ±1/255" {
    const samples = [_]u32{
        0xFF000000, 0xFFFFFFFF, 0xFFFF0000, 0xFF00FF00, 0xFF0000FF,
        0xFF336699, 0xFF808080, 0xFFDEEED6, 0xFF442434, 0xFFD04648,
    };
    for (samples) |c| {
        const back = oklchToSrgb(srgbToOklch(c));
        const r0: i32 = @intCast(c >> 16 & 0xFF);
        const g0: i32 = @intCast(c >> 8 & 0xFF);
        const b0: i32 = @intCast(c & 0xFF);
        const r1: i32 = @intCast(back >> 16 & 0xFF);
        const g1: i32 = @intCast(back >> 8 & 0xFF);
        const b1: i32 = @intCast(back & 0xFF);
        try std.testing.expect(@abs(r0 - r1) <= 1);
        try std.testing.expect(@abs(g0 - g1) <= 1);
        try std.testing.expect(@abs(b0 - b1) <= 1);
    }
}

test "generateRamp: 決定性（同入力→bit 同一）と端 clamp・n 長" {
    var a: [8]u32 = undefined;
    var b: [8]u32 = undefined;
    generateRamp(0xFF336699, 8, &a);
    generateRamp(0xFF336699, 8, &b);
    try std.testing.expectEqualSlices(u32, &a, &b);
    // 端: L=0 は黒寄り、L=1 は白寄り（C 維持でも gamut clamp で明るい/暗い）
    // 明度: 先頭 ≤ 末尾（R+G+B 合計の近似）
    const sum0 = (a[0] >> 16 & 0xFF) + (a[0] >> 8 & 0xFF) + (a[0] & 0xFF);
    const sum7 = (a[7] >> 16 & 0xFF) + (a[7] >> 8 & 0xFF) + (a[7] & 0xFF);
    try std.testing.expect(sum0 < sum7);
    // n=2 最小: L=0 と L=1 で 2 色が実際に異なる
    var two: [2]u32 = undefined;
    generateRamp(0xFFFF0000, 2, &two);
    try std.testing.expect(two[0] != two[1]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), two[0] & 0xFF000000);
    try std.testing.expectEqual(@as(u32, 0xFF000000), two[1] & 0xFF000000);
    const sum_lo = (two[0] >> 16 & 0xFF) + (two[0] >> 8 & 0xFF) + (two[0] & 0xFF);
    const sum_hi = (two[1] >> 16 & 0xFF) + (two[1] >> 8 & 0xFF) + (two[1] & 0xFF);
    try std.testing.expect(sum_lo < sum_hi);
}

test "generateRamp: 高彩度 seed でも clamp で不透明 sRGB に収まる" {
    var out: [4]u32 = undefined;
    generateRamp(0xFFFF00FF, 4, &out);
    for (out) |c| {
        try std.testing.expectEqual(@as(u32, 0xFF000000), c & 0xFF000000);
    }
}

test "extractColorsByFrequency: 頻度降順・上限・透明スキップ" {
    const gpa = std.testing.allocator;
    // 赤×3、緑×2、青×1、透明×2
    const px = [_]u32{
        0xFFFF0000, 0xFFFF0000, 0xFFFF0000,
        0xFF00FF00, 0xFF00FF00, 0xFF0000FF,
        0x00000000, 0x80FFFFFF, // 完全透明スキップ / 半透明は不透明化して数える
    };
    // 0x80FFFFFF → 0xFFFFFFFF としてカウント 1
    const got = try extractColorsByFrequency(gpa, &px, 64);
    defer gpa.free(got);
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), got[0]); // 3
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), got[1]); // 2
    // 青と白は count=1 ずつ → color 昇順で 0xFF0000FF < 0xFFFFFFFF
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), got[2]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), got[3]);

    const top2 = try extractColorsByFrequency(gpa, &px, 2);
    defer gpa.free(top2);
    try std.testing.expectEqual(@as(usize, 2), top2.len);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), top2[0]);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), top2[1]);
}
