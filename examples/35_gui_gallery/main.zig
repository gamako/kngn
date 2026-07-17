//! GUI widget capability gallery (TASK-121.1).
//!
//! APG / Dear ImGui の参照軸と、libs/gui の現有 API を一つの画面で照合する
//! 固定レイアウト example。未対応項目は実装せず、対象タスクを注記する。
//!
//! ホットパス宣言:
//! - widget の構築・DrawList への追加はフレーム毎。計算量は表示項目数に対する O(N)。
//! - 全画素ループ、framebuffer 全面コピー、独自 rasterizer、RT 経路は追加しない。
//! - SV square / hue bar / stepgrid の描画と固定 gradient buffer は libs/gui に委譲する。

const std = @import("std");
const platform = @import("platform");
const gui = @import("gui");

const WINDOW_W: u32 = 1024;
const WINDOW_H: u32 = 640;
const SCHEMA = "v0";

const Section = enum(u8) {
    overview,
    basic,
    text,
    values,
    color,
    layout,
    menus,
    stepgrid,
    missing,
};

const SectionMeta = struct {
    name: []const u8,
    detail: []const u8,
    widgets: u8,
    missing: u8,
};

const SECTIONS = [_]SectionMeta{
    .{ .name = "overview", .detail = "three axes: widget / state / context", .widgets = 0, .missing = 15 },
    .{ .name = "basic", .detail = "button / label", .widgets = 2, .missing = 0 },
    .{ .name = "text", .detail = "selectableLabel / textInputId", .widgets = 2, .missing = 0 },
    .{ .name = "values", .detail = "slider / checkbox / toggle / radio", .widgets = 4, .missing = 0 },
    .{ .name = "color", .detail = "colorSwatch / SV+hue / imageBox", .widgets = 3, .missing = 0 },
    .{ .name = "layout", .detail = "splitter / scrollArea", .widgets = 2, .missing = 0 },
    .{ .name = "menus", .detail = "popup/contextMenu / menuBar", .widgets = 2, .missing = 0 },
    .{ .name = "stepgrid", .detail = "stepgrid.widgetRow", .widgets = 1, .missing = 0 },
    .{ .name = "missing", .detail = "APG / ImGui gaps (placeholder only)", .widgets = 15, .missing = 15 },
};

const MatrixRow = struct {
    name: []const u8,
    cells: [9][]const u8,
};

const BASIC_MATRIX = [_]MatrixRow{
    .{ .name = "button", .cells = .{ "✓", "demo", "demo", "N/A", "N/A", "✓", "N/A", "N/A", "N/A" } },
    .{ .name = "label", .cells = .{ "✓", "N/A", "N/A", "N/A", "N/A", "✓", "N/A", "N/A", "N/A" } },
};
const TEXT_MATRIX = [_]MatrixRow{
    .{ .name = "selectableLabel", .cells = .{ "✓", "N/A", "drag", "✓", "N/A", "✓", "N/A", "N/A", "✓" } },
    .{ .name = "textInputId", .cells = .{ "✓", "demo", "demo", "✓", "N/A", "✓", "N/A", "N/A", "✓" } },
};
const VALUES_MATRIX = [_]MatrixRow{
    .{ .name = "slider i32/f32", .cells = .{ "✓", "demo", "demo", "N/A", "N/A", "N/A", "✓", "✓", "N/A" } },
    .{ .name = "checkbox", .cells = .{ "✓", "demo", "demo", "N/A", "N/A", "✓", "N/A", "N/A", "N/A" } },
    .{ .name = "toggle", .cells = .{ "✓", "demo", "demo", "N/A", "N/A", "✓", "N/A", "N/A", "N/A" } },
    .{ .name = "radio", .cells = .{ "✓", "demo", "demo", "N/A", "N/A", "✓", "N/A", "N/A", "✓" } },
};
const COLOR_MATRIX = [_]MatrixRow{
    .{ .name = "colorSwatch", .cells = .{ "✓", "demo", "demo", "N/A", "N/A", "N/A", "N/A", "N/A", "✓" } },
    .{ .name = "SV / hue", .cells = .{ "✓", "demo", "demo", "N/A", "N/A", "N/A", "✓", "✓", "N/A" } },
    .{ .name = "imageBox", .cells = .{ "✓", "N/A", "N/A", "N/A", "N/A", "N/A", "N/A", "N/A", "N/A" } },
};
const LAYOUT_MATRIX = [_]MatrixRow{
    .{ .name = "splitter", .cells = .{ "✓", "demo", "demo", "N/A", "N/A", "N/A", "✓", "✓", "N/A" } },
    .{ .name = "scrollArea", .cells = .{ "✓", "demo", "demo", "N/A", "N/A", "N/A", "✓", "✓", "N/A" } },
};
const MENUS_MATRIX = [_]MatrixRow{
    .{ .name = "popup/context", .cells = .{ "✓", "✓", "✓", "N/A", "✓ item", "N/A", "N/A", "N/A", "✓" } },
    .{ .name = "menuBar", .cells = .{ "✓", "demo", "demo", "N/A", "✓ command", "N/A", "N/A", "N/A", "✓" } },
};
const STEPGRID_MATRIX = [_]MatrixRow{
    .{ .name = "stepgrid", .cells = .{ "✓", "demo", "demo", "N/A", "partial", "✓", "N/A", "N/A", "✓" } },
};

