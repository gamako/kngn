//! Pure parsers for apps/synth harness actions.
//!
//! Hot-path declaration: parse results are **event-time only** (once per harness
//! `action <name> [args]` command) and then dispatch. Neither a per-frame full-pixel loop nor a per-sample RT path,
//! so the performance rules (SIMD triad and the rest) do not apply.
//!
//! This file depends on **std only** and imports none of App / kit / platform / dsp
//! (same shape as pixie's `actions.zig`. Avoids a circular import with main.zig and stays unit-testable).
//! Resolving parameter names and enum names (wave/filter and the like) is done on the main.zig side,
//! which knows App's concrete types (same separation as pixie's `ToolKind` resolution; this file passes names through).
//!
//! Each parser takes the raw remainder of the line after `action <name>` (already trimmed; main.zig
//! has already stripped `;` / LF) and returns a typed value or an error. Tokens are whitespace-split;
//! **surplus tokens are rejected with `error.TooManyTokens`** (fail-fast; do not swallow typos).

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

/// Check that the token iterator has no leftover tokens (shared fail-fast helper).
fn expectExhausted(it: *std.mem.TokenIterator(u8, .any)) ParseError!void {
    if (it.next() != null) return error.TooManyTokens;
}

pub const NameF32 = struct { name: []const u8, value: f32 };

/// Two tokens "<name> <value>" (generic f32 setter parser for `set_param`/`set_fx_param`).
/// Reject NaN/Inf with `error.NonFinite` (fail-fast. Feeding a non-finite value into the RT-side Patch
/// invites illegal behaviour in `makePatch` via `@intFromFloat(clamp(round(unison)))` and the like).
pub fn parseNameF32(args: []const u8) ParseError!NameF32 {
    var it = tokenize(args);
    const name = it.next() orelse return error.Empty;
    const v_tok = it.next() orelse return error.Empty;
    const value = std.fmt.parseFloat(f32, v_tok) catch return error.InvalidNumber;
    if (!std.math.isFinite(value)) return error.NonFinite;
    try expectExhausted(&it);
    return .{ .name = name, .value = value };
}

/// One token "<name>" (for `set_wave`/`set_osc2_wave`/`set_filter`).
pub fn parseName(args: []const u8) ParseError![]const u8 {
    var it = tokenize(args);
    const name = it.next() orelse return error.Empty;
    try expectExhausted(&it);
    return name;
}

/// One token "<0|1>" (for `set_fx_bypass`).
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

/// For `save_patch`/`load_patch`: trim only leading/trailing whitespace; keep internal spaces (path is
/// treated as one string that may contain spaces. Do not tokenise like the numeric parsers. Same as pixie's
/// `parsePath`).
pub fn parsePath(args: []const u8) ParseError![]const u8 {
    const trimmed = std.mem.trim(u8, args, " \t");
    if (trimmed.len == 0) return error.Empty;
    return trimmed;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseNameF32: valid / empty / bad number / non-finite / surplus tokens" {
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

test "parseName: trim ends / reject surplus tokens / reject empty" {
    try testing.expectEqualStrings("saw", try parseName("  saw  "));
    try testing.expectError(error.Empty, parseName(""));
    try testing.expectError(error.Empty, parseName("   "));
    try testing.expectError(error.TooManyTokens, parseName("saw extra"));
}

test "parseBool01: only 0/1 accepted" {
    try testing.expectEqual(true, try parseBool01("1"));
    try testing.expectEqual(false, try parseBool01("0"));
    try testing.expectError(error.UnknownBool, parseBool01("true"));
    try testing.expectError(error.Empty, parseBool01(""));
    try testing.expectError(error.TooManyTokens, parseBool01("1 0"));
}

test "parsePath: trim ends / keep internal spaces / reject empty" {
    try testing.expectEqualStrings("/tmp/out.synp", try parsePath("  /tmp/out.synp  "));
    try testing.expectEqualStrings("/tmp/my patch.synp", try parsePath("/tmp/my patch.synp"));
    try testing.expectError(error.Empty, parsePath(""));
    try testing.expectError(error.Empty, parsePath("   "));
}
