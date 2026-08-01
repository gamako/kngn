//! Compose the editor's history onto a payload-agnostic journal store.
//!
//! The journal (`appshell.history_journal`) frames opaque byte records; the meaning of a
//! record lives here. Two record kinds are used:
//!
//! - `kind_op`: one immutable undo `Op`, encoded by `undo_io.encodeOpPayload`. An Op's
//!   bytes never change once written, so a record is written once and referenced by id
//!   from then on.
//! - `kind_index`: the mutable part — which op records make up the undo and redo stacks,
//!   in order, plus each undo entry's handle and owner tag, the next handle, and the
//!   command-log snapshot from `command_io`. It also carries the CRC of the document file
//!   the history belongs to.
//!
//! Splitting immutable payloads from a small mutable index is what makes the journal
//! append-only in practice: committing an edit appends the new Op once, and saving appends
//! an index of a few kilobytes. Nothing rewrites the payloads that are already there.
//!
//! Restoring is a direct read of the newest index whose document CRC matches the file that
//! was actually opened — there is no replay of stack mutations, so the restored stack
//! cannot drift from what the runtime had.
//!
//! Hot-path declaration: append runs when a document is saved; restore runs when one is
//! opened. Neither runs per frame or per audio sample.

const std = @import("std");
const kit = @import("kit");
const core = @import("paint");

const platform = kit.platform;
const appshell = kit.appshell;

const journal = appshell.history_journal;
const command_io = platform.command_io;
const undo_io = core.undo_io;

const CommandLog = platform.command.CommandLog;
const Executor = platform.command.Executor;
const UndoStack = core.UndoStack;

pub const kind_op: u8 = 1;
pub const kind_index: u8 = 2;
pub const record_version: u16 = 1;

pub const index_magic: [4]u8 = "HIDX".*;

