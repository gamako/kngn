//! CommandRecord → 履歴表示 schema（TASK-62.5.5）。
//!
//! TASK-83 Phase 1 の in-process 入口と history probe（digest/snapshot）の単一ソース。
//! `App` / `main.zig` を import しない（循環回避）。`@import` は kit（command 型）+ actions + std。
//!
//! ## ホットパス宣言
//! summarize / digest / snapshot はすべて**イベント時のみ**（probe 要求時・将来の panel 再構築時）。
//! フレーム毎全走査 / RT 経路には乗らない。

const std = @import("std");
const kit = @import("kit");
const command = kit.platform.command;
const actions = @import("actions.zig");

const testing = std.testing;

/// harness `DIGEST_BUF_LEN` と同値（history_summary は harness を import しない）。
pub const DIGEST_BUF_LEN = 1024;

pub const HistoryContext = struct {
    ctx: *anyopaque,
    hasHandle: *const fn (ctx: *anyopaque, ref: u64) bool,
    log: *const command.CommandLog,
};

/// 履歴 1 件の表示用ビュー。
///
/// `name` / `actor` / `kind` は借用 slice（`name` は `CommandRecord.name_buf` への参照、
/// `actor`/`kind` は `@tagName` の静的文字列）。`summary_buf` のみ inline copy で寿命が自立する。
/// `CommandLog` の変異（`append` による ring 上書き）を跨いで `HistoryEntry` を保持してはならない。
/// イベント時に `makeHistoryEntry` で再構築すること。
pub const HistoryEntry = struct {
    seq: u64,
    actor: []const u8,
    actor_peer: ?u32,
    kind: []const u8,
    name: []const u8,
    summary_buf: [command.MAX_SUMMARY]u8 = undefined,
    summary_len: u8 = 0,
    undoable: bool,
    reverted: bool,
    redo_consumed: bool,
    tx: ?u64,
    target: ?u64,
    redo_of: ?u64,
    undo_live: ?bool,
    epoch: u64,

    pub fn summary(self: *const HistoryEntry) []const u8 {
        return self.summary_buf[0..self.summary_len];
    }
};

/// pixie summarize の唯一の本体（adapter / makeHistoryEntry の双方がこれを呼ぶ）。
pub fn summarizeRecord(rec: *const command.CommandRecord, buf: []u8) []const u8 {
    var scratch: [command.MAX_SUMMARY]u8 = undefined;
    const raw: []const u8 = blk: {
        if (rec.kind == .revert) {
            if (rec.target_seq) |t| {
                break :blk std.fmt.bufPrint(&scratch, "undo #{d}", .{t}) catch "undo";
            }
            break :blk "undo";
        }
        if (std.mem.eql(u8, rec.name(), "stroke")) {
            break :blk summarizeStroke(rec.args(), &scratch) orelse "stroke";
        }
        break :blk rec.name();
    };
    return copyAsciiSummary(raw, buf);
}

fn summarizeStroke(args: []const u8, buf: []u8) ?[]const u8 {
    var pts_buf: [actions.MAX_STROKE_POINTS]actions.Point = undefined;
    const parsed = actions.parseStroke(args, &pts_buf) catch return null;
    const tool = parsed.params.tool orelse return null;
    return switch (tool) {
        .pen => blk: {
            const color = parsed.params.color orelse return null;
            break :blk std.fmt.bufPrint(buf, "stroke pen #{X:0>6}", .{color & 0xFFFFFF}) catch null;
        },
        .eraser => std.fmt.bufPrint(buf, "stroke eraser", .{}) catch null,
        .brush => blk: {
            const color = parsed.params.color orelse return null;
            break :blk std.fmt.bufPrint(buf, "stroke brush #{X:0>6}", .{color & 0xFFFFFF}) catch null;
        },
    };
}

fn copyAsciiSummary(src: []const u8, buf: []u8) []const u8 {
    const limit = @min(buf.len, command.MAX_SUMMARY);
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < src.len and out_len < limit) {
        const c = src[i];
        if (c < 0x80) {
            buf[out_len] = if (c >= 0x20 and c <= 0x7E) c else '?';
            out_len += 1;
            i += 1;
        } else {
            // 非 ASCII は 1 code unit を '?' に潰し、UTF-8 シーケンスをスキップ
            const seq_len = std.unicode.utf8ByteSequenceLength(c) catch 1;
            buf[out_len] = '?';
            out_len += 1;
            i += seq_len;
            if (i > src.len) i = src.len;
        }
    }
    // UTF-8 境界: 最後が不完全なら削る（ASCII 正規化後は実質不要だが防御）
    while (out_len > 0 and buf[out_len - 1] & 0x80 != 0 and buf[out_len - 1] & 0xC0 != 0xC0) {
        // continuation only — 上のループでは出さない
        out_len -= 1;
    }
    return buf[0..out_len];
}

