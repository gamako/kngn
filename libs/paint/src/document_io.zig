//! document_io — Document の直列化（.pix プロジェクトファイル v4 schema）と PNG 連番書き出し
//! （TASK-63 で v1 導入・TASK-45.1 で v2 セルグリッド schema へ全面改訂・TASK-94 で v3=LayerId・
//! TASK-89 で v4=PLTE パレット）。
//!
//! 62.2 の `serde` versioned container（RIFF/IFF 系統）に pixie の schema を載せる。
//! serde が「コンテナ（magic/version/chunk/CRC）」を、この module が「pixie schema
//! （DOCH/LAYR/FRAM/CEL/PLTE）」を担う。serde は file I/O を持たないので、実 I/O は
//! ここで `std.Io` 経由に行う（既存 io_png.savePNG と同じ流儀）。
//!
//! **schema v4（`schema_version = 4`、現行 write）**: 任意 chunk `PLTE`（count u16 + u32×N）で
//! Document.palette を永続化（TASK-89）。空 palette は chunk 省略。v3 以前 read は palette 空。
//! netsync SYNC も本 module 経由のため palette も自動同期。
//! **互換**: v4 reader は schema 2/3/4 を読む（後方互換）。旧 reader（max schema=3）は
//! `ver > schema_version` で v4 を拒否する（前方互換ではない＝v4 ファイルを v3 reader は読めない）。
//!
//! **schema v3（read 互換）**: LayerId（安定 handle）と `next_layer_id` を永続化（TASK-94 Phase A）。
//!
//! **schema v2（read 互換）**: LayerDef を Document レベルへ（TASK-45.1）、cel の実体は grid と
//! 分離して CEL チャンクへ1回だけ書く。**id 無し**のため load 時に layer 順で決定的採番する
//! （`next_layer_id = layer_count+1`）。
//!
//! 旧 v1（`frames:[]*Canvas`、LAYR に pixels を直接埋め込む形式）の読み込み互換は**実装しない**
//! （破壊的変更。backlog task-45.1 plan §6.3/§9.7）。`decodeDocument` は schema 2/3/4 を受理し、
//! それ以外（v1・将来超過）は `error.UnsupportedSchemaVersion` で拒否する。
//!
//! フォーマット（streaming walk。すべて little-endian）:
//! - DOCH(1個・先頭):
//!   - v2=28B: width u32 | height u32 | layer_count u32 | frame_count u32
//!     | selected_layer u32 | selected_frame u32 | flags u32(予約=0)
//!   - v3=36B: 上記 + next_layer_id u64
//! - LAYR(layer_count回・DOCH直後、pixelsを含まない):
//!   - v2=8B: type u8(0=raster,1=text) | visible u8 | opacity u8 | blend u8(予約=0) | pad[4]
//!   - v3=16B: 上記 + id u64（LayerId。0=invalid は全 LAYR 読了後に max 明示 id+1 から
//!     順次再採番。非ゼロ id の重複は `error.CorruptLayer`）
//!   - LNAM(任意・対応LAYRの直後): レイヤー名 UTF-8（ヘッダなし）
//!   - LTXT(任意・LNAMの直後・kind==textのみ・16Bヘッダ+text): font_px f32(bitcast→u32,LE)
//!     | color u32(LE) | x i32(LE) | y i32(LE) | text bytes(UTF-8, ヘッダなし)
//! - FRAM(frame_count回・全LAYRの後・8B+layer_count*4B): frame_index u32 | duration_ms u32
//!   | grid[layer_count](u32 each, LE. 0xFFFFFFFF=無し・それ以外=シリアルID)
//! - CEL(K回・全FRAMの後にまとめて。K=ユニーク参照cel数・4B+W*H*4B): compression u8(0=raw)
//!   | pad[3] | pixels[W*H*4](canonical BGRA u32 の raw bytes, row-major)
//! - PLTE(任意・v4・CEL の後): count u16(LE) | colors[count] u32(LE each, canonical BGRA)
//!
//! **シリアルID圧縮**（ファイル内表現のみ。in-memory の `CelId`/`CelSetSnapshot` とは別物）:
//! encode は「FRAM を frame 順・各 frame は layer 順に走査した時の初出順」で 0 から
//! シリアル番号を振り、CEL チャンクをその順に1回だけ書く。decode はシリアルID自体を
//! そのまま新しい `CelId` として使う（CEL チャンクを出現順に cel_pool へ push すれば
//! push した順序がそのまま新しい CelId になるため、変換テーブルは不要。plan 6.1節）。
//!
//! **前方互換/構造違反（v2/v3。plan 6.2節）**:
//! - 未知 top-level tag → skip。
//! - `LAYR.type` が raster/text 以外 → **skip できない**（grid が layer_count 個の固定長配列で
//!   LAYR の出現順とインデックス対応するため）→ `error.UnsupportedLayerType` で全体拒否。
//! - `LAYR`/`FRAM`/`CEL` の payload 長不一致 → 各々 `CorruptLayer`/`CorruptFrame`/`CorruptCel`。
//! - `layer_count`/`frame_count` 宣言値と実出現数の不一致 → `LayerCountMismatch`/`FrameCountMismatch`。
//! - すべての LAYR は全ての FRAM より前に出現しなければならない → `error.LayerAfterFrame`。
//! - `FRAM.grid` のシリアルIDが実在する CEL 数以上 → `error.CorruptGrid`（dangling参照）。
//!   余剰 CEL は許容（load後 refcount=0 として自動回収）。
//! - 同一シリアルID（＝同一 CelId）が異なる複数の layer の grid から参照されている
//!   → `error.CrossLayerCelShare`（cel の共有は layer 内に閉じるという設計前提の保護。plan 4.3節）。
//! - `DOCH` 欠落/重複・`schema_version` が 2/3/4 以外は拒否。
//!
//! ホットパス宣言: 保存・読込・書き出しは **イベント時のみ**（メニュー操作 1 回）。全画素規模だが
//! フレーム毎ループではないため SIMD 3 点セット対象外。pixel payload は @memcpy 一括転送
//! （per-pixel 除算/関数呼び出し/bounds 検査なし）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const serde = @import("serde");
const canvas_mod = @import("canvas.zig");
const document_mod = @import("document.zig");
const io_png = @import("io_png.zig");
const Canvas = canvas_mod.Canvas;
const Document = document_mod.Document;
const LayerDef = document_mod.LayerDef;
const LayerId = document_mod.LayerId;
const CelId = document_mod.CelId;

/// .pix の magic（FourCC 'PIX1' の little-endian u32）。serde の expected_magic に渡す。
pub const magic: u32 = @as(u32, 'P') | (@as(u32, 'I') << 8) | (@as(u32, 'X') << 16) | (@as(u32, '1') << 24);
/// pixie schema のバージョン（serde の container_version とは別。app 管理）。
/// TASK-45.1 で v2・TASK-94 で v3（LayerId）・TASK-89 で v4（PLTE）。write は常に現行版。
pub const schema_version: u16 = 4;
/// 読み込みを受け付ける最古 schema（v2 セルグリッド）。v1 は拒否。
pub const schema_version_min: u16 = 2;
/// v3 schema 定数（read 分岐・手書き fixture 用。v2→v3 併置パターン踏襲）。
pub const schema_version_v3: u16 = 3;
/// v2 schema 定数。
pub const schema_version_v2: u16 = 2;

const TAG_DOC: [4]u8 = "DOCH".*;
const TAG_FRAME: [4]u8 = "FRAM".*;
const TAG_LAYER: [4]u8 = "LAYR".*;
const TAG_LAYER_NAME: [4]u8 = "LNAM".*;
const TAG_LAYER_TEXT: [4]u8 = "LTXT".*;
const TAG_CEL: [4]u8 = "CELS".*;
const TAG_PLTE: [4]u8 = "PLTE".*;

const doc_header_size_v2: usize = 28;
const doc_header_size_v3: usize = 36; // + next_layer_id u64（v3/v4 共通）
const doc_header_size: usize = doc_header_size_v3; // encode 用
const layer_header_size_v2: usize = 8;
const layer_header_size_v3: usize = 16; // + id u64（v3/v4 共通）
const layer_header_size: usize = layer_header_size_v3; // encode 用
const frame_header_size: usize = 8; // grid[layer_count] はこれに続く可変長部分
const cel_header_size: usize = 4;
const plte_header_size: usize = 2; // count u16
/// PLTE 色数上限（u16 全幅は拒否。DoS / 破損防御。TASK-89 review）。
const plte_max_colors: usize = 256;
const layer_type_raster: u8 = 0;
const layer_type_text: u8 = 1;
const compression_raw: u8 = 0;
/// LTXT ヘッダ長（font_px:f32 + color:u32 + x:i32 + y:i32）。残りが text bytes。
const text_header_size: usize = 16;
/// FRAM.grid の「空スロット」マーカー（実 CelId は非再利用の単調増加で高々 u32 の範囲に収まる
/// 前提。schema 上は予約値として扱う）。
const grid_none: u32 = 0xFFFFFFFF;

