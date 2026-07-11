//! copilot/assist transport（TASK-62.5.2）: 通常 UX と共存する第3の control-plane。
//!
//! `VP_COPILOT_*` opt-in で TCP loopback に listen し、agent が probe で observe / action で
//! operate できる。harness live（検証専用・step gate でアプリを止める）と異なり **step gate を
//! 持ち込まない**: コマンドは毎フレームの `pump()` が非ブロッキングで処理し、ユーザーの通常操作と
//! agent 操作が同一セッションで混在する。operate は `CommandExecutor`（command.zig, TASK-62.5.1）を
//! 通り `actor=local_agent` で CommandRecord に記録される。
//!
//! ## ホットパス宣言
//! copilot transport は**イベント時 + フレーム毎 O(1)**: `pump()` を facade の `pollEvents` から
//! 毎フレーム呼ぶが、idle 時は非ブロッキング poll 1 回（syscall 1 発・alloc なし・全画素/毎サンプル
//! 処理なし）で即帰る。コマンド処理（digest/snapshot/action/tx）はコマンド到着時のみ。RT 経路には
//! 一切触れない。SIMD 3点セット・bench 対象外。**env 未設定時は pump が bool 1 個の early return**
//! （既存挙動への回帰ゼロ）。
//!
//! ## 依存方向（一方向）
//! copilot.zig → harness.zig（registry アクセサ / capabilities）+ command.zig（executor）。
//! harness.zig 側の copilot への参照は namespace 再エクスポート 1 行のみで、harness から copilot の
//! 関数は呼ばない。
//!
//! ## 排他（1 プロセス 1 control transport）
//! `VP_HARNESS_*`（SCRIPT/LIVE/PORT/HEADLESS）の env が存在すれば `VP_COPILOT_*` は warn して無視
//! （判定は env 存在ベースで `parseConfig()` 時点に確定・決定論。harness の listen 成否には依存しない）。
//!
//! ## 接続モデル（非ブロッキング state machine）
//! harness live と同じ「1 接続 = 1 リクエスト（`;`/改行区切り・client half-close で確定）= 1 レスポンス」
//! で `scripts/drive` がそのまま使える（wire 互換）。fd は OS レベル nonblocking。read/execute/send の
//! 全フェーズがフレームを跨いで進行し、main loop を block しない（詳細は `ConnState` と `pump()`）。

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const harness = @import("harness.zig");
const command = @import("command.zig");

const net = std.Io.net;
const gpa = std.heap.page_allocator;

/// リクエスト / レスポンスの wire 上限（各 64 KiB）。超過リクエストは error 応答、
/// 超過レスポンスは打ち切り + `error: response truncated` 行。
pub const MAX_WIRE = 64 * 1024;
/// 1 pump（フレーム）あたりのコマンド実行 budget。64 KiB に大量のコマンドを詰められても
/// 1 フレームを占有しない（残りは次フレームへ持ち越し）。
pub const CMD_BUDGET = 16;
/// 接続 deadline（フレーム数。60fps で約 30 秒）。read〜send が完了しない slow client を close して
/// 単一接続モデルの永久占有を防ぐ（時刻 syscall は使わない）。
pub const DEADLINE_FRAMES = 1800;
/// 1 pump あたりの read チャンク上限（高速に流し込む client でも 1 フレームを占有しない）。
const READ_CHUNKS_PER_PUMP = 16;
const TRUNCATED_LINE = "error: response truncated\n";

// ============================================================================
// module 状態（enabled 時のみ touch。env 未設定の通常実行では一切使われない）
// ============================================================================

var config_parsed = false;
var transport_started = false;
/// parseConfig で確定する「listen を試みる」フラグ（排他判定込み）。
var enabled_pending = false;
/// listen 成功後に立つ有効フラグ。`pump()` の early return 判定。
var enabled = false;
var req_port: u16 = 0;
/// netsync session 中は operate（action / tx 制御）を拒否する（observe は可。TASK-62.5 親 plan §6）。
var netsync_active = false;

var io_inited = false;
var threaded: std.Io.Threaded = undefined;
var io_val: std.Io = undefined;

var server: net.Server = undefined;

var conn_active = false;
var conn_fd: net.Socket.Handle = undefined;
var conn: ConnState = undefined;

/// operate の記録先（TASK-62.5.1 の consumer 第1号）。BSS 固定容量で enabled 時のみ touch。
var command_log: command.CommandLog = undefined;
var executor: command.Executor = undefined;
/// wire の begin_tx/end_tx/cancel_tx が管理する open transaction（同時 1 個）。
var open_tx: ?command.TransactionHandle = null;
/// app 所有の共有 executor（TASK-62.5.3）。設定時は own executor/log を使わない:
/// - `action` は harness.findAction の run を**直接呼ぶ**（記録は app 側 wrapper が一元化。
///   own-executor 経由だと app wrapper の executeAction と二重記録になり、同一 executor なら
///   ReentrantDispatch になるため）。
/// - `begin_tx`/`end_tx`/`cancel_tx` は共有 executor に対して actor=.local_agent で操作する
///   （app wrapper が `openTransactionFor(.local_agent)` で自動参加する）。
/// 未設定（null）時は 62.5.2 の挙動（own executor + own log）を完全維持。
var shared_executor: ?*command.Executor = null;

/// 共有 executor を設定する（facade の `platform.setCommandExecutor` から委譲される。
/// harness/copilot 無効時も呼んでよい no-op 規約 = module 変数の代入のみ）。
pub fn setSharedExecutor(exec: ?*command.Executor) void {
    shared_executor = exec;
}

/// operate（action/tx 制御）の対象 executor（共有 executor 優先）。
fn targetExecutor() *command.Executor {
    return shared_executor orelse &executor;
}

/// capabilities JSON の組み立て先（harness の capabilities_buf と同型の再利用スクラッチ）。
var caps_buf: [16 * 1024]u8 = undefined;

pub fn isEnabled() bool {
    return enabled;
}

/// netsync session の operate 拒否フラグ（platform が `netsync.setSessionStateCallback` で配線。TASK-62.5.6）。
pub fn setNetsyncSessionActive(active: bool) void {
    netsync_active = active;
}

// ============================================================================
// lifecycle（platform.init/shutdown から呼ばれる。§3b の順序）
// ============================================================================

