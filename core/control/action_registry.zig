//! Action registry（TASK-62.3.1）: harness から分離した custom action 登録簿。
//!
//! app が `platform.registerAction(...)` で高レベル操作を opt-in 登録し、harness / copilot /
//! netsync（62.3.2〜）が `dispatch` / `routeLocalAction` 経由で叩く。std のみ（harness/netsync
//! 非依存。ADR-007 core 層）。
//!
//! ## ホットパス宣言
//! イベント時のみ（action コマンド到着・register）。フレーム毎（全画素）/ RT（毎サンプル）には触れない。
//!
//! ## 有効化ゲート
//! `enabled` は OR 条件（`setEnabled(true)` のみ効く。無効化は `resetForTest` のみ）。
//! 呼び出し元: harness.startTransport / setExternalRegistryEnabled(true) / 将来 netsync。

const std = @import("std");

/// netsync 同時編集時の action 配送ポリシー（TASK-62.3）。既定は `.reject_when_synced`。
pub const NetworkPolicy = enum {
    /// host へ PROPOSE → COMMIT で全 peer に適用（62.3.2）。
    relay,
    /// 常にローカルのみ（例: save）。
    local_only,
    /// netsync session 中は拒否（既定。undo/layer 等）。
    reject_when_synced,
    /// 自分の commit だけを revert（62.3.5）。
    undo_own,
    /// 自分の revert を redo（62.3.5）。
    redo_own,
};

/// app が register する custom action。**framework は中身を解釈しない**（probe と同じ不変条件）:
/// `action <name> [args...]` の `<name>` 以降の残り行 raw テキストをそのまま `run` へ渡し、
/// 戻り値（1行）をそのまま既存 sink へ流すだけ。
pub const Action = struct {
    /// action 名（`action <name> ...` の引数。空白/`;`/改行を含む名前は登録できない）。
    name: []const u8,
    /// callback に渡す不透明コンテキスト（app の状態へのポインタ）。
    ctx: *anyopaque,
    /// capabilities 列挙用の説明文（省略可）。登録時に sanitize で禁止文字・200B 超を空文字化。
    desc: []const u8 = "",
    /// netsync 配送ポリシー（既定 `.reject_when_synced`。既存 registerAction 呼び出しは無改修）。
    network_policy: NetworkPolicy = .reject_when_synced,
    /// 操作を実行し結果1行を返す write callback。
    /// - `args` は `action <name>` の後の残り行 raw テキスト（trim 済み・再トークン化しない）。
    /// - 戻り値は改行を含めない1行。`buf` 内の slice か ctx/静的所有の一時 slice を返してよい。
    /// - **callback は main thread で実行される**（RT callback から呼ばれることは無い）。
    run: *const fn (ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8,
};

/// router 未設定時の `routeLocalAction` は `dispatch` と完全等価。
pub const RouterFn = *const fn (name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8;

pub const MAX_ACTIONS = 32; // TASK-62.5.3 で 16→32（pixie 登録超過の解消。62.3.1 で移送）

var actions: [MAX_ACTIONS]Action = undefined;
var action_count: usize = 0;
var enabled: bool = false;
var router: ?RouterFn = null;

const MAX_DESC_LEN = 200;

fn containsUnsafeJsonChar(s: []const u8) bool {
    for (s) |c| {
        if (c == '"' or c == '\\' or c < 0x20) return true;
    }
    return false;
}

fn sanitizeDesc(name: []const u8, desc: []const u8) []const u8 {
    if (desc.len == 0) return desc;
    if (desc.len > MAX_DESC_LEN or containsUnsafeJsonChar(desc)) {
        std.debug.print("[action_registry] action desc for '{s}' は無効化されました（禁止文字 or 200 bytes 超）\n", .{name});
        return "";
    }
    return desc;
}

fn isValidActionName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (std.ascii.isWhitespace(c) or c == ';') return false;
    }
    return true;
}

/// 登録ゲートを開く（OR 条件: `enabled = enabled or v`）。無効化は `resetForTest` のみ。
pub fn setEnabled(v: bool) void {
    enabled = enabled or v;
}

pub fn isEnabled() bool {
    return enabled;
}

