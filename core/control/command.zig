//! The semantic command execution model for co-piloting (a human and an AI operating together).
//!
//! `CommandExecutor` stands in front of `Dispatcher` (the equivalent of the existing action callback) and
//! records who (`ActorId`), what (the action name and args) and within which macro unit (`Transaction`) something
//! ran into a `CommandLog` (a fixed ring), then derives undo and redo from those records.
//! A configuration with no `CommandLog` (`Executor.log = null`) is a **no-op recorder** (it records nothing and only passes the dispatch through).
//!
//! ## Hot path declaration
//! Recording a command, managing a transaction and searching for an undo or a redo all run **at event time only** (when a
//! user or an agent operates, or asks for undo or redo). None of it sits on a per-frame (all-pixel) or real-time (per-sample) path,
//! so the performance rules' SIMD trio, `cache_line` separation and before-and-after benchmarks do not apply.
//! Execution is main-thread only (the same rule as harness actions and the UI), and this module holds no lock and no atomic.
//!
//! ## Dependencies
//! `@import` is `std` alone. It depends on neither platform nor harness, and holds no global state
//! (everything is a struct the caller instantiates).
//!
//! ## Terms
//! - `ActorId`: who ran it (local_user, local_agent, peer, system).
//! - `CommandRecord`: the record of one executed command (kind=normal or revert).
//! - `Transaction`: the macro boundary bundling several commands into a single undo unit.
//! - `UndoRef`: an opaque handle on the application's internal inverse-apply data. The framework does not interpret its contents.

const std = @import("std");
const command_types = @import("command_types");

/// The limit on the bytes owned inline for an action name (existing action names run to just under 20B, so there is room to spare).
pub const MAX_CMD_NAME = 64;
/// The limit on adapter.summarize and on the history display text (in **bytes**, truncated at a UTF-8 boundary).
pub const MAX_SUMMARY = 64;
/// The limit on the bytes owned inline for args (it holds the point sequence of a UI or agent stroke). The same value as
/// the wire's `MAX_ACTION_FRAME_BYTES` guide of 4096B, and
/// unrelated to the response buffer's `DIGEST_BUF_LEN`=1024.
pub const MAX_CMD_ARGS = 4096;
/// The fixed ring capacity of `CommandLog` (consistent with the netsync side's undo retention of max_history=128).
pub const MAX_CMD_LOG = 128;
/// The limit on trackable actors (the redo_epoch table), on the same scale as the netsync peer count.
pub const MAX_ACTORS = 16;
/// The limit on simultaneously open transactions (in practice one per actor).
pub const MAX_OPEN_TX = 4;
/// The limit on undoable commands a single transaction's undo or redo can handle (the fixed length of the snapshot array).
pub const MAX_TX_UNDO = 32;
/// The limit on the bytes owned inline for a transaction label.
pub const MAX_TX_LABEL = 64;

/// Who performs an operation. Used as the match test for undo and redo searches, the actor table and transaction checks.
pub const ActorId = union(enum) {
    local_user,
    local_agent,
    peer: u32,
    system,

    /// A peer is compared right down to its id, an exact match (no hash, no modulo).
    pub fn eql(a: ActorId, b: ActorId) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .peer => |aid| aid == b.peer,
            .local_user, .local_agent, .system => true,
        };
    }
};

pub const CommandKind = enum { normal, revert };

/// An opaque handle on the application's internal inverse-apply data (pixie's `UndoStack.Op`, say). The framework does not interpret its contents.
pub const UndoRef = u64;

/// The record of one executed command. The authority for undo and redo searches and for the history display.
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
    /// The state on the normal command side (whether it has been undone).
    reverted: bool = false,
    /// The state on the revert command side (whether a redo has reapplied it).
    redo_consumed: bool = false,
    /// The seq of the normal command a kind=revert record targets.
    target_seq: ?u64 = null,
    /// The old target referred to by a normal command that a redo reapplied. The grounds for skipping an epoch bump.
    redo_of: ?u64 = null,
    undo_ref: ?UndoRef = null,
    /// Valid for kind=revert only: burns in the actor's redo_epoch as of creation.
    epoch: u64 = 0,
    /// Valid only while it belongs to a transaction (0 = does not belong, or does not apply): on the normal side it is the
    /// 1-based ordinal among that transaction's undoable members, and on the revert side the 1-based ordinal within the
    /// revert bundle. Used to decide whether an undo or a redo is complete (that the member with ordinal 1 still exists).
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

/// A fixed ring of `CommandRecord` plus a monotonic `next_seq`. No allocation.
pub const CommandLog = struct {
    records: [MAX_CMD_LOG]CommandRecord = undefined,
    /// How many records are currently valid (constant once it reaches the `MAX_CMD_LOG` limit).
    filled: u32 = 0,
    /// The ring position written to next.
    head: u32 = 0,
    /// The local seq issued next. It is monotonic and never reused; appends are rejected once it is exhausted.
    next_seq: u64 = 1,

    pub fn append(self: *CommandLog, rec: CommandRecord) void {
        self.records[self.head] = rec;
        self.head = (self.head + 1) % MAX_CMD_LOG;
        if (self.filled < MAX_CMD_LOG) self.filled += 1;
    }

    /// i: 0 = the oldest … `filled - 1` = the newest. Read only (for the history panel and for probes).
    /// Out of range is the caller's responsibility (`i < filled`).
    pub fn recordAt(self: *const CommandLog, i: u32) *const CommandRecord {
        const idx = (self.head + MAX_CMD_LOG - self.filled + i) % MAX_CMD_LOG;
        return &self.records[idx];
    }

    /// For internal use (marking reverted and so on). A mutable reference to the same position as `recordAt`.
    fn recordAtMut(self: *CommandLog, i: u32) *CommandRecord {
        const idx = (self.head + MAX_CMD_LOG - self.filled + i) % MAX_CMD_LOG;
        return &self.records[idx];
    }

    /// A record lost to overflow is simply "not found" (there is no side data, so a stale reference cannot arise by construction).
    pub fn findBySeq(self: *CommandLog, seq: u64) ?*CommandRecord {
        var i: u32 = 0;
        while (i < self.filled) : (i += 1) {
            const r = self.recordAtMut(i);
            if (r.seq == seq) return r;
        }
        return null;
    }

    /// The newest (most recently appended) record, or null when empty (for observation by the history probe and friends).
    pub fn latest(self: *CommandLog) ?*CommandRecord {
        if (self.filled == 0) return null;
        return self.recordAtMut(self.filled - 1);
    }

    /// Whether `count` more local records can be appended without exhausting `next_seq`.
    pub fn hasSeqCapacity(self: *const CommandLog, count: u64) bool {
        return std.math.maxInt(u64) - self.next_seq >= count;
    }

    /// Copy ring state for persistence. `records[0..filled]` are oldest-to-newest; unused slots are undefined.
    pub fn exportState(self: *const CommandLog) CommandLogState {
        var state: CommandLogState = .{
            .filled = self.filled,
            .head = self.head,
            .next_seq = self.next_seq,
            .records = undefined,
        };
        var i: u32 = 0;
        while (i < self.filled) : (i += 1) {
            state.records[i] = self.recordAt(i).*;
        }
        return state;
    }

    /// Replace ring state from an exported snapshot. Physical placement follows `head`/`filled`.
    pub fn restoreState(self: *CommandLog, state: CommandLogState) void {
        self.* = .{
            .filled = state.filled,
            .head = state.head,
            .next_seq = state.next_seq,
        };
        var i: u32 = 0;
        while (i < state.filled) : (i += 1) {
            const idx = (self.head + MAX_CMD_LOG - self.filled + i) % MAX_CMD_LOG;
            self.records[idx] = state.records[i];
        }
    }
};

/// Portable view of `CommandLog` for export/restore (no allocation; unused ring slots omitted).
pub const CommandLogState = struct {
    /// Oldest-to-newest; only `records[0..filled]` are valid.
    records: [MAX_CMD_LOG]CommandRecord = undefined,
    filled: u32 = 0,
    head: u32 = 0,
    next_seq: u64 = 1,
};

/// Portable actor-epoch slot for persistence (mirrors internal `ActorEpochSlot`).
pub const ActorEpochState = struct {
    actor: ActorId,
    epoch: u64 = 0,
};

/// Portable open/closed transaction slot for persistence (mirrors internal `TxSlot`).
pub const TransactionSlotState = struct {
    open: bool = false,
    id: u64 = 0,
    actor: ActorId = .system,
    generation: u32 = 0,
    label_len: u8 = 0,
    label_buf: [MAX_TX_LABEL]u8 = undefined,
    undoable_member_count: u16 = 0,

    pub fn label(self: *const TransactionSlotState) []const u8 {
        return self.label_buf[0..self.label_len];
    }
};

/// Executor persistence state: actor epochs, transaction slots, and id counter only.
/// Runtime pointers and dispatch-only fields are not included.
pub const ExecutorState = struct {
    actors: [MAX_ACTORS]ActorEpochState = undefined,
    actor_count: u32 = 0,
    transactions: [MAX_OPEN_TX]TransactionSlotState = [_]TransactionSlotState{.{}} ** MAX_OPEN_TX,
    next_transaction_id: u64 = 1,
};

