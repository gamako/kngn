//! GUI style showcase: widget states, paths, rounded primitives, gradient paints, and shadows.
//!
//! Hot path declaration:
//! - The GUI tree and DrawList commands are built once per frame.
//! - The framebuffer clear and renderer perform the example's all-pixel work per frame.
//! - Probe digest and snapshot callbacks walk the DrawList only when the harness requests them.
//! - No real-time or audio path is used.

const std = @import("std");
const kit = @import("kit");
const platform = kit.platform;
const gui = kit.gui;

const WINDOW_W: u32 = 1024;
const WINDOW_H: u32 = 640;

const Section = enum(u8) {
    overview,
    states,
    paths,
    rounded,
    gradients,
    shadow,
};

const FrameSection = enum {
    /// Framebuffer lock, clear, and GUI frame opening.
    begin,
    /// Platform event drain and application input handling.
    events,
    /// Immediate-mode widget tree construction and layout finalisation.
    ui_build,
    /// Direct path command construction for the path showcase.
    paths,
    /// DrawList rasterisation into the framebuffer.
    gui_render,
    /// Window presentation to the backend.
    present,
};

const Prof = kit.frame_prof.Profiler(FrameSection, platform.getRealTime);

fn drawlistDigest(ctx_ptr: *anyopaque, buf: []u8) []const u8 {
    const draw_list: *const gui.DrawList = @ptrCast(@alignCast(ctx_ptr));
    return gui.drawlistDigest(draw_list, buf);
}

fn drawlistDumpAlloc(ctx_ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const draw_list: *const gui.DrawList = @ptrCast(@alignCast(ctx_ptr));
    return gui.drawlistDumpAlloc(allocator, draw_list);
}

const Ids = struct {
    const tab_overview: gui.Id = 0x4601;
    const tab_states: gui.Id = 0x4602;
    const tab_paths: gui.Id = 0x4603;
    const primary_button: gui.Id = 0x4610;
    const disabled_button: gui.Id = 0x4611;
    const checkbox: gui.Id = 0x4620;
    const toggle: gui.Id = 0x4621;
    const radio_a: gui.Id = 0x4622;
    const radio_b: gui.Id = 0x4623;
    const slider: gui.Id = 0x4624;
    const selectable: gui.Id = 0x4630;
    const text_input: gui.Id = 0x4631;
    const icon_a: gui.Id = 0x4640;
    const icon_b: gui.Id = 0x4641;
};

const ICON_A: [16]u16 = .{
    0b0000000000000000,
    0b0000000000011000,
    0b0000000000111100,
    0b0000000001111000,
    0b0000000011110000,
    0b0000000111100000,
    0b0000001111000000,
    0b0000011110000000,
    0b0000111100000000,
    0b0001111000000000,
    0b0011110000000000,
    0b0111100000000000,
    0b1111000000000000,
    0b1110000000000000,
    0b1100000000000000,
    0b0000000000000000,
};

const ICON_B: [16]u16 = .{
    0b0000000110000000,
    0b0000001111000000,
    0b0000011111100000,
    0b0000011111100000,
    0b0000001111000000,
    0b0000000110000000,
    0b0000000110000000,
    0b0000000110000000,
    0b0000000110000000,
    0b0000000110000000,
    0b0000000110000000,
    0b0000001111000000,
    0b0000011111100000,
    0b0000111111110000,
    0b0000011111100000,
    0b0000000000000000,
};

