//! apps/patch: DynGraph のノード/エッジ構成の直列化（TASK-65 serialize / TASK-105.4 旧 PTCG）。
//!
//! libs/serde の versioned container（TASK-62.2）に NODE chunk × N（ノード=kind+world 座標）と
//! EDGE chunk × M（接続）を繰り返し載せる（`libs/paint` の `document_io.zig` が LAYR chunk を
//! layer 数ぶん繰り返すのと同じ「可変個の小さい chunk を repeated tag で並べる」流儀）。
//!
//! **TASK-105.4**: 正規のプロジェクト保存は `project_io.zig`（VPRJ）。本 file は旧 PTCG の
//! reader/encoder（fixture・統合 reader からの変換）と NODE/EDGE layout の単一ソースを維持する。
//! 新 path の writer は VPRJ に寄せ、PTCG writer を新しい保存経路から呼ばない。
//!
//! **ModuleKind 互換**: enum ordinal は永続化フォーマットの一部。新しい ModuleKind は enum の
//! 末尾にのみ追加する。既存 tag の並べ替え・削除・名前変更は禁止。未知 ordinal は NODE 単位で
//! skip（対応 EDGE は load 側 mapping 欠落で自然除外）。
//!
//! **スコープ**: 生ノード（`DynGraph.add/removeModule/connect/disconnect`）のみを対象とする。
//! マクロ（DrumMachine/BassMachine）の折り畳み情報（`group.Ledger`）は対象外
//! （既存 action set が `add_node`/`remove_node`/`connect`/`disconnect` という「生ノード」操作のみを
//! 提供するのと同じスコープ。load 後、元マクロのメンバーは折り畳まれていない生ノードとして復元される）。
//! master 出力（`DynGraph.setOutput`）も対象外（既存 action に `set_output` が無く、現状は起動時の
//! 既定パッチにのみ存在するため。今後 action 化されたら本 file に OUTP chunk を追加する）。
//!
//! **循環 import 回避**: `App`/`Handle`/`Vec2f`（apps/patch/main.zig・canvas.zig 具体型）は import
//! しない。`modular`（`ModuleKind` の単一ソース）のみ依存する（main.zig も既に直 import 済みの
//! 「流動 lib・app_direct_ok」なので、この file が使うのと同じ依存で完結する）。
//!
//! ホットパス宣言: encode/decode/save/load は **イベント時のみ**（`save_graph`/`load_graph` action
//! 1回につき1回）。RT 経路（`DynGraph.processBlock`）には一切触れない。

const std = @import("std");
const serde = @import("serde");
const modular = @import("modular");

pub const Handle = u16;
pub const ModuleKind = modular.ModuleKind;

/// 'PTCG'（patch graph）の little-endian u32。serde の expected_magic に渡す。
pub const magic: u32 = @as(u32, 'P') | (@as(u32, 'T') << 8) | (@as(u32, 'C') << 16) | (@as(u32, 'G') << 24);
pub const schema_version: u16 = 1;

const TAG_NODE: [4]u8 = "NODE".*;
const TAG_EDGE: [4]u8 = "EDGE".*;

// NODE payload layout（little-endian・固定 11B）: handle u16 | kind u8(ModuleKind ordinal) | x f32 | y f32
const NODE_SIZE: usize = 11;
// EDGE payload layout（固定 6B）: src_handle u16 | src_out u8 | dst_handle u16 | dst_in u8
const EDGE_SIZE: usize = 6;

pub const NodeEntry = struct { handle: Handle, kind: ModuleKind, x: f32, y: f32 };
pub const EdgeEntry = struct { src_handle: Handle, src_out: u8, dst_handle: Handle, dst_in: u8 };

pub const DecodeError = error{
    UnsupportedSchemaVersion,
    CorruptNode,
    CorruptEdge,
};

fn packNode(n: NodeEntry, out: *[NODE_SIZE]u8) void {
    std.mem.writeInt(u16, out[0..2], n.handle, .little);
    out[2] = @intFromEnum(n.kind);
    std.mem.writeInt(u32, out[3..7], @bitCast(n.x), .little);
    std.mem.writeInt(u32, out[7..11], @bitCast(n.y), .little);
}

fn packEdge(e: EdgeEntry, out: *[EDGE_SIZE]u8) void {
    std.mem.writeInt(u16, out[0..2], e.src_handle, .little);
    out[2] = e.src_out;
    std.mem.writeInt(u16, out[3..5], e.dst_handle, .little);
    out[5] = e.dst_in;
}

/// `ModuleKind` は exhaustive enum なので `@enumFromInt` は範囲外値で safety-checked illegal
/// behavior（panic）になる。`std.meta.intToEnum` 相当を手書きし、宣言済み tag 値との一致を
/// 確認してから `@enumFromInt` する（前方互換: 未知 kind ordinal は null を返し caller が skip する）。
fn moduleKindFromU8(v: u8) ?ModuleKind {
    inline for (@typeInfo(ModuleKind).@"enum".fields) |f| {
        if (f.value == v) return @enumFromInt(v);
    }
    return null;
}

