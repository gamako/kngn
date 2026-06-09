// Context: 入力 + ID stack + interaction state + draw list + arena + font を束ねる。
// フレームライフサイクル（beginFrame / endFrame）と widget behavior の起点。
//
// ライフサイクル契約（21.2 スコープ = 案A「契約の番人」）:
//   beginFrame(w,h): arena.reset → input/id_stack/state.beginFrame → draw_list.reset(w,h)
//   endFrame():      frame_active を下ろすだけ。arena も draw_list も触らない。
//                    → endFrame 後も draw_list / id_stack / state は次 beginFrame まで valid。
//   layout / draw emit / rect キャッシュは 21.4 / 21.5 でここに差し込む（拡張シーム）。

const std = @import("std");
const Allocator = std.mem.Allocator;

const geom = @import("geom.zig");
const draw = @import("draw.zig");
const font_mod = @import("font.zig");
const id_mod = @import("id.zig");
const input_mod = @import("input.zig");
const state_mod = @import("state.zig");

pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const Id = id_mod.Id;
pub const IdStack = id_mod.IdStack;
pub const Input = input_mod.Input;
pub const InputEvent = input_mod.InputEvent;
pub const InteractionState = state_mod.InteractionState;
pub const DrawList = draw.DrawList;
pub const BitmapFont = font_mod.BitmapFont;

pub const Context = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    input: Input,
    id_stack: IdStack,
    state: InteractionState = .{},
    draw_list: DrawList,
    font: BitmapFont,
    screen_w: u32 = 0,
    screen_h: u32 = 0,
    frame_active: bool = false,
    // style, layout は 21.4 / 21.5 で追加

    pub fn init(gpa: Allocator, font: BitmapFont) Context {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .input = Input.init(gpa),
            .id_stack = IdStack.init(gpa),
            .draw_list = DrawList.init(gpa),
            .font = font,
        };
    }

    pub fn deinit(self: *Context) void {
        self.draw_list.deinit();
        self.id_stack.deinit();
        self.input.deinit();
        self.arena.deinit();
    }

    /// arena allocator（cmd の text/image payload 用）。次フレーム beginFrame で reset される。
    pub fn allocator(self: *Context) Allocator {
        return self.arena.allocator();
    }

    pub fn beginFrame(self: *Context, screen_w: u32, screen_h: u32) void {
        std.debug.assert(!self.frame_active);
        self.frame_active = true;
        self.screen_w = screen_w;
        self.screen_h = screen_h;
        _ = self.arena.reset(.retain_capacity); // 前フレームの payload をここで解放
        self.input.beginFrame();
        self.id_stack.clear();
        self.state.beginFrame();
        self.draw_list.reset(screen_w, screen_h);
    }

    pub fn endFrame(self: *Context) void {
        std.debug.assert(self.frame_active);
        self.frame_active = false;
        // active widget が当フレーム未評価（非表示・分岐で未描画）かつ既にボタンが
        // 離されているなら、active_id の張り付き（wantsMouse の引きずり）を防ぐため解除する。
        if (self.state.active_id != 0 and !self.state.active_submitted and !self.input.mouse_buttons.left) {
            self.state.active_id = 0;
        }
        // 21.2 では arena も draw_list も触らない（契約の番人）。
    }

    pub fn pushEvent(self: *Context, ev: InputEvent) void {
        std.debug.assert(self.frame_active);
        self.input.pushEvent(ev);
    }

    pub fn wantsMouse(self: *const Context) bool {
        return self.state.active_id != 0 or self.state.this_frame_hovered_any;
    }

    pub fn wantsKeyboard(self: *const Context) bool {
        return self.state.focused_id != 0;
    }
};

pub const ButtonResult = struct {
    clicked: bool = false,
    hovered: bool = false,
    held: bool = false,
};

