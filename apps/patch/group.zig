//! apps/patch: グループ/マクロ台帳（TASK-40.7.1）。
//!
//! platform / gui / modular を import しない純 Zig（canvas.zig と同格）。型は canvas.zig から import する。
//! 固定確保・アロケーション無し。display/audio 無しで単体テストできる（test-patch）。
//!
//! 設計（案 A）: マクロのメンバーは通常のプリミティブモジュールとして DynGraph 上の handle を持つ。
//! 「どの handle がどのマクロに属すか / 畳んでいるか / 外向きポートはどれか」は main（UI）側のこの台帳が持ち、
//! publish には一切載せない（RT のグラフ記述とは完全分離。AC#3）。展開/畳みは純粋に表示の写像。
//!
//! **合成 handle（>= GROUP_HANDLE_BASE）は canvas 幾何関数の引数/返り値の中だけで使う**。dyn accessor・
//! app.layout[h] の index・dyn.disconnect の引数へは決して渡さない（main.zig 側の呼び出し規約）。

const std = @import("std");
const canvas = @import("canvas.zig");

pub const Handle = canvas.Handle;
pub const Vec2f = canvas.Vec2f;
pub const NodeGeom = canvas.NodeGeom;
pub const Edge = canvas.Edge;
pub const PortRef = canvas.PortRef;
pub const CableRef = canvas.CableRef;

pub const MAX_GROUPS = 8;
pub const GroupId = u8;
pub const MAX_EXPOSED = 8;

/// == libs/modular/src/dyn.zig の MAX_MODULES。group.zig は modular 非依存のため定数を複製する
/// （canvas.Handle は u16 なので 48..55 は実 handle 空間と衝突しない）。main.zig 側で
/// `comptime { if (group.GROUP_HANDLE_BASE != modular.dyn.MAX_MODULES) @compileError(...) }` により
/// 数値の食い違いを検出する。
pub const GROUP_HANDLE_BASE = 48;

/// 40.7.1 は drum_machine のみ（40.7.2 で bass_machine 追加）。
pub const MacroKind = enum {
    drum_machine,

    pub fn displayName(self: MacroKind) []const u8 {
        return switch (self) {
            .drum_machine => "DrumMachine",
        };
    }
};

/// 畳んだ箱 / 展開時の実メンバーポートへの alias 1 個。
pub const ExposedPort = struct {
    member: Handle = 0,
    port: u8 = 0,
    is_input: bool = false,
    label: [8]u8 = [_]u8{0} ** 8,
    label_len: u8 = 0,
};

/// label を書き込む（8B 超は切り詰め）。イベント時のみ。
pub fn setLabel(ep: *ExposedPort, text: []const u8) void {
    const n = @min(text.len, ep.label.len);
    @memcpy(ep.label[0..n], text[0..n]);
    if (n < ep.label.len) @memset(ep.label[n..], 0);
    ep.label_len = @intCast(n);
}

pub const Group = struct {
    active: bool = false,
    kind: MacroKind = .drum_machine,
    collapsed: bool = true,
    pos: Vec2f = .{ .x = 0, .y = 0 },
    exposed_in: [MAX_EXPOSED]ExposedPort = [_]ExposedPort{.{}} ** MAX_EXPOSED,
    n_in: u8 = 0,
    exposed_out: [MAX_EXPOSED]ExposedPort = [_]ExposedPort{.{}} ** MAX_EXPOSED,
    n_out: u8 = 0,
    /// 先頭 template_n_in/out 件は「テンプレ明示」の expose（deriveExposed が接続の有無に関わらず常に保持。
    /// 所属メンバーが個別削除された分だけ縮む）。残り（n_in-template_n_in 件等）は「境界跨ぎ自動」で
    /// deriveExposed の呼び出しごとに再計算・再配置される（(member,port) 昇順で安定）。
    template_n_in: u8 = 0,
    template_n_out: u8 = 0,
};

/// visual=描画/ヒットテスト用の写像済み端点（collapsed グループのメンバー端点は箱の合成 handle+exposed
/// index に写像）。actual=常に実接続の CableRef（選択/削除/drag-off はこちらを使い、合成 handle を
/// dyn.disconnect へ渡さない）。
pub const DisplayEdge = struct {
    visual: Edge,
    actual: CableRef,
};

