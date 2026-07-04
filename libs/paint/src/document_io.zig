//! document_io — Document の直列化（.pix プロジェクトファイル）と PNG 連番書き出し（TASK-63）。
//!
//! 62.2 の `serde` versioned container（RIFF/IFF 系統）に pixie の schema を載せる第一 adopter。
//! serde が「コンテナ（magic/version/chunk/CRC）」を、この module が「pixie schema（DOCH/FRAM/LAYR）」を担う。
//! serde は file I/O を持たないので、実 I/O（read/write file）はここで `std.Io` 経由に行う
//! （既存 io_png.savePNG と同じ流儀）。
//!
//! schema（streaming walk。DOCH→メタ / FRAM→新フレーム / LAYR→現フレームへ layer 追加。すべて little-endian）:
//! - DOCH(1個・先頭): width u32 | height u32 | frame_count u32 | selected_layer u32 | flags u32(予約=0)
//! - FRAM(frame 毎): frame_index u32 | duration_ms u32(予約=0, TASK-45 用)
//! - LAYR(layer 毎, 親 FRAM の後に出現順): type u8(0=raster) | visible u8 | opacity u8 | blend u8(予約=0)
//!                                        | compression u8(0=raw) | pad[3] | pixels[W*H*4]（raw canonical BGRA u32, row-major）
//!
//! **pixel byte 順の責務はここ（schema 側）**（serde は payload opaque）。canonical BGRA u32 を
//! std.mem.sliceAsBytes で直格納 = little-endian BGRA bytes。ターゲット（aarch64/x86_64）は LE なので直格納で足りる。
//!
//! 前方互換: 未知 chunk tag は serde iterator が skip / 未知 LAYR.type は skip（層追加しない）/
//!           raster かつ compression≠raw は error / 構造違反（DOCH 欠落・重複・LAYR-before-FRAM・payload 長不一致・
//!           schema_version 超過・frame_count 不一致）は error。
//!
//! ホットパス宣言: 保存・読込・書き出しは **イベント時のみ**（メニュー操作 1 回）。全画素規模だが
//! フレーム毎ループではないため SIMD 3 点セット対象外。pixel payload は @memcpy 一括転送
//! （per-pixel 除算/関数呼び出し/bounds 検査なし）。

const std = @import("std");
const serde = @import("serde");
const canvas_mod = @import("canvas.zig");
const document_mod = @import("document.zig");
const io_png = @import("io_png.zig");
const Canvas = canvas_mod.Canvas;
const Document = document_mod.Document;

/// .pix の magic（FourCC 'PIX1' の little-endian u32）。serde の expected_magic に渡す。
pub const magic: u32 = @as(u32, 'P') | (@as(u32, 'I') << 8) | (@as(u32, 'X') << 16) | (@as(u32, '1') << 24);
/// pixie schema のバージョン（serde の container_version とは別。app 管理）。
pub const schema_version: u16 = 1;

const TAG_DOC: [4]u8 = "DOCH".*;
const TAG_FRAME: [4]u8 = "FRAM".*;
const TAG_LAYER: [4]u8 = "LAYR".*;

const doc_header_size: usize = 20;
const frame_header_size: usize = 8;
const layer_header_size: usize = 8;
const layer_type_raster: u8 = 0;
const compression_raw: u8 = 0;

pub const CanvasSize = struct { w: u32, h: u32 };

// ── encode / decode（bytes ⇔ Document。file I/O なし）─────────────────────

