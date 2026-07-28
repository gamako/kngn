//! 28_text_input: single-line TextInput demo for focus / UTF-8 edit / selection / scroll / IME.
//!
//! Hot path declaration: edit / caret / selection / scroll are event-only. While composition is active,
//! reread the composition snapshot every frame (latest-wins; avoids a stale preedit if an event is dropped).
//! Preedit draw reuses the existing DrawCmd and Font paths; caret blink is decided from Context virtual time alone.
//! Composition text borrows a fixed buffer (no heap alloc).

const std = @import("std");
const platform = @import("platform");
const gui = @import("gui");
const fontmod = @import("font");

const COMPOSITION_BYTES = 1024;

const CompositionCaretRect = struct { x: i32, y: i32, w: i32, h: i32 };

fn buttonToU8(b: platform.MouseButton) u8 {
    return switch (b) {
        .left => 0,
        .right => 1,
        .middle => 2,
        else => 0xFF,
    };
}

fn toGuiEvent(ev: platform.Event) ?gui.InputEvent {
    return switch (ev) {
        .quit, .gamepad_connected, .gamepad_disconnected, .composition_changed, .menu_command => null,
        .file_drop => null,
        .mouse_move => |m| .{ .mouse_move = .{ .x = m.x, .y = m.y, .modifiers = m.modifiers.toC() } },
        .mouse_down => |m| .{ .mouse_down = .{ .x = m.x, .y = m.y, .button = buttonToU8(m.button), .modifiers = m.modifiers.toC() } },
        .mouse_up => |m| .{ .mouse_up = .{ .x = m.x, .y = m.y, .button = buttonToU8(m.button), .modifiers = m.modifiers.toC() } },
        .mouse_scroll => |s| .{ .mouse_scroll = .{ .x = s.x, .y = s.y, .dx = s.dx, .dy = s.dy, .modifiers = s.modifiers.toC() } },
        .char_input => |ch| .{ .char_input = .{ .codepoint = ch.codepoint, .modifiers = ch.modifiers.toC() } },
        .key_down => |k| blk: {
            const code = @intFromEnum(k.key);
            if (code < 0) break :blk null;
            break :blk .{ .key_down = .{ .code = @intCast(code), .modifiers = k.modifiers.toC(), .repeat = k.is_repeat } };
        },
        .key_up => |k| blk: {
            const code = @intFromEnum(k.key);
            if (code < 0) break :blk null;
            break :blk .{ .key_up = .{ .code = @intCast(code), .modifiers = k.modifiers.toC() } };
        },
    };
}

const InputProbe = struct {
    focus: u32 = 0,
    len: usize = 0,
    caret: usize = 0,
    selection_start: usize = 0,
    selection_end: usize = 0,
    scroll: i32 = 0,
    preedit_active: u32 = 0,
    preedit_len: usize = 0,
    preedit_cursor: usize = 0,

    fn update(self: *InputProbe, buffer: *const gui.TextBuffer, result: gui.TextInputResult, caret: usize) void {
        self.focus = if (result.focused) 1 else 0;
        self.len = buffer.slice().len;
        self.caret = caret;
        self.selection_start = result.selection.start;
        self.selection_end = result.selection.end;
    }

    fn digest(ctx: *anyopaque, buf: []u8) []const u8 {
        const self: *const InputProbe = @ptrCast(@alignCast(ctx));
        return std.fmt.bufPrint(buf, "focus={d} len={d} caret={d} selection={d}:{d} scroll={d} preedit_active={d} preedit_len={d} preedit_cursor={d}", .{
            self.focus,
            self.len,
            self.caret,
            self.selection_start,
            self.selection_end,
            self.scroll,
            self.preedit_active,
            self.preedit_len,
            self.preedit_cursor,
        }) catch buf[0..0];
    }
};

const CopyProbe = struct {
    count: u32 = 0,
    bytes: usize = 0,

    fn digest(ctx: *anyopaque, buf: []u8) []const u8 {
        const self: *const CopyProbe = @ptrCast(@alignCast(ctx));
        return std.fmt.bufPrint(buf, "count={d} bytes={d}", .{ self.count, self.bytes }) catch buf[0..0];
    }
};

