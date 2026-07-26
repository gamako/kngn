//! document_io — Document serialization (.pix project file v4 schema) and PNG sequence export
//! (v1 introduced; v2 cell-grid schema rewrite; v3=LayerId;
//! v4=PLTE palette).
//!
//! Loads pixie's schema onto the `serde` versioned container (RIFF/IFF lineage).
//! serde owns the container (magic/version/chunk/CRC); this module owns the pixie schema
//! (DOCH/LAYR/FRAM/CELS/PLTE). serde has no file I/O, so real I/O goes
//! through `std.Io` here (same style as existing io_png.savePNG).
//!
//! **schema v4 (`schema_version = 4`, current write)**: optional chunk `PLTE` (count u16 + u32×N)
//! persists Document.palette. Empty palette omits the chunk. Reads of v3 and older get an empty palette.
//! netsync SYNC also goes through this module, so the palette syncs automatically.
//! **Compatibility**: the v4 reader reads schemas 2/3/4 (backward compatible). An older reader (max schema=3)
//! rejects v4 via `ver > schema_version` (not forward compatible — a v3 reader cannot read a v4 file).
//!
//! **schema v3 (read compatible)**: persists LayerId (stable handle) and `next_layer_id`.
//!
//! **schema v2 (read compatible)**: LayerDef at Document level; cel bodies are separated from the grid and
//! written once into CELS chunks. **No ids**, so load assigns deterministically in layer order
//! (`next_layer_id = layer_count+1`).
//!
//! Read compatibility for old v1 (`frames:[]*Canvas`, pixels embedded directly in LAYR) is **not implemented**
//! (breaking change). `decodeDocument` accepts schemas 2/3/4 and
//! rejects anything else (v1 / future overflow) with `error.UnsupportedSchemaVersion`.
//!
//! Format (streaming walk; all little-endian):
//! - DOCH (one, at the start):
//!   - v2=28B: width u32 | height u32 | layer_count u32 | frame_count u32
//!     | selected_layer u32 | selected_frame u32 | flags u32 (reserved=0)
//!   - v3=36B: above + next_layer_id u64
//! - LAYR (layer_count times, right after DOCH; no pixels):
//!   - v2=8B: type u8 (0=raster,1=text) | visible u8 | opacity u8 | blend u8 (reserved=0) | pad[4]
//!   - v3=16B: above + id u64 (LayerId. 0=invalid is reassigned after all LAYR are read, from max explicit id+1
//!     in order. Duplicate non-zero ids → `error.CorruptLayer`)
//!   - LNAM (optional, immediately after the matching LAYR): layer name UTF-8 (no header)
//!   - LTXT (optional, after LNAM, kind==text only, 16B header+text): font_px f32 (bitcast→u32,LE)
//!     | color u32(LE) | x i32(LE) | y i32(LE) | text bytes (UTF-8, no header)
//! - FRAM (frame_count times, after all LAYR, 8B+layer_count*4B): frame_index u32 | duration_ms u32
//!   | grid[layer_count] (u32 each, LE. 0xFFFFFFFF=none; otherwise serial ID)
//! - CELS (K times, batched after all FRAM. K=unique referenced cel count; 4B+W*H*4B): compression u8(0=raw)
//!   | pad[3] | pixels[W*H*4] (canonical BGRA u32 raw bytes, row-major)
//! - PLTE (optional, v4, after CELS): count u16(LE) | colors[count] u32(LE each, canonical BGRA)
//!
//! **Serial-ID compression** (on-disk representation only; distinct from in-memory `CelId`/`CelSetSnapshot`):
//! encode numbers from 0 in first-seen order while walking FRAM in frame order and each frame in layer order,
//! and writes each CELS chunk once in that order. decode uses the serial ID itself
//! as the new `CelId` (pushing CELS chunks into cel_pool in appearance order makes
//! push order equal the new CelId, so no translation table is needed).
//!
//! **Forward compatibility / structural errors (v2-v4)**:
//! - Unknown top-level tag → skip.
//! - `LAYR.type` other than raster/text → **cannot skip** (grid is a fixed-length array of layer_count
//!   indexed by LAYR appearance order) → reject whole file with `error.UnsupportedLayerType`.
//! - `LAYR`/`FRAM`/`CELS` payload length mismatch → `CorruptLayer`/`CorruptFrame`/`CorruptCel` respectively.
//! - Declared `layer_count`/`frame_count` ≠ actual appearance count → `LayerCountMismatch`/`FrameCountMismatch`.
//! - Every LAYR must appear before every FRAM → `error.LayerAfterFrame`.
//! - `FRAM.grid` serial ID ≥ actual CELS count → `error.CorruptGrid` (dangling reference).
//!   Surplus CELs are allowed (auto-reclaimed after load as refcount=0).
//! - The same serial ID (= same CelId) referenced from grids of different layers
//!   → `error.CrossLayerCelShare` (protects the design premise that cel sharing stays within a layer).
//! - Missing/duplicate `DOCH`, or `schema_version` other than 2/3/4 → reject.
//!
//! Hot-path declaration: save/load/export are **event-time only** (one menu action). Pixel-scale but
//! not an every-frame loop, so outside the SIMD trio. Pixel payload is bulk-transferred with @memcpy
//! (no per-pixel division/function call/bounds check).

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

