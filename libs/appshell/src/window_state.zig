//! Saved window state and off-screen detection.
//!
//! Geometry is stored in a 17-byte `WIND` chunk. The coordinate space of
//! `State.position` is declared in a 1-byte `WSPC` chunk. Both chunks are
//! written on every save.

const std = @import("std");
const builtin = @import("builtin");
const serde = @import("serde");

pub const format_version: u16 = 1;
pub const magic: u32 = @as(u32, 'A') | (@as(u32, 'S') << 8) | (@as(u32, 'H') << 16) | (@as(u32, '1') << 24);

const wind_tag = "WIND".*;
const wspc_tag = "WSPC".*;
const wind_payload_len: usize = 17;
const wspc_payload_len: usize = 1;

pub const Point = struct { x: i32, y: i32 };
pub const Size = struct { width: u32, height: u32 };
pub const Rect = struct { x: i32, y: i32, width: u32, height: u32 };
pub const State = struct { position: ?Point, size: Size };

/// Coordinate space of `State.position` on the wire. IDs are format values;
/// an existing ID keeps its meaning. A new ID is added when a platform's
/// position contract changes.
pub const PositionSpace = enum(u8) {
    macos_screen_points_v1 = 1,
    linux_screen_coordinates_v1 = 2,
    windows_pmv2_physical_pixels_v1 = 3,
};

/// Outcome of reading a window-state file.
/// Position and size are decided independently: size is a logical content
/// size and does not depend on the declared position space.
pub const LoadStatus = enum {
    /// A valid `WIND` and `WSPC` are present, and the declared space matches `expected_space`.
    loaded,
    /// A valid `WIND` is present, but no `WSPC` declares the position space.
    position_space_undeclared,
    /// A valid `WIND` and `WSPC` are present, but the declared space does not match `expected_space`.
    position_space_mismatch,
    /// The file is missing, invalid, or otherwise unusable; `fallback` is returned.
    defaulted,
};

pub const LoadResult = struct { state: State, status: LoadStatus };

pub fn default() State {
    return .{ .position = null, .size = .{ .width = 800, .height = 600 } };
}

/// The coordinate space this build's platform reports window positions in.
/// Unused on targets that do not persist window state (no directory-capable filesystem).
pub fn currentSpace() PositionSpace {
    return comptime switch (builtin.os.tag) {
        .windows => .windows_pmv2_physical_pixels_v1,
        .macos => .macos_screen_points_v1,
        .linux => .linux_screen_coordinates_v1,
        else => .linux_screen_coordinates_v1,
    };
}

/// Read a window-state file and compare its declared position space to `expected_space`.
/// Callers pass `currentSpace()`; they do not branch on OS themselves.
pub fn load(
    io: std.Io,
    dir: std.Io.Dir,
    file_name: []const u8,
    fallback: State,
    expected_space: PositionSpace,
) !LoadResult {
    const bytes = dir.readFileAlloc(io, file_name, std.heap.page_allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return defaultedResult(fallback),
        else => return err,
    };
    defer std.heap.page_allocator.free(bytes);
    const container = serde.Container.parse(bytes, magic) catch return defaultedResult(fallback);
    if (container.schemaVersion() != format_version) return defaultedResult(fallback);

    var found_wind: ?State = null;
    var found_space: ?PositionSpace = null;
    var wind_count: usize = 0;
    var space_count: usize = 0;
    var it = container.iterator();
    while (it.next()) |chunk| {
        if (std.mem.eql(u8, &chunk.tag, &wind_tag)) {
            wind_count += 1;
            found_wind = parsePayload(chunk.payload) orelse return defaultedResult(fallback);
        } else if (std.mem.eql(u8, &chunk.tag, &wspc_tag)) {
            space_count += 1;
            found_space = parseSpace(chunk.payload) orelse return defaultedResult(fallback);
        }
    }

    if (wind_count != 1 or space_count > 1) return defaultedResult(fallback);
    const state = found_wind.?;

    if (found_space) |space| {
        if (space != expected_space) {
            return .{
                .state = .{ .position = null, .size = state.size },
                .status = .position_space_mismatch,
            };
        }
        return .{ .state = state, .status = .loaded };
    }

    const position = if (expected_space == .windows_pmv2_physical_pixels_v1) null else state.position;
    return .{
        .state = .{ .position = position, .size = state.size },
        .status = .position_space_undeclared,
    };
}

