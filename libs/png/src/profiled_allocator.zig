const std = @import("std");
const Allocator = std.mem.Allocator;

/// ProfiledAllocator is an allocator wrapper that tracks memory-allocation statistics.
/// It tracks peak memory use, current memory use, and allocation count.
///
/// **Note**: this allocator is single-threaded only.
/// Concurrent access from multiple threads causes data races and undefined behaviour.
/// In multithreaded use, give each thread its own ProfiledAllocator instance.
pub const ProfiledAllocator = struct {
    child_allocator: Allocator,
    current_bytes: usize,
    peak_bytes: usize,
    allocation_count: usize,

    /// Wrap a child allocator and initialise ProfiledAllocator
    pub fn init(child: Allocator) ProfiledAllocator {
        return .{
            .child_allocator = child,
            .current_bytes = 0,
            .peak_bytes = 0,
            .allocation_count = 0,
        };
    }

    /// Return the std.mem.Allocator interface
    pub fn allocator(self: *ProfiledAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = remap,
            },
        };
    }

    /// Reset statistics (call before a benchmark)
    pub fn reset(self: *ProfiledAllocator) void {
        self.current_bytes = 0;
        self.peak_bytes = 0;
        self.allocation_count = 0;
    }

    /// Statistics struct
    pub const Stats = struct {
        /// Current memory use in bytes
        current_bytes: usize,
        /// Peak memory use in bytes — maximum since reset()
        peak_bytes: usize,
        /// Cumulative successful allocation count — not decreased on free
        allocation_count: usize,
    };

    /// Return the current statistics
    pub fn getStats(self: *ProfiledAllocator) Stats {
        return .{
            .current_bytes = self.current_bytes,
            .peak_bytes = self.peak_bytes,
            .allocation_count = self.allocation_count,
        };
    }

    // ========================================
    // Allocator vtable implementation
    // ========================================

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        ptr_align: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *ProfiledAllocator = @ptrCast(@alignCast(ctx));

        // Allocate from the child allocator
        const result = self.child_allocator.rawAlloc(len, ptr_align, ret_addr) orelse return null;

        // Update stats (ignore zero-length allocations)
        if (len > 0) {
            self.current_bytes += len;
            self.allocation_count += 1; // Cumulative count (not decreased on free)
            if (self.current_bytes > self.peak_bytes) {
                self.peak_bytes = self.current_bytes;
            }
        }

        return result;
    }

    fn resize(
        ctx: *anyopaque,
        buf: []u8,
        buf_align: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *ProfiledAllocator = @ptrCast(@alignCast(ctx));

        const success = self.child_allocator.rawResize(buf, buf_align, new_len, ret_addr);
        if (success) {
            // Update stats (compute the delta)
            const old_len = buf.len;
            if (new_len > old_len) {
                self.current_bytes += (new_len - old_len);
                if (self.current_bytes > self.peak_bytes) {
                    self.peak_bytes = self.current_bytes;
                }
            } else {
                const delta = old_len - new_len;
                std.debug.assert(self.current_bytes >= delta); // Underflow detection
                self.current_bytes -= delta;
            }
        }
        return success;
    }

    fn remap(
        ctx: *anyopaque,
        buf: []u8,
        buf_align: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *ProfiledAllocator = @ptrCast(@alignCast(ctx));

        const result = self.child_allocator.rawRemap(buf, buf_align, new_len, ret_addr) orelse return null;

        // Update stats (compute the delta)
        const old_len = buf.len;
        if (new_len > old_len) {
            self.current_bytes += (new_len - old_len);
            if (self.current_bytes > self.peak_bytes) {
                self.peak_bytes = self.current_bytes;
            }
        } else {
            const delta = old_len - new_len;
            std.debug.assert(self.current_bytes >= delta); // Underflow detection
            self.current_bytes -= delta;
        }

        return result;
    }

    fn free(
        ctx: *anyopaque,
        buf: []u8,
        buf_align: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *ProfiledAllocator = @ptrCast(@alignCast(ctx));

        // Update stats (ignore zero-length frees)
        if (buf.len > 0) {
            std.debug.assert(self.current_bytes >= buf.len); // Underflow detection
            self.current_bytes -= buf.len;
        }

        // Free via the child allocator
        self.child_allocator.rawFree(buf, buf_align, ret_addr);
    }
};
