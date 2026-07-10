//! Co-pilot（人間+AI 混在操作）の意味的コマンド実行モデル（TASK-62.5.1）。
//!
//! `CommandExecutor` が `Dispatcher`（既存 action callback 相当）の手前に立ち、
//! 誰が（`ActorId`）・何を（action name/args）・どの macro 単位で（`Transaction`）実行したかを
//! `CommandLog`（固定リング）へ記録し、その記録から undo/redo を導出する。
//! `CommandLog` を持たない構成（`Executor.log = null`）は **no-op recorder**（記録せず dispatch のみ通す）。
//!
//! ## ホットパス宣言
//! command 記録・transaction 管理・undo/redo 探索は**すべてイベント時のみ**（ユーザー/agent の操作時・
//! undo/redo 要求時）に走る。フレーム毎（全画素）/ RT（毎サンプル）経路には一切乗らない。
//! よって性能規約の SIMD 3点セット・cache_line 分離・bench 前後比較は対象外。
//! 実行は main thread 限定（harness action/UI と同じ規約）で、本モジュールは lock/atomic を持たない。
//!
//! ## 依存
//! `@import` は `std` のみ。platform / harness に非依存でグローバル状態も持たない
//! （すべて呼び出し側がインスタンス化する struct）。
//!
//! ## 用語（親 TASK-62.5 plan v1.1 §3/§4/§5 が意味論の正）
//! - `ActorId`: 誰が実行したか（local_user/local_agent/peer/system）。
//! - `CommandRecord`: 実行済み command 1 件の記録（kind=normal/revert）。
//! - `Transaction`: 複数 command を 1 undo 単位に束ねる macro 境界。
//! - `UndoRef`: app 内部の逆適用データへの opaque handle。framework は中身非解釈。

const std = @import("std");

/// action name の inline 所有バイト数上限（既存 action 名は最長 20B 弱。余裕を含む）。
pub const MAX_CMD_NAME = 64;
/// args の inline 所有バイト数上限（`Action.run` の buf 契約 1024B と同値）。
pub const MAX_CMD_ARGS = 1024;
/// `CommandLog` の固定リング容量（62.3 plan v6 の undo 保持数 max_history=128 と整合）。
pub const MAX_CMD_LOG = 128;
/// 追跡できる actor（redo_epoch 表）の上限（netsync peer 規模と同水準）。
pub const MAX_ACTORS = 16;
/// 同時に open できる transaction の上限（実用は actor あたり 1）。
pub const MAX_OPEN_TX = 4;
/// 1 transaction の undo/redo で扱える undoable command 数の上限（スナップショット配列の固定長）。
pub const MAX_TX_UNDO = 32;
/// transaction label の inline 所有バイト数上限。
pub const MAX_TX_LABEL = 64;

/// 操作の実行主体。undo/redo 探索・actor 表・transaction 照合の一致判定に使う。
pub const ActorId = union(enum) {
    local_user,
    local_agent,
    peer: u32,
    system,

    /// peer は id まで比較する完全一致判定（hash/modulo は使わない）。
    pub fn eql(a: ActorId, b: ActorId) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .peer => |aid| aid == b.peer,
            .local_user, .local_agent, .system => true,
        };
    }
};

pub const CommandKind = enum { normal, revert };

/// app 内部の逆適用データ（例: pixie `UndoStack.Op`）への opaque handle。framework は中身非解釈。
pub const UndoRef = u64;

/// 実行済み command 1 件の記録。undo/redo 探索・履歴表示の正。
pub const CommandRecord = struct {
    seq: u64,
    actor: ActorId,
    kind: CommandKind,
    name_len: u8,
    name_buf: [MAX_CMD_NAME]u8 = undefined,
    args_len: u16,
    args_buf: [MAX_CMD_ARGS]u8 = undefined,
    transaction_id: ?u64,
    undoable: bool,
    /// normal command 側の状態（undo 済みか）。
    reverted: bool = false,
    /// revert command 側の状態（redo で再適用済みか）。
    redo_consumed: bool = false,
    /// kind=revert の対象 normal command の seq。
    target_seq: ?u64 = null,
    /// redo で再適用された normal command が参照する旧 target。epoch bump 除外の根拠。
    redo_of: ?u64 = null,
    undo_ref: ?UndoRef = null,
    /// kind=revert のみ有効: 作成時点の actor redo_epoch を焼き込む。
    epoch: u64 = 0,
    /// transaction 所属時のみ有効（0 = 非所属/非対象）: normal 側は tx 内 undoable member の
    /// 1-based 序数、revert 側は revert bundle 内の 1-based 序数。undo/redo の完全性判定
    /// （序数 1 の member が現存すること）に使う。
    tx_member_index: u16 = 0,

    pub fn name(self: *const CommandRecord) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn args(self: *const CommandRecord) []const u8 {
        return self.args_buf[0..self.args_len];
    }

    fn setName(self: *CommandRecord, s: []const u8) void {
        self.name_len = @intCast(s.len);
        @memcpy(self.name_buf[0..s.len], s);
    }

    fn setArgs(self: *CommandRecord, s: []const u8) void {
        self.args_len = @intCast(s.len);
        @memcpy(self.args_buf[0..s.len], s);
    }
};

/// `CommandRecord` の固定リング + 単調 `next_seq`。alloc なし。
pub const CommandLog = struct {
    records: [MAX_CMD_LOG]CommandRecord = undefined,
    /// 現在有効な record 数（上限 `MAX_CMD_LOG` に達したら以後は一定）。
    filled: u32 = 0,
    /// 次に書き込むリング位置。
    head: u32 = 0,
    /// 次に発番する local seq。
    next_seq: u64 = 1,

    pub fn append(self: *CommandLog, rec: CommandRecord) void {
        self.records[self.head] = rec;
        self.head = (self.head + 1) % MAX_CMD_LOG;
        if (self.filled < MAX_CMD_LOG) self.filled += 1;
    }

    /// i: 0 = 最古 … `filled - 1` = 最新。
    fn recordAt(self: *CommandLog, i: u32) *CommandRecord {
        const idx = (self.head + MAX_CMD_LOG - self.filled + i) % MAX_CMD_LOG;
        return &self.records[idx];
    }

    /// 溢れて消えた record は「見つからない」だけ（サイドデータなし。stale 参照が構造的に無い）。
    pub fn findBySeq(self: *CommandLog, seq: u64) ?*CommandRecord {
        var i: u32 = 0;
        while (i < self.filled) : (i += 1) {
            const r = self.recordAt(i);
            if (r.seq == seq) return r;
        }
        return null;
    }
};

/// redo 由来の command を記録する際に発行元が渡す付随メタ（epoch 誤 bump 防止。§5.2）。
pub const PendingMeta = struct { redo_of: ?u64 };

/// executeAction の出所。`remote_commit` は netsync COMMIT 適用専用（router 再経由なし）。
pub const ExecuteSource = union(enum) {
    local,
    remote_commit: struct { seq: u64, pending_local_meta: ?PendingMeta = null },
};

pub const RecordPolicy = enum { record, dry_run, no_record };

pub const ExecuteOptions = struct {
    actor: ActorId,
    source: ExecuteSource = .local,
    transaction: ?TransactionHandle = null,
    record_policy: RecordPolicy = .record,
};

