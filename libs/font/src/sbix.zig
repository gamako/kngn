// sbix テーブルパーサ。sfnt の 'sbix' テーブル（埋め込みビットマップ。カラー絵文字フォントで
// PNG を格納するのに使われる）を安全にパースする。
//
// strike（ppem 単位の解像度バリエーション）ごとの glyph record（graphicType + origin offset +
// 埋め込みバイト列）を読み、GID と目標 px から使う strike / bitmap を選択できるようにする。
// PNG のデコード・(GID,px) キャッシュ・cmap 絵文字解決・FontFace への結線は行わない
// （TASK-26.3 のスコープ）。
//
// ホットパス宣言: **初期化時のみ**（フォント読込時に parse）+ **イベント時のみ**（26.3 の
// キャッシュミス時に glyph 解決）。フレーム毎（全画素）/ RT（毎サンプル）経路では走らない
// → 性能規約（SIMD 3点セット・cache_line 分離・bench 前後比較）の適用対象外。
//
// 設計（sfnt.zig / glyf.zig / cmap.zig と同型）:
//   - 読み取りは byte_reader.zig の Reader（BE + overflow-safe 境界チェック）経由。範囲外は
//     error.InvalidFont。生バイトは借用保持（コピーしない）。table-local slice 上で読む。
//   - parse 時に「安い構造検証」（ヘッダ + 各 strike ヘッダの範囲）を eager に行い、
//     glyph record の検証はアクセス時（glyphData）に lazy に行う（glyf.zig の glyphData と同型）。
//   - アロケーション無し（Sbix は slice + スカラーのみ保持。テスト builder を除く）。
//
// バイナリレイアウト（OpenType 'sbix' 仕様）:
//   - ヘッダ: version(u16, ==1) / flags(u16) / numStrikes(u32) /
//     strikeOffsets[numStrikes](u32, sbix テーブル先頭基準)。
//   - strike: ppem(u16) / ppi(u16) / glyphDataOffsets[numGlyphs+1](u32, strike 先頭基準)。
//   - glyph record: originOffsetX(i16) / originOffsetY(i16) / graphicType(4byte tag) / data。
//     レコード長 = offsets[gid+1] − offsets[gid]。0 は「この strike に bitmap 無し」、
//     1..7 は不正、8 以上でヘッダ(8byte) + data。
//
// graphicType の扱い:
//   - 'png ': bytes をそのまま返す（decode しない）。data 空（レコード長 8）は許容し空 bytes を返す。
//   - 'dupe': data 長 == 2（参照先 GID の u16）を厳格要求。同一 strike 内の別 GID を再解決する。
//     解決結果は**参照先レコードの originOffset を採用**する（OpenType 仕様に明文なし。
//     FreeType 実装準拠。この実装の仕様として固定）。
//   - 'jpg ' / 'tiff' / 未知 tag: 非対応 → 「bitmap 無し」(null) と同じ扱いにする
//     （該当 strike をスキップして他 strike / outline へ穏当に劣化させるため）。
//
// エラー方針: 構造破壊（offset 逆転・範囲外・レコード長 1..7・dupe 違反・範囲外 GID 引数）は
// error.InvalidFont。findGlyph は途中 strike の構造エラーを握りつぶさず伝播する。

const std = @import("std");
const Reader = @import("byte_reader.zig").Reader;
const sfnt = @import("sfnt.zig");

pub const Error = error{InvalidFont};

/// dupe 追従の hard cap（循環・深すぎ防止。spec 上 dupe→dupe は想定外だが防御的に追従）。
const max_dupe_depth: u32 = 4;

/// strike ヘッダの必要長（strike 先頭からの相対バイト数）: ppem(2)+ppi(2)+glyphDataOffsets[n+1](4*(n+1))。
fn strikeHeaderLen(num_glyphs: u16) usize {
    return 4 + (@as(usize, num_glyphs) + 1) * 4;
}

