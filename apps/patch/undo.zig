//! apps/patch: fixed-length undo payload store.
//!
//! Hot path: **event-time only** (the main-thread path for GUI operations / action application). Never runs on a
//! per-frame loop or an RT (per-sample) path. Holds no per-operation allocator or mutex; self-contained with fixed-capacity value types.
//! Only the store body (~1.16MiB) is heap-allocated at startup (avoids living on the App stack, preserving Windows' default 1MB stack).
//!
//! pattern/song does not import lofi.zig (to avoid pulling in the heavy synth/dsp dependency); it holds
//! `PatternSnap` / `SongSnap`, whose field layout mirrors it. main.zig converts between `lofi.PatternCommand` and `PatternSnap`,
//! and between `lofi.SongData` and `SongSnap`. ModuleKind is kept as a `u8` tag.

const std = @import("std");
const group = @import("group.zig");

pub const MAX_UNDO = 128; // == command.MAX_CMD_LOG
pub const MAX_UNDO_EDGES = 64;
pub const MAX_UNDO_PARAMS = 16;
pub const MAX_UNDO_NAME = 32;
pub const MAX_MACRO_MEMBERS = 12;

pub const MAX_DRUM_PHRASES = 64;
pub const MAX_BASS_PHRASES = 32;
pub const MAX_CHAINS = 32;
pub const MAX_CHAIN_LEN = 16;
pub const MAX_SONG_ROWS = 64;

/// Snapshot mirroring lofi.PatternCommand's fields (includes rev/quantize_bar).
pub const PatternSnap = struct {
    rev: u32 = 0,
    evolve: bool = true,
    kick_on: u16 = 0,
    kick_lock: bool = false,
    hat_on: u16 = 0,
    hat_lock: bool = false,
    clap_on: u16 = 0,
    clap_lock: bool = false,
    bass_on: u16 = 0,
    bass_accent: u16 = 0,
    bass_slide: u16 = 0,
    bass_deg: [16]i8 = [_]i8{0} ** 16,
    bass_lock: bool = false,
    quantize_bar: bool = false,
};

/// Mirror of lofi.BassPhrase.
pub const BassPhraseSnap = struct {
    on: u16 = 0,
    accent: u16 = 0,
    slide: u16 = 0,
    deg: [16]i8 = [_]i8{0} ** 16,
};

/// Mirror of lofi.Chain.
pub const ChainSnap = struct {
    entries: [MAX_CHAIN_LEN]u8 = [_]u8{0} ** MAX_CHAIN_LEN,
    len: u8 = 0,
};

/// Mirror of lofi.SongRow.
pub const SongRowSnap = struct {
    kick: u8 = 0,
    hat: u8 = 0,
    clap: u8 = 0,
    bass: u8 = 0,
};

/// Snapshot mirroring lofi.SongData's fields (includes rev).
pub const SongSnap = struct {
    rev: u32 = 0,
    phrases_kick: [MAX_DRUM_PHRASES]u16 = [_]u16{0} ** MAX_DRUM_PHRASES,
    phrases_hat: [MAX_DRUM_PHRASES]u16 = [_]u16{0} ** MAX_DRUM_PHRASES,
    phrases_clap: [MAX_DRUM_PHRASES]u16 = [_]u16{0} ** MAX_DRUM_PHRASES,
    phrases_bass: [MAX_BASS_PHRASES]BassPhraseSnap = [_]BassPhraseSnap{.{}} ** MAX_BASS_PHRASES,
    chains: [MAX_CHAINS]ChainSnap = [_]ChainSnap{.{}} ** MAX_CHAINS,
    rows: [MAX_SONG_ROWS]SongRowSnap = [_]SongRowSnap{.{}} ** MAX_SONG_ROWS,
    row_count: u8 = 0,
    loop: bool = false,
};

pub const ParamSnap = struct {
    name_buf: [MAX_UNDO_NAME]u8 = undefined,
    name_len: u8 = 0,
    value_kind: u8 = 0, // 0=scalar 1=choice
    value: u32 = 0,

    pub fn name(self: *const ParamSnap) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn setName(self: *ParamSnap, n: []const u8) void {
        const len = @min(n.len, MAX_UNDO_NAME);
        @memcpy(self.name_buf[0..len], n[0..len]);
        self.name_len = @intCast(len);
    }
};

pub const EdgeSnap = struct {
    src_id: u64 = 0,
    src_out: u8 = 0,
    dst_id: u64 = 0,
    dst_in: u8 = 0,
};

