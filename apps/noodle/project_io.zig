//! apps/noodle: unified project serialization.
//!
//! Chunks placed in a libs/serde versioned container (magic = `NDL1`, schema_version=2):
//!   - SPRM: scalar Params (the existing MPRJ flat packer)
//!   - PTRN: grid/303 pattern (PatternPayload, 33B)
//!   - SEED: base_seed + notation_seed + notation_counter (20B)
//!   - SONG: Phrase/Chain/Song (1890B)
//!   - NODE x N / EDGE x M: the raw graph (the existing PTCG 11B/6B layout)
//!   - NPRM: per-node DSP parameters (descriptor name + scalar/choice; an optional chunk)
//!   - NIDM: next_node_id (schema 2)
//!   - NREF: the saved_handle <-> NodeId mapping (schema 2)
//!   - LEDG: the entire group.Ledger (fixed length)
//!   - GENR: LofiPatch's generation-role -> saved-handle mapping (unified format only)
//!
//! The writer emits only NDL1. The reader auto-detects NDL1 plus the legacy MDLP / MPRJ / PTCG formats.
//! Schema 1 (no NIDM/NREF) falls back to deterministic numbering by node appearance order.
//!
//! **ModuleKind compatibility**: the enum ordinal is part of the persisted format. New kinds may only be appended at the end.
//! Reordering, deleting, or renaming is forbidden. An unknown ordinal is skipped per NODE (for PTCG compatibility).
//!
//! **Avoiding a circular import**: Params/SongData/LofiPatch are not imported.
//! The Ledger is passed as group.Ledger; the graph is passed as graph_io's NodeEntry/EdgeEntry.
//!
//! Hot-path declaration: encode/decode/save/load run **only at event time**. They never touch the RT path.

const std = @import("std");
const serde = @import("serde");
const modular = @import("modular");
const pattern_io = @import("pattern_io.zig");
const graph_io = @import("graph_io.zig");
const group = @import("group.zig");

/// 'NDL1', a little-endian u32: the format's own name plus its generation, so that renaming
/// the tool never renames the file format (a lesson from the magic this one replaces).
pub const magic: u32 = @as(u32, 'N') | (@as(u32, 'D') << 8) | (@as(u32, 'L') << 16) | (@as(u32, '1') << 24);
/// The legacy MPRJ magic (read compatibility only; the writer never emits it).
pub const mprj_magic: u32 = @as(u32, 'M') | (@as(u32, 'P') << 8) | (@as(u32, 'R') << 16) | (@as(u32, 'J') << 24);
/// schema 2 means NIDM/NREF are present. The reader also accepts schema 1 (falling back to numbering).
pub const schema_version: u16 = 2;
pub const schema_version_v1: u16 = 1;

const TAG_SPRM: [4]u8 = "SPRM".*;
const TAG_PTRN: [4]u8 = "PTRN".*;
const TAG_SEED: [4]u8 = "SEED".*;
const TAG_SONG: [4]u8 = "SONG".*;
const TAG_NODE: [4]u8 = "NODE".*;
const TAG_EDGE: [4]u8 = "EDGE".*;
const TAG_NPRM: [4]u8 = "NPRM".*;
const TAG_NIDM: [4]u8 = "NIDM".*;
const TAG_NREF: [4]u8 = "NREF".*;
const TAG_LEDG: [4]u8 = "LEDG".*;
const TAG_GENR: [4]u8 = "GENR".*;

pub const NPRM_VERSION: u16 = 1;
/// The DynGraph frame (group.GROUP_HANDLE_BASE == modular.dyn.MAX_MODULES).
pub const MAX_NPRM_NODES: usize = group.GROUP_HANDLE_BASE;
/// A practical upper bound on the descriptor count (on the same scale as params.zig's uniqueness check).
pub const MAX_PARAMS_PER_NODE: usize = 64;
pub const VALUE_KIND_SCALAR: u8 = 0;
pub const VALUE_KIND_CHOICE: u8 = 1;

pub const NodeId = graph_io.NodeId;

/// One NREF entry: the save-time runtime handle <-> the stable NodeId.
pub const NodeIdRef = struct {
    saved_handle: u16,
    id: NodeId,
};

pub const FormatKind = enum { noodle, mdlp, mprj, ptcg };

pub const DecodeError = error{
    MissingSprm,
    MissingPtrn,
    MissingSeed,
    MissingSong,
    MissingLedg,
    MissingGenr,
    CorruptSprm,
    CorruptPtrn,
    CorruptSeed,
    CorruptSong,
    CorruptNode,
    CorruptEdge,
    CorruptLedger,
    CorruptGenr,
    CorruptNprm,
    CorruptNidm,
    CorruptNref,
    DuplicateChunk,
    DuplicateNprmParamName,
    DuplicateNodeId,
    UnsupportedSchemaVersion,
    UnsupportedNprmVersion,
    NonFiniteField,
    BadMagic,
    WrongValueKind,
    OutOfRange,
    ChoiceIndexOutOfRange,
};

pub const NodeEntry = graph_io.NodeEntry;
pub const EdgeEntry = graph_io.EdgeEntry;
pub const Handle = graph_io.Handle;

/// The sentinel for a nonexistent role (DynGraph.isActive(0xffff)==false).
pub const INVALID_ROLE_HANDLE: u16 = 0xffff;

/// The fixed order of LofiPatch generation roles (the GENR payload). New roles may only be appended at the end.
pub const GenRole = enum(u8) {
    clock,
    kick_seq,
    hat_seq,
    clap_seq,
    bass_seq,
    kick,
    hat,
    clap,
    pad_div,
    pad_eu,
    pad,
    ambient_turing,
    ambient_quant,
    ambient_lfo,
    ambient_random,
    bass_perc,
    vco,
    vcf,
    vca,
    nonkick_mixer,
    sidechain,
    master_mixer,
    master_vcf,
    saturator,
    bitcrusher,
    delay_fx,
    reverb_fx,
    vinyl,
    wow,
    output,

    pub const count: usize = @typeInfo(GenRole).@"enum".fields.len;
};

pub const GenRoleHandles = struct {
    handles: [GenRole.count]u16 = [_]u16{INVALID_ROLE_HANDLE} ** GenRole.count,

    pub fn get(self: GenRoleHandles, role: GenRole) u16 {
        return self.handles[@intFromEnum(role)];
    }
    pub fn set(self: *GenRoleHandles, role: GenRole, h: u16) void {
        self.handles[@intFromEnum(role)] = h;
    }
};

/// One NPRM parameter (name has the caller's lifetime during encode; inside Decoded it is gpa-owned).
pub const NodeParam = struct {
    name: []const u8,
    value_kind: u8,
    /// scalar: f32 bit pattern / choice: index as u32
    value: u32,
};

/// One node's worth of NPRM.
pub const NodeParamRecord = struct {
    saved_handle: u16,
    params: []const NodeParam,
};

const NODE_SIZE: usize = 11;
const EDGE_SIZE: usize = 6;
const PTRN_SIZE: usize = 33;
const SEED_SIZE: usize = 20;
const SONG_SIZE: usize = 1890;
const GENR_SIZE: usize = GenRole.count * 2;
// LEDG: group_of[GROUP_HANDLE_BASE]u8 + groups[MAX_GROUPS] * (header + 8*13*2 exposed).
//
// **Write format (v2)**: header includes Group.identity (u64 LE). This is what packLedger emits.
// **Legacy read format (v1)**: 16B header without identity. The reader accepts both sizes and
// assigns fresh monotonic identities on v1 load (same rule as Ledger.alloc). N via -Dmax-modules.
const LEDG_EXPOSED_BYTES: usize = group.MAX_EXPOSED * 13 * 2;
/// Current write format: common 16B fields + identity u64.
const LEDG_GROUP_HEADER_V2: usize = 24;
const LEDG_GROUP_SIZE_V2: usize = LEDG_GROUP_HEADER_V2 + LEDG_EXPOSED_BYTES;
const LEDG_SIZE_V2: usize = group.GROUP_HANDLE_BASE + group.MAX_GROUPS * LEDG_GROUP_SIZE_V2;
/// Legacy read-only format (pre-identity). Never written by the current packer.
const LEDG_GROUP_HEADER_V1: usize = 16;
const LEDG_GROUP_SIZE_V1: usize = LEDG_GROUP_HEADER_V1 + LEDG_EXPOSED_BYTES;
const LEDG_SIZE_V1: usize = group.GROUP_HANDLE_BASE + group.MAX_GROUPS * LEDG_GROUP_SIZE_V1;

// Aliases for the write path (call sites keep using LEDG_SIZE / LEDG_GROUP_HEADER).
const LEDG_GROUP_HEADER: usize = LEDG_GROUP_HEADER_V2;
const LEDG_GROUP_SIZE: usize = LEDG_GROUP_SIZE_V2;
const LEDG_SIZE: usize = LEDG_SIZE_V2;

comptime {
    if (GenRole.count != 30) @compileError("GENR role count changed; update schema or tests");
    // Self-consistency of the size formulas (N-independent shape).
    if (LEDG_SIZE_V2 != group.GROUP_HANDLE_BASE + group.MAX_GROUPS * LEDG_GROUP_SIZE_V2)
        @compileError("LEDG v2 size formula mismatch");
    if (LEDG_SIZE_V1 != group.GROUP_HANDLE_BASE + group.MAX_GROUPS * LEDG_GROUP_SIZE_V1)
        @compileError("LEDG v1 size formula mismatch");
    if (LEDG_GROUP_SIZE_V2 != 232)
        @compileError("LEDG v2 per-group size mismatch (write format)");
    if (LEDG_GROUP_SIZE_V1 != 224)
        @compileError("LEDG v1 per-group size mismatch (legacy read format)");
    // Fixed known sizes at default N=48.
    if (group.GROUP_HANDLE_BASE == 48 and LEDG_SIZE_V2 != 1904)
        @compileError("LEDG v2 size mismatch for default N=48");
    if (group.GROUP_HANDLE_BASE == 48 and LEDG_SIZE_V1 != 1840)
        @compileError("LEDG v1 size mismatch for default N=48");
}

// -- scalar Params packer --

fn fieldSize(comptime T: type) usize {
    if (T == f32 or T == usize) return 4;
    if (T == bool) return 1;
    @compileError("project_io: unsupported field type " ++ @typeName(T));
}

fn packedSize(comptime T: type) usize {
    comptime var total: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |f| total += comptime fieldSize(f.type);
    return total;
}

fn packInto(comptime T: type, value: T, out: []u8) void {
    comptime var off: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const v = @field(value, f.name);
        if (f.type == f32) {
            std.mem.writeInt(u32, out[off..][0..4], @as(u32, @bitCast(v)), .little);
        } else if (f.type == usize) {
            std.mem.writeInt(u32, out[off..][0..4], @as(u32, @intCast(v)), .little);
        } else if (f.type == bool) {
            out[off] = @intFromBool(v);
        } else {
            @compileError("project_io: unsupported field type " ++ @typeName(f.type));
        }
        off += comptime fieldSize(f.type);
    }
}

fn unpackFrom(comptime T: type, bytes: []const u8) error{NonFiniteField}!T {
    var value: T = .{};
    comptime var off: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (f.type == f32) {
            const v: f32 = @bitCast(std.mem.readInt(u32, bytes[off..][0..4], .little));
            if (!std.math.isFinite(v)) return error.NonFiniteField;
            @field(value, f.name) = v;
        } else if (f.type == usize) {
            @field(value, f.name) = @intCast(std.mem.readInt(u32, bytes[off..][0..4], .little));
        } else if (f.type == bool) {
            @field(value, f.name) = bytes[off] != 0;
        } else {
            @compileError("project_io: unsupported field type " ++ @typeName(f.type));
        }
        off += comptime fieldSize(f.type);
    }
    return value;
}

// ── PTRN ─────────────────────────────────────────────────────────────────────

fn packPattern(p: pattern_io.PatternPayload, out: *[PTRN_SIZE]u8) void {
    out[0] = @intFromBool(p.evolve);
    std.mem.writeInt(u16, out[1..3], p.kick_on, .little);
    out[3] = @intFromBool(p.kick_lock);
    std.mem.writeInt(u16, out[4..6], p.hat_on, .little);
    out[6] = @intFromBool(p.hat_lock);
    std.mem.writeInt(u16, out[7..9], p.clap_on, .little);
    out[9] = @intFromBool(p.clap_lock);
    std.mem.writeInt(u16, out[10..12], p.bass_on, .little);
    std.mem.writeInt(u16, out[12..14], p.bass_accent, .little);
    std.mem.writeInt(u16, out[14..16], p.bass_slide, .little);
    out[16] = @intFromBool(p.bass_lock);
    for (p.bass_deg, 0..) |d, i| out[17 + i] = @bitCast(d);
}

