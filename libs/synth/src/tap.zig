//! 出力タップ（Audio→GUI）。スペクトログラム可視化用。
//!
//! producer = オーディオ RT スレッド: マスター出力（interleaved stereo）を **コピーするだけ**。
//! 満杯ならブロックせず **drop**（取りこぼし可。可視化は最新が見えれば十分）。
//! consumer = メインスレッド: drain して FFT 等に回す。

const std = @import("std");
const AtomicUsize = std.atomic.Value(usize);

/// f32 サンプルの SPSC リング。RT 側は `write`（drop 可）、GUI 側は `read`。
pub fn SampleTap(comptime capacity: usize) type {
    if (!std.math.isPowerOfTwo(capacity)) @compileError("capacity must be a power of two");
    return struct {
        const Self = @This();
        const mask = capacity - 1;

        buffer: [capacity]f32 = undefined,
        head: AtomicUsize = AtomicUsize.init(0), // producer(RT)
        tail: AtomicUsize = AtomicUsize.init(0), // consumer(GUI)

        /// RT producer: `samples` をまとめて書く。空き不足なら丸ごと drop（ブロックしない）。
        pub fn write(self: *Self, samples: []const f32) void {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            const used = head -% tail;
            const free = capacity - used;
            if (samples.len > free) return; // drop（取りこぼし可）
            for (samples, 0..) |s, i| {
                self.buffer[(head +% i) & mask] = s;
            }
            self.head.store(head +% samples.len, .release);
        }

        /// GUI consumer: `dst` へ取り出す。取り出した個数を返す。
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
    const b = [_]f32{ 4, 5 }; // 2 > free 1 → 丸ごと drop
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
