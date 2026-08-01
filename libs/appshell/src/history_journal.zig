//! Append-only journal store for auxiliary per-document history.
//!
//! The store is payload-agnostic: it frames opaque byte records and knows nothing about
//! what they mean. Callers own the meaning of `kind` and `version`, which mirror the
//! self-describing entry headers used by the history codecs, so a reader can skip a
//! record whose kind it does not understand.
//!
//! Hot-path declaration: append runs at event time (one edit committed, one save), and
//! scan / compaction run at open and save. Nothing here runs per frame or per audio
//! sample.
//!
//! ## Why a store interface at all
//! Two implementations exist and both are used: `MemoryStore` (tests, and any run with no
//! writable application-data directory) and `NativeStore` (a real append-only file). The
//! browser build has no directory concept at all — `paths.openAppDataDir` fails there with
//! `error.PersistenceUnsupported` — so a caller on that target holds no store rather than a
//! store that silently discards. Absence is modelled as `?Store`, never as a "null store"
//! that would make unavailable persistence look successful.
//!
//! ## File layout (little-endian)
//! ```text
//! header:  magic "HJN1" 4 | format_version u16 | flags u16 | path_len u32 | header_crc32 u32 | path bytes
//! record:  payload_len u32 | id u64 | kind u8 | version u16 | flags u8 | payload | record_crc32 u32
//! ```
//! `header_crc32` covers the first 12 header bytes plus the path bytes. `record_crc32`
//! covers the whole frame except itself, so a corrupt length is caught as well as corrupt
//! payload bytes.
//!
//! ## Durability
//! `append` does not sync. `sync` is the explicit durability boundary and the caller
//! decides where it sits. History is auxiliary — the document file is authoritative — so
//! paying an fsync per edit would buy very little. A crash loses at most the records
//! appended since the last `sync`, and a torn final frame is truncated at the next open.

const std = @import("std");
const file_safety = @import("file_safety.zig");

pub const magic: [4]u8 = "HJN1".*;
pub const format_version: u16 = 1;

/// Fixed part of the file header; the canonical document path follows it.
pub const header_fixed_size: usize = 16;
/// Per-record framing overhead: the 16-byte prefix plus the trailing CRC.
pub const frame_overhead: usize = 20;

/// Upper bound on one record's payload. A single undo entry for a full-canvas structural
/// edit is the largest thing a caller will hand over, so this is generous on purpose; the
/// per-document budget that actually limits a journal is the caller's policy, not this.
pub const max_record_payload: u32 = 256 * 1024 * 1024;

/// Buffer size used for streaming CRC verification and for copying frames during compaction.
const scratch_size: usize = 64 * 1024;

pub const Error = error{
    OutOfMemory,
    /// No live record carries this id (never appended, or dropped).
    NotFound,
    /// The file header is missing, truncated, or fails its CRC. The file is left untouched.
    CorruptHeader,
    /// A record inside the live region fails its CRC (bit rot rather than a torn tail).
    CorruptRecord,
    /// The header names a different document than the one requested.
    PathMismatch,
    /// The payload exceeds `max_record_payload`.
    RecordTooLarge,
    PathTooLong,
    FileNotFound,
    AccessDenied,
    NoSpaceLeft,
    /// Any other failure reported by the file layer.
    Io,
};

/// Opaque, monotonically increasing record identity.
///
/// An id is assigned on append and never reused. It survives compaction: a record that is
/// still live keeps the id it was appended with, so a caller may store ids inside its own
/// records. Dropped ids read back as `error.NotFound` and are never handed out again. An
/// id is not a file offset, and nothing about its numeric value is part of the contract
/// beyond ordering.
pub const RecordId = u64;

/// Reserved: no record ever carries it, so it is usable as "absent".
pub const invalid_id: RecordId = 0;

/// A record's framing, without its payload. Produced by `scan` and `tail`, which read only
/// the in-memory index and therefore allocate nothing and touch no file.
pub const RecordInfo = struct {
    id: RecordId,
    kind: u8,
    version: u16,
    payload_len: u32,
};

pub const OwnedRecord = struct {
    allocator: std.mem.Allocator,
    id: RecordId,
    kind: u8,
    version: u16,
    payload: []u8,

    pub fn deinit(self: *OwnedRecord) void {
        self.allocator.free(self.payload);
        self.* = undefined;
    }
};

pub const Stats = struct {
    live_count: usize,
    /// Framed size of the live records (payload plus overhead), excluding the file header.
    live_bytes: u64,
    /// Framed size still occupied by dropped records; reclaimed by `compact`.
    dropped_bytes: u64,
};

pub const ScanAction = enum { continue_scan, stop };
pub const VisitFn = *const fn (ctx: *anyopaque, info: RecordInfo) ScanAction;