fn unpackPattern(bytes: []const u8) pattern_io.PatternPayload {
    var p: pattern_io.PatternPayload = .{};
    p.evolve = bytes[0] != 0;
    p.kick_on = std.mem.readInt(u16, bytes[1..3], .little);
    p.kick_lock = bytes[3] != 0;
    p.hat_on = std.mem.readInt(u16, bytes[4..6], .little);
    p.hat_lock = bytes[6] != 0;
    p.clap_on = std.mem.readInt(u16, bytes[7..9], .little);
    p.clap_lock = bytes[9] != 0;
    p.bass_on = std.mem.readInt(u16, bytes[10..12], .little);
    p.bass_accent = std.mem.readInt(u16, bytes[12..14], .little);
    p.bass_slide = std.mem.readInt(u16, bytes[14..16], .little);
    p.bass_lock = bytes[16] != 0;
    for (&p.bass_deg, 0..) |*d, i| d.* = @bitCast(bytes[17 + i]);
    return p;
}

// ── SEED ─────────────────────────────────────────────────────────────────────

pub const SeedPayload = struct {
    base_seed: u64 = 0,
    notation_seed: u64 = 0,
    notation_counter: u32 = 0,
};

fn packSeed(s: SeedPayload, out: *[SEED_SIZE]u8) void {
    std.mem.writeInt(u64, out[0..8], s.base_seed, .little);
    std.mem.writeInt(u64, out[8..16], s.notation_seed, .little);
    std.mem.writeInt(u32, out[16..20], s.notation_counter, .little);
}

fn unpackSeed(bytes: []const u8) SeedPayload {
    return .{
        .base_seed = std.mem.readInt(u64, bytes[0..8], .little),
        .notation_seed = std.mem.readInt(u64, bytes[8..16], .little),
        .notation_counter = std.mem.readInt(u32, bytes[16..20], .little),
    };
}

// ── SONG ─────────────────────────────────────────────────────────────────────

pub const MAX_DRUM_PHRASES: usize = 64;
pub const MAX_BASS_PHRASES: usize = 32;
pub const MAX_CHAINS: usize = 32;
pub const MAX_CHAIN_LEN: usize = 16;
pub const MAX_SONG_ROWS: usize = 64;

pub const BassPhrasePayload = struct {
    on: u16 = 0,
    accent: u16 = 0,
    slide: u16 = 0,
    deg: [16]i8 = [_]i8{0} ** 16,
};

pub const ChainPayload = struct {
    entries: [MAX_CHAIN_LEN]u8 = [_]u8{0} ** MAX_CHAIN_LEN,
    len: u8 = 0,
};

pub const SongRowPayload = struct {
    kick: u8 = 0,
    hat: u8 = 0,
    clap: u8 = 0,
    bass: u8 = 0,
};

pub const SongPayload = struct {
    phrases_kick: [MAX_DRUM_PHRASES]u16 = [_]u16{0} ** MAX_DRUM_PHRASES,
    phrases_hat: [MAX_DRUM_PHRASES]u16 = [_]u16{0} ** MAX_DRUM_PHRASES,
    phrases_clap: [MAX_DRUM_PHRASES]u16 = [_]u16{0} ** MAX_DRUM_PHRASES,
    phrases_bass: [MAX_BASS_PHRASES]BassPhrasePayload = [_]BassPhrasePayload{.{}} ** MAX_BASS_PHRASES,
    chains: [MAX_CHAINS]ChainPayload = [_]ChainPayload{.{}} ** MAX_CHAINS,
    rows: [MAX_SONG_ROWS]SongRowPayload = [_]SongRowPayload{.{}} ** MAX_SONG_ROWS,
    row_count: u8 = 0,
    loop: bool = false,
};

fn packSong(s: SongPayload, out: *[SONG_SIZE]u8) void {
    var off: usize = 0;
    for (s.phrases_kick) |v| {
        std.mem.writeInt(u16, out[off..][0..2], v, .little);
        off += 2;
    }
    for (s.phrases_hat) |v| {
        std.mem.writeInt(u16, out[off..][0..2], v, .little);
        off += 2;
    }
    for (s.phrases_clap) |v| {
        std.mem.writeInt(u16, out[off..][0..2], v, .little);
        off += 2;
    }
    for (s.phrases_bass) |bp| {
        std.mem.writeInt(u16, out[off..][0..2], bp.on, .little);
        off += 2;
        std.mem.writeInt(u16, out[off..][0..2], bp.accent, .little);
        off += 2;
        std.mem.writeInt(u16, out[off..][0..2], bp.slide, .little);
        off += 2;
        for (bp.deg) |d| {
            out[off] = @bitCast(d);
            off += 1;
        }
    }
    for (s.chains) |ch| {
        @memcpy(out[off..][0..MAX_CHAIN_LEN], &ch.entries);
        off += MAX_CHAIN_LEN;
        out[off] = ch.len;
        off += 1;
    }
    for (s.rows) |row| {
        out[off] = row.kick;
        out[off + 1] = row.hat;
        out[off + 2] = row.clap;
        out[off + 3] = row.bass;
        off += 4;
    }
    out[off] = s.row_count;
    out[off + 1] = @intFromBool(s.loop);
    off += 2;
    std.debug.assert(off == SONG_SIZE);
}

fn unpackSong(bytes: []const u8) SongPayload {
    var s: SongPayload = .{};
    var off: usize = 0;
    for (&s.phrases_kick) |*v| {
        v.* = std.mem.readInt(u16, bytes[off..][0..2], .little);
        off += 2;
    }
    for (&s.phrases_hat) |*v| {
        v.* = std.mem.readInt(u16, bytes[off..][0..2], .little);
        off += 2;
    }
    for (&s.phrases_clap) |*v| {
        v.* = std.mem.readInt(u16, bytes[off..][0..2], .little);
        off += 2;
    }
    for (&s.phrases_bass) |*bp| {
        bp.on = std.mem.readInt(u16, bytes[off..][0..2], .little);
        off += 2;
        bp.accent = std.mem.readInt(u16, bytes[off..][0..2], .little);
        off += 2;
        bp.slide = std.mem.readInt(u16, bytes[off..][0..2], .little);
        off += 2;
        for (&bp.deg) |*d| {
            d.* = @bitCast(bytes[off]);
            off += 1;
        }
    }
    for (&s.chains) |*ch| {
        @memcpy(&ch.entries, bytes[off..][0..MAX_CHAIN_LEN]);
        off += MAX_CHAIN_LEN;
        ch.len = bytes[off];
        off += 1;
    }
    for (&s.rows) |*row| {
        row.kick = bytes[off];
        row.hat = bytes[off + 1];
        row.clap = bytes[off + 2];
        row.bass = bytes[off + 3];
        off += 4;
    }
    s.row_count = bytes[off];
    s.loop = bytes[off + 1] != 0;
    return s;
}

fn validateSong(s: SongPayload, loop_raw: u8) error{CorruptSong}!void {
    if (loop_raw > 1) return error.CorruptSong;
    if (s.row_count > MAX_SONG_ROWS) return error.CorruptSong;
    for (s.chains) |ch| {
        if (ch.len > MAX_CHAIN_LEN) return error.CorruptSong;
        var i: u8 = 0;
        while (i < ch.len) : (i += 1) {
            if (ch.entries[i] >= MAX_DRUM_PHRASES) return error.CorruptSong;
        }
    }
    for (s.rows) |row| {
        if (row.kick >= MAX_CHAINS or row.hat >= MAX_CHAINS or
            row.clap >= MAX_CHAINS or row.bass >= MAX_CHAINS)
        {
            return error.CorruptSong;
        }
    }
}

// -- NODE / EDGE (reusing the PTCG layout) --

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

fn moduleKindFromU8(v: u8) ?graph_io.ModuleKind {
    inline for (@typeInfo(graph_io.ModuleKind).@"enum".fields) |f| {
        if (f.value == v) return @enumFromInt(v);
    }
    return null;
}

fn unpackNode(payload: []const u8) error{ CorruptNode, NonFiniteField }!?NodeEntry {
    if (payload.len != NODE_SIZE) return error.CorruptNode;
    const handle = std.mem.readInt(u16, payload[0..2], .little);
    const kind = moduleKindFromU8(payload[2]) orelse return null;
    const x: f32 = @bitCast(std.mem.readInt(u32, payload[3..7], .little));
    const y: f32 = @bitCast(std.mem.readInt(u32, payload[7..11], .little));
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return error.NonFiniteField;
    return .{ .handle = handle, .kind = kind, .x = x, .y = y };
}

fn unpackEdge(payload: []const u8) error{CorruptEdge}!EdgeEntry {
    if (payload.len != EDGE_SIZE) return error.CorruptEdge;
    return .{
        .src_handle = std.mem.readInt(u16, payload[0..2], .little),
        .src_out = payload[2],
        .dst_handle = std.mem.readInt(u16, payload[3..5], .little),
        .dst_in = payload[5],
    };
}

// ── LEDG ─────────────────────────────────────────────────────────────────────

fn readBool01(b: u8) error{CorruptLedger}!bool {
    if (b > 1) return error.CorruptLedger;
    return b != 0;
}

fn macroKindFromU8(v: u8) error{CorruptLedger}!group.MacroKind {
    inline for (@typeInfo(group.MacroKind).@"enum".fields) |f| {
        if (f.value == v) return @enumFromInt(v);
    }
    return error.CorruptLedger;
}

fn packExposed(ep: group.ExposedPort, out: *[13]u8) void {
    std.mem.writeInt(u16, out[0..2], ep.member, .little);
    out[2] = ep.port;
    out[3] = @intFromBool(ep.is_input);
    @memcpy(out[4..12], &ep.label);
    out[12] = ep.label_len;
}

fn unpackExposed(bytes: []const u8) error{CorruptLedger}!group.ExposedPort {
    if (bytes.len < 13) return error.CorruptLedger;
    const member = std.mem.readInt(u16, bytes[0..2], .little);
    if (member >= group.GROUP_HANDLE_BASE) return error.CorruptLedger;
    const is_input = try readBool01(bytes[3]);
    var label: [8]u8 = undefined;
    @memcpy(&label, bytes[4..12]);
    const label_len = bytes[12];
    if (label_len > 8) return error.CorruptLedger;
    return .{
        .member = member,
        .port = bytes[2],
        .is_input = is_input,
        .label = label,
        .label_len = label_len,
    };
}

fn packLedger(ledger: *const group.Ledger, out: *[LEDG_SIZE]u8) void {
    var off: usize = 0;
    for (ledger.group_of) |gid_opt| {
        out[off] = if (gid_opt) |gid| gid else 0xff;
        off += 1;
    }
    for (ledger.groups) |g| {
        out[off] = @intFromBool(g.active);
        out[off + 1] = @intFromEnum(g.kind);
        out[off + 2] = @intFromBool(g.collapsed);
        out[off + 3] = g.grid_rows;
        std.mem.writeInt(u32, out[off + 4 ..][0..4], @bitCast(g.pos.x), .little);
        std.mem.writeInt(u32, out[off + 8 ..][0..4], @bitCast(g.pos.y), .little);
        out[off + 12] = g.n_in;
        out[off + 13] = g.n_out;
        out[off + 14] = g.template_n_in;
        out[off + 15] = g.template_n_out;
        std.mem.writeInt(u64, out[off + 16 ..][0..8], g.identity, .little);
        off += LEDG_GROUP_HEADER;
        for (g.exposed_in) |ep| {
            var buf: [13]u8 = undefined;
            packExposed(ep, &buf);
            @memcpy(out[off..][0..13], &buf);
            off += 13;
        }
        for (g.exposed_out) |ep| {
            var buf: [13]u8 = undefined;
            packExposed(ep, &buf);
            @memcpy(out[off..][0..13], &buf);
            off += 13;
        }
    }
    std.debug.assert(off == LEDG_SIZE);
}

