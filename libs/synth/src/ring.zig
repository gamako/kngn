//! SPSC lock-free ring buffer and the GUI→Audio note-event queue.
//!
//! Thread model: producer = main thread (GUI/input), consumer = audio RT thread.
//! The RT thread does no lock/malloc/IO (pop is index arithmetic only).

const std = @import("std");
const AtomicUsize = std.atomic.Value(usize);

/// Single-producer / single-consumer lock-free ring buffer.
/// `capacity` is a power of two. head/tail are wrapping monotonic counters (hold at most `capacity` items).
pub fn SpscRing(comptime T: type, comptime capacity: usize) type {
    if (!std.math.isPowerOfTwo(capacity)) @compileError("capacity must be a power of two");
    return struct {
        const Self = @This();
        const mask = capacity - 1;

        buffer: [capacity]T = undefined,
        // Separate head (producer writes) / tail (consumer writes) onto different cache lines (avoid false sharing)
        head: AtomicUsize align(std.atomic.cache_line) = AtomicUsize.init(0), // advanced by the producer
        tail: AtomicUsize align(std.atomic.cache_line) = AtomicUsize.init(0), // advanced by the consumer

        pub fn capacityCount() usize {
            return capacity;
        }

        /// producer: push if there is room; return false when full.
        pub fn push(self: *Self, item: T) bool {
            return self.pushReserve(item, 0);
        }

        /// producer: push only when free capacity exceeds `reserve`.
        /// Use when leaving a `reserve` window for other uses (e.g. note_off).
        pub fn pushReserve(self: *Self, item: T, reserve: usize) bool {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            const used = head -% tail;
            if (used + reserve >= capacity) return false;
            self.buffer[head & mask] = item;
            self.head.store(head +% 1, .release);
            return true;
        }

        /// consumer: take one item. null if empty.
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

/// Note event (GUI→Audio).
pub const NoteEvent = union(enum) {
    note_on: struct { note: u8, velocity: f32 },
    note_off: struct { note: u8 },
};

/// GUI→Audio note-event queue.
/// - `note_on`: drop (thin) when nearly full (inside the `off_reserve` window).
/// - `note_off`: try hard to enqueue even by using the `off_reserve` window.
/// - Panic (all notes off): an atomic counter independent of ring free space — **never dropped**.
pub fn NoteQueue(comptime capacity: usize, comptime off_reserve: usize) type {
    return struct {
        const Self = @This();
        const Ring = SpscRing(NoteEvent, capacity);

        ring: Ring = .{},
        // Keep off the same line as ring.tail (consumer writes) (producer writes / consumer reads)
        panic_gen: std.atomic.Value(u32) align(std.atomic.cache_line) = std.atomic.Value(u32).init(0),

        // ---- producer (GUI / input) ----

        /// Send note_on. Drop (return false) when nearly full.
        pub fn sendNoteOn(self: *Self, note: u8, velocity: f32) bool {
            return self.ring.pushReserve(.{ .note_on = .{ .note = note, .velocity = velocity } }, off_reserve);
        }

        /// Send note_off. Can use the reserve window, so drops are rare.
        pub fn sendNoteOff(self: *Self, note: u8) bool {
            return self.ring.push(.{ .note_off = .{ .note = note } });
        }

        /// All notes off (panic). Always delivered, independent of ring state.
        pub fn panicAllNotesOff(self: *Self) void {
            _ = self.panic_gen.fetchAdd(1, .release);
        }

        // ---- consumer (Audio RT) ----

        pub fn pop(self: *Self) ?NoteEvent {
            return self.ring.pop();
        }

        /// True if a newer panic was issued since last check (consumes by updating `last_seen`).
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
    try testing.expect(ring.push(4)); // Holds up to 4
    try testing.expect(!ring.push(5)); // Full
    try testing.expectEqual(@as(?u32, 1), ring.pop());
    try testing.expect(ring.push(5)); // One slot freed
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
    // capacity 4, off_reserve 2 → note_on drops when used+2>=4 i.e. used>=2.
    var q = NoteQueue(4, 2){};
    try testing.expect(q.sendNoteOn(60, 1.0)); // used 0->1
    try testing.expect(q.sendNoteOn(61, 1.0)); // used 1->2
    try testing.expect(!q.sendNoteOn(62, 1.0)); // used 2, refused by reserve
    // note_off can use the reserve window so it gets in
    try testing.expect(q.sendNoteOff(60)); // used 2->3
    try testing.expect(q.sendNoteOff(61)); // used 3->4 (full)
    try testing.expect(!q.sendNoteOff(62)); // Completely full: does not get in
}

test "NoteQueue: panic is never dropped even when ring is full" {
    var q = NoteQueue(2, 0){};
    try testing.expect(q.sendNoteOn(60, 1.0));
    try testing.expect(q.sendNoteOn(61, 1.0)); // Full
    try testing.expect(!q.sendNoteOn(62, 1.0));
    // Panic still delivers even when the ring is full
    var seen: u32 = 0;
    try testing.expect(!q.takePanic(&seen));
    q.panicAllNotesOff();
    try testing.expect(q.takePanic(&seen));
    try testing.expect(!q.takePanic(&seen)); // Not consumed twice
}

test "SpscRing/NoteQueue: producer/consumer atomics are on separate cache lines (layout fixed)" {
    const cl = std.atomic.cache_line;
    const Ring = SpscRing(u32, 8);
    try testing.expect(@alignOf(Ring) >= cl);
    try testing.expect(@offsetOf(Ring, "head") % cl == 0);
    try testing.expect(@offsetOf(Ring, "tail") % cl == 0);
    const dist = if (@offsetOf(Ring, "tail") > @offsetOf(Ring, "head"))
        @offsetOf(Ring, "tail") - @offsetOf(Ring, "head")
    else
        @offsetOf(Ring, "head") - @offsetOf(Ring, "tail");
    try testing.expect(dist >= cl);

    const Q = NoteQueue(8, 2);
    const tail_off = @offsetOf(Q, "ring") + @offsetOf(Q.Ring, "tail");
    const panic_off = @offsetOf(Q, "panic_gen");
    try testing.expect(panic_off % cl == 0);
    try testing.expect(tail_off / cl != panic_off / cl); // Separate lines
}
