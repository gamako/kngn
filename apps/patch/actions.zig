//! apps/patch の harness action（TASK-65）向け純パーサ。
//!
//! ホットパス宣言: ここでパースした結果は「イベント時のみ」（harness の `action <name> [args]`
//! コマンド1回につき1回）dispatch される。毎フレーム全画素ループ・毎サンプル RT 経路のいずれでもない
//! ため、性能規約（SIMD 3点セット等）の適用対象外。
//!
//! このファイルは **std のみに依存**し、App / kit / platform / modular を一切 import しない
//! （pixie の `actions.zig` と同型。main.zig との circular import を避け、単体テスト可能にする）。
//! `ModuleKind` 名の enum 解決は App の具象型を知る main.zig 側が行う（pixie の `ToolKind` 解決と
//! 同じ分離方針。このファイルは kind 名を素通しする）。

const std = @import("std");

pub const ParseError = error{
    Empty,
    InvalidNumber,
    TooManyTokens,
    OddExtraTokens,
};

fn tokenize(args: []const u8) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, args, " \t");
}

fn expectExhausted(it: *std.mem.TokenIterator(u8, .any)) ParseError!void {
    if (it.next() != null) return error.TooManyTokens;
}

/// "<handle>" の1トークン（`remove_node` 用）。
pub fn parseUsize(args: []const u8) ParseError!usize {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const v = std.fmt.parseUnsigned(usize, tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return v;
}

pub const TwoUsize = struct { a: usize, b: usize };

/// "<a> <b>" の2トークン（`disconnect <dst_handle> <dst_in>` 用）。
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

/// "<src_h> <src_out> <dst_h> <dst_in>" の4トークン（`connect` 用）。
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

pub const AddNode = struct { kind: []const u8, x: ?f32 = null, y: ?f32 = null };

/// "<kind> [x y]" — kind 名の1トークン + 省略可能な world 座標2トークン（`add_node` 用）。
/// x のみ・3個以上の余剰トークンは `error.OddExtraTokens`。
pub fn parseAddNode(args: []const u8) ParseError!AddNode {
    var it = tokenize(args);
    const kind = it.next() orelse return error.Empty;
    const x_tok = it.next() orelse return .{ .kind = kind };
    const x = std.fmt.parseFloat(f32, x_tok) catch return error.InvalidNumber;
    const y_tok = it.next() orelse return error.OddExtraTokens;
    const y = std.fmt.parseFloat(f32, y_tok) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return .{ .kind = kind, .x = x, .y = y };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseUsize: 有効値 / 空 / 不正数値 / 余剰トークン" {
    try testing.expectEqual(@as(usize, 0), try parseUsize("0"));
    try testing.expectEqual(@as(usize, 7), try parseUsize("  7  "));
    try testing.expectError(error.Empty, parseUsize(""));
    try testing.expectError(error.InvalidNumber, parseUsize("abc"));
    try testing.expectError(error.InvalidNumber, parseUsize("-1"));
    try testing.expectError(error.TooManyTokens, parseUsize("1 2"));
}

test "parseTwoUsize: 有効値 / 不正数値 / 余剰トークン" {
    const r = try parseTwoUsize("3 1");
    try testing.expectEqual(@as(usize, 3), r.a);
    try testing.expectEqual(@as(usize, 1), r.b);
    try testing.expectError(error.Empty, parseTwoUsize("3"));
    try testing.expectError(error.InvalidNumber, parseTwoUsize("3 abc"));
    try testing.expectError(error.TooManyTokens, parseTwoUsize("3 1 5"));
}

test "parseFourUsize: 有効値 / 不足 / 余剰トークン" {
    const r = try parseFourUsize("1 0 2 1");
    try testing.expectEqual(@as(usize, 1), r.a);
    try testing.expectEqual(@as(usize, 0), r.b);
    try testing.expectEqual(@as(usize, 2), r.c);
    try testing.expectEqual(@as(usize, 1), r.d);
    try testing.expectError(error.Empty, parseFourUsize("1 0 2"));
    try testing.expectError(error.TooManyTokens, parseFourUsize("1 0 2 1 9"));
}

test "parseAddNode: kind のみ / kind+xy / 不正数値 / x のみは OddExtraTokens" {
    const r1 = try parseAddNode("vco");
    try testing.expectEqualStrings("vco", r1.kind);
    try testing.expectEqual(@as(?f32, null), r1.x);
    try testing.expectEqual(@as(?f32, null), r1.y);

    const r2 = try parseAddNode("vco 10 20");
    try testing.expectEqualStrings("vco", r2.kind);
    try testing.expectEqual(@as(?f32, 10), r2.x);
    try testing.expectEqual(@as(?f32, 20), r2.y);

    try testing.expectError(error.Empty, parseAddNode(""));
    try testing.expectError(error.InvalidNumber, parseAddNode("vco abc 20"));
    try testing.expectError(error.OddExtraTokens, parseAddNode("vco 10"));
    try testing.expectError(error.TooManyTokens, parseAddNode("vco 10 20 30"));
}