/// .pix magic (FourCC 'PIX1' as little-endian u32). Passed to serde's expected_magic.
pub const magic: u32 = @as(u32, 'P') | (@as(u32, 'I') << 8) | (@as(u32, 'X') << 16) | (@as(u32, '1') << 24);
/// pixie schema version (separate from serde's container_version; app-managed).
/// write always uses the current version (v2 cell grid; v3 LayerId; v4 PLTE).
pub const schema_version: u16 = 4;
/// Oldest schema accepted on read (v2 cell grid). v1 is rejected.
pub const schema_version_min: u16 = 2;
/// v3 schema constant (read branch / hand-written fixtures; follows the v2→v3 side-by-side pattern).
pub const schema_version_v3: u16 = 3;
/// v2 schema constant.
pub const schema_version_v2: u16 = 2;

const TAG_DOC: [4]u8 = "DOCH".*;
const TAG_FRAME: [4]u8 = "FRAM".*;
const TAG_LAYER: [4]u8 = "LAYR".*;
const TAG_LAYER_NAME: [4]u8 = "LNAM".*;
const TAG_LAYER_TEXT: [4]u8 = "LTXT".*;
const TAG_CEL: [4]u8 = "CELS".*;
const TAG_PLTE: [4]u8 = "PLTE".*;

const doc_header_size_v2: usize = 28;
const doc_header_size_v3: usize = 36; // + next_layer_id u64 (shared by v3/v4)
const doc_header_size: usize = doc_header_size_v3; // for encode
const layer_header_size_v2: usize = 8;
const layer_header_size_v3: usize = 16; // + id u64 (shared by v3/v4)
const layer_header_size: usize = layer_header_size_v3; // for encode
const frame_header_size: usize = 8; // grid[layer_count] is the variable-length part that follows
const cel_header_size: usize = 4;
const plte_header_size: usize = 2; // count u16
/// PLTE color-count cap (full u16 range rejected; DoS / corruption defence).
const plte_max_colors: usize = 256;
const layer_type_raster: u8 = 0;
const layer_type_text: u8 = 1;
const compression_raw: u8 = 0;
/// LTXT header length (font_px:f32 + color:u32 + x:i32 + y:i32). Remainder is text bytes.
const text_header_size: usize = 16;
/// FRAM.grid "empty slot" marker (real CelIds are monotonic non-reused and fit in u32
/// by premise; treated as a reserved value on the schema).
const grid_none: u32 = 0xFFFFFFFF;

pub const CanvasSize = struct { w: u32, h: u32 };

// ── encode / decode (bytes ⇔ Document; no file I/O) ─────────────────────