pub const NodeSnap = struct {
    id: u64 = 0,
    kind_tag: u8 = 0, // @intFromEnum(ModuleKind)
    x: f32 = 0,
    y: f32 = 0,
    params: [MAX_UNDO_PARAMS]ParamSnap = [_]ParamSnap{.{}} ** MAX_UNDO_PARAMS,
    param_count: u8 = 0,
    /// optional GENR role index; 0xFF = none
    gen_role: u8 = 0xFF,
};

pub const MuteSnap = struct {
    track: u8, // track = MuteTrack tag
    was_muted: bool,
};

pub const SeedSnap = struct {
    base_seed: u64,
    notation_seed: u64,
    notation_counter: u32,
};

pub const ParamValueSnap = struct {
    /// 0 = legacy transport alias (removed; undo restore is a no-op), 1 = node override
    mode: u8 = 0,
    node_id: u64 = 0,
    name_buf: [MAX_UNDO_NAME]u8 = undefined,
    name_len: u8 = 0,
    value_bits: u32 = 0, // f32 bitcast or choice
    value_kind: u8 = 0,

    pub fn name(self: *const ParamValueSnap) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn setName(self: *ParamValueSnap, n: []const u8) void {
        const len = @min(n.len, MAX_UNDO_NAME);
        @memcpy(self.name_buf[0..len], n[0..len]);
        self.name_len = @intCast(len);
    }
};

pub const AddNodeSnap = struct {
    id: u64,
    kind_tag: u8,
    x: f32,
    y: f32,
};

pub const MoveNodeSnap = struct {
    id: u64,
    x: f32,
    y: f32,
};

/// One layout target's before-position for multi-target undo (auto_layout / selected / move_layout).
/// `target` is a stable node id, or `GROUP_TARGET_TAG | group.identity` for a group box
/// (not the slot GroupId — identities are never reused after free).
/// Fixed 16 bytes so the dynamic payload is dense; the undo union holds only LayoutRef.
pub const LayoutTargetSnap = struct {
    target: u64 = 0,
    x: f32 = 0,
    y: f32 = 0,
};

/// High bit of LayoutTargetSnap.target marks a group identity (low 63 bits = Group.identity).
/// Real stable node ids must not set this bit (asserted when encoding).
pub const GROUP_TARGET_TAG: u64 = 1 << 63;

/// Union payload for a multi-target layout undo: points at a dynamic block on PatchUndoStore.
/// Fixed 16 bytes; coordinates live in a per-slot heap block sized to the changed target count.
pub const LayoutRef = struct {
    generation: u64 = 0,
    slot: u8 = 0,
    count: u16 = 0,
    _pad: u32 = 0,
};

pub fn encodeRealLayoutTarget(id: u64) u64 {
    std.debug.assert((id & GROUP_TARGET_TAG) == 0);
    return id;
}

/// `identity` is `Group.identity` (never the slot GroupId).
pub fn encodeGroupLayoutTarget(identity: u64) u64 {
    std.debug.assert(identity != 0);
    std.debug.assert((identity & GROUP_TARGET_TAG) == 0);
    return GROUP_TARGET_TAG | identity;
}

pub fn isGroupLayoutTarget(target: u64) bool {
    return (target & GROUP_TARGET_TAG) != 0;
}

/// Low 63 bits: node id, or group.identity when the group tag is set.
pub fn layoutTargetId(target: u64) u64 {
    return target & ~GROUP_TARGET_TAG;
}

pub const ConnectSnap = struct {
    new_edge: EdgeSnap = .{},
    /// edges detached from dst input before connect (0 or 1 typically)
    replaced: [4]EdgeSnap = [_]EdgeSnap{.{}} ** 4,
    replaced_count: u8 = 0,
};

pub const DisconnectSnap = struct {
    edge: EdgeSnap = .{},
};

pub const RemoveNodeSnap = struct {
    node: NodeSnap = .{},
    edges: [MAX_UNDO_EDGES]EdgeSnap = [_]EdgeSnap{.{}} ** MAX_UNDO_EDGES,
    edge_count: u8 = 0,
    /// group membership before remove; 0xFF = none
    group_id: u8 = 0xFF,
    group_kind: u8 = 0,
};

