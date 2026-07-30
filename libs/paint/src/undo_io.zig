//! UndoStack Op entry codec and UOPS snapshot wrapper.
//!
//! Entry layer: one Op (undo or redo side) per call; no stack counts.
//! Snapshot layer: thin UOPS wrapper with undo/redo counts and `next_handle`.
//!
//! Hot-path declaration: encode/decode run only at explicit save/restore events
//! (not per-frame, not per-sample).
//!
//! ## Wire integer / pixel byte order
//! This format is little-endian fixed. Multi-byte integers and each `u32` pixel are
//! written and read with explicit LE helpers (`writeU32`/`readU32`), not host-order
//! `@memcpy` of native arrays. That keeps the payload portable across endianness
//! at the cost of a per-element encode loop (acceptable: save/restore is event-time only).

const std = @import("std");
const document = @import("document.zig");
const canvas_mod = @import("canvas.zig");
const undo_mod = @import("undo.zig");

const Allocator = std.mem.Allocator;
const Op = document.Op;
const UndoStack = document.UndoStack;
const UndoStackOwned = document.UndoStackOwned;
const PixelDiff = undo_mod.PixelDiff;
const NameSnapshot = undo_mod.NameSnapshot;
const TextParams = canvas_mod.TextParams;
const LayerKind = canvas_mod.LayerKind;
const LayerDef = document.LayerDef;
const LayerId = document.LayerId;
const CelId = document.CelId;
const CelSetSnapshot = document.CelSetSnapshot;
const CelSnapshotItem = document.CelSnapshotItem;
const LayerStructOp = document.LayerStructOp;
const FrameStructOp = document.FrameStructOp;
const freeOp = document.freeOp;
const freeCelSetSnapshotOwned = document.freeCelSetSnapshotOwned;
const layer_name_max = canvas_mod.layer_name_max;
const text_content_max = canvas_mod.text_content_max;

pub const magic_uops: [4]u8 = "UOPS".*;
pub const snapshot_version: u16 = 1;
pub const entry_version: u16 = 1;
pub const entry_kind_op: u8 = 1;

/// Decode allocation guard (not a history trim limit).
pub const MAX_CODEC_ITEMS: u32 = 16 * 1024 * 1024;

const stack_kind_undo: u8 = 0;
const stack_kind_redo: u8 = 1;

// Explicit variant tags (not Zig enum ordinals).
const tag_paint: u8 = 0;
const tag_layer_visible: u8 = 1;
const tag_layer_opacity: u8 = 2;
const tag_layer_rename: u8 = 3;
const tag_layer_reorder: u8 = 4;
const tag_layer_text_params: u8 = 5;
const tag_layer_rasterize: u8 = 6;
const tag_layer_add: u8 = 7;
const tag_layer_delete: u8 = 8;
const tag_frame_add: u8 = 9;
const tag_frame_delete: u8 = 10;
const tag_frame_duplicate: u8 = 11;
const tag_layer_merge_down: u8 = 12;
const tag_cel_link: u8 = 13;
const tag_cel_unlink: u8 = 14;

pub const CodecError = error{
    UnexpectedEnd,
    TrailingBytes,
    BadMagic,
    BadVersion,
    BadFlags,
    BadEntryKind,
    BadEntryVersion,
    EntryLengthMismatch,
    BadStackKind,
    BadVariantTag,
    BadOptional,
    BadEnum,
    CountExceeded,
    LengthMismatch,
    Overflow,
    InvalidHandle,
    DuplicateHandle,
    InvalidNextHandle,
    InvalidUndoState,
    InvalidOwnership,
    OutOfMemory,
};

// ── cursor / writer ─────────────────────────────────────────────────────

const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    fn remaining(self: *const Cursor) usize {
        return self.data.len - self.pos;
    }

    fn atEnd(self: *const Cursor) bool {
        return self.pos == self.data.len;
    }

    fn require(self: *const Cursor, n: usize) CodecError!void {
        if (self.remaining() < n) return error.UnexpectedEnd;
    }

    fn readBytes(self: *Cursor, n: usize) CodecError![]const u8 {
        try self.require(n);
        const slice = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }

    fn readU8(self: *Cursor) CodecError!u8 {
        return (try self.readBytes(1))[0];
    }

    fn readU16(self: *Cursor) CodecError!u16 {
        const b = try self.readBytes(2);
        return std.mem.readInt(u16, b[0..2], .little);
    }

    fn readU32(self: *Cursor) CodecError!u32 {
        const b = try self.readBytes(4);
        return std.mem.readInt(u32, b[0..4], .little);
    }

    fn readU64(self: *Cursor) CodecError!u64 {
        const b = try self.readBytes(8);
        return std.mem.readInt(u64, b[0..8], .little);
    }

    fn readI32(self: *Cursor) CodecError!i32 {
        return @bitCast(try self.readU32());
    }

    fn readUsize(self: *Cursor) CodecError!usize {
        const v = try self.readU64();
        if (v > std.math.maxInt(usize)) return error.Overflow;
        return @intCast(v);
    }

    fn skip(self: *Cursor, n: usize) CodecError!void {
        try self.require(n);
        self.pos += n;
    }

    fn subCursor(self: *Cursor, n: usize) CodecError!Cursor {
        return .{ .data = try self.readBytes(n), .pos = 0 };
    }
};

const Writer = struct {
    list: *std.ArrayList(u8),
    gpa: Allocator,

    fn writeBytes(self: *Writer, bytes: []const u8) CodecError!void {
        self.list.appendSlice(self.gpa, bytes) catch return error.OutOfMemory;
    }

    fn writeU8(self: *Writer, v: u8) CodecError!void {
        self.list.append(self.gpa, v) catch return error.OutOfMemory;
    }

    fn writeU16(self: *Writer, v: u16) CodecError!void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, v, .little);
        try self.writeBytes(&buf);
    }

    fn writeU32(self: *Writer, v: u32) CodecError!void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, v, .little);
        try self.writeBytes(&buf);
    }

    fn writeU64(self: *Writer, v: u64) CodecError!void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, v, .little);
        try self.writeBytes(&buf);
    }

    fn writeI32(self: *Writer, v: i32) CodecError!void {
        try self.writeU32(@bitCast(v));
    }

    fn writeUsize(self: *Writer, v: usize) CodecError!void {
        try self.writeU64(v);
    }
};

fn writeOptionalU64(w: *Writer, value: ?u64) CodecError!void {
    if (value) |v| {
        try w.writeU8(1);
        try w.writeU64(v);
    } else {
        try w.writeU8(0);
    }
}

fn readOptionalU64(c: *Cursor) CodecError!?u64 {
    return switch (try c.readU8()) {
        0 => null,
        1 => try c.readU64(),
        else => error.BadOptional,
    };
}

fn writeOptionalU32(w: *Writer, value: ?u32) CodecError!void {
    if (value) |v| {
        try w.writeU8(1);
        try w.writeU32(v);
    } else {
        try w.writeU8(0);
    }
}

fn readOptionalU32(c: *Cursor) CodecError!?u32 {
    return switch (try c.readU8()) {
        0 => null,
        1 => try c.readU32(),
        else => error.BadOptional,
    };
}

fn writeOptionalU8(w: *Writer, value: ?u8) CodecError!void {
    if (value) |v| {
        try w.writeU8(1);
        try w.writeU8(v);
    } else {
        try w.writeU8(0);
    }
}

fn readOptionalU8(c: *Cursor) CodecError!?u8 {
    return switch (try c.readU8()) {
        0 => null,
        1 => try c.readU8(),
        else => error.BadOptional,
    };
}

fn checkCount(n: u32) CodecError!void {
    if (n > MAX_CODEC_ITEMS) return error.CountExceeded;
}

