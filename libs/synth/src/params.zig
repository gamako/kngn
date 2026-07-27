//! Continuous-parameter hand-off GUI→Audio.
//!
//! - A single f32 parameter is bitcast to `u32` and made atomic (do not atomicise a large struct wholesale).
//! - Patch switches that need multi-value consistency use a triple-buffer mailbox (Mailbox; three slots, not two).
//! Memory ordering: GUI-side store = release / Audio-side load = acquire.

const std = @import("std");

/// Atomic parameter holding an `f32` bitcast to `u32`.
pub const AtomicF32 = struct {
    bits: std.atomic.Value(u32),

    pub fn init(v: f32) AtomicF32 {
        return .{ .bits = std.atomic.Value(u32).init(@bitCast(v)) };
    }

    /// GUI side: publish with release.
    pub fn store(self: *AtomicF32, v: f32) void {
        self.bits.store(@bitCast(v), .release);
    }

    /// Audio side: read with acquire.
    pub fn load(self: *const AtomicF32) f32 {
        return @bitCast(self.bits.load(.acquire));
    }
};

/// Triple-buffer mailbox. For patches that swap multiple values coherently.
/// Single producer (GUI) / single consumer (Audio RT).
///
/// With only two slots, if the producer publishes twice while the consumer is still copying there is a
/// theoretical torn-read window — so this is three slots (same semantics as the Mailbox in libs/modular dyn.zig;
/// API/names aligned so they stay easy to share). See docs/adr/015 for why the third buffer is spent.
/// Invariant: {write_idx, read_idx, shared&IDX} is always a permutation of {0,1,2} = **the producer
/// never writes the slot the consumer currently holds**.
pub fn Mailbox(comptime T: type) type {
    return struct {
        const Self = @This();
        const FRESH: u8 = 0x80;
        const IDX_MASK: u8 = 0x03;

        /// Place each slot on its own cache line to prevent false sharing between slots
        const Slot = struct { value: T align(std.atomic.cache_line) };

        bufs: [3]Slot,
        // Separate shared atomic / producer-private / consumer-private onto their own lines
        shared: std.atomic.Value(u8) align(std.atomic.cache_line),
        write_idx: u8 align(std.atomic.cache_line), // producer-private
        read_idx: u8 align(std.atomic.cache_line), // consumer-private

        pub fn init(initial: T) Self {
            return .{
                .bufs = .{ .{ .value = initial }, .{ .value = initial }, .{ .value = initial } },
                .shared = std.atomic.Value(u8).init(2), // slot2 published(no fresh) / write=0 / read=1
                .write_idx = 0,
                .read_idx = 1,
            };
        }

        /// producer(GUI): write the private write slot then swap with shared (never block).
        pub fn publish(self: *Self, value: T) void {
            self.bufs[self.write_idx].value = value;
            const new: u8 = self.write_idx | FRESH;
            const old = self.shared.swap(new, .acq_rel);
            self.write_idx = old & IDX_MASK;
        }

        /// consumer(RT): if fresh, swap the read slot with shared and latch the latest; otherwise keep the current slot.
        /// The returned reference is not written by the producer until the next acquire (safe to keep reading).
        pub fn acquire(self: *Self) *const T {
            const s = self.shared.load(.acquire);
            if (s & FRESH != 0) {
                const old = self.shared.swap(self.read_idx, .acq_rel);
                self.read_idx = old & IDX_MASK;
            }
            return &self.bufs[self.read_idx].value;
        }

        /// Test helper: assert the three indices are a permutation of {0,1,2} (the invariant).
        pub fn indicesArePermutation(self: *const Self) bool {
            const a = self.write_idx & IDX_MASK;
            const b = self.read_idx & IDX_MASK;
            const c = self.shared.load(.monotonic) & IDX_MASK;
            return a != b and b != c and a != c and a < 3 and b < 3 and c < 3;
        }
    };
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "AtomicF32: store/load roundtrip" {
    var p = AtomicF32.init(0.0);
    try testing.expectEqual(@as(f32, 0.0), p.load());
    p.store(440.0);
    try testing.expectEqual(@as(f32, 440.0), p.load());
    p.store(-1.5);
    try testing.expectEqual(@as(f32, -1.5), p.load());
}

test "Mailbox: publish/acquire latest-wins consistency" {
    const Patch = struct { cutoff: f32, res: f32 };
    var mb = Mailbox(Patch).init(.{ .cutoff = 1000, .res = 0.5 });
    try testing.expectEqual(@as(f32, 1000), mb.acquire().cutoff);

    mb.publish(.{ .cutoff = 2000, .res = 0.7 });
    const cur = mb.acquire().*;
    try testing.expectEqual(@as(f32, 2000), cur.cutoff);
    try testing.expectEqual(@as(f32, 0.7), cur.res);

    // Consecutive publishes are latest-wins. With no publish, the same value is kept
    mb.publish(.{ .cutoff = 3000, .res = 0.1 });
    mb.publish(.{ .cutoff = 4000, .res = 0.2 });
    try testing.expectEqual(@as(f32, 4000), mb.acquire().cutoff);
    try testing.expectEqual(@as(f32, 4000), mb.acquire().cutoff);
}

test "Mailbox: permutation invariant (publish/acquire always keep a permutation of {0,1,2})" {
    var mb = Mailbox(u64).init(0);
    try testing.expect(mb.indicesArePermutation());
    var i: u64 = 1;
    while (i < 50) : (i += 1) {
        mb.publish(i);
        try testing.expect(mb.indicesArePermutation());
        if (i % 3 != 0) { // Also mix in turns that skip acquire (consecutive-publish path)
            try testing.expectEqual(i, mb.acquire().*);
            try testing.expect(mb.indicesArePermutation());
        }
    }
}

test "Mailbox: consumer-held slot is not rewritten by later publishes (no torn read)" {
    var mb = Mailbox(u64).init(0);
    mb.publish(111);
    const held = mb.acquire(); // consumer latches a slot
    try testing.expectEqual(@as(u64, 111), held.*);
    // Even if the producer publishes 3 times while the consumer is reading, the held slot is unchanged
    mb.publish(222);
    mb.publish(333);
    mb.publish(444);
    try testing.expectEqual(@as(u64, 111), held.*);
    // The next acquire moves to the latest
    try testing.expectEqual(@as(u64, 444), mb.acquire().*);
}

test "Mailbox: shared/write_idx/read_idx/slot are on separate cache lines (layout fixed)" {
    const cl = std.atomic.cache_line;
    const M = Mailbox(u32);
    try testing.expect(@alignOf(M) >= cl);
    try testing.expect(@offsetOf(M, "shared") % cl == 0);
    try testing.expect(@offsetOf(M, "write_idx") % cl == 0);
    try testing.expect(@offsetOf(M, "read_idx") % cl == 0);
    try testing.expect(@offsetOf(M, "shared") / cl != @offsetOf(M, "write_idx") / cl);
    try testing.expect(@offsetOf(M, "write_idx") / cl != @offsetOf(M, "read_idx") / cl);
    // Slots are also on separate lines (Slot is cache_line-aligned)
    try testing.expect(@sizeOf(M.Slot) % cl == 0 or @alignOf(M.Slot) >= cl);
}