/// Write `WIND` (17-byte geometry) and `WSPC` (1-byte position space).
/// Both chunks are written on every save, including when `state.position` is null.
pub fn save(
    io: std.Io,
    dir: std.Io.Dir,
    file_name: []const u8,
    state: State,
    space: PositionSpace,
) !void {
    var writer = try serde.Writer.init(std.heap.page_allocator, magic, format_version);
    defer writer.deinit();
    const wind_payload = encodeWindPayload(state);
    const wspc_payload = encodeWspcPayload(space);
    try writer.addChunk(wind_tag, &wind_payload);
    try writer.addChunk(wspc_tag, &wspc_payload);
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

fn defaultedResult(fallback: State) LoadResult {
    return .{ .state = fallback, .status = .defaulted };
}

fn encodeWindPayload(state: State) [wind_payload_len]u8 {
    var payload: [wind_payload_len]u8 = undefined;
    payload[0] = if (state.position != null) 1 else 0;
    const position = state.position orelse Point{ .x = 0, .y = 0 };
    std.mem.writeInt(i32, payload[1..5], position.x, .little);
    std.mem.writeInt(i32, payload[5..9], position.y, .little);
    std.mem.writeInt(u32, payload[9..13], state.size.width, .little);
    std.mem.writeInt(u32, payload[13..17], state.size.height, .little);
    return payload;
}

fn encodeWspcPayload(space: PositionSpace) [wspc_payload_len]u8 {
    return .{@intFromEnum(space)};
}

fn parsePayload(payload: []const u8) ?State {
    if (payload.len != wind_payload_len or (payload[0] != 0 and payload[0] != 1)) return null;
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

fn parseSpace(payload: []const u8) ?PositionSpace {
    if (payload.len != wspc_payload_len) return null;
    return std.enums.fromInt(PositionSpace, payload[0]);
}

const ChunkSpec = struct { tag: [4]u8, payload: []const u8 };

fn writeChunks(io: std.Io, dir: std.Io.Dir, file_name: []const u8, chunks: []const ChunkSpec) !void {
    var writer = try serde.Writer.init(std.heap.page_allocator, magic, format_version);
    defer writer.deinit();
    for (chunks) |chunk| try writer.addChunk(chunk.tag, chunk.payload);
    const bytes = try writer.finish();
    defer std.heap.page_allocator.free(bytes);
    try dir.writeFile(io, .{ .sub_path = file_name, .data = bytes });
}

test "window state round-trip and resolve" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state: State = .{ .position = .{ .x = 40, .y = 50 }, .size = .{ .width = 720, .height = 480 } };
    const space = PositionSpace.macos_screen_points_v1;
    try save(std.testing.io, tmp.dir, "window_state.ash", state, space);
    const loaded = try load(std.testing.io, tmp.dir, "window_state.ash", default(), space);
    try std.testing.expectEqual(LoadStatus.loaded, loaded.status);
    try std.testing.expectEqualDeep(state, loaded.state);
    try std.testing.expectEqualDeep(state, resolve(state, default(), .{ .x = 0, .y = 0, .width = 1920, .height = 1080 }));
    try std.testing.expectEqualDeep(default(), resolve(state, default(), .{ .x = 0, .y = 0, .width = 20, .height = 20 }));
}

test "save writes strict WIND and WSPC chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state: State = .{ .position = .{ .x = 40, .y = 50 }, .size = .{ .width = 720, .height = 480 } };
    const space = PositionSpace.linux_screen_coordinates_v1;
    try save(std.testing.io, tmp.dir, "window_state.ash", state, space);

    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "window_state.ash", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    const container = try serde.Container.parse(bytes, magic);
    try std.testing.expectEqual(format_version, container.schemaVersion());

    var it = container.iterator();
    const wind = it.next().?;
    try std.testing.expectEqualSlices(u8, &wind_tag, &wind.tag);
    try std.testing.expectEqual(wind_payload_len, wind.payload.len);
    try std.testing.expectEqualSlices(u8, &encodeWindPayload(state), wind.payload);

    const wspc = it.next().?;
    try std.testing.expectEqualSlices(u8, &wspc_tag, &wspc.tag);
    try std.testing.expectEqual(wspc_payload_len, wspc.payload.len);
    try std.testing.expectEqual(@intFromEnum(space), wspc.payload[0]);
    try std.testing.expect(it.next() == null);

    const untitled: State = .{ .position = null, .size = .{ .width = 800, .height = 600 } };
    try save(std.testing.io, tmp.dir, "untitled.ash", untitled, space);
    const untitled_bytes = try tmp.dir.readFileAlloc(std.testing.io, "untitled.ash", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(untitled_bytes);
    const untitled_container = try serde.Container.parse(untitled_bytes, magic);
    var untitled_it = untitled_container.iterator();
    try std.testing.expectEqualSlices(u8, &wind_tag, &untitled_it.next().?.tag);
    const untitled_wspc = untitled_it.next().?;
    try std.testing.expectEqualSlices(u8, &wspc_tag, &untitled_wspc.tag);
    try std.testing.expectEqual(wspc_payload_len, untitled_wspc.payload.len);
    try std.testing.expect(untitled_it.next() == null);
}

test "load accepts WSPC after WIND" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state: State = .{ .position = .{ .x = 12, .y = 34 }, .size = .{ .width = 640, .height = 480 } };
    const space = PositionSpace.macos_screen_points_v1;
    const wind = encodeWindPayload(state);
    const wspc = encodeWspcPayload(space);
    try writeChunks(std.testing.io, tmp.dir, "window_state.ash", &.{
        .{ .tag = wind_tag, .payload = &wind },
        .{ .tag = wspc_tag, .payload = &wspc },
    });
    const loaded = try load(std.testing.io, tmp.dir, "window_state.ash", default(), space);
    try std.testing.expectEqual(LoadStatus.loaded, loaded.status);
    try std.testing.expectEqualDeep(state, loaded.state);
}

