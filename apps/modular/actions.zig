//! apps/modular の harness action（TASK-65）向け純パーサ。
//!
//! ホットパス宣言: ここでパースした結果は「イベント時のみ」（harness の `action <name> [args]`
//! コマンド1回につき1回）dispatch される。毎フレーム全画素ループ・毎サンプル RT 経路のいずれでもない
//! ため、性能規約（SIMD 3点セット等）の適用対象外。
//!
//! このファイルは **std のみに依存**し、App / kit / platform / modular を一切 import しない
//! （pixie の `actions.zig` と同型。main.zig との circular import を避け、単体テスト可能にする）。
//! track 名（kick/hat/clap/bass 等）の enum 解決は App の具象型を知る main.zig 側が行う
//! （pixie の `ToolKind` 解決と同じ分離方針。このファイルは name を素通しする）。

const std = @import("std");

pub const ParseError = error{
    Empty,
    InvalidNumber,
    NonFinite,
    TooManyTokens,
    UnknownBool,
    OutOfRange,
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