pub const ExecuteResult = struct { seq: ?u64, output: []const u8 };

/// open transaction の slot 参照。generation 不一致は stale handle（slot 再利用後の古い参照）として弾く。
pub const TransactionHandle = struct { index: u8, generation: u32 };

/// 既存 action callback 相当。名前解決済みの action を実行する薄い委譲口。
pub const Dispatcher = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8,
};

/// app 側の undo 逆適用アダプタ。
pub const CommandAdapter = struct {
    ctx: *anyopaque,
    /// UndoRef が現存し逆適用可能かを確認する。
    canUndo: *const fn (ctx: *anyopaque, rec: *const CommandRecord) bool,
    /// 逆適用する。**失敗しない契約**: `canUndo==true` なら必ず成功する
    /// （逆適用が失敗しうる app は `canUndo` 側で false を返す責務を負う。
    /// これにより transaction の all-or-nothing が事前検証だけで成立する）。
    applyUndo: *const fn (ctx: *anyopaque, rec: *const CommandRecord) void,
};

pub const UndoOutcome = struct {
    happened: bool,
    message: []const u8 = "",
};

pub const RedoOutcome = struct {
    happened: bool,
    message: []const u8 = "",
};

pub const TransactionError = error{
    TooManyOpenTransactions,
    LabelTooLong,
    StaleTransactionHandle,
    TransactionIdExhausted,
};

const ActorEpochSlot = struct {
    actor: ActorId,
    epoch: u64 = 0,
};

const TxSlot = struct {
    open: bool = false,
    id: u64 = 0,
    actor: ActorId = .system,
    generation: u32 = 0,
    label_len: u8 = 0,
    label_buf: [MAX_TX_LABEL]u8 = undefined,
    /// tx 内で undoable な normal command が append されるたびに増える。`tx_member_index` の発番源。
    undoable_member_count: u16 = 0,
};

/// tx（transaction 側 or revert bundle 側）の member を一時的に退避するスナップショット。
/// undo/redo 中にリングが上書きされても安全に扱えるよう、対象を確定した時点で値コピーする。
const TxSnapshot = struct {
    items: [MAX_TX_UNDO]CommandRecord = undefined,
    count: u16 = 0,
};

fn writeMsg(buf: []u8, msg: []const u8) []const u8 {
    const n = @min(buf.len, msg.len);
    @memcpy(buf[0..n], msg[0..n]);
    return buf[0..n];
}

/// AppendSpec: `executeAction` の記録 / undo の revert 記録 / redo の新規記録が共有する append 経路。
const AppendSpec = struct {
    actor: ActorId,
    kind: CommandKind,
    name: []const u8,
    args: []const u8,
    transaction_id: ?u64,
    undoable: bool,
    undo_ref: ?UndoRef,
    target_seq: ?u64 = null,
    redo_of: ?u64 = null,
    tx_member_index: u16 = 0,
    source: ExecuteSource = .local,
};

