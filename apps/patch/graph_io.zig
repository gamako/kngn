//! apps/patch: serialization of the DynGraph node/edge topology (legacy PTCG format).
//!
//! On top of libs/serde's versioned container, lay NODE chunk × N (node = kind + world coordinates) and
//! EDGE chunk × M (connections) repeatedly (the same convention `document_io.zig` in `libs/paint` uses to repeat LAYR chunk
//! once per layer — laying a variable number of small chunks under a repeated tag).
//!
//! The canonical project save path is `project_io.zig` (KNGN). This file maintains the legacy PTCG
//! reader/encoder (fixture and conversion from the unified reader) and remains the single source for NODE/EDGE layout.
//! New save paths should use the KNGN writer; do not call the PTCG writer from a new save path.
//!
//! **ModuleKind compatibility**: the enum ordinal is part of the persisted format. New ModuleKind values must be
//! appended only at the end of the enum. Reordering, removing, or renaming existing tags is forbidden. Unknown ordinals are
//! skipped per NODE (the corresponding EDGE is naturally excluded by the missing mapping on load).
//!
//! **Scope**: covers only raw nodes (`DynGraph.add/removeModule/connect/disconnect`).
//! Macro (DrumMachine/BassMachine) folding info (`group.Ledger`) is out of scope
//! (the existing action set only provides "raw node" operations — `add_node`/`remove_node`/`connect`/`disconnect` —
//! matching that same scope. After load, the original macro's members are restored as unfolded raw nodes).
//! Master output (`DynGraph.setOutput`) is also out of scope (there is no `set_output` action; it currently exists only in the
//! default startup patch. If it becomes an action later, add an OUTP chunk to this file).
//!
//! **Avoiding circular imports**: does not import `App`/`Handle`/`Vec2f` (concrete types from apps/patch/main.zig and
//! canvas.zig). Depends only on `modular` (the single source for `ModuleKind`) (since main.zig already directly imports it
//! as a "flowing lib, app_direct_ok", this file is self-contained with the same dependency it uses).
//!
//! Hot-path declaration: encode/decode/save/load run **only on events** (once per `save_graph`/`load_graph` action
//! invocation). Never touches the RT path (`DynGraph.processBlock`).

const std = @import("std");
const serde = @import("serde");
const modular = @import("modular");

pub const Handle = u16;
pub const ModuleKind = modular.ModuleKind;

/// Stable node reference. Separate from the runtime `DynGraph.Handle`.
/// `0 = invalid`, monotonically increasing with no reuse (same shape as pixie's `LayerId`).
pub const NodeId = enum(u64) {
    invalid = 0,
    _,

    pub fn raw(self: NodeId) u64 {
        return @intFromEnum(self);
    }

    pub fn fromRaw(v: u64) NodeId {
        return @enumFromInt(v);
    }
};

/// Node for stable export (equality / digest; does not carry the runtime handle).
pub const StableNode = struct {
    id: NodeId,
    kind: ModuleKind,
    x: f32,
    y: f32,
};

/// Edge for stable export (NodeId-based; sort key is src_id, src_out, dst_id, dst_in).
pub const StableEdge = struct {
    src_id: NodeId,
    src_out: u8,
    dst_id: NodeId,
    dst_in: u8,
};

pub const StableGraph = struct {
    nodes: []StableNode,
    edges: []StableEdge,
    output_id: ?NodeId = null,

    pub fn deinit(self: *StableGraph, gpa: std.mem.Allocator) void {
        gpa.free(self.nodes);
        gpa.free(self.edges);
    }
};

fn lessStableNode(ctx: void, a: StableNode, b: StableNode) bool {
    _ = ctx;
    return a.id.raw() < b.id.raw();
}

fn lessStableEdge(ctx: void, a: StableEdge, b: StableEdge) bool {
    _ = ctx;
    if (a.src_id.raw() != b.src_id.raw()) return a.src_id.raw() < b.src_id.raw();
    if (a.src_out != b.src_out) return a.src_out < b.src_out;
    if (a.dst_id.raw() != b.dst_id.raw()) return a.dst_id.raw() < b.dst_id.raw();
    return a.dst_in < b.dst_in;
}

/// Returns a canonical export with nodes/edges sorted by ascending NodeId and edge key (caller frees).
/// Skips active-equivalent entries where `handle_to_id[h]` is null (assumes the caller passes only allocated entries).
pub fn canonicalizeStableGraph(
    gpa: std.mem.Allocator,
    nodes: []const StableNode,
    edges: []const StableEdge,
    output_id: ?NodeId,
) !StableGraph {
    const n_out = try gpa.dupe(StableNode, nodes);
    errdefer gpa.free(n_out);
    const e_out = try gpa.dupe(StableEdge, edges);
    errdefer gpa.free(e_out);
    std.mem.sort(StableNode, n_out, {}, lessStableNode);
    std.mem.sort(StableEdge, e_out, {}, lessStableEdge);
    return .{ .nodes = n_out, .edges = e_out, .output_id = output_id };
}

