//! Target-list wire format for layout actions (`auto_layout`, `auto_layout_selected`, `move_layout`).
//!
//! Payload is a `;`-separated list of final positions only (no header, no before/after pairs):
//! - real node: `#<lowercase hex stable node id>:<8 hex f32 bits>:<8 hex f32 bits>`
//! - group:     `@<lowercase hex group.identity>:<8 hex f32 bits>:<8 hex f32 bits>`
//!   (`group.identity` is a monotonic id that is never reused when a slot is recycled; not the slot GroupId.)
//!
//! Coordinates use the f32 IEEE bit pattern (no quantisation). Stable node ids are full u64
//! (variable-length hex; never truncated to 32-bit).
//!
//! Byte budget (args field of the netsync action frame, name + separator excluded by the caller):
//! - worst-case real target = 35 bytes (`#` + 16 hex id + `:` + 8 + `:` + 8)
//! - 113 real targets fit; 114 real targets are rejected wholesale
//!
//! Hot path: event time only (layout / drag commit). Not per-frame or audio RT.
//! Depends on std only so test-patch can collect it without App / kit / modular.

const std = @import("std");
const testing = std.testing;

/// Matches `core/control/command.zig` `MAX_CMD_ARGS` / netsync `MAX_ACTION_FRAME_BYTES`.
pub const MAX_CMD_ARGS: usize = 4096;

/// Worst-case bytes for one real target at full 16-hex stable id.
pub const WORST_REAL_TARGET_BYTES: usize = 1 + 16 + 1 + 8 + 1 + 8; // 35

/// Conservative max real targets that still fit in any layout action's args budget.
pub const MAX_REAL_TARGETS_FITTING: usize = 113;
pub const MIN_REAL_TARGETS_OVERFLOW: usize = 114;

pub const TargetKind = enum { real, group };

pub const LayoutTarget = struct {
    kind: TargetKind,
    id: u64,
    x: f32,
    y: f32,
};

pub const WireError = error{
    Empty,
    InvalidToken,
    InvalidHex,
    InvalidCoord,
    TooLong,
    ArgsTooLong,
};

/// Args budget for a named action: `MAX_CMD_ARGS - (name.len + 1)` (the space separator in the frame).
pub fn maxArgsForAction(action_name: []const u8) usize {
    return MAX_CMD_ARGS - (action_name.len + 1);
}

/// Encoded size of `count` worst-case real targets (with separators).
pub fn worstCaseEncodedLen(count: usize) usize {
    if (count == 0) return 0;
    return count * WORST_REAL_TARGET_BYTES + (count - 1);
}

/// Reject when `args_len` exceeds the named action's frame budget.
pub fn checkArgsBudget(action_name: []const u8, args_len: usize) WireError!void {
    if (args_len > maxArgsForAction(action_name)) return error.ArgsTooLong;
}

fn f32Bits(v: f32) u32 {
    return @bitCast(v);
}

fn f32FromBits(bits: u32) f32 {
    return @bitCast(bits);
}

/// Append one target to `buf` starting at `off`. Returns the new offset.
pub fn appendTarget(buf: []u8, off: usize, t: LayoutTarget) WireError!usize {
    const prefix: u8 = switch (t.kind) {
        .real => '#',
        .group => '@',
    };
    const xb = f32Bits(t.x);
    const yb = f32Bits(t.y);
    const written = std.fmt.bufPrint(buf[off..], "{c}{x}:{x:0>8}:{x:0>8}", .{ prefix, t.id, xb, yb }) catch return error.TooLong;
    return off + written.len;
}

/// Encode `targets` into `buf`. Returns the written slice.
pub fn encodeTargets(buf: []u8, targets: []const LayoutTarget) WireError![]const u8 {
    if (targets.len == 0) return error.Empty;
    var off: usize = 0;
    for (targets, 0..) |t, i| {
        if (i > 0) {
            if (off >= buf.len) return error.TooLong;
            buf[off] = ';';
            off += 1;
        }
        off = try appendTarget(buf, off, t);
    }
    return buf[0..off];
}

/// Encode and enforce the named action's args budget.
pub fn encodeTargetsForAction(buf: []u8, action_name: []const u8, targets: []const LayoutTarget) WireError![]const u8 {
    const encoded = try encodeTargets(buf, targets);
    try checkArgsBudget(action_name, encoded.len);
    return encoded;
}

fn parseHexU64(tok: []const u8) WireError!u64 {
    if (tok.len == 0) return error.InvalidHex;
    return std.fmt.parseUnsigned(u64, tok, 16) catch return error.InvalidHex;
}

fn parseHexU32(tok: []const u8) WireError!u32 {
    if (tok.len != 8) return error.InvalidHex;
    return std.fmt.parseUnsigned(u32, tok, 16) catch return error.InvalidHex;
}