const MissingEntry = struct { name: []const u8, target: []const u8 };
const MISSING = [_]MissingEntry{
    .{ .name = "Accordion", .target = "121.3" },
    .{ .name = "Alert / Message Dialog", .target = "121.2" },
    .{ .name = "Breadcrumb", .target = "121.3" },
    .{ .name = "Carousel", .target = "Phase 2" },
    .{ .name = "Combobox", .target = "121.3 / 121.4" },
    .{ .name = "Dialog (Modal)", .target = "121.3" },
    .{ .name = "Disclosure", .target = "121.3" },
    .{ .name = "Listbox", .target = "121.4" },
    .{ .name = "Meter", .target = "121.3" },
    .{ .name = "Spinbutton", .target = "121.3" },
    .{ .name = "Table", .target = "121.4" },
    .{ .name = "Tabs", .target = "121.3" },
    .{ .name = "Tooltip", .target = "121.3 / Phase 2" },
    .{ .name = "Tree View", .target = "121.4" },
    .{ .name = "Treegrid", .target = "Phase 2" },
};

const Ids = struct {
    const primary_button: gui.Id = 0x3501;
    const secondary_button: gui.Id = 0x3502;
    const text_input: gui.Id = 0x3510;
    const selectable: gui.Id = 0x3511;
    const slider_i32: gui.Id = 0x3520;
    const slider_f32: gui.Id = 0x3521;
    const checkbox: gui.Id = 0x3522;
    const toggle: gui.Id = 0x3523;
    const radio_pen: gui.Id = 0x3524;
    const radio_brush: gui.Id = 0x3525;
    const swatch: gui.Id = 0x3530;
    const sv: gui.Id = 0x3531;
    const hue: gui.Id = 0x3532;
    const image: gui.Id = 0x3533;
    const splitter: gui.Id = 0x3540;
    const scroll: gui.Id = 0x3541;
    const popup_trigger: gui.Id = 0x3550;
    const popup: gui.Id = 0x3551;
    const grid: gui.Id = 0x3560;
};

const image_pixels = [_]u32{
    0xFF20242C, 0xFF4A90E2, 0xFF20242C, 0xFFE0C050, 0xFF20242C, 0xFFE0C050, 0xFF20242C, 0xFF4A90E2,
    0xFF4A90E2, 0xFF20242C, 0xFFE0C050, 0xFF20242C, 0xFFE0C050, 0xFF20242C, 0xFF4A90E2, 0xFF20242C,
    0xFF20242C, 0xFFE0C050, 0xFF20242C, 0xFF4A90E2, 0xFF20242C, 0xFF4A90E2, 0xFF20242C, 0xFFE0C050,
    0xFFE0C050, 0xFF20242C, 0xFF4A90E2, 0xFF20242C, 0xFF4A90E2, 0xFF20242C, 0xFFE0C050, 0xFF20242C,
    0xFF20242C, 0xFF4A90E2, 0xFF20242C, 0xFFE0C050, 0xFF20242C, 0xFFE0C050, 0xFF20242C, 0xFF4A90E2,
    0xFF4A90E2, 0xFF20242C, 0xFFE0C050, 0xFF20242C, 0xFFE0C050, 0xFF20242C, 0xFF4A90E2, 0xFF20242C,
    0xFF20242C, 0xFFE0C050, 0xFF20242C, 0xFF4A90E2, 0xFF20242C, 0xFF4A90E2, 0xFF20242C, 0xFFE0C050,
    0xFFE0C050, 0xFF20242C, 0xFF4A90E2, 0xFF20242C, 0xFF4A90E2, 0xFF20242C, 0xFFE0C050, 0xFF20242C,
};