/// nodes/edges を NODE×N/EDGE×M の container へ組み立てる（caller が free する）。
pub fn encodeGraph(gpa: std.mem.Allocator, nodes: []const NodeEntry, edges: []const EdgeEntry) ![]u8 {
    var w = try serde.Writer.init(gpa, magic, schema_version);
    errdefer w.deinit();

    for (nodes) |n| {
        var buf: [NODE_SIZE]u8 = undefined;
        packNode(n, &buf);
        try w.addChunk(TAG_NODE, &buf);
    }
    for (edges) |e| {
        var buf: [EDGE_SIZE]u8 = undefined;
        packEdge(e, &buf);
        try w.addChunk(TAG_EDGE, &buf);
    }
    return w.finish();
}

pub const DecodedGraph = struct {
    nodes: []NodeEntry, // gpa 確保（caller が free）
    edges: []EdgeEntry, // gpa 確保（caller が free）

    pub fn deinit(self: *DecodedGraph, gpa: std.mem.Allocator) void {
        gpa.free(self.nodes);
        gpa.free(self.edges);
    }
};

/// バイト列から nodes/edges を復元する。**未知 `ModuleKind`（将来の schema 拡張）の NODE は
/// skip する**（前方互換。その handle を参照する EDGE は main.zig 側のロード処理が
/// 「対応する新 handle が見つからない」として自然に無視する）。
pub fn decodeGraph(gpa: std.mem.Allocator, bytes: []const u8) !DecodedGraph {
    const container = try serde.Container.parse(bytes, magic);
    if (container.schemaVersion() > schema_version) return error.UnsupportedSchemaVersion;

    var nodes: std.ArrayList(NodeEntry) = .empty;
    errdefer nodes.deinit(gpa);
    var edges: std.ArrayList(EdgeEntry) = .empty;
    errdefer edges.deinit(gpa);

    var it = container.iterator();
    while (it.next()) |chunk| {
        if (std.mem.eql(u8, &chunk.tag, &TAG_NODE)) {
            if (chunk.payload.len != NODE_SIZE) return error.CorruptNode;
            const handle = std.mem.readInt(u16, chunk.payload[0..2], .little);
            const kind = moduleKindFromU8(chunk.payload[2]) orelse continue; // 未知 kind: skip
            const x: f32 = @bitCast(std.mem.readInt(u32, chunk.payload[3..7], .little));
            const y: f32 = @bitCast(std.mem.readInt(u32, chunk.payload[7..11], .little));
            try nodes.append(gpa, .{ .handle = handle, .kind = kind, .x = x, .y = y });
        } else if (std.mem.eql(u8, &chunk.tag, &TAG_EDGE)) {
            if (chunk.payload.len != EDGE_SIZE) return error.CorruptEdge;
            const src_handle = std.mem.readInt(u16, chunk.payload[0..2], .little);
            const src_out = chunk.payload[2];
            const dst_handle = std.mem.readInt(u16, chunk.payload[3..5], .little);
            const dst_in = chunk.payload[5];
            try edges.append(gpa, .{ .src_handle = src_handle, .src_out = src_out, .dst_handle = dst_handle, .dst_in = dst_in });
        }
        // 未知 tag は無視（serde iterator は全 chunk を返すが match しないものは skip）
    }

    return .{ .nodes = try nodes.toOwnedSlice(gpa), .edges = try edges.toOwnedSlice(gpa) };
}

pub fn saveGraph(io: std.Io, path: []const u8, gpa: std.mem.Allocator, nodes: []const NodeEntry, edges: []const EdgeEntry) !void {
    const bytes = try encodeGraph(gpa, nodes, edges);
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

pub fn loadGraph(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !DecodedGraph {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    return decodeGraph(gpa, bytes);
}

// ============================ tests ============================

const testing = std.testing;

test "encode/decode: round-trip nodes + edges（出現順保持）" {
    const gpa = testing.allocator;
    const nodes = [_]NodeEntry{
        .{ .handle = 0, .kind = .vco, .x = 10, .y = 20 },
        .{ .handle = 1, .kind = .vcf, .x = 100.5, .y = -5.25 },
        .{ .handle = 2, .kind = .output, .x = 200, .y = 0 },
    };
    const edges = [_]EdgeEntry{
        .{ .src_handle = 0, .src_out = 0, .dst_handle = 1, .dst_in = 0 },
        .{ .src_handle = 1, .src_out = 0, .dst_handle = 2, .dst_in = 0 },
    };

    const bytes = try encodeGraph(gpa, &nodes, &edges);
    defer gpa.free(bytes);

    var got = try decodeGraph(gpa, bytes);
    defer got.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), got.nodes.len);
    try testing.expectEqual(@as(usize, 2), got.edges.len);
    for (nodes, got.nodes) |want, have| try testing.expectEqual(want, have);
    for (edges, got.edges) |want, have| try testing.expectEqual(want, have);
}

