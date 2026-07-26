// === Outline font (TTF) rendering demo ===
//
// Draw a real TTF on screen with libs/font OutlineFont.
//   1. Load a system .ttf at runtime (bytes kept in a main-lifetime owner buffer)
//   2. FontFace (immutable, borrowed data) → OutlineFont (px-size binding, lazy cache)
//   3. Draw each size via the shared Font interface's drawTo
//
// Note: vendoring font assets (OFL) is a follow-up. Here we load an OS system .ttf at
//     runtime (not redistributed, so no licence issue. Try macOS/Windows/Linux candidates in order).

const std = @import("std");
const platform = @import("platform");
const fontmod = @import("font");

const Loaded = fontmod.LoadedSystemFontFace;

/// Variable-font candidates (glyf VF with fvar). macOS SF Pro is representative
/// (4 axes wdth/opsz/GRAD/wght + gvar + HVAR; demo of the VF stack).
const var_font_paths = [_][]const u8{
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/SFNSRounded.ttf",
    "C:/Windows/Fonts/segoeui.ttf", // Newer Windows builds may ship a VF version
    "/usr/share/fonts/truetype/noto/NotoSans-VariableFont_wdth,wght.ttf",
};

/// read→FontFace.init each candidate; return the first with fvar (else null → skip the VF section).
fn loadVarFace(io: std.Io, alloc: std.mem.Allocator) ?Loaded {
    for (var_font_paths) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch continue;
        const face = fontmod.FontFace.init(bytes) catch {
            alloc.free(bytes);
            continue;
        };
        if (face.fvar == null) {
            alloc.free(bytes);
            continue;
        }
        std.debug.print("variable font: loaded {s}\n", .{path});
        return .{ .bytes = bytes, .face = face };
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(800, 600, "12: Outline Font (TTF) Demo");
    defer window.destroy();

    // Font bytes must outlive FontFace (held for main's lifetime).
    const loaded = fontmod.loadSystemTextFace(init.io, allocator);
    defer if (loaded) |l| allocator.free(l.bytes);
    if (loaded == null) std.debug.print("no usable system .ttf found; window will be blank.\n", .{});

    var face: ?fontmod.FontFace = if (loaded) |l| l.face else null;

    // OutlineFonts at several sizes (share one FontFace)
    var fonts: [3]?fontmod.OutlineFont = .{ null, null, null };
    const sizes = [_]f32{ 48, 24, 16 };
    if (face) |*f| {
        for (&fonts, sizes) |*of, px| of.* = fontmod.OutlineFont.init(allocator, f, px);
    }
    defer for (&fonts) |*of| if (of.*) |*o| o.deinit();

    // Variable-font section (if a system font with fvar exists, draw per wght)
    const var_loaded = loadVarFace(init.io, allocator);
    defer if (var_loaded) |l| allocator.free(l.bytes);
    var var_face: ?fontmod.FontFace = if (var_loaded) |l| l.face else null;
    const var_weights = [_]f32{ 100, 400, 700, 900 };
    var var_fonts: [var_weights.len]?fontmod.OutlineFont = .{null} ** var_weights.len;
    if (var_face) |*vf| {
        const wght_tag = [4]u8{ 'w', 'g', 'h', 't' };
        for (&var_fonts, var_weights) |*of, w| {
            var o = fontmod.OutlineFont.init(allocator, vf, 40);
            // Axis set failure (no wght axis etc.) skips only that weight row
            o.setAxis(&wght_tag, w) catch {
                o.deinit();
                continue;
            };
            of.* = o;
        }
    }
    defer for (&var_fonts) |*of| if (of.*) |*o| o.deinit();

    const white = fontmod.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);
    const cyan = fontmod.Color.rgba(0x66, 0xCC, 0xFF, 0xFF);

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| if (k.key == .ESCAPE) break :main_loop,
            else => {},
        };

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, 0xFF1A1A2E);
            const target = fontmod.RenderTarget{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
            const clip = fontmod.Rect{ .x = 0, .y = 0, .w = fb.width, .h = fb.height };

            if (fonts[0]) |*big| big.asFont().drawTo(target, .{ .x = 24, .y = 24 }, "Outline Font (TTF)", white, clip, 1.0);
            if (fonts[1]) |*mid| mid.asFont().drawTo(target, .{ .x = 24, .y = 96 }, "The quick brown fox jumps over the lazy dog.", cyan, clip, 1.0);
            if (fonts[0]) |*big| big.asFont().drawTo(target, .{ .x = 24, .y = 230 }, "こんにちは 世界 ABC 123", white, clip, 1.0);
            if (fonts[2]) |*small| {
                small.asFont().drawTo(target, .{ .x = 24, .y = 150 }, "abcdefghijklmnopqrstuvwxyz 0123456789 !?@#&", white, clip, 1.0);
                small.asFont().drawTo(target, .{ .x = 24, .y = 180 }, "ESC to quit. Glyphs are rasterized on demand and cached.", cyan, clip, 1.0);
                small.asFont().drawTo(target, .{ .x = 24, .y = 300 }, "日本語: ひらがな カタカナ 漢字（CFF/.ttc）", cyan, clip, 1.0);
            }

            // VF section: wght 100/400/700/900 from the same face (fvar/avar/gvar/HVAR path)
            if (var_face != null) {
                if (fonts[2]) |*small| small.asFont().drawTo(target, .{ .x = 24, .y = 340 }, "Variable font (fvar/gvar): wght 100 / 400 / 700 / 900", cyan, clip, 1.0);
                const labels = [_][]const u8{ "Thin 100", "Regular 400", "Bold 700", "Black 900" };
                var vy: i32 = 370;
                for (&var_fonts, labels) |*of, label| {
                    if (of.*) |*o| o.asFont().drawTo(target, .{ .x = 24, .y = vy }, label, white, clip, 1.0);
                    vy += 52;
                }
            }

            window.present();
        }

        platform.frameDelay(16_666_666);
    }
}
