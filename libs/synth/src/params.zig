//! GUI→Audio の連続パラメータ受け渡し。
//!
//! - 単一 f32 パラメータは `u32` に bitcast して atomic 化（巨大 struct を一括 atomic にしない）。
//! - 複数値の整合性が要る patch 切替は double-buffer + atomic index publish。
//! メモリオーダリング: GUI 側 store = release / Audio 側 load = acquire。

const std = @import("std");

/// `f32` を `u32` に bitcast して持つ atomic パラメータ。
pub const AtomicF32 = struct {
    bits: std.atomic.Value(u32),

    pub fn init(v: f32) AtomicF32 {
        return .{ .bits = std.atomic.Value(u32).init(@bitCast(v)) };
    }

    /// GUI 側: release で公開。
    pub fn store(self: *AtomicF32, v: f32) void {
        self.bits.store(@bitCast(v), .release);
    }

    /// Audio 側: acquire で読む。
    pub fn load(self: *const AtomicF32) f32 {
        return @bitCast(self.bits.load(.acquire));
    }
};

/// double-buffer + atomic index publish。複数値をまとめて整合的に差し替える patch 用。
/// 単一 producer(GUI) / 単一 consumer(Audio)。
pub fn DoubleBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffers: [2]T,
        index: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        pub fn init(initial: T) Self {
            return .{ .buffers = .{ initial, initial } };
        }

        /// producer: 裏バッファに書いてから index を publish。
        pub fn publish(self: *Self, value: T) void {
            const cur = self.index.load(.monotonic);
            const back = cur ^ 1;
            self.buffers[back] = value;
            self.index.store(back, .release);
        }

        /// consumer: 現在公開中の値を読む。
        pub fn current(self: *const Self) T {
            const idx = self.index.load(.acquire);
            return self.buffers[idx];
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

test "DoubleBuffer: publish/current integrity" {
    const Patch = struct { cutoff: f32, res: f32 };
    var db = DoubleBuffer(Patch).init(.{ .cutoff = 1000, .res = 0.5 });
    try testing.expectEqual(@as(f32, 1000), db.current().cutoff);

    db.publish(.{ .cutoff = 2000, .res = 0.7 });
    const cur = db.current();
    try testing.expectEqual(@as(f32, 2000), cur.cutoff);
    try testing.expectEqual(@as(f32, 0.7), cur.res);

    // 連続 publish で別バッファに切り替わる
    db.publish(.{ .cutoff = 3000, .res = 0.1 });
    try testing.expectEqual(@as(f32, 3000), db.current().cutoff);
}