/// 排他の純粋判定（env I/O から分離。単体テスト用）: harness の env が 1 つでも存在すれば
/// copilot は無効（1 プロセス 1 control transport）。
fn decideEnabled(requested: bool, harness_env_present: bool) bool {
    return requested and !harness_env_present;
}

/// platform.init() が `harness.parseConfig()` の後に 1 度だけ呼ぶ。env を読むだけで
/// I/O 副作用（listen/alloc/thread）は起こさない（AC #2）。
pub fn parseConfig() void {
    if (config_parsed) return;
    config_parsed = true;

    const requested = getEnv("VP_COPILOT") != null or getEnv("VP_COPILOT_PORT") != null;
    if (!requested) return;

    const harness_env_present = getEnv("VP_HARNESS_SCRIPT") != null or
        getEnv("VP_HARNESS_LIVE") != null or
        getEnv("VP_HARNESS_PORT") != null or
        getEnv("VP_HARNESS_HEADLESS") != null;
    if (!decideEnabled(requested, harness_env_present)) {
        std.debug.print("[copilot] VP_HARNESS_* が有効なため VP_COPILOT_* を無視します（1プロセス1 control transport）\n", .{});
        return;
    }
    if (comptime builtin.os.tag == .windows) {
        std.debug.print("[copilot] Windows では copilot transport は未対応です。VP_COPILOT_* を無視します\n", .{});
        return;
    }
    if (getEnv("VP_COPILOT_PORT")) |pe| req_port = std.fmt.parseInt(u16, pe, 10) catch 0;
    enabled_pending = true;
}

/// platform.init() が `harness.startTransport()` の後に 1 度だけ呼ぶ。listen 成功時のみ
/// enabled 確定 + registry OR ゲートを開く。listen 失敗は warn + disabled（起動は継続）。
pub fn startTransport() void {
    if (comptime builtin.os.tag != .windows) startTransportPosix();
}

fn startTransportPosix() void {
    if (transport_started) return;
    transport_started = true;
    if (!enabled_pending) return;

    ensureIo();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(req_port) };
    server = addr.listen(io_val, .{ .reuse_address = true }) catch |err| {
        std.debug.print("[copilot] listen 失敗: {s}（copilot 無効のまま起動継続）\n", .{@errorName(err)});
        return;
    };
    if (!setNonblocking(server.socket.handle)) {
        std.debug.print("[copilot] listener の nonblocking 設定に失敗。copilot を無効化します\n", .{});
        server.deinit(io_val);
        return;
    }
    initExecutorState();
    harness.setExternalRegistryEnabled(true);
    enabled = true;
    const chosen = server.socket.address.getPort();
    std.debug.print("[copilot] 有効: 127.0.0.1:{d}\n", .{chosen});
    writePortFile(chosen);
}

/// platform.shutdown() が呼ぶ。接続中 stream を close（送信途中の応答は破棄）→ listener close →
/// enabled=false。
pub fn stopTransport() void {
    if (comptime builtin.os.tag != .windows) stopTransportPosix();
}

fn stopTransportPosix() void {
    if (!enabled) return;
    if (conn_active) {
        closeConn();
    }
    server.deinit(io_val);
    enabled = false;
}

fn ensureIo() void {
    if (io_inited) return;
    io_inited = true;
    threaded = std.Io.Threaded.init(gpa, .{});
    io_val = threaded.io();
}

fn initExecutorState() void {
    command_log = .{};
    executor = command.Executor.init(.{ .ctx = undefined, .run = dispatchHarnessAction });
    executor.log = &command_log;
    open_tx = null;
}

/// executor の Dispatcher: harness action registry の name lookup → run() 委譲
/// （framework は args も戻り値も解釈しない）。
/// structured error は `action_registry.dispatch` と同様、run 前に毎回クリアする（TASK-62.5.9）。
fn dispatchHarnessAction(ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = ctx;
    harness.action_registry.clearActionErrorDetail();
    const act = harness.findAction(name) orelse return error.UnknownAction;
    return act.run(act.ctx, args, buf);
}

fn writePortFile(port: u16) void {
    const path = getEnv("VP_COPILOT_PORT_FILE") orelse return; // 省略時は stderr 表示のみ
    var pbuf: [16]u8 = undefined;
    const txt = std.fmt.bufPrint(&pbuf, "{d}\n", .{port}) catch return;
    std.Io.Dir.cwd().writeFile(io_val, .{ .sub_path = path, .data = txt }) catch |err| {
        std.debug.print("[copilot] port file 書き込み失敗 {s}: {s}\n", .{ path, @errorName(err) });
    };
}

/// 環境変数を読む（harness と同じく libc getenv。platform module は常に link_libc）。
fn getEnv(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

// ============================================================================
// pump（毎フレーム。facade の Window.pollEvents 末尾から呼ばれる）
// ============================================================================

/// フレーム毎に 1 回呼ぶ。disabled なら bool 1 個の early return（回帰ゼロ）。
/// 1 pump の仕事量上限: accept 1 回 + read 16 チャンク + コマンド 16 個 + 書ける分の send。
pub fn pump() void {
    if (!enabled) return;
    if (comptime builtin.os.tag != .windows) pumpPosix();
}

fn pumpPosix() void {
    if (!conn_active) {
        if (!fdReadable(server.socket.handle)) return;
        const fd = tryAccept() orelse return;
        if (!setNonblocking(fd)) {
            std.debug.print("[copilot] accepted fd の nonblocking 設定に失敗。接続を破棄します\n", .{});
            io_val.vtable.netClose(io_val.userdata, (&fd)[0..1]);
            return;
        }
        conn_fd = fd;
        conn.reset();
        conn_active = true;
    }

    if (!conn.tickFrame()) {
        std.debug.print("[copilot] 接続 deadline 超過（{d} frames）。close します\n", .{DEADLINE_FRAMES});
        closeConn();
        return;
    }

    if (conn.phase == .reading) pumpRead();
    if (conn_active and conn.phase == .executing) conn.executeBudget();
    if (conn_active and conn.phase == .sending) pumpSend();
}

fn closeConn() void {
    io_val.vtable.netClose(io_val.userdata, (&conn_fd)[0..1]);
    conn_active = false;
}

/// listener/接続 fd の readable 判定（timeout=0 の非ブロッキング poll 1 回）。
fn fdReadable(fd: net.Socket.Handle) bool {
    var pfds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP, .revents = 0 }};
    const n = posix.poll(&pfds, 0) catch return false;
    if (n == 0) return false;
    // POLLHUP は half-close 後の残データ読み取りに使う（read を尽くして read==0 で確定。§4 v1.3）。
    return pfds[0].revents & (posix.POLL.IN | posix.POLL.HUP) != 0;
}

