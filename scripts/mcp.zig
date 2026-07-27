//! vp-mcp: harness listen TCP ↔ stdio MCP server.
//!
//! Attach to a running app (`VP_HARNESS_LISTEN`) and build MCP tools dynamically from capabilities.
//! Pure std + `std.Io.net` only (no platform/audio dependency, no module import).
//!
//! Usage:
//!   vp-mcp --port-file /tmp/vp.port
//!   vp-mcp --port 54321 --out /tmp/vp-mcp-out
//!
//! MCP protocol is a minimal stdio JSON-RPC subset (initialize / notifications/initialized /
//! tools/list / tools/call / ping). See docs/harness.md.

const std = @import("std");
const net = std.Io.net;
const json = std.json;
const testing = std.testing;

const PROTOCOL_VERSION = "2025-06-18";
const SERVER_NAME = "vp-mcp";
const SERVER_VERSION = "0.1.0";
const MESSAGE_MAX = 64 * 1024;
// CONNECT_TIMEOUT_S=2 is the intended connect budget. Zig 0.16 Threaded netConnectIpPosix
// panics on timeout≠.none (TODO), so it is unused (same `.none` as drive). Apply it once std supports it.
const RESPONSE_TIMEOUT_S: i64 = 30;
const RESPONSE_LIMIT = 1 << 20;

// ---------------------------------------------------------------------------
// CLI / process entry
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer it.deinit();
    _ = it.next();

    var port_opt: ?u16 = null;
    var port_file: ?[]const u8 = null;
    var out_opt: ?[]const u8 = null;

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const v = it.next() orelse return die("--port requires a value\n");
            port_opt = std.fmt.parseInt(u16, v, 10) catch return die("--port value is invalid\n");
        } else if (std.mem.eql(u8, arg, "--port-file")) {
            port_file = it.next() orelse return die("--port-file requires a value\n");
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_opt = it.next() orelse return die("--out requires a value\n");
        } else {
            return die2("unknown argument: {s}\n", .{arg});
        }
    }

    const port: u16 = port_opt orelse blk: {
        if (port_file) |pf| break :blk try readPortFile(io, gpa, pf);
        if (init.environ_map.get("VP_HARNESS_LISTEN")) |pe| {
            const trimmed = std.mem.trim(u8, pe, " \t");
            if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "0")) {
                break :blk std.fmt.parseInt(u16, trimmed, 10) catch return die("VP_HARNESS_LISTEN value is invalid\n");
            }
        }
        if (init.environ_map.get("VP_HARNESS_PORT_FILE")) |pf| break :blk try readPortFile(io, gpa, pf);
        return die("port is unknown (set one of --port / --port-file / VP_HARNESS_LISTEN / VP_HARNESS_PORT_FILE)\n");
    };

    const out_arg = out_opt orelse blk: {
        const tmp = init.environ_map.get("TMPDIR") orelse "/tmp";
        break :blk try std.fmt.allocPrint(gpa, "{s}/vp-mcp-{d}", .{ tmp, port });
    };
    try validateOutArg(out_arg);
    const out_abs = try absolutizeOutDir(io, gpa, out_arg);

    const caps_resp = sendRequest(io, gpa, port, "digest capabilities") catch |err| {
        return die2("startup digest capabilities failed: {s}\n", .{@errorName(err)});
    };
    const caps_json = try extractCapabilitiesJson(caps_resp) orelse {
        return die("digest capabilities response format is invalid\n");
    };

    const caps_val = json.parseFromSliceLeaky(json.Value, gpa, caps_json, .{}) catch {
        return die("failed to parse capabilities JSON\n");
    };
    if (caps_val != .object) return die("capabilities JSON is not an object\n");
    if (caps_val.object.get("truncated")) |t| {
        if (t == .bool and t.bool) {
            return die("capabilities has truncated=true (cannot emit an incomplete tool list). Reduce app-side registrations or revisit the buffer\n");
        }
    }

    const tools = try buildToolTable(gpa, caps_val.object);

    var session: Session = .{
        .io = io,
        .gpa = gpa,
        .port = port,
        .out_abs = out_abs,
        .tools = tools.items,
        .snapshot_seq = 0,
        .phase = .need_initialize,
    };

    try runStdioLoop(&session);
}

fn readPortFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !u16 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, std.Io.Limit.limited(64)) catch |err| {
        return die2("failed to read port file {s}: {s}\n", .{ path, @errorName(err) });
    };
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    return std.fmt.parseInt(u16, trimmed, 10) catch return die("port file contents are invalid\n");
}

fn absolutizeOutDir(io: std.Io, gpa: std.mem.Allocator, out_arg: []const u8) ![]const u8 {
    std.Io.Dir.cwd().createDirPath(io, out_arg) catch |err| {
        return die2("failed to create --out directory {s}: {s}\n", .{ out_arg, @errorName(err) });
    };
    var dir = std.Io.Dir.cwd().openDir(io, out_arg, .{}) catch |err| {
        return die2("cannot open --out directory {s}: {s}\n", .{ out_arg, @errorName(err) });
    };
    defer dir.close(io);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = dir.realPath(io, &buf) catch |err| {
        return die2("failed to resolve absolute --out path: {s}\n", .{@errorName(err)});
    };
    return try gpa.dupe(u8, buf[0..n]);
}

/// harness wire splits on whitespace tokens, so --out must not contain spaces.
fn validateOutArg(out_arg: []const u8) error{McpFailed}!void {
    if (std.mem.indexOfAny(u8, out_arg, " \t") != null) {
        return die("--out path must not contain whitespace (harness wire splits on spaces)\n");
    }
}

fn die(msg: []const u8) error{McpFailed} {
    std.debug.print("vp-mcp: {s}", .{msg});
    return error.McpFailed;
}

fn die2(comptime fmt: []const u8, args: anytype) error{McpFailed} {
    std.debug.print("vp-mcp: " ++ fmt, args);
    return error.McpFailed;
}

fn warn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("vp-mcp: " ++ fmt, args);
}

// ---------------------------------------------------------------------------
// TCP (same shape as drive, plus timeout)
// ---------------------------------------------------------------------------

const SendError = error{
    ConnectFailed,
    WriteFailed,
    ReadFailed,
    ResponseTimeout,
    ResponseTooLarge,
    OutOfMemory,
};

fn sendRequest(io: std.Io, gpa: std.mem.Allocator, port: u16, cmd: []const u8) SendError![]u8 {
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    // Zig 0.16 Threaded: netConnectIpPosix panics on timeout≠.none (TODO). Same `.none` as drive.
    // The receive side applies RESPONSE_TIMEOUT_S via receiveTimeout.
    var stream = addr.connect(io, .{ .mode = .stream }) catch {
        return error.ConnectFailed;
    };
    defer stream.close(io);

    {
        var wbuf: [4096]u8 = undefined;
        var writer = stream.writer(io, &wbuf);
        writer.interface.writeAll(cmd) catch return error.WriteFailed;
        writer.interface.flush() catch return error.WriteFailed;
    }
    stream.shutdown(io, .send) catch {};

    const deadline: std.Io.Timeout = .{ .deadline = .fromNow(io, .{
        .raw = .fromSeconds(RESPONSE_TIMEOUT_S),
        .clock = .awake,
    }) };
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var rbuf: [4096]u8 = undefined;
    while (list.items.len < RESPONSE_LIMIT) {
        const message = stream.socket.receiveTimeout(io, &rbuf, deadline) catch |err| switch (err) {
            error.Timeout => return error.ResponseTimeout,
            error.ConnectionResetByPeer, error.SocketUnconnected => break,
            else => return error.ReadFailed,
        };
        if (message.data.len == 0) break;
        if (list.items.len + message.data.len > RESPONSE_LIMIT) return error.ResponseTooLarge;
        list.appendSlice(gpa, message.data) catch return error.OutOfMemory;
    }
    return try list.toOwnedSlice(gpa);
}