/// Identify the document bytes a history belongs to.
///
/// Deliberately **not** CRC-32 over the whole file. A document container that ends with the
/// CRC-32 of everything before it — which the editor's format does — has the same CRC-32
/// over its entire contents no matter what it holds: that value is the algorithm's residue
/// constant. Binding on it would accept every well-formed document, which is the opposite
/// of a binding. A non-CRC hash has no such fixed point.
pub fn documentDigest(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

/// Ceiling on the bytes of history persisted for one document.
///
/// An ordinary stroke is a pixel diff of a few kilobytes, so this is never approached in
/// normal use. It exists for the structural edits that carry whole layers: a merge-down on
/// a maximum-size canvas (16M pixels) holds two full pixel arrays plus a cel snapshot,
/// about 192MB in one Op. The budget is spent newest-first, so the ops a user is most
/// likely to undo are the ones that survive; older ops beyond the budget stay in memory
/// for the session and are simply not persisted.
pub const max_document_bytes: u64 = 64 * 1024 * 1024;

/// When the file (live plus reclaimable bytes) grows past this, the next save rewrites the
/// whole journal instead of appending. Superseded index records and redo payloads that a
/// prefix-only drop cannot reach are collected this way.
pub const rebuild_threshold: u64 = 2 * max_document_bytes;

/// Journal size up to which reclaiming dead records after a save is done unconditionally.
pub const compact_eager_limit: u64 = 8 * 1024 * 1024;

/// How far back a load looks for an index whose document CRC matches. The newest index
/// always describes the last save, so more than a couple is already defensive.
const index_lookback: usize = 8;

pub const SaveOutcome = struct {
    /// True when an index record was appended, i.e. this document state is restorable.
    persisted: bool = false,
    undo_records: usize = 0,
    redo_records: usize = 0,
    /// Undo entries left out because the per-document budget was reached.
    dropped_by_budget: usize = 0,
    bytes: u64 = 0,
};

pub const LoadStatus = enum {
    restored,
    /// No store: an unsaved document, or a target with no writable application data.
    no_store,
    /// The journal exists but holds no index for this document's current contents.
    no_match,
    /// An index matched but its records could not be turned back into a history.
    decode_failed,
};

pub const LoadOutcome = struct {
    status: LoadStatus,
    undo_records: usize = 0,
    redo_records: usize = 0,
};

/// Binding between a live journal store and the editor's history.
pub const Persist = struct {
    gpa: std.mem.Allocator,
    store: ?journal.Store = null,
    /// Op records already in the journal, keyed by the undo handle they were written for.
    persisted: std.ArrayList(Persisted) = .empty,

    pub const Persisted = struct {
        handle: u64,
        id: journal.RecordId,
        bytes: u64,
    };

    pub fn deinit(self: *Persist) void {
        self.persisted.deinit(self.gpa);
        self.* = undefined;
    }

    /// Attach (or detach, with null) the store for the current document.
    pub fn setStore(self: *Persist, store: ?journal.Store) void {
        self.store = store;
        self.persisted.clearRetainingCapacity();
    }

    fn lookup(self: *const Persist, handle: u64) ?Persisted {
        for (self.persisted.items) |entry| {
            if (entry.handle == handle) return entry;
        }
        return null;
    }

    fn remember(self: *Persist, handle: u64, id: journal.RecordId, bytes: u64) void {
        for (self.persisted.items) |*entry| {
            if (entry.handle == handle) {
                entry.* = .{ .handle = handle, .id = id, .bytes = bytes };
                return;
            }
        }
        // A full table only costs a reuse opportunity, never correctness.
        self.persisted.append(self.gpa, .{ .handle = handle, .id = id, .bytes = bytes }) catch {};
    }

    /// Persist the history that belongs to a document whose bytes hash to `doc_digest`.
    ///
    /// Call after the document file itself has been written, so a crash can never leave an
    /// index claiming to describe a document that was not saved.
    pub fn save(
        self: *Persist,
        stack: *const UndoStack,
        log: *const CommandLog,
        exec: *const Executor,
        doc_digest: u64,
    ) !SaveOutcome {
        return self.saveWithBudget(stack, log, exec, doc_digest, max_document_bytes);
    }

    /// `save` with an explicit per-document byte budget. Tests use a small budget to reach
    /// the truncation path without building a canvas that is megabytes wide.
    pub fn saveWithBudget(
        self: *Persist,
        stack: *const UndoStack,
        log: *const CommandLog,
        exec: *const Executor,
        doc_digest: u64,
        budget: u64,
    ) !SaveOutcome {
        const store = self.store orelse return .{};
        var outcome: SaveOutcome = .{};

        {
            const stats = store.stats();
            if (stats.live_bytes + stats.dropped_bytes > rebuild_threshold) {
                while (store.dropOldest() != null) {}
                try store.compact();
                self.persisted.clearRetainingCapacity();
            }
        }

        const view = stack.stateView();

        // Newest first, so the budget keeps the ops a user is most likely to undo.
        var entries: std.ArrayList(IndexUndoEntry) = .empty;
        defer entries.deinit(self.gpa);
        var used: u64 = 0;
        var i = view.undo.len;
        while (i > 0) : (i -= 1) {
            const idx = i - 1;
            const handle = view.handles[idx];
            if (self.lookup(handle)) |known| {
                if (used + known.bytes > budget) break;
                used += known.bytes;
                try entries.append(self.gpa, .{ .id = known.id, .handle = handle, .owner = view.owners[idx] });
                continue;
            }
            const payload = try undo_io.encodeOpPayload(self.gpa, &view.undo[idx]);
            defer self.gpa.free(payload);
            if (used + payload.len > budget) break;
            const id = store.append(kind_op, record_version, payload) catch break;
            used += payload.len;
            self.remember(handle, id, payload.len);
            try entries.append(self.gpa, .{ .id = id, .handle = handle, .owner = view.owners[idx] });
        }
        outcome.dropped_by_budget = view.undo.len - entries.items.len;
        std.mem.reverse(IndexUndoEntry, entries.items);

        // Redo ops carry no handle (a re-push allocates a fresh one), so they cannot be
        // matched to an existing record and are written afresh. The redo stack is short in
        // practice, and the periodic rebuild collects the superseded copies.
        var redo_ids: std.ArrayList(journal.RecordId) = .empty;
        defer redo_ids.deinit(self.gpa);
        var r = view.redo.len;
        while (r > 0) : (r -= 1) {
            const payload = try undo_io.encodeOpPayload(self.gpa, &view.redo[r - 1]);
            defer self.gpa.free(payload);
            if (used + payload.len > budget) break;
            const id = store.append(kind_op, record_version, payload) catch break;
            used += payload.len;
            try redo_ids.append(self.gpa, id);
        }
        std.mem.reverse(journal.RecordId, redo_ids.items);

        const cmdl = try command_io.encodePersistentStateSnapshot(self.gpa, log, exec);
        defer self.gpa.free(cmdl);

        const index_payload = try encodeIndex(self.gpa, .{
            .doc_digest = doc_digest,
            .next_handle = view.next_handle,
            .undo = entries.items,
            .redo = redo_ids.items,
            .cmdl = cmdl,
        });
        defer self.gpa.free(index_payload);

        // Op payloads must be durable before the index that names them.
        try store.sync();
        const index_id = try store.append(kind_index, record_version, index_payload);
        try store.sync();

        self.collect(store, entries.items, redo_ids.items, index_id);

        outcome.persisted = true;
        outcome.undo_records = entries.items.len;
        outcome.redo_records = redo_ids.items.len;
        outcome.bytes = store.stats().live_bytes;
        return outcome;
    }

    /// Drop every record the freshly written index does not reference, then reclaim the
    /// space once the dropped bytes outweigh the live ones.
    ///
    /// Dropping by id (rather than only from the front) is what keeps a superseded index
    /// record from accumulating one per save: it sits after the op records it replaced,
    /// where a prefix-only drop could never reach it.
    fn collect(
        self: *Persist,
        store: journal.Store,
        undo: []const IndexUndoEntry,
        redo: []const journal.RecordId,
        index_id: journal.RecordId,
    ) void {
        const Sweep = struct {
            undo: []const IndexUndoEntry,
            redo: []const journal.RecordId,
            index_id: journal.RecordId,
            garbage: [256]journal.RecordId = undefined,
            n: usize = 0,
            filled: bool = false,

            fn referenced(ctx: *const @This(), id: journal.RecordId) bool {
                if (id == ctx.index_id) return true;
                for (ctx.undo) |e| {
                    if (e.id == id) return true;
                }
                for (ctx.redo) |rid| {
                    if (rid == id) return true;
                }
                return false;
            }

            fn visit(ctx_ptr: *anyopaque, info: journal.RecordInfo) journal.ScanAction {
                const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr));
                if (ctx.referenced(info.id)) return .continue_scan;
                ctx.garbage[ctx.n] = info.id;
                ctx.n += 1;
                if (ctx.n == ctx.garbage.len) {
                    ctx.filled = true;
                    return .stop;
                }
                return .continue_scan;
            }
        };

        var passes: usize = 0;
        while (passes < 8) : (passes += 1) {
            var sweep: Sweep = .{ .undo = undo, .redo = redo, .index_id = index_id };
            store.scan(&sweep, Sweep.visit);
            if (sweep.n == 0) break;
            for (sweep.garbage[0..sweep.n]) |id| {
                _ = store.drop(id);
                for (self.persisted.items, 0..) |entry, i| {
                    if (entry.id == id) {
                        _ = self.persisted.orderedRemove(i);
                        break;
                    }
                }
            }
            if (!sweep.filled) break;
        }

        // A drop only marks a record dead in memory; `compact` is what makes it stick, so
        // without one here the same garbage is re-indexed on the next open. Reclaiming
        // rewrites the live frames, so it is done eagerly only while the journal is small
        // (the normal case, a few hundred kilobytes); a large one waits until the dead bytes
        // are worth the copy. Frames are copied verbatim, so nothing is ever re-encoded.
        const stats = store.stats();
        const cheap = stats.live_bytes <= compact_eager_limit;
        if (stats.dropped_bytes > 0 and (cheap or stats.dropped_bytes * 4 >= stats.live_bytes)) {
            store.compact() catch {};
        }
    }

    /// Restore the history recorded for a document whose bytes hash to `doc_digest`.
    ///
    /// On any failure the caller's log, executor and undo stack are left exactly as they
    /// were, so a journal from another document — or a broken one — degrades to starting
    /// with no history rather than to a wrong history.
    pub fn load(
        self: *Persist,
        stack: *UndoStack,
        log: *CommandLog,
        exec: *Executor,
        doc_digest: u64,
    ) LoadOutcome {
        const store = self.store orelse return .{ .status = .no_store };
        self.persisted.clearRetainingCapacity();

        const Finder = struct {
            ids: [index_lookback]journal.RecordId = @splat(0),
            n: usize = 0,

            fn visit(ctx_ptr: *anyopaque, info: journal.RecordInfo) journal.ScanAction {
                const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr));
                if (info.kind != kind_index) return .continue_scan;
                if (ctx.n == ctx.ids.len) {
                    std.mem.copyForwards(journal.RecordId, ctx.ids[0 .. ctx.ids.len - 1], ctx.ids[1..]);
                    ctx.n -= 1;
                }
                ctx.ids[ctx.n] = info.id;
                ctx.n += 1;
                return .continue_scan;
            }
        };
        var finder: Finder = .{};
        store.scan(&finder, Finder.visit);

        var k = finder.n;
        while (k > 0) : (k -= 1) {
            var record = store.read(self.gpa, finder.ids[k - 1]) catch continue;
            defer record.deinit();
            var parsed = parseIndex(self.gpa, record.payload) catch continue;
            defer parsed.deinit(self.gpa);
            if (parsed.doc_digest != doc_digest) continue;
            return self.applyIndex(store, stack, log, exec, parsed);
        }
        return .{ .status = .no_match };
    }

    fn applyIndex(
        self: *Persist,
        store: journal.Store,
        stack: *UndoStack,
        log: *CommandLog,
        exec: *Executor,
        parsed: ParsedIndex,
    ) LoadOutcome {
        var owned: core.document.UndoStackOwned = .{};
        var ok = false;
        defer if (!ok) owned.deinit(self.gpa);
        owned.next_handle = parsed.next_handle;

        const sizes = self.gpa.alloc(u64, parsed.undo.len) catch return .{ .status = .decode_failed };
        defer self.gpa.free(sizes);

        for (parsed.undo, sizes) |entry, *size| {
            var record = store.read(self.gpa, entry.id) catch return .{ .status = .decode_failed };
            defer record.deinit();
            size.* = record.payload.len;
            var op = undo_io.decodeOpPayload(self.gpa, record.payload) catch return .{ .status = .decode_failed };
            owned.undo.append(self.gpa, op) catch {
                core.document.freeOp(self.gpa, &op);
                return .{ .status = .decode_failed };
            };
            owned.handles.append(self.gpa, entry.handle) catch return .{ .status = .decode_failed };
            owned.owners.append(self.gpa, entry.owner) catch return .{ .status = .decode_failed };
        }
        for (parsed.redo) |id| {
            var record = store.read(self.gpa, id) catch return .{ .status = .decode_failed };
            defer record.deinit();
            var op = undo_io.decodeOpPayload(self.gpa, record.payload) catch return .{ .status = .decode_failed };
            owned.redo.append(self.gpa, op) catch {
                core.document.freeOp(self.gpa, &op);
                return .{ .status = .decode_failed };
            };
        }

        // Validate before touching anything, so the two restores below cannot half-apply.
        UndoStack.validateOwnedState(&owned) catch return .{ .status = .decode_failed };
        command_io.decodePersistentStateSnapshot(parsed.cmdl, log, exec) catch return .{ .status = .decode_failed };
        stack.restoreState(self.gpa, &owned) catch return .{ .status = .decode_failed };
        ok = true;

        // Sizes come from the records themselves, so the next save's budget accounting starts
        // from the real cost of what is already stored rather than from zero.
        for (parsed.undo, sizes) |entry, bytes| self.remember(entry.handle, entry.id, bytes);
        return .{
            .status = .restored,
            .undo_records = parsed.undo.len,
            .redo_records = parsed.redo.len,
        };
    }
};