/// Unpack LEDG payload. Accepts **v2** (write format, with identity) and **v1** (legacy, no identity).
/// On v1, active groups receive fresh monotonic identities (same rule as `Ledger.alloc`).
fn unpackLedger(bytes: []const u8) error{ CorruptLedger, NonFiniteField }!group.Ledger {
    const has_identity: bool = if (bytes.len == LEDG_SIZE_V2)
        true
    else if (bytes.len == LEDG_SIZE_V1)
        false
    else
        return error.CorruptLedger;
    const group_header: usize = if (has_identity) LEDG_GROUP_HEADER_V2 else LEDG_GROUP_HEADER_V1;

    var ledger: group.Ledger = .{};
    var off: usize = 0;
    for (&ledger.group_of) |*go| {
        const v = bytes[off];
        off += 1;
        if (v == 0xff) {
            go.* = null;
        } else if (v < group.MAX_GROUPS) {
            go.* = v;
        } else {
            return error.CorruptLedger;
        }
    }
    var max_identity: u64 = 0;
    for (&ledger.groups) |*g| {
        g.active = try readBool01(bytes[off]);
        g.kind = try macroKindFromU8(bytes[off + 1]);
        g.collapsed = try readBool01(bytes[off + 2]);
        g.grid_rows = bytes[off + 3];
        const x: f32 = @bitCast(std.mem.readInt(u32, bytes[off + 4 ..][0..4], .little));
        const y: f32 = @bitCast(std.mem.readInt(u32, bytes[off + 8 ..][0..4], .little));
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return error.NonFiniteField;
        g.pos = .{ .x = x, .y = y };
        g.n_in = bytes[off + 12];
        g.n_out = bytes[off + 13];
        g.template_n_in = bytes[off + 14];
        g.template_n_out = bytes[off + 15];
        if (has_identity) {
            g.identity = std.mem.readInt(u64, bytes[off + 16 ..][0..8], .little);
            if (g.active) {
                if (g.identity == 0) return error.CorruptLedger;
                if (g.identity > max_identity) max_identity = g.identity;
            } else {
                g.identity = 0;
            }
        } else {
            // v1: identities assigned after the loop (monotonic, collision-free within the file).
            g.identity = 0;
        }
        if (g.n_in > group.MAX_EXPOSED or g.n_out > group.MAX_EXPOSED) return error.CorruptLedger;
        if (g.template_n_in > g.n_in or g.template_n_out > g.n_out) return error.CorruptLedger;
        off += group_header;
        for (&g.exposed_in) |*ep| {
            ep.* = try unpackExposed(bytes[off..][0..13]);
            off += 13;
        }
        for (&g.exposed_out) |*ep| {
            ep.* = try unpackExposed(bytes[off..][0..13]);
            off += 13;
        }
        if (g.active) {
            // An exposed member is consistent with group_of (only the first n_* entries are validated)
            var i: u8 = 0;
            while (i < g.n_in) : (i += 1) {
                const m = g.exposed_in[i].member;
                const gid = ledger.group_of[m] orelse return error.CorruptLedger;
                _ = gid;
            }
            i = 0;
            while (i < g.n_out) : (i += 1) {
                const m = g.exposed_out[i].member;
                _ = ledger.group_of[m] orelse return error.CorruptLedger;
            }
        }
    }
    std.debug.assert(off == bytes.len);

    if (has_identity) {
        ledger.next_identity = max_identity + 1;
        if (ledger.next_identity == 0) ledger.next_identity = 1;
    } else {
        // Same allocation rule as Ledger.alloc: start at 1, never 0, no reuse within this ledger.
        var next: u64 = 1;
        for (&ledger.groups) |*g| {
            if (!g.active) continue;
            g.identity = next;
            next += 1;
            if (next == 0) next = 1;
        }
        ledger.next_identity = next;
    }
    // The group referenced by group_of must be active
    for (ledger.group_of) |gid_opt| {
        if (gid_opt) |gid| {
            if (!ledger.groups[gid].active) return error.CorruptLedger;
        }
    }
    return ledger;
}

/// Pack legacy v1 LEDG (no identity field). Used only by fixed fixtures / migration tests.
/// The production writer always uses packLedger (v2).
fn packLedgerV1(ledger: *const group.Ledger, out: *[LEDG_SIZE_V1]u8) void {
    var off: usize = 0;
    for (ledger.group_of) |gid_opt| {
        out[off] = if (gid_opt) |gid| gid else 0xff;
        off += 1;
    }
    for (ledger.groups) |g| {
        out[off] = @intFromBool(g.active);
        out[off + 1] = @intFromEnum(g.kind);
        out[off + 2] = @intFromBool(g.collapsed);
        out[off + 3] = g.grid_rows;
        std.mem.writeInt(u32, out[off + 4 ..][0..4], @bitCast(g.pos.x), .little);
        std.mem.writeInt(u32, out[off + 8 ..][0..4], @bitCast(g.pos.y), .little);
        out[off + 12] = g.n_in;
        out[off + 13] = g.n_out;
        out[off + 14] = g.template_n_in;
        out[off + 15] = g.template_n_out;
        off += LEDG_GROUP_HEADER_V1;
        for (g.exposed_in) |ep| {
            var buf: [13]u8 = undefined;
            packExposed(ep, &buf);
            @memcpy(out[off..][0..13], &buf);
            off += 13;
        }
        for (g.exposed_out) |ep| {
            var buf: [13]u8 = undefined;
            packExposed(ep, &buf);
            @memcpy(out[off..][0..13], &buf);
            off += 13;
        }
    }
    std.debug.assert(off == LEDG_SIZE_V1);
}

/// Remaps the Ledger using an old-handle -> new-handle mapping (slots, order, and coordinates are left unchanged).
pub fn remapLedger(src: *const group.Ledger, mapping: *const [group.GROUP_HANDLE_BASE]?Handle) error{CorruptLedger}!group.Ledger {
    var out: group.Ledger = .{};
    out.groups = src.groups;
    for (src.group_of, 0..) |gid_opt, old_h| {
        if (gid_opt) |gid| {
            const nh = mapping[old_h] orelse return error.CorruptLedger;
            if (nh >= group.GROUP_HANDLE_BASE) return error.CorruptLedger;
            out.group_of[nh] = gid;
        }
    }
    for (&out.groups) |*g| {
        if (!g.active) continue;
        var i: u8 = 0;
        while (i < g.n_in) : (i += 1) {
            const old = g.exposed_in[i].member;
            if (old >= group.GROUP_HANDLE_BASE) return error.CorruptLedger;
            g.exposed_in[i].member = mapping[old] orelse return error.CorruptLedger;
        }
        i = 0;
        while (i < g.n_out) : (i += 1) {
            const old = g.exposed_out[i].member;
            if (old >= group.GROUP_HANDLE_BASE) return error.CorruptLedger;
            g.exposed_out[i].member = mapping[old] orelse return error.CorruptLedger;
        }
    }
    return out;
}

// ── GENR ─────────────────────────────────────────────────────────────────────

fn packGenr(g: GenRoleHandles, out: *[GENR_SIZE]u8) void {
    for (g.handles, 0..) |h, i| {
        std.mem.writeInt(u16, out[i * 2 ..][0..2], h, .little);
    }
}

fn unpackGenr(bytes: []const u8) error{CorruptGenr}!GenRoleHandles {
    if (bytes.len != GENR_SIZE) return error.CorruptGenr;
    var g: GenRoleHandles = .{};
    for (&g.handles, 0..) |*h, i| {
        h.* = std.mem.readInt(u16, bytes[i * 2 ..][0..2], .little);
    }
    return g;
}

/// Remaps GENR handles via the mapping. INVALID is left unchanged; an unmapped handle is downgraded to INVALID.
pub fn remapGenr(src: GenRoleHandles, mapping: *const [group.GROUP_HANDLE_BASE]?Handle) GenRoleHandles {
    var out: GenRoleHandles = .{};
    for (src.handles, 0..) |h, i| {
        if (h == INVALID_ROLE_HANDLE) {
            out.handles[i] = INVALID_ROLE_HANDLE;
        } else if (h < group.GROUP_HANDLE_BASE) {
            out.handles[i] = mapping[h] orelse INVALID_ROLE_HANDLE;
        } else {
            out.handles[i] = INVALID_ROLE_HANDLE;
        }
    }
    return out;
}

// ── NPRM ─────────────────────────────────────────────────────────────────────

fn nprmPayloadSize(records: []const NodeParamRecord) usize {
    var size: usize = 4; // version + node_count
    for (records) |rec| {
        size += 4; // saved_handle + param_count
        for (rec.params) |p| {
            size += 1 + p.name.len + 1 + 4; // name_len + name + value_kind + value
        }
    }
    return size;
}

fn packNprm(records: []const NodeParamRecord, out: []u8) void {
    std.debug.assert(out.len == nprmPayloadSize(records));
    std.debug.assert(records.len <= MAX_NPRM_NODES);
    std.mem.writeInt(u16, out[0..2], NPRM_VERSION, .little);
    std.mem.writeInt(u16, out[2..4], @intCast(records.len), .little);
    var off: usize = 4;
    for (records) |rec| {
        std.debug.assert(rec.params.len <= MAX_PARAMS_PER_NODE);
        std.mem.writeInt(u16, out[off..][0..2], rec.saved_handle, .little);
        off += 2;
        std.mem.writeInt(u16, out[off..][0..2], @intCast(rec.params.len), .little);
        off += 2;
        for (rec.params) |p| {
            std.debug.assert(p.name.len <= 255);
            out[off] = @intCast(p.name.len);
            off += 1;
            @memcpy(out[off..][0..p.name.len], p.name);
            off += p.name.len;
            out[off] = p.value_kind;
            off += 1;
            std.mem.writeInt(u32, out[off..][0..4], p.value, .little);
            off += 4;
        }
    }
    std.debug.assert(off == out.len);
}

fn freeNodeParamRecords(gpa: std.mem.Allocator, records: []const NodeParamRecord) void {
    for (records) |rec| {
        for (rec.params) |p| gpa.free(p.name);
        gpa.free(@constCast(rec.params));
    }
    if (records.len != 0) gpa.free(@constCast(records));
}

fn unpackNprm(gpa: std.mem.Allocator, payload: []const u8) ![]NodeParamRecord {
    if (payload.len < 4) return error.CorruptNprm;
    const version = std.mem.readInt(u16, payload[0..2], .little);
    if (version != NPRM_VERSION) return error.UnsupportedNprmVersion;
    const node_count = std.mem.readInt(u16, payload[2..4], .little);
    if (node_count > MAX_NPRM_NODES) return error.CorruptNprm;
    if (node_count == 0) {
        if (payload.len != 4) return error.CorruptNprm;
        return &.{};
    }

    var records: std.ArrayList(NodeParamRecord) = .empty;
    errdefer {
        for (records.items) |rec| {
            for (rec.params) |p| gpa.free(p.name);
            gpa.free(@constCast(rec.params));
        }
        records.deinit(gpa);
    }

    var off: usize = 4;
    var i: usize = 0;
    while (i < node_count) : (i += 1) {
        if (off + 4 > payload.len) return error.CorruptNprm;
        const saved_handle = std.mem.readInt(u16, payload[off..][0..2], .little);
        off += 2;
        const param_count = std.mem.readInt(u16, payload[off..][0..2], .little);
        off += 2;
        if (param_count > MAX_PARAMS_PER_NODE) return error.CorruptNprm;

        var params: std.ArrayList(NodeParam) = .empty;
        errdefer {
            for (params.items) |p| gpa.free(p.name);
            params.deinit(gpa);
        }

        var pi: usize = 0;
        while (pi < param_count) : (pi += 1) {
            if (off >= payload.len) return error.CorruptNprm;
            const name_len: usize = payload[off];
            off += 1;
            if (name_len == 0 or off + name_len + 1 + 4 > payload.len) return error.CorruptNprm;
            const name = try gpa.dupe(u8, payload[off..][0..name_len]);
            errdefer gpa.free(name);
            off += name_len;
            const value_kind = payload[off];
            off += 1;
            if (value_kind != VALUE_KIND_SCALAR and value_kind != VALUE_KIND_CHOICE) return error.CorruptNprm;
            const value = std.mem.readInt(u32, payload[off..][0..4], .little);
            off += 4;
            if (value_kind == VALUE_KIND_SCALAR) {
                const f: f32 = @bitCast(value);
                if (!std.math.isFinite(f)) return error.NonFiniteField;
            }
            for (params.items) |prev| {
                if (std.mem.eql(u8, prev.name, name)) return error.DuplicateNprmParamName;
            }
            try params.append(gpa, .{ .name = name, .value_kind = value_kind, .value = value });
        }
        const owned_params = try params.toOwnedSlice(gpa);
        errdefer {
            for (owned_params) |p| gpa.free(p.name);
            gpa.free(owned_params);
        }
        for (records.items) |prev| {
            if (prev.saved_handle == saved_handle) return error.CorruptNprm;
        }
        try records.append(gpa, .{ .saved_handle = saved_handle, .params = owned_params });
    }
    if (off != payload.len) return error.CorruptNprm;
    return try records.toOwnedSlice(gpa);
}

/// Looks at each NODE's kind and validates known descriptors via `modular.validateParam` (the same check as setParam).
/// An unknown name is skipped. A saved_handle that is missing from NODE or out of range is skipped.
/// Call this before clearGraph, so an invalid value never corrupts the graph.
pub fn validateNodeParams(nodes: []const NodeEntry, records: []const NodeParamRecord) DecodeError!void {
    var kinds = [_]?graph_io.ModuleKind{null} ** MAX_NPRM_NODES;
    for (nodes) |n| {
        if (n.handle < MAX_NPRM_NODES) kinds[n.handle] = n.kind;
    }
    for (records) |rec| {
        if (rec.saved_handle >= MAX_NPRM_NODES) continue;
        const kind = kinds[rec.saved_handle] orelse continue;
        for (rec.params) |p| {
            const value: modular.ParamValue = switch (p.value_kind) {
                VALUE_KIND_SCALAR => .{ .scalar = @bitCast(p.value) },
                VALUE_KIND_CHOICE => .{ .choice = @intCast(p.value) },
                else => return error.CorruptNprm,
            };
            modular.validateParam(kind, p.name, value) catch |err| switch (err) {
                error.UnknownParam => continue, // forward compat
                error.WrongValueKind => return error.WrongValueKind,
                error.OutOfRange => return error.OutOfRange,
                error.ChoiceIndexOutOfRange => return error.ChoiceIndexOutOfRange,
                error.InvalidHandle, error.InactiveHandle => unreachable,
            };
        }
    }
}

