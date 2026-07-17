//! apps/patch 統合プロジェクト直列化（TASK-105.4）。
//!
//! libs/serde の versioned container に次の chunk を載せる（magic = `VPRJ`、schema_version=1）:
//!   - SPRM: scalar Params（既存 MPRJ フラットパッカー）
//!   - PTRN: grid/303 pattern（PatternPayload 33B）
//!   - SEED: base_seed + notation_seed + notation_counter（20B）
//!   - SONG: Phrase/Chain/Song（1890B）
//!   - NODE×N / EDGE×M: 生グラフ（既存 PTCG の 11B/6B layout）
//!   - LEDG: group.Ledger 全体（固定長）
//!   - GENR: LofiPatch 生成 role → 保存 handle 対応（統合形式のみ）
//!
//! writer は VPRJ のみ。reader は VPRJ + 旧 MDLP / MPRJ / PTCG を自動判定する。
//!
//! **ModuleKind 互換**: enum ordinal は永続化の一部。新 kind は末尾追加のみ。
//! 並べ替え・削除・名前変更は禁止。未知 ordinal は NODE 単位で skip（PTCG 互換）。
//!
//! **循環 import 回避**: Params/SongData/LofiPatch は import しない。
//! Ledger は group.Ledger、graph は graph_io の NodeEntry/EdgeEntry で受け渡し。
//!
//! ホットパス宣言: encode/decode/save/load は **イベント時のみ**。RT 経路には触れない。

const std = @import("std");
const serde = @import("serde");
const pattern_io = @import("pattern_io.zig");
const graph_io = @import("graph_io.zig");
const group = @import("group.zig");

/// 'VPRJ'（video-proto project）little-endian u32。
pub const magic: u32 = @as(u32, 'V') | (@as(u32, 'P') << 8) | (@as(u32, 'R') << 16) | (@as(u32, 'J') << 24);
/// 旧 MPRJ magic（読込互換のみ。writer は使わない）。
pub const mprj_magic: u32 = @as(u32, 'M') | (@as(u32, 'P') << 8) | (@as(u32, 'R') << 16) | (@as(u32, 'J') << 24);
pub const schema_version: u16 = 1;

const TAG_SPRM: [4]u8 = "SPRM".*;
const TAG_PTRN: [4]u8 = "PTRN".*;
const TAG_SEED: [4]u8 = "SEED".*;
const TAG_SONG: [4]u8 = "SONG".*;
const TAG_NODE: [4]u8 = "NODE".*;
const TAG_EDGE: [4]u8 = "EDGE".*;
const TAG_LEDG: [4]u8 = "LEDG".*;
const TAG_GENR: [4]u8 = "GENR".*;

pub const FormatKind = enum { vprj, mdlp, mprj, ptcg };

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
    DuplicateChunk,
    UnsupportedSchemaVersion,
    NonFiniteField,
    BadMagic,
};

pub const NodeEntry = graph_io.NodeEntry;
pub const EdgeEntry = graph_io.EdgeEntry;
pub const Handle = graph_io.Handle;

/// 存在しない role の sentinel（DynGraph.isActive(0xffff)==false）。
pub const INVALID_ROLE_HANDLE: u16 = 0xffff;

/// LofiPatch 生成 role の固定順（GENR payload）。追加は末尾のみ。
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

const NODE_SIZE: usize = 11;
const EDGE_SIZE: usize = 6;
const PTRN_SIZE: usize = 33;
const SEED_SIZE: usize = 20;
const SONG_SIZE: usize = 1890;
const GENR_SIZE: usize = GenRole.count * 2;
// LEDG: group_of[48]u8 + groups[8] * (16 header + 8*13*2 exposed) = 48 + 8*224 = 1840
const LEDG_GROUP_SIZE: usize = 224;
const LEDG_SIZE: usize = group.GROUP_HANDLE_BASE + group.MAX_GROUPS * LEDG_GROUP_SIZE;

comptime {
    if (GenRole.count != 30) @compileError("GENR role count changed; update schema or tests");
    if (LEDG_SIZE != 1840) @compileError("LEDG size mismatch");
}

// ── scalar Params パッカー ───────────────────────────────────────────────────

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

// ── NODE / EDGE（PTCG layout 再利用）─────────────────────────────────────────

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
        off += 16;
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

fn unpackLedger(bytes: []const u8) error{ CorruptLedger, NonFiniteField }!group.Ledger {
    if (bytes.len != LEDG_SIZE) return error.CorruptLedger;
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
        if (g.n_in > group.MAX_EXPOSED or g.n_out > group.MAX_EXPOSED) return error.CorruptLedger;
        if (g.template_n_in > g.n_in or g.template_n_out > g.n_out) return error.CorruptLedger;
        off += 16;
        for (&g.exposed_in) |*ep| {
            ep.* = try unpackExposed(bytes[off..][0..13]);
            off += 13;
        }
        for (&g.exposed_out) |*ep| {
            ep.* = try unpackExposed(bytes[off..][0..13]);
            off += 13;
        }
        if (g.active) {
            // exposed の member は group_of と整合（先頭 n_* 件のみ検証）
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
    // group_of が指す group は active であること
    for (ledger.group_of) |gid_opt| {
        if (gid_opt) |gid| {
            if (!ledger.groups[gid].active) return error.CorruptLedger;
        }
    }
    return ledger;
}

/// 旧 handle → 新 handle 対応で Ledger を remap する（slot/順序/座標はそのまま）。
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

/// mapping で GENR handles を remap。INVALID はそのまま。未対応 handle は INVALID へ落とす。
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
        ledger: group.Ledger,
        genr: GenRoleHandles,
        /// 部分形式で「このフィールド群を適用すべきか」
        apply_params_pattern: bool,
        apply_seed_song: bool,
        apply_graph: bool,
        apply_ledger: bool,
        apply_genr: bool,

        pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
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
    ledger: *const group.Ledger,
    genr: GenRoleHandles,
};