fn extractCapabilitiesJson(resp: []const u8) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, resp, '\n');
    const first = lines.next() orelse return null;
    const line = std.mem.trimEnd(u8, first, " \t\r");
    const prefix = "capabilities ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    return line[prefix.len..];
}

// ---------------------------------------------------------------------------
// Tool table
// ---------------------------------------------------------------------------

const ToolKind = enum { digest, snapshot, action };

const ArgSpecInfo = struct {
    name: []const u8,
    kind: []const u8,
    optional: bool,
    variadic: bool,
    values: []const []const u8,
    pattern: []const u8,
    desc: []const u8,
    min: ?f64,
    max: ?f64,
};

/// args_mode: .fallback = no args in capabilities / .typed = args array (including empty)
const ArgsMode = enum { fallback, typed };

const Tool = struct {
    mcp_name: []const u8,
    kind: ToolKind,
    harness_name: []const u8,
    ext: []const u8,
    description: []const u8,
    args_mode: ArgsMode,
    arg_specs: []const ArgSpecInfo,
    input_schema: json.Value,
};

fn buildToolTable(gpa: std.mem.Allocator, root: json.ObjectMap) !std.ArrayList(Tool) {
    var tools: std.ArrayList(Tool) = .empty;
    var name_set: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer name_set.deinit(gpa);

    const probes = root.get("probes") orelse return error.McpFailed;
    if (probes != .array) return error.McpFailed;
    for (probes.array.items) |entry| {
        if (entry != .object) continue;
        const obj = entry.object;
        const name = obj.get("name") orelse continue;
        if (name != .string) continue;
        const pname = name.string;
        const ext = if (obj.get("ext")) |e| (if (e == .string) e.string else "bin") else "bin";
        const desc = if (obj.get("desc")) |d| (if (d == .string) d.string else "") else "";
        const has_digest = if (obj.get("digest")) |d| (d == .bool and d.bool) else false;
        const has_snapshot = if (obj.get("snapshot")) |d| (d == .bool and d.bool) else false;

        if (has_digest) {
            const cand = try std.fmt.allocPrint(gpa, "digest_{s}", .{pname});
            try tryAddTool(gpa, &tools, &name_set, .{
                .base_name = cand,
                .probe_prefix = true,
                .kind = .digest,
                .harness_name = pname,
                .ext = ext,
                .description = if (desc.len > 0) desc else try std.fmt.allocPrint(gpa, "digest {s}", .{pname}),
                .args_mode = .typed,
                .arg_specs = &.{},
                .input_schema = try emptyObjectSchema(gpa),
            });
        }
        if (has_snapshot) {
            const cand = try std.fmt.allocPrint(gpa, "snapshot_{s}", .{pname});
            try tryAddTool(gpa, &tools, &name_set, .{
                .base_name = cand,
                .probe_prefix = true,
                .kind = .snapshot,
                .harness_name = pname,
                .ext = ext,
                .description = if (desc.len > 0) desc else try std.fmt.allocPrint(gpa, "snapshot {s}", .{pname}),
                .args_mode = .typed,
                .arg_specs = &.{},
                .input_schema = try emptyObjectSchema(gpa),
            });
        }
    }

    const actions = root.get("actions") orelse return tools;
    if (actions != .array) return tools;
    for (actions.array.items) |entry| {
        if (entry != .object) continue;
        const obj = entry.object;
        const name = obj.get("name") orelse continue;
        if (name != .string) continue;
        const aname = name.string;
        const desc_raw = if (obj.get("desc")) |d| (if (d == .string) d.string else "") else "";

        // args three forms: field absent / .null → fallback / .array → typed (anything else: skip)
        const args_present = obj.get("args");
        if (args_present) |args_v| {
            if (args_v == .null) {
                try addFallbackAction(gpa, &tools, &name_set, aname, desc_raw);
                continue;
            }
            if (args_v != .array) continue;
            const specs: []const ArgSpecInfo = if (args_v.array.items.len == 0)
                &.{}
            else
                try parseArgSpecs(gpa, args_v.array.items);
            const schema = if (specs.len == 0)
                try emptyObjectSchema(gpa)
            else
                try argSpecsToInputSchema(gpa, specs);
            const d = if (desc_raw.len > 0) desc_raw else try std.fmt.allocPrint(gpa, "action {s}", .{aname});
            try tryAddTool(gpa, &tools, &name_set, .{
                .base_name = aname,
                .probe_prefix = false,
                .kind = .action,
                .harness_name = aname,
                .ext = "",
                .description = d,
                .args_mode = .typed,
                .arg_specs = specs,
                .input_schema = schema,
            });
        } else {
            try addFallbackAction(gpa, &tools, &name_set, aname, desc_raw);
        }
    }
    return tools;
}

fn addFallbackAction(
    gpa: std.mem.Allocator,
    tools: *std.ArrayList(Tool),
    name_set: *std.StringArrayHashMapUnmanaged(void),
    aname: []const u8,
    desc_raw: []const u8,
) !void {
    const schema = try fallbackInputSchema(gpa);
    const legacy_note = "legacy raw argument syntax; see the app docs for the format";
    const d = if (desc_raw.len > 0)
        try std.fmt.allocPrint(gpa, "{s} ({s})", .{ desc_raw, legacy_note })
    else
        legacy_note;
    try tryAddTool(gpa, tools, name_set, .{
        .base_name = aname,
        .probe_prefix = false,
        .kind = .action,
        .harness_name = aname,
        .ext = "",
        .description = d,
        .args_mode = .fallback,
        .arg_specs = &.{},
        .input_schema = schema,
    });
}

const AddToolArgs = struct {
    base_name: []const u8,
    probe_prefix: bool,
    kind: ToolKind,
    harness_name: []const u8,
    ext: []const u8,
    description: []const u8,
    args_mode: ArgsMode,
    arg_specs: []const ArgSpecInfo,
    input_schema: json.Value,
};

fn tryAddTool(
    gpa: std.mem.Allocator,
    tools: *std.ArrayList(Tool),
    name_set: *std.StringArrayHashMapUnmanaged(void),
    a: AddToolArgs,
) !void {
    const resolved = resolveToolName(gpa, name_set, a.base_name, a.probe_prefix) catch |err| switch (err) {
        error.Skipped => return,
        else => |e| return e,
    };
    try name_set.put(gpa, resolved, {});
    try tools.append(gpa, .{
        .mcp_name = resolved,
        .kind = a.kind,
        .harness_name = a.harness_name,
        .ext = a.ext,
        .description = a.description,
        .args_mode = a.args_mode,
        .arg_specs = a.arg_specs,
        .input_schema = a.input_schema,
    });
}