// ── index record codec ──────────────────────────────────────────────────

pub const IndexUndoEntry = struct {
    id: journal.RecordId,
    handle: u64,
    owner: u8,
};

pub const IndexInput = struct {
    doc_digest: u64,
    next_handle: u64,
    undo: []const IndexUndoEntry,
    redo: []const journal.RecordId,
    cmdl: []const u8,
};

pub const ParsedIndex = struct {
    doc_digest: u64,
    next_handle: u64,
    undo: []IndexUndoEntry,
    redo: []journal.RecordId,
    cmdl: []u8,

    pub fn deinit(self: *ParsedIndex, gpa: std.mem.Allocator) void {
        gpa.free(self.undo);
        gpa.free(self.redo);
        gpa.free(self.cmdl);
        self.* = undefined;
    }
};

pub const IndexError = error{
    OutOfMemory,
    BadMagic,
    BadVersion,
    BadFlags,
    UnexpectedEnd,
    TrailingBytes,
    CountExceeded,
};

/// ```text
/// magic "HIDX" 4 | version u16 | flags u16 | doc_digest u64 | next_handle u64
/// undo_count u16 | redo_count u16 | cmdl_len u32
/// undo_count x { record_id u64, handle u64, owner u8 }
/// redo_count x { record_id u64 }
/// cmdl bytes
/// ```
pub fn encodeIndex(gpa: std.mem.Allocator, input: IndexInput) IndexError![]u8 {
    if (input.undo.len > UndoStack.max_history or input.redo.len > UndoStack.max_history) return error.CountExceeded;
    if (input.cmdl.len > std.math.maxInt(u32)) return error.CountExceeded;
    const total = 4 + 2 + 2 + 8 + 8 + 2 + 2 + 4 +
        input.undo.len * 17 + input.redo.len * 8 + input.cmdl.len;
    const buf = gpa.alloc(u8, total) catch return error.OutOfMemory;
    errdefer gpa.free(buf);

    var at: usize = 0;
    @memcpy(buf[at..][0..4], &index_magic);
    at += 4;
    std.mem.writeInt(u16, buf[at..][0..2], record_version, .little);
    at += 2;
    std.mem.writeInt(u16, buf[at..][0..2], 0, .little);
    at += 2;
    std.mem.writeInt(u64, buf[at..][0..8], input.doc_digest, .little);
    at += 8;
    std.mem.writeInt(u64, buf[at..][0..8], input.next_handle, .little);
    at += 8;
    std.mem.writeInt(u16, buf[at..][0..2], @intCast(input.undo.len), .little);
    at += 2;
    std.mem.writeInt(u16, buf[at..][0..2], @intCast(input.redo.len), .little);
    at += 2;
    std.mem.writeInt(u32, buf[at..][0..4], @intCast(input.cmdl.len), .little);
    at += 4;
    for (input.undo) |entry| {
        std.mem.writeInt(u64, buf[at..][0..8], entry.id, .little);
        at += 8;
        std.mem.writeInt(u64, buf[at..][0..8], entry.handle, .little);
        at += 8;
        buf[at] = entry.owner;
        at += 1;
    }
    for (input.redo) |id| {
        std.mem.writeInt(u64, buf[at..][0..8], id, .little);
        at += 8;
    }
    @memcpy(buf[at..][0..input.cmdl.len], input.cmdl);
    at += input.cmdl.len;
    std.debug.assert(at == total);
    return buf;
}