pub const AddMacroSnap = struct {
    kind: u8 = 0, // MacroKind
    x: f32 = 0,
    y: f32 = 0,
    members: [MAX_MACRO_MEMBERS]u64 = [_]u64{0} ** MAX_MACRO_MEMBERS, // NodeIds
    member_count: u8 = 0,
    group_id: u8 = 0xFF,
};

pub const RemoveMacroSnap = struct {
    kind: u8 = 0,
    x: f32 = 0,
    y: f32 = 0,
    collapsed: bool = true,
    grid_rows: u8 = 0,
    group_id: u8 = 0xFF,
    members: [MAX_MACRO_MEMBERS]NodeSnap = [_]NodeSnap{.{}} ** MAX_MACRO_MEMBERS,
    member_count: u8 = 0,
    edges: [MAX_UNDO_EDGES]EdgeSnap = [_]EdgeSnap{.{}} ** MAX_UNDO_EDGES,
    edge_count: u8 = 0,
};

pub const PatchUndoPayload = union(enum) {
    pattern: PatternSnap,
    song: SongSnap,
    seed: SeedSnap,
    mute: MuteSnap,
    param: ParamValueSnap,
    add_node: AddNodeSnap,
    remove_node: RemoveNodeSnap,
    connect: ConnectSnap,
    disconnect: DisconnectSnap,
    move_node: MoveNodeSnap,
    add_macro: AddMacroSnap,
    remove_macro: RemoveMacroSnap,
    /// Multi-target layout before-positions (block lives on PatchUndoStore.layout_blocks).
    layout: LayoutRef,
};

pub const PatchUndoEntry = struct {
    gen: u64 = 0, // 0 = empty slot
    payload: PatchUndoPayload = .{ .pattern = .{} },
};

/// Per-ring-slot descriptor for a dynamic layout snapshot block (not the coordinates themselves).
const LayoutBlockDescriptor = struct {
    ptr: ?[*]LayoutTargetSnap = null,
    count: u16 = 0,
    capacity: u16 = 0,
};