const ImeState = struct {
    preedit: [COMPOSITION_BYTES]u8 = undefined,
    preedit_len: usize = 0,
    preedit_cursor: usize = 0,
    active: bool = false,
    dirty: bool = false,
    last_phase: platform.CompositionPhase = .cancel,
    composition_rect: ?CompositionCaretRect = null,

    fn syncFromWindow(self: *ImeState, window: platform.Window) void {
        // On dirty (composition_changed) or while active, reread the snapshot every frame.
        // text/cursor are always latest-wins. Avoids a stale preedit if an event is dropped.
        //
        // Known residual limit (no fix needed): if the commit/cancel event itself is dropped, clearing the active
        // flag is undetectable because CompositionSnapshot has no active bit
        // (same constraint as example_21; a future platform-side concern).
        if (!self.dirty and !self.active) return;
        const snapshot = window.getCompositionSnapshot(self.preedit[0..]);
        self.preedit_len = snapshot.text.len;
        self.preedit_cursor = @min(@as(usize, snapshot.cursor), self.preedit_len);
        if (self.dirty) {
            self.active = switch (self.last_phase) {
                .start, .update => true,
                .commit, .cancel => false,
            };
            self.dirty = false;
        }
    }

    fn guiState(self: *const ImeState) gui.CompositionState {
        return .{
            .active = self.active,
            .text = self.preedit[0..self.preedit_len],
            .cursor = self.preedit_cursor,
        };
    }
};

fn notifyCompositionRect(window: platform.Window, state: *ImeState, rect: ?CompositionCaretRect) void {
    const next = rect orelse CompositionCaretRect{ .x = 0, .y = 0, .w = 0, .h = 0 };
    if (state.composition_rect) |prev| {
        if (prev.x == next.x and prev.y == next.y and prev.w == next.w and prev.h == next.h) return;
    } else if (next.w == 0 and next.h == 0) {
        // First-time clear is unnecessary (candidate window also not shown yet)
        state.composition_rect = next;
        return;
    }
    window.setCompositionRect(next.x, next.y, next.w, next.h);
    state.composition_rect = next;
}

/// Bridge that supplies the focused TextInput document to IME.
const DocBridge = struct {
    buffer: *gui.TextBuffer,
    selection: *gui.SelectionState,
    caret: *usize,
    max_len: ?usize = null,

    fn getSelectedRange(ud: *anyopaque) ?platform.TextInputRange {
        const self: *DocBridge = @ptrCast(@alignCast(ud));
        const r = self.buffer.selectedRangeUtf16(self.selection.*);
        return .{ .location = r.location, .length = r.length };
    }

    fn getSubstring(ud: *anyopaque, proposed: platform.TextInputRange) ?platform.TextInputSubstring {
        const self: *DocBridge = @ptrCast(@alignCast(ud));
        const sub = self.buffer.substringForUtf16Range(.{
            .location = proposed.location,
            .length = proposed.length,
        }) orelse return null;
        return .{
            .utf8 = sub.utf8,
            .actual_range = .{ .location = sub.actual_range.location, .length = sub.actual_range.length },
        };
    }

    fn replaceText(ud: *anyopaque, range: platform.TextInputRange, utf8: []const u8) bool {
        const self: *DocBridge = @ptrCast(@alignCast(ud));
        return self.buffer.replaceUtf16RangeAndCollapseCaret(
            self.selection,
            self.caret,
            .{ .location = range.location, .length = range.length },
            utf8,
            self.max_len,
        ) catch false;
    }
};

