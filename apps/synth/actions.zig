//! apps/synth の harness action（TASK-65）向け純パーサ。
//!
//! ホットパス宣言: ここでパースした結果は「イベント時のみ」（harness の `action <name> [args]`
//! コマンド1回につき1回）dispatch される。毎フレーム全画素ループ・毎サンプル RT 経路のいずれでもない
//! ため、性能規約（SIMD 3点セット等）の適用対象外。
//!
//! このファイルは **std のみに依存**し、App / kit / platform / dsp を一切 import しない
//! （pixie の `actions.zig` と同型。main.zig との circular import を避け、単体テスト可能にする）。
//! パラメータ名・enum 名（wave/filter 等）の解決は App の具象型を知る main.zig 側が行う
//! （pixie の `ToolKind` 解決と同じ分離方針。このファイルは name を素通しする）。
//!
//! 各パーサは `action <name>` の後の残り行 raw テキスト（trim 済み・main.zig 側で `;`/改行は
//! 既に取り除かれている）を受け取り、typed な値かエラーを返す。空白区切りのトークンを読み、
//! **余剰トークンがあれば `error.TooManyTokens` で拒否**する（fail-fast。typo を握りつぶさない）。

const std = @import("std");

pub const ParseError = error{
    Empty,
    InvalidNumber,
    NonFinite,
    TooManyTokens,
    UnknownBool,
};

fn tokenize(args: []const u8) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, args, " \t");
}

/// トークン反復子に余剰トークンが残っていないか検査する（fail-fast の共通ヘルパー）。
fn expectExhausted(it: *std.mem.TokenIterator(u8, .any)) ParseError!void {
    if (it.next() != null) return error.TooManyTokens;
}

pub const NameF32 = struct { name: []const u8, value: f32 };

/// "<name> <value>" の2トークン（`set_param`/`set_fx_param` 用の汎用 f32 setter パーサ）。
/// NaN/Inf は `error.NonFinite` で拒否する（fail-fast。非有限値を RT 側 Patch へ渡すと
/// `makePatch` の `@intFromFloat(clamp(round(unison)))` 等で illegal behavior を招くため）。
pub fn parseNameF32(args: []const u8) ParseError!NameF32 {
    var it = tokenize(args);
    const name = it.next() orelse return error.Empty;
    const v_tok = it.next() orelse return error.Empty;
    const value = std.fmt.parseFloat(f32, v_tok) catch return error.InvalidNumber;
    if (!std.math.isFinite(value)) return error.NonFinite;
    try expectExhausted(&it);
    return .{ .name = name, .value = value };
}

/// "<name>" の1トークン（`set_wave`/`set_osc2_wave`/`set_filter` 用）。
pub fn parseName(args: []const u8) ParseError![]const u8 {
    var it = tokenize(args);
    const name = it.next() orelse return error.Empty;
    try expectExhausted(&it);
    return name;
}

/// "<0|1>" の1トークン（`set_fx_bypass` 用）。
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

/// `save_patch`/`load_patch` 用: 前後の空白のみ trim し、内部の空白はそのまま保持する（path は
/// 空白を含みうる1本の文字列として扱う。数値系パーサのようにトークナイズしない。pixie の
/// `parsePath` と同型）。
pub fn parsePath(args: []const u8) ParseError![]const u8 {
    const trimmed = std.mem.trim(u8, args, " \t");
    if (trimmed.len == 0) return error.Empty;
    return trimmed;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseNameF32: 有効値 / 空 / 不正数値 / 非有限 / 余剰トークン" {
    const r = try parseNameF32("cutoff 8000");
    try testing.expectEqualStrings("cutoff", r.name);
    try testing.expectEqual(@as(f32, 8000), r.value);

    const r2 = try parseNameF32("  gain   0.25  ");
    try testing.expectEqualStrings("gain", r2.name);
    try testing.expectEqual(@as(f32, 0.25), r2.value);

    try testing.expectError(error.Empty, parseNameF32(""));
    try testing.expectError(error.Empty, parseNameF32("cutoff"));
    try testing.expectError(error.InvalidNumber, parseNameF32("cutoff abc"));
    try testing.expectError(error.NonFinite, parseNameF32("cutoff nan"));
    try testing.expectError(error.NonFinite, parseNameF32("cutoff inf"));
    try testing.expectError(error.NonFinite, parseNameF32("cutoff -inf"));
    try testing.expectError(error.TooManyTokens, parseNameF32("cutoff 8000 extra"));
}

test "parseName: 前後 trim / 余剰トークン拒否 / 空拒否" {
    try testing.expectEqualStrings("saw", try parseName("  saw  "));
    try testing.expectError(error.Empty, parseName(""));
    try testing.expectError(error.Empty, parseName("   "));
    try testing.expectError(error.TooManyTokens, parseName("saw extra"));
}

test "parseBool01: 0/1 のみ許容" {
    try testing.expectEqual(true, try parseBool01("1"));
    try testing.expectEqual(false, try parseBool01("0"));
    try testing.expectError(error.UnknownBool, parseBool01("true"));
    try testing.expectError(error.Empty, parseBool01(""));
    try testing.expectError(error.TooManyTokens, parseBool01("1 0"));
}

test "parsePath: 前後 trim / 内部空白保持 / 空は拒否" {
    try testing.expectEqualStrings("/tmp/out.synp", try parsePath("  /tmp/out.synp  "));
    try testing.expectEqualStrings("/tmp/my patch.synp", try parsePath("/tmp/my patch.synp"));
    try testing.expectError(error.Empty, parsePath(""));
    try testing.expectError(error.Empty, parsePath("   "));
}
