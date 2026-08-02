//! Pure parsers for pixie's harness actions.
//!
//! Hot-path note: parse results are dispatched **event-only** (once per harness `action <name> [args]`
//! command). Not a per-frame full-pixel loop or a per-sample RT path,
//! so the performance rules (SIMD three-point set etc.) do not apply.
//!
//! This file depends on **std only** and imports neither App, kit, nor platform (avoids a circular
//! import with main.zig. Dispatch that needs the concrete App type, and `registerActions(app)`, live
//! in main.zig's "headless-harness custom action" section. Detailed design notes
//! (action ⇄ UndoCmd pairing table, whether undo is pushed, network policy) are in that
//! doc comment too).
//!
//! Each parser takes the raw remainder after `action <name>` (already trimmed; main.zig has already
//! stripped `;`/newlines) and returns a typed value or an error. Numeric parsers read whitespace-
//! separated tokens and **reject leftover tokens with `error.TooManyTokens`** (fail-fast;
//! do not swallow typos). `parsePath` is the exception: paths may contain spaces, so it passes through.

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

/// Layer ref: `#<id>` (stable handle) or a bare number (index; backward compatible).
pub const LayerRef = union(enum) {
    id: u64,
    index: usize,
};

fn tokenize(args: []const u8) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, args, " \t");
}

/// Check that the token iterator has no leftover tokens (shared fail-fast helper).
fn expectExhausted(it: *std.mem.TokenIterator(u8, .any)) ParseError!void {
    if (it.next() != null) return error.TooManyTokens;
}

/// One "<idx>" token.
pub fn parseUsize(args: []const u8) ParseError!usize {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const v = std.fmt.parseUnsigned(usize, tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return v;
}

/// One "<0-255>" token.
pub fn parseU8(args: []const u8) ParseError!u8 {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const v = std.fmt.parseUnsigned(u8, tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return v;
}

/// One signed-integer token (generic parser besides `move_layer`. Pixie actions currently use
/// `parseMoveDelta`, but this stays public for boundary tests and future actions).
pub fn parseI32(args: []const u8) ParseError!i32 {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const v = std.fmt.parseInt(i32, tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return v;
}

pub const IdxBool = struct { idx: usize, on: bool };

/// Two tokens: "<idx> <0|1>".
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

/// "on [count]" / "off" / "1 [count]" / "0". count is optional (caller clamps to 1..3).
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

/// Two tokens: "<idx> <0-255>".
pub fn parseIdxU8(args: []const u8) ParseError!IdxU8 {
    var it = tokenize(args);
    const idx_tok = it.next() orelse return error.Empty;
    const idx = std.fmt.parseUnsigned(usize, idx_tok, 10) catch return error.InvalidNumber;
    const v_tok = it.next() orelse return error.Empty;
    const value = std.fmt.parseUnsigned(u8, v_tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return .{ .idx = idx, .value = value };
}

// No text-layer action parsers are added here.
// Text-layer harness coverage goes through UI (context menu + `inject char`) by design
// (see main.zig `registerActions`). MAX_ACTIONS has headroom —
// capacity is not why these stay UI-only.
// (No text-layer action slot is registered from this file.)

/// One "#RRGGBB" or "RRGGBB" token (case-insensitive) → canonical 0xFFRRGGBB (straight; alpha fixed at 255).
pub fn parseHexColor(args: []const u8) ParseError!u32 {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const c = try parseHexColorToken(tok);
    try expectExhausted(&it);
    return c;
}

/// Single-token form of `parseHexColor` (shared with `parseStroke`'s `color=` value).
fn parseHexColorToken(tok_in: []const u8) ParseError!u32 {
    var tok = tok_in;
    if (tok.len > 0 and tok[0] == '#') tok = tok[1..];
    if (tok.len != 6) return error.InvalidNumber;
    const rgb = std.fmt.parseUnsigned(u32, tok, 16) catch return error.InvalidNumber;
    return 0xFF000000 | rgb;
}

/// One "<+1|-1>" token (`move_layer` only. Anything other than ±1 → `error.InvalidDelta`).
pub fn parseMoveDelta(args: []const u8) ParseError!i32 {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const v = std.fmt.parseInt(i32, tok, 10) catch return error.InvalidNumber;
    if (v != 1 and v != -1) return error.InvalidDelta;
    try expectExhausted(&it);
    return v;
}

/// Single-token layer ref: `#<id>` → `.id` / bare number → `.index`.
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

/// One "`#<id>` | `<idx>`" token (select_layer / delete_layer / duplicate_layer / merge_down).
pub fn parseLayerRef(args: []const u8) ParseError!LayerRef {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const ref = try parseLayerRefToken(tok);
    try expectExhausted(&it);
    return ref;
}

pub const LayerRefBool = struct { ref: LayerRef, on: bool };

/// "`#<id>`|`<idx>` <0|1>" (set_layer_visible).
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

/// "`#<id>`|`<idx>` <0-255>" (set_layer_opacity).
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

/// "`#<id>`|`<idx>` <+1|-1>" (move_layer canonical / both forms).
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

/// Write `#<id>` into buf (for canonicalize / UI helpers).
pub fn formatLayerId(buf: []u8, id: u64) error{TooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "#{d}", .{id}) catch return error.TooLong;
}

/// `#<id> <0|1>`.
pub fn formatLayerIdBool(buf: []u8, id: u64, on: bool) error{TooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "#{d} {d}", .{ id, @as(u8, if (on) 1 else 0) }) catch return error.TooLong;
}

/// `#<id> <0-255>`.
pub fn formatLayerIdU8(buf: []u8, id: u64, value: u8) error{TooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "#{d} {d}", .{ id, value }) catch return error.TooLong;
}

/// `#<id> <+1|-1>`.
pub fn formatLayerIdDelta(buf: []u8, id: u64, delta: i32) error{TooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "#{d} {d}", .{ id, delta }) catch return error.TooLong;
}