pub const Sbix = struct {
    /// sbix table-local slice（借用）。
    data: []const u8,
    num_glyphs: u16,
    version: u16,
    /// bit1(draw outlines) 等は 26.3 が参照できるよう保持のみ（検証しない）。
    flags: u16,
    num_strikes: u32,

    pub const Strike = struct { index: u32, ppem: u16, ppi: u16 };

    pub const GlyphData = struct {
        origin_offset_x: i16,
        origin_offset_y: i16,
        /// dupe 解決後なので常に 'png '（AC#2 の文言に合わせ保持）。
        graphic_type: [4]u8,
        /// PNG 生バイト（借用）。decode は 26.3。
        bytes: []const u8,
    };

    pub const FoundGlyph = struct { strike: Strike, glyph: GlyphData };

    /// sbix テーブルを parse する（sfnt 非依存。単体テスト可）。
    /// 検証: version==1 / numStrikes>=1 / strikeOffsets 配列が table に収まる（overflow-safe）/
    /// 各 strikeOffset がヘッダ・offsets 配列の内側を指さない（下限）/ 各 strike ヘッダ
    /// （ppem+ppi+glyphDataOffsets[numGlyphs+1]）が table に収まる。glyph record 自体の検証は lazy。
    pub fn parse(table: []const u8, num_glyphs: u16) Error!Sbix {
        const r = Reader{ .data = table };
        try r.require(0, 8);
        const version = try r.u16At(0);
        if (version != 1) return error.InvalidFont;
        const flags = try r.u16At(2);
        const num_strikes = try r.u32At(4);
        if (num_strikes == 0) return error.InvalidFont;

        const offsets_len = std.math.mul(usize, @as(usize, num_strikes), 4) catch return error.InvalidFont;
        try r.require(8, offsets_len);
        const header_end = 8 + offsets_len; // require 済みなので overflow しない

        const strike_header_len = strikeHeaderLen(num_glyphs);

        var i: u32 = 0;
        while (i < num_strikes) : (i += 1) {
            const off: usize = try r.u32At(8 + @as(usize, i) * 4);
            // 下限: ヘッダ + strikeOffsets 配列の内側を指す crafted table を弾く
            // （sfnt.zig の TTC `base < 12 + ot_len` 検査と同型）。
            if (off < header_end) return error.InvalidFont;
            // 上限: strike ヘッダ全体（ppem/ppi/glyphDataOffsets 配列）が table に収まる。
            try r.require(off, strike_header_len);
        }

        return .{
            .data = table,
            .num_glyphs = num_glyphs,
            .version = version,
            .flags = flags,
            .num_strikes = num_strikes,
        };
    }

    /// sfnt から 'sbix' テーブルを見つけて parse する。テーブル不在は null。
    pub fn init(font: *const sfnt.SfntFile) Error!?Sbix {
        const table = (font.tableSlice("sbix") catch return error.InvalidFont) orelse return null;
        return try parse(table, font.num_glyphs);
    }

    fn strikeOffsetAt(self: *const Sbix, index: u32) Error!usize {
        if (index >= self.num_strikes) return error.InvalidFont;
        const r = Reader{ .data = self.data };
        return try r.u32At(8 + @as(usize, index) * 4);
    }

    /// index の strike（ppem/ppi）を返す。AC#4 の列挙用に全 strike を走査できる。
    pub fn strikeAt(self: *const Sbix, index: u32) Error!Strike {
        const off = try self.strikeOffsetAt(index);
        const r = Reader{ .data = self.data };
        const ppem = try r.u16At(off);
        const ppi = try r.u16At(off + 2);
        return .{ .index = index, .ppem = ppem, .ppi = ppi };
    }

    /// strike 選択の固定規則（AC#5）: 目標 px 以上の最小 ppem を選ぶ。無ければ最大 ppem。
    /// ppi は無視。同 ppem 複数は strike 配列順で先勝ち。
    pub fn selectStrike(self: *const Sbix, target_px: u32) Error!Strike {
        var best_above: ?Strike = null; // 目標以上で ppem 最小
        var best_max: ?Strike = null; // 全体で ppem 最大（fallback）
        var i: u32 = 0;
        while (i < self.num_strikes) : (i += 1) {
            const s = try self.strikeAt(i);
            if (best_max == null or s.ppem > best_max.?.ppem) best_max = s;
            if (s.ppem >= target_px) {
                if (best_above == null or s.ppem < best_above.?.ppem) best_above = s;
            }
        }
        // num_strikes >= 1（parse で保証）なので best_max は必ず設定される。
        return best_above orelse best_max.?;
    }

    /// strike_index・gid の glyph data を返す（dupe 解決済み）。bitmap 無し（0 レコード・
    /// jpg/tiff/未知 tag）は null。構造破壊は InvalidFont。
    pub fn glyphData(self: *const Sbix, strike_index: u32, gid: u16) Error!?GlyphData {
        if (gid >= self.num_glyphs) return error.InvalidFont;
        const strike_off = try self.strikeOffsetAt(strike_index);
        return self.resolveGlyphData(strike_off, gid, 0);
    }

    fn resolveGlyphData(self: *const Sbix, strike_off: usize, gid: u16, depth: u32) Error!?GlyphData {
        if (depth > max_dupe_depth) return error.InvalidFont;
        if (gid >= self.num_glyphs) return error.InvalidFont; // dupe 参照先の再検証

        const r = Reader{ .data = self.data };
        const rec_off = strike_off + 4 + @as(usize, gid) * 4;
        const off0: usize = try r.u32At(rec_off);
        const off1: usize = try r.u32At(rec_off + 4);
        if (off0 > off1) return error.InvalidFont;
        if (off0 == off1) return null; // bitmap 無し（下限違反でも 1 byte も読まないので安全に null）

        const strike_slice_len = self.data.len - strike_off; // strike_off は parse で <= data.len 検証済み
        const header_len = strikeHeaderLen(self.num_glyphs);
        // 下限: ヘッダ（ppem/ppi/glyphDataOffsets 配列）の内側を指す非空レコードを弾く。
        // 上限: strike の残り領域を超える範囲を弾く。
        if (off0 < header_len or off1 > strike_slice_len) return error.InvalidFont;

        const record = self.data[strike_off + off0 .. strike_off + off1];
        if (record.len < 8) return error.InvalidFont; // 1..7 は不正（8 以上でヘッダが揃う）

        const rr = Reader{ .data = record };
        const ox = try rr.i16At(0);
        const oy = try rr.i16At(2);
        var gtype: [4]u8 = undefined;
        @memcpy(&gtype, record[4..8]);

        if (std.mem.eql(u8, &gtype, "png ")) {
            return GlyphData{
                .origin_offset_x = ox,
                .origin_offset_y = oy,
                .graphic_type = gtype,
                .bytes = record[8..],
            };
        } else if (std.mem.eql(u8, &gtype, "dupe")) {
            if (record.len != 10) return error.InvalidFont; // data 長は厳格に 2byte
            const ref_gid = try rr.u16At(8);
            if (ref_gid >= self.num_glyphs) return error.InvalidFont;
            return self.resolveGlyphData(strike_off, ref_gid, depth + 1);
        } else {
            // jpg / tiff / 未知 tag: 非対応 → 「bitmap 無し」と同じ扱い。
            return null;
        }
    }

    const Candidate = struct { ppem: u16, index: u32 };

    fn beforeAsc(a: Candidate, b: Candidate) bool {
        return a.ppem < b.ppem or (a.ppem == b.ppem and a.index < b.index);
    }
    fn beforeDesc(a: Candidate, b: Candidate) bool {
        return a.ppem > b.ppem or (a.ppem == b.ppem and a.index < b.index);
    }

    /// GID と目標 px から、strike をまたいで bitmap を解決する（AC#4）。
    /// 選好順は selectStrike と同じ規則を残り集合へ再適用したもの:
    /// 目標以上を ppem 昇順 → 目標未満を ppem 降順（同 ppem は配列順で先勝ち）。
    /// 途中 strike の構造エラー（InvalidFont）は握りつぶさず伝播する。全 strike に無ければ null。
    pub fn findGlyph(self: *const Sbix, target_px: u32, gid: u16) Error!?FoundGlyph {
        if (gid >= self.num_glyphs) return error.InvalidFont;

        // Phase A: ppem >= target_px を昇順（同 ppem は index 昇順）で試す。
        var last: ?Candidate = null;
        while (true) {
            var best: ?Candidate = null;
            var i: u32 = 0;
            while (i < self.num_strikes) : (i += 1) {
                const s = try self.strikeAt(i);
                if (s.ppem < target_px) continue;
                const c = Candidate{ .ppem = s.ppem, .index = i };
                if (last) |l| {
                    if (!beforeAsc(l, c)) continue;
                }
                if (best == null or beforeAsc(c, best.?)) best = c;
            }
            const cand = best orelse break;
            last = cand;
            if (try self.glyphData(cand.index, gid)) |g| {
                return .{ .strike = try self.strikeAt(cand.index), .glyph = g };
            }
        }

        // Phase B: ppem < target_px を降順（同 ppem は index 昇順）で試す。
        last = null;
        while (true) {
            var best: ?Candidate = null;
            var i: u32 = 0;
            while (i < self.num_strikes) : (i += 1) {
                const s = try self.strikeAt(i);
                if (s.ppem >= target_px) continue;
                const c = Candidate{ .ppem = s.ppem, .index = i };
                if (last) |l| {
                    if (!beforeDesc(l, c)) continue;
                }
                if (best == null or beforeDesc(c, best.?)) best = c;
            }
            const cand = best orelse break;
            last = cand;
            if (try self.glyphData(cand.index, gid)) |g| {
                return .{ .strike = try self.strikeAt(cand.index), .glyph = g };
            }
        }

        return null;
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn putU16(buf: []u8, off: usize, v: u16) void {
    buf[off] = @intCast(v >> 8);
    buf[off + 1] = @truncate(v);
}
fn putU32(buf: []u8, off: usize, v: u32) void {
    buf[off] = @truncate(v >> 24);
    buf[off + 1] = @truncate(v >> 16);
    buf[off + 2] = @truncate(v >> 8);
    buf[off + 3] = @truncate(v);
}
fn appendU16(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u16) !void {
    try list.append(alloc, @intCast(v >> 8));
    try list.append(alloc, @truncate(v));
}
fn appendI16(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: i16) !void {
    try appendU16(list, alloc, @bitCast(v));
}
fn appendU32(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u32) !void {
    try list.append(alloc, @truncate(v >> 24));
    try list.append(alloc, @truncate(v >> 16));
    try list.append(alloc, @truncate(v >> 8));
    try list.append(alloc, @truncate(v));
}

/// 合成 sbix テストデータ用の glyph record 記述。builder が offset 配列を自動計算する。
/// **テスト専用**（TASK-26.3 で outline_font.zig の統合テストが合成 sbix バイト列生成に
/// 再利用するため pub 昇格。本番コードから使わない）。
pub const RecordSpec = union(enum) {
    /// bitmap 無し（off0==off1）。
    empty,
    png: Png,
    dupe: Dupe,
    /// jpg/tiff/未知 tag や不正な data 長（dupe 系の負テスト）を直接記述する低レベル手段。
    raw: Raw,

    const Png = struct { x: i16 = 0, y: i16 = 0, bytes: []const u8 = &.{} };
    const Dupe = struct { x: i16 = 0, y: i16 = 0, gid: u16 };
    const Raw = struct { x: i16 = 0, y: i16 = 0, kind: [4]u8, data: []const u8 = &.{} };
};

/// **テスト専用**（RecordSpec と同じく TASK-26.3 で pub 昇格）。
pub const StrikeSpec = struct {
    ppem: u16,
    ppi: u16 = 72,
    /// 長さは num_glyphs と一致必須（各 gid の record を順に記述）。
    records: []const RecordSpec,
};

/// strikes から正しい sbix バイト列を組む（呼び出し側が free）。
/// **テスト専用**（RecordSpec と同じく TASK-26.3 で pub 昇格。本番コードから使わない）。
/// 単一 strike フィクスチャ（num_strikes==1）を使うテストは、strikeOffsets[0] が常に
/// 絶対位置 8、strike 本体が常に絶対位置 12、glyphDataOffsets 配列が常に絶対位置 16 から
/// 始まる（ヘッダ長が固定のため）ことを利用して、正常系バイト列を狙って上書きし境界テストを組む。
pub fn buildSbix(alloc: std.mem.Allocator, num_glyphs: u16, strikes: []const StrikeSpec) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try appendU16(&out, alloc, 1); // version
    try appendU16(&out, alloc, 0); // flags
    try appendU32(&out, alloc, @intCast(strikes.len)); // numStrikes

    const offsets_pos = out.items.len;
    for (0..strikes.len) |_| try appendU32(&out, alloc, 0); // strikeOffsets placeholder

    for (strikes, 0..) |sp, i| {
        std.debug.assert(sp.records.len == num_glyphs);
        const strike_abs = out.items.len;
        putU32(out.items, offsets_pos + i * 4, @intCast(strike_abs));

        try appendU16(&out, alloc, sp.ppem);
        try appendU16(&out, alloc, sp.ppi);
        const goff_pos = out.items.len;
        for (0..@as(usize, num_glyphs) + 1) |_| try appendU32(&out, alloc, 0); // glyphDataOffsets placeholder

        var g: usize = 0;
        while (g <= num_glyphs) : (g += 1) {
            const rel: u32 = @intCast(out.items.len - strike_abs);
            putU32(out.items, goff_pos + g * 4, rel);
            if (g == num_glyphs) break;
            switch (sp.records[g]) {
                .empty => {},
                .png => |p| {
                    try appendI16(&out, alloc, p.x);
                    try appendI16(&out, alloc, p.y);
                    try out.appendSlice(alloc, "png ");
                    try out.appendSlice(alloc, p.bytes);
                },
                .dupe => |d| {
                    try appendI16(&out, alloc, d.x);
                    try appendI16(&out, alloc, d.y);
                    try out.appendSlice(alloc, "dupe");
                    try appendU16(&out, alloc, d.gid);
                },
                .raw => |rw| {
                    try appendI16(&out, alloc, rw.x);
                    try appendI16(&out, alloc, rw.y);
                    try out.appendSlice(alloc, &rw.kind);
                    try out.appendSlice(alloc, rw.data);
                },
            }
        }
    }
    return out.toOwnedSlice(alloc);
}

// ── AC#1: 正常系 + 切り詰め ─────────────────────────────────────────

test "sbix: 正常系（2 strike・複数 record）で version/flags/numStrikes/ppem/ppi/offsets を読める" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 2, &.{
        .{ .ppem = 20, .ppi = 72, .records = &.{ .empty, .{ .png = .{ .bytes = &.{ 1, 2, 3 } } } } },
        .{ .ppem = 40, .ppi = 144, .records = &.{ .{ .png = .{ .bytes = &.{4} } }, .empty } },
    });
    defer a.free(bytes);

    const s = try Sbix.parse(bytes, 2);
    try testing.expectEqual(@as(u16, 1), s.version);
    try testing.expectEqual(@as(u16, 0), s.flags);
    try testing.expectEqual(@as(u32, 2), s.num_strikes);

    const st0 = try s.strikeAt(0);
    try testing.expectEqual(@as(u16, 20), st0.ppem);
    try testing.expectEqual(@as(u16, 72), st0.ppi);
    const st1 = try s.strikeAt(1);
    try testing.expectEqual(@as(u16, 40), st1.ppem);
    try testing.expectEqual(@as(u16, 144), st1.ppi);

    // strike0: gid0=empty, gid1=png
    try testing.expect((try s.glyphData(0, 0)) == null);
    const g01 = (try s.glyphData(0, 1)).?;
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, g01.bytes);
    // strike1: gid0=png, gid1=empty
    const g10 = (try s.glyphData(1, 0)).?;
    try testing.expectEqualSlices(u8, &.{4}, g10.bytes);
    try testing.expect((try s.glyphData(1, 1)) == null);
}