/// Dear ImGui 流の同期 hit-test + button state machine（Description 修正版 v2）。
/// rect / clip は呼び出し側が渡す（21.2 は layout を持たないため）。
pub fn buttonBehavior(ctx: *Context, id: Id, rect: Rect, clip: Rect) ButtonResult {
    std.debug.assert(ctx.frame_active);
    const mp = ctx.input.mouse_pos;
    const hovered_now = rect.contains(mp) and clip.contains(mp);
    var result: ButtonResult = .{};
    result.hovered = hovered_now;

    // 1. hover 反映（active が他 widget に乗ってる時は奪わない）
    if (hovered_now) {
        if (ctx.state.active_id == 0 or ctx.state.active_id == id) {
            ctx.state.next_hot_id = id; // 描画順で最後勝ち
        }
        ctx.state.this_frame_hovered_any = true;
    }

    // 2. acquire active。press 起点（down した瞬間の座標 = mouse_pressed_pos）が rect 内の
    //    ときのみ。フレーム最終位置 mouse_pos ではなく起点を使うことで、同フレーム内の
    //    「外で down → 内へ move」での誤取得を防ぐ（mouse_pressed_pos を持たせた理由）。
    if (ctx.state.active_id == 0 and ctx.input.mouse_pressed.left) {
        const pp = ctx.input.mouse_pressed_pos;
        if (rect.contains(pp) and clip.contains(pp)) {
            ctx.state.active_id = id;
        }
    }

    // 3. hold / release（release edge で active 解除 + up 時に hover 内なら click 確定）
    if (ctx.state.active_id == id) {
        result.held = true;
        ctx.state.active_submitted = true; // 張り付き防止: 当フレームに評価された印
        if (ctx.input.mouse_released.left) {
            if (hovered_now) result.clicked = true;
            ctx.state.active_id = 0;
        }
    }
    return result;
}

// ============================================================
// Tests
// ============================================================

const color_mod = @import("color.zig");

const full_clip = Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
const btn_rect = Rect{ .x = 0, .y = 0, .w = 100, .h = 50 };

fn testCtx() Context {
    return Context.init(std.testing.allocator, font_mod.default_font);
}

test "buttonBehavior: hover 中の down→up（別フレーム）で clicked が 1 フレームのみ true" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 1;

    // フレーム1: hover + down → held, not clicked
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    var r = buttonBehavior(&ctx, id, btn_rect, full_clip);
    try std.testing.expect(!r.clicked);
    try std.testing.expect(r.held);
    ctx.endFrame();

    // フレーム2: hover 内で up → clicked
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    r = buttonBehavior(&ctx, id, btn_rect, full_clip);
    try std.testing.expect(r.clicked);
    ctx.endFrame();

    // フレーム3: clicked は false に戻る
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    r = buttonBehavior(&ctx, id, btn_rect, full_clip);
    try std.testing.expect(!r.clicked);
    ctx.endFrame();
}

test "buttonBehavior: 同一フレームで down→up 完結でも clicked を返す" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    const r = buttonBehavior(&ctx, 1, btn_rect, full_clip);
    try std.testing.expect(r.clicked);
    ctx.endFrame();
}

test "buttonBehavior: clip 外なら hover/click しない" {
    var ctx = testCtx();
    defer ctx.deinit();
    const narrow_clip = Rect{ .x = 0, .y = 0, .w = 5, .h = 5 };

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } }); // rect 内だが clip 外
    const r = buttonBehavior(&ctx, 1, btn_rect, narrow_clip);
    try std.testing.expect(!r.hovered);
    try std.testing.expect(!ctx.wantsMouse());
    ctx.endFrame();
}

test "Context.wantsMouse: hover 開始フレームから true" {
    var ctx = testCtx();
    defer ctx.deinit();

    // hover 外
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 200, .y = 200, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, 1, btn_rect, full_clip);
    try std.testing.expect(!ctx.wantsMouse());
    ctx.endFrame();

    // hover 内（開始フレーム）
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, 1, btn_rect, full_clip);
    try std.testing.expect(ctx.wantsMouse());
    ctx.endFrame();
}