comptime {
    @setEvalBranchQuota(50_000);
    for (@typeInfo(graph_io.ModuleKind).@"enum".fields) |field| {
        const kind: graph_io.ModuleKind = @enumFromInt(field.value);
        if (modular.descriptors(kind).len > MAX_PARAMS_PER_NODE) {
            @compileError("ModuleKind descriptors exceed MAX_PARAMS_PER_NODE; raise the constant");
        }
    }
}

// -- NIDM / NREF --

const NIDM_SIZE: usize = 8;
const NREF_ENTRY_SIZE: usize = 10; // handle u16 + id u64

fn packNidm(next_node_id: u64, out: *[NIDM_SIZE]u8) void {
    std.mem.writeInt(u64, out[0..8], next_node_id, .little);
}

fn unpackNidm(payload: []const u8) DecodeError!u64 {
    if (payload.len != NIDM_SIZE) return error.CorruptNidm;
    const next = std.mem.readInt(u64, payload[0..8], .little);
    if (next == 0) return error.CorruptNidm;
    return next;
}

fn nrefPayloadSize(refs: []const NodeIdRef) usize {
    return 2 + refs.len * NREF_ENTRY_SIZE;
}

fn packNref(refs: []const NodeIdRef, out: []u8) void {
    std.debug.assert(out.len >= nrefPayloadSize(refs));
    std.mem.writeInt(u16, out[0..2], @intCast(refs.len), .little);
    var off: usize = 2;
    for (refs) |r| {
        std.mem.writeInt(u16, out[off..][0..2], r.saved_handle, .little);
        std.mem.writeInt(u64, out[off + 2 ..][0..8], r.id.raw(), .little);
        off += NREF_ENTRY_SIZE;
    }
}

fn unpackNref(gpa: std.mem.Allocator, payload: []const u8) ![]NodeIdRef {
    if (payload.len < 2) return error.CorruptNref;
    const count = std.mem.readInt(u16, payload[0..2], .little);
    if (payload.len != 2 + @as(usize, count) * NREF_ENTRY_SIZE) return error.CorruptNref;
    if (count > MAX_NPRM_NODES) return error.CorruptNref;
    const refs = try gpa.alloc(NodeIdRef, count);
    errdefer gpa.free(refs);
    var off: usize = 2;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const h = std.mem.readInt(u16, payload[off..][0..2], .little);
        const id_raw = std.mem.readInt(u64, payload[off + 2 ..][0..8], .little);
        if (id_raw == 0) return error.CorruptNref;
        refs[i] = .{ .saved_handle = h, .id = NodeId.fromRaw(id_raw) };
        off += NREF_ENTRY_SIZE;
    }
    return refs;
}

/// Validates that NREF is consistent with nodes / next_node_id.
pub fn validateNodeIdRefs(nodes: []const NodeEntry, refs: []const NodeIdRef, next_node_id: u64) DecodeError!void {
    if (next_node_id == 0) return error.CorruptNidm;
    var seen_handle = [_]bool{false} ** MAX_NPRM_NODES;
    for (nodes) |n| {
        if (n.handle < MAX_NPRM_NODES) seen_handle[n.handle] = true;
    }
    var used_saved = [_]bool{false} ** MAX_NPRM_NODES;
    var id_slots: [MAX_NPRM_NODES]u64 = [_]u64{0} ** MAX_NPRM_NODES;
    var id_n: usize = 0;
    var max_id: u64 = 0;
    for (refs) |r| {
        if (r.id.raw() == 0) return error.CorruptNref;
        if (r.saved_handle >= MAX_NPRM_NODES or !seen_handle[r.saved_handle]) return error.CorruptNref;
        if (used_saved[r.saved_handle]) return error.CorruptNref; // bijection: a saved_handle must not be used twice
        used_saved[r.saved_handle] = true;
        var j: usize = 0;
        while (j < id_n) : (j += 1) {
            if (id_slots[j] == r.id.raw()) return error.DuplicateNodeId;
        }
        if (id_n >= MAX_NPRM_NODES) return error.CorruptNref;
        id_slots[id_n] = r.id.raw();
        id_n += 1;
        if (r.id.raw() > max_id) max_id = r.id.raw();
    }
    // Every node needs a corresponding ref (an empty graph may have empty refs)
    if (refs.len != nodes.len) return error.CorruptNref;
    if (next_node_id <= max_id) return error.CorruptNidm;
}

/// schema 1 / PTCG: assigns NodeIds by node appearance order, returning refs and next (caller frees them).
pub fn buildFallbackNodeIdRefs(gpa: std.mem.Allocator, nodes: []const NodeEntry) !struct { refs: []NodeIdRef, next: u64 } {
    const refs = try gpa.alloc(NodeIdRef, nodes.len);
    errdefer gpa.free(refs);
    var ids_buf: [MAX_NPRM_NODES]NodeId = undefined;
    std.debug.assert(nodes.len <= MAX_NPRM_NODES);
    const next = graph_io.assignFallbackNodeIds(nodes, ids_buf[0..nodes.len]);
    for (nodes, 0..) |n, i| {
        refs[i] = .{ .saved_handle = n.handle, .id = ids_buf[i] };
    }
    return .{ .refs = refs, .next = next };
}

// ── encode / decode ──────────────────────────────────────────────────────────

pub fn Decoded(comptime P: type) type {
    return struct {
        format: FormatKind,
        params: P,
        pattern: pattern_io.PatternPayload,
        seed: SeedPayload,
        song: SongPayload,
        nodes: []NodeEntry,
        edges: []EdgeEntry,
        node_params: []NodeParamRecord,
        /// saved_handle -> NodeId (not necessarily in the same order as nodes; gpa-owned).
        node_id_refs: []NodeIdRef,
        next_node_id: u64,
        ledger: group.Ledger,
        genr: GenRoleHandles,
        /// Whether this group of fields should be applied, for a partial format
        apply_params_pattern: bool,
        apply_seed_song: bool,
        apply_graph: bool,
        apply_node_params: bool,
        apply_ledger: bool,
        apply_genr: bool,

        pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
            freeNodeParamRecords(gpa, self.node_params);
            self.node_params = &.{};
            gpa.free(self.node_id_refs);
            self.node_id_refs = &.{};
            gpa.free(self.nodes);
            gpa.free(self.edges);
        }
    };
}

pub const EncodeInput = struct {
    pattern: pattern_io.PatternPayload,
    seed: SeedPayload,
    song: SongPayload,
    nodes: []const NodeEntry,
    edges: []const EdgeEntry,
    node_params: []const NodeParamRecord = &.{},
    node_id_refs: []const NodeIdRef = &.{},
    next_node_id: u64 = 1,
    ledger: *const group.Ledger,
    genr: GenRoleHandles,
};

/// Encodes an entire noodle project (caller frees the result).
pub fn encode(comptime P: type, gpa: std.mem.Allocator, params: P, input: EncodeInput) ![]u8 {
    var w = try serde.Writer.init(gpa, magic, schema_version);
    errdefer w.deinit();

    var pbuf: [packedSize(P)]u8 = undefined;
    packInto(P, params, &pbuf);
    try w.addChunk(TAG_SPRM, &pbuf);

    var tbuf: [PTRN_SIZE]u8 = undefined;
    packPattern(input.pattern, &tbuf);
    try w.addChunk(TAG_PTRN, &tbuf);

    var sbuf: [SEED_SIZE]u8 = undefined;
    packSeed(input.seed, &sbuf);
    try w.addChunk(TAG_SEED, &sbuf);

    var songbuf: [SONG_SIZE]u8 = undefined;
    packSong(input.song, &songbuf);
    try w.addChunk(TAG_SONG, &songbuf);

    for (input.nodes) |n| {
        var buf: [NODE_SIZE]u8 = undefined;
        packNode(n, &buf);
        try w.addChunk(TAG_NODE, &buf);
    }
    for (input.edges) |e| {
        var buf: [EDGE_SIZE]u8 = undefined;
        packEdge(e, &buf);
        try w.addChunk(TAG_EDGE, &buf);
    }

    const nprm_size = nprmPayloadSize(input.node_params);
    const nprm_buf = try gpa.alloc(u8, nprm_size);
    defer gpa.free(nprm_buf);
    packNprm(input.node_params, nprm_buf);
    try w.addChunk(TAG_NPRM, nprm_buf);

    var nidm_buf: [NIDM_SIZE]u8 = undefined;
    packNidm(input.next_node_id, &nidm_buf);
    try w.addChunk(TAG_NIDM, &nidm_buf);

    const nref_size = nrefPayloadSize(input.node_id_refs);
    const nref_buf = try gpa.alloc(u8, nref_size);
    defer gpa.free(nref_buf);
    packNref(input.node_id_refs, nref_buf);
    try w.addChunk(TAG_NREF, nref_buf);

    var lbuf: [LEDG_SIZE]u8 = undefined;
    packLedger(input.ledger, &lbuf);
    try w.addChunk(TAG_LEDG, &lbuf);

    var gbuf: [GENR_SIZE]u8 = undefined;
    packGenr(input.genr, &gbuf);
    try w.addChunk(TAG_GENR, &gbuf);

    return w.finish();
}

/// For generating legacy MPRJ fixtures (test-only; the production writer emits only NDL1).
pub fn encodeMprj(
    comptime P: type,
    gpa: std.mem.Allocator,
    params: P,
    pattern: pattern_io.PatternPayload,
    seed: SeedPayload,
    song: SongPayload,
) ![]u8 {
    var w = try serde.Writer.init(gpa, mprj_magic, schema_version);
    errdefer w.deinit();
    var pbuf: [packedSize(P)]u8 = undefined;
    packInto(P, params, &pbuf);
    try w.addChunk(TAG_SPRM, &pbuf);
    var tbuf: [PTRN_SIZE]u8 = undefined;
    packPattern(pattern, &tbuf);
    try w.addChunk(TAG_PTRN, &tbuf);
    var sbuf: [SEED_SIZE]u8 = undefined;
    packSeed(seed, &sbuf);
    try w.addChunk(TAG_SEED, &sbuf);
    var songbuf: [SONG_SIZE]u8 = undefined;
    packSong(song, &songbuf);
    try w.addChunk(TAG_SONG, &songbuf);
    return w.finish();
}

fn emptyDecoded(comptime P: type, format: FormatKind) Decoded(P) {
    return .{
        .format = format,
        .params = .{},
        .pattern = .{},
        .seed = .{},
        .song = .{},
        .nodes = &.{},
        .edges = &.{},
        .node_params = &.{},
        .node_id_refs = &.{},
        .next_node_id = 1,
        .ledger = .{},
        .genr = .{},
        .apply_params_pattern = false,
        .apply_seed_song = false,
        .apply_graph = false,
        .apply_node_params = false,
        .apply_ledger = false,
        .apply_genr = false,
    };
}

