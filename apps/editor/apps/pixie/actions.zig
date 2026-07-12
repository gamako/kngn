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

/// `goto_frame <idx>` 用: frame index の1トークン（u32）。
pub fn parseGotoFrame(args: []const u8) ParseError!u32 {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const v = std.fmt.parseUnsigned(u32, tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return v;
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

test "parseGotoFrame: 有効値 / Empty / InvalidNumber / TooManyTokens" {
    try testing.expectEqual(@as(u32, 0), try parseGotoFrame("0"));
    try testing.expectEqual(@as(u32, 12), try parseGotoFrame("  12  "));
    try testing.expectError(error.Empty, parseGotoFrame(""));
    try testing.expectError(error.Empty, parseGotoFrame("   "));
    try testing.expectError(error.InvalidNumber, parseGotoFrame("abc"));
    try testing.expectError(error.InvalidNumber, parseGotoFrame("-1"));
    try testing.expectError(error.TooManyTokens, parseGotoFrame("1 2"));
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