/// Document を .pix バイト列へ直列化する（caller が free）。
pub fn encodeDocument(doc: *Document, gpa: std.mem.Allocator) ![]u8 {
    var w = try serde.Writer.init(gpa, magic, schema_version);
    errdefer w.deinit();

    var doch: [doc_header_size]u8 = undefined;
    std.mem.writeInt(u32, doch[0..4], doc.width, .little);
    std.mem.writeInt(u32, doch[4..8], doc.height, .little);
    std.mem.writeInt(u32, doch[8..12], @intCast(doc.frameCount()), .little);
    // MVP は active frame の selected_layer を保存（多フレーム化では FRAM 側へ移す想定）。
    std.mem.writeInt(u32, doch[12..16], @intCast(doc.activeCanvas().selected_layer), .little);
    std.mem.writeInt(u32, doch[16..20], 0, .little); // flags 予約
    try w.addChunk(TAG_DOC, &doch);

    for (doc.frames.items, 0..) |c, fi| {
        var frm: [frame_header_size]u8 = undefined;
        std.mem.writeInt(u32, frm[0..4], @intCast(fi), .little);
        std.mem.writeInt(u32, frm[4..8], 0, .little); // duration 予約
        try w.addChunk(TAG_FRAME, &frm);

        for (c.layers.items) |layer| {
            const px_bytes = std.mem.sliceAsBytes(layer.pixels);
            // meta(8B) + pixels を 1 chunk に inline（未知 type の skip が chunk 単位で済む）。
            // event-time の temp alloc は許容（フレーム毎ループではない）。
            const buf = try gpa.alloc(u8, layer_header_size + px_bytes.len);
            defer gpa.free(buf);
            buf[0] = layer_type_raster;
            buf[1] = @intFromBool(layer.visible);
            buf[2] = layer.opacity;
            buf[3] = 0; // blend 予約
            buf[4] = compression_raw;
            buf[5] = 0;
            buf[6] = 0;
            buf[7] = 0; // pad
            @memcpy(buf[layer_header_size..], px_bytes);
            try w.addChunk(TAG_LAYER, buf);
        }
    }
    return w.finish();
}

/// .pix バイト列から Document を復元する（任意サイズ。size 制限は呼び出し側=pixie 責務）。
pub fn decodeDocument(bytes: []const u8, gpa: std.mem.Allocator) !Document {
    const container = try serde.Container.parse(bytes, magic);
    if (container.schemaVersion() > schema_version) return error.UnsupportedSchemaVersion;

    var it = container.iterator();
    const first = it.next() orelse return error.MissingHeader;
    if (!std.mem.eql(u8, &first.tag, &TAG_DOC)) return error.MissingHeader;
    // v1 は固定長。将来 DOCH を拡張する版は schema_version を上げ、上の gate で先に弾かれる
    // ため、v1 内では厳密一致を要求する（余剰 bytes = 破損）。
    if (first.payload.len != doc_header_size) return error.CorruptDocument;
    const width = std.mem.readInt(u32, first.payload[0..4], .little);
    const height = std.mem.readInt(u32, first.payload[4..8], .little);
    const declared_frames = std.mem.readInt(u32, first.payload[8..12], .little);
    const sel_layer = std.mem.readInt(u32, first.payload[12..16], .little);

    var doc = Document.initEmpty(gpa, width, height);
    errdefer doc.deinit();

    var cur: ?*Canvas = null;
    var filled_layer0 = false;
    const px_len: usize = @as(usize, width) * height;
    const expected_layer_payload = layer_header_size + px_len * 4;

    while (it.next()) |chunk| {
        if (std.mem.eql(u8, &chunk.tag, &TAG_DOC)) return error.DuplicateHeader;
        if (std.mem.eql(u8, &chunk.tag, &TAG_FRAME)) {
            if (chunk.payload.len != frame_header_size) return error.CorruptFrame; // v1 固定長（破損検出）
            // 新フレーム。Canvas は heap 確保しポインタ安定にして Document へ所有権移譲。
            const c = try gpa.create(Canvas);
            c.* = Canvas.init(gpa, width, height) catch |e| {
                gpa.destroy(c);
                return e;
            };
            doc.appendFrame(c) catch |e| {
                c.deinit();
                gpa.destroy(c);
                return e;
            };
            cur = c;
            filled_layer0 = false;
        } else if (std.mem.eql(u8, &chunk.tag, &TAG_LAYER)) {
            const c = cur orelse return error.LayerBeforeFrame;
            const p = chunk.payload;
            if (p.len < layer_header_size) return error.CorruptLayer;
            if (p[0] != layer_type_raster) continue; // 未知 type: skip（前方互換。層は追加しない）
            if (p[4] != compression_raw) return error.UnsupportedCompression;
            if (p.len != expected_layer_payload) return error.CorruptLayer;
            const visible = p[1] != 0;
            const opacity = p[2];
            const src_bytes = p[layer_header_size..];
            if (!filled_layer0) {
                // Canvas.init の初期 blank layer0 を上書き（層が余らないように。codex 指摘）。
                @memcpy(std.mem.sliceAsBytes(c.layers.items[0].pixels), src_bytes);
                c.layers.items[0].visible = visible;
                c.layers.items[0].opacity = opacity;
                filled_layer0 = true;
            } else {
                var layer = try c.allocBlankLayer(gpa);
                errdefer gpa.free(layer.pixels);
                @memcpy(std.mem.sliceAsBytes(layer.pixels), src_bytes);
                layer.visible = visible;
                layer.opacity = opacity;
                try c.insertLayer(gpa, c.layers.items.len, layer);
            }
        }
        // 未知 tag は無視（serde iterator は全 chunk を返すが match しないものは skip）
    }

    if (doc.frameCount() == 0) return error.MissingFrame;
    if (doc.frameCount() != declared_frames) return error.FrameCountMismatch;

    const active = doc.activeCanvas();
    if (sel_layer < active.layers.items.len) active.selected_layer = sel_layer;
    for (doc.frames.items) |c| c.markDirty(); // 直接書きした pixels の cache を無効化
    return doc;
}

