const std = @import("std");
const kit = @import("kit");

const platform = kit.platform;
const appshell = kit.appshell;

const PREF_BACKGROUND = "background";
const PREF_DEFAULT_BACKGROUND: i64 = 0x224466;

const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: std.Io.Dir,
    prefs: *appshell.preferences.Preferences,
    window_state: appshell.window_state.State,
    recent: *appshell.recent_files.RecentFiles,
    background: u32,
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    try platform.init();
    defer platform.shutdown();

    const override_path = if (std.c.getenv("VP_APPSHELL_DIR")) |value| std.mem.span(value) else null;
    var data_dir = try appshell.paths.openAppDataDir(io, allocator, "video-proto-example-26", override_path);
    defer data_dir.close(io);

    var prefs = appshell.preferences.Preferences.init(allocator);
    defer prefs.deinit();
    _ = try prefs.load(io, data_dir, "preferences.ash");
    const background = backgroundFromPrefs(&prefs);

    const fallback = appshell.window_state.default();
    const loaded_window = try appshell.window_state.load(io, data_dir, "window_state.ash", fallback);
    var recent = appshell.recent_files.RecentFiles.init(allocator, 10);
    defer recent.deinit();
    _ = try recent.load(io, data_dir, "recent_files.ash");

    var app = App{
        .allocator = allocator,
        .io = io,
        .data_dir = data_dir,
        .prefs = &prefs,
        .window_state = loaded_window.state,
        .recent = &recent,
        .background = background,
    };
    registerHarness(&app);

    var window = platform.Window.create(
        app.window_state.size.width,
        app.window_state.size.height,
        "26: AppShell Demo",
    ) catch |err| {
        std.debug.print("appshell demo: window creation failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer window.destroy();

    main_loop: while (window.pollEvents()) {
        while (window.nextEvent()) |event| switch (event) {
            .quit => break :main_loop,
            .key_down => |key| if (key.key == .ESCAPE or key.key == .Q) break :main_loop,
            else => {},
        };
        if (window.lockFramebuffer()) |fb| {
            defer fb.unlock();
            @memset(fb.pixels, 0xFF000000 | app.background);
            window.present();
        }
        platform.frameDelay(16_666_666);
    }

    try saveAll(&app);
}

fn backgroundFromPrefs(prefs: *const appshell.preferences.Preferences) u32 {
    const value = prefs.getI64(PREF_BACKGROUND) orelse PREF_DEFAULT_BACKGROUND;
    if (value < 0 or value > 0xFF_FFFF) return @intCast(PREF_DEFAULT_BACKGROUND);
    return @intCast(value);
}

fn saveAll(app: *App) !void {
    try app.prefs.setI64(PREF_BACKGROUND, app.background);
    try app.prefs.save(app.io, app.data_dir, "preferences.ash");
    try appshell.window_state.save(app.io, app.data_dir, "window_state.ash", app.window_state);
    try app.recent.save(app.io, app.data_dir, "recent_files.ash");
}

fn registerHarness(app: *App) void {
    platform.registerProbe(.{
        .name = "appshell",
        .ctx = app,
        .ext = "txt",
        .desc = "appshell persisted state",
        .digest = digest,
    });
    platform.registerAction(.{
        .name = "set_background",
        .ctx = app,
        .args = &.{.{ .name = "rgb", .kind = "string" }},
        .network_policy = .local_only,
        .run = setBackground,
    });
    platform.registerAction(.{
        .name = "set_window_state",
        .ctx = app,
        .args = &.{
            .{ .name = "x", .kind = "int" },
            .{ .name = "y", .kind = "int" },
            .{ .name = "width", .kind = "int" },
            .{ .name = "height", .kind = "int" },
        },
        .network_policy = .local_only,
        .run = setWindowState,
    });
    platform.registerAction(.{
        .name = "open",
        .ctx = app,
        .args = &.{.{ .name = "path", .kind = "path" }},
        .network_policy = .local_only,
        .run = openPath,
    });
}

fn digest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const point = app.window_state.position orelse appshell.window_state.Point{ .x = 0, .y = 0 };
    const path0 = if (app.recent.items().len > 0) app.recent.items()[0] else "";
    return std.fmt.bufPrint(buf, "size={d}x{d} pos={d},{d} bg=#{X:0>6} recent={d} path0={s}", .{
        app.window_state.size.width,
        app.window_state.size.height,
        point.x,
        point.y,
        app.background,
        app.recent.items().len,
        path0,
    }) catch buf[0..0];
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

fn openPath(ctx: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (args.len == 0) return error.InvalidArgument;
    try app.recent.push(args);
    return std.fmt.bufPrint(buf, "ok open", .{}) catch error.BufferTooSmall;
}