pub fn makeHistoryEntry(hctx: HistoryContext, rec: *const command.CommandRecord) HistoryEntry {
    var e: HistoryEntry = .{
        .seq = rec.seq,
        .actor = @tagName(rec.actor),
        .actor_peer = switch (rec.actor) {
            .peer => |id| id,
            else => null,
        },
        .kind = @tagName(rec.kind),
        .name = rec.name(),
        .undoable = rec.undoable,
        .reverted = rec.reverted,
        .redo_consumed = rec.redo_consumed,
        .tx = rec.transaction_id,
        .target = rec.target_seq,
        .redo_of = rec.redo_of,
        .undo_live = null,
        .epoch = rec.epoch,
    };
    const sum = summarizeRecord(rec, e.summary_buf[0..]);
    e.summary_len = @intCast(sum.len);
    if (rec.undo_ref) |ref| {
        e.undo_live = hctx.hasHandle(hctx.ctx, ref);
    }
    return e;
}

fn tokenSafe(dst: []u8, src: []const u8) []const u8 {
    const n = @min(dst.len, src.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = src[i];
        // digest 1行契約: 空白/= に加え、非印刷 ASCII も '_' へ（制御文字で行が割れないように）。
        dst[i] = if (c >= 0x20 and c <= 0x7E and c != ' ' and c != '=') c else '_';
    }
    return dst[0..n];
}

/// §4b digest。空 log の全文はテストの正。
pub fn formatDigest(hctx: HistoryContext, buf: []u8) []const u8 {
    const log = hctx.log;
    if (log.filled == 0) {
        const empty =
            \\count=0 last_seq=0 last_actor=- last_name=- last_undoable=- last_undo_ref=- last_undo_live=- last_tx=- last_kind=- last_target=- last_redo_of=- last2_tx=- last_summary=- last_reverted=- last_redo_consumed=-
        ;
        if (empty.len > buf.len) return buf[0..0];
        @memcpy(buf[0..empty.len], empty);
        return buf[0..empty.len];
    }
    const latest = log.recordAt(log.filled - 1);
    const entry = makeHistoryEntry(hctx, latest);

    var ref_buf: [24]u8 = undefined;
    const ref_str: []const u8 = if (latest.undo_ref) |r|
        (std.fmt.bufPrint(&ref_buf, "{d}", .{r}) catch "-")
    else
        "-";
    const live_str: []const u8 = if (entry.undo_live) |v|
        (if (v) "1" else "0")
    else
        "-";
    var tx_buf: [24]u8 = undefined;
    const tx_str: []const u8 = if (entry.tx) |t|
        (std.fmt.bufPrint(&tx_buf, "{d}", .{t}) catch "-")
    else
        "-";
    var target_buf: [24]u8 = undefined;
    const target_str: []const u8 = if (entry.target) |t|
        (std.fmt.bufPrint(&target_buf, "{d}", .{t}) catch "-")
    else
        "-";
    var redo_of_buf: [24]u8 = undefined;
    const redo_of_str: []const u8 = if (entry.redo_of) |r|
        (std.fmt.bufPrint(&redo_of_buf, "{d}", .{r}) catch "-")
    else
        "-";
    var tx2_buf: [24]u8 = undefined;
    const tx2_str: []const u8 = blk: {
        if (log.filled < 2) break :blk "-";
        const second = log.recordAt(log.filled - 2);
        break :blk if (second.transaction_id) |t|
            (std.fmt.bufPrint(&tx2_buf, "{d}", .{t}) catch "-")
        else
            "-";
    };

    var name_safe_buf: [command.MAX_CMD_NAME]u8 = undefined;
    const name_safe = tokenSafe(&name_safe_buf, entry.name);

    // 固定キーを先に書き、last_summary を残り容量へ（DIGEST 収まり保証）
    const head = std.fmt.bufPrint(buf, "count={d} last_seq={d} last_actor={s} last_name={s} last_undoable={d} last_undo_ref={s} last_undo_live={s} last_tx={s} last_kind={s} last_target={s} last_redo_of={s} last2_tx={s} last_summary=", .{
        log.filled,
        entry.seq,
        entry.actor,
        name_safe,
        @as(u1, if (entry.undoable) 1 else 0),
        ref_str,
        live_str,
        tx_str,
        entry.kind,
        target_str,
        redo_of_str,
        tx2_str,
    }) catch return buf[0..0];

    var pos: usize = head.len;
    var sum_safe_buf: [command.MAX_SUMMARY]u8 = undefined;
    const sum_safe = tokenSafe(&sum_safe_buf, entry.summary());
    // 末尾 " last_reverted=0 last_redo_consumed=0" の長さを正とする（値は 0/1 同長）。
    const tail_reserve = " last_reverted=0 last_redo_consumed=0".len;
    const sum_room = if (buf.len > pos + tail_reserve) buf.len - pos - tail_reserve else 0;
    const sum_n = @min(sum_safe.len, sum_room);
    if (sum_n > 0) {
        @memcpy(buf[pos..][0..sum_n], sum_safe[0..sum_n]);
        pos += sum_n;
    }
    const tail = std.fmt.bufPrint(buf[pos..], " last_reverted={d} last_redo_consumed={d}", .{
        @as(u1, if (entry.reverted) 1 else 0),
        @as(u1, if (entry.redo_consumed) 1 else 0),
    }) catch return buf[0..0];
    pos += tail.len;
    return buf[0..pos];
}