/// バイト列の DOCH から canvas サイズだけを覗く（layer 復元前の size 拒否用。codex 指摘）。
pub fn peekCanvasSize(bytes: []const u8) !CanvasSize {
    const container = try serde.Container.parse(bytes, magic);
    const doch = container.find(TAG_DOC) orelse return error.MissingHeader;
    if (doch.len < 8) return error.CorruptDocument;
    return .{
        .w = std.mem.readInt(u32, doch[0..4], .little),
        .h = std.mem.readInt(u32, doch[4..8], .little),
    };
}

// ── file I/O（std.Io 経由。serde は I/O を持たない）───────────────────────

/// Document を path へ保存する（encode → writeFile）。
pub fn saveDocument(io: std.Io, path: []const u8, doc: *Document, gpa: std.mem.Allocator) !void {
    const bytes = try encodeDocument(doc, gpa);
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// path から Document を読む。expected_w/h に一致しないサイズは layer 復元前に
/// error.UnsupportedCanvasSize（0 を渡すとサイズ検査をしない＝任意サイズ許可）。
pub fn loadDocument(io: std.Io, gpa: std.mem.Allocator, path: []const u8, expected_w: u32, expected_h: u32) !Document {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    if (expected_w != 0 or expected_h != 0) {
        const sz = try peekCanvasSize(bytes);
        if (sz.w != expected_w or sz.h != expected_h) return error.UnsupportedCanvasSize;
    }
    return decodeDocument(bytes, gpa);
}

/// 各フレームを compositeStraight（フラット透明）して `<stem>_NNNN.png`（1 始まり）へ書き出す。
/// MVP 1 frame → `<stem>_0001.png`。PNG 保存規約: 白背景 composite() は使わない。
pub fn exportPngSequence(io: std.Io, stem: []const u8, doc: *Document, gpa: std.mem.Allocator) !void {
    for (doc.frames.items, 0..) |c, i| {
        const flat = c.compositeStraight();
        const path = try std.fmt.allocPrint(gpa, "{s}_{d:0>4}.png", .{ stem, i + 1 });
        defer gpa.free(path);
        try io_png.savePNG(io, path, flat, doc.width, doc.height, gpa);
    }
}

// ============================ tests ============================

const testing = std.testing;

fn fillLayer(c: *Canvas, idx: usize, color: u32) void {
    for (c.layerPixels(idx)) |*p| p.* = color;
}

test "round-trip: 多層（visible/opacity/partial-alpha/透明混在）を bit 復元 + layers.len/selected" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();
    const c = doc.activeCanvas();

    // layer0: 不透明赤で塗る
    fillLayer(c, 0, 0xFFFF0000);
    // layer1: partial-alpha + 透明混在、visible=false, opacity=128
    _ = try c.addLayer(gpa); // idx 1
    const l1 = c.layerPixels(1);
    l1[0] = 0x80112233; // partial alpha
    l1[1] = 0x00000000; // 透明
    l1[5] = 0xFF00FF00;
    c.layers.items[1].visible = false;
    c.layers.items[1].opacity = 128;
    // layer2: 単純
    _ = try c.addLayer(gpa); // idx 2
    fillLayer(c, 2, 0x40ABCDEF);
    c.selected_layer = 1;

    const bytes = try encodeDocument(&doc, gpa);
    defer gpa.free(bytes);

    var loaded = try decodeDocument(bytes, gpa);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.frameCount());
    const lc = loaded.activeCanvas();
    try testing.expectEqual(@as(usize, 3), lc.layers.items.len); // 余り層が出ない
    try testing.expectEqual(@as(usize, 1), lc.selected_layer);
    try testing.expectEqualSlices(u32, c.layers.items[0].pixels, lc.layers.items[0].pixels);
    try testing.expectEqualSlices(u32, c.layers.items[1].pixels, lc.layers.items[1].pixels);
    try testing.expectEqualSlices(u32, c.layers.items[2].pixels, lc.layers.items[2].pixels);
    try testing.expectEqual(false, lc.layers.items[1].visible);
    try testing.expectEqual(@as(u8, 128), lc.layers.items[1].opacity);
    try testing.expectEqual(true, lc.layers.items[0].visible);
    try testing.expectEqual(@as(u8, 255), lc.layers.items[0].opacity);
}