/// Serialize Document to .pix bytes (caller frees). Written at the current schema (v4).
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
    std.mem.writeInt(u32, doch[24..28], 0, .little); // flags reserved
    std.mem.writeInt(u64, doch[28..36], doc.next_layer_id, .little);
    try w.addChunk(TAG_DOC, &doch);

    // LAYR(+LNAM/LTXT). No pixels (essential to v2). v3 appends id u64.
    for (doc.layers.items) |def| {
        var lbuf: [layer_header_size]u8 = undefined;
        lbuf[0] = if (def.kind == .text) layer_type_text else layer_type_raster;
        lbuf[1] = @intFromBool(def.visible);
        lbuf[2] = def.opacity;
        lbuf[3] = 0; // blend reserved
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

    // FRAM (frame order; each frame walks grid in layer order = serial-ID first-seen order).
    var serial_of = try gpa.alloc(?u32, doc.cel_pool.items.len);
    defer gpa.free(serial_of);
    @memset(serial_of, null);
    var serial_order: std.ArrayList(CelId) = .empty; // Source CelIds in serial-ID order (for CELS write-out)
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

    // CELS (once each, in serial-ID order).
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

    // PLTE (v4. Empty = unset, so omit the chunk).
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

/// Restore a Document from .pix bytes (any size; size limits are the caller's=pixie's job).
/// Accepts schema_version ∈ {2,3,4} (v1 / overflow → `error.UnsupportedSchemaVersion`).
/// v2 (no ids) assigns deterministically in layer order. Pre-v3 gets an empty palette.
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
    // payload[24..28] = flags (reserved, unused)
    const stored_next_layer_id: ?u64 = if (has_layer_ids) readU64(first.payload[28..36]) else null;

    var doc = try Document.initEmpty(gpa, width, height);
    errdefer doc.deinit();

    var last_layer_idx: ?usize = null;
    var layers_done = false; // Once true, further LAYR is a structural error
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
            // LayerId: v3 from payload (0=invalid reassigned after read; non-zero duplicates rejected).
            // v2 assigns deterministically in layer order.
            if (has_layer_ids) {
                const raw_id = readU64(p[8..16]);
                if (raw_id == 0) {
                    def.id = .invalid; // After all LAYR are read, assign sequentially from max explicit id+1
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
            // Apply only when the previous chunk was a valid LAYR (last_layer_idx is not
            // reset by LNAM/LTXT = LTXT can target the same layer. Same safety valve as v1).
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
            // v4 palette (absent from pre-v3 files. Multiple PLTE: last write wins).
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

    // v3: reassign id=0 (invalid) slots in layer order from max explicit id+1.
    // Immediate assign-while-reading is forbidden (can collide with later explicit ids).
    if (has_layer_ids) {
        var max_explicit: u64 = 0;
        for (doc.layers.items) |def| {
            const v = @intFromEnum(def.id);
            if (v > max_explicit) max_explicit = v;
        }
        var next_assign: u64 = max_explicit + 1;
        if (next_assign == 0) next_assign = 1; // All-invalid plus overflow defence (normally unreachable)
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

    // Build the grid (layer-major) while checking/computing dangling refs, cross-layer shares, and refcounts.
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

    // Zero-ref cels (surplus CELS) are auto-reclaimed (not compacted; keeps CelId=cel_pool index).
    for (doc.cel_pool.items) |*maybe_cel| {
        if (maybe_cel.*) |cel| {
            if (cel.refcount == 0) {
                gpa.free(cel.pixels);
                maybe_cel.* = null;
            }
        }
    }

    // Defensively normalize text-layer invariants (force a state that satisfies the invariant
    // by the time decode completes, even for broken/hand-edited files).
    for (0..nlayers) |l| {
        if (doc.layers.items[l].kind == .text) doc.normalizeTextLayerLinks(gpa, l);
    }

    // LayerId allocation cursor: v3 takes DOCH's next_layer_id and defensively raises it if below
    // max(id)+1 after reassignment. v2 already has
    // next_layer_id = layer_count+1 from allocLayerId during load.
    if (stored_next_layer_id) |n| doc.next_layer_id = n;
    for (doc.layers.items) |def| {
        const v = @intFromEnum(def.id);
        if (v >= doc.next_layer_id) doc.next_layer_id = v + 1;
    }

    if (sel_layer < nlayers) doc.selected_layer = sel_layer;
    if (sel_frame < nframes) doc.selected_frame = sel_frame;

    // Right after project load (one of the three call sites): rebuild active_view from
    // doc.layers/grid (reconcile layer count + apply pixels/metadata).
    doc.resyncActiveView(gpa);
    return doc;
}

/// Peek only the canvas size from the DOCH in a byte slice (for size rejection before layer restore).
pub fn peekCanvasSize(bytes: []const u8) !CanvasSize {
    const container = try serde.Container.parse(bytes, magic);
    const doch = container.find(TAG_DOC) orelse return error.MissingHeader;
    if (doch.len < 8) return error.CorruptDocument;
    return .{
        .w = readU32(doch[0..4]),
        .h = readU32(doch[4..8]),
    };
}

// ── file I/O (via std.Io; serde has no I/O) ───────────────────────

/// Save Document to path (encode → writeFile).
pub fn saveDocument(io: std.Io, path: []const u8, doc: *Document, gpa: Allocator) !void {
    const bytes = try encodeDocument(doc, gpa);
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// Load Document from path. Sizes that do not match expected_w/h return
/// error.UnsupportedCanvasSize before layer restore (pass 0 to skip the size check = any size allowed).
pub fn loadDocument(io: std.Io, gpa: Allocator, path: []const u8, expected_w: u32, expected_h: u32) !Document {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    if (expected_w != 0 or expected_h != 0) {
        const sz = try peekCanvasSize(bytes);
        if (sz.w != expected_w or sz.h != expected_h) return error.UnsupportedCanvasSize;
    }
    return decodeDocument(bytes, gpa);
}

/// compositeStraight each frame (flat transparent) and write `<stem>_NNNN.png` (1-based).
/// PNG save rule: do not use white-background composite(). Implementation: stash selected_frame → for each frame
/// resync→composite→restore (chosen for simplicity: frame counts are
/// usually small, and this avoids sharing composite logic partially).
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

/// compositeStraight every frame (flat transparent) into one spritesheet PNG.
/// `columns=0` auto-picks `ceil(sqrt(n))`. Inter-cell margin is `margin` px (transparent).
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

    // Multiply and add are checked (huge columns/margin args return SheetTooLarge without panic)
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

test "round-trip: multi-layer (visible/opacity/partial-alpha/mixed transparency) bit-restores + layers.len/selected" {
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
    // On first commit, pixels hand-written into active_view are already committed, so after pushPaintOp
    // c.layerPixels(1)/(2) are unchanged (usable as comparison targets as-is).
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
    try testing.expectEqual(@as(usize, 3), lc.layers.items.len); // No leftover layers
    try testing.expectEqual(@as(usize, 1), lc.selected_layer);
    try testing.expectEqualSlices(u32, c.layers.items[0].pixels, lc.layers.items[0].pixels);
    try testing.expectEqualSlices(u32, c.layers.items[1].pixels, lc.layers.items[1].pixels);
    try testing.expectEqualSlices(u32, c.layers.items[2].pixels, lc.layers.items[2].pixels);
    try testing.expectEqual(false, lc.layers.items[1].visible);
    try testing.expectEqual(@as(u8, 128), lc.layers.items[1].opacity);
    try testing.expectEqual(true, lc.layers.items[0].visible);
    try testing.expectEqual(@as(u8, 255), lc.layers.items[0].opacity);
    try testing.expectEqualStrings("Background", lc.layers.items[0].name());
    try testing.expectEqualStrings("Layer 2", lc.layers.items[1].name()); // Unrenamed keeps the default name
    try testing.expectEqualStrings("あ日本語レイヤー", lc.layers.items[2].name());
    // LayerId / next_layer_id also restore bit-identically
    try testing.expectEqual(id0, loaded.layerIdAt(0).?);
    try testing.expectEqual(id1, loaded.layerIdAt(1).?);
    try testing.expectEqual(id2, loaded.layerIdAt(2).?);
    try testing.expectEqual(next_id, loaded.next_layer_id);
}

test "peekCanvasSize: reads DOCH w/h before restore" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 13, 7);
    defer doc.deinit();
    const bytes = try encodeDocument(&doc, gpa);
    defer gpa.free(bytes);
    const sz = try peekCanvasSize(bytes);
    try testing.expectEqual(@as(u32, 13), sz.w);
    try testing.expectEqual(@as(u32, 7), sz.h);
}

// ── Forward compatibility / structural errors (hand-built containers via serde.Writer) ────────────

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

/// Build a FRAM chunk payload (frame_index + duration_ms + grid[layer_count]).
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

test "forward compatibility: skip unknown chunk tags and still read known layer/frame/cel" {
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

test "v1 schema is rejected with an explicit error (v1 compatibility not implemented; breaking change)" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, 1); // schema_version=1 (old-format equivalent)
    defer w.deinit();
    const doch = docChunk(1, 1, 1, 1, 0, 0);
    try w.addChunk(TAG_DOC, &doch);
    const bytes = try w.finish();
    defer gpa.free(bytes);
    try testing.expectError(error.UnsupportedSchemaVersion, decodeDocument(bytes, gpa));
}

test "schema_version overflow is also rejected" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, schema_version + 1);
    defer w.deinit();
    const doch = docChunk(1, 1, 1, 1, 0, 0);
    try w.addChunk(TAG_DOC, &doch);
    const bytes = try w.finish();
    defer gpa.free(bytes);
    try testing.expectError(error.UnsupportedSchemaVersion, decodeDocument(bytes, gpa));
}