/// Deterministically assigns NodeId from the legacy NodeEntry order (appearance order) (schema 1 / PTCG fallback).
/// The returned ids[i] correspond to nodes[i]. next = max+1 (1 if empty).
pub fn assignFallbackNodeIds(nodes: []const NodeEntry, ids_out: []NodeId) u64 {
    std.debug.assert(ids_out.len >= nodes.len);
    var next: u64 = 1;
    for (nodes, 0..) |_, i| {
        ids_out[i] = NodeId.fromRaw(next);
        next += 1;
    }
    return next;
}

/// Stable topology JSON (shared body for digest / snapshot).
/// Format: `{"nodes":[{"id":N,"kind":"...","x":..,"y":..},...],"edges":[[sid,so,did,di],...],"output":OID}`
/// `nodes`/`edges` must already be sorted by the caller.
pub fn appendStableTopologyJson(
    list: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    nodes: []const StableNode,
    edges: []const StableEdge,
    output_id: u64,
) !void {
    try list.appendSlice(gpa, "{\"nodes\":[");
    for (nodes, 0..) |n, i| {
        if (i != 0) try list.append(gpa, ',');
        var tmp: [128]u8 = undefined;
        const piece = try std.fmt.bufPrint(&tmp, "{{\"id\":{d},\"kind\":\"{s}\",\"x\":{d:.1},\"y\":{d:.1}}}", .{
            n.id.raw(), @tagName(n.kind), n.x, n.y,
        });
        try list.appendSlice(gpa, piece);
    }
    try list.appendSlice(gpa, "],\"edges\":[");
    for (edges, 0..) |e, i| {
        if (i != 0) try list.append(gpa, ',');
        var tmp: [64]u8 = undefined;
        const piece = try std.fmt.bufPrint(&tmp, "[{d},{d},{d},{d}]", .{
            e.src_id.raw(), e.src_out, e.dst_id.raw(), e.dst_in,
        });
        try list.appendSlice(gpa, piece);
    }
    var tail: [48]u8 = undefined;
    const t = try std.fmt.bufPrint(&tail, "],\"output\":{d}}}", .{output_id});
    try list.appendSlice(gpa, t);
}

/// Fixed-buffer version (for digest). If it doesn't fit, truncated=true (partial write).
pub fn formatStableTopologyInto(
    buf: []u8,
    nodes: []const StableNode,
    edges: []const StableEdge,
    output_id: u64,
) struct { len: usize, truncated: bool } {
    var off: usize = 0;
    var truncated = false;
    const head = std.fmt.bufPrint(buf[off..], "{{\"nodes\":[", .{}) catch return .{ .len = 0, .truncated = true };
    off += head.len;
    for (nodes, 0..) |n, i| {
        const sep: []const u8 = if (i == 0) "" else ",";
        const piece = std.fmt.bufPrint(buf[off..], "{s}{{\"id\":{d},\"kind\":\"{s}\",\"x\":{d:.1},\"y\":{d:.1}}}", .{
            sep, n.id.raw(), @tagName(n.kind), n.x, n.y,
        }) catch {
            truncated = true;
            break;
        };
        off += piece.len;
    }
    if (!truncated) {
        const mid = std.fmt.bufPrint(buf[off..], "],\"edges\":[", .{}) catch {
            return .{ .len = off, .truncated = true };
        };
        off += mid.len;
        for (edges, 0..) |e, i| {
            const sep: []const u8 = if (i == 0) "" else ",";
            const piece = std.fmt.bufPrint(buf[off..], "{s}[{d},{d},{d},{d}]", .{
                sep, e.src_id.raw(), e.src_out, e.dst_id.raw(), e.dst_in,
            }) catch {
                truncated = true;
                break;
            };
            off += piece.len;
        }
    }
    if (!truncated) {
        const tail = std.fmt.bufPrint(buf[off..], "],\"output\":{d}}}", .{output_id}) catch {
            return .{ .len = off, .truncated = true };
        };
        off += tail.len;
    }
    return .{ .len = off, .truncated = truncated };
}

/// Little-endian u32 for 'PTCG' (patch graph). Passed to serde's expected_magic.
pub const magic: u32 = @as(u32, 'P') | (@as(u32, 'T') << 8) | (@as(u32, 'C') << 16) | (@as(u32, 'G') << 24);
pub const schema_version: u16 = 1;

const TAG_NODE: [4]u8 = "NODE".*;
const TAG_EDGE: [4]u8 = "EDGE".*;