const popup_items = [_]gui.PopupItem{
    .{ .label = "Open context", .enabled = true },
    .{ .label = "Disabled action", .enabled = false },
};

const commands = [_]gui.Command{
    .{ .id = 1, .label = "Open", .menu = .{ .title = "File", .order = 0 }, .shortcut = .{ .key = .O, .modifiers = .{ .cmd = true } } },
    .{ .id = 2, .label = "Save (disabled)", .menu = .{ .title = "File", .order = 1 }, .enabled = false },
    .{ .id = 0, .menu = .{ .title = "File", .order = 2 }, .kind = .separator },
    .{ .id = 3, .label = "Show grid", .menu = .{ .title = "View", .order = 0 }, .checked = true },
};

const App = struct {
    ctx: *gui.Context,
    section: u8 = 0,
    clicks: u32 = 0,
    slider_i32: i32 = 0,
    slider_f32: f32 = 0.5,
    checked: bool = true,
    toggled: bool = false,
    radio_brush: bool = false,
    hue: f32 = 210,
    saturation: f32 = 0.65,
    value: f32 = 0.8,
    splitter_size: i32 = 250,
    scroll: gui.Vec2f = .{},
    menu: gui.MenuBarState = .{},
    text: *gui.TextBuffer,

    fn current(self: *const App) Section {
        return @enumFromInt(self.section);
    }

    fn changeSection(self: *App, delta: i8) void {
        const count: i16 = @intCast(SECTIONS.len);
        var next: i16 = @as(i16, self.section) + delta;
        if (next < 0) next = count - 1;
        if (next >= count) next = 0;
        self.section = @intCast(next);
        self.menu.open_title = null;
        self.menu.switch_click = false;
        self.ctx.closePopup();
        self.ctx.state.hot_id = 0;
        self.ctx.state.next_hot_id = 0;
        self.ctx.state.active_id = 0;
        self.ctx.state.focused_id = 0;
    }

    fn widgetName(self: *const App, id: gui.Id) []const u8 {
        if (id >= Ids.grid and id < Ids.grid + 16) return "stepgrid";
        return switch (id) {
            0 => "none",
            Ids.primary_button, Ids.secondary_button => "button",
            Ids.text_input => "textInputId",
            Ids.selectable => "selectableLabelId",
            Ids.slider_i32, Ids.slider_f32 => "slider",
            Ids.checkbox => "checkbox",
            Ids.toggle => "toggle",
            Ids.radio_pen, Ids.radio_brush => "radio",
            Ids.swatch => "colorSwatch",
            Ids.sv => "svSquare",
            Ids.hue => "hueBar",
            Ids.image => "imageBox",
            Ids.splitter => "splitter",
            Ids.scroll => "scrollArea",
            Ids.popup_trigger, Ids.popup => "popup",
            else => if (self.current() == .menus) "menuBar" else "none",
        };
    }
};

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
        .quit, .char_input => null,
        .gamepad_connected, .gamepad_disconnected => null,
        .composition_changed => null,
        .menu_command => null,
        .mouse_move => |m| .{ .mouse_move = .{ .x = m.x, .y = m.y, .modifiers = m.modifiers.toC() } },
        .mouse_down => |m| .{ .mouse_down = .{ .x = m.x, .y = m.y, .button = buttonToU8(m.button), .modifiers = m.modifiers.toC() } },
        .mouse_up => |m| .{ .mouse_up = .{ .x = m.x, .y = m.y, .button = buttonToU8(m.button), .modifiers = m.modifiers.toC() } },
        .mouse_scroll => |s| .{ .mouse_scroll = .{ .x = s.x, .y = s.y, .dx = s.dx, .dy = s.dy, .modifiers = s.modifiers.toC() } },
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