pub const PatchUndoStore = struct {
    entries: [MAX_UNDO]PatchUndoEntry = [_]PatchUndoEntry{.{}} ** MAX_UNDO,
    /// Parallel to entries: heap block for `.layout` payloads. Freed on overwrite / destroy.
    layout_blocks: [MAX_UNDO]LayoutBlockDescriptor = [_]LayoutBlockDescriptor{.{}} ** MAX_UNDO,
    next_gen: u64 = 1,
    allocator: std.mem.Allocator = undefined,

    pub fn create(allocator: std.mem.Allocator) !*PatchUndoStore {
        const self = try allocator.create(PatchUndoStore);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *PatchUndoStore) void {
        var i: usize = 0;
        while (i < MAX_UNDO) : (i += 1) {
            self.freeLayoutSlot(i);
        }
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn freeLayoutSlot(self: *PatchUndoStore, slot: usize) void {
        const b = &self.layout_blocks[slot];
        if (b.ptr) |p| {
            self.allocator.free(p[0..b.capacity]);
        }
        b.* = .{};
    }

    fn allocGenSlot(self: *PatchUndoStore) struct { gen: u64, slot: usize } {
        const gen = self.next_gen;
        self.next_gen += 1;
        if (self.next_gen == 0) self.next_gen = 1; // skip 0
        const slot: usize = @intCast(gen % MAX_UNDO);
        return .{ .gen = gen, .slot = slot };
    }

    /// Push payload, return UndoRef (= gen). Overwrites oldest ring slot.
    /// Clears any layout block previously owned by that slot.
    pub fn push(self: *PatchUndoStore, payload: PatchUndoPayload) u64 {
        // Layout payloads must use pushLayout so the dynamic block is owned correctly.
        std.debug.assert(payload != .layout);
        const gs = self.allocGenSlot();
        self.freeLayoutSlot(gs.slot);
        self.entries[gs.slot] = .{ .gen = gs.gen, .payload = payload };
        return gs.gen;
    }

    /// Push a multi-target layout before-snapshot. Allocates a block sized to `snaps.len`.
    /// On OutOfMemory the store is unchanged (caller must not apply the coordinate change).
    /// `snaps.len == 0` is rejected (no undo entry for a no-op layout).
    pub fn pushLayout(self: *PatchUndoStore, snaps: []const LayoutTargetSnap) error{ OutOfMemory, Empty }!u64 {
        if (snaps.len == 0) return error.Empty;
        if (snaps.len > std.math.maxInt(u16)) return error.OutOfMemory;

        // Allocate first so a failure leaves the ring untouched.
        const copy = try self.allocator.alloc(LayoutTargetSnap, snaps.len);
        errdefer self.allocator.free(copy);
        @memcpy(copy, snaps);

        const gs = self.allocGenSlot();
        self.freeLayoutSlot(gs.slot);
        self.layout_blocks[gs.slot] = .{
            .ptr = copy.ptr,
            .count = @intCast(snaps.len),
            .capacity = @intCast(snaps.len),
        };
        const lref = LayoutRef{
            .generation = gs.gen,
            .slot = @intCast(gs.slot),
            .count = @intCast(snaps.len),
        };
        self.entries[gs.slot] = .{ .gen = gs.gen, .payload = .{ .layout = lref } };
        return gs.gen;
    }

    /// Resolve the dynamic before-positions for a layout ref (null if stale / mismatch).
    pub fn layoutSnaps(self: *const PatchUndoStore, ref: LayoutRef) ?[]const LayoutTargetSnap {
        if (ref.slot >= MAX_UNDO or ref.count == 0) return null;
        const e = &self.entries[ref.slot];
        if (e.gen != ref.generation) return null;
        if (e.payload != .layout) return null;
        if (e.payload.layout.generation != ref.generation or e.payload.layout.count != ref.count) return null;
        const b = self.layout_blocks[ref.slot];
        if (b.ptr == null or b.count != ref.count) return null;
        return b.ptr.?[0..b.count];
    }

    pub fn get(self: *const PatchUndoStore, ref: u64) ?*const PatchUndoEntry {
        if (ref == 0) return null;
        const e = &self.entries[@as(usize, @intCast(ref % MAX_UNDO))];
        if (e.gen != ref) return null;
        return e;
    }

    pub fn getMut(self: *PatchUndoStore, ref: u64) ?*PatchUndoEntry {
        if (ref == 0) return null;
        const e = &self.entries[@as(usize, @intCast(ref % MAX_UNDO))];
        if (e.gen != ref) return null;
        return e;
    }

    /// true iff get(ref) non-null
    pub fn valid(self: *const PatchUndoStore, ref: u64) bool {
        return self.get(ref) != null;
    }
};

/// Hook for the app side to inject NodeId liveness / free-handle capacity (used by main.zig's patchCanUndo).
pub const NodePresence = struct {
    ctx: *anyopaque,
    exists: *const fn (*anyopaque, u64) bool,
    free_handles: usize,
};

/// canUndo judgment per payload kind (structural conflicts, liveness, capacity).
/// After redo assigns a new id, an old undo payload pointing at the old id returns false here.
pub fn canUndoPayload(payload: PatchUndoPayload, presence: NodePresence) bool {
    switch (payload) {
        .add_node => |s| {
            // undo = remove: the target must be alive
            return presence.exists(presence.ctx, s.id);
        },
        .remove_node => |s| {
            if (presence.exists(presence.ctx, s.node.id)) return false;
            if (presence.free_handles < 1) return false;
            return true;
        },
        .add_macro => |s| {
            if (s.member_count == 0) return false;
            var mi: u8 = 0;
            while (mi < s.member_count) : (mi += 1) {
                if (!presence.exists(presence.ctx, s.members[mi])) return false;
            }
            return true;
        },
        .remove_macro => |s| {
            if (s.member_count == 0) return false;
            var mi: u8 = 0;
            while (mi < s.member_count) : (mi += 1) {
                if (presence.exists(presence.ctx, s.members[mi].id)) return false;
            }
            if (presence.free_handles < s.member_count) return false;
            return true;
        },
        .connect => |s| {
            // undo = disconnect new + restore replaced: dst (and the endpoint of the replaced edge) must be alive
            if (!presence.exists(presence.ctx, s.new_edge.dst_id)) return false;
            var ri: u8 = 0;
            while (ri < s.replaced_count) : (ri += 1) {
                const e = s.replaced[ri];
                if (!presence.exists(presence.ctx, e.src_id)) return false;
                if (!presence.exists(presence.ctx, e.dst_id)) return false;
            }
            return true;
        },
        .disconnect => |s| {
            if (!presence.exists(presence.ctx, s.edge.src_id)) return false;
            if (!presence.exists(presence.ctx, s.edge.dst_id)) return false;
            return true;
        },
        .move_node => |s| return presence.exists(presence.ctx, s.id),
        .layout => |r| {
            // Detailed restorable check needs the dynamic block (see PatchUndoStore.canUndoLayout).
            return r.count > 0 and r.generation != 0;
        },
        .param => |s| {
            if (s.mode == 1) return presence.exists(presence.ctx, s.node_id);
            return true;
        },
        .pattern, .song, .seed, .mute => return true,
    }
}

/// Whether a layout undo can restore at least one still-present target.
/// Missing real nodes / freed group identities are skipped at apply time (no stale write).
/// `groupIdentityLive(ctx, identity)` must resolve Group.identity (not slot id).
pub fn canUndoLayout(self: *const PatchUndoStore, ref: LayoutRef, presence: NodePresence, groupIdentityLive: *const fn (*anyopaque, u64) bool) bool {
    const snaps = self.layoutSnaps(ref) orelse return false;
    for (snaps) |s| {
        if (isGroupLayoutTarget(s.target)) {
            if (groupIdentityLive(presence.ctx, layoutTargetId(s.target))) return true;
        } else if (presence.exists(presence.ctx, s.target)) {
            return true;
        }
    }
    return false;
}

/// group.MacroKind → u8 tag (stored in AddMacroSnap/RemoveMacroSnap's kind).
pub fn macroKindTag(kind: group.MacroKind) u8 {
    return @intFromEnum(kind);
}

/// PatternSnap equality for no-op detection (ignore rev and quantize_bar).
pub fn patternContentEql(a: PatternSnap, b: PatternSnap) bool {
    var x = a;
    var y = b;
    x.rev = 0;
    y.rev = 0;
    x.quantize_bar = false;
    y.quantize_bar = false;
    return std.meta.eql(x, y);
}

/// SongSnap equality ignoring rev.
pub fn songContentEql(a: SongSnap, b: SongSnap) bool {
    var x = a;
    var y = b;
    x.rev = 0;
    y.rev = 0;
    return std.meta.eql(x, y);
}

/// Returns a copy with rev cleared for storage (making the diff-detection baseline rev-independent).
pub fn patternForStore(p: PatternSnap) PatternSnap {
    var c = p;
    c.rev = 0;
    return c;
}

pub fn songForStore(s: SongSnap) SongSnap {
    var c = s;
    c.rev = 0;
    return c;
}

test "entry size and capacity bounds" {
    const size = @sizeOf(PatchUndoEntry);
    try std.testing.expect(size < 64 * 1024);
    try std.testing.expectEqual(@as(usize, 128), MAX_UNDO);
    // The scale at which the whole store landing on the App stack would collide with Windows' default 1MB
    try std.testing.expect(@sizeOf(PatchUndoStore) > 512 * 1024);
    try std.testing.expect(@sizeOf(PatchUndoStore) < 2 * 1024 * 1024);
}

test "layout snap and ref are 16 bytes; layout union arm is LayoutRef only" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(LayoutTargetSnap));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(LayoutRef));
    // Pin the union arm itself: layout holds only LayoutRef (not a MAX_MODULES-sized array).
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(@FieldType(PatchUndoPayload, "layout")));
    // Fixed store region excludes dynamic layout payload bytes.
    const fixed_entries = @sizeOf([MAX_UNDO]PatchUndoEntry);
    const fixed_blocks = @sizeOf([MAX_UNDO]LayoutBlockDescriptor);
    try std.testing.expect(fixed_entries + fixed_blocks < 2 * 1024 * 1024);
    // Default display upper bound (48 modules + 8 groups) stays under the args budget.
    try std.testing.expect(@sizeOf(LayoutTargetSnap) * 56 < 4096);
}