/// gid ⇔ 合成 handle の変換（両側境界。OOB を閉じる）。
pub fn handleOfGroup(gid: GroupId) Handle {
    return GROUP_HANDLE_BASE + @as(Handle, gid);
}
pub fn groupIdFromHandle(h: Handle) ?GroupId {
    if (h < GROUP_HANDLE_BASE or h >= GROUP_HANDLE_BASE + MAX_GROUPS) return null;
    return @intCast(h - GROUP_HANDLE_BASE);
}

/// handle→所属 GroupId。**Ph7 は 1 レベル限定**（Group に parent 無し。将来ネストは Group.parent 追加で
/// 拡張できる形に留めるが実装しない＝過剰設計回避）。
pub const Ledger = struct {
    groups: [MAX_GROUPS]Group = [_]Group{.{}} ** MAX_GROUPS,
    /// 実 handle（< GROUP_HANDLE_BASE）→ 所属 GroupId。合成 handle は index しない。
    group_of: [GROUP_HANDLE_BASE]?GroupId = [_]?GroupId{null} ** GROUP_HANDLE_BASE,

    // ------------------------------------------------------------------
    // ライフサイクル（イベント時のみ）
    // ------------------------------------------------------------------

    /// 空き group slot を確保する（無ければ null）。
    pub fn alloc(self: *Ledger) ?GroupId {
        for (&self.groups, 0..) |*g, i| {
            if (!g.active) {
                g.* = .{ .active = true };
                return @intCast(i);
            }
        }
        return null;
    }

    /// group を解放し、所属メンバーの group_of もクリアする。
    pub fn free(self: *Ledger, gid: GroupId) void {
        if (gid >= MAX_GROUPS or !self.groups[gid].active) return;
        for (&self.group_of) |*go| {
            if (go.* != null and go.*.? == gid) go.* = null;
        }
        self.groups[gid] = .{};
    }

    /// 実 handle h を group gid のメンバーとして登録する。h が合成 handle（>= GROUP_HANDLE_BASE）や
    /// gid が範囲外なら無視する（1 レベル制約: グループがグループのメンバーにはなれない）。
    pub fn assign(self: *Ledger, h: Handle, gid: GroupId) void {
        if (h >= GROUP_HANDLE_BASE or gid >= MAX_GROUPS) return;
        self.group_of[h] = gid;
    }

    /// h の所属を外す。所属先グループが 0 メンバーになったら自動消滅（free 相当）。
    pub fn unassign(self: *Ledger, h: Handle) void {
        if (h >= GROUP_HANDLE_BASE) return;
        const gid = self.group_of[h] orelse return;
        self.group_of[h] = null;
        if (self.memberCount(gid) == 0) self.groups[gid] = .{};
    }

    pub fn memberOf(self: *const Ledger, gid: GroupId, h: Handle) bool {
        if (h >= GROUP_HANDLE_BASE) return false;
        return self.group_of[h] != null and self.group_of[h].? == gid;
    }

    fn memberCount(self: *const Ledger, gid: GroupId) usize {
        var n: usize = 0;
        for (self.group_of) |go| {
            if (go != null and go.? == gid) n += 1;
        }
        return n;
    }

    // ------------------------------------------------------------------
    // expose 導出（イベント時のみ。接続変更のたびに main が呼ぶ）
    // ------------------------------------------------------------------

    /// gid の expose 表を「テンプレ明示（先頭固定・現存メンバーのみ再検証）」∪「境界跨ぎ自動
    /// （グループ外ノードと接続済みのメンバーポートを (member,port) 昇順で追加）」で書き換える。
    ///
    /// 事前条件: flat_edges は実 handle のみ（buildFlatEdges の結果。DisplayEdge.visual や合成 handle を
    /// 含む edge を渡すのは呼び出し側のバグ）。synthetic handle 混入は debug assert で落とす。
    pub fn deriveExposed(self: *Ledger, gid: GroupId, flat_edges: []const Edge) void {
        if (gid >= MAX_GROUPS) return;
        const g = &self.groups[gid];
        if (!g.active) return;

        for (flat_edges) |e| {
            std.debug.assert(e.src_handle < GROUP_HANDLE_BASE);
            std.debug.assert(e.dst_handle < GROUP_HANDLE_BASE);
        }

        // 1) テンプレ明示を現存メンバーのみで再パック（個別削除された member の分は落ちる）。
        var new_in: [MAX_EXPOSED]ExposedPort = [_]ExposedPort{.{}} ** MAX_EXPOSED;
        var n_in: u8 = 0;
        {
            var i: u8 = 0;
            while (i < g.template_n_in) : (i += 1) {
                const ep = g.exposed_in[i];
                if (self.memberOf(gid, ep.member)) {
                    new_in[n_in] = ep;
                    n_in += 1;
                }
            }
        }
        const kept_template_in = n_in;

        var new_out: [MAX_EXPOSED]ExposedPort = [_]ExposedPort{.{}} ** MAX_EXPOSED;
        var n_out: u8 = 0;
        {
            var i: u8 = 0;
            while (i < g.template_n_out) : (i += 1) {
                const ep = g.exposed_out[i];
                if (self.memberOf(gid, ep.member)) {
                    new_out[n_out] = ep;
                    n_out += 1;
                }
            }
        }
        const kept_template_out = n_out;

        // 2) 境界跨ぎ自動候補を収集（テンプレと重複しない分だけ、(member,port) 重複除去）。
        var cand_in: [MAX_EXPOSED]ExposedPort = undefined;
        var cand_in_n: usize = 0;
        var cand_out: [MAX_EXPOSED]ExposedPort = undefined;
        var cand_out_n: usize = 0;

        for (flat_edges) |e| {
            const src_member = self.memberOf(gid, e.src_handle);
            const dst_member = self.memberOf(gid, e.dst_handle);
            if (src_member and !dst_member) {
                if (cand_out_n < MAX_EXPOSED and
                    findExposedIndex(new_out[0..n_out], e.src_handle, e.src_out) == null and
                    findExposedIndex(cand_out[0..cand_out_n], e.src_handle, e.src_out) == null)
                {
                    cand_out[cand_out_n] = .{ .member = e.src_handle, .port = e.src_out, .is_input = false };
                    cand_out_n += 1;
                }
            }
            if (dst_member and !src_member) {
                if (cand_in_n < MAX_EXPOSED and
                    findExposedIndex(new_in[0..n_in], e.dst_handle, e.dst_in) == null and
                    findExposedIndex(cand_in[0..cand_in_n], e.dst_handle, e.dst_in) == null)
                {
                    cand_in[cand_in_n] = .{ .member = e.dst_handle, .port = e.dst_in, .is_input = true };
                    cand_in_n += 1;
                }
            }
        }

        sortExposed(cand_in[0..cand_in_n]);
        sortExposed(cand_out[0..cand_out_n]);

        // 3) テンプレの後ろに追加（容量超過分は捨てる。MAX_EXPOSED=8 に対し想定メンバー数は十分小さい）。
        for (cand_in[0..cand_in_n]) |ep| {
            if (n_in >= MAX_EXPOSED) break;
            new_in[n_in] = ep;
            n_in += 1;
        }
        for (cand_out[0..cand_out_n]) |ep| {
            if (n_out >= MAX_EXPOSED) break;
            new_out[n_out] = ep;
            n_out += 1;
        }

        g.exposed_in = new_in;
        g.n_in = n_in;
        g.template_n_in = kept_template_in;
        g.exposed_out = new_out;
        g.n_out = n_out;
        g.template_n_out = kept_template_out;
    }

    // ------------------------------------------------------------------
    // 表示写像（フレーム毎・純関数。main が呼ぶ）
    // ------------------------------------------------------------------

    /// collapsed グループのメンバーを除外し、代わりに箱 NodeGeom を 1 個追加した表示用ノード列を書く。
    /// expanded グループのメンバーはそのまま通常表示（flat_nodes をそのまま通す）。
    /// フレーム毎（ノード数十個規模。全画素ではない）。
    pub fn mapNodesForCollapsed(self: *const Ledger, flat_nodes: []const NodeGeom, out: []NodeGeom) usize {
        var n: usize = 0;
        for (flat_nodes) |ng| {
            if (ng.handle < GROUP_HANDLE_BASE) {
                if (self.group_of[ng.handle]) |gid| {
                    if (self.groups[gid].collapsed) continue; // 畳み時はメンバー非表示（箱側で表現）
                }
            }
            if (n < out.len) {
                out[n] = ng;
                n += 1;
            }
        }
        for (self.groups, 0..) |g, i| {
            if (g.active and g.collapsed and n < out.len) {
                out[n] = .{ .handle = handleOfGroup(@intCast(i)), .pos = g.pos, .n_in = g.n_in, .n_out = g.n_out };
                n += 1;
            }
        }
        return n;
    }

    /// flat edge を表示用に写像する。collapsed グループ内メンバーの端点は箱ポート（合成 handle + exposed
    /// index）へ写像（visual）。actual は常に実接続（CableRef）。両端が同一 collapsed グループ内部の edge は
    /// 除外（非表示）。フレーム毎（edge 数十本規模）。
    pub fn buildDisplayEdges(self: *const Ledger, flat_edges: []const Edge, out: []DisplayEdge) usize {
        // deriveExposed と同じく flat edge（実 handle のみ）を事前条件とする。synthetic handle を混ぜると
        // 下の group_of[e.*_handle] が OOB index になるので早期に落とす（誤投入の防御）。
        for (flat_edges) |e| {
            std.debug.assert(e.src_handle < GROUP_HANDLE_BASE);
            std.debug.assert(e.dst_handle < GROUP_HANDLE_BASE);
        }
        var n: usize = 0;
        for (flat_edges) |e| {
            const src_gid = self.group_of[e.src_handle];
            const dst_gid = self.group_of[e.dst_handle];
            const src_collapsed = if (src_gid) |gid| self.groups[gid].collapsed else false;
            const dst_collapsed = if (dst_gid) |gid| self.groups[gid].collapsed else false;
            if (src_gid != null and dst_gid != null and src_gid.? == dst_gid.? and src_collapsed) {
                continue; // 同一 collapsed グループ内部 edge は非表示
            }
            var visual = e;
            if (src_collapsed) {
                const gid = src_gid.?;
                const gr = &self.groups[gid];
                if (findExposedIndex(gr.exposed_out[0..gr.n_out], e.src_handle, e.src_out)) |idx| {
                    visual.src_handle = handleOfGroup(gid);
                    visual.src_out = idx;
                }
            }
            if (dst_collapsed) {
                const gid = dst_gid.?;
                const gr = &self.groups[gid];
                if (findExposedIndex(gr.exposed_in[0..gr.n_in], e.dst_handle, e.dst_in)) |idx| {
                    visual.dst_handle = handleOfGroup(gid);
                    visual.dst_in = idx;
                }
            }
            if (n < out.len) {
                out[n] = .{ .visual = visual, .actual = .{ .dst_handle = e.dst_handle, .dst_in = e.dst_in } };
                n += 1;
            }
        }
        return n;
    }

    /// 合成 PortRef を exposed 表で実メンバーの PortRef へ解決する。実 handle（非合成）はそのまま返す
    /// （呼び出し側は合成かどうかを事前判定せず常に resolvePort を通せる）。範囲外の gid/index は null。
    pub fn resolvePort(self: *const Ledger, pr: PortRef) ?PortRef {
        const gid = groupIdFromHandle(pr.handle) orelse return pr;
        if (gid >= MAX_GROUPS or !self.groups[gid].active) return null;
        const g = &self.groups[gid];
        if (pr.is_input) {
            if (pr.index >= g.n_in) return null;
            const ep = g.exposed_in[pr.index];
            return .{ .handle = ep.member, .is_input = true, .index = ep.port };
        } else {
            if (pr.index >= g.n_out) return null;
            const ep = g.exposed_out[pr.index];
            return .{ .handle = ep.member, .is_input = false, .index = ep.port };
        }
    }
};