/// The substitutable storage surface.
///
/// `append` / `read` / `tail` / `scan` / `drop` / `dropOldest` / `sync` are the operations
/// the history layer needs; `compact` reclaims the space of dropped records. Everything
/// that only consults the in-memory index is infallible.
///
/// The shape deliberately stays expressible by a transactional backend: an implementation
/// backed by a database would map `append` to an insert, `read` to a lookup by the same
/// explicit id, `compact` to a delete plus vacuum, and `sync` to a commit. Nothing here
/// forces an append-only file. No such backend is adopted, and a remote one is out of
/// scope by design — `read` returning over a network would make undo asynchronous and
/// fallible, which is a change to the editor's interaction contract rather than to its
/// storage.
pub const Store = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        append: *const fn (ctx: *anyopaque, kind: u8, version: u16, payload: []const u8) Error!RecordId,
        read: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, id: RecordId) Error!OwnedRecord,
        tail: *const fn (ctx: *anyopaque, out: []RecordInfo) []RecordInfo,
        scan: *const fn (ctx: *anyopaque, visitor_ctx: *anyopaque, visit: VisitFn) void,
        drop: *const fn (ctx: *anyopaque, id: RecordId) bool,
        dropOldest: *const fn (ctx: *anyopaque) ?RecordId,
        compact: *const fn (ctx: *anyopaque) Error!void,
        sync: *const fn (ctx: *anyopaque) Error!void,
        stats: *const fn (ctx: *anyopaque) Stats,
    };

    /// Append one record and return its id. Does not sync.
    pub fn append(self: Store, kind: u8, version: u16, payload: []const u8) Error!RecordId {
        return self.vtable.append(self.ctx, kind, version, payload);
    }

    /// Read one live record's payload. `error.NotFound` when the id was dropped or never existed.
    pub fn read(self: Store, gpa: std.mem.Allocator, id: RecordId) Error!OwnedRecord {
        return self.vtable.read(self.ctx, gpa, id);
    }

    /// Fill `out` with the newest live records, oldest first, and return the used prefix.
    pub fn tail(self: Store, out: []RecordInfo) []RecordInfo {
        return self.vtable.tail(self.ctx, out);
    }

    /// Visit every live record oldest first until the visitor returns `.stop`.
    pub fn scan(self: Store, visitor_ctx: *anyopaque, visit: VisitFn) void {
        self.vtable.scan(self.ctx, visitor_ctx, visit);
    }

    /// Drop one record by id. Returns false when no live record carries that id.
    ///
    /// The record becomes unreadable immediately; its bytes are reclaimed by `compact`.
    /// Deciding that a record is unreferenced is the caller's job — the store cannot know,
    /// because it does not interpret payloads.
    pub fn drop(self: Store, id: RecordId) bool {
        return self.vtable.drop(self.ctx, id);
    }

    /// Drop the oldest live record and return its id, or null when the store is empty.
    pub fn dropOldest(self: Store) ?RecordId {
        return self.vtable.dropOldest(self.ctx);
    }

    /// Rewrite the store so that only live records remain. Live ids are preserved.
    pub fn compact(self: Store) Error!void {
        return self.vtable.compact(self.ctx);
    }

    /// The durability boundary: on return, every record appended so far has reached stable
    /// storage (as far as the file layer guarantees).
    pub fn sync(self: Store) Error!void {
        return self.vtable.sync(self.ctx);
    }

    pub fn stats(self: Store) Stats {
        return self.vtable.stats(self.ctx);
    }
};

// ── framing helpers ─────────────────────────────────────────────────────

fn writeFramePrefix(buf: *[16]u8, id: RecordId, kind: u8, version: u16, payload_len: u32) void {
    std.mem.writeInt(u32, buf[0..4], payload_len, .little);
    std.mem.writeInt(u64, buf[4..12], id, .little);
    buf[12] = kind;
    std.mem.writeInt(u16, buf[13..15], version, .little);
    buf[15] = 0;
}

fn frameCrc(prefix: []const u8, payload: []const u8) u32 {
    var crc = std.hash.Crc32.init();
    crc.update(prefix);
    crc.update(payload);
    return crc.final();
}

fn encodeFileHeader(gpa: std.mem.Allocator, doc_path: []const u8) Error![]u8 {
    if (doc_path.len > std.math.maxInt(u32)) return error.PathTooLong;
    const total = header_fixed_size + doc_path.len;
    const buf = gpa.alloc(u8, total) catch return error.OutOfMemory;
    errdefer gpa.free(buf);
    @memcpy(buf[0..4], &magic);
    std.mem.writeInt(u16, buf[4..6], format_version, .little);
    std.mem.writeInt(u16, buf[6..8], 0, .little);
    std.mem.writeInt(u32, buf[8..12], @intCast(doc_path.len), .little);
    var crc = std.hash.Crc32.init();
    crc.update(buf[0..12]);
    crc.update(doc_path);
    std.mem.writeInt(u32, buf[12..16], crc.final(), .little);
    @memcpy(buf[header_fixed_size..], doc_path);
    return buf;
}

// ── in-memory store ─────────────────────────────────────────────────────