pub fn parseIndex(gpa: std.mem.Allocator, data: []const u8) IndexError!ParsedIndex {
    const fixed = 4 + 2 + 2 + 8 + 8 + 2 + 2 + 4;
    if (data.len < fixed) return error.UnexpectedEnd;
    if (!std.mem.eql(u8, data[0..4], &index_magic)) return error.BadMagic;
    if (std.mem.readInt(u16, data[4..6], .little) != record_version) return error.BadVersion;
    if (std.mem.readInt(u16, data[6..8], .little) != 0) return error.BadFlags;
    const doc_digest = std.mem.readInt(u64, data[8..16], .little);
    const next_handle = std.mem.readInt(u64, data[16..24], .little);
    const undo_count = std.mem.readInt(u16, data[24..26], .little);
    const redo_count = std.mem.readInt(u16, data[26..28], .little);
    const cmdl_len = std.mem.readInt(u32, data[28..32], .little);
    if (undo_count > UndoStack.max_history or redo_count > UndoStack.max_history) return error.CountExceeded;

    const body = @as(usize, undo_count) * 17 + @as(usize, redo_count) * 8 + cmdl_len;
    if (data.len < fixed + body) return error.UnexpectedEnd;
    if (data.len != fixed + body) return error.TrailingBytes;

    const undo = gpa.alloc(IndexUndoEntry, undo_count) catch return error.OutOfMemory;
    errdefer gpa.free(undo);
    const redo = gpa.alloc(journal.RecordId, redo_count) catch return error.OutOfMemory;
    errdefer gpa.free(redo);

    var at: usize = fixed;
    for (undo) |*entry| {
        entry.* = .{
            .id = std.mem.readInt(u64, data[at..][0..8], .little),
            .handle = std.mem.readInt(u64, data[at + 8 ..][0..8], .little),
            .owner = data[at + 16],
        };
        at += 17;
    }
    for (redo) |*id| {
        id.* = std.mem.readInt(u64, data[at..][0..8], .little);
        at += 8;
    }
    const cmdl = gpa.dupe(u8, data[at .. at + cmdl_len]) catch return error.OutOfMemory;
    return .{ .doc_digest = doc_digest, .next_handle = next_handle, .undo = undo, .redo = redo, .cmdl = cmdl };
}

// ── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "history index record round-trips and rejects malformed input" {
    const gpa = testing.allocator;
    const undo = [_]IndexUndoEntry{
        .{ .id = 11, .handle = 3, .owner = 1 },
        .{ .id = 12, .handle = 4, .owner = 0 },
    };
    const redo = [_]journal.RecordId{ 20, 21, 22 };
    const bytes = try encodeIndex(gpa, .{
        .doc_digest = 0xDEADBEEFCAFEF00D,
        .next_handle = 9,
        .undo = &undo,
        .redo = &redo,
        .cmdl = "cmdl-body",
    });
    defer gpa.free(bytes);

    var parsed = try parseIndex(gpa, bytes);
    defer parsed.deinit(gpa);
    try testing.expectEqual(@as(u64, 0xDEADBEEFCAFEF00D), parsed.doc_digest);
    try testing.expectEqual(@as(u64, 9), parsed.next_handle);
    try testing.expectEqualSlices(IndexUndoEntry, &undo, parsed.undo);
    try testing.expectEqualSlices(journal.RecordId, &redo, parsed.redo);
    try testing.expectEqualStrings("cmdl-body", parsed.cmdl);

    try testing.expectError(error.UnexpectedEnd, parseIndex(gpa, bytes[0 .. bytes.len - 1]));
    var wrong_magic = try gpa.dupe(u8, bytes);
    defer gpa.free(wrong_magic);
    wrong_magic[0] = 'X';
    try testing.expectError(error.BadMagic, parseIndex(gpa, wrong_magic));
    var wrong_version = try gpa.dupe(u8, bytes);
    defer gpa.free(wrong_version);
    std.mem.writeInt(u16, wrong_version[4..6], 99, .little);
    try testing.expectError(error.BadVersion, parseIndex(gpa, wrong_version));
}