pub const CanvasSize = struct { w: u32, h: u32 };

// ── encode / decode（bytes ⇔ Document。file I/O なし）─────────────────────

/// Document を .pix バイト列へ直列化する（caller が free）。schema は現行版（v4）で書く。
pub fn encodeDocument(doc: *Document, gpa: Allocator) ![]u8 {
    var w = try serde.Writer.init(gpa, magic, schema_version);
    errdefer w.deinit();

    const nlayers = doc.layers.items.len;
    const nframes = doc.frames.items.len;

    var doch: [doc_header_size]u8 = undefined;
    std.mem.writeInt(u32, doch[0..4], doc.width, .little);
    std.mem.writeInt(u32, doch[4..8], doc.height, .little);
    std.mem.writeInt(u32, doch[8..12], @intCast(nlayers), .little);
    std.mem.writeInt(u32, doch[12..16], @intCast(nframes), .little);
    std.mem.writeInt(u32, doch[16..20], @intCast(doc.selected_layer), .little);
    std.mem.writeInt(u32, doch[20..24], doc.selected_frame, .little);
    std.mem.writeInt(u32, doch[24..28], 0, .little); // flags 予約
    std.mem.writeInt(u64, doch[28..36], doc.next_layer_id, .little);
    try w.addChunk(TAG_DOC, &doch);

    // LAYR(+LNAM/LTXT)。pixels は含まない（v2 の要）。v3 は id u64 を末尾に載せる。
    for (doc.layers.items) |def| {
        var lbuf: [layer_header_size]u8 = undefined;
        lbuf[0] = if (def.kind == .text) layer_type_text else layer_type_raster;
        lbuf[1] = @intFromBool(def.visible);
        lbuf[2] = def.opacity;
        lbuf[3] = 0; // blend 予約
        @memset(lbuf[4..8], 0); // pad
        std.mem.writeInt(u64, lbuf[8..16], @intFromEnum(def.id), .little);
        try w.addChunk(TAG_LAYER, &lbuf);
        try w.addChunk(TAG_LAYER_NAME, def.name());
        if (def.kind == .text) {
            const tp = def.text_params;
            const text_bytes = tp.text();
            const tbuf = try gpa.alloc(u8, text_header_size + text_bytes.len);
            defer gpa.free(tbuf);
            const px_bits: u32 = @bitCast(tp.font_px);
            std.mem.writeInt(u32, tbuf[0..4], px_bits, .little);
            std.mem.writeInt(u32, tbuf[4..8], tp.color, .little);
            std.mem.writeInt(i32, tbuf[8..12], tp.x, .little);
            std.mem.writeInt(i32, tbuf[12..16], tp.y, .little);
            @memcpy(tbuf[text_header_size..], text_bytes);
            try w.addChunk(TAG_LAYER_TEXT, tbuf);
        }
    }

    // FRAM（frame 順・各 frame は layer 順で grid を走査 = シリアルID の初出順）。
    var serial_of = try gpa.alloc(?u32, doc.cel_pool.items.len);
    defer gpa.free(serial_of);
    @memset(serial_of, null);
    var serial_order: std.ArrayList(CelId) = .empty; // シリアルID順の元 CelId（CEL 書き出し用）
    defer serial_order.deinit(gpa);

    for (0..nframes) |f| {
        const fi: u32 = @intCast(f);
        const grid_buf = try gpa.alloc(u8, frame_header_size + nlayers * 4);
        defer gpa.free(grid_buf);
        std.mem.writeInt(u32, grid_buf[0..4], fi, .little);
        std.mem.writeInt(u32, grid_buf[4..8], doc.frames.items[f].duration_ms, .little);
        for (0..nlayers) |l| {
            const maybe_id = doc.gridGet(l, fi);
            var val: u32 = grid_none;
            if (maybe_id) |id| {
                if (serial_of[id] == null) {
                    serial_of[id] = @intCast(serial_order.items.len);
                    try serial_order.append(gpa, id);
                }
                val = serial_of[id].?;
            }
            std.mem.writeInt(u32, grid_buf[frame_header_size + l * 4 ..][0..4], val, .little);
        }
        try w.addChunk(TAG_FRAME, grid_buf);
    }

    // CEL（シリアルID順に1回ずつ）。
    for (serial_order.items) |orig_id| {
        const cel = doc.cel_pool.items[orig_id].?;
        const px_bytes = std.mem.sliceAsBytes(cel.pixels);
        const buf = try gpa.alloc(u8, cel_header_size + px_bytes.len);
        defer gpa.free(buf);
        buf[0] = compression_raw;
        buf[1] = 0;
        buf[2] = 0;
        buf[3] = 0;
        @memcpy(buf[cel_header_size..], px_bytes);
        try w.addChunk(TAG_CEL, buf);
    }

    // PLTE（v4。空 = 未設定なので chunk 省略）。
    if (doc.palette.items.len > 0) {
        const n = doc.palette.items.len;
        const buf = try gpa.alloc(u8, plte_header_size + n * 4);
        defer gpa.free(buf);
        std.mem.writeInt(u16, buf[0..2], @intCast(n), .little);
        for (doc.palette.items, 0..) |c, i| {
            std.mem.writeInt(u32, buf[plte_header_size + i * 4 ..][0..4], c, .little);
        }
        try w.addChunk(TAG_PLTE, buf);
    }

    return w.finish();
}

fn readU32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}

fn readU64(b: []const u8) u64 {
    return std.mem.readInt(u64, b[0..8], .little);
}