// NODE payload layout (little-endian, fixed 11B): handle u16 | kind u8(ModuleKind ordinal) | x f32 | y f32
const NODE_SIZE: usize = 11;
// EDGE payload layout (fixed 6B): src_handle u16 | src_out u8 | dst_handle u16 | dst_in u8
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

/// `ModuleKind` is an exhaustive enum, so `@enumFromInt` triggers safety-checked illegal
/// behavior (panic) on out-of-range values. Hand-write the `std.meta.intToEnum` equivalent and check the value against
/// declared tag values before calling `@enumFromInt` (forward compatible: unknown kind ordinals return null and the caller skips them).
fn moduleKindFromU8(v: u8) ?ModuleKind {
    inline for (@typeInfo(ModuleKind).@"enum".fields) |f| {
        if (f.value == v) return @enumFromInt(v);
    }
    return null;
}

/// Assembles nodes/edges into a NODE×N/EDGE×M container (caller frees).
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
    nodes: []NodeEntry, // gpa-allocated (caller frees)
    edges: []EdgeEntry, // gpa-allocated (caller frees)

    pub fn deinit(self: *DecodedGraph, gpa: std.mem.Allocator) void {
        gpa.free(self.nodes);
        gpa.free(self.edges);
    }
};

/// Restores nodes/edges from a byte slice. **NODE entries with an unknown `ModuleKind` (future schema extension) are
/// skipped** (forward compatible; EDGE entries referencing that handle are naturally ignored by main.zig's load
/// logic as "no matching new handle found").
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
            const kind = moduleKindFromU8(chunk.payload[2]) orelse continue; // Unknown kind: skip
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
        // Unknown tags are ignored (the serde iterator returns every chunk; non-matching ones are skipped)
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

test "encode/decode: round-trip nodes + edges (preserves appearance order)" {
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

test "encode/decode: empty graph (0 nodes, 0 edges)" {
    const gpa = testing.allocator;
    const bytes = try encodeGraph(gpa, &.{}, &.{});
    defer gpa.free(bytes);
    var got = try decodeGraph(gpa, bytes);
    defer got.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), got.nodes.len);
    try testing.expectEqual(@as(usize, 0), got.edges.len);
}

test "forward compat: skips NODE with unknown kind and unknown chunk tags" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, schema_version);
    defer w.deinit();
    var buf: [NODE_SIZE]u8 = undefined;
    packNode(.{ .handle = 0, .kind = .vco, .x = 1, .y = 2 }, &buf);
    try w.addChunk(TAG_NODE, &buf);
    // Unknown kind ordinal (a value beyond ModuleKind's tag count)
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
    try testing.expectEqual(@as(usize, 1), got.nodes.len); // Unknown kind is skipped
    try testing.expectEqual(ModuleKind.vco, got.nodes[0].kind);
}

test "backward compat: legacy sidechain(ordinal 25) fixture plus a new kind appended at the end" {
    const gpa = testing.allocator;
    // Legacy fixed byte fixture. NODE(sidechain, ordinal=25) + EDGE.
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

test "corruption detection: UnsupportedSchemaVersion / CorruptNode / CorruptEdge / BadMagic" {
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
    // Fixed cwd names race across parallel test binaries, so isolate with tmpDir.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/graph_io_test.ptcg", .{&tmp.sub_path});

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

test "stable export: matches on a NodeId basis even when runtime handles differ" {
    const gpa = testing.allocator;
    // Same topology, different runtime handles
    const a_nodes = [_]StableNode{
        .{ .id = NodeId.fromRaw(2), .kind = .vcf, .x = 100, .y = 0 },
        .{ .id = NodeId.fromRaw(1), .kind = .vco, .x = 0, .y = 0 },
    };
    const a_edges = [_]StableEdge{
        .{ .src_id = NodeId.fromRaw(1), .src_out = 0, .dst_id = NodeId.fromRaw(2), .dst_in = 0 },
    };
    const b_nodes = [_]StableNode{
        .{ .id = NodeId.fromRaw(1), .kind = .vco, .x = 0, .y = 0 },
        .{ .id = NodeId.fromRaw(2), .kind = .vcf, .x = 100, .y = 0 },
    };
    const b_edges = [_]StableEdge{
        .{ .src_id = NodeId.fromRaw(1), .src_out = 0, .dst_id = NodeId.fromRaw(2), .dst_in = 0 },
    };
    var ga = try canonicalizeStableGraph(gpa, &a_nodes, &a_edges, NodeId.fromRaw(2));
    defer ga.deinit(gpa);
    var gb = try canonicalizeStableGraph(gpa, &b_nodes, &b_edges, NodeId.fromRaw(2));
    defer gb.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), ga.nodes.len);
    try testing.expectEqual(ga.nodes[0].id, gb.nodes[0].id);
    try testing.expectEqual(ga.nodes[1].id, gb.nodes[1].id);
    try testing.expectEqual(ga.edges[0], gb.edges[0]);
    try testing.expectEqual(ga.output_id, gb.output_id);
}

