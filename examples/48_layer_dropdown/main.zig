//! Interactive layer dropdown: a modal marker, a text field and a roving listbox row.
//!
//! The dropdown is declared where its owner state is built. Its presence is controlled only by
//! `dropdown_open`; the marker registry has no separate open state. Input ownership is delayed
//! by the previous-frame route contract, while the visible layer is drawn in the frame where its
//! marker is submitted.
//!
//! Hot path declaration:
//! - The GUI tree and layer marker are built once per frame; the list has four bounded rows.
//! - The framebuffer clear uses `kit.pixelops.fill32`; this example adds no all-pixel loop.
//! - Probe and raw-input handling are event/control-plane work, not a real-time path.

const std = @import("std");
const kit = @import("kit");
const platform = kit.platform;
const gui = kit.gui;

const dropdown_key: gui.LayerKey = .{ .value = 0x4801 };

const Ids = struct {
    const trigger: gui.Id = 0x4802;
    const dropdown_root: gui.Id = 0x4803;
    const search: gui.Id = 0x4804;
    const row_base: gui.Id = 0x4810;
};

const options = [_][]const u8{ "Cobalt", "Moss", "Amber", "Rose" };
const escape_code: u32 = @intCast(@intFromEnum(platform.KeyCode.ESCAPE));

const App = struct {
    pub const window = .{
        .w = 1100,
        .h = 720,
        .title = "Layer dropdown",
    };

    gpa: std.mem.Allocator,
    ctx: gui.Context,
    search: gui.TextBuffer,
    dropdown_open: bool = false,
    highlighted_row: usize = 0,
    selected_row: ?usize = null,
    main_escape_count: usize = 0,

    // These values describe the last completed frame and are the only state read by the probe.
    last_placed: bool = false,
    last_root_rect: ?gui.Rect = null,
    last_hit_rows: usize = 0,
    last_focus_row: ?usize = null,
    last_wants_keyboard: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !*App {
        _ = io;
        const app = try gpa.create(App);
        app.* = .{
            .gpa = gpa,
            .ctx = gui.Context.init(gpa, gui.default_font),
            .search = try gui.TextBuffer.init(gpa, ""),
        };
        registerHarness(app);
        return app;
    }

    pub fn deinit(self: *App) void {
        self.search.deinit();
        self.ctx.deinit();
        self.gpa.destroy(self);
    }

    pub fn frame(self: *App, win: *platform.Window, now: f64) !bool {
        _ = now;
        const fb = win.lockFramebuffer() orelse return true;
        defer fb.unlock();

        var running = true;
        const ctx = &self.ctx;
        self.last_hit_rows = 0;
        // Stage the platform events before beginFrame so the frame-latched route can include
        // an outside press in its dismissal decision (ADR-028).
        while (win.nextEvent()) |ev| {
            if (ev == .quit) running = false;
            if (kit.toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
        }
        ctx.beginFrame(fb.logical_size.width, fb.logical_size.height);

        // Raw input remains raw by design. The owner consumes Escape while its marker state is
        // present; a main-tree shortcut is allowed only when the latched keyboard gate is open.
        if (self.dropdown_open and ctx.layerDismissed(dropdown_key)) {
            self.dropdown_open = false;
        }
        const escape_pressed = ctx.input.wasPressed(escape_code);
        const escape_consumed = self.dropdown_open and escape_pressed;
        if (escape_consumed) self.dropdown_open = false;
        if (escape_pressed and !escape_consumed and !ctx.wantsKeyboard()) {
            self.main_escape_count += 1;
        }

        self.buildMain(ctx);
        if (self.dropdown_open) self.buildDropdown(ctx);
        ctx.endFrame();

        self.last_placed = ctx.layerWasPlaced(dropdown_key);
        self.last_root_rect = if (self.last_placed) ctx.layerPrevRect(dropdown_key) else null;
        self.last_wants_keyboard = ctx.wantsKeyboard();
        self.last_focus_row = focusedRow(ctx.focusedId());

        kit.pixelops.fill32(fb.pixels, @bitCast(ctx.style.surface.canvas));
        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        gui.render(target, ctx.postFrameDrawList(), ctx.font, 1.0);
        win.setTextInputActive(ctx.wantsTextInput());
        win.present();
        return running;
    }

    fn buildMain(self: *App, ctx: *gui.Context) void {
        ctx.beginBox(.{
            .direction = .column,
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .padding = .{ 28, 32, 28, 32 },
            .gap = 12,
            .bg = ctx.style.surface.canvas,
            .clip_children = true,
        });
        ctx.labelStyled("Layer placement", .headline);
        ctx.label("The control below owns a detached modal layer. Its marker is submitted only while the owner state is open.");
        ctx.label("Selected color:");
        ctx.label(if (self.selected_row) |index| options[index] else "none");

        ctx.beginBox(.{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } });
        ctx.endBox();

        ctx.beginBox(.{
            .direction = .row,
            .width = .{ .grow = 1 },
            .height = .fit,
            .align_main = .end,
            .align_cross = .end,
        });
        const trigger = ctx.buttonId(Ids.trigger, "Choose a color", .{ .min_w = 168 });
        if (trigger.clicked) {
            self.dropdown_open = true;
            // The trigger opens a transient surface rather than becoming the main keyboard
            // destination; the modal subtree will establish its own focus on the next Tab.
            ctx.releaseFocus();
        }
        ctx.endBox();
        ctx.label("The main Escape shortcut is gated by wantsKeyboard().");
        ctx.endBox();
    }

    fn buildDropdown(self: *App, ctx: *gui.Context) void {
        const spec: gui.LayerSpec = .{
            .key = dropdown_key,
            .z = 10,
            .placement = .{
                .source = .{ .id = Ids.trigger },
                .side = .below,
                .flip = .main_axis,
                .shift = .both_axes,
            },
            .cache = true,
            .input = .modal,
            .dismiss_on_outside = true,
        };
        ctx.beginBox(.{
            .id = Ids.dropdown_root,
            .layer = &spec,
            .direction = .column,
            .width = .{ .fixed = 280 },
            .height = .fit,
            .gap = 8,
            .padding = .{ 14, 14, 14, 14 },
            .bg = ctx.style.surface.raised,
            .border = .{ .color = ctx.style.border_tokens.normal, .thickness = 1 },
            .radius = 8,
            .clip_children = true,
        });
        ctx.labelStyled("Choose a color", .subtitle);
        _ = ctx.textInputId(Ids.search, &self.search, .{
            .width = .{ .grow = 1 },
            .placeholder = "Search colors",
        });

        const nav = ctx.pollListNav(rowId(self.highlighted_row));
        if (nav != .none) {
            self.highlighted_row = switch (nav) {
                .prev => if (self.highlighted_row == 0) options.len - 1 else self.highlighted_row - 1,
                .next => (self.highlighted_row + 1) % options.len,
                .none => unreachable,
            };
            _ = ctx.claimFocus(rowId(self.highlighted_row));
        }

        for (options, 0..) |label, i| {
            const row = ctx.beginListboxRow(rowId(i), self.highlighted_row == i, .{
                .height = .{ .fixed = 32 },
                .padding = .{ 0, 10, 0, 10 },
                .align_cross = .center,
            });
            ctx.label(label);
            ctx.endListboxRow();
            if (row.activated) {
                if (ctx.input.mouse_pressed.left or ctx.input.mouse_released.left or
                    ctx.input.mouse_pressed.right or ctx.input.mouse_released.right or
                    ctx.input.mouse_pressed.middle or ctx.input.mouse_released.middle)
                {
                    self.last_hit_rows += 1;
                }
                self.highlighted_row = i;
                self.selected_row = i;
                self.dropdown_open = false;
                ctx.releaseFocus();
            }
        }
        ctx.endBox();
    }

    fn rowId(index: usize) gui.Id {
        return Ids.row_base + @as(gui.Id, @intCast(index));
    }

    fn focusedRow(id: gui.Id) ?usize {
        if (id < Ids.row_base) return null;
        const offset = id - Ids.row_base;
        return if (offset < options.len) @intCast(offset) else null;
    }
};