test "Context.wantsMouse: active 解除後も hover 継続中は true" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 1;

    // フレーム1: hover + down → active 取得
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, id, btn_rect, full_clip);
    try std.testing.expect(ctx.wantsMouse());
    try std.testing.expectEqual(id, ctx.state.active_id);
    ctx.endFrame();

    // フレーム2: hover 内で up → active 解除されるが hover 継続 → wantsMouse true
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, id, btn_rect, full_clip);
    try std.testing.expectEqual(@as(Id, 0), ctx.state.active_id);
    try std.testing.expect(ctx.wantsMouse());
    ctx.endFrame();
}

test "buttonBehavior: active 中は別 widget が hot を奪わない" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id_a: Id = 1;
    const id_b: Id = 2;
    const rect_a = Rect{ .x = 0, .y = 0, .w = 100, .h = 50 };
    const rect_b = Rect{ .x = 0, .y = 60, .w = 100, .h = 50 };

    // フレーム1: A を hover+down → active_id = A
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, id_a, rect_a, full_clip);
    try std.testing.expectEqual(id_a, ctx.state.active_id);
    ctx.endFrame();

    // フレーム2: B 上に移動（A は押下継続）。B 上でも next_hot は B に乗らない
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 70, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, id_a, rect_a, full_clip);
    _ = buttonBehavior(&ctx, id_b, rect_b, full_clip);
    try std.testing.expectEqual(@as(Id, 0), ctx.state.next_hot_id);
    ctx.endFrame();
}

test "Context: beginFrame でリセット、endFrame では draw_list/id_stack/state を保持" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    try ctx.draw_list.rectFilled(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, color_mod.Color.rgba(0xFF, 0, 0, 0xFF));
    ctx.id_stack.push("scope");
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, 1, btn_rect, full_clip);
    ctx.endFrame();

    // endFrame 後も valid（次 beginFrame まで参照できる）
    try std.testing.expect(ctx.draw_list.cmds.items.len > 0);
    try std.testing.expect(ctx.id_stack.stack.items.len > 0);
    try std.testing.expect(ctx.state.this_frame_hovered_any);

    // 次 beginFrame でリセットされる
    ctx.beginFrame(800, 600);
    try std.testing.expectEqual(@as(usize, 0), ctx.draw_list.cmds.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.id_stack.stack.items.len);
    try std.testing.expect(!ctx.state.this_frame_hovered_any);
    ctx.endFrame();
}

test "buttonBehavior: 外で down → 内へ move → up（同フレーム）では click しない" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 200, .y = 200, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 200, .y = 200, .button = 0, .modifiers = 0 } }); // 起点は外
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } }); // 内へ移動
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    const r = buttonBehavior(&ctx, 1, btn_rect, full_clip);
    try std.testing.expect(!r.clicked);
    try std.testing.expectEqual(@as(Id, 0), ctx.state.active_id);
    ctx.endFrame();
}

test "buttonBehavior: 内で down → 外へ move（同フレーム）でも active は press 起点で取得される" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } }); // 起点は内
    ctx.pushEvent(.{ .mouse_move = .{ .x = 200, .y = 200, .modifiers = 0 } }); // 外へドラッグ
    const r = buttonBehavior(&ctx, 1, btn_rect, full_clip);
    try std.testing.expect(r.held);
    try std.testing.expectEqual(@as(Id, 1), ctx.state.active_id);
    ctx.endFrame();
}

test "Context: active widget が未評価のまま release されたら endFrame で active_id を解除" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 1;

    // フレーム1: hover+down → active 取得
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, id, btn_rect, full_clip);
    try std.testing.expectEqual(id, ctx.state.active_id);
    ctx.endFrame();

    // フレーム2: widget を呼ばず（非表示）、ボタンを離す
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    // buttonBehavior(id) を呼ばない（widget が消えた状況）
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 0), ctx.state.active_id); // 張り付き解除
}