test "sbix: ヘッダ未満の切り詰めは InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 16, .records = &.{.empty} }});
    defer a.free(bytes);
    try testing.expectError(error.InvalidFont, Sbix.parse(bytes[0..4], 1)); // 8 byte 未満
}

test "sbix: strikeOffsets 配列が不足する切り詰めは InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 16, .records = &.{.empty} }});
    defer a.free(bytes);
    try testing.expectError(error.InvalidFont, Sbix.parse(bytes[0..10], 1)); // strikeOffsets[0] は 4 byte 必要（8..12）だが 10 まで
}

test "sbix: strike ヘッダが不足する切り詰めは InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 16, .records = &.{.empty} }});
    defer a.free(bytes);
    // strike 本体は絶対位置 12 から始まり ppem(2)+ppi(2)+offsets[2](8) = 16 byte 必要。14 までだと不足。
    try testing.expectError(error.InvalidFont, Sbix.parse(bytes[0..14], 1));
}

test "sbix: version != 1 は InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 16, .records = &.{.empty} }});
    defer a.free(bytes);
    const corrupt = try a.dupe(u8, bytes);
    defer a.free(corrupt);
    putU16(corrupt, 0, 2); // version=2
    try testing.expectError(error.InvalidFont, Sbix.parse(corrupt, 1));
}