fn optionalIndexText(buffer: []u8, value: ?usize) []const u8 {
    const index = value orelse return "none";
    return std.fmt.bufPrint(buffer, "{d}", .{index}) catch "none";
}

fn digestDropdown(ctx_ptr: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx_ptr));
    var selected_buf: [24]u8 = undefined;
    var focus_buf: [24]u8 = undefined;
    const selected = optionalIndexText(&selected_buf, app.selected_row);
    const focus = optionalIndexText(&focus_buf, app.last_focus_row);
    if (app.last_root_rect) |rect| {
        return std.fmt.bufPrint(
            buf,
            "placed={d} root_rect={d},{d},{d},{d} selected={s} hit_rows={d} focus_row={s} wants_keyboard={d} main_escape_count={d}",
            .{
                @intFromBool(app.last_placed),
                rect.x,
                rect.y,
                rect.w,
                rect.h,
                selected,
                app.last_hit_rows,
                focus,
                @intFromBool(app.last_wants_keyboard),
                app.main_escape_count,
            },
        ) catch buf[0..0];
    }
    return std.fmt.bufPrint(
        buf,
        "placed={d} root_rect=none selected={s} hit_rows={d} focus_row={s} wants_keyboard={d} main_escape_count={d}",
        .{
            @intFromBool(app.last_placed),
            selected,
            app.last_hit_rows,
            focus,
            @intFromBool(app.last_wants_keyboard),
            app.main_escape_count,
        },
    ) catch buf[0..0];
}

fn registerHarness(app: *App) void {
    platform.registerProbe(.{
        .name = "dropdown",
        .ctx = app,
        .ext = "txt",
        .digest = digestDropdown,
        .desc = "modal dropdown placement, selection, focus and host keyboard gate",
    });
}

const Rt = kit.app_runtime.Runtime(App);

pub fn main(init: std.process.Init) !void {
    try Rt.runNative(init);
}

test "dropdown row ids remain distinct from the trigger and root" {
    try std.testing.expect(Ids.trigger != Ids.dropdown_root);
    try std.testing.expect(Ids.row_base > Ids.dropdown_root);
    try std.testing.expectEqual(@as(gui.Id, Ids.row_base + 3), App.rowId(3));
}
