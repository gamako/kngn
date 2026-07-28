//! 26_appshell_demo — AppShell persistence + DocumentHost doodle sample.
//!
//! Hot path declaration: DocumentHost, paint edit/save/load, RecentFiles, quit cancel, and confirm UI are
//! event-only. The displayed canvas composite is a per-frame all-pixel path, but it reuses the existing
//! `paint.Canvas.composite` SIMD/cache path and the `gui` image renderer.

const std = @import("std");
const kit = @import("kit");
const gui = kit.gui;
const paint = @import("paint");

const platform = kit.platform;
const appshell = kit.appshell;

const FRAME_PERIOD_S: f64 = 1.0 / 60.0;

const PREF_BACKGROUND = "background";
const PREF_DEFAULT_BACKGROUND: i64 = 0x224466;
const DOODLE_WIDTH: u32 = 256;
const DOODLE_HEIGHT: u32 = 256;

const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: std.Io.Dir,
    prefs: *appshell.preferences.Preferences,
    window_state: appshell.window_state.State,
    recent: *appshell.recent_files.RecentFiles,
    background: u32,
    doc: paint.Document,
    host: appshell.document_host.DocumentHost,
    autosave: appshell.autosave.Controller,
    recovery: ?appshell.autosave.Candidate = null,
    window: ?*platform.Window = null,
    should_quit: bool = false,
    drawing: bool = false,
    last_point: paint.Vec2 = .{ .x = 0, .y = 0 },
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    try platform.init();
    defer platform.shutdown();

    const override_path = if (std.c.getenv("KNGN_APPSHELL_DIR")) |value| std.mem.span(value) else null;
    var data_dir = try appshell.paths.openAppDataDir(io, allocator, "kngn-example-26", override_path);
    defer data_dir.close(io);
    var autosave_dir = try appshell.paths.openAutosaveDir(io, data_dir);
    defer autosave_dir.close(io);

    var prefs = appshell.preferences.Preferences.init(allocator);
    defer prefs.deinit();
    _ = try prefs.load(io, data_dir, "preferences.ash");
    const background = backgroundFromPrefs(&prefs);

    const fallback = appshell.window_state.default();
    const loaded_window = try appshell.window_state.load(io, data_dir, "window_state.ash", fallback);
    var recent = appshell.recent_files.RecentFiles.init(allocator, 10);
    defer recent.deinit();
    _ = try recent.load(io, data_dir, "recent_files.ash");

    const doc = try paint.Document.init(allocator, DOODLE_WIDTH, DOODLE_HEIGHT);
    const autosave_controller = try appshell.autosave.Controller.init(allocator, io, autosave_dir, null);
    var app: App = .{
        .allocator = allocator,
        .io = io,
        .data_dir = data_dir,
        .prefs = &prefs,
        .window_state = loaded_window.state,
        .recent = &recent,
        .background = background,
        .doc = doc,
        .host = undefined,
        .autosave = autosave_controller,
        .recovery = try appshell.autosave.scan(allocator, io, autosave_dir),
    };
    app.host = .init(allocator, .{
        .ctx = &app,
        .newDocument = newDocument,
        .openDocument = openDocument,
        .saveDocument = saveDocument,
    });
    defer app.host.deinit();
    defer {
        if (app.recovery) |*candidate| candidate.deinit();
        app.autosave.deinit();
    }
    defer app.doc.deinit();

    registerHarness(&app);

    var window = platform.Window.create(
        app.window_state.size.width,
        app.window_state.size.height,
        "26: AppShell Doodle",
    ) catch |err| {
        std.debug.print("appshell demo: window creation failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer window.destroy();
    app.window = &window;

    var draw_list = gui.DrawList.init(allocator);
    defer draw_list.deinit();

    main_loop: while (!app.should_quit and window.pollEvents()) {
        const frame_t0 = platform.getTime();
        defer platform.framePaceUntil(frame_t0 + FRAME_PERIOD_S);

        while (window.nextEvent()) |event| {
            switch (event) {
                .quit => {
                    const result = try requestClose(&app);
                    if (result == .allowed) app.should_quit = true else window.cancelQuit();
                },
                .key_down => |key| {
                    if (key.key == .ESCAPE or key.key == .Q) {
                        const result = try requestClose(&app);
                        if (result == .allowed) app.should_quit = true else window.cancelQuit();
                    }
                },
                .mouse_down => |mouse| {
                    if (app.recovery != null or app.host.confirmation() != .none) {
                        try handleConfirmationClick(&app, mouse.x, mouse.y);
                    } else if (mouse.button == .left) {
                        app.drawing = true;
                        app.last_point = .{ .x = mouse.x, .y = mouse.y };
                        drawLine(&app, app.last_point, app.last_point);
                    }
                },
                .mouse_move => |mouse| if (app.drawing) {
                    const point: paint.Vec2 = .{ .x = mouse.x, .y = mouse.y };
                    drawLine(&app, app.last_point, point);
                    app.last_point = point;
                },
                .mouse_up => |mouse| {
                    if (mouse.button == .left) app.drawing = false;
                },
                else => {},
            }
        }

        _ = try app.autosave.tick(platform.getTime(), &app, snapshotDocument);

        const fb = window.lockFramebuffer() orelse continue :main_loop;
        defer fb.unlock();
        @memset(fb.pixels, 0xFF000000 | app.background);
        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        draw_list.reset(fb.width, fb.height);
        try draw_list.image(.{ .x = 24, .y = 24, .w = DOODLE_WIDTH, .h = DOODLE_HEIGHT }, app.doc.activeCanvas().composite(), DOODLE_WIDTH, DOODLE_HEIGHT);
        try draw_list.rectOutline(.{ .x = 23, .y = 23, .w = DOODLE_WIDTH + 2, .h = DOODLE_HEIGHT + 2 }, gui.Color.rgba(0x70, 0x78, 0x90, 0xFF), 1);
        var title_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
        try draw_list.text(.{ .x = 310, .y = 28 }, app.host.title(&title_buf), gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
        try draw_list.text(.{ .x = 310, .y = 52 }, "Draw with the mouse", gui.Color.rgba(0xB0, 0xB8, 0xC8, 0xFF));
        try draw_list.text(.{ .x = 310, .y = 72 }, "Q / ESC: request close", gui.Color.rgba(0xB0, 0xB8, 0xC8, 0xFF));
        try draw_list.text(.{ .x = 310, .y = 110 }, "Recent files", gui.Color.rgba(0xFF, 0xD0, 0x80, 0xFF));
        if (app.recent.items().len == 0) {
            try draw_list.text(.{ .x = 310, .y = 132 }, "(none)", gui.Color.rgba(0xA0, 0xA8, 0xB8, 0xFF));
        } else {
            for (app.recent.items(), 0..) |path, i| {
                if (i >= 5) break;
                try draw_list.text(.{ .x = 310, .y = 132 + @as(i32, @intCast(i * 18)) }, path, gui.Color.rgba(0xA0, 0xA8, 0xB8, 0xFF));
            }
        }
        if (app.recovery != null) {
            try drawRecovery(&draw_list);
        } else if (app.host.confirmation() != .none) {
            try drawConfirmation(&draw_list, &app);
        }
        gui.render(target, &draw_list, gui.default_font, 1.0);
        window.present();
    }

    try saveAll(&app);
}

fn backgroundFromPrefs(prefs: *const appshell.preferences.Preferences) u32 {
    const value = prefs.getI64(PREF_BACKGROUND) orelse PREF_DEFAULT_BACKGROUND;
    if (value < 0 or value > 0xFF_FFFF) return @intCast(PREF_DEFAULT_BACKGROUND);
    return @intCast(value);
}

fn saveAll(app: *App) !void {
    try app.autosave.clear();
    try app.prefs.setI64(PREF_BACKGROUND, app.background);
    try app.prefs.save(app.io, app.data_dir, "preferences.ash");
    try appshell.window_state.save(app.io, app.data_dir, "window_state.ash", app.window_state);
    try app.recent.save(app.io, app.data_dir, "recent_files.ash");
}

fn newDocument(ctx: *anyopaque) !void {
    const app: *App = @ptrCast(@alignCast(ctx));
    try app.autosave.clear();
    const next = try paint.Document.init(app.allocator, DOODLE_WIDTH, DOODLE_HEIGHT);
    app.doc.deinit();
    app.doc = next;
    try app.autosave.setPath(null);
}

fn openDocument(ctx: *anyopaque, path: []const u8) !void {
    const app: *App = @ptrCast(@alignCast(ctx));
    var next = try paint.document_io.loadDocument(app.io, app.allocator, path, 0, 0);
    errdefer next.deinit();
    try app.recent.push(path);
    try app.autosave.clear();
    app.doc.deinit();
    app.doc = next;
    try app.autosave.setPath(path);
}

fn saveDocument(ctx: *anyopaque, path: []const u8) !void {
    const app: *App = @ptrCast(@alignCast(ctx));
    syncDocumentForSave(app);
    const bytes = try paint.document_io.encodeDocument(&app.doc, app.allocator);
    defer app.allocator.free(bytes);
    try appshell.file_safety.writeAtomic(app.io, path, bytes, .{ .backup = true });
    try app.recent.push(path);
    try app.autosave.clear();
    try appshell.autosave.clearPath(app.io, app.autosave.dir, app.allocator, path);
    try app.autosave.setPath(path);
}

fn drawLine(app: *App, from: paint.Vec2, to: paint.Vec2) void {
    var x = from.x;
    var y = from.y;
    const dx: i32 = @intCast(@abs(to.x - from.x));
    const sx: i32 = if (from.x < to.x) 1 else -1;
    const dy: i32 = -@as(i32, @intCast(@abs(to.y - from.y)));
    const sy: i32 = if (from.y < to.y) 1 else -1;
    var err = dx + dy;
    while (true) {
        app.doc.activeCanvas().drawPixel(0, x, y, 0xFFFF8A30);
        if (x == to.x and y == to.y) break;
        const twice = 2 * err;
        if (twice >= dy) {
            err += dy;
            x += sx;
        }
        if (twice <= dx) {
            err += dx;
            y += sy;
        }
    }
    const now = platform.getTime();
    app.host.markDirty();
    app.autosave.markDirty(now);
}

fn drawStrokeAction(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var it = std.mem.tokenizeAny(u8, args, " \t");
    const x0 = try nextInt(&it, i32);
    const y0 = try nextInt(&it, i32);
    const x1 = try nextInt(&it, i32);
    const y1 = try nextInt(&it, i32);
    if (it.next() != null) return error.InvalidArgument;
    drawLine(app, .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y1 });
    return std.fmt.bufPrint(buf, "ok stroke", .{}) catch error.BufferTooSmall;
}

fn requestCloseAction(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (args.len != 0) return error.InvalidArgument;
    const result = try requestClose(app);
    if (result == .allowed) app.should_quit = true else if (result == .confirmation_required) if (app.window) |window| window.cancelQuit();
    return std.fmt.bufPrint(buf, "ok close={s}", .{@tagName(result)}) catch error.BufferTooSmall;
}

fn confirmSaveAction(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (args.len == 0) return error.InvalidArgument;
    const result = try app.host.confirmSave(args);
    return std.fmt.bufPrint(buf, "ok confirm_save={s}", .{@tagName(result)}) catch error.BufferTooSmall;
}

fn confirmDiscardAction(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (args.len != 0) return error.InvalidArgument;
    const result = try app.host.confirmDiscard();
    if (result == .allowed) try app.autosave.clear();
    return std.fmt.bufPrint(buf, "ok confirm_discard={s}", .{@tagName(result)}) catch error.BufferTooSmall;
}

fn confirmCancelAction(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (args.len != 0) return error.InvalidArgument;
    const result = app.host.confirmCancel();
    return std.fmt.bufPrint(buf, "ok confirm_cancel={s}", .{@tagName(result)}) catch error.BufferTooSmall;
}

fn openPath(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (args.len == 0) return error.InvalidArgument;
    const result = try app.host.open(args);
    return std.fmt.bufPrint(buf, "ok open={s}", .{@tagName(result)}) catch error.BufferTooSmall;
}

fn savePath(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (args.len != 0) return error.InvalidArgument;
    const result = try app.host.save();
    return std.fmt.bufPrint(buf, "ok save={s}", .{@tagName(result)}) catch error.BufferTooSmall;
}

fn saveAsPath(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (args.len == 0) return error.InvalidArgument;
    const result = try app.host.saveAs(args);
    return std.fmt.bufPrint(buf, "ok save_as={s}", .{@tagName(result)}) catch error.BufferTooSmall;
}

fn handleConfirmationClick(app: *App, x: i32, y: i32) !void {
    if (app.recovery != null) {
        if (x < 300 or x >= 570 or y < 470 or y >= 520) return;
        if (x < 435) {
            try recover(app);
        } else {
            try discardRecovery(app);
        }
        return;
    }
    if (x < 300 or x >= 700 or y < 470 or y >= 520) return;
    const result = if (x < 430) try app.host.confirmSave("doodle.pix") else if (x < 565) try app.host.confirmDiscard() else app.host.confirmCancel();
    if (result == .allowed) app.should_quit = true;
}

fn requestClose(app: *App) !appshell.document_host.Result {
    if (app.recovery != null) return .rejected;
    return app.host.requestClose();
}

fn snapshotDocument(ctx: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    syncDocumentForSave(app);
    return paint.document_io.encodeDocument(&app.doc, allocator);
}

fn syncDocumentForSave(app: *App) void {
    app.doc.commitActiveLayerToCel(app.allocator, app.doc.selected_layer);
}

fn recoverAction(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (args.len != 0) return error.InvalidArgument;
    try recover(app);
    return std.fmt.bufPrint(buf, "ok recover", .{}) catch error.BufferTooSmall;
}

fn discardRecoveryAction(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (args.len != 0) return error.InvalidArgument;
    try discardRecovery(app);
    return std.fmt.bufPrint(buf, "ok discard_recovery", .{}) catch error.BufferTooSmall;
}

fn recover(app: *App) !void {
    const candidate = &(app.recovery orelse return error.NoRecoveryPending);
    var decoded = try paint.document_io.decodeDocument(candidate.envelope.snapshot, app.allocator);
    errdefer decoded.deinit();
    try app.host.adoptRecovered(candidate.envelope.original_path);
    try appshell.autosave.discardCandidate(app.io, app.autosave.dir, candidate.file_name);
    app.doc.deinit();
    app.doc = decoded;
    decoded = undefined;
    candidate.deinit();
    app.recovery = null;
    try app.autosave.setPath(app.host.currentPath());
    app.autosave.markDirty(platform.getTime());
}

fn discardRecovery(app: *App) !void {
    const candidate = &(app.recovery orelse return error.NoRecoveryPending);
    try appshell.autosave.discardCandidate(app.io, app.autosave.dir, candidate.file_name);
    candidate.deinit();
    app.recovery = null;
}

fn drawRecovery(draw_list: *gui.DrawList) !void {
    try draw_list.rectFilled(.{ .x = 286, .y = 420, .w = 560, .h = 120 }, gui.Color.rgba(0x20, 0x24, 0x30, 0xF8));
    try draw_list.rectOutline(.{ .x = 286, .y = 420, .w = 560, .h = 120 }, gui.Color.rgba(0xFF, 0xD0, 0x80, 0xFF), 2);
    try draw_list.text(.{ .x = 310, .y = 438 }, "Recover autosaved changes?", gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
    try draw_list.rectFilled(.{ .x = 310, .y = 480, .w = 110, .h = 30 }, gui.Color.rgba(0x40, 0x80, 0xC0, 0xFF));
    try draw_list.rectFilled(.{ .x = 445, .y = 480, .w = 110, .h = 30 }, gui.Color.rgba(0x80, 0x60, 0x40, 0xFF));
    try draw_list.text(.{ .x = 330, .y = 489 }, "Recover", gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
    try draw_list.text(.{ .x = 462, .y = 489 }, "Discard", gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
}

fn drawConfirmation(draw_list: *gui.DrawList, app: *const App) !void {
    try draw_list.rectFilled(.{ .x = 286, .y = 420, .w = 560, .h = 120 }, gui.Color.rgba(0x20, 0x24, 0x30, 0xF8));
    try draw_list.rectOutline(.{ .x = 286, .y = 420, .w = 560, .h = 120 }, gui.Color.rgba(0xFF, 0xD0, 0x80, 0xFF), 2);
    try draw_list.text(.{ .x = 310, .y = 438 }, "Unsaved changes", gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
    try draw_list.text(.{ .x = 310, .y = 458 }, "Save before continuing?", gui.Color.rgba(0xC0, 0xC8, 0xD8, 0xFF));
    try draw_list.rectFilled(.{ .x = 310, .y = 480, .w = 110, .h = 30 }, gui.Color.rgba(0x40, 0x80, 0xC0, 0xFF));
    try draw_list.rectFilled(.{ .x = 445, .y = 480, .w = 110, .h = 30 }, gui.Color.rgba(0x80, 0x60, 0x40, 0xFF));
    try draw_list.rectFilled(.{ .x = 580, .y = 480, .w = 110, .h = 30 }, gui.Color.rgba(0x50, 0x58, 0x68, 0xFF));
    try draw_list.text(.{ .x = 330, .y = 489 }, "Save", gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
    try draw_list.text(.{ .x = 462, .y = 489 }, "Discard", gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
    try draw_list.text(.{ .x = 600, .y = 489 }, "Cancel", gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
    _ = app;
}

fn registerHarness(app: *App) void {
    platform.registerProbe(.{
        .name = "appshell",
        .ctx = app,
        .ext = "txt",
        .desc = "appshell persisted state",
        .digest = digest,
    });
    platform.registerProbe(.{
        .name = "doodle",
        .ctx = app,
        .ext = "txt",
        .desc = "DocumentHost doodle lifecycle",
        .digest = doodleDigest,
    });
    platform.registerAction(.{ .name = "set_background", .ctx = app, .args = &.{.{ .name = "rgb", .kind = "string" }}, .network_policy = .local_only, .run = setBackground });
    platform.registerAction(.{ .name = "set_window_state", .ctx = app, .args = &.{ .{ .name = "x", .kind = "int" }, .{ .name = "y", .kind = "int" }, .{ .name = "width", .kind = "int" }, .{ .name = "height", .kind = "int" } }, .network_policy = .local_only, .run = setWindowState });
    platform.registerAction(.{ .name = "draw_stroke", .ctx = app, .args = &.{ .{ .name = "x0", .kind = "int" }, .{ .name = "y0", .kind = "int" }, .{ .name = "x1", .kind = "int" }, .{ .name = "y1", .kind = "int" } }, .network_policy = .local_only, .run = drawStrokeAction });
    platform.registerAction(.{ .name = "request_close", .ctx = app, .network_policy = .local_only, .run = requestCloseAction });
    platform.registerAction(.{ .name = "confirm_save", .ctx = app, .args = &.{.{ .name = "path", .kind = "path" }}, .network_policy = .local_only, .run = confirmSaveAction });
    platform.registerAction(.{ .name = "confirm_discard", .ctx = app, .network_policy = .local_only, .run = confirmDiscardAction });
    platform.registerAction(.{ .name = "confirm_cancel", .ctx = app, .network_policy = .local_only, .run = confirmCancelAction });
    platform.registerAction(.{ .name = "open", .ctx = app, .args = &.{.{ .name = "path", .kind = "path" }}, .network_policy = .local_only, .run = openPath });
    platform.registerAction(.{ .name = "save", .ctx = app, .network_policy = .local_only, .run = savePath });
    platform.registerAction(.{ .name = "save_as", .ctx = app, .args = &.{.{ .name = "path", .kind = "path" }}, .network_policy = .local_only, .run = saveAsPath });
    platform.registerAction(.{ .name = "recover", .ctx = app, .network_policy = .local_only, .run = recoverAction });
    platform.registerAction(.{ .name = "discard_recovery", .ctx = app, .network_policy = .local_only, .run = discardRecoveryAction });
}

fn digest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const point = app.window_state.position orelse appshell.window_state.Point{ .x = 0, .y = 0 };
    const path0 = if (app.recent.items().len > 0) app.recent.items()[0] else "";
    return std.fmt.bufPrint(buf, "size={d}x{d} pos={d},{d} bg=#{X:0>6} recent={d} path0={s} doodle_dirty={d} doodle_named={d}", .{
        app.window_state.size.width,
        app.window_state.size.height,
        point.x,
        point.y,
        app.background,
        app.recent.items().len,
        path0,
        @intFromBool(app.host.isDirty()),
        @intFromBool(app.host.nameState() == .named),
    }) catch buf[0..0];
}

fn doodleDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var title_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const title = app.host.title(&title_buf);
    const canvas = app.doc.activeCanvas().compositeStraight();
    const canvas_crc = std.hash.Crc32.hash(std.mem.sliceAsBytes(canvas));
    const autosave_present = app.recovery != null or activeAutosavePresent(app);
    return std.fmt.bufPrint(buf, "dirty={d} named={d} confirm={s} recent={d} edited={d} title={s} recovery={s} autosave={d} canvas_crc={X:0>8}", .{
        @intFromBool(app.host.isDirty()),
        @intFromBool(app.host.nameState() == .named),
        @tagName(app.host.confirmation()),
        app.recent.items().len,
        @intFromBool(app.host.isDirty()),
        title,
        if (app.recovery != null) "pending" else "none",
        @intFromBool(autosave_present),
        canvas_crc,
    }) catch buf[0..0];
}

fn activeAutosavePresent(app: *const App) bool {
    const name = appshell.paths.autosaveFileName(app.io, app.autosave.allocator, app.autosave.current_path) catch return false;
    defer app.autosave.allocator.free(name);
    app.autosave.dir.access(app.io, name, .{}) catch return false;
    return true;
}

fn setBackground(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const value = std.fmt.parseInt(u32, args, 16) catch return error.InvalidArgument;
    if (value > 0xFF_FFFF or args.len != 6) return error.InvalidArgument;
    app.background = value;
    return std.fmt.bufPrint(buf, "ok background=#{X:0>6}", .{value}) catch error.BufferTooSmall;
}

fn setWindowState(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var it = std.mem.tokenizeAny(u8, args, " \t");
    const x = try nextInt(&it, i32);
    const y = try nextInt(&it, i32);
    const width = try nextInt(&it, u32);
    const height = try nextInt(&it, u32);
    if (it.next() != null or width == 0 or height == 0) return error.InvalidArgument;
    app.window_state = .{ .position = .{ .x = x, .y = y }, .size = .{ .width = width, .height = height } };
    return std.fmt.bufPrint(buf, "ok window_state", .{}) catch error.BufferTooSmall;
}

fn nextInt(it: anytype, comptime T: type) !T {
    return std.fmt.parseInt(T, it.next() orelse return error.InvalidArgument, 10) catch error.InvalidArgument;
}