test "LNAM/LTXT: round-trip bit-restores text kind/text_params" {
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

test "structural errors: returns each error" {
    const gpa = testing.allocator;

    // Missing DOCH (FRAM first)
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
    // Duplicate DOCH
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
    // Unknown LAYR.type
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        const doch = docChunk(1, 1, 1, 1, 0, 0);
        try w.addChunk(TAG_DOC, &doch);
        const lay = layerChunk(2, true, 255); // type=2 is unknown
        try w.addChunk(TAG_LAYER, &lay);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.UnsupportedLayerType, decodeDocument(bytes, gpa));
    }
    // LAYR after FRAM (structural error)
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
    // CELS + compression != raw
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
    // CELS payload length mismatch
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        const doch = docChunk(2, 2, 1, 1, 0, 0); // Expect 2x2=16B pixels
        try w.addChunk(TAG_DOC, &doch);
        const lay = layerChunk(layer_type_raster, true, 255);
        try w.addChunk(TAG_LAYER, &lay);
        const frm = try frameChunk(gpa, 0, 100, &.{0});
        defer gpa.free(frm);
        try w.addChunk(TAG_FRAME, frm);
        var short: [cel_header_size + 4]u8 = undefined; // Only 1px worth
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
    // frame_count mismatch (DOCH says 2 but one FRAM)
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
    // layer_count mismatch (DOCH says 2 but one LAYR)
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
    // FRAM grid dangling reference (serial ID with no CEL)
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        const doch = docChunk(1, 1, 1, 1, 0, 0);
        try w.addChunk(TAG_DOC, &doch);
        const lay = layerChunk(layer_type_raster, true, 255);
        try w.addChunk(TAG_LAYER, &lay);
        const frm = try frameChunk(gpa, 0, 100, &.{0}); // serial 0 but no CEL
        defer gpa.free(frm);
        try w.addChunk(TAG_FRAME, frm);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptGrid, decodeDocument(bytes, gpa));
    }
    // Another app's magic (serde BadMagic)
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