/// custom action を登録する。
/// - `enabled` が false のときは **no-op**（通常実行の回帰ゼロ）。
/// - 同名は上書き。空白/`;`/改行を含む名前と空名は拒否。
/// - registry 満杯はスキップ（warn）。
pub fn registerAction(a: Action) void {
    if (!enabled) return;
    if (!isValidActionName(a.name)) {
        std.debug.print("[action_registry] registerAction: 不正な名前 '{s}'（空/空白/';'/改行 は不可）\n", .{a.name});
        return;
    }
    for (actions[0..action_count]) |*existing| {
        if (std.mem.eql(u8, existing.name, a.name)) {
            var ma = a;
            ma.desc = sanitizeDesc(a.name, a.desc);
            existing.* = ma;
            return;
        }
    }
    if (action_count >= MAX_ACTIONS) {
        std.debug.print("[action_registry] registerAction: registry 満杯（{d}）。'{s}' をスキップ\n", .{ MAX_ACTIONS, a.name });
        return;
    }
    var ma = a;
    ma.desc = sanitizeDesc(a.name, a.desc);
    actions[action_count] = ma;
    action_count += 1;
}

/// 登録済み custom action の name lookup。
pub fn findAction(name: []const u8) ?*Action {
    for (actions[0..action_count]) |*a| {
        if (std.mem.eql(u8, a.name, name)) return a;
    }
    return null;
}

/// name lookup → `run()`。未知 action は `error.UnknownAction`。`run()` のエラーはそのまま透過。
pub fn dispatch(name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    const act = findAction(name) orelse return error.UnknownAction;
    return act.run(act.ctx, args, buf);
}

/// netsync 等の router を設定する（未設定時 `routeLocalAction` は `dispatch` 等価）。
pub fn setRouter(r: ?RouterFn) void {
    router = r;
}

/// router 設定時は router へ委譲、未設定時は `dispatch` と完全等価。
pub fn routeLocalAction(name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    if (router) |r| return r(name, args, buf);
    return dispatch(name, args, buf);
}

/// テスト用リセット（count=0 / enabled=false / router=null）。
pub fn resetForTest() void {
    action_count = 0;
    enabled = false;
    router = null;
}

/// capabilities 列挙用 iterator: 登録件数。
pub fn actionCount() usize {
    return action_count;
}

/// capabilities 列挙用 iterator: `i` 番目の Action（範囲外は null）。
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

test "action_registry: disabled no-op" {
    resetForTest();
    var c = TestCtx{};
    registerAction(.{ .name = "x", .ctx = &c, .run = testRun });
    try testing.expectEqual(@as(usize, 0), actionCount());
}

test "action_registry: 満杯 skip / 同名上書き / 名前検証" {
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

test "action_registry: router 切替（routeLocalAction / dispatch / UnknownAction）" {
    resetForTest();
    setEnabled(true);
    var c = TestCtx{};
    registerAction(.{ .name = "foo", .ctx = &c, .run = testRun });
    var buf: [64]u8 = undefined;

    const d = try dispatch("foo", "bar", &buf);
    try testing.expectEqualStrings("ok bar", d);
    try testing.expectError(error.UnknownAction, dispatch("nosuch", "", &buf));

    // router 未設定時は dispatch 等価
    const r0 = try routeLocalAction("foo", "x", &buf);
    try testing.expectEqualStrings("ok x", r0);

    setRouter(testRouter);
    const r1 = try routeLocalAction("foo", "y", &buf);
    try testing.expectEqualStrings("routed:foo:y", r1);

    setRouter(null);
    const r2 = try routeLocalAction("foo", "z", &buf);
    try testing.expectEqualStrings("ok z", r2);
    try testing.expectEqual(@as(u32, 3), c.calls); // dispatch + route×2（router 経由は run を呼ばない）
}

test "action_registry: dispatch run() エラー透過" {
    resetForTest();
    setEnabled(true);
    var c = TestCtx{};
    registerAction(.{ .name = "boom", .ctx = &c, .run = testRunErr });
    var buf: [32]u8 = undefined;
    try testing.expectError(error.Boom, dispatch("boom", "", &buf));
}

test "action_registry: setEnabled OR 条件 / false は無効化しない / resetForTest" {
    resetForTest();
    try testing.expect(!isEnabled());
    setEnabled(true);
    try testing.expect(isEnabled());
    setEnabled(false); // OR なので無効化しない
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

test "action_registry: network_policy 既定は reject_when_synced" {
    resetForTest();
    setEnabled(true);
    var c = TestCtx{};
    registerAction(.{ .name = "n", .ctx = &c, .run = testRun });
    try testing.expectEqual(NetworkPolicy.reject_when_synced, findAction("n").?.network_policy);
    registerAction(.{ .name = "r", .ctx = &c, .run = testRun, .network_policy = .relay });
    try testing.expectEqual(NetworkPolicy.relay, findAction("r").?.network_policy);
}