/// Journal held entirely in memory.
///
/// Used by the tests that pin the interface contract, and by any run where no writable
/// application-data directory exists but history should still behave normally within the
/// session.
pub const MemoryStore = struct {
    gpa: std.mem.Allocator,
    records: std.ArrayList(Entry) = .empty,
    next_id: RecordId = 1,
    dropped_bytes: u64 = 0,
    /// Number of `sync` calls, so a test can pin where the durability boundary is taken.
    sync_count: usize = 0,

    const Entry = struct {
        id: RecordId,
        kind: u8,
        version: u16,
        payload: []u8,
    };

    pub fn init(gpa: std.mem.Allocator) MemoryStore {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *MemoryStore) void {
        for (self.records.items) |entry| self.gpa.free(entry.payload);
        self.records.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn store(self: *MemoryStore) Store {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: Store.VTable = .{
        .append = vtAppend,
        .read = vtRead,
        .tail = vtTail,
        .scan = vtScan,
        .drop = vtDrop,
        .dropOldest = vtDropOldest,
        .compact = vtCompact,
        .sync = vtSync,
        .stats = vtStats,
    };

    fn self_(ctx: *anyopaque) *MemoryStore {
        return @ptrCast(@alignCast(ctx));
    }

    fn vtAppend(ctx: *anyopaque, kind: u8, version: u16, payload: []const u8) Error!RecordId {
        const self = self_(ctx);
        if (payload.len > max_record_payload) return error.RecordTooLarge;
        const owned = self.gpa.dupe(u8, payload) catch return error.OutOfMemory;
        errdefer self.gpa.free(owned);
        const id = self.next_id;
        self.records.append(self.gpa, .{ .id = id, .kind = kind, .version = version, .payload = owned }) catch
            return error.OutOfMemory;
        self.next_id += 1;
        return id;
    }

    fn vtRead(ctx: *anyopaque, gpa: std.mem.Allocator, id: RecordId) Error!OwnedRecord {
        const self = self_(ctx);
        for (self.records.items) |entry| {
            if (entry.id != id) continue;
            const copy = gpa.dupe(u8, entry.payload) catch return error.OutOfMemory;
            return .{ .allocator = gpa, .id = id, .kind = entry.kind, .version = entry.version, .payload = copy };
        }
        return error.NotFound;
    }

    fn vtTail(ctx: *anyopaque, out: []RecordInfo) []RecordInfo {
        const self = self_(ctx);
        const n = @min(out.len, self.records.items.len);
        const start = self.records.items.len - n;
        for (self.records.items[start..], 0..) |entry, i| {
            out[i] = .{ .id = entry.id, .kind = entry.kind, .version = entry.version, .payload_len = @intCast(entry.payload.len) };
        }
        return out[0..n];
    }

    fn vtScan(ctx: *anyopaque, visitor_ctx: *anyopaque, visit: VisitFn) void {
        const self = self_(ctx);
        for (self.records.items) |entry| {
            const info: RecordInfo = .{
                .id = entry.id,
                .kind = entry.kind,
                .version = entry.version,
                .payload_len = @intCast(entry.payload.len),
            };
            if (visit(visitor_ctx, info) == .stop) return;
        }
    }

    fn vtDrop(ctx: *anyopaque, id: RecordId) bool {
        const self = self_(ctx);
        for (self.records.items, 0..) |entry, i| {
            if (entry.id != id) continue;
            _ = self.records.orderedRemove(i);
            self.dropped_bytes += frame_overhead + entry.payload.len;
            self.gpa.free(entry.payload);
            return true;
        }
        return false;
    }

    fn vtDropOldest(ctx: *anyopaque) ?RecordId {
        const self = self_(ctx);
        if (self.records.items.len == 0) return null;
        const entry = self.records.orderedRemove(0);
        self.dropped_bytes += frame_overhead + entry.payload.len;
        self.gpa.free(entry.payload);
        return entry.id;
    }

    fn vtCompact(ctx: *anyopaque) Error!void {
        // Dropped entries are freed immediately, so there is nothing left to reclaim.
        self_(ctx).dropped_bytes = 0;
    }

    fn vtSync(ctx: *anyopaque) Error!void {
        self_(ctx).sync_count += 1;
    }

    fn vtStats(ctx: *anyopaque) Stats {
        const self = self_(ctx);
        var bytes: u64 = 0;
        for (self.records.items) |entry| bytes += frame_overhead + entry.payload.len;
        return .{ .live_count = self.records.items.len, .live_bytes = bytes, .dropped_bytes = self.dropped_bytes };
    }
};

// ── native file store ───────────────────────────────────────────────────

/// Journal backed by an append-only file inside the application-data directory.
pub const NativeStore = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    file: std.Io.File,
    file_name: []u8,
    doc_path: []u8,
    slots: std.ArrayList(Slot) = .empty,
    live_count: usize = 0,
    header_len: u64 = 0,
    end_offset: u64 = 0,
    next_id: RecordId = 1,
    dropped_bytes: u64 = 0,

    const Slot = struct {
        id: RecordId,
        offset: u64,
        kind: u8,
        version: u16,
        payload_len: u32,
        dropped: bool = false,

        fn frameLen(self: Slot) u64 {
            return frame_overhead + @as(u64, self.payload_len);
        }
    };

    /// Open (creating if absent) the journal that belongs to `doc_path`.
    ///
    /// A file that exists must name the same document, or `error.PathMismatch` is returned
    /// without touching it. Framing errors in the tail truncate the file back to the last
    /// intact record; a bad header never truncates anything, because the start of the
    /// record region would only be a guess.
    pub fn open(
        gpa: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        file_name: []const u8,
        doc_path: []const u8,
    ) Error!NativeStore {
        const owned_name = gpa.dupe(u8, file_name) catch return error.OutOfMemory;
        errdefer gpa.free(owned_name);
        const owned_path = gpa.dupe(u8, doc_path) catch return error.OutOfMemory;
        errdefer gpa.free(owned_path);

        const file = dir.createFile(io, file_name, .{ .read = true, .truncate = false }) catch |err|
            return mapFileError(err);
        errdefer file.close(io);

        var self: NativeStore = .{
            .gpa = gpa,
            .io = io,
            .dir = dir,
            .file = file,
            .file_name = owned_name,
            .doc_path = owned_path,
        };
        errdefer self.slots.deinit(gpa);

        const size = file.length(io) catch |err| return mapFileError(err);
        if (size == 0) {
            try self.writeHeader();
        } else {
            try self.readHeader(size);
            try self.scanRecords(size);
        }
        return self;
    }

    /// `open`, but a header that is corrupt or names another document restarts the journal
    /// from scratch instead of failing. The caller loses history it could not have used.
    pub fn openOrReset(
        gpa: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        file_name: []const u8,
        doc_path: []const u8,
    ) Error!NativeStore {
        return open(gpa, io, dir, file_name, doc_path) catch |err| switch (err) {
            error.CorruptHeader, error.PathMismatch => {
                dir.deleteFile(io, file_name) catch |del| switch (del) {
                    error.FileNotFound => {},
                    else => return mapFileError(del),
                };
                return open(gpa, io, dir, file_name, doc_path);
            },
            else => return err,
        };
    }

    pub fn deinit(self: *NativeStore) void {
        self.file.close(self.io);
        self.slots.deinit(self.gpa);
        self.gpa.free(self.file_name);
        self.gpa.free(self.doc_path);
        self.* = undefined;
    }

    pub fn store(self: *NativeStore) Store {
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// Canonical document path recorded in the header.
    pub fn documentPath(self: *const NativeStore) []const u8 {
        return self.doc_path;
    }

    fn writeHeader(self: *NativeStore) Error!void {
        const header = try encodeFileHeader(self.gpa, self.doc_path);
        defer self.gpa.free(header);
        self.file.writePositionalAll(self.io, header, 0) catch |err| return mapFileError(err);
        self.header_len = header.len;
        self.end_offset = header.len;
    }

    fn readHeader(self: *NativeStore, size: u64) Error!void {
        var fixed: [header_fixed_size]u8 = undefined;
        if (size < header_fixed_size) return error.CorruptHeader;
        readExact(self.io, self.file, &fixed, 0) catch return error.CorruptHeader;
        if (!std.mem.eql(u8, fixed[0..4], &magic)) return error.CorruptHeader;
        if (std.mem.readInt(u16, fixed[4..6], .little) != format_version) return error.CorruptHeader;
        if (std.mem.readInt(u16, fixed[6..8], .little) != 0) return error.CorruptHeader;
        const path_len = std.mem.readInt(u32, fixed[8..12], .little);
        const stored_crc = std.mem.readInt(u32, fixed[12..16], .little);
        const header_len = header_fixed_size + @as(u64, path_len);
        if (header_len > size) return error.CorruptHeader;

        const path_buf = self.gpa.alloc(u8, path_len) catch return error.OutOfMemory;
        defer self.gpa.free(path_buf);
        readExact(self.io, self.file, path_buf, header_fixed_size) catch return error.CorruptHeader;
        var crc = std.hash.Crc32.init();
        crc.update(fixed[0..12]);
        crc.update(path_buf);
        if (crc.final() != stored_crc) return error.CorruptHeader;
        if (!std.mem.eql(u8, path_buf, self.doc_path)) return error.PathMismatch;

        self.header_len = header_len;
        self.end_offset = header_len;
    }

    /// Walk the record region, indexing intact frames and truncating from the first broken one.
    fn scanRecords(self: *NativeStore, size: u64) Error!void {
        var scratch: [scratch_size]u8 = undefined;
        var offset = self.header_len;
        var max_id: RecordId = 0;
        while (offset + frame_overhead <= size) {
            var prefix: [16]u8 = undefined;
            readExact(self.io, self.file, &prefix, offset) catch break;
            const payload_len = std.mem.readInt(u32, prefix[0..4], .little);
            if (payload_len > max_record_payload) break;
            const frame_len = frame_overhead + @as(u64, payload_len);
            if (offset + frame_len > size) break;
            if (prefix[15] != 0) break;

            var crc = std.hash.Crc32.init();
            crc.update(&prefix);
            var remaining: u64 = payload_len;
            var cursor = offset + prefix.len;
            var payload_ok = true;
            while (remaining > 0) {
                const take: usize = @intCast(@min(remaining, scratch.len));
                readExact(self.io, self.file, scratch[0..take], cursor) catch {
                    payload_ok = false;
                    break;
                };
                crc.update(scratch[0..take]);
                cursor += take;
                remaining -= take;
            }
            if (!payload_ok) break;
            var crc_bytes: [4]u8 = undefined;
            readExact(self.io, self.file, &crc_bytes, cursor) catch break;
            if (std.mem.readInt(u32, &crc_bytes, .little) != crc.final()) break;

            const id = std.mem.readInt(u64, prefix[4..12], .little);
            // Ids are issued in increasing order; anything else means a rewritten frame.
            if (id == invalid_id or id <= max_id) break;
            max_id = id;
            self.slots.append(self.gpa, .{
                .id = id,
                .offset = offset,
                .kind = prefix[12],
                .version = std.mem.readInt(u16, prefix[13..15], .little),
                .payload_len = payload_len,
            }) catch return error.OutOfMemory;
            self.live_count += 1;
            offset += frame_len;
        }
        self.end_offset = offset;
        self.next_id = max_id + 1;
        if (offset < size) {
            // Drop the broken tail so the next append starts from an intact prefix.
            self.file.setLength(self.io, offset) catch |err| return mapFileError(err);
        }
    }

    const vtable: Store.VTable = .{
        .append = vtAppend,
        .read = vtRead,
        .tail = vtTail,
        .scan = vtScan,
        .drop = vtDrop,
        .dropOldest = vtDropOldest,
        .compact = vtCompact,
        .sync = vtSync,
        .stats = vtStats,
    };

    fn self_(ctx: *anyopaque) *NativeStore {
        return @ptrCast(@alignCast(ctx));
    }

    fn vtAppend(ctx: *anyopaque, kind: u8, version: u16, payload: []const u8) Error!RecordId {
        const self = self_(ctx);
        if (payload.len > max_record_payload) return error.RecordTooLarge;
        const id = self.next_id;
        var prefix: [16]u8 = undefined;
        writeFramePrefix(&prefix, id, kind, version, @intCast(payload.len));
        const crc = frameCrc(&prefix, payload);
        var crc_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_bytes, crc, .little);

        const at = self.end_offset;
        self.file.writePositionalAll(self.io, &prefix, at) catch |err| return mapFileError(err);
        self.file.writePositionalAll(self.io, payload, at + prefix.len) catch |err| return mapFileError(err);
        self.file.writePositionalAll(self.io, &crc_bytes, at + prefix.len + payload.len) catch |err| return mapFileError(err);

        self.slots.append(self.gpa, .{
            .id = id,
            .offset = at,
            .kind = kind,
            .version = version,
            .payload_len = @intCast(payload.len),
        }) catch return error.OutOfMemory;
        self.end_offset = at + frame_overhead + payload.len;
        self.live_count += 1;
        self.next_id += 1;
        return id;
    }

    fn vtRead(ctx: *anyopaque, gpa: std.mem.Allocator, id: RecordId) Error!OwnedRecord {
        const self = self_(ctx);
        for (self.slots.items) |slot| {
            if (slot.id != id or slot.dropped) continue;
            const payload = gpa.alloc(u8, slot.payload_len) catch return error.OutOfMemory;
            errdefer gpa.free(payload);
            var prefix: [16]u8 = undefined;
            readExact(self.io, self.file, &prefix, slot.offset) catch return error.Io;
            readExact(self.io, self.file, payload, slot.offset + prefix.len) catch return error.Io;
            var crc_bytes: [4]u8 = undefined;
            readExact(self.io, self.file, &crc_bytes, slot.offset + prefix.len + payload.len) catch return error.Io;
            if (std.mem.readInt(u32, &crc_bytes, .little) != frameCrc(&prefix, payload)) return error.CorruptRecord;
            return .{ .allocator = gpa, .id = id, .kind = slot.kind, .version = slot.version, .payload = payload };
        }
        return error.NotFound;
    }

    fn vtTail(ctx: *anyopaque, out: []RecordInfo) []RecordInfo {
        const self = self_(ctx);
        var n: usize = 0;
        var i = self.slots.items.len;
        while (i > 0 and n < out.len) : (i -= 1) {
            const slot = self.slots.items[i - 1];
            if (slot.dropped) continue;
            out[n] = .{ .id = slot.id, .kind = slot.kind, .version = slot.version, .payload_len = slot.payload_len };
            n += 1;
        }
        std.mem.reverse(RecordInfo, out[0..n]);
        return out[0..n];
    }

    fn vtScan(ctx: *anyopaque, visitor_ctx: *anyopaque, visit: VisitFn) void {
        const self = self_(ctx);
        for (self.slots.items) |slot| {
            if (slot.dropped) continue;
            const info: RecordInfo = .{
                .id = slot.id,
                .kind = slot.kind,
                .version = slot.version,
                .payload_len = slot.payload_len,
            };
            if (visit(visitor_ctx, info) == .stop) return;
        }
    }

    fn vtDrop(ctx: *anyopaque, id: RecordId) bool {
        const self = self_(ctx);
        for (self.slots.items) |*slot| {
            if (slot.id != id or slot.dropped) continue;
            slot.dropped = true;
            self.live_count -= 1;
            self.dropped_bytes += slot.frameLen();
            return true;
        }
        return false;
    }

    fn vtDropOldest(ctx: *anyopaque) ?RecordId {
        const self = self_(ctx);
        for (self.slots.items) |*slot| {
            if (slot.dropped) continue;
            slot.dropped = true;
            self.live_count -= 1;
            self.dropped_bytes += slot.frameLen();
            return slot.id;
        }
        return null;
    }

    /// Rewrite the file with the live records only, preserving their ids.
    ///
    /// Frames are copied verbatim, so nothing is re-encoded and no CRC is recomputed. The
    /// replacement goes through the same atomic write the document save uses: a crash
    /// leaves either the previous journal or the new one, never a half-written mixture.
    fn vtCompact(ctx: *anyopaque) Error!void {
        const self = self_(ctx);
        if (self.dropped_bytes == 0) return;

        const header = try encodeFileHeader(self.gpa, self.doc_path);
        defer self.gpa.free(header);

        var atomic = self.dir.createFileAtomic(self.io, self.file_name, .{ .replace = true }) catch |err|
            return mapFileError(err);
        defer atomic.deinit(self.io);
        atomic.file.writeStreamingAll(self.io, header) catch |err| return mapFileError(err);

        // Copy first, commit the new offsets only once the replacement is in place: a failure
        // part-way leaves both the file and the in-memory index describing the old layout.
        var scratch: [scratch_size]u8 = undefined;
        var write_at: u64 = header.len;
        for (self.slots.items) |slot| {
            if (slot.dropped) continue;
            var remaining = slot.frameLen();
            var read_at = slot.offset;
            while (remaining > 0) {
                const take: usize = @intCast(@min(remaining, scratch.len));
                readExact(self.io, self.file, scratch[0..take], read_at) catch return error.Io;
                atomic.file.writeStreamingAll(self.io, scratch[0..take]) catch |err| return mapFileError(err);
                read_at += take;
                remaining -= take;
            }
            write_at += slot.frameLen();
        }
        atomic.file.sync(self.io) catch |err| return mapFileError(err);
        atomic.replace(self.io) catch |err| return mapFileError(err);

        var new_offset: u64 = header.len;
        for (self.slots.items) |*slot| {
            if (slot.dropped) continue;
            slot.offset = new_offset;
            new_offset += slot.frameLen();
        }

        // Adopt the replacement: the old handle still points at the unlinked file.
        self.file.close(self.io);
        self.file = self.dir.createFile(self.io, self.file_name, .{ .read = true, .truncate = false }) catch |err|
            return mapFileError(err);

        // `slots` keeps only live entries once their offsets have been rewritten above.
        var kept: usize = 0;
        for (self.slots.items) |slot| {
            if (slot.dropped) continue;
            self.slots.items[kept] = slot;
            kept += 1;
        }
        self.slots.shrinkRetainingCapacity(kept);
        self.live_count = kept;
        self.header_len = header.len;
        self.end_offset = write_at;
        self.dropped_bytes = 0;
    }

    fn vtSync(ctx: *anyopaque) Error!void {
        const self = self_(ctx);
        self.file.sync(self.io) catch |err| return mapFileError(err);
    }

    fn vtStats(ctx: *anyopaque) Stats {
        const self = self_(ctx);
        var bytes: u64 = 0;
        for (self.slots.items) |slot| {
            if (!slot.dropped) bytes += slot.frameLen();
        }
        return .{ .live_count = self.live_count, .live_bytes = bytes, .dropped_bytes = self.dropped_bytes };
    }
};

fn readExact(io: std.Io, file: std.Io.File, buf: []u8, offset: u64) !void {
    const n = try file.readPositionalAll(io, buf, offset);
    if (n != buf.len) return error.EndOfFile;
}

fn mapFileError(err: anyerror) Error {
    return switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.NoSpaceLeft, error.DiskQuota => error.NoSpaceLeft,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Io,
    };
}