/// .pix バイト列から Document を復元する（任意サイズ。size 制限は呼び出し側=pixie 責務）。
/// schema_version ∈ {2,3,4} を受理する（v1 / 超過は `error.UnsupportedSchemaVersion`）。
/// v2（id 無し）は layer 順に決定的採番する（TASK-94）。v3 以前は palette 空。
pub fn decodeDocument(bytes: []const u8, gpa: Allocator) !Document {
    const container = try serde.Container.parse(bytes, magic);
    const ver = container.schemaVersion();
    if (ver < schema_version_min or ver > schema_version) return error.UnsupportedSchemaVersion;
    const has_layer_ids = ver >= 3;

    var it = container.iterator();
    const first = it.next() orelse return error.MissingHeader;
    if (!std.mem.eql(u8, &first.tag, &TAG_DOC)) return error.MissingHeader;
    const expected_doch = if (has_layer_ids) doc_header_size_v3 else doc_header_size_v2;
    if (first.payload.len != expected_doch) return error.CorruptDocument;
    const width = readU32(first.payload[0..4]);
    const height = readU32(first.payload[4..8]);
    const declared_layers = readU32(first.payload[8..12]);
    const declared_frames = readU32(first.payload[12..16]);
    const sel_layer = readU32(first.payload[16..20]);
    const sel_frame = readU32(first.payload[20..24]);
    // payload[24..28] = flags（予約・未使用）
    const stored_next_layer_id: ?u64 = if (has_layer_ids) readU64(first.payload[28..36]) else null;

    var doc = try Document.initEmpty(gpa, width, height);
    errdefer doc.deinit();

    var last_layer_idx: ?usize = null;
    var layers_done = false; // true になったら以後 LAYR は構造違反
    var raw_grid: std.ArrayList(?u32) = .empty; // frame-major: [frame*declared_layers + layer]
    defer raw_grid.deinit(gpa);
    var frame_count: u32 = 0;

    const px_len: usize = @as(usize, width) * height;
    const expected_frame_payload = frame_header_size + @as(usize, declared_layers) * 4;
    const expected_cel_payload = cel_header_size + px_len * 4;
    const expected_layer_payload = if (has_layer_ids) layer_header_size_v3 else layer_header_size_v2;

    while (it.next()) |chunk| {
        if (std.mem.eql(u8, &chunk.tag, &TAG_DOC)) {
            return error.DuplicateHeader;
        } else if (std.mem.eql(u8, &chunk.tag, &TAG_LAYER)) {
            if (layers_done) return error.LayerAfterFrame;
            const p = chunk.payload;
            if (p.len != expected_layer_payload) return error.CorruptLayer;
            const t = p[0];
            if (t != layer_type_raster and t != layer_type_text) return error.UnsupportedLayerType;
            var def: LayerDef = .{ .kind = if (t == layer_type_text) .text else .raster };
            def.visible = p[1] != 0;
            def.opacity = p[2];
            // LayerId: v3 は payload から（0=invalid は読了後に再採番。非ゼロ重複は拒否）。
            // v2 は layer 順に決定的採番（TASK-94 / codex P1）。
            if (has_layer_ids) {
                const raw_id = readU64(p[8..16]);
                if (raw_id == 0) {
                    def.id = .invalid; // 全 LAYR 読了後に max 明示 id+1 から順次採番
                } else {
                    const id: LayerId = @enumFromInt(raw_id);
                    for (doc.layers.items) |existing| {
                        if (existing.id == id) return error.CorruptLayer;
                    }
                    def.id = id;
                }
            } else {
                def.id = doc.allocLayerId();
            }
            var namebuf: [24]u8 = undefined;
            const default_name = std.fmt.bufPrint(&namebuf, "Layer {d}", .{doc.layers.items.len + 1}) catch "Layer";
            def.setName(default_name);
            try doc.layers.append(gpa, def);
            last_layer_idx = doc.layers.items.len - 1;
        } else if (std.mem.eql(u8, &chunk.tag, &TAG_LAYER_NAME)) {
            // 直前が有効な LAYR だった場合のみ適用する（last_layer_idx は LNAM/LTXT では
            // リセットしない = LTXT が同じレイヤーを対象にできる。v1 と同じ安全弁）。
            if (last_layer_idx) |li| {
                if (canvas_mod.isValidLayerName(chunk.payload)) doc.layers.items[li].setName(chunk.payload);
            }
        } else if (std.mem.eql(u8, &chunk.tag, &TAG_LAYER_TEXT)) {
            if (last_layer_idx) |li| blk: {
                if (doc.layers.items[li].kind != .text) break :blk;
                const p = chunk.payload;
                if (p.len < text_header_size) break :blk;
                const px_bits = readU32(p[0..4]);
                const font_px: f32 = @bitCast(px_bits);
                if (!std.math.isFinite(font_px) or font_px <= 0) break :blk;
                const color = readU32(p[4..8]);
                const tx = std.mem.readInt(i32, p[8..12], .little);
                const ty = std.mem.readInt(i32, p[12..16], .little);
                const text_bytes = p[text_header_size..];
                if (!canvas_mod.isValidLayerName(text_bytes)) break :blk;
                var params = canvas_mod.TextParams{ .font_px = font_px, .color = color, .x = tx, .y = ty };
                params.setText(text_bytes);
                doc.layers.items[li].text_params = params;
            }
        } else if (std.mem.eql(u8, &chunk.tag, &TAG_FRAME)) {
            layers_done = true;
            const p = chunk.payload;
            if (p.len != expected_frame_payload) return error.CorruptFrame;
            const duration_ms = readU32(p[4..8]);
            try doc.frames.append(gpa, .{ .duration_ms = duration_ms });
            for (0..declared_layers) |l| {
                const v = readU32(p[frame_header_size + l * 4 ..][0..4]);
                try raw_grid.append(gpa, if (v == grid_none) null else v);
            }
            frame_count += 1;
            last_layer_idx = null;
        } else if (std.mem.eql(u8, &chunk.tag, &TAG_CEL)) {
            const p = chunk.payload;
            if (p.len != expected_cel_payload) return error.CorruptCel;
            if (p[0] != compression_raw) return error.UnsupportedCompression;
            const pixels = try gpa.alloc(u32, px_len);
            @memcpy(std.mem.sliceAsBytes(pixels), p[cel_header_size..]);
            try doc.cel_pool.append(gpa, .{ .pixels = pixels, .refcount = 0 });
            doc.next_cel_id += 1;
            last_layer_idx = null;
        } else if (std.mem.eql(u8, &chunk.tag, &TAG_PLTE)) {
            // v4 パレット（v3 以前ファイルには無い。複数 PLTE は後勝ちで置き換え）。
            const p = chunk.payload;
            if (p.len < plte_header_size) return error.CorruptPalette;
            const count: usize = std.mem.readInt(u16, p[0..2], .little);
            if (count > plte_max_colors) return error.CorruptPalette;
            if (p.len != plte_header_size + count * 4) return error.CorruptPalette;
            doc.palette.clearRetainingCapacity();
            try doc.palette.ensureTotalCapacity(gpa, count);
            for (0..count) |i| {
                const c = readU32(p[plte_header_size + i * 4 ..][0..4]);
                doc.palette.appendAssumeCapacity(c);
            }
            last_layer_idx = null;
        } else {
            last_layer_idx = null;
        }
    }

    if (doc.layers.items.len != declared_layers) return error.LayerCountMismatch;
    if (frame_count == 0) return error.MissingFrame;
    if (frame_count != declared_frames) return error.FrameCountMismatch;

    // v3: id=0（invalid）スロットを、明示 id の max+1 から layer 順に再採番する。
    // 読みながらの即時採番は後続の明示 id と衝突しうるため禁止（codex P1）。
    if (has_layer_ids) {
        var max_explicit: u64 = 0;
        for (doc.layers.items) |def| {
            const v = @intFromEnum(def.id);
            if (v > max_explicit) max_explicit = v;
        }
        var next_assign: u64 = max_explicit + 1;
        if (next_assign == 0) next_assign = 1; // 全 invalid かつ overflow 防御（通常は到達しない）
        for (doc.layers.items) |*def| {
            if (def.id == .invalid) {
                def.id = @enumFromInt(next_assign);
                next_assign += 1;
            }
        }
    }

    const nlayers = doc.layers.items.len;
    const nframes: usize = frame_count;
    const cel_count = doc.cel_pool.items.len;

    // grid（layer-major）を組み立てつつ、dangling参照・cross-layer共有・refcountを検査/計算する。
    const owner_layer = try gpa.alloc(?usize, cel_count);
    defer gpa.free(owner_layer);
    @memset(owner_layer, null);

    doc.grid.ensureTotalCapacity(gpa, nlayers * nframes) catch return error.OutOfMemory;
    for (0..nlayers) |l| {
        for (0..nframes) |f| {
            const raw = raw_grid.items[f * declared_layers + l];
            if (raw) |v| {
                if (v >= cel_count) return error.CorruptGrid;
                if (owner_layer[v]) |ol| {
                    if (ol != l) return error.CrossLayerCelShare;
                } else {
                    owner_layer[v] = l;
                }
                doc.grid.appendAssumeCapacity(v);
                doc.cel_pool.items[v].?.refcount += 1;
            } else {
                doc.grid.appendAssumeCapacity(null);
            }
        }
    }

    // 参照0の cel（余剰CEL）は自動回収（詰めない。CelId=cel_pool indexという前提を崩さない）。
    for (doc.cel_pool.items) |*maybe_cel| {
        if (maybe_cel.*) |cel| {
            if (cel.refcount == 0) {
                gpa.free(cel.pixels);
                maybe_cel.* = null;
            }
        }
    }

    // text layer の不変条件を防御的に正規化（4.4節手順5。壊れた/手編集ファイルでも
    // decode 完了時点で必ず不変条件を満たす状態へ矯正する）。
    for (0..nlayers) |l| {
        if (doc.layers.items[l].kind == .text) doc.normalizeTextLayerLinks(gpa, l);
    }

    // LayerId 採番カーソル: v3 は DOCH の next_layer_id を採用し、全 id（再採番後）の
    // max+1 未満なら防御的に引き上げる。v2 は load 中の allocLayerId で既に
    // next_layer_id = layer_count+1 になっている。
    if (stored_next_layer_id) |n| doc.next_layer_id = n;
    for (doc.layers.items) |def| {
        const v = @intFromEnum(def.id);
        if (v >= doc.next_layer_id) doc.next_layer_id = v + 1;
    }

    if (sel_layer < nlayers) doc.selected_layer = sel_layer;
    if (sel_frame < nframes) doc.selected_frame = sel_frame;

    // project load 直後（呼び出し元の3箇所のうち1つ。plan 2節）: active_view を
    // doc.layers/grid から作り直す（layer 数 reconcile + pixels/metadata 反映）。
    doc.resyncActiveView(gpa);
    return doc;
}

/// バイト列の DOCH から canvas サイズだけを覗く（layer 復元前の size 拒否用）。
pub fn peekCanvasSize(bytes: []const u8) !CanvasSize {
    const container = try serde.Container.parse(bytes, magic);
    const doch = container.find(TAG_DOC) orelse return error.MissingHeader;
    if (doch.len < 8) return error.CorruptDocument;
    return .{
        .w = readU32(doch[0..4]),
        .h = readU32(doch[4..8]),
    };
}

// ── file I/O（std.Io 経由。serde は I/O を持たない）───────────────────────

