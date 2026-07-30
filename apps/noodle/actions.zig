//! apps/noodle: pure parser for harness actions.
//!
//! Hot-path declaration: parsing here runs only "on events" (once per harness
//! `action <name> [args]` command dispatch). Neither a per-frame all-pixel loop nor a per-sample RT path,
//! so the performance rules (SIMD triad, etc.) do not apply.
//!
//! This file **depends only on std** and never imports App / kit / platform / modular
//! (same shape as pixie's `actions.zig`. Avoids a circular import with main.zig and stays unit-testable).
//! Resolving `ModuleKind` names as an enum is done by main.zig, which knows the App's concrete type (the same
//! separation as pixie's `ToolKind` resolution. This file passes kind names through unchanged).

const std = @import("std");

pub const ParseError = error{
    Empty,
    InvalidNumber,
    TooManyTokens,
    OddExtraTokens,
    InvalidCoord,
    TooManyMacroMembers,
};

/// Node reference: `#<id>` (stable NodeId) or a bare number (runtime handle, solo-compatible).
pub const NodeRef = union(enum) {
    id: u64,
    handle: usize,
};

/// Accepted range for world coordinates (NaN/Inf are rejected separately; guards against extreme values breaking layout).
pub const COORD_ABS_MAX: f32 = 1_000_000.0;

/// Member cap for remove_macro (a practical upper bound equal to DynGraph MAX_MODULES).
pub const MAX_REMOVE_MACRO_MEMBERS: usize = 48;

/// Node form for `set_param`: `#<NodeId>|bare-handle <name> <value>`.
pub const ParamOverride = struct { ref: NodeRef, name: []const u8, value: f32 };

/// Single-handle parser for `select_node <handle>` (.local_only, stays a runtime handle).
pub fn parseSelectNode(args: []const u8) ParseError!usize {
    return parseUsize(args);
}

/// Parser for `set_param #<id>|handle <name> <value>`.
/// A bare handle is accepted for solo compatibility. Rejection during netsync happens at canonicalize / the handler side (`id_required`).
pub fn parseParamOverride(args: []const u8) ParseError!ParamOverride {
    var it = tokenize(args);
    const ref_tok = it.next() orelse return error.Empty;
    const ref = try parseNodeRefToken(ref_tok);
    const name = it.next() orelse return error.Empty;
    if (name.len == 0) return error.Empty;
    const value_tok = it.next() orelse return error.Empty;
    const value = std.fmt.parseFloat(f32, value_tok) catch return error.InvalidNumber;
    if (!std.math.isFinite(value)) return error.InvalidNumber;
    try expectExhausted(&it);
    return .{ .ref = ref, .name = name, .value = value };
}

/// For wire: `#<id> <canonical-name> <value>`.
pub fn formatParamOverride(buf: []u8, id: u64, name: []const u8, value: f32) error{TooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "#{d} {s} {d}", .{ id, name, value }) catch return error.TooLong;
}

fn tokenize(args: []const u8) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, args, " \t");
}

fn expectExhausted(it: *std.mem.TokenIterator(u8, .any)) ParseError!void {
    if (it.next() != null) return error.TooManyTokens;
}