fn galleryDigest(ctx_ptr: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx_ptr));
    const meta = SECTIONS[app.section];
    return std.fmt.bufPrint(buf, "section={s} index={d} widgets={d} missing={d} schema={s} hot={s} active={s} focused={s}", .{
        meta.name,
        app.section,
        meta.widgets,
        meta.missing,
        SCHEMA,
        app.widgetName(app.ctx.state.hot_id),
        app.widgetName(app.ctx.state.active_id),
        app.widgetName(app.ctx.state.focused_id),
    }) catch buf[0..0];
}

fn matrixFor(section: Section) []const MatrixRow {
    return switch (section) {
        .basic => &BASIC_MATRIX,
        .text => &TEXT_MATRIX,
        .values => &VALUES_MATRIX,
        .color => &COLOR_MATRIX,
        .layout => &LAYOUT_MATRIX,
        .menus => &MENUS_MATRIX,
        .stepgrid => &STEPGRID_MATRIX,
        else => &.{},
    };
}

fn renderMatrix(ctx: *gui.Context, rows: []const MatrixRow) void {
    ctx.labelEx("normal hover active focused disabled empty min max none", ctx.style.text_subtle);
    for (rows) |row| {
        ctx.beginBox(.{ .direction = .row, .gap = 2 });
        ctx.beginBox(.{ .width = .{ .fixed = 104 } });
        ctx.label(row.name);
        ctx.endBox();
        for (row.cells) |cell| {
            ctx.beginBox(.{ .width = .{ .fixed = 34 } });
            ctx.label(cell);
            ctx.endBox();
        }
        ctx.endBox();
    }
}

fn renderOverview(ctx: *gui.Context) void {
    ctx.label("APG: living patterns / ImGui: demo sections / libs/gui: current API");
    ctx.label("State axis: normal hover active focused disabled empty min max none");
    ctx.label("Use PAGE_DOWN / PAGE_UP to cycle sections.");
    ctx.label("Current implementation is normal + endpoint focused; demo cells are exercised by E2E.");
    ctx.beginBox(.{ .direction = .row, .gap = 12 });
    ctx.beginBox(.{ .width = .{ .fixed = 270 }, .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF), .padding = .{ 8, 8, 8, 8 } });
    ctx.label("Existing API: 16 semantic widgets");
    ctx.label("Missing placeholders: 15");
    ctx.label("Context: normal / demo / gaps");
    ctx.endBox();
    ctx.beginBox(.{ .width = .{ .fixed = 270 }, .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF), .padding = .{ 8, 8, 8, 8 } });
    ctx.label("APG × ImGui × libs/gui");
    ctx.label("See docs/plans/PLAN_gui_capability_matrix.md");
    ctx.label("TASK-121.2 owns abnormal cases");
    ctx.endBox();
    ctx.endBox();
}

fn renderBasic(ctx: *gui.Context, app: *App) void {
    if (ctx.buttonId(Ids.primary_button, "Primary button", .{ .min_w = 160 }).clicked) app.clicks += 1;
    ctx.label("Label: normal text / empty text is documented as ✓");
    if (ctx.buttonId(Ids.secondary_button, "Secondary", .{ .min_w = 160 }).clicked) app.clicks += 1;
    var buf: [32]u8 = undefined;
    ctx.labelEx(std.fmt.bufPrint(&buf, "clicked={d}", .{app.clicks}) catch "clicked=?", ctx.style.text_subtle);
}

fn renderText(ctx: *gui.Context, app: *App) void {
    _ = ctx.textInputId(Ids.text_input, app.text, .{ .width = .{ .fixed = 320 }, .placeholder = "empty" });
    _ = ctx.selectableLabelId(Ids.selectable, "Selectable label (drag)", .{});
}