test "PatchUndoStore create destroy on heap" {
    const store = try PatchUndoStore.create(std.testing.allocator);
    defer store.destroy();
    const ref = store.push(.{ .pattern = .{ .kick_on = 1 } });
    try std.testing.expect(store.valid(ref));
}

test "remove_node structural payload round-trip" {
    var store = PatchUndoStore{};
    var snap: RemoveNodeSnap = .{};
    snap.node.id = 42;
    snap.node.kind_tag = 3;
    snap.node.x = 10.5;
    snap.node.y = -2.0;
    snap.node.gen_role = 0xFF;
    snap.node.params[0].setName("cutoff");
    snap.node.params[0].value_kind = 0;
    snap.node.params[0].value = @bitCast(@as(f32, 0.7));
    snap.node.param_count = 1;
    snap.edges[0] = .{ .src_id = 1, .src_out = 0, .dst_id = 42, .dst_in = 1 };
    snap.edges[1] = .{ .src_id = 42, .src_out = 0, .dst_id = 7, .dst_in = 0 };
    snap.edge_count = 2;
    snap.group_id = 3;
    snap.group_kind = 1;

    const ref = store.push(.{ .remove_node = snap });
    const got = store.get(ref).?.payload.remove_node;
    try std.testing.expectEqual(@as(u64, 42), got.node.id);
    try std.testing.expectEqual(@as(u8, 1), got.node.param_count);
    try std.testing.expectEqualStrings("cutoff", got.node.params[0].name());
    try std.testing.expectEqual(@as(u8, 2), got.edge_count);
    try std.testing.expectEqual(@as(u64, 1), got.edges[0].src_id);
    try std.testing.expectEqual(@as(u64, 7), got.edges[1].dst_id);
    try std.testing.expectEqual(@as(u8, 3), got.group_id);
}