/// Document を path へ保存する（encode → writeFile）。
pub fn saveDocument(io: std.Io, path: []const u8, doc: *Document, gpa: Allocator) !void {
    const bytes = try encodeDocument(doc, gpa);
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// path から Document を読む。expected_w/h に一致しないサイズは layer 復元前に
/// error.UnsupportedCanvasSize（0 を渡すとサイズ検査をしない＝任意サイズ許可）。
pub fn loadDocument(io: std.Io, gpa: Allocator, path: []const u8, expected_w: u32, expected_h: u32) !Document {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    if (expected_w != 0 or expected_h != 0) {
        const sz = try peekCanvasSize(bytes);
        if (sz.w != expected_w or sz.h != expected_h) return error.UnsupportedCanvasSize;
    }
    return decodeDocument(bytes, gpa);
}

/// 各フレームを compositeStraight（フラット透明）して `<stem>_NNNN.png`（1 始まり）へ書き出す。
/// PNG 保存規約: 白背景 composite() は使わない。実装方式は「selected_frame 退避→各frameを
/// resync→composite→復元」（v5補遺(e)②で候補として挙げた2方式のうち前者を採用。frame数は
/// 通常小さく、composite ロジックの部分共有が要らない前者の方が実装が単純）。
pub fn exportPngSequence(io: std.Io, stem: []const u8, doc: *Document, gpa: Allocator) !void {
    const saved_frame = doc.selected_frame;
    defer {
        doc.selected_frame = saved_frame;
        doc.resyncActiveView(gpa);
    }
    for (0..doc.frames.items.len) |f| {
        doc.selected_frame = @intCast(f);
        doc.resyncActiveView(gpa);
        const flat = doc.active_view.compositeStraight();
        const path = try std.fmt.allocPrint(gpa, "{s}_{d:0>4}.png", .{ stem, f + 1 });
        defer gpa.free(path);
        try io_png.savePNG(io, path, flat, doc.width, doc.height, gpa);
    }
}

pub const SpriteSheetOpts = struct {
    columns: u32 = 0,
    margin: u32 = 0,
};

/// 全フレームを compositeStraight（フラット透明）して 1 枚のスプライトシート PNG へ書き出す。
/// `columns=0` は `ceil(sqrt(n))` を自動採用。セル間余白は `margin` px（透明）。
pub fn exportSpriteSheet(io: std.Io, path: []const u8, doc: *Document, gpa: Allocator, opts: SpriteSheetOpts) !void {
    const n_frames = doc.frames.items.len;
    if (n_frames == 0) return error.NoFrames;

    const cols: u32 = if (opts.columns == 0) blk: {
        const sqrt_n = @sqrt(@as(f64, @floatFromInt(n_frames)));
        break :blk @intFromFloat(@ceil(sqrt_n));
    } else opts.columns;
    const rows: u32 = @intCast((n_frames + @as(usize, cols) - 1) / @as(usize, cols));

    const fw: u64 = doc.width;
    const fh: u64 = doc.height;
    const margin: u64 = opts.margin;

    // 乗算・加算とも checked（巨大な columns/margin 引数でも panic せず SheetTooLarge を返す）
    const cells_w = std.math.mul(u64, cols, fw) catch return error.SheetTooLarge;
    const gaps_w = std.math.mul(u64, @as(u64, cols) -| 1, margin) catch return error.SheetTooLarge;
    const sheet_w_u64 = std.math.add(u64, cells_w, gaps_w) catch return error.SheetTooLarge;
    const cells_h = std.math.mul(u64, rows, fh) catch return error.SheetTooLarge;
    const gaps_h = std.math.mul(u64, @as(u64, rows) -| 1, margin) catch return error.SheetTooLarge;
    const sheet_h_u64 = std.math.add(u64, cells_h, gaps_h) catch return error.SheetTooLarge;
    const pixel_count_u64 = std.math.mul(u64, sheet_w_u64, sheet_h_u64) catch return error.SheetTooLarge;
    if (sheet_w_u64 > std.math.maxInt(u32) or sheet_h_u64 > std.math.maxInt(u32) or
        pixel_count_u64 > std.math.maxInt(usize))
    {
        return error.SheetTooLarge;
    }

    const sheet_w: u32 = @intCast(sheet_w_u64);
    const sheet_h: u32 = @intCast(sheet_h_u64);
    const pixel_count: usize = @intCast(pixel_count_u64);

    const buf = try gpa.alloc(u32, pixel_count);
    defer gpa.free(buf);
    @memset(buf, 0x00000000);

    const saved_frame = doc.selected_frame;
    defer {
        doc.selected_frame = saved_frame;
        doc.resyncActiveView(gpa);
    }

    const fw_usize: usize = @intCast(fw);
    const fh_usize: usize = @intCast(fh);
    const margin_usize: usize = @intCast(margin);
    const sheet_w_usize: usize = @intCast(sheet_w);

    for (0..n_frames) |f| {
        doc.selected_frame = @intCast(f);
        doc.resyncActiveView(gpa);
        const flat = doc.active_view.compositeStraight();

        const col = @as(u32, @intCast(f)) % cols;
        const row = @as(u32, @intCast(f)) / cols;
        const dst_x = @as(usize, col) * (fw_usize + margin_usize);
        const dst_y = @as(usize, row) * (fh_usize + margin_usize);

        for (0..fh_usize) |y| {
            const src_row = flat[y * fw_usize ..][0..fw_usize];
            const dst_off = (dst_y + y) * sheet_w_usize + dst_x;
            @memcpy(buf[dst_off..][0..fw_usize], src_row);
        }
    }

    try io_png.savePNG(io, path, buf, sheet_w, sheet_h, gpa);
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

    fillLayer(c, 0, 0xFFFF0000);
    try doc.pushPaintOp(gpa, 0, blk: {
        const px = c.layerPixels(0);
        const d = try gpa.alloc(document_mod.PixelDiff, px.len);
        for (px, 0..) |p, i| d[i] = .{ .idx = @intCast(i), .before = 0, .after = p };
        break :blk d;
    });
    _ = try doc.addLayer(gpa); // idx 1
    const l1 = c.layerPixels(1);
    l1[0] = 0x80112233;
    l1[1] = 0x00000000;
    l1[5] = 0xFF00FF00;
    try doc.pushPaintOp(gpa, 1, try gpa.dupe(document_mod.PixelDiff, &.{
        .{ .idx = 0, .before = 0, .after = 0x80112233 },
        .{ .idx = 5, .before = 0, .after = 0xFF00FF00 },
    }));
    try doc.setLayerVisible(gpa, 1, false);
    try doc.setLayerOpacity(gpa, 1, 128);
    _ = try doc.addLayer(gpa); // idx 2
    fillLayer(c, 2, 0x40ABCDEF);
    try doc.pushPaintOp(gpa, 2, blk: {
        const px = c.layerPixels(2);
        const d = try gpa.alloc(document_mod.PixelDiff, px.len);
        for (px, 0..) |p, i| d[i] = .{ .idx = @intCast(i), .before = 0, .after = p };
        break :blk d;
    });
    doc.selected_layer = 1;
    try doc.renameLayer(gpa, 0, "Background");
    try doc.renameLayer(gpa, 2, "あ日本語レイヤー");
    // 初回コミット時に active_view へ手で書いた pixels は既にコミット済みなので pushPaintOp 後の
    // c.layerPixels(1)/(2) は変わらない（そのまま比較対象に使える）。
    const id0 = doc.layerIdAt(0).?;
    const id1 = doc.layerIdAt(1).?;
    const id2 = doc.layerIdAt(2).?;
    const next_id = doc.next_layer_id;

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
    try testing.expectEqualStrings("Background", lc.layers.items[0].name());
    try testing.expectEqualStrings("Layer 2", lc.layers.items[1].name()); // 未リネームは既定名のまま
    try testing.expectEqualStrings("あ日本語レイヤー", lc.layers.items[2].name());
    // LayerId / next_layer_id も bit 復元（TASK-94）
    try testing.expectEqual(id0, loaded.layerIdAt(0).?);
    try testing.expectEqual(id1, loaded.layerIdAt(1).?);
    try testing.expectEqual(id2, loaded.layerIdAt(2).?);
    try testing.expectEqual(next_id, loaded.next_layer_id);
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

fn docChunk(w: u32, h: u32, layer_count: u32, frame_count: u32, selected_layer: u32, selected_frame: u32) [doc_header_size]u8 {
    return docChunkV3(w, h, layer_count, frame_count, selected_layer, selected_frame, @as(u64, layer_count) + 1);
}

fn docChunkV3(w: u32, h: u32, layer_count: u32, frame_count: u32, selected_layer: u32, selected_frame: u32, next_layer_id: u64) [doc_header_size_v3]u8 {
    var d: [doc_header_size_v3]u8 = undefined;
    std.mem.writeInt(u32, d[0..4], w, .little);
    std.mem.writeInt(u32, d[4..8], h, .little);
    std.mem.writeInt(u32, d[8..12], layer_count, .little);
    std.mem.writeInt(u32, d[12..16], frame_count, .little);
    std.mem.writeInt(u32, d[16..20], selected_layer, .little);
    std.mem.writeInt(u32, d[20..24], selected_frame, .little);
    std.mem.writeInt(u32, d[24..28], 0, .little);
    std.mem.writeInt(u64, d[28..36], next_layer_id, .little);
    return d;
}

fn docChunkV2(w: u32, h: u32, layer_count: u32, frame_count: u32, selected_layer: u32, selected_frame: u32) [doc_header_size_v2]u8 {
    var d: [doc_header_size_v2]u8 = undefined;
    std.mem.writeInt(u32, d[0..4], w, .little);
    std.mem.writeInt(u32, d[4..8], h, .little);
    std.mem.writeInt(u32, d[8..12], layer_count, .little);
    std.mem.writeInt(u32, d[12..16], frame_count, .little);
    std.mem.writeInt(u32, d[16..20], selected_layer, .little);
    std.mem.writeInt(u32, d[20..24], selected_frame, .little);
    std.mem.writeInt(u32, d[24..28], 0, .little);
    return d;
}

fn layerChunk(ltype: u8, visible: bool, opacity: u8) [layer_header_size]u8 {
    return layerChunkV3(ltype, visible, opacity, 1);
}

fn layerChunkV3(ltype: u8, visible: bool, opacity: u8, id: u64) [layer_header_size_v3]u8 {
    var b: [layer_header_size_v3]u8 = undefined;
    b[0] = ltype;
    b[1] = @intFromBool(visible);
    b[2] = opacity;
    b[3] = 0;
    @memset(b[4..8], 0);
    std.mem.writeInt(u64, b[8..16], id, .little);
    return b;
}

fn layerChunkV2(ltype: u8, visible: bool, opacity: u8) [layer_header_size_v2]u8 {
    var b: [layer_header_size_v2]u8 = undefined;
    b[0] = ltype;
    b[1] = @intFromBool(visible);
    b[2] = opacity;
    b[3] = 0;
    @memset(b[4..8], 0);
    return b;
}

/// FRAM チャンク payload を組む（frame_index + duration_ms + grid[layer_count]）。
fn frameChunk(gpa: Allocator, frame_index: u32, duration_ms: u32, grid: []const u32) ![]u8 {
    const buf = try gpa.alloc(u8, frame_header_size + grid.len * 4);
    std.mem.writeInt(u32, buf[0..4], frame_index, .little);
    std.mem.writeInt(u32, buf[4..8], duration_ms, .little);
    for (grid, 0..) |v, i| std.mem.writeInt(u32, buf[frame_header_size + i * 4 ..][0..4], v, .little);
    return buf;
}

fn celChunk(gpa: Allocator, w: u32, h: u32, fill: u32) ![]u8 {
    const n: usize = @as(usize, w) * h;
    const buf = try gpa.alloc(u8, cel_header_size + n * 4);
    buf[0] = compression_raw;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 0;
    const px = std.mem.bytesAsSlice(u32, buf[cel_header_size..]);
    for (px) |*p| p.* = fill;
    return buf;
}

fn textChunk(gpa: Allocator, font_px: f32, color: u32, x: i32, y: i32, text: []const u8) ![]u8 {
    const buf = try gpa.alloc(u8, text_header_size + text.len);
    const px_bits: u32 = @bitCast(font_px);
    std.mem.writeInt(u32, buf[0..4], px_bits, .little);
    std.mem.writeInt(u32, buf[4..8], color, .little);
    std.mem.writeInt(i32, buf[8..12], x, .little);
    std.mem.writeInt(i32, buf[12..16], y, .little);
    @memcpy(buf[text_header_size..], text);
    return buf;
}

test "前方互換: 未知 chunk tag を skip して既知 layer/frame/cel を読む" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, schema_version);
    defer w.deinit();
    const doch = docChunk(2, 2, 1, 1, 0, 0);
    try w.addChunk(TAG_DOC, &doch);
    try w.addChunk("XxYy".*, "future-unknown");
    const lay = layerChunk(layer_type_raster, true, 255);
    try w.addChunk(TAG_LAYER, &lay);
    const frm = try frameChunk(gpa, 0, 100, &.{0});
    defer gpa.free(frm);
    try w.addChunk(TAG_FRAME, frm);
    const cel = try celChunk(gpa, 2, 2, 0xFF010203);
    defer gpa.free(cel);
    try w.addChunk(TAG_CEL, cel);
    const bytes = try w.finish();
    defer gpa.free(bytes);

    var loaded = try decodeDocument(bytes, gpa);
    defer loaded.deinit();
    const lc = loaded.activeCanvas();
    try testing.expectEqual(@as(usize, 1), lc.layers.items.len);
    for (lc.layers.items[0].pixels) |p| try testing.expectEqual(@as(u32, 0xFF010203), p);
}

