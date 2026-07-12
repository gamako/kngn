// === カラー絵文字 (sbix) デモ (TASK-26.4) ===
//
// libs/font の OutlineFont + sbix 統合（TASK-26.2/26.3 で実装済み）で Apple Color Emoji.ttc を
// runtime 読込し、単一コードポイント絵文字 + ASCII/日本語 混在描画を目視確認する。
//
//   1. テキスト face: 12_outline_font と同じ候補リスト（system の .ttf/.ttc を runtime 読込）
//   2. 絵文字 face: /System/Library/Fonts/Apple Color Emoji.ttc（macOS のみ・再配布なし）
//
// 制約（明記）:
//   - default emoji presentation の**単一 codepoint**のみ対応（例 U+1F600 😀）。
//     VS16 シーケンス（U+2764 U+FE0F 等）・ZWJ 結合・肌色修飾・国旗は非対応（将来のシェーピング課題）。
//   - 非 macOS（Linux/Windows）や Apple Color Emoji 不在環境では emoji face 無しで起動し、
//     その旨をテキスト描画する（graceful degradation。落ちない）。Linux の Noto Color Emoji は
//     CBDT/CBLC 形式のため本デモ（sbix 専用）の対象外。
//
// ホットパス宣言: 毎フレーム呼ぶのは 26.1/26.3 実装済みの OutlineFont.drawTo / font.blitRGBA の
// みで新規の全画素ループは無い。baseline ガイド線は @memset の一括書き込み（per-pixel ループでは
// ない）。よって性能規約の SIMD 3点セット・bench 前後比較は適用対象外（新設ループ無し）。

const std = @import("std");
const platform = @import("platform");
const fontmod = @import("font");

const Color = fontmod.Color;
const RenderTarget = fontmod.RenderTarget;
const Rect = fontmod.Rect;

// Apple Color Emoji（macOS 標準搭載。再配布はしない・runtime 読込のみ）。
const emoji_font_path = "/System/Library/Fonts/Apple Color Emoji.ttc";

const target_emoji_cp = "\u{1F600}"; // 😀 default emoji presentation の単一 codepoint

const Loaded = fontmod.LoadedSystemFontFace;

