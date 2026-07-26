//! A pure parser for the generation-layer harness actions of apps/patch.
//!
//! Hot-path declaration: parsing results here are dispatched only at event time (once per harness
//! `action <name> [args]` command). It is neither a per-frame per-pixel loop nor a per-sample RT path,
//! so the performance rules (SIMD triple-set, etc.) do not apply.
//!
//! This file **depends only on std** and never imports App / kit / platform / modular
//! (mirroring pixie's `actions.zig`; this avoids a circular import with main.zig and keeps it unit-testable).
//! Resolving track names (kick/hat/clap/bass, etc.) to an enum is done on the main.zig side, which knows App's concrete type
//! (the same separation used for pixie's `ToolKind` resolution; this file just passes the name through).
//!
//! The mini-notation `parseNotation` / `evalNotation` are also self-contained in this file (fixed capacity, no allocation,
//! deterministic). Evaluation happens only when the action runs; only the evaluated mask is published to RT.

const std = @import("std");

pub const ParseError = error{
    Empty,
    InvalidNumber,
    NonFinite,
    TooManyTokens,
    UnknownBool,
    OutOfRange,
    // mini-notation
    InvalidNotation,
    NestTooDeep,
    Unbalanced,
    EuclidBad,
    TooManyNodes,
};

fn tokenize(args: []const u8) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, args, " \t");
}

fn expectExhausted(it: *std.mem.TokenIterator(u8, .any)) ParseError!void {
    if (it.next() != null) return error.TooManyTokens;
}

pub const NameF32 = struct { name: []const u8, value: f32 };

/// Two tokens, "<name> <value>" (a generic f32 setter; the same shape as sibling parsers like mute/lock).
/// `set_param` itself accepts only the 3-token NodeId form; this function is for other actions and tests.
/// NaN/Inf are rejected with `error.NonFinite` (fail-fast).
pub fn parseNameF32(args: []const u8) ParseError!NameF32 {
    var it = tokenize(args);
    const name = it.next() orelse return error.Empty;
    const v_tok = it.next() orelse return error.Empty;
    const value = std.fmt.parseFloat(f32, v_tok) catch return error.InvalidNumber;
    if (!std.math.isFinite(value)) return error.NonFinite;
    try expectExhausted(&it);
    return .{ .name = name, .value = value };
}

pub const NameBool = struct { name: []const u8, on: bool };

/// Two tokens, "<name> <0|1>" (for `set_mute`/`set_lock`).
pub fn parseNameBool(args: []const u8) ParseError!NameBool {
    var it = tokenize(args);
    const name = it.next() orelse return error.Empty;
    const b_tok = it.next() orelse return error.Empty;
    const on = if (std.mem.eql(u8, b_tok, "0"))
        false
    else if (std.mem.eql(u8, b_tok, "1"))
        true
    else
        return error.UnknownBool;
    try expectExhausted(&it);
    return .{ .name = name, .on = on };
}

pub const NameU8 = struct { name: []const u8, value: u8 };