fn appendJsonStr(list: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try list.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var esc: [6]u8 = undefined;
                    const e = try std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c});
                    try list.appendSlice(allocator, e);
                } else {
                    try list.append(allocator, c);
                }
            },
        }
    }
    try list.append(allocator, '"');
}

fn appendOptU64(list: *std.ArrayList(u8), allocator: std.mem.Allocator, v: ?u64) !void {
    if (v) |n| {
        var tmp: [24]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "{d}", .{n});
        try list.appendSlice(allocator, s);
    } else {
        try list.appendSlice(allocator, "null");
    }
}

fn appendOptU32(list: *std.ArrayList(u8), allocator: std.mem.Allocator, v: ?u32) !void {
    if (v) |n| {
        var tmp: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "{d}", .{n});
        try list.appendSlice(allocator, s);
    } else {
        try list.appendSlice(allocator, "null");
    }
}

fn appendOptBool(list: *std.ArrayList(u8), allocator: std.mem.Allocator, v: ?bool) !void {
    if (v) |b| {
        try list.appendSlice(allocator, if (b) "true" else "false");
    } else {
        try list.appendSlice(allocator, "null");
    }
}

/// 1 entry を JSON object として追記（人工 fixture の escape テストからも利用）。
pub fn appendEntryJson(list: *std.ArrayList(u8), allocator: std.mem.Allocator, e: *const HistoryEntry) !void {
    try list.append(allocator, '{');
    try list.appendSlice(allocator, "\"seq\":");
    {
        var tmp: [24]u8 = undefined;
        try list.appendSlice(allocator, try std.fmt.bufPrint(&tmp, "{d}", .{e.seq}));
    }
    try list.appendSlice(allocator, ",\"actor\":");
    try appendJsonStr(list, allocator, e.actor);
    try list.appendSlice(allocator, ",\"actor_peer\":");
    try appendOptU32(list, allocator, e.actor_peer);
    try list.appendSlice(allocator, ",\"kind\":");
    try appendJsonStr(list, allocator, e.kind);
    try list.appendSlice(allocator, ",\"name\":");
    try appendJsonStr(list, allocator, e.name);
    try list.appendSlice(allocator, ",\"summary\":");
    try appendJsonStr(list, allocator, e.summary());
    try list.appendSlice(allocator, ",\"undoable\":");
    try list.appendSlice(allocator, if (e.undoable) "true" else "false");
    try list.appendSlice(allocator, ",\"reverted\":");
    try list.appendSlice(allocator, if (e.reverted) "true" else "false");
    try list.appendSlice(allocator, ",\"redo_consumed\":");
    try list.appendSlice(allocator, if (e.redo_consumed) "true" else "false");
    try list.appendSlice(allocator, ",\"tx\":");
    try appendOptU64(list, allocator, e.tx);
    try list.appendSlice(allocator, ",\"target\":");
    try appendOptU64(list, allocator, e.target);
    try list.appendSlice(allocator, ",\"redo_of\":");
    try appendOptU64(list, allocator, e.redo_of);
    try list.appendSlice(allocator, ",\"undo_live\":");
    try appendOptBool(list, allocator, e.undo_live);
    try list.appendSlice(allocator, ",\"epoch\":");
    {
        var tmp: [24]u8 = undefined;
        try list.appendSlice(allocator, try std.fmt.bufPrint(&tmp, "{d}", .{e.epoch}));
    }
    try list.append(allocator, '}');
}