/// 単一パスを read→FontFace.init する（Apple Color Emoji 専用。候補リスト無し）。
fn loadSingleFace(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ?Loaded {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |err| {
        std.debug.print("emoji font: read {s}: {s} (macOS 以外・環境差では想定内)\n", .{ path, @errorName(err) });
        return null;
    };
    const face = fontmod.FontFace.init(bytes) catch |err| {
        std.debug.print("emoji font: parse {s}: {s}\n", .{ path, @errorName(err) });
        alloc.free(bytes);
        return null;
    };
    std.debug.print("emoji font: loaded {s} ({d} bytes)\n", .{ path, bytes.len });
    return .{ .bytes = bytes, .face = face };
}

/// カラーグリフの前提条件を診断ログへ出し、実際に使用可能か（sbix 有り かつ gid 解決成功）を
/// 返す（codex 計画レビュー指摘の preflight ゲート a〜c）。戻り値 false の場合、呼び出し側は
/// emoji face を「使用不能」として扱い、fallback メッセージを表示すること（codex コードレビュー
/// 指摘: sbix 無し/gid 未解決でも emoji_fonts を作ると、画面上は無地/outline フォールバックの
/// まま「デモ成功っぽい」表示になり fallback メッセージが出ない不具合があったため）。
/// (d) 実際に color glyph が decode 成功したかは本関数では判定せず、検証手順側で harness
/// snapshot の実ピクセル色を目視確認する分担とする（内部キャッシュを覗く private API が無いため。
/// drawTo の結果＝画面上の色そのものが最も直接的な証拠になる）。
fn logEmojiPreflight(face: *const fontmod.FontFace) bool {
    std.debug.print("emoji font: FontFace.init ok\n", .{});
    const has_sbix = face.sbix != null;
    std.debug.print("emoji font: sbix = {s}\n", .{if (has_sbix) "present" else "MISSING (outline-only fallback)"});
    const gid = face.cmap.lookup(0x1F600);
    if (gid != 0) {
        std.debug.print("emoji font: gid(U+1F600) = {d} (resolved)\n", .{gid});
    } else {
        std.debug.print("emoji font: gid(U+1F600) = 0 (UNRESOLVED -- cmap encoding record not supported? see cmap.zig (3,10)/(0,4)/(3,1)/(0,3))\n", .{});
    }
    const usable = has_sbix and gid != 0;
    if (!usable) std.debug.print("emoji font: NOT USABLE for this demo (sbix missing or cmap gid unresolved) -- falling back to text-only message\n", .{});
    return usable;
}

/// x=[x0,x1) の水平線を 1px 幅で引く（バウンド外は自動でクリップ）。@memset の一括書き込みで
/// per-pixel ループではない。
fn drawHLine(pixels: []u32, fb_w: u32, fb_h: u32, y: i32, x0: i32, x1: i32, color: u32) void {
    if (y < 0 or y >= @as(i32, @intCast(fb_h))) return;
    const yu: u32 = @intCast(y);
    const xs: u32 = @intCast(@max(x0, 0));
    const xe: u32 = @intCast(@max(@min(x1, @as(i32, @intCast(fb_w))), 0));
    if (xe <= xs) return;
    const row = yu * fb_w;
    @memset(pixels[row + xs .. row + xe], color);
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(960, 600, "19: Color Emoji (sbix) Demo");
    defer window.destroy();

    // テキスト face（ASCII/日本語）。
    const text_loaded = fontmod.loadSystemTextFace(init.io, allocator);
    defer if (text_loaded) |l| allocator.free(l.bytes);
    if (text_loaded == null) std.debug.print("no usable system text font found; labels will be blank.\n", .{});
    var text_face: ?fontmod.FontFace = if (text_loaded) |l| l.face else null;

    var text_big: ?fontmod.OutlineFont = null;
    var text_mid: ?fontmod.OutlineFont = null;
    var text_small: ?fontmod.OutlineFont = null;
    if (text_face) |*f| {
        text_big = fontmod.OutlineFont.init(allocator, f, 28);
        text_mid = fontmod.OutlineFont.init(allocator, f, 22);
        text_small = fontmod.OutlineFont.init(allocator, f, 14);
    }
    defer if (text_big) |*o| o.deinit();
    defer if (text_mid) |*o| o.deinit();
    defer if (text_small) |*o| o.deinit();

    // 絵文字 face（Apple Color Emoji。macOS のみ想定・不在なら null のまま継続）。
    const emoji_loaded = loadSingleFace(init.io, allocator, emoji_font_path);
    defer if (emoji_loaded) |l| allocator.free(l.bytes);
    var emoji_face: ?fontmod.FontFace = if (emoji_loaded) |l| l.face else null;
    // sbix 無し・cmap gid 未解決の face は「使用不能」として emoji_fonts を作らない（codex
    // コードレビュー指摘: 作ってしまうと画面は無地/outline フォールバックのまま fallback
    // メッセージが出ず「デモ成功っぽい」誤表示になる）。
    const emoji_usable = if (emoji_face) |*f| logEmojiPreflight(f) else false;
    if (emoji_face != null and !emoji_usable) emoji_face = null; // FontFace.deinit 不要（借用のみで解放対象なし）

    const emoji_sizes = [_]f32{ 24, 48, 96 };
    var emoji_fonts: [3]?fontmod.OutlineFont = .{ null, null, null };
    if (emoji_face) |*f| {
        for (&emoji_fonts, emoji_sizes) |*of, px| of.* = fontmod.OutlineFont.init(allocator, f, px);
    }
    defer for (&emoji_fonts) |*of| if (of.*) |*o| o.deinit();

    const white = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);
    const cyan = Color.rgba(0x66, 0xCC, 0xFF, 0xFF);
    const gray = Color.rgba(0xAA, 0xAA, 0xAA, 0xFF);
    const guide_line_color: u32 = 0xFF555566;

    std.debug.print("Controls: ESC to quit.\n", .{});

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| if (k.key == .ESCAPE) break :main_loop,
            else => {},
        };

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, 0xFF1A1A2E);
            const target = RenderTarget{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
            const clip = Rect{ .x = 0, .y = 0, .w = fb.width, .h = fb.height };

            if (text_big) |*big| big.asFont().drawTo(target, .{ .x = 20, .y = 16 }, "Color Emoji (sbix) Demo", cyan, clip);
            if (text_small) |*small| {
                small.asFont().drawTo(target, .{ .x = 20, .y = 56 }, "Single default-presentation codepoint only (no VS16/ZWJ/skin tone/flags). ESC to quit.", gray, clip);
            }

            // ── 混在描画（ASCII/日本語/絵文字 を同一行にインライン表示） ──
            if (text_mid) |*mid| {
                if (text_small) |*small| small.asFont().drawTo(target, .{ .x = 20, .y = 84 }, "Mixed inline (ASCII + Japanese + emoji, single row):", gray, clip);
                var cx: f32 = 20;
                const row_y = 108;
                const segs = [_]struct { text: []const u8, is_emoji: bool }{
                    .{ .text = "Hello ", .is_emoji = false },
                    .{ .text = target_emoji_cp, .is_emoji = true },
                    .{ .text = " \u{3053}\u{3093}\u{306B}\u{3061}\u{306F} \u{4E16}\u{754C} ", .is_emoji = false }, // こんにちは 世界
                    .{ .text = target_emoji_cp, .is_emoji = true },
                    .{ .text = " ABC 123", .is_emoji = false },
                };
                for (segs) |seg| {
                    const xi: i32 = @intFromFloat(@round(cx));
                    if (seg.is_emoji) {
                        if (emoji_fonts[0]) |*e24| {
                            e24.asFont().drawTo(target, .{ .x = xi, .y = row_y }, seg.text, white, clip);
                            cx += @floatFromInt(e24.measure(seg.text));
                        } else {
                            mid.asFont().drawTo(target, .{ .x = xi, .y = row_y }, "[emoji]", white, clip);
                            cx += @floatFromInt(mid.measure("[emoji]"));
                        }
                    } else {
                        mid.asFont().drawTo(target, .{ .x = xi, .y = row_y }, seg.text, white, clip);
                        cx += @floatFromInt(mid.measure(seg.text));
                    }
                }

                mid.asFont().drawTo(target, .{ .x = 20, .y = 170 }, "The quick brown fox jumps over the lazy dog. 0123456789", white, clip);
                mid.asFont().drawTo(target, .{ .x = 20, .y = 200 }, "\u{65E5}\u{672C}\u{8A9E}: \u{3053}\u{3093}\u{306B}\u{3061}\u{306F}\u{4E16}\u{754C} \u{3044}\u{308D}\u{306F} ABC123", white, clip); // 日本語: こんにちは世界 いろは ABC123
            }

            // ── 絵文字ストライク・サイズ比較（共有 baseline ガイド線で origin 整合を目視） ──
            if (text_small) |*small| small.asFont().drawTo(target, .{ .x = 20, .y = 250 }, "Emoji strike sizes 24 / 48 / 96px (shared baseline guide line):", gray, clip);

            const baseline_row_y: i32 = 420;
            const emoji_x = [_]i32{ 40, 220, 480 };
            var have_any_emoji = false;
            for (&emoji_fonts, emoji_sizes, emoji_x) |*of, px, x| {
                if (of.*) |*e| {
                    have_any_emoji = true;
                    const m = e.metrics();
                    const pos_y = baseline_row_y - m.ascent;
                    e.asFont().drawTo(target, .{ .x = x, .y = pos_y }, target_emoji_cp, white, clip);
                    if (text_small) |*small| {
                        var buf: [16]u8 = undefined;
                        const label = std.fmt.bufPrint(&buf, "{d}px", .{@as(u32, @intFromFloat(px))}) catch "?px";
                        small.asFont().drawTo(target, .{ .x = x, .y = baseline_row_y + 12 }, label, gray, clip);
                    }
                }
            }
            if (have_any_emoji) {
                drawHLine(fb.pixels, fb.width, fb.height, baseline_row_y, 20, 900, guide_line_color);
            } else if (text_small) |*small| {
                small.asFont().drawTo(
                    target,
                    .{ .x = 20, .y = 280 },
                    "Apple Color Emoji unavailable (not found, or sbix/cmap unsupported) -- color emoji rendering skipped (see stderr log). Expected on non-macOS.",
                    gray,
                    clip,
                );
            }

            window.present();
        }

        platform.frameDelay(16_666_666);
    }
}
