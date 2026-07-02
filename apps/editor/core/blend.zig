//! straight-alpha src-over ブレンド（TASK-21.11 → TASK-51 で libs/pixelops へ統合）。
//! canonical BGRA(0xAARRGGBB)、非 premultiplied。
//!
//! core の blend 面（srcOver/overWhite/scaleAlpha）は維持しつつ、実装は共有
//! `pixelops` に委譲する thin facade。bit 挙動は移設前と同一（詳細テストは
//! libs/pixelops/src/lib.zig 側にある）。

const std = @import("std");
const pixelops = @import("pixelops");

/// src OVER dst（**引数順: dst が先・src が後**）。straight-alpha src-over, canonical BGRA(0xAARRGGBB)。
pub const srcOver = pixelops.srcOver;

/// 白(不透明)背景に src を src-over した不透明色（composite 表示用）。
pub const overWhite = pixelops.overWhite;

/// 色の alpha に coverage(0..255) を乗算（RGB 不変、a' = (a*cov+127)/255）。
pub const scaleAlpha = pixelops.scaleAlpha;

/// dst を不透明とみなす straight src-over（除算なし・out_a=255 固定）。
/// dst 不透明のとき srcOver と bit 一致（pixelops 側の全数テストで固定。TASK-51/54）。
pub const srcOverOpaque = pixelops.srcOverOpaque;

// ============================================================
// Tests（facade の再エクスポート疎通のみ。ブレンド自体のテストは pixelops 側）
// ============================================================

test "facade: srcOver/overWhite/scaleAlpha が pixelops へ委譲されている" {
    const dst: u32 = 0xFF112233;
    try std.testing.expectEqual(dst, srcOver(dst, 0x00AABBCC)); // a=0 → dst
    try std.testing.expectEqual(@as(u32, 0xFFAABBCC), srcOver(dst, 0xFFAABBCC)); // a=255 → src
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), overWhite(0xFF0000FF));
    try std.testing.expectEqual(@as(u32, 0x000000FF), scaleAlpha(0xFF0000FF, 0));
}
