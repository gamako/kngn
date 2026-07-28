//! apps/patch: the group/macro ledger.
//!
//! Pure Zig with no platform / gui / modular imports (on par with canvas.zig). Types are imported from canvas.zig.
//! Fixed allocation only, no dynamic allocation. Unit-testable without display/audio (test-patch).
//!
//! Design: a macro's members are ordinary primitive modules, each holding a handle on the DynGraph.
//! Which handle belongs to which macro, whether it is collapsed, and which ports are exposed outward are held by this ledger on the main (UI) side,
//! and none of it is ever published (fully separate from the RT graph description). Expand/collapse is purely a display-side mapping.
//!
//! **A synthetic handle (>= GROUP_HANDLE_BASE) is used only as an argument/return value of canvas geometry functions.** It must never be passed to dyn
//! accessors, the app.layout[h] index, or dyn.disconnect (a calling convention enforced on the main.zig side).

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

/// == libs/modular/src/dyn.zig's MAX_MODULES. Since group.zig does not import modular, it
/// reads the same build_options.max_modules instead (no dependency on modular).
/// Since canvas.Handle is u16, GROUP_HANDLE_BASE..BASE+MAX_GROUPS never collides with the real handle space.
/// On the main.zig side, `comptime { if (group.GROUP_HANDLE_BASE != modular.dyn.MAX_MODULES) @compileError(...) }`
/// detects any numeric mismatch.
pub const GROUP_HANDLE_BASE: usize = @import("build_options").max_modules;

/// == modular.signal.MAX_OUT. port id = handle * MAX_OUT_PORTS + out_index.
/// Duplicated here for resolveExposedPort since group.zig is modular-independent.
pub const MAX_OUT_PORTS: u32 = 4;

/// drum_machine and bass_machine are supported kinds. The ledger, expose derivation, and display mapping are all kind-independent and shared.
pub const MacroKind = enum {
    drum_machine,
    bass_machine,

    pub fn displayName(self: MacroKind) []const u8 {
        return switch (self) {
            .drum_machine => "DrumMachine",
            .bass_machine => "BassMachine",
        };
    }
};

/// One alias, either to a collapsed box or to a real member port when expanded.
pub const ExposedPort = struct {
    member: Handle = 0,
    port: u8 = 0,
    is_input: bool = false,
    label: [8]u8 = [_]u8{0} ** 8,
    label_len: u8 = 0,
};

/// Writes the label (truncated beyond 8B). Event-time only.
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
    /// 0 uses the per-kind default (palette macro drum=2 / bass=4).
    /// A generated macro states its display lane count explicitly (generated drum=3 / bass=4). UI-local only.
    grid_rows: u8 = 0,
    pos: Vec2f = .{ .x = 0, .y = 0 },
    exposed_in: [MAX_EXPOSED]ExposedPort = [_]ExposedPort{.{}} ** MAX_EXPOSED,
    n_in: u8 = 0,
    exposed_out: [MAX_EXPOSED]ExposedPort = [_]ExposedPort{.{}} ** MAX_EXPOSED,
    n_out: u8 = 0,
    /// The first template_n_in/out entries are the "explicit template" exposes (deriveExposed always keeps them regardless of connection state;
    /// they shrink only when their owning member is individually removed). The rest (n_in-template_n_in entries, etc.) are "automatic boundary-crossing" exposes,
    /// recomputed and repositioned on every deriveExposed call (stable, ordered ascending by (member,port)).
    template_n_in: u8 = 0,
    template_n_out: u8 = 0,
};

/// visual = the mapped endpoint used for drawing/hit-testing (a collapsed group's member endpoint is mapped to the box's synthetic handle + exposed
/// index). actual = always the real connection's CableRef (used for select/delete/drag-off; a synthetic handle
/// is never passed to dyn.disconnect).
pub const DisplayEdge = struct {
    visual: Edge,
    actual: CableRef,
};