test "load accepts WSPC before WIND" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state: State = .{ .position = .{ .x = 12, .y = 34 }, .size = .{ .width = 640, .height = 480 } };
    const space = PositionSpace.macos_screen_points_v1;
    const wind = encodeWindPayload(state);
    const wspc = encodeWspcPayload(space);
    try writeChunks(std.testing.io, tmp.dir, "window_state.ash", &.{
        .{ .tag = wspc_tag, .payload = &wspc },
        .{ .tag = wind_tag, .payload = &wind },
    });
    const loaded = try load(std.testing.io, tmp.dir, "window_state.ash", default(), space);
    try std.testing.expectEqual(LoadStatus.loaded, loaded.status);
    try std.testing.expectEqualDeep(state, loaded.state);
}

test "load drops a Windows position whose space was never declared" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state: State = .{ .position = .{ .x = 100, .y = 200 }, .size = .{ .width = 1280, .height = 720 } };
    const wind = encodeWindPayload(state);
    try writeChunks(std.testing.io, tmp.dir, "window_state.ash", &.{
        .{ .tag = wind_tag, .payload = &wind },
    });
    const loaded = try load(std.testing.io, tmp.dir, "window_state.ash", default(), .windows_pmv2_physical_pixels_v1);
    try std.testing.expectEqual(LoadStatus.position_space_undeclared, loaded.status);
    try std.testing.expectEqual(@as(?Point, null), loaded.state.position);
    try std.testing.expectEqualDeep(state.size, loaded.state.size);
}

test "load keeps a non-Windows position whose space was never declared" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state: State = .{ .position = .{ .x = 100, .y = 200 }, .size = .{ .width = 1280, .height = 720 } };
    const wind = encodeWindPayload(state);
    try writeChunks(std.testing.io, tmp.dir, "window_state.ash", &.{
        .{ .tag = wind_tag, .payload = &wind },
    });

    const macos_loaded = try load(std.testing.io, tmp.dir, "window_state.ash", default(), .macos_screen_points_v1);
    try std.testing.expectEqual(LoadStatus.position_space_undeclared, macos_loaded.status);
    try std.testing.expectEqualDeep(state, macos_loaded.state);

    const linux_loaded = try load(std.testing.io, tmp.dir, "window_state.ash", default(), .linux_screen_coordinates_v1);
    try std.testing.expectEqual(LoadStatus.position_space_undeclared, linux_loaded.status);
    try std.testing.expectEqualDeep(state, linux_loaded.state);
}