fn findExposedIndex(list: []const ExposedPort, member: Handle, port: u8) ?u8 {
    for (list, 0..) |ep, i| {
        if (ep.member == member and ep.port == port) return @intCast(i);
    }
    return null;
}

/// (member,port) 昇順の挿入ソート（件数は MAX_EXPOSED=8 以下）。
fn sortExposed(list: []ExposedPort) void {
    var i: usize = 1;
    while (i < list.len) : (i += 1) {
        const key = list[i];
        var j: usize = i;
        while (j > 0 and (list[j - 1].member > key.member or
            (list[j - 1].member == key.member and list[j - 1].port > key.port))) : (j -= 1)
        {
            list[j] = list[j - 1];
        }
        list[j] = key;
    }
}

// ============================================================================
// tests（display/audio 不要。test-patch）
// ============================================================================
const testing = std.testing;

test "group: groupIdFromHandle boundary (both ends) and handleOfGroup round-trip" {
    try testing.expectEqual(@as(?GroupId, null), groupIdFromHandle(GROUP_HANDLE_BASE - 1));
    try testing.expectEqual(@as(?GroupId, null), groupIdFromHandle(GROUP_HANDLE_BASE + MAX_GROUPS));
    try testing.expectEqual(@as(?GroupId, 0), groupIdFromHandle(GROUP_HANDLE_BASE));
    try testing.expectEqual(@as(?GroupId, MAX_GROUPS - 1), groupIdFromHandle(GROUP_HANDLE_BASE + MAX_GROUPS - 1));
    for (0..MAX_GROUPS) |i| {
        const gid: GroupId = @intCast(i);
        try testing.expectEqual(gid, groupIdFromHandle(handleOfGroup(gid)).?);
    }
}