/// The number of TR/303 grid rows in a collapsed box, used to extend the box height (drum=2 lanes; bass=on/accent/slide 3 rows plus a 1-row pitch band).
/// Distinct from the clickable mask row count (drum=2 / bass=3); the pitch band is display-only. Passed to canvas.NodeGeom.grid_rows.
pub fn gridRowsForBox(kind: MacroKind) u8 {
    return switch (kind) {
        .drum_machine => 2,
        .bass_machine => 4,
    };
}

/// Converts between a gid and its synthetic handle (bidirectional; out-of-bounds values are rejected).
pub fn handleOfGroup(gid: GroupId) Handle {
    return @intCast(GROUP_HANDLE_BASE + @as(usize, gid));
}
pub fn groupIdFromHandle(h: Handle) ?GroupId {
    if (h < GROUP_HANDLE_BASE or h >= GROUP_HANDLE_BASE + MAX_GROUPS) return null;
    return @intCast(@as(usize, h) - GROUP_HANDLE_BASE);
}

/// Resolves a display handle (real or a synthetic box) to a real global output port id (handle*MAX_OUT_PORTS+out).
/// out0 is the representative. Returns -1 when unresolvable (no output / inactive / a synthetic box with no expose).
///
/// `dyn_check` is a duck-typed value with `slotActive(Handle) bool` and `nOut(Handle) u8`
/// (this keeps modular independence by not importing the real DynGraph type).
///
/// Contract: the return value (a real port id) and the display handle are independent axes.
/// (1) Even if a synthetic box handle is unchanged, the return value changes if exposed_out[0]'s member/port changes.
/// (2) Different display handles can yield the same return value if they point at the same real member/port.
pub fn resolveExposedPort(ledger: *const Ledger, dyn_check: anytype, dh: Handle) i32 {
    if (groupIdFromHandle(dh)) |gid| {
        const g = ledger.groups[gid];
        if (g.n_out == 0) return -1;
        const ref = g.exposed_out[0];
        if (!dyn_check.slotActive(ref.member) or dyn_check.nOut(ref.member) <= ref.port) return -1;
        return @intCast(@as(u32, ref.member) * MAX_OUT_PORTS + ref.port);
    }
    if (!dyn_check.slotActive(dh) or dyn_check.nOut(dh) == 0) return -1;
    return @intCast(@as(u32, dh) * MAX_OUT_PORTS); // out0
}

