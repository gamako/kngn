//! apps/patch の生成レイヤ harness action（TASK-65 / TASK-93）向け純パーサ。
//!
//! ホットパス宣言: ここでパースした結果は「イベント時のみ」（harness の `action <name> [args]`
//! コマンド1回につき1回）dispatch される。毎フレーム全画素ループ・毎サンプル RT 経路のいずれでもない
//! ため、性能規約（SIMD 3点セット等）の適用対象外。
//!
//! このファイルは **std のみに依存**し、App / kit / platform / modular を一切 import しない
//! （pixie の `actions.zig` と同型。main.zig との circular import を避け、単体テスト可能にする）。
//! track 名（kick/hat/clap/bass 等）の enum 解決は App の具象型を知る main.zig 側が行う
//! （pixie の `ToolKind` 解決と同じ分離方針。このファイルは name を素通しする）。
//!
//! TASK-93 mini-notation: `parseNotation` / `evalNotation` も本ファイルに閉じる（固定容量・alloc なし・
//! 決定的）。評価は action 実行時のみ。RT には評価済み mask だけが publish される。

const std = @import("std");

pub const ParseError = error{
    Empty,
    InvalidNumber,
    NonFinite,
    TooManyTokens,
    UnknownBool,
    OutOfRange,
    // TASK-93 mini-notation
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

/// "<name> <value>" の2トークン（`set_param` 汎用 f32 setter 用）。
/// NaN/Inf は `error.NonFinite` で拒否する（fail-fast。非有限値を Controls(atomic) 経由で RT へ
/// 渡すのを入口で止める。synth の parseNameF32 と対称）。
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

/// "<name> <0|1>" の2トークン（`set_mute`/`set_lock` 用）。
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

/// "<name> <0-255>" の2トークン（`toggle_step` 用: track 名 + step index）。
pub fn parseNameU8(args: []const u8) ParseError!NameU8 {
    var it = tokenize(args);
    const name = it.next() orelse return error.Empty;
    const v_tok = it.next() orelse return error.Empty;
    const value = std.fmt.parseUnsigned(u8, v_tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return .{ .name = name, .value = value };
}

pub const TwoU8 = struct { a: u8, b: u8 };

/// "<a> <b>" の2トークン（`set_pitch <step> <deg>` 用）。
pub fn parseTwoU8(args: []const u8) ParseError!TwoU8 {
    var it = tokenize(args);
    const a_tok = it.next() orelse return error.Empty;
    const a = std.fmt.parseUnsigned(u8, a_tok, 10) catch return error.InvalidNumber;
    const b_tok = it.next() orelse return error.Empty;
    const b = std.fmt.parseUnsigned(u8, b_tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return .{ .a = a, .b = b };
}

/// "<0|1>" の1トークン（`set_evolve` 用）。
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

/// "<u64>" の1トークン（`seed` 用。10 進）。
pub fn parseU64(args: []const u8) ParseError!u64 {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const value = std.fmt.parseUnsigned(u64, tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return value;
}

/// `save_pattern`/`load_pattern` 用: 前後の空白のみ trim し、内部の空白はそのまま保持する
/// （path は空白を含みうる1本の文字列として扱う。pixie/synth の `parsePath` と同型）。
pub fn parsePath(args: []const u8) ParseError![]const u8 {
    const trimmed = std.mem.trim(u8, args, " \t");
    if (trimmed.len == 0) return error.Empty;
    return trimmed;
}

pub const RenderArgs = struct {
    path: []const u8,
    seconds: u32,
};

/// `render <path> <seconds>` 用: path=空白を含まない1トークン + seconds=u32（範囲 1..=600）。
/// 範囲外は `error.OutOfRange`（clamp せず fail-fast。TASK-86）。
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
// TASK-91: Song/Chain/Phrase action パーサ（std のみ・固定容量・fail-fast）
// ============================================================================

/// `phrase_capture <idx>` / `song_len <n>` / `song_goto <row>` 用: u8 1 トークン。
pub fn parseU8(args: []const u8) ParseError!u8 {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const value = std.fmt.parseUnsigned(u8, tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return value;
}

pub const ChainSetArgs = struct {
    chain_idx: u8,
    /// phrase index 列（1..16）
    phrases: [16]u8 = undefined,
    len: u8 = 0,
};

/// `chain_set <chain_idx> <phrase_idx...>`（phrase 1..16 個）。
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

/// `song_row <row_idx> <kick_chain> <hat_chain> <clap_chain> <bass_chain>`。
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
// TASK-93: mini-notation パーサ + 評価器（std のみ・固定容量・alloc なし・決定的）
//
// 文法（空白区切りトークン列）:
//   x = hit / ~ = 休符 / 0..9 = bass 度数（hit + deg）
//   [a b] = スロット内サブ分割（ネスト深さ 2 まで）
//   <a b> = 評価ごと交代（alt_index % N。bar ごと連続交代は将来スコープ）
//   a*2 = スロット内反復 / a? = 50% 確率 / x(k,n) = スパン内ユークリッド
// 評価: bar を有理数分割し round(pos*16) で最寄り step へ量子化。衝突は OR。
// ============================================================================

/// root 1 + トークン最大 64 = 65。ネスト group ノードもここに入る。
pub const MAX_NOTATION_NODES: usize = 65;
/// 子参照スロット（木の辺数 ≤ nodes-1）。64 トークンまで可を成立させる。
pub const MAX_CHILD_SLOTS: usize = 64;
pub const MAX_TOKENS: usize = 64;
pub const MAX_NEST_DEPTH: u8 = 2;

pub const NodeKind = enum { rest, hit, deg, seq, alt };

/// 固定長 AST ノード。子は `Ast.child_indices[child_start .. child_start+child_count]` の
/// **明示 index リスト**（連続ノード範囲ではない。ネスト後の兄弟を誤拾いしない）。
pub const Node = struct {
    kind: NodeKind,
    deg: i8 = 0,
    child_start: u16 = 0,
    child_count: u16 = 0,
    /// `*n`（既定 1）。euclid 指定時は評価で無視。
    repeat: u8 = 1,
    /// `?` = 50% 確率間引き。
    prob: bool = false,
    /// `(k,n)` の n。0 = 未指定。
    euclid_n: u8 = 0,
    euclid_k: u8 = 0,
};

pub const Ast = struct {
    nodes: [MAX_NOTATION_NODES]Node = undefined,
    count: u16 = 0,
    root: u16 = 0,
    /// 各 seq/alt ノードの子 node index を連続格納する arena。
    child_indices: [MAX_CHILD_SLOTS]u16 = undefined,
    child_index_count: u16 = 0,

    fn childAt(self: *const Ast, n: Node, c: u16) u16 {
        return self.child_indices[n.child_start + c];
    }
};

pub const NotationResult = struct {
    on: u16 = 0,
    deg: [16]i8 = [_]i8{0} ** 16,
    /// deg を上書きすべき step の bit mask（bass 用。hit しない step は立てない）。
    deg_set: u16 = 0,
};

/// `action pattern <track> <notation>` の args を track + notation に分割する。
/// notation は空白を含む生テキスト（trim のみ。再トークン化しない）。
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

/// splitmix64（Steele / Vigna）。seed.zig と同式。actions は std のみ依存のためここにも置く。
fn splitmix64(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

/// Bresenham 系ユークリッド判定（libs/modular EuclideanSeq.hitAt と同式。依存は張らない）。
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
    /// トップレベル空白区切り item 数（上限 MAX_TOKENS）。
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

    /// atom + modifiers。depth は現在の括弧深さ（0=トップ）。
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

    /// 直接子 index をローカルに集め、ネスト側の arena push が終わってから一括で arena に書く。
    /// （ネスト group が先に arena を埋めるため、親の child_start を parse 開始時に取る方式は壊れる）
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
            // 空グループは拒否（意味が無い）
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
            // トップレベルで閉じ括弧が来たら不均衡
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

/// mini-notation 文字列を固定容量 AST にパースする（alloc なし）。
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
        // round(pos*16) → 最寄り step。端点は 0..15 に clamp。衝突は OR。
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
            // 明示 child_indices 経由（連続ノード index ではない）
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

    /// alt グループに modifiers が付いている場合、選ばれた子に対して leaf 的に再適用するのではなく
    /// 子ノード自体を [t0,t1) で評価し、グループの modifiers は子が leaf のときと同様に扱う。
    /// 簡略: グループ modifiers は選ばれた子の評価スパン上で `evalLeaf`-like wrap する。
    fn evalWithMods(self: *EvalCtx, child_idx: u16, group: Node, t0: f64, t1: f64) void {
        // グループに euclid/repeat/prob があれば、子を leaf として扱うのではなく
        // まず modifiers でスパンを分割し各サブスパンで子を評価する。
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

/// AST を 16-step mask（+ bass deg）へ評価する。同じ (ast, rng_seed, alt_index) で bit 決定的。
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

test "parseNameF32: 有効値 / 空 / 不正数値 / 非有限 / 余剰トークン" {
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

test "parseNameBool: 0/1 のみ許容" {
    const r = try parseNameBool("kick 1");
    try testing.expectEqualStrings("kick", r.name);
    try testing.expectEqual(true, r.on);
    try testing.expectError(error.UnknownBool, parseNameBool("kick true"));
    try testing.expectError(error.Empty, parseNameBool("kick"));
    try testing.expectError(error.TooManyTokens, parseNameBool("kick 1 extra"));
}

test "parseNameU8: 有効値 / 範囲外 / 余剰トークン" {
    const r = try parseNameU8("kick 5");
    try testing.expectEqualStrings("kick", r.name);
    try testing.expectEqual(@as(u8, 5), r.value);
    try testing.expectError(error.InvalidNumber, parseNameU8("kick 999"));
    try testing.expectError(error.Empty, parseNameU8("kick"));
    try testing.expectError(error.TooManyTokens, parseNameU8("kick 5 6"));
}

test "parseTwoU8: 有効値 / 不正数値" {
    const r = try parseTwoU8("3 5");
    try testing.expectEqual(@as(u8, 3), r.a);
    try testing.expectEqual(@as(u8, 5), r.b);
    try testing.expectError(error.InvalidNumber, parseTwoU8("3 abc"));
    try testing.expectError(error.Empty, parseTwoU8("3"));
    try testing.expectError(error.TooManyTokens, parseTwoU8("3 5 7"));
}

test "parseBool01: 0/1 のみ許容" {
    try testing.expectEqual(true, try parseBool01("1"));
    try testing.expectEqual(false, try parseBool01("0"));
    try testing.expectError(error.UnknownBool, parseBool01("yes"));
    try testing.expectError(error.Empty, parseBool01(""));
    try testing.expectError(error.TooManyTokens, parseBool01("1 0"));
}

test "parseU64: 有効値 / 空 / 不正 / 余剰トークン" {
    try testing.expectEqual(@as(u64, 42), try parseU64("42"));
    try testing.expectEqual(@as(u64, 0), try parseU64("0"));
    try testing.expectError(error.Empty, parseU64(""));
    try testing.expectError(error.InvalidNumber, parseU64("abc"));
    try testing.expectError(error.InvalidNumber, parseU64("-1"));
    try testing.expectError(error.TooManyTokens, parseU64("42 1"));
}

test "parsePath: 前後 trim / 内部空白保持 / 空は拒否" {
    try testing.expectEqualStrings("/tmp/out.mdlp", try parsePath("  /tmp/out.mdlp  "));
    try testing.expectEqualStrings("/tmp/my pattern.mdlp", try parsePath("/tmp/my pattern.mdlp"));
    try testing.expectError(error.Empty, parsePath(""));
    try testing.expectError(error.Empty, parsePath("   "));
}

test "parseRender: 正常系 / 秒数 0・601・非数値・トークン不足の fail-fast" {
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
    // 4 等分: pos 0, 0.25, 0.5, 0.75 → step 0,4,8,12。hit は 0 と 8。
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
    // トップ 1 slot [0,1) を 2 分割 → pos 0 と 0.5 → steps 0, 8
    const r = try evalStr("[x x]", 0, 0);
    try testing.expectEqual(@as(u16, 0x0101), r.on);
}

test "notation: x*2 within single slot" {
    // トップ 1 slot を *2 → pos 0 と 0.5 → steps 0, 8
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
    // 4 等分: hit+deg at 0,4,8; rest at 12
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
    // ? は seed 依存。同じ seed で bit 再現、異なる seed で変化しうる。
    const a1 = try evalStr("x?", 42, 0);
    const a2 = try evalStr("x?", 42, 0);
    try testing.expectEqual(a1.on, a2.on);

    // 複数スロットで確率を振ると seed 差が出やすい
    const b1 = try evalStr("x? x? x? x? x? x? x? x?", 1, 0);
    const b2 = try evalStr("x? x? x? x? x? x? x? x?", 1, 0);
    const b3 = try evalStr("x? x? x? x? x? x? x? x?", 2, 0);
    try testing.expectEqual(b1.on, b2.on);
    // seed が違えば高確率で異なる（万一一致しても alt は別経路で担保）
    _ = b3;

    // <a b>: alt_index % 2 で交代。RNG 不要で決定的。
    const c0 = try evalStr("<x ~>", 0, 0); // pick x
    const c1 = try evalStr("<x ~>", 0, 1); // pick ~
    try testing.expectEqual(@as(u16, 0x0001), c0.on); // step 0
    try testing.expectEqual(@as(u16, 0), c1.on);
    const c0b = try evalStr("<x ~>", 99, 0); // seed 無関係
    try testing.expectEqual(c0.on, c0b.on);
    // alt_index=2 → また x
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
    // 32 等分相当: x*32 は 32 点を 16 step に丸めて OR → 全 step に寄りやすい
    const r = try evalStr("x*32", 0, 0);
    // 32 点: i/32 → round(i/32*16)=round(i/2)。i=0..31 → steps 0,0,1,2,...,15,16→15
    // ほぼ全 bit が立つ
    try testing.expect(r.on != 0);
    try testing.expectEqual(@as(u16, 0xFFFF), r.on);
}

test "notation P1-1: nested group mid/start/composite sibling placement" {
    // 'x [x x] x': 3 等分。slot0 x@0→0 / slot1 [x x]@1/3,1/2 → round 5.33→5, 8 / slot2 x@2/3→round 10.67→11
    const mid = try evalStr("x [x x] x", 0, 0);
    const expect_mid: u16 = (@as(u16, 1) << 0) | (@as(u16, 1) << 5) | (@as(u16, 1) << 8) | (@as(u16, 1) << 11);
    try testing.expectEqual(expect_mid, mid.on);

    // '[x x] x': 2 等分。slot0 [x x]@0,0.25→0,4 / slot1 x@0.5→8
    const lead = try evalStr("[x x] x", 0, 0);
    const expect_lead: u16 = (@as(u16, 1) << 0) | (@as(u16, 1) << 4) | (@as(u16, 1) << 8);
    try testing.expectEqual(expect_lead, lead.on);

    // 'x <x ~> [x x]' alt=0: 3 等分。x@0→0 / <x>@1/3→5 / [x x]@2/3,5/6 →11,13
    const comp = try evalStr("x <x ~> [x x]", 0, 0);
    const expect_comp: u16 = (@as(u16, 1) << 0) | (@as(u16, 1) << 5) | (@as(u16, 1) << 11) | (@as(u16, 1) << 13);
    try testing.expectEqual(expect_comp, comp.on);

    // alt=1 で中間が休符 → steps 0,11,13
    const comp1 = try evalStr("x <x ~> [x x]", 0, 1);
    const expect_comp1: u16 = (@as(u16, 1) << 0) | (@as(u16, 1) << 11) | (@as(u16, 1) << 13);
    try testing.expectEqual(expect_comp1, comp1.on);
}

test "notation: 64 tokens exact capacity" {
    // "x " * 63 + "x" = 64 hits。root+64 leaves = 65 nodes ちょうど。
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
    // 64 等分 → 各 i/64 *16 を round → 全 16 step が OR で立つ
    try testing.expectEqual(@as(u16, 0xFFFF), r.on);
}

// ============================================================================
// TASK-91 parsers
// ============================================================================

test "parseU8: 有効値 / 空 / 不正 / 余剰" {
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