test "decode: cross-layer CelId sharing is rejected (same serial ID referenced from different layers)" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, schema_version);
    defer w.deinit();
    const doch = docChunk(1, 1, 2, 1, 0, 0); // 2 layer / 1 frame
    try w.addChunk(TAG_DOC, &doch);
    const lay0 = layerChunkV3(layer_type_raster, true, 255, 1);
    try w.addChunk(TAG_LAYER, &lay0);
    const lay1 = layerChunkV3(layer_type_raster, true, 255, 2);
    try w.addChunk(TAG_LAYER, &lay1);
    // frame0: layer0=serial0, layer1=serial0 (same serial ID from different layers)
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

test "decode: surplus CEL (refcount 0) is auto-reclaimed (nulled at refcount=0)" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, schema_version);
    defer w.deinit();
    const doch = docChunk(1, 1, 1, 1, 0, 0);
    try w.addChunk(TAG_DOC, &doch);
    const lay = layerChunk(layer_type_raster, true, 255);
    try w.addChunk(TAG_LAYER, &lay);
    const frm = try frameChunk(gpa, 0, 100, &.{grid_none}); // No references
    defer gpa.free(frm);
    try w.addChunk(TAG_FRAME, frm);
    const cel = try celChunk(gpa, 1, 1, 0xFF112233); // Surplus CEL nobody references
    defer gpa.free(cel);
    try w.addChunk(TAG_CEL, cel);
    const bytes = try w.finish();
    defer gpa.free(bytes);

    var loaded = try decodeDocument(bytes, gpa);
    defer loaded.deinit();
    // grid stays null (surplus CEL is unreferenced)
    try testing.expect(loaded.gridGet(0, 0) == null);
}