fn renderValues(ctx: *gui.Context, app: *App) void {
    ctx.beginBox(.{ .direction = .row, .gap = 12 });
    _ = ctx.sliderI32Id(Ids.slider_i32, "i32", &app.slider_i32, .{ .min = -10, .max = 10, .step = 1, .track_w = 180 });
    _ = ctx.sliderF32Id(Ids.slider_f32, "f32", &app.slider_f32, .{ .min = 0, .max = 1, .step = 0.05, .track_w = 180 });
    ctx.endBox();
    _ = ctx.checkboxId(Ids.checkbox, "Checkbox", &app.checked);
    _ = ctx.toggleId(Ids.toggle, "Toggle", &app.toggled);
    ctx.beginBox(.{ .direction = .row, .gap = 12 });
    if (ctx.radioId(Ids.radio_pen, "Pen", !app.radio_brush)) app.radio_brush = false;
    if (ctx.radioId(Ids.radio_brush, "Brush", app.radio_brush)) app.radio_brush = true;
    ctx.endBox();
}

fn renderColor(ctx: *gui.Context, app: *App) void {
    ctx.beginBox(.{ .direction = .row, .gap = 12 });
    _ = ctx.colorSwatchId(Ids.swatch, .{ .color = gui.Color.fromHsv(app.hue, app.saturation, app.value), .selected = true, .size = 64 });
    _ = ctx.svSquareId(Ids.sv, app.hue, &app.saturation, &app.value, .{ .size = 96 });
    _ = ctx.hueBarId(Ids.hue, &app.hue, .{ .w = 16, .h = 96 });
    ctx.imageBox(Ids.image, &image_pixels, 8, 8, .{ .border = gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF) });
    ctx.endBox();
    ctx.label("HSV controls use libs/gui gradient buffers; gallery adds no rasterizer.");
}

fn renderLayout(ctx: *gui.Context, app: *App) void {
    ctx.beginBox(.{ .direction = .row, .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .gap = 8 });
    ctx.beginBox(.{ .width = .{ .fixed = 250 }, .height = .{ .grow = 1 }, .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF), .padding = .{ 8, 8, 8, 8 } });
    ctx.label("left pane");
    ctx.label("splitter is draggable");
    ctx.endBox();
    _ = ctx.splitter(Ids.splitter, .vertical, &app.splitter_size, .{ .min = 160, .max = 400 });
    ctx.beginScrollArea(Ids.scroll, &app.scroll, .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .padding = .{ 8, 8, 8, 8 }, .gap = 4, .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF) });
    ctx.label("scroll viewport");
    for (0..24) |i| {
        var buf: [32]u8 = undefined;
        ctx.label(std.fmt.bufPrint(&buf, "content row {d}", .{i}) catch "content row ?");
    }
    ctx.endScrollArea();
    ctx.endBox();
}

fn renderMenus(ctx: *gui.Context, app: *App) void {
    ctx.beginBox(.{ .direction = .column, .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .gap = 10 });
    ctx.beginBox(.{ .direction = .row, .height = .{ .fixed = 32 }, .gap = 8 });
    ctx.beginBox(.{ .width = .{ .fixed = 160 } });
    ctx.endBox();
    gui.menuBar(ctx, &commands, &app.menu);
    ctx.endBox();
    if (ctx.buttonId(Ids.popup_trigger, "Open context popup", .{ .min_w = 180 }).clicked) {
        ctx.openPopup(Ids.popup, .{ .x = 160, .y = 128 });
    }
    ctx.label("PopupItem and Command expose enabled / disabled / checked / shortcut / separator.");
    ctx.endBox();
}

fn renderStepgrid(ctx: *gui.Context) void {
    ctx.label("16 steps / explicit id_base / editable caller state");
    _ = gui.stepgrid.widgetRow(ctx, .{ .id_base = Ids.grid, .mask = 0b1010_1010_1010_1010, .cell_size = 20, .editable = true });
}

fn renderMissing(ctx: *gui.Context) void {
    ctx.beginBox(.{ .direction = .row, .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .gap = 6 });
    var i: usize = 0;
    while (i < MISSING.len) : (i += 1) {
        if (i % 3 == 0) {
            if (i != 0) ctx.endBox();
            ctx.beginBox(.{ .direction = .column, .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .gap = 6 });
        }
        const item = MISSING[i];
        ctx.beginBox(.{ .height = .{ .fixed = 54 }, .bg = gui.Color.rgba(0x30, 0x24, 0x2C, 0xFF), .padding = .{ 6, 6, 6, 6 } });
        ctx.label(item.name);
        ctx.labelEx("NOT IMPLEMENTED", gui.Color.rgba(0xFF, 0xB0, 0x80, 0xFF));
        ctx.labelEx(item.target, ctx.style.text_subtle);
        ctx.endBox();
    }
    ctx.endBox();
    ctx.endBox();
}