const App = struct {
    ctx: *gui.Context,
    text: *gui.TextBuffer,
    section: Section = .overview,
    selected_tab: Section = .states,
    checked: bool = true,
    toggled: bool = true,
    radio_b: bool = false,
    slider_value: i32 = 4,
    fill_count: u32 = 0,
    stroke_count: u32 = 0,
    aa_on_count: u32 = 0,
    aa_off_count: u32 = 0,
    shadow_count: u32 = 0,

    fn sectionIndex(self: *const App) u8 {
        return @intFromEnum(self.section);
    }

    fn sectionName(self: *const App) []const u8 {
        return @tagName(self.section);
    }

    fn selectedName(self: *const App) []const u8 {
        return @tagName(self.selected_tab);
    }

    fn widgetName(id: gui.Id) []const u8 {
        if (id == 0) return "none";
        if (id == Ids.tab_overview) return "tab_overview";
        if (id == Ids.tab_states) return "tab_states";
        if (id == Ids.tab_paths) return "tab_paths";
        if (id == Ids.primary_button) return "button";
        if (id == Ids.disabled_button) return "disabled";
        if (id == Ids.checkbox) return "checkbox";
        if (id == Ids.toggle) return "toggle";
        if (id == Ids.radio_a or id == Ids.radio_b) return "radio";
        if (id == Ids.slider) return "slider";
        if (id == Ids.selectable) return "selectable";
        if (id == Ids.text_input) return "textInput";
        if (id == Ids.icon_a or id == Ids.icon_b) return "iconButton";
        return "other";
    }

    fn changeSection(self: *App, delta: i8) void {
        const count: i16 = @intCast(@typeInfo(Section).@"enum".fields.len);
        var next: i16 = @intCast(@intFromEnum(self.section));
        next += delta;
        if (next < 0) next = count - 1;
        if (next >= count) next = 0;
        self.section = @enumFromInt(@as(u8, @intCast(next)));
        self.ctx.closePopup();
        self.ctx.state.hot_id = 0;
        self.ctx.state.next_hot_id = 0;
        self.ctx.state.active_id = 0;
        self.ctx.state.focused_id = 0;
        self.ctx.state.focus_visible = false;
    }
};

fn showcaseDigest(ctx_ptr: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx_ptr));
    return std.fmt.bufPrint(buf, "section={s} index={d} hot={s} active={s} focused={s} selected={s} disabled={d} fill={d} stroke={d} aa_on={d} aa_off={d} shadow={d}", .{
        app.sectionName(),
        app.sectionIndex(),
        App.widgetName(app.ctx.state.hot_id),
        App.widgetName(app.ctx.state.active_id),
        App.widgetName(app.ctx.state.focused_id),
        app.selectedName(),
        @as(u32, if (app.section == .states) 1 else 0),
        app.fill_count,
        app.stroke_count,
        app.aa_on_count,
        app.aa_off_count,
        app.shadow_count,
    }) catch buf[0..0];
}

fn renderHeader(ctx: *gui.Context, app: *const App) void {
    ctx.beginBox(.{
        .height = .{ .fixed = 64 },
        .width = .{ .grow = 1 },
        .padding = .{ 8, 12, 8, 12 },
        .bg = gui.Color.rgba(0x28, 0x30, 0x3C, 0xFF),
    });
    ctx.labelStyled("GUI Style Showcase", .heading);
    var line: [128]u8 = undefined;
    ctx.labelEx(std.fmt.bufPrint(&line, "section={s}  |  PAGE_DOWN/PAGE_UP or N/P", .{app.sectionName()}) catch "section=?", ctx.style.text_subtle);
    ctx.endBox();
}

fn renderOverview(ctx: *gui.Context) void {
    ctx.beginBox(.{ .direction = .column, .gap = 10, .padding = .{ 16, 16, 16, 16 } });
    ctx.labelStyled("A compact visual contract for GUI states and path rendering.", .heading);
    ctx.label("The states section keeps normal and selected controls visible together.");
    ctx.label("Move the pointer for hover, hold the left button for press, and use Tab for focus.");
    ctx.label("The paths section compares fills, holes, caps, joins, hairlines, and antialiasing.");
    ctx.label("PAGE_DOWN / PAGE_UP or N / P changes sections and clears transient interaction state.");
    ctx.endBox();
}