/// 非ブロッキング accept（EAGAIN/EINTR は「このフレームでは進捗なし」= null。§4: EINTR も
/// 同一 pump 内でリトライせず次フレームへ持ち越す＝signal 連打でフレームを占有しない。
/// listener が nonblocking なので poll→accept 間で接続が消えても block しない）。
fn tryAccept() ?net.Socket.Handle {
    const rc = std.c.accept(server.socket.handle, null, null);
    switch (posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .INTR, .AGAIN => return null,
        else => |e| {
            std.debug.print("[copilot] accept 失敗: {s}\n", .{@tagName(e)});
            return null;
        },
    }
}

/// fd を OS レベル nonblocking にする。失敗（F_GETFL/F_SETFL）は false（呼び出し側が
/// listener なら transport 無効化・accepted fd なら接続破棄する。blocking fd のまま
/// 進めると poll(0) 判定だけに頼る形になり §4 の非ブロッキング契約が崩れるため黙殺しない）。
fn setNonblocking(fd: net.Socket.Handle) bool {
    const fl = std.c.fcntl(fd, posix.F.GETFL, @as(c_int, 0));
    if (fl < 0) return false;
    const nonblock: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    return std.c.fcntl(fd, posix.F.SETFL, fl | nonblock) >= 0;
}

/// 読める分だけ読む（nonblocking read。EAGAIN/EINTR=このフレームは進捗なし・次フレームへ持ち越し /
/// read==0=half-close で確定）。raw `std.c.read` を使うのは、`posix.read` が EINTR を内部で
/// 無制限リトライするため（§4: 同一 pump 内で無制限ループしない契約に揃える）。
///
/// HUP の優先順（§4 v1.3）の担保: `fdReadable` が POLLIN|POLLHUP どちらでも true を返し、close の
/// 判定はこの関数の **read の結果のみ**（read==0 かつ `finishRead()==false`=データ無し、または
/// read エラー）で行う。POLLHUP ビットを見て直接 close する分岐は存在しないため、half-close 直後に
/// 未読データと HUP が同時に届いても、まず read を尽くして正常 request として実行される。
fn pumpRead() void {
    var chunks: usize = 0;
    var rbuf: [4096]u8 = undefined;
    while (chunks < READ_CHUNKS_PER_PUMP) : (chunks += 1) {
        const rc = std.c.read(conn_fd, &rbuf, rbuf.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) {
                    // half-close = リクエスト確定。データ無し HUP は応答なしで close（§4 v1.3）。
                    if (!conn.finishRead()) closeConn();
                    return;
                }
                conn.feed(rbuf[0..n]);
            },
            .INTR, .AGAIN => return, // 次フレームへ持ち越し
            else => {
                closeConn(); // read エラーは接続 close + 状態リセット
                return;
            },
        }
    }
}

/// 書ける分だけ送る（nonblocking send。読み取らない client が main thread を止めない。
/// EAGAIN/EINTR はともに「このフレームでは進捗なし」= 次フレームへ持ち越し。§4）。
fn pumpSend() void {
    while (conn.sent < conn.resp_len) {
        const rc = std.c.send(conn_fd, conn.resp[conn.sent..].ptr, conn.resp_len - conn.sent, posix.MSG.NOSIGNAL);
        switch (posix.errno(rc)) {
            .SUCCESS => conn.sent += @intCast(rc),
            .INTR, .AGAIN => return, // 次フレームへ持ち越し
            else => {
                closeConn(); // send 中の HUP/エラーは close
                return;
            },
        }
    }
    closeConn(); // 送り切ったら close（1 接続 = 1 レスポンス）
}

// ============================================================================
// ConnState（バイト列 state machine。fd から分離して socket 非依存で単体テスト可能）
// ============================================================================

pub const Phase = enum { reading, executing, sending };

/// 1 接続分の request/response 状態。read（feed/finishRead）→ execute（executeBudget）→
/// send（transport 側が resp[sent..resp_len] を送る）の 3 フェーズをフレームを跨いで進める。
pub const ConnState = struct {
    phase: Phase = .reading,
    req: [MAX_WIRE]u8 = undefined,
    req_len: usize = 0,
    req_overflow: bool = false,
    /// コマンド実行カーソル（budget 持ち越しの再開点）。
    cursor: usize = 0,
    resp: [MAX_WIRE]u8 = undefined,
    resp_len: usize = 0,
    resp_truncated: bool = false,
    /// 送信済みバイト数（transport 側が進める）。
    sent: usize = 0,
    frames_alive: u32 = 0,

    /// 固定長配列には触れずスカラーのみ初期化する（接続ごとの 128 KiB memset を避ける）。
    pub fn reset(self: *ConnState) void {
        self.phase = .reading;
        self.req_len = 0;
        self.req_overflow = false;
        self.cursor = 0;
        self.resp_len = 0;
        self.resp_truncated = false;
        self.sent = 0;
        self.frames_alive = 0;
    }

    /// 受信バイトを蓄積する（上限 MAX_WIRE。超過は overflow フラグ + 以降の read 破棄）。
    pub fn feed(self: *ConnState, bytes: []const u8) void {
        if (self.phase != .reading or self.req_overflow) return;
        if (self.req_len + bytes.len > MAX_WIRE) {
            self.req_overflow = true;
            return;
        }
        @memcpy(self.req[self.req_len..][0..bytes.len], bytes);
        self.req_len += bytes.len;
    }

    /// half-close（read==0）でリクエスト確定。戻り値 false = データ無し HUP（応答なしで close してよい）。
    /// 上限超過は実行せず error 応答のみ（send フェーズへ直行）。
    pub fn finishRead(self: *ConnState) bool {
        if (self.phase != .reading) return true;
        if (self.req_overflow) {
            self.appendResp("error: request too large\n");
            self.beginSend();
            return true;
        }
        if (self.req_len == 0) return false;
        self.phase = .executing;
        return true;
    }

    /// 接続フレームカウンタ。deadline 超過で false（呼び出し側が close する）。
    pub fn tickFrame(self: *ConnState) bool {
        self.frames_alive += 1;
        return self.frames_alive <= DEADLINE_FRAMES;
    }

    /// 1 pump あたり最大 CMD_BUDGET 個のコマンドを実行する。全消化で send フェーズへ。
    pub fn executeBudget(self: *ConnState) void {
        if (self.phase != .executing) return;
        var executed: usize = 0;
        while (executed < CMD_BUDGET) {
            const raw = self.nextLine() orelse {
                self.beginSend();
                return;
            };
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            executeCommand(self, line);
            executed += 1;
        }
        // budget 消化。残りは次フレームへ持ち越し（phase は .executing のまま）
    }

    /// 次のコマンド片を返す（区切りは改行または `;`。harness のコマンド言語と同じ）。尽きたら null。
    fn nextLine(self: *ConnState) ?[]const u8 {
        if (self.cursor >= self.req_len) return null;
        const start = self.cursor;
        var end = start;
        while (end < self.req_len and self.req[end] != '\n' and self.req[end] != ';') end += 1;
        self.cursor = end + 1;
        return self.req[start..end];
    }

    /// レスポンス追記（上限 MAX_WIRE - truncated 行の予約。超過分は打ち切り + フラグ）。
    fn appendResp(self: *ConnState, s: []const u8) void {
        if (self.resp_truncated) return;
        const limit = MAX_WIRE - TRUNCATED_LINE.len;
        if (self.resp_len + s.len > limit) {
            self.resp_truncated = true;
            return;
        }
        @memcpy(self.resp[self.resp_len..][0..s.len], s);
        self.resp_len += s.len;
    }

    fn beginSend(self: *ConnState) void {
        if (self.resp_truncated) {
            // appendResp が TRUNCATED_LINE.len 分を常に予約しているので必ず入る
            @memcpy(self.resp[self.resp_len..][0..TRUNCATED_LINE.len], TRUNCATED_LINE);
            self.resp_len += TRUNCATED_LINE.len;
        }
        self.phase = .sending;
    }
};