test "sbix: numStrikes == 0 は InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 16, .records = &.{.empty} }});
    defer a.free(bytes);
    const corrupt = try a.dupe(u8, bytes);
    defer a.free(corrupt);
    putU32(corrupt, 4, 0); // numStrikes=0
    try testing.expectError(error.InvalidFont, Sbix.parse(corrupt, 1));
}

test "sbix: numStrikes 過大（offsets 配列が table を超える）は InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 16, .records = &.{.empty} }});
    defer a.free(bytes);
    const corrupt = try a.dupe(u8, bytes);
    defer a.free(corrupt);
    putU32(corrupt, 4, 100); // numStrikes=100 だが table には 1 strike 分の余地しか無い
    try testing.expectError(error.InvalidFont, Sbix.parse(corrupt, 1));
}

// ── AC#3: strikeOffset の境界 ────────────────────────────────────

test "sbix: strikeOffset がヘッダ/offsets 配列の内側を指す（下限違反）は InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 16, .records = &.{.empty} }});
    defer a.free(bytes);
    const corrupt = try a.dupe(u8, bytes);
    defer a.free(corrupt);
    // strikeOffsets[0] は絶対位置 8。正常値 12 を、ヘッダ内(4)に書き換える。
    putU32(corrupt, 8, 4);
    try testing.expectError(error.InvalidFont, Sbix.parse(corrupt, 1));
}