/// Two tokens, "<name> <0-255>" (for `toggle_step`: track name + step index).
pub fn parseNameU8(args: []const u8) ParseError!NameU8 {
    var it = tokenize(args);
    const name = it.next() orelse return error.Empty;
    const v_tok = it.next() orelse return error.Empty;
    const value = std.fmt.parseUnsigned(u8, v_tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return .{ .name = name, .value = value };
}

pub const TwoU8 = struct { a: u8, b: u8 };

/// Two tokens, "<a> <b>" (for `set_pitch <step> <deg>`).
pub fn parseTwoU8(args: []const u8) ParseError!TwoU8 {
    var it = tokenize(args);
    const a_tok = it.next() orelse return error.Empty;
    const a = std.fmt.parseUnsigned(u8, a_tok, 10) catch return error.InvalidNumber;
    const b_tok = it.next() orelse return error.Empty;
    const b = std.fmt.parseUnsigned(u8, b_tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return .{ .a = a, .b = b };
}

/// One token, "<0|1>" (for `set_evolve`).
pub fn parseBool01(args: []const u8) ParseError!bool {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const on = if (std.mem.eql(u8, tok, "0"))
        false
    else if (std.mem.eql(u8, tok, "1"))
        true
    else
        return error.UnknownBool;
    try expectExhausted(&it);
    return on;
}

/// One token, "<u64>" (for `seed`; decimal).
pub fn parseU64(args: []const u8) ParseError!u64 {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const value = std.fmt.parseUnsigned(u64, tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return value;
}

/// For `save_pattern`/`load_pattern`: only leading/trailing whitespace is trimmed; internal whitespace is preserved
/// (a path is treated as a single string that may contain spaces; the same shape as pixie/synth's `parsePath`).
pub fn parsePath(args: []const u8) ParseError![]const u8 {
    const trimmed = std.mem.trim(u8, args, " \t");
    if (trimmed.len == 0) return error.Empty;
    return trimmed;
}

pub const RenderArgs = struct {
    path: []const u8,
    seconds: u32,
};

/// For `render <path> <seconds>`: path is one token with no spaces, seconds is a u32 in range 1..=600.
/// Out-of-range values yield `error.OutOfRange` (fail-fast, not clamped).
pub fn parseRender(args: []const u8) ParseError!RenderArgs {
    var it = tokenize(args);
    const path = it.next() orelse return error.Empty;
    const sec_tok = it.next() orelse return error.Empty;
    const seconds = std.fmt.parseUnsigned(u32, sec_tok, 10) catch return error.InvalidNumber;
    if (seconds < 1 or seconds > 600) return error.OutOfRange;
    try expectExhausted(&it);
    return .{ .path = path, .seconds = seconds };
}

// ============================================================================
// Song/Chain/Phrase action parsers (std only, fixed capacity, fail-fast)
// ============================================================================

/// For `phrase_capture <idx>` / `song_len <n>` / `song_goto <row>`: one u8 token.
pub fn parseU8(args: []const u8) ParseError!u8 {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const value = std.fmt.parseUnsigned(u8, tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return value;
}

pub const ChainSetArgs = struct {
    chain_idx: u8,
    /// A phrase index list (1..16)
    phrases: [16]u8 = undefined,
    len: u8 = 0,
};

/// `chain_set <chain_idx> <phrase_idx...>` (1..16 phrase indices).
pub fn parseChainSet(args: []const u8) ParseError!ChainSetArgs {
    var it = tokenize(args);
    const c_tok = it.next() orelse return error.Empty;
    const chain_idx = std.fmt.parseUnsigned(u8, c_tok, 10) catch return error.InvalidNumber;
    var phrases: [16]u8 = undefined;
    var len: u8 = 0;
    while (it.next()) |tok| {
        if (len >= 16) return error.TooManyTokens;
        phrases[len] = std.fmt.parseUnsigned(u8, tok, 10) catch return error.InvalidNumber;
        len += 1;
    }
    if (len == 0) return error.Empty;
    return .{ .chain_idx = chain_idx, .phrases = phrases, .len = len };
}

pub const SongRowArgs = struct {
    row_idx: u8,
    kick: u8,
    hat: u8,
    clap: u8,
    bass: u8,
};

/// `song_row <row_idx> <kick_chain> <hat_chain> <clap_chain> <bass_chain>`.
pub fn parseSongRow(args: []const u8) ParseError!SongRowArgs {
    var it = tokenize(args);
    const r = it.next() orelse return error.Empty;
    const k = it.next() orelse return error.Empty;
    const h = it.next() orelse return error.Empty;
    const c = it.next() orelse return error.Empty;
    const b = it.next() orelse return error.Empty;
    const row_idx = std.fmt.parseUnsigned(u8, r, 10) catch return error.InvalidNumber;
    const kick = std.fmt.parseUnsigned(u8, k, 10) catch return error.InvalidNumber;
    const hat = std.fmt.parseUnsigned(u8, h, 10) catch return error.InvalidNumber;
    const clap = std.fmt.parseUnsigned(u8, c, 10) catch return error.InvalidNumber;
    const bass = std.fmt.parseUnsigned(u8, b, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return .{ .row_idx = row_idx, .kick = kick, .hat = hat, .clap = clap, .bass = bass };
}

// ============================================================================
// pattern_state's fixed wire format (a host evolve snapshot)
//
// A whitespace-separated token list, fixed at 28 elements:
//   kick_on hat_on clap_on bass_on bass_accent bass_slide
//   kick_lock hat_lock clap_lock bass_lock evolve mutation_count
//   deg0 .. deg15
// masks are 4-digit hex u16 values. lock/evolve are 0|1. mutation_count is a decimal u32.
// deg is a decimal i8. This fits within the 4096B action-frame limit.
// ============================================================================

pub const PatternStateArgs = struct {
    kick_on: u16,
    hat_on: u16,
    clap_on: u16,
    bass_on: u16,
    bass_accent: u16,
    bass_slide: u16,
    kick_lock: bool,
    hat_lock: bool,
    clap_lock: bool,
    bass_lock: bool,
    evolve: bool,
    mutation_count: u32,
    bass_deg: [16]i8,
};

fn parseHexU16(tok: []const u8) ParseError!u16 {
    if (tok.len == 0) return error.InvalidNumber;
    return std.fmt.parseUnsigned(u16, tok, 16) catch return error.InvalidNumber;
}

fn parseBool01Tok(tok: []const u8) ParseError!bool {
    if (std.mem.eql(u8, tok, "0")) return false;
    if (std.mem.eql(u8, tok, "1")) return true;
    return error.UnknownBool;
}

fn parseI8Tok(tok: []const u8) ParseError!i8 {
    return std.fmt.parseInt(i8, tok, 10) catch return error.InvalidNumber;
}

/// Decodes `pattern_state`'s wire args from the fixed format.
pub fn parsePatternState(args: []const u8) ParseError!PatternStateArgs {
    var it = tokenize(args);
    const kick_on = try parseHexU16(it.next() orelse return error.Empty);
    const hat_on = try parseHexU16(it.next() orelse return error.Empty);
    const clap_on = try parseHexU16(it.next() orelse return error.Empty);
    const bass_on = try parseHexU16(it.next() orelse return error.Empty);
    const bass_accent = try parseHexU16(it.next() orelse return error.Empty);
    const bass_slide = try parseHexU16(it.next() orelse return error.Empty);
    const kick_lock = try parseBool01Tok(it.next() orelse return error.Empty);
    const hat_lock = try parseBool01Tok(it.next() orelse return error.Empty);
    const clap_lock = try parseBool01Tok(it.next() orelse return error.Empty);
    const bass_lock = try parseBool01Tok(it.next() orelse return error.Empty);
    const evolve = try parseBool01Tok(it.next() orelse return error.Empty);
    const mut_tok = it.next() orelse return error.Empty;
    const mutation_count = std.fmt.parseUnsigned(u32, mut_tok, 10) catch return error.InvalidNumber;
    var bass_deg: [16]i8 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        bass_deg[i] = try parseI8Tok(it.next() orelse return error.Empty);
    }
    try expectExhausted(&it);
    return .{
        .kick_on = kick_on,
        .hat_on = hat_on,
        .clap_on = clap_on,
        .bass_on = bass_on,
        .bass_accent = bass_accent,
        .bass_slide = bass_slide,
        .kick_lock = kick_lock,
        .hat_lock = hat_lock,
        .clap_lock = clap_lock,
        .bass_lock = bass_lock,
        .evolve = evolve,
        .mutation_count = mutation_count,
        .bass_deg = bass_deg,
    };
}

/// Encodes `pattern_state`'s wire args into the fixed format (masks as lowercase 4-digit hex).
pub fn formatPatternState(buf: []u8, p: PatternStateArgs) error{TooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "{x:0>4} {x:0>4} {x:0>4} {x:0>4} {x:0>4} {x:0>4} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d}", .{
        p.kick_on,
        p.hat_on,
        p.clap_on,
        p.bass_on,
        p.bass_accent,
        p.bass_slide,
        @intFromBool(p.kick_lock),
        @intFromBool(p.hat_lock),
        @intFromBool(p.clap_lock),
        @intFromBool(p.bass_lock),
        @intFromBool(p.evolve),
        p.mutation_count,
        p.bass_deg[0],
        p.bass_deg[1],
        p.bass_deg[2],
        p.bass_deg[3],
        p.bass_deg[4],
        p.bass_deg[5],
        p.bass_deg[6],
        p.bass_deg[7],
        p.bass_deg[8],
        p.bass_deg[9],
        p.bass_deg[10],
        p.bass_deg[11],
        p.bass_deg[12],
        p.bass_deg[13],
        p.bass_deg[14],
        p.bass_deg[15],
    }) catch return error.TooLong;
}

// ============================================================================
// network_policy table (the single source for register and unit tests; std only)
// ============================================================================

/// A tag synonymous with platform.NetworkPolicy (a separate enum so it can be shared without depending on kit/platform).
pub const NetworkPolicyTag = enum { relay, local_only, reject_when_synced };

pub const PolicyEntry = struct {
    name: []const u8,
    policy: NetworkPolicyTag,
};

/// The network_policy for every registered patch action. Referenced by register* and the regression tests.
pub const PATCH_NETWORK_POLICIES = [_]PolicyEntry{
    .{ .name = "select_node", .policy = .local_only },
    .{ .name = "observe_param", .policy = .local_only },
    .{ .name = "add_node", .policy = .relay },
    .{ .name = "remove_node", .policy = .relay },
    .{ .name = "connect", .policy = .relay },
    .{ .name = "disconnect", .policy = .relay },
    .{ .name = "move_node", .policy = .relay },
    .{ .name = "add_macro", .policy = .relay },
    .{ .name = "remove_macro", .policy = .relay },
    .{ .name = "save_graph", .policy = .local_only },
    .{ .name = "load_graph", .policy = .reject_when_synced },
    .{ .name = "set_param", .policy = .relay },
    .{ .name = "set_mute", .policy = .relay },
    .{ .name = "set_lock", .policy = .relay },
    .{ .name = "set_evolve", .policy = .relay },
    .{ .name = "toggle_step", .policy = .relay },
    .{ .name = "set_pitch", .policy = .relay },
    .{ .name = "save_pattern", .policy = .local_only },
    .{ .name = "load_pattern", .policy = .reject_when_synced },
    .{ .name = "seed", .policy = .relay },
    .{ .name = "pattern", .policy = .relay },
    .{ .name = "pattern_state", .policy = .reject_when_synced },
    .{ .name = "phrase_capture", .policy = .relay },
    .{ .name = "chain_set", .policy = .relay },
    .{ .name = "song_row", .policy = .relay },
    .{ .name = "song_len", .policy = .relay },
    .{ .name = "song_loop", .policy = .relay },
    .{ .name = "song_play", .policy = .relay },
    .{ .name = "song_goto", .policy = .relay },
    .{ .name = "recipe_save", .policy = .local_only },
    .{ .name = "recipe_replay", .policy = .reject_when_synced },
    .{ .name = "render", .policy = .reject_when_synced },
    .{ .name = "save_project", .policy = .local_only },
    .{ .name = "load_project", .policy = .reject_when_synced },
};

pub fn policyOf(name: []const u8) ?NetworkPolicyTag {
    // Using inline for + comptime eql also makes a build-time lookup work (a regular for could resolve to null at comptime).
    inline for (PATCH_NETWORK_POLICIES) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.policy;
    }
    return null;
}

// ============================================================================
// mini-notation parser + evaluator (std only, fixed capacity, no allocation, deterministic)
//
// Grammar (a whitespace-separated token list):
//   x = hit / ~ = rest / 0..9 = bass degree (hit + deg)
//   [a b] = subdivision within a slot (nesting depth up to 2)
//   <a b> = alternates per evaluation (alt_index % N; alternating every bar is a future scope)
//   a*2 = repetition within a slot / a? = 50% probability / x(k,n) = Euclidean rhythm within the span
// Evaluation: the bar is split into rational fractions, and round(pos*16) quantizes each to the nearest step. Collisions are OR'd.
// ============================================================================

/// root 1 + up to 64 tokens = 65. Nested group nodes are also counted here.
pub const MAX_NOTATION_NODES: usize = 65;
/// Child-reference slots (tree edge count <= nodes-1), sized to support up to 64 tokens.
pub const MAX_CHILD_SLOTS: usize = 64;
pub const MAX_TOKENS: usize = 64;
pub const MAX_NEST_DEPTH: u8 = 2;

pub const NodeKind = enum { rest, hit, deg, seq, alt };

/// A fixed-size AST node. Children are
/// an **explicit index list** in `Ast.child_indices[child_start .. child_start+child_count]` (not a contiguous node range, so nested siblings are never picked up by mistake).
pub const Node = struct {
    kind: NodeKind,
    deg: i8 = 0,
    child_start: u16 = 0,
    child_count: u16 = 0,
    /// `*n` (default 1); ignored during evaluation when euclid is specified.
    repeat: u8 = 1,
    /// `?` = 50% probability of being dropped.
    prob: bool = false,
    /// The n in `(k,n)`. 0 means unspecified.
    euclid_n: u8 = 0,
    euclid_k: u8 = 0,
};

pub const Ast = struct {
    nodes: [MAX_NOTATION_NODES]Node = undefined,
    count: u16 = 0,
    root: u16 = 0,
    /// An arena that stores each seq/alt node's child node indices contiguously.
    child_indices: [MAX_CHILD_SLOTS]u16 = undefined,
    child_index_count: u16 = 0,

    fn childAt(self: *const Ast, n: Node, c: u16) u16 {
        return self.child_indices[n.child_start + c];
    }
};

pub const NotationResult = struct {
    on: u16 = 0,
    deg: [16]i8 = [_]i8{0} ** 16,
    /// A bit mask of steps whose deg should be overridden (for bass; a step without a hit is never set).
    deg_set: u16 = 0,
};

/// Splits `action pattern <track> <notation>`'s args into track + notation.
/// notation is raw text that may contain spaces (only trimmed, never re-tokenized).
pub fn parsePatternArgs(args: []const u8) ParseError!struct { track: []const u8, notation: []const u8 } {
    const trimmed = std.mem.trim(u8, args, " \t");
    if (trimmed.len == 0) return error.Empty;
    var i: usize = 0;
    while (i < trimmed.len and trimmed[i] != ' ' and trimmed[i] != '\t') : (i += 1) {}
    if (i == 0) return error.Empty;
    const track = trimmed[0..i];
    const notation = std.mem.trim(u8, trimmed[i..], " \t");
    if (notation.len == 0) return error.Empty;
    return .{ .track = track, .notation = notation };
}

/// splitmix64 (Steele / Vigna), the same formula as seed.zig. Duplicated here since actions depends only on std.
fn splitmix64(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

/// A Bresenham-style Euclidean-rhythm check, the same formula as libs/modular's EuclideanSeq.hitAt (with no dependency on it).
fn euclidHit(steps: u8, pulses: u8, s: u8) bool {
    if (steps == 0 or pulses == 0) return false;
    const st: u32 = steps;
    const pu: u32 = @min(@as(u32, pulses), st);
    const idx: u32 = s;
    return (idx * pu) % st < pu;
}

const Parser = struct {
    src: []const u8,
    i: usize = 0,
    nodes: [MAX_NOTATION_NODES]Node = undefined,
    count: u16 = 0,
    child_indices: [MAX_CHILD_SLOTS]u16 = undefined,
    child_index_count: u16 = 0,
    /// The number of top-level whitespace-separated items (capped at MAX_TOKENS).
    items: u16 = 0,

    fn peek(self: *const Parser) ?u8 {
        if (self.i >= self.src.len) return null;
        return self.src[self.i];
    }

    fn advance(self: *Parser) void {
        if (self.i < self.src.len) self.i += 1;
    }

    fn skipWs(self: *Parser) void {
        while (self.peek()) |c| {
            if (c != ' ' and c != '\t') break;
            self.advance();
        }
    }

    fn allocNode(self: *Parser, n: Node) ParseError!u16 {
        if (self.count >= MAX_NOTATION_NODES) return error.TooManyNodes;
        const idx = self.count;
        self.nodes[idx] = n;
        self.count += 1;
        return idx;
    }

    fn pushChild(self: *Parser, child_idx: u16) ParseError!void {
        if (self.child_index_count >= MAX_CHILD_SLOTS) return error.TooManyNodes;
        self.child_indices[self.child_index_count] = child_idx;
        self.child_index_count += 1;
    }

    fn parseUint(self: *Parser) ParseError!u8 {
        const start = self.i;
        while (self.peek()) |c| {
            if (c < '0' or c > '9') break;
            self.advance();
        }
        if (self.i == start) return error.InvalidNumber;
        const tok = self.src[start..self.i];
        return std.fmt.parseUnsigned(u8, tok, 10) catch return error.InvalidNumber;
    }

    fn parseModifiers(self: *Parser, node_idx: u16) ParseError!void {
        while (self.peek()) |c| {
            switch (c) {
                '*' => {
                    self.advance();
                    const n = try self.parseUint();
                    if (n == 0) return error.InvalidNotation;
                    self.nodes[node_idx].repeat = n;
                },
                '?' => {
                    self.advance();
                    self.nodes[node_idx].prob = true;
                },
                '(' => {
                    self.advance();
                    self.skipWs();
                    const k = try self.parseUint();
                    self.skipWs();
                    if (self.peek() != ',') return error.InvalidNotation;
                    self.advance();
                    self.skipWs();
                    const n = try self.parseUint();
                    self.skipWs();
                    if (self.peek() != ')') return error.Unbalanced;
                    self.advance();
                    if (n == 0) return error.EuclidBad;
                    if (k > n) return error.EuclidBad;
                    self.nodes[node_idx].euclid_k = k;
                    self.nodes[node_idx].euclid_n = n;
                },
                else => return,
            }
        }
    }

    /// An atom plus modifiers. depth is the current bracket nesting depth (0 = top level).
    fn parseItem(self: *Parser, depth: u8) ParseError!u16 {
        self.skipWs();
        const c = self.peek() orelse return error.Empty;
        const node_idx: u16 = switch (c) {
            '~' => blk: {
                self.advance();
                break :blk try self.allocNode(.{ .kind = .rest });
            },
            'x', 'X' => blk: {
                self.advance();
                break :blk try self.allocNode(.{ .kind = .hit });
            },
            '0'...'9' => blk: {
                const d: i8 = @intCast(c - '0');
                self.advance();
                break :blk try self.allocNode(.{ .kind = .deg, .deg = d });
            },
            '[' => try self.parseGroup(.seq, ']', depth),
            '<' => try self.parseGroup(.alt, '>', depth),
            else => return error.InvalidNotation,
        };
        try self.parseModifiers(node_idx);
        return node_idx;
    }

    /// Direct child indices are collected locally and written to the arena all at once, after any nested arena pushes have completed
    /// (a nested group fills the arena first, so taking the parent's child_start at parse start would break).
    fn commitChildren(self: *Parser, node_idx: u16, local: []const u16) ParseError!void {
        const child_start = self.child_index_count;
        for (local) |cidx| {
            try self.pushChild(cidx);
        }
        self.nodes[node_idx].child_start = child_start;
        self.nodes[node_idx].child_count = @intCast(local.len);
    }

    fn parseGroup(self: *Parser, kind: NodeKind, closer: u8, depth: u8) ParseError!u16 {
        if (depth >= MAX_NEST_DEPTH) return error.NestTooDeep;
        self.advance(); // open
        const seq_idx = try self.allocNode(.{ .kind = kind });
        var local: [MAX_TOKENS]u16 = undefined;
        var child_count: u16 = 0;
        self.skipWs();
        if (self.peek() == closer) {
            // An empty group is rejected (it is meaningless)
            return error.InvalidNotation;
        }
        while (true) {
            self.skipWs();
            const p = self.peek() orelse return error.Unbalanced;
            if (p == closer) {
                self.advance();
                break;
            }
            const cidx = try self.parseItem(depth + 1);
            if (child_count >= MAX_TOKENS) return error.TooManyTokens;
            local[child_count] = cidx;
            child_count += 1;
            self.skipWs();
        }
        try self.commitChildren(seq_idx, local[0..child_count]);
        return seq_idx;
    }

    fn parseTop(self: *Parser) ParseError!Ast {
        self.skipWs();
        if (self.peek() == null) return error.Empty;

        const root = try self.allocNode(.{ .kind = .seq });
        var local: [MAX_TOKENS]u16 = undefined;
        var child_count: u16 = 0;

        while (true) {
            self.skipWs();
            if (self.peek() == null) break;
            // A closing bracket at the top level means the brackets are unbalanced
            const p = self.peek().?;
            if (p == ']' or p == '>') return error.Unbalanced;
            const cidx = try self.parseItem(0);
            if (child_count >= MAX_TOKENS) return error.TooManyTokens;
            local[child_count] = cidx;
            child_count += 1;
            self.items += 1;
            if (self.items > MAX_TOKENS) return error.TooManyTokens;
        }

        if (child_count == 0) return error.Empty;
        try self.commitChildren(root, local[0..child_count]);
        return .{
            .nodes = self.nodes,
            .count = self.count,
            .root = root,
            .child_indices = self.child_indices,
            .child_index_count = self.child_index_count,
        };
    }
};

/// Parses a mini-notation string into a fixed-capacity AST (no allocation).
pub fn parseNotation(notation: []const u8) ParseError!Ast {
    var p: Parser = .{ .src = notation };
    return p.parseTop();
}

const EvalCtx = struct {
    ast: *const Ast,
    rng_seed: u64,
    alt_index: u32,
    pos_index: u32 = 0,
    result: NotationResult = .{},

    fn place(self: *EvalCtx, t: f64, deg: ?i8) void {
        // round(pos*16) -> nearest step; endpoints are clamped to 0..15; collisions are OR'd.
        var s_f = t * 16.0;
        if (s_f < 0) s_f = 0;
        if (s_f > 15.0) s_f = 15.0;
        const s: u8 = @intFromFloat(@round(s_f));
        const bit: u16 = @as(u16, 1) << @as(u4, @intCast(s & 15));
        self.result.on |= bit;
        if (deg) |d| {
            self.result.deg[s] = d;
            self.result.deg_set |= bit;
        }
    }

    fn chance(self: *EvalCtx) bool {
        const idx = self.pos_index;
        self.pos_index += 1;
        const r = splitmix64(self.rng_seed ^ idx);
        return (r & 1) == 0; // 50%
    }

    fn evalNode(self: *EvalCtx, idx: u16, t0: f64, t1: f64) void {
        const n = self.ast.nodes[idx];
        switch (n.kind) {
            .rest => {},
            .hit, .deg => {
                const d: ?i8 = if (n.kind == .deg) n.deg else null;
                self.evalLeaf(n, t0, t1, d);
            },
            .seq => self.evalSeq(n, t0, t1, false),
            .alt => self.evalSeq(n, t0, t1, true),
        }
    }

    fn evalSeq(self: *EvalCtx, n: Node, t0: f64, t1: f64, is_alt: bool) void {
        if (n.child_count == 0) return;
        if (is_alt) {
            const pick = self.alt_index % n.child_count;
            // Via the explicit child_indices list (not a contiguous node index range)
            const child_idx = self.ast.childAt(n, @intCast(pick));
            // modifiers on the alt group itself
            self.evalWithMods(child_idx, n, t0, t1);
            return;
        }
        const span = t1 - t0;
        const inv: f64 = 1.0 / @as(f64, @floatFromInt(n.child_count));
        var c: u16 = 0;
        while (c < n.child_count) : (c += 1) {
            const ct0 = t0 + span * @as(f64, @floatFromInt(c)) * inv;
            const ct1 = t0 + span * @as(f64, @floatFromInt(c + 1)) * inv;
            self.evalNode(self.ast.childAt(n, c), ct0, ct1);
        }
    }

    /// When an alt group has modifiers, they are not simply reapplied leaf-style to the chosen child;
    /// instead, the child node itself is evaluated over [t0,t1), and the group's modifiers are handled the same way as when the child is a leaf.
    /// In short: the group's modifiers wrap the chosen child's evaluation span the way `evalLeaf` would.
    fn evalWithMods(self: *EvalCtx, child_idx: u16, group: Node, t0: f64, t1: f64) void {
        // If a group has euclid/repeat/prob, its child is not treated as a leaf;
        // instead the modifiers first split the span, and the child is evaluated within each sub-span.
        if (group.prob and !self.chance()) return;
        if (group.euclid_n > 0) {
            const en = group.euclid_n;
            const ek = group.euclid_k;
            const span = t1 - t0;
            const inv: f64 = 1.0 / @as(f64, @floatFromInt(en));
            var s: u8 = 0;
            while (s < en) : (s += 1) {
                if (!euclidHit(en, ek, s)) continue;
                const st0 = t0 + span * @as(f64, @floatFromInt(s)) * inv;
                const st1 = t0 + span * @as(f64, @floatFromInt(s + 1)) * inv;
                self.evalNode(child_idx, st0, st1);
            }
            return;
        }
        const rep: u8 = if (group.repeat == 0) 1 else group.repeat;
        if (rep > 1) {
            const span = t1 - t0;
            const inv: f64 = 1.0 / @as(f64, @floatFromInt(rep));
            var r: u8 = 0;
            while (r < rep) : (r += 1) {
                const st0 = t0 + span * @as(f64, @floatFromInt(r)) * inv;
                const st1 = t0 + span * @as(f64, @floatFromInt(r + 1)) * inv;
                self.evalNode(child_idx, st0, st1);
            }
            return;
        }
        self.evalNode(child_idx, t0, t1);
    }

    fn evalLeaf(self: *EvalCtx, n: Node, t0: f64, t1: f64, deg: ?i8) void {
        if (n.prob and !self.chance()) return;
        if (n.euclid_n > 0) {
            const en = n.euclid_n;
            const ek = n.euclid_k;
            const span = t1 - t0;
            const inv: f64 = 1.0 / @as(f64, @floatFromInt(en));
            var s: u8 = 0;
            while (s < en) : (s += 1) {
                if (!euclidHit(en, ek, s)) continue;
                const st = t0 + span * @as(f64, @floatFromInt(s)) * inv;
                self.place(st, deg);
            }
            return;
        }
        const rep: u8 = if (n.repeat == 0) 1 else n.repeat;
        if (rep == 1) {
            self.place(t0, deg);
            return;
        }
        const span = t1 - t0;
        const inv: f64 = 1.0 / @as(f64, @floatFromInt(rep));
        var r: u8 = 0;
        while (r < rep) : (r += 1) {
            const st = t0 + span * @as(f64, @floatFromInt(r)) * inv;
            self.place(st, deg);
        }
    }
};

/// Evaluates an AST into a 16-step mask (plus bass deg). Bit-deterministic for the same (ast, rng_seed, alt_index).
pub fn evalNotation(ast: Ast, rng_seed: u64, alt_index: u32) NotationResult {
    var ctx: EvalCtx = .{
        .ast = &ast,
        .rng_seed = rng_seed,
        .alt_index = alt_index,
    };
    ctx.evalNode(ast.root, 0.0, 1.0);
    return ctx.result;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseNameF32: valid / empty / bad number / non-finite / trailing tokens" {
    const r = try parseNameF32("tempo 128");
    try testing.expectEqualStrings("tempo", r.name);
    try testing.expectEqual(@as(f32, 128), r.value);
    try testing.expectError(error.Empty, parseNameF32(""));
    try testing.expectError(error.Empty, parseNameF32("tempo"));
    try testing.expectError(error.InvalidNumber, parseNameF32("tempo abc"));
    try testing.expectError(error.NonFinite, parseNameF32("tempo nan"));
    try testing.expectError(error.NonFinite, parseNameF32("tempo inf"));
    try testing.expectError(error.TooManyTokens, parseNameF32("tempo 128 extra"));
}

test "parseNameBool: only 0/1 accepted" {
    const r = try parseNameBool("kick 1");
    try testing.expectEqualStrings("kick", r.name);
    try testing.expectEqual(true, r.on);
    try testing.expectError(error.UnknownBool, parseNameBool("kick true"));
    try testing.expectError(error.Empty, parseNameBool("kick"));
    try testing.expectError(error.TooManyTokens, parseNameBool("kick 1 extra"));
}

test "parseNameU8: valid / out of range / trailing tokens" {
    const r = try parseNameU8("kick 5");
    try testing.expectEqualStrings("kick", r.name);
    try testing.expectEqual(@as(u8, 5), r.value);
    try testing.expectError(error.InvalidNumber, parseNameU8("kick 999"));
    try testing.expectError(error.Empty, parseNameU8("kick"));
    try testing.expectError(error.TooManyTokens, parseNameU8("kick 5 6"));
}

test "parseTwoU8: valid / bad number" {
    const r = try parseTwoU8("3 5");
    try testing.expectEqual(@as(u8, 3), r.a);
    try testing.expectEqual(@as(u8, 5), r.b);
    try testing.expectError(error.InvalidNumber, parseTwoU8("3 abc"));
    try testing.expectError(error.Empty, parseTwoU8("3"));
    try testing.expectError(error.TooManyTokens, parseTwoU8("3 5 7"));
}

test "parseBool01: only 0/1 accepted" {
    try testing.expectEqual(true, try parseBool01("1"));
    try testing.expectEqual(false, try parseBool01("0"));
    try testing.expectError(error.UnknownBool, parseBool01("yes"));
    try testing.expectError(error.Empty, parseBool01(""));
    try testing.expectError(error.TooManyTokens, parseBool01("1 0"));
}

test "parseU64: valid / empty / bad / trailing tokens" {
    try testing.expectEqual(@as(u64, 42), try parseU64("42"));
    try testing.expectEqual(@as(u64, 0), try parseU64("0"));
    try testing.expectError(error.Empty, parseU64(""));
    try testing.expectError(error.InvalidNumber, parseU64("abc"));
    try testing.expectError(error.InvalidNumber, parseU64("-1"));
    try testing.expectError(error.TooManyTokens, parseU64("42 1"));
}

test "parsePath: trim ends / keep internal spaces / reject empty" {
    try testing.expectEqualStrings("/tmp/out.mdlp", try parsePath("  /tmp/out.mdlp  "));
    try testing.expectEqualStrings("/tmp/my pattern.mdlp", try parsePath("/tmp/my pattern.mdlp"));
    try testing.expectError(error.Empty, parsePath(""));
    try testing.expectError(error.Empty, parsePath("   "));
}

test "parseRender: happy path / fail-fast on seconds 0, 601, non-numeric, missing tokens" {
    const r = try parseRender("/tmp/out.wav 4");
    try testing.expectEqualStrings("/tmp/out.wav", r.path);
    try testing.expectEqual(@as(u32, 4), r.seconds);
    try testing.expectEqual(@as(u32, 1), (try parseRender("a.wav 1")).seconds);
    try testing.expectEqual(@as(u32, 600), (try parseRender("a.wav 600")).seconds);
    try testing.expectError(error.OutOfRange, parseRender("a.wav 0"));
    try testing.expectError(error.OutOfRange, parseRender("a.wav 601"));
    try testing.expectError(error.InvalidNumber, parseRender("a.wav abc"));
    try testing.expectError(error.Empty, parseRender(""));
    try testing.expectError(error.Empty, parseRender("a.wav"));
    try testing.expectError(error.TooManyTokens, parseRender("a.wav 4 extra"));
}

fn evalStr(notation: []const u8, seed: u64, alt: u32) !NotationResult {
    const ast = try parseNotation(notation);
    return evalNotation(ast, seed, alt);
}

test "notation: x ~ x ~ → steps 0,8 (0x0101)" {
    // Split into 4: pos 0, 0.25, 0.5, 0.75 -> steps 0,4,8,12. Hits are at 0 and 8.
    const r = try evalStr("x ~ x ~", 0, 0);
    try testing.expectEqual(@as(u16, 0x0101), r.on);
}

test "notation: x ~ x ~ x ~ x ~ → steps 0,4,8,12 (0x1111)" {
    const r = try evalStr("x ~ x ~ x ~ x ~", 0, 0);
    try testing.expectEqual(@as(u16, 0x1111), r.on);
}

test "notation: rest only → on=0" {
    const r = try evalStr("~", 0, 0);
    try testing.expectEqual(@as(u16, 0), r.on);
    const r2 = try evalStr("~ ~ ~ ~", 0, 0);
    try testing.expectEqual(@as(u16, 0), r2.on);
}

test "notation: [x x] subdivision quantize" {
    // The top-level 1 slot [0,1) split in 2 -> pos 0 and 0.5 -> steps 0, 8
    const r = try evalStr("[x x]", 0, 0);
    try testing.expectEqual(@as(u16, 0x0101), r.on);
}

test "notation: x*2 within single slot" {
    // The top-level 1 slot with *2 -> pos 0 and 0.5 -> steps 0, 8
    const r = try evalStr("x*2", 0, 0);
    try testing.expectEqual(@as(u16, 0x0101), r.on);
}

test "notation: x(3,8) euclidean" {
    // E(3,8) hits at s=0,3,6 → pos 0, 3/8, 6/8 → step 0, 6, 12
    const r = try evalStr("x(3,8)", 0, 0);
    const expect: u16 = (@as(u16, 1) << 0) | (@as(u16, 1) << 6) | (@as(u16, 1) << 12);
    try testing.expectEqual(expect, r.on);
}

test "notation: bass degrees 0 3 5 ~" {
    // Split into 4: hit+deg at 0,4,8; rest at 12
    const r = try evalStr("0 3 5 ~", 0, 0);
    try testing.expectEqual(@as(u16, 0x0111), r.on); // steps 0,4,8
    try testing.expectEqual(@as(i8, 0), r.deg[0]);
    try testing.expectEqual(@as(i8, 3), r.deg[4]);
    try testing.expectEqual(@as(i8, 5), r.deg[8]);
    try testing.expectEqual(@as(u16, 0x0111), r.deg_set);
}

test "notation: fail-fast empty / unknown / nest / euclid k>n / unbalanced" {
    try testing.expectError(error.Empty, parseNotation(""));
    try testing.expectError(error.Empty, parseNotation("   "));
    try testing.expectError(error.InvalidNotation, parseNotation("x z"));
    try testing.expectError(error.Unbalanced, parseNotation("x [ x"));
    try testing.expectError(error.Unbalanced, parseNotation("x ]"));
    try testing.expectError(error.NestTooDeep, parseNotation("[[[x]]]"));
    try testing.expectError(error.EuclidBad, parseNotation("x(5,3)"));
    try testing.expectError(error.EuclidBad, parseNotation("x(1,0)"));
}

test "notation: ? and <a b> deterministic under same (seed, alt_index)" {
    // `?` depends on the seed: bit-reproducible for the same seed, may vary with a different seed.
    const a1 = try evalStr("x?", 42, 0);
    const a2 = try evalStr("x?", 42, 0);
    try testing.expectEqual(a1.on, a2.on);

    // Rolling probability across multiple slots makes seed differences more likely to show
    const b1 = try evalStr("x? x? x? x? x? x? x? x?", 1, 0);
    const b2 = try evalStr("x? x? x? x? x? x? x? x?", 1, 0);
    const b3 = try evalStr("x? x? x? x? x? x? x? x?", 2, 0);
    try testing.expectEqual(b1.on, b2.on);
    // A different seed makes the result differ with high probability (even in the rare case of a match, alt is covered by a separate path)
    _ = b3;

    // <a b>: alternates via alt_index % 2. Deterministic, no RNG needed.
    const c0 = try evalStr("<x ~>", 0, 0); // pick x
    const c1 = try evalStr("<x ~>", 0, 1); // pick ~
    try testing.expectEqual(@as(u16, 0x0001), c0.on); // step 0
    try testing.expectEqual(@as(u16, 0), c1.on);
    const c0b = try evalStr("<x ~>", 99, 0); // Independent of the seed
    try testing.expectEqual(c0.on, c0b.on);
    // alt_index=2 -> back to x
    const c2 = try evalStr("<x ~>", 0, 2);
    try testing.expectEqual(c0.on, c2.on);
}

test "notation: parsePatternArgs splits track and notation" {
    const r = try parsePatternArgs("kick x ~ x ~");
    try testing.expectEqualStrings("kick", r.track);
    try testing.expectEqualStrings("x ~ x ~", r.notation);
    try testing.expectError(error.Empty, parsePatternArgs(""));
    try testing.expectError(error.Empty, parsePatternArgs("kick"));
    try testing.expectError(error.Empty, parsePatternArgs("   "));
}

test "notation: 16-resolution overflow rounds and ORs" {
    // Equivalent to a 32-way split: x*32 rounds 32 points onto 16 steps and OR's them, so it tends to fill most steps
    const r = try evalStr("x*32", 0, 0);
    // 32 points: i/32 -> round(i/32*16)=round(i/2). i=0..31 -> steps 0,0,1,2,...,15,16->15
    // Nearly all bits end up set
    try testing.expect(r.on != 0);
    try testing.expectEqual(@as(u16, 0xFFFF), r.on);
}

test "notation P1-1: nested group mid/start/composite sibling placement" {
    // 'x [x x] x': split into 3. slot0 x@0->0 / slot1 [x x]@1/3,1/2 -> round 5.33->5, 8 / slot2 x@2/3->round 10.67->11
    const mid = try evalStr("x [x x] x", 0, 0);
    const expect_mid: u16 = (@as(u16, 1) << 0) | (@as(u16, 1) << 5) | (@as(u16, 1) << 8) | (@as(u16, 1) << 11);
    try testing.expectEqual(expect_mid, mid.on);

    // '[x x] x': split into 2. slot0 [x x]@0,0.25->0,4 / slot1 x@0.5->8
    const lead = try evalStr("[x x] x", 0, 0);
    const expect_lead: u16 = (@as(u16, 1) << 0) | (@as(u16, 1) << 4) | (@as(u16, 1) << 8);
    try testing.expectEqual(expect_lead, lead.on);

    // 'x <x ~> [x x]' alt=0: split into 3. x@0->0 / <x>@1/3->5 / [x x]@2/3,5/6 ->11,13
    const comp = try evalStr("x <x ~> [x x]", 0, 0);
    const expect_comp: u16 = (@as(u16, 1) << 0) | (@as(u16, 1) << 5) | (@as(u16, 1) << 11) | (@as(u16, 1) << 13);
    try testing.expectEqual(expect_comp, comp.on);

    // With alt=1 the middle becomes a rest -> steps 0,11,13
    const comp1 = try evalStr("x <x ~> [x x]", 0, 1);
    const expect_comp1: u16 = (@as(u16, 1) << 0) | (@as(u16, 1) << 11) | (@as(u16, 1) << 13);
    try testing.expectEqual(expect_comp1, comp1.on);
}

test "notation: 64 tokens exact capacity" {
    // "x " * 63 + "x" = 64 hits. root+64 leaves = exactly 65 nodes.
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    var t: usize = 0;
    while (t < 64) : (t += 1) {
        if (t > 0) {
            buf[n] = ' ';
            n += 1;
        }
        buf[n] = 'x';
        n += 1;
    }
    const ast = try parseNotation(buf[0..n]);
    try testing.expectEqual(@as(u16, 65), ast.count); // root + 64
    const r = evalNotation(ast, 0, 0);
    // Split into 64 -> rounding i/64*16 for each -> all 16 steps end up set via OR
    try testing.expectEqual(@as(u16, 0xFFFF), r.on);
}

// ============================================================================
// Song/Chain/Phrase parsers
// ============================================================================

test "parseU8: valid / empty / bad / trailing" {
    try testing.expectEqual(@as(u8, 0), try parseU8("0"));
    try testing.expectEqual(@as(u8, 63), try parseU8("63"));
    try testing.expectError(error.Empty, parseU8(""));
    try testing.expectError(error.InvalidNumber, parseU8("abc"));
    try testing.expectError(error.InvalidNumber, parseU8("256"));
    try testing.expectError(error.TooManyTokens, parseU8("1 2"));
}

test "parseChainSet: 1..16 phrases / fail-fast" {
    const r = try parseChainSet("0 1 2 3");
    try testing.expectEqual(@as(u8, 0), r.chain_idx);
    try testing.expectEqual(@as(u8, 3), r.len);
    try testing.expectEqual(@as(u8, 1), r.phrases[0]);
    try testing.expectEqual(@as(u8, 2), r.phrases[1]);
    try testing.expectEqual(@as(u8, 3), r.phrases[2]);

    const one = try parseChainSet("5 7");
    try testing.expectEqual(@as(u8, 5), one.chain_idx);
    try testing.expectEqual(@as(u8, 1), one.len);
    try testing.expectEqual(@as(u8, 7), one.phrases[0]);

    // 16 phrases exact
    const full = try parseChainSet("1 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15");
    try testing.expectEqual(@as(u8, 16), full.len);

    try testing.expectError(error.Empty, parseChainSet(""));
    try testing.expectError(error.Empty, parseChainSet("3")); // chain only, no phrases
    try testing.expectError(error.InvalidNumber, parseChainSet("0 x"));
    try testing.expectError(error.TooManyTokens, parseChainSet("0 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16"));
}

test "parseSongRow: 5 tokens / fail-fast" {
    const r = try parseSongRow("0 1 2 3 4");
    try testing.expectEqual(@as(u8, 0), r.row_idx);
    try testing.expectEqual(@as(u8, 1), r.kick);
    try testing.expectEqual(@as(u8, 2), r.hat);
    try testing.expectEqual(@as(u8, 3), r.clap);
    try testing.expectEqual(@as(u8, 4), r.bass);
    try testing.expectError(error.Empty, parseSongRow("0 1 2 3"));
    try testing.expectError(error.TooManyTokens, parseSongRow("0 1 2 3 4 5"));
    try testing.expectError(error.InvalidNumber, parseSongRow("0 a 2 3 4"));
}

test "parseBool01 / parseU8 for song_loop / song_play / song_len / song_goto" {
    try testing.expectEqual(true, try parseBool01("1"));
    try testing.expectEqual(false, try parseBool01("0"));
    try testing.expectEqual(@as(u8, 8), try parseU8("8"));
    try testing.expectEqual(@as(u8, 0), try parseU8("0"));
}

test "pattern_state: round-trip / trailing tokens / non-hex / 4096B cap" {
    const sample = PatternStateArgs{
        .kick_on = 0x1111,
        .hat_on = 0x2222,
        .clap_on = 0x3333,
        .bass_on = 0x4444,
        .bass_accent = 0x5555,
        .bass_slide = 0x6666,
        .kick_lock = true,
        .hat_lock = false,
        .clap_lock = true,
        .bass_lock = false,
        .evolve = true,
        .mutation_count = 42,
        .bass_deg = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    };
    var buf: [512]u8 = undefined;
    const encoded = try formatPatternState(&buf, sample);
    try testing.expect(encoded.len < 4096);
    const decoded = try parsePatternState(encoded);
    try testing.expectEqual(sample.kick_on, decoded.kick_on);
    try testing.expectEqual(sample.hat_on, decoded.hat_on);
    try testing.expectEqual(sample.clap_on, decoded.clap_on);
    try testing.expectEqual(sample.bass_on, decoded.bass_on);
    try testing.expectEqual(sample.bass_accent, decoded.bass_accent);
    try testing.expectEqual(sample.bass_slide, decoded.bass_slide);
    try testing.expectEqual(sample.kick_lock, decoded.kick_lock);
    try testing.expectEqual(sample.hat_lock, decoded.hat_lock);
    try testing.expectEqual(sample.clap_lock, decoded.clap_lock);
    try testing.expectEqual(sample.bass_lock, decoded.bass_lock);
    try testing.expectEqual(sample.evolve, decoded.evolve);
    try testing.expectEqual(sample.mutation_count, decoded.mutation_count);
    try testing.expectEqualSlices(i8, &sample.bass_deg, &decoded.bass_deg);

    try testing.expectError(error.Empty, parsePatternState(""));
    try testing.expectError(error.InvalidNumber, parsePatternState("zzzz 0000 0000 0000 0000 0000 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"));
    try testing.expectError(error.TooManyTokens, parsePatternState("1111 2222 3333 4444 5555 6666 0 0 0 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 extra"));
    // deg is missing
    try testing.expectError(error.Empty, parsePatternState("1111 2222 3333 4444 5555 6666 0 0 0 0 1 0 0 0 0"));
}

test "pattern_state: parseBool01Tok bad value is UnknownBool" {
    // The lock/evolve field is something other than 0|1
    try testing.expectError(error.UnknownBool, parsePatternState("1111 2222 3333 4444 5555 6666 2 0 0 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"));
    try testing.expectError(error.UnknownBool, parsePatternState("1111 2222 3333 4444 5555 6666 0 true 0 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"));
    try testing.expectError(error.UnknownBool, parsePatternState("1111 2222 3333 4444 5555 6666 0 0 0 0 yes 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"));
}

test "policy table: relay / reject_when_synced / local_only buckets" {
    const relays = [_][]const u8{
        "add_node",  "remove_node",    "connect",   "disconnect", "move_node",   "add_macro", "remove_macro",
        "set_param", "set_mute",       "set_lock",  "set_evolve", "toggle_step", "set_pitch", "seed",
        "pattern",   "phrase_capture", "chain_set", "song_row",   "song_len",    "song_loop", "song_play",
        "song_goto",
    };
    for (relays) |name| {
        try testing.expectEqual(NetworkPolicyTag.relay, policyOf(name).?);
    }

    const rejects = [_][]const u8{ "load_graph", "load_pattern", "load_project", "recipe_replay", "render", "pattern_state" };
    for (rejects) |name| {
        try testing.expectEqual(NetworkPolicyTag.reject_when_synced, policyOf(name).?);
    }

    const locals = [_][]const u8{ "select_node", "observe_param", "save_graph", "save_pattern", "save_project", "recipe_save" };
    for (locals) |name| {
        try testing.expectEqual(NetworkPolicyTag.local_only, policyOf(name).?);
    }

    // A name not in the table yields null
    try testing.expect(policyOf("no_such_action") == null);
    // All entries are unique
    for (PATCH_NETWORK_POLICIES, 0..) |a, i| {
        for (PATCH_NETWORK_POLICIES[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}