test "decode defensive text-layer normalization: broken link state corrected to the first non-null" {
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
    // frame0=serial0, frame1=serial1 (should share one but brokenly point at different ones)
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
    // Normalization makes both frames point at the same CelId (first non-null found = frame0's cel is canonical)
    const id0 = loaded.gridGet(0, 0);
    const id1 = loaded.gridGet(0, 1);
    try testing.expect(id0 != null and id1 != null);
    try testing.expectEqual(id0.?, id1.?);
}

test "any-size round-trip (document_io itself is size-agnostic; 256 limit is pixie's job)" {
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

/// Compare post-resize Document with encode→decode result (structure/pixels/links; CelId values may be reassigned).
fn expectResizePixRoundTrip(src: *Document, gpa: Allocator) !void {
    const bytes = try encodeDocument(src, gpa);
    defer gpa.free(bytes);
    var loaded = try decodeDocument(bytes, gpa);
    defer loaded.deinit();

    try testing.expectEqual(src.width, loaded.width);
    try testing.expectEqual(src.height, loaded.height);
    try testing.expectEqual(src.layers.items.len, loaded.layers.items.len);
    try testing.expectEqual(src.frames.items.len, loaded.frames.items.len);

    const nframes = src.frames.items.len;
    for (0..src.layers.items.len) |li| {
        for (0..nframes) |fi| {
            const a = src.gridGet(li, @intCast(fi));
            const b = loaded.gridGet(li, @intCast(fi));
            try testing.expectEqual(a == null, b == null);
            if (a) |aid| {
                const bid = b.?;
                try testing.expectEqualSlices(u32, src.cel_pool.items[aid].?.pixels, loaded.cel_pool.items[bid].?.pixels);
                try testing.expectEqual(src.cel_pool.items[aid].?.refcount, loaded.cel_pool.items[bid].?.refcount);
            }
            // Same-layer shared links (same CelId) stay equal after decode
            for (fi + 1..nframes) |fj| {
                const same_src = blk: {
                    const x = src.gridGet(li, @intCast(fi));
                    const y = src.gridGet(li, @intCast(fj));
                    break :blk x != null and y != null and x.? == y.?;
                };
                const same_dst = blk: {
                    const x = loaded.gridGet(li, @intCast(fi));
                    const y = loaded.gridGet(li, @intCast(fj));
                    break :blk x != null and y != null and x.? == y.?;
                };
                try testing.expectEqual(same_src, same_dst);
            }
        }
    }
    // active_view also matches at the new size
    try testing.expectEqual(src.active_view.width, loaded.active_view.width);
    try testing.expectEqual(src.active_view.height, loaded.active_view.height);
    try testing.expectEqual(src.active_view.layers.items.len, loaded.active_view.layers.items.len);
    for (src.active_view.layers.items, loaded.active_view.layers.items) |sa, la| {
        try testing.expectEqualSlices(u32, sa.pixels, la.pixels);
    }
}

test "Document.resize → encode/decode round-trip (shrink/grow/multi-layer/frame/linked-cel)" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    _ = try doc.addLayer(gpa); // layer1 gets a cel first via ensureCelAt
    try doc.addFrame(gpa, 1);

    const cel0 = doc.createCel(gpa, 0, 0);
    doc.cel_pool.items[cel0].?.pixels[0] = 0xFFFF0000; // (0,0)
    doc.cel_pool.items[cel0].?.pixels[5] = 0xFF00FF00; // (1,1)
    try doc.linkCel(gpa, 0, 1, 0); // frame1 → same CelId
    const cel1 = doc.createCel(gpa, 1, 0);
    doc.cel_pool.items[cel1].?.pixels[0] = 0xFF0000FF;
    doc.resyncActiveView(gpa);

    try testing.expectEqual(cel0, doc.gridGet(0, 1).?);
    try testing.expect(doc.cel_pool.items[cel0].?.refcount >= 2);

    // Shrink: keep top-left 2x2
    try doc.resize(gpa, 2, 2);
    try testing.expectEqual(@as(u32, 0xFFFF0000), doc.cel_pool.items[cel0].?.pixels[0]);
    try testing.expectEqual(@as(u32, 0xFF00FF00), doc.cel_pool.items[cel0].?.pixels[3]); // (1,1)
    try expectResizePixRoundTrip(&doc, gpa);

    // Grow: keep original content top-left; new region 0
    try doc.resize(gpa, 6, 5);
    try testing.expectEqual(@as(u32, 0xFFFF0000), doc.cel_pool.items[cel0].?.pixels[0]);
    try testing.expectEqual(@as(u32, 0), doc.cel_pool.items[cel0].?.pixels[2]);
    try expectResizePixRoundTrip(&doc, gpa);
}

