//! apps/noodle: a Sugiyama-style layered layout for the display graph.
//!
//! Ranks and vertically stacks the display nodes/edges returned by mapNodesForCollapsed / buildDisplayEdges,
//! writing real nodes to layout[handle], collapsed macro boxes to ledger.groups[gid].pos, and making an
//! expanded macro's header track its members' bbox.
//!
//! Hot-path declaration: runs only when the auto_layout / auto_layout_selected action is invoked (event time).
//! It never touches per-frame drawing or the RT path.
//! Pure Zig with no platform / gui / modular imports (only canvas / group). Unit-testable via test-noodle.

const std = @import("std");
const canvas = @import("canvas.zig");
const group = @import("group.zig");

pub const Handle = canvas.Handle;
pub const Vec2f = canvas.Vec2f;
pub const NodeGeom = canvas.NodeGeom;
pub const Edge = canvas.Edge;

/// The world-space origin X and the gap between rank columns: x = 24 + rank * (NODE_W + 40).
pub const ORIGIN_X: f32 = 24;
pub const COL_GAP: f32 = 40;
/// A default starting Y for each rank column, used in tests. At runtime the caller passes a world Y that avoids the palette band.
pub const ORIGIN_Y: f32 = 24;
pub const ROW_GAP: f32 = 24;
/// The margin between an expanded header and the member bbox (margin=10, matching drawExpandedGroupFrame).
pub const EXPANDED_HEADER_MARGIN: f32 = 10;

const MAX_NODES: usize = group.GROUP_HANDLE_BASE + group.MAX_GROUPS;

/// Repositions only the selected display nodes into a simple, topology-agnostic grid.
///
/// - `nodes`: all display nodes (only the targeted ones get pos updated; unselected ones are unchanged)
/// - `target_handles`: the handles to reposition (assumed already matched against the display nodes)
/// - `layout` / `ledger`: write-back is limited to the targets (a synthetic handle writes only to groups[gid].pos)
///
/// A no-op for 0 or 1 targets. `repositionExpandedHeaders` is not called, so unselected headers are not moved.
/// Hot path: only at action invocation time. edges / order_keys are not referenced.
pub fn applySelectedGrid(
    nodes: []NodeGeom,
    target_handles: []const Handle,
    layout: []Vec2f,
    ledger: *group.Ledger,
) void {
    std.debug.assert(layout.len >= group.GROUP_HANDLE_BASE);
    if (target_handles.len == 0) return;

    // Collect target indices (only those whose handle matches within the display nodes)
    var target_idx: [MAX_NODES]u16 = undefined;
    var tn: usize = 0;
    for (nodes, 0..) |ng, i| {
        if (!containsHandle(target_handles, ng.handle)) continue;
        if (tn >= MAX_NODES) break;
        target_idx[tn] = @intCast(i);
        tn += 1;
    }
    if (tn <= 1) return; // 0 matches (not in the display) or 1 match is a no-op

    // anchor = the top-left of the target bbox; max_h is for row bucketing
    var anchor_x: f32 = nodes[target_idx[0]].pos.x;
    var anchor_y: f32 = nodes[target_idx[0]].pos.y;
    var max_h: f32 = canvas.nodeSize(nodes[target_idx[0]]).y;
    var ti: usize = 1;
    while (ti < tn) : (ti += 1) {
        const ng = nodes[target_idx[ti]];
        const sz = canvas.nodeSize(ng);
        anchor_x = @min(anchor_x, ng.pos.x);
        anchor_y = @min(anchor_y, ng.pos.y);
        max_h = @max(max_h, sz.y);
    }
    const row_stride = max_h + ROW_GAP;

    // Deterministic sort: ascending row_bucket -> ascending pos.x -> ascending handle
    const sort_ctx = SelectedSortCtx{
        .nodes = nodes,
        .anchor_y = anchor_y,
        .row_stride = row_stride,
    };
    std.mem.sort(u16, target_idx[0..tn], sort_ctx, SelectedSortCtx.less);

    // cell size = the targets' max width and max height
    var cell_w: f32 = 0;
    var cell_h: f32 = 0;
    ti = 0;
    while (ti < tn) : (ti += 1) {
        const sz = canvas.nodeSize(nodes[target_idx[ti]]);
        cell_w = @max(cell_w, sz.x);
        cell_h = @max(cell_h, sz.y);
    }

    // cols = ceil(sqrt(n)); rows are laid out at roughly ceil(n/cols)
    const cols_f = @ceil(@sqrt(@as(f32, @floatFromInt(tn))));
    const cols: usize = @max(@as(usize, @intFromFloat(cols_f)), 1);

    ti = 0;
    while (ti < tn) : (ti += 1) {
        const col = ti % cols;
        const row = ti / cols;
        const ni = target_idx[ti];
        nodes[ni].pos = .{
            .x = anchor_x + @as(f32, @floatFromInt(col)) * (cell_w + COL_GAP),
            .y = anchor_y + @as(f32, @floatFromInt(row)) * (cell_h + ROW_GAP),
        };
    }

    writeBackTargets(nodes, target_handles, layout, ledger);
}

const SelectedSortCtx = struct {
    nodes: []const NodeGeom,
    anchor_y: f32,
    row_stride: f32,

    fn rowBucket(ctx: SelectedSortCtx, ni: u16) i32 {
        const y = ctx.nodes[ni].pos.y;
        return @intFromFloat(@floor((y - ctx.anchor_y) / ctx.row_stride));
    }

    fn less(ctx: SelectedSortCtx, a: u16, b: u16) bool {
        const ra = ctx.rowBucket(a);
        const rb = ctx.rowBucket(b);
        if (ra != rb) return ra < rb;
        const xa = ctx.nodes[a].pos.x;
        const xb = ctx.nodes[b].pos.x;
        if (xa != xb) return xa < xb;
        return ctx.nodes[a].handle < ctx.nodes[b].handle;
    }
};

fn containsHandle(handles: []const Handle, h: Handle) bool {
    for (handles) |th| {
        if (th == h) return true;
    }
    return false;
}

/// Writes back only the target handles (unselected layout / group.pos entries are untouched).
fn writeBackTargets(
    nodes: []const NodeGeom,
    target_handles: []const Handle,
    layout: []Vec2f,
    ledger: *group.Ledger,
) void {
    for (nodes) |ng| {
        if (!containsHandle(target_handles, ng.handle)) continue;
        if (group.groupIdFromHandle(ng.handle)) |gid| {
            if (gid < group.MAX_GROUPS and ledger.groups[gid].active) {
                ledger.setPosAndTranslateMembers(gid, ng.pos, layout);
            }
        } else if (ng.handle < layout.len) {
            layout[ng.handle] = ng.pos;
        }
    }
}