test "remove_macro member array round-trip" {
    var store = PatchUndoStore{};
    var snap: RemoveMacroSnap = .{
        .kind = 0,
        .x = 100,
        .y = 200,
        .collapsed = true,
        .grid_rows = 2,
        .group_id = 1,
        .member_count = 3,
        .edge_count = 1,
    };
    snap.members[0] = .{ .id = 10, .kind_tag = 1, .x = 1, .y = 2 };
    snap.members[1] = .{ .id = 11, .kind_tag = 2, .x = 3, .y = 4 };
    snap.members[2] = .{ .id = 12, .kind_tag = 3, .x = 5, .y = 6 };
    snap.edges[0] = .{ .src_id = 10, .src_out = 0, .dst_id = 11, .dst_in = 0 };

    const ref = store.push(.{ .remove_macro = snap });
    const got = store.get(ref).?.payload.remove_macro;
    try std.testing.expectEqual(@as(u8, 3), got.member_count);
    try std.testing.expectEqual(@as(u64, 10), got.members[0].id);
    try std.testing.expectEqual(@as(u64, 12), got.members[2].id);
    try std.testing.expectEqual(@as(u8, 1), got.edge_count);
    try std.testing.expectEqual(@as(u64, 11), got.edges[0].dst_id);
}

const AliveSet = struct {
    ids: []const u64,
    free: usize,

    fn exists(ctx: *anyopaque, id: u64) bool {
        const self: *const AliveSet = @ptrCast(@alignCast(ctx));
        for (self.ids) |x| if (x == id) return true;
        return false;
    }
};

test "canUndoPayload survival checks for connect disconnect move param" {
    var alive = AliveSet{ .ids = &[_]u64{ 1, 2 }, .free = 8 };
    const presence = NodePresence{ .ctx = &alive, .exists = AliveSet.exists, .free_handles = alive.free };

    try std.testing.expect(canUndoPayload(.{ .connect = .{
        .new_edge = .{ .src_id = 1, .dst_id = 2, .src_out = 0, .dst_in = 0 },
    } }, presence));
    try std.testing.expect(!canUndoPayload(.{ .connect = .{
        .new_edge = .{ .src_id = 1, .dst_id = 99, .src_out = 0, .dst_in = 0 },
    } }, presence));

    try std.testing.expect(canUndoPayload(.{ .disconnect = .{
        .edge = .{ .src_id = 1, .dst_id = 2, .src_out = 0, .dst_in = 0 },
    } }, presence));
    try std.testing.expect(!canUndoPayload(.{ .disconnect = .{
        .edge = .{ .src_id = 1, .dst_id = 99, .src_out = 0, .dst_in = 0 },
    } }, presence));

    try std.testing.expect(canUndoPayload(.{ .move_node = .{ .id = 1, .x = 0, .y = 0 } }, presence));
    try std.testing.expect(!canUndoPayload(.{ .move_node = .{ .id = 99, .x = 0, .y = 0 } }, presence));

    var param_live = ParamValueSnap{ .mode = 1, .node_id = 1 };
    param_live.setName("cutoff");
    try std.testing.expect(canUndoPayload(.{ .param = param_live }, presence));
    var param_dead = ParamValueSnap{ .mode = 1, .node_id = 99 };
    param_dead.setName("cutoff");
    try std.testing.expect(!canUndoPayload(.{ .param = param_dead }, presence));
    // transport mode needs no node
    try std.testing.expect(canUndoPayload(.{ .param = .{ .mode = 0 } }, presence));
}

