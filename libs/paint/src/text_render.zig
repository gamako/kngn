//! テキストレイヤーの text_params → pixels（全画素、canvas 全体サイズ）再ラスタライズ（TASK-79.5。
//! TASK-82 で system font 対応）。
//!
//! `libs/font`（TASK-79.4 の透明バッファ焼き込み基盤）へ委譲する。フォントは
//! **呼び出し側（`Canvas.system_font`）が渡す system font bytes を優先**し、渡されなかった/
//! parse 失敗した場合のみ vendoring 済みの既定フォント（`font.default_font_bytes`, OFL
//! Press Start 2P。ASCII のみ）へフォールバックする（TASK-82）。System font（macOS の
//! ヒラギノ角ゴ等の `.ttc`）は CJK グリフを含むため、日本語テキストレイヤーが tofu(□) にならず
//! 字形で描画される。フォントバイト列の実ディスク読込・パス解決は呼び出し側（pixie App。
//! `examples/12_outline_font`/`examples/21_char_input` と同じ system font ランタイム読込パターン）
//! の責務で、本関数は既に読み込まれた bytes を受け取るだけ（本ファイルは disk I/O をしない）。
//! いずれの経路でも `FontFace.init` + `OutlineFont.init` を毎回 fresh に構築し、描画後に
//! `deinit` する（イベント時のみ呼ばれるため per-call 構築で十分。グリフキャッシュは呼び出しを
//! またいで保持しない。`FontFace.init` は sfnt table directory + cmap header の parse のみで
//! alloc を伴わないため、system font のファイルサイズが大きくても軽い。ディスク I/O 自体は
//! 呼び出し側が起動時に1回だけ行い bytes をキャッシュするため、本関数の呼び出し毎に発生しない）。
//!
//! **本ファイルは `canvas.zig` を import しない**（`Layer`/`TextParams` の型に依存せず個別の
//! スカラー引数を取ることで、`canvas.zig` → `text_render.zig` の一方向 import を保つ。circular
//! import 回避）。
//!
//! ホットパス宣言: **イベント時のみ**（テキスト内容/サイズ/色/位置の編集確定時に1回）。
//! フレーム毎ではないため性能規約の SIMD 3点セット等は必須対象外（既存 `doMergeDown` 等の
//! event-time 全画素ループと同じ扱い）。対象面積はテキストのグリフ bbox（通常 canvas 全体より
//! 遥かに小さい）に限られ、実質的な負荷は小さい。`blitOnto` は dst が呼び出し前に全域
//! `@memset` で 0（透明）初期化されている前提で `memcpy` する（straight-alpha src-over の
//! 数式的帰結: da=0 の時 out=src と一致するため、per-pixel のブレンド計算自体が不要）。

const std = @import("std");
const font = @import("font");

/// `pixels`（`width*height`, straight alpha canonical BGRA。呼び出し前のサイズ不変条件は
/// 呼び出し側=Canvas が保証する）を `text`/`font_px`/`color`/`x`/`y` から再生成する。
/// 空文字列（`text.len==0`）は全透明のまま（`memset` 済みで return）。
/// `font_px` の非有限値/非正値は許容する（`font.OutlineFont.init` が内部で安全値へ
/// sanitize するため描画は落ちない。`TextParams` へ非有限値を保存させない検証は
/// 呼び出し側=`document_io.zig` の decode 時に行う。ここでは二重にしない）。
///
/// `system_font`（TASK-82）: 呼び出し側が既に読み込んだ system font のバイト列（`.ttf`/`.ttc`）。
/// `null` または `FontFace.init` が失敗する（破損/非対応バイト列）場合は embedded
/// `font.default_font_bytes`（ASCII のみ）へフォールバックする。呼び出し側は通常この防御的
/// フォールバックに頼らず起動時に一度 parse 検証した bytes を渡す想定だが、本関数は二重に
/// 防御することでどのような bytes を渡されても crash しない。
pub fn rasterizeTextLayer(
    gpa: std.mem.Allocator,
    pixels: []u32,
    width: u32,
    height: u32,
    text: []const u8,
    font_px: f32,
    color: u32,
    x: i32,
    y: i32,
    system_font: ?[]const u8,
) !void {
    std.debug.assert(pixels.len == @as(usize, width) * @as(usize, height));
    @memset(pixels, 0);
    if (text.len == 0) return;

    const face: font.FontFace = blk: {
        if (system_font) |bytes| {
            if (font.FontFace.init(bytes)) |f| break :blk f else |_| {}
        }
        break :blk try font.FontFace.init(font.default_font_bytes);
    };
    var of = font.OutlineFont.init(gpa, &face, font_px);
    defer of.deinit();

    var rendered = try font.renderTextLayer(gpa, &of, text, @bitCast(color));
    defer rendered.deinit(gpa);

    blitOnto(pixels, width, height, rendered.pixels, rendered.width, rendered.height, x, y);
}