fn renderStates(ctx: *gui.Context, app: *App) void {
    ctx.beginBox(.{ .direction = .column, .gap = 8, .padding = .{ 12, 12, 12, 12 } });
    ctx.labelEx("normal / hover / press / disabled / focus / selected", ctx.style.text_subtle);

    ctx.beginBox(.{ .direction = .row, .gap = 8 });
    const overview_tab = ctx.tabId(Ids.tab_overview, "Overview", app.selected_tab == .overview, .{ .width = .{ .fixed = 112 }, .height = .{ .fixed = 30 } });
    const states_tab = ctx.tabId(Ids.tab_states, "States", app.selected_tab == .states, .{ .width = .{ .fixed = 112 }, .height = .{ .fixed = 30 } });
    const paths_tab = ctx.tabId(Ids.tab_paths, "Paths", app.selected_tab == .paths, .{ .width = .{ .fixed = 112 }, .height = .{ .fixed = 30 } });
    if (overview_tab.activated) app.selected_tab = .overview;
    if (states_tab.activated) app.selected_tab = .states;
    if (paths_tab.activated) app.selected_tab = .paths;
    ctx.endBox();

    ctx.beginBox(.{ .direction = .row, .gap = 12 });
    _ = ctx.buttonId(Ids.primary_button, "Primary button", .{ .min_w = 176 });
    ctx.beginDisabled();
    _ = ctx.buttonId(Ids.disabled_button, "Disabled button", .{ .min_w = 176 });
    ctx.endDisabled();
    ctx.endBox();

    ctx.beginBox(.{ .direction = .row, .gap = 16 });
    _ = ctx.checkboxId(Ids.checkbox, "Checkbox", &app.checked);
    _ = ctx.toggleId(Ids.toggle, "Toggle", &app.toggled);
    ctx.endBox();

    ctx.beginBox(.{ .direction = .row, .gap = 16 });
    if (ctx.radioId(Ids.radio_a, "Radio A", !app.radio_b)) app.radio_b = false;
    if (ctx.radioId(Ids.radio_b, "Radio B", app.radio_b)) app.radio_b = true;
    ctx.endBox();

    _ = ctx.sliderI32Id(Ids.slider, "Slider", &app.slider_value, .{ .min = 0, .max = 10, .step = 1, .track_w = 240 });
    _ = ctx.selectableLabelId(Ids.selectable, "Selectable label (focusable)", .{ .focusable = true });
    _ = ctx.textInputId(Ids.text_input, app.text, .{ .width = .{ .fixed = 320 }, .placeholder = "Text input" });

    ctx.beginBox(.{ .direction = .row, .gap = 8 });
    _ = ctx.iconButtonId(Ids.icon_a, &ICON_A, true);
    _ = ctx.iconButtonId(Ids.icon_b, &ICON_B, false);
    ctx.labelEx("selected icon / normal icon", ctx.style.text_subtle);
    ctx.endBox();
    ctx.endBox();
}

fn renderPathLabels(ctx: *gui.Context) void {
    ctx.beginBox(.{ .direction = .column, .gap = 4, .padding = .{ 12, 12, 12, 12 } });
    ctx.labelEx("fills (curve / concave / hole), stroke caps and joins, hairline; AA off on the middle shapes", ctx.style.text_subtle);
    ctx.endBox();
}

fn renderFrame(ctx: *gui.Context, app: *App) void {
    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 24, 24, 24, 24 },
        .gap = 12,
        .bg = gui.Color.rgba(0x18, 0x1C, 0x24, 0xFF),
    });
    renderHeader(ctx, app);
    ctx.beginBox(.{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF) });
    switch (app.section) {
        .overview => renderOverview(ctx),
        .states => renderStates(ctx, app),
        .paths => renderPathLabels(ctx),
        .rounded => {
            ctx.beginBox(.{ .direction = .column, .gap = 4, .padding = .{ 12, 12, 12, 12 } });
            ctx.labelEx("sharp / rounded fills / outlines / circles / translucent / clipped", ctx.style.text_subtle);
            ctx.endBox();
        },
        .gradients => {
            ctx.beginBox(.{ .direction = .column, .gap = 4, .padding = .{ 12, 12, 12, 12 } });
            ctx.labelEx("linear vertical / diagonal / rounded and radial rounded paints", ctx.style.text_subtle);
            ctx.endBox();
        },
        .shadow => {
            ctx.beginBox(.{ .direction = .column, .gap = 4, .padding = .{ 12, 12, 12, 12 } });
            ctx.labelEx("nine-slice shadow masks: radius / blur / offset / slice boundaries", ctx.style.text_subtle);
            ctx.endBox();
        },
    }
    ctx.endBox();
    ctx.endBox();
    ctx.endFrame();
}