/// Applies a layered layout to the display graph and writes the result back into layout / ledger.
///
/// - `nodes`: display nodes (pos is updated; the input n_in/n_out/grid_rows are used by nodeSize)
/// - `edges`: display edges (DisplayEdge.visual; feedback edges may be included but are excluded from rank computation)
/// - `order_keys`: parallel to nodes; the DynGraph view.order index (a collapsed group uses its minimum member key)
/// - `layout`: indexed by real handles only (a synthetic handle is never written here)
/// - `ledger`: the write-back target for a collapsed box's pos and an expanded header's pos
/// - `origin_y`: the starting world Y for the rank-0 column (main passes the world-transformed value corresponding to paletteBottom)
///
/// Preconditions: nodes.len == order_keys.len, and layout.len >= GROUP_HANDLE_BASE.
pub fn apply(
    nodes: []NodeGeom,
    edges: []const Edge,
    order_keys: []const u32,
    layout: []Vec2f,
    ledger: *group.Ledger,
    origin_y: f32,
) void {
    std.debug.assert(nodes.len == order_keys.len);
    std.debug.assert(layout.len >= group.GROUP_HANDLE_BASE);
    if (nodes.len == 0) return;

    var ranks: [MAX_NODES]u32 = undefined;
    @memset(ranks[0..nodes.len], 0);

    computeRanks(nodes, edges, order_keys, ranks[0..nodes.len]);
    placeByRank(nodes, edges, order_keys, ranks[0..nodes.len], origin_y);
    writeBack(nodes, layout, ledger);
    repositionExpandedHeaders(nodes, layout, ledger);
}

/// Computes rank using only forward edges where src_key < dst_key.
/// Processes display nodes in ascending order-key order, setting rank[dst] = max(rank[dst], rank[src]+1).
fn computeRanks(
    nodes: []const NodeGeom,
    edges: []const Edge,
    order_keys: []const u32,
    ranks: []u32,
) void {
    const n = nodes.len;
    // Processed in ascending order-key order (the original index is the secondary key, for determinism)
    var order_idx: [MAX_NODES]u16 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) order_idx[i] = @intCast(i);
    std.mem.sort(u16, order_idx[0..n], SortByOrderKey{ .keys = order_keys }, SortByOrderKey.less);

    // handle -> index within nodes (used to resolve edge endpoints; a handle is assumed to appear at most once in the display)
    // A synthetic handle is GROUP_HANDLE_BASE + gid.
    var handle_to_idx: [group.GROUP_HANDLE_BASE + group.MAX_GROUPS]?u16 =
        [_]?u16{null} ** (group.GROUP_HANDLE_BASE + group.MAX_GROUPS);
    i = 0;
    while (i < n) : (i += 1) {
        const h = nodes[i].handle;
        if (h < handle_to_idx.len) handle_to_idx[h] = @intCast(i);
    }

    for (order_idx[0..n]) |si| {
        const src_key = order_keys[si];
        const src_h = nodes[si].handle;
        for (edges) |e| {
            if (e.src_handle != src_h) continue;
            const di_opt = if (e.dst_handle < handle_to_idx.len) handle_to_idx[e.dst_handle] else null;
            const di = di_opt orelse continue;
            const dst_key = order_keys[di];
            if (src_key >= dst_key) continue; // Feedback edges are excluded from rank computation
            ranks[di] = @max(ranks[di], ranks[si] + 1);
        }
    }
}

const SortByOrderKey = struct {
    keys: []const u32,
    fn less(ctx: SortByOrderKey, a: u16, b: u16) bool {
        const ka = ctx.keys[a];
        const kb = ctx.keys[b];
        if (ka != kb) return ka < kb;
        return a < b;
    }
};

/// Fixes coordinates in ascending rank order. Within the same rank, nodes are sorted by average source center-Y, falling back to order key when unavailable.
fn placeByRank(
    nodes: []NodeGeom,
    edges: []const Edge,
    order_keys: []const u32,
    ranks: []const u32,
    origin_y: f32,
) void {
    const n = nodes.len;
    var max_rank: u32 = 0;
    for (ranks[0..n]) |r| max_rank = @max(max_rank, r);

    var handle_to_idx: [group.GROUP_HANDLE_BASE + group.MAX_GROUPS]?u16 =
        [_]?u16{null} ** (group.GROUP_HANDLE_BASE + group.MAX_GROUPS);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const h = nodes[i].handle;
        if (h < handle_to_idx.len) handle_to_idx[h] = @intCast(i);
    }

    var bucket: [MAX_NODES]u16 = undefined;
    var rank_r: u32 = 0;
    while (rank_r <= max_rank) : (rank_r += 1) {
        var bn: usize = 0;
        i = 0;
        while (i < n) : (i += 1) {
            if (ranks[i] == rank_r) {
                bucket[bn] = @intCast(i);
                bn += 1;
            }
        }
        if (bn == 0) continue;

        // The sort key used within the same rank
        var sort_y: [MAX_NODES]f32 = undefined;
        var has_src: [MAX_NODES]bool = undefined;
        var bi: usize = 0;
        while (bi < bn) : (bi += 1) {
            const ni = bucket[bi];
            const avg = averageSourceCenterY(nodes, edges, order_keys, handle_to_idx[0..], ni);
            has_src[ni] = avg != null;
            sort_y[ni] = avg orelse 0;
        }

        const ctx = RankSortCtx{
            .order_keys = order_keys,
            .sort_y = sort_y[0..n],
            .has_src = has_src[0..n],
        };
        std.mem.sort(u16, bucket[0..bn], ctx, RankSortCtx.less);

        // Vertical stacking (each rank column starts at the caller's origin_y)
        var prev_y: f32 = origin_y;
        var prev_h: f32 = 0;
        bi = 0;
        while (bi < bn) : (bi += 1) {
            const ni = bucket[bi];
            const sz = canvas.nodeSize(nodes[ni]);
            const y: f32 = if (bi == 0) origin_y else prev_y + @max(prev_h, sz.y) + ROW_GAP;
            nodes[ni].pos = .{
                .x = ORIGIN_X + @as(f32, @floatFromInt(rank_r)) * (canvas.NODE_W + COL_GAP),
                .y = y,
            };
            prev_y = y;
            prev_h = sz.y;
        }
    }
}

