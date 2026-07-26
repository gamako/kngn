//! Action registry: the registry of custom actions, split out of the harness.
//!
//! An application opt-in registers a high-level operation with `platform.registerAction(...)`, and the
//! harness, copilot and netsync invoke it through `dispatch` / `routeLocalAction`. std only (it depends on
//! neither harness nor netsync; the core layer of ADR-007).
//!
//! ## Hot path declaration
//! At event time only (an action command arriving, a register). It touches nothing per frame (over every pixel) or real-time (per sample).
//!
//! ## The enable gate
//! `enabled` is an OR condition (only `setEnabled(true)` takes effect; `resetForTest` is the only way to clear it).
//! Callers: harness.startTransport, setExternalRegistryEnabled(true), and netsync in future.

const std = @import("std");

/// The policy for routing an action while netsync concurrent editing is on. The default is `.reject_when_synced`.
pub const NetworkPolicy = enum {
    /// PROPOSE to the host, then a COMMIT applies it on every peer.
    relay,
    /// Always local only (save, for example).
    local_only,
    /// Rejected during a netsync session (the default; undo, layers and so on).
    reject_when_synced,
    /// Revert only one's own commit.
    undo_own,
    /// Redo one's own revert.
    redo_own,
    /// Ephemeral presence. Consumes no COMMIT, PROPOSE or seq, and takes a dedicated path.
    ephemeral,
};

/// One element of an action's or a probe's argument signature.
/// **The framework only transcribes it and never interprets its meaning** (it neither validates the vocabulary of kind nor checks values for consistency).
/// The slices (name, kind, values, pattern, desc) are guaranteed a static lifetime by the registrant (the same contract as Action.name).
///
/// kind is a string (the recommended vocabulary is "int"/"float"/"string"/"bool"/"enum"/"path"; an application-specific kind is allowed too.
/// Interpreting an unknown kind is the consumer's responsibility — that is, the MCP server's).
pub const ArgSpec = struct {
    name: []const u8,
    kind: []const u8,
    min: ?f64 = null,
    max: ?f64 = null,
    values: []const []const u8 = &.{},
    pattern: []const u8 = "",
    optional: bool = false,
    variadic: bool = false,
    desc: []const u8 = "",
};