/// 人間/agent 混在操作の意味的コマンド実行器。record 対象の `CommandLog` を持たなければ
/// no-op recorder（記録せず dispatch のみ通す）として振る舞う。
pub const Executor = struct {
    log: ?*CommandLog = null,
    dispatcher: Dispatcher,
    adapter: ?CommandAdapter = null,

    actor_table: [MAX_ACTORS]ActorEpochSlot = undefined,
    actor_count: u32 = 0,

    tx_table: [MAX_OPEN_TX]TxSlot = undefined,
    /// begin / undo の revert bundle / redo の新 bundle ごとに単調一意な id を発行する。
    /// 閉じた transaction の id は再利用しない。u64 枯渇は実用上到達不能だが、到達時は
    /// fail-stop でなく新規 transaction を reject する（`allocTransactionId`）。
    next_transaction_id: u64 = 1,

    /// dispatcher.run 実行区間を示す（reentrant executeAction/redo を拒否するためのフラグ）。
    in_dispatch: bool = false,
    pending_undo_ref: ?UndoRef = null,
    pending_set: bool = false,

    pub fn init(dispatcher: Dispatcher) Executor {
        var self: Executor = .{ .dispatcher = dispatcher };
        for (&self.tx_table) |*slot| slot.* = .{};
        return self;
    }

    /// dispatch callback 実行中に app が呼ぶ。**dispatch 開始時に pending を clear、正常復帰時のみ
    /// consume、dispatch エラー時は discard**（`runDispatchCapturingUndo` が管理）。
    /// 同一 dispatch 内の 2 回目以降の呼び出しは first-wins（警告して無視）。
    pub fn noteUndo(self: *Executor, ref: UndoRef) void {
        if (!self.in_dispatch) {
            std.debug.print("[command] noteUndo: dispatch 区間外の呼び出しは無視されます\n", .{});
            return;
        }
        if (self.pending_set) {
            std.debug.print("[command] noteUndo: 同一 dispatch 内の2回目以降の呼び出しは無視されます(first-wins)\n", .{});
            return;
        }
        self.pending_undo_ref = ref;
        self.pending_set = true;
    }

    // ------------------------------------------------------------------
    // actor 表（redo_epoch）
    // ------------------------------------------------------------------

    fn findActorSlot(self: *Executor, actor: ActorId) ?*ActorEpochSlot {
        var i: u32 = 0;
        while (i < self.actor_count) : (i += 1) {
            if (self.actor_table[i].actor.eql(actor)) return &self.actor_table[i];
        }
        return null;
    }

    fn actorCapacityOk(self: *Executor, actor: ActorId) bool {
        if (self.findActorSlot(actor) != null) return true;
        return self.actor_count < MAX_ACTORS;
    }

    fn ensureActor(self: *Executor, actor: ActorId) error{TooManyActors}!*ActorEpochSlot {
        if (self.findActorSlot(actor)) |s| return s;
        if (self.actor_count >= MAX_ACTORS) return error.TooManyActors;
        self.actor_table[self.actor_count] = .{ .actor = actor };
        self.actor_count += 1;
        return &self.actor_table[self.actor_count - 1];
    }

    fn currentEpoch(self: *Executor, actor: ActorId) u64 {
        return if (self.findActorSlot(actor)) |s| s.epoch else 0;
    }

    // ------------------------------------------------------------------
    // transaction
    // ------------------------------------------------------------------

    fn checkTransactionHandle(self: *Executor, h: TransactionHandle, actor: ActorId) error{StaleTransactionHandle}!void {
        if (h.index >= MAX_OPEN_TX) return error.StaleTransactionHandle;
        const slot = &self.tx_table[h.index];
        if (!slot.open or slot.generation != h.generation or !slot.actor.eql(actor)) {
            return error.StaleTransactionHandle;
        }
    }

    fn isTransactionOpen(self: *Executor, tx_id: u64) bool {
        for (self.tx_table) |slot| {
            if (slot.open and slot.id == tx_id) return true;
        }
        return false;
    }

    /// transaction id の発番。u64 枯渇時は null（fail-stop でなく新規 transaction を reject する）。
    fn allocTransactionId(self: *Executor) ?u64 {
        if (self.next_transaction_id == std.math.maxInt(u64)) return null;
        const id = self.next_transaction_id;
        self.next_transaction_id += 1;
        return id;
    }

    pub fn beginTransaction(self: *Executor, actor: ActorId, label: []const u8) TransactionError!TransactionHandle {
        if (label.len > MAX_TX_LABEL) return error.LabelTooLong;
        var i: usize = 0;
        while (i < MAX_OPEN_TX) : (i += 1) {
            if (!self.tx_table[i].open) {
                const id = self.allocTransactionId() orelse return error.TransactionIdExhausted;
                const generation = self.tx_table[i].generation;
                self.tx_table[i] = .{
                    .open = true,
                    .id = id,
                    .actor = actor,
                    .generation = generation,
                    .label_len = @intCast(label.len),
                    .undoable_member_count = 0,
                };
                @memcpy(self.tx_table[i].label_buf[0..label.len], label);
                return .{ .index = @intCast(i), .generation = generation };
            }
        }
        return error.TooManyOpenTransactions;
    }

    pub fn endTransaction(self: *Executor, handle: TransactionHandle, actor: ActorId) TransactionError!void {
        try self.checkTransactionHandle(handle, actor);
        const slot = &self.tx_table[handle.index];
        slot.open = false;
        slot.generation += 1;
    }

    /// 以後のタグ付けを止めるのみ。実行済み command の巻き戻しは framework の責務外
    /// （必要なら app が undo を呼ぶ）。
    pub fn cancelTransaction(self: *Executor, handle: TransactionHandle, actor: ActorId) TransactionError!void {
        try self.checkTransactionHandle(handle, actor);
        const slot = &self.tx_table[handle.index];
        slot.open = false;
        slot.generation += 1;
    }

    // ------------------------------------------------------------------
    // append（executeAction の記録 / undo の revert 記録 / redo の新規記録が共有）
    // ------------------------------------------------------------------

    fn appendRecord(self: *Executor, spec: AppendSpec) !u64 {
        const log = self.log.?;
        var seq: u64 = undefined;
        switch (spec.source) {
            .local => {
                seq = log.next_seq;
                log.next_seq += 1;
            },
            .remote_commit => |rc| {
                seq = rc.seq;
                if (rc.seq + 1 > log.next_seq) log.next_seq = rc.seq + 1;
            },
        }

        var rec: CommandRecord = .{
            .seq = seq,
            .actor = spec.actor,
            .kind = spec.kind,
            .name_len = 0,
            .args_len = 0,
            .transaction_id = spec.transaction_id,
            .undoable = spec.undoable,
            .target_seq = spec.target_seq,
            .redo_of = spec.redo_of,
            .undo_ref = spec.undo_ref,
            .tx_member_index = spec.tx_member_index,
        };
        rec.setName(spec.name);
        rec.setArgs(spec.args);

        const slot = try self.ensureActor(spec.actor);
        // epoch を進めるのは「redo 由来でない新規 undoable normal command」の記録のみ（§5.3）。
        if (spec.kind == .normal and spec.undoable and spec.redo_of == null) {
            slot.epoch += 1;
        }
        if (spec.kind == .revert) rec.epoch = slot.epoch;

        log.append(rec);
        return seq;
    }

    // ------------------------------------------------------------------
    // dispatch（in_dispatch 管理 + noteUndo の scoped pending）
    // ------------------------------------------------------------------

    const DispatchResult = struct { output: []const u8, undo_ref: ?UndoRef };

    fn runDispatchCapturingUndo(self: *Executor, name: []const u8, args: []const u8, buf: []u8) !DispatchResult {
        if (self.in_dispatch) return error.ReentrantDispatch;
        self.in_dispatch = true;
        self.pending_undo_ref = null;
        self.pending_set = false;
        defer self.in_dispatch = false;

        const output = self.dispatcher.run(self.dispatcher.ctx, name, args, buf) catch |err| {
            self.pending_undo_ref = null;
            self.pending_set = false;
            return err;
        };
        const ref = self.pending_undo_ref;
        self.pending_undo_ref = null;
        self.pending_set = false;
        return .{ .output = output, .undo_ref = ref };
    }

    // ------------------------------------------------------------------
    // preflight（dispatch 前に一括検証。record_policy と log の有無によらず同一の入力制約を適用）
    // ------------------------------------------------------------------

    fn preflight(self: *Executor, name: []const u8, args: []const u8, opts: ExecuteOptions) !void {
        if (name.len == 0) return error.NameEmpty;
        if (name.len > MAX_CMD_NAME) return error.NameTooLong;
        if (args.len > MAX_CMD_ARGS) return error.ArgsTooLong;
        if (opts.transaction) |h| try self.checkTransactionHandle(h, opts.actor);
        if (!self.actorCapacityOk(opts.actor)) return error.TooManyActors;
        switch (opts.source) {
            .local => {},
            .remote_commit => |rc| {
                // log が無い（no-op recorder）場合は比較対象の next_seq が無いため検査自体が成立しない。
                if (self.log) |log| {
                    if (rc.seq < log.next_seq) return error.StaleRemoteSeq;
                }
            },
        }
    }

    // ------------------------------------------------------------------
    // executeAction
    // ------------------------------------------------------------------

    pub fn executeAction(self: *Executor, name: []const u8, args: []const u8, opts: ExecuteOptions, buf: []u8) anyerror!ExecuteResult {
        try self.preflight(name, args, opts);

        if (opts.record_policy == .dry_run) {
            return .{ .seq = null, .output = "" };
        }

        const dr = try self.runDispatchCapturingUndo(name, args, buf);

        if (opts.record_policy == .no_record or self.log == null) {
            return .{ .seq = null, .output = dr.output };
        }

        var transaction_id: ?u64 = null;
        var tx_member_index: u16 = 0;
        if (opts.transaction) |h| {
            const slot = &self.tx_table[h.index];
            transaction_id = slot.id;
            if (dr.undo_ref != null) {
                slot.undoable_member_count += 1;
                tx_member_index = slot.undoable_member_count;
            }
        }

        const redo_of: ?u64 = switch (opts.source) {
            .local => null,
            .remote_commit => |rc| if (rc.pending_local_meta) |m| m.redo_of else null,
        };

        const seq = try self.appendRecord(.{
            .actor = opts.actor,
            .kind = .normal,
            .name = name,
            .args = args,
            .transaction_id = transaction_id,
            .undoable = dr.undo_ref != null,
            .undo_ref = dr.undo_ref,
            .redo_of = redo_of,
            .tx_member_index = tx_member_index,
            .source = opts.source,
        });

        return .{ .seq = seq, .output = dr.output };
    }

    // ------------------------------------------------------------------
    // undo
    // ------------------------------------------------------------------

    /// tx（または revert bundle）の member を集める。序数1が現存しない・上限超過なら null
    /// （候補外として skip する。§6 のリング溢れ安全策）。
    fn collectMembers(log: *CommandLog, tx_id: u64, kind: CommandKind) ?TxSnapshot {
        var out: TxSnapshot = .{};
        var has_index1 = false;
        var i: u32 = 0;
        while (i < log.filled) : (i += 1) {
            const r = log.recordAt(i);
            if (r.kind != kind) continue;
            if (r.transaction_id == null or r.transaction_id.? != tx_id) continue;
            if (kind == .normal and !r.undoable) continue;
            if (r.tx_member_index == 1) has_index1 = true;
            if (out.count >= MAX_TX_UNDO) return null;
            out.items[out.count] = r.*;
            out.count += 1;
        }
        if (out.count == 0) return null;
        if (!has_index1) return null;
        return out;
    }

    fn performUndoBundle(self: *Executor, log: *CommandLog, adapter: CommandAdapter, actor: ActorId, members: []const CommandRecord, buf: []u8) !UndoOutcome {
        const revert_tx_id = self.allocTransactionId() orelse
            return .{ .happened = false, .message = writeMsg(buf, "no candidate: transaction id exhausted") };

        var idx: usize = members.len;
        var member_index: u16 = 0;
        while (idx > 0) {
            idx -= 1;
            const m = members[idx];
            adapter.applyUndo(adapter.ctx, &m);
            member_index += 1;
            _ = try self.appendRecord(.{
                .actor = actor,
                .kind = .revert,
                .name = m.name(),
                .args = m.args(),
                .transaction_id = revert_tx_id,
                .undoable = false,
                .undo_ref = null,
                .target_seq = m.seq,
                .redo_of = null,
                .tx_member_index = member_index,
                .source = .local,
            });
            // append 後に seq で再解決してからマークする（`*CommandRecord` を append 跨ぎで保持しない）。
            if (log.findBySeq(m.seq)) |live| live.reverted = true;
        }
        return .{ .happened = true, .message = writeMsg(buf, "undo ok") };
    }

    /// 後方走査で「actor 一致・kind=normal・undoable・!reverted・canUndo=true」の最新候補を探し、
    /// 逆適用 + revert record 群を append する。`.system` actor は常に候補なし。
    pub fn undoOne(self: *Executor, actor: ActorId, buf: []u8) anyerror!UndoOutcome {
        if (actor.eql(.system)) return .{ .happened = false, .message = writeMsg(buf, "no candidate: system actor") };
        const log = self.log orelse return .{ .happened = false, .message = writeMsg(buf, "no candidate: no log") };
        const adapter = self.adapter orelse return .{ .happened = false, .message = writeMsg(buf, "no candidate: no adapter") };

        var i: u32 = log.filled;
        while (i > 0) {
            i -= 1;
            const rec = log.recordAt(i);
            if (!rec.actor.eql(actor)) continue;
            if (rec.kind != .normal) continue;
            if (!rec.undoable) continue;
            if (rec.reverted) continue;

            if (rec.transaction_id) |tx_id| {
                if (self.isTransactionOpen(tx_id)) continue; // open 中の tx の member は候補外
                const snap = collectMembers(log, tx_id, .normal) orelse continue; // 不完全/上限超過な tx は skip

                var all_ok = true;
                for (snap.items[0..snap.count]) |m| {
                    if (!adapter.canUndo(adapter.ctx, &m)) {
                        all_ok = false;
                        break;
                    }
                }
                if (!all_ok) continue; // all-or-nothing: 1件でも不可なら tx ごと skip

                return try self.performUndoBundle(log, adapter, actor, snap.items[0..snap.count], buf);
            } else {
                if (!adapter.canUndo(adapter.ctx, rec)) continue;
                const single = [1]CommandRecord{rec.*};
                return try self.performUndoBundle(log, adapter, actor, single[0..1], buf);
            }
        }
        return .{ .happened = false, .message = writeMsg(buf, "no candidate") };
    }

    // ------------------------------------------------------------------
    // redo
    // ------------------------------------------------------------------

    fn sortByTargetSeqAsc(items: []CommandRecord) void {
        var i: usize = 1;
        while (i < items.len) : (i += 1) {
            const key = items[i];
            var j: usize = i;
            while (j > 0 and items[j - 1].target_seq.? > key.target_seq.?) : (j -= 1) {
                items[j] = items[j - 1];
            }
            items[j] = key;
        }
    }

    fn performRedoBundle(self: *Executor, log: *CommandLog, actor: ActorId, members_in: []CommandRecord, buf: []u8) !RedoOutcome {
        sortByTargetSeqAsc(members_in); // 元の実行順（target_seq 昇順）で再実行する

        const new_tx_id = self.allocTransactionId() orelse
            return .{ .happened = false, .message = writeMsg(buf, "no candidate: transaction id exhausted") };

        var applied_count: u16 = 0;
        var dispatch_err: ?anyerror = null;

        for (members_in) |m| {
            const target_seq = m.target_seq.?;
            const target = log.findBySeq(target_seq) orelse {
                dispatch_err = error.PartialRedo;
                break;
            };
            const name_copy = target.name();
            const args_copy = target.args();

            const dr = self.runDispatchCapturingUndo(name_copy, args_copy, buf) catch {
                dispatch_err = error.PartialRedo;
                break;
            };

            applied_count += 1;
            _ = try self.appendRecord(.{
                .actor = actor,
                .kind = .normal,
                .name = name_copy,
                .args = args_copy,
                .transaction_id = new_tx_id,
                .undoable = dr.undo_ref != null,
                .undo_ref = dr.undo_ref,
                .redo_of = target_seq,
                .tx_member_index = applied_count,
                .source = .local,
            });
        }

        // transaction redo の途中失敗規則（MVP）: bundle は試行1回で全消費する
        // （成功/失敗を問わず revert 群全件に redo_consumed=true を立てる。適用済み分は
        // 同一の新 transaction_id を共有するため 1 回の undoOne でまとめて取り消せる）。
        for (members_in) |m| {
            if (log.findBySeq(m.seq)) |live| live.redo_consumed = true;
        }

        if (dispatch_err) |e| return e;
        return .{ .happened = true, .message = writeMsg(buf, "redo ok") };
    }

    /// 後方走査で「actor 一致・kind=revert・!redo_consumed・epoch==現在値・target が現存し reverted の
    /// まま」の最新候補を探し、target を新しい normal command として再実行する。
    pub fn redoOne(self: *Executor, actor: ActorId, buf: []u8) anyerror!RedoOutcome {
        if (actor.eql(.system)) return .{ .happened = false, .message = writeMsg(buf, "no candidate: system actor") };
        const log = self.log orelse return .{ .happened = false, .message = writeMsg(buf, "no candidate: no log") };

        const current_epoch = self.currentEpoch(actor);

        var i: u32 = log.filled;
        while (i > 0) {
            i -= 1;
            const rec = log.recordAt(i);
            if (!rec.actor.eql(actor)) continue;
            if (rec.kind != .revert) continue;
            if (rec.redo_consumed) continue;
            if (rec.epoch != current_epoch) continue;
            const tx_id = rec.transaction_id orelse continue; // 設計上 revert は必ず transaction_id を持つ

            const snap = collectMembers(log, tx_id, .revert) orelse continue; // bundle 不完全なら候補外

            var viable = true;
            for (snap.items[0..snap.count]) |m| {
                const t_seq = m.target_seq orelse {
                    viable = false;
                    break;
                };
                const t = log.findBySeq(t_seq) orelse {
                    viable = false;
                    break;
                };
                if (!t.reverted) {
                    viable = false;
                    break;
                }
            }
            if (!viable) continue;

            var items = snap.items;
            return try self.performRedoBundle(log, actor, items[0..snap.count], buf);
        }
        return .{ .happened = false, .message = writeMsg(buf, "no candidate") };
    }
};