const RankSortCtx = struct {
    order_keys: []const u32,
    sort_y: []const f32,
    has_src: []const bool,

    fn less(ctx: RankSortCtx, a: u16, b: u16) bool {
        // Between two nodes that both have inbound edges: sorted by ascending average_source_y. If only one has inbound edges, it comes first (order is preferred over a y comparison).
        // If neither has inbound edges: order key. The secondary key is always order key.
        const a_has = ctx.has_src[a];
        const b_has = ctx.has_src[b];
        if (a_has and b_has) {
            if (ctx.sort_y[a] != ctx.sort_y[b]) return ctx.sort_y[a] < ctx.sort_y[b];
        } else if (a_has != b_has) {
            // When one side falls back to order key, the comparison switches to order key for determinism.
        }
        const ka = ctx.order_keys[a];
        const kb = ctx.order_keys[b];
        if (ka != kb) return ka < kb;
        return a < b;
    }
};

/// The average center-Y of the rects connected via forward inbound edges. null if there are no inbound edges (falls back to order key).
fn averageSourceCenterY(
    nodes: []const NodeGeom,
    edges: []const Edge,
    order_keys: []const u32,
    handle_to_idx: []const ?u16,
    dst_i: usize,
) ?f32 {
    const dst_h = nodes[dst_i].handle;
    const dst_key = order_keys[dst_i];
    var sum: f32 = 0;
    var count: u32 = 0;
    for (edges) |e| {
        if (e.dst_handle != dst_h) continue;
        const si_opt = if (e.src_handle < handle_to_idx.len) handle_to_idx[e.src_handle] else null;
        const si = si_opt orelse continue;
        const src_key = order_keys[si];
        if (src_key >= dst_key) continue; // Feedback edges are also excluded from the sort reference
        const src = nodes[si];
        const sz = canvas.nodeSize(src);
        sum += src.pos.y + sz.y * 0.5;
        count += 1;
    }
    if (count == 0) return null;
    return sum / @as(f32, @floatFromInt(count));
}

/// A real node writes to layout[handle]; a synthetic handle writes to groups[gid].pos
/// (and translates collapsed members by the same delta). A synthetic handle is never used to index layout.
fn writeBack(nodes: []const NodeGeom, layout: []Vec2f, ledger: *group.Ledger) void {
    for (nodes) |ng| {
        if (group.groupIdFromHandle(ng.handle)) |gid| {
            if (gid < group.MAX_GROUPS and ledger.groups[gid].active) {
                ledger.setPosAndTranslateMembers(gid, ng.pos, layout);
            }
        } else if (ng.handle < layout.len) {
            layout[ng.handle] = ng.pos;
        }
    }
}

/// Makes an expanded group's header track above the members' bbox after repositioning (margin=10).
/// A group with no members is left unchanged. A collapsed group is out of scope (its box is already placed as a display node).
fn repositionExpandedHeaders(nodes: []const NodeGeom, layout: []const Vec2f, ledger: *group.Ledger) void {
    _ = layout; // Member coordinates are taken from the nodes side, which is already placed before writeBack
    var gi: group.GroupId = 0;
    while (gi < group.MAX_GROUPS) : (gi += 1) {
        const g = &ledger.groups[gi];
        if (!g.active or g.collapsed) continue;

        var bbox_min = Vec2f{ .x = std.math.floatMax(f32), .y = std.math.floatMax(f32) };
        var any = false;

        // Enumerates the real nodes where group_of[h]==gid, taking nodeSize from the NodeGeom of the members present in the display.
        for (ledger.group_of, 0..) |go, h| {
            if (go == null or go.? != gi) continue;
            const ng = findNode(nodes, @intCast(h)) orelse continue;
            any = true;
            bbox_min.x = @min(bbox_min.x, ng.pos.x);
            bbox_min.y = @min(bbox_min.y, ng.pos.y);
        }
        if (!any) continue;

        const header = NodeGeom{
            .handle = group.handleOfGroup(gi),
            .pos = .{ .x = 0, .y = 0 },
            .n_in = 0,
            .n_out = 0,
        };
        const header_h = canvas.nodeSize(header).y;
        g.pos = .{
            .x = bbox_min.x,
            .y = bbox_min.y - header_h - EXPANDED_HEADER_MARGIN,
        };
    }
}

fn findNode(nodes: []const NodeGeom, h: Handle) ?NodeGeom {
    for (nodes) |ng| {
        if (ng.handle == h) return ng;
    }
    return null;
}

// ============================================================================
// tests (no display/audio needed; test-noodle)
// ============================================================================
const testing = std.testing;

fn rectsOverlap(a: NodeGeom, b: NodeGeom) bool {
    const as = canvas.nodeSize(a);
    const bs = canvas.nodeSize(b);
    if (a.pos.x + as.x <= b.pos.x or b.pos.x + bs.x <= a.pos.x) return false;
    if (a.pos.y + as.y <= b.pos.y or b.pos.y + bs.y <= a.pos.y) return false;
    return true;
}

fn isFinitePos(p: Vec2f) bool {
    return std.math.isFinite(p.x) and std.math.isFinite(p.y);
}

test "layout: empty graph does not panic" {
    var layout_arr = [_]Vec2f{.{ .x = 0, .y = 0 }} ** group.GROUP_HANDLE_BASE;
    var ledger: group.Ledger = .{};
    apply(&.{}, &.{}, &.{}, &layout_arr, &ledger, ORIGIN_Y);
}

test "layout: single node places at finite origin column" {
    var nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 999, .y = 999 }, .n_in = 0, .n_out = 1 },
    };
    const keys = [_]u32{0};
    var layout_arr = [_]Vec2f{.{ .x = 0, .y = 0 }} ** group.GROUP_HANDLE_BASE;
    var ledger: group.Ledger = .{};
    apply(&nodes, &.{}, &keys, &layout_arr, &ledger, ORIGIN_Y);
    try testing.expect(isFinitePos(nodes[0].pos));
    try testing.expectApproxEqAbs(ORIGIN_X, nodes[0].pos.x, 1e-4);
    try testing.expectApproxEqAbs(ORIGIN_Y, nodes[0].pos.y, 1e-4);
    try testing.expectApproxEqAbs(nodes[0].pos.x, layout_arr[0].x, 1e-4);
    try testing.expectApproxEqAbs(nodes[0].pos.y, layout_arr[0].y, 1e-4);
}

