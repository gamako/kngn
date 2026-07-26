//! modular: base seed for generative RNG plus per-purpose derivation.
//!
//! Hot-path declaration: derive runs only at event time (action seed), at init time, and when the PRNG is
//! rebuilt at a bar boundary. Never called on the per-sample RT path.
//!
//! Depends only on std (unit-testable). Timbre fixed seeds (e.g. Kick/Hat/Clap's "KICK") are
//! out of scope (kept independent of the base seed to preserve timbre identity).

const std = @import("std");

/// Default base seed. `deriveU32(DEFAULT, *)` is bit-compatible with the current fixed-seed set
/// (doesn't break the existing offline CRC determinism tests).
pub const DEFAULT_BASE_SEED: u64 = 0;

/// Purpose tag (XORed with base and passed to splitmix64). Returns the legacy constant when DEFAULT.
pub const Purpose = enum(u64) {
    mutate = 1,
    ambient_random = 2,
    ambient_turing = 3,
    ambient_turing_register = 4,
};

/// splitmix64 (Steele / Vigna). Deterministic, no alloc.
pub fn splitmix64(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

/// Derives a per-purpose u32 from the base seed.
/// With DEFAULT_BASE_SEED, returns the current LofiPatch fixed seeds ("MUT1"/"RAND"/"TURN"/0xB5).
pub fn deriveU32(base: u64, purpose: Purpose) u32 {
    if (base == DEFAULT_BASE_SEED) {
        return switch (purpose) {
            .mutate => 0x4D555431, // "MUT1"
            .ambient_random => 0x52414E44, // "RAND"
            .ambient_turing => 0x5455524E, // "TURN"
            .ambient_turing_register => 0xB5,
        };
    }
    return @truncate(splitmix64(base ^ @intFromEnum(purpose)));
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "seed derive: same base yields same stream; different base differs" {
    const a1 = deriveU32(42, .mutate);
    const a2 = deriveU32(42, .mutate);
    try testing.expectEqual(a1, a2);
    const b = deriveU32(43, .mutate);
    try testing.expect(a1 != b);

    // Differs even with the same base if the purpose differs
    try testing.expect(deriveU32(42, .mutate) != deriveU32(42, .ambient_random));
    try testing.expect(deriveU32(42, .ambient_turing) != deriveU32(42, .ambient_turing_register));
}

test "seed derive: DEFAULT_BASE_SEED matches legacy fixed seeds" {
    try testing.expectEqual(@as(u32, 0x4D555431), deriveU32(DEFAULT_BASE_SEED, .mutate));
    try testing.expectEqual(@as(u32, 0x52414E44), deriveU32(DEFAULT_BASE_SEED, .ambient_random));
    try testing.expectEqual(@as(u32, 0x5455524E), deriveU32(DEFAULT_BASE_SEED, .ambient_turing));
    try testing.expectEqual(@as(u32, 0xB5), deriveU32(DEFAULT_BASE_SEED, .ambient_turing_register));
}

test "splitmix64: deterministic and mixes" {
    try testing.expectEqual(splitmix64(0), splitmix64(0));
    try testing.expect(splitmix64(0) != splitmix64(1));
}
