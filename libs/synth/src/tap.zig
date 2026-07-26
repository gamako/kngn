//! Output tap (Audio→GUI). For spectrogram visualisation.
//!
//! producer = audio RT thread: **only copies** the master output (interleaved stereo).
//! When full, does not block — **drops** (loss is allowed; visualisation only needs the latest).
//! consumer = main thread: drains into FFT etc.

const std = @import("std");
const AtomicUsize = std.atomic.Value(usize);

/// SPSC ring of f32 samples. RT side `write` (may drop); GUI side `read`.
pub fn SampleTap(comptime capacity: usize) type {
    if (!std.math.isPowerOfTwo(capacity)) @compileError("capacity must be a power of two");
    return struct {
        const Self = @This();
        const mask = capacity - 1;

        buffer: [capacity]f32 = undefined,
        // Separate head(RT writes) / tail(GUI writes) onto different cache lines (avoid false sharing).
        head: AtomicUsize align(std.atomic.cache_line) = AtomicUsize.init(0), // producer(RT)
        tail: AtomicUsize align(std.atomic.cache_line) = AtomicUsize.init(0), // consumer(GUI)

        /// RT producer: write `samples` as a batch. If space is insufficient, drop the whole batch (never blocks).
        pub fn write(self: *Self, samples: []const f32) void {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            const used = head -% tail;
            const free = capacity - used;
            if (samples.len > free) return; // drop (loss is allowed)
            for (samples, 0..) |s, i| {
                self.buffer[(head +% i) & mask] = s;
            }
            self.head.store(head +% samples.len, .release);
        }

        /// GUI consumer: drain into `dst`. Returns how many were taken.
        pub fn read(self: *Self, dst: []f32) usize {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.acquire);
            const avail = head -% tail;
            const n = @min(avail, dst.len);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                dst[i] = self.buffer[(tail +% i) & mask];
            }
            self.tail.store(tail +% n, .release);
            return n;
        }
    };
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "SampleTap: write/read roundtrip" {
    var tap = SampleTap(8){};
    const in = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    tap.write(&in);
    var out: [4]f32 = undefined;
    try testing.expectEqual(@as(usize, 4), tap.read(&out));
    try testing.expectEqualSlices(f32, &in, &out);
}

test "SampleTap: drop when insufficient space (never blocks)" {
    var tap = SampleTap(4){};
    const a = [_]f32{ 1, 2, 3 };
    tap.write(&a); // used 3, free 1
    const b = [_]f32{ 4, 5 }; // 2 > free 1 → drop the whole batch
    tap.write(&b);
    var out: [4]f32 = undefined;
    const n = tap.read(&out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(f32, &a, out[0..3]);
}

test "SampleTap: partial read and wrap-around" {
    var tap = SampleTap(4){};
    var round: u32 = 0;
    while (round < 10) : (round += 1) {
        const in = [_]f32{ @floatFromInt(round), @floatFromInt(round + 1) };
        tap.write(&in);
        var out: [2]f32 = undefined;
        try testing.expectEqual(@as(usize, 2), tap.read(&out));
        try testing.expectEqualSlices(f32, &in, &out);
    }
}

test "SampleTap: head/tail are on separate cache lines (layout fixed)" {
    const cl = std.atomic.cache_line;
    const Tap = SampleTap(8);
    try testing.expect(@alignOf(Tap) >= cl);
    try testing.expect(@offsetOf(Tap, "head") % cl == 0);
    try testing.expect(@offsetOf(Tap, "tail") % cl == 0);
    const dist = if (@offsetOf(Tap, "tail") > @offsetOf(Tap, "head"))
        @offsetOf(Tap, "tail") - @offsetOf(Tap, "head")
    else
        @offsetOf(Tap, "head") - @offsetOf(Tap, "tail");
    try testing.expect(dist >= cl);
}