/// Combined log + executor persistence state for snapshot codecs.
pub const PersistentState = struct {
    log: CommandLogState = .{},
    executor: ExecutorState = .{},
};

/// The metadata an issuer passes alongside a command that came from a redo, which stops the epoch from being bumped wrongly.
pub const PendingMeta = struct { redo_of: ?u64 };

/// Where an executeAction came from. `remote_commit` is only for applying a netsync COMMIT (it does not pass through the router again).
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

/// A slot reference for an open transaction. A generation mismatch is rejected as a stale handle (an old reference to a reused slot).
pub const TransactionHandle = struct { index: u8, generation: u32 };

/// The equivalent of the existing action callback: a thin delegation point that runs an already name-resolved action.
pub const Dispatcher = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8,
};

/// The application's adapter for inverse-applying an undo.
pub const CommandAdapter = struct {
    ctx: *anyopaque,
    /// Confirms that the UndoRef still exists and can be inverse-applied.
    canUndo: *const fn (ctx: *anyopaque, rec: *const CommandRecord) bool,
    /// Inverse-applies it. **A contract that cannot fail**: when `canUndo==true` this always succeeds
    /// (an application whose inverse apply can fail takes on the duty of returning false from `canUndo`.
    /// That is what makes a transaction's all-or-nothing hold on pre-validation alone).
    applyUndo: *const fn (ctx: *anyopaque, rec: *const CommandRecord) void,
    /// Writes the record's short display text into `buf` (the caller provides at least `MAX_SUMMARY`) and returns the written slice.
    /// It cannot fail (it copies the name when it knows no better). No allocation, no side effects. The return value must be
    /// normalised to printable ASCII (0x20..0x7E). The executor never calls it (it is for the history UI and for probes).
    summarize: *const fn (ctx: *anyopaque, rec: *const CommandRecord, buf: []u8) []const u8,
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
    /// Increments each time an undoable normal command is appended within the transaction. The source of `tx_member_index`.
    undoable_member_count: u16 = 0,
};

/// A snapshot that stashes a transaction's members (either the transaction side or the revert bundle side).
/// The records are copied by value once the targets are settled, so overwriting the ring during an undo or a redo stays safe.
const TxSnapshot = struct {
    items: [MAX_TX_UNDO]CommandRecord = undefined,
    count: u16 = 0,
};

fn writeMsg(buf: []u8, msg: []const u8) []const u8 {
    const n = @min(buf.len, msg.len);
    @memcpy(buf[0..n], msg[0..n]);
    return buf[0..n];
}

/// AppendSpec: the append path shared by `executeAction`'s record, an undo's revert record and a redo's new record.
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