test "group: alloc/assign/free lifecycle + auto-vanish on last unassign" {
    var l = Ledger{};
    const gid = l.alloc().?;
    try testing.expect(l.groups[gid].active);
    l.assign(10, gid);
    l.assign(11, gid);
    try testing.expectEqual(@as(?GroupId, gid), l.group_of[10]);
    l.unassign(10);
    try testing.expect(l.groups[gid].active); // まだ 1 メンバー残る
    l.unassign(11);
    try testing.expect(!l.groups[gid].active); // 0 メンバーで自動消滅
    try testing.expectEqual(@as(?GroupId, null), l.group_of[10]);
}

test "group: assign ignores synthetic handle (1-level nesting guard)" {
    var l = Ledger{};
    const gid = l.alloc().?;
    l.assign(handleOfGroup(0), gid); // 合成 handle は無視（グループがグループのメンバーにはなれない）
    try testing.expectEqual(@as(?GroupId, null), l.group_of[0]);
}

/// DrumMachine 相当のテスト用固定シナリオ: 外部 clock(0) → cdiv(10) → seqK(11)/seqH(12) →
/// kick(13)/hat(14) → mix(15) → 外部 output(20)。cdiv.in0 と mix.out0 がテンプレ明示 expose。
const Scenario = struct {
    l: Ledger = .{},
    gid: GroupId = 0,

    fn init() Scenario {
        var s = Scenario{};
        s.gid = s.l.alloc().?;
        const members = [_]Handle{ 10, 11, 12, 13, 14, 15 };
        for (members) |h| s.l.assign(h, s.gid);
        var g = &s.l.groups[s.gid];
        g.exposed_in[0] = .{ .member = 10, .port = 0, .is_input = true };
        g.n_in = 1;
        g.template_n_in = 1;
        g.exposed_out[0] = .{ .member = 15, .port = 0, .is_input = false };
        g.n_out = 1;
        g.template_n_out = 1;
        return s;
    }

    fn flatEdges(buf: []Edge) []Edge {
        const es = [_]Edge{
            .{ .src_handle = 0, .src_out = 0, .dst_handle = 10, .dst_in = 0 }, // 外部 clock -> cdiv.in0（テンプレと重複）
            .{ .src_handle = 10, .src_out = 0, .dst_handle = 11, .dst_in = 0 },
            .{ .src_handle = 10, .src_out = 0, .dst_handle = 12, .dst_in = 0 },
            .{ .src_handle = 11, .src_out = 0, .dst_handle = 13, .dst_in = 0 },
            .{ .src_handle = 12, .src_out = 0, .dst_handle = 14, .dst_in = 0 },
            .{ .src_handle = 13, .src_out = 0, .dst_handle = 15, .dst_in = 0 },
            .{ .src_handle = 14, .src_out = 0, .dst_handle = 15, .dst_in = 1 },
            .{ .src_handle = 15, .src_out = 0, .dst_handle = 20, .dst_in = 0 }, // mix.out0 -> 外部 output（テンプレと重複）
        };
        @memcpy(buf[0..es.len], &es);
        return buf[0..es.len];
    }
};