pub fn formatSnapshotJson(hctx: HistoryContext, allocator: std.mem.Allocator) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try list.append(allocator, '[');
    var i: u32 = 0;
    while (i < hctx.log.filled) : (i += 1) {
        if (i > 0) try list.append(allocator, ',');
        const rec = hctx.log.recordAt(i);
        const entry = makeHistoryEntry(hctx, rec);
        try appendEntryJson(&list, allocator, &entry);
    }
    try list.append(allocator, ']');
    return try list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

fn testHasHandleNone(_: *anyopaque, _: u64) bool {
    return false;
}

fn testHasHandleAll(_: *anyopaque, _: u64) bool {
    return true;
}

fn fillRec(name: []const u8, args: []const u8) command.CommandRecord {
    var rec: command.CommandRecord = .{
        .seq = 1,
        .actor = .local_user,
        .kind = .normal,
        .name_len = 0,
        .args_len = 0,
        .transaction_id = null,
        .undoable = true,
    };
    rec.name_len = @intCast(name.len);
    @memcpy(rec.name_buf[0..name.len], name);
    rec.args_len = @intCast(args.len);
    @memcpy(rec.args_buf[0..args.len], args);
    return rec;
}

test "summarizeRecord: revert / stroke / other" {
    var buf: [command.MAX_SUMMARY]u8 = undefined;
    var rev = fillRec("stroke", "tool=pen color=FF0000 1 1 2 2");
    rev.kind = .revert;
    rev.target_seq = 3;
    try testing.expectEqualStrings("undo #3", summarizeRecord(&rev, &buf));

    const stroke = fillRec("stroke", "tool=pen color=00FF00 1 1 3 3");
    try testing.expectEqualStrings("stroke pen #00FF00", summarizeRecord(&stroke, &buf));

    const eraser = fillRec("stroke", "tool=eraser 0 0 1 1");
    try testing.expectEqualStrings("stroke eraser", summarizeRecord(&eraser, &buf));

    const other = fillRec("set_color", "FF0000");
    try testing.expectEqualStrings("set_color", summarizeRecord(&other, &buf));
}

test "formatDigest: empty exact" {
    var log: command.CommandLog = .{};
    const hctx: HistoryContext = .{
        .ctx = undefined,
        .hasHandle = testHasHandleNone,
        .log = &log,
    };
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const got = formatDigest(hctx, &buf);
    const want =
        \\count=0 last_seq=0 last_actor=- last_name=- last_undoable=- last_undo_ref=- last_undo_live=- last_tx=- last_kind=- last_target=- last_redo_of=- last2_tx=- last_summary=- last_reverted=- last_redo_consumed=-
    ;
    try testing.expectEqualStrings(want, got);
}

test "formatDigest: single stroke keys order + additive tail" {
    var log: command.CommandLog = .{};
    var rec = fillRec("stroke", "tool=pen color=FF0000 1 1 2 2");
    rec.seq = 1;
    rec.undo_ref = 7;
    log.append(rec);
    var dummy: u8 = 0;
    const hctx: HistoryContext = .{
        .ctx = &dummy,
        .hasHandle = testHasHandleAll,
        .log = &log,
    };
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const got = formatDigest(hctx, &buf);
    try testing.expect(got.len <= DIGEST_BUF_LEN);
    const want =
        \\count=1 last_seq=1 last_actor=local_user last_name=stroke last_undoable=1 last_undo_ref=7 last_undo_live=1 last_tx=- last_kind=normal last_target=- last_redo_of=- last2_tx=- last_summary=stroke_pen_#FF0000 last_reverted=0 last_redo_consumed=0
    ;
    try testing.expectEqualStrings(want, got);
}

