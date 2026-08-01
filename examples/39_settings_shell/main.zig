//! GUI settings shell benchmark.
//!
//! VS Code / System Settings-style settings shell. Left nav + right form with 3 sections.
//! The left nav is `gui.tabId` (selected-section semantics); the forms use existing widgets.
//!
//! Hot path declaration:
//! - Widget build and DrawList command appends are per-frame. O(N) in the selected form's control count.
//! - No new all-pixel loop, full framebuffer copy, custom rasterizer, or RT path.
//! - custom probe digest only on harness request. Env reads at init only.

const std = @import("std");
const platform = @import("platform");
const gui = @import("gui");

const DEFAULT_W: u32 = 1024;
const DEFAULT_H: u32 = 768;
const MAX_DIM: u32 = 4096;

const Section = enum(u8) {
    general,
    editor,
    audio,
};

const Theme = enum { system, light, dark };
const IndentStyle = enum { tabs, spaces };
const FontFamily = enum { system, monospace };
const OutputDevice = enum { default, headphones };
const BufferSize = enum { low, medium, high };

const Ids = struct {
    const nav_general: gui.Id = 0x3901;
    const nav_editor: gui.Id = 0x3902;
    const nav_audio: gui.Id = 0x3903;

    const general_scroll: gui.Id = 0x3910;
    const general_launch_at_login: gui.Id = 0x3920;
    const general_check_updates: gui.Id = 0x3921;
    const general_send_telemetry: gui.Id = 0x3922;
    const general_show_notifications: gui.Id = 0x3923;
    const general_use_native_dialogs: gui.Id = 0x3924;
    const general_theme_system: gui.Id = 0x3925;
    const general_theme_light: gui.Id = 0x3926;
    const general_theme_dark: gui.Id = 0x3927;
    const general_ui_scale: gui.Id = 0x3928;
    const general_interface_opacity: gui.Id = 0x3929;
    const general_settings_path: gui.Id = 0x392A;

    const editor_scroll: gui.Id = 0x3930;
    const editor_word_wrap: gui.Id = 0x3940;
    const editor_show_minimap: gui.Id = 0x3941;
    const editor_format_on_save: gui.Id = 0x3942;
    const editor_auto_indent: gui.Id = 0x3943;
    const editor_bracket_pair_colorization: gui.Id = 0x3944;
    const editor_indent_tabs: gui.Id = 0x3945;
    const editor_indent_spaces: gui.Id = 0x3946;
    const editor_font_system: gui.Id = 0x3947;
    const editor_font_monospace: gui.Id = 0x3948;
    const editor_tab_width: gui.Id = 0x3949;
    const editor_font_size: gui.Id = 0x394A;
    const editor_workspace_path: gui.Id = 0x394B;

    const audio_scroll: gui.Id = 0x3950;
    const audio_enabled: gui.Id = 0x3960;
    const audio_exclusive_mode: gui.Id = 0x3961;
    const audio_show_meter: gui.Id = 0x3962;
    const audio_input_monitor: gui.Id = 0x3963;
    const audio_normalize_output: gui.Id = 0x3964;
    const audio_output_default: gui.Id = 0x3965;
    const audio_output_headphones: gui.Id = 0x3966;
    const audio_buffer_low: gui.Id = 0x3967;
    const audio_buffer_medium: gui.Id = 0x3968;
    const audio_buffer_high: gui.Id = 0x3969;
    const audio_master_volume: gui.Id = 0x396A;
    const audio_balance: gui.Id = 0x396B;
    const audio_cache_path: gui.Id = 0x396C;
};

const GeneralState = struct {
    launch_at_login: bool = false,
    check_updates: bool = true,
    send_telemetry: bool = false,
    show_notifications: bool = true,
    use_native_dialogs: bool = true,
    theme: Theme = .system,
    ui_scale: i32 = 100,
    interface_opacity: f32 = 1.0,
    settings_path: *gui.TextBuffer,
    scroll: gui.Vec2f = .{},
};

const EditorState = struct {
    word_wrap: bool = true,
    show_minimap: bool = true,
    format_on_save: bool = false,
    auto_indent: bool = true,
    bracket_pair_colorization: bool = true,
    indent_style: IndentStyle = .spaces,
    font_family: FontFamily = .monospace,
    tab_width: i32 = 4,
    font_size: f32 = 14.0,
    workspace_path: *gui.TextBuffer,
    scroll: gui.Vec2f = .{},
};

