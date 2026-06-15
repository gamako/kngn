//! SPSC ロックフリーリングバッファと、GUI→Audio のノートイベントキュー。
//!
//! スレッドモデル: producer = メインスレッド(GUI/入力)、consumer = オーディオ RT スレッド。
//! RT スレッド側では lock/malloc/IO をしない（pop はインデックス演算のみ）。

const std = @import("std");
const AtomicUsize = std.atomic.Value(usize);

/// 単一 producer / 単一 consumer のロックフリーリングバッファ。
/// `capacity` は 2 の冪。head/tail はラップするモノトニックカウンタ（最大 `capacity` 個保持）。
pub fn SpscRing(comptime T: type, comptime capacity: usize) type {
    if (!std.math.isPowerOfTwo(capacity)) @compileError("capacity must be a power of two");
    return struct {
        const Self = @This();
        const mask = capacity - 1;

        buffer: [capacity]T = undefined,
        head: AtomicUsize = AtomicUsize.init(0), // producer が進める
        tail: AtomicUsize = AtomicUsize.init(0), // consumer が進める

        pub fn capacityCount() usize {
            return capacity;
        }

        /// producer: 空きがあれば push、満杯なら false。
        pub fn push(self: *Self, item: T) bool {
            return self.pushReserve(item, 0);
        }

        /// producer: 空き容量が `reserve` を超えるときだけ push する。
        /// `reserve` 枠を他用途（例: note_off）に残したい場合に使う。
        pub fn pushReserve(self: *Self, item: T, reserve: usize) bool {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            const used = head -% tail;
            if (used + reserve >= capacity) return false;
            self.buffer[head & mask] = item;
            self.head.store(head +% 1, .release);
            return true;
        }

        /// consumer: 1 件取り出す。空なら null。
        pub fn pop(self: *Self) ?T {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.acquire);
            if (head == tail) return null;
            const item = self.buffer[tail & mask];
            self.tail.store(tail +% 1, .release);
            return item;
        }
    };
}

/// ノートイベント（GUI→Audio）。
pub const NoteEvent = union(enum) {
    note_on: struct { note: u8, velocity: f32 },
    note_off: struct { note: u8 },
};

/// GUI→Audio のノートイベントキュー。
/// - `note_on`: 満杯間際（`off_reserve` 枠）では落とす（間引く）。
/// - `note_off`: `off_reserve` 枠を使ってでも極力入れる。
/// - パニック（全ノートオフ）: リングの空き状況と無関係な atomic カウンタで **決して落とさない**。
pub fn NoteQueue(comptime capacity: usize, comptime off_reserve: usize) type {
    return struct {
        const Self = @This();
        const Ring = SpscRing(NoteEvent, capacity);

        ring: Ring = .{},
        panic_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        // ---- producer (GUI / 入力) ----

        /// note_on を送る。満杯間際なら落とす（false）。
        pub fn sendNoteOn(self: *Self, note: u8, velocity: f32) bool {
            return self.ring.pushReserve(.{ .note_on = .{ .note = note, .velocity = velocity } }, off_reserve);
        }

        /// note_off を送る。reserve 枠を使えるので極力落とさない。
        pub fn sendNoteOff(self: *Self, note: u8) bool {
            return self.ring.push(.{ .note_off = .{ .note = note } });
        }

        /// 全ノートオフ（パニック）。リング状態に依存せず必ず伝わる。
        pub fn panicAllNotesOff(self: *Self) void {
            _ = self.panic_gen.fetchAdd(1, .release);
        }

        // ---- consumer (Audio RT) ----

        pub fn pop(self: *Self) ?NoteEvent {
            return self.ring.pop();
        }

        /// 前回確認時から新しいパニックが発行されていれば true（`last_seen` を更新して消費）。
        pub fn takePanic(self: *Self, last_seen: *u32) bool {
            const cur = self.panic_gen.load(.acquire);
            if (cur != last_seen.*) {
                last_seen.* = cur;
                return true;
            }
            return false;
        }
    };
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "SpscRing: FIFO order push/pop" {
    var ring = SpscRing(u32, 4){};
    try testing.expect(ring.push(10));
    try testing.expect(ring.push(20));
    try testing.expectEqual(@as(?u32, 10), ring.pop());
    try testing.expectEqual(@as(?u32, 20), ring.pop());
    try testing.expectEqual(@as(?u32, null), ring.pop());
}

test "SpscRing: full returns false, capacity == capacity items" {
    var ring = SpscRing(u32, 4){};
    try testing.expect(ring.push(1));
    try testing.expect(ring.push(2));
    try testing.expect(ring.push(3));
    try testing.expect(ring.push(4)); // 4 個まで保持できる
    try testing.expect(!ring.push(5)); // 満杯
    try testing.expectEqual(@as(?u32, 1), ring.pop());
    try testing.expect(ring.push(5)); // 1 つ空いた
}

test "SpscRing: wrap-around" {
    var ring = SpscRing(u32, 4){};
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try testing.expect(ring.push(i));
        try testing.expectEqual(@as(?u32, i), ring.pop());
    }
}

test "NoteQueue: note_off survives when note_on is throttled (reserve)" {
    // capacity 4, off_reserve 2 → note_on は used+2>=4 すなわち used>=2 で落ちる。
    var q = NoteQueue(4, 2){};
    try testing.expect(q.sendNoteOn(60, 1.0)); // used 0->1
    try testing.expect(q.sendNoteOn(61, 1.0)); // used 1->2
    try testing.expect(!q.sendNoteOn(62, 1.0)); // used 2, reserve で拒否
    // note_off は reserve 枠を使えるので入る
    try testing.expect(q.sendNoteOff(60)); // used 2->3
    try testing.expect(q.sendNoteOff(61)); // used 3->4(満杯)
    try testing.expect(!q.sendNoteOff(62)); // 完全に満杯なら入らない
}

test "NoteQueue: panic is never dropped even when ring is full" {
    var q = NoteQueue(2, 0){};
    try testing.expect(q.sendNoteOn(60, 1.0));
    try testing.expect(q.sendNoteOn(61, 1.0)); // 満杯
    try testing.expect(!q.sendNoteOn(62, 1.0));
    // リング満杯でもパニックは伝わる
    var seen: u32 = 0;
    try testing.expect(!q.takePanic(&seen));
    q.panicAllNotesOff();
    try testing.expect(q.takePanic(&seen));
    try testing.expect(!q.takePanic(&seen)); // 二度は消費しない
}