test "group: deriveExposed template stays (no dup with boundary) when no extra crossing" {
    var s = Scenario.init();
    var buf: [16]Edge = undefined;
    const edges = Scenario.flatEdges(&buf);
    s.l.deriveExposed(s.gid, edges);
    const g = s.l.groups[s.gid];
    try testing.expectEqual(@as(u8, 1), g.n_in);
    try testing.expectEqual(@as(Handle, 10), g.exposed_in[0].member);
    try testing.expectEqual(@as(u8, 1), g.n_out);
    try testing.expectEqual(@as(Handle, 15), g.exposed_out[0].member);
}

test "group: deriveExposed adds boundary-crossing auto ports sorted by (member,port), template first" {
    var s = Scenario.init();
    var buf: [16]Edge = undefined;
    var es_buf: [16]Edge = undefined;
    const base = Scenario.flatEdges(&buf);
    @memcpy(es_buf[0..base.len], base);
    // 追加の境界跨ぎ fan-out: kick(13)/hat(14) の audio out がそれぞれ別の外部ノード（< GROUP_HANDLE_BASE の
    // 実 handle。ここでは 30/31）へも直結（出力は fan-out 可）。
    es_buf[base.len] = .{ .src_handle = 14, .src_out = 0, .dst_handle = 31, .dst_in = 0 };
    es_buf[base.len + 1] = .{ .src_handle = 13, .src_out = 0, .dst_handle = 30, .dst_in = 0 };
    const edges = es_buf[0 .. base.len + 2];

    s.l.deriveExposed(s.gid, edges);
    const g = s.l.groups[s.gid];
    try testing.expectEqual(@as(u8, 3), g.n_out);
    try testing.expectEqual(@as(Handle, 15), g.exposed_out[0].member); // テンプレが先頭
    try testing.expectEqual(@as(Handle, 13), g.exposed_out[1].member); // 自動は member 昇順
    try testing.expectEqual(@as(Handle, 14), g.exposed_out[2].member);
    try testing.expectEqual(@as(u8, 1), g.n_in); // 入力側は変化なし
}