// ============================================================================
// コマンド言語（harness のサブセット + transaction 制御。§5）
//   observe: digest <probe> / snapshot <probe> <path>   … 失敗は `error: <reason>` 行
//   operate: action <name> [args...] / begin_tx [label] / end_tx / cancel_tx
//            … 成功 `<name> <msg>` / `ok tx=<id>` / `ok`、失敗 `fail <name> <reason>` 行
// ============================================================================

fn executeCommand(conn_state: *ConnState, line: []const u8) void {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const cmd = it.next() orelse return;
    if (std.mem.eql(u8, cmd, "digest")) {
        handleDigestCmd(conn_state, &it);
    } else if (std.mem.eql(u8, cmd, "snapshot")) {
        handleSnapshotCmd(conn_state, &it);
    } else if (std.mem.eql(u8, cmd, "action")) {
        handleActionCmd(conn_state, &it);
    } else if (std.mem.eql(u8, cmd, "begin_tx")) {
        handleBeginTx(conn_state, &it);
    } else if (std.mem.eql(u8, cmd, "end_tx")) {
        handleEndTx(conn_state);
    } else if (std.mem.eql(u8, cmd, "cancel_tx")) {
        handleCancelTx(conn_state);
    } else if (std.mem.eql(u8, cmd, "quit")) {
        // アプリ寿命の所有者は人間（harness=検証との分界）
        failResp(conn_state, "quit", "unsupported (app lifetime is owned by the user)");
    } else {
        failResp(conn_state, cmd, "unknown command");
    }
}

/// 組み込み probe のうち copilot 非公開のもの（fb 捕捉の per-frame memcpy 等を通常 UX に足さない。
/// 観察は custom probe + capabilities で足りる。将来 additive に拡張可）。
fn isCopilotUnavailableBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "fb") or std.mem.eql(u8, name, "audio") or std.mem.eql(u8, name, "stats") or
        std.mem.eql(u8, name, "capture") or std.mem.eql(u8, name, "gamepad");
}

fn errorResp(conn_state: *ConnState, reason: []const u8) void {
    conn_state.appendResp("error: ");
    conn_state.appendResp(reason);
    conn_state.appendResp("\n");
}

fn failResp(conn_state: *ConnState, name: []const u8, reason: []const u8) void {
    failRespEx(conn_state, name, reason, false);
}

/// action run 失敗専用: app が `setActionErrorDetail` 済みなら末尾に ` code=<c> next=<n>` を追記
/// （TASK-62.5.9。未セット時は `failResp` と同じ = 従来 bit 一致。行頭 `fail ` 不変）。
fn failActionResp(conn_state: *ConnState, name: []const u8, reason: []const u8) void {
    failRespEx(conn_state, name, reason, true);
}

fn failRespEx(conn_state: *ConnState, name: []const u8, reason: []const u8, with_detail: bool) void {
    conn_state.appendResp("fail ");
    conn_state.appendResp(name);
    conn_state.appendResp(" ");
    conn_state.appendResp(firstLine(reason));
    if (with_detail) {
        if (harness.action_registry.actionErrorDetail()) |d| {
            conn_state.appendResp(" code=");
            conn_state.appendResp(d.code);
            conn_state.appendResp(" next=");
            conn_state.appendResp(d.next);
        }
    }
    conn_state.appendResp("\n");
}

/// `msg` を最初の `\r`/`\n` の手前で切る（wire framing 保護。harness reportAction と同じ防御）。
fn firstLine(msg: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, msg, '\n');
    const cr = std.mem.indexOfScalar(u8, msg, '\r');
    const cut = @min(nl orelse msg.len, cr orelse msg.len);
    return msg[0..cut];
}

/// digest: custom probe + `capabilities` のみ（組み込み fb/audio/stats/capture/gamepad は対象外）。
fn handleDigestCmd(conn_state: *ConnState, it: *std.mem.TokenIterator(u8, .any)) void {
    const probe = it.next() orelse return errorResp(conn_state, "digest: missing probe name");
    if (std.mem.eql(u8, probe, "capabilities")) {
        const payload = harness.capabilitiesPayload(&caps_buf);
        conn_state.appendResp("capabilities ");
        conn_state.appendResp(payload);
        conn_state.appendResp("\n");
        return;
    }
    if (isCopilotUnavailableBuiltin(probe)) return errorResp(conn_state, "probe not available via copilot (custom probes + capabilities only)");
    const p = harness.findProbe(probe) orelse return errorResp(conn_state, "unknown probe");
    const dg = p.digest orelse return errorResp(conn_state, "digest unsupported");
    var buf: [harness.DIGEST_BUF_LEN]u8 = undefined;
    const payload = dg(p.ctx, &buf);
    conn_state.appendResp(probe);
    conn_state.appendResp(" ");
    conn_state.appendResp(firstLine(payload));
    conn_state.appendResp("\n");
}

