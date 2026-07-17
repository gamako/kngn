// interaction state（hot / active / focused）と widget ごとの永続状態。
//
// hot_id は 1 フレーム遅延の安定 hover ID（描画フィードバック用）。当フレーム計算中の
// hover は next_hot_id に積み、beginFrame で hot_id に昇格させる。これによりネスト
// widget 等で同フレーム内に hover 主体が入れ替わってもフリッカしない。
// 描画時は state.hot_id == id を見る（buttonBehavior の result.hovered は当フレーム生値）。

const id_mod = @import("id.zig");
const text_edit = @import("text_edit.zig");

pub const Id = id_mod.Id;

/// SelectableLabel など、ID に紐づく widget のフレーム間状態。
pub const PerIdState = struct {
    selection: text_edit.SelectionState = .{},
    last_click_time: f64 = -1.0,
    last_click_pos: struct { x: i32 = 0, y: i32 = 0 } = .{},
    /// TextInput の caret は selection.extent と同期する codepoint index。
    caret: usize = 0,
    /// content の左端からの横スクロール量（px）。
    scroll_x: i32 = 0,
    /// caret が表示を開始した Context 仮想時刻。
    caret_blink_start_s: f64 = 0,
};

/// ID ごとの状態を必要な ID だけ遅延確保する state store。
///
/// # 容量・LRU trim 契約（TASK-127）
///
/// - 方式: frame generation による touch + ID リンクの LRU リスト。
/// - 既定: `max_entries=4096`、`trim_to=3072`（25% 余裕で frame 毎 churn を抑える）。
/// - touch: `getOrPut` が current generation を記録し entry を LRU 末尾へ移動する O(1)。
///   `get` は読み取り専用で touch しない。表示中 widget は `Context.perIdState` → `getOrPut`
///   経由で毎フレーム touch される。
/// - trim 発火: `entry_count > max_entries` のとき、`Context.endFrame` 末尾のフレーム境界のみ。
///   widget 構築ループ内では trim しない。
/// - 表示中 state: `last_touched_frame == current_generation` の entry は削除されない。
/// - 操作中 state: `active_id` / `focused_id` / `hot_id` / `next_hot_id` に対応する entry は
///   last_touched に関わらず trim 対象外（一時非表示の focus/drag/hover を維持）。
/// - 非表示 state: 上限超過時に LRU の古い entry から破棄され得る。削除後に同じ ID が
///   再表示された場合、`PerIdState` は初期値から再生成される（selection / caret /
///   TextInput 内 `scroll_x` / double-click 情報がリセット）。上限未満の間は保持する。
/// - 保護 entry だけで `trim_to` を満たせない場合は、表示中・操作中 state を優先し
///   一時的に `max_entries` 超過を許容する。
/// - 呼び出し側所有データは store 外: `TextBuffer`（`std.ArrayList(u8)`）と ScrollArea の
///   caller 所有 `*Vec2f` は本 store に入らない。entry 破棄でもそれらの内容・容量は不変。
pub const PerIdStateStore = struct {
    pub const default_max_entries: usize = 4096;
    pub const default_trim_to: usize = 3072;

    /// map value: 公開 state + LRU metadata。リンクは ID（rehash でポインタ無効化を避ける）。
    /// `lru_prev` / `lru_next` の 0 はリンク無し（Id=0 は widget ID として未使用）。
    pub const Entry = struct {
        state: PerIdState = .{},
        last_touched_frame: u64 = 0,
        lru_prev: Id = 0,
        lru_next: Id = 0,
    };

    /// trim 時に保護する interaction ID 群（0 = 無し）。
    pub const ProtectedIds = struct {
        active_id: Id = 0,
        focused_id: Id = 0,
        hot_id: Id = 0,
        next_hot_id: Id = 0,
    };

    map: std.AutoHashMapUnmanaged(Id, Entry) = .empty,
    /// store 専用 frame generation（Context.frame_index とは独立。beginFrameAt でも同じ契約）。
    generation: u64 = 0,
    /// LRU 先頭 = 最古（least recently used）。0 = 空。
    lru_head: Id = 0,
    /// LRU 末尾 = 最新（most recently used）。0 = 空。
    lru_tail: Id = 0,
    max_entries: usize = default_max_entries,
    trim_to: usize = default_trim_to,

    pub fn deinit(self: *PerIdStateStore, gpa: std.mem.Allocator) void {
        self.map.deinit(gpa);
        self.* = .{};
    }

    /// フレーム開始時に generation を進める。Context.beginFrameAtInternal から呼ばれる。
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
            // 新規 entry を LRU 末尾へ。getOrPut 後の rehash に備え ID 経由でリンクする。
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

    /// フレーム境界でのみ呼ぶ。`count > max_entries` なら LRU 古い entry から `trim_to` まで削除。
    /// 当フレーム touch / protected ID は除外。保護のみで `trim_to` に届かない場合は超過を許容。
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
    hot_id: Id = 0, // 前フレーム確定の hover ID（描画用・安定）
    active_id: Id = 0, // 押下中ロック ID
    next_hot_id: Id = 0, // 今フレーム計算中の hover 候補（描画順で最後勝ち）
    focused_id: Id = 0, // TextInput focus
    focus_claimed_this_frame: bool = false,
    this_frame_hovered_any: bool = false, // wantsMouse 算出用
    active_submitted: bool = false, // 当フレームに active widget が評価されたか（張り付き防止用）

    pub fn beginFrame(self: *InteractionState) void {
        self.hot_id = self.next_hot_id;
        self.next_hot_id = 0;
        self.this_frame_hovered_any = false;
        self.active_submitted = false;
        self.focus_claimed_this_frame = false;
        // active_id / focused_id は状態なので維持する。
    }
};