/// Appends a fixed rounded-primitive scene once per frame.
fn appendRounded(app: *App) !void {
    const draw_list = &app.ctx.draw_list;
    app.fill_count = 0;
    app.stroke_count = 0;
    app.aa_on_count = 0;
    app.aa_off_count = 0;
    app.shadow_count = 0;

    const blue = gui.Color.rgba(0x48, 0xA8, 0xF0, 0xFF);
    const green = gui.Color.rgba(0x58, 0xD0, 0x80, 0xFF);
    const amber = gui.Color.rgba(0xF0, 0xB8, 0x48, 0xFF);
    const violet = gui.Color.rgba(0xA0, 0x78, 0xF0, 0xFF);

    try draw_list.rectFilled(.{ .x = 44, .y = 164, .w = 136, .h = 64 }, blue);
    app.fill_count += 1;
    app.aa_on_count += 1;
    try draw_list.rectFilledEx(.{ .x = 200, .y = 164, .w = 136, .h = 64 }, blue, .{ .radius = 0 });
    app.fill_count += 1;
    app.aa_on_count += 1;
    try draw_list.rectFilledEx(.{ .x = 356, .y = 164, .w = 136, .h = 64 }, green, .{ .radius = 6 });
    app.fill_count += 1;
    app.aa_on_count += 1;
    try draw_list.rectFilledEx(.{ .x = 512, .y = 164, .w = 136, .h = 64 }, amber, .{ .radius = 16 });
    app.fill_count += 1;
    app.aa_on_count += 1;
    try draw_list.rectFilledEx(.{ .x = 668, .y = 164, .w = 136, .h = 64 }, violet, .{ .radius = 32, .aa = false });
    app.fill_count += 1;
    app.aa_off_count += 1;

    try draw_list.rectOutlineEx(.{ .x = 44, .y = 270, .w = 210, .h = 92 }, blue, 2, .{ .radius = 12 });
    app.stroke_count += 1;
    app.aa_on_count += 1;
    try draw_list.rectOutlineEx(.{ .x = 282, .y = 270, .w = 210, .h = 92 }, green, 12, .{ .radius = 20 });
    app.stroke_count += 1;
    app.aa_on_count += 1;
    try draw_list.rectOutlineEx(.{ .x = 520, .y = 270, .w = 210, .h = 92 }, amber, 30, .{ .radius = 18, .aa = false });
    app.stroke_count += 1;
    app.aa_off_count += 1;

    try draw_list.circleFilled(.{ .x = 108, .y = 470 }, 48, blue, .{});
    app.fill_count += 1;
    app.aa_on_count += 1;
    try draw_list.circleOutline(.{ .x = 250, .y = 470 }, 48, green, 10, .{});
    app.stroke_count += 1;
    app.aa_on_count += 1;

    try draw_list.rectFilled(.{ .x = 340, .y = 414, .w = 220, .h = 112 }, gui.Color.rgba(0x30, 0x38, 0x48, 0xFF));
    app.fill_count += 1;
    app.aa_on_count += 1;
    try draw_list.rectFilledEx(.{ .x = 364, .y = 434, .w = 172, .h = 72 }, gui.Color.rgba(0xF0, 0x78, 0xA0, 0x88), .{ .radius = 24 });
    app.fill_count += 1;
    app.aa_on_count += 1;

    try draw_list.pushClip(.{ .x = 680, .y = 424, .w = 180, .h = 92 });
    try draw_list.rectFilledEx(.{ .x = 640, .y = 392, .w = 260, .h = 156 }, violet, .{ .radius = 40 });
    draw_list.popClip();
    app.fill_count += 1;
    app.aa_on_count += 1;
}