/// snapshot: custom probe の raw bytes を明示 path（必須）へ書き、path を返す。
fn handleSnapshotCmd(conn_state: *ConnState, it: *std.mem.TokenIterator(u8, .any)) void {
    const probe = it.next() orelse return errorResp(conn_state, "snapshot: missing probe name");
    const path = it.next() orelse return errorResp(conn_state, "snapshot: path required");
    if (std.mem.eql(u8, probe, "capabilities") or isCopilotUnavailableBuiltin(probe)) {
        return errorResp(conn_state, "snapshot not available via copilot (custom probes only)");
    }
    const p = harness.findProbe(probe) orelse return errorResp(conn_state, "unknown probe");
    const snap = p.snapshot orelse return errorResp(conn_state, "snapshot unsupported");
    ensureIo();
    const bytes = snap(p.ctx, gpa) catch |err| {
        std.debug.print("[copilot] snapshot {s} 失敗: {s}\n", .{ probe, @errorName(err) });
        return errorResp(conn_state, "snapshot failed");
    };
    defer gpa.free(bytes);
    std.Io.Dir.cwd().writeFile(io_val, .{ .sub_path = path, .data = bytes }) catch |err| {
        std.debug.print("[copilot] snapshot {s} 書き込み失敗 {s}: {s}\n", .{ probe, path, @errorName(err) });
        return errorResp(conn_state, "snapshot write failed");
    };
    conn_state.appendResp(path);
    conn_state.appendResp("\n");
}

/// action: executor 経由で実行し `actor=local_agent` で記録する（open 中の tx があればタグ付け）。
fn handleActionCmd(conn_state: *ConnState, it: *std.mem.TokenIterator(u8, .any)) void {
    const name = it.next() orelse return failResp(conn_state, "?", "missing action name");
    if (netsync_active) return failResp(conn_state, name, "netsync session active (operate disabled)");
    const args = std.mem.trim(u8, it.rest(), " \t");
    var buf: [harness.DIGEST_BUF_LEN]u8 = undefined;
    if (shared_executor != null) {
        // 共有 executor 設定時: registry の run を直接呼ぶ（app 側 wrapper が executor 経由の
        // 記録を一元化しているため、ここで own executor を通すと二重記録/ReentrantDispatch になる）。
        const act = harness.findAction(name) orelse return failResp(conn_state, name, "unknown action");
        // direct-run は action_registry.dispatch を経由しないので structured error を手動クリア
        harness.action_registry.clearActionErrorDetail();
        const result = act.run(act.ctx, args, &buf) catch |err| {
            return failActionResp(conn_state, name, @errorName(err));
        };
        conn_state.appendResp(name);
        conn_state.appendResp(" ");
        conn_state.appendResp(firstLine(result));
        conn_state.appendResp("\n");
        return;
    }
    const result = executor.executeAction(name, args, .{
        .actor = .local_agent,
        .transaction = open_tx,
        .record_policy = .record,
    }, &buf) catch |err| {
        if (err == error.UnknownAction) return failResp(conn_state, name, "unknown action");
        return failActionResp(conn_state, name, @errorName(err));
    };
    conn_state.appendResp(name);
    conn_state.appendResp(" ");
    conn_state.appendResp(firstLine(result.output));
    conn_state.appendResp("\n");
}

fn handleBeginTx(conn_state: *ConnState, it: *std.mem.TokenIterator(u8, .any)) void {
    if (netsync_active) return failResp(conn_state, "begin_tx", "netsync session active (operate disabled)");
    if (open_tx != null) return failResp(conn_state, "begin_tx", "transaction already open");
    const label = std.mem.trim(u8, it.rest(), " \t");
    const exec = targetExecutor();
    const handle = exec.beginTransaction(.local_agent, label) catch |err| {
        return failResp(conn_state, "begin_tx", @errorName(err));
    };
    open_tx = handle;
    var buf: [32]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "ok tx={d}\n", .{exec.tx_table[handle.index].id}) catch "ok\n";
    conn_state.appendResp(line);
}

fn handleEndTx(conn_state: *ConnState) void {
    if (netsync_active) return failResp(conn_state, "end_tx", "netsync session active (operate disabled)");
    const handle = open_tx orelse return failResp(conn_state, "end_tx", "no open transaction");
    open_tx = null;
    targetExecutor().endTransaction(handle, .local_agent) catch |err| {
        return failResp(conn_state, "end_tx", @errorName(err));
    };
    conn_state.appendResp("ok\n");
}

fn handleCancelTx(conn_state: *ConnState) void {
    if (netsync_active) return failResp(conn_state, "cancel_tx", "netsync session active (operate disabled)");
    const handle = open_tx orelse return failResp(conn_state, "cancel_tx", "no open transaction");
    open_tx = null;
    targetExecutor().cancelTransaction(handle, .local_agent) catch |err| {
        return failResp(conn_state, "cancel_tx", @errorName(err));
    };
    conn_state.appendResp("ok\n");
}

// ============================================================================
// tests（socket 非依存の直叩き中心。実 socket・並行 UX 非干渉は E2E で確認）
// 名前は "copilot:" prefix（build.zig の test-copilot step が filter で選別する）。
// ============================================================================

const testing = std.testing;

/// copilot module 状態のテスト用リセット（transport は起動しない）。
fn resetCopilotForTest() void {
    ensureIo();
    initExecutorState();
    netsync_active = false;
    enabled = false;
    shared_executor = null;
    harness.setExternalRegistryEnabled(false);
    // false は action_registry に伝わらないため、無効化は resetForTest 必須（TASK-62.3.1）。
    harness.action_registry.resetForTest();
}

/// テスト用 convenience: 1 リクエスト分の bytes を ConnState に通し全コマンドを実行、応答 slice を返す。
fn handleRequest(cs: *ConnState, bytes: []const u8) []const u8 {
    cs.reset();
    cs.feed(bytes);
    if (!cs.finishRead()) return cs.resp[0..0];
    while (cs.phase == .executing) cs.executeBudget();
    return cs.resp[0..cs.resp_len];
}

const TestActionCtx = struct { calls: u32 = 0 };

fn testActionPing(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const c: *TestActionCtx = @ptrCast(@alignCast(ctx));
    c.calls += 1;
    return std.fmt.bufPrint(buf, "pong {s}", .{args}) catch "pong";
}