const doc_callbacks = platform.TextInputDocumentCallbacks{
    .getSelectedRange = DocBridge.getSelectedRange,
    .getSubstring = DocBridge.getSubstring,
    .replaceText = DocBridge.replaceText,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(640, 360, "example_28: text input");
    defer window.destroy();

    var first_buffer = try gui.TextBuffer.init(gpa, "");
    defer first_buffer.deinit();
    var second_buffer = try gui.TextBuffer.init(gpa, "A long second input demonstrates horizontal caret scrolling");
    defer second_buffer.deinit();

    // KNGN_EXAMPLE_28_FONT=bitmap|outline. Unset means outline (bit-identical to current).
    const font_mode = if (std.c.getenv("KNGN_EXAMPLE_28_FONT")) |v| std.mem.span(v) else "outline";
    const prefer_bitmap = std.mem.eql(u8, font_mode, "bitmap");

    // Font bytes must outlive FontFace (kept for main's lifetime).
    const loaded = if (prefer_bitmap) null else fontmod.loadSystemTextFace(init.io, gpa);
    defer if (loaded) |l| gpa.free(l.bytes);
    if (!prefer_bitmap and loaded == null) std.debug.print("no usable system font found; falling back to gui.default_font.\n", .{});
    var face: ?fontmod.FontFace = if (loaded) |l| l.face else null;
    // Pixel size matched to gui.default_font line_height=16.
    var outline_font: ?fontmod.OutlineFont = if (face) |*f| fontmod.OutlineFont.init(gpa, f, 16) else null;
    defer if (outline_font) |*o| o.deinit();

    const app_font = if (prefer_bitmap)
        gui.default_font
    else if (outline_font) |*o|
        o.asFont()
    else
        gui.default_font;
    var ctx = gui.Context.init(gpa, app_font);
    defer ctx.deinit();

    var input_probe: InputProbe = .{};
    var copy_probe: CopyProbe = .{};
    var ime: ImeState = .{};
    platform.registerProbe(.{
        .name = "input",
        .ctx = &input_probe,
        .ext = "txt",
        .digest = InputProbe.digest,
        .desc = "TextInput focus/edit/IME preedit state",
    });
    platform.registerProbe(.{
        .name = "copy",
        .ctx = &copy_probe,
        .ext = "txt",
        .digest = CopyProbe.digest,
        .desc = "TextInput copy requests",
    });

    var running = true;
    // Before the first pollEvents, declare "no edit focus" (closes the gap where a keyDown right after launch
    // was always routed into IME). After that, follow focus at the end of every frame.
    window.setTextInputActive(false);
    var doc_bridge: DocBridge = undefined;
    var doc_bridge_active = false;
    main_loop: while (running and window.pollEvents()) {
        const fb = window.lockFramebuffer() orelse continue :main_loop;
        defer fb.unlock();

        ctx.beginFrameAt(fb.width, fb.height, platform.getTime());
        var paste_buf: [4096]u8 = undefined;
        var paste_text: ?[]const u8 = null;
        while (window.nextEvent()) |ev| {
            if (ev == .quit) running = false;
            if (ev == .composition_changed) {
                ime.dirty = true;
                ime.last_phase = ev.composition_changed.phase;
            }
            if (ev == .key_down) {
                const k = ev.key_down;
                // Read the OS clipboard only on Cmd+V (GUI does not import platform).
                if (k.key == .V and k.modifiers.cmd and !k.modifiers.ctrl and !k.modifiers.alt and !k.is_repeat) {
                    paste_text = platform.getClipboardText(paste_buf[0..]);
                }
            }
            if (toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
        }

        ime.syncFromWindow(window);
        ctx.setComposition(ime.guiState());

        @memset(fb.pixels, 0xFF_18181C);
        ctx.beginBox(.{
            .direction = .column,
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .padding = .{ 72, 24, 0, 24 },
            .gap = 24,
        });
        const first = ctx.textInputId(0x2801, &first_buffer, .{
            .width = .{ .fixed = 320 },
            .placeholder = "Type ASCII or 日本語...",
            .paste_text = paste_text,
        });
        const second = ctx.textInputId(0x2802, &second_buffer, .{
            .width = .{ .fixed = 320 },
            .placeholder = "Second input",
            .paste_text = paste_text,
        });
        ctx.labelEx("single-line UTF-8 / Shift selection / Cmd+C/X/V", gui.Color.rgba(0xA0, 0xA8, 0xB8, 0xFF));
        ctx.labelEx("IME: 変換中 preedit は下線付き inline。Enter=確定 / Esc=取消", gui.Color.rgba(0xA0, 0xA8, 0xB8, 0xFF));
        ctx.endBox();

        if (first.copy_request) |r| {
            platform.setClipboardText(r.text);
            copy_probe.count += 1;
            copy_probe.bytes += r.text.len;
        }
        if (second.copy_request) |r| {
            platform.setClipboardText(r.text);
            copy_probe.count += 1;
            copy_probe.bytes += r.text.len;
        }

        ctx.endFrame();

        // Treat focusedId after endFrame as authoritative (do not clear the rect from a stale first.focused
        // right after second claimed focus in the same frame).
        const focused_id = ctx.focusedId();
        switch (focused_id) {
            0x2801 => {
                input_probe.update(&first_buffer, first, ctx.perIdState(0x2801).caret);
                input_probe.scroll = ctx.perIdState(0x2801).scroll_x;
            },
            0x2802 => {
                input_probe.update(&second_buffer, second, ctx.perIdState(0x2802).caret);
                input_probe.scroll = ctx.perIdState(0x2802).scroll_x;
            },
            else => {
                input_probe.update(&first_buffer, first, ctx.perIdState(0x2801).caret);
                input_probe.scroll = ctx.perIdState(0x2801).scroll_x;
                input_probe.focus = 0;
            },
        }
        input_probe.preedit_active = if (ime.active) 1 else 0;
        input_probe.preedit_len = ime.preedit_len;
        input_probe.preedit_cursor = ime.preedit_cursor;

        const local_caret: ?gui.Rect = switch (focused_id) {
            0x2801 => first.caret_rect,
            0x2802 => second.caret_rect,
            else => null,
        };
        if (local_caret) |local| {
            if (ctx.getNodeRect(focused_id)) |node| {
                notifyCompositionRect(window, &ime, .{
                    .x = node.x + local.x,
                    .y = node.y + local.y,
                    .w = @intCast(local.w),
                    .h = @intCast(local.h),
                });
            }
        } else {
            notifyCompositionRect(window, &ime, null);
        }

        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        gui.render(target, &ctx.draw_list, ctx.font, 1.0);
        window.present();

        // Forward keyDown to IME only while a text field has focus. Clicking empty space to clear focus
        // (wantsKeyboard()==false) lets keys reach shortcuts even while IME is enabled.
        // Switch document access on the same schedule (must complete before the next pollEvents).
        // Re-registering every frame is intentional: PerIdStateStore rehash can invalidate *PerIdState, so
        // optimizing to focus-change-only would leave selection/caret pointers dangling.
        const wants = ctx.wantsKeyboard();
        window.setTextInputActive(wants);
        if (wants) {
            switch (focused_id) {
                0x2801 => {
                    const per = ctx.perIdState(0x2801);
                    doc_bridge = .{
                        .buffer = &first_buffer,
                        .selection = &per.selection,
                        .caret = &per.caret,
                        .max_len = null,
                    };
                    window.setTextInputDocumentAccess(@ptrCast(&doc_bridge), doc_callbacks);
                    doc_bridge_active = true;
                },
                0x2802 => {
                    const per = ctx.perIdState(0x2802);
                    doc_bridge = .{
                        .buffer = &second_buffer,
                        .selection = &per.selection,
                        .caret = &per.caret,
                        .max_len = null,
                    };
                    window.setTextInputDocumentAccess(@ptrCast(&doc_bridge), doc_callbacks);
                    doc_bridge_active = true;
                },
                else => {
                    if (doc_bridge_active) {
                        var dummy: u8 = 0;
                        window.setTextInputDocumentAccess(@ptrCast(&dummy), null);
                        doc_bridge_active = false;
                    }
                },
            }
        } else if (doc_bridge_active) {
            var dummy: u8 = 0;
            window.setTextInputDocumentAccess(@ptrCast(&dummy), null);
            doc_bridge_active = false;
        }
    }
}
