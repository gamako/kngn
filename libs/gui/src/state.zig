// interaction state (hot / active / focused) and per-widget persistent state.
//
// hot_id is a one-frame-delayed stable hover ID (for draw feedback). Hover computed this
// frame accumulates in next_hot_id and is promoted to hot_id in beginFrame. Nested
// widgets that swap the hover subject within a frame therefore do not flicker.
// Drawing checks state.hot_id == id (buttonBehavior's result.hovered is the raw same-frame value).

const id_mod = @import("id.zig");
const text_edit = @import("text_edit.zig");

pub const Id = id_mod.Id;

/// Cross-frame state keyed by ID for widgets such as SelectableLabel.
pub const PerIdState = struct {
    selection: text_edit.SelectionState = .{},
    last_click_time: f64 = -1.0,
    last_click_pos: struct { x: i32 = 0, y: i32 = 0 } = .{},
    /// TextInput caret is a codepoint index kept in sync with selection.extent.
    caret: usize = 0,
    /// Horizontal scroll in px from the left edge of the content.
    scroll_x: i32 = 0,
    /// Context virtual time when the caret became visible.
    caret_blink_start_s: f64 = 0,
};

/// State store that lazily allocates per-ID state only for IDs that need it.
///
/// # Capacity / LRU trim contract
///
/// - Method: touch via frame generation + an ID-linked LRU list.
/// - Defaults: `max_entries=4096`, `trim_to=3072` (25% headroom to limit per-frame churn).
/// - touch: `getOrPut` records the current generation and moves the entry to the LRU tail in O(1).
///   `get` is read-only and does not touch. Visible widgets are touched every frame via
///   `Context.perIdState` → `getOrPut`.
/// - trim fires: only at the frame boundary at the end of `Context.endFrame` when `entry_count > max_entries`.
///   Never trim inside the widget-build loop.
/// - Visible state: entries with `last_touched_frame == current_generation` are never deleted.
/// - In-use state: entries matching `active_id` / `focused_id` / `hot_id` / `next_hot_id` are
///   excluded from trim regardless of last_touched (keeps briefly hidden focus/drag/hover).
/// - Hidden state: may be discarded from oldest LRU when over capacity. If the same ID is
///   shown again after deletion, `PerIdState` is recreated from defaults (selection / caret /
///   TextInput `scroll_x` / double-click info reset). Kept while under the limit.
/// - If protected entries alone cannot reach `trim_to`, prefer visible and in-use state and
///   temporarily allow exceeding `max_entries`.
/// - Caller-owned data stays outside the store: `TextBuffer` (`std.ArrayList(u8)`) and ScrollArea's
///   caller-owned `*Vec2f` are not in this store. Entry discard leaves their content and capacity intact.
pub const PerIdStateStore = struct {
    pub const default_max_entries: usize = 4096;
    pub const default_trim_to: usize = 3072;

    /// map value: public state + LRU metadata. Links are by ID (avoids pointer invalidation on rehash).
    /// `lru_prev` / `lru_next` of 0 means unlinked (Id=0 is unused as a widget ID).
    pub const Entry = struct {
        state: PerIdState = .{},
        last_touched_frame: u64 = 0,
        lru_prev: Id = 0,
        lru_next: Id = 0,
    };

    /// Interaction IDs protected during trim (0 = none).
    pub const ProtectedIds = struct {
        active_id: Id = 0,
        focused_id: Id = 0,
        hot_id: Id = 0,
        next_hot_id: Id = 0,
    };

    map: std.AutoHashMapUnmanaged(Id, Entry) = .empty,
    /// Store-local frame generation (independent of Context.frame_index; same contract under beginFrameAt).
    generation: u64 = 0,
    /// LRU head = oldest (least recently used). 0 = empty.
    lru_head: Id = 0,
    /// LRU tail = newest (most recently used). 0 = empty.
    lru_tail: Id = 0,
    max_entries: usize = default_max_entries,
    trim_to: usize = default_trim_to,

    pub fn deinit(self: *PerIdStateStore, gpa: std.mem.Allocator) void {
        self.map.deinit(gpa);
        self.* = .{};
    }

    /// Advance generation at frame start. Called from Context.beginFrameAtInternal.
    pub fn beginFrame(self: *PerIdStateStore) void {
        self.generation +%= 1;
    }

    pub fn count(self: *const PerIdStateStore) usize {
        return self.map.count();
    }

    pub fn getOrPut(self: *PerIdStateStore, gpa: std.mem.Allocator, id: Id) *PerIdState {
        std.debug.assert(id != 0);
        const gop = self.map.getOrPut(gpa, id) catch @panic("PerIdStateStore: OOM");
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
            // Link a new entry as the LRU tail. Link by ID to survive rehash after getOrPut.
            self.linkAsTail(id);
        } else if (self.lru_tail != id) {
            self.unlink(id);
            self.linkAsTail(id);
        }
        const e = self.map.getPtr(id).?;
        e.last_touched_frame = self.generation;
        return &e.state;
    }

    pub fn get(self: *const PerIdStateStore, id: Id) ?*const PerIdState {
        const e = self.map.getPtr(id) orelse return null;
        return &e.state;
    }

    /// Call only at the frame boundary. If `count > max_entries`, delete oldest LRU entries down to `trim_to`.
    /// Exclude same-frame touch / protected IDs. If protected alone cannot reach `trim_to`, allow overflow.
    pub fn trim(self: *PerIdStateStore, protected: ProtectedIds) void {
        if (self.map.count() <= self.max_entries) return;

        var cursor = self.lru_head;
        while (self.map.count() > self.trim_to and cursor != 0) {
            const id = cursor;
            const e = self.map.getPtr(id) orelse break;
            const next = e.lru_next;
            if (!self.isProtected(id, e, protected)) {
                self.unlink(id);
                _ = self.map.remove(id);
            }
            cursor = next;
        }
    }

    fn isProtected(self: *const PerIdStateStore, id: Id, e: *const Entry, protected: ProtectedIds) bool {
        if (e.last_touched_frame == self.generation) return true;
        if (id == protected.active_id and id != 0) return true;
        if (id == protected.focused_id and id != 0) return true;
        if (id == protected.hot_id and id != 0) return true;
        if (id == protected.next_hot_id and id != 0) return true;
        return false;
    }

    fn unlink(self: *PerIdStateStore, id: Id) void {
        const e = self.map.getPtr(id) orelse return;
        const prev = e.lru_prev;
        const next = e.lru_next;
        if (prev != 0) {
            if (self.map.getPtr(prev)) |p| p.lru_next = next;
        } else {
            self.lru_head = next;
        }
        if (next != 0) {
            if (self.map.getPtr(next)) |n| n.lru_prev = prev;
        } else {
            self.lru_tail = prev;
        }
        e.lru_prev = 0;
        e.lru_next = 0;
    }

    fn linkAsTail(self: *PerIdStateStore, id: Id) void {
        const e = self.map.getPtr(id).?;
        e.lru_prev = self.lru_tail;
        e.lru_next = 0;
        if (self.lru_tail != 0) {
            self.map.getPtr(self.lru_tail).?.lru_next = id;
        } else {
            self.lru_head = id;
        }
        self.lru_tail = id;
    }
};