// After PNG-open equivalent (reset → write active_view directly → commitActiveLayerToCel),
// saveDocument → loadDocument must bit-match pixels (empty .pix if cel was never written back).
test "reset + direct layerPixels write + commitActiveLayerToCel → save/load pixels bit-identical" {
    const gpa = testing.allocator;
    const io = std.testing.io;

    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();
    _ = try doc.addLayer(gpa); // Reproduce open-equivalent collapse from multi-layer
    doc.resetToSingleBlankLayer(gpa);
    try testing.expectEqual(@as(u32, 0), doc.selected_frame);
    try testing.expectEqual(@as(usize, 1), doc.layers.items.len);
    try testing.expectEqual(@as(usize, 0), doc.cel_pool.items.len); // Right after reset: 0 cels

    const color: u32 = 0xFF112233;
    const px = doc.activeCanvas().layerPixels(0);
    @memset(px, color);

    doc.commitActiveLayerToCel(gpa, 0);
    const cel_id = doc.gridGet(0, 0).?;
    try testing.expectEqualSlices(u32, px, doc.celPixels(cel_id).?);

    // Fixed cwd names race across parallel test binaries, so isolate with tmpDir.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const pix_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/task95_open_commit.pix", .{&tmp.sub_path});
    try saveDocument(io, pix_path, &doc, gpa);

    var loaded = try loadDocument(io, gpa, pix_path, 4, 4);
    defer loaded.deinit();
    try testing.expectEqualSlices(u32, px, loaded.activeCanvas().layerPixels(0));
    // Same via cel (proof that save wrote cel_pool)
    try testing.expectEqualSlices(u32, px, loaded.celPixels(loaded.gridGet(0, 0).?).?);
}

test "LayerId: .pix v3 round-trip keeps id/next_layer_id + id stable after reorder" {
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
    // Schema equals current schema_version (v4)
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
    // add after load continues from next_layer_id (no collision)
    const idx = try loaded.addLayer(gpa);
    try testing.expectEqual(@as(LayerId, @enumFromInt(next_before)), loaded.layerIdAt(idx).?);
}

test "LayerId: old schema v2 fixture assigns deterministically in layer order (fallback)" {
    const gpa = testing.allocator;
    // Hand-written v2 container (LAYR 8B, DOCH 28B, no ids)
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
    // Deterministic assign 1, 2 in layer order
    try testing.expectEqual(@as(LayerId, @enumFromInt(1)), loaded.layerIdAt(0).?);
    try testing.expectEqual(@as(LayerId, @enumFromInt(2)), loaded.layerIdAt(1).?);
    try testing.expectEqual(@as(u64, 3), loaded.next_layer_id);
    try testing.expectEqualStrings("A", loaded.layers.items[0].name());
    try testing.expectEqualStrings("B", loaded.layers.items[1].name());
    try testing.expectEqual(false, loaded.layers.items[1].visible);
    try testing.expectEqual(@as(u8, 128), loaded.layers.items[1].opacity);
}

test "LayerId: v3 duplicate ids rejected with CorruptLayer" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, schema_version);
    defer w.deinit();
    // ids=[7,7] → reject the hazard that layerIndexOf only returns the first
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

test "LayerId: v3 mixed id=0 reassigns from max+1 without colliding with explicit ids" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, schema_version);
    defer w.deinit();
    // ids=[0, 5, 0] → older code could assign 1 while reading and collide with explicit id=1.
    // Current: explicit max=5 → assign invalids 6, 7 in layer order → [6, 5, 7]
    const doch = docChunkV3(1, 1, 3, 1, 0, 0, 1); // Raise stored next defensively even if small
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
    // Each id resolves uniquely
    try testing.expectEqual(@as(?usize, 0), loaded.layerIndexOf(@as(LayerId, @enumFromInt(6))));
    try testing.expectEqual(@as(?usize, 1), loaded.layerIndexOf(@as(LayerId, @enumFromInt(5))));
    try testing.expectEqual(@as(?usize, 2), loaded.layerIndexOf(@as(LayerId, @enumFromInt(7))));
    try testing.expectEqual(@as(u64, 8), loaded.next_layer_id); // max(7)+1 (raise stored=1)
    try testing.expectEqualStrings("zero0", loaded.layers.items[0].name());
    try testing.expectEqualStrings("five", loaded.layers.items[1].name());
    try testing.expectEqualStrings("zero1", loaded.layers.items[2].name());
}