/// A single "<handle>" token (for legacy / select_node).
pub fn parseUsize(args: []const u8) ParseError!usize {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const v = std.fmt.parseUnsigned(usize, tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return v;
}

pub const TwoUsize = struct { a: usize, b: usize };

/// Two "<a> <b>" tokens (for legacy disconnect).
pub fn parseTwoUsize(args: []const u8) ParseError!TwoUsize {
    var it = tokenize(args);
    const a_tok = it.next() orelse return error.Empty;
    const a = std.fmt.parseUnsigned(usize, a_tok, 10) catch return error.InvalidNumber;
    const b_tok = it.next() orelse return error.Empty;
    const b = std.fmt.parseUnsigned(usize, b_tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return .{ .a = a, .b = b };
}

pub const FourUsize = struct { a: usize, b: usize, c: usize, d: usize };

/// Four "<src_h> <src_out> <dst_h> <dst_in>" tokens (for legacy connect).
pub fn parseFourUsize(args: []const u8) ParseError!FourUsize {
    var it = tokenize(args);
    const a_tok = it.next() orelse return error.Empty;
    const a = std.fmt.parseUnsigned(usize, a_tok, 10) catch return error.InvalidNumber;
    const b_tok = it.next() orelse return error.Empty;
    const b = std.fmt.parseUnsigned(usize, b_tok, 10) catch return error.InvalidNumber;
    const c_tok = it.next() orelse return error.Empty;
    const c = std.fmt.parseUnsigned(usize, c_tok, 10) catch return error.InvalidNumber;
    const d_tok = it.next() orelse return error.Empty;
    const d = std.fmt.parseUnsigned(usize, d_tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return .{ .a = a, .b = b, .c = c, .d = d };
}

/// For `save_graph`/`load_graph`: trims only leading/trailing whitespace, preserving internal whitespace as-is
/// (treats path as a single string that may contain whitespace. Same shape as pixie/synth/modular's `parsePath`).
pub fn parsePath(args: []const u8) ParseError![]const u8 {
    const trimmed = std.mem.trim(u8, args, " \t");
    if (trimmed.len == 0) return error.Empty;
    return trimmed;
}

pub const AddNode = struct { kind: []const u8, x: f32, y: f32 };

fn parseFiniteCoord(tok: []const u8) ParseError!f32 {
    const v = std.fmt.parseFloat(f32, tok) catch return error.InvalidNumber;
    if (!std.math.isFinite(v)) return error.InvalidCoord;
    if (@abs(v) > COORD_ABS_MAX) return error.InvalidCoord;
    return v;
}

/// "<kind> <x> <y>" — kind name plus world coordinates are required (`add_node` wire).
pub fn parseAddNode(args: []const u8) ParseError!AddNode {
    var it = tokenize(args);
    const kind = it.next() orelse return error.Empty;
    const x_tok = it.next() orelse return error.Empty;
    const x = try parseFiniteCoord(x_tok);
    const y_tok = it.next() orelse return error.Empty;
    const y = try parseFiniteCoord(y_tok);
    try expectExhausted(&it);
    return .{ .kind = kind, .x = x, .y = y };
}

/// Single-token node reference: `#<id>` → `.id` / bare number → `.handle`.
/// Rejects `#0` and a bare empty token. id=0 is invalid.
pub fn parseNodeRefToken(tok: []const u8) ParseError!NodeRef {
    if (tok.len == 0) return error.Empty;
    if (tok[0] == '#') {
        if (tok.len < 2) return error.InvalidNumber;
        const id = std.fmt.parseUnsigned(u64, tok[1..], 10) catch return error.InvalidNumber;
        if (id == 0) return error.InvalidNumber;
        return .{ .id = id };
    }
    const h = std.fmt.parseUnsigned(usize, tok, 10) catch return error.InvalidNumber;
    return .{ .handle = h };
}

/// A single "`#<id>` | `<handle>`" token (remove_node).
pub fn parseNodeRef(args: []const u8) ParseError!NodeRef {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const ref = try parseNodeRefToken(tok);
    try expectExhausted(&it);
    return ref;
}

pub const MoveNode = struct { ref: NodeRef, x: f32, y: f32 };

/// "`#<id>`|`<handle>` <x> <y>" (move_node).
pub fn parseMoveNode(args: []const u8) ParseError!MoveNode {
    var it = tokenize(args);
    const ref_tok = it.next() orelse return error.Empty;
    const ref = try parseNodeRefToken(ref_tok);
    const x_tok = it.next() orelse return error.Empty;
    const x = try parseFiniteCoord(x_tok);
    const y_tok = it.next() orelse return error.Empty;
    const y = try parseFiniteCoord(y_tok);
    try expectExhausted(&it);
    return .{ .ref = ref, .x = x, .y = y };
}

pub const DisconnectArgs = struct { dst: NodeRef, dst_in: usize };

/// "`#<id>`|`<handle>` <dst_in>" (disconnect).
pub fn parseDisconnect(args: []const u8) ParseError!DisconnectArgs {
    var it = tokenize(args);
    const ref_tok = it.next() orelse return error.Empty;
    const dst = try parseNodeRefToken(ref_tok);
    const in_tok = it.next() orelse return error.Empty;
    const dst_in = std.fmt.parseUnsigned(usize, in_tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return .{ .dst = dst, .dst_in = dst_in };
}

pub const ConnectArgs = struct {
    src: NodeRef,
    src_out: usize,
    dst: NodeRef,
    dst_in: usize,
    /// Optional: the drag-off source input (detach within the same COMMIT). null if absent.
    detach_dst: ?NodeRef = null,
    detach_in: ?usize = null,
};

/// "`#src` <out> `#dst` <in> [`#detach` <in>]" (connect; detach is optional).
pub fn parseConnect(args: []const u8) ParseError!ConnectArgs {
    var it = tokenize(args);
    const src_tok = it.next() orelse return error.Empty;
    const src = try parseNodeRefToken(src_tok);
    const out_tok = it.next() orelse return error.Empty;
    const src_out = std.fmt.parseUnsigned(usize, out_tok, 10) catch return error.InvalidNumber;
    const dst_tok = it.next() orelse return error.Empty;
    const dst = try parseNodeRefToken(dst_tok);
    const in_tok = it.next() orelse return error.Empty;
    const dst_in = std.fmt.parseUnsigned(usize, in_tok, 10) catch return error.InvalidNumber;

    const detach_tok = it.next();
    if (detach_tok) |dt| {
        const detach_dst = try parseNodeRefToken(dt);
        const din_tok = it.next() orelse return error.OddExtraTokens;
        const detach_in = std.fmt.parseUnsigned(usize, din_tok, 10) catch return error.InvalidNumber;
        try expectExhausted(&it);
        return .{
            .src = src,
            .src_out = src_out,
            .dst = dst,
            .dst_in = dst_in,
            .detach_dst = detach_dst,
            .detach_in = detach_in,
        };
    }
    try expectExhausted(&it);
    return .{ .src = src, .src_out = src_out, .dst = dst, .dst_in = dst_in };
}

pub const AddMacro = struct { kind: []const u8, x: f32, y: f32 };

/// "<macro-kind> <x> <y>" (add_macro).
pub fn parseAddMacro(args: []const u8) ParseError!AddMacro {
    var it = tokenize(args);
    const kind = it.next() orelse return error.Empty;
    const x_tok = it.next() orelse return error.Empty;
    const x = try parseFiniteCoord(x_tok);
    const y_tok = it.next() orelse return error.Empty;
    const y = try parseFiniteCoord(y_tok);
    try expectExhausted(&it);
    return .{ .kind = kind, .x = x, .y = y };
}

pub const RemoveMacro = struct {
    members: [MAX_REMOVE_MACRO_MEMBERS]NodeRef,
    count: usize,
};

/// "`#id` ..." — one or more member NodeRefs (remove_macro).
pub fn parseRemoveMacro(args: []const u8) ParseError!RemoveMacro {
    var it = tokenize(args);
    var out: RemoveMacro = .{ .members = undefined, .count = 0 };
    while (it.next()) |tok| {
        if (out.count >= MAX_REMOVE_MACRO_MEMBERS) return error.TooManyMacroMembers;
        out.members[out.count] = try parseNodeRefToken(tok);
        out.count += 1;
    }
    if (out.count == 0) return error.Empty;
    return out;
}

/// Writes `#<id>` into buf.
pub fn formatNodeId(buf: []u8, id: u64) error{TooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "#{d}", .{id}) catch return error.TooLong;
}

pub fn formatAddNode(buf: []u8, kind: []const u8, x: f32, y: f32) error{TooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "{s} {d} {d}", .{ kind, x, y }) catch return error.TooLong;
}

pub fn formatMoveNode(buf: []u8, id: u64, x: f32, y: f32) error{TooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "#{d} {d} {d}", .{ id, x, y }) catch return error.TooLong;
}

pub fn formatDisconnect(buf: []u8, id: u64, dst_in: usize) error{TooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "#{d} {d}", .{ id, dst_in }) catch return error.TooLong;
}