test "peekCanvasSize: DOCH の w/h を復元前に取れる" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 13, 7);
    defer doc.deinit();
    const bytes = try encodeDocument(&doc, gpa);
    defer gpa.free(bytes);
    const sz = try peekCanvasSize(bytes);
    try testing.expectEqual(@as(u32, 13), sz.w);
    try testing.expectEqual(@as(u32, 7), sz.h);
}

// ── 前方互換 / 構造違反（手書き container を serde.Writer で組む）────────────

fn layerChunk(gpa: std.mem.Allocator, w: u32, h: u32, ltype: u8, compression: u8, fill: u32) ![]u8 {
    const n: usize = @as(usize, w) * h;
    const buf = try gpa.alloc(u8, layer_header_size + n * 4);
    buf[0] = ltype;
    buf[1] = 1; // visible
    buf[2] = 255; // opacity
    buf[3] = 0;
    buf[4] = compression;
    buf[5] = 0;
    buf[6] = 0;
    buf[7] = 0;
    const px = std.mem.bytesAsSlice(u32, buf[layer_header_size..]);
    for (px) |*p| p.* = fill;
    return buf;
}

fn docChunk(w: u32, h: u32, frame_count: u32, selected: u32) [doc_header_size]u8 {
    var d: [doc_header_size]u8 = undefined;
    std.mem.writeInt(u32, d[0..4], w, .little);
    std.mem.writeInt(u32, d[4..8], h, .little);
    std.mem.writeInt(u32, d[8..12], frame_count, .little);
    std.mem.writeInt(u32, d[12..16], selected, .little);
    std.mem.writeInt(u32, d[16..20], 0, .little);
    return d;
}

fn frameChunk(idx: u32) [frame_header_size]u8 {
    var f: [frame_header_size]u8 = undefined;
    std.mem.writeInt(u32, f[0..4], idx, .little);
    std.mem.writeInt(u32, f[4..8], 0, .little);
    return f;
}

