//! apps/patch の固定長 undo ペイロード store（TASK-106.4）。
//!
//! ホットパス: **イベント時のみ**（GUI 操作 / action 適用の主スレッド経路）。フレーム毎ループにも
//! RT（毎サンプル）経路にも一切乗らない。操作毎の allocator も mutex も持たず、固定容量の値型で完結する。
//! store 本体（~1.16MiB）のみ起動時に heap 確保する（App スタック常駐を避け Windows 既定 1MB stack を守る）。
//!
//! pattern/song は lofi.zig を import せず（synth/dsp を引き込む重依存を避けるため）、フィールド配置を
//! ミラーした `PatternSnap` / `SongSnap` を持つ。main.zig 側で `lofi.PatternCommand` ⇄ `PatternSnap`、
//! `lofi.SongData` ⇄ `SongSnap` を相互変換する。ModuleKind は `u8` タグとして保持する。

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

/// lofi.PatternCommand のフィールドをミラーした snapshot（rev/quantize_bar 含む）。
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

/// lofi.BassPhrase のミラー。
pub const BassPhraseSnap = struct {
    on: u16 = 0,
    accent: u16 = 0,
    slide: u16 = 0,
    deg: [16]i8 = [_]i8{0} ** 16,
};

/// lofi.Chain のミラー。
pub const ChainSnap = struct {
    entries: [MAX_CHAIN_LEN]u8 = [_]u8{0} ** MAX_CHAIN_LEN,
    len: u8 = 0,
};

/// lofi.SongRow のミラー。
pub const SongRowSnap = struct {
    kick: u8 = 0,
    hat: u8 = 0,
    clap: u8 = 0,
    bass: u8 = 0,
};

/// lofi.SongData のフィールドをミラーした snapshot（rev 含む）。
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
    /// 0 = transport (name only), 1 = node override
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
};

pub const PatchUndoEntry = struct {
    gen: u64 = 0, // 0 = empty slot
    payload: PatchUndoPayload = .{ .pattern = .{} },
};

pub const PatchUndoStore = struct {
    entries: [MAX_UNDO]PatchUndoEntry = [_]PatchUndoEntry{.{}} ** MAX_UNDO,
    next_gen: u64 = 1,
    allocator: std.mem.Allocator = undefined,

    pub fn create(allocator: std.mem.Allocator) !*PatchUndoStore {
        const self = try allocator.create(PatchUndoStore);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *PatchUndoStore) void {
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Push payload, return UndoRef (= gen). Overwrites oldest ring slot.
    pub fn push(self: *PatchUndoStore, payload: PatchUndoPayload) u64 {
        const gen = self.next_gen;
        self.next_gen += 1;
        if (self.next_gen == 0) self.next_gen = 1; // skip 0
        const slot: usize = @intCast(gen % MAX_UNDO);
        self.entries[slot] = .{ .gen = gen, .payload = payload };
        return gen;
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

/// NodeId 生存 / free handle 容量を app 側から注入するためのフック（main.zig の patchCanUndo 用）。
pub const NodePresence = struct {
    ctx: *anyopaque,
    exists: *const fn (*anyopaque, u64) bool,
    free_handles: usize,
};

/// payload 種別ごとの canUndo 判定（構造系の衝突・生存・容量）。
/// redo 後に新 id が付き、旧 id を指す古い undo payload はここが false を返す。
pub fn canUndoPayload(payload: PatchUndoPayload, presence: NodePresence) bool {
    switch (payload) {
        .add_node => |s| {
            // undo = remove: 対象が生きていること
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
            // undo = disconnect new + restore replaced: dst（と置換辺の端点）が生存していること
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
        .param => |s| {
            if (s.mode == 1) return presence.exists(presence.ctx, s.node_id);
            return true;
        },
        .pattern, .song, .seed, .mute => return true,
    }
}

/// group.MacroKind → u8 タグ（AddMacroSnap/RemoveMacroSnap の kind に格納する用）。
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

/// storage 用に rev をクリアした copy を返す（差分検知の基準を rev 非依存にする）。
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
    // store 全体が App スタックに乗ると Windows 既定 1MB と衝突する規模
    try std.testing.expect(@sizeOf(PatchUndoStore) > 512 * 1024);
    try std.testing.expect(@sizeOf(PatchUndoStore) < 2 * 1024 * 1024);
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
    // add→undo→redo で新 id が付き、旧 add_node / move の payload は死 id を指す
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