/// Collision resolution: preferred name → `p_`/`a_` fallback → skip. Invalid names also skip.
fn resolveToolName(
    gpa: std.mem.Allocator,
    name_set: *const std.StringArrayHashMapUnmanaged(void),
    base: []const u8,
    probe_prefix: bool,
) error{ Skipped, OutOfMemory }![]const u8 {
    if (!isValidToolName(base)) {
        warn("skipping tool name; does not match MCP rules: {s}\n", .{base});
        return error.Skipped;
    }
    if (name_set.get(base) == null) return try gpa.dupe(u8, base);
    const alt = if (probe_prefix)
        try std.fmt.allocPrint(gpa, "p_{s}", .{base})
    else
        try std.fmt.allocPrint(gpa, "a_{s}", .{base});
    if (isValidToolName(alt) and name_set.get(alt) == null) return alt;
    warn("skipping tool name; collision unresolved: {s}\n", .{base});
    return error.Skipped;
}

fn isValidToolName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn emptyObjectSchema(gpa: std.mem.Allocator) !json.Value {
    var obj: json.ObjectMap = .empty;
    try obj.put(gpa, "type", .{ .string = "object" });
    try obj.put(gpa, "properties", .{ .object = .empty });
    const req = json.Array.init(gpa);
    try obj.put(gpa, "required", .{ .array = req });
    return .{ .object = obj };
}

fn fallbackInputSchema(gpa: std.mem.Allocator) !json.Value {
    var args_prop: json.ObjectMap = .empty;
    try args_prop.put(gpa, "type", .{ .string = "string" });
    try args_prop.put(gpa, "description", .{ .string = "legacy raw argument syntax" });

    var props: json.ObjectMap = .empty;
    try props.put(gpa, "args", .{ .object = args_prop });

    var obj: json.ObjectMap = .empty;
    try obj.put(gpa, "type", .{ .string = "object" });
    try obj.put(gpa, "properties", .{ .object = props });
    const req = json.Array.init(gpa);
    try obj.put(gpa, "required", .{ .array = req });
    return .{ .object = obj };
}

fn parseArgSpecs(gpa: std.mem.Allocator, items: []const json.Value) ![]ArgSpecInfo {
    var list: std.ArrayList(ArgSpecInfo) = .empty;
    for (items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const n = o.get("name") orelse continue;
        const k = o.get("kind") orelse continue;
        if (n != .string or k != .string) continue;
        var values: std.ArrayList([]const u8) = .empty;
        if (o.get("values")) |vs| {
            if (vs == .array) {
                for (vs.array.items) |v| {
                    if (v == .string) try values.append(gpa, v.string);
                }
            }
        }
        try list.append(gpa, .{
            .name = n.string,
            .kind = k.string,
            .optional = if (o.get("optional")) |v| (v == .bool and v.bool) else false,
            .variadic = if (o.get("variadic")) |v| (v == .bool and v.bool) else false,
            .values = try values.toOwnedSlice(gpa),
            .pattern = if (o.get("pattern")) |p| (if (p == .string) p.string else "") else "",
            .desc = if (o.get("desc")) |d| (if (d == .string) d.string else "") else "",
            .min = jsonNumberAsFloat(o.get("min")),
            .max = jsonNumberAsFloat(o.get("max")),
        });
    }
    return try list.toOwnedSlice(gpa);
}