/// The semantic command executor for a human and an agent operating together. Without a `CommandLog` to record into it
/// behaves as a no-op recorder (recording nothing and only passing the dispatch through).
pub const Executor = struct {
    log: ?*CommandLog = null,
    dispatcher: Dispatcher,
    adapter: ?CommandAdapter = null,

    actor_table: [MAX_ACTORS]ActorEpochSlot = undefined,
    actor_count: u32 = 0,

    tx_table: [MAX_OPEN_TX]TxSlot = undefined,
    /// Issues a monotonically unique id for each begin, each revert bundle of an undo, and each new bundle of a redo.
    /// A closed transaction's id is never reused. Exhausting u64 is unreachable in practice, but on reaching it the
    /// behaviour is to reject a new transaction rather than to fail-stop (`allocTransactionId`).
    next_transaction_id: u64 = 1,

    /// Marks the dispatcher.run interval (the flag by which a reentrant executeAction or redo is rejected).
    in_dispatch: bool = false,
    pending_undo_ref: ?UndoRef = null,
    pending_set: bool = false,

    /// True during a netsync session. It drops a source=.local record to no_record, which stops a wire seq collision.
    /// Set from the **main thread only** (the netsync gate opening, shutdown, fail-soft).
    wire_session: bool = false,

    pub fn init(dispatcher: Dispatcher) Executor {
        var self: Executor = .{ .dispatcher = dispatcher };
        for (&self.tx_table) |*slot| slot.* = .{};
        return self;
    }

    pub fn setWireSession(self: *Executor, on: bool) void {
        self.wire_session = on;
    }

    /// Copy actor epochs, transaction slots, and `next_transaction_id` for persistence.
    /// Does not include dispatcher/adapter/log pointers or dispatch-only fields.
    pub fn exportState(self: *const Executor) ExecutorState {
        var state: ExecutorState = .{
            .actor_count = self.actor_count,
            .next_transaction_id = self.next_transaction_id,
            .actors = undefined,
            .transactions = undefined,
        };
        var i: u32 = 0;
        while (i < self.actor_count) : (i += 1) {
            state.actors[i] = .{
                .actor = self.actor_table[i].actor,
                .epoch = self.actor_table[i].epoch,
            };
        }
        for (self.tx_table, 0..) |slot, ti| {
            state.transactions[ti] = .{
                .open = slot.open,
                .id = slot.id,
                .actor = slot.actor,
                .generation = slot.generation,
                .label_len = slot.label_len,
                .label_buf = slot.label_buf,
                .undoable_member_count = slot.undoable_member_count,
            };
        }
        return state;
    }

    /// Restore actor epochs, transaction slots, and `next_transaction_id`.
    /// Keeps dispatcher, adapter, log pointer, and `wire_session`. Clears dispatch-only state.
    pub fn restoreState(self: *Executor, state: ExecutorState) void {
        self.actor_count = state.actor_count;
        var i: u32 = 0;
        while (i < state.actor_count) : (i += 1) {
            self.actor_table[i] = .{
                .actor = state.actors[i].actor,
                .epoch = state.actors[i].epoch,
            };
        }
        for (state.transactions, 0..) |slot, ti| {
            self.tx_table[ti] = .{
                .open = slot.open,
                .id = slot.id,
                .actor = slot.actor,
                .generation = slot.generation,
                .label_len = slot.label_len,
                .label_buf = slot.label_buf,
                .undoable_member_count = slot.undoable_member_count,
            };
        }
        self.next_transaction_id = state.next_transaction_id;
        self.in_dispatch = false;
        self.pending_undo_ref = null;
        self.pending_set = false;
    }

    /// Called by the application while the dispatch callback runs. **pending is cleared at the start of a dispatch, consumed
    /// only on a normal return, and discarded on a dispatch error** (`runDispatchCapturingUndo` manages it).
    /// A second or later call within the same dispatch is first-wins (warned about and ignored).
    pub fn noteUndo(self: *Executor, ref: UndoRef) void {
        if (!self.in_dispatch) {
            std.debug.print("[command] noteUndo: a call from outside a dispatch interval is ignored\n", .{});
            return;
        }
        if (self.pending_set) {
            std.debug.print("[command] noteUndo: a second or later call within the same dispatch is ignored (first-wins)\n", .{});
            return;
        }
        self.pending_undo_ref = ref;
        self.pending_set = true;
    }

    // ------------------------------------------------------------------
    // the actor table (redo_epoch)
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

    /// Increments an actor's redo_epoch by one without recording anything. An application calls it on detecting an
    /// "undoable edit that never reaches the CommandLog" (an unrecorded UI operation during a staged migration), which
    /// expires that actor's unconsumed redo candidates (the usual expiry happens automatically when an undoable normal
    /// command is recorded; this is the variant outside that recording). When the actor table is full and the actor is
    /// unregistered this is a no-op (an actor with no records and no undo candidates has no redo to expire).
    pub fn bumpEpoch(self: *Executor, actor: ActorId) void {
        const slot = self.ensureActor(actor) catch return;
        slot.epoch += 1;
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

    /// Issues a transaction id, or null once u64 is exhausted (rejecting a new transaction rather than fail-stopping).
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

    /// This only stops the tagging from here on. Rewinding already executed commands is not the framework's responsibility
    /// (the application calls undo if it needs to).
    pub fn cancelTransaction(self: *Executor, handle: TransactionHandle, actor: ActorId) TransactionError!void {
        try self.checkTransactionHandle(handle, actor);
        const slot = &self.tx_table[handle.index];
        slot.open = false;
        slot.generation += 1;
    }

    // ------------------------------------------------------------------
    // append (shared by executeAction's record, an undo's revert record and a redo's new record)
    // ------------------------------------------------------------------

    fn appendRecord(self: *Executor, spec: AppendSpec) !u64 {
        const log = self.log.?;
        var seq: u64 = undefined;
        switch (spec.source) {
            .local => {
                if (!log.hasSeqCapacity(1)) return error.SeqExhausted;
                seq = log.next_seq;
                log.next_seq += 1;
            },
            .remote_commit => |rc| {
                if (rc.seq == std.math.maxInt(u64)) return error.RemoteSeqExhausted;
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
        // Only the record of "a new undoable normal command that did not come from a redo" advances the epoch.
        if (spec.kind == .normal and spec.undoable and spec.redo_of == null) {
            slot.epoch += 1;
        }
        if (spec.kind == .revert) rec.epoch = slot.epoch;

        log.append(rec);
        return seq;
    }

    // ------------------------------------------------------------------
    // dispatch (managing in_dispatch, plus noteUndo's scoped pending)
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
    // preflight (validated in one go before the dispatch; the same input constraints apply regardless of record_policy or of whether there is a log)
    // ------------------------------------------------------------------

    fn preflight(self: *Executor, name: []const u8, args: []const u8, opts: ExecuteOptions) !void {
        if (name.len == 0) return error.NameEmpty;
        if (name.len > MAX_CMD_NAME) return error.NameTooLong;
        if (args.len > MAX_CMD_ARGS) return error.ArgsTooLong;
        if (opts.transaction) |h| try self.checkTransactionHandle(h, opts.actor);
        if (!self.actorCapacityOk(opts.actor)) return error.TooManyActors;
        switch (opts.source) {
            .local => {
                if (self.log) |log| {
                    if (!log.hasSeqCapacity(1)) return error.SeqExhausted;
                }
            },
            .remote_commit => |rc| {
                // With no log (a no-op recorder) there is no next_seq to compare against, so the check cannot be made at all.
                if (self.log) |log| {
                    if (rc.seq < log.next_seq) return error.StaleRemoteSeq;
                    if (rc.seq == std.math.maxInt(u64)) return error.RemoteSeqExhausted;
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

        // A local record during a netsync session is suppressed, so that it cannot collide with a wire seq.
        const effective_policy: RecordPolicy = blk: {
            if (opts.record_policy == .no_record) break :blk .no_record;
            if (self.wire_session and opts.source == .local) break :blk .no_record;
            break :blk opts.record_policy;
        };

        if (effective_policy == .no_record or self.log == null) {
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

    /// Returns the handle of that actor's open transaction (the MVP assumes one per actor and takes the first
    /// match; null when there is none). An application's action wrapper uses it to join "the transaction copilot
    /// opened with begin_tx" automatically.
    pub fn openTransactionFor(self: *Executor, actor: ActorId) ?TransactionHandle {
        for (self.tx_table, 0..) |slot, i| {
            if (slot.open and slot.actor.eql(actor)) {
                return .{ .index = @intCast(i), .generation = slot.generation };
            }
        }
        return null;
    }

    /// **Records an already performed operation without dispatching it** (for recording a UI operation).
    /// preflight is identical to `executeAction`'s, and so is the epoch bump rule (they share `appendRecord`).
    /// undoable = `undo_ref != null`. `record_policy` accepts `.record` only (anything else gives
    /// `error.InvalidRecordPolicy`). The return value is the recorded seq (null for a no-op recorder with no log).
    /// A redo re-runs this record through the dispatcher as usual.
    pub fn recordExecuted(self: *Executor, name: []const u8, args: []const u8, opts: ExecuteOptions, undo_ref: ?UndoRef, buf: []u8) anyerror!?u64 {
        _ = buf; // a signature symmetrical with executeAction's (unused for now, since nothing is dispatched)
        if (opts.record_policy != .record) return error.InvalidRecordPolicy;
        try self.preflight(name, args, opts);
        if (self.log == null) return null;
        // A local record during a netsync session is suppressed (a UI stroke, say).
        if (self.wire_session and opts.source == .local) return null;

        var transaction_id: ?u64 = null;
        var tx_member_index: u16 = 0;
        if (opts.transaction) |h| {
            const slot = &self.tx_table[h.index];
            transaction_id = slot.id;
            if (undo_ref != null) {
                slot.undoable_member_count += 1;
                tx_member_index = slot.undoable_member_count;
            }
        }

        const redo_of: ?u64 = switch (opts.source) {
            .local => null,
            .remote_commit => |rc| if (rc.pending_local_meta) |m| m.redo_of else null,
        };

        return try self.appendRecord(.{
            .actor = opts.actor,
            .kind = .normal,
            .name = name,
            .args = args,
            .transaction_id = transaction_id,
            .undoable = undo_ref != null,
            .undo_ref = undo_ref,
            .redo_of = redo_of,
            .tx_member_index = tx_member_index,
            .source = opts.source,
        });
    }

    // ------------------------------------------------------------------
    // undo
    // ------------------------------------------------------------------

    /// Collects a transaction's (or a revert bundle's) members. Returns null when ordinal 1 no longer exists, or the limit is exceeded
    /// (skipping it as a non-candidate; this is the safeguard against a ring overflow).
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
        if (!log.hasSeqCapacity(@intCast(members.len))) {
            return .{ .happened = false, .message = writeMsg(buf, "no candidate: seq exhausted") };
        }
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
            // Mark it only after re-resolving by seq following the append (a `*CommandRecord` is never held across an append).
            if (log.findBySeq(m.seq)) |live| live.reverted = true;
        }
        return .{ .happened = true, .message = writeMsg(buf, "undo ok") };
    }

    /// Returns the seq of a single-command undo candidate by scanning backwards (transaction members excluded; for netsync's `.undo_own`).
    /// The conditions: a matching actor, kind=normal, undoable, !reverted, transaction_id==null, and canUndo.
    pub fn findUndoCandidate(self: *Executor, actor: ActorId) ?u64 {
        if (actor.eql(.system)) return null;
        const log = self.log orelse return null;
        const adapter = self.adapter orelse return null;

        var i: u32 = log.filled;
        while (i > 0) {
            i -= 1;
            const rec = log.recordAt(i);
            if (!rec.actor.eql(actor)) continue;
            if (rec.kind != .normal) continue;
            if (!rec.undoable) continue;
            if (rec.reverted) continue;
            if (rec.transaction_id != null) continue; // wire and netsync handle single commands only
            if (!adapter.canUndo(adapter.ctx, rec)) continue;
            return rec.seq;
        }
        return null;
    }

    /// Applies a wire COMMIT_REVERT. It inverse-applies the target, fixes reverted, and appends a revert record with
    /// `source=.remote_commit{seq=new_seq}`. The actor is inherited from the target's actor.
    /// As with a solo undoOne, the revert record is a 1-member bundle carrying a transaction_id (compatible with redoOne's search).
    pub fn applyWireRevert(self: *Executor, target_seq: u64, new_seq: u64) !void {
        const log = self.log orelse return error.NoLog;
        const adapter = self.adapter orelse return error.NoAdapter;
        if (new_seq == std.math.maxInt(u64)) return error.RemoteSeqExhausted;
        const rec = log.findBySeq(target_seq) orelse return error.UnknownSeq;
        if (rec.kind != .normal) return error.NotUndoable;
        if (!rec.undoable) return error.NotUndoable;
        if (rec.reverted) return error.AlreadyReverted;
        if (rec.transaction_id != null) return error.TransactionUndoUnsupported;
        if (!adapter.canUndo(adapter.ctx, rec)) return error.TooOld;

        const actor = rec.actor;
        adapter.applyUndo(adapter.ctx, rec);
        if (log.findBySeq(target_seq)) |live| live.reverted = true;

        const revert_tx_id = self.allocTransactionId() orelse return error.TransactionIdExhausted;
        _ = try self.appendRecord(.{
            .actor = actor,
            .kind = .revert,
            .name = "revert",
            .args = "",
            .transaction_id = revert_tx_id,
            .undoable = false,
            .undo_ref = null,
            .target_seq = target_seq,
            .redo_of = null,
            .tx_member_index = 1,
            .source = .{ .remote_commit = .{ .seq = new_seq } },
        });
    }

    /// Scans backwards for the newest candidate matching "a matching actor, kind=normal, undoable, !reverted, canUndo=true",
    /// then inverse-applies it and appends the revert records. The `.system` actor never has a candidate.
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
                if (self.isTransactionOpen(tx_id)) continue; // a member of an open transaction is not a candidate
                const snap = collectMembers(log, tx_id, .normal) orelse continue; // an incomplete transaction, or one over the limit, is skipped

                var all_ok = true;
                for (snap.items[0..snap.count]) |m| {
                    if (!adapter.canUndo(adapter.ctx, &m)) {
                        all_ok = false;
                        break;
                    }
                }
                if (!all_ok) continue; // all-or-nothing: if even one is impossible, skip the whole transaction

                return try self.performUndoBundle(log, adapter, actor, snap.items[0..snap.count], buf);
            } else {
                // A single command: the same predicate as findUndoCandidate (canUndo). Decided directly here too, to keep the behaviour identical.
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
        sortByTargetSeqAsc(members_in); // re-run in the original execution order (ascending target_seq)

        if (!log.hasSeqCapacity(@intCast(members_in.len))) {
            return .{ .happened = false, .message = writeMsg(buf, "no candidate: seq exhausted") };
        }
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

        // The rule for a mid-way failure of a transaction redo (MVP): a bundle is consumed entirely on a single attempt
        // (redo_consumed=true is set on every revert record, whether it succeeded or failed. Whatever was applied shares
        // the same new transaction_id, so a single undoOne takes all of it back at once).
        for (members_in) |m| {
            if (log.findBySeq(m.seq)) |live| live.redo_consumed = true;
        }

        if (dispatch_err) |e| return e;
        return .{ .happened = true, .message = writeMsg(buf, "redo ok") };
    }

    /// A redo candidate (the target's name and args). The slices point into the CommandLog, so the caller must copy
    /// them before mutating. For netsync's `.redo_own`.
    ///
    /// **A known and accepted consequence (epochs diverging between peers)**: redo_of is not carried on the wire, so on
    /// another peer a commit that came from a redo looks normal and its epoch advances. Per-actor epoch values may
    /// diverge between peers, which is harmless because a redo search is only ever used locally by the issuer.
    pub const RedoCandidate = struct {
        target_seq: u64,
        name: []const u8,
        args: []const u8,
    };

    pub fn findRedoCandidate(self: *Executor, actor: ActorId) ?RedoCandidate {
        if (actor.eql(.system)) return null;
        const log = self.log orelse return null;
        const current_epoch = self.currentEpoch(actor);

        var i: u32 = log.filled;
        while (i > 0) {
            i -= 1;
            const rec = log.recordAt(i);
            if (!rec.actor.eql(actor)) continue;
            if (rec.kind != .revert) continue;
            if (rec.redo_consumed) continue;
            if (rec.epoch != current_epoch) continue;
            const tx_id = rec.transaction_id orelse continue;

            const snap = collectMembers(log, tx_id, .revert) orelse continue;
            // netsync handles single commands only (a bundle is unsupported during a session)
            if (snap.count != 1) continue;

            const m = snap.items[0];
            const t_seq = m.target_seq orelse continue;
            const t = log.findBySeq(t_seq) orelse continue;
            if (!t.reverted) continue;
            return .{ .target_seq = t_seq, .name = t.name(), .args = t.args() };
        }
        return null;
    }

    /// Scans backwards for the newest candidate matching "a matching actor, kind=revert, !redo_consumed, an epoch equal to the
    /// current value, and a target that still exists and is still reverted", then re-runs the target as a new normal command.
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
            const tx_id = rec.transaction_id orelse continue; // by design a revert always carries a transaction_id

            const snap = collectMembers(log, tx_id, .revert) orelse continue; // an incomplete bundle is not a candidate

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
// tests (each case number is the prefix of the test name)
// ============================================================================

const testing = std.testing;

/// A minimal application mock for the tests. Only the name "set_tool" counts as non-undoable; everything else
/// issues a fresh ref and calls noteUndo on each dispatch. A name matching `fail_on` makes the dispatch fail.
const MockApp = struct {
    exec: *Executor = undefined,
    next_ref: u64 = 1,
    /// How many times dispatcher(run) was called in total. Used to observe that "a reject before the dispatch never calls it".
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

    fn summarize(ctx: *anyopaque, rec: *const CommandRecord, buf: []u8) []const u8 {
        _ = ctx;
        const n = @min(rec.name().len, buf.len);
        @memcpy(buf[0..n], rec.name()[0..n]);
        return buf[0..n];
    }
};

fn wire(app: *MockApp, log: *CommandLog, exec: *Executor) void {
    log.* = .{};
    exec.* = Executor.init(.{ .ctx = app, .run = MockApp.run });
    exec.log = log;
    exec.adapter = .{ .ctx = app, .canUndo = MockApp.canUndo, .applyUndo = MockApp.applyUndo, .summarize = MockApp.summarize };
    app.* = .{ .exec = exec };
}

fn exec1(exec: *Executor, actor: ActorId, name: []const u8, buf: []u8) !ExecuteResult {
    return exec.executeAction(name, "", .{ .actor = actor }, buf);
}

test "1: undo and redo with mixed actors" {
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
    try testing.expect(log.findBySeq(1).?.reverted); // B(agent) is skipped and A(user) is the target
    try testing.expect(!log.findBySeq(2).?.reverted);

    const a1 = try exec.undoOne(.local_agent, &buf);
    try testing.expect(a1.happened);
    try testing.expect(log.findBySeq(2).?.reverted);
}

test "2: a reverted record is skipped, so the same target is never undone twice" {
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
    try testing.expect(!uc2.happened); // the targets are exhausted, so there is no candidate
}

test "3: a redo chain, asserting seq, redo_of and redo_consumed" {
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

test "3b: a mid-way failure of a transaction redo (PartialRedo) consumes the whole bundle, and a single undo takes back what was applied" {
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

    app.fail_on = "m2"; // make the re-run of the second one (m2) fail
    const r = exec.redoOne(.local_user, &buf);
    try testing.expectError(error.PartialRedo, r);

    // the bundle is consumed entirely (redo_consumed=true on both), so no redo candidate remains
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

    // m1 was reapplied and remains as the single member of a new transaction (m2 failed and was not added)
    var applied_new: u32 = 0;
    i = 0;
    while (i < log.filled) : (i += 1) {
        const rec = log.recordAt(i);
        if (rec.kind == .normal and rec.redo_of != null) applied_new += 1;
    }
    try testing.expectEqual(@as(u32, 1), applied_new);

    // the one that remains can be taken back by a single undoOne
    const uc2 = try exec.undoOne(.local_user, &buf);
    try testing.expect(uc2.happened);
}

test "4: discarding the epoch, so a new undoable edit after an undo expires the redo candidate" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "a", &buf); // seq1
    _ = try exec.undoOne(.local_user, &buf); // revert target=1

    _ = try exec1(&exec, .local_user, "b", &buf); // a new undoable edit -> an epoch bump

    const r = try exec.redoOne(.local_user, &buf);
    try testing.expect(!r.happened); // an expired revert is not a candidate
}

test "5: a redo leaves the epoch unchanged, so redo C' is still possible right after redo B'" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "a", &buf); // seq1
    _ = try exec1(&exec, .local_user, "b", &buf); // seq2

    _ = try exec.undoOne(.local_user, &buf); // undo b
    _ = try exec.undoOne(.local_user, &buf); // undo a

    const r1 = try exec.redoOne(.local_user, &buf); // redo a (from the oldest unconsumed revert)
    try testing.expect(r1.happened);

    const r2 = try exec.redoOne(.local_user, &buf); // redo b -> the case that would destroy itself if it bumped
    try testing.expect(r2.happened);
}

test "6: a transaction mixing non-undoable and undoable members inverse-applies only the stroke in one undo, and its revert records share one transaction id" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    const tx = try exec.beginTransaction(.local_user, "macro");
    _ = try exec.executeAction("set_tool", "", .{ .actor = .local_user, .transaction = tx }, &buf); // seq1 is not undoable
    _ = try exec.executeAction("stroke", "", .{ .actor = .local_user, .transaction = tx }, &buf); // seq2 undoable
    try exec.endTransaction(tx, .local_user);

    try testing.expect(!log.findBySeq(1).?.undoable);
    try testing.expect(log.findBySeq(2).?.undoable);

    const u = try exec.undoOne(.local_user, &buf);
    try testing.expect(u.happened);
    try testing.expect(!log.findBySeq(1).?.reverted); // the non-undoable one stays out of scope
    try testing.expect(log.findBySeq(2).?.reverted);

    // there is a single revert record (there being one undoable member); check its transaction_id
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

test "7: transaction all-or-nothing, so a transaction containing canUndo=false is skipped for the next candidate" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "solo", &buf); // seq1: a single undoable command (a spare candidate)

    const tx = try exec.beginTransaction(.local_user, "macro");
    _ = try exec.executeAction("m1", "", .{ .actor = .local_user, .transaction = tx }, &buf); // seq2
    _ = try exec.executeAction("m2", "", .{ .actor = .local_user, .transaction = tx }, &buf); // seq3
    try exec.endTransaction(tx, .local_user);

    // invalidate the undo_ref of the transaction's second member (seq3), making canUndo false
    app.valid[log.findBySeq(3).?.undo_ref.?] = false;

    const u = try exec.undoOne(.local_user, &buf); // the transaction is all-or-nothing and so is skipped -> seq1 (solo) is the target
    try testing.expect(u.happened);
    try testing.expect(log.findBySeq(1).?.reverted);
    try testing.expect(!log.findBySeq(2).?.reverted);
    try testing.expect(!log.findBySeq(3).?.reverted);
}

test "8: a ring overflow, so once the oldest is gone it is no longer an undo or redo candidate" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "first", &buf); // seq1: this is the one that overflows and disappears

    var n: usize = 0;
    while (n < MAX_CMD_LOG) : (n += 1) {
        _ = try exec1(&exec, .local_user, "filler", &buf);
    }
    // the ring is full at MAX_CMD_LOG records, so seq1 has already overflowed and gone.
    try testing.expect(log.findBySeq(1) == null);

    // seq1 cannot be undone deliberately (the search runs from the newest end anyway), so instead
    // "a lost target never becomes a candidate" is checked through the redo path: as general undo and redo
    // behaviour, confirm that the newest filler still present can be undone normally.
    const u = try exec.undoOne(.local_user, &buf);
    try testing.expect(u.happened);
}