fn decodeNoodle(comptime P: type, gpa: std.mem.Allocator, bytes: []const u8) !Decoded(P) {
    const container = try serde.Container.parse(bytes, magic);
    if (container.schemaVersion() > schema_version) return error.UnsupportedSchemaVersion;
    const file_schema = container.schemaVersion();

    var seen_sprm = false;
    var seen_ptrn = false;
    var seen_seed = false;
    var seen_song = false;
    var seen_nprm = false;
    var seen_nidm = false;
    var seen_nref = false;
    var seen_ledg = false;
    var seen_genr = false;
    var sprm: ?[]const u8 = null;
    var ptrn: ?[]const u8 = null;
    var seed_c: ?[]const u8 = null;
    var song_c: ?[]const u8 = null;
    var nprm_c: ?[]const u8 = null;
    var nidm_c: ?[]const u8 = null;
    var nref_c: ?[]const u8 = null;
    var ledg_c: ?[]const u8 = null;
    var genr_c: ?[]const u8 = null;

    var nodes: std.ArrayList(NodeEntry) = .empty;
    errdefer nodes.deinit(gpa);
    var edges: std.ArrayList(EdgeEntry) = .empty;
    errdefer edges.deinit(gpa);

    var it = container.iterator();
    while (it.next()) |chunk| {
        if (std.mem.eql(u8, &chunk.tag, &TAG_SPRM)) {
            if (seen_sprm) return error.DuplicateChunk;
            seen_sprm = true;
            sprm = chunk.payload;
        } else if (std.mem.eql(u8, &chunk.tag, &TAG_PTRN)) {
            if (seen_ptrn) return error.DuplicateChunk;
            seen_ptrn = true;
            ptrn = chunk.payload;
        } else if (std.mem.eql(u8, &chunk.tag, &TAG_SEED)) {
            if (seen_seed) return error.DuplicateChunk;
            seen_seed = true;
            seed_c = chunk.payload;
        } else if (std.mem.eql(u8, &chunk.tag, &TAG_SONG)) {
            if (seen_song) return error.DuplicateChunk;
            seen_song = true;
            song_c = chunk.payload;
        } else if (std.mem.eql(u8, &chunk.tag, &TAG_NPRM)) {
            if (seen_nprm) return error.DuplicateChunk;
            seen_nprm = true;
            nprm_c = chunk.payload;
        } else if (std.mem.eql(u8, &chunk.tag, &TAG_NIDM)) {
            if (seen_nidm) return error.DuplicateChunk;
            seen_nidm = true;
            nidm_c = chunk.payload;
        } else if (std.mem.eql(u8, &chunk.tag, &TAG_NREF)) {
            if (seen_nref) return error.DuplicateChunk;
            seen_nref = true;
            nref_c = chunk.payload;
        } else if (std.mem.eql(u8, &chunk.tag, &TAG_LEDG)) {
            if (seen_ledg) return error.DuplicateChunk;
            seen_ledg = true;
            ledg_c = chunk.payload;
        } else if (std.mem.eql(u8, &chunk.tag, &TAG_GENR)) {
            if (seen_genr) return error.DuplicateChunk;
            seen_genr = true;
            genr_c = chunk.payload;
        } else if (std.mem.eql(u8, &chunk.tag, &TAG_NODE)) {
            if (try unpackNode(chunk.payload)) |n| try nodes.append(gpa, n);
        } else if (std.mem.eql(u8, &chunk.tag, &TAG_EDGE)) {
            try edges.append(gpa, try unpackEdge(chunk.payload));
        }
        // An unknown tag is ignored
    }

    const sprm_b = sprm orelse return error.MissingSprm;
    if (sprm_b.len != packedSize(P)) return error.CorruptSprm;
    const ptrn_b = ptrn orelse return error.MissingPtrn;
    if (ptrn_b.len != PTRN_SIZE) return error.CorruptPtrn;
    const seed_b = seed_c orelse return error.MissingSeed;
    if (seed_b.len != SEED_SIZE) return error.CorruptSeed;
    const song_b = song_c orelse return error.MissingSong;
    if (song_b.len != SONG_SIZE) return error.CorruptSong;
    const ledg_b = ledg_c orelse return error.MissingLedg;
    const genr_b = genr_c orelse return error.MissingGenr;

    const song = unpackSong(song_b);
    try validateSong(song, song_b[SONG_SIZE - 1]);

    const owned_nodes = try nodes.toOwnedSlice(gpa);
    errdefer gpa.free(owned_nodes);
    const owned_edges = try edges.toOwnedSlice(gpa);
    errdefer gpa.free(owned_edges);

    var node_params: []NodeParamRecord = &.{};
    var apply_node_params = false;
    if (nprm_c) |payload| {
        node_params = try unpackNprm(gpa, payload);
        apply_node_params = true;
    }
    errdefer freeNodeParamRecords(gpa, node_params);

    var node_id_refs: []NodeIdRef = &.{};
    var next_node_id: u64 = 1;
    errdefer if (node_id_refs.len > 0) gpa.free(node_id_refs);
    if (nidm_c != null or nref_c != null) {
        // Having only one of the pair is invalid
        const nidm_payload = nidm_c orelse return error.CorruptNidm;
        const nref_payload = nref_c orelse return error.CorruptNref;
        next_node_id = try unpackNidm(nidm_payload);
        node_id_refs = try unpackNref(gpa, nref_payload);
        try validateNodeIdRefs(owned_nodes, node_id_refs, next_node_id);
    } else if (file_schema >= schema_version) {
        // At schema 2+, missing NIDM/NREF is allowed only for an empty graph
        if (owned_nodes.len != 0) return error.CorruptNidm;
        next_node_id = 1;
        node_id_refs = &.{};
    } else {
        // schema 1: deterministic fallback
        const fb = try buildFallbackNodeIdRefs(gpa, owned_nodes);
        node_id_refs = fb.refs;
        next_node_id = fb.next;
    }

    return .{
        .format = .noodle,
        .params = try unpackFrom(P, sprm_b),
        .pattern = unpackPattern(ptrn_b),
        .seed = unpackSeed(seed_b),
        .song = song,
        .nodes = owned_nodes,
        .edges = owned_edges,
        .node_params = node_params,
        .node_id_refs = node_id_refs,
        .next_node_id = next_node_id,
        .ledger = try unpackLedger(ledg_b),
        .genr = try unpackGenr(genr_b),
        .apply_params_pattern = true,
        .apply_seed_song = true,
        .apply_graph = true,
        .apply_node_params = apply_node_params,
        .apply_ledger = true,
        .apply_genr = true,
    };
}

fn decodeFromMdlp(comptime P: type, gpa: std.mem.Allocator, bytes: []const u8) !Decoded(P) {
    _ = gpa;
    const loaded = try pattern_io.decode(P, bytes);
    var out = emptyDecoded(P, .mdlp);
    out.params = loaded.params;
    out.pattern = loaded.pattern;
    out.apply_params_pattern = true;
    return out;
}

fn decodeFromMprj(comptime P: type, gpa: std.mem.Allocator, bytes: []const u8) !Decoded(P) {
    _ = gpa;
    const container = try serde.Container.parse(bytes, mprj_magic);
    if (container.schemaVersion() > schema_version) return error.UnsupportedSchemaVersion;

    const sprm = container.find(TAG_SPRM) orelse return error.MissingSprm;
    if (sprm.len != packedSize(P)) return error.CorruptSprm;
    const ptrn = container.find(TAG_PTRN) orelse return error.MissingPtrn;
    if (ptrn.len != PTRN_SIZE) return error.CorruptPtrn;
    const seed_c = container.find(TAG_SEED) orelse return error.MissingSeed;
    if (seed_c.len != SEED_SIZE) return error.CorruptSeed;
    const song_c = container.find(TAG_SONG) orelse return error.MissingSong;
    if (song_c.len != SONG_SIZE) return error.CorruptSong;

    const song = unpackSong(song_c);
    try validateSong(song, song_c[SONG_SIZE - 1]);

    var out = emptyDecoded(P, .mprj);
    out.params = try unpackFrom(P, sprm);
    out.pattern = unpackPattern(ptrn);
    out.seed = unpackSeed(seed_c);
    out.song = song;
    out.apply_params_pattern = true;
    out.apply_seed_song = true;
    return out;
}

fn decodeFromPtcg(comptime P: type, gpa: std.mem.Allocator, bytes: []const u8) !Decoded(P) {
    var graph = try graph_io.decodeGraph(gpa, bytes);
    errdefer graph.deinit(gpa);
    var out = emptyDecoded(P, .ptcg);
    out.nodes = graph.nodes;
    out.edges = graph.edges;
    graph.nodes = &.{};
    graph.edges = &.{};
    const fb = try buildFallbackNodeIdRefs(gpa, out.nodes);
    out.node_id_refs = fb.refs;
    out.next_node_id = fb.next;
    out.apply_graph = true;
    out.apply_ledger = true; // Reset to an empty Ledger
    out.apply_genr = true; // invalidate
    out.ledger = .{};
    out.genr = .{}; // all INVALID
    return out;
}

/// Decodes by auto-detecting the magic. nodes/edges are gpa-allocated (caller must deinit).
pub fn decode(comptime P: type, gpa: std.mem.Allocator, bytes: []const u8) !Decoded(P) {
    if (bytes.len < 4) return error.BadMagic;
    const m = std.mem.readInt(u32, bytes[0..4], .little);
    if (m == magic) return decodeNoodle(P, gpa, bytes);
    if (m == pattern_io.magic) return decodeFromMdlp(P, gpa, bytes);
    if (m == mprj_magic) return decodeFromMprj(P, gpa, bytes);
    if (m == graph_io.magic) return decodeFromPtcg(P, gpa, bytes);
    return error.BadMagic;
}

pub fn save(
    io: std.Io,
    path: []const u8,
    comptime P: type,
    params: P,
    input: EncodeInput,
    gpa: std.mem.Allocator,
) !void {
    const bytes = try encode(P, gpa, params, input);
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

pub fn load(io: std.Io, gpa: std.mem.Allocator, path: []const u8, comptime P: type) !Decoded(P) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    return decode(P, gpa, bytes);
}

// ============================ tests ============================

const testing = std.testing;

const TestParams = struct {
    tempo: f32 = 122.0,
    kick_mute: bool = false,
    idx: usize = 0,
};

const sample_nodes = [_]NodeEntry{
    .{ .handle = 0, .kind = .vco, .x = 10, .y = 20 },
    .{ .handle = 1, .kind = .output, .x = 100, .y = 0 },
};
const sample_edges = [_]EdgeEntry{
    .{ .src_handle = 0, .src_out = 0, .dst_handle = 1, .dst_in = 0 },
};
const sample_nrefs = [_]NodeIdRef{
    .{ .saved_handle = 0, .id = NodeId.fromRaw(1) },
    .{ .saved_handle = 1, .id = NodeId.fromRaw(2) },
};
var sample_ledger: group.Ledger = .{};

fn sampleInput() EncodeInput {
    return .{
        .pattern = .{
            .evolve = false,
            .kick_on = 0x1111,
            .kick_lock = true,
            .hat_on = 0x4444,
            .bass_on = 0x4949,
            .bass_deg = [16]i8{ 0, 0, 0, 3, 0, 0, 2, 0, 0, 0, 0, 5, -1, 0, 2, 0 },
        },
        .seed = .{ .base_seed = 42, .notation_seed = 99, .notation_counter = 7 },
        .song = blk: {
            var song = SongPayload{};
            song.phrases_kick[0] = 0x1111;
            song.row_count = 1;
            song.loop = true;
            break :blk song;
        },
        .nodes = &sample_nodes,
        .edges = &sample_edges,
        .node_id_refs = &sample_nrefs,
        .next_node_id = 3,
        .ledger = &sample_ledger,
        .genr = blk: {
            var g: GenRoleHandles = .{};
            g.set(.clock, 0);
            g.set(.output, 1);
            break :blk g;
        },
    };
}

test "container magic: the writer emits NDL1 and older magics are refused" {
    const gpa = testing.allocator;
    const params = TestParams{ .tempo = 120, .kick_mute = false, .idx = 0 };

    const bytes = try encode(TestParams, gpa, params, sampleInput());
    defer gpa.free(bytes);
    try testing.expectEqualSlices(u8, "NDL1", bytes[0..4]);

    var got = try decode(TestParams, gpa, bytes);
    defer got.deinit(gpa);
    try testing.expect(got.format == .noodle);

    // The retired magic is not in the reader's accepted set, so a file written by an older
    // build is refused rather than misread.
    const retired = try gpa.dupe(u8, bytes);
    defer gpa.free(retired);
    @memcpy(retired[0..4], "KNGN");
    try testing.expectError(error.BadMagic, decode(TestParams, gpa, retired));
}

test "noodle encode/decode: full field round-trip" {
    const gpa = testing.allocator;
    const params = TestParams{ .tempo = 140, .kick_mute = true, .idx = 2 };
    var ledger: group.Ledger = .{};
    const gid = ledger.alloc().?;
    ledger.assign(0, gid);
    ledger.groups[gid].kind = .drum_machine;
    ledger.groups[gid].collapsed = true;
    ledger.groups[gid].pos = .{ .x = 40, .y = 50 };
    ledger.groups[gid].n_out = 1;
    ledger.groups[gid].template_n_out = 1;
    ledger.groups[gid].exposed_out[0] = .{ .member = 0, .port = 0, .is_input = false, .label_len = 3 };
    @memcpy(ledger.groups[gid].exposed_out[0].label[0..3], "out");

    var input = sampleInput();
    input.ledger = &ledger;

    const bytes = try encode(TestParams, gpa, params, input);
    defer gpa.free(bytes);

    var got = try decode(TestParams, gpa, bytes);
    defer got.deinit(gpa);

    try testing.expect(got.format == .noodle);
    try testing.expectEqual(params, got.params);
    try testing.expectEqual(input.pattern, got.pattern);
    try testing.expectEqual(input.seed, got.seed);
    try testing.expectEqual(input.song.phrases_kick[0], got.song.phrases_kick[0]);
    try testing.expectEqual(input.song.row_count, got.song.row_count);
    try testing.expectEqual(@as(usize, 2), got.nodes.len);
    try testing.expectEqual(input.nodes[0], got.nodes[0]);
    try testing.expectEqual(@as(usize, 1), got.edges.len);
    try testing.expectEqual(input.edges[0], got.edges[0]);
    try testing.expectEqual(@as(?group.GroupId, gid), got.ledger.group_of[0]);
    try testing.expect(got.ledger.groups[gid].active);
    try testing.expectEqual(group.MacroKind.drum_machine, got.ledger.groups[gid].kind);
    try testing.expectEqual(@as(u16, 0), got.genr.get(.clock));
    try testing.expectEqual(@as(u16, 1), got.genr.get(.output));
    try testing.expectEqual(@as(usize, 2), got.node_id_refs.len);
    try testing.expectEqual(input.node_id_refs[0].id, got.node_id_refs[0].id);
    try testing.expectEqual(input.next_node_id, got.next_node_id);
}