fn testActionBoomDetail(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = ctx;
    _ = buf;
    if (std.mem.eql(u8, args, "set")) {
        harness.setActionErrorDetail("file_not_found", "check path or use save first");
    }
    return error.Boom;
}

const TestProbeCtx = struct { value: u32 = 7 };

fn testProbeDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const c: *TestProbeCtx = @ptrCast(@alignCast(ctx));
    return std.fmt.bufPrint(buf, "value={d}", .{c.value}) catch "value=?";
}

fn testProbeSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    _ = ctx;
    return allocator.dupe(u8, "SNAPBYTES");
}

test "copilot: 1 env未設定は no-op（isEnabled=false・pump no-op・register は従来通り no-op）" {
    resetCopilotForTest();
    try testing.expect(!isEnabled());
    pump(); // disabled → 即 return（クラッシュしないこと）
    // harness disabled + external gate off → registerAction は no-op
    try testing.expect(!harness.isEnabled());
    var c = TestActionCtx{};
    harness.registerAction(.{ .name = "copilot_noreg", .ctx = &c, .run = testActionPing });
    try testing.expect(harness.findAction("copilot_noreg") == null);
}

test "copilot: 2 OR ゲート（setExternalRegistryEnabled で registerProbe/registerAction が registry へ入る）" {
    resetCopilotForTest();
    try testing.expect(!harness.isEnabled()); // 前提: harness は disabled のまま
    harness.setExternalRegistryEnabled(true);
    defer {
        harness.setExternalRegistryEnabled(false);
        harness.action_registry.resetForTest();
    }
    var ac = TestActionCtx{};
    var pc = TestProbeCtx{};
    harness.registerAction(.{ .name = "copilot_gate_a", .ctx = &ac, .run = testActionPing });
    harness.registerProbe(.{ .name = "copilot_gate_p", .ctx = &pc, .digest = testProbeDigest });
    try testing.expect(harness.findAction("copilot_gate_a") != null);
    try testing.expect(harness.findProbe("copilot_gate_p") != null);
}

test "copilot: 3 action 応答形式 + CommandLog に actor=local_agent kind=normal で記録" {
    resetCopilotForTest();
    harness.setExternalRegistryEnabled(true);
    defer {
        harness.setExternalRegistryEnabled(false);
        harness.action_registry.resetForTest();
    }
    var ac = TestActionCtx{};
    harness.registerAction(.{ .name = "ping", .ctx = &ac, .run = testActionPing });

    var cs: ConnState = undefined;
    const resp = handleRequest(&cs, "action ping hello");
    try testing.expectEqualStrings("ping pong hello\n", resp);
    try testing.expectEqual(@as(u32, 1), ac.calls);

    try testing.expectEqual(@as(u32, 1), command_log.filled);
    const rec = command_log.findBySeq(1).?;
    try testing.expect(rec.actor.eql(.local_agent));
    try testing.expectEqual(command.CommandKind.normal, rec.kind);
    try testing.expectEqualStrings("ping", rec.name());
    try testing.expectEqualStrings("hello", rec.args());
    try testing.expect(!rec.undoable); // noteUndo 呼び出し元がまだ無い（62.5.3 で pixie が対応）
}

test "copilot: 3b failActionResp に structured error（code=/next=）/ 未セット時 bit 一致 / fail 行頭" {
    resetCopilotForTest();
    harness.setExternalRegistryEnabled(true);
    defer {
        harness.setExternalRegistryEnabled(false);
        harness.action_registry.resetForTest();
    }
    var ac = TestActionCtx{};
    harness.registerAction(.{ .name = "boom", .ctx = &ac, .run = testActionBoomDetail });

    var cs: ConnState = undefined;
    const resp1 = handleRequest(&cs, "action boom set");
    try testing.expect(std.mem.startsWith(u8, resp1, "fail boom "));
    try testing.expectEqualStrings("fail boom Boom code=file_not_found next=check path or use save first\n", resp1);

    // dispatch 相当のクリア: 次の失敗（detail 未セット）は従来形式と bit 一致
    const resp2 = handleRequest(&cs, "action boom noset");
    try testing.expectEqualStrings("fail boom Boom\n", resp2);

    // 非 action 失敗（begin_tx 等）は detail を付けない
    const resp3 = handleRequest(&cs, "end_tx");
    try testing.expectEqualStrings("fail end_tx no open transaction\n", resp3);
}

test "copilot: 4 begin_tx→action→end_tx で transaction_id が付く / 二重 begin・handle 不整合は fail" {
    resetCopilotForTest();
    harness.setExternalRegistryEnabled(true);
    defer {
        harness.setExternalRegistryEnabled(false);
        harness.action_registry.resetForTest();
    }
    var ac = TestActionCtx{};
    harness.registerAction(.{ .name = "ping", .ctx = &ac, .run = testActionPing });

    var cs: ConnState = undefined;
    const resp = handleRequest(&cs, "begin_tx macro; action ping x; end_tx");
    try testing.expectEqualStrings("ok tx=1\nping pong x\nok\n", resp);
    const rec = command_log.findBySeq(1).?;
    try testing.expectEqual(@as(?u64, 1), rec.transaction_id);
    try testing.expect(open_tx == null);

    // 二重 begin は 2 回目が fail
    const resp2 = handleRequest(&cs, "begin_tx a; begin_tx b");
    try testing.expectEqualStrings("ok tx=2\nfail begin_tx transaction already open\n", resp2);
    _ = handleRequest(&cs, "end_tx");

    // open が無い end_tx / cancel_tx は fail（handle 不整合の wire 表現）
    const resp3 = handleRequest(&cs, "end_tx; cancel_tx");
    try testing.expectEqualStrings("fail end_tx no open transaction\nfail cancel_tx no open transaction\n", resp3);

    // cancel_tx 後の action は tx タグ無し
    const resp4 = handleRequest(&cs, "begin_tx m2; cancel_tx; action ping y");
    try testing.expect(std.mem.endsWith(u8, resp4, "ping pong y\n"));
    const rec_last = command_log.findBySeq(command_log.next_seq - 1).?;
    try testing.expectEqual(@as(?u64, null), rec_last.transaction_id);
}