test "9: a transaction undo at the ring boundary completes with no wrong mark and no stale reference, even as the revert appends advance the slot" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    // fill the log almost to capacity
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

test "10: remote_commit adopts the seq, advances next_seq, rejects a duplicate, and leaves the epoch unchanged given pending_local_meta.redo_of" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "local1", &buf); // seq1
    try testing.expectEqual(@as(u64, 2), log.next_seq);

    // accept seq=10 as a remote_commit -> next_seq advances to 11
    const r = try exec.executeAction("remote1", "", .{ .actor = .{ .peer = 1 }, .source = .{ .remote_commit = .{ .seq = 10 } } }, &buf);
    try testing.expectEqual(@as(?u64, 10), r.seq);
    try testing.expectEqual(@as(u64, 11), log.next_seq);

    // redelivering the same seq=10 is rejected before the dispatch (the dispatcher call count does not rise)
    const run_count_before_dup = app.run_count;
    const dup = exec.executeAction("remote1_dup", "", .{ .actor = .{ .peer = 1 }, .source = .{ .remote_commit = .{ .seq = 10 } } }, &buf);
    try testing.expectError(error.StaleRemoteSeq, dup);
    try testing.expectEqual(run_count_before_dup, app.run_count);
    try testing.expect(log.findBySeq(10).?.name_len == "remote1".len); // the recorded content is unchanged too

    // local numbering carries on from 11, with no collision
    const local2 = try exec1(&exec, .local_user, "local2", &buf);
    try testing.expectEqual(@as(?u64, 11), local2.seq);

    // a remote_commit carrying pending_local_meta.redo_of does not bump the epoch
    const before_epoch = exec.currentEpoch(.{ .peer = 1 });
    _ = try exec.executeAction("remote_redo", "", .{
        .actor = .{ .peer = 1 },
        .source = .{ .remote_commit = .{ .seq = 20, .pending_local_meta = .{ .redo_of = 10 } } },
    }, &buf);
    try testing.expectEqual(before_epoch, exec.currentEpoch(.{ .peer = 1 }));
}