test "layout: branch-join DAG no overlap and forward edges increase x" {
    // A(0) -> B(1), A -> C(2), B -> D(3), C -> D. order key = handle.
    var nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1 },
        .{ .handle = 2, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1 },
        .{ .handle = 3, .pos = .{ .x = 0, .y = 0 }, .n_in = 2, .n_out = 0 },
    };
    const keys = [_]u32{ 0, 1, 2, 3 };
    const edges = [_]Edge{
        .{ .src_handle = 0, .src_out = 0, .dst_handle = 1, .dst_in = 0 },
        .{ .src_handle = 0, .src_out = 0, .dst_handle = 2, .dst_in = 0 },
        .{ .src_handle = 1, .src_out = 0, .dst_handle = 3, .dst_in = 0 },
        .{ .src_handle = 2, .src_out = 0, .dst_handle = 3, .dst_in = 1 },
    };
    var layout_arr = [_]Vec2f{.{ .x = 0, .y = 0 }} ** group.GROUP_HANDLE_BASE;
    var ledger: group.Ledger = .{};
    apply(&nodes, &edges, &keys, &layout_arr, &ledger, ORIGIN_Y);

    // No rects overlap
    var i: usize = 0;
    while (i < nodes.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < nodes.len) : (j += 1) {
            try testing.expect(!rectsOverlap(nodes[i], nodes[j]));
        }
    }
    // A forward edge satisfies x(src) < x(dst)
    for (edges) |e| {
        const s = findNode(&nodes, e.src_handle).?;
        const d = findNode(&nodes, e.dst_handle).?;
        try testing.expect(s.pos.x < d.pos.x);
    }
    // rank0 contains only A
    try testing.expectApproxEqAbs(ORIGIN_X, nodes[0].pos.x, 1e-4);
}

test "layout: rank0 nodes ordered by order key" {
    // 3 disconnected nodes. order key 2,0,1 -> Y follows ascending key order: 0,1,2.
    var nodes = [_]NodeGeom{
        .{ .handle = 10, .pos = .{ .x = 0, .y = 0 }, .n_in = 0, .n_out = 0 },
        .{ .handle = 11, .pos = .{ .x = 0, .y = 0 }, .n_in = 0, .n_out = 0 },
        .{ .handle = 12, .pos = .{ .x = 0, .y = 0 }, .n_in = 0, .n_out = 0 },
    };
    const keys = [_]u32{ 2, 0, 1 };
    var layout_arr = [_]Vec2f{.{ .x = 0, .y = 0 }} ** group.GROUP_HANDLE_BASE;
    var ledger: group.Ledger = .{};
    apply(&nodes, &.{}, &keys, &layout_arr, &ledger, ORIGIN_Y);
    // key0 = handle 11, key1 = handle 12, key2 = handle 10
    try testing.expect(nodes[1].pos.y < nodes[2].pos.y);
    try testing.expect(nodes[2].pos.y < nodes[0].pos.y);
}

test "layout: cycle A-B-C-A finishes with finite positions and keeps feedback edge input" {
    // A->B->C->A. order key 0,1,2. forward: A->B, B->C. feedback: C->A is excluded from rank.
    var nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 50, .y = 50 }, .n_in = 1, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 50, .y = 50 }, .n_in = 1, .n_out = 1 },
        .{ .handle = 2, .pos = .{ .x = 50, .y = 50 }, .n_in = 1, .n_out = 1 },
    };
    const keys = [_]u32{ 0, 1, 2 };
    const edges = [_]Edge{
        .{ .src_handle = 0, .src_out = 0, .dst_handle = 1, .dst_in = 0 },
        .{ .src_handle = 1, .src_out = 0, .dst_handle = 2, .dst_in = 0 },
        .{ .src_handle = 2, .src_out = 0, .dst_handle = 0, .dst_in = 0 }, // feedback
    };
    var layout_arr = [_]Vec2f{.{ .x = 0, .y = 0 }} ** group.GROUP_HANDLE_BASE;
    var ledger: group.Ledger = .{};
    apply(&nodes, &edges, &keys, &layout_arr, &ledger, ORIGIN_Y);

    for (nodes) |ng| try testing.expect(isFinitePos(ng.pos));
    // Forward edges are monotonic in x
    try testing.expect(nodes[0].pos.x < nodes[1].pos.x);
    try testing.expect(nodes[1].pos.x < nodes[2].pos.x);
    // The input edges are unchanged (layout never rewrites edges; the caller keeps them for display)
    try testing.expectEqual(@as(Handle, 2), edges[2].src_handle);
    try testing.expectEqual(@as(Handle, 0), edges[2].dst_handle);
}

test "layout: collapsed synthetic group is one node and translates member layout" {
    const gid: group.GroupId = 0;
    const box_h = group.handleOfGroup(gid);
    // external 0 -> box, box -> external 1. The box's order key is the minimum member key, 5 (member handles are 5,6 but are hidden)
    var nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 0, .n_out = 1 },
        .{ .handle = box_h, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1, .grid_rows = 2 },
        .{ .handle = 1, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 0 },
    };
    const keys = [_]u32{ 0, 5, 10 };
    const edges = [_]Edge{
        .{ .src_handle = 0, .src_out = 0, .dst_handle = box_h, .dst_in = 0 },
        .{ .src_handle = box_h, .src_out = 0, .dst_handle = 1, .dst_in = 0 },
    };
    var layout_arr = [_]Vec2f{.{ .x = 42, .y = 42 }} ** group.GROUP_HANDLE_BASE;
    // layout has no slot for synthetic handles (its length is GROUP_HANDLE_BASE); it is left untouched as a sentinel array.
    var ledger: group.Ledger = .{};
    ledger.groups[gid] = .{
        .active = true,
        .collapsed = true,
        .pos = .{ .x = -1, .y = -1 },
        .kind = .drum_machine,
    };
    // Member registration (simulating order-key construction; layout itself does not display members)
    ledger.assign(5, gid);
    ledger.assign(6, gid);

    apply(&nodes, &edges, &keys, &layout_arr, &ledger, ORIGIN_Y);

    try testing.expect(isFinitePos(ledger.groups[gid].pos));
    try testing.expectApproxEqAbs(nodes[1].pos.x, ledger.groups[gid].pos.x, 1e-4);
    try testing.expectApproxEqAbs(nodes[1].pos.y, ledger.groups[gid].pos.y, 1e-4);
    // Real nodes are written into layout
    try testing.expectApproxEqAbs(nodes[0].pos.x, layout_arr[0].x, 1e-4);
    try testing.expectApproxEqAbs(nodes[2].pos.x, layout_arr[1].x, 1e-4);
    // Member layout slots follow the box by the same delta (old box (-1,-1) -> laid out (184,24)).
    try testing.expectApproxEqAbs(@as(f32, 227), layout_arr[5].x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 67), layout_arr[5].y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 227), layout_arr[6].x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 67), layout_arr[6].y, 1e-4);
    // Monotonic in x for forward edges
    try testing.expect(nodes[0].pos.x < nodes[1].pos.x);
    try testing.expect(nodes[1].pos.x < nodes[2].pos.x);
}