fn renderSection(ctx: *gui.Context, app: *App) void {
    switch (app.current()) {
        .overview => renderOverview(ctx),
        .basic => renderBasic(ctx, app),
        .text => renderText(ctx, app),
        .values => renderValues(ctx, app),
        .color => renderColor(ctx, app),
        .layout => renderLayout(ctx, app),
        .menus => renderMenus(ctx, app),
        .stepgrid => renderStepgrid(ctx),
        .missing => renderMissing(ctx),
    }
}

fn renderFrame(ctx: *gui.Context, app: *App) void {
    ctx.beginBox(.{ .direction = .column, .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .padding = .{ 16, 16, 16, 16 }, .gap = 16, .bg = gui.Color.rgba(0x18, 0x1C, 0x24, 0xFF) });
    const meta = SECTIONS[app.section];
    ctx.beginBox(.{ .height = .{ .fixed = 64 }, .width = .{ .grow = 1 }, .padding = .{ 8, 8, 8, 8 }, .bg = gui.Color.rgba(0x28, 0x30, 0x3C, 0xFF) });
    ctx.label("GUI Capability Gallery v0");
    var section_buf: [128]u8 = undefined;
    ctx.labelEx(std.fmt.bufPrint(&section_buf, "section {d}/8: {s} — {s}", .{ app.section, meta.name, meta.detail }) catch "section=?", ctx.style.text_subtle);
    ctx.labelEx("PAGE_DOWN / PAGE_UP: navigate | ESC / Q: quit", ctx.style.text_subtle);
    ctx.endBox();

    if (app.current() == .menus) {
        renderMenus(ctx, app);
    } else if (app.current() == .overview or app.current() == .missing) {
        ctx.beginBox(.{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .padding = .{ 16, 16, 16, 16 }, .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF) });
        renderSection(ctx, app);
        ctx.endBox();
    } else {
        ctx.beginBox(.{ .direction = .row, .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .padding = .{ 16, 16, 16, 16 }, .gap = 16, .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF) });
        ctx.beginBox(.{ .width = .{ .fixed = 620 }, .height = .{ .grow = 1 }, .gap = 10 });
        renderSection(ctx, app);
        ctx.endBox();
        ctx.beginBox(.{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .padding = .{ 8, 8, 8, 8 }, .bg = gui.Color.rgba(0x28, 0x30, 0x3C, 0xFF) });
        ctx.label("State matrix");
        renderMatrix(ctx, matrixFor(app.current()));
        ctx.endBox();
        ctx.endBox();
    }
    ctx.endBox();
    ctx.endFrame();
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WINDOW_W, WINDOW_H, "GUI Capability Gallery v0");
    defer window.destroy();
    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();
    var text = try gui.TextBuffer.init(gpa, "edit me");
    defer text.deinit();
    var app: App = .{ .ctx = &ctx, .text = &text };
    platform.registerProbe(.{ .name = "gallery", .ctx = &app, .ext = "txt", .digest = galleryDigest, .desc = "GUI capability gallery section/state matrix" });

    var running = true;
    main_loop: while (running and window.pollEvents()) {
        const fb = window.lockFramebuffer() orelse continue :main_loop;
        defer fb.unlock();
        @memset(fb.pixels, 0xFF_18_1C_24);
        ctx.beginFrame(fb.width, fb.height);

        while (window.nextEvent()) |ev| {
            switch (ev) {
                .quit => running = false,
                .key_down => |k| switch (k.key) {
                    .ESCAPE, .Q => running = false,
                    .PAGE_DOWN => app.changeSection(1),
                    .PAGE_UP => app.changeSection(-1),
                    else => {},
                },
                else => {},
            }
            if (toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
        }

        renderFrame(&ctx, &app);
        _ = gui.menuBarPopup(&ctx, &commands, &app.menu);
        _ = ctx.popupMenu(Ids.popup, &popup_items);
        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        gui.render(target, &ctx.draw_list, ctx.font);
        window.present();
    }
}