/// Build a document with a handful of pixel edits, save its history, then restore it into
/// a second set of runtime structures.
fn makeStack(gpa: std.mem.Allocator, count: usize) !core.UndoStack {
    var stack: core.UndoStack = .{};
    errdefer stack.deinit(gpa);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const diffs = try gpa.alloc(core.PixelDiff, 1);
        diffs[0] = .{ .idx = @intCast(i), .before = 0, .after = 0xFF112233 };
        stack.push(gpa, .{ .paint = .{ .cel_id = 1, .diffs = diffs, .layer_idx = 0, .frame_idx = 0 } });
    }
    return stack;
}

test "history persist: save then load restores the undo stack through a memory store" {
    const gpa = testing.allocator;
    var mem = journal.MemoryStore.init(gpa);
    defer mem.deinit();

    var persist: Persist = .{ .gpa = gpa };
    defer persist.deinit();
    persist.setStore(mem.store());

    var stack = try makeStack(gpa, 3);
    defer stack.deinit(gpa);
    var log: CommandLog = .{};
    var exec = Executor.init(.{ .ctx = undefined, .run = noopRun });

    const outcome = try persist.save(&stack, &log, &exec, 0xABCD1234);
    try testing.expect(outcome.persisted);
    try testing.expectEqual(@as(usize, 3), outcome.undo_records);
    try testing.expectEqual(@as(usize, 0), outcome.dropped_by_budget);
    // Op payloads plus the index.
    try testing.expectEqual(@as(usize, 4), mem.store().stats().live_count);

    var restored: core.UndoStack = .{};
    defer restored.deinit(gpa);
    var log2: CommandLog = .{};
    var exec2 = Executor.init(.{ .ctx = undefined, .run = noopRun });
    var reader: Persist = .{ .gpa = gpa };
    defer reader.deinit();
    reader.setStore(mem.store());

    const loaded = reader.load(&restored, &log2, &exec2, 0xABCD1234);
    try testing.expectEqual(LoadStatus.restored, loaded.status);
    try testing.expectEqual(@as(usize, 3), restored.undo.items.len);
    try testing.expectEqual(stack.next_handle, restored.next_handle);
    for (stack.handles.items, restored.handles.items) |a, b| try testing.expectEqual(a, b);
    try testing.expectEqual(
        stack.undo.items[2].paint.diffs[0].after,
        restored.undo.items[2].paint.diffs[0].after,
    );
}

