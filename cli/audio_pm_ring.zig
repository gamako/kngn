//! Pure postMessage audio ring invariants (host-testable).
//!
//! Mirrors the AudioWorklet postMessage transport contract in `web/kngn-worklet.js`:
//! fixed 128-frame blocks, 8-block capacity, no silent partial discard of a block.
//! Non-128 quanta are rejected (bad_quantum) rather than corrupting the ring.
//!
//! All functions are free of allocation. Unit tests pin underrun / capacity / quantum rules.

const std = @import("std");

pub const frames_per_block: u32 = 128;
pub const channels: u32 = 2;
pub const samples_per_block: u32 = frames_per_block * channels;
/// Ring capacity. The producer chooses how much of it to keep filled (it starts low for
/// latency and grows after an underrun), so this is the ceiling the transport allows.
pub const max_blocks: u32 = 24;

pub const PullResult = enum {
    ok,
    underrun,
    bad_quantum,
};

pub const Ring = struct {
    /// Interleaved f32 storage: max_blocks * samples_per_block.
    storage: []f32,
    write: u32 = 0,
    read: u32 = 0,
    count: u32 = 0,
    underruns: u32 = 0,
    quantum_mismatches: u32 = 0,
    /// Blocks the producer offered while the ring was full. A dropped block is rendered
    /// audio that never reaches the output, so it is counted and reported rather than
    /// absorbed: it is the signature of a producer pacing against something other than
    /// the ring depth.
    drops: u32 = 0,
    /// Samples already consumed from the current read block (for split quanta — unused when quantum is fixed 128).
    read_offset: u32 = 0,

    pub fn init(storage: []f32) Ring {
        std.debug.assert(storage.len >= max_blocks * samples_per_block);
        return .{ .storage = storage };
    }

    /// Push one full block (exactly samples_per_block samples). Returns false if full.
    pub fn pushBlock(self: *Ring, block: []const f32) bool {
        std.debug.assert(block.len >= samples_per_block);
        if (self.count >= max_blocks) {
            self.drops += 1;
            return false;
        }
        const base = self.write * samples_per_block;
        @memcpy(self.storage[base..][0..samples_per_block], block[0..samples_per_block]);
        self.write = (self.write + 1) % max_blocks;
        self.count += 1;
        return true;
    }

    /// Pull `frames` into deinterleaved or interleaved? We use interleaved stereo out of length frames*channels.
    /// Contract: only `frames_per_block` is accepted; anything else increments quantum_mismatches and returns .bad_quantum.
    pub fn pullInterleaved(self: *Ring, frames: u32, out: []f32) PullResult {
        if (frames != frames_per_block) {
            self.quantum_mismatches += 1;
            @memset(out[0..@min(out.len, frames * channels)], 0);
            return .bad_quantum;
        }
        const need = frames * channels;
        std.debug.assert(out.len >= need);

        if (self.count == 0) {
            self.underruns += 1;
            @memset(out[0..need], 0);
            return .underrun;
        }

        const base = self.read * samples_per_block + self.read_offset;
        @memcpy(out[0..need], self.storage[base..][0..need]);
        // Full block consumed (fixed quantum == block size).
        self.read = (self.read + 1) % max_blocks;
        self.count -= 1;
        self.read_offset = 0;
        return .ok;
    }
};

test "underrun increments and silences" {
    var buf: [max_blocks * samples_per_block]f32 = undefined;
    var ring = Ring.init(&buf);
    var out: [samples_per_block]f32 = undefined;
    try std.testing.expect(ring.pullInterleaved(frames_per_block, &out) == .underrun);
    try std.testing.expectEqual(@as(u32, 1), ring.underruns);
    try std.testing.expectEqual(@as(f32, 0), out[0]);
}

test "queue capacity rejects overflow" {
    var buf: [max_blocks * samples_per_block]f32 = undefined;
    var ring = Ring.init(&buf);
    var block: [samples_per_block]f32 = undefined;
    @memset(&block, 1.0);
    var i: u32 = 0;
    while (i < max_blocks) : (i += 1) {
        try std.testing.expect(ring.pushBlock(&block));
    }
    try std.testing.expect(!ring.pushBlock(&block));
    try std.testing.expectEqual(max_blocks, ring.count);
    try std.testing.expectEqual(@as(u32, 1), ring.drops);
}

test "a producer pacing on ring depth never drops a block" {
    // The transport's contract: top the ring back up to capacity, where "how full" is
    // the ring's own count. Pacing on anything else (for instance on how many transfer
    // buffers have come back) renders faster than playback and the surplus is dropped.
    var buf: [max_blocks * samples_per_block]f32 = undefined;
    var ring = Ring.init(&buf);
    var block: [samples_per_block]f32 = undefined;
    @memset(&block, 0.5);
    var out: [samples_per_block]f32 = undefined;

    var tick: u32 = 0;
    while (tick < 1000) : (tick += 1) {
        while (ring.count < max_blocks) {
            try std.testing.expect(ring.pushBlock(&block));
        }
        try std.testing.expectEqual(PullResult.ok, ring.pullInterleaved(frames_per_block, &out));
    }
    try std.testing.expectEqual(@as(u32, 0), ring.drops);
    try std.testing.expectEqual(@as(u32, 0), ring.underruns);
}

test "non-128 quantum is bad_quantum and does not consume" {
    var buf: [max_blocks * samples_per_block]f32 = undefined;
    var ring = Ring.init(&buf);
    var block: [samples_per_block]f32 = undefined;
    @memset(&block, 0.5);
    try std.testing.expect(ring.pushBlock(&block));
    var out64: [64 * channels]f32 = undefined;
    try std.testing.expect(ring.pullInterleaved(64, &out64) == .bad_quantum);
    try std.testing.expectEqual(@as(u32, 1), ring.quantum_mismatches);
    try std.testing.expectEqual(@as(u32, 1), ring.count); // not consumed
    var out128: [samples_per_block]f32 = undefined;
    try std.testing.expect(ring.pullInterleaved(frames_per_block, &out128) == .ok);
    try std.testing.expectEqual(@as(f32, 0.5), out128[0]);
    try std.testing.expectEqual(@as(u32, 0), ring.count);
}

test "fifo order across blocks" {
    var buf: [max_blocks * samples_per_block]f32 = undefined;
    var ring = Ring.init(&buf);
    var a: [samples_per_block]f32 = undefined;
    var b: [samples_per_block]f32 = undefined;
    @memset(&a, 1.0);
    @memset(&b, 2.0);
    try std.testing.expect(ring.pushBlock(&a));
    try std.testing.expect(ring.pushBlock(&b));
    var out: [samples_per_block]f32 = undefined;
    try std.testing.expect(ring.pullInterleaved(frames_per_block, &out) == .ok);
    try std.testing.expectEqual(@as(f32, 1.0), out[0]);
    try std.testing.expect(ring.pullInterleaved(frames_per_block, &out) == .ok);
    try std.testing.expectEqual(@as(f32, 2.0), out[0]);
}