/// Reject counts that cannot fit in the remaining payload bytes before allocating.
fn checkCountFits(c: *const Cursor, count: u32, bytes_per_item: usize) CodecError!void {
    try checkCount(count);
    const need = @as(u64, count) * @as(u64, bytes_per_item);
    if (need > c.remaining()) return error.UnexpectedEnd;
}

// ── entry header / skip ─────────────────────────────────────────────────

const EntryHeader = struct { kind: u8, version: u16, len: u32 };

fn encodeEntryHeader(w: *Writer, kind: u8, version: u16, len: u32) CodecError!void {
    try w.writeU8(kind);
    try w.writeU16(version);
    try w.writeU32(len);
}

fn decodeEntryHeader(c: *Cursor) CodecError!EntryHeader {
    return .{
        .kind = try c.readU8(),
        .version = try c.readU16(),
        .len = try c.readU32(),
    };
}

/// Skip one entry by reading header and advancing `entry_len` (count-independent journal helper).
pub fn skipEntry(data: []const u8) CodecError!usize {
    var c: Cursor = .{ .data = data };
    const hdr = try decodeEntryHeader(&c);
    try c.skip(hdr.len);
    return c.pos;
}

// ── auxiliary types ─────────────────────────────────────────────────────

fn encodeNameSnapshot(w: *Writer, ns: NameSnapshot) CodecError!void {
    if (ns.len > layer_name_max) return error.LengthMismatch;
    try w.writeU8(ns.len);
    try w.writeBytes(ns.buf[0..ns.len]);
}

fn decodeNameSnapshot(c: *Cursor) CodecError!NameSnapshot {
    const len = try c.readU8();
    if (len > layer_name_max) return error.LengthMismatch;
    const bytes = try c.readBytes(len);
    var ns: NameSnapshot = .{};
    ns.len = len;
    @memcpy(ns.buf[0..len], bytes);
    return ns;
}

fn encodeTextParams(w: *Writer, tp: TextParams) CodecError!void {
    if (tp.text_len > text_content_max) return error.LengthMismatch;
    try w.writeU8(tp.text_len);
    try w.writeBytes(tp.text_buf[0..tp.text_len]);
    try w.writeU32(@bitCast(tp.font_px));
    try w.writeU32(tp.color);
    try w.writeI32(tp.x);
    try w.writeI32(tp.y);
}

fn decodeTextParams(c: *Cursor) CodecError!TextParams {
    const text_len = try c.readU8();
    if (text_len > text_content_max) return error.LengthMismatch;
    const text_bytes = try c.readBytes(text_len);
    var tp: TextParams = .{
        .font_px = @bitCast(try c.readU32()),
        .color = try c.readU32(),
        .x = try c.readI32(),
        .y = try c.readI32(),
    };
    tp.text_len = text_len;
    @memcpy(tp.text_buf[0..text_len], text_bytes);
    return tp;
}

fn encodeLayerDef(w: *Writer, def: LayerDef) CodecError!void {
    try w.writeU64(@intFromEnum(def.id));
    try w.writeU8(if (def.visible) 1 else 0);
    try w.writeU8(def.opacity);
    if (def.name_len > layer_name_max) return error.LengthMismatch;
    try w.writeU8(def.name_len);
    try w.writeBytes(def.name_buf[0..def.name_len]);
    try w.writeU8(@intFromEnum(def.kind));
    try encodeTextParams(w, def.text_params);
}

fn decodeLayerDef(c: *Cursor) CodecError!LayerDef {
    var def: LayerDef = .{
        .id = @enumFromInt(try c.readU64()),
        .visible = switch (try c.readU8()) {
            0 => false,
            1 => true,
            else => return error.BadOptional,
        },
        .opacity = try c.readU8(),
        .name_len = 0,
        .kind = .raster,
        .text_params = .{},
    };
    const name_len = try c.readU8();
    if (name_len > layer_name_max) return error.LengthMismatch;
    const name_bytes = try c.readBytes(name_len);
    def.name_len = name_len;
    @memcpy(def.name_buf[0..name_len], name_bytes);
    def.kind = switch (try c.readU8()) {
        0 => .raster,
        1 => .text,
        else => return error.BadEnum,
    };
    def.text_params = try decodeTextParams(c);
    return def;
}

fn encodePixelArray(w: *Writer, pixels: []const u32) CodecError!void {
    if (pixels.len > MAX_CODEC_ITEMS) return error.CountExceeded;
    try w.writeU32(@intCast(pixels.len));
    // Explicit LE per element (see module wire-order contract above).
    for (pixels) |p| try w.writeU32(p);
}

fn decodePixelArray(c: *Cursor, gpa: Allocator) CodecError![]u32 {
    const count = try c.readU32();
    // 4 bytes per u32; reject oversized counts before allocating.
    try checkCountFits(c, count, 4);
    const pixels = gpa.alloc(u32, count) catch return error.OutOfMemory;
    errdefer gpa.free(pixels);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        pixels[i] = try c.readU32();
    }
    return pixels;
}

fn encodeOptionalPixels(w: *Writer, pixels: ?[]const u32) CodecError!void {
    if (pixels) |p| {
        try w.writeU8(1);
        try encodePixelArray(w, p);
    } else {
        try w.writeU8(0);
    }
}

fn decodeOptionalPixels(c: *Cursor, gpa: Allocator) CodecError!?[]u32 {
    return switch (try c.readU8()) {
        0 => null,
        1 => try decodePixelArray(c, gpa),
        else => error.BadOptional,
    };
}

fn encodeCelSnapshotItem(w: *Writer, item: CelSnapshotItem) CodecError!void {
    try w.writeU32(item.id);
    try encodePixelArray(w, item.pixels);
}

fn decodeCelSnapshotItem(c: *Cursor, gpa: Allocator) CodecError!CelSnapshotItem {
    const id = try c.readU32();
    const pixels = try decodePixelArray(c, gpa);
    return .{ .id = id, .pixels = pixels };
}

fn encodeCelSetSnapshot(w: *Writer, snap: CelSetSnapshot) CodecError!void {
    if (snap.slots.len > MAX_CODEC_ITEMS) return error.CountExceeded;
    try w.writeU32(@intCast(snap.slots.len));
    for (snap.slots) |slot| {
        try writeOptionalU32(w, slot);
    }
    if (snap.fully_released.len > MAX_CODEC_ITEMS) return error.CountExceeded;
    try w.writeU32(@intCast(snap.fully_released.len));
    for (snap.fully_released) |item| {
        try encodeCelSnapshotItem(w, item);
    }
}

fn decodeCelSetSnapshot(c: *Cursor, gpa: Allocator) CodecError!CelSetSnapshot {
    const slots_count = try c.readU32();
    // Each slot is at least a present byte; bound before allocating.
    try checkCountFits(c, slots_count, 1);
    const slots = gpa.alloc(?CelId, slots_count) catch return error.OutOfMemory;
    errdefer gpa.free(slots);
    var i: u32 = 0;
    while (i < slots_count) : (i += 1) {
        slots[i] = try readOptionalU32(c);
    }

    const fr_count = try c.readU32();
    // Each fully_released item is at least id(u32)+count(u32) = 8 bytes.
    try checkCountFits(c, fr_count, 8);
    const fully_released = gpa.alloc(CelSnapshotItem, fr_count) catch return error.OutOfMemory;
    var decoded: u32 = 0;
    errdefer {
        var k: u32 = 0;
        while (k < decoded) : (k += 1) gpa.free(fully_released[k].pixels);
        gpa.free(fully_released);
    }
    while (decoded < fr_count) : (decoded += 1) {
        fully_released[decoded] = try decodeCelSnapshotItem(c, gpa);
    }
    return .{ .slots = slots, .fully_released = fully_released };
}

