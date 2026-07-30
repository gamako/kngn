//! Command history entry codec and CMDL snapshot wrapper.
//!
//! Entry layer: one record / actor epoch / transaction slot per call; no counts.
//! Snapshot layer: thin CMDL wrapper that stores counts and ring metadata, then
//! delegates each body to the entry codecs.
//!
//! Hot-path declaration: encode/decode run only at explicit save/restore events
//! (not per-frame, not per-sample). No performance claims beyond that boundary.

const std = @import("std");
const command = @import("command.zig");

pub const CommandRecord = command.CommandRecord;
pub const CommandLog = command.CommandLog;
pub const CommandLogState = command.CommandLogState;
pub const ActorId = command.ActorId;
pub const CommandKind = command.CommandKind;
pub const ActorEpochState = command.ActorEpochState;
pub const TransactionSlotState = command.TransactionSlotState;
pub const ExecutorState = command.ExecutorState;
pub const PersistentState = command.PersistentState;
pub const Executor = command.Executor;
pub const MAX_CMD_NAME = command.MAX_CMD_NAME;
pub const MAX_CMD_ARGS = command.MAX_CMD_ARGS;
pub const MAX_CMD_LOG = command.MAX_CMD_LOG;
pub const MAX_ACTORS = command.MAX_ACTORS;
pub const MAX_OPEN_TX = command.MAX_OPEN_TX;
pub const MAX_TX_LABEL = command.MAX_TX_LABEL;

pub const magic_cmdl: [4]u8 = "CMDL".*;
pub const snapshot_version: u16 = 1;
pub const entry_version: u16 = 1;

pub const entry_kind_record: u8 = 1;
pub const entry_kind_actor_epoch: u8 = 2;
pub const entry_kind_transaction_slot: u8 = 3;

const flag_undoable: u8 = 1 << 0;
const flag_reverted: u8 = 1 << 1;
const flag_redo_consumed: u8 = 1 << 2;
const flag_known_mask: u8 = flag_undoable | flag_reverted | flag_redo_consumed;

const actor_tag_local_user: u8 = 0;
const actor_tag_local_agent: u8 = 1;
const actor_tag_peer: u8 = 2;
const actor_tag_system: u8 = 3;

const kind_normal: u8 = 0;
const kind_revert: u8 = 1;

pub const CodecError = error{
    UnexpectedEnd,
    TrailingBytes,
    BadMagic,
    BadVersion,
    BadFlags,
    BadEntryKind,
    BadEntryVersion,
    EntryLengthMismatch,
    BadActorTag,
    BadCommandKind,
    BadOptional,
    NameTooLong,
    ArgsTooLong,
    LabelTooLong,
    CountExceeded,
    DuplicateActor,
    DuplicateSeq,
    DuplicateTransactionId,
    BadTransactionId,
    BadNextSeq,
    BadNextTransactionId,
    BadCount,
    Overflow,
    OutOfMemory,
};

// ── cursor / writer helpers ─────────────────────────────────────────────

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
        const b = try self.readBytes(1);
        return b[0];
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

    fn skip(self: *Cursor, n: usize) CodecError!void {
        try self.require(n);
        self.pos += n;
    }

    fn subCursor(self: *Cursor, n: usize) CodecError!Cursor {
        const slice = try self.readBytes(n);
        return .{ .data = slice, .pos = 0 };
    }
};

const Writer = struct {
    list: *std.ArrayList(u8),
    gpa: std.mem.Allocator,

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
    const present = try c.readU8();
    return switch (present) {
        0 => null,
        1 => try c.readU64(),
        else => error.BadOptional,
    };
}

// ── entry header ────────────────────────────────────────────────────────

const EntryHeader = struct {
    kind: u8,
    version: u16,
    len: u32,
};

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

/// Read entry header and advance past the payload without interpreting it.
/// Journal readers use this to skip unknown `entry_kind` values via `entry_len`.
pub fn skipEntry(c_data: []const u8) CodecError!usize {
    var c: Cursor = .{ .data = c_data };
    const hdr = try decodeEntryHeader(&c);
    try c.skip(hdr.len);
    return c.pos;
}

// ── ActorId ─────────────────────────────────────────────────────────────

pub fn encodeActorId(w_list: *std.ArrayList(u8), gpa: std.mem.Allocator, actor: ActorId) CodecError!void {
    var w: Writer = .{ .list = w_list, .gpa = gpa };
    try encodeActorIdW(&w, actor);
}

fn encodeActorIdW(w: *Writer, actor: ActorId) CodecError!void {
    switch (actor) {
        .local_user => try w.writeU8(actor_tag_local_user),
        .local_agent => try w.writeU8(actor_tag_local_agent),
        .peer => |id| {
            try w.writeU8(actor_tag_peer);
            try w.writeU32(id);
        },
        .system => try w.writeU8(actor_tag_system),
    }
}

pub fn decodeActorId(data: []const u8) CodecError!struct { actor: ActorId, consumed: usize } {
    var c: Cursor = .{ .data = data };
    const actor = try decodeActorIdC(&c);
    return .{ .actor = actor, .consumed = c.pos };
}