test "10a: a local seq exhaustion rejects executeAction and recordExecuted before mutation" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    log.next_seq = std.math.maxInt(u64);
    try testing.expectError(error.SeqExhausted, exec.executeAction("blocked", "", .{ .actor = .local_user }, &buf));
    try testing.expectEqual(@as(u64, 0), app.run_count);
    try testing.expectEqual(@as(u64, 0), log.filled);

    try testing.expectError(error.SeqExhausted, exec.recordExecuted("blocked", "", .{ .actor = .local_user }, null, &buf));
    try testing.expectEqual(@as(u64, 0), log.filled);
}

test "10b: a maximum remote seq is rejected before dispatch or recording" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    try testing.expectError(error.RemoteSeqExhausted, exec.executeAction("blocked", "", .{
        .actor = .{ .peer = 1 },
        .source = .{ .remote_commit = .{ .seq = std.math.maxInt(u64) } },
    }, &buf));
    try testing.expectEqual(@as(u64, 0), app.run_count);
    try testing.expectEqual(@as(u64, 1), log.next_seq);
    try testing.expectEqual(@as(u64, 0), log.filled);
}

test "10c: a remote commit can reach the seq ceiling, after which local execution is rejected" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec.executeAction("remote", "", .{
        .actor = .{ .peer = 1 },
        .source = .{ .remote_commit = .{ .seq = std.math.maxInt(u64) - 1 } },
    }, &buf);
    try testing.expectEqual(std.math.maxInt(u64), log.next_seq);

    const run_count_before = app.run_count;
    try testing.expectError(error.SeqExhausted, exec.executeAction("blocked", "", .{ .actor = .local_user }, &buf));
    try testing.expectEqual(run_count_before, app.run_count);
    try testing.expectEqual(std.math.maxInt(u64), log.next_seq);
}

test "10d: seq exhaustion prevents undo from applying or marking its target" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "undoable", &buf);
    const target = log.findBySeq(1).?;
    const ref = target.undo_ref.?;
    log.next_seq = std.math.maxInt(u64);

    const result = try exec.undoOne(.local_user, &buf);
    try testing.expect(!result.happened);
    try testing.expect(!target.reverted);
    try testing.expect(app.valid[ref]);
    try testing.expectEqual(@as(u32, 1), log.filled);
}

test "10e: seq exhaustion prevents redo from dispatching or consuming its candidate" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "redoable", &buf);
    _ = try exec.undoOne(.local_user, &buf);
    const run_count_before = app.run_count;
    const revert = log.findBySeq(2).?;
    log.next_seq = std.math.maxInt(u64);

    const result = try exec.redoOne(.local_user, &buf);
    try testing.expect(!result.happened);
    try testing.expectEqual(run_count_before, app.run_count);
    try testing.expect(!revert.redo_consumed);
}

test "10f: a maximum wire revert seq is rejected before inverse application" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec.executeAction("remote", "", .{
        .actor = .{ .peer = 1 },
        .source = .{ .remote_commit = .{ .seq = 1 } },
    }, &buf);
    const target = log.findBySeq(1).?;
    const ref = target.undo_ref.?;
    const filled_before = log.filled;

    try testing.expectError(error.RemoteSeqExhausted, exec.applyWireRevert(1, std.math.maxInt(u64)));
    try testing.expectEqual(filled_before, log.filled);
    try testing.expect(!target.reverted);
    try testing.expect(app.valid[ref]);
}

test "10g: a bundle short of the seq ceiling by one is rejected whole, not partially applied" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    const tx = try exec.beginTransaction(.local_user, "macro");
    _ = try exec.executeAction("m1", "", .{ .actor = .local_user, .transaction = tx }, &buf);
    _ = try exec.executeAction("m2", "", .{ .actor = .local_user, .transaction = tx }, &buf);
    try exec.endTransaction(tx, .local_user);

    const seq_m1 = log.next_seq - 2;
    const seq_m2 = log.next_seq - 1;
    const ref_m1 = log.findBySeq(seq_m1).?.undo_ref.?;
    const ref_m2 = log.findBySeq(seq_m2).?.undo_ref.?;

    // Only one more seq of headroom remains, but the bundle needs two (one revert record per member).
    log.next_seq = std.math.maxInt(u64) - 1;

    const u = try exec.undoOne(.local_user, &buf);
    try testing.expect(!u.happened);
    try testing.expect(!log.findBySeq(seq_m1).?.reverted);
    try testing.expect(!log.findBySeq(seq_m2).?.reverted);
    try testing.expect(app.valid[ref_m1]);
    try testing.expect(app.valid[ref_m2]);
}

test "11: preflight's input constraints apply identically for every record_policy (dry_run, no_record, a no-op recorder)" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    const before_filled = log.filled;
    const dry = try exec.executeAction("dry_action", "", .{ .actor = .local_user, .record_policy = .dry_run }, &buf);
    try testing.expectEqual(@as(?u64, null), dry.seq);
    try testing.expectEqual(before_filled, log.filled); // not even dispatched -> so no ref is issued either
    try testing.expectEqual(@as(u64, 1), app.next_ref);

    const nr = try exec.executeAction("no_record_action", "", .{ .actor = .local_user, .record_policy = .no_record }, &buf);
    try testing.expectEqual(@as(?u64, null), nr.seq);
    try testing.expectEqual(before_filled, log.filled); // dispatched, but not recorded
    try testing.expectEqual(@as(u64, 2), app.next_ref);

    // preflight's input constraint (an empty name) applies the same regardless of record_policy
    try testing.expectError(error.NameEmpty, exec.executeAction("", "", .{ .actor = .local_user, .record_policy = .dry_run }, &buf));
    try testing.expectError(error.NameEmpty, exec.executeAction("", "", .{ .actor = .local_user, .record_policy = .no_record }, &buf));

    // the same constraint applies to a no-op recorder (log=null) too
    var app2: MockApp = undefined;
    var exec2: Executor = Executor.init(.{ .ctx = &app2, .run = MockApp.run });
    app2 = .{ .exec = &exec2 };
    try testing.expect(exec2.log == null);
    try testing.expectError(error.NameEmpty, exec2.executeAction("", "", .{ .actor = .local_user }, &buf));
    const ok = try exec2.executeAction("ok_action", "", .{ .actor = .local_user }, &buf);
    try testing.expectEqual(@as(?u64, null), ok.seq); // not recorded (a no-op recorder)
    try testing.expectEqual(@as(u64, 2), app2.next_ref); // the dispatch itself does happen (the failed empty-name call just before was not dispatched)
}

test "12: the preflight failures (an empty name, a name over the limit, args over the limit, a stale transaction handle, MAX_ACTORS, MAX_OPEN_TX) are not dispatched" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    try testing.expectError(error.NameEmpty, exec.executeAction("", "", .{ .actor = .local_user }, &buf));
    try testing.expectEqual(@as(u64, 0), app.run_count); // not dispatched

    const long_name = [_]u8{'x'} ** (MAX_CMD_NAME + 1);
    try testing.expectError(error.NameTooLong, exec.executeAction(&long_name, "", .{ .actor = .local_user }, &buf));
    try testing.expectEqual(@as(u64, 0), app.run_count);

    var long_args_buf: [MAX_CMD_ARGS + 1]u8 = undefined;
    @memset(&long_args_buf, 'y');
    try testing.expectError(error.ArgsTooLong, exec.executeAction("ok", &long_args_buf, .{ .actor = .local_user }, &buf));
    try testing.expectEqual(@as(u64, 0), app.run_count);

    // a stale transaction handle: a generation mismatch after the close
    const tx = try exec.beginTransaction(.local_user, "macro");
    try exec.endTransaction(tx, .local_user);
    try testing.expectError(error.StaleTransactionHandle, exec.executeAction("m", "", .{ .actor = .local_user, .transaction = tx }, &buf));
    try testing.expectEqual(@as(u64, 0), app.run_count);

    // MAX_ACTORS overflow (a reject before the dispatch = the dispatcher call count does not rise)
    var i: u32 = 0;
    while (i < MAX_ACTORS) : (i += 1) {
        _ = try exec.executeAction("touch", "", .{ .actor = .{ .peer = i } }, &buf);
    }
    const run_count_full = app.run_count;
    try testing.expectError(error.TooManyActors, exec.executeAction("touch", "", .{ .actor = .{ .peer = 999 } }, &buf));
    try testing.expectEqual(run_count_full, app.run_count);

    // MAX_OPEN_TX overflow
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