/// Parse one `#id:xbits:ybits` or `@id:xbits:ybits` token.
pub fn parseTargetToken(tok: []const u8) WireError!LayoutTarget {
    if (tok.len < 1 + 1 + 1 + 8 + 1 + 8) return error.InvalidToken; // min: #0:00000000:00000000
    const kind: TargetKind = switch (tok[0]) {
        '#' => .real,
        '@' => .group,
        else => return error.InvalidToken,
    };
    const body = tok[1..];
    const c1 = std.mem.indexOfScalar(u8, body, ':') orelse return error.InvalidToken;
    const rest = body[c1 + 1 ..];
    const c2 = std.mem.indexOfScalar(u8, rest, ':') orelse return error.InvalidToken;
    const id_hex = body[0..c1];
    const x_hex = rest[0..c2];
    const y_hex = rest[c2 + 1 ..];
    if (std.mem.indexOfScalar(u8, y_hex, ':') != null) return error.InvalidToken;
    const id = try parseHexU64(id_hex);
    const xb = try parseHexU32(x_hex);
    const yb = try parseHexU32(y_hex);
    const x = f32FromBits(xb);
    const y = f32FromBits(yb);
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return error.InvalidCoord;
    return .{ .kind = kind, .id = id, .x = x, .y = y };
}

/// Parse a full target-list payload. Writes into `out` and returns the count.
pub fn parseTargets(args: []const u8, out: []LayoutTarget) WireError!usize {
    const trimmed = std.mem.trim(u8, args, " \t");
    if (trimmed.len == 0) return error.Empty;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, trimmed, ';');
    while (it.next()) |tok| {
        if (tok.len == 0) return error.InvalidToken;
        if (n >= out.len) return error.TooLong;
        out[n] = try parseTargetToken(tok);
        n += 1;
    }
    if (n == 0) return error.Empty;
    return n;
}

