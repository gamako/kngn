// === Colour emoji (sbix) demo ===
//
// Load Apple Color Emoji.ttc at runtime via libs/font OutlineFont + sbix integration and
// visually confirm single-codepoint emoji plus mixed ASCII/Japanese drawing.
//
//   1. Text face: same candidate list as 12_outline_font (system .ttf/.ttc loaded at runtime)
//   2. Emoji face: /System/Library/Fonts/Apple Color Emoji.ttc (macOS only; not redistributed)
//
// Constraints (stated):
//   - Only **single codepoints** with default emoji presentation (e.g. U+1F600).
//     VS16 sequences (U+2764 U+FE0F etc.), ZWJ joins, skin-tone modifiers, and flags are unsupported (future shaping work).
//   - On non-macOS (Linux/Windows) or without Apple Color Emoji, start with no emoji face and
//     draw that fact as text (graceful degradation; must not crash). Linux Noto Color Emoji is
//     CBDT/CBLC, so it is out of scope for this sbix-only demo.
//
// Hot path declaration: each frame only calls OutlineFont.drawTo / font.blitRGBA already implemented;
// no new all-pixel loop. The baseline guide is a bulk @memset write (not a per-pixel loop).
// So the SIMD three-point set and before/after bench comparison do not apply (no new loop).

const std = @import("std");
const platform = @import("platform");
const fontmod = @import("font");

const Color = fontmod.Color;
const RenderTarget = fontmod.RenderTarget;
const Rect = fontmod.Rect;

// Apple Color Emoji (bundled on macOS. Not redistributed; runtime load only).
const emoji_font_path = "/System/Library/Fonts/Apple Color Emoji.ttc";

const target_emoji_cp = "\u{1F600}"; // Single codepoint with default emoji presentation

const Loaded = fontmod.LoadedSystemFontFace;

/// read→FontFace.init a single path (Apple Color Emoji only; no candidate list).
fn loadSingleFace(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ?Loaded {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |err| {
        std.debug.print("emoji font: read {s}: {s} (expected off macOS / across environments)\n", .{ path, @errorName(err) });
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

/// Emit diagnostic logs for colour-glyph prerequisites and return whether the face is usable
/// (has sbix and gid resolves). When false, the caller must treat the emoji face as
/// unusable and show the fallback message (otherwise a face without sbix / with unresolved gid
/// still builds emoji_fonts and the screen looks like a blank/outline fallback with no
/// fallback message — a false "demo succeeded" look).
/// Whether a colour glyph actually decoded is not decided here; the verification procedure
/// visually checks real pixel colours from a harness snapshot (no private API to peek the
/// internal cache; drawTo's on-screen colour is the most direct evidence).
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

/// Draw a 1px-wide horizontal line over x=[x0,x1) (auto-clips out of bounds). Bulk @memset write;
/// not a per-pixel loop.
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

    // Text face (ASCII/Japanese).
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

    // Emoji face (Apple Color Emoji. macOS only; stay null if absent).
    const emoji_loaded = loadSingleFace(init.io, allocator, emoji_font_path);
    defer if (emoji_loaded) |l| allocator.free(l.bytes);
    var emoji_face: ?fontmod.FontFace = if (emoji_loaded) |l| l.face else null;
    // Faces without sbix or with unresolved cmap gid are "unusable": do not build emoji_fonts
    // (otherwise the screen stays blank/outline-fallback with no fallback message —
    // a false "demo succeeded" look).
    const emoji_usable = if (emoji_face) |*f| logEmojiPreflight(f) else false;
    if (emoji_face != null and !emoji_usable) emoji_face = null; // FontFace.deinit not needed (borrowed only; nothing to free)

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

            if (text_big) |*big| big.asFont().drawTo(target, .{ .x = 20, .y = 16 }, "Color Emoji (sbix) Demo", cyan, clip, 1.0);
            if (text_small) |*small| {
                small.asFont().drawTo(target, .{ .x = 20, .y = 56 }, "Single default-presentation codepoint only (no VS16/ZWJ/skin tone/flags). ESC to quit.", gray, clip, 1.0);
            }

            // ── Mixed drawing (ASCII/Japanese/emoji inline on one line) ──
            if (text_mid) |*mid| {
                if (text_small) |*small| small.asFont().drawTo(target, .{ .x = 20, .y = 84 }, "Mixed inline (ASCII + Japanese + emoji, single row):", gray, clip, 1.0);
                var cx: f32 = 20;
                const row_y = 108;
                const segs = [_]struct { text: []const u8, is_emoji: bool }{
                    .{ .text = "Hello ", .is_emoji = false },
                    .{ .text = target_emoji_cp, .is_emoji = true },
                    .{ .text = " \u{3053}\u{3093}\u{306B}\u{3061}\u{306F} \u{4E16}\u{754C} ", .is_emoji = false }, // Hello World (Japanese)
                    .{ .text = target_emoji_cp, .is_emoji = true },
                    .{ .text = " ABC 123", .is_emoji = false },
                };
                for (segs) |seg| {
                    const xi: i32 = @intFromFloat(@round(cx));
                    if (seg.is_emoji) {
                        if (emoji_fonts[0]) |*e24| {
                            e24.asFont().drawTo(target, .{ .x = xi, .y = row_y }, seg.text, white, clip, 1.0);
                            cx += @floatFromInt(e24.measure(seg.text));
                        } else {
                            mid.asFont().drawTo(target, .{ .x = xi, .y = row_y }, "[emoji]", white, clip, 1.0);
                            cx += @floatFromInt(mid.measure("[emoji]"));
                        }
                    } else {
                        mid.asFont().drawTo(target, .{ .x = xi, .y = row_y }, seg.text, white, clip, 1.0);
                        cx += @floatFromInt(mid.measure(seg.text));
                    }
                }

                mid.asFont().drawTo(target, .{ .x = 20, .y = 170 }, "The quick brown fox jumps over the lazy dog. 0123456789", white, clip, 1.0);
                mid.asFont().drawTo(target, .{ .x = 20, .y = 200 }, "\u{65E5}\u{672C}\u{8A9E}: \u{3053}\u{3093}\u{306B}\u{3061}\u{306F}\u{4E16}\u{754C} \u{3044}\u{308D}\u{306F} ABC123", white, clip, 1.0); // Japanese: hello world iroha ABC123
            }

            // ── Emoji strike / size comparison (shared baseline guide to eyeball origin alignment) ──
            if (text_small) |*small| small.asFont().drawTo(target, .{ .x = 20, .y = 250 }, "Emoji strike sizes 24 / 48 / 96px (shared baseline guide line):", gray, clip, 1.0);

            const baseline_row_y: i32 = 420;
            const emoji_x = [_]i32{ 40, 220, 480 };
            var have_any_emoji = false;
            for (&emoji_fonts, emoji_sizes, emoji_x) |*of, px, x| {
                if (of.*) |*e| {
                    have_any_emoji = true;
                    const m = e.metrics();
                    const pos_y = baseline_row_y - m.ascent;
                    e.asFont().drawTo(target, .{ .x = x, .y = pos_y }, target_emoji_cp, white, clip, 1.0);
                    if (text_small) |*small| {
                        var buf: [16]u8 = undefined;
                        const label = std.fmt.bufPrint(&buf, "{d}px", .{@as(u32, @intFromFloat(px))}) catch "?px";
                        small.asFont().drawTo(target, .{ .x = x, .y = baseline_row_y + 12 }, label, gray, clip, 1.0);
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
                    1.0,
                );
            }

            window.present();
        }

        platform.frameDelay(16_666_666);
    }
}