test "sbix: strikeOffset が strike ヘッダ全体を table 内に収められない（上限違反・範囲外）は InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 16, .records = &.{.empty} }});
    defer a.free(bytes);
    // strike 本体（絶対位置 12）を 2 byte だけ残して切り詰める（ppem は読めても ppi/offsets が読めない）。
    try testing.expectError(error.InvalidFont, Sbix.parse(bytes[0..14], 1));
}

// ── AC#2: graphicType（png/dupe/jpg/tiff/未知） ──────────────────

test "sbix: png record は origin/type/bytes を返す" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 32, .records = &.{
        .{ .png = .{ .x = 3, .y = -5, .bytes = &.{ 0xAA, 0xBB } } },
    } }});
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    const g = (try s.glyphData(0, 0)).?;
    try testing.expectEqual(@as(i16, 3), g.origin_offset_x);
    try testing.expectEqual(@as(i16, -5), g.origin_offset_y);
    try testing.expectEqualSlices(u8, "png ", &g.graphic_type);
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB }, g.bytes);
}

test "sbix: dupe は参照先 GID の bitmap に追従する" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 2, &.{.{ .ppem = 32, .records = &.{
        .{ .dupe = .{ .gid = 1 } },
        .{ .png = .{ .bytes = &.{ 9, 9 } } },
    } }});
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 2);
    const g = (try s.glyphData(0, 0)).?;
    try testing.expectEqualSlices(u8, &.{ 9, 9 }, g.bytes);
    try testing.expectEqualSlices(u8, "png ", &g.graphic_type);
}