test "load drops a position declared in another space but keeps the size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state: State = .{ .position = .{ .x = 80, .y = 90 }, .size = .{ .width = 1024, .height = 768 } };
    try save(std.testing.io, tmp.dir, "window_state.ash", state, .macos_screen_points_v1);
    const loaded = try load(std.testing.io, tmp.dir, "window_state.ash", default(), .windows_pmv2_physical_pixels_v1);
    try std.testing.expectEqual(LoadStatus.position_space_mismatch, loaded.status);
    try std.testing.expectEqual(@as(?Point, null), loaded.state.position);
    try std.testing.expectEqualDeep(state.size, loaded.state.size);
}

test "load skips unknown chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state: State = .{ .position = .{ .x = 16, .y = 32 }, .size = .{ .width = 900, .height = 600 } };
    const space = PositionSpace.linux_screen_coordinates_v1;
    const wind = encodeWindPayload(state);
    const wspc = encodeWspcPayload(space);
    try writeChunks(std.testing.io, tmp.dir, "window_state.ash", &.{
        .{ .tag = "UNK1".*, .payload = "before" },
        .{ .tag = wind_tag, .payload = &wind },
        .{ .tag = "UNK2".*, .payload = "between" },
        .{ .tag = wspc_tag, .payload = &wspc },
        .{ .tag = "UNK3".*, .payload = "after" },
    });
    const loaded = try load(std.testing.io, tmp.dir, "window_state.ash", default(), space);
    try std.testing.expectEqual(LoadStatus.loaded, loaded.status);
    try std.testing.expectEqualDeep(state, loaded.state);
}

test "load rejects WSPC without WIND" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fallback: State = .{ .position = .{ .x = 9, .y = 9 }, .size = .{ .width = 111, .height = 222 } };
    const wspc = encodeWspcPayload(.macos_screen_points_v1);
    try writeChunks(std.testing.io, tmp.dir, "window_state.ash", &.{
        .{ .tag = wspc_tag, .payload = &wspc },
    });
    const loaded = try load(std.testing.io, tmp.dir, "window_state.ash", fallback, .macos_screen_points_v1);
    try std.testing.expectEqual(LoadStatus.defaulted, loaded.status);
    try std.testing.expectEqualDeep(fallback, loaded.state);
}

test "load rejects duplicate WSPC" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fallback: State = .{ .position = .{ .x = 9, .y = 9 }, .size = .{ .width = 111, .height = 222 } };
    const state: State = .{ .position = .{ .x = 1, .y = 2 }, .size = .{ .width = 320, .height = 240 } };
    const wind = encodeWindPayload(state);
    const wspc = encodeWspcPayload(.macos_screen_points_v1);
    try writeChunks(std.testing.io, tmp.dir, "window_state.ash", &.{
        .{ .tag = wind_tag, .payload = &wind },
        .{ .tag = wspc_tag, .payload = &wspc },
        .{ .tag = wspc_tag, .payload = &wspc },
    });
    const loaded = try load(std.testing.io, tmp.dir, "window_state.ash", fallback, .macos_screen_points_v1);
    try std.testing.expectEqual(LoadStatus.defaulted, loaded.status);
    try std.testing.expectEqualDeep(fallback, loaded.state);
}