const AudioState = struct {
    audio_enabled: bool = true,
    exclusive_mode: bool = false,
    show_meter: bool = true,
    input_monitor: bool = false,
    normalize_output: bool = true,
    output: OutputDevice = .default,
    buffer_size: BufferSize = .medium,
    master_volume: i32 = 80,
    balance: f32 = 0.0,
    audio_cache_path: *gui.TextBuffer,
    scroll: gui.Vec2f = .{},
};

const App = struct {
    ctx: *gui.Context,
    screen_w: u32,
    screen_h: u32,
    section: Section = .general,
    general: GeneralState,
    editor: EditorState,
    audio: AudioState,
    paste_buf: [4096]u8 = undefined,
    paste_text: ?[]const u8 = null,
};

fn envSlice(name: [*:0]const u8) ?[]const u8 {
    const p = std.c.getenv(name) orelse return null;
    return std.mem.span(p);
}

fn parseDim(env: ?[]const u8, default: u32, name: []const u8) u32 {
    const raw = env orelse return default;
    const v = std.fmt.parseInt(u32, raw, 10) catch {
        std.log.warn("{s}={s} is not a u32; using default {d}", .{ name, raw, default });
        return default;
    };
    if (v == 0) {
        std.log.warn("{s}=0 is invalid; using default {d}", .{ name, default });
        return default;
    }
    return @min(v, MAX_DIM);
}

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
        .quit => null,
        .gamepad_connected, .gamepad_disconnected => null,
        .composition_changed => null,
        .menu_command => null,
        .file_drop => null,
        .char_input => |ch| .{
            .char_input = .{
                .codepoint = ch.codepoint,
                .modifiers = ch.modifiers.toC(),
            },
        },
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

fn appendFmt(buf: []u8, off: *usize, comptime fmt: []const u8, args: anytype) void {
    if (off.* >= buf.len) return;
    const written = std.fmt.bufPrint(buf[off.*..], fmt, args) catch {
        off.* = buf.len;
        return;
    };
    off.* += written.len;
}

fn pathBytesCrc(buf: *const gui.TextBuffer) struct { bytes: usize, crc: u32 } {
    const s = buf.slice();
    return .{ .bytes = s.len, .crc = std.hash.Crc32.hash(s) };
}

fn widgetName(id: gui.Id) []const u8 {
    if (id == 0) return "none";
    return switch (id) {
        Ids.nav_general => "nav.general",
        Ids.nav_editor => "nav.editor",
        Ids.nav_audio => "nav.audio",
        Ids.general_scroll => "general.scroll",
        Ids.general_launch_at_login => "general.launch_at_login",
        Ids.general_check_updates => "general.check_updates",
        Ids.general_send_telemetry => "general.send_telemetry",
        Ids.general_show_notifications => "general.show_notifications",
        Ids.general_use_native_dialogs => "general.use_native_dialogs",
        Ids.general_theme_system => "general.theme_system",
        Ids.general_theme_light => "general.theme_light",
        Ids.general_theme_dark => "general.theme_dark",
        Ids.general_ui_scale => "general.ui_scale",
        Ids.general_interface_opacity => "general.interface_opacity",
        Ids.general_settings_path => "general.settings_path",
        Ids.editor_scroll => "editor.scroll",
        Ids.editor_word_wrap => "editor.word_wrap",
        Ids.editor_show_minimap => "editor.show_minimap",
        Ids.editor_format_on_save => "editor.format_on_save",
        Ids.editor_auto_indent => "editor.auto_indent",
        Ids.editor_bracket_pair_colorization => "editor.bracket_pair_colorization",
        Ids.editor_indent_tabs => "editor.indent_tabs",
        Ids.editor_indent_spaces => "editor.indent_spaces",
        Ids.editor_font_system => "editor.font_system",
        Ids.editor_font_monospace => "editor.font_monospace",
        Ids.editor_tab_width => "editor.tab_width",
        Ids.editor_font_size => "editor.font_size",
        Ids.editor_workspace_path => "editor.workspace_path",
        Ids.audio_scroll => "audio.scroll",
        Ids.audio_enabled => "audio.audio_enabled",
        Ids.audio_exclusive_mode => "audio.exclusive_mode",
        Ids.audio_show_meter => "audio.show_meter",
        Ids.audio_input_monitor => "audio.input_monitor",
        Ids.audio_normalize_output => "audio.normalize_output",
        Ids.audio_output_default => "audio.output_default",
        Ids.audio_output_headphones => "audio.output_headphones",
        Ids.audio_buffer_low => "audio.buffer_low",
        Ids.audio_buffer_medium => "audio.buffer_medium",
        Ids.audio_buffer_high => "audio.buffer_high",
        Ids.audio_master_volume => "audio.master_volume",
        Ids.audio_balance => "audio.balance",
        Ids.audio_cache_path => "audio.cache_path",
        else => "none",
    };
}

