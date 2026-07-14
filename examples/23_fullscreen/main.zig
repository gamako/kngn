const std = @import("std");
const platform = @import("platform");

/// 23_fullscreen: `platform.Window.createFullscreen` の実 caller & デモ（TASK-100）。
///
/// 画面全域を animated 縦グラデーションで塗り、ESC / Q または quit で終了する。
/// `createFullscreen` は backend が対応していれば本物のフルスクリーン（X11=EWMH
/// `_NET_WM_STATE_FULLSCREEN` / Wayland=`xdg_toplevel_set_fullscreen`）、非対応 backend
/// （macOS/Windows）は 1920x1080 の通常ウィンドウへフォールバックする。実際の解像度は
/// `fb.width`/`fb.height`（フルスクリーン時は compositor/画面解像度）に追従する。
///
/// ホットパス宣言: フレーム毎に全画素を塗るが、色は **行ごとに 1 回**計算し（縦グラデーション）
/// 行スライスを `@memset` で一括書き込みする。per-pixel の除算・浮動小数点は使わず（`/denom` は
/// per-row = O(height)）、行連続（row-major）アクセス・行頭オフセットはループ内 `y*w` で算出する。
/// 性能規約「全画素ループ」の `@memset` 高速パス方針に沿う（新規の per-pixel 除算/分岐なし）。
pub fn main() !void {
    try platform.init();
    defer platform.shutdown();

    var window = platform.Window.createFullscreen("23: Fullscreen Demo") catch |err| {
        std.debug.print("Failed to create fullscreen window: {s}\n", .{@errorName(err)});
        return;
    };
    defer window.destroy();

    std.debug.print("Fullscreen demo running. Press ESC or Q to exit.\n", .{});

    var frame: u32 = 0;
    var reported = false;

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| {
                if (k.key == .ESCAPE or k.key == .Q) break :main_loop;
            },
            else => {},
        };

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            const w = fb.width;
            const h = fb.height;
            if (!reported) {
                // フルスクリーンで得られた実解像度を 1 回だけ報告（画面サイズに追従したことの確認用）。
                std.debug.print("Fullscreen framebuffer: {d}x{d}\n", .{ w, h });
                reported = true;
            }
            // 時間で青成分をドリフトさせ、静止画でなく「生きている」ことを示す。
            const phase: u32 = frame *% 2;
            const denom: u32 = if (h > 1) h - 1 else 1;
            var y: u32 = 0;
            while (y < h) : (y += 1) {
                const v: u32 = (y *% 255) / denom; // 縦位置 0..255（per-row。per-pixel ではない）
                const r: u32 = v;
                const g: u32 = 255 - v;
                // 青は (v+phase) の三角波（0→255→0）。単純な `&0xFF` ラップだと 255→0 の段差が
                // 継ぎ目に見えるが、三角波は折り返しが連続なので継ぎ目が出ない（下方向へ滑らかに流れる）。
                const s: u32 = (v +% phase) & 0xFF;
                const b: u32 = if (s < 128) s *% 2 else (255 - s) *% 2;
                // canonical BGRA(0xAARRGGBB): A=FF, R, G, B（examples/01 と同じパッキング）。
                const color: u32 = 0xFF00_0000 | (r << 16) | (g << 8) | b;
                const row_start: usize = @as(usize, y) * w; // usize 積算で理論上の u32 オーバーフローを排除
                @memset(fb.pixels[row_start .. row_start + w], color);
            }
            window.present();
        }

        frame +%= 1;
        platform.frameDelay(16_666_666);
    }

    std.debug.print("Fullscreen demo terminated.\n", .{});
}
