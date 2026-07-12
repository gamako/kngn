// ポップアップ/コンテキストメニュー primitive（TASK-79.1）。
//
// ホットパス宣言: イベント時のみ。開閉・ヒットテスト・描画は「popup が表示されている
// フレームの popupMenu() 呼び出し1回」に限定され、フレーム毎の全画素ループでも
// RT（毎サンプル）でもない。描画量もメニュー矩形+数項目程度で軽微（性能規約の
// SIMD 3点セット等は適用対象外。下地の gui.render 側は既に規約適用済み）。
//
// 設計（apps/editor/apps/pixie/selection_overlay.zig と同じ「endFrame 後に draw_list へ
// 手動描画する」オーバーレイ方式）:
//   既存の layout 木（beginBox/endBox）には乗せない。layout 木の rect_cache は
//   明示 ID ノードの「前フレーム」の rect を返す同期 hit-test 契約（context.zig 冒頭の
//   契約コメント参照）であり、当フレームに開いたポップアップの位置をその場で
//   hit-test できない。よって popupMenu() は **ctx.endFrame() の後に呼ぶ契約**とし、
//   当フレームの ctx.input を直接読んで Rect.contains で hit-test し、
//   ctx.draw_list へ直接コマンドを積む（layout 発行済みの通常 UI の後に積まれるので
//   最前面に描かれる。selection_overlay.zig と同型）。
//
// モーダル吸収: openPopup() が active_id/hot_id/next_hot_id を 0 にリセットし、
// context.zig の buttonBehavior() が `popup_state != null` の間は無条件で
// ButtonResult{} を返すガードを持つ（このファイルではなく context.zig 側の実装。
// 詳細はそちらの doc comment 参照）。これにより popup 表示中は新規 acquire は
// 構造的に起こらず、背後 widget は hover/hot/active を一切得られない。
// wantsMouse() も popup_state != null を OR するため、canvas 等アプリ側の入力ゲートも
// 「popup 表示中は入力を渡さない」を wantsMouse() 一本で表現できる。

const std = @import("std");
const context_mod = @import("context.zig");
const geom = @import("geom.zig");
const id_mod = @import("id.zig");

pub const Context = context_mod.Context;
pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const Id = id_mod.Id;

/// Context が保持するポップアップ開閉状態。MVP は同時に1つのみ開ける。
pub const PopupState = struct {
    id: Id,
    /// 開いた時の要求位置（左上、クランプ前）。
    pos: Vec2,
};

/// メニュー項目。label はラベル文字列（popupMenu が arena に複製するので呼び出し後の
/// caller バッファ書き換えに影響されない）。
pub const PopupItem = struct {
    label: []const u8,
    enabled: bool = true,
};

/// popupMenu() の戻り値。
pub const PopupResult = struct {
    /// この呼び出し終了時点でまだ開いているか（false なら selected/dismissed 側を見る）。
    open: bool = false,
    /// クリックで選択された項目 index（選択されたら popup は自動で閉じる）。
    selected: ?usize = null,
    /// ESC 相当（caller が closePopup を呼んだ）・外側クリック・空 items で
    /// 選択せずに閉じられたか。
    dismissed: bool = false,
};

/// 幾何計算の結果。outer は常に screen 矩形内に収まる（不変条件。screen より要求サイズが
/// 大きい場合は縮小して収める＝スクロールは MVP スコープ外）。
pub const PopupGeometry = struct {
    outer: Rect,
    pad: i32,
    item_h: i32,
};