test "layout: auto-layout keeps collapsed members aligned after expansion" {
    const gid: group.GroupId = 0;
    const box_h = group.handleOfGroup(gid);
    var nodes = [_]NodeGeom{
        .{ .handle = box_h, .pos = .{ .x = 300, .y = 200 }, .n_in = 1, .n_out = 1, .grid_rows = 2 },
    };
    var layout_arr = [_]Vec2f{.{ .x = 0, .y = 0 }} ** group.GROUP_HANDLE_BASE;
    layout_arr[5] = .{ .x = 325, .y = 280 };
    layout_arr[6] = .{ .x = 500, .y = 390 };
    var ledger: group.Ledger = .{};
    ledger.groups[gid] = .{
        .active = true,
        .collapsed = true,
        .kind = .drum_machine,
        .pos = .{ .x = 300, .y = 200 },
    };
    ledger.assign(5, gid);
    ledger.assign(6, gid);

    apply(&nodes, &.{}, &.{0}, layout_arr[0..], &ledger, ORIGIN_Y);

    try testing.expectApproxEqAbs(@as(f32, 24), ledger.groups[gid].pos.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 24), ledger.groups[gid].pos.y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 49), layout_arr[5].x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 104), layout_arr[5].y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 224), layout_arr[6].x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 214), layout_arr[6].y, 1e-4);

    ledger.groups[gid].collapsed = false;
    const flat = [_]NodeGeom{
        .{ .handle = 5, .pos = layout_arr[5], .n_in = 0, .n_out = 0 },
        .{ .handle = 6, .pos = layout_arr[6], .n_in = 0, .n_out = 0 },
    };
    var expanded: [2]NodeGeom = undefined;
    const n = ledger.mapNodesForCollapsed(&flat, &expanded);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectApproxEqAbs(@as(f32, 49), expanded[0].pos.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 104), expanded[0].pos.y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 224), expanded[1].pos.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 214), expanded[1].pos.y, 1e-4);
}

test "layout: synthetic handle never indexes layout array" {
    const gid: group.GroupId = 1;
    const box_h = group.handleOfGroup(gid);
    var nodes = [_]NodeGeom{
        .{ .handle = box_h, .pos = .{ .x = 0, .y = 0 }, .n_in = 0, .n_out = 0, .grid_rows = 2 },
    };
    const keys = [_]u32{0};
    var layout_arr = [_]Vec2f{.{ .x = 7, .y = 7 }} ** group.GROUP_HANDLE_BASE;
    const before = layout_arr;
    var ledger: group.Ledger = .{};
    ledger.groups[gid] = .{ .active = true, .collapsed = true, .pos = .{ .x = 0, .y = 0 } };

    apply(&nodes, &.{}, &keys, &layout_arr, &ledger, ORIGIN_Y);

    // Every layout slot is unchanged (a synthetic handle is never used to index it)
    for (before, layout_arr) |b, a| {
        try testing.expectEqual(b.x, a.x);
        try testing.expectEqual(b.y, a.y);
    }
    try testing.expectApproxEqAbs(nodes[0].pos.x, ledger.groups[gid].pos.x, 1e-4);
}

test "layout: expanded group header follows member bbox without overlap" {
    const gid: group.GroupId = 0;
    // member 10 -> 11. Since it is expanded, both are display nodes. The header is groups[gid].pos.
    var nodes = [_]NodeGeom{
        .{ .handle = 10, .pos = .{ .x = 0, .y = 0 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 11, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 0 },
    };
    const keys = [_]u32{ 0, 1 };
    const edges = [_]Edge{
        .{ .src_handle = 10, .src_out = 0, .dst_handle = 11, .dst_in = 0 },
    };
    var layout_arr = [_]Vec2f{.{ .x = 0, .y = 0 }} ** group.GROUP_HANDLE_BASE;
    var ledger: group.Ledger = .{};
    ledger.groups[gid] = .{
        .active = true,
        .collapsed = false,
        .pos = .{ .x = 500, .y = 500 },
        .kind = .drum_machine,
    };
    ledger.assign(10, gid);
    ledger.assign(11, gid);

    apply(&nodes, &edges, &keys, &layout_arr, &ledger, ORIGIN_Y);

    // Members go into layout
    try testing.expectApproxEqAbs(nodes[0].pos.x, layout_arr[10].x, 1e-4);
    try testing.expectApproxEqAbs(nodes[1].pos.x, layout_arr[11].x, 1e-4);

    // The header sits above the top of the bbox
    var bbox_min_y = nodes[0].pos.y;
    bbox_min_y = @min(bbox_min_y, nodes[1].pos.y);
    var bbox_min_x = nodes[0].pos.x;
    bbox_min_x = @min(bbox_min_x, nodes[1].pos.x);
    const header = NodeGeom{ .handle = group.handleOfGroup(gid), .pos = ledger.groups[gid].pos, .n_in = 0, .n_out = 0 };
    const header_h = canvas.nodeSize(header).y;
    try testing.expectApproxEqAbs(bbox_min_x, ledger.groups[gid].pos.x, 1e-4);
    try testing.expectApproxEqAbs(bbox_min_y - header_h - EXPANDED_HEADER_MARGIN, ledger.groups[gid].pos.y, 1e-4);

    // The header rect and the members do not overlap
    const hsz = canvas.nodeSize(header);
    for (nodes) |ng| {
        const msz = canvas.nodeSize(ng);
        const overlap = !(header.pos.x + hsz.x <= ng.pos.x or
            ng.pos.x + msz.x <= header.pos.x or
            header.pos.y + hsz.y <= ng.pos.y or
            ng.pos.y + msz.y <= header.pos.y);
        try testing.expect(!overlap);
    }
}

test "layout: real node vs group writeback separation" {
    const gid: group.GroupId = 2;
    const box_h = group.handleOfGroup(gid);
    var nodes = [_]NodeGeom{
        .{ .handle = 3, .pos = .{ .x = 1, .y = 1 }, .n_in = 0, .n_out = 1 },
        .{ .handle = box_h, .pos = .{ .x = 2, .y = 2 }, .n_in = 1, .n_out = 0, .grid_rows = 2 },
    };
    const keys = [_]u32{ 0, 1 };
    const edges = [_]Edge{
        .{ .src_handle = 3, .src_out = 0, .dst_handle = box_h, .dst_in = 0 },
    };
    var layout_arr = [_]Vec2f{.{ .x = 9, .y = 9 }} ** group.GROUP_HANDLE_BASE;
    var ledger: group.Ledger = .{};
    ledger.groups[gid] = .{ .active = true, .collapsed = true, .pos = .{ .x = 0, .y = 0 } };

    apply(&nodes, &edges, &keys, &layout_arr, &ledger, ORIGIN_Y);

    // Real node 3 -> layout[3]
    try testing.expectApproxEqAbs(nodes[0].pos.x, layout_arr[3].x, 1e-4);
    try testing.expectApproxEqAbs(nodes[0].pos.y, layout_arr[3].y, 1e-4);
    // The box writes only to group.pos (all other layout slots, other than handle 3, remain at 9,9)
    try testing.expectApproxEqAbs(nodes[1].pos.x, ledger.groups[gid].pos.x, 1e-4);
    try testing.expectApproxEqAbs(layout_arr[0].x, 9, 1e-4);
    try testing.expectApproxEqAbs(layout_arr[4].x, 9, 1e-4);
}

test "layout: caller origin_y is used as rank0 top Y" {
    // When main passes a large world Y corresponding to paletteBottom, rank0's start matches that value.
    const caller_origin_y: f32 = 100;
    var nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 0 },
    };
    const keys = [_]u32{ 0, 1 };
    const edges = [_]Edge{
        .{ .src_handle = 0, .src_out = 0, .dst_handle = 1, .dst_in = 0 },
    };
    var layout_arr = [_]Vec2f{.{ .x = 0, .y = 0 }} ** group.GROUP_HANDLE_BASE;
    var ledger: group.Ledger = .{};
    apply(&nodes, &edges, &keys, &layout_arr, &ledger, caller_origin_y);

    try testing.expectApproxEqAbs(caller_origin_y, nodes[0].pos.y, 1e-4);
    // rank1 also starts vertical stacking from the same origin_y (with a single node column, its start equals origin_y)
    try testing.expectApproxEqAbs(caller_origin_y, nodes[1].pos.y, 1e-4);
    try testing.expect(nodes[0].pos.y >= caller_origin_y);
    try testing.expect(nodes[1].pos.y >= caller_origin_y);
}

