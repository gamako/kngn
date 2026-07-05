//! pixie の harness action（TASK-64）向け純パーサ。
//!
//! ホットパス宣言: ここでパースした結果は「イベント時のみ」（harness の `action <name> [args]`
//! コマンド1回につき1回）dispatch される。毎フレーム全画素ループ・毎サンプル RT 経路のいずれでもない
//! ため、性能規約（SIMD 3点セット等）の適用対象外。
//!
//! このファイルは **std のみに依存**し、App / kit / platform を一切 import しない（main.zig との
//! circular import を避けるため。App の具象型に依存する dispatch と `registerActions(app)` は
//! main.zig 側の「ヘッドレス検証 harness の custom action」セクションに直接書く。詳細な設計意図
//! （action ⇄ UndoCmd 対応表・undo push の有無・TASK-65/network への申し送り）もそちらの doc
//! comment を参照）。
//!
//! 各パーサは `action <name>` の後の残り行 raw テキスト（trim 済み・main.zig 側で `;`/改行は
//! 既に取り除かれている）を受け取り、typed な値かエラーを返す。数値系パーサは空白区切りの
//! トークンを読み、**余剰トークンがあれば `error.TooManyTokens` で拒否**する（fail-fast。
//! typo を握りつぶさない）。`parsePath` だけは例外で、path が空白を含みうるため素通しする。

const std = @import("std");

pub const ParseError = error{
    Empty,
    InvalidNumber,
    TooManyTokens,
    UnknownBool,
    OddPointCount,
    TooManyPoints,
    InvalidDelta,
};

fn tokenize(args: []const u8) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, args, " \t");
}

/// トークン反復子に余剰トークンが残っていないか検査する（fail-fast の共通ヘルパー）。
fn expectExhausted(it: *std.mem.TokenIterator(u8, .any)) ParseError!void {
    if (it.next() != null) return error.TooManyTokens;
}