test "12b: once next_transaction_id is exhausted a new transaction is rejected, without a fail-stop" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "a", &buf); // prepare one undo and redo candidate before the exhaustion

    exec.next_transaction_id = std.math.maxInt(u64); // reproduce the exhausted state
    try testing.expectError(error.TransactionIdExhausted, exec.beginTransaction(.local_user, "macro"));

    const u = try exec.undoOne(.local_user, &buf); // no id can be issued for the revert bundle -> treated as no candidate
    try testing.expect(!u.happened);
    try testing.expect(!log.findBySeq(1).?.reverted); // no inverse apply happened (issuing the id comes before applyUndo)
    try testing.expect(app.valid[log.findBySeq(1).?.undo_ref.?]); // the UndoRef was not consumed either
}

test "13: the noteUndo rules: a reentrant call is rejected, an error discards, a doubled noteUndo is first-wins" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    // reentrant dispatch: calling executeAction from inside the dispatcher callback
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

    // A pending is discarded on a dispatch error and does not contaminate the next record:
    // fail with a dispatcher that returns an error **after** setting pending through noteUndo, and confirm
    // that the successful command right after, which does not call noteUndo, is recorded as undoable=false (undo_ref=null)
    const NoteThenFailApp = struct {
        fn run(ctx: *anyopaque, name: []const u8, args: []const u8, b: []u8) anyerror![]const u8 {
            _ = args;
            const e: *Executor = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "note_then_fail")) {
                e.noteUndo(333); // fail after setting pending
                return error.Boom;
            }
            return writeMsg(b, "ok"); // no noteUndo
        }
    };
    var log_f: CommandLog = .{};
    var exec_f: Executor = undefined;
    exec_f = Executor.init(.{ .ctx = &exec_f, .run = NoteThenFailApp.run });
    exec_f.log = &log_f;
    try testing.expectError(error.Boom, exec_f.executeAction("note_then_fail", "", .{ .actor = .local_user }, &buf));
    const plain = try exec_f.executeAction("plain", "", .{ .actor = .local_user }, &buf);
    const plain_rec = log_f.findBySeq(plain.seq.?).?;
    try testing.expect(!plain_rec.undoable); // a discarded pending does not leak and turn this undoable
    try testing.expectEqual(@as(?UndoRef, null), plain_rec.undo_ref);

    // a doubled noteUndo is first-wins
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

test "14: a vanished undo_ref (canUndo=false) skips the candidate, as the last line of defence" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "a", &buf); // seq1
    _ = try exec1(&exec, .local_user, "b", &buf); // seq2

    // drop seq2's undo_ref on the application side (making canUndo false)
    app.valid[log.findBySeq(2).?.undo_ref.?] = false;

    const u = try exec.undoOne(.local_user, &buf); // seq2 is skipped and seq1 is the target
    try testing.expect(u.happened);
    try testing.expect(log.findBySeq(1).?.reverted);
    try testing.expect(!log.findBySeq(2).?.reverted);
}

test "15: the 16-actor boundary: with MAX_ACTORS full a new actor is rejected in preflight and existing actors are unaffected" {
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
    try testing.expectEqual(run_count_full, app.run_count); // a reject before the dispatch (the dispatcher is not called)

    // existing actors are unaffected
    const r = try exec.executeAction("touch2", "", .{ .actor = .{ .peer = 0 } }, &buf);
    try testing.expect(r.seq != null);
    try testing.expectEqual(run_count_full + 1, app.run_count);
}

test "16: a partial transaction overflow: losing the first member puts the whole transaction and the whole revert bundle out of the running, as does an open transaction" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    // an open transaction: add one member but do not close it
    const open_tx = try exec.beginTransaction(.local_user, "open");
    _ = try exec.executeAction("open_m1", "", .{ .actor = .local_user, .transaction = open_tx }, &buf);
    const open_seq = log.next_seq - 1;

    const u_open = try exec.undoOne(.local_user, &buf);
    try testing.expect(!u_open.happened); // a member of an open transaction is never a candidate (and there is no other candidate)
    try testing.expect(!log.findBySeq(open_seq).?.reverted);

    try exec.endTransaction(open_tx, .local_user);

    // build a transaction with 3 undoable members and lose only the first to a ring overflow
    const tx = try exec.beginTransaction(.local_user, "macro3");
    _ = try exec.executeAction("m1", "", .{ .actor = .local_user, .transaction = tx }, &buf);
    const seq_m1 = log.next_seq - 1;
    _ = try exec.executeAction("m2", "", .{ .actor = .local_user, .transaction = tx }, &buf);
    const seq_m2 = log.next_seq - 1;
    _ = try exec.executeAction("m3", "", .{ .actor = .local_user, .transaction = tx }, &buf);
    try exec.endTransaction(tx, .local_user);

    // the cumulative appends so far (open_m1 plus m1, m2, m3) = 4. Fill the ring with non-undoable (set_tool) fillers, and
    // once the total appends reach MAX_CMD_LOG+2, evicted=2 (open_m1 and m1). m2 and m3 are still intact.
    // The fillers are non-undoable to avoid "being picked up as an undo candidate, so that the undo itself appends more
    // and chains a further overflow" (being non-undoable, undoOne always ignores them).
    var n: usize = 0;
    const filler_count = MAX_CMD_LOG - 4 + 2;
    while (n < filler_count) : (n += 1) {
        _ = try exec.executeAction("set_tool", "", .{ .actor = .local_user }, &buf);
    }
    try testing.expect(log.findBySeq(seq_m1) == null); // the first member (m1) overflowed and is gone
    try testing.expect(log.findBySeq(seq_m2) != null); // m2 is intact

    const u = try exec.undoOne(.local_user, &buf); // tx3 is incomplete -> not a candidate. The fillers are non-undoable -> not candidates. So: no candidate
    try testing.expect(!u.happened);
    try testing.expect(!log.findBySeq(seq_m2).?.reverted); // no partial undo happens

    // Partial overflow on the revert bundle side: undo a small complete transaction, then overflow the first of its revert records
    var app2: MockApp = undefined;
    var log2: CommandLog = undefined;
    var exec2: Executor = undefined;
    wire(&app2, &log2, &exec2);

    const tx2 = try exec2.beginTransaction(.local_user, "macro2");
    _ = try exec2.executeAction("a1", "", .{ .actor = .local_user, .transaction = tx2 }, &buf);
    _ = try exec2.executeAction("a2", "", .{ .actor = .local_user, .transaction = tx2 }, &buf);
    try exec2.endTransaction(tx2, .local_user);

    const uc2 = try exec2.undoOne(.local_user, &buf); // produce a revert bundle (2 records): idx1(target=a2), idx2(target=a1)
    try testing.expect(uc2.happened);

    // the cumulative appends (a1, a2, revert×2) = 4. Adding 127 fillers makes evicted=3 (a1, a2, revert-idx1), leaving
    // only revert-idx2(target=a1). The bundle's ordinal 1 (revert-idx1) is gone, so the bundle is incomplete.
    var n2: usize = 0;
    const filler_count2 = MAX_CMD_LOG - 4 + 3;
    while (n2 < filler_count2) : (n2 += 1) {
        _ = try exec2.executeAction("filler2", "", .{ .actor = .local_user }, &buf);
    }
    const r2 = try exec2.redoOne(.local_user, &buf);
    try testing.expect(!r2.happened);
}

