// === アウトラインフォント (TTF) レンダリング デモ (TASK-25.6) ===
//
// libs/font の OutlineFont で実 TTF を画面に描画する。
//   1. system の .ttf を runtime 読込（bytes は main 寿命の owner buffer に保持）
//   2. FontFace（不変・借用 data）→ OutlineFont（px サイズ束縛・遅延キャッシュ）
//   3. 共通 Font インターフェースの drawTo で各サイズのテキストを描画
//
// 注: フォント資産の vendoring（OFL）は follow-up。ここでは macOS の system .ttf を
//     runtime 読込する（再配布でないのでライセンス問題なし・macOS 依存）。

const std = @import("std");
const platform = @import("platform");
const fontmod = @import("font");

// 試行する system フォントパス（glyf 系 TTF）。先に見つかったものを使う。
const font_paths = [_][]const u8{
    // 日本語フォントを優先（.ttc コレクション＝CID-keyed CFF。ASCII も含むので 1 本で混在描画可）
    "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc",
    "/System/Library/Fonts/ヒラギノ角ゴシック W4.ttc",
    "/System/Library/Fonts/ヒラギノ明朝 ProN.ttc",
    // ASCII フォント（日本語が無い場合のフォールバック）
    "/System/Library/Fonts/Supplemental/Andale Mono.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Supplemental/Times New Roman.ttf",
    "/Library/Fonts/Arial.ttf",
    // Linux（Ubuntu / nix の system フォント）。macOS では FileNotFound で skip される。
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", // 日本語（CJK, CID-keyed CFF）
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", // ASCII フォールバック
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
};

const Loaded = struct { bytes: []u8, face: fontmod.FontFace };

/// 各候補を read→FontFace.init まで試し、最初に成功したものを返す。
/// FileNotFound は静かに次へ。それ以外（権限/IO/parse 失敗）はログして次候補へ。
fn loadFace(io: std.Io, alloc: std.mem.Allocator) ?Loaded {
    for (font_paths) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |err| {
            if (err != error.FileNotFound) std.debug.print("font read {s}: {s}\n", .{ path, @errorName(err) });
            continue;
        };
        const face = fontmod.FontFace.init(bytes) catch |err| {
            std.debug.print("font parse {s}: {s}\n", .{ path, @errorName(err) });
            alloc.free(bytes);
            continue;
        };
        std.debug.print("font: loaded {s} ({d} bytes)\n", .{ path, bytes.len });
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

    // フォント bytes は FontFace より長命であること（main 寿命で保持）。
    const loaded = loadFace(init.io, allocator);
    defer if (loaded) |l| allocator.free(l.bytes);
    if (loaded == null) std.debug.print("no usable system .ttf found; window will be blank.\n", .{});

    var face: ?fontmod.FontFace = if (loaded) |l| l.face else null;

    // 複数サイズの OutlineFont（同一 FontFace を共有）
    var fonts: [3]?fontmod.OutlineFont = .{ null, null, null };
    const sizes = [_]f32{ 48, 24, 16 };
    if (face) |*f| {
        for (&fonts, sizes) |*of, px| of.* = fontmod.OutlineFont.init(allocator, f, px);
    }
    defer for (&fonts) |*of| if (of.*) |*o| o.deinit();

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

            if (fonts[0]) |*big| big.asFont().drawTo(target, .{ .x = 24, .y = 24 }, "Outline Font (TTF)", white, clip);
            if (fonts[1]) |*mid| mid.asFont().drawTo(target, .{ .x = 24, .y = 96 }, "The quick brown fox jumps over the lazy dog.", cyan, clip);
            if (fonts[0]) |*big| big.asFont().drawTo(target, .{ .x = 24, .y = 230 }, "こんにちは 世界 ABC 123", white, clip);
            if (fonts[2]) |*small| {
                small.asFont().drawTo(target, .{ .x = 24, .y = 150 }, "abcdefghijklmnopqrstuvwxyz 0123456789 !?@#&", white, clip);
                small.asFont().drawTo(target, .{ .x = 24, .y = 180 }, "ESC to quit. Glyphs are rasterized on demand and cached.", cyan, clip);
                small.asFont().drawTo(target, .{ .x = 24, .y = 300 }, "日本語: ひらがな カタカナ 漢字（CFF/.ttc）", cyan, clip);
            }

            window.present();
        }

        var req = std.c.timespec{ .sec = 0, .nsec = 16_666_666 };
        _ = std.c.nanosleep(&req, null);
    }
}