/// Maps a handle to its owning GroupId. **Currently limited to one level** (a Group has no parent). Nesting could be added later via a Group.parent field,
/// but is left unimplemented to avoid over-engineering.
pub const Ledger = struct {
    groups: [MAX_GROUPS]Group = [_]Group{.{}} ** MAX_GROUPS,
    /// A real handle (< GROUP_HANDLE_BASE) maps to its owning GroupId. Synthetic handles are not indexed.
    group_of: [GROUP_HANDLE_BASE]?GroupId = [_]?GroupId{null} ** GROUP_HANDLE_BASE,

    // ------------------------------------------------------------------
    // Lifecycle (event-time only)
    // ------------------------------------------------------------------

    /// Allocates a free group slot (null if none is available).
    pub fn alloc(self: *Ledger) ?GroupId {
        for (&self.groups, 0..) |*g, i| {
            if (!g.active) {
                g.* = .{ .active = true };
                return @intCast(i);
            }
        }
        return null;
    }

    /// Frees a group and clears group_of for its members.
    pub fn free(self: *Ledger, gid: GroupId) void {
        if (gid >= MAX_GROUPS or !self.groups[gid].active) return;
        for (&self.group_of) |*go| {
            if (go.* != null and go.*.? == gid) go.* = null;
        }
        self.groups[gid] = .{};
    }

    /// Registers real handle h as a member of group gid. If h is a synthetic handle (>= GROUP_HANDLE_BASE)
    /// or gid is out of range, the call is ignored (a one-level constraint: a group cannot be a member of another group).
    pub fn assign(self: *Ledger, h: Handle, gid: GroupId) void {
        if (h >= GROUP_HANDLE_BASE or gid >= MAX_GROUPS) return;
        self.group_of[h] = gid;
    }

    /// Removes h's membership. If the owning group drops to 0 members, it is automatically freed.
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

    /// Sets a group's position and translates its members when the group is collapsed.
    /// `layout` is indexed by real handles; synthetic handles are never members.
    pub fn setPosAndTranslateMembers(
        self: *Ledger,
        gid: GroupId,
        new_pos: Vec2f,
        layout: []Vec2f,
    ) void {
        if (gid >= MAX_GROUPS or !self.groups[gid].active) return;

        const old_pos = self.groups[gid].pos;
        const delta = new_pos.sub(old_pos);

        if (self.groups[gid].collapsed) {
            for (self.group_of, 0..) |owner, h| {
                if (owner == null or owner.? != gid) continue;
                if (h >= layout.len) continue;
                layout[h] = layout[h].add(delta);
            }
        }

        // This assignment must remain after the member loop. Every caller passes the
        // position that it wants to become the new group position.
        self.groups[gid].pos = new_pos;
    }

    fn memberCount(self: *const Ledger, gid: GroupId) usize {
        var n: usize = 0;
        for (self.group_of) |go| {
            if (go != null and go.? == gid) n += 1;
        }
        return n;
    }

    // ------------------------------------------------------------------
    // Expose derivation (event-time only; main calls this on every connection change)
    // ------------------------------------------------------------------

    /// Rewrites gid's expose table as the union of "explicit template" (fixed prefix, re-validated against current members only) and "automatic
    /// boundary-crossing" (member ports connected to a node outside the group, added in ascending (member,port) order).
    ///
    /// Precondition: flat_edges contains only real handles (the result of buildFlatEdges). Passing an edge that contains
    /// DisplayEdge.visual or a synthetic handle is a caller bug; a mixed-in synthetic handle triggers a debug assert.
    pub fn deriveExposed(self: *Ledger, gid: GroupId, flat_edges: []const Edge) void {
        if (gid >= MAX_GROUPS) return;
        const g = &self.groups[gid];
        if (!g.active) return;

        for (flat_edges) |e| {
            std.debug.assert(e.src_handle < GROUP_HANDLE_BASE);
            std.debug.assert(e.dst_handle < GROUP_HANDLE_BASE);
        }

        // 1) Repack the explicit template using only current members (entries for individually removed members are dropped).
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

        // 2) Collect automatic boundary-crossing candidates (only those not duplicating the template, de-duplicated by (member,port)).
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

        // 3) Append them after the template (entries beyond capacity are discarded; the expected member count is well within MAX_EXPOSED=8).
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
    // Display mapping (per-frame, pure function; called by main)
    // ------------------------------------------------------------------

    /// Writes a display node list that excludes a collapsed group's members and adds one box NodeGeom in their place.
    /// An expanded group's members are shown normally, passed through from flat_nodes unchanged.
    /// Runs every frame, over on the order of tens of nodes (not per-pixel).
    pub fn mapNodesForCollapsed(self: *const Ledger, flat_nodes: []const NodeGeom, out: []NodeGeom) usize {
        var n: usize = 0;
        for (flat_nodes) |ng| {
            if (ng.handle < GROUP_HANDLE_BASE) {
                if (self.group_of[ng.handle]) |gid| {
                    if (self.groups[gid].collapsed) continue; // Members are hidden while collapsed (represented by the box instead)
                }
            }
            if (n < out.len) {
                out[n] = ng;
                n += 1;
            }
        }
        for (self.groups, 0..) |g, i| {
            if (g.active and g.collapsed and n < out.len) {
                out[n] = .{
                    .handle = handleOfGroup(@intCast(i)),
                    .pos = g.pos,
                    .n_in = g.n_in,
                    .n_out = g.n_out,
                    .grid_rows = if (g.grid_rows == 0) gridRowsForBox(g.kind) else g.grid_rows,
                };
                n += 1;
            }
        }
        return n;
    }

    /// Maps a flat edge for display. An endpoint on a member inside a collapsed group is mapped to the box's port (synthetic handle + exposed
    /// index) as `visual`; `actual` is always the real connection (CableRef). An edge whose both ends are inside the same collapsed group is
    /// excluded (hidden). Runs every frame, over on the order of tens of edges.
    pub fn buildDisplayEdges(self: *const Ledger, flat_edges: []const Edge, out: []DisplayEdge) usize {
        // As with deriveExposed, the precondition is a flat edge (real handles only). Mixing in a synthetic handle
        // would make group_of[e.*_handle] below an out-of-bounds index, so it is rejected early as a guard against misuse.
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
                continue; // An edge entirely inside the same collapsed group is hidden
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

    /// Resolves a synthetic PortRef to a real member's PortRef via the expose table. A real (non-synthetic) handle is returned unchanged,
    /// so the caller can always route through resolvePort without pre-checking whether a handle is synthetic. An out-of-range gid/index yields null.
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

/// An insertion sort ordered ascending by (member,port); the count is at most MAX_EXPOSED=8.
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
// tests (no display/audio needed; test-patch)
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

/// A dummy for resolveExposedPort (no DynGraph; slotActive is always true, nOut is always >0).
const DynAlwaysOk = struct {
    fn slotActive(_: @This(), _: Handle) bool {
        return true;
    }
    fn nOut(_: @This(), _: Handle) u8 {
        return 4;
    }
};

// Case A: a synthetic handle and the real member handle point at the same exposed real port -> the return values match
// (the unit-level equivalent of the contract that updateViz does not republish when the real port ID is unchanged even if the display handle differs).
test "group: resolveExposedPort same real port via synthetic and member handle" {
    var l = Ledger{};
    const gid = l.alloc().?;
    l.assign(15, gid);
    var g = &l.groups[gid];
    g.n_out = 1;
    g.exposed_out[0] = .{ .member = 15, .port = 0, .is_input = false };

    const dyn = DynAlwaysOk{};
    const via_group = resolveExposedPort(&l, dyn, handleOfGroup(gid));
    const via_member = resolveExposedPort(&l, dyn, 15);
    try testing.expect(via_group >= 0);
    try testing.expectEqual(via_group, via_member);
    try testing.expectEqual(@as(i32, @intCast(15 * MAX_OUT_PORTS)), via_group);
}

// Case B: keeping the same synthetic handle but replacing exposed_out[0] -> the return value changes
// (the contract that a real port ID change is detected even when the handle is unchanged).
test "group: resolveExposedPort changes when exposed_out member/port swaps on same handle" {
    var l = Ledger{};
    const gid = l.alloc().?;
    l.assign(15, gid);
    l.assign(13, gid);
    var g = &l.groups[gid];
    g.n_out = 1;
    g.exposed_out[0] = .{ .member = 15, .port = 0, .is_input = false };

    const dyn = DynAlwaysOk{};
    const dh = handleOfGroup(gid);
    const before = resolveExposedPort(&l, dyn, dh);
    try testing.expectEqual(@as(i32, @intCast(15 * MAX_OUT_PORTS)), before);

    g.exposed_out[0] = .{ .member = 13, .port = 0, .is_input = false };
    const after = resolveExposedPort(&l, dyn, dh);
    try testing.expectEqual(@as(i32, @intCast(13 * MAX_OUT_PORTS)), after);
    try testing.expect(before != after);
}

test "group: alloc/assign/free lifecycle + auto-vanish on last unassign" {
    var l = Ledger{};
    const gid = l.alloc().?;
    try testing.expect(l.groups[gid].active);
    l.assign(10, gid);
    l.assign(11, gid);
    try testing.expectEqual(@as(?GroupId, gid), l.group_of[10]);
    l.unassign(10);
    try testing.expect(l.groups[gid].active); // One member still remains
    l.unassign(11);
    try testing.expect(!l.groups[gid].active); // Auto-freed at 0 members
    try testing.expectEqual(@as(?GroupId, null), l.group_of[10]);
}

test "group: assign ignores synthetic handle (1-level nesting guard)" {
    var l = Ledger{};
    const gid = l.alloc().?;
    l.assign(handleOfGroup(0), gid); // A synthetic handle is ignored (a group cannot be a member of another group)
    try testing.expectEqual(@as(?GroupId, null), l.group_of[0]);
}

/// A fixed test scenario equivalent to a DrumMachine: external clock(0) -> cdiv(10) -> seqK(11)/seqH(12) ->
/// kick(13)/hat(14) -> mix(15) -> external output(20). cdiv.in0 and mix.out0 are the explicit-template exposes.
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
            .{ .src_handle = 0, .src_out = 0, .dst_handle = 10, .dst_in = 0 }, // external clock -> cdiv.in0 (duplicates the template)
            .{ .src_handle = 10, .src_out = 0, .dst_handle = 11, .dst_in = 0 },
            .{ .src_handle = 10, .src_out = 0, .dst_handle = 12, .dst_in = 0 },
            .{ .src_handle = 11, .src_out = 0, .dst_handle = 13, .dst_in = 0 },
            .{ .src_handle = 12, .src_out = 0, .dst_handle = 14, .dst_in = 0 },
            .{ .src_handle = 13, .src_out = 0, .dst_handle = 15, .dst_in = 0 },
            .{ .src_handle = 14, .src_out = 0, .dst_handle = 15, .dst_in = 1 },
            .{ .src_handle = 15, .src_out = 0, .dst_handle = 20, .dst_in = 0 }, // mix.out0 -> external output (duplicates the template)
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
    // Additional boundary-crossing fan-out: kick(13)'s and hat(14)'s audio out each also connect directly to a separate external node (a real handle
    // below GROUP_HANDLE_BASE; here 30/31), since an output can fan out.
    es_buf[base.len] = .{ .src_handle = 14, .src_out = 0, .dst_handle = 31, .dst_in = 0 };
    es_buf[base.len + 1] = .{ .src_handle = 13, .src_out = 0, .dst_handle = 30, .dst_in = 0 };
    const edges = es_buf[0 .. base.len + 2];

    s.l.deriveExposed(s.gid, edges);
    const g = s.l.groups[s.gid];
    try testing.expectEqual(@as(u8, 3), g.n_out);
    try testing.expectEqual(@as(Handle, 15), g.exposed_out[0].member); // The template comes first
    try testing.expectEqual(@as(Handle, 13), g.exposed_out[1].member); // Automatic entries are ordered ascending by member
    try testing.expectEqual(@as(Handle, 14), g.exposed_out[2].member);
    try testing.expectEqual(@as(u8, 1), g.n_in); // The input side is unchanged
}

test "group: deriveExposed drops template entry whose member left the group" {
    var s = Scenario.init();
    s.l.unassign(15); // mix is individually removed (member count doesn't reach 0, so the group remains)
    // Using Scenario.flatEdges as-is, which includes the internal kick/hat->mix edges, would mean that once mix is no longer a member,
    // kick/hat's audio out would newly count as boundary-crossing (an automatic-expose fallback for a cable left dangling;
    // this is intended behavior and covered by a separate test). Here we only confirm that the template entry disappears,
    // so a minimal edge list excluding those two edges is used.
    const edges = [_]Edge{
        .{ .src_handle = 0, .src_out = 0, .dst_handle = 10, .dst_in = 0 }, // external clock -> cdiv.in0
        .{ .src_handle = 15, .src_out = 0, .dst_handle = 20, .dst_in = 0 }, // mix (non-member) -> external output
    };
    s.l.deriveExposed(s.gid, &edges);
    const g = s.l.groups[s.gid];
    try testing.expectEqual(@as(u8, 0), g.n_out); // Since mix is absent, the audio out expose disappears (both ends are non-members, so it is ignored)
    try testing.expectEqual(@as(u8, 1), g.n_in); // The cdiv side is unaffected
}

test "group: deriveExposed re-exposes a dangling internal port as boundary when its downstream member is removed" {
    var s = Scenario.init();
    s.l.unassign(15); // mix is individually removed
    var buf: [16]Edge = undefined;
    const edges = Scenario.flatEdges(&buf); // The original scenario as-is, including kick->mix / hat->mix
    s.l.deriveExposed(s.gid, edges);
    const g = s.l.groups[s.gid];
    // With mix no longer a member, kick(13)'s and hat(14)'s audio out newly count as boundary-crossing and are auto-exposed
    // (a fallback so the cable is not left dangling; ordered ascending by member).
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

    // collapsed (default): 6 members collapse into 1 box -> 3 nodes total: 0, box, 20.
    {
        const n = s.l.mapNodesForCollapsed(&flat, &out_buf);
        try testing.expectEqual(@as(usize, 3), n);
        var saw_box = false;
        for (out_buf[0..n]) |ng| {
            if (ng.handle == handleOfGroup(s.gid)) saw_box = true;
        }
        try testing.expect(saw_box);
    }
    // expanded: members appear as-is (no box) -> the original 8 nodes unchanged.
    {
        s.l.groups[s.gid].collapsed = false;
        const n = s.l.mapNodesForCollapsed(&flat, &out_buf);
        try testing.expectEqual(flat.len, n);
    }
}

test "group: grid_rows explicit value and kind fallback reach collapsed NodeGeom" {
    var s = Scenario.init();
    const flat = [_]NodeGeom{
        .{ .handle = 10, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1 },
        .{ .handle = 11, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1 },
    };
    var out: [4]NodeGeom = undefined;

    s.l.groups[s.gid].grid_rows = 3;
    var n = s.l.mapNodesForCollapsed(&flat, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u8, 3), out[0].grid_rows);

    s.l.groups[s.gid].grid_rows = 0;
    s.l.groups[s.gid].kind = .drum_machine;
    n = s.l.mapNodesForCollapsed(&flat, &out);
    try testing.expectEqual(@as(u8, 2), out[0].grid_rows);

    s.l.groups[s.gid].kind = .bass_machine;
    n = s.l.mapNodesForCollapsed(&flat, &out);
    try testing.expectEqual(@as(u8, 4), out[0].grid_rows);
}

test "group: buildDisplayEdges maps collapsed boundary to box index, hides internal edges, actual stays real" {
    var s = Scenario.init();
    var buf: [16]Edge = undefined;
    const edges = Scenario.flatEdges(&buf);
    s.l.deriveExposed(s.gid, edges); // Template only (no boundary-crossing additions)

    var out_buf: [16]DisplayEdge = undefined;
    const n = s.l.buildDisplayEdges(edges, &out_buf);
    try testing.expectEqual(@as(usize, 2), n); // The 6 internal edges are hidden; only the 2 boundary edges remain

    // The 0 -> cdiv.in0 boundary edge: visual dst is the box's exposed_in[0], actual is the real CableRef(10,0).
    const in_edge = for (out_buf[0..n]) |de| {
        if (de.visual.src_handle == 0) break de;
    } else unreachable;
    try testing.expectEqual(handleOfGroup(s.gid), in_edge.visual.dst_handle);
    try testing.expectEqual(@as(u8, 0), in_edge.visual.dst_in);
    try testing.expectEqual(@as(Handle, 10), in_edge.actual.dst_handle);
    try testing.expectEqual(@as(u8, 0), in_edge.actual.dst_in);

    // The mix.out0 -> 20 boundary edge: visual src is the box's exposed_out[0], actual is the real CableRef(20,0).
    const out_edge = for (out_buf[0..n]) |de| {
        if (de.visual.dst_handle == 20) break de;
    } else unreachable;
    try testing.expectEqual(handleOfGroup(s.gid), out_edge.visual.src_handle);
    try testing.expectEqual(@as(u8, 0), out_edge.visual.src_out);
    try testing.expectEqual(@as(Handle, 20), out_edge.actual.dst_handle);

    // expanded: no filtering or mapping (every edge passes through with its real handles unchanged).
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
    // Real PortRefs are unchanged.
    const real = PortRef{ .handle = 10, .is_input = true, .index = 0 };
    try testing.expectEqual(real, s.l.resolvePort(real).?);

    // synthetic in0 -> cdiv(10).in0.
    const synth_in = PortRef{ .handle = handleOfGroup(s.gid), .is_input = true, .index = 0 };
    const resolved_in = s.l.resolvePort(synth_in).?;
    try testing.expectEqual(@as(Handle, 10), resolved_in.handle);
    try testing.expect(resolved_in.is_input);
    try testing.expectEqual(@as(u8, 0), resolved_in.index);

    // synthetic out0 -> mix(15).out0.
    const synth_out = PortRef{ .handle = handleOfGroup(s.gid), .is_input = false, .index = 0 };
    const resolved_out = s.l.resolvePort(synth_out).?;
    try testing.expectEqual(@as(Handle, 15), resolved_out.handle);
    try testing.expect(!resolved_out.is_input);

    // An out-of-range index (exposed_in has only 1 entry).
    try testing.expectEqual(@as(?PortRef, null), s.l.resolvePort(.{ .handle = handleOfGroup(s.gid), .is_input = true, .index = 5 }));
    // An inactive gid.
    try testing.expectEqual(@as(?PortRef, null), s.l.resolvePort(.{ .handle = handleOfGroup(1), .is_input = true, .index = 0 }));
}

test "group: manual collapsed-box move keeps members aligned after expansion" {
    var layout_arr = [_]Vec2f{.{ .x = 0, .y = 0 }} ** GROUP_HANDLE_BASE;
    layout_arr[3] = .{ .x = 130, .y = 250 };
    layout_arr[7] = .{ .x = 290, .y = 205 };

    var ledger: Ledger = .{};
    ledger.groups[1] = .{
        .active = true,
        .collapsed = true,
        .kind = .drum_machine,
        .pos = .{ .x = 100, .y = 200 },
    };
    ledger.assign(3, 1);
    ledger.assign(7, 1);

    ledger.setPosAndTranslateMembers(1, .{ .x = 180, .y = 140 }, layout_arr[0..]);

    try testing.expectApproxEqAbs(@as(f32, 180), ledger.groups[1].pos.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 140), ledger.groups[1].pos.y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 210), layout_arr[3].x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 190), layout_arr[3].y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 370), layout_arr[7].x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 145), layout_arr[7].y, 1e-4);

    ledger.groups[1].collapsed = false;
    const flat = [_]NodeGeom{
        .{ .handle = 3, .pos = layout_arr[3], .n_in = 0, .n_out = 0 },
        .{ .handle = 7, .pos = layout_arr[7], .n_in = 0, .n_out = 0 },
    };
    var expanded: [2]NodeGeom = undefined;
    const n = ledger.mapNodesForCollapsed(&flat, &expanded);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectApproxEqAbs(@as(f32, 210), expanded[0].pos.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 190), expanded[0].pos.y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 370), expanded[1].pos.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 145), expanded[1].pos.y, 1e-4);
}

