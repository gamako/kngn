//! apps/patch: 表示グラフの Sugiyama 系レイヤードレイアウト（TASK-173.1）。
//!
//! mapNodesForCollapsed / buildDisplayEdges が返す表示ノード・辺に対し rank 付けと縦積みを行い、
//! 実ノードは layout[handle]、畳みマクロ箱は ledger.groups[gid].pos、展開中マクロのヘッダーは
//! メンバー bbox に追従させる。
//!
//! ホットパス宣言: auto_layout action 呼び出し時のみ（イベント時）。フレーム毎描画・RT 経路には触れない。
//! platform / gui / modular を import しない純 Zig（canvas / group のみ。test-patch で単体テスト可）。

const std = @import("std");
const canvas = @import("canvas.zig");
const group = @import("group.zig");

pub const Handle = canvas.Handle;
pub const Vec2f = canvas.Vec2f;
pub const NodeGeom = canvas.NodeGeom;
pub const Edge = canvas.Edge;

/// world 原点 X / 列間ギャップ（plan: x = 24 + rank * (NODE_W + 40)）。
pub const ORIGIN_X: f32 = 24;
pub const COL_GAP: f32 = 40;
/// 各 rank 列の先頭 Y のテスト用既定値。実行時は呼び出し側がパレット帯を避けた world Y を渡す。
pub const ORIGIN_Y: f32 = 24;
pub const ROW_GAP: f32 = 24;
/// 展開ヘッダーとメンバー bbox の余白（drawExpandedGroupFrame と同じ margin=10）。
pub const EXPANDED_HEADER_MARGIN: f32 = 10;

const MAX_NODES: usize = group.GROUP_HANDLE_BASE + group.MAX_GROUPS;

/// 表示グラフをレイヤードレイアウトし、layout / ledger へ書き戻す。
///
/// - `nodes`: 表示ノード（pos を更新する。入力の n_in/n_out/grid_rows は nodeSize に使う）
/// - `edges`: 表示辺（DisplayEdge.visual。フィードバック辺も含めて渡してよいが rank 計算からは除外）
/// - `order_keys`: nodes と並行。DynGraph view.order 添字（collapsed group はメンバー最小 key）
/// - `layout`: 実 handle のみ index（合成 handle は絶対に書かない）
/// - `ledger`: collapsed 箱 pos / expanded ヘッダー pos の書き戻し先
/// - `origin_y`: rank0 列の先頭 world Y（main が paletteBottom 相当を world 変換して渡す）
///
/// 事前条件: nodes.len == order_keys.len。layout.len >= GROUP_HANDLE_BASE。
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

/// src_key < dst_key の順方向辺だけを使い rank を計算する。
/// 表示ノードを order key 昇順で処理し、rank[dst] = max(rank[dst], rank[src]+1)。
fn computeRanks(
    nodes: []const NodeGeom,
    edges: []const Edge,
    order_keys: []const u32,
    ranks: []u32,
) void {
    const n = nodes.len;
    // order key 昇順の処理順（第二キーは元 index で決定性）
    var order_idx: [MAX_NODES]u16 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) order_idx[i] = @intCast(i);
    std.mem.sort(u16, order_idx[0..n], SortByOrderKey{ .keys = order_keys }, SortByOrderKey.less);

    // handle → nodes 内 index（辺の端点解決用。同一 handle は表示上 1 回のみ想定）
    // 合成 handle は GROUP_HANDLE_BASE + gid。
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
            if (src_key >= dst_key) continue; // フィードバック辺は rank 計算から除外
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

/// rank 昇順に座標を確定。同一 rank 内は average source center-Y（無ければ order key）でソート。
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

        // 同一 rank 内ソート用キー
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

        // 縦積み（各 rank 列の先頭 Y は呼び出し側の origin_y）
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
        // 入辺あり同士: average_source_y 昇順。片方のみ: 入辺ありを先（y 比較より order に寄せない）。
        // 両方なし: order key。第二キーは常に order key。
        const a_has = ctx.has_src[a];
        const b_has = ctx.has_src[b];
        if (a_has and b_has) {
            if (ctx.sort_y[a] != ctx.sort_y[b]) return ctx.sort_y[a] < ctx.sort_y[b];
        } else if (a_has != b_has) {
            // 片方が order-key フォールバック。決定性のため order key 比較へ。
        }
        const ka = ctx.order_keys[a];
        const kb = ctx.order_keys[b];
        if (ka != kb) return ka < kb;
        return a < b;
    }
};