fn encodeOptionalCelSet(w: *Writer, snap: ?CelSetSnapshot) CodecError!void {
    if (snap) |s| {
        try w.writeU8(1);
        try encodeCelSetSnapshot(w, s);
    } else {
        try w.writeU8(0);
    }
}

fn decodeOptionalCelSet(c: *Cursor, gpa: Allocator) CodecError!?CelSetSnapshot {
    return switch (try c.readU8()) {
        0 => null,
        1 => try decodeCelSetSnapshot(c, gpa),
        else => error.BadOptional,
    };
}

fn encodeOptionalLayerDef(w: *Writer, def: ?LayerDef) CodecError!void {
    if (def) |d| {
        try w.writeU8(1);
        try encodeLayerDef(w, d);
    } else {
        try w.writeU8(0);
    }
}

fn decodeOptionalLayerDef(c: *Cursor) CodecError!?LayerDef {
    return switch (try c.readU8()) {
        0 => null,
        1 => try decodeLayerDef(c),
        else => error.BadOptional,
    };
}

fn encodeOptionalCelItem(w: *Writer, item: ?CelSnapshotItem) CodecError!void {
    if (item) |it| {
        try w.writeU8(1);
        try encodeCelSnapshotItem(w, it);
    } else {
        try w.writeU8(0);
    }
}

fn decodeOptionalCelItem(c: *Cursor, gpa: Allocator) CodecError!?CelSnapshotItem {
    return switch (try c.readU8()) {
        0 => null,
        1 => try decodeCelSnapshotItem(c, gpa),
        else => error.BadOptional,
    };
}

// ── Op payload ──────────────────────────────────────────────────────────

fn variantTag(op: *const Op) u8 {
    return switch (op.*) {
        .paint => tag_paint,
        .layer_visible => tag_layer_visible,
        .layer_opacity => tag_layer_opacity,
        .layer_rename => tag_layer_rename,
        .layer_reorder => tag_layer_reorder,
        .layer_text_params => tag_layer_text_params,
        .layer_rasterize => tag_layer_rasterize,
        .layer_add => tag_layer_add,
        .layer_delete => tag_layer_delete,
        .frame_add => tag_frame_add,
        .frame_delete => tag_frame_delete,
        .frame_duplicate => tag_frame_duplicate,
        .layer_merge_down => tag_layer_merge_down,
        .cel_link => tag_cel_link,
        .cel_unlink => tag_cel_unlink,
    };
}

fn encodeOpBody(w: *Writer, op: *const Op) CodecError!void {
    switch (op.*) {
        .paint => |p| {
            try w.writeU32(p.cel_id);
            try w.writeUsize(p.layer_idx);
            try w.writeU32(p.frame_idx);
            try w.writeU8(if (p.created) 1 else 0);
            try encodeOptionalPixels(w, p.created_released);
            if (p.diffs.len > MAX_CODEC_ITEMS) return error.CountExceeded;
            try w.writeU32(@intCast(p.diffs.len));
            for (p.diffs) |d| {
                try w.writeU32(d.idx);
                try w.writeU32(d.before);
                try w.writeU32(d.after);
            }
        },
        .layer_visible => |v| {
            try w.writeUsize(v.index);
            try w.writeU8(if (v.before) 1 else 0);
            try w.writeU8(if (v.after) 1 else 0);
        },
        .layer_opacity => |v| {
            try w.writeUsize(v.index);
            try w.writeU8(v.before);
            try w.writeU8(v.after);
        },
        .layer_rename => |v| {
            try w.writeUsize(v.index);
            try encodeNameSnapshot(w, v.before);
            try encodeNameSnapshot(w, v.after);
        },
        .layer_reorder => |v| {
            try w.writeUsize(v.from);
            try w.writeUsize(v.to);
            try w.writeUsize(v.selected_before);
            try w.writeUsize(v.selected_after);
        },
        .layer_text_params => |v| {
            try w.writeUsize(v.index);
            try encodeTextParams(w, v.before);
            try encodeTextParams(w, v.after);
        },
        .layer_rasterize => |v| {
            try w.writeUsize(v.index);
            try encodeTextParams(w, v.before);
        },
        .layer_add, .layer_delete => |v| {
            try w.writeUsize(v.index);
            try w.writeUsize(v.selected_before);
            try w.writeUsize(v.selected_after);
            try encodeOptionalLayerDef(w, v.def);
            try encodeOptionalCelSet(w, v.row);
        },
        .frame_add, .frame_delete => |v| {
            try w.writeU32(v.index);
            try w.writeU32(v.selected_before);
            try w.writeU32(v.selected_after);
            try w.writeU32(v.duration_ms);
            try encodeOptionalCelSet(w, v.col);
        },
        .frame_duplicate => |v| {
            try w.writeU32(v.src);
            try w.writeU32(v.new_index);
            try w.writeU32(v.selected_before);
            try w.writeU32(v.selected_after);
            try w.writeU32(v.duration_ms);
            try encodeOptionalCelSet(w, v.col);
        },
        .layer_merge_down => |v| {
            try w.writeUsize(v.index);
            try w.writeUsize(v.selected_before);
            try w.writeUsize(v.selected_after);
            try encodeOptionalLayerDef(w, v.def);
            try encodeOptionalCelItem(w, v.cel);
            try encodePixelArray(w, v.below_before);
            try encodePixelArray(w, v.below_after);
        },
        .cel_link => |v| {
            try w.writeUsize(v.layer_idx);
            try w.writeU32(v.frame_idx);
            try writeOptionalU32(w, v.before);
            try w.writeU32(v.after);
            try encodeOptionalPixels(w, v.before_released);
        },
        .cel_unlink => |v| {
            try w.writeUsize(v.layer_idx);
            try w.writeU32(v.frame_idx);
            try w.writeU32(v.before);
            try w.writeU32(v.after);
            try encodeOptionalPixels(w, v.after_released);
        },
    }
}

fn decodeBoolU8(c: *Cursor) CodecError!bool {
    return switch (try c.readU8()) {
        0 => false,
        1 => true,
        else => error.BadOptional,
    };
}

/// Ownership / optional-combination invariants for a decoded Op.
/// Reject combinations that would panic in Document.applyBefore/applyAfter.
fn validateOpOwnership(op: *const Op) CodecError!void {
    switch (op.*) {
        .paint => |p| {
            // created_released is only meaningful while created==true (document.zig paint contract).
            if (p.created_released != null and !p.created) return error.InvalidOwnership;
        },
        .layer_visible, .layer_opacity, .layer_rename, .layer_reorder, .layer_text_params, .layer_rasterize => {},
        .layer_add, .layer_delete => |ld| {
            // def and row toggle together: both null (structure applied) or both held.
            // applyBefore(.layer_delete) / applyAfter(.layer_add) panic if only one is set.
            if ((ld.def == null) != (ld.row == null)) return error.InvalidOwnership;
        },
        .frame_add, .frame_delete => {
            // col alone is a valid toggle state (null right after push for frame_add; held for frame_delete).
        },
        .frame_duplicate => {},
        .layer_merge_down => |lm| {
            // below_before / below_after are full-canvas pixel arrays of the layer below; must match.
            if (lm.below_before.len != lm.below_after.len) return error.InvalidOwnership;
            if (lm.cel) |item| {
                if (item.pixels.len != lm.below_before.len) return error.InvalidOwnership;
            }
            // def may be null (after undo applied) or non-null (after merge); cel optional when layer had empty cel.
        },
        .cel_link => |cl| {
            // applyBefore(.cel_link) does op.before.? when before_released is present.
            if (cl.before_released != null and cl.before == null) return error.InvalidOwnership;
        },
        .cel_unlink => {
            // before/after are always concrete CelIds; after_released is a toggle (null or owned pixels).
        },
    }
}