test "v1 schema は明示エラーで拒否される（v1互換は実装しない。plan §9.7 破壊的変更）" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, 1); // schema_version=1（旧形式相当）
    defer w.deinit();
    const doch = docChunk(1, 1, 1, 1, 0, 0);
    try w.addChunk(TAG_DOC, &doch);
    const bytes = try w.finish();
    defer gpa.free(bytes);
    try testing.expectError(error.UnsupportedSchemaVersion, decodeDocument(bytes, gpa));
}

test "schema_version 超過も拒否される" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, schema_version + 1);
    defer w.deinit();
    const doch = docChunk(1, 1, 1, 1, 0, 0);
    try w.addChunk(TAG_DOC, &doch);
    const bytes = try w.finish();
    defer gpa.free(bytes);
    try testing.expectError(error.UnsupportedSchemaVersion, decodeDocument(bytes, gpa));
}

test "LNAM/LTXT: round-trip で text kind/text_params が bit 復元される" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 8, 4);
    defer doc.deinit();

    var params = canvas_mod.TextParams{ .font_px = 24.5, .color = 0xFFAABBCC, .x = 3, .y = -2 };
    params.setText("Hi あ");
    const idx = try doc.addTextLayer(gpa, params);
    try doc.renameLayer(gpa, idx, "Label");

    const bytes = try encodeDocument(&doc, gpa);
    defer gpa.free(bytes);

    var loaded = try decodeDocument(bytes, gpa);
    defer loaded.deinit();
    const lc = loaded.activeCanvas();
    try testing.expectEqual(canvas_mod.LayerKind.text, lc.layers.items[idx].kind);
    try testing.expect(lc.layers.items[idx].text_params.eql(params));
    try testing.expectEqualStrings("Label", lc.layers.items[idx].name());
    try testing.expectEqualSlices(u32, doc.activeCanvas().layerPixels(idx), lc.layerPixels(idx));
}

test "構造違反: 各エラーを返す" {
    const gpa = testing.allocator;

    // DOCH 欠落（FRAM が先頭）
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        const frm = try frameChunk(gpa, 0, 100, &.{});
        defer gpa.free(frm);
        try w.addChunk(TAG_FRAME, frm);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.MissingHeader, decodeDocument(bytes, gpa));
    }
    // DOCH 重複
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        const doch = docChunk(1, 1, 0, 1, 0, 0);
        try w.addChunk(TAG_DOC, &doch);
        try w.addChunk(TAG_DOC, &doch);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.DuplicateHeader, decodeDocument(bytes, gpa));
    }
    // 未知 LAYR.type
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        const doch = docChunk(1, 1, 1, 1, 0, 0);
        try w.addChunk(TAG_DOC, &doch);
        const lay = layerChunk(2, true, 255); // type=2 は未知
        try w.addChunk(TAG_LAYER, &lay);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.UnsupportedLayerType, decodeDocument(bytes, gpa));
    }
    // LAYR が FRAM の後（構造違反）
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        const doch = docChunk(1, 1, 1, 1, 0, 0);
        try w.addChunk(TAG_DOC, &doch);
        const frm = try frameChunk(gpa, 0, 100, &.{grid_none});
        defer gpa.free(frm);
        try w.addChunk(TAG_FRAME, frm);
        const lay = layerChunk(layer_type_raster, true, 255);
        try w.addChunk(TAG_LAYER, &lay);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.LayerAfterFrame, decodeDocument(bytes, gpa));
    }
    // CEL + compression != raw
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        const doch = docChunk(1, 1, 1, 1, 0, 0);
        try w.addChunk(TAG_DOC, &doch);
        const lay = layerChunk(layer_type_raster, true, 255);
        try w.addChunk(TAG_LAYER, &lay);
        const frm = try frameChunk(gpa, 0, 100, &.{0});
        defer gpa.free(frm);
        try w.addChunk(TAG_FRAME, frm);
        var cel = try celChunk(gpa, 1, 1, 0);
        defer gpa.free(cel);
        cel[0] = 1; // compression != raw
        try w.addChunk(TAG_CEL, cel);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.UnsupportedCompression, decodeDocument(bytes, gpa));
    }
    // CEL payload 長不一致
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        const doch = docChunk(2, 2, 1, 1, 0, 0); // 2x2=16B pixels 期待
        try w.addChunk(TAG_DOC, &doch);
        const lay = layerChunk(layer_type_raster, true, 255);
        try w.addChunk(TAG_LAYER, &lay);
        const frm = try frameChunk(gpa, 0, 100, &.{0});
        defer gpa.free(frm);
        try w.addChunk(TAG_FRAME, frm);
        var short: [cel_header_size + 4]u8 = undefined; // 1px 分しかない
        short[0] = compression_raw;
        short[1] = 0;
        short[2] = 0;
        short[3] = 0;
        std.mem.writeInt(u32, short[cel_header_size..][0..4], 0, .little);
        try w.addChunk(TAG_CEL, &short);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptCel, decodeDocument(bytes, gpa));
    }
    // frame_count 不一致（DOCH は 2 だが FRAM 1 個）
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        const doch = docChunk(1, 1, 1, 2, 0, 0);
        try w.addChunk(TAG_DOC, &doch);
        const lay = layerChunk(layer_type_raster, true, 255);
        try w.addChunk(TAG_LAYER, &lay);
        const frm = try frameChunk(gpa, 0, 100, &.{grid_none});
        defer gpa.free(frm);
        try w.addChunk(TAG_FRAME, frm);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.FrameCountMismatch, decodeDocument(bytes, gpa));
    }
    // layer_count 不一致（DOCH は 2 だが LAYR 1 個）
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        const doch = docChunk(1, 1, 2, 1, 0, 0);
        try w.addChunk(TAG_DOC, &doch);
        const lay = layerChunk(layer_type_raster, true, 255);
        try w.addChunk(TAG_LAYER, &lay);
        const frm = try frameChunk(gpa, 0, 100, &.{ grid_none, grid_none });
        defer gpa.free(frm);
        try w.addChunk(TAG_FRAME, frm);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.LayerCountMismatch, decodeDocument(bytes, gpa));
    }
    // FRAM の grid が dangling 参照（CEL 未出現のシリアルIDを参照）
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        const doch = docChunk(1, 1, 1, 1, 0, 0);
        try w.addChunk(TAG_DOC, &doch);
        const lay = layerChunk(layer_type_raster, true, 255);
        try w.addChunk(TAG_LAYER, &lay);
        const frm = try frameChunk(gpa, 0, 100, &.{0}); // serial 0 だが CEL が無い
        defer gpa.free(frm);
        try w.addChunk(TAG_FRAME, frm);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptGrid, decodeDocument(bytes, gpa));
    }
    // 別 app の magic（serde が BadMagic）
    {
        var w = try serde.Writer.init(gpa, 0xDEADBEEF, schema_version);
        defer w.deinit();
        const doch = docChunk(1, 1, 1, 1, 0, 0);
        try w.addChunk(TAG_DOC, &doch);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.BadMagic, decodeDocument(bytes, gpa));
    }
}

