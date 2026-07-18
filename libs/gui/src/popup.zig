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

/// 幾何計算の結果。
///
/// 不変条件: `outer` は常に screen 矩形 `[0, screen_w) × [0, screen_h)` 内に収まる。
/// screen より要求サイズが大きい場合は viewport へ縮小して clip する（水平スクロール・
/// 文字縮小・折り返しはスコープ外）。長文 item の自然な文字幅は変えず、描画は
/// `pushClip(outer)` で切り、hit-test は `itemRect`（= 可視部分）に一致させる。
pub const PopupGeometry = struct {
    outer: Rect,
    pad: i32,
    item_h: i32,
};

/// item label 群の自然 content 幅（最大 measure）。要求 outer 幅は `content_w + pad*2`。
/// 極端に長い label でも i32 変換で trap しないよう i64 中間計算する。
/// draw ループでは再測定しない（popupMenu が 1 回だけ呼ぶ）。
pub fn measurePopupContentWidth(font: anytype, items: []const PopupItem) i32 {
    var max_w: i64 = 0;
    for (items) |it| {
        const mw: i64 = font.measure(it.label);
        max_w = @max(max_w, mw);
    }
    return std.math.cast(i32, max_w) orelse std.math.maxInt(i32);
}

/// 要求位置 pos に対しメニュー外枠を計算し、screen 矩形内に収まるようクランプする。
/// Context 非依存の純粋関数（単体テスト容易）。
///
/// 事前条件（デバッグ assert）: item_count > 0, item_h > 0, pad >= 0, screen_w > 0, screen_h > 0。
/// content_w は 0 以上を期待するが、万一負値が渡っても @max(content_w, 0) で救う。
///
/// クランプ手順:
/// 1. 要求サイズ `requested_w = content_w + pad*2` / `requested_h = count*item_h + pad*2`
/// 2. `outer.w = min(requested_w, screen_w)` / `outer.h = min(requested_h, screen_h)`（viewport clip）
/// 3. 位置を右/下端 → 左/上端の順で clamp し outer を screen 内へ収める
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

    // 1. 要求サイズ（自然サイズ）
    const requested_w: i64 = cw + pad64 * 2;
    const requested_h: i64 = count64 * item_h64 + pad64 * 2;
    // 2. viewport clip: screen より大きい要求は screen に収める（折り返し・縮小表示はしない）
    var w: i64 = @min(requested_w, sw);
    var h: i64 = @min(requested_h, sh);
    if (w < 1) w = 1;
    if (h < 1) h = 1;

    // 3. 位置 clamp（右/下端 → 左/上端）
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

/// index 番目の項目行の **可視** 矩形。
///
/// 自然な項目矩形（outer 内の content 帯 × item_h）を算出し、`outer` との交差を返す。
/// outer が viewport 縮小されているとき、末尾項目の自然矩形は outer 下端をはみ出しうるが、
/// 戻り値は outer 内の表示可能部分だけになる（空なら w=0 or h=0）。
/// 描画の `pushClip(outer)` と hit-test が同じ可視領域を共有するための単一の正。
pub fn itemRect(geo: PopupGeometry, index: usize) Rect {
    // layoutPopup と同じ理由（style/index が caller 由来で極端な値になりうる）で
    // i64 中間計算にして i32 演算の overflow trap を避ける。
    const pad64: i64 = geo.pad;
    const item_h64: i64 = geo.item_h;
    const idx64: i64 = std.math.cast(i64, index) orelse std.math.maxInt(i64);
    const x: i64 = @as(i64, geo.outer.x) + pad64;
    const y: i64 = @as(i64, geo.outer.y) + pad64 + idx64 * item_h64;
    // 水平: outer 内 content 帯（viewport 縮小後の outer.w に従う。文字幅自体は変えない）
    const w: i64 = @max(@as(i64, geo.outer.w) - pad64 * 2, 0);
    const natural: Rect = .{
        .x = @intCast(x),
        .y = @intCast(y),
        .w = @intCast(w),
        .h = @intCast(item_h64),
    };
    // 垂直（および万一の水平）: outer との交差 = 可視部分
    return Rect.intersect(natural, geo.outer);
}