fn decodeOpBody(c: *Cursor, gpa: Allocator, tag: u8) CodecError!Op {
    const op: Op = switch (tag) {
        tag_paint => blk: {
            const cel_id = try c.readU32();
            const layer_idx = try c.readUsize();
            const frame_idx = try c.readU32();
            const created = try decodeBoolU8(c);
            const created_released = try decodeOptionalPixels(c, gpa);
            errdefer if (created_released) |p| gpa.free(p);
            const diff_count = try c.readU32();
            // PixelDiff = 3×u32.
            try checkCountFits(c, diff_count, 12);
            const diffs = gpa.alloc(PixelDiff, diff_count) catch return error.OutOfMemory;
            errdefer gpa.free(diffs);
            var i: u32 = 0;
            while (i < diff_count) : (i += 1) {
                diffs[i] = .{
                    .idx = try c.readU32(),
                    .before = try c.readU32(),
                    .after = try c.readU32(),
                };
            }
            break :blk .{ .paint = .{
                .cel_id = cel_id,
                .layer_idx = layer_idx,
                .frame_idx = frame_idx,
                .created = created,
                .created_released = created_released,
                .diffs = diffs,
            } };
        },
        tag_layer_visible => .{ .layer_visible = .{
            .index = try c.readUsize(),
            .before = try decodeBoolU8(c),
            .after = try decodeBoolU8(c),
        } },
        tag_layer_opacity => .{ .layer_opacity = .{
            .index = try c.readUsize(),
            .before = try c.readU8(),
            .after = try c.readU8(),
        } },
        tag_layer_rename => .{ .layer_rename = .{
            .index = try c.readUsize(),
            .before = try decodeNameSnapshot(c),
            .after = try decodeNameSnapshot(c),
        } },
        tag_layer_reorder => .{ .layer_reorder = .{
            .from = try c.readUsize(),
            .to = try c.readUsize(),
            .selected_before = try c.readUsize(),
            .selected_after = try c.readUsize(),
        } },
        tag_layer_text_params => .{ .layer_text_params = .{
            .index = try c.readUsize(),
            .before = try decodeTextParams(c),
            .after = try decodeTextParams(c),
        } },
        tag_layer_rasterize => .{ .layer_rasterize = .{
            .index = try c.readUsize(),
            .before = try decodeTextParams(c),
        } },
        tag_layer_add, tag_layer_delete => blk: {
            const index = try c.readUsize();
            const selected_before = try c.readUsize();
            const selected_after = try c.readUsize();
            const def = try decodeOptionalLayerDef(c);
            const row = try decodeOptionalCelSet(c, gpa);
            errdefer if (row) |r| freeCelSetSnapshotOwned(gpa, r);
            const payload: LayerStructOp = .{
                .index = index,
                .selected_before = selected_before,
                .selected_after = selected_after,
                .def = def,
                .row = row,
            };
            break :blk if (tag == tag_layer_add)
                Op{ .layer_add = payload }
            else
                Op{ .layer_delete = payload };
        },
        tag_frame_add, tag_frame_delete => blk: {
            const index = try c.readU32();
            const selected_before = try c.readU32();
            const selected_after = try c.readU32();
            const duration_ms = try c.readU32();
            const col = try decodeOptionalCelSet(c, gpa);
            errdefer if (col) |cl| freeCelSetSnapshotOwned(gpa, cl);
            const payload: FrameStructOp = .{
                .index = index,
                .selected_before = selected_before,
                .selected_after = selected_after,
                .duration_ms = duration_ms,
                .col = col,
            };
            break :blk if (tag == tag_frame_add)
                Op{ .frame_add = payload }
            else
                Op{ .frame_delete = payload };
        },
        tag_frame_duplicate => blk: {
            const src = try c.readU32();
            const new_index = try c.readU32();
            const selected_before = try c.readU32();
            const selected_after = try c.readU32();
            const duration_ms = try c.readU32();
            const col = try decodeOptionalCelSet(c, gpa);
            errdefer if (col) |cl| freeCelSetSnapshotOwned(gpa, cl);
            break :blk .{ .frame_duplicate = .{
                .src = src,
                .new_index = new_index,
                .selected_before = selected_before,
                .selected_after = selected_after,
                .duration_ms = duration_ms,
                .col = col,
            } };
        },
        tag_layer_merge_down => blk: {
            const index = try c.readUsize();
            const selected_before = try c.readUsize();
            const selected_after = try c.readUsize();
            const def = try decodeOptionalLayerDef(c);
            const cel = try decodeOptionalCelItem(c, gpa);
            errdefer if (cel) |ci| gpa.free(ci.pixels);
            const below_before = try decodePixelArray(c, gpa);
            errdefer gpa.free(below_before);
            const below_after = try decodePixelArray(c, gpa);
            errdefer gpa.free(below_after);
            break :blk .{ .layer_merge_down = .{
                .index = index,
                .selected_before = selected_before,
                .selected_after = selected_after,
                .def = def,
                .cel = cel,
                .below_before = below_before,
                .below_after = below_after,
            } };
        },
        tag_cel_link => blk: {
            const layer_idx = try c.readUsize();
            const frame_idx = try c.readU32();
            const before = try readOptionalU32(c);
            const after = try c.readU32();
            const before_released = try decodeOptionalPixels(c, gpa);
            errdefer if (before_released) |p| gpa.free(p);
            break :blk .{ .cel_link = .{
                .layer_idx = layer_idx,
                .frame_idx = frame_idx,
                .before = before,
                .after = after,
                .before_released = before_released,
            } };
        },
        tag_cel_unlink => blk: {
            const layer_idx = try c.readUsize();
            const frame_idx = try c.readU32();
            const before = try c.readU32();
            const after = try c.readU32();
            const after_released = try decodeOptionalPixels(c, gpa);
            errdefer if (after_released) |p| gpa.free(p);
            break :blk .{ .cel_unlink = .{
                .layer_idx = layer_idx,
                .frame_idx = frame_idx,
                .before = before,
                .after = after,
                .after_released = after_released,
            } };
        },
        else => return error.BadVariantTag,
    };
    errdefer {
        var mutable = op;
        freeOp(gpa, &mutable);
    }
    try validateOpOwnership(&op);
    return op;
}

/// Encode Op payload as `variant_tag` + body (no stack count, no entry header).
pub fn encodeOpPayload(gpa: Allocator, op: *const Op) CodecError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var w: Writer = .{ .list = &out, .gpa = gpa };
    try w.writeU8(variantTag(op));
    try encodeOpBody(&w, op);
    return out.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

/// Decode Op payload (`variant_tag` + body). Allocates owned slices; caller frees via `freeOp`.
/// Rejects ownership-invariant violations (`InvalidOwnership`) before returning.
pub fn decodeOpPayload(gpa: Allocator, data: []const u8) CodecError!Op {
    var c: Cursor = .{ .data = data };
    var op = try decodeOpBody(&c, gpa, try c.readU8());
    errdefer freeOp(gpa, &op);
    if (!c.atEnd()) return error.TrailingBytes;
    return op;
}

// ── Undo Op entry ───────────────────────────────────────────────────────

pub const DecodedUndoOpEntry = struct {
    stack_kind: u8, // 0=undo, 1=redo
    handle: ?u64,
    owner: ?u8,
    op: Op,
    consumed: usize,
};