fn stateDigest(ctx_ptr: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx_ptr));
    const ctx = app.ctx;
    var off: usize = 0;

    const gsp = pathBytesCrc(app.general.settings_path);
    const ewp = pathBytesCrc(app.editor.workspace_path);
    const acp = pathBytesCrc(app.audio.audio_cache_path);

    appendFmt(buf, &off, "schema=1 selected={s} focused={s} active={s} hot={s}", .{
        @tagName(app.section),
        widgetName(ctx.state.focused_id),
        widgetName(ctx.state.active_id),
        widgetName(ctx.state.hot_id),
    });
    appendFmt(buf, &off, " general_scroll_y={d} editor_scroll_y={d} audio_scroll_y={d}", .{
        @as(i32, @intFromFloat(@round(app.general.scroll.y))),
        @as(i32, @intFromFloat(@round(app.editor.scroll.y))),
        @as(i32, @intFromFloat(@round(app.audio.scroll.y))),
    });
    appendFmt(buf, &off, " general_launch_at_login={d} general_check_updates={d} general_send_telemetry={d}", .{
        @as(u32, if (app.general.launch_at_login) 1 else 0),
        @as(u32, if (app.general.check_updates) 1 else 0),
        @as(u32, if (app.general.send_telemetry) 1 else 0),
    });
    appendFmt(buf, &off, " general_show_notifications={d} general_use_native_dialogs={d} general_theme={s}", .{
        @as(u32, if (app.general.show_notifications) 1 else 0),
        @as(u32, if (app.general.use_native_dialogs) 1 else 0),
        @tagName(app.general.theme),
    });
    appendFmt(buf, &off, " general_ui_scale={d} general_interface_opacity={d:.2}", .{
        app.general.ui_scale,
        app.general.interface_opacity,
    });
    appendFmt(buf, &off, " general_settings_path_bytes={d} general_settings_path_crc={X:0>8}", .{
        gsp.bytes,
        gsp.crc,
    });
    appendFmt(buf, &off, " editor_word_wrap={d} editor_show_minimap={d} editor_format_on_save={d}", .{
        @as(u32, if (app.editor.word_wrap) 1 else 0),
        @as(u32, if (app.editor.show_minimap) 1 else 0),
        @as(u32, if (app.editor.format_on_save) 1 else 0),
    });
    appendFmt(buf, &off, " editor_auto_indent={d} editor_bracket_pair_colorization={d}", .{
        @as(u32, if (app.editor.auto_indent) 1 else 0),
        @as(u32, if (app.editor.bracket_pair_colorization) 1 else 0),
    });
    appendFmt(buf, &off, " editor_indent_style={s} editor_font_family={s} editor_tab_width={d} editor_font_size={d:.2}", .{
        @tagName(app.editor.indent_style),
        @tagName(app.editor.font_family),
        app.editor.tab_width,
        app.editor.font_size,
    });
    appendFmt(buf, &off, " editor_workspace_path_bytes={d} editor_workspace_path_crc={X:0>8}", .{
        ewp.bytes,
        ewp.crc,
    });
    appendFmt(buf, &off, " audio_audio_enabled={d} audio_exclusive_mode={d} audio_show_meter={d}", .{
        @as(u32, if (app.audio.audio_enabled) 1 else 0),
        @as(u32, if (app.audio.exclusive_mode) 1 else 0),
        @as(u32, if (app.audio.show_meter) 1 else 0),
    });
    appendFmt(buf, &off, " audio_input_monitor={d} audio_normalize_output={d} audio_output={s} audio_buffer_size={s}", .{
        @as(u32, if (app.audio.input_monitor) 1 else 0),
        @as(u32, if (app.audio.normalize_output) 1 else 0),
        @tagName(app.audio.output),
        @tagName(app.audio.buffer_size),
    });
    appendFmt(buf, &off, " audio_master_volume={d} audio_balance={d:.2}", .{
        app.audio.master_volume,
        app.audio.balance,
    });
    appendFmt(buf, &off, " audio_cache_path_bytes={d} audio_cache_path_crc={X:0>8}", .{
        acp.bytes,
        acp.crc,
    });
    return buf[0..off];
}