// ============================================================================
// テスト（TASK-62.5.1 plan v1.3 §7。ケース番号はテスト名のプレフィックスで対応）
// ============================================================================

const testing = std.testing;

/// テスト専用の最小 app モック。undoable 判定は名前 "set_tool" のみ非 undoable、それ以外は
/// dispatch のたびに新規 ref を発行して noteUndo する。`fail_on` に一致する名前は dispatch エラー。
const MockApp = struct {
    exec: *Executor = undefined,
    next_ref: u64 = 1,
    /// dispatcher(run) が呼ばれた総回数。「dispatch 前 reject では呼ばれない」ことの観測用。
    run_count: u64 = 0,
    valid: [4096]bool = [_]bool{false} ** 4096,
    fail_on: []const u8 = "",

    fn run(ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
        _ = args;
        const self: *MockApp = @ptrCast(@alignCast(ctx));
        self.run_count += 1;
        if (self.fail_on.len > 0 and std.mem.eql(u8, name, self.fail_on)) {
            return error.Boom;
        }
        if (!std.mem.eql(u8, name, "set_tool")) {
            const ref = self.next_ref;
            self.next_ref += 1;
            self.valid[ref] = true;
            self.exec.noteUndo(ref);
        }
        return writeMsg(buf, "ok");
    }

    fn canUndo(ctx: *anyopaque, rec: *const CommandRecord) bool {
        const self: *MockApp = @ptrCast(@alignCast(ctx));
        const ref = rec.undo_ref orelse return false;
        return ref < self.valid.len and self.valid[ref];
    }

    fn applyUndo(ctx: *anyopaque, rec: *const CommandRecord) void {
        const self: *MockApp = @ptrCast(@alignCast(ctx));
        if (rec.undo_ref) |ref| {
            if (ref < self.valid.len) self.valid[ref] = false;
        }
    }
};