/// A custom action registered by an application. **The framework does not interpret its contents** (the same invariant as a probe):
/// it hands the raw remainder of the line after `<name>` in `action <name> [args...]` straight to `run`,
/// and forwards the return value (one line) straight to the existing sink.
pub const Action = struct {
    /// The action name (the argument of `action <name> ...`; a name containing whitespace, `;` or a newline cannot be registered).
    name: []const u8,
    /// The opaque context handed to the callback (a pointer to the application's state).
    ctx: *anyopaque,
    /// A description for the capabilities listing (optional). At registration, sanitising empties it if it holds a forbidden character or exceeds 200B.
    desc: []const u8 = "",
    /// The argument signature (optional, backwards compatible).
    /// **null = unspecified (as before: no args field in the JSON) / an empty slice = an explicit declaration of "no arguments"**
    /// (a distinction the MCP server needs in order to decide on a fallback: null and `[]` differ in the JSON).
    args: ?[]const ArgSpec = null,
    /// The netsync routing policy (default `.reject_when_synced`, so existing registerAction calls need no change).
    network_policy: NetworkPolicy = .reject_when_synced,
    /// A callback that canonicalises the arguments before a `.relay` PROPOSE or local apply (optional).
    canonicalize: ?CanonicalizeFn = null,
    /// The write callback: performs the operation and returns one line of result.
    /// - `args` is the raw remainder of the line after `action <name>` (already trimmed, never re-tokenised).
    /// - The return value is one line and holds no newline. It may be a slice inside `buf`, or a temporary slice owned by ctx or by static storage.
    /// - **The callback runs on the main thread** (it is never called from a real-time callback).
    run: *const fn (ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8,
};

/// With no router set, `routeLocalAction` is exactly equivalent to `dispatch`.
pub const RouterFn = *const fn (name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8;

/// A callback that normalises a `.relay` action's wire arguments in the originator's context before they reach the router.
/// The return value may borrow `scratch` or static storage; the router consumes it synchronously.
pub const CanonicalizeFn = *const fn (ctx: *anyopaque, args: []const u8, scratch: []u8) anyerror![]const u8;

pub const MAX_ACTIONS = 48; // A fixed-size registry: registering beyond this limit is skipped with a warning.

var actions: [MAX_ACTIONS]Action = undefined;
var action_count: usize = 0;
var enabled: bool = false;
var router: ?RouterFn = null;

const MAX_DESC_LEN = 200;
const MAX_ARG_NAME_LEN = 32;
const MAX_ARG_KIND_LEN = 32;
const MAX_ARG_VALUE_LEN = 64;
const MAX_ARG_PATTERN_LEN = 100;

// ============================================================================
// structured error: an opt-in code plus a suggested_next_action when an action fails
//
// Module variables owned exclusively by the main thread. When a handler calls `setActionErrorDetail`
// just before returning an error, ` code=<c> next=<n>` is appended to the harness's or copilot's failure line. When it is
// not called, the wire is bit-identical to before (no code= or next= at all). The framework does not
// **interpret** the vocabulary of code or next (it only sanitises to protect the wire framing).
// ============================================================================

/// The wire limit on an error code (assumed to be a single token).
pub const MAX_ERROR_CODE_LEN = 64;
/// The wire limit on suggested_next_action (whitespace allowed; it is the last field on the line).
pub const MAX_ERROR_NEXT_LEN = 200;

var err_code_buf: [MAX_ERROR_CODE_LEN]u8 = undefined;
var err_code_len: usize = 0;
var err_next_buf: [MAX_ERROR_NEXT_LEN]u8 = undefined;
var err_next_len: usize = 0;
var err_detail_set: bool = false;

/// Framing protection: replaces control characters and `DEL` with `_`, and truncates to `out.len`.
/// With `collapse_ws=true`, ASCII whitespace (space included) also becomes `_` (a code is a single token).
/// With `collapse_ws=false`, spaces are kept (next may contain whitespace).
fn sanitizeErrorField(out: []u8, src: []const u8, comptime collapse_ws: bool) usize {
    const n = @min(src.len, out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = src[i];
        if (collapse_ws) {
            out[i] = if (c <= 0x20 or c == 0x7f) '_' else c;
        } else {
            out[i] = if (c < 0x20 or c == 0x7f) '_' else c;
        }
    }
    return n;
}

/// Clears the structured error (at the start of `dispatch`, and before copilot's direct run; framework internal).
pub fn clearActionErrorDetail() void {
    err_code_len = 0;
    err_next_len = 0;
    err_detail_set = false;
}

/// Sets the structured error for an action failure (application opt-in, main thread only).
/// It is cleared on every entry to `dispatch`, so call it **immediately before returning the error**.
/// Sanitising only protects the wire framing (the meaning is not interpreted): control characters become `_`, with limits of code=64B and next=200B.
pub fn setActionErrorDetail(code: []const u8, suggested_next_action: []const u8) void {
    err_code_len = sanitizeErrorField(&err_code_buf, code, true);
    err_next_len = sanitizeErrorField(&err_next_buf, suggested_next_action, false);
    err_detail_set = true;
}

/// The most recent structured error (null when none is set). A peek between `dispatch`'s clear and a set.
/// For formatting the harness's and copilot's wire only (an application does not normally use it).
pub fn actionErrorDetail() ?struct { code: []const u8, next: []const u8 } {
    if (!err_detail_set) return null;
    return .{
        .code = err_code_buf[0..err_code_len],
        .next = err_next_buf[0..err_next_len],
    };
}

fn containsUnsafeJsonChar(s: []const u8) bool {
    for (s) |c| {
        if (c == '"' or c == '\\' or c < 0x20) return true;
    }
    return false;
}

fn sanitizeDesc(name: []const u8, desc: []const u8) []const u8 {
    if (desc.len == 0) return desc;
    if (desc.len > MAX_DESC_LEN or containsUnsafeJsonChar(desc)) {
        std.debug.print("[action_registry] action desc for '{s}' was disabled (a forbidden character, or over 200 bytes)\n", .{name});
        return "";
    }
    return desc;
}

/// Sanitising an argument signature at registration.
/// Applies containsUnsafeJsonChar plus a length limit to name, kind, values[*], pattern and desc.
/// **On a violation it warns and drops args as a whole to null** (registration itself still succeeds — the same shape of fail-safe as emptying desc).
/// The framework does not interpret the meaning of a type (it only protects the wire framing).
fn sanitizeArgs(action_name: []const u8, args: ?[]const ArgSpec) ?[]const ArgSpec {
    const specs = args orelse return null;
    for (specs) |s| {
        // NaN and Inf cannot be emitted as a JSON number (they would break the always-valid-JSON contract), so they are rejected at registration
        if ((s.min != null and !std.math.isFinite(s.min.?)) or
            (s.max != null and !std.math.isFinite(s.max.?)))
        {
            std.debug.print("[action_registry] action args for '{s}' was disabled (min or max is not finite)\n", .{action_name});
            return null;
        }
        if (s.name.len > MAX_ARG_NAME_LEN or containsUnsafeJsonChar(s.name) or
            s.kind.len > MAX_ARG_KIND_LEN or containsUnsafeJsonChar(s.kind) or
            s.pattern.len > MAX_ARG_PATTERN_LEN or containsUnsafeJsonChar(s.pattern) or
            s.desc.len > MAX_DESC_LEN or containsUnsafeJsonChar(s.desc))
        {
            std.debug.print("[action_registry] action args for '{s}' was disabled (a forbidden character, or over the length limit)\n", .{action_name});
            return null;
        }
        for (s.values) |v| {
            if (v.len > MAX_ARG_VALUE_LEN or containsUnsafeJsonChar(v)) {
                std.debug.print("[action_registry] action args for '{s}' was disabled (a forbidden character, or over the length limit)\n", .{action_name});
                return null;
            }
        }
    }
    return specs;
}

fn isValidActionName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (std.ascii.isWhitespace(c) or c == ';') return false;
    }
    return true;
}