fn rectCsv(app: *const App, id: gui.Id, key: []const u8, buf: []u8, off: *usize) void {
    if (app.ctx.getNodeRect(id)) |r| {
        appendFmt(buf, off, " {s}={d},{d},{d},{d}", .{ key, r.x, r.y, r.w, r.h });
    } else {
        appendFmt(buf, off, " {s}=-1,-1,-1,-1", .{key});
    }
}

fn layoutDigest(ctx_ptr: *anyopaque, buf: []u8) []const u8 {
    // 1024B contract: rects as comma-joined x,y,w,h. Only E2E targets + nav + selected scroll.
    const app: *App = @ptrCast(@alignCast(ctx_ptr));
    var off: usize = 0;
    appendFmt(buf, &off, "schema=1 screen_w={d} screen_h={d} selected={s}", .{
        app.screen_w,
        app.screen_h,
        @tagName(app.section),
    });
    rectCsv(app, Ids.nav_general, "nav_general", buf, &off);
    rectCsv(app, Ids.nav_editor, "nav_editor", buf, &off);
    rectCsv(app, Ids.nav_audio, "nav_audio", buf, &off);

    switch (app.section) {
        .general => rectCsv(app, Ids.general_scroll, "general_scroll", buf, &off),
        .editor => rectCsv(app, Ids.editor_scroll, "editor_scroll", buf, &off),
        .audio => rectCsv(app, Ids.audio_scroll, "audio_scroll", buf, &off),
    }

    // E2E interaction targets (hidden → -1)
    if (app.section == .general) {
        rectCsv(app, Ids.general_launch_at_login, "general_launch_at_login", buf, &off);
        rectCsv(app, Ids.general_ui_scale, "general_ui_scale", buf, &off);
        rectCsv(app, Ids.general_settings_path, "general_settings_path", buf, &off);
    } else {
        appendFmt(buf, &off, " general_launch_at_login=-1,-1,-1,-1 general_ui_scale=-1,-1,-1,-1 general_settings_path=-1,-1,-1,-1", .{});
    }
    if (app.section == .editor) {
        rectCsv(app, Ids.editor_format_on_save, "editor_format_on_save", buf, &off);
        rectCsv(app, Ids.editor_workspace_path, "editor_workspace_path", buf, &off);
    } else {
        appendFmt(buf, &off, " editor_format_on_save=-1,-1,-1,-1 editor_workspace_path=-1,-1,-1,-1", .{});
    }
    if (app.section == .audio) {
        rectCsv(app, Ids.audio_output_headphones, "audio_output_headphones", buf, &off);
        rectCsv(app, Ids.audio_buffer_high, "audio_buffer_high", buf, &off);
    } else {
        appendFmt(buf, &off, " audio_output_headphones=-1,-1,-1,-1 audio_buffer_high=-1,-1,-1,-1", .{});
    }
    return buf[0..off];
}

fn formSpacer(ctx: *gui.Context, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        ctx.labelEx(" ", ctx.style.text_subtle);
    }
}

fn renderNav(ctx: *gui.Context, app: *App) void {
    const nav_w: i32 = 148;

    const items = [_]struct { id: gui.Id, label: []const u8, section: Section }{
        .{ .id = Ids.nav_general, .label = "General", .section = .general },
        .{ .id = Ids.nav_editor, .label = "Editor", .section = .editor },
        .{ .id = Ids.nav_audio, .label = "Audio", .section = .audio },
    };

    for (items) |it| {
        const res = ctx.tabId(it.id, it.label, app.section == it.section, .{
            .width = .{ .fixed = nav_w },
            .height = .{ .fixed = 28 },
            .padding = .{ 4, 8, 4, 8 },
        });
        // Selection follows focus: a click focuses immediately, and Tab traversal reaches a
        // tab one frame later (ADR-021), so this stays in step with either path.
        if (res.focused) app.section = it.section;
    }
}