/// "<idx>" の1トークン。
pub fn parseUsize(args: []const u8) ParseError!usize {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const v = std.fmt.parseUnsigned(usize, tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return v;
}

/// "<0-255>" の1トークン。
pub fn parseU8(args: []const u8) ParseError!u8 {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const v = std.fmt.parseUnsigned(u8, tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return v;
}

/// 符号付き整数の1トークン（`move_layer` 以外の汎用パーサとして用意。現状 pixie action は
/// `parseMoveDelta` を使うが、境界テスト・将来の action 追加向けに公開しておく）。
pub fn parseI32(args: []const u8) ParseError!i32 {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const v = std.fmt.parseInt(i32, tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return v;
}

pub const IdxBool = struct { idx: usize, on: bool };

/// "<idx> <0|1>" の2トークン。
pub fn parseIdxBool(args: []const u8) ParseError!IdxBool {
    var it = tokenize(args);
    const idx_tok = it.next() orelse return error.Empty;
    const idx = std.fmt.parseUnsigned(usize, idx_tok, 10) catch return error.InvalidNumber;
    const b_tok = it.next() orelse return error.Empty;
    const on = if (std.mem.eql(u8, b_tok, "0"))
        false
    else if (std.mem.eql(u8, b_tok, "1"))
        true
    else
        return error.UnknownBool;
    try expectExhausted(&it);
    return .{ .idx = idx, .on = on };
}

pub const IdxU8 = struct { idx: usize, value: u8 };

/// "<idx> <0-255>" の2トークン。
pub fn parseIdxU8(args: []const u8) ParseError!IdxU8 {
    var it = tokenize(args);
    const idx_tok = it.next() orelse return error.Empty;
    const idx = std.fmt.parseUnsigned(usize, idx_tok, 10) catch return error.InvalidNumber;
    const v_tok = it.next() orelse return error.Empty;
    const value = std.fmt.parseUnsigned(u8, v_tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return .{ .idx = idx, .value = value };
}

// TASK-79.5（テキストレイヤー）向けの action パーサは追加していない。harness の action
// registry は `MAX_ACTIONS=16`（core/control/harness.zig）固定で pixie は既に使い切っており
// （main.zig の `registerActions` doc comment 参照）、harness.zig 改変はスコープ外のため
// 空き slot が無い。テキストレイヤーの harness 検証は UI 操作（右クリックメニュー +
// `inject char`）で行う。

/// "#RRGGBB" または "RRGGBB"（大小無視）の1トークン → canonical 0xFFRRGGBB（straight・alpha=255固定）。
pub fn parseHexColor(args: []const u8) ParseError!u32 {
    var it = tokenize(args);
    var tok = it.next() orelse return error.Empty;
    if (tok.len > 0 and tok[0] == '#') tok = tok[1..];
    if (tok.len != 6) return error.InvalidNumber;
    const rgb = std.fmt.parseUnsigned(u32, tok, 16) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return 0xFF000000 | rgb;
}

/// "<+1|-1>" の1トークン（`move_layer` 専用。±1 以外は `error.InvalidDelta`）。
pub fn parseMoveDelta(args: []const u8) ParseError!i32 {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const v = std.fmt.parseInt(i32, tok, 10) catch return error.InvalidNumber;
    if (v != 1 and v != -1) return error.InvalidDelta;
    try expectExhausted(&it);
    return v;
}

pub const Point = struct { x: i32, y: i32 };

/// stroke action の点列上限（呼び出し側がこのサイズの固定長スタックバッファを用意する）。
pub const MAX_STROKE_POINTS: usize = 256;

/// "x0 y0 x1 y1 ..." → `buf` に詰めて borrowed slice を返す（allocator を取らない・所有権移動なし）。
/// 偶数個必須（奇数個は `error.OddPointCount`）。0個は `error.Empty`。`buf.len` 超過は `error.TooManyPoints`。
pub fn parseStrokePoints(args: []const u8, buf: []Point) ParseError![]Point {
    var it = tokenize(args);
    var n: usize = 0;
    while (it.next()) |x_tok| {
        const y_tok = it.next() orelse return error.OddPointCount;
        const x = std.fmt.parseInt(i32, x_tok, 10) catch return error.InvalidNumber;
        const y = std.fmt.parseInt(i32, y_tok, 10) catch return error.InvalidNumber;
        if (n >= buf.len) return error.TooManyPoints;
        buf[n] = .{ .x = x, .y = y };
        n += 1;
    }
    if (n == 0) return error.Empty;
    return buf[0..n];
}

/// `save`/`open` 用: 前後の空白のみ trim し、内部の空白はそのまま保持する（path は空白を
/// 含みうる1本の文字列として扱う。数値系パーサのようにトークナイズしない）。
pub fn parsePath(args: []const u8) ParseError![]const u8 {
    const trimmed = std.mem.trim(u8, args, " \t");
    if (trimmed.len == 0) return error.Empty;
    return trimmed;
}

/// 引数を取らない action（undo/redo/clear/add_layer/delete_layer）用: trim 後に空であることを
/// 確認する（余剰トークンは `error.TooManyTokens`。typo を握りつぶさない）。
pub fn parseNoArgs(args: []const u8) ParseError!void {
    if (std.mem.trim(u8, args, " \t").len != 0) return error.TooManyTokens;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseUsize: 有効値 / 空 / 不正数値 / 余剰トークン" {
    try testing.expectEqual(@as(usize, 0), try parseUsize("0"));
    try testing.expectEqual(@as(usize, 42), try parseUsize("  42  "));
    try testing.expectError(error.Empty, parseUsize(""));
    try testing.expectError(error.Empty, parseUsize("   "));
    try testing.expectError(error.InvalidNumber, parseUsize("abc"));
    try testing.expectError(error.InvalidNumber, parseUsize("-1"));
    try testing.expectError(error.TooManyTokens, parseUsize("1 2"));
}

test "parseU8: 範囲外は InvalidNumber" {
    try testing.expectEqual(@as(u8, 255), try parseU8("255"));
    try testing.expectError(error.InvalidNumber, parseU8("256"));
}

test "parseIdxBool: 0/1 のみ許容 / 不正トークン" {
    try testing.expectEqual(IdxBool{ .idx = 3, .on = true }, try parseIdxBool("3 1"));
    try testing.expectEqual(IdxBool{ .idx = 0, .on = false }, try parseIdxBool("0 0"));
    try testing.expectError(error.UnknownBool, parseIdxBool("0 true"));
    try testing.expectError(error.Empty, parseIdxBool("0"));
    try testing.expectError(error.TooManyTokens, parseIdxBool("0 1 2"));
}

test "parseIdxU8: 有効値 / 範囲外" {
    try testing.expectEqual(IdxU8{ .idx = 2, .value = 128 }, try parseIdxU8("2 128"));
    try testing.expectError(error.InvalidNumber, parseIdxU8("2 999"));
    try testing.expectError(error.Empty, parseIdxU8("2"));
}

test "parseHexColor: # 有無どちらも許容 / 大小無視 / 桁数不正 / 不正文字" {
    try testing.expectEqual(@as(u32, 0xFFFF0000), try parseHexColor("#FF0000"));
    try testing.expectEqual(@as(u32, 0xFFFF0000), try parseHexColor("FF0000"));
    try testing.expectEqual(@as(u32, 0xFF00FF00), try parseHexColor("00ff00"));
    try testing.expectError(error.InvalidNumber, parseHexColor("#FF00"));
    try testing.expectError(error.InvalidNumber, parseHexColor("#GGGGGG"));
    try testing.expectError(error.Empty, parseHexColor(""));
}

test "parseMoveDelta: +1/-1 のみ許容" {
    try testing.expectEqual(@as(i32, 1), try parseMoveDelta("1"));
    try testing.expectEqual(@as(i32, -1), try parseMoveDelta("-1"));
    try testing.expectError(error.InvalidDelta, parseMoveDelta("2"));
    try testing.expectError(error.InvalidDelta, parseMoveDelta("0"));
}

test "parseStrokePoints: 有効列 / 奇数個 / 空 / 上限超過" {
    var buf: [MAX_STROKE_POINTS]Point = undefined;
    const pts = try parseStrokePoints("10 10 50 10 50 50", &buf);
    try testing.expectEqual(@as(usize, 3), pts.len);
    try testing.expectEqual(Point{ .x = 10, .y = 10 }, pts[0]);
    try testing.expectEqual(Point{ .x = 50, .y = 50 }, pts[2]);

    try testing.expectError(error.OddPointCount, parseStrokePoints("10 10 50", &buf));
    try testing.expectError(error.Empty, parseStrokePoints("", &buf));

    var small_buf: [1]Point = undefined;
    try testing.expectError(error.TooManyPoints, parseStrokePoints("0 0 1 1", &small_buf));
}

test "parsePath: 前後 trim / 内部空白保持 / 空は拒否" {
    try testing.expectEqualStrings("/tmp/out.png", try parsePath("  /tmp/out.png  "));
    try testing.expectEqualStrings("/tmp/my file.png", try parsePath("/tmp/my file.png"));
    try testing.expectError(error.Empty, parsePath(""));
    try testing.expectError(error.Empty, parsePath("   "));
}

test "parseNoArgs: 空は許容 / 余剰トークンは拒否" {
    try parseNoArgs("");
    try parseNoArgs("   ");
    try testing.expectError(error.TooManyTokens, parseNoArgs("typo"));
}