fn wire(app: *MockApp, log: *CommandLog, exec: *Executor) void {
    log.* = .{};
    exec.* = Executor.init(.{ .ctx = app, .run = MockApp.run });
    exec.log = log;
    exec.adapter = .{ .ctx = app, .canUndo = MockApp.canUndo, .applyUndo = MockApp.applyUndo };
    app.* = .{ .exec = exec };
}

fn exec1(exec: *Executor, actor: ActorId, name: []const u8, buf: []u8) !ExecuteResult {
    return exec.executeAction(name, "", .{ .actor = actor }, buf);
}

test "1: actor 混在 undo/redo(親 plan §5.1 例と同値)" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "stroke_a", &buf); // seq1
    _ = try exec1(&exec, .local_agent, "stroke_b", &buf); // seq2
    _ = try exec1(&exec, .local_user, "stroke_c", &buf); // seq3

    const uc1 = try exec.undoOne(.local_user, &buf);
    try testing.expect(uc1.happened);
    try testing.expect(log.findBySeq(3).?.reverted);
    try testing.expect(!log.findBySeq(2).?.reverted);

    const uc2 = try exec.undoOne(.local_user, &buf);
    try testing.expect(uc2.happened);
    try testing.expect(log.findBySeq(1).?.reverted); // B(agent) は skip され A(user) が対象
    try testing.expect(!log.findBySeq(2).?.reverted);

    const a1 = try exec.undoOne(.local_agent, &buf);
    try testing.expect(a1.happened);
    try testing.expect(log.findBySeq(2).?.reverted);
}

test "2: reverted skip(同一対象の二重 undo が起きない)" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "stroke_a", &buf); // seq1

    const uc1 = try exec.undoOne(.local_user, &buf);
    try testing.expect(uc1.happened);
    try testing.expect(log.findBySeq(1).?.reverted);

    const uc2 = try exec.undoOne(.local_user, &buf);
    try testing.expect(!uc2.happened); // 対象が尽きて候補なし
}

test "3: redo 連鎖(親 plan §5.2 例。seq/redo_of/redo_consumed まで assert)" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "a", &buf); // seq1
    _ = try exec1(&exec, .local_user, "b", &buf); // seq2
    _ = try exec1(&exec, .local_user, "c", &buf); // seq3

    _ = try exec.undoOne(.local_user, &buf); // seq4 revert target=3(C)
    _ = try exec.undoOne(.local_user, &buf); // seq5 revert target=2(B)

    try testing.expect(log.findBySeq(3).?.reverted);
    try testing.expect(log.findBySeq(2).?.reverted);

    const r1 = try exec.redoOne(.local_user, &buf); // redo B -> seq6 B' redo_of=2
    try testing.expect(r1.happened);
    const rec6 = log.findBySeq(6).?;
    try testing.expectEqual(@as(?u64, 2), rec6.redo_of);
    try testing.expect(log.findBySeq(5).?.redo_consumed);

    const r2 = try exec.redoOne(.local_user, &buf); // redo C -> seq7 C' redo_of=3
    try testing.expect(r2.happened);
    const rec7 = log.findBySeq(7).?;
    try testing.expectEqual(@as(?u64, 3), rec7.redo_of);
    try testing.expect(log.findBySeq(4).?.redo_consumed);

    const uc3 = try exec.undoOne(.local_user, &buf); // undo C' -> revert target=7
    try testing.expect(uc3.happened);
    try testing.expect(log.findBySeq(7).?.reverted);

    const uc4 = try exec.undoOne(.local_user, &buf); // undo B' -> revert target=6
    try testing.expect(uc4.happened);
    try testing.expect(log.findBySeq(6).?.reverted);
}

test "3b: tx redo の途中失敗(PartialRedo)は bundle を全消費し適用済み分は1回のundoで取り消せる" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    const tx = try exec.beginTransaction(.local_user, "macro");
    _ = try exec.executeAction("m1", "", .{ .actor = .local_user, .transaction = tx }, &buf); // seq1
    _ = try exec.executeAction("m2", "", .{ .actor = .local_user, .transaction = tx }, &buf); // seq2
    try exec.endTransaction(tx, .local_user);

    const u = try exec.undoOne(.local_user, &buf); // revert bundle: target=2,target=1
    try testing.expect(u.happened);
    try testing.expect(log.findBySeq(1).?.reverted);
    try testing.expect(log.findBySeq(2).?.reverted);

    app.fail_on = "m2"; // 2件目の再実行(m2)を失敗させる
    const r = exec.redoOne(.local_user, &buf);
    try testing.expectError(error.PartialRedo, r);

    // bundle は全消費(2件とも redo_consumed=true)。以後 redo 候補なし。
    var count_consumed: u32 = 0;
    var i: u32 = 0;
    while (i < log.filled) : (i += 1) {
        const rec = log.recordAt(i);
        if (rec.kind == .revert and rec.target_seq != null and (rec.target_seq.? == 1 or rec.target_seq.? == 2)) {
            try testing.expect(rec.redo_consumed);
            count_consumed += 1;
        }
    }
    try testing.expectEqual(@as(u32, 2), count_consumed);

    // m1 は再適用され新しい tx の1件として残っている(m2 は失敗し追加されない)
    var applied_new: u32 = 0;
    i = 0;
    while (i < log.filled) : (i += 1) {
        const rec = log.recordAt(i);
        if (rec.kind == .normal and rec.redo_of != null) applied_new += 1;
    }
    try testing.expectEqual(@as(u32, 1), applied_new);

    // 残った1件は undoOne 1回でまとめて取り消せる
    const uc2 = try exec.undoOne(.local_user, &buf);
    try testing.expect(uc2.happened);
}