fn renderGeneral(ctx: *gui.Context, app: *App) void {
    ctx.beginScrollArea(Ids.general_scroll, &app.general.scroll, .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 12, 12, 12, 12 },
        .gap = 8,
        .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
    });
    ctx.label("General");
    ctx.labelEx("Application-wide preferences and appearance.", ctx.style.text_subtle);
    formSpacer(ctx, 1);

    ctx.label("Startup");
    _ = ctx.checkboxId(Ids.general_launch_at_login, "Launch at login", &app.general.launch_at_login);
    _ = ctx.checkboxId(Ids.general_check_updates, "Check for updates", &app.general.check_updates);
    _ = ctx.checkboxId(Ids.general_send_telemetry, "Send telemetry", &app.general.send_telemetry);

    ctx.label("Notifications");
    _ = ctx.toggleId(Ids.general_show_notifications, "Show notifications", &app.general.show_notifications);
    _ = ctx.toggleId(Ids.general_use_native_dialogs, "Use native dialogs", &app.general.use_native_dialogs);

    ctx.label("Theme");
    ctx.beginBox(.{ .direction = .row, .gap = 12 });
    if (ctx.radioId(Ids.general_theme_system, "System", app.general.theme == .system)) {
        app.general.theme = .system;
    }
    if (ctx.radioId(Ids.general_theme_light, "Light", app.general.theme == .light)) {
        app.general.theme = .light;
    }
    if (ctx.radioId(Ids.general_theme_dark, "Dark", app.general.theme == .dark)) {
        app.general.theme = .dark;
    }
    ctx.endBox();

    ctx.label("Scale & opacity");
    _ = ctx.sliderI32Id(Ids.general_ui_scale, "UI scale", &app.general.ui_scale, .{ .min = 50, .max = 200, .step = 1, .track_w = 180 });
    _ = ctx.sliderF32Id(Ids.general_interface_opacity, "Opacity", &app.general.interface_opacity, .{ .min = 0.2, .max = 1.0, .step = 0.05, .track_w = 180 });

    ctx.label("Paths");
    ctx.labelEx("Settings file path (text input).", ctx.style.text_subtle);
    _ = ctx.textInputId(Ids.general_settings_path, app.general.settings_path, .{
        .width = .{ .fixed = 320 },
        .placeholder = "/path/to/settings.conf",
        .paste_text = app.paste_text,
    });

    // Tall form: add spacer rows so 640x360 still needs scroll
    formSpacer(ctx, 8);
    ctx.labelEx("Additional notes: changes apply immediately.", ctx.style.text_subtle);
    ctx.labelEx("Scroll this panel on small windows.", ctx.style.text_subtle);
    formSpacer(ctx, 6);
    ctx.labelEx("End of General form.", ctx.style.text_subtle);
    ctx.endScrollArea();
}

fn renderEditor(ctx: *gui.Context, app: *App) void {
    ctx.beginScrollArea(Ids.editor_scroll, &app.editor.scroll, .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 12, 12, 12, 12 },
        .gap = 8,
        .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
    });
    ctx.label("Editor");
    ctx.labelEx("Text editing preferences for the workspace.", ctx.style.text_subtle);
    formSpacer(ctx, 1);

    ctx.label("Display");
    _ = ctx.checkboxId(Ids.editor_word_wrap, "Word wrap", &app.editor.word_wrap);
    _ = ctx.checkboxId(Ids.editor_show_minimap, "Show minimap", &app.editor.show_minimap);
    _ = ctx.checkboxId(Ids.editor_format_on_save, "Format on save", &app.editor.format_on_save);

    ctx.label("Editing");
    _ = ctx.toggleId(Ids.editor_auto_indent, "Auto indent", &app.editor.auto_indent);
    _ = ctx.toggleId(Ids.editor_bracket_pair_colorization, "Bracket pair colorization", &app.editor.bracket_pair_colorization);

    ctx.label("Indent style");
    ctx.beginBox(.{ .direction = .row, .gap = 12 });
    if (ctx.radioId(Ids.editor_indent_tabs, "Tabs", app.editor.indent_style == .tabs)) {
        app.editor.indent_style = .tabs;
    }
    if (ctx.radioId(Ids.editor_indent_spaces, "Spaces", app.editor.indent_style == .spaces)) {
        app.editor.indent_style = .spaces;
    }
    ctx.endBox();

    ctx.label("Font family");
    ctx.beginBox(.{ .direction = .row, .gap = 12 });
    if (ctx.radioId(Ids.editor_font_system, "System", app.editor.font_family == .system)) {
        app.editor.font_family = .system;
    }
    if (ctx.radioId(Ids.editor_font_monospace, "Monospace", app.editor.font_family == .monospace)) {
        app.editor.font_family = .monospace;
    }
    ctx.endBox();

    ctx.label("Sizes");
    _ = ctx.sliderI32Id(Ids.editor_tab_width, "Tab width", &app.editor.tab_width, .{ .min = 2, .max = 8, .step = 1, .track_w = 160 });
    _ = ctx.sliderF32Id(Ids.editor_font_size, "Font size", &app.editor.font_size, .{ .min = 8.0, .max = 32.0, .step = 0.5, .track_w = 160 });

    formSpacer(ctx, 4);
    ctx.labelEx("Workspace path lives near the bottom of this long form.", ctx.style.text_subtle);
    formSpacer(ctx, 6);
    ctx.label("Workspace");
    ctx.labelEx("Root directory for the current workspace.", ctx.style.text_subtle);
    _ = ctx.textInputId(Ids.editor_workspace_path, app.editor.workspace_path, .{
        .width = .{ .fixed = 320 },
        .placeholder = "/path/to/workspace",
        .paste_text = app.paste_text,
    });
    formSpacer(ctx, 4);
    ctx.labelEx("End of Editor form.", ctx.style.text_subtle);
    ctx.endScrollArea();
}

