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
    DuplicateKey,
    UnknownKey,
    UnknownTool,
    ValueOutOfRange,
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

pub const OnionArgs = struct { enabled: bool, count: ?u32 };

/// "on [count]" / "off" / "1 [count]" / "0"。count は省略可（1..3 を呼び出し側で clamp）。
pub fn parseOnion(args: []const u8) ParseError!OnionArgs {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const enabled = if (std.ascii.eqlIgnoreCase(tok, "on") or std.mem.eql(u8, tok, "1"))
        true
    else if (std.ascii.eqlIgnoreCase(tok, "off") or std.mem.eql(u8, tok, "0"))
        false
    else
        return error.UnknownBool;
    const count_tok = it.next();
    if (count_tok) |ct| {
        const c = std.fmt.parseUnsigned(u32, ct, 10) catch return error.InvalidNumber;
        try expectExhausted(&it);
        return .{ .enabled = enabled, .count = c };
    }
    try expectExhausted(&it);
    return .{ .enabled = enabled, .count = null };
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
    const tok = it.next() orelse return error.Empty;
    const c = try parseHexColorToken(tok);
    try expectExhausted(&it);
    return c;
}

/// `parseHexColor` の単一トークン版（`parseStroke` の `color=` 値と共有）。
fn parseHexColorToken(tok_in: []const u8) ParseError!u32 {
    var tok = tok_in;
    if (tok.len > 0 and tok[0] == '#') tok = tok[1..];
    if (tok.len != 6) return error.InvalidNumber;
    const rgb = std.fmt.parseUnsigned(u32, tok, 16) catch return error.InvalidNumber;
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

// ── stroke の k=v 拡張（TASK-62.5.3 §5c'）─────────────────────────────
//
// 文法: `stroke [tool=pen|eraser|brush] [color=RRGGBB] [size=N] [opacity=N] [hardness=N] x0 y0 [x y ...]`
// k=v トークンは座標列の**前**にのみ置ける（0 個以上・順不同）。パラメータ無しは従来文法と
// 後方互換（TASK-64 の既存 replay スクリプト不変）。fail-fast 規約: 重複 key・未知 key・
// 値不正（tool 名 / hex / 数値範囲）はすべてエラー（inject 修飾子の「typo を握りつぶさない」
// 方針と同一）。

/// stroke で latch できるツール（bezier/select 等の独立経路ツールは対象外）。
pub const StrokeTool = enum { pen, eraser, brush };

/// brush size の上限（`paint.Brush.MAX_SIZE` と同値。actions.zig は std のみのため独立定義し、
/// 乖離は main.zig の comptime 検査で防ぐ）。
pub const MAX_BRUSH_SIZE: u32 = 64;

/// stroke の明示 k=v パラメータ（null = 未指定 → 呼び出し側が現在の App 状態で補完する）。
pub const StrokeParams = struct {
    tool: ?StrokeTool = null,
    color: ?u32 = null, // canonical 0xFFRRGGBB
    size: ?u32 = null, // 1..MAX_BRUSH_SIZE
    opacity: ?u8 = null, // 0..255
    hardness: ?u8 = null, // 0..255（Brush.hardness_q と同スケール）
};

pub const StrokeArgs = struct { params: StrokeParams, points: []Point };

/// "k=v ... x0 y0 x1 y1 ..." → パラメータ + 点列。点列の制約は `parseStrokePoints` と同じ
/// （偶数個必須・0 個は Empty・`buf.len` 超過は TooManyPoints）。
pub fn parseStroke(args: []const u8, buf: []Point) ParseError!StrokeArgs {
    var it = tokenize(args);
    var params: StrokeParams = .{};

    var pending: ?[]const u8 = null;
    while (it.next()) |tok| {
        if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
            const key = tok[0..eq];
            const val = tok[eq + 1 ..];
            if (std.mem.eql(u8, key, "tool")) {
                if (params.tool != null) return error.DuplicateKey;
                params.tool = std.meta.stringToEnum(StrokeTool, val) orelse return error.UnknownTool;
            } else if (std.mem.eql(u8, key, "color")) {
                if (params.color != null) return error.DuplicateKey;
                params.color = try parseHexColorToken(val);
            } else if (std.mem.eql(u8, key, "size")) {
                if (params.size != null) return error.DuplicateKey;
                const v = std.fmt.parseUnsigned(u32, val, 10) catch return error.InvalidNumber;
                if (v < 1 or v > MAX_BRUSH_SIZE) return error.ValueOutOfRange;
                params.size = v;
            } else if (std.mem.eql(u8, key, "opacity")) {
                if (params.opacity != null) return error.DuplicateKey;
                params.opacity = std.fmt.parseUnsigned(u8, val, 10) catch return error.InvalidNumber;
            } else if (std.mem.eql(u8, key, "hardness")) {
                if (params.hardness != null) return error.DuplicateKey;
                params.hardness = std.fmt.parseUnsigned(u8, val, 10) catch return error.InvalidNumber;
            } else {
                return error.UnknownKey;
            }
        } else {
            pending = tok; // 最初の座標トークン（以降は座標列）
            break;
        }
    }

    var n: usize = 0;
    var x_tok: ?[]const u8 = pending;
    while (x_tok) |xt| {
        const y_tok = it.next() orelse return error.OddPointCount;
        const x = std.fmt.parseInt(i32, xt, 10) catch return error.InvalidNumber;
        const y = std.fmt.parseInt(i32, y_tok, 10) catch return error.InvalidNumber;
        if (n >= buf.len) return error.TooManyPoints;
        buf[n] = .{ .x = x, .y = y };
        n += 1;
        x_tok = it.next();
    }
    if (n == 0) return error.Empty;
    return .{ .params = params, .points = buf[0..n] };
}