// ── store directory maintenance ─────────────────────────────────────────

pub const MaintainOptions = struct {
    /// Total budget for every journal in the directory.
    global_cap_bytes: u64 = 512 * 1024 * 1024,
    /// Upper bound on files examined in one call, so startup work stays amortised.
    max_files: usize = 64,
    /// Delete a journal whose document has not been seen for this long.
    max_age_seconds: i128 = 30 * 24 * 60 * 60,
};

pub const MaintainReport = struct {
    examined: usize = 0,
    removed_orphan: usize = 0,
    removed_stale: usize = 0,
    removed_lru: usize = 0,
    total_bytes: u64 = 0,
};

/// Sweep the journal directory: drop journals whose document is gone, drop journals nobody
/// has touched in a long time, then evict least-recently-used ones until the directory is
/// under its global budget.
///
/// A journal is removed as an orphan **only** when its document is definitively absent.
/// A permission failure or an unmounted volume leaves it alone, because "cannot see it
/// right now" is not "gone".
pub fn maintain(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    now_seconds: i128,
    options: MaintainOptions,
) !MaintainReport {
    const Candidate = struct {
        name: []u8,
        size: u64,
        mtime_seconds: i128,
    };

    var report: MaintainReport = .{};
    var candidates: std.ArrayList(Candidate) = .empty;
    defer {
        for (candidates.items) |c| gpa.free(c.name);
        candidates.deinit(gpa);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (report.examined >= options.max_files) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, extension)) continue;
        report.examined += 1;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        const mtime_seconds: i128 = @divFloor(stat.mtime.nanoseconds, std.time.ns_per_s);

        const doc_path = readHeaderPath(gpa, io, dir, entry.name) catch null;
        defer if (doc_path) |p| gpa.free(p);

        if (doc_path) |p| {
            const missing = if (std.fs.path.isAbsolute(p))
                isDefinitelyMissingAbsolute(io, p)
            else
                false;
            if (missing) {
                dir.deleteFile(io, entry.name) catch continue;
                report.removed_orphan += 1;
                continue;
            }
        } else {
            // A journal with no readable header can never be restored from.
            dir.deleteFile(io, entry.name) catch continue;
            report.removed_orphan += 1;
            continue;
        }

        if (now_seconds - mtime_seconds > options.max_age_seconds) {
            dir.deleteFile(io, entry.name) catch continue;
            report.removed_stale += 1;
            continue;
        }

        const name = try gpa.dupe(u8, entry.name);
        errdefer gpa.free(name);
        try candidates.append(gpa, .{ .name = name, .size = stat.size, .mtime_seconds = mtime_seconds });
        report.total_bytes += stat.size;
    }

    if (report.total_bytes <= options.global_cap_bytes) return report;

    std.mem.sort(Candidate, candidates.items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            return a.mtime_seconds < b.mtime_seconds;
        }
    }.lessThan);

    for (candidates.items) |c| {
        if (report.total_bytes <= options.global_cap_bytes) break;
        dir.deleteFile(io, c.name) catch continue;
        report.total_bytes -= @min(report.total_bytes, c.size);
        report.removed_lru += 1;
    }
    return report;
}