test "canUndoPayload rejects stale id after fresh-id redo scenario" {
    // After add→undo→redo, a new id is assigned, and the old add_node / move payload points at the dead id
    var alive = AliveSet{ .ids = &[_]u64{100}, .free = 8 }; // only new id after redo
    const presence = NodePresence{ .ctx = &alive, .exists = AliveSet.exists, .free_handles = alive.free };
    try std.testing.expect(!canUndoPayload(.{ .add_node = .{ .id = 31, .kind_tag = 0, .x = 0, .y = 0 } }, presence));
    try std.testing.expect(!canUndoPayload(.{ .move_node = .{ .id = 31, .x = 0, .y = 0 } }, presence));
    try std.testing.expect(canUndoPayload(.{ .add_node = .{ .id = 100, .kind_tag = 0, .x = 0, .y = 0 } }, presence));
}

test "ring overflow invalidates oldest" {
    var store = PatchUndoStore{};
    var refs: [MAX_UNDO]u64 = undefined;
    for (0..MAX_UNDO) |i| {
        refs[i] = store.push(.{ .pattern = .{} });
    }
    for (refs) |r| try std.testing.expect(store.valid(r));

    const extra = store.push(.{ .pattern = .{} });
    try std.testing.expect(store.valid(extra));
    try std.testing.expect(!store.valid(refs[0]));
}

test "gen mismatch invalidates ref" {
    var store = PatchUndoStore{};
    const r = store.push(.{ .pattern = .{} });
    try std.testing.expect(store.valid(r));

    store.entries[@as(usize, @intCast(r % MAX_UNDO))].gen = r + 1000;
    try std.testing.expect(!store.valid(r));
    try std.testing.expect(store.get(r) == null);
    try std.testing.expect(store.getMut(r) == null);
    try std.testing.expect(store.get(0) == null);
}

test "patternContentEql ignores rev and quantize_bar" {
    var a = PatternSnap{ .kick_on = 0x00FF };
    var b = a;
    a.rev = 1;
    b.rev = 99;
    a.quantize_bar = false;
    b.quantize_bar = true;
    try std.testing.expect(patternContentEql(a, b));

    b.kick_on = 0x0F0F;
    try std.testing.expect(!patternContentEql(a, b));
}

test "songContentEql ignores rev" {
    var a = SongSnap{ .row_count = 3 };
    a.rows[0] = .{ .kick = 1, .hat = 2, .clap = 3, .bass = 4 };
    var b = a;
    a.rev = 1;
    b.rev = 42;
    try std.testing.expect(songContentEql(a, b));

    b.loop = true;
    try std.testing.expect(!songContentEql(a, b));
}

test "ParamSnap setName truncates to MAX_UNDO_NAME" {
    var p = ParamSnap{};
    const long = "x" ** 100;
    p.setName(long);
    try std.testing.expectEqual(@as(u8, MAX_UNDO_NAME), p.name_len);
    try std.testing.expectEqual(@as(usize, MAX_UNDO_NAME), p.name().len);

    var q = ParamSnap{};
    q.setName("cutoff");
    try std.testing.expectEqualStrings("cutoff", q.name());
}

test "layout target encode: real vs group identity tag" {
    const real = encodeRealLayoutTarget(0x12);
    try std.testing.expect(!isGroupLayoutTarget(real));
    try std.testing.expectEqual(@as(u64, 0x12), layoutTargetId(real));
    // Group wire/undo key is Group.identity (never the slot GroupId).
    const g = encodeGroupLayoutTarget(3);
    try std.testing.expect(isGroupLayoutTarget(g));
    try std.testing.expectEqual(@as(u64, 3), layoutTargetId(g));
    try std.testing.expect((g & GROUP_TARGET_TAG) != 0);
}

