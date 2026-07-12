// === アウトラインフォント (TTF) レンダリング デモ (TASK-25.6) ===
//
// libs/font の OutlineFont で実 TTF を画面に描画する。
//   1. system の .ttf を runtime 読込（bytes は main 寿命の owner buffer に保持）
//   2. FontFace（不変・借用 data）→ OutlineFont（px サイズ束縛・遅延キャッシュ）
//   3. 共通 Font インターフェースの drawTo で各サイズのテキストを描画
//
// 注: フォント資産の vendoring（OFL）は follow-up。ここでは OS の system .ttf を
//     runtime 読込する（再配布でないのでライセンス問題なし。macOS/Windows/Linux の候補を順に試す）。

const std = @import("std");
const platform = @import("platform");
const fontmod = @import("font");

const Loaded = fontmod.LoadedSystemFontFace;

/// 可変フォント（fvar あり glyf VF）の候補。macOS の SF Pro が代表
/// （4 軸 wdth/opsz/GRAD/wght + gvar + HVAR。TASK-25.15 の VF スタックのデモ）。
const var_font_paths = [_][]const u8{
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/SFNSRounded.ttf",
    "C:/Windows/Fonts/segoeui.ttf", // 新しめの Windows では VF 版がある
    "/usr/share/fonts/truetype/noto/NotoSans-VariableFont_wdth,wght.ttf",
};

/// 各候補を read→FontFace.init し、fvar を持つ最初のものを返す（無ければ null → VF 段はスキップ）。
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

    // フォント bytes は FontFace より長命であること（main 寿命で保持）。
    const loaded = fontmod.loadSystemTextFace(init.io, allocator);
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

    // 可変フォント段（fvar を持つ system フォントがあれば wght 別に描画）
    const var_loaded = loadVarFace(init.io, allocator);
    defer if (var_loaded) |l| allocator.free(l.bytes);
    var var_face: ?fontmod.FontFace = if (var_loaded) |l| l.face else null;
    const var_weights = [_]f32{ 100, 400, 700, 900 };
    var var_fonts: [var_weights.len]?fontmod.OutlineFont = .{null} ** var_weights.len;
    if (var_face) |*vf| {
        const wght_tag = [4]u8{ 'w', 'g', 'h', 't' };
        for (&var_fonts, var_weights) |*of, w| {
            var o = fontmod.OutlineFont.init(allocator, vf, 40);
            // 軸 set 失敗（wght 軸なし等）はその weight 行だけスキップ
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

            if (fonts[0]) |*big| big.asFont().drawTo(target, .{ .x = 24, .y = 24 }, "Outline Font (TTF)", white, clip);
            if (fonts[1]) |*mid| mid.asFont().drawTo(target, .{ .x = 24, .y = 96 }, "The quick brown fox jumps over the lazy dog.", cyan, clip);
            if (fonts[0]) |*big| big.asFont().drawTo(target, .{ .x = 24, .y = 230 }, "こんにちは 世界 ABC 123", white, clip);
            if (fonts[2]) |*small| {
                small.asFont().drawTo(target, .{ .x = 24, .y = 150 }, "abcdefghijklmnopqrstuvwxyz 0123456789 !?@#&", white, clip);
                small.asFont().drawTo(target, .{ .x = 24, .y = 180 }, "ESC to quit. Glyphs are rasterized on demand and cached.", cyan, clip);
                small.asFont().drawTo(target, .{ .x = 24, .y = 300 }, "日本語: ひらがな カタカナ 漢字（CFF/.ttc）", cyan, clip);
            }

            // 可変フォント段: 同一 face から wght 100/400/700/900（fvar/avar/gvar/HVAR 経路）
            if (var_face != null) {
                if (fonts[2]) |*small| small.asFont().drawTo(target, .{ .x = 24, .y = 340 }, "Variable font (fvar/gvar): wght 100 / 400 / 700 / 900", cyan, clip);
                const labels = [_][]const u8{ "Thin 100", "Regular 400", "Bold 700", "Black 900" };
                var vy: i32 = 370;
                for (&var_fonts, labels) |*of, label| {
                    if (of.*) |*o| o.asFont().drawTo(target, .{ .x = 24, .y = vy }, label, white, clip);
                    vy += 52;
                }
            }

            window.present();
        }

        platform.frameDelay(16_666_666);
    }
}