pub const InteractionState = struct {
    hot_id: Id = 0, // Previous-frame settled hover ID (for drawing; stable)
    active_id: Id = 0, // Press-lock ID
    next_hot_id: Id = 0, // Hover candidate computed this frame (last writer wins in draw order)
    focused_id: Id = 0, // TextInput focus
    focus_claimed_this_frame: bool = false,
    this_frame_hovered_any: bool = false, // for wantsMouse
    active_submitted: bool = false, // Whether an active widget was evaluated this frame (anti-stick)

    pub fn beginFrame(self: *InteractionState) void {
        self.hot_id = self.next_hot_id;
        self.next_hot_id = 0;
        self.this_frame_hovered_any = false;
        self.active_submitted = false;
        self.focus_claimed_this_frame = false;
        // active_id / focused_id are state, so they persist.
    }
};

// ============================================================
// Tests
// ============================================================

const std = @import("std");
const testing = std.testing;

test "InteractionState: beginFrame promotes next_hot_id to hot_id" {
    var s: InteractionState = .{};
    s.next_hot_id = 42;
    s.beginFrame();
    try testing.expectEqual(@as(Id, 42), s.hot_id);
    try testing.expectEqual(@as(Id, 0), s.next_hot_id);
    try testing.expect(!s.this_frame_hovered_any);
}

test "InteractionState: active_id / focused_id persist across beginFrame" {
    var s: InteractionState = .{};
    s.active_id = 7;
    s.focused_id = 9;
    s.this_frame_hovered_any = true;
    s.beginFrame();
    try testing.expectEqual(@as(Id, 7), s.active_id); // Press lock persists
    try testing.expectEqual(@as(Id, 9), s.focused_id);
    try testing.expect(!s.this_frame_hovered_any); // per-frame fields reset
}