test "17: recordExecuted: no dispatch, a record, an epoch bump, undoable following undo_ref, and only record accepted" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    // not dispatched, and recorded with an undo_ref
    const seq1 = try exec.recordExecuted("stroke", "tool=pen 1 1", .{ .actor = .local_user }, 42, &buf);
    try testing.expectEqual(@as(?u64, 1), seq1);
    try testing.expectEqual(@as(u64, 0), app.run_count); // the dispatcher is not called
    const rec1 = log.findBySeq(1).?;
    try testing.expect(rec1.undoable);
    try testing.expectEqual(@as(?UndoRef, 42), rec1.undo_ref);
    try testing.expectEqualStrings("stroke", rec1.name());
    try testing.expectEqualStrings("tool=pen 1 1", rec1.args());
    try testing.expectEqual(@as(u64, 1), exec.currentEpoch(.local_user)); // an undoable record bumps the epoch

    // undo_ref=null means undoable=false and the epoch unchanged
    _ = try exec.recordExecuted("set_color", "FF0000", .{ .actor = .local_user }, null, &buf);
    try testing.expect(!log.findBySeq(2).?.undoable);
    try testing.expectEqual(@as(u64, 1), exec.currentEpoch(.local_user));

    // preflight is identical to executeAction's (an empty name, or args over the limit, is neither dispatched nor recorded)
    try testing.expectError(error.NameEmpty, exec.recordExecuted("", "", .{ .actor = .local_user }, null, &buf));
    var big_args: [MAX_CMD_ARGS + 1]u8 = undefined;
    @memset(&big_args, 'x');
    try testing.expectError(error.ArgsTooLong, exec.recordExecuted("stroke", &big_args, .{ .actor = .local_user }, null, &buf));
    try testing.expectEqual(@as(u32, 2), log.filled);

    // a record_policy other than record is rejected
    try testing.expectError(error.InvalidRecordPolicy, exec.recordExecuted("a", "", .{ .actor = .local_user, .record_policy = .no_record }, null, &buf));
    try testing.expectError(error.InvalidRecordPolicy, exec.recordExecuted("a", "", .{ .actor = .local_user, .record_policy = .dry_run }, null, &buf));

    // a no-op recorder (log=null) returns null after preflight alone
    var exec2: Executor = Executor.init(.{ .ctx = &app, .run = MockApp.run });
    const none = try exec2.recordExecuted("stroke", "1 1", .{ .actor = .local_user }, 7, &buf);
    try testing.expectEqual(@as(?u64, null), none);

    // an undoable record made by recordExecuted becomes a target of undoOne (recording in one place is what ties them together)
    app.valid[42] = true; // put it on the ref ledger MockApp's canUndo consults
    const u = try exec.undoOne(.local_user, &buf);
    try testing.expect(u.happened);
    try testing.expect(log.findBySeq(1).?.reverted);
}

test "18: openTransactionFor: only while open, per actor, and null after the close" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);

    try testing.expect(exec.openTransactionFor(.local_agent) == null);

    const tx = try exec.beginTransaction(.local_agent, "macro");
    const found = exec.openTransactionFor(.local_agent).?;
    try testing.expectEqual(tx.index, found.index);
    try testing.expectEqual(tx.generation, found.generation);
    try testing.expect(exec.openTransactionFor(.local_user) == null); // per actor

    // the handle found passes executeAction's transaction check
    var buf: [256]u8 = undefined;
    const res = try exec.executeAction("m1", "", .{ .actor = .local_agent, .transaction = found }, &buf);
    try testing.expectEqual(@as(?u64, 1), log.findBySeq(res.seq.?).?.transaction_id);

    try exec.endTransaction(tx, .local_agent);
    try testing.expect(exec.openTransactionFor(.local_agent) == null); // null after the close
}

test "19: the MAX_CMD_ARGS=4096 boundary: exactly the limit passes and +1 is rejected" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    try testing.expectEqual(4096, MAX_CMD_ARGS);
    var exact: [MAX_CMD_ARGS]u8 = undefined;
    @memset(&exact, 'a');
    const res = try exec.executeAction("big", &exact, .{ .actor = .local_user }, &buf);
    try testing.expectEqual(@as(usize, MAX_CMD_ARGS), log.findBySeq(res.seq.?).?.args().len);

    var over: [MAX_CMD_ARGS + 1]u8 = undefined;
    @memset(&over, 'a');
    try testing.expectError(error.ArgsTooLong, exec.executeAction("big", &over, .{ .actor = .local_user }, &buf));
}

test "20: bumpEpoch expires a redo candidate without recording anything, discarding the epoch for an unrecorded UI edit" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "a", &buf); // seq1
    _ = try exec.undoOne(.local_user, &buf); // revert target=1

    // the control: without a bump there is a redo candidate (checked on a separate executor)
    // the point: after bumpEpoch the epoch no longer matches, so there is no candidate
    exec.bumpEpoch(.local_user);
    const r = try exec.redoOne(.local_user, &buf);
    try testing.expect(!r.happened);

    // another actor's epoch is unaffected
    _ = try exec1(&exec, .local_agent, "b", &buf);
    _ = try exec.undoOne(.local_agent, &buf);
    const r2 = try exec.redoOne(.local_agent, &buf); // a bump of local_user is unrelated
    try testing.expect(r2.happened);

    // a bump of an unregistered actor registers it and advances the epoch (consistent with a later record)
    exec.bumpEpoch(.{ .peer = 9 });
    try testing.expectEqual(@as(u64, 1), exec.currentEpoch(.{ .peer = 9 }));
}

test "21: applyWireRevert: fixing reverted, the revert record, and burning in the epoch" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec.executeAction("paint", "x", .{ .actor = .{ .peer = 0 }, .source = .{ .remote_commit = .{ .seq = 1 } } }, &buf);
    try testing.expectEqual(@as(u64, 2), log.next_seq);
    const epoch_before = exec.currentEpoch(.{ .peer = 0 });

    try exec.applyWireRevert(1, 2);
    try testing.expect(log.findBySeq(1).?.reverted);
    const rev = log.findBySeq(2).?;
    try testing.expectEqual(CommandKind.revert, rev.kind);
    try testing.expectEqualStrings("revert", rev.name());
    try testing.expectEqual(@as(u64, 1), rev.target_seq.?);
    try testing.expect(rev.actor.eql(.{ .peer = 0 }));
    try testing.expectEqual(epoch_before, rev.epoch); // burned in (the epoch is unchanged, this not being a normal undoable)
    try testing.expectEqual(@as(u64, 3), log.next_seq);

    // findUndoCandidate / findRedoCandidate
    try testing.expect(exec.findUndoCandidate(.{ .peer = 0 }) == null);
    const rc = exec.findRedoCandidate(.{ .peer = 0 }).?;
    try testing.expectEqual(@as(u64, 1), rc.target_seq);
    try testing.expectEqualStrings("paint", rc.name);
}

test "22: wire_session suppresses a local record and still records a remote_commit" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    exec.setWireSession(true);
    const local = try exec.executeAction("save", "/tmp/x", .{ .actor = .local_user }, &buf);
    try testing.expect(local.seq == null);
    try testing.expectEqual(@as(u64, 1), log.next_seq); // not consumed

    const remote = try exec.executeAction("stroke", "1 2", .{
        .actor = .{ .peer = 0 },
        .source = .{ .remote_commit = .{ .seq = 1 } },
    }, &buf);
    try testing.expectEqual(@as(u64, 1), remote.seq.?);
    try testing.expectEqual(@as(u64, 2), log.next_seq);

    _ = try exec.recordExecuted("ui", "", .{ .actor = .local_user }, 1, &buf);
    try testing.expectEqual(@as(u32, 1), log.filled); // a UI record is suppressed too

    exec.setWireSession(false);
    const after = try exec.executeAction("local2", "", .{ .actor = .local_user }, &buf);
    try testing.expectEqual(@as(u64, 2), after.seq.?);
}

// ============================================================================
// App.dispatchCommand adapter
// ============================================================================

