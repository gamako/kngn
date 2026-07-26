//! serde — cross-app versioned container serialization foundation.
//!
//! **Lineage**: RIFF/IFF family (magic + little-endian + FOURCC-tagged length-prefixed
//! chunk sequence) as the base, plus a two-level version (container/schema) for forward/backward
//! compat and a footer CRC. Extends this repo's existing PNG chunk convention
//! (tag/len/payload + CRC-32/ISO-HDLC) and probe-snapshot style (opaque raw bytes).
//! Heavy schema-driven serializers (protobuf/flatbuffers, etc.) are rejected: they fight
//! the no-deps pure-Zig policy and the "framework does not interpret schema" design.
//!
//! **Format** (little-endian fixed):
//! ```
//! header: magic u32 (caller-chosen, per app) | container_version u16(=1) | schema_version u16 (app-owned, uninterpreted)
//! chunks: sequence of { tag [4]u8 | len u32 | payload [len]u8 } (duplicate tags allowed; order preserved)
//! footer: crc32 u32 (CRC-32/ISO-HDLC over header + all chunks)
//! ```
//! - Forward compat: reader can skip unknown-tag chunks by len.
//! - Backward compat: detecting missing required chunks is the app's job (framework only enumerates).
//! - App schema uninterpreted: payloads are returned as []const u8 (framework does not interpret contents).
//!
//! **Hot-path note**: serialize/parse run only at init/event time (save/load I/O).
//! They do not run per-frame or on the RT path → the SIMD three-point set, cache_line separation, and before/after bench are
//! not required. Large payloads use bulk @memcpy; no per-element append
//! (Writer does ensureUnusedCapacity → appendSliceAssumeCapacity per chunk).
//! parse only views the input bytes and takes no allocator (zero-allocation on the restore path).

const std = @import("std");

/// Framework-managed container version. Separate from schema_version (app-managed).
pub const container_version: u16 = 1;

const header_size: usize = 4 + 2 + 2; // magic u32 + container_version u16 + schema_version u16
const chunk_header_size: usize = 4 + 4; // tag [4]u8 + len u32
const footer_size: usize = 4; // crc32 u32

/// Errors on the parse (restore) path. Writer OOM / oversized payload are separate (addChunk's inferred error set).
pub const Error = error{
    BadMagic,
    UnsupportedContainerVersion,
    Truncated,
    CrcMismatch,
};

/// One chunk (views of tag and payload).
pub const Chunk = struct {
    tag: [4]u8,
    payload: []const u8,
};

/// Writer that builds a versioned container.
///
/// Reserve capacity per chunk, then bulk-copy (no per-byte append).
/// header is written in init; CRC is appended as the trailing 4B in finish.
pub const Writer = struct {
    buf: std.ArrayList(u8),
    gpa: std.mem.Allocator,

    /// Write the header (magic / container_version / schema_version) and return a Writer.
    pub fn init(gpa: std.mem.Allocator, magic: u32, schema_version: u16) std.mem.Allocator.Error!Writer {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);
        try buf.ensureUnusedCapacity(gpa, header_size);
        var hdr: [header_size]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], magic, .little);
        std.mem.writeInt(u16, hdr[4..6], container_version, .little);
        std.mem.writeInt(u16, hdr[6..8], schema_version, .little);
        buf.appendSliceAssumeCapacity(&hdr);
        return .{ .buf = buf, .gpa = gpa };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.gpa);
    }

    /// Append one chunk (repeated adds of the same tag are stored in appearance order).
    pub fn addChunk(self: *Writer, tag: [4]u8, payload: []const u8) error{ OutOfMemory, PayloadTooLarge }!void {
        if (payload.len > std.math.maxInt(u32)) return error.PayloadTooLarge;
        try self.buf.ensureUnusedCapacity(self.gpa, chunk_header_size + payload.len);
        var ch: [chunk_header_size]u8 = undefined;
        @memcpy(ch[0..4], &tag);
        std.mem.writeInt(u32, ch[4..8], @intCast(payload.len), .little);
        self.buf.appendSliceAssumeCapacity(&ch);
        self.buf.appendSliceAssumeCapacity(payload);
    }

    /// Append the footer CRC and return an owned byte slice (caller frees).
    /// After this call the Writer is empty (deinit remains safe).
    pub fn finish(self: *Writer) std.mem.Allocator.Error![]u8 {
        const crc = std.hash.Crc32.hash(self.buf.items); // header + all chunks
        try self.buf.ensureUnusedCapacity(self.gpa, footer_size);
        var f: [footer_size]u8 = undefined;
        std.mem.writeInt(u32, &f, crc, .little);
        self.buf.appendSliceAssumeCapacity(&f);
        return self.buf.toOwnedSlice(self.gpa);
    }
};