/// 順方向入辺の接続元矩形中心 Y の平均。入辺が無ければ null（order key フォールバック）。
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
        if (src_key >= dst_key) continue; // フィードバック辺はソート参照からも除外
        const src = nodes[si];
        const sz = canvas.nodeSize(src);
        sum += src.pos.y + sz.y * 0.5;
        count += 1;
    }
    if (count == 0) return null;
    return sum / @as(f32, @floatFromInt(count));
}

/// 実ノード → layout[handle]、合成 handle → groups[gid].pos。合成を layout に index しない。
fn writeBack(nodes: []const NodeGeom, layout: []Vec2f, ledger: *group.Ledger) void {
    for (nodes) |ng| {
        if (group.groupIdFromHandle(ng.handle)) |gid| {
            if (gid < group.MAX_GROUPS and ledger.groups[gid].active) {
                ledger.groups[gid].pos = ng.pos;
            }
        } else if (ng.handle < layout.len) {
            layout[ng.handle] = ng.pos;
        }
    }
}

/// 展開中 group のヘッダーを、再配置後メンバー bbox の上（margin=10）へ追従。
/// メンバー無し group は変更しない。collapsed は対象外（箱は表示ノードとして既に配置済み）。
fn repositionExpandedHeaders(nodes: []const NodeGeom, layout: []const Vec2f, ledger: *group.Ledger) void {
    _ = layout; // メンバー座標は nodes 側（writeBack 前に place 済み）を正とする
    var gi: group.GroupId = 0;
    while (gi < group.MAX_GROUPS) : (gi += 1) {
        const g = &ledger.groups[gi];
        if (!g.active or g.collapsed) continue;

        var bbox_min = Vec2f{ .x = std.math.floatMax(f32), .y = std.math.floatMax(f32) };
        var any = false;

        // plan: group_of[h]==gid の実ノードを列挙。表示に居るメンバーの NodeGeom で nodeSize を取る。
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
// tests（display/audio 不要。test-patch）
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
    // A(0) → B(1), A → C(2), B → D(3), C → D。order key = handle。
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

    // 全矩形が重ならない
    var i: usize = 0;
    while (i < nodes.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < nodes.len) : (j += 1) {
            try testing.expect(!rectsOverlap(nodes[i], nodes[j]));
        }
    }
    // 順方向辺は x(src) < x(dst)
    for (edges) |e| {
        const s = findNode(&nodes, e.src_handle).?;
        const d = findNode(&nodes, e.dst_handle).?;
        try testing.expect(s.pos.x < d.pos.x);
    }
    // rank0 は A のみ
    try testing.expectApproxEqAbs(ORIGIN_X, nodes[0].pos.x, 1e-4);
}

test "layout: rank0 nodes ordered by order key" {
    // 非接続 3 ノード。order key 2,0,1 → Y は key 昇順 0,1,2。
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
    // A→B→C→A。order key 0,1,2。forward: A→B, B→C。feedback: C→A は rank 除外。
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
    // forward 辺は x 単調
    try testing.expect(nodes[0].pos.x < nodes[1].pos.x);
    try testing.expect(nodes[1].pos.x < nodes[2].pos.x);
    // 入力 edges は不変（layout は edges を書き換えない＝呼び出し側が表示用に保持）
    try testing.expectEqual(@as(Handle, 2), edges[2].src_handle);
    try testing.expectEqual(@as(Handle, 0), edges[2].dst_handle);
}