test "4: epoch 破棄(undo 後の新規 undoable 編集で redo 候補が失効)" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "a", &buf); // seq1
    _ = try exec.undoOne(.local_user, &buf); // revert target=1

    _ = try exec1(&exec, .local_user, "b", &buf); // 新規 undoable 編集 -> epoch bump

    const r = try exec.redoOne(.local_user, &buf);
    try testing.expect(!r.happened); // 失効済みの revert は候補外
}

test "5: redo 由来は epoch 不変(redo B' 直後でも redo C' が可能)" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "a", &buf); // seq1
    _ = try exec1(&exec, .local_user, "b", &buf); // seq2

    _ = try exec.undoOne(.local_user, &buf); // undo b
    _ = try exec.undoOne(.local_user, &buf); // undo a

    const r1 = try exec.redoOne(.local_user, &buf); // redo a (最古の未消費revertから)
    try testing.expect(r1.happened);

    const r2 = try exec.redoOne(.local_user, &buf); // redo b -> bump したら自壊するケース
    try testing.expect(r2.happened);
}

test "6: transaction(非undoable+undoable混在)は undo 1回でstrokeのみ逆適用・revert群が同一tx id" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    const tx = try exec.beginTransaction(.local_user, "macro");
    _ = try exec.executeAction("set_tool", "", .{ .actor = .local_user, .transaction = tx }, &buf); // seq1 非undoable
    _ = try exec.executeAction("stroke", "", .{ .actor = .local_user, .transaction = tx }, &buf); // seq2 undoable
    try exec.endTransaction(tx, .local_user);

    try testing.expect(!log.findBySeq(1).?.undoable);
    try testing.expect(log.findBySeq(2).?.undoable);

    const u = try exec.undoOne(.local_user, &buf);
    try testing.expect(u.happened);
    try testing.expect(!log.findBySeq(1).?.reverted); // 非undoableは対象外のまま
    try testing.expect(log.findBySeq(2).?.reverted);

    // revert record は1件だけ(undoable memberが1件のため)で、その transaction_id を確認
    var revert_tx_id: ?u64 = null;
    var revert_count: u32 = 0;
    var i: u32 = 0;
    while (i < log.filled) : (i += 1) {
        const rec = log.recordAt(i);
        if (rec.kind == .revert) {
            revert_count += 1;
            revert_tx_id = rec.transaction_id;
        }
    }
    try testing.expectEqual(@as(u32, 1), revert_count);
    try testing.expect(revert_tx_id != null);
}

test "7: tx all-or-nothing(canUndo=false を含む tx は skip され次候補へ)" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "solo", &buf); // seq1: 単発undoable(候補予備)

    const tx = try exec.beginTransaction(.local_user, "macro");
    _ = try exec.executeAction("m1", "", .{ .actor = .local_user, .transaction = tx }, &buf); // seq2
    _ = try exec.executeAction("m2", "", .{ .actor = .local_user, .transaction = tx }, &buf); // seq3
    try exec.endTransaction(tx, .local_user);

    // tx の2件目(seq3)の undo_ref を無効化(canUndo=falseにする)
    app.valid[log.findBySeq(3).?.undo_ref.?] = false;

    const u = try exec.undoOne(.local_user, &buf); // tx は all-or-nothing で skip -> seq1(solo)が対象
    try testing.expect(u.happened);
    try testing.expect(log.findBySeq(1).?.reverted);
    try testing.expect(!log.findBySeq(2).?.reverted);
    try testing.expect(!log.findBySeq(3).?.reverted);
}

test "8: リング溢れ(最古が消えると undo/redo 候補にならない)" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "first", &buf); // seq1: これが溢れて消える対象

    var n: usize = 0;
    while (n < MAX_CMD_LOG) : (n += 1) {
        _ = try exec1(&exec, .local_user, "filler", &buf);
    }
    // ring は MAX_CMD_LOG 件で満杯。seq1 は既に溢れて消えている。
    try testing.expect(log.findBySeq(1) == null);

    // seq1 を狙って undo することはできない(そもそも探索対象は最新側からなので、代わりに
    // 「消えた対象は候補にならない」ことを redo 経路で確認する: 直接 undo/redo の一般挙動として
    // 現存する最新の filler は普通に undo できることを確認する。
    const u = try exec.undoOne(.local_user, &buf);
    try testing.expect(u.happened);
}

test "9: リング境界の tx undo(revert append によるスロット進行があっても誤マーク・stale参照なく完了)" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    // log をほぼ満杯にする
    var n: usize = 0;
    while (n < MAX_CMD_LOG - 4) : (n += 1) {
        _ = try exec1(&exec, .local_user, "filler", &buf);
    }

    const tx = try exec.beginTransaction(.local_user, "macro");
    _ = try exec.executeAction("m1", "", .{ .actor = .local_user, .transaction = tx }, &buf);
    _ = try exec.executeAction("m2", "", .{ .actor = .local_user, .transaction = tx }, &buf);
    _ = try exec.executeAction("m3", "", .{ .actor = .local_user, .transaction = tx }, &buf);
    try exec.endTransaction(tx, .local_user);

    const seq_m1 = log.next_seq - 3;
    const seq_m2 = log.next_seq - 2;
    const seq_m3 = log.next_seq - 1;

    const u = try exec.undoOne(.local_user, &buf);
    try testing.expect(u.happened);
    try testing.expect(log.findBySeq(seq_m1).?.reverted);
    try testing.expect(log.findBySeq(seq_m2).?.reverted);
    try testing.expect(log.findBySeq(seq_m3).?.reverted);
}

test "10: remote_commit(seq採用/next_seq前進/重複reject/pending_local_meta.redo_ofでepoch不変)" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "local1", &buf); // seq1
    try testing.expectEqual(@as(u64, 2), log.next_seq);

    // remote_commit で seq=10 を受理 -> next_seq は 11 に前進
    const r = try exec.executeAction("remote1", "", .{ .actor = .{ .peer = 1 }, .source = .{ .remote_commit = .{ .seq = 10 } } }, &buf);
    try testing.expectEqual(@as(?u64, 10), r.seq);
    try testing.expectEqual(@as(u64, 11), log.next_seq);

    // 同一 seq=10 の再配送は dispatch 前に reject（dispatcher 呼出回数が増えない）
    const run_count_before_dup = app.run_count;
    const dup = exec.executeAction("remote1_dup", "", .{ .actor = .{ .peer = 1 }, .source = .{ .remote_commit = .{ .seq = 10 } } }, &buf);
    try testing.expectError(error.StaleRemoteSeq, dup);
    try testing.expectEqual(run_count_before_dup, app.run_count);
    try testing.expect(log.findBySeq(10).?.name_len == "remote1".len); // 記録内容も不変

    // local の以降の採番は 11 から(衝突しない)
    const local2 = try exec1(&exec, .local_user, "local2", &buf);
    try testing.expectEqual(@as(?u64, 11), local2.seq);

    // pending_local_meta.redo_of を伴う remote_commit は epoch を bump しない
    const before_epoch = exec.currentEpoch(.{ .peer = 1 });
    _ = try exec.executeAction("remote_redo", "", .{
        .actor = .{ .peer = 1 },
        .source = .{ .remote_commit = .{ .seq = 20, .pending_local_meta = .{ .redo_of = 10 } } },
    }, &buf);
    try testing.expectEqual(before_epoch, exec.currentEpoch(.{ .peer = 1 }));
}