test "group: deriveExposed drops template entry whose member left the group" {
    var s = Scenario.init();
    s.l.unassign(15); // mix を個別削除（メンバー 0 にはならない = グループは残る）
    // kick/hat->mix の内部 edge を含む Scenario.flatEdges をそのまま使うと、mix が非メンバーになった
    // ことで kick/hat の audio out が新たに境界跨ぎ扱いになる（宙に浮いたケーブルの自動 expose
    // フォールバック。これは意図した挙動で別テストの対象）。ここでは「テンプレ entry が消えること」だけを
    // 単純に確認するため、その 2 本を含まない最小 edge 列を使う。
    const edges = [_]Edge{
        .{ .src_handle = 0, .src_out = 0, .dst_handle = 10, .dst_in = 0 }, // 外部 clock -> cdiv.in0
        .{ .src_handle = 15, .src_out = 0, .dst_handle = 20, .dst_in = 0 }, // mix(非メンバー) -> 外部 output
    };
    s.l.deriveExposed(s.gid, &edges);
    const g = s.l.groups[s.gid];
    try testing.expectEqual(@as(u8, 0), g.n_out); // mix が居ないので audio out expose は消える（両端非メンバーで無視）
    try testing.expectEqual(@as(u8, 1), g.n_in); // cdiv 側は無事
}

test "group: deriveExposed re-exposes a dangling internal port as boundary when its downstream member is removed" {
    var s = Scenario.init();
    s.l.unassign(15); // mix を個別削除
    var buf: [16]Edge = undefined;
    const edges = Scenario.flatEdges(&buf); // kick->mix / hat->mix を含む元のシナリオそのまま
    s.l.deriveExposed(s.gid, edges);
    const g = s.l.groups[s.gid];
    // mix が非メンバーになったことで kick(13)/hat(14) の audio out が新たに境界跨ぎ＝自動 expose される
    // （ケーブルが宙に浮かないフォールバック。member 昇順）。
    try testing.expectEqual(@as(u8, 2), g.n_out);
    try testing.expectEqual(@as(Handle, 13), g.exposed_out[0].member);
    try testing.expectEqual(@as(Handle, 14), g.exposed_out[1].member);
}

test "group: mapNodesForCollapsed hides members and adds a box when collapsed, shows members when expanded" {
    var s = Scenario.init();
    const flat = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 10, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1 },
        .{ .handle = 11, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1 },
        .{ .handle = 12, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1 },
        .{ .handle = 13, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1 },
        .{ .handle = 14, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1 },
        .{ .handle = 15, .pos = .{ .x = 0, .y = 0 }, .n_in = 2, .n_out = 1 },
        .{ .handle = 20, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 0 },
    };
    var out_buf: [16]NodeGeom = undefined;

    // collapsed（既定）: 6 メンバーが 1 箱に畳まれる → 0, box, 20 の 3 個。
    {
        const n = s.l.mapNodesForCollapsed(&flat, &out_buf);
        try testing.expectEqual(@as(usize, 3), n);
        var saw_box = false;
        for (out_buf[0..n]) |ng| {
            if (ng.handle == handleOfGroup(s.gid)) saw_box = true;
        }
        try testing.expect(saw_box);
    }
    // expanded: メンバーがそのまま出る（箱は無し）→ 元の 8 個そのまま。
    {
        s.l.groups[s.gid].collapsed = false;
        const n = s.l.mapNodesForCollapsed(&flat, &out_buf);
        try testing.expectEqual(flat.len, n);
    }
}