fn jsonNumberAsFloat(v: ?json.Value) ?f64 {
    const x = v orelse return null;
    return switch (x) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn argSpecsToInputSchema(gpa: std.mem.Allocator, specs: []const ArgSpecInfo) !json.Value {
    var props: json.ObjectMap = .empty;
    var required = json.Array.init(gpa);
    for (specs) |s| {
        const prop = try argSpecToPropertySchema(gpa, s);
        try props.put(gpa, s.name, prop);
        if (!s.optional) try required.append(.{ .string = s.name });
    }
    var obj: json.ObjectMap = .empty;
    try obj.put(gpa, "type", .{ .string = "object" });
    try obj.put(gpa, "properties", .{ .object = props });
    try obj.put(gpa, "required", .{ .array = required });
    return .{ .object = obj };
}

fn argSpecToPropertySchema(gpa: std.mem.Allocator, s: ArgSpecInfo) !json.Value {
    const base = try kindToJsonSchema(gpa, s);
    if (!s.variadic) return base;
    var arr: json.ObjectMap = .empty;
    try arr.put(gpa, "type", .{ .string = "array" });
    try arr.put(gpa, "items", base);
    return .{ .object = arr };
}

fn kindToJsonSchema(gpa: std.mem.Allocator, s: ArgSpecInfo) !json.Value {
    var obj: json.ObjectMap = .empty;
    if (std.mem.eql(u8, s.kind, "int")) {
        try obj.put(gpa, "type", .{ .string = "integer" });
        if (s.min) |m| try obj.put(gpa, "minimum", jsonFloatOrInt(m));
        if (s.max) |m| try obj.put(gpa, "maximum", jsonFloatOrInt(m));
    } else if (std.mem.eql(u8, s.kind, "float")) {
        try obj.put(gpa, "type", .{ .string = "number" });
        if (s.min) |m| try obj.put(gpa, "minimum", .{ .float = m });
        if (s.max) |m| try obj.put(gpa, "maximum", .{ .float = m });
    } else if (std.mem.eql(u8, s.kind, "bool")) {
        try obj.put(gpa, "type", .{ .string = "boolean" });
    } else if (std.mem.eql(u8, s.kind, "enum")) {
        try obj.put(gpa, "type", .{ .string = "string" });
        var vals = json.Array.init(gpa);
        for (s.values) |v| try vals.append(.{ .string = v });
        try obj.put(gpa, "enum", .{ .array = vals });
    } else {
        // string | path | unknown kind
        try obj.put(gpa, "type", .{ .string = "string" });
        if (s.pattern.len > 0) try obj.put(gpa, "pattern", .{ .string = s.pattern });
    }
    if (s.desc.len > 0) try obj.put(gpa, "description", .{ .string = s.desc });
    return .{ .object = obj };
}

fn jsonFloatOrInt(m: f64) json.Value {
    if (m == @trunc(m) and m >= @as(f64, @floatFromInt(std.math.minInt(i64))) and m <= @as(f64, @floatFromInt(std.math.maxInt(i64)))) {
        return .{ .integer = @intFromFloat(m) };
    }
    return .{ .float = m };
}

fn findTool(tools: []const Tool, name: []const u8) ?*const Tool {
    for (tools) |*t| {
        if (std.mem.eql(u8, t.mcp_name, name)) return t;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Args → raw serialization
// ---------------------------------------------------------------------------

const SerializeError = error{
    InvalidParams,
    OutOfMemory,
};

fn serializeArguments(gpa: std.mem.Allocator, tool: *const Tool, arguments: json.ObjectMap) SerializeError![]const u8 {
    switch (tool.args_mode) {
        .fallback => {
            if (arguments.get("args")) |v| {
                if (v != .string) return error.InvalidParams;
                if (std.mem.indexOfAny(u8, v.string, ";\n\r") != null) return error.InvalidParams;
                return try gpa.dupe(u8, v.string);
            }
            return try gpa.dupe(u8, "");
        },
        .typed => {
            if (tool.arg_specs.len == 0) return try gpa.dupe(u8, "");
            return try serializeTypedArgs(gpa, tool.arg_specs, arguments);
        },
    }
}

fn serializeTypedArgs(gpa: std.mem.Allocator, specs: []const ArgSpecInfo, arguments: json.ObjectMap) SerializeError![]const u8 {
    // optional may be omitted only from the tail: find the omit boundary of trailing optionals
    var end: usize = specs.len;
    while (end > 0 and specs[end - 1].optional and arguments.get(specs[end - 1].name) == null) {
        end -= 1;
    }
    // No holes: missing a required/optional that is still in the kept range is NG
    var i: usize = 0;
    while (i < end) : (i += 1) {
        if (arguments.get(specs[i].name) == null) return error.InvalidParams;
    }
    // A value after end means a hole (omission not at the tail)
    i = end;
    while (i < specs.len) : (i += 1) {
        if (arguments.get(specs[i].name) != null) return error.InvalidParams;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var first = true;
    i = 0;
    while (i < end) : (i += 1) {
        const s = specs[i];
        const val = arguments.get(s.name).?;
        const is_last_path = std.mem.eql(u8, s.kind, "path") and i + 1 == end and !s.variadic;
        if (s.variadic) {
            if (val != .array) return error.InvalidParams;
            for (val.array.items) |item| {
                if (!first) try out.append(gpa, ' ');
                first = false;
                try appendSerializedToken(gpa, &out, s, item, false);
            }
        } else {
            if (!first) try out.append(gpa, ' ');
            first = false;
            try appendSerializedToken(gpa, &out, s, val, is_last_path);
        }
    }
    return try out.toOwnedSlice(gpa);
}

fn appendSerializedToken(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    s: ArgSpecInfo,
    val: json.Value,
    allow_spaces_in_path: bool,
) SerializeError!void {
    if (std.mem.eql(u8, s.kind, "bool")) {
        if (val != .bool) return error.InvalidParams;
        try out.appendSlice(gpa, if (val.bool) "1" else "0");
        return;
    }
    if (std.mem.eql(u8, s.kind, "int")) {
        const n: i64 = switch (val) {
            .integer => |x| x,
            .float => |f| try floatToI64Checked(f),
            else => return error.InvalidParams,
        };
        var buf: [32]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return error.InvalidParams;
        try out.appendSlice(gpa, t);
        return;
    }
    if (std.mem.eql(u8, s.kind, "float")) {
        const f: f64 = switch (val) {
            .float => |x| x,
            .integer => |x| @floatFromInt(x),
            else => return error.InvalidParams,
        };
        var buf: [128]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "{d}", .{f}) catch return error.InvalidParams;
        if (std.mem.indexOfAny(u8, t, "eE") != null) return error.InvalidParams;
        try out.appendSlice(gpa, t);
        return;
    }
    if (std.mem.eql(u8, s.kind, "enum")) {
        if (val != .string) return error.InvalidParams;
        var ok = false;
        for (s.values) |v| {
            if (std.mem.eql(u8, v, val.string)) {
                ok = true;
                break;
            }
        }
        if (!ok) return error.InvalidParams;
        if (std.mem.indexOfAny(u8, val.string, " \t;\n\r") != null) return error.InvalidParams;
        try out.appendSlice(gpa, val.string);
        return;
    }
    // string / path / unknown kind
    if (val != .string) return error.InvalidParams;
    const str = val.string;
    if (allow_spaces_in_path) {
        if (std.mem.indexOfAny(u8, str, ";\n\r") != null) return error.InvalidParams;
    } else {
        if (std.mem.indexOfAny(u8, str, " \t;\n\r") != null) return error.InvalidParams;
    }
    try out.appendSlice(gpa, str);
}

fn floatToI64Checked(f: f64) SerializeError!i64 {
    if (f != @trunc(f)) return error.InvalidParams;
    const lo: f64 = @floatFromInt(std.math.minInt(i64));
    const hi: f64 = @floatFromInt(std.math.maxInt(i64));
    if (f < lo or f > hi) return error.InvalidParams;
    return @intFromFloat(f);
}

// ---------------------------------------------------------------------------
// Extract the fail line (code=/next= from the right end)
// ---------------------------------------------------------------------------

const FailInfo = struct {
    name: []const u8,
    message: []const u8,
    code: ?[]const u8,
    next: ?[]const u8,
};

/// Parse `fail <name> <msg> [code=<c> next=<n>]` with right-end-only fields. Requires a leading `fail `.
fn parseFailLine(line: []const u8) ?FailInfo {
    const prefix = "fail ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = line[prefix.len..];
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse {
        if (rest.len == 0) return null;
        return .{ .name = rest, .message = "", .code = null, .next = null };
    };
    const name = rest[0..sp];
    var msg_part = rest[sp + 1 ..];

    var code: ?[]const u8 = null;
    var next: ?[]const u8 = null;
    // Search from the right for " code="
    if (std.mem.lastIndexOf(u8, msg_part, " code=")) |code_at| {
        const after_code = msg_part[code_at + " code=".len ..];
        if (std.mem.indexOf(u8, after_code, " next=")) |next_at| {
            code = after_code[0..next_at];
            next = after_code[next_at + " next=".len ..];
            msg_part = msg_part[0..code_at];
        }
        // If next= is absent, do not take code= either (pass the whole remainder as msg)
    }
    return .{ .name = name, .message = msg_part, .code = code, .next = next };
}

fn formatFailText(gpa: std.mem.Allocator, info: FailInfo) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, "harness action failed\nname: ");
    try out.appendSlice(gpa, info.name);
    try out.appendSlice(gpa, "\nmessage: ");
    try out.appendSlice(gpa, info.message);
    if (info.code) |c| {
        try out.appendSlice(gpa, "\ncode: ");
        try out.appendSlice(gpa, c);
    }
    if (info.next) |n| {
        try out.appendSlice(gpa, "\nnext: ");
        try out.appendSlice(gpa, n);
    }
    return try out.toOwnedSlice(gpa);
}

fn findFirstFailLine(resp: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, resp, '\n');
    while (lines.next()) |ln| {
        const t = std.mem.trimEnd(u8, ln, "\r");
        if (std.mem.startsWith(u8, t, "fail ")) return t;
    }
    return null;
}

// ---------------------------------------------------------------------------
// MCP session / JSON-RPC
// ---------------------------------------------------------------------------

const Phase = enum { need_initialize, need_initialized, ready };

const Session = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    port: u16,
    out_abs: []const u8,
    tools: []const Tool,
    snapshot_seq: u32,
    phase: Phase,
};

fn runStdioLoop(session: *Session) !void {
    var in_buf: [MESSAGE_MAX]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(session.io, &in_buf);

    var out_buf: [MESSAGE_MAX]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(session.io, &out_buf);

    while (true) {
        const line = stdin_reader.interface.takeDelimiter(0x0A) catch |err| switch (err) {
            error.StreamTooLong => {
                var msg_arena = std.heap.ArenaAllocator.init(session.gpa);
                defer msg_arena.deinit();
                try writeJsonLine(&stdout.interface, try errorResponse(msg_arena.allocator(), .null, -32700, "Parse error: message too long"));
                _ = stdin_reader.interface.discardRemaining() catch {};
                continue;
            },
            else => return err,
        } orelse break; // EOF

        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) continue;

        // Per-message arena: parse / response JSON / TCP scratch freed here
        var msg_arena = std.heap.ArenaAllocator.init(session.gpa);
        defer msg_arena.deinit();
        const msg_gpa = msg_arena.allocator();

        const maybe_resp = try handleLine(session, msg_gpa, trimmed);
        if (maybe_resp) |resp| {
            try writeJsonLine(&stdout.interface, resp);
        }
    }
}

fn writeJsonLine(w: *std.Io.Writer, payload: []const u8) !void {
    try w.writeAll(payload);
    try w.writeAll("\n");
    try w.flush();
}