/// 要求位置 pos に対しメニュー外枠を計算し、screen 矩形内に収まるようクランプする。
/// Context 非依存の純粋関数（単体テスト容易）。
///
/// 事前条件（デバッグ assert）: item_count > 0, item_h > 0, pad >= 0, screen_w > 0, screen_h > 0。
/// content_w は 0 以上を期待するが、万一負値が渡っても @max(content_w, 0) で救う。
///
/// クランプ手順: まず w/h を screen_w/screen_h に収まるよう縮小し（「outer は常に screen
/// 内」を不変条件にする）、続けて x/y を右/下端→左/上端の順でクランプする。
pub fn layoutPopup(
    pos: Vec2,
    item_count: usize,
    content_w: i32,
    item_h: i32,
    pad: i32,
    screen_w: u32,
    screen_h: u32,
) PopupGeometry {
    std.debug.assert(item_count > 0);
    std.debug.assert(item_h > 0);
    std.debug.assert(pad >= 0);
    std.debug.assert(screen_w > 0);
    std.debug.assert(screen_h > 0);

    // オーバーフロー対策で i64 中間計算（style は caller が直接書き換えられるため、
    // 極端な値が来ても trap しないようにする）。
    const cw: i64 = @max(@as(i64, content_w), 0);
    const pad64: i64 = pad;
    const item_h64: i64 = item_h;
    const count64: i64 = std.math.cast(i64, item_count) orelse std.math.maxInt(i64);
    const sw: i64 = screen_w;
    const sh: i64 = screen_h;

    var w: i64 = cw + pad64 * 2;
    var h: i64 = count64 * item_h64 + pad64 * 2;
    // 縮小: screen より大きい要求サイズは screen に収める（不変条件: outer <= screen）。
    if (w > sw) w = sw;
    if (h > sh) h = sh;
    if (w < 1) w = 1;
    if (h < 1) h = 1;

    var x: i64 = pos.x;
    var y: i64 = pos.y;
    if (x + w > sw) x = sw - w;
    if (y + h > sh) y = sh - h;
    if (x < 0) x = 0;
    if (y < 0) y = 0;

    return .{
        .outer = .{ .x = @intCast(x), .y = @intCast(y), .w = @intCast(w), .h = @intCast(h) },
        .pad = pad,
        .item_h = item_h,
    };
}

/// index 番目の項目行の矩形（outer.pad/item_h から算出。outer が縮小されているときは
/// 末尾の項目ほど outer の下端をはみ出しうる＝呼び出し側は outer でクリップ/hit-test する
/// ことで見えている範囲とクリックできる範囲を一致させる）。
pub fn itemRect(geo: PopupGeometry, index: usize) Rect {
    // layoutPopup と同じ理由（style/index が caller 由来で極端な値になりうる）で
    // i64 中間計算にして i32 演算の overflow trap を避ける。
    const pad64: i64 = geo.pad;
    const item_h64: i64 = geo.item_h;
    const idx64: i64 = std.math.cast(i64, index) orelse std.math.maxInt(i64);
    const x: i64 = @as(i64, geo.outer.x) + pad64;
    const y: i64 = @as(i64, geo.outer.y) + pad64 + idx64 * item_h64;
    const w: i64 = @max(@as(i64, geo.outer.w) - pad64 * 2, 0);
    return .{
        .x = @intCast(x),
        .y = @intCast(y),
        .w = @intCast(w),
        .h = @intCast(item_h64),
    };
}

/// 点 p がどの項目行にあるかを返す（矩形外・項目間隙は null）。
/// 先に outer.contains(p) で足切りするため、outer が縮小され末尾の項目行が outer の
/// 下端をはみ出していても、はみ出した部分（=描画時に pushClip(outer) で見えない部分）は
/// 決してヒットしない（見えている範囲=クリックできる範囲、の一致を保証する）。
pub fn hitTestItem(geo: PopupGeometry, item_count: usize, p: Vec2) ?usize {
    if (!geo.outer.contains(p)) return null;
    var i: usize = 0;
    while (i < item_count) : (i += 1) {
        if (itemRect(geo, i).contains(p)) return i;
    }
    return null;
}

/// popup を開く。id/pos を記録し、展開直前まで active/hot だった widget を解放する
/// （popup 表示中は active_id==0 を不変条件にする。stale hot_id の描画残りも解消）。
pub fn openPopup(ctx: *Context, id: Id, pos: Vec2) void {
    ctx.popup_state = .{ .id = id, .pos = pos };
    ctx.state.active_id = 0;
    ctx.state.hot_id = 0;
    ctx.state.next_hot_id = 0;
}

