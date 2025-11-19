const std = @import("std");
const Allocator = std.mem.Allocator;

/// ProfiledAllocator はメモリ割り当てを追跡し、統計情報を提供するアロケータラッパーです。
/// ピークメモリ使用量、現在のメモリ使用量、割り当て回数を追跡します。
pub const ProfiledAllocator = struct {
    child_allocator: Allocator,
    current_bytes: usize,
    peak_bytes: usize,
    allocation_count: usize,

    /// 子アロケータをラップして ProfiledAllocator を初期化します
    pub fn init(child: Allocator) ProfiledAllocator {
        return .{
            .child_allocator = child,
            .current_bytes = 0,
            .peak_bytes = 0,
            .allocation_count = 0,
        };
    }

    /// std.mem.Allocator インターフェースを返します
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

    /// 統計情報をリセットします（ベンチマーク前に呼び出す）
    pub fn reset(self: *ProfiledAllocator) void {
        self.current_bytes = 0;
        self.peak_bytes = 0;
        self.allocation_count = 0;
    }

    /// 統計情報の構造体
    pub const Stats = struct {
        current_bytes: usize,
        peak_bytes: usize,
        allocation_count: usize,
    };

    /// 現在の統計情報を取得します
    pub fn getStats(self: *ProfiledAllocator) Stats {
        return .{
            .current_bytes = self.current_bytes,
            .peak_bytes = self.peak_bytes,
            .allocation_count = self.allocation_count,
        };
    }

    // ========================================
    // Allocator vtable の実装
    // ========================================

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        ptr_align: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *ProfiledAllocator = @ptrCast(@alignCast(ctx));

        // 子アロケータから割り当て
        const result = self.child_allocator.rawAlloc(len, ptr_align, ret_addr) orelse return null;

        // 統計を更新（長さ 0 の割り当ては無視）
        if (len > 0) {
            self.current_bytes += len;
            self.allocation_count += 1;
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
            // 統計を更新（差分を計算）
            const old_len = buf.len;
            if (new_len > old_len) {
                self.current_bytes += (new_len - old_len);
                if (self.current_bytes > self.peak_bytes) {
                    self.peak_bytes = self.current_bytes;
                }
            } else {
                self.current_bytes -= (old_len - new_len);
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

        // 統計を更新（差分を計算）
        const old_len = buf.len;
        if (new_len > old_len) {
            self.current_bytes += (new_len - old_len);
            if (self.current_bytes > self.peak_bytes) {
                self.peak_bytes = self.current_bytes;
            }
        } else {
            self.current_bytes -= (old_len - new_len);
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

        // 統計を更新（長さ 0 の解放は無視）
        if (buf.len > 0) {
            self.current_bytes -= buf.len;
        }

        // 子アロケータで解放
        self.child_allocator.rawFree(buf, buf_align, ret_addr);
    }
};