test "PerIdStateStore: getOrPut touch moves the entry to the LRU tail" {
    const gpa = testing.allocator;
    var store: PerIdStateStore = .{};
    defer store.deinit(gpa);

    store.beginFrame();
    _ = store.getOrPut(gpa, 1);
    _ = store.getOrPut(gpa, 2);
    _ = store.getOrPut(gpa, 3);
    try testing.expectEqual(@as(Id, 1), store.lru_head);
    try testing.expectEqual(@as(Id, 3), store.lru_tail);

    // touch oldest (1) → move to tail
    _ = store.getOrPut(gpa, 1);
    try testing.expectEqual(@as(Id, 2), store.lru_head);
    try testing.expectEqual(@as(Id, 1), store.lru_tail);
    try testing.expectEqual(@as(Id, 3), store.map.getPtr(2).?.lru_next);
    try testing.expectEqual(@as(Id, 1), store.map.getPtr(3).?.lru_next);
    try testing.expectEqual(@as(u64, 1), store.map.getPtr(1).?.last_touched_frame);
}

test "PerIdStateStore: get does not touch" {
    const gpa = testing.allocator;
    var store: PerIdStateStore = .{};
    defer store.deinit(gpa);

    store.beginFrame();
    _ = store.getOrPut(gpa, 1);
    _ = store.getOrPut(gpa, 2);
    try testing.expectEqual(@as(Id, 2), store.lru_tail);

    _ = store.get(1);
    try testing.expectEqual(@as(Id, 2), store.lru_tail);
    try testing.expectEqual(@as(Id, 1), store.lru_head);
}

test "PerIdStateStore: over capacity deletes oldest LRU entries down to trim_to" {
    const gpa = testing.allocator;
    var store: PerIdStateStore = .{ .max_entries = 4, .trim_to = 3 };
    defer store.deinit(gpa);

    // frame 1: ids 1..5 (all touched this frame)
    store.beginFrame();
    store.getOrPut(gpa, 1).selection.anchor = 10;
    _ = store.getOrPut(gpa, 2);
    _ = store.getOrPut(gpa, 3);
    _ = store.getOrPut(gpa, 4);
    _ = store.getOrPut(gpa, 5);
    try testing.expectEqual(@as(usize, 5), store.count());

    // frame 2: nobody touches → every entry is non-current and deletable
    store.beginFrame();
    store.trim(.{});
    try testing.expectEqual(@as(usize, 3), store.count());
    // Oldest LRU 1, 2 gone; 3-4-5 remain
    try testing.expect(store.get(1) == null);
    try testing.expect(store.get(2) == null);
    try testing.expect(store.get(3) != null);
    try testing.expect(store.get(4) != null);
    try testing.expect(store.get(5) != null);
}

test "PerIdStateStore: over capacity deletes only non-current-frame oldest entries" {
    const gpa = testing.allocator;
    var store: PerIdStateStore = .{ .max_entries = 4, .trim_to = 3 };
    defer store.deinit(gpa);

    store.beginFrame();
    store.getOrPut(gpa, 1).selection.anchor = 10;
    _ = store.getOrPut(gpa, 2);
    _ = store.getOrPut(gpa, 3);

    // frame 2: 1 hidden; touch 2,3 + new 4,5 → count=5 > max
    store.beginFrame();
    _ = store.getOrPut(gpa, 2);
    _ = store.getOrPut(gpa, 3);
    _ = store.getOrPut(gpa, 4);
    _ = store.getOrPut(gpa, 5);
    store.trim(.{});
    // Only 1 is deletable (2..5 are current generation). Temporary overflow allowed even if trim_to is unmet.
    try testing.expectEqual(@as(usize, 4), store.count());
    try testing.expect(store.get(1) == null);
    try testing.expect(store.get(2) != null);
    try testing.expect(store.get(5) != null);
}

test "PerIdStateStore: same-frame touch is not trimmed" {
    const gpa = testing.allocator;
    var store: PerIdStateStore = .{ .max_entries = 2, .trim_to = 1 };
    defer store.deinit(gpa);

    store.beginFrame();
    _ = store.getOrPut(gpa, 1);
    _ = store.getOrPut(gpa, 2);
    _ = store.getOrPut(gpa, 3);
    try testing.expectEqual(@as(usize, 3), store.count());

    // No deletion: every entry is current generation (temporary overflow allowed)
    store.trim(.{});
    try testing.expectEqual(@as(usize, 3), store.count());
}