/// During netsync, .relay layer ops require `#<id>` (bare index / implicit selected are wrong targets).
/// false in solo (index still allowed, as before). Pure function; unit-testable.
pub fn layerRefRejectDuringNetsync(ref: LayerRef, netsync_active: bool) bool {
    return netsync_active and ref == .index;
}

/// Whether canonicalize may fill/convert implicit selected / bare index to #id.
/// Forbidden during netsync (selected differs per peer → diverge).
pub fn allowLayerCanonFill(netsync_active: bool) bool {
    return !netsync_active;
}

/// UI paint-commit branch during netsync.
/// - solo: netsync off → pushPaintOp + recordUiStroke
/// - relay: netsync + pen/eraser/brush → rewind → routeAction("stroke")
/// - rewind_discard: netsync + fill etc. (no action vocabulary) → rewind and discard (prevent silent diverge)
pub const UiPaintCommitPath = enum { solo, relay, rewind_discard };

pub fn uiPaintCommitPath(netsync_active: bool, relays_via_action: bool) UiPaintCommitPath {
    if (!netsync_active) return .solo;
    if (relays_via_action) return .relay;
    return .rewind_discard;
}

pub const Point = struct { x: i32, y: i32 };

/// Stroke-action point-list cap (caller prepares a fixed stack buffer of this size).
pub const MAX_STROKE_POINTS: usize = 256;

/// Per-chunk point-list cap for netsync relay wire.
/// Smaller than `MAX_STROKE_POINTS`; 128 is chosen so worst-case coords still fit `MAX_CMD_ARGS` / action frame (4096B)
/// (brush head + `segment=continuation` + worst-case i32 coords × N + commit framing).
/// The comptime below self-checks against a 4096 literal (std only). Drift guard against the real constant
/// lives in `apps/editor/apps/pixie/main.zig` against `platform.command.MAX_CMD_ARGS`.
pub const RELAY_STROKE_CHUNK_POINTS: usize = 128;