/// Appends a fixed scene covering the supported rectangle paint variants.
fn appendGradients(app: *App) !void {
    const draw_list = &app.ctx.draw_list;
    app.fill_count = 0;
    app.stroke_count = 0;
    app.aa_on_count = 0;
    app.aa_off_count = 0;
    app.shadow_count = 0;

    const blue = gui.Color.rgba(0x38, 0x78, 0xE8, 0xFF);
    const cyan = gui.Color.rgba(0x40, 0xD8, 0xC0, 0xFF);
    const violet = gui.Color.rgba(0xA8, 0x60, 0xF0, 0xFF);
    const amber = gui.Color.rgba(0xF0, 0xB0, 0x38, 0xFF);

    try draw_list.rectFilledPaint(.{ .x = 44, .y = 164, .w = 180, .h = 108 }, .{ .linear = .{
        .start = .{ .x = 44, .y = 164 },
        .end = .{ .x = 44, .y = 272 },
        .start_color = blue,
        .end_color = cyan,
    } });
    try draw_list.rectFilledPaint(.{ .x = 248, .y = 164, .w = 180, .h = 108 }, .{ .linear = .{
        .start = .{ .x = 248, .y = 164 },
        .end = .{ .x = 428, .y = 272 },
        .start_color = violet,
        .end_color = amber,
    } });
    try draw_list.rectFilledPaintEx(.{ .x = 452, .y = 164, .w = 180, .h = 108 }, .{ .linear = .{
        .start = .{ .x = 452, .y = 164 },
        .end = .{ .x = 632, .y = 164 },
        .start_color = cyan,
        .end_color = violet,
    } }, .{ .radius = 24 });
    try draw_list.rectFilledPaintEx(.{ .x = 656, .y = 164, .w = 260, .h = 148 }, .{ .radial = .{
        .center = .{ .x = 786, .y = 238 },
        .radius = 130,
        .inner_color = amber,
        .outer_color = blue,
    } }, .{ .radius = 32 });

    try draw_list.rectFilled(.{ .x = 44, .y = 340, .w = 588, .h = 172 }, gui.Color.rgba(0x30, 0x38, 0x50, 0xFF));
    try draw_list.rectFilledPaint(.{ .x = 44, .y = 340, .w = 588, .h = 172 }, .{ .linear = .{
        .start = .{ .x = 44, .y = 340 },
        .end = .{ .x = 632, .y = 512 },
        .start_color = gui.Color.rgba(0x20, 0xA0, 0xFF, 0x88),
        .end_color = gui.Color.rgba(0xF0, 0x50, 0xA0, 0x88),
    } });
}

fn appendShadows(app: *App) !void {
    const draw_list = &app.ctx.draw_list;
    app.fill_count = 0;
    app.stroke_count = 0;
    app.aa_on_count = 0;
    app.aa_off_count = 0;
    app.shadow_count = 0;

    const panels = [_]struct {
        rect: gui.Rect,
        radius: u32,
        blur: u32,
        offset: gui.Vec2,
        color: gui.Color,
    }{
        .{ .rect = .{ .x = 56, .y = 164, .w = 220, .h = 104 }, .radius = 10, .blur = 8, .offset = .{ .x = 0, .y = 0 }, .color = gui.Color.rgba(0x48, 0xA8, 0xF0, 0xFF) },
        .{ .rect = .{ .x = 350, .y = 164, .w = 220, .h = 104 }, .radius = 28, .blur = 18, .offset = .{ .x = 8, .y = 8 }, .color = gui.Color.rgba(0x58, 0xD0, 0x80, 0xFF) },
        .{ .rect = .{ .x = 644, .y = 164, .w = 220, .h = 104 }, .radius = 42, .blur = 4, .offset = .{ .x = -8, .y = 12 }, .color = gui.Color.rgba(0xF0, 0xB8, 0x48, 0xFF) },
        .{ .rect = .{ .x = 56, .y = 360, .w = 128, .h = 128 }, .radius = 52, .blur = 12, .offset = .{ .x = 0, .y = 0 }, .color = gui.Color.rgba(0xA0, 0x78, 0xF0, 0xFF) },
        .{ .rect = .{ .x = 248, .y = 360, .w = 300, .h = 128 }, .radius = 6, .blur = 24, .offset = .{ .x = 4, .y = 4 }, .color = gui.Color.rgba(0x40, 0xD8, 0xC0, 0xFF) },
    };
    for (panels) |panel| {
        try draw_list.shadow(panel.rect, gui.Color.rgba(0x00, 0x00, 0x00, 0xB0), .{
            .radius = panel.radius,
            .blur = panel.blur,
            .offset = panel.offset,
        });
        app.shadow_count += 1;
        try draw_list.rectFilledEx(panel.rect, panel.color, .{ .radius = panel.radius });
        try draw_list.rectOutlineEx(panel.rect, gui.Color.rgba(0xFF, 0xFF, 0xFF, 0x60), 1, .{ .radius = panel.radius });
        app.fill_count += 1;
        app.stroke_count += 1;
    }
}

