//! PerIdStateStore capacity / LRU trim measurement (TASK-127).
//! 100 unique IDs/frame × 300 frames = 30,000 unique IDs を生成しても
//! 既定上限（max_entries=4096, trim_to=3072）により entry 数が収束することを assert する。
//!
//! ホットパス宣言: 300 フレームの計測専用ループ。RT / 通常 GUI 経路には影響しない。

const std = @import("std");
const gui = @import("gui");
const testing = std.testing;

const W: u32 = 1024;
const H: u32 = 768;
const IDS_PER_FRAME: usize = 100;
const FRAMES: usize = 300;
const MAX_ENTRIES: usize = gui.PerIdStateStore.default_max_entries; // 4096
const TRIM_TO: usize = gui.PerIdStateStore.default_trim_to; // 3072

/// Zig 0.16 には CountingAllocator が無いため、live/peak/alloc 回数を数える薄い wrapper。
const CountingAllocator = struct {
    parent: std.mem.Allocator,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,
    total_alloc_bytes: usize = 0,
    alloc_count: usize = 0,
    free_count: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.live_bytes += len;
        self.total_alloc_bytes += len;
        self.alloc_count += 1;
        if (self.live_bytes > self.peak_bytes) self.peak_bytes = self.live_bytes;
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.parent.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len > memory.len) {
            const d = new_len - memory.len;
            self.live_bytes += d;
            self.total_alloc_bytes += d;
            if (self.live_bytes > self.peak_bytes) self.peak_bytes = self.live_bytes;
        } else {
            self.live_bytes -= memory.len - new_len;
        }
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.parent.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len > memory.len) {
            const d = new_len - memory.len;
            self.live_bytes += d;
            self.total_alloc_bytes += d;
            if (self.live_bytes > self.peak_bytes) self.peak_bytes = self.live_bytes;
        } else {
            self.live_bytes -= memory.len - new_len;
        }
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ret_addr);
        self.live_bytes -= memory.len;
        self.free_count += 1;
    }
};

fn runLeakScenario(counter: *CountingAllocator) !struct {
    entries_frame_1: usize,
    entries_frame_300: usize,
    entries_final: usize,
    max_observed: usize,
    capacity: usize,
    live_after: usize,
    peak: usize,
    total_alloc: usize,
    allocs: usize,
    frees: usize,
    live_after_deinit: usize,
} {
    const a = counter.allocator();
    var ctx = gui.Context.init(a, gui.default_font);
    // deinit later for live-after-deinit measurement

    var entries_frame_1: usize = 0;
    var entries_frame_300: usize = 0;
    var max_observed: usize = 0;

    var frame: usize = 0;
    while (frame < FRAMES) : (frame += 1) {
        ctx.beginFrame(W, H);
        var i: usize = 0;
        while (i < IDS_PER_FRAME) : (i += 1) {
            // IDs never repeat across frames
            const id: gui.Id = @as(gui.Id, @intCast(frame * IDS_PER_FRAME + i + 1));
            // Touch PerIdStateStore (text/selectable path) and layout id path
            _ = ctx.perIdState(id);
            var lab: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&lab, "w{d}", .{i}) catch "w";
            const owned = ctx.allocator().dupe(u8, s) catch s;
            _ = ctx.selectableLabelId(id, owned, .{});
        }
        ctx.endFrame();
        const n = ctx.per_id_state.map.count();
        if (n > max_observed) max_observed = n;
        if (frame == 0) entries_frame_1 = n;
        if (frame == FRAMES - 1) entries_frame_300 = n;
    }

    const entries_final = ctx.per_id_state.map.count();
    const capacity = ctx.per_id_state.map.capacity();
    const live_after = counter.live_bytes;
    const peak = counter.peak_bytes;
    const total_alloc = counter.total_alloc_bytes;
    const allocs = counter.alloc_count;
    const frees = counter.free_count;

    ctx.deinit();
    const live_after_deinit = counter.live_bytes;

    return .{
        .entries_frame_1 = entries_frame_1,
        .entries_frame_300 = entries_frame_300,
        .entries_final = entries_final,
        .max_observed = max_observed,
        .capacity = capacity,
        .live_after = live_after,
        .peak = peak,
        .total_alloc = total_alloc,
        .allocs = allocs,
        .frees = frees,
        .live_after_deinit = live_after_deinit,
    };
}

test "gui leak: 100 unique IDs/frame x 300 frames stays within PerIdStateStore cap" {
    var parent_da: std.heap.DebugAllocator(.{}) = .init;
    defer _ = parent_da.deinit();
    var counter: CountingAllocator = .{ .parent = parent_da.allocator() };

    const r = try runLeakScenario(&counter);

    // TASK-127: 30,000 unique ID を生成しても endFrame 後の entry は max_entries 以下。
    // trim は count > max_entries のときだけ発火し trim_to まで減らすため、
    // final は常に 3072 固定ではなく [trim_to, max_entries] 付近に収まる。
    try testing.expectEqual(@as(usize, IDS_PER_FRAME), r.entries_frame_1);
    try testing.expect(r.entries_frame_300 <= MAX_ENTRIES);
    try testing.expect(r.entries_final <= MAX_ENTRIES);
    try testing.expect(r.max_observed <= MAX_ENTRIES);
    // 上限なし旧仕様（30000）へ退行していないこと
    try testing.expect(r.entries_final <= TRIM_TO + IDS_PER_FRAME * 12);
    try testing.expect(r.entries_final < IDS_PER_FRAME * FRAMES / 2);

    // Print allocator metrics for notes (not hard-asserted; environment-dependent)
    std.debug.print(
        \\
        \\[gui-leak] state_entries_frame_1={d}
        \\[gui-leak] state_entries_frame_300={d}
        \\[gui-leak] state_entries_final={d}
        \\[gui-leak] state_entries_max_observed={d}
        \\[gui-leak] per_id_state.map.capacity={d}
        \\[gui-leak] live_bytes_before_deinit={d}
        \\[gui-leak] peak_bytes={d}
        \\[gui-leak] total_alloc_bytes={d}
        \\[gui-leak] alloc_count={d}
        \\[gui-leak] free_count={d}
        \\[gui-leak] live_bytes_after_deinit={d}
        \\
    ,
        .{
            r.entries_frame_1,
            r.entries_frame_300,
            r.entries_final,
            r.max_observed,
            r.capacity,
            r.live_after,
            r.peak,
            r.total_alloc,
            r.allocs,
            r.frees,
            r.live_after_deinit,
        },
    );

    // After Context.deinit, store memory should be freed (live may still include parent bookkeeping)
    try testing.expect(r.live_after_deinit <= r.live_after);
}