test "history persist: a different document checksum yields no history" {
    const gpa = testing.allocator;
    var mem = journal.MemoryStore.init(gpa);
    defer mem.deinit();
    var persist: Persist = .{ .gpa = gpa };
    defer persist.deinit();
    persist.setStore(mem.store());

    var stack = try makeStack(gpa, 2);
    defer stack.deinit(gpa);
    var log: CommandLog = .{};
    var exec = Executor.init(.{ .ctx = undefined, .run = noopRun });
    _ = try persist.save(&stack, &log, &exec, 0x11111111);

    var restored: core.UndoStack = .{};
    defer restored.deinit(gpa);
    var log2: CommandLog = .{};
    var exec2 = Executor.init(.{ .ctx = undefined, .run = noopRun });
    var reader: Persist = .{ .gpa = gpa };
    defer reader.deinit();
    reader.setStore(mem.store());
    const loaded = reader.load(&restored, &log2, &exec2, 0x22222222);
    try testing.expectEqual(LoadStatus.no_match, loaded.status);
    // The caller's stack is untouched.
    try testing.expectEqual(@as(usize, 0), restored.undo.items.len);
}

test "history persist: with no store, save and load are quiet no-ops" {
    const gpa = testing.allocator;
    var persist: Persist = .{ .gpa = gpa };
    defer persist.deinit();

    var stack = try makeStack(gpa, 1);
    defer stack.deinit(gpa);
    var log: CommandLog = .{};
    var exec = Executor.init(.{ .ctx = undefined, .run = noopRun });
    const outcome = try persist.save(&stack, &log, &exec, 1);
    try testing.expect(!outcome.persisted);

    var restored: core.UndoStack = .{};
    defer restored.deinit(gpa);
    try testing.expectEqual(LoadStatus.no_store, persist.load(&restored, &log, &exec, 1).status);
}

test "history persist: an empty journal restores nothing rather than failing" {
    const gpa = testing.allocator;
    var mem = journal.MemoryStore.init(gpa);
    defer mem.deinit();
    var persist: Persist = .{ .gpa = gpa };
    defer persist.deinit();
    persist.setStore(mem.store());

    var restored: core.UndoStack = .{};
    defer restored.deinit(gpa);
    var log: CommandLog = .{};
    var exec = Executor.init(.{ .ctx = undefined, .run = noopRun });
    try testing.expectEqual(LoadStatus.no_match, persist.load(&restored, &log, &exec, 7).status);
}

test "history persist: repeated saves reuse op records instead of appending copies" {
    const gpa = testing.allocator;
    var mem = journal.MemoryStore.init(gpa);
    defer mem.deinit();
    var persist: Persist = .{ .gpa = gpa };
    defer persist.deinit();
    persist.setStore(mem.store());

    var stack = try makeStack(gpa, 4);
    defer stack.deinit(gpa);
    var log: CommandLog = .{};
    var exec = Executor.init(.{ .ctx = undefined, .run = noopRun });

    _ = try persist.save(&stack, &log, &exec, 1);
    const after_first = mem.store().stats().live_count;
    _ = try persist.save(&stack, &log, &exec, 1);
    const after_second = mem.store().stats().live_count;
    // The second save adds one index record and re-writes no Op payload; the superseded
    // index is collected, so the live count does not grow.
    try testing.expectEqual(after_first, after_second);
}

test "history persist: the per-document budget keeps the newest ops" {
    const gpa = testing.allocator;
    var mem = journal.MemoryStore.init(gpa);
    defer mem.deinit();
    var persist: Persist = .{ .gpa = gpa };
    defer persist.deinit();
    persist.setStore(mem.store());

    // Ops large enough that only a few fit a deliberately small budget.
    var stack: core.UndoStack = .{};
    defer stack.deinit(gpa);
    const per_op = 4096;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const diffs = try gpa.alloc(core.PixelDiff, per_op);
        for (diffs, 0..) |*d, j| d.* = .{ .idx = @intCast(j), .before = 0, .after = @intCast(i + 1) };
        stack.push(gpa, .{ .paint = .{ .cel_id = 1, .diffs = diffs, .layer_idx = 0, .frame_idx = 0 } });
    }
    var log: CommandLog = .{};
    var exec = Executor.init(.{ .ctx = undefined, .run = noopRun });

    // One op encodes to more than 4096 * 12 bytes, so a 100KB budget admits only a few.
    const outcome = try persist.saveWithBudget(&stack, &log, &exec, 5, 100 * 1024);
    try testing.expect(outcome.persisted);
    try testing.expect(outcome.undo_records > 0);
    try testing.expect(outcome.undo_records < 8);
    try testing.expectEqual(8 - outcome.undo_records, outcome.dropped_by_budget);

    var restored: core.UndoStack = .{};
    defer restored.deinit(gpa);
    var log2: CommandLog = .{};
    var exec2 = Executor.init(.{ .ctx = undefined, .run = noopRun });
    var reader: Persist = .{ .gpa = gpa };
    defer reader.deinit();
    reader.setStore(mem.store());
    const loaded = reader.load(&restored, &log2, &exec2, 5);
    try testing.expectEqual(LoadStatus.restored, loaded.status);
    try testing.expectEqual(outcome.undo_records, restored.undo.items.len);
    // The retained ops are the newest ones: the last push is on top.
    try testing.expectEqual(
        stack.undo.items[stack.undo.items.len - 1].paint.diffs[0].after,
        restored.undo.items[restored.undo.items.len - 1].paint.diffs[0].after,
    );
}