/// canonical stroke の実効パラメータ（明示 k=v > 現在の App 状態、の解決済み値）。
pub const EffectiveStroke = struct {
    tool: StrokeTool,
    color: u32, // 0xFFRRGGBB
    size: u32,
    opacity: u8,
    hardness: u8,
};

/// canonical な自己完結 stroke args を生成する（TASK-62.5.3 §5c'。UI 記録と agent 経路が共有）。
/// ツールに意味のある key を**ちょうど一度だけ**含む: pen=tool,color / eraser=tool /
/// brush=tool,color,size,opacity,hardness。`parseStroke` で round-trip 可能（記録された全
/// stroke record が状態非依存に再実行できる）。buf に収まらなければ `error.TooLong`。
pub fn formatCanonicalStroke(buf: []u8, eff: EffectiveStroke, points: []const Point) error{TooLong}![]const u8 {
    var len: usize = 0;
    const head = switch (eff.tool) {
        .pen => std.fmt.bufPrint(buf, "tool=pen color={X:0>6}", .{eff.color & 0xFFFFFF}) catch return error.TooLong,
        .eraser => std.fmt.bufPrint(buf, "tool=eraser", .{}) catch return error.TooLong,
        .brush => std.fmt.bufPrint(buf, "tool=brush color={X:0>6} size={d} opacity={d} hardness={d}", .{
            eff.color & 0xFFFFFF, eff.size, eff.opacity, eff.hardness,
        }) catch return error.TooLong,
    };
    len += head.len;
    for (points) |p| {
        const part = std.fmt.bufPrint(buf[len..], " {d} {d}", .{ p.x, p.y }) catch return error.TooLong;
        len += part.len;
    }
    return buf[0..len];
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

test "parseStroke: パラメータ無しは従来文法と後方互換" {
    var buf: [MAX_STROKE_POINTS]Point = undefined;
    const r = try parseStroke("10 10 50 50", &buf);
    try testing.expectEqual(@as(?StrokeTool, null), r.params.tool);
    try testing.expectEqual(@as(?u32, null), r.params.color);
    try testing.expectEqual(@as(usize, 2), r.points.len);
    try testing.expectEqual(Point{ .x = 50, .y = 50 }, r.points[1]);
}

test "parseStroke: k=v 前置（順不同）+ 座標列" {
    var buf: [MAX_STROKE_POINTS]Point = undefined;
    const r = try parseStroke("color=00FF00 tool=brush size=8 opacity=128 hardness=200 1 2 3 4", &buf);
    try testing.expectEqual(StrokeTool.brush, r.params.tool.?);
    try testing.expectEqual(@as(u32, 0xFF00FF00), r.params.color.?);
    try testing.expectEqual(@as(u32, 8), r.params.size.?);
    try testing.expectEqual(@as(u8, 128), r.params.opacity.?);
    try testing.expectEqual(@as(u8, 200), r.params.hardness.?);
    try testing.expectEqual(@as(usize, 2), r.points.len);
    try testing.expectEqual(Point{ .x = 1, .y = 2 }, r.points[0]);
}

test "parseStroke: fail-fast（重複 key / 未知 key / 不正値 / 範囲外 / 奇数個 / 座標なし）" {
    var buf: [MAX_STROKE_POINTS]Point = undefined;
    try testing.expectError(error.DuplicateKey, parseStroke("tool=pen tool=brush 1 1", &buf));
    try testing.expectError(error.UnknownKey, parseStroke("thickness=3 1 1", &buf));
    try testing.expectError(error.UnknownTool, parseStroke("tool=fill 1 1", &buf));
    try testing.expectError(error.InvalidNumber, parseStroke("color=GGGGGG 1 1", &buf));
    try testing.expectError(error.InvalidNumber, parseStroke("color=FF00 1 1", &buf));
    try testing.expectError(error.ValueOutOfRange, parseStroke("size=0 1 1", &buf));
    try testing.expectError(error.ValueOutOfRange, parseStroke("size=65 1 1", &buf));
    try testing.expectError(error.InvalidNumber, parseStroke("opacity=256 1 1", &buf));
    try testing.expectError(error.InvalidNumber, parseStroke("hardness=999 1 1", &buf));
    try testing.expectError(error.OddPointCount, parseStroke("tool=pen 1 1 2", &buf));
    try testing.expectError(error.Empty, parseStroke("tool=pen", &buf));
    try testing.expectError(error.Empty, parseStroke("", &buf));
    // 座標列開始後の k=v は座標として不正（fail-fast）
    try testing.expectError(error.InvalidNumber, parseStroke("1 1 tool=pen 2", &buf));
}

test "parseStroke: 上限は MAX_STROKE_POINTS 定数を共有（buf.len 超過は TooManyPoints）" {
    var small: [2]Point = undefined;
    try testing.expectError(error.TooManyPoints, parseStroke("tool=pen 1 1 2 2 3 3", &small));
}

test "formatCanonicalStroke: ツール別の key 集合がちょうど一度 + parseStroke round-trip" {
    var out: [512]u8 = undefined;
    const pts = [_]Point{ .{ .x = 1, .y = 2 }, .{ .x = -3, .y = 4 } };

    const pen = try formatCanonicalStroke(&out, .{ .tool = .pen, .color = 0xFFFF0000, .size = 8, .opacity = 255, .hardness = 255 }, &pts);
    try testing.expectEqualStrings("tool=pen color=FF0000 1 2 -3 4", pen);

    var buf: [MAX_STROKE_POINTS]Point = undefined;
    const rt = try parseStroke(pen, &buf);
    try testing.expectEqual(StrokeTool.pen, rt.params.tool.?);
    try testing.expectEqual(@as(u32, 0xFFFF0000), rt.params.color.?);
    try testing.expectEqual(@as(usize, 2), rt.points.len);
    try testing.expectEqual(Point{ .x = -3, .y = 4 }, rt.points[1]);

    var out2: [512]u8 = undefined;
    const eraser = try formatCanonicalStroke(&out2, .{ .tool = .eraser, .color = 0, .size = 1, .opacity = 0, .hardness = 0 }, pts[0..1]);
    try testing.expectEqualStrings("tool=eraser 1 2", eraser);

    var out3: [512]u8 = undefined;
    const brush = try formatCanonicalStroke(&out3, .{ .tool = .brush, .color = 0xFF00FF00, .size = 8, .opacity = 128, .hardness = 200 }, pts[0..1]);
    try testing.expectEqualStrings("tool=brush color=00FF00 size=8 opacity=128 hardness=200 1 2", brush);
    const rt3 = try parseStroke(brush, &buf);
    try testing.expectEqual(@as(u8, 200), rt3.params.hardness.?);

    // 収まらない buf は TooLong
    var tiny: [8]u8 = undefined;
    try testing.expectError(error.TooLong, formatCanonicalStroke(&tiny, .{ .tool = .pen, .color = 0, .size = 1, .opacity = 255, .hardness = 255 }, &pts));
}