comptime {
    // commit framing: 12B header + "stroke " + args. propose is looser at 4B+name.
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

/// "x0 y0 x1 y1 ..." → pack into `buf` and return a borrowed slice (no allocator; no ownership transfer).
/// Even count required (odd → `error.OddPointCount`). Zero → `error.Empty`. Over `buf.len` → `error.TooManyPoints`.
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

// ── stroke k=v extension ─────────────────────────────
//
// Grammar: `stroke [layer=#id] [tool=pen|eraser|brush] [color=RRGGBB] [size=N] [opacity=N] [hardness=N] x0 y0 [x y ...]`
// k=v tokens may appear only **before** the coordinate list (zero or more; any order). No parameters stays
// backward-compatible with the legacy grammar (existing replay scripts unchanged). Fail-fast: duplicate key, unknown key,
// or bad value (tool name / hex / numeric range) are all errors (same "do not swallow typos" policy
// as inject modifiers).

/// Tools that stroke can latch (independent-path tools like bezier/select are out of scope).
pub const StrokeTool = enum { pen, eraser, brush, fill };

/// Relay-chunk boundary meta. Omitted / `first` = normal stroke (stamp the origin).
/// `continuation` starts from the previous chunk's end carry and does not stamp the origin.
pub const StrokeSegment = enum { first, continuation };

/// Brush-size cap (same value as `paint.Brush.MAX_SIZE`. actions.zig defines it independently because it is std-only;
/// drift is caught by main.zig's comptime check).
pub const MAX_BRUSH_SIZE: u32 = 64;

/// Explicit stroke k=v parameters (null = unspecified → caller fills from current App state).
pub const StrokeParams = struct {
    layer: ?LayerRef = null,
    tool: ?StrokeTool = null,
    color: ?u32 = null, // canonical 0xFFRRGGBB
    size: ?u32 = null, // 1..MAX_BRUSH_SIZE
    opacity: ?u8 = null, // 0..255
    hardness: ?u8 = null, // 0..255 (same scale as Brush.hardness_q)
    tolerance: ?u8 = null, // 0..255 (fill only)
    segment: ?StrokeSegment = null, // null/first = normal. continuation = no-stamp origin
};

pub const StrokeArgs = struct { params: StrokeParams, points: []Point };

/// "k=v ... x0 y0 x1 y1 ..." → parameters + point list. Point-list rules match `parseStrokePoints`
/// (even count required; zero → Empty; over `buf.len` → TooManyPoints).
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
            } else if (std.mem.eql(u8, key, "tolerance")) {
                if (params.tolerance != null) return error.DuplicateKey;
                params.tolerance = std.fmt.parseUnsigned(u8, val, 10) catch return error.InvalidNumber;
            } else if (std.mem.eql(u8, key, "segment")) {
                if (params.segment != null) return error.DuplicateKey;
                params.segment = std.meta.stringToEnum(StrokeSegment, val) orelse return error.UnknownKey;
            } else {
                return error.UnknownKey;
            }
        } else {
            pending = tok; // First coordinate token (rest is the coordinate list)
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

/// Effective parameters of a canonical stroke (resolved: explicit k=v > current App state).
pub const EffectiveStroke = struct {
    layer_id: u64,
    tool: StrokeTool,
    color: u32, // 0xFFRRGGBB
    size: u32,
    opacity: u8,
    hardness: u8,
    /// Fill color distance (0 = exact match). Unused for pen/eraser/brush.
    tolerance: u8 = 0,
    /// `first` is not written on the wire (backward compatible). Only `continuation` is explicit.
    segment: StrokeSegment = .first,
};

/// Build canonical self-contained stroke args (shared by UI recording and the agent path).
/// Includes each tool-relevant key **exactly once**: pen=tool,color / eraser=tool /
/// brush=tool,color,size,opacity,hardness / fill=tool,color,tolerance. Round-trips through
/// `parseStroke` (every recorded stroke record re-runs without depending on App state).
/// `error.TooLong` if it does not fit buf.
/// `segment=continuation` is appended only for continuation chunks (`first`/omit same as before).
pub fn formatCanonicalStroke(buf: []u8, eff: EffectiveStroke, points: []const Point) error{TooLong}![]const u8 {
    var len: usize = 0;
    const head = switch (eff.tool) {
        .pen => std.fmt.bufPrint(buf, "layer=#{d} tool=pen color={X:0>6}", .{ eff.layer_id, eff.color & 0xFFFFFF }) catch return error.TooLong,
        .eraser => std.fmt.bufPrint(buf, "layer=#{d} tool=eraser", .{eff.layer_id}) catch return error.TooLong,
        .brush => std.fmt.bufPrint(buf, "layer=#{d} tool=brush color={X:0>6} size={d} opacity={d} hardness={d}", .{
            eff.layer_id, eff.color & 0xFFFFFF, eff.size, eff.opacity, eff.hardness,
        }) catch return error.TooLong,
        .fill => std.fmt.bufPrint(buf, "layer=#{d} tool=fill color={X:0>6} tolerance={d}", .{
            eff.layer_id,
            eff.color & 0xFFFFFF,
            eff.tolerance,
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

/// For `save`/`open`: trim only leading/trailing whitespace; keep internal spaces (treat path as one
/// string that may contain spaces. Do not tokenize like the numeric parsers).
pub fn parsePath(args: []const u8) ParseError![]const u8 {
    const trimmed = std.mem.trim(u8, args, " \t");
    if (trimmed.len == 0) return error.Empty;
    return trimmed;
}

// ── palette / replace_color parsers ────────────────────────────

pub const ReplaceColorArgs = struct {
    /// When omitted, the handler uses the selected layer (#id required / reject during netsync).
    layer: ?LayerRef = null,
    from: u32,
    to: u32,
};

/// Whether the leading token is a layer ref (`#`+decimal = id / decimal-only = index).
/// `#RRGGBB` (hex color) contains non-decimal chars → false → treat as a color token.
fn looksLikeLayerRefToken(tok: []const u8) bool {
    if (tok.len == 0) return false;
    if (tok[0] == '#') {
        if (tok.len < 2) return true; // InvalidNumber at parse time
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

/// `replace_color [#<id>|<index>] <from> <to>` (layer ref optional; defaults to selected).
/// Two hex tokens alone stay legacy-compatible. A leading `#`+decimal or bare number is a layer ref.
pub fn parseReplaceColor(args: []const u8) ParseError!ReplaceColorArgs {
    var it = tokenize(args);
    const t1 = it.next() orelse return error.Empty;
    const t2 = it.next() orelse return error.Empty;
    if (it.next()) |t3| {
        // 3 tokens: layer ref + from + to
        if (!looksLikeLayerRefToken(t1)) return error.TooManyTokens;
        const ref = try parseLayerRefToken(t1);
        const from = try parseHexColorToken(t2);
        const to = try parseHexColorToken(t3);
        try expectExhausted(&it);
        return .{ .layer = ref, .from = from, .to = to };
    }
    // 2 tokens: from + to (legacy-compatible)
    const from = try parseHexColorToken(t1);
    const to = try parseHexColorToken(t2);
    return .{ .layer = null, .from = from, .to = to };
}

pub const PaletteRampArgs = struct { seed: u32, n: u8 };

/// `palette_ramp <seed_hex> <n>` (n is 2..=32).
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

/// palette_set color-count cap (same as palette.zig MAX_PALETTE_COLORS; drift caught by main comptime).
pub const MAX_PALETTE_SET: usize = 64;

// ── shape / symmetry / pixel_perfect ────────────────────────

pub const ShapeKind = enum { line, rect, ellipse };

/// Symmetry mode (same vocabulary as StrokeRecorder.Symmetry. v/h are short forms).
pub const SymmetryMode = enum { off, v, h, quad };

pub const ShapeArgs = struct {
    kind: ShapeKind,
    p0: Point,
    p1: Point,
    fill: bool = false,
};

/// Anchor name → canvas coords (App-independent. Caller passes w/h).
/// center / top-left / top-right / bottom-left / bottom-right /
/// mid-top / mid-bottom / mid-left / mid-right.
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

/// `x,y` coordinate token or an anchor name.
/// Numeric path requires `0 <= x < w` / `0 <= y < h` (out of range / negative → ValueOutOfRange).
/// Anchor path is in-range by definition; no extra check.
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
/// p is `x,y` or an anchor name. fill is meaningful for rect/ellipse only (still accepted for line).
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

/// Canvas size (resize / new W H). Cap is applied by the caller's shared validator.
pub const CanvasSize = struct { w: u32, h: u32 };

/// Canvas-size cap (each edge ≤4096; total pixels ≤16M). Shared by action / .pix / netsync / GUI.
pub const MAX_CANVAS_EDGE: u32 = 4096;
pub const MAX_CANVAS_PIXELS: usize = 16 * 1024 * 1024;

/// Validate canvas size (each edge ≤4096; total pixels ≤16M). Reject 0 / mul overflow / over cap.
pub fn validateCanvasSize(w: u32, h: u32) error{ InvalidSize, SizeOverflow, CanvasTooLarge }!void {
    if (w == 0 or h == 0) return error.InvalidSize;
    if (w > MAX_CANVAS_EDGE or h > MAX_CANVAS_EDGE) return error.CanvasTooLarge;
    const n = std.math.mul(usize, w, h) catch return error.SizeOverflow;
    if (n > MAX_CANVAS_PIXELS) return error.CanvasTooLarge;
}

/// `resize W H` equivalent: exactly 2 unsigned-int args. 0 → ValueOutOfRange.
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

/// `new` / `new W H`. 0 args = blank reset at current size (backward compatible). 2 args = new at the given size.
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

/// `set_grid <0|1>`
pub fn parseGrid(args: []const u8) ParseError!bool {
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

/// `set_loupe <0|1>`
pub fn parseLoupe(args: []const u8) ParseError!bool {
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

/// `set_coarse_grid <0|1>`
pub fn parseCoarseGrid(args: []const u8) ParseError!bool {
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

/// The coarse grid's spacing range, shared by the UI slider, this parser, and the persisted
/// preferences clamp (one range, so a value valid in one place is valid everywhere): at least one
/// canvas pixel, and capped at 256. The cap is set by what the grid is for — marking tile and
/// sprite boundaries, which live in the 8..128 range — rather than by what a document can hold.
/// A cap near the largest canvas edge would only buy spacings that draw at most one line across a
/// typical document, at the cost of spreading the slider's travel so thin that the useful values
/// become hard to hit.
pub const MIN_GRID_SPACING: u32 = 1;
pub const MAX_GRID_SPACING: u32 = 256;

/// `set_grid_spacing <N>` (N is MIN_GRID_SPACING..=MAX_GRID_SPACING, in canvas pixels).
pub fn parseGridSpacing(args: []const u8) ParseError!i32 {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const n = std.fmt.parseUnsigned(u32, tok, 10) catch return error.InvalidNumber;
    if (n < MIN_GRID_SPACING or n > MAX_GRID_SPACING) return error.ValueOutOfRange;
    try expectExhausted(&it);
    return @intCast(n);
}

/// Canonical shape args (for UI recording / redo).
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

/// `palette_set <hex...>` (1..=64; # optional) → pack into `buf` and return a borrowed slice.
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

/// For no-arg actions (undo/redo/clear/add_layer/delete_layer): after trim, require empty
/// (leftover tokens → `error.TooManyTokens`. Do not swallow typos).
pub fn parseNoArgs(args: []const u8) ParseError!void {
    if (std.mem.trim(u8, args, " \t").len != 0) return error.TooManyTokens;
}

/// `panel_toggle` panel-name set (for harness actions. Short IDs, distinct from PanelHost stable names).
pub const PanelToggleName = enum {
    history,
    color,
    palette,
    tool_options,
    layers,
    timeline,
};

/// For `panel_toggle <name>`: one token. Unknown / empty / leftover → error.
pub fn parsePanelToggle(args: []const u8) ParseError!PanelToggleName {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const name = std.meta.stringToEnum(PanelToggleName, tok) orelse return error.UnknownPanel;
    try expectExhausted(&it);
    return name;
}

/// For `goto_frame <idx>`: one frame-index token (u32).
pub fn parseGotoFrame(args: []const u8) ParseError!u32 {
    var it = tokenize(args);
    const tok = it.next() orelse return error.Empty;
    const v = std.fmt.parseUnsigned(u32, tok, 10) catch return error.InvalidNumber;
    try expectExhausted(&it);
    return v;
}

/// For `export_seq <stem>`: stem for numbered PNGs (one path token; whitespace trim only).
pub fn parseExportSeq(args: []const u8) ParseError![]const u8 {
    return parsePath(args);
}

pub const ExportSheetArgs = struct {
    path: []const u8,
    columns: u32 = 0,
    margin: u32 = 0,
};

/// For `export_sheet <path> [columns] [margin]`.
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

test "parseUsize: valid / empty / bad number / leftover tokens" {
    try testing.expectEqual(@as(usize, 0), try parseUsize("0"));
    try testing.expectEqual(@as(usize, 42), try parseUsize("  42  "));
    try testing.expectError(error.Empty, parseUsize(""));
    try testing.expectError(error.Empty, parseUsize("   "));
    try testing.expectError(error.InvalidNumber, parseUsize("abc"));
    try testing.expectError(error.InvalidNumber, parseUsize("-1"));
    try testing.expectError(error.TooManyTokens, parseUsize("1 2"));
}

test "parseU8: out of range → InvalidNumber" {
    try testing.expectEqual(@as(u8, 255), try parseU8("255"));
    try testing.expectError(error.InvalidNumber, parseU8("256"));
}

test "parseIdxBool: only 0/1 allowed / bad token" {
    try testing.expectEqual(IdxBool{ .idx = 3, .on = true }, try parseIdxBool("3 1"));
    try testing.expectEqual(IdxBool{ .idx = 0, .on = false }, try parseIdxBool("0 0"));
    try testing.expectError(error.UnknownBool, parseIdxBool("0 true"));
    try testing.expectError(error.Empty, parseIdxBool("0"));
    try testing.expectError(error.TooManyTokens, parseIdxBool("0 1 2"));
}

test "parseIdxU8: valid / out of range" {
    try testing.expectEqual(IdxU8{ .idx = 2, .value = 128 }, try parseIdxU8("2 128"));
    try testing.expectError(error.InvalidNumber, parseIdxU8("2 999"));
    try testing.expectError(error.Empty, parseIdxU8("2"));
}

test "parseHexColor: # optional / case-insensitive / bad length / bad chars" {
    try testing.expectEqual(@as(u32, 0xFFFF0000), try parseHexColor("#FF0000"));
    try testing.expectEqual(@as(u32, 0xFFFF0000), try parseHexColor("FF0000"));
    try testing.expectEqual(@as(u32, 0xFF00FF00), try parseHexColor("00ff00"));
    try testing.expectError(error.InvalidNumber, parseHexColor("#FF00"));
    try testing.expectError(error.InvalidNumber, parseHexColor("#GGGGGG"));
    try testing.expectError(error.Empty, parseHexColor(""));
}

test "parseMoveDelta: only +1/-1 allowed" {
    try testing.expectEqual(@as(i32, 1), try parseMoveDelta("1"));
    try testing.expectEqual(@as(i32, -1), try parseMoveDelta("-1"));
    try testing.expectError(error.InvalidDelta, parseMoveDelta("2"));
    try testing.expectError(error.InvalidDelta, parseMoveDelta("0"));
}

test "parseLayerRef: #<id> and bare index forms / bad token" {
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

test "layerRefRejectDuringNetsync: during netsync reject bare index only / id ok / solo allows both" {
    try testing.expect(!layerRefRejectDuringNetsync(.{ .id = 1 }, false));
    try testing.expect(!layerRefRejectDuringNetsync(.{ .index = 0 }, false));
    try testing.expect(!layerRefRejectDuringNetsync(.{ .id = 1 }, true));
    try testing.expect(layerRefRejectDuringNetsync(.{ .index = 0 }, true));
    try testing.expect(layerRefRejectDuringNetsync(.{ .index = 3 }, true));
}

test "allowLayerCanonFill: during netsync forbid implicit selected / index→id fill" {
    try testing.expect(allowLayerCanonFill(false)); // solo: fill allowed
    try testing.expect(!allowLayerCanonFill(true)); // netsync: fill forbidden
}

test "uiPaintCommitPath: three branches solo / relay / rewind_discard" {
    try testing.expectEqual(UiPaintCommitPath.solo, uiPaintCommitPath(false, false));
    try testing.expectEqual(UiPaintCommitPath.solo, uiPaintCommitPath(false, true));
    try testing.expectEqual(UiPaintCommitPath.relay, uiPaintCommitPath(true, true));
    try testing.expectEqual(UiPaintCommitPath.rewind_discard, uiPaintCommitPath(true, false));
}

/// Trailing trunc marker for digests (shared with canvasDigest. `" trunc=1"` = 8 bytes).
pub const DIGEST_TRUNC_MARKER = " trunc=1";

/// When `truncated=false`, return `buf[0..written]` as-is (bit-identical).
/// When `truncated=true`, append ` trunc=1` at the end, shrinking written if needed to make room.
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

/// Test helper: pack whitespace-separated entries into buf; set trunc=1 if they do not fit.
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

test "finishDigestWithTrunc: non-trunc bit-identical / trunc appends trunc=1" {
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

test "parseReplaceColor: two hex / # optional / layer ref omitted or present / too many or few" {
    const a = try parseReplaceColor("FF0000 00FF00");
    try testing.expect(a.layer == null);
    try testing.expectEqual(@as(u32, 0xFFFF0000), a.from);
    try testing.expectEqual(@as(u32, 0xFF00FF00), a.to);
    // #RRGGBB is a color (not a layer id)
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
    // 3 hex colors (leading token does not look like a ref) → TooManyTokens
    try testing.expectError(error.TooManyTokens, parseReplaceColor("FF0000 00FF00 0000FF"));
    try testing.expectError(error.InvalidNumber, parseReplaceColor("GGGGGG 00FF00"));
    try testing.expectError(error.TooManyTokens, parseReplaceColor("#1 FF0000 00FF00 extra"));
}

test "parsePaletteRamp: n 2..=32 / out of range" {
    const a = try parsePaletteRamp("336699 8");
    try testing.expectEqual(@as(u32, 0xFF336699), a.seed);
    try testing.expectEqual(@as(u8, 8), a.n);
    try testing.expectError(error.ValueOutOfRange, parsePaletteRamp("336699 1"));
    try testing.expectError(error.ValueOutOfRange, parsePaletteRamp("336699 33"));
    try testing.expectError(error.Empty, parsePaletteRamp("336699"));
    try testing.expectError(error.TooManyTokens, parsePaletteRamp("336699 8 extra"));
}

test "parsePaletteSet: 1..=64 hex / empty / too many" {
    var buf: [64]u32 = undefined;
    const one = try parsePaletteSet("FF0000", &buf);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(@as(u32, 0xFFFF0000), one[0]);
    const three = try parsePaletteSet("#FF0000 00FF00 0000FF", &buf);
    try testing.expectEqual(@as(usize, 3), three.len);
    try testing.expectError(error.Empty, parsePaletteSet("", &buf));
    // 65 → TooManyTokens ("FF0000 " × 65 ≈ 455B)
    var many_buf: [512]u8 = undefined;
    var len: usize = 0;
    var i: usize = 0;
    while (i < 65) : (i += 1) {
        const part = std.fmt.bufPrint(many_buf[len..], "{s}FF0000", .{if (i == 0) "" else " "}) catch unreachable;
        len += part.len;
    }
    try testing.expectError(error.TooManyTokens, parsePaletteSet(many_buf[0..len], &buf));
}

test "packDigestEntries: few entries no trunc / many entries trunc=1" {
    var small_buf: [128]u8 = undefined;
    const few = packDigestEntries(&small_buf, "head", &[_][]const u8{ "l0{id=1,name=a}", "l1{id=2,name=b}" });
    try testing.expect(std.mem.startsWith(u8, few, "head "));
    try testing.expect(std.mem.indexOf(u8, few, "trunc=1") == null);

    var tiny: [40]u8 = undefined;
    const long_name = "l0{id=1,v=true,op=255,crc=DEADBEEF,nz=0,name=VeryLongLayerNameForTrunc,kind=raster}";
    const many = packDigestEntries(&tiny, "head", &[_][]const u8{ long_name, long_name, long_name });
    try testing.expect(std.mem.endsWith(u8, many, DIGEST_TRUNC_MARKER));
}

test "parseStrokePoints: valid list / odd count / empty / over cap" {
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

test "parsePath: trim ends / keep internal spaces / reject empty" {
    try testing.expectEqualStrings("/tmp/out.png", try parsePath("  /tmp/out.png  "));
    try testing.expectEqualStrings("/tmp/my file.png", try parsePath("/tmp/my file.png"));
    try testing.expectError(error.Empty, parsePath(""));
    try testing.expectError(error.Empty, parsePath("   "));
}

test "parseNoArgs: empty ok / reject leftover tokens" {
    try parseNoArgs("");
    try parseNoArgs("   ");
    try testing.expectError(error.TooManyTokens, parseNoArgs("typo"));
}

test "parsePanelToggle: valid name / empty / unknown / leftover tokens" {
    try testing.expectEqual(PanelToggleName.history, try parsePanelToggle("history"));
    try testing.expectEqual(PanelToggleName.tool_options, try parsePanelToggle("tool_options"));
    try testing.expectEqual(PanelToggleName.timeline, try parsePanelToggle("  timeline  "));
    try testing.expectError(error.Empty, parsePanelToggle(""));
    try testing.expectError(error.UnknownPanel, parsePanelToggle("inspector"));
    try testing.expectError(error.TooManyTokens, parsePanelToggle("history extra"));
}

test "parseGotoFrame: valid / Empty / InvalidNumber / TooManyTokens" {
    try testing.expectEqual(@as(u32, 0), try parseGotoFrame("0"));
    try testing.expectEqual(@as(u32, 12), try parseGotoFrame("  12  "));
    try testing.expectError(error.Empty, parseGotoFrame(""));
    try testing.expectError(error.Empty, parseGotoFrame("   "));
    try testing.expectError(error.InvalidNumber, parseGotoFrame("abc"));
    try testing.expectError(error.InvalidNumber, parseGotoFrame("-1"));
    try testing.expectError(error.TooManyTokens, parseGotoFrame("1 2"));
}

test "parseExportSeq: same shape as parsePath" {
    try testing.expectEqualStrings("/tmp/seq", try parseExportSeq("/tmp/seq"));
    try testing.expectError(error.Empty, parseExportSeq(""));
}

test "parseExportSheet: path only / columns+margin / reject leftover tokens" {
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

test "parseStroke: no params stays backward-compatible with legacy grammar" {
    var buf: [MAX_STROKE_POINTS]Point = undefined;
    const r = try parseStroke("10 10 50 50", &buf);
    try testing.expectEqual(@as(?StrokeTool, null), r.params.tool);
    try testing.expectEqual(@as(?u32, null), r.params.color);
    try testing.expectEqual(@as(usize, 2), r.points.len);
    try testing.expectEqual(Point{ .x = 50, .y = 50 }, r.points[1]);
}

test "parseStroke: leading k=v (any order) + coordinate list" {
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

test "parseStroke: fail-fast (duplicate key / unknown key / bad value / out of range / odd count / no coords)" {
    var buf: [MAX_STROKE_POINTS]Point = undefined;
    try testing.expectError(error.DuplicateKey, parseStroke("tool=pen tool=brush 1 1", &buf));
    try testing.expectError(error.UnknownKey, parseStroke("thickness=3 1 1", &buf));
    try testing.expectError(error.UnknownTool, parseStroke("tool=wand 1 1", &buf));
    try testing.expectError(error.InvalidNumber, parseStroke("color=GGGGGG 1 1", &buf));
    try testing.expectError(error.InvalidNumber, parseStroke("color=FF00 1 1", &buf));
    try testing.expectError(error.ValueOutOfRange, parseStroke("size=0 1 1", &buf));
    try testing.expectError(error.ValueOutOfRange, parseStroke("size=65 1 1", &buf));
    try testing.expectError(error.InvalidNumber, parseStroke("opacity=256 1 1", &buf));
    try testing.expectError(error.InvalidNumber, parseStroke("hardness=999 1 1", &buf));
    try testing.expectError(error.InvalidNumber, parseStroke("tolerance=256 1 1", &buf));
    try testing.expectError(error.DuplicateKey, parseStroke("tolerance=0 tolerance=1 1 1", &buf));
    try testing.expectError(error.OddPointCount, parseStroke("tool=pen 1 1 2", &buf));
    try testing.expectError(error.Empty, parseStroke("tool=pen", &buf));
    try testing.expectError(error.Empty, parseStroke("", &buf));
    // k=v after the coordinate list starts is invalid as a coordinate (fail-fast)
    try testing.expectError(error.InvalidNumber, parseStroke("1 1 tool=pen 2", &buf));
}

test "parseStroke: tool=fill color and tolerance" {
    var buf: [MAX_STROKE_POINTS]Point = undefined;
    const r = try parseStroke("layer=#7 tool=fill color=FF0000 tolerance=12 10 10", &buf);
    try testing.expectEqual(StrokeTool.fill, r.params.tool.?);
    try testing.expectEqual(@as(u32, 0xFFFF0000), r.params.color.?);
    try testing.expectEqual(@as(u8, 12), r.params.tolerance.?);
    try testing.expectEqual(LayerRef{ .id = 7 }, r.params.layer.?);
    try testing.expectEqual(@as(usize, 1), r.points.len);
    try testing.expectEqual(Point{ .x = 10, .y = 10 }, r.points[0]);
}

test "formatCanonicalStroke: fill form is fixed by origin EffectiveStroke (not ambient tool)" {
    var out_pen: [512]u8 = undefined;
    var out_brush: [512]u8 = undefined;
    const pts = [_]Point{.{ .x = 10, .y = 10 }};
    // Receiver tool selection never enters formatCanonicalStroke; the same origin
    // effective values must always produce the same wire form.
    const origin: EffectiveStroke = .{
        .layer_id = 7,
        .tool = .fill,
        .color = 0xFFFF0000,
        .size = 1,
        .opacity = 255,
        .hardness = 255,
        .tolerance = 12,
    };
    const wire_as_if_receiver_pen = try formatCanonicalStroke(&out_pen, origin, &pts);
    const wire_as_if_receiver_brush = try formatCanonicalStroke(&out_brush, origin, &pts);
    try testing.expectEqualStrings("layer=#7 tool=fill color=FF0000 tolerance=12 10 10", wire_as_if_receiver_pen);
    try testing.expectEqualStrings(wire_as_if_receiver_pen, wire_as_if_receiver_brush);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, wire_as_if_receiver_pen, "tool=fill"));

    var buf: [MAX_STROKE_POINTS]Point = undefined;
    const rt = try parseStroke(wire_as_if_receiver_pen, &buf);
    try testing.expectEqual(StrokeTool.fill, rt.params.tool.?);
    try testing.expectEqual(@as(u32, 0xFFFF0000), rt.params.color.?);
    try testing.expectEqual(@as(u8, 12), rt.params.tolerance.?);
}

test "parseStroke: legacy bare points keep tool null (canonicalize is the caller's job)" {
    var buf: [MAX_STROKE_POINTS]Point = undefined;
    const r = try parseStroke("10 10", &buf);
    try testing.expectEqual(@as(?StrokeTool, null), r.params.tool);
    try testing.expectEqual(@as(?u8, null), r.params.tolerance);
}

test "parseStroke: cap shares MAX_STROKE_POINTS constant (over buf.len → TooManyPoints)" {
    var small: [2]Point = undefined;
    try testing.expectError(error.TooManyPoints, parseStroke("tool=pen 1 1 2 2 3 3", &small));
}

test "formatCanonicalStroke: per-tool key set exactly once + parseStroke round-trip" {
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

    // buf that cannot fit → TooLong
    var tiny: [8]u8 = undefined;
    try testing.expectError(error.TooLong, formatCanonicalStroke(&tiny, .{ .layer_id = 7, .tool = .pen, .color = 0, .size = 1, .opacity = 255, .hardness = 255 }, &pts));
}

test "parseStroke: layer ref optional round-trip; legacy allows omit" {
    var points: [MAX_STROKE_POINTS]Point = undefined;
    const with_layer = try parseStroke("layer=#42 tool=pen color=112233 1 2", &points);
    try testing.expectEqual(LayerRef{ .id = 42 }, with_layer.params.layer.?);
    const legacy = try parseStroke("1 2", &points);
    try testing.expect(legacy.params.layer == null);
}

test "parseStroke/formatCanonicalStroke: segment=continuation round-trip (omit means first)" {
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

test "RELAY_STROKE_CHUNK_POINTS: worst-case brush continuation fits in 4096" {
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

// ── shape parsers ─────────────────────────────────────────

test "parseShape: coords / anchors / fill / errors" {
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

    // Range-check numeric coords (0 <= x < w, 0 <= y < h). Anchors are in-range by definition.
    try testing.expectError(error.ValueOutOfRange, parseShape("line -1,0 1,1", 16, 16));
    try testing.expectError(error.ValueOutOfRange, parseShape("line 0,-1 1,1", 16, 16));
    try testing.expectError(error.ValueOutOfRange, parseShape("line 0,0 16,1", 16, 16)); // x == w
    try testing.expectError(error.ValueOutOfRange, parseShape("line 0,0 1,16", 16, 16)); // y == h
    try testing.expectError(error.ValueOutOfRange, parseShape("line 0,0 999,999", 16, 16));
    try testing.expectError(error.ValueOutOfRange, parseShape("rect 0,0 2147483647,0", 256, 256));
    // Inclusive endpoints (w-1,h-1) are accepted
    const edge = try parseShape("line 0,0 15,15", 16, 16);
    try testing.expectEqual(Point{ .x = 15, .y = 15 }, edge.p1);
}

test "parseCanvasSize / parseNew: accept and reject" {
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

test "validateCanvasSize: boundaries" {
    // (a) minimum
    try validateCanvasSize(1, 1);
    // (b) edge cap exactly (4096×4096 = exactly 16M total pixels)
    try validateCanvasSize(MAX_CANVAS_EDGE, MAX_CANVAS_EDGE);
    try testing.expectEqual(@as(usize, MAX_CANVAS_PIXELS), @as(usize, MAX_CANVAS_EDGE) * @as(usize, MAX_CANVAS_EDGE));
    // (c) over edge cap
    try testing.expectError(error.CanvasTooLarge, validateCanvasSize(MAX_CANVAS_EDGE + 1, 1));
    try testing.expectError(error.CanvasTooLarge, validateCanvasSize(1, MAX_CANVAS_EDGE + 1));
    // (d) 0
    try testing.expectError(error.InvalidSize, validateCanvasSize(0, 1));
    try testing.expectError(error.InvalidSize, validateCanvasSize(1, 0));
    // (e) total pixels > 16M (edges within cap)
    try testing.expectError(error.CanvasTooLarge, validateCanvasSize(MAX_CANVAS_EDGE, MAX_CANVAS_EDGE + 1));
    // (f) huge input: CanvasTooLarge at the edge cap first (SizeOverflow on u32×u32 is an unreachable defense under current constants)
    try testing.expectError(error.CanvasTooLarge, validateCanvasSize(std.math.maxInt(u32), 1));
    try testing.expectError(error.CanvasTooLarge, validateCanvasSize(std.math.maxInt(u32), std.math.maxInt(u32)));
}

test "resolveAnchor: mid/center on even sizes" {
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

test "parseCoarseGrid / parseGridSpacing" {
    try testing.expectEqual(true, try parseCoarseGrid("1"));
    try testing.expectEqual(false, try parseCoarseGrid("0"));
    try testing.expectError(error.UnknownBool, parseCoarseGrid("on"));

    try testing.expectEqual(@as(i32, 16), try parseGridSpacing("16"));
    try testing.expectEqual(@as(i32, 1), try parseGridSpacing(std.fmt.comptimePrint("{d}", .{MIN_GRID_SPACING})));
    try testing.expectEqual(@as(i32, @intCast(MAX_GRID_SPACING)), try parseGridSpacing(std.fmt.comptimePrint("{d}", .{MAX_GRID_SPACING})));
    try testing.expectError(error.ValueOutOfRange, parseGridSpacing("0"));
    try testing.expectError(error.ValueOutOfRange, parseGridSpacing(std.fmt.comptimePrint("{d}", .{MAX_GRID_SPACING + 1})));
    try testing.expectError(error.InvalidNumber, parseGridSpacing("sixteen"));
    try testing.expectError(error.TooManyTokens, parseGridSpacing("16 32"));
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
// presence parsers + PresenceStore (std only; caller passes platform.getTime)
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

/// `presence_point` args: `[peer=<id>] <x> <y> [ttl_ms]` (peer defaults to 0).
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

/// `presence_highlight` args: `[peer=<id>] <x0> <y0> <x1> <y1> [ttl_ms]`.
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

/// `presence_suggest` args: `[peer=<id>] <x> <y> [ttl_ms]`.
pub fn parsePresenceSuggest(args: []const u8) ParseError!PresencePointArgs {
    // Coord / TTL rules match point (only the default TTL differs for suggest)
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
        // Full: reuse the head slot (MVP. MAX_PEERS=8 matches netsync)
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

test "PresenceStore: TTL expire / subtypes independent / digest" {
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

    // Only suggest expires (1.2s)
    const d1 = store.formatDigest(&buf, 1.3);
    try testing.expect(std.mem.indexOf(u8, d1, "suggest=0") != null);
    try testing.expect(std.mem.indexOf(u8, d1, "point=1") != null);
    try testing.expect(std.mem.indexOf(u8, d1, "s1=") == null);

    // All expire
    const d2 = store.formatDigest(&buf, 2.1);
    try testing.expect(std.mem.indexOf(u8, d2, "count=0") != null);
    try testing.expect(std.mem.indexOf(u8, d2, "point=0") != null);
}

test "PresenceStore: local without peer and remote peer= are independent slots" {
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