test "前方互換: 未知 chunk tag と未知 LAYR.type を skip して既知 layer を読む" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, schema_version);
    defer w.deinit();
    const doch = docChunk(2, 2, 1, 0);
    try w.addChunk(TAG_DOC, &doch);
    try w.addChunk("XxYy".*, "future-unknown"); // 未知 tag
    const frm = frameChunk(0);
    try w.addChunk(TAG_FRAME, &frm);
    const raster = try layerChunk(gpa, 2, 2, layer_type_raster, compression_raw, 0xFF010203);
    defer gpa.free(raster);
    try w.addChunk(TAG_LAYER, raster);
    const vector = try layerChunk(gpa, 2, 2, 1, compression_raw, 0xDEADBEEF); // 未知 type=1
    defer gpa.free(vector);
    try w.addChunk(TAG_LAYER, vector);
    const bytes = try w.finish();
    defer gpa.free(bytes);

    var loaded = try decodeDocument(bytes, gpa);
    defer loaded.deinit();
    const lc = loaded.activeCanvas();
    try testing.expectEqual(@as(usize, 1), lc.layers.items.len); // 未知 type は skip され raster 1 層のみ
    for (lc.layers.items[0].pixels) |p| try testing.expectEqual(@as(u32, 0xFF010203), p);
}

test "構造違反: 各エラーを返す" {
    const gpa = testing.allocator;

    // schema_version 超過
    {
        var w = try serde.Writer.init(gpa, magic, schema_version + 1);
        defer w.deinit();
        const doch = docChunk(1, 1, 1, 0);
        try w.addChunk(TAG_DOC, &doch);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.UnsupportedSchemaVersion, decodeDocument(bytes, gpa));
    }
    // DOCH 欠落（FRAM が先頭）
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        const frm = frameChunk(0);
        try w.addChunk(TAG_FRAME, &frm);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.MissingHeader, decodeDocument(bytes, gpa));
    }
    // DOCH 重複
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        const doch = docChunk(1, 1, 1, 0);
        try w.addChunk(TAG_DOC, &doch);
        try w.addChunk(TAG_DOC, &doch);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.DuplicateHeader, decodeDocument(bytes, gpa));
    }
    // LAYR が FRAM より前
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        const doch = docChunk(1, 1, 1, 0);
        try w.addChunk(TAG_DOC, &doch);
        const raster = try layerChunk(gpa, 1, 1, layer_type_raster, compression_raw, 0);
        defer gpa.free(raster);
        try w.addChunk(TAG_LAYER, raster);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.LayerBeforeFrame, decodeDocument(bytes, gpa));
    }
    // raster + compression≠raw
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        const doch = docChunk(1, 1, 1, 0);
        try w.addChunk(TAG_DOC, &doch);
        const frm = frameChunk(0);
        try w.addChunk(TAG_FRAME, &frm);
        const bad = try layerChunk(gpa, 1, 1, layer_type_raster, 1, 0); // compression=1
        defer gpa.free(bad);
        try w.addChunk(TAG_LAYER, bad);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.UnsupportedCompression, decodeDocument(bytes, gpa));
    }
    // raster payload 長不一致（宣言サイズより短い）
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        const doch = docChunk(2, 2, 1, 0); // 2x2 = 16B pixels 期待
        try w.addChunk(TAG_DOC, &doch);
        const frm = frameChunk(0);
        try w.addChunk(TAG_FRAME, &frm);
        var short: [layer_header_size + 4]u8 = undefined; // 1px 分しかない
        short[0] = layer_type_raster;
        short[1] = 1;
        short[2] = 255;
        short[3] = 0;
        short[4] = compression_raw;
        short[5] = 0;
        short[6] = 0;
        short[7] = 0;
        std.mem.writeInt(u32, short[layer_header_size..][0..4], 0, .little);
        try w.addChunk(TAG_LAYER, &short);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptLayer, decodeDocument(bytes, gpa));
    }
    // frame_count 不一致（DOCH は 2 だが FRAM 1 個）
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        const doch = docChunk(1, 1, 2, 0);
        try w.addChunk(TAG_DOC, &doch);
        const frm = frameChunk(0);
        try w.addChunk(TAG_FRAME, &frm);
        const raster = try layerChunk(gpa, 1, 1, layer_type_raster, compression_raw, 0);
        defer gpa.free(raster);
        try w.addChunk(TAG_LAYER, raster);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.FrameCountMismatch, decodeDocument(bytes, gpa));
    }
    // DOCH の余剰長（v1 は固定 20B）
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        const d = docChunk(1, 1, 1, 0);
        var big: [doc_header_size + 4]u8 = undefined;
        @memcpy(big[0..doc_header_size], &d);
        @memset(big[doc_header_size..], 0);
        try w.addChunk(TAG_DOC, &big);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptDocument, decodeDocument(bytes, gpa));
    }
    // FRAM の長さ不一致（v1 は固定 8B。len=0 でも frame 成立させない）
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        const doch = docChunk(1, 1, 1, 0);
        try w.addChunk(TAG_DOC, &doch);
        try w.addChunk(TAG_FRAME, ""); // len=0
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptFrame, decodeDocument(bytes, gpa));
    }
    // 別 app の magic（serde が BadMagic）
    {
        var w = try serde.Writer.init(gpa, 0xDEADBEEF, schema_version);
        defer w.deinit();
        const doch = docChunk(1, 1, 1, 0);
        try w.addChunk(TAG_DOC, &doch);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.BadMagic, decodeDocument(bytes, gpa));
    }
}

