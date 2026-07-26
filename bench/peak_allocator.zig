//! Bench-only peak-memory tracking allocator wrapper.
//! Wraps a child allocator (DebugAllocator) and tracks the maximum allocated bytes since reset().
//! Shared by bench-gui / bench-gui-frame / bench-blit / bench-viz (avoids copying it in 4 places).
//! Single-thread only (every bench runs single-threaded).

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

    /// Call just before the next measurement window (restarts peak_bytes from 0).
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

test "PeakTrackingAllocator: peak keeps the maximum across alloc/free" {
    var tracker = PeakTrackingAllocator.init(std.testing.allocator);
    const a = tracker.allocator();

    const p1 = try a.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), tracker.peak_bytes);
    const p2 = try a.alloc(u8, 200);
    try std.testing.expectEqual(@as(usize, 300), tracker.peak_bytes);
    a.free(p1);
    // After free, current falls but peak keeps the maximum.
    try std.testing.expectEqual(@as(usize, 300), tracker.peak_bytes);
    try std.testing.expectEqual(@as(usize, 200), tracker.current_bytes);
    a.free(p2);
    try std.testing.expectEqual(@as(usize, 0), tracker.current_bytes);
}

test "PeakTrackingAllocator: reset() restarts peak for the next window" {
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