/// popup を明示的に閉じる。ESC 等の caller 判断で呼ぶ（libs/gui は platform.KeyCode を
/// 知らない契約のため、ESC 判定自体は caller 責務。input.zig 冒頭の「platform 非依存」
/// 方針を踏襲）。
pub fn closePopup(ctx: *Context) void {
    ctx.popup_state = null;
}

/// 何らかの popup が開いているか。
pub fn hasOpenPopup(ctx: *const Context) bool {
    return ctx.popup_state != null;
}

/// id の popup が開いているか。
pub fn isPopupOpen(ctx: *const Context, id: Id) bool {
    return if (ctx.popup_state) |s| s.id == id else false;
}

/// id に対応する popup が開いていれば描画+ヒットテストし、結果を返す。
/// 開いていなければ何もせず `.{}`（open=false）を返す（呼び出しは毎フレーム無条件でよい
/// immediate-mode 流儀）。
///
/// **契約: ctx.endFrame() の後に呼ぶこと**（最前面に描くため。selection_overlay.zig と
/// 同型の「endFrame 後に draw_list へ手動描画する」オーバーレイ規約）。
pub fn popupMenu(ctx: *Context, id: Id, items: []const PopupItem) PopupResult {
    std.debug.assert(!ctx.frame_active);
    const state = ctx.popup_state orelse return .{};
    if (state.id != id) return .{};

    // 空 items は caller のバグでも実運用でも起こりうる（例: 対象が削除された）ため
    // panic ではなく defensive に閉じる。
    if (items.len == 0) {
        closePopup(ctx);
        return .{ .dismissed = true };
    }

    var max_w: i32 = 0;
    for (items) |it| max_w = @max(max_w, @as(i32, @intCast(ctx.font.measure(it.label))));
    const style = ctx.style;
    const geo = layoutPopup(state.pos, items.len, max_w, style.popup_item_h, style.popup_padding, ctx.screen_w, ctx.screen_h);

    const in = &ctx.input;

    // 外側クリック（どれかのボタンが press edge かつ press 位置が outer 外）→ 閉じる。
    const any_pressed = in.mouse_pressed.left or in.mouse_pressed.right or in.mouse_pressed.middle;
    if (any_pressed and !geo.outer.contains(in.mouse_pressed_pos)) {
        closePopup(ctx);
        return .{ .dismissed = true };
    }

    const hovered_idx = hitTestItem(geo, items.len, in.mouse_pos);
    var clicked_idx: ?usize = null;
    if (in.mouse_pressed.left) {
        if (hitTestItem(geo, items.len, in.mouse_pressed_pos)) |idx| {
            if (items[idx].enabled) clicked_idx = idx;
        }
    }

    draw(ctx, geo, items, hovered_idx);

    if (clicked_idx) |idx| {
        closePopup(ctx);
        return .{ .selected = idx };
    }
    return .{ .open = true };
}

fn draw(ctx: *Context, geo: PopupGeometry, items: []const PopupItem, hovered_idx: ?usize) void {
    const dl = &ctx.draw_list;
    const style = ctx.style;
    // screen ではなく outer でクリップする: outer は screen 縮小により自然な内容サイズより
    // 小さくなりうる（layoutPopup 参照）。screen でクリップすると末尾の項目が outer の
    // 背景/枠をはみ出して描かれてしまうため、見えている範囲=outer に一致させる。
    dl.pushClip(geo.outer) catch @panic("popupMenu: OOM");
    defer dl.popClip();

    dl.rectFilled(geo.outer, style.bg) catch @panic("popupMenu: OOM");
    dl.rectOutline(geo.outer, style.border, 1) catch @panic("popupMenu: OOM");

    const metrics = ctx.font.metrics();
    const line_h: i32 = @intCast(metrics.line_height);
    for (items, 0..) |it, i| {
        const r = itemRect(geo, i);
        if (hovered_idx != null and hovered_idx.? == i and it.enabled) {
            dl.rectFilled(r, style.bg_hover) catch @panic("popupMenu: OOM");
        }
        const text_col = if (it.enabled) style.text else style.text_subtle;
        const text_y = r.y + @divTrunc(@as(i32, @intCast(r.h)) - line_h, 2);
        // ctx.labelEx と同じ契約（arena に複製）。popupMenu は endFrame 後に呼ばれるが、
        // arena は次 beginFrame まで有効（Context.beginFrame の reset タイミング参照）
        // なので caller が一時バッファを渡しても安全。
        const dup = ctx.allocator().dupe(u8, it.label) catch @panic("popupMenu: OOM");
        dl.textEx(.{ .x = r.x + 4, .y = text_y }, dup, text_col, null) catch @panic("popupMenu: OOM");
    }
}