test "decode: cross-layer CelId 共有は拒否される（同一シリアルIDを異なるlayerが参照）" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, schema_version);
    defer w.deinit();
    const doch = docChunk(1, 1, 2, 1, 0, 0); // 2 layer / 1 frame
    try w.addChunk(TAG_DOC, &doch);
    const lay0 = layerChunkV3(layer_type_raster, true, 255, 1);
    try w.addChunk(TAG_LAYER, &lay0);
    const lay1 = layerChunkV3(layer_type_raster, true, 255, 2);
    try w.addChunk(TAG_LAYER, &lay1);
    // frame0: layer0=serial0, layer1=serial0（同じシリアルIDを異なるlayerが参照）
    const frm = try frameChunk(gpa, 0, 100, &.{ 0, 0 });
    defer gpa.free(frm);
    try w.addChunk(TAG_FRAME, frm);
    const cel = try celChunk(gpa, 1, 1, 0xFF112233);
    defer gpa.free(cel);
    try w.addChunk(TAG_CEL, cel);
    const bytes = try w.finish();
    defer gpa.free(bytes);
    try testing.expectError(error.CrossLayerCelShare, decodeDocument(bytes, gpa));
}

test "decode: 余剰CEL(参照0)は自動回収される（refcount=0でnull化）" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, schema_version);
    defer w.deinit();
    const doch = docChunk(1, 1, 1, 1, 0, 0);
    try w.addChunk(TAG_DOC, &doch);
    const lay = layerChunk(layer_type_raster, true, 255);
    try w.addChunk(TAG_LAYER, &lay);
    const frm = try frameChunk(gpa, 0, 100, &.{grid_none}); // 参照なし
    defer gpa.free(frm);
    try w.addChunk(TAG_FRAME, frm);
    const cel = try celChunk(gpa, 1, 1, 0xFF112233); // 誰も参照しない余剰CEL
    defer gpa.free(cel);
    try w.addChunk(TAG_CEL, cel);
    const bytes = try w.finish();
    defer gpa.free(bytes);

    var loaded = try decodeDocument(bytes, gpa);
    defer loaded.deinit();
    // grid は null のまま（余剰CELは参照されない）
    try testing.expect(loaded.gridGet(0, 0) == null);
}

test "decode時のtext layer防御的正規化: 壊れたリンク状態を最初のnon-nullで矯正する" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, schema_version);
    defer w.deinit();
    const doch = docChunk(1, 1, 1, 2, 0, 0); // 1 layer(text) / 2 frame
    try w.addChunk(TAG_DOC, &doch);
    const lay = layerChunk(layer_type_text, true, 255);
    try w.addChunk(TAG_LAYER, &lay);
    try w.addChunk(TAG_LAYER_NAME, "T");
    const txt = try textChunk(gpa, 12, 0xFFFFFFFF, 0, 0, "X");
    defer gpa.free(txt);
    try w.addChunk(TAG_LAYER_TEXT, txt);
    // frame0=serial0, frame1=serial1（本来は同一を共有すべきだが壊れて別々を指す）
    const frm0 = try frameChunk(gpa, 0, 100, &.{0});
    defer gpa.free(frm0);
    try w.addChunk(TAG_FRAME, frm0);
    const frm1 = try frameChunk(gpa, 1, 100, &.{1});
    defer gpa.free(frm1);
    try w.addChunk(TAG_FRAME, frm1);
    const cel0 = try celChunk(gpa, 1, 1, 0xFFAAAAAA);
    defer gpa.free(cel0);
    try w.addChunk(TAG_CEL, cel0);
    const cel1 = try celChunk(gpa, 1, 1, 0xFFBBBBBB);
    defer gpa.free(cel1);
    try w.addChunk(TAG_CEL, cel1);
    const bytes = try w.finish();
    defer gpa.free(bytes);

    var loaded = try decodeDocument(bytes, gpa);
    defer loaded.deinit();
    // 正規化により両frameが同一CelIdを指す（最初に見つかったnon-null=frame0のcelが正典）
    const id0 = loaded.gridGet(0, 0);
    const id1 = loaded.gridGet(0, 1);
    try testing.expect(id0 != null and id1 != null);
    try testing.expectEqual(id0.?, id1.?);
}

test "任意サイズ round-trip（document_io 自体は size 非依存。256 制限は pixie 責務）" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 3, 5);
    defer doc.deinit();
    try doc.pushPaintOp(gpa, 0, blk: {
        const px = doc.activeCanvas().layerPixels(0);
        const d = try gpa.alloc(document_mod.PixelDiff, px.len);
        for (0..px.len) |i| d[i] = .{ .idx = @intCast(i), .before = 0, .after = 0xFF9988AA };
        break :blk d;
    });
    const bytes = try encodeDocument(&doc, gpa);
    defer gpa.free(bytes);
    var loaded = try decodeDocument(bytes, gpa);
    defer loaded.deinit();
    try testing.expectEqual(@as(u32, 3), loaded.width);
    try testing.expectEqual(@as(u32, 5), loaded.height);
    try testing.expectEqualSlices(u32, doc.activeCanvas().layerPixels(0), loaded.activeCanvas().layerPixels(0));
}

// TASK-95: PNG open 相当（reset → active_view 直書き → commitActiveLayerToCel）後に
// saveDocument → loadDocument で pixels が bit 一致すること（cel 未書き戻しだと空 .pix になる）。
test "TASK-95: reset + layerPixels 直書き + commitActiveLayerToCel → save/load pixels bit 一致" {
    const gpa = testing.allocator;
    const io = std.testing.io;

    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();
    _ = try doc.addLayer(gpa); // multi-layer から open 相当の縮退を再現
    doc.resetToSingleBlankLayer(gpa);
    try testing.expectEqual(@as(u32, 0), doc.selected_frame);
    try testing.expectEqual(@as(usize, 1), doc.layers.items.len);
    try testing.expectEqual(@as(usize, 0), doc.cel_pool.items.len); // reset 直後は cel 0 個

    const color: u32 = 0xFF112233;
    const px = doc.activeCanvas().layerPixels(0);
    @memset(px, color);

    doc.commitActiveLayerToCel(gpa, 0);
    const cel_id = doc.gridGet(0, 0).?;
    try testing.expectEqualSlices(u32, px, doc.celPixels(cel_id).?);

    // cwd 固定名は並列テストバイナリ間で race する（TASK-96 で実測）ため tmpDir で分離する。
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const pix_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/task95_open_commit.pix", .{&tmp.sub_path});
    try saveDocument(io, pix_path, &doc, gpa);

    var loaded = try loadDocument(io, gpa, pix_path, 4, 4);
    defer loaded.deinit();
    try testing.expectEqualSlices(u32, px, loaded.activeCanvas().layerPixels(0));
    // cel 経由でも同一（save が cel_pool を書いた証拠）
    try testing.expectEqualSlices(u32, px, loaded.celPixels(loaded.gridGet(0, 0).?).?);
}