test "noodle encode→decode→encode: canonical bytes bit-identical" {
    const gpa = testing.allocator;
    const params = TestParams{ .tempo = 96, .idx = 1 };
    const input = sampleInput();
    const a = try encode(TestParams, gpa, params, input);
    defer gpa.free(a);
    var decoded = try decode(TestParams, gpa, a);
    defer decoded.deinit(gpa);
    const b = try encode(TestParams, gpa, decoded.params, .{
        .pattern = decoded.pattern,
        .seed = decoded.seed,
        .song = decoded.song,
        .nodes = decoded.nodes,
        .edges = decoded.edges,
        .node_params = decoded.node_params,
        .node_id_refs = decoded.node_id_refs,
        .next_node_id = decoded.next_node_id,
        .ledger = &decoded.ledger,
        .genr = decoded.genr,
    });
    defer gpa.free(b);
    try testing.expectEqualSlices(u8, a, b);
}

test "noodle decode: unknown chunk skip / DuplicateChunk / missing required" {
    const gpa = testing.allocator;
    const input = sampleInput();
    // unknown skip
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        var pbuf: [packedSize(TestParams)]u8 = undefined;
        packInto(TestParams, .{}, &pbuf);
        try w.addChunk(TAG_SPRM, &pbuf);
        try w.addChunk("FUTR".*, "x");
        var tbuf: [PTRN_SIZE]u8 = undefined;
        packPattern(input.pattern, &tbuf);
        try w.addChunk(TAG_PTRN, &tbuf);
        var sbuf: [SEED_SIZE]u8 = undefined;
        packSeed(input.seed, &sbuf);
        try w.addChunk(TAG_SEED, &sbuf);
        var songbuf: [SONG_SIZE]u8 = undefined;
        packSong(input.song, &songbuf);
        try w.addChunk(TAG_SONG, &songbuf);
        var lbuf: [LEDG_SIZE]u8 = undefined;
        packLedger(input.ledger, &lbuf);
        try w.addChunk(TAG_LEDG, &lbuf);
        var gbuf: [GENR_SIZE]u8 = undefined;
        packGenr(input.genr, &gbuf);
        try w.addChunk(TAG_GENR, &gbuf);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        var got = try decode(TestParams, gpa, bytes);
        defer got.deinit(gpa);
        try testing.expectEqual(input.seed.base_seed, got.seed.base_seed);
    }
    // DuplicateChunk
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        var pbuf: [packedSize(TestParams)]u8 = undefined;
        packInto(TestParams, .{}, &pbuf);
        try w.addChunk(TAG_SPRM, &pbuf);
        try w.addChunk(TAG_SPRM, &pbuf);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.DuplicateChunk, decode(TestParams, gpa, bytes));
    }
    // MissingLedg
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        var pbuf: [packedSize(TestParams)]u8 = undefined;
        packInto(TestParams, .{}, &pbuf);
        try w.addChunk(TAG_SPRM, &pbuf);
        var tbuf: [PTRN_SIZE]u8 = undefined;
        packPattern(.{}, &tbuf);
        try w.addChunk(TAG_PTRN, &tbuf);
        var sbuf: [SEED_SIZE]u8 = undefined;
        packSeed(.{}, &sbuf);
        try w.addChunk(TAG_SEED, &sbuf);
        var songbuf: [SONG_SIZE]u8 = undefined;
        packSong(.{}, &songbuf);
        try w.addChunk(TAG_SONG, &songbuf);
        var gbuf: [GENR_SIZE]u8 = undefined;
        packGenr(.{}, &gbuf);
        try w.addChunk(TAG_GENR, &gbuf);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.MissingLedg, decode(TestParams, gpa, bytes));
    }
}

test "noodle decode: UnsupportedSchemaVersion / CrcMismatch / CorruptLedger" {
    const gpa = testing.allocator;
    const input = sampleInput();
    {
        var w = try serde.Writer.init(gpa, magic, schema_version + 1);
        defer w.deinit();
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.UnsupportedSchemaVersion, decode(TestParams, gpa, bytes));
    }
    {
        const bytes = try encode(TestParams, gpa, .{}, input);
        defer gpa.free(bytes);
        var mut = try gpa.dupe(u8, bytes);
        defer gpa.free(mut);
        mut[mut.len - 1] ^= 0xFF;
        try testing.expectError(error.CrcMismatch, decode(TestParams, gpa, mut));
    }
    {
        var w = try serde.Writer.init(gpa, magic, schema_version);
        defer w.deinit();
        var pbuf: [packedSize(TestParams)]u8 = undefined;
        packInto(TestParams, .{}, &pbuf);
        try w.addChunk(TAG_SPRM, &pbuf);
        var tbuf: [PTRN_SIZE]u8 = undefined;
        packPattern(.{}, &tbuf);
        try w.addChunk(TAG_PTRN, &tbuf);
        var sbuf: [SEED_SIZE]u8 = undefined;
        packSeed(.{}, &sbuf);
        try w.addChunk(TAG_SEED, &sbuf);
        var songbuf: [SONG_SIZE]u8 = undefined;
        packSong(.{}, &songbuf);
        try w.addChunk(TAG_SONG, &songbuf);
        try w.addChunk(TAG_LEDG, "short");
        var gbuf: [GENR_SIZE]u8 = undefined;
        packGenr(.{}, &gbuf);
        try w.addChunk(TAG_GENR, &gbuf);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptLedger, decode(TestParams, gpa, bytes));
    }
}

test "legacy MDLP/MPRJ/PTCG: integrated reader restores expected fields" {
    const gpa = testing.allocator;
    // MDLP
    {
        const bytes = try pattern_io.encode(TestParams, gpa, .{ .tempo = 100 }, .{ .kick_on = 0x00FF });
        defer gpa.free(bytes);
        var got = try decode(TestParams, gpa, bytes);
        defer got.deinit(gpa);
        try testing.expect(got.format == .mdlp);
        try testing.expect(got.apply_params_pattern);
        try testing.expect(!got.apply_graph);
        try testing.expectEqual(@as(f32, 100), got.params.tempo);
        try testing.expectEqual(@as(u16, 0x00FF), got.pattern.kick_on);
    }
    // MPRJ
    {
        const bytes = try encodeMprj(TestParams, gpa, .{ .tempo = 110 }, .{ .hat_on = 0x2222 }, .{ .base_seed = 7 }, .{ .row_count = 2, .loop = true });
        defer gpa.free(bytes);
        var got = try decode(TestParams, gpa, bytes);
        defer got.deinit(gpa);
        try testing.expect(got.format == .mprj);
        try testing.expect(got.apply_seed_song);
        try testing.expect(!got.apply_graph);
        try testing.expectEqual(@as(u64, 7), got.seed.base_seed);
        try testing.expectEqual(@as(u8, 2), got.song.row_count);
    }
    // PTCG
    {
        const nodes = [_]NodeEntry{.{ .handle = 3, .kind = .lfo, .x = 5, .y = 6 }};
        const bytes = try graph_io.encodeGraph(gpa, &nodes, &.{});
        defer gpa.free(bytes);
        var got = try decode(TestParams, gpa, bytes);
        defer got.deinit(gpa);
        try testing.expect(got.format == .ptcg);
        try testing.expect(got.apply_graph);
        try testing.expectEqual(@as(usize, 1), got.nodes.len);
        try testing.expectEqual(nodes[0], got.nodes[0]);
        try testing.expect(!got.ledger.groups[0].active);
        try testing.expectEqual(INVALID_ROLE_HANDLE, got.genr.get(.clock));
    }
}

test "GENR remap / Ledger remap: old→new handle map" {
    var mapping = [_]?Handle{null} ** group.GROUP_HANDLE_BASE;
    mapping[2] = 10;
    mapping[5] = 11;

    var genr: GenRoleHandles = .{};
    genr.set(.clock, 2);
    genr.set(.output, 5);
    genr.set(.kick, INVALID_ROLE_HANDLE);
    const rg = remapGenr(genr, &mapping);
    try testing.expectEqual(@as(u16, 10), rg.get(.clock));
    try testing.expectEqual(@as(u16, 11), rg.get(.output));
    try testing.expectEqual(INVALID_ROLE_HANDLE, rg.get(.kick));

    var ledger: group.Ledger = .{};
    const gid = ledger.alloc().?;
    ledger.assign(2, gid);
    ledger.groups[gid].n_out = 1;
    ledger.groups[gid].exposed_out[0].member = 2;
    const rl = try remapLedger(&ledger, &mapping);
    try testing.expectEqual(@as(?group.GroupId, null), rl.group_of[2]);
    try testing.expectEqual(@as(?group.GroupId, gid), rl.group_of[10]);
    try testing.expectEqual(@as(Handle, 10), rl.groups[gid].exposed_out[0].member);
}

test "ModuleKind ordinal stability: sidechain=25, slew..=logic=26..30" {
    try testing.expectEqual(@as(u8, 25), @intFromEnum(graph_io.ModuleKind.sidechain));
    try testing.expectEqual(@as(u8, 26), @intFromEnum(graph_io.ModuleKind.slew));
    try testing.expectEqual(@as(u8, 27), @intFromEnum(graph_io.ModuleKind.sample_hold));
    try testing.expectEqual(@as(u8, 28), @intFromEnum(graph_io.ModuleKind.comparator));
    try testing.expectEqual(@as(u8, 29), @intFromEnum(graph_io.ModuleKind.ring_mod));
    try testing.expectEqual(@as(u8, 30), @intFromEnum(graph_io.ModuleKind.logic));
}

// ── LEDG v1/v2 size fixtures (fixed-format regression) ───────────────────────

/// Build a deterministic ledger with one active drum group (slot from alloc).
fn fixtureLedgerOneGroup() group.Ledger {
    var ledger: group.Ledger = .{};
    const gid = ledger.alloc().?;
    ledger.assign(0, gid);
    ledger.groups[gid].kind = .drum_machine;
    ledger.groups[gid].collapsed = true;
    ledger.groups[gid].pos = .{ .x = 40, .y = 50 };
    ledger.groups[gid].n_out = 1;
    ledger.groups[gid].template_n_out = 1;
    ledger.groups[gid].exposed_out[0] = .{ .member = 0, .port = 0, .is_input = false, .label_len = 3 };
    @memcpy(ledger.groups[gid].exposed_out[0].label[0..3], "out");
    return ledger;
}

test "LEDG size constants: v1 legacy and v2 write formulas hold for any MAX_MODULES" {
    // Pin the per-group sizes (N-independent) and the full-chunk formulas.
    try testing.expectEqual(@as(usize, 16), LEDG_GROUP_HEADER_V1);
    try testing.expectEqual(@as(usize, 24), LEDG_GROUP_HEADER_V2);
    try testing.expectEqual(@as(usize, 224), LEDG_GROUP_SIZE_V1);
    try testing.expectEqual(@as(usize, 232), LEDG_GROUP_SIZE_V2);
    try testing.expectEqual(group.GROUP_HANDLE_BASE + group.MAX_GROUPS * LEDG_GROUP_SIZE_V1, LEDG_SIZE_V1);
    try testing.expectEqual(group.GROUP_HANDLE_BASE + group.MAX_GROUPS * LEDG_GROUP_SIZE_V2, LEDG_SIZE_V2);
    // Write path aliases the v2 constants.
    try testing.expectEqual(LEDG_SIZE_V2, LEDG_SIZE);
    try testing.expectEqual(LEDG_GROUP_SIZE_V2, LEDG_GROUP_SIZE);
}

test "LEDG v1 fixture: legacy size loads and assigns fresh identities" {
    var src = fixtureLedgerOneGroup();
    // Wipe identities to simulate a pre-identity on-disk image (v1 pack ignores them).
    const gid0: group.GroupId = 0;
    try testing.expect(src.groups[gid0].active);
    const saved_id = src.groups[gid0].identity;
    try testing.expect(saved_id != 0);
    src.groups[gid0].identity = 0;
    src.next_identity = 1;

    var v1: [LEDG_SIZE_V1]u8 = undefined;
    packLedgerV1(&src, &v1);
    try testing.expectEqual(LEDG_SIZE_V1, v1.len);

    const got = try unpackLedger(&v1);
    try testing.expect(got.groups[gid0].active);
    try testing.expectEqual(group.MacroKind.drum_machine, got.groups[gid0].kind);
    try testing.expect(got.groups[gid0].collapsed);
    try testing.expectApproxEqAbs(@as(f32, 40), got.groups[gid0].pos.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 50), got.groups[gid0].pos.y, 1e-5);
    try testing.expectEqual(@as(u8, 1), got.groups[gid0].n_out);
    try testing.expectEqual(@as(Handle, 0), got.groups[gid0].exposed_out[0].member);
    try testing.expectEqual(@as(?group.GroupId, gid0), got.group_of[0]);
    // Fresh identity assigned on v1 load (monotonic from 1).
    try testing.expectEqual(@as(u64, 1), got.groups[gid0].identity);
    try testing.expectEqual(@as(u64, 2), got.next_identity);
    try testing.expectEqual(gid0, got.groupIdOfIdentity(1).?);
}