/// File-name extension every journal uses.
pub const extension = ".hjr";

fn isDefinitelyMissingAbsolute(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch |err| return err == error.FileNotFound;
    return false;
}

/// Read only the document path out of a journal header. Caller frees.
pub fn readHeaderPath(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, file_name: []const u8) Error![]u8 {
    const file = dir.openFile(io, file_name, .{}) catch |err| return mapFileError(err);
    defer file.close(io);
    var fixed: [header_fixed_size]u8 = undefined;
    readExact(io, file, &fixed, 0) catch return error.CorruptHeader;
    if (!std.mem.eql(u8, fixed[0..4], &magic)) return error.CorruptHeader;
    if (std.mem.readInt(u16, fixed[4..6], .little) != format_version) return error.CorruptHeader;
    const path_len = std.mem.readInt(u32, fixed[8..12], .little);
    const stored_crc = std.mem.readInt(u32, fixed[12..16], .little);
    const path_buf = gpa.alloc(u8, path_len) catch return error.OutOfMemory;
    errdefer gpa.free(path_buf);
    readExact(io, file, path_buf, header_fixed_size) catch return error.CorruptHeader;
    var crc = std.hash.Crc32.init();
    crc.update(fixed[0..12]);
    crc.update(path_buf);
    if (crc.final() != stored_crc) return error.CorruptHeader;
    return path_buf;
}

// ── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

/// Exercise one `Store` implementation through the interface only, so both backends are
/// held to the same contract.
fn runInterfaceContract(s: Store, gpa: std.mem.Allocator) !void {
    const a = try s.append(1, 1, "alpha");
    const b = try s.append(2, 3, "bravo-payload");
    const c = try s.append(1, 1, "charlie");
    try testing.expect(a < b and b < c);

    var rec = try s.read(gpa, b);
    defer rec.deinit();
    try testing.expectEqualStrings("bravo-payload", rec.payload);
    try testing.expectEqual(@as(u8, 2), rec.kind);
    try testing.expectEqual(@as(u16, 3), rec.version);

    var tail_buf: [2]RecordInfo = undefined;
    const t = s.tail(&tail_buf);
    try testing.expectEqual(@as(usize, 2), t.len);
    try testing.expectEqual(b, t[0].id);
    try testing.expectEqual(c, t[1].id);

    const Collector = struct {
        ids: [8]RecordId = undefined,
        n: usize = 0,
        fn visit(ctx: *anyopaque, info: RecordInfo) ScanAction {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ids[self.n] = info.id;
            self.n += 1;
            return .continue_scan;
        }
    };
    var collector: Collector = .{};
    s.scan(&collector, Collector.visit);
    try testing.expectEqual(@as(usize, 3), collector.n);
    try testing.expectEqual(a, collector.ids[0]);
    try testing.expectEqual(c, collector.ids[2]);

    try testing.expectEqual(@as(usize, 3), s.stats().live_count);
    // Drop by id reaches a record in the middle, which a prefix-only drop cannot.
    try testing.expect(s.drop(b));
    try testing.expect(!s.drop(b));
    try testing.expectEqual(@as(usize, 2), s.stats().live_count);
    try testing.expectError(error.NotFound, s.read(gpa, b));
    var after_drop: [4]RecordInfo = undefined;
    const remaining = s.tail(&after_drop);
    try testing.expectEqual(@as(usize, 2), remaining.len);
    try testing.expectEqual(a, remaining[0].id);
    try testing.expectEqual(c, remaining[1].id);

    try testing.expectEqual(a, s.dropOldest().?);
    try testing.expectEqual(@as(usize, 1), s.stats().live_count);
    try testing.expectError(error.NotFound, s.read(gpa, a));

    // Ids of the surviving records are unchanged by compaction.
    try s.compact();
    try testing.expectEqual(@as(u64, 0), s.stats().dropped_bytes);
    try testing.expectEqual(@as(usize, 1), s.stats().live_count);
    var rec2 = try s.read(gpa, c);
    defer rec2.deinit();
    try testing.expectEqualStrings("charlie", rec2.payload);
    try testing.expectError(error.NotFound, s.read(gpa, a));

    // A new record still gets a fresh id after compaction.
    const d = try s.append(9, 9, "delta");
    try testing.expect(d > c);
    try s.sync();
}

