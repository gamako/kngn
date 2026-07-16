//! 21_char_input: TASK-22 の `char_input`（確定テキスト文字。UTF-32 codepoint）を単体で確認する
//! 最小サンプル。pixie の rename や capture demo に混ぜず「文字入力だけ」を見られる vehicle で、
//! 全 backend（macOS objc/swift/metal・Linux x11/wayland・Windows gdi/d3d11）の char_input 発火を
//! 実機で目視確認する土台にする（Windows・Linux x11/wayland にも流用）。
//!
//! フォントは **OS のシステムフォントをランタイム読込**する（example_12 と同じ方式。日本語 .ttc を
//! 優先し ASCII も 1 本で混在描画。再配布でないので repo にアセットを持たず・ネットワーク取得も不要）。
//! フォント自体は日本語グリフを持つので、char_input で**届いた** codepoint は日本語も描画できる。
//!
//! **IME（TASK-79.6.1）**: macOS は view を NSTextInputClient 化し、keyDown を
//! `interpretKeyEvents:` 経由で insertText → `char_input` に流す（確定日本語が入る）。
//! 変換中 preedit の inline 描画は 79.6.2。harness は `inject commit <text>` で確定列を
//! codepoint 分解注入できる（`inject char` と同経路）。
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

/// 入力状態（`chars` probe の ctx）。buf は UTF-8。改行は '\n' をそのまま格納し描画側で分割する。
const State = struct {
    buf: [MAX_BYTES]u8 = undefined,
    len: usize = 0,
    last_cp: u32 = 0,
    last_mods: u32 = 0,

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
            // 印字は char_input 経由（日本語含む確定文字）。key_down は制御キーのみ。
            .char_input => |ch| state.appendCodepoint(ch.codepoint, ch.modifiers.toC()),
            else => {},
        };

        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, 0xFF14141E);

            const fbh_i32: i32 = @intCast(fb.height);
            const target = fontmod.RenderTarget{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
            const clip = fontmod.Rect{ .x = 0, .y = 0, .w = fb.width, .h = fb.height };

            if (of) |*o| {
                const f = o.asFont();
                const lh: i32 = @intCast(f.metrics().line_height);

                f.drawTo(target, .{ .x = 8, .y = 8 }, "char_input demo: type ASCII / BACKSPACE / ENTER / ESC quit", gray, clip);
                f.drawTo(target, .{ .x = 8, .y = 8 + lh }, "(IME: 変換→確定で日本語。preedit 下線は 79.6.2。inject commit 可)", gray, clip);

                // 入力テキスト（'\n' で行分割）。末尾に静的キャレット '_'（blink しない＝決定的）。
                const text_top: i32 = 8 + lh * 2;
                var y: i32 = text_top;
                var last_line: []const u8 = "";
                var last_y: i32 = text_top;
                var it = std.mem.splitScalar(u8, state.buf[0..state.len], '\n');
                while (it.next()) |line| {
                    f.drawTo(target, .{ .x = 8, .y = y }, line, green, clip);
                    last_line = line;
                    last_y = y;
                    y += lh;
                }
                const caret_x: i32 = 8 + @as(i32, @intCast(f.measure(last_line)));
                f.drawTo(target, .{ .x = caret_x, .y = last_y }, "_", green, clip);

                // 直近の codepoint / modifier（非 ASCII でも受信を数値で確認できる）。
                var dbg: [80]u8 = undefined;
                const dbg_str = std.fmt.bufPrint(&dbg, "last: U+{X:0>4}  mods=0x{X}  bytes={d}", .{ state.last_cp, state.last_mods, state.len }) catch "last: ?";
                f.drawTo(target, .{ .x = 8, .y = fbh_i32 - 28 }, dbg_str, cyan, clip);
            }

            window.present();
        }

        platform.frameDelay(16_666_666);
    }
}