// ============================================================
// Tests
// ============================================================

const font_mod = @import("font.zig");
const color_mod = @import("color.zig");
const Color = color_mod.Color;

fn testCtx() Context {
    return Context.init(std.testing.allocator, font_mod.default_font);
}

// ── layoutPopup: 幾何/クランプ ──────────────────────────────

test "layoutPopup: クランプ不要な通常位置はそのまま" {
    const geo = layoutPopup(.{ .x = 10, .y = 10 }, 3, 40, 20, 4, 800, 600);
    try std.testing.expectEqual(@as(i32, 10), geo.outer.x);
    try std.testing.expectEqual(@as(i32, 10), geo.outer.y);
    try std.testing.expectEqual(@as(u32, 48), geo.outer.w); // 40 + 4*2
    try std.testing.expectEqual(@as(u32, 68), geo.outer.h); // 3*20 + 4*2
}

test "layoutPopup: 右端はみ出しはクランプされる" {
    const geo = layoutPopup(.{ .x = 780, .y = 10 }, 3, 40, 20, 4, 800, 600);
    // w=48 なので x は 800-48=752 にクランプされる
    try std.testing.expectEqual(@as(i32, 752), geo.outer.x);
    try std.testing.expect(@as(i64, geo.outer.x) + geo.outer.w <= 800);
}

test "layoutPopup: 下端はみ出しはクランプされる" {
    const geo = layoutPopup(.{ .x = 10, .y = 590 }, 3, 40, 20, 4, 800, 600);
    try std.testing.expectEqual(@as(i32, 532), geo.outer.y); // 600-68=532
    try std.testing.expect(@as(i64, geo.outer.y) + geo.outer.h <= 600);
}

test "layoutPopup: 負の pos は 0 にクランプされる" {
    const geo = layoutPopup(.{ .x = -50, .y = -50 }, 2, 20, 20, 4, 800, 600);
    try std.testing.expectEqual(@as(i32, 0), geo.outer.x);
    try std.testing.expectEqual(@as(i32, 0), geo.outer.y);
}

test "layoutPopup: 画面より大きい要求サイズでも outer は screen 内に収まる" {
    // 100 項目 * item_h 50 = 5000px 高 vs screen 60px
    const geo = layoutPopup(.{ .x = 0, .y = 0 }, 100, 40, 50, 4, 100, 60);
    try std.testing.expect(geo.outer.w <= 100);
    try std.testing.expect(geo.outer.h <= 60);
    try std.testing.expectEqual(@as(i32, 0), geo.outer.x);
    try std.testing.expectEqual(@as(i32, 0), geo.outer.y);
}

// ── hitTestItem: 境界・間隙・矩形外 ──────────────────────────────

test "hitTestItem: 各項目行の内側で一致する index を返す" {
    const geo = layoutPopup(.{ .x = 0, .y = 0 }, 3, 40, 20, 4, 800, 600);
    // item0: y=[4,24), item1: y=[24,44), item2: y=[44,64)
    try std.testing.expectEqual(@as(?usize, 0), hitTestItem(geo, 3, .{ .x = 10, .y = 10 }));
    try std.testing.expectEqual(@as(?usize, 1), hitTestItem(geo, 3, .{ .x = 10, .y = 30 }));
    try std.testing.expectEqual(@as(?usize, 2), hitTestItem(geo, 3, .{ .x = 10, .y = 50 }));
}