test "group: collapsed-box move preserves hand-made member offsets" {
    var layout_arr = [_]Vec2f{.{ .x = 0, .y = 0 }} ** GROUP_HANDLE_BASE;
    layout_arr[4] = .{ .x = 57, .y = 93 };
    layout_arr[9] = .{ .x = 122, .y = 27 };

    var ledger: Ledger = .{};
    ledger.groups[2] = .{
        .active = true,
        .collapsed = true,
        .kind = .drum_machine,
        .pos = .{ .x = 10, .y = 20 },
    };
    ledger.assign(4, 2);
    ledger.assign(9, 2);

    ledger.setPosAndTranslateMembers(2, .{ .x = 210, .y = 140 }, layout_arr[0..]);

    try testing.expectApproxEqAbs(@as(f32, 257), layout_arr[4].x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 213), layout_arr[4].y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 322), layout_arr[9].x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 147), layout_arr[9].y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 47), layout_arr[4].x - ledger.groups[2].pos.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 73), layout_arr[4].y - ledger.groups[2].pos.y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 112), layout_arr[9].x - ledger.groups[2].pos.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 7), layout_arr[9].y - ledger.groups[2].pos.y, 1e-4);

    ledger.groups[2].collapsed = false;
    const flat = [_]NodeGeom{
        .{ .handle = 4, .pos = layout_arr[4], .n_in = 0, .n_out = 0 },
        .{ .handle = 9, .pos = layout_arr[9], .n_in = 0, .n_out = 0 },
    };
    var expanded: [2]NodeGeom = undefined;
    const n = ledger.mapNodesForCollapsed(&flat, &expanded);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectApproxEqAbs(@as(f32, 257), expanded[0].pos.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 213), expanded[0].pos.y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 322), expanded[1].pos.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 147), expanded[1].pos.y, 1e-4);
}