test "sbix: jpg/tiff/未知 tag は bitmap 無し(null)扱い" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 3, &.{.{ .ppem = 32, .records = &.{
        .{ .raw = .{ .kind = "jpg ".*, .data = &.{1} } },
        .{ .raw = .{ .kind = "tiff".*, .data = &.{1} } },
        .{ .raw = .{ .kind = "zzzz".*, .data = &.{1} } },
    } }});
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 3);
    try testing.expect((try s.glyphData(0, 0)) == null);
    try testing.expect((try s.glyphData(0, 1)) == null);
    try testing.expect((try s.glyphData(0, 2)) == null);
}

// ── AC#6: dupe の安全性 ──────────────────────────────────────────

test "sbix: dupe の data 長 != 2 は InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{
        .ppem = 32,
        .records = &.{
            .{ .raw = .{ .kind = "dupe".*, .data = &.{ 1, 2, 3 } } }, // 3 byte（不正）
        },
    }});
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    try testing.expectError(error.InvalidFont, s.glyphData(0, 0));
}

test "sbix: dupe の参照先 GID が範囲外は InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{
        .ppem = 32,
        .records = &.{
            .{ .dupe = .{ .gid = 5 } }, // numGlyphs=1 なので範囲外
        },
    }});
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    try testing.expectError(error.InvalidFont, s.glyphData(0, 0));
}

test "sbix: dupe の自己参照は深さ上限超過で InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{
        .ppem = 32,
        .records = &.{
            .{ .dupe = .{ .gid = 0 } }, // 自己参照（無限ループを深さ上限で止める）
        },
    }});
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    try testing.expectError(error.InvalidFont, s.glyphData(0, 0));
}

test "sbix: dupe の相互循環は深さ上限超過で InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 2, &.{.{ .ppem = 32, .records = &.{
        .{ .dupe = .{ .gid = 1 } },
        .{ .dupe = .{ .gid = 0 } },
    } }});
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 2);
    try testing.expectError(error.InvalidFont, s.glyphData(0, 0));
}

test "sbix: dupe→png の origin は参照先レコードを採用する（この実装の仕様）" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 2, &.{.{
        .ppem = 32,
        .records = &.{
            .{ .dupe = .{ .x = 999, .y = 888, .gid = 1 } }, // 自身の origin は無視される
            .{ .png = .{ .x = 5, .y = 7, .bytes = &.{ 1, 2, 3 } } },
        },
    }});
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 2);
    const g = (try s.glyphData(0, 0)).?;
    try testing.expectEqual(@as(i16, 5), g.origin_offset_x);
    try testing.expectEqual(@as(i16, 7), g.origin_offset_y);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, g.bytes);
}

// ── AC#3: glyphDataOffset の境界（レコード） ────────────────────

test "sbix: glyphDataOffset 逆転（off0 > off1）は InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 2, &.{.{ .ppem = 32, .records = &.{
        .{ .png = .{ .bytes = &.{1} } },
        .{ .png = .{ .bytes = &.{1} } },
    } }});
    defer a.free(bytes);
    const corrupt = try a.dupe(u8, bytes);
    defer a.free(corrupt);
    // 単一 strike・numGlyphs=2 では glyphDataOffsets[gid] は絶対位置 16+4*gid に固定。
    // offsets[1] を offsets[0] より小さい値へ書き換えて gid0 のレコードを逆転させる。
    putU32(corrupt, 16 + 4 * 1, 0);
    const s = try Sbix.parse(corrupt, 2);
    try testing.expectError(error.InvalidFont, s.glyphData(0, 0));
}

test "sbix: glyphDataOffset のレコード長 1..7（0 でも 8 以上でもない）は InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{
        .ppem = 32,
        .records = &.{
            .{ .png = .{ .bytes = &.{} } }, // 自然長は 8（header のみ）
        },
    }});
    defer a.free(bytes);
    const corrupt = try a.dupe(u8, bytes);
    defer a.free(corrupt);
    // offsets[0]=12(header_len), offsets[1]（絶対位置 16+4=20）を 12+3=15 に書き換えてレコード長 3 に。
    putU32(corrupt, 16 + 4 * 1, 15);
    const s = try Sbix.parse(corrupt, 1);
    try testing.expectError(error.InvalidFont, s.glyphData(0, 0));
}