/// Parsed container. Holds only views into the input bytes; no allocator
/// (API shape structurally guarantees zero-allocation on the restore path).
pub const Container = struct {
    bytes: []const u8, // view of the whole container (including footer)
    schema_version_value: u16,

    /// Validate magic / container_version / CRC / chunk framing and return a Container.
    /// `expected_magic` is the magic chosen by the caller (app). serde cannot return BadMagic
    /// without knowing the expected value, so it is passed as an argument.
    pub fn parse(bytes: []const u8, expected_magic: u32) Error!Container {
        if (bytes.len < header_size + footer_size) return error.Truncated;

        const magic = std.mem.readInt(u32, bytes[0..4], .little);
        if (magic != expected_magic) return error.BadMagic;

        const cver = std.mem.readInt(u16, bytes[4..6], .little);
        if (cver != container_version) return error.UnsupportedContainerVersion;

        const sver = std.mem.readInt(u16, bytes[6..8], .little);

        // footer = trailing 4B; body (=CRC input) = bytes[0..len-4] (header + all chunks).
        const body = bytes[0 .. bytes.len - footer_size];

        // Fully validate chunk framing **before** the CRC. That way
        // structural loss (missing tail / truncated chunk header/payload) becomes Truncated, and content/footer
        // bit corruption (framing intact) becomes CrcMismatch. Also establishes the invariant that the iterator
        // never walks past the end. Length checks use remaining length before adding (avoids cursor+len wrap).
        var cursor: usize = header_size;
        const end = body.len;
        while (cursor < end) {
            if (end - cursor < chunk_header_size) return error.Truncated;
            const len: usize = std.mem.readInt(u32, body[cursor + 4 ..][0..4], .little);
            cursor += chunk_header_size;
            if (len > end - cursor) return error.Truncated;
            cursor += len;
        }
        // Must end exactly at end (consequence of framing validation; checked defensively).
        if (cursor != end) return error.Truncated;

        // After framing OK, check CRC (separates content/footer corruption into CrcMismatch).
        const stored_crc = std.mem.readInt(u32, bytes[bytes.len - footer_size ..][0..4], .little);
        if (std.hash.Crc32.hash(body) != stored_crc) return error.CrcMismatch;

        return .{ .bytes = bytes, .schema_version_value = sver };
    }

    /// App-managed schema version.
    pub fn schemaVersion(self: Container) u16 {
        return self.schema_version_value;
    }

    /// Iterator that enumerates chunks in appearance order.
    pub fn iterator(self: Container) ChunkIterator {
        return .{
            .bytes = self.bytes,
            .cursor = header_size,
            .end = self.bytes.len - footer_size,
        };
    }

    /// Return the first payload matching tag (or null). Use the iterator when there may be duplicates.
    pub fn find(self: Container, tag: [4]u8) ?[]const u8 {
        var it = self.iterator();
        while (it.next()) |c| {
            if (std.mem.eql(u8, &c.tag, &tag)) return c.payload;
        }
        return null;
    }
};

/// Iterator over the container's chunks in appearance order. Framing was validated in parse, so
/// next() slices views without checks (bounds are the invariant parse guarantees).
pub const ChunkIterator = struct {
    bytes: []const u8,
    cursor: usize,
    end: usize,

    pub fn next(self: *ChunkIterator) ?Chunk {
        if (self.cursor >= self.end) return null;
        var tag: [4]u8 = undefined;
        @memcpy(&tag, self.bytes[self.cursor..][0..4]);
        const len: usize = std.mem.readInt(u32, self.bytes[self.cursor + 4 ..][0..4], .little);
        self.cursor += chunk_header_size;
        const payload = self.bytes[self.cursor..][0..len];
        self.cursor += len;
        return .{ .tag = tag, .payload = payload };
    }
};

// ============================ tests ============================