fn handleLine(session: *Session, msg_gpa: std.mem.Allocator, line: []const u8) !?[]const u8 {
    const msg = json.parseFromSliceLeaky(json.Value, msg_gpa, line, .{}) catch {
        return try errorResponse(msg_gpa, .null, -32700, "Parse error");
    };
    if (msg != .object) {
        return try errorResponse(msg_gpa, .null, -32700, "Parse error");
    }
    const obj = msg.object;

    if (obj.get("jsonrpc")) |v| {
        if (v != .string or !std.mem.eql(u8, v.string, "2.0")) {
            const id = obj.get("id") orelse .null;
            return try errorResponse(msg_gpa, id, -32600, "Invalid Request");
        }
    }

    const method_v = obj.get("method") orelse {
        const id = obj.get("id") orelse .null;
        return try errorResponse(msg_gpa, id, -32600, "Invalid Request");
    };
    if (method_v != .string) {
        const id = obj.get("id") orelse .null;
        return try errorResponse(msg_gpa, id, -32600, "Invalid Request");
    }
    const method = method_v.string;
    const has_id = obj.get("id") != null;
    const id = obj.get("id") orelse .null;

    if (!has_id) {
        if (std.mem.eql(u8, method, "notifications/initialized")) {
            if (session.phase == .need_initialized) {
                session.phase = .ready;
            }
            return null;
        }
        return null;
    }

    if (std.mem.eql(u8, method, "initialize")) {
        return try handleInitialize(session, msg_gpa, id, obj.get("params"));
    }
    if (session.phase == .need_initialize) {
        return try errorResponse(msg_gpa, id, -32602, "Server not initialized");
    }
    if (std.mem.eql(u8, method, "ping")) {
        return try resultResponse(msg_gpa, id, .{ .object = .empty });
    }
    if (session.phase != .ready) {
        return try errorResponse(msg_gpa, id, -32602, "notifications/initialized required before tools");
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        return try handleToolsList(session, msg_gpa, id);
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        return try handleToolsCall(session, msg_gpa, id, obj.get("params"));
    }
    return try errorResponse(msg_gpa, id, -32601, "Method not found");
}

fn handleInitialize(session: *Session, msg_gpa: std.mem.Allocator, id: json.Value, params: ?json.Value) ![]const u8 {
    if (session.phase != .need_initialize) {
        return try errorResponse(msg_gpa, id, -32602, "already initialized");
    }
    const p = params orelse {
        return try errorResponse(msg_gpa, id, -32602, "Invalid params: params required");
    };
    if (p == .null) {
        return try errorResponse(msg_gpa, id, -32602, "Invalid params: params must be object");
    }
    if (p != .object) {
        return try errorResponse(msg_gpa, id, -32602, "Invalid params: params must be object");
    }
    const pv = p.object.get("protocolVersion") orelse {
        return try errorResponse(msg_gpa, id, -32602, "Invalid params: protocolVersion required");
    };
    if (pv != .string) {
        return try errorResponse(msg_gpa, id, -32602, "Invalid params: protocolVersion must be string");
    }
    if (!std.mem.eql(u8, pv.string, PROTOCOL_VERSION)) {
        return try errorResponse(msg_gpa, id, -32602, "Unsupported protocolVersion");
    }
    session.phase = .need_initialized;

    var tools_cap: json.ObjectMap = .empty;
    try tools_cap.put(msg_gpa, "listChanged", .{ .bool = false });
    var caps: json.ObjectMap = .empty;
    try caps.put(msg_gpa, "tools", .{ .object = tools_cap });

    var server: json.ObjectMap = .empty;
    try server.put(msg_gpa, "name", .{ .string = SERVER_NAME });
    try server.put(msg_gpa, "version", .{ .string = SERVER_VERSION });

    var result: json.ObjectMap = .empty;
    try result.put(msg_gpa, "protocolVersion", .{ .string = PROTOCOL_VERSION });
    try result.put(msg_gpa, "capabilities", .{ .object = caps });
    try result.put(msg_gpa, "serverInfo", .{ .object = server });
    return try resultResponse(msg_gpa, id, .{ .object = result });
}

fn handleToolsList(session: *Session, msg_gpa: std.mem.Allocator, id: json.Value) ![]const u8 {
    var tools_arr = json.Array.init(msg_gpa);
    for (session.tools) |t| {
        var tool_obj: json.ObjectMap = .empty;
        try tool_obj.put(msg_gpa, "name", .{ .string = t.mcp_name });
        try tool_obj.put(msg_gpa, "description", .{ .string = t.description });
        try tool_obj.put(msg_gpa, "inputSchema", t.input_schema);
        try tools_arr.append(.{ .object = tool_obj });
    }
    var result: json.ObjectMap = .empty;
    try result.put(msg_gpa, "tools", .{ .array = tools_arr });
    return try resultResponse(msg_gpa, id, .{ .object = result });
}

fn handleToolsCall(session: *Session, msg_gpa: std.mem.Allocator, id: json.Value, params: ?json.Value) ![]const u8 {
    const p = params orelse {
        return try errorResponse(msg_gpa, id, -32602, "Invalid params");
    };
    if (p != .object) return try errorResponse(msg_gpa, id, -32602, "Invalid params");
    const name_v = p.object.get("name") orelse {
        return try errorResponse(msg_gpa, id, -32602, "Invalid params: name required");
    };
    if (name_v != .string) return try errorResponse(msg_gpa, id, -32602, "Invalid params: name");
    const tool = findTool(session.tools, name_v.string) orelse {
        return try errorResponse(msg_gpa, id, -32602, "Unknown tool");
    };

    var arguments: json.ObjectMap = .empty;
    if (p.object.get("arguments")) |a| {
        if (a != .object) return try errorResponse(msg_gpa, id, -32602, "Invalid params: arguments");
        arguments = a.object;
    }

    const raw = serializeArguments(msg_gpa, tool, arguments) catch {
        return try errorResponse(msg_gpa, id, -32602, "Invalid params: argument serialization");
    };

    const cmd = try buildHarnessCommand(session, msg_gpa, tool, raw);
    const resp = sendRequest(session.io, msg_gpa, session.port, cmd) catch |err| {
        const msg = switch (err) {
            error.ConnectFailed => "TCP connect failed; restart vp-mcp after the app is running",
            error.ResponseTimeout => "TCP response timeout; restart vp-mcp if the app exited",
            error.WriteFailed, error.ReadFailed => "TCP I/O failed; restart vp-mcp after the app is running",
            error.ResponseTooLarge => "TCP response too large",
            error.OutOfMemory => "out of memory",
        };
        return try errorResponse(msg_gpa, id, -32000, msg);
    };

    const trimmed = nonemptyTrimmed(resp) catch {
        return try errorResponse(msg_gpa, id, -32000, "empty TCP response");
    };

    if (findFirstFailLine(resp)) |fail_line| {
        const info = parseFailLine(fail_line) orelse FailInfo{ .name = tool.harness_name, .message = fail_line, .code = null, .next = null };
        const text = try formatFailText(msg_gpa, info);
        return try toolResultResponse(msg_gpa, id, text, true);
    }

    if (tool.kind == .snapshot) {
        const first = firstLineOf(trimmed);
        if (!std.fs.path.isAbsolute(first)) {
            return try errorResponse(msg_gpa, id, -32000, "snapshot path is not absolute; set VP_HARNESS_OUT / --out correctly and restart vp-mcp");
        }
        return try toolResultResponse(msg_gpa, id, first, false);
    }

    return try toolResultResponse(msg_gpa, id, trimmed, false);
}

