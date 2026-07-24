//! bench 専用のピークメモリ追跡 allocator ラッパー（TASK-156.5 R10）。
//! 子 allocator（DebugAllocator）をラップし、reset() 以降の最大確保バイト数を追跡する。
//! bench-gui / bench-gui-frame / bench-blit / bench-viz が共有する（4 箇所への複製を避ける）。
//! 単一スレッド専用（bench はどれも single-thread で回す前提）。

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PeakTrackingAllocator = struct {
    child: Allocator,
    current_bytes: usize = 0,
    peak_bytes: usize = 0,

    pub fn init(child: Allocator) PeakTrackingAllocator {
        return .{ .child = child };
    }

    pub fn allocator(self: *PeakTrackingAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    /// 次の計測区間の直前に呼ぶ（peak_bytes を 0 から測り直す）。
    pub fn reset(self: *PeakTrackingAllocator) void {
        self.peak_bytes = 0;
    }

    fn bump(self: *PeakTrackingAllocator) void {
        if (self.current_bytes > self.peak_bytes) self.peak_bytes = self.current_bytes;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PeakTrackingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.current_bytes += len;
        self.bump();
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *PeakTrackingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.child.rawResize(memory, alignment, new_len, ret_addr);
        if (ok) {
            if (new_len > memory.len) {
                self.current_bytes += new_len - memory.len;
                self.bump();
            } else {
                self.current_bytes -= memory.len - new_len;
            }
        }
        return ok;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *PeakTrackingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len > memory.len) {
            self.current_bytes += new_len - memory.len;
            self.bump();
        } else {
            self.current_bytes -= memory.len - new_len;
        }
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *PeakTrackingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.current_bytes -= memory.len;
    }
};

test "PeakTrackingAllocator: alloc/free を経て peak が最大値を保持する" {
    var tracker = PeakTrackingAllocator.init(std.testing.allocator);
    const a = tracker.allocator();

    const p1 = try a.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), tracker.peak_bytes);
    const p2 = try a.alloc(u8, 200);
    try std.testing.expectEqual(@as(usize, 300), tracker.peak_bytes);
    a.free(p1);
    // free 後も current は減るが peak は最大値のまま残る。
    try std.testing.expectEqual(@as(usize, 300), tracker.peak_bytes);
    try std.testing.expectEqual(@as(usize, 200), tracker.current_bytes);
    a.free(p2);
    try std.testing.expectEqual(@as(usize, 0), tracker.current_bytes);
}

test "PeakTrackingAllocator: reset() で次区間の peak を測り直す" {
    var tracker = PeakTrackingAllocator.init(std.testing.allocator);
    const a = tracker.allocator();

    const p1 = try a.alloc(u8, 500);
    try std.testing.expectEqual(@as(usize, 500), tracker.peak_bytes);
    a.free(p1);
    tracker.reset();
    try std.testing.expectEqual(@as(usize, 0), tracker.peak_bytes);

    const p2 = try a.alloc(u8, 50);
    try std.testing.expectEqual(@as(usize, 50), tracker.peak_bytes);
    a.free(p2);
}