test "file I/O: saveDocument→loadDocument round-trip + size reject + exportPngSequence (matches compositeStraight)" {
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

    // Size reject (expect 256 → 4x4 rejected; error before layer restore)
    try testing.expectError(error.UnsupportedCanvasSize, loadDocument(io, gpa, pix_path, 256, 256));

    // Round-trip with any size allowed (expected 0)
    var loaded = try loadDocument(io, gpa, pix_path, 0, 0);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 2), loaded.activeCanvas().layers.items.len);
    try testing.expectEqualSlices(u32, c.layers.items[0].pixels, loaded.activeCanvas().layers.items[0].pixels);
    try testing.expectEqualSlices(u32, c.layers.items[1].pixels, loaded.activeCanvas().layers.items[1].pixels);

    // exportPngSequence (1 frame → <stem>_0001.png; matches compositeStraight)
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

test "exportSpriteSheet: 2x2 layout / 1-frame identity / margin / columns / frame 0 is error" {
    const gpa = testing.allocator;
    const io = std.testing.io;
    const png = @import("png");

    // Reject frame count 0
    var empty = try Document.initEmpty(gpa, 2, 2);
    defer empty.deinit();
    try testing.expectError(error.NoFrames, exportSpriteSheet(io, ".task45_sheet_empty.png", &empty, gpa, .{}));

    // 1-frame identity (auto columns = 1)
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

    // 2x2 layout (4 frames, 2x2 canvas, columns=2)
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
    // Each frame's (0,0) pixel lands on the grid position
    try testing.expectEqual(colors[0], sheet.pixels[0]); // (0,0)
    try testing.expectEqual(colors[1], sheet.pixels[2]); // (2,0)
    try testing.expectEqual(colors[2], sheet.pixels[8]); // (0,2) = row 2 * width 4
    try testing.expectEqual(colors[3], sheet.pixels[10]); // (2,2)

    // With margin (2 frames, 1x2 canvas, columns=2, margin=1)
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

test "exportSpriteSheet: huge columns/margin → SheetTooLarge (checked arithmetic; no panic)" {
    const gpa = testing.allocator;
    const io = std.testing.io;
    var doc = try Document.init(gpa, 2, 2);
    defer doc.deinit();
    try testing.expectError(error.SheetTooLarge, exportSpriteSheet(io, ".task45_sheet_huge.png", &doc, gpa, .{
        .columns = std.math.maxInt(u32),
        .margin = std.math.maxInt(u32),
    }));
}

// ── v4 PLTE ──────────────────────────────────────────────────

test "v4 PLTE: palette round-trip" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 2, 2);
    defer doc.deinit();
    try doc.palette.append(gpa, 0xFFFF0000);
    try doc.palette.append(gpa, 0xFF00FF00);
    try doc.palette.append(gpa, 0xFF0000FF);

    const bytes = try encodeDocument(&doc, gpa);
    defer gpa.free(bytes);
    // Current write is schema v4
    const container = try serde.Container.parse(bytes, magic);
    try testing.expectEqual(schema_version, container.schemaVersion());

    var loaded = try decodeDocument(bytes, gpa);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 3), loaded.palette.items.len);
    try testing.expectEqual(@as(u32, 0xFFFF0000), loaded.palette.items[0]);
    try testing.expectEqual(@as(u32, 0xFF00FF00), loaded.palette.items[1]);
    try testing.expectEqual(@as(u32, 0xFF0000FF), loaded.palette.items[2]);
}

test "v3 read: palette is empty (no PLTE)" {
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

test "v4: empty palette omits PLTE; round-trip stays empty" {
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

test "still reads PLTE after an unknown chunk (tag skip within the same schema)" {
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

test "PLTE: more than 256 colors → CorruptPalette" {
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