fn noopRun(ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = ctx;
    _ = name;
    _ = args;
    return buf[0..0];
}

test "history persist: the document digest survives a container that ends with its own CRC" {
    const gpa = testing.allocator;
    // Two different bodies, each followed by its own CRC-32 — the shape of a self-checked
    // document container.
    const bodies = [_][]const u8{ "first document body", "an entirely different body!" };
    var framed: [2][]u8 = undefined;
    for (bodies, 0..) |body, i| {
        framed[i] = try gpa.alloc(u8, body.len + 4);
        @memcpy(framed[i][0..body.len], body);
        std.mem.writeInt(u32, framed[i][body.len..][0..4], std.hash.Crc32.hash(body), .little);
    }
    defer for (framed) |f| gpa.free(f);

    // CRC-32 over the whole framed container collapses to the same residue for both, which is
    // exactly why the binding does not use it.
    try testing.expectEqual(std.hash.Crc32.hash(framed[0]), std.hash.Crc32.hash(framed[1]));
    try testing.expect(documentDigest(framed[0]) != documentDigest(framed[1]));
}

test "history persist: a native journal survives a close and reopen, and reuses op records" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var stack = try makeStack(gpa, 3);
    defer stack.deinit(gpa);
    var log: CommandLog = .{};
    var exec = Executor.init(.{ .ctx = undefined, .run = noopRun });
    const digest: u64 = 0x0123456789ABCDEF;

    var first_ids: [3]journal.RecordId = undefined;
    {
        var native = try journal.NativeStore.open(gpa, testing.io, tmp.dir, "doc.hjr", "/documents/a.pix");
        defer native.deinit();
        var persist: Persist = .{ .gpa = gpa };
        defer persist.deinit();
        persist.setStore(native.store());

        _ = try persist.save(&stack, &log, &exec, digest);
        // A second save of the same stack must not write the payloads again.
        const before = native.store().stats().live_count;
        _ = try persist.save(&stack, &log, &exec, digest);
        try testing.expectEqual(before, native.store().stats().live_count);
        for (persist.persisted.items, 0..) |entry, i| {
            if (i < first_ids.len) first_ids[i] = entry.id;
        }
    }

    // Reopen from disk: the collected records really are gone, not just marked in memory.
    var reopened = try journal.NativeStore.open(gpa, testing.io, tmp.dir, "doc.hjr", "/documents/a.pix");
    defer reopened.deinit();
    try testing.expectEqual(@as(usize, 4), reopened.store().stats().live_count);

    var restored: core.UndoStack = .{};
    defer restored.deinit(gpa);
    var log2: CommandLog = .{};
    var exec2 = Executor.init(.{ .ctx = undefined, .run = noopRun });
    var reader: Persist = .{ .gpa = gpa };
    defer reader.deinit();
    reader.setStore(reopened.store());
    const loaded = reader.load(&restored, &log2, &exec2, digest);
    try testing.expectEqual(LoadStatus.restored, loaded.status);
    try testing.expectEqual(@as(usize, 3), restored.undo.items.len);
    try testing.expectEqual(stack.next_handle, restored.next_handle);
    for (stack.undo.items, restored.undo.items) |a, b| {
        try testing.expectEqual(a.paint.diffs[0].idx, b.paint.diffs[0].idx);
        try testing.expectEqual(a.paint.diffs[0].after, b.paint.diffs[0].after);
    }
}