/// Appends the fixed path scene once per frame; all shapes are inside the framebuffer.
fn appendPaths(app: *App, arena: *std.heap.ArenaAllocator) !void {
    const ctx = app.ctx;
    const draw_list = &ctx.draw_list;
    app.fill_count = 0;
    app.stroke_count = 0;
    app.aa_on_count = 0;
    app.aa_off_count = 0;
    app.shadow_count = 0;

    var p = draw_list.beginPath(arena.allocator());
    try p.moveTo(.{ .x = 56, .y = 240 });
    try p.cubicTo(.{ .x = 56, .y = 160 }, .{ .x = 220, .y = 160 }, .{ .x = 220, .y = 240 });
    try p.cubicTo(.{ .x = 220, .y = 320 }, .{ .x = 56, .y = 320 }, .{ .x = 56, .y = 240 });
    try p.close();
    try p.finish(.{ .color = gui.Color.rgba(0x40, 0xA0, 0xFF, 0xFF), .aa = true });
    app.fill_count += 1;
    app.aa_on_count += 1;

    p = draw_list.beginPath(arena.allocator());
    try p.moveTo(.{ .x = 280, .y = 170 });
    try p.lineTo(.{ .x = 450, .y = 170 });
    try p.lineTo(.{ .x = 450, .y = 330 });
    try p.lineTo(.{ .x = 365, .y = 250 });
    try p.lineTo(.{ .x = 280, .y = 330 });
    try p.close();
    try p.finish(.{ .color = gui.Color.rgba(0x50, 0xD0, 0x70, 0xFF), .aa = false });
    app.fill_count += 1;
    app.aa_off_count += 1;

    p = draw_list.beginPath(arena.allocator());
    try p.moveTo(.{ .x = 510, .y = 170 });
    try p.lineTo(.{ .x = 720, .y = 170 });
    try p.lineTo(.{ .x = 720, .y = 330 });
    try p.lineTo(.{ .x = 510, .y = 330 });
    try p.close();
    try p.moveTo(.{ .x = 560, .y = 215 });
    try p.lineTo(.{ .x = 560, .y = 285 });
    try p.lineTo(.{ .x = 670, .y = 285 });
    try p.lineTo(.{ .x = 670, .y = 215 });
    try p.close();
    try p.finish(.{ .color = gui.Color.rgba(0xF0, 0xC0, 0x40, 0x90), .aa = true });
    app.fill_count += 1;
    app.aa_on_count += 1;

    p = draw_list.beginPath(arena.allocator());
    try p.moveTo(.{ .x = 60, .y = 410 });
    try p.lineTo(.{ .x = 120, .y = 380 });
    try p.lineTo(.{ .x = 180, .y = 410 });
    try p.stroke(.{ .color = gui.Color.rgba(0xFF, 0x90, 0x40, 0xFF), .width = 14, .cap = .butt, .aa = true });
    app.stroke_count += 1;
    app.aa_on_count += 1;

    p = draw_list.beginPath(arena.allocator());
    try p.moveTo(.{ .x = 230, .y = 410 });
    try p.lineTo(.{ .x = 290, .y = 380 });
    try p.lineTo(.{ .x = 350, .y = 410 });
    try p.stroke(.{ .color = gui.Color.rgba(0x40, 0xC0, 0xFF, 0xFF), .width = 14, .cap = .square, .aa = false });
    app.stroke_count += 1;
    app.aa_off_count += 1;

    p = draw_list.beginPath(arena.allocator());
    try p.moveTo(.{ .x = 400, .y = 410 });
    try p.lineTo(.{ .x = 460, .y = 380 });
    try p.lineTo(.{ .x = 520, .y = 410 });
    try p.stroke(.{ .color = gui.Color.rgba(0x90, 0x70, 0xFF, 0xFF), .width = 14, .cap = .round, .aa = true });
    app.stroke_count += 1;
    app.aa_on_count += 1;

    p = draw_list.beginPath(arena.allocator());
    try p.moveTo(.{ .x = 580, .y = 470 });
    try p.lineTo(.{ .x = 650, .y = 360 });
    try p.lineTo(.{ .x = 720, .y = 470 });
    try p.close();
    try p.stroke(.{ .color = gui.Color.rgba(0x50, 0xD0, 0x70, 0xFF), .width = 10, .join = .miter, .miter_limit = 4, .aa = true });
    app.stroke_count += 1;
    app.aa_on_count += 1;

    p = draw_list.beginPath(arena.allocator());
    try p.moveTo(.{ .x = 770, .y = 470 });
    try p.lineTo(.{ .x = 830, .y = 360 });
    try p.lineTo(.{ .x = 890, .y = 470 });
    try p.close();
    try p.stroke(.{ .color = gui.Color.rgba(0xF0, 0xC0, 0x40, 0xFF), .width = 10, .join = .bevel, .aa = false });
    app.stroke_count += 1;
    app.aa_off_count += 1;

    p = draw_list.beginPath(arena.allocator());
    try p.moveTo(.{ .x = 60, .y = 570 });
    try p.cubicTo(.{ .x = 200, .y = 510 }, .{ .x = 340, .y = 610 }, .{ .x = 500, .y = 570 });
    try p.stroke(.{ .color = gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), .width = 1, .cap = .round, .aa = true });
    app.stroke_count += 1;
    app.aa_on_count += 1;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WINDOW_W, WINDOW_H, "GUI Style Showcase");
    defer window.destroy();

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();
    ctx.style.animation.enabled = true;
    var text = try gui.TextBuffer.init(gpa, "edit me");
    defer text.deinit();
    var path_arena = std.heap.ArenaAllocator.init(gpa);
    defer path_arena.deinit();

    var app: App = .{ .ctx = &ctx, .text = &text };
    platform.registerProbe(.{ .name = "showcase", .ctx = &app, .ext = "txt", .digest = showcaseDigest, .desc = "style showcase section and widget state" });
    platform.registerProbe(.{ .name = "drawlist", .ctx = &ctx.draw_list, .ext = "txt", .digest = drawlistDigest, .snapshot = drawlistDumpAlloc, .desc = "style showcase DrawList command digest and structure dump" });
    platform.registerProbe(.{ .name = Prof.probe_name, .ctx = &app, .ext = "txt", .digest = Prof.probeDigest, .desc = "frame section timing for the style showcase" });
    platform.registerAction(.{ .name = Prof.reset_action_name, .ctx = &app, .run = Prof.resetAction, .network_policy = .local_only, .desc = "reset style showcase frame timing" });

    var running = true;
    window.setTextInputActive(false);
    main_loop: while (running and window.pollEvents()) {
        Prof.begin();
        const fb = window.lockFramebuffer() orelse continue :main_loop;
        defer fb.unlock();
        kit.pixelops.fill32(fb.pixels, 0xFF_18_1C_24);
        ctx.beginFrame(fb.width, fb.height);
        Prof.mark(.begin);

        while (window.nextEvent()) |ev| {
            switch (ev) {
                .quit => running = false,
                .key_down => |k| switch (k.key) {
                    .ESCAPE => running = false,
                    .PAGE_DOWN, .N => app.changeSection(1),
                    .PAGE_UP, .P => app.changeSection(-1),
                    else => {},
                },
                else => {},
            }
            if (kit.toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
        }
        Prof.mark(.events);

        renderFrame(&ctx, &app);
        Prof.mark(.ui_build);

        _ = path_arena.reset(.retain_capacity);
        if (app.section == .paths) {
            try appendPaths(&app, &path_arena);
        } else if (app.section == .rounded) {
            try appendRounded(&app);
        } else if (app.section == .gradients) {
            try appendGradients(&app);
        } else if (app.section == .shadow) {
            try appendShadows(&app);
        } else {
            app.fill_count = 0;
            app.stroke_count = 0;
            app.aa_on_count = 0;
            app.aa_off_count = 0;
            app.shadow_count = 0;
        }
        Prof.mark(.paths);

        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        gui.render(target, &ctx.draw_list, ctx.font, 1.0);
        Prof.mark(.gui_render);
        window.setTextInputActive(ctx.state.focused_id == Ids.text_input);
        window.present();
        Prof.end(.present);
    }
}
