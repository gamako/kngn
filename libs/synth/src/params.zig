//! GUI→Audio の連続パラメータ受け渡し。
//!
//! - 単一 f32 パラメータは `u32` に bitcast して atomic 化（巨大 struct を一括 atomic にしない）。
//! - 複数値の整合性が要る patch 切替は triple-buffer mailbox（Mailbox。TASK-56 で 2 枚→3 枚）。
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

/// triple-buffer mailbox（TASK-56。旧 DoubleBuffer の後継）。複数値をまとめて整合的に差し替える patch 用。
/// 単一 producer(GUI) / 単一 consumer(Audio RT)。
///
/// 2 枚では「consumer がコピー中に producer が 2 回 publish」で torn read の理論余地が
/// あったため 3 枚に格上げ（libs/modular dyn.zig の Mailbox と同一セマンティクス。
/// TASK-40 マージ時に共有化しやすいよう API/名称も揃えている）。
/// 不変条件: {write_idx, read_idx, shared&IDX} は常に {0,1,2} の置換 = **consumer が
/// 保持中の slot を producer は決して書かない**。
pub fn Mailbox(comptime T: type) type {
    return struct {
        const Self = @This();
        const FRESH: u8 = 0x80;
        const IDX_MASK: u8 = 0x03;

        /// slot 間の false sharing を防ぐため各 slot を別キャッシュラインに置く
        const Slot = struct { value: T align(std.atomic.cache_line) };

        bufs: [3]Slot,
        // 共有 atomic / producer 専有 / consumer 専有 を各々別ラインに分離（TASK-56）
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

        /// producer(GUI): private write slot に書いてから shared と交換（never block）。
        pub fn publish(self: *Self, value: T) void {
            self.bufs[self.write_idx].value = value;
            const new: u8 = self.write_idx | FRESH;
            const old = self.shared.swap(new, .acq_rel);
            self.write_idx = old & IDX_MASK;
        }

        /// consumer(RT): fresh があれば read slot を shared と交換して最新を latch、無ければ現 slot 維持。
        /// 返る参照は次の acquire まで producer に書かれない（安全に読み続けられる）。
        pub fn acquire(self: *Self) *const T {
            const s = self.shared.load(.acquire);
            if (s & FRESH != 0) {
                const old = self.shared.swap(self.read_idx, .acq_rel);
                self.read_idx = old & IDX_MASK;
            }
            return &self.bufs[self.read_idx].value;
        }

        /// テスト用: 3 index が {0,1,2} の置換であることを確認（不変条件）。
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

test "Mailbox: publish/acquire の latest-wins と整合性" {
    const Patch = struct { cutoff: f32, res: f32 };
    var mb = Mailbox(Patch).init(.{ .cutoff = 1000, .res = 0.5 });
    try testing.expectEqual(@as(f32, 1000), mb.acquire().cutoff);

    mb.publish(.{ .cutoff = 2000, .res = 0.7 });
    const cur = mb.acquire().*;
    try testing.expectEqual(@as(f32, 2000), cur.cutoff);
    try testing.expectEqual(@as(f32, 0.7), cur.res);

    // 連続 publish は latest-wins。publish が無ければ同じ値を維持
    mb.publish(.{ .cutoff = 3000, .res = 0.1 });
    mb.publish(.{ .cutoff = 4000, .res = 0.2 });
    try testing.expectEqual(@as(f32, 4000), mb.acquire().cutoff);
    try testing.expectEqual(@as(f32, 4000), mb.acquire().cutoff);
}

test "Mailbox: 置換不変条件（publish/acquire 交互で常に {0,1,2} の置換）" {
    var mb = Mailbox(u64).init(0);
    try testing.expect(mb.indicesArePermutation());
    var i: u64 = 1;
    while (i < 50) : (i += 1) {
        mb.publish(i);
        try testing.expect(mb.indicesArePermutation());
        if (i % 3 != 0) { // acquire しないターンも混ぜる（連続 publish 経路）
            try testing.expectEqual(i, mb.acquire().*);
            try testing.expect(mb.indicesArePermutation());
        }
    }
}

test "Mailbox: consumer 保持 slot は後続 publish で書き換わらない（torn read 解消）" {
    var mb = Mailbox(u64).init(0);
    mb.publish(111);
    const held = mb.acquire(); // consumer が slot を latch
    try testing.expectEqual(@as(u64, 111), held.*);
    // consumer が読んでいる間に producer が 3 回 publish しても held の slot は不変
    mb.publish(222);
    mb.publish(333);
    mb.publish(444);
    try testing.expectEqual(@as(u64, 111), held.*);
    // 次の acquire で最新へ移る
    try testing.expectEqual(@as(u64, 444), mb.acquire().*);
}

test "Mailbox: shared/write_idx/read_idx/slot が別キャッシュライン（レイアウト固定）" {
    const cl = std.atomic.cache_line;
    const M = Mailbox(u32);
    try testing.expect(@alignOf(M) >= cl);
    try testing.expect(@offsetOf(M, "shared") % cl == 0);
    try testing.expect(@offsetOf(M, "write_idx") % cl == 0);
    try testing.expect(@offsetOf(M, "read_idx") % cl == 0);
    try testing.expect(@offsetOf(M, "shared") / cl != @offsetOf(M, "write_idx") / cl);
    try testing.expect(@offsetOf(M, "write_idx") / cl != @offsetOf(M, "read_idx") / cl);
    // slot 同士も別ライン（Slot が cache_line align）
    try testing.expect(@sizeOf(M.Slot) % cl == 0 or @alignOf(M.Slot) >= cl);
}