test "group: buildDisplayEdges maps collapsed boundary to box index, hides internal edges, actual stays real" {
    var s = Scenario.init();
    var buf: [16]Edge = undefined;
    const edges = Scenario.flatEdges(&buf);
    s.l.deriveExposed(s.gid, edges); // テンプレのみ（境界跨ぎ追加なし）

    var out_buf: [16]DisplayEdge = undefined;
    const n = s.l.buildDisplayEdges(edges, &out_buf);
    try testing.expectEqual(@as(usize, 2), n); // 6 本の内部 edge は非表示、2 本の境界 edge のみ

    // 0 -> cdiv.in0 の boundary edge: visual dst は箱の exposed_in[0]、actual は実 CableRef(10,0)。
    const in_edge = for (out_buf[0..n]) |de| {
        if (de.visual.src_handle == 0) break de;
    } else unreachable;
    try testing.expectEqual(handleOfGroup(s.gid), in_edge.visual.dst_handle);
    try testing.expectEqual(@as(u8, 0), in_edge.visual.dst_in);
    try testing.expectEqual(@as(Handle, 10), in_edge.actual.dst_handle);
    try testing.expectEqual(@as(u8, 0), in_edge.actual.dst_in);

    // mix.out0 -> 20 の boundary edge: visual src は箱の exposed_out[0]、actual は実 CableRef(20,0)。
    const out_edge = for (out_buf[0..n]) |de| {
        if (de.visual.dst_handle == 20) break de;
    } else unreachable;
    try testing.expectEqual(handleOfGroup(s.gid), out_edge.visual.src_handle);
    try testing.expectEqual(@as(u8, 0), out_edge.visual.src_out);
    try testing.expectEqual(@as(Handle, 20), out_edge.actual.dst_handle);

    // expanded: フィルタも写像も無し（全 edge がそのまま実 handle で通る）。
    s.l.groups[s.gid].collapsed = false;
    const n2 = s.l.buildDisplayEdges(edges, &out_buf);
    try testing.expectEqual(edges.len, n2);
    for (out_buf[0..n2], edges) |de, e| {
        try testing.expectEqual(e.src_handle, de.visual.src_handle);
        try testing.expectEqual(e.dst_handle, de.visual.dst_handle);
        try testing.expectEqual(e.dst_handle, de.actual.dst_handle);
        try testing.expectEqual(e.dst_in, de.actual.dst_in);
    }
}

test "group: resolvePort passes through real refs and resolves synthetic refs, rejects out-of-range" {
    var s = Scenario.init();
    // 実 PortRef はそのまま。
    const real = PortRef{ .handle = 10, .is_input = true, .index = 0 };
    try testing.expectEqual(real, s.l.resolvePort(real).?);

    // 合成 in0 → cdiv(10).in0。
    const synth_in = PortRef{ .handle = handleOfGroup(s.gid), .is_input = true, .index = 0 };
    const resolved_in = s.l.resolvePort(synth_in).?;
    try testing.expectEqual(@as(Handle, 10), resolved_in.handle);
    try testing.expect(resolved_in.is_input);
    try testing.expectEqual(@as(u8, 0), resolved_in.index);

    // 合成 out0 → mix(15).out0。
    const synth_out = PortRef{ .handle = handleOfGroup(s.gid), .is_input = false, .index = 0 };
    const resolved_out = s.l.resolvePort(synth_out).?;
    try testing.expectEqual(@as(Handle, 15), resolved_out.handle);
    try testing.expect(!resolved_out.is_input);

    // 範囲外 index（exposed_in は 1 個しか無い）。
    try testing.expectEqual(@as(?PortRef, null), s.l.resolvePort(.{ .handle = handleOfGroup(s.gid), .is_input = true, .index = 5 }));
    // 非 active な gid。
    try testing.expectEqual(@as(?PortRef, null), s.l.resolvePort(.{ .handle = handleOfGroup(1), .is_input = true, .index = 0 }));
}