// ============================================================================
// applySelectedGrid
// ============================================================================

test "layout selected: empty targets leave nodes/layout/ledger unchanged" {
    var nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 10, .y = 20 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 30, .y = 40 }, .n_in = 1, .n_out = 0 },
    };
    var layout_arr = [_]Vec2f{.{ .x = 1, .y = 2 }} ** group.GROUP_HANDLE_BASE;
    layout_arr[0] = .{ .x = 10, .y = 20 };
    layout_arr[1] = .{ .x = 30, .y = 40 };
    var ledger: group.Ledger = .{};
    ledger.groups[0] = .{ .active = true, .collapsed = true, .pos = .{ .x = 99, .y = 88 } };
    const nodes_before = nodes;
    const layout_before = layout_arr;
    const gpos_before = ledger.groups[0].pos;

    applySelectedGrid(&nodes, &.{}, &layout_arr, &ledger);

    try testing.expectEqual(nodes_before[0].pos.x, nodes[0].pos.x);
    try testing.expectEqual(nodes_before[0].pos.y, nodes[0].pos.y);
    try testing.expectEqual(nodes_before[1].pos.x, nodes[1].pos.x);
    try testing.expectEqual(nodes_before[1].pos.y, nodes[1].pos.y);
    try testing.expectEqual(layout_before[0].x, layout_arr[0].x);
    try testing.expectEqual(layout_before[1].y, layout_arr[1].y);
    try testing.expectEqual(gpos_before.x, ledger.groups[0].pos.x);
    try testing.expectEqual(gpos_before.y, ledger.groups[0].pos.y);
}

test "layout selected: single target is no-op" {
    var nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 55, .y = 66 }, .n_in = 0, .n_out = 0 },
        .{ .handle = 1, .pos = .{ .x = 100, .y = 200 }, .n_in = 0, .n_out = 0 },
    };
    var layout_arr = [_]Vec2f{.{ .x = 0, .y = 0 }} ** group.GROUP_HANDLE_BASE;
    layout_arr[0] = .{ .x = 55, .y = 66 };
    layout_arr[1] = .{ .x = 100, .y = 200 };
    var ledger: group.Ledger = .{};
    const pos0 = nodes[0].pos;
    const pos1 = nodes[1].pos;

    applySelectedGrid(&nodes, &.{0}, &layout_arr, &ledger);

    try testing.expectApproxEqAbs(pos0.x, nodes[0].pos.x, 1e-4);
    try testing.expectApproxEqAbs(pos0.y, nodes[0].pos.y, 1e-4);
    try testing.expectApproxEqAbs(pos1.x, nodes[1].pos.x, 1e-4);
    try testing.expectApproxEqAbs(pos1.y, nodes[1].pos.y, 1e-4);
    try testing.expectApproxEqAbs(55, layout_arr[0].x, 1e-4);
    try testing.expectApproxEqAbs(100, layout_arr[1].x, 1e-4);
}

test "layout selected: multi grid keeps anchor, max cell size, and gaps" {
    // 3 selected + 1 unselected. cols = ceil(sqrt(3)) = 2.
    // positions: A(100,50), B(180,55), C(120,200) -> anchor=(100,50)
    var nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 100, .y = 50 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 180, .y = 55 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 2, .pos = .{ .x = 120, .y = 200 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 3, .pos = .{ .x = 900, .y = 900 }, .n_in = 0, .n_out = 0 }, // unselected
    };
    var layout_arr = [_]Vec2f{.{ .x = 0, .y = 0 }} ** group.GROUP_HANDLE_BASE;
    var ledger: group.Ledger = .{};
    const unsel_before = nodes[3].pos;
    layout_arr[3] = unsel_before;

    applySelectedGrid(&nodes, &.{ 0, 1, 2 }, &layout_arr, &ledger);

    const cell_w = canvas.NODE_W; // All nodes have the same width
    const cell_h = canvas.nodeSize(nodes[0]).y; // n_out=1 gives the same height
    // After sorting: row0 is A then B, row1 is C -> placement index 0=A, 1=B, 2=C
    try testing.expectApproxEqAbs(100, nodes[0].pos.x, 1e-4);
    try testing.expectApproxEqAbs(50, nodes[0].pos.y, 1e-4);
    try testing.expectApproxEqAbs(100 + cell_w + COL_GAP, nodes[1].pos.x, 1e-4);
    try testing.expectApproxEqAbs(50, nodes[1].pos.y, 1e-4);
    try testing.expectApproxEqAbs(100, nodes[2].pos.x, 1e-4);
    try testing.expectApproxEqAbs(50 + cell_h + ROW_GAP, nodes[2].pos.y, 1e-4);
    // Written back into layout
    try testing.expectApproxEqAbs(nodes[0].pos.x, layout_arr[0].x, 1e-4);
    try testing.expectApproxEqAbs(nodes[1].pos.x, layout_arr[1].x, 1e-4);
    try testing.expectApproxEqAbs(nodes[2].pos.y, layout_arr[2].y, 1e-4);
    // The unselected node is unchanged
    try testing.expectApproxEqAbs(unsel_before.x, nodes[3].pos.x, 1e-4);
    try testing.expectApproxEqAbs(unsel_before.y, nodes[3].pos.y, 1e-4);
    try testing.expectApproxEqAbs(unsel_before.x, layout_arr[3].x, 1e-4);
}