test "LEDG v2 fixture: identity is preserved on pack/unpack" {
    var src = fixtureLedgerOneGroup();
    const gid0: group.GroupId = 0;
    // Force a non-default identity so we are not just seeing alloc's first id.
    src.groups[gid0].identity = 0xA11CE;
    src.next_identity = 0xA11CE + 1;

    var v2: [LEDG_SIZE_V2]u8 = undefined;
    packLedger(&src, &v2);
    try testing.expectEqual(LEDG_SIZE_V2, v2.len);

    const got = try unpackLedger(&v2);
    try testing.expectEqual(@as(u64, 0xA11CE), got.groups[gid0].identity);
    try testing.expectEqual(@as(u64, 0xA11CE + 1), got.next_identity);
    try testing.expectEqual(gid0, got.groupIdOfIdentity(0xA11CE).?);
    try testing.expectApproxEqAbs(@as(f32, 40), got.groups[gid0].pos.x, 1e-5);
    try testing.expectEqual(@as(?group.GroupId, gid0), got.group_of[0]);
}

test "LEDG v1→v2 migration: re-save after legacy load writes identity-bearing size" {
    var src = fixtureLedgerOneGroup();
    src.groups[0].identity = 0;
    src.next_identity = 1;

    var v1: [LEDG_SIZE_V1]u8 = undefined;
    packLedgerV1(&src, &v1);

    const loaded = try unpackLedger(&v1);
    try testing.expectEqual(@as(u64, 1), loaded.groups[0].identity);

    var v2: [LEDG_SIZE_V2]u8 = undefined;
    packLedger(&loaded, &v2);
    try testing.expectEqual(LEDG_SIZE_V2, v2.len);
    try testing.expect(v2.len != LEDG_SIZE_V1);

    const again = try unpackLedger(&v2);
    try testing.expectEqual(@as(u64, 1), again.groups[0].identity);
    try testing.expectEqual(loaded.groups[0].pos.x, again.groups[0].pos.x);
    try testing.expectEqual(loaded.groups[0].pos.y, again.groups[0].pos.y);
    try testing.expectEqual(loaded.groups[0].kind, again.groups[0].kind);
    try testing.expectEqual(loaded.group_of[0], again.group_of[0]);
}

test "LEDG wrong size is rejected" {
    var bad: [100]u8 = undefined;
    @memset(&bad, 0);
    try testing.expectError(error.CorruptLedger, unpackLedger(&bad));
}

test "noodle file I/O: save→load round-trip" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/project_io_test.noodle", .{&tmp.sub_path});

    const params = TestParams{ .tempo = 96, .idx = 1 };
    const input = sampleInput();
    try save(io, path, TestParams, params, input, gpa);
    var got = try load(io, gpa, path, TestParams);
    defer got.deinit(gpa);
    try testing.expectEqual(params, got.params);
    try testing.expectEqual(input.pattern.kick_on, got.pattern.kick_on);
    try testing.expectEqual(input.seed, got.seed);
    try testing.expectEqual(@as(usize, 2), got.nodes.len);
    try testing.expect(got.apply_node_params);
    try testing.expectEqual(@as(usize, 0), got.node_params.len);
}

fn expectNodeParamsEqual(want: []const NodeParamRecord, got: []const NodeParamRecord) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqual(w.saved_handle, g.saved_handle);
        try testing.expectEqual(w.params.len, g.params.len);
        for (w.params, g.params) |wp, gp| {
            try testing.expectEqualStrings(wp.name, gp.name);
            try testing.expectEqual(wp.value_kind, gp.value_kind);
            try testing.expectEqual(wp.value, gp.value);
        }
    }
}

fn appendRequiredChunks(w: *serde.Writer, input: EncodeInput) !void {
    var pbuf: [packedSize(TestParams)]u8 = undefined;
    packInto(TestParams, .{}, &pbuf);
    try w.addChunk(TAG_SPRM, &pbuf);
    var tbuf: [PTRN_SIZE]u8 = undefined;
    packPattern(input.pattern, &tbuf);
    try w.addChunk(TAG_PTRN, &tbuf);
    var sbuf: [SEED_SIZE]u8 = undefined;
    packSeed(input.seed, &sbuf);
    try w.addChunk(TAG_SEED, &sbuf);
    var songbuf: [SONG_SIZE]u8 = undefined;
    packSong(input.song, &songbuf);
    try w.addChunk(TAG_SONG, &songbuf);
    for (input.nodes) |n| {
        var buf: [NODE_SIZE]u8 = undefined;
        packNode(n, &buf);
        try w.addChunk(TAG_NODE, &buf);
    }
    for (input.edges) |e| {
        var buf: [EDGE_SIZE]u8 = undefined;
        packEdge(e, &buf);
        try w.addChunk(TAG_EDGE, &buf);
    }
}

fn appendLedgGenr(w: *serde.Writer, input: EncodeInput) !void {
    var lbuf: [LEDG_SIZE]u8 = undefined;
    packLedger(input.ledger, &lbuf);
    try w.addChunk(TAG_LEDG, &lbuf);
    var gbuf: [GENR_SIZE]u8 = undefined;
    packGenr(input.genr, &gbuf);
    try w.addChunk(TAG_GENR, &gbuf);
}

fn appendNidmNref(w: *serde.Writer, input: EncodeInput) !void {
    var nidm_buf: [NIDM_SIZE]u8 = undefined;
    packNidm(input.next_node_id, &nidm_buf);
    try w.addChunk(TAG_NIDM, &nidm_buf);
    var nref_buf: [2 + MAX_NPRM_NODES * NREF_ENTRY_SIZE]u8 = undefined;
    const nref_size = nrefPayloadSize(input.node_id_refs);
    packNref(input.node_id_refs, nref_buf[0..nref_size]);
    try w.addChunk(TAG_NREF, nref_buf[0..nref_size]);
}

/// For NPRM fixtures: a scalar that leans non-default while still being accepted by validateParam.
/// For an integer-backed field, mid can be fractional, so a @trunc'd candidate is preferred.
fn scalarFixtureValue(kind: graph_io.ModuleKind, name: []const u8, s: modular.ScalarDesc) f32 {
    const mid = s.min + (s.max - s.min) * 0.5;
    const candidates = [_]f32{
        @trunc(if (mid != s.default) mid else s.max),
        if (mid != s.default) mid else s.max,
        @trunc(s.max),
        @trunc(s.min),
        s.default,
    };
    var fallback: ?f32 = null;
    for (candidates) |c| {
        if (c < s.min or c > s.max) continue;
        modular.validateParam(kind, name, .{ .scalar = c }) catch continue;
        if (c != s.default) return c;
        if (fallback == null) fallback = c;
    }
    return fallback orelse s.default;
}

test "NPRM round-trip: all ModuleKind descriptors + 303 fixture bit-identical" {
    const gpa = testing.allocator;

    // (1) Turn every ModuleKind's descriptors into NodeParamRecords (scalar = non-default, choice = every index)
    var records: std.ArrayList(NodeParamRecord) = .empty;
    defer {
        for (records.items) |rec| gpa.free(@constCast(rec.params));
        records.deinit(gpa);
    }
    var nodes: std.ArrayList(NodeEntry) = .empty;
    defer nodes.deinit(gpa);

    var handle: u16 = 0;
    inline for (std.enums.values(graph_io.ModuleKind)) |kind| {
        const descs = modular.descriptors(kind);
        var params: std.ArrayList(NodeParam) = .empty;
        defer params.deinit(gpa);
        for (descs) |desc| {
            switch (desc.kind) {
                .scalar => |s| {
                    const v = scalarFixtureValue(kind, desc.name, s);
                    try params.append(gpa, .{
                        .name = desc.name,
                        .value_kind = VALUE_KIND_SCALAR,
                        .value = @bitCast(v),
                    });
                },
                .choice => |c| {
                    // Every choice index cannot be written as separate param rows (duplicate names are forbidden), so
                    // instead of putting each index on a separate node of the same kind, here we save only the
                    // single highest non-default index; every index is validated in the dedicated block below.
                    const idx: u32 = if (c.options.len > 1)
                        @intCast(c.options.len - 1)
                    else
                        @intCast(c.default);
                    try params.append(gpa, .{
                        .name = desc.name,
                        .value_kind = VALUE_KIND_CHOICE,
                        .value = idx,
                    });
                },
            }
        }
        const owned = try params.toOwnedSlice(gpa);
        try records.append(gpa, .{ .saved_handle = handle, .params = owned });
        try nodes.append(gpa, .{ .handle = handle, .kind = kind, .x = @floatFromInt(handle), .y = 0 });
        handle += 1;
    }

    // Every choice index: VCO waveform / antialias (bool) are covered on separate handles
    {
        const wave_opts = modular.descriptors(.vco)[1].kind.choice.options;
        var wi: u32 = 0;
        while (wi < wave_opts.len) : (wi += 1) {
            const p = try gpa.alloc(NodeParam, 1);
            p[0] = .{ .name = "waveform", .value_kind = VALUE_KIND_CHOICE, .value = wi };
            try records.append(gpa, .{ .saved_handle = handle, .params = p });
            try nodes.append(gpa, .{ .handle = handle, .kind = .vco, .x = 0, .y = @floatFromInt(wi) });
            handle += 1;
        }
        var bi: u32 = 0;
        while (bi < 2) : (bi += 1) {
            const p = try gpa.alloc(NodeParam, 1);
            p[0] = .{ .name = "antialias", .value_kind = VALUE_KIND_CHOICE, .value = bi };
            try records.append(gpa, .{ .saved_handle = handle, .params = p });
            try nodes.append(gpa, .{ .handle = handle, .kind = .vco, .x = 1, .y = @floatFromInt(bi) });
            handle += 1;
        }
    }

    // The 303-equivalent: VCF + VCA
    const vcf_params = [_]NodeParam{
        .{ .name = "cutoff", .value_kind = VALUE_KIND_SCALAR, .value = @bitCast(@as(f32, 600.0)) },
        .{ .name = "resonance", .value_kind = VALUE_KIND_SCALAR, .value = @bitCast(@as(f32, 0.9)) },
        .{ .name = "mod_octaves", .value_kind = VALUE_KIND_SCALAR, .value = @bitCast(@as(f32, 1.0)) },
    };
    const vca_params = [_]NodeParam{
        .{ .name = "gain", .value_kind = VALUE_KIND_SCALAR, .value = @bitCast(@as(f32, 0.7)) },
    };
    const vcf_owned = try gpa.dupe(NodeParam, &vcf_params);
    const vca_owned = try gpa.dupe(NodeParam, &vca_params);
    try records.append(gpa, .{ .saved_handle = handle, .params = vcf_owned });
    try nodes.append(gpa, .{ .handle = handle, .kind = .vcf, .x = 10, .y = 20 });
    handle += 1;
    try records.append(gpa, .{ .saved_handle = handle, .params = vca_owned });
    try nodes.append(gpa, .{ .handle = handle, .kind = .vca, .x = 30, .y = 40 });

    var input = sampleInput();
    input.nodes = nodes.items;
    input.edges = &.{};
    input.node_params = records.items;
    var refs_buf: [MAX_NPRM_NODES]NodeIdRef = undefined;
    for (nodes.items, 0..) |n, i| {
        refs_buf[i] = .{ .saved_handle = n.handle, .id = NodeId.fromRaw(@as(u64, @intCast(i)) + 1) };
    }
    input.node_id_refs = refs_buf[0..nodes.items.len];
    input.next_node_id = @as(u64, @intCast(nodes.items.len)) + 1;

    try validateNodeParams(input.nodes, input.node_params);

    const bytes = try encode(TestParams, gpa, .{}, input);
    defer gpa.free(bytes);
    var got = try decode(TestParams, gpa, bytes);
    defer got.deinit(gpa);

    try testing.expect(got.apply_node_params);
    try expectNodeParamsEqual(input.node_params, got.node_params);

    // encode→decode→encode canonical
    const again = try encode(TestParams, gpa, got.params, .{
        .pattern = got.pattern,
        .seed = got.seed,
        .song = got.song,
        .nodes = got.nodes,
        .edges = got.edges,
        .node_params = got.node_params,
        .node_id_refs = got.node_id_refs,
        .next_node_id = got.next_node_id,
        .ledger = &got.ledger,
        .genr = got.genr,
    });
    defer gpa.free(again);
    try testing.expectEqualSlices(u8, bytes, again);
}