/// EmptyResponse when trim yields empty.
fn nonemptyTrimmed(resp: []const u8) error{EmptyResponse}![]const u8 {
    const t = std.mem.trim(u8, resp, " \t\r\n");
    if (t.len == 0) return error.EmptyResponse;
    return t;
}

fn firstLineOf(text: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '\n')) |nl| {
        return std.mem.trimEnd(u8, text[0..nl], "\r");
    }
    return text;
}

fn buildHarnessCommand(session: *Session, msg_gpa: std.mem.Allocator, tool: *const Tool, raw: []const u8) ![]const u8 {
    switch (tool.kind) {
        .digest => return try std.fmt.allocPrint(msg_gpa, "digest {s}", .{tool.harness_name}),
        .snapshot => {
            session.snapshot_seq += 1;
            const path = try std.fmt.allocPrint(msg_gpa, "{s}/{s}_{d}.{s}", .{
                session.out_abs,
                tool.harness_name,
                session.snapshot_seq,
                tool.ext,
            });
            return try std.fmt.allocPrint(msg_gpa, "snapshot {s} {s}", .{ tool.harness_name, path });
        },
        .action => {
            if (raw.len == 0) return try std.fmt.allocPrint(msg_gpa, "action {s}", .{tool.harness_name});
            return try std.fmt.allocPrint(msg_gpa, "action {s} {s}", .{ tool.harness_name, raw });
        },
    }
}

fn resultResponse(gpa: std.mem.Allocator, id: json.Value, result: json.Value) ![]const u8 {
    var obj: json.ObjectMap = .empty;
    try obj.put(gpa, "jsonrpc", .{ .string = "2.0" });
    try obj.put(gpa, "id", id);
    try obj.put(gpa, "result", result);
    return try stringifyMinified(gpa, .{ .object = obj });
}

fn toolResultResponse(gpa: std.mem.Allocator, id: json.Value, text: []const u8, is_error: bool) ![]const u8 {
    var content_item: json.ObjectMap = .empty;
    try content_item.put(gpa, "type", .{ .string = "text" });
    try content_item.put(gpa, "text", .{ .string = text });
    var content = json.Array.init(gpa);
    try content.append(.{ .object = content_item });
    var result: json.ObjectMap = .empty;
    try result.put(gpa, "content", .{ .array = content });
    if (is_error) try result.put(gpa, "isError", .{ .bool = true });
    return try resultResponse(gpa, id, .{ .object = result });
}

fn errorResponse(gpa: std.mem.Allocator, id: json.Value, code: i64, message: []const u8) ![]const u8 {
    var err_obj: json.ObjectMap = .empty;
    try err_obj.put(gpa, "code", .{ .integer = code });
    try err_obj.put(gpa, "message", .{ .string = message });
    var obj: json.ObjectMap = .empty;
    try obj.put(gpa, "jsonrpc", .{ .string = "2.0" });
    try obj.put(gpa, "id", id);
    try obj.put(gpa, "error", .{ .object = err_obj });
    return try stringifyMinified(gpa, .{ .object = obj });
}

fn stringifyMinified(gpa: std.mem.Allocator, value: json.Value) ![]const u8 {
    const bytes = try json.Stringify.valueAlloc(gpa, value, .{ .whitespace = .minified });
    // minified emits no newlines (contract tests also check the response side)
    std.debug.assert(std.mem.indexOfScalar(u8, bytes, '\n') == null);
    return bytes;
}

// ---------------------------------------------------------------------------
// Tests (pure functions)
// ---------------------------------------------------------------------------

test "tool name: MCP rules" {
    try testing.expect(isValidToolName("digest_canvas"));
    try testing.expect(isValidToolName("a_digest_canvas"));
    try testing.expect(isValidToolName("A-z_09"));
    try testing.expect(!isValidToolName(""));
    try testing.expect(!isValidToolName("has space"));
    try testing.expect(!isValidToolName("bad.name"));
    const long = [_]u8{'a'} ** 65;
    try testing.expect(!isValidToolName(&long));
    const ok64 = [_]u8{'a'} ** 64;
    try testing.expect(isValidToolName(&ok64));
}

test "collision: action colliding with probe-derived name → a_ fallback" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    const caps =
        \\{"probes":[{"name":"canvas","ext":"txt","snapshot":false,"digest":true,"desc":"c"}],"actions":[{"name":"digest_canvas","desc":"collide"}]}
    ;
    const root = try json.parseFromSliceLeaky(json.Value, gpa, caps, .{});
    const tools = try buildToolTable(gpa, root.object);
    var found_digest = false;
    var found_action = false;
    for (tools.items) |t| {
        if (std.mem.eql(u8, t.mcp_name, "digest_canvas") and t.kind == .digest) found_digest = true;
        if (std.mem.eql(u8, t.mcp_name, "a_digest_canvas") and t.kind == .action) found_action = true;
    }
    try testing.expect(found_digest);
    try testing.expect(found_action);
    try testing.expect(findTool(tools.items, "a_digest_canvas") != null);
    try testing.expect(findTool(tools.items, "digest_canvas").?.kind == .digest);
}

test "schema convert: int/float/bool/enum/string/variadic/optional" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    const specs = [_]ArgSpecInfo{
        .{ .name = "tool", .kind = "enum", .optional = true, .variadic = false, .values = &.{ "pen", "eraser" }, .pattern = "", .desc = "tool name", .min = null, .max = null },
        .{ .name = "n", .kind = "int", .optional = false, .variadic = true, .values = &.{}, .pattern = "", .desc = "", .min = 0, .max = 255 },
        .{ .name = "color", .kind = "string", .optional = false, .variadic = false, .values = &.{}, .pattern = "#?RRGGBB", .desc = "", .min = null, .max = null },
        .{ .name = "on", .kind = "bool", .optional = false, .variadic = false, .values = &.{}, .pattern = "", .desc = "", .min = null, .max = null },
        .{ .name = "x", .kind = "float", .optional = false, .variadic = false, .values = &.{}, .pattern = "", .desc = "", .min = 0.5, .max = 1.5 },
    };
    const schema = try argSpecsToInputSchema(gpa, &specs);
    const props = schema.object.get("properties").?.object;
    try testing.expectEqualStrings("integer", props.get("n").?.object.get("items").?.object.get("type").?.string);
    try testing.expectEqualStrings("array", props.get("n").?.object.get("type").?.string);
    try testing.expectEqualStrings("boolean", props.get("on").?.object.get("type").?.string);
    try testing.expectEqualStrings("number", props.get("x").?.object.get("type").?.string);
    try testing.expectEqualStrings("#?RRGGBB", props.get("color").?.object.get("pattern").?.string);
    const req = schema.object.get("required").?.array.items;
    // tool treats optional as absent from required
    for (req) |r| try testing.expect(!std.mem.eql(u8, r.string, "tool"));
}

