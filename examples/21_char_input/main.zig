//! 21_char_input: minimal sample that checks `char_input` alone (committed text characters as UTF-32 codepoints).
//! A vehicle for "text input only" without mixing in pixie rename or the capture demo, and a base for
//! visually confirming char_input on every backend (macOS objc/swift/metal, Linux x11/wayland, Windows gdi/d3d11)
//! on real hardware (also reusable on Windows and Linux x11/wayland).
//!
//! The font is an **OS system font loaded at runtime** (same approach as example_12. Prefer a Japanese .ttc so
//! ASCII and Japanese mix in one face. Not redistributed, so no repo asset and no network fetch).
//! The font itself has Japanese glyphs, so Japanese codepoints that **arrive** via char_input also draw.
//!
//! **IME**: on macOS the view is an NSTextInputClient; committed characters go to `char_input`, and
//! in-progress conversion is drawn as an underlined inline composition snapshot. The harness can
//! verify the same state contract with `inject composition update/cancel` and `inject commit <text>`.
//!
//! Controls: type = append via `char_input` / BACKSPACE = delete one codepoint /
//!       ENTER = newline / ESC = quit.
//!   - **Printing uses `char_input` only** (not physical `key_down` keys or `keyboard.getCharFromKey`,
//!     which is limited to A-Z/0-9 and cannot emit Japanese). Only ESC/BACKSPACE/ENTER controls use `key_down`.
//!
//! harness: `inject char <cp>` injects characters headlessly; the `chars` probe (digest) asserts
//!   len/last_cp/last_mods; `snapshot fb` is for visual check (deterministic).
//!
//! Hot path declaration: state updates are **event-only** (keystrokes). Text drawing is the existing per-frame
//!   font path; no new all-pixel loop. Outside the performance-rules (SIMD three-point set etc.) scope.

const std = @import("std");
const platform = @import("platform");
const fontmod = @import("font");

const FRAME_PERIOD_S: f64 = 1.0 / 60.0;

const MAX_BYTES = 512;
const COMPOSITION_BYTES = 1024;

const CompositionCaretRect = struct { x: i32, y: i32, w: i32, h: i32 };

/// Input state (`chars` probe ctx). buf is UTF-8. Newlines store a literal LF and the drawer splits on it.
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

    /// Append a `char_input` codepoint as UTF-8. Ignore control characters (should not arrive on char_input, but
    /// defended) and capacity overflow (fail-safe: a drop must not crash).
    fn appendCodepoint(self: *State, cp: u32, mods: u32) void {
        self.last_cp = cp;
        self.last_mods = mods;
        if (cp < 0x20 or cp == 0x7F) return;
        if (cp > std.math.maxInt(u21)) return;
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cp), &enc) catch return; // Ignore invalid / surrogates etc.
        if (self.len + n > self.buf.len) return;
        @memcpy(self.buf[self.len..][0..n], enc[0..n]);
        self.len += n;
    }

    /// Delete the previous codepoint (walk back UTF-8 continuation bytes safely).
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

/// `chars` probe: top-level numeric k=v only (assertable as `expect chars last_cp=12354` etc.).
/// Raw text may contain newlines, so it is not put on the digest (protects the one-line wire framing).
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

    // Font bytes must outlive FontFace (held for main's lifetime).
    const loaded = fontmod.loadSystemTextFace(init.io, allocator);
    defer if (loaded) |l| allocator.free(l.bytes);
    if (loaded == null) std.debug.print("no usable system font found; text will not render (chars probe still works).\n", .{});
    var face: ?fontmod.FontFace = if (loaded) |l| l.face else null;
    var of: ?fontmod.OutlineFont = if (face) |*f| fontmod.OutlineFont.init(allocator, f, 22) else null;
    defer if (of) |*o| o.deinit();

    var state: State = .{};
    // No-op when harness is disabled (does not affect normal runs).
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
        const frame_t0 = platform.getTime();
        defer platform.framePaceUntil(frame_t0 + FRAME_PERIOD_S);

        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| switch (k.key) {
                .ESCAPE => break :main_loop,
                .BACKSPACE => state.backspace(),
                .ENTER, .KP_ENTER => state.newline(),
                else => {},
            },
            .composition_changed => state.composition_dirty = true,
            // Printing goes through char_input (committed characters including Japanese). key_down is control keys only.
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
                f.drawTo(target, .{ .x = 8, .y = 8 + lh }, "(IME: 変換→確定で日本語。preedit 下線あり。inject commit 可)", gray, clip, 1.0);

                // Input text (split on LF). Static caret '_' at the end (no blink = deterministic).
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
                    // Underline sits just under the baseline (ascent+2). At the bottom of the line box (lh-2) it floats
                    // below descent+gap. Clamp with lh-1 so it stays inside the line.
                    const underline_y = @min(last_y + @as(i32, @intCast(f.metrics().ascent)) + 2, last_y + lh - 1);
                    var ux = caret_x;
                    while (ux < caret_x + preedit_w) : (ux += 1) {
                        fontmod.plotCoverage(target, ux, underline_y, cyan, 0xFF, clip);
                    }
                    const cursor_prefix = preedit[0..@min(state.preedit_cursor, preedit.len)];
                    caret_x += @intCast(f.measure(cursor_prefix));
                }
                f.drawTo(target, .{ .x = caret_x, .y = last_y }, "_", green, clip, 1.0);
                // The rect always points at the caret regardless of preedit, so the correct position is already
                // supplied at the handleEvent of the keystroke that starts composition.
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

                // Latest codepoint / modifiers (non-ASCII receipt is still visible as numbers).
                var dbg: [80]u8 = undefined;
                const dbg_str = std.fmt.bufPrint(&dbg, "last: U+{X:0>4}  mods=0x{X}  bytes={d}", .{ state.last_cp, state.last_mods, state.len }) catch "last: ?";
                f.drawTo(target, .{ .x = 8, .y = fbh_i32 - 28 }, dbg_str, cyan, clip, 1.0);
            }

            window.present();
        }
    }
}