test "pushLayout stores only changed targets and overwrites free old block" {
    const store = try PatchUndoStore.create(std.testing.allocator);
    defer store.destroy();

    const snaps1 = [_]LayoutTargetSnap{
        .{ .target = encodeRealLayoutTarget(1), .x = 10, .y = 20 },
        .{ .target = encodeGroupLayoutTarget(2), .x = 30, .y = 40 },
    };
    const ref1 = try store.pushLayout(&snaps1);
    try std.testing.expect(store.valid(ref1));
    const got1 = store.layoutSnaps(store.get(ref1).?.payload.layout).?;
    try std.testing.expectEqual(@as(usize, 2), got1.len);
    try std.testing.expectEqual(@as(f32, 10), got1[0].x);
    try std.testing.expectEqual(@as(f32, 40), got1[1].y);

    // Empty is rejected (no undo entry for zero-change layout).
    try std.testing.expectError(error.Empty, store.pushLayout(&.{}));

    // Fill the ring past slot of ref1 so it is overwritten and the block freed.
    var i: usize = 0;
    while (i < MAX_UNDO) : (i += 1) {
        _ = try store.pushLayout(&[_]LayoutTargetSnap{.{ .target = encodeRealLayoutTarget(@intCast(i + 3)), .x = 0, .y = 0 }});
    }
    try std.testing.expect(!store.valid(ref1));
    try std.testing.expect(store.layoutSnaps(.{ .generation = ref1, .slot = @intCast(ref1 % MAX_UNDO), .count = 2 }) == null);
}

test "pushLayout then non-layout push frees layout block" {
    const store = try PatchUndoStore.create(std.testing.allocator);
    defer store.destroy();
    const ref = try store.pushLayout(&[_]LayoutTargetSnap{.{ .target = encodeRealLayoutTarget(7), .x = 1, .y = 2 }});
    try std.testing.expect(store.layoutSnaps(store.get(ref).?.payload.layout) != null);
    // Same slot will eventually be reused; push MAX_UNDO regular entries to force overwrite of ref's slot.
    var i: usize = 0;
    while (i < MAX_UNDO) : (i += 1) {
        _ = store.push(.{ .pattern = .{} });
    }
    try std.testing.expect(!store.valid(ref));
}

test "canUndoLayout requires at least one live target (identity-keyed groups)" {
    const store = try PatchUndoStore.create(std.testing.allocator);
    defer store.destroy();
    const snaps = [_]LayoutTargetSnap{
        .{ .target = encodeRealLayoutTarget(1), .x = 0, .y = 0 },
        .{ .target = encodeGroupLayoutTarget(2), .x = 0, .y = 0 }, // identity=2
    };
    const ref = try store.pushLayout(&snaps);
    const lref = store.get(ref).?.payload.layout;

    var alive = AliveSet{ .ids = &[_]u64{1}, .free = 8 };
    const presence = NodePresence{ .ctx = &alive, .exists = AliveSet.exists, .free_handles = alive.free };
    const groupLive = struct {
        fn go(ctx: *anyopaque, identity: u64) bool {
            _ = ctx;
            return identity == 2;
        }
    }.go;
    try std.testing.expect(canUndoLayout(store, lref, presence, groupLive));

    alive.ids = &[_]u64{}; // no real nodes
    // Freed identity (slot may be reused with a different identity) → not live.
    const groupNone = struct {
        fn go(_: *anyopaque, _: u64) bool {
            return false;
        }
    }.go;
    try std.testing.expect(!canUndoLayout(store, lref, presence, groupNone));
}

test "canUndoLayout rejects stale group identity after slot reuse" {
    const store = try PatchUndoStore.create(std.testing.allocator);
    defer store.destroy();
    // Old entry keyed by identity 1; after free+realloc the live group has identity 2.
    const snaps = [_]LayoutTargetSnap{
        .{ .target = encodeGroupLayoutTarget(1), .x = 10, .y = 20 },
    };
    const ref = try store.pushLayout(&snaps);
    const lref = store.get(ref).?.payload.layout;
    var alive = AliveSet{ .ids = &[_]u64{}, .free = 8 };
    const presence = NodePresence{ .ctx = &alive, .exists = AliveSet.exists, .free_handles = alive.free };
    const onlyNew = struct {
        fn go(_: *anyopaque, identity: u64) bool {
            return identity == 2; // new group in same slot
        }
    }.go;
    try std.testing.expect(!canUndoLayout(store, lref, presence, onlyNew));
}

test "pushLayout OOM leaves store unchanged" {
    var fail_once = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const store = try PatchUndoStore.create(std.testing.allocator);
    defer {
        store.allocator = std.testing.allocator;
        store.destroy();
    }
    store.allocator = fail_once.allocator();
    const snaps = [_]LayoutTargetSnap{
        .{ .target = encodeRealLayoutTarget(1), .x = 1, .y = 2 },
    };
    try std.testing.expectError(error.OutOfMemory, store.pushLayout(&snaps));
    // No entry was reserved (next_gen still 1, slot empty).
    try std.testing.expectEqual(@as(u64, 1), store.next_gen);
    try std.testing.expect(store.get(1) == null);
}