test "hitTestItem: 左上は inclusive・右下は exclusive（Rect.contains 契約と同一）" {
    const geo = layoutPopup(.{ .x = 0, .y = 0 }, 1, 40, 20, 4, 800, 600);
    // item0 矩形: x=[4, 4+40)=44, y=[4,24)
    try std.testing.expectEqual(@as(?usize, 0), hitTestItem(geo, 1, .{ .x = 4, .y = 4 }));
    try std.testing.expectEqual(@as(?usize, null), hitTestItem(geo, 1, .{ .x = 44, .y = 4 }));
    try std.testing.expectEqual(@as(?usize, null), hitTestItem(geo, 1, .{ .x = 4, .y = 24 }));
}

test "hitTestItem: outer 矩形外は null" {
    const geo = layoutPopup(.{ .x = 100, .y = 100 }, 2, 40, 20, 4, 800, 600);
    try std.testing.expectEqual(@as(?usize, null), hitTestItem(geo, 2, .{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(@as(?usize, null), hitTestItem(geo, 2, .{ .x = 500, .y = 500 }));
}

test "hitTestItem: outer が縮小され末尾項目がはみ出す場合、はみ出した位置はヒットしない" {
    // screen 高 30px に対し 3 項目 * item_h 20 + pad*2=8 = 68px 要求 → outer.h は 30 に縮む
    const geo = layoutPopup(.{ .x = 0, .y = 0 }, 3, 40, 20, 4, 800, 30);
    try std.testing.expectEqual(@as(u32, 30), geo.outer.h);
    // item2 の自然な矩形は y=[44,64) だが outer.h=30 を超えているので outer.contains が
    // 先に false を返し、常に null になる。
    try std.testing.expectEqual(@as(?usize, null), hitTestItem(geo, 3, .{ .x = 10, .y = 50 }));
}

// ── popupMenu: Context 統合 ──────────────────────────────

const items3 = [_]PopupItem{
    .{ .label = "Copy" },
    .{ .label = "Delete" },
    .{ .label = "Rename" },
};

test "popupMenu: 閉じている id を呼んでも no-op" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();

    const result = ctx.popupMenu(42, &items3);
    try std.testing.expect(!result.open);
    try std.testing.expectEqual(@as(?usize, null), result.selected);
    try std.testing.expect(!result.dismissed);
    try std.testing.expectEqual(@as(usize, 0), ctx.draw_list.cmds.items.len);
}

test "popupMenu: 開いた状態で描画される（背景+枠+テキスト）" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();

    ctx.openPopup(1, .{ .x = 10, .y = 10 });
    const before = ctx.draw_list.cmds.items.len;
    const result = ctx.popupMenu(1, &items3);
    try std.testing.expect(result.open);
    // bg(1) + border(1) + text*3 = 5 コマンド追加
    try std.testing.expectEqual(before + 5, ctx.draw_list.cmds.items.len);
}

test "popupMenu: 項目内クリックで selected が返り popup が閉じる" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();
    ctx.openPopup(1, .{ .x = 0, .y = 0 });

    // 幾何を再現: content_w = measure("Delete")=6*8=48, pad=4, item_h=20
    // item1(Delete) の矩形は y=[24,44)。popupMenu は endFrame 後に呼ぶ契約だが、
    // input の edge（mouse_pressed 等）は次 beginFrame まで凍結される（endFrame は
    // input に触らない）ため、このフレームで push した press をそのまま読める。
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 30, .button = 0, .modifiers = 0 } });
    ctx.endFrame();

    const result = ctx.popupMenu(1, &items3);
    try std.testing.expectEqual(@as(?usize, 1), result.selected);
    try std.testing.expect(!ctx.hasOpenPopup());
}

test "popupMenu: disabled 項目クリックでは選択されず開いたまま" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();

    const items_disabled = [_]PopupItem{
        .{ .label = "Copy" },
        .{ .label = "Delete", .enabled = false },
    };
    ctx.openPopup(1, .{ .x = 0, .y = 0 });

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 30, .button = 0, .modifiers = 0 } }); // item1(Delete)
    ctx.endFrame();

    const result = ctx.popupMenu(1, &items_disabled);
    try std.testing.expectEqual(@as(?usize, null), result.selected);
    try std.testing.expect(result.open);
    try std.testing.expect(ctx.hasOpenPopup());
}