pub fn formatConnect(buf: []u8, src_id: u64, src_out: usize, dst_id: u64, dst_in: usize) error{TooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "#{d} {d} #{d} {d}", .{ src_id, src_out, dst_id, dst_in }) catch return error.TooLong;
}

pub fn formatConnectWithDetach(
    buf: []u8,
    src_id: u64,
    src_out: usize,
    dst_id: u64,
    dst_in: usize,
    detach_id: u64,
    detach_in: usize,
) error{TooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "#{d} {d} #{d} {d} #{d} {d}", .{ src_id, src_out, dst_id, dst_in, detach_id, detach_in }) catch return error.TooLong;
}

pub fn formatAddMacro(buf: []u8, kind: []const u8, x: f32, y: f32) error{TooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "{s} {d} {d}", .{ kind, x, y }) catch return error.TooLong;
}

/// A `.relay` graph op during netsync requires `#<id>` (a bare handle could target the wrong node).
pub fn nodeRefRejectDuringNetsync(ref: NodeRef, netsync_active: bool) bool {
    return netsync_active and ref == .handle;
}

/// Whether canonicalize may convert a bare handle to #id (forbidden during netsync).
pub fn allowNodeCanonFill(netsync_active: bool) bool {
    return !netsync_active;
}

/// Truncation marker at the end of a digest (same shape as pixie. `" trunc=1"` = 8 bytes).
pub const DIGEST_TRUNC_MARKER = " trunc=1";