test "11: record_policy(dry_run/no_record/no-op recorder)いずれも preflight の入力制約は同一に効く" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    const before_filled = log.filled;
    const dry = try exec.executeAction("dry_action", "", .{ .actor = .local_user, .record_policy = .dry_run }, &buf);
    try testing.expectEqual(@as(?u64, null), dry.seq);
    try testing.expectEqual(before_filled, log.filled); // dispatch すらされない -> ref も発行されない
    try testing.expectEqual(@as(u64, 1), app.next_ref);

    const nr = try exec.executeAction("no_record_action", "", .{ .actor = .local_user, .record_policy = .no_record }, &buf);
    try testing.expectEqual(@as(?u64, null), nr.seq);
    try testing.expectEqual(before_filled, log.filled); // dispatch はされるが記録されない
    try testing.expectEqual(@as(u64, 2), app.next_ref);

    // preflight の入力制約(空名)は record_policy によらず同じに効く
    try testing.expectError(error.NameEmpty, exec.executeAction("", "", .{ .actor = .local_user, .record_policy = .dry_run }, &buf));
    try testing.expectError(error.NameEmpty, exec.executeAction("", "", .{ .actor = .local_user, .record_policy = .no_record }, &buf));

    // no-op recorder(log=null)でも同じ制約が効く
    var app2: MockApp = undefined;
    var exec2: Executor = Executor.init(.{ .ctx = &app2, .run = MockApp.run });
    app2 = .{ .exec = &exec2 };
    try testing.expect(exec2.log == null);
    try testing.expectError(error.NameEmpty, exec2.executeAction("", "", .{ .actor = .local_user }, &buf));
    const ok = try exec2.executeAction("ok_action", "", .{ .actor = .local_user }, &buf);
    try testing.expectEqual(@as(?u64, null), ok.seq); // 記録されない(no-op recorder)
    try testing.expectEqual(@as(u64, 2), app2.next_ref); // dispatch 自体はされる(直前の失敗した空名呼び出しは dispatch されていない)
}

test "12: preflight失敗系(空名/name超過/args超過/staleTxHandle/MAX_ACTORS/MAX_OPEN_TX)はdispatchされない" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    try testing.expectError(error.NameEmpty, exec.executeAction("", "", .{ .actor = .local_user }, &buf));
    try testing.expectEqual(@as(u64, 0), app.run_count); // dispatch されていない

    const long_name = [_]u8{'x'} ** (MAX_CMD_NAME + 1);
    try testing.expectError(error.NameTooLong, exec.executeAction(&long_name, "", .{ .actor = .local_user }, &buf));
    try testing.expectEqual(@as(u64, 0), app.run_count);

    var long_args_buf: [MAX_CMD_ARGS + 1]u8 = undefined;
    @memset(&long_args_buf, 'y');
    try testing.expectError(error.ArgsTooLong, exec.executeAction("ok", &long_args_buf, .{ .actor = .local_user }, &buf));
    try testing.expectEqual(@as(u64, 0), app.run_count);

    // stale transaction handle: close 後の generation 不一致
    const tx = try exec.beginTransaction(.local_user, "macro");
    try exec.endTransaction(tx, .local_user);
    try testing.expectError(error.StaleTransactionHandle, exec.executeAction("m", "", .{ .actor = .local_user, .transaction = tx }, &buf));
    try testing.expectEqual(@as(u64, 0), app.run_count);

    // MAX_ACTORS 溢れ（dispatch 前 reject = dispatcher 呼出回数が増えない）
    var i: u32 = 0;
    while (i < MAX_ACTORS) : (i += 1) {
        _ = try exec.executeAction("touch", "", .{ .actor = .{ .peer = i } }, &buf);
    }
    const run_count_full = app.run_count;
    try testing.expectError(error.TooManyActors, exec.executeAction("touch", "", .{ .actor = .{ .peer = 999 } }, &buf));
    try testing.expectEqual(run_count_full, app.run_count);

    // MAX_OPEN_TX 溢れ
    var app2: MockApp = undefined;
    var log2: CommandLog = undefined;
    var exec2: Executor = undefined;
    wire(&app2, &log2, &exec2);
    var handles: [MAX_OPEN_TX]TransactionHandle = undefined;
    var j: usize = 0;
    while (j < MAX_OPEN_TX) : (j += 1) {
        handles[j] = try exec2.beginTransaction(.local_user, "t");
    }
    try testing.expectError(error.TooManyOpenTransactions, exec2.beginTransaction(.local_user, "overflow"));
}

test "12b: next_transaction_id 枯渇時は新規 transaction を reject(fail-stop しない)" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "a", &buf); // 枯渇前に undo/redo 候補を1件用意

    exec.next_transaction_id = std.math.maxInt(u64); // 枯渇状態を再現
    try testing.expectError(error.TransactionIdExhausted, exec.beginTransaction(.local_user, "macro"));

    const u = try exec.undoOne(.local_user, &buf); // revert bundle 用の id が発番できない -> 候補なし扱い
    try testing.expect(!u.happened);
    try testing.expect(!log.findBySeq(1).?.reverted); // 逆適用は行われていない（id 発番は applyUndo より前）
    try testing.expect(app.valid[log.findBySeq(1).?.undo_ref.?]); // UndoRef も消費されていない
}