test "PerIdStateStore: active/focused/hot are excluded from trim even on hidden frames" {
    const gpa = testing.allocator;
    var store: PerIdStateStore = .{ .max_entries = 2, .trim_to = 1 };
    defer store.deinit(gpa);

    store.beginFrame();
    store.getOrPut(gpa, 10).caret = 7; // will be focused, not touched next frame
    store.getOrPut(gpa, 20).scroll_x = 3; // will be active
    store.getOrPut(gpa, 30).selection.extent = 2; // will be hot
    _ = store.getOrPut(gpa, 40); // unprotected old

    store.beginFrame();
    // Exceed the limit with new entries (3 protected + many new)
    var i: Id = 100;
    while (i < 110) : (i += 1) {
        _ = store.getOrPut(gpa, i);
    }
    try testing.expect(store.count() > store.max_entries);

    store.trim(.{
        .focused_id = 10,
        .active_id = 20,
        .hot_id = 30,
        .next_hot_id = 0,
    });

    // The 3 protected remain
    try testing.expectEqual(@as(usize, 7), store.get(10).?.caret);
    try testing.expectEqual(@as(i32, 3), store.get(20).?.scroll_x);
    try testing.expectEqual(@as(usize, 2), store.get(30).?.selection.extent);
    // Unprotected old 40 is gone
    try testing.expect(store.get(40) == null);
    // This frame's 100..109 remain (current touch)
    try testing.expect(store.get(100) != null);
}

test "PerIdStateStore: brief hide under capacity keeps state on re-show" {
    const gpa = testing.allocator;
    var store: PerIdStateStore = .{};
    defer store.deinit(gpa);

    store.beginFrame();
    store.getOrPut(gpa, 5).selection = .{ .anchor = 3, .extent = 8, .dragging = true };
    store.getOrPut(gpa, 5).caret = 8;

    // Hidden frame (no touch)
    store.beginFrame();
    store.trim(.{});
    try testing.expectEqual(@as(usize, 3), store.get(5).?.selection.anchor);

    // Shown again
    store.beginFrame();
    const s = store.getOrPut(gpa, 5);
    try testing.expectEqual(@as(usize, 3), s.selection.anchor);
    try testing.expectEqual(@as(usize, 8), s.selection.extent);
    try testing.expect(s.selection.dragging);
    try testing.expectEqual(@as(usize, 8), s.caret);
}

test "PerIdStateStore: re-fetch after deletion yields defaults" {
    const gpa = testing.allocator;
    var store: PerIdStateStore = .{ .max_entries = 1, .trim_to = 1 };
    defer store.deinit(gpa);

    store.beginFrame();
    store.getOrPut(gpa, 1).caret = 99;
    store.getOrPut(gpa, 1).selection.anchor = 4;

    store.beginFrame();
    _ = store.getOrPut(gpa, 2); // Touch only 2 → 1 becomes oldest
    store.trim(.{});
    try testing.expect(store.get(1) == null);

    store.beginFrame();
    const s = store.getOrPut(gpa, 1);
    try testing.expectEqual(@as(usize, 0), s.caret);
    try testing.expectEqual(@as(usize, 0), s.selection.anchor);
    try testing.expectEqual(@as(usize, 0), s.selection.extent);
    try testing.expectEqual(@as(i32, 0), s.scroll_x);
}

test "PerIdStateStore: TextBuffer is unaffected by store trim" {
    const gpa = testing.allocator;
    var buf = try text_edit.TextBuffer.init(gpa, "hello");
    defer buf.deinit();

    var store: PerIdStateStore = .{ .max_entries = 1, .trim_to = 1 };
    defer store.deinit(gpa);

    store.beginFrame();
    store.getOrPut(gpa, 1).caret = 5;
    store.beginFrame();
    _ = store.getOrPut(gpa, 2);
    store.trim(.{});
    try testing.expect(store.get(1) == null);

    // Caller-owned TextBuffer is unchanged
    try testing.expectEqualStrings("hello", buf.slice());
}

test "PerIdStateStore: ScrollArea caller-owned Vec2f stays outside the store" {
    const gpa = testing.allocator;
    const scroll: struct { x: f32 = 0, y: f32 = 0 } = .{ .x = 12, .y = 34 };

    var store: PerIdStateStore = .{ .max_entries = 1, .trim_to = 1 };
    defer store.deinit(gpa);

    store.beginFrame();
    _ = store.getOrPut(gpa, 1);
    store.beginFrame();
    _ = store.getOrPut(gpa, 2);
    store.trim(.{});

    // Store does not hold scroll; caller-side value stays as-is.
    try testing.expectEqual(@as(f32, 12), scroll.x);
    try testing.expectEqual(@as(f32, 34), scroll.y);
    try testing.expect(store.get(1) == null);
}

test "PerIdStateStore: no trim while at or below max" {
    const gpa = testing.allocator;
    var store: PerIdStateStore = .{ .max_entries = 10, .trim_to = 5 };
    defer store.deinit(gpa);

    store.beginFrame();
    var i: Id = 1;
    while (i <= 10) : (i += 1) _ = store.getOrPut(gpa, i);
    store.beginFrame();
    // Hidden with count==max → fire condition is count > max, so do nothing
    store.trim(.{});
    try testing.expectEqual(@as(usize, 10), store.count());
}