test "sbix: 非空レコードの glyphDataOffset がヘッダ内を指す（下限違反）は InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 32, .records = &.{
        .{ .png = .{ .bytes = &.{ 1, 2 } } },
    } }});
    defer a.free(bytes);
    const corrupt = try a.dupe(u8, bytes);
    defer a.free(corrupt);
    // offsets[0]（絶対位置 16）を 0 に書き換える（off1 はそのまま。off0!=off1 で非空）。
    putU32(corrupt, 16 + 4 * 0, 0);
    const s = try Sbix.parse(corrupt, 1);
    try testing.expectError(error.InvalidFont, s.glyphData(0, 0));
}

test "sbix: 空レコード（off0==off1）は下限違反があっても null（例外的に安全）" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 32, .records = &.{.empty} }});
    defer a.free(bytes);
    const corrupt = try a.dupe(u8, bytes);
    defer a.free(corrupt);
    // offsets[0],offsets[1] とも 0 に書き換える（off0==off1==0 はヘッダ内=下限違反の値だが、
    // 1 byte も読まないため安全に null を返す仕様）。
    putU32(corrupt, 16 + 4 * 0, 0);
    putU32(corrupt, 16 + 4 * 1, 0);
    const s = try Sbix.parse(corrupt, 1);
    try testing.expect((try s.glyphData(0, 0)) == null);
}

test "sbix: glyphDataOffset が strike の残り領域を超える（範囲外）は InvalidFont" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 32, .records = &.{
        .{ .png = .{ .bytes = &.{1} } },
    } }});
    defer a.free(bytes);
    const corrupt = try a.dupe(u8, bytes);
    defer a.free(corrupt);
    putU32(corrupt, 16 + 4 * 1, 0xFFFFFF); // offsets[1](sentinel) を巨大値に
    const s = try Sbix.parse(corrupt, 1);
    try testing.expectError(error.InvalidFont, s.glyphData(0, 0));
}

// ── AC: 範囲外 GID 引数 ──────────────────────────────────────────

test "sbix: 範囲外 GID 引数は InvalidFont（glyphData / findGlyph）" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 32, .records = &.{.empty} }});
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    try testing.expectError(error.InvalidFont, s.glyphData(0, 1)); // gid==numGlyphs
    try testing.expectError(error.InvalidFont, s.findGlyph(32, 1));
}

test "sbix: 範囲外 strike index は InvalidFont（strikeAt / glyphData）" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{.{ .ppem = 32, .records = &.{.empty} }});
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    try testing.expectError(error.InvalidFont, s.strikeAt(1));
    try testing.expectError(error.InvalidFont, s.glyphData(1, 0));
}

// ── AC#4: strike をまたいだ coverage 解決 ────────────────────────

test "sbix: findGlyph は strike A に無く B にある GID を B から解決する" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 16, .records = &.{.empty} }, // strike A: bitmap 無し
        .{ .ppem = 32, .records = &.{.{ .png = .{ .bytes = &.{7} } }} }, // strike B: bitmap 有り
    });
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    const found = (try s.findGlyph(16, 0)).?; // 目標=16 は strike A(16)を優先するが無いので B へ
    try testing.expectEqual(@as(u32, 1), found.strike.index);
    try testing.expectEqualSlices(u8, &.{7}, found.glyph.bytes);
}

test "sbix: findGlyph は目標未満のみのとき ppem 降順で次点へフォールバックする" {
    const a = testing.allocator;
    // 目標=100。ppem>=100 の strike は無い。40(最大)に bitmap 無し→次点 20 に有り、を確認。
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 40, .records = &.{.empty} },
        .{ .ppem = 20, .records = &.{.{ .png = .{ .bytes = &.{5} } }} },
    });
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    const found = (try s.findGlyph(100, 0)).?;
    try testing.expectEqual(@as(u32, 1), found.strike.index);
    try testing.expectEqualSlices(u8, &.{5}, found.glyph.bytes);
}

test "sbix: findGlyph は同 ppem 複数で先勝ち（index 昇順）が bitmap 無しなら次の同値へ進む" {
    const a = testing.allocator;
    // 目標=32。ppem=32 が index0,1 の 2 つ。0 は bitmap 無し→先勝ちで試すが空なので index1 へ進む。
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 32, .records = &.{.empty} },
        .{ .ppem = 32, .records = &.{.{ .png = .{ .bytes = &.{9} } }} },
    });
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    const found = (try s.findGlyph(32, 0)).?;
    try testing.expectEqual(@as(u32, 1), found.strike.index);
    try testing.expectEqualSlices(u8, &.{9}, found.glyph.bytes);
}