test "layout selected: sort order is row_bucket then x then handle" {
    // Within the same row bucket: ties in x are broken by ascending handle. A Y difference under row_stride puts nodes in the same bucket.
    var nodes = [_]NodeGeom{
        .{ .handle = 5, .pos = .{ .x = 200, .y = 10 }, .n_in = 0, .n_out = 0 },
        .{ .handle = 3, .pos = .{ .x = 100, .y = 12 }, .n_in = 0, .n_out = 0 },
        .{ .handle = 7, .pos = .{ .x = 100, .y = 11 }, .n_in = 0, .n_out = 0 }, // same x as 3, higher handle
        .{ .handle = 1, .pos = .{ .x = 50, .y = 300 }, .n_in = 0, .n_out = 0 }, // lower row bucket later → row1
    };
    var layout_arr = [_]Vec2f{.{ .x = 0, .y = 0 }} ** group.GROUP_HANDLE_BASE;
    var ledger: group.Ledger = .{};

    applySelectedGrid(&nodes, &.{ 5, 3, 7, 1 }, &layout_arr, &ledger);

    // cols = ceil(sqrt(4)) = 2. row0: handle3 (x=100), handle7 (x=100,h>3), handle5 (x=200)
    // wait: sort is x then handle. So row0: (100,h3), (100,h7), (200,h5) — that's 3 in row0 before
    // row_bucket for h1 is higher so it goes last.
    // With 4 items and cols=2: index0=h3, index1=h7, index2=h5, index3=h1
    const cell_w = canvas.NODE_W;
    const cell_h = canvas.nodeSize(nodes[1]).y; // any — same size
    const ax: f32 = 50; // min x is h1's 50... wait min of ALL targets
    // anchor_x = min(50,100,100,200)=50, anchor_y=min(10,12,11,300)=10
    try testing.expectApproxEqAbs(50, nodes[1].pos.x, 1e-3); // handle 3 at index 0?
    // Actually after sort order of indices by (bucket,x,handle):
    // h3: bucket0, x100
    // h7: bucket0, x100
    // h5: bucket0, x200
    // h1: bucket for y=300
    // Place:
    // [0]=h3 at (50, 10)
    // [1]=h7 at (50+cell_w+COL_GAP, 10)
    // [2]=h5 at (50, 10+cell_h+ROW_GAP)
    // [3]=h1 at (50+cell_w+COL_GAP, 10+cell_h+ROW_GAP)
    _ = ax;
    try testing.expectApproxEqAbs(50, findNode(&nodes, 3).?.pos.x, 1e-3);
    try testing.expectApproxEqAbs(10, findNode(&nodes, 3).?.pos.y, 1e-3);
    try testing.expectApproxEqAbs(50 + cell_w + COL_GAP, findNode(&nodes, 7).?.pos.x, 1e-3);
    try testing.expectApproxEqAbs(10, findNode(&nodes, 7).?.pos.y, 1e-3);
    try testing.expectApproxEqAbs(50, findNode(&nodes, 5).?.pos.x, 1e-3);
    try testing.expectApproxEqAbs(10 + cell_h + ROW_GAP, findNode(&nodes, 5).?.pos.y, 1e-3);
    try testing.expectApproxEqAbs(50 + cell_w + COL_GAP, findNode(&nodes, 1).?.pos.x, 1e-3);
    try testing.expectApproxEqAbs(10 + cell_h + ROW_GAP, findNode(&nodes, 1).?.pos.y, 1e-3);
}

test "layout selected: unselected node and layout sentinel stay fixed" {
    var nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 0, .n_out = 0 },
        .{ .handle = 1, .pos = .{ .x = 200, .y = 0 }, .n_in = 0, .n_out = 0 },
        .{ .handle = 2, .pos = .{ .x = 400, .y = 400 }, .n_in = 0, .n_out = 0 },
    };
    var layout_arr = [_]Vec2f{.{ .x = 77, .y = 88 }} ** group.GROUP_HANDLE_BASE;
    layout_arr[0] = .{ .x = 0, .y = 0 };
    layout_arr[1] = .{ .x = 200, .y = 0 };
    layout_arr[2] = .{ .x = 400, .y = 400 };
    const sentinel = layout_arr[10];
    var ledger: group.Ledger = .{};

    applySelectedGrid(&nodes, &.{ 0, 1 }, &layout_arr, &ledger);

    try testing.expectApproxEqAbs(400, nodes[2].pos.x, 1e-4);
    try testing.expectApproxEqAbs(400, nodes[2].pos.y, 1e-4);
    try testing.expectApproxEqAbs(400, layout_arr[2].x, 1e-4);
    try testing.expectApproxEqAbs(sentinel.x, layout_arr[10].x, 1e-4);
    try testing.expectApproxEqAbs(sentinel.y, layout_arr[10].y, 1e-4);
}