test "round-trip: appearance order / same tag / zero-length / large payload bit-restore" {
    const gpa = std.testing.allocator;
    const magic: u32 = 0xA1B2C3D4;

    // Large payload at 256x256 scale (one pixie layer).
    var big: [256 * 256 * 4]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i * 7 + 3);

    var w = try Writer.init(gpa, magic, 42);
    defer w.deinit();
    try w.addChunk("DOCH".*, "meta-A");
    try w.addChunk("LAYR".*, ""); // zero-length
    try w.addChunk("LAYR".*, "layer-2"); // same tag (appearance order preserved)
    try w.addChunk("LPIX".*, &big); // large payload
    const bytes = try w.finish();
    defer gpa.free(bytes);

    const c = try Container.parse(bytes, magic);
    try std.testing.expectEqual(@as(u16, 42), c.schemaVersion());

    var it = c.iterator();
    const c0 = it.next().?;
    try std.testing.expectEqualSlices(u8, "DOCH", &c0.tag);
    try std.testing.expectEqualSlices(u8, "meta-A", c0.payload);
    const c1 = it.next().?;
    try std.testing.expectEqualSlices(u8, "LAYR", &c1.tag);
    try std.testing.expectEqual(@as(usize, 0), c1.payload.len);
    const c2 = it.next().?;
    try std.testing.expectEqualSlices(u8, "LAYR", &c2.tag);
    try std.testing.expectEqualSlices(u8, "layer-2", c2.payload);
    const c3 = it.next().?;
    try std.testing.expectEqualSlices(u8, "LPIX", &c3.tag);
    try std.testing.expectEqualSlices(u8, &big, c3.payload);
    try std.testing.expect(it.next() == null);

    // find returns the first match
    try std.testing.expectEqualSlices(u8, "meta-A", c.find("DOCH".*).?);
    try std.testing.expectEqual(@as(usize, 0), c.find("LAYR".*).?.len); // first LAYR = zero-len
    try std.testing.expect(c.find("NOPE".*) == null);
}

test "Document-shaped: DOCH + LAYR×N + LPIX layout round-trip" {
    const gpa = std.testing.allocator;
    const magic: u32 = 0x70697831; // 'pix1' equivalent

    var w = try Writer.init(gpa, magic, 1);
    defer w.deinit();

    var doch: [16]u8 = undefined;
    std.mem.writeInt(u32, doch[0..4], 4, .little); // width
    std.mem.writeInt(u32, doch[4..8], 4, .little); // height
    std.mem.writeInt(u32, doch[8..12], 2, .little); // layer_count
    std.mem.writeInt(u32, doch[12..16], 1, .little); // selected
    try w.addChunk("DOCH".*, &doch);

    const px0 = [_]u8{0x11} ** (4 * 4 * 4);
    const px1 = [_]u8{0x22} ** (4 * 4 * 4);
    try w.addChunk("LAYR".*, &[_]u8{ 1, 255 }); // visible, opacity
    try w.addChunk("LPIX".*, &px0);
    try w.addChunk("LAYR".*, &[_]u8{ 0, 128 });
    try w.addChunk("LPIX".*, &px1);

    const bytes = try w.finish();
    defer gpa.free(bytes);

    const c = try Container.parse(bytes, magic);
    var it = c.iterator();
    const d = it.next().?;
    try std.testing.expectEqualSlices(u8, "DOCH", &d.tag);
    const l0 = it.next().?;
    try std.testing.expectEqualSlices(u8, "LAYR", &l0.tag);
    try std.testing.expectEqual(@as(u8, 1), l0.payload[0]);
    const p0 = it.next().?;
    try std.testing.expectEqualSlices(u8, "LPIX", &p0.tag);
    try std.testing.expectEqualSlices(u8, &px0, p0.payload);
    const l1 = it.next().?;
    try std.testing.expectEqual(@as(u8, 0), l1.payload[0]);
    const p1 = it.next().?;
    try std.testing.expectEqualSlices(u8, &px1, p1.payload);
    try std.testing.expect(it.next() == null);
}