// ============================================================
// Tests
// ============================================================

const std = @import("std");
const testing = std.testing;

test "InteractionState: beginFrame で next_hot_id が hot_id に昇格" {
    var s: InteractionState = .{};
    s.next_hot_id = 42;
    s.beginFrame();
    try testing.expectEqual(@as(Id, 42), s.hot_id);
    try testing.expectEqual(@as(Id, 0), s.next_hot_id);
    try testing.expect(!s.this_frame_hovered_any);
}

test "InteractionState: active_id / focused_id は beginFrame で維持される" {
    var s: InteractionState = .{};
    s.active_id = 7;
    s.focused_id = 9;
    s.this_frame_hovered_any = true;
    s.beginFrame();
    try testing.expectEqual(@as(Id, 7), s.active_id); // 押下ロックは継続
    try testing.expectEqual(@as(Id, 9), s.focused_id);
    try testing.expect(!s.this_frame_hovered_any); // per-frame はリセット
}

test "PerIdStateStore: getOrPut touch が LRU 末尾へ移動する" {
    const gpa = testing.allocator;
    var store: PerIdStateStore = .{};
    defer store.deinit(gpa);

    store.beginFrame();
    _ = store.getOrPut(gpa, 1);
    _ = store.getOrPut(gpa, 2);
    _ = store.getOrPut(gpa, 3);
    try testing.expectEqual(@as(Id, 1), store.lru_head);
    try testing.expectEqual(@as(Id, 3), store.lru_tail);

    // 最古 (1) を touch → 末尾へ
    _ = store.getOrPut(gpa, 1);
    try testing.expectEqual(@as(Id, 2), store.lru_head);
    try testing.expectEqual(@as(Id, 1), store.lru_tail);
    try testing.expectEqual(@as(Id, 3), store.map.getPtr(2).?.lru_next);
    try testing.expectEqual(@as(Id, 1), store.map.getPtr(3).?.lru_next);
    try testing.expectEqual(@as(u64, 1), store.map.getPtr(1).?.last_touched_frame);
}