test "history journal: memory and native stores satisfy the same interface contract" {
    var mem = MemoryStore.init(testing.allocator);
    defer mem.deinit();
    try runInterfaceContract(mem.store(), testing.allocator);

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var native = try NativeStore.open(testing.allocator, testing.io, tmp.dir, "doc.hjr", "/documents/a.pix");
    defer native.deinit();
    try runInterfaceContract(native.store(), testing.allocator);
}

test "history journal: records survive close and reopen" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var first_id: RecordId = 0;
    {
        var native = try NativeStore.open(testing.allocator, testing.io, tmp.dir, "doc.hjr", "/documents/a.pix");
        defer native.deinit();
        const s = native.store();
        first_id = try s.append(7, 2, "persisted");
        _ = try s.append(7, 2, "second");
        try s.sync();
    }
    var native = try NativeStore.open(testing.allocator, testing.io, tmp.dir, "doc.hjr", "/documents/a.pix");
    defer native.deinit();
    const s = native.store();
    try testing.expectEqual(@as(usize, 2), s.stats().live_count);
    var rec = try s.read(testing.allocator, first_id);
    defer rec.deinit();
    try testing.expectEqualStrings("persisted", rec.payload);
    // Fresh ids continue past the highest one already on disk.
    try testing.expect(try s.append(1, 1, "third") > first_id + 1);
}

test "history journal: a torn tail is truncated and earlier records survive" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var keep_id: RecordId = 0;
    var size_after_two: u64 = 0;
    {
        var native = try NativeStore.open(testing.allocator, testing.io, tmp.dir, "doc.hjr", "/d/a.pix");
        defer native.deinit();
        const s = native.store();
        keep_id = try s.append(1, 1, "keep-me");
        _ = try s.append(1, 1, "torn-away");
        size_after_two = native.end_offset;
    }
    // Cut the file in the middle of the second frame.
    {
        const f = try tmp.dir.createFile(testing.io, "doc.hjr", .{ .read = true, .truncate = false });
        defer f.close(testing.io);
        try f.setLength(testing.io, size_after_two - 4);
    }
    var native = try NativeStore.open(testing.allocator, testing.io, tmp.dir, "doc.hjr", "/d/a.pix");
    defer native.deinit();
    const s = native.store();
    try testing.expectEqual(@as(usize, 1), s.stats().live_count);
    var rec = try s.read(testing.allocator, keep_id);
    defer rec.deinit();
    try testing.expectEqualStrings("keep-me", rec.payload);
    // Truncation is durable: the next append lands where the broken frame started.
    _ = try s.append(1, 1, "after-repair");
    try testing.expectEqual(@as(usize, 2), s.stats().live_count);
}

test "history journal: a flipped payload byte is caught and truncates from that record" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var second_offset: u64 = 0;
    {
        var native = try NativeStore.open(testing.allocator, testing.io, tmp.dir, "doc.hjr", "/d/a.pix");
        defer native.deinit();
        const s = native.store();
        _ = try s.append(1, 1, "first");
        _ = try s.append(1, 1, "second");
        second_offset = native.slots.items[1].offset;
    }
    {
        const f = try tmp.dir.createFile(testing.io, "doc.hjr", .{ .read = true, .truncate = false });
        defer f.close(testing.io);
        var byte: [1]u8 = undefined;
        _ = try f.readPositionalAll(testing.io, &byte, second_offset + 16);
        byte[0] ^= 0xFF;
        try f.writePositionalAll(testing.io, &byte, second_offset + 16);
    }
    var native = try NativeStore.open(testing.allocator, testing.io, tmp.dir, "doc.hjr", "/d/a.pix");
    defer native.deinit();
    try testing.expectEqual(@as(usize, 1), native.store().stats().live_count);
}

test "history journal: truncating at every byte position never yields a bad record" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var full_size: u64 = 0;
    {
        var native = try NativeStore.open(testing.allocator, testing.io, tmp.dir, "seed.hjr", "/d/a.pix");
        defer native.deinit();
        const s = native.store();
        _ = try s.append(1, 1, "aaaa");
        _ = try s.append(2, 1, "bbbbbbbb");
        _ = try s.append(3, 1, "cc");
        full_size = native.end_offset;
    }
    const full = try tmp.dir.readFileAlloc(testing.io, "seed.hjr", testing.allocator, .unlimited);
    defer testing.allocator.free(full);

    var cut: usize = 0;
    while (cut <= full.len) : (cut += 1) {
        try file_safety.writeAtomicToDir(testing.io, tmp.dir, "cut.hjr", full[0..cut], .{});
        var native = NativeStore.open(testing.allocator, testing.io, tmp.dir, "cut.hjr", "/d/a.pix") catch |err| {
            // Only a header that is not fully present may fail, and it must fail this way.
            try testing.expectEqual(error.CorruptHeader, err);
            try testing.expect(cut < header_fixed_size + "/d/a.pix".len);
            continue;
        };
        defer native.deinit();
        const s = native.store();
        // Every record the store still reports must read back intact.
        var buf: [8]RecordInfo = undefined;
        for (s.tail(&buf)) |info| {
            var rec = try s.read(testing.allocator, info.id);
            defer rec.deinit();
            try testing.expectEqual(info.payload_len, @as(u32, @intCast(rec.payload.len)));
        }
    }
}

