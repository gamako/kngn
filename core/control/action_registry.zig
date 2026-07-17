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
    /// ephemeral プレゼンス（TASK-103）。COMMIT/PROPOSE/seq を消費せず専用経路へ。
    ephemeral,
};

/// action/probe の引数シグネチャ 1 要素（TASK-88.1）。
/// **framework は転記のみ・意味を解釈しない**（kind の語彙検証も values の整合も行わない）。
/// スライス（name/kind/values/pattern/desc）は登録側が static lifetime を保証する（Action.name と同じ契約）。
///
/// kind は文字列（推奨語彙: "int"/"float"/"string"/"bool"/"enum"/"path"。app 独自 kind も可。
/// 未知 kind の解釈は消費側＝MCP の責務）。
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
    /// args シグネチャ（TASK-88.1。省略可・後方互換）。
    /// **null=未指定（従来どおり・JSON に args フィールド無し）/ 空 slice=「引数なし」を明示宣言**
    /// （MCP の fallback 判定に必要な区別。null と `[]` は JSON 上で異なる）。
    args: ?[]const ArgSpec = null,
    /// netsync 配送ポリシー（既定 `.reject_when_synced`。既存 registerAction 呼び出しは無改修）。
    network_policy: NetworkPolicy = .reject_when_synced,
    /// `.relay` の PROPOSE/ローカル適用前に引数を canonical 化する callback（省略可）。
    canonicalize: ?CanonicalizeFn = null,
    /// 操作を実行し結果1行を返す write callback。
    /// - `args` は `action <name>` の後の残り行 raw テキスト（trim 済み・再トークン化しない）。
    /// - 戻り値は改行を含めない1行。`buf` 内の slice か ctx/静的所有の一時 slice を返してよい。
    /// - **callback は main thread で実行される**（RT callback から呼ばれることは無い）。
    run: *const fn (ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8,
};

/// router 未設定時の `routeLocalAction` は `dispatch` と完全等価。
pub const RouterFn = *const fn (name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8;

/// `.relay` action の wire 引数を router へ渡す前に発信元の文脈で正規化する callback。
/// 戻り値は `scratch` または static storage を借用してよい。router は同期的に消費する。
pub const CanonicalizeFn = *const fn (ctx: *anyopaque, args: []const u8, scratch: []u8) anyerror![]const u8;

pub const MAX_ACTIONS = 48; // TASK-90 で 32→48（pixie 31 件で満杯目前の解消）。以前: TASK-62.5.3 で 16→32

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
// structured error（TASK-62.5.9）: action 失敗時の opt-in code + suggested_next_action
//
// main thread 専有の module 変数。handler がエラー return 直前に `setActionErrorDetail` を
// 呼ぶと、harness/copilot の失敗行末尾に ` code=<c> next=<n>` が追記される。未呼び出し時は
// 従来 wire と bit 一致（code=/next= を一切付けない）。framework は code/next の語彙を
// **解釈しない**（wire framing 保護の sanitize のみ）。
// ============================================================================

/// error code の wire 上限（1 トークン想定）。
pub const MAX_ERROR_CODE_LEN = 64;
/// suggested_next_action の wire 上限（空白可・行末最終フィールド）。
pub const MAX_ERROR_NEXT_LEN = 200;

var err_code_buf: [MAX_ERROR_CODE_LEN]u8 = undefined;
var err_code_len: usize = 0;
var err_next_buf: [MAX_ERROR_NEXT_LEN]u8 = undefined;
var err_next_len: usize = 0;
var err_detail_set: bool = false;

/// framing 保護: 制御文字/`DEL` を `_` に置換し `out.len` で切り詰める。
/// `collapse_ws=true` のとき ASCII whitespace（space 含む）も `_`（code は 1 トークン）。
/// `collapse_ws=false` のとき space は保持（next は空白可）。
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

/// structured error をクリアする（`dispatch` 開始時 / copilot の direct-run 前。framework 内部用）。
pub fn clearActionErrorDetail() void {
    err_code_len = 0;
    err_next_len = 0;
    err_detail_set = false;
}

/// action 失敗の構造化エラーをセットする（app opt-in・main thread のみ）。
/// `dispatch` 開始時に毎回クリアされるので、**エラー return の直前**に呼ぶ。
/// sanitize は wire framing 保護のみ（意味は非解釈）: 制御文字→`_`、上限 code=64B / next=200B。
pub fn setActionErrorDetail(code: []const u8, suggested_next_action: []const u8) void {
    err_code_len = sanitizeErrorField(&err_code_buf, code, true);
    err_next_len = sanitizeErrorField(&err_next_buf, suggested_next_action, false);
    err_detail_set = true;
}

/// 直近の structured error（未セットなら null）。`dispatch` クリア〜set までの peek。
/// harness/copilot の wire 整形専用（app は通常使わない）。
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
        std.debug.print("[action_registry] action desc for '{s}' は無効化されました（禁止文字 or 200 bytes 超）\n", .{name});
        return "";
    }
    return desc;
}