/// If `truncated=false`, returns `buf[0..written]` as-is.
/// If `truncated=true`, appends ` trunc=1` at the end, trimming written if needed to make room.
pub fn finishDigestWithTrunc(buf: []u8, written: usize, truncated: bool) []const u8 {
    if (!truncated) return buf[0..written];
    const marker = DIGEST_TRUNC_MARKER;
    var n = written;
    if (n > buf.len) n = buf.len;
    if (n + marker.len > buf.len) {
        if (buf.len < marker.len) return buf[0..0];
        n = buf.len - marker.len;
    }
    @memcpy(buf[n..][0..marker.len], marker);
    return buf[0 .. n + marker.len];
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseUsize: valid value / empty / invalid number / extra token" {
    try testing.expectEqual(@as(usize, 0), try parseUsize("0"));
    try testing.expectEqual(@as(usize, 7), try parseUsize("  7  "));
    try testing.expectError(error.Empty, parseUsize(""));
    try testing.expectError(error.InvalidNumber, parseUsize("abc"));
    try testing.expectError(error.InvalidNumber, parseUsize("-1"));
    try testing.expectError(error.TooManyTokens, parseUsize("1 2"));
}

test "parseSelectNode / parseParamOverride: handle and value" {
    try testing.expectEqual(@as(usize, 17), try parseSelectNode(" 17 "));
    const p = try parseParamOverride("17 cutoff 2000");
    try testing.expectEqual(NodeRef{ .handle = 17 }, p.ref);
    try testing.expectEqualStrings("cutoff", p.name);
    try testing.expectEqual(@as(f32, 2000), p.value);
    try testing.expectError(error.Empty, parseParamOverride("17 cutoff"));
    try testing.expectError(error.InvalidNumber, parseParamOverride("-1 cutoff 2000"));
    try testing.expectError(error.TooManyTokens, parseParamOverride("17 cutoff 2000 extra"));
    try testing.expectError(error.InvalidNumber, parseParamOverride("17 cutoff nan"));
}