test "stable export: canonical match even with differing input order / fallback numbering" {
    const gpa = testing.allocator;
    const edges_a = [_]StableEdge{
        .{ .src_id = NodeId.fromRaw(2), .src_out = 0, .dst_id = NodeId.fromRaw(3), .dst_in = 1 },
        .{ .src_id = NodeId.fromRaw(1), .src_out = 0, .dst_id = NodeId.fromRaw(2), .dst_in = 0 },
    };
    const edges_b = [_]StableEdge{
        .{ .src_id = NodeId.fromRaw(1), .src_out = 0, .dst_id = NodeId.fromRaw(2), .dst_in = 0 },
        .{ .src_id = NodeId.fromRaw(2), .src_out = 0, .dst_id = NodeId.fromRaw(3), .dst_in = 1 },
    };
    var ga = try canonicalizeStableGraph(gpa, &.{}, &edges_a, null);
    defer ga.deinit(gpa);
    var gb = try canonicalizeStableGraph(gpa, &.{}, &edges_b, null);
    defer gb.deinit(gpa);
    try testing.expectEqualSlices(StableEdge, ga.edges, gb.edges);

    const legacy = [_]NodeEntry{
        .{ .handle = 7, .kind = .vco, .x = 0, .y = 0 },
        .{ .handle = 3, .kind = .output, .x = 1, .y = 1 },
    };
    var ids: [2]NodeId = undefined;
    const next = assignFallbackNodeIds(&legacy, &ids);
    try testing.expectEqual(@as(u64, 1), ids[0].raw());
    try testing.expectEqual(@as(u64, 2), ids[1].raw());
    try testing.expectEqual(@as(u64, 3), next);
}

test "stable topology JSON: ascending id order, kind/x/y, output, trunc" {
    const gpa = testing.allocator;
    const nodes = [_]StableNode{
        .{ .id = NodeId.fromRaw(1), .kind = .vco, .x = 10, .y = 20 },
        .{ .id = NodeId.fromRaw(2), .kind = .output, .x = 100, .y = 0 },
    };
    const edges = [_]StableEdge{
        .{ .src_id = NodeId.fromRaw(1), .src_out = 0, .dst_id = NodeId.fromRaw(2), .dst_in = 0 },
    };
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try appendStableTopologyJson(&list, gpa, &nodes, &edges, 2);
    const full = list.items;
    try testing.expect(std.mem.indexOf(u8, full, "\"id\":1") != null);
    try testing.expect(std.mem.indexOf(u8, full, "\"kind\":\"vco\"") != null);
    try testing.expect(std.mem.indexOf(u8, full, "\"x\":10.0") != null);
    try testing.expect(std.mem.indexOf(u8, full, "[1,0,2,0]") != null);
    try testing.expect(std.mem.endsWith(u8, full, "\"output\":2}"));
    // Does not include camera/fb
    try testing.expect(std.mem.indexOf(u8, full, "camera") == null);
    try testing.expect(std.mem.indexOf(u8, full, "fb") == null);

    // Small buffer → truncated
    var tiny: [32]u8 = undefined;
    const fmt = formatStableTopologyInto(&tiny, &nodes, &edges, 2);
    try testing.expect(fmt.truncated);

    // Sufficiently large buffer → not truncated, bit-identical to the ArrayList version
    var big: [512]u8 = undefined;
    const fmt2 = formatStableTopologyInto(&big, &nodes, &edges, 2);
    try testing.expect(!fmt2.truncated);
    try testing.expectEqualStrings(full, big[0..fmt2.len]);
}

test "stable topology snapshot-sized: JSON stays complete even with many nodes (no trunc)" {
    const gpa = testing.allocator;
    var nodes: [30]StableNode = undefined;
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        nodes[i] = .{
            .id = NodeId.fromRaw(@intCast(i + 1)),
            .kind = .vco,
            .x = @floatFromInt(i),
            .y = 0,
        };
    }
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try appendStableTopologyJson(&list, gpa, &nodes, &.{}, 1);
    try testing.expect(list.items.len > 1024); // Complete even at sizes beyond the digest cap
    try testing.expect(list.items[0] == '{');
    try testing.expect(list.items[list.items.len - 1] == '}');
    try testing.expect(std.mem.indexOf(u8, list.items, "\"id\":30") != null);
    try testing.expect(std.mem.indexOf(u8, list.items, " trunc=") == null);
}