test "load rejects duplicate WIND" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fallback: State = .{ .position = .{ .x = 9, .y = 9 }, .size = .{ .width = 111, .height = 222 } };
    const state: State = .{ .position = .{ .x = 1, .y = 2 }, .size = .{ .width = 320, .height = 240 } };
    const wind = encodeWindPayload(state);
    const wspc = encodeWspcPayload(.macos_screen_points_v1);
    try writeChunks(std.testing.io, tmp.dir, "window_state.ash", &.{
        .{ .tag = wind_tag, .payload = &wind },
        .{ .tag = wind_tag, .payload = &wind },
        .{ .tag = wspc_tag, .payload = &wspc },
    });
    const loaded = try load(std.testing.io, tmp.dir, "window_state.ash", fallback, .macos_screen_points_v1);
    try std.testing.expectEqual(LoadStatus.defaulted, loaded.status);
    try std.testing.expectEqualDeep(fallback, loaded.state);
}

test "load rejects unknown WSPC value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fallback: State = .{ .position = .{ .x = 9, .y = 9 }, .size = .{ .width = 111, .height = 222 } };
    const state: State = .{ .position = .{ .x = 1, .y = 2 }, .size = .{ .width = 320, .height = 240 } };
    const wind = encodeWindPayload(state);
    try writeChunks(std.testing.io, tmp.dir, "window_state.ash", &.{
        .{ .tag = wind_tag, .payload = &wind },
        .{ .tag = wspc_tag, .payload = &.{99} },
    });
    const loaded = try load(std.testing.io, tmp.dir, "window_state.ash", fallback, .macos_screen_points_v1);
    try std.testing.expectEqual(LoadStatus.defaulted, loaded.status);
    try std.testing.expectEqualDeep(fallback, loaded.state);
}

test "load rejects malformed WSPC payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fallback: State = .{ .position = .{ .x = 9, .y = 9 }, .size = .{ .width = 111, .height = 222 } };
    const state: State = .{ .position = .{ .x = 1, .y = 2 }, .size = .{ .width = 320, .height = 240 } };
    const wind = encodeWindPayload(state);

    try writeChunks(std.testing.io, tmp.dir, "empty.ash", &.{
        .{ .tag = wind_tag, .payload = &wind },
        .{ .tag = wspc_tag, .payload = &.{} },
    });
    const empty = try load(std.testing.io, tmp.dir, "empty.ash", fallback, .macos_screen_points_v1);
    try std.testing.expectEqual(LoadStatus.defaulted, empty.status);
    try std.testing.expectEqualDeep(fallback, empty.state);

    try writeChunks(std.testing.io, tmp.dir, "long.ash", &.{
        .{ .tag = wind_tag, .payload = &wind },
        .{ .tag = wspc_tag, .payload = &.{ 1, 2 } },
    });
    const long = try load(std.testing.io, tmp.dir, "long.ash", fallback, .macos_screen_points_v1);
    try std.testing.expectEqual(LoadStatus.defaulted, long.status);
    try std.testing.expectEqualDeep(fallback, long.state);
}

test "load rejects a valid-CRC invalid WIND payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fallback: State = .{ .position = .{ .x = 9, .y = 9 }, .size = .{ .width = 111, .height = 222 } };
    const state: State = .{ .position = .{ .x = 1, .y = 2 }, .size = .{ .width = 320, .height = 240 } };
    const wspc = encodeWspcPayload(.macos_screen_points_v1);

    var bad_flag = encodeWindPayload(state);
    bad_flag[0] = 2;
    try writeChunks(std.testing.io, tmp.dir, "flag.ash", &.{
        .{ .tag = wind_tag, .payload = &bad_flag },
        .{ .tag = wspc_tag, .payload = &wspc },
    });
    const flag = try load(std.testing.io, tmp.dir, "flag.ash", fallback, .macos_screen_points_v1);
    try std.testing.expectEqual(LoadStatus.defaulted, flag.status);
    try std.testing.expectEqualDeep(fallback, flag.state);

    var bad_size = encodeWindPayload(state);
    std.mem.writeInt(u32, bad_size[9..13], 0, .little);
    try writeChunks(std.testing.io, tmp.dir, "size.ash", &.{
        .{ .tag = wind_tag, .payload = &bad_size },
        .{ .tag = wspc_tag, .payload = &wspc },
    });
    const size = try load(std.testing.io, tmp.dir, "size.ash", fallback, .macos_screen_points_v1);
    try std.testing.expectEqual(LoadStatus.defaulted, size.status);
    try std.testing.expectEqualDeep(fallback, size.state);
}
