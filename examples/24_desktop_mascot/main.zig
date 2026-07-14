const std = @import("std");
const platform = @import("platform");
const png = @import("png");

/// 24_desktop_mascot: 透過 / borderless ウィンドウのデモ（TASK-104）。
///
/// うさこ（usako.png, 64x64 RGBA）をデスクトップ上に「枠なし・背景透過・常に最前面」で表示する
/// デスクトップマスコット。透明な余白へのクリックは背後のアプリへ抜け（per-pixel click-through）、
/// うさこ本体を左ドラッグするとウィンドウごと移動する（OS の対話的ドラッグへ委譲）。右クリックで
/// 終了メニュー、ESC でも終了する。
///
/// 使う platform 拡張（TASK-104）:
/// - `Window.createWithOptions(.{ .transparent = true, .borderless = true })`: 透過 + 枠なし
/// - `platform.setDockVisible(false)`: Dock アイコン / メニューバー非表示（常駐アプリらしく）
/// - `window.setAlwaysOnTop(true)`: 常に最前面
/// - `window.setClickThrough(true)`: 透明画素上のクリックを背後へ抜けさせる
/// - `window.beginDrag()`: 本体 mouse_down からウィンドウ移動を開始
/// - `window.showQuitMenu()`: 終了メニューをポップアップ
///
/// ホットパス宣言: フレーム毎に全画素（64x64=4096px）を書くが、静的画像の premultiplied バッファを
/// `@memcpy` で一括コピーするだけ（per-pixel の除算・分岐・ブレンドなし）。premultiply は
/// `decodePNGPremultiplied` で初期化時に 1 回だけ行う。性能規約「全画素ループ」の一括書き込み方針に沿う。
const usako_png = @embedFile("image/usako.png");

const MASCOT_W: u32 = 64;
const MASCOT_H: u32 = 64;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try platform.init();
    defer platform.shutdown();

    // 透過 + borderless ウィンドウ（背後が透け、枠・タイトルバーなし）。
    var window = platform.Window.createWithOptions(
        MASCOT_W,
        MASCOT_H,
        "usako",
        .{ .transparent = true, .borderless = true },
    ) catch |err| {
        std.debug.print("Failed to create mascot window: {s}\n", .{@errorName(err)});
        return;
    };
    defer window.destroy();

    // マスコットらしい挙動: Dock 非表示・最前面・透明部クリック透過。
    platform.setDockVisible(false);
    window.setAlwaysOnTop(true);
    window.setClickThrough(true);

    // うさこを premultiplied alpha でデコード（透過 CGImage の PremultipliedFirst と整合）。
    // 透明な余白は 0x00000000（A=0, premul RGB=0）で、そのまま透過表示になる。
    var usako = try png.decodePNGPremultiplied(allocator, usako_png);
    defer usako.deinit(allocator);

    std.debug.print("usako mascot running. Drag body to move / right-click or ESC to quit.\n", .{});

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| {
                if (k.key == .ESCAPE) break :main_loop;
            },
            .mouse_down => |m| switch (m.button) {
                // 本体（不透明画素）上の左押下だけがここに届く（透明部は click-through で抜ける）。
                // → OS の対話的ウィンドウ移動を開始（うさこを掴んで動かす）。
                .left => window.beginDrag(),
                // 右クリックで終了メニュー。
                .right => window.showQuitMenu(),
                else => {},
            },
            else => {},
        };

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            // 背景は完全透明（0x00000000）。うさこの premultiplied バッファをそのまま転写する。
            if (fb.width == usako.width and fb.height == usako.height and
                fb.pixels.len == usako.pixels.len)
            {
                @memcpy(fb.pixels, usako.pixels);
            } else {
                // サイズ不一致（HiDPI 等で fb がスケールした場合の保険）: 透明で埋めて中央へ収まる分だけ転写。
                @memset(fb.pixels, 0x0000_0000);
                const cw = @min(fb.width, usako.width);
                const ch = @min(fb.height, usako.height);
                var y: u32 = 0;
                while (y < ch) : (y += 1) {
                    const dst = fb.pixels[@as(usize, y) * fb.width ..][0..cw];
                    const src = usako.pixels[@as(usize, y) * usako.width ..][0..cw];
                    @memcpy(dst, src);
                }
            }
            window.present();
        }

        platform.frameDelay(16_666_666);
    }

    std.debug.print("usako mascot terminated.\n", .{});
}
