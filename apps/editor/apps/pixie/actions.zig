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
    UnknownShape,
    UnknownSymmetry,
    UnknownAnchor,
    UnknownPanel,
};

/// layer 参照（TASK-94 Phase B）: `#<id>`（安定 handle）または bare 数値（index・後方互換）。
pub const LayerRef = union(enum) {
    id: u64,
    index: usize,
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

/// 単一トークンの layer 参照: `#<id>` → `.id` / bare 数値 → `.index`（TASK-94 Phase B）。
pub fn parseLayerRefToken(tok: []const u8) ParseError!LayerRef {
    if (tok.len == 0) return error.Empty;
    if (tok[0] == '#') {
        if (tok.len < 2) return error.InvalidNumber;
        const id = std.fmt.parseUnsigned(u64, tok[1..], 10) catch return error.InvalidNumber;
        return .{ .id = id };
    }
    const idx = std.fmt.parseUnsigned(usize, tok, 10) catch return error.InvalidNumber;
    return .{ .index = idx };
}

/// "`#<id>` | `<idx>`" の1トークン（select_layer / delete_layer / duplicate_layer / merge_down）。
pub fn parseLayerRef(args: []const u8) ParseError!LayerRef {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const ref = try parseLayerRefToken(tok);
    try expectExhausted(&it);
    return ref;
}

pub const LayerRefBool = struct { ref: LayerRef, on: bool };

/// "`#<id>`|`<idx>` <0|1>"（set_layer_visible）。
pub fn parseLayerRefBool(args: []const u8) ParseError!LayerRefBool {
    var it = tokenize(args);
    const ref_tok = it.next() orelse return error.Empty;
    const ref = try parseLayerRefToken(ref_tok);
    const b_tok = it.next() orelse return error.Empty;
    const on = if (std.mem.eql(u8, b_tok, "0"))
        false
    else if (std.mem.eql(u8, b_tok, "1"))
        true
    else
        return error.UnknownBool;
    try expectExhausted(&it);
    return .{ .ref = ref, .on = on };
}

pub const LayerRefU8 = struct { ref: LayerRef, value: u8 };

/// "`#<id>`|`<idx>` <0-255>"（set_layer_opacity）。
pub fn parseLayerRefU8(args: []const u8) ParseError!LayerRefU8 {
    var it = tokenize(args);
    const ref_tok = it.next() orelse return error.Empty;
    const ref = try parseLayerRefToken(ref_tok);
    const v_tok = it.next() orelse return error.Empty;
    const value = std.fmt.parseUnsigned(u8, v_tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return .{ .ref = ref, .value = value };
}

pub const LayerRefDelta = struct { ref: LayerRef, delta: i32 };

/// "`#<id>`|`<idx>` <+1|-1>"（move_layer の canonical / 二形式）。
pub fn parseLayerRefDelta(args: []const u8) ParseError!LayerRefDelta {
    var it = tokenize(args);
    const ref_tok = it.next() orelse return error.Empty;
    const ref = try parseLayerRefToken(ref_tok);
    const d_tok = it.next() orelse return error.Empty;
    const delta = std.fmt.parseInt(i32, d_tok, 10) catch return error.InvalidNumber;
    if (delta != 1 and delta != -1) return error.InvalidDelta;
    try expectExhausted(&it);
    return .{ .ref = ref, .delta = delta };
}

/// `#<id>` を buf に書く（canonicalize / UI helper 用）。
pub fn formatLayerId(buf: []u8, id: u64) error{TooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "#{d}", .{id}) catch return error.TooLong;
}

/// `#<id> <0|1>`。
pub fn formatLayerIdBool(buf: []u8, id: u64, on: bool) error{TooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "#{d} {d}", .{ id, @as(u8, if (on) 1 else 0) }) catch return error.TooLong;
}

/// `#<id> <0-255>`。
pub fn formatLayerIdU8(buf: []u8, id: u64, value: u8) error{TooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "#{d} {d}", .{ id, value }) catch return error.TooLong;
}

/// `#<id> <+1|-1>`。
pub fn formatLayerIdDelta(buf: []u8, id: u64, delta: i32) error{TooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "#{d} {d}", .{ id, delta }) catch return error.TooLong;
}

/// netsync 中の .relay layer op は `#<id>` 必須（bare index / 暗黙 selected は誤ターゲット）。
/// solo では false（従来どおり index 許容）。純関数なので単体テスト可能。
pub fn layerRefRejectDuringNetsync(ref: LayerRef, netsync_active: bool) bool {
    return netsync_active and ref == .index;
}

/// canonicalize が暗黙 selected / bare index を #id に補完・変換してよいか。
/// netsync 中は禁止（peer ごとに selected が違うと diverge。TASK-94 Phase B P1）。
pub fn allowLayerCanonFill(netsync_active: bool) bool {
    return !netsync_active;
}

/// netsync 中の UI paint 確定の分岐（TASK-94 Phase C review）。
/// - solo: netsync 無効 → pushPaintOp + recordUiStroke
/// - relay: netsync + pen/eraser/brush → rewind → routeAction("stroke")
/// - rewind_discard: netsync + fill 等（action 語彙なし）→ rewind して破棄（silent diverge 防止）
pub const UiPaintCommitPath = enum { solo, relay, rewind_discard };

pub fn uiPaintCommitPath(netsync_active: bool, relays_via_action: bool) UiPaintCommitPath {
    if (!netsync_active) return .solo;
    if (relays_via_action) return .relay;
    return .rewind_discard;
}

pub const Point = struct { x: i32, y: i32 };

/// stroke action の点列上限（呼び出し側がこのサイズの固定長スタックバッファを用意する）。
pub const MAX_STROKE_POINTS: usize = 256;

/// netsync relay 用 wire 点列の 1 chunk 上限（TASK-162）。
/// `MAX_STROKE_POINTS` より小さく、worst-case 座標でも `MAX_CMD_ARGS`/action frame（4096B）に収まるよう
/// 128 を採る（brush head + `segment=continuation` + i32 最悪座標 × N + commit framing）。
/// 下の comptime は std のみのため 4096 リテラルで自己検査。実定数との drift guard は
/// `apps/editor/apps/pixie/main.zig` が `platform.command.MAX_CMD_ARGS` に対して持つ。
pub const RELAY_STROKE_CHUNK_POINTS: usize = 128;

comptime {
    // commit framing: 12B header + "stroke " + args。propose は 4B+name でより緩い。
    const commit_framing = 12 + "stroke ".len;
    const worst_head =
        "layer=#18446744073709551615 tool=brush color=FFFFFF size=64 opacity=255 hardness=255 segment=continuation".len;
    const worst_point = " -2147483648 -2147483648".len;
    const worst_args = worst_head + RELAY_STROKE_CHUNK_POINTS * worst_point;
    if (commit_framing + worst_args > 4096) {
        @compileError("RELAY_STROKE_CHUNK_POINTS is too large for MAX_ACTION_FRAME_BYTES");
    }
    if (worst_args > 4096) {
        @compileError("RELAY_STROKE_CHUNK_POINTS is too large for MAX_CMD_ARGS");
    }
    if (RELAY_STROKE_CHUNK_POINTS > MAX_STROKE_POINTS) {
        @compileError("RELAY_STROKE_CHUNK_POINTS must fit parseStroke's MAX_STROKE_POINTS buffer");
    }
}

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
// 文法: `stroke [layer=#id] [tool=pen|eraser|brush] [color=RRGGBB] [size=N] [opacity=N] [hardness=N] x0 y0 [x y ...]`
// k=v トークンは座標列の**前**にのみ置ける（0 個以上・順不同）。パラメータ無しは従来文法と
// 後方互換（TASK-64 の既存 replay スクリプト不変）。fail-fast 規約: 重複 key・未知 key・
// 値不正（tool 名 / hex / 数値範囲）はすべてエラー（inject 修飾子の「typo を握りつぶさない」
// 方針と同一）。

/// stroke で latch できるツール（bezier/select 等の独立経路ツールは対象外）。
pub const StrokeTool = enum { pen, eraser, brush };

