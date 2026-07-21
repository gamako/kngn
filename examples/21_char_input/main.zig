//! 21_char_input: TASK-22 の `char_input`（確定テキスト文字。UTF-32 codepoint）を単体で確認する
//! 最小サンプル。pixie の rename や capture demo に混ぜず「文字入力だけ」を見られる vehicle で、
//! 全 backend（macOS objc/swift/metal・Linux x11/wayland・Windows gdi/d3d11）の char_input 発火を
//! 実機で目視確認する土台にする（Windows・Linux x11/wayland にも流用）。
//!
//! フォントは **OS のシステムフォントをランタイム読込**する（example_12 と同じ方式。日本語 .ttc を
//! 優先し ASCII も 1 本で混在描画。再配布でないので repo にアセットを持たず・ネットワーク取得も不要）。
//! フォント自体は日本語グリフを持つので、char_input で**届いた** codepoint は日本語も描画できる。
//!
//! **IME（TASK-79.6.2）**: macOS は view を NSTextInputClient 化し、確定文字を `char_input`、
//! 変換中は composition snapshot を下線付き inline で描画する。harness は
//! `inject composition update/cancel` と `inject commit <text>` で同じ状態契約を検証できる。
//!
//! 操作: 文字をタイプ＝`char_input` でバッファ追記 / BACKSPACE=1 コードポイント削除 /
//!       ENTER=改行 / ESC=終了。
//!   - **印字は `char_input` のみで行う**（`key_down` の物理キーや `keyboard.getCharFromKey` は使わない。
//!     後者は A-Z/0-9 に限られ日本語が出せないため）。ESC/BACKSPACE/ENTER の制御だけ `key_down` で見る。
//!
//! harness: `inject char <cp>` で headless に文字を注入でき、`chars` probe（digest）で
//!   len/last_cp/last_mods を assert、`snapshot fb` で表示を目視できる（決定的）。
//!
//! ホットパス宣言: 状態更新は**イベント時のみ**（打鍵）。テキスト描画は既存 font 経路の毎フレーム
//!   描画で、新規の全画素ループは作らない。性能規約（SIMD 3 点セット等）の適用対象外。

const std = @import("std");
const platform = @import("platform");
const fontmod = @import("font");

const MAX_BYTES = 512;
const COMPOSITION_BYTES = 1024;

const CompositionCaretRect = struct { x: i32, y: i32, w: i32, h: i32 };

/// 入力状態（`chars` probe の ctx）。buf は UTF-8。改行は '\n' をそのまま格納し描画側で分割する。
const State = struct {
    buf: [MAX_BYTES]u8 = undefined,
    len: usize = 0,
    last_cp: u32 = 0,
    last_mods: u32 = 0,
    preedit: [COMPOSITION_BYTES]u8 = undefined,
    preedit_len: usize = 0,
    preedit_cursor: usize = 0,
    composition_dirty: bool = false,
    composition_rect: ?CompositionCaretRect = null,

    /// `char_input` の codepoint を UTF-8 で追記する。制御文字（本来 char_input には来ない想定だが
    /// 防御）と容量超過は無視（fail-safe: 取りこぼしがあってもクラッシュしない）。
    fn appendCodepoint(self: *State, cp: u32, mods: u32) void {
        self.last_cp = cp;
        self.last_mods = mods;
        if (cp < 0x20 or cp == 0x7F) return;
        if (cp > std.math.maxInt(u21)) return;
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cp), &enc) catch return; // 不正/サロゲート等は無視
        if (self.len + n > self.buf.len) return;
        @memcpy(self.buf[self.len..][0..n], enc[0..n]);
        self.len += n;
    }

    /// 直前の 1 コードポイントを削除（UTF-8 継続バイトを遡って安全に削る）。
    fn backspace(self: *State) void {
        if (self.len == 0) return;
        var i = self.len - 1;
        while (i > 0 and (self.buf[i] & 0xC0) == 0x80) : (i -= 1) {}
        self.len = i;
    }

    fn newline(self: *State) void {
        if (self.len + 1 > self.buf.len) return;
        self.buf[self.len] = '\n';
        self.len += 1;
    }

    fn syncComposition(self: *State, window: platform.Window) void {
        if (!self.composition_dirty) return;
        const snapshot = window.getCompositionSnapshot(self.preedit[0..]);
        self.preedit_len = snapshot.text.len;
        self.preedit_cursor = @min(@as(usize, snapshot.cursor), self.preedit_len);
        self.composition_dirty = false;
    }
};