test "schema convert: no args → fallback / args:null → fallback / args:[] → empty properties" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    const caps_absent =
        \\{"probes":[],"actions":[{"name":"legacy","desc":"d"}]}
    ;
    const root1 = try json.parseFromSliceLeaky(json.Value, gpa, caps_absent, .{});
    const tools1 = try buildToolTable(gpa, root1.object);
    try testing.expectEqual(@as(usize, 1), tools1.items.len);
    try testing.expect(tools1.items[0].args_mode == .fallback);
    try testing.expect(tools1.items[0].input_schema.object.get("properties").?.object.get("args") != null);

    const caps_null =
        \\{"probes":[],"actions":[{"name":"legacy2","desc":"d","args":null}]}
    ;
    const root_null = try json.parseFromSliceLeaky(json.Value, gpa, caps_null, .{});
    const tools_null = try buildToolTable(gpa, root_null.object);
    try testing.expectEqual(@as(usize, 1), tools_null.items.len);
    try testing.expect(tools_null.items[0].args_mode == .fallback);
    try testing.expectEqualStrings("legacy2", tools_null.items[0].mcp_name);

    const caps_empty =
        \\{"probes":[],"actions":[{"name":"none","desc":"","args":[]}]}
    ;
    const root2 = try json.parseFromSliceLeaky(json.Value, gpa, caps_empty, .{});
    const tools2 = try buildToolTable(gpa, root2.object);
    try testing.expect(tools2.items[0].args_mode == .typed);
    try testing.expectEqual(@as(usize, 0), tools2.items[0].arg_specs.len);
    try testing.expectEqual(@as(usize, 0), tools2.items[0].input_schema.object.get("properties").?.object.count());
}

test "serialize: declaration order, variadic flatten, bool 0/1, optional tail-only" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    const specs = [_]ArgSpecInfo{
        .{ .name = "points", .kind = "int", .optional = false, .variadic = true, .values = &.{}, .pattern = "", .desc = "", .min = null, .max = null },
        .{ .name = "visible", .kind = "bool", .optional = false, .variadic = false, .values = &.{}, .pattern = "", .desc = "", .min = null, .max = null },
        .{ .name = "label", .kind = "string", .optional = true, .variadic = false, .values = &.{}, .pattern = "", .desc = "", .min = null, .max = null },
    };
    var args: json.ObjectMap = .empty;
    // Insert keys in reverse order on purpose
    try args.put(gpa, "visible", .{ .bool = true });
    var pts = json.Array.init(gpa);
    try pts.append(.{ .integer = 30 });
    try pts.append(.{ .integer = 40 });
    try pts.append(.{ .integer = 50 });
    try pts.append(.{ .integer = 60 });
    try args.put(gpa, "points", .{ .array = pts });

    const tool = Tool{
        .mcp_name = "stroke",
        .kind = .action,
        .harness_name = "stroke",
        .ext = "",
        .description = "",
        .args_mode = .typed,
        .arg_specs = &specs,
        .input_schema = .null,
    };
    const raw = try serializeArguments(gpa, &tool, args);
    try testing.expectEqualStrings("30 40 50 60 1", raw);

    // label may be omitted
    // hole: no visible, but label present → NG
    var bad: json.ObjectMap = .empty;
    try bad.put(gpa, "points", .{ .array = pts });
    try bad.put(gpa, "label", .{ .string = "x" });
    try testing.expectError(error.InvalidParams, serializeArguments(gpa, &tool, bad));

    // whitespace in string → NG
    var sp: json.ObjectMap = .empty;
    try sp.put(gpa, "points", .{ .array = pts });
    try sp.put(gpa, "visible", .{ .bool = false });
    try sp.put(gpa, "label", .{ .string = "a b" });
    try testing.expectError(error.InvalidParams, serializeArguments(gpa, &tool, sp));
}

test "serialize: final path arg may contain spaces; ; and newline rejected / fallback args" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    const specs = [_]ArgSpecInfo{
        .{ .name = "file", .kind = "path", .optional = false, .variadic = false, .values = &.{}, .pattern = "", .desc = "", .min = null, .max = null },
    };
    const tool = Tool{
        .mcp_name = "load",
        .kind = .action,
        .harness_name = "load",
        .ext = "",
        .description = "",
        .args_mode = .typed,
        .arg_specs = &specs,
        .input_schema = .null,
    };
    var args: json.ObjectMap = .empty;
    try args.put(gpa, "file", .{ .string = "/tmp/my file.pix" });
    try testing.expectEqualStrings("/tmp/my file.pix", try serializeArguments(gpa, &tool, args));

    var bad: json.ObjectMap = .empty;
    try bad.put(gpa, "file", .{ .string = "/tmp/a;b" });
    try testing.expectError(error.InvalidParams, serializeArguments(gpa, &tool, bad));

    const fb = Tool{
        .mcp_name = "legacy",
        .kind = .action,
        .harness_name = "legacy",
        .ext = "",
        .description = "",
        .args_mode = .fallback,
        .arg_specs = &.{},
        .input_schema = .null,
    };
    var fa: json.ObjectMap = .empty;
    try fa.put(gpa, "args", .{ .string = "1 2 3" });
    try testing.expectEqualStrings("1 2 3", try serializeArguments(gpa, &fb, fa));
    var fa2: json.ObjectMap = .empty;
    try fa2.put(gpa, "args", .{ .string = "1;2" });
    try testing.expectError(error.InvalidParams, serializeArguments(gpa, &fb, fa2));
}

test "fail line: extract right-end code=/next= / else pass through" {
    const a = parseFailLine("fail boom Boom code=file_not_found next=check path or use save first").?;
    try testing.expectEqualStrings("boom", a.name);
    try testing.expectEqualStrings("Boom", a.message);
    try testing.expectEqualStrings("file_not_found", a.code.?);
    try testing.expectEqualStrings("check path or use save first", a.next.?);

    const b = parseFailLine("fail plain Boom").?;
    try testing.expectEqualStrings("plain", b.name);
    try testing.expectEqualStrings("Boom", b.message);
    try testing.expect(b.code == null);
    try testing.expect(b.next == null);

    // code= only (no next=) → pass the whole remainder as msg
    const c = parseFailLine("fail x msg code=only").?;
    try testing.expectEqualStrings("msg code=only", c.message);
    try testing.expect(c.code == null);

    // Even if the message looks like it contains code=, only the right-end " code=" + " next=" pair counts
    const d = parseFailLine("fail x see code=fake stuff code=real next=go").?;
    try testing.expectEqualStrings("see code=fake stuff", d.message);
    try testing.expectEqualStrings("real", d.code.?);
    try testing.expectEqualStrings("go", d.next.?);
}

test "fail text fixed multi-line form" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const text = try formatFailText(gpa, .{
        .name = "boom",
        .message = "Boom",
        .code = "file_not_found",
        .next = "check path",
    });
    try testing.expectEqualStrings(
        "harness action failed\nname: boom\nmessage: Boom\ncode: file_not_found\nnext: check path",
        text,
    );
    const text2 = try formatFailText(gpa, .{
        .name = "plain",
        .message = "Boom",
        .code = null,
        .next = null,
    });
    try testing.expectEqualStrings(
        "harness action failed\nname: plain\nmessage: Boom",
        text2,
    );
}

