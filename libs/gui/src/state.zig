// interaction state（hot / active / focused）。
//
// hot_id は 1 フレーム遅延の安定 hover ID（描画フィードバック用）。当フレーム計算中の
// hover は next_hot_id に積み、beginFrame で hot_id に昇格させる。これによりネスト
// widget 等で同フレーム内に hover 主体が入れ替わってもフリッカしない。
// 描画時は state.hot_id == id を見る（buttonBehavior の result.hovered は当フレーム生値）。

const id_mod = @import("id.zig");

pub const Id = id_mod.Id;

pub const InteractionState = struct {
    hot_id: Id = 0, // 前フレーム確定の hover ID（描画用・安定）
    active_id: Id = 0, // 押下中ロック ID
    next_hot_id: Id = 0, // 今フレーム計算中の hover 候補（描画順で最後勝ち）
    focused_id: Id = 0, // text field focus（本タスクでは設定しない）
    this_frame_hovered_any: bool = false, // wantsMouse 算出用
    active_submitted: bool = false, // 当フレームに active widget が評価されたか（張り付き防止用）

    pub fn beginFrame(self: *InteractionState) void {
        self.hot_id = self.next_hot_id;
        self.next_hot_id = 0;
        self.this_frame_hovered_any = false;
        self.active_submitted = false;
        // active_id / focused_id は状態なので維持する。
    }
};

// ============================================================
// Tests
// ============================================================

const std = @import("std");

test "InteractionState: beginFrame で next_hot_id が hot_id に昇格" {
    var s: InteractionState = .{};
    s.next_hot_id = 42;
    s.beginFrame();
    try std.testing.expectEqual(@as(Id, 42), s.hot_id);
    try std.testing.expectEqual(@as(Id, 0), s.next_hot_id);
    try std.testing.expect(!s.this_frame_hovered_any);
}

test "InteractionState: active_id / focused_id は beginFrame で維持される" {
    var s: InteractionState = .{};
    s.active_id = 7;
    s.focused_id = 9;
    s.this_frame_hovered_any = true;
    s.beginFrame();
    try std.testing.expectEqual(@as(Id, 7), s.active_id); // 押下ロックは継続
    try std.testing.expectEqual(@as(Id, 9), s.focused_id);
    try std.testing.expect(!s.this_frame_hovered_any); // per-frame はリセット
}