fn renderAudio(ctx: *gui.Context, app: *App) void {
    ctx.beginScrollArea(Ids.audio_scroll, &app.audio.scroll, .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 12, 12, 12, 12 },
        .gap = 8,
        .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
    });
    ctx.label("Audio");
    ctx.labelEx("Playback and capture device settings.", ctx.style.text_subtle);
    formSpacer(ctx, 1);

    ctx.label("Enablement");
    _ = ctx.checkboxId(Ids.audio_enabled, "Audio enabled", &app.audio.audio_enabled);
    _ = ctx.checkboxId(Ids.audio_exclusive_mode, "Exclusive mode", &app.audio.exclusive_mode);
    _ = ctx.checkboxId(Ids.audio_show_meter, "Show meter", &app.audio.show_meter);

    ctx.label("Routing");
    _ = ctx.toggleId(Ids.audio_input_monitor, "Input monitor", &app.audio.input_monitor);
    _ = ctx.toggleId(Ids.audio_normalize_output, "Normalize output", &app.audio.normalize_output);

    ctx.label("Output device");
    ctx.beginBox(.{ .direction = .row, .gap = 12 });
    if (ctx.radioId(Ids.audio_output_default, "Default", app.audio.output == .default)) {
        app.audio.output = .default;
    }
    if (ctx.radioId(Ids.audio_output_headphones, "Headphones", app.audio.output == .headphones)) {
        app.audio.output = .headphones;
    }
    ctx.endBox();

    ctx.label("Buffer size");
    ctx.beginBox(.{ .direction = .row, .gap = 12 });
    if (ctx.radioId(Ids.audio_buffer_low, "Low", app.audio.buffer_size == .low)) {
        app.audio.buffer_size = .low;
    }
    if (ctx.radioId(Ids.audio_buffer_medium, "Medium", app.audio.buffer_size == .medium)) {
        app.audio.buffer_size = .medium;
    }
    if (ctx.radioId(Ids.audio_buffer_high, "High", app.audio.buffer_size == .high)) {
        app.audio.buffer_size = .high;
    }
    ctx.endBox();

    ctx.label("Levels");
    _ = ctx.sliderI32Id(Ids.audio_master_volume, "Master volume", &app.audio.master_volume, .{ .min = 0, .max = 100, .step = 1, .track_w = 180 });
    _ = ctx.sliderF32Id(Ids.audio_balance, "Balance", &app.audio.balance, .{ .min = -1.0, .max = 1.0, .step = 0.05, .track_w = 180 });

    ctx.label("Cache");
    _ = ctx.textInputId(Ids.audio_cache_path, app.audio.audio_cache_path, .{
        .width = .{ .fixed = 320 },
        .placeholder = "/tmp/audio-cache",
        .paste_text = app.paste_text,
    });

    formSpacer(ctx, 8);
    ctx.labelEx("End of Audio form.", ctx.style.text_subtle);
    ctx.endScrollArea();
}