fn decodeActorIdC(c: *Cursor) CodecError!ActorId {
    const tag = try c.readU8();
    return switch (tag) {
        actor_tag_local_user => .local_user,
        actor_tag_local_agent => .local_agent,
        actor_tag_peer => .{ .peer = try c.readU32() },
        actor_tag_system => .system,
        else => error.BadActorTag,
    };
}

// ── CommandRecord entry ─────────────────────────────────────────────────

fn encodeRecordPayload(w: *Writer, rec: *const CommandRecord) CodecError!void {
    try w.writeU64(rec.seq);
    try encodeActorIdW(w, rec.actor);
    try w.writeU8(switch (rec.kind) {
        .normal => kind_normal,
        .revert => kind_revert,
    });
    var flags: u8 = 0;
    if (rec.undoable) flags |= flag_undoable;
    if (rec.reverted) flags |= flag_reverted;
    if (rec.redo_consumed) flags |= flag_redo_consumed;
    try w.writeU8(flags);
    try w.writeU8(rec.name_len);
    try w.writeBytes(rec.name());
    try w.writeU16(rec.args_len);
    try w.writeBytes(rec.args());
    try writeOptionalU64(w, rec.transaction_id);
    try writeOptionalU64(w, rec.target_seq);
    try writeOptionalU64(w, rec.redo_of);
    try writeOptionalU64(w, rec.undo_ref);
    try w.writeU64(rec.epoch);
    try w.writeU16(rec.tx_member_index);
}

fn decodeRecordPayload(c: *Cursor) CodecError!CommandRecord {
    var rec: CommandRecord = .{
        .seq = try c.readU64(),
        .actor = try decodeActorIdC(c),
        .kind = switch (try c.readU8()) {
            kind_normal => .normal,
            kind_revert => .revert,
            else => return error.BadCommandKind,
        },
        .name_len = 0,
        .args_len = 0,
        .transaction_id = null,
        .undoable = false,
    };
    const flags = try c.readU8();
    if ((flags & ~flag_known_mask) != 0) return error.BadFlags;
    rec.undoable = (flags & flag_undoable) != 0;
    rec.reverted = (flags & flag_reverted) != 0;
    rec.redo_consumed = (flags & flag_redo_consumed) != 0;

    const name_len = try c.readU8();
    if (name_len > MAX_CMD_NAME) return error.NameTooLong;
    const name_bytes = try c.readBytes(name_len);
    rec.name_len = name_len;
    @memcpy(rec.name_buf[0..name_len], name_bytes);

    const args_len = try c.readU16();
    if (args_len > MAX_CMD_ARGS) return error.ArgsTooLong;
    const args_bytes = try c.readBytes(args_len);
    rec.args_len = args_len;
    @memcpy(rec.args_buf[0..args_len], args_bytes);

    rec.transaction_id = try readOptionalU64(c);
    rec.target_seq = try readOptionalU64(c);
    rec.redo_of = try readOptionalU64(c);
    rec.undo_ref = try readOptionalU64(c);
    rec.epoch = try c.readU64();
    rec.tx_member_index = try c.readU16();
    if (!c.atEnd()) return error.TrailingBytes;
    return rec;
}