test "13: noteUndo規則(reentrant拒否/エラー時discard/二重noteUndoはfirst-wins)" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    // reentrant dispatch: dispatcher callback 内から executeAction を呼ぶ
    const ReentrantApp = struct {
        fn run(ctx: *anyopaque, name: []const u8, args: []const u8, b: []u8) anyerror![]const u8 {
            _ = name;
            _ = args;
            const e: *Executor = @ptrCast(@alignCast(ctx));
            var inner_buf: [64]u8 = undefined;
            _ = e.executeAction("inner", "", .{ .actor = .local_user }, &inner_buf) catch |err| {
                return writeMsg(b, @errorName(err));
            };
            return writeMsg(b, "should not reach");
        }
    };
    var exec_r: Executor = undefined;
    exec_r = Executor.init(.{ .ctx = &exec_r, .run = ReentrantApp.run });
    var log_r: CommandLog = .{};
    exec_r.log = &log_r;
    const res = try exec_r.executeAction("outer", "", .{ .actor = .local_user }, &buf);
    try testing.expectEqualStrings("ReentrantDispatch", res.output);

    // dispatch エラー時に pending が discard され次の record を汚染しない:
    // noteUndo で pending をセットした**後に** error を返す dispatcher で失敗させ、
    // 直後の「noteUndo を呼ばない」成功 command が undoable=false（undo_ref=null）で記録されることを確認
    const NoteThenFailApp = struct {
        fn run(ctx: *anyopaque, name: []const u8, args: []const u8, b: []u8) anyerror![]const u8 {
            _ = args;
            const e: *Executor = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "note_then_fail")) {
                e.noteUndo(333); // pending セット後に失敗
                return error.Boom;
            }
            return writeMsg(b, "ok"); // noteUndo なし
        }
    };
    var log_f: CommandLog = .{};
    var exec_f: Executor = undefined;
    exec_f = Executor.init(.{ .ctx = &exec_f, .run = NoteThenFailApp.run });
    exec_f.log = &log_f;
    try testing.expectError(error.Boom, exec_f.executeAction("note_then_fail", "", .{ .actor = .local_user }, &buf));
    const plain = try exec_f.executeAction("plain", "", .{ .actor = .local_user }, &buf);
    const plain_rec = log_f.findBySeq(plain.seq.?).?;
    try testing.expect(!plain_rec.undoable); // discard 済み pending が漏れて undoable 化しない
    try testing.expectEqual(@as(?UndoRef, null), plain_rec.undo_ref);

    // 二重 noteUndo は first-wins
    const DoubleNoteApp = struct {
        fn run(ctx: *anyopaque, name: []const u8, args: []const u8, b: []u8) anyerror![]const u8 {
            _ = name;
            _ = args;
            const e: *Executor = @ptrCast(@alignCast(ctx));
            e.noteUndo(111);
            e.noteUndo(222);
            return writeMsg(b, "ok");
        }
    };
    var log_d: CommandLog = .{};
    var exec_d: Executor = Executor.init(.{ .ctx = undefined, .run = DoubleNoteApp.run });
    exec_d.log = &log_d;
    exec_d.dispatcher.ctx = &exec_d;
    const rd = try exec_d.executeAction("double", "", .{ .actor = .local_user }, &buf);
    try testing.expectEqual(@as(?u64, 1), rd.seq);
    try testing.expectEqual(@as(?UndoRef, 111), log_d.findBySeq(1).?.undo_ref);
}

test "14: undo_ref消滅(canUndo=false)で候補skip(最終防衛)" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "a", &buf); // seq1
    _ = try exec1(&exec, .local_user, "b", &buf); // seq2

    // seq2 の undo_ref を app 側で消す(canUndo=falseになる)
    app.valid[log.findBySeq(2).?.undo_ref.?] = false;

    const u = try exec.undoOne(.local_user, &buf); // seq2 は skip され seq1 が対象
    try testing.expect(u.happened);
    try testing.expect(log.findBySeq(1).?.reverted);
    try testing.expect(!log.findBySeq(2).?.reverted);
}

test "15: 16actor境界(MAX_ACTORS満杯で新actorはpreflight reject・既存actorは影響なし)" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    var i: u32 = 0;
    while (i < MAX_ACTORS) : (i += 1) {
        _ = try exec.executeAction("touch", "", .{ .actor = .{ .peer = i } }, &buf);
    }
    const run_count_full = app.run_count;
    try testing.expectError(error.TooManyActors, exec.executeAction("touch", "", .{ .actor = .{ .peer = 999 } }, &buf));
    try testing.expectEqual(run_count_full, app.run_count); // dispatch 前 reject（dispatcher は呼ばれない）

    // 既存 actor は影響なし
    const r = try exec.executeAction("touch2", "", .{ .actor = .{ .peer = 0 } }, &buf);
    try testing.expect(r.seq != null);
    try testing.expectEqual(run_count_full + 1, app.run_count);
}

test "16: tx部分溢れ(先頭member喪失でtx全体・revert bundle全体が候補外/open中txも候補外)" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    // open 中の tx: member を1件足すが close しない
    const open_tx = try exec.beginTransaction(.local_user, "open");
    _ = try exec.executeAction("open_m1", "", .{ .actor = .local_user, .transaction = open_tx }, &buf);
    const open_seq = log.next_seq - 1;

    const u_open = try exec.undoOne(.local_user, &buf);
    try testing.expect(!u_open.happened); // open 中の member は候補にならない(他に候補もない)
    try testing.expect(!log.findBySeq(open_seq).?.reverted);

    try exec.endTransaction(open_tx, .local_user);

    // 3件 undoable の tx を作り、先頭1件だけをリング溢れで失わせる
    const tx = try exec.beginTransaction(.local_user, "macro3");
    _ = try exec.executeAction("m1", "", .{ .actor = .local_user, .transaction = tx }, &buf);
    const seq_m1 = log.next_seq - 1;
    _ = try exec.executeAction("m2", "", .{ .actor = .local_user, .transaction = tx }, &buf);
    const seq_m2 = log.next_seq - 1;
    _ = try exec.executeAction("m3", "", .{ .actor = .local_user, .transaction = tx }, &buf);
    try exec.endTransaction(tx, .local_user);

    // ここまでの累計 append 数(open_m1 + m1,m2,m3) = 4。非undoable(set_tool)の filler で ring を埋め、
    // 総 append 数が MAX_CMD_LOG+2 になった時点で evicted=2件(open_m1, m1)。m2/m3 は健在のまま。
    // filler を非undoableにするのは「undo 候補として拾われて undo 自体が新たな append を起こし
    // さらなる溢れを連鎖させる」ことを避けるため(non-undoable なので undoOne から常に無視される)。
    var n: usize = 0;
    const filler_count = MAX_CMD_LOG - 4 + 2;
    while (n < filler_count) : (n += 1) {
        _ = try exec.executeAction("set_tool", "", .{ .actor = .local_user }, &buf);
    }
    try testing.expect(log.findBySeq(seq_m1) == null); // 先頭member(m1)は溢れて消えた
    try testing.expect(log.findBySeq(seq_m2) != null); // m2 は健在

    const u = try exec.undoOne(.local_user, &buf); // tx3 は不完全 -> 候補外。filler は非undoableで候補外 -> no candidate
    try testing.expect(!u.happened);
    try testing.expect(!log.findBySeq(seq_m2).?.reverted); // 部分 undo は起きない

    // revert bundle 側の部分溢れ: 完全な小さい tx を undo してから、その revert 群の先頭を溢れさせる
    var app2: MockApp = undefined;
    var log2: CommandLog = undefined;
    var exec2: Executor = undefined;
    wire(&app2, &log2, &exec2);

    const tx2 = try exec2.beginTransaction(.local_user, "macro2");
    _ = try exec2.executeAction("a1", "", .{ .actor = .local_user, .transaction = tx2 }, &buf);
    _ = try exec2.executeAction("a2", "", .{ .actor = .local_user, .transaction = tx2 }, &buf);
    try exec2.endTransaction(tx2, .local_user);

    const uc2 = try exec2.undoOne(.local_user, &buf); // revert bundle(2件)を生成: idx1(target=a2) idx2(target=a1)
    try testing.expect(uc2.happened);

    // 累計 append 数(a1,a2,revert×2) = 4。127件 filler を足すと evicted=3件(a1,a2,revert-idx1)で
    // revert-idx2(target=a1)だけが残る。bundle の序数1(revert-idx1)が消えるので bundle は不完全。
    var n2: usize = 0;
    const filler_count2 = MAX_CMD_LOG - 4 + 3;
    while (n2 < filler_count2) : (n2 += 1) {
        _ = try exec2.executeAction("filler2", "", .{ .actor = .local_user }, &buf);
    }
    const r2 = try exec2.redoOne(.local_user, &buf);
    try testing.expect(!r2.happened);
}