test "parseParamOverride: #<NodeId> / #0 / Inf / empty name" {
    const p = try parseParamOverride("#123 cutoff 2000");
    try testing.expectEqual(NodeRef{ .id = 123 }, p.ref);
    try testing.expectEqualStrings("cutoff", p.name);
    try testing.expectEqual(@as(f32, 2000), p.value);
    try testing.expectError(error.InvalidNumber, parseParamOverride("#0 cutoff 1"));
    try testing.expectError(error.InvalidNumber, parseParamOverride("#abc cutoff 1"));
    try testing.expectError(error.InvalidNumber, parseParamOverride("#99999999999999999999 cutoff 1"));
    try testing.expectError(error.InvalidNumber, parseParamOverride("#1 cutoff inf"));
    try testing.expectError(error.InvalidNumber, parseParamOverride("#1 cutoff nan"));
    try testing.expectError(error.Empty, parseParamOverride("#1"));
    try testing.expectError(error.TooManyTokens, parseParamOverride("#1 cutoff 1 extra"));
    // The legacy Transport alias (2 tokens) is rejected because 3 tokens are now required.
    try testing.expectError(error.InvalidNumber, parseParamOverride("tempo 140"));
    try testing.expectError(error.InvalidNumber, parseParamOverride("cutoff 0.5"));
}

test "parseParamOverride: whitespace and floating point" {
    const p = try parseParamOverride(" 3 resonance 0.75 ");
    try testing.expectEqual(NodeRef{ .handle = 3 }, p.ref);
    try testing.expectEqualStrings("resonance", p.name);
    try testing.expectApproxEqAbs(@as(f32, 0.75), p.value, 1e-6);
    try testing.expectError(error.Empty, parseSelectNode(""));
    try testing.expectError(error.TooManyTokens, parseSelectNode("3 4"));
}

test "formatParamOverride: round-trip with parseParamOverride" {
    var buf: [64]u8 = undefined;
    const s = try formatParamOverride(&buf, 42, "cutoff", 2000);
    const p = try parseParamOverride(s);
    try testing.expectEqual(NodeRef{ .id = 42 }, p.ref);
    try testing.expectEqualStrings("cutoff", p.name);
    try testing.expectEqual(@as(f32, 2000), p.value);
}

test "parseTwoUsize: valid value / invalid number / extra token" {
    const r = try parseTwoUsize("3 1");
    try testing.expectEqual(@as(usize, 3), r.a);
    try testing.expectEqual(@as(usize, 1), r.b);
    try testing.expectError(error.Empty, parseTwoUsize("3"));
    try testing.expectError(error.InvalidNumber, parseTwoUsize("3 abc"));
    try testing.expectError(error.TooManyTokens, parseTwoUsize("3 1 5"));
}

test "parseFourUsize: valid value / insufficient / extra token" {
    const r = try parseFourUsize("1 0 2 1");
    try testing.expectEqual(@as(usize, 1), r.a);
    try testing.expectEqual(@as(usize, 0), r.b);
    try testing.expectEqual(@as(usize, 2), r.c);
    try testing.expectEqual(@as(usize, 1), r.d);
    try testing.expectError(error.Empty, parseFourUsize("1 0 2"));
    try testing.expectError(error.TooManyTokens, parseFourUsize("1 0 2 1 9"));
}

test "parsePath: trims leading/trailing / preserves internal whitespace / rejects empty" {
    try testing.expectEqualStrings("/tmp/out.ptcg", try parsePath("  /tmp/out.ptcg  "));
    try testing.expectEqualStrings("/tmp/my graph.ptcg", try parsePath("/tmp/my graph.ptcg"));
    try testing.expectError(error.Empty, parsePath(""));
    try testing.expectError(error.Empty, parsePath("   "));
}