test "layout selected: real node vs collapsed group writeback separation" {
    const gid: group.GroupId = 1;
    const box_h = group.handleOfGroup(gid);
    var nodes = [_]NodeGeom{
        .{ .handle = 4, .pos = .{ .x = 10, .y = 20 }, .n_in = 0, .n_out = 1 },
        .{ .handle = box_h, .pos = .{ .x = 300, .y = 20 }, .n_in = 1, .n_out = 0, .grid_rows = 2 },
        .{ .handle = 8, .pos = .{ .x = 800, .y = 800 }, .n_in = 0, .n_out = 0 },
    };
    var layout_arr = [_]Vec2f{.{ .x = 5, .y = 5 }} ** group.GROUP_HANDLE_BASE;
    layout_arr[4] = .{ .x = 10, .y = 20 };
    layout_arr[8] = .{ .x = 800, .y = 800 };
    var ledger: group.Ledger = .{};
    ledger.groups[gid] = .{ .active = true, .collapsed = true, .pos = .{ .x = 300, .y = 20 } };
    const layout8_before = layout_arr[8];
    const layout0_before = layout_arr[0];

    applySelectedGrid(&nodes, &.{ 4, box_h }, &layout_arr, &ledger);

    try testing.expectApproxEqAbs(nodes[0].pos.x, layout_arr[4].x, 1e-4);
    try testing.expectApproxEqAbs(nodes[0].pos.y, layout_arr[4].y, 1e-4);
    try testing.expectApproxEqAbs(nodes[1].pos.x, ledger.groups[gid].pos.x, 1e-4);
    try testing.expectApproxEqAbs(nodes[1].pos.y, ledger.groups[gid].pos.y, 1e-4);
    // Unselected real handles and unrelated slots are unchanged
    try testing.expectApproxEqAbs(layout8_before.x, layout_arr[8].x, 1e-4);
    try testing.expectApproxEqAbs(layout0_before.x, layout_arr[0].x, 1e-4);
    try testing.expectApproxEqAbs(800, nodes[2].pos.x, 1e-4);
}

test "layout selected: synthetic handle never mutates layout array" {
    const gid: group.GroupId = 0;
    const box_h = group.handleOfGroup(gid);
    var nodes = [_]NodeGeom{
        .{ .handle = box_h, .pos = .{ .x = 0, .y = 0 }, .n_in = 0, .n_out = 0, .grid_rows = 2 },
        .{ .handle = group.handleOfGroup(1), .pos = .{ .x = 200, .y = 0 }, .n_in = 0, .n_out = 0, .grid_rows = 2 },
    };
    var layout_arr = [_]Vec2f{.{ .x = 3, .y = 4 }} ** group.GROUP_HANDLE_BASE;
    const before = layout_arr;
    var ledger: group.Ledger = .{};
    ledger.groups[0] = .{ .active = true, .collapsed = true, .pos = .{ .x = 0, .y = 0 } };
    ledger.groups[1] = .{ .active = true, .collapsed = true, .pos = .{ .x = 200, .y = 0 } };

    applySelectedGrid(&nodes, &.{ box_h, group.handleOfGroup(1) }, &layout_arr, &ledger);

    for (before, layout_arr) |b, a| {
        try testing.expectEqual(b.x, a.x);
        try testing.expectEqual(b.y, a.y);
    }
    try testing.expectApproxEqAbs(nodes[0].pos.x, ledger.groups[0].pos.x, 1e-4);
    try testing.expectApproxEqAbs(nodes[1].pos.x, ledger.groups[1].pos.x, 1e-4);
}

test "layout selected: moving expanded members leaves unselected header unchanged" {
    const gid: group.GroupId = 0;
    var nodes = [_]NodeGeom{
        .{ .handle = 10, .pos = .{ .x = 100, .y = 100 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 11, .pos = .{ .x = 250, .y = 100 }, .n_in = 1, .n_out = 0 },
        .{ .handle = 20, .pos = .{ .x = 500, .y = 500 }, .n_in = 0, .n_out = 0 }, // unselected outside
    };
    var layout_arr = [_]Vec2f{.{ .x = 0, .y = 0 }} ** group.GROUP_HANDLE_BASE;
    var ledger: group.Ledger = .{};
    const header_before = Vec2f{ .x = 90, .y = 60 };
    ledger.groups[gid] = .{
        .active = true,
        .collapsed = false,
        .pos = header_before,
        .kind = .drum_machine,
    };
    ledger.assign(10, gid);
    ledger.assign(11, gid);

    applySelectedGrid(&nodes, &.{ 10, 11 }, &layout_arr, &ledger);

    // repositionExpandedHeaders is not called, so the header is unchanged
    try testing.expectApproxEqAbs(header_before.x, ledger.groups[gid].pos.x, 1e-4);
    try testing.expectApproxEqAbs(header_before.y, ledger.groups[gid].pos.y, 1e-4);
    try testing.expectApproxEqAbs(500, nodes[2].pos.x, 1e-4);
    try testing.expectApproxEqAbs(500, nodes[2].pos.y, 1e-4);
}

test "layout selected: selected rectangles do not overlap" {
    var nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 0, .n_out = 3 },
        .{ .handle = 1, .pos = .{ .x = 5, .y = 5 }, .n_in = 2, .n_out = 2 },
        .{ .handle = 2, .pos = .{ .x = 10, .y = 10 }, .n_in = 1, .n_out = 1 },
        .{ .handle = 3, .pos = .{ .x = 15, .y = 15 }, .n_in = 0, .n_out = 0 },
    };
    var layout_arr = [_]Vec2f{.{ .x = 0, .y = 0 }} ** group.GROUP_HANDLE_BASE;
    var ledger: group.Ledger = .{};

    applySelectedGrid(&nodes, &.{ 0, 1, 2, 3 }, &layout_arr, &ledger);

    var i: usize = 0;
    while (i < nodes.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < nodes.len) : (j += 1) {
            try testing.expect(!rectsOverlap(nodes[i], nodes[j]));
        }
    }
}

test "layout selected: topology-agnostic — same positions yield same result" {
    // Independent of whether connections exist (this API does not take edges). The same initial position yields the same result.
    var a = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 40, .y = 40 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 200, .y = 50 }, .n_in = 1, .n_out = 0 },
        .{ .handle = 2, .pos = .{ .x = 60, .y = 180 }, .n_in = 0, .n_out = 0 },
    };
    var b = a;
    var la = [_]Vec2f{.{ .x = 0, .y = 0 }} ** group.GROUP_HANDLE_BASE;
    var lb = la;
    var ledger_a: group.Ledger = .{};
    var ledger_b: group.Ledger = .{};

    applySelectedGrid(&a, &.{ 0, 1, 2 }, &la, &ledger_a);
    applySelectedGrid(&b, &.{ 0, 1, 2 }, &lb, &ledger_b);

    for (a, b) |na, nb| {
        try testing.expectApproxEqAbs(na.pos.x, nb.pos.x, 1e-4);
        try testing.expectApproxEqAbs(na.pos.y, nb.pos.y, 1e-4);
    }
}