/// Opens the registration gate (an OR condition: `enabled = enabled or v`). `resetForTest` is the only way to clear it.
pub fn setEnabled(v: bool) void {
    enabled = enabled or v;
}

pub fn isEnabled() bool {
    return enabled;
}

/// Registers a custom action.
/// - When `enabled` is false this is a **no-op** (zero regression for a normal run).
/// - The same name overwrites. A name containing whitespace, `;` or a newline, and an empty name, are rejected.
/// - A full registry is skipped (with a warning).
pub fn registerAction(a: Action) void {
    if (!enabled) return;
    if (!isValidActionName(a.name)) {
        std.debug.print("[action_registry] registerAction: invalid name '{s}' (empty, whitespace, ';' and a newline are not allowed)\n", .{a.name});
        return;
    }
    for (actions[0..action_count]) |*existing| {
        if (std.mem.eql(u8, existing.name, a.name)) {
            var ma = a;
            ma.desc = sanitizeDesc(a.name, a.desc);
            ma.args = sanitizeArgs(a.name, a.args);
            existing.* = ma;
            return;
        }
    }
    if (action_count >= MAX_ACTIONS) {
        std.debug.print("[action_registry] registerAction: the registry is full ({d}); skipping '{s}'\n", .{ MAX_ACTIONS, a.name });
        return;
    }
    var ma = a;
    ma.desc = sanitizeDesc(a.name, a.desc);
    ma.args = sanitizeArgs(a.name, a.args);
    actions[action_count] = ma;
    action_count += 1;
}

/// Looks a registered custom action up by name.
pub fn findAction(name: []const u8) ?*Action {
    for (actions[0..action_count]) |*a| {
        if (std.mem.eql(u8, a.name, name)) return a;
    }
    return null;
}

/// A name lookup, then `run()`. An unknown action gives `error.UnknownAction`, and an error from `run()` passes straight through.
/// **The structured error is cleared every time** before `run` (which stops the previous detail from leaking).
pub fn dispatch(name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    clearActionErrorDetail();
    const act = findAction(name) orelse return error.UnknownAction;
    return act.run(act.ctx, args, buf);
}

/// Sets a router (netsync's, say). With none set, `routeLocalAction` is equivalent to `dispatch`.
/// Call it from the **main thread only** (harness handleAction, copilot pump, and netsync.shutdown and pump are all on main).
pub fn setRouter(r: ?RouterFn) void {
    router = r;
}