test "encode/decode: 空グラフ（0 ノード・0 エッジ）" {
    const gpa = testing.allocator;
    const bytes = try encodeGraph(gpa, &.{}, &.{});
    defer gpa.free(bytes);
    var got = try decodeGraph(gpa, bytes);
    defer got.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), got.nodes.len);
    try testing.expectEqual(@as(usize, 0), got.edges.len);
}

test "前方互換: 未知 kind の NODE と未知 chunk tag を skip する" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, schema_version);
    defer w.deinit();
    var buf: [NODE_SIZE]u8 = undefined;
    packNode(.{ .handle = 0, .kind = .vco, .x = 1, .y = 2 }, &buf);
    try w.addChunk(TAG_NODE, &buf);
    // 未知 kind ordinal（ModuleKind の tag 数を超える値）
    var bad: [NODE_SIZE]u8 = undefined;
    std.mem.writeInt(u16, bad[0..2], 99, .little);
    bad[2] = 255;
    std.mem.writeInt(u32, bad[3..7], @bitCast(@as(f32, 0)), .little);
    std.mem.writeInt(u32, bad[7..11], @bitCast(@as(f32, 0)), .little);
    try w.addChunk(TAG_NODE, &bad);
    try w.addChunk("XxYy".*, "future-unknown-chunk");
    const bytes = try w.finish();
    defer gpa.free(bytes);

    var got = try decodeGraph(gpa, bytes);
    defer got.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), got.nodes.len); // 未知 kind は skip
    try testing.expectEqual(ModuleKind.vco, got.nodes[0].kind);
}

test "後方互換: 107 実装前の sidechain(ordinal 25) fixture と新 kind 末尾追加" {
    const gpa = testing.allocator;
    // TASK-107 前に保存された固定バイト列。NODE(sidechain, ordinal=25) + EDGE。
    const legacy = [_]u8{
        0x50, 0x54, 0x43, 0x47, 0x01, 0x00, 0x01, 0x00,
        0x4E, 0x4F, 0x44, 0x45, 0x0B, 0x00, 0x00, 0x00,
        0x07, 0x00, 0x19, 0x00, 0x00, 0x48, 0x41, 0x00,
        0x00, 0x40, 0xC0, 0x45, 0x44, 0x47, 0x45, 0x06,
        0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x08, 0x00,
        0x00, 0xD8, 0x7B, 0x8E, 0x7C,
    };
    var old = try decodeGraph(gpa, &legacy);
    defer old.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), old.nodes.len);
    try testing.expectEqual(ModuleKind.sidechain, old.nodes[0].kind);
    try testing.expectEqual(@as(u8, 25), @intFromEnum(old.nodes[0].kind));
    try testing.expectEqual(@as(usize, 1), old.edges.len);
    try testing.expectEqual(@as(Handle, 7), old.edges[0].src_handle);
    try testing.expectEqual(@as(Handle, 8), old.edges[0].dst_handle);

    try testing.expectEqual(@as(u8, 26), @intFromEnum(ModuleKind.slew));
    try testing.expectEqual(@as(u8, 27), @intFromEnum(ModuleKind.sample_hold));
    try testing.expectEqual(@as(u8, 28), @intFromEnum(ModuleKind.comparator));
    try testing.expectEqual(@as(u8, 29), @intFromEnum(ModuleKind.ring_mod));
    try testing.expectEqual(@as(u8, 30), @intFromEnum(ModuleKind.logic));
}

test "破損検出: UnsupportedSchemaVersion / CorruptNode / CorruptEdge / BadMagic" {
    const gpa = testing.allocator;

    {
        var w = try serde.Writer.init(gpa, magic, schema_version + 1);
        defer w.deinit();
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.UnsupportedSchemaVersion, decodeGraph(gpa, bytes));
    }
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        try w.addChunk(TAG_NODE, "short");
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptNode, decodeGraph(gpa, bytes));
    }
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        try w.addChunk(TAG_EDGE, "x");
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptEdge, decodeGraph(gpa, bytes));
    }
    {
        var w = try serde.Writer.init(gpa, 0x11111111, schema_version);
        defer w.deinit();
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.BadMagic, decodeGraph(gpa, bytes));
    }
}

test "file I/O: save→load round-trip" {
    const gpa = testing.allocator;
    const io = testing.io;
    const path = ".task65_patch_graph_io_test.ptcg";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const nodes = [_]NodeEntry{
        .{ .handle = 3, .kind = .lfo, .x = 5, .y = 6 },
    };
    const edges = [_]EdgeEntry{};
    try saveGraph(io, path, gpa, &nodes, &edges);

    var got = try loadGraph(io, gpa, path);
    defer got.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), got.nodes.len);
    try testing.expectEqual(nodes[0], got.nodes[0]);
    try testing.expectEqual(@as(usize, 0), got.edges.len);
}
