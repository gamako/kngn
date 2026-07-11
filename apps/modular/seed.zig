//! modular の生成 RNG 用 base seed + 用途別 derive（TASK-62.5.7）。
//!
//! ホットパス宣言: derive はイベント時（action seed）と初期化時、および bar 境界での
//! PRNG 再構築時のみ。毎サンプル RT 経路では呼ばない。
//!
//! std のみ依存（単体テスト可能）。音色用 fixed seed（Kick/Hat/Clap の "KICK" 等）は
//! 対象外（音色の同一性のため base seed から独立）。

const std = @import("std");

/// 既定 base seed。`deriveU32(DEFAULT, *)` は現行 fixed seed 群と bit 互換
/// （既存 offline CRC 決定性テストを壊さない）。
pub const DEFAULT_BASE_SEED: u64 = 0;

/// 用途タグ（base と XOR して splitmix64 へ渡す）。DEFAULT 時は legacy 定数を返す。
pub const Purpose = enum(u64) {
    mutate = 1,
    ambient_random = 2,
    ambient_turing = 3,
    ambient_turing_register = 4,
};

/// splitmix64（Steele / Vigna）。決定的・alloc なし。
pub fn splitmix64(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

/// base seed から用途別 u32 を導出する。
/// DEFAULT_BASE_SEED では現行 LofiPatch の fixed seed（"MUT1"/"RAND"/"TURN"/0xB5）を返す。
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

    // 用途が違えば同 base でも相違
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