test "任意サイズ round-trip（document_io 自体は size 非依存。256 制限は pixie 責務）" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 3, 5);
    defer doc.deinit();
    fillLayer(doc.activeCanvas(), 0, 0xFF9988AA);
    const bytes = try encodeDocument(&doc, gpa);
    defer gpa.free(bytes);
    var loaded = try decodeDocument(bytes, gpa);
    defer loaded.deinit();
    try testing.expectEqual(@as(u32, 3), loaded.width);
    try testing.expectEqual(@as(u32, 5), loaded.height);
    try testing.expectEqualSlices(u32, doc.activeCanvas().layers.items[0].pixels, loaded.activeCanvas().layers.items[0].pixels);
}

test "file I/O: saveDocument→loadDocument 往復 + サイズ拒否 + exportPngSequence（compositeStraight 一致）" {
    const gpa = testing.allocator;
    const io = std.testing.io;
    const png = @import("png");

    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();
    const c = doc.activeCanvas();
    fillLayer(c, 0, 0xFF204060);
    _ = try c.addLayer(gpa);
    c.layerPixels(1)[0] = 0x80FF00FF;

    const pix_path = ".task63_doc_test.pix";
    defer std.Io.Dir.cwd().deleteFile(io, pix_path) catch {};
    try saveDocument(io, pix_path, &doc, gpa);

    // サイズ拒否（256 を期待 → 4x4 は弾く。layer 復元前に error）
    try testing.expectError(error.UnsupportedCanvasSize, loadDocument(io, gpa, pix_path, 256, 256));

    // 任意サイズ許可（expected 0）で往復
    var loaded = try loadDocument(io, gpa, pix_path, 0, 0);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 2), loaded.activeCanvas().layers.items.len);
    try testing.expectEqualSlices(u32, c.layers.items[0].pixels, loaded.activeCanvas().layers.items[0].pixels);
    try testing.expectEqualSlices(u32, c.layers.items[1].pixels, loaded.activeCanvas().layers.items[1].pixels);

    // exportPngSequence（1 frame → <stem>_0001.png・compositeStraight と一致）
    const stem = ".task63_seq_test";
    const seq_path = ".task63_seq_test_0001.png";
    defer std.Io.Dir.cwd().deleteFile(io, seq_path) catch {};
    try exportPngSequence(io, stem, &doc, gpa);
    const png_img = try png.decodePNGFile(io, gpa, seq_path);
    defer {
        var img = png_img;
        img.deinit(gpa);
    }
    const flat = c.compositeStraight();
    try testing.expectEqualSlices(u32, flat, png_img.pixels);
}