test "contract: initialize / version / gate / unknown / parse / minified" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var session: Session = .{
        .io = undefined, // do not tools/call
        .gpa = gpa,
        .port = 0,
        .out_abs = "/tmp",
        .tools = &.{},
        .snapshot_seq = 0,
        .phase = .need_initialize,
    };

    // tools/list before initialize → error
    {
        const r = (try handleLine(&session, gpa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}")).?;
        try testing.expect(std.mem.indexOf(u8, r, "-32602") != null);
        try testing.expect(std.mem.indexOf(u8, r, "\n") == null);
    }

    // bad version
    {
        const r = (try handleLine(&session, gpa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"1999-01-01\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"0\"}}}")).?;
        try testing.expect(std.mem.indexOf(u8, r, "-32602") != null);
        try testing.expect(session.phase == .need_initialize);
    }

    // ok initialize
    {
        const r = (try handleLine(&session, gpa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"0\"}}}")).?;
        try testing.expect(std.mem.indexOf(u8, r, "\"protocolVersion\":\"2025-06-18\"") != null);
        try testing.expect(std.mem.indexOf(u8, r, "\"listChanged\":false") != null);
        try testing.expect(std.mem.indexOf(u8, r, "\"name\":\"vp-mcp\"") != null);
        try testing.expect(session.phase == .need_initialized);
        try testing.expect(std.mem.indexOf(u8, r, "\n") == null);
    }

    // tools/list before initialized
    {
        const r = (try handleLine(&session, gpa, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")).?;
        try testing.expect(std.mem.indexOf(u8, r, "-32602") != null);
    }

    // notification: no response
    {
        const r = try handleLine(&session, gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
        try testing.expect(r == null);
        try testing.expect(session.phase == .ready);
    }

    // double initialize
    {
        const r = (try handleLine(&session, gpa, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\"}}")).?;
        try testing.expect(std.mem.indexOf(u8, r, "-32602") != null);
        try testing.expect(std.mem.indexOf(u8, r, "already initialized") != null);
    }

    // unknown method
    {
        const r = (try handleLine(&session, gpa, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"foo/bar\"}")).?;
        try testing.expect(std.mem.indexOf(u8, r, "-32601") != null);
    }

    // invalid JSON
    {
        const r = (try handleLine(&session, gpa, "{not json")).?;
        try testing.expect(std.mem.indexOf(u8, r, "-32700") != null);
    }

    // echo string ids too
    {
        const r = (try handleLine(&session, gpa, "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"ping\"}")).?;
        try testing.expect(std.mem.indexOf(u8, r, "\"id\":\"abc\"") != null);
    }
}

test "contract: initialize params missing/null/non-object/version required" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var session: Session = .{
        .io = undefined,
        .gpa = gpa,
        .port = 0,
        .out_abs = "/tmp",
        .tools = &.{},
        .snapshot_seq = 0,
        .phase = .need_initialize,
    };

    // missing params
    {
        const r = (try handleLine(&session, gpa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}")).?;
        try testing.expect(std.mem.indexOf(u8, r, "-32602") != null);
        try testing.expect(session.phase == .need_initialize);
    }
    // params: null
    {
        const r = (try handleLine(&session, gpa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":null}")).?;
        try testing.expect(std.mem.indexOf(u8, r, "-32602") != null);
    }
    // params: not an object
    {
        const r = (try handleLine(&session, gpa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":[]}")).?;
        try testing.expect(std.mem.indexOf(u8, r, "-32602") != null);
    }
    // missing protocolVersion
    {
        const r = (try handleLine(&session, gpa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{}}}")).?;
        try testing.expect(std.mem.indexOf(u8, r, "-32602") != null);
        try testing.expect(std.mem.indexOf(u8, r, "protocolVersion") != null);
    }
    // protocolVersion is not a string
    {
        const r = (try handleLine(&session, gpa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1}}")).?;
        try testing.expect(std.mem.indexOf(u8, r, "-32602") != null);
    }
}

test "empty TCP response → EmptyResponse / firstLineOf" {
    try testing.expectError(error.EmptyResponse, nonemptyTrimmed(""));
    try testing.expectError(error.EmptyResponse, nonemptyTrimmed("   \n\r\t  "));
    const t = try nonemptyTrimmed("  hello\nworld  ");
    try testing.expectEqualStrings("hello\nworld", t);
    try testing.expectEqualStrings("hello", firstLineOf(t));
    try testing.expectEqualStrings("/tmp/a.png", firstLineOf("/tmp/a.png\nextra"));
}

test "serialize: out-of-range float→int / enum out of set → InvalidParams" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    try testing.expectError(error.InvalidParams, floatToI64Checked(1e100));
    try testing.expectError(error.InvalidParams, floatToI64Checked(1.5));
    try testing.expectEqual(@as(i64, 42), try floatToI64Checked(42.0));

    const specs = [_]ArgSpecInfo{
        .{ .name = "tool", .kind = "enum", .optional = false, .variadic = false, .values = &.{ "pen", "eraser" }, .pattern = "", .desc = "", .min = null, .max = null },
    };
    const tool = Tool{
        .mcp_name = "set_tool",
        .kind = .action,
        .harness_name = "set_tool",
        .ext = "",
        .description = "",
        .args_mode = .typed,
        .arg_specs = &specs,
        .input_schema = .null,
    };
    var bad: json.ObjectMap = .empty;
    try bad.put(gpa, "tool", .{ .string = "spray" });
    try testing.expectError(error.InvalidParams, serializeArguments(gpa, &tool, bad));

    var ok: json.ObjectMap = .empty;
    try ok.put(gpa, "tool", .{ .string = "pen" });
    try testing.expectEqualStrings("pen", try serializeArguments(gpa, &tool, ok));

    const ispecs = [_]ArgSpecInfo{
        .{ .name = "n", .kind = "int", .optional = false, .variadic = false, .values = &.{}, .pattern = "", .desc = "", .min = null, .max = null },
    };
    const itool = Tool{
        .mcp_name = "n",
        .kind = .action,
        .harness_name = "n",
        .ext = "",
        .description = "",
        .args_mode = .typed,
        .arg_specs = &ispecs,
        .input_schema = .null,
    };
    var huge: json.ObjectMap = .empty;
    try huge.put(gpa, "n", .{ .float = 1e100 });
    try testing.expectError(error.InvalidParams, serializeArguments(gpa, &itool, huge));
}

test "--out path with whitespace is a startup error" {
    try testing.expectError(error.McpFailed, validateOutArg("/tmp/has space"));
    try testing.expectError(error.McpFailed, validateOutArg("/tmp/has\ttab"));
    try validateOutArg("/tmp/vp-mcp-ok");
}

test "min/max JSON accepts both .integer and .float" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const items = try json.parseFromSliceLeaky(json.Value, gpa,
        \\[{"name":"n","kind":"int","min":0,"max":255}]
    , .{});
    const specs = try parseArgSpecs(gpa, items.array.items);
    try testing.expectEqual(@as(f64, 0), specs[0].min.?);
    try testing.expectEqual(@as(f64, 255), specs[0].max.?);

    const items2 = try json.parseFromSliceLeaky(json.Value, gpa,
        \\[{"name":"x","kind":"float","min":0.5,"max":1.5}]
    , .{});
    const specs2 = try parseArgSpecs(gpa, items2.array.items);
    try testing.expectEqual(@as(f64, 0.5), specs2[0].min.?);
    try testing.expectEqual(@as(f64, 1.5), specs2[0].max.?);
}

test "truncated capabilities detection (startup-failure guard)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const v = try json.parseFromSliceLeaky(json.Value, gpa,
        \\{"probes":[],"actions":[],"truncated":true}
    , .{});
    try testing.expect(v.object.get("truncated").?.bool);
}

test "probe both flags false → no tool / both digest+snapshot" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const caps =
        \\{"probes":[{"name":"p1","ext":"txt","snapshot":false,"digest":false,"desc":""},{"name":"p2","ext":"png","snapshot":true,"digest":true,"desc":"d"}],"actions":[]}
    ;
    const root = try json.parseFromSliceLeaky(json.Value, gpa, caps, .{});
    const tools = try buildToolTable(gpa, root.object);
    try testing.expectEqual(@as(usize, 2), tools.items.len);
    try testing.expectEqualStrings("digest_p2", tools.items[0].mcp_name);
    try testing.expectEqualStrings("snapshot_p2", tools.items[1].mcp_name);
}
