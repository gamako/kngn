//! serde — app 横断の versioned container 直列化基盤（TASK-62.2）。
//!
//! **系譜**: RIFF/IFF 系統（magic + little-endian + FOURCC タグの length-prefixed
//! チャンク列）を土台に、前方/後方互換のための 2 段 version（container/schema）と
//! footer CRC を上乗せしたもの。独自発明ではなく、リポジトリ既存の PNG チャンク慣習
//! （tag/len/payload + CRC-32/ISO-HDLC）と probe snapshot（中身非解釈の raw bytes）の
//! 延長に位置づける。重量級のスキーマ駆動シリアライザ（protobuf/flatbuffers 等）は
//! 「無依存・純 Zig」方針と「framework は schema 非解釈」設計に反するため採らない。
//!
//! **フォーマット**（little-endian 固定）:
//! ```
//! header: magic u32（呼び出し側指定・app 毎） | container_version u16(=1) | schema_version u16(app 管理・非解釈)
//! chunks: { tag [4]u8 | len u32 | payload [len]u8 } の連続（同一 tag 複数可・出現順保存）
//! footer: crc32 u32（header + 全 chunk を CRC-32/ISO-HDLC）
//! ```
//! - 前方互換: reader は未知 tag chunk を len で skip できる。
//! - 後方互換: 必須 chunk の欠落検出は app 責務（framework は列挙のみ）。
//! - app schema 非解釈: payload は []const u8 のまま返す（framework は中身を解釈しない）。
//!
//! **ホットパス宣言**: 直列化/復元は初期化時/イベント時のみ（保存・読込の I/O 起点。
//! フレーム毎ループ・RT では走らない）→ SIMD 3 点セット・cache_line 分離・bench 前後比較は
//! 不要。大 payload は @memcpy の一括転送で扱い、per-要素 append はしない
//! （Writer は chunk 単位で ensureUnusedCapacity → appendSliceAssumeCapacity）。
//! parse は入力 bytes への view のみで allocator を受け取らない（復元側ゼロアロケーション）。

const std = @import("std");

/// framework 管理のコンテナ版。schema_version（app 管理）とは分離する。
pub const container_version: u16 = 1;

const header_size: usize = 4 + 2 + 2; // magic u32 + container_version u16 + schema_version u16
const chunk_header_size: usize = 4 + 4; // tag [4]u8 + len u32
const footer_size: usize = 4; // crc32 u32

/// parse（復元）側のエラー。Writer 側の OOM / payload 過大は別（addChunk の推論エラー集合）。
pub const Error = error{
    BadMagic,
    UnsupportedContainerVersion,
    Truncated,
    CrcMismatch,
};

/// 1 チャンク（tag と payload への view）。
pub const Chunk = struct {
    tag: [4]u8,
    payload: []const u8,
};

/// versioned container を組み立てる Writer。
///
/// chunk 単位で容量を確保してから一括コピーする（per-byte append をしない）。
/// header は init で書き、CRC は finish で末尾 4B に追記する。
pub const Writer = struct {
    buf: std.ArrayList(u8),
    gpa: std.mem.Allocator,

    /// header（magic / container_version / schema_version）を書いて Writer を返す。
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

    /// チャンクを 1 個追記する（同一 tag の複数回追記も出現順に保存される）。
    pub fn addChunk(self: *Writer, tag: [4]u8, payload: []const u8) error{ OutOfMemory, PayloadTooLarge }!void {
        if (payload.len > std.math.maxInt(u32)) return error.PayloadTooLarge;
        try self.buf.ensureUnusedCapacity(self.gpa, chunk_header_size + payload.len);
        var ch: [chunk_header_size]u8 = undefined;
        @memcpy(ch[0..4], &tag);
        std.mem.writeInt(u32, ch[4..8], @intCast(payload.len), .little);
        self.buf.appendSliceAssumeCapacity(&ch);
        self.buf.appendSliceAssumeCapacity(payload);
    }

    /// footer CRC を追記し、所有権つきバイト列を返す（caller が free する）。
    /// 呼び出し後の Writer は空（deinit は引き続き安全）。
    pub fn finish(self: *Writer) std.mem.Allocator.Error![]u8 {
        const crc = std.hash.Crc32.hash(self.buf.items); // header + 全 chunk
        try self.buf.ensureUnusedCapacity(self.gpa, footer_size);
        var f: [footer_size]u8 = undefined;
        std.mem.writeInt(u32, &f, crc, .little);
        self.buf.appendSliceAssumeCapacity(&f);
        return self.buf.toOwnedSlice(self.gpa);
    }
};

