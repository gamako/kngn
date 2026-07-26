//! Saved window state and off-screen detection.

const std = @import("std");
const serde = @import("serde");

pub const format_version: u16 = 1;
pub const magic: u32 = @as(u32, 'A') | (@as(u32, 'S') << 8) | (@as(u32, 'H') << 16) | (@as(u32, '1') << 24);

pub const Point = struct { x: i32, y: i32 };
pub const Size = struct { width: u32, height: u32 };
pub const Rect = struct { x: i32, y: i32, width: u32, height: u32 };
pub const State = struct { position: ?Point, size: Size };
pub const LoadStatus = enum { loaded, defaulted };
pub const LoadResult = struct { state: State, status: LoadStatus };

pub fn default() State {
    return .{ .position = null, .size = .{ .width = 800, .height = 600 } };
}

pub fn load(io: std.Io, dir: std.Io.Dir, file_name: []const u8, fallback: State) !LoadResult {
    const bytes = dir.readFileAlloc(io, file_name, std.heap.page_allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .state = fallback, .status = .defaulted },
        else => return err,
    };
    defer std.heap.page_allocator.free(bytes);
    const container = serde.Container.parse(bytes, magic) catch return .{ .state = fallback, .status = .defaulted };
    if (container.schemaVersion() != format_version) return .{ .state = fallback, .status = .defaulted };
    var it = container.iterator();
    var found: ?State = null;
    while (it.next()) |chunk| {
        if (!std.mem.eql(u8, &chunk.tag, "WIND")) continue;
        if (parsePayload(chunk.payload)) |state| found = state else return .{ .state = fallback, .status = .defaulted };
    }
    return if (found) |state| .{ .state = state, .status = .loaded } else .{ .state = fallback, .status = .defaulted };
}

pub fn save(io: std.Io, dir: std.Io.Dir, file_name: []const u8, state: State) !void {
    var writer = try serde.Writer.init(std.heap.page_allocator, magic, format_version);
    defer writer.deinit();
    var payload: [17]u8 = undefined;
    payload[0] = if (state.position != null) 1 else 0;
    const position = state.position orelse Point{ .x = 0, .y = 0 };
    std.mem.writeInt(i32, payload[1..5], position.x, .little);
    std.mem.writeInt(i32, payload[5..9], position.y, .little);
    std.mem.writeInt(u32, payload[9..13], state.size.width, .little);
    std.mem.writeInt(u32, payload[13..17], state.size.height, .little);
    try writer.addChunk("WIND".*, &payload);
    const bytes = try writer.finish();
    defer std.heap.page_allocator.free(bytes);
    var atomic = try dir.createFileAtomic(io, file_name, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}

pub fn resolve(state: State, fallback: State, screen_bounds: ?Rect) State {
    if (state.size.width == 0 or state.size.height == 0) return fallback;
    const position = state.position orelse return state;
    const screen = screen_bounds orelse return state;
    const right = @as(i64, position.x) + @as(i64, state.size.width);
    const bottom = @as(i64, position.y) + @as(i64, state.size.height);
    const screen_right = @as(i64, screen.x) + @as(i64, screen.width);
    const screen_bottom = @as(i64, screen.y) + @as(i64, screen.height);
    if (right <= screen.x or position.x >= screen_right or bottom <= screen.y or position.y >= screen_bottom) return fallback;
    return state;
}

fn parsePayload(payload: []const u8) ?State {
    if (payload.len != 17 or (payload[0] != 0 and payload[0] != 1)) return null;
    const width = std.mem.readInt(u32, payload[9..13], .little);
    const height = std.mem.readInt(u32, payload[13..17], .little);
    if (width == 0 or height == 0) return null;
    return .{
        .position = if (payload[0] == 1) .{
            .x = std.mem.readInt(i32, payload[1..5], .little),
            .y = std.mem.readInt(i32, payload[5..9], .little),
        } else null,
        .size = .{ .width = width, .height = height },
    };
}

test "window state round-trip and resolve" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state: State = .{ .position = .{ .x = 40, .y = 50 }, .size = .{ .width = 720, .height = 480 } };
    try save(std.testing.io, tmp.dir, "window_state.ash", state);
    const loaded = try load(std.testing.io, tmp.dir, "window_state.ash", default());
    try std.testing.expectEqual(LoadStatus.loaded, loaded.status);
    try std.testing.expectEqualDeep(state, loaded.state);
    try std.testing.expectEqualDeep(state, resolve(state, default(), .{ .x = 0, .y = 0, .width = 1920, .height = 1080 }));
    try std.testing.expectEqualDeep(default(), resolve(state, default(), .{ .x = 0, .y = 0, .width = 20, .height = 20 }));
}