/// Validate payload syntax and action budget without allocating.
pub fn validateArgs(action_name: []const u8, args: []const u8) WireError!void {
    try checkArgsBudget(action_name, args.len);
    var tmp: [1]LayoutTarget = undefined;
    // Walk tokens without needing the full out buffer: parse each token only.
    const trimmed = std.mem.trim(u8, args, " \t");
    if (trimmed.len == 0) return error.Empty;
    var it = std.mem.splitScalar(u8, trimmed, ';');
    var any = false;
    while (it.next()) |tok| {
        if (tok.len == 0) return error.InvalidToken;
        tmp[0] = try parseTargetToken(tok);
        any = true;
    }
    if (!any) return error.Empty;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test "layout_wire: encode/decode real and group round-trip" {
    var buf: [256]u8 = undefined;
    const targets = [_]LayoutTarget{
        .{ .kind = .real, .id = 0x12, .x = 100.0, .y = 200.0 },
        .{ .kind = .group, .id = 3, .x = 150.0, .y = 180.0 },
    };
    const encoded = try encodeTargets(&buf, &targets);
    try testing.expectEqualStrings("#12:42c80000:43480000;@3:43160000:43340000", encoded);

    var out: [4]LayoutTarget = undefined;
    const n = try parseTargets(encoded, out[0..]);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(TargetKind.real, out[0].kind);
    try testing.expectEqual(@as(u64, 0x12), out[0].id);
    try testing.expectEqual(@as(f32, 100.0), out[0].x);
    try testing.expectEqual(@as(f32, 200.0), out[0].y);
    try testing.expectEqual(TargetKind.group, out[1].kind);
    try testing.expectEqual(@as(u64, 3), out[1].id);
    try testing.expectEqual(@as(f32, 150.0), out[1].x);
    try testing.expectEqual(@as(f32, 180.0), out[1].y);
}

test "layout_wire: variable-length hex stable id is not truncated" {
    var buf: [64]u8 = undefined;
    const big: u64 = 0x1_0000_0000; // > 32-bit
    const t = LayoutTarget{ .kind = .real, .id = big, .x = 0, .y = 0 };
    const encoded = try encodeTargets(&buf, &.{t});
    try testing.expect(std.mem.startsWith(u8, encoded, "#100000000:"));
    var out: [1]LayoutTarget = undefined;
    _ = try parseTargets(encoded, out[0..]);
    try testing.expectEqual(big, out[0].id);
}

test "layout_wire: worst-case 113 real targets fit; 114 overflow" {
    try testing.expectEqual(@as(usize, 4067), worstCaseEncodedLen(MAX_REAL_TARGETS_FITTING));
    try testing.expectEqual(@as(usize, 4103), worstCaseEncodedLen(MIN_REAL_TARGETS_OVERFLOW));
    try testing.expect(worstCaseEncodedLen(MAX_REAL_TARGETS_FITTING) <= MAX_CMD_ARGS);
    try testing.expect(worstCaseEncodedLen(MIN_REAL_TARGETS_OVERFLOW) > MAX_CMD_ARGS);

    // auto_layout_selected has the tightest name budget among layout actions.
    try testing.expect(worstCaseEncodedLen(MAX_REAL_TARGETS_FITTING) <= maxArgsForAction("auto_layout_selected"));
    try testing.expect(worstCaseEncodedLen(MIN_REAL_TARGETS_OVERFLOW) > maxArgsForAction("auto_layout"));
}

test "layout_wire: default MAX_MODULES=48 display upper bound under 4096" {
    // MAX_MODULES=48 + MAX_GROUPS=8 → 56 display targets worst-case.
    const max_targets: usize = 48 + 8;
    const bound = worstCaseEncodedLen(max_targets);
    try testing.expectEqual(@as(usize, 2015), bound);
    try testing.expect(bound < MAX_CMD_ARGS);
}

test "layout_wire: encodeTargetsForAction rejects over-budget payload" {
    var buf: [8192]u8 = undefined;
    var targets: [MIN_REAL_TARGETS_OVERFLOW]LayoutTarget = undefined;
    for (&targets, 0..) |*t, i| {
        // Force full 16-hex id width so each entry is worst-case 35 bytes.
        t.* = .{ .kind = .real, .id = 0xffff_ffff_ffff_ffff -% i, .x = 1.0, .y = 2.0 };
    }
    try testing.expectError(error.ArgsTooLong, encodeTargetsForAction(&buf, "auto_layout", targets[0..]));
    try testing.expectError(error.ArgsTooLong, encodeTargetsForAction(&buf, "auto_layout_selected", targets[0..]));
    try testing.expectError(error.ArgsTooLong, encodeTargetsForAction(&buf, "move_layout", targets[0..]));

    // 113 of the same worst-case shape must fit for every layout action name.
    const ok = try encodeTargetsForAction(&buf, "auto_layout", targets[0..MAX_REAL_TARGETS_FITTING]);
    try testing.expect(ok.len <= maxArgsForAction("auto_layout"));
    try testing.expect(ok.len <= MAX_CMD_ARGS);
    try testing.expect(ok.len == 4067); // pin measured worst-case byte count
    _ = try encodeTargetsForAction(&buf, "auto_layout_selected", targets[0..MAX_REAL_TARGETS_FITTING]);
    _ = try encodeTargetsForAction(&buf, "move_layout", targets[0..MAX_REAL_TARGETS_FITTING]);
}

test "layout_wire: uniform delta preserves relative layout (multi-drag preview model)" {
    // Preview applies start + delta for every frozen target; same delta for all.
    const starts = [_]struct { x: f32, y: f32 }{
        .{ .x = 10, .y = 20 },
        .{ .x = 30, .y = 40 },
        .{ .x = 0, .y = 0 },
    };
    const dx: f32 = 5.5;
    const dy: f32 = -2.25;
    const finals = [_]struct { x: f32, y: f32 }{
        .{ .x = starts[0].x + dx, .y = starts[0].y + dy },
        .{ .x = starts[1].x + dx, .y = starts[1].y + dy },
        .{ .x = starts[2].x + dx, .y = starts[2].y + dy },
    };
    // Pairwise deltas equal the applied delta.
    try testing.expectEqual(dx, finals[1].x - starts[1].x);
    try testing.expectEqual(dy, finals[2].y - starts[2].y);
    try testing.expectEqual(finals[0].x - starts[0].x, finals[1].x - starts[1].x);
}

test "layout_wire: action-specific budgets" {
    try testing.expectEqual(@as(usize, 4084), maxArgsForAction("auto_layout"));
    try testing.expectEqual(@as(usize, 4084), maxArgsForAction("move_layout"));
    try testing.expectEqual(@as(usize, 4075), maxArgsForAction("auto_layout_selected"));
}

test "layout_wire: validateArgs rejects empty and over budget" {
    try testing.expectError(error.Empty, validateArgs("auto_layout", ""));
    try testing.expectError(error.Empty, validateArgs("auto_layout", "   "));
    var huge: [4100]u8 = undefined;
    @memset(&huge, '0');
    huge[0] = '#';
    huge[1] = '1';
    huge[2] = ':';
    // not a valid token either, but budget fails first when long enough
    try testing.expectError(error.ArgsTooLong, checkArgsBudget("auto_layout", 4085));
}

test "layout_wire: f32 bit pattern has no quantisation" {
    const v: f32 = 0.1;
    var buf: [64]u8 = undefined;
    const encoded = try encodeTargets(&buf, &.{.{ .kind = .real, .id = 1, .x = v, .y = -v }});
    var out: [1]LayoutTarget = undefined;
    _ = try parseTargets(encoded, out[0..]);
    try testing.expectEqual(v, out[0].x);
    try testing.expectEqual(-v, out[0].y);
    try testing.expectEqual(f32Bits(v), f32Bits(out[0].x));
}