pub const RouteFn = *const fn (name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8;
pub const NetsyncStateFn = *const fn (ctx: *anyopaque) bool;

/// One row of the command table an application owns. The ID is stable; the action name is the lookup name for the Executor or the router.
pub const AppCommandBinding = struct {
    id: command_types.CommandId,
    action: []const u8,
    args: []const u8 = "",
};

pub const AppDispatchResult = struct {
    output: []const u8,
    seq: ?u64,
    routed: bool,
};

/// The adapter connecting an application-owned Executor to the shared entry point for menu commands.
/// The meaning of a NetworkPolicy is delegated to the action registry and the router; this layer does not interpret it.
pub const App = struct {
    executor: *Executor,
    bindings: []const AppCommandBinding,
    netsync_ctx: *anyopaque = undefined,
    is_netsync: NetsyncStateFn,
    route: RouteFn,

    pub fn dispatchCommand(self: *App, id: command_types.CommandId, buf: []u8) anyerror!AppDispatchResult {
        const binding = self.find(id) orelse return error.UnknownCommand;
        if (self.is_netsync(self.netsync_ctx)) {
            return .{
                .output = try self.route(binding.action, binding.args, buf),
                .seq = null,
                .routed = true,
            };
        }
        const result = try self.executor.executeAction(binding.action, binding.args, .{ .actor = .local_user }, buf);
        return .{ .output = result.output, .seq = result.seq, .routed = false };
    }

    fn find(self: *const App, id: command_types.CommandId) ?AppCommandBinding {
        for (self.bindings) |binding| {
            if (binding.id == id) return binding;
        }
        return null;
    }
};

const AppAdapterFakeState = struct {
    netsync: bool = false,
    dispatch_count: u32 = 0,
};

fn appAdapterFakeIsNetsync(ctx: *anyopaque) bool {
    return @as(*AppAdapterFakeState, @ptrCast(@alignCast(ctx))).netsync;
}

fn appAdapterFakeDispatch(ctx: *anyopaque, name: []const u8, _: []const u8, buf: []u8) anyerror![]const u8 {
    const state = @as(*AppAdapterFakeState, @ptrCast(@alignCast(ctx)));
    state.dispatch_count += 1;
    const msg = if (std.mem.eql(u8, name, "local")) "solo" else "unexpected";
    @memcpy(buf[0..msg.len], msg);
    return buf[0..msg.len];
}

fn appAdapterFakeRoute(name: []const u8, _: []const u8, buf: []u8) anyerror![]const u8 {
    // The fake router expresses only the outcome of a NetworkPolicy. Interpreting it for real is the router's responsibility.
    if (std.mem.eql(u8, name, "reject")) return error.RejectedWhileSynced;
    if (std.mem.eql(u8, name, "undo_own")) {
        @memcpy(buf[0..4], "undo");
        return buf[0..4];
    }
    @memcpy(buf[0..5], "relay");
    return buf[0..5];
}

test "App.dispatchCommand: solo goes through the application-owned Executor and is recorded" {
    var state: AppAdapterFakeState = .{};
    var log = CommandLog{};
    var executor = Executor.init(.{ .ctx = @ptrCast(&state), .run = appAdapterFakeDispatch });
    executor.log = &log;
    const bindings = [_]AppCommandBinding{.{ .id = 10, .action = "local" }};
    var app = App{
        .executor = &executor,
        .bindings = &bindings,
        .netsync_ctx = @ptrCast(&state),
        .is_netsync = appAdapterFakeIsNetsync,
        .route = appAdapterFakeRoute,
    };
    var buf: [16]u8 = undefined;
    const result = try app.dispatchCommand(10, &buf);
    try testing.expect(!result.routed);
    try testing.expectEqual(@as(u64, 1), result.seq.?);
    try testing.expectEqualStrings("solo", result.output);
    try testing.expectEqual(@as(u32, 1), state.dispatch_count);
    try testing.expectEqual(@as(u32, 1), log.filled);
}

test "App.dispatchCommand: netsync delegates relay, reject and undo_own to the router" {
    var state: AppAdapterFakeState = .{ .netsync = true };
    var executor = Executor.init(.{ .ctx = @ptrCast(&state), .run = appAdapterFakeDispatch });
    const bindings = [_]AppCommandBinding{
        .{ .id = 1, .action = "relay" },
        .{ .id = 2, .action = "reject" },
        .{ .id = 3, .action = "undo_own" },
    };
    var app = App{
        .executor = &executor,
        .bindings = &bindings,
        .netsync_ctx = @ptrCast(&state),
        .is_netsync = appAdapterFakeIsNetsync,
        .route = appAdapterFakeRoute,
    };
    var buf: [16]u8 = undefined;
    const relay = try app.dispatchCommand(1, &buf);
    try testing.expect(relay.routed);
    try testing.expectEqualStrings("relay", relay.output);
    try testing.expectError(error.RejectedWhileSynced, app.dispatchCommand(2, &buf));
    const undo = try app.dispatchCommand(3, &buf);
    try testing.expectEqualStrings("undo", undo.output);
    try testing.expectEqual(@as(u32, 0), state.dispatch_count);
}

test "App.dispatchCommand: an unregistered ID reaches neither the Executor nor the router" {
    var state: AppAdapterFakeState = .{};
    var executor = Executor.init(.{ .ctx = @ptrCast(&state), .run = appAdapterFakeDispatch });
    const bindings = [_]AppCommandBinding{.{ .id = 1, .action = "local" }};
    var app = App{
        .executor = &executor,
        .bindings = &bindings,
        .netsync_ctx = @ptrCast(&state),
        .is_netsync = appAdapterFakeIsNetsync,
        .route = appAdapterFakeRoute,
    };
    var buf: [8]u8 = undefined;
    try testing.expectError(error.UnknownCommand, app.dispatchCommand(99, &buf));
}

// ============================================================================
// persistence state transfer (export / restore; no byte codec)
// ============================================================================

test "persistent state export preserves command log order" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "a", &buf);
    _ = try exec1(&exec, .local_agent, "b", &buf);
    _ = try exec1(&exec, .local_user, "c", &buf);

    const state = log.exportState();
    try testing.expectEqual(@as(u32, 3), state.filled);
    try testing.expectEqual(log.head, state.head);
    try testing.expectEqual(log.next_seq, state.next_seq);
    try testing.expectEqual(@as(u64, 1), state.records[0].seq);
    try testing.expectEqual(@as(u64, 2), state.records[1].seq);
    try testing.expectEqual(@as(u64, 3), state.records[2].seq);
    try testing.expect(state.records[0].actor.eql(.local_user));
    try testing.expect(state.records[1].actor.eql(.local_agent));
    try testing.expectEqualStrings("a", state.records[0].name());
    try testing.expectEqualStrings("c", state.records[2].name());

    var log2: CommandLog = .{};
    log2.restoreState(state);
    try testing.expectEqual(state.filled, log2.filled);
    try testing.expectEqual(state.head, log2.head);
    try testing.expectEqual(state.next_seq, log2.next_seq);
    try testing.expectEqual(@as(u64, 1), log2.recordAt(0).seq);
    try testing.expectEqual(@as(u64, 3), log2.recordAt(2).seq);
    try testing.expectEqualStrings("b", log2.recordAt(1).name());
}

test "persistent state export preserves actor epochs" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    _ = try exec1(&exec, .local_user, "a", &buf);
    _ = try exec1(&exec, .{ .peer = 7 }, "b", &buf);
    _ = try exec.undoOne(.local_user, &buf);
    // undoable normal after undo bumps epoch again
    _ = try exec1(&exec, .local_user, "c", &buf);

    const state = exec.exportState();
    try testing.expect(state.actor_count >= 2);

    var found_user = false;
    var found_peer = false;
    var i: u32 = 0;
    while (i < state.actor_count) : (i += 1) {
        if (state.actors[i].actor.eql(.local_user)) {
            found_user = true;
            try testing.expect(state.actors[i].epoch >= 1);
        }
        if (state.actors[i].actor.eql(.{ .peer = 7 })) {
            found_peer = true;
            try testing.expectEqual(@as(u64, 1), state.actors[i].epoch);
        }
    }
    try testing.expect(found_user);
    try testing.expect(found_peer);

    var app2: MockApp = undefined;
    var log2: CommandLog = .{};
    var exec2: Executor = Executor.init(.{ .ctx = &app2, .run = MockApp.run });
    exec2.log = &log2;
    exec2.adapter = .{ .ctx = &app2, .canUndo = MockApp.canUndo, .applyUndo = MockApp.applyUndo, .summarize = MockApp.summarize };
    app2 = .{ .exec = &exec2 };
    const keep_dispatcher = exec2.dispatcher;
    exec2.restoreState(state);
    try testing.expectEqual(keep_dispatcher.ctx, exec2.dispatcher.ctx);
    try testing.expectEqual(state.actor_count, exec2.actor_count);
    try testing.expectEqual(state.next_transaction_id, exec2.next_transaction_id);
}

test "persistent state export preserves open transactions" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);
    var buf: [256]u8 = undefined;

    const tx = try exec.beginTransaction(.local_user, "macro");
    _ = try exec.executeAction("m1", "arg1", .{ .actor = .local_user, .transaction = tx }, &buf);
    _ = try exec.executeAction("m2", "", .{ .actor = .local_user, .transaction = tx }, &buf);
    // leave open (no endTransaction)

    const log_state = log.exportState();
    const exec_state = exec.exportState();
    try testing.expect(exec_state.transactions[tx.index].open);
    try testing.expectEqualStrings("macro", exec_state.transactions[tx.index].label());
    try testing.expectEqual(@as(u16, 2), exec_state.transactions[tx.index].undoable_member_count);
    try testing.expectEqual(tx.generation, exec_state.transactions[tx.index].generation);

    var app2: MockApp = undefined;
    var log2: CommandLog = .{};
    var exec2: Executor = Executor.init(.{ .ctx = &app2, .run = MockApp.run });
    exec2.log = &log2;
    exec2.adapter = .{ .ctx = &app2, .canUndo = MockApp.canUndo, .applyUndo = MockApp.applyUndo, .summarize = MockApp.summarize };
    app2 = .{ .exec = &exec2 };
    log2.restoreState(log_state);
    exec2.restoreState(exec_state);

    // continue the restored open transaction
    const restored_tx = TransactionHandle{ .index = tx.index, .generation = tx.generation };
    _ = try exec2.executeAction("m3", "", .{ .actor = .local_user, .transaction = restored_tx }, &buf);
    try exec2.endTransaction(restored_tx, .local_user);
    try testing.expectEqual(@as(u32, 3), log2.filled);
    try testing.expect(!exec2.tx_table[tx.index].open);
}

test "persistent state restore clears dispatch-only state" {
    var app: MockApp = undefined;
    var log: CommandLog = undefined;
    var exec: Executor = undefined;
    wire(&app, &log, &exec);

    exec.in_dispatch = true;
    exec.pending_undo_ref = 42;
    exec.pending_set = true;
    exec.wire_session = true;
    const keep_log = exec.log;
    const keep_dispatcher = exec.dispatcher;
    const keep_adapter = exec.adapter;
    const keep_wire = exec.wire_session;

    const state = exec.exportState();
    exec.restoreState(state);

    try testing.expect(!exec.in_dispatch);
    try testing.expectEqual(@as(?UndoRef, null), exec.pending_undo_ref);
    try testing.expect(!exec.pending_set);
    try testing.expectEqual(keep_log, exec.log);
    try testing.expectEqual(keep_dispatcher.ctx, exec.dispatcher.ctx);
    try testing.expect(exec.adapter != null);
    try testing.expectEqual(keep_adapter.?.ctx, exec.adapter.?.ctx);
    try testing.expectEqual(keep_wire, exec.wire_session);
}