/// Encode one CommandRecord as a self-describing entry (header + payload). Count-independent.
pub fn encodeCommandRecordEntry(gpa: std.mem.Allocator, rec: *const CommandRecord) CodecError![]u8 {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    var pw: Writer = .{ .list = &payload, .gpa = gpa };
    try encodeRecordPayload(&pw, rec);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var w: Writer = .{ .list = &out, .gpa = gpa };
    try encodeEntryHeader(&w, entry_kind_record, entry_version, @intCast(payload.items.len));
    try w.writeBytes(payload.items);
    return out.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

/// Decode one CommandRecord entry. Cursor must be exactly one entry; returns consumed byte count.
pub fn decodeCommandRecordEntry(data: []const u8) CodecError!struct { record: CommandRecord, consumed: usize } {
    var c: Cursor = .{ .data = data };
    const hdr = try decodeEntryHeader(&c);
    if (hdr.kind != entry_kind_record) return error.BadEntryKind;
    if (hdr.version != entry_version) return error.BadEntryVersion;
    var payload = try c.subCursor(hdr.len);
    const rec = try decodeRecordPayload(&payload);
    return .{ .record = rec, .consumed = c.pos };
}

// ── Actor epoch entry ───────────────────────────────────────────────────

fn encodeActorEpochPayload(w: *Writer, slot: ActorEpochState) CodecError!void {
    try encodeActorIdW(w, slot.actor);
    try w.writeU64(slot.epoch);
}

fn decodeActorEpochPayload(c: *Cursor) CodecError!ActorEpochState {
    const slot: ActorEpochState = .{
        .actor = try decodeActorIdC(c),
        .epoch = try c.readU64(),
    };
    if (!c.atEnd()) return error.TrailingBytes;
    return slot;
}

pub fn encodeActorEpochEntry(gpa: std.mem.Allocator, slot: ActorEpochState) CodecError![]u8 {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    var pw: Writer = .{ .list = &payload, .gpa = gpa };
    try encodeActorEpochPayload(&pw, slot);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var w: Writer = .{ .list = &out, .gpa = gpa };
    try encodeEntryHeader(&w, entry_kind_actor_epoch, entry_version, @intCast(payload.items.len));
    try w.writeBytes(payload.items);
    return out.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

pub fn decodeActorEpochEntry(data: []const u8) CodecError!struct { slot: ActorEpochState, consumed: usize } {
    var c: Cursor = .{ .data = data };
    const hdr = try decodeEntryHeader(&c);
    if (hdr.kind != entry_kind_actor_epoch) return error.BadEntryKind;
    if (hdr.version != entry_version) return error.BadEntryVersion;
    var payload = try c.subCursor(hdr.len);
    const slot = try decodeActorEpochPayload(&payload);
    return .{ .slot = slot, .consumed = c.pos };
}

// ── Transaction slot entry ──────────────────────────────────────────────

fn encodeTransactionSlotPayload(w: *Writer, slot_index: u8, slot: TransactionSlotState) CodecError!void {
    try w.writeU8(slot_index);
    try w.writeU8(if (slot.open) 1 else 0);
    try w.writeU32(slot.generation);
    try w.writeU64(slot.id);
    try encodeActorIdW(w, slot.actor);
    try w.writeU8(slot.label_len);
    try w.writeBytes(slot.label());
    try w.writeU16(slot.undoable_member_count);
}

fn decodeTransactionSlotPayload(c: *Cursor) CodecError!struct { index: u8, slot: TransactionSlotState } {
    const index = try c.readU8();
    const open_b = try c.readU8();
    if (open_b > 1) return error.BadOptional;
    var slot: TransactionSlotState = .{
        .open = open_b == 1,
        .generation = try c.readU32(),
        .id = try c.readU64(),
        .actor = try decodeActorIdC(c),
        .label_len = 0,
        .undoable_member_count = 0,
    };
    const label_len = try c.readU8();
    if (label_len > MAX_TX_LABEL) return error.LabelTooLong;
    const label_bytes = try c.readBytes(label_len);
    slot.label_len = label_len;
    @memcpy(slot.label_buf[0..label_len], label_bytes);
    slot.undoable_member_count = try c.readU16();
    if (!c.atEnd()) return error.TrailingBytes;
    return .{ .index = index, .slot = slot };
}

pub fn encodeTransactionSlotEntry(gpa: std.mem.Allocator, slot_index: u8, slot: TransactionSlotState) CodecError![]u8 {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    var pw: Writer = .{ .list = &payload, .gpa = gpa };
    try encodeTransactionSlotPayload(&pw, slot_index, slot);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var w: Writer = .{ .list = &out, .gpa = gpa };
    try encodeEntryHeader(&w, entry_kind_transaction_slot, entry_version, @intCast(payload.items.len));
    try w.writeBytes(payload.items);
    return out.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

pub fn decodeTransactionSlotEntry(data: []const u8) CodecError!struct { index: u8, slot: TransactionSlotState, consumed: usize } {
    var c: Cursor = .{ .data = data };
    const hdr = try decodeEntryHeader(&c);
    if (hdr.kind != entry_kind_transaction_slot) return error.BadEntryKind;
    if (hdr.version != entry_version) return error.BadEntryVersion;
    var payload = try c.subCursor(hdr.len);
    const decoded = try decodeTransactionSlotPayload(&payload);
    return .{ .index = decoded.index, .slot = decoded.slot, .consumed = c.pos };
}

// ── CMDL snapshot wrapper ───────────────────────────────────────────────

/// Encode full CommandLog + Executor persistence state as a CMDL snapshot.
/// Does not mutate runtime state. Caller frees the returned slice.
pub fn encodePersistentStateSnapshot(gpa: std.mem.Allocator, log: *const CommandLog, exec: *const Executor) CodecError![]u8 {
    const log_state = log.exportState();
    const exec_state = exec.exportState();
    return encodePersistentStateSnapshotFromStates(gpa, log_state, exec_state);
}

pub fn encodePersistentStateSnapshotFromStates(
    gpa: std.mem.Allocator,
    log_state: CommandLogState,
    exec_state: ExecutorState,
) CodecError![]u8 {
    if (log_state.filled > MAX_CMD_LOG) return error.CountExceeded;
    if (exec_state.actor_count > MAX_ACTORS) return error.CountExceeded;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var w: Writer = .{ .list = &out, .gpa = gpa };

    try w.writeBytes(&magic_cmdl);
    try w.writeU16(snapshot_version);
    try w.writeU16(0); // flags
    try w.writeU32(log_state.filled);
    try w.writeU32(log_state.head);
    try w.writeU64(log_state.next_seq);
    try w.writeU64(exec_state.next_transaction_id);
    try w.writeU32(exec_state.actor_count);
    try w.writeU32(MAX_OPEN_TX);

    var i: u32 = 0;
    while (i < log_state.filled) : (i += 1) {
        const entry = try encodeCommandRecordEntry(gpa, &log_state.records[i]);
        defer gpa.free(entry);
        try w.writeBytes(entry);
    }
    i = 0;
    while (i < exec_state.actor_count) : (i += 1) {
        const entry = try encodeActorEpochEntry(gpa, exec_state.actors[i]);
        defer gpa.free(entry);
        try w.writeBytes(entry);
    }
    i = 0;
    while (i < MAX_OPEN_TX) : (i += 1) {
        const entry = try encodeTransactionSlotEntry(gpa, @intCast(i), exec_state.transactions[i]);
        defer gpa.free(entry);
        try w.writeBytes(entry);
    }

    return out.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

/// Decode a CMDL snapshot into log and executor. On failure neither target is mutated.
pub fn decodePersistentStateSnapshot(data: []const u8, log: *CommandLog, exec: *Executor) CodecError!void {
    var c: Cursor = .{ .data = data };
    const magic = try c.readBytes(4);
    if (!std.mem.eql(u8, magic, &magic_cmdl)) return error.BadMagic;
    const version = try c.readU16();
    if (version != snapshot_version) return error.BadVersion;
    const flags = try c.readU16();
    if (flags != 0) return error.BadFlags;

    const record_count = try c.readU32();
    if (record_count > MAX_CMD_LOG) return error.CountExceeded;
    const head = try c.readU32();
    if (head >= MAX_CMD_LOG and !(record_count == 0 and head == 0)) {
        // head is always in 0..MAX_CMD_LOG-1 when filled, or 0 when empty; accept any head < MAX_CMD_LOG
    }
    if (head >= MAX_CMD_LOG) return error.BadCount;
    const next_seq = try c.readU64();
    const next_transaction_id = try c.readU64();
    const actor_count = try c.readU32();
    if (actor_count > MAX_ACTORS) return error.CountExceeded;
    const tx_slot_count = try c.readU32();
    if (tx_slot_count != MAX_OPEN_TX) return error.BadCount;

    var log_state: CommandLogState = .{
        .filled = record_count,
        .head = head,
        .next_seq = next_seq,
        .records = undefined,
    };

    var seen_seq: [MAX_CMD_LOG]u64 = undefined;
    var max_seq: u64 = 0;
    var has_any_seq = false;
    // Collect transaction ids from records and slots; next_transaction_id must exceed all of them.
    var seen_tx_ids: [MAX_CMD_LOG + MAX_OPEN_TX]u64 = undefined;
    var seen_tx_count: u32 = 0;

    var i: u32 = 0;
    while (i < record_count) : (i += 1) {
        const start = c.pos;
        const rem = c.data[c.pos..];
        const decoded = try decodeCommandRecordEntry(rem);
        c.pos = start + decoded.consumed;
        // duplicate seq check
        var j: u32 = 0;
        while (j < i) : (j += 1) {
            if (seen_seq[j] == decoded.record.seq) return error.DuplicateSeq;
        }
        seen_seq[i] = decoded.record.seq;
        if (!has_any_seq or decoded.record.seq > max_seq) {
            max_seq = decoded.record.seq;
            has_any_seq = true;
        }
        if (decoded.record.transaction_id) |tid| {
            if (tid == 0) return error.BadTransactionId;
            // Records may share a transaction_id (members of one open/closed tx). Track max only
            // via seen list for next_transaction_id; do not reject shared ids across records.
            var already = false;
            var k: u32 = 0;
            while (k < seen_tx_count) : (k += 1) {
                if (seen_tx_ids[k] == tid) {
                    already = true;
                    break;
                }
            }
            if (!already) {
                seen_tx_ids[seen_tx_count] = tid;
                seen_tx_count += 1;
            }
        }
        log_state.records[i] = decoded.record;
    }

    // next append issues `next_seq` then increments; reuse would collide with an existing record.
    if (has_any_seq and next_seq <= max_seq) return error.BadNextSeq;

    var exec_state: ExecutorState = .{
        .actor_count = actor_count,
        .next_transaction_id = next_transaction_id,
        .actors = undefined,
        .transactions = [_]TransactionSlotState{.{}} ** MAX_OPEN_TX,
    };

    i = 0;
    while (i < actor_count) : (i += 1) {
        const start = c.pos;
        const rem = c.data[c.pos..];
        const decoded = try decodeActorEpochEntry(rem);
        c.pos = start + decoded.consumed;
        var j: u32 = 0;
        while (j < i) : (j += 1) {
            if (exec_state.actors[j].actor.eql(decoded.slot.actor)) return error.DuplicateActor;
        }
        exec_state.actors[i] = decoded.slot;
    }

    i = 0;
    while (i < MAX_OPEN_TX) : (i += 1) {
        const start = c.pos;
        const rem = c.data[c.pos..];
        const decoded = try decodeTransactionSlotEntry(rem);
        c.pos = start + decoded.consumed;
        if (decoded.index != i) return error.BadCount;
        const slot = decoded.slot;
        if (slot.open) {
            // Open slot must carry a real id (allocTransactionId starts at 1).
            if (slot.id == 0) return error.BadTransactionId;
        }
        if (slot.id != 0) {
            // Slot ids are never reused; reject duplicates across the table.
            var k: u32 = 0;
            while (k < seen_tx_count) : (k += 1) {
                if (seen_tx_ids[k] == slot.id) {
                    // Same id may already appear on records that belong to this tx — that is fine.
                    // Only reject when another *slot* already claimed this id.
                    break;
                }
            }
            // Check other slots already written into exec_state.
            var s: u32 = 0;
            while (s < i) : (s += 1) {
                if (exec_state.transactions[s].id != 0 and exec_state.transactions[s].id == slot.id) {
                    return error.DuplicateTransactionId;
                }
            }
            // Track for next_transaction_id bound.
            var already = false;
            k = 0;
            while (k < seen_tx_count) : (k += 1) {
                if (seen_tx_ids[k] == slot.id) {
                    already = true;
                    break;
                }
            }
            if (!already) {
                seen_tx_ids[seen_tx_count] = slot.id;
                seen_tx_count += 1;
            }
        }
        exec_state.transactions[i] = slot;
    }

    // next beginTransaction issues `next_transaction_id`; it must not collide with any known id.
    var t: u32 = 0;
    while (t < seen_tx_count) : (t += 1) {
        if (next_transaction_id <= seen_tx_ids[t]) return error.BadNextTransactionId;
    }
    // Exhausted counter cannot issue a new id.
    if (next_transaction_id == std.math.maxInt(u64) and seen_tx_count > 0) {
        // still valid if no new tx will be opened; keep accepting (runtime rejects begin).
    }

    if (!c.atEnd()) return error.TrailingBytes;

    log.restoreState(log_state);
    exec.restoreState(exec_state);
}

// ── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn sampleRecord() CommandRecord {
    var rec: CommandRecord = .{
        .seq = 42,
        .actor = .{ .peer = 9 },
        .kind = .normal,
        .name_len = 0,
        .args_len = 0,
        .transaction_id = 7,
        .undoable = true,
        .reverted = true,
        .redo_consumed = false,
        .target_seq = null,
        .redo_of = 3,
        .undo_ref = 100,
        .epoch = 2,
        .tx_member_index = 1,
    };
    const name = "stroke";
    rec.name_len = name.len;
    @memcpy(rec.name_buf[0..name.len], name);
    const args = "xy";
    rec.args_len = args.len;
    @memcpy(rec.args_buf[0..args.len], args);
    return rec;
}

test "command record entry round-trip preserves one record" {
    const gpa = testing.allocator;
    const rec = sampleRecord();
    const bytes = try encodeCommandRecordEntry(gpa, &rec);
    defer gpa.free(bytes);

    const decoded = try decodeCommandRecordEntry(bytes);
    try testing.expectEqual(bytes.len, decoded.consumed);
    try testing.expectEqual(rec.seq, decoded.record.seq);
    try testing.expect(rec.actor.eql(decoded.record.actor));
    try testing.expectEqual(rec.kind, decoded.record.kind);
    try testing.expectEqual(rec.undoable, decoded.record.undoable);
    try testing.expectEqual(rec.reverted, decoded.record.reverted);
    try testing.expectEqual(rec.redo_consumed, decoded.record.redo_consumed);
    try testing.expectEqual(rec.transaction_id, decoded.record.transaction_id);
    try testing.expectEqual(rec.target_seq, decoded.record.target_seq);
    try testing.expectEqual(rec.redo_of, decoded.record.redo_of);
    try testing.expectEqual(rec.undo_ref, decoded.record.undo_ref);
    try testing.expectEqual(rec.epoch, decoded.record.epoch);
    try testing.expectEqual(rec.tx_member_index, decoded.record.tx_member_index);
    try testing.expectEqualStrings(rec.name(), decoded.record.name());
    try testing.expectEqualStrings(rec.args(), decoded.record.args());
}

test "command entry codec does not depend on record count" {
    const gpa = testing.allocator;
    var r1 = sampleRecord();
    r1.seq = 1;
    var r2 = sampleRecord();
    r2.seq = 2;
    r2.kind = .revert;
    r2.target_seq = 1;
    r2.redo_of = null;
    r2.actor = .local_user;

    const e1 = try encodeCommandRecordEntry(gpa, &r1);
    defer gpa.free(e1);
    const e2 = try encodeCommandRecordEntry(gpa, &r2);
    defer gpa.free(e2);

    // Concatenate two independent entries (no count header between them).
    var cat: std.ArrayList(u8) = .empty;
    defer cat.deinit(gpa);
    try cat.appendSlice(gpa, e1);
    try cat.appendSlice(gpa, e2);

    // Entry layer has no count: first decode consumes only e1.
    const d1 = try decodeCommandRecordEntry(cat.items);
    try testing.expectEqual(e1.len, d1.consumed);
    try testing.expectEqual(@as(u64, 1), d1.record.seq);

    const d2 = try decodeCommandRecordEntry(cat.items[d1.consumed..]);
    try testing.expectEqual(e2.len, d2.consumed);
    try testing.expectEqual(@as(u64, 2), d2.record.seq);
    try testing.expectEqual(CommandKind.revert, d2.record.kind);

    // Unknown entry_kind can be skipped via entry_len only.
    var unknown: std.ArrayList(u8) = .empty;
    defer unknown.deinit(gpa);
    var uw: Writer = .{ .list = &unknown, .gpa = gpa };
    try encodeEntryHeader(&uw, 99, entry_version, 3);
    try uw.writeBytes(&[_]u8{ 0xAA, 0xBB, 0xCC });

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    try stream.appendSlice(gpa, e1);
    try stream.appendSlice(gpa, unknown.items);
    try stream.appendSlice(gpa, e2);

    const s1 = try decodeCommandRecordEntry(stream.items);
    try testing.expectEqual(@as(u64, 1), s1.record.seq);
    const skipped = try skipEntry(stream.items[s1.consumed..]);
    try testing.expectEqual(unknown.items.len, skipped);
    const s2 = try decodeCommandRecordEntry(stream.items[s1.consumed + skipped ..]);
    try testing.expectEqual(@as(u64, 2), s2.record.seq);
}

test "command actor and transaction entries round-trip independently" {
    const gpa = testing.allocator;

    const epoch_slot: ActorEpochState = .{ .actor = .local_agent, .epoch = 5 };
    const epoch_bytes = try encodeActorEpochEntry(gpa, epoch_slot);
    defer gpa.free(epoch_bytes);
    const epoch_decoded = try decodeActorEpochEntry(epoch_bytes);
    try testing.expectEqual(epoch_bytes.len, epoch_decoded.consumed);
    try testing.expect(epoch_slot.actor.eql(epoch_decoded.slot.actor));
    try testing.expectEqual(epoch_slot.epoch, epoch_decoded.slot.epoch);

    var tx: TransactionSlotState = .{
        .open = true,
        .id = 3,
        .actor = .system,
        .generation = 4,
        .label_len = 0,
        .undoable_member_count = 2,
    };
    const label = "tx";
    tx.label_len = label.len;
    @memcpy(tx.label_buf[0..label.len], label);
    const tx_bytes = try encodeTransactionSlotEntry(gpa, 1, tx);
    defer gpa.free(tx_bytes);
    const tx_decoded = try decodeTransactionSlotEntry(tx_bytes);
    try testing.expectEqual(tx_bytes.len, tx_decoded.consumed);
    try testing.expectEqual(@as(u8, 1), tx_decoded.index);
    try testing.expect(tx_decoded.slot.open);
    try testing.expectEqual(tx.id, tx_decoded.slot.id);
    try testing.expectEqualStrings("tx", tx_decoded.slot.label());
    try testing.expectEqual(@as(u16, 2), tx_decoded.slot.undoable_member_count);
}

test "command snapshot wrapper round-trip preserves counts and ring state" {
    const gpa = testing.allocator;

    // Build a real log/executor pair through public APIs.
    const MockApp = struct {
        exec: *Executor = undefined,
        next_ref: u64 = 1,
        valid: [64]bool = [_]bool{false} ** 64,

        fn run(ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
            _ = name;
            _ = args;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const ref = self.next_ref;
            self.next_ref += 1;
            self.valid[ref] = true;
            self.exec.noteUndo(ref);
            const n = @min(buf.len, "ok".len);
            @memcpy(buf[0..n], "ok"[0..n]);
            return buf[0..n];
        }
        fn canUndo(ctx: *anyopaque, rec: *const CommandRecord) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const ref = rec.undo_ref orelse return false;
            return ref < self.valid.len and self.valid[ref];
        }
        fn applyUndo(ctx: *anyopaque, rec: *const CommandRecord) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (rec.undo_ref) |ref| {
                if (ref < self.valid.len) self.valid[ref] = false;
            }
        }
        fn summarize(ctx: *anyopaque, rec: *const CommandRecord, buf: []u8) []const u8 {
            _ = ctx;
            const n = @min(rec.name().len, buf.len);
            @memcpy(buf[0..n], rec.name()[0..n]);
            return buf[0..n];
        }
    };

    var app: MockApp = undefined;
    var log: CommandLog = .{};
    var exec = Executor.init(.{ .ctx = &app, .run = MockApp.run });
    exec.log = &log;
    exec.adapter = .{ .ctx = &app, .canUndo = MockApp.canUndo, .applyUndo = MockApp.applyUndo, .summarize = MockApp.summarize };
    app = .{ .exec = &exec };

    var buf: [64]u8 = undefined;
    _ = try exec.executeAction("a", "", .{ .actor = .local_user }, &buf);
    _ = try exec.executeAction("b", "x", .{ .actor = .{ .peer = 2 } }, &buf);
    const tx = try exec.beginTransaction(.local_user, "open");
    _ = try exec.executeAction("c", "", .{ .actor = .local_user, .transaction = tx }, &buf);
    // leave transaction open

    const orig_filled = log.filled;
    const orig_head = log.head;
    const orig_next_seq = log.next_seq;
    const orig_next_tx = exec.next_transaction_id;
    const orig_actor_count = exec.actor_count;

    const bytes = try encodePersistentStateSnapshot(gpa, &log, &exec);
    defer gpa.free(bytes);

    var app2: MockApp = undefined;
    var log2: CommandLog = .{};
    var exec2 = Executor.init(.{ .ctx = &app2, .run = MockApp.run });
    exec2.log = &log2;
    exec2.adapter = .{ .ctx = &app2, .canUndo = MockApp.canUndo, .applyUndo = MockApp.applyUndo, .summarize = MockApp.summarize };
    app2 = .{ .exec = &exec2 };
    // Seed different state so restore must overwrite.
    _ = try exec2.executeAction("zzz", "", .{ .actor = .system }, &buf);

    try decodePersistentStateSnapshot(bytes, &log2, &exec2);
    try testing.expectEqual(orig_filled, log2.filled);
    try testing.expectEqual(orig_head, log2.head);
    try testing.expectEqual(orig_next_seq, log2.next_seq);
    try testing.expectEqual(orig_next_tx, exec2.next_transaction_id);
    try testing.expectEqual(orig_actor_count, exec2.actor_count);
    try testing.expectEqualStrings("a", log2.recordAt(0).name());
    try testing.expectEqualStrings("b", log2.recordAt(1).name());
    try testing.expectEqualStrings("c", log2.recordAt(2).name());
    try testing.expect(log2.recordAt(1).actor.eql(.{ .peer = 2 }));
    try testing.expect(exec2.tx_table[tx.index].open);
    try testing.expectEqualStrings("open", exec2.tx_table[tx.index].label_buf[0..exec2.tx_table[tx.index].label_len]);
}

test "command entry codec rejects malformed input without mutation" {
    const gpa = testing.allocator;

    // bad entry kind on record decode
    var bad_kind: std.ArrayList(u8) = .empty;
    defer bad_kind.deinit(gpa);
    var w: Writer = .{ .list = &bad_kind, .gpa = gpa };
    try encodeEntryHeader(&w, 55, entry_version, 0);
    try testing.expectError(error.BadEntryKind, decodeCommandRecordEntry(bad_kind.items));

    // truncated payload
    const rec = sampleRecord();
    const good = try encodeCommandRecordEntry(gpa, &rec);
    defer gpa.free(good);
    try testing.expectError(error.UnexpectedEnd, decodeCommandRecordEntry(good[0 .. good.len - 1]));

    // trailing bytes inside entry payload (inflate entry_len and append junk)
    var inflated: std.ArrayList(u8) = .empty;
    defer inflated.deinit(gpa);
    try inflated.appendSlice(gpa, good);
    // bump entry_len by 1 and append a trailing byte inside the claimed payload
    const old_len = std.mem.readInt(u32, inflated.items[3..7], .little);
    std.mem.writeInt(u32, inflated.items[3..7], old_len + 1, .little);
    try inflated.append(gpa, 0xFF);
    try testing.expectError(error.TrailingBytes, decodeCommandRecordEntry(inflated.items));

    // Snapshot malformed: bad magic must not touch targets
    var app: struct {
        fn run(ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
            _ = ctx;
            _ = name;
            _ = args;
            return buf[0..0];
        }
    } = .{};
    var log: CommandLog = .{};
    var exec = Executor.init(.{ .ctx = @ptrCast(&app), .run = @TypeOf(app).run });
    // seed
    log.append(.{
        .seq = 1,
        .actor = .local_user,
        .kind = .normal,
        .name_len = 1,
        .name_buf = .{'x'} ++ .{undefined} ** (MAX_CMD_NAME - 1),
        .args_len = 0,
        .transaction_id = null,
        .undoable = true,
    });
    // Keep next_seq strictly above max record seq (semantic invariant for decode).
    log.next_seq = 2;
    const filled_before = log.filled;
    const next_before = log.next_seq;

    try testing.expectError(error.BadMagic, decodePersistentStateSnapshot("XXXX", &log, &exec));
    try testing.expectEqual(filled_before, log.filled);
    try testing.expectEqual(next_before, log.next_seq);

    // version mismatch
    var bad_ver = try encodePersistentStateSnapshot(gpa, &log, &exec);
    defer gpa.free(bad_ver);
    std.mem.writeInt(u16, bad_ver[4..6], 99, .little);
    try testing.expectError(error.BadVersion, decodePersistentStateSnapshot(bad_ver, &log, &exec));
    try testing.expectEqual(filled_before, log.filled);

    // trailing bytes after valid snapshot
    var with_trail: std.ArrayList(u8) = .empty;
    defer with_trail.deinit(gpa);
    const good_snap = try encodePersistentStateSnapshot(gpa, &log, &exec);
    defer gpa.free(good_snap);
    try with_trail.appendSlice(gpa, good_snap);
    try with_trail.append(gpa, 0);
    try testing.expectError(error.TrailingBytes, decodePersistentStateSnapshot(with_trail.items, &log, &exec));
    try testing.expectEqual(filled_before, log.filled);

    // invalid actor tag
    try testing.expectError(error.BadActorTag, decodeActorId(&[_]u8{0xFE}));
}

test "command snapshot rejects next_seq that would reuse a record seq" {
    const gpa = testing.allocator;
    var app: struct {
        fn run(ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
            _ = ctx;
            _ = name;
            _ = args;
            return buf[0..0];
        }
    } = .{};
    var log: CommandLog = .{};
    var exec = Executor.init(.{ .ctx = @ptrCast(&app), .run = @TypeOf(app).run });
    log.append(.{
        .seq = 5,
        .actor = .local_user,
        .kind = .normal,
        .name_len = 1,
        .name_buf = .{'a'} ++ .{undefined} ** (MAX_CMD_NAME - 1),
        .args_len = 0,
        .transaction_id = null,
        .undoable = true,
    });
    log.next_seq = 6;
    const bytes = try encodePersistentStateSnapshot(gpa, &log, &exec);
    defer gpa.free(bytes);
    // Patch next_seq (after magic4 + ver2 + flags2 + record_count4 + head4) to equal max seq.
    // Layout: [0..4) magic, [4..6) ver, [6..8) flags, [8..12) record_count, [12..16) head, [16..24) next_seq
    std.mem.writeInt(u64, bytes[16..24], 5, .little);

    var log2: CommandLog = .{};
    var exec2 = Executor.init(.{ .ctx = @ptrCast(&app), .run = @TypeOf(app).run });
    try testing.expectError(error.BadNextSeq, decodePersistentStateSnapshot(bytes, &log2, &exec2));
    try testing.expectEqual(@as(u32, 0), log2.filled);
}

test "command snapshot rejects zero and duplicate transaction slot ids" {
    const gpa = testing.allocator;
    var app: struct {
        fn run(ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
            _ = ctx;
            _ = name;
            _ = args;
            return buf[0..0];
        }
    } = .{};
    var log: CommandLog = .{};
    var exec = Executor.init(.{ .ctx = @ptrCast(&app), .run = @TypeOf(app).run });

    // Open a real transaction so encode produces a valid baseline, then patch.
    const tx = try exec.beginTransaction(.local_user, "t");
    _ = tx;
    const bytes = try encodePersistentStateSnapshot(gpa, &log, &exec);
    defer gpa.free(bytes);

    // Locate transaction slot entries after records (0) + actors. Easier: rebuild a hand-crafted snapshot.
    var crafted: std.ArrayList(u8) = .empty;
    defer crafted.deinit(gpa);
    var w: Writer = .{ .list = &crafted, .gpa = gpa };
    try w.writeBytes(&magic_cmdl);
    try w.writeU16(snapshot_version);
    try w.writeU16(0);
    try w.writeU32(0); // record_count
    try w.writeU32(0); // head
    try w.writeU64(1); // next_seq
    try w.writeU64(10); // next_transaction_id
    try w.writeU32(0); // actor_count
    try w.writeU32(MAX_OPEN_TX);

    // Slot 0: open with id=0 → BadTransactionId
    {
        const slot: TransactionSlotState = .{ .open = true, .id = 0, .actor = .local_user, .generation = 0 };
        const e = try encodeTransactionSlotEntry(gpa, 0, slot);
        defer gpa.free(e);
        try w.writeBytes(e);
    }
    var si: u8 = 1;
    while (si < MAX_OPEN_TX) : (si += 1) {
        const e = try encodeTransactionSlotEntry(gpa, si, .{});
        defer gpa.free(e);
        try w.writeBytes(e);
    }

    var log2: CommandLog = .{};
    var exec2 = Executor.init(.{ .ctx = @ptrCast(&app), .run = @TypeOf(app).run });
    try testing.expectError(error.BadTransactionId, decodePersistentStateSnapshot(crafted.items, &log2, &exec2));

    // Duplicate open slot ids
    crafted.clearRetainingCapacity();
    w = .{ .list = &crafted, .gpa = gpa };
    try w.writeBytes(&magic_cmdl);
    try w.writeU16(snapshot_version);
    try w.writeU16(0);
    try w.writeU32(0);
    try w.writeU32(0);
    try w.writeU64(1);
    try w.writeU64(10);
    try w.writeU32(0);
    try w.writeU32(MAX_OPEN_TX);
    {
        const slot0: TransactionSlotState = .{ .open = true, .id = 3, .actor = .local_user };
        const slot1: TransactionSlotState = .{ .open = true, .id = 3, .actor = .local_agent };
        const e0 = try encodeTransactionSlotEntry(gpa, 0, slot0);
        defer gpa.free(e0);
        const e1 = try encodeTransactionSlotEntry(gpa, 1, slot1);
        defer gpa.free(e1);
        try w.writeBytes(e0);
        try w.writeBytes(e1);
        si = 2;
        while (si < MAX_OPEN_TX) : (si += 1) {
            const e = try encodeTransactionSlotEntry(gpa, si, .{});
            defer gpa.free(e);
            try w.writeBytes(e);
        }
    }
    try testing.expectError(error.DuplicateTransactionId, decodePersistentStateSnapshot(crafted.items, &log2, &exec2));
}

test "command snapshot rejects next_transaction_id not above known ids" {
    const gpa = testing.allocator;
    var app: struct {
        fn run(ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
            _ = ctx;
            _ = name;
            _ = args;
            return buf[0..0];
        }
    } = .{};
    var log: CommandLog = .{};
    var exec = Executor.init(.{ .ctx = @ptrCast(&app), .run = @TypeOf(app).run });
    _ = try exec.beginTransaction(.local_user, "open");
    const bytes = try encodePersistentStateSnapshot(gpa, &log, &exec);
    defer gpa.free(bytes);
    // next_transaction_id is at offset 24 after next_seq (u64 at 16).
    // Layout: magic4 + ver2 + flags2 + rec4 + head4 + next_seq8 + next_tx8
    // Patch next_transaction_id down to 1 (open slot id is also 1).
    std.mem.writeInt(u64, bytes[24..32], 1, .little);

    var log2: CommandLog = .{};
    var exec2 = Executor.init(.{ .ctx = @ptrCast(&app), .run = @TypeOf(app).run });
    try testing.expectError(error.BadNextTransactionId, decodePersistentStateSnapshot(bytes, &log2, &exec2));
    try testing.expectEqual(@as(u32, 0), log2.filled);
}