test "LayerId: .pix v3 round-trip で id/next_layer_id 保持 + reorder 後も id 安定" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 2, 2);
    defer doc.deinit();
    _ = try doc.addLayer(gpa);
    _ = try doc.addLayer(gpa);
    const id0 = doc.layerIdAt(0).?;
    const id1 = doc.layerIdAt(1).?;
    const id2 = doc.layerIdAt(2).?;
    try doc.reorderLayer(gpa, 0, 2); // [id1, id2, id0]
    try doc.setLayerVisible(gpa, 0, false);
    const next_before = doc.next_layer_id;

    const bytes = try encodeDocument(&doc, gpa);
    defer gpa.free(bytes);
    // schema が現行 v3 であること
    const container = try serde.Container.parse(bytes, magic);
    try testing.expectEqual(schema_version, container.schemaVersion());

    var loaded = try decodeDocument(bytes, gpa);
    defer loaded.deinit();
    try testing.expectEqual(id1, loaded.layerIdAt(0).?);
    try testing.expectEqual(id2, loaded.layerIdAt(1).?);
    try testing.expectEqual(id0, loaded.layerIdAt(2).?);
    try testing.expectEqual(@as(?usize, 2), loaded.layerIndexOf(id0));
    try testing.expectEqual(@as(?usize, 0), loaded.layerIndexOf(id1));
    try testing.expectEqual(next_before, loaded.next_layer_id);
    try testing.expectEqual(false, loaded.layers.items[0].visible);
    // load 後の add は next_layer_id から継続（衝突なし）
    const idx = try loaded.addLayer(gpa);
    try testing.expectEqual(@as(LayerId, @enumFromInt(next_before)), loaded.layerIdAt(idx).?);
}

test "LayerId: 旧 schema v2 fixture は layer 順に決定的採番（fallback）" {
    const gpa = testing.allocator;
    // 手書き v2 container（LAYR 8B・DOCH 28B・id 無し）
    var w = try serde.Writer.init(gpa, magic, 2);
    defer w.deinit();
    const doch = docChunkV2(2, 2, 2, 1, 0, 0);
    try w.addChunk(TAG_DOC, &doch);
    const lay0 = layerChunkV2(layer_type_raster, true, 255);
    try w.addChunk(TAG_LAYER, &lay0);
    try w.addChunk(TAG_LAYER_NAME, "A");
    const lay1 = layerChunkV2(layer_type_raster, false, 128);
    try w.addChunk(TAG_LAYER, &lay1);
    try w.addChunk(TAG_LAYER_NAME, "B");
    const frm = try frameChunk(gpa, 0, 100, &.{ grid_none, grid_none });
    defer gpa.free(frm);
    try w.addChunk(TAG_FRAME, frm);
    const bytes = try w.finish();
    defer gpa.free(bytes);

    var loaded = try decodeDocument(bytes, gpa);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 2), loaded.layers.items.len);
    // layer 順に 1, 2 を決定的採番
    try testing.expectEqual(@as(LayerId, @enumFromInt(1)), loaded.layerIdAt(0).?);
    try testing.expectEqual(@as(LayerId, @enumFromInt(2)), loaded.layerIdAt(1).?);
    try testing.expectEqual(@as(u64, 3), loaded.next_layer_id);
    try testing.expectEqualStrings("A", loaded.layers.items[0].name());
    try testing.expectEqualStrings("B", loaded.layers.items[1].name());
    try testing.expectEqual(false, loaded.layers.items[1].visible);
    try testing.expectEqual(@as(u8, 128), loaded.layers.items[1].opacity);
}

test "LayerId: v3 重複 id は CorruptLayer で拒否" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, schema_version);
    defer w.deinit();
    // ids=[7,7] → layerIndexOf が先頭だけ返す危険を拒否する
    const doch = docChunkV3(1, 1, 2, 1, 0, 0, 8);
    try w.addChunk(TAG_DOC, &doch);
    const lay0 = layerChunkV3(layer_type_raster, true, 255, 7);
    try w.addChunk(TAG_LAYER, &lay0);
    const lay1 = layerChunkV3(layer_type_raster, true, 255, 7);
    try w.addChunk(TAG_LAYER, &lay1);
    const frm = try frameChunk(gpa, 0, 100, &.{ grid_none, grid_none });
    defer gpa.free(frm);
    try w.addChunk(TAG_FRAME, frm);
    const bytes = try w.finish();
    defer gpa.free(bytes);
    try testing.expectError(error.CorruptLayer, decodeDocument(bytes, gpa));
}

test "LayerId: v3 id=0 混在は明示 id と衝突しない max+1 から再採番" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, schema_version);
    defer w.deinit();
    // ids=[0, 5, 0] → 旧実装は読みながら 1 を割り当てて明示 id=1 と衝突し得た。
    // 新実装: 明示 max=5 → invalid を 6, 7 へ layer 順に採番 → [6, 5, 7]
    const doch = docChunkV3(1, 1, 3, 1, 0, 0, 1); // stored next は小さくても防御的に引き上げ
    try w.addChunk(TAG_DOC, &doch);
    const lay0 = layerChunkV3(layer_type_raster, true, 255, 0);
    try w.addChunk(TAG_LAYER, &lay0);
    try w.addChunk(TAG_LAYER_NAME, "zero0");
    const lay1 = layerChunkV3(layer_type_raster, true, 128, 5);
    try w.addChunk(TAG_LAYER, &lay1);
    try w.addChunk(TAG_LAYER_NAME, "five");
    const lay2 = layerChunkV3(layer_type_raster, false, 200, 0);
    try w.addChunk(TAG_LAYER, &lay2);
    try w.addChunk(TAG_LAYER_NAME, "zero1");
    const frm = try frameChunk(gpa, 0, 100, &.{ grid_none, grid_none, grid_none });
    defer gpa.free(frm);
    try w.addChunk(TAG_FRAME, frm);
    const bytes = try w.finish();
    defer gpa.free(bytes);

    var loaded = try decodeDocument(bytes, gpa);
    defer loaded.deinit();
    try testing.expectEqual(@as(LayerId, @enumFromInt(6)), loaded.layerIdAt(0).?);
    try testing.expectEqual(@as(LayerId, @enumFromInt(5)), loaded.layerIdAt(1).?);
    try testing.expectEqual(@as(LayerId, @enumFromInt(7)), loaded.layerIdAt(2).?);
    // 各 id は一意に解決される
    try testing.expectEqual(@as(?usize, 0), loaded.layerIndexOf(@as(LayerId, @enumFromInt(6))));
    try testing.expectEqual(@as(?usize, 1), loaded.layerIndexOf(@as(LayerId, @enumFromInt(5))));
    try testing.expectEqual(@as(?usize, 2), loaded.layerIndexOf(@as(LayerId, @enumFromInt(7))));
    try testing.expectEqual(@as(u64, 8), loaded.next_layer_id); // max(7)+1（stored=1 を引き上げ）
    try testing.expectEqualStrings("zero0", loaded.layers.items[0].name());
    try testing.expectEqualStrings("five", loaded.layers.items[1].name());
    try testing.expectEqualStrings("zero1", loaded.layers.items[2].name());
}