/// straight-alpha の小さい `src`（`sw x sh`）を、透明で初期化済みの `dst`（`dw x dh`）へ
/// `(dst_x, dst_y)` を左上として配置する。clip はループ外で1回計算し、内側は無条件 `memcpy`
/// （dst は呼び出し前に全域0埋め済み＝src-over ではなく単純コピーで正しい）。完全に canvas
/// 外なら何もしない（クラッシュしない）。
fn blitOnto(dst: []u32, dw: u32, dh: u32, src: []const u32, sw: u32, sh: u32, dst_x: i32, dst_y: i32) void {
    if (sw == 0 or sh == 0) return;
    const x0: i64 = @max(0, dst_x);
    const y0: i64 = @max(0, dst_y);
    const x1: i64 = @min(@as(i64, dw), @as(i64, dst_x) + @as(i64, sw));
    const y1: i64 = @min(@as(i64, dh), @as(i64, dst_y) + @as(i64, sh));
    if (x1 <= x0 or y1 <= y0) return; // 完全に canvas 外

    const ux0: usize = @intCast(x0);
    const uy0: usize = @intCast(y0);
    const uy1: usize = @intCast(y1);
    const row_len: usize = @intCast(x1 - x0);
    const src_x0: usize = @intCast(x0 - dst_x);
    const src_y0: usize = @intCast(y0 - dst_y);

    var dy = uy0;
    var sy = src_y0;
    while (dy < uy1) : ({
        dy += 1;
        sy += 1;
    }) {
        const drow = dst[dy * dw + ux0 ..][0..row_len];
        const srow = src[sy * sw + src_x0 ..][0..row_len];
        @memcpy(drow, srow);
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "rasterizeTextLayer: 空文字列は全透明のまま" {
    const gpa = testing.allocator;
    const pixels = try gpa.alloc(u32, 8 * 8);
    defer gpa.free(pixels);
    @memset(pixels, 0xFFFFFFFF); // 事前に非透明で汚しておき、memset(0) が効くことも確認
    try rasterizeTextLayer(gpa, pixels, 8, 8, "", 16, 0xFFFFFFFF, 0, 0, null);
    for (pixels) |p| try testing.expectEqual(@as(u32, 0), p);
}

test "rasterizeTextLayer: 非空文字列は canvas 内に非透明ピクセルを焼く" {
    const gpa = testing.allocator;
    const w: u32 = 64;
    const h: u32 = 32;
    const pixels = try gpa.alloc(u32, w * h);
    defer gpa.free(pixels);
    try rasterizeTextLayer(gpa, pixels, w, h, "Hi", 16, 0xFFFFFFFF, 4, 4, null);

    var non_transparent: usize = 0;
    for (pixels) |p| {
        if (p & 0xFF000000 != 0) non_transparent += 1;
    }
    try testing.expect(non_transparent > 0);
}

test "rasterizeTextLayer: 位置が canvas 完全に外でもクラッシュせず全透明" {
    const gpa = testing.allocator;
    const w: u32 = 16;
    const h: u32 = 16;
    const pixels = try gpa.alloc(u32, w * h);
    defer gpa.free(pixels);
    try rasterizeTextLayer(gpa, pixels, w, h, "Hi", 16, 0xFFFFFFFF, 10_000, 10_000, null);
    for (pixels) |p| try testing.expectEqual(@as(u32, 0), p);

    // 負方向に大きく外れても同様
    try rasterizeTextLayer(gpa, pixels, w, h, "Hi", 16, 0xFFFFFFFF, -10_000, -10_000, null);
    for (pixels) |p| try testing.expectEqual(@as(u32, 0), p);
}

test "rasterizeTextLayer: 部分的に canvas 外へはみ出る配置は clip された範囲だけ焼かれる" {
    const gpa = testing.allocator;
    const w: u32 = 16;
    const h: u32 = 16;
    const pixels = try gpa.alloc(u32, w * h);
    defer gpa.free(pixels);
    // 右下ぎりぎり（大部分が canvas 外）に配置してもクラッシュせず、canvas 内側だけ焼かれる。
    try rasterizeTextLayer(gpa, pixels, w, h, "Hi", 16, 0xFFFFFFFF, @as(i32, @intCast(w)) - 2, @as(i32, @intCast(h)) - 2, null);
    var non_transparent: usize = 0;
    for (pixels) |p| {
        if (p & 0xFF000000 != 0) non_transparent += 1;
    }
    try testing.expect(non_transparent > 0);
    try testing.expect(non_transparent <= 4); // clip された 2x2 の範囲以内
}

test "rasterizeTextLayer: 呼び出しを繰り返しても前回の内容が残らない（毎回 memset される）" {
    const gpa = testing.allocator;
    const w: u32 = 32;
    const h: u32 = 16;
    const pixels = try gpa.alloc(u32, w * h);
    defer gpa.free(pixels);
    try rasterizeTextLayer(gpa, pixels, w, h, "Hello", 16, 0xFFFFFFFF, 0, 0, null);
    var first_count: usize = 0;
    for (pixels) |p| {
        if (p & 0xFF000000 != 0) first_count += 1;
    }
    try testing.expect(first_count > 0);

    try rasterizeTextLayer(gpa, pixels, w, h, "", 16, 0xFFFFFFFF, 0, 0, null); // 空文字列 → 全透明に戻る
    for (pixels) |p| try testing.expectEqual(@as(u32, 0), p);
}

test "rasterizeTextLayer: system_font が実際に使われる（embedded と異なる結果を生む。TASK-82。codex コードレビュー指摘の強化）" {
    // 前回版は system_font に `font.default_font_bytes` そのものを注入しており、
    // 「system_font を無視して常に embedded font を使う」実装でも同じ結果になり通ってしまう
    // 弱いテストだった（codex コードレビュー指摘）。ここでは embedded font と明確に異なる
    // 合成済み最小フォント（cmap が通常の文字を一切マップしない＝gid0(.notdef, 空グリフ)固定）
    // を system_font として渡す。embedded font は "Hi" の実グリフを持つため非透明ピクセルを
    // 生成するのに対し、このテストフォントを使えば必ず全透明になる。よって「全透明になる」
    // ことの確認が、system_font 分岐が確実に使われた（embedded へ無視フォールバックしていない）
    // ことの直接証拠になる。
    const gpa = testing.allocator;
    const blank_font = try buildBlankTestFont(gpa);
    defer gpa.free(blank_font);

    const w: u32 = 64;
    const h: u32 = 32;
    const pixels = try gpa.alloc(u32, w * h);
    defer gpa.free(pixels);
    try rasterizeTextLayer(gpa, pixels, w, h, "Hi", 16, 0xFFFFFFFF, 4, 4, blank_font);
    for (pixels) |p| try testing.expectEqual(@as(u32, 0), p); // gid0(.notdef) は空グリフ→全透明

    // 対照: 同じ "Hi" を system_font=null（embedded フォールバック）で描くと非透明になる
    // （既存テストで確認済みだが、ここでも同一 pixels バッファで直接対比させる）。
    try rasterizeTextLayer(gpa, pixels, w, h, "Hi", 16, 0xFFFFFFFF, 4, 4, null);
    var non_transparent: usize = 0;
    for (pixels) |p| {
        if (p & 0xFF000000 != 0) non_transparent += 1;
    }
    try testing.expect(non_transparent > 0);
}

test "rasterizeTextLayer: system_font が破損バイト列でも embedded フォントへフォールバックしクラッシュしない（AC#2）" {
    const gpa = testing.allocator;
    const w: u32 = 64;
    const h: u32 = 32;
    const pixels = try gpa.alloc(u32, w * h);
    defer gpa.free(pixels);
    const garbage = [_]u8{ 1, 2, 3 }; // FontFace.init が InvalidFont/Unsupported で弾く短い非対応バイト列
    try rasterizeTextLayer(gpa, pixels, w, h, "Hi", 16, 0xFFFFFFFF, 4, 4, &garbage);

    var non_transparent: usize = 0;
    for (pixels) |p| {
        if (p & 0xFF000000 != 0) non_transparent += 1;
    }
    try testing.expect(non_transparent > 0); // embedded ASCII フォントへフォールバックして描画される
}

// ── テスト用の最小合成 sfnt ビルダー（TASK-82）─────────────────────────
//
// `libs/font/src/outline_font.zig` の private test helper `buildTestFont`/`buildSfnt` と
// 同型（それらは非 `pub` で本ファイルから参照できず、`libs/font` 自体はスコープ上変更しないため
// 独立実装する）。ここでは三角形グリフは不要（cmap がどの通常文字もマップしない=全て
// gid0(.notdef, 空グリフ) に落ちるだけで用が足りる）ため、`buildTestFont` より単純にできる。

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
fn appendU16(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) !void {
    try l.append(a, @intCast(v >> 8));
    try l.append(a, @truncate(v));
}
fn appendU32(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
    try l.append(a, @truncate(v >> 24));
    try l.append(a, @truncate(v >> 16));
    try l.append(a, @truncate(v >> 8));
    try l.append(a, @truncate(v));
}

/// sfnt(tag,body) 群からフォントバイト列を組む（checksum は 0 固定。`SfntFile.parse` は
/// checksum を検証しない）。
fn buildSfnt(a: std.mem.Allocator, tables: []const struct { tag: [4]u8, body: []const u8 }) ![]u8 {
    const n: u16 = @intCast(tables.len);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try appendU32(&out, a, 0x00010000); // version = TrueType
    try appendU16(&out, a, n);
    try appendU16(&out, a, 0); // searchRange
    try appendU16(&out, a, 0); // entrySelector
    try appendU16(&out, a, 0); // rangeShift
    var off: u32 = @intCast(12 + 16 * @as(usize, n));
    for (tables) |t| {
        try out.appendSlice(a, &t.tag);
        try appendU32(&out, a, 0); // checksum（未使用）
        try appendU32(&out, a, off);
        try appendU32(&out, a, @intCast(t.body.len));
        off += @intCast(t.body.len);
    }
    for (tables) |t| try out.appendSlice(a, t.body);
    return out.toOwnedSlice(a);
}

/// 合成済み最小 TTF: numGlyphs=1（gid0=.notdef, 空グリフのみ）・cmap は sentinel セグメント
/// （0xFFFF）のみで通常の文字を一切マップしない。この font でどの文字列を描いても
/// 全て gid0(.notdef, 空グリフ) に解決され、レンダリング結果は全透明になる（`renderTextLayer`
/// の描画対象領域の実 pixels に非透明画素が全く現れない）。embedded font（"Hi" 等の実グリフを
/// 持つ）と観測可能に異なる結果になることを保証するための「意図的に何も描けないフォント」。
fn buildBlankTestFont(a: std.mem.Allocator) ![]u8 {
    var head = [_]u8{0} ** 54;
    putU32(&head, 12, 0x5F0F3CF5); // magicNumber
    putU16(&head, 18, 64); // unitsPerEm
    putU16(&head, 50, 0); // indexToLocFormat = short

    var maxp = [_]u8{0} ** 6;
    putU16(&maxp, 4, 1); // numGlyphs = 1（.notdef のみ）

    var hhea = [_]u8{0} ** 36;
    putU16(&hhea, 4, 48); // ascender
    putU16(&hhea, 6, @bitCast(@as(i16, -16))); // descender
    putU16(&hhea, 34, 1); // numberOfHMetrics

    const hmtx = [_]u8{0} ** 4; // gid0: advance=0, lsb=0

    // cmap format4: セグメント1つ（sentinel 0xFFFF）のみ＝通常の文字は全て未対応→gid0。
    var cmap_sub = [_]u8{0} ** 24; // 14(固定ヘッダ) + 2(end) + 2(reservedPad) + 2(start) + 2(delta) + 2(rangeOffset)
    putU16(&cmap_sub, 0, 4); // format
    putU16(&cmap_sub, 2, @intCast(cmap_sub.len)); // length
    putU16(&cmap_sub, 6, 2); // segCountX2 = 1 seg * 2
    putU16(&cmap_sub, 14, 0xFFFF); // endCode[0]
    putU16(&cmap_sub, 18, 0xFFFF); // startCode[0]
    putU16(&cmap_sub, 20, 1); // idDelta[0]
    putU16(&cmap_sub, 22, 0); // idRangeOffset[0]

    var cmap_tbl = [_]u8{0} ** (4 + 8 + 24);
    putU16(&cmap_tbl, 2, 1); // numTables = 1
    putU16(&cmap_tbl, 4, 3); // platformID = Windows
    putU16(&cmap_tbl, 6, 1); // encodingID = Unicode BMP
    putU32(&cmap_tbl, 8, 12); // subtable offset = 4+8
    @memcpy(cmap_tbl[12..], &cmap_sub);

    const loca = [_]u8{0} ** 4; // short format, (numGlyphs+1)=2 entries、全て0＝gid0 は空

    return buildSfnt(a, &.{
        .{ .tag = "head".*, .body = &head },
        .{ .tag = "maxp".*, .body = &maxp },
        .{ .tag = "hhea".*, .body = &hhea },
        .{ .tag = "hmtx".*, .body = &hmtx },
        .{ .tag = "cmap".*, .body = &cmap_tbl },
        .{ .tag = "loca".*, .body = &loca },
        .{ .tag = "glyf".*, .body = &[_]u8{} },
    });
}