test "PerIdStateStore: get は touch しない" {
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

test "PerIdStateStore: 上限超過で LRU 最古から削除し trim_to へ" {
    const gpa = testing.allocator;
    var store: PerIdStateStore = .{ .max_entries = 4, .trim_to = 3 };
    defer store.deinit(gpa);

    // frame 1: ids 1..5（いずれもこの frame で touch）
    store.beginFrame();
    store.getOrPut(gpa, 1).selection.anchor = 10;
    _ = store.getOrPut(gpa, 2);
    _ = store.getOrPut(gpa, 3);
    _ = store.getOrPut(gpa, 4);
    _ = store.getOrPut(gpa, 5);
    try testing.expectEqual(@as(usize, 5), store.count());

    // frame 2: 誰も touch しない → 全 entry が非 current で削除可能
    store.beginFrame();
    store.trim(.{});
    try testing.expectEqual(@as(usize, 3), store.count());
    // LRU 最古 1, 2 が消え、3-4-5 が残る
    try testing.expect(store.get(1) == null);
    try testing.expect(store.get(2) == null);
    try testing.expect(store.get(3) != null);
    try testing.expect(store.get(4) != null);
    try testing.expect(store.get(5) != null);
}

test "PerIdStateStore: 上限超過時に当フレーム以外の最古だけ削除" {
    const gpa = testing.allocator;
    var store: PerIdStateStore = .{ .max_entries = 4, .trim_to = 3 };
    defer store.deinit(gpa);

    store.beginFrame();
    store.getOrPut(gpa, 1).selection.anchor = 10;
    _ = store.getOrPut(gpa, 2);
    _ = store.getOrPut(gpa, 3);

    // frame 2: 1 は非表示、2,3 touch + 新規 4,5 → count=5 > max
    store.beginFrame();
    _ = store.getOrPut(gpa, 2);
    _ = store.getOrPut(gpa, 3);
    _ = store.getOrPut(gpa, 4);
    _ = store.getOrPut(gpa, 5);
    store.trim(.{});
    // 削除可能は 1 のみ（2..5 は current generation）。trim_to 未達でも一時超過許容。
    try testing.expectEqual(@as(usize, 4), store.count());
    try testing.expect(store.get(1) == null);
    try testing.expect(store.get(2) != null);
    try testing.expect(store.get(5) != null);
}

test "PerIdStateStore: 当フレーム touch は trim されない" {
    const gpa = testing.allocator;
    var store: PerIdStateStore = .{ .max_entries = 2, .trim_to = 1 };
    defer store.deinit(gpa);

    store.beginFrame();
    _ = store.getOrPut(gpa, 1);
    _ = store.getOrPut(gpa, 2);
    _ = store.getOrPut(gpa, 3);
    try testing.expectEqual(@as(usize, 3), store.count());

    // 全 entry が current generation のため 1 件も消えない（一時超過許容）
    store.trim(.{});
    try testing.expectEqual(@as(usize, 3), store.count());
}

test "PerIdStateStore: active/focused/hot は非表示 frame でも trim 除外" {
    const gpa = testing.allocator;
    var store: PerIdStateStore = .{ .max_entries = 2, .trim_to = 1 };
    defer store.deinit(gpa);

    store.beginFrame();
    store.getOrPut(gpa, 10).caret = 7; // will be focused, not touched next frame
    store.getOrPut(gpa, 20).scroll_x = 3; // will be active
    store.getOrPut(gpa, 30).selection.extent = 2; // will be hot
    _ = store.getOrPut(gpa, 40); // unprotected old

    store.beginFrame();
    // 新規で上限超過を起こす（保護 3 + 新規多数）
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

    // 保護 3 つは残る
    try testing.expectEqual(@as(usize, 7), store.get(10).?.caret);
    try testing.expectEqual(@as(i32, 3), store.get(20).?.scroll_x);
    try testing.expectEqual(@as(usize, 2), store.get(30).?.selection.extent);
    // 非保護の古い 40 は消える
    try testing.expect(store.get(40) == null);
    // 当フレームの 100..109 は残る（current touch）
    try testing.expect(store.get(100) != null);
}

test "PerIdStateStore: 上限未満の一時非表示は再表示で state 保持" {
    const gpa = testing.allocator;
    var store: PerIdStateStore = .{};
    defer store.deinit(gpa);

    store.beginFrame();
    store.getOrPut(gpa, 5).selection = .{ .anchor = 3, .extent = 8, .dragging = true };
    store.getOrPut(gpa, 5).caret = 8;

    // 非表示フレーム（touch しない）
    store.beginFrame();
    store.trim(.{});
    try testing.expectEqual(@as(usize, 3), store.get(5).?.selection.anchor);

    // 再表示
    store.beginFrame();
    const s = store.getOrPut(gpa, 5);
    try testing.expectEqual(@as(usize, 3), s.selection.anchor);
    try testing.expectEqual(@as(usize, 8), s.selection.extent);
    try testing.expect(s.selection.dragging);
    try testing.expectEqual(@as(usize, 8), s.caret);
}

test "PerIdStateStore: 削除後の再取得は初期値" {
    const gpa = testing.allocator;
    var store: PerIdStateStore = .{ .max_entries = 1, .trim_to = 1 };
    defer store.deinit(gpa);

    store.beginFrame();
    store.getOrPut(gpa, 1).caret = 99;
    store.getOrPut(gpa, 1).selection.anchor = 4;

    store.beginFrame();
    _ = store.getOrPut(gpa, 2); // 2 のみ touch → 1 が最古
    store.trim(.{});
    try testing.expect(store.get(1) == null);

    store.beginFrame();
    const s = store.getOrPut(gpa, 1);
    try testing.expectEqual(@as(usize, 0), s.caret);
    try testing.expectEqual(@as(usize, 0), s.selection.anchor);
    try testing.expectEqual(@as(usize, 0), s.selection.extent);
    try testing.expectEqual(@as(i32, 0), s.scroll_x);
}

test "PerIdStateStore: TextBuffer は store trim の影響を受けない" {
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

    // caller 所有 TextBuffer は不変
    try testing.expectEqualStrings("hello", buf.slice());
}

test "PerIdStateStore: ScrollArea の caller 所有 Vec2f は store 外" {
    const gpa = testing.allocator;
    const scroll: struct { x: f32 = 0, y: f32 = 0 } = .{ .x = 12, .y = 34 };

    var store: PerIdStateStore = .{ .max_entries = 1, .trim_to = 1 };
    defer store.deinit(gpa);

    store.beginFrame();
    _ = store.getOrPut(gpa, 1);
    store.beginFrame();
    _ = store.getOrPut(gpa, 2);
    store.trim(.{});

    // store は scroll を保持しない。caller 側値はそのまま。
    try testing.expectEqual(@as(f32, 12), scroll.x);
    try testing.expectEqual(@as(f32, 34), scroll.y);
    try testing.expect(store.get(1) == null);
}

test "PerIdStateStore: max 以下では trim しない" {
    const gpa = testing.allocator;
    var store: PerIdStateStore = .{ .max_entries = 10, .trim_to = 5 };
    defer store.deinit(gpa);

    store.beginFrame();
    var i: Id = 1;
    while (i <= 10) : (i += 1) _ = store.getOrPut(gpa, i);
    store.beginFrame();
    // 非表示のまま count==max → 発火条件は count > max なので何もしない
    store.trim(.{});
    try testing.expectEqual(@as(usize, 10), store.count());
}