test "parseAddNode: kind+xy required / rejects NaN, Inf, out-of-range" {
    const r2 = try parseAddNode("vco 10 20");
    try testing.expectEqualStrings("vco", r2.kind);
    try testing.expectEqual(@as(f32, 10), r2.x);
    try testing.expectEqual(@as(f32, 20), r2.y);

    try testing.expectError(error.Empty, parseAddNode(""));
    try testing.expectError(error.Empty, parseAddNode("vco"));
    try testing.expectError(error.Empty, parseAddNode("vco 10"));
    try testing.expectError(error.InvalidNumber, parseAddNode("vco abc 20"));
    try testing.expectError(error.InvalidCoord, parseAddNode("vco nan 20"));
    try testing.expectError(error.InvalidCoord, parseAddNode("vco 1 inf"));
    try testing.expectError(error.InvalidCoord, parseAddNode("vco 2000000 0"));
    try testing.expectError(error.TooManyTokens, parseAddNode("vco 10 20 30"));
}

test "parseAddNode: step_seq_bass wire alias / unknown kind token passes through unchanged" {
    // The parser passes kind through unchanged. ModuleKind resolution happens on the main side. Aliases are also accepted as ordinary tokens.
    const bass = try parseAddNode("step_seq_bass 1.5 2.5");
    try testing.expectEqualStrings("step_seq_bass", bass.kind);
    try testing.expectEqual(@as(f32, 1.5), bass.x);
    try testing.expectEqual(@as(f32, 2.5), bass.y);
    const drum = try parseAddNode("step_seq 0 0");
    try testing.expectEqualStrings("step_seq", drum.kind);
    // Parsing an unknown token still succeeds (UnknownKind is handled on the action side).
    const unk = try parseAddNode("not_a_module 3 4");
    try testing.expectEqualStrings("not_a_module", unk.kind);
}

test "parseNodeRef: #<id> and bare handle / rejects 0 / extra token" {
    try testing.expectEqual(NodeRef{ .id = 1 }, try parseNodeRef("#1"));
    try testing.expectEqual(NodeRef{ .id = 42 }, try parseNodeRef("  #42  "));
    try testing.expectEqual(NodeRef{ .handle = 0 }, try parseNodeRef("0"));
    try testing.expectEqual(NodeRef{ .handle = 3 }, try parseNodeRef("3"));
    try testing.expectError(error.Empty, parseNodeRef(""));
    try testing.expectError(error.InvalidNumber, parseNodeRef("#"));
    try testing.expectError(error.InvalidNumber, parseNodeRef("#0"));
    try testing.expectError(error.InvalidNumber, parseNodeRef("#abc"));
    try testing.expectError(error.InvalidNumber, parseNodeRef("abc"));
    try testing.expectError(error.TooManyTokens, parseNodeRef("#1 2"));
}

test "nodeRefRejectDuringNetsync / allowNodeCanonFill" {
    try testing.expect(nodeRefRejectDuringNetsync(.{ .handle = 0 }, true));
    try testing.expect(!nodeRefRejectDuringNetsync(.{ .id = 1 }, true));
    try testing.expect(!nodeRefRejectDuringNetsync(.{ .handle = 0 }, false));
    try testing.expect(allowNodeCanonFill(false));
    try testing.expect(!allowNodeCanonFill(true));
}