test "copilot: 5 netsync session 中は operate 拒否・observe は許可（AC #3）" {
    resetCopilotForTest();
    harness.setExternalRegistryEnabled(true);
    defer {
        harness.setExternalRegistryEnabled(false);
        harness.action_registry.resetForTest();
    }
    var ac = TestActionCtx{};
    var pc = TestProbeCtx{ .value = 42 };
    harness.registerAction(.{ .name = "ping", .ctx = &ac, .run = testActionPing });
    harness.registerProbe(.{ .name = "cp_probe", .ctx = &pc, .digest = testProbeDigest, .snapshot = testProbeSnapshot });

    setNetsyncSessionActive(true);
    defer setNetsyncSessionActive(false);

    var cs: ConnState = undefined;
    const resp = handleRequest(&cs, "action ping x; begin_tx m; end_tx; cancel_tx");
    try testing.expectEqualStrings(
        "fail ping netsync session active (operate disabled)\n" ++
            "fail begin_tx netsync session active (operate disabled)\n" ++
            "fail end_tx netsync session active (operate disabled)\n" ++
            "fail cancel_tx netsync session active (operate disabled)\n",
        resp,
    );
    try testing.expectEqual(@as(u32, 0), ac.calls); // dispatch されていない
    try testing.expectEqual(@as(u32, 0), command_log.filled); // 記録もされない

    // observe（digest）は許可
    const resp2 = handleRequest(&cs, "digest cp_probe; digest capabilities");
    try testing.expect(std.mem.startsWith(u8, resp2, "cp_probe value=42\ncapabilities {"));

    // observe（snapshot）も許可（netsync 中に拒否されるのは operate の 4 コマンドのみ）
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/netsync_snap.bin", .{tmp.sub_path});
    var req_buf: [256]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "snapshot cp_probe {s}", .{path});
    var expect_buf: [192]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expect_buf, "{s}\n", .{path});
    try testing.expectEqualStrings(expected, handleRequest(&cs, req));
    const written = try std.Io.Dir.cwd().readFileAlloc(io_val, path, gpa, .unlimited);
    defer gpa.free(written);
    try testing.expectEqualStrings("SNAPBYTES", written);
}

test "copilot: 6 digest/snapshot/未知の応答形式（capabilities/custom/明示 path/fail 形式/quit 非対応）" {
    resetCopilotForTest();
    harness.setExternalRegistryEnabled(true);
    defer {
        harness.setExternalRegistryEnabled(false);
        harness.action_registry.resetForTest();
    }
    var pc = TestProbeCtx{ .value = 9 };
    harness.registerProbe(.{ .name = "cp_probe", .ctx = &pc, .digest = testProbeDigest, .snapshot = testProbeSnapshot });

    var cs: ConnState = undefined;
    // digest: custom / capabilities / 組み込み非公開 / 未知
    try testing.expectEqualStrings("cp_probe value=9\n", handleRequest(&cs, "digest cp_probe"));
    try testing.expect(std.mem.startsWith(u8, handleRequest(&cs, "digest capabilities"), "capabilities {\"probes\":["));
    try testing.expectEqualStrings("error: probe not available via copilot (custom probes + capabilities only)\n", handleRequest(&cs, "digest fb"));
    try testing.expectEqualStrings("error: unknown probe\n", handleRequest(&cs, "digest nosuch"));

    // snapshot: 明示 path へ書き path を返す / path 省略は error
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/copilot_snap.bin", .{tmp.sub_path});
    var req_buf: [256]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "snapshot cp_probe {s}", .{path});
    var expect_buf: [192]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expect_buf, "{s}\n", .{path});
    try testing.expectEqualStrings(expected, handleRequest(&cs, req));
    const written = try std.Io.Dir.cwd().readFileAlloc(io_val, path, gpa, .unlimited);
    defer gpa.free(written);
    try testing.expectEqualStrings("SNAPBYTES", written);
    try testing.expectEqualStrings("error: snapshot: path required\n", handleRequest(&cs, "snapshot cp_probe"));

    // 未知 action / 未知コマンド / quit 非対応
    try testing.expectEqualStrings("fail nosuch unknown action\n", handleRequest(&cs, "action nosuch x"));
    try testing.expectEqualStrings("fail bogus unknown command\n", handleRequest(&cs, "bogus 1 2"));
    try testing.expect(std.mem.startsWith(u8, handleRequest(&cs, "quit"), "fail quit "));
}

test "copilot: 7 リクエスト 64KiB 超過で error 応答（実行されない）" {
    resetCopilotForTest();
    var cs: ConnState = undefined;
    cs.reset();
    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 'a');
    var fed: usize = 0;
    while (fed <= MAX_WIRE) : (fed += chunk.len) cs.feed(&chunk);
    try testing.expect(cs.req_overflow);
    try testing.expect(cs.finishRead());
    try testing.expectEqual(Phase.sending, cs.phase); // 実行フェーズを踏まない
    try testing.expectEqualStrings("error: request too large\n", cs.resp[0..cs.resp_len]);
}

test "copilot: 8 排他（VP_HARNESS_* 併用時は copilot 無効）" {
    try testing.expect(!decideEnabled(true, true)); // harness env があれば無効
    try testing.expect(decideEnabled(true, false));
    try testing.expect(!decideEnabled(false, false));
    try testing.expect(!decideEnabled(false, true));
}