fn renderFrame(ctx: *gui.Context, app: *App) void {
    ctx.style = gui.defaultStyle();

    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 12, 12, 12, 12 },
        .gap = 10,
        .bg = gui.Color.rgba(0x18, 0x1C, 0x24, 0xFF),
    });

    // header
    ctx.beginBox(.{
        .height = .{ .fixed = 40 },
        .width = .{ .grow = 1 },
        .padding = .{ 6, 10, 6, 10 },
        .bg = gui.Color.rgba(0x28, 0x30, 0x3C, 0xFF),
        .align_cross = .center,
    });
    ctx.label("Settings");
    ctx.labelEx("General / Editor / Audio", ctx.style.text_subtle);
    ctx.endBox();

    // body row
    ctx.beginBox(.{
        .direction = .row,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .gap = 10,
    });

    // left nav
    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .fixed = 160 },
        .height = .{ .grow = 1 },
        .padding = .{ 8, 8, 8, 8 },
        .gap = 6,
        .bg = gui.Color.rgba(0x1C, 0x20, 0x28, 0xFF),
        .border = .{ .color = ctx.style.border, .thickness = 1 },
    });
    ctx.labelEx("Categories", ctx.style.text_subtle);
    renderNav(ctx, app);
    ctx.endBox();

    // right form
    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .border = .{ .color = ctx.style.border, .thickness = 1 },
    });
    switch (app.section) {
        .general => renderGeneral(ctx, app),
        .editor => renderEditor(ctx, app),
        .audio => renderAudio(ctx, app),
    }
    ctx.endBox();

    ctx.endBox(); // body
    ctx.endBox(); // root
    ctx.endFrame();
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    try platform.init();
    defer platform.shutdown();

    const screen_w = parseDim(envSlice("KNGN_GUI_WIDTH"), DEFAULT_W, "KNGN_GUI_WIDTH");
    const screen_h = parseDim(envSlice("KNGN_GUI_HEIGHT"), DEFAULT_H, "KNGN_GUI_HEIGHT");

    var window = try platform.Window.create(screen_w, screen_h, "Settings Shell");
    defer window.destroy();

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    var settings_path = try gui.TextBuffer.init(gpa, "");
    defer settings_path.deinit();
    var workspace_path = try gui.TextBuffer.init(gpa, "");
    defer workspace_path.deinit();
    var audio_cache_path = try gui.TextBuffer.init(gpa, "");
    defer audio_cache_path.deinit();

    var app: App = .{
        .ctx = &ctx,
        .screen_w = screen_w,
        .screen_h = screen_h,
        .general = .{ .settings_path = &settings_path },
        .editor = .{ .workspace_path = &workspace_path },
        .audio = .{ .audio_cache_path = &audio_cache_path },
    };

    platform.registerProbe(.{ .name = "state", .ctx = &app, .ext = "txt", .digest = stateDigest, .desc = "settings shell state" });
    platform.registerProbe(.{ .name = "layout", .ctx = &app, .ext = "txt", .digest = layoutDigest, .desc = "settings shell layout rects" });

    var running = true;
    main_loop: while (running and window.pollEvents()) {
        const fb = window.lockFramebuffer() orelse continue :main_loop;
        defer fb.unlock();
        @memset(fb.pixels, 0xFF_18_1C_24);
        app.screen_w = fb.width;
        app.screen_h = fb.height;
        ctx.beginFrame(fb.width, fb.height);

        app.paste_text = null;
        while (window.nextEvent()) |ev| {
            if (ev == .key_down) {
                const pk = ev.key_down;
                if (pk.key == .V and pk.modifiers.cmd and !pk.modifiers.ctrl and !pk.modifiers.alt and !pk.is_repeat) {
                    app.paste_text = platform.getClipboardText(app.paste_buf[0..]);
                }
            }
            switch (ev) {
                .quit => running = false,
                .key_down => |k| switch (k.key) {
                    .ESCAPE, .Q => if (ctx.state.focused_id == 0 or k.key == .ESCAPE) {
                        running = false;
                    },
                    else => {},
                },
                else => {},
            }
            if (toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
        }

        renderFrame(&ctx, &app);
        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        gui.render(target, &ctx.draw_list, ctx.font, 1.0);
        window.present();
    }
}