/// 点 p がどの項目行にあるかを返す（矩形外・項目間隙・outer 外は null）。
/// `itemRect`（可視部分）のみを判定に使うため、outer clip 外の自然矩形部分は
/// ヒットしない（見えている範囲 = クリックできる範囲）。
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

    // item 幅はここで一度だけ測定（draw では再測定しない）。通常サイズでは
    // outer.w = max_measure + pad*2 となり、viewport 超過時は layoutPopup が screen へ clip。
    const content_w = measurePopupContentWidth(ctx.font, items);
    const style = ctx.style;
    const geo = layoutPopup(state.pos, items.len, content_w, style.popup_item_h, style.popup_padding, ctx.screen_w, ctx.screen_h);

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
        // outer 外に完全に出た項目（viewport 縮小で見えない末尾）はスキップ。
        // 長文の右側は pushClip(outer) で切られる（文字幅自体は変えない）。
        if (r.isEmpty()) continue;
        if (hovered_idx != null and hovered_idx.? == i and it.enabled) {
            dl.rectFilled(r, style.bg_hover) catch @panic("popupMenu: OOM");
        }
        const text_col = if (it.enabled) style.text else style.text_subtle;
        // 垂直中央は自然 item_h 基準（部分見切れでも行の見た目を崩さない）
        const text_y = r.y + @divTrunc(geo.item_h - line_h, 2);
        // ctx.labelEx と同じ契約（arena に複製）。popupMenu は endFrame 後に呼ばれるが、
        // arena は次 beginFrame まで有効（Context.beginFrame の reset タイミング参照）
        // なので caller が一時バッファを渡しても安全。
        const dup = ctx.allocator().dupe(u8, it.label) catch @panic("popupMenu: OOM");
        dl.textEx(.{ .x = r.x + 4, .y = text_y }, dup, text_col, null) catch @panic("popupMenu: OOM");
    }
}