/// Encode one undo/redo Op entry with self-describing header. Count-independent.
/// For undo: handle and owner required. For redo: handle/owner omitted.
pub fn encodeUndoOpEntry(
    gpa: Allocator,
    stack_kind: u8,
    handle: ?u64,
    owner: ?u8,
    op: *const Op,
) CodecError![]u8 {
    if (stack_kind != stack_kind_undo and stack_kind != stack_kind_redo) return error.BadStackKind;
    if (stack_kind == stack_kind_undo) {
        if (handle == null or owner == null) return error.InvalidHandle;
    } else {
        if (handle != null or owner != null) return error.InvalidHandle;
    }

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var bw: Writer = .{ .list = &body, .gpa = gpa };
    try bw.writeU8(stack_kind);
    if (stack_kind == stack_kind_undo) {
        try writeOptionalU64(&bw, handle);
        try writeOptionalU8(&bw, owner);
    } else {
        try writeOptionalU64(&bw, null);
        try writeOptionalU8(&bw, null);
    }

    const op_payload = try encodeOpPayload(gpa, op);
    defer gpa.free(op_payload);
    try bw.writeU32(@intCast(op_payload.len));
    try bw.writeBytes(op_payload);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var w: Writer = .{ .list = &out, .gpa = gpa };
    try encodeEntryHeader(&w, entry_kind_op, entry_version, @intCast(body.items.len));
    try w.writeBytes(body.items);
    return out.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

/// Decode one undo/redo Op entry. On success, `op` is owned by the caller (`freeOp` on dispose).
pub fn decodeUndoOpEntry(gpa: Allocator, data: []const u8) CodecError!DecodedUndoOpEntry {
    var c: Cursor = .{ .data = data };
    const hdr = try decodeEntryHeader(&c);
    if (hdr.kind != entry_kind_op) return error.BadEntryKind;
    if (hdr.version != entry_version) return error.BadEntryVersion;
    var payload = try c.subCursor(hdr.len);

    const stack_kind = try payload.readU8();
    if (stack_kind != stack_kind_undo and stack_kind != stack_kind_redo) return error.BadStackKind;
    const handle = try readOptionalU64(&payload);
    const owner = try readOptionalU8(&payload);
    if (stack_kind == stack_kind_undo) {
        if (handle == null or owner == null) return error.InvalidHandle;
        if (handle.? == 0) return error.InvalidHandle;
    } else {
        if (handle != null or owner != null) return error.InvalidHandle;
    }

    const op_payload_len = try payload.readU32();
    var op_cursor = try payload.subCursor(op_payload_len);
    // decodeOpPayload expects exact end of its buffer
    const tag = try op_cursor.readU8();
    var op = try decodeOpBody(&op_cursor, gpa, tag);
    errdefer freeOp(gpa, &op);
    if (!op_cursor.atEnd()) return error.TrailingBytes;
    if (!payload.atEnd()) return error.TrailingBytes;

    return .{
        .stack_kind = stack_kind,
        .handle = handle,
        .owner = owner,
        .op = op,
        .consumed = c.pos,
    };
}

// ── UOPS snapshot ───────────────────────────────────────────────────────

/// Encode full UndoStack as UOPS snapshot. Caller frees.
pub fn encodeUndoStackSnapshot(gpa: Allocator, stack: *const UndoStack) CodecError![]u8 {
    const view = stack.stateView();
    if (view.undo.len > UndoStack.max_history) return error.CountExceeded;
    if (view.redo.len > UndoStack.max_history) return error.CountExceeded;
    if (view.undo.len != view.handles.len or view.undo.len != view.owners.len) return error.InvalidUndoState;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var w: Writer = .{ .list = &out, .gpa = gpa };

    try w.writeBytes(&magic_uops);
    try w.writeU16(snapshot_version);
    try w.writeU16(0);
    try w.writeU32(@intCast(view.undo.len));
    try w.writeU32(@intCast(view.redo.len));
    try w.writeU64(view.next_handle);

    for (view.undo, 0..) |*op, i| {
        const entry = try encodeUndoOpEntry(gpa, stack_kind_undo, view.handles[i], view.owners[i], op);
        defer gpa.free(entry);
        try w.writeBytes(entry);
    }
    for (view.redo) |*op| {
        const entry = try encodeUndoOpEntry(gpa, stack_kind_redo, null, null, op);
        defer gpa.free(entry);
        try w.writeBytes(entry);
    }

    return out.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

/// Decode UOPS into `stack` via restoreState. On failure the existing stack is unchanged.
/// Any Op decoded before a failure is freed (via `owned.deinit` or an explicit free on the
/// entry that never transferred into `owned`).
pub fn decodeUndoStackSnapshot(gpa: Allocator, data: []const u8, stack: *UndoStack) CodecError!void {
    var c: Cursor = .{ .data = data };
    const magic = try c.readBytes(4);
    if (!std.mem.eql(u8, magic, &magic_uops)) return error.BadMagic;
    if (try c.readU16() != snapshot_version) return error.BadVersion;
    if (try c.readU16() != 0) return error.BadFlags;

    const undo_count = try c.readU32();
    const redo_count = try c.readU32();
    if (undo_count > UndoStack.max_history) return error.CountExceeded;
    if (redo_count > UndoStack.max_history) return error.CountExceeded;
    const next_handle = try c.readU64();
    // 0 is invalid; maxInt overflows on the next push's next_handle += 1.
    if (next_handle == 0 or next_handle == std.math.maxInt(u64)) return error.InvalidNextHandle;

    var owned: UndoStackOwned = .{};
    errdefer owned.deinit(gpa);
    owned.next_handle = next_handle;

    var i: u32 = 0;
    while (i < undo_count) : (i += 1) {
        const start = c.pos;
        var decoded = try decodeUndoOpEntry(gpa, c.data[c.pos..]);
        c.pos = start + decoded.consumed;
        // Free explicitly until the Op is stored in `owned` (owned.deinit covers the rest).
        if (decoded.stack_kind != stack_kind_undo) {
            freeOp(gpa, &decoded.op);
            return error.BadStackKind;
        }
        const handle = decoded.handle.?;
        const owner = decoded.owner.?;
        owned.undo.append(gpa, decoded.op) catch {
            freeOp(gpa, &decoded.op);
            return error.OutOfMemory;
        };
        owned.handles.append(gpa, handle) catch return error.OutOfMemory;
        owned.owners.append(gpa, owner) catch return error.OutOfMemory;
    }
    i = 0;
    while (i < redo_count) : (i += 1) {
        const start = c.pos;
        var decoded = try decodeUndoOpEntry(gpa, c.data[c.pos..]);
        c.pos = start + decoded.consumed;
        if (decoded.stack_kind != stack_kind_redo) {
            freeOp(gpa, &decoded.op);
            return error.BadStackKind;
        }
        owned.redo.append(gpa, decoded.op) catch {
            freeOp(gpa, &decoded.op);
            return error.OutOfMemory;
        };
    }

    if (!c.atEnd()) return error.TrailingBytes;

    stack.restoreState(gpa, &owned) catch return error.InvalidUndoState;
}

// ── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn visOp(index: usize) Op {
    return .{ .layer_visible = .{ .index = index, .before = true, .after = false } };
}

fn paintOp(gpa: Allocator) !Op {
    const diffs = try gpa.alloc(PixelDiff, 2);
    diffs[0] = .{ .idx = 0, .before = 0, .after = 0xFF0000FF };
    diffs[1] = .{ .idx = 1, .before = 1, .after = 0xFF00FF00 };
    return .{ .paint = .{
        .cel_id = 3,
        .diffs = diffs,
        .layer_idx = 1,
        .frame_idx = 2,
        .created = true,
        .created_released = try gpa.dupe(u32, &[_]u32{ 1, 2, 3 }),
    } };
}

fn expectOpEqual(a: Op, b: Op) !void {
    try testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
    switch (a) {
        .layer_visible => |av| {
            const bv = b.layer_visible;
            try testing.expectEqual(av.index, bv.index);
            try testing.expectEqual(av.before, bv.before);
            try testing.expectEqual(av.after, bv.after);
        },
        .layer_opacity => |av| {
            const bv = b.layer_opacity;
            try testing.expectEqual(av.index, bv.index);
            try testing.expectEqual(av.before, bv.before);
            try testing.expectEqual(av.after, bv.after);
        },
        .paint => |ap| {
            const bp = b.paint;
            try testing.expectEqual(ap.cel_id, bp.cel_id);
            try testing.expectEqual(ap.layer_idx, bp.layer_idx);
            try testing.expectEqual(ap.frame_idx, bp.frame_idx);
            try testing.expectEqual(ap.created, bp.created);
            try testing.expectEqual(ap.diffs.len, bp.diffs.len);
            try testing.expectEqualSlices(PixelDiff, ap.diffs, bp.diffs);
            if (ap.created_released) |ar| {
                try testing.expect(bp.created_released != null);
                try testing.expectEqualSlices(u32, ar, bp.created_released.?);
            } else {
                try testing.expect(bp.created_released == null);
            }
        },
        .layer_rename => |av| {
            const bv = b.layer_rename;
            try testing.expectEqual(av.index, bv.index);
            try testing.expectEqualStrings(av.before.slice(), bv.before.slice());
            try testing.expectEqualStrings(av.after.slice(), bv.after.slice());
        },
        .layer_reorder => |av| {
            const bv = b.layer_reorder;
            try testing.expectEqual(av.from, bv.from);
            try testing.expectEqual(av.to, bv.to);
            try testing.expectEqual(av.selected_before, bv.selected_before);
            try testing.expectEqual(av.selected_after, bv.selected_after);
        },
        .layer_text_params => |av| {
            const bv = b.layer_text_params;
            try testing.expectEqual(av.index, bv.index);
            try testing.expectEqualStrings(av.before.text(), bv.before.text());
            try testing.expectEqual(av.before.font_px, bv.before.font_px);
            try testing.expectEqual(av.before.color, bv.before.color);
            try testing.expectEqual(av.before.x, bv.before.x);
            try testing.expectEqual(av.before.y, bv.before.y);
            try testing.expectEqualStrings(av.after.text(), bv.after.text());
        },
        .layer_rasterize => |av| {
            const bv = b.layer_rasterize;
            try testing.expectEqual(av.index, bv.index);
            try testing.expectEqualStrings(av.before.text(), bv.before.text());
        },
        .layer_add, .layer_delete => |av| {
            const bv = if (a == .layer_add) b.layer_add else b.layer_delete;
            try testing.expectEqual(av.index, bv.index);
            try testing.expectEqual(av.selected_before, bv.selected_before);
            try testing.expectEqual(av.selected_after, bv.selected_after);
            try testing.expectEqual(av.def == null, bv.def == null);
            if (av.def) |ad| {
                try testing.expectEqual(ad.id, bv.def.?.id);
                try testing.expectEqualStrings(ad.name(), bv.def.?.name());
            }
            try testing.expectEqual(av.row == null, bv.row == null);
            if (av.row) |ar| {
                try testing.expectEqual(ar.slots.len, bv.row.?.slots.len);
                try testing.expectEqual(ar.fully_released.len, bv.row.?.fully_released.len);
            }
        },
        .frame_add, .frame_delete => |av| {
            const bv = if (a == .frame_add) b.frame_add else b.frame_delete;
            try testing.expectEqual(av.index, bv.index);
            try testing.expectEqual(av.duration_ms, bv.duration_ms);
            try testing.expectEqual(av.col == null, bv.col == null);
        },
        .frame_duplicate => |av| {
            const bv = b.frame_duplicate;
            try testing.expectEqual(av.src, bv.src);
            try testing.expectEqual(av.new_index, bv.new_index);
            try testing.expectEqual(av.duration_ms, bv.duration_ms);
        },
        .layer_merge_down => |av| {
            const bv = b.layer_merge_down;
            try testing.expectEqual(av.index, bv.index);
            try testing.expectEqualSlices(u32, av.below_before, bv.below_before);
            try testing.expectEqualSlices(u32, av.below_after, bv.below_after);
        },
        .cel_link => |av| {
            const bv = b.cel_link;
            try testing.expectEqual(av.layer_idx, bv.layer_idx);
            try testing.expectEqual(av.frame_idx, bv.frame_idx);
            try testing.expectEqual(av.before, bv.before);
            try testing.expectEqual(av.after, bv.after);
        },
        .cel_unlink => |av| {
            const bv = b.cel_unlink;
            try testing.expectEqual(av.layer_idx, bv.layer_idx);
            try testing.expectEqual(av.before, bv.before);
            try testing.expectEqual(av.after, bv.after);
        },
    }
}

fn roundTripOp(gpa: Allocator, op: *Op) !void {
    const bytes = try encodeOpPayload(gpa, op);
    defer gpa.free(bytes);
    var decoded = try decodeOpPayload(gpa, bytes);
    defer freeOp(gpa, &decoded);
    try expectOpEqual(op.*, decoded);
}

test "Op payload round-trip preserves every variant" {
    const gpa = testing.allocator;

    // simple variants
    var v0 = visOp(3);
    try roundTripOp(gpa, &v0);

    var v1: Op = .{ .layer_opacity = .{ .index = 2, .before = 10, .after = 200 } };
    try roundTripOp(gpa, &v1);

    var v2: Op = .{ .layer_rename = .{
        .index = 0,
        .before = NameSnapshot.of("A"),
        .after = NameSnapshot.of("B"),
    } };
    try roundTripOp(gpa, &v2);

    var v3: Op = .{ .layer_reorder = .{ .from = 1, .to = 0, .selected_before = 1, .selected_after = 0 } };
    try roundTripOp(gpa, &v3);

    var tp_before: TextParams = .{ .font_px = 12.5, .color = 0xFF112233, .x = -1, .y = 4 };
    tp_before.setText("hi");
    var tp_after: TextParams = .{ .font_px = 18, .color = 0xFFAABBCC, .x = 2, .y = 3 };
    tp_after.setText("yo");
    var v4: Op = .{ .layer_text_params = .{ .index = 1, .before = tp_before, .after = tp_after } };
    try roundTripOp(gpa, &v4);

    var v5: Op = .{ .layer_rasterize = .{ .index = 0, .before = tp_before } };
    try roundTripOp(gpa, &v5);

    var paint = try paintOp(gpa);
    defer freeOp(gpa, &paint);
    try roundTripOp(gpa, &paint);

    // layer_add with optional def/row null
    var la: Op = .{ .layer_add = .{
        .index = 1,
        .selected_before = 0,
        .selected_after = 1,
        .def = null,
        .row = null,
    } };
    try roundTripOp(gpa, &la);

    // layer_delete with def + empty row snapshot
    var def: LayerDef = .{ .id = @enumFromInt(5), .visible = true, .opacity = 128, .kind = .raster };
    def.setName("L");
    const slots = try gpa.alloc(?CelId, 2);
    slots[0] = 1;
    slots[1] = null;
    const fr = try gpa.alloc(CelSnapshotItem, 1);
    fr[0] = .{ .id = 1, .pixels = try gpa.dupe(u32, &[_]u32{ 9, 8 }) };
    var ld: Op = .{ .layer_delete = .{
        .index = 0,
        .selected_before = 0,
        .selected_after = 0,
        .def = def,
        .row = .{ .slots = slots, .fully_released = fr },
    } };
    defer freeOp(gpa, &ld);
    try roundTripOp(gpa, &ld);

    var fa: Op = .{ .frame_add = .{
        .index = 1,
        .selected_before = 0,
        .selected_after = 1,
        .duration_ms = 100,
        .col = null,
    } };
    try roundTripOp(gpa, &fa);

    var fd: Op = .{ .frame_delete = .{
        .index = 0,
        .selected_before = 0,
        .selected_after = 0,
        .duration_ms = 50,
        .col = null,
    } };
    try roundTripOp(gpa, &fd);

    var fdup: Op = .{ .frame_duplicate = .{
        .src = 0,
        .new_index = 1,
        .selected_before = 0,
        .selected_after = 1,
        .duration_ms = 100,
        .col = null,
    } };
    try roundTripOp(gpa, &fdup);

    const below_b = try gpa.dupe(u32, &[_]u32{ 1, 2 });
    const below_a = try gpa.dupe(u32, &[_]u32{ 3, 4 });
    var lm: Op = .{ .layer_merge_down = .{
        .index = 1,
        .selected_before = 1,
        .selected_after = 0,
        .def = null,
        .cel = null,
        .below_before = below_b,
        .below_after = below_a,
    } };
    defer freeOp(gpa, &lm);
    try roundTripOp(gpa, &lm);

    var cl: Op = .{ .cel_link = .{
        .layer_idx = 0,
        .frame_idx = 1,
        .before = null,
        .after = 3,
        .before_released = null,
    } };
    try roundTripOp(gpa, &cl);

    var cu: Op = .{ .cel_unlink = .{
        .layer_idx = 0,
        .frame_idx = 0,
        .before = 1,
        .after = 2,
        .after_released = try gpa.dupe(u32, &[_]u32{5}),
    } };
    defer freeOp(gpa, &cu);
    try roundTripOp(gpa, &cu);
}

test "Undo Op entry round-trip preserves one undo operation" {
    const gpa = testing.allocator;
    var op = visOp(4);
    const bytes = try encodeUndoOpEntry(gpa, stack_kind_undo, 7, 2, &op);
    defer gpa.free(bytes);
    var decoded = try decodeUndoOpEntry(gpa, bytes);
    defer freeOp(gpa, &decoded.op);
    try testing.expectEqual(bytes.len, decoded.consumed);
    try testing.expectEqual(@as(u8, stack_kind_undo), decoded.stack_kind);
    try testing.expectEqual(@as(?u64, 7), decoded.handle);
    try testing.expectEqual(@as(?u8, 2), decoded.owner);
    try expectOpEqual(op, decoded.op);
}

test "Redo Op entry round-trip preserves one redo operation" {
    const gpa = testing.allocator;
    var op = visOp(1);
    const bytes = try encodeUndoOpEntry(gpa, stack_kind_redo, null, null, &op);
    defer gpa.free(bytes);
    var decoded = try decodeUndoOpEntry(gpa, bytes);
    defer freeOp(gpa, &decoded.op);
    try testing.expectEqual(@as(u8, stack_kind_redo), decoded.stack_kind);
    try testing.expectEqual(@as(?u64, null), decoded.handle);
    try testing.expectEqual(@as(?u8, null), decoded.owner);
    try expectOpEqual(op, decoded.op);
}

test "Op entry codec does not depend on stack count" {
    const gpa = testing.allocator;
    var a = visOp(0);
    var b = visOp(1);
    const e1 = try encodeUndoOpEntry(gpa, stack_kind_undo, 1, 0, &a);
    defer gpa.free(e1);
    const e2 = try encodeUndoOpEntry(gpa, stack_kind_undo, 2, 0, &b);
    defer gpa.free(e2);

    var cat: std.ArrayList(u8) = .empty;
    defer cat.deinit(gpa);
    try cat.appendSlice(gpa, e1);
    try cat.appendSlice(gpa, e2);

    var d1 = try decodeUndoOpEntry(gpa, cat.items);
    defer freeOp(gpa, &d1.op);
    try testing.expectEqual(e1.len, d1.consumed);
    try testing.expectEqual(@as(?u64, 1), d1.handle);

    var d2 = try decodeUndoOpEntry(gpa, cat.items[d1.consumed..]);
    defer freeOp(gpa, &d2.op);
    try testing.expectEqual(@as(?u64, 2), d2.handle);

    // skip unknown entry_kind via entry_len
    var unknown: std.ArrayList(u8) = .empty;
    defer unknown.deinit(gpa);
    var uw: Writer = .{ .list = &unknown, .gpa = gpa };
    try encodeEntryHeader(&uw, 42, entry_version, 2);
    try uw.writeBytes(&[_]u8{ 1, 2 });

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    try stream.appendSlice(gpa, e1);
    try stream.appendSlice(gpa, unknown.items);
    try stream.appendSlice(gpa, e2);

    var s1 = try decodeUndoOpEntry(gpa, stream.items);
    defer freeOp(gpa, &s1.op);
    const skipped = try skipEntry(stream.items[s1.consumed..]);
    try testing.expectEqual(unknown.items.len, skipped);
    var s2 = try decodeUndoOpEntry(gpa, stream.items[s1.consumed + skipped ..]);
    defer freeOp(gpa, &s2.op);
    try testing.expectEqual(@as(?u64, 2), s2.handle);
}

test "UndoStack snapshot wrapper round-trip preserves counts" {
    const gpa = testing.allocator;
    var stack: UndoStack = .{};
    defer stack.deinit(gpa);
    stack.push(gpa, visOp(0));
    stack.setOwner(1, 3);
    stack.push(gpa, visOp(1));
    stack.setOwner(2, 4);
    // move one to redo without using push: manual
    const top = stack.undo.pop().?;
    _ = stack.handles.pop();
    _ = stack.owners.pop();
    try stack.redo.append(gpa, top);

    const bytes = try encodeUndoStackSnapshot(gpa, &stack);
    defer gpa.free(bytes);

    var other: UndoStack = .{};
    defer other.deinit(gpa);
    other.push(gpa, visOp(99)); // seed different state

    try decodeUndoStackSnapshot(gpa, bytes, &other);
    try testing.expectEqual(@as(usize, 1), other.undo.items.len);
    try testing.expectEqual(@as(usize, 1), other.redo.items.len);
    try testing.expectEqual(@as(u64, 1), other.handles.items[0]);
    try testing.expectEqual(@as(u8, 3), other.owners.items[0]);
    try testing.expectEqual(stack.next_handle, other.next_handle);
}

test "Op codec rejects unknown tags and malformed lengths" {
    const gpa = testing.allocator;

    // unknown variant tag
    try testing.expectError(error.BadVariantTag, decodeOpPayload(gpa, &[_]u8{255}));

    // unknown entry kind
    var bad: std.ArrayList(u8) = .empty;
    defer bad.deinit(gpa);
    var w: Writer = .{ .list = &bad, .gpa = gpa };
    try encodeEntryHeader(&w, 9, entry_version, 0);
    try testing.expectError(error.BadEntryKind, decodeUndoOpEntry(gpa, bad.items));

    // truncated
    var op = visOp(0);
    const good = try encodeUndoOpEntry(gpa, stack_kind_undo, 1, 0, &op);
    defer gpa.free(good);
    try testing.expectError(error.UnexpectedEnd, decodeUndoOpEntry(gpa, good[0 .. good.len - 1]));
}

test "UndoStack codec keeps the original stack on decode failure" {
    const gpa = testing.allocator;
    var stack: UndoStack = .{};
    defer stack.deinit(gpa);
    stack.push(gpa, visOp(5));
    stack.setOwner(1, 7);
    const before_len = stack.undo.items.len;
    const before_h = stack.handles.items[0];
    const before_o = stack.owners.items[0];
    const before_nh = stack.next_handle;

    try testing.expectError(error.BadMagic, decodeUndoStackSnapshot(gpa, "XXXX", &stack));
    try testing.expectEqual(before_len, stack.undo.items.len);
    try testing.expectEqual(before_h, stack.handles.items[0]);
    try testing.expectEqual(before_o, stack.owners.items[0]);
    try testing.expectEqual(before_nh, stack.next_handle);

    // trailing bytes
    const good = try encodeUndoStackSnapshot(gpa, &stack);
    defer gpa.free(good);
    var with_trail: std.ArrayList(u8) = .empty;
    defer with_trail.deinit(gpa);
    try with_trail.appendSlice(gpa, good);
    try with_trail.append(gpa, 0);
    try testing.expectError(error.TrailingBytes, decodeUndoStackSnapshot(gpa, with_trail.items, &stack));
    try testing.expectEqual(before_h, stack.handles.items[0]);

    // count exceeded
    var over: std.ArrayList(u8) = .empty;
    defer over.deinit(gpa);
    try over.appendSlice(gpa, &magic_uops);
    var ow: Writer = .{ .list = &over, .gpa = gpa };
    try ow.writeU16(snapshot_version);
    try ow.writeU16(0);
    try ow.writeU32(@intCast(UndoStack.max_history + 1));
    try ow.writeU32(0);
    try ow.writeU64(1);
    try testing.expectError(error.CountExceeded, decodeUndoStackSnapshot(gpa, over.items, &stack));
    try testing.expectEqual(before_len, stack.undo.items.len);
}

test "Op codec rejects invalid ownership combinations" {
    const gpa = testing.allocator;

    // cel_link: before_released present but before absent → would panic in applyBefore.
    {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        var w: Writer = .{ .list = &body, .gpa = gpa };
        try w.writeU8(tag_cel_link);
        try w.writeUsize(0); // layer_idx
        try w.writeU32(0); // frame_idx
        try w.writeU8(0); // before absent
        try w.writeU32(3); // after
        try w.writeU8(1); // before_released present
        try w.writeU32(1); // pixel count
        try w.writeU32(0xFF000000);
        try testing.expectError(error.InvalidOwnership, decodeOpPayload(gpa, body.items));
    }

    // layer_add: def present, row absent.
    {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        var w: Writer = .{ .list = &body, .gpa = gpa };
        try w.writeU8(tag_layer_add);
        try w.writeUsize(0);
        try w.writeUsize(0);
        try w.writeUsize(0);
        try w.writeU8(1); // def present
        try encodeLayerDef(&w, .{});
        try w.writeU8(0); // row absent
        try testing.expectError(error.InvalidOwnership, decodeOpPayload(gpa, body.items));
    }

    // layer_delete: def absent, row present (empty snapshot).
    {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        var w: Writer = .{ .list = &body, .gpa = gpa };
        try w.writeU8(tag_layer_delete);
        try w.writeUsize(0);
        try w.writeUsize(0);
        try w.writeUsize(0);
        try w.writeU8(0); // def absent
        try w.writeU8(1); // row present
        try w.writeU32(0); // slots_count
        try w.writeU32(0); // fully_released_count
        try testing.expectError(error.InvalidOwnership, decodeOpPayload(gpa, body.items));
    }

    // paint: created_released without created.
    {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        var w: Writer = .{ .list = &body, .gpa = gpa };
        try w.writeU8(tag_paint);
        try w.writeU32(1); // cel_id
        try w.writeUsize(0);
        try w.writeU32(0);
        try w.writeU8(0); // created=false
        try w.writeU8(1); // created_released present
        try w.writeU32(1);
        try w.writeU32(0);
        try w.writeU32(0); // diff_count
        try testing.expectError(error.InvalidOwnership, decodeOpPayload(gpa, body.items));
    }

    // layer_merge_down: below_before / below_after length mismatch.
    {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        var w: Writer = .{ .list = &body, .gpa = gpa };
        try w.writeU8(tag_layer_merge_down);
        try w.writeUsize(1);
        try w.writeUsize(1);
        try w.writeUsize(0);
        try w.writeU8(0); // def absent
        try w.writeU8(0); // cel absent
        try w.writeU32(2); // below_before
        try w.writeU32(1);
        try w.writeU32(2);
        try w.writeU32(1); // below_after shorter
        try w.writeU32(9);
        try testing.expectError(error.InvalidOwnership, decodeOpPayload(gpa, body.items));
    }
}

test "Op codec rejects oversized pixel count before allocating" {
    const gpa = testing.allocator;
    // paint payload: claim 1_000_000 diffs but supply no bytes after the count.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var w: Writer = .{ .list = &body, .gpa = gpa };
    try w.writeU8(tag_paint);
    try w.writeU32(0);
    try w.writeUsize(0);
    try w.writeU32(0);
    try w.writeU8(0); // created
    try w.writeU8(0); // no created_released
    try w.writeU32(1_000_000); // diff_count — 12MB claimed, zero remaining
    // Must fail with UnexpectedEnd without attempting a huge allocation (would OOM or hang).
    try testing.expectError(error.UnexpectedEnd, decodeOpPayload(gpa, body.items));
}

test "UndoStack codec rejects next_handle that would overflow on push" {
    const gpa = testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    var w: Writer = .{ .list = &bytes, .gpa = gpa };
    try w.writeBytes(&magic_uops);
    try w.writeU16(snapshot_version);
    try w.writeU16(0);
    try w.writeU32(0);
    try w.writeU32(0);
    try w.writeU64(std.math.maxInt(u64));
    var stack: UndoStack = .{};
    defer stack.deinit(gpa);
    try testing.expectError(error.InvalidNextHandle, decodeUndoStackSnapshot(gpa, bytes.items, &stack));
}

test "UndoStack snapshot frees decoded ops on wrong stack kind" {
    const gpa = testing.allocator;
    var op = visOp(0);
    // Claim one undo entry but supply a redo entry body (wrong stack_kind).
    const redo_entry = try encodeUndoOpEntry(gpa, stack_kind_redo, null, null, &op);
    defer gpa.free(redo_entry);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    var w: Writer = .{ .list = &bytes, .gpa = gpa };
    try w.writeBytes(&magic_uops);
    try w.writeU16(snapshot_version);
    try w.writeU16(0);
    try w.writeU32(1); // undo_count
    try w.writeU32(0);
    try w.writeU64(2);
    try w.writeBytes(redo_entry);

    var stack: UndoStack = .{};
    defer stack.deinit(gpa);
    // testing.allocator fails the test if freeOp is skipped (leak).
    try testing.expectError(error.BadStackKind, decodeUndoStackSnapshot(gpa, bytes.items, &stack));
    try testing.expectEqual(@as(usize, 0), stack.undo.items.len);
}

test "UndoStack snapshot does not leak when append hits OOM" {
    const gpa = testing.allocator;
    var src: UndoStack = .{};
    defer src.deinit(gpa);
    src.push(gpa, visOp(0));
    src.setOwner(1, 1);
    const bytes = try encodeUndoStackSnapshot(gpa, &src);
    defer gpa.free(bytes);

    // Walk fail_index until decode reports OutOfMemory; every attempt must free via testing.allocator.
    var fail_index: usize = 0;
    var saw_oom = false;
    while (fail_index < 128) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        var stack: UndoStack = .{};
        const result = decodeUndoStackSnapshot(failing.allocator(), bytes, &stack);
        // Always release anything that landed in the stack (success path) with the real gpa.
        stack.deinit(gpa);
        if (result) |_| {
            // Decode succeeded despite fail_index (not enough allocs failed); keep searching.
            continue;
        } else |err| {
            if (err == error.OutOfMemory) {
                saw_oom = true;
                break;
            }
            // Other induced failures (e.g. mid-entry) are also leak-checked by gpa.
        }
    }
    try testing.expect(saw_oom);
}