test "NPRM absent: legacy schema 1 keeps apply_node_params=false" {
    const gpa = testing.allocator;
    const input = sampleInput();
    // schema 1 (no NIDM/NREF) = fallback numbering
    var w = try serde.Writer.init(gpa, magic, schema_version_v1);
    defer w.deinit();
    try appendRequiredChunks(&w, input);
    // No NPRM
    try appendLedgGenr(&w, input);
    const bytes = try w.finish();
    defer gpa.free(bytes);

    var got = try decode(TestParams, gpa, bytes);
    defer got.deinit(gpa);
    try testing.expect(!got.apply_node_params);
    try testing.expectEqual(@as(usize, 0), got.node_params.len);
    try testing.expectEqual(@as(usize, 2), got.nodes.len);
    try testing.expectEqual(input.nodes[0], got.nodes[0]);
    try testing.expectEqual(@as(usize, 1), got.edges.len);
    try testing.expect(got.apply_ledger);
    try testing.expect(got.apply_genr);
    try testing.expectEqual(@as(u64, 1), got.node_id_refs[0].id.raw());
    try testing.expectEqual(@as(u64, 3), got.next_node_id);
}

test "NPRM unknown name / descriptor count mismatch: decode ok, validate skips unknown" {
    const gpa = testing.allocator;
    const nodes = [_]NodeEntry{.{ .handle = 0, .kind = .vca, .x = 0, .y = 0 }};
    // VCA has only gain. Extra unknown fields plus omissions are fine
    const params = [_]NodeParam{
        .{ .name = "gain", .value_kind = VALUE_KIND_SCALAR, .value = @bitCast(@as(f32, 0.5)) },
        .{ .name = "future_param", .value_kind = VALUE_KIND_SCALAR, .value = @bitCast(@as(f32, 1.0)) },
    };
    const records = [_]NodeParamRecord{.{ .saved_handle = 0, .params = &params }};
    try validateNodeParams(&nodes, &records); // unknown skip

    var input = sampleInput();
    input.nodes = &nodes;
    input.edges = &.{};
    input.node_params = &records;
    input.node_id_refs = &.{.{ .saved_handle = 0, .id = NodeId.fromRaw(1) }};
    input.next_node_id = 2;
    const bytes = try encode(TestParams, gpa, .{}, input);
    defer gpa.free(bytes);
    var got = try decode(TestParams, gpa, bytes);
    defer got.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), got.node_params[0].params.len);
    try testing.expectEqualStrings("future_param", got.node_params[0].params[1].name);
}

test "NPRM corrupt: duplicate chunk / version / short / dup name / NaN / choice OOR" {
    const gpa = testing.allocator;
    const input = sampleInput();

    // duplicate NPRM
    {
        var w = try serde.Writer.init(gpa, magic, schema_version_v1);
        defer w.deinit();
        try appendRequiredChunks(&w, input);
        var nprm: [4]u8 = undefined;
        std.mem.writeInt(u16, nprm[0..2], NPRM_VERSION, .little);
        std.mem.writeInt(u16, nprm[2..4], 0, .little);
        try w.addChunk(TAG_NPRM, &nprm);
        try w.addChunk(TAG_NPRM, &nprm);
        try appendLedgGenr(&w, input);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.DuplicateChunk, decode(TestParams, gpa, bytes));
    }
    // unsupported version
    {
        var w = try serde.Writer.init(gpa, magic, schema_version_v1);
        defer w.deinit();
        try appendRequiredChunks(&w, input);
        var nprm: [4]u8 = undefined;
        std.mem.writeInt(u16, nprm[0..2], NPRM_VERSION + 1, .little);
        std.mem.writeInt(u16, nprm[2..4], 0, .little);
        try w.addChunk(TAG_NPRM, &nprm);
        try appendLedgGenr(&w, input);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.UnsupportedNprmVersion, decode(TestParams, gpa, bytes));
    }
    // short payload
    {
        var w = try serde.Writer.init(gpa, magic, schema_version_v1);
        defer w.deinit();
        try appendRequiredChunks(&w, input);
        try w.addChunk(TAG_NPRM, &[_]u8{ 1, 0 }); // only 2 bytes
        try appendLedgGenr(&w, input);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptNprm, decode(TestParams, gpa, bytes));
    }
    // duplicate param name
    {
        const dup = [_]NodeParam{
            .{ .name = "gain", .value_kind = VALUE_KIND_SCALAR, .value = @bitCast(@as(f32, 0.5)) },
            .{ .name = "gain", .value_kind = VALUE_KIND_SCALAR, .value = @bitCast(@as(f32, 0.6)) },
        };
        const rec = [_]NodeParamRecord{.{ .saved_handle = 0, .params = &dup }};
        var w = try serde.Writer.init(gpa, magic, schema_version_v1);
        defer w.deinit();
        try appendRequiredChunks(&w, input);
        const nprm_size = nprmPayloadSize(&rec);
        const nprm_buf = try gpa.alloc(u8, nprm_size);
        defer gpa.free(nprm_buf);
        packNprm(&rec, nprm_buf);
        try w.addChunk(TAG_NPRM, nprm_buf);
        try appendLedgGenr(&w, input);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.DuplicateNprmParamName, decode(TestParams, gpa, bytes));
    }
    // NaN scalar
    {
        const nan_bits: u32 = @bitCast(std.math.nan(f32));
        const bad = [_]NodeParam{.{ .name = "gain", .value_kind = VALUE_KIND_SCALAR, .value = nan_bits }};
        const rec = [_]NodeParamRecord{.{ .saved_handle = 0, .params = &bad }};
        var w = try serde.Writer.init(gpa, magic, schema_version_v1);
        defer w.deinit();
        try appendRequiredChunks(&w, input);
        const nprm_size = nprmPayloadSize(&rec);
        const nprm_buf = try gpa.alloc(u8, nprm_size);
        defer gpa.free(nprm_buf);
        packNprm(&rec, nprm_buf);
        try w.addChunk(TAG_NPRM, nprm_buf);
        try appendLedgGenr(&w, input);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.NonFiniteField, decode(TestParams, gpa, bytes));
    }
    // Inf scalar
    {
        const inf_bits: u32 = @bitCast(std.math.inf(f32));
        const bad = [_]NodeParam{.{ .name = "gain", .value_kind = VALUE_KIND_SCALAR, .value = inf_bits }};
        const rec = [_]NodeParamRecord{.{ .saved_handle = 0, .params = &bad }};
        var w = try serde.Writer.init(gpa, magic, schema_version_v1);
        defer w.deinit();
        try appendRequiredChunks(&w, input);
        const nprm_size = nprmPayloadSize(&rec);
        const nprm_buf = try gpa.alloc(u8, nprm_size);
        defer gpa.free(nprm_buf);
        packNprm(&rec, nprm_buf);
        try w.addChunk(TAG_NPRM, nprm_buf);
        try appendLedgGenr(&w, input);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.NonFiniteField, decode(TestParams, gpa, bytes));
    }
    // choice index out of range (validate)
    {
        const nodes = [_]NodeEntry{.{ .handle = 0, .kind = .vca, .x = 0, .y = 0 }};
        // VCA gain is a scalar. Not a WrongValueKind; the OOR case uses VCO waveform
        const nodes2 = [_]NodeEntry{.{ .handle = 1, .kind = .vco, .x = 0, .y = 0 }};
        const bad = [_]NodeParam{.{ .name = "waveform", .value_kind = VALUE_KIND_CHOICE, .value = 99 }};
        const rec = [_]NodeParamRecord{.{ .saved_handle = 1, .params = &bad }};
        try testing.expectError(error.ChoiceIndexOutOfRange, validateNodeParams(&nodes2, &rec));
        _ = nodes;
    }
    // OutOfRange scalar (validate)
    {
        const nodes = [_]NodeEntry{.{ .handle = 0, .kind = .vca, .x = 0, .y = 0 }};
        const bad = [_]NodeParam{.{ .name = "gain", .value_kind = VALUE_KIND_SCALAR, .value = @bitCast(@as(f32, 99.0)) }};
        const rec = [_]NodeParamRecord{.{ .saved_handle = 0, .params = &bad }};
        try testing.expectError(error.OutOfRange, validateNodeParams(&nodes, &rec));
    }
    // A fractional value for an integer-backed field (TuringMachine.bits) is rejected by validate
    {
        const nodes = [_]NodeEntry{.{ .handle = 0, .kind = .turing, .x = 0, .y = 0 }};
        const bad = [_]NodeParam{.{ .name = "bits", .value_kind = VALUE_KIND_SCALAR, .value = @bitCast(@as(f32, 8.5)) }};
        const rec = [_]NodeParamRecord{.{ .saved_handle = 0, .params = &bad }};
        try testing.expectError(error.OutOfRange, validateNodeParams(&nodes, &rec));
    }
    // duplicate saved_handle
    {
        const p0 = [_]NodeParam{.{ .name = "gain", .value_kind = VALUE_KIND_SCALAR, .value = @bitCast(@as(f32, 0.5)) }};
        const p1 = [_]NodeParam{.{ .name = "gain", .value_kind = VALUE_KIND_SCALAR, .value = @bitCast(@as(f32, 0.6)) }};
        const rec = [_]NodeParamRecord{
            .{ .saved_handle = 3, .params = &p0 },
            .{ .saved_handle = 3, .params = &p1 },
        };
        var w = try serde.Writer.init(gpa, magic, schema_version_v1);
        defer w.deinit();
        try appendRequiredChunks(&w, input);
        const nprm_size = nprmPayloadSize(&rec);
        const nprm_buf = try gpa.alloc(u8, nprm_size);
        defer gpa.free(nprm_buf);
        packNprm(&rec, nprm_buf);
        try w.addChunk(TAG_NPRM, nprm_buf);
        try appendLedgGenr(&w, input);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptNprm, decode(TestParams, gpa, bytes));
    }
}

test "NIDM/NREF: round-trip + corrupt duplicate/zero/unknown/next" {
    const gpa = testing.allocator;
    const input = sampleInput();
    const bytes = try encode(TestParams, gpa, .{}, input);
    defer gpa.free(bytes);
    var got = try decode(TestParams, gpa, bytes);
    defer got.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), got.node_id_refs.len);
    try testing.expectEqual(@as(u64, 1), got.node_id_refs[0].id.raw());
    try testing.expectEqual(@as(u64, 3), got.next_node_id);

    // id=0
    try testing.expectError(error.CorruptNref, validateNodeIdRefs(input.nodes, &.{
        .{ .saved_handle = 0, .id = .invalid },
        .{ .saved_handle = 1, .id = NodeId.fromRaw(2) },
    }, 3));
    // duplicate id
    try testing.expectError(error.DuplicateNodeId, validateNodeIdRefs(input.nodes, &.{
        .{ .saved_handle = 0, .id = NodeId.fromRaw(1) },
        .{ .saved_handle = 1, .id = NodeId.fromRaw(1) },
    }, 3));
    // unknown handle
    try testing.expectError(error.CorruptNref, validateNodeIdRefs(input.nodes, &.{
        .{ .saved_handle = 0, .id = NodeId.fromRaw(1) },
        .{ .saved_handle = 9, .id = NodeId.fromRaw(2) },
    }, 3));
    // duplicate saved_handle (a hole in the bijection)
    try testing.expectError(error.CorruptNref, validateNodeIdRefs(input.nodes, &.{
        .{ .saved_handle = 0, .id = NodeId.fromRaw(1) },
        .{ .saved_handle = 0, .id = NodeId.fromRaw(2) },
    }, 3));
    // next <= max
    try testing.expectError(error.CorruptNidm, validateNodeIdRefs(&sample_nodes, &sample_nrefs, 2));
}

test "NREF corrupt via decode: duplicate id / duplicate handle (leak-free)" {
    const gpa = testing.allocator;

    // duplicate NodeId
    {
        var input = sampleInput();
        const bad_refs = [_]NodeIdRef{
            .{ .saved_handle = 0, .id = NodeId.fromRaw(1) },
            .{ .saved_handle = 1, .id = NodeId.fromRaw(1) },
        };
        input.node_id_refs = &bad_refs;
        const bytes = try encode(TestParams, gpa, .{}, input);
        defer gpa.free(bytes);
        try testing.expectError(error.DuplicateNodeId, decode(TestParams, gpa, bytes));
    }
    // duplicate saved_handle
    {
        var input = sampleInput();
        const bad_refs = [_]NodeIdRef{
            .{ .saved_handle = 0, .id = NodeId.fromRaw(1) },
            .{ .saved_handle = 0, .id = NodeId.fromRaw(2) },
        };
        input.node_id_refs = &bad_refs;
        const bytes = try encode(TestParams, gpa, .{}, input);
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptNref, decode(TestParams, gpa, bytes));
    }
}