/// With a router set it delegates to the router; with none set it is exactly equivalent to `dispatch`.
/// **Main thread only** (harness `handleAction`, copilot pump). Reading router uses no synchronisation primitive
/// (the writer is main-thread-only too, and netsync.pump lifts a client's fail-soft on main).
/// The structured error is cleared on entry every time, so a previous detail cannot leak even down a path where the
/// router returns an error without reaching dispatch (the clear inside dispatch is idempotent).
pub fn routeLocalAction(name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    clearActionErrorDetail();
    const act = findAction(name);
    var routed_args = args;
    var scratch: [4096]u8 = undefined;
    if (act) |a| {
        if (a.network_policy == .relay) {
            if (a.canonicalize) |canonicalize| {
                routed_args = try canonicalize(a.ctx, args, &scratch);
            }
        }
    }
    if (router) |r| return r(name, routed_args, buf);
    return dispatch(name, routed_args, buf);
}

/// A reset for tests (count=0, enabled=false, router=null, and the error detail cleared).
pub fn resetForTest() void {
    action_count = 0;
    enabled = false;
    router = null;
    clearActionErrorDetail();
}

/// An iterator for the capabilities listing: how many are registered.
pub fn actionCount() usize {
    return action_count;
}

/// An iterator for the capabilities listing: the `i`th Action (null when out of range).
pub fn actionAt(i: usize) ?*const Action {
    if (i >= action_count) return null;
    return &actions[i];
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

const TestCtx = struct {
    calls: u32 = 0,
    last_args: [256]u8 = undefined,
    last_args_len: usize = 0,
};

fn testRun(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const c: *TestCtx = @ptrCast(@alignCast(ctx));
    c.calls += 1;
    const n = @min(args.len, c.last_args.len);
    @memcpy(c.last_args[0..n], args[0..n]);
    c.last_args_len = n;
    return std.fmt.bufPrint(buf, "ok {s}", .{args}) catch "ok";
}

fn testRunErr(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = ctx;
    _ = args;
    _ = buf;
    return error.Boom;
}

fn testRouter(name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    return std.fmt.bufPrint(buf, "routed:{s}:{s}", .{ name, args }) catch "routed";
}

fn testCanonicalize(ctx: *anyopaque, args: []const u8, scratch: []u8) anyerror![]const u8 {
    const c: *TestCtx = @ptrCast(@alignCast(ctx));
    _ = c;
    return std.fmt.bufPrint(scratch, "canonical:{s}", .{args}) catch error.TooLong;
}

test "action_registry: disabled no-op" {
    resetForTest();
    var c = TestCtx{};
    registerAction(.{ .name = "x", .ctx = &c, .run = testRun });
    try testing.expectEqual(@as(usize, 0), actionCount());
}

test "action_registry: a full registry is skipped, the same name overwrites, names are validated" {
    resetForTest();
    setEnabled(true);
    var c1 = TestCtx{};
    var c2 = TestCtx{};
    registerAction(.{ .name = "a", .ctx = &c1, .run = testRun });
    registerAction(.{ .name = "a", .ctx = &c2, .run = testRun });
    try testing.expectEqual(@as(usize, 1), actionCount());
    try testing.expectEqual(@as(*anyopaque, &c2), findAction("a").?.ctx);

    registerAction(.{ .name = "", .ctx = &c1, .run = testRun });
    registerAction(.{ .name = "b c", .ctx = &c1, .run = testRun });
    registerAction(.{ .name = "b;c", .ctx = &c1, .run = testRun });
    try testing.expectEqual(@as(usize, 1), actionCount());

    var name_bufs: [MAX_ACTIONS + 4][8]u8 = undefined;
    for (&name_bufs, 0..) |*nb, i| {
        const nm = std.fmt.bufPrint(nb, "act{d}", .{i}) catch unreachable;
        registerAction(.{ .name = nm, .ctx = &c1, .run = testRun });
    }
    try testing.expectEqual(@as(usize, MAX_ACTIONS), actionCount());
}

test "action_registry: switching the router (routeLocalAction, dispatch, UnknownAction)" {
    resetForTest();
    setEnabled(true);
    var c = TestCtx{};
    registerAction(.{ .name = "foo", .ctx = &c, .run = testRun });
    var buf: [64]u8 = undefined;

    const d = try dispatch("foo", "bar", &buf);
    try testing.expectEqualStrings("ok bar", d);
    try testing.expectError(error.UnknownAction, dispatch("nosuch", "", &buf));

    // with no router set it is equivalent to dispatch
    const r0 = try routeLocalAction("foo", "x", &buf);
    try testing.expectEqualStrings("ok x", r0);

    setRouter(testRouter);
    const r1 = try routeLocalAction("foo", "y", &buf);
    try testing.expectEqualStrings("routed:foo:y", r1);

    setRouter(null);
    const r2 = try routeLocalAction("foo", "z", &buf);
    try testing.expectEqualStrings("ok z", r2);
    try testing.expectEqual(@as(u32, 3), c.calls); // dispatch plus route×2 (going through the router does not call run)
}

test "action_registry: dispatch passes an error from run() through" {
    resetForTest();
    setEnabled(true);
    var c = TestCtx{};
    registerAction(.{ .name = "boom", .ctx = &c, .run = testRunErr });
    var buf: [32]u8 = undefined;
    try testing.expectError(error.Boom, dispatch("boom", "", &buf));
}

test "action_registry: setEnabled is an OR condition, false does not disable, resetForTest" {
    resetForTest();
    try testing.expect(!isEnabled());
    setEnabled(true);
    try testing.expect(isEnabled());
    setEnabled(false); // OR, so this does not disable it
    try testing.expect(isEnabled());

    var c = TestCtx{};
    registerAction(.{ .name = "keep", .ctx = &c, .run = testRun });
    try testing.expectEqual(@as(usize, 1), actionCount());

    resetForTest();
    try testing.expect(!isEnabled());
    try testing.expectEqual(@as(usize, 0), actionCount());
    try testing.expect(findAction("keep") == null);
}

test "action_registry: actionCount / actionAt iterator" {
    resetForTest();
    setEnabled(true);
    var c = TestCtx{};
    registerAction(.{ .name = "a1", .ctx = &c, .run = testRun, .desc = "d1" });
    registerAction(.{ .name = "a2", .ctx = &c, .run = testRun });
    try testing.expectEqual(@as(usize, 2), actionCount());
    try testing.expectEqualStrings("a1", actionAt(0).?.name);
    try testing.expectEqualStrings("d1", actionAt(0).?.desc);
    try testing.expectEqualStrings("a2", actionAt(1).?.name);
    try testing.expect(actionAt(2) == null);
}

test "action_registry: network_policy defaults to reject_when_synced" {
    resetForTest();
    setEnabled(true);
    var c = TestCtx{};
    registerAction(.{ .name = "n", .ctx = &c, .run = testRun });
    try testing.expectEqual(NetworkPolicy.reject_when_synced, findAction("n").?.network_policy);
    registerAction(.{ .name = "r", .ctx = &c, .run = testRun, .network_policy = .relay });
    try testing.expectEqual(NetworkPolicy.relay, findAction("r").?.network_policy);
    registerAction(.{ .name = "e", .ctx = &c, .run = testRun, .network_policy = .ephemeral });
    try testing.expectEqual(NetworkPolicy.ephemeral, findAction("e").?.network_policy);
}

test "action_registry: ephemeral reaches the router without being canonicalized" {
    resetForTest();
    setEnabled(true);
    var c = TestCtx{};
    registerAction(.{
        .name = "presence_point",
        .ctx = &c,
        .run = testRun,
        .network_policy = .ephemeral,
        .canonicalize = testCanonicalize,
    });
    setRouter(testRouter);
    var buf: [128]u8 = undefined;
    const out = try routeLocalAction("presence_point", "32 40", &buf);
    // ephemeral does not apply the canonicalize meant for relay
    try testing.expectEqualStrings("routed:presence_point:32 40", out);
}

test "action_registry: a relay's canonicalize is applied before the router" {
    resetForTest();
    setEnabled(true);
    var c = TestCtx{};
    registerAction(.{ .name = "stroke", .ctx = &c, .run = testRun, .network_policy = .relay, .canonicalize = testCanonicalize });
    setRouter(testRouter);
    var buf: [128]u8 = undefined;
    const out = try routeLocalAction("stroke", "1 2", &buf);
    try testing.expectEqualStrings("routed:stroke:canonical:1 2", out);
}

fn testRunSetDetail(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = ctx;
    _ = args;
    _ = buf;
    setActionErrorDetail("file_not_found", "check path or use save first");
    return error.Boom;
}

fn testRunSetDetailStale(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = ctx;
    _ = buf;
    // attach a detail only when args is "set" (to catch a regression in dispatch's clear)
    if (std.mem.eql(u8, args, "set")) {
        setActionErrorDetail("stale_code", "should not leak");
    }
    return error.Boom;
}

test "action_registry: setActionErrorDetail, null when unset, sanitising, next keeps whitespace" {
    resetForTest();
    try testing.expect(actionErrorDetail() == null);

    setActionErrorDetail("index_out_of_range", "use add_layer or 0..N-1");
    const d0 = actionErrorDetail().?;
    try testing.expectEqualStrings("index_out_of_range", d0.code);
    try testing.expectEqualStrings("use add_layer or 0..N-1", d0.next); // whitespace kept

    // code: whitespace and control characters → `_`, limit 64B. next: control characters only → `_`, limit 200B, spaces kept
    setActionErrorDetail("a b\nc\td", "go\nhere now");
    const d1 = actionErrorDetail().?;
    try testing.expectEqualStrings("a_b_c_d", d1.code);
    try testing.expectEqualStrings("go_here now", d1.next);

    var long_code: [80]u8 = undefined;
    @memset(&long_code, 'X');
    var long_next: [250]u8 = undefined;
    @memset(&long_next, 'y');
    setActionErrorDetail(&long_code, &long_next);
    const d2 = actionErrorDetail().?;
    try testing.expectEqual(@as(usize, MAX_ERROR_CODE_LEN), d2.code.len);
    try testing.expectEqual(@as(usize, MAX_ERROR_NEXT_LEN), d2.next.len);
}

test "action_registry: dispatch clears the error detail on entry (no leak from the previous one)" {
    resetForTest();
    setEnabled(true);
    var c = TestCtx{};
    registerAction(.{ .name = "boom", .ctx = &c, .run = testRunSetDetailStale });
    var buf: [32]u8 = undefined;

    try testing.expectError(error.Boom, dispatch("boom", "set", &buf));
    try testing.expect(actionErrorDetail() != null);
    try testing.expectEqualStrings("stale_code", actionErrorDetail().?.code);

    // the second time the handler does not set one, so dispatch's clear leaves the detail null
    try testing.expectError(error.Boom, dispatch("boom", "noset", &buf));
    try testing.expect(actionErrorDetail() == null);
}

test "action_registry: a detail set before a run error survives, for the wire formatter to read" {
    resetForTest();
    setEnabled(true);
    var c = TestCtx{};
    registerAction(.{ .name = "boom", .ctx = &c, .run = testRunSetDetail });
    var buf: [32]u8 = undefined;
    try testing.expectError(error.Boom, dispatch("boom", "", &buf));
    const d = actionErrorDetail().?;
    try testing.expectEqualStrings("file_not_found", d.code);
    try testing.expectEqualStrings("check path or use save first", d.next);
}

/// A fake router imitating a path that returns an error without reaching dispatch, as netsyncRouter's reject and unknown do.
fn testRouterFailNoDispatch(name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = name;
    _ = args;
    _ = buf;
    return error.UnknownAction;
}

test "action_registry: routeLocalAction clears the detail on entry, so a failure that never reaches the router leaks no previous code or next" {
    resetForTest();
    setEnabled(true);
    var c = TestCtx{};
    registerAction(.{ .name = "boom", .ctx = &c, .run = testRunSetDetail });
    var buf: [32]u8 = undefined;

    // the immediately preceding action fails with a detail attached
    try testing.expectError(error.Boom, dispatch("boom", "", &buf));
    try testing.expect(actionErrorDetail() != null);
    try testing.expectEqualStrings("file_not_found", actionErrorDetail().?.code);

    // a failure through the router that never reaches dispatch (an unknown action, in effect); the entry clear removes the previous detail
    setRouter(testRouterFailNoDispatch);
    try testing.expectError(error.UnknownAction, routeLocalAction("nosuch", "", &buf));
    try testing.expect(actionErrorDetail() == null);
}