test "Forward compat: known chunks readable with unknown tags in between (skip)" {
    const gpa = std.testing.allocator;
    const magic: u32 = 0x55667788;

    var w = try Writer.init(gpa, magic, 3);
    defer w.deinit();
    try w.addChunk("DOCH".*, "doc");
    try w.addChunk("XxYy".*, "future-unknown-chunk-payload"); // unknown tag
    try w.addChunk("LPIX".*, "pixels");
    const bytes = try w.finish();
    defer gpa.free(bytes);

    const c = try Container.parse(bytes, magic);
    try std.testing.expectEqualSlices(u8, "doc", c.find("DOCH".*).?);
    try std.testing.expectEqualSlices(u8, "pixels", c.find("LPIX".*).?);
    var count: usize = 0;
    var it = c.iterator();
    while (it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 3), count); // unknown tags are enumerated too
}

test "Corruption detection: BadMagic / UnsupportedContainerVersion / Truncated / CrcMismatch" {
    const gpa = std.testing.allocator;
    const magic: u32 = 0x11223344;

    var w = try Writer.init(gpa, magic, 1);
    defer w.deinit();
    try w.addChunk("AAAA".*, "payload");
    const bytes = try w.finish();
    defer gpa.free(bytes);

    // BadMagic
    try std.testing.expectError(error.BadMagic, Container.parse(bytes, 0xDEADBEEF));

    // UnsupportedContainerVersion (checked right after magic = before crc)
    {
        const dup = try gpa.dupe(u8, bytes);
        defer gpa.free(dup);
        dup[4] = 0x02; // set container_version to 2
        try std.testing.expectError(error.UnsupportedContainerVersion, Container.parse(dup, magic));
    }

    // Missing trailing 1 byte: declared len of the last chunk exceeds remaining, so framing validation returns Truncated
    // (framing is checked before CRC, so structural loss is separated into Truncated)
    try std.testing.expectError(error.Truncated, Container.parse(bytes[0 .. bytes.len - 1], magic));
    // Truncated: shorter than header+footer
    try std.testing.expectError(error.Truncated, Container.parse(bytes[0..4], magic));

    // CrcMismatch: flip 1 bit in the payload
    {
        const dup = try gpa.dupe(u8, bytes);
        defer gpa.free(dup);
        dup[header_size + chunk_header_size] ^= 0x01;
        try std.testing.expectError(error.CrcMismatch, Container.parse(dup, magic));
    }

    // Truncated: chunk len larger than remaining (framing validation / overflow-safe). Even with a correct CRC,
    // framing-first validation returns Truncated (does not morph into CrcMismatch).
    {
        var frame: [header_size + chunk_header_size + footer_size]u8 = undefined;
        std.mem.writeInt(u32, frame[0..4], magic, .little);
        std.mem.writeInt(u16, frame[4..6], container_version, .little);
        std.mem.writeInt(u16, frame[6..8], 0, .little);
        @memcpy(frame[8..12], "BBBB");
        std.mem.writeInt(u32, frame[12..16], 999, .little); // len=999 with no payload
        const crc = std.hash.Crc32.hash(frame[0 .. frame.len - footer_size]);
        std.mem.writeInt(u32, frame[frame.len - footer_size ..][0..4], crc, .little);
        try std.testing.expectError(error.Truncated, Container.parse(&frame, magic));
    }
}

test "Fixed fixture: handwritten bytes checked against a known CRC constant (Writer-independent)" {
    // magic=0xAABBCCDD, container_version=1, schema=7, chunk 'TEST' payload "hi".
    // footer crc = 0x9F88F4D1 (independent oracle from Python zlib.crc32).
    const fixture = [_]u8{
        0xDD, 0xCC, 0xBB, 0xAA, // magic u32 LE
        0x01, 0x00, // container_version u16 LE
        0x07, 0x00, // schema_version u16 LE
        0x54, 0x45, 0x53, 0x54, // 'TEST'
        0x02, 0x00, 0x00, 0x00, // len=2
        0x68, 0x69, // "hi"
        0xD1, 0xF4, 0x88, 0x9F, // crc32 LE = 0x9F88F4D1
    };
    const c = try Container.parse(&fixture, 0xAABBCCDD);
    try std.testing.expectEqual(@as(u16, 7), c.schemaVersion());
    try std.testing.expectEqualSlices(u8, "hi", c.find("TEST".*).?);

    // Flip 1 byte → CrcMismatch
    var bad = fixture;
    bad[17] ^= 0x01; // the 'i' in the payload
    try std.testing.expectError(error.CrcMismatch, Container.parse(&bad, 0xAABBCCDD));
}