test "sbix: findGlyph は strike 配列が ppem 昇順でなくても正しく走査する" {
    const a = testing.allocator;
    // 配列順: 64(bitmap無), 16(bitmap無), 32(bitmap有)。目標=20 → ppem>=20 は{64,32}だが
    // 配列順(64が先)ではなく ppem 昇順(32が先)で試すため、32 が bitmap 有りで即発見できる。
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 64, .records = &.{.empty} },
        .{ .ppem = 16, .records = &.{.empty} },
        .{ .ppem = 32, .records = &.{.{ .png = .{ .bytes = &.{3} } }} },
    });
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    const found = (try s.findGlyph(20, 0)).?;
    try testing.expectEqual(@as(u32, 2), found.strike.index);
    try testing.expectEqualSlices(u8, &.{3}, found.glyph.bytes);
}

test "sbix: findGlyph は全て目標未満で ppem 降順走査が複数段フォールバックする" {
    const a = testing.allocator;
    // 目標=100。降順候補: 40(無)→20(無)→10(有)。
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 40, .records = &.{.empty} },
        .{ .ppem = 20, .records = &.{.empty} },
        .{ .ppem = 10, .records = &.{.{ .png = .{ .bytes = &.{1} } }} },
    });
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    const found = (try s.findGlyph(100, 0)).?;
    try testing.expectEqual(@as(u32, 2), found.strike.index);
    try testing.expectEqualSlices(u8, &.{1}, found.glyph.bytes);
}

test "sbix: findGlyph は全 strike に無ければ null（strikeAt で列挙可能）" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 16, .records = &.{.empty} },
        .{ .ppem = 32, .records = &.{.empty} },
    });
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    try testing.expect((try s.findGlyph(16, 0)) == null);
    try testing.expectEqual(@as(u32, 2), s.num_strikes);
    try testing.expectEqual(@as(u16, 16), (try s.strikeAt(0)).ppem);
    try testing.expectEqual(@as(u16, 32), (try s.strikeAt(1)).ppem);
}

test "sbix: findGlyph は途中 strike の構造エラーを伝播する（握りつぶさない）" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 16, .records = &.{.{ .png = .{ .bytes = &.{1} } }} },
    });
    defer a.free(bytes);
    const corrupt = try a.dupe(u8, bytes);
    defer a.free(corrupt);
    putU32(corrupt, 16 + 4 * 1, 0xFFFFFF); // strike0 の gid0 レコードを範囲外に破壊
    const s = try Sbix.parse(corrupt, 1);
    try testing.expectError(error.InvalidFont, s.findGlyph(16, 0));
}

// ── AC#5: selectStrike の固定規則 ─────────────────────────────────

test "sbix: selectStrike は目標 px 以上の最小 ppem を選ぶ" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 16, .records = &.{.empty} },
        .{ .ppem = 32, .records = &.{.empty} },
        .{ .ppem = 64, .records = &.{.empty} },
    });
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    try testing.expectEqual(@as(u16, 32), (try s.selectStrike(20)).ppem);
    try testing.expectEqual(@as(u16, 16), (try s.selectStrike(16)).ppem); // ちょうど一致
}

test "sbix: selectStrike は全て目標未満なら最大 ppem を選ぶ" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 16, .records = &.{.empty} },
        .{ .ppem = 32, .records = &.{.empty} },
    });
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    try testing.expectEqual(@as(u16, 32), (try s.selectStrike(100)).ppem);
}

test "sbix: selectStrike は同 ppem 複数なら strike 配列順で先勝ち（ppi は無視）" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 32, .ppi = 72, .records = &.{.empty} },
        .{ .ppem = 32, .ppi = 144, .records = &.{.empty} },
    });
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    const sel = try s.selectStrike(20);
    try testing.expectEqual(@as(u32, 0), sel.index); // 先勝ち
    try testing.expectEqual(@as(u16, 72), sel.ppi);
}

test "sbix: selectStrike は strike 配列が ppem 昇順でなくても正しく選ぶ" {
    const a = testing.allocator;
    const bytes = try buildSbix(a, 1, &.{
        .{ .ppem = 64, .records = &.{.empty} },
        .{ .ppem = 16, .records = &.{.empty} },
        .{ .ppem = 32, .records = &.{.empty} },
    });
    defer a.free(bytes);
    const s = try Sbix.parse(bytes, 1);
    try testing.expectEqual(@as(u16, 32), (try s.selectStrike(20)).ppem);
    try testing.expectEqual(@as(u16, 16), (try s.selectStrike(0)).ppem);
}