/// `chars` probe: 数値のみの top-level k=v（`expect chars last_cp=12354` 等で assert 可能）。
/// 生テキストは改行を含みうるので digest には出さない（1 行契約の wire framing 保護）。
fn charsDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const st: *State = @ptrCast(@alignCast(ctx));
    return std.fmt.bufPrint(buf, "len={d} last_cp={d} last_mods={d}", .{ st.len, st.last_cp, st.last_mods }) catch buf[0..0];
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(900, 600, "21: char_input demo");
    defer window.destroy();

    // フォント bytes は FontFace より長命であること（main 寿命で保持）。
    const loaded = fontmod.loadSystemTextFace(init.io, allocator);
    defer if (loaded) |l| allocator.free(l.bytes);
    if (loaded == null) std.debug.print("no usable system font found; text will not render (chars probe still works).\n", .{});
    var face: ?fontmod.FontFace = if (loaded) |l| l.face else null;
    var of: ?fontmod.OutlineFont = if (face) |*f| fontmod.OutlineFont.init(allocator, f, 22) else null;
    defer if (of) |*o| o.deinit();

    var state: State = .{};
    // harness 無効時は no-op（通常実行に影響しない）。
    platform.registerProbe(.{
        .name = "chars",
        .ctx = &state,
        .ext = "txt",
        .digest = charsDigest,
        .desc = "typed char_input buffer: len / last codepoint / modifiers",
    });

    const gray = fontmod.Color.rgba(0xAA, 0xAA, 0xAA, 0xFF);
    const green = fontmod.Color.rgba(0x88, 0xFF, 0x88, 0xFF);
    const cyan = fontmod.Color.rgba(0x66, 0xCC, 0xFF, 0xFF);

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| switch (k.key) {
                .ESCAPE => break :main_loop,
                .BACKSPACE => state.backspace(),
                .ENTER, .KP_ENTER => state.newline(),
                else => {},
            },
            .composition_changed => state.composition_dirty = true,
            // 印字は char_input 経由（日本語含む確定文字）。key_down は制御キーのみ。
            .char_input => |ch| state.appendCodepoint(ch.codepoint, ch.modifiers.toC()),
            else => {},
        };

        state.syncComposition(window);

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, 0xFF14141E);

            const fbh_i32: i32 = @intCast(fb.height);
            const target = fontmod.RenderTarget{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
            const clip = fontmod.Rect{ .x = 0, .y = 0, .w = fb.width, .h = fb.height };

            if (of) |*o| {
                const f = o.asFont();
                const lh: i32 = @intCast(f.metrics().line_height);

                f.drawTo(target, .{ .x = 8, .y = 8 }, "char_input demo: type ASCII / BACKSPACE / ENTER / ESC quit", gray, clip, 1.0);
                f.drawTo(target, .{ .x = 8, .y = 8 + lh }, "(IME: 変換→確定で日本語。preedit 下線は 79.6.2。inject commit 可)", gray, clip, 1.0);

                // 入力テキスト（'\n' で行分割）。末尾に静的キャレット '_'（blink しない＝決定的）。
                const text_top: i32 = 8 + lh * 2;
                var y: i32 = text_top;
                var last_line: []const u8 = "";
                var last_y: i32 = text_top;
                var it = std.mem.splitScalar(u8, state.buf[0..state.len], '\n');
                while (it.next()) |line| {
                    f.drawTo(target, .{ .x = 8, .y = y }, line, green, clip, 1.0);
                    last_line = line;
                    last_y = y;
                    y += lh;
                }
                var caret_x: i32 = 8 + @as(i32, @intCast(f.measure(last_line)));
                if (state.preedit_len > 0) {
                    const preedit = state.preedit[0..state.preedit_len];
                    f.drawTo(target, .{ .x = caret_x, .y = last_y }, preedit, cyan, clip, 1.0);
                    const preedit_w: i32 = @intCast(f.measure(preedit));
                    // 下線は baseline 直下（ascent+2）。行ボックス最下端（lh-2）だと descent+gap の
                    // 下に浮いて見える（実機指摘 2026-07-17）。行内に収まるよう lh-1 で clamp。
                    const underline_y = @min(last_y + @as(i32, @intCast(f.metrics().ascent)) + 2, last_y + lh - 1);
                    var ux = caret_x;
                    while (ux < caret_x + preedit_w) : (ux += 1) {
                        fontmod.plotCoverage(target, ux, underline_y, cyan, 0xFF, clip);
                    }
                    const cursor_prefix = preedit[0..@min(state.preedit_cursor, preedit.len)];
                    caret_x += @intCast(f.measure(cursor_prefix));
                }
                f.drawTo(target, .{ .x = caret_x, .y = last_y }, "_", green, clip, 1.0);
                // rect は preedit の有無に関係なく常に caret を指す（composition 開始打鍵の
                // handleEvent 時点で正しい位置が既に供給されているように。実機指摘 2026-07-17）。
                {
                    const rect = CompositionCaretRect{ .x = caret_x, .y = last_y, .w = 1, .h = lh };
                    if (state.composition_rect == null or
                        state.composition_rect.?.x != rect.x or
                        state.composition_rect.?.y != rect.y or
                        state.composition_rect.?.w != rect.w or
                        state.composition_rect.?.h != rect.h)
                    {
                        window.setCompositionRect(rect.x, rect.y, rect.w, rect.h);
                        state.composition_rect = rect;
                    }
                }

                // 直近の codepoint / modifier（非 ASCII でも受信を数値で確認できる）。
                var dbg: [80]u8 = undefined;
                const dbg_str = std.fmt.bufPrint(&dbg, "last: U+{X:0>4}  mods=0x{X}  bytes={d}", .{ state.last_cp, state.last_mods, state.len }) catch "last: ?";
                f.drawTo(target, .{ .x = 8, .y = fbh_i32 - 28 }, dbg_str, cyan, clip, 1.0);
            }

            window.present();
        }

        platform.frameDelay(16_666_666);
    }
}