test "popupMenu: 外側クリックで dismissed=true・popup が閉じる" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();
    ctx.openPopup(1, .{ .x = 0, .y = 0 });

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_down = .{ .x = 700, .y = 500, .button = 0, .modifiers = 0 } }); // 遠く外側
    ctx.endFrame();

    const result = ctx.popupMenu(1, &items3);
    try std.testing.expect(result.dismissed);
    try std.testing.expect(!ctx.hasOpenPopup());
}

test "popupMenu: 空 items は defensive に閉じる（dismissed）" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();

    ctx.openPopup(1, .{ .x = 0, .y = 0 });
    const result = ctx.popupMenu(1, &[_]PopupItem{});
    try std.testing.expect(result.dismissed);
    try std.testing.expect(!ctx.hasOpenPopup());
}

test "popupMenu: 画面端近くで開いてもメニュー矩形が画面内に収まる" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(100, 100);
    ctx.endFrame();

    ctx.openPopup(1, .{ .x = 95, .y = 95 });
    _ = ctx.popupMenu(1, &items3);
    // 描画された rect_filled（背景）が画面内に収まっていることを確認
    const bg = ctx.draw_list.cmds.items[ctx.draw_list.cmds.items.len - 5].rect_filled.rect;
    try std.testing.expect(@as(i64, bg.x) + bg.w <= 100);
    try std.testing.expect(@as(i64, bg.y) + bg.h <= 100);
}

test "popupMenu: label に一時バッファを渡しても呼び出し後の書き換えに影響されない（arena dupe）" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.endFrame();

    var buf = "hello".*;
    const tmp_items = [_]PopupItem{.{ .label = &buf }};
    ctx.openPopup(1, .{ .x = 0, .y = 0 });
    _ = ctx.popupMenu(1, &tmp_items);
    buf[0] = 'X'; // popupMenu 呼び出し後に caller バッファを書き換える

    // 最後の text コマンドが元の "hello" のまま
    const last = ctx.draw_list.cmds.items[ctx.draw_list.cmds.items.len - 1];
    try std.testing.expectEqualStrings("hello", last.text.text);
}

// ── モーダル吸収 ──────────────────────────────

test "モーダル吸収: popup 表示中は背後 buttonBehavior が hover/active を得ない" {
    var ctx = testCtx();
    defer ctx.deinit();
    const btn_rect = geom.Rect{ .x = 0, .y = 0, .w = 100, .h = 50 };
    const full_clip = geom.Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    ctx.openPopup(99, .{ .x = 200, .y = 200 });
    const r = context_mod.buttonBehavior(&ctx, 1, btn_rect, full_clip);
    try std.testing.expect(!r.hovered);
    try std.testing.expect(!r.held);
    try std.testing.expect(!r.clicked);
    try std.testing.expectEqual(@as(context_mod.Id, 0), ctx.state.active_id);
    try std.testing.expect(ctx.wantsMouse()); // popup 表示中は wantsMouse()==true 相当
    ctx.endFrame();

    // popup を閉じれば通常どおり反応する
    ctx.closePopup();
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    const r2 = context_mod.buttonBehavior(&ctx, 1, btn_rect, full_clip);
    try std.testing.expect(r2.hovered);
    ctx.endFrame();
}

test "openPopup: 展開直前の active_id/hot_id を解除する" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.state.active_id = 7;
    ctx.state.hot_id = 7;
    ctx.state.next_hot_id = 7;

    ctx.openPopup(1, .{ .x = 0, .y = 0 });
    try std.testing.expectEqual(@as(context_mod.Id, 0), ctx.state.active_id);
    try std.testing.expectEqual(@as(context_mod.Id, 0), ctx.state.hot_id);
    try std.testing.expectEqual(@as(context_mod.Id, 0), ctx.state.next_hot_id);
}