/// args シグネチャの登録時サニタイズ（TASK-88.1）。
/// name/kind/values[*]/pattern/desc に containsUnsafeJsonChar + 長さ上限を適用。
/// **違反時は warn + args 全体を null に落とす**（登録自体は成功。desc の空文字化と同型のフェイルセーフ）。
/// framework は型の意味を解釈しない（wire framing 保護のみ）。
fn sanitizeArgs(action_name: []const u8, args: ?[]const ArgSpec) ?[]const ArgSpec {
    const specs = args orelse return null;
    for (specs) |s| {
        // NaN/Inf は JSON 数値として emit できない（常に valid JSON の契約を壊す）ため登録時に拒否
        if ((s.min != null and !std.math.isFinite(s.min.?)) or
            (s.max != null and !std.math.isFinite(s.max.?)))
        {
            std.debug.print("[action_registry] action args for '{s}' は無効化されました（min/max が非有限）\n", .{action_name});
            return null;
        }
        if (s.name.len > MAX_ARG_NAME_LEN or containsUnsafeJsonChar(s.name) or
            s.kind.len > MAX_ARG_KIND_LEN or containsUnsafeJsonChar(s.kind) or
            s.pattern.len > MAX_ARG_PATTERN_LEN or containsUnsafeJsonChar(s.pattern) or
            s.desc.len > MAX_DESC_LEN or containsUnsafeJsonChar(s.desc))
        {
            std.debug.print("[action_registry] action args for '{s}' は無効化されました（禁止文字 or 長さ上限超過）\n", .{action_name});
            return null;
        }
        for (s.values) |v| {
            if (v.len > MAX_ARG_VALUE_LEN or containsUnsafeJsonChar(v)) {
                std.debug.print("[action_registry] action args for '{s}' は無効化されました（禁止文字 or 長さ上限超過）\n", .{action_name});
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
            ma.args = sanitizeArgs(a.name, a.args);
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
    ma.args = sanitizeArgs(a.name, a.args);
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
/// **structured error は毎回クリア**してから `run` する（前回 detail の漏れを防ぐ。TASK-62.5.9）。
pub fn dispatch(name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    clearActionErrorDetail();
    const act = findAction(name) orelse return error.UnknownAction;
    return act.run(act.ctx, args, buf);
}

/// netsync 等の router を設定する（未設定時 `routeLocalAction` は `dispatch` 等価）。
/// **main thread のみ**から呼ぶ（harness handleAction / copilot pump / netsync.shutdown・pump も main）。
pub fn setRouter(r: ?RouterFn) void {
    router = r;
}

/// router 設定時は router へ委譲、未設定時は `dispatch` と完全等価。
/// **main thread のみ**（harness `handleAction` / copilot pump）。router 読みは同期プリミティブ無し
/// （書き手も main thread のみ。client fail-soft の解除は netsync.pump が main で行う）。
/// structured error は入口で毎回クリア（router が dispatch に到達せずエラーを返す経路でも
/// 前回 detail が漏れない。TASK-62.5.9 P1。dispatch 内クリアは冪等）。
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

/// テスト用リセット（count=0 / enabled=false / router=null / error detail クリア）。
pub fn resetForTest() void {
    action_count = 0;
    enabled = false;
    router = null;
    clearActionErrorDetail();
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
    registerAction(.{ .name = "e", .ctx = &c, .run = testRun, .network_policy = .ephemeral });
    try testing.expectEqual(NetworkPolicy.ephemeral, findAction("e").?.network_policy);
}

test "action_registry: ephemeral は canonicalize せず router へ到達する" {
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
    // ephemeral は relay 用 canonicalize を適用しない
    try testing.expectEqualStrings("routed:presence_point:32 40", out);
}

test "action_registry: relay の canonicalize は router 前に適用される" {
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
    // args が "set" のときだけ detail を載せる（dispatch クリアの回帰確認用）
    if (std.mem.eql(u8, args, "set")) {
        setActionErrorDetail("stale_code", "should not leak");
    }
    return error.Boom;
}

test "action_registry: setActionErrorDetail / 未セットは null / sanitize / next 空白保持" {
    resetForTest();
    try testing.expect(actionErrorDetail() == null);

    setActionErrorDetail("index_out_of_range", "use add_layer or 0..N-1");
    const d0 = actionErrorDetail().?;
    try testing.expectEqualStrings("index_out_of_range", d0.code);
    try testing.expectEqualStrings("use add_layer or 0..N-1", d0.next); // 空白保持

    // code: whitespace/制御 → `_`、上限 64B。next: 制御のみ `_`、上限 200B、space 保持
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

test "action_registry: dispatch 開始時に error detail をクリア（前回漏れ防止）" {
    resetForTest();
    setEnabled(true);
    var c = TestCtx{};
    registerAction(.{ .name = "boom", .ctx = &c, .run = testRunSetDetailStale });
    var buf: [32]u8 = undefined;

    try testing.expectError(error.Boom, dispatch("boom", "set", &buf));
    try testing.expect(actionErrorDetail() != null);
    try testing.expectEqualStrings("stale_code", actionErrorDetail().?.code);

    // 2 回目: handler は set しない → dispatch がクリアするので detail は null
    try testing.expectError(error.Boom, dispatch("boom", "noset", &buf));
    try testing.expect(actionErrorDetail() == null);
}

test "action_registry: dispatch run エラー後も set 済み detail が残る（wire 整形側が読む）" {
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

/// netsyncRouter の reject/unknown 等、dispatch 非到達でエラーを返す経路を模した偽 router。
fn testRouterFailNoDispatch(name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = name;
    _ = args;
    _ = buf;
    return error.UnknownAction;
}

test "action_registry: routeLocalAction 入口で detail クリア（router 非到達失敗に前回 code/next が漏れない）" {
    resetForTest();
    setEnabled(true);
    var c = TestCtx{};
    registerAction(.{ .name = "boom", .ctx = &c, .run = testRunSetDetail });
    var buf: [32]u8 = undefined;

    // 直前 action が detail 付きで失敗
    try testing.expectError(error.Boom, dispatch("boom", "", &buf));
    try testing.expect(actionErrorDetail() != null);
    try testing.expectEqualStrings("file_not_found", actionErrorDetail().?.code);

    // router 経由で dispatch 非到達の失敗（未知 action 相当）→ 入口 clear で前回 detail が消える
    setRouter(testRouterFailNoDispatch);
    try testing.expectError(error.UnknownAction, routeLocalAction("nosuch", "", &buf));
    try testing.expect(actionErrorDetail() == null);
}