/// relay chunk の境界メタ（TASK-162）。省略時 / `first` = 通常 stroke（始点 stamp）。
/// `continuation` = 前 chunk 終点の carry から始まり、始点は stamp しない。
pub const StrokeSegment = enum { first, continuation };

/// brush size の上限（`paint.Brush.MAX_SIZE` と同値。actions.zig は std のみのため独立定義し、
/// 乖離は main.zig の comptime 検査で防ぐ）。
pub const MAX_BRUSH_SIZE: u32 = 64;

/// stroke の明示 k=v パラメータ（null = 未指定 → 呼び出し側が現在の App 状態で補完する）。
pub const StrokeParams = struct {
    layer: ?LayerRef = null,
    tool: ?StrokeTool = null,
    color: ?u32 = null, // canonical 0xFFRRGGBB
    size: ?u32 = null, // 1..MAX_BRUSH_SIZE
    opacity: ?u8 = null, // 0..255
    hardness: ?u8 = null, // 0..255（Brush.hardness_q と同スケール）
    segment: ?StrokeSegment = null, // null/first = 通常。continuation = no-stamp 始点
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
            if (std.mem.eql(u8, key, "layer")) {
                if (params.layer != null) return error.DuplicateKey;
                params.layer = try parseLayerRefToken(val);
            } else if (std.mem.eql(u8, key, "tool")) {
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
            } else if (std.mem.eql(u8, key, "segment")) {
                if (params.segment != null) return error.DuplicateKey;
                params.segment = std.meta.stringToEnum(StrokeSegment, val) orelse return error.UnknownKey;
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
    layer_id: u64,
    tool: StrokeTool,
    color: u32, // 0xFFRRGGBB
    size: u32,
    opacity: u8,
    hardness: u8,
    /// TASK-162: `first` は wire に出さない（後方互換）。`continuation` のみ明示する。
    segment: StrokeSegment = .first,
};

/// canonical な自己完結 stroke args を生成する（TASK-62.5.3 §5c'。UI 記録と agent 経路が共有）。
/// ツールに意味のある key を**ちょうど一度だけ**含む: pen=tool,color / eraser=tool /
/// brush=tool,color,size,opacity,hardness。`parseStroke` で round-trip 可能（記録された全
/// stroke record が状態非依存に再実行できる）。buf に収まらなければ `error.TooLong`。
/// TASK-162: `segment=continuation` は continuation chunk のみ追記（`first`/省略は従来と同じ）。
pub fn formatCanonicalStroke(buf: []u8, eff: EffectiveStroke, points: []const Point) error{TooLong}![]const u8 {
    var len: usize = 0;
    const head = switch (eff.tool) {
        .pen => std.fmt.bufPrint(buf, "layer=#{d} tool=pen color={X:0>6}", .{ eff.layer_id, eff.color & 0xFFFFFF }) catch return error.TooLong,
        .eraser => std.fmt.bufPrint(buf, "layer=#{d} tool=eraser", .{eff.layer_id}) catch return error.TooLong,
        .brush => std.fmt.bufPrint(buf, "layer=#{d} tool=brush color={X:0>6} size={d} opacity={d} hardness={d}", .{
            eff.layer_id, eff.color & 0xFFFFFF, eff.size, eff.opacity, eff.hardness,
        }) catch return error.TooLong,
    };
    len += head.len;
    if (eff.segment == .continuation) {
        const seg = std.fmt.bufPrint(buf[len..], " segment=continuation", .{}) catch return error.TooLong;
        len += seg.len;
    }
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

// ── TASK-89: palette / replace_color パーサ ────────────────────────────

pub const ReplaceColorArgs = struct {
    /// 省略時は handler が selected layer を使う（netsync 中は #id 必須で reject）。
    layer: ?LayerRef = null,
    from: u32,
    to: u32,
};

/// 先頭トークンが layer ref か（`#`+十進 = id / 十進のみ = index）。
/// `#RRGGBB`（hex 色）は十進以外を含むので false → 色トークンとして扱う。
fn looksLikeLayerRefToken(tok: []const u8) bool {
    if (tok.len == 0) return false;
    if (tok[0] == '#') {
        if (tok.len < 2) return true; // パース時に InvalidNumber
        for (tok[1..]) |c| {
            if (c < '0' or c > '9') return false;
        }
        return true;
    }
    for (tok) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// `replace_color [#<id>|<index>] <from> <to>`（layer ref は optional・省略時 selected）。
/// hex 2 個のみは従来互換。先頭が `#`+十進 or 数値のみなら layer ref と解釈する。
pub fn parseReplaceColor(args: []const u8) ParseError!ReplaceColorArgs {
    var it = tokenize(args);
    const t1 = it.next() orelse return error.Empty;
    const t2 = it.next() orelse return error.Empty;
    if (it.next()) |t3| {
        // 3 トークン: layer ref + from + to
        if (!looksLikeLayerRefToken(t1)) return error.TooManyTokens;
        const ref = try parseLayerRefToken(t1);
        const from = try parseHexColorToken(t2);
        const to = try parseHexColorToken(t3);
        try expectExhausted(&it);
        return .{ .layer = ref, .from = from, .to = to };
    }
    // 2 トークン: from + to（従来互換）
    const from = try parseHexColorToken(t1);
    const to = try parseHexColorToken(t2);
    return .{ .layer = null, .from = from, .to = to };
}

pub const PaletteRampArgs = struct { seed: u32, n: u8 };

/// `palette_ramp <seed_hex> <n>`（n は 2..=32）。
pub fn parsePaletteRamp(args: []const u8) ParseError!PaletteRampArgs {
    var it = tokenize(args);
    const seed_tok = it.next() orelse return error.Empty;
    const n_tok = it.next() orelse return error.Empty;
    const seed = try parseHexColorToken(seed_tok);
    const n_u = std.fmt.parseUnsigned(u8, n_tok, 10) catch return error.InvalidNumber;
    if (n_u < 2 or n_u > 32) return error.ValueOutOfRange;
    try expectExhausted(&it);
    return .{ .seed = seed, .n = n_u };
}

/// palette_set の色数上限（palette.zig MAX_PALETTE_COLORS と同値。乖離は main の comptime で防ぐ）。
pub const MAX_PALETTE_SET: usize = 64;

// ── TASK-90: shape / symmetry / pixel_perfect ────────────────────────

pub const ShapeKind = enum { line, rect, ellipse };

/// 対称モード（StrokeRecorder.Symmetry と同語彙。v/h は短縮形）。
pub const SymmetryMode = enum { off, v, h, quad };

pub const ShapeArgs = struct {
    kind: ShapeKind,
    p0: Point,
    p1: Point,
    fill: bool = false,
};

/// アンカー名 → canvas 座標（App 非依存。w/h は呼び出し側が渡す）。
/// center / top-left / top-right / bottom-left / bottom-right /
/// mid-top / mid-bottom / mid-left / mid-right。
pub fn resolveAnchor(name: []const u8, w: i32, h: i32) ParseError!Point {
    if (w < 1 or h < 1) return error.ValueOutOfRange;
    const r = w - 1;
    const b = h - 1;
    const mx = @divTrunc(w, 2);
    const my = @divTrunc(h, 2);
    if (std.mem.eql(u8, name, "center")) return .{ .x = mx, .y = my };
    if (std.mem.eql(u8, name, "top-left")) return .{ .x = 0, .y = 0 };
    if (std.mem.eql(u8, name, "top-right")) return .{ .x = r, .y = 0 };
    if (std.mem.eql(u8, name, "bottom-left")) return .{ .x = 0, .y = b };
    if (std.mem.eql(u8, name, "bottom-right")) return .{ .x = r, .y = b };
    if (std.mem.eql(u8, name, "mid-top")) return .{ .x = mx, .y = 0 };
    if (std.mem.eql(u8, name, "mid-bottom")) return .{ .x = mx, .y = b };
    if (std.mem.eql(u8, name, "mid-left")) return .{ .x = 0, .y = my };
    if (std.mem.eql(u8, name, "mid-right")) return .{ .x = r, .y = my };
    return error.UnknownAnchor;
}

/// `x,y` 座標トークン or アンカー名。
/// 数値経路は canvas 内 `0 <= x < w` / `0 <= y < h` を必須（範囲外・負値は ValueOutOfRange）。
/// アンカー経路は定義上範囲内なので追加検証なし。
fn parsePointToken(tok: []const u8, w: i32, h: i32) ParseError!Point {
    if (std.mem.indexOfScalar(u8, tok, ',')) |comma| {
        const xs = tok[0..comma];
        const ys = tok[comma + 1 ..];
        if (xs.len == 0 or ys.len == 0) return error.InvalidNumber;
        const x = std.fmt.parseInt(i32, xs, 10) catch return error.InvalidNumber;
        const y = std.fmt.parseInt(i32, ys, 10) catch return error.InvalidNumber;
        if (x < 0 or y < 0 or x >= w or y >= h) return error.ValueOutOfRange;
        return .{ .x = x, .y = y };
    }
    return resolveAnchor(tok, w, h);
}

/// `shape <line|rect|ellipse> <p0> <p1> [fill]`
/// p は `x,y` またはアンカー名。fill は rect/ellipse のみ意味を持つ（line でも許容）。
pub fn parseShape(args: []const u8, canvas_w: i32, canvas_h: i32) ParseError!ShapeArgs {
    var it = tokenize(args);
    const kind_tok = it.next() orelse return error.Empty;
    const kind = std.meta.stringToEnum(ShapeKind, kind_tok) orelse return error.UnknownShape;
    const p0_tok = it.next() orelse return error.Empty;
    const p1_tok = it.next() orelse return error.Empty;
    const p0 = try parsePointToken(p0_tok, canvas_w, canvas_h);
    const p1 = try parsePointToken(p1_tok, canvas_w, canvas_h);
    var fill = false;
    if (it.next()) |fill_tok| {
        if (!std.ascii.eqlIgnoreCase(fill_tok, "fill")) return error.TooManyTokens;
        fill = true;
        try expectExhausted(&it);
    }
    return .{ .kind = kind, .p0 = p0, .p1 = p1, .fill = fill };
}

/// キャンバスサイズ（resize / new W H）。上限は呼び出し側の共通 validator が適用する。
pub const CanvasSize = struct { w: u32, h: u32 };

/// キャンバスサイズ上限（各辺 ≤4096・総画素 ≤16M）。action / .pix / netsync / GUI で共有（TASK-144.1）。
pub const MAX_CANVAS_EDGE: u32 = 4096;
pub const MAX_CANVAS_PIXELS: usize = 16 * 1024 * 1024;

/// キャンバスサイズ上限検証（各辺 ≤4096・総画素 ≤16M）。0 / 乗算 overflow / 上限超過を拒否。
pub fn validateCanvasSize(w: u32, h: u32) error{ InvalidSize, SizeOverflow, CanvasTooLarge }!void {
    if (w == 0 or h == 0) return error.InvalidSize;
    if (w > MAX_CANVAS_EDGE or h > MAX_CANVAS_EDGE) return error.CanvasTooLarge;
    const n = std.math.mul(usize, w, h) catch return error.SizeOverflow;
    if (n > MAX_CANVAS_PIXELS) return error.CanvasTooLarge;
}

/// `resize W H` 相当: 引数厳密 2・符号なし整数。0 は ValueOutOfRange。
pub fn parseCanvasSize(args: []const u8) ParseError!CanvasSize {
    var it = tokenize(args);
    const w_tok = it.next() orelse return error.Empty;
    const h_tok = it.next() orelse return error.Empty;
    const w = std.fmt.parseUnsigned(u32, w_tok, 10) catch return error.InvalidNumber;
    const h = std.fmt.parseUnsigned(u32, h_tok, 10) catch return error.InvalidNumber;
    if (w == 0 or h == 0) return error.ValueOutOfRange;
    try expectExhausted(&it);
    return .{ .w = w, .h = h };
}

/// `new` / `new W H`。0 引数 = 現サイズ blank reset（後方互換）。2 引数 = 指定サイズ新規。
pub const NewArgs = union(enum) {
    reset_current,
    sized: CanvasSize,
};

pub fn parseNew(args: []const u8) ParseError!NewArgs {
    var it = tokenize(args);
    const w_tok = it.next() orelse return .reset_current;
    const h_tok = it.next() orelse return error.Empty;
    const w = std.fmt.parseUnsigned(u32, w_tok, 10) catch return error.InvalidNumber;
    const h = std.fmt.parseUnsigned(u32, h_tok, 10) catch return error.InvalidNumber;
    if (w == 0 or h == 0) return error.ValueOutOfRange;
    try expectExhausted(&it);
    return .{ .sized = .{ .w = w, .h = h } };
}

/// `set_symmetry <off|v|h|quad>`
pub fn parseSymmetry(args: []const u8) ParseError!SymmetryMode {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const mode = std.meta.stringToEnum(SymmetryMode, tok) orelse return error.UnknownSymmetry;
    try expectExhausted(&it);
    return mode;
}

/// `set_pixel_perfect <0|1>`
pub fn parsePixelPerfect(args: []const u8) ParseError!bool {
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

/// canonical shape args（UI 記録 / redo 用）。
pub fn formatCanonicalShape(buf: []u8, a: ShapeArgs) error{TooLong}![]const u8 {
    if (a.fill) {
        return std.fmt.bufPrint(buf, "{s} {d},{d} {d},{d} fill", .{
            @tagName(a.kind), a.p0.x, a.p0.y, a.p1.x, a.p1.y,
        }) catch return error.TooLong;
    }
    return std.fmt.bufPrint(buf, "{s} {d},{d} {d},{d}", .{
        @tagName(a.kind), a.p0.x, a.p0.y, a.p1.x, a.p1.y,
    }) catch return error.TooLong;
}

/// `palette_set <hex...>`（1..=64 個・# 任意）→ `buf` に詰めて borrowed slice。
pub fn parsePaletteSet(args: []const u8, buf: []u32) ParseError![]u32 {
    var it = tokenize(args);
    var n: usize = 0;
    while (it.next()) |tok| {
        if (n >= buf.len) return error.TooManyTokens;
        if (n >= MAX_PALETTE_SET) return error.TooManyTokens;
        buf[n] = try parseHexColorToken(tok);
        n += 1;
    }
    if (n == 0) return error.Empty;
    return buf[0..n];
}

/// 引数を取らない action（undo/redo/clear/add_layer/delete_layer）用: trim 後に空であることを
/// 確認する（余剰トークンは `error.TooManyTokens`。typo を握りつぶさない）。
pub fn parseNoArgs(args: []const u8) ParseError!void {
    if (std.mem.trim(u8, args, " \t").len != 0) return error.TooManyTokens;
}

/// `panel_toggle` の対象パネル名（harness action 用。PanelHost の安定 name とは別の短い ID）。
pub const PanelToggleName = enum {
    history,
    color,
    palette,
    tool_options,
    layers,
    timeline,
};

/// `panel_toggle <name>` 用: 1 トークン。未知名・空・余剰はエラー。
pub fn parsePanelToggle(args: []const u8) ParseError!PanelToggleName {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const name = std.meta.stringToEnum(PanelToggleName, tok) orelse return error.UnknownPanel;
    try expectExhausted(&it);
    return name;
}

/// `goto_frame <idx>` 用: frame index の1トークン（u32）。
pub fn parseGotoFrame(args: []const u8) ParseError!u32 {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const v = std.fmt.parseUnsigned(u32, tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return v;
}

/// `export_seq <stem>` 用: 連番 PNG の stem（path トークン1個・空白 trim のみ）。
pub fn parseExportSeq(args: []const u8) ParseError![]const u8 {
    return parsePath(args);
}

pub const ExportSheetArgs = struct {
    path: []const u8,
    columns: u32 = 0,
    margin: u32 = 0,
};

/// `export_sheet <path> [columns] [margin]` 用。
pub fn parseExportSheet(args: []const u8) ParseError!ExportSheetArgs {
    var it = tokenize(args);
    const path_tok = it.next() orelse return error.Empty;
    var result: ExportSheetArgs = .{ .path = path_tok };
    if (it.next()) |col_tok| {
        result.columns = std.fmt.parseUnsigned(u32, col_tok, 10) catch return error.InvalidNumber;
        if (it.next()) |mar_tok| {
            result.margin = std.fmt.parseUnsigned(u32, mar_tok, 10) catch return error.InvalidNumber;
        }
        try expectExhausted(&it);
    }
    return result;
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

test "parseLayerRef: #<id> と bare index の二形式 / 不正トークン" {
    try testing.expectEqual(LayerRef{ .id = 1 }, try parseLayerRef("#1"));
    try testing.expectEqual(LayerRef{ .id = 42 }, try parseLayerRef("  #42  "));
    try testing.expectEqual(LayerRef{ .index = 0 }, try parseLayerRef("0"));
    try testing.expectEqual(LayerRef{ .index = 3 }, try parseLayerRef("3"));
    try testing.expectError(error.Empty, parseLayerRef(""));
    try testing.expectError(error.InvalidNumber, parseLayerRef("#"));
    try testing.expectError(error.InvalidNumber, parseLayerRef("#abc"));
    try testing.expectError(error.InvalidNumber, parseLayerRef("abc"));
    try testing.expectError(error.TooManyTokens, parseLayerRef("#1 2"));
}

test "parseLayerRefBool / parseLayerRefU8 / parseLayerRefDelta" {
    const vb = try parseLayerRefBool("#2 1");
    try testing.expectEqual(LayerRef{ .id = 2 }, vb.ref);
    try testing.expect(vb.on);
    const ib = try parseLayerRefBool("0 0");
    try testing.expectEqual(LayerRef{ .index = 0 }, ib.ref);
    try testing.expect(!ib.on);
    try testing.expectError(error.UnknownBool, parseLayerRefBool("#1 true"));

    const vu = try parseLayerRefU8("#3 128");
    try testing.expectEqual(LayerRef{ .id = 3 }, vu.ref);
    try testing.expectEqual(@as(u8, 128), vu.value);
    try testing.expectError(error.InvalidNumber, parseLayerRefU8("1 999"));

    const vd = try parseLayerRefDelta("#4 -1");
    try testing.expectEqual(LayerRef{ .id = 4 }, vd.ref);
    try testing.expectEqual(@as(i32, -1), vd.delta);
    const id = try parseLayerRefDelta("1 1");
    try testing.expectEqual(LayerRef{ .index = 1 }, id.ref);
    try testing.expectEqual(@as(i32, 1), id.delta);
    try testing.expectError(error.InvalidDelta, parseLayerRefDelta("#1 2"));
    try testing.expectError(error.Empty, parseLayerRefDelta("#1"));
}

test "formatLayerId*: round-trip with parsers" {
    var buf: [64]u8 = undefined;
    const a = try formatLayerId(&buf, 7);
    try testing.expectEqualStrings("#7", a);
    try testing.expectEqual(LayerRef{ .id = 7 }, try parseLayerRef(a));

    const b = try formatLayerIdBool(&buf, 2, true);
    try testing.expectEqualStrings("#2 1", b);
    const pb = try parseLayerRefBool(b);
    try testing.expectEqual(LayerRef{ .id = 2 }, pb.ref);
    try testing.expect(pb.on);

    const c = try formatLayerIdU8(&buf, 3, 128);
    try testing.expectEqualStrings("#3 128", c);
    const d = try formatLayerIdDelta(&buf, 1, -1);
    try testing.expectEqualStrings("#1 -1", d);
}

test "layerRefRejectDuringNetsync: netsync 中は bare index のみ拒否 / id は許容 / solo は両方許容" {
    try testing.expect(!layerRefRejectDuringNetsync(.{ .id = 1 }, false));
    try testing.expect(!layerRefRejectDuringNetsync(.{ .index = 0 }, false));
    try testing.expect(!layerRefRejectDuringNetsync(.{ .id = 1 }, true));
    try testing.expect(layerRefRejectDuringNetsync(.{ .index = 0 }, true));
    try testing.expect(layerRefRejectDuringNetsync(.{ .index = 3 }, true));
}

test "allowLayerCanonFill: netsync 中は暗黙 selected / index→id 補完禁止" {
    try testing.expect(allowLayerCanonFill(false)); // solo: 補完可
    try testing.expect(!allowLayerCanonFill(true)); // netsync: 補完禁止
}

test "uiPaintCommitPath: solo / relay / rewind_discard の 3 分岐" {
    try testing.expectEqual(UiPaintCommitPath.solo, uiPaintCommitPath(false, false));
    try testing.expectEqual(UiPaintCommitPath.solo, uiPaintCommitPath(false, true));
    try testing.expectEqual(UiPaintCommitPath.relay, uiPaintCommitPath(true, true));
    try testing.expectEqual(UiPaintCommitPath.rewind_discard, uiPaintCommitPath(true, false));
}

/// digest 末尾の trunc マーカー（canvasDigest と共有。`" trunc=1"` = 8 bytes）。
pub const DIGEST_TRUNC_MARKER = " trunc=1";

/// `truncated=false` なら `buf[0..written]` をそのまま返す（bit 一致）。
/// `truncated=true` なら末尾に ` trunc=1` を書き、必要なら written を削って領域を確保する。
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

/// テスト用: 空白区切りエントリを buf に詰め、入り切らなければ trunc=1。
pub fn packDigestEntries(buf: []u8, prefix: []const u8, entries: []const []const u8) []const u8 {
    var len: usize = 0;
    if (prefix.len > 0) {
        if (prefix.len > buf.len) return finishDigestWithTrunc(buf, 0, true);
        @memcpy(buf[0..prefix.len], prefix);
        len = prefix.len;
    }
    var truncated = false;
    for (entries) |e| {
        const part = std.fmt.bufPrint(buf[len..], " {s}", .{e}) catch {
            truncated = true;
            break;
        };
        len += part.len;
    }
    return finishDigestWithTrunc(buf, len, truncated);
}

test "finishDigestWithTrunc: 非 trunc は bit 一致 / trunc 時は末尾に trunc=1" {
    var buf: [64]u8 = undefined;
    const base = "32x32 layers=1 sel=none";
    @memcpy(buf[0..base.len], base);
    try testing.expectEqualStrings(base, finishDigestWithTrunc(&buf, base.len, false));

    var full: [20]u8 = undefined;
    @memset(&full, 'x');
    const out = finishDigestWithTrunc(&full, full.len, true);
    try testing.expect(std.mem.endsWith(u8, out, DIGEST_TRUNC_MARKER));
    try testing.expectEqual(@as(usize, full.len), out.len);
}

test "parseReplaceColor: hex 2 個 / # 任意 / layer ref 省略・付き / 余剰・不足" {
    const a = try parseReplaceColor("FF0000 00FF00");
    try testing.expect(a.layer == null);
    try testing.expectEqual(@as(u32, 0xFFFF0000), a.from);
    try testing.expectEqual(@as(u32, 0xFF00FF00), a.to);
    // #RRGGBB は色（layer id ではない）
    const b = try parseReplaceColor("#aabbcc #112233");
    try testing.expect(b.layer == null);
    try testing.expectEqual(@as(u32, 0xFFAABBCC), b.from);
    try testing.expectEqual(@as(u32, 0xFF112233), b.to);
    // optional layer ref: #<id> / bare index
    const c = try parseReplaceColor("#2 FF0000 00FF00");
    try testing.expectEqual(LayerRef{ .id = 2 }, c.layer.?);
    try testing.expectEqual(@as(u32, 0xFFFF0000), c.from);
    try testing.expectEqual(@as(u32, 0xFF00FF00), c.to);
    const d = try parseReplaceColor("0 aabbcc 112233");
    try testing.expectEqual(LayerRef{ .index = 0 }, d.layer.?);
    try testing.expectEqual(@as(u32, 0xFFAABBCC), d.from);
    try testing.expectError(error.Empty, parseReplaceColor(""));
    try testing.expectError(error.Empty, parseReplaceColor("FF0000"));
    // 3 hex 色（先頭が ref に見えない）→ TooManyTokens
    try testing.expectError(error.TooManyTokens, parseReplaceColor("FF0000 00FF00 0000FF"));
    try testing.expectError(error.InvalidNumber, parseReplaceColor("GGGGGG 00FF00"));
    try testing.expectError(error.TooManyTokens, parseReplaceColor("#1 FF0000 00FF00 extra"));
}

test "parsePaletteRamp: n 2..=32 / 範囲外" {
    const a = try parsePaletteRamp("336699 8");
    try testing.expectEqual(@as(u32, 0xFF336699), a.seed);
    try testing.expectEqual(@as(u8, 8), a.n);
    try testing.expectError(error.ValueOutOfRange, parsePaletteRamp("336699 1"));
    try testing.expectError(error.ValueOutOfRange, parsePaletteRamp("336699 33"));
    try testing.expectError(error.Empty, parsePaletteRamp("336699"));
    try testing.expectError(error.TooManyTokens, parsePaletteRamp("336699 8 extra"));
}

test "parsePaletteSet: 1..=64 hex / 空 / 過多" {
    var buf: [64]u32 = undefined;
    const one = try parsePaletteSet("FF0000", &buf);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(@as(u32, 0xFFFF0000), one[0]);
    const three = try parsePaletteSet("#FF0000 00FF00 0000FF", &buf);
    try testing.expectEqual(@as(usize, 3), three.len);
    try testing.expectError(error.Empty, parsePaletteSet("", &buf));
    // 65 個 → TooManyTokens（"FF0000 " × 65 ≒ 455B）
    var many_buf: [512]u8 = undefined;
    var len: usize = 0;
    var i: usize = 0;
    while (i < 65) : (i += 1) {
        const part = std.fmt.bufPrint(many_buf[len..], "{s}FF0000", .{if (i == 0) "" else " "}) catch unreachable;
        len += part.len;
    }
    try testing.expectError(error.TooManyTokens, parsePaletteSet(many_buf[0..len], &buf));
}

test "packDigestEntries: 少エントリは trunc 無し / 多エントリは trunc=1" {
    var small_buf: [128]u8 = undefined;
    const few = packDigestEntries(&small_buf, "head", &[_][]const u8{ "l0{id=1,name=a}", "l1{id=2,name=b}" });
    try testing.expect(std.mem.startsWith(u8, few, "head "));
    try testing.expect(std.mem.indexOf(u8, few, "trunc=1") == null);

    var tiny: [40]u8 = undefined;
    const long_name = "l0{id=1,v=true,op=255,crc=DEADBEEF,nz=0,name=VeryLongLayerNameForTrunc,kind=raster}";
    const many = packDigestEntries(&tiny, "head", &[_][]const u8{ long_name, long_name, long_name });
    try testing.expect(std.mem.endsWith(u8, many, DIGEST_TRUNC_MARKER));
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

test "parsePanelToggle: 有効名 / 空 / 未知名 / 余剰トークン" {
    try testing.expectEqual(PanelToggleName.history, try parsePanelToggle("history"));
    try testing.expectEqual(PanelToggleName.tool_options, try parsePanelToggle("tool_options"));
    try testing.expectEqual(PanelToggleName.timeline, try parsePanelToggle("  timeline  "));
    try testing.expectError(error.Empty, parsePanelToggle(""));
    try testing.expectError(error.UnknownPanel, parsePanelToggle("inspector"));
    try testing.expectError(error.TooManyTokens, parsePanelToggle("history extra"));
}

test "parseGotoFrame: 有効値 / Empty / InvalidNumber / TooManyTokens" {
    try testing.expectEqual(@as(u32, 0), try parseGotoFrame("0"));
    try testing.expectEqual(@as(u32, 12), try parseGotoFrame("  12  "));
    try testing.expectError(error.Empty, parseGotoFrame(""));
    try testing.expectError(error.Empty, parseGotoFrame("   "));
    try testing.expectError(error.InvalidNumber, parseGotoFrame("abc"));
    try testing.expectError(error.InvalidNumber, parseGotoFrame("-1"));
    try testing.expectError(error.TooManyTokens, parseGotoFrame("1 2"));
}

test "parseExportSeq: parsePath と同型" {
    try testing.expectEqualStrings("/tmp/seq", try parseExportSeq("/tmp/seq"));
    try testing.expectError(error.Empty, parseExportSeq(""));
}

test "parseExportSheet: path のみ / columns+margin / 余剰トークン拒否" {
    const a = try parseExportSheet("/tmp/sheet.png");
    try testing.expectEqualStrings("/tmp/sheet.png", a.path);
    try testing.expectEqual(@as(u32, 0), a.columns);
    try testing.expectEqual(@as(u32, 0), a.margin);

    const b = try parseExportSheet("/tmp/s.png 4 2");
    try testing.expectEqualStrings("/tmp/s.png", b.path);
    try testing.expectEqual(@as(u32, 4), b.columns);
    try testing.expectEqual(@as(u32, 2), b.margin);

    const c = try parseExportSheet("/tmp/s.png 3");
    try testing.expectEqual(@as(u32, 3), c.columns);
    try testing.expectEqual(@as(u32, 0), c.margin);

    try testing.expectError(error.Empty, parseExportSheet(""));
    try testing.expectError(error.InvalidNumber, parseExportSheet("/tmp/s.png abc"));
    try testing.expectError(error.TooManyTokens, parseExportSheet("/tmp/s.png 4 2 1"));
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

    const pen = try formatCanonicalStroke(&out, .{ .layer_id = 7, .tool = .pen, .color = 0xFFFF0000, .size = 8, .opacity = 255, .hardness = 255 }, &pts);
    try testing.expectEqualStrings("layer=#7 tool=pen color=FF0000 1 2 -3 4", pen);

    var buf: [MAX_STROKE_POINTS]Point = undefined;
    const rt = try parseStroke(pen, &buf);
    try testing.expectEqual(StrokeTool.pen, rt.params.tool.?);
    try testing.expectEqual(@as(u32, 0xFFFF0000), rt.params.color.?);
    try testing.expectEqual(LayerRef{ .id = 7 }, rt.params.layer.?);
    try testing.expectEqual(@as(usize, 2), rt.points.len);
    try testing.expectEqual(Point{ .x = -3, .y = 4 }, rt.points[1]);

    var out2: [512]u8 = undefined;
    const eraser = try formatCanonicalStroke(&out2, .{ .layer_id = 7, .tool = .eraser, .color = 0, .size = 1, .opacity = 0, .hardness = 0 }, pts[0..1]);
    try testing.expectEqualStrings("layer=#7 tool=eraser 1 2", eraser);

    var out3: [512]u8 = undefined;
    const brush = try formatCanonicalStroke(&out3, .{ .layer_id = 7, .tool = .brush, .color = 0xFF00FF00, .size = 8, .opacity = 128, .hardness = 200 }, pts[0..1]);
    try testing.expectEqualStrings("layer=#7 tool=brush color=00FF00 size=8 opacity=128 hardness=200 1 2", brush);
    const rt3 = try parseStroke(brush, &buf);
    try testing.expectEqual(@as(u8, 200), rt3.params.hardness.?);

    // 収まらない buf は TooLong
    var tiny: [8]u8 = undefined;
    try testing.expectError(error.TooLong, formatCanonicalStroke(&tiny, .{ .layer_id = 7, .tool = .pen, .color = 0, .size = 1, .opacity = 255, .hardness = 255 }, &pts));
}

test "parseStroke: layer ref は optional で round-trip、legacy は省略を許容" {
    var points: [MAX_STROKE_POINTS]Point = undefined;
    const with_layer = try parseStroke("layer=#42 tool=pen color=112233 1 2", &points);
    try testing.expectEqual(LayerRef{ .id = 42 }, with_layer.params.layer.?);
    const legacy = try parseStroke("1 2", &points);
    try testing.expect(legacy.params.layer == null);
}

test "parseStroke/formatCanonicalStroke: segment=continuation round-trip（省略は first）" {
    var buf: [MAX_STROKE_POINTS]Point = undefined;
    const legacy = try parseStroke("tool=pen color=FF0000 1 2 3 4", &buf);
    try testing.expect(legacy.params.segment == null);

    const cont = try parseStroke("layer=#7 tool=pen color=FF0000 segment=continuation 10 10 20 20", &buf);
    try testing.expectEqual(StrokeSegment.continuation, cont.params.segment.?);
    try testing.expectEqual(@as(usize, 2), cont.points.len);

    try testing.expectError(error.DuplicateKey, parseStroke("segment=first segment=continuation 1 1", &buf));
    try testing.expectError(error.UnknownKey, parseStroke("segment=middle 1 1", &buf));

    var out: [512]u8 = undefined;
    const first_args = try formatCanonicalStroke(&out, .{
        .layer_id = 7,
        .tool = .pen,
        .color = 0xFFFF0000,
        .size = 1,
        .opacity = 255,
        .hardness = 255,
        .segment = .first,
    }, cont.points);
    try testing.expectEqualStrings("layer=#7 tool=pen color=FF0000 10 10 20 20", first_args);

    const cont_args = try formatCanonicalStroke(&out, .{
        .layer_id = 7,
        .tool = .pen,
        .color = 0xFFFF0000,
        .size = 1,
        .opacity = 255,
        .hardness = 255,
        .segment = .continuation,
    }, cont.points);
    try testing.expectEqualStrings("layer=#7 tool=pen color=FF0000 segment=continuation 10 10 20 20", cont_args);
    const rt = try parseStroke(cont_args, &buf);
    try testing.expectEqual(StrokeSegment.continuation, rt.params.segment.?);
}

test "RELAY_STROKE_CHUNK_POINTS: worst-case brush continuation が 4096 内" {
    var pts: [RELAY_STROKE_CHUNK_POINTS]Point = undefined;
    for (&pts, 0..) |*p, i| {
        p.* = .{ .x = std.math.minInt(i32), .y = if (i % 2 == 0) std.math.maxInt(i32) else std.math.minInt(i32) };
    }
    var out: [4096]u8 = undefined;
    const args = try formatCanonicalStroke(&out, .{
        .layer_id = std.math.maxInt(u64),
        .tool = .brush,
        .color = 0xFFFFFFFF,
        .size = MAX_BRUSH_SIZE,
        .opacity = 255,
        .hardness = 255,
        .segment = .continuation,
    }, &pts);
    try testing.expect(args.len <= 4096);
    try testing.expect(args.len + "stroke ".len + 12 <= 4096);
}

// ── TASK-90 パーサ ─────────────────────────────────────────

test "parseShape: 座標 / アンカー / fill / エラー" {
    const a = try parseShape("rect 4,4 20,14", 256, 256);
    try testing.expectEqual(ShapeKind.rect, a.kind);
    try testing.expectEqual(Point{ .x = 4, .y = 4 }, a.p0);
    try testing.expectEqual(Point{ .x = 20, .y = 14 }, a.p1);
    try testing.expect(!a.fill);

    const b = try parseShape("ellipse top-left bottom-right fill", 256, 256);
    try testing.expectEqual(ShapeKind.ellipse, b.kind);
    try testing.expectEqual(Point{ .x = 0, .y = 0 }, b.p0);
    try testing.expectEqual(Point{ .x = 255, .y = 255 }, b.p1);
    try testing.expect(b.fill);

    const c = try parseShape("line center mid-right", 10, 10);
    try testing.expectEqual(ShapeKind.line, c.kind);
    try testing.expectEqual(Point{ .x = 5, .y = 5 }, c.p0);
    try testing.expectEqual(Point{ .x = 9, .y = 5 }, c.p1);

    try testing.expectError(error.UnknownShape, parseShape("circle 0,0 1,1", 16, 16));
    try testing.expectError(error.UnknownAnchor, parseShape("line nowhere mid-top", 16, 16));
    try testing.expectError(error.Empty, parseShape("line 0,0", 16, 16));
    try testing.expectError(error.TooManyTokens, parseShape("rect 0,0 1,1 fill extra", 16, 16));

    // 数値座標の範囲検証（0 <= x < w, 0 <= y < h）。アンカーは定義上範囲内で不変。
    try testing.expectError(error.ValueOutOfRange, parseShape("line -1,0 1,1", 16, 16));
    try testing.expectError(error.ValueOutOfRange, parseShape("line 0,-1 1,1", 16, 16));
    try testing.expectError(error.ValueOutOfRange, parseShape("line 0,0 16,1", 16, 16)); // x == w
    try testing.expectError(error.ValueOutOfRange, parseShape("line 0,0 1,16", 16, 16)); // y == h
    try testing.expectError(error.ValueOutOfRange, parseShape("line 0,0 999,999", 16, 16));
    try testing.expectError(error.ValueOutOfRange, parseShape("rect 0,0 2147483647,0", 256, 256));
    // 端点 inclusive（w-1,h-1）は受理
    const edge = try parseShape("line 0,0 15,15", 16, 16);
    try testing.expectEqual(Point{ .x = 15, .y = 15 }, edge.p1);
}

test "parseCanvasSize / parseNew: 受理と拒否（TASK-144.1）" {
    const sz = try parseCanvasSize("32 16");
    try testing.expectEqual(@as(u32, 32), sz.w);
    try testing.expectEqual(@as(u32, 16), sz.h);

    try testing.expectError(error.Empty, parseCanvasSize(""));
    try testing.expectError(error.Empty, parseCanvasSize("32"));
    try testing.expectError(error.TooManyTokens, parseCanvasSize("32 16 extra"));
    try testing.expectError(error.ValueOutOfRange, parseCanvasSize("0 16"));
    try testing.expectError(error.ValueOutOfRange, parseCanvasSize("16 0"));
    try testing.expectError(error.InvalidNumber, parseCanvasSize("-1 16"));
    try testing.expectError(error.InvalidNumber, parseCanvasSize("abc 16"));
    try testing.expectError(error.InvalidNumber, parseCanvasSize("32 xyz"));
    try testing.expectError(error.InvalidNumber, parseCanvasSize("4294967296 16"));

    const n0 = try parseNew("");
    try testing.expect(n0 == .reset_current);
    const n0w = try parseNew("   ");
    try testing.expect(n0w == .reset_current);

    const n2 = try parseNew("32 16");
    try testing.expect(n2 == .sized);
    try testing.expectEqual(@as(u32, 32), n2.sized.w);
    try testing.expectEqual(@as(u32, 16), n2.sized.h);

    try testing.expectError(error.Empty, parseNew("32"));
    try testing.expectError(error.TooManyTokens, parseNew("32 16 extra"));
    try testing.expectError(error.ValueOutOfRange, parseNew("0 16"));
    try testing.expectError(error.ValueOutOfRange, parseNew("16 0"));
    try testing.expectError(error.InvalidNumber, parseNew("-1 16"));
    try testing.expectError(error.InvalidNumber, parseNew("nope 16"));
}

test "validateCanvasSize: 境界（TASK-144.2）" {
    // (a) 最小
    try validateCanvasSize(1, 1);
    // (b) 辺上限ちょうど（4096×4096 = 16M 総画素ちょうど）
    try validateCanvasSize(MAX_CANVAS_EDGE, MAX_CANVAS_EDGE);
    try testing.expectEqual(@as(usize, MAX_CANVAS_PIXELS), @as(usize, MAX_CANVAS_EDGE) * @as(usize, MAX_CANVAS_EDGE));
    // (c) 辺上限超過
    try testing.expectError(error.CanvasTooLarge, validateCanvasSize(MAX_CANVAS_EDGE + 1, 1));
    try testing.expectError(error.CanvasTooLarge, validateCanvasSize(1, MAX_CANVAS_EDGE + 1));
    // (d) 0
    try testing.expectError(error.InvalidSize, validateCanvasSize(0, 1));
    try testing.expectError(error.InvalidSize, validateCanvasSize(1, 0));
    // (e) 総画素 > 16M（辺は上限内）
    try testing.expectError(error.CanvasTooLarge, validateCanvasSize(MAX_CANVAS_EDGE, MAX_CANVAS_EDGE + 1));
    // (f) 極大入力: 辺上限で先に CanvasTooLarge（現行定数では u32×u32 の SizeOverflow は到達不能な防御分岐）
    try testing.expectError(error.CanvasTooLarge, validateCanvasSize(std.math.maxInt(u32), 1));
    try testing.expectError(error.CanvasTooLarge, validateCanvasSize(std.math.maxInt(u32), std.math.maxInt(u32)));
}

test "resolveAnchor: 偶数サイズの mid/center" {
    try testing.expectEqual(Point{ .x = 4, .y = 4 }, try resolveAnchor("center", 8, 8));
    try testing.expectEqual(Point{ .x = 7, .y = 0 }, try resolveAnchor("top-right", 8, 8));
    try testing.expectEqual(Point{ .x = 4, .y = 7 }, try resolveAnchor("mid-bottom", 8, 8));
}

test "parseSymmetry / parsePixelPerfect" {
    try testing.expectEqual(SymmetryMode.off, try parseSymmetry("off"));
    try testing.expectEqual(SymmetryMode.v, try parseSymmetry("v"));
    try testing.expectEqual(SymmetryMode.h, try parseSymmetry("h"));
    try testing.expectEqual(SymmetryMode.quad, try parseSymmetry("quad"));
    try testing.expectError(error.UnknownSymmetry, parseSymmetry("vertical"));
    try testing.expectError(error.TooManyTokens, parseSymmetry("v extra"));

    try testing.expectEqual(true, try parsePixelPerfect("1"));
    try testing.expectEqual(false, try parsePixelPerfect("0"));
    try testing.expectError(error.UnknownBool, parsePixelPerfect("yes"));
}

test "formatCanonicalShape round-trip" {
    var buf: [64]u8 = undefined;
    const s = try formatCanonicalShape(&buf, .{ .kind = .rect, .p0 = .{ .x = 4, .y = 4 }, .p1 = .{ .x = 20, .y = 14 }, .fill = true });
    try testing.expectEqualStrings("rect 4,4 20,14 fill", s);
    const rt = try parseShape(s, 256, 256);
    try testing.expectEqual(ShapeKind.rect, rt.kind);
    try testing.expect(rt.fill);
}

// ============================================================================
// TASK-103: presence parsers + PresenceStore（std のみ・platform.getTime は呼び出し側が渡す）
// ============================================================================

pub const PRESENCE_COORD_MAX: i32 = 255;
pub const PRESENCE_TTL_MAX: u16 = 10000;
pub const PRESENCE_MAX_PEERS: usize = 8;

pub const PresenceKind = enum {
    point,
    highlight,
    suggest,

    pub fn defaultTtlMs(self: PresenceKind) u16 {
        return switch (self) {
            .point => 1500,
            .highlight => 2000,
            .suggest => 1200,
        };
    }
};

pub const PresencePointArgs = struct {
    peer_id: u32,
    x: i32,
    y: i32,
    ttl_ms: u16,
};

pub const PresenceHighlightArgs = struct {
    peer_id: u32,
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    ttl_ms: u16,
};

fn parseCoordToken(tok: []const u8) ParseError!i32 {
    const v = std.fmt.parseInt(i32, tok, 10) catch return error.InvalidNumber;
    if (v < 0 or v > PRESENCE_COORD_MAX) return error.ValueOutOfRange;
    return v;
}

fn parseTtlToken(tok: []const u8, kind: PresenceKind) ParseError!u16 {
    const v = std.fmt.parseInt(u32, tok, 10) catch return error.InvalidNumber;
    if (v > PRESENCE_TTL_MAX) return error.ValueOutOfRange;
    if (v == 0) return kind.defaultTtlMs();
    return @intCast(v);
}

/// `presence_point` args: `[peer=<id>] <x> <y> [ttl_ms]`（peer 省略時 0）。
pub fn parsePresencePoint(args: []const u8) ParseError!PresencePointArgs {
    var it = tokenize(args);
    const t0 = it.next() orelse return error.Empty;
    var peer_id: u32 = 0;
    var x_tok: []const u8 = undefined;
    if (std.mem.startsWith(u8, t0, "peer=")) {
        peer_id = std.fmt.parseInt(u32, t0["peer=".len..], 10) catch return error.InvalidNumber;
        x_tok = it.next() orelse return error.Empty;
    } else {
        x_tok = t0;
    }
    const y_tok = it.next() orelse return error.Empty;
    const x = try parseCoordToken(x_tok);
    const y = try parseCoordToken(y_tok);
    const ttl: u16 = if (it.next()) |tt|
        try parseTtlToken(tt, .point)
    else
        PresenceKind.point.defaultTtlMs();
    try expectExhausted(&it);
    return .{ .peer_id = peer_id, .x = x, .y = y, .ttl_ms = ttl };
}

/// `presence_highlight` args: `[peer=<id>] <x0> <y0> <x1> <y1> [ttl_ms]`。
pub fn parsePresenceHighlight(args: []const u8) ParseError!PresenceHighlightArgs {
    var it = tokenize(args);
    const t0 = it.next() orelse return error.Empty;
    var peer_id: u32 = 0;
    var x0_tok: []const u8 = undefined;
    if (std.mem.startsWith(u8, t0, "peer=")) {
        peer_id = std.fmt.parseInt(u32, t0["peer=".len..], 10) catch return error.InvalidNumber;
        x0_tok = it.next() orelse return error.Empty;
    } else {
        x0_tok = t0;
    }
    const y0_tok = it.next() orelse return error.Empty;
    const x1_tok = it.next() orelse return error.Empty;
    const y1_tok = it.next() orelse return error.Empty;
    const x0 = try parseCoordToken(x0_tok);
    const y0 = try parseCoordToken(y0_tok);
    const x1 = try parseCoordToken(x1_tok);
    const y1 = try parseCoordToken(y1_tok);
    const ttl: u16 = if (it.next()) |tt|
        try parseTtlToken(tt, .highlight)
    else
        PresenceKind.highlight.defaultTtlMs();
    try expectExhausted(&it);
    return .{ .peer_id = peer_id, .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .ttl_ms = ttl };
}

/// `presence_suggest` args: `[peer=<id>] <x> <y> [ttl_ms]`。
pub fn parsePresenceSuggest(args: []const u8) ParseError!PresencePointArgs {
    // 座標・TTL 規則は point と同じ（既定 TTL のみ suggest）
    var it = tokenize(args);
    const t0 = it.next() orelse return error.Empty;
    var peer_id: u32 = 0;
    var x_tok: []const u8 = undefined;
    if (std.mem.startsWith(u8, t0, "peer=")) {
        peer_id = std.fmt.parseInt(u32, t0["peer=".len..], 10) catch return error.InvalidNumber;
        x_tok = it.next() orelse return error.Empty;
    } else {
        x_tok = t0;
    }
    const y_tok = it.next() orelse return error.Empty;
    const x = try parseCoordToken(x_tok);
    const y = try parseCoordToken(y_tok);
    const ttl: u16 = if (it.next()) |tt|
        try parseTtlToken(tt, .suggest)
    else
        PresenceKind.suggest.defaultTtlMs();
    try expectExhausted(&it);
    return .{ .peer_id = peer_id, .x = x, .y = y, .ttl_ms = ttl };
}

pub const PeerPresence = struct {
    peer_id: u32 = 0,
    occupied: bool = false,
    point_active: bool = false,
    point_x: i32 = 0,
    point_y: i32 = 0,
    point_deadline: f64 = 0,
    highlight_active: bool = false,
    hl_x0: i32 = 0,
    hl_y0: i32 = 0,
    hl_x1: i32 = 0,
    hl_y1: i32 = 0,
    highlight_deadline: f64 = 0,
    suggest_active: bool = false,
    suggest_x: i32 = 0,
    suggest_y: i32 = 0,
    suggest_deadline: f64 = 0,

    fn anyActive(self: *const PeerPresence) bool {
        return self.point_active or self.highlight_active or self.suggest_active;
    }
};

pub const PresenceStore = struct {
    peers: [PRESENCE_MAX_PEERS]PeerPresence = [_]PeerPresence{.{}} ** PRESENCE_MAX_PEERS,

    fn slotFor(self: *PresenceStore, peer_id: u32) ?*PeerPresence {
        for (&self.peers) |*p| {
            if (p.occupied and p.peer_id == peer_id) return p;
        }
        for (&self.peers) |*p| {
            if (!p.occupied) {
                p.* = .{ .peer_id = peer_id, .occupied = true };
                return p;
            }
        }
        // 満杯: 先頭を再利用（MVP。MAX_PEERS=8 と netsync 一致）
        self.peers[0] = .{ .peer_id = peer_id, .occupied = true };
        return &self.peers[0];
    }

    pub fn applyPoint(self: *PresenceStore, a: PresencePointArgs, now: f64) void {
        const p = self.slotFor(a.peer_id) orelse return;
        p.point_active = true;
        p.point_x = a.x;
        p.point_y = a.y;
        p.point_deadline = now + @as(f64, @floatFromInt(a.ttl_ms)) / 1000.0;
    }

    pub fn applyHighlight(self: *PresenceStore, a: PresenceHighlightArgs, now: f64) void {
        const p = self.slotFor(a.peer_id) orelse return;
        p.highlight_active = true;
        p.hl_x0 = a.x0;
        p.hl_y0 = a.y0;
        p.hl_x1 = a.x1;
        p.hl_y1 = a.y1;
        p.highlight_deadline = now + @as(f64, @floatFromInt(a.ttl_ms)) / 1000.0;
    }

    pub fn applySuggest(self: *PresenceStore, a: PresencePointArgs, now: f64) void {
        const p = self.slotFor(a.peer_id) orelse return;
        p.suggest_active = true;
        p.suggest_x = a.x;
        p.suggest_y = a.y;
        p.suggest_deadline = now + @as(f64, @floatFromInt(a.ttl_ms)) / 1000.0;
    }

    pub fn expire(self: *PresenceStore, now: f64) void {
        for (&self.peers) |*p| {
            if (!p.occupied) continue;
            if (p.point_active and now >= p.point_deadline) p.point_active = false;
            if (p.highlight_active and now >= p.highlight_deadline) p.highlight_active = false;
            if (p.suggest_active and now >= p.suggest_deadline) p.suggest_active = false;
            if (!p.anyActive()) p.occupied = false;
        }
    }

    /// digest: `count=N point=P highlight=H suggest=S [p<id>=x,y ...] [h<id>=... ] [s<id>=...]`
    pub fn formatDigest(self: *PresenceStore, buf: []u8, now: f64) []const u8 {
        self.expire(now);
        var point_n: u32 = 0;
        var highlight_n: u32 = 0;
        var suggest_n: u32 = 0;
        for (&self.peers) |*p| {
            if (!p.occupied) continue;
            if (p.point_active) point_n += 1;
            if (p.highlight_active) highlight_n += 1;
            if (p.suggest_active) suggest_n += 1;
        }
        const total = point_n + highlight_n + suggest_n;
        var len: usize = 0;
        const head = std.fmt.bufPrint(buf, "count={d} point={d} highlight={d} suggest={d}", .{ total, point_n, highlight_n, suggest_n }) catch return buf[0..0];
        len = head.len;
        for (&self.peers) |*p| {
            if (!p.occupied) continue;
            if (p.point_active) {
                const part = std.fmt.bufPrint(buf[len..], " p{d}={d},{d}", .{ p.peer_id, p.point_x, p.point_y }) catch break;
                len += part.len;
            }
            if (p.highlight_active) {
                const x0 = @min(p.hl_x0, p.hl_x1);
                const y0 = @min(p.hl_y0, p.hl_y1);
                const x1 = @max(p.hl_x0, p.hl_x1);
                const y1 = @max(p.hl_y0, p.hl_y1);
                const part = std.fmt.bufPrint(buf[len..], " h{d}={d},{d},{d},{d}", .{ p.peer_id, x0, y0, x1, y1 }) catch break;
                len += part.len;
            }
            if (p.suggest_active) {
                const part = std.fmt.bufPrint(buf[len..], " s{d}={d},{d}", .{ p.peer_id, p.suggest_x, p.suggest_y }) catch break;
                len += part.len;
            }
        }
        return buf[0..len];
    }
};

test "parsePresencePoint / Highlight / Suggest" {
    const p = try parsePresencePoint("32 40 1500");
    try testing.expectEqual(@as(u32, 0), p.peer_id);
    try testing.expectEqual(@as(i32, 32), p.x);
    try testing.expectEqual(@as(i32, 40), p.y);
    try testing.expectEqual(@as(u16, 1500), p.ttl_ms);

    const pr = try parsePresencePoint("peer=1 32 40 1500");
    try testing.expectEqual(@as(u32, 1), pr.peer_id);

    const def = try parsePresencePoint("10 20");
    try testing.expectEqual(@as(u16, 1500), def.ttl_ms);

    const h = try parsePresenceHighlight("10 12 40 24 2000");
    try testing.expectEqual(@as(i32, 10), h.x0);
    try testing.expectEqual(@as(i32, 24), h.y1);

    const s = try parsePresenceSuggest("48 48");
    try testing.expectEqual(@as(u16, 1200), s.ttl_ms);

    try testing.expectError(error.ValueOutOfRange, parsePresencePoint("256 0"));
    try testing.expectError(error.ValueOutOfRange, parsePresencePoint("0 -1"));
    try testing.expectError(error.ValueOutOfRange, parsePresencePoint("0 0 10001"));
    try testing.expectError(error.TooManyTokens, parsePresencePoint("1 2 3 4"));
    try testing.expectError(error.Empty, parsePresencePoint(""));
    try testing.expectError(error.TooManyTokens, parsePresenceHighlight("1 2 3 4 5 6"));
}

test "PresenceStore: TTL expire / subtype 独立 / digest" {
    var store: PresenceStore = .{};
    store.applyPoint(.{ .peer_id = 1, .x = 32, .y = 40, .ttl_ms = 1500 }, 0.0);
    store.applyHighlight(.{ .peer_id = 1, .x0 = 10, .y0 = 12, .x1 = 40, .y1 = 24, .ttl_ms = 2000 }, 0.0);
    store.applySuggest(.{ .peer_id = 1, .x = 48, .y = 48, .ttl_ms = 1200 }, 0.0);

    var buf: [256]u8 = undefined;
    const d0 = store.formatDigest(&buf, 0.5);
    try testing.expect(std.mem.indexOf(u8, d0, "count=3") != null);
    try testing.expect(std.mem.indexOf(u8, d0, "point=1") != null);
    try testing.expect(std.mem.indexOf(u8, d0, "highlight=1") != null);
    try testing.expect(std.mem.indexOf(u8, d0, "suggest=1") != null);
    try testing.expect(std.mem.indexOf(u8, d0, "p1=32,40") != null);
    try testing.expect(std.mem.indexOf(u8, d0, "h1=10,12,40,24") != null);
    try testing.expect(std.mem.indexOf(u8, d0, "s1=48,48") != null);

    // suggest だけ消滅（1.2s）
    const d1 = store.formatDigest(&buf, 1.3);
    try testing.expect(std.mem.indexOf(u8, d1, "suggest=0") != null);
    try testing.expect(std.mem.indexOf(u8, d1, "point=1") != null);
    try testing.expect(std.mem.indexOf(u8, d1, "s1=") == null);

    // 全消滅
    const d2 = store.formatDigest(&buf, 2.1);
    try testing.expect(std.mem.indexOf(u8, d2, "count=0") != null);
    try testing.expect(std.mem.indexOf(u8, d2, "point=0") != null);
}

test "PresenceStore: peer 無し local と remote peer= が独立 slot" {
    var store: PresenceStore = .{};
    store.applyPoint(.{ .peer_id = 0, .x = 1, .y = 1, .ttl_ms = 1500 }, 0);
    store.applyPoint(.{ .peer_id = 1, .x = 2, .y = 2, .ttl_ms = 1500 }, 0);
    var buf: [256]u8 = undefined;
    const d = store.formatDigest(&buf, 0);
    try testing.expect(std.mem.indexOf(u8, d, "count=2") != null);
    try testing.expect(std.mem.indexOf(u8, d, "point=2") != null);
    try testing.expect(std.mem.indexOf(u8, d, "p0=1,1") != null);
    try testing.expect(std.mem.indexOf(u8, d, "p1=2,2") != null);
}