// カバレッジ限界の明記: POLLIN|POLLHUP 同時到着時の実 socket タイミング（half-close 直後の
// 未読データ + HUP）は unit test では決定的に再現できない（OS のバッファリング依存で脆いテストに
// なるため追加しない）。コード上の担保は `pumpRead` の doc comment のとおり「close 判定は read の
// 結果のみ・POLLHUP ビットで直接 close しない」構造で、ConnState 層の等価分岐（データ有り=実行 /
// データ無し=close）は下のテストが直接叩く。実 socket 経路は E2E（scripts/drive。drive は
// write→half-close→read の順で必ずこの経路を通る）で担保する。
test "copilot: 9 ConnState transport 挙動（partial feed/一度だけ実行/truncated/deadline/budget 持ち越し）" {
    resetCopilotForTest();
    harness.setExternalRegistryEnabled(true);
    defer {
        harness.setExternalRegistryEnabled(false);
        harness.action_registry.resetForTest();
    }
    var ac = TestActionCtx{};
    harness.registerAction(.{ .name = "ping", .ctx = &ac, .run = testActionPing });

    // データ無し HUP: 1 byte も受けずに half-close → finishRead()=false（transport が応答なしで close）
    var cs: ConnState = undefined;
    cs.reset();
    try testing.expect(!cs.finishRead());

    // データ有り HUP: 未読データがあれば HUP が同時でも実行フェーズへ進む（partial feed →
    // half-close で一度だけ実行）
    cs.reset();
    cs.feed("action pi");
    cs.feed("ng abc");
    try testing.expect(cs.finishRead());
    cs.executeBudget();
    try testing.expectEqual(Phase.sending, cs.phase);
    try testing.expectEqualStrings("ping pong abc\n", cs.resp[0..cs.resp_len]);
    try testing.expectEqual(@as(u32, 1), ac.calls);
    cs.executeBudget(); // .sending 以降は no-op（再実行されない）
    try testing.expectEqual(@as(u32, 1), ac.calls);

    // 応答 64KiB 超過で truncated 行
    cs.reset();
    var big: [4096]u8 = undefined;
    @memset(&big, 'x');
    var appended: usize = 0;
    while (appended <= MAX_WIRE) : (appended += big.len) cs.appendResp(&big);
    try testing.expect(cs.resp_truncated);
    cs.beginSend();
    try testing.expect(std.mem.endsWith(u8, cs.resp[0..cs.resp_len], TRUNCATED_LINE));

    // deadline: DEADLINE_FRAMES 回までは true、超過で false（close 判定）
    cs.reset();
    var i: u32 = 0;
    while (i < DEADLINE_FRAMES) : (i += 1) {
        try testing.expect(cs.tickFrame());
    }
    try testing.expect(!cs.tickFrame());

    // budget 持ち越し: 17 コマンドは 2 pump に分割実行される
    ac.calls = 0;
    cs.reset();
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(testing.allocator);
    var n: usize = 0;
    while (n < CMD_BUDGET + 1) : (n += 1) {
        try req.appendSlice(testing.allocator, "action ping x\n");
    }
    cs.feed(req.items);
    try testing.expect(cs.finishRead());
    cs.executeBudget();
    try testing.expectEqual(@as(u32, CMD_BUDGET), ac.calls); // 1 pump 目は budget 分だけ
    try testing.expectEqual(Phase.executing, cs.phase); // 持ち越し
    cs.executeBudget();
    try testing.expectEqual(@as(u32, CMD_BUDGET + 1), ac.calls); // 2 pump 目で残りを消化
    try testing.expectEqual(Phase.sending, cs.phase);
}

test "copilot: 10 setSharedExecutor（action は own-log 非記録の直 dispatch / tx は共有 executor / 未設定時は従来挙動）" {
    resetCopilotForTest();
    harness.setExternalRegistryEnabled(true);
    defer {
        harness.setExternalRegistryEnabled(false);
        harness.action_registry.resetForTest();
    }
    var ac = TestActionCtx{};
    harness.registerAction(.{ .name = "ping", .ctx = &ac, .run = testActionPing });

    // 共有 executor（app 所有想定。ここではテストローカル）を設定
    var shared_log: command.CommandLog = .{};
    var shared_exec = command.Executor.init(.{ .ctx = undefined, .run = dispatchHarnessAction });
    shared_exec.log = &shared_log;
    setSharedExecutor(&shared_exec);
    defer setSharedExecutor(null);

    // action: own-log に記録されず直 dispatch される（記録は app wrapper の責務 = ここでは無記録）
    var cs: ConnState = undefined;
    const resp = handleRequest(&cs, "action ping hello");
    try testing.expectEqualStrings("ping pong hello\n", resp);
    try testing.expectEqual(@as(u32, 1), ac.calls); // dispatch はされる
    try testing.expectEqual(@as(u32, 0), command_log.filled); // own-log には記録されない
    try testing.expectEqual(@as(u32, 0), shared_log.filled); // executor 経由でもない（app wrapper が居ないので無記録）

    // begin_tx は共有 executor に開き、openTransactionFor(.local_agent) で見える
    const resp2 = handleRequest(&cs, "begin_tx macro");
    try testing.expectEqualStrings("ok tx=1\n", resp2);
    try testing.expect(shared_exec.openTransactionFor(.local_agent) != null);
    try testing.expect(executor.openTransactionFor(.local_agent) == null); // own executor は無関係
    const resp3 = handleRequest(&cs, "end_tx");
    try testing.expectEqualStrings("ok\n", resp3);
    try testing.expect(shared_exec.openTransactionFor(.local_agent) == null);

    // 未設定へ戻すと従来挙動（own executor 経由で own-log に記録される）
    setSharedExecutor(null);
    const resp4 = handleRequest(&cs, "action ping x");
    try testing.expectEqualStrings("ping pong x\n", resp4);
    try testing.expectEqual(@as(u32, 1), command_log.filled); // own-log に記録
    try testing.expect(command_log.latest().?.actor.eql(.local_agent));
}

test "copilot: 8 netsync session callback 配線で operate 拒否・終了で復帰" {
    resetCopilotForTest();
    harness.netsync.resetForTest();
    harness.setExternalRegistryEnabled(true);
    defer {
        harness.setExternalRegistryEnabled(false);
        harness.action_registry.resetForTest();
        harness.netsync.resetForTest();
        setNetsyncSessionActive(false);
    }

    var ac = TestActionCtx{};
    var pc = TestProbeCtx{ .value = 7 };
    harness.registerAction(.{ .name = "ping", .ctx = &ac, .run = testActionPing });
    harness.registerProbe(.{ .name = "cp_probe", .ctx = &pc, .digest = testProbeDigest, .snapshot = testProbeSnapshot });

    // platform.init 相当（callback は enableRouter より前）
    harness.netsync.setSessionStateCallback(setNetsyncSessionActive);
    harness.netsync.initHost(0);
    try testing.expect(netsync_active);

    var cs: ConnState = undefined;
    const denied = handleRequest(&cs, "action ping x; begin_tx m");
    try testing.expectEqualStrings(
        "fail ping netsync session active (operate disabled)\n" ++
            "fail begin_tx netsync session active (operate disabled)\n",
        denied,
    );
    try testing.expectEqual(@as(u32, 0), ac.calls);

    const obs = handleRequest(&cs, "digest cp_probe");
    try testing.expectEqualStrings("cp_probe value=7\n", obs);

    harness.netsync.shutdown();
    try testing.expect(!netsync_active);

    const ok = handleRequest(&cs, "action ping y");
    try testing.expectEqualStrings("ping pong y\n", ok);
    try testing.expectEqual(@as(u32, 1), ac.calls);
}