/// パース済み container。入力 bytes への view のみを保持し allocator を持たない
/// （復元側ゼロアロケーションを API 形状で構造的に担保）。
pub const Container = struct {
    bytes: []const u8, // container 全体（footer 含む）への view
    schema_version_value: u16,

    /// magic / container_version / CRC / chunk framing を検証して Container を返す。
    /// `expected_magic` は呼び出し側（app）が指定した magic。serde は magic を
    /// 知らないと BadMagic を返せないため引数で受ける。
    pub fn parse(bytes: []const u8, expected_magic: u32) Error!Container {
        if (bytes.len < header_size + footer_size) return error.Truncated;

        const magic = std.mem.readInt(u32, bytes[0..4], .little);
        if (magic != expected_magic) return error.BadMagic;

        const cver = std.mem.readInt(u16, bytes[4..6], .little);
        if (cver != container_version) return error.UnsupportedContainerVersion;

        const sver = std.mem.readInt(u16, bytes[6..8], .little);

        // footer=末尾 4B、body（=CRC 対象）=bytes[0..len-4]（header + 全 chunk）。
        const body = bytes[0 .. bytes.len - footer_size];

        // chunk framing を **CRC より先に** 完全検証する。こうすると
        // 構造的欠落（tail 欠落・chunk header/payload 端数）は Truncated、内容/footer の
        // bit 破損（framing 健全）は CrcMismatch に分離できる。かつ iterator が末尾を
        // 踏み越えない不変条件も確立する。長さ判定は加算前に残り長で行う（cursor+len の wrap 回避）。
        var cursor: usize = header_size;
        const end = body.len;
        while (cursor < end) {
            if (end - cursor < chunk_header_size) return error.Truncated;
            const len: usize = std.mem.readInt(u32, body[cursor + 4 ..][0..4], .little);
            cursor += chunk_header_size;
            if (len > end - cursor) return error.Truncated;
            cursor += len;
        }
        // ちょうど end で終わるはず（framing 検証の帰結。防御的に確認）。
        if (cursor != end) return error.Truncated;

        // framing OK の後に CRC 照合（内容/footer 破損を CrcMismatch に分離）。
        const stored_crc = std.mem.readInt(u32, bytes[bytes.len - footer_size ..][0..4], .little);
        if (std.hash.Crc32.hash(body) != stored_crc) return error.CrcMismatch;

        return .{ .bytes = bytes, .schema_version_value = sver };
    }

    /// app 管理の schema version。
    pub fn schemaVersion(self: Container) u16 {
        return self.schema_version_value;
    }

    /// チャンクを出現順に列挙する iterator。
    pub fn iterator(self: Container) ChunkIterator {
        return .{
            .bytes = self.bytes,
            .cursor = header_size,
            .end = self.bytes.len - footer_size,
        };
    }

    /// 指定 tag の先頭一致 payload を返す（無ければ null）。複数出現があれば iterator を使う。
    pub fn find(self: Container, tag: [4]u8) ?[]const u8 {
        var it = self.iterator();
        while (it.next()) |c| {
            if (std.mem.eql(u8, &c.tag, &tag)) return c.payload;
        }
        return null;
    }
};

/// container のチャンクを出現順に返す iterator。framing は parse で検証済みなので
/// next() は無検査で view を切り出す（bounds は parse が保証する不変条件）。
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

test "round-trip: 出現順・同一 tag・ゼロ長・大 payload を bit 復元" {
    const gpa = std.testing.allocator;
    const magic: u32 = 0xA1B2C3D4;

    // 256x256 級（pixie の 1 layer 相当）の大 payload。
    var big: [256 * 256 * 4]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i * 7 + 3);

    var w = try Writer.init(gpa, magic, 42);
    defer w.deinit();
    try w.addChunk("DOCH".*, "meta-A");
    try w.addChunk("LAYR".*, ""); // ゼロ長
    try w.addChunk("LAYR".*, "layer-2"); // 同一 tag（出現順保存）
    try w.addChunk("LPIX".*, &big); // 大 payload
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

    // find は先頭一致
    try std.testing.expectEqualSlices(u8, "meta-A", c.find("DOCH".*).?);
    try std.testing.expectEqual(@as(usize, 0), c.find("LAYR".*).?.len); // 先頭 LAYR = zero-len
    try std.testing.expect(c.find("NOPE".*) == null);
}