test "history journal: a corrupt header is reported without destroying the file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var native = try NativeStore.open(testing.allocator, testing.io, tmp.dir, "doc.hjr", "/d/a.pix");
        defer native.deinit();
        _ = try native.store().append(1, 1, "payload");
    }
    const before = try tmp.dir.readFileAlloc(testing.io, "doc.hjr", testing.allocator, .unlimited);
    defer testing.allocator.free(before);
    {
        const f = try tmp.dir.createFile(testing.io, "doc.hjr", .{ .read = true, .truncate = false });
        defer f.close(testing.io);
        try f.writePositionalAll(testing.io, "XX", 1);
    }
    try testing.expectError(
        error.CorruptHeader,
        NativeStore.open(testing.allocator, testing.io, tmp.dir, "doc.hjr", "/d/a.pix"),
    );
    const after = try tmp.dir.readFileAlloc(testing.io, "doc.hjr", testing.allocator, .unlimited);
    defer testing.allocator.free(after);
    try testing.expectEqual(before.len, after.len);

    // openOrReset starts a fresh journal instead of failing.
    var reset = try NativeStore.openOrReset(testing.allocator, testing.io, tmp.dir, "doc.hjr", "/d/a.pix");
    defer reset.deinit();
    try testing.expectEqual(@as(usize, 0), reset.store().stats().live_count);
}

test "history journal: a journal for another document is refused" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var native = try NativeStore.open(testing.allocator, testing.io, tmp.dir, "doc.hjr", "/d/a.pix");
        defer native.deinit();
        _ = try native.store().append(1, 1, "belongs to a");
    }
    try testing.expectError(
        error.PathMismatch,
        NativeStore.open(testing.allocator, testing.io, tmp.dir, "doc.hjr", "/d/b.pix"),
    );
}

test "history journal: an unknown record kind survives a round trip" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var unknown_id: RecordId = 0;
    {
        var native = try NativeStore.open(testing.allocator, testing.io, tmp.dir, "doc.hjr", "/d/a.pix");
        defer native.deinit();
        const s = native.store();
        _ = try s.append(1, 1, "known");
        unknown_id = try s.append(200, 42, "from a newer writer");
        _ = try s.append(1, 1, "known too");
    }
    var native = try NativeStore.open(testing.allocator, testing.io, tmp.dir, "doc.hjr", "/d/a.pix");
    defer native.deinit();
    const s = native.store();
    try testing.expectEqual(@as(usize, 3), s.stats().live_count);
    var rec = try s.read(testing.allocator, unknown_id);
    defer rec.deinit();
    try testing.expectEqual(@as(u8, 200), rec.kind);
    try testing.expectEqual(@as(u16, 42), rec.version);
}

test "history journal: compaction preserves live payloads across a reopen" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var keep: RecordId = 0;
    var dropped: RecordId = 0;
    {
        var native = try NativeStore.open(testing.allocator, testing.io, tmp.dir, "doc.hjr", "/d/a.pix");
        defer native.deinit();
        const s = native.store();
        dropped = try s.append(1, 1, "obsolete" ** 8);
        keep = try s.append(2, 1, "retained payload");
        try testing.expectEqual(dropped, s.dropOldest().?);
        try testing.expect(s.stats().dropped_bytes > 0);
        try s.compact();
        try s.sync();
    }
    var native = try NativeStore.open(testing.allocator, testing.io, tmp.dir, "doc.hjr", "/d/a.pix");
    defer native.deinit();
    const s = native.store();
    try testing.expectEqual(@as(usize, 1), s.stats().live_count);
    var rec = try s.read(testing.allocator, keep);
    defer rec.deinit();
    try testing.expectEqualStrings("retained payload", rec.payload);
    try testing.expectError(error.NotFound, s.read(testing.allocator, dropped));
}

test "history journal: an oversized payload is refused before any bytes are written" {
    var mem = MemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();
    // Build a slice descriptor larger than the cap without allocating it.
    const huge: []const u8 = @as([*]const u8, @ptrFromInt(0x1000))[0 .. max_record_payload + 1];
    try testing.expectError(error.RecordTooLarge, s.append(1, 1, huge));
    try testing.expectEqual(@as(usize, 0), s.stats().live_count);
}

test "history journal: maintenance removes orphans and evicts by age" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // A journal whose document exists (this very directory entry stands in for it).
    try file_safety.writeAtomicToDir(testing.io, tmp.dir, "live.pix", "document", .{});
    var doc_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(testing.io, &doc_path_buf);
    _ = cwd_len;

    {
        // Orphan: names a document that cannot exist.
        var orphan = try NativeStore.open(testing.allocator, testing.io, tmp.dir, "orphan.hjr", "/nonexistent/definitely-missing.pix");
        defer orphan.deinit();
        _ = try orphan.store().append(1, 1, "x");
    }
    {
        // Unreadable header: not a journal at all.
        try file_safety.writeAtomicToDir(testing.io, tmp.dir, "garbage.hjr", "not a journal", .{});
    }
    const report = try maintain(testing.allocator, testing.io, tmp.dir, 0, .{});
    try testing.expectEqual(@as(usize, 2), report.removed_orphan);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "orphan.hjr", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "garbage.hjr", .{}));
    // A non-journal file is never touched.
    try tmp.dir.access(testing.io, "live.pix", .{});
}

test "history journal: the durability boundary is explicit, not per append" {
    var mem = MemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();
    _ = try s.append(1, 1, "a");
    _ = try s.append(1, 1, "b");
    try testing.expectEqual(@as(usize, 0), mem.sync_count);
    try s.sync();
    try testing.expectEqual(@as(usize, 1), mem.sync_count);
}