test "file I/O: saveDocument→loadDocument 往復 + サイズ拒否 + exportPngSequence（compositeStraight 一致）" {
    const gpa = testing.allocator;
    const io = std.testing.io;
    const png = @import("png");

    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();
    const c = doc.activeCanvas();
    try doc.pushPaintOp(gpa, 0, blk: {
        const px = c.layerPixels(0);
        const d = try gpa.alloc(document_mod.PixelDiff, px.len);
        for (0..px.len) |i| d[i] = .{ .idx = @intCast(i), .before = 0, .after = 0xFF204060 };
        break :blk d;
    });
    _ = try doc.addLayer(gpa);
    try doc.pushPaintOp(gpa, 1, try gpa.dupe(document_mod.PixelDiff, &.{
        .{ .idx = 0, .before = 0, .after = 0x80FF00FF },
    }));

    const pix_path = ".task45_doc_test.pix";
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
    const stem = ".task45_seq_test";
    const seq_path = ".task45_seq_test_0001.png";
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

fn paintFramePixel(doc: *Document, gpa: Allocator, frame_idx: u32, color: u32) !void {
    doc.selected_frame = frame_idx;
    doc.resyncActiveView(gpa);
    const px = doc.activeCanvas().layerPixels(0);
    px[0] = color;
    try doc.pushPaintOp(gpa, 0, try gpa.dupe(document_mod.PixelDiff, &.{
        .{ .idx = 0, .before = 0, .after = color },
    }));
}

test "exportSpriteSheet: 2x2 配置・1 frame 恒等・margin・columns 指定・frame 0 はエラー" {
    const gpa = testing.allocator;
    const io = std.testing.io;
    const png = @import("png");

    // frame 数 0 は拒否
    var empty = try Document.initEmpty(gpa, 2, 2);
    defer empty.deinit();
    try testing.expectError(error.NoFrames, exportSpriteSheet(io, ".task45_sheet_empty.png", &empty, gpa, .{}));

    // 1 frame 恒等（columns 自動 = 1）
    var one = try Document.init(gpa, 2, 2);
    defer one.deinit();
    try paintFramePixel(&one, gpa, 0, 0xFFFF0000);
    const one_path = ".task45_sheet_one.png";
    defer std.Io.Dir.cwd().deleteFile(io, one_path) catch {};
    try exportSpriteSheet(io, one_path, &one, gpa, .{});
    const one_img = try png.decodePNGFile(io, gpa, one_path);
    defer {
        var img = one_img;
        img.deinit(gpa);
    }
    try testing.expectEqual(@as(u32, 2), one_img.width);
    try testing.expectEqual(@as(u32, 2), one_img.height);
    try testing.expectEqual(@as(u32, 0xFFFF0000), one_img.pixels[0]);

    // 2x2 配置（4 frame・2x2 canvas・columns=2）
    var doc = try Document.init(gpa, 2, 2);
    defer doc.deinit();
    const colors = [_]u32{ 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF };
    try paintFramePixel(&doc, gpa, 0, colors[0]);
    for (1..4) |fi| {
        try doc.addFrame(gpa, @intCast(fi));
        try paintFramePixel(&doc, gpa, @intCast(fi), colors[fi]);
    }
    const sheet_path = ".task45_sheet_2x2.png";
    defer std.Io.Dir.cwd().deleteFile(io, sheet_path) catch {};
    try exportSpriteSheet(io, sheet_path, &doc, gpa, .{ .columns = 2 });
    const sheet = try png.decodePNGFile(io, gpa, sheet_path);
    defer {
        var img = sheet;
        img.deinit(gpa);
    }
    try testing.expectEqual(@as(u32, 4), sheet.width);
    try testing.expectEqual(@as(u32, 4), sheet.height);
    // 各フレームの (0,0) ピクセルが格子位置へ配置される
    try testing.expectEqual(colors[0], sheet.pixels[0]); // (0,0)
    try testing.expectEqual(colors[1], sheet.pixels[2]); // (2,0)
    try testing.expectEqual(colors[2], sheet.pixels[8]); // (0,2) = row 2 * width 4
    try testing.expectEqual(colors[3], sheet.pixels[10]); // (2,2)

    // margin 付き（2 frame・1x2 canvas・columns=2・margin=1）
    var margin_doc = try Document.init(gpa, 1, 2);
    defer margin_doc.deinit();
    try paintFramePixel(&margin_doc, gpa, 0, 0xFFFF0000);
    try margin_doc.addFrame(gpa, 1);
    try paintFramePixel(&margin_doc, gpa, 1, 0xFF00FF00);
    const margin_path = ".task45_sheet_margin.png";
    defer std.Io.Dir.cwd().deleteFile(io, margin_path) catch {};
    try exportSpriteSheet(io, margin_path, &margin_doc, gpa, .{ .columns = 2, .margin = 1 });
    const margin_img = try png.decodePNGFile(io, gpa, margin_path);
    defer {
        var img = margin_img;
        img.deinit(gpa);
    }
    // width = 2*1 + 1*1 = 3, height = 1*2 = 2
    try testing.expectEqual(@as(u32, 3), margin_img.width);
    try testing.expectEqual(@as(u32, 2), margin_img.height);
    try testing.expectEqual(@as(u32, 0xFFFF0000), margin_img.pixels[0]);
    try testing.expectEqual(@as(u32, 0xFF00FF00), margin_img.pixels[2]); // x = 1 + 1 margin
}

test "exportSpriteSheet: 巨大 columns/margin は SheetTooLarge（checked 演算・panic しない）" {
    const gpa = testing.allocator;
    const io = std.testing.io;
    var doc = try Document.init(gpa, 2, 2);
    defer doc.deinit();
    try testing.expectError(error.SheetTooLarge, exportSpriteSheet(io, ".task45_sheet_huge.png", &doc, gpa, .{
        .columns = std.math.maxInt(u32),
        .margin = std.math.maxInt(u32),
    }));
}

// ── TASK-89: v4 PLTE ──────────────────────────────────────────────────

test "v4 PLTE: palette round-trip" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 2, 2);
    defer doc.deinit();
    try doc.palette.append(gpa, 0xFFFF0000);
    try doc.palette.append(gpa, 0xFF00FF00);
    try doc.palette.append(gpa, 0xFF0000FF);

    const bytes = try encodeDocument(&doc, gpa);
    defer gpa.free(bytes);
    // 現行 write は schema v4
    const container = try serde.Container.parse(bytes, magic);
    try testing.expectEqual(schema_version, container.schemaVersion());

    var loaded = try decodeDocument(bytes, gpa);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 3), loaded.palette.items.len);
    try testing.expectEqual(@as(u32, 0xFFFF0000), loaded.palette.items[0]);
    try testing.expectEqual(@as(u32, 0xFF00FF00), loaded.palette.items[1]);
    try testing.expectEqual(@as(u32, 0xFF0000FF), loaded.palette.items[2]);
}

test "v3 読み: palette は空（PLTE 無し）" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, schema_version_v3);
    defer w.deinit();
    const doch = docChunkV3(2, 2, 1, 1, 0, 0, 2);
    try w.addChunk(TAG_DOC, &doch);
    const lay = layerChunkV3(layer_type_raster, true, 255, 1);
    try w.addChunk(TAG_LAYER, &lay);
    const frm = try frameChunk(gpa, 0, 100, &.{grid_none});
    defer gpa.free(frm);
    try w.addChunk(TAG_FRAME, frm);
    const bytes = try w.finish();
    defer gpa.free(bytes);

    var loaded = try decodeDocument(bytes, gpa);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 0), loaded.palette.items.len);
    try testing.expectEqual(@as(usize, 1), loaded.layers.items.len);
}

test "v4: 空 palette は PLTE 省略・round-trip で空" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 2, 2);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.palette.items.len);
    const bytes = try encodeDocument(&doc, gpa);
    defer gpa.free(bytes);
    var loaded = try decodeDocument(bytes, gpa);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 0), loaded.palette.items.len);
}

test "未知 chunk 後も PLTE を読む（同一 schema 内の tag skip）" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, schema_version);
    defer w.deinit();
    const doch = docChunk(2, 2, 1, 1, 0, 0);
    try w.addChunk(TAG_DOC, &doch);
    const lay = layerChunk(layer_type_raster, true, 255);
    try w.addChunk(TAG_LAYER, &lay);
    const frm = try frameChunk(gpa, 0, 100, &.{grid_none});
    defer gpa.free(frm);
    try w.addChunk(TAG_FRAME, frm);
    try w.addChunk("XxYy".*, "future");
    var plte: [2 + 4]u8 = undefined;
    std.mem.writeInt(u16, plte[0..2], 1, .little);
    std.mem.writeInt(u32, plte[2..6], 0xFFAABBCC, .little);
    try w.addChunk(TAG_PLTE, &plte);
    const bytes = try w.finish();
    defer gpa.free(bytes);

    var loaded = try decodeDocument(bytes, gpa);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.palette.items.len);
    try testing.expectEqual(@as(u32, 0xFFAABBCC), loaded.palette.items[0]);
}

test "PLTE: 256 色超は CorruptPalette" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, schema_version);
    defer w.deinit();
    const doch = docChunk(1, 1, 1, 1, 0, 0);
    try w.addChunk(TAG_DOC, &doch);
    const lay = layerChunk(layer_type_raster, true, 255);
    try w.addChunk(TAG_LAYER, &lay);
    const frm = try frameChunk(gpa, 0, 100, &.{grid_none});
    defer gpa.free(frm);
    try w.addChunk(TAG_FRAME, frm);
    const count: u16 = 257;
    const plte = try gpa.alloc(u8, 2 + @as(usize, count) * 4);
    defer gpa.free(plte);
    std.mem.writeInt(u16, plte[0..2], count, .little);
    @memset(plte[2..], 0);
    try w.addChunk(TAG_PLTE, plte);
    const bytes = try w.finish();
    defer gpa.free(bytes);
    try testing.expectError(error.CorruptPalette, decodeDocument(bytes, gpa));
}