/// VPRJ 全体を encode（caller が free）。
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

    var lbuf: [LEDG_SIZE]u8 = undefined;
    packLedger(input.ledger, &lbuf);
    try w.addChunk(TAG_LEDG, &lbuf);

    var gbuf: [GENR_SIZE]u8 = undefined;
    packGenr(input.genr, &gbuf);
    try w.addChunk(TAG_GENR, &gbuf);

    return w.finish();
}

/// 旧 MPRJ fixture 生成用（テスト専用。本番 writer は VPRJ のみ）。
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
        .ledger = .{},
        .genr = .{},
        .apply_params_pattern = false,
        .apply_seed_song = false,
        .apply_graph = false,
        .apply_ledger = false,
        .apply_genr = false,
    };
}

fn decodeVprj(comptime P: type, gpa: std.mem.Allocator, bytes: []const u8) !Decoded(P) {
    const container = try serde.Container.parse(bytes, magic);
    if (container.schemaVersion() > schema_version) return error.UnsupportedSchemaVersion;

    var seen_sprm = false;
    var seen_ptrn = false;
    var seen_seed = false;
    var seen_song = false;
    var seen_ledg = false;
    var seen_genr = false;
    var sprm: ?[]const u8 = null;
    var ptrn: ?[]const u8 = null;
    var seed_c: ?[]const u8 = null;
    var song_c: ?[]const u8 = null;
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
        // 未知 tag は無視
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

    return .{
        .format = .vprj,
        .params = try unpackFrom(P, sprm_b),
        .pattern = unpackPattern(ptrn_b),
        .seed = unpackSeed(seed_b),
        .song = song,
        .nodes = try nodes.toOwnedSlice(gpa),
        .edges = try edges.toOwnedSlice(gpa),
        .ledger = try unpackLedger(ledg_b),
        .genr = try unpackGenr(genr_b),
        .apply_params_pattern = true,
        .apply_seed_song = true,
        .apply_graph = true,
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
    out.apply_graph = true;
    out.apply_ledger = true; // 空 Ledger へリセット
    out.apply_genr = true; // invalidate
    out.ledger = .{};
    out.genr = .{}; // all INVALID
    return out;
}

/// magic 自動判定で decode。nodes/edges は gpa 確保（caller が deinit）。
pub fn decode(comptime P: type, gpa: std.mem.Allocator, bytes: []const u8) !Decoded(P) {
    if (bytes.len < 4) return error.BadMagic;
    const m = std.mem.readInt(u32, bytes[0..4], .little);
    if (m == magic) return decodeVprj(P, gpa, bytes);
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
        .nodes = &.{
            .{ .handle = 0, .kind = .vco, .x = 10, .y = 20 },
            .{ .handle = 1, .kind = .output, .x = 100, .y = 0 },
        },
        .edges = &.{
            .{ .src_handle = 0, .src_out = 0, .dst_handle = 1, .dst_in = 0 },
        },
        .ledger = &group.Ledger{},
        .genr = blk: {
            var g: GenRoleHandles = .{};
            g.set(.clock, 0);
            g.set(.output, 1);
            break :blk g;
        },
    };
}

test "VPRJ encode/decode: full field round-trip" {
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

    try testing.expect(got.format == .vprj);
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
}

test "VPRJ encode→decode→encode: canonical bytes bit-identical" {
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
        .ledger = &decoded.ledger,
        .genr = decoded.genr,
    });
    defer gpa.free(b);
    try testing.expectEqualSlices(u8, a, b);
}

test "VPRJ decode: unknown chunk skip / DuplicateChunk / missing required" {
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

test "VPRJ decode: UnsupportedSchemaVersion / CrcMismatch / CorruptLedger" {
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

test "VPRJ file I/O: save→load round-trip" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/project_io_test.vprj", .{&tmp.sub_path});

    const params = TestParams{ .tempo = 96, .idx = 1 };
    const input = sampleInput();
    try save(io, path, TestParams, params, input, gpa);
    var got = try load(io, gpa, path, TestParams);
    defer got.deinit(gpa);
    try testing.expectEqual(params, got.params);
    try testing.expectEqual(input.pattern.kick_on, got.pattern.kick_on);
    try testing.expectEqual(input.seed, got.seed);
    try testing.expectEqual(@as(usize, 2), got.nodes.len);
}