test "formatSnapshotJson: empty and one entry optional nulls" {
    var log: command.CommandLog = .{};
    var dummy: u8 = 0;
    const hctx: HistoryContext = .{
        .ctx = &dummy,
        .hasHandle = testHasHandleNone,
        .log = &log,
    };
    const empty = try formatSnapshotJson(hctx, testing.allocator);
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("[]", empty);

    var rec = fillRec("set_tool", "pen");
    rec.seq = 2;
    rec.undoable = false;
    log.append(rec);
    const one = try formatSnapshotJson(hctx, testing.allocator);
    defer testing.allocator.free(one);
    try testing.expect(std.mem.indexOf(u8, one, "\"seq\":2") != null);
    try testing.expect(std.mem.indexOf(u8, one, "\"tx\":null") != null);
    try testing.expect(std.mem.indexOf(u8, one, "\"undo_live\":null") != null);
    try testing.expect(std.mem.indexOf(u8, one, "\"undoable\":false") != null);
}

test "formatSnapshotJson: full ring (128) keeps oldest-to-newest order" {
    var log: command.CommandLog = .{};
    var seq: u64 = 1;
    while (seq <= 130) : (seq += 1) {
        var rec = fillRec("set_tool", "pen");
        rec.seq = seq;
        log.append(rec);
    }
    try testing.expectEqual(@as(u32, command.MAX_CMD_LOG), log.filled);

    var dummy: u8 = 0;
    const hctx: HistoryContext = .{
        .ctx = &dummy,
        .hasHandle = testHasHandleNone,
        .log = &log,
    };
    const json = try formatSnapshotJson(hctx, testing.allocator);
    defer testing.allocator.free(json);

    // (a) entry 数 = 128（満杯後 wrap しても filled 上限）
    try testing.expectEqual(@as(usize, command.MAX_CMD_LOG), std.mem.count(u8, json, "\"seq\":"));
    // (b) 先頭 = 最古の生存 seq=3（1,2 は evict）
    try testing.expect(std.mem.startsWith(u8, json, "[{\"seq\":3,"));
    // (c) 末尾 entry の seq = 130（最新）
    const last_seq_key = std.mem.lastIndexOf(u8, json, "\"seq\":").?;
    try testing.expect(std.mem.startsWith(u8, json[last_seq_key..], "\"seq\":130,"));
    // (d) 昇順（先頭が末尾より前）
    const first_pos = std.mem.indexOf(u8, json, "\"seq\":3,").?;
    try testing.expect(first_pos < last_seq_key);
}

test "appendEntryJson: escape fixture (unnormalized summary)" {
    var e: HistoryEntry = .{
        .seq = 1,
        .actor = "local_user",
        .actor_peer = null,
        .kind = "normal",
        .name = "x",
        .undoable = true,
        .reverted = false,
        .redo_consumed = false,
        .tx = null,
        .target = null,
        .redo_of = null,
        .undo_live = null,
        .epoch = 0,
    };
    const raw = "a\"b\\c\x01";
    @memcpy(e.summary_buf[0..raw.len], raw);
    e.summary_len = @intCast(raw.len);

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try appendEntryJson(&list, testing.allocator, &e);
    try testing.expect(std.mem.indexOf(u8, list.items, "a\\\"b\\\\c\\u0001") != null);
}

test "summarizeRecord: respects MAX_SUMMARY" {
    var name_buf: [command.MAX_CMD_NAME]u8 = undefined;
    @memset(&name_buf, 'b');
    const rec = fillRec(&name_buf, "");
    var buf: [command.MAX_SUMMARY]u8 = undefined;
    const s = summarizeRecord(&rec, &buf);
    try testing.expectEqual(@as(usize, command.MAX_SUMMARY), s.len);
}

test "formatDigest: reverted and redo_consumed" {
    var log: command.CommandLog = .{};
    var rec = fillRec("stroke", "tool=pen color=0000FF 0 0 1 1");
    rec.seq = 5;
    rec.reverted = true;
    log.append(rec);
    var rev: command.CommandRecord = fillRec("stroke", "tool=pen color=0000FF 0 0 1 1");
    rev.seq = 6;
    rev.kind = .revert;
    rev.target_seq = 5;
    rev.redo_consumed = true;
    rev.undoable = false;
    log.append(rev);
    var dummy: u8 = 0;
    const hctx: HistoryContext = .{
        .ctx = &dummy,
        .hasHandle = testHasHandleNone,
        .log = &log,
    };
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const got = formatDigest(hctx, &buf);
    try testing.expect(std.mem.indexOf(u8, got, "last_kind=revert") != null);
    try testing.expect(std.mem.indexOf(u8, got, "last_reverted=0") != null);
    try testing.expect(std.mem.indexOf(u8, got, "last_redo_consumed=1") != null);
    try testing.expect(std.mem.indexOf(u8, got, "last_target=5") != null);
}