test "layout: collapsed synthetic group is one node and writes group.pos only" {
    const gid: group.GroupId = 0;
    const box_h = group.handleOfGroup(gid);
    // 外部 0 → 箱、箱 → 外部 1。箱の order key = メンバー最小 = 5（メンバー handle は 5,6 だが非表示）
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
    // 合成 handle 用スロットは layout に無い（長さ GROUP_HANDLE_BASE）。番兵として別配列は触らない。
    var ledger: group.Ledger = .{};
    ledger.groups[gid] = .{
        .active = true,
        .collapsed = true,
        .pos = .{ .x = -1, .y = -1 },
        .kind = .drum_machine,
    };
    // メンバー登録（order key 構築のシミュ。layout 本体はメンバーを表示しない）
    ledger.assign(5, gid);
    ledger.assign(6, gid);

    // layout の合成 index 相当を壊していないことの検証用スナップショット
    const layout_before = layout_arr;

    apply(&nodes, &edges, &keys, &layout_arr, &ledger, ORIGIN_Y);

    try testing.expect(isFinitePos(ledger.groups[gid].pos));
    try testing.expectApproxEqAbs(nodes[1].pos.x, ledger.groups[gid].pos.x, 1e-4);
    try testing.expectApproxEqAbs(nodes[1].pos.y, ledger.groups[gid].pos.y, 1e-4);
    // 実ノードは layout に書かれる
    try testing.expectApproxEqAbs(nodes[0].pos.x, layout_arr[0].x, 1e-4);
    try testing.expectApproxEqAbs(nodes[2].pos.x, layout_arr[1].x, 1e-4);
    // メンバー handle 5,6 の layout は表示対象外なので変更されない（書き戻し先分離）
    try testing.expectApproxEqAbs(layout_before[5].x, layout_arr[5].x, 1e-4);
    try testing.expectApproxEqAbs(layout_before[6].x, layout_arr[6].x, 1e-4);
    // 順方向 x 単調
    try testing.expect(nodes[0].pos.x < nodes[1].pos.x);
    try testing.expect(nodes[1].pos.x < nodes[2].pos.x);
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

    // 全 layout スロット不変（合成 handle を index していない）
    for (before, layout_arr) |b, a| {
        try testing.expectEqual(b.x, a.x);
        try testing.expectEqual(b.y, a.y);
    }
    try testing.expectApproxEqAbs(nodes[0].pos.x, ledger.groups[gid].pos.x, 1e-4);
}

test "layout: expanded group header follows member bbox without overlap" {
    const gid: group.GroupId = 0;
    // メンバー 10 → 11。expanded なので両方が表示ノード。ヘッダーは groups[gid].pos。
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

    // メンバーは layout に
    try testing.expectApproxEqAbs(nodes[0].pos.x, layout_arr[10].x, 1e-4);
    try testing.expectApproxEqAbs(nodes[1].pos.x, layout_arr[11].x, 1e-4);

    // ヘッダーは bbox 上端の上
    var bbox_min_y = nodes[0].pos.y;
    bbox_min_y = @min(bbox_min_y, nodes[1].pos.y);
    var bbox_min_x = nodes[0].pos.x;
    bbox_min_x = @min(bbox_min_x, nodes[1].pos.x);
    const header = NodeGeom{ .handle = group.handleOfGroup(gid), .pos = ledger.groups[gid].pos, .n_in = 0, .n_out = 0 };
    const header_h = canvas.nodeSize(header).y;
    try testing.expectApproxEqAbs(bbox_min_x, ledger.groups[gid].pos.x, 1e-4);
    try testing.expectApproxEqAbs(bbox_min_y - header_h - EXPANDED_HEADER_MARGIN, ledger.groups[gid].pos.y, 1e-4);

    // ヘッダー矩形とメンバーが重ならない
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

    // 実ノード 3 → layout[3]
    try testing.expectApproxEqAbs(nodes[0].pos.x, layout_arr[3].x, 1e-4);
    try testing.expectApproxEqAbs(nodes[0].pos.y, layout_arr[3].y, 1e-4);
    // 箱 → group.pos のみ（layout の他スロットは 9,9 のまま。handle 3 以外）
    try testing.expectApproxEqAbs(nodes[1].pos.x, ledger.groups[gid].pos.x, 1e-4);
    try testing.expectApproxEqAbs(layout_arr[0].x, 9, 1e-4);
    try testing.expectApproxEqAbs(layout_arr[4].x, 9, 1e-4);
}

test "layout: caller origin_y is used as rank0 top Y" {
    // main が paletteBottom 相当の大きい world Y を渡したとき、rank0 先頭がその値と一致する。
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
    // rank1 も同じ origin_y から縦積み開始（単一ノード列なので先頭 = origin_y）
    try testing.expectApproxEqAbs(caller_origin_y, nodes[1].pos.y, 1e-4);
    try testing.expect(nodes[0].pos.y >= caller_origin_y);
    try testing.expect(nodes[1].pos.y >= caller_origin_y);
}