test "parseMoveNode / parseDisconnect / parseConnect(+detach)" {
    const m = try parseMoveNode("#7 1.5 -2");
    try testing.expectEqual(NodeRef{ .id = 7 }, m.ref);
    try testing.expectEqual(@as(f32, 1.5), m.x);
    try testing.expectEqual(@as(f32, -2), m.y);
    try testing.expectError(error.InvalidCoord, parseMoveNode("#1 nan 0"));

    const d = try parseDisconnect("#3 1");
    try testing.expectEqual(NodeRef{ .id = 3 }, d.dst);
    try testing.expectEqual(@as(usize, 1), d.dst_in);
    try testing.expectError(error.Empty, parseDisconnect("#3"));

    const c = try parseConnect("#1 0 #2 1");
    try testing.expectEqual(NodeRef{ .id = 1 }, c.src);
    try testing.expectEqual(@as(usize, 0), c.src_out);
    try testing.expectEqual(NodeRef{ .id = 2 }, c.dst);
    try testing.expectEqual(@as(usize, 1), c.dst_in);
    try testing.expect(c.detach_dst == null);

    const cd = try parseConnect("#1 0 #2 1 #9 0");
    try testing.expectEqual(NodeRef{ .id = 9 }, cd.detach_dst.?);
    try testing.expectEqual(@as(usize, 0), cd.detach_in.?);
    try testing.expectError(error.OddExtraTokens, parseConnect("#1 0 #2 1 #9"));
    try testing.expectError(error.TooManyTokens, parseConnect("#1 0 #2 1 #9 0 extra"));
}

test "parseAddMacro / parseRemoveMacro" {
    const a = try parseAddMacro("drum_machine 10 20");
    try testing.expectEqualStrings("drum_machine", a.kind);
    try testing.expectEqual(@as(f32, 10), a.x);
    try testing.expectError(error.Empty, parseAddMacro("drum_machine"));

    const r = try parseRemoveMacro("#1 #2 #3");
    try testing.expectEqual(@as(usize, 3), r.count);
    try testing.expectEqual(NodeRef{ .id = 1 }, r.members[0]);
    try testing.expectError(error.Empty, parseRemoveMacro(""));
    try testing.expectError(error.InvalidNumber, parseRemoveMacro("#0"));
}

test "formatNodeId* / connect detach: round-trip with parsers" {
    var buf: [128]u8 = undefined;
    const a = try formatNodeId(&buf, 7);
    try testing.expectEqual(NodeRef{ .id = 7 }, try parseNodeRef(a));

    const mv = try formatMoveNode(&buf, 2, 3.25, -1);
    const pm = try parseMoveNode(mv);
    try testing.expectEqual(NodeRef{ .id = 2 }, pm.ref);

    const cn = try formatConnect(&buf, 1, 0, 2, 1);
    const pc = try parseConnect(cn);
    try testing.expectEqual(NodeRef{ .id = 1 }, pc.src);
    try testing.expectEqual(NodeRef{ .id = 2 }, pc.dst);

    const cnd = try formatConnectWithDetach(&buf, 1, 0, 2, 1, 9, 0);
    const pcd = try parseConnect(cnd);
    try testing.expectEqual(NodeRef{ .id = 9 }, pcd.detach_dst.?);

    const an = try formatAddNode(&buf, "vco", 10, 20);
    const pan = try parseAddNode(an);
    try testing.expectEqualStrings("vco", pan.kind);
}

test "finishDigestWithTrunc: non-trunc is bit-identical / trunc appends trunc=1 at the end" {
    var buf: [64]u8 = undefined;
    const base = "{\"nodes\":[]}";
    @memcpy(buf[0..base.len], base);
    try testing.expectEqualStrings(base, finishDigestWithTrunc(&buf, base.len, false));

    var full: [20]u8 = undefined;
    @memset(&full, 'x');
    const out = finishDigestWithTrunc(&full, full.len, true);
    try testing.expect(std.mem.endsWith(u8, out, " trunc=1"));
}

test "canonical args: the same input always yields the same format result" {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    const s1 = try formatConnect(&a, 3, 1, 5, 0);
    const s2 = try formatConnect(&b, 3, 1, 5, 0);
    try testing.expectEqualStrings(s1, s2);
    const p1 = try parseConnect(s1);
    const p2 = try parseConnect(s2);
    try testing.expectEqual(p1.src, p2.src);
    try testing.expectEqual(p1.dst, p2.dst);
}