/// tooltip overlay 描画（TASK-145.2）。
/// `layoutPopup` のクランプ規則で画面内に収め、popupMenu と同じく DrawList に
/// rectFilled / rectOutline / textEx を積む。text は caller が frame arena 上に複製済みであること
/// （Context.tooltip が dupe する）。screen_w/h が 0 なら no-op（layoutPopup の assert 回避）。
/// 位置: anchor 下端 + 4px（はみ出しは layoutPopup が clamp）。
pub fn drawTooltipOverlay(ctx: *Context, text: []const u8, anchor: Rect) void {
    if (ctx.screen_w == 0 or ctx.screen_h == 0) return;
    const style = ctx.style;
    const pad = style.popup_padding;
    const metrics = ctx.font.metrics();
    const line_h: i32 = @intCast(metrics.line_height);
    if (line_h <= 0) return;
    const content_w: i32 = @intCast(ctx.font.measure(text));
    const pos: Vec2 = .{
        .x = anchor.x,
        .y = anchor.y + @as(i32, @intCast(anchor.h)) + 4,
    };
    const geo = layoutPopup(pos, 1, content_w, line_h, pad, ctx.screen_w, ctx.screen_h);

    const dl = &ctx.draw_list;
    dl.pushClip(geo.outer) catch @panic("tooltip: OOM");
    defer dl.popClip();
    dl.rectFilled(geo.outer, style.bg) catch @panic("tooltip: OOM");
    dl.rectOutline(geo.outer, style.border, 1) catch @panic("tooltip: OOM");

    const r = itemRect(geo, 0);
    if (r.isEmpty()) return;
    const text_y = r.y + @divTrunc(geo.item_h - line_h, 2);
    dl.textEx(.{ .x = r.x + 4, .y = text_y }, text, style.text, null) catch @panic("tooltip: OOM");
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

test "layoutPopup: 長文 content_w でも viewport が十分なら要求幅どおり" {
    // content_w=200 → outer.w=208。screen 800 なら縮小しない
    const geo = layoutPopup(.{ .x = 10, .y = 20 }, 2, 200, 20, 4, 800, 600);
    try std.testing.expectEqual(@as(i32, 10), geo.outer.x);
    try std.testing.expectEqual(@as(i32, 20), geo.outer.y);
    try std.testing.expectEqual(@as(u32, 208), geo.outer.w);
    try std.testing.expectEqual(@as(u32, 48), geo.outer.h); // 2*20 + 4*2
}

test "layoutPopup: 小画面では outer.w が viewport 幅へ clip される" {
    // content_w=200 → 要求 208 > screen 100 → outer.w=100、位置も screen 内
    const geo = layoutPopup(.{ .x = 50, .y = 50 }, 3, 200, 20, 4, 100, 100);
    try std.testing.expectEqual(@as(u32, 100), geo.outer.w);
    try std.testing.expect(@as(i64, geo.outer.x) + geo.outer.w <= 100);
    try std.testing.expect(@as(i64, geo.outer.y) + geo.outer.h <= 100);
    try std.testing.expect(geo.outer.x >= 0);
    try std.testing.expect(geo.outer.y >= 0);
}

// ── itemRect / hitTestItem: 可視領域契約 ──────────────────────────────

test "itemRect: 通常サイズでは自然矩形（pad 内・full item_h）" {
    const geo = layoutPopup(.{ .x = 10, .y = 10 }, 3, 40, 20, 4, 800, 600);
    const r0 = itemRect(geo, 0);
    try std.testing.expectEqual(@as(i32, 14), r0.x); // 10+4
    try std.testing.expectEqual(@as(i32, 14), r0.y); // 10+4
    try std.testing.expectEqual(@as(u32, 40), r0.w);
    try std.testing.expectEqual(@as(u32, 20), r0.h);
}

test "itemRect: outer 縮小時は outer との交差（可視部分）を返す" {
    // screen 高 30 → outer.h=30。item2 自然 y=[44,64) は完全に outer 外 → empty
    const geo = layoutPopup(.{ .x = 0, .y = 0 }, 3, 40, 20, 4, 800, 30);
    try std.testing.expectEqual(@as(u32, 30), geo.outer.h);
    try std.testing.expect(itemRect(geo, 2).isEmpty());
    // item1 自然 y=[24,44) と outer [0,30) の交差 → y=24,h=6
    const r1 = itemRect(geo, 1);
    try std.testing.expectEqual(@as(i32, 24), r1.y);
    try std.testing.expectEqual(@as(u32, 6), r1.h);
    try std.testing.expect(!r1.isEmpty());
}

test "itemRect: 小画面で水平 content 帯が outer 内に収まる" {
    const geo = layoutPopup(.{ .x = 0, .y = 0 }, 1, 200, 20, 4, 100, 100);
    const r = itemRect(geo, 0);
    try std.testing.expectEqual(@as(u32, 100), geo.outer.w);
    try std.testing.expectEqual(@as(u32, 92), r.w); // 100 - 4*2
    try std.testing.expect(@as(i64, r.x) + r.w <= @as(i64, geo.outer.x) + geo.outer.w);
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

test "hitTestItem: 部分見切れ item は可視部分だけヒットする" {
    // item1 可視 y=[24,30)。y=25 は hit、自然矩形内だが outer 外の y=35 は null
    const geo = layoutPopup(.{ .x = 0, .y = 0 }, 3, 40, 20, 4, 800, 30);
    try std.testing.expectEqual(@as(?usize, 1), hitTestItem(geo, 3, .{ .x = 10, .y = 25 }));
    try std.testing.expectEqual(@as(?usize, null), hitTestItem(geo, 3, .{ .x = 10, .y = 35 }));
}

test "measurePopupContentWidth: max measure を返す" {
    const items = [_]PopupItem{
        .{ .label = "ab" }, // 16
        .{ .label = "abcd" }, // 32
        .{ .label = "a" }, // 8
    };
    const w = measurePopupContentWidth(font_mod.default_font, &items);
    try std.testing.expectEqual(@as(i32, 32), w);
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

test "popupMenu: 長文 item を 100x100 で開いても outer が viewport 内に収まる" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(100, 100);
    ctx.endFrame();

    // default font advance≈8 → 40 文字で content_w≈320 ≫ 100
    const long = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const long_items = [_]PopupItem{
        .{ .label = long },
        .{ .label = "B" },
        .{ .label = "C" },
    };
    ctx.openPopup(1, .{ .x = 10, .y = 10 });
    const result = ctx.popupMenu(1, &long_items);
    try std.testing.expect(result.open);

    // 背景 rect（最初の rect_filled）が [0,100)×[0,100) 内
    const bg = ctx.draw_list.cmds.items[0].rect_filled.rect;
    try std.testing.expectEqual(@as(u32, 100), bg.w);
    try std.testing.expect(@as(i64, bg.x) + bg.w <= 100);
    try std.testing.expect(@as(i64, bg.y) + bg.h <= 100);
    try std.testing.expect(bg.x >= 0);
    try std.testing.expect(bg.y >= 0);

    // 可視 item は hit、outer 外は hit しない
    const content_w = measurePopupContentWidth(ctx.font, &long_items);
    const geo = layoutPopup(.{ .x = 10, .y = 10 }, 3, content_w, 20, 4, 100, 100);
    try std.testing.expectEqual(@as(u32, 100), geo.outer.w);
    try std.testing.expectEqual(@as(?usize, 0), hitTestItem(geo, 3, .{ .x = 20, .y = 20 }));
    try std.testing.expectEqual(@as(?usize, null), hitTestItem(geo, 3, .{ .x = 150, .y = 20 }));
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