test "Document 相当: DOCH + LAYR×N + LPIX の構成を round-trip" {
    const gpa = std.testing.allocator;
    const magic: u32 = 0x70697831; // 'pix1' 相当

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

test "前方互換: 未知 tag を挟んでも既知 chunk を読める（skip）" {
    const gpa = std.testing.allocator;
    const magic: u32 = 0x55667788;

    var w = try Writer.init(gpa, magic, 3);
    defer w.deinit();
    try w.addChunk("DOCH".*, "doc");
    try w.addChunk("XxYy".*, "future-unknown-chunk-payload"); // 未知 tag
    try w.addChunk("LPIX".*, "pixels");
    const bytes = try w.finish();
    defer gpa.free(bytes);

    const c = try Container.parse(bytes, magic);
    try std.testing.expectEqualSlices(u8, "doc", c.find("DOCH".*).?);
    try std.testing.expectEqualSlices(u8, "pixels", c.find("LPIX".*).?);
    var count: usize = 0;
    var it = c.iterator();
    while (it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 3), count); // 未知 tag も列挙される
}

test "破損検出: BadMagic / UnsupportedContainerVersion / Truncated / CrcMismatch" {
    const gpa = std.testing.allocator;
    const magic: u32 = 0x11223344;

    var w = try Writer.init(gpa, magic, 1);
    defer w.deinit();
    try w.addChunk("AAAA".*, "payload");
    const bytes = try w.finish();
    defer gpa.free(bytes);

    // BadMagic
    try std.testing.expectError(error.BadMagic, Container.parse(bytes, 0xDEADBEEF));

    // UnsupportedContainerVersion（magic の次に検査＝crc より先）
    {
        const dup = try gpa.dupe(u8, bytes);
        defer gpa.free(dup);
        dup[4] = 0x02; // container_version を 2 に
        try std.testing.expectError(error.UnsupportedContainerVersion, Container.parse(dup, magic));
    }

    // 末尾 1 byte 欠落: 最終 chunk の宣言 len が残りを超えるため framing 検証が Truncated を返す
    // （CRC より前に framing を検証するので、構造的欠落は Truncated に分離される）
    try std.testing.expectError(error.Truncated, Container.parse(bytes[0 .. bytes.len - 1], magic));
    // Truncated: header+footer より短い
    try std.testing.expectError(error.Truncated, Container.parse(bytes[0..4], magic));

    // CrcMismatch: payload 1bit 破壊
    {
        const dup = try gpa.dupe(u8, bytes);
        defer gpa.free(dup);
        dup[header_size + chunk_header_size] ^= 0x01;
        try std.testing.expectError(error.CrcMismatch, Container.parse(dup, magic));
    }

    // Truncated: chunk len が残りより過大（framing 検証 / overflow-safe）。CRC を正しく詰めても
    // framing を先に検証するので Truncated が返る（CrcMismatch に化けない）ことも確認する。
    {
        var frame: [header_size + chunk_header_size + footer_size]u8 = undefined;
        std.mem.writeInt(u32, frame[0..4], magic, .little);
        std.mem.writeInt(u16, frame[4..6], container_version, .little);
        std.mem.writeInt(u16, frame[6..8], 0, .little);
        @memcpy(frame[8..12], "BBBB");
        std.mem.writeInt(u32, frame[12..16], 999, .little); // payload 無しなのに len=999
        const crc = std.hash.Crc32.hash(frame[0 .. frame.len - footer_size]);
        std.mem.writeInt(u32, frame[frame.len - footer_size ..][0..4], crc, .little);
        try std.testing.expectError(error.Truncated, Container.parse(&frame, magic));
    }
}

test "固定 fixture: 手書き byte 列を既知 CRC 定数で検証（Writer 非依存）" {
    // magic=0xAABBCCDD, container_version=1, schema=7, chunk 'TEST' payload "hi"。
    // footer crc = 0x9F88F4D1（Python zlib.crc32 で算出した独立オラクル）。
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

    // 1 byte 破壊 → CrcMismatch
    var bad = fixture;
    bad[17] ^= 0x01; // payload の 'i'
    try std.testing.expectError(error.CrcMismatch, Container.parse(&bad, 0xAABBCCDD));
}
